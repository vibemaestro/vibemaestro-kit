#!/usr/bin/env python3
"""Install the SDLC gates into a repo: workflows into `.github/workflows/`, the gate scripts into `.vibemaestro/gates/`, an allowlist header.

    install_gates.py [--root DIR] [--only commit-discipline,pr-sensitive,pr-title,pr-body,dead-branches]
                     [--runner-var NAME] [--runner-default LABEL] [--dry-run]

Skills ask, scripts do: the `install-gates` skill collects the answers, this script writes the files, with no model in between.

- Never overwrites. A file that exists is KEPT, byte for byte: `kept` when it equals what would be written, `kept (differs)` when it does
  not (the repo changed it on purpose, or the plugin has moved on: a person decides). A second run is a no-op.
- The workflow templates (`gates/workflows/*.yml`) get `runs-on: ${{ vars.CI_GATE_RUNNER || vars.<runner var> || '<runner default>' }}`. The two
  values come from the flags, else from `ci.runner_var` / `ci.runner_default` of the repo's `.vibemaestro/sdlc.json`, else `CI_RUNNER` / `ubuntu-latest`.
  A runner label that is not `[A-Za-z0-9._-]+` and a variable that is not an identifier are refused before anything is written.
- The runner default `self-hosted only` (`sdlc_config.RUNNER_SELF_HOSTED_ONLY`) is the form for an organisation that has no hosted runner: the
  workflows get no label at all, `... || fromJSON('<var> is not set and ...')`, so with both variables unset or empty the run fails when it is
  created, with that message, instead of a job that waits for a machine that never comes. A workflow kept from an earlier install keeps its
  fallback: with this form the installer prints a WARNING for each kept file whose runs-on has no guard.
- The gate scripts, the config loader and the message table (`messages.py`) are copied to `.vibemaestro/gates/` (the workflows run
  them from there, from the BASE branch).
- With `language` `en` in the repo's config the copies are English only: the `vi` slot of every `messages.py` entry holds the English
  text, the `vi` defaults of `sdlc_config.py` hold the `en` preset's values, and the install stops (rc 65, nothing written) if a
  letter in U+00C0..U+1EF9 is left in a copy it would write, a workflow template or the allowlist header (a rendered workflow carries
  the repo's own tokens, so it is not checked). A copy the repo already has is still kept; with `en` a kept copy of those scripts that holds such
  a letter is named in a WARNING (delete the file and install again for a clean one). With `vi` (or no key) the copies are the
  plugin's own, byte for byte.
- The allowlist of the sensitive-info gate is written as a header-only file at `sensitive.allowlist` (default `.pr-sensitive-allow`).
- It does not write `.vibemaestro/sdlc.json`; it prints which keys the gates read.
- After that it asks GitHub, read-only (`gh api -X GET`, never a write, never a prompt), whether the runner variable is set on the repo or
  on its organization. Unset (or empty) prints one WARNING (the workflows would run on the fallback label, and on a hosted runner whose minutes are
  locked the gates never start and read as failed). When `gh` cannot answer it prints one "check skipped" line. Neither changes the rc.

rc 0 done (or nothing to do; the runner-variable check never changes it), 64 bad usage (unknown gate, bad runner label, not a git repo),
65 invalid config, or a Vietnamese letter that the `en` rewrite could not remove.
Standard library only, Python 3.8+.
"""
import argparse
import ast
import json
import os
import re
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sdlc_config  # noqa: E402

