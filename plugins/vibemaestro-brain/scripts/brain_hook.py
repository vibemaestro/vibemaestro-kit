#!/usr/bin/env python3
"""vibemaestro-brain hooks: one entry for every event, `brain_hook.py <event>` with the hook JSON on stdin.

    session-start  string 1: inject hot memory (pins, windows, Now) and the Shelf index through additionalContext (≤ 8,000
                   characters); log the episode; mark an item whose anchor names a closed issue or merged PR, and in the
                   writer's session close an item whose `closes` anchors are all done (brain_stale.py). It renders strings 2
                   and 3 in the same pass and hands each over in a file of `starts/` (Claude Code runs the three commands in
                   parallel); the command that prints one deletes its file, so a hand-over is used once
    session-start-sessions, session-start-plan
                   strings 2 (`## Brain · sessions`: S, Q) and 3 (`## Brain · plan`: X, T, Done, F), ≤ 9,500 characters each:
                   what session-start handed over for this SessionStart, else, after START_WAIT, their own part from the
                   log without lookups; nothing when the part is empty and has no note
    pre-compact    log the trigger and the context size (S1) from the transcript's tail; add the calls since the saved
                   byte offset to the session's running cost sums (B1.3); never blocks
    post-compact   save compact_summary (0600, never injected) and log the loss score
    session-end    delete this session's "asked" records; append the `cost` line from the saved sums (B1.3); log the end
                   (no fold, no transcript read: a 1.5-second budget)
    guard-bash     deny `brain op` from a subagent (agent_id present)
    guard-edit     deny Edit/Write/NotebookEdit under the brain state root
    guard-owner    on an owner-shaped Bash command: ask with the one-line dialog and write the "asked" record in a dialog
                   mode; deny otherwise (owner-confirmation spec)
    update-check   the update reminder: vibemaestro-sdlc's scripts/update_check.py run with brain's own root and data
                   (one `systemMessage` line when a newer public brain exists); silent when sdlc is not found

Every event is silent under BRAIN_OFF and in a sandbox worker (INTENT_SLUG and SEAT); every event but guard-owner and
session-end is silent in a project with no hot memory. Fail-open: an error is one line on stderr and rc 0. A guard denies or
asks only on a positive match; a guard-owner that fails writes no record (or voids the one it wrote), so the CLI refuses.
Standard library only, Python 3.8.
"""
import os
import sys


def state_root():
    """brain_store.state_root() without its imports (tests/test-brain-hooks.sh [R] holds the two equal)."""
    x = os.environ.get("XDG_STATE_HOME", "")
    if not os.path.isabs(x):
        h = os.environ.get("HOME", "")
        if not os.path.isabs(h):                    # rare: the store's own answer (the password database)
            sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
            import brain_store
            return brain_store.state_root()
        x = os.path.join(h, ".local", "state")
    return os.path.join(x, "vibemaestro", "brain")


def pending_dir():
    """`<state root>/pending/`: one marker per session whose "asked" record waits for the very call it was asked for."""
    return os.path.join(state_root(), "pending")


SWEEP_AGE = 1200        # seconds: a marker older than twice a record's life (brain_store.RECORD_MAX_AGE) is a crashed session's


# guard-owner runs on every Bash call: the common "not mine" case is decided from the raw input before the imports below,
# which cost about 15 ms of a guard's 22 (measured with `python3 -X importtime`). A missed match fails safe: guard-owner writes
# no record, so the CLI refuses; guard-bash is a slip guard. While any session has a pending record, guard-owner takes the
# full path on every call, so the next Bash call of that session voids it (round 1).
_FAST = {"guard-owner": (b"brain", b"owner"), "guard-bash": (b"brain", b"agent_id")}
_RAW = None
if __name__ == "__main__" and sys.argv[1:2] and sys.argv[1] in _FAST:
    _RAW = sys.stdin.buffer.read()
    if not all(w in _RAW for w in _FAST[sys.argv[1]]):
        waiting = False
        if sys.argv[1] == "guard-owner":
            import stat as _stat
            import time as _time
            try:
                _names = os.listdir(pending_dir())
            except FileNotFoundError:
                _names = []
            except OSError:
                _names, waiting = [], True
            for _m in _names:                                  # any doubt takes the full path, never the fast one
                _p = os.path.join(pending_dir(), _m)
                try:
                    _st = os.lstat(_p)
                    _age = _time.time() - _st.st_mtime
                    if not _stat.S_ISREG(_st.st_mode):
                        continue                               # never a marker (mark_pending writes regular files)
                    if -SWEEP_AGE < _age < SWEEP_AGE:
                        waiting = True
                    else:
                        os.unlink(_p)
                except OSError:
                    waiting = True
        if not waiting:
            sys.exit(0)

import contextlib  # noqa: E402
import glob  # noqa: E402
import hashlib  # noqa: E402
import io  # noqa: E402
import json  # noqa: E402
import re  # noqa: E402
import shlex  # noqa: E402
import subprocess  # noqa: E402
import time  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

