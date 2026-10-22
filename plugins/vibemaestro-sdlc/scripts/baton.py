#!/usr/bin/env python3
"""baton: the BatonRun runner of vibemaestro-sdlc.

A privileged action (a write outside the session: GitHub, a cluster, a registry, the user's Claude Code config, a deletion) is one
baton script, checked, rehearsed, signed, run by the coordinating session itself, post-checked and logged. The script contract
(header, the write() gate, the phases, the verdict lines) is the template templates/baton-script.sh; the design and its limits are in
the reference files of the skill batonrun (`help <topic>`).

  baton.py new <name> [--dir D]                                    write D/<name>.sh from the template (never overwrites)
  baton.py new <name> --from <kind> [--dir D]                      the same from a ready kind: install-file, settings-merge,
                                                                   remote-exec, kubectl-exec (templates/baton-kinds/)
  baton.py check <script>                                          static checks of a baton script
  baton.py rehearse <script> [args...]                             check, then the rehearse phase; the plan against Expect
  baton.py sign --by W --seal S <script> [args...]               check, mode policy, rehearse, seal, then the signature record
  baton.py run <script> [args...]                                  signed run: rehearse again, run, post-check, undo on failure;
                                                                   one line `run: ok — <n> writes — <run log>` when it holds
  baton.py go [--by coordinator-auto] [--reuse] <script> [args...] check, rehearse, seal, sign, run, post-check and log in one
                                                                   command, one line when it all holds; a baton the session
                                                                   may not sign stops after rehearse with the owner's decision
                                                                   card (exit 8)
  baton.py go [--by coordinator-auto] - [args...]                  the same, the script read from stdin and stored under
                                                                   <state>/stdin first; not for a baton: Claude Code blocks a
                                                                   heredoc that holds the skeleton, so Write a file and go it
  baton.py log [--tail N]                                          the last N lines of the log (default 20)
  baton.py log --last                                              the path of the newest run log (set before the script runs: a killed run is found here)
  baton.py log --wait-names N1,N2,... [--timeout S] [--since T]   wait (S 1-580 s, default 580) until the latest run line of
                                                                   each named script written at or after T (default: the wait's
                                                                   start minus 300 s) is ok; prints those lines; a failed line
                                                                   does not end the wait; lines before T are ignored, counted
  baton.py help [<topic>]                                          this text, or one reference file of the batonrun skill:
                                                                   act, kinds, kits, modes, permissions, setup, limits
  baton.py mode [manual|auto]                                      print or set the approval mode
  baton.py permissions --print                                     the user-settings block for this install: the permission rules
                                                                   and attribution off (JSON, applied by the owner)
  baton.py permissions --check [--settings F]...                   the rules in force against --print, attribution as a WARNING;
                                                                   writes nothing
  baton.py permissions --install-launcher                          copy the launcher to <state>/bin/baton, the command the rules name

baton's own options come before the script path; everything after the path is the script's own arguments (`--` ends baton's
options). Every phase runs `bash` on a fresh copy of the script bytes that were hashed, from the caller's directory, with the caller's
environment (without BASH_ENV and the other SHELL_HOOKS) plus BATON_PHASE, in a process group of its own; stdin is closed, so a script never prompts.
The run phase also gets BATON_PLAN, a file holding the signed plan (one line per write), so a script can refuse an act that
cannot be undone when the world moved between the run's own rehearse and that act. The undo after a failed run gets it too,
so a run record can name the run that wrote it (its plan's sha256) and undo acts only on its own run's record.

`go` is the same code as `rehearse`, `sign --by coordinator-auto` and `run` called in turn, so it checks exactly what they
check; it stops at the first step that fails, with that command's exit code, and prints that step's whole output. When every
step holds it prints one line, `go: ok — <n> writes — <run log>`; the run log holds every step's output.
`go` runs a session baton only from a file written in the last FRESH_SECONDS (120 s; read with fstat on the bytes it read):
an older file is rc 1, nothing run, unless `--reuse` says these very bytes are meant again. The same holds for the --spec file
of kit:gh-write. A file written with the Write tool and run by `go` in the same response is seconds old; one the Write did not
replace is as old as its last writer.
`go -` reads the script from stdin instead (at most STDIN_MAX bytes, not a terminal, not empty), writes those bytes once to
<state>/stdin/<stamp>-<sha12>.sh (mode 0400, never overwritten) and runs that file exactly as `go <file>`: the same check, rehearse,
seal, sign, run and post-check, each reading the stored file and bound by its sha256, so a byte changed between two phases is
refused as for any file. The only way a session can feed it is a heredoc on the command, and Claude Code denies a heredoc that holds the
baton skeleton (measured in default mode, skill reference limits.md): a session writes the baton to a fresh path and runs `go <path>`.
`--reuse -` is bad usage: bytes from stdin are fresh by construction. A
file named `-` runs as `go ./-`. The newest STDIN_KEPT stored scripts are kept, and any younger than STDIN_KEEP_DAYS within the
newest STDIN_HARD.
`kind:<name>` runs a ready kind (templates/baton-kinds/<name>.sh, CALLABLE_KINDS) with its arguments, checked as a session
baton; the binding adds the kinds directory, like a kit baton's. A failed post-check is read again after 1, 2, 4
and 8 seconds (BATON_POSTCHECK_WAITS, space-separated seconds, may only shorten that), in `run` and `go` alike.

A signature binds the sha256 of the script bytes, its arguments, the directory it runs from, a fingerprint of the variables
that steer the tools (STEERING) and the plan rehearsed at signing; `sign` must name the seal that rehearse printed, so it signs
what was shown. `run` consumes it, and the run's writes (DO lines) must be the signed plan. Mode `manual` (the default) accepts only `--by owner`; mode `auto` also accepts `--by coordinator-auto`, for a
script whose header says `Stops: none`. This guards an honest but fallible session (an edit after approval, other arguments, a
changed world, a second run); it does not stop a session that sets out to forge a record, which is the job of the owner's permission
rules and read-only tools.

State, outside every repository: $XDG_STATE_HOME/vibemaestro/baton (a relative XDG_STATE_HOME is ignored), else
~/.local/state/vibemaestro/baton: `mode`, `signatures/`, `used/`, `log.tsv`, `runs/` (the newest 200 run outputs are kept; `runs/LAST` names the newest, written before the script runs),
`stdin/` (the scripts `go -` read, the newest 200 kept).

Exit codes:
  0   done
  1   the script fails check, or its rehearse fails (exit not 0, no verdict line, plan differs from Expect)
  2   environment: no bash, or the state directory cannot be written
  3   refused, nothing ran: no signature matches the script, its arguments, its directory, its environment and its plan (for
      sign: the seal shown), the mode does not allow the signer, or it stopped before the run phase (an interrupt or an
      error); the signature stays unused
  4   the run or its post-check failed (an interrupt while waiting to read a failed post-check again counts as that
      failure), and undo put the state back
  5   the state is unknown: the run or its post-check failed and undo failed too, or the run phase or a later one was
      interrupted (SIGINT, SIGTERM or SIGHUP) or hit an error (the phase's process group is stopped, no undo then)
  6   new: the file already exists
  7   permissions --check: a rule is missing, stale or unsafe (each one is printed)
  8   go: the baton needs the owner's signature (a Stops item, or mode manual); nothing was signed, nothing ran
  9   log --wait-names: at the deadline a named script's latest run line since --since is not ok, or it has none (each is named)
  64  bad usage
  66  the script cannot be read

Python 3.8+, standard library only.
"""
import calendar
import fnmatch
import hashlib
import json
import os
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True

OK, BAD_SCRIPT, ENV, REFUSED, UNDONE, UNKNOWN, EXISTS, PERMS, OWNER, USAGE, NOINPUT = 0, 1, 2, 3, 4, 5, 6, 7, 8, 64, 66
WAIT_UNMET = 9

HEADER_FIELDS = ("Purpose", "Targets", "Blast", "Undo", "Pre", "Stops", "Each", "Expect")
STOP_WORDS = ("irreversible-delete", "secrets", "security-boundary", "cluster-lane", "history-rewrite", "money-org", "publish",
              "no-way-back", "owner-acts")
SIGNERS = ("owner", "coordinator-auto")
MODES = ("manual", "auto")
PHASES = ("rehearse", "run", "postcheck", "undo")
RUNS_KEPT = 200
# A failed post-check is read again after these waits (seconds): GitHub answers a read with the old state for a moment after a
# write (a post-check read the old PR head right after a successful update-branch). Only the post-check repeats;
# BATON_POSTCHECK_WAITS may shorten the schedule, never lengthen it (see postcheck_waits).
POSTCHECK_WAITS = (1, 2, 4, 8)
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
PLUGIN_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TEMPLATE = os.path.join(PLUGIN_ROOT, "templates", "baton-script.sh")
LAUNCHER = os.path.join(PLUGIN_ROOT, "scripts", "baton-launcher.py")
# `help <topic>`: the reference files of the batonrun skill, read when a baton needs that topic
HELP_DIR = os.path.join(PLUGIN_ROOT, "skills", "batonrun")
HELP_TOPICS = ("act", "kinds", "kits", "modes", "permissions", "setup", "limits")
# `log --wait-names`: the main session's one wait for the scripts it delegated to a worker; within one Bash call
WAIT_MAX, WAIT_LOOKBACK, WAIT_POLL = 580, 300, 0.5
# `new <name> --from <kind>`: a ready template of a kind the baton log repeats, templates/baton-kinds/<kind>.sh
KINDS_DIR = os.path.join(PLUGIN_ROOT, "templates", "baton-kinds")
KIND_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
# `kind:<name>`: the kinds a session runs with arguments only, no script to write. __NAME__ reads as the kind's name.
CALLABLE_KINDS = ("install-file", "settings-merge", "ci-rerun-failed")
KINDS_REAL = os.path.realpath(KINDS_DIR)
# go and a stale file: a Write and a `go` in one response leave the file seconds old (1.9-3.0 s measured); a Write that
# did not land leaves the older bytes. An older file, or one dated in the future, is refused unless `go --reuse`.
FRESH_SECONDS = 120
FUTURE_SLACK = 5
# go -: the script from stdin, stored once under <state>/stdin and run as a file. A baton is a few KiB; the
# size cap and STDIN_HARD keep a stray pipe or a burst from filling the state directory.
STDIN_MAX = 256 * 1024
STDIN_KEPT = 200
STDIN_KEEP_DAYS = 7                                    # a stored script this young stays: an exit-8 baton's owner commands name it
STDIN_HARD = 1000                                      # beyond the newest this many, every stored script goes, young or not
KIT_INPUTS = {"gh-write": "--spec"}                     # a kit baton whose input is a file the session writes: the same rule
KIND_INPUTS = {"settings-merge": 1}                     # a kind's argument (by position) that names a file the session writes
# Kit batons: `kit:<name>` names the plugin's own batons/<name>.sh. A kit baton is plugin code, the same bytes for every
# install of a version and denied to Edit by the permission snippet, so it alone may run one of the plugin's gates, in exactly the
# form TRUSTED_RUN, and BATON_PLUGIN_ROOT tells it where they are. Its binding also covers the batons directory (a versioned path),
# so a signature does not carry across an upgrade or to another copy of the same bytes.
KIT_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
KIT_ROOT = os.path.realpath(os.path.join(PLUGIN_ROOT, "batons"))
# A dependent plugin's kit: when sdlc ships no batons/<name>.sh, `kit:<name>` is batons/<name>.sh of another plugin of sdlc's
# own marketplace that declares the dependency. The registry is the one beside this copy
# (<plugins>/cache/<marketplace>/vibemaestro-sdlc/<version>), never CLAUDE_CONFIG_DIR or HOME, which a session sets; such a kit
# has the same checks, its binding covers its own batons/ and BATON_PLUGIN_ROOT is its root. A name both ship, or two dependent
# plugins ship, runs nowhere.
SDLC = "vibemaestro-sdlc"
REGISTRY_VERSION = 2
MAX_REGISTRY = 1 << 20
MAX_MANIFEST = 64 << 10
# the version directory of an install, as the launcher accepts sdlc's (baton-launcher.py INSTALL_DIR)
INSTALL_DIR = re.compile(r"^(?:(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9a-f]{12})?|[0-9a-f]{12}(?:-[0-9a-f]{8})?|unknown)\Z")
TRUSTED_GATE = r"gates/[A-Za-z0-9_]+\.py"
TRUSTED_RUN = re.compile(r'python3 -I -B "\$BATON_PLUGIN_ROOT/' + TRUSTED_GATE + r'"(?=[\s;|&)]|$)')
# Plugin scripts in a session baton: `"$BATON_PLUGIN_ROOT/scripts/<file>"` is the one way a session baton names its
# variable, only as the command a write() runs, as `bash` (.sh) or `python3 -I -B` (.py): never in rehearse, never as an
# argument. Every mention of the name in the text (comments and heredocs too) must be such a run. Rehearse wants the sha256 of
# each named file, as a whole word, in a plan line; the binding covers the real plugin root and every file under its scripts/
# (which holds no link), so a script or a sibling it calls that changed since signing, or another copy or version of the
# plugin, has no signature; scripts/ is hashed again when each phase ends. baton itself is not a tool of a baton.
PLUGIN_SCRIPT_RUN = re.compile(r'(?:bash "\$BATON_PLUGIN_ROOT/scripts/([A-Za-z0-9_-]+\.sh)"'
                               r'|python3 -I -B "\$BATON_PLUGIN_ROOT/scripts/([A-Za-z0-9_-]+\.py)")(?=[\s;|&]|$)')
PLUGIN_SCRIPTS_REFUSED = ("baton.py", "baton-launcher.py")
# Variables that make bash run code before the script, dropped from every phase.
SHELL_HOOKS = ("BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS", "CDPATH", "GLOBIGNORE", "PROMPT_COMMAND")
# Variables that point the tools elsewhere (another repository, host, config): their fingerprint is part of the binding, so a
# signature for one target does not run against another. Values are hashed, never stored.
STEERING = ("PATH", "HOME", "XDG_CONFIG_HOME", "GH_REPO", "GH_HOST", "GH_CONFIG_DIR", "GH_TOKEN", "GITHUB_TOKEN",
            "DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_CONFIG", "GIT_DIR", "GIT_WORK_TREE", "GIT_SSH", "GIT_SSH_COMMAND",
            "CLAUDE_CONFIG_DIR")         # plus every GIT_CONFIG_* and PYTHON* variable
LOG_FIELDS = ("time", "event", "name", "script", "binding", "args", "dir", "signed_by", "mode", "result", "undone", "output")

# Commands whose non-zero exit is normal: inside a pipeline under pipefail they stop a `set -e` script silently.
TOLERATED = ("diff", "grep", "egrep", "fgrep", "zgrep", "cmp")
PHASE_LINE = re.compile(r"^\s*PHASE=\$\{BATON_PHASE:-rehearse\}\s*$")
# `Each: <glob>` instead of Expect lines (the coordinator's conditions): for a kit baton whose number of
# writes is its input's (kit:gh-write, one write per op of a spec). Every plan line matches the glob whole and is not empty, and
# the rehearse prints exactly one PLAN-COUNT line, whose number the plan must have.
PLAN_COUNT = re.compile(r"^PLAN-COUNT ([0-9]+)$")

# A heuristic backstop for `Stops:`: a body line that looks like a stop category the header does not declare fails check.
# It catches an honest omission, not a determined disguise; known false positives are asserted in tests/test-baton.sh.
# git with its global options (`git -C dir push`); each option parses one way only, so a long line stays linear
GIT = (r"\bgit(?:\s+(?:-[Cc]\s+\S+|--(?:git-dir|work-tree|namespace)\s+\S+"
       r"|--(?!(?:git-dir|work-tree|namespace)(?:\s|$))[\w-]+(?:=\S+)?))*\s+")
