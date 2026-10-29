#!/usr/bin/env python3
"""The guarded merge: merge one pull request only when every condition holds.

    merge_guard.py --repo <owner/name> --pr <n> --head <full sha> (--brief <file> | --allow <glob,glob>)...
                   [--base <branch>] [--accept '<check>:<step prefix>']... [--behind-ok <glob,glob>]...
                   [--behind-ok-clean <docs glob,docs glob>]... [--behind auto]
                   [--require-image <tag|reference>] [--image-bump] [--admin] [--merge [--expect-plan <file>] | --status]

Dry run by default: it prints one line per condition (`ok`, `FAIL`, `n/a`, `??` for could not tell) and, when all hold, the
`merge-plan:` line. `--merge` then merges once, through `gh pr merge --squash --match-head-commit <head>` (`--merge`, a merge
commit, in the back-merge lane below), so a push between the check and the merge makes GitHub refuse it; with `--expect-plan <file>` it first refuses a plan line other than the one in the
file (the signed plan, which the kit baton passes), and it reads the PR's base again just before the merge call (gh pins the
head, not the base). `--status` only reads the PR's state (`merged <sha>`, `queued` for an auto-merge request, `pending` when a
merge run of this head was left pending and none merged since, else `open` or `closed`; then the head; rc 2 when the base config
or the merge log cannot be read).
`--help`, alone, prints the usage (rc 0); with other arguments it is misuse.
The coordinator runs it as the kit baton `kit:merge-pr` (batons/merge-pr.sh): the baton's rehearse is this dry run, its run
this `--merge`.

`merge.*` and `ci.backend` are read through the GitHub API, wherever this runs, by the same loader as every gate, at the tip of
the branch the guard merges into: `--base`, else the repository's default branch (never the branch the PR names), so a PR cannot
widen its own rules or pick its own adapter code. `merge.deny_globs` unset is rc 65: the guard refuses to run until the repo says
which paths it refuses (an empty list is a valid answer). Bootstrap, the one exception: when the base has no config file at all
and the PR adds `.vibemaestro/sdlc.json` (status added), that file is read at the PR's head for this one merge (printed, logged
and in the plan line as `bootstrap`); it must set `merge.deny_globs` and name no `external:` adapter (else rc 65), `--admin`,
`--image-bump` and `--require-image` are rc 64, deny adds the init default (sdlc_config.merge_deny_floor: MERGE_DENY_DEFAULT plus each `rules.dirs` folder of the added config under
`.vibemaestro/`) to the PR's globs and
lets through only the config and Markdown files under its `.vibemaestro/` rules directory, and the brief applies as always.

Conditions:
  open, not-draft    the PR is open and not a draft
  head               its head is the --head the worker reported (the full SHA: a short prefix can be ground)
  base               it targets the branch the guard merges into (--base, else the repository's default branch)
  checks             the latest run per check (kind, app, workflow id, name; by parsed start time, a run not started yet is
                     the newest, a completed run without a readable start time is red; a skipped run never outranks a run
                     that is not skipped) is green; skipped and neutral are
                     ignored; a commit status can only be red (anyone with push access can post one); a red check run passes
                     only through --accept: its conclusion is failure and EVERY failed step of its job starts with an accepted
                     prefix of that exact check name, as whole words; with merge.required_checks empty, at least one green
                     check run (an empty list is red)
  required           each name in merge.required_checks (a check name, or <workflow>/<name>) has a latest check run, and every
                     latest check run of that name is a success
  mergeable          GitHub reports no conflict (UNKNOWN is read again, then could not conclude); read before the CI runs, and
                     CONFLICTING stops the run there (rc 1), so nobody waits on CI for a PR that cannot merge
  backmerge          only for a PR into the repository's default branch (n/a otherwise, and when there is no branch `release`
                     and the head ref is not backmerge/*): a head ref `backmerge/*` merges with a merge commit, not a squash,
                     so `release` stays an ancestor of the default branch, and needs its head on `release` (the compare API:
                     `release` ahead of or identical to the head; no `release` is a FAIL); any other PR whose head is already on
                     `release` is refused, since a squash of it would cut `release` off the default branch's history
  files              every changed file was read (a rename counts its source too)
  deny               no changed path matches merge.deny_globs, whatever the case (normal lane)
  brief              every changed path matches an allowed glob, case-sensitively
  links              no changed path is a symlink or a submodule at the head
  own-inputs         no changed path is the config file or an `external:` adapter the config names (whatever the deny globs)
  behind             not behind the base; or behind only by base files that --behind-ok lists and the PR does not touch (the
                     base files are always printed); --behind-ok-clean <docs globs> also accepts a base file the PR changed too
                     when it matches, both sides modified it in place (no add, remove or rename), it is a regular file at the
                     base, `git merge-file` of (base tip, merge base, head) is clean, GitHub's test merge (parents base tip and
                     head) holds the same bytes, and, for current_state.path, the merged text passes the current-state check
                     (caps included); each accepted file is printed and logged. A docs glob ends in `.md` and starts with a
                     literal segment other than tests, test, plugins, .github, .vibemaestro (else rc 64); it also counts as a
                     --behind-ok glob. --behind auto (alone: with --behind-ok or --behind-ok-clean it is rc 64) lists nothing
                     and accepts a behind PR from the compare API alone (the merge base, behind_by and the files the base
                     changed since): GitHub's test merge, which GitHub does not always rebuild after the base moves, is no gate and
                     a stale one never refuses; it is read where it still adds information: (a) `mergeable` false is FAIL at once,
                     and a file both sides changed needs a fresh test merge (parents base tip and head, mergeable true) as the
                     second opinion on git's merge (stale: asked again 3 times, 2 s apart, then ??; a PR sharing no file reads it
                     once and does not wait); a base path that is a file where the PR has a directory of that name (or the
                     reverse), that differs from a PR path only in case or Unicode form, or that sits in a directory (at any level) the PR
                     moved a file out of (or the reverse: a directory rename), is FAIL; (b)
                     every file both sides changed is a docs path (the docs-glob rule applied to the path, in no dot-directory
                     or agent-instruction directory, not CLAUDE.md, AGENTS.md or the like) and passes the --behind-ok-clean
                     checks above; (c) with
                     merge.planner, the suites the base's files wake (every base file, shared ones too: `--suites --woken`, and
                     `--old <dir>` with the merge base's inputs when the base changed one) and the suites CI plans for the PR's
                     files (`--suites`) do not meet (a side that needs every suite, `@full`, meets any non-empty side, and the
                     PR's side meets any base file at all); without
                     one, or in bootstrap, every base file is a docs path. The planner's script and inputs are read at the base
                     tip only (the --old inputs at the merge base), each a regular file there, written into an empty temp dir
                     and run there as `<python> -I -B <script> --suites [--woken] [--old <dir>]` (NUL-separated paths on stdin;
                     it prints one suite per line or one line `@full <reason>`), with Python's sockets refused, an environment
                     of an empty PATH, HOME that dir and LC_ALL=C, and a 60 s timeout: no code or data of the head reaches it.
                     The plan line says `behind <n> auto`; the log line gains behind_auto and both sides' suites
  image              --require-image and the lane's new tag exist in the registry
  lane-*             --image-bump (only when merge.image_bump.enabled) replaces deny: lane-files, lane-deny, lane-tag-only
                     (a changed line of a tag file changes only the tag of the configured image reference, or is `key: <tag>`;
                     a tag file is changed in place, never renamed or removed), lane-one-tag, lane-revision
--admin (only when merge.admin_bypass) adds `--admin` to gh pr merge; it changes no condition.

Every run that gets past its arguments appends one JSON line to the merge log (merge.log under $XDG_STATE_HOME/vibemaestro,
else ~/.local/state/vibemaestro; default merge-log.jsonl, always the default in bootstrap), mode 0600, never the PR's title or
body. A log that cannot be written is rc 2, before any merge.

Exit codes (the gates'): 0 every condition holds (dry run) or merged; 1 a condition fails, each named; 2 could not conclude (a
`gh` error, mergeable still unknown, a truncated tree, the merge refused by GitHub or left pending, the PR not readable after
the merge, an adapter that exits, the log, a guard input not found in the base's trees, a test merge still stale, a planner
that cannot answer); 64 misuse (also an argument or a --brief/--expect-plan file that is not UTF-8, a --behind-ok-clean glob
that is not docs-only, --behind with another value than auto or beside --behind-ok or --behind-ok-clean, --admin without
merge.admin_bypass or in bootstrap, --image-bump with the lane off or in bootstrap, --require-image without a registry, naming
another image or in bootstrap); 65 invalid config, or merge.deny_globs unset (in bootstrap: the added config invalid, without merge.deny_globs,
or naming an external adapter).

Standard library only, Python 3.8+.
"""
import argparse
import datetime
import hashlib
import json
import os
import posixpath
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unicodedata
import urllib.parse

sys.dont_write_bytecode = True
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
import gate_common as G  # noqa: E402  (puts the loader's directory on the path)
import sdlc_config as C  # noqa: E402
import backends as B  # noqa: E402
import current_state as CS  # noqa: E402  (next to the loader, in ../scripts)

OK, RED, INFRA, USAGE, CONFIG = G.OK, G.RED, G.INFRA, G.USAGE, G.CONFIG
SHA_RE = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")
REPO_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9_.-]+$")
TAG_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$")
PR_FIELDS = "number,state,isDraft,baseRefName,headRefName,headRefOid,mergeable,changedFiles,url"
# the back-merge lane: the release channel branch, and the head ref prefix of its back-merges
RELEASE_BRANCH, BACKMERGE_PREFIX = "release", "backmerge/"
# what git refuses in a branch name (git check-ref-format --branch): control characters and space, ~ ^ : ? * [ \, "..", "@{",
# "//", a component that starts with "." or ends with ".lock", a leading "/" or "-", a trailing "/" or ".", "@" alone; any other
# name, `+`, `#` and non-ASCII included, is a branch (tests/test-merge-guard.sh compares this with git itself)
BRANCH_BAD = re.compile(r"[\x00-\x20\x7f~^:?*\[\\]|\.\.|@\{|//|^[/-]|(^|/)\.|[/.]$|\.lock(/|$)|^@$")
# a `key: value` or `KEY=value` line whose whole value is a tag (a label, an env variable): the other form of a tag line
KEY_LINE = re.compile(r"""(\s*-?\s*[A-Za-z0-9_.\-/]+\s*[:=]\s*)(["']?)([A-Za-z0-9_][A-Za-z0-9_.-]{0,127})\2(\s*)""")
TIME_RE = re.compile(r"(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.(\d{1,9}))?(Z|[+-]\d\d:\d\d)")
MERGEABLE_REREADS, MERGEABLE_WAIT_S = 3, 2
TEST_MERGE_READS, TEST_MERGE_WAIT_S = 4, 2           # --behind auto (a): a stale test merge is asked again, 3 times, 2 s apart
PLANNER_TIMEOUT_S = 60
SUITE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$")
# --behind auto runs the base's planner through this: Python's sockets refuse, then the script runs as __main__ with its argv
NO_NET = ("import os, runpy, socket, sys\n"
          "def _refuse(*a, **k):\n"
          "    raise OSError('the merge guard runs the planner with no network')\n"
          "socket.socket = socket.create_connection = socket.getaddrinfo = socket.socketpair = _refuse\n"
          "sys.argv = sys.argv[1:]\n"
          "sys.path.insert(0, os.path.dirname(sys.argv[0]))\n"
          "runpy.run_path(sys.argv[0], run_name='__main__')\n")
