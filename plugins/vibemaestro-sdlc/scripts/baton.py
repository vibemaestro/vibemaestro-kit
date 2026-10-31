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
  baton.py list [<keyword>...]                                     one line per baton (kit:, kind:, project:, user:), at most 25;
                                                                   the one baton every keyword matches: its whole entry
  baton.py pack <script|project:N|user:N> <project|user>:<name>    keep a script that ran ok (file, keep record; user: prints an
                                                                   `owner:` line to relay), or move a kept one to the other place;
                                                                   in a sandbox a bare <name> is project:<name>, user: is refused
  baton.py pack --retire <project|user>:<name> <sha256>            unpin one sha; the file stays
  baton.py log [--tail N]                                          the last N lines of the log (default 20)
  baton.py log --last                                              the path of the newest run log (set before the script runs: a killed run is found here)
  baton.py log --wait-names N1,N2,... [--timeout S] [--since T]   wait (S 1-580 s) until the latest run line since T (default:
                                                                   300 s before the wait) of each named script is ok
  baton.py help [<topic>]                                          this text, or one reference file of the batonrun skill:
                                                                   act, kinds, kits, modes, permissions, setup, limits
  baton.py mode [manual|auto]                                      print or set the approval mode
  baton.py mode remotes | mode trust|untrust <remote>             print or change the owner's remote list (a reviewed project:
                                                                   baton of a listed origin runs without a keep record)
  baton.py permissions --print                                     the user-settings block: permission rules, attribution off
  baton.py permissions --check [--settings F]...                   the rules in force against --print; writes nothing
  baton.py permissions --install-launcher [--force]                copy the launcher to <state>/bin/baton, the command the rules name
                                                                   (refused from a copy that is not the registry's sdlc, unless --force)

A script is a path (a session baton), kit:<name>, kind:<name>, or a kept baton: project:<name> (<project root>/.vibemaestro/
batons/<name>.sh) or user:<name> (the library $XDG_DATA_HOME/vibemaestro/batons/<name>.sh); any other prefix or a bare name is
refused. A kept baton runs only with bytes a keep record in <state>/kept pins (checked at every step), with no 120 s gate,
or, for project:, bytes that are the blob on origin's default branch when origin is on the owner's remote list.
A baton that declares `# Params:` takes key=value words, every one checked against its type before anything runs; the script
gets the values as $1… in the declared order (a file value as a read-only copy under <state>/inputs, bound by its sha256).
baton's own options come before the script path; everything after the path is the script's own arguments (`--` ends baton's
options). Every phase runs `bash` on a fresh copy of the hashed bytes, from the caller's directory, with the caller's environment
(without BASH_ENV, the other SHELL_HOOKS and P_*) plus BATON_PHASE, in a process group of its own, stdin closed. The run phase
and its undo also get BATON_PLAN, a file holding the signed plan, so a script can refuse an act when the world moved since, and
BATON_UNDO_ONLY, a file the script appends the path of a file to when it keeps it only for its undo (a backup): once the run
ends ok or its undo put the state back, baton removes each such path that is a regular file the run wrote in <state>/records;
when the state is unknown they stay, for the owner.

`go` is `rehearse`, `sign --by coordinator-auto` and `run` in turn; it stops at the first step that fails, with its exit code
and whole output, else prints one line, `go: ok — <n> writes — <run log>`.
`go` runs a session baton only from a file written in the last FRESH_SECONDS (120 s, by fstat on the bytes read): an older
file is rc 1, nothing run, unless `--reuse` says these very bytes are meant again. The same holds for the --spec file of
kit:gh-write and for an `input` value.
`go -` reads the script from stdin (at most STDIN_MAX bytes, not a terminal, not empty), writes it once to
<state>/stdin/<stamp>-<sha12>.sh (mode 0400) and runs that file exactly as `go <file>`. Claude Code denies a heredoc that holds the
baton skeleton (limits.md): a session writes the baton to a fresh path and runs `go <path>`. `--reuse -` is bad usage; a file
named `-` runs as `go ./-`. The newest STDIN_KEPT stored scripts are kept, and any younger than STDIN_KEEP_DAYS within the
newest STDIN_HARD.
`kind:<name>` runs a ready kind (templates/baton-kinds/<name>.sh, CALLABLE_KINDS). A failed post-check is read again after 1,
2, 4 and 8 s (BATON_POSTCHECK_WAITS may only shorten that).

A signature binds the script's sha256 (and a kept baton's place), its arguments (and file values' sha256), the directory, a
fingerprint of the variables that steer the tools (STEERING) and the plan; `sign` names the seal rehearse printed. `run` consumes
it, and its writes (DO lines) must be the signed plan. Mode `manual` (the default) accepts only `--by owner`; mode `auto` also
`--by coordinator-auto`, for `Stops: none` and no argument or Param value that names a Claude Code settings file or its
directory (settings_value). This guards an honest but fallible session, not one that sets out to forge a record.
`go --queue` leaves a run that needs the owner in the queue instead of a dialog: the owner signs it later from a Claude Code session
of their own (`sign --by owner --queued <id>`, never from the session or Claude Code process that queued it), and `run --queued
<id>` runs it once within 24 h while its plan is the sealed one; `log --queue` lists the items, `log --wait-queued <id>` waits.

State, outside every repository: $XDG_STATE_HOME/vibemaestro/baton (a relative XDG_STATE_HOME is ignored), else
~/.local/state/vibemaestro/baton: `mode`, `signatures/`, `used/`, `log.tsv`, `runs/` (the newest 200 run outputs are kept; `runs/LAST` names the newest, written before the script runs),
`stdin/` (the scripts `go -` read), `inputs/` (file values' copies: a call that never reaches its run phase removes its own,
the copies runs used are kept, the newest 200, until a call of the same bytes that never runs ends), `records/` (a script's run records and backups), `kept/` (keep records `pack` writes),
`queue/` (the owner's queue; `queue/used/` the items that ran; both removed 7 days after their expiry).

Exit codes:
  0   done
  1   the script fails check, or its rehearse fails (exit not 0, no verdict line, plan differs from Expect or the Targets);
      pack: the source fails check as a kept one
  2   environment: no bash, or the state directory cannot be written; pack: a lock held 30 s
  3   refused, nothing ran: no signature matches the script, its arguments, its directory, its environment and its plan (for
      sign: the seal shown), the mode does not allow the signer, `sign --by owner` has no record of the owner's dialog for
      that very call (the plugin's hook baton-guard.py writes it when it opens the dialog), or it stopped before the run phase
      (an interrupt or an error); the signature stays unused; a kept baton not pinned on this machine, a loose project root;
      pack: no ok run of these bytes here, the bytes kept under another name, another Stops; a queued item absent, unsigned,
      expired, used, damaged, signed by the session that queued it, or run elsewhere; log --wait-queued: never signable
  4   the run or its post-check failed, and undo put the state back
  5   the state is unknown: undo failed too, or the run phase or a later one was interrupted or hit an error; pack interrupted
  6   new: the file already exists
  7   permissions --check: a rule is missing, stale or unsafe (each one is printed)
  8   go: the baton needs the owner's signature (a Stops item, or mode manual); nothing was signed, nothing ran
  9   log --wait-names: at the deadline a named script's latest run line since --since is not ok, or it has none (each is named);
      log --wait-queued: the item is not signed by the deadline
  10  permissions --check, or --install-launcher without --force: the registry no longer lists this installed copy and the
      launcher runs another (the session started before a plugin update); restart Claude Code; nothing written
  64  bad usage, a call that does not fit the Params, an unknown prefix or a bare name; pack: no place, a kit, kind or copy name;
      go --queue in a sandbox, with no session id, with --by, or on a baton the session may sign itself; --queued with a
      malformed id, another signer, or a word after the id
  66  the script cannot be read: no such kept baton, no project root; retire: no record of the sha

Python 3.8+, standard library only.
"""
import calendar
import difflib
import errno
import fcntl
import fnmatch
import glob
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
import unicodedata

sys.dont_write_bytecode = True

OK, BAD_SCRIPT, ENV, REFUSED, UNDONE, UNKNOWN, EXISTS, PERMS, OWNER, USAGE, NOINPUT = 0, 1, 2, 3, 4, 5, 6, 7, 8, 64, 66
WAIT_UNMET = 9
OTHER_SDLC = 10

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
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]*\Z")
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
KIND_RE = re.compile(r"^[a-z0-9][a-z0-9-]*\Z")
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
KIT_RE = re.compile(r"^[a-z0-9][a-z0-9-]*\Z")
KIT_ROOT = os.path.realpath(os.path.join(PLUGIN_ROOT, "batons"))
# Kept batons and parameters. `project:<name>` is <project root>/.vibemaestro/batons/<name>.sh, `user:<name>` the user library's
# <name>.sh; a call always names its place (no lookup across places), and a kept baton runs only with bytes a keep record in the
# state directory pins (kept/<place key>/<name>/<seq>.json; `baton pack` writes them). `# Params:` declares a baton's values: a
# call passes them as key=value, checked against a closed vocabulary of types before anything runs; the script gets them as
# positional arguments in the declared order and reads them once, into P_<KEY>; a file value is a read-only copy under
# <state>/inputs, bound by its sha256. `# Usage:` documents the flags of a kit or kind, which keep their own interface.
OPTIONAL_FIELDS = ("Params", "Usage")
PLACES = ("kit", "kind", "project", "user")
PREFIX_WORD = re.compile(r"([A-Za-z][A-Za-z0-9_-]*):")
KEPT_NAME_MAX, KEPT_MAX, HEADER_READ = 64, 256 * 1024, 8 * 1024
PARAM_KEY = re.compile(r"[a-z][a-z0-9_]{0,31}\Z")
PARAM_TYPES = ("int", "sha40", "sha256", "name", "repo", "ref", "path", "url", "file", "input")
SECRET_KEY = re.compile(r"token|secret|passw|credential|apikey|api_key", re.I)
# A file or input value is copied under <state>/inputs and kept, so one whose bytes look like key material is refused before the
# copy: a secret is a path value, read where it is. The kinds name key material with little doubt: the leak scan's
# (gates/pr_sensitive.py) and a few more token shapes; its prose kinds (password=, bearer, a URL credential, long base64) are left
# out, since an input value is mostly prose. A token starts at TOKEN_START: after a byte that cannot be part of it, or right
# after an escape (`\nghp_…` in JSON, `%3Dghp_…`), so a word or a base64 blob holding the prefix is not one and each match has
# few starts (no quadratic scan of 1 MiB). Group 1 is the value: fewer than 4 distinct bytes in it is a placeholder
# (ghp_XXXX…), judged on the whole value so padding a real token does not hide it; a docs placeholder with a varied part
# (sk-ant-api03-xxxx…) is refused. A backstop, not the rule: a binary or re-encoded key passes, and so does a token glued to
# a byte that can be part of it (123ghp_…).
TOKEN_START = rb"(?:(?<![A-Za-z0-9_\-])|(?<=\\[nrt])|(?<=\\u[0-9A-Fa-f]{4})|(?<=%[0-9A-Fa-f]{2}))"
SECRET_CONTENT = [(k, re.compile(rx)) for k, rx in (
    ("private-key", rb"-----BEGIN [A-Z0-9 ]*PRIVATE KEY|PuTTY-User-Key-File-[0-9]+:"),
    # YAML plain, quoted, block or on the next line, or JSON with the key quoted
    ("cluster-client-key", rb"client-key-data[\"']?\s*:\s*(?:[|>][-+]?\s*)?[\"']?([A-Za-z0-9+/]{16,})"),
    ("github-token", TOKEN_START + rb"(?:gh[pousr]_([A-Za-z0-9]{30,})|github" rb"_pat_([A-Za-z0-9_]{40,}))"),
    ("gitlab-token", TOKEN_START + rb"glpat-([A-Za-z0-9_\-]{20,})"),
    # a bare sk- needs a run of 20 without a hyphen, so a branch name (sk-1234-fix-login-…) is not one
    ("api-key-sk", TOKEN_START + rb"(?:sk-(?:ant|proj)-([A-Za-z0-9_\-]{20,})|sk-([A-Za-z0-9_\-]*[A-Za-z0-9_]{20})|[rs]k_live_([A-Za-z0-9]{20,}))"),
    ("slack-token", TOKEN_START + rb"xox[abpr]-([A-Za-z0-9-]{10,})"),
    ("aws-access-key", TOKEN_START + rb"(?:(?:AKIA|ASIA)([0-9A-Z]{16})(?![0-9A-Z])|"
     rb"(?i:aws_secret_access_key|aws_session_token|secretaccesskey|sessiontoken)(?:\\?[\"'])?(?:[ \t]*[:=][ \t]*|[ \t]+)"
     rb"(?:\\?[\"'])?(?=[A-Za-z+/=]{0,64}[0-9])([A-Za-z0-9+/=]{20,}))"),
    ("google-api-key", TOKEN_START + rb"AIza([0-9A-Za-z_\-]{35})"),
    ("npm-token", TOKEN_START + rb"npm_([A-Za-z0-9]{36})(?![A-Za-z0-9])"),
    ("vault-token", TOKEN_START + rb"hv[sbr]\.([A-Za-z0-9_\-]{20,})"),
    ("age-secret-key", rb"AGE-SECRET-KEY-1([A-Z0-9]{20,})"),
    ("jwt", TOKEN_START + rb"eyJ([A-Za-z0-9_\-]{10,})\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{5,}"),
)]
PARAMS_LINE_MAX, PARAMS_KEYS_MAX, VALUES_MAX, FILE_MAX, INPUTS_KEPT = 400, 12, 4096, 1 << 20, 200
BASENAME_MAX = 190                                      # <sha256>.<basename> stays within a 255-byte file name
LEAD_REFUSED = "-+:@=~%"                                # a value starting with one changes a word's meaning for git, gh, curl
WORD_RE = {"int": re.compile(r"(?:0|[1-9][0-9]{0,17})\Z"), "sha40": re.compile(r"[0-9a-f]{40}\Z"),
           "sha256": re.compile(r"[0-9a-f]{64}\Z"), "name": re.compile(r"[a-z0-9][a-z0-9_-]{0,99}\Z"),
           "repo": re.compile(r"[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9][A-Za-z0-9._-]{0,99}\Z")}
PATH_CHARS = re.compile(r"[A-Za-z0-9._/@+-]+\Z")
REF_CHARS = re.compile(r"[A-Za-z0-9._/-]{1,200}\Z")
REF_SHADOWS = re.compile(r"(?:HEAD|[A-Z_]+_HEAD|AUTO_MERGE|BISECT_EXPECTED_REV|[0-9a-fA-F]{40}|[0-9a-fA-F]{64})\Z")
URL_RE = re.compile(r"https://([a-z0-9.-]+)(?::([1-9][0-9]{0,4}))?(/.*)?\Z")
DNS_LABEL = re.compile(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\Z")
# Targets of a kept baton: patterns, `{key}` placeholders of these types; `X/**` covers X and what is under it
TARGET_TYPES = ("path", "under", "repo", "ref", "url", "name", "int", "sha40", "enum")
PLACEHOLDER = re.compile(r"\{([a-z][a-z0-9_]{0,31})\}")
TARGET_SEP = " — "                                 # ` — `: prose follows, in a Targets value and in a plan line
LIST_LINES, LIST_WIDTH, ENTRY_MAX, CUT = 25, 260, 1536, 120
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
LOG_FIELDS = ("time", "event", "name", "script", "binding", "args", "dir", "signed_by", "mode", "result", "undone", "output",
              "baton")                         # <prefix>:<name>@<sha256>, scratch@<sha256>; a line written before it has 12 fields

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
GIT_OPT = (r"(?:-[Cc]\s+\S+|-[pP](?!\S)|--(?:git-dir|work-tree|namespace)\s+\S+"
           r"|--(?!(?:git-dir|work-tree|namespace)(?:\s|$))[\w-]+(?:=\S+)?)")
GIT = r"\bgit(?:\s+" + GIT_OPT + r")*\s+"
# git pointed at another repository: `-C`, `--git-dir` or `--work-tree` among its options, or a GIT_DIR=/GIT_WORK_TREE= prefix
GIT_ELSEWHERE = (r"(?:\bGIT_(?:DIR|WORK_TREE)=\S*\s+(?:[A-Za-z_]\w*=\S*\s+)*(?=git\s)"
                 r"|(?=\bgit(?:\s+" + GIT_OPT + r")*?\s+(?:-C\s|--git-dir|--work-tree)))" + GIT)
# a ref deleted by its value: the zero object id (SHA-1 or SHA-256) as the new value
ZERO_OID = r"[\"']?0{40}(?:0{24})?(?![0-9a-fA-F])"
# a file command that removes or moves (not `--rm`, not `git|docker|podman|npm rm`)
# the short options of `git branch`, so a combined `-Dq` or `-df` reads as flags and `--sort -refname` does not
BR_FLAGS = r"[acCdDfilmMqrtuv]"
REFS_NS = r"refs/(?:heads|tags|remotes|notes|replace|original|stash|namespaces|pull|bisect)\b"
REFS_PATH = r"(?:" + REFS_NS + r"|refs/?\*?[\"']?(?=[\s;|&)]|$))"
RM_WORD = r"(?<!-)(?<!git\s)(?<!docker\s)(?<!podman\s)(?<!npm\s)\b(?:rm|unlink|mv|truncate|shred)\b"
# a flagged branch delete names the kit that deletes a proven-merged GitHub branch without the owner
BRANCH_DELETE_LABELS = ("git push --delete|-d|:<ref>", "git update-ref -d|--delete", "git update-ref <ref> 0{40}",
                        "update-ref --stdin: delete <ref>|update <ref> 0{40}|<heredoc or file>", "git branch -D|-d -f|--delete --force",
                        "git -C|--git-dir|--work-tree|GIT_DIR=<dir> branch -d|-f|-M|-C|--delete|--force")
BRANCH_KIT_HINT = ("; a branch of a private GitHub repository (not a tag, not a rename) merged into its default branch at a "
                   "pinned head (the head in the default branch, or the head of its merged PR into it): "
                   "`kit:branch-delete repo= branch= head=` deletes it with no owner signature")
# A Claude Code settings file: settings*.json (managed-settings.json) right under .claude, $CLAUDE_CONFIG_DIR or the managed
# directory, joined by `/` or written as path parts (`".claude", "settings.json"`, `".claude" / "settings.json"`). The guard
# (scripts/settings-guard.py) denies a plain-tool write that widens one; a baton's writes run where no hook sees them.
# a directory: `.claude`, CLAUDE_CONFIG_DIR, the managed one, or a variable named for it (`"$CLAUDE_DIR/settings.json"`); not
# `foo.claude` or `x-claude-code`
SETTINGS_DIR = (r"(?<![\w.-])(?:(?i:\.claude)|CLAUDE_CONFIG_DIR|(?i:claude-?code)"
                r"|\$\{?(?!CLAUDE_PLUGIN|CLAUDE_PROJECT_DIR\b)[A-Za-z_]*(?i:claude)\w*)\}?")    # a plugin's own root is not it
SETTINGS_FILE = r"(?i:(?:managed-)?settings[\w.*?\[\]{},-]*\.json)(?![\w.-])"           # a glob or `settings{,.local}.json` too
SETTINGS_PATH = (SETTINGS_DIR + r"[\"']?[\])]*[\"']?\s*(?:[/,]|\+\s*[\"']/)[/\s]*(?:\./)*[\"']?"  # `environ["…"], "…"`, `+ "/…"`
                 + SETTINGS_FILE)
# the path as one shell word: a quoted word may hold spaces and `$(…)`; unquoted, `$(…)` and quoted pieces with no space
# (`"$HOME/".claude`, `~/'.claude'`, `` `pwd` ``): a quoted piece with a space would reach into a `$(jq … "<path>")` read
SHELL_PIECE = r"(?:[^\s|;&<>()\"'`]|\$\([^()\n]*\)|\"[^\"\s]*\"|'[^'\s]*'|`[^`\s]*`)"
SETTINGS_WORD = r"(?:\"[^\"\n]*?|'[^'\n]*?|" + SHELL_PIECE + r"*?[\"']?)" + SETTINGS_PATH
WORD_END = r"[\"']?(?:\s+\d*[<>]&?\s*\S*)*\s*(?:#[^\n]*)?(?:$|[;|&)])"  # the last word: a redirection or a comment may follow
FILE_CMD = r"(?<![-\w.])(?:%s)(?![\w-])"                            # a command word (`/bin/rm` too, never `--rm`)
CODE_WRITE = (r"\bopen\([^\n]*?,\s*(?:mode\s*=\s*)?[\"'][rbt]*[wax+][rbtwax+]*[\"']"
              r"|\.open\(\s*(?:mode\s*=\s*)?[\"'][rbt]*[wax+][rbtwax+]*[\"']"
              r"|write_text|write_bytes|json\.dump\((?![^\n;]*?,\s*sys\.std)|(?<!stdout)(?<!stderr)\.write\(|\bos\.(?:replace|rename|remove|unlink|truncate)\(|\bshutil\.\w+\("
              r"|writeFile|appendFile|copyFile|createWriteStream|\bfs\.(?:rename|copy|unlink|rm)|file_put_contents")
SETTINGS_HELD_LABEL = "settings*.json or its .claude|$CLAUDE_CONFIG_DIR directory held in a name: X=|x = |${X:=}|for x in"
SETTINGS_HELD_HINT = ("; a later write through that name is not seen, so the name counts as one. A baton that only reads it: "
                      "declare it all the same, or name the path written out in the command that reads it, not through a "
                      "name (`OUT=$(jq . \"$HOME/.claude/settings.json\")`)")
STOP_HINTS = (                                     # (category, the label check names and the skill lists, the pattern)
    ("irreversible-delete", "gh repo|release delete", r"\bgh\s+(?:repo|release)\s+delete\b"),
    ("irreversible-delete", "kubectl … delete ns|pvc|pv",
     r"\bkubectl(?=\s)[^|;&\n]*\sdelete\s+(?:ns|namespaces?|pvc|persistentvolumeclaims?|pv|persistentvolumes?)\b"),
    # `:<ref>` quoted or forced too (`":$REF"`, `'+:<ref>'`): a refspec with no source deletes, whatever lease it carries
    ("irreversible-delete", "git push --delete|-d|:<ref>",
     GIT + r"push\b[^|;&\n]*(?:\s--delete\b|\s-d\b|\s[\"']?\+?:[^\s:\"']+)"),
    ("irreversible-delete", "gh api -X DELETE", r"\bgh\s+api\b[^|;&\n]*(?:-X\s*|--method[\s=]+)[\"']?(?i:DELETE)\b"),
    ("irreversible-delete", "git push --mirror", GIT + r"push\b[^|;&\n]*\s--mirror\b"),
    # a ref deleted without a push, in any repository: the remote's own directory is as writable as the clone
    ("irreversible-delete", "git update-ref -d|--delete", GIT + r"update-ref\b[^|;&\n]*\s(?:-d|--delete)\b"),
    ("irreversible-delete", "git update-ref <ref> 0{40}",               # the new value; a zero old value only asks "create"
     GIT + r"update-ref(?:\s+(?:-m\s+(?:\"[^\"]*\"|'[^']*'|\S+)|--[\w-]+(?:=\S+)?))*\s+\S+\s+" + ZERO_OID),
    # its input: a delete line seen anywhere, a `delete` piped in, or a heredoc or file the line lint cannot read
    ("irreversible-delete", "update-ref --stdin: delete <ref>|update <ref> 0{40}|<heredoc or file>",
     r"(?:^|[\s\"'(])(?:delete\s+[\"']?refs/|update\s+[\"']?refs/\S+\s+" + ZERO_OID + r")"
     r"|(?:\bdelete\b[^\n]*?|(?:<|(?<![^\s;&|(`])(?:/[\w./-]*/)?cat(?=[\s|)`]))[^;&\n]*?)\|\s*" + GIT + r"update-ref\b(?=[^|;&\n]*?\s--stdin\b)"
     r"|" + GIT + r"update-ref\b(?=[^|;&\n]*?\s--stdin\b)[^|;&\n<]*<"),
    ("irreversible-delete", "git branch -D|-d -f|--delete --force",
     GIT + r"branch\b(?:[^|;&\n]*\s-" + BR_FLAGS + r"*D" + BR_FLAGS + r"*\b|(?=[^|;&\n]*\s(?:-" + BR_FLAGS + r"*d" + BR_FLAGS
     + r"*\b|--delete\b))(?=[^|;&\n]*\s(?:-" + BR_FLAGS + r"*f" + BR_FLAGS + r"*\b|--force\b)))"),
    ("irreversible-delete", "git -C|--git-dir|--work-tree|GIT_DIR=<dir> branch -d|-f|-M|-C|--delete|--force",
     GIT_ELSEWHERE + r"branch\b[^|;&\n]*\s(?:-" + BR_FLAGS + r"*[dfMC]" + BR_FLAGS + r"*\b|--delete\b|--force\b)"),
    ("irreversible-delete", "git tag -d|--delete", GIT + r"tag\b[^|;&\n]*\s(?:-[A-Za-z]*d|--delete)\b"),
    # a ref file or a whole refs directory: `refs/<a git namespace>/…`, or a path ending in `refs`, `refs/` or `refs/*`
    ("irreversible-delete", "rm|unlink|mv|truncate|shred|find -delete|-exec rm|> … refs/",
     r"(?:" + RM_WORD + r"|\bfind\b(?=[^|;&\n]*\s(?:-delete\b|-exec\s+\S*\brm\b)))[^|;&\n]*(?<=[/\s\"'])" + REFS_PATH
     + r"|>\|?\s*[^\s|;&<>]*\b" + REFS_NS + r"/"),
    ("irreversible-delete", "packed-refs written: >|tee|sed -i|perl -i|dd of=|rm|mv|truncate|cp onto",
     r"(?:>\|?\s*|>>\s*|\btee\b[^|;&\n]*\s|\bdd\b[^|;&\n]*\bof=|\b(?:sed|perl)\b[^|;&\n]*\s(?:-[A-Za-z]*i|--in-place)[^|;&\n]*\s"
     r"|" + RM_WORD + r"[^|;&\n]*\s)[\"']?[^\s|;&<>]*packed-refs(?![\w.-])"
     r"|\b(?:cp|install|ln)\b[^|;&\n]*\s[\"']?[^\s|;&<>]*packed-refs[\"']?\s*(?:$|[;|&)])"),
    ("secrets", "gh secret", r"\bgh\s+secret\b"),
    ("secrets", "kubectl … secret", r"\bkubectl(?=\s)[^|;&\n]*\ssecrets?\b"),
    ("secrets", "vault kv|read|write|delete", r"\bvault\s+(?:kv|read|write|delete)\b"),
    ("security-boundary", "kind: Role|RoleBinding|ClusterRole…|NetworkPolicy|ValidatingAdmissionPolicy",
     r"\bkind:\s*(?:ClusterRole|ClusterRoleBinding|Role|RoleBinding|NetworkPolicy|ValidatingAdmissionPolicy\w*)\b"),
    ("security-boundary", "gh pr merge --admin",
     r"\bgh(?:\s+(?:-R|--repo)[\s=]+\S+)?\s+pr(?:\s+(?:-R|--repo)[\s=]+\S+)?\s+merge\b[^|;&\n]*\s--admin\b"),
    ("security-boundary", "private=false|visibility=public", r"\b(?:private=false|visibility=public)\b"),
    ("security-boundary", "--visibility public", r"--visibility[\s=]+public\b"),
    # the settings guard's Bash shapes, on one line: a redirection, a file command naming it, a copy onto it (or a settings
    # file into a .claude directory), dd of=, a download onto it, an in-place edit, git checkout|restore, code that names it
    # and writes; and the path as an argument of write() or of an interpreter whose program is a heredoc (a change it makes)
    ("security-boundary",
     "settings*.json under .claude|$CLAUDE_CONFIG_DIR written: >|tee|rm|mv|ln|cp|install|rsync|sd|dd|curl|wget -o"
     "|sed|perl|ruby|yq|awk -i|git checkout|code|a write() or interpreter argument",
     r"(?:>\|?|>>|&>>?)\s*" + SETTINGS_WORD
     + r"|(?:^|[;&|{(]|\b(?:then|do|else))\s*write\s+(?:\"[^\"\n]*\"|'[^'\n]*'|\S+)\s[^\n]*?" + SETTINGS_PATH
     + r"|\b(?:python[0-9.]*|node|ruby|perl|php|deno|bun)\b(?=[^|;&\n]{0,600}<<)[^|;&\n]{0,600}?" + SETTINGS_PATH
     + r"|" + FILE_CMD % "tee|sponge|truncate|rm|unlink|shred|mv|ln|patch|sd" + r"[^|;&\n]{0,600}?\s" + SETTINGS_WORD
     + r"|" + FILE_CMD % "cp|install|rsync" + r"[^|;&\n]{0,600}\s" + SETTINGS_WORD + WORD_END
     # into a .claude directory: a settings*.json, or a directory copied whole (cp, rsync)
     + r"|(?:" + FILE_CMD % "cp|install|rsync|mv|ln" + r"(?=[^|;&\n]{0,600}?(?i:settings)[\w.*?\[\]-]*\.json)|" + FILE_CMD % "cp|rsync"
     + r"(?=[^|;&\n]{0,600}?\s(?:-[A-Za-z]*[rRa]|--(?:recursive|archive)\b)))[^|;&\n]{0,600}\s[\"']?" + SHELL_PIECE
     + r"{0,300}?[\"']?" + SETTINGS_DIR + r"[\"']?/?" + WORD_END
     + r"|\bdd\b[^|;&\n]{0,600}\sof=" + SETTINGS_WORD
     + r"|\b(?:curl|wget)\b[^|;&\n]{0,600}?\s(?:-[A-Za-z]*[oO]|--output(?:-document)?)(?:=|\s*)" + SETTINGS_WORD
     + r"|" + FILE_CMD % "g?sed|perl|ruby|yq|g?awk" + r"(?=[^|;&\n]{0,600}\s(?:-(?![Mm])[A-Za-z0-9]*i|--in-?place))[^|;&\n]{0,600}?"
     + SETTINGS_PATH
     + r"|" + GIT + r"(?:checkout|restore)\b[^|;&\n]{0,600}?" + SETTINGS_PATH
     + r"|^(?=[^\n]*" + SETTINGS_PATH + r")[^\n]*?(?:" + CODE_WRITE + r")"),
    ("security-boundary", SETTINGS_HELD_LABEL,
     # shell: the value is the path word (`S="$HOME/.claude/settings.json"`), not a command reading it (`R="$(jq . …)"`)
     # or a `${S:=…}` default
     r"(?<![\w$(,.=-])[A-Za-z_]\w*=\(?[\"']?" + SHELL_PIECE + r"{0,300}?" + SETTINGS_PATH
     + r"|\$\{\w+:?=[^}\n]{0,600}?" + SETTINGS_PATH
     # code: a call or a string that ends in the path (`p = os.path.join(…, ".claude", "settings.json")`, `p = f"{h}/…"`), or,
     # with a space after `=`, an operator, a list, a parenthesis or a template (`p = home / ".claude" / …`); not a read
     # (open, read, load, exists, isfile, stat): `x=y/z cmd <path>` and ``X=`cat <path>` `` are shell, not code
     + r"|(?<![\w$(,.=-])[A-Za-z_][\w.]*\s*(?::[^=\n]{0,80})?=(?!=)(?:\s*(?=[\w.]+\s*\(|[fFrRbB]{0,2}[\"'])"
     + r"|\s+(?=[\w.]+\s*[/+%\[]|[\[(`]))"
     + r"(?:(?!\b(?:open|read(?:_text|_bytes|lines?)?|loads?|exists|is_?file|stat|getsize|getmtime)\s*\(|\$\()[^;\n]){0,600}?"
     + SETTINGS_PATH
     + r"[\"'`)\]\s]*(?:(?:\.(?:expanduser|resolve|absolute)\(\)|%\s*[\w(][^;#\n]*)\s*)*(?:$|[;#])"
     + r"|\bfor\s+\w+\s+in\b[^;\n]*?" + SETTINGS_PATH),
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
    """A refusal: its message is built by the print layer (shown), so a value in it cannot forge a line."""
    def __init__(self, rc, fmt, *args):
        self.text = shown(fmt, *args)
        Exception.__init__(self, self.text)
        self.rc = rc


def sha256(data):
    return hashlib.sha256(data if isinstance(data, bytes) else data.encode("utf-8", "surrogateescape")).hexdigest()


def iso_at(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def now_iso():
    return iso_at(time.time())


# ── the print layer: every line baton prints is a constant format and escaped values ──────────────────────────────
class Safe(str):
    """Text the print layer built (shown, shown_join): its values are escaped already, so the layer passes it on as it is."""


def shown(fmt, *args):
    """The one way a value gets into a line baton prints: `fmt` is a constant baton writes itself, each arg is escaped with esc
    (a newline in a path cannot start a line of its own), except a Safe (built here) and a number. Without args, fmt as it is."""
    return Safe(fmt % tuple(a if isinstance(a, (Safe, int, float)) else esc(str(a)) for a in args) if args else fmt)


def shown_join(sep, parts):
    """The parts joined by the constant `sep` (a block of lines baton composes), each escaped unless the layer built it."""
    return Safe(sep.join(p if isinstance(p, Safe) else esc(str(p)) for p in parts))


def say(fmt, *args, out=None):
    (out or sys.stdout).write(shown(fmt, *args) + "\n")
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
        raise Stop(USAGE, "%s: a kit baton is named by lower-case letters, digits and '-' only (no '/', no '.')", arg)
    root = KIT_ROOT
    path = os.path.join(root, name + ".sh")
    found, refused, why = dependent_kits(arg, name)
    if os.path.lexists(path):
        if found:
            raise Stop(USAGE, "%s: both %s and %s ship batons/%s.sh; a kit name must be unique, so neither runs", arg, SDLC,
                       " and ".join(k.pid for k in found), name)
        if os.path.dirname(os.path.realpath(path)) != root:
            raise Stop(USAGE, "%s: %s leads outside %s", arg, path, root)
        return Kit(path, root, plugin_real(), None)
    if len(found) > 1:
        raise Stop(USAGE, "%s: %s both ship batons/%s.sh; a kit name must be unique, so none runs", arg,
                   " and ".join(k.pid for k in found), name)
    if found:
        return found[0]
    if refused:
        raise Stop(USAGE, "%s", shown_join("\n", refused))
    raise Stop(NOINPUT, "%s: no such kit baton in %s%s", arg, root, why or " nor in batons/ of a plugin that depends on " + SDLC)


def read_capped(path, cap, nofollow=True):
    """(bytes, stat) of a regular file of at most `cap` bytes, opened without blocking and, with `nofollow`, never through a
    symlink; ValueError or OSError."""
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
        return b"".join(chunks), st
    finally:
        os.close(fd)


def read_small(path, cap, nofollow=True):
    """The text of a regular file of at most `cap` bytes (read_capped); ValueError or OSError."""
    return read_capped(path, cap, nofollow)[0].decode("utf-8")


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
        raise Stop(USAGE, "%s: no such callable kind; the callable kinds are %s (`new --from` writes any kind)", arg,
                   ", ".join(CALLABLE_KINDS))
    path = os.path.join(KINDS_REAL, name + ".sh")
    if not os.path.lexists(path):
        raise Stop(NOINPUT, "%s: no such kind in %s", arg, KINDS_REAL)
    if os.path.dirname(os.path.realpath(path)) != KINDS_REAL:
        raise Stop(USAGE, "%s: %s leads outside %s", arg, path, KINDS_REAL)
    return path


# ── kept batons: places, the pin, parameters ───────────────────────────────────────────────────────────────────────────────────
def esc(v):
    """v with its C0 and C1 controls, DEL, format characters (Cf) and line or paragraph separators (Zl, Zp) written as \\u{…}:
    text that came from a file or a value cannot redraw or hide a line baton prints."""
    return "".join("\\u{%x}" % ord(c) if ord(c) < 0x20 or 0x7f <= ord(c) <= 0x9f or unicodedata.category(c) in ("Cf", "Zl", "Zp")
                   else c for c in v)


def quoted(v):
    """A value as every call form baton prints shows it: escaped, then single-quoted for the shell (shlex.quote)."""
    return shlex.quote(esc(v))


def place_of(word):
    """The place a script word names: kit, kind, project or user; None for a path. Any other prefix (lib:, Kit:) and a bare
    name are refused: a call always names its place, and no place is searched on the caller's behalf."""
    m = PREFIX_WORD.match(word)
    if m:
        if m.group(1) in PLACES:
            return m.group(1)
        raise Stop(USAGE, "%s: %s: is not a place; a baton is kit:<name>, kind:<name>, project:<name> or user:<name>, or a "
                          "path (a file whose name looks like a prefix: ./%s)", word, m.group(1), word)
    if KIT_RE.match(word):
        held = places_holding(word)
        raise Stop(USAGE, "%s: a bare name names no place: %s", word, "call " + " or ".join(held) if held else
                                                                     "no place holds it; give a path (./%s) or a place" % word)
    return None


def places_holding(name):
    """[prefix:name] of each place that holds a baton of that name (for the refusal of a bare name)."""
    held = []
    for prefix in PLACES:
        try:
            if prefix == "kit":
                kit_path("kit:" + name)
            elif prefix == "kind":
                kind_path("kind:" + name)
            elif not os.path.lexists(Kept(prefix + ":" + name).path):
                continue
            held.append(prefix + ":" + name)
        except Stop:
            pass
    return held


GIT_TOP = {}


def git_top(cwd):
    """(top level, common git directory) of the repository the directory is in, both real paths; (None, None) outside git."""
    if cwd not in GIT_TOP:
        try:
            r = subprocess.run(["git", "rev-parse", "--show-toplevel", "--git-common-dir"], cwd=cwd, capture_output=True,
                               text=True, timeout=10)
            out = r.stdout.splitlines() if r.returncode == 0 else []
        except (OSError, subprocess.SubprocessError):
            out = []
        GIT_TOP[cwd] = ((os.path.realpath(out[0]), os.path.realpath(os.path.join(cwd, out[1]))) if len(out) == 2
                        else (None, None))
    return GIT_TOP[cwd]


def project_root():
    """(root, place key, in git) of `project:`: the git top level of the working directory unless that is HOME (a dotfiles
    repository); otherwise the nearest directory from here up that holds .vibemaestro/, HOME and / not included. The place key
    names the keep records: of git's common directory, so every worktree of a repository shares its pins. (None, None, False)
    when there is no root."""
    home = os.environ.get("HOME", "")
    home = os.path.realpath(home) if os.path.isabs(home) else None
    cwd = os.path.realpath(os.getcwd())
    top, common = git_top(cwd)
    if top and top != home:
        return top, "project-" + sha256(common)[:16], True
    d = cwd
    while d not in ("/", home):
        if os.path.isdir(os.path.join(d, ".vibemaestro")):
            return d, "project-" + sha256(d)[:16], False
        up = os.path.dirname(d)
        if up == d:
            break
        d = up
    return None, None, False


def library_dir():
    """The user library: $XDG_DATA_HOME/vibemaestro/batons (an absolute value only), else ~/.local/share/vibemaestro/batons."""
    x = os.environ.get("XDG_DATA_HOME", "")
    base = x if os.path.isabs(x) else os.path.join(os.path.expanduser("~"), ".local", "share")
    return os.path.join(base, "vibemaestro", "batons")


def loose_dir(path):
    """Why a directory of a project's place cannot be trusted (another user owns it, its group or others can write it), or None."""
    try:
        st = os.stat(path)
    except OSError:
        return None
    if st.st_uid != os.getuid() or st.st_mode & 0o022:
        return "%s is owned by uid %d, mode %o: a project root and its .vibemaestro/batons are yours and writable by you only" \
               % (esc(path), st.st_uid, stat.S_IMODE(st.st_mode))
    return None


class Kept:
    """A project: or user: baton: the file in its place, the place key of its keep records, and (after read) its pin."""

    def __init__(self, word):
        self.prefix, self.name = word.split(":", 1)
        if not KIT_RE.match(self.name) or len(self.name) > KEPT_NAME_MAX:
            raise Stop(USAGE, "%s: a kept baton is named by lower-case letters, digits and '-', at most %d characters", word, KEPT_NAME_MAX)
        self.word, self.git = word, False
        if self.prefix == "project":
            self.root, self.key, self.git = project_root()
            if self.root is None:
                raise Stop(NOINPUT, "%s: no project root here: not in a git repository (other than HOME), and no .vibemaestro/ "
                                    "from %s up to HOME", word, os.path.realpath(os.getcwd()))
            self.dir = os.path.join(self.root, ".vibemaestro", "batons")
            for p in (self.root, os.path.dirname(self.dir), self.dir):
                why = loose_dir(p)
                if why:
                    raise Stop(REFUSED, "%s: %s", word, why)
            want = os.path.join(self.root, ".vibemaestro", "batons")
        else:
            self.root, self.key, self.dir = None, "user", library_dir()
            want = os.path.join(os.path.realpath(os.path.dirname(os.path.dirname(self.dir))), "vibemaestro", "batons")
        if os.path.lexists(self.dir) and os.path.realpath(self.dir) != want:
            raise Stop(USAGE, "%s: the place %s leads to %s: a kept baton's place is never reached through a link", word, self.dir,
                       os.path.realpath(self.dir))
        self.path = os.path.join(self.dir, self.name + ".sh")
        self.pinned, self.by, self.newest, self.retired = False, None, None, False
        self.review, self.review_why = None, None

    def read(self):
        """(bytes, mtime) of the file, opened without following a link, at most KEPT_MAX bytes."""
        try:
            data, st = read_capped(self.path, KEPT_MAX)
        except OSError as e:
            if os.path.islink(self.path):
                raise Stop(USAGE, "%s: %s is a link to %s: a kept baton is never read through a link", self.word, self.path,
                           os.path.realpath(self.path))
            raise Stop(NOINPUT, "%s: no such baton in %s (%s)", self.word, self.dir, e.strerror or e)
        except ValueError as e:
            raise Stop(NOINPUT, "%s: %s %s: it cannot be called", self.word, self.path, e)
        return data, st.st_mtime

    def pin(self, sha):
        self.sha = sha
        self.pinned, self.by, self.newest, self.retired = pin_state(self.prefix, kept_records(self.key, self.name), sha)
        return self.pinned

    def reviewed(self, data):
        """True when these bytes run without a pin (Q2b): see reviewed_on. Sets review, or review_why for the refusal."""
        self.review, self.review_why = reviewed_on(self, data)
        return self.review is not None

    def label(self):
        if self.review:
            return "reviewed on %s %s" % (esc(self.review[0]), esc(self.review[1]))
        return kept_label(self.by) if self.by else "not kept on this machine"

    def refusal(self):
        """The rc 3 refusal of bytes that are not pinned: their sha, the name's newest keep, and what to do."""
        why = "these bytes were retired" if self.retired else "no keep record pins these bytes on this machine"
        msg = "%s: %s (sha256 %s, %s)" % (esc(self.word), why, self.sha, esc(self.path))
        if self.newest and self.newest.get("sha256") != self.sha:
            msg += "; %s was kept with sha256 %s, %s" % (self.word, self.newest.get("sha256"), kept_label(self.newest)[len("not reviewed, "):])
        if self.review_why:
            msg += "; origin's default branch does not stand in for a pin: %s" % self.review_why
        return msg + (". Read it; keep it only if you have read it and mean these bytes (run a scratch copy, then pack); a change "
                      "you did not expect goes to the owner")


def kept_records(key, name):
    """[(seq, record)] of the keep and retire records of (place key, name), oldest first. A keep record holds `sha256` (and
    place, root, name, params, stops, prev_sha256, kept_by, kept_at, and never_ran for a pod's keep of bytes that declare no
    stop, on a mode-manual stop); a retire record holds `retired` (and kept_by, kept_at).
    Each is <state>/kept/<place key>/<name>/<seq>.json, seq six digits; any other file there is not a record."""
    d = os.path.join(state_dir(), "kept", key, name)
    try:
        names = os.listdir(d)
    except OSError:
        return []
    out = []
    for n in names:
        m = re.match(r"([0-9]{6})\.json\Z", n)
        if not m:
            continue
        try:
            r = json.loads(read_small(os.path.join(d, n), 64 << 10))
        except (OSError, ValueError, RecursionError):
            continue
        if isinstance(r, dict) and (is_keep(r) or is_retire(r)):
            out.append((int(m.group(1)), r))
    return sorted(out, key=lambda x: x[0])


def is_keep(r):
    return isinstance(r.get("sha256"), str) and WORD_RE["sha256"].match(r["sha256"]) is not None and "retired" not in r


def is_retire(r):
    return isinstance(r.get("retired"), str) and WORD_RE["sha256"].match(r["retired"]) is not None


def pin_state(prefix, recs, sha):
    """(pinned, the keep that pins these bytes, the newest keep of the name, retired) for bytes of sha256 `sha`. project: a sha
    is pinned while the newest record naming it is a keep, so the versions of several branches each run. user: one file, no
    branches: the name is pinned only at its newest keep, and not at all once a later retire names that sha (no older keep
    comes back). retired: the newest record naming these bytes is a retire."""
    keeps = [(q, r) for q, r in recs if is_keep(r)]
    newest = keeps[-1] if keeps else None
    naming = [(q, r) for q, r in recs if (is_keep(r) and r["sha256"] == sha) or (is_retire(r) and r["retired"] == sha)]
    retired = bool(naming) and is_retire(naming[-1][1])
    if prefix == "project":
        by = naming[-1][1] if naming and not retired else None
    else:
        by = newest[1] if newest and newest[1]["sha256"] == sha and not any(
            q > newest[0] and is_retire(r) and r["retired"] == sha for q, r in recs) else None
    return by is not None, by, newest[1] if newest else None, retired


def kept_who(rec):
    """Who kept it, shortened: the first 8 characters of the session, then the seat and the intent, each only when it is a valid
    `name` value; `local` when none is. kept_by is an object {session, seat, intent} (each optional) or the word `local`."""
    kb = rec.get("kept_by") if isinstance(rec, dict) else None
    parts = []
    if isinstance(kb, dict):
        for k, cut in (("session", 8), ("seat", 100), ("intent", 100)):
            v = kb.get(k)
            if isinstance(v, str) and WORD_RE["name"].match(v):
                parts.append(v[:cut])
    return esc(" ".join(parts) or "local")


NEVER_RAN = "it never ran: Stops none, held only by a sandbox pod's mode manual, so the coordinator's go is its first run"


def kept_label(rec):
    """`not reviewed, kept by <who> <YYYY-MM-DD>`: the one label of a kept baton, on list, the sign line, go's line and the card;
    `, kept before any run` for a pod's keep of bytes that had not run (true for good, even after a later run)."""
    at = rec.get("kept_at") if isinstance(rec, dict) else None
    day = at[:10] if isinstance(at, str) and re.match(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", at) else "(no date)"
    return "not reviewed, kept by %s %s%s" % (kept_who(rec), day, ", kept before any run" if isinstance(rec, dict) and
                                              rec.get("never_ran") else "")


def drop_userinfo(url):
    """A remote URL without its userinfo (`https://<token>@host/…` or `user@host:path`): a token never reaches the transcript."""
    return re.sub(r"^(?:([A-Za-z][A-Za-z0-9+.-]*://)[^/@]*@|[^/@:]+@(?=[^/:]+:))", lambda m: m.group(1) or "", url)


def git_env():
    """The environment for the git that reads origin: the caller's without its GIT_* variables, so GIT_DIR, GIT_WORK_TREE or
    GIT_CONFIG_* cannot lead the read to another repository."""
    return dict((k, v) for k, v in os.environ.items() if not k.startswith("GIT_"))


def top_of(root):
    """git's top level of `root` read as git_top reads it (the first line, whitespace kept), without GIT_*; None outside git."""
    r = subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=root, capture_output=True, text=True, timeout=10, env=git_env())
    out = r.stdout.splitlines() if r.returncode == 0 else []
    return os.path.realpath(out[0]) if out else None


def origin_blobs(root):
    """(url, branch, {name: blob id}, object format, the repository's top) of the project batons on origin's default branch, read
    from the local ref
    refs/remotes/origin/HEAD, which must name a branch of origin (refs/remotes/origin/<branch>, never a local branch); None
    without it or without git."""
    def git(*a):
        r = subprocess.run(["git"] + list(a), cwd=root, capture_output=True, text=True, timeout=10, env=git_env())
        return r.stdout.strip() if r.returncode == 0 else None
    try:
        ref = git("symbolic-ref", "-q", "refs/remotes/origin/HEAD")
        if not ref or not ref.startswith("refs/remotes/origin/"):
            return None
        fmt = git("rev-parse", "--show-object-format") or "sha1"
        top = top_of(root)
        listing = git("ls-tree", "--full-tree", ref, "--", ".vibemaestro/batons/") or ""   # from the top: a second guard
        url = git("remote", "get-url", "origin") or "(no url)"            # the URL git fetches from (insteadOf, the first one)
    except (OSError, subprocess.SubprocessError):
        return None
    blobs = {}
    for ln in listing.splitlines():
        m = re.match(r"100(?:644|755) blob ([0-9a-f]+)\t\.vibemaestro/batons/([a-z0-9][a-z0-9-]*)\.sh\Z", ln)
        if m:
            blobs[m.group(2)] = m.group(1)
    return drop_userinfo(url), ref[len("refs/remotes/origin/"):], blobs, fmt, top


def blob_id(data, fmt):
    h = hashlib.new("sha256" if fmt == "sha256" else "sha1")
    h.update(b"blob %d\0" % len(data) + data)
    return h.hexdigest()


def origin_note(kept, data, blobs=None):
    """`(matches origin <url> <branch>)` when the bytes that run are, as a git blob, the blob at the baton's path on origin's
    default branch; "" otherwise. Shown beside the label, never instead of it, and it never makes a baton callable. kept: a
    Kept, or (prefix, name, root, in git)."""
    prefix, name, root, git = (kept.prefix, kept.name, kept.root, kept.git) if isinstance(kept, Kept) else kept
    if prefix != "project" or not git or isinstance(kept, Kept) and kept.review:     # a reviewed label already names origin
        return ""
    got = blobs if blobs is not None else origin_blobs(root)
    if not got or got[2].get(name) != blob_id(data, got[3]) or got[4] != os.path.realpath(root):
        return ""
    return " (matches origin %s %s)" % (esc(got[0]), esc(got[1]))


# Q2b: the owner's remote list. A project baton whose bytes are the blob on origin's default branch runs without a pin only when
# origin is on it; the list is the owner's, set with `mode trust|untrust` (each change takes the owner's dialog record), and
# empty until the owner sets it
_REMOTE_HOST = re.compile(r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+(?::[0-9]{1,5})?\Z")
_REMOTE_SEG = re.compile(r"[A-Za-z0-9_~][A-Za-z0-9._~-]*\Z")


def remote_canon(url, strict=False):
    """The canonical form of a network remote, `host/path`: no scheme, userinfo, trailing `/` or `.git`, `git@host:path` as
    host/path, the host lower-cased (`github.com/owner/repo`); None for anything else (a local path, a file:
    URL, a host with no dot or no path, a `.` or `..` segment, a character outside the URL's plain ones). strict: a URL git
    reads, where `host/path` is a relative local path, so only `scheme://` and `host:path` count."""
    if not isinstance(url, str) or not re.match(r"[\x21-\x7e]+\Z", url):
        return None
    u = drop_userinfo(url)
    m = re.match(r"([A-Za-z][A-Za-z0-9+.-]*)://([^/]*)/(.*)\Z", u)
    if m:
        if m.group(1).lower() not in ("https", "http", "ssh", "git", "git+ssh", "ssh+git"):
            return None
        host, path = m.group(2), m.group(3)
    else:
        m = re.match(r"([^/:]+):([^/].*)\Z", u) or (None if strict else re.match(r"([^/:]+)/(.+)\Z", u))
        if not m:
            return None
        host, path = m.group(1), m.group(2)
    path = path.rstrip("/")
    path = (path[:-4] if path.endswith(".git") and not path.endswith("/.git") else path).rstrip("/")
    segs = path.split("/")
    if not _REMOTE_HOST.match(host.lower()) or not path or not all(_REMOTE_SEG.match(x) and x not in (".", "..") for x in segs):
        return None
    return host.lower() + "/" + path


def plain_remote(word):
    """`word` names a network remote with no userinfo (a user or token before `@`), git's own `git@host:path` aside: what a
    trust dialog shows is then the remote written, never a trusted-looking host placed before `@` and another host after it."""
    return remote_canon(word) is not None and (drop_userinfo(word) == word or re.fullmatch(r"git@[^@/:]+:[^@]+", word) is not None)


def remotes_path():
    return os.path.join(state_dir(), "remotes")


# A mode or remote list file counts only with the line `dialog <id>` of the owner's dialog record that set it (cmd_mode,
# cmd_remotes): a copy of baton.py from before the record (an older version left in the plugin cache, a checkout) writes no
# such line, so what it writes, through any wrapper, reads as not chosen. Writing the line by hand is forgery of the state.
PROOF_LINE = re.compile(r"dialog [0-9a-f]{32}\Z")


def proven(lines):
    return any(PROOF_LINE.match(ln.strip()) for ln in lines)


def read_remotes():
    """The owner's remote list, in its file's order: each line that is a canonical remote (any other line is not on it). No
    file, or one without the owner's dialog line (PROOF_LINE), is the empty list."""
    try:
        text = read_small(remotes_path(), 64 << 10)
    except (OSError, ValueError):
        return []
    lines = text.split("\n")
    if not proven(lines):
        return []
    out = []
    for ln in lines:
        if ln and remote_canon(ln) == ln and ln not in out:
            out.append(ln)
    return out


def reviewed_on(kept, data, blobs=None):
    """((url, branch), None) when the bytes that run may run without a pin (Q2b): a project: baton in git whose bytes are, as a
    git blob, the blob at its path on origin's default branch, origin's URL on the owner's remote list; else (None, why), why
    None when there is nothing to say (user:, no git). kept: a Kept, or (prefix, name, root, in git)."""
    prefix, name, root, git = (kept.prefix, kept.name, kept.root, kept.git) if isinstance(kept, Kept) else kept
    if prefix != "project":
        return None, None
    if not git:
        return None, "the project root is not in git"
    got = blobs if blobs is not None else origin_blobs(root)
    if not got:
        return None, "no refs/remotes/origin/HEAD naming a branch of origin"
    if got[4] != os.path.realpath(root):
        return None, "the project root %s is not the top of its repository (%s)" % (esc(root), esc(got[4] or "unknown"))
    if got[2].get(name) != blob_id(data, got[3]):
        return None, "these bytes are not the blob at .vibemaestro/batons/%s.sh on origin %s" % (name, esc(got[1]))
    canon = remote_canon(got[0], strict=True)
    if canon not in read_remotes():
        return None, ("%s is not on the owner's remote list (`mode remotes`; the owner sets it)" % esc(canon) if canon else
                      "%s is not a network remote (a relative or local path, a file: URL, a host with no dot or a URL "
                      "ending in /.git is never on the list)" % esc(got[0]))
    return (got[0], got[1]), None


# Params: the declaration, the values of a call, and how they reach the script
def parse_params(value):
    """([(key, type, arg)], problems) of a `# Params:` value: `none`, or key=type words separated by single spaces. arg is the
    directory of `under:` and the words of `enum:`, else None."""
    if value == "none":
        return [], []
    if not value:
        return [], ["Params: empty; write `none`, or key=type words"]
    decls, probs, seen = [], [], set()
    toks = value.split(" ")
    if "" in toks:
        return [], ["Params: separate its key=type words by single spaces"]
    for tok in toks:
        key, eq, typ = tok.partition("=")
        if not eq or not PARAM_KEY.match(key):
            probs.append("Params: %s is not <key>=<type>, a key of [a-z][a-z0-9_] (at most 32)" % esc(tok))
            continue
        if key in seen:
            probs.append("Params: the key %s is given twice" % key)
            continue
        seen.add(key)
        if SECRET_KEY.search(key):
            probs.append("Params: the key %s names a secret (token, secret, passw, credential, apikey): a baton holds no secret, "
                         "and values are logged" % key)
        if typ in PARAM_TYPES:
            decls.append((key, typ, None))
        elif typ.startswith("under:") and under_base_problem(typ[len("under:"):]) is None:
            decls.append((key, "under", typ[len("under:"):]))
        elif typ.startswith("enum:") and all(WORD_RE["name"].match(w) for w in typ[len("enum:"):].split("|")):
            decls.append((key, "enum", tuple(typ[len("enum:"):].split("|"))))
        else:
            probs.append("Params: %s=%s: the type is one of %s, under:<an absolute directory, ~ or ~/dir>, or enum:<name>|<name>…"
                         % (key, esc(typ), ", ".join(PARAM_TYPES)))
    if len(seen) > PARAMS_KEYS_MAX:
        probs.append("Params: %d keys, at most %d (a list goes through a file parameter)" % (len(seen), PARAMS_KEYS_MAX))
    return decls, probs


def under_base_problem(d):
    if d == "~":
        return None
    return path_problem("/" + d[2:] if d.startswith("~/") else d)


def path_problem(v):
    """Why v is not a `path` value, or None: absolute, of [A-Za-z0-9._/@+-], at most 1024 characters, no . or .. segment, no //,
    no trailing /, no last segment (the basename) that starts with -, + or @: a middle segment may, as Claude Code's scratchpad does."""
    if not v.startswith("/"):
        return "is not an absolute path"
    if len(v) > 1024:
        return "is longer than 1024 characters"
    if not PATH_CHARS.match(v):
        return "holds a character outside [A-Za-z0-9._/@+-]"
    if "//" in v or v.endswith("/"):
        return "holds // or ends with /"
    segs = v.split("/")[1:]
    for seg in segs:
        if seg in (".", ".."):
            return "has a . or .. segment"
    if segs[-1][0] in "-+@":
        return "has a last segment that starts with %s" % segs[-1][0]
    return None


def ref_problem(v):
    if not REF_CHARS.match(v):
        return "is not 1 to 200 characters of [A-Za-z0-9._/-]"
    parts = v.split("/")
    if ".." in v or "//" in v or v[0] in "/.-" or v[-1] in "/." or any(p.startswith(".") or p.endswith(".lock") for p in parts):
        return "is not a name git check-ref-format accepts (no .., //, leading / . -, trailing / . or .lock)"
    if REF_SHADOWS.match(v) or parts[0] in ("refs", "heads", "tags", "remotes"):
        return ("is a name git resolves first as another ref (HEAD, *_HEAD, AUTO_MERGE, BISECT_EXPECTED_REV, a first component "
                "refs, heads, tags or remotes, a full SHA)")
    return None


def url_problem(v):
    m = URL_RE.match(v) if len(v) <= 2048 else None
    if not m:
        return "is not https://<host>[:<port>][/<path>], at most 2048 characters, with no userinfo, query or fragment"
    host, port, path = m.groups()
    labels = host.split(".")
    if re.match(r"[0-9.]+\Z", host):
        if len(labels) != 4 or not all(re.match(r"(?:0|[1-9][0-9]{0,2})\Z", x) and int(x) < 256 for x in labels):
            return "has a host that is not an IPv4 address"
    elif len(host) > 253 or not all(DNS_LABEL.match(x) for x in labels):
        return "has a host that is not lower-case DNS labels"
    if port and int(port) > 65535:
        return "has a port over 65535"
    p = path_problem(path) if path is not None else None
    return "has a path that " + p if p else None


def value_problem(typ, arg, v, home):
    """Why v is not a value of the type, or None. Every type refuses an empty value, a leading - + : @ = ~ %, any control,
    format or separator character, and bytes that are not UTF-8. A file or input value is read later (bind_call)."""
    if not v:
        return "is empty"
    if v[0] in LEAD_REFUSED:
        return "starts with %s" % v[0]
    try:
        v.encode("utf-8")
    except UnicodeEncodeError:
        return "is not valid UTF-8"
    for c in v:
        if ord(c) < 0x20 or 0x7f <= ord(c) <= 0x9f:
            return "holds a control character (%s)" % esc(c)
        if unicodedata.category(c) in ("Cf", "Zl", "Zp"):
            return "holds a format or separator character (%s)" % esc(c)
    if typ in WORD_RE:
        return None if WORD_RE[typ].match(v) else "is not a %s value (%s)" % (typ, WORD_RE[typ].pattern[:-2])
    if typ == "ref":
        return ref_problem(v)
    if typ == "url":
        return url_problem(v)
    if typ == "enum":
        return None if v in arg else "is not one of %s" % "|".join(arg)
    p = path_problem(v)
    if p:
        return p
    if typ == "under":
        base = home + arg[1:] if arg == "~" or arg.startswith("~/") else arg
        if v != base and not v.startswith(base + "/"):
            return "is neither %s nor under it" % base
    if in_state(v):
        return "names the baton state directory (%s), which no baton writes through a value" % state_dir()
    return None


def in_state(v):
    """True when the path, or what it resolves to, is the state directory or under it (its records, signatures, mode, launcher)."""
    st = state_dir()
    bases = set([st, os.path.realpath(st)])
    return any(p == b or p.startswith(b + "/") for b in bases for p in set([v, os.path.realpath(v)]))


def read_value_file(v):
    """(bytes, mtime) of a file value, or a problem text: a regular file, opened without following a link in its last part,
    at most FILE_MAX bytes, its name at most BASENAME_MAX bytes."""
    if len(os.path.basename(v).encode("utf-8")) > BASENAME_MAX:
        return None, "has a file name over %d bytes" % BASENAME_MAX
    try:
        data, st = read_capped(v, FILE_MAX)
    except OSError as e:
        return None, "cannot be read as a file (%s; a link is never followed)" % (e.strerror or e)
    except ValueError as e:
        return None, str(e)
    return (data, st.st_mtime), None


def secret_problem(data):
    """The refusal of a file or input value whose bytes look like key material (SECRET_CONTENT), naming the kind and never the
    bytes, or None. One verdict per content in a process: go binds the same values more than once."""
    sha = hashlib.sha256(data).digest()
    if sha not in SECRET_SEEN:
        SECRET_SEEN[sha] = next((kind for kind, rx in SECRET_CONTENT for m in rx.finditer(data)
                                 if len(set(next((g for g in m.groups() if g), m.group()))) >= 4), None)
    if SECRET_SEEN[sha] is None:
        return None
    return ("looks like a secret (%s): a file or input value is copied under the state directory and a run's copy is kept, so a secret is never "
            "one; declare it as a path Param under a key that names no secret (key_file, not token): the script reads it where "
            "it is (into a command's stdin, never printed) and nothing copies it. Text that only quotes a secret's shape: "
            "reword it" % SECRET_SEEN[sha])


SECRET_SEEN = {}

# A bound value that names a Claude Code settings file, or a settings directory itself, makes the call security-boundary
# whatever Stops says: `check` reads the text, so a script that writes "$1" or a Params value is seen only here, by the value.
# A settings directory is one named .claude (any case), the managed one (MANAGED_SETTINGS) or one CLAUDE_CONFIG_DIR names; a
# settings file has SETTINGS_FILE's name right in one; a subdirectory of one is not one. A value is read as one path.
SETTINGS_FILE_NAME = re.compile(r"\A" + SETTINGS_FILE + r"\Z")
SETTINGS_NAMES = ("settings.json", "settings.local.json", "managed-settings.json")   # what a glob in the name is tried on
GLOB_CHARS = re.compile(r"[*?\[]")
VAR_DEFAULT = re.compile(r"\$\{(\w+):?[-=]([^}]*)\}")                    # ${X:-d}, ${X-d}, ${X:=d}, ${X=d}
CONFIG_DIRS, SETTINGS_IDS = [], []                      # read once per process


def config_dirs():
    """The directories CLAUDE_CONFIG_DIR names, in baton's environment and in each ancestor's (the session's), absolute ones only,
    as written and with links followed."""
    if not CONFIG_DIRS:
        dirs = [os.environ.get("CLAUDE_CONFIG_DIR", "")] + [cfg for _a, _c, cfg, _h in ancestors()]
        CONFIG_DIRS.append(set(p for d in dirs if d and os.path.isabs(d) for p in (os.path.normpath(d), os.path.realpath(d))))
    return CONFIG_DIRS[0]


def settings_dir(p):
    return os.path.basename(p).lower() == ".claude" or p in config_dirs() or p in [os.path.dirname(m) for m in MANAGED_SETTINGS]


def settings_kind(p):
    """"file" when the absolute path p is a Claude Code settings file, "directory" when it is a settings directory, else None."""
    if settings_dir(p):
        return "directory"
    d, name = os.path.split(p)
    if settings_dir(d) and (SETTINGS_FILE_NAME.match(name)
                            or (GLOB_CHARS.search(name) and any(fnmatch.fnmatchcase(n, name.lower()) for n in SETTINGS_NAMES))):
        return "file"
    return None


def settings_ids():
    """{(st_dev, st_ino): (kind, path)} of the settings directories baton knows (the config directories, ~/.claude, the managed
    one, the .claude of the directory and of each one above it) and of the settings files in them, links followed: another
    name of one (a hard link, the file or directory a settings link points to) is the same file."""
    if not SETTINGS_IDS:
        dirs, d = set(config_dirs()) | set([os.path.join(os.path.expanduser("~"), ".claude")]), os.getcwd()
        dirs |= set(os.path.dirname(m) for m in MANAGED_SETTINGS)
        while True:
            dirs.add(os.path.join(d, ".claude"))
            if os.path.dirname(d) == d:
                break
            d = os.path.dirname(d)
        ids = {}
        for d in sorted(dirs):
            files = [f for f in sorted(glob.glob(os.path.join(glob.escape(d), "*.json")))     # no cap: a decoy never hides one
                     if SETTINGS_FILE_NAME.match(os.path.basename(f))]
            for kind, f in [("directory", d)] + [("file", f) for f in files]:
                try:
                    st = os.stat(f)
                except (OSError, ValueError):
                    continue
                m = st.st_mode                          # a link to /dev/null (a device) or a directory is no settings file
                if stat.S_ISDIR(m) if kind == "directory" else not (stat.S_ISDIR(m) or stat.S_ISCHR(m) or stat.S_ISBLK(m)):
                    ids.setdefault((st.st_dev, st.st_ino), (kind, f))
        SETTINGS_IDS.append(ids)
    return SETTINGS_IDS[0]


def value_paths(v, cwd):
    """The absolute paths a value may name: the value; without surrounding blanks and one pair of quotes; the part after its first
    `=`; without a leading file://. Each with $CLAUDE_CONFIG_DIR, other $VAR, ${VAR:-default} and ~ expanded and joined to cwd,
    as written (`..` folded) and with links followed; a glob in it expanded against the disk."""
    unq = lambda c: c[1:-1] if len(c) >= 2 and c[0] == c[-1] and c[0] in "'\"" else c
    cands = [v, unq(v.strip())]
    cands += [unq(c.split("=", 1)[1].strip()) for c in list(cands) if "=" in c]
    cands += [c[len("file://"):] for c in list(cands) if c[:7].lower() == "file://"]
    cfg = os.environ.get("CLAUDE_CONFIG_DIR", "")
    cfg = cfg if os.path.isabs(cfg) else os.path.join(os.path.expanduser("~"), ".claude")
    env = lambda name, dflt: cfg if name == "CLAUDE_CONFIG_DIR" else os.environ.get(name) or dflt
    out = []
    for c in cands:
        if not c:
            continue
        try:                                            # a NUL (a queued item's JSON) is no path
            c = re.sub(r"\$(?:CLAUDE_CONFIG_DIR\b|\{CLAUDE_CONFIG_DIR\})", lambda _m: cfg, c)
            c = os.path.expanduser(os.path.expandvars(VAR_DEFAULT.sub(lambda m: env(m.group(1), m.group(2)), c)))
            p = os.path.join(cwd, c)
            out += [os.path.normpath(p), os.path.realpath(p)]
            if GLOB_CHARS.search(c):
                out += [q for g in sorted(glob.glob(p))[:64] for q in (os.path.normpath(g), os.path.realpath(g))]
        except (OSError, ValueError):
            continue
    return list(dict.fromkeys(out))


def settings_value(pairs):
    """(label, value, what, path) of the first (label, value) pair whose value names a Claude Code settings file or directory,
    by its path or as another name of one (settings_ids), else None. A regular file with more than one hard link that is not
    one of those is "linked": its other names may be a settings file in a .claude no search reaches, so it counts as one."""
    cwd = os.getcwd()
    for label, v in pairs:
        for p in value_paths(v, cwd):
            kind = settings_kind(p)
            if kind:
                return label, v, kind, p
            try:
                st = os.stat(p)
            except (OSError, ValueError):
                continue
            hit = settings_ids().get((st.st_dev, st.st_ino))
            if hit:
                return (label, v) + hit
            if stat.S_ISREG(st.st_mode) and st.st_nlink > 1:
                return label, v, "linked", "%s, %d hard links" % (p, st.st_nlink)
    return None


def bind_call(s, args):
    """The binding words of a call. For a baton with Params: the key=value words in the declared order once every word is
    checked; s.argv (the script's arguments: the values, a file value as its copy), s.inputs ({key: sha256}), s.values and
    s.param_lines (the card lines) are set; any problem is Stop(USAGE) naming each one and the declared Params. Without Params
    the words are the arguments as given. s.value_stop: the value that names a Claude Code settings file (settings_value), or None."""
    if s.params is None:
        s.value_stop = settings_value(("argument %d" % (i + 1), a) for i, a in enumerate(args))
        return list(args)
    if s.params_problems:
        raise Stop(USAGE, "%s: its Params line does not parse: %s", s.path, "; ".join(s.params_problems))
    declared = dict((k, (t, a)) for k, t, a in s.params)
    probs, vals = [], {}
    for w in args:
        key, eq, v = w.partition("=")
        if not eq:
            probs.append("%s: no '=': each word after the baton is key=value" % quoted(w))
        elif key not in declared:
            probs.append("%s: no such key" % quoted(key))
        elif key in vals:
            probs.append("%s: given twice" % key)
        else:
            vals[key] = v
    probs += ["%s: missing" % k for k, _t, _a in s.params if k not in vals]
    home = os.environ.get("HOME", "")
    if any(t == "under" and (a == "~" or a.startswith("~/")) for _k, t, a in s.params) and not os.path.isabs(home):
        probs.append("HOME is %s, not absolute: an under:~ parameter has no base" % quoted(home))
    home = home.rstrip("/")
    files = {}
    for k, t, a in s.params:
        if k not in vals:
            continue
        p = value_problem(t, a, vals[k], home)
        if p is None and t in ("file", "input"):
            files[k], p = read_value_file(vals[k])
            if p is None:
                p = secret_problem(files[k][0])
        if p:
            probs.append("%s=%s: %s" % (k, quoted(vals[k]), p))
    total = sum(len(v.encode("utf-8", "surrogateescape")) for v in vals.values())
    if total > VALUES_MAX:
        probs.append("the values total %d bytes, over %d: a long body goes through a file or input parameter" % (total, VALUES_MAX))
    if probs:
        raise Stop(USAGE, "the call does not fit %s:\n%s\n  # Params: %s", s.word, shown_join("\n", ["  " + p for p in probs]),
                   s.field("Params"))
    s.value_stop = settings_value((k, vals[k]) for k, _t, _a in s.params)
    words, argv, inputs, lines, s.input_mtimes = [], [], {}, [], {}
    for k, t, _a in s.params:
        v = vals[k]
        words.append("%s=%s" % (k, v))
        if t in ("file", "input"):
            data, mtime = files[k]
            inputs[k] = sha256(data)
            copy = input_copy(v, data, inputs[k])
            argv.append(copy)
            s.input_mtimes[k] = (v, mtime, inputs[k], t)
            lines.append("param %s = %s sha256 %s copy %s" % (k, quoted(v), inputs[k], esc(copy)))
        else:
            argv.append(v)
            lines.append("param %s = %s" % (k, quoted(v)))
    s.argv, s.inputs, s.values, s.param_lines = argv, inputs, vals, lines
    return words


def input_copy(v, data, sha):
    """The read-only copy a file value reaches the script as: <state>/inputs/<sha256>.<basename>/<basename>, written once
    through a temporary directory and a rename (file 0400, directory 0500), held (hold_copy) and checked like any existing copy.
    A copy that does not hold its bytes is removed and logged, and this step is refused (rc 3): the next call makes it again.
    One another baton process holds is left to it, and this step is refused too."""
    d = ensure_state()
    real = os.path.realpath(d)
    if path_problem(real):
        raise Stop(USAGE, "the state directory %s %s, so a file value's copy would not be a plain path: set XDG_STATE_HOME to "
                          "an absolute path of [A-Za-z0-9._/@+-]", real, path_problem(real))
    top = os.path.join(real, "inputs")
    base = os.path.basename(v)
    final = os.path.join(top, "%s.%s" % (sha, base))
    try:
        os.makedirs(top, mode=0o700, exist_ok=True)
        HELD_COPIES.setdefault(final, None)             # before it is made: a stop from here on still removes it
        for _attempt in range(3):                       # a copy another process removed meanwhile is made again
            if not os.path.lexists(final):
                make_copy(top, final, base, data)
            if hold_copy(final):
                break
        why = copy_problem(final, base, sha)
        if why:
            release_copy(final)
            if not remove_if_free(final):
                raise Stop(REFUSED, "the input copy %s %s, not sha256 %s, and another baton process holds it: nothing ran; "
                                    "call again once it ended", os.path.join(final, base), why, sha)
            log_event(d, event="input-copy", result="mismatch", output="%s: %s; removed" % (final, why))
            raise Stop(REFUSED, "the input copy %s %s, not sha256 %s: it was removed; nothing ran, and the next call makes it "
                                "again from the file", os.path.join(final, base), why, sha)
        if HELD_COPIES.get(final) is None:
            raise Stop(REFUSED, "the input copy %s was removed by another baton process each time it was made: nothing ran; "
                                "call again", os.path.join(final, base))
        os.utime(final)                                 # in use: the newest INPUTS_KEPT copies stay
    except OSError as e:
        raise Stop(ENV, "the input copy %s cannot be made: %s", final, e.strerror or e)
    prune_inputs(top)
    return os.path.join(final, base)


# A copy lives for the process that binds it, unless that process runs: each process holds a shared lock on every copy it bound
# (HELD_COPIES) until it ends, and one that never started a run phase removes them then (drop_copies), each only when no other
# baton process holds it. A copy a run used stays until the newest INPUTS_KEPT rule or a later call of the same bytes that never
# runs removes it. A process killed outright cannot remove its copy: the INPUTS_KEPT rule does.
HELD_COPIES = {}                                        # {copy directory: fd holding its shared lock, or None (not held yet)}


def hold_copy(final):
    """True once this process holds a shared lock on the copy directory at `final` (opened without following a link), the one
    still at that path; False when it was removed or replaced while the lock was taken."""
    if HELD_COPIES.get(final) is not None:
        return True
    try:
        fd = os.open(final, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0))
    except OSError:
        return False                                    # not a directory of its own: copy_problem names it
    try:
        fcntl.flock(fd, fcntl.LOCK_SH)
        if os.path.samestat(os.fstat(fd), os.lstat(final)):
            HELD_COPIES[final] = fd
            return True
    except OSError:
        pass
    os.close(fd)
    return False


def release_copy(final):
    fd = HELD_COPIES.get(final)
    HELD_COPIES[final] = None
    if fd is not None:
        os.close(fd)


def remove_if_free(path):
    """Remove a copy directory (or a link where one should be) when no baton process holds it: the exclusive lock, taken at
    once, is held while it goes. A directory that cannot be opened cannot be held either, so it goes too. True when it went."""
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0))
    except OSError as e:
        if e.errno == errno.ENOENT:
            return True
        if e.errno not in (errno.ELOOP, errno.ENOTDIR, errno.EACCES, errno.EPERM):
            return False                                # out of descriptors or memory: nothing known, nothing removed
        remove_tree(path)                               # a link, a file, a directory of mode 0: never held
        return not os.path.lexists(path)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if not os.path.samestat(os.fstat(fd), os.lstat(path)):
            return False
        remove_tree(path)
        return True
    except OSError:
        return False
    finally:
        os.close(fd)


def drop_copies():
    """At the end of a process: release every copy it held, and remove each when no run phase started (RUN["consumed"]). The stop
    signals wait meanwhile, so a second interrupt does not leave a copy behind."""
    mask = signal.pthread_sigmask(signal.SIG_BLOCK, (signal.SIGTERM, signal.SIGHUP, signal.SIGINT))
    try:
        for final in list(HELD_COPIES):
            release_copy(final)
            if not RUN["consumed"]:
                remove_if_free(final)
            del HELD_COPIES[final]
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, mask)


def make_copy(top, final, base, data):
    tmp = tempfile.mkdtemp(prefix=".tmp-", dir=top)
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        fd = os.open(os.path.join(tmp, base), flags, 0o400)
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.chmod(os.path.join(tmp, base), 0o400)
        os.chmod(tmp, 0o500)
        try:
            os.rename(tmp, final)                       # an existing copy stays: the caller checks it
        except OSError:
            pass
    finally:
        if os.path.lexists(tmp):
            remove_tree(tmp)


def copy_problem(final, base, sha):
    """Why the copy at final/base is not the bytes of sha256 `sha` in a 0500 directory and a 0400 regular file of this user,
    or None. The directory is opened without following a link, and the file through it."""
    try:
        dfd = os.open(final, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0))
    except OSError as e:
        return "is not a directory of its own (%s)" % (e.strerror or e)
    try:
        st = os.fstat(dfd)
        if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o500:
            return "is in a directory that is not yours with mode 500"
        try:
            fd = os.open(base, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0), dir_fd=dfd)
        except OSError as e:
            return "cannot be opened (%s)" % (e.strerror or e)
        try:
            st = os.fstat(fd)
            if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o400:
                return "is not a regular file of yours with mode 400"
            chunks = []
            while True:
                b = os.read(fd, 1 << 16)
                if not b:
                    break
                chunks.append(b)
        finally:
            os.close(fd)
        got = sha256(b"".join(chunks))
        return None if got == sha else "holds sha256 %s" % got
    finally:
        os.close(dfd)