PLUGIN = os.path.dirname(HERE)
GATES_DIR = os.path.join(PLUGIN, "gates")
TEMPLATES = os.path.join(GATES_DIR, "workflows")
# gate name -> (workflow template, the script it runs)
GATES = {
    "commit-discipline": ("commit-discipline.yml", "commit_discipline.py"),
    "pr-sensitive": ("pr-sensitive.yml", "pr_sensitive.py"),
    "pr-title": ("pr-title.yml", "pr_title.py"),
    "pr-body": ("pr-body.yml", "pr_body.py"),
    "pr-evidence": ("pr-evidence.yml", "pr_evidence.py"),
    "dead-branches": ("dead-branches.yml", "dead_branches.sh"),
}
KEYS = {
    "commit-discipline": "commits.max_per_pr, commits.max_touches, commits.round_pattern, tokens.commit_exception",
    "pr-sensitive": "sensitive.scan, sensitive.allowlist",
    "pr-title": "pr.title.pattern, pr.title.max_len, pr.title.intent_form, branch.pattern, branch.intent_prefix",
    "pr-body": "pr.body.max_chars, pr.body.summary_max_lines, pr.body.evidence_max_lines, tokens.summary_heading, tokens.evidence_heading",
    "pr-evidence": "evidence.ui_paths, tokens.round_comment_prefix, commits.round_pattern",
    "dead-branches": "dead_branches.max_merged_on_remote, branch.protected, branch.intent_prefix",
}
ALLOWLIST_HEADER = """# Allowlist of the sensitive-info gate (.vibemaestro/gates/pr_sensitive.py): ONLY for a false positive that a person has looked at.
#
# The workflow reads this file at the BASE of the PR, not at its head: a line added in a PR takes effect for the PRs AFTER it has
# merged. That is deliberate: no PR can exempt the value it is itself leaking.
#
# Format: <sha256 of exactly the value that was caught>  # kind - where it was seen - why it is not sensitive
# Take the sha256 from the RED line when you run the scanner on your own machine (CI does not print it: the hash of a value with little
# entropy, such as an IPv4 address, can be reversed from a public log). Never write the value itself in this file.
"""


def die(rc, msg):
    sys.stderr.write("install-gates: %s\n" % msg)
    return rc


GH_TIMEOUT_S = 20


def _timeout():
    """Seconds one gh call may take. INSTALL_GATES_GH_TIMEOUT_S shortens it for tests; a value that is not a number in (0, 60] is ignored."""
    try:
        v = float(os.environ.get("INSTALL_GATES_GH_TIMEOUT_S", ""))
    except ValueError:
        return GH_TIMEOUT_S
    return v if 0 < v <= 60 else GH_TIMEOUT_S


def _gh_names(root, path):
    """([(name, value)], why): the variables that `gh api -X GET --paginate <path>` lists, or (None, why) when gh cannot answer. Read-only
    by construction: a fixed argv with no shell, GET and no body flag (a body flag would turn the call into a POST), stdin closed so nothing
    can prompt, a timeout. `gh` is looked up once, here, and run by its absolute path: with an empty or `.` entry in PATH a bare name would be
    searched in the repo being installed into, and a file of the repo must never run. GH_REPO is dropped so `{owner}/{repo}` means the repo
    being installed into. The answer is data: a page that is not `{"variables": [{"name": str, "value": str}, ...]}` is "cannot tell",
    never "empty"."""
    env = {k: v for k, v in os.environ.items() if k != "GH_REPO"}
    env.update(GH_PROMPT_DISABLED="1", GH_NO_UPDATE_NOTIFIER="1", GH_SPINNER_DISABLED="1", NO_COLOR="1")
    gh = shutil.which("gh")
    if not gh:
        return None, "gh is not installed"
    gh = os.path.abspath(gh)
    for base in {os.path.abspath(root), os.path.realpath(root)}:
        for where in (gh, os.path.realpath(gh)):       # a symlink inside the repo to /bin/sh would run the repo's own files
            try:
                inside = os.path.commonpath([base, where]) == base
            except ValueError:                         # another drive: not inside
                inside = False
            if inside:
                return None, "the gh found is a file of this repo and is not run"
    try:
        r = subprocess.run([gh, "api", "-X", "GET", "--paginate", path + "?per_page=100"], cwd=root, env=env,
                           stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=_timeout())
    except subprocess.TimeoutExpired:
        return None, "gh did not answer in time"
    except OSError as e:
        return None, "gh could not run: %s" % e.__class__.__name__
    if r.returncode != 0:
        first = re.sub(r"[^\x20-\x7e]", "?", (r.stderr.decode("utf-8", "replace").strip().splitlines() or [""])[0])[:100]
        return None, "gh could not read it: not logged in, no access, no network, repo not found or no GitHub remote here (rc %d%s)" % (
            r.returncode, ": " + first if first else "")
    text, rows_all, i, dec = r.stdout.decode("utf-8", "replace"), [], 0, json.JSONDecoder()
    while True:
        while i < len(text) and text[i].isspace():
            i += 1
        if i >= len(text):
            break
        try:
            page, i = dec.raw_decode(text, i)
        except (ValueError, RecursionError):
            return None, "gh answered with something that is not JSON"
        rows = page.get("variables") if isinstance(page, dict) else None
        if not isinstance(rows, list) or not all(isinstance(x, dict) and isinstance(x.get("name"), str)
                                                 and isinstance(x.get("value", ""), str) for x in rows):
            return None, "gh answered with something that is not a list of variables"
        rows_all.extend((x["name"], x.get("value")) for x in rows)
    if not text.strip():
        return None, "gh answered with nothing"
    return rows_all, None