STOP_HINTS = (                                     # (category, the label check names and the skill lists, the pattern)
    ("irreversible-delete", "gh repo|release delete", r"\bgh\s+(?:repo|release)\s+delete\b"),
    ("irreversible-delete", "kubectl … delete ns|pvc|pv",
     r"\bkubectl(?=\s)[^|;&\n]*\sdelete\s+(?:ns|namespaces?|pvc|persistentvolumeclaims?|pv|persistentvolumes?)\b"),
    ("irreversible-delete", "git push --delete|-d|:<ref>", GIT + r"push\b[^|;&\n]*(?:\s--delete\b|\s-d\b|\s:[^\s:]+)"),
    ("irreversible-delete", "gh api -X DELETE", r"\bgh\s+api\b[^|;&\n]*(?:-X\s*|--method[\s=]+)[\"']?(?i:DELETE)\b"),
    ("irreversible-delete", "git push --mirror", GIT + r"push\b[^|;&\n]*\s--mirror\b"),
    ("secrets", "gh secret", r"\bgh\s+secret\b"),
    ("secrets", "kubectl … secret", r"\bkubectl(?=\s)[^|;&\n]*\ssecrets?\b"),
    ("secrets", "vault kv|read|write|delete", r"\bvault\s+(?:kv|read|write|delete)\b"),
    ("security-boundary", "kind: Role|RoleBinding|ClusterRole…|NetworkPolicy|ValidatingAdmissionPolicy",
     r"\bkind:\s*(?:ClusterRole|ClusterRoleBinding|Role|RoleBinding|NetworkPolicy|ValidatingAdmissionPolicy\w*)\b"),
    ("security-boundary", "gh pr merge --admin",
     r"\bgh(?:\s+(?:-R|--repo)[\s=]+\S+)?\s+pr(?:\s+(?:-R|--repo)[\s=]+\S+)?\s+merge\b[^|;&\n]*\s--admin\b"),
    ("security-boundary", "private=false|visibility=public", r"\b(?:private=false|visibility=public)\b"),
    ("security-boundary", "--visibility public", r"--visibility[\s=]+public\b"),
    ("cluster-lane", "flux suspend", r"\bflux\s+suspend\b"),
    ("cluster-lane", "kubectl … drain|cordon", r"\bkubectl(?=\s)[^|;&\n]*\s(?:drain|cordon)\b"),
    ("history-rewrite", "git push --force|-f|+<ref>",
     GIT + r"push\b[^|;&\n]*(?:\s--force(?![-\w])|\s-[A-Za-z]*f[A-Za-z]*\b|\s\+[^\s+])"),
    ("history-rewrite", "git filter-branch|filter-repo", GIT + r"filter-(?:branch|repo)\b"),
    ("history-rewrite", "git push --mirror", GIT + r"push\b[^|;&\n]*\s--mirror\b"),
    ("money-org", "gh repo create|rename|transfer|archive", r"\bgh\s+repo\s+(?:create|rename|transfer|archive)\b"),
    ("money-org", "gh api /orgs/<org>/members|memberships|teams|billing|settings",
     r"\bgh\s+api\b[^|;&\n]*/orgs/[^/\s]+/(?:members|memberships|teams|billing|settings)"),
    ("publish", "--visibility public", r"--visibility[\s=]+public\b"),
    ("publish", "npm publish", r"\bnpm\s+publish\b"),
    ("publish", "gh gist create --public|-p", r"\bgh\s+gist\s+create\b[^|;&\n]*\s(?:--public|-p)\b"),
    ("publish", "private=false|visibility=public", r"\b(?:private=false|visibility=public)\b"),
)


# A privileged write outside write() runs in every phase: rehearse, sign and a plain `bash x.sh` would perform it before anyone
# approved it. check flags these commands outside write() and outside the functions that are only called through write().
# A heuristic like STOP_HINTS: a write behind a variable or another tool is not seen.
DRY_RUN = re.compile(r"\s--dry-run(?:=(?:server|client|true))?(?![\w=-])")    # on the masked command: a dry run is a read
METHOD = r"(?:-X\s*|--method[\s=]+)[\"']?"
PRIVILEGED = re.compile(r"(?:" + "|".join((
    r"gh(?:\s+(?:-R|--repo)[\s=]+\S+)?\s+(?:pr|issue|release|repo|secret|variable|label|gist|workflow|run)"
    r"(?:\s+(?:-R|--repo)[\s=]+\S+)?\s+(?:merge|create|edit|close|reopen|delete|comment|review|ready|set|rename|archive"
    r"|transfer|upload|enable|disable|rerun|cancel|run|update-branch)(?![\w-])",
    r"gh\s+api\b(?=[^|;&\n]*\s" + METHOD + r"(?i:POST|PATCH|DELETE|PUT)\b)",
    r"gh\s+api\b(?![^|;&\n]*\sgraphql\b)(?![^|;&\n]*\s" + METHOD + r"(?i:GET|HEAD)\b)"
    r"(?=[^|;&\n]*\s(?:-[fF]\S*|--(?:raw-)?field|--input)(?:\s|=|$))",
    r"gh\s+api\s+graphql\b(?=[^|;&\n]*(?i:mutation))",
    r"docker(?:\s+-{1,2}(?!-)[\w-]+(?:[=\s]+(?!-)\S+)?)*\s+(?:(?:image|manifest|compose)\s+)?push\b",
    r"docker\s+(?:buildx\s+)?(?:build|bake)\b[^|;&\n]*\s(?:--push\b|(?:--output|-o)[=\s]+\S*(?:type=registry|push=true))",
    r"claude\s+plugins?\s+(?:install|i|uninstall|remove|update|enable|disable|prune|autoremove|configure"
    r"|marketplace\s+(?:add|remove|update))\b",
    GIT[2:] + r"push\b",
    r"kubectl\b(?![^|;&\n]*\sauth\s+can-i\b)[^|;&\n]*?\s(?:apply|patch|delete|create|replace"
    r"|edit|scale|drain|cordon|label|annotate|rollout\s+(?:restart|undo|pause|resume))(?![\w-])",
    r"helm\s+(?:install|upgrade|uninstall|rollback)\b",
    r"flux\s+(?:suspend|resume|reconcile|delete|create)\b",
)) + ")")


def is_dry(word, masked):
    """A dry run (`--dry-run`, `--dry-run=server|client|true`; `git push -n`) outside quotes: a read, not a write."""
    return bool(DRY_RUN.search(masked) or (word == "git" and re.search(r"\s-n(?![\w-])", masked)))


class Interrupted(Exception):
    """SIGTERM or SIGHUP (a tool timeout, a closed terminal): handled like Ctrl-C, which a background job never receives."""


def _on_term(_signum, _frame):
    raise Interrupted()


RUN = {"consumed": False}                               # set once `run` has used its signature


class Stop(Exception):
    def __init__(self, rc, msg):
        Exception.__init__(self, msg)
        self.rc = rc


def sha256(data):
    return hashlib.sha256(data if isinstance(data, bytes) else data.encode("utf-8", "surrogateescape")).hexdigest()


def now_iso():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def say(msg, out=None):
    (out or sys.stdout).write(msg + "\n")
    (out or sys.stdout).flush()


# ── the script ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────
class Kit:
    """Where a kit baton comes from: its file, the real batons/ it lies in (the binding), the plugin root BATON_PLUGIN_ROOT names,
    and the plugin id (None for sdlc's own)."""
    def __init__(self, path, batons, root, pid):
        self.path, self.batons, self.root, self.pid = path, batons, root, pid


def kit_path(arg):
    """The Kit of `kit:<name>`: <sdlc>/batons/<name>.sh, else batons/<name>.sh of the one dependent plugin that ships it
    (dependent_kits). The name is lower-case letters, digits and '-' (no '/', no '.'), and the file must lie in its batons
    directory itself: a link that leads out is refused before anything runs, as are a name sdlc and a dependent plugin both
    ship, a name two dependent plugins ship, and a name only plugins that may not run it ship."""
    name = arg[len("kit:"):]
    if not KIT_RE.match(name):
        raise Stop(USAGE, "%s: a kit baton is named by lower-case letters, digits and '-' only (no '/', no '.')" % arg)
    root = KIT_ROOT
    path = os.path.join(root, name + ".sh")
    found, refused, why = dependent_kits(arg, name)
    if os.path.lexists(path):
        if found:
            raise Stop(USAGE, "%s: both %s and %s ship batons/%s.sh; a kit name must be unique, so neither runs"
                       % (arg, SDLC, " and ".join(k.pid for k in found), name))
        if os.path.dirname(os.path.realpath(path)) != root:
            raise Stop(USAGE, "%s: %s leads outside %s" % (arg, path, root))
        return Kit(path, root, plugin_real(), None)
    if len(found) > 1:
        raise Stop(USAGE, "%s: %s both ship batons/%s.sh; a kit name must be unique, so none runs"
                   % (arg, " and ".join(k.pid for k in found), name))
    if found:
        return found[0]
    if refused:
        raise Stop(USAGE, "\n".join(refused))
    raise Stop(NOINPUT, "%s: no such kit baton in %s%s" % (arg, root, why or " nor in batons/ of a plugin that depends on " + SDLC))


def read_small(path, cap, nofollow=True):
    """The text of a regular file of at most `cap` bytes, opened without blocking and, with `nofollow`, never through a symlink;
    ValueError or OSError."""
    fd = os.open(path, os.O_RDONLY | (getattr(os, "O_NOFOLLOW", 0) if nofollow else 0) | getattr(os, "O_NONBLOCK", 0)
                 | getattr(os, "O_NOCTTY", 0))
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise ValueError("is not a regular file")
        chunks, size = [], 0
        while size <= cap:
            b = os.read(fd, cap + 1 - size)
            if not b:
                break
            chunks.append(b)
            size += len(b)
        if size > cap:
            raise ValueError("is larger than %d bytes" % cap)
        return b"".join(chunks).decode("utf-8")
    finally:
        os.close(fd)


def installed_sdlc():
    """(plugins directory, marketplace, registry) of this baton.py when it is an installed copy, or (None, None, why): its
    real plugin root is <plugins>/cache/<marketplace>/vibemaestro-sdlc/<version> and that directory's installed_plugins.json
    lists vibemaestro-sdlc@<marketplace> there."""
    me = plugin_real()
    parent = os.path.dirname(me)
    mdir = os.path.dirname(parent)
    cache = os.path.dirname(mdir)
    if os.path.basename(parent) != SDLC or os.path.basename(cache) != "cache":
        return None, None, (", and this baton.py (%s) is not an installed copy under <claude dir>/plugins/cache/, so no other "
                            "plugin's kit is looked up" % me)
    plugins, market = os.path.dirname(cache), os.path.basename(mdir)
    reg = os.path.join(plugins, "installed_plugins.json")
    try:
        data = json.loads(read_small(reg, MAX_REGISTRY, nofollow=False))     # followed, as the launcher reads it
    except (OSError, ValueError, RecursionError) as e:
        return None, None, ", and the plugin registry %s cannot be read (%s)" % (reg, getattr(e, "strerror", None) or e)
    ids = data.get("plugins") if isinstance(data, dict) and data.get("version") == REGISTRY_VERSION else None
    if not isinstance(ids, dict):
        return None, None, ", and the plugin registry %s is not a version-%d registry" % (reg, REGISTRY_VERSION)
    mine = ids.get("%s@%s" % (SDLC, market))
    if not any(isinstance(e, dict) and usable_path(e.get("installPath")) and os.path.realpath(e["installPath"]) == me
               for e in (mine if isinstance(mine, list) else [])):
        return None, None, ", and the plugin registry %s does not list %s@%s at %s" % (reg, SDLC, market, me)
    return plugins, market, ids


def usable_path(p):
    """An absolute path os.path.realpath can take: a str with no NUL that encodes to the file system's bytes."""
    if not isinstance(p, str) or not os.path.isabs(p) or "\0" in p:
        return False
    try:
        os.fsencode(p)
    except (UnicodeError, ValueError):
        return False
    return True


def latest_entry(entries):
    """The install entry with the latest `lastUpdated` (the first one on a tie), as the launcher picks sdlc's; None if none."""
    best = None
    for e in entries if isinstance(entries, list) else []:
        if isinstance(e, dict) and isinstance(e.get("installPath"), str):
            stamp = e.get("lastUpdated") if isinstance(e.get("lastUpdated"), str) else ""
            if best is None or stamp > best[0]:
                best = (stamp, e)
    return best[1] if best else None


def depends_on_sdlc(manifest, market):
    """A `dependencies` item, a string or an object's `name`, that is vibemaestro-sdlc or vibemaestro-sdlc@<market>."""
    deps = manifest.get("dependencies") if isinstance(manifest, dict) else None
    for d in deps if isinstance(deps, list) else []:
        n = d if isinstance(d, str) else d.get("name") if isinstance(d, dict) else None
        if n in (SDLC, "%s@%s" % (SDLC, market)):
            return True
    return False


def dependent_kits(arg, name):
    """([Kit] of the dependent plugins that may run batons/<name>.sh, [why each other plugin that ships it may not], why no
    plugin was looked up or ""). Every plugin of the registry beside this copy is looked at, sorted by id; only one that ships
    the file is read further. Never raises: a plugin that cannot be read is a refusal of its own."""
    plugins, market, ids = installed_sdlc()
    if plugins is None:
        return [], [], ids
    found, refused = [], []
    for pid in sorted(ids):
        p, _at, m = pid.partition("@")
        if p == SDLC or not p or not m:
            continue
        e = latest_entry(ids[pid])
        inst = e.get("installPath") if e else None
        if not usable_path(inst):
            continue
        try:
            real = os.path.realpath(inst)
            batons = os.path.join(real, "batons")
            path = os.path.join(batons, name + ".sh")
            if not os.path.lexists(path):
                continue
            ships = "%s: %s ships batons/%s.sh but " % (arg, pid, name)
            manifest = os.path.join(real, ".claude-plugin", "plugin.json")
            home = os.path.join(plugins, "cache", market, p)
            if m != market:
                refused.append(ships + "comes from marketplace %s, not %s (this %s's)" % (m, market, SDLC))
            elif os.path.dirname(real) != home or not INSTALL_DIR.match(os.path.basename(real)):
                refused.append(ships + "is installed at %s, not under %s/<version>" % (real, home))
            elif os.path.dirname(os.path.realpath(path)) != batons:
                refused.append(ships + "%s leads outside %s" % (path, batons))
            elif os.path.realpath(manifest) != manifest:
                refused.append(ships + "its %s is reached through a symlink" % manifest)
            elif not depends_on_sdlc(json.loads(read_small(manifest, MAX_MANIFEST)), market):
                refused.append(ships + "its plugin.json does not declare a dependency on %s" % SDLC)
            else:
                found.append(Kit(path, batons, real, pid))
        except (OSError, ValueError, RecursionError) as e:
            refused.append("%s: %s ships batons/%s.sh but its manifest cannot be read (%s)"
                           % (arg, pid, name, getattr(e, "strerror", None) or e))
    return found, refused, ""


def kind_path(arg):
    """The file of the callable kind `kind:<name>`: <plugin>/templates/baton-kinds/<name>.sh, for a name in CALLABLE_KINDS only."""
    name = arg[len("kind:"):]
    if name not in CALLABLE_KINDS:
        raise Stop(USAGE, "%s: no such callable kind; the callable kinds are %s (`new --from` writes any kind)"
                   % (arg, ", ".join(CALLABLE_KINDS)))
    path = os.path.join(KINDS_REAL, name + ".sh")
    if not os.path.lexists(path):
        raise Stop(NOINPUT, "%s: no such kind in %s" % (arg, KINDS_REAL))
    if os.path.dirname(os.path.realpath(path)) != KINDS_REAL:
        raise Stop(USAGE, "%s: %s leads outside %s" % (arg, path, KINDS_REAL))
    return path


class Script:
    def __init__(self, path):
        self.kit = path.startswith("kit:")
        self.kind = path[len("kind:"):] if path.startswith("kind:") else None
        self.from_kit = kit_path(path) if self.kit else None
        if self.kit:
            path = self.from_kit.path
        elif self.kind is not None:
            path = kind_path(path)
        self.path = path
        try:
            with open(path, "rb") as f:
                self.data = f.read()
                self.mtime = os.fstat(f.fileno()).st_mtime    # of the bytes read, whatever the path is a link to
        except OSError as e:
            raise Stop(NOINPUT, "cannot read %s: %s" % (path, e.strerror or e))
        if self.kind is not None:
            self.data = self.data.replace(b"__NAME__", self.kind.encode("ascii"))
        self.real = os.path.realpath(path)
        self.name = os.path.basename(self.real)
        self.sha = sha256(self.data)
        self.text = self.data.decode("utf-8", "replace")
        self.plugin_scripts = {} if self.kit else plugin_scripts(self.text)
        self.tree_sha = scripts_tree_sha() if self.plugin_scripts else None
        if self.kit:
            self.bind_sha = sha256(self.sha + "\0kit:" + self.from_kit.batons)
        elif self.kind is not None:
            self.bind_sha = sha256(self.sha + "\0kind:" + KINDS_REAL)
        elif self.plugin_scripts:
            self.bind_sha = sha256(self.sha + "\0plugin:" + plugin_real() + "\0" + self.tree_sha)
        else:
            self.bind_sha = self.sha
        self.fields, self.header_end, self.header_problems = parse_header(self.text.split("\n"))

    def field(self, key):
        return self.fields.get(key, (0, ""))[1]

    def expect(self):
        return [v for _n, v in self.fields["Expect"]]

    def stops(self):
        """(declared categories, unknown words). `none` alone declares nothing."""
        words = [w.strip() for w in self.field("Stops").split(",") if w.strip()]
        if words == ["none"]:
            return [], []
        return [w for w in words if w in STOP_WORDS], [w for w in words if w not in STOP_WORDS]