def remove_tree(path):
    """Remove a copy directory baton made read-only; a link is removed itself, never followed."""
    try:
        if os.path.islink(path) or not os.path.isdir(path):
            os.unlink(path)
            return
        for root, dirs, _files in os.walk(path):
            for x in dirs:
                if not os.path.islink(os.path.join(root, x)):
                    os.chmod(os.path.join(root, x), 0o700)
        os.chmod(path, 0o700)
    except OSError:
        pass
    shutil.rmtree(path, ignore_errors=True)


def prune_inputs(top):
    """Keep the newest INPUTS_KEPT copies (by the time each was last used), as stdin/ keeps its scripts, the newest 20 copies set
    aside on a mismatch, and no temporary directory older than an hour (a make_copy that was killed). A copy another baton
    process holds (hold_copy) is never removed."""
    try:
        names = os.listdir(top)
        when = dict((n, os.lstat(os.path.join(top, n)).st_mtime) for n in names)
    except OSError:
        return
    for pattern, keep in ((r"[0-9a-f]{64}\.", INPUTS_KEPT), (r"\.mismatch-", 20)):
        group = sorted((n for n in names if re.match(pattern, n)), key=lambda n: when[n])
        for n in group[:-keep]:
            remove_if_free(os.path.join(top, n))      # a copy another process holds stays
    for n in names:
        if n.startswith(".tmp-") and time.time() - when[n] > 3600:
            remove_tree(os.path.join(top, n))


