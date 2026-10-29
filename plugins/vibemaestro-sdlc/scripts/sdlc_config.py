#!/usr/bin/env python3
"""The one reader of `.vibemaestro/sdlc.json`, used by the hooks, `kb.py` and both cores.

    load(root, quiet=False) -> (effective, problems, present)
        effective  the defaults with the file merged over them; the plain defaults when there is any problem
        problems   [(dotted key, reason)]; empty means the file is valid (or absent)
        present    a regular file exists at `<root>/.vibemaestro/sdlc.json`
    load_notes(root) -> [(dotted key, note)]   the warnings of a valid file (below); `load` prints them once per process on
                                               stderr unless `quiet` (the hooks show them in their session notice instead)

Callers decide what a problem means: hooks warn once per session and carry on with the defaults, `kb.py` and the gates exit
65 naming the key, the two cores exit 64. A missing file is not a problem: it means "defaults", which equal the behaviour
of a repo that never heard of this file.

Schema 1 (section A of the consumer-contract spec in this repo's kb/specs). Compatibility (rule config-compat):
  forward   an unknown key, at any depth, is a NOTE, not a problem: it is dropped from the effective config and the reader goes on
            (a newer plugin may know it); a known key with a wrong value is still a problem. Keys that start with `_` are
            silent everywhere, so a repo can leave a `_comment`. `problems(data, strict=True)` (a config being WRITTEN, the init
            answers) treats an unknown key as a problem, so a typo never reaches a file.
  backward  every key has a default; a key renamed, removed or retyped is listed in DEPRECATED for its window: the old form is
            still read (mapped to its new key, which wins when both are set) and a note names the new form.
  breaking  `schema` is the major version: a reader refuses only a schema above SCHEMA, naming the update to run; `migrate`
            carries a config up through MIGRATIONS.

    python3 sdlc_config.py get <dotted.key> [--root DIR]    print one effective value (JSON for lists and objects)
    python3 sdlc_config.py get <dotted.key> --default       print the plugin default of the key, whatever the repo's file says
                                                            (what a skill falls back to when the effective read fails); --root
                                                            is accepted and ignored with it

Standard library only, Python 3.8+.
"""
import copy
import functools
import json
import math
import os
import posixpath
import re
import sys
import unicodedata

try:                                         # the regex parser: `re._parser` from Python 3.11, `sre_parse` before
    import re._parser as _re_parser
except ImportError:                          # pragma: no cover - Python 3.8 to 3.10
    import sre_parse as _re_parser

sys.dont_write_bytecode = True

SCHEMA = 1                                   # the highest schema number this plugin understands
CONFIG_REL = ".vibemaestro/sdlc.json"
# what a reader older than the config should run (the refusal of a newer schema names it)
UPDATE_HINT = ("update the plugin (claude plugin marketplace update vibemaestro && claude plugin update vibemaestro-sdlc@vibemaestro), "
               "or run this repo's own scripts")
UNKNOWN_NOTE = "unknown key (ignored; a newer plugin may know it)"

# A key in its deprecation window (rule config-compat): {old dotted key: {"since": YYYY-MM-DD, "use": new dotted key or None,
# "note": one line, "removed": bool}}. While `removed` is false the old key stays in SCHEMA_TREE and is still read: with `use`, its
# value moves to the new key (the new key wins when both are set). `removed: true` once it has left SCHEMA_TREE: the note replaces
# the plain unknown-key note. A key leaves the schema only when the floor reader (tests/fixtures/config_compat/floor) reads `use`.
# `note_key` instead of `note`: the note is that key of messages.py, in the config's `language` (left out where messages.py is
# not beside this file, a copy vendored alone).
DEPRECATED = {
    "pr.flow": {"since": "2026-10-20", "use": None,
                "note": "PR bodies have no flow checklist; the pr-evidence gate checks the review and E2E evidence pinned to the head"},
    "pr.tester_exempt": {"since": "2026-10-20", "use": None,
                         "note_key": "config.tester_exempt_note"},
}

# {n: function(config of schema n) -> config of schema n + 1}; `migrate` applies them in order up to SCHEMA. The PR that raises
# SCHEMA adds its step here, with a case in tests/test-config-compat.sh.
MIGRATIONS = {}

# one id per history sign of current_state.py (ten regexes in HISTORY plus the heading test)
HISTORY_IDS = ("date_iso", "date_slash_ymd", "date_dm", "date_words_month", "date_words_day", "date_words_dm",
               "pr_ref", "commit_sha", "past_words", "update_stamp", "history_heading")
CLOSING_KEYWORDS = ("close", "closes", "closed", "fix", "fixes", "fixed", "resolve", "resolves", "resolved")
SENSITIVE_SCOPES = ("pr_body", "pr_comments", "commit_messages")
# the model aliases the Agent tool's `model` parameter accepts (Claude Code 2.1.290), strongest tier first; never a dated id
MODEL_ALIASES = ("fable", "opus", "sonnet", "haiku")

# the four lines the PR body prints under its flow heading today; the first one is ticked
DEFAULT_FLOW = [
    {"text": "Worker: build/test + bằng chứng chạy", "done": True},
    {"text": "Reviewer: gate máy", "done": False},
    {"text": "Reviewer: AI review", "done": False},
    {"text": "Tester: E2E", "done": False},
]

# the word that marks one review round in a commit subject; group 1 is the round number. The commit gate matches it against the
# subject normalised by `round_plain`, so a repo that writes the word in another language sets a lower-case, accent-free regex
ROUND_PATTERN = r"\bround\s*(\d+)\b"


def round_plain(text):
    """A commit subject as `commits.round_pattern` sees it: lower case, accents removed (composed or decomposed), `đ` as `d`
    (NFD does not decompose it), so `dot` matches "Đợt 2"."""
    return "".join(ch for ch in unicodedata.normalize("NFD", text.lower()) if not unicodedata.combining(ch)).replace("\u0111", "d")


# A pattern that can never match is a WARNING (`kb.py config check`, the commit gate), not a problem: schema 1 accepted it, and
# CONTRACT.md counts a narrower set of accepted values as a breaking change.
ROUND_NEVER_MATCHES = ("can never match: a commit subject is matched lower-cased, without accents and with d for \u0111, so no "
                       "round is ever counted; write the pattern that way (for example \\bdot\\s*(\\d+)\\b)")


def round_never_matches(pattern):
    """True when a valid `commits.round_pattern` can never match a `round_plain` subject (upper case without `(?i)`, an accent,
    the d with stroke). False for a pattern that does not compile: that is a problem `validate` reports."""
    try:
        rx = re.compile(pattern)
        return not _round_can_match(_re_parser.parse(pattern), bool(rx.flags & re.IGNORECASE))
    except (re.error, TypeError):
        return False


