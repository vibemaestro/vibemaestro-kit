"""vibemaestro-brain transfer: export, import, backup and restore of a project's brain, as one bundle.

A bundle is one JSON file: a brain's log line by line as it was written, its chain head, and copies of what the log holds (the
live and queued items, the overflow queue, the ledger) for readers. Every check and every import works from the log. `brain
import` lands the right brain as `brain op add` writes it and replays the ledger; `brain owner import` lands the left brain
through one dialog bound to its record. The owner names a private place for backups; `brain backup` writes one there.

Loaded only by the commands that need it (`brain export`, `import`, `backup`, `doctor --bundle`, `owner import`, `owner
backup`, and guard-owner for those two): no SessionStart command imports it, so the hooks never compile it
(tests/test-brain-transfer.sh [l] holds that). What the hooks read of the backups (is one due, the card and doctor lines) stays
in brain_store. Standard library only.
"""
import contextlib
import fcntl
import hashlib
import json
import os
import re
import stat
import time

import brain_store as s


# --- bundles: export, check, import -------------------------------------------------------------------------------------------
# A bundle is one JSON file: a brain's log line by line as it was written, its chain head, and copies of what the log holds
# (the live and queued items, the overflow queue, the ledger) for readers. Every check and every import works from the log:
# its chain is checked as `verify` checks the brain's, and its copies must equal its fold. This machine's paths become
# placeholders; a line that changed is carried with its original hash. A bundle is data: nothing in it is run or used as a
# path, and its text passes the guards of a write before anything lands. An import only appends: `brain import` the right
# brain as `brain op add` writes it, and the ledger's events; `brain owner import` the left brain, through one dialog.

BUNDLE_MAGIC = "vibemaestro-brain"
BUNDLE_VERSION = 1                  # kept whole, so that a later envelope (a passphrase) can wrap a version-1 bundle unchanged
BUNDLE_MAX = 64 * 1024 * 1024       # bytes: export refuses past it, a read refuses a larger file
BUNDLE_KEYS = frozenset(("bundle", "version", "format", "exported", "project", "scope", "head", "log", "items", "queue",
                         "ledger", "placeholders"))
BUNDLE_SCOPES = ("all", "global", "project")
PLACEHOLDERS = ("<project>", "<brain-state>", "<state-home>", "<claude-dir>", "~")
NAME_RE = re.compile(r"[A-Za-z0-9._-]{1,40}")
KEY_RE = re.compile(r"[0-9a-f]{12}")
HASH_RE = re.compile(r"[0-9a-f]{64}")
# the ids and hashes the brain writes itself, by where it writes them (an op's prev, its writer, its record, an evidence op's
# session label, an import's key and hashes): never text, and a random id can read as a phone number to the filter. Every other
# string of an op or an item, at any depth and under any key, is text, filtered as a write's
IMPORT_IDS = frozenset(("key", "head", "line"))
RIGHT_LETTERS = dict(s.HALVES)["right"]
DIALOG_MAX = 20000                  # UTF-16 units of one owner import's dialog: a design value, not measured
TIME_SKEW = 300                     # seconds a time in a bundle may run ahead of this clock


def _pairs(kv):
    out = {}
    for k, v in kv:
        if k in out:
            raise ValueError("a repeated key")      # two readers could take two different values
        out[k] = v
    return out


def _no_constant(name):
    raise ValueError("%s is not JSON" % name)


def strict_json(text):
    """JSON with no repeated key and no NaN or Infinity."""
    return json.loads(text, object_pairs_hook=_pairs, parse_constant=_no_constant)


def texts_of(objs):
    """Every text string of the ops or items `objs`, keys included, at any depth, but the ids and hashes the brain writes
    itself where it writes them (`structural`)."""
    out = []

    def walk(x, path):
        if isinstance(x, str):
            if not structural(path):
                out.append(x)
        elif isinstance(x, dict):
            for k, v in x.items():
                out.append(k) if isinstance(k, str) else None
                walk(v, path + (k,))
        elif isinstance(x, list):
            for v in x:
                walk(v, path + (None,))
    for o in objs:
        walk(o, ())
    return out


def structural(path):
    """The string at `path` (its keys from an op or an item down) is an id or a hash the brain writes itself."""
    return (path in (("prev",), ("session",), ("by", "session"), ("confirm", "record"))
            or (len(path) >= 2 and path[-2] == "import" and path[-1] in IMPORT_IDS))


def bad_string(obj):
    """The first string of `obj` (a key or a value, at any depth) holding a character a write refuses: a control, format,
    invisible or noncharacter, a selector out of place, a stack of marks; None when it holds none."""
    stack = [obj]
    while stack:
        x = stack.pop()
        if isinstance(x, str):
            if x.isascii() and x.isprintable():
                continue
            if (any(s.is_bad(c) for c in x) or s._marks_run(x) > s.MARKS_RUN_MAX
                    or any(ord(c) in s.SELECTORS and not s.selector_fits(x, i) for i, c in enumerate(x))):
                return x
        elif isinstance(x, dict):
            stack.extend(x)
            stack.extend(x.values())
        elif isinstance(x, list):
            stack.extend(x)
    return None


def within(path, root):
    """`path` is `root` or lies under it, both resolved."""
    p, r = os.path.realpath(path), os.path.realpath(root)
    return p == r or p.startswith(r.rstrip(os.sep) + os.sep)


def machine_paths():
    """[(path, placeholder)] of this machine's own layout, longest first: the project's work trees, the brain's state root and
    the XDG_STATE_HOME it sits in, Claude Code's config directory and the home directory (by HOME and by the account), each as
    given and resolved."""
    out = {}
    xdg = os.environ.get("XDG_STATE_HOME", "")
    for p, ph in ((s.config_root(), "<project>"), (s.project_root(), "<project>"), (s.state_root(), "<brain-state>"),
                  (xdg if os.path.isabs(xdg) else "", "<state-home>"), (s.config_dir(), "<claude-dir>"), (s.home(), "~"),
                  (s.account_home(), "~")):
        for q in (p, os.path.realpath(p) if p else ""):
            q = (q or "").rstrip(os.sep)
            if os.path.isabs(q) and len(q) > 1:
                out.setdefault(q, ph)
    return sorted(out.items(), key=lambda kv: (-len(kv[0]), kv[0]))


def redacted(obj, paths, used):
    """`obj` with each of this machine's paths in a string replaced by its placeholder (a path ends where no path character
    follows); the placeholders used go into `used`."""
    if isinstance(obj, str):
        for p, ph in paths:
            if p in obj:
                obj, n = re.subn(re.escape(p) + r"(?![A-Za-z0-9._-])", lambda _: ph, obj)
                if n:
                    used.add(ph)
        return obj
    if isinstance(obj, dict):
        return {k: redacted(v, paths, used) for k, v in obj.items()}
    if isinstance(obj, list):
        return [redacted(v, paths, used) for v in obj]
    return obj


def project_id(d):
    """{"name", "key"} of the state directory `d`: its base name and the 12 hex of its project path's hash, never the path."""
    name, _, key = os.path.basename(os.path.normpath(d)).rpartition("-")
    return {"name": name if NAME_RE.fullmatch(name) else "project", "key": key if KEY_RE.fullmatch(key) else "0" * 12}


def item_scope(it):
    """A goal's or a decision's scope: `global`, else `project` (a decision that stores none is the project's)."""
    return "global" if it.get("scope") == "global" else "project"


ITEM_WRITERS = ("add", "overflow-add", "owner-add", "supersede", "owner-supersede", "owner-demote")


def wrote_by(ops):
    """{item id: the seq of the line that wrote it}: only an op that writes an item counts (an `item` key on any other op is
    nothing the fold reads, and must not pass for the writer of a line carried with a placeholder)."""
    return {op["item"]["id"]: op.get("seq") for op in ops if op.get("op") in ITEM_WRITERS
            and isinstance(op.get("item"), dict) and isinstance(op["item"].get("id"), str)}


def selection_seqs(st, ops, scope):
    """The seqs of the lines a selection carries: those that wrote each live goal and decision of `scope` and every item of its
    supersede chain (the owner's words may sit on the first)."""
    wrote, seqs = wrote_by(ops), set()
    for it in st["items"].values():
        if it["status"] == "live" and it["id"][0] in ("G", "D") and item_scope(it) == scope:
            x, seen = it, set()
            while x is not None and x["id"] not in seen:
                seen.add(x["id"])
                seqs.add(wrote[x["id"]])
                x = st["items"].get(x.get("supersedes")) if isinstance(x.get("supersedes"), str) else None
    return sorted(seqs)


def bundle_copies(st, ops, led_read=None):
    """(items, queue, ledger): what a bundle carries of its log's fold for readers, which every check computes again
    (`led_read`: the ledger already read from `ops`)."""
    import brain_ledger
    order = {letter: i for i, (letter, _) in enumerate(s.SECTIONS)}
    items = sorted((it for it in st["items"].values() if it["status"] in ("live", "queued")),
                   key=lambda i: (order[i["id"][0]], int(i["id"][1:])))
    waiting = {letter: [it["id"] for it in s.queue(st, letter)] for letter, _ in s.SECTIONS}
    led = {}
    for key, v in sorted((brain_ledger.read(ops) if led_read is None else led_read).items()):
        ev = v["events"]
        times = sorted(str(e["t"]) for e in ev if isinstance(e["t"], str))
        led[key] = {"held": sum(e["result"] == "held" for e in ev), "broke": sum(e["result"] == "broke" for e in ev),
                    "progress": sum(e["result"] == "progress" for e in ev),
                    "sessions": len({str(e["session"]) for e in ev if e["result"] in ("held", "broke")}),
                    "first": times[0] if times else None, "last": times[-1] if times else None}
    return items, {k: v for k, v in waiting.items() if v}, led


