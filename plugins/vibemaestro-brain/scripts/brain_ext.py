"""vibemaestro-brain extensions: what another plugin adds to the brain through one declared script.

An extension is an enabled plugin that depends on vibemaestro-brain and ships `brain-extension.json` at its root
(brain_store.extension_roots finds it). Its manifest declares one script, the `brain op` writes the script checks (and the
options it adds to them), the owner verbs it adds (each one of brain's own two owner writes, through brain's dialog: `pin` a
decision, `archive` an item to a pointer), and the calls it answers: `start` (lines at SessionStart and on the review card),
`record` (a section of `brain ledger --record`) and `read` (`brain ext NAME`).

Brain runs the script in its own process (`python -I -B`, the plugin root as its directory), one JSON object in on stdin and
one out on stdout, under a time cap and a budget for the whole event, with no session id and an empty XDG_STATE_HOME. The
extension never writes: brain checks what comes back (characters, lengths, the sensitive-value filter) and writes it, under
`ext.<name>` of an item or an op, through its own write paths. Every call runs under the store lock, and whatever it changed
in the log, its head, the caches, the owner records or the session's SessionStart hand-over files is undone (the caches it
changed are dropped). A missing, broken or slow
extension is skipped with one line. A brain with no extension never imports this module. Standard library only.
"""
import contextlib
import hashlib
import json
import math
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

import brain_store as s

SCHEMA = 1
MANIFEST_MAX = 16 * 1024                            # bytes of brain-extension.json
OUT_MAX = 64 * 1024                                 # bytes of one answer
DATA_MAX, DATA_DEPTH = 2048, 4                      # an answer's `data`: bytes as stored, levels
HOOK_SECONDS, CLI_SECONDS = 1.0, 3.0                # an answer's time cap in a hook, in the CLI
HOOK_BUDGET, CLI_BUDGET = 2.0, 6.0                  # what every extension of one event may take together, in a hook, in the CLI
MIN_CALL = 0.2                                      # seconds a call needs at least: with less left, it is skipped
EXT_MAX = 4                                         # extensions read, by plugin id
NAME_RE = re.compile(r"[a-z][a-z0-9-]{1,23}")
OPTION_RE = re.compile(r"--[a-z][a-z0-9-]{1,23}")
VERB_RE = re.compile(r"[a-z][a-z-]{1,15}")
CHECK_VERBS = ("add", "supersede", "close", "held", "broke", "hit", "progress")
KIND_VERBS = ("add", "supersede", "close")
RIGHT_KINDS = ("now", "next", "trap", "session", "queue", "fact", "focus", "request")
CORE_OWNER = ("add", "unpin", "supersede", "promote", "import", "backup", "batch")
EFFECTS = ("pin", "archive")
ARCHIVE_LETTERS = ("G", "D", "W", "T", "F")
CALLS = ("start", "record", "read")
KEYS = ("schema", "name", "script", "checks", "owner", "calls")
OPTIONS_MAX, ARGS_MAX = 4, 2
# brain's own options of each verb an extension may check: it adds none of them, but may take one of CLAIMABLE for the kinds
# brain does not use it on (a focus's --goal, a Next item's --focus, a request's --due)
BRAIN_OPTIONS = {"add": ("--kind", "--text", "--expires", "--link", "--anchor", "--closes", "--owner-quote", "--where", "--goal",
                         "--focus", "--due"),
                 "supersede": ("--text", "--reason", "--drop-anchor", "--anchor", "--closes", "--focus", "--due", "--shorter",
                               "--bulk"),
                 "close": ("--reason", "--pointer", "--bulk"), "held": ("--pointer", "--session"),
                 "broke": ("--pointer", "--differed", "--session"), "hit": ("--pointer", "--session"),
                 "progress": ("--measure", "--pointer")}
CLAIMABLE = {("add", "--goal"): ("focus",), ("add", "--focus"): ("next",), ("add", "--due"): ("request",),
             ("supersede", "--focus"): ("next",), ("supersede", "--due"): ("request",)}
LINES = {"start": (5, 200), "record": (60, 300), "read": (200, 400)}   # lines of an answer, UTF-16 units of each
NOTE_LINES, NOTE_LINE = 12, 300
DETAIL_MAX, MESSAGE_MAX = 120, 300
OPTION_MAX, ARG_MAX, READ_ARGS, READ_ARG = 300, 80, 8, 200
WATCHED = ("hot.jsonl", "head.json", "hot.json", "archive.jsonl", "owner.json", "hot.md")
SKIP_SHOWN = 86400                                  # seconds doctor shows the Episode Log's last skip of an extension
SKIP_TAIL = 256 * 1024                              # bytes of the Episode Log doctor reads for them
WARNINGS = []                                       # what the CLI prints on stderr after the command (a check that did not run)
_FOUND = {}
ABSENT = object()


class Broken(Exception):
    """An extension's manifest or answer that breaks a rule: the extension is skipped, for this reason (`str`). `detail`, the
    last line its script wrote on stderr, goes to the Episode Log and doctor only, never into a string the session reads."""

    def __init__(self, why, detail=None):
        Exception.__init__(self, why)
        self.detail = detail