BLOCK_MAX = 8000
START_WAIT = 6.0                        # seconds strings 2 and 3 wait for string 1's hand-over (worst case: 4 s of waits, then its work)
SIBLINGS = 1.0                          # seconds between the starts of the commands of one SessionStart, at most (measured: 2 ms)
T_START = time.time()                   # this process's start: the commands of one SessionStart start together
PART_EVENTS = {"session-start-sessions": "sessions", "session-start-plan": "plan"}
SHELF_MAX = 1000
SHELF_LINE = 100
PLUGIN_LINE = 200
TAIL_BYTES = 256 * 1024                 # design value: the transcript tail read for the last `usage`
SUMMARIES_KEPT = 200
VERSION_FLOOR = (2, 1, 211)
OWNER_VERBS = ("add", "unpin", "supersede", "promote")
TEST_ASK_MODES = ("plan", "bypassPermissions")   # the only modes BRAIN_TEST_ASK_MODES may add, and only with BRAIN_TEST=1
LITERAL = ("write one `brain owner …` command alone in the Bash call, with literal arguments: no variable, substitution, "
           "backslash, glob, ~ or redirect, and nothing before or after it, so the dialog shows exactly what runs")


def off():
    return (os.environ.get("BRAIN_OFF", "") not in ("", "0")
            or bool(os.environ.get("INTENT_SLUG") and os.environ.get("SEAT")))


def emit(event, **fields):
    """One JSON line, UTF-8 whatever the locale (a non-UTF-8 stdout would lose the dialog line's `·`, round 1)."""
    out = json.dumps({"hookSpecificOutput": dict(fields, hookEventName=event)}, ensure_ascii=False) + "\n"
    sys.stdout.flush()
    sys.stdout.buffer.write(out.encode("utf-8"))
    sys.stdout.buffer.flush()


def decide(decision, reason):
    emit("PreToolUse", permissionDecision=decision, permissionDecisionReason=reason)


def store():
    import brain_store
    return brain_store


def has_state(d):
    return os.path.isfile(os.path.join(d, "hot.jsonl"))


def episode(d, inp, kind, **fields):
    """Append one line to episodes.jsonl (append-only, 0600, one write per line)."""
    store().episode_line(d, inp.get("session_id"), kind, **fields)


def cwd_of(inp):
    c = inp.get("cwd")
    return c if isinstance(c, str) and os.path.isabs(c) and os.path.isdir(c) else os.getcwd()


def unwritten(s, sid, d):
    """After a failed write of the session's record: what `brain` run from Bash will use now. A record naming another brain
    is removed (best effort), so it cannot send the CLI there; one naming this brain (a sibling worktree) is kept."""
    try:
        left = s.read_session(sid)
    except s.Refused:
        return ""                                   # the CLI refuses a damaged record itself, naming it
    if left and left["state"] == d:
        return ""
    if left:
        s.drop_session(sid)
        try:
            left = s.read_session(sid)
        except s.Refused:
            return ""
    if left:
        return "; it still names %s, which `brain` run from Bash would use" % s.printable(left["project"])
    return "; `brain` run from Bash follows the shell's directory until a hook writes it"


def resolve(inp, record=True):
    """(project, state directory, the other project a new record replaced or None) of this session, never of the shell's
    directory while the session is known: CLAUDE_PROJECT_DIR (the directory the session started in; the input's `cwd` follows
    every `cd`), recorded under the session id for the CLI (unless `record` is false); else the session's record; else the
    input's cwd. A record that cannot be trusted raises, so the hook does nothing rather than act on another project."""
    s = store()
    sid = inp.get("session_id")
    sid = sid if isinstance(sid, str) and sid else ""
    env = os.environ.get("CLAUDE_PROJECT_DIR", "")
    if os.path.isabs(env) and os.path.isdir(env):
        d, old = s.state_dir(env), None
        try:
            old = s.record_session(sid, env, d) if sid and record else None
        except OSError as e:                        # the record serves the CLI; this hook still has its project
            sys.stderr.write("brain: the session's project record was not written: %s%s\n" % (e.__class__.__name__,
                                                                                                 unwritten(s, sid, d)))
        if old:
            sys.stderr.write("brain: this session's project was %s; it is now %s (CLAUDE_PROJECT_DIR)\n"
                             % (s.printable(old), s.printable(env)))
        return env, d, old
    b = s.read_session(sid) if sid else None
    if b:
        return b["project"], b["state"], None
    c = cwd_of(inp)
    return c, s.state_dir(c), None


# --- shell words --------------------------------------------------------------------------------------------------------------

def segments(cmd, heredoc=False):
    """[(text, flags)]: the command split at unquoted `;`, `&`, `|`, `(`, `)` and newlines. flags holds `expansion` ($, a
    backtick or a leading ~ outside single quotes), `glob` (unquoted * ? [ {), `redirect` (unquoted < >) and `open` (a quote
    left open). With `heredoc`, the body of a here-document (`<<` or `<<-`, not `<<<`) is skipped: it is a command's input,
    not a command, and its line `brain owner …` or its apostrophe is no word of the command. The segment holding the
    `<<` keeps its `redirect` flag, so a command with a here-document is never literal. A body is skipped only up to its
    closing line: a `<<` with no such line after it (a shift, as in `$((1<<2))`, `$[1<<2]` or `${a[1<<0]}`) skips nothing,
    so the lines after it stay commands (review rounds 1 and 2)."""
    out, cur, flags, docs = [], [], set(), []
    q, i, n, start = None, 0, len(cmd), True
    while i < n:
        c = cmd[i]
        if q == "'":
            cur.append(c)
            q = None if c == "'" else q
            i += 1
            continue
        if c in "\r\x0b\x0c":
            flags.add("control")                    # shlex reads \r as a space, bash as a character (round 1)
        if q == '"':
            if c == "\\":
                flags.add("escape")                 # bash and shlex unescape different sets inside double quotes
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
            out.append(("".join(cur), flags))
            cur, flags, start = [], set(), True
            i += 1
            if c == "\n" and docs:
                i, docs = skip_bodies(cmd, i, docs), []
            continue
        elif c in "<>":
            flags.add("redirect")
            if heredoc and cmd.startswith("<<", i):     # `<<<` has no word: its third `<` stops here_delim
                docs += [d for d in [here_delim(cmd, i + 2)] if d]
                cur.append("<<")
                i += 2
                start = False
                continue
        elif c in "$`~":
            flags.add("expansion")                  # ~ after `=` or `:` is expanded too, so any unquoted ~
        elif c in "*?[{":
            flags.add("glob")
        cur.append(c)
        start = c.isspace()
        i += 1
    if q:
        flags.add("open")
    out.append(("".join(cur), flags))
    return [(t, f) for t, f in out if t.strip()]