def build_bundle(d, scope="all", now=None):
    """(bundle, how many lines carry a placeholder) of the state directory `d`, its log read under the lock. Refused (1) when
    the sensitive-value filter finds a value in what it would carry (only the masked value is printed)."""
    now = time.time() if now is None else now
    with s.locked(d):
        raw, ops = s.verify(d)
    paths, used, log, bops, changed = machine_paths(), set(), [], [], 0
    for seq in range(1, len(raw) + 1) if scope == "all" else selection_seqs(s.fold(ops), ops, scope):
        op = ops[seq - 1]
        r = redacted(op, paths, used)
        if r == op:
            log.append({"seq": seq, "line": raw[seq - 1].decode("utf-8")})
        else:                                       # the line's own hash, so the chain is still checked across it
            log.append({"seq": seq, "line": s.dumps(r), "sha256": s.line_hash(raw[seq - 1])})
            changed += 1
        bops.append(r)
    items, waiting, led = bundle_copies(s.fold(bops), bops)
    b = {"bundle": BUNDLE_MAGIC, "version": BUNDLE_VERSION, "format": s.FORMAT, "exported": s.now_iso(now), "project": project_id(d),
         "scope": scope, "head": s.head_of(raw), "log": log, "items": items, "queue": waiting, "ledger": led,
         "placeholders": sorted(used)}
    s.sanitize(d, list(dict.fromkeys(texts_of(bops) + texts_of(items) + [b["project"]["name"]])))
    return b, changed


def write_new(path, data):
    """`data` into a new file, 0600; FileExistsError when anything is at `path`, a symlink included."""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        view = memoryview(data)
        while view:
            view = view[os.write(fd, view):]
        os.fsync(fd)
    except OSError:
        os.close(fd)
        with contextlib.suppress(OSError):
            os.unlink(path)
        raise
    os.close(fd)


def section_counts(items):
    n = {}
    for it in items:
        n[it["id"][0]] = n.get(it["id"][0], 0) + 1
    return ", ".join("%s %d" % (letter, n[letter]) for letter, _ in s.SECTIONS if n.get(letter))


def export(out, scope=None):
    """`brain export --out FILE [--scope global|project]`: one bundle of this project's brain, into a new file. A read: it
    needs no session and writes nothing to the brain but one Episode Log line."""
    scope = scope or "all"
    if scope not in BUNDLE_SCOPES:
        raise s.Refused(64, "--scope is global or project (without it, the whole brain)")
    d = s.state_dir()
    if not os.path.isfile(os.path.join(d, "hot.jsonl")):
        raise s.Refused(1, "no brain state for this project yet: nothing to export")
    target = os.path.abspath(out)
    if within(os.path.dirname(target), s.state_root()):
        raise s.Refused(1, "--out lies in the brain's state root: a bundle goes outside it")
    if os.path.lexists(target):
        raise s.Refused(1, "%s exists: a bundle is written to a new file" % target)
    b, changed = build_bundle(d, scope)
    data = (s.dumps(b) + "\n").encode("utf-8")
    if len(data) > BUNDLE_MAX:
        raise s.Refused(1, "the bundle would be %d bytes, past the %d a bundle may hold: export by --scope" % (len(data), BUNDLE_MAX))
    try:
        write_new(target, data)
    except OSError as e:
        raise s.Refused(1, "%s cannot be written (%s)" % (target, e.__class__.__name__))
    s.episode_line(d, s.session_id(), "export", scope=scope, seq=b["head"]["seq"], lines=len(b["log"]))
    return "exported %s at seq %d (head %s…), %s: %s; %d log line%s%s; to %s" % (
        b["project"]["name"], b["head"]["seq"], b["head"]["sha256"][:12], "the whole brain" if scope == "all" else
        "the %s goals and decisions" % scope, section_counts(b["items"]) or "no item", len(b["log"]),
        "" if len(b["log"]) == 1 else "s", ", %d with a placeholder (%s)" % (changed, " ".join(b["placeholders"])) if changed
        else "", target)


def read_bundle(path):
    """(bundle, the SHA-256 of its bytes): a regular file, not a symlink, at most BUNDLE_MAX bytes, one JSON value with no
    repeated key; Refused(1) otherwise. Nothing in it is opened, run or used as a path."""
    name = s.printable(path)
    try:
        st_ = os.lstat(path)
    except OSError as e:
        raise s.Refused(1, "%s cannot be read (%s)" % (name, e.__class__.__name__))
    if stat.S_ISLNK(st_.st_mode):
        raise s.Refused(1, "%s is a symlink: name the bundle's own file" % name)
    if not stat.S_ISREG(st_.st_mode):
        raise s.Refused(1, "%s is not a regular file" % name)
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0))
        with os.fdopen(fd, "rb") as f:
            if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
                raise s.Refused(1, "%s is not a regular file" % name)
            data = f.read(BUNDLE_MAX + 1)
    except OSError as e:
        raise s.Refused(1, "%s cannot be read (%s)" % (name, e.__class__.__name__))
    if len(data) > BUNDLE_MAX:
        raise s.Refused(1, "%s is larger than a bundle may be (%d bytes)" % (name, BUNDLE_MAX))
    try:
        b = strict_json(data.decode("utf-8"))
    except (ValueError, UnicodeDecodeError, RecursionError) as e:
        raise s.Refused(1, "%s is not a bundle: not one JSON object (%s)" % (name, s.printable(str(e))[:80]))
    return b, hashlib.sha256(data).hexdigest()


def bundle_shape(b):
    """The problems of a bundle's shape: its keys, version, format, project, scope, head and the shape of its log."""
    if not isinstance(b, dict):
        return ["it is not a JSON object"]
    if set(b) != BUNDLE_KEYS:
        missing, extra = sorted(BUNDLE_KEYS - set(b)), sorted(set(b) - BUNDLE_KEYS)
        return ["its keys are not a bundle's%s%s" % ("; missing: " + ", ".join(missing) if missing else "",
                                                       "; unknown: " + ", ".join(s.printable(k)[:30] for k in extra[:5])
                                                       if extra else "")]
    out = []
    if b["bundle"] != BUNDLE_MAGIC:
        out.append("it is not a vibemaestro-brain bundle")
    if not s._isint(b["version"]) or b["version"] < 1:
        out.append("its version is not a number")
    elif b["version"] > BUNDLE_VERSION:
        out.append("its version %d is newer than this brain reads (%d): update vibemaestro-brain" % (b["version"], BUNDLE_VERSION))
    if not s._isint(b["format"]) or b["format"] < 1:
        out.append("its log format is not a number")
    elif b["format"] > s.FORMAT:
        out.append("its log format %d is newer than this brain folds (%d): update vibemaestro-brain" % (b["format"], s.FORMAT))
    p = b["project"]
    if not (isinstance(p, dict) and set(p) == {"name", "key"} and isinstance(p["name"], str) and NAME_RE.fullmatch(p["name"])
            and isinstance(p["key"], str) and KEY_RE.fullmatch(p["key"])):
        out.append("its project is not a name and a key")
    if not isinstance(b["scope"], str) or b["scope"] not in BUNDLE_SCOPES:
        out.append("its scope is not all, global or project")
    if not isinstance(b["exported"], str) or s.parse_iso(b["exported"]) is None:
        out.append("its export time is not a time")
    h = b["head"]
    if not (isinstance(h, dict) and set(h) == {"seq", "sha256"} and s._isint(h["seq"]) and h["seq"] >= 0
            and isinstance(h["sha256"], str) and HASH_RE.fullmatch(h["sha256"])):
        out.append("its head is not a seq and a hash")
    lines = b["log"]
    if not isinstance(lines, list) or not all(
            isinstance(e, dict) and set(e) in ({"seq", "line"}, {"seq", "line", "sha256"}) and s._isint(e["seq"])
            and isinstance(e["line"], str) and (isinstance(e.get("sha256", "0" * 64), str) and HASH_RE.fullmatch(e.get("sha256", "0" * 64)))
            for e in lines):
        out.append("its log is not a list of lines")
    if not (isinstance(b["items"], list) and all(isinstance(i, dict) and isinstance(i.get("id"), str) for i in b["items"])
            and isinstance(b["queue"], dict) and all(isinstance(v, list) for v in b["queue"].values())
            and isinstance(b["ledger"], dict) and all(isinstance(v, dict) for v in b["ledger"].values())):
        out.append("its items, queue or ledger is not a copy's shape")
    if not isinstance(b["placeholders"], list) or not all(isinstance(x, str) and x in PLACEHOLDERS for x in b["placeholders"]):
        out.append("its placeholders are not the brain's")
    return out