def _find(rows, want):
    """None when `want` (upper-cased) is not listed, else its value: `""` when it is listed with an empty value (the workflows read
    `vars.X || 'fallback'`, so an empty value falls back too), a non-empty string otherwise (a list that gives no value counts as set)."""
    for name, value in rows:
        if name.upper() == want:
            return "x" if value is None else value.strip()
    return None


def self_hosted_only(default):
    return default == sdlc_config.RUNNER_SELF_HOSTED_ONLY


# the words the failing guard carries; a kept workflow without them on a runs-on line is judged to have a fallback
GUARD_MARK = "is not set and this repo runs on self-hosted runners only"
_RUNS_ON_KEY = re.compile(r"""^\s*(?:-\s+)?["']?runs-on["']?\s*:""")


def kept_fallbacks(path):
    """The `runs-on` lines of the kept workflow `path` that do not carry the failing guard (a line that is not exactly the guard counts as a
    fallback: a warning too many is safe, one too few queues a job), or None when the file cannot be read."""
    try:
        with open(path, encoding="utf-8-sig", errors="replace") as f:
            return [ln.strip() for ln in f if _RUNS_ON_KEY.match(ln) and GUARD_MARK not in ln]
    except OSError:
        return None


def runner_fallback(var, default):
    """The last operand of the runs-on expression: the quoted fallback label, or in the self-hosted-only form a `fromJSON` of text that is not
    JSON, which fails the evaluation (the run is refused with the text in its error) and names no machine at all."""
    if self_hosted_only(default):
        return "fromJSON('%s %s; set the repository variable %s to the label of one')" % (var, GUARD_MARK, var)
    return "'%s'" % default


def runner_var_report(root, var, default):
    """The one line to print about the runner variable `var`: set, WARNING (unset or empty), or skipped. Names compare case-insensitively
    (GitHub stores them upper-cased). The repo's variables first, the organization's visible to the repo only when the repo's do not list
    it (a repo value, even an empty one, wins over the organization's); a scope that cannot be read never turns into "unset" or into "set":
    when the repo's list cannot be read nothing is said about the variable (a repo value could override whatever the organization holds),
    and "unset" needs both lists read and neither holding the name. Never raises: anything unexpected is a skip."""
    try:
        want = var.upper()
        repo, why_repo = _gh_names(root, "repos/{owner}/{repo}/actions/variables")
        if repo is None:
            return "install-gates: runner variable check skipped (repo variables: %s)" % why_repo
        got, scope = _find(repo, want), "repo"
        if got is None:
            org, why_org = _gh_names(root, "repos/{owner}/{repo}/actions/organization-variables")
            if org is None:
                return "install-gates: runner variable check skipped (organization variables: %s)" % why_org
            got, scope = _find(org, want), "organization"
        if got:
            return "runner variable %s: set (%s)" % (var, scope)
        state = "is set but empty on the %s" % scope if got is not None else "is not set on this repo or its organization"
        if self_hosted_only(default):
            return ("WARNING runner variable %s %s: the workflows have no fallback runner (ci.runner_default is \"%s\"), so a gate run "
                    "fails at its start with a message naming the variable unless CI_GATE_RUNNER is set. Set it to the label of your runner: gh variable set %s --body "
                    "<label> (this script never sets it)" % (var, state, default, var))
        return ("WARNING runner variable %s %s: the workflows fall back to runs-on '%s'. If that is a GitHub-hosted runner whose minutes "
                "are locked, the gates never start and read as failed. Set it to the label of your runner: gh variable set %s --body "
                "<label> (this script never sets it)" % (var, state, default, var))
    except Exception as e:
        return "install-gates: runner variable check skipped (internal error: %s)" % e.__class__.__name__