def plugin_real():
    return os.path.realpath(PLUGIN_ROOT)


def plugin_runs(text):
    """[file] of each `"$BATON_PLUGIN_ROOT/scripts/<file>"` run as the command of a write() call, in order."""
    out = []
    entries = logical_lines(text)
    for k, _n, _p, i, _e, code, _m, word in simple_commands(entries):
        if word == "write":
            m = PLUGIN_SCRIPT_RUN.match(code, write_target(code, i))
            if m:
                out.append(m.group(1) or m.group(2))
    return out


def plugin_name_count(text):
    """How often the variable's name occurs in the text, a backslash-newline joined first (as bash reads it); comments and
    heredoc bodies count too."""
    return len(re.findall(r"BATON_PLUGIN_ROOT", text.replace("\\\n", "")))


def plugin_scripts(text):
    """{file: sha256 of its bytes, or None when baton may not run it} for the plugin scripts the write() calls run."""
    return dict((name, plugin_script_sha(name)) for name in sorted(set(plugin_runs(text))))


def plugin_script_sha(name):
    d = os.path.join(plugin_real(), "scripts")
    path = os.path.join(d, name)
    if name.lower() in PLUGIN_SCRIPTS_REFUSED or os.path.islink(path) or os.path.dirname(os.path.realpath(path)) != d \
            or not os.path.isfile(path) or any(same_file(path, os.path.join(d, x)) for x in PLUGIN_SCRIPTS_REFUSED):
        return None
    try:
        with open(path, "rb") as f:
            return sha256(f.read())
    except OSError:
        return None


def same_file(a, b):
    try:
        return os.path.samefile(a, b)
    except OSError:
        return False


def scripts_links():
    """The links under <real plugin root>/scripts: a plugin root that holds one runs no plugin script."""
    top, out = os.path.join(plugin_real(), "scripts"), []
    for root, dirs, files in os.walk(top):
        dirs[:] = [x for x in dirs if x != "__pycache__" or os.path.islink(os.path.join(root, x))]
        out += [os.path.relpath(os.path.join(root, x), top) for x in dirs + files if os.path.islink(os.path.join(root, x))]
    return sorted(out)


def scripts_tree_sha():
    """One sha256 over every name and byte under <real plugin root>/scripts (a link by its target), bytecode left out."""
    top, parts = os.path.join(plugin_real(), "scripts"), []
    for root, dirs, files in os.walk(top):
        dirs[:] = sorted(x for x in dirs if x != "__pycache__")
        for name in sorted(dirs + files):
            p = os.path.join(root, name)
            rel = os.path.relpath(p, top)
            if os.path.islink(p):
                parts.append("L %s %s" % (rel, os.readlink(p)))
            elif name in files and not name.endswith(".pyc"):
                try:
                    with open(p, "rb") as f:
                        parts.append("F %s %s" % (rel, sha256(f.read())))
                except OSError:
                    parts.append("E %s" % rel)
    return sha256("\n".join(parts))


def plugin_script_problems(s):
    """[(line, problem)]: in a session baton, a mention of BATON_PLUGIN_ROOT that is not a plugin script run by write(), and
    a named file that is not a plugin script baton may run."""
    if s.kit:
        return []
    probs = []
    runs, names = len(plugin_runs(s.text)), plugin_name_count(s.text)
    if names != runs:
        probs.append((0, 'BATON_PLUGIN_ROOT occurs %d time%s, but only %d %s write "<plan>" bash|python3 -I -B '
                         '"$BATON_PLUGIN_ROOT/scripts/<file>" …: a session baton names it nowhere else (not in a read, an '
                         'argument, a comment or a heredoc)' % (names, "" if names == 1 else "s", runs,
                                                               "is" if runs == 1 else "are")))
    for name, sha in sorted(s.plugin_scripts.items()):
        if sha is None:
            probs.append((0, "scripts/%s is not a plugin script baton may run (missing, a link, not directly in %s, or "
                             "baton itself)" % (name, os.path.join(plugin_real(), "scripts"))))
    links = scripts_links() if s.plugin_scripts else []
    if links:
        probs.append((0, "the plugin's scripts/ holds a link (%s): baton runs no plugin script from it" % ", ".join(links)))
    return probs


HEADER_LINE = re.compile(r"^#\s*([A-Z][A-Za-z]*):\s*(.*?)\s*$")


def parse_header(lines):
    """The leading comment block: ({field: (line, value)}, with Expect a list; index of the first body line; problems)."""
    fields, problems = {"Expect": []}, []
    end = len(lines)
    for i, line in enumerate(lines):
        s = line.strip()
        if i == 0 and s.startswith("#!"):
            continue
        if not s:
            continue
        if not s.startswith("#"):
            end = i
            break
        m = HEADER_LINE.match(s)
        if not m or m.group(1) not in HEADER_FIELDS:
            continue
        key, val = m.group(1), m.group(2)
        if key == "Expect":
            fields["Expect"].append((i + 1, val))
        elif key in fields:
            problems.append((i + 1, "header field %s is given twice" % key))
        else:
            fields[key] = (i + 1, val)
    return fields, end, problems


# ── a rough shell reader: logical lines with comments and heredoc bodies dropped ───────────────────────────────────────────────
HEREDOC = re.compile(r"<<(-?)\s*([\"']?)([A-Za-z_][\w]*)\2")


def logical_lines(text):
    """[(first line number, code, masked)] — one entry per logical line of shell. Comments and heredoc bodies are dropped and
    continued lines joined (a trailing `\\`, `|`, `&&` or `||`, or an open quote). `code` keeps the text inside quotes; `masked`
    replaces it with `_`, except a `$( … )` inside double quotes, which stays shell, so `|`, `;` and words inside a string are
    never read as syntax. A heuristic for lints, not a parser."""
    lines = text.split("\n")
    out, code, masked = [], [], []
    stack = [["c", 0, False, ""]]  # frames: [kind, paren depth, nested in "…", closer]; kinds c (code), d ("…"), s ('…')
    start, n = None, 0
    heredocs = []

    def emit(c, m=None):
        code.append(c)
        masked.append(c if m is None else m)

    while n < len(lines):
        line = lines[n]
        if start is None:
            start = n + 1
        j, cont = 0, False
        while j < len(line):
            ch, top = line[j], stack[-1]
            if top[0] == "s":
                if ch == "'":
                    stack.pop()
                    emit(ch)
                else:
                    emit(ch, "_")
                j += 1
                continue
            if top[0] == "d":
                if ch == "\\" and j + 1 < len(line):
                    emit(line[j:j + 2], "__")
                    j += 2
                elif ch == '"':
                    stack.pop()
                    emit(ch)
                    j += 1
                elif line.startswith("$(", j) and not line.startswith("$((", j):
                    stack.append(["c", 0, True, ")"])
                    emit("$(")
                    j += 2
                elif ch == "`":
                    stack.append(["c", 0, True, "`"])
                    emit(ch)
                    j += 1
                else:
                    emit(ch, "_")
                    j += 1
                continue
            if ch == "\\":
                if j + 1 == len(line):
                    cont = True
                    j += 1
                    continue
                emit(line[j:j + 2], "__")
                j += 2
                continue
            if ch == "`" and top[3] == "`":
                stack.pop()
                emit(ch)
                j += 1
                continue
            if ch == "'":
                stack.append(["s", 0, False, ""])
            elif ch == '"':
                stack.append(["d", 0, False, ""])
            elif ch == "#" and (j == 0 or line[j - 1] in " \t;&|("):
                break
            elif ch == "(":
                top[1] += 1
            elif ch == ")":
                if top[1] == 0 and top[3] == ")":
                    stack.pop()
                elif top[1] > 0:
                    top[1] -= 1
            elif line.startswith("<<", j) and not line.startswith("<<<", j):
                m = HEREDOC.match(line, j)
                if m:
                    heredocs.append((m.group(3), m.group(1) == "-"))
                    emit(m.group(0))
                    j = m.end()
                    continue
            emit(ch)
            j += 1
        n += 1
        while heredocs:                       # the bodies start on the next line
            word, tabs = heredocs.pop(0)
            while n < len(lines) and (lines[n].lstrip("\t") if tabs else lines[n]) != word:
                n += 1
            n += 1
        tail = "".join(masked).rstrip()
        if cont or len(stack) > 1 or tail.endswith("|") or tail.endswith("&&"):
            emit(" " if not len(stack) > 1 else "\n", " " if not len(stack) > 1 else "_")
            if n < len(lines):
                continue
        out.append((start, "".join(code), "".join(masked)))
        code, masked, start = [], [], None
    return out


STATEMENT_SPLIT = re.compile(r";|(?<![<>&])&(?![&>])|\n")
LEADING = re.compile(r"^\s*(?:then|do|else|\{|\()\s+|^\s*case\s+\S+\s+in\s+|^\s*(?:function\s+)?[A-Za-z_][\w-]*\s*\(\s*\)\s*\{\s*|^\s*\(?[^\s()|;&]+(?:\s*\|\s*[^\s()|;&]+)*\)\s*")


def statements(masked):
    """And-or lists of one masked logical line, with leading keywords and case labels stripped."""
    for stmt in STATEMENT_SPLIT.split(masked):
        prev = None
        while prev != stmt:
            prev, stmt = stmt, LEADING.sub("", stmt, count=1)
        if stmt.strip():
            yield stmt


WRAPPERS = ("env", "timeout", "sudo", "xargs", "nice", "nohup", "stdbuf", "command", "exec", "time")


def command_word(seg):
    """The command a simple command runs: assignments, `{`, `$(` and wrappers such as `env`, `timeout 5`, `sudo -u x` skipped."""
    m = re.match(r"[^\s;|&()<>\"]+", seg[command_start(seg):])
    return os.path.basename(m.group(0)) if m else ""


def unguarded_pipes(masked):
    """The tolerated commands of this line that sit in a pipeline whose failure stops a `set -e` script."""
    s, prev = masked, None
    while prev != s:                                    # `{ cmd || true; }` and `( cmd || … )` are guarded groups
        prev = s
        s = re.sub(r"\{\s*[^{};]*\|\|\s*(?:true|:)\s*;?\s*\}", " GUARDED ", s)    # one statement, `cmd || true`
        s = re.sub(r"(?<!\$)\((?!\()\s*[^();]*\|\|\s*(?:true|:)\s*\)", " GUARDED ", s)
    hits = []
    for stmt in statements(s):
        if re.match(r"\s*(?:if|elif|while|until)\b|\s*!", stmt):
            continue                                    # a condition: set -e does not apply
        last = re.split(r"&&|\|\|", stmt)[-1]          # only the last pipeline of an and-or list stops the script
        segs = re.split(r"(?<!\|)\|(?!\|)", last)
        if len(segs) < 2:
            continue
        hits += [w for w in (command_word(g) for g in segs) if w in TOLERATED]
    return hits


# A local script run as a command (`./x`, `"$HERE/x"`, `bash x.sh`): the signature binds this file only.
LOCAL_RUN = re.compile(r"(?:(?:bash|sh|zsh|dash|python3?|node|ruby|perl)\s+(?:-[A-Za-z]+\s+)*[\"']?[^\s;|&\"']*\.(?:sh|bash|py|js|rb|pl)\b"
                       r"|[\"']?(?:\.{1,2}/|\$\{?\w+\}?/))")
SEPARATORS = re.compile(r"\|\||&&|;;|(?<![<>&])&(?![&>])|[;|\n`()]|\$\(\(?|[<>]\(")
BLOCK_LEAD = re.compile(r"\s*(\{|if|while|until|for|select|case|then|do|else|elif|time(?:\s+-p)?|!)(?=\s|$)")
BLOCK_OPENERS = ("{", "if", "while", "until", "for", "select", "case")
BLOCK_END = re.compile(r"\s*(\}|fi|done|esac)(?=\s|$)")
FUNC_HEAD = re.compile(r"(?:^|(?<=[\s;&|{]))(?:function\s+)?[A-Za-z_][\w-]*\s*\(\s*\)")
HEAD = re.compile(r"\s*(?:\{|\(|\"?\$\(|!|(?:if|elif|while|until|then|do|else)\s|case\s+\S+\s+in\s|[A-Za-z_]\w*=\"?\$\(|"
                  r"[A-Za-z_]\w*=\S*\s)")
# options of a wrapper that take a value (`xargs -I %`, `sudo -u x`, `timeout -s KILL 5`)
WRAPPER_ARGS = {"xargs": "ILnPdEsa", "sudo": "ugCDhpRrTt", "timeout": "sk", "env": "uCS", "nice": "n", "stdbuf": "ioe"}


def word_end(s, i):
    """End of the shell word that starts at s[i]: quotes, `$( … )` and `${ … }` followed to their close."""
    stack = []
    while i < len(s):
        c, top = s[i], (stack[-1] if stack else None)
        if top == "'":
            if c == "'":
                stack.pop()
        elif c == "\\":
            i += 2
            continue
        elif s.startswith("$(", i) or s.startswith("${", i):
            stack.append(s[i + 1])
            i += 2
            continue
        elif top == '"':
            if c == '"':
                stack.pop()
        elif c in "'\"":
            stack.append(c)
        elif c == "(" and top == "(":
            stack.append("(")
        elif (c == ")" and top == "(") or (c == "}" and top == "{"):
            stack.pop()
        elif not stack and (c.isspace() or c in ";&|"):
            return i
        i += 1
    return i


def command_start(masked):
    """Index in a simple command (masked) where the command itself starts: after keywords, `{`, `$(`, a case label,
    assignments, and wrappers such as `env`, `timeout 5`, `sudo -u x`, `xargs`."""
    i = 0
    while True:
        m = HEAD.match(masked, i)
        if not m or m.end() == i:
            break
        i = m.end()
    while True:
        m = re.compile(r"\s*([^\s;|&()<>\"]+)").match(masked, i)
        if not m or os.path.basename(m.group(1)) not in WRAPPERS:
            break
        wrapper, i = os.path.basename(m.group(1)), m.end()
        while True:
            m = re.compile(r"\s+([^\s;|&()<>\"]+)").match(masked, i)
            if not m or not (m.group(1).startswith("-") or "=" in m.group(1) or re.match(r"^\d+(?:\.\d+)?[smhd]?$", m.group(1))):
                break
            i = m.end()
            if re.match(r"^-[%s]$" % WRAPPER_ARGS.get(wrapper, "_"), m.group(1)):
                m = re.compile(r"\s+\S+").match(masked, i)          # the option's value
                i = m.end() if m else i
    while i < len(masked) and masked[i].isspace():
        i += 1
    return i


def simple_commands(entries):
    """(entry index, line, segment start, command start, segment end, raw line, masked line, command word) of every simple
    command, also those inside `$( … )`, backticks and `( … )`."""
    for k, (n, code, masked) in enumerate(entries):
        masked = FUNC_HEAD.sub(lambda m: " " * len(m.group()), masked)
        pos, groups, after_group = 0, [], False
        for m in list(SEPARATORS.finditer(masked)) + [None]:
            end = m.start() if m else len(masked)
            sep = m.group(0) if m else ""
            label = sep == ")" and not groups                       # an unmatched `)` ends a case pattern
            inert = bool(groups) and groups[-1] in ("array", "label")
            if masked[pos:end].strip() and not (label or inert or after_group):
                i = pos + command_start(masked[pos:end])
                word = re.match(r"[^\s;|&()<>\"]*", masked[i:end]).group(0)
                yield k, n, pos, i, end, code, masked, os.path.basename(word)
            after_group = False
            if not m:
                break
            before = masked[:m.start()]
            if sep in ("(", "<(", ">(") or sep.startswith("$("):
                if sep == "(" and re.search(r"[A-Za-z_]\w*\+?=$", before):
                    groups.append("array")                          # `files=( … )`: words, not commands
                elif sep == "(" and re.search(r"(?:\bin|;;&?|;&)\s*$", before):
                    groups.append("label")                          # `case x in (a) …`
                else:
                    groups.append("(")
            elif sep == "`":
                if groups and groups[-1] == "`":
                    groups.pop()
                    after_group = True
                else:
                    groups.append("`")
            elif sep == ")" and groups:
                after_group = groups.pop() in ("(", "array")        # what follows continues the enclosing command
            pos = m.end()