def bundle_check(b, now=None):
    """([problems], context) of a bundle `read_bundle` read. The context, None while the bundle cannot be folded, holds its
    ops, the hash of each of its lines by seq, its fold and whether it carries the full chain."""
    now = time.time() if now is None else now
    out = bundle_shape(b)
    if out:
        return out, None
    full, h = b["scope"] == "all", b["head"]
    ops, hashes, last = [], {}, 0
    for e in b["log"]:
        seq = e["seq"]
        try:
            op = strict_json(e["line"])
        except (ValueError, RecursionError):
            return ["log seq %d: its line is not JSON" % seq], None
        if not isinstance(op, dict) or op.get("seq") != seq:
            return ["log seq %d: its line holds another seq" % seq], None
        if full and seq != last + 1:
            return ["its log goes from seq %d to %d: a line is missing or out of place" % (last, seq)], None
        if not full and not last < seq <= h["seq"]:
            return ["log seq %d: out of order, or past its head" % seq], None
        want = s.GENESIS if seq == 1 else hashes.get(seq - 1)
        if want is not None and op.get("prev") != want:
            return ["log seq %d: its prev is not the hash of line %d: the chain is broken (an edit or a splice)" % (seq, seq - 1)], None
        if "sha256" in e and (e["sha256"] == s.line_hash(e["line"].encode("utf-8"))
                              or not any(ph in e["line"] for ph in b["placeholders"])):
            return ["log seq %d: carried with its source's hash, yet it holds none of the bundle's placeholders: only a line "
                    "that changed for one keeps its source's hash" % seq], None   # else any line could take the chain's word
        hashes[seq] = e.get("sha256") or s.line_hash(e["line"].encode("utf-8"))
        ops.append(op)
        last = seq
    if full and (last != h["seq"] or (hashes[last] if last else s.GENESIS) != h["sha256"]):
        return ["its head (seq %d) is not the end of its log (seq %d, hash %s…): the chain is cut or spliced"
                % (h["seq"], last, (hashes[last] if last else s.GENESIS)[:12])], None
    bad = bad_string(ops) or bad_string({k: v for k, v in b.items() if k != "log"})
    if bad is not None:
        out.append("a string holds a control, format or invisible character: %s" % s.printable(bad)[:80])
    for op in ops:
        t = s.parse_iso(op["t"]) if isinstance(op.get("t"), str) else None
        if t is None or t > now + TIME_SKEW:
            out.append("log seq %d: its time is not a past time" % op["seq"])
            break
    if not full:
        odd = [op["seq"] for op in ops if op.get("op") not in ("owner-add", "owner-supersede", "owner-demote")
               or not isinstance(op.get("item"), dict) or str(op["item"].get("id", ""))[:1] not in ("G", "D")]
        if odd:
            return out + ["a selection holds only the lines of goals and decisions: seq %d is not one" % odd[0]], None
    try:
        import brain_ledger
        st = s.fold(ops)
        led = brain_ledger.read(ops)
        copies = json.loads(s.dumps(bundle_copies(st, ops, led)))
    except s.Refused as e:
        return out + ["its log does not fold: %s" % e.msg], None
    except (KeyError, TypeError, ValueError, AttributeError, IndexError) as e:
        return out + ["its log does not fold: a malformed op (%s)" % e.__class__.__name__], None
    for name, got in zip(("items", "queue", "ledger"), copies):
        if b[name] != got:
            out.append("its copy of the %s differs from the fold of its log" % name)
    carried = {e["seq"] for e in b["log"] if "sha256" in e}
    return out, {"ops": ops, "hashes": hashes, "st": st, "full": full, "led": led, "copies": copies, "carried": carried,
                 "by_seq": {op["seq"]: op for op in ops}}


def filter_dir(d):
    """The directory the sensitive-value filter runs in: the brain's state directory, else its root, else /."""
    return next((x for x in (d, s.state_root()) if x and os.path.isdir(x)), os.sep)


def bundle_doctor(path, now=None):
    """`brain doctor --bundle FILE`: [(level, text)] of one bundle read on its own; no brain is read or written."""
    try:
        b, sha = read_bundle(path)
    except s.Refused as e:
        return [("problem", e.msg)]
    problems, ctx = bundle_check(b, now)
    out = [("problem", p) for p in problems]
    if ctx is None:
        return out
    h, p = b["head"], b["project"]
    if ctx["full"]:
        out.append(("ok", "the chain: %d line%s, each line's prev the hash of the one before, to head %s… at seq %d"
                    % (len(ctx["ops"]), "" if len(ctx["ops"]) == 1 else "s", h["sha256"][:12], h["seq"])))
    else:
        out.append(("info", "a selection (scope %s) of %d lines of the chain to head %s… at seq %d: a line is checked against "
                            "the one before only when both are carried; the rest of the chain is not in the bundle"
                    % (b["scope"], len(ctx["ops"]), h["sha256"][:12], h["seq"])))
    if not any(x.startswith("its copy") for x in problems):
        out.append(("ok", "the copies of the items, the queue and the ledger equal the fold of the log"))
    if ctx["carried"]:
        out.append(("warn", "%d line%s carry a placeholder (%s), at seq %s: the chain does not vouch for their content (their "
                            "hash is the source's), so an import lands nothing they wrote"
                    % (len(ctx["carried"]), "" if len(ctx["carried"]) == 1 else "s", " ".join(b["placeholders"]) or "none named",
                       " ".join(str(x) for x in sorted(ctx["carried"])[:10]))))
    try:
        out += [("problem", x) for x in vet_problems(ctx)]
        s.sanitize(filter_dir(None), list(dict.fromkeys(import_texts(dict(ctx, bundle=b)) + texts_of(ctx["ops"]))))
        out.append(("ok", "the sensitive-value filter finds nothing in its texts and keys (the brain's own ids and hashes, "
                          "never text, are not scanned)"))
    except s.Refused as e:
        out.append(("problem", e.msg))
    except (KeyError, TypeError, ValueError, AttributeError, IndexError) as e:
        out.append(("problem", "a malformed item or event (%s)" % e.__class__.__name__))
    items, waiting, led = ctx["copies"]                 # the fold's, never the bundle's own copies, which may be anything
    out += [("info", "project %s (key %s), exported %s, scope %s, bundle %s…" % (p["name"], p["key"], b["exported"], b["scope"],
                                                                                sha[:12])),
            ("info", "items: %s" % (section_counts(items) or "none")),
            ("info", "ledger: %d rules and goals, %d held, %d broke, %d progress" % (
                len(led), sum(v["held"] for v in led.values()), sum(v["broke"] for v in led.values()),
                sum(v["progress"] for v in led.values())))]
    if waiting:
        out.append(("info", "overflow queue: %s" % ", ".join("%s %d" % (k, len(v)) for k, v in sorted(waiting.items()))))
    return out


# --- import ---------------------------------------------------------------------------------------------------------------------
# An item or an event lands once, wherever it came from: its origin is the `import.line` it carries from an earlier import, else
# the hash of its own line, and this brain's lines, ops and items are indexed by theirs. Nothing a line carried with a
# placeholder wrote lands: the chain does not vouch for that line's content. Items keep their source times, so their dates and
# dormancy read as at the source; `import.at` says when they were written here.

SOURCE_KEYS = frozenset(("type", "quote", "where"))     # an item's source, as a store writes it
SUPERSEDES = re.compile(r"supersedes [GDW][1-9][0-9]{0,5}")   # the `where` an owner supersede writes: an id of the source


def vet_item(it):
    """Refused (1) for an item no store of this brain would have written: a kind that is not its letter's, a source that is
    not its kind's or holds another key, a field of the wrong type or over its fixed cap, a `"` or a look-alike quote in an
    owner item's field the dialog shows before a quote. A text or a quote over this brain's own (configurable) cap is no
    refusal: the plan skips that item."""
    letter, owner = it["id"][0], it["id"][0] in s.OWNER_LETTERS
    if not isinstance(it.get("kind"), str) or s.KINDS.get(it["kind"]) != letter:
        raise s.Refused(1, "its kind is not its letter's")
    if not isinstance(it.get("text"), str):
        raise s.Refused(1, "its text is not a text")
    s.check_text("text", it["text"], cap=s.RANGES["text_max"][1])
    src = it.get("source")
    if not isinstance(src, dict) or src.get("type") != ("owner" if owner else s.SESSION_SOURCE["type"]):
        raise s.Refused(1, "its source is not %s" % ("the owner's" if owner else "the session's"))
    if set(src) - SOURCE_KEYS:
        raise s.Refused(1, "its source holds a key a store never writes")
    for field, req in (("quote", letter in ("G", "P", "R")), ("where", owner or letter in ("P", "R"))):
        v = src.get(field)
        if v is None and not req:
            continue
        if not isinstance(v, str):
            raise s.Refused(1, "its %s is not a text" % field)
        s.check_text(field, v, cap=s.RANGES["quote_max"][1] if field == "quote" else None)
    for field, v in (("text", it["text"]), ("where", src.get("where")), ("done", it.get("done")),
                     ("not-doing", it.get("not_doing"))):
        if owner and isinstance(v, str) and '"' in v:
            raise s.Refused(1, "its %s holds a double quote, which the owner's dialog cannot show as one field" % field)
        c = s.quote_like(v) if owner and field != "text" and isinstance(v, str) else None
        if c:
            raise s.Refused(1, "its %s holds U+%04X, which can pass for the dialog's quote" % (field, ord(c)))
    for field in ("links", "anchors"):
        v = it.get(field) or []
        if not isinstance(v, list) or not all(isinstance(x, str) for x in v):
            raise s.Refused(1, "its %s are not texts" % field)
        s.check_list(field[:-1], v)
    closes = it.get("closes")
    if closes is not None:
        if not (isinstance(closes, list) and all(isinstance(x, str) for x in closes) and s.closes_list(letter, closes) == closes):
            raise s.Refused(1, "its closes anchors are not this store's")
    exp = it.get("expires")
    if (exp is not None and (not isinstance(exp, str) or s.parse_iso(exp) is None)) or (letter == "W" and exp is None):
        raise s.Refused(1, "its expiry is not a time")
    if letter == "G":
        for field, key in (("done", "done"), ("not-doing", "not_doing")):
            if not isinstance(it.get(key), str):
                raise s.Refused(1, "its %s is not a text" % field)
            s.check_text(field, it[key])
        if s.parse_day(it.get("review")) is None or it.get("scope") not in s.SCOPES:
            raise s.Refused(1, "its review day or scope is not a goal's")
    if letter == "D" and it.get("scope") is not None and it.get("scope") not in s.SCOPES:
        raise s.Refused(1, "its scope is not global or project")
    for key, want in (("goal", "G"), ("focus", "P")):
        v = it.get(key)
        if v is not None and not (isinstance(v, str) and v[:1] == want and s.ID_RE.fullmatch(v)):
            raise s.Refused(1, "its %s is not a %s id" % (key, want))
    if letter == "P" and it.get("goal") is None:
        raise s.Refused(1, "a focus without its goal")
    if it.get("due") is not None and s.parse_day(it.get("due")) is None:
        raise s.Refused(1, "its due day is not a day")
    if it.get("no_goal") is not None:
        if not isinstance(it["no_goal"], str):
            raise s.Refused(1, "its reason for no goal is not a text")
        s.check_text("reason", it["no_goal"])


