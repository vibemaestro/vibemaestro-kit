"""vibemaestro-brain store: Hot Memory as one hash-chained op log, its fold, guards, caches and render.

Truth is `hot.jsonl`, one op per line; each line's `prev` is the SHA-256 of the line before (64 zeros for the first), and
`head.json` holds the last `seq` and hash. Every write takes the lock, verifies the whole chain and the head (rc 5 on any
mismatch), folds the log, checks the op, appends one line, rewrites `head.json` atomically, and rewrites the caches
(`hot.json`, `archive.jsonl`, `owner.json`). A cache is used only when its `folded_from` equals the head and its digest matches
its content; otherwise the log is folded again.

Owner items (`D` decisions, `W` windows) are written only by `brain owner …` with a fresh, matching, unused "asked" record
(`record_asked`, called by B1.2's guard-owner hook). Like BatonRun, this guards against slips, not same-user forgery.
Standard library only.
"""
import contextlib
import datetime
import fcntl
import glob
import hashlib
import json
import os
import pwd
import re
import secrets
import stat
import subprocess
import sys
import time
import unicodedata

KINDS = {"decision": "D", "window": "W", "now": "N", "next": "X", "trap": "T"}
OWNER_LETTERS = ("D", "W")
SECTIONS = (("D", "Pinned (owner)"), ("W", "Windows"), ("N", "Now"), ("X", "Next"), ("T", "Traps"))
CAPS = {"D": 10, "W": 5, "N": 3, "X": 5, "T": 4}       # design values: 27 lines of ≤ 200 chars fit the render cap
RENDER_CAP = 6000
LINE_MAX = 200
WARN_RATIO = 0.85
TEXT_MAX = 150
FIELD_MAX = {"text": TEXT_MAX, "quote": 300, "where": 60, "pointer": 60, "reason": 150, "anchor": 80, "link": 80}
LIST_MAX = 8                                        # anchors, links
BUDGET_N, BUDGET_WINDOW = 5, 30 * 60                # retirements per session in any 30 minutes
SHRINK_MIN = 0.6                                    # supersede keeps ≥ 60% of the first item of its chain
RECORD_MAX_AGE = 600                                # seconds an "asked" record stays usable
DIALOG_MODES = ("default", "acceptEdits", "auto")
# not "Cn": an older Python's tables call a newer emoji unassigned; noncharacters (never assigned) are refused by is_bad
BAD_CATEGORIES = ("Cc", "Cf", "Cs", "Co", "Zl", "Zp")
# letters and symbols that render as nothing: Hangul fillers, the blank braille pattern, Khmer inherent vowels, the grapheme joiner
INVISIBLE = frozenset((0x034F, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x2800, 0x3164, 0xFFA0))
# Unicode's Default_Ignorable_Code_Point ranges: rendered as nothing, so refused, even where an older Python calls them
# unassigned. The one exception is SELECTORS (text or emoji presentation), one, right after a non-ASCII symbol or in a keycap
# (`#`, `*` or a digit, the selector, U+20E3): after a letter it changes nothing on screen, so a choice of selector, like any
# other selector or a run of them, could carry text the owner never sees in the dialog
DEFAULT_IGNORABLE = ((0x00AD, 0x00AD), (0x034F, 0x034F), (0x061C, 0x061C), (0x115F, 0x1160), (0x17B4, 0x17B5),
                     (0x180B, 0x180F), (0x200B, 0x200F), (0x202A, 0x202E), (0x2060, 0x206F), (0x3164, 0x3164),
                     (0xFE00, 0xFE0F), (0xFEFF, 0xFEFF), (0xFFA0, 0xFFA0), (0xFFF0, 0xFFF8), (0x1BCA0, 0x1BCA3),
                     (0x1D173, 0x1D17A), (0xE0000, 0xE0FFF))
SELECTORS = (0xFE0E, 0xFE0F)
# characters that can pass for the dialog's `"` (or flip the line's order) inside the quoted source or pointer, which sit
# before the text: an imitation there would show a fake text first (round 5); the text itself is last and needs none of this
QUOTE_NAMES = ("QUOTATION", "PRIME", "GERSHAYIM", "DITTO", "DOUBLE APOSTROPHE", "DOUBLE ACUTE")
MARKS_RUN_MAX = 8                                   # combining marks in a row: Vietnamese 2, Tibetan stacks 6; 149 smear a line
EMOJI_BASES = frozenset((0x203C, 0x2049, 0x2139, 0x3030, 0x303D))   # emoji with a FE0F sequence outside So and Sm: ‼ ⁉ ℹ 〰 〽
GENESIS = "0" * 64
NO_DIALOG = ("owner items need a session that can show Claude Code's permission dialog; ask the owner in an interactive "
             "session")
ID_RE = re.compile(r"^[DWNXT][1-9][0-9]{0,5}$")
MANAGED_SETTINGS = ("/etc/claude-code/managed-settings.json", "/Library/Application Support/ClaudeCode/managed-settings.json")


class Refused(Exception):
    """A refusal with its exit code: 1 refused, 3 not the writer, 4 worker, 5 log/head mismatch, 6 owner, 64 usage."""

    def __init__(self, rc, msg):
        Exception.__init__(self, msg)
        self.rc = rc
        self.msg = msg


# --- where state lives --------------------------------------------------------------------------------------------------------

def account_home():
    """The account's home from the password database: HOME can be emptied or pointed elsewhere, this cannot."""
    try:
        return pwd.getpwuid(os.getuid()).pw_dir
    except KeyError:
        return ""


def home():
    """HOME when it is an absolute path, else the account's home (an empty HOME would make every path relative)."""
    h = os.environ.get("HOME", "")
    return h if os.path.isabs(h) else account_home()


def config_dir(cwd=None):
    """Claude Code's config directory as this process sees it: CLAUDE_CONFIG_DIR (a relative one from `cwd`), else ~/.claude."""
    c = os.environ.get("CLAUDE_CONFIG_DIR", "")
    return os.path.join(cwd or os.getcwd(), c) if c else os.path.join(home(), ".claude")


def state_root():
    x = os.environ.get("XDG_STATE_HOME", "")
    base = x if os.path.isabs(x) else os.path.join(home(), ".local", "state")
    return os.path.join(base, "vibemaestro", "brain")


def project_dir(cwd=None):
    """The git common directory (so every worktree shares one brain), else the working directory."""
    cwd = cwd or os.getcwd()
    try:
        out = subprocess.run(["git", "rev-parse", "--git-common-dir"], cwd=cwd, capture_output=True, text=True, timeout=10)
        if out.returncode == 0 and out.stdout.strip():
            return os.path.realpath(os.path.join(cwd, out.stdout.strip()))
    except (OSError, subprocess.SubprocessError):
        pass
    return os.path.realpath(cwd)