def here_delim(cmd, i):
    """(word, strip tabs) of the here-document whose operator ends just before `i`, or None: the word after an optional `-`
    and blanks, with its quotes and backslashes removed, as bash compares it to each body line."""
    strip = cmd[i:i + 1] == "-"
    if strip:
        i += 1
    while i < len(cmd) and cmd[i] in " \t":
        i += 1
    word, q = [], None
    while i < len(cmd):
        c = cmd[i]
        if q:
            if c == q:
                q = None
            else:
                word.append(c)
        elif c in "'\"":
            q = c
        elif c == "\\":
            word.append(cmd[i + 1:i + 2])
            i += 1
        elif c.isspace() or c in ";&|()<>":
            break
        else:
            word.append(c)
        i += 1
    return ("".join(word), strip) if word else None


def skip_bodies(cmd, i, docs):
    """The index after the bodies of `docs` [(word, strip tabs)] that start at `i`, one after the other. A body with no
    closing line is not skipped: bash would run it to the end of the command, but a `<<` that is a shift has none either,
    and its lines are commands; reading them as commands only keeps the deny of main."""
    for word, strip in docs:
        j = i
        while j < len(cmd):
            e = cmd.find("\n", j)
            line, j = (cmd[j:], len(cmd)) if e < 0 else (cmd[j:e], e + 1)
            if (line.lstrip("\t") if strip else line) == word:
                i = j
                break
    return i


def words(text):
    try:
        return shlex.split(text)
    except ValueError:
        return None


def lead_words(text, k=3):
    """The first `k` words of `text`, read as shlex reads them up to a quote left open: enough for `owner_tokens` to tell a
    brain call from a command that only mentions the words further on."""
    lex = shlex.shlex(text, posix=True)
    lex.whitespace_split, lex.commenters = True, ""
    out = []
    with contextlib.suppress(ValueError):
        while len(out) < k:
            w = lex.get_token()
            if w is None:
                break
            out.append(w)
    return out


def is_brain(w):
    return os.path.basename(w) in ("brain", "brain.py")


def owner_tokens(ws):
    """The tokens after `owner` when `ws` is owner-shaped, else None: the command starts with the brain word (or a python
    interpreter running brain.py) and `owner` follows it, as the CLI needs. `brain op … --text owner add` is not owner-shaped
    (round 1); neither is `echo brain owner …` nor `X=1 brain owner …`, which would show a dialog for a command that does not
    write what it shows (round 2): those run the CLI without a record, so it refuses."""
    i = 1 if ws[:1] and re.match(r"python[0-9.]*$", os.path.basename(ws[0])) else 0
    if i and os.path.basename(ws[1] if ws[1:] else "") != "brain.py":
        return None                                 # python runs brain.py, never the sh wrapper bin/brain (round 3)
    if ws[i:i + 1] and is_brain(ws[i]) and ws[i + 1:i + 2] == ["owner"]:
        return ws[i + 2:]
    return None


# --- SessionStart -------------------------------------------------------------------------------------------------------------

def frontmatter(path):
    """{key: value} of a SKILL.md's frontmatter (plain, quoted and block scalars)."""
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read(16384)
    except (OSError, UnicodeDecodeError):
        return {}
    m = re.match(r"---\r?\n(.*?)\r?\n---", text, re.S)
    if not m:
        return {}
    out, key, block = {}, None, []
    for line in m.group(1).splitlines():
        kv = re.match(r"([A-Za-z0-9_-]+):\s*(.*)$", line)
        if kv and not line.startswith((" ", "\t")):
            if key and block:
                out[key] = " ".join(block)
            key, v = kv.group(1), kv.group(2).strip()
            block = []
            if v in ("|", ">", "|-", ">-", "|+", ">+"):
                continue
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
                v = v[1:-1]
            out[key], key = v, None
        elif key is not None and line.strip():
            block.append(line.strip())
    if key and block:
        out[key] = " ".join(block)
    return out


def skills(root):
    """[(name, first sentence)] of the model-invocable skills under root/*/SKILL.md, sorted by name."""
    out = []
    for p in sorted(glob.glob(os.path.join(root, "*", "SKILL.md"))):
        fm = frontmatter(p)
        if str(fm.get("disable-model-invocation", "")).lower() == "true":
            continue
        desc = re.sub(r"\s+", " ", fm.get("description", "")).strip()
        first = re.split(r"(?<=[.!?])\s", desc, 1)[0]
        out.append((fm.get("name") or os.path.basename(os.path.dirname(p)), first))
    return sorted(out)