def vet_words(w):
    """Refused (1) for the owner's words an owner supersede left on an earlier item of a chain, as an import would carry them:
    a quote of the wrong type or over the largest cap a store allows, a `where` with a quote (the dialog shows it before
    them)."""
    if not isinstance(w["quote"], str) or (w["where"] is not None and not isinstance(w["where"], str)):
        raise s.Refused(1, "the owner's words of its chain are not texts")
    s.check_text("quote", w["quote"], cap=s.RANGES["quote_max"][1])
    if w["where"] is not None:
        s.check_text("where", w["where"])
        if '"' in w["where"] or s.quote_like(w["where"]):
            raise s.Refused(1, "the where of its chain's words holds a quote")


def vet_event(e):
    """Refused (1) for a ledger event no store would have written: a result, a pointer, a what-differed or a measure of the
    wrong type, missing or over its cap, a quote in a measure (the card shows it in quotes)."""
    need = {"held": () if e.get("via") == "hit" else ("pointer",), "broke": ("pointer", "differed"),
            "progress": ("measure", "pointer")}.get(e.get("result"))
    if need is None:
        raise s.Refused(1, "its result is not held, broke or progress")
    for field in ("pointer", "differed", "measure"):
        v = e.get(field)
        if v is None and field not in need:
            continue
        if not isinstance(v, str):
            raise s.Refused(1, "its %s is not a text" % field)
        s.check_text(field, v)
    m = e.get("measure")
    if isinstance(m, str) and ('"' in m or s.quote_like(m)):
        raise s.Refused(1, "its measure holds a quote")
    if not isinstance(e.get("session"), str) or e.get("via") not in (None, "hit"):
        raise s.Refused(1, "its session or its via is not a store's")


def import_context(path):
    """The context of a bundle an import may read: its check's (any problem refuses it whole, rc 1), the bundle, the hash of
    its bytes, its source key, the line that wrote each of its items and each item's origin; then every item, chain's words
    and event an import could write is vetted (one a store would never have written refuses it whole)."""
    b, sha = read_bundle(path)
    name = s.printable(os.path.basename(path))
    try:
        problems, ctx = bundle_check(b)
        if problems:
            raise s.Refused(1, "%s is refused whole: %s%s" % (name, "; ".join(problems[:3]), " (+%d more: brain doctor --bundle)"
                                                             % (len(problems) - 3) if len(problems) > 3 else ""))
        ctx.update(bundle=b, sha=sha, key=b["project"]["key"], wrote=wrote_by(ctx["ops"]))
        how = {iid: (it, source_line(ctx, iid), ctx["by_seq"].get(ctx["wrote"].get(iid), {}), ctx["wrote"].get(iid) in ctx["carried"])
               for iid, it in ctx["st"]["items"].items()}
        ctx["origins"] = {iid: origin(*h) for iid, h in how.items()}
        ctx["continues"] = {iid: continued(*h) for iid, h in how.items()}
        vetted = vet_problems(ctx)
    except (KeyError, TypeError, ValueError, AttributeError, IndexError) as e:
        raise s.Refused(1, "%s is refused whole: a malformed item or op (%s)" % (name, e.__class__.__name__))
    if vetted:
        raise s.Refused(1, "%s is refused whole: %s" % (name, vetted[0]))
    return ctx


def landing_items(ctx):
    """The bundle's items an import could land: live and queued."""
    return [it for it in ctx["st"]["items"].values() if it["status"] in ("live", "queued")]


def vet_problems(ctx):
    """What `vet_item`, `vet_words` and `vet_event` refuse in what an import of the bundle could write."""
    out = []
    for it in sorted(landing_items(ctx), key=lambda i: (i["id"][0], int(i["id"][1:]))):
        try:
            vet_item(it)
            w = chain_words(ctx["st"], it) if it["id"][0] in ("D", "W") and not it["source"].get("quote") else None
            if w:
                vet_words(w)
        except s.Refused as e:
            out.append("its %s: %s" % (it["id"], e.msg))
    for v in ctx["led"].values():
        for e in v["events"]:
            try:
                vet_event(e)
            except s.Refused as e2:
                out.append("its line seq %s: %s" % (e.get("seq"), e2.msg))
    return out


def import_texts(ctx):
    """Every text an import of the bundle could write (its live and queued items whole, the words of their chains, its
    ledger's events, its project's name): one run of the sensitive-value filter takes them all, before the lock."""
    items = landing_items(ctx)
    words = [w for w in (chain_words(ctx["st"], it) for it in items if it["id"][0] in ("D", "W")) if w]
    ev = [e for v in ctx["led"].values() for e in v["events"]]
    return list(dict.fromkeys(texts_of(items) + texts_of(words) + [x for e in ev for x in (e.get("pointer"), e.get("differed"),
                                                                                          e.get("measure")) if isinstance(x, str)]
                              + [ctx["bundle"]["project"]["name"]]))


def source_line(ctx, iid):
    """The hash of the bundle's line that wrote item `iid` (None when it holds none)."""
    return ctx["hashes"].get(ctx["wrote"].get(iid))


IMPORTING = ("add", "overflow-add", "owner-add")    # the ops an import writes an item with (a supersede is a new item)


def _hash_of(p, key):
    v = p.get(key) if isinstance(p, dict) else None
    return v if isinstance(v, str) and HASH_RE.fullmatch(v) else None


def origin(x, line, wrote_op=None, carried=False):
    """Where an item or an op first came from: the `import.line` it carries from an earlier import, else `line`, the hash of
    its own line. For an item, `wrote_op` is the op that wrote it: only an add carries an import's origin, since a supersede
    copies the provenance of the item it replaces into an item of its own; and a line carried with a placeholder names no
    origin but its own (the chain does not vouch for what it says)."""
    if carried or (wrote_op is not None and wrote_op.get("op") not in IMPORTING):
        return line
    return _hash_of(x.get("import"), "line") or line


CONTINUES_MAX = 32                  # origins one item records it continues, however many edits and restores it went through


def continued(x, line, wrote_op=None, carried=False):
    """The origins an item continues, as a tuple: those an import recorded (`import.continues`, every generation of edits and
    restores), and, for an item a supersede wrote with the provenance of the item it replaced, that item's origin too; none for
    a carried line."""
    p = x.get("import") if isinstance(x.get("import"), dict) else {}
    if carried:
        return ()
    c = p.get("continues")
    out = [h for h in ([c] if isinstance(c, str) else c if isinstance(c, list) else []) if isinstance(h, str) and HASH_RE.fullmatch(h)]
    if wrote_op is not None and wrote_op.get("op") not in IMPORTING and _hash_of(p, "line"):
        out.insert(0, p["line"])
    return tuple(dict.fromkeys(out))[:CONTINUES_MAX]


def here_index(raw, ops, st):
    """(the origins of this brain's lines and ops, {the origin of each of its items: [its ids]}, the same with the origins each
    item continues as well). The first map is what an item is, the second also what it stands for: an edit here, restored,
    stands for what it replaced, so the original is not landed again, but the original's evidence is not the edit's (a
    supersede starts a rule's evidence again)."""
    hashes, wrote = [s.line_hash(b) for b in raw], wrote_by(ops)
    lines, items, known = set(hashes), {}, {}
    for op in ops:
        lines.add(origin(op, None))
    for it in st["items"].values():
        seq = wrote.get(it["id"])
        ok = s._isint(seq) and 0 < seq <= len(hashes)
        how = (it, hashes[seq - 1] if ok else None, ops[seq - 1] if ok else {})
        o = origin(*how)
        if o:
            items.setdefault(o, []).append(it["id"])
        for x in dict.fromkeys((o,) + continued(*how)):
            if x:
                known.setdefault(x, []).append(it["id"])
    lines.discard(None)
    return lines, items, known


def here_of(st, items, o, ok=("live",)):
    """The item here an origin `o` landed as, followed through a supersede here, when its status is one of `ok`; else None."""
    for iid in sorted(items.get(o, ()), key=lambda i: int(i[1:])):
        end = s.last_of(st, iid)
        if (st["items"].get(end) or {}).get("status") in ok:
            return end
    return None