def label(x, n=60):
    """A value of the registry or a manifest, shown in a line: its bad characters dropped, cut to `n` units."""
    return s.cut_units(s.clean_line(str(x)), n)


# --- the manifest -------------------------------------------------------------------------------------------------------------

def _list(m, key):
    v = m.get(key, [])
    if not isinstance(v, list) or not all(isinstance(x, dict) for x in v):
        raise Broken("%s is not a list of objects" % key)
    return v


def _check(c):
    verb = c.get("verb")
    if verb not in CHECK_VERBS:
        raise Broken("a check's verb is not one of %s" % ", ".join(CHECK_VERBS))
    kinds = c.get("kinds")
    if kinds is not None:
        if verb not in KIND_VERBS or not isinstance(kinds, list) or not kinds or not all(k in RIGHT_KINDS for k in kinds):
            raise Broken("the kinds of check %s are not a list of right-brain kinds (and only add, supersede and close take "
                         "kinds)" % verb)
        kinds = tuple(sorted(set(kinds)))
    opts = c.get("options", [])
    if (not isinstance(opts, list) or not all(isinstance(o, str) and OPTION_RE.fullmatch(o) and o != "--help" for o in opts)
            or len(opts) > OPTIONS_MAX or len(set(opts)) != len(opts)):
        raise Broken("the options of check %s are not up to %d distinct --names" % (verb, OPTIONS_MAX))
    for o in opts:
        if o in BRAIN_OPTIONS[verb]:
            mine = CLAIMABLE.get((verb, o))
            if mine is None or kinds is None or set(kinds) & set(mine):
                raise Broken("check %s takes brain's own option %s%s" % (
                    verb, o, " for a kind brain uses it on (%s)" % ", ".join(mine) if mine else ""))
    unknown = sorted(set(c) - {"verb", "kinds", "options"})
    if unknown:
        raise Broken("check %s has the unknown key %s" % (verb, label(unknown[0], 30)))
    return {"verb": verb, "kinds": kinds, "options": tuple(opts)}


def _owner(o):
    verb, effect = o.get("verb"), o.get("effect")
    if not isinstance(verb, str) or not VERB_RE.fullmatch(verb) or verb in CORE_OWNER:
        raise Broken("an owner verb is not [a-z][a-z-]{1,15}, or is brain's own (%s)" % ", ".join(CORE_OWNER))
    if effect not in EFFECTS:
        raise Broken("owner verb %s: the effect is not pin or archive" % verb)
    args, letters = o.get("args", []), o.get("letters")
    if effect == "pin":
        if (letters is not None or not isinstance(args, list) or not all(isinstance(a, str) and NAME_RE.fullmatch(a) for a in args)
                or len(args) > ARGS_MAX or len(set(args)) != len(args)):
            raise Broken("owner verb %s (pin) takes up to %d named args and no letters" % (verb, ARGS_MAX))
    elif ("args" in o or not isinstance(letters, list) or not letters or not all(l in ARCHIVE_LETTERS for l in letters)
          or len(set(letters)) != len(letters)):
        raise Broken("owner verb %s (archive) takes letters from %s and no args" % (verb, " ".join(ARCHIVE_LETTERS)))
    unknown = sorted(set(o) - {"verb", "effect", "args", "letters"})
    if unknown:
        raise Broken("owner verb %s has the unknown key %s" % (verb, label(unknown[0], 30)))
    return verb, {"effect": effect, "args": tuple(args) if effect == "pin" else (), "letters": tuple(letters or ())}


def manifest(pid, root):
    """The checked manifest of the plugin `pid` at its real `root`; raises Broken naming the rule it breaks."""
    m = s.json_capped(os.path.join(root, s.EXT_MARKER), MANIFEST_MAX, follow=False)
    if not isinstance(m, dict):
        raise Broken("%s is not one JSON object of at most %d bytes" % (s.EXT_MARKER, MANIFEST_MAX))
    if m.get("schema") != SCHEMA:
        raise Broken("schema is not %d" % SCHEMA)
    name, script = m.get("name"), m.get("script")
    if not isinstance(name, str) or not NAME_RE.fullmatch(name):
        raise Broken("name is not [a-z][a-z0-9-]{1,23}")
    if not isinstance(script, str) or not script.endswith(".py") or os.path.isabs(script) or "\0" in script:
        raise Broken("script is not a .py path relative to the plugin root")
    real = os.path.realpath(os.path.join(root, script))
    if not s.inside(real, root) or s.plain(real) != "file":
        raise Broken("script %s is not a regular file inside the plugin root" % label(script, 40))
    checks = [_check(c) for c in _list(m, "checks")]
    kinds_of = {}
    for c in checks:
        kinds_of.setdefault(c["verb"], []).extend(c["kinds"] or ("*",))
    if any(len(ks) != len(set(ks)) or "*" in ks and len(ks) > 1 for ks in kinds_of.values()):
        raise Broken("a verb is checked twice for one kind: one check per verb, or per verb and kind")
    owner = {}
    for o in _list(m, "owner"):
        verb, spec = _owner(o)
        if verb in owner:
            raise Broken("owner verb %s is declared twice" % verb)
        owner[verb] = spec
    calls = m.get("calls", [])
    if not isinstance(calls, list) or not all(c in CALLS for c in calls):
        raise Broken("calls is not a list of %s" % ", ".join(CALLS))
    return {"name": name, "id": pid, "root": root, "script": real, "checks": checks, "owner": owner, "calls": tuple(calls),
            "unknown": sorted(k for k in m if k not in KEYS)}