def render(text, var, default, exception="COMMIT EXCEPTION:"):
    """The template with its markers filled. The exemption token sits in a quoted expression string inside a double-quoted YAML
    scalar, so it is escaped for both (`'` doubled for the expression, then `\\` and `"` for YAML)."""
    if "@@COMMIT_EXCEPTION@@" in text and ("${{" in exception or "}}" in exception):
        raise ValueError("tokens.commit_exception holds ${{ or }}: it cannot sit inside a workflow expression")
    tok = exception.replace("'", "''").replace("\\", "\\\\").replace('"', '\\"')
    return (text.replace("'@@RUNNER_DEFAULT@@'", runner_fallback(var, default)).replace("@@RUNNER_VAR@@", var)
            .replace("@@RUNNER_DEFAULT@@", default).replace("@@COMMIT_EXCEPTION@@", tok))


# a letter of the Vietnamese range (U+00C0..U+1EF9: the Latin-1 and Latin Extended letters up to the Vietnamese tones)
VIET = re.compile("[\u00c0-\u1ef9]")


def viet_lines(data):
    """The 1-based numbers of the lines of `data` (bytes) that hold a Vietnamese letter."""
    return [i for i, ln in enumerate(data.decode("utf-8", errors="replace").split("\n"), 1) if VIET.search(ln)]


def _splice(data, edits):
    """`data` (bytes) with each (node, new bytes) put in place of the node's source text. `ast` counts columns in UTF-8 bytes."""
    starts, pos = [], 0
    for ln in data.split(b"\n"):
        starts.append(pos)
        pos += len(ln) + 1
    spans = sorted(((starts[n.lineno - 1] + n.col_offset, starts[n.end_lineno - 1] + n.end_col_offset, new) for n, new in edits), reverse=True)
    for lo, hi, new in spans:
        data = data[:lo] + new + data[hi:]
    return data


def _node_bytes(data, node):
    lines = data.split(b"\n")
    if node.lineno == node.end_lineno:
        return lines[node.lineno - 1][node.col_offset:node.end_col_offset]
    first = lines[node.lineno - 1][node.col_offset:]
    last = lines[node.end_lineno - 1][:node.end_col_offset]
    return b"\n".join([first] + lines[node.lineno:node.end_lineno - 1] + [last])


def english_messages(data):
    """`messages.py` with the English text in the `vi` slot of every `TABLE` entry (the keys, the placeholders and the code stay)."""
    tree = ast.parse(data.decode("utf-8"))
    edits = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "TABLE" for t in node.targets) and isinstance(node.value, ast.Dict):
            for entry in node.value.values:
                if isinstance(entry, ast.Dict):
                    slots = {k.value: v for k, v in zip(entry.keys, entry.values) if isinstance(k, ast.Constant)}
                    if "vi" in slots and "en" in slots:
                        edits.append((slots["vi"], _node_bytes(data, slots["en"])))
    return _splice(data, edits)


def _vi_to_en(base, over, out, path="DEFAULTS"):
    """Fill `out` with {Vietnamese default string: its `en` preset string} by walking the defaults and the preset laid over them."""
    if isinstance(over, dict):
        for k, v in over.items():
            _vi_to_en(base[k], v, out, "%s.%s" % (path, k))
    elif isinstance(over, list):
        if len(base) != len(over):
            raise ValueError("%s: the vi and en lists differ in length" % path)
        for i, (b, o) in enumerate(zip(base, over)):
            _vi_to_en(b, o, out, "%s[%d]" % (path, i))
    elif isinstance(over, str) and over != base:
        if out.setdefault(base, over) != over:
            raise ValueError("%s: one vi text, two en texts" % path)