def provenance(ctx, sid, now):
    """An imported item's `import`: the source project, its key, the bundle's head, the source id, the origin of the line that
    wrote it, its source time, whether the chain was carried, and when it was written here."""
    b = ctx["bundle"]
    return {"from": b["project"]["name"], "key": ctx["key"], "head": b["head"]["sha256"], "seq": b["head"]["seq"], "id": sid,
            "line": ctx["origins"][sid], "created": ctx["st"]["items"][sid].get("created"),
            "chain": "full" if ctx["full"] else "selection", "at": s.now_iso(now),
            **({"continues": list(ctx["continues"][sid])} if ctx["continues"].get(sid) else {})}


def source_time(it, now):
    """An item's time at the source when it reads as a past time, else `now`: an imported item keeps its date."""
    t = s.parse_iso(it.get("created") or "") if isinstance(it.get("created"), str) else None
    return it["created"] if t is not None and t <= now + TIME_SKEW else s.now_iso(now)


def over_caps(it, words=None):
    """Why an item exceeds this brain's own caps (a text, the owner's words, those of its chain), which the source may have set
    higher; None when it fits."""
    letter, q = it["id"][0], (it.get("source") or {}).get("quote")
    if s.units(it["text"]) > s.text_max(letter):
        return "its text is %d units, over this brain's cap of %d" % (s.units(it["text"]), s.text_max(letter))
    for what, x in (("the owner's words are", q if letter in s.QUOTED else None),
                    ("the owner's words of its chain are", (words or {}).get("quote"))):
        if isinstance(x, str) and s.units(x) > s.quote_max():
            return "%s %d units, over this brain's cap of %d" % (what, s.units(x), s.quote_max())
    return None


def blocked(ctx, st, items, it, words=None):
    """Why a bundle's item may not land whatever this brain's room: a line carried with a placeholder wrote it (or the words of
    its chain), or its chain holds an item that came here before and was retired here; None otherwise."""
    src, carried = ctx["st"], ctx["carried"]
    if ctx["wrote"].get(it["id"]) in carried or (words and ctx["wrote"].get(words["id"]) in carried):
        return "its line carries a placeholder: the chain does not vouch for it; re-add it by hand if it holds"
    x, seen = it, set()
    while isinstance(x.get("supersedes"), str) and x["id"] not in seen:
        seen.add(x["id"])
        x = src["items"].get(x["supersedes"])
        if x is None:
            break
        for iid in items.get(ctx["origins"].get(x["id"]), ()):
            end = s.last_of(st, iid)
            if (st["items"].get(end) or {}).get("status") not in ("live", "queued"):
                return "it supersedes %s at the source, which was retired here (as %s)" % (x["id"], end)
    return None


class Batch:
    """The ops of one import, each folded into a copy of the state as it is planned (so that the next one's id, cap and queue
    see it), appended together under the lock; a claim first when the brain has no writer yet."""

    def __init__(self, raw, st):
        self.st = json.loads(s.dumps(st))
        self.seq = len(raw)
        self.ops = []
        self.top, self.lives = {}, {}               # per letter: the highest id, the live count (kept, not scanned per item)
        for iid, it in self.st["items"].items():
            self.top[iid[0]] = max(self.top.get(iid[0], 0), int(iid[1:]))
            self.lives[iid[0]] = self.lives.get(iid[0], 0) + (it["status"] == "live")
        self.queues = {letter: [it["id"] for it in s.queue(self.st, letter)] for letter in RIGHT_LETTERS}
        if self.st["writer"] is None:
            self.add({"op": "claim", "t": s.now_iso(), "by": s.by(), "takeover": False})

    def add(self, op):
        self.seq += 1
        s.apply(self.st, dict(op, seq=self.seq))
        self.ops.append(op)
        iid = (op.get("item") or {}).get("id")
        if op["op"] in IMPORTING and iid:
            self.top[iid[0]] = max(self.top.get(iid[0], 0), int(iid[1:]))
            if op["op"] == "overflow-add":
                self.queues[iid[0]].append(iid)
            else:
                self.lives[iid[0]] = self.lives.get(iid[0], 0) + 1
        for pid in op.get("promote") or ():         # the queue's head moved up by this add
            self.queues[pid[0]].remove(pid)
            self.lives[pid[0]] = self.lives.get(pid[0], 0) + 1

    def new_id(self, letter, sid):
        """The source id when it is free here and greater than every id of its letter (an empty brain keeps every id), else
        the next id."""
        return sid if sid not in self.st["items"] and int(sid[1:]) > self.top.get(letter, 0) else "%s%d" % (
            letter, self.top.get(letter, 0) + 1)

    def placement(self, letter):
        """(op name, the ids that move up) of one more item of a right-brain section, as `brain_store.placement` decides it,
        from the batch's own counts: queued while the section is full once the queue's head has moved up, or while items wait."""
        n, q = self.lives.get(letter, 0), self.queues[letter]
        up = q[:max(0, s.cap(letter) - n)]
        return ("overflow-add" if len(q) > len(up) or n + len(up) >= s.cap(letter) else "add"), up

    def news(self):
        return [op for op in self.ops if op["op"] != "claim"]


def commit(d, raw, st, batch):
    """Append the batch's lines, fold them into `st` as `write` does, rewrite the caches; returns the cache warning or "". A
    failed append, cut back whole, is a refusal: nothing was written."""
    try:
        raw = s.append_many(d, raw, batch.ops)
    except OSError as e:
        left = "may be left past head.json" in str(e)  # append_many could not cut the log back: say so, as the store does
        raise s.Refused(1, "the import could not be written (%s)%s" % (s.printable(e), "" if left else ": nothing was written"))
    for b in raw[len(raw) - len(batch.ops):]:
        s.apply(st, json.loads(b.decode("utf-8")))
    return s.caches_after_append(d, st, raw)


def check_source(ctx, d, raw, st):
    """Refuse (1) a bundle that holds this very brain's chain from its first line (this brain, an older state of it, or a fork
    of it), a bundle older than one already imported from its source, and one that forks from it."""
    b, key = ctx["bundle"], ctx["key"]
    n, h = b["head"]["seq"], b["head"]["sha256"]
    restore = "to restore, the owner moves the state directory aside (brain doctor --path) and the bundle is imported into " \
              "an empty brain"
    p = 0                                           # the lines this log and the bundle share from the first, whatever key
    while p < min(len(raw), n) and ctx["hashes"].get(p + 1) == s.line_hash(raw[p]):   # the bundle claims: the log says whose
        p += 1
    if any(ctx["by_seq"][i].get("op") != "claim" for i in range(1, p + 1)):   # more than a claim alike: one chain
        if p == n:
            raise s.Refused(1, "this bundle is this brain at seq %d (it is at seq %d now): nothing to import; %s"
                          % (n, len(raw), restore))
        if ctx["full"] and p == len(raw):
            raise s.Refused(1, "this brain is the bundle's own chain at seq %d, an older state of it: an import would write its "
                             "items twice; %s" % (len(raw), restore))
        raise s.Refused(1, "this bundle shares this brain's first %d lines but not the next: a fork of this brain; ask the "
                         "owner" % p)
    seen = [(p["seq"], p.get("head")) for p in (it.get("import") for it in st["items"].values())
            if isinstance(p, dict) and p.get("key") == key and s._isint(p.get("seq"))]
    if not seen:
        return
    m = max(x[0] for x in seen)
    heads = {x[1] for x in seen if x[0] == m}
    if n < m:
        raise s.Refused(1, "an older bundle of %s (seq %d) than one already imported here (seq %d): a replay is refused"
                      % (b["project"]["name"], n, m))
    if (n == m and h not in heads) or (n > m and ctx["full"] and ctx["hashes"].get(m) not in heads):
        raise s.Refused(1, "this bundle of %s does not continue the chain imported here before (seq %d): the two brains "
                         "diverged; ask the owner" % (b["project"]["name"], m))


def chain_words(src, it):
    """{"id", "quote", "where"} of the nearest item before `it` in its supersede chain that holds the owner's words; None."""
    x, seen = it, set()
    while isinstance(x.get("supersedes"), str) and x["id"] not in seen:
        seen.add(x["id"])
        x = src["items"].get(x["supersedes"])
        if x is None:
            return None
        s_ = x.get("source") if isinstance(x.get("source"), dict) else {}
        if isinstance(s_.get("quote"), str) and s_["quote"]:
            return {"id": x["id"], "quote": s_["quote"], "where": s_.get("where")}
    return None


def shown(x):
    """A link or an anchor inside the dialog's quotes: a backslash doubled, then `"` and every character that could pass for a
    quote spelled as \\uXXXX, so one cannot read as two and no two read alike."""
    return "".join("\\\\" if c == "\\" else "\\u%04x" % ord(c) if c == '"' or s.quote_like(c) else c for c in s.clean_line(x))


