#!/usr/bin/env python3
"""The local state file: what a worker outside a sandbox records for a dashboard to read.

    local_state.py <spec|code|review|ship> <stem> [--subagents <0-99>]
    local_state.py ask <stem>                   the question on stdin
    local_state.py done <stem>                  the report on stdin
    local_state.py progress <stem> --step <step>
    local_state.py bind <stem> --agent <id>

`scripts/stage-signal.sh` runs this (with `python3 -I`) when `session-notify` is not on the PATH, after it has found the stem; a
skill calls stage-signal.sh, never this file. The place, the JSON shape, its versions and how a reader ties a file to its
transcript and its coordinator are the item `local-state` of the plugin's CONTRACT.md: that item is the contract, this header
does not repeat it.

How it writes: under `flock` on `<stem>.lock` (LOCK_WAIT seconds, then a refusal), into a temp file opened with O_EXCL and
O_NOFOLLOW, mode 0600, then `os.replace`, so a reader never sees half a file. The session directory is made 0700; a linked
`vibemaestro`, `sessions` or session directory, or a linked target, is refused. Only fixed phrases, the stem, the step, the session id and the agent id are
written from arguments, each checked against a fixed pattern first; the question and the report come from stdin only (never from
an argument, so no caller quotes them into a command line), are stored as JSON string data, cut to QUESTION_MAX and REPORT_MAX
characters, and are never run or parsed.

Exit 0 in every case: a signal never fails the work. A refusal prints one line on stderr and writes nothing. Without
CLAUDE_CODE_SESSION_ID nothing is written and nothing is printed (no session to show it on).
Standard library only, Python 3.8+.
"""
import datetime as dt
import errno
import fcntl
import glob
import json
import os
import re
import select
import sys
import time

SCHEMA = 1
LOCAL_V = 1
QUESTION_MAX = 2000
REPORT_MAX = 500
STDIN_MAX = 64 * 1024
STDIN_WAIT = 5.0
DRAIN_MAX = 4 * 1024 * 1024
LOCK_WAIT = 2.0
STAGES = {"spec": "spec stage started", "code": "coding started", "review": "review round started", "ship": "ship started"}
STEPS = {"tests-pass": "tests pass", "tests-fail": "tests fail", "ci-green": "CI green", "ci-red": "CI red",
         "fix-pushed": "review fix pushed"}
STATES = ("working", "waiting", "done")
STEM_RX = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9]+(?:-[a-z0-9]+)*")
STEM_MAX = 80
ID_RX = re.compile(r"[A-Za-z0-9_-]{1,64}")