def english_config(data):
    """`sdlc_config.py` with the `en` preset's text where the `vi` defaults have theirs: each string literal equal to a `vi` default
    that the preset replaces is written as the preset's string."""
    table = {}
    _vi_to_en(sdlc_config.DEFAULTS, sdlc_config.LANGUAGE_PRESETS["en"], table)
    edits = [(n, repr(table[n.value]).encode("utf-8")) for n in ast.walk(ast.parse(data.decode("utf-8")))
             if isinstance(n, ast.Constant) and isinstance(n.value, str) and n.value in table and VIET.search(n.value)]
    return _splice(data, edits)


def write_new(path, data, mode, dry):
    """Create `path` only if it is absent. Returns 'wrote', or 'kept' / 'kept (differs)' when it exists."""
    if os.path.lexists(path):
        try:
            with open(path, "rb") as f:
                same = f.read() == data
        except OSError:
            same = False
        return "kept" if same else "kept (differs)"
    if dry:
        return "would write"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    with os.fdopen(fd, "wb") as f:
        f.write(data)
    os.chmod(path, mode)
    return "wrote"


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--root")
    ap.add_argument("--only")
    ap.add_argument("--runner-var")
    ap.add_argument("--runner-default")
    ap.add_argument("--dry-run", action="store_true")
    try:
        a = ap.parse_args(argv)
    except SystemExit as e:
        return 64 if e.code else 0
    root = a.root or os.getcwd()
    top = subprocess.run(["git", "-C", root, "rev-parse", "--show-toplevel"], capture_output=True, text=True)
    if top.returncode != 0:
        return die(64, "%s is not inside a git repo" % root)
    root = top.stdout.strip()
    names = list(GATES) if not a.only else [n.strip() for n in a.only.split(",") if n.strip()]
    unknown = [n for n in names if n not in GATES]
    if unknown or not names:
        return die(64, "unknown gate %s (known: %s)" % (", ".join(unknown) or "(none given)", ", ".join(GATES)))
    cfg, probs, _present = sdlc_config.load(root)
    if probs:
        sys.stderr.write(sdlc_config.render_problems(probs) + "\n")
        return 65
    var = a.runner_var or cfg["ci"]["runner_var"]
    default = a.runner_default or cfg["ci"]["runner_default"]
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", var):
        return die(64, "the runner variable must be an identifier ([A-Za-z_][A-Za-z0-9_]*), not %r" % var)
    if not self_hosted_only(default) and not re.fullmatch(r"[A-Za-z0-9._-]+", default):
        return die(64, "the runner label must match [A-Za-z0-9._-]+, or be %r (no fallback), not %r" % (sdlc_config.RUNNER_SELF_HOSTED_ONLY, default))

    plan = []   # (relative path, bytes, mode)
    owned = []  # (label, bytes) the plugin writes as its own text: what language en must find free of Vietnamese letters
    vendored_rels = set()
    for n in names:
        with open(os.path.join(TEMPLATES, GATES[n][0]), encoding="utf-8") as f:
            tmpl = f.read()
            owned.append(("gates/workflows/" + GATES[n][0] + " (the template)", tmpl.encode("utf-8")))
            try:
                text = render(tmpl, var, default, cfg["tokens"]["commit_exception"])
            except ValueError as e:
                return die(65, str(e))
            plan.append((".github/workflows/" + GATES[n][0], text.encode("utf-8"), 0o644))
    vendored = ["gate_common.py"] + [GATES[n][1] for n in names]
    for fn in vendored:
        with open(os.path.join(GATES_DIR, fn), "rb") as f:
            plan.append((".vibemaestro/gates/" + fn, f.read(), 0o755))
            vendored_rels.add(".vibemaestro/gates/" + fn)
    english = {"sdlc_config.py": english_config, "messages.py": english_messages}
    for fn in ("sdlc_config.py", "messages.py"):        # the config loader, and the message table a gate prints from
        with open(os.path.join(HERE, fn), "rb") as f:
            data = f.read()
        if cfg["language"] == "en":
            try:
                data = english[fn](data)
            except Exception as e:          # a source the rewrite cannot read is a refusal, not a traceback half way through
                return die(65, "%s: the English copy could not be made: %s: %s" % (fn, e.__class__.__name__, e))
        plan.append((".vibemaestro/gates/" + fn, data, 0o644))
        vendored_rels.add(".vibemaestro/gates/" + fn)
    if "pr-sensitive" in names:
        owned.append(("the allowlist header", ALLOWLIST_HEADER.encode("utf-8")))
        plan.append((cfg["sensitive"]["allowlist"], ALLOWLIST_HEADER.encode("utf-8"), 0o644))

    if cfg["language"] == "en":
        # the plugin's own text only: a rendered workflow carries the repo's own tokens, which may hold such a letter on purpose
        for rel, data, _mode in plan:
            if rel in vendored_rels:
                owned.append((rel, data))
        for label, data in owned:
            left = viet_lines(data)
            if left:
                return die(65, "%s: language is en, but line %d of the text to write (%d line(s) in all) still holds a Vietnamese letter: "
                           "nothing was written. A Vietnamese comment or text in the plugin's own file is the usual cause." % (label, left[0], len(left)))
    # every target is checked BEFORE anything is written: it must stay inside the repo once symlinks are resolved, and no parent of it may
    # be a file (a symlinked .github pointing outside the repo would otherwise make the installer write there)
    real_root = os.path.realpath(root)
    for rel, _data, _mode in plan:
        path = os.path.join(root, *rel.split("/"))
        anc = os.path.dirname(path)
        while not os.path.lexists(anc):
            anc = os.path.dirname(anc)
        if not os.path.isdir(anc):
            return die(64, "%s: a parent of this path is not a directory" % rel)
        if os.path.commonpath([real_root, os.path.realpath(anc)]) != real_root:
            return die(64, "%s resolves outside the repo (a symlinked directory?): nothing was written" % rel)

    counts = {}
    for rel, data, mode in plan:
        res = write_new(os.path.join(root, *rel.split("/")), data, mode, a.dry_run)
        counts[res] = counts.get(res, 0) + 1
        print("%-16s %s" % (res, rel))
        if res == "kept (differs)" and self_hosted_only(default) and rel.startswith(".github/workflows/"):
            hosted = kept_fallbacks(os.path.join(root, *rel.split("/")))
            if hosted is None:
                print("WARNING %s is kept and could not be read, so it is not known whether its runs-on has a fallback: look at it, or delete it "
                      "and install again." % rel)
            elif hosted:
                print("WARNING %s is kept, and its runs-on still has a fallback (%s) although ci.runner_default is \"%s\": a run with the "
                      "variable unset can still go to that runner and queue without an error. Delete the file and install again to write "
                      "the version with no fallback." % (rel, hosted[0], sdlc_config.RUNNER_SELF_HOSTED_ONLY))
        if res == "kept (differs)" and cfg["language"] == "en" and rel in vendored_rels:   # the plugin's copies, not a file the repo owns
            try:
                with open(os.path.join(root, *rel.split("/")), "rb") as f:
                    left = viet_lines(f.read())
            except OSError:
                left = []
            if left:
                print("WARNING %s is kept and still holds Vietnamese text (%d line(s)) although language is en: delete the file and install "
                      "again to write the English copy." % (rel, len(left)))
        if res == "kept (differs)" and rel.endswith("/commit-discipline.yml"):
            with open(os.path.join(root, *rel.split("/")), "rb") as f:
                have = f.read()
            want = [ln for ln in data.splitlines() if ln.strip().startswith(b"if:")]
            if want and want[0] not in have.splitlines():
                print("WARNING %s has another job condition than this plugin writes (an older template, or another "
                      "exemption token than tokens.commit_exception): an edit that adds the configured token may not run "
                      "the gate. Delete the file and install again to write the current one." % rel)
    print("install-gates: %s" % ", ".join("%s %d" % (k, v) for k, v in sorted(counts.items())))
    print("runs-on in the workflows: ${{ vars.CI_GATE_RUNNER || vars.%s || %s }}  (set it in ci.runner_var / ci.runner_default of .vibemaestro/sdlc.json to keep it there)"
          % (var, "no fallback label (a run with neither variable set fails at its start)" if self_hosted_only(default) else "'%s'" % default))
    print(runner_var_report(root, var, default))
    print("config keys the gates read:")
    for n in names:
        print("  %s: %s" % (n, KEYS[n]))
    print("a gate judges a PR by the scripts and the config of its BASE branch: merge this change first, then it applies to later PRs")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