def _round_can_match(items, fold):
    """False when the parsed regex needs a literal that a `round_plain` text never holds (upper case without `(?i)`, an accent,
    `đ`). A branch, a class or an optional part is fine as soon as one way through it can match."""
    def char_ok(c):
        ch = chr(c)
        return round_plain(ch) == (ch.lower() if fold else ch)

    def one(op, av):
        name = getattr(op, "name", str(op))
        if name == "LITERAL":
            return char_ok(av)
        if name == "IN":
            members = [x for x in av if getattr(x[0], "name", str(x[0])) != "NEGATE"]
            if len(members) < len(av):
                return True                      # a negated class matches nearly anything
            return any(getattr(o, "name", str(o)) != "LITERAL" or char_ok(a) for o, a in members)
        if name == "BRANCH":
            return any(_round_can_match(alt, fold) for alt in av[1])
        if name == "SUBPATTERN":                 # (group, add_flags, del_flags, pattern): a scoped `(?i:...)` or `(?-i:...)`
            inner = (fold or bool(av[1] & re.IGNORECASE)) and not av[2] & re.IGNORECASE
            return _round_can_match(av[-1], inner)
        if name == "ATOMIC_GROUP":                # `(?>...)`
            return _round_can_match(av, fold)
        if name == "ASSERT":                      # a lookaround must match too; a negative one never blocks
            return _round_can_match(av[1], fold)
        if name in ("MAX_REPEAT", "MIN_REPEAT", "POSSESSIVE_REPEAT"):
            return av[0] == 0 or _round_can_match(av[2], fold)
        return True
    return all(one(op, av) for op, av in items)

# the languages `language` names: `vi` is the plugin's own (the defaults), `en` lays LANGUAGE_PRESETS["en"] over them
LANGUAGES = ("vi", "en")
SPEC_SECTIONS = ("context", "goal", "out_of_scope", "criteria", "design")   # the `## ` sections of `tokens.spec`; each names its own

DEFAULTS = {
    "schema": 1,
    "hooks": "auto",
    "language": "vi",
    # the update reminder of a public install (scripts/update_check.py): false turns it off in this repository, for sdlc and brain
    "update_check": True,
    "branch": {"intent_prefix": "intent/", "protected": ["main", "master"], "pattern": None},
    "pr": {
        "title": {"pattern": None, "max_len": None, "intent_form": "allow"},
        # the cap on a PR body (gates/pr_body.py, also run by open_pr.py): characters in all, non-empty lines of the summary and of
        # the evidence section; 0 turns one limit off. On by default: the owner's rule, not an option a repo has to find.
        "body": {"max_chars": 3000, "summary_max_lines": 10, "evidence_max_lines": 30},
        "draft": False,
        "flow": DEFAULT_FLOW,
        "tester_exempt": None,
        "closing": {"keyword": "Closes", "verify": True, "tries": 10, "wait_s": 2, "deadline_s": 30},
    },
    "commits": {"max_per_pr": 15, "max_touches": 4, "round_pattern": ROUND_PATTERN},
    "current_state": {
        "path": "kb/current-state.md",
        "template": "ledger",
        "limits": {"lines": 120, "bytes": 12000, "line_chars": 200, "warn_ratio": 0.85},
        "forbid": list(HISTORY_IDS),
        "forbid_patterns": [],
        "table": None,
        "table_own_width": False,
        "tables": [],
        "no_empty_cells": False,
        "exempt": {"min_reason_chars": 0},
        # SessionStart `startup` and `compact` inject the index as a string of its own (vsdlc.session_index); on, an index over
        # current_state.INJECT_MAX_CHARS characters is a shape problem. Off by default: the repo turns it on once its index fits
        "inject": False,
        "watch": [],
        # paths under a `watch` prefix that never force a ledger edit (a test directory of a watched component)
        "watch_exclude": [],
        # the ledger's pages: null, or one flat directory of Markdown files (`kb/state/*.md`) the index points to; a page has a cap
        # of its own (a page holds whole old table rows, so its lines are longer and it has no line count)
        "pages": None,
        "page_limits": {"lines": None, "bytes": 8000, "line_chars": 400, "warn_ratio": 0.85},
        "gate": "builtin",
        # dated labels: null, or {regex with a named group `date`, max_age_days}; a label with no date or older than N days is a
        # WARNING (current_state.label_warnings), and its date is not a history sign
        "labels": None,
    },
    "rules": {"dirs": [], "disable": []},
    # a repo that publishes its tree: null (it does not), or the globs that stay private besides the root kb/ (rule public-tree)
    "public": {"private": None},
    # the pr-evidence gate: null (the repo has no UI, no E2E evidence asked), or the globs of its UI paths. Set it in a repo only
    # once every reader in use knows the key (rule config-compat, rollout)
    "evidence": {"ui_paths": None},
    "sensitive": {"allowlist": ".pr-sensitive-allow", "scan": list(SENSITIVE_SCOPES)},
    "dead_branches": {"max_merged_on_remote": 0},
    "ci": {"runner_var": "CI_RUNNER", "runner_default": "ubuntu-latest", "backend": "github-actions"},
    # the guarded merge (gates/merge_guard.py), read from the PR's base commit: deny_globs null means "not set", and the guard
    # refuses to run until it is (an empty list is a valid answer)
    # planner: null, or {script, inputs}: the test planner `--behind auto` runs from the base commit (merge_guard.py's docstring)
    "merge": {"deny_globs": None, "admin_bypass": False, "required_checks": [], "log": None, "planner": None,
              "image_bump": {"enabled": False, "tag_files": [], "tree": None, "revision": None, "registry": None}},
    "rebase": {"identity": None},
    "upstream_issues": True,
    # the model a skill passes to the Agent tool, by the subagent's job (see the skills that spawn agents)
    "agents": {"review_model": "opus", "search_model": "haiku", "worker_model": "sonnet"},
    # a spec over this many bytes is listed by `kb.py check` (~10k tokens at ~4 bytes a token: reading it whole stops being cheap)
    "kb": {"spec_warn_bytes": 40000},
    "tokens": {
        "summary_heading": "Tóm tắt",
        "criteria_heading": "Tiêu chí chấp nhận",
        "evidence_heading": "Bằng chứng chạy",
        "flow_heading": "Luồng",
        "fixes_line": "Vá cho",
        "not_run": "KHÔNG CHẠY:",
        "no_state_change": ["NO STATE CHANGE:"],
        "commit_exception": "COMMIT EXCEPTION:",
        "round_comment_prefix": "SHA:",
        # the PR body's other fixed lines: the marker that replaces the middle of a long evidence (`{n}` = lines cut), the warning
        # above an evidence that starts with `not_run`, the note under the criteria checklist (`{evidence}` = evidence_heading)
        "evidence_cut": "… (cắt {n} dòng giữa) …",
        "not_run_note": "⚠ **Không chạy được** — lý do do worker khai, reviewer đối chiếu với diff:",
        "criteria_note": "_Chỉ tick dòng nào có lệnh tương ứng ở mục **{evidence}**. "
                         "Tick không có lệnh là lời tự khai._",
        # what `kb.py check spec` checks and `kb.py new` writes: the four required `## ` sections in order, the optional design section,
        # the heading the last criterion must name, and the mark of a blank left to fill. Apart from the PR-body tokens on purpose:
        # a repo that renamed `criteria_heading` for its PR bodies keeps passing its existing specs.
        "spec": {
            "context": "Bối cảnh",
            "goal": "Mục tiêu",
            "out_of_scope": "Ngoài phạm vi",
            "criteria": "Tiêu chí chấp nhận",
            "design": "Thiết kế",
            "evidence": "Bằng chứng chạy",
            "placeholder": "<ĐIỀN",
        },
    },
}