def _clashes(exts):
    """{plugin id: why} of the extensions that clash with another: a name, an owner verb, or an option of the same verb for a
    kind both check."""
    out = {}
    for i, a in enumerate(exts):
        for b in exts[i + 1:]:
            why = None
            if a["name"] == b["name"]:
                why = "the name %s is also %s's" % (a["name"], "%s")
            elif set(a["owner"]) & set(b["owner"]):
                why = "owner verb %s is also %s's" % (sorted(set(a["owner"]) & set(b["owner"]))[0], "%s")
            else:
                for ca in a["checks"]:
                    for cb in b["checks"]:
                        both = set(ca["options"]) & set(cb["options"])
                        if ca["verb"] == cb["verb"] and both and (ca["kinds"] is None or cb["kinds"] is None
                                                                  or set(ca["kinds"]) & set(cb["kinds"])):
                            why = "option %s of %s is also %s's" % (sorted(both)[0], ca["verb"], "%s")
            if why:
                out.setdefault(a["id"], why % b["id"])
                out.setdefault(b["id"], why % a["id"])
    return out


def _key(project):
    return os.path.realpath(project or s.session_project())


def found(project=None):
    """The extensions of the session's project, checked; the skipped ones are in notes(). Read once per process."""
    key = _key(project)
    if key not in _FOUND:
        exts, gone = [], []
        for i, (pid, root) in enumerate(s.extension_roots(project)):
            if i >= EXT_MAX:
                gone.append(("extension of %s" % label(pid), "more than %d extensions are enabled" % EXT_MAX))
                continue
            try:
                exts.append(manifest(pid, root))
            except Broken as e:
                gone.append(("extension of %s" % label(pid), str(e)))
            except Exception as e:  # noqa: BLE001 — a manifest no rule foresaw: skipped, never the brain's failure
                gone.append(("extension of %s" % label(pid), "its manifest cannot be read (%s)" % e.__class__.__name__))
        clash = _clashes(exts)
        gone += [("extension %s of %s" % (e["name"], label(e["id"])), label(clash[e["id"]], 200)) for e in exts if e["id"] in clash]
        notes = [("warn", "%s skipped: %s" % g) for g in gone]
        WARNINGS.extend("%s skipped: %s" % g for g in gone)      # a write says so: a check it declared does not run
        notes += [("warn", "extension %s: unknown key %s in %s (ignored)" % (e["name"], label(e["unknown"][0], 30), s.EXT_MARKER))
                  for e in exts if e["unknown"] and e["id"] not in clash]
        _FOUND[key] = ([e for e in exts if e["id"] not in clash], notes, gone)
    return _FOUND[key][0]


def notes(project=None):
    """Doctor's lines on the extensions found: [(level, text)]."""
    found(project)
    return _FOUND[_key(project)][1]


def named(name, project=None):
    for e in found(project):
        if e["name"] == name:
            return e
    return None


def owner_verb(verb, project=None):
    """(extension, its spec of the owner verb `verb`), or (None, None)."""
    for e in found(project):
        if verb in e["owner"]:
            return e, e["owner"][verb]
    return None, None


def option_names(verb, project=None):
    """The options extensions add to `brain op VERB` that brain's parser does not have."""
    return sorted({o for e in found(project) for c in e["checks"] if c["verb"] == verb for o in c["options"]
                   if o not in BRAIN_OPTIONS[verb]})


def route(verb, kind, given, project=None):
    """{(extension name, option): value} for the options of `brain op VERB` given for `kind` (`given`: {option: value}, None
    when not given); refused (64) for an option no extension takes for that kind."""
    out = {}
    for o, v in sorted(given.items()):
        if v is None:
            continue
        owners = [e["name"] for e in found(project) for c in e["checks"]
                  if c["verb"] == verb and o in c["options"] and (c["kinds"] is None or kind in c["kinds"])]
        if not owners:
            kinds = sorted({k for e in found(project) for c in e["checks"] if c["verb"] == verb and o in c["options"]
                            for k in (c["kinds"] or ("any",))})
            raise s.Refused(64, "%s is not an option of %s %s%s" % (o, verb, kind or "", " (it is for: %s)" % ", ".join(kinds)
                                                                   if kinds else ""))
        s.check_text("option", v, cap=OPTION_MAX)
        out[(owners[0], o)] = v
    return out


def claimed(verb, kind, option, project=None):
    """An extension takes brain's own `option` of `brain op VERB` for `kind`."""
    return any(c["verb"] == verb and option in c["options"] and c["kinds"] is not None and kind in c["kinds"]
               for e in found(project) for c in e["checks"])


def checks(verb, kind, project=None):
    """The extensions that check `brain op VERB` of `kind`, each once."""
    return [e for e in found(project) if any(c["verb"] == verb and (c["kinds"] is None or kind in c["kinds"])
                                             for c in e["checks"])]


# --- one call -----------------------------------------------------------------------------------------------------------------