def input_staleness(s):
    """(key, path, why, sha256) of the first `input` value older than FRESH_SECONDS, else None: an input file is written for
    this call. go checks it (unless --reuse); sign and run do not, so a signature made later still runs."""
    for k, (v, mtime, sha, t) in sorted(getattr(s, "input_mtimes", {}).items()):
        why = staleness(mtime) if t == "input" else None
        if why:
            return k, v, why, sha
    return None


# Targets of a baton with Params: testable patterns
def target_looking(w):
    """A word that names a target: an absolute path, owner/name (optionally #<n>), <host>:/<path>, a URL, a refs/ name."""
    return (w.startswith("/") or "://" in w or w.startswith("refs/") or re.match(r"[^\s/:]+:/", w) is not None
            or re.match(r"[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9][A-Za-z0-9._-]{0,99}(?:#[0-9]+)?\Z", w) is not None)


def target_patterns(s):
    """([pattern], problems): the words of the Targets value before ` — `, each literal text with {key} placeholders of
    declared word keys, or a target-looking word as written; `*` only as a trailing /** right after a placeholder."""
    head = s.field("Targets").split(TARGET_SEP, 1)[0]
    words, probs = head.split(), []
    types = dict((k, t) for k, t, _a in s.params or [])
    if not words:
        probs.append("no pattern before ' \u2014 '")
    for w in words:
        keys = PLACEHOLDER.findall(w)
        rest = PLACEHOLDER.sub("", w)
        if [k for k in keys if k not in types]:
            probs.append("%s names %s, not a declared key" % (esc(w), ", ".join(k for k in keys if k not in types)))
        elif [k for k in keys if types[k] not in TARGET_TYPES]:
            probs.append("%s holds a %s placeholder: file and input values are never targets"
                         % (esc(w), "/".join(types[k] for k in keys if types[k] not in TARGET_TYPES)))
        if "{" in rest or "}" in rest:
            probs.append("%s holds a brace that is not a {key} placeholder" % esc(w))
        if "*" in w and not (w.count("*") == 2 and w.endswith("}/**")):
            probs.append("%s: `*` only as a trailing /** right after a placeholder" % esc(w))
        if not keys and not target_looking(w):
            probs.append("%s is neither a pattern with a placeholder nor a target-looking word" % esc(w))
    return words, probs


def targets_table(s, plan):
    """(table lines, reasons) of the plan against the declared Targets, for a baton with Params whose Targets parse; ([], [])
    for any other. Every plan line holds a declared target as a whole word, and every target-looking word before its first
    ` — ` matches one; a word with a .. segment fails first; a copy under <state>/inputs and a run record under
    <state>/records are exempt from both."""
    if s.params is None or getattr(s, "values", None) is None:
        return [], []
    patterns, probs = target_patterns(s)
    if probs:
        return [], []
    vals = s.values
    declared = [PLACEHOLDER.sub(lambda m: vals.get(m.group(1), ""), p) for p in patterns]
    st = [state_dir(), os.path.realpath(state_dir())]
    exempt = tuple(os.path.join(b, sub) + "/" for b in st for sub in ("inputs", "records"))

    def matches(w):
        return any(w == d or (d.endswith("/**") and (w == d[:-3] or w.startswith(d[:-2]))) for d in declared)

    table, reasons = ["== plan against Targets (%s)" % esc(" ".join(declared))], []
    for i, line in enumerate(plan):
        words = line.split(TARGET_SEP, 1)[0].split()
        why = None
        for w in words:
            if ".." in re.split(r"[/=:]", w):          # any word, after `/`, `=` or `:`: a plan line names resolved paths
                why = "%s has a .. segment" % esc(w)
                break
        if why is None:
            live = [w for w in words if not w.startswith(exempt)]
            outside = [w for w in live if target_looking(w) and not matches(w)]
            if outside:
                why = "%s is not a declared target" % esc(outside[0])
            elif not any(matches(w) for w in live):
                why = "it names no declared target"
        table.append("  %s %s" % ("FAIL" if why else "ok  ", esc(line)))
        if why and len(reasons) < 10:
            reasons.append("plan line %d is outside the declared Targets: %s" % (i + 1, why))
    return table, reasons


class Script:
    def __init__(self, path, pin=True, data=None):
        """pin: a project: or user: baton must be pinned on this machine (every step that runs it); check reads it unpinned.
        data: the bytes of a project: or user: baton not read from its file (pack checks a source as its target place would)."""
        self.word, self.place = path, place_of(path)
        self.kit = self.place == "kit"
        self.kind = path[len("kind:"):] if path.startswith("kind:") else None
        self.from_kit = kit_path(path) if self.kit else None
        self.kept = Kept(path) if self.place in ("project", "user") else None
        if self.kit:
            path = self.from_kit.path
        elif self.kind is not None:
            path = kind_path(path)
        elif self.kept is not None:
            path = self.kept.path
        self.path = path
        if self.kept is not None and data is not None:
            self.data, self.mtime, pin = data, None, False
        elif self.kept is not None:
            self.data, self.mtime = self.kept.read()
        else:
            try:
                with open(path, "rb") as f:
                    self.data = f.read()
                    self.mtime = os.fstat(f.fileno()).st_mtime    # of the bytes read, whatever the path is a link to
            except OSError as e:
                raise Stop(NOINPUT, "cannot read %s: %s", path, e.strerror or e)
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
        elif self.kept is not None:                     # its bytes, its prefix and its place: the same bytes elsewhere sign apart
            tree = "\0plugin:%s\0%s" % (plugin_real(), self.tree_sha) if self.plugin_scripts else ""
            self.bind_sha = sha256(self.sha + "\0%s:" % self.place + self.real + tree)
        elif self.plugin_scripts:
            self.bind_sha = sha256(self.sha + "\0plugin:" + plugin_real() + "\0" + self.tree_sha)
        else:
            self.bind_sha = self.sha
        self.fields, self.header_end, self.header_problems = parse_header(self.text.split("\n"))
        self.params, self.params_problems = parse_params(self.field("Params")) if "Params" in self.fields else (None, [])
        self.argv = self.inputs = self.values = self.value_stop = None
        self.param_lines = []
        if self.kept is not None and not self.kept.pin(self.sha) and pin and (self.kept.retired or not self.kept.reviewed(self.data)):
            raise Stop(REFUSED, "%s", self.kept.refusal())

    def baton_id(self):
        """The `baton` field of log.tsv: <prefix>:<name>@<sha256>, or scratch@<sha256> for a script given by its path."""
        if self.kit or self.kind is not None or self.kept is not None:
            name = self.kept.name if self.kept is not None else self.kind if self.kind is not None else self.word[len("kit:"):]
            return "%s:%s@%s" % (self.place, name, self.sha)
        return "scratch@%s" % self.sha

    def label(self):
        """The kept baton's label (`not reviewed, kept by …`), or "" for any other."""
        return self.kept.label() if self.kept is not None else ""

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

    def value_why(self):
        """The one line of a bound value that names a Claude Code settings file (bind_call), or None: also None when Stops
        already declares security-boundary, so such a baton reads as before."""
        if self.value_stop is None or "security-boundary" in self.stops()[0]:
            return None
        label, v, kind, p = self.value_stop
        what = ("names a file with other hard links, which may be a Claude Code settings file" if kind == "linked"
                else "names a Claude Code settings %s" % kind)
        return ("%s %s %s%s: the call is security-boundary whatever Stops: says; only the owner signs it"
                % (label, quoted(v), what, "" if p == v else " (%s)" % esc(p)))

    def call_stops(self):
        """The call's stop categories: the declared ones, plus security-boundary for a value_why."""
        return self.stops()[0] + (["security-boundary"] if self.value_why() else [])


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
        if not m or m.group(1) not in HEADER_FIELDS + OPTIONAL_FIELDS:
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
ANSI_C = {"a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b", "f": "\f", "n": "\n", "r": "\r", "t": "\t", "v": "\v", "\\": "\\",
          "'": "'", '"': '"', "?": "?"}


def ansi_c(body):
    """The text of a `$'…'` word as bash decodes it: \\a…\\v, \\e, \\?, octal \\nnn, \\xHH, \\uHHHH, \\UHHHHHHHH, \\cX."""
    out, i = [], 0
    while i < len(body):
        c, d = body[i], body[i + 1:i + 2]
        if c != "\\" or not d:
            out.append(c)
            i += 1
        elif d in ANSI_C:
            out.append(ANSI_C[d])
            i += 2
        elif d in "01234567":
            m = re.match(r"[0-7]{1,3}", body[i + 1:])
            out.append(chr(int(m.group(0), 8) & 0xFF))
            i += 1 + len(m.group(0))
        elif d in "xuU" and re.match(r"[0-9A-Fa-f]", body[i + 2:i + 3]):
            m = re.match(r"[0-9A-Fa-f]{1,%d}" % {"x": 2, "u": 4, "U": 8}[d], body[i + 2:])
            v = int(m.group(0), 16)
            out.append(chr(v) if v <= 0x10FFFF else "")
            i += 2 + len(m.group(0))
        elif d == "c" and i + 2 < len(body):
            out.append(chr(ord(body[i + 2]) & 0x1F))
            i += 3
        else:
            out.append(c + d)
            i += 2
    return "".join(out)


def assignment_subscript(line, j):
    """True when the `[` at line[j] opens the subscript of an assignment word (`a[…]=` or `a[…]+=`): bash reads it as
    arithmetic, so a `<<` in it is a shift."""
    if not re.search(r"(?:^|[\s;&|(])[A-Za-z_][A-Za-z0-9_]*\Z", line[:j]):
        return False
    depth = 0
    for i in range(j, len(line)):
        depth += {"[": 1, "]": -1}.get(line[i], 0)
        if depth == 0:
            return line.startswith("=", i + 1) or line.startswith("+=", i + 1)
    return False


def balanced_end(line, k):
    """The index after the `$( … )`, `${ … }` or backtick group that starts at line[k], quotes followed; None when the line
    does not close it."""
    close = {"(": ")", "{": "}"}.get(line[k + 1:k + 2]) if line[k] == "$" else "`"
    opener = line[k + 1] if line[k] == "$" else None
    depth, i = 0, k + (2 if line[k] == "$" else 1)
    while i < len(line):
        c = line[i]
        if c == "\\":
            i += 2
            continue
        if c == "'" and close != "`":
            e = line.find("'", i + 1)
            if e < 0:
                return None
            i = e + 1
            continue
        if c == close and depth == 0:
            return i + 1
        if opener and c == opener:
            depth += 1
        elif opener and c == close:
            depth -= 1
        i += 1
    return None


def heredoc_word(line, j):
    """(end, delimiter, tabs) of the here-document operator at line[j] (`<<` or `<<-`, blanks, then a word); None when no word
    follows. The word is read as bash reads it: it ends at an unquoted blank or `;&|()<>`, a `$( … )`, `${ … }` or backtick
    group in it is part of it, and its delimiter is the word with its quotes removed (`\\x`, `'…'`, `"…"`, `$'…'` decoded,
    `$"…"`). A word the reader cannot decide (a quote or a group left open, a line continuation) has delimiter None."""
    k = j + 2
    tabs = line.startswith("-", k)
    k += 1 if tabs else 0
    while k < len(line) and line[k] in " \t":
        k += 1
    out, begin = [], k
    while k < len(line) and line[k] not in " \t;&|()<>":
        c = line[k]
        if c == "\\":
            if k + 1 >= len(line):
                return k + 1, None, tabs              # a line continuation: the word goes on, on the next line
            out.append(line[k + 1])
            k += 2
        elif c in "'\"" or (c == "$" and line[k + 1:k + 2] in ("'", '"')):
            k += 1 if c == "$" else 0
            q, e = line[k], k + 1
            while e < len(line) and line[e] != q:
                e += 2 if line[e] == "\\" and (q != "'" or c == "$") else 1
            if e >= len(line):
                return len(line), None, tabs          # a quote left open
            body = line[k + 1:e]
            if c == "$" and q == "'":
                body = ansi_c(body)
            elif q == '"':
                body = re.sub(r'\\([$`"\\])', r"\1", body)
            out.append(body)
            k = e + 1
        elif c == "`" or (c == "$" and line[k + 1:k + 2] in ("(", "{")):
            e = balanced_end(line, k)
            if e is None:
                return len(line), None, tabs          # a group left open
            out.append(line[k:e])
            k = e
        else:
            out.append(c)
            k += 1
    return (k, "".join(out), tabs) if k > begin else None


def logical_lines(text, bodies=None):
    """[(first line number, code, masked)] — one entry per logical line of shell. Comments and heredoc bodies are dropped and
    continued lines joined (a trailing `\\`, `|`, `&&` or `||`, or an open quote). `code` keeps the text inside quotes; `masked`
    replaces it with `_`, except a `$( … )` inside double quotes, which stays shell, so `|`, `;` and words inside a string are
    never read as syntax. With `bodies` (a list), each heredoc body is appended to it as (first line number, its lines, closed:
    False when no line ends it). `<<` inside `${ … }`, `$[ … ]` or arithmetic is no here-document. A heuristic for lints, not
    a parser."""
    lines = text.split("\n")
    out, code, masked = [], [], []
    stack = [["c", 0, False, ""]]  # frames: [kind, paren depth, nested in "…", closer]; kinds c (code), d ("…"), s ('…')
    start, n = None, 0
    heredocs = []
    # [frame, kind, depth before it, nesting] of each open `${` (brace), `$[` (bracket), `((`/`$((` (arith) and `$(` (subst) in
    # a code frame: inside the innermost of a brace, a bracket or arith, `<<` is no here-document and `#` no comment
    ctx = []

    def innermost(frame):
        return next((c for c in reversed(ctx) if c[0] is frame), None)

    def pop_frame():
        gone = stack.pop()
        ctx[:] = [c for c in ctx if c[0] is not gone]

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
                    pop_frame()
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
                    pop_frame()
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
                pop_frame()
                emit(ch)
                j += 1
                continue
            cur = innermost(top) if ctx else None
            if ch == "'":
                stack.append(["s", 0, False, ""])
            elif ch == '"':
                stack.append(["d", 0, False, ""])
            elif ch == "#" and (j == 0 or line[j - 1] in " \t;&|(") and not (cur and cur[1] in ("brace", "bracket", "arith")):
                break
            elif line.startswith("$$", j):                 # the shell's pid: `$${` is `$$` and a literal `{`
                emit("$$")
                j += 2
                continue
            elif line.startswith("${", j) or line.startswith("$[", j):
                ctx.append([top, "brace" if line[j + 1] == "{" else "bracket", top[1], 0])
                emit(line[j:j + 2])
                j += 2
                continue
            elif line.startswith("$(", j):
                width = 3 if line.startswith("$((", j) else 2
                ctx.append([top, "arith" if width == 3 else "subst", top[1], 0])
                top[1] += width - 1
                emit(line[j:j + width])
                j += width
                continue
            elif cur and ((cur[1] == "brace" and ch in "{}") or (cur[1] == "bracket" and ch in "[]")):
                if ch in "{[":
                    cur[3] += 1
                elif cur[3]:
                    cur[3] -= 1
                else:
                    ctx[:] = [c for c in ctx if c is not cur]
            elif ch == "[" and assignment_subscript(line, j):
                ctx.append([top, "bracket", top[1], 0])
            elif ch == "(":
                if line.startswith("((", j):
                    ctx.append([top, "arith", top[1], 0])
                top[1] += 1
            elif ch == ")":
                if top[1] == 0 and top[3] == ")":
                    pop_frame()
                elif top[1] > 0:
                    top[1] -= 1
                while ctx and ctx[-1][0] is top and ctx[-1][1] in ("arith", "subst") and top[1] <= ctx[-1][2]:
                    ctx.pop()
            elif line.startswith("<<<", j):                # a here-string: one token, never a here-document's operator
                emit("<<<")
                j += 3
                continue
            elif line.startswith("<<", j) and not (cur and cur[1] != "subst"):
                hw = heredoc_word(line, j)
                if hw and hw[1] is None:                    # a delimiter the reader cannot decide: check refuses it
                    if bodies is not None:
                        bodies.append((n + 1, [], None))
                    emit(line[j:hw[0]])
                    j = hw[0]
                    continue
                if hw:
                    heredocs.append((hw[1], hw[2]))
                    emit(line[j:hw[0]])
                    j = hw[0]
                    continue
            emit(ch)
            j += 1
        n += 1
        while heredocs:                       # the bodies start on the next line
            word, tabs = heredocs.pop(0)
            first = n
            while n < len(lines) and (lines[n].lstrip("\t") if tabs else lines[n]) != word:
                n += 1
            if bodies is not None:
                bodies.append((first + 1, lines[first:n], n < len(lines)))
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


