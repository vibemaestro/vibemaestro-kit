"""Backends of the guarded merge.

Infrastructure that varies by kind has a few supported, tested backends; anything else is an adapter a company writes and tests
itself, named `external:<path>`, never generated code.

    load(kind, spec, fetch) -> Backend
        kind   "ci" or "registry"
        spec   a built-in name (ci: github-actions; registry: ghcr) or external:<relative path>
        fetch  fetch(path) -> text or None: how an external adapter is read (the guard reads it from the PR's base commit)

Interfaces (an adapter is a Python module that defines them):
    ci        runs(repo, sha) -> [{name, status, conclusion, started_at, ...}]; optional failed_steps(repo, run) -> [step name] | None
    registry  list_tags(image) -> [tag]; tag_exists(image, tag) -> bool; visibility(image) -> "private" | "public" | "unknown"

`Backend.digest` is the sha256 of the code that answers: the built-in module's file, or the adapter's text. The guard puts it in
its plan line, so a signature binds it. A missing function, an unreadable or failing adapter, or an unknown name raises
gate_common.ConfigError (rc 65); a `gh` call that fails raises gate_common.Infra (rc 2).

The `gh` helpers below are shared by the built-in backends and the guard: GET only, no `--jq`, no `--slurp` (version-dependent);
`--paginate` prints the pages one after the other, and `json_values` splits them.
Standard library only, Python 3.8+.
"""
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True

from gate_common import ConfigError, Infra  # noqa: E402

FUNCS = {"ci": ("runs",), "registry": ("list_tags", "tag_exists", "visibility")}
OPTIONAL = {"ci": ("failed_steps",), "registry": ()}
BUILTIN = {"ci": {"github-actions": "github_actions"}, "registry": {"ghcr": "ghcr"}}
GH_TIMEOUT_S = 120                              # MERGE_GUARD_GH_TIMEOUT_S shortens it for tests: a number in (0, 120]
_HERE = os.path.dirname(os.path.abspath(__file__))


class NotFound(Infra):
    """A 404 from the API: the caller decides whether that means "absent"."""


def sha256_text(text):
    return hashlib.sha256(text.encode("utf-8", "surrogateescape")).hexdigest()


def gh_timeout():
    try:
        v = float(os.environ.get("MERGE_GUARD_GH_TIMEOUT_S", ""))
    except ValueError:
        return GH_TIMEOUT_S
    return v if 0 < v <= GH_TIMEOUT_S else GH_TIMEOUT_S


def gh(args):
    """(rc, stdout, stderr) of one `gh` call; a missing `gh` or a timeout is Infra."""
    exe = shutil.which("gh")
    if not exe:
        raise Infra("no gh on PATH")
    limit = gh_timeout()
    try:
        p = subprocess.run([exe] + args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=limit)
    except subprocess.TimeoutExpired:
        raise Infra("gh %s timed out after %gs" % (" ".join(args[:2]), limit))
    return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace").strip()


def _fail(path, err):
    if "HTTP 404" in err:
        raise NotFound("not found: %s" % path)
    raise Infra("gh api %s failed: %s" % (path, err[:200]))


def json_values(text):
    """Every JSON value in `text`, which may hold several one after the other (the pages of `gh api --paginate`)."""
    dec, out, i, n = json.JSONDecoder(), [], 0, len(text)
    while True:
        while i < n and text[i] in " \t\r\n":
            i += 1
        if i >= n:
            return out
        try:
            v, i = dec.raw_decode(text, i)
        except ValueError as e:
            raise Infra("gh printed something that is not JSON (%s)" % e)
        out.append(v)


def api(path):
    """One GET page, parsed."""
    rc, out, err = gh(["api", path])
    if rc != 0:
        _fail(path, err)
    vals = json_values(out)
    if len(vals) != 1:
        raise Infra("gh api %s printed %d JSON values, not 1" % (path, len(vals)))
    return vals[0]


def api_pages(path):
    """Every page of a GET, each parsed."""
    args = ["api", path, "--paginate"]
    rc, out, err = gh(args)
    if rc != 0:
        _fail(path, err)
    return json_values(out)


def api_list(path):
    """A paginated GET whose pages are lists: the elements of every page."""
    out = []
    for page in api_pages(path):
        if not isinstance(page, list):
            raise Infra("gh api %s: a page is not a list" % path)
        out.extend(page)
    return out


def api_raw(path):
    """A file's text through the contents API (Accept: raw); None when it is not there."""
    rc, out, err = gh(["api", "-H", "Accept: application/vnd.github.raw", path])
    if rc != 0:
        try:
            _fail(path, err)
        except NotFound:
            return None
    return out


class Backend(object):
    def __init__(self, kind, spec, mod, digest):
        self.kind, self.spec, self.mod, self.digest = kind, spec, mod, digest

    def __getattr__(self, name):
        if name not in FUNCS[self.kind] + OPTIONAL[self.kind]:
            raise AttributeError(name)
        fn = getattr(self.mod, name, None)
        if fn is None:                                  # an optional function the adapter leaves out
            return lambda *a: None
        return fn


def _import_file(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def load(kind, spec, fetch):
    """The backend `spec` of `kind` (see the module docstring)."""
    if kind not in FUNCS:
        raise ValueError("unknown backend kind %r" % kind)
    if isinstance(spec, str) and spec.startswith("external:"):
        rel = spec[len("external:"):]
        text = fetch(rel)
        if text is None:
            raise ConfigError("%s backend %s: the adapter file %s is not there" % (kind, spec, rel))
        tmp = tempfile.mkdtemp(prefix="merge-adapter-")
        try:
            p = os.path.join(tmp, "adapter.py")
            fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(text)
            try:
                mod = _import_file("merge_adapter_%s" % kind, p)
            except (Exception, SystemExit) as e:                  # SystemExit too: an adapter cannot end the guard with its own code
                raise ConfigError("%s backend %s: the adapter fails to load (%s)" % (kind, spec, type(e).__name__))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        digest = sha256_text(text)
    elif spec in BUILTIN[kind]:
        path = os.path.join(_HERE, BUILTIN[kind][spec] + ".py")
        mod = _import_file("merge_backend_" + BUILTIN[kind][spec], path)
        with open(path, encoding="utf-8") as f:
            digest = sha256_text(f.read())
    else:
        raise ConfigError("%s backend %r is not supported: use %s, or external:<path>" % (kind, spec, " or ".join(BUILTIN[kind])))
    missing = [f for f in FUNCS[kind] if not callable(getattr(mod, f, None))]
    if missing:
        raise ConfigError("%s backend %s does not define %s" % (kind, spec, ", ".join(missing)))
    return Backend(kind, spec, mod, digest)