def payload(ext, call, st, ops, **fields):
    """The input of one call: what every call carries, then the call's own fields; `ops` None for a start without a card."""
    c = s.conf()
    out = {"schema": SCHEMA, "call": call, "extension": ext["name"], "now": time.time(),
           "project": os.path.basename(s.config_root().rstrip(os.sep)) or "project",
           "config": {"ledger": dict(c["ledger"]), "caps": {l: s.cap(l) for l in sorted(s.CAPS)}}, "state": st}
    if ops is not None:
        out["ops"] = ops
    out.update(fields)
    return out


class Budget(object):
    """The time all extensions of one event may take together: each call gets its cap or what is left, whichever is less."""

    def __init__(self, total):
        self.total, self.end = total, time.monotonic() + total

    def take(self, cap):
        left = self.end - time.monotonic()
        if left < MIN_CALL:
            raise Broken("no time left for it in this event (%g s for every extension together)" % self.total)
        return min(cap, left)


def own_starts(session):
    """The name its SessionStart hand-over files start with (brain_hook.start_file), "" for no session."""
    return hashlib.sha256(session.encode("utf-8")).hexdigest()[:32] + "." if session else ""


def watch(d, session):
    """What a call must not change: the log, its head and the caches (each name with its size, time and inode), the owner
    records' names, and this session's SessionStart hand-over files (another session's string 1 writes its own without the
    lock, at any time)."""
    files = {}
    for n in WATCHED:
        try:
            x = os.lstat(os.path.join(d, n))
            files[n] = (x.st_size, x.st_mtime_ns, x.st_ino)
        except OSError:
            files[n] = None
    try:
        asked = frozenset(os.listdir(os.path.join(d, "asked")))
    except OSError:
        asked = frozenset()
    starts, mine = {}, own_starts(session)
    try:
        for n in os.listdir(os.path.join(d, "starts")) if mine else ():
            if n.startswith(mine):
                with contextlib.suppress(OSError):
                    x = os.lstat(os.path.join(d, "starts", n))
                    starts[n] = (x.st_size, x.st_mtime_ns, x.st_ino)
    except OSError:
        pass
    return files, asked, starts


def made(before, after):
    """What a call made in the state directory: (the log, head and cache files it changed; owner records that appeared;
    hand-over files that appeared or changed). A record or a hand-over file that went is not the call's: guard-owner voids
    records and SessionStart's commands take their hand-over files without the lock."""
    return ([n for n in WATCHED if before[0][n] != after[0][n]], sorted(after[1] - before[1]),
            sorted(n for n, v in after[2].items() if before[2].get(n) != v))


def _kill(p):
    """End the call's process group (whatever it left running in it) and collect it."""
    with contextlib.suppress(OSError):
        os.killpg(p.pid, signal.SIGKILL)
    with contextlib.suppress(subprocess.TimeoutExpired, OSError):
        p.wait(timeout=1)


def _pump(f, keep, cap, box):
    """Read the pipe `f` to its end in a thread, keeping its first `cap` bytes (`keep` "head") or its last (`keep` "tail")
    in box[0], so an answer or a stderr of any size costs at most `cap` bytes; box[1] is True once more came than kept."""
    try:
        while True:
            b = os.read(f.fileno(), 65536)
            if not b:
                break
            if keep == "head":
                room = cap - len(box[0])
                box[0] += b[:max(0, room)]
                box[1] = box[1] or len(b) > room
            else:
                box[0] = (box[0] + b)[-cap:]
    except (OSError, ValueError):
        pass


def _call(ext, raw, seconds):
    """(exit code, stdout's first OUT_MAX + 1 bytes, more than that came, stderr's last line) of one run of the script. Its
    input is a file, so no writer waits on a reader; its output and stderr are read by two threads, given half a second
    together after it ends (a child that left its process group may hold them open: what came so far is used)."""
    try:
        tmp = tempfile.mkdtemp(prefix="brain-ext-")
    except OSError as e:
        raise Broken("its input could not be handed over (%s)" % e.__class__.__name__)
    env = {k: v for k, v in os.environ.items() if k != "CLAUDE_CODE_SESSION_ID"}
    env.update({"BRAIN_EXTENSION": ext["name"], "XDG_STATE_HOME": tmp})
    out, err = [bytearray(), False], [bytearray(), False]
    try:
        try:
            fin = tempfile.TemporaryFile(buffering=0)     # unbuffered: a close never writes, so a failed write stays this one
        except OSError as e:
            raise Broken("its input could not be handed over (%s)" % e.__class__.__name__)
        with fin:
            try:
                view = memoryview(raw)
                while view:
                    view = view[fin.write(view):]
                fin.seek(0)
            except OSError as e:
                raise Broken("its input could not be handed over (%s)" % e.__class__.__name__)
            try:
                p = subprocess.Popen([sys.executable, "-I", "-B", ext["script"]], cwd=ext["root"], env=env, stdin=fin,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0, start_new_session=True)
            except OSError as e:
                raise Broken("its script did not start (%s)" % e.__class__.__name__)
        threads = [threading.Thread(target=_pump, args=(p.stdout, "head", OUT_MAX + 1, out)),
                   threading.Thread(target=_pump, args=(p.stderr, "tail", 4096, err))]
        for th in threads:
            th.daemon = True
            th.start()
        try:
            p.wait(timeout=seconds)
        except subprocess.TimeoutExpired:
            raise Broken("no answer within %g s" % round(seconds, 1))
        finally:
            _kill(p)
            end = time.monotonic() + 0.5
            for th in threads:
                th.join(timeout=max(0.0, end - time.monotonic()))
            for f in (p.stdout, p.stderr):
                with contextlib.suppress(OSError, ValueError):
                    f.close()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    last = (bytes(err[0]).decode("utf-8", "replace").strip().splitlines()[-1:] or [""])[0]
    return p.returncode, bytes(out[0]), out[1] or len(out[0]) > OUT_MAX, label(last, 120) or None