# A language preset is laid between the defaults and the file, before the `current_state.template` preset: every string the plugin
# writes into a PR body or checks in a spec, and the flow lines. `vi` is the defaults themselves; a key the file sets still wins.
LANGUAGE_PRESETS = {
    "vi": {},
    "en": {
        "pr": {"flow": [
            {"text": "Worker: build/test + run evidence", "done": True},
            {"text": "Reviewer: machine gate", "done": False},
            {"text": "Reviewer: AI review", "done": False},
            {"text": "Tester: E2E", "done": False},
        ]},
        "tokens": {
            "summary_heading": "Summary",
            "criteria_heading": "Acceptance criteria",
            "evidence_heading": "Run evidence",
            "flow_heading": "Flow",
            "fixes_line": "Patch for",          # not "Fixes": that is a GitHub closing keyword and would close an issue of that number
            "not_run": "NOT RUN:",
            "evidence_cut": "… ({n} lines cut from the middle) …",
            "not_run_note": "⚠ **Not run**: the reason is the worker's own claim; the reviewer checks it against the diff:",
            "criteria_note": "_Tick only a line whose command is in **{evidence}**. A tick without a command is a claim._",
            "spec": {
                "context": "Context",
                "goal": "Goal",
                "out_of_scope": "Out of scope",
                "criteria": "Acceptance criteria",
                "design": "Design",
                "evidence": "Run evidence",
                "placeholder": "<FILL",
            },
        },
    },
}

# A preset is a named bundle of `current_state` knobs laid between the defaults (the `ledger` preset) and the file. It carries
# only what is true of the template whatever the repo: sizes, the history signs the template tolerates, the table width. Repo
# values (watched paths, the exemption token, section headings and column names) are never in a preset.
PRESETS = {
    "ledger": {},
    "map": {
        "limits": {"lines": None, "bytes": 28000, "line_chars": 400},
        "forbid": [],
        "table": {"columns": 5, "required": True},
    },
}

# object defaults that are filled in when the object is given (the object itself defaults to null)
TESTER_EXEMPT_DEFAULTS = {"unless_package_script": "test:e2e"}


def defaults():
    return copy.deepcopy(DEFAULTS)


def config_path(root):
    return os.path.join(root, *CONFIG_REL.split("/"))


def is_present(root):
    """Something sits at the config path. A directory or a broken link there counts as present (and invalid, see `load`):
    a config that exists but cannot be read must not look like "no config"."""
    return os.path.lexists(config_path(root))


# ── validation ───────────────────────────────────────────────────────────────────────────────────
# A node is a tuple: ("int", min) ("intnull", min) ("num", min, strict) ("ratio",) ("bool",) ("str",) ("enum", values) ("regex",)
# ("regexnull",) ("hole", "{x}") ("heading",) ("mark",) ("groupre",) ("strlist",) ("idlist", ids) ("pathlist",) ("relpath",) ("flow",) ("obj", {key: node}) ("objnull", {key: node},
# required keys) ("tokenlist",) ("gate",) ("keyword",) ("ident",) ("patterns",) ("tables",) ("gitfile",) ("gitprefixes",) ("pageglob",)
# ("labelre",)
_STR = ("str",)
# `ci.runner_default` is a runner label, or this value: no fallback label at all, the workflows install-gates writes fail at the start of a
# run while the runner variable is unset (an organisation with self-hosted runners only has no hosted machine to fall back to). It holds a
# space, so it can never equal a label; to a reader that predates the form it is an ordinary string.
RUNNER_SELF_HOSTED_ONLY = "self-hosted only"
RUNNER_LABEL = re.compile(r"[A-Za-z0-9._-]+")
LABEL_PROBE_SECONDS = 1     # the `labelre` probes are 10 characters at most: a regex that needs longer backtracks


class _Overrun(BaseException):
    """The timer of `time_boxed`. Not an Exception: an `except Exception` inside `fn` must not swallow it."""


def time_boxed(fn, seconds):
    """True when `fn()` returned within `seconds`, False when a SIGALRM timer stopped it first (it interrupts a regular expression
    on CPython 3.11). Here, not in rules.py, because this module is vendored alone into a repo's gates. Where no timer can be set
    (no SIGALRM, not the main thread) `fn` runs unbounded; when another timer already runs, `fn` runs under that one alone (a
    second timer would cancel it)."""
    import signal
    import threading
    if not hasattr(signal, "setitimer") or threading.current_thread() is not threading.main_thread() \
            or signal.getitimer(signal.ITIMER_REAL)[0] > 0:
        fn()
        return True

    def on_alarm(*_a):
        raise _Overrun()
    old = signal.signal(signal.SIGALRM, on_alarm)
    try:
        try:
            signal.setitimer(signal.ITIMER_REAL, seconds)
            fn()
            return True
        finally:
            signal.setitimer(signal.ITIMER_REAL, 0)
    except _Overrun:
        return False
    finally:
        if old is not None:              # None: a handler not set from Python, which cannot be put back
            signal.signal(signal.SIGALRM, old)

SCHEMA_TREE = {
    "schema": ("int", 1),
    "hooks": ("enum", ("auto", "off")),
    "language": ("enum", LANGUAGES),
    "update_check": ("bool",),
    "branch": ("obj", {
        "intent_prefix": ("prefix",),
        "protected": ("strlist",),
        "pattern": ("regexnull",),
    }),
    "pr": ("obj", {
        "title": ("obj", {
            "pattern": ("regexnull",),
            "max_len": ("intnull", 1),
            "intent_form": ("enum", ("allow", "reject")),
        }),
        "body": ("obj", {
            "max_chars": ("int", 0),
            "summary_max_lines": ("int", 0),
            "evidence_max_lines": ("int", 0),
        }),
        "draft": ("bool",),
        "flow": ("flow",),
        "tester_exempt": ("objnull", {"decision": ("relpath",), "unless_package_script": _STR}, ("decision",)),
        "closing": ("obj", {
            "keyword": ("keyword",),
            "verify": ("bool",),
            "tries": ("int", 1),
            "wait_s": ("num", 0, False),
            "deadline_s": ("num", 0, True),
        }),
    }),
    "commits": ("obj", {"max_per_pr": ("int", 1), "max_touches": ("int", 1), "round_pattern": ("groupre",)}),
    "current_state": ("obj", {
        "path": ("gitfile",),
        "template": ("enum", ("ledger", "map")),
        "limits": ("obj", {"lines": ("intnull", 1), "bytes": ("int", 1), "line_chars": ("int", 1), "warn_ratio": ("ratio",)}),
        "forbid": ("idlist", HISTORY_IDS),
        "forbid_patterns": ("patterns",),
        "table": ("objnull", {"columns": ("int", 1), "required": ("bool",)}, ("columns",)),
        "table_own_width": ("bool",),
        "tables": ("tables",),
        "no_empty_cells": ("bool",),
        "exempt": ("obj", {"min_reason_chars": ("int", 0)}),
        "inject": ("bool",),
        "watch": ("gitprefixes",),
        "watch_exclude": ("gitprefixes",),
        "pages": ("pageglob",),
        "page_limits": ("obj", {"lines": ("intnull", 1), "bytes": ("int", 1), "line_chars": ("int", 1), "warn_ratio": ("ratio",)}),
        "gate": ("gate",),
        "labels": ("objnull", {"regex": ("labelre",), "max_age_days": ("int", 0)}, ("regex", "max_age_days")),
    }),
    "rules": ("obj", {"dirs": ("pathlist",), "disable": ("strlist",)}),
    "public": ("obj", {"private": ("globsnull",)}),
    "evidence": ("obj", {"ui_paths": ("globsnull",)}),
    "sensitive": ("obj", {"allowlist": ("relpath",), "scan": ("idlist", SENSITIVE_SCOPES)}),
    "dead_branches": ("obj", {"max_merged_on_remote": ("int", 0)}),
    "ci": ("obj", {"runner_var": ("ident",), "runner_default": _STR, "backend": ("backend", ("github-actions",))}),
    "merge": ("obj", {
        "deny_globs": ("globsnull",),
        "admin_bypass": ("bool",),
        "required_checks": ("strlist",),
        "log": ("lognull",),
        "planner": ("objnull", {"script": ("gitfile",), "inputs": ("gitfiles",)}, ("script", "inputs")),
        "image_bump": ("obj", {
            "enabled": ("bool",),
            "tag_files": ("gitfiles",),
            "tree": ("gitprefixnull",),
            "revision": ("objnull", {"file": ("gitfile",), "pattern": ("groupre",)}, ("file", "pattern")),
            "registry": ("objnull", {"backend": ("backend", ("ghcr",)), "host": ("host",), "image": ("image",)},
                         ("backend", "host", "image")),
        }),
    }),
    "rebase": ("obj", {"identity": ("objnull", {"name": _STR, "email": _STR}, ("name", "email"))}),
    "upstream_issues": ("bool",),
    "agents": ("obj", {"review_model": ("enum", MODEL_ALIASES), "search_model": ("enum", MODEL_ALIASES),
                       "worker_model": ("enum", MODEL_ALIASES)}),
    "kb": ("obj", {"spec_warn_bytes": ("intnull", 1)}),
    "tokens": ("obj", {
        "summary_heading": _STR, "criteria_heading": _STR, "evidence_heading": _STR, "flow_heading": _STR,
        "fixes_line": _STR, "not_run": _STR, "no_state_change": ("tokenlist",), "commit_exception": _STR,
        "round_comment_prefix": _STR, "evidence_cut": ("hole", "{n}"), "not_run_note": _STR, "criteria_note": _STR,
        "spec": ("obj", {"context": ("heading",), "goal": ("heading",), "out_of_scope": ("heading",), "criteria": ("heading",),
                         "design": ("heading",), "evidence": ("heading",), "placeholder": ("mark",)}),
    }),
}


