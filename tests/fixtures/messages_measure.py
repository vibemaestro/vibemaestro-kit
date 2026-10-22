#!/usr/bin/env python3
"""The wide measure of tests/test-messages-language.sh: a Vietnamese letter in a string the scripts can print.

    messages_measure.py <sdlc plugin dir> <brain plugin dir>

Over sdlc `scripts/` and `gates/` and brain `scripts/`, every Python string token that holds a Vietnamese letter (the tokenizer
drops comments; a docstring does not count, except the module docstring of a file that prints `__doc__`), and every shell line
that holds one outside its comment, is put in a class:
  vi-branch  the value of a `"vi"` key in a dict literal (messages.TABLE, kb.py's README / CURRENT_STATE / TEMPLATES / …)
  parsing    a pattern or word list that reads BOTH languages (PARSING below, by file and top-level name)
  vi-default the plugin's `vi` defaults that LANGUAGE_PRESETS["en"] lays English over (sdlc_config.py DEFAULTS, DEFAULT_FLOW)
  shell-vi   the `vi` arm of the shell refusals printed before python3 and the table are known to run (SHELL_VI below)
Anything else is printed as `UNCLASSIFIED <file>:<line>: <text>` and the exit code is 1. The last line is the count per class.
"""
import ast
import io
import os
import re
import sys
import tokenize

VI = re.compile(r"[àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđ"
                r"ÀÁẠẢÃÂẦẤẬẨẪĂẰẮẶẲẴÈÉẸẺẼÊỀẾỆỂỄÌÍỊỈĨÒÓỌỎÕÔỒỐỘỔỖƠỜỚỢỞỠÙÚỤỦŨƯỪỨỰỬỮỲÝỴỶỸĐ]")
PARSING = {   # file → the top-level names whose strings read both languages (never printed as a message)
    "current_state.py": {"_W", "_COUNT_AFTER", "_COUNT_BEFORE", "_RANK_BEFORE", "HISTORY", "HEADING_HISTORY", "_OVER_TEXT"},
    "kb_plan.py": {"COLUMNS", "DECISIONS_RX", "DROPPED_RX", "NONE_CELL"},
    "kb_index.py": {"fold"},
    "pr_evidence.py": {"E2E_SKIP"},
}
VI_DEFAULT = {"sdlc_config.py": {"DEFAULTS", "DEFAULT_FLOW"}}
SHELL_VI = {'if shell_en; then die "the core is missing: $f" 2; else die "thiếu lõi $f" 2; fi',
            'if shell_en; then die "no \\`python3\\`" 2; else die "không có \\`python3\\`" 2; fi'}


def top_names(tree):
    """{line: name of the top-level statement that holds it}."""
    out = {}
    for st in tree.body:
        name = None
        if isinstance(st, (ast.FunctionDef, ast.ClassDef)):
            name = st.name
        elif isinstance(st, ast.Assign) and isinstance(st.targets[0], ast.Name):
            name = st.targets[0].id
        if name:
            for ln in range(st.lineno, st.end_lineno + 1):
                out[ln] = name
    return out


def vi_lines(tree):
    """The lines of every value of a `"vi"` key in a dict literal."""
    out = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Dict):
            for k, v in zip(node.keys, node.values):
                if isinstance(k, ast.Constant) and k.value == "vi":
                    out.update(range(v.lineno, v.end_lineno + 1))
    return out


def docstring_lines(tree, keep_module=False):
    out = set()
    for node in ast.walk(tree):
        if keep_module and isinstance(node, ast.Module):
            continue
        if isinstance(node, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) and node.body:
            b = node.body[0]
            if isinstance(b, ast.Expr) and isinstance(b.value, ast.Constant) and isinstance(b.value.value, str):
                out.update(range(b.lineno, b.end_lineno + 1))
    return out


def classify_py(path, counts, bad):
    src = open(path, encoding="utf-8").read()
    tree = ast.parse(src)
    fn = os.path.basename(path)
    doc = docstring_lines(tree, keep_module="__doc__" in src)
    vi, names, lines = vi_lines(tree), top_names(tree), src.splitlines()
    seen = set()
    for tok in tokenize.generate_tokens(io.StringIO(src).readline):
        if tok.type != tokenize.STRING and tok.type != getattr(tokenize, "FSTRING_MIDDLE", -1):
            continue
        for i, part in enumerate(tok.string.splitlines(), tok.start[0]):
            if not VI.search(part) or i in doc or i in seen:
                continue
            seen.add(i)
            if i in vi:
                counts["vi-branch"] += 1
            elif names.get(i) in PARSING.get(fn, ()):
                counts["parsing"] += 1
            elif names.get(i) in VI_DEFAULT.get(fn, ()):
                counts["vi-default"] += 1
            else:
                bad.append("%s:%d: %s" % (path, i, lines[i - 1].strip()[:160]))


def code_of(line):
    """A shell line without its comment: from the first `#` that starts a word outside quotes."""
    q = None
    for i, c in enumerate(line):
        if q:
            q = None if c == q else q
        elif c in "'\"":
            q = c
        elif c == "#" and (i == 0 or line[i - 1] in " \t"):
            return line[:i]
    return line


def classify_sh(path, counts, bad):
    for i, ln in enumerate(open(path, encoding="utf-8"), 1):
        s = code_of(ln).strip()
        if not VI.search(s) or s.startswith("#"):
            continue
        if s in SHELL_VI:
            counts["shell-vi"] += 1
        else:
            bad.append("%s:%d: %s" % (path, i, s[:160]))


def main(argv):
    sdlc, brain = argv[1:3]
    counts = {"vi-branch": 0, "parsing": 0, "vi-default": 0, "shell-vi": 0}
    bad = []
    for top in (os.path.join(sdlc, "scripts"), os.path.join(sdlc, "gates"), os.path.join(brain, "scripts")):
        for d, subs, files in sorted(os.walk(top)):
            subs[:] = sorted(s for s in subs if s != "__pycache__")
            for fn in sorted(files):
                p = os.path.join(d, fn)
                if fn.endswith(".py"):
                    classify_py(p, counts, bad)
                elif fn.endswith(".sh"):
                    classify_sh(p, counts, bad)
    for b in bad:
        print("UNCLASSIFIED " + b)
    print("lines: %s, unclassified %d" % (", ".join("%s %d" % kv for kv in counts.items()), len(bad)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