PR_FILES_CAP, COMPARE_FILES_CAP = 3000, 300
LINK_MODES = {"120000": "symlink", "160000": "submodule"}
IGNORED = ("skipped", "neutral")
LOG_NAME = "merge-log.jsonl"
# the first segment a --behind-ok-clean glob may not start with: test code, plugin code, CI, the guard's own config and rules
DOC_ROOTS_REFUSED = ("tests", "test", "plugins", ".github", ".vibemaestro")
# Markdown an agent loads as instructions wherever it stands (by the name before its first dot: CLAUDE.local.md,
# AGENTS.override.md), and the directories that hold such files: never in the docs class of --behind auto (a name list, so the
# config's rules directories are refused too: doc_path's `cfg`)
AGENT_MD = ("claude", "agents", "agent", "gemini", "qwen", "crush", "skill")
AGENT_DIRS = ("skills", "agents", "commands", "rules", "prompts", "hooks")


class Usage(Exception):
    pass


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise Usage(message)


def branch_ok(name):
    if not isinstance(name, str) or not name or BRANCH_BAD.search(name):
        return False
    try:
        name.encode("utf-8")                           # a lone surrogate (bytes that are not UTF-8 on the command line)
    except UnicodeEncodeError:
        return False
    return True


def say(msg, out=None):
    (out or sys.stdout).write(msg + "\n")
    (out or sys.stdout).flush()


def sha256(data):
    return hashlib.sha256(data if isinstance(data, bytes) else data.encode("utf-8", "surrogateescape")).hexdigest()


def globs_of(text, where):
    out = []
    for g in text:
        if not C.glob_ok(g):
            raise Usage("%s: %r %s" % (where, g, C.GLOB_RULE))
        out.append(g)
    return out


def docs_only(g):
    """None when `g` can only match Markdown files outside test, plugin, CI and config trees, else why not. A docs glob ends in the
    literal `.md` (so no plugin.json, lockfile or code file matches) and starts with a literal segment (so it cannot reach
    `tests/**`, `plugins/**` or `.github/**` through a wildcard)."""
    segs = g.split("/")
    if any(c in segs[0] for c in "*?"):
        return "its first segment must be a literal name, not a wildcard (it could reach tests/, plugins/ or .github/)"
    if segs[0].lower() in DOC_ROOTS_REFUSED:
        return "it starts in %s/, which holds code, tests or the guard's own inputs" % segs[0]
    if not segs[-1].endswith(".md"):
        return "its last segment must end in the literal .md (Markdown only: no plugin.json, lockfile or code file)"
    return None


def doc_path(p, cfg=None):
    """True when the path `p` is in the docs class of --behind auto: Markdown outside the test, plugin, CI and config trees (the
    rule a --behind-ok-clean glob follows, applied to a path), in no dot-directory (.claude/, .github/, …), no directory that
    holds agent instructions (skills/, rules/, …, and `rules.dirs` of the config) and not a file an agent loads as instructions
    (CLAUDE.md, AGENTS.md, SKILL.md, …): those are read as orders, not as text."""
    segs, low = p.split("/"), p.lower()
    dirs = [posixpath.normpath(d).lower() for d in ((cfg or {}).get("rules") or {}).get("dirs") or []]   # ./ops is ops, . is all
    return (p.endswith(".md") and segs[0].lower() not in DOC_ROOTS_REFUSED and not any(s.startswith(".") for s in segs)
            and segs[-1].lower().split(".")[0] not in AGENT_MD and not any(s.lower() in AGENT_DIRS for s in segs[:-1])
            and not any(d == "." or low.startswith(d + "/") for d in dirs))


def make_parser():
    p = Parser(prog="merge_guard.py", allow_abbrev=False, add_help=False, description="The guarded merge (dry run unless --merge).")
    p.add_argument("--repo", required=True)
    p.add_argument("--pr", required=True)
    p.add_argument("--head", required=True)
    p.add_argument("--brief", action="append", default=[])
    p.add_argument("--allow", action="append", default=[])
    p.add_argument("--base")
    p.add_argument("--accept", action="append", default=[])
    p.add_argument("--behind-ok", action="append", default=[], dest="behind_ok")
    p.add_argument("--behind-ok-clean", action="append", default=[], dest="behind_ok_clean")
    p.add_argument("--behind", dest="behind_mode")
    p.add_argument("--require-image", dest="require_image")
    p.add_argument("--image-bump", action="store_true", dest="image_bump")
    p.add_argument("--admin", action="store_true")
    mode = p.add_mutually_exclusive_group()
    mode.add_argument("--merge", action="store_true")
    mode.add_argument("--status", action="store_true")
    p.add_argument("--expect-plan", dest="expect_plan")
    return p


def parse(argv):
    a = make_parser().parse_args(argv)
    if not REPO_RE.fullmatch(a.repo):
        raise Usage("--repo must be <owner>/<name>, got %r" % a.repo)
    if not re.fullmatch(r"[1-9][0-9]{0,9}", a.pr):
        raise Usage("--pr must be a pull request number, got %r" % a.pr)
    a.head = a.head.lower()
    if not SHA_RE.fullmatch(a.head):
        raise Usage("--head must be the full commit SHA the worker reported (40 or 64 hex digits): a short prefix can be "
                    "matched by another commit, got %r" % a.head)
    if a.base is not None and not branch_ok(a.base):
        raise Usage("--base must be a branch name, got %r" % a.base)
    if a.status:
        return a
    a.expected = None
    if a.expect_plan is not None:
        if not a.merge:
            raise Usage("--expect-plan goes with --merge (it is the plan the merge must still have)")
        try:
            with open(a.expect_plan, encoding="utf-8") as fh:
                a.expected = [ln for ln in fh.read().split("\n") if ln]
        except (OSError, UnicodeDecodeError) as e:
            raise Usage("--expect-plan %s cannot be read as UTF-8 text: %s" % (a.expect_plan, getattr(e, "strerror", None) or e))
    allowed = []
    for f in a.brief:
        try:
            with open(f, encoding="utf-8") as fh:
                lines = [ln.strip() for ln in fh.read().split("\n")]
        except (OSError, UnicodeDecodeError) as e:
            raise Usage("--brief %s cannot be read as UTF-8 text: %s" % (f, getattr(e, "strerror", None) or e))
        allowed += globs_of([ln for ln in lines if ln and not ln.startswith("#")], "--brief %s" % f)
    for v in a.allow:
        allowed += globs_of([g.strip() for g in v.split(",") if g.strip()], "--allow")
    if not allowed:
        raise Usage("give the brief's scope: --brief <file> (one glob per line) or --allow <glob,glob>")
    a.allowed = sorted(set(allowed))
    for r in a.accept:
        check, sep, prefix = r.partition(":")
        if not sep or not check or not prefix.strip():
            raise Usage("--accept takes '<check>:<step prefix>', got %r" % r)
    a.behind_globs = []
    for v in a.behind_ok:
        a.behind_globs += globs_of([g.strip() for g in v.split(",") if g.strip()], "--behind-ok")
    a.clean_globs = []
    for v in a.behind_ok_clean:
        for g in globs_of([g.strip() for g in v.split(",") if g.strip()], "--behind-ok-clean"):
            why = docs_only(g)
            if why:
                raise Usage("--behind-ok-clean %r is not a docs glob: %s" % (g, why))
            a.clean_globs.append(g)
    if a.behind_mode is not None and a.behind_mode != "auto":
        raise Usage("--behind takes auto, got %r" % a.behind_mode)
    a.auto = a.behind_mode == "auto"
    if a.auto and (a.behind_globs or a.clean_globs):
        raise Usage("--behind auto decides a behind PR by itself: it does not go with --behind-ok or --behind-ok-clean")
    if a.require_image is not None and not a.require_image.strip():
        raise Usage("--require-image takes a tag or a full image reference")
    return a


# ── GitHub reads ───────────────────────────────────────────────────────────────────────────────────────────────────────────────
def pr_view(a, fields):
    rc, out, err = B.gh(["pr", "view", a.pr, "--repo", a.repo, "--json", fields])
    if rc != 0:
        raise G.Infra("gh pr view %s failed: %s" % (a.pr, err[:200]))
    vals = B.json_values(out)
    if len(vals) != 1 or not isinstance(vals[0], dict):
        raise G.Infra("gh pr view printed no JSON object")
    return vals[0]


def state_home():
    return G.state_home()


def match_fold(g, p):
    return C.glob_match(g.lower(), p.lower())


# ── checks ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
def _num(x):
    try:
        return int(x)
    except (TypeError, ValueError):
        return 0


def parse_time(s):
    """Seconds since the epoch of an ISO 8601 time with a zone (`2026-10-16T12:00:00.5Z`, `…+07:00`), else None."""
    m = TIME_RE.fullmatch(s) if isinstance(s, str) else None
    if not m:
        return None
    try:
        dt = datetime.datetime(*[int(x) for x in m.groups()[:6]], tzinfo=datetime.timezone.utc)
    except ValueError:
        return None
    zone = m.group(8)
    shift = 0 if zone == "Z" else (1 if zone[0] == "+" else -1) * (int(zone[1:3]) * 3600 + int(zone[4:6]) * 60)
    return dt.timestamp() + (float("0." + m.group(7)) if m.group(7) else 0.0) - shift