def enabled_plugins(s, project):
    """{plugin name: install path} of the plugins the settings enable (user, then project, then local; later wins)."""
    cfg = s.config_dir()
    enabled = {}
    for p in (os.path.join(cfg, "settings.json"), os.path.join(project, ".claude", "settings.json"),
              os.path.join(project, ".claude", "settings.local.json")):
        obj = s._json_file(p)
        if isinstance(obj, dict) and isinstance(obj.get("enabledPlugins"), dict):
            enabled.update(obj["enabledPlugins"])
    reg = s._json_file(os.path.join(cfg, "plugins", "installed_plugins.json"))
    plugins = reg.get("plugins") if isinstance(reg, dict) else None
    out = {}
    for key, entries in sorted(plugins.items() if isinstance(plugins, dict) else []):
        if enabled.get(key) is not True:
            continue
        for e in entries if isinstance(entries, list) else []:
            path = str(e.get("installPath", "")) if isinstance(e, dict) else ""
            if os.path.isdir(path):
                out[key.split("@")[0]] = path
                break
    return out


def shelf_index(s, project):
    """The Shelf index, ≤ SHELF_MAX characters: project and user skills one line each, plugin skills as names per plugin.
    Lines are chosen round-robin across the three sources, so each shows when the cap is hit, and are dropped whole."""
    one = lambda name, first: ("- %s — %s" % (s.clean_line(name), s.clean_line(first)))[:SHELF_LINE]
    proj = [one(*k) for k in skills(os.path.join(project, ".claude", "skills"))]
    user = [one(*k) for k in skills(os.path.join(s.config_dir(), "skills"))]
    plug, counts = [], {}
    for name, path in sorted(enabled_plugins(s, project).items()):
        names = [s.clean_line(k[0]) for k in skills(os.path.join(path, "skills"))]
        if not names:
            continue
        line, shown = "- %s: " % s.clean_line(name), 0
        for k in names:
            rest = len(names) - shown - 1
            cand = line + (", " if shown else "") + k
            if len(cand) + (len(" +%d" % rest) if rest else 0) > PLUGIN_LINE:
                break
            line, shown = cand, shown + 1
        line += " +%d" % (len(names) - shown) if shown < len(names) else ""
        plug.append(line)
        counts[line] = len(names)
    if not (proj or user or plug):
        return ""
    sources = [("project", proj), ("user", user), ("plugins", plug)]
    title = "## Shelf index (skills you can invoke; plugin skills by name)"
    chosen, used, dropped = {k: [] for k, _ in sources}, len(title) + 1, 0
    reserve = 40                                         # room for the dropped-count line
    for r in range(max([len(l) for _, l in sources] + [0])):
        for k, l in sources:
            if r < len(l):
                if used + len(l[r]) + 1 + reserve <= SHELF_MAX:
                    chosen[k].append(l[r])
                    used += len(l[r]) + 1
                else:
                    dropped += counts.get(l[r], 1)
    lines = [title]
    for k, _ in sources:
        lines += chosen[k] if k == "plugins" else sorted(chosen[k])
    if dropped:
        lines.append("(%d more skill%s not listed)" % (dropped, "" if dropped == 1 else "s"))
    return "\n".join(lines) + "\n"


def units(text):
    """The length Claude Code counts a hook string in: UTF-16 code units, so an emoji or another character past U+FFFF is 2."""
    return len(text.encode("utf-16-le")) // 2


def cut(block, limit=BLOCK_MAX):
    """The hard cut at `limit` UTF-16 units (a backstop): whole lines, then one line naming the sections it cut lines of."""
    if units(block) <= limit:
        return block, 0
    keep, size = [], 0
    lines = block.splitlines(True)
    for l in lines:
        if size + units(l) > limit - 120:
            break
        keep.append(l)
        size += units(l)
    gone = len(block) - len("".join(keep))
    titles = {t for _, t in store().SECTIONS} | {store().DONE_TITLE}
    sections, here = [], None
    for i, l in enumerate(lines):
        m = re.match(r"## ([^\n(]{1,60})", l)
        here = (re.sub(r" v[0-9]+ · .*", "", m.group(1)).strip() if m
                else l.rstrip("\n") if l.rstrip("\n") in titles else here)
        if i >= len(keep) and here and here not in sections:
            sections.append(here)
    named = "[brain: cut %d characters%s]\n" % (gone, ": " + ", ".join(sections) if sections else "")
    if size + units(named) > limit:                 # many sections named: the count alone, never past the limit
        named = "[brain: cut %d characters]\n" % gone
    return "".join(keep) + named, gone


def sources_ok(source):
    """BRAIN_TEST_SOURCES (a comma list), honoured only with BRAIN_TEST=1: inject at those SessionStart sources only, and log
    nothing at the others. The B1 probe (tests/live/brain-probe.sh) keeps arm H's block out until SessionStart:compact, so both
    arms share every byte before the compaction. Unset, or without BRAIN_TEST=1: every source."""
    if os.environ.get("BRAIN_TEST") != "1":
        return True
    names = [x for x in os.environ.get("BRAIN_TEST_SOURCES", "").split(",") if x]
    return not names or source in names


