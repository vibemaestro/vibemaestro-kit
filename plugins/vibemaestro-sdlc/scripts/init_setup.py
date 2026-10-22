#!/usr/bin/env python3
"""`kb.py init` for a repo that adopts the plugin: the `kb/` scaffold, the per-repo config and the rules scaffold.

Called by `kb.py` (which owns the `kb/` templates and the config check); not a command of its own.

    kb.py init [--answers F.json] [--lang vi|en] [--adopt [--detect]] [--dry-run]

  default      an app repo: `kb/` scaffold, `.vibemaestro/sdlc.json`, `<rules dir>/README.md` and `example.instructions.md`.
  --adopt      a repo that already has process files: the same, but no rule file is written and no existing file is touched;
               the report says what the repo does by hand and what the plugin does after.
  --detect     (only with --adopt) read the repo and PROPOSE `rules.dirs`, `current_state.path` and `.table`, `sensitive.allowlist`,
               `ci.runner_default`. Never writes; answers win over proposals.
               Paths git ignores are not read.
  --answers F  a JSON object in the shape of the config (any subset, up to every key of the schema). Validated, with everything
               it is layered over, before the first write: rc 65 and nothing written. An empty F is rc 64.
  --lang L     the answer `language: L`, laid over `--answers`: a new config records it, and the scaffold (`kb/README.md`, the
               current-state skeleton) is written in it. The scaffold always speaks the language of the config in force, the one
               `kb.py check spec` and `kb.py new` read; a config that exists is never rewritten, so a `--lang` (or an answer
               `language`) that differs from its language is rc 64 and nothing is written. Without either: a new config records
               `en`; an existing one keeps its `language` (absent: `vi`).
  --dry-run    validate, print the proposal and the report, write nothing.

The file written is `schema` plus the scaffold keys, the detected values and the answers (later layer wins key by key; `_` keys of
the answers are kept). It is not a copy of the defaults: a later plugin version's defaults still reach the repo. An existing config is
never rewritten; `would add <key>` and `differs <key>` say what the detected and answered values would change. Every file is
written only if absent (`open(..., "x")`). rc: 0 done · 64 usage · 65 answers or config invalid · 66 answers file cannot be read.
Standard library only, Python 3.8+.
"""
import copy
import functools
import json
import os
import re
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import current_state as CS  # noqa: E402
import rules as R  # noqa: E402
import sdlc_config as C  # noqa: E402
import vsdlc  # noqa: E402

# the paths the guarded merge (gates/merge_guard.py) refuses in its normal lane, written explicitly: unset, the guard refuses every
# PR. The list the init-kb skill proposes (tests/test-init-setup.sh reads both); an answer replaces it, `[]` included
DENY_DEFAULT = list(C.MERGE_DENY_DEFAULT)
# A new config always records `language`: `en` unless answered. The code default stays `vi` for a config without the key (the repos
# made before, the floor reader and the gates vendored into repos all read it so), so a new repo never depends on that default.
NEW_LANGUAGE = "en"
APP_SCAFFOLD = {"schema": 1, "language": NEW_LANGUAGE, "rules": {"dirs": [".vibemaestro/rules"]},
                "current_state": {"template": "ledger"}, "merge": {"deny_globs": DENY_DEFAULT}}
ADOPT_SCAFFOLD = {"schema": 1, "language": NEW_LANGUAGE, "merge": {"deny_globs": DENY_DEFAULT}}
EXAMPLE_NAME = "example.instructions.md"
SKIP_DIRS = {".git", ".claude", "node_modules", "__pycache__", ".venv", "venv"}

RULES_README = """# Rules of this repo

Rule files that the `vibemaestro-sdlc` plugin delivers next to its own rules. This directory is listed in `rules.dirs` of
`.vibemaestro/sdlc.json`; the plugin reads it on every edit and every shell command.

A rule is `<name>.instructions.md`: a short frontmatter, then the text of the reminder.

- `applyTo: "<glob>,<glob>"`: reminded when a file that matches is edited.
- `applyWhen: "<regex>"`: reminded when a shell command that matches is about to run.
- `description:` one line shown in the rule catalogue. `level: block` makes a command rule stop the command.
- `status:` anything but `active` (the default) means the rule is not delivered, which is how `example.instructions.md` stays quiet.

A file with the same name as a plugin rule replaces it; `rules.disable` in the config turns a plugin rule off. Keep a rule short and
state the order, not the history: a reminder that is long gets skimmed.
"""