def gh_state_in_subshell(entries):
    """Line numbers of the skeleton's `gh_state` called where its GH_STATE and its `exit` stay in a subshell: nested in
    `$( … )`, `( … )`, `<( … )` or backticks, a side of a pipe, sent to the background with `&`, or inside a `{ … }`, `if`,
    loop or `case` block that is piped or sent to the background as a whole. It splits at SEPARATORS as
    simple_commands does and reads every keyword that leads a segment (`do if`, `then {`, `time {`, `} }`). Not seen: a `$(`
    opened on an earlier line, a heredoc body, a function that wraps gh_state, `coproc`, and a case label inside `$( … )`."""
    blocks = []                                         # [piped, holds gh_state] per open block, across lines
    for n, _code, masked in entries:
        masked = FUNC_HEAD.sub(lambda m: " " * len(m.group()), masked)
        pos, groups, prev, pending = 0, [], "", None    # pending: the level of a closed block that held gh_state
        for m in list(SEPARATORS.finditer(masked)) + [None]:
            end = m.start() if m else len(masked)
            sep = m.group(0) if m else ""
            seg = masked[pos:end]
            if sep == ")" and not groups:                # a case label (`done)`, `if)`) is no keyword: drop its word
                seg = re.sub(r"\S*\s*$", "", seg)
            if seg.strip():
                k = 0
                while True:
                    kw = BLOCK_LEAD.match(seg, k)
                    if not kw:
                        break
                    if kw.group(1) in BLOCK_OPENERS:
                        blocks.append([prev == "|", False])
                    k = kw.end()
                while prev != ")":                      # `${V:-$(cmd)}`: a `}` right after `)` closes no block
                    kw = BLOCK_END.match(seg, k)
                    if not kw:
                        break
                    if blocks and blocks.pop()[1]:
                        pending = len(groups)
                    k = kw.end()
                word = re.match(r"[^\s;|&()<>\"]*", seg[k + command_start(seg[k:]):]).group(0)
                if word == "gh_state":
                    if "(" in groups or "`" in groups or prev == "|" or sep in ("|", "&") or any(b[0] for b in blocks):
                        yield n
                    for b in blocks:
                        b[1] = True
            if pending is not None and len(groups) == pending:
                if sep in ("|", "&"):
                    yield n
                    pending = None
                elif sep in (";", "&&", "||", ";;", "\n", ""):
                    pending = None
            if not m:
                break
            if sep in ("(", "<(", ">(") or sep.startswith("$("):
                groups.append("(")
            elif sep == "`":
                if groups and groups[-1] == "`":
                    groups.pop()
                else:
                    groups.append("`")
            elif sep == ")" and groups:
                groups.pop()
            if not (sep == "&" and prev == "|" and not seg.strip()):   # `|&` is a pipe: keep prev at `|`
                prev = sep
            pos = m.end()

def command_text(code, masked, i):
    """(raw, masked) of the command that starts at i, up to its end at its own level, with every nested `$( … )`, `( … )`
    and backtick group blanked to underscores of the same length: the options after a substitution still count."""
    inside_tick = masked[:i].count("`") % 2 == 1
    depth, tick, j, raw, msk = 0, False, i, [], []
    while j < len(masked):
        c = masked[j]
        if depth == 0 and not tick and (c in ";&|\n)" or (c == "`" and inside_tick)):
            break
        if c in "()`" or masked.startswith("$(", j):
            width = 2 if masked.startswith("$(", j) else 1
            depth += 1 if c in "($" else -1 if c == ")" else 0
            tick = not tick if c == "`" else tick
            raw.append("_" * width)
            msk.append("_" * width)
            j += width
            continue
        nested = depth > 0 or tick
        raw.append("_" if nested else code[j])
        msk.append("_" if nested else c)
        j += 1
    return "".join(raw), "".join(msk)


def sources_file(masked):
    return any(command_word(part) in ("source", ".") for st in statements(masked) for part in re.split(r"&&|\|\|", st))


def set_changes(code):
    """(turned on, turned off) by one `set` line: short flags and -o names, errexit and nounset read as e and u."""
    m = re.match(r"^\s*set\s+(.*)$", code)
    on, off = set(), set()
    if not m:
        return on, off
    toks, i = m.group(1).split(), 0
    while i < len(toks):
        t = toks[i]
        if re.match(r"^[-+][a-zA-Z]+$", t):
            dest = on if t[0] == "-" else off
            dest.update(t[1:].replace("o", ""))
            if "o" in t[1:] and i + 1 < len(toks):
                name = toks[i + 1]
                dest.add({"errexit": "e", "nounset": "u"}.get(name, name))
                i += 1
        i += 1
    return on, off


def span_after(entries, k, closer):
    """Index of the first entry after k whose code matches closer, else len(entries) - 1."""
    for i in range(k + 1, len(entries)):
        if closer(entries[i][1]):
            return i
    return len(entries) - 1


def gate_body(text):
    """The normalised statements of write() in a script text, or None when it has none."""
    entries = logical_lines(text)
    for k, (_n, code, _m) in enumerate(entries):
        if re.match(r"^\s*(?:function\s+)?write\s*\(\s*\)", code):
            end = k if code.rstrip().endswith("}") else span_after(entries, k, lambda c: c.strip() == "}")
            return [" ".join(c.split()) for _n2, c, _m2 in entries[k:end + 1] if c.strip()]
    return None


def branch_bodies(dtext):
    """{label: [statement, ...]} of the final dispatch, the verdict echo left out."""
    out = {}
    for chunk in dtext.split(";;"):
        m = re.match(r"\s*\(?\s*([\w*|\s-]+?)\s*\)(.*)$", chunk, re.S)
        if not m:
            continue
        stmts = [st.strip() for st in re.split(r"[\n;]", m.group(2)) if st.strip()]
        stmts = [st for st in stmts if not re.search(r"VERDICT\s+\w+\s+ok", st)]
        for lab in m.group(1).split("|"):
            out[lab.strip()] = stmts
    return out


def function_spans(entries):
    """{name: set of entry indexes of its body}, for `name() {` definitions."""
    spans = {}
    for k, (_n, code, _m) in enumerate(entries):
        m = re.match(r"^\s*(?:function\s+)?([A-Za-z_][\w-]*)\s*\(\s*\)", code)
        if m:
            end = k if code.rstrip().endswith("}") else span_after(entries, k, lambda c: c.strip() == "}")
            spans[m.group(1)] = set(range(k, end + 1))
    return spans


def write_target(code, i):
    """The offset of the command a `write` call at code[i] runs: past the word and the plan line, whatever quotes it holds."""
    j = i + len("write")
    j += len(code[j:]) - len(code[j:].lstrip())
    c = word_end(code, j)
    return c + len(code[c:]) - len(code[c:].lstrip())


def unwrapped_writes(entries, trusted=None, trusted_outside=True):
    """[(line, problem)]: a privileged command outside write(); a function of this script used through write() and called
    without it; a local script run (the signature would not bind it). `trusted` is the form of plugin code that is not a local
    script: TRUSTED_RUN (a plugin gate, anywhere) for a kit baton; PLUGIN_SCRIPT_RUN for a session baton, only as the command a
    write() runs (`trusted_outside` False), so it never runs in rehearse."""
    spans = function_spans(entries)
    cmds = list(simple_commands(entries))
    target = {}                                         # (entry, offset) of the command a write() call runs
    for k, _n, _p, i, _e, code, _m, word in cmds:
        if word == "write":
            c = write_target(code, i)                   # past the plan line, whatever quotes and $( … ) it holds
            target[(k, c)] = re.match(r"[^\s;|&()<>\"']*", code[c:]).group(0)
    wrapped = set(name for name in target.values() if name in spans)    # functions of this script, not tools (gh, rm)
    exempt = set()
    for f in wrapped | {"write"}:
        exempt |= spans.get(f, set())
    probs = []
    for k, n, pos, i, end, code, masked, word in cmds:
        hit = [c for (kk, c) in target if kk == k and pos <= c < max(end, pos + 1)]
        if word == "write" and not hit:
            continue
        if hit:                                         # the command a write() runs: only a local script is wrong here
            if LOCAL_RUN.match(code, hit[0]) and not (trusted and trusted.match(code, hit[0])):
                probs.append((n, "runs a local script through write(): the signature binds this script only; inline it"))
            continue
        raw = code[i:end]
        if LOCAL_RUN.match(raw) and not (trusted and trusted_outside and trusted.match(raw)):
            probs.append((n, "runs a local script: the signature binds this script only; inline the helper"))
        if k in exempt:
            continue
        if word in wrapped:
            probs.append((n, "`%s` is a write (it goes through write() elsewhere) called without write()" % word))
        else:
            whole, whole_masked = command_text(code, masked, i)
            prefix = re.match(r"\S*/", whole)                     # `/usr/bin/gh …`: the command's own path
            if PRIVILEGED.match(whole, prefix.end() if prefix else 0) and not is_dry(word, whole_masked):
                probs.append((n, "a privileged command outside write(): it would run in rehearse too (%s)" % whole.strip()[:60]))
    return probs