def ts_text(now):
    return dt.datetime.fromtimestamp(now, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class Refuse(Exception):
    pass


def trunc(s, n):
    """Cut to at most n characters, keeping the start; when cut, end with `…` (the total stays <= n)."""
    return s if len(s) <= n else s[: n - 1] + "…"


def valid_stem(s):
    return isinstance(s, str) and len(s) <= STEM_MAX and STEM_RX.fullmatch(s) is not None


def parse(argv):
    """(verb, stem, opts) or Refuse."""
    if len(argv) < 2:
        raise Refuse("usage: local_state.py <verb> <stem> [--subagents <n>|--step <step>|--agent <id>]")
    verb, stem, rest = argv[0], argv[1], argv[2:]
    allowed = {"--subagents"} if verb in STAGES else {"--step"} if verb == "progress" else {"--agent"} if verb == "bind" else set()
    if verb not in STAGES and verb not in ("ask", "done", "progress", "bind"):
        raise Refuse("unknown verb")
    if not valid_stem(stem):
        raise Refuse("the intent stem is not <YYYY-MM-DD>-<slug> (lower case, digits, hyphens, at most %d characters)" % STEM_MAX)
    opts = {}
    while rest:
        if rest[0] not in allowed or len(rest) < 2 or rest[0] in opts:
            raise Refuse("unknown, repeated or empty argument for %s" % verb)
        opts[rest[0]], rest = rest[1], rest[2:]
    if verb == "progress" and opts.get("--step") not in STEPS:
        raise Refuse("unknown progress step: one of %s" % ", ".join(STEPS))
    if verb == "bind" and not ID_RX.fullmatch(opts.get("--agent", "")):
        raise Refuse("bind needs --agent <id> (letters, digits, - and _, at most 64)")
    sub = opts.get("--subagents", "0")
    if not re.fullmatch(r"[0-9]{1,2}", sub):
        raise Refuse("--subagents is not 0-99")
    opts["--subagents"] = int(sub)
    return verb, stem, opts


def read_text(limit):
    """The question or the report, from stdin only: kept as given, less its trailing line ends. When the text is taken, input past
    STDIN_MAX is read and dropped up to DRAIN_MAX, so a heredoc or a pipe of that size ends cleanly; the whole read ends within
    STDIN_WAIT seconds (an input still open then is refused), so no stdin holds the caller, with or without `timeout`."""
    if sys.stdin is None:
        raise Refuse("the text goes on stdin (a quoted heredoc), and stdin is closed")
    if sys.stdin.isatty():
        raise Refuse("the text goes on stdin (a quoted heredoc), and stdin is a terminal")
    fd, got, n = sys.stdin.fileno(), [], 0
    deadline = time.monotonic() + STDIN_WAIT
    while n <= DRAIN_MAX:
        left = deadline - time.monotonic()
        if left <= 0 or not select.select([fd], [], [], left)[0]:
            raise Refuse("stdin did not end within %d seconds" % STDIN_WAIT)
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        if n < STDIN_MAX:
            got.append(chunk[: STDIN_MAX - n])
        n += len(chunk)
    t = b"".join(got).decode("utf-8", "replace").rstrip("\r\n")
    if not t.strip():
        raise Refuse("missing text on stdin")
    return trunc(t, limit)


def state_root():
    x = os.environ.get("XDG_STATE_HOME", "")
    if x and os.path.isabs(x):
        return x
    h = os.environ.get("HOME", "")
    if not h or not os.path.isabs(h):
        raise Refuse("no absolute XDG_STATE_HOME or HOME")
    return os.path.join(h, ".local", "state")


def session_dir(session):
    top = os.path.join(state_root(), "vibemaestro")
    base = os.path.join(top, "sessions")
    d = os.path.join(base, session)
    if os.path.islink(top) or os.path.islink(base):
        raise Refuse("the vibemaestro or sessions directory is a link")
    try:
        os.makedirs(base, mode=0o700, exist_ok=True)
        os.mkdir(d, 0o700)
    except FileExistsError:
        pass
    st = os.lstat(d)
    if not os.path.isdir(d) or os.path.islink(d) or st.st_uid != os.getuid():
        raise Refuse("the session directory is a link, not a directory, or not this user's")
    os.chmod(d, 0o700)
    return d


def read_current(path, stem):
    """The file's last content when it is this contract's and this stem's, else None (a fresh start)."""
    if os.path.islink(path):
        raise Refuse("the state file is a link")
    try:
        with open(path, encoding="utf-8") as f:
            cur = json.load(f)
    except FileNotFoundError:
        return None
    except (OSError, ValueError):
        return None
    loc = cur.get("local") if isinstance(cur, dict) else None
    if not isinstance(loc, dict) or cur.get("schema") != SCHEMA or loc.get("stem") != stem or cur.get("state") not in STATES:
        return None
    return cur


def integer(v):
    return v if isinstance(v, int) and not isinstance(v, bool) and 0 <= v < 10 ** 10 else None


def carried_intents(cur, stem):
    e = ((cur or {}).get("intents") or {}).get(stem) if isinstance((cur or {}).get("intents"), dict) else None
    ok = (isinstance(e, dict) and set(e) == {"stage", "subagents", "text", "epoch"} and e["stage"] in STAGES
          and integer(e["subagents"]) is not None and e["subagents"] <= 99 and integer(e["epoch"]) is not None
          and e["text"] == "%s: %s" % (stem, STAGES[e["stage"]]))
    return {stem: dict(e)} if ok else {}


def build(cur, verb, stem, opts, session, text, now):
    c = cur or {}
    loc = c.get("local") or {}
    prog = c.get("progress")
    prog = prog if isinstance(prog, str) and prog in {"%s: %s" % (stem, p) for p in STEPS.values()} else None
    agent = loc.get("agent") if isinstance(loc.get("agent"), str) and ID_RX.fullmatch(loc.get("agent")) else None
    child = loc.get("child") is True or os.environ.get("CLAUDE_CODE_CHILD_SESSION") == "1"
    state = {"ask": "waiting", "done": "done", "bind": c.get("state", "working")}.get(verb, "working")
    changed = cur is None or c.get("state") != state
    renew = changed or integer(c.get("epoch")) is None or c.get("ts") != ts_text(c.get("epoch"))   # ts and epoch go as one pair
    st = {
        "schema": SCHEMA,
        "state": state,
        "ts": ts_text(int(now)) if renew else c.get("ts"),
        "epoch": int(now) if renew else c.get("epoch"),
        "event": "stage" if verb in STAGES else verb,
        "question": None,
        "source": None,
        "tail": None,
        "hint": False,
        "session": session,
        "progress": prog,
        "progress_epoch": integer(c.get("progress_epoch")) if prog else None,
        "intents": carried_intents(cur, stem),
        "local": {"v": LOCAL_V, "stem": stem, "agent": agent, "child": child},
    }
    if state == "waiting":
        st["question"], st["source"] = (text if verb == "ask" else c.get("question")), "ask"
    if state == "done":
        st["tail"] = text if verb == "done" else c.get("tail")
    if verb in STAGES:
        st["intents"] = {stem: {"stage": verb, "subagents": opts["--subagents"], "text": "%s: %s" % (stem, STAGES[verb]),
                                "epoch": int(now)}}
    elif verb == "progress":
        st["progress"], st["progress_epoch"] = "%s: %s" % (stem, STEPS[opts["--step"]]), int(now)
    elif verb == "bind":
        st["local"]["agent"] = opts["--agent"]
    for k, n in (("question", QUESTION_MAX), ("tail", REPORT_MAX)):
        if not isinstance(st[k], str):
            st[k] = None
        else:
            st[k] = trunc(st[k], n)
    if st["question"] is None:
        st["source"] = None
    return st


def write_atomic(d, stem, st):
    path = os.path.join(d, stem + ".json")
    tmp = os.path.join(d, ".%s.json.tmp.%d" % (stem, os.getpid()))
    for old in glob.glob(os.path.join(glob.escape(d), ".%s.json.tmp.*" % stem)):
        try:
            os.unlink(old)                       # a writer killed before its replace left it; the lock is held, so it is stale
        except OSError:
            pass                                 # what cannot go is left; the temp name of this pid is still free
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            os.fchmod(f.fileno(), 0o600)
            json.dump(st, f, ensure_ascii=False)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        if os.path.islink(path):
            raise Refuse("the state file is a link")
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def record(argv):
    session = os.environ.get("CLAUDE_CODE_SESSION_ID", "")
    if not session:
        return                                   # no session to show it on: silent
    if not ID_RX.fullmatch(session):
        raise Refuse("CLAUDE_CODE_SESSION_ID is not letters, digits, - and _ (at most 64)")
    verb, stem, opts = parse(argv)
    text = read_text(QUESTION_MAX if verb == "ask" else REPORT_MAX) if verb in ("ask", "done") else None
    d = session_dir(session)
    lock = os.path.join(d, stem + ".lock")
    fd = os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        deadline = time.monotonic() + LOCK_WAIT
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except OSError as e:
                if e.errno not in (errno.EAGAIN, errno.EACCES) or time.monotonic() >= deadline:
                    raise Refuse("another writer holds the lock of %s" % stem)
                time.sleep(0.02)
        cur = read_current(os.path.join(d, stem + ".json"), stem)
        write_atomic(d, stem, build(cur, verb, stem, opts, session, text, time.time()))
    finally:
        os.close(fd)


def main(argv):
    try:
        record(argv)
    except Refuse as e:
        sys.stderr.write("stage-signal: %s; nothing recorded\n" % e)
    except Exception as e:                       # a signal never fails the work: one line, exit 0
        sys.stderr.write("stage-signal: the local state was not written (%s); going on\n" % type(e).__name__)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