def latest_runs(runs):
    """The newest run per check (kind, app, workflow id, name), by parsed start time. A run without a readable start time ranks
    newest: one not started yet is pending, a completed one is marked `_bad_time` (red), so neither can hide a red run. A skipped
    run tested nothing, so it never outranks a run that is not skipped (green, red or pending), whatever its time (a
    late skipped duplicate of a draft event hid the green run of a required check)."""
    best = {}
    for r in runs:
        key = (r.get("kind") or "check", r.get("app") or "", r.get("workflow_id") or r.get("workflow") or "", r.get("name") or "")
        t = parse_time(r.get("started_at"))
        if t is None and r.get("status") == "completed":
            r = dict(r, _bad_time=True)
        rank = (r.get("conclusion") != "skipped", float("inf") if t is None else t, _num(r.get("id")))
        if key not in best or rank >= best[key][0]:
            best[key] = (rank, r)
    return sorted((r for _rank, r in best.values()), key=lambda r: (r.get("workflow") or "", r.get("name") or ""))


def label(r):
    return "%s/%s" % (r["workflow"], r.get("name")) if r.get("workflow") else (r.get("name") or "?")


def word_prefix(name, prefix):
    """`prefix` starts `name` as whole words: equal, or followed by a space, `(` or `:`."""
    return name == prefix or (name.startswith(prefix) and name[len(prefix)] in " (:")


def every_step_accepted(steps, prefixes):
    return all(any(word_prefix(s, p) for p in prefixes) for s in steps)


def accepted_prefixes(a, name):
    """The step prefixes the --accept rules give the check `name`: a rule is `<name>:<prefix>`, so a check name may hold ':'
    itself; trailing spaces of a prefix are dropped (the whole-word match supplies the boundary)."""
    head = (name or "") + ":"
    return [r[len(head):].rstrip() for r in a.accept if name and r.startswith(head) and r[len(head):].strip()]


def acceptance(a, ci, r):
    """True when this red run is accepted, else the reason it is not ("" when no --accept names it)."""
    prefixes = accepted_prefixes(a, r.get("name"))
    if not prefixes:
        return ""
    if r.get("conclusion") != "failure":
        return " (only a failure can be accepted)"
    try:
        steps = ci.failed_steps(a.repo, r)
    except G.Infra as e:
        return " (its steps cannot be read: %s)" % e
    if steps is None:
        return " (its steps cannot be read)"
    if not steps:
        return " (no failed step to judge)"
    if every_step_accepted(steps, prefixes):
        return True
    return " (failed steps not accepted: %s)" % ", ".join(s for s in steps if not any(word_prefix(s, p) for p in prefixes))


def checks(a, mcfg, ci, V):
    try:
        runs = ci.runs(a.repo, a.head) or []
    except G.Infra as e:
        V.unknown("checks", "the CI backend could not read the runs: %s" % e)
        V.unknown("required", "the runs are not known")
        return
    latest = latest_runs(runs)
    green, ignored, accepted, red, notes = 0, 0, [], [], []
    for r in latest:
        concl = r.get("conclusion")
        if r.get("_bad_time"):
            red.append("%s=%s with no readable start time" % (label(r), concl))
        elif r.get("status") != "completed" or concl is None:
            red.append("%s=pending" % label(r))
        elif concl == "success" and r.get("kind") != "status":
            green += 1
        elif concl == "success" or concl in IGNORED:        # a status in success is not counted: anyone with push access posts one
            ignored += 1
        else:
            why = acceptance(a, ci, r)
            if why is True:
                accepted.append(label(r))
                notes.append("accepted %s: every failed step starts with an accepted prefix" % label(r))
            else:
                red.append("%s=%s%s" % (label(r), concl, why))
    required = mcfg["required_checks"]
    if not required and green == 0:
        red.append("no green check (an empty or all-skipped list is red)")
    for rule in a.accept:
        if not any(r.get("name") and rule.startswith(r["name"] + ":") for r in latest):
            notes.append("note: --accept %s names no check that has a run" % rule)
    V.cond("checks", not red, "%d latest of %d runs: %d green check run(s), %d skipped, neutral or status, %d accepted red%s"
           % (len(latest), len(runs), green, ignored, len(accepted), ("; red: " + ", ".join(red[:8])) if red else ""), notes)
    if not required:
        V.na("required", "merge.required_checks is empty: at least one green check is asked instead")
        return
    missing = []
    for name in required:
        mine = [r for r in latest if r.get("kind") != "status" and name in (r.get("name"), label(r))]
        if not mine:
            missing.append("%s (no check run)" % name)
        elif any(r.get("status") != "completed" or r.get("conclusion") != "success" for r in mine):
            missing.append("%s (%s)" % (name, ",".join(sorted(set(str(r.get("conclusion") or "pending") for r in mine)))))
    V.cond("required", not missing, "%d required check(s)%s" % (len(required), ("; not green: " + ", ".join(missing)) if missing else ", all green"))


# ── files ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
def pr_files(a):
    """The PR's changed files, read once per run."""
    if getattr(a, "_files", None) is None:
        a._files = B.api_list("repos/%s/pulls/%s/files?per_page=100" % (a.repo, a.pr))
    return a._files


def changed(a, pr, V):
    """(files, paths) of the PR, or (None, None) when they cannot be read whole."""
    n = pr.get("changedFiles")
    if not isinstance(n, int) or n > PR_FILES_CAP:
        V.unknown("files", "the PR counts %r changed files; the API lists at most %d" % (n, PR_FILES_CAP))
        return None, None
    try:
        files = pr_files(a)
    except G.Infra as e:
        V.unknown("files", "the changed files cannot be read: %s" % e)
        return None, None
    paths = []
    for f in files:
        paths.append(f.get("filename") or "")
        if f.get("previous_filename"):
            paths.append(f["previous_filename"])
    V.cond("files", len(files) == n, "%d changed files read, the PR counts %d (a rename counts its source too)" % (len(files), n))
    return files, sorted(set(p for p in paths if p))


def guard_inputs(cfg):
    """The files the guard reads at the base to judge every PR: the config, and each `external:` adapter it names."""
    out = {C.CONFIG_REL}
    reg = cfg["merge"]["image_bump"]["registry"] or {}
    for spec in (cfg["ci"]["backend"], reg.get("backend")):
        if isinstance(spec, str) and spec.startswith("external:"):
            out.add(posixpath.normpath(spec[len("external:"):]))     # as git prints it, whatever the config spelled
    return out


def base_modes(a, base_sha, paths):
    """{path: its git mode at the base, None when absent}, walking the base's trees one level at a time (a few small reads,
    never the whole tree). A directory on the way that is not a tree (a symlinked directory) gives that entry's mode."""
    trees, out = {}, {}

    def entries(sha):
        if sha not in trees:
            trees[sha] = B.api("repos/%s/git/trees/%s" % (a.repo, sha)).get("tree") or []
        return trees[sha]
    for p in paths:
        sha, mode, parts = base_sha, None, p.split("/")
        for i, seg in enumerate(parts):
            ent = next((e for e in entries(sha) if e.get("path") == seg), None)
            if ent is None:
                mode = None
                break
            if i < len(parts) - 1 and ent.get("mode") == "040000":
                sha = ent.get("sha")
                continue
            mode = ent.get("mode")
            break
        out[p] = mode
    return out


def own_inputs(cfg, paths, modes, V):
    """A PR that changes the guard's own inputs is refused whatever the deny globs say: once merged, it would judge every PR. An
    input that is a symlink at the base is refused too: the contents API serves its target, which a PR could change unseen. Every
    input exists by now (the config was read, each adapter loaded), so one the walk cannot find (a truncated tree) is unknown."""
    missing = sorted(p for p, m in modes.items() if m is None)
    if missing:
        V.unknown("own-inputs", "not found in the base's trees, so their mode is unknown: %s" % ", ".join(missing))
        return
    mine = sorted(set(paths) & guard_inputs(cfg))
    links = [p for p, m in sorted(modes.items()) if m is not None and m not in ("100644", "100755")]
    why = (["changed: " + ", ".join(mine)] if mine else []) + (["not a regular file at the base: " + ", ".join(links)] if links else [])
    V.cond("own-inputs", not why, "the config and the adapters it names%s" % (("; " + "; ".join(why)) if why else " are unchanged files"))


def links(a, files, V):
    try:
        tree = B.api("repos/%s/git/trees/%s?recursive=1" % (a.repo, a.head))
    except G.Infra as e:
        V.unknown("links", "the head's tree cannot be read: %s" % e)
        return
    if tree.get("truncated"):
        V.unknown("links", "GitHub truncated the head's tree: the modes of the changed files cannot all be read")
        return
    modes = dict((e.get("path"), e.get("mode")) for e in tree.get("tree") or [])
    found, missing = [], []
    for f in files:
        if f.get("status") == "removed":
            continue
        p = f.get("filename")
        m = modes.get(p)
        if m is None:
            missing.append(p)
        elif m in LINK_MODES:
            found.append("%s (%s)" % (p, LINK_MODES[m]))
    if found:
        V.cond("links", False, "a link can point anywhere, whatever glob it sits in: %s" % ", ".join(found[:8]))
    elif missing:
        V.unknown("links", "not in the head's tree: %s" % ", ".join(missing[:8]))
    else:
        V.cond("links", True, "no changed path is a symlink or a submodule")


def behind(a, base_sha, files, paths, cfg, V):
    """(commits the head is behind, the shared files --behind-ok-clean accepted)."""
    try:
        cmp_ = B.api("repos/%s/compare/%s...%s" % (a.repo, a.head, base_sha))
    except G.Infra as e:
        V.unknown("behind", "the comparison with the base cannot be read: %s" % e)
        return 0, []
    ahead = cmp_.get("ahead_by")
    if not isinstance(ahead, int):
        V.unknown("behind", "the comparison with the base has no ahead_by")
        return 0, []
    if ahead == 0:
        V.cond("behind", True, "not behind the base %s" % base_sha[:12])
        return 0, []
    bfiles = cmp_.get("files") or []
    base_files = sorted(set([f.get("filename") for f in bfiles if f.get("filename")] +
                            [f["previous_filename"] for f in bfiles if f.get("previous_filename")]))
    notes = ["base file since the merge base: %s" % f for f in base_files]
    listed, accepted = a.behind_globs + a.clean_globs, []
    if len(bfiles) >= COMPARE_FILES_CAP:
        V.unknown("behind", "behind by %d commits and %d or more base files: the list is cut" % (ahead, COMPARE_FILES_CAP), notes)
    elif a.auto and paths is None:
        V.unknown("behind", "behind by %d commit(s); the PR's files are not known, so --behind auto cannot decide" % ahead, notes)
    elif a.auto:
        accepted = behind_auto(a, base_sha, cmp_, files, paths, base_files, cfg, ahead, notes, V)
    elif not listed:
        V.cond("behind", False, "behind the base by %d commit(s), %d base file(s) listed below; --behind-ok <globs> accepts them "
               "when none is a file of this PR" % (ahead, len(base_files)), notes)
    elif paths is None:
        V.unknown("behind", "behind by %d commit(s); the PR's files are not known, so an overlap cannot be ruled out" % ahead, notes)
    else:
        unlisted = [f for f in base_files if not any(C.glob_match(g, f) for g in listed)]
        overlap = sorted(set(base_files) & set(paths))
        accepted, refused, unknown = [], overlap, []
        if overlap and a.clean_globs:
            accepted, refused, unknown = clean_shared(a, base_sha, cmp_, files, overlap, cfg)
        notes += ["accepted clean: %s (%s)" % acc for acc in accepted]
        why = (["not in --behind-ok: " + ", ".join(unlisted[:8])] if unlisted else []) + \
              (["also files of this PR: " + ", ".join(refused[:8])] if refused else [])
        if why or not unknown:
            V.cond("behind", not why, "behind the base by %d commit(s); %s" % (ahead, "; ".join(why) or (
                "only base files --behind-ok lists, none of the PR's" if not accepted else
                "only base files --behind-ok lists; %d file(s) of this PR merge clean (--behind-ok-clean)" % len(accepted))), notes)
        else:
            V.unknown("behind", "behind by %d commit(s); cannot tell whether a shared file merges clean: %s"
                      % (ahead, "; ".join(unknown[:4])), notes)
        if why or unknown:
            accepted = []
    return ahead, [p for p, _d in accepted]