_REF_SEG = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")

# The glob language of the guarded merge (`merge.deny_globs`, a brief's allowed globs, `--behind-ok`): the `applyTo` semantics of
# rules.py (`*` and `?` inside a segment, `**` across segments, `**/` also zero directories). What it does not support is refused
# rather than read literally, so nobody relies on a class or a brace that would match nothing.
GLOB_BAD_CHARS = "[]{}\\"
# the deny globs a new config gets from `kb.py init` (the list the init-kb skill proposes), and the floor the guarded merge adds to
# the deny globs of a config a repo's first PR brings (bootstrap), so that PR cannot empty its own list. `.vibemaestro/` is named
# file by file and directory by directory, leaving out `batons/`: a project baton merges through the guard like other code (BatonRun
# Q2a). A config that sets merge.deny_globs keeps its own list
MERGE_DENY_DEFAULT = (".github/workflows/**", ".vibemaestro/*", ".vibemaestro/gates/**", ".vibemaestro/rules/**", "**/*secret*")


def merge_deny_floor(rules_dirs):
    """MERGE_DENY_DEFAULT plus `<dir>/**` for each `rules.dirs` folder that sits under `.vibemaestro/` and is not named there yet: a
    rules folder is policy as much as `.vibemaestro/rules`, whatever its name. A folder outside `.vibemaestro/` adds nothing. A name
    the glob language cannot spell literally fails closed: each of `[`, `]`, `{`, `}` becomes `?` (it denies that folder and may deny
    a neighbour), `*` and `?` stay (so does a run of `*` as one). The gates folder is fixed (`install_gates.py`), so it is in the tuple."""
    have = set(g.lower() for g in MERGE_DENY_DEFAULT)
    extra = []
    for d in rules_dirs if isinstance(rules_dirs, list) else []:
        if not isinstance(d, str) or not _clean(d):
            continue
        norm = posixpath.normpath(d)
        low = norm.lower()
        g = re.sub(r"\*+", "*", re.sub(r"[\[\]{}]", "?", norm)) + "/**"
        if (low == ".vibemaestro" or low.startswith(".vibemaestro/")) and glob_ok(g) and g.lower() not in have:
            have.add(g.lower())
            extra.append(g)
    return list(MERGE_DENY_DEFAULT) + extra
# a registry host (`ghcr.io`, `registry.example.test:5000`) and an image path (lower case, the OCI distribution grammar)
_HOST = re.compile(r"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)*(?::[0-9]{1,5})?$")
# `merge.log`: a plain file name in the user's state directory, so it can never point into the baton's own state
_LOG_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*")
_IMAGE = re.compile(r"^[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*(?:/[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*)*$")


def glob_ok(g):
    """A glob of the guarded merge: relative, segments split on `/`, none empty, `.` or `..`, no backslash, class or brace, and
    `**` only as a whole segment."""
    if not _clean(g) or not g or g.startswith("/") or any(c in g for c in GLOB_BAD_CHARS):
        return False
    segs = g.split("/")
    if any(seg in ("", ".", "..") for seg in segs):
        return False
    return all("**" not in seg or seg == "**" for seg in segs)


@functools.lru_cache(maxsize=1024)
def glob_regex(g):
    """The compiled regex of a glob that `glob_ok` accepts: `**/` any number of directories (also none), `**` anything, `*` and
    `?` inside one segment."""
    out, i = [], 0
    while i < len(g):
        if g.startswith("**/", i):
            out.append(r"(?:[^/]+/)*")
            i += 3
        elif g.startswith("**", i):
            out.append(r".*")
            i += 2
        elif g[i] == "*":
            out.append(r"[^/]*")
            i += 1
        elif g[i] == "?":
            out.append(r"[^/]")
            i += 1
        else:
            out.append(re.escape(g[i]))
            i += 1
    return re.compile("^" + "".join(out) + r"\Z", re.S)


# the typed kb directories: a page directory is none of them, inside none of them and above none of them (their files are
# one-time records or decisions, never ledger pages)
KB_TYPED_DIRS = ("kb/intent", "kb/specs", "kb/plans", "kb/decisions")
PAGE_GLOB_RULE = ("must be null or a glob of one flat directory of Markdown pages, `<directory>/<name>.md` (for example kb/state/*.md): "
                  "the directory written out (no '*', '?' or '**'), the name one segment ending in .md")


def page_glob_ok(g):
    """`current_state.pages` has the shape of `kb/decisions/*.md`: a literal directory, then one name segment ending in `.md`."""
    if not isinstance(g, str) or not glob_ok(g) or "/" not in g or "**" in g:
        return False
    d, name = g.rsplit("/", 1)
    return not any(c in d for c in "*?") and _git_path_ok(d) and name.endswith(".md") and name != ".md"


def page_dir(g):
    """The directory of a `current_state.pages` glob that `page_glob_ok` accepts."""
    return g.rsplit("/", 1)[0]


def glob_match(g, path):
    """True when `path` (as git prints it) matches the glob `g`, case-sensitively."""
    return bool(glob_regex(g).match(path))