# ── parameter checks: a value reaches the script through its values block and quoted expansions only ───────────────────────────
IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
REF_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*|[0-9]+|[@*#?$!-]")
SHELLS = ("bash", "sh", "zsh", "dash", "ksh")
DATA_OPTS = {"gh": ("-F", "--field"), "curl": ("-d", "--data", "--data-binary", "--data-urlencode", "--data-ascii", "--json",
                                               "-F", "--form")}

def shell_refs(code):
    """[(name, form, ctx, start, end)] of the parameter expansions and bare identifiers of one logical line of shell (comments
    and heredoc bodies dropped). form: plain ($NAME, $1, $@), brace (${NAME}), op (any other ${…}: an operator, ${#…}),
    indirect (${!…}) or bare (an identifier outside quotes, not after $: an assignment, a read, arithmetic). ctx: d inside
    double quotes, c outside. Single-quoted text is skipped; $( … ), $(( … )), backticks and the word of ${…} nest."""
    out, i, n, stack = [], 0, len(code), [("c", "")]
    while i < n:
        kind, closer = stack[-1]
        ch = code[i]
        if ch == "\\":
            i += 2
            continue
        if closer and code.startswith(closer, i):
            stack.pop()
            i += len(closer)
            continue
        if kind in ("d", "w"):                          # inside "…", or the word of a ${…} inside "…"
            if ch == '"':
                stack.pop() if kind == "d" else stack.append(("d", ""))
            elif ch == "`":
                stack.append(("c", "`"))
            elif ch == "$":
                i = shell_dollar(code, i, "d", out, stack)
                continue
            i += 1
            continue
        if ch == "'":
            j = code.find("'", i + 1)
            i = n if j < 0 else j + 1
        elif ch in '"`(':
            stack.append({'"': ("d", ""), "`": ("c", "`"), "(": ("c", ")")}[ch])
            i += 1
        elif ch == "$":
            i = shell_dollar(code, i, "c", out, stack)
        else:
            m = IDENT.match(code, i)
            if m and (i == 0 or not (code[i - 1].isalnum() or code[i - 1] == "_")):
                out.append((m.group(0), "bare", "c", i, m.end()))
                i = m.end()
            else:
                i += 1
    return out


def shell_dollar(code, i, ctx, out, stack):
    """Read the expansion at code[i] == '$' into `out`; the index after it."""
    j = i + 1
    if code.startswith("((", j) or code.startswith("(", j):
        k = 2 if code.startswith("((", j) else 1
        stack.append(("c", ")" * k))
        return j + k
    if code.startswith("{", j):
        k = j + 1
        pre = code[k] if k < len(code) and code[k] in "!#" else ""
        if pre == "#" and code.startswith("}", k + 1):          # ${#}: the number of positional parameters
            out.append(("#", "brace", ctx, i, k + 2))
            return k + 2
        m = REF_NAME.match(code, k + len(pre))
        e = m.end() if m else k + len(pre)
        name = m.group(0) if m else ""
        if not pre and code.startswith("}", e):
            out.append((name, "brace", ctx, i, e + 1))
            return e + 1
        out.append((name, "indirect" if pre == "!" else "op", ctx, i, e))
        stack.append(("c" if ctx == "c" else "w", "}"))
        return e
    if ctx == "c" and code.startswith("'", j):                  # $'…'
        k = j + 1
        while k < len(code) and code[k] != "'":
            k += 2 if code[k] == "\\" else 1
        return k + 1
    m = re.compile(r"[A-Za-z_][A-Za-z0-9_]*|[0-9]|[@*#?$!-]").match(code, j)
    if m:
        out.append((m.group(0), "plain", ctx, i, m.end()))
        return m.end()
    return j


def cmd_words(code, i, end):
    """[(word, start, end)] of the shell words of code[i:end]."""
    out, j = [], i
    while j < end:
        while j < end and code[j].isspace():
            j += 1
        if j >= end:
            break
        e = max(j + 1, min(word_end(code, j), end))
        out.append((code[j:e], j, e))
        j = e
    return out


# ── a segment derived from a value ────────────────────────────────────────────────────────────────────────────────────────────
# A value never starts with - + : @ = ~ % (LEAD_REFUSED, every type), and a path's last segment never starts with - + @; a middle
# segment may (Claude Code's scratchpad holds `-home-…`). dirname and a suffix trim (${d%/*}, ${q%%=*}) keep the first
# character (or give . or / or nothing), so they are safe only because of LEAD_REFUSED; basename, a prefix trim, a substring
# or a replacement can hand a middle segment to a command:
# dest=/tmp/w/--force/x gives --force through `basename "$(dirname "$P_DEST")"`. A lint, not a proof: a value passed to a
# function and trimmed as $1, and text tools (cut, sed, awk, IFS=/ read), are not followed.
# ${v:-x} ${v:=x} ${v:?x} ${v:+x} (and without the colon): the value whole or another word; ${v%…} ${v%%…}: its first character
SEGMENT_SAFE_OPS = re.compile(r":?[-=?+]|%")


def assigned_values(code, masked):
    """[(name, value text)] of the assignments of one logical line: NAME=…, NAME+=… (also after local, declare, export,
    readonly), `for NAME in …` and `printf -v NAME …` (those two end at the first ; & | outside quotes: masked tells)."""
    out = []
    for name, form, _ctx, a, b in shell_refs(code):
        if form != "bare" or (a and code[a - 1] not in " \t;&|(`"):
            continue
        k = b + 2 if code.startswith("+=", b) else b + 1 if code.startswith("=", b) else None
        if k is None or k >= len(code) or code[k].isspace():
            continue
        if code[k] == "`":
            e = code.find("`", k + 1)
            e = len(code) if e < 0 else e + 1
        elif code[k] == "(":
            depth, e = 0, k
            while e < len(code):
                depth += {"(": 1, ")": -1}.get(code[e], 0)
                e += 1
                if depth == 0:
                    break
        else:
            e = word_end(code, k)
        out.append((name, code[k:e]))
    for rx in (r"(?:^|[;&|(\s])for\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\s",
               r"(?:^|[;&|(\s])printf\s+-v\s*[\"']?([A-Za-z_][A-Za-z0-9_]*)(?:\[[^]]*\])?[\"']?\s"):
        for m in re.finditer(rx, code):
            stop = re.compile(r"[;&|\n]").search(masked, m.end())
            out.append((m.group(1), code[m.end():stop.start() if stop else len(code)]))
    return out


def split_substs(text):
    """(text with every $( … ) and backtick substitution cut out, [each substitution's inner text])."""
    outer, inner, i = [], [], 0
    while i < len(text):
        if text.startswith("$(", i) and not text.startswith("$((", i):
            depth, e = 0, i + 1
            while e < len(text):
                depth += {"(": 1, ")": -1}.get(text[e], 0)
                e += 1
                if depth == 0:
                    break
            inner.append(text[i + 2:e - 1])
            i = e
        elif text[i] == "`":
            e = text.find("`", i + 1)
            e = len(text) if e < 0 else e + 1
            inner.append(text[i + 1:e - 1])
            i = e
        else:
            outer.append(text[i])
            i += 1
    return "".join(outer), inner


SEGMENT_CMD = re.compile(r"(?:^|[\s;&|(/=])(?:dirname|basename)(?![\w.-])")     # behind any wrapper: env, command -p, X=y


def carriers_of(entries, names):
    """The names that hold a parameter's value or a part of it: the P_ names, and every variable assigned text that holds one
    of them (a copy, a value inside a longer string, printf -v) or a dirname or basename of one, followed to a fixed point.
    The output of any other command that reads a value (gh api, git) is not a part of it: a text tool is a residual."""
    pairs = [(n, split_substs(v)) for _n, code, masked in entries for n, v in assigned_values(code, masked)]
    held = set(names)
    while True:
        more = set(n for n, (outer, inner) in pairs if n not in held and (
            reads_any(outer, held) or any(SEGMENT_CMD.search(x) and reads_any(x, held) for x in inner)))
        if not more:
            return held
        held |= more


def reads_any(text, names):
    return any(m.group(1) in names for m in re.finditer(r"\$\{?[#!]?([A-Za-z_][A-Za-z0-9_]*)", text))


def subst_end(masked, s):
    """The index after the `$( … )` or backtick substitution that opens at masked[s] (quoted text is masked)."""
    if masked[s] == "`":
        e = masked.find("`", s + 1)
        return len(masked) if e < 0 else e + 1
    depth, e = 0, s + 1
    while e < len(masked):
        depth += {"(": 1, ")": -1}.get(masked[e], 0)
        e += 1
        if depth == 0:
            break
    return e


def basename_exempt(code, masked, s):
    """True when the substitution opening at s is in a word that starts with a literal ./ (`./"$(basename …)"`,
    `n="./$(…)"`) or comes after a `--` word of the command that reads it."""
    j = s
    while j > 0 and not masked[j - 1].isspace() and masked[j - 1] not in ";&|()`":
        j -= 1
    assign = re.match(r"[A-Za-z_][A-Za-z0-9_]*\+?=", code[j:s])
    word = code[j + (assign.end() if assign else 0):s].replace('"', "").replace("'", "")
    if word.startswith("./"):
        return True
    if assign:                                          # `local -- x=$(…)`: that -- ends local's options, not the reader's
        return False
    c, depth = j, 0                                     # back to the start of the command, over a closed $( … )
    while c > 0:
        ch = masked[c - 1]
        if ch == ")":
            depth += 1
        elif ch == "(" and depth:
            depth -= 1
        elif depth == 0 and ch in ";&|(`":
            break
        c -= 1
    return "--" in masked[c:j].split()


def basename_many(text, mtext):
    """True when the basename in a substitution's text may print more than one word: an option other than -z or --zero
    (-a, -s, --multiple, --suffix, any abbreviation or attached form; options end at the first operand, as getopt's "+"
    reads them), or more than two operands. Its words end at the first ; | & outside quotes (mtext is the masked text), and
    a redirection (2>&1, 2> /dev/null, >x) is no operand."""
    k = 2 if text.startswith("$(") else 1
    inner, minner = text[k:-1], mtext[k:-1]
    stop = re.search(r"[;|]|(?<![<>])&(?!>)", minner)
    inner, minner = inner[:stop.start()] if stop else inner, minner[:stop.start()] if stop else minner
    for m in reversed(list(re.finditer(r"\d*(?:&>>?|[<>]{1,2})(?:&[\d-]+|\s*[^\s;|&<>]+)?", minner))):
        inner = inner[:m.start()] + " " * (m.end() - m.start()) + inner[m.end():]
    words = [w for w, _a, _b in cmd_words(inner, 0, len(inner))]
    k = next((j for j, w in enumerate(words) if os.path.basename(w.strip("\"'")) == "basename"), None)
    if k is None:
        return True
    operands, opts = 0, True
    for w in words[k + 1:]:
        if opts and w == "--":
            opts = False
        elif opts and w.startswith("-") and w != "-":
            if w not in ("-z", "--zero"):
                return True
        else:
            opts, operands = False, operands + 1
    return operands > 2


def segment_problems(entries, names):
    """[(line, problem)]: basename of a value or a carrier, unless its result is passed as ./<name> or after --, and a prefix
    trim, substring, replacement or transform of a carrier that is not a P_ name (every operator on those is refused already)."""
    held, probs = carriers_of(entries, names), []
    copies = held - set(names)
    for k, n, pos, i, end, code, masked, word in simple_commands(entries):
        if word != "basename":
            continue
        s = pos - 2 if masked[max(pos - 2, 0):pos] == "$(" else pos - 1 if masked[pos - 1:pos] == "`" else None
        text = code[s:subst_end(masked, s)] if s is not None else code[i:end]
        if not reads_any(text, held):
            continue
        if s is None or basename_many(text, masked[s:s + len(text)]) or not basename_exempt(code, masked, s):
            probs.append((n, "basename of a parameter or its copy: a segment of a value can start with - (dest=/w/--force/x gives "
                             "--force): pass the result after -- or as ./<name>"))
    for n, code, _m in entries:
        for name, form, _ctx, _a, b in shell_refs(code):
            if form != "op" or name not in copies:
                continue
            e = code.find("]", b) + 1 if code.startswith("[", b) else b
            if code.startswith("}", e) or SEGMENT_SAFE_OPS.match(code, e):
                continue
            probs.append((n, "${%s…} cuts %s, which holds a parameter's value: a segment of a value can start with -; read it "
                             "whole, or take a segment with basename after -- or as ./<name>" % (name, name)))
    return probs


def param_problems(s, entries, bodies):
    """[(line, problem)] of the parameter checks of a baton that declares Params: one values block, quoted expansions only, no
    value in eval, a command name, gh -F or curl -d, or a here-document."""
    if s.params is None or s.params_problems:
        return []
    names = dict((k, "P_" + k.upper()) for k, _t, _a in s.params)
    NAMES = set(names.values())
    spans = function_spans(entries)
    in_fn = set()
    for v in spans.values():
        in_fn |= v
    probs = []
    keys = [names[k] for k, _t, _a in s.params]
    want = [re.compile(r'\s*%s="\$(?:%s\{%d\})"\s*\Z' % (n, "%d|" % (j + 1) if j < 9 else "", j + 1)) for j, n in enumerate(keys)]
    top = [k for k in range(len(entries)) if k not in in_fn]
    first = next((k for k in top if re.match(r"\s*P_[A-Za-z0-9_]*\+?=", entries[k][1])), None)
    block = set()
    if keys:
        run = [k for k in range(first, first + len(keys))] if first is not None else []
        if first is None or run[-1] >= len(entries) or any(k in in_fn or not want[j].match(entries[k][1]) for j, k in enumerate(run)):
            probs.append((entries[first][0] if first is not None else 0,
                          "the values block is one top-level line per declared key, in the declared order: %s"
                          % "; ".join('%s="$%s"' % (n, j + 1 if j < 9 else "{%d}" % (j + 1)) for j, n in enumerate(keys))))
        else:
            block = set(run)
    start = min(block) if block else None
    seen = set()

    def bad(n, msg):
        if (n, msg) not in seen:
            seen.add((n, msg))
            probs.append((n, msg))

    for k, (n, code, _m) in enumerate(entries):
        for name, form, ctx, a, b in shell_refs(code):
            if ((name.isdigit() and name != "0") or name in ("@", "*")) and form != "bare" and k not in in_fn and k not in block:
                bad(n, "a positional parameter ($1…, $@, $*) is read outside the values block: a value is read once, there")
            if form == "bare" and name.startswith("P_") and (code[b:b + 1] in ("=", "[") or code[b:b + 2] == "+=") and k not in block:
                bad(n, "%s is assigned outside the values block: a P_ name is set there only" % name)
            if name not in NAMES or k in block:
                if form == "indirect" and name.startswith("P_"):
                    bad(n, "${!%s…}: an indirect expansion of a parameter" % name)
                continue
            if form == "bare":
                bad(n, "%s is named bare (assigned, read, exported, declared or in arithmetic): a value is read only as "
                       "\"$%s\" or \"${%s}\"" % (name, name, name))
            elif form in ("op", "indirect"):
                bad(n, "${%s…} with an operator: a value is read only as \"$%s\" or \"${%s}\"" % (name, name, name))
            elif ctx == "c":
                bad(n, "$%s is unquoted: a value is read only as \"$%s\" or \"${%s}\"" % (name, name, name))
            if start is not None and k < start and k not in in_fn:
                bad(n, "%s is read at the top level before the values block" % name)
    cmds = list(simple_commands(entries))
    for k, n, pos, i, end, code, masked, word in cmds:
        if k not in in_fn and k not in block and (word in ("shift", "getopts") or (word == "set" and re.search(r"\s--(?:\s|$)", masked[i:end]))):
            bad(n, "`%s` at the top level reads or replaces the positional parameters: a value is read once, in the values block" % word)
        raw = code[i:end]
        held = sorted(x for x in NAMES if re.search(r"(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])" % x, raw))
        if not held:
            continue
        head = code[i:word_end(code, i)]
        if not re.match(r"[A-Za-z_][A-Za-z0-9_]*\+?=", head) and re.search(r"\$\{?(?:%s)\b" % "|".join(held), head):
            bad(n, "%s is the command name: a value never names the command" % held[0])
        if word in ("eval", "trap") or (word in SHELLS and re.search(r"\s-[A-Za-z]*c", masked[i:end])):
            bad(n, "%s in `%s`: the value would be parsed as code" % (held[0], word))
        cw = cmd_words(code, i, end)
        if word == "write" and len(cw) > 2:
            cw = cmd_words(code, write_target(code, i), end)
        prog = os.path.basename(cw[0][0]) if cw else ""
        for j, (w, _a, _b) in enumerate(cw):
            opt = next((o for o in DATA_OPTS.get(prog, ()) if w == o or w.startswith(o + "=") or (len(o) == 2 and w.startswith(o)
                                                                                                    and len(w) > 2)), None)
            val = (cw[j + 1][0] if j + 1 < len(cw) else "") if opt == w else w[len(opt):] if opt else ""
            if opt and any(re.search(r"(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])" % x, val) for x in held):
                bad(n, "a parameter is the value of %s %s, which reads @<file>: pass it with %s" % (prog, opt, "-f" if prog == "gh" else "--data-raw"))
    for ln, msg in segment_problems(entries, NAMES):
        bad(ln, msg)
    for ln, lines, _closed in bodies:
        for x in sorted(NAMES):
            if any(re.search(r"(?<![A-Za-z0-9_])%s(?![A-Za-z0-9_])" % x, line) for line in lines):
                bad(ln, "%s in the body of a here-document: a program sent elsewhere reads its own variables, and a value never "
                        "becomes code" % x)
    return probs


def interface_problems(s):
    """[(line, problem)] of a baton's declared interface: Params (its grammar; required, with a key, in a kept baton), Usage
    (a kit's or kind's documented flags: never in a kept baton, never beside Params), and a kept baton's testable Targets."""
    probs, pl, ul = [], s.fields.get("Params"), s.fields.get("Usage")
    if pl:
        raw = s.text.split("\n")[pl[0] - 1]
        if raw != "# Params: " + pl[1]:
            probs.append((pl[0], "header: the Params line is `# Params: <none, or key=type words>`, with no other spacing"))
        if len(raw) > PARAMS_LINE_MAX:
            probs.append((pl[0], "header: the Params line is %d characters, over %d" % (len(raw), PARAMS_LINE_MAX)))
        probs += [(pl[0], "header: " + p) for p in s.params_problems]
    if ul and not ul[1]:
        probs.append((ul[0], "header: empty Usage"))
    if pl and ul:
        probs.append((ul[0], "header: Params and Usage together; a baton declares one of the two"))
    if s.kept is not None:
        if not s.params:
            probs.append((pl[0] if pl else 0, "header: a %s: baton declares Params with at least one key (a fixed-value script "
                                              "stays a one-off in scratch)" % s.place))
        if ul:
            probs.append((ul[0], "header: Usage documents a kit's or kind's flags; a %s: baton declares Params" % s.place))
        if s.params and not s.params_problems:
            probs += [(s.fields.get("Targets", (0,))[0], "header: the Targets of a kept baton are patterns the runner tests: " + p)
                      for p in target_patterns(s)[1]]
    elif (s.kit or s.kind is not None) and not pl and not ul:
        probs.append((0, "header: a kit or callable kind declares Usage (its flags) or Params"))
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
    probs += interface_problems(s)

    heredoc_bodies = []
    entries = logical_lines(s.text, heredoc_bodies)
    if b"\0" in s.data:                                 # bash drops a NUL byte: check would not read what bash runs
        probs.append((0, "a NUL byte in the script: bash drops it, so check cannot read what bash runs"))
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
    probs += param_problems(s, entries, heredoc_bodies)
    probs += [(ln - 1, "a here-document that no line closes: everything after it would be its body, never read as code")
              for ln, _lines, closed in heredoc_bodies if closed is False]
    probs += [(ln, "a here-document whose delimiter the reader cannot decide (a line continuation, or a quote or group left "
                   "open in it): write the word on one line, plainly quoted") for ln, _lines, closed in heredoc_bodies if closed is None]
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
                              % (cat, label, m.group(0).strip()[:60], joined.strip()[:80], cat)
                              + (BRANCH_KIT_HINT if label in BRANCH_DELETE_LABELS else "")
                              + (SETTINGS_HELD_HINT if label == SETTINGS_HELD_LABEL else "")))
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
        say("FAIL %s%s", "line %d: " % n if n else "", p)
    say("check: %d problem%s in %s", len(probs), "" if len(probs) == 1 else "s", s.path)


# ── phases ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
def need_bash():
    if not shutil.which("bash"):
        raise Stop(ENV, "no bash on PATH")


def run_phase(s, args, phase, sinks, plan=None, undo_only=None):
    """Run one phase on a fresh copy of the hashed bytes; (rc, output lines). Each output line goes to every sink as it comes.
    With `plan` (the signed plan, given to the run phase and its undo) the script gets BATON_PLAN, a file holding it one line per write,
    so it can refuse to do anything else before an act that cannot be undone. With `undo_only` (the same file for the run phase and
    its undo) it gets BATON_UNDO_ONLY: the paths it keeps only for its undo (drop_undo_only)."""
    tmpd = tempfile.mkdtemp(prefix="baton-")
    try:
        p = os.path.join(tmpd, s.name)
        fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as f:
            f.write(s.data)
        env = {k: v for k, v in os.environ.items() if k not in SHELL_HOOKS and not k.startswith("BASH_FUNC_")}
        env = {k: v for k, v in env.items() if not k.startswith("P_")}    # a parameter is never inherited: the values block sets it
        writes = os.path.join(tmpd, "writes")         # write() appends one plan line per write here
        open(writes, "w").close()
        env["BATON_PHASE"] = phase
        RUN["phase"] = phase
        env["BATON_SCRIPT"] = s.real
        env["BATON_WRITES"] = writes
        env.pop("BATON_PLAN", None)                     # only the runner sets it, and only for the run phase and its undo
        env.pop("BATON_UNDO_ONLY", None)                # the same
        if undo_only is not None:
            env["BATON_UNDO_ONLY"] = undo_only
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
            say("== %s", phase, out=out)
        argv = list(s.argv if s.argv is not None else args)    # a baton with Params: the values, a file value as its copy
        # A stop signal that comes while the phase starts waits (blocked) until Popen has returned, then lands inside the try that
        # stops the phase's group; the child starts with the caller's mask. Without this, one raised inside Popen left the group running.
        stops = {signal.SIGTERM, signal.SIGHUP, signal.SIGINT}
        mask = signal.pthread_sigmask(signal.SIG_BLOCK, ())   # the caller's mask, unchanged
        proc = None
        lines = []
        try:
            signal.pthread_sigmask(signal.SIG_BLOCK, stops)
            proc = subprocess.Popen([shutil.which("bash"), p] + argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, env=env, start_new_session=True,
                                    preexec_fn=lambda: signal.pthread_sigmask(signal.SIG_SETMASK, mask))
            signal.pthread_sigmask(signal.SIG_SETMASK, mask)
            for raw in proc.stdout:
                line = raw.decode("utf-8", "replace").rstrip("\n")
                lines.append(line)
                for out in sinks:                       # a script's line is relayed, never a line of baton's own
                    say("  %s", line, out=out)
            rc = proc.wait()
        except BaseException:
            # Several stop signals can be pending at once, and each raises at the next point where Python runs handlers. Each level
            # blocks them before stopping the group, and a raise moves to the next level (from an except to the next try there is
            # no such point). Four levels: enough for three signals delivered before a block takes effect; a flood of four or more
            # within microseconds can still use them all up before the group is stopped.
            try:
                _stop_phase(proc, stops)
            except BaseException:
                try:
                    _stop_phase(proc, stops)
                except BaseException:
                    try:
                        _stop_phase(proc, stops)
                    except BaseException:
                        try:
                            _stop_phase(proc, stops)
                        except BaseException:
                            pass
            signal.pthread_sigmask(signal.SIG_SETMASK, mask)   # what arrived meanwhile lands now, after the group was stopped
            raise
        if s.plugin_scripts and scripts_tree_sha() != s.tree_sha:
            msg = "baton: the plugin's scripts/ changed during the phase (detected after it, not prevented)"
            lines.append(msg)
            for out in sinks:
                say("%s", msg, out=out)
            rc = rc or 70
        with open(writes, "rb") as f:
            return rc, lines, [w.decode("utf-8", "backslashreplace") for w in f.read().split(b"\n")[:-1]]
    finally:
        shutil.rmtree(tmpd, ignore_errors=True)


def _stop_phase(proc, stops):
    """stop_group with the stop signals blocked: once the block has taken effect, none that arrives can interrupt it (one that
    arrived just before, still to be handled, can raise at this function's entry or in the pthread_sigmask wrapper)."""
    signal.pthread_sigmask(signal.SIG_BLOCK, stops)
    if proc is not None:
        stop_group(proc)


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
    ttable, treasons = targets_table(s, plan)            # a baton with Params and testable Targets: no line outside them
    table += ttable
    reasons += treasons
    for out in sinks:
        for ln in table:
            say("%s", ln, out=out)
    return not reasons, plan, reasons


def steering():
    """{name: sha256 prefix of its value, or None when unset} for the STEERING variables."""
    names = set(STEERING) | set(k for k in os.environ if k.startswith(("GIT_CONFIG", "PYTHON")))
    return {k: (sha256(os.environ[k].encode("utf-8", "surrogateescape"))[:16] if k in os.environ else None) for k in sorted(names)}


def binding_of(script_sha, args, cwd, env, inputs=None):
    if inputs is not None:                              # a baton with Params: v2, the sha256 of each file value beside its words
        return sha256(json.dumps({"v": 2, "script_sha256": script_sha, "args": list(args), "cwd": cwd, "env": env,
                                  "inputs": inputs}, sort_keys=True, separators=(",", ":")))
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
        raise Stop(ENV, "the state directory %s cannot be written: %s", d, e.strerror or e)
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
    """(mode, chosen): chosen is False when there is no mode file, a fresh install where nobody has chosen yet, or a file without
    the owner's dialog line (PROOF_LINE: written by an older baton.py, or before the record); it reads as manual."""
    try:
        with open(os.path.join(state_dir(), "mode"), encoding="utf-8") as f:
            lines = f.read().split("\n")
    except FileNotFoundError:
        return "manual", False
    except (OSError, ValueError):                                     # unreadable, or not UTF-8: chosen, read as manual
        return "manual", True
    if not proven(lines[1:]):
        return "manual", False
    v = lines[0].strip()
    if v not in MODES:
        say("baton: the mode file holds %s: treated as manual", repr(v), out=sys.stderr)
        return "manual", True
    return v, True


def read_mode():
    return mode_state()[0]


def log_value(v):
    return esc(v)


def log_event(d, **kw):
    """Append one line to log.tsv; returns it as written."""
    kw.setdefault("time", now_iso())
    vals = []
    for k in LOG_FIELDS:
        v = kw.get(k)
        if k == "args" and isinstance(v, list):         # a value is cut at CUT characters here and on list, never on the card
            v = [cut(a, CUT) if isinstance(a, str) else a for a in v]
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
    if s.inputs is not None and not any(r.get("inputs") == s.inputs for r in same):
        return "a file value changed since it was signed (signed: %s; now: %s)" % (
            "; ".join(json.dumps(r.get("inputs")) for r in same), json.dumps(s.inputs))
    if not any(r.get("cwd") == cwd for r in same):
        return "the directory differs from the one it was signed in (signed: %s)" % ", ".join(str(r.get("cwd")) for r in same)
    moved = sorted(set(k for r in same if r.get("cwd") == cwd for k in set(r.get("env") or {}) | set(env)
                       if (r.get("env") or {}).get(k) != env.get(k)))
    return "the environment differs from the signed one: %s" % (", ".join(moved) or "unknown")


def allowed(signer, mode, stops, value=None):
    """None when `signer` may sign or run in `mode`, else the reason. stops: the declared ones; value: Script.value_why()."""
    if signer == "owner":
        return None
    if signer != "coordinator-auto":
        return "unknown signer %r" % signer
    if value:
        return "%s%s" % ("the script declares stop categories (%s); " % ", ".join(stops) if stops else "", value)
    if mode != "auto":
        return "the mode is manual: only the owner signs (`baton mode` shows it; the owner sets it)"
    if stops:
        return "the script declares stop categories (%s): only the owner signs it" % ", ".join(stops)
    return None


# ── the owner's dialog ─────────────────────────────────────────────────────────────────────────────────────────────────────────
# `sign --by owner` signs only with a record that the plugin's PreToolUse Bash hook (baton-guard.py → guard_owner) wrote when it
# answered `ask` for that very call: Claude Code then shows its dialog whatever the settings say, and the owner's click runs the
# command. The record binds the session, the argv after `sign`, the directory and the Claude Code process that asked; only a
# process that Claude Code process started after the ask may use it (LINEAGE), so a process started before (a background poller)
# or under another Claude Code (another session) cannot. It lives ASKED_MAX_AGE seconds, the first sign attempt from inside
# that lineage uses it up, and the session's next Bash call voids it (a rejected dialog leaves one). The guard denies, and writes none, where
# no human sees the dialog or the human is not the owner. The design is vibemaestro-brain's `brain owner` (guard-owner), ported:
# sdlc does not depend on brain. Like the rest of baton, it guards against slips, not same-user forgery of the state files.
ASKED_MAX_AGE = 600
VERSION_FLOOR = (2, 1, 211)                            # before it, auto mode could approve a hook's `ask` without the dialog
DIALOG_MODES = ("default", "acceptEdits", "auto")
MANAGED_SETTINGS = ("/etc/claude-code/managed-settings.json", "/Library/Application Support/ClaudeCode/managed-settings.json")
SANDBOX_ENV = ("INTENT_SLUG", "SEAT")                  # vsdlc.SANDBOX_ENV: both set means a session in a sandbox pod
CLAUDE_PROGRAMS = ("claude", "claude.exe", "cli.js")    # an argv word naming Claude Code; also any path under claude/versions/
PY_FLAGS = ("-I", "-B", "-E", "-s", "-S", "-u", "-O", "-OO", "-q", "-b", "-bb")  # python3 options a literal owner call may carry
LINEAGE = True                                           # off only in the suites' isolated copies (tests/fixtures/baton-owner.sh)
OWNER_PREFIXES = ("env", "xargs", "command", "exec", "nohup", "time", "sudo", "builtin", "nice", "timeout", "stdbuf", "setsid")
NO_OWNER_DIALOG = ("sign --by owner is the owner's click in Claude Code's dialog: the session runs the printed command right "
                   "after the decision card, and the plugin's hook opens the dialog")
SHAPE = ("the guard asks only for the printed command, exactly: <program> sign --by owner --seal <seal> <absolute script path, "
         "or kit:/kind:/project:/user:<name>> [plain arguments]; printable ASCII, no quote or shell character; the program is this "
         "plugin's "
         "baton.py (`python3 [-I -B …] <it>`) or the installed launcher, by absolute path")
SAFE_WORD = re.compile(r"[A-Za-z0-9_./:@%+,=-]+\Z")   # no quote, glob, brace, tilde, `$`, `#`, `\`, `;&|()<>` or space
SEAL_WORD = re.compile(r"[0-9a-f]{16}\.[0-9a-f]{16}\Z")
LITERAL = ("write the `sign --by owner …` command alone in the Bash call, with literal arguments: no variable, substitution, "
           "backslash, glob, redirect or wrapper, and nothing before or after it, so the dialog shows exactly what runs")
# A mode change (`mode manual|auto`, `mode trust|untrust <remote>`) takes the same dialog and record as `sign --by owner`: the ask
# rules only show the dialog, the record is the guard, so a wrapped or hidden call fails closed (mode unchanged).
MODE_WRITES = MODES + ("trust", "untrust")
NO_MODE_DIALOG = ("a mode change is the owner's click in Claude Code's dialog: on the owner's answer the session runs `<launcher> "
                  "mode <answer>` alone in its Bash call, and the plugin's hook opens the dialog")
SHAPE_MODE = ("the guard asks only for the printed command, exactly: <program> mode manual|auto, or <program> mode trust|untrust "
              "<remote>; printable ASCII, no quote or shell character; the program is this plugin's baton.py (`python3 [-I -B …] "
              "<it>`) or the installed launcher, by absolute path or as ~/… where the kit's text spells it so")


def asked_dir():
    return os.path.join(state_dir(), "asked")


def session_id():
    return os.environ.get("CLAUDE_CODE_SESSION_ID", "")


def in_sandbox():
    return all(os.environ.get(v, "").strip() for v in SANDBOX_ENV)


def void_asked(session, now=None):
    """Delete the session's records and every expired one."""
    now = time.time() if now is None else now
    try:
        names = os.listdir(asked_dir())
    except OSError:
        return
    for n in names:
        p = os.path.join(asked_dir(), n)
        r = load_json(p)
        try:
            gone = not isinstance(r, dict) or r.get("session") == session or not 0 <= now - float(r.get("t")) <= ASKED_MAX_AGE
        except (TypeError, ValueError):
            gone = True
        if gone:
            try:
                os.unlink(p)
            except OSError:
                pass


def record_asked(session, mode, argv, cwd, claude, after, kept=None, queued=None):
    """claude: [pid, start] of the Claude Code process that asked (None when unknown); after: the hook process's start.
    kept: (real path, sha256) of the pinned file a project: or user: name resolved to when the dialog opened.
    queued: [id, body_sha256] of the queued item the dialog showed."""
    d = ensure_state()
    os.makedirs(os.path.join(d, "asked"), mode=0o700, exist_ok=True)
    rid = sha256(os.urandom(32))[:32]
    rec = {"id": rid, "session": session, "mode": mode, "argv": list(argv), "cwd": cwd, "claude": claude, "after": after,
           "t": time.time()}
    if kept:
        rec["script_path"], rec["script_sha256"] = kept
    if queued:
        rec["queued"] = list(queued)
    write_private(os.path.join(d, "asked", rid + ".json"), json.dumps(rec, sort_keys=True) + "\n")
    return rid


def find_asked(session, argv, cwd, now=None):
    """(path, record) of a fresh record of this session for exactly this argv and directory, written in a dialog mode, or
    (None, None)."""
    now = time.time() if now is None else now
    try:
        names = sorted(os.listdir(asked_dir()))
    except OSError:
        return None, None
    for n in names:
        p = os.path.join(asked_dir(), n)
        r = load_json(p)
        try:
            age = now - float(r["t"])
        except (TypeError, ValueError, KeyError):
            continue
        if (session and r.get("session") == session and r.get("argv") == list(argv) and r.get("cwd") == cwd
                and r.get("mode") in DIALOG_MODES and 0 <= age <= ASKED_MAX_AGE and n == "%s.json" % r.get("id")):
            return p, r
    return None, None


def version_ok():
    """The running Claude Code is VERSION_FLOOR or later, read from the `X.Y.Z (Claude Code)` line of `$CLAUDE_CODE_EXECPATH
    --version`, else of `claude --version` (an npm install's EXECPATH is node, whose version is not Claude Code's)."""
    exe = os.environ.get("CLAUDE_CODE_EXECPATH", "")
    for prog in ([exe] if os.path.isabs(exe) else []) + ["claude"]:
        try:
            out = subprocess.run([prog, "--version"], capture_output=True, text=True, timeout=5).stdout
        except (OSError, subprocess.SubprocessError):
            continue
        m = re.search(r"(\d+)\.(\d+)\.(\d+)[^\n]*Claude Code", out or "")
        if m:
            return tuple(int(x) for x in m.groups()) >= VERSION_FLOOR
    return False


def account_home():
    """The account's home from the password database: HOME can be emptied or pointed elsewhere, this cannot."""
    try:
        import pwd
        return pwd.getpwuid(os.getuid()).pw_dir
    except (ImportError, KeyError):
        return ""