def _undo(d, log_size, head, caches):
    """Put the log and its head back as they were before a call: the lines it appended cut off (the log removed when there
    was none), head.json rewritten, and every cache it changed dropped (brain writes them again; the read cache is always
    dropped, so the next read folds the log). A change inside the old lines stays, and the chain refuses every write until
    it is gone, as for a hand edit."""
    p = os.path.join(d, "hot.jsonl")
    with contextlib.suppress(OSError):
        if log_size is None:
            if os.path.lexists(p):
                os.unlink(p)
        elif os.path.getsize(p) > log_size:
            with open(p, "r+b") as f:
                f.truncate(log_size)
                os.fsync(f.fileno())
    with contextlib.suppress(OSError):
        hp = os.path.join(d, "head.json")
        if head is None:
            if os.path.lexists(hp):
                os.unlink(hp)
        else:
            s._write_file(hp, head)
    for n in set(caches) | {"hot.json"}:
        if n not in ("hot.jsonl", "head.json"):
            with contextlib.suppress(OSError):
                os.unlink(os.path.join(d, n))


def _guarded(ext, data, seconds, d, locked, session):
    """The call under the store lock (`locked`: the caller holds it), the state directory watched around it: whatever it
    made there is undone, and the call fails (rc 5 for a write, else Broken)."""
    before = watch(d, session)
    try:
        log_size = os.path.getsize(os.path.join(d, "hot.jsonl"))
    except OSError:
        log_size = None
    try:
        with open(os.path.join(d, "head.json"), encoding="utf-8") as f:
            head = f.read()
    except OSError:
        head = None
    try:
        return _call(ext, s.dumps(data).encode("utf-8"), seconds)
    finally:
        changed, records, starts = made(before, watch(d, session))
        if changed or records or starts:
            _undo(d, log_size, head, changed)
            for sub, names in (("asked", records), ("starts", starts)):
                for n in names:
                    with contextlib.suppress(OSError):
                        os.unlink(os.path.join(d, sub, n))
            if locked:
                raise s.Refused(5, "extension %s changed the brain's state directory during its call: nothing was written, "
                                   "and what it changed is undone; run brain doctor" % ext["name"])
            raise Broken("it changed the brain's state directory during its call (undone)")


def run(ext, data, seconds, d=None, locked=False, session=None):
    """The answer (a dict) of the extension `ext` to the input `data`. Every call with a state directory `d` runs under the
    store lock (`locked`: the caller holds it already), so nothing else writes the log, its head, the caches or an owner
    record meanwhile; whatever the call changed there is undone. Raises Broken when the store stays busy, the script does not
    start, exits non-zero, runs past `seconds`, answers more than OUT_MAX bytes, or not one JSON object; Refused (5) when a
    call under the caller's lock changed the state directory. `session`: whose hand-over files are watched (default, the
    CLI's session). The wait for the lock, at most LOCK_WAIT, comes out of `seconds`."""
    t0 = time.monotonic()
    session = s.session_id() if session is None else session
    if d is None:
        rc, out, over, last = _call(ext, s.dumps(data).encode("utf-8"), seconds)
    elif locked:
        rc, out, over, last = _guarded(ext, data, seconds, d, True, session)
    else:
        with contextlib.ExitStack() as held:
            try:
                held.enter_context(s.locked(d, min(seconds, s.LOCK_WAIT)))
            except s.Refused as e:
                if e.rc != 1:
                    raise
                raise Broken("the brain's store is busy")
            except OSError as e:
                raise Broken("the store lock cannot be opened (%s)" % e.__class__.__name__)
            rc, out, over, last = _guarded(ext, data, max(MIN_CALL, seconds - (time.monotonic() - t0)), d, False, session)
    if over:
        raise Broken("its answer is over %d bytes" % OUT_MAX, last)
    if rc != 0:
        raise Broken("its script %s" % ("exited %d" % rc if rc > 0 else "was stopped by signal %d" % -rc), last)
    try:
        obj = json.loads(out.decode("utf-8"), parse_constant=_no_constant)
    except (ValueError, UnicodeDecodeError, RecursionError):
        obj = None
    if not isinstance(obj, dict):
        raise Broken("its answer is not one JSON object of standard JSON")
    return obj


def _no_constant(name):
    raise ValueError("%s is not standard JSON" % name)