def project_root(cwd=None):
    cwd = cwd or os.getcwd()
    try:
        out = subprocess.run(["git", "rev-parse", "--show-toplevel"], cwd=cwd, capture_output=True, text=True, timeout=10)
        if out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip()
    except (OSError, subprocess.SubprocessError):
        pass
    return os.path.realpath(cwd)


def state_dir(cwd=None):
    """`<state root>/<base name>-<12 hex of the SHA-1 of the project path>`; not created here."""
    p = project_dir(cwd)
    name = os.path.basename(os.path.dirname(p)) if os.path.basename(p) == ".git" else os.path.basename(p)
    name = re.sub(r"[^A-Za-z0-9._-]", "_", name)[:40] or "project"
    return os.path.join(state_root(), "%s-%s" % (name, hashlib.sha1(p.encode("utf-8")).hexdigest()[:12]))


def ensure_dir(d):
    """Create the state directory and `asked/`; every directory created from `vibemaestro/` down is 0700, and the brain's own
    (the root, the state directory, `asked/`) are put back to 0700 when an earlier build left them open."""
    root = state_root()
    for p in (os.path.dirname(root), root, d, os.path.join(d, "asked")):
        if os.path.isdir(p):
            st_ = os.lstat(p)
            if (p != os.path.dirname(root) and stat.S_ISDIR(st_.st_mode) and st_.st_uid == os.getuid()
                    and st_.st_mode & 0o077):
                os.chmod(p, 0o700)
            continue
        os.makedirs(os.path.dirname(p), exist_ok=True)
        try:
            os.mkdir(p, 0o700)
        except FileExistsError:
            continue
        os.chmod(p, 0o700)