RULES_EXAMPLE = """---
applyTo: "docs/**"
status: example
description: "Example rule, never delivered: copy it, set status to active and write your own"
---

# Example rule

Replace this text with one instruction that is easy to get wrong in this repo: say what to do, why, and the command that
proves it. This file is never delivered while its `status` is `example`.
"""


# ── layers ───────────────────────────────────────────────────────────────────────────────────────
def layer(base, over):
    """`over` laid on `base`: objects merge key by key, everything else (lists, scalars, null) replaces. `_` keys of `over` are kept,
    so a comment in the answers is written as it was given."""
    out = copy.deepcopy(base)
    for k, v in over.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict) and not k.startswith("_"):
            out[k] = layer(out[k], v)
        else:
            out[k] = copy.deepcopy(v)
    return out


def leaves(d, prefix=""):
    """{dotted key: value} of the non-object values of a config-shaped dict (an empty object counts as a value); `_` keys and
    `schema` are not compared."""
    out = {}
    for k, v in d.items():
        if k.startswith("_") or (not prefix and k == "schema"):
            continue
        key = prefix + k
        if isinstance(v, dict) and v:
            out.update(leaves(v, key + "."))
        else:
            out[key] = v
    return out


def dig(d, dotted, default=None):
    cur = d
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return default
        cur = cur[part]
    return cur


def j(v):
    return json.dumps(v, ensure_ascii=False)


# ── detect ───────────────────────────────────────────────────────────────────────────────────────
@functools.lru_cache(maxsize=None)              # one git call per root: detect walks the tree twice
def _ignored(root):
    """The paths git ignores here (a directory ends in `/`): a rule or a ledger in `build/` or `dist/` is a copy, not the repo's own.
    Empty when git cannot say (not a repo, no git): then only SKIP_DIRS is skipped."""
    out = vsdlc.git_out(root, "ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory")
    return {p.rstrip("/") for p in (out or "").split("\0") if p}


def _walk(root):
    ignored = _ignored(root)
    for dp, dns, fns in os.walk(root):
        rel = os.path.relpath(dp, root).replace(os.sep, "/")
        pre = "" if rel == "." else rel + "/"
        dns[:] = sorted(d for d in dns if d not in SKIP_DIRS and pre + d not in ignored)
        yield rel, sorted(f for f in fns if pre + f not in ignored)


def _rules_dirs(root):
    out = []
    for rel, fns in _walk(root):
        for fn in fns:
            if fn.endswith(R.RULE_SUFFIX) and R.front(R._read(os.path.join(root, rel, fn)) or "", "applyTo"):
                out.append(rel)
                break
    return [d for d in out if d != "."]


def _current_state(root):
    """(relative path, table width or None): the default path when the file exists, else the one `current-state.md` of the repo.
    The width is proposed only when the file has tables and they all have the same number of columns (a `table` entry applies to
    every table the `tables` entries do not name)."""
    default = C.DEFAULTS["current_state"]["path"]
    rel = default if os.path.isfile(os.path.join(root, *default.split("/"))) else None
    if rel is None:
        found = [(d + "/" if d != "." else "") + fn for d, fns in _walk(root) for fn in fns if fn == "current-state.md"]
        rel = found[0] if len(found) == 1 else None
    if rel is None:
        return None, None
    try:
        with open(os.path.join(root, *rel.split("/")), "rb") as f:
            tabs = CS._tables(CS._lines(f.read()))
    except (OSError, ValueError):
        return rel, None
    widths = {len(CS._cells(t[1][0][1])) for t in tabs}
    return rel, (widths.pop() if len(widths) == 1 else None)


_RUNS_ON = re.compile(r"^\s*(?:-\s+)?runs-on:\s*(.+?)\s*(?:#.*)?$")
_FALLBACK = re.compile(r"""^\$\{\{\s*vars\.\w+\s*\|\|\s*(['"])([^'"]+)\1\s*\}\}$""")


