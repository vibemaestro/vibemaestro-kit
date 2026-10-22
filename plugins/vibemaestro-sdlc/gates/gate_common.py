#!/usr/bin/env python3
"""Shared helpers of the SDLC gates: exit codes, git, the repo config (from the working tree or from a git ref), strip_fences.

Exit codes of every gate: 0 pass (or not applicable), 1 red, 2 could not conclude (never green), 64 bad usage, 65 invalid config.

    python3 gate_common.py get <dotted.key> [--root DIR] [--config-ref REF]    print one effective config value

The config is read by the C2 loader `sdlc_config.py`, never parsed here. `--config-ref REF` is how CI reads it from the BASE of a PR:
a PR then cannot relax its own gate by editing `.vibemaestro/sdlc.json`. The loader sits next to this file in a repo that vendored the
gates (`.vibemaestro/gates/`) and in `../scripts` inside the plugin.

Standard library only, Python 3.8+.
"""
import os
import re
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True

OK, RED, INFRA, USAGE, CONFIG = 0, 1, 2, 64, 65

_HERE = os.path.dirname(os.path.abspath(__file__))
for _cand in (_HERE, os.path.join(_HERE, "..", "scripts")):
    if os.path.isfile(os.path.join(_cand, "sdlc_config.py")):
        sys.path.insert(0, _cand)
        break
import sdlc_config  # noqa: E402


class Infra(Exception):
    """The gate cannot conclude: not the same as red."""


class ConfigError(Exception):
    """The config is invalid; the message names the key."""


def state_home():
    """$XDG_STATE_HOME when it is absolute (a relative one is ignored), else ~/.local/state: the base of the gates' state."""
    x = os.environ.get("XDG_STATE_HOME", "")
    return x if os.path.isabs(x) else os.path.join(os.path.expanduser("~"), ".local", "state")