def skipped(d, ext, call, why, session=None):
    """One Episode Log line for a skip (doctor shows the last one of each extension for a day): why, and the script's last
    stderr line unless the sensitive-value filter finds a value in it."""
    detail = getattr(why, "detail", None)
    with contextlib.suppress(Exception):
        if detail and withheld(d, [detail]):
            detail = "(its stderr line is withheld: a sensitive value)"
        s.episode_line(d, session if session is not None else s.session_id(), "extension-skip", extension=ext["name"],
                       call=call, why=str(why), **({"stderr": detail} if detail else {}))


# --- the answer's rules -------------------------------------------------------------------------------------------------------

def bad_text(v):
    """Why the string `v` breaks brain's character rules (as `check_text`), None when it keeps them."""
    if not isinstance(v, str):
        return "it is not a string"
    if any(s.is_bad(c) for c in v) or any(ord(c) in s.SELECTORS and not s.selector_fits(v, i) for i, c in enumerate(v)):
        return "it holds a control, format or invisible character"
    if s._marks_run(v) > s.MARKS_RUN_MAX:
        return "it stacks more than %d combining marks" % s.MARKS_RUN_MAX
    return None


def text_of(v, cap, what):
    why = bad_text(v)
    if why:
        raise Broken("its %s: %s" % (what, why))
    return s.cut_symbols(v, cap)


def lines_of(obj, call):
    """The answer's `lines`, each checked and cut; at most LINES[call][0] of them; blank lines left out."""
    lines = obj.get("lines", [])
    if not isinstance(lines, list):
        raise Broken("its lines are not a list")
    n, cap = LINES[call]
    out = [text_of(l, cap, "line") for l in lines]
    return [l for l in out if l.strip()][:n]


def strings(v, depth=0):
    """Every string of a JSON value (keys too), checked; raises Broken past DATA_DEPTH levels, on a bad character or on a
    number that is not finite."""
    if depth > DATA_DEPTH:
        raise Broken("its data is more than %d levels deep" % DATA_DEPTH)
    if isinstance(v, str):
        text_of(v, len(v) * 2 + 1, "data")
        return [v]
    if isinstance(v, list):
        return [x for i in v for x in strings(i, depth + 1)]
    if isinstance(v, dict):
        return [x for k, i in v.items() for x in strings(k, depth + 1) + strings(i, depth + 1)]
    if isinstance(v, float) and not math.isfinite(v):
        raise Broken("its data holds a number that is not finite")
    if v is None or isinstance(v, (bool, int, float)):
        return []
    raise Broken("its data holds a value that is not JSON")


def data_of(obj):
    """The answer's `data`: ABSENT when it has none, None to remove the extension's entry, else a checked object."""
    if "data" not in obj:
        return ABSENT
    v = obj["data"]
    if v is None:
        return None
    if not isinstance(v, dict):
        raise Broken("its data is not an object")
    strings(v)
    if len(s.dumps(v).encode("utf-8")) > DATA_MAX:
        raise Broken("its data is over %d bytes" % DATA_MAX)
    return v


def note_of(obj):
    note = obj.get("note")
    if note is None:
        return []
    if not isinstance(note, str):
        raise Broken("its note is not a string")
    lines = [text_of(l, NOTE_LINE, "note") for l in note.split("\n")]
    return [l for l in lines if l.strip()][:NOTE_LINES]


def refusal(obj, d, rcs=(1,)):
    """(rc, message) of the answer's `refuse`, None when it has none; a message the sensitive-value filter finds a value in
    is withheld."""
    r = obj.get("refuse")
    if r is None:
        return None
    rc = r.get("rc", rcs[0]) if isinstance(r, dict) else None
    if not isinstance(r, dict) or not isinstance(r.get("message"), str) or type(rc) is not int or rc not in rcs:
        raise Broken("its refuse is not {\"rc\": %s, \"message\": M}" % " or ".join(str(x) for x in rcs))
    msg = text_of(r["message"], MESSAGE_MAX, "message") or "refused"
    return rc, ("its message is withheld (a sensitive value)" if withheld(d, [msg]) else msg)


def withheld(d, texts):
    """True when the sensitive-value filter refuses one of `texts` (or cannot run): lines shown are then withheld."""
    try:
        s.sanitize(d, texts)
    except s.Refused:
        return True
    return False


# --- the call sites -----------------------------------------------------------------------------------------------------------

def check(verb, kind, given, op, d, st, ops, texts_before=()):
    """Each extension's check of `brain op VERB` (of `kind`), under the store lock, after brain's own checks, the sensitive
    filter included (`texts_before`: the write's own texts, and the extension's options): a refusal raises Refused; `data`
    goes under `ext.<name>` of the item the op writes (add, supersede) or of the op itself. `given`: {(extension name,
    option): value}. Returns (texts for the sensitive filter, note lines to print)."""
    texts, notes_ = [], []
    target = op["item"] if verb in ("add", "supersede") else op
    exts = checks(verb, kind)
    if not exts:
        return texts, notes_
    s.sanitize(d, [x for x in list(texts_before) + list(given.values()) if x])   # the extension never sees what brain refuses
    budget = Budget(CLI_BUDGET)
    for e in exts:
        mine = {o: v for (n, o), v in given.items() if n == e["name"]}
        try:
            out = run(e, payload(e, "check", st, ops, verb=verb, kind=kind, options=mine, op=op), budget.take(CLI_SECONDS), d,
                      locked=True)
            ref = refusal(out, d, (1, 64))
            data, note = data_of(out), note_of(out)
        except Broken as b:
            skipped(d, e, "check", b)
            if mine:
                raise s.Refused(1, "extension %s is not available (%s): its option %s cannot be recorded; run brain doctor"
                                % (e["name"], b, sorted(mine)[0]))
            WARNINGS.append("extension %s skipped (%s): its check did not run" % (e["name"], b))
            continue
        if ref:
            raise s.Refused(ref[0], "%s: %s" % (e["name"], ref[1]))
        if data is not ABSENT:
            ext = dict(target.get("ext") or {})
            if data is None:
                ext.pop(e["name"], None)
            else:
                ext[e["name"]] = data
                texts += strings(data)
            if ext:
                target["ext"] = ext
            else:
                target.pop("ext", None)
        texts += note
        notes_ += ["%s: %s" % (e["name"], l) for l in note]
    return texts, notes_