def _runner(root):
    """The commonest `runs-on` label of the workflows: a plain label, or the fallback label of `${{ vars.X || 'label' }}`; a list or
    any other expression is skipped. Ties go to the smaller label, so the answer does not depend on file order."""
    wf = os.path.join(root, ".github", "workflows")
    count = {}
    try:
        names = sorted(n for n in os.listdir(wf) if n.endswith((".yml", ".yaml")))
    except OSError:
        return None
    for n in names:
        for line in (R._read(os.path.join(wf, n)) or "").split("\n"):
            m = _RUNS_ON.match(line)
            if not m:
                continue
            v = m.group(1).strip()
            fb = _FALLBACK.search(v)
            label = fb.group(2) if fb else (None if v.startswith(("[", "$", "{", "|", ">", "&", "*", "!")) else v.strip("'\""))
            if label:
                count[label] = count.get(label, 0) + 1
    return sorted(count, key=lambda k: (-count[k], k))[0] if count else None


def detect(root):
    """The proposal in the shape of the config. Reads only; every field is optional."""
    prop = {}
    dirs = _rules_dirs(root)
    if dirs:
        prop["rules"] = {"dirs": dirs}
    path, width = _current_state(root)
    if path:
        prop["current_state"] = {"path": path}
        if width:
            prop["current_state"]["table"] = {"columns": width, "required": True}
    allow = C.DEFAULTS["sensitive"]["allowlist"]
    if os.path.isfile(os.path.join(root, *allow.split("/"))):
        prop["sensitive"] = {"allowlist": allow}
    runner = _runner(root)
    if runner:
        prop["ci"] = {"runner_default": runner}
    return prop


# ── answers, validation ──────────────────────────────────────────────────────────────────────────
def read_answers(path):
    """(dict, None) or (None, (rc, message))."""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except OSError as e:                                            # missing, a directory, no permission: nothing to read
        return None, (66, "answers file cannot be read: %s (%s)" % (path, e.strerror or type(e).__name__))
    except (ValueError, RecursionError) as e:
        return None, (65, "answers file %s is not valid JSON: %s" % (path, " ".join(str(e).split())[:200]))
    if not isinstance(data, dict):
        return None, (65, "answers file %s: the top level must be a JSON object" % path)
    return data, None


def parse(argv):
    """(options, None) or (None, message)."""
    o = {"adopt": False, "detect": False, "dry": False, "answers": None, "lang": None}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--adopt":
            o["adopt"] = True
        elif a == "--detect":
            o["detect"] = True
        elif a == "--dry-run":
            o["dry"] = True
        elif a == "--answers" and i + 1 < len(argv) and o["answers"] is None:
            if not argv[i + 1]:
                return None, "--answers needs a file path; an empty value is not \"no answers\" (leave the flag out for that)"
            o["answers"], i = argv[i + 1], i + 1
        elif a == "--lang" and i + 1 < len(argv) and o["lang"] is None:
            if argv[i + 1] not in C.LANGUAGES:
                return None, "--lang must be one of %s" % ", ".join(C.LANGUAGES)
            o["lang"], i = argv[i + 1], i + 1
        else:
            return None, "unknown or repeated argument: %s" % a
        i += 1
    if o["detect"] and not o["adopt"]:
        return None, "--detect is only for --adopt (an app repo has nothing to detect)"
    return o, None


# ── writing ──────────────────────────────────────────────────────────────────────────────────────
def unfit(root, rels):
    """[problem] for the paths `init` would write: a parent that exists and is not a directory (the write would crash half way), or a
    parent that is a link leading out of the repo (a rules directory must be inside it). Checked before the first write."""
    real_root, bad = os.path.realpath(root), []
    for rel in rels:
        cur = root
        for part in rel.split("/")[:-1]:
            cur = os.path.join(cur, part)
            if not os.path.lexists(cur):
                break
            real = os.path.realpath(cur)
            if not os.path.isdir(cur):
                bad.append("%s is not a directory, so %s cannot be written" % (os.path.relpath(cur, root), rel))
                break
            if real != real_root and not real.startswith(real_root + os.sep):
                bad.append("%s leads outside the repo, so %s cannot be written" % (os.path.relpath(cur, root), rel))
                break
    return bad


