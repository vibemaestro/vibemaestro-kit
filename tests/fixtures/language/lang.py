#!/usr/bin/env python3
"""Helpers of tests/test-language.sh (standard library only).

    lang.py bodies <scripts dir> <repo root> <out dir>
        the PR bodies `open_pr.build_body` builds under the config of <repo root> (none: the defaults), one file per case:
        body-plain.md, body-long.md (cut evidence, criteria, fixes, closes), body-notrun.md (the not-run token first),
        body-fences.md (evidence holding triple and quadruple backtick fences, a line of five backticks, a `## ` line and tildes)
    lang.py viet <file>...
        prints `<count> <file>`: the letters that only Vietnamese spelling uses here (a Latin letter with a diacritic, or the d
        with stroke); exit 1 when any file has one
    lang.py fences <body file> <evidence file>
        checks the body the way a CommonMark reader opens and closes fences: exactly one code block, it holds the evidence verbatim,
        and every `## ` heading of the body is outside it; prints the problems, exit 1 when there is one
"""
import os
import re
import sys
import unicodedata

sys.dont_write_bytecode = True

LONG_EV = "\n".join("line %d" % i for i in range(120))
FENCED_EV = "\n".join([
    "$ cat report.md",
    "```bash",
    "echo hi",
    "```",
    "## Context",
    "````md",
    "```",
    "nested",
    "```",
    "````",
    "`````",
    "inline run ```` of four",
    "~~~",
    "tilde block",
    "~~~",
    "end",
])


def bodies(scripts, root, out):
    sys.path.insert(0, scripts)
    import open_pr
    import sdlc_config
    cfg, probs, _present = sdlc_config.load(root)
    if probs:
        sys.stderr.write("invalid config: %s\n" % probs)
        return 2
    nr = cfg["tokens"]["not_run"]
    cases = {
        "plain": dict(summary="Did X.", evidence="$ make test\nok"),
        "long": dict(summary="Did X.", evidence=LONG_EV, crit="1. `a` -> b\n- [x] c", fixes="98, #96", closes="12"),
        "notrun": dict(summary="Did X.", evidence=nr + " docs only", crit="one"),
        "fences": dict(summary="Did X.", evidence=FENCED_EV),
    }
    for k, kw in cases.items():
        with open(os.path.join(out, "body-%s.md" % k), "w", encoding="utf-8") as f:
            f.write(open_pr.build_body(cfg=cfg, **kw))
    with open(os.path.join(out, "evidence-fences.txt"), "w", encoding="utf-8") as f:
        f.write(FENCED_EV)
    return 0


def is_viet(ch):
    if ch in "đĐ":
        return True
    return ch.isalpha() and ord(ch) > 127 and any(unicodedata.combining(c) for c in unicodedata.normalize("NFD", ch))


def viet(files):
    rc = 0
    for p in files:
        with open(p, encoding="utf-8") as f:
            n = sum(1 for ch in f.read() if is_viet(ch))
        print("%d %s" % (n, p))
        rc = rc or (1 if n else 0)
    return rc


OPEN = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")


def blocks(lines):
    """[(first content line, line after the last content line)] of the fenced code blocks, CommonMark style: a fence closes on a
    run of the same character at least as long as the one that opened it, with nothing after it but spaces."""
    out, i = [], 0
    while i < len(lines):
        m = OPEN.match(lines[i])
        if m and not (m.group(1)[0] == "`" and "`" in m.group(2)):
            ch, n, j = m.group(1)[0], len(m.group(1)), i + 1
            close = re.compile(r"^ {0,3}%s{%d,}[ \t]*$" % (re.escape(ch), n))
            while j < len(lines) and not close.match(lines[j]):
                j += 1
            out.append((i + 1, j))
            i = j + 1
        else:
            i += 1
    return out


def fences(body_path, ev_path):
    with open(body_path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    with open(ev_path, encoding="utf-8") as f:
        ev = f.read()
    bl = blocks(lines)
    probs = []
    if len(bl) != 1:
        probs.append("%d code blocks, expected 1: %s" % (len(bl), bl))
    elif "\n".join(lines[bl[0][0]:bl[0][1]]) != ev:
        probs.append("the code block does not hold the evidence verbatim")
    inside = set(i for a, b in bl for i in range(a, b))
    heads = [ln for i, ln in enumerate(lines) if i not in inside and ln.startswith("## ")]
    if len(heads) != 2:
        probs.append("headings outside code blocks: %s (expected summary and evidence; a body has no flow section)" % heads)
    for p in probs:
        print(p)
    return 1 if probs else 0


def main(argv):
    if argv[:1] == ["bodies"] and len(argv) == 4:
        return bodies(*argv[1:])
    if argv[:1] == ["viet"] and len(argv) > 1:
        return viet(argv[1:])
    if argv[:1] == ["fences"] and len(argv) == 3:
        return fences(*argv[1:])
    sys.stderr.write(__doc__)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