def ancestors():
    """[(argv, cwd or None, CLAUDE_CONFIG_DIR or None, HOME or None)] of the ancestor processes (Linux /proc, else `ps`)."""
    out, pid = [], os.getppid()
    for _ in range(64):
        if pid <= 1:
            break
        argv, ppid, cwd, cfg, hm = None, 0, None, None, None
        try:
            with open("/proc/%d/cmdline" % pid, "rb") as f:
                argv = [a.decode("utf-8", "replace") for a in f.read().split(b"\0") if a]
            with open("/proc/%d/stat" % pid) as f:
                ppid = int(f.read().rsplit(")", 1)[1].split()[1])
            try:
                cwd = os.readlink("/proc/%d/cwd" % pid)
                with open("/proc/%d/environ" % pid, "rb") as f:
                    for kv in f.read().split(b"\0"):
                        if kv.startswith(b"CLAUDE_CONFIG_DIR="):
                            cfg = kv.split(b"=", 1)[1].decode("utf-8", "replace")
                        elif kv.startswith(b"HOME="):
                            hm = kv.split(b"=", 1)[1].decode("utf-8", "replace")
            except OSError:
                pass
        except (OSError, ValueError, IndexError):
            try:
                r = subprocess.run(["ps", "-o", "ppid=,args=", "-p", str(pid)], capture_output=True, text=True, timeout=5)
                ppid_s, _, args = r.stdout.strip().partition(" ")
                ppid, argv = int(ppid_s), args.split()
            except (OSError, ValueError, subprocess.SubprocessError):
                break
        out.append((argv or [], cwd, cfg, hm))
        pid = ppid
    return out


def proc_start(pid):
    """A process's start time in seconds (Linux: boot time plus its start ticks; else now minus `ps` etime), or None."""
    try:
        with open("/proc/%d/stat" % pid) as f:
            ticks = int(f.read().rsplit(")", 1)[1].split()[19])
        with open("/proc/stat") as f:
            boot = next(int(l.split()[1]) for l in f if l.startswith("btime "))
        return boot + ticks / float(os.sysconf("SC_CLK_TCK"))
    except (OSError, ValueError, IndexError, StopIteration):
        pass
    try:
        et = subprocess.run(["ps", "-o", "etime=", "-p", str(pid)], capture_output=True, text=True, timeout=5).stdout.strip()
        days, _, hms = et.rpartition("-")
        secs = 0
        for part in hms.split(":"):
            secs = secs * 60 + int(part)
        return time.time() - secs - int(days or 0) * 86400
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def lineage():
    """[(pid, argv, start)] of this process and its ancestors, nearest first."""
    out, pid = [], os.getpid()
    for _ in range(64):
        if pid < 2:
            break
        argv, ppid = [], 0
        try:
            with open("/proc/%d/cmdline" % pid, "rb") as f:
                argv = [a.decode("utf-8", "replace") for a in f.read().split(b"\0") if a]
            with open("/proc/%d/stat" % pid) as f:
                ppid = int(f.read().rsplit(")", 1)[1].split()[1])
        except (OSError, ValueError, IndexError):
            try:
                r = subprocess.run(["ps", "-o", "ppid=,args=", "-p", str(pid)], capture_output=True, text=True, timeout=5)
                ppid_s, _, args = r.stdout.strip().partition(" ")
                ppid, argv = int(ppid_s), args.split()
            except (OSError, ValueError, subprocess.SubprocessError):
                break
        out.append((pid, argv, proc_start(pid)))
        pid = ppid
    return out


def is_claude(argv):
    """An argv of Claude Code: its program (or node's script) named in CLAUDE_PROGRAMS or a path under claude/versions/."""
    head = argv[:argv.index("--")] if "--" in argv else argv
    return any(os.path.basename(a) in CLAUDE_PROGRAMS or "/claude/versions/" in a for a in head[:2])


def claude_index(lin, hint=""):
    """The index in `lin` of the Claude Code process above this one: the ancestor whose pid is `hint` (CLAUDE_PID, which Claude
    Code sets), else the nearest one whose argv is Claude Code's; None when there is none."""
    for i, (pid, _a, _s) in enumerate(lin[1:], 1):
        if str(pid) == str(hint):
            return i
    for i, (_p, argv, _s) in enumerate(lin[1:], 1):
        if is_claude(argv):
            return i
    return None


def headless(argv):
    head = argv[:argv.index("--")] if "--" in argv else argv
    return "-p" in head or "--print" in head


def flag_values(argv, flag):
    """Values of `flag` in an argv, in both `--flag value` and `--flag=value` forms."""
    vals = []
    for i, a in enumerate(argv):
        if a == flag and i + 1 < len(argv):
            vals.append(argv[i + 1])
        elif a.startswith(flag + "="):
            vals.append(a[len(flag) + 1:])
    return vals


def print_run(anc):
    """True when an ancestor is Claude Code run with -p/--print: no one answers its dialog."""
    for argv, _c, _g, _h in anc:
        if is_claude(argv) and headless(argv):
            return True
    return False


def has_permission_request(obj):
    hooks = obj.get("hooks") if isinstance(obj, dict) else None
    return isinstance(hooks, dict) and bool(hooks.get("PermissionRequest"))


def plugin_answers(root):
    """A plugin directory whose hooks/hooks.json, or a hooks object or hooks file(s) its manifest names, has the hook."""
    if has_permission_request(load_json(os.path.join(root, "hooks", "hooks.json"))):
        return True
    man = load_json(os.path.join(root, ".claude-plugin", "plugin.json"))
    hooks = man.get("hooks") if isinstance(man, dict) else None
    if isinstance(hooks, dict):
        return has_permission_request(man)
    for h in [hooks] if isinstance(hooks, str) else hooks if isinstance(hooks, list) else []:
        if isinstance(h, str) and has_permission_request(load_json(os.path.join(root, h))):
            return True
        if isinstance(h, dict) and has_permission_request({"hooks": h}):
            return True
    return False


def worktrees():
    try:
        r = subprocess.run(["git", "worktree", "list", "--porcelain"], capture_output=True, text=True, timeout=10)
        return [l[len("worktree "):] for l in r.stdout.splitlines() if l.startswith("worktree ")] if r.returncode == 0 else []
    except (OSError, subprocess.SubprocessError):
        return []


def answerers(anc):
    """What can answer Claude Code's permission prompt in place of a human, as far as settings and processes show: the union
    of every place the running session may take settings from (each config directory, each worktree, each ancestor's
    directory), so a call from another directory or environment can only see more (vibemaestro-brain's answerers)."""
    found = []
    cfgs = [os.path.join(h, ".claude") for h in (os.environ.get("HOME", ""), account_home()) if os.path.isabs(h)]
    cfgs.append(claude_config_dir())
    rel = lambda v, cwd: v if os.path.isabs(v) or not cwd else os.path.join(cwd, v)                 # noqa: E731
    cfgs += [rel(c, cwd) for _, cwd, c, _ in anc if c]
    cfgs += [os.path.join(rel(h, cwd), ".claude") for _, cwd, _, h in anc if h]
    cfgs = [c for c in cfgs if os.path.isabs(c)]
    roots = [os.getcwd()] + worktrees() + [a[1] for a in anc if a[1]]
    proj = os.environ.get("CLAUDE_PROJECT_DIR", "")
    roots += [proj] if os.path.isabs(proj) else []
    files = [("user settings", os.path.join(c, "settings.json")) for c in cfgs]
    for r in roots:
        files += [("project settings", os.path.join(r, ".claude", "settings.json")),
                  ("local settings", os.path.join(r, ".claude", "settings.local.json"))]
    files += [("managed settings", p) for p in MANAGED_SETTINGS]
    enabled, seen = {}, set()
    for label, p in files:
        key = os.path.realpath(p)
        if key in seen:
            continue
        seen.add(key)
        s = load_json(p)
        if has_permission_request(s):
            found.append("a PermissionRequest hook in the %s" % label)
        if isinstance(s, dict) and isinstance(s.get("enabledPlugins"), dict):
            enabled.update({k: v for k, v in s["enabledPlugins"].items() if v is True or k not in enabled})
    for c in sorted(set(cfgs)):
        reg = load_json(os.path.join(c, "plugins", "installed_plugins.json"))
        plugins = reg.get("plugins") if isinstance(reg, dict) else None
        for key, entries in sorted(plugins.items() if isinstance(plugins, dict) else []):
            if enabled.get(key) is not True:
                continue
            for e in entries if isinstance(entries, list) else []:
                if isinstance(e, dict) and plugin_answers(str(e.get("installPath", ""))):
                    found.append("a PermissionRequest hook in the enabled plugin %s" % key.split("@")[0])
    for argv, cwd, _, _ in anc:
        if any(a == "--permission-prompt-tool" or a.startswith("--permission-prompt-tool=") for a in argv):
            found.append("a process started with --permission-prompt-tool")
        for v in flag_values(argv, "--settings"):
            if v.lstrip().startswith("{"):
                try:
                    s = json.loads(v)
                except ValueError:
                    s = None
            else:
                s = load_json(rel(v, cwd))
            if has_permission_request(s):
                found.append("a PermissionRequest hook in --settings of a parent process")
        for v in flag_values(argv, "--plugin-dir"):
            if plugin_answers(rel(v, cwd)):
                found.append("a PermissionRequest hook in a --plugin-dir of a parent process")
    return sorted(set(found))


def owner_unsafe(anc, what="sign --by owner"):
    """The allow rules that would let `sign --by owner` (or, what="mode", a mode change) run with no dialog: the UNSAFE findings
    of `permissions --check` for it, over the settings files and every --settings file of an ancestor."""
    sources = list(settings_sources())
    for argv, cwd, _, _ in anc:
        sources += [("given", v if os.path.isabs(v) or not cwd else os.path.join(cwd, v))
                    for v in flag_values(argv, "--settings") if not v.lstrip().startswith("{")]
    rules, _p = load_rules(sources)
    out = []
    for cmd in (mode_probes() if what == "mode" else owner_probes()):
        d, r = decide(rules, cmd)
        if d == "allow":
            out.append("the allow rule `%s` (%s) lets `%s` run with no dialog" % (r[0], r[1], what))
        out += ["the allow rule `%s` (%s) matches `%s`" % (text, where, what) for k, tool, content, text, where in rules
                if k == "allow" and tool == "Bash" and bash_matches(content, cmd) and d != "allow"]
    return sorted(set(out))


def owner_proof(argv):
    """(why, record path, record) for this `sign --by owner` (argv: the words after `sign`) or mode change (argv: `mode` and its
    words): why is None when it has the owner's dialog. The path is that of the record found, also when a later check refuses, so the attempt uses it up; except a process
    outside the lineage (not started by the asking Claude Code after the ask), which gets no path and leaves the record."""
    path, rec = find_asked(session_id(), argv, os.path.realpath(os.getcwd())) if session_id() else (None, None)
    if path and LINEAGE:                                # first: a process outside the lineage never touches the record
        lin, claude = lineage(), rec.get("claude") or [None, None]
        at = [i for i, (pid, _a, st) in enumerate(lin) if i > 0 and pid == claude[0] and st is not None
              and claude[1] is not None and abs(st - claude[1]) < 1]
        child = lin[at[0] - 1][2] if at else None
        if child is None or rec.get("after") is None or child < rec["after"]:
            return ("this process was not started by the Claude Code process that asked, after it asked: only the command the "
                    "owner's dialog runs may use the record"), None, rec   # kept: no such process can ever pass, the dialog's can
    mode = argv[:1] == ["mode"]
    nod = NO_MODE_DIALOG if mode else NO_OWNER_DIALOG
    if in_sandbox():
        return ("a sandbox session: whoever answers its dialog is not the owner, so the owner %s only outside a sandbox (%s)"
                % (("sets the mode", "mode unchanged") if mode else ("signs", "nothing signed"))), path, rec
    if not session_id():
        return "no Claude Code session (CLAUDE_CODE_SESSION_ID): " + nod, None, None
    if path is None:
        return ("no fresh record of the owner's dialog for this very command in this session: %s. Stop and tell the owner: if "
                "they clicked yes, the record had expired (%d s), another Bash call of this session voided it, or an earlier "
                "attempt used it up, and only the owner's word starts a new dialog; never run it again on your own or another way"
                % (nod, ASKED_MAX_AGE)), None, None
    anc = ancestors()
    if print_run(anc):
        return "a -p run: no one answers its dialog", path, rec
    ans = answerers(anc)
    if ans:
        return "something can answer the dialog in place of a human: " + "; ".join(ans), path, rec
    bad = owner_unsafe(anc, "mode" if mode else "sign --by owner")
    if bad:
        return "; ".join(bad) + " (remove it: `permissions --check` names it)", path, rec
    return None, path, rec


def owner_signs(asked):
    """The owner's dialog for this `sign --by owner` (asked: the words after `sign`), checked before anything else and used up
    by any attempt from inside the lineage (owner_proof): the record's id, or Stop(REFUSED)."""
    why, path, rec = owner_proof(asked)
    try:
        if path:
            os.unlink(path)                             # one dialog, one sign attempt
    except OSError as e:
        why = why or "the record of the owner's dialog cannot be used up (%s)" % (e.strerror or e)
    if why:
        try:
            log_event(ensure_state(), event="sign", result="refused", args=asked, dir=os.path.realpath(os.getcwd()),
                      signed_by="owner", output=why)
        except (OSError, Stop):
            pass
        raise Stop(REFUSED, "sign refused: %s", why)
    RUN["asked_kept"] = (rec.get("script_path"), rec.get("script_sha256"))
    RUN["asked_queued"], RUN["asked_claude"] = rec.get("queued"), rec.get("claude")
    return rec["id"]


def owner_sets_mode(argv):
    """The owner's dialog for this mode change (argv: `mode` and its words), checked and used up as owner_signs does: the
    record's id, or Stop(REFUSED) with the mode unchanged."""
    why, path, rec = owner_proof(argv)
    try:
        if path:
            os.unlink(path)                             # one dialog, one attempt
    except OSError as e:
        why = why or "the record of the owner's dialog cannot be used up (%s)" % (e.strerror or e)
    if why:
        try:
            log_event(ensure_state(), event="mode", result="refused", args=argv, dir=os.path.realpath(os.getcwd()), output=why)
        except (OSError, Stop):
            pass
        raise Stop(REFUSED, "mode refused: %s", why)
    return rec["id"]


def program_at(ws, tilde=False):
    """The index after the program words when ws starts with this plugin's baton.py or the installed launcher by absolute path
    (or `python3[.N] [flags] <baton.py>`), else None. tilde: the launcher spelled ~/… as the kit's text prints it also counts."""
    own = {os.path.realpath(os.path.abspath(__file__)), os.path.realpath(launcher_path())}
    if tilde and ws and tilde_launcher() and ws[0] == tilde_launcher():
        return 1
    if not ws or not SAFE_WORD.match(ws[0]):
        return None
    if os.path.isabs(ws[0]) and os.path.realpath(ws[0]) in own:
        return 1
    if re.fullmatch(r"python3(?:\.[0-9]+)?", ws[0]):
        i = 1
        while i < len(ws) and ws[i] in PY_FLAGS:
            i += 1
        if i < len(ws) and os.path.isabs(ws[i]) and os.path.realpath(ws[i]) == os.path.realpath(os.path.abspath(__file__)):
            return i + 1
    return None


def mode_shape(cmd):
    """The argv (`mode` and its words) when `cmd` is exactly a printed mode change (an allowlist: SHAPE_MODE), else None."""
    if not re.fullmatch(r"[\x20-\x7e]+", cmd):
        return None
    ws = [w for w in cmd.split(" ") if w != ""]
    i = program_at(ws, tilde=True)
    if i is None or not all(SAFE_WORD.match(w) for w in ws[i:]):
        return None
    rest = ws[i:]
    if rest[:1] != ["mode"] or len(rest) < 2 or rest[1] not in MODE_WRITES:
        return None
    if rest[1] in MODES:
        return rest if len(rest) == 2 else None
    return rest if len(rest) == 3 and plain_remote(rest[2]) else None


def owner_shape(cmd):
    """The argv after `sign` when `cmd` is exactly the printed owner command (an allowlist: SHAPE), else None. Nothing else is
    parsed: a command that deviates in any character is not asked about."""
    if not re.fullmatch(r"[\x20-\x7e]+", cmd):
        return None
    ws = cmd.split(" ")
    ws = [w for w in ws if w != ""]
    if not ws or not all(SAFE_WORD.match(w) for w in ws):
        return None
    own = {os.path.realpath(os.path.abspath(__file__)), os.path.realpath(launcher_path())}
    if os.path.isabs(ws[0]) and os.path.realpath(ws[0]) in own:
        i = 1
    elif re.fullmatch(r"python3(?:\.[0-9]+)?", ws[0]):
        i = 1
        while i < len(ws) and ws[i] in PY_FLAGS:
            i += 1
        if not (i < len(ws) and os.path.isabs(ws[i]) and os.path.realpath(ws[i]) == os.path.realpath(os.path.abspath(__file__))):
            return None
        i += 1
    else:
        return None
    rest = ws[i:]
    if rest[:4] == ["sign", "--by", "owner", "--queued"]:
        return rest[1:] if len(rest) == 5 and QUEUE_ID.match(rest[4]) else None
    if rest[:4] != ["sign", "--by", "owner", "--seal"] or len(rest) < 6 or not SEAL_WORD.match(rest[4]):
        return None
    if not (os.path.isabs(rest[5]) or re.fullmatch(r"(?:kit|kind|project|user):[a-z0-9][a-z0-9-]*", rest[5])):
        return None
    return rest[1:]


# guard_owner: shell words, after vibemaestro-brain's guard-owner
def segments(cmd):
    """[(text, flags)]: the command split at unquoted `;`, `&`, `|`, `(`, `)` and newlines. flags holds `expansion` ($, a
    backtick, or a ~ not at the very start), `glob` (unquoted * ? [ {), `redirect` (unquoted < >), `escape`, `control` and
    `open` (a quote left open)."""
    out, cur, flags = [], [], set()
    q, i, n, start = None, 0, len(cmd), True
    while i < n:
        c = cmd[i]
        if q == "'":
            cur.append(c)
            q = None if c == "'" else q
            i += 1
            continue
        if c in "\r\x0b\x0c":
            flags.add("control")
        if q == '"':
            if c == "\\":                               # `\"` inside double quotes is a quote, as bash reads it: no split there
                flags.add("escape")
                cur.append(cmd[i:i + 2])
                i += 2
                continue
            if c in "$`":
                flags.add("expansion")
            cur.append(c)
            q = None if c == '"' else q
            i += 1
            continue
        if c == "\\":
            flags.add("escape")
            cur.append(cmd[i:i + 2])
            i += 2
            start = False
            continue
        if c in "'\"":
            q = c
        elif c == "#" and start:
            while i < n and cmd[i] != "\n":
                i += 1
            continue
        elif c in ";&|()\n":
            flags.add("operator")                       # an operator next to the call, even with nothing on its other side
            out.append(("".join(cur), flags))
            cur, flags, start = [], {"operator"}, True
            i += 1
            continue
        elif c in "<>":
            flags.add("redirect")
        elif c == "~" and not "".join(cur).strip() and cmd[i + 1:i + 2] == "/":
            pass                                        # the launcher spelled from ~/ (tilde_launcher): the program word
        elif c in "$`~":
            flags.add("expansion")
        elif c in "*?[{":
            flags.add("glob")
        cur.append(c)
        start = c.isspace()
        i += 1
    if q:
        flags.add("open")
    out.append(("".join(cur), flags))
    return [(t, f) for t, f in out if t.strip()]


def sign_index(ws):
    """The index of `sign` when the words run baton (`baton`, the launcher, `python3 [opts] …/baton.py`), else None."""
    if not ws:
        return None
    prog = os.path.basename(ws[0])
    if prog in ("baton", "baton.py"):
        return 1
    if re.fullmatch(r"python[0-9.]*", prog):
        j = 1
        while j < len(ws) and ws[j] in PY_FLAGS:          # any other option (-c, -Sc, -m, -X …) is not a literal baton call
            j += 1
        return j + 1 if j < len(ws) and os.path.basename(ws[j]) == "baton.py" else None
    return None


