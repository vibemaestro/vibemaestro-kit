#!/usr/bin/env python3
"""Gate: the body of a PR stays short: a cap on its characters, on its summary and on its evidence.

The limits (config `pr.body.*`, ON by default, `0` turns one off):

  pr.body.max_chars            the body, in characters: CRLF read as LF, leading and trailing whitespace removed (3000)
  pr.body.summary_max_lines    the summary section, in non-empty lines (10)
  pr.body.evidence_max_lines   the evidence section, in non-empty lines (30)

Sections are found by the headings `tokens.summary_heading` and `tokens.evidence_heading`. A heading is an ATX heading of any level
(its closing `#` sequence is not part of its words), a setext one or an `<h1>`..`<h6>` line, outside a code fence. Its words are
normalised: tags, every Unicode format character (category Cf) and the blank-rendering fillers removed, every kind of space read as
one space, NFC, case folded. The summary and evidence headings match leniently: the normalised words equal the token or start with
it followed by a non-letter, after any symbols, numbers or brackets before the first letter (`## 2. Summary (round 2)`). The criteria
and flow headings must match exactly, so `### Flow diagram` is a line of the section it is in. A line inside an HTML comment block
(a line that starts with `<!--`, up to the line with `-->`) is never a heading. A section runs to the next heading that matches one
of the four tokens of the body shape (summary, criteria, evidence, flow) or the end of the body; a sub-heading of the author's own
does not end it. A section found twice counts as the sum of its parts. Lines are the non-empty ones, without the heading itself,
without a line that is only a code-fence delimiter and without the note `open_pr.py` puts as the first line of an evidence that
starts with `tokens.not_run`. The flow and criteria sections, and the lines above the summary, count toward the total only. A body
without a heading has nothing to count lines on, and is judged on what it has.

Threat model: the gate guards honest writers who are fallible, not an author who hides text on purpose; the 3000-character total is
the hard bound on every body. The fillers and format characters are removed because they appear by accident (a pasted zero-width
space), which is as far as this goes: a heading obfuscated on purpose (variation selectors or HTML entities as the space, a heading
inside a blockquote, an emphasis mark split inside the word) is not detected, and its lines may leave a section count.

`check_body(body, cfg)` returns the violations (a list of strings); `open_pr.py` calls it on the body it built.

Use:
    pr_body.py --pr N [--repo OWNER/NAME]      read the CURRENT body through `gh` (CI; a body rewritten with `gh pr edit` is read too)
    pr_body.py --body-file F                   check a file (`-`: stdin): the command to run before `gh pr edit --body-file F`
        [--config-ref REF]                     read .vibemaestro/sdlc.json at this git ref (CI: the base) instead of the working tree
        [--cwd DIR]

rc 0 pass, 1 red (each violation printed), 2 could not conclude (`gh` failed, the file cannot be read: never green), 64 usage,
65 invalid config. A red here is a signal on the PR (a repo may not make it a required check); it is not a merge blocker by itself.
Standard library only.
"""
import json
import re
import subprocess
import sys
import unicodedata

try:
    import gate_common as gc
except ImportError as e:     # a partial vendored copy must not read as "red" (a traceback exits 1)
    sys.stderr.write("%s: could not conclude: %s\n" % ("pr_body.py", e))
    sys.exit(2)

# a fence opens at up to 3 spaces of indent, or after a list marker (`- ```), and then the fence and its content are indented
_FENCE_OPEN = re.compile(r"^(?: {0,3}|[ \t]*(?:(?:[-*+]|\d{1,9}[.)])[ \t]+)+)(`{3,}|~{3,})(.*)$")
_COMMENT_START = re.compile(r"^ {0,3}<!--")      # an HTML comment BLOCK: a `<!--` in the middle of a line is plain text
_ATX = re.compile(r"^ {0,3}#{1,6}(?:[ \t]+(.*))?$")
_HTML_H = re.compile(r"^ {0,3}<h[1-6][^>]*>(.*?)(?:</h[1-6]>.*)?$", re.I)
_SETEXT_UNDERLINE = re.compile(r"^ {0,3}(?:=+|-+)[ \t]*$")
_TAG = re.compile(r"<[^>]*>")
# characters a reader does not see in a word: every Unicode format character (category Cf: zero-width, bidi marks, soft hyphen, BOM,
# tag characters) and the fillers that render blank
_FORMAT = "Cf"
_FILLERS = "\u034f\u115f\u1160\u3164\uffa0"
# the token key of each section the body shape has, in the order of the shape; only the first and the third are measured
SECTIONS = ("summary_heading", "criteria_heading", "evidence_heading", "flow_heading")
MEASURED = ("summary_heading", "evidence_heading")