GLOB_RULE = ("must be a relative glob: segments split on '/', none empty, '.' or '..'; no backslash, '[', ']', '{' or '}'; "
             "'**' only as a whole segment")


def _is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def _is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def _clean(v):
    """A string with no control character (NUL, newline...) that can be written out as UTF-8 (no lone surrogate)."""
    if not isinstance(v, str) or any(ord(c) < 32 or ord(c) == 127 for c in v):
        return False
    try:
        v.encode("utf-8")
    except UnicodeEncodeError:
        return False
    return True


def _text(v):
    return _clean(v) and v.strip() != ""


def _rel_ok(v):
    """A path inside the repo: relative, no `..` segment, no empty segment, no backslash."""
    if not _clean(v) or not v.strip() or v.startswith("/") or "\\" in v or re.match(r"^[A-Za-z]:", v):
        return False
    return all(seg not in ("", "..") for seg in v.rstrip("/").split("/"))


def _git_path_ok(v):
    """A path or prefix that can ever equal what `git diff --name-only` prints: relative, no `.` or `..` segment."""
    return _rel_ok(v) and all(seg != "." for seg in v.split("/"))


def _check(node, v, key, out):
    """Validate `v` against `node`; append (key, reason) to `out`."""
    kind = node[0]
    if kind == "int":
        if not _is_int(v) or v < node[1]:
            out.append((key, "must be an integer >= %d" % node[1]))
    elif kind == "intnull":
        if v is not None and (not _is_int(v) or v < node[1]):
            out.append((key, "must be null or an integer >= %d" % node[1]))
    elif kind == "num":
        if not _is_num(v) or not math.isfinite(v) or (v <= node[1] if node[2] else v < node[1]):
            out.append((key, "must be a finite number %s %s" % (">" if node[2] else ">=", node[1])))
    elif kind == "ratio":
        if not _is_num(v) or not 0 < v <= 1:
            out.append((key, "must be a number above 0 and at most 1 (a share of the cap)"))
    elif kind == "bool":
        if not isinstance(v, bool):
            out.append((key, "must be true or false"))
    elif kind == "str":
        if not _text(v):
            out.append((key, "must be a non-empty single-line string"))
    elif kind == "hole":
        if not _text(v) or node[1] not in v:
            out.append((key, "must be a non-empty single-line string that contains %s" % node[1]))
    elif kind == "heading":
        if not _text(v) or v != v.strip():
            out.append((key, "must be a non-empty single-line string without leading or trailing spaces (a `## ` heading is read stripped)"))
    elif kind == "mark":
        if not _text(v) or not re.match(r"^<[^\s<>][^<>]*$", v):
            out.append((key, "must be '<' and a word, with no other '<' or '>' (the templates write `<mark>: what to fill>`), for example <FILL"))
    elif kind == "ident":
        if not isinstance(v, str) or not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", v):
            out.append((key, "must be an identifier ([A-Za-z_][A-Za-z0-9_]*)"))
    elif kind == "enum":
        if not isinstance(v, str) or v not in node[1]:
            out.append((key, "must be one of %s" % ", ".join(node[1])))
    elif kind in ("regex", "regexnull"):
        if v is None and kind == "regexnull":
            return
        if not _clean(v) or not v:
            out.append((key, "must be a regular expression string%s" % (" or null" if kind == "regexnull" else "")))
            return
        try:
            re.compile(v)
        except re.error as e:
            out.append((key, "invalid regular expression: %s" % e))
    elif kind == "labelre":
        if not _clean(v) or not v:
            out.append((key, "must be a regular expression string with a named group date"))
            return
        try:
            rx = re.compile(unicodedata.normalize("NFC", v))
        except re.error as e:
            out.append((key, "invalid regular expression: %s" % e))
            return
        if "date" not in rx.groupindex:
            out.append((key, "must have a named group date, (?P<date>...), that holds the label's YYYY-MM-DD"))
            return
        got = []           # the probes run under a timer: this check runs on every load, the SessionStart hook included
        if not time_boxed(lambda: got.extend([rx.search(""), rx.search("2026-10-19")]), LABEL_PROBE_SECONDS):
            out.append((key, "runs over %d s on a 10-character probe (nested quantifiers backtrack): write it without them"
                        % LABEL_PROBE_SECONDS))
        elif got[0]:
            out.append((key, "matches the empty string, so every line would hold a label"))
        elif got[1]:
            out.append((key, "matches a bare date: it needs a marker word, or every date of the ledger would be a label and "
                             "leave the history check"))
    elif kind == "groupre":
        if not _clean(v) or not v:
            out.append((key, "must be a regular expression string with a capture group for the round number"))
            return
        try:
            rx = re.compile(v)
        except re.error as e:
            out.append((key, "invalid regular expression: %s" % e))
            return
        if rx.groups < 1:
            out.append((key, "must have a capture group (group 1 is the round number)"))
    elif kind == "prefix":
        if not _text(v) or not v.endswith("/") or not all(_REF_SEG.match(seg) and ".." not in seg and not seg.endswith(".lock")
                                                           for seg in v[:-1].split("/")):
            out.append((key, "must be a branch-name prefix ending in '/' (letters, digits, . _ - per segment; for example intent/)"))
    elif kind == "keyword":
        if not isinstance(v, str) or v.lower() not in CLOSING_KEYWORDS:
            out.append((key, "must be one of the closing keywords GitHub honours: %s" % ", ".join(CLOSING_KEYWORDS)))
    elif kind == "relpath":
        if not _rel_ok(v):
            out.append((key, "must be a relative path inside the repo (no '..', not absolute)"))
    elif kind == "gitfile":
        if not _git_path_ok(v) or v.endswith("/"):
            out.append((key, "must be a file path as git prints it: relative, no '.' or '..' segment, no trailing '/'"))
    elif kind == "gitprefixes":
        if not isinstance(v, list):
            out.append((key, "must be a list"))
            return
        for i, item in enumerate(v):
            if not _git_path_ok(item):
                out.append(("%s[%d]" % (key, i), "must be a path prefix as git prints paths: relative, no '.' or '..' segment"))
    elif kind == "pageglob":
        if v is not None and not page_glob_ok(v):
            out.append((key, PAGE_GLOB_RULE))
    elif kind == "globsnull":
        if v is None:
            return
        if not isinstance(v, list):
            out.append((key, "must be a list of globs (an empty list is a valid answer), or null for not set"))
            return
        for i, item in enumerate(v):
            if not glob_ok(item):
                out.append(("%s[%d]" % (key, i), GLOB_RULE))
    elif kind == "lognull":
        if v is not None and (not isinstance(v, str) or not _LOG_NAME.fullmatch(v) or v.lower() == "baton"):
            out.append((key, "must be null or a plain file name (letters, digits, '.', '_', '-'; not `baton`) in the user's state directory"))
    elif kind == "backend":
        if not isinstance(v, str) or not (v in node[1] or (v.startswith("external:") and _git_path_ok(v[len("external:"):]) and not v.endswith("/"))):
            out.append((key, "must be %s, or external:<file path as git prints it: relative, no '.' or '..' segment>" % " or ".join(node[1])))
    elif kind == "host":
        if not isinstance(v, str) or not _HOST.match(v):
            out.append((key, "must be a registry host name, optionally with a port (for example ghcr.io)"))
    elif kind == "image":
        if not isinstance(v, str) or not _IMAGE.match(v):
            out.append((key, "must be an image path in lower case, without host or tag (for example acme/app)"))
    elif kind == "gitfiles":
        if not isinstance(v, list):
            out.append((key, "must be a list of file paths"))
            return
        for i, item in enumerate(v):
            _check(("gitfile",), item, "%s[%d]" % (key, i), out)
    elif kind == "gitprefixnull":
        if v is not None and not _git_path_ok(v):
            out.append((key, "must be null or a directory path as git prints paths: relative, no '.' or '..' segment"))
    elif kind == "gate":
        if not isinstance(v, str) or not (v in ("builtin", "off") or (v.startswith("external:") and _rel_ok(v[len("external:"):]))):
            out.append((key, "must be builtin, off, or external:<relative path>"))
    elif kind in ("strlist", "tokenlist", "pathlist", "idlist"):
        if not isinstance(v, list):
            out.append((key, "must be a list"))
            return
        for i, item in enumerate(v):
            k = "%s[%d]" % (key, i)
            if kind == "pathlist":
                if not _rel_ok(item):
                    out.append((k, "must be a relative path inside the repo (no '..', not absolute)"))
            elif kind == "idlist":
                if item not in node[1]:
                    out.append((k, "must be one of %s" % ", ".join(node[1])))
            elif not _text(item):
                out.append((k, "must be a non-empty single-line string"))
    elif kind == "patterns":
        _check_patterns(v, key, out)
    elif kind == "tables":
        _check_tables(v, key, out)
    elif kind == "flow":
        if not isinstance(v, list) or not v:
            out.append((key, "must be a non-empty list of strings or {text, done} objects"))
            return
        for i, item in enumerate(v):
            k = "%s[%d]" % (key, i)
            if _text(item):
                continue
            if not isinstance(item, dict):
                out.append((k, "must be a string or a {text, done} object"))
                continue
            _check_obj({"text": _STR, "done": ("bool",)}, item, k, out, required=("text",))
    elif kind in ("obj", "objnull"):
        if v is None and kind == "objnull":
            return
        if not isinstance(v, dict):
            out.append((key, "must be an object%s" % (" or null" if kind == "objnull" else "")))
            return
        _check_obj(node[1], v, key, out, required=node[2] if kind == "objnull" else ())
    else:                                                        # a schema bug, not a user error
        raise ValueError("unknown schema node %r" % (kind,))