def owner_calls(cmd):
    """[(kind, argv or None, not literal)] for each segment of `cmd` that runs `baton … sign --by owner` (kind "sign", argv
    the words after `sign`) or a mode change `baton … mode manual|auto|trust|untrust …` (kind "mode", argv from `mode`)."""
    found = []
    for text, flags in segments(cmd):
        try:
            ws = shlex.split(text)
        except ValueError:
            ws = None
        if ws is None:
            if re.search(r"baton.*\bsign\b.*\bowner\b", text, re.S):
                found.append(("sign", None, True))
            elif re.search(r"baton.*\bmode\s+(?:%s)\b" % "|".join(MODE_WRITES), text, re.S):
                found.append(("mode", None, True))
            continue
        lead = 0
        while lead < len(ws) and (re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", ws[lead]) or ws[lead] in OWNER_PREFIXES):
            lead += 1
        k = sign_index(ws[lead:])
        if k is not None and ws[lead + k:lead + k + 3] == ["sign", "--by", "owner"]:
            found.append(("sign", ws[lead + k + 1:], bool(flags) or lead > 0))
        elif k is not None and ws[lead + k:lead + k + 1] == ["mode"] and ws[lead + k + 1:lead + k + 2] and \
                ws[lead + k + 1] in MODE_WRITES:
            found.append(("mode", ws[lead + k:], bool(flags) or lead > 0))
    return found


def guard_owner(inp):
    """The PreToolUse Bash hook: None (no opinion), or (decision, reason) for a `sign --by owner` call or a mode change."""
    cmd = str(((inp.get("tool_input") or {}).get("command")) or "").strip(" \t\n")   # bash's blanks and newlines only; owner_shape refuses any other character
    sid = str(inp.get("session_id") or "")
    void_asked(sid)                                     # every Bash call voids the session's unused record
    found = owner_calls(cmd)
    if not found:
        return None
    is_mode = all(f[0] == "mode" for f in found)
    what = "mode" if is_mode else "sign --by owner"
    mode = str(inp.get("permission_mode") or "unknown")
    cwd = inp.get("cwd") if isinstance(inp.get("cwd"), str) and os.path.isabs(inp.get("cwd")) else os.getcwd()

    def deny(why):
        try:
            if os.path.isdir(state_dir()):                 # a denial logs, but creates no state of its own
                log_event(state_dir(), event="owner-ask", result="denied", mode=mode, dir=cwd, output=why)
        except OSError:
            pass
        return "deny", "baton: %s refused: %s" % (what, why)

    literal = not (len(found) > 1 or len(segments(cmd)) > 1 or found[0][2] or found[0][1] is None)
    if is_mode and not literal:
        segs = segments(cmd)
        at = next((i for i, (t, _f) in enumerate(segs) if owner_calls(t)), 0)
        if any("<<" in t for t, _f in segs[:at]):  # maybe a heredoc's body line: no record, so a call there refuses itself; no deny
            return None
    if in_sandbox():
        return deny("a sandbox session: whoever answers its dialog is not the owner")
    if inp.get("agent_id"):
        return deny("a subagent never %s; it reports to the main session" % ("sets the mode" if is_mode else "signs as the owner"))
    if not literal:                 # a wrapped mode call, too: an ask rule may still show its dialog, which no click could make work
        return deny(SHAPE_MODE if is_mode else LITERAL)
    shaped = mode_shape(cmd) if is_mode else owner_shape(cmd)
    if shaped is None:
        return deny(SHAPE_MODE if is_mode else SHAPE)
    if not sid:
        return deny("no session id in the hook input")
    if not (mode in ("default", "acceptEdits") or (mode == "auto" and version_ok())):
        return deny("permission mode %s shows no dialog the owner answers (default, acceptEdits, or auto from %s)"
                    % (mode, ".".join(map(str, VERSION_FLOOR))))
    lin = lineage()
    ci = claude_index(lin, os.environ.get("CLAUDE_PID", ""))
    if LINEAGE and ci is None:
        return deny("no Claude Code process above the hook, so no process can be bound to the owner's dialog")
    anc = ancestors()
    if print_run(anc) or (ci is not None and headless(lin[ci][1])):
        return deny("a -p run: no one answers its dialog")
    ans = answerers(anc)
    if ans:
        return deny("something can answer the dialog in place of a human: " + "; ".join(ans))
    bad = owner_unsafe(anc, what)
    if bad:
        return deny("; ".join(bad) + " (remove it: `permissions --check` names it)")
    argv = shaped
    if is_mode:
        log_event(ensure_state(), event="owner-ask", result="asked", mode=mode, dir=cwd, args=argv)
        record_asked(sid, mode, argv, os.path.realpath(cwd), [lin[ci][0], lin[ci][2]] if ci is not None else None,
                     lin[0][2] if lin else None)
        change = ("sets the baton mode to %s (now %s)" % (argv[1], read_mode()) if argv[1] in MODES else
                  "%s the remote %s for the baton remote list" % ("trusts" if argv[1] == "trust" else "untrusts",
                                                                   remote_canon(argv[2])))
        return "ask", ("baton: the owner %s. Your click is the owner's decision; the session never answers this dialog for you."
                       % change)
    kept = queued = it = None
    if argv[2] == "--queued":                          # a queued item: the dialog shows its card and binds its bytes
        _p, it, state = load_item(argv[3])
        why = queue_why(argv[3], state, it) if state != "pending" else queuer(it, sid, [this_claude(lin)])
        if why:
            return deny(why)
        queued = [it["id"], it["body_sha256"]]
    elif re.match(r"(?:project|user):", argv[4]):        # a kept baton: the dialog binds the pinned file the name resolves to
        here = os.getcwd()
        try:
            os.chdir(cwd)
            s = Script(argv[4])
            kept = (s.real, s.sha)
        except (Stop, OSError) as e:
            return deny("%s cannot be signed here: %s" % (argv[4], e))
        finally:
            os.chdir(here)
    log_event(ensure_state(), event="owner-ask", result="asked", mode=mode, dir=cwd, args=argv)
    record_asked(sid, mode, argv, os.path.realpath(cwd), [lin[ci][0], lin[ci][2]] if ci is not None else None,
                 lin[0][2] if lin else None, kept, queued)    # last: the hook voids it when its `ask` cannot be written
    if it is not None:
        return "ask", shown("baton: the owner signs queued item %s (%s), which the session may run until %s:\n%s\nYour click is "
                            "the owner's signature; the session never answers this dialog for you.", it["id"], it["name"],
                            it["expires"], shown_join("\n", item_lines(it)))
    return "ask", ("baton: the owner signs %s%s. Your click is the owner's signature; the session never answers this "
                   "dialog for you." % (" ".join(shlex.quote(a) for a in argv[2:]),
                                        " (%s, sha256 %s)" % (esc(kept[0]), kept[1]) if kept else ""))


# ── the owner's queue ──────────────────────────────────────────────────────────────────────────────────────────────────────────
# A run that needs the owner waits for them in a file instead of a dialog that freezes the session: `go --queue` seals it as `go`
# does and writes an item; the owner signs the item later, in a Claude Code session of their own, with `sign --by owner --queued
# <id>`, through the same guard, dialog and record as `--seal`; `run --queued <id>` runs it once, within QUEUE_LIFE, while its
# rehearse still gives the sealed plan. The session that queued an item never signs it, nor does its Claude Code process under a
# new session id (/clear): a click there would freeze the session the queue keeps working. body_sha256 binds every field and the
# signature names it, so bytes changed after the dialog opened, or after signing, are refused. Like the rest of baton, it guards
# against slips, not same-user forgery of the state files.
QUEUE_LIFE = 24 * 3600
QUEUE_KEEP = 7 * 24 * 3600                             # an item this long past its expiry is removed, a used one too
QUEUE_ID = re.compile(r"[0-9a-f]{16}\Z")
QUEUE_WAIT_MAX = 24 * 3600
QUEUE_MAX = 1 << 20


def queue_dir():
    return os.path.join(state_dir(), "queue")


def item_digest(item):
    """sha256 of every field of a queued item but its body_sha256 and signature."""
    body = {k: v for k, v in item.items() if k not in ("body_sha256", "signature")}
    return sha256(json.dumps(body, sort_keys=True, separators=(",", ":")))


def load_item(qid, now=None):
    """(path, item, state) of a queued item; state is pending, signed, expired, used, damaged (bytes changed since baton wrote
    them, or not an item: item None, nothing of it is trusted) or absent (path None)."""
    now = time.time() if now is None else now
    for path, used in ((os.path.join(queue_dir(), qid + ".json"), False), (os.path.join(queue_dir(), "used", qid + ".json"), True)):
        if not os.path.lexists(path):
            continue
        try:
            it = json.loads(read_small(path, QUEUE_MAX))
        except (OSError, ValueError):
            return path, None, "damaged"
        sig = it.get("signature") if isinstance(it, dict) else None
        exp = iso_seconds(str(it.get("expires"))) if isinstance(it, dict) else None
        if (not isinstance(it, dict) or it.get("v") != 1 or it.get("id") != qid or exp is None or it.get("body_sha256") != item_digest(it)
                or (sig is not None and not (isinstance(sig, dict) and sig.get("by") == "owner" and sig.get("dialog")
                                             and sig.get("body_sha256") == it["body_sha256"]))):
            return path, None, "damaged"
        if used:
            return path, it, "used"
        if now > exp:
            return path, it, "expired"
        return path, it, "signed" if sig is not None else "pending"
    return None, None, "absent"


def queue_why(qid, state, it):
    """Why item `qid` in `state` cannot be signed (pending excepted) or run (signed excepted)."""
    return {"absent": "no queued item %s" % qid,
            "damaged": "item %s is damaged: its bytes changed since baton wrote them, so it is never signed or run" % qid,
            "used": "item %s was used already: one run per signature" % qid,
            "expired": "item %s expired at %s: the session queues it again" % (qid, (it or {}).get("expires")),
            "pending": ("item %s is not signed yet: the owner signs it in a Claude Code session of their own "
                        "(/vibemaestro-sdlc:owner-sign)" % qid),
            "signed": "item %s is signed already" % qid}[state]


def item_lines(it):
    """What the owner signs, from the item's own fields: the script, the directory and the words as given, then the card
    without its heading and its mode question (the dialog and `log --queue` show these)."""
    card = [ln for ln in it.get("card") or [] if not str(ln).startswith(("==", "  Mode:"))]
    return ["  Script:   %s (%s, sha256 %s)" % (it.get("word"), it.get("script_path"), it.get("script_sha256")),
            "  Dir:      %s" % it.get("cwd"),
            "  Args:     %s" % (" ".join(quoted(str(a)) for a in it.get("call") or []) or "(none)")] + card


def this_claude(lin=None):
    """[pid, start] of the Claude Code process above this one (claude_index), else of the CLAUDE_PID that Claude Code set when
    that process is not an ancestor (a call under setsid); None when neither is known."""
    lin = lineage() if lin is None else lin
    hint = os.environ.get("CLAUDE_PID", "")
    ci = claude_index(lin, hint)
    if ci is not None and lin[ci][2] is not None:
        return [lin[ci][0], lin[ci][2]]
    start = proc_start(int(hint)) if re.fullmatch(r"[1-9][0-9]{0,9}", hint) else None
    return [int(hint), start] if start is not None else None


def same_claude(a, b):
    """The same Claude Code process: its pid, and a start time within a minute (a start derived from the clock moves with it; a
    false match only refuses a sign)."""
    return (isinstance(a, list) and isinstance(b, list) and len(a) == len(b) == 2 and None not in a and None not in b
            and a[0] == b[0] and abs(a[1] - b[1]) < 60)


def queuer(it, session, claudes):
    """Why the caller is the one that queued `it` (None when it is not): its session id, or its Claude Code process."""
    if it.get("session") and session == it["session"]:
        return "this is the session that queued item %s: the owner signs it in a Claude Code session of their own" % it["id"]
    if any(same_claude(it.get("claude"), c) for c in claudes):
        return ("this is the Claude Code process that queued item %s (a /clear gives it a new session id, not a new process): the "
                "owner signs it in a Claude Code session of their own" % it["id"])
    return None


def prune_queue(q, now):
    for sub in (q, os.path.join(q, "used")):
        try:
            names = os.listdir(sub)
        except OSError:
            continue
        for n in names:
            p = os.path.join(sub, n)
            r = load_json(p) if n.endswith(".json") else None
            exp = iso_seconds(str(r.get("expires"))) if isinstance(r, dict) else None
            try:
                if os.path.isfile(p) and now - (exp if exp is not None else os.lstat(p).st_mtime) > QUEUE_KEEP:
                    os.unlink(p)
            except OSError:
                pass


def queue_item(s, word, call, args, plan, stops, mode, card, detail):
    """Write the item of a sealed run that needs the owner; returns it."""
    d = ensure_state()
    q = os.path.join(d, "queue")
    try:
        os.makedirs(os.path.join(q, "used"), mode=0o700, exist_ok=True)
        os.chmod(q, 0o700)
    except OSError as e:
        raise Stop(ENV, "the queue directory %s cannot be written: %s", q, e.strerror or e)
    now = int(time.time())
    prune_queue(q, now)
    cwd, env = os.path.realpath(os.getcwd()), steering()
    binding = binding_of(s.bind_sha, args, cwd, env, s.inputs)
    it = {"v": 1, "id": os.urandom(8).hex(), "created": iso_at(now), "expires": iso_at(now + QUEUE_LIFE), "session": session_id(),
          "claude": this_claude(), "name": s.name, "word": word, "call": list(call), "script_path": s.real, "script_sha256": s.sha,
          "baton": s.baton_id(), "args": args, "cwd": cwd, "env": env, "binding": binding, "seal": seal_of(binding, plan),
          "plan": plan, "plan_sha256": plan_sha(plan), "stops": stops, "mode": mode, "card": card, "detail": detail}
    if s.inputs is not None:
        it["inputs"] = s.inputs
    it["body_sha256"] = item_digest(it)
    write_private(os.path.join(q, it["id"] + ".json"), json.dumps(it, indent=1, sort_keys=True) + "\n")
    log_event(d, event="queue", result="queued", name=s.name, script=s.sha[:12], binding=binding[:12], args=args, dir=cwd, mode=mode,
              output=it["id"], baton=s.baton_id())
    return it


def signed_queued(qid, dialog):
    """The owner's signature of a queued item, once cmd_sign used up the dialog's record: written into the item, naming its body."""
    d = ensure_state()
    path, it, state = load_item(qid)

    def refuse(why):
        log_event(d, event="queue", result="refused", name=(it or {}).get("name"), args=(it or {}).get("args"),
                  dir=(it or {}).get("cwd"), signed_by="owner", output=qid)
        raise Stop(REFUSED, "sign refused: %s", why)

    if state != "pending":
        refuse(queue_why(qid, state, it))
    if RUN.get("asked_queued") != [qid, it["body_sha256"]]:
        refuse("item %s changed since the dialog opened (or the dialog showed another one): show it and ask again" % qid)
    why = queuer(it, session_id(), [this_claude(), RUN.get("asked_claude")])
    if why:
        refuse(why)
    here = os.getcwd()
    try:
        os.chdir(it["cwd"])
        s = Script(it["word"])
    except (Stop, OSError) as e:
        refuse("its script cannot be read from %s: %s" % (it["cwd"], e))
    finally:
        os.chdir(here)
    if (s.real, s.sha) != (it["script_path"], it["script_sha256"]):
        refuse("its script changed since it was queued (now %s at sha256 %s): the session queues it again" % (s.real, s.sha))
    it["signature"] = {"by": "owner", "dialog": dialog, "session": session_id(), "time": now_iso(), "body_sha256": it["body_sha256"]}
    write_private(path, json.dumps(it, indent=1, sort_keys=True) + "\n")
    log_event(d, event="queue", result="signed", name=it["name"], script=it["script_sha256"][:12], binding=it["binding"][:12],
              args=it["args"], dir=it["cwd"], signed_by="owner", mode=it["mode"], output=qid, baton=it["baton"])
    say("signed queued %s by owner: %s, %d planned write%s, from %s; the session runs it before %s", qid, it["name"], len(it["plan"]),
        "" if len(it["plan"]) == 1 else "s", it["cwd"], it["expires"])
    return OK


def queued_call(qid):
    """(word, call, (path, item)) of a signed item this directory may run, else Stop(REFUSED)."""
    path, it, state = load_item(qid)
    cwd = os.path.realpath(os.getcwd())
    if state != "signed":
        why = queue_why(qid, state, it)
    elif cwd != it["cwd"]:
        why = "item %s was queued in %s: run it from there" % (qid, it["cwd"])
    else:
        return it["word"], list(it["call"]), (path, it)
    log_event(ensure_state(), event="run", result="refused", name=(it or {}).get("name"), dir=cwd, output=qid)
    raise Stop(REFUSED, "run refused, nothing ran: %s", why)


def queue_list(rest):
    if rest:
        raise Stop(USAGE, "usage: baton.py log --queue")
    ids = set()
    for sub in ("", "used"):
        try:
            ids.update(n[:-5] for n in os.listdir(os.path.join(queue_dir(), sub)) if n.endswith(".json") and QUEUE_ID.match(n[:-5]))
        except OSError:
            pass
    rows = [(qid,) + load_item(qid)[1:] for qid in ids]
    if not rows:
        say("queue: no item")
        return OK
    for qid, it, state in sorted(rows, key=lambda r: ((r[1] or {}).get("created", ""), r[0])):
        if it is None:
            say("%s  %s  (its bytes changed since baton wrote them: never signed, never run)", qid, state)
            continue
        say("%s  %s  %s  created %s  expires %s", qid, state, it.get("name"), it.get("created"), it.get("expires"))
        if state == "used":
            continue
        for ln in item_lines(it):
            say("  %s", ln)
        if it.get("detail"):
            say("  detail: %s (check and rehearse output)", it["detail"])
        if state == "pending":
            say("  the owner signs, in a Claude Code session of their own: %s sign --by owner --queued %s", entry_command(), qid)
        elif state == "signed":
            sig = it["signature"]
            say("  signed by owner at %s; the session runs it: %s run --queued %s", sig.get("time"), entry_command(), qid)
    return OK


def queue_wait(rest):
    """log --wait-queued: wait until the item is signed (0), can no longer be (3), or the deadline (9)."""
    usage = "usage: baton.py log --wait-queued <id> [--timeout S]  (S 1-%d, default %d)" % (QUEUE_WAIT_MAX, WAIT_MAX)
    timeout = WAIT_MAX
    if len(rest) == 3 and rest[1] == "--timeout" and re.match(r"^[1-9]\d{0,5}$", rest[2]) and int(rest[2]) <= QUEUE_WAIT_MAX:
        timeout = int(rest[2])
    elif len(rest) != 1:
        raise Stop(USAGE, "%s", usage)
    if not QUEUE_ID.match(rest[0]):
        raise Stop(USAGE, "%s", usage)
    qid, deadline, state, it = rest[0], time.time() + timeout, "pending", None
    try:
        while True:
            _p, it, state = load_item(qid)
            if state != "pending" or time.time() >= deadline:
                break
            time.sleep(min(1.0, max(0.0, deadline - time.time())))
    except (KeyboardInterrupt, Interrupted):
        say("wait: interrupted")
        return WAIT_UNMET
    if state == "signed":
        say("wait: ok — item %s (%s) signed by owner at %s; run it: %s run --queued %s", qid, it["name"], it["signature"].get("time"),
            entry_command(), qid)
        return OK
    if state == "pending":
        say("wait: not met after %d s — item %s is not signed yet", timeout, qid)
        return WAIT_UNMET
    say("wait: %s", queue_why(qid, state, it))
    return REFUSED


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
            raise Stop(USAGE, "%s", usage)
    if not name or not NAME_RE.match(name):
        raise Stop(USAGE, "the name is lower-case letters, digits and hyphens: [a-z0-9][a-z0-9-]*")
    if not os.path.isdir(d):
        raise Stop(USAGE, "--dir %s is not a directory", d)
    template = TEMPLATE
    if kind is not None:
        path = os.path.join(KINDS_DIR, kind + ".sh")
        if not KIND_RE.match(kind) or not os.path.isfile(path):
            raise Stop(USAGE, "--from %s: no such kind; the kinds are %s", kind, ", ".join(kinds()) or "(none)")
        template = path
    try:
        with open(template, encoding="utf-8") as f:
            text = f.read().replace("__NAME__", name)
    except OSError as e:
        raise Stop(ENV, "the template %s cannot be read: %s", template, e.strerror or e)
    path = os.path.join(d, name + ".sh")
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    except FileExistsError:
        raise Stop(EXISTS, "%s already exists; nothing written", path)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    say("written %s: edit the header and the act, then `baton.py check %s`", path, path)
    return OK


def checked(path, pin=True):
    """The script at path once it passes check; otherwise its problems are printed and Stop(BAD_SCRIPT) is raised. pin=False
    (check alone) reads a project: or user: baton whether or not it is pinned: check never runs it."""
    s = Script(path, pin)
    need_bash()
    probs = check_script(s)
    if probs:
        print_problems(s, probs)
        raise Stop(BAD_SCRIPT, "check failed: fix the script, then check again")
    return s


def cmd_check(rest):
    if len(rest) != 1:
        raise Stop(USAGE, "usage: baton.py check <script>")
    s = checked(rest[0], pin=False)
    if s.kept is not None and not s.kept.pinned and not s.kept.retired:
        s.kept.reviewed(s.data)
    say("check ok: %s (sha256 %s)%s", s.path, s.sha[:12], "; %s, %s" % (
        "pinned" if s.kept.pinned else "not pinned on this machine, callable as reviewed" if s.kept.review else
        "these bytes were retired: it cannot be called" if s.kept.retired else
        "not pinned on this machine: it cannot be called", s.label()) if s.kept is not None else "")
    return OK


def header_summary(s, out):
    say("baton script %s (sha256 %s)%s", s.path, s.sha[:12],
        " from %s" % log_value(s.from_kit.pid) if s.kit and s.from_kit.pid else "", out=out)
    for key in HEADER_FIELDS[:-1]:
        if key != "Each" or key in s.fields:
            say("  %-8s %s", key + ":", s.field(key), out=out)
    for key in OPTIONAL_FIELDS:
        if key in s.fields:
            say("  %-8s %s", key + ":", s.field(key), out=out)
    if s.kept is not None:
        say("  %-8s %s is %s, sha256 %s; %s%s", "Kept:", s.word, s.real, s.sha, s.label(), origin_note(s.kept, s.data), out=out)
    for line in s.param_lines:                          # one per value, never cut, before the plan lines
        say("%s", line, out=out)


def script_and_args(rest, usage):
    if rest and rest[0] == "--":
        rest = rest[1:]
    if not rest:
        raise Stop(USAGE, "%s", usage)
    return rest[0], list(rest[1:])


def rehearsed(s, args, out):
    """The body of `rehearse` once check passed: the header, the rehearse phase, the plan against Expect, the seal; all to `out`.
    (plan, reasons, seal): seal is None when the rehearse failed."""
    header_summary(s, out)
    good, plan, reasons = rehearse(s, args, [out])
    if not good:
        for r in reasons:
            say("FAIL %s", r, out=out)
        say("rehearse FAILED: fix the script or its Expect, then rehearse again", out=out)
        return plan, reasons, None
    cwd, env = os.path.realpath(os.getcwd()), steering()
    seal = seal_of(binding_of(s.bind_sha, args, cwd, env, s.inputs), plan)
    say("seal %s (binding of script sha256 %s, %d argument%s, directory %s and environment; then the plan)", seal, s.sha[:12],
        len(args), "" if len(args) == 1 else "s", cwd, out=out)
    return plan, reasons, seal


def owner_commands(path, args, seal):
    # a file by its absolute path: the owner's guard asks only for that shape (owner_shape)
    path = path if re.match(r"(?:kit|kind|project|user):", path) else os.path.abspath(path)
    words = " ".join(shlex.quote(a) for a in [path] + args)
    return "%s sign --by owner --seal %s %s" % (entry_command(), seal, words), "%s run %s" % (entry_command(), words)


def sandbox_handoff(path, args, seal, stops, params):
    """The lines a pod session reads after the decision card in place of the owner's sign and run commands: nobody in a pod
    signs as the owner (its guard refuses it), so the call goes to the coordinator, under a name its machine can run. A session
    script is kept as `project:<name>` and carried by the PR, whether its stop is a stop-list item or only mode manual (with
    `Stops: none`: then it never ran, and the coordinator's `go` is its first run); `pack` keeps only a baton that declares
    Params, and a script given them changes its bytes, args and seal, so one without them is sent back to `go` first. A kit, a
    kind or a kept baton has nothing to pack: only the call is handed over. The seal is of the file as it stands here: the
    coordinator's own `go` on the kept baton shows the one it signs."""
    call = lambda name, note="": "tell the coordinator the call: name %s, args %s, seal %s%s" % (
        name, " ".join(shlex.quote(a) for a in args) or "(none)", seal, note)
    lines = ["in a sandbox pod nobody signs as the owner: hand the call to the coordinator"]
    if place_of(path) is None:
        if not params:
            return ["in a sandbox pod nobody signs as the owner, and this script cannot be handed over yet: add a `# Params:` "
                    "header (the script reads its values from it), then `go` on it again with key=value args; that `go` prints "
                    "the hand-off"]
        name = os.path.splitext(os.path.basename(path))[0]
        name = (name if KIT_RE.match(name) and len(name) <= KEPT_NAME_MAX and name not in kit_names() and
                not COPY_NAME.search(name) else "<name>")       # a name pack refuses is no call: the session picks one
        return lines + ["  1. keep it: %s pack %s project:%s" % (entry_command(), shlex.quote(os.path.abspath(path)), name),
                        "  2. commit .vibemaestro/batons/%s.sh on your branch and open the PR" % name,
                        "  3. " + call("project:" + name, " (of this copy)" if stops else " (of this copy; %s)" % NEVER_RAN)]
    return lines + ["  " + call(path)]


def needs_quoting(s, args):
    """The first value of a baton with Params that the owner's literal sign command cannot carry as typed (it needs shell
    quoting, or is not printable ASCII), else None. The guard asks only for a literal command, and is not widened for values:
    such a value goes through an input file."""
    if s.params is None:
        return None
    return next((a for a in args if not (re.match(r"[\x20-\x7e]+\Z", a) and SAFE_WORD.match(a))), None)


def quoting_note(word):
    return ("no owner command: the value %s needs quoting, which the owner's dialog cannot show as typed; pass that text "
            "through an input file (an input parameter), then go again" % quoted(word))


def cmd_rehearse(rest):
    path, args = script_and_args(rest, "usage: baton.py rehearse <script> [args...]")
    s = checked(path)
    args = bind_call(s, args)
    _plan, _r, seal = rehearsed(s, args, sys.stdout)
    if seal is None:
        return BAD_SCRIPT
    if s.value_why():
        say("rehearse: %s", s.value_why())
    if needs_quoting(s, args):
        say("rehearse ok. %s", quoting_note(needs_quoting(s, args)))
        return OK
    if in_sandbox():                                    # a pod has no owner: its guard refuses the sign, so no sign line
        say("rehearse ok. In a sandbox pod nobody signs as the owner: when this call needs the owner, go on it hands it to "
            "the coordinator")
        return OK
    say("rehearse ok. After the owner's go: %s", owner_commands(path, args, seal)[0])
    return OK


def cmd_sign(rest):
    seal, usage = None, "usage: baton.py sign --by owner|coordinator-auto --seal <seal> <script> [args...]"
    # One spelling only: `--by <signer>` first, once, two words. The owner's permission rules match the command text, so an
    # allow on `sign --by coordinator-auto` must not admit `sign --by coordinator-auto --by owner` (or `--by=owner`) as owner.
    if len(rest) < 2 or rest[0] != "--by" or rest[1] not in SIGNERS:
        raise Stop(USAGE, "%s (--by <signer> comes first, once: who approves is never a default)", usage)
    asked = list(rest)                                  # the words after `sign`, as the owner's dialog showed them
    if rest[2:3] == ["--queued"]:                       # a queued item: the owner only, and nothing after its id
        if rest[1] != "owner" or len(rest) != 4 or not QUEUE_ID.match(rest[3]):
            raise Stop(USAGE, "usage: baton.py sign --by owner --queued <id>  (only the owner signs a queued item; nothing follows the id)")
        return signed_queued(rest[3], owner_signs(asked))
    by, rest = rest[1], rest[2:]
    while rest and rest[0].startswith("--") and rest[0] != "--":
        if rest[0] == "--seal" and len(rest) > 1 and seal is None:
            seal, rest = rest[1], rest[2:]
        elif rest[0].startswith("--seal=") and seal is None:
            seal, rest = rest[0][len("--seal="):], rest[1:]
        else:
            raise Stop(USAGE, "%s (--by once, first; --seal once)", usage)
    if not seal:
        raise Stop(USAGE, "%s (--seal is the one rehearse printed: the signature names what was shown)", usage)
    path, args = script_and_args(rest, usage)
    # before the script is read or rehearsed: any refusal after it still finds the record used up. Only a usage error comes
    # before it, and the guard writes no record for a command that has one (owner_shape)
    dialog = owner_signs(asked) if by == "owner" else None
    return signed(by, seal, path, args, sys.stdout, dialog)


def signed(by, seal, path, args, out, dialog=None):
    """The body of `sign` once its options are read: check, mode policy, rehearse, the seal shown, then the signature record.
    dialog: the id of the owner's dialog record cmd_sign used up (an owner signature is record version 2 and names it)."""
    s = checked(path)
    d = ensure_state()
    args = bind_call(s, args)
    mode, cwd, env = read_mode(), os.path.realpath(os.getcwd()), steering()
    binding = binding_of(s.bind_sha, args, cwd, env, s.inputs)
    stops, _u = s.stops()
    why = allowed(by, mode, stops, s.value_why())
    common = dict(name=s.name, script=s.sha[:12], binding=binding[:12], args=args, dir=cwd, signed_by=by, mode=mode,
                  baton=s.baton_id())
    if why is None and by == "owner" and not dialog:
        why = "an owner signature needs the owner's dialog (cmd_sign)"
    if why is None and by == "owner" and s.kept is not None and RUN.get("asked_kept") != (s.real, s.sha):
        why = ("the owner's dialog named %s at sha256 %s; %s now resolves to %s at sha256 %s: rehearse, show it and have it "
               "signed again" % (tuple(esc(str(x)) for x in RUN.get("asked_kept") or ("(none)", "(none)"))
                                 + (s.word, esc(s.real), s.sha)))
    if why:
        log_event(d, event="sign", result="refused", **common)
        raise Stop(REFUSED, "sign refused: %s", why)
    header_summary(s, out)
    good, plan, reasons = rehearse(s, args, [out])
    if not good:
        for r in reasons:
            say("FAIL %s", r, out=out)
        log_event(d, event="sign", result="rehearse-failed", **common)
        say("sign: rehearse FAILED, nothing signed", out=out)
        return BAD_SCRIPT
    if seal_of(binding, plan) != seal:
        log_event(d, event="sign", result="refused", **common)
        raise Stop(REFUSED, "sign refused: the seal now is %s, not the %s that was shown; the script, its arguments, its "
                            "directory, its environment or its plan changed: rehearse and show it again", seal_of(binding, plan), seal)
    rec = {"v": 2 if dialog else 1, "binding": binding, "script_path": s.real, "script_sha256": s.sha, "args": args, "cwd": cwd,
           "env": env, "plan_sha256": plan_sha(plan), "plan": plan, "stops": s.call_stops(), "signed_by": by, "mode": mode, "time": now_iso()}
    if dialog:
        rec["dialog"] = dialog
    if s.inputs is not None:
        rec["inputs"] = s.inputs
    text = json.dumps(rec, indent=1, sort_keys=True) + "\n"
    RUN["signed"] = (d, os.path.join(d, "signatures", binding + ".json"), common, text)    # before the write: go may withdraw it
    write_private(RUN["signed"][1], text)
    log_event(d, event="sign", result="signed", **common)
    say("signed %s by %s (mode %s): binding %s, %d planned write%s; one run, from %s%s", s.name, by, mode, binding[:12], len(plan),
        "" if len(plan) == 1 else "s", cwd, shown("; %s %s sha256 %s, %s", s.word, s.real, s.sha, s.label()) if s.kept is not None
        else "", out=out)
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
            say("baton: BATON_POSTCHECK_WAITS=%s may only shorten %s: ignored", repr(raw), " ".join(map(str, POSTCHECK_WAITS)), out=out)
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
                    say("== post-check attempt %d of %d failed; reading again in %g s", k + 1, len(waits) + 1, waits[k], out=out)
                time.sleep(waits[k])
            except (KeyboardInterrupt, Interrupted):           # the failure is known: undo, rather than "state unknown"
                for out in sinks:
                    say("== interrupted while waiting to read again: the post-check stands as failed", out=out)
                return False
    return False


def cmd_run(rest):
    """One line when the run holds, like go: the run log keeps the whole output; any other outcome prints it all."""
    queued = None
    if rest[:1] == ["--queued"]:
        if len(rest) != 2 or not QUEUE_ID.match(rest[1]):
            raise Stop(USAGE, "usage: baton.py run --queued <id>")
        path, args, queued = queued_call(rest[1])
    else:
        path, args = script_and_args(rest, "usage: baton.py run <script> [args...] | run --queued <id>")
    held = Held()
    try:
        rc, result, _line, out_path = signed_run(path, args, quiet=held, queued=queued)
    except BaseException:
        sys.stdout.write(held.text())
        raise
    if rc == OK and result == "ok":
        n = RUN.get("writes", 0)
        say("run: ok — %d write%s — %s", n, "" if n == 1 else "s", out_path)
        return OK
    sys.stdout.write(held.text())
    say("full output: %s", out_path)
    return rc


def signed_run(path, args, quiet=None, preamble=None, queued=None):
    """The body of `run`: (exit code, result, the log line it wrote, the run log's path). The result is the log line's: ok,
    run-failed, run-diverged, postcheck-failed, interrupted or error; a refusal raises Stop(REFUSED). With `quiet` (go), the
    output goes to that sink and the run log instead of stdout, and the run log starts with `preamble` (a Held of go's earlier steps).
    queued: (path, item) of a signed queued item (queued_call): its signature, not one of signatures/, and it moves to queue/used/."""
    s = Script(path)
    need_bash()
    d = ensure_state()
    args = bind_call(s, args)
    mode, cwd, env = read_mode(), os.path.realpath(os.getcwd()), steering()
    binding = binding_of(s.bind_sha, args, cwd, env, s.inputs)
    common = dict(name=s.name, script=s.sha[:12], binding=binding[:12], args=args, dir=cwd, mode=mode, baton=s.baton_id())

    def refuse(why, signer=None, output=None, result="refused"):
        log_event(d, event="run", result=result, signed_by=signer, output=output, **common)
        raise Stop(REFUSED, "run refused, nothing ran: %s", why)

    if queued is None:
        sig = os.path.join(d, "signatures", binding + ".json")
        rec = load_json(sig) if os.path.exists(sig) else None
        if rec is None:
            refuse(why_unsigned(d, s, args, cwd, env) if not os.path.exists(sig) else "the signature record cannot be read")
    else:                                               # an owner signature, as sign --by owner --seal writes one
        sig, item = queued
        rec = dict({k: item.get(k) for k in ("binding", "script_sha256", "args", "cwd", "env", "plan", "plan_sha256")}, v=2,
                   signed_by="owner", dialog=item["signature"]["dialog"], time=item["signature"].get("time"))
    if not isinstance(rec, dict) or (rec.get("binding"), rec.get("script_sha256"), rec.get("args"), rec.get("cwd"),
                                     rec.get("env")) != (binding, s.sha, args, cwd, env):
        refuse("the %s does not match the script, its arguments, its directory and its environment"
               % ("signature record" if queued is None else "queued item %s (run it from the directory and environment it was queued "
                                                       "in, or queue it again)" % item["id"]))
    signer = rec.get("signed_by")
    stops, _u = s.stops()
    why = allowed(signer, mode, stops, s.value_why())
    if why is None and signer == "owner" and (rec.get("v") != 2 or not rec.get("dialog")):
        why = "the signature names no owner's dialog (a baton that signs without one wrote it): have it signed again"
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
        if preamble is not None:
            logf.write(preamble.text())
            say("== go: run", out=logf)
        sinks = [sys.stdout if quiet is None else quiet, logf]
        for out in sinks:
            header_summary(s, out)
            say("signed by %s at %s; mode %s; binding %s", signer, rec.get("time"), mode, binding[:12], out=out)
        result, undone, consumed = None, None, False
        ufd, undo_only = tempfile.mkstemp(prefix=".undo-only-", dir=d)   # the paths the run keeps only for its undo
        os.close(ufd)
        started = time.time() - 2                       # a file system's coarse clock: a file the run wrote is never older
        try:
            good, plan, reasons = rehearse(s, args, sinks)
            if not good:
                for r in reasons:
                    say("FAIL %s", r, out=logf)
                refuse("the rehearse before the run failed: " + "; ".join(reasons), signer, out_path)
            RUN["writes"] = len(plan)
            if plan_sha(plan) != rec.get("plan_sha256"):
                for out in sinks:
                    say("== the signed plan\n%s", shown_join("\n", ["  " + p for p in rec.get("plan") or []]), out=out)
                refuse("the plan changed since signing (the world moved): rehearse and sign again", signer, out_path)
            if queued is not None:                      # the item as it was read, still signed and not expired
                _p, again, state = load_item(item["id"])
                if state != "signed" or again != item:
                    refuse(queue_why(item["id"], state, again) if state != "signed" else "item %s changed meanwhile" % item["id"],
                           signer, out_path)
            try:
                os.rename(sig, os.path.join(d, "used", "%s-%s.json" % (stamp, binding)) if queued is None
                          else os.path.join(queue_dir(), "used", item["id"] + ".json"))
                consumed = RUN["consumed"] = True
            except OSError:
                refuse("the signature was used meanwhile", signer, out_path)
            rc, lines, done = run_phase(s, args, "run", sinks, plan=rec.get("plan") or [], undo_only=undo_only)
            if rc != 0 or not verdict_ok(lines, "run"):
                result = "run-failed"
            elif done != plan:
                for out in sinks:
                    say("== the run did other writes than the signed plan:\n%s", shown_join("\n", ["  DO " + x for x in done]), out=out)
                result = "run-diverged"
            else:
                result = "ok" if postchecked(s, args, sinks) else "postcheck-failed"
            if result != "ok":
                rc, lines, _w = run_phase(s, args, "undo", sinks, plan=rec.get("plan") or [], undo_only=undo_only)
                undone = "yes" if rc == 0 and verdict_ok(lines, "undo") else "failed"
        except Stop:
            raise
        except (KeyboardInterrupt, Interrupted, Exception) as e:
            what = "interrupted" if isinstance(e, (KeyboardInterrupt, Interrupted)) else "error"
            if not consumed:
                refuse("%s before the run phase (%s); the signature is still unused" % (what, type(e).__name__), signer,
                       out_path, result=what + "-before-run")
            say("baton: %s during the run (%s: %s)", what, type(e).__name__, e, out=logf)
            result, undone = what, "no"
        finally:
            for sig in (signal.SIGTERM, signal.SIGHUP):  # the run is over: let the log line and the report through
                signal.signal(sig, signal.SIG_IGN)
            drop_undo_only(undo_only, result == "ok" or undone == "yes", sinks, started)
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
            say("== %s", msg, out=out)
        if quiet is None:
            say("full output: %s", out_path)
    prune_runs(d)
    return (OK if result == "ok" else UNDONE if undone == "yes" else UNKNOWN), result, logged, out_path


def drop_undo_only(listing, known, sinks, started):
    """The end of the undo window: the run's state is known (`known`: ok, or its undo put it back), so each path the script listed
    in BATON_UNDO_ONLY that is a regular file (not a link) directly in <state>/records, written since the run started (its ctime),
    is removed; a path anywhere else, or a file the run did not write, is never removed. When the state is unknown the files
    stay, for the owner to put the state back by hand. The listing goes either way."""
    try:
        with open(listing, encoding="utf-8", errors="surrogateescape") as f:
            paths = [ln.rstrip("\n") for ln in f if ln.strip()]
        os.unlink(listing)
    except OSError:
        return
    records = os.path.realpath(os.path.join(state_dir(), "records"))
    for p in sorted(set(paths)):
        try:
            st = os.lstat(p)
            mine = (os.path.isabs(p) and os.path.realpath(os.path.dirname(p)) == records
                    and stat.S_ISREG(st.st_mode) and st.st_ctime >= started)
        except OSError:
            continue                                    # gone already
        if not mine:
            for out in sinks:
                say("== kept %s: not a file this run wrote in %s", esc(p), records, out=out)
        elif known:
            try:
                os.unlink(p)
            except OSError:
                pass
        else:
            for out in sinks:
                say("== kept for putting the state back by hand: %s", esc(p), out=out)


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
    """The card lines of a mode nobody chose yet: ask the owner once. On the answer the session runs `mode` alone in its Bash
    call: the plugin's hook opens the owner's dialog and writes the record a mode change needs (owner_sets_mode), whatever the
    ask rules say; a mode call with no record (a `!` command, a wrapper, a script) is refused."""
    cmd = "%s mode <answer>" % entry_command()
    how = "on the owner's answer the session runs `%s` alone in its Bash call; the plugin's hook opens the owner's dialog" % cmd
    return ["  Stop:     mode manual (not chosen yet): ask the owner once which mode; auto is recommended on a solo machine"
            " (help modes)", "  Mode:     " + how]


def decision_card(s, plan, stops, mode, chosen=True, question=None):
    """The lines a human decides from when a baton needs the owner: what, where, why, blast, undo, the stop, what was checked.
    Every plan line is on it, and control characters are escaped as in the log: a script cannot redraw the card."""
    n, f = len(plan), lambda key: log_value(s.field(key))
    lines = ["== OWNER DECISION: %s%s needs the owner's signature; nothing was signed, nothing ran"
             % (log_value(s.name), " (a kit of %s)" % log_value(s.from_kit.pid) if s.kit and s.from_kit.pid else ""),
             "  What:     %d write%s to %s" % (n, "" if n == 1 else "s", f("Targets") or "(no Targets)")]
    if s.kept is not None:                              # an owner signature binds the file the name resolves to, and its bytes
        lines.insert(1, "  Kept:     %s is %s, sha256 %s; %s%s"
                     % (s.word, log_value(s.real), s.sha, s.label(), origin_note(s.kept, s.data)))
        if s.kept.root:
            lines.insert(2, "  Root:     %s; origin %s" % (log_value(s.kept.root), log_value(origin_url(s.kept.root))))
    lines[-1:-1] = ["  %s" % log_value(ln) for ln in s.param_lines]      # every value uncut, one line each, before the plan
    lines += ["              %d. %s" % (i + 1, log_value(p)) for i, p in enumerate(plan)]
    lines += ["  Why:      %s" % f("Purpose"), "  Blast:    %s" % f("Blast"), "  Undo:     %s" % f("Undo")]
    if stops:
        lines.append("  Stop:     %s (a stop-list item: only the owner signs)" % ", ".join(stops))
    if s.value_why():
        lines.append("  Stop:     %s" % log_value(s.value_why()))
    if question:
        lines += question
    elif mode == "manual" and chosen:
        lines.append("  Stop:     mode manual: the owner signs every baton")
    lines.append("  Checked:  check ok; rehearse ok; plan matches Expect (%d of %d line%s); %d write%s"
                 % (n, n, "" if n == 1 else "s", n, "" if n == 1 else "s"))
    return lines


def origin_url(root):
    """The URL of the project's `origin`, without its userinfo; `(none)` without one."""
    try:
        r = subprocess.run(["git", "config", "--get", "remote.origin.url"], cwd=root, capture_output=True, text=True, timeout=10)
        return drop_userinfo(r.stdout.strip()) if r.returncode == 0 and r.stdout.strip() else "(none)"
    except (OSError, subprocess.SubprocessError):
        return "(none)"


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
    if not s.kit and s.kind is None and s.kept is None:        # a kept baton runs its pinned bytes: no 120 s gate
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
        raise Stop(USAGE, "go -: stdin holds more than %d bytes; a baton is a few KiB", STDIN_MAX)
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
        raise Stop(ENV, "go -: the script cannot be stored under %s: %s", d, e.strerror or e)
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
    usage = ("usage: baton.py go [--by coordinator-auto | --queue] [--reuse] <script|-> [args...]  (- reads the script from stdin; "
             "%s--queue leaves a run that needs the owner in the queue for them)"
             % ("" if in_sandbox() else "the owner signs with `sign --by owner`; "))    # a pod never signs as the owner
    by = reuse = queue = False
    if rest and rest[0] == "--queue":                   # a run that needs the owner waits in the queue, not in a dialog
        if in_sandbox():
            raise Stop(USAGE, "go --queue in a sandbox session: the owner never signs there, so nothing is queued")
        if not session_id():
            raise Stop(USAGE, "go --queue needs a Claude Code session (CLAUDE_CODE_SESSION_ID): the item names the session that "
                              "never signs it")
        queue, rest = True, rest[1:]
        if rest and (rest[0] == "--by" or rest[0].startswith("--by=")):
            raise Stop(USAGE, "%s: --queue waits for the owner; it never goes with --by", usage)
    if rest and (rest[0] == "--by" or rest[0].startswith("--by=")):
        if rest[0] != "--by" or len(rest) < 2 or rest[1] != "coordinator-auto":
            raise Stop(USAGE, "%s: go signs only as coordinator-auto", usage)
        by, rest = True, rest[2:]
    if rest and rest[0] == "--reuse":
        reuse, rest = True, rest[1:]
    if rest and rest[0].startswith("-") and rest[0] not in ("--", "-"):
        raise Stop(USAGE, "%s (--by or --queue once, first; then --reuse once; no other option: the seal is go's own rehearse)", usage)
    path, args = script_and_args(rest, usage)
    call = list(args)                                   # as given: run --queued binds them again
    if path == "-" and reuse:
        raise Stop(USAGE, "%s (--reuse runs a file again; a script from stdin is fresh by construction)", usage)
    step, held = "check", Held()
    try:
        if path == "-":
            path = stdin_script()
        s = Script(path)
        stale = None if reuse else stale_input(s, args)
        if stale:
            what, p, why, sha, purpose = stale
            say("go: refused, nothing ran: %s %s %s.", what, p, why)
            say("  sha256 %s%s", sha, "; Purpose: %s" % log_value(purpose) if purpose is not None else "")
            say("  A Write of it in this response that did not land leaves these older bytes: write a fresh path, then go.")
            say("  To run these very bytes again, after reading the sha256 and Purpose above: %s", go_command(by, path, args))
            return BAD_SCRIPT
        need_bash()
        probs = check_script(s)
        if probs:
            print_problems(s, probs)
            raise Stop(BAD_SCRIPT, "check failed: fix the script, then check again")
        args = bind_call(s, args)                       # Params: every value checked, file values copied, before anything runs
        stale = None if reuse else input_staleness(s)
        if stale:
            key, p, why, sha = stale
            say("go: refused, nothing ran: the input file of %s, %s, %s.", key, quoted(p), why)
            say("  sha256 %s", sha)
            say("  An input file is written for this call: write it again, then go.")
            say("  To run with these very bytes again, after reading the sha256 above: %s", go_command(by, path, args))
            return BAD_SCRIPT
        say("go: check ok", out=held)                      # held: printed only when a step fails; else the run log keeps it
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
                if all("outside the declared Targets" in r for r in reasons):
                    step = "plan-vs-Targets"
            say("go: stopped at %s (exit %d): %s", step, BAD_SCRIPT, "; ".join(reasons))
            return BAD_SCRIPT
        stops, _u = s.stops()
        mode, chosen = mode_state()
        why = allowed("coordinator-auto", mode, stops, s.value_why())
        if queue and not why:
            raise Stop(USAGE, "go --queue: %s needs no owner here (mode %s, Stops none): go without --queue runs it", s.name, mode)
        if why:
            d = ensure_state()
            stamp = "%s-%d" % (time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()), os.getpid())
            detail = os.path.join(d, "runs", "%s-%s-owner.log" % (stamp, os.path.splitext(s.name)[0]))
            fd = os.open(detail, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8", errors="backslashreplace") as f:
                f.write(held.text())
            manual = not stops and not s.value_why() and place_of(path) is None   # a session script held only by mode manual
            if (stops or manual) and in_sandbox():      # only the owner signs it, never in a pod: pack may keep these bytes
                log_event(d, event="go", result="owner", name=s.name, script=s.sha[:12], args=args,
                          dir=os.path.realpath(os.getcwd()), mode=mode, baton=s.baton_id())
            asks = mode == "manual" and not chosen and not s.call_stops()     # a Stops: none baton waits on the mode question
            question = mode_question() if asks and not in_sandbox() else None   # a pod has no owner to ask: no mode command
            card = decision_card(s, plan, s.call_stops(), mode, chosen or asks, question)
            if in_sandbox():                            # nobody in a pod sets the mode
                why = why.replace(" (`baton mode` shows it; the owner sets it)", "")
            if queue and not needs_quoting(s, args):
                word = path if re.match(r"(?:kit|kind|project|user):", path) else os.path.abspath(path)
                it = queue_item(s, word, call, args, plan, s.call_stops(), mode, card, detail)
                say("go: queued %s — %s: %d write%s; the owner signs it in a Claude Code session of their own before %s "
                    "(/vibemaestro-sdlc:owner-sign); wait: %s log --wait-queued %s; then: %s run --queued %s", it["id"], s.name,
                    len(plan), "" if len(plan) == 1 else "s", it["expires"], entry_command(), it["id"], entry_command(), it["id"])
                return OK
            for ln in card:
                say("%s", ln)
            say("detail: %s (check and rehearse output)", detail)
            sign_cmd, run_cmd = owner_commands(path, args, seal)
            say("script: %s", s.real)
            if needs_quoting(s, args):                  # the guard asks only for a literal command: not widened for a value
                say("on the owner's go: %s", quoting_note(needs_quoting(s, args)))
                say("go: stopped after rehearse (exit %d, waiting for the owner): %s", OWNER, why)
                return OWNER
            if in_sandbox():                            # a pod has no owner: the guard refuses its sign, so no sign line
                if s.value_why() and not stops and place_of(path) is None:
                    # the coordinator cannot run a pod's file, and pack keeps one only for a declared stop: the header says it
                    say("in a sandbox pod nobody signs as the owner: declare `# Stops: security-boundary`%s in %s (%s), write "
                        "it to a fresh path and go again; that stop hands it to the coordinator",
                        "" if s.params is not None else " and a `# Params:` header (only such a script can be kept)",
                        os.path.abspath(path), "a value names a file with other hard links, which may be a Claude Code "
                        "settings file" if s.value_stop[2] == "linked" else "a value names a Claude Code settings %s" % s.value_stop[2])
                else:
                    for ln in sandbox_handoff(path, args, seal, stops, s.params is not None):
                        say("%s", ln)
            else:
                say("on the owner's go: %s", sign_cmd)
                say("then:              %s", run_cmd)
            say("go: stopped after rehearse (exit %d, waiting for the owner): %s", OWNER, why)
            return OWNER
        say("go: rehearse ok", out=held)
        say("go: plan-vs-Expect ok (%d of %d line%s)", len(plan), len(plan), "" if len(plan) == 1 else "s", out=held)
        say("go: seal %s", seal, out=held)
        if reuse:
            log_event(ensure_state(), event="go", result="reuse", name=s.name, script=s.sha[:12], args=args,
                      dir=os.path.realpath(os.getcwd()), mode=mode, baton=s.baton_id())
        step, sheld = "sign", Held()
        try:
            rc = signed("coordinator-auto", seal, path, args, sheld)
        except BaseException:
            sys.stdout.write(sheld.text())
            raise
        if rc != OK:
            sys.stdout.write(sheld.text())
            say("go: stopped at sign (exit %d): the rehearse at signing failed", rc)
            return rc
        held.write(sheld.text())
        say("go: sign ok", out=held)
        step, rheld = "run", Held()
        try:
            rc, result, _line, out_path = signed_run(path, args, quiet=rheld, preamble=held)
        except Stop:
            sys.stdout.write(rheld.text())
            withdraw()
            raise
        except BaseException:
            sys.stdout.write(rheld.text())
            raise
        if rc != OK or result != "ok":
            sys.stdout.write(rheld.text())
            say("full output: %s", out_path)
            at_check = result == "postcheck-failed" or (result in ("interrupted", "error") and RUN.get("phase") == "postcheck")
            say("go: stopped at %s (exit %d): %s", "post-check" if at_check else "run", rc, result)
            return rc if rc != OK else UNKNOWN
        step = "log"
        if s.kept is None:
            say("go: ok — %d write%s — %s", len(plan), "" if len(plan) == 1 else "s", out_path)
        else:                                           # go holds the sign line back: its one line carries the label
            say("go: ok — %d write%s — %s — %s %s", len(plan), "" if len(plan) == 1 else "s", out_path, s.word, s.label())
        return OK
    except Stop as e:
        say("go: stopped at %s (exit %d): %s", step, e.rc, e.text)
        raise
    except BaseException as e:
        say("go: stopped at %s: %s", step, type(e).__name__)
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
    if rest[:1] == ["--queue"]:
        return queue_list(rest[1:])
    if rest[:1] == ["--wait-queued"]:
        return queue_wait(rest[1:])
    n = 20
    if rest == ["--last"]:
        try:
            with open(os.path.join(state_dir(), "runs", "LAST"), encoding="utf-8", errors="backslashreplace") as f:
                last = f.read().strip()
        except OSError:
            last = ""
        if not last:
            raise Stop(NOINPUT, "no run has started yet: runs/LAST does not exist")
        say("%s", last)
        return OK
    if rest:
        if len(rest) == 2 and rest[0] == "--tail" and re.match(r"^[1-9]\d*$", rest[1]):
            n = int(rest[1])
        else:
            raise Stop(USAGE, "usage: baton.py log [--tail N]  (N >= 1), or log --last, or log --wait-names N1,N2,... [--timeout S] "
                              "[--since T], or log --queue, or log --wait-queued <id> [--timeout S]")
    try:
        with open(os.path.join(state_dir(), "log.tsv"), encoding="utf-8", errors="backslashreplace", newline="") as f:
            lines = f.read().split("\n")[:-1]
    except OSError:
        lines = []
    for ln in lines[-n:]:
        say("%s", shown_join("\t", ln.split("\t")))     # the columns of log.tsv: each value escaped there already
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
        raise Stop(USAGE, "%s", usage)
    names = [x for x in rest[0].split(",") if x]
    if not names or len(names) != len(rest[0].split(",")):
        raise Stop(USAGE, "%s (names are comma-separated, none empty)", usage)
    timeout, since, opts = WAIT_MAX, None, rest[1:]
    seen = set()
    while opts:
        if len(opts) < 2 or opts[0] not in ("--timeout", "--since") or opts[0] in seen:
            raise Stop(USAGE, "%s", usage)
        seen.add(opts[0])
        if opts[0] == "--timeout":
            if not re.match(r"^[1-9]\d{0,2}$", opts[1]) or int(opts[1]) > WAIT_MAX:
                raise Stop(USAGE, "%s (--timeout %s)", usage, opts[1])
            timeout = int(opts[1])
        else:
            since = iso_seconds(opts[1])
            if since is None:
                raise Stop(USAGE, "%s (--since %s)", usage, opts[1])
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
                if len(v) not in (len(LOG_FIELDS) - 1, len(LOG_FIELDS)) or v[1] != "run" or v[2] not in names:
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
            say("%s", shown_join("\t", oks[n].split("\t")))
    note = " (%d run line%s before --since ignored)" % (older, "" if older == 1 else "s") if older else ""
    want = list(dict.fromkeys(names))
    if len(oks) == len(want):
        say("wait: ok — %d of %d named scripts ran ok since %s%s", len(oks), len(want), since_txt, note)
        return OK
    for n in want:
        if n not in oks:
            say("wait: %s: %s", n, "last run %s" % last[n] if n in last else "no run line since %s" % since_txt)
    say("wait: not met after %d s — %d of %d named scripts ran ok%s", timeout, len(oks), len(want), note)
    return WAIT_UNMET

def cut(v, n):
    return v if len(v) <= n else v[:n - 1] + "…"


def read_fd(fd, cap):
    chunks, size = [], 0
    while size < cap:
        b = os.read(fd, cap - size)
        if not b:
            break
        chunks.append(b)
        size += len(b)
    return b"".join(chunks)


def ok_runs():
    """{<prefix>:<name>@<sha256>: number of ok runs} from the `baton` field of log.tsv (lines written before it are not counted)."""
    runs = {}
    try:
        with open(os.path.join(state_dir(), "log.tsv"), encoding="utf-8", errors="backslashreplace", newline="") as f:
            for ln in f:
                v = ln.rstrip("\n").split("\t")
                if len(v) == len(LOG_FIELDS) and v[1] == "run" and v[9] == "ok":
                    runs[v[-1]] = runs.get(v[-1], 0) + 1
    except OSError:
        pass
    return runs


def catalogue_files():
    """[(prefix, name, path)] of every baton list shows, in its order (kit, kind, project, user; then by name), and the notes
    of a place that cannot be read."""
    out, notes = [], []
    kits = set()
    for d in [KIT_ROOT] + [os.path.join(real, "batons") for real in dependent_roots()]:
        try:
            names = sorted(f[:-3] for f in os.listdir(d) if f.endswith(".sh") and KIT_RE.match(f[:-3]))
        except OSError:
            continue
        for name in names:
            if name in kits:
                continue
            try:
                kit = kit_path("kit:" + name)
            except Stop:
                continue
            kits.add(name)
            out.append(("kit", name, kit.path))
    out.sort(key=lambda x: x[1])
    out += [("kind", k, os.path.join(KINDS_REAL, k + ".sh")) for k in sorted(CALLABLE_KINDS)]
    for prefix in ("project", "user"):
        try:
            place = Kept(prefix + ":x")
        except Stop as e:
            if prefix == "user" or e.rc != NOINPUT:
                notes.append("%s: %s" % (prefix, esc(str(e))))
            continue
        try:
            names = sorted(f[:-3] for f in os.listdir(place.dir) if f.endswith(".sh") and KIT_RE.match(f[:-3])
                           and len(f[:-3]) <= KEPT_NAME_MAX)
        except OSError:
            continue
        out += [(prefix, name, os.path.join(place.dir, name + ".sh")) for name in names]
    return out, notes


def dependent_roots():
    """The real roots of the plugins of sdlc's own registry that may ship kits (kit_path checks each name again)."""
    plugins, market, ids = installed_sdlc()
    if plugins is None:
        return []
    roots = []
    for pid in sorted(ids):
        p, _at, m = pid.partition("@")
        e = latest_entry(ids[pid])
        if p != SDLC and m == market and e and usable_path(e.get("installPath")):
            roots.append(os.path.realpath(e["installPath"]))
    return roots


def catalogue():
    """[entry] of every baton: a dict of its prefix, name, path, header fields, sha256, label, marks and run count."""
    files, notes = catalogue_files()
    runs, by_sha, origin = ok_runs(), {}, {}
    kit_names = set(n for p, n, _f in files if p == "kit")
    entries = []
    for prefix, name, path in files:
        e = {"prefix": prefix, "name": name, "path": path, "marks": [], "sha": None}
        try:
            fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOCTTY", 0))
            try:
                st = os.fstat(fd)
                if not stat.S_ISREG(st.st_mode):
                    continue
                data = read_fd(fd, KEPT_MAX + 1 if st.st_size <= KEPT_MAX else HEADER_READ)
            finally:
                os.close(fd)
        except OSError:
            continue
        if prefix == "kind":
            data = data.replace(b"__NAME__", name.encode("ascii"))
        head = data[:HEADER_READ].decode("utf-8", "replace")
        e["fields"] = parse_header(head.split("\n"))[0]
        if len(data) > KEPT_MAX or st.st_size > KEPT_MAX:
            e["marks"].append("too large")
        else:
            e["sha"] = sha256(data)
        e["runs"] = runs.get("%s:%s@%s" % (prefix, name, e["sha"]), 0) if e["sha"] else 0
        if prefix in ("kit", "kind"):
            e["label"] = "reviewed"
        else:
            pinned, by, newest, retired = pin_state(prefix, kept_records("user" if prefix == "user" else project_root()[1], name),
                                                    e["sha"] or "")
            e["label"] = kept_label(by) if pinned else "not kept on this machine"
            review = None
            if not pinned and not retired and prefix == "project" and e["sha"]:
                root, _key, git = project_root()
                if git and "blobs" not in origin:
                    origin["blobs"] = origin_blobs(root)
                review = reviewed_on((prefix, name, root, git), data, origin.get("blobs") or ())[0]
            if review:
                e["label"] = "reviewed on %s %s" % (esc(review[0]), esc(review[1]))
            elif not pinned:
                e["marks"].append("unpinned")
            if retired:
                e["marks"].append("retired")
            if not pinned and newest and newest["sha256"] != e["sha"]:
                e["marks"].append("changed since kept")
            if pinned and prefix == "project" and newest and newest["sha256"] != e["sha"]:
                e["marks"].append("older version")
            if name in kit_names or name in CALLABLE_KINDS:
                e["marks"].append("%s:%s exists: retire" % ("kit" if name in kit_names else "kind", name))
            if e["sha"]:
                e["pinned"] = pinned
                by_sha.setdefault(e["sha"], []).append(e)
            if prefix == "project" and e["sha"]:
                root, _key, git = project_root()
                if git and "blobs" not in origin:
                    origin["blobs"] = origin_blobs(root)
                if not review:
                    e["label"] += origin_note((prefix, name, root, git), data, origin.get("blobs"))
        f = e["fields"]
        stops = [w.strip() for w in f.get("Stops", (0, ""))[1].split(",") if w.strip()]
        e["signer"] = "auto" if stops == ["none"] else "owner"
        iface = f.get("Params", f.get("Usage", (0, "")))[1]
        e["iface"] = iface
        keys = [d.split("=", 1)[0] for d in iface.split()] if "Params" in f else re.findall(r"--([a-z][a-z0-9-]*)", iface)
        e["hay"] = " ".join([prefix + ":" + name, f.get("Purpose", (0, ""))[1]] + keys).lower()
        entries.append(e)
    for same in by_sha.values():                        # the same bytes under a second name: the pinned one is the original
        first = next((e for e in same if e["pinned"]), same[0])
        for e in same:
            if e is not first:
                e["marks"].append("copy of %s:%s" % (first["prefix"], first["name"]))
    return entries, notes


def list_line(e):
    f = e["fields"]
    parts = ["%s:%s" % (e["prefix"], e["name"]), e["signer"], "runs %d" % e["runs"]] + ([", ".join(e["marks"])] if e["marks"] else [])
    parts += [e["label"], cut(esc(f.get("Purpose", (0, "(no Purpose)"))[1]), 80)]
    return cut("  ".join(parts) + "  — " + cut(esc(e["iface"] or "(no Params or Usage)"), 160), LIST_WIDTH)


def list_entry(e):
    """The whole entry of one baton, at most ENTRY_MAX bytes: what a plain call needs, so no reference file is read. It is
    uncut unless a header or a path floods it: a deep path keeps its start and its file name, then the longest fields are cut."""
    f = e["fields"]
    head = "  ".join(["%s:%s" % (e["prefix"], e["name"]), e["signer"], "runs %d" % e["runs"]] + e["marks"] + [e["label"]])
    keys = ["Purpose", "Targets", "Blast", "Undo", "Stops", "Params" if "Params" in f else "Usage"]
    vals = dict((k, esc(f.get(k, (0, "(none)"))[1])) for k in keys)
    path, base = esc(e["path"]), esc(os.path.basename(e["path"]))
    sha = e["sha"] or "(too large: not hashed, cannot be called)"

    def text():
        return shown_join("\n", [head] + ["  %-8s %s" % (k + ":", vals[k]) for k in keys] + ["  file: %s sha256 %s" % (path, sha)])
    over = len(text().encode("utf-8")) - ENTRY_MAX
    if over > 0 and len(path) > len(base) + 40:
        full, keep = path, len(path) - len(base) - over - 4
        path = full[:max(20, keep)] + "\u2026/" + base
        while len(text().encode("utf-8")) > ENTRY_MAX and keep > 20:
            keep -= len(text().encode("utf-8")) - ENTRY_MAX
            path = full[:max(20, keep)] + "\u2026/" + base
    while len(text().encode("utf-8")) > ENTRY_MAX:     # only a header written to flood the entry is cut
        k = max(keys, key=lambda x: len(vals[x]))
        if len(vals[k]) <= 20:
            break
        vals[k] = cut(vals[k], max(20, len(vals[k]) - (len(text().encode("utf-8")) - ENTRY_MAX) - 1))
    out = text()
    if len(out.encode("utf-8")) > ENTRY_MAX:             # a deep path: the entry is cut at its byte bound, never past it
        out = shown_join("\n", (out.encode("utf-8")[:ENTRY_MAX - 3].decode("utf-8", "ignore") + "…").split("\n"))
    return out


def cmd_list(rest):
    """list [<keyword>...]: one bounded line per baton (kit:, kind:, project:, user:), or the whole entry of the one baton the
    keywords match. It reads each header and hashes each file, never runs one, and writes nothing."""
    if any(w.startswith("-") for w in rest):
        raise Stop(USAGE, "usage: baton.py list [<keyword>...]  (every keyword must appear in the name, the Purpose or a key)")
    entries, notes = catalogue()
    kws = [w.lower() for w in rest]
    hit = [e for e in entries if all(k in e["hay"] for k in kws)]
    for n in notes[:2]:
        say("%s", cut(n, LIST_WIDTH))
    if not hit:
        say("no baton matches %s", cut(esc(" ".join(rest)), 120))
        return OK
    if kws and len(hit) == 1:
        say("%s", list_entry(hit[0]))
        return OK
    for e in hit[:LIST_LINES]:
        say("%s", list_line(e))
    if len(hit) > LIST_LINES:
        say("… %d more: add a keyword", len(hit) - LIST_LINES)
    return OK


# ── pack: keep a baton that ran right, retire one sha, move between places ─────────────────────────────────────────────────────
# A place's files and records are written under its lock, <state>/kept/<place key>/.lock, and a move holds the locks of both
# places: a flock, which the kernel drops with the process holding it, so a killed pack leaves only the lock file and never wedges
# the next one. A record's <seq> is taken by link(), which fails on a name that exists, as O_EXCL does: two writers never share
# one, and a reader never sees half a record. The file, the record, the log line and the owner: line are written with SIGTERM,
# SIGHUP and SIGINT held, so an interrupt cannot leave a keep its owner never hears of.
PACK_LOCK_WAIT = 30
SEQ_MAX = 999999
COPY_NAME = re.compile(r"-(?:v[0-9]+|[0-9a-f]{7,})-*\Z")       # the names a copy takes: evolve a baton, never copy it
CRITICAL = (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)


def kit_names():
    """The names a kit (of sdlc or of a dependent plugin) or a callable kind ships: a kept baton never takes one."""
    names = set(CALLABLE_KINDS)
    for d in [KIT_ROOT] + [os.path.join(real, "batons") for real in dependent_roots()]:
        try:
            names.update(f[:-3] for f in os.listdir(d) if f.endswith(".sh"))
        except OSError:
            pass
    return names


def owner_stops(manual=False):
    """The `baton` field of each `go` line that stopped for the owner in a sandbox (result `owner`: the baton's Stops list, or a
    session script held only by mode manual), from this machine's log.tsv; with manual, only the lines logged in mode manual."""
    out = set()
    try:
        with open(os.path.join(state_dir(), "log.tsv"), encoding="utf-8", errors="backslashreplace", newline="") as f:
            for ln in f:
                v = ln.rstrip("\n").split("\t")
                if len(v) == len(LOG_FIELDS) and v[1] == "go" and v[9] == "owner" and (not manual or v[8] == "manual"):
                    out.add(v[-1])
    except OSError:
        pass
    return out


def owner_stop_of(t, sha):
    """In a sandbox, a project: keep stands on a `go` that stopped for the owner on these exact bytes instead of an ok run: a pod
    never gets the owner's signature, so the coordinator runs it after the PR merges. Bytes that declare no stop stand only on a
    stop logged in mode manual (the pod could not run them): they never ran, and the coordinator's `go` is their first run."""
    if not (in_sandbox() and t.kept.prefix == "project" and stops_of(t.text) is not None):
        return False
    return any(v.endswith("@" + sha) for v in owner_stops(manual=no_stop(t.text)))


def no_stop(text):
    """True when the Stops line declares no stop word (`none`, or nothing but commas), as Script.stops() reads it."""
    s = stops_of(text)
    return s is not None and not set(s.split(", ")) - {"none", ""}


def ok_run_of(sha):
    """True when this machine's baton log holds an ok run of these exact bytes, under any id (scratch@, project:, user:).
    Nothing else is read: not the keep records, not the file, not a log anywhere else."""
    return any(v.endswith("@" + sha) for v in ok_runs())


def kept_by():
    """Who keeps it: the session, the seat and the intent, each only when it is a valid `name` value; `local` when none is."""
    parts = {}
    for key, var in (("session", "CLAUDE_CODE_SESSION_ID"), ("seat", "SEAT"), ("intent", "INTENT_SLUG")):
        v = os.environ.get(var, "")
        if WORD_RE["name"].match(v):
            parts[key] = v
    return parts or "local"


def stops_of(text):
    """The set of Stops words of a baton text as one value: sorted, `, `-joined (`none` alone stays `none`); None with no Stops."""
    f = parse_header(text.split("\n"))[0]
    if "Stops" not in f:
        return None
    return ", ".join(sorted(set(w.strip() for w in f["Stops"][1].split(",") if w.strip())))


def place_lock(key):
    """The descriptor holding the lock of one place; close it to release. Stop(ENV) after PACK_LOCK_WAIT seconds."""
    d = os.path.join(ensure_state(), "kept", key)
    os.makedirs(d, mode=0o700, exist_ok=True)
    path = os.path.join(d, ".lock")
    fd = os.open(path, os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
    deadline = time.monotonic() + PACK_LOCK_WAIT
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except BlockingIOError:
            if time.monotonic() > deadline:
                os.close(fd)
                raise Stop(ENV, "pack: another pack or retire in %s holds its lock %s after %d s; a lock ends with the process "
                                "that holds it, so that one is still running: wait for it, then run this again", key, path, PACK_LOCK_WAIT)
            time.sleep(0.05)


def place_locks(*keys):
    """The locks of these places, taken in one order (sorted), so two moves the opposite way cannot hold one each."""
    fds = []
    try:
        for key in sorted(set(keys)):
            fds.append(place_lock(key))
    except BaseException:
        unlock(fds)
        raise
    return fds


def unlock(fds):
    for fd in reversed(fds):
        os.close(fd)


def write_record(key, name, rec):
    """Write a keep or retire record as <seq>.json, <seq> one above the highest present; the seq."""
    d = os.path.join(state_dir(), "kept", key, name)
    os.makedirs(d, mode=0o700, exist_ok=True)
    tmp = os.path.join(d, ".record.%d" % os.getpid())
    try:
        os.unlink(tmp)                                  # a leftover of a killed pack with the same pid
    except OSError:
        pass
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(rec, f, sort_keys=True)
        f.write("\n")
    try:
        while True:
            seqs = [int(n[:6]) for n in os.listdir(d) if re.match(r"[0-9]{6}\.json\Z", n)]
            seq = max(seqs or [0]) + 1
            if seq > SEQ_MAX:
                raise Stop(ENV, "pack: %s holds a record numbered %06d: no number is left", d, SEQ_MAX)
            path = os.path.join(d, "%06d.json" % seq)
            try:
                os.link(tmp, path)
                return seq
            except FileExistsError:
                continue                                # another writer took that number: the next one
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def place_fd(kept, create=True):
    """A descriptor of the place directory, reached one level at a time from its anchor (the project root, or the user's data
    directory) without following a link at any level; with `create`, a missing level is made there, mode 0755. A level that is a
    link or not a directory is Stop(USAGE); a project level another user owns, or others can write, is Stop(REFUSED)."""
    if kept.prefix == "project":
        anchor, parts = kept.root, (".vibemaestro", "batons")
    else:
        base = os.path.dirname(os.path.dirname(kept.dir))
        if create:
            os.makedirs(base, exist_ok=True)            # the user's data directory: outside the place, followed as given
        anchor, parts = os.path.realpath(base), ("vibemaestro", "batons")
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(anchor, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        for part in parts:
            made = False
            if create:
                try:
                    os.mkdir(part, 0o755, dir_fd=fd)
                    made = True
                except FileExistsError:
                    pass
            try:
                nfd = os.open(part, flags, dir_fd=fd)
            except OSError as e:
                if e.errno not in (errno.ELOOP, errno.ENOTDIR):
                    raise
                raise Stop(USAGE, "%s: %s in %s is a link or not a directory: a kept baton's place is never reached through a "
                                  "link", kept.word, part, anchor)
            os.close(fd)
            fd = nfd
            if made:
                os.fchmod(fd, 0o755)                    # the umask may leave it writable by its group: a loose place
            st = os.fstat(fd)
            if kept.prefix == "project" and (st.st_uid != os.getuid() or st.st_mode & 0o022):
                raise Stop(REFUSED, "%s: %s is owned by uid %d, mode %o: a project's place is yours and writable by you only",
                           kept.word, os.path.join(anchor, part), st.st_uid, stat.S_IMODE(st.st_mode))
            anchor = os.path.join(anchor, part)
        return fd
    except BaseException:
        os.close(fd)
        raise


def pack_put_file(kept, data):
    """Write the bytes to <place>/<name>.sh: a temporary file in the place directory, then a rename onto the name, both through
    the directory's descriptor, so a target that is a link is replaced, never followed."""
    fd = place_fd(kept)
    try:
        tmp = ".%s.sh.pack-%d" % (kept.name, os.getpid())
        try:
            os.unlink(tmp, dir_fd=fd)
        except OSError:
            pass
        f = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o644, dir_fd=fd)
        try:
            try:
                os.fchmod(f, 0o644)
                view = memoryview(data)
                while view:
                    view = view[os.write(f, view):]
            finally:
                os.close(f)
            os.rename(tmp, kept.name + ".sh", src_dir_fd=fd, dst_dir_fd=fd)
        except BaseException:                           # a failed write or rename leaves no copy of the bytes behind
            try:
                os.unlink(tmp, dir_fd=fd)
            except OSError:
                pass
            raise
    finally:
        os.close(fd)


def place_bytes(kept):
    """The bytes of <place>/<name>.sh as they are (None when absent, a link, not a regular file or too large)."""
    try:
        return read_capped(kept.path, KEPT_MAX)[0]
    except (OSError, ValueError):
        return None


def copy_holder(kept, sha):
    """Another name of the same place that holds these bytes: a keep record of it names them, or its file holds them, and no
    later record of it retires them (a retire frees them). None when no other name does."""
    names = set()
    for d in (kept.dir, os.path.join(state_dir(), "kept", kept.key)):
        try:
            names.update(n[:-3] if n.endswith(".sh") else n for n in os.listdir(d))
        except OSError:
            pass
    for name in sorted(n for n in names - {kept.name} if KIT_RE.match(n) and len(n) <= KEPT_NAME_MAX):
        recs = kept_records(kept.key, name)
        naming = [r for _q, r in recs if (is_keep(r) and r["sha256"] == sha) or (is_retire(r) and r["retired"] == sha)]
        retired = bool(naming) and is_retire(naming[-1])
        if retired:
            continue
        if any(is_keep(r) and r["sha256"] == sha for _q, r in recs):
            return name
        try:
            data = read_capped(os.path.join(kept.dir, name + ".sh"), KEPT_MAX)[0]
        except (OSError, ValueError):
            continue
        if sha256(data) == sha:
            return name
    return None


def keep_refusal(t, sha, recs, ran):
    """The state refusals of a keep (rc 3), against the records and the files at this moment, under the place's lock; ran: an
    ok run of these bytes is in the log."""
    kept = t.kept
    if not ran and not owner_stop_of(t, sha):
        raise Stop(REFUSED, "pack: no ok run of these bytes (sha256 %s) in this machine's baton log: run them once with values "
                            "(go <path> key=…), then pack%s", sha, "; in a sandbox a baton packs as project: once go has "
                            "stopped for the owner on these bytes (exit 8; for Stops none, in mode manual)" if in_sandbox() and
                            t.kept.prefix == "project" and stops_of(t.text) is not None else "")
    other = copy_holder(kept, sha)
    if other is not None:
        raise Stop(REFUSED, "pack: these bytes (sha256 %s) are already kept as %s:%s: evolve that baton and keep its name, never "
                            "a copy (retire that sha first to keep them under another name)", sha[:12], kept.prefix, other)
    stops = stops_of(t.text)
    keeps = [r for _q, r in recs if is_keep(r)]
    if keeps and isinstance(keeps[-1].get("stops"), str):
        was, where = keeps[-1]["stops"], "its newest keep record"
    else:
        old = place_bytes(kept)
        was, where = (stops_of(old.decode("utf-8", "replace")) if old is not None else None), "the file in the place"
    if was is not None and was != stops:
        raise Stop(REFUSED, "pack: %s has Stops %s (%s), these bytes Stops %s: another Stops word makes another baton, under a "
                            "name of its own", kept.word, was, where, stops or "(none)")


def pack_facts(t, data, sha, old, prev, newest, ran=True):
    """The one line that tells what was kept, against the file it replaced. The Purpose (the file's text) comes last, so it
    cannot pose as the fields before it."""
    def value(f, k):
        return [v for _n, v in f.get(k, [])] if k == "Expect" else f.get(k, (0, None))[1]
    b = t.text.split("\n")[t.header_end:]
    if old is None:
        changed, body = "(new)", "+%d" % (len(b) - (1 if t.text.endswith("\n") else 0))
    else:
        text = old.decode("utf-8", "replace")
        fields, end = parse_header(text.split("\n"))[:2]
        changed = ", ".join(k for k in HEADER_FIELDS + OPTIONAL_FIELDS if value(fields, k) != value(t.fields, k)) or "none"
        a = text.split("\n")[end:]
        add = rem = 0
        for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b, autojunk=False).get_opcodes():
            if op != "equal":
                rem, add = rem + i2 - i1, add + j2 - j1
        body = "+%d -%d" % (add, rem)
    was = ("was %s" % prev[:12] if prev is not None else "after retired %s" % newest["sha256"][:12] if newest is not None
           else "new")
    if old is not None and sha256(old) != prev:
        was += ", file %s" % sha256(old)[:12]
    return "kept %s (%s) — Stops %s — sha256 %s — changed: %s — body %s lines — not reviewed%s — Purpose: %s" % (
        esc(t.kept.word), was, esc(stops_of(t.text) or "(none)"), sha[:12], changed, body,
        "" if ran else " — not run: stop-list, the owner signs after merge" if not no_stop(t.text) else " — " + NEVER_RAN,
        cut(esc(t.field("Purpose")), 120))


def pack_target(t, data, sha):
    """Keep `data` as the target t (a Script of the target word over these bytes); the caller holds the place's lock. The state
    refusals, then the file, the keep record, the log line and what to tell. The file goes first: a pack cut before its record
    leaves bytes no record pins, which no call runs."""
    kept = t.kept
    recs = kept_records(kept.key, kept.name)
    ran = ok_run_of(sha)
    keep_refusal(t, sha, recs, ran)
    keeps = [r for _q, r in recs if is_keep(r)]
    newest = keeps[-1] if keeps else None
    prev = newest["sha256"] if newest is not None and pin_state(kept.prefix, recs, newest["sha256"])[0] else None
    old = place_bytes(kept)
    root = kept.root if kept.prefix == "project" else os.path.realpath(kept.dir)
    d, cwd, baton = state_dir(), os.path.realpath(os.getcwd()), "%s@%s" % (kept.word, sha)
    old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, CRITICAL)
    try:
        if newest is not None and newest["sha256"] == sha and kept.pin(sha):
            restored = "" if old == data else "; the file held %s, restored to these bytes" % (
                "sha256 %s" % sha256(old)[:12] if old is not None else
                "a link or no regular file of at most 256 KiB" if os.path.lexists(kept.path) else "nothing")
            if old != data:
                pack_put_file(kept, data)
            log_event(d, event="pack", name=kept.word, script=sha[:12], result="already kept" + (" (restored)" if restored else ""),
                      dir=cwd, output=kept.path, baton=baton)
            line = "already kept %s sha256 %s, %s; no record written%s — Purpose: %s" % (
                esc(kept.word), sha[:12], kept_label(newest), restored, cut(esc(t.field("Purpose")), 120))
            say("%s%s", "owner: " if kept.prefix == "user" else "", line)   # relayed again: a keep cut before its line
                                                                            # still reaches the owner
            return
        if old != data:
            pack_put_file(kept, data)
        rec = {"place": kept.prefix, "root": root, "name": kept.name, "sha256": sha, "params": t.field("Params"),
               "stops": stops_of(t.text), "prev_sha256": prev, "kept_by": kept_by(), "kept_at": now_iso()}
        if not ran and no_stop(t.text):                 # kept on a mode-manual stop (keep_refusal): it never ran
            rec["never_ran"] = NEVER_RAN
        write_record(kept.key, kept.name, rec)
        log_event(d, event="pack", name=kept.word, script=sha[:12], result="kept", dir=cwd, output=kept.path, baton=baton)
        facts = pack_facts(t, data, sha, old, prev, newest, ran=ran)
        if kept.prefix == "user":
            say("owner: %s", facts)
        else:
            say("%s — the file is %s: commit it on your branch, the PR carries it", facts, kept.path)
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, old_mask)