# ── check ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
def check_script(s):
    """[(line, problem)] of a baton script; empty when it passes."""
    probs = list(s.header_problems)
    for key in HEADER_FIELDS:
        if key == "Expect":
            each = s.fields.get("Each")
            if each and s.fields["Expect"]:
                probs.append((each[0], "header: Each and Expect lines together; a baton uses one of the two"))
            elif not each and not s.fields["Expect"]:
                probs.append((0, "header: no Expect line (one per planned write)"))
            probs += [(n, "header: empty Expect") for n, v in s.fields["Expect"] if not v]
        elif key == "Each":
            if key in s.fields:
                n, v = s.fields[key]
                if not s.kit:
                    probs.append((n, "header: Each is for kit batons shipped in the plugin (kit:<name>) only; use one Expect "
                                     "line per planned write"))
                if not v or v[0] in "*?[":
                    probs.append((n, "header: Each must start with a literal character (not *, ? or [)"))
        elif key not in s.fields:
            probs.append((0, "header: no %s field" % key))
        elif not s.fields[key][1]:
            probs.append((s.fields[key][0], "header: empty %s" % key))
    _stops, unknown = s.stops()
    if unknown:
        probs.append((s.fields.get("Stops", (0,))[0], "header: Stops holds %s; use `none` or a comma list of: %s"
                      % (", ".join(unknown), ", ".join(STOP_WORDS))))

    entries = logical_lines(s.text)
    flags = set()
    for _n, code, _m in entries:                        # in order: a later `set +e` turns errexit off again
        on, off = set_changes(code)
        flags = (flags | on) - off
    if not {"e", "u", "pipefail"} <= flags:
        probs.append((0, "no `set -euo pipefail` in force (a later `set +e`, `+u` or `+o pipefail` turns it off)"))

    defs = {}
    for k, (n, code, _m) in enumerate(entries):
        m = re.match(r"^\s*(?:function\s+)?(write|postcheck|undo)\s*\(\s*\)", code)
        if m:
            defs.setdefault(m.group(1), []).append(k)
    if len(defs.get("write", [])) != 1:
        probs.append((0, "the write() gate must be defined exactly once (found %d)" % len(defs.get("write", []))))

    phase_reads = [n for n, code, _m in entries if "BATON_PHASE" in code]
    if not any(PHASE_LINE.match(code) for _n, code, _m in entries):
        probs.append((0, "the phase is not read as `PHASE=${BATON_PHASE:-rehearse}` (a plain bash run must rehearse)"))
    probs += [(n, "BATON_PHASE read again: the phase is read once, into PHASE") for n in phase_reads[1:]]

    disp = [k for k, (_n, code, _m) in enumerate(entries) if re.search(r"\bcase\s+\"?\$\{?PHASE\}?\"?\s+in\b", code)]
    gate = set()                                        # the body of write()
    for k in defs.get("write", [])[:1]:
        one_line = entries[k][1].rstrip().endswith("}")
        gate = set(range(k, (k if one_line else span_after(entries, k, lambda c: c.strip() == "}")) + 1))
    inside = set(gate)
    labels, dtext = {}, ""
    if not disp:
        probs.append((0, "no final dispatch `case \"$PHASE\" in` (so no rehearse path)"))
    else:
        k0 = disp[-1]
        k1 = span_after(entries, k0, lambda c: re.match(r"^\s*esac\b", c) is not None)
        inside.update(range(k0, k1 + 1))
        for _n, code, _m in entries[k0 + 1:k1]:
            dtext += code + "\n"
            m = re.match(r"^\s*\(?\s*([\w*|\s-]+?)\s*\)", code)
            if m:
                for lab in m.group(1).split("|"):
                    labels.setdefault(lab.strip(), True)
    for k, (n, code, _m) in enumerate(entries):
        if k not in inside and not PHASE_LINE.match(code) and re.search(r"\$\{?PHASE\b", code):
            probs.append((n, "the phase is looked at outside write() and the final dispatch (fidelity: rehearse and run take one path)"))
    for k, (n, code, _m) in enumerate(entries):
        if k not in gate and re.search(r"\b(?:echo|printf)\b[^\n]*?[\"']PLAN\s", code):
            probs.append((n, "a PLAN line printed outside write(): the plan comes from write() only"))
    if disp:
        bodies = branch_bodies(dtext)
        if "rehearse" in bodies and "run" in bodies and bodies["rehearse"] != bodies["run"]:
            probs.append((0, "the rehearse) and run) branches differ: both run the same act, only the verdict line differs"))
        for lab, stmts in sorted(bodies.items()):
            if any(re.search(r"\|\||&&", st) or re.match(r"^(?:if|!)\s", st) for st in stmts):
                probs.append((0, "the %s) branch masks a failure (`||`, `&&`, `if` or `!`): a failed write must stop it" % lab))
    try:
        with open(TEMPLATE, encoding="utf-8") as f:
            want = gate_body(f.read())
    except OSError:
        want = None
    if defs.get("write") and want is not None and gate_body(s.text) != want:
        probs.append((0, "write() differs from the template's gate: copy it unchanged from `baton.py new`"))
    probs += unwrapped_writes(entries, TRUSTED_RUN, True) if s.kit else unwrapped_writes(entries, PLUGIN_SCRIPT_RUN, False)
    probs += plugin_script_problems(s)
    for ph in PHASES:
        what = {"rehearse": "rehearse path", "run": "run path", "postcheck": "post-check", "undo": "undo"}[ph]
        if disp and ph not in labels:
            probs.append((0, "no %s: the final dispatch has no `%s)` branch" % (what, ph)))
        if disp and ("VERDICT %s ok" % ph) not in dtext:
            probs.append((0, "no %s verdict: the dispatch never prints `VERDICT %s ok`" % (what, ph)))
        if ph in ("postcheck", "undo") and not defs.get(ph):
            probs.append((0, "no %s() function" % ph))

    for n in sorted(set(gh_state_in_subshell(entries))):
        probs.append((n, "`gh_state` in `$(…)`, backticks, a pipe, a subshell or the background: its answer and its exit "
                      "stay there; call it as a statement, then test $GH_STATE"))
    for n, _code, masked in entries:
        for w in unguarded_pipes(masked):
            probs.append((n, "`%s` in a pipeline under pipefail: its normal non-zero exit stops the script; wrap it "
                             "`{ %s … || true; }`" % (w, w)))
        if sources_file(masked):
            probs.append((n, "`source`/`.` of another file: the signature covers this file only"))

    declared, _u = s.stops()
    body = s.text.split("\n")
    joined, n0 = "", 0
    for i in range(s.header_end, len(body) + 1):
        line = body[i] if i < len(body) else ""
        if not joined:
            n0 = i + 1
        if line.lstrip().startswith("#") and not joined:
            continue
        if line.endswith("\\") and i < len(body):
            joined += line[:-1] + " "
            continue
        joined += line
        for cat, label, rx in STOP_HINTS:
            m = None if cat in declared else re.search(rx, joined)
            if m:
                probs.append((n0, "looks like stop category `%s`: matched `%s` (`%s`) in: %s; if the act does that, "
                              "declare it (`# Stops: %s`, then only the owner signs)"
                              % (cat, label, m.group(0).strip()[:60], joined.strip()[:80], cat)))
        joined = ""

    # the bytes that were read and hashed, on stdin: never the file again, which may have changed since
    r = subprocess.run([shutil.which("bash"), "-n"], input=s.data, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if r.returncode != 0:
        probs += [(0, "bash -n: " + ln) for ln in r.stdout.decode("utf-8", "replace").splitlines() if ln.strip()] or \
                 [(0, "bash -n failed")]
    sc = shutil.which("shellcheck")
    if sc:
        r = subprocess.run([sc, "-S", "error", "-s", "bash", "-f", "gcc", "-"], input=s.data, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT)
        if r.returncode != 0:
            probs += [(0, "shellcheck: " + ln) for ln in r.stdout.decode("utf-8", "replace").splitlines() if ln.strip()]
    return probs


def print_problems(s, probs):
    for n, p in probs:
        say("FAIL %s%s" % ("line %d: " % n if n else "", p))
    say("check: %d problem%s in %s" % (len(probs), "" if len(probs) == 1 else "s", s.path))


# ── phases ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
def need_bash():
    if not shutil.which("bash"):
        raise Stop(ENV, "no bash on PATH")


def run_phase(s, args, phase, sinks, plan=None):
    """Run one phase on a fresh copy of the hashed bytes; (rc, output lines). Each output line goes to every sink as it comes.
    With `plan` (the signed plan, given to the run phase and its undo) the script gets BATON_PLAN, a file holding it one line per write,
    so it can refuse to do anything else before an act that cannot be undone."""
    tmpd = tempfile.mkdtemp(prefix="baton-")
    try:
        p = os.path.join(tmpd, s.name)
        fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(s.data)
        env = {k: v for k, v in os.environ.items() if k not in SHELL_HOOKS and not k.startswith("BASH_FUNC_")}
        writes = os.path.join(tmpd, "writes")         # write() appends one plan line per write here
        open(writes, "w").close()
        env["BATON_PHASE"] = phase
        RUN["phase"] = phase
        env["BATON_SCRIPT"] = s.real
        env["BATON_WRITES"] = writes
        env.pop("BATON_PLAN", None)                     # only the runner sets it, and only for the run phase and its undo
        if plan is not None:                            # a name of its own: a script may be called `plan`
            pfd, planf = tempfile.mkstemp(prefix="signed-plan-", dir=tmpd)
            with os.fdopen(pfd, "w", encoding="utf-8", errors="surrogateescape") as f:
                f.write("".join(p + "\n" for p in plan))
            env["BATON_PLAN"] = planf
        if s.kit:                                       # the root of the plugin that ships the kit
            env["BATON_PLUGIN_ROOT"] = s.from_kit.root
        elif s.plugin_scripts and phase in ("run", "undo"):    # a session baton: only where write() runs
            env["BATON_PLUGIN_ROOT"] = plugin_real()
        elif s.plugin_scripts:                          # rehearse and post-check expand write()'s words: a root with no scripts
            env["BATON_PLUGIN_ROOT"] = os.path.join(tmpd, "no-plugin-root-in-" + phase)
        else:                                           # never otherwise, not even from the caller
            env.pop("BATON_PLUGIN_ROOT", None)
        if s.plugin_scripts:                            # bytecode of the plugin's Python from a directory of this phase only
            env["PYTHONPYCACHEPREFIX"] = os.path.join(tmpd, "pycache")
        for out in sinks:
            out.write("== %s\n" % phase)
            out.flush()
        proc = subprocess.Popen([shutil.which("bash"), p] + list(args), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, env=env, start_new_session=True)
        lines = []
        try:
            for raw in proc.stdout:
                line = raw.decode("utf-8", "replace").rstrip("\n")
                lines.append(line)
                for out in sinks:
                    out.write(line + "\n")
                    out.flush()
            rc = proc.wait()
        except BaseException:
            stop_group(proc)
            raise
        if s.plugin_scripts and scripts_tree_sha() != s.tree_sha:
            msg = "baton: the plugin's scripts/ changed during the phase (detected after it, not prevented)"
            lines.append(msg)
            for out in sinks:
                out.write(msg + "\n")
                out.flush()
            rc = rc or 70
        with open(writes, "rb") as f:
            return rc, lines, [w.decode("utf-8", "backslashreplace") for w in f.read().split(b"\n")[:-1]]
    finally:
        shutil.rmtree(tmpd, ignore_errors=True)


def stop_group(proc):
    """TERM to the phase's whole process group, then KILL to what is left: a push or a merge the script started must not
    finish unobserved after baton has logged the run as interrupted."""
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except OSError:
        pass
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except OSError:
        pass
    proc.wait()


def verdict_ok(lines, phase):
    """The last non-empty line ends with the verdict (a command's output without a final newline may precede it)."""
    tail = [ln.strip() for ln in lines if ln.strip()]
    return bool(tail) and tail[-1].endswith("VERDICT %s ok" % phase)


def plan_sha(plan):
    return sha256("\n".join(plan))


def rehearse(s, args, sinks):
    """(ok, plan, reasons) of one rehearse phase; the plan-against-Expect table goes to the sinks."""
    rc, lines, plan = run_phase(s, args, "rehearse", sinks)
    expect, reasons = s.expect(), []
    each = s.field("Each") if "Each" in s.fields else None
    if rc != 0:
        reasons.append("the rehearse phase exited %d" % rc)
    if not verdict_ok(lines, "rehearse"):
        reasons.append("no verdict: the last line is not `VERDICT rehearse ok`")
    if each is not None:
        counts = [int(m.group(1)) for m in (PLAN_COUNT.match(ln.strip()) for ln in lines) if m]
        if len(counts) != 1:
            reasons.append("an Each baton prints exactly one PLAN-COUNT line; this rehearse printed %d" % len(counts))
        elif counts[0] < 1 or counts[0] != len(plan):
            reasons.append("the plan has %d line%s, PLAN-COUNT says %d" % (len(plan), "" if len(plan) == 1 else "s", counts[0]))
        expect = [each] * max(len(plan), 1)
    table = ["== plan against Expect"]
    for i in range(max(len(plan), len(expect))):
        p = plan[i] if i < len(plan) else None
        e = expect[i] if i < len(expect) else None
        good = p is not None and e is not None and fnmatch.fnmatchcase(p, e) and (each is None or p != "")
        table.append("  %s %s  ~  %s" % ("ok  " if good else "FAIL", "(none)" if p is None else p, "(none)" if e is None else e))
        if not good and len(reasons) < 10:
            reasons.append("plan line %d %r does not match Expect %r" % (i + 1, p, e))
    if not plan and not expect:
        table.append("  (no plan, no Expect)")
    for name, sha in sorted(s.plugin_scripts.items()):
        if not sha or not any(re.search(r"(?<![0-9a-fA-F])%s(?![0-9a-fA-F])" % sha, p) for p in plan):
            reasons.append("plugin script scripts/%s: its sha256 %s is in no plan line" % (name, sha or "(unreadable)"))
    for out in sinks:
        out.write("\n".join(table) + "\n")
        out.flush()
    return not reasons, plan, reasons


def steering():
    """{name: sha256 prefix of its value, or None when unset} for the STEERING variables."""
    names = set(STEERING) | set(k for k in os.environ if k.startswith(("GIT_CONFIG", "PYTHON")))
    return {k: (sha256(os.environ[k].encode("utf-8", "surrogateescape"))[:16] if k in os.environ else None) for k in sorted(names)}


def binding_of(script_sha, args, cwd, env):
    blob = json.dumps({"v": 1, "script_sha256": script_sha, "args": list(args), "cwd": cwd, "env": env}, sort_keys=True,
                      separators=(",", ":"))
    return sha256(blob)


def seal_of(binding, plan):
    """What rehearse shows and sign must name: the binding and the plan, so the click signs what was shown."""
    return "%s.%s" % (binding[:16], plan_sha(plan)[:16])


# ── state ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
def state_dir():
    x = os.environ.get("XDG_STATE_HOME", "")
    base = x if os.path.isabs(x) else os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(base, "vibemaestro", "baton")


def ensure_state():
    d = state_dir()
    try:
        for sub in ("signatures", "used", "runs"):
            os.makedirs(os.path.join(d, sub), mode=0o700, exist_ok=True)
        os.chmod(d, 0o700)
        if not os.access(d, os.W_OK):
            raise PermissionError(13, "not writable")
    except OSError as e:
        raise Stop(ENV, "the state directory %s cannot be written: %s" % (d, e.strerror or e))
    return d


def write_private(path, text):
    tmp = "%s.tmp%d" % (path, os.getpid())
    try:
        os.unlink(tmp)                                  # a leftover of a crashed run with the same pid
    except OSError:
        pass
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def mode_state():
    """(mode, chosen): chosen is False when there is no mode file, a fresh install where nobody has chosen yet; it reads as manual."""
    try:
        with open(os.path.join(state_dir(), "mode"), encoding="utf-8") as f:
            v = f.read().strip()
    except FileNotFoundError:
        return "manual", False
    except (OSError, ValueError):                                     # unreadable, or not UTF-8: chosen, read as manual
        return "manual", True
    if v not in MODES:
        say("baton: the mode file holds %r: treated as manual" % v, sys.stderr)
        return "manual", True
    return v, True


def read_mode():
    return mode_state()[0]


def log_value(v):
    return re.sub(r"[\x00-\x1f\x7f-\x9f\u2028\u2029]", lambda m: "\\x%02x" % ord(m.group()), v)


def log_event(d, **kw):
    """Append one line to log.tsv; returns it as written."""
    kw.setdefault("time", now_iso())
    vals = []
    for k in LOG_FIELDS:
        v = kw.get(k)
        v = "-" if v is None or v == "" else (json.dumps(v) if isinstance(v, list) else str(v))
        vals.append(log_value(v))
    data = "\t".join(vals).encode("utf-8", "backslashreplace")
    fd = os.open(os.path.join(d, "log.tsv"), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        os.write(fd, data + b"\n")
    finally:
        os.close(fd)
    return data.decode("utf-8")                         # the line as it stands in the file


def mark_started(d, out_path, **common):
    """Before the run's script starts: a `run-start` line in log.tsv and the file runs/LAST naming the run log, so a run that is killed
    (SIGKILL, a tool timeout), which prints nothing, is still found (`log --last`). Best effort: the run log itself is the record."""
    tmp = os.path.join(d, "runs", "LAST.%d" % os.getpid())
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8", errors="backslashreplace") as f:
            f.write(out_path + "\n")
        os.replace(tmp, os.path.join(d, "runs", "LAST"))              # the pointer first: a kill between the two still leaves it
        log_event(d, event="run-start", output=out_path, **common)
    except OSError:
        try:
            os.remove(tmp)
        except OSError:
            pass


def prune_runs(d):
    runs = os.path.join(d, "runs")
    names = sorted(n for n in os.listdir(runs) if n.endswith(".log"))
    for n in names[:-RUNS_KEPT]:
        try:
            os.remove(os.path.join(runs, n))
        except OSError:
            pass


def load_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def pending(d):
    sig = os.path.join(d, "signatures")
    out = []
    for n in sorted(os.listdir(sig)):
        if n.endswith(".json"):
            r = load_json(os.path.join(sig, n))
            if isinstance(r, dict):
                out.append(r)
    return out


def why_unsigned(d, s, args, cwd, env):
    mine = [r for r in pending(d) if r.get("script_path") == s.real]
    if not mine:
        return "no signature for this script: rehearse it, show it, and have it signed"
    same = [r for r in mine if r.get("script_sha256") == s.sha]
    if not same:
        return "the script changed since it was signed (now %s, signed %s)" % (
            s.sha[:12], ", ".join(sorted(set(str(r.get("script_sha256", ""))[:12] for r in mine))))
    if not any(r.get("args") == list(args) for r in same):
        return "the arguments differ from the signed ones (signed: %s)" % "; ".join(json.dumps(r.get("args")) for r in same)
    same = [r for r in same if r.get("args") == list(args)]
    if not any(r.get("cwd") == cwd for r in same):
        return "the directory differs from the one it was signed in (signed: %s)" % ", ".join(str(r.get("cwd")) for r in same)
    moved = sorted(set(k for r in same if r.get("cwd") == cwd for k in set(r.get("env") or {}) | set(env)
                       if (r.get("env") or {}).get(k) != env.get(k)))
    return "the environment differs from the signed one: %s" % (", ".join(moved) or "unknown")


def allowed(signer, mode, stops):
    """None when `signer` may sign or run in `mode`, else the reason."""
    if signer == "owner":
        return None
    if signer != "coordinator-auto":
        return "unknown signer %r" % signer
    if mode != "auto":
        return "the mode is manual: only the owner signs (`baton mode` shows it; the owner sets it)"
    if stops:
        return "the script declares stop categories (%s): only the owner signs it" % ", ".join(stops)
    return None


# ── commands ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────
def kinds():
    try:
        return sorted(f[:-3] for f in os.listdir(KINDS_DIR) if f.endswith(".sh"))
    except OSError:
        return []


def cmd_new(rest):
    name, d, kind, i = None, ".", None, 0
    usage = "usage: baton.py new <name> [--dir D] [--from <kind>]  (kinds: %s)" % ", ".join(kinds())
    while i < len(rest):
        if rest[i] in ("--dir", "--from") and i + 1 < len(rest) and not rest[i + 1].startswith("-"):
            if rest[i] == "--dir":
                d = rest[i + 1]
            else:
                kind = rest[i + 1]
            i += 2
        elif rest[i].startswith("--dir="):
            d, i = rest[i][len("--dir="):], i + 1
        elif rest[i].startswith("--from="):
            kind, i = rest[i][len("--from="):], i + 1
        elif name is None and not rest[i].startswith("-"):
            name, i = rest[i], i + 1
        else:
            raise Stop(USAGE, usage)
    if not name or not NAME_RE.match(name):
        raise Stop(USAGE, "the name is lower-case letters, digits and hyphens: [a-z0-9][a-z0-9-]*")
    if not os.path.isdir(d):
        raise Stop(USAGE, "--dir %s is not a directory" % d)
    template = TEMPLATE
    if kind is not None:
        path = os.path.join(KINDS_DIR, kind + ".sh")
        if not KIND_RE.match(kind) or not os.path.isfile(path):
            raise Stop(USAGE, "--from %s: no such kind; the kinds are %s" % (kind, ", ".join(kinds()) or "(none)"))
        template = path
    try:
        with open(template, encoding="utf-8") as f:
            text = f.read().replace("__NAME__", name)
    except OSError as e:
        raise Stop(ENV, "the template %s cannot be read: %s" % (template, e.strerror or e))
    path = os.path.join(d, name + ".sh")
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    except FileExistsError:
        raise Stop(EXISTS, "%s already exists; nothing written" % path)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    say("written %s: edit the header and the act, then `baton.py check %s`" % (path, path))
    return OK


def checked(path):
    """The script at path once it passes check; otherwise its problems are printed and Stop(BAD_SCRIPT) is raised."""
    s = Script(path)
    need_bash()
    probs = check_script(s)
    if probs:
        print_problems(s, probs)
        raise Stop(BAD_SCRIPT, "check failed: fix the script, then check again")
    return s


def cmd_check(rest):
    if len(rest) != 1:
        raise Stop(USAGE, "usage: baton.py check <script>")
    s = checked(rest[0])
    say("check ok: %s (sha256 %s)" % (s.path, s.sha[:12]))
    return OK


def header_summary(s, out):
    say("baton script %s (sha256 %s)%s" % (s.path, s.sha[:12], " from %s" % log_value(s.from_kit.pid) if s.kit and s.from_kit.pid else ""),
        out)
    for key in HEADER_FIELDS[:-1]:
        if key != "Each" or key in s.fields:
            say("  %-8s %s" % (key + ":", s.field(key)), out)


def script_and_args(rest, usage):
    if rest and rest[0] == "--":
        rest = rest[1:]
    if not rest:
        raise Stop(USAGE, usage)
    return rest[0], list(rest[1:])


def rehearsed(s, args, out):
    """The body of `rehearse` once check passed: the header, the rehearse phase, the plan against Expect, the seal; all to `out`.
    (plan, reasons, seal): seal is None when the rehearse failed."""
    header_summary(s, out)
    good, plan, reasons = rehearse(s, args, [out])
    if not good:
        for r in reasons:
            say("FAIL " + r, out)
        say("rehearse FAILED: fix the script or its Expect, then rehearse again", out)
        return plan, reasons, None
    cwd, env = os.path.realpath(os.getcwd()), steering()
    seal = seal_of(binding_of(s.bind_sha, args, cwd, env), plan)
    say("seal %s (binding of script sha256 %s, %d argument%s, directory %s and environment; then the plan)"
        % (seal, s.sha[:12], len(args), "" if len(args) == 1 else "s", cwd), out)
    return plan, reasons, seal


def owner_commands(path, args, seal):
    words = " ".join(shlex.quote(a) for a in (["--"] if path.startswith("-") else []) + [path] + args)
    return "%s sign --by owner --seal %s %s" % (entry_command(), seal, words), "%s run %s" % (entry_command(), words)


def cmd_rehearse(rest):
    path, args = script_and_args(rest, "usage: baton.py rehearse <script> [args...]")
    s = checked(path)
    _plan, _r, seal = rehearsed(s, args, sys.stdout)
    if seal is None:
        return BAD_SCRIPT
    say("rehearse ok. After the owner's go: %s" % owner_commands(path, args, seal)[0])
    return OK


def cmd_sign(rest):
    seal, usage = None, "usage: baton.py sign --by owner|coordinator-auto --seal <seal> <script> [args...]"
    # One spelling only: `--by <signer>` first, once, two words. The owner's permission rules match the command text, so an
    # allow on `sign --by coordinator-auto` must not admit `sign --by coordinator-auto --by owner` (or `--by=owner`) as owner.
    if len(rest) < 2 or rest[0] != "--by" or rest[1] not in SIGNERS:
        raise Stop(USAGE, "%s (--by <signer> comes first, once: who approves is never a default)" % usage)
    by, rest = rest[1], rest[2:]
    while rest and rest[0].startswith("--") and rest[0] != "--":
        if rest[0] == "--seal" and len(rest) > 1 and seal is None:
            seal, rest = rest[1], rest[2:]
        elif rest[0].startswith("--seal=") and seal is None:
            seal, rest = rest[0][len("--seal="):], rest[1:]
        else:
            raise Stop(USAGE, "%s (--by once, first; --seal once)" % usage)
    if not seal:
        raise Stop(USAGE, "%s (--seal is the one rehearse printed: the signature names what was shown)" % usage)
    path, args = script_and_args(rest, usage)
    return signed(by, seal, path, args, sys.stdout)


def signed(by, seal, path, args, out):
    """The body of `sign` once its options are read: check, mode policy, rehearse, the seal shown, then the signature record."""
    s = checked(path)
    d = ensure_state()
    mode, cwd, env = read_mode(), os.path.realpath(os.getcwd()), steering()
    binding = binding_of(s.bind_sha, args, cwd, env)
    stops, _u = s.stops()
    why = allowed(by, mode, stops)
    common = dict(name=s.name, script=s.sha[:12], binding=binding[:12], args=args, dir=cwd, signed_by=by, mode=mode)
    if why:
        log_event(d, event="sign", result="refused", **common)
        raise Stop(REFUSED, "sign refused: " + why)
    header_summary(s, out)
    good, plan, reasons = rehearse(s, args, [out])
    if not good:
        for r in reasons:
            say("FAIL " + r, out)
        log_event(d, event="sign", result="rehearse-failed", **common)
        say("sign: rehearse FAILED, nothing signed", out)
        return BAD_SCRIPT
    if seal_of(binding, plan) != seal:
        log_event(d, event="sign", result="refused", **common)
        raise Stop(REFUSED, "sign refused: the seal now is %s, not the %s that was shown; the script, its arguments, its "
                            "directory, its environment or its plan changed: rehearse and show it again"
                   % (seal_of(binding, plan), seal))
    rec = {"v": 1, "binding": binding, "script_path": s.real, "script_sha256": s.sha, "args": args, "cwd": cwd, "env": env,
           "plan_sha256": plan_sha(plan), "plan": plan, "stops": stops, "signed_by": by, "mode": mode, "time": now_iso()}
    text = json.dumps(rec, indent=1, sort_keys=True) + "\n"
    RUN["signed"] = (d, os.path.join(d, "signatures", binding + ".json"), common, text)    # before the write: go may withdraw it
    write_private(RUN["signed"][1], text)
    log_event(d, event="sign", result="signed", **common)
    say("signed %s by %s (mode %s): binding %s, %d planned write%s; one run, from %s"
        % (s.name, by, mode, binding[:12], len(plan), "" if len(plan) == 1 else "s", cwd), out)
    return OK


def postcheck_waits(sinks=None):
    """The waits between post-check attempts: POSTCHECK_WAITS, or BATON_POSTCHECK_WAITS when it only shortens them (no more
    waits, none longer than the default at its place; empty means one attempt). Anything else is ignored, with a line to the
    sinks (stderr without them): go keeps it in its run log, not as a second line."""
    raw = os.environ.get("BATON_POSTCHECK_WAITS")
    if raw is None:
        return POSTCHECK_WAITS
    try:
        waits = tuple(float(w) for w in raw.split())
    except ValueError:
        waits = None
    if waits is None or len(waits) > len(POSTCHECK_WAITS) or any(not 0 <= w <= d for w, d in zip(waits, POSTCHECK_WAITS)):
        for out in sinks or [sys.stderr]:
            say("baton: BATON_POSTCHECK_WAITS=%r may only shorten %s: ignored" % (raw, " ".join(map(str, POSTCHECK_WAITS))), out)
        return POSTCHECK_WAITS
    return waits


def postchecked(s, args, sinks):
    """The post-check phase, read again after each wait while it fails (it cannot write: write() refuses in that phase)."""
    waits = postcheck_waits(sinks)
    for k in range(len(waits) + 1):
        rc, lines, _w = run_phase(s, args, "postcheck", sinks)
        if rc == 0 and verdict_ok(lines, "postcheck"):
            return True
        if k < len(waits):
            try:                                          # the line too: a signal right after it is still in the wait
                for out in sinks:
                    say("== post-check attempt %d of %d failed; reading again in %g s" % (k + 1, len(waits) + 1, waits[k]), out)
                time.sleep(waits[k])
            except (KeyboardInterrupt, Interrupted):           # the failure is known: undo, rather than "state unknown"
                for out in sinks:
                    say("== interrupted while waiting to read again: the post-check stands as failed", out)
                return False
    return False


def cmd_run(rest):
    """One line when the run holds, like go: the run log keeps the whole output; any other outcome prints it all."""
    path, args = script_and_args(rest, "usage: baton.py run <script> [args...]")
    held = Held()
    try:
        rc, result, _line, out_path = signed_run(path, args, quiet=held)
    except BaseException:
        sys.stdout.write(held.text())
        raise
    if rc == OK and result == "ok":
        n = RUN.get("writes", 0)
        say("run: ok — %d write%s — %s" % (n, "" if n == 1 else "s", out_path))
        return OK
    sys.stdout.write(held.text())
    say("full output: " + out_path)
    return rc


def signed_run(path, args, quiet=None, preamble=""):
    """The body of `run`: (exit code, result, the log line it wrote, the run log's path). The result is the log line's: ok,
    run-failed, run-diverged, postcheck-failed, interrupted or error; a refusal raises Stop(REFUSED). With `quiet` (go), the
    output goes to that sink and the run log instead of stdout, and the run log starts with `preamble` (go's earlier steps)."""
    s = Script(path)
    need_bash()
    d = ensure_state()
    mode, cwd, env = read_mode(), os.path.realpath(os.getcwd()), steering()
    binding = binding_of(s.bind_sha, args, cwd, env)
    common = dict(name=s.name, script=s.sha[:12], binding=binding[:12], args=args, dir=cwd, mode=mode)

    def refuse(why, signer=None, output=None, result="refused"):
        log_event(d, event="run", result=result, signed_by=signer, output=output, **common)
        raise Stop(REFUSED, "run refused, nothing ran: " + why)

    sig = os.path.join(d, "signatures", binding + ".json")
    rec = load_json(sig) if os.path.exists(sig) else None
    if rec is None:
        refuse(why_unsigned(d, s, args, cwd, env) if not os.path.exists(sig) else "the signature record cannot be read")
    if not isinstance(rec, dict) or (rec.get("binding"), rec.get("script_sha256"), rec.get("args"), rec.get("cwd"),
                                     rec.get("env")) != (binding, s.sha, args, cwd, env):
        refuse("the signature record does not match the script, its arguments, its directory and its environment")
    signer = rec.get("signed_by")
    stops, _u = s.stops()
    why = allowed(signer, mode, stops)
    if why:
        refuse("signed by %s, but %s" % (signer, why), signer)
    probs = check_script(s)
    if probs:
        print_problems(s, probs)
        refuse("the script no longer passes check", signer)

    stamp = "%s-%d" % (time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()), os.getpid())     # unique per run
    out_path = os.path.join(d, "runs", "%s-%s-%s.log" % (stamp, os.path.splitext(s.name)[0], binding[:12]))
    fd = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8", errors="backslashreplace") as logf:
        mark_started(d, out_path, signed_by=signer, **common)
        if preamble:
            logf.write(preamble + "== go: run\n")
        sinks = [sys.stdout if quiet is None else quiet, logf]
        for out in sinks:
            header_summary(s, out)
            say("signed by %s at %s; mode %s; binding %s" % (signer, rec.get("time"), mode, binding[:12]), out)
        result, undone, consumed = None, None, False
        try:
            good, plan, reasons = rehearse(s, args, sinks)
            if not good:
                for r in reasons:
                    say("FAIL " + r, logf)
                refuse("the rehearse before the run failed: " + "; ".join(reasons), signer, out_path)
            RUN["writes"] = len(plan)
            if plan_sha(plan) != rec.get("plan_sha256"):
                for out in sinks:
                    say("== the signed plan\n" + "\n".join("  " + p for p in rec.get("plan") or []), out)
                refuse("the plan changed since signing (the world moved): rehearse and sign again", signer, out_path)
            try:
                os.rename(sig, os.path.join(d, "used", "%s-%s.json" % (stamp, binding)))
                consumed = RUN["consumed"] = True
            except OSError:
                refuse("the signature was used meanwhile", signer, out_path)
            rc, lines, done = run_phase(s, args, "run", sinks, plan=rec.get("plan") or [])
            if rc != 0 or not verdict_ok(lines, "run"):
                result = "run-failed"
            elif done != plan:
                for out in sinks:
                    say("== the run did other writes than the signed plan:\n" + "\n".join("  DO " + x for x in done), out)
                result = "run-diverged"
            else:
                result = "ok" if postchecked(s, args, sinks) else "postcheck-failed"
            if result != "ok":
                rc, lines, _w = run_phase(s, args, "undo", sinks, plan=rec.get("plan") or [])
                undone = "yes" if rc == 0 and verdict_ok(lines, "undo") else "failed"
        except Stop:
            raise
        except (KeyboardInterrupt, Interrupted, Exception) as e:
            what = "interrupted" if isinstance(e, (KeyboardInterrupt, Interrupted)) else "error"
            if not consumed:
                refuse("%s before the run phase (%s); the signature is still unused" % (what, type(e).__name__), signer,
                       out_path, result=what + "-before-run")
            say("baton: %s during the run (%s: %s)" % (what, type(e).__name__, e), logf)
            result, undone = what, "no"
        finally:
            for sig in (signal.SIGTERM, signal.SIGHUP):  # the run is over: let the log line and the report through
                signal.signal(sig, signal.SIG_IGN)
        logged = log_event(d, event="run", signed_by=signer, result=result, undone=undone, output=out_path, **common)
        if result == "ok":
            msg = "run ok: %s did what it planned and the post-check holds" % s.name
        elif undone == "yes":
            msg = "run FAILED (%s); undo put the state back" % result
        elif undone == "failed":
            msg = "run FAILED (%s) and undo FAILED: the state is unknown, tell the owner" % result
        else:
            msg = "run %s: the state is unknown, tell the owner" % result.upper()
        for out in sinks:
            say("== " + msg, out)
        if quiet is None:
            say("full output: " + out_path)
    prune_runs(d)
    return (OK if result == "ok" else UNDONE if undone == "yes" else UNKNOWN), result, logged, out_path


class Held:
    """A sink that keeps what it is given, for output printed later (the decision card comes before the rehearse output)."""

    def __init__(self):
        self.parts = []

    def write(self, text):
        self.parts.append(text)

    def flush(self):
        pass

    def text(self):
        return "".join(self.parts)


def mode_question():
    """The card lines of a mode nobody chose yet: ask the owner once. Who then runs `mode` depends on the ask rules: only when
    the check of `permissions --check` is clean on the user and managed settings alone does the session's `mode` call open the
    owner's dialog (a project's settings are found from CLAUDE_PROJECT_DIR or go's directory, which may not be the session's
    project); otherwise, or when a settings file cannot be parsed, the owner runs it."""
    cmd = "%s mode <answer>" % entry_command()
    try:
        found = perm_findings([src for src in settings_sources() if src[0] in ("managed", "user")])
    except (TypeError, ValueError, AttributeError, RecursionError):   # a malformed settings file promises no dialog
        found = True
    if found:
        how = "the baton rules are not in force in the user or managed settings: the owner runs `! %s` themselves" % cmd
    else:
        how = "on the owner's answer the session runs `%s`; the ask rule opens the owner's dialog" % cmd
    return ["  Stop:     mode manual (not chosen yet): ask the owner once which mode; auto is recommended on a solo machine"
            " (help modes)", "  Mode:     " + how]


def decision_card(s, plan, stops, mode, chosen=True, question=None):
    """The lines a human decides from when a baton needs the owner: what, where, why, blast, undo, the stop, what was checked.
    Every plan line is on it, and control characters are escaped as in the log: a script cannot redraw the card."""
    n, f = len(plan), lambda key: log_value(s.field(key))
    lines = ["== OWNER DECISION: %s%s needs the owner's signature; nothing was signed, nothing ran"
             % (log_value(s.name), " (a kit of %s)" % log_value(s.from_kit.pid) if s.kit and s.from_kit.pid else ""),
             "  What:     %d write%s to %s" % (n, "" if n == 1 else "s", f("Targets") or "(no Targets)")]
    lines += ["              %d. %s" % (i + 1, log_value(p)) for i, p in enumerate(plan)]
    lines += ["  Why:      %s" % f("Purpose"), "  Blast:    %s" % f("Blast"), "  Undo:     %s" % f("Undo")]
    if stops:
        lines.append("  Stop:     %s (a stop-list item: only the owner signs)" % ", ".join(stops))
    if question:
        lines += question
    elif mode == "manual" and chosen:
        lines.append("  Stop:     mode manual: the owner signs every baton")
    lines.append("  Checked:  check ok; rehearse ok; plan matches Expect (%d of %d line%s); %d write%s"
                 % (n, n, "" if n == 1 else "s", n, "" if n == 1 else "s"))
    return lines


def staleness(mtime):
    """None when a file last modified at `mtime` was written for this call (FRESH_SECONDS), else why not."""
    age = time.time() - mtime
    if age > FRESH_SECONDS:
        return "was last written %d s ago, before this call (go runs a file written in the last %d s)" % (age, FRESH_SECONDS)
    if age < -FUTURE_SLACK:
        return "is dated %d s in the future" % -age
    return None


def stale_input(s, args):
    """(what, path, why, sha256, Purpose) of the file go would run from older bytes, else None: the script of a session baton,
    the input file of a kit baton in KIT_INPUTS or of a kind in KIND_INPUTS. Plugin files (kit:, kind:) are old by nature and
    exempt; install-file's source is often an existing file, so it is not looked at."""
    if not s.kit and s.kind is None:
        why = staleness(s.mtime)
        return ("the script", s.path, why, s.sha, s.field("Purpose")) if why else None
    p, what = None, None
    flag = KIT_INPUTS.get(os.path.splitext(s.name)[0]) if s.kit and s.from_kit.pid is None else None   # sdlc's kits
    if flag and flag in args[:-1]:
        p, what = args[args.index(flag) + 1], "the %s file" % flag
    elif s.kind in KIND_INPUTS and len(args) > KIND_INPUTS[s.kind]:
        p, what = args[KIND_INPUTS[s.kind]], "the input file"
    if p is not None:
        try:
            with open(p, "rb") as f:
                data, mtime = f.read(), os.fstat(f.fileno()).st_mtime
        except OSError:
            return None                                 # the baton's own rehearse names a file it cannot read
        why = staleness(mtime)
        return (what, p, why, sha256(data), None) if why else None
    return None


def stdin_script():
    """The path `go -` runs: stdin's bytes written once to <state>/stdin/<stamp>-<sha12>.sh, mode 0400, O_EXCL, never followed
    through a link. The state directory is Edit-denied by the permission rules, so the stored bytes stay what was sent; the sha256
    binding of every later phase refuses them if they change anyway."""
    stream = getattr(sys.stdin, "buffer", None)
    if stream is None or sys.stdin.isatty():
        raise Stop(USAGE, "go -: stdin is not a script (a terminal, or closed): stdin feeds a script only through a heredoc, "
                          "which Claude Code blocks for a baton skeleton: write the baton to a fresh path and run `go <path>`")
    data = stream.read(STDIN_MAX + 1)
    if len(data) > STDIN_MAX:
        raise Stop(USAGE, "go -: stdin holds more than %d bytes; a baton is a few KiB" % STDIN_MAX)
    if not data.strip():
        raise Stop(USAGE, "go -: stdin is empty")
    d = os.path.join(ensure_state(), "stdin")
    try:
        os.makedirs(d, mode=0o700, exist_ok=True)
        os.chmod(d, 0o700)
        stamp = "%s-%d" % (time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()), os.getpid())
        path = os.path.join(d, "%s-%s.sh" % (stamp, sha256(data)[:12]))
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o400)
        with os.fdopen(fd, "wb") as f:
            f.write(data)
    except OSError as e:
        raise Stop(ENV, "go -: the script cannot be stored under %s: %s" % (d, e.strerror or e))
    names = sorted(n for n in os.listdir(d) if n.endswith(".sh"))
    hard = len(names) - STDIN_HARD
    for i, n in enumerate(names[:-STDIN_KEPT]):
        try:
            if i < hard or time.time() - os.lstat(os.path.join(d, n)).st_mtime > STDIN_KEEP_DAYS * 86400:
                os.remove(os.path.join(d, n))
        except OSError:
            pass
    return path