def import_lines(item, sid, words):
    """The dialog's lines for one owner item: the single dialog's form, with the window's whole expiry and a `where` that names
    a source id said so, then a line with the owner's words (its own, or its chain's), its anchors and its links."""
    letter, iid, src = item["id"][0], item["id"], item["source"]
    w = src.get("where")
    frm = 'from "%s"%s' % (w, " (an id at the source)" if SUPERSEDES.fullmatch(w or "") else "")
    if letter == "G":
        head = 'Pin owner goal %s (review %s, scope %s), %s, done when "%s", not doing "%s": "%s"' % (
            iid, item["review"], item["scope"], frm, item["done"], item["not_doing"], item["text"])
    elif letter == "D":
        head = 'Pin owner decision %s (%s)%s, %s: "%s"' % (iid, s.DECISION_KIND, " (scope %s)" % item["scope"]
                                                           if item.get("scope") else "", frm, item["text"])
    else:
        head = 'Grant window %s until %s, %s: "%s"' % (iid, s.now_iso(s.parse_iso(item["expires"]))[:16].replace("T", " ") + "Z",
                                                       frm, item["text"])
    out = ["%s [was %s]" % (head, sid)]
    refs = ["%s %s" % (k, ", ".join('"%s"' % shown(x) for x in item[k])) for k in ("anchors", "links") if item[k]]
    if refs:                                        # a line of its own, each quoted: the words below cannot pass for them
        out.append("   " + "; ".join(refs))
    if src.get("quote"):                            # the words last on their line: nothing after them is theirs to fake
        out.append('   the owner\'s words "%s"' % s.escaped(src["quote"]))
    elif words:
        out.append('   the owner\'s words, on %s at the source%s: "%s"' % (
            words["id"], ' from "%s"' % words["where"] if words["where"] else "", s.escaped(words["quote"])))
    return out


def plan_owner(ctx, st, raw, ops, now, confirm=None):
    """(batch, the dialog's lines per item, the not-imported notes) of `brain owner import`: the bundle's live goals, decisions
    and windows; those already here, blocked, expired, over this brain's caps or past a full left section are named and left
    out."""
    src = ctx["st"]
    _, _, items = here_index(raw, ops, st)
    batch, lines, notes = Batch(raw, st), [], []
    for letter in s.LEFT_LETTERS:
        for it in sorted(s.live(src, letter), key=lambda i: int(i["id"][1:])):
            sid = it["id"]
            o, n = ctx["origins"][sid], batch.lives.get(letter, 0)
            words = chain_words(src, it) if letter in ("D", "W") and not it["source"].get("quote") else None
            if o in items:
                why = "already here as %s" % (here_of(batch.st, items, o, ("live", "queued")) or items[o][0])
            elif letter == "W" and (s.parse_iso(it["expires"]) or 0) <= now:
                why = "expired %s" % it["expires"][:10]
            else:
                why = blocked(ctx, st, items, it, words) or over_caps(it, words) or (
                    "%s holds %d of %d" % (dict(s.SECTIONS)[letter], n, s.cap(letter)) if n >= s.cap(letter) else None)
            if why:
                notes.append("%s (%s)" % (sid, why))
                continue
            item = {"id": batch.new_id(letter, sid), "kind": it["kind"], "pinned": letter == "D", "text": it["text"],
                    "source": {"type": "owner", "quote": it["source"].get("quote"), "where": it["source"]["where"]},
                    "expires": it.get("expires"), "links": list(it.get("links") or []),
                    "anchors": list(it.get("anchors") or []), "supersedes": None}
            if letter == "G":
                item.update({k: it[k] for k in s.GOAL_FIELDS})
            elif letter == "D" and it.get("scope") is not None:
                item["scope"] = it["scope"]
            prov = provenance(ctx, sid, now)
            if words:
                prov["words"] = words
            item["import"] = prov
            op = {"op": "owner-add", "item": item, "t": source_time(it, now), "by": s.by()}
            if confirm:
                op["confirm"] = confirm
            batch.add(op)
            lines.append(import_lines(item, sid, words))
    return batch, lines, notes


def import_dialog(ctx, lines, notes):
    """(the owner import's dialog text, its SHA-256 with the bundle's): the lines of each owner item that lands, numbered."""
    b = ctx["bundle"]
    p, h = b["project"], b["head"]
    chain = ("chain verified to head %s at seq %d" % (h["sha256"][:12], h["seq"]) if ctx["full"] else
             "a selection: its chain is not carried; head %s at seq %d" % (h["sha256"][:12], h["seq"]))
    if ctx["carried"]:                              # the chain does not vouch for these lines: nothing they wrote lands
        chain += ", but for %d line%s carrying a placeholder" % (len(ctx["carried"]), "" if len(ctx["carried"]) == 1 else "s")
    out = ["Import %d owner item%s from the brain of %s (key %s, %s; bundle %s):"
           % (len(lines), "" if len(lines) == 1 else "s", p["name"], p["key"], chain, ctx["sha"][:12])]
    for i, item in enumerate(lines, 1):
        out += ["%d. %s" % (i, item[0])] + item[1:]
    if notes:
        out.append("Not imported: %s." % "; ".join(notes))
    out.append("Each keeps the owner's words verbatim and a provenance line naming %s and its chain head." % p["name"])
    text = "\n".join(out)
    return text, hashlib.sha256((text + "\n" + ctx["sha"]).encode("utf-8")).hexdigest()


def owner_import_ask(d, path):
    """(dialog text, its digest) that guard-owner asks with for `brain owner import FILE`; Refused when nothing would land, or
    when the CLI would refuse the bundle (its text through the sensitive-value filter first), so the owner never approves a
    refused import."""
    ctx = import_context(path)
    s.sanitize(filter_dir(d), import_texts(ctx))
    raw, ops = s.verify(d) if os.path.isfile(os.path.join(d, "hot.jsonl")) else ([], [])
    st = s.fold(ops)
    check_source(ctx, d, raw, st)
    _, lines, notes = plan_owner(ctx, st, raw, ops, time.time())
    if not lines:
        raise s.Refused(1, "nothing to import from %s: %s" % (s.printable(os.path.basename(path)), "; ".join(notes) or
                                                           "it holds no live goal, decision or window"))
    text, digest = import_dialog(ctx, lines, notes)
    if s.units(text) > DIALOG_MAX:
        raise s.Refused(1, "the dialog would be %d units, past the %d of one dialog: export by --scope for smaller bundles"
                      % (s.units(text), DIALOG_MAX))
    return text, digest


def owner_import(args, ns):
    """`brain owner import FILE`: the bundle's goals, decisions and windows, only with a fresh record of the one dialog that
    listed them, whose text this plan must give again (the bundle and this brain unchanged since)."""
    s.check_caller()
    s.check_config()
    if not ns.bundle:
        raise s.Refused(64, "brain owner import FILE")
    ctx = import_context(ns.bundle)
    d = s.state_dir()
    s.sanitize(filter_dir(d), import_texts(ctx))
    now = time.time()
    with s.locked(d):
        raw, ops = s.verify(d)
        st = s.fold(ops)
        s.check_writer(st)
        rec, path = s.find_record(d, args, st)
        if rec is None:
            raise s.Refused(6, s.NO_DIALOG + " (no fresh, matching, unused record of an approved dialog in this session)")
        ans = s.answerers()
        if ans:
            raise s.Refused(6, "owner items are refused while something can answer the permission prompt in place of a human: "
                          + "; ".join(ans))
        check_source(ctx, d, raw, st)
        s.test_pause()
        batch, lines, notes = plan_owner(ctx, st, raw, ops, now, {"asked": True, "mode": rec["mode"], "record": rec["id"]})
        if rec.get("plan") != import_dialog(ctx, lines, notes)[1]:
            raise s.Refused(6, "the bundle or this brain changed since the owner's dialog, or the dialog was not for this import: "
                             "nothing was written; ask the owner again")
        if not batch.news():
            raise s.Refused(1, "nothing to import")
        warn = commit(d, raw, st, batch)
        with contextlib.suppress(OSError):
            os.unlink(path)
    s.episode_line(d, s.session_id(), "owner-import", key=ctx["key"], seq=ctx["bundle"]["head"]["seq"], landed=len(batch.news()))
    landed_ids = ["%s as %s" % (op["item"]["import"]["id"], op["item"]["id"]) for op in batch.news()]
    return "imported from %s (key %s): %s%s\nnext: `brain import FILE` lands the right brain and replays the ledger%s" % (
        ctx["bundle"]["project"]["name"], ctx["key"], "; ".join(landed_ids),
        "\nnot imported: %s" % "; ".join(notes) if notes else "", warn)


def only_letters(only):
    """The letters `--only` names (`TF`, `T,F`), every one of the right brain; None without it."""
    if not only:
        return None
    letters = set(only.replace(",", "").upper())
    if not letters or letters - set(RIGHT_LETTERS):
        raise s.Refused(64, "--only takes letters of the right brain (%s), like TF" % "".join(RIGHT_LETTERS))
    return letters