def retire_locked(kept, sha):
    """Write a retire record of sha for the kept baton (the caller holds the place's lock); False when the newest record naming
    sha is already a retire. Stop(NOINPUT) when no keep record of the name names sha."""
    naming = [r for _q, r in kept_records(kept.key, kept.name)
              if (is_keep(r) and r["sha256"] == sha) or (is_retire(r) and r["retired"] == sha)]
    if not naming:
        raise Stop(NOINPUT, "pack --retire: no keep record of %s names sha256 %s", kept.word, sha)
    if is_retire(naming[-1]):
        return False
    write_record(kept.key, kept.name, {"retired": sha, "kept_by": kept_by(), "kept_at": now_iso()})
    log_event(state_dir(), event="retire", name=kept.word, script=sha[:12], result="retired",
              dir=os.path.realpath(os.getcwd()), output=kept.path, baton="%s@%s" % (kept.word, sha))
    return True


def retire_source(src, sha):
    """Step 2 of a move: retire the source's sha, so a file restored later (git checkout, a backup) is not pinned again."""
    retire_locked(src.kept, sha)


def remove_source(src, sha):
    """Step 3 of a move: remove the source file, through its place's descriptor, only while it still holds the bytes moved."""
    now = place_bytes(src.kept)
    if now is None:
        return
    if sha256(now) != sha:
        raise Stop(REFUSED, "pack: %s changed while pack ran (sha256 %s now): it is left in place; the target holds the bytes "
                            "read, and their sha %s is retired at the source", src.word, sha256(now)[:12], sha[:12])
    fd = place_fd(src.kept, create=False)
    try:
        os.unlink(src.kept.name + ".sh", dir_fd=fd)
    finally:
        os.close(fd)