def go_command(by, path, args):
    words = " ".join(shlex.quote(a) for a in (["--"] if path.startswith("-") else []) + [path] + args)
    return "%s go %s--reuse %s" % (entry_command(), "--by coordinator-auto " if by else "", words)


def cmd_go(rest):
    """rehearse, sign --by coordinator-auto and run in one process: the same functions in turn, so the same checks. A baton the
    session may not sign stops after rehearse with the owner's decision card and exit 8; `go` never signs as owner. When every
    step holds it prints one line; a failing step prints its whole output."""
    usage = ("usage: baton.py go [--by coordinator-auto] [--reuse] <script|-> [args...]  (- reads the script from stdin; the owner "
             "signs with `sign --by owner`)")
    by = reuse = False
    if rest and (rest[0] == "--by" or rest[0].startswith("--by=")):
        if rest[0] != "--by" or len(rest) < 2 or rest[1] != "coordinator-auto":
            raise Stop(USAGE, "%s: go signs only as coordinator-auto" % usage)
        by, rest = True, rest[2:]
    if rest and rest[0] == "--reuse":
        reuse, rest = True, rest[1:]
    if rest and rest[0].startswith("-") and rest[0] not in ("--", "-"):
        raise Stop(USAGE, "%s (--by once, first; then --reuse once; no other option: the seal is go's own rehearse)" % usage)
    path, args = script_and_args(rest, usage)
    if path == "-" and reuse:
        raise Stop(USAGE, "%s (--reuse runs a file again; a script from stdin is fresh by construction)" % usage)
    step, held = "check", Held()
    try:
        if path == "-":
            path = stdin_script()
        s = Script(path)
        stale = None if reuse else stale_input(s, args)
        if stale:
            what, p, why, sha, purpose = stale
            say("go: refused, nothing ran: %s %s %s." % (what, log_value(p), why))
            say("  sha256 %s%s" % (sha, "; Purpose: %s" % log_value(purpose) if purpose is not None else ""))
            say("  A Write of it in this response that did not land leaves these older bytes: write a fresh path, then go.")
            say("  To run these very bytes again, after reading the sha256 and Purpose above: %s" % go_command(by, path, args))
            return BAD_SCRIPT
        need_bash()
        probs = check_script(s)
        if probs:
            print_problems(s, probs)
            raise Stop(BAD_SCRIPT, "check failed: fix the script, then check again")
        say("go: check ok", held)                      # held: printed only when a step fails; else the run log keeps it
        step = "rehearse"
        try:
            plan, reasons, seal = rehearsed(s, args, held)
        except BaseException:
            sys.stdout.write(held.text())                # an interrupt keeps what the rehearse printed so far
            raise
        if seal is None:
            sys.stdout.write(held.text())
            if all(r.startswith("plan line") or "PLAN-COUNT" in r for r in reasons):
                step = "plan-vs-Expect"
            say("go: stopped at %s (exit %d): %s" % (step, BAD_SCRIPT, "; ".join(reasons)))
            return BAD_SCRIPT
        stops, _u = s.stops()
        mode, chosen = mode_state()
        why = allowed("coordinator-auto", mode, stops)
        if why:
            d = ensure_state()
            stamp = "%s-%d" % (time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()), os.getpid())
            detail = os.path.join(d, "runs", "%s-%s-owner.log" % (stamp, os.path.splitext(s.name)[0]))
            fd = os.open(detail, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8", errors="backslashreplace") as f:
                f.write(held.text())
            question = mode_question() if mode == "manual" and not chosen and not stops else None   # a Stops: none baton waits on it
            for ln in decision_card(s, plan, stops, mode, chosen, question):
                say(ln)
            say("detail: %s (check and rehearse output)" % detail)
            sign_cmd, run_cmd = owner_commands(path, args, seal)
            say("script: %s" % log_value(s.real))
            say("on the owner's go: %s" % sign_cmd)
            say("then:              %s" % run_cmd)
            say("go: stopped after rehearse (exit %d, waiting for the owner): %s" % (OWNER, why))
            return OWNER
        say("go: rehearse ok", held)
        say("go: plan-vs-Expect ok (%d of %d line%s)" % (len(plan), len(plan), "" if len(plan) == 1 else "s"), held)
        say("go: seal %s" % seal, held)
        if reuse:
            log_event(ensure_state(), event="go", result="reuse", name=s.name, script=s.sha[:12], args=args,
                      dir=os.path.realpath(os.getcwd()), mode=mode)
        step, sheld = "sign", Held()
        try:
            rc = signed("coordinator-auto", seal, path, args, sheld)
        except BaseException:
            sys.stdout.write(sheld.text())
            raise
        if rc != OK:
            sys.stdout.write(sheld.text())
            say("go: stopped at sign (exit %d): the rehearse at signing failed" % rc)
            return rc
        held.write(sheld.text())
        say("go: sign ok", held)
        step, rheld = "run", Held()
        try:
            rc, result, _line, out_path = signed_run(path, args, quiet=rheld, preamble=held.text())
        except Stop:
            sys.stdout.write(rheld.text())
            withdraw()
            raise
        except BaseException:
            sys.stdout.write(rheld.text())
            raise
        if rc != OK or result != "ok":
            sys.stdout.write(rheld.text())
            say("full output: " + out_path)
            at_check = result == "postcheck-failed" or (result in ("interrupted", "error") and RUN.get("phase") == "postcheck")
            say("go: stopped at %s (exit %d): %s" % ("post-check" if at_check else "run", rc, result))
            return rc if rc != OK else UNKNOWN
        step = "log"
        say("go: ok — %d write%s — %s" % (len(plan), "" if len(plan) == 1 else "s", out_path))
        return OK
    except Stop as e:
        say("go: stopped at %s (exit %d): %s" % (step, e.rc, e))
        raise
    except BaseException as e:
        say("go: stopped at %s: %s" % (step, type(e).__name__))
        if step in ("sign", "run"):                     # an interrupt between the signature and the run's own guard
            withdraw()
        raise


def withdraw():
    """A signature go made that its run refused before using it: removed (and logged), so a later plain `run`, which the
    permission rules allow, cannot use a signature the session no longer looks at."""
    d, sig, common, text = RUN.get("signed") or (None, None, None, None)
    if RUN["consumed"] or not sig:
        return
    try:
        with open(sig, encoding="utf-8") as f:
            if f.read() != text:                         # not the record go wrote (another signer replaced it): leave it
                return
        os.unlink(sig)
        log_event(d, event="sign", result="withdrawn", **common)
        say("go: the signature it made was withdrawn (nothing ran)")
    except OSError:
        pass


def cmd_log(rest):
    if rest[:1] == ["--wait-names"]:
        return log_wait(rest[1:])
    n = 20
    if rest == ["--last"]:
        try:
            with open(os.path.join(state_dir(), "runs", "LAST"), encoding="utf-8", errors="backslashreplace") as f:
                last = f.read().strip()
        except OSError:
            last = ""
        if not last:
            raise Stop(NOINPUT, "no run has started yet: runs/LAST does not exist")
        say(last)
        return OK
    if rest:
        if len(rest) == 2 and rest[0] == "--tail" and re.match(r"^[1-9]\d*$", rest[1]):
            n = int(rest[1])
        else:
            raise Stop(USAGE, "usage: baton.py log [--tail N]  (N >= 1), or log --last, or log --wait-names N1,N2,... [--timeout S] [--since T]")
    try:
        with open(os.path.join(state_dir(), "log.tsv"), encoding="utf-8", errors="backslashreplace", newline="") as f:
            lines = f.read().split("\n")[:-1]
    except OSError:
        lines = []
    for ln in lines[-n:]:
        say(ln)
    return OK


def iso_seconds(v):
    """Seconds since the epoch of a log time (YYYY-MM-DDTHH:MM:SSZ, UTC), or None."""
    try:
        return calendar.timegm(time.strptime(v, "%Y-%m-%dT%H:%M:%SZ"))
    except (ValueError, OverflowError):
        return None


def log_wait(rest):
    """log --wait-names: wait until the latest `run` line of each named script, among those written at or after --since, is ok."""
    usage = ("usage: baton.py log --wait-names N1,N2,... [--timeout S] [--since YYYY-MM-DDTHH:MM:SSZ]  (S 1-%d, default %d; "
             "--since defaults to the wait's start minus %d s)" % (WAIT_MAX, WAIT_MAX, WAIT_LOOKBACK))
    if not rest or rest[0].startswith("-"):
        raise Stop(USAGE, usage)
    names = [x for x in rest[0].split(",") if x]
    if not names or len(names) != len(rest[0].split(",")):
        raise Stop(USAGE, usage + " (names are comma-separated, none empty)")
    timeout, since, opts = WAIT_MAX, None, rest[1:]
    seen = set()
    while opts:
        if len(opts) < 2 or opts[0] not in ("--timeout", "--since") or opts[0] in seen:
            raise Stop(USAGE, usage)
        seen.add(opts[0])
        if opts[0] == "--timeout":
            if not re.match(r"^[1-9]\d{0,2}$", opts[1]) or int(opts[1]) > WAIT_MAX:
                raise Stop(USAGE, "%s (--timeout %s)" % (usage, opts[1]))
            timeout = int(opts[1])
        else:
            since = iso_seconds(opts[1])
            if since is None:
                raise Stop(USAGE, "%s (--since %s)" % (usage, opts[1]))
        opts = opts[2:]
    start = time.time()
    since = start - WAIT_LOOKBACK if since is None else since
    since_txt = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(since))
    deadline, path = start + timeout, os.path.join(state_dir(), "log.tsv")
    try:
        while True:
            oks, last, older = {}, {}, 0
            try:
                with open(path, encoding="utf-8", errors="backslashreplace", newline="") as f:
                    lines = f.read().split("\n")[:-1]
            except OSError:
                lines = []
            for ln in lines:
                v = ln.split("\t")
                if len(v) != len(LOG_FIELDS) or v[1] != "run" or v[2] not in names:
                    continue
                t = iso_seconds(v[0])
                if t is None or t < since:
                    older += 1
                    continue
                last[v[2]] = v[9]                       # the latest run line decides: a failed re-run after an ok is not ok
                if v[9] == "ok":
                    oks[v[2]] = ln
                else:
                    oks.pop(v[2], None)
            if len(oks) == len(set(names)) or time.time() >= deadline:
                break
            time.sleep(min(WAIT_POLL, max(0.0, deadline - time.time())))
    except (KeyboardInterrupt, Interrupted):
        say("wait: interrupted")
    for n in dict.fromkeys(names):
        if n in oks:
            say(oks[n])
    note = " (%d run line%s before --since ignored)" % (older, "" if older == 1 else "s") if older else ""
    want = list(dict.fromkeys(names))
    if len(oks) == len(want):
        say("wait: ok — %d of %d named scripts ran ok since %s%s" % (len(oks), len(want), since_txt, note))
        return OK
    for n in want:
        if n not in oks:
            say("wait: %s: %s" % (n, "last run %s" % last[n] if n in last else "no run line since %s" % since_txt))
    say("wait: not met after %d s — %d of %d named scripts ran ok%s" % (timeout, len(oks), len(want), note))
    return WAIT_UNMET