def plan_right(ctx, st, ops, raw, letters, now):
    """(batch, report) of `brain import`: the right brain's live then queued items as `brain op add` writes them, references
    remapped (an item whose goal or focus has not landed waits; a Next item whose focus is not live at the source lands untied,
    as the source shows it), then the ledger's events of what is here."""
    src = ctx["st"]
    lines_here, same, items = here_index(raw, ops, st)
    batch, mapped = Batch(raw, st), {}
    rep = {k: [] for k in ("landed", "waiting", "skipped", "already")}

    def now_id(sid, ok=("live",), index=items):
        if sid in mapped:
            return mapped[sid]
        return here_of(batch.st, index, ctx["origins"].get(sid), ok) if sid in ctx["origins"] else None

    for letter in RIGHT_LETTERS:
        if letters and letter not in letters:
            continue
        for it in sorted(s.live(src, letter), key=lambda i: int(i["id"][1:])) + s.queue(src, letter):
            sid, refs, wait, note = it["id"], {}, None, ""
            o = ctx["origins"][sid]
            if o in items:
                rep["already"].append("%s (here %s)" % (sid, here_of(batch.st, items, o, ("live", "queued")) or items[o][0]))
                continue
            why = blocked(ctx, st, items, it)
            goal = s.goal_of(src, it) if letter == "P" else s.last_of(src, it["goal"]) if letter == "S" and it.get("goal") else None
            focus = s.last_of(src, it["focus"]) if letter == "X" and isinstance(it.get("focus"), str) else None
            for key_, ref in (("goal", goal), ("focus", focus)):
                if ref is None or why or wait:
                    continue
                if (src["items"].get(ref) or {}).get("status") != "live":
                    if key_ == "focus":
                        note = " (untied: its focus %s is not live at the source)" % ref
                    else:
                        why = "its goal %s is not live at the source" % ref
                elif now_id(ref) is None:
                    wait = "its %s %s has not landed here" % (key_, ref)
                else:
                    refs[key_] = now_id(ref)
            why = why or (None if wait else over_caps(it))
            if why or wait:
                rep["skipped" if why else "waiting"].append("%s (%s)" % (sid, why or wait))
                continue
            nid = batch.new_id(letter, sid)
            name, up = batch.placement(letter)
            item = {"id": nid, "kind": it["kind"], "pinned": False, "text": it["text"],
                    "source": (dict(s.SESSION_SOURCE, quote=it["source"]["quote"], where=it["source"]["where"])
                               if letter in ("P", "R") else dict(s.SESSION_SOURCE)),
                    "expires": it.get("expires"), "links": list(it.get("links") or []),
                    "anchors": list(it.get("anchors") or []), "supersedes": None}
            if it.get("closes"):
                item["closes"] = list(it["closes"])
            item.update({k: it[k] for k in ("due", "no_goal") if it.get(k) is not None})
            item.update(refs)
            item["import"] = provenance(ctx, sid, now)
            op = {"op": name, "item": item, "t": source_time(it, now), "by": s.by()}
            if up:
                op["promote"] = up
            batch.add(op)
            mapped[sid] = nid
            rep["landed"].append("%s as %s%s%s" % (sid, nid, " (queued)" if name == "overflow-add" else "", note))
    rep.update(replay(ctx, batch, lines_here, lambda sid, ok=("live",): now_id(sid, ok, same), ops, now,
                      lambda sid: now_id(sid, ("live", "queued"))))
    rep["owner"] = [it["id"] for letter in s.LEFT_LETTERS for it in sorted(s.live(src, letter), key=lambda i: int(i["id"][1:]))
                    if ctx["origins"][it["id"]] not in items and not blocked(ctx, st, items, it, chain_words(src, it)
                                                                                 if letter in ("D", "W") and not it["source"]
                                                                                 .get("quote") else None)
                    and not (letter == "W" and (s.parse_iso(it["expires"]) or 0) <= now)]
    rep["retired"] = ["%s (here %s)" % (sid, here_of(batch.st, items, o, ("live", "queued")))
                      for sid, o in sorted(ctx["origins"].items(), key=lambda kv: (kv[0][0], int(kv[0][1:])))
                      if o in items and here_of(batch.st, items, o, ("live", "queued"))
                      and src["items"][sid]["status"] not in ("live", "queued")]
    return batch, rep


def replay(ctx, batch, lines_here, now_id, ops, now, stands=lambda sid: None):
    """The ledger of what is here, replayed into the batch: the source's events (held, broke, a hit, progress) of each item
    that landed here (live or queued) and of each rule code (`[S07]`) no `owner-demote` retired, at the source or here (an
    older brain's op: the owner's act, which a replay would undo), a superseded goal's progress onto the goal it continues
    as, and the items' touch and older hit ops, in source order, each with its source time and `import` (its origin and when
    it was written here). An event whose origin is already here, or whose line carries a placeholder, is not written; an
    event goes only to the item that is the same item by origin, never to one that only continues it. Its session reads
    `~imported@<key>:<source session>` (the ledger shows `imported`), never one of this brain."""
    src, key = ctx["st"], ctx["key"]
    events, wait, counts, left = [], {}, {}, 0
    retired = {op.get("soul") for op in list(ctx["ops"]) + list(ops) if op.get("op") == "owner-demote"}
    for k, v in ctx["led"].items():
        if k.startswith("["):
            if k[1:-1] in retired:                  # a code demoted at the source or here: retired, its events stay there
                continue
            target = ("soul", k[1:-1])
        else:
            end = s.last_of(src, k) if k[:1] == "G" else k   # a goal's progress reads across its chain: onto its successor
            nid = now_id(end, ("live", "queued"))
            if nid is None:                         # an item here only through an edit of it: its evidence stays behind
                if (src["items"].get(end) or {}).get("status") in ("live", "queued") and not stands(end):
                    wait[end] = wait.get(end, 0) + len(v["events"])
                continue
            target = ("id", nid)
        events += [(e["seq"], target, e, None) for e in v["events"]]
    for op in ctx["ops"]:
        nid = now_id(op.get("id"), ("live", "queued")) if op.get("op") in ("touch", "hit") else None
        if nid:
            events.append((op["seq"], ("id", nid), None, op))
    for seq, (kind, value), e, old in sorted(events, key=lambda x: x[0]):
        if seq in ctx["carried"]:                   # counted before its origin is read: a carried line names none
            left += 1
            continue
        o = origin(ctx["by_seq"][seq], ctx["hashes"].get(seq))
        if o in lines_here:
            continue
        imp = {"key": key, "seq": seq, "line": o, "at": s.now_iso(now)}
        if old is not None:
            op = {"op": old["op"], "id": value, "t": old["t"]}
        elif e["result"] == "progress":
            op = {"op": "progress", "id": value, "measure": e["measure"], "pointer": e["pointer"], "t": e["t"]}
        else:
            op = {"op": "evidence", "result": e["result"], kind: value, "t": e["t"], "session": imported_label(e["session"], key)}
            op.update({f: e[f] for f in ("pointer", "differed", "via") if e.get(f)})
        batch.add(dict(op, by=s.by(), **{"import": imp}))
        lines_here.add(o)
        label = "[%s]" % value if kind == "soul" else value
        counts[label] = counts.get(label, 0) + 1
    return {"replayed": counts, "events_wait": wait, "events_left": left}


IMPORTED_LABEL = re.compile(r"~imported@[0-9a-f]{12}:[A-Za-z0-9-]{1,8}")


def imported_label(session, key):
    """A replayed event's session: a label an import wrote, kept as it is when it has exactly that shape (so imported evidence
    imported again keeps its sessions apart), else `~imported@<key>:<8 plain characters of the source's>`: never a session of
    this brain, and never text from the bundle longer than those 8."""
    if IMPORTED_LABEL.fullmatch(session):
        return session
    return "~imported@%s:%s" % (key, re.sub(r"[^A-Za-z0-9-]", "", session.lstrip("~"))[:8] or "unknown")


def import_bundle(path, only=None):
    """`brain import FILE [--only LETTERS]`: the session's half of an import, as `brain op` writes (the writer, under the
    lock, one batch): the right brain's items, then the ledger of what is here. Prints what landed, waits, was skipped or
    was here already, and the owner items left for `brain owner import FILE`."""
    s.check_caller()
    s.check_config()
    letters = only_letters(only)
    ctx = import_context(path)
    d = s.state_dir()
    s.sanitize(filter_dir(d), import_texts(ctx))
    now = time.time()
    with s.locked(d):
        raw, ops = s.verify(d)
        st = s.fold(ops)
        s.check_writer(st)
        check_source(ctx, d, raw, st)
        s.test_pause()
        batch, rep = plan_right(ctx, st, ops, raw, letters, now)
        warn = commit(d, raw, st, batch) if batch.news() else ""
    b = ctx["bundle"]
    s.episode_line(d, s.session_id(), "import", key=ctx["key"], seq=b["head"]["seq"], landed=len(rep["landed"]),
                   events=sum(rep["replayed"].values()))
    out = ["imported from %s (key %s), %s head %s… (seq %d):" % (
        b["project"]["name"], ctx["key"], "its chain verified to" if ctx["full"] else "a selection (its chain not carried),",
        b["head"]["sha256"][:12], b["head"]["seq"])]
    for k, title in (("landed", "landed"), ("waiting", "waiting"), ("skipped", "skipped"), ("already", "already here"),
                     ("retired", "retired at the source since")):
        if rep[k]:
            out.append("%s: %s" % (title, "; ".join(rep[k])))
    if rep["replayed"]:
        out.append("ledger: %d events replayed (%s)" % (sum(rep["replayed"].values()), ", ".join(
            "%s %d" % kv for kv in sorted(rep["replayed"].items()))))
    if rep["events_wait"]:
        out.append("ledger waiting for its item: %s" % ", ".join("%s %d" % kv for kv in sorted(rep["events_wait"].items())))
    if rep["events_left"]:
        out.append("ledger left out: %d events a line carrying a placeholder wrote" % rep["events_left"])
    if rep["owner"]:
        out.append("owner items, for the owner's dialog: %s (`brain owner import FILE`, alone in its turn, then `brain import "
                   "FILE` again)" % ", ".join(rep["owner"]))
    if not batch.news():
        out.append("nothing new to write")
    return "\n".join(out) + warn


# --- backup ---------------------------------------------------------------------------------------------------------------------
# The owner names a private directory through the dialog (`brain owner backup DIR`); it is kept in the state directory, never in
# the log, so no bundle carries its path. `brain backup` writes a full bundle there. What the hooks read of it (is one due, the
# card and doctor lines) is brain_store's.