def pack_place_word(word, what, new=True):
    """(place, name, word) of a target or --retire word: project:<name> or user:<name>; a new keep (new) also takes no name a kit
    or kind ships and no copy name (a retire may: a later kit release can ship a name a kept baton has). In a sandbox a new keep
    of a bare name is project:<name>, and user: is refused: a pod's library is lost with the pod. Stop(USAGE) otherwise."""
    if ":" not in word and new and in_sandbox():
        say("pack: %s names no place: keeping it as project: (a sandbox keeps to project:)", word)
        word = "project:" + word
    if ":" not in word:
        raise Stop(USAGE, "pack: name the place of %s: project:%s or user:%s (a pack always names its place)", word, word, word)
    place = place_of(word)
    if place not in ("project", "user"):
        raise Stop(USAGE, "pack: %s is %s: a %s is project:<name> or user:<name>; kits and kinds ship in the plugin", word,
                   "a path" if place is None else "a %s: name" % place, what)
    name = word.split(":", 1)[1]
    if place == "user" and new and in_sandbox():
        raise Stop(USAGE, "pack: %s: a sandbox keeps to project: (a pod's library is lost with the pod): use project:%s, and the "
                          "PR carries it", word, name)
    if not KIT_RE.match(name) or len(name) > KEPT_NAME_MAX:
        raise Stop(USAGE, "pack: %s: a kept baton is named by lower-case letters, digits and '-', at most %d characters", word,
                   KEPT_NAME_MAX)
    if not new:
        return place, name, word
    if name in kit_names():
        raise Stop(USAGE, "pack: %s: kit:%s or kind:%s already ships that name; choose another", word, name, name)
    if COPY_NAME.search(name):
        raise Stop(USAGE, "pack: %s ends like a copy's name (-v<digits> or -<7 or more hex>): evolve the baton in place and "
                          "keep its name", word)
    return place, name, word


def cmd_pack(rest):
    """pack <source> <place>:<name>: keep a scratch baton that ran right, or move a kept one to the other place.
    pack --retire <place>:<name> <sha256>: unpin one sha."""
    usage = "usage: baton.py pack <source> <project|user>:<name>  |  baton.py pack --retire <project|user>:<name> <sha256>"
    try:
        if rest[:1] == ["--retire"]:
            if len(rest) != 3 or not WORD_RE["sha256"].match(rest[2]):
                raise Stop(USAGE, "%s (the sha256 is 64 lower-case hex)", usage)
            pack_place_word(rest[1], "baton to retire", new=False)
            kept = Kept(rest[1])
            fds = place_locks(kept.key)
            try:
                done = retire_locked(kept, rest[2])
            finally:
                unlock(fds)
            say("%s: %s sha256 %s; %s", "retired" if done else "already retired", kept.word, rest[2], "the file stays, and a "
                "later pack of these bytes pins them again" if done else "nothing written")
            return OK
        if len(rest) != 2 or rest[0].startswith("-"):
            raise Stop(USAGE, "%s", usage)
        source, word = rest
        word = pack_place_word(word, "target")[2]
        src = None
        if place_of(source) in ("kit", "kind"):
            raise Stop(USAGE, "pack: %s is plugin code: the source is a scratch path, or project:<name> or user:<name> to move", source)
        if place_of(source) is not None:
            if source.split(":", 1)[0] == word.split(":", 1)[0]:
                raise Stop(USAGE, "pack: %s and %s are in one place: a move goes between project: and user:; a baton keeps its "
                                  "name (evolve it in place)", source, word)
            src = Script(source, pin=False)
            data = src.data
        else:
            try:
                data = read_capped(source, KEPT_MAX, nofollow=False)[0]
            except (OSError, ValueError) as e:
                raise Stop(NOINPUT, "pack: cannot read %s: %s", source, getattr(e, "strerror", None) or e)
        t = Script(word, data=data)
        sha = t.sha
        need_bash()
        probs = check_script(t)
        if probs:
            print_problems(t, probs)
            raise Stop(BAD_SCRIPT, "pack: these bytes fail check as a %s: baton; fix them, run them once, then pack", t.place)
        if src is None:
            fds = place_locks(t.kept.key)
            try:
                pack_target(t, data, sha)
            finally:
                unlock(fds)
            return OK
        fds = place_locks(src.kept.key, t.kept.key)
        try:
            src.kept.pin(sha)                           # again, under both locks: a move the other way may have retired it
            if not src.kept.pinned and not (src.kept.retired and t.kept.pin(sha)):
                raise Stop(REFUSED, "%s", src.kept.refusal())
            was_retired = not src.kept.pinned
            pack_target(t, data, sha)
            retire_source(src, sha)
            remove_source(src, sha)
            log_event(state_dir(), event="pack", name=word, script=sha[:12], result="moved", dir=os.path.realpath(os.getcwd()),
                      output="%s -> %s" % (src.kept.path, t.kept.path), baton="%s@%s" % (word, sha))
        finally:
            unlock(fds)
        say("moved: %s -> %s; the source sha256 %s %s, and its file removed%s", source, word, sha[:12],
            "was already retired" if was_retired else "is retired",
            " (commit the removal on your branch)" if src.kept.prefix == "project" else "")
        return OK
    except (KeyboardInterrupt, Interrupted):
        raise Stop(UNKNOWN, "pack interrupted: run the same command again; it finishes a cut move, or says what is already kept "
                            "(bytes no record pins never run)")
    except OSError as e:
        raise Stop(ENV, "pack: %s%s", "%s: " % esc(str(e.filename)) if e.filename else "", e.strerror or e)


def cmd_mode(rest):
    if not rest:
        say("%s", read_mode())
        return OK
    if rest[0] in ("remotes", "trust", "untrust"):
        return cmd_remotes(rest)
    if len(rest) != 1 or rest[0] not in MODES:
        raise Stop(USAGE, "usage: baton.py mode [manual|auto]  |  mode remotes  |  mode trust|untrust <remote>")
    d = ensure_state()
    rid = owner_sets_mode(["mode"] + rest)              # the owner's dialog for this very command, or refused: mode unchanged
    old = read_mode()
    try:
        write_private(os.path.join(d, "mode"), "%s\ndialog %s\n" % (rest[0], rid))
    except OSError as e:
        raise Stop(ENV, "the mode cannot be written: %s", e.strerror or e)
    log_event(d, event="mode", mode=rest[0], result="%s->%s" % (old, rest[0]))
    say("mode %s (was %s)", rest[0], old)
    return OK

def cmd_remotes(rest):
    """mode remotes: print the owner's remote list. mode trust|untrust <remote>: add or remove one, in its canonical form. A
    mode change, so it takes the owner's dialog record, as the mode itself does."""
    usage = "usage: baton.py mode remotes  |  baton.py mode trust|untrust <remote>"
    if rest == ["remotes"]:
        for r in read_remotes() or ["(none): no remote's default branch stands in for a pin"]:
            say("%s", r)
        return OK
    if len(rest) != 2 or rest[0] == "remotes":
        raise Stop(USAGE, "%s", usage)
    canon = remote_canon(rest[1])
    if canon is None:
        raise Stop(USAGE, "mode %s: %s is not a network remote (https://host/path, ssh://host/path, git@host:path or host/path, "
                          "the host with a dot): a local path or a file: URL is never on the list%s", rest[0], rest[1],
                   "; a URL ending in /.git is never on the list: set origin to the plain URL" if
                   rest[0] == "trust" and rest[1].rstrip("/").endswith("/.git") else "")
    if not plain_remote(rest[1]):
        raise Stop(USAGE, "mode %s: name the remote without a user or token before @ (as %s): the owner's dialog shows what is "
                          "written", rest[0], canon)
    rid = owner_sets_mode(["mode"] + rest)
    have = read_remotes()
    if (canon in have) == (rest[0] == "trust"):
        say("%s %s; nothing changed", canon, "is already on the list" if rest[0] == "trust" else "is not on the list")
        return OK
    new = have + [canon] if rest[0] == "trust" else [r for r in have if r != canon]
    d = ensure_state()
    try:
        write_private(remotes_path(), "".join(r + "\n" for r in new) + "dialog %s\n" % rid)
    except OSError as e:
        raise Stop(ENV, "the remote list cannot be written: %s", e.strerror or e)
    log_event(d, event="mode", result="%s %s" % (rest[0], canon))
    say("%s %s; the remote list: %s", "trusted" if rest[0] == "trust" else "untrusted", canon, ", ".join(new) or "(none)")
    return OK

# ── permissions: the owner's Claude Code rules for baton (printed and checked, never written) ──────────────────────────────────
# Claude Code (2.1.x) decides a Bash call by its rules: deny, then ask, then allow, the first match wins, in every settings scope
# combined. A rule ending in `:*` is a literal prefix (the command, or the command and a space); another rule with an unescaped
# `*` is a wildcard where `*` is any text, `/` and spaces included; any other rule is the exact command. The rules name the
# launcher, a fixed path no upgrade moves.
ALLOWED_SUBS = (("new", "act"), ("check", "act.sh"), ("rehearse", "act.sh"), ("run", "act.sh"), ("go", "act.sh"),
                ("list", "merge"), ("pack", "act.sh user:act"), ("log", "--tail 5"))
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


# the launcher as the kit's text (the core, the rule, the skill) tells a session to type it: the default state directory, in the
# `~/` spelling the printed rules allow; SessionStart names this machine's launcher where it lies elsewhere (launcher_line)
TEXT_LAUNCHER = "~/.local/state/vibemaestro/baton/bin/baton"


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
            raise Stop(ENV, "the plugin's launcher has no line %s", repr(line))
        text = text.replace(line, "%s = %r" % (name, value))
    return text


def launcher_current():
    """True when the installed launcher holds this machine's rendering of this version's launcher."""
    try:
        with open(launcher_path(), encoding="utf-8") as f:
            return f.read() == launcher_text()
    except (OSError, ValueError, Stop):
        return False


def registry_other():
    """(this version, the registry's version, the registry's plugin root) when this baton.py is an installed copy and the
    launcher would run another one: the registry's `vibemaestro-sdlc@vibemaestro` entry with the latest `lastUpdated` whose real
    path is a version directory of <claude dir>/plugins/cache/vibemaestro/vibemaestro-sdlc holding scripts/baton.py, read the way
    the launcher reads it, while no entry lists this copy any more (a plugin update moved it: a restart loads the new one). None
    in every other case: a copy outside that cache (a pod's sdlc, a clone), no registry, no entry, an entry the launcher refuses
    outright, or this copy still listed (another scope's entry is the latest: a restart would load this copy again); there the
    permission commands behave as before."""
    plugins = os.path.join(os.path.realpath(claude_config_dir()), "plugins")
    base = os.path.join(plugins, "cache", "vibemaestro", SDLC)
    me = plugin_real()
    if os.path.dirname(me) != base:
        return None
    try:
        data = json.loads(read_small(os.path.join(plugins, "installed_plugins.json"), MAX_REGISTRY, nofollow=False))
    except (OSError, ValueError, RecursionError):
        return None
    ids = data.get("plugins") if isinstance(data, dict) else None
    entries = ids.get("%s@vibemaestro" % SDLC) if isinstance(ids, dict) else None
    best, listed = None, False
    for e in entries if isinstance(entries, list) else []:
        path = e.get("installPath") if isinstance(e, dict) else None
        if not usable_path(path):
            return None
        real = os.path.realpath(path)
        if os.path.dirname(real) != base or not VERSIONED.fullmatch("/%s/%s/" % (SDLC, os.path.basename(real))):
            return None
        listed = listed or real == me
        stamp = e.get("lastUpdated") if isinstance(e.get("lastUpdated"), str) else ""
        if os.path.isfile(os.path.join(real, "scripts", "baton.py")) and (best is None or stamp > best[0]):
            best = (stamp, real)
    if best is None or listed:
        return None
    return os.path.basename(me), os.path.basename(best[1]), best[1]


def other_line(other):
    """The one line for a session whose sdlc is not the registry's: it never names this copy's --install-launcher, whose
    launcher would replace the installed sdlc's."""
    return shown("baton permissions: this session runs a different vibemaestro-sdlc version than the installed one (session %s, "
                 "installed %s): restart Claude Code", other[0], other[1])


LAUNCHER_PROBE = """import json, sys
def probe(src):
    ns = {"__name__": "baton_launcher_probe"}
    exec(compile(src, "<launcher>", "exec"), ns)
    try:
        ns["resolve"]()
    except ns["Refused"] as e:
        return str(e) or "no reason given"
with open(sys.argv[1], encoding="utf-8") as f:
    installed = f.read()
print(json.dumps([probe(installed), probe(sys.stdin.read())]))
"""


def launcher_refuses():
    """The reason the installed launcher refuses every baton.py when this version's launcher would not (a reinstall fixes it),
    from each one's own resolve(): both are loaded under python3 -I without their __main__ (no re-exec, no baton.py started); the
    installed one is already what every allowed baton command runs. None when the installed one resolves, when this version's
    refuses too (the registry is at fault, not the copy), or when the probe cannot tell."""
    try:
        p = subprocess.run([sys.executable, "-I", "-c", LAUNCHER_PROBE, launcher_path()], input=launcher_text(),
                           capture_output=True, text=True, timeout=5)
        installed, mine = json.loads(p.stdout) if p.returncode == 0 else (None, None)
    except (OSError, subprocess.SubprocessError, ValueError, TypeError, Stop):
        return None
    return installed if isinstance(installed, str) and mine is None else None


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


# The ask rules of the block before the anchored ones: a leading `*` matched any command that only mentioned the words (a printf, a heredoc, a
# commit message). `permissions --check` names each one, and kit:permissions-upgrade swaps exactly these for owner_asks().
OLD_ASKS = ("Bash(*baton* sign --by owner*)",) + tuple(
    "Bash(*%s%s mode *)" % (prog, q) for prog in ("baton.py", "/baton") for q in ("", '"', "'"))
OLD_ASK_FINDING = "the old broad ask rule "     # its finding's text starts so: kit:coordinator-bootstrap sets it aside
OWNER_SUBS = ("sign --by owner", "mode")


def spellings(path):
    """The ways a session spells one path as a program word: shell-quoted as the kit prints it, and in double or single quotes
    (each only where those quotes keep the path as it is), without repeats."""
    out = [shlex.quote(path)]
    if not re.search(r'["$`\\!]', path):
        out.append('"%s"' % path)
    if "'" not in path:
        out.append("'%s'" % path)
    return list(dict.fromkeys(out))


def home_spellings(path):
    """`~/rel`, `$HOME/rel` and `"$HOME/rel"` for a path under HOME whose rest needs no quoting, else []."""
    home = os.path.expanduser("~")
    if not os.path.isabs(home):
        return []
    rel = os.path.relpath(path, home)
    if rel == ".." or rel.startswith("../") or shlex.quote(rel) != rel or "*" in rel:
        return []
    return ["~/" + rel, "$HOME/" + rel, '"$HOME/%s"' % rel]


def owner_programs():
    """[(program, wild)]: every program word the ask rules anchor a `sign --by owner` or `mode` call to. wild: the word holds a
    `*` (the version directory under the Claude plugins directory), so its rules are wildcards, else `:*` prefixes. A star only
    ever follows a literal path of this machine: in Claude Code's wildcard `*` is any text, `/` and spaces included."""
    lp, plugins, real = launcher_path(), os.path.join(claude_config_dir(), "plugins"), os.path.abspath(__file__)
    progs = [(w, False) for w in spellings(lp) + home_spellings(lp) + ["baton"]]
    tail = "/*/scripts/baton.py"                        # the version directory (cache/…/<version>, or a marketplace's tree)
    lit = plugins.replace("\\", "\\\\").replace("*", "\\*")   # the literal part, escaped as Claude Code's wildcard reads it
    pys = []
    for w in spellings(plugins) + home_spellings(plugins):
        if len(w) > 1 and w[0] in "'\"" and w[-1] == w[0]:
            pys.append((w[0] + w[1:-1].replace(plugins, lit) + tail + w[-1], True))
        else:
            pys.append((w.replace(plugins, lit) + tail, True))
    if not real.startswith(plugins + "/"):
        pys += [(w, False) for w in spellings(real)]                 # a checkout: its own path, nothing wider
    return progs + pys + [("python3 " + w, wild) for w, wild in pys]


def owner_asks():
    """The ask rules: each owner program, then `sign --by owner` or `mode`. A prefix rule matches the call and nothing before it;
    a wildcard rule names the subcommand right after the program, so a `run … mode fast` argument stays out."""
    out = []
    for sub in OWNER_SUBS:
        for prog, wild in owner_programs():
            out.append("Bash(%s %s *)" % (prog, sub) if wild else "Bash(%s %s:*)" % (prog, sub))
    return out


def snippet():
    L, plugins, st = shlex.quote(launcher_path()), os.path.join(claude_config_dir(), "plugins"), state_dir()
    allow = ["Bash(%s %s:*)" % (L, sub) for sub, _a in ALLOWED_SUBS] + ["Bash(%s sign --by coordinator-auto:*)" % L]
    T = tilde_launcher()
    if T:                                               # the same commands spelled from ~/
        allow += ["Bash(%s %s:*)" % (T, sub) for sub, _a in ALLOWED_SUBS] + ["Bash(%s sign --by coordinator-auto:*)" % T]
    deny = ["Edit(/%s/**)" % plugins, "Edit(/%s/**)" % st]
    return {"permissions": {"allow": allow, "ask": owner_asks(), "deny": deny}, "attribution": dict(ATTRIBUTION_OFF)}


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


def owner_probe_programs():
    """The program words of a real `sign --by owner` or `mode` call, written out for this machine as the kit prints them or a
    session types them: the launcher (bare, quoted, from ~/ or $HOME), a bare `baton`, and baton.py of a cached version, of the
    marketplace's tree and of this copy when it lies under the plugins directory, each bare, quoted and after python3. A checkout
    elsewhere is a developer's copy: --print names it when it prints, but another copy's check does not require it."""
    lp, plugins, real = launcher_path(), os.path.join(claude_config_dir(), "plugins"), os.path.abspath(__file__)
    out = spellings(lp) + home_spellings(lp) + ["baton"]
    pys = [os.path.join(plugins, "cache", "vibemaestro", "vibemaestro-sdlc", "0.0.0", "scripts", "baton.py"),
           os.path.join(plugins, "marketplaces", "vibemaestro", "plugins", "vibemaestro-sdlc", "scripts", "baton.py")]
    pys += [real] if real.startswith(plugins + "/") else []
    words = []
    for p in pys:
        words += spellings(p) + home_spellings(p)
    return list(dict.fromkeys(out + words + ["python3 " + w for w in words]))


def owner_probes():
    """The spellings of `sign --by owner` that the ask rules must catch."""
    out = []
    for prog in owner_probe_programs():
        out += ["%s sign --by owner %s" % (prog, SEAL_PROBE), "%s sign --by owner --queued 0123456789abcdef" % prog]
    return out


def mode_probes():
    """The spellings of a mode change that the ask rules must catch."""
    out = []
    for prog in owner_probe_programs():
        out += ["%s mode auto" % prog, "%s mode manual" % prog, "%s mode trust github.com/acme/app" % prog]
    return out


def mention_probes():
    """(what, command): commands that only mention a sign or a mode call; no ask rule may catch them."""
    L, real = shlex.quote(launcher_path()), shlex.quote(os.path.abspath(__file__))
    return [("a printf piped to a message send", "printf 'next: %s sign --by owner %s\\n' | sandbox.sh send w -" % (L, SEAL_PROBE)),
            ("an echo", 'echo "then run %s mode auto"' % L),
            ("a python heredoc", "python3 - <<'EOF'\nprint('python3 %s sign --by owner %s')\nEOF" % (real, SEAL_PROBE)),
            ("a heredoc into a file", "cat > note.md <<'EOF'\n%s mode auto\nEOF" % L),
            ("a quoted string", "'%s sign --by owner' is the owner's line" % L),
            ("a gh comment body", 'gh issue comment 561 --body "the rule asked for python3 %s mode auto"' % real),
            ("a gh comment by its path", '/usr/bin/gh issue comment 561 --body "%s mode auto"' % real),
            ("a gh issue body", "gh issue create --title t --body 'baton sign --by owner and baton.py mode manual'"),
            ("a commit message", 'git commit -m "docs: %s sign --by owner, then python3 %s mode auto"' % (L, real)),
            ("a grep", "grep -rn 'baton sign --by owner' kb"), ("a grep", 'grep -rn "/baton mode auto" .')]


def perm_findings(sources):
    """[(kind, text)]: kind is MISSING, STALE, UNSAFE or UNREADABLE. Empty when the rules in force hold the snippet's split."""
    rules, probs = load_rules(sources)
    out = list(probs)
    L, real = shlex.quote(launcher_path()), os.path.abspath(__file__)
    q = lambda c: "`%s`" % c                                                          # noqa: E731
    want_allow = ["%s %s %s" % (L, sub, a) for sub, a in ALLOWED_SUBS]
    auto_sign = "%s sign --by coordinator-auto %s" % (L, SEAL_PROBE)
    owner, modes = owner_probes(), mode_probes()
    probes, T = want_allow + [auto_sign], tilde_launcher()
    if T:
        probes += ["%s %s %s" % (T, sub, a) for sub, a in ALLOWED_SUBS] + ["%s sign --by coordinator-auto %s" % (T, SEAL_PROBE)]
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
    for k, tool, content, text, where in rules:
        if k == "ask" and tool == "Bash" and text in OLD_ASKS:
            out.append(("STALE", OLD_ASK_FINDING + "%s (%s) asks for any command that only mentions it (a printf, a heredoc, "
                                 "a commit message): kit:permissions-upgrade replaces it with the anchored rules" % (q(text), where)))
    serves = lambda content: content and any(bash_matches(content, c) for c in owner + modes)   # noqa: E731
    for what, cmd in mention_probes():
        for k, tool, content, text, where in rules:      # an owner's own ask rule (`git commit:*`) that asks no sign or mode is theirs
            if k == "ask" and tool == "Bash" and text not in OLD_ASKS and serves(content) and bash_matches(content, cmd):
                out.append(("STALE", "the ask rule %s (%s) asks for a command that only mentions a sign or a mode call (%s): "
                                     "a dialog must mean the call" % (q(text), where, what)))
    plugins, st = os.path.join(claude_config_dir(), "plugins"), state_dir()
    guarded = (os.path.join(plugins, "installed_plugins.json"),
               os.path.join(plugins, "cache", "vibemaestro", "vibemaestro-sdlc", "0.0.0", "scripts", "baton.py"),
               os.path.join(st, "bin", "baton"), os.path.join(st, "mode"), os.path.join(st, "remotes"),
               os.path.join(st, "signatures", "x.json"))
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
        why = launcher_refuses()
        if why:                                         # first: every baton fails until it is reinstalled; the reason is the
            # launcher's own text (it can carry registry values) and the SessionStart line formats findings raw: escaped here
            out.insert(0, ("STALE", "the launcher %s cannot run the installed vibemaestro-sdlc (%s): every baton is refused "
                                    "until --install-launcher from the installed sdlc" % (launcher_path(), esc(why))))
        else:
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


def launcher_line():
    """The SessionStart line naming an installed launcher that does not lie at TEXT_LAUNCHER, spelled as the printed rules allow
    it (the `~/` spelling, else the quoted path), or None: at the default place the kit's text is already right."""
    if not os.path.isfile(launcher_path()):
        return None
    typed = tilde_launcher() or shlex.quote(launcher_path())
    if typed == TEXT_LAUNCHER:
        return None
    return shown("baton launcher: here it is %s; type it where the kit's text says %s", typed, TEXT_LAUNCHER)


def session_warning():
    """One line for SessionStart, or None. In mode manual with no baton rule anywhere, a missing rule is not a finding: there
    every baton command opening a dialog is the intended behaviour; a stale or unsafe rule still is. A session whose sdlc is not
    the registry's gets the restart line only: its view of the rules and the launcher is another version's. A launcher away
    from TEXT_LAUNCHER adds launcher_line. The line goes into the session context as it is, so it is built by shown: a path in
    a finding cannot start a line there."""
    other = registry_other()
    if other:
        return other_line(other)
    sources, mode = settings_sources(), read_mode()
    found = perm_findings(sources)
    if mode == "manual" and not baton_rules_present(sources):
        found = [f for f in found if f[0] != "MISSING"]
    parts = [launcher_line()]
    if found:
        kinds = sorted(set(k for k, _t in found))
        parts.insert(0, shown("baton permissions (mode %s): %d %s (first: %s); print the fix with: %s",
                              mode, len(found), "/".join(k.lower() for k in kinds), found[0][1], fix_hint()))
    parts = [x for x in parts if x]
    return shown_join("; ", parts) if parts else None


def cmd_permissions(rest):
    usage = "usage: baton.py permissions --print | --check [--settings F]... | --install-launcher [--force]"
    other = registry_other()
    if rest == ["--print"]:
        for ln in json.dumps(snippet(), indent=2).split("\n"):      # json writes every control character as \uXXXX
            say("%s", ln)
        if other:
            say("%s", other_line(other), out=sys.stderr)
        if not other and not launcher_current():
            say("baton: the launcher these rules name is not installed (or not current): run %s permissions --install-launcher",
                "python3 " + shlex.quote(os.path.abspath(__file__)), out=sys.stderr)
        return OK
    if rest[:1] == ["--install-launcher"] and rest[1:] in ([], ["--force"]):
        force = rest[1:] == ["--force"]
        if other and not force:                         # a code, not a Stop: the bootstrap gate calls this in process
            say("baton: %s; nothing written. The installed one writes its launcher: python3 -I %s permissions "
                "--install-launcher (--force overrides this refusal)", other_line(other)[len("baton permissions: "):],
                shlex.quote(os.path.join(other[2], "scripts", "baton.py")), out=sys.stderr)
            return OTHER_SDLC
        d = ensure_state()
        try:
            os.makedirs(os.path.join(d, "bin"), mode=0o700, exist_ok=True)
            write_private(launcher_path(), launcher_text())
            os.chmod(launcher_path(), 0o700)
        except OSError as e:
            raise Stop(ENV, "the launcher cannot be installed: %s", e.strerror or e)
        say("launcher %s installed: the permission rules name it (%s permissions --print)", launcher_path(), entry_command())
        return OK
    if not rest or rest[0] != "--check":
        raise Stop(USAGE, "%s", usage)
    files, i = [], 1
    while i < len(rest):
        if rest[i] == "--settings" and i + 1 < len(rest):
            files.append(rest[i + 1])
            i += 2
        else:
            raise Stop(USAGE, "%s", usage)
    sources = [("given", os.path.abspath(f)) for f in files] or settings_sources()
    for f in files:
        if not os.path.isfile(f):
            raise Stop(USAGE, "--settings %s: no such file", f)
    if other:
        say("%s", other_line(other))
        return OTHER_SDLC
    found = perm_findings(sources)
    say("baton permissions: mode %s; settings read: %s", read_mode(), ", ".join(p for _l, p in sources if os.path.exists(p))
                                                          or "none")
    for kind, text in found:
        say("%-10s %s", kind, text)
    for text in attribution_warnings(sources):
        say("%-10s %s; --print has the block that turns it off (it does not change the exit code)", "WARNING", text)
    if not found:
        say("ok: the rules hold the split (the session signs Stops: none in mode auto; the owner's signature and mode ask)")
        return OK
    say("fix: %s; apply the printed rules through Claude Code's settings (/permissions or settings.json): baton never writes "
        "them", fix_hint())
    return PERMS


COMMANDS = {"new": cmd_new, "check": cmd_check, "rehearse": cmd_rehearse, "sign": cmd_sign, "run": cmd_run, "go": cmd_go,
            "list": cmd_list, "pack": cmd_pack, "log": cmd_log, "mode": cmd_mode, "permissions": cmd_permissions}


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
        say("baton: usage: baton.py help <topic>; the topics are %s", ", ".join(HELP_TOPICS), out=sys.stderr)
        return USAGE
    try:
        with open(os.path.join(HELP_DIR, rest[0] + ".md"), encoding="utf-8") as f:
            sys.stdout.write(f.read())
    except OSError as e:
        say("baton: cannot read the topic %s: %s", rest[0], e.strerror or e, out=sys.stderr)
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
        say(__doc__.strip(), out=sys.stdout if argv else sys.stderr)
        if argv:
            say("\nTopics (baton.py help <topic>, the reference files next to the batonrun skill): %s", ", ".join(HELP_TOPICS))
        return OK if argv else USAGE
    fn = COMMANDS.get(argv[0])
    if fn is None:
        say("baton: unknown command %s (one of: %s)", repr(argv[0]), ", ".join(COMMANDS), out=sys.stderr)
        return USAGE
    try:
        try:
            return fn(list(argv[1:]))
        finally:
            drop_copies()
    except Stop as e:
        say("baton: %s", e.text, out=sys.stderr)
        return e.rc
    except (KeyboardInterrupt, Interrupted):
        if RUN["consumed"]:
            say("baton: interrupted after the signature was used: the state is unknown, tell the owner", out=sys.stderr)
            return UNKNOWN
        say("baton: interrupted before any run phase; nothing ran", out=sys.stderr)
        return REFUSED
    except Exception as e:                              # never a traceback with rc 1, which means "fails check"
        say("baton: unexpected %s: %s", type(e).__name__, e, out=sys.stderr)
        return ENV


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