def read_state(s, d):
    """The state, read under the store lock: a read between a write's line and its head would see a broken log (rc 5). When the
    lock stays held past LOCK_WAIT (a writer stuck), or the lock file cannot be opened (a read-only or full disk), the read goes
    on without it."""
    try:
        with s.locked(d, s.LOCK_WAIT):
            return s.load(d)[1]
    except s.Refused as e:
        if e.rc != 1:                               # 1: the lock was not free in time; anything else is the log's answer
            raise
    except OSError:
        pass
    return s.load(d)[1]


def start_file(d, sid, part):
    """The hand-over of one session's SessionStart string `part` (sessions or plan), in the project's state directory."""
    return os.path.join(d, "starts", "%s.%s.json" % (hashlib.sha256(sid.encode("utf-8")).hexdigest()[:32], part))


def hand_over(s, d, sid, hand):
    """Write one hand-over file per part (0600, atomic); old ones of other sessions are swept. Never raises: the other commands
    then render their own parts."""
    try:
        sd = os.path.join(d, "starts")
        if not os.path.isdir(sd):
            with contextlib.suppress(FileExistsError):
                os.mkdir(sd, 0o700)
        for p in PART_EVENTS.values():
            one = {k: v for k, v in hand.items() if k != "parts"}
            s._write_file(start_file(d, sid, p), s.dumps(dict(one, part=p, text=hand["parts"].get(p, ""))) + "\n")
        for name in os.listdir(sd):
            with contextlib.suppress(OSError):
                q = os.path.join(sd, name)
                if time.time() - os.lstat(q).st_mtime > 86400:
                    os.unlink(q)
    except OSError as e:
        sys.stderr.write("brain: strings 2 and 3 were not handed over: %s\n" % e.__class__.__name__)


def session_start(inp):
    s = store()
    project, d, rebound = resolve(inp)
    if not has_state(d):
        return
    source = str(inp.get("source") or "startup")
    if not sources_ok(source):
        return
    sid = inp.get("session_id")
    sid = sid if isinstance(sid, str) else ""
    head_line = ("# vibemaestro-brain — re-injected at SessionStart:%s; change it only with `brain op` / `brain owner` "
                 "(skill brain)\n" % s.clean_line(source)[:20])
    hand = {"session": sid, "source": source, "t": T_START, "parts": {}}
    for p in PART_EVENTS.values() if sid else ():  # an earlier SessionStart's leftovers: never this one's strings
        with contextlib.suppress(OSError):
            os.unlink(start_file(d, sid, p))
    try:
        try:
            st = read_state(s, d)
            parts = s.render_parts(st)
        except s.Refused as e:
            hand["error"] = "refused"               # strings 2 and 3 read the log themselves, and stay silent if it refuses them too
            warn = "brain: hot memory was not injected: %s; run `brain doctor`" % s.printable(e.msg)
            emit("SessionStart", additionalContext=warn)
            sys.stderr.write(warn + "\n")
            return
        import brain_stale
        parts, stale, did, st = brain_stale.annotate(parts, st, d, sid or None)
        block, gone = cut(head_line + parts["hot"] + "\n" + shelf_index(s, project))
        more = {p: cut(parts[p], s.STRING_MAX) if p in did["noted"] or not s.part_empty(st, p) else ("", 0)
                for p in ("sessions", "plan")}
        hand["parts"] = {p: more[p][0] for p in more}
    except BaseException:
        hand["error"] = "failed"                    # the other commands render their own parts
        raise
    finally:
        if sid:                                     # a hand-over is matched by session: none without an id
            hand_over(s, d, sid, hand)
    emit("SessionStart", additionalContext=block)
    if did["closed"]:
        episode(d, inp, "auto-close", hook="SessionStart", ids=[i for i, _ in did["closed"]],
                anchors=[a["anchor"] for _, an in did["closed"] for a in an])
    fields = {"source": source, "transcript": inp.get("transcript_path"), "injected": len(block), "cut": gone, "stale": stale,
              "format": s.FORMAT, "injected_sessions": len(more["sessions"][0]), "cut_sessions": more["sessions"][1],
              "injected_plan": len(more["plan"][0]), "cut_plan": more["plan"][1]}
    fields.update({k: v for k, v in (("closed", len(did["closed"])), ("held", did["held"])) if v})
    if rebound:
        fields["rebound_from"] = rebound
    if source in ("resume", "fork"):
        fields.update({k: inp[k] for k in ("context_tokens", "prompt_cache_likely_expired", "estimated_cache_write_usd")
                       if k in inp})
    episode(d, inp, "session-start", **fields)


def taken_over(d, sid, source, part):
    """The hand-over of `part` string 1's command wrote for this SessionStart (same session and source, started within SIBLINGS
    seconds of this command), waiting up to START_WAIT seconds for it, and deleted once read: an earlier SessionStart's was
    taken by its own command. None when none came."""
    p, end = start_file(d, sid, part), T_START + START_WAIT
    while True:
        try:
            with open(p, encoding="utf-8") as f:
                h = json.loads(f.read())
            t = h.get("t") if isinstance(h, dict) else None
            if (h.get("session") == sid and h.get("source") == source and isinstance(t, (int, float))
                    and not isinstance(t, bool) and abs(t - T_START) <= SIBLINGS and isinstance(h.get("text"), str)):
                with contextlib.suppress(OSError):
                    os.unlink(p)
                return h
        except (OSError, ValueError, AttributeError):
            pass
        if time.time() >= end:
            return None
        time.sleep(0.005 if time.time() < T_START + 0.5 else 0.05)   # string 1 usually hands over within half a second