@contextlib.contextmanager
def locked(d):
    ensure_dir(d)
    fd = os.open(os.path.join(d, "lock"), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        os.close(fd)


def test_pause():
    """BRAIN_TEST_PAUSE_MS, honoured only with BRAIN_TEST=1 and capped at 2,000 ms: makes the lock test deterministic."""
    if os.environ.get("BRAIN_TEST") != "1":
        return
    try:
        ms = min(int(os.environ.get("BRAIN_TEST_PAUSE_MS", "0")), 2000)
    except ValueError:
        return
    if ms > 0:
        time.sleep(ms / 1000.0)


def _write_file(path, data):
    """Atomic write, 0600."""
    tmp = "%s.%d.tmp" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except OSError:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def now_iso(t=None):
    return datetime.datetime.fromtimestamp(time.time() if t is None else t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(s):
    try:
        d = datetime.datetime.strptime(s.replace("+00:00", "Z"), "%Y-%m-%dT%H:%M:%SZ")
    except (ValueError, AttributeError):
        return None
    return d.replace(tzinfo=datetime.timezone.utc).timestamp()


# --- the log ------------------------------------------------------------------------------------------------------------------

def line_hash(b):
    return hashlib.sha256(b).hexdigest()


def dumps(obj):
    return json.dumps(obj, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


def read_head(d):
    p = os.path.join(d, "head.json")
    if not os.path.exists(p):
        return None
    try:
        h = json.load(open(p, encoding="utf-8"))
        return {"seq": int(h["seq"]), "sha256": str(h["sha256"])}
    except (ValueError, KeyError, TypeError, OSError, OverflowError):
        return {"seq": -1, "sha256": "unreadable"}


_MD_VERSION = re.compile(r"^## Brain · hot memory v(\d{1,9}) ")


def cache_seq(d):
    """(seq, file): the highest `seq` a cache says it was folded from, and which cache says it ((0, None) when none does).
    `hot.md` counts too, through the version in its title, so deleting the log, the head and the three JSON caches is seen."""
    best = (0, None)
    for name in ("hot.json", "archive.jsonl", "owner.json", "hot.md"):
        try:
            with open(os.path.join(d, name), encoding="utf-8") as f:
                first = f.readline()
            if name == "hot.md":
                m = _MD_VERSION.match(first)
                seq = int(m.group(1)) if m else 0
            else:
                seq = int(json.loads(first)["folded_from"]["seq"])
        except (OSError, ValueError, KeyError, TypeError, OverflowError, AttributeError, UnicodeDecodeError):
            continue
        if seq > best[0]:
            best = (seq, name)
    return best


def verify(d):
    """(raw lines, ops) of a log whose chain and head agree; raises Refused(5) naming the first break."""
    p = os.path.join(d, "hot.jsonl")
    raw = []
    if os.path.lexists(p):
        try:
            with open(p, "rb") as f:
                data = f.read()
        except OSError as e:
            raise Refused(5, "hot.jsonl cannot be read (%s); the log does not match head.json" % e.__class__.__name__)
        if data and not data.endswith(b"\n"):
            raise Refused(5, "hot.jsonl: the last line is cut (no newline); the log does not match head.json")
        raw = data.split(b"\n")[:-1] if data else []
    ops, prev = [], GENESIS
    for i, b in enumerate(raw, 1):
        try:
            o = json.loads(b.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            raise Refused(5, "hot.jsonl line %d: not JSON; the chain is broken" % i)
        if not isinstance(o, dict) or o.get("seq") != i:
            raise Refused(5, "hot.jsonl line %d: seq is not %d; the chain is broken" % (i, i))
        if o.get("prev") != prev:
            raise Refused(5, "hot.jsonl line %d: prev does not match line %d; the chain is broken (a hand edit?)" % (i, i - 1))
        prev = line_hash(b)
        ops.append(o)
    head = read_head(d)
    cs, name = cache_seq(d)
    if cs > len(raw):
        raise Refused(5, "%s was made from seq %d, past the log's %d lines: the log lost lines; writes stop, the evidence "
                         "stays" % (name, cs, len(raw)))
    if head is None:
        if raw:
            raise Refused(5, "head.json is missing while hot.jsonl has %d lines" % len(raw))
    elif head != {"seq": len(raw), "sha256": prev if raw else GENESIS}:
        raise Refused(5, "head.json (seq %s) does not match the log's tail (seq %d): a truncated or edited log stops all "
                         "writes; the evidence stays" % (head.get("seq"), len(raw)))
    return raw, ops


def head_of(raw):
    return {"seq": len(raw), "sha256": line_hash(raw[-1]) if raw else GENESIS}


def append(d, raw, op):
    """Append one op after `raw` (already verified under the lock); returns the new raw list."""
    op = dict(op)
    op["seq"] = len(raw) + 1
    op["prev"] = line_hash(raw[-1]) if raw else GENESIS
    b = dumps(op).encode("utf-8")
    fd = os.open(os.path.join(d, "hot.jsonl"), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        os.write(fd, b + b"\n")
        os.fsync(fd)
    finally:
        os.close(fd)
    raw = raw + [b]
    _write_file(os.path.join(d, "head.json"), dumps(head_of(raw)) + "\n")
    return raw


# --- the fold -----------------------------------------------------------------------------------------------------------------

def empty_state():
    return {"version": 0, "items": {}, "writer": None, "claimed": None, "takeovers": 0, "spent": [], "retirements": []}


def _retire(st, op, it, status):
    it["status"] = status
    it["retired"] = op["t"]
    it["touched"] = op["seq"]
    st["retirements"].append({"t": op["t"], "session": op["by"]["session"], "bulk": bool(op.get("bulk")), "op": op["op"]})


def _new_item(st, op, item):
    it = dict(item)
    if it.get("id") in st["items"] or not ID_RE.match(str(it.get("id"))):
        raise Refused(5, "hot.jsonl line %d: item id %r is reused or malformed" % (op["seq"], it.get("id")))
    it.update({"status": "live", "created": op["t"], "touched": op["seq"], "seen": 0})
    if it["id"][0] == "T":
        it["hits"] = 0
    st["items"][it["id"]] = it
    return it


def apply(st, op):
    """Fold one op into the state (the same function serves the full fold and the write path)."""
    kind = op.get("op")
    items = st["items"]

    def item(key="id"):
        it = items.get(op.get(key))
        if it is None:
            raise Refused(5, "hot.jsonl line %d: %s names unknown item %r" % (op["seq"], kind, op.get(key)))
        return it

    if kind == "claim":
        if op.get("takeover"):
            st["takeovers"] += 1
        st["writer"] = op["by"]["session"]
        st["claimed"] = op["t"]
    elif kind in ("add", "owner-add"):
        _new_item(st, op, op["item"])
    elif kind == "close":
        it = item()
        it["reason"], it["pointer"] = op.get("reason"), op.get("pointer")
        _retire(st, op, it, "closed")
    elif kind in ("supersede", "owner-supersede"):
        it = item()
        it["reason"] = op.get("reason")
        new = _new_item(st, op, op["item"])
        it["superseded_by"] = new["id"]
        _retire(st, op, it, "superseded")
    elif kind == "owner-unpin":
        it = item()
        it["reason"] = "unpinned by the owner"
        _retire(st, op, it, "closed")
    elif kind == "owner-promote":
        it = item()
        it["pointer"] = op.get("pointer")
        it["reason"] = "promoted"
        _retire(st, op, it, "archived")
    elif kind == "touch":
        item()["touched"] = op["seq"]
    elif kind == "hit":
        it = item()
        it["hits"] = it.get("hits", 0) + 1
        it["touched"] = op["seq"]
    else:
        raise Refused(5, "hot.jsonl line %d: unknown op %r" % (op["seq"], kind))
    rid = (op.get("confirm") or {}).get("record")
    if rid:
        st["spent"].append(rid)
    st["version"] = op["seq"]
    return st


def fold(ops):
    st = empty_state()
    for op in ops:
        apply(st, op)
    return st


# --- caches -------------------------------------------------------------------------------------------------------------------

def digest(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def archive_lines(st):
    return [dumps(it) for _, it in sorted(st["items"].items(), key=lambda kv: kv[1]["touched"]) if it["status"] != "live"]


def write_caches(d, st, head):
    body = dumps(st)
    _write_file(os.path.join(d, "hot.json"), dumps({"folded_from": head, "digest": digest(body), "state": st}) + "\n")
    lines = archive_lines(st)
    _write_file(os.path.join(d, "archive.jsonl"),
                "\n".join([dumps({"folded_from": head, "digest": digest("\n".join(lines))})] + lines) + "\n")
    _write_file(os.path.join(d, "owner.json"), dumps({"folded_from": head, "session": st["writer"], "since": st["claimed"],
                                                       "takeovers": st["takeovers"]}) + "\n")
    _write_file(os.path.join(d, "hot.md"), render(st))


_SIZE = re.compile(r" · [\d,]+/([\d,]+) chars")
_ITEM = re.compile(r"^- ([DWNXT][1-9][0-9]{0,5}) ")
_LEFT = re.compile(r"expired|(\d+)d (\d+)h|(\d+)h (\d\d)m")


def _left_fits(left, it, now):
    """A window's shown time left could have been rendered by this state at some time between its creation and `now`."""
    exp = parse_iso(it.get("expires") or "")
    created = parse_iso(it.get("created") or "")
    m = _LEFT.fullmatch(left)
    if exp is None or created is None or not m:
        return False
    if left == "expired":
        return now >= exp
    if m.group(1) is not None:
        lo, step = (int(m.group(1)) * 24 + int(m.group(2))) * 3600, 3600
    else:
        lo, step = int(m.group(3)) * 3600 + int(m.group(4)) * 60, 60
    if _left(lo + step // 2) != left:
        return False   # only the form _left writes: "2d 23h", never "0d 71h", "71h 00m" or "02d 23h"
    return lo <= exp - created and lo + step > exp - now


def render_key(text, st, now=None):
    """A render reduced to what does not move with the clock, for comparing hot.md with a fresh render: a window's time left,
    and so which of its links fit, changes as it nears expiry. An item line is reduced to its id when it is the state's line
    without links, its time left (a window's, at its place) one the state could have shown by `now`, then the very tail
    item_line writes after that much text; any other line is kept whole (the title without its size), so an edited id, text, date, time left or tail
    cannot compare equal."""
    now = time.time() if now is None else now
    out = []
    for line in text.splitlines():
        m = _ITEM.match(line)
        it = st["items"].get(m.group(1)) if m else None
        if it:
            base = item_line(dict(it, links=[]), now)
            rest = None
            if it["id"][0] == "W" and it.get("expires"):
                stem = base[:base.rindex(" (")] + " ("
                if line.startswith(stem) and ")" in line[len(stem):]:
                    left, _, after = line[len(stem):].partition(")")
                    rest = after if _left_fits(left, it, now) else None
            elif line.startswith(base):
                rest = line[len(base):]
            if rest is not None and rest == links_tail(len(line) - len(rest), it):
                out.append("item %s" % it["id"])
                continue
        out.append(_SIZE.sub(r" · ?/\1 chars", line))
    return out


def cache_state(d, head):
    """The cached state when hot.json was folded from `head` and its digest matches; else None."""
    try:
        c = json.load(open(os.path.join(d, "hot.json"), encoding="utf-8"))
        if c.get("folded_from") == head and c.get("digest") == digest(dumps(c["state"])):
            return c["state"]
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        pass
    return None


def cache_problems(d, head, st):
    """Doctor's view of the three caches against a fresh fold `st`: [(level, text)]."""
    out = []
    try:
        c = json.load(open(os.path.join(d, "hot.json"), encoding="utf-8"))
        if c.get("folded_from") != head:
            out.append(("warn", "hot.json is stale (folded from another head); the next read folds again"))
        elif c.get("digest") != digest(dumps(c.get("state"))) or dumps(c.get("state")) != dumps(st):
            out.append(("problem", "hot.json does not match its digest or the fold: it was edited; reads ignore it"))
    except (OSError, ValueError, AttributeError):
        out.append(("warn", "hot.json is missing or unreadable; the next read folds again"))
    try:
        lines = open(os.path.join(d, "archive.jsonl"), encoding="utf-8").read().splitlines()
        h = json.loads(lines[0])
        if h.get("folded_from") != head:
            out.append(("warn", "archive.jsonl is stale; the next write folds again"))
        elif h.get("digest") != digest("\n".join(lines[1:])) or lines[1:] != archive_lines(st):
            out.append(("problem", "archive.jsonl does not match its digest or the fold: it was edited"))
    except (OSError, ValueError, IndexError, AttributeError):
        out.append(("warn", "archive.jsonl is missing or unreadable"))
    try:
        o = json.load(open(os.path.join(d, "owner.json"), encoding="utf-8"))
        if o.get("session") != st["writer"]:
            out.append(("problem", "owner.json does not name the writer of the log's last claim"))
    except (OSError, ValueError, AttributeError):
        out.append(("warn", "owner.json is missing or unreadable"))
    return out


def load(d):
    """(head, state) for reading: the cache when it matches the head, else a fresh fold. Raises Refused(5) on a broken log."""
    raw, ops = verify(d)
    head = head_of(raw)
    st = cache_state(d, head)
    return head, (st if st is not None else fold(ops))


# --- text guards --------------------------------------------------------------------------------------------------------------

def check_text(field, value, required=True):
    if value is None or value == "":
        if required:
            raise Refused(1, "%s is empty" % field)
        return
    if not any(not c.isspace() and unicodedata.category(c) not in ("Mn", "Me") for c in value):
        raise Refused(1, "%s is blank: only spaces or marks that show nothing on their own" % field)
    if _marks_run(value) > MARKS_RUN_MAX:
        raise Refused(1, "%s stacks more than %d combining marks on one character" % (field, MARKS_RUN_MAX))
    bad = [c for c in value if is_bad(c)]
    bad += [c for i, c in enumerate(value) if ord(c) in SELECTORS and not selector_fits(value, i)]
    if bad:
        raise Refused(1, "%s holds a control or format character (U+%04X); refused so the render stays one clean line"
                      % (field, ord(bad[0])))
    cap = FIELD_MAX[field]
    if len(value) > cap:
        raise Refused(1, "%s is %d characters, over its cap of %d" % (field, len(value), cap))


def _marks_run(value):
    """The longest run of visible combining marks; selectors and other default-ignorables are the selector rule's."""
    run = best = 0
    for c in value:
        run = run + 1 if unicodedata.category(c) in ("Mn", "Me") and not ignorable(c) else 0
        best = max(best, run)
    return best


def check_list(field, values):
    if len(values) > LIST_MAX:
        raise Refused(1, "more than %d %ss" % (LIST_MAX, field))
    for v in values:
        check_text(field, v)


def ignorable(c):
    o = ord(c)
    return any(a <= o <= b for a, b in DEFAULT_IGNORABLE)


def selector_fits(value, i):
    """value[i] is a selector right after a non-ASCII symbol (an emoji's presentation), or inside a keycap."""
    prev = value[i - 1] if i else ""
    if prev in "0123456789#*" and prev:
        return value[i + 1:i + 2] == "\u20e3"
    return bool(prev) and ord(prev) > 0x7F and (unicodedata.category(prev) in ("So", "Sm") or ord(prev) in EMOJI_BASES)


def skeleton(t):
    return unicodedata.normalize("NFKC", "".join(c for c in t if unicodedata.category(c) not in ("Mn", "Me") and not ignorable(c)))


def is_bad(c):
    o = ord(c)
    return (unicodedata.category(c) in BAD_CATEGORIES or o in INVISIBLE or 0xFDD0 <= o <= 0xFDEF
            or o & 0xFFFE == 0xFFFE or (ignorable(c) and o not in SELECTORS))


def clean_line(s):
    """The render backstop: drop every control, format, noncharacter or invisible character."""
    return "".join(c for c in str(s) if not is_bad(c))


def printable(s):
    """One line safe for a terminal: every bad character, the newline included (it could forge a line), shown as \\uXXXX."""
    return "".join(c if not is_bad(c) else "\\u%04x" % ord(c) for c in str(s))


def sdlc_filter():
    """Path of vibemaestro-sdlc's gates/pr_sensitive.py: the plugin registry first, then the marketplace layout; else None."""
    rel = os.path.join("gates", "pr_sensitive.py")
    try:
        reg = json.load(open(os.path.join(config_dir(), "plugins", "installed_plugins.json"), encoding="utf-8"))
        for key, entries in sorted((reg.get("plugins") or {}).items()):
            if key.split("@")[0] == "vibemaestro-sdlc":
                for e in entries or []:
                    f = os.path.join(str(e.get("installPath", "")), rel)
                    if os.path.isfile(f):
                        return f
    except (OSError, ValueError, AttributeError, TypeError):
        pass
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    f = os.path.join(os.path.dirname(here), "vibemaestro-sdlc", rel)
    return f if os.path.isfile(f) else None


def sanitize(d, texts):
    """Run every text through sdlc's filter once; refuse (rc 1) on a hit, printing only the masked form, or when it cannot run."""
    texts = [t for t in texts if t]
    if not texts:
        return
    # the filter's patterns also run on a skeleton of each text: marks and selectors removed (one between every character of a
    # token would split it for the filter), then NFKC (fullwidth or styled letters back to plain ones)
    texts += [k for k in (skeleton(t) for t in texts) if k not in texts]
    f = sdlc_filter()
    if not f:
        raise Refused(1, "vibemaestro-sdlc's sensitive-value filter (gates/pr_sensitive.py) was not found; writes are refused "
                         "until it is installed")
    try:
        r = subprocess.run([sys.executable, f, "--text", "--cwd", d], input="\n".join(texts), capture_output=True,
                           text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as e:
        raise Refused(1, "the sensitive-value filter could not run (%s); the write is refused" % e.__class__.__name__)
    if r.returncode == 0:
        return
    if r.returncode == 1:
        masked = [re.sub(r"\s+sha256=\S+", "", l.replace("stdin text: ", "")).strip()
                  for l in r.stdout.splitlines() if l.startswith("RED")]
        raise Refused(1, "a sensitive value; nothing was written: %s" % "; ".join(masked or ["(masked)"]))
    raise Refused(1, "the sensitive-value filter did not conclude (rc %d); the write is refused" % r.returncode)


# --- who may write ------------------------------------------------------------------------------------------------------------

def session_id():
    return os.environ.get("CLAUDE_CODE_SESSION_ID", "")


def check_caller():
    if os.environ.get("INTENT_SLUG") and os.environ.get("SEAT"):
        raise Refused(4, "a sandbox worker session keeps no hot memory (INTENT_SLUG and SEAT are set)")
    if not session_id():
        raise Refused(7, "no CLAUDE_CODE_SESSION_ID: only a Claude Code session writes hot memory")


def check_writer(st):
    if st["writer"] not in (None, session_id()):
        raise Refused(3, "another session writes this project's hot memory; after /clear or --fork-session run "
                         "`brain claim --take-over` (it is logged)")


def by():
    return {"session": session_id(), "agent": None}


# --- "asked" records (written by B1.2's guard-owner hook) ---------------------------------------------------------------------

def void_records(d, session):
    for p in glob.glob(os.path.join(d, "asked", "*.json")):
        try:
            if json.load(open(p, encoding="utf-8")).get("session") == session:
                os.unlink(p)
        except (OSError, ValueError, AttributeError):
            pass


def record_asked(d, session, mode, args, t=None):
    """Void the session's earlier unused records, then write one for this dialog. Returns the record id."""
    with locked(d):
        void_records(d, session)
        rid = secrets.token_hex(16)
        _write_file(os.path.join(d, "asked", rid + ".json"),
                    dumps({"id": rid, "session": session, "mode": mode, "args": list(args),
                           "t": time.time() if t is None else t}) + "\n")
    return rid


def find_record(d, args, st, now=None):
    now = time.time() if now is None else now
    for p in sorted(glob.glob(os.path.join(d, "asked", "*.json"))):
        try:
            r = json.load(open(p, encoding="utf-8"))
            age = now - float(r["t"])
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            continue
        if (r.get("session") == session_id() and r.get("args") == list(args) and r.get("mode") in DIALOG_MODES
                and 0 <= age <= RECORD_MAX_AGE and r.get("id") not in st["spent"]
                and os.path.basename(p) == "%s.json" % r.get("id")):
            return r, p
    return None, None


# --- programmatic answerers ------------------------------------------------------------------

def _has_permission_request(obj):
    hooks = obj.get("hooks") if isinstance(obj, dict) else None
    return isinstance(hooks, dict) and bool(hooks.get("PermissionRequest"))


def _json_file(p):
    try:
        with open(p, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _ancestors():
    """[(argv, cwd or None, CLAUDE_CONFIG_DIR or None, HOME or None)] of the ancestor processes (Linux /proc, else `ps` without cwd)."""
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


def _flag_values(argv, flag):
    """Values of `flag` in an argv, in both `--flag value` and `--flag=value` forms."""
    vals = []
    for i, a in enumerate(argv):
        if a == flag and i + 1 < len(argv):
            vals.append(argv[i + 1])
        elif a.startswith(flag + "="):
            vals.append(a[len(flag) + 1:])
    return vals


def _plugin_answers(root):
    """A plugin directory whose hooks/hooks.json, or a hooks object or hooks file(s) its manifest names, has the hook."""
    if _has_permission_request(_json_file(os.path.join(root, "hooks", "hooks.json"))):
        return True
    man = _json_file(os.path.join(root, ".claude-plugin", "plugin.json"))
    hooks = man.get("hooks") if isinstance(man, dict) else None
    if isinstance(hooks, dict):
        return _has_permission_request(man)
    for h in [hooks] if isinstance(hooks, str) else hooks if isinstance(hooks, list) else []:
        if isinstance(h, str) and _has_permission_request(_json_file(os.path.join(root, h))):
            return True
        if isinstance(h, dict) and _has_permission_request({"hooks": h}):
            return True
    return False


def _worktrees():
    try:
        r = subprocess.run(["git", "worktree", "list", "--porcelain"], capture_output=True, text=True, timeout=10)
        return [l[len("worktree "):] for l in r.stdout.splitlines() if l.startswith("worktree ")] if r.returncode == 0 else []
    except (OSError, subprocess.SubprocessError):
        return []


def answerers(project=None):
    """What can answer Claude Code's permission prompt in place of a human, as far as settings and processes show. It reads
    the union of every place the running session may take settings from (each config directory, each worktree of the
    repository, each ancestor's working directory), so a call from another directory or environment can only see more."""
    found = []
    anc = _ancestors()
    # ~/.claude by HOME and by the password database (HOME can be emptied or moved), this process's config directory (a
    # relative one from its cwd), and each ancestor's config directory and ~/.claude (relative ones from that ancestor's cwd)
    cfgs = [os.path.join(h, ".claude") for h in (os.environ.get("HOME", ""), account_home()) if os.path.isabs(h)]
    cfgs.append(config_dir())
    rel = lambda v, cwd: v if os.path.isabs(v) or not cwd else os.path.join(cwd, v)
    cfgs += [rel(c, cwd) for _, cwd, c, _ in anc if c]
    cfgs += [os.path.join(rel(h, cwd), ".claude") for _, cwd, _, h in anc if h]
    cfgs = [c for c in cfgs if os.path.isabs(c)]
    roots = [project or project_root()] + _worktrees() + [a[1] for a in anc if a[1]]
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
        s = _json_file(p)
        if _has_permission_request(s):
            found.append("a PermissionRequest hook in the %s" % label)
        if isinstance(s, dict) and isinstance(s.get("enabledPlugins"), dict):
            enabled.update({k: v for k, v in s["enabledPlugins"].items() if v is True or k not in enabled})
    for c in sorted(set(cfgs)):
        reg = _json_file(os.path.join(c, "plugins", "installed_plugins.json"))
        plugins = reg.get("plugins") if isinstance(reg, dict) else None
        for key, entries in sorted(plugins.items() if isinstance(plugins, dict) else []):
            if enabled.get(key) is not True:
                continue
            for e in entries if isinstance(entries, list) else []:
                if isinstance(e, dict) and _plugin_answers(str(e.get("installPath", ""))):
                    found.append("a PermissionRequest hook in the enabled plugin %s" % key.split("@")[0])
    for argv, cwd, _, _ in anc:
        if any(a == "--permission-prompt-tool" or a.startswith("--permission-prompt-tool=") for a in argv):
            found.append("a process started with --permission-prompt-tool")
        for v in _flag_values(argv, "--settings"):
            if v.lstrip().startswith("{"):
                try:
                    s = json.loads(v)
                except ValueError:
                    s = None
            else:
                s = _json_file(v if os.path.isabs(v) or not cwd else os.path.join(cwd, v))
            if _has_permission_request(s):
                found.append("a PermissionRequest hook in --settings of a parent process")
        for v in _flag_values(argv, "--plugin-dir"):
            if _plugin_answers(v if os.path.isabs(v) or not cwd else os.path.join(cwd, v)):
                found.append("a PermissionRequest hook in a --plugin-dir of a parent process")
    return sorted(set(found))


# --- render -------------------------------------------------------------------------------------------------------------------

def _left(seconds):
    if seconds <= 0:
        return "expired"
    h, m = int(seconds // 3600), int(seconds % 3600 // 60)
    return "%dd %dh" % (h // 24, h % 24) if h >= 48 else "%dh %02dm" % (h, m)


def item_line(it, now):
    text = clean_line(it["text"])[:TEXT_MAX]
    if it["id"][0] == "W" and it.get("expires"):
        ts = parse_iso(it["expires"]) or 0
        date = "until %s (%s)" % (now_iso(ts)[5:16].replace("T", " ") + "Z", _left(ts - now))
    else:
        date = "since %s" % str(it.get("created", ""))[5:10]
    if it["id"][0] == "T":
        date += " (hits %d)" % it.get("hits", 0)
    line = "- %s %s · %s" % (clean_line(it["id"]), text, clean_line(date))
    return (line + links_tail(len(line), it))[:LINE_MAX]


def links_tail(used, it):
    """The ` · links …` tail of an item line whose first `used` characters are written: as many links as fit, then `+N`."""
    links = [clean_line(l) for l in it.get("links") or []]
    if not links:
        return ""
    shown = []
    for i, l in enumerate(links):
        rest = len(links) - i - 1
        cand = " · links " + ", ".join(shown + [l]) + (" +%d" % rest if rest else "")
        if used + len(cand) > LINE_MAX:
            break
        shown.append(l)
    more = len(links) - len(shown)
    tail = " · links " + ", ".join(shown) + (" +%d" % more if more else "") if shown else " · links +%d" % more
    return tail if used + len(tail) <= LINE_MAX else ""


def render(st, now=None):
    now = time.time() if now is None else now
    body = []
    for letter, title in SECTIONS:
        body.append(title)
        live = [it for it in st["items"].values() if it["id"][0] == letter and it["status"] == "live"]
        body += [item_line(it, now) for it in sorted(live, key=lambda i: int(i["id"][1:]))]
    body.append("Matrix: `brain matrix`")
    size = 0
    for _ in range(3):
        title = ("## Brain · hot memory v%d · %s/%s chars   (re-injected after compaction; change only with `brain op` or "
                 "`brain owner`)" % (st["version"], "{:,}".format(size), "{:,}".format(RENDER_CAP)))
        text = "\n".join([title] + body) + "\n"
        if len(text) == size:
            break
        size = len(text)
    return text


# --- writes -------------------------------------------------------------------------------------------------------------------

def next_id(st, letter):
    n = [int(k[1:]) for k in st["items"] if k[0] == letter]
    return "%s%d" % (letter, max(n) + 1 if n else 1)


def live(st, letter):
    return sorted((it for it in st["items"].values() if it["id"][0] == letter and it["status"] == "live"),
                  key=lambda i: i["touched"])


def chain_root(st, it):
    seen = set()
    while it.get("supersedes") and it["supersedes"] in st["items"] and it["id"] not in seen:
        seen.add(it["id"])
        it = st["items"][it["supersedes"]]
    return it


def budget_used(st, session, now):
    return sum(1 for r in st["retirements"]
               if r["session"] == session and now - (parse_iso(r["t"]) or 0) < BUDGET_WINDOW)


def check_cap(st, letter):
    cur = live(st, letter)
    if len(cur) >= CAPS[letter]:
        name = dict(SECTIONS)[letter]
        hint = {"D": "Sleep: promote decisions", "W": "unpin a window"}.get(letter, "close one first, e.g. %s" % cur[0]["id"])
        raise Refused(1, "%s holds %d of %d live items; %s" % (name, len(cur), CAPS[letter], hint))
    if len(cur) + 1 >= WARN_RATIO * CAPS[letter]:
        return "warning: %s at %d of %d" % (dict(SECTIONS)[letter], len(cur) + 1, CAPS[letter])
    return None


def get_live(st, iid, letters):
    it = st["items"].get(iid)
    if it is None or it["status"] != "live":
        raise Refused(1, "%s is not a live item" % iid)
    if it["id"][0] not in letters:
        if it["id"][0] in OWNER_LETTERS:
            raise Refused(1, "%s is an owner item: only `brain owner …`, through the permission dialog, changes it" % iid)
        raise Refused(1, "%s is not an owner item; use `brain op`" % iid)
    return it


def write(build):
    """Run `build(d, st) -> (op, texts, message, extra)` under the lock and append its op; returns the printed message."""
    check_caller()
    d = state_dir()
    with locked(d):
        raw, ops = verify(d)
        st = fold(ops)
        check_writer(st)
        test_pause()
        op, texts, msg, after = build(d, st)
        sanitize(d, texts)
        t = now_iso()
        if st["writer"] is None:
            claim = {"op": "claim", "t": t, "by": by(), "takeover": False}
            raw = append(d, raw, claim)
            apply(st, dict(claim, seq=len(raw)))
        op = dict(op, t=t, by=by())
        raw = append(d, raw, op)
        apply(st, json.loads(raw[-1].decode("utf-8")))
        if after:
            after()
        msg += caches_after_append(d, st, raw)
    return msg


def caches_after_append(d, st, raw):
    """Rewrite the caches once the op is in the log. A failure here is not a refusal: the op is written (a retry would write it
    twice), and the next read folds the log again. Returns the warning to print, or ""."""
    try:
        write_caches(d, st, head_of(raw))
    except OSError as e:
        return ("\nwarning: written as seq %d, but the caches could not be rewritten (%s); the next read folds the log again"
                % (len(raw), e.__class__.__name__))
    return ""


def op_add(kind, text, links, anchors, expires):
    letter = KINDS.get(kind)
    if letter is None:
        raise Refused(64, "--kind must be one of %s" % ", ".join(KINDS))
    if letter in OWNER_LETTERS:
        raise Refused(1, "a %s is an owner item: only `brain owner add`, through the permission dialog, writes one" % kind)
    check_text("text", text)
    check_list("link", links)
    check_list("anchor", anchors)
    if expires is not None and parse_iso(expires) is None:
        raise Refused(64, "--expires must be like 2026-10-17T22:00:00Z")

    def build(d, st):
        warn = check_cap(st, letter)
        iid = next_id(st, letter)
        item = {"id": iid, "kind": kind, "pinned": False, "text": text, "source": {"type": "coordinator"},
                "expires": expires, "links": links, "anchors": anchors, "supersedes": None}
        return {"op": "add", "item": item}, [text] + links + anchors, "added %s%s" % (iid, "\n" + warn if warn else ""), None
    return write(build)


def op_close(iid, reason, pointer, bulk):
    check_text("reason", reason)
    check_text("pointer", pointer, required=False)

    def build(d, st):
        get_live(st, iid, ("N", "X", "T"))
        if not bulk and budget_used(st, session_id(), time.time()) >= BUDGET_N:
            raise Refused(1, "retirement budget: %d retirements in 30 minutes already; add --bulk (logged) if this is a "
                             "deliberate sweep" % BUDGET_N)
        return ({"op": "close", "id": iid, "reason": reason, "pointer": pointer, "bulk": bulk}, [reason, pointer],
                "closed %s" % iid, None)
    return write(build)


def op_supersede(iid, text, reason, drop, add_anchors, shorter, bulk):
    check_text("text", text)
    check_text("reason", reason)
    check_list("anchor", drop + add_anchors)

    def build(d, st):
        old = get_live(st, iid, ("N", "X", "T"))
        missing = [a for a in drop if a not in old.get("anchors", [])]
        if missing:
            raise Refused(1, "%s holds no anchor %r to drop" % (iid, missing[0]))
        anchors = [a for a in old.get("anchors", []) if a not in drop]
        anchors += [a for a in add_anchors if a not in anchors]
        lost = [a for a in old.get("anchors", []) if a not in anchors and a not in drop]
        if lost:
            raise Refused(1, "the new item would lose anchor %r; name it with --drop-anchor and a --reason" % lost[0])
        check_list("anchor", anchors)
        root = chain_root(st, old)
        if not shorter and len(text) < SHRINK_MIN * len(root["text"]):
            raise Refused(1, "the new text is %d characters, under 60%% of the first item of its chain (%s, %d); a supersede "
                             "must not shrink meaning: pass --shorter with a --reason if it must"
                          % (len(text), root["id"], len(root["text"])))
        if not bulk and budget_used(st, session_id(), time.time()) >= BUDGET_N:
            raise Refused(1, "retirement budget: %d retirements in 30 minutes already; add --bulk (logged) if this is a "
                             "deliberate sweep" % BUDGET_N)
        nid = next_id(st, iid[0])
        item = {"id": nid, "kind": old["kind"], "pinned": False, "text": text, "source": {"type": "coordinator"},
                "expires": old.get("expires"), "links": old.get("links", []), "anchors": anchors, "supersedes": iid}
        op = {"op": "supersede", "id": iid, "item": item, "reason": reason, "drop": drop, "shorter": shorter, "bulk": bulk}
        return op, [text, reason] + anchors, "superseded %s with %s" % (iid, nid), None
    return write(build)


def op_counter(iid, verb):
    def build(d, st):
        get_live(st, iid, ("N", "X", "T"))
        if verb == "hit" and iid[0] != "T":
            raise Refused(1, "hit counts traps only")
        return {"op": verb, "id": iid}, [], "%s %s" % (verb, iid), None
    return write(build)


def claim(takeover):
    check_caller()
    d = state_dir()
    with locked(d):
        raw, ops = verify(d)
        st = fold(ops)
        if st["writer"] == session_id():
            return "this session already writes this project's hot memory"
        if st["writer"] is not None and not takeover:
            raise Refused(3, "another session writes this project's hot memory; `brain claim --take-over` takes it (logged)")
        raw = append(d, raw, {"op": "claim", "t": now_iso(), "by": by(), "takeover": st["writer"] is not None})
        apply(st, json.loads(raw[-1].decode("utf-8")))
        warn = caches_after_append(d, st, raw)
    return "claimed%s%s" % (" (take-over logged)" if st["takeovers"] else "", warn)


# --- owner writes -------------------------------------------------------------------------------------------------------------

def owner(args, verb, ns):
    """`brain owner <verb> …`: `args` is the argv after `owner`, matched item by item against an "asked" record."""

    def build(d, st):
        rec, path = find_record(d, args, st)
        if rec is None:
            raise Refused(6, NO_DIALOG + " (no fresh, matching, unused record of an approved dialog in this session)")
        ans = answerers()
        if ans:
            raise Refused(6, "owner items are refused while something can answer the permission prompt in place of a human: "
                             + "; ".join(ans))
        confirm = {"asked": True, "mode": rec["mode"], "record": rec["id"]}
        after = lambda: os.path.exists(path) and os.unlink(path)
        if verb == "add":
            letter = KINDS[ns.kind]
            warn = check_cap(st, letter)
            iid = next_id(st, letter)
            item = {"id": iid, "kind": ns.kind, "pinned": letter == "D", "text": ns.text,
                    "source": {"type": "owner", "quote": ns.owner_quote, "where": ns.where},
                    "expires": ns.expires, "links": ns.link, "anchors": ns.anchor, "supersedes": None}
            texts = [ns.text, ns.owner_quote, ns.where] + ns.link + ns.anchor
            return {"op": "owner-add", "item": item, "confirm": confirm}, texts, "pinned %s%s" % (
                iid, "\n" + warn if warn else ""), after
        old = get_live(st, ns.id, OWNER_LETTERS)
        if verb == "unpin":
            return {"op": "owner-unpin", "id": ns.id, "confirm": confirm}, [], "unpinned %s" % ns.id, after
        if verb == "promote":
            return ({"op": "owner-promote", "id": ns.id, "pointer": ns.pointer, "confirm": confirm}, [ns.pointer],
                    "promoted %s to %s" % (ns.id, ns.pointer), after)
        nid = next_id(st, ns.id[0])
        item = {"id": nid, "kind": old["kind"], "pinned": old.get("pinned", False), "text": ns.text,
                "source": {"type": "owner", "quote": None, "where": "supersedes %s" % ns.id},
                "expires": old.get("expires"), "links": old.get("links", []), "anchors": old.get("anchors", []),
                "supersedes": ns.id}
        return ({"op": "owner-supersede", "id": ns.id, "item": item, "reason": "superseded by the owner", "confirm": confirm},
                [ns.text], "superseded %s with %s" % (ns.id, nid), after)

    owner_check(verb, ns)
    return write(build)


def owner_check(verb, ns):
    """The field checks of `brain owner <verb>`, before any state is read; guard-owner runs the same ones before it asks."""
    for field, value in (("text", getattr(ns, "text", None)), ("where", getattr(ns, "where", None)),
                         ("pointer", getattr(ns, "pointer", None))):
        if value and '"' in value:
            raise Refused(1, "%s holds a double quote: the dialog quotes each field, so a quote inside one could end it and "
                             "imitate another (write it without one)" % field)
        if value and field != "text":
            for c in value:
                if (unicodedata.category(c) in ("Pi", "Pf") or unicodedata.bidirectional(c) in ("R", "AL")
                        or any(n in unicodedata.name(c, "") for n in QUOTE_NAMES)):
                    raise Refused(1, "%s holds U+%04X, which can pass for the dialog's quote or reverse the line; the source "
                                     "and pointer come before the text, so they take plain characters" % (field, ord(c)))
    if verb == "add":
        if ns.kind not in ("decision", "window"):
            raise Refused(64, "brain owner add --kind decision|window")
        check_text("text", ns.text)
        check_text("quote", ns.owner_quote)
        check_text("where", ns.where)
        check_list("link", ns.link)
        check_list("anchor", ns.anchor)
        if ns.kind == "window":
            ts = parse_iso(ns.expires or "")
            if ts is None:
                raise Refused(1, "a window needs --expires like 2026-10-17T22:00:00Z")
            if ts <= time.time():
                raise Refused(1, "--expires %s has already passed" % ns.expires)
        elif ns.expires is not None:
            raise Refused(64, "--expires is for a window")
    elif verb == "supersede":
        check_text("text", ns.text)
    elif verb == "promote":
        check_text("pointer", ns.pointer)


# --- doctor -------------------------------------------------------------------------------------------------------------------

def _version_tuple(s):
    m = re.search(r"(\d+)\.(\d+)\.(\d+)", s or "")
    return tuple(int(x) for x in m.groups()) if m else None


def doctor():
    """[(level, text)] with level ok | warn | problem | info."""
    out = []
    d = state_dir()
    if not os.path.isdir(d):
        out.append(("info", "no brain state for this project yet"))
    else:
        try:
            raw, ops = verify(d)
            head = head_of(raw)
            st = fold(ops)
            out.append(("ok", "hot.jsonl: %d lines, the chain and head.json agree" % len(raw)))
            out += cache_problems(d, head, st) or [("ok", "hot.json, archive.jsonl and owner.json match the head")]
            out.append(("ok" if st["writer"] in (None, session_id()) else "info",
                        "writer: %s" % ("none yet" if st["writer"] is None else
                                        "this session" if st["writer"] == session_id() else "another session")))
            try:
                md = open(os.path.join(d, "hot.md"), encoding="utf-8").read()
                out.append(("ok", "hot.md matches a fresh render") if render_key(md, st) == render_key(render(st), st) else
                           ("problem", "hot.md does not match a fresh render of the log: it was edited or is stale"))
            except (OSError, ValueError):
                out.append(("warn", "hot.md is missing or unreadable; `brain render` writes it"))
            stale = 0
            for p in glob.glob(os.path.join(d, "asked", "*.json")):
                r = _json_file(p)
                if not isinstance(r, dict) or not isinstance(r.get("t"), (int, float)) or time.time() - r["t"] > RECORD_MAX_AGE:
                    stale += 1
            if stale:
                out.append(("info", "%d expired \"asked\" record(s); SessionEnd deletes them (B1.2)" % stale))
        except Refused as e:
            out.append(("problem", "the chain or head.json: %s" % e.msg))
        try:
            fd = os.open(os.path.join(d, "lock"), os.O_RDWR | os.O_CREAT, 0o600)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                out.append(("ok", "the lock is free"))
            except OSError:
                out.append(("warn", "the lock is held by another process right now"))
            finally:
                os.close(fd)
        except OSError as e:
            out.append(("problem", "the lock file cannot be opened (%s)" % e.__class__.__name__))
        loose = []
        for root, dirs, files in os.walk(d):
            for n in dirs + files:
                try:
                    st_ = os.lstat(os.path.join(root, n))
                except OSError:
                    continue
                if stat.S_ISLNK(st_.st_mode):
                    loose.append(n + " (a symlink)")
                elif st_.st_mode & 0o077:
                    loose.append(n + ("/" if n in dirs else ""))
        for p, label in ((d, "the state directory"), (state_root(), "the brain root")):
            if os.stat(p).st_mode & 0o077:
                loose.append(label)
        out.append(("problem", "group or other can read, or a symlink: %s" % printable(", ".join(sorted(loose)))) if loose
                   else ("ok", "file modes 0600 / 0700"))
    f = sdlc_filter()
    if not f:
        out.append(("problem", "vibemaestro-sdlc's sensitive-value filter was not found: every write is refused"))
    else:
        tok = "gh" + "p_" + "a1B2c3D4e5" * 3 + "a1B2c3"
        rc = [subprocess.run([sys.executable, f, "--text", "--cwd", d if os.path.isdir(d) else os.getcwd()], input=t,
                             capture_output=True, text=True, timeout=30).returncode for t in ("plain words", tok)]
        out.append(("ok", "the sensitive-value filter runs (clean 0, token 1)") if rc == [0, 1] else
                   ("problem", "the sensitive-value filter answers %s on clean text and a token, not 0 and 1" % rc))
    for a in answerers():
        out.append(("problem", "%s: owner items are refused while it is configured" % a))
    try:
        v = subprocess.run(["claude", "--version"], capture_output=True, text=True, timeout=10).stdout
        vt = _version_tuple(v)
        if vt is None:
            out.append(("info", "Claude Code version unknown"))
        elif vt < (2, 1, 211):
            out.append(("problem", "Claude Code %d.%d.%d is older than 2.1.211: auto mode may approve without the dialog, "
                                   "so owner items need 2.1.211 or later" % vt))
        else:
            out.append(("ok", "Claude Code %d.%d.%d" % vt))
    except (OSError, subprocess.SubprocessError):
        out.append(("info", "`claude` is not on PATH; the version floor (2.1.211) is not checked"))
    for v in ("BRAIN_TEST", "BRAIN_TEST_PAUSE_MS"):
        if os.environ.get(v):
            out.append(("warn", "%s is set: it is for tests only" % v))
    return out