def _unclose(text):
    """`text` without the optional closing sequence of an ATX heading (spaces then `#`s at the end), in linear time."""
    t = text.rstrip(" \t")
    k = len(t)
    while k and t[k - 1] == "#":
        k -= 1
    return t[:k].rstrip(" \t") if k < len(t) and (k == 0 or t[k - 1] in " \t") else t


def _clean(text, lenient):
    """The words of a heading: tags and invisible characters removed, every kind of space read as one space, NFC, case folded;
    `lenient` also drops the symbols, numbers, brackets and emphasis marks before the first letter (`## 1. Summary`)."""
    seen = "".join(ch for ch in _TAG.sub("", text) if unicodedata.category(ch) != _FORMAT and ch not in _FILLERS)
    t = " ".join(unicodedata.normalize("NFC", seen).split())
    k = 0
    while lenient and k < len(t) and not t[k].isalpha():
        k += 1
    return t[k:].casefold()


def _heading_text(line, nxt):
    """(text, setext) of the heading `line` starts, or None. `nxt` is the next line, for the setext form."""
    line = line.rstrip()
    m = _ATX.match(line) or _HTML_H.match(line)
    if m:
        return _unclose(m.group(1) or ""), False
    if line.strip() and nxt is not None and _SETEXT_UNDERLINE.match(nxt) and not line.startswith(("    ", "\t")):
        return line, True
    return None


def _kind(text, tokens):
    """The section key whose heading token `text` equals or starts with (the longest token wins), else None. The summary and
    evidence tokens match leniently (a prefix, symbols or numbers before the first letter: `## 2. Run evidence (round 2)`), because an
    honest writer decorates them; the criteria and flow tokens must match exactly, so that a sub-heading such as `### Flow diagram`
    does not end a section."""
    best = None
    for key in SECTIONS:
        lenient = key in MEASURED
        t, tok = _clean(text, lenient), _clean(tokens[key], lenient)
        if tok and (t == tok or (lenient and t.startswith(tok) and not t[len(tok)].isalnum())):
            if best is None or len(tok) > best[0]:
                best = (len(tok), key)
    return best[1] if best else None


def section_lines(body, tokens):
    """{key: non-empty lines} for the summary and the evidence section of `body`, as `check_body` counts them. A line inside an HTML
    comment block is a line of the section it is in, never a heading (GitHub does not render it). The note `open_pr.py` adds as the
    first line of an evidence that starts with `tokens.not_run` is the kit's own line: it is not counted, and only that one."""
    lines = body.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    counts = {key: 0 for key in MEASURED}
    note = tokens.get("not_run_note", "").strip()
    fence = cur = None
    comment = note_open = False
    i = 0

    def count(text):
        nonlocal note_open
        t = text.strip()
        if not t or cur not in counts:
            return
        if note_open:
            note_open = False
            if t == note:
                return
        counts[cur] += 1

    while i < len(lines):
        ln = lines[i]
        i += 1
        if fence:
            if re.match(r"^[ \t]*%s{%d,}[ \t]*$" % (re.escape(fence[0]), len(fence)), ln):
                fence = None
            else:
                count(ln)
            continue
        if comment:
            count(ln)
            comment = "-->" not in ln
            continue
        m = _COMMENT_START.match(ln)
        if m:
            count(ln)
            comment = "-->" not in ln[m.end() - 2:]      # `<!-->` is a comment that ends where it starts
            continue
        m = _FENCE_OPEN.match(ln)
        if m and not (m.group(1)[0] == "`" and "`" in m.group(2)):
            fence = m.group(1)
            continue
        h = _heading_text(ln, lines[i] if i < len(lines) else None)
        if h is not None:
            kind = _kind(h[0], tokens)
            if kind:
                cur, note_open = kind, kind == "evidence_heading"
                i += 1 if h[1] else 0      # the underline of a setext heading is part of it
                continue
        count(ln)
    return counts