MERGE_BASE = "; merge the base into the branch"


def behind_auto(a, base_sha, cmp_, files, paths, base_files, cfg, ahead, notes, V):
    """--behind auto: a behind PR passes when (b) every file both sides changed is a docs file that merges clean, and (c) the
    base's files and the PR's wake no suite in common (the base's planner), or, with no planner (or in bootstrap), the base's
    files are all docs. The decision reads the compare API only (the merge base, the base's files since it, behind_by): GitHub's
    test merge is not a gate, since GitHub does not always rebuild it after the base moves. It is read where it still adds
    information, and only when fresh (parents base tip and head): `mergeable` false is a conflict; and a file both sides changed
    needs it as the second opinion on git's merge. A stale test merge on its own never refuses. Returns the shared files accepted
    clean."""
    head = "behind the base by %d commit(s); --behind auto" % ahead
    shared = sorted(set(base_files) & set(paths))
    clash = path_clashes(base_files, paths, dir_moves(cmp_.get("files")), dir_moves(files))
    if clash:
        notes.append("(b) and (c) not read")
        V.cond("behind", False, "%s: (b) a path of the base clashes with one of this PR: %s%s" % (head, "; ".join(clash[:4]), MERGE_BASE), notes)
        return []
    # a disjoint PR needs no test merge: one read, no waiting; a shared file waits for GitHub to rebuild it
    try:
        tm, why = fresh_test_merge(a, base_sha, TEST_MERGE_READS if shared else 1)
    except G.Infra as e:
        tm, why = None, ("??", "GitHub's test merge cannot be read: %s" % e)
    if tm is None and why[0] == "FAIL":
        notes.append("(b) and (c) not read")
        V.cond("behind", False, "%s: (a) %s%s" % (head, why[1], MERGE_BASE), notes)
        return []
    a_say = "(a) test merge %s fresh" % tm[:12] if tm else "(a) test merge not fresh: not needed"
    notes.append("(a) GitHub's test merge %s: parents base tip and head, mergeable" % tm[:12] if tm else
                 "(a) GitHub's test merge is not fresh (%s): the compare API decides" % why[1])
    planner = None if getattr(a, "boot", False) else cfg["merge"]["planner"]
    if getattr(a, "boot", False) and cfg["merge"]["planner"]:
        notes.append("(c) bootstrap: merge.planner is in the config this PR adds, so it is not used")
    accepted, refused, unknown = [], [], []
    if shared:
        accepted, refused, unknown = clean_shared(a, base_sha, cmp_, files, shared, cfg, lambda p: doc_path(p, cfg), tm,
                                                  None if tm else "cannot cross-check git's merge with GitHub's test merge: %s" % why[1])
        refused = ["%s (not docs: a clean merge of code, config or a planner's map is not a tested whole)" % p
                   if p in shared else p for p in refused]
    notes += ["(b) accepted clean: %s (%s)" % acc for acc in accepted]
    if refused:
        notes.append("(c) not read")
        V.cond("behind", False, "%s: (b) also files of this PR: %s%s" % (head, ", ".join(refused[:8]), MERGE_BASE), notes)
        return []
    if unknown:
        notes.append("(c) not read")
        V.unknown("behind", "%s: (b) cannot tell whether a shared file merges clean: %s" % (head, "; ".join(unknown[:4])), notes)
        return []
    # every base file counts on the base's side, a shared one too: its merged text is new to the suites that read it
    verdict, detail = suites_apart(a, base_sha, cmp_, planner, base_files, paths, notes, cfg)
    b = "(b) %s" % ("%d shared file(s) merge clean" % len(accepted) if accepted else "no file of this PR changed on the base")
    if verdict == "??":
        V.unknown("behind", "%s: %s; (c) %s" % (head, b, detail), notes)
        return []
    V.cond("behind", verdict == "ok", "%s: %s; %s; (c) %s%s" % (head, a_say, b, detail, "" if verdict == "ok" else MERGE_BASE), notes)
    return accepted if verdict == "ok" else []


def fold(p):
    """A path as a case-insensitive, normalising checkout (macOS, Windows) sees it: NFC, case-folded."""
    return unicodedata.normalize("NFC", p).casefold()


def dir_moves(entries):
    """[(source, destination)] of the renames in a compare or PR file list whose destination is outside some directory of the
    source: git may apply them to the other side's files of such a directory as a directory rename (moved into the new
    place, or a conflict). A copy is no move; a file moved down into a subdirectory leaves no directory."""
    return [(f["previous_filename"], f["filename"]) for f in entries or []
            if f.get("status") == "renamed" and f.get("previous_filename") and f.get("filename")
            and left_dirs(f["previous_filename"], f["filename"])]


def left_dirs(src, dst):
    """The directories of `src` (every ancestor, nearest first, the root excluded) that `dst` is not inside. Compared exactly,
    not folded: a directory renamed to another case or Unicode form is a rename for git on a case-sensitive checkout."""
    out, d = [], posixpath.dirname(src)
    while d:
        if not (dst + "/").startswith(d + "/"):
            out.append(d)
        d = posixpath.dirname(d)
    return out


def path_clashes(base_files, paths, base_moves=(), pr_moves=()):
    """The base's paths that clash with the PR's without being the same name, which a test merge would have shown as a conflict
    and the two file lists cannot: a file on one side where the other has a directory of that name, names that differ only in
    case or Unicode form (one file on a case-insensitive or normalising checkout), and a file moved out of a directory on one
    side (`base_moves`, `pr_moves`: dir_moves) while the other side has a path in that directory (a directory rename).
    [text] for each pair, sorted."""
    def dirs(ps):
        out = {}
        for p in ps:
            parts = p.split("/")
            for k in range(1, len(parts)):
                out.setdefault(fold("/".join(parts[:k])), p)
        return out

    def by_fold(ps):
        out = {}
        for p in ps:
            out.setdefault(fold(p), set()).add(p)
        return out
    bdirs, pdirs = dirs(base_files), dirs(paths)
    bfold, pfold = by_fold(base_files), by_fold(paths)
    found = []
    for k, bps in sorted(bfold.items()):
        for bp in sorted(bps):
            for pp in sorted(pfold.get(k, ())):
                if pp != bp:
                    found.append("%s and %s differ only in case or Unicode form" % (bp, pp))
            if k in pdirs:
                found.append("the base's file %s is a directory in this PR (%s)" % (bp, pdirs[k]))
    for k, pps in sorted(pfold.items()):
        for pp in sorted(pps):
            if k in bdirs:
                found.append("this PR's file %s is a directory in the base (%s)" % (pp, bdirs[k]))
    for who, moves, other, where in (("the base", base_moves, paths, "this PR"), ("this PR", pr_moves, base_files, "the base")):
        for src, dst in moves:
            hit = [p for d in left_dirs(src, dst) for p in other if fold(p).startswith(fold(d) + "/")]
            if hit:
                found.append("%s moved %s to %s, a directory rename git may apply to %s's %s" % (who, src, dst, where, hit[0]))
    return found


def fresh_test_merge(a, base_sha, reads=TEST_MERGE_READS):
    """GitHub's test merge as --behind auto reads it: (test merge SHA, None) when it has the parents [base tip, head] and
    `mergeable` is true in the same answer; else (None, (verdict, why)): FAIL for `mergeable` false (a conflict, whatever the
    parents say: the parents of a test merge GitHub did not rebuild cannot tell an old conflict from a new one, and a refusal
    only asks for the base to be merged), ?? while it
    stays stale (asked again `reads` - 1 times, TEST_MERGE_WAIT_S apart: the read itself makes GitHub recompute it)."""
    seen = ""
    for i in range(reads):
        if i:
            time.sleep(TEST_MERGE_WAIT_S)
        pr = B.api("repos/%s/pulls/%s" % (a.repo, a.pr)) or {}
        m, ok = (pr.get("merge_commit_sha") or "").lower(), pr.get("mergeable")
        if ok is False:                                 # GitHub computed a conflict (it says null while it computes)
            return None, ("FAIL", "GitHub reports this PR does not merge with its base (mergeable false)")
        if not SHA_RE.fullmatch(m):
            seen = "no test merge, mergeable %s" % json.dumps(ok)
            continue
        got = merge_parents(a, m)
        if got != [base_sha, a.head]:
            seen = "test merge %s has the parents %s" % (m[:12], ", ".join(x[:12] for x in got) or "none")
            continue
        if ok is True:
            return m, None
        seen = "test merge %s is fresh, mergeable %s" % (m[:12], json.dumps(ok))
    return None, ("??", "GitHub's test merge is still stale after %d read(s) (%s): re-run once GitHub has recomputed it"
                  % (reads, seen))


def merge_parents(a, m):
    """The parents of the commit `m` (GitHub's test merge), in order, lower case."""
    return [((x or {}).get("sha") or "").lower() for x in (B.api("repos/%s/git/commits/%s" % (a.repo, m)) or {}).get("parents") or []]