def session_part(inp, part):
    """String 2 or 3: string 1's hand-over for this SessionStart, else this part rendered here from the log, without lookups."""
    s = store()
    _, d, _ = resolve(inp, record=False)            # string 1's command records the session
    if not has_state(d):
        return
    source = str(inp.get("source") or "startup")
    if not sources_ok(source):
        return
    sid = inp.get("session_id")
    sid = sid if isinstance(sid, str) else ""
    sd = os.path.join(d, "starts")
    waits = bool(sid) and (os.access(sd, os.W_OK | os.X_OK) if os.path.isdir(sd) else not os.path.lexists(sd))   # else no place
    h = taken_over(d, sid, source, part) if waits else None
    if h is not None and not h.get("error"):
        text = h["text"]
    else:
        try:
            st = read_state(s, d)
        except s.Refused as e:
            if h is None or h.get("error") != "refused":            # string 1 has not said it already
                emit("SessionStart", additionalContext="brain: the %s string was not injected: %s; run `brain doctor`"
                     % (part, s.printable(e.msg)))
            return
        text = "" if s.part_empty(st, part) else cut(s.render_part(st, part) + "stale-anchor check: skipped (string 1 handed "
                                                                               "nothing over)\n", s.STRING_MAX)[0]
    if text:
        emit("SessionStart", additionalContext=text)


# --- PreCompact, PostCompact, SessionEnd ----------------------------------------------------------------------------------------

def last_context(path):
    """S1: input + cache-read + cache-write tokens of the last `usage` in the transcript's tail; None when not found."""
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - TAIL_BYTES))
            data = f.read()
    except (OSError, TypeError):
        return None
    for line in reversed(data.split(b"\n")):
        if b'"usage"' not in line:
            continue
        try:
            o = json.loads(line)
        except ValueError:
            continue
        u = (o.get("message") or {}).get("usage") if isinstance(o, dict) and isinstance(o.get("message"), dict) else None
        if isinstance(u, dict):
            return sum(int(u.get(k) or 0) for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
    return None


def hot_version(s, d):
    h = s.read_head(d)
    return h["seq"] if h else 0


def pre_compact(inp):
    s = store()
    d = resolve(inp)[1]
    if not has_state(d):
        return
    episode(d, inp, "pre-compact", trigger=inp.get("trigger"), context_before=last_context(inp.get("transcript_path")),
            hot_version=hot_version(s, d))
    sid, tr = inp.get("session_id"), inp.get("transcript_path")
    if isinstance(sid, str) and sid and isinstance(tr, str) and os.path.isabs(tr):
        import brain_cost
        brain_cost.update(d, sid, tr, s._write_file)


def anchor_found(anchor, text):
    a = re.escape(anchor)
    pat = ("(?<!\\w)" if re.match(r"\w", anchor) else "") + a + ("(?!\\w)" if re.search(r"\w$", anchor) else "")
    return re.search(pat, text, re.I) is not None


def loss_score(st, summary):
    anchors = sorted({a for it in st["items"].values() if it.get("status") == "live" for a in it.get("anchors") or []})
    if not anchors or summary is None:
        return None
    found = sum(1 for a in anchors if anchor_found(a, summary))
    return round(1 - found / len(anchors), 4)


def tail_lines(path, nbytes=65536):
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - nbytes))
            return f.read().split(b"\n")
    except OSError:
        return []


def post_compact(inp):
    s = store()
    d = resolve(inp)[1]
    if not has_state(d):
        return
    trigger = re.sub(r"[^a-z]", "", str(inp.get("trigger") or "unknown"))[:10] or "unknown"
    summary = inp.get("compact_summary")
    rel = None
    if isinstance(summary, str):
        sd = os.path.join(d, "summaries")
        if not os.path.isdir(sd):
            os.mkdir(sd, 0o700)
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        name, n = "%s-%s.md" % (stamp, trigger), 1
        while os.path.exists(os.path.join(sd, name)):
            n += 1
            name = "%s-%s-%d.md" % (stamp, trigger, n)
        s._write_file(os.path.join(sd, name), summary)
        rel = "summaries/" + name
        for old in sorted(glob.glob(os.path.join(sd, "*.md")))[:-SUMMARIES_KEPT]:
            with contextlib.suppress(OSError):
                os.unlink(old)
    else:
        summary = None
    try:
        _, st = s.load(d)
        loss = loss_score(st, summary)
    except s.Refused:
        loss = None
    before = None
    for b in reversed(tail_lines(os.path.join(d, "episodes.jsonl"))):
        try:
            o = json.loads(b)
        except ValueError:
            continue
        if isinstance(o, dict) and o.get("kind") == "pre-compact" and o.get("session") == (inp.get("session_id") or None):
            before = o.get("context_before")
            break
    episode(d, inp, "compact", trigger=trigger, context_before=before, summary=rel, loss=loss, hot_version=hot_version(s, d))