def cmd_mode(rest):
    if not rest:
        say(read_mode())
        return OK
    if len(rest) != 1 or rest[0] not in MODES:
        raise Stop(USAGE, "usage: baton.py mode [manual|auto]")
    old = read_mode()
    d = ensure_state()
    try:
        write_private(os.path.join(d, "mode"), rest[0] + "\n")
    except OSError as e:
        raise Stop(ENV, "the mode cannot be written: %s" % (e.strerror or e))
    log_event(d, event="mode", mode=rest[0], result="%s->%s" % (old, rest[0]))
    say("mode %s (was %s)" % (rest[0], old))
    return OK

# ── permissions: the owner's Claude Code rules for baton (printed and checked, never written) ──────────────────────────────────
# Claude Code (2.1.x) decides a Bash call by its rules: deny, then ask, then allow, the first match wins, in every settings scope
# combined. A rule ending in `:*` is a literal prefix (the command, or the command and a space); another rule with an unescaped
# `*` is a wildcard where `*` is any text, `/` and spaces included; any other rule is the exact command. The rules name the
# launcher, a fixed path no upgrade moves.
ALLOWED_SUBS = (("new", "act"), ("check", "act.sh"), ("rehearse", "act.sh"), ("run", "act.sh"), ("go", "act.sh"),
                ("log", "--tail 5"))
SEAL_PROBE = "--seal 0123456789abcdef.0123456789abcdef act.sh"
RULE_RE = re.compile(r"^\s*([A-Za-z0-9_]+)\s*(?:\((.*)\))?\s*$", re.S)
# a version directory of the sdlc cache, as Claude Code names it: X.Y.Z, X.Y.Z-<12 hex> (a tag-resolved dependency), <12 hex> (a git
# marketplace whose plugin carries no version), <12 hex>-<8 hex> (a git-subdir plugin source) or unknown (a directory marketplace
# without git)
VERSIONED = re.compile(r"/vibemaestro-sdlc/(\d+\.\d+\.\d+(?:-[0-9a-f]{12})?|[0-9a-f]{12}(?:-[0-9a-f]{8})?|unknown)/")
# The kit's machines commit without Claude Code's attribution (the owner's setup). The object form: old Claude Code versions
# reject a boolean `attribution`.
ATTRIBUTION_OFF = {"commit": "", "pr": "", "sessionUrl": False}


def claude_config_dir():
    c = os.environ.get("CLAUDE_CONFIG_DIR", "")
    return c if os.path.isabs(c) else os.path.join(os.path.expanduser("~"), ".claude")


def launcher_path():
    return os.path.join(state_dir(), "bin", "baton")


def launcher_text():
    """The launcher for this machine: the plugin's copy with its Claude Code directory and state base written in, so no
    variable can point the installed launcher at other files."""
    with open(LAUNCHER, encoding="utf-8") as f:
        text = f.read()
    for name, value in (("CLAUDE_DIR", claude_config_dir()), ("STATE_HOME", os.path.dirname(os.path.dirname(state_dir())))):
        line = "%s = None    # set by --install-launcher" % name
        if text.count(line) != 1:
            raise Stop(ENV, "the plugin's launcher has no line %r" % line)
        text = text.replace(line, "%s = %r" % (name, value))
    return text


def launcher_current():
    """True when the installed launcher holds this machine's rendering of this version's launcher."""
    try:
        with open(launcher_path(), encoding="utf-8") as f:
            return f.read() == launcher_text()
    except (OSError, ValueError, Stop):
        return False


def tilde_launcher():
    """The launcher spelled from `~/` when it lies under HOME and needs no quoting, else None. The rules match the command text,
    and `~/…/bin/baton run …` is another text for the same command: a call through `~` matched no rule."""
    home = os.path.expanduser("~")
    if not os.path.isabs(home):
        return None
    rel = os.path.relpath(launcher_path(), home)
    if rel == ".." or rel.startswith("../") or shlex.quote(rel) != rel:
        return None
    return "~/" + rel


def entry_command():
    """The command to print in hints: the launcher when it is installed, else this baton.py."""
    return shlex.quote(launcher_path()) if launcher_current() else "python3 " + shlex.quote(os.path.abspath(__file__))


def snippet():
    L, plugins, st = shlex.quote(launcher_path()), os.path.join(claude_config_dir(), "plugins"), state_dir()
    allow = ["Bash(%s %s:*)" % (L, sub) for sub, _a in ALLOWED_SUBS] + ["Bash(%s sign --by coordinator-auto:*)" % L]
    T = tilde_launcher()
    if T:                                               # the same commands spelled from ~/; the asks below catch that spelling too
        allow += ["Bash(%s %s:*)" % (T, sub) for sub, _a in ALLOWED_SUBS] + ["Bash(%s sign --by coordinator-auto:*)" % T]
    # the launcher, then any other spelling: a quoted path too ("…/baton.py" sign …); `mode` names the program right before it,
    # so a commit message or a `run … mode fast` argument stays out
    ask = ["Bash(%s sign --by owner:*)" % L, "Bash(%s mode:*)" % L, "Bash(*baton* sign --by owner*)", "Bash(baton mode:*)"] + [
        "Bash(*%s%s mode *)" % (prog, q) for prog in ("baton.py", "/baton") for q in ("", '"', "'")]
    deny = ["Edit(/%s/**)" % plugins, "Edit(/%s/**)" % st]
    return {"permissions": {"allow": allow, "ask": ask, "deny": deny}, "attribution": dict(ATTRIBUTION_OFF)}