def owner_texts(ns, spec):
    """The texts of an owner verb the session wrote: they pass the sensitive-value filter before the extension sees them."""
    if spec["effect"] == "archive":
        return [ns.pointer]
    return ([ns.text, ns.owner_quote, ns.where] + [getattr(ns, "ext_arg_" + a) for a in spec["args"]] + list(ns.link)
            + list(ns.anchor))


def owner_fields(ns, spec):
    """The owner verb's own input fields, from its parsed arguments."""
    if spec["effect"] == "archive":
        return {"id": ns.id, "pointer": ns.pointer}
    return {"args": {a: getattr(ns, "ext_arg_" + a) for a in spec["args"]}, "text": ns.text, "quote": ns.owner_quote,
            "where": ns.where, "anchors": ns.anchor, "links": ns.link}


def owner_call(e, spec, phase, ns, d, st, ops, seconds, locked=False, session=None):
    """An owner verb's call, once its texts passed the filter: ("refuse", message) or ("ok", detail or data). Broken when the
    extension does not answer."""
    s.sanitize(d, [x for x in owner_texts(ns, spec) if x])     # the extension never sees what brain refuses
    out = run(e, payload(e, "owner", st, ops, phase=phase, verb=ns.verb, effect=spec["effect"], **owner_fields(ns, spec)),
              seconds, d, locked, session)
    ref = refusal(out, d)
    if ref:
        return "refuse", ref[1]
    if phase == "ask":
        detail = out.get("detail")
        if detail is None:
            return "ok", None
        detail = text_of(detail, DETAIL_MAX, "detail")
        if '"' in detail or "(" in detail or ")" in detail or s.quote_like(detail):
            raise Broken("its detail holds a quote, a parenthesis or a character that passes for a quote: the dialog shows it "
                         "in parentheses inside brain's own line")
        if s.DECISION_KIND in " ".join(s.skeleton(detail).casefold().split()):
            raise Broken("its detail holds brain's kind phrase (%s): only brain names an item's kind in the dialog"
                         % s.DECISION_KIND)
        return "ok", detail or None
    return "ok", data_of(out)


def dialog(ns, d, st, ops, session=None):
    """guard-owner's dialog line for an extension's owner verb: brain's own line for the write, the extension's detail inside
    it, every value the session wrote in quotes. Refused (1) when the write would be refused, the extension refuses, or it
    does not answer."""
    e, spec = owner_verb(ns.verb)
    if spec["effect"] == "pin":
        s.check_cap(st, "D")                       # brain's own refusals first: the extension is not asked for those
    else:
        it = s.get_live(st, ns.id, spec["letters"])
    s.ensure_dir(d)
    try:
        how, detail = owner_call(e, spec, "ask", ns, d, st, ops, HOOK_SECONDS, session=session)
    except Broken as b:
        skipped(d, e, "owner", b)
        raise s.Refused(1, "extension %s did not answer (%s): its verb %s is not available now; run brain doctor"
                        % (e["name"], b, ns.verb))
    if how == "refuse":
        raise s.Refused(1, "%s: %s" % (e["name"], detail))
    if detail and withheld(d, [detail]):
        raise s.Refused(1, "extension %s: its detail holds a sensitive value" % e["name"])
    more = " (%s)" % detail if detail else ""
    if spec["effect"] == "pin":
        args = "".join(' "%s"' % getattr(ns, "ext_arg_" + a) for a in spec["args"])
        return '%s %s%s: Pin owner decision %s (%s)%s, from "%s": "%s"' % (e["name"], ns.verb, args, s.next_id(st, "D"),
                                                                          s.DECISION_KIND, more, ns.where, ns.text)
    noun = {"G": "owner goal", "D": "owner decision", "W": "owner window", "T": "lesson", "F": "fact"}[ns.id[0]]
    return '%s %s: Promote %s %s to "%s"%s: "%s"' % (e["name"], ns.verb, noun, ns.id, ns.pointer, more, s.escaped(it["text"]))