def _check_lane(v, key, out):
    """`merge.image_bump` across its fields (each field is valid): the lane on needs a registry and a tag file, and the `ghcr`
    backend serves the host ghcr.io only."""
    if v.get("enabled") is True and v.get("registry") is None:
        out.append((key + ".registry", "is required when the lane is enabled: the new tag must be found in the registry"))
    if v.get("enabled") is True and not v.get("tag_files"):
        out.append((key + ".tag_files", "must list at least one file when the lane is enabled: a bump changes the image tag somewhere"))
    reg = v.get("registry") or {}
    if reg.get("backend") == "ghcr" and reg.get("host") != "ghcr.io":
        out.append((key + ".registry.host", "must be ghcr.io for the ghcr backend (another registry takes an external: adapter)"))


def _check_patterns(v, key, out):
    """`forbid_patterns`: a list of {id, regex}; the ids are unique and are not one of the built-in history ids."""
    if not isinstance(v, list):
        out.append((key, "must be a list of {id, regex} objects"))
        return
    seen = set()
    for i, item in enumerate(v):
        k = "%s[%d]" % (key, i)
        if not isinstance(item, dict):
            out.append((k, "must be an {id, regex} object"))
            continue
        _check_obj({"id": ("ident",), "regex": ("regex",)}, item, k, out, required=("id", "regex"))
        rx = item.get("regex")
        if isinstance(rx, str) and _clean(rx):
            try:
                if re.compile(rx).search(""):
                    out.append((k + ".regex", "matches the empty string, so it would flag every line"))
            except re.error:
                pass
        pid = item.get("id")
        if isinstance(pid, str):
            if pid in HISTORY_IDS:
                out.append((k + ".id", "is a built-in history id; list it in forbid instead, or pick another id"))
            elif pid in seen:
                out.append((k + ".id", "is used twice"))
            seen.add(pid)


def _check_tables(v, key, out):
    """`tables`: a list of {heading: regex, columns: [names], enums: {column: [values]}, decorations: {column: regex | [regex]}}; an
    enums column must be one of `columns`."""
    if not isinstance(v, list):
        out.append((key, "must be a list of {heading, columns, enums} objects"))
        return
    headings = set()
    for i, item in enumerate(v):
        k = "%s[%d]" % (key, i)
        if not isinstance(item, dict):
            out.append((k, "must be a {heading, columns, enums} object"))
            continue
        if isinstance(item.get("heading"), str):
            if item["heading"] in headings:
                out.append((k + ".heading", "is used by an earlier entry (each entry demands exactly one table, two cannot share a heading)"))
            headings.add(item["heading"])
        for sub in item:
            if not sub.startswith("_") and sub not in ITEM_FIELDS["tables"]:
                out.append((_safe(k + "." + sub), Note(UNKNOWN_NOTE)))
        for need in ("heading", "columns"):
            if need not in item:
                out.append((k + "." + need, "is required"))
        if "heading" in item:
            _check(("regex",), item["heading"], k + ".heading", out)
        cols = item.get("columns")
        if "columns" in item:
            if not isinstance(cols, list) or not cols:
                out.append((k + ".columns", "must be a non-empty list of column names"))
            else:
                for j, c in enumerate(cols):
                    if not _text(c):
                        out.append(("%s.columns[%d]" % (k, j), "must be a non-empty single-line string"))
                    elif cols.index(c) != j:
                        out.append(("%s.columns[%d]" % (k, j), "repeats an earlier column name"))
        if "decorations" in item:
            _check_decorations(item["decorations"], item.get("enums"), k + ".decorations", out)
        if "enums" in item:
            en = item["enums"]
            if not isinstance(en, dict):
                out.append((k + ".enums", "must be an object {column: [allowed values]}"))
                continue
            for col, vals in en.items():
                kk = "%s.enums.%s" % (k, col)
                if col.startswith("_"):
                    continue
                if isinstance(cols, list) and col not in cols:
                    out.append((kk, "is not one of the columns of this table"))
                if not isinstance(vals, list) or not vals or not all(_text(x) for x in vals):
                    out.append((kk, "must be a non-empty list of non-empty single-line strings"))


def _check_decorations(dec, enums, key, out):
    """`decorations` of a `tables` entry: {column: regex | [regex, ...]}; the column has an `enums` entry in the same table, and no
    regex can match the empty string (it would remove nothing and say nothing)."""
    if not isinstance(dec, dict):
        out.append((key, "must be an object {column: regex or list of regexes}"))
        return
    for col, rx in dec.items():
        if col.startswith("_"):
            continue
        kk = "%s.%s" % (key, col)
        if not (isinstance(enums, dict) and col in enums):
            out.append((kk, "is not a column with an enums entry in this table"))
        if isinstance(rx, list) and not rx:
            out.append((kk, "must be a regular expression string or a non-empty list of them"))
            continue
        for j, r in enumerate(rx if isinstance(rx, list) else [rx]):
            kj = "%s[%d]" % (kk, j) if isinstance(rx, list) else kk
            n = len(out)
            _check(("regex",), r, kj, out)
            if len(out) == n and re.compile(r).search(""):
                out.append((kj, "matches the empty string, so it decorates nothing"))