def suites_apart(a, base_sha, cmp_, planner, base_side, paths, notes, cfg=None):
    """(c) of --behind auto: (verdict ok|FAIL|??, detail). With a planner, the suites the base's files wake (`--suites --woken`:
    no @always set but what a path wakes; with the merge base's inputs as --old when the base changed one, so a changed map
    line wakes its suite) and the suites CI plans for the PR's files (`--suites`: the @always set included; a PR that changes
    the map is @full, since its map is never read) must not meet. Without a planner, every base file must be docs."""
    if not planner:
        code = [f for f in base_side if not doc_path(f, cfg)]
        if code:
            return "FAIL", "no planner (merge.planner): base file(s) that are not docs may change what this PR's tests see: %s" \
                % ", ".join(code[:8])
        return "ok", "no planner (merge.planner): every base file is docs (%d)" % len(base_side)
    if not base_side:
        return "ok", "the base changed no file"
    try:
        texts = planner_files(a, base_sha, [planner["script"]] + planner["inputs"], "the base")
        old = None
        if any(p in base_side for p in planner["inputs"]):
            mb = ((cmp_.get("merge_base_commit") or {}).get("sha") or "").lower()
            if not SHA_RE.fullmatch(mb):
                raise G.Infra("the comparison names no merge base, so the planner inputs from before the change cannot be read")
            old = planner_files(a, mb, planner["inputs"], "the merge base %s" % mb[:12], absent_ok=True)
        sides = run_planner(texts, planner["script"], [(base_side, ["--woken"]), (paths, [])], old)
    except G.Infra as e:
        return "??", "the planner %s cannot answer: %s" % (planner["script"], e)
    a.auto_suites = dict((k, sorted(v) if v is not None else "full") for k, (v, _w) in zip(("base", "pr"), sides))
    (bs, bwhy), (ps, pwhy) = sides
    notes.append("(c) the base's files wake: %s" % (" ".join(sorted(bs)) or "no suite" if bs is not None else "every suite (%s)" % bwhy))
    notes.append("(c) this PR's files wake: %s" % (" ".join(sorted(ps)) or "no suite" if ps is not None else "every suite (%s)" % pwhy))
    if bs is None and ps is None:
        return "FAIL", "the base's files and this PR's files both need every suite (%s; %s)" % (bwhy, pwhy)
    if bs is None:
        meet = sorted(ps)
        why = "the base's files need every suite (%s), and this PR's files wake %s" % (bwhy, " ".join(meet))
    elif ps is None:                                    # its map or an unmapped file: the base map's exclusions may not hold
        meet = sorted(bs) or base_side
        why = "this PR's files need every suite (%s), and the base's files %s" % (
            pwhy, "wake " + " ".join(meet) if bs else "are " + ", ".join(base_side[:8]) + " (any file may be one its own map reads)")
    else:
        meet = sorted(bs & ps)
        why = "the base's files and this PR's files wake the same suite(s): %s" % " ".join(meet)
    if meet:
        return "FAIL", why
    return "ok", "the base's files and this PR's files wake no suite in common (planner %s, read at the base)" % planner["script"]


def planner_files(a, sha, rels, where, absent_ok=False):
    """{repo path: text} of the planner's files at the commit `sha` (the base tip, or the merge base for --old: both on the base
    branch, never the head), each a regular file there (walked like the guard's own inputs: the contents API serves a
    symlink's target, which a PR could change). absent_ok: a file not there is left out (an input new since the merge base)."""
    rels = sorted(set(rels), key=rels.index)
    modes = base_modes(a, sha, rels)
    bad = [p for p in rels if modes.get(p) not in ("100644", "100755") and not (absent_ok and modes.get(p) is None)]
    if bad:
        raise G.Infra("not regular files at %s: %s" % (where, ", ".join("%s (%s)" % (p, modes.get(p) or "absent") for p in bad)))
    texts = {}
    for rel in rels:
        if modes.get(rel) is None:
            continue
        t = raw_at(a, rel, sha)
        if t is None:
            raise G.Infra("%s is not at %s" % (rel, where))
        texts[rel] = t
    return texts


def run_planner(texts, script, queries, old=None):
    """[(suites, None), or (None, why) when the paths need every suite]: the planner's `--suites` answer for each (paths, extra
    arguments) in `queries`, the first with `--old <dir>` when `old` holds the inputs from before the change. It runs in a fresh directory
    holding only `texts` at their repo paths (and `old` beside it), through NO_NET, with an environment of an empty PATH, HOME
    that directory and LC_ALL=C (no token, no proxy, no git variable), Python in isolated mode, and a timeout per run."""
    with tempfile.TemporaryDirectory(prefix="merge-planner-") as d:
        for top, files in (("repo", texts), ("old", old or {})):
            for rel, text in files.items():
                dst = os.path.join(d, top, *rel.split("/"))
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                with open(dst, "w", encoding="utf-8", errors="surrogateescape") as f:
                    f.write(text)
        root = os.path.join(d, "repo")
        env = {"PATH": "", "HOME": root, "LC_ALL": "C"}
        out = []
        for i, (paths, extra) in enumerate(queries):
            stdin = b"".join(p.encode("utf-8", "surrogateescape") + b"\0" for p in paths)
            argv = [sys.executable, "-I", "-B", "-c", NO_NET, os.path.join(root, *script.split("/")), "--suites"]
            try:
                p = subprocess.run(argv + extra + (["--old", os.path.join(d, "old")] if i == 0 and old is not None else []), cwd=root,
                                   env=env, input=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=PLANNER_TIMEOUT_S)
            except (OSError, subprocess.TimeoutExpired) as e:
                raise G.Infra("it did not run: %s" % e)
            out.append(planner_answer(p))
    return out


def planner_answer(p):
    """(suites, None) or (None, why) from one finished planner run; Infra when it failed or printed something else."""
    err = p.stderr.decode("utf-8", "replace").strip()
    if p.returncode != 0:
        raise G.Infra("it exits %d: %s" % (p.returncode, err[-200:] or "no message"))
    lines = [ln for ln in p.stdout.decode("utf-8", "replace").split("\n") if ln]
    if lines and lines[0].startswith("@full"):
        if len(lines) != 1:
            raise G.Infra("it printed @full and more lines")
        return None, lines[0][len("@full"):].strip() or "@full"
    bad = [ln for ln in lines if not SUITE_RE.fullmatch(ln)]
    if bad:
        raise G.Infra("it printed a line that is not a suite name: %r" % bad[0][:80])
    return set(lines), None


def raw_at(a, rel, ref):
    return B.api_raw("repos/%s/contents/%s?ref=%s" % (a.repo, urllib.parse.quote(rel, safe="/"), ref))