BACKUP_LOCK = "backup.lock"
BACKUP_KEEP = 30                    # bundles of this project kept in the place, the newest
BACKUP_EVERY = 24                   # hours between two backups, unless the owner named another interval
BACKUP_NAME = re.compile(r"(?P<name>[A-Za-z0-9._-]{1,40})-(?P<key>[0-9a-f]{12})-(?P<t>[0-9]{8}T[0-9]{6}Z)-s(?P<seq>[0-9]{1,9})"
                         r"\.brain\.json")


def place_problem(place, project=None):
    """Why `place` cannot hold this project's backups, None when it can: an absolute path, an existing directory and not a
    symlink, owned by this account, with no access for group or others, outside every git work tree and git directory (so
    never a repository, the kit's public export included), the project's work tree and the brain's state root."""
    if not isinstance(place, str) or not os.path.isabs(place):
        return "it is not an absolute path"
    if os.path.normpath(place) != (place.rstrip("/") or "/") or place.startswith("//"):
        return "name it plainly, with no `.`, `..` or `//` (the system and a lexical reading could part at a link)"
    place = os.path.normpath(place)                 # `link/` would make lstat follow the link
    try:
        st_ = os.lstat(place)
    except OSError:
        return "it does not exist"
    if stat.S_ISLNK(st_.st_mode):
        return "it is a symlink: name the directory itself"
    if not stat.S_ISDIR(st_.st_mode):
        return "it is not a directory"
    if st_.st_uid != os.getuid():
        return "it is not this account's"
    if st_.st_mode & 0o077:
        return "group or others can use it (mode %04o): chmod 700 makes it private" % (st_.st_mode & 0o7777)
    if "true" in (s._git(place, "rev-parse", "--is-inside-work-tree"), s._git(place, "rev-parse", "--is-inside-git-dir")):
        return "it lies in a git repository: a backup never goes where a commit could publish it"
    roots = [r for r in (s.project_root(project) if project else s.project_root(), s.config_root()) if r]
    if any(within(place, r) for r in roots):
        return "it lies in the project's work tree"
    if within(place, s.state_root()):
        return "it lies in the brain's state root, the thing it backs up"
    return None


def backup_prune(place, me, keep=BACKUP_KEEP):
    """Delete this project's bundles in `place` past the newest `keep`: only regular files of this account named as a backup
    of this project (`me`: its project id)."""
    mine = []
    for name in os.listdir(place):
        m = BACKUP_NAME.fullmatch(name)
        if not m or (m.group("name"), m.group("key")) != (me["name"], me["key"]):
            continue
        p = os.path.join(place, name)
        with contextlib.suppress(OSError):
            st_ = os.lstat(p)
            if stat.S_ISREG(st_.st_mode) and st_.st_uid == os.getuid():
                mine.append((m.group("t"), int(m.group("seq")), p))
    for _, _, p in sorted(mine, reverse=True)[keep:]:
        with contextlib.suppress(OSError):
            os.unlink(p)


def backup(if_due=False, now=None):
    """`brain backup [--if-due]`: one full bundle into the place the owner named, the newest BACKUP_KEEP kept; with `--if-due`
    only when one is due, and silent otherwise. A second run while one runs stops at its lock. The result goes into
    backup-last.json and the Episode Log."""
    d = s.state_dir()
    if not os.path.isfile(os.path.join(d, "hot.jsonl")):
        if if_due:
            return None
        raise s.Refused(1, "no brain state for this project yet: nothing to back up")
    conf = s.backup_conf(d)
    if conf is None:
        if if_due:
            return None
        raise s.Refused(1, "no backup place is named: the owner names one through the dialog (`brain owner backup DIR`)")
    fd = os.open(os.path.join(d, BACKUP_LOCK), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            if if_due:
                return None
            raise s.Refused(1, "another backup of this brain is running")
        now = time.time() if now is None else now
        last, head = s.backup_last(d), s.read_head(d)
        if if_due and not s.backup_due(conf, last, head, now):
            return None
        try:
            why = place_problem(conf["dir"])
            if why:
                raise s.Refused(1, "the backup place %s is refused: %s" % (conf["dir"], why))
            b, _ = build_bundle(d, "all", now)
            data = (s.dumps(b) + "\n").encode("utf-8")
            if len(data) > BUNDLE_MAX:
                raise s.Refused(1, "the bundle would be %d bytes, past the %d a bundle may hold" % (len(data), BUNDLE_MAX))
            me = b["project"]
            name = "%s-%s-%s-s%d.brain.json" % (me["name"], me["key"], time.strftime("%Y%m%dT%H%M%SZ", time.gmtime(now)),
                                                b["head"]["seq"])
            write_new(os.path.join(conf["dir"], name), data)
            backup_prune(conf["dir"], me)
        except (s.Refused, OSError) as e:
            last["failed"] = {"t": now, "error": s.printable(e.msg if isinstance(e, s.Refused) else e.__class__.__name__)[:200]}
            s._write_file(os.path.join(d, s.BACKUP_LAST), s.dumps(last) + "\n")
            s.episode_line(d, s.session_id(), "backup", ok=False, error=last["failed"]["error"])
            if isinstance(e, s.Refused):
                raise
            raise s.Refused(1, "the backup could not be written (%s)" % e.__class__.__name__)
        last = {"ok": {"t": now, "seq": b["head"]["seq"], "sha256": b["head"]["sha256"], "file": name, "dir": conf["dir"]},
                "failed": None}
        s._write_file(os.path.join(d, s.BACKUP_LAST), s.dumps(last) + "\n")
        s.episode_line(d, s.session_id(), "backup", ok=True, seq=b["head"]["seq"], file=name)
        return "backed up seq %d (head %s…) to %s" % (b["head"]["seq"], b["head"]["sha256"][:12], os.path.join(conf["dir"], name))
    finally:
        os.close(fd)


def backup_args(ns):
    """(place or "off", hours) of `brain owner backup`: an absolute directory with plain characters, or `off`; `--every` is
    whole hours from 1 to 720, 24 when left out; anything else is a usage error (rc 64)."""
    place, every = ns.place, getattr(ns, "every", None)
    if place == "off":
        if every is not None:
            raise s.Refused(64, "brain owner backup off takes no --every")
        return place, None
    if not os.path.isabs(place):
        raise s.Refused(64, "brain owner backup DIR (an absolute path) [--every HOURS], or brain owner backup off")
    s.check_text("place", place)
    c = '"' if '"' in place else s.quote_like(place)
    if c:
        raise s.Refused(1, "the place holds U+%04X, a quote or a character that passes for one: the dialog quotes it" % ord(c))
    hours = BACKUP_EVERY if every is None else int(every) if every.isascii() and every.isdigit() else 0
    if not 1 <= hours <= 720:
        raise s.Refused(64, "--every takes hours, from 1 to 720")
    return place, hours


def owner_backup_line(d, ns, project=None):
    """guard-owner's line for `brain owner backup`: the place checked first, so the owner never approves a refused one."""
    place, hours = backup_args(ns)
    if place == "off":
        conf = s.backup_conf(d)
        if conf is None:
            raise s.Refused(1, "no backup place is named: nothing to stop")
        return 'Stop backing up this project\'s brain (it went to "%s")' % conf["dir"]
    why = place_problem(place, project)
    if why:
        raise s.Refused(1, "the backup place is refused: %s" % why)
    return ('Back up this project\'s brain to "%s" every %d h (a private directory: yours, mode 0700, outside every git work '
            'tree)' % (place, hours))


def owner_backup(args, ns):
    """`brain owner backup DIR [--every HOURS]` or `off`: the owner names (or stops) the private place of this project's
    backups, with a fresh record of the dialog; kept in the state directory, never in the log."""
    s.check_caller()
    place, hours = backup_args(ns)
    d = s.state_dir()
    with s.locked(d):
        _, ops = s.verify(d)
        rec, path = s.find_record(d, args, s.fold(ops))
        if rec is None:
            raise s.Refused(6, s.NO_DIALOG + " (no fresh, matching, unused record of an approved dialog in this session)")
        ans = s.answerers()
        if ans:
            raise s.Refused(6, "owner items are refused while something can answer the permission prompt in place of a human: "
                          + "; ".join(ans))
        if place == "off":
            conf = s.backup_conf(d)
            if conf is None:
                raise s.Refused(1, "no backup place is named: nothing to stop")
            os.unlink(os.path.join(d, s.BACKUP_FILE))
            msg = "backups stopped (they went to %s)" % conf["dir"]
        else:
            why = place_problem(place)
            if why:
                raise s.Refused(1, "the backup place is refused: %s" % why)
            s._write_file(os.path.join(d, s.BACKUP_FILE), s.dumps({"dir": os.path.normpath(place), "every": hours,
                                                              "named": s.now_iso(), "record": rec["id"]}) + "\n")
            last = s.backup_last(d)
            if last["failed"]:                      # a failure was the old place's: the new one has not failed
                s._write_file(os.path.join(d, s.BACKUP_LAST), s.dumps(dict(last, failed=None)) + "\n")
            msg = ("this project's brain is backed up to %s every %d h; one is due now (`brain backup`, or the next "
                   "SessionStart starts it)" % (os.path.normpath(place), hours))
        with contextlib.suppress(OSError):
            os.unlink(path)
    s.episode_line(d, s.session_id(), "backup-place", every=hours)
    return msg