class Note(str):
    """A reason that is a warning, not a problem (an unknown key): `check` sorts the two apart."""


# the keys of the objects inside the list nodes, the one list each check and `_strip` use
ITEM_FIELDS = {"tables": ("heading", "columns", "enums", "decorations"), "flow": ("text", "done"), "patterns": ("id", "regex")}


def _safe(key):
    """A key as it may be printed: control characters escaped, at most 120 characters (a key comes from the file, and its
    note reaches a terminal, a CI log and a hook's context)."""
    k = "".join(c if c.isprintable() else "\\x%02x" % ord(c) for c in key)
    return k if len(k) <= 120 else k[:119] + "…"


def _check_obj(fields, v, key, out, required=()):
    for k in v:
        if k.startswith("_"):
            continue
        if k not in fields:
            dotted = ("%s.%s" % (key, k)) if key else k
            gone = DEPRECATED.get(dotted)
            out.append((_safe(dotted), Note(_deprecation_note(dotted, gone) if gone and gone.get("removed") else UNKNOWN_NOTE)))
    for k, sub in fields.items():
        if k in v:
            _check(sub, v[k], ("%s.%s" % (key, k)) if key else k, out)
        elif k in required:
            out.append((("%s.%s" % (key, k)) if key else k, "is required"))


def _deprecation_note(key, d, lang="vi"):
    """The note of a deprecated key: what replaces it, or that it does nothing now."""
    if d.get("use"):
        what = "use %s instead%s" % (d["use"], " (when both are set, %s wins)" % d["use"] if not d.get("removed") else "")
    else:
        what = "it does nothing now: remove it"
    note = d.get("note")
    if d.get("note_key"):
        try:
            import messages
            note = messages.text(d["note_key"], lang)
        except Exception:                       # vendored alone, or another `messages` module: the note is left out, the rest
            note = None                         # of the line still says what to do
    return "deprecated since %s, %s%s" % (d["since"], what, ": " + note if note else "")


def _lookup(data, dotted):
    """(found, value) at a dotted key of a parsed config; objects only."""
    cur = data
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return False, None
        cur = cur[part]
    return True, cur


def check(data):
    """(problems, notes) for a parsed config: problems refuse it, notes are warnings (unknown keys, deprecated keys in use)."""
    if not isinstance(data, dict):
        return [("(file)", "the top level must be a JSON object")], []
    schema = data.get("schema", 1)
    if _is_int(schema) and schema > SCHEMA:
        return [("schema", "config is schema %d, this plugin reads up to %d: %s" % (schema, SCHEMA, UPDATE_HINT))], []
    out = []
    lang = data.get("language") if data.get("language") in LANGUAGES else "vi"      # the language of a note (`note_key`)
    _check_obj(SCHEMA_TREE, data, "", out)
    notes = [(k, Note(_deprecation_note(k, DEPRECATED[k], lang)) if isinstance(why, Note) and DEPRECATED.get(k, {}).get("removed") else why)
             for k, why in out if isinstance(why, Note)]
    probs = [p for p in out if not isinstance(p[1], Note)]
    for key, d in sorted(DEPRECATED.items()):
        if not d.get("removed") and _lookup(data, key)[0]:
            notes.append((key, Note(_deprecation_note(key, d, lang))))
    rd = data.get("ci", {}).get("runner_default") if isinstance(data.get("ci"), dict) else None
    if _text(rd) and rd != RUNNER_SELF_HOSTED_ONLY and not RUNNER_LABEL.fullmatch(rd):     # the type stays a string for every older reader
        notes.append(("ci.runner_default", Note("is not a runner label ([A-Za-z0-9._-]+) and not \"%s\": install-gates refuses it; write a label "
                                                "(the fallback of the runs-on expression) or \"%s\" (no fallback)"
                                                % (RUNNER_SELF_HOSTED_ONLY, RUNNER_SELF_HOSTED_ONLY))))
    moved = _forward(data)
    if moved is not data:                    # a value moved to its new key is checked against the new key's type too
        again = []
        _check_obj(SCHEMA_TREE, moved, "", again)
        probs += [(k, "%s (the value of a deprecated key moved here)" % why) for k, why in again
                  if not isinstance(why, Note) and (k, why) not in probs]
    return [(_safe(k), why) for k, why in probs], notes      # a problem key can hold a name from the file too


def validate(data):
    """[(dotted key, reason)] for a parsed config; empty means valid. An unknown key is a note (`check`), not a problem."""
    return check(data)[0]


def _strip(v, node):
    """`v` without the keys `node` does not know (objects recursively, and the objects inside a list node): what the effective
    config is built from."""
    if isinstance(v, list) and isinstance(node, tuple) and node[0] in ITEM_FIELDS:
        keep = ITEM_FIELDS[node[0]]
        return [{k: x for k, x in item.items() if k in keep} if isinstance(item, dict) else item for item in v]
    if not isinstance(v, dict) or not isinstance(node, tuple) or node[0] not in ("obj", "objnull"):
        return v
    fields = node[1]
    return {k: _strip(x, fields[k]) for k, x in v.items() if k in fields}      # `_` keys too: `_merge` skips them anyway


def _forward(data):
    """The deprecated keys in their window moved to their new key (the new key wins when both are set)."""
    out = data
    for key, d in sorted(DEPRECATED.items()):
        if d.get("removed") or not d.get("use"):
            continue
        found, val = _lookup(out, key)
        if not found or _lookup(out, d["use"])[0]:
            continue
        parts = d["use"].split(".")
        cur, ok = out, True
        for part in parts[:-1]:                # a parent of the new key set to a non-object (null) is the new key's answer
            cur = cur.get(part, {}) if isinstance(cur, dict) else None
            if not isinstance(cur, dict):
                ok = False
                break
        if not ok:
            continue
        out = copy.deepcopy(out) if out is data else out
        cur = out
        for part in parts[:-1]:
            cur = cur.setdefault(part, {})
        cur[parts[-1]] = copy.deepcopy(val)
    return out


def migrate(data):
    """(config, steps): `data` carried up to SCHEMA through MIGRATIONS, and the schema numbers it passed. A config already at
    SCHEMA comes back as it is; one above SCHEMA, or a missing step, raises ValueError naming what to do."""
    n = data.get("schema", 1) if isinstance(data, dict) else None
    if not _is_int(n) or n < 1:
        raise ValueError("schema must be an integer >= 1")
    if n > SCHEMA:
        raise ValueError("config is schema %d, this plugin reads up to %d: %s" % (n, SCHEMA, UPDATE_HINT))
    out, steps = copy.deepcopy(data), []
    while n < SCHEMA:
        if n not in MIGRATIONS:
            raise ValueError("no migration from schema %d to %d in this plugin" % (n, n + 1))
        out = MIGRATIONS[n](out)
        n += 1
        out["schema"] = n
        steps.append(n)
    return out, steps


# ── merge and load ───────────────────────────────────────────────────────────────────────────────
def _merge(base, over):
    """`over` laid on `base`: objects merge key by key, everything else (lists, scalars, null) replaces."""
    out = copy.deepcopy(base)
    for k, v in over.items():
        if k.startswith("_"):
            continue
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = _merge(out[k], v)
        else:
            out[k] = copy.deepcopy(v)
    return out