def owner_write(ns, d, st, ops):
    """(effect, data) of an extension's owner verb at the CLI, under the lock, once the record matched: refused (1) when the
    extension refuses or does not answer (the record stays unspent)."""
    e, spec = owner_verb(ns.verb)
    try:
        how, data = owner_call(e, spec, "write", ns, d, st, ops, CLI_SECONDS, locked=True)
    except Broken as b:
        skipped(d, e, "owner", b)
        raise s.Refused(1, "extension %s did not answer (%s): its verb %s is not available now; run brain doctor"
                        % (e["name"], b, ns.verb))
    if how == "refuse":
        raise s.Refused(1, "%s: %s" % (e["name"], data))
    return e, spec, data


def start_lines(d, st, ops, source, card, session=None, project=None, cli=False):
    """String 1's lines from every extension that answers `start` (`- ` not yet added): `<name>: <line>`, or one line when it
    was skipped or its lines hold a sensitive value. `card`: after a compaction and in doctor, when `ops` go with the state.
    `cli`: doctor's call, with the CLI's caps."""
    found(project)
    out = ["%s: skipped (%s): brain doctor" % g for g in _FOUND[_key(project)][2]]
    budget = Budget(CLI_BUDGET if cli else HOOK_BUDGET)
    for e in found(project):
        if "start" not in e["calls"]:
            continue
        try:
            lines = lines_of(run(e, payload(e, "start", st, ops if card else None, source=source, card=card),
                                 budget.take(CLI_SECONDS if cli else HOOK_SECONDS), d, session=session), "start")
            if lines and withheld(d, lines):
                lines = ["lines withheld (a sensitive value): brain doctor"]
        except Broken as b:
            skipped(d, e, "start", b, session)
            lines = ["skipped (%s): brain doctor" % b]
        out += ["%s: %s" % (e["name"], l) for l in lines]
    return out


def record_lines(d, st, ops, days, t0, t1):
    """The record's sections: `## <name>` and its lines, for each extension that answers `record`."""
    out = []
    budget = Budget(CLI_BUDGET)
    for e in found():
        if "record" not in e["calls"]:
            continue
        try:
            lines = lines_of(run(e, payload(e, "record", st, ops, days=days, **{"from": t0, "to": t1}),
                                 budget.take(CLI_SECONDS), d), "record")
            if lines and withheld(d, lines):
                lines = ["lines withheld (a sensitive value)"]
        except Broken as b:
            skipped(d, e, "record", b)
            lines = ["skipped (%s): brain doctor" % b]
        out += ["", "## %s" % e["name"], ""] + (lines or ["- none"])
    return out


def read(name, args, d, st, ops):
    """`brain ext NAME [ARG…]`: the extension's lines; its refusal's rc, or 1 when it is skipped."""
    e = named(name)
    if e is None or "read" not in e["calls"]:
        raise s.Refused(1, "no extension named %s answers brain ext (brain doctor lists the extensions)" % label(name, 30))
    if len(args) > READ_ARGS:
        raise s.Refused(64, "brain ext %s takes at most %d arguments" % (name, READ_ARGS))
    for a in args:
        s.check_text("argument", a, cap=READ_ARG)
    if args:
        s.sanitize(d, list(args))
    try:
        out = run(e, payload(e, "read", st, ops, args=list(args)), CLI_SECONDS, d)
        ref = refusal(out, d, (1, 64))
        lines = [] if ref else lines_of(out, "read")
    except Broken as b:
        skipped(d, e, "read", b)
        raise s.Refused(1, "extension %s skipped (%s); run brain doctor" % (name, b))
    if ref:
        raise s.Refused(ref[0], "%s: %s" % (name, ref[1]))
    if lines and withheld(d, lines):
        raise s.Refused(1, "extension %s: its lines hold a sensitive value; nothing is shown" % name)
    return "\n".join(lines)


def doctor_lines(d, st, ops, project=None):
    """[(level, text)]: each extension found, each skipped, the last skip of each in the Episode Log within a day, and the
    lines its `start` call gives with the card."""
    import brain_ledger
    out = list(notes(project))
    for e in found(project):
        parts = ["checks " + " ".join("%s%s" % (c["verb"], "(%s)" % ",".join(c["kinds"]) if c["kinds"] else "")
                                      for c in e["checks"]) if e["checks"] else "",
                 "owner " + " ".join(sorted(e["owner"])) if e["owner"] else "", "calls " + " ".join(e["calls"]) if e["calls"] else ""]
        out.append(("info", "extension %s of %s: %s" % (e["name"], label(e["id"]),
                                                        "; ".join(p for p in parts if p) or "declares nothing")))
    last = {}
    for o in brain_ledger.episodes(d, SKIP_TAIL) if d is not None else []:
        if o.get("kind") == "extension-skip" and isinstance(o.get("extension"), str):
            last[o["extension"]] = o
    now = time.time()
    for name, o in sorted(last.items()):
        t = s.parse_iso(o.get("t") or "")
        if t is not None and now - t < SKIP_SHOWN:
            out.append(("warn", "extension %s skipped at %s (%s call): %s%s" % (
                label(name, 30), str(o.get("t"))[5:16].replace("T", " "), label(o.get("call"), 10), label(o.get("why"), 200),
                "; its stderr: " + label(o["stderr"], 120) if o.get("stderr") else "")))
    if d is not None and os.path.isdir(d):
        out += [("info", "review card: " + l) for l in start_lines(d, st, ops, "doctor", True, project=project, cli=True)]
    return out