def session_end(inp):
    s = store()
    sid = inp.get("session_id")
    if sid:
        clear_pending(s, sid)                       # the record of the marker's own project, whatever this cwd (round 2)
    try:
        d = resolve(inp)[1]
    finally:
        if sid and inp.get("reason") not in ("clear", "resume"):  # the record lives as long as the session; after
            s.drop_session(sid)                     # /clear or a switch the Bash environment may still carry this id
    if not os.path.isdir(d):
        return
    if sid:
        s.void_records(d, sid)
        for p in PART_EVENTS.values():
            with contextlib.suppress(OSError):
                os.unlink(start_file(d, sid, p))
    episode(d, inp, "session-end", reason=inp.get("reason"))
    cost_line(s, d, inp)                            # the episode's last line (the parent spec's hook map)


def cost_line(s, d, inp):
    """The `cost` episode line from the sums pre-compact saved; none when this session never compacted."""
    sid = inp.get("session_id")
    if not (isinstance(sid, str) and sid):
        return
    import brain_cost
    r, fresh = brain_cost.cached_report(d, sid)
    if r is None or not fresh:
        return                                      # never compacted, or nothing new since this session's last cost line
    episode(d, inp, "cost", **{k: r[k] for k in ("calls", "tokens", "units", "split", "context_mean", "context_max",
                                                  "through")})
    brain_cost.mark_reported(d, sid, s._write_file)


# --- guards ---------------------------------------------------------------------------------------------------------------------

def command_of(inp):
    ti = inp.get("tool_input")
    c = ti.get("command") if isinstance(ti, dict) else None
    return c if isinstance(c, str) else ""


def guard_bash(inp):
    if not inp.get("agent_id"):
        return
    cmd = command_of(inp)
    if "brain" not in cmd:
        return
    for text, _ in segments(cmd):
        ws = words(text) or text.split()
        if any(is_brain(w) and ws[i + 1:i + 2] == ["op"] for i, w in enumerate(ws)):
            decide("deny", "brain: hot memory is written by the main session only; report back, and the main session runs "
                           "`brain op`")
            return


def guard_edit(inp):
    ti = inp.get("tool_input")
    if not isinstance(ti, dict):
        return
    p = ti.get("file_path") or ti.get("notebook_path")
    if not isinstance(p, str) or not p:
        return
    s = store()
    full = os.path.realpath(os.path.join(cwd_of(inp), os.path.expanduser(p)))
    for root in {s.state_root(), os.path.realpath(s.state_root())}:
        if full == root or full.startswith(root.rstrip(os.sep) + os.sep):
            decide("deny", "brain: the state directory is changed only through `brain op` and `brain owner` (skill brain); "
                           "an edit would break the hash chain and stop all writes")
            return