def merge_file(ours, base, theirs):
    """(rc, merged bytes) of `git merge-file -p <ours> <base> <theirs>` on three texts, outside any repository, with git's system
    and global config off: rc 0 clean, 1-127 the number of conflicts. No git, or git failing, is Infra."""
    git = shutil.which("git")
    if not git:
        raise G.Infra("no git on PATH for git merge-file")
    env = dict((k, v) for k, v in os.environ.items() if not k.startswith("GIT_"))
    with tempfile.TemporaryDirectory() as d:
        # no system or global config, and no repository found above the temp dir: nothing can set a merge option
        env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_CEILING_DIRECTORIES=os.path.dirname(d), LC_ALL="C")
        for name, text in (("ours", ours), ("base", base), ("theirs", theirs)):
            with open(os.path.join(d, name), "wb") as f:
                f.write(text.encode("utf-8", "surrogateescape"))
        try:
            p = subprocess.run([git, "merge-file", "-p", "ours", "base", "theirs"], cwd=d, env=env, stdin=subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        except (OSError, subprocess.TimeoutExpired) as e:
            raise G.Infra("git merge-file did not run: %s" % e)
    if not 0 <= p.returncode <= 127:
        raise G.Infra("git merge-file failed (rc %d): %s" % (p.returncode, p.stderr.decode("utf-8", "replace").strip()[:120]))
    return p.returncode, p.stdout


def test_merge(a, base_sha):
    """The SHA of GitHub's test merge of this PR when its parents are exactly [base tip, head], else Infra (stale, or none)."""
    m = (B.api("repos/%s/pulls/%s" % (a.repo, a.pr)) or {}).get("merge_commit_sha") or ""
    if not SHA_RE.fullmatch(m):
        raise G.Infra("GitHub has no test merge of this PR (merge_commit_sha %r)" % (m or None))
    parents = merge_parents(a, m)
    if parents != [base_sha, a.head]:
        raise G.Infra("GitHub's test merge %s has the parents %s, not the base tip and the head: it is stale, re-run once GitHub "
                      "has recomputed it" % (m[:12], ", ".join(str(x)[:12] for x in parents) or "none"))
    return m


def clean_shared(a, base_sha, cmp_, files, overlap, cfg, may=None, tm=None, no_tm=None):
    """([(path, detail)] accepted, [path (why)] refused, [why] could not tell) for the files both the base and the PR changed.
    Two independent merges must agree: git's own (`git merge-file` exits 0 on the three texts) and GitHub's test merge (the
    same bytes at a test merge whose parents are the base tip and the head), so a rename GitHub pairs differently, a merge
    attribute or another diff algorithm shows as a disagreement. A file added, removed or renamed on either side is refused
    outright: a 3-way merge of one path means nothing there. --behind auto passes `may` (the clean classes, instead of the
    --behind-ok-clean globs) and `tm` (the fresh test merge it already read; `no_tm`, the reason there is none, makes a file
    that passes the other checks `??` instead: the second opinion is missing)."""
    accepted, refused, unknown = [], [], []
    cand = [p for p in overlap if any(C.glob_match(g, p) for g in a.clean_globs)]
    if may is not None:
        cand = [p for p in overlap if may(p)]
    refused += [p for p in overlap if p not in cand]
    pr_by = dict((f.get("filename"), f) for f in files or [])
    pr_prev = set(f.get("previous_filename") for f in files or [] if f.get("previous_filename"))
    bfiles = cmp_.get("files") or []
    base_by = dict((f.get("filename"), f) for f in bfiles)
    base_prev = set(f.get("previous_filename") for f in bfiles if f.get("previous_filename"))
    todo = []
    for p in cand:
        side = [("the PR", pr_by, pr_prev), ("the base", base_by, base_prev)]
        bad = [(who, "a rename's source" if p in prev else (by.get(p) or {}).get("status") or "absent")
               for who, by, prev in side if p in prev or (by.get(p) or {}).get("status") != "modified"]
        if bad:
            refused.append("%s (%s; only a file both sides modify in place is merged)" % (
                p, ", ".join("%s in %s" % (st, who) for who, st in bad)))
        else:
            todo.append(p)
    if not todo:
        return accepted, refused, unknown
    if no_tm:
        return accepted, refused, unknown + ["%s: %s" % (p, no_tm) for p in todo]
    mb = ((cmp_.get("merge_base_commit") or {}).get("sha") or "").lower()
    if not SHA_RE.fullmatch(mb):
        return accepted, refused, unknown + ["the comparison names no merge base"]
    try:
        modes = base_modes(a, base_sha, todo)
        tm = tm or test_merge(a, base_sha)
    except G.Infra as e:
        return accepted, refused, unknown + [str(e)]
    led = cfg["current_state"]["path"]
    for p in todo:
        if modes.get(p) not in ("100644", "100755"):
            refused.append("%s (not a regular file at the base: mode %s)" % (p, modes.get(p)))
            continue
        try:
            texts = [raw_at(a, p, ref) for ref in (base_sha, mb, a.head, tm)]
        except G.Infra as e:
            unknown.append("%s: %s" % (p, e))
            continue
        if any(t is None for t in texts):
            unknown.append("%s: not found at one of base tip, merge base, head, test merge" % p)
            continue
        if any("\x00" in t or "\ufffd" in t for t in texts):
            refused.append("%s (not UTF-8 text)" % p)
            continue
        try:
            rc, merged = merge_file(texts[0], texts[1], texts[2])
        except G.Infra as e:
            unknown.append("%s: %s" % (p, e))
            continue
        if rc:
            refused.append("%s (git merge-file: %d conflict(s))" % (p, rc))
            continue
        if merged != texts[3].encode("utf-8", "surrogateescape"):
            refused.append("%s (GitHub's test merge %s holds other bytes than git merge-file)" % (p, tm[:12]))
            continue
        detail = "git merge-file clean, the same bytes as GitHub's test merge %s" % tm[:12]
        if p == led:
            prof = CS.profile_from_config(cfg)
            probs = CS.problems(merged, prof)
            if probs:
                refused.append("%s (the merged text fails the current-state check: %s)" % (
                    p, "; ".join(("line %d: %s" % (n, w)) if n else w for n, w in probs[:3])))
                continue
            detail += "; the merged current-state passes its check, %d of %d bytes" % (len(merged), prof["limits"]["bytes"])
        accepted.append((p, detail))
    return accepted, refused, unknown


# ── the image ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────
def diff_blocks(patch):
    """([(removed lines, added lines)], problem): the change blocks of a unified diff; problem names a block that adds or removes
    lines instead of replacing them one for one."""
    blocks, minus, plus = [], [], []

    def flush():
        if minus or plus:
            blocks.append((list(minus), list(plus)))
            del minus[:]
            del plus[:]
    for ln in patch.split("\n"):
        if ln.startswith("\\"):                          # "\ No newline at end of file": about the line before it, not a line
            continue
        if ln.startswith("-"):
            if plus:
                flush()
            minus.append(ln[1:])
        elif ln.startswith("+"):
            plus.append(ln[1:])
        else:                                           # a context line or a hunk header
            flush()
    flush()
    uneven = [b for b in blocks if len(b[0]) != len(b[1])]
    return blocks, ("a block removes %d line(s) and adds %d" % (len(uneven[0][0]), len(uneven[0][1])) if uneven else None)


def lane(a, mcfg, files, paths, V):
    """The image-bump lane's conditions; the new tag when it is one, else None."""
    ib, deny = mcfg["image_bump"], mcfg["deny_globs"]
    tag_files, rev = set(ib["tag_files"]), ib["revision"]
    rev_file = rev["file"] if rev else None
    tree = ib["tree"].rstrip("/") + "/" if ib["tree"] else None

    def in_tree(p):
        return tree is not None and p.startswith(tree)
    outside = [p for p in paths if p not in tag_files and p != rev_file and not in_tree(p)]
    V.cond("lane-files", not outside, "every changed path is a tag file, the revision file or under %s%s"
           % (tree or "(no tree)", ("; not: " + ", ".join(outside[:8])) if outside else ""))
    hits = []
    for p in paths:
        if p in tag_files or p == rev_file or not in_tree(p):
            continue
        neutral = tree + "/".join("-" for _seg in p[len(tree):].split("/"))
        hits += ["%s (%s)" % (p, g) for g in deny if match_fold(g, p) and not match_fold(g, neutral)]
    V.cond("lane-deny", not hits, "a file under the tree still meets every deny glob but the tree's own%s"
           % ("; denied: " + ", ".join(hits[:8]) if hits else ""))
    reg = ib["registry"]
    ref = "%s/%s:" % (reg["host"], reg["image"])
    ref_re = re.compile(re.escape(ref) + r"([A-Za-z0-9_][A-Za-z0-9_.-]{0,127})")
    by_path = dict((f.get("filename"), f) for f in files)
    sources = set(f.get("previous_filename") for f in files if f.get("previous_filename"))
    changed_tags = [p for p in sorted(tag_files) if p in by_path]
    olds, pairs, problems = set(), [], []
    for p in sorted(tag_files):
        if p in sources or (p in by_path and by_path[p].get("status") in ("removed", "renamed")):
            problems.append("%s: a tag file is renamed or removed, so its content cannot be proved" % p)
    for p in changed_tags:
        if by_path[p].get("status") in ("removed", "renamed"):
            continue
        patch = by_path[p].get("patch")
        if patch is None:
            problems.append("%s: no patch (too large or binary), so a tag-only change cannot be proved" % p)
            continue
        blocks, uneven = diff_blocks(patch)
        if uneven:
            problems.append("%s: %s" % (p, uneven))
            continue
        for minus, plus in blocks:
            for m in minus:
                olds.update(ref_re.findall(m))
            pairs += [(p, x, y) for x, y in zip(minus, plus)]
    news = set()
    for p, x, y in pairs:
        o = next((t for t in sorted(olds, key=len, reverse=True) if t in x), None)
        if not o:
            problems.append("%s: a changed line holds no old image tag: %s" % (p, x.strip()[:80]))
            continue
        i = x.index(o)
        pre, post = x[:i], x[i + len(o):]
        new = y[len(pre):len(y) - len(post)] if y.startswith(pre) and y.endswith(post) and len(y) >= len(pre) + len(post) else None
        if new is None or new == o or not TAG_RE.fullmatch(new) or y != x.replace(o, new):
            problems.append("%s: a changed line changes more than the image tag: %s" % (p, y.strip()[:80]))
            continue
        kv = KEY_LINE.fullmatch(x)
        anchored = x.count(o) == x.count(ref + o) or bool(kv and kv.group(3) == o)
        if not anchored:
            problems.append("%s: the old tag also stands outside a %s reference or a `key: <tag>` value: %s" % (p, ref, x.strip()[:80]))
            continue
        news.add(new)
    V.cond("lane-tag-only", not problems, "%d changed tag file(s), %d changed line(s)%s"
           % (len(changed_tags), len(pairs), ("; " + "; ".join(problems[:4])) if problems else ", each only the image tag"))
    V.cond("lane-one-tag", len(news) == 1, "new tag(s) %s across %d changed tag file(s) (exactly one is required)"
           % (sorted(news), len(changed_tags)))
    tag = next(iter(news)) if len(news) == 1 else None
    if not rev:
        V.na("lane-revision", "merge.image_bump.revision is not set")
        return tag
    rx, problems = re.compile(rev["pattern"]), []
    if rev_file in sources or (rev_file in by_path and by_path[rev_file].get("status") in ("removed", "renamed")):
        problems.append("%s is renamed or removed" % rev_file)
    elif rev_file in by_path:
        patch = by_path[rev_file].get("patch")
        blocks, uneven = diff_blocks(patch) if patch is not None else ([], "no patch")
        if uneven:
            problems.append("%s: %s" % (rev_file, uneven))
        for minus, plus in blocks:
            for x, y in zip(minus, plus):
                mx, my = rx.search(x), rx.search(y)
                if not (mx and my and x[:mx.start(1)] == y[:my.start(1)] and x[mx.end(1):] == y[my.end(1):]):
                    problems.append("a line of %s changes more than the revision: %s" % (rev_file, y.strip()[:80]))
    try:
        text = B.api_raw("repos/%s/contents/%s?ref=%s" % (a.repo, urllib.parse.quote(rev_file, safe="/"), a.head))
    except G.Infra as e:
        V.unknown("lane-revision", "%s cannot be read at the head: %s" % (rev_file, e))
        return tag
    m = rx.search(text or "")
    value = m.group(1) if m else None
    if value is None:
        problems.append("the revision pattern finds nothing in %s at the head" % rev_file)
    elif tag and not (tag == value or tag.endswith("-" + value)):
        problems.append("the tag %s does not end with the revision %s" % (tag, value))
    V.cond("lane-revision", not problems, "revision %s at the head%s" % (value, ("; " + "; ".join(problems[:4])) if problems else ""))
    return tag


def image_ref(a, reg):
    """(image, tag) of --require-image: a tag, or a full reference that must name the configured registry and image."""
    v = a.require_image.strip()
    if TAG_RE.fullmatch(v):
        return reg["image"], v
    want = "%s/%s:" % (reg["host"], reg["image"])
    if v.startswith(want) and TAG_RE.fullmatch(v[len(want):]):
        return reg["image"], v[len(want):]
    raise Usage("--require-image %r names another image than the configured %s<tag> (merge.image_bump.registry)" % (v, want))


def image(a, reg, registry, tags, V):
    if not tags:
        V.na("image", "no --require-image, and no single new tag in the lane")
        return
    missing, img = [], reg["image"]
    try:
        for tag in sorted(set(tags)):
            exists = registry.tag_exists(img, tag)
            if not exists:
                missing.append(tag)
    except G.Infra as e:
        V.unknown("image", "the registry cannot be read: %s" % e)
        return
    refs = ["%s/%s:%s" % (reg["host"], img, t) for t in sorted(set(tags))]
    V.cond("image", not missing, "%s %s" % (", ".join(refs), "not in the registry" if missing else "in the registry"))


# ── one run ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
class Verdicts(object):
    def __init__(self):
        self.items = []

    def _add(self, name, verdict, detail, notes=()):
        self.items.append((name, verdict))
        say("  %-4s  %s: %s" % (verdict, name, detail))
        for n in notes:
            say("        %s" % n)

    def cond(self, name, good, detail, notes=()):
        self._add(name, "ok" if good else "FAIL", detail, notes)

    def na(self, name, detail):
        self._add(name, "n/a", detail)

    def unknown(self, name, detail, notes=()):
        self._add(name, "??", detail, notes)

    def failed(self):
        return [n for n, v in self.items if v == "FAIL"]

    def unknowns(self):
        return [n for n, v in self.items if v == "??"]


def base_and_text(a):
    """(branch, its tip SHA, the config file's text there or None when there is none): the branch the guard merges into is
    --base, else the repository's default branch, never the branch the PR names."""
    base = a.base or (B.api("repos/%s" % a.repo) or {}).get("default_branch") or ""
    if not branch_ok(base):
        raise G.Infra("the repository's default branch cannot be read")
    ref = B.api("repos/%s/git/ref/heads/%s" % (a.repo, urllib.parse.quote(base, safe="/")))
    base_sha = ((ref or {}).get("object") or {}).get("sha") or ""
    if not SHA_RE.fullmatch(base_sha):
        raise G.Infra("the branch %s has no commit SHA" % base)
    return base, base_sha, B.api_raw("repos/%s/contents/%s?ref=%s" % (a.repo, C.CONFIG_REL, base_sha))


def base_and_config(a):
    """(branch, its tip SHA, the effective config there), read at that tip by the gates' loader."""
    base, base_sha, text = base_and_text(a)
    return base, base_sha, G.load_config_text(text, " (read at %s %s)" % (base, base_sha[:12]))


def bootstrap_scaffold(cfg, files):
    """The files a bootstrap PR adds that deny lets through: the config itself, and Markdown files under a rules directory of
    that config inside `.vibemaestro/` (the init-kb scaffold). Never code: `.vibemaestro/gates/` is what CI runs."""
    dirs = [d.rstrip("/") + "/" for d in (cfg["rules"]["dirs"] or []) if d.startswith(".vibemaestro/")]
    out = set()
    for f in files:
        p = f.get("filename") or ""
        if f.get("status") != "added":
            continue
        if p == C.CONFIG_REL or (p.endswith(".md") and any(p.startswith(d) and "/" not in p[len(d):] for d in dirs)):
            out.add(p)
    return out


def bootstrap_config(a, base):
    """(config, text) read at the PR's head when the base has no config file and this PR adds it (status added, no rename), else
    None. The config must set merge.deny_globs and name no `external:` adapter: a first PR may bring its rules, never the code
    that judges it."""
    files = pr_files(a)
    if not any(f.get("filename") == C.CONFIG_REL and f.get("status") == "added" for f in files) or \
            any(f.get("previous_filename") == C.CONFIG_REL for f in files):
        return None
    text = B.api_raw("repos/%s/contents/%s?ref=%s" % (a.repo, C.CONFIG_REL, a.head))
    if text is None:
        return None
    where = " (bootstrap: read at the head %s, %s has none)" % (a.head[:12], base)
    cfg = G.load_config_text(text, where)
    if cfg["merge"]["deny_globs"] is None:
        raise G.ConfigError("merge.deny_globs is not set in the config this PR adds%s: a first PR must say which paths the guard "
                            "refuses (an empty list is a valid answer)" % where)
    ext = sorted(guard_inputs(cfg) - {C.CONFIG_REL})
    if ext:
        raise G.ConfigError("the config this PR adds names an external adapter (%s)%s: a first PR cannot bring the code that "
                            "judges it; merge it by hand" % (", ".join(ext), where))
    return cfg, text


def log_path(cfg):
    rel = ((cfg or {}).get("merge") or {}).get("log") or LOG_NAME
    return os.path.join(state_home(), "vibemaestro", rel)


class Run(object):
    def __init__(self, a):
        self.a, self.cfg, self.base, self.base_sha, self.V = a, None, None, None, Verdicts()
        self.digest, self.merge_sha, self.fd = None, None, None
        self.boot, self.clean = None, []                  # bootstrap: sha256 of the head's config; the shared files merged clean
        self.merge_commit = False                         # the back-merge lane: a merge commit instead of a squash

    def log_cfg(self):
        return None if self.boot else self.cfg          # bootstrap: the default log, the one --status reads while the base has no config

    def open_log(self):
        """Open the merge log before anything that cannot be undone, so the run that merges can always write its line."""
        p = log_path(self.log_cfg())
        os.makedirs(os.path.dirname(p), mode=0o700, exist_ok=True)
        self.fd = os.open(p, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)

    def log(self, result):
        a = self.a
        line = json.dumps({
            "time": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "repo": a.repo, "pr": int(a.pr), "head": a.head,
            "base": self.base, "base_sha": self.base_sha, "lane": "image-bump" if a.image_bump else "normal", "admin": a.admin,
            "accept": sorted(a.accept), "require_image": a.require_image, "behind_ok": a.behind_globs,
            "behind_ok_clean": getattr(a, "clean_globs", []), "clean": self.clean, "bootstrap": self.boot,
            "behind_auto": getattr(a, "auto", False), "suites": getattr(a, "auto_suites", None),
            "mode": "merge" if a.merge else "dry-run", "caller": os.environ.get("BATON_PHASE") or None,
            "conditions": dict((n, v) for n, v in self.V.items), "result": result, "merge_sha": self.merge_sha,
            "guard": self.digest}, sort_keys=True) + "\n"
        try:
            if self.fd is None:
                self.open_log()
            os.write(self.fd, line.encode("utf-8"))
        except OSError as e:
            say("merge_guard: the merge log %s cannot be written: %s" % (log_path(self.log_cfg()), e.strerror or e), sys.stderr)
            return False
        finally:
            if self.fd is not None:
                os.close(self.fd)
                self.fd = None
        return True

    def go(self):
        try:
            return self.evaluate()
        except Usage as e:
            say("merge_guard: %s" % e, sys.stderr)
            self.log("usage")
            return USAGE
        except G.ConfigError as e:
            say("merge_guard: invalid config: %s" % e, sys.stderr)
            self.log("config")
            return CONFIG
        except G.Infra as e:
            say("merge_guard: could not conclude: %s" % e, sys.stderr)
            self.log("error")
            return INFRA
        except (Exception, SystemExit) as e:    # a fault of the guard, or an adapter that exits, is "could not conclude", never green
            say("merge_guard: could not conclude: internal error (%s)" % type(e).__name__, sys.stderr)
            self.log("error")
            return INFRA

    def evaluate(self):
        a = self.a
        pr = pr_view(a, PR_FIELDS)
        self.base, base_sha, text = base_and_text(a)
        self.base_sha = base_sha
        boot = bootstrap_config(a, self.base) if text is None else None
        if boot:
            self.cfg, self.boot = boot[0], sha256(boot[1])
            if a.admin:
                raise Usage("--admin is refused in bootstrap: the config that would allow it is the PR's own")
            if a.image_bump:
                raise Usage("--image-bump is refused in bootstrap: the lane's rules would be the PR's own")
            if a.require_image is not None:
                raise Usage("--require-image is refused in bootstrap: the registry it is checked against would be the PR's own")
        else:
            self.cfg = G.load_config_text(text, " (read at %s %s)" % (self.base, base_sha[:12]))
        mcfg = self.cfg["merge"]
        if mcfg["deny_globs"] is None:
            raise G.ConfigError("merge.deny_globs is not set at %s %s: the guard refuses to run until the repo lists the paths "
                                "it refuses (an empty list is a valid answer)" % (self.base, base_sha[:12]))
        if a.admin and not mcfg["admin_bypass"]:
            raise Usage("--admin needs merge.admin_bypass true in the base config (it is false)")
        ib, reg = mcfg["image_bump"], mcfg["image_bump"]["registry"]
        if a.image_bump and not ib["enabled"]:
            raise Usage("--image-bump needs merge.image_bump.enabled true in the base config")
        req = None
        if a.require_image is not None:
            if reg is None:
                raise Usage("--require-image needs merge.image_bump.registry in the base config")
            req = image_ref(a, reg)

        def fetch(rel):
            return B.api_raw("repos/%s/contents/%s?ref=%s" % (a.repo, urllib.parse.quote(rel, safe="/"), base_sha))
        ci = B.load("ci", self.cfg["ci"]["backend"], fetch)
        used = [ci]
        registry = None
        if req or a.image_bump:
            registry = B.load("registry", reg["backend"], fetch)
            used.append(registry)
        self.digest = code_digest(used)
        say("merge_guard: %s#%s into %s (%s, %s), head %s, lane %s"
            % (a.repo, a.pr, self.base, base_sha[:12], "bootstrap: it has no %s, so the one this PR adds is read at the head"
               % C.CONFIG_REL if self.boot else "its config read there", a.head, "image-bump" if a.image_bump else "normal"))
        V = self.V
        cond = V.cond
        cond("open", pr.get("state") == "OPEN", "state %s" % pr.get("state"))
        cond("not-draft", pr.get("isDraft") is False, "isDraft %s" % pr.get("isDraft"))
        cond("head", pr.get("headRefOid") == a.head, "headRefOid %s, reported %s" % (pr.get("headRefOid") or "?", a.head))
        base = self.base
        cond("base", pr.get("baseRefName") == base,
             "the PR targets %s; the guard merges into %s (%s)" % (pr.get("baseRefName"), base,
                                                                  "--base" if a.base else "the repository's default branch"))
        if not mergeable(a, pr, V):
            say("REFUSED early: mergeable: GitHub reports CONFLICTING; checks, files and behind were not read: merge the base into "
                "the branch and resolve; nothing merged")
            self.log("refused")
            return RED
        self.merge_commit = backmerge(a, pr, base, V)
        checks(a, mcfg, ci, V)
        files, paths = changed(a, pr, V)
        lane_tag = None
        if paths is None:
            for n in ("lane-files" if a.image_bump else "deny", "brief", "links", "own-inputs"):
                V.unknown(n, "the changed files are not known")
        else:
            if a.image_bump:
                lane_tag = lane(a, mcfg, files, paths, V)
            else:
                deny = mcfg["deny_globs"]
                scaffold = set()
                if self.boot:                           # the PR's own list cannot be emptied below the init default
                    deny = list(deny) + [g for g in C.merge_deny_floor(self.cfg["rules"]["dirs"]) if g not in deny]
                    scaffold = bootstrap_scaffold(self.cfg, files)
                hit = [p for p in paths if p not in scaffold and any(match_fold(g, p) for g in deny)]
                cond("deny", not hit, "%d deny glob(s)%s%s" % (len(deny), ("; denied: " + ", ".join(hit[:8])) if hit else ", none matches",
                     "; bootstrap: the init default is added, and the %d file(s) this PR adds as its config and its rules' "
                     "Markdown are its scaffold" % len(scaffold) if self.boot else ""))
            allowed = a.allowed
            outside = [p for p in paths if not any(C.glob_match(g, p) for g in allowed)]
            cond("brief", not outside, "%d allowed glob(s)%s" % (len(allowed), ("; outside: " + ", ".join(outside[:8])) if outside else ", every path inside"))
            links(a, files, V)
            if self.boot:
                cond("own-inputs", True, "bootstrap: the base has no config; the one this PR adds names no adapter")
            else:
                try:
                    modes = base_modes(a, base_sha, sorted(guard_inputs(self.cfg)))
                except G.Infra as e:
                    V.unknown("own-inputs", "the guard's inputs cannot be read at the base: %s" % e)
                else:
                    own_inputs(self.cfg, paths, modes, V)
        a.boot = bool(self.boot)                        # --behind auto: in bootstrap the config, and so merge.planner, is the PR's
        ahead, self.clean = behind(a, base_sha, files, paths, self.cfg, V)
        tags = ([req[1]] if req else []) + ([lane_tag] if lane_tag else [])
        if reg is not None:
            image(a, reg, registry, tags, V)
        else:
            V.na("image", "no registry configured")
        return self.conclude(ahead, tags, reg)

    def conclude(self, ahead, tags, reg):
        a, V = self.a, self.V
        failed, unknown = V.failed(), V.unknowns()
        if failed:
            say("REFUSED: %s: nothing merged" % ", ".join(failed))
            self.log("refused")
            return RED
        if unknown:
            say("COULD NOT CONCLUDE: %s: nothing merged" % ", ".join(unknown))
            self.log("error")
            return INFRA
        refs = ",".join("%s/%s:%s" % (reg["host"], reg["image"], t) for t in sorted(set(tags))) if tags else "none"
        plan = ("merge %s#%s head %s into %s@%s %s lane %s admin %s accept %d image %s behind %d%s brief %s guard %s"
                % (a.repo, a.pr, a.head, self.base, self.base_sha[:12], "merge-commit" if self.merge_commit else "squash",
                   "image-bump" if a.image_bump else "normal",
                   "yes" if a.admin else "no", len(a.accept), refs, ahead, " auto" if a.auto else "", sha256("\n".join(a.allowed))[:12],
                   self.digest[:12])
                + (" clean %d" % len(self.clean) if self.clean else "") + (" bootstrap %s" % self.boot[:12] if self.boot else ""))
        say("merge-plan: " + plan)
        expected = a.expected
        if a.expect_plan is not None and expected != [plan]:
            V.cond("signed-plan", False, "the plan now is the line above; the signed one: %s" % (" | ".join(expected) or "(empty)"))
            say("REFUSED: signed-plan: the world moved since signing; nothing merged")
            self.log("refused")
            return RED
        try:
            self.open_log()
        except OSError as e:
            say("merge_guard: the merge log %s cannot be written (%s): nothing merged" % (log_path(self.log_cfg()), e.strerror or e), sys.stderr)
            return INFRA
        if not a.merge:
            say("DRY RUN: every condition holds; nothing merged (--merge, or the run of the kit baton kit:merge-pr, merges)")
            return OK if self.log("pass") else INFRA
        now = pr_view(a, "baseRefName")                 # gh pins the head, not the base: narrow the retarget window
        if now.get("baseRefName") != self.base:
            V.cond("base", False, "the PR was retargeted to %s after the check; the guard merges into %s" % (now.get("baseRefName"), self.base))
            say("REFUSED: base: nothing merged")
            self.log("refused")
            return RED
        args = ["pr", "merge", a.pr, "--repo", a.repo, "--merge" if self.merge_commit else "--squash", "--match-head-commit", a.head]
        if a.admin:
            args.append("--admin")
        try:
            rc, out, err = B.gh(args)
        except G.Infra as e:
            say("gh pr merge did not answer (%s): the request may have reached GitHub and the merge may still land; tell the owner" % e)
            self.log("merge-pending")
            return INFRA
        if rc != 0:
            say("gh pr merge refused (rc %d): %s" % (rc, (err or out).strip()[:300]))
            self.log("merge-failed")
            return INFRA
        try:
            st = pr_view(a, "state,mergeCommit,headRefOid")
        except G.Infra as e:
            say("gh pr merge exited 0, but the PR cannot be read back (%s): it is probably merged; check it now" % e)
            self.log("merged-unconfirmed")
            return INFRA
        self.merge_sha = (st.get("mergeCommit") or {}).get("oid")
        if st.get("state") != "MERGED":
            say("gh pr merge exited 0 but the PR reads %s: the merge is pending (a merge queue or auto-merge) and may still "
                "happen; tell the owner" % st.get("state"))
            self.log("merge-pending")
            return INFRA
        say("MERGED %s#%s head %s as %s" % (a.repo, a.pr, a.head, self.merge_sha))
        return OK if self.log("merged") else INFRA


def backmerge(a, pr, base, V):
    """The back-merge lane: True when this PR merges with a merge commit (the condition `backmerge` in the docstring)."""
    named = (pr.get("headRefName") or "").startswith(BACKMERGE_PREFIX)
    try:
        default = (B.api("repos/%s" % a.repo) or {}).get("default_branch")
    except G.Infra as e:
        V.unknown("backmerge", "the repository's default branch cannot be read: %s" % e)
        return False
    if base != default:
        V.na("backmerge", "the base %s is not the default branch %s: squash" % (base, default))
        return False
    try:
        ref = B.api("repos/%s/git/ref/heads/%s" % (a.repo, RELEASE_BRANCH))
        rel = ((ref or {}).get("object") or {}).get("sha") or ""
    except B.NotFound:
        rel = None
    except G.Infra as e:
        V.unknown("backmerge", "the branch %s cannot be read: %s" % (RELEASE_BRANCH, e))
        return False
    if rel is None:
        if named:
            V.cond("backmerge", False, "the head ref %s is a back-merge, and there is no branch %s to back-merge from (the "
                   "owner-signed follow-up creates it)" % (pr.get("headRefName"), RELEASE_BRANCH))
        else:
            V.na("backmerge", "no branch %s: squash" % RELEASE_BRANCH)
        return False
    if not SHA_RE.fullmatch(rel):
        V.unknown("backmerge", "the branch %s has no commit SHA" % RELEASE_BRANCH)
        return False
    try:
        status = (B.api("repos/%s/compare/%s...%s" % (a.repo, a.head, rel)) or {}).get("status")
    except G.Infra as e:
        V.unknown("backmerge", "the head cannot be compared with %s: %s" % (RELEASE_BRANCH, e))
        return False
    if status not in ("ahead", "identical", "behind", "diverged"):
        V.unknown("backmerge", "the comparison of the head with %s has status %r" % (RELEASE_BRANCH, status))
        return False
    on = status in ("ahead", "identical")
    if named:
        V.cond("backmerge", on, "the head ref %s; the head is %son %s %s: %s" % (
            pr.get("headRefName"), "" if on else "not ", RELEASE_BRANCH, rel[:12],
            "a merge commit keeps %s an ancestor of %s" % (RELEASE_BRANCH, base) if on else "only the release tip is back-merged"))
        return on
    V.cond("backmerge", not on, "the head is %son %s %s%s" % ("" if on else "not ", RELEASE_BRANCH, rel[:12],
           ": a squash of it would cut %s off %s; open it from a %s* branch" % (RELEASE_BRANCH, base, BACKMERGE_PREFIX) if on else ": squash"))
    return False


def mergeable(a, pr, V):
    """False only when GitHub reports CONFLICTING: the caller stops there, before reading CI."""
    m, reads = pr.get("mergeable"), 0
    while m == "UNKNOWN" and reads < MERGEABLE_REREADS:
        time.sleep(MERGEABLE_WAIT_S)
        m, reads = pr_view(a, "mergeable").get("mergeable"), reads + 1
    if m in ("MERGEABLE", "CONFLICTING"):
        V.cond("mergeable", m == "MERGEABLE", "GitHub reports %s" % m)
    else:
        V.unknown("mergeable", "GitHub reports %s after %d re-read(s)" % (m, reads))
    return m != "CONFLICTING"


def code_digest(used):
    """sha256 of the code that decides: this file, the gate helpers, the loader, the backends package, the current-state check
    and each backend used."""
    h = hashlib.sha256()
    for p in (os.path.abspath(__file__), G.__file__, C.__file__, B.__file__, CS.__file__):
        with open(p, "rb") as f:
            h.update(f.read())
    for b in used:
        h.update(b.digest.encode("ascii"))
    return h.hexdigest()


def merge_pending(a):
    """True when the merge log holds a merge run of this repo, PR and head left pending (`merge-pending`, `merged-unconfirmed`)
    that no later `merged` line closed: a refused or failed retry does not clear it. A config or a log that cannot be read raises
    (could not conclude): `--status` never guesses `open`."""
    cfg = base_and_config(a)[2]
    pending = False
    try:
        with open(log_path(cfg), encoding="utf-8", errors="replace") as f:
            for ln in f:
                try:
                    d = json.loads(ln)
                except ValueError:
                    continue
                if not (isinstance(d, dict) and d.get("mode") == "merge" and str(d.get("repo")).lower() == a.repo.lower()
                        and d.get("pr") == int(a.pr) and d.get("head") == a.head):
                    continue
                if d.get("result") in ("merge-pending", "merged-unconfirmed"):
                    pending = True
                elif d.get("result") == "merged":
                    pending = False
    except FileNotFoundError:
        return False
    except OSError as e:
        raise G.Infra("the merge log %s cannot be read: %s" % (log_path(cfg), e.strerror or e))
    return pending


def status(a):
    """One line: `merged <sha>`, `queued` (an auto-merge request), `pending` (open, and a merge run of this head was left pending
    with no later run merging it), else the state; then `head <sha>`. Undo of the kit baton refuses all but open and closed. When
    the base config or the merge log cannot be read, rc 2 (could not conclude) rather than `open`."""
    st = pr_view(a, "state,mergeCommit,headRefOid,autoMergeRequest")
    head = st.get("headRefOid") or "?"
    pending = st.get("state") == "OPEN" and merge_pending(a)
    if st.get("state") == "MERGED":
        say("merged %s head %s" % ((st.get("mergeCommit") or {}).get("oid") or "?", head))
    elif st.get("state") == "OPEN" and st.get("autoMergeRequest"):
        say("queued head %s" % head)
    elif pending:
        say("pending head %s" % head)
    else:
        say("%s head %s" % ((st.get("state") or "?").lower(), head))
    return OK


def main(argv):
    if argv in (["-h"], ["--help"]):
        make_parser().print_help()
        return OK
    try:
        a = parse(argv)
    except Usage as e:
        say("merge_guard: %s" % e, sys.stderr)
        return USAGE
    if a.status:
        try:
            return status(a)
        except (G.Infra, G.ConfigError) as e:
            say("merge_guard: could not conclude: %s" % e, sys.stderr)
            return INFRA
    return Run(a).go()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