def check_body(body, cfg):
    """The violations of the limits `cfg["pr"]["body"]` for `body`: a list of strings, empty when the body is within them. Pure."""
    lim, tokens = cfg["pr"]["body"], cfg["tokens"]
    body = body or ""
    out = []
    n = len(body.replace("\r\n", "\n").strip())
    if lim["max_chars"] and n > lim["max_chars"]:
        out.append("the body is %d characters, over pr.body.max_chars (%d)" % (n, lim["max_chars"]))
    if lim["summary_max_lines"] or lim["evidence_max_lines"]:
        counts = section_lines(body, tokens)
        for key, limit_key in (("summary_heading", "summary_max_lines"), ("evidence_heading", "evidence_max_lines")):
            if lim[limit_key] and counts[key] > lim[limit_key]:
                out.append("the `%s` section has %d non-empty lines, over pr.body.%s (%d)" % (tokens[key], counts[key], limit_key, lim[limit_key]))
    return out


def report(violations, cfg):
    """The text printed for a red: each violation on its own line, then where the detail goes."""
    tk = cfg["tokens"]
    return ("\n".join("  - " + v for v in violations)
            + "\nKeep the body to the current state: what outlives the PR goes to a spec or a decision in kb/, what happened in a round goes "
              "in a comment that starts with `%s` and the head SHA. The limits are pr.body.max_chars, pr.body.summary_max_lines and "
              "pr.body.evidence_max_lines in .vibemaestro/sdlc.json (0 turns one off)." % tk["round_comment_prefix"])


def _gh_body(pr, repo):
    args = ["gh", "pr", "view", pr] + (["-R", repo] if repo else []) + ["--json", "body"]
    try:
        p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise gc.Infra("gh could not run: %s" % e)
    if p.returncode != 0:
        raise gc.Infra("gh pr view failed: %s" % p.stderr.decode("utf-8", "replace").strip()[:160])
    try:
        data = json.loads(p.stdout.decode("utf-8", "replace"))
    except ValueError:
        raise gc.Infra("gh pr view did not print JSON")
    if not isinstance(data, dict) or not isinstance(data.get("body"), (str, type(None))) or "body" not in data:
        raise gc.Infra("gh pr view printed no `body`")
    return data.get("body") or ""


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    pr = repo = ref = path = None
    cwd = "."
    i = 0
    while i < len(argv):
        k = argv[i]
        if k in ("--pr", "--repo", "--config-ref", "--cwd", "--body-file") and i + 1 < len(argv):
            v = argv[i + 1]
            if k == "--pr":
                pr = v
            elif k == "--repo":
                repo = v
            elif k == "--config-ref":
                ref = v
            elif k == "--body-file":
                path = v
            else:
                cwd = v
            i += 2
        else:
            pr = False
            break
    if pr is False or (pr is None) == (path is None) or (repo and pr is None):
        sys.stderr.write("usage: pr_body.py (--pr N [--repo OWNER/NAME] | --body-file F|-) [--config-ref REF] [--cwd DIR]\n")
        return gc.USAGE
    cfg = gc.load_config(cwd, ref)
    if pr is not None:
        body, what = _gh_body(pr, repo), "#%s" % pr
    elif path == "-":
        body, what = sys.stdin.buffer.read().decode("utf-8", "replace"), "stdin"
    else:
        try:
            with open(path, "rb") as f:
                body, what = f.read().decode("utf-8", "replace"), path
        except OSError as e:
            raise gc.Infra("cannot read %s: %s" % (path, e.__class__.__name__))
    violations = check_body(body, cfg)
    if violations:
        print("FAIL %s: the body is over its cap\n%s" % (what, report(violations, cfg)))
        return gc.RED
    print("ok   %s: the body is within pr.body.* (%d characters)" % (what, len(body.replace("\r\n", "\n").strip())))
    return gc.OK


if __name__ == "__main__":
    sys.exit(gc.run_gate("pr-body", main))