def version_ok():
    """The running Claude Code is 2.1.211 or later: `$CLAUDE_CODE_EXECPATH --version`, else `claude --version`; unknown → no."""
    exe = os.environ.get("CLAUDE_CODE_EXECPATH", "")
    exe = exe if os.path.isabs(exe) else "claude"
    try:
        out = subprocess.run([exe, "--version"], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return False
    v = store()._version_tuple(out)
    return v is not None and v >= VERSION_FLOOR


def ask_modes():
    """The test-only modes guard-owner also asks in: TEST_ASK_MODES named in BRAIN_TEST_ASK_MODES, under BRAIN_TEST=1. The
    record keeps the real mode and the store's dialog modes do not change, so the CLI refuses such a record."""
    if os.environ.get("BRAIN_TEST") != "1":
        return []
    dialog = store().DIALOG_MODES
    return [m for m in os.environ.get("BRAIN_TEST_ASK_MODES", "").split(",") if m in TEST_ASK_MODES and m not in dialog]


def parse_owner(args):
    """(verb, ns) as `brain owner` parses `args`, or raises Refused with the CLI's own message."""
    s = store()
    import brain
    brain.owner_grammar(args)
    err = io.StringIO()
    try:
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(err):   # `--help` prints to stdout (round 1)
            ns = brain.parser().parse_args(["owner"] + brain.owner_argv(args))
    except SystemExit:
        msg = [l for l in err.getvalue().splitlines() if l.startswith("brain: ")]
        raise s.Refused(64, (msg[-1][len("brain: "):] if msg else "brain owner: usage"))
    s.owner_check(ns.verb, ns)
    return ns.verb, ns


def dialog_line(s, ns, st):
    """The one line of the dialog. Every field the session wrote is quoted, the source (or pointer) before the text, and the
    store refuses `"` in them, so no field can end its quotes and imitate another (round 4: a label blocklist could not keep
    up with look-alike letters and colons)."""
    if ns.verb == "add":
        letter = s.KINDS[ns.kind]
        iid = s.next_id(st, letter)
        if letter == "D":
            return 'Pin owner decision %s, from "%s": "%s"' % (iid, ns.where, ns.text)
        ts = s.parse_iso(ns.expires)
        until = s.now_iso(ts)[5:16].replace("T", " ") + "Z"
        return 'Grant window %s until %s, from "%s": "%s"' % (iid, until, ns.where, ns.text)
    it = s.get_live(st, ns.id, s.OWNER_LETTERS)
    noun = "decision" if ns.id[0] == "D" else "window"
    text = s.clean_line(it["text"])
    if ns.verb == "unpin":
        return 'Unpin owner %s %s: "%s"' % (noun, ns.id, text)
    if ns.verb == "supersede":
        return 'Replace %s with: "%s"' % (ns.id, ns.text)
    return 'Promote owner %s %s to "%s": "%s"' % (noun, ns.id, ns.pointer, text)


def pending_marker(sid):
    return os.path.join(pending_dir(), hashlib.sha256(sid.encode("utf-8")).hexdigest()[:32])


def clear_pending(s, sid):
    """Void the record a session's last ask left, and its marker: a record serves only the call it was asked for, so the
    session's next Bash call of any shape (an `eval`, a `bash -c`, a symlink to brain) finds none (round 1, residual risk 5)."""
    m = pending_marker(sid)
    try:
        with open(m, encoding="utf-8") as f:
            d = f.read().strip()
    except OSError:
        return
    root = os.path.realpath(s.state_root())
    if os.path.realpath(d).startswith(root + os.sep):
        s.void_records(d, sid)
    with contextlib.suppress(OSError):
        os.unlink(m)


def mark_pending(s, sid, d):
    pd = pending_dir()
    s.ensure_dir(d)
    if not os.path.isdir(pd):
        with contextlib.suppress(FileExistsError):
            os.mkdir(pd, 0o700)
    s._write_file(pending_marker(sid), d + "\n")


def guard_owner(inp):
    cmd = command_of(inp)
    sid = inp.get("session_id") or ""
    if sid:
        clear_pending(store(), sid)
    if "owner" not in cmd or "brain" not in cmd:
        return
    found, segs = [], segments(cmd, heredoc=True)
    for text, flags in segs:
        ws = words(text)
        if ws is None:
            if owner_tokens(lead_words(text)) is not None:      # a brain call at the start, not the words anywhere
                found.append((None, flags | {"open"}))
            continue
        toks = owner_tokens(ws)
        if toks is not None:
            found.append((toks, flags))
    if not found:
        return
    s = store()
    project, d, _ = resolve(inp)                    # the project `brain owner` will write to, whatever the shell's directory
    mode = str(inp.get("permission_mode") or "unknown")
    log = {"mode": mode}

    def deny(reason, why):
        decide("deny", "brain: " + reason)
        with contextlib.suppress(Exception):
            episode(d, inp, "owner-call", decision="deny", why=why, **log)

    if sid:
        s.void_records(d, sid)                 # every recognised call voids the session's earlier unused records
    if inp.get("agent_id"):
        return deny("owner items come from the main session only; a subagent reports the owner's words back", "subagent")
    if len(found) > 1 or len(segs) > 1 or found[0][0] is None or found[0][1]:
        return deny(LITERAL, "not-literal")         # alone: a `cd x &&` before it would run the CLI in another project
    args = found[0][0]
    try:
        verb, ns = parse_owner(args)
    except s.Refused as e:
        return deny(s.printable(e.msg), "usage")
    log["verb"] = verb
    if not sid:
        return deny("no session id in the hook input; owner items need a Claude Code session", "no-session")
    dialog = mode in ("default", "acceptEdits") or (mode == "auto" and version_ok()) or mode in ask_modes()
    if not dialog:
        return deny(s.NO_DIALOG, "no-dialog")
    ans = s.answerers(s.project_root(project))
    if ans:
        return deny("owner items are refused while something can answer the permission prompt in place of a human: "
                    + s.printable("; ".join(ans)), "answerer")
    try:
        _, st = s.load(d) if has_state(d) else (None, s.empty_state())
        line = dialog_line(s, ns, st)
    except s.Refused as e:
        return deny(s.printable(e.msg), "state")
    mark_pending(s, sid, d)                         # first: a marker with no record is harmless, a record with none is not
    rid = s.record_asked(d, sid, mode, args)
    try:
        decide("ask", line)
    except Exception:
        s.void_records(d, sid)
        raise
    with contextlib.suppress(Exception):
        episode(d, inp, "owner-call", decision="ask", record=rid, **log)


def update_check(inp):
    """sdlc's update reminder for brain (brain depends on sdlc): its root is brain's, so the line, the read and the cache are
    brain's own. No sdlc found: nothing."""
    import importlib.util
    import brain_store as s
    f = s.sdlc_file(os.path.join("scripts", "update_check.py"))
    if not f:
        return
    try:
        spec = importlib.util.spec_from_file_location("vibemaestro_update_check", f)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        mod.session_start(os.path.dirname(HERE))
    except Exception:  # noqa: BLE001 — the reminder is silent on any error, as in sdlc's own entry
        pass


HANDLERS = {"session-start": session_start, "session-start-sessions": lambda inp: session_part(inp, "sessions"),
            "session-start-plan": lambda inp: session_part(inp, "plan"), "pre-compact": pre_compact, "post-compact": post_compact,
            "session-end": session_end, "guard-bash": guard_bash, "guard-edit": guard_edit, "guard-owner": guard_owner,
            "update-check": update_check}


def main(argv):
    event = argv[1] if len(argv) > 1 else ""
    if event not in HANDLERS or off():
        return 0
    try:
        inp = json.loads(_RAW) if _RAW is not None else json.load(sys.stdin)
    except ValueError:
        return 0
    if not isinstance(inp, dict):
        return 0
    try:
        HANDLERS[event](inp)
    except Exception as e:  # noqa: BLE001 — fail-open: a hook error must never block the session
        sys.stderr.write("brain hook %s: %s: %s\n" % (event, e.__class__.__name__, str(e)[:200]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