def _normalise(cfg):
    """Fill what the file may leave out of an object that defaults to null, and put the flow in one shape."""
    te = cfg["pr"]["tester_exempt"]
    if isinstance(te, dict):
        cfg["pr"]["tester_exempt"] = _merge(TESTER_EXEMPT_DEFAULTS, te)
    cfg["pr"]["flow"] = [{"text": f, "done": False} if isinstance(f, str)
                         else {"text": f["text"], "done": bool(f.get("done", False))} for f in cfg["pr"]["flow"]]
    cl = cfg["pr"]["closing"]
    cl["keyword"] = cl["keyword"].capitalize()
    if isinstance(cfg["current_state"]["table"], dict):
        cfg["current_state"]["table"].setdefault("required", False)
    return cfg


def _check_effective(cfg):
    """Rules that span keys, judged on the merged result (a preset may supply one of the two keys, the file the other)."""
    cs = cfg["current_state"]
    if cs["table_own_width"] and cs["table"] is not None:
        return [("current_state.table_own_width",
                 "is true while current_state.table is set (the preset or the file): the two are alternatives, set `table: null` to check "
                 "each uncovered table against its own header")]
    if cs["pages"] is not None:
        d = page_dir(cs["pages"])
        if cs["path"] == d or cs["path"].startswith(d + "/"):
            return [("current_state.pages", "matches too much: its directory %s holds the index %s (the pages need a directory of "
                     "their own, for example kb/state/)" % (d, cs["path"]))]
        for t in KB_TYPED_DIRS:
            if d == t or d.startswith(t + "/") or t.startswith(d + "/"):
                return [("current_state.pages", "matches too much: its directory %s is, is inside or holds %s, whose files are not "
                         "ledger pages" % (d, t))]
    sp = cfg["tokens"]["spec"]
    names = [sp[k] for k in SPEC_SECTIONS]
    for k in SPEC_SECTIONS:
        if names.count(sp[k]) > 1:
            return [("tokens.spec." + k, "names the same section as another of %s (the preset or the file): no spec could hold both"
                     % ", ".join(SPEC_SECTIONS))]
    out = []
    _check_lane(cfg["merge"]["image_bump"], "merge.image_bump", out)
    return out


def _with_preset(data):
    """The defaults with the preset named by `language`, then the one named by `current_state.template`, laid over them (the file
    is laid over the result)."""
    lang = LANGUAGE_PRESETS[data.get("language", "vi")]
    base = _merge(DEFAULTS, lang) if lang else DEFAULTS             # not copied here: `effective` merges it into a deep copy
    cs = data.get("current_state")
    template = cs.get("template", "ledger") if isinstance(cs, dict) else "ledger"
    return _merge(base, {"current_state": PRESETS[template]}) if PRESETS.get(template) else base


def problems(data, strict=False):
    """Every problem `load` would report for `data` (the schema, then the rules that span keys), without reading a file. `strict`:
    for a config about to be written, an unknown key is a problem too (a typo must not reach the file)."""
    probs, notes = check(data)
    if strict:
        probs = probs + [(k, "unknown key") for k, why in notes if why == UNKNOWN_NOTE]
    return probs or _check_effective(effective(data))


def effective(data):
    """The effective config of `data`, a config that `validate` accepts: defaults, presets, then `data` without the keys this
    plugin does not know and with its deprecated keys moved forward, normalised."""
    data = _forward(_strip(data, ("obj", SCHEMA_TREE)))
    return _normalise(_merge(_with_preset(data), data))


def repo_root(start):
    """Top of the work tree that holds `start` (a linked worktree has its own copy of the committed config); `start` itself
    when git cannot tell."""
    import subprocess
    try:
        r = subprocess.run(["git", "-C", start, "rev-parse", "--show-toplevel"], capture_output=True, text=True, timeout=5)
    except Exception:
        return start
    return r.stdout.strip() if r.returncode == 0 and r.stdout.strip() else start


_NOTED = set()          # the note lines this process has printed (a gate reads the same config from several scratch copies)
LAST_NOTES = []         # the notes of the last valid file `load` read: a hook takes them from here instead of parsing twice


def _read(root):
    """(data, problems, present): the parsed file, or the problem that stops reading it."""
    path = config_path(root)
    if not os.path.lexists(path):
        return None, [], False
    if not os.path.isfile(path):
        return None, [("(file)", "%s is not a regular file" % CONFIG_REL)], True
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f), [], True
    except (OSError, ValueError, RecursionError) as e:
        return None, [("(file)", "cannot read %s: %s" % (CONFIG_REL, " ".join(str(e).split())[:200]))], True


def load(root, quiet=False):
    """(effective, problems, present). See the module docstring. The notes of a valid file go to stderr once per process
    (`WARNING .vibemaestro/sdlc.json: <key>: <note>`) unless `quiet`."""
    global LAST_NOTES
    LAST_NOTES = []
    data, probs, present = _read(root)
    if probs or not present:
        return defaults(), probs, present
    probs, notes = check(data)
    if probs:
        return defaults(), probs, True
    cfg = effective(data)
    probs = _check_effective(cfg)
    if probs:
        return defaults(), probs, True
    LAST_NOTES = list(notes)
    if not quiet:
        for k, why in notes:
            line = "WARNING %s: %s: %s\n" % (CONFIG_REL, k, why)
            if line not in _NOTED:
                _NOTED.add(line)
                sys.stderr.write(line)
    return cfg, [], True


def load_notes(root):
    """[(dotted key, note)] of the config at `root`: empty when there is none, or when it has problems (those come first)."""
    data, probs, present = _read(root)
    if probs or not present:
        return []
    probs, notes = check(data)
    return [] if probs else notes


def render_problems(problems, rel=CONFIG_REL):
    return "\n".join("%s: %s: %s" % (rel, k, why) for k, why in problems)


def get(cfg, dotted):
    """The value at a dotted key of an effective config; KeyError when the key is not part of the schema."""
    cur = cfg
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            raise KeyError(dotted)
        cur = cur[part]
    return cur


def main(argv):
    """`sdlc_config.py get <key> [--root DIR] [--default]`: rc 0 value printed, 64 bad config / bad usage / unknown key."""
    root, rest, i, plain = os.getcwd(), [], 0, False
    while i < len(argv):
        if argv[i] == "--root" and i + 1 < len(argv):
            root, i = argv[i + 1], i + 2
        elif argv[i] == "--default":
            plain, i = True, i + 1
        else:
            rest.append(argv[i])
            i += 1
    if len(rest) != 2 or rest[0] != "get":
        sys.stderr.write("usage: sdlc_config.py get <dotted.key> [--root DIR] [--default]\n")
        return 64
    cfg, probs, _present = (defaults(), [], False) if plain else load(repo_root(root), quiet=True)   # stdout is the value a caller captures
    if probs:
        sys.stderr.write(render_problems(probs) + "\n")
        return 64
    try:
        v = get(cfg, rest[1])
    except KeyError:
        sys.stderr.write("sdlc_config: no such key: %s\n" % rest[1])
        return 64
    if isinstance(v, bool):
        v = "true" if v else "false"
    sys.stdout.write((v if isinstance(v, str) else json.dumps(v, ensure_ascii=False)) + "\n" if v is not None else "null\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