SCOPE_RANK = {"managed": 0, "project local": 1, "project": 2, "user": 3}


def attribution_warnings(sources):
    """Warnings (text) when Claude Code's attribution is on. Settings objects merge key by key, so each key comes from the first
    scope that sets it: managed, then the project's local file, the project's, the user's; among --settings files the last one
    wins. A key no scope sets is on (Claude Code's default)."""
    order = sorted(enumerate(sources), key=lambda x: (SCOPE_RANK.get(x[1][0], 9), -x[0]))
    got = {}
    for _i, (label, path) in order:
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError):
            continue
        if not isinstance(data, dict) or "attribution" not in data:
            continue
        a, where = data["attribution"], "%s %s" % (label, path)
        if not isinstance(a, dict):
            return ["`attribution` in %s is %s, not an object (old Claude Code versions reject a boolean)" % (where, json.dumps(a))]
        for k in ATTRIBUTION_OFF:
            if k in a and k not in got:
                got[k] = (a[k], where)
    on = ["%s (%s)" % (k, got[k][1] if k in got else "not set") for k, off in sorted(ATTRIBUTION_OFF.items())
          if k not in got or got[k][0] != off]
    return ["Claude Code's attribution is on: %s; commits and PRs carry it" % ", ".join(on)] if on else []


def wildcard_re(pattern):
    """Claude Code's wildcard: `\\*` a literal star, `*` any text, a single trailing ` *` also matches nothing."""
    out, i, stars = [], 0, 0
    while i < len(pattern):
        c = pattern[i]
        if c == "\\" and i + 1 < len(pattern) and pattern[i + 1] in "*\\":
            out.append(re.escape(pattern[i + 1]))
            i += 2
            continue
        if c == "*":
            stars += 1
            out.append(".*")
        else:
            out.append(re.escape(c))
        i += 1
    rx = "".join(out)
    if stars == 1 and rx.endswith(r"\ .*"):
        rx = rx[:-len(r"\ .*")] + "(?: .*)?"
    return re.compile("^" + rx + "$", re.S)


def has_wildcard(content):
    i = 0
    while i < len(content):
        if content[i] == "\\":
            i += 2
            continue
        if content[i] == "*":
            return True
        i += 1
    return False


def bash_matches(content, cmd):
    """Whether the content of a `Bash(…)` rule (None: a bare `Bash`) matches one simple command."""
    if content is None or content.strip() in ("", "*", ":*"):
        return True
    norm = re.sub(r"[ \t]+", " ", cmd.strip())
    c = content.strip()
    if c.endswith(":*"):
        prefix = re.sub(r"[ \t]+", " ", c[:-2])
        return norm == prefix or norm.startswith(prefix + " ")
    if has_wildcard(c):
        return bool(wildcard_re(re.sub(r"[ \t]+", " ", c)).match(norm))
    return norm == re.sub(r"[ \t]+", " ", c)


def glob_re(pattern):
    out, i = [], 0
    while i < len(pattern):
        if pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pattern[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile("^" + "".join(out) + "$", re.S)


def path_matches(content, path):
    """Whether a path rule covers an absolute path: `//abs`, `~/…` or `**/…` patterns, gitignore-style (a rule that matches a
    directory covers what is inside). Relative patterns depend on the settings file's place and are not counted."""
    if content is None or content.strip() in ("", "**", "*"):
        return True
    c = content.strip()
    if c.startswith("//"):
        rx = glob_re(c[1:])
    elif c.startswith("~/"):
        rx = glob_re(os.path.join(os.path.expanduser("~"), c[2:]))
    elif c.startswith("**/"):
        rx = glob_re("/" + c)
    else:
        return False
    p = os.path.normpath(path)
    while True:
        if rx.match(p) or rx.match(p + "/"):
            return True
        up = os.path.dirname(p)
        if up == p:
            return False
        p = up


def settings_sources():
    """(label, path) of every settings file Claude Code combines, for the project of the working directory."""
    out = []
    if sys.platform == "darwin":
        out.append(("managed", "/Library/Application Support/ClaudeCode/managed-settings.json"))
    else:
        out.append(("managed", "/etc/claude-code/managed-settings.json"))
    out.append(("user", os.path.join(claude_config_dir(), "settings.json")))
    proj = os.environ.get("CLAUDE_PROJECT_DIR", "")
    if not os.path.isabs(proj):
        try:
            proj = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True,
                                  timeout=5).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            proj = ""
    proj = proj or os.getcwd()
    out.append(("project", os.path.join(proj, ".claude", "settings.json")))
    out.append(("project local", os.path.join(proj, ".claude", "settings.local.json")))
    return out


RULES_READ = {}


def load_rules(sources):
    """[(list, tool, content, rule text, label)] of the readable sources, and the problems of the unreadable ones (read once)."""
    key = tuple(sources)
    if key not in RULES_READ:
        RULES_READ[key] = read_rules(sources)
    return RULES_READ[key]


def read_rules(sources):
    rules, probs = [], []
    for label, path in sources:
        if not os.path.exists(path):
            continue
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
        except (OSError, ValueError) as e:
            probs.append(("UNREADABLE", "%s settings %s cannot be read (%s): its rules are not checked" % (label, path, e)))
            continue
        perms = data.get("permissions") if isinstance(data, dict) else None
        if not isinstance(perms, dict):
            continue
        for kind in ("deny", "ask", "allow"):
            for r in perms.get(kind) or []:
                m = RULE_RE.match(r) if isinstance(r, str) else None
                if m:
                    rules.append((kind, m.group(1), m.group(2), r, "%s %s" % (label, path)))
    return rules, probs


def decide(rules, cmd):
    """(decision, rule) for one Bash command: the first match of deny, ask, allow; (None, None) when no rule matches."""
    for kind in ("deny", "ask", "allow"):
        for k, tool, content, text, where in rules:
            if k == kind and tool == "Bash" and bash_matches(content, cmd):
                return kind, (text, where)
    return None, None


def perm_findings(sources):
    """[(kind, text)]: kind is MISSING, STALE, UNSAFE or UNREADABLE. Empty when the rules in force hold the snippet's split."""
    rules, probs = load_rules(sources)
    out = list(probs)
    L, real = shlex.quote(launcher_path()), os.path.abspath(__file__)
    q = lambda c: "`%s`" % c                                                          # noqa: E731
    want_allow = ["%s %s %s" % (L, sub, a) for sub, a in ALLOWED_SUBS]
    auto_sign = "%s sign --by coordinator-auto %s" % (L, SEAL_PROBE)
    owner = ["%s sign --by owner %s" % (L, SEAL_PROBE), "python3 %s sign --by owner %s" % (shlex.quote(real), SEAL_PROBE),
             "python3 scripts/baton.py sign --by owner %s" % SEAL_PROBE, "./baton sign --by owner %s" % SEAL_PROBE,
             '"%s" sign --by owner %s' % (launcher_path(), SEAL_PROBE), 'python3 "%s" sign --by owner %s' % (real, SEAL_PROBE)]
    modes = ["%s mode auto" % L, "%s mode manual" % L, "python3 %s mode auto" % shlex.quote(real), "./baton mode auto",
             '"%s" mode auto' % launcher_path(), "python3 '%s' mode manual" % real]
    probes, T = want_allow + [auto_sign], tilde_launcher()
    if T:
        probes += ["%s %s %s" % (T, sub, a) for sub, a in ALLOWED_SUBS] + ["%s sign --by coordinator-auto %s" % (T, SEAL_PROBE)]
        owner.append("%s sign --by owner %s" % (T, SEAL_PROBE))
        modes.append("%s mode auto" % T)
    for cmd in probes:
        d, r = decide(rules, cmd)
        if d is None:
            out.append(("MISSING", "no allow rule for %s" % q(cmd)))
        elif d == "ask" and cmd == auto_sign:
            out.append(("STALE", "the ask rule %s (%s) also asks for %s: a broad sign ask puts every normal baton in a dialog"
                        % (q(r[0]), r[1], q(cmd))))
        elif d != "allow":
            out.append(("STALE", "the %s rule %s (%s) catches %s, which should be allowed" % (d, q(r[0]), r[1], q(cmd))))
    for cmd in owner + modes:
        d, r = decide(rules, cmd)
        if d is None:
            out.append(("MISSING", "no ask rule for %s" % q(cmd)))
        elif d == "allow":
            out.append(("UNSAFE", "the allow rule %s (%s) lets %s run with no dialog" % (q(r[0]), r[1], q(cmd))))
        elif d == "deny":
            out.append(("MISSING", "the deny rule %s (%s) blocks %s: it must ask" % (q(r[0]), r[1], q(cmd))))
        for k, tool, content, text, where in rules:
            if k == "allow" and tool == "Bash" and bash_matches(content, cmd) and d != "allow":
                out.append(("UNSAFE", "the allow rule %s (%s) matches %s; only the ask rule in front of it makes a dialog"
                            % (q(text), where, q(cmd))))
    plugins, st = os.path.join(claude_config_dir(), "plugins"), state_dir()
    guarded = (os.path.join(plugins, "installed_plugins.json"),
               os.path.join(plugins, "cache", "vibemaestro", "vibemaestro-sdlc", "0.0.0", "scripts", "baton.py"),
               os.path.join(st, "bin", "baton"), os.path.join(st, "mode"), os.path.join(st, "signatures", "x.json"))
    for path in guarded:
        if not any(k == "deny" and tool == "Edit" and path_matches(content, path) for k, tool, content, _t, _w in rules):
            out.append(("MISSING", "no deny Edit rule covers %s" % path))
    mine = VERSIONED.search(real + "/")
    for k, tool, content, text, where in rules:
        if tool == "Write" and k == "deny" and any(path_matches(content, p) for p in guarded):
            out.append(("STALE", "%s (%s): Claude Code does not match Write(path) rules; Edit(path) covers every write tool"
                        % (q(text), where)))
        m = VERSIONED.search(content or "")
        if m and (mine is None or m.group(1) != mine.group(1)) and "baton" in (content or ""):
            out.append(("STALE", "%s (%s) names version %s" % (q(text), where, m.group(1))))
    if not os.path.exists(launcher_path()):
        out.append(("MISSING", "the launcher %s is not installed" % launcher_path()))
    elif not launcher_current():
        out.append(("STALE", "the launcher %s differs from this version's" % launcher_path()))
    seen, uniq = set(), []
    for f in out:
        if f not in seen:
            seen.add(f)
            uniq.append(f)
    return uniq


def baton_rules_present(sources):
    rules, _p = load_rules(sources)                                  # read once by perm_findings already
    return any("baton" in (content or "") or state_dir() in (content or "") for _k, _t, content, _x, _w in rules)


def fix_hint():
    me = "python3 " + shlex.quote(os.path.abspath(__file__))
    if launcher_current():
        return "%s permissions --print" % me
    return "%s permissions --install-launcher, then %s permissions --print" % (me, me)


def session_warning():
    """One line for SessionStart, or None. In mode manual with no baton rule anywhere, a missing rule is not a finding: there
    every baton command opening a dialog is the intended behaviour; a stale or unsafe rule still is."""
    sources, mode = settings_sources(), read_mode()
    found = perm_findings(sources)
    if mode == "manual" and not baton_rules_present(sources):
        found = [f for f in found if f[0] != "MISSING"]
    if not found:
        return None
    kinds = sorted(set(k for k, _t in found))
    return ("baton permissions (mode %s): %d %s (first: %s); print the fix with: %s"
            % (mode, len(found), "/".join(k.lower() for k in kinds), found[0][1], fix_hint()))


def cmd_permissions(rest):
    usage = "usage: baton.py permissions --print | --check [--settings F]... | --install-launcher"
    if rest == ["--print"]:
        say(json.dumps(snippet(), indent=2))
        if not launcher_current():
            say("baton: the launcher these rules name is not installed (or not current): run %s permissions --install-launcher"
                % ("python3 " + shlex.quote(os.path.abspath(__file__))), sys.stderr)
        return OK
    if rest == ["--install-launcher"]:
        d = ensure_state()
        try:
            os.makedirs(os.path.join(d, "bin"), mode=0o700, exist_ok=True)
            write_private(launcher_path(), launcher_text())
            os.chmod(launcher_path(), 0o700)
        except OSError as e:
            raise Stop(ENV, "the launcher cannot be installed: %s" % (e.strerror or e))
        say("launcher %s installed: the permission rules name it (%s permissions --print)" % (launcher_path(), entry_command()))
        return OK
    if not rest or rest[0] != "--check":
        raise Stop(USAGE, usage)
    files, i = [], 1
    while i < len(rest):
        if rest[i] == "--settings" and i + 1 < len(rest):
            files.append(rest[i + 1])
            i += 2
        else:
            raise Stop(USAGE, usage)
    sources = [("given", os.path.abspath(f)) for f in files] or settings_sources()
    for f in files:
        if not os.path.isfile(f):
            raise Stop(USAGE, "--settings %s: no such file" % f)
    found = perm_findings(sources)
    say("baton permissions: mode %s; settings read: %s" % (read_mode(), ", ".join(p for _l, p in sources if os.path.exists(p))
                                                          or "none"))
    for kind, text in found:
        say("%-10s %s" % (kind, text))
    for text in attribution_warnings(sources):
        say("%-10s %s; --print has the block that turns it off (it does not change the exit code)" % ("WARNING", text))
    if not found:
        say("ok: the rules hold the split (the session signs Stops: none in mode auto; the owner's signature and mode ask)")
        return OK
    say("fix: %s; apply the printed rules through Claude Code's settings (/permissions or settings.json): baton never writes "
        "them" % fix_hint())
    return PERMS


COMMANDS = {"new": cmd_new, "check": cmd_check, "rehearse": cmd_rehearse, "sign": cmd_sign, "run": cmd_run, "go": cmd_go,
            "log": cmd_log, "mode": cmd_mode, "permissions": cmd_permissions}


class SafeOut:
    """stdout that a closed pipe (`baton.py run … | head`) cannot break: once a write fails it is dropped (the run log goes on)."""

    def __init__(self, stream):
        self.stream, self.dead = stream, False

    def write(self, text):
        if not self.dead:
            try:
                self.stream.write(text)
            except OSError:
                self._drop()

    def flush(self):
        if not self.dead:
            try:
                self.stream.flush()
            except OSError:
                self._drop()

    def _drop(self):
        self.dead = True
        try:
            os.dup2(os.open(os.devnull, os.O_WRONLY), self.stream.fileno())   # Python's exit flush must not fail either
        except (OSError, ValueError):
            pass


def help_topic(rest):
    """help <topic>: print one reference file of the batonrun skill as it is."""
    if len(rest) != 1 or rest[0] not in HELP_TOPICS:
        say("baton: usage: baton.py help <topic>; the topics are %s" % ", ".join(HELP_TOPICS), sys.stderr)
        return USAGE
    try:
        with open(os.path.join(HELP_DIR, rest[0] + ".md"), encoding="utf-8") as f:
            sys.stdout.write(f.read())
    except OSError as e:
        say("baton: cannot read the topic %s: %s" % (rest[0], e.strerror or e), sys.stderr)
        return NOINPUT
    return OK

def main(argv):
    for name in ("stdout", "stderr"):
        stream = getattr(sys, name) or open(os.devnull, "w")   # None when the descriptor was closed (`>&-`)
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(errors="backslashreplace")
        setattr(sys, name, SafeOut(stream))
    for sig in (signal.SIGTERM, signal.SIGHUP):
        if signal.getsignal(sig) is not signal.SIG_IGN:  # `nohup` keeps SIGHUP ignored
            signal.signal(sig, _on_term)
    if argv[:1] == ["help"] and len(argv) > 1:
        return help_topic(argv[1:])
    if not argv or argv[0] in ("-h", "--help", "help"):
        say(__doc__.strip(), sys.stdout if argv else sys.stderr)
        if argv:
            say("\nTopics (baton.py help <topic>, the reference files next to the batonrun skill): " + ", ".join(HELP_TOPICS))
        return OK if argv else USAGE
    fn = COMMANDS.get(argv[0])
    if fn is None:
        say("baton: unknown command %r (one of: %s)" % (argv[0], ", ".join(COMMANDS)), sys.stderr)
        return USAGE
    try:
        return fn(list(argv[1:]))
    except Stop as e:
        say("baton: %s" % e, sys.stderr)
        return e.rc
    except (KeyboardInterrupt, Interrupted):
        if RUN["consumed"]:
            say("baton: interrupted after the signature was used: the state is unknown, tell the owner", sys.stderr)
            return UNKNOWN
        say("baton: interrupted before any run phase; nothing ran", sys.stderr)
        return REFUSED
    except Exception as e:                              # never a traceback with rc 1, which means "fails check"
        say("baton: unexpected %s: %s" % (type(e).__name__, e), sys.stderr)
        return ENV


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
