#!/usr/bin/env python3
"""The plugin code that points to the BatonRun standard stays true to the runner.

  python3 -I -B batonrun_standard_check.py <root>

Reads form only, never meaning. Checks (plugin code only: the documents themselves are not tested):
  - the stop list of the skill core and STOP_WORDS of baton.py are the same words in the same order;
  - the skill core, the rule and the BatonRun bullet of the workflow core name the standard docs/batonrun.md.
Prints one line per problem, then a last line `<n> checks, <m> problems`; rc 0 when there is none, 1 otherwise, 2 on bad usage.
"""
import ast
import os
import re
import sys

SDLC = "plugins/vibemaestro-sdlc"
SKILL = SDLC + "/skills/batonrun/SKILL.md"
RULE = SDLC + "/rules/batonrun.instructions.md"
CORE = SDLC + "/rules/workflow-core.instructions.md"
BATON = SDLC + "/scripts/baton.py"
POINTERS = (SKILL, RULE)


def read(root, rel):
    try:
        with open(os.path.join(root, rel), encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None


def section(text, title):
    """The body of the `## <n>. <title>` section, up to the next `## ` heading."""
    m = re.search(r"^## (?:\d+\. )?%s\b.*$" % re.escape(title), text, re.M)
    if not m:
        return None
    rest = text[m.end():]
    n = re.search(r"^## ", rest, re.M)
    return rest[: n.start()] if n else rest


def baton_constant(src, name):
    for node in ast.parse(src).body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == name for t in node.targets):
            return list(ast.literal_eval(node.value))
    return None


def main(argv):
    if len(argv) != 2:
        print(__doc__.strip().splitlines()[2].strip())
        return 2
    root = argv[1]
    problems, checks = [], 0

    def need(cond, msg):
        nonlocal checks
        checks += 1
        if not cond:
            problems.append(msg)

    # the stop list: the skill core and the runner
    src = read(root, BATON) or ""
    words = baton_constant(src, "STOP_WORDS") if src else None
    need(bool(words), "%s: no STOP_WORDS" % BATON)
    skill = read(root, SKILL) or ""
    stop = section(skill, "Stop list") or ""
    skill_words = re.findall(r"^- `([a-z-]+)`:", stop, re.M)
    if words:
        need(skill_words == words, "%s: the stop list %s is not baton.py's %s" % (SKILL, skill_words, words))

    # the pointers
    for rel in POINTERS:
        text = read(root, rel)
        need(text is not None and "docs/batonrun.md" in text,
             "%s: does not name the standard docs/batonrun.md" % rel)
    core = read(root, CORE) or ""
    bullet = re.search(r"^- \*\*[^*\n]*BatonRun[^*\n]*\*\*.*?(?=^- \*\*|\Z)", core, re.M | re.S)
    need(bullet is not None, "%s: no BatonRun bullet" % CORE)
    if bullet:
        need("docs/batonrun.md" in bullet.group(0), "%s: the BatonRun bullet does not name the standard" % CORE)

    for p in problems:
        print(p)
    print("%d checks, %d problems" % (checks, len(problems)))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