def write_new(path, text):
    """True when written; an existing file is left alone (`x` fails even on a race)."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    try:
        with open(path, "x", encoding="utf-8") as f:
            f.write(text)
    except FileExistsError:
        return False
    return True


# said once by every run, because a repo that installs the gates later should hear it before its first PR waits on a runner that never starts
DENY_NOTE = ("merge.deny_globs = %s: the paths the guarded merge refuses in its normal lane, written so a PR of this repo can be "
             "merged by kit:merge-pr (unset, the guard refuses every PR); edit it in the config, [] is a valid answer")
DENY_UNSET_NOTE = ("merge.deny_globs is unset (the answers say null): the guarded merge refuses every PR of this repo until the "
                   "config lists the paths it refuses ([] is a valid answer)")
RUNNER_NOTE = ("CI runner: install-gates will check, read-only through gh, that the repo variable %s is set; unset or empty, the "
               "workflows fall back to a fallback runner label (ubuntu-latest, GitHub-hosted, unless the repo names another), and where "
               "hosted minutes are locked the gates never start")


def table_cols(basis, template):
    """Width of the table the current-state skeleton must carry to pass the gate of its own profile: `current_state.table.columns`
    when the config names one, else the width of the `map` preset when the template is `map` and the config says nothing, else none."""
    cs = dig(basis, "current_state") or {}
    if isinstance(cs.get("table"), dict):
        return cs["table"]["columns"]
    if template == "map" and "table" not in cs:
        return C.PRESETS["map"]["table"]["columns"]
    return None


def run(root, argv, kb_plan, config_check, config_notices):
    """The whole of `kb.py init`. `kb_plan(root, state_rel, template, table_cols)` -> [(rel, text|None)]: the files of the `kb/` scaffold (None = a
    directory that already holds files, kept as it is; the current-state skeleton follows the template); `config_check(root)` -> rc; `config_notices(root, cfg)` -> [lines]."""
    o, err = parse(argv)
    if err:
        sys.stderr.write("kb: init: %s\n" % err)
        return 64
    cfg, _probs, present = C.load(root)                             # kb.py has already exited 65 on an invalid config
    answers = {}
    if o["answers"]:
        answers, e = read_answers(o["answers"])
        if e:
            sys.stderr.write("kb: init: %s\n" % e[1])
            return e[0]
    if o["lang"]:
        answers = layer(answers, {"language": o["lang"]})
    prop = detect(root) if o["detect"] else {}
    inputs = layer(prop, answers)                                   # what the person and the detection say
    composed = layer(layer(ADOPT_SCAFFOLD if o["adopt"] else APP_SCAFFOLD, prop), answers)
    composed.setdefault("schema", 1)
    bad = C.problems(composed, strict=True)                         # the rules that span keys too, and no unknown key: refused before the first write
    if bad:
        sys.stderr.write("kb: init: the answers%s are invalid (%d problem(s)); nothing was written:\n%s\n"
                         % (" and the detected values" if o["detect"] else "", len(bad), C.render_problems(bad, "answers")))
        return 65
    try:
        cfg_text = json.dumps(composed, indent=2, ensure_ascii=False) + "\n"
        cfg_text.encode("utf-8")                                    # a lone surrogate in a `_` key passes validation but cannot be written
    except (UnicodeEncodeError, ValueError, RecursionError) as e:
        sys.stderr.write("kb: init: the answers cannot be written as UTF-8 JSON (%s); nothing was written\n" % e)
        return 65
    # ── plan, check that every path can be written, then write ──
    basis = cfg if present else composed                            # the config that will be in force (the file's, else the one about to be written)
    scaffold_cfg = cfg if present else C.effective(composed)        # the scaffold speaks the language of that config, the one the checks will use
    want = answers.get("language")                                  # --lang, else the answers file
    if want and scaffold_cfg["language"] != want:
        sys.stderr.write("kb: init: the language asked is %s, but %s is in force with language %s and is never rewritten; nothing was "
                         "written. Set \"language\": \"%s\" in it first (a repo with installed gates refreshes .vibemaestro/gates/"
                         "sdlc_config.py too, see the install-gates skill), then re-run init\n" % (want, C.CONFIG_REL, scaffold_cfg["language"], want))
        return 64
    state_rel = dig(basis, "current_state.path") or C.DEFAULTS["current_state"]["path"]
    template = dig(basis, "current_state.template") or "ledger"
    rule_dirs = dig(basis, "rules.dirs")
    plan = []                                                       # (label rel path, text or None for "kept as is")
    plan.extend(kb_plan(root, state_rel, template, table_cols(basis, template), scaffold_cfg))
    cfg_rel = C.CONFIG_REL
    plan.append((cfg_rel, None if present else cfg_text))
    notes, soft = [], set()                                         # `soft`: scaffold files a repo's own rules make unwelcome
    if not o["adopt"] and rule_dirs:
        rd = rule_dirs[0]
        here = os.path.join(root, *rd.split("/"))
        own = [n for n in (os.listdir(here) if os.path.isdir(here) else []) if n.endswith(R.RULE_SUFFIX) and n != EXAMPLE_NAME]
        for rel, text in ((rd + "/README.md", RULES_README), (rd + "/" + EXAMPLE_NAME, RULES_EXAMPLE)):
            plan.append((rel, text))
            if own:
                soft.add(rel)
        if own:
            notes.append("no rules scaffold written in %s: the directory already holds rule files of this repo" % rd)
    elif not o["adopt"]:
        notes.append("no rules scaffold written: rules.dirs is empty, nothing would deliver it")
    blocked = unfit(root, [rel for rel, text in plan if text is not None])
    if blocked:
        sys.stderr.write("kb: init: nothing was written; the paths cannot be used:\n  %s\n" % "\n  ".join(blocked))
        return 65
    out = sys.stdout.write
    out("kb.py init (%s%s)\n" % ("adopt" if o["adopt"] else "app", ", dry run" if o["dry"] else ""))
    if o["detect"]:
        out("detected (a proposal; the answers file wins): %s\n" % (j(prop) if prop else "nothing"))
    for rel, text in plan:
        p = os.path.join(root, *rel.split("/"))
        exists = os.path.lexists(p)
        if rel in soft and not exists:
            continue
        if text is None or (o["dry"] and exists):
            out("kept    %s\n" % rel)
        elif o["dry"]:
            out("would create %s\n" % rel)
        elif write_new(p, text):
            out("created %s\n" % rel)
        else:
            out("kept    %s\n" % rel)
    for n in notes:
        out(n + "\n")
    if not present:
        deny = dig(composed, "merge.deny_globs")
        out((DENY_NOTE % j(deny)) if deny is not None else DENY_UNSET_NOTE)
        out("\n")
    out(RUNNER_NOTE % " ".join(str(dig(basis, "ci.runner_var") or C.DEFAULTS["ci"]["runner_var"]).split()) + "\n")
    if present:
        try:
            with open(C.config_path(root), encoding="utf-8") as f:
                raw = json.load(f)
        except (OSError, ValueError):
            raw = {}
        have = leaves(raw)
        for key, val in sorted(leaves(inputs).items()):
            if key not in have:
                out("would add %s = %s\n" % (key, j(val)))
            elif have[key] != val:
                out("differs %s: the file has %s, the answers say %s\n" % (key, j(have[key]), j(val)))
        out("%s exists and is not rewritten\n" % cfg_rel)
    if o["dry"]:
        out("dry run: nothing was written\n")
        return 0
    rc = config_check(root)
    if o["adopt"]:
        report_adopt(root, config_notices)
    return rc


def report_adopt(root, config_notices):
    cfg, probs, _present = C.load(root)
    dups = [] if probs else [ln for ln in config_notices(root, cfg) if ln.startswith("WARNING duplicate paragraph")]
    out = sys.stdout.write
    out("\nBy hand (init edits no existing file):\n")
    n = 0
    n += 1
    out("  %d. delete the rule files that moved into the plugin%s\n"
        % (n, " (listed above as duplicate paragraphs: %d)" % len(dups) if dups else " (kb.py config check lists them as duplicate paragraphs)"))
    n += 1
    out("  %d. write by hand what detection does not read: title and branch patterns, watched paths, limits, tokens, thresholds, UI paths\n" % n)
    out("After that the plugin:\n")
    out("  - delivers the rules of rules.dirs next to its own, and reminds on edits and commands (hooks: auto); a repo that keeps "
        "rule hooks of its own in .claude/settings.json gets both, so it removes them or sets \"hooks\" to \"off\" in %s\n" % C.CONFIG_REL)
    out("  - reads %s in kb.py, open_pr.py, intent_branch.py and the gates\n" % C.CONFIG_REL)
    out("  - leaves every existing file as it is; install-gates writes the CI workflows when you ask for them\n")