def git(args, cwd=".", binary=False):
    """(rc, stdout, stderr). Decoded as UTF-8 on purpose, not by the locale: subjects are not ASCII and a CI box may run `LANG=C`."""
    p = subprocess.run(["git", "-c", "core.quotePath=false"] + args, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if binary:
        return p.returncode, p.stdout, p.stderr
    return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace").strip()


def must(args, cwd="."):
    rc, out, err = git(args, cwd)
    if rc != 0:
        raise Infra("git %s failed (rc %d) %s" % (" ".join(args[:3]), rc, err[:120]))
    return out


def ref_ok(ref, cwd="."):
    return git(["rev-parse", "--verify", "--quiet", ref + "^{commit}"], cwd)[0] == 0


def read_at(root, ref, rel):
    """Text of `rel` as it is at git `ref` (None when the file is not there), or in the working tree when `ref` is None.
    A ref that does not read raises Infra: judging by "no file" a ref that cannot be read would be a silent pass."""
    if ref is None:
        path = os.path.join(root, *rel.split("/"))
        if not os.path.isfile(path):
            return None
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    if not ref_ok(ref, root):
        raise Infra("ref `%s` does not read" % ref)
    if git(["cat-file", "-e", "%s:%s" % (ref, rel)], root)[0] != 0:
        return None                      # the file is not there at that ref: the caller means "defaults"
    rc, out, err = git(["show", "%s:%s" % (ref, rel)], root, binary=True)
    if rc != 0:                          # it is there and cannot be read: not the same as absent
        raise Infra("cannot read %s at %s: %s" % (rel, ref, err.decode("utf-8", "replace")[:120]))
    return out.decode("utf-8", "replace")


def load_config_text(text, where=""):
    """The effective config for the TEXT of a config file (None: no file, so the defaults). Same loader, same messages."""
    if text is None:
        return sdlc_config.defaults()
    with tempfile.TemporaryDirectory() as tmp:
        os.makedirs(os.path.join(tmp, ".vibemaestro"))
        with open(sdlc_config.config_path(tmp), "w", encoding="utf-8") as f:
            f.write(text)
        cfg, probs, _present = sdlc_config.load(tmp)
    if probs:
        raise ConfigError(sdlc_config.render_problems(probs) + where)
    return cfg


def load_config(root, ref=None):
    """The effective config (C2 loader). Raises ConfigError with the loader's own `<file>: <key>: <reason>` lines, Infra on a bad ref."""
    if ref is None:
        cfg, probs, _present = sdlc_config.load(sdlc_config.repo_root(root))
        if probs:
            raise ConfigError(sdlc_config.render_problems(probs))
        return cfg
    return load_config_text(read_at(root, ref, sdlc_config.CONFIG_REL), " (read at %s)" % ref)


_FENCE_OPEN = re.compile(r"^ {0,3}(`{3,}|~{3,})")
_HTML_BLOCK = re.compile(r"^ {0,3}<!--")
_INLINE_COMMENT = re.compile(r"<!--.*?-->", re.S)
_CODE_SPAN = re.compile(r"(?<!`)(`+)(?!`)(.+?)(?<!`)\1(?!`)", re.S)
# a line that opens a new block ends the paragraph an inline comment could span
_PARA_BREAK = re.compile(r"^ {0,3}(?:[-*+](?:[ \t]|$)|\d{1,9}[.)](?:[ \t]|$)|#{1,6}(?:[ \t]|$)|>|[ \t]*$)")


def strip_fences(body):
    """The body without what is not a statement: fenced code blocks and HTML comments, hidden or quoted text a reader does not see
    as the author's word. Follows what GitHub renders:
      - a fence (backticks or tildes) closes with the same character, at least as long; an unclosed one runs to the end of the body;
      - a line that STARTS with `<!--` (up to 3 spaces of indent) is an HTML block: the whole line is hidden, and the lines after it up
        to the one that holds `-->` (an unclosed block hides the rest);
      - `<!-- ... -->` in the middle of a paragraph is hidden, also across lines of the same paragraph, but not inside a code span; an
        unclosed `<!--` in the middle of a line is plain text.
    Lines are split on "\n" only (str.splitlines would also split on U+2028 and other characters a renderer does not treat as a line
    break). Hidden lines become empty lines, so line numbers stay."""
    out, fence, in_html = [], None, False
    for ln in (body or "").split("\n"):
        if in_html:
            in_html = "-->" not in ln
            out.append("")
            continue
        if fence:
            if re.match(r"^ {0,3}%s{%d,}[ \t]*$" % (re.escape(fence[0]), len(fence)), ln):
                fence = None
            out.append("")
            continue
        m = _FENCE_OPEN.match(ln)
        if m:
            fence = m.group(1)
            out.append("")
            continue
        if _HTML_BLOCK.match(ln):
            in_html = "-->" not in ln[ln.index("<!--") + 4:]
            out.append("")
            continue
        out.append(ln)
    res, para = [], []

    def flush():
        if para:
            text = "\n".join(para)
            # code spans are masked with a placeholder of the same length so a `<!--` inside one opens nothing
            masked = _CODE_SPAN.sub(lambda c: "".join("\n" if ch == "\n" else "\0" for ch in c.group(0)), text)
            pieces, last = [], 0
            for c in _INLINE_COMMENT.finditer(masked):
                pieces.append(text[last:c.start()])
                pieces.append("\n" * c.group(0).count("\n"))
                last = c.end()
            pieces.append(text[last:])
            res.extend("".join(pieces).split("\n"))
            del para[:]

    for ln in out:
        if _PARA_BREAK.match(ln):
            flush()
        para.append(ln)
    flush()
    return "\n".join(res)


def run_gate(name, fn):
    """Run `fn() -> rc`, mapping the errors every gate shares to its exit codes."""
    try:
        return fn()
    except ConfigError as e:
        sys.stderr.write("%s: invalid config: %s\n" % (name, e))
        return CONFIG
    except Infra as e:
        sys.stderr.write("%s: could not conclude: %s\n" % (name, e))
        return INFRA
    except SystemExit:
        raise
    except Exception as e:   # a traceback exits 1 and reads as "red"; a fault of the gate itself is "could not conclude"
        # only the type: the text of an exception can carry the input, and the input of a scan is the sensitive text itself
        sys.stderr.write("%s: could not conclude: internal error (%s)\n" % (name, type(e).__name__))
        return INFRA


def _get_main(argv):
    root, ref, rest, i = os.getcwd(), None, [], 0
    while i < len(argv):
        if argv[i] == "--root" and i + 1 < len(argv):
            root, i = argv[i + 1], i + 2
        elif argv[i] == "--config-ref" and i + 1 < len(argv):
            ref, i = argv[i + 1], i + 2
        else:
            rest.append(argv[i])
            i += 1
    if len(rest) != 2 or rest[0] != "get":
        sys.stderr.write("usage: gate_common.py get <dotted.key> [--root DIR] [--config-ref REF]\n")
        return USAGE
    cfg = load_config(root, ref)
    try:
        v = sdlc_config.get(cfg, rest[1])
    except KeyError:
        sys.stderr.write("gate_common: no such key: %s\n" % rest[1])
        return USAGE
    import json
    sys.stdout.write((v if isinstance(v, str) else json.dumps(v, ensure_ascii=False)) + "\n")
    return OK


if __name__ == "__main__":
    sys.exit(run_gate("gate_common", lambda: _get_main(sys.argv[1:])))
