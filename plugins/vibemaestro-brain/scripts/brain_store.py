"""vibemaestro-brain store: Hot Memory as one hash-chained op log, its fold, guards, caches and render.

Truth is `hot.jsonl`, one op per line; each line's `prev` is the SHA-256 of the line before (64 zeros for the first), and
`head.json` holds the last `seq` and hash. Every write takes the lock, verifies the whole chain and the head (rc 5 on any
mismatch), folds the log, checks the op, appends one line, rewrites `head.json` atomically, and rewrites the caches
(`hot.json`, `archive.jsonl`, `owner.json`). A cache is used only when its `folded_from` equals the head and its digest matches
its content; otherwise the log is folded again.

Owner items (`G` goals, `D` decisions, `W` windows) are written only by `brain owner …` with a fresh, matching, unused "asked"
record (`record_asked`, called by B1.2's guard-owner hook). Like BatonRun, this guards against slips, not same-user forgery.
`brain op` writes the rest; a request (`R`) and a focus (`P`) in the owner's words carry them, stored whole and never rewritten;
a focus the session opens carries none, and names its goal and when it is done.

The render has two halves: the left brain (the owner's: G with its quote, done and not-doing lines, D with its quote lines,
W) and the right brain (P and R with their quote lines, N, S, Q, X, T, Done, F). Each half is packed into strings of
≤ STRING_MAX UTF-16 units, one SessionStart command each, the left first and never sharing a string with the right, at most
SLOTS strings in all. Done is never written: it is the R, N, X, S and Q items the log closed in the last 24 hours. The caps
come from the project's `.vibemaestro/brain.json` (`config`), each key with a default.
An add to a full right-brain section is queued in the log (`overflow-add`), never refused; the op that makes room moves the
queue's head up in the same line (`promote`). The left brain has no overflow: at its cap an owner add is refused.
The evidence of each rule (`held`, `broke`, a trap's hit) and a goal's progress are ops of the log too (`evidence`,
`progress`); brain_ledger reads them from the log and never stores them twice. A plugin may extend the brain (brain_ext.py):
its data rides under `ext.<name>` of an item or an op, which the fold keeps and never reads.
Standard library only.
"""
import bisect
import contextlib
import datetime
import glob
import hashlib
import json
import os
import re
import secrets
import shlex
import shutil
import signal
import stat
import string
import struct
import subprocess
import sys
import time
import unicodedata

WINDOWS = os.name == "nt"
if WINDOWS:                                         # no fcntl, no pwd: msvcrt locks, the account comes from the process token
    import ctypes
    import msvcrt
else:
    import fcntl
    import pwd

KINDS = {"goal": "G", "decision": "D", "window": "W", "focus": "P", "request": "R", "now": "N", "next": "X", "trap": "T",
         "session": "S", "queue": "Q", "fact": "F"}
OWNER_LETTERS = ("G", "D", "W")
OP_LETTERS = ("P", "R", "N", "X", "T", "S", "Q", "F")   # the kinds `brain op` closes, supersedes and touches
LEFT_LETTERS = ("G", "D", "W")                      # the left brain: the owner's, through the dialog, no overflow
QUOTED = ("G", "D", "P", "R")                       # the kinds that store the owner's words (a quote line under the item)
FOCUSED = ("X", "S")                                # the kinds `--focus` ties to a live focus: Next, a running session
SECTIONS = (("G", "Goals (owner)"), ("D", "Pinned (owner)"), ("W", "Windows"), ("P", "Focus"), ("R", "Requests"), ("N", "Now"),
            ("S", "Sessions"), ("Q", "Owner queue"), ("X", "Next"), ("T", "Traps"), ("F", "Facts"))
HALVES = (("left", ("G", "D", "W")), ("right", ("P", "R", "N", "S", "Q", "X", "T", "F")))   # Done sits between Traps and Facts
# the caps' defaults; `.vibemaestro/brain.json` changes them per project
DEFAULT_CAPS = {"G": 5, "D": 20, "W": 10, "P": 5, "R": 20, "N": 5, "X": 30, "S": 20, "Q": 15, "T": 20, "F": 25}
CAPS = {k: v for k, v in DEFAULT_CAPS.items() if k in KINDS.values()}     # the letters this store writes, at their defaults
# the line after the head line of string 1: which source wins goes by the kind of question; the five chains are in the skill's
# key rules and the rulebook's chapter 7, too long for string 1's reserve (FIRST_RESERVE)
PRECEDENCE = ("Precedence, only when two sources disagree, goes by the kind of question: 1 rules and decisions, 2 order of work, "
              "3 one work's contract, 4 the present state, 5 history and evidence (each chain: skill brain, rulebook chapter 7). "
              "The machine never overrides the owner. Auto-memory ranks last: never edit it, report a contradiction to the "
              "owner.")
CONFIG_LEFT = ("G", "D", "W")                       # a left cap off its default is the owner's decision: flagged
STRING_MAX = 9500                                   # every SessionStart string, by its own hard cut (Claude Code replaces one
                                                    # over 10,000 by a 2,000-character preview)
SLOTS = 14                                          # SessionStart string commands in hooks.json (14 × 9,500 measured inline)
FIRST_RESERVE = 2800                                # string 1's room for the hook's lines at their caps: the head, the
                                                    # precedence line, the config line, the review card and the Shelf
                                                    # (test-brain-layers.sh [e] holds their sum within it)
TITLE_ROOM = 170                                    # a string's title line
ANNOTATE_ROOM = 710                                 # a string's room for stale marks, a summary and the notes (brain_stale)
LAST_RESERVE = 200                                  # the last slot's room for the line naming what was not injected
WARN_RATIO = 0.85
TEXT_MAX = 300
TEXT_CAPS = {"S": 600}                              # a running session's next step and pointers (spec R4 point 1)
TEXT_CEIL = 1000                                    # the render never cuts a stored text shorter than this
LINE_EXTRA = 60                                     # an item line: its text, then the id, the date and the links' tail
GOAL_EXTRA = 50                                     # a goal's line also carries its review day and scope
QUOTE_MAX = 600
QUOTE_SHOWN = 120                                   # a pin's quote line: `  "<quote>" · <where>`, ≤ 187 characters
QUOTE_LONG = 300                                    # a goal's, a focus's or a request's quote line: ≤ 367 characters
DONE_LETTERS = ("R", "N", "X", "S", "Q")
DONE_TITLE = "Done (24 h)"
DONE_WINDOW = 86400                                 # seconds a closed item stays in Done
DONE_SHOWN = 7                                      # Done lines, then one `(+N more: brain doctor)`
STATUS_LETTERS = ("S", "Q")                         # status, not decisions: a supersede spends no budget and may shrink
FIELD_MAX = {"text": TEXT_MAX, "quote": QUOTE_MAX, "where": 60, "pointer": 80, "reason": 150, "anchor": 80, "link": 80,
             "done": 200, "not-doing": 200}
FIELD_MAX.update({"differed": 150, "measure": 80})  # a broke's what-differed, a goal's progress measure
FIELD_MAX["blocks"] = 200                           # what a queue item blocks until the owner acts
FIELD_MAX.update({"arg": 80})                      # an extension owner verb's positional value (shown in the dialog)
FIELD_MAX["place"] = 1000                           # the directory the owner names for backups
WHERE_SHOWN = FIELD_MAX["where"]                    # the quote line shows the source whole (an older brain cut it at 30)
LIST_MAX = 8                                        # anchors, links
CLOSES_MAX = 2                                      # `closes` anchors of one item
CLOSES_LETTERS = ("N", "X", "S", "Q", "R")
# the log's format: 2 adds the machine op `link-close`, which a brain of format 1 refuses to fold (a line without it is 1); 3 adds
# the kinds S, Q and F, whose ids a brain of format 2 refuses to fold; 4 adds the op `overflow-add` (a queued item) and `promote`
# on the ops that make room, and a brain of format 3 refuses the op rather than show a queued item as live; 5 adds the kinds
# G, P and R, whose ids a brain of format 4 refuses to fold; 6 adds the ops `evidence`, `progress` and `owner-demote`, and
# `promote` on an `owner-promote` of a lesson or a fact, which a brain of format 5 refuses to fold (the fields `goal` and
# `no_goal` of a session and `soul` of a promotion it folds unread). An older brain wrote those last three; this one folds
# them as it did and writes none (a plugin that extends the brain may), and an extension's `ext` entries are fields too; 7 adds the
# op `words` (a focus's done when and not doing, in place), which a brain of format 6 refuses to fold; 8 adds the op `link`
# (`closes` added to a live item in place), which a brain of format 7 refuses to fold; 9 writes the op `signal` (a measurement,
# its kind in `what`, folded unread), which a brain of format 8 from before it learned to fold one refuses; 10 adds the op
# `owner-soul-code` (the owner's step that gave a line already in the SOUL file a code; a brain of format 10 wrote it, this one
# folds it and writes none), which a brain of format 9 refuses to fold: a log needs 10 only once it holds one; 11 adds the op
# `ext` (an extension's own op, brain_ext.write_op or an owner verb's effect `op`, folded unread), which a brain of format 10
# refuses to fold: a log needs 11 only once it holds one. An export says FORMAT: an older brain refuses the bundle, saying to
# update (it could not land every item a newer brain writes, a focus with no owner's words among them)
FORMAT = 11
EXT_NAME = re.compile(r"[a-z][a-z0-9-]{1,23}")      # an extension's name, and the `what` of its op
LOCK_WAIT = 1.0                                     # seconds a SessionStart waits for the lock: to read, then to close by a link
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
QUOTE_NAMES = ("QUOTATION", "PRIME", "GERSHAYIM", "DITTO", "DOUBLE APOSTROPHE", "DOUBLE ACUTE", "SALTILLO", "CLICK")
APOSTROPHE_LIKE = frozenset("'`")                   # one is a plain apostrophe; two in a row pass for a `"`
DOTLESS = frozenset("\u0131\u0237")                 # ı ȷ: a mark on one shows the mark alone (ı + U+030E passes for a `"`)
SOFT_DOTTED = frozenset("ij\u012f\u0249\u0268\u03f3\u0456\u0458\u1e2d\u1ecb")   # their dot goes under a mark above,
DOUBLE_MARKS = frozenset("\u030b\u030e\u030f\u0348")    # so a double mark on one shows as ı + U+030E would
MARKS_RUN_MAX = 8                                   # combining marks in a row: Vietnamese 2, Tibetan stacks 6; 149 smear a line
EMOJI_BASES = frozenset((0x203C, 0x2049, 0x2139, 0x3030, 0x303D))   # emoji with a FE0F sequence outside So and Sm: ‼ ⁉ ℹ 〰 〽
GENESIS = "0" * 64
NO_DIALOG = ("owner items need a session that can show Claude Code's permission dialog; ask the owner in an interactive "
             "session")
ID_RE = re.compile(r"^[GDWPRNXTSQF][1-9][0-9]{0,5}$")
SOUL_CODE = re.compile(r"S(?:[0-9]{2}|[1-9][0-9]{2})")  # a SOUL rule's code (`[S07]` in CLAUDE.md), whole (fullmatch): two
                                                    # digits, or three with no leading zero, so each code has one spelling
RULE_LETTERS = ("D", "T", "F")                      # the items the ledger counts held and broke for, with the SOUL codes
SESSION_SOURCE = {"type": "coordinator"}            # the log's word, since its first format, for an item `brain op` wrote
# Claude Code's managed settings file (code.claude.com/docs/en/managed-settings); on Windows its path and the legacy one it no
# longer reads, read here too: one more place to look only makes the answerer check stricter
POSIX_MANAGED = ("/etc/claude-code/managed-settings.json", "/Library/Application Support/ClaudeCode/managed-settings.json")
WINDOWS_MANAGED = (r"C:\Program Files\ClaudeCode\managed-settings.json", r"C:\ProgramData\ClaudeCode\managed-settings.json")
MANAGED_SETTINGS = WINDOWS_MANAGED if WINDOWS else POSIX_MANAGED
VERSION_FLOOR = (2, 1, 211)                 # before it, auto mode could approve a hook's `ask` without the dialog
CLAUDE_PROGRAMS = ("claude", "claude.exe", "cli.js")  # an argv word naming Claude Code; also any path under claude/versions/
OFFICIAL_HOSTS = ("claude-vscode", "claude-desktop", "claude-desktop-3p")   # CLAUDE_CODE_ENTRYPOINT: VS Code, the desktop app
AUTO_WHERE = ("In a terminal, the VS Code extension or the Claude desktop app, switch the permission mode to default and ask "
              "again, or update Claude Code. Anywhere else (an SDK app, a custom prompt tool) %s refused in every mode: open "
              "Claude Code in one of those three")
O_BINARY = getattr(os, "O_BINARY", 0)               # Windows opens a file in text mode without it: CRLF written, Ctrl-Z ends a read


class Refused(Exception):
    """A refusal with its exit code: 1 refused, 3 not the writer, 4 worker, 5 log/head mismatch, 6 owner, 64 usage."""

    def __init__(self, rc, msg):
        Exception.__init__(self, msg)
        self.rc = rc
        self.msg = msg


# --- Windows: the account, its access rules, the lock and process trees (ctypes, msvcrt) --------------------------------------

_WIN, _MINE = {}, []
SID_TRUSTED = ("S-1-5-18", "S-1-5-32-544", "S-1-3-4", "S-1-3-0")   # SYSTEM, Administrators, OWNER RIGHTS, CREATOR OWNER
SYNCHRONIZE = 0x00100000                            # waiting on an object: the one right another account may hold


def _win():
    """kernel32, advapi32 and userenv with the signatures used here, loaded once."""
    if not _WIN:
        from ctypes import wintypes as w
        k, a, u = (ctypes.WinDLL(n, use_last_error=True) for n in ("kernel32", "advapi32", "userenv"))
        nt = ctypes.WinDLL("ntdll")
        ref = ctypes.POINTER

        class PE(ctypes.Structure):                 # PROCESSENTRY32W
            _fields_ = [("dwSize", w.DWORD), ("cntUsage", w.DWORD), ("th32ProcessID", w.DWORD),
                        ("th32DefaultHeapID", ctypes.c_size_t), ("th32ModuleID", w.DWORD), ("cntThreads", w.DWORD),
                        ("th32ParentProcessID", w.DWORD), ("pcPriClassBase", w.LONG), ("dwFlags", w.DWORD),
                        ("szExeFile", w.WCHAR * 260)]
        for f, res, args in ((k.GetCurrentProcess, w.HANDLE, []), (k.CloseHandle, w.BOOL, [w.HANDLE]),
                             (k.CreateToolhelp32Snapshot, w.HANDLE, [w.DWORD, w.DWORD]),
                             (k.Process32FirstW, w.BOOL, [w.HANDLE, ref(PE)]), (k.Process32NextW, w.BOOL, [w.HANDLE, ref(PE)]),
                             (k.GetProcessTimes, w.BOOL, [w.HANDLE] + [ref(w.FILETIME)] * 4),
                             (k.GetExitCodeProcess, w.BOOL, [w.HANDLE, ref(w.DWORD)]),
                             (k.QueryFullProcessImageNameW, w.BOOL, [w.HANDLE, w.DWORD, w.LPWSTR, ref(w.DWORD)]),
                             (nt.NtQueryInformationProcess, w.LONG, [w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.ULONG,
                                                                     ref(w.ULONG)]),
                             (k.CreateJobObjectW, w.HANDLE, [ctypes.c_void_p, w.LPCWSTR]),
                             (k.OpenProcess, w.HANDLE, [w.DWORD, w.BOOL, w.DWORD]),
                             (k.AssignProcessToJobObject, w.BOOL, [w.HANDLE, w.HANDLE]),
                             (k.TerminateJobObject, w.BOOL, [w.HANDLE, w.UINT]),
                             (a.OpenProcessToken, w.BOOL, [w.HANDLE, w.DWORD, ref(w.HANDLE)]),
                             (a.GetTokenInformation, w.BOOL, [w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.DWORD, ref(w.DWORD)]),
                             (a.GetFileSecurityW, w.BOOL, [w.LPCWSTR, w.DWORD, ctypes.c_void_p, w.DWORD, ref(w.DWORD)]),
                             (u.GetUserProfileDirectoryW, w.BOOL, [w.HANDLE, w.LPWSTR, ref(w.DWORD)])):
            f.restype, f.argtypes = res, args
        _WIN.update(k=k, a=a, u=u, nt=nt, w=w, PE=PE)
    return _WIN


def _winerr():
    """The OSError of the Windows call that just failed."""
    return ctypes.WinError(ctypes.get_last_error())


@contextlib.contextmanager
def _token():
    """This process's access token, opened for reading (TOKEN_QUERY)."""
    W = _win()
    h = W["w"].HANDLE()
    if not W["a"].OpenProcessToken(W["k"].GetCurrentProcess(), 0x0008, ctypes.byref(h)):
        raise _winerr()
    try:
        yield h
    finally:
        W["k"].CloseHandle(h)


def _sized(call):
    """The buffer a Windows call fills once it has said its size: call(buffer, size, byref(size needed)), nonzero on success."""
    n = _win()["w"].DWORD(0)
    call(None, 0, ctypes.byref(n))
    if not n.value:
        raise _winerr()
    buf = ctypes.create_string_buffer(n.value)
    if not call(buf, n, ctypes.byref(n)):
        raise _winerr()
    return buf


def my_sids():
    """(the user, the default owner) of this process's token as SID text: who this account is, and whom it makes the owner of
    what it creates (the Administrators group for an elevated administrator)."""
    if not _MINE:
        mine = []
        with _token() as h:
            for cls in (1, 4):                      # TokenUser, TokenOwner: a pointer to a SID that lies in the same buffer
                buf = _sized(lambda b, n, r: _win()["a"].GetTokenInformation(h, cls, b, n, r))
                at = (ctypes.cast(buf, ctypes.POINTER(ctypes.c_void_p))[0] or 0) - ctypes.addressof(buf)
                sid = sid_text(buf.raw, at)
                if sid is None:
                    raise OSError("the process token's SID cannot be read")
                mine.append(sid)
        _MINE[:] = mine
    return tuple(_MINE)


def win_profile():
    """The profile folder Windows keeps for this process's account (GetUserProfileDirectoryW), whatever USERPROFILE says."""
    W = _win()
    with _token() as h:
        n = W["w"].DWORD(0)
        W["u"].GetUserProfileDirectoryW(h, None, ctypes.byref(n))
        buf = ctypes.create_unicode_buffer(n.value or 1)
        if not n.value or not W["u"].GetUserProfileDirectoryW(h, buf, ctypes.byref(n)):
            raise _winerr()
    return buf.value


def sid_text(b, at):
    """The SID at offset `at` of the bytes `b` as text ("S-1-5-18"), None when it does not fit in `b` or is not a SID."""
    if not 0 <= at <= len(b) - 8 or b[at] != 1 or b[at + 1] > 15 or at + 8 + 4 * b[at + 1] > len(b):
        return None
    return "S-1-%d" % int.from_bytes(b[at + 2:at + 8], "big") + "".join(
        "-%d" % x for x in struct.unpack_from("<%dI" % b[at + 1], b, at + 8))


def sd_problem(sd, mine, owner_only=False):
    """Why the self-relative security descriptor `sd` (bytes: owner and DACL) does not keep what it guards to this account,
    None when it does: its owner is one of `mine`, and each allow rule names `mine`, SYSTEM, Administrators, OWNER RIGHTS or
    CREATOR OWNER, or grants nothing but SYNCHRONIZE. A rule only children inherit counts too: the brain's files would get it.
    No DACL (everyone may do anything), a rule of a kind other than allow or deny, and an offset or a length that does not fit
    are problems: nothing is answered from part of a descriptor. With owner_only, only the owner is read."""
    cut = "its security descriptor does not add up"
    if len(sd) < 20:
        return cut
    rev, _, ctrl, o_owner, _, _, o_dacl = struct.unpack_from("<BBHIIII", sd, 0)
    if rev != 1 or not ctrl & 0x8000:               # SE_SELF_RELATIVE: offsets into these bytes, not pointers
        return cut
    owner = sid_text(sd, o_owner) if o_owner else None
    if owner is None:
        return cut
    if owner not in mine:
        return "it is not this account's (its owner is %s)" % owner
    if owner_only:
        return None
    if not ctrl & 0x0004 or not o_dacl:             # SE_DACL_PRESENT
        return "it has no access list, so everyone can use it"
    if o_dacl > len(sd) - 8:
        return cut
    arev, _, size, count, _ = struct.unpack_from("<BBHHH", sd, o_dacl)
    at, end = o_dacl + 8, o_dacl + size
    if arev not in (2, 4) or size < 8 or end > len(sd):
        return cut
    for _ in range(count):
        if at > end - 4:
            return cut
        kind, _, asize = struct.unpack_from("<BBH", sd, at)
        if asize < 4 or at + asize > end:
            return cut
        if kind not in (1, 6, 10, 12):              # a deny rule only takes access away
            if kind != 0:                           # ACCESS_ALLOWED_ACE is the one allow rule read here
                return "it has an access rule of a kind this check does not read (type %d)" % kind
            sid = sid_text(sd[at + 8:at + asize], 0) if asize >= 16 else None
            if sid is None:
                return cut
            mask = struct.unpack_from("<I", sd, at + 4)[0]
            if mask & ~SYNCHRONIZE and sid not in mine and sid not in SID_TRUSTED:
                return "%s can use it (access 0x%08x)" % (sid, mask)
        at += asize
    return None


def access_problem(path, owner_only=False):
    """sd_problem of what `path` names (Windows; GetFileSecurityW follows a link, as a write would), None when it is this
    account's alone; OSError when Windows cannot say."""
    W = _win()
    buf = _sized(lambda b, n, r: W["a"].GetFileSecurityW(path, 0x1 | 0x4, b, n, r))   # OWNER and DACL_SECURITY_INFORMATION
    return sd_problem(buf.raw, my_sids(), owner_only)


def private(p):
    """Refused(1) unless the directory `p` is this account's and nobody else's: on Windows, which has no mode to put back."""
    try:
        why = access_problem(p)
    except OSError as e:
        why = "its owner and access list cannot be read (%s)" % e
    if why:
        raise Refused(1, "the brain's directory %s is refused: %s; the brain README's Windows section says how to make it "
                         "private again" % (printable(p), why))



def open_to_others(path, st_):
    """Group or others can use `path` (its stat `st_`); on Windows, where the mode says nothing, its owner and access list."""
    if not WINDOWS:
        return st_.st_mode & 0o077
    try:
        return access_problem(path) is not None
    except OSError:
        return True


HELD = PermissionError if WINDOWS else OSError      # what taking a lock another open file holds, without waiting, raises


def lock_nb(fd):
    """The lock on the open file `fd`, taken at once, or HELD. POSIX: flock. Windows: msvcrt's lock on byte 0 (past the end of
    the empty lock file), which Windows drops when the file closes or its process ends."""
    if WINDOWS:
        msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
    else:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)


def unlock(fd):
    """Give the lock on `fd` back before it closes: Windows may drop a closed file's lock late (POSIX: the close does it)."""
    if WINDOWS:
        with contextlib.suppress(OSError):
            msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)


def spawn(argv, **kw):
    """subprocess.Popen(argv) in a group of its own that kill_tree ends whole: a new session on POSIX, a job object on Windows
    (what the child starts joins the job and cannot leave it). A child the job cannot take is killed and OSError raised."""
    if not WINDOWS:
        return subprocess.Popen(argv, start_new_session=True, **kw)
    p = subprocess.Popen(argv, **kw)
    # shortcut: the child runs a few microseconds before it joins the job, so a process it starts in that time is not in the
    # job, and a read of a pipe that process holds then waits for it (a hang where POSIX only loses output); start the child
    # suspended and resume it after the join if a hang ever escapes this way
    try:
        p.job = _job(p.pid)
    except OSError:
        p.kill()
        p.wait()
        raise
    return p


def _job(pid):
    """A new job object holding the process `pid` (a child not reaped yet, so the pid is still that child's)."""
    k = _win()["k"]
    job = k.CreateJobObjectW(None, None)
    if not job:
        raise _winerr()
    h = k.OpenProcess(0x0101, False, pid)          # PROCESS_TERMINATE | PROCESS_SET_QUOTA, what joining a job needs
    err = None if h and k.AssignProcessToJobObject(job, h) else _winerr()
    if h:
        k.CloseHandle(h)
    if err:
        k.CloseHandle(job)
        raise err
    return job


def kill_tree(p):
    """End what still runs in the group spawn() gave `p`, its children included; OSError when that fails."""
    if not WINDOWS:
        os.killpg(p.pid, signal.SIGKILL)
        return
    job, p.job = getattr(p, "job", None), None
    if job:
        k = _win()["k"]
        err = None if k.TerminateJobObject(job, 1) else _winerr()
        k.CloseHandle(job)
        if err:
            raise err


# The processes that started this one (Windows), read so that a parent able to answer the owner's dialog is seen: their
# parent ids from a Toolhelp snapshot, each one's command line from NtQueryInformationProcess, class 60
# (ProcessCommandLineInformation, Windows 8.1 and later), with PROCESS_QUERY_LIMITED_INFORMATION: no read of another process's
# memory. Their working directory and environment live in that memory, so they are not read (README, On Windows).

class Unread(Exception):
    """A running parent process whose command line cannot be read: an owner write is refused, never allowed for want of a look."""


def win_chain(pid, table, info, stop=None, bridge=None):
    """[(pid, command line)] of the processes above `pid`, nearest first, from `table` ({pid: parent pid}, a snapshot) and
    `info(pid)` ((creation time, command line); ProcessLookupError when it has ended, OSError when it cannot be read). A
    parent that no longer runs (not in the table, or an id a younger process took: created after its child) ends the chain,
    a dead process answers no prompt, unless `bridge(pid, below)` names the parent Git Bash keeps for `pid` (`below`: the
    process walked just under it): a Git Bash program whose own parent is one ends its Windows process when it execs another,
    which keeps its Git Bash parent. System ends it.
    Unread when a running parent or what `bridge` reads cannot be read, when `pid` or a bridged parent is not in the table,
    or when the chain does not end within 64. `stop`: a process the walk ends below (the suites' own shell)."""
    if pid not in table:
        raise Unread("process %d is not in the process table" % pid)
    try:
        t = info(pid)[0]
    except OSError as e:
        raise Unread("process %d: %s" % (pid, e.strerror or e))
    out, below = [], None
    for _ in range(64):
        ppid = table[pid]
        if ppid in (0, 4) or ppid == stop:
            return out
        got = None
        if ppid in table:
            try:
                got = info(ppid)
            except ProcessLookupError:
                pass
            except OSError as e:
                raise Unread("process %d: %s" % (ppid, e.strerror or e))
            if got and got[0] > t:
                got = None
        if got is None:
            try:
                ppid = bridge(pid, below) if bridge else None
            except OSError as e:
                raise Unread("the Git Bash parent of process %d: %s" % (pid, e.strerror or e))
            if ppid is None or ppid == stop:
                return out
            if ppid not in table:
                raise Unread("process %d, Git Bash's parent of %d, is not in the process table" % (ppid, pid))
            try:
                got = info(ppid)
            except OSError as e:
                raise Unread("process %d: %s" % (ppid, e.strerror or e))
            if got[0] > t:
                raise Unread("process %d, Git Bash's parent of %d, started after it" % (ppid, pid))
        out.append((ppid, got[1]))
        below, pid, t = pid, ppid, got[0]
    raise Unread("the chain of parent processes does not end within 64")


MSYS_ROW = re.compile(r"[ SIO] +([0-9]+) +([0-9]+) +[0-9]+ +([0-9]+) ")   # ps.cc's long form: status, PID PPID PGID WINPID


def msys_table(text):
    """({Windows pid: (Git Bash pid, its Git Bash parent)}, {Git Bash pid: Windows pid}) from the output of Git Bash's `ps`
    (its long form: a status letter, then PID PPID PGID WINPID …; a Git Bash pid shows the Windows pid of its newest program);
    OSError when it is not that output, or a row is not one. Rows end at a newline only, so a program's name cannot add one;
    a process ended and not yet reaped (`<defunct>`, its Windows pid free for another) is left out."""
    lines = text.split("\n")
    if lines[0].split()[:4] != ["PID", "PPID", "PGID", "WINPID"]:
        raise OSError("ps printed no process table")
    byw, byc = {}, {}
    for line in lines[1:]:
        m = MSYS_ROW.match(line)
        if not m:
            if line.strip():
                raise OSError("ps printed a row this check cannot read")
            continue
        if line.rstrip().endswith(" <defunct>"):
            continue
        pid, ppid, w = (int(g) for g in m.groups())
        byw[w], byc[pid] = (pid, ppid), w
    return byw, byc


def _msys_bridge():
    """bridge(pid, below) for win_chain: the Windows pid of the parent Git Bash (or Cygwin) keeps for `pid` when `pid`'s program
    sits beside that runtime's DLL, read once from the runtime's own `ps -a` beside it. A Git Bash pid shows its newest
    program, so `pid` waiting on the native program it exec-ed is found by that program, `below`. None for any other
    program. OSError when the table cannot be read, when the process is not in it, when its Git Bash parent is 1 (an ended
    parent, or a native program that started it, whose first program may still wait above the break), or when its parent
    is not in the table."""
    tables = {}

    def bridge(pid, below):
        d = os.path.dirname(_win_image(pid))
        if not any(os.path.isfile(os.path.join(d, n)) for n in ("msys-2.0.dll", "cygwin1.dll")):
            return None
        if d not in tables:
            try:
                env = {k: v for k, v in os.environ.items() if k.upper() != "COLUMNS"}   # ps cuts each line to COLUMNS
                r = subprocess.run([os.path.join(d, "ps.exe"), "-a"], capture_output=True, timeout=10,
                                   stdin=subprocess.DEVNULL, env=env)
            except subprocess.SubprocessError as e:
                raise OSError(str(e))
            if r.returncode != 0:
                raise OSError("ps.exe exited %d" % r.returncode)
            tables[d] = msys_table(r.stdout.decode("utf-8", "replace"))
        byw, byc = tables[d]
        mine = byw.get(pid) or byw.get(below)
        if not mine:
            raise OSError("Git Bash's process table does not hold it")
        if mine[1] <= 1:
            raise OSError("Git Bash keeps no running parent of it, and the program above the break is not known")
        if mine[1] not in byc:
            raise OSError("its Git Bash parent %d is not in Git Bash's process table" % mine[1])
        return byc[mine[1]]
    return bridge


def us_text(b, base):
    """The text of the UNICODE_STRING at the start of `b`, the bytes a call filled at address `base` (its Buffer points into
    them); None when a length or the pointer does not fit in `b`. Nothing is read outside `b`."""
    head = struct.calcsize("HHP")
    if len(b) < head:
        return None
    n, most, ptr = struct.unpack_from("HHP", b, 0)
    at = ptr - base
    if n % 2 or n > most or not head <= at <= len(b) - n:
        return None
    try:
        return b[at:at + n].decode("utf-16-le")
    except UnicodeDecodeError:
        return None


def split_cmdline(c):
    """The argv a Windows program's C runtime makes of the command line `c`: the first word ends at a space or tab outside
    quotes, with no escapes; in the others 2n backslashes and a quote are n backslashes and a quote that opens or closes,
    2n+1 and a quote are n backslashes and a literal quote, other backslashes are literal, and "" inside quotes is a quote."""
    out, i, n = [], 0, len(c)
    word, q = [], False
    while i < n and (q or c[i] not in " \t"):
        if c[i] == '"':
            q = not q
        else:
            word.append(c[i])
        i += 1
    out.append("".join(word))
    while True:
        while i < n and c[i] in " \t":
            i += 1
        if i >= n:
            return out
        word, q = [], False
        while i < n and (q or c[i] not in " \t"):
            if c[i] == "\\":
                j = i
                while j < n and c[j] == "\\":
                    j += 1
                if j < n and c[j] == '"':
                    word.append("\\" * ((j - i) // 2))
                    if (j - i) % 2:
                        word.append('"')
                        j += 1
                else:
                    word.append("\\" * (j - i))
                i = j
            elif c[i] == '"':
                if q and c[i + 1:i + 2] == '"':
                    word.append('"')
                    i += 2
                else:
                    q = not q
                    i += 1
            else:
                word.append(c[i])
                i += 1
        out.append("".join(word))


def split_cmdline_w(c):
    """The argv CommandLineToArgvW makes of `c` (what a program built on it, an older Bun's among them, sees): the first word
    ends at the next quote when it starts with one, and the next starts right there; backslashes as split_cmdline; in a run
    of quotes, every third is a literal quote and the run leaves the quotes."""
    out, i, n = [], 0, len(c)
    word = []
    if c[:1] == '"':
        i = 1
        while i < n and c[i] != '"':
            word.append(c[i])
            i += 1
        i += 1
    else:
        while i < n and c[i] not in " \t":
            word.append(c[i])
            i += 1
    out.append("".join(word))
    while i < n and c[i] in " \t":
        i += 1
    if i >= n:
        return out
    word, q, b = [], 0, 0
    while i < n:
        ch = c[i]
        if ch in " \t" and q == 0:
            out.append("".join(word))
            word, b = [], 0
            while i < n and c[i] in " \t":
                i += 1
            if i >= n:
                return out
            continue
        if ch == "\\":
            word.append(ch)
            b += 1
            i += 1
        elif ch == '"':
            if b % 2 == 0:
                del word[len(word) - b // 2:]
                q += 1
            else:
                del word[len(word) - b // 2 - 1:]
                word.append('"')
            i, b = i + 1, 0
            while i < n and c[i] == '"':
                q += 1
                if q == 3:
                    word.append('"')
                    q = 0
                i += 1
            if q == 2:
                q = 0
        else:
            word.append(ch)
            b = 0
            i += 1
    out.append("".join(word))
    return out


def _win_table():
    """{pid: parent pid} of the processes running now (a Toolhelp snapshot); OSError when Windows will not give one."""
    W = _win()
    k = W["k"]
    snap = k.CreateToolhelp32Snapshot(0x2, 0)       # TH32CS_SNAPPROCESS
    if snap in (None, ctypes.c_void_p(-1).value):
        raise _winerr()
    try:
        pe, table = W["PE"](), {}
        pe.dwSize = ctypes.sizeof(pe)
        more = k.Process32FirstW(snap, ctypes.byref(pe))
        while more:
            table[pe.th32ProcessID] = pe.th32ParentProcessID
            more = k.Process32NextW(snap, ctypes.byref(pe))
        if ctypes.get_last_error() != 18:           # ERROR_NO_MORE_FILES ends the list; anything else cut it short
            raise _winerr()
    finally:
        k.CloseHandle(snap)
    return table


def _win_info(pid):
    """(creation time, command line) of the running process `pid`; ProcessLookupError when it has ended, OSError when Windows
    will not say."""
    W = _win()
    k, w = W["k"], W["w"]
    h = k.OpenProcess(0x1000, False, pid)           # PROCESS_QUERY_LIMITED_INFORMATION
    if not h:
        e = ctypes.get_last_error()
        if e == 87:                                 # ERROR_INVALID_PARAMETER: no process has this id now
            raise ProcessLookupError(pid)
        raise ctypes.WinError(e)
    try:
        code, ft = w.DWORD(), [w.FILETIME() for _ in range(4)]
        if not k.GetExitCodeProcess(h, ctypes.byref(code)) or not k.GetProcessTimes(h, *map(ctypes.byref, ft)):
            raise _winerr()
        if code.value != 259:                       # STILL_ACTIVE: a process that has ended can still be open
            raise ProcessLookupError(pid)
        size = w.ULONG(0)
        W["nt"].NtQueryInformationProcess(h, 60, None, 0, ctypes.byref(size))
        buf = ctypes.create_string_buffer(size.value or 1)
        st = W["nt"].NtQueryInformationProcess(h, 60, buf, size.value, ctypes.byref(size))
        text = us_text(buf.raw[:size.value], ctypes.addressof(buf)) if st >= 0 and size.value <= len(buf) else None
        if text is None:
            raise OSError("its command line cannot be read (NTSTATUS 0x%08x)" % (st & 0xFFFFFFFF))
        return ft[0].dwHighDateTime << 32 | ft[0].dwLowDateTime, text
    finally:
        k.CloseHandle(h)


def _win_image(pid):
    """The full path of the program the running process `pid` runs; OSError when Windows will not say."""
    W = _win()
    k, w = W["k"], W["w"]
    h = k.OpenProcess(0x1000, False, pid)           # PROCESS_QUERY_LIMITED_INFORMATION
    if not h:
        raise _winerr()
    try:
        buf, n = ctypes.create_unicode_buffer(32768), w.DWORD(32768)
        if not k.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(n)):
            raise _winerr()
        return buf.value
    finally:
        k.CloseHandle(h)


def win_ancestors():
    """[(argv, None, None, None)] of the processes above this one, in _ancestors' form (working directory and environment
    unread), each command line split by both rules a Windows program may use; Unread when one cannot be read."""
    try:
        table = _win_table()
    except OSError as e:
        raise Unread("the process table cannot be read (%s)" % e)
    chain = win_chain(os.getpid(), table, _win_info, bridge=_msys_bridge())
    return [(argv, None, None, None) for _, c in chain for argv in (split_cmdline(c), split_cmdline_w(c))]


# --- where state lives --------------------------------------------------------------------------------------------------------

def account_home():
    """The account's home from the password database (on Windows the profile folder Windows keeps for it): HOME, and on Windows
    USERPROFILE, can be emptied or pointed elsewhere, this cannot."""
    try:
        return win_profile() if WINDOWS else pwd.getpwuid(os.getuid()).pw_dir
    except (KeyError, OSError):
        return ""


def home():
    """HOME when it is an absolute path, else the account's home (an empty HOME would make every path relative)."""
    h = os.environ.get("HOME", "")
    return h if os.path.isabs(h) else account_home()


def config_dir(cwd=None):
    """Claude Code's config directory as this process sees it: CLAUDE_CONFIG_DIR (a relative one from `cwd`), else ~/.claude."""
    c = os.environ.get("CLAUDE_CONFIG_DIR", "")
    return os.path.join(cwd or working_dir(), c) if c else os.path.join(home(), ".claude")


def state_root():
    x = os.environ.get("XDG_STATE_HOME", "")
    base = x if os.path.isabs(x) else os.path.join(home(), ".local", "state")
    r = os.path.join(base, "vibemaestro", "brain")
    return r.replace("/", "\\") if WINDOWS else r    # one spelling on Windows (Git Bash hands C:/…), every path below it the same


def same_path(a, b):
    """`a` and `b` name the same path as written (separators, case on Windows, `.` and `..` read lexically), not as strings."""
    return os.path.normcase(os.path.normpath(a)) == os.path.normcase(os.path.normpath(b))


class Gone(Refused):
    """The working directory was deleted under the shell (a hook stays silent on it)."""


def working_dir():
    """os.getcwd(); refused (1, Gone) when the directory was deleted under the shell, rather than a guess at another project."""
    try:
        return os.getcwd()
    except OSError:
        try:                                        # Linux names a deleted cwd `<path> (deleted)`; else the shell's PWD
            pwd_ = os.readlink("/proc/self/cwd")
            pwd_ = pwd_[:-len(" (deleted)")] if pwd_.endswith(" (deleted)") else pwd_
        except OSError:
            pwd_ = os.environ.get("PWD", "")
        raise Gone(1, "the working directory %sno longer exists (it was deleted under the shell): cd into the project and run "
                      "it again; nothing was read or written" % ("%s " % printable(pwd_) if os.path.isabs(pwd_) else ""))


def project_dir(cwd=None):
    """The git common directory (so every worktree shares one brain), else the working directory."""
    cwd = cwd or working_dir()
    out = _git(cwd, "rev-parse", "--git-common-dir")
    if out and out.strip():
        return os.path.realpath(os.path.join(cwd, out.strip()))
    return os.path.realpath(cwd)


def project_root(cwd=None):
    """The work tree's top level of `cwd`; with no `cwd`, of this session's project (its record), else of the working directory."""
    b = bound() if cwd is None else None
    cwd = cwd or (b["project"] if b else working_dir())
    out = _git(cwd, "rev-parse", "--show-toplevel")
    if out and out.strip():
        return out.strip()
    return os.path.realpath(cwd)


def state_dir(cwd=None):
    """`<state root>/<base name>-<12 hex of the SHA-1 of the project path>`; not created here. With no `cwd`: this session's
    project (its record), else the working directory's."""
    if cwd is None:
        b = bound()
        if b:
            return b["state"]
    p = project_dir(cwd)
    name = os.path.basename(os.path.dirname(p)) if os.path.basename(p) == ".git" else os.path.basename(p)
    name = re.sub(r"[^A-Za-z0-9._-]", "_", name)[:40] or "project"
    try:
        raw = p.encode("utf-8")
    except UnicodeEncodeError:                      # a path that is not UTF-8: its bytes (no brain could be written there before)
        raw = os.fsencode(p)
    return os.path.join(state_root(), "%s-%s" % (name, hashlib.sha1(raw).hexdigest()[:12]))


# --- the session's own project ------------------------------------------------------------------------------------------------
# A session works in one project, whatever directory its shell has moved to. The hooks know it (CLAUDE_PROJECT_DIR, the
# directory the session started in) and record it under the session id; the CLI has only the session id in the Bash tool's
# environment (CLAUDE_CODE_SESSION_ID, the same in a subagent), so it reads the record. No record, or no session: the cwd.

SESSION_MAX_AGE = 30 * 86400           # seconds: a record this old is a crashed session's (SessionEnd removes the others)
_BOUND = []


def shell_dir():
    """The working directory, or a phrase when it was deleted under the shell (os.getcwd() raises then)."""
    try:
        return os.getcwd()
    except OSError:
        return "a directory that no longer exists"


def session_file(sid):
    return os.path.join(state_root(), "sessions", hashlib.sha256(sid.encode("utf-8")).hexdigest()[:32])


def read_session(sid):
    """{"project", "state"} the session recorded, None when it recorded none; a record that cannot be trusted is refused, so
    the CLI never falls back to another project in silence."""
    p = session_file(sid)
    try:
        with open(p, encoding="utf-8") as f:
            r = json.loads(f.read())
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as e:
        raise Refused(1, "this session's project record %s cannot be read (%s); the shell is in %s; nothing was read or "
                         "written" % (p, e.__class__.__name__, shell_dir()))
    if WINDOWS:                                     # a record in a sessions/ another account may change is not trusted
        private(os.path.dirname(p))
    project, state = (r.get("project"), r.get("state")) if isinstance(r, dict) else (None, None)
    if not (isinstance(project, str) and os.path.isabs(project) and isinstance(state, str)
            and os.path.dirname(os.path.normpath(state)) == os.path.normpath(state_root())
            and os.path.basename(state) not in ("", ".", "..", "pending", "sessions")):
        raise Refused(1, "this session's project record %s does not name a project and its brain state directory; the shell "
                         "is in %s; nothing was read or written" % (p, shell_dir()))
    return {"project": project, "state": os.path.normpath(state)}


def bound():
    """This session's recorded project (read once per process), None outside a Claude Code session or without a record."""
    if not _BOUND:
        sid = session_id()
        _BOUND.append(read_session(sid) if sid else None)
    return _BOUND[0]


def session_note():
    """One line when the shell's directory belongs to another project than this session's record, else None."""
    b = bound()
    if not b:
        return None
    here = shell_dir()
    if not os.path.isabs(here) or not same_path(state_dir(here), b["state"]):
        return "this session's project is %s; the shell is in %s; using %s" % (b["project"], here, b["project"])
    return None


def record_session(sid, project, d):
    """Record `project` (state directory `d`) as session `sid`'s; returns the other project it replaced, else None. Records
    older than SESSION_MAX_AGE are swept."""
    sd = sessions_dir()
    p = session_file(sid)
    try:
        old = read_session(sid)
    except Refused:
        old = None
    if old == {"project": project, "state": d}:
        os.utime(p)
        return None
    _write_file(p, json.dumps({"project": project, "state": d}) + "\n")
    now = time.time()
    for name in os.listdir(sd):
        with contextlib.suppress(OSError):
            q = os.path.join(sd, name)
            if now - os.lstat(q).st_mtime > SESSION_MAX_AGE:
                os.unlink(q)
    return old["project"] if old and not same_path(old["state"], d) else None


def sessions_dir():
    """`<state root>/sessions/`, created 0700 with the root above it when missing."""
    root = state_root()
    sd = os.path.join(root, "sessions")
    for q in (os.path.dirname(root), root, sd):
        if not os.path.isdir(q):
            os.makedirs(os.path.dirname(q), exist_ok=True)
            with contextlib.suppress(FileExistsError):
                os.mkdir(q, 0o700)
        if WINDOWS and q != os.path.dirname(root):  # the root and sessions/ are the brain's own: checked before a record goes in
            private(q)
    return sd


def drop_session(sid):
    with contextlib.suppress(OSError):
        os.unlink(session_file(sid))


def mark_env(sid, bin_dir):
    """The session's start put `bin_dir` first on PATH for its Bash commands (CLAUDE_ENV_FILE); swept with the records."""
    sessions_dir()
    _write_file(session_file(sid) + ".env", bin_dir + "\n")


def env_marked(sid):
    """The bin directory the session's start put first on PATH, None when it put none (or the mark does not read)."""
    try:
        with open(session_file(sid) + ".env", encoding="utf-8") as f:
            return f.read().strip() or None
    except (OSError, ValueError):
        return None


# --- the project's configuration ----------------------------------------------------------------------------------------------
# `.vibemaestro/brain.json` at the top of the session's work tree, or of its main work tree when it is a linked worktree: every
# worktree of a repository writes one brain log, so all of them, the hooks and the CLI alike, read one file. Every key has a
# default; an unknown key warns and is ignored; a known key with a wrong value, a newer schema or a file that is not a regular
# JSON file makes every item write refuse (rc 1; `brain claim` still works, so a session can take the brain back) while every
# read uses that key's default. A left cap (G, D, W) off its default is flagged: the owner's decision.

CONFIG_FILE = ".vibemaestro/brain.json"             # a repository path in messages: `/` on every system, as the docs write it
CONFIG_SCHEMA = 1
CONFIG_BYTES = 65536
RANGES = {"caps": (1, 100), "text_max": (50, 1000), "text_caps": (50, 1000), "quote_max": (100, 2000), "untouched": (1, 365)}
# days a right-brain item goes untouched before every load marks it (brain_stale.untouched); the left brain is never marked
DEFAULT_UNTOUCHED = {"N": 7, "X": 14, "S": 21, "Q": 21, "R": 30, "T": 60, "F": 60}
# the ledger's thresholds (brain_ledger), each with its default
LEDGER_DEFAULTS = {"promote_held": 5, "promote_sessions": 3, "promote_days": 7, "promote_clean_days": 30, "drift_broke": 2,
                   "drift_sessions": 2, "drift_checks": 3, "drift_one_in": 3, "drift_days": 30, "dormant_days": 30}
LEDGER_RANGES = {"promote_held": (1, 100), "promote_sessions": (1, 100), "promote_days": (0, 365), "promote_clean_days": (0, 365),
                 "drift_broke": (1, 100), "drift_sessions": (1, 100), "drift_checks": (1, 100), "drift_one_in": (1, 100),
                 "drift_days": (1, 365), "dormant_days": (1, 365)}
_PROJECT = []
_ROOT = []                                          # [the config root, doctor's notes on it]
_CONF = {}


def use_project(path):
    """The hooks name the session's project (CLAUDE_PROJECT_DIR); the CLI finds it from the session's record, else its cwd."""
    _PROJECT[:] = [path]
    _ROOT[:] = []


def config_root():
    """Where the session's config lives, resolved once per process (`main_tree`)."""
    if not _ROOT:
        base = _PROJECT[0] if _PROJECT else (bound() or {}).get("project")
        notes = []
        _ROOT[:] = [main_tree(base or shell_dir(), notes), notes]
    return _ROOT[0]


def _git(cwd, *args):
    """git's one-line answer, without its final newline (a path may hold others), decoded as the OS decodes paths; None when it
    fails or cannot run."""
    try:
        r = subprocess.run(["git"] + list(args), cwd=cwd, capture_output=True, timeout=10)
    except (OSError, ValueError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    out = os.fsdecode(r.stdout)
    return out[:-1] if out.endswith("\n") else out


def main_tree(cwd, notes=None):
    """The work tree whose config every worktree of `cwd`'s repository reads: `cwd`'s own top level, unless it is a linked
    worktree (its git directory is not the common one) or a git directory; then the work tree the common directory names
    (`core.worktree`, as a submodule's does), else the parent of a common directory named `.git`, else the directory that holds
    a bare repository, else its own top level: git records no main work tree for a git directory kept apart. Not in git: `cwd`
    itself. A tree that reads its own file while its brain log is shared with another's adds a line for doctor to `notes`."""
    top = _git(cwd, "rev-parse", "--show-toplevel")
    gd = _git(cwd, "rev-parse", "--git-dir")
    cd = _git(cwd, "rev-parse", "--git-common-dir")
    if not (gd and cd):
        return os.path.realpath(cwd) if os.path.isdir(cwd) else cwd
    gd, cd = os.path.realpath(os.path.join(cwd, gd)), os.path.realpath(os.path.join(cwd, cd))
    note = notes.append if notes is not None else (lambda _: None)
    if top and gd == cd:                            # the main work tree, or one with its own git directory
        if os.path.basename(cd) == ".git" and os.path.dirname(cd) != os.path.realpath(top):
            note("%s is read from this work tree only, yet its brain log is shared with %s, whose .git this one links to: "
                 "keep the same file in both" % (CONFIG_FILE, os.path.dirname(cd)))
        return top
    wt = _git(cwd, "--git-dir=" + cd, "config", "--get", "core.worktree")
    if wt:
        return os.path.realpath(os.path.join(cd, wt))
    if os.path.basename(cd) == ".git":
        return os.path.dirname(cd)
    if _git(cwd, "--git-dir=" + cd, "rev-parse", "--is-bare-repository") == "true":
        return os.path.dirname(cd)
    note("%s is read from this work tree only, yet its brain log is shared with every work tree of %s: git records no main "
         "work tree for a git directory kept apart; keep the same file in each" % (CONFIG_FILE, cd))
    return top or os.path.realpath(cwd)


def _int_in(v, key):
    lo, hi = RANGES[key]
    return isinstance(v, int) and not isinstance(v, bool) and lo <= v <= hi


def read_config(root):
    """{"caps", "text_max", "text_caps", "quote_max"} with every default filled, plus "found" (the file exists), "warnings"
    (unknown keys), "errors" (a wrong value, a newer schema, not JSON: the key's default is used) and "left" ([(letter, value,
    default)] of each left cap off its default)."""
    out = {"caps": dict(DEFAULT_CAPS), "text_max": TEXT_MAX, "text_caps": dict(TEXT_CAPS), "quote_max": QUOTE_MAX,
           "found": False, "warnings": [], "errors": [], "left": [], "path": os.path.join(root, CONFIG_FILE)}
    out["ledger"] = dict(LEDGER_DEFAULTS)
    out["untouched"] = dict(DEFAULT_UNTOUCHED)
    out["soul_file"] = None
    try:
        fd = os.open(out["path"], os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | O_BINARY)    # a FIFO opens at once instead of waiting for a writer
    except FileNotFoundError:
        return out
    except OSError as e:
        out["found"] = True
        out["errors"].append("cannot be read (%s)" % e.__class__.__name__)
        return out
    out["found"] = True
    try:
        with os.fdopen(fd, "rb") as f:
            if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
                out["errors"].append("is not a regular file")
                return out
            data = f.read(CONFIG_BYTES + 1)
        if len(data) > CONFIG_BYTES:
            raise ValueError
        c = json.loads(data.decode("utf-8"))
        if not isinstance(c, dict):
            raise ValueError
    except OSError as e:
        out["errors"].append("cannot be read (%s)" % e.__class__.__name__)
        return out
    except (ValueError, UnicodeDecodeError, RecursionError):
        out["errors"].append("is not a JSON object of at most %d bytes" % CONFIG_BYTES)
        return out
    schema = c.get("schema", CONFIG_SCHEMA)
    if not isinstance(schema, int) or isinstance(schema, bool) or schema < 1:
        out["errors"].append("schema must be %d" % CONFIG_SCHEMA)
    elif schema > CONFIG_SCHEMA:
        out["errors"].append("schema %d is newer than this brain reads (%d): update vibemaestro-brain" % (schema, CONFIG_SCHEMA))
        return out
    for k in sorted(c):
        if k not in ("schema", "caps", "text_max", "text_caps", "quote_max", "ledger", "untouched", "soul_file"):
            out["warnings"].append("unknown key %s (ignored)" % printable(json.dumps(k))[:40])
    read_ledger(c, out)
    if "soul_file" in c:                            # the file that holds the SOUL lines, relative to this file's work tree
        v = c["soul_file"]
        if isinstance(v, str) and 0 < len(v) <= 1024 and "\x00" not in v:
            out["soul_file"] = v
        else:
            out["errors"].append("soul_file must be a path of 1 to 1024 characters")
    for key, letters in (("caps", DEFAULT_CAPS), ("text_caps", DEFAULT_CAPS), ("untouched", DEFAULT_UNTOUCHED)):
        if key not in c:
            continue
        if not isinstance(c[key], dict):
            out["errors"].append("%s must be an object of letters" % key)
            continue
        for k in sorted(c[key]):
            if k not in letters:
                out["warnings"].append("unknown key %s.%s (ignored)" % (key, printable(json.dumps(k))[:40]))
            elif _int_in(c[key][k], key):
                out[key][k] = c[key][k]
            else:
                out["errors"].append("%s.%s must be an integer from %d to %d" % ((key, k) + RANGES[key]))
    for key in ("text_max", "quote_max"):
        if key in c:
            if _int_in(c[key], key):
                out[key] = c[key]
            else:
                out["errors"].append("%s must be an integer from %d to %d" % ((key,) + RANGES[key]))
    out["left"] = [(k, out["caps"][k], DEFAULT_CAPS[k]) for k in CONFIG_LEFT if out["caps"][k] != DEFAULT_CAPS[k]]
    return out


def read_ledger(c, out):
    """The `ledger` object's thresholds into `out["ledger"]` (brain_ledger.DEFAULTS for each key left out): an unknown key warns,
    a wrong value is an error, as for the caps."""
    if "ledger" not in c:
        return
    if not isinstance(c["ledger"], dict):
        out["errors"].append("ledger must be an object of thresholds")
        return
    for k in sorted(c["ledger"]):
        v = c["ledger"][k]
        if k not in LEDGER_DEFAULTS:
            out["warnings"].append("unknown key ledger.%s (ignored)" % printable(json.dumps(k))[:40])
        elif isinstance(v, int) and not isinstance(v, bool) and LEDGER_RANGES[k][0] <= v <= LEDGER_RANGES[k][1]:
            out["ledger"][k] = v
        else:
            out["errors"].append("ledger.%s must be an integer from %d to %d" % ((k,) + LEDGER_RANGES[k]))


def conf():
    """The configuration of the session's project, read once per process."""
    root = config_root()
    if root not in _CONF:
        _CONF[root] = read_config(root)
    return _CONF[root]


def cap(letter):
    return conf()["caps"].get(letter, DEFAULT_CAPS.get(letter, 1))


def quote_max():
    return conf()["quote_max"]


def untouched_days(letter):
    """Days an item of `letter` goes untouched before it is marked; None for a letter never marked (the left brain, a focus)."""
    return conf()["untouched"].get(letter)


def check_config():
    """A write refuses (rc 1) while the configuration holds a wrong value; a read never does."""
    c = conf()
    if c["errors"]:
        raise Refused(1, "%s: %s; writes are refused until it is fixed (`brain doctor` shows it)"
                      % (CONFIG_FILE, "; ".join(c["errors"])))


def left_cap_notes(c):
    return ["%s: the left cap %s is %d, not its default %d: changing it is the owner's decision" % (CONFIG_FILE, k, v, dv)
            for k, v, dv in c["left"]]


def config_notes():
    """The warnings a write prints on stderr: unknown keys, and each left cap off its default."""
    c = conf()
    return ["%s: %s" % (CONFIG_FILE, w) for w in c["warnings"]] + left_cap_notes(c)


def config_line():
    """String 1's line while the configuration has a warning, an error or a left cap off its default; None otherwise."""
    c = conf()
    parts = []
    if c["errors"]:
        parts.append("%d error%s, defaults used and writes refused" % (len(c["errors"]), "" if len(c["errors"]) == 1 else "s"))
    if c["warnings"]:
        parts.append("%d warning%s" % (len(c["warnings"]), "" if len(c["warnings"]) == 1 else "s"))
    if c["left"]:
        parts.append(", ".join("left cap %s %d (default %d)" % x for x in c["left"]) + " is the owner's decision")
    return ("brain config: %s: brain doctor" % "; ".join(parts))[:300] if parts else None


def ensure_dir(d):
    """Create the state directory and `asked/`; every directory created from `vibemaestro/` down is 0700, and the brain's own
    (the root, the state directory, `asked/`) are put back to 0700 when an earlier build left them open. Windows has no mode to
    put back: there the brain's own are refused (Refused 1) unless they are this account's alone (private)."""
    root = state_root()
    for p in (os.path.dirname(root), root, d, os.path.join(d, "asked")):
        if os.path.isdir(p):
            st_ = os.lstat(p)
            if (not WINDOWS and p != os.path.dirname(root) and stat.S_ISDIR(st_.st_mode) and st_.st_uid == os.getuid()
                    and st_.st_mode & 0o077):
                os.chmod(p, 0o700)
        else:
            os.makedirs(os.path.dirname(p), exist_ok=True)
            try:
                os.mkdir(p, 0o700)
                os.chmod(p, 0o700)
            except FileExistsError:
                pass
        if WINDOWS and p != os.path.dirname(root):  # checked before anything is made inside it
            private(p)


@contextlib.contextmanager
def locked(d, wait=None):
    """The store lock; with `wait` seconds, Refused(1) when it is still held then (a hook must not hang on a writer)."""
    ensure_dir(d)
    fd = os.open(os.path.join(d, "lock"), os.O_RDWR | os.O_CREAT | O_BINARY, 0o600)
    try:
        if wait is None and not WINDOWS:
            fcntl.flock(fd, fcntl.LOCK_EX)
        else:                                       # Windows waits by trying again: msvcrt's own wait gives up after 10 s
            end = time.monotonic() + (float("inf") if wait is None else wait)
            while True:
                try:
                    lock_nb(fd)
                    break
                except HELD:
                    if time.monotonic() >= end:
                        raise Refused(1, "the store lock is held by another process")
                    time.sleep(0.02)
        yield
    finally:
        unlock(fd)
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
    """Atomic write, 0600, with the same bytes on every system (no CRLF on Windows)."""
    tmp = "%s.%d.tmp" % (path, os.getpid())
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | O_BINARY, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        replace(tmp, path)
    except OSError:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def replace(src, dst):
    """os.replace; on Windows tried again for up to a second while another process has `dst` open (PermissionError: a reader,
    or an antivirus scan, that opened it without letting it be renamed over)."""
    for _ in range(50 if WINDOWS else 0):
        try:
            return os.replace(src, dst)
        except PermissionError:
            time.sleep(0.02)
    return os.replace(src, dst)


def now_iso(t=None):
    return datetime.datetime.fromtimestamp(time.time() if t is None else t, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


_ISO = re.compile(r"([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:Z|\+00:00)")


def parse_iso(s):
    m = _ISO.fullmatch(s) if isinstance(s, str) else None
    if m:                                           # the form the brain writes, read without strptime (a bundle holds many)
        with contextlib.suppress(ValueError):
            return datetime.datetime(*(int(x) for x in m.groups()), tzinfo=datetime.timezone.utc).timestamp()
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


_MD_VERSION = re.compile(r"^## Brain · (?:hot memory|left brain(?:, \d+ of \d+)?) v(\d{1,9}) ")   # the older title too
OLDER_TITLE = "## Brain · hot memory v"                 # hot.md as a brain of log format 3 or older wrote it


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
    """Append one op after `raw` (already verified under the lock); returns the new raw list. When the line or the head cannot
    be written whole, the log is cut back to its old length before the error is raised: a line with no head stops every
    read and write (rc 5), and a write from SessionStart must leave the log as it found it."""
    return append_many(d, raw, [op])


def append_many(d, raw, ops):
    """Append the ops after `raw` in one write of all their lines, then the head (an import's batch): every line or none."""
    lines, prev = [], line_hash(raw[-1]) if raw else GENESIS
    for i, op in enumerate(ops, len(raw) + 1):
        op = dict(op)
        op["seq"], op["prev"] = i, prev
        lines.append(dumps(op).encode("utf-8"))
        prev = line_hash(lines[-1])
    data = b"".join(b + b"\n" for b in lines)
    fd = os.open(os.path.join(d, "hot.jsonl"), os.O_WRONLY | os.O_APPEND | os.O_CREAT | O_BINARY, 0o600)
    try:
        size = os.lseek(fd, 0, os.SEEK_END)
        try:
            if os.write(fd, data) != len(data):
                raise OSError("hot.jsonl: a short write")
            os.fsync(fd)
            _write_file(os.path.join(d, "head.json"), dumps(head_of(raw + lines)) + "\n")
        except OSError as e:
            try:
                os.ftruncate(fd, size)
                os.fsync(fd)
            except OSError as e2:
                raise OSError(e.errno, "hot.jsonl may be left past head.json: %s, and cutting it back failed (%s); run brain "
                                       "doctor" % (e.strerror or e, e2.strerror or e2)) from e
            raise
    finally:
        os.close(fd)
    return raw + lines


# --- the fold -----------------------------------------------------------------------------------------------------------------

def empty_state():
    return {"version": 0, "items": {}, "writer": None, "claimed": None, "takeovers": 0, "spent": [], "retirements": []}


def _retire(st, op, it, status, budget=True):
    it["status"] = status
    it["retired"] = op["t"]
    it["touched"] = op["seq"]
    if budget:                                      # a machine op (link-close) has its own cap, not the session's budget
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
    elif kind == "overflow-add":
        it = _new_item(st, op, op["item"])
        if it["id"][0] in LEFT_LETTERS:
            raise Refused(5, "hot.jsonl line %d: %s is queued, but the left brain has no overflow" % (op["seq"], it["id"]))
        it.update({"status": "queued", "queued": op["seq"]})
    elif kind == "close":
        it = item()
        it["reason"], it["pointer"] = op.get("reason"), op.get("pointer")
        _retire(st, op, it, "closed", budget=it["id"][0] != "W")    # a window ended by the session narrows: no budget spent
    elif kind == "link-close":
        it = item()
        it["reason"], it["pointer"] = op.get("reason"), op.get("pointer")
        it["linked"] = {"t": op["t"], "anchors": op.get("anchors") or []}
        _retire(st, op, it, "closed", budget=False)
    elif kind in ("supersede", "owner-supersede"):
        it = item()
        it["reason"] = op.get("reason")
        was_queued = it["status"] == "queued"
        new = _new_item(st, op, op["item"])
        if op.get("queued"):                        # a queued item's successor keeps its place in the queue
            if not was_queued:
                raise Refused(5, "hot.jsonl line %d: %s is not queued" % (op["seq"], it["id"]))
            new.update({"status": "queued", "queued": it["queued"]})
        it["superseded_by"] = new["id"]
        _retire(st, op, it, "superseded", budget=it["id"][0] not in STATUS_LETTERS)
    elif kind == "owner-unpin":
        it = item()
        it["reason"] = "unpinned by the owner"
        _retire(st, op, it, "closed")
    elif kind == "owner-promote":
        it = item()
        it["pointer"] = op.get("pointer")
        it["reason"] = "promoted"
        _retire(st, op, it, "archived")
        if op.get("soul") is not None:              # a code an older brain stored (log format 6): kept as it was
            if not SOUL_CODE.fullmatch(str(op["soul"])):
                raise Refused(5, "hot.jsonl line %d: a malformed SOUL code" % op["seq"])
            it["soul"] = op["soul"]
    elif kind == "owner-demote":                    # a decision an older brain pinned from a SOUL code: folded as it was
        it = _new_item(st, op, op["item"])
        if it["id"][0] != "D" or not SOUL_CODE.fullmatch(str(op.get("soul"))) or it.get("demoted_from") != op.get("soul"):
            raise Refused(5, "hot.jsonl line %d: a malformed demotion" % op["seq"])
    elif kind == "evidence":                        # a held or a broke: the ledger reads it from the log, the fold only checks it
        if op.get("result") not in ("held", "broke") or bool(op.get("id")) == bool(op.get("soul")):
            raise Refused(5, "hot.jsonl line %d: a malformed evidence op" % op["seq"])
        if op.get("id"):
            it = item()
            if it["id"][0] not in RULE_LETTERS or op.get("via") == "hit" and it["id"][0] != "T":
                raise Refused(5, "hot.jsonl line %d: evidence for %s, which is not a rule" % (op["seq"], it["id"]))
            if it["id"][0] in ("T", "F"):           # the session's items are touched; a decision stays the owner's
                it["touched"] = op["seq"]
                if op.get("via") == "hit":
                    it["hits"] = it.get("hits", 0) + 1
        elif not SOUL_CODE.fullmatch(str(op["soul"])):
            raise Refused(5, "hot.jsonl line %d: a malformed SOUL code" % op["seq"])
    elif kind == "progress":                        # a goal's progress: ledger data, the goal itself unchanged
        if item()["id"][0] != "G":
            raise Refused(5, "hot.jsonl line %d: progress for an item that is not a goal" % op["seq"])
    elif kind == "words":                           # a focus's done when and not doing, set in place: same id (log format 7)
        it = item()
        got = {k: op[k] for k in ("done", "not_doing") if isinstance(op.get(k), str)}
        if it["id"][0] != "P" or not got:
            raise Refused(5, "hot.jsonl line %d: words for an item that is not a focus, or with no words" % op["seq"])
        it.update(got)
        it["touched"] = op["seq"]
    elif kind == "link":                            # `closes` added to a live item in place: same id (log format 8)
        it = item()
        new = op.get("closes")
        if (it["id"][0] not in CLOSES_LETTERS or it["status"] != "live" or not isinstance(new, list) or not new
                or not all(isinstance(c, str) for c in new)):
            raise Refused(5, "hot.jsonl line %d: a malformed link" % op["seq"])
        old = it.get("closes") or []
        it["closes"] = old + [c for c in new if c not in old]
        # when each anchor joined: work done before it was linked never closes the item (brain_stale.done_after)
        it["closes_at"] = dict(it.get("closes_at") or {}, **{c.lower(): op["t"] for c in new if c not in old})
        it["anchors"] = with_closes(it.get("anchors", []), new)
        it["touched"] = op["seq"]
    elif kind == "touch":
        item()["touched"] = op["seq"]
    elif kind == "hit":
        it = item()
        it["hits"] = it.get("hits", 0) + 1
        it["touched"] = op["seq"]
    elif kind == "signal":                          # a measurement: folded unread, no item changes (read ahead of a writer)
        if not isinstance(op.get("what"), str) or not 0 < len(op["what"]) <= 32:
            raise Refused(5, "hot.jsonl line %d: a malformed signal" % op["seq"])
    elif kind == "owner-soul-code":                 # a SOUL line's code and source (log format 10): the ledger counts it, no item
        if (not SOUL_CODE.fullmatch(str(op.get("soul"))) or not all(isinstance(op.get(k), str) for k in ("text", "file", "sha256"))
                or not isinstance(op.get("source"), list) or not op["source"]):
            raise Refused(5, "hot.jsonl line %d: a malformed SOUL code step" % op["seq"])
        st["format"] = max(st.get("format", 0), 10)     # the caches say so: an older brain then folds the log, and refuses it
    elif kind == "ext":                             # an extension's own op: folded unread, no item changes (its reader is the extension)
        if (not isinstance(op.get("ext"), str) or not EXT_NAME.fullmatch(op["ext"]) or not isinstance(op.get("what"), str)
                or not EXT_NAME.fullmatch(op["what"]) or not isinstance(op.get("data"), dict)):
            raise Refused(5, "hot.jsonl line %d: a malformed extension op" % op["seq"])
        st["format"] = 11
    else:
        raise Refused(5, "hot.jsonl line %d: unknown op %r" % (op["seq"], kind))
    if "promote" in op:
        _promote(st, op)
    rid = (op.get("confirm") or {}).get("record")
    if rid:
        st["spent"].append(rid)
    st["version"] = op["seq"]
    return st


PROMOTING = ("add", "overflow-add", "close", "link-close", "supersede", "owner-promote")   # a promoted lesson or fact makes room


def _promote(st, op):
    """Move the op's `promote` ids from the queue to live: each must be queued, in the section the op writes."""
    letter = (op.get("item") or {}).get("id", "")[:1] if op["op"] in ("add", "overflow-add") else str(op.get("id", ""))[:1]
    ids = op["promote"]
    if op["op"] not in PROMOTING or not isinstance(ids, list):
        raise Refused(5, "hot.jsonl line %d: a malformed promote" % op["seq"])
    for pid in ids:
        it = st["items"].get(pid) if isinstance(pid, str) else None
        if it is None or it["status"] != "queued" or pid[0] != letter:
            raise Refused(5, "hot.jsonl line %d: promote names %r, which is not queued in section %s"
                          % (op["seq"], pid, letter or "?"))
        it.update({"status": "live", "promoted": op["seq"], "touched": op["seq"]})


def fold(ops):
    st = empty_state()
    for op in ops:
        apply(st, op)
    return st


# --- caches -------------------------------------------------------------------------------------------------------------------

def digest(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def archive_lines(st):
    return [dumps(it) for _, it in sorted(st["items"].items(), key=lambda kv: kv[1]["touched"])
            if it["status"] not in ("live", "queued")]


def cache_head(head, st):
    """A cache's `folded_from`: the head, with the log format the state needs when an older brain cannot fold it (an older
    brain compares it whole, so it folds the log itself and refuses the op it does not know, rather than read this cache)."""
    return dict(head, format=st["format"]) if "format" in st else head


def write_caches(d, st, head):
    body = dumps(st)
    head = cache_head(head, st)
    _write_file(os.path.join(d, "hot.json"), dumps({"folded_from": head, "digest": digest(body), "state": st}) + "\n")
    lines = archive_lines(st)
    _write_file(os.path.join(d, "archive.jsonl"),
                "\n".join([dumps({"folded_from": head, "digest": digest("\n".join(lines))})] + lines) + "\n")
    _write_file(os.path.join(d, "owner.json"), dumps({"folded_from": head, "session": st["writer"], "since": st["claimed"],
                                                       "takeovers": st["takeovers"]}) + "\n")
    write_render(d, render_all(st))


CAPS_KEYS = ("caps", "text_max", "text_caps", "quote_max")


def caps_values():
    """The caps and lengths in force: a render made under others differs only by them."""
    c = conf()
    return {k: c[k] for k in CAPS_KEYS}


@contextlib.contextmanager
def caps_as(values):
    """Render under other caps and lengths for a moment (doctor re-renders hot.md under those it was rendered under)."""
    root = config_root()
    saved = _CONF.get(root)
    _CONF[root] = dict(conf(), **values)
    try:
        yield
    finally:
        if saved is None:
            _CONF.pop(root, None)
        else:
            _CONF[root] = saved


def write_render(d, text):
    """hot.md, and beside it the caps it was rendered under, so that doctor tells a config change from an edit."""
    _write_file(os.path.join(d, "hot.md"), text)
    _write_file(os.path.join(d, "hot.md.caps"), dumps(caps_values()) + "\n")


_SIZE = re.compile(r" · [\d,]+/([\d,]+) chars")
_MORE = re.compile(r"\(\+[0-9]+ more: brain doctor\)")
_ITEM = re.compile(r"^- ([GDWPRNXTSQF][1-9][0-9]{0,5}) ")
_HALF = re.compile(r"^## Brain · (left|right) brain(?:, \d+ of \d+)? v(\d{1,9}) · ")
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


def review_forms(it, now):
    """The review parts a goal's line could have shown from its creation to `now`: its day, then `OVERDUE n d` for each day
    past it so far."""
    n = days_to(it.get("review"), now)
    return [review_text(it, k) for k in range(min(n, 0), 1)] if n is not None else [""]


def due_forms(st, now):
    """Every Due line this state could have shown on some day from the oldest live request with a due day to `now`."""
    rs = [it for it in live(st, "R") if parse_day(it.get("due"))]
    if not rs:
        return set()
    first = min(parse_iso(it.get("created") or "") or now for it in rs)
    days = max(0, (today(now) - today(first)).days)
    return {due_line(st, now - k * 86400) for k in range(days + 1)} - {None}


def render_key(text, st, now=None):
    """A render reduced to what does not move with the clock, for comparing hot.md with a fresh render: a window's time left,
    and so which of its links fit, changes as it nears expiry, a goal's review day becomes `OVERDUE n d`, the Due line counts
    days, and Done holds what closed in the last 24 hours. An item line is reduced to its id when it is the state's line without
    links, its time left (a window's, at its place) or review part (a goal's) one the state could have shown by `now`, then the
    very tail item_line writes after that much text; the Due line is dropped when the state showed it on some day; a line under
    Done is dropped when it is the Done line of an item the log closed, or the count of the rest; any other line is kept whole (a
    title without its size), so an edited id, text, date, time left or tail cannot compare equal. As Done ages, the strings a
    half takes and where they part can change: a half's title counts once (without which string it is), and a section's
    ` (cont.)` title and the blank line between strings are dropped."""
    now = time.time() if now is None else now
    out, section, halves = [], None, set()
    for line in text.splitlines():
        if not line.strip():
            continue
        if line.endswith(CONT) and line[:-len(CONT)] in TITLE_SET:
            section = line[:-len(CONT)]
            continue
        if line in TITLE_SET:
            section = line
        elif line.startswith("## "):
            section = None
            m = _HALF.match(line)
            if m:
                if m.group(1) not in halves:
                    halves.add(m.group(1))
                    out.append("## Brain · %s brain v%s" % (m.group(1), m.group(2)))
                continue
        if section is None and line.startswith("Due: ") and line in due_forms(st, now):
            continue                                # the Due line of some day since its requests were written
        m = _ITEM.match(line)
        it = st["items"].get(m.group(1)) if m else None
        if section == DONE_TITLE and line != DONE_TITLE:
            if (it and it["status"] == "closed" and it["id"][0] in DONE_LETTERS and line == done_line(it)) or _MORE.fullmatch(line):
                continue
        elif it:
            base = item_line(dict(it, links=[]), now, st)
            rest = None
            if it["id"][0] == "W" and it.get("expires"):
                # an older brain wrote a window with no scope without its `lowers no signing`: either form is this line
                for b in [base] + ([base.replace(" · lowers no signing · ", " · ", 1)] if not it.get("lowers") else []):
                    stem = b[:b.rindex(" (")] + " ("
                    if line.startswith(stem) and ")" in line[len(stem):]:
                        left, _, after = line[len(stem):].partition(")")
                        rest = after if _left_fits(left, it, now) else None
                        break
            elif it["id"][0] == "G" and parse_day(it.get("review")):
                for form in review_forms(it, now):
                    b = item_line(dict(it, links=[]), now, st, review=form)
                    if line.startswith(b):
                        rest = line[len(b):]
                        break
            elif line.startswith(base):
                rest = line[len(base):]
            if rest is not None and rest == links_tail(units(line[:len(line) - len(rest)]), it):
                out.append("item %s" % it["id"])
                continue
        out.append(_SIZE.sub(r" · ?/\1 chars", line))
    return out


def cache_state(d, head):
    """The cached state when hot.json was folded from `head` and its digest matches; else None."""
    try:
        c = json.load(open(os.path.join(d, "hot.json"), encoding="utf-8"))
        if c.get("folded_from") == cache_head(head, c["state"]) and c.get("digest") == digest(dumps(c["state"])):
            return c["state"]
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        pass
    return None


def cache_problems(d, head, st):
    """Doctor's view of the three caches against a fresh fold `st`: [(level, text)]."""
    out = []
    try:
        c = json.load(open(os.path.join(d, "hot.json"), encoding="utf-8"))
        if c.get("folded_from") != cache_head(head, st):
            out.append(("warn", "hot.json is stale (folded from another head); the next read folds again"))
        elif c.get("digest") != digest(dumps(c.get("state"))):
            out.append(("problem", "hot.json does not match its digest: it was edited; reads fold the log until the next write "
                                   "rewrites it"))
        elif dumps(c.get("state")) != dumps(st):      # its own digest holds: another brain version's fold, as after an update
            out.append(("warn", "hot.json holds a fold of this log that differs from this brain's (another brain version's, as "
                                "after an update, or one rewritten with its digest); reads use it until the next write rewrites it"))
    except (OSError, ValueError, AttributeError):
        out.append(("warn", "hot.json is missing or unreadable; the next read folds again"))
    try:
        lines = open(os.path.join(d, "archive.jsonl"), encoding="utf-8").read().splitlines()
        h = json.loads(lines[0])
        if h.get("folded_from") != cache_head(head, st):
            out.append(("warn", "archive.jsonl is stale; the next write folds again"))
        elif h.get("digest") != digest("\n".join(lines[1:])):
            out.append(("problem", "archive.jsonl does not match its digest: it was edited"))
        elif lines[1:] != archive_lines(st):
            out.append(("warn", "archive.jsonl holds a fold of this log that differs from this brain's (another brain version's, "
                                "as after an update); the next write rewrites it"))
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


def load_ops(d):
    """(head, state, ops): `load` with the log's ops, which it parses anyway (the ledger is read from them)."""
    raw, ops = verify(d)
    head = head_of(raw)
    st = cache_state(d, head)
    return head, (st if st is not None else fold(ops)), ops


# --- text guards --------------------------------------------------------------------------------------------------------------

def check_text(field, value, required=True, cap=None):
    """Refuse (1) an empty, blank, control-holding or over-long field; `cap` overrides the field's own (a session's text)."""
    if value is None or value == "":
        if required:
            raise Refused(1, "%s is empty" % field)
        return
    if value.isascii() and value.isprintable():     # no mark, control, format or selector: only blank and long to check
        if not value.strip():
            raise Refused(1, "%s is blank: only spaces or marks that show nothing on their own" % field)
    elif not any(not c.isspace() and unicodedata.category(c) not in ("Mn", "Me") for c in value):
        raise Refused(1, "%s is blank: only spaces or marks that show nothing on their own" % field)
    elif _marks_run(value) > MARKS_RUN_MAX:
        raise Refused(1, "%s stacks more than %d combining marks on one character" % (field, MARKS_RUN_MAX))
    bad = [] if value.isascii() and value.isprintable() else [c for c in value if is_bad(c)]
    bad += [c for i, c in enumerate(value) if ord(c) in SELECTORS and not selector_fits(value, i)] if not value.isascii() else []
    if bad:
        raise Refused(1, "%s holds a control or format character (U+%04X); refused so the render stays one clean line"
                      % (field, ord(bad[0])))
    cap = FIELD_MAX[field] if cap is None else cap
    if units(value) > cap:                          # as Claude Code counts a hook string: an emoji is 2
        raise Refused(1, "%s is %d characters (UTF-16 units: an emoji counts 2), over its cap of %d" % (field, units(value), cap))


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


_IGNORABLE_STARTS = [a for a, _ in DEFAULT_IGNORABLE]     # the ranges are sorted and apart: one bisect finds the only candidate


def ignorable(c):
    o = ord(c)
    i = bisect.bisect_right(_IGNORABLE_STARTS, o) - 1
    return i >= 0 and o <= DEFAULT_IGNORABLE[i][1]


def selector_fits(value, i):
    """value[i] is a selector right after a non-ASCII symbol (an emoji's presentation), or inside a keycap."""
    prev = value[i - 1] if i else ""
    if prev in "0123456789#*" and prev:
        return value[i + 1:i + 2] == "\u20e3"
    return bool(prev) and ord(prev) > 0x7F and (unicodedata.category(prev) in ("So", "Sm") or ord(prev) in EMOJI_BASES)


def skeleton(t):
    if t.isascii():                                 # no mark, no ignorable, and NFKC keeps ASCII as it is
        return t
    return unicodedata.normalize("NFKC", "".join(c for c in t if unicodedata.category(c) not in ("Mn", "Me") and not ignorable(c)))


def is_bad(c):
    o = ord(c)
    return (unicodedata.category(c) in BAD_CATEGORIES or o in INVISIBLE or 0xFDD0 <= o <= 0xFDEF
            or o & 0xFFFE == 0xFFFE or (ignorable(c) and o not in SELECTORS))


def escaped(text):
    """A stored text shown inside `"…"` (the owner's dialog, the 7-line card): a backslash as `\\\\`, then a `"` as `\\"`, so a
    lesson's or a fact's text, which the session wrote, cannot end the quotes it is shown in."""
    return clean_line(text).replace("\\", "\\\\").replace('"', '\\"')


def quote_like(value):
    """The first character of `value` that is not plain, None when every one is: a field shown before others inside quotes
    takes only an allowlist, since a blocklist of what can pass for a `"` or reverse the line cannot be complete (U+1CD3,
    U+02F5, U+0660 passed one). Plain: a letter (Lu, Ll, Lt, Lo) of bidi class L; a combining mark right after one or after
    another such mark; a decimal digit of bidi class L or EN; a space; ASCII punctuation other than `"`. A character whose name
    is a quote's (QUOTE_NAMES) is never plain, nor a second apostrophe-like character (APOSTROPHE_LIKE) right after one, nor a
    mark on a dotless i or j (DOTLESS), nor a double mark on a soft-dotted one (i + U+030E). A script's own letters and marks
    (Tifinagh, polytonic Greek in NFD, Vietnamese in NFD) stay plain."""
    prev, tick, dotless, soft = False, False, False, False   # before: a plain letter or a mark on one; a tick; ı or ȷ; i, j…
    for c in value:
        if c in APOSTROPHE_LIKE and tick:
            return c
        tick = c in APOSTROPHE_LIKE
        if (dotless and unicodedata.category(c) in ("Mn", "Mc")) or (soft and c in DOUBLE_MARKS):
            return c
        dotless, soft = c in DOTLESS, c in SOFT_DOTTED or (soft and unicodedata.category(c) in ("Mn", "Mc"))
        if c.isascii():
            ok = c == " " or c.isalnum() or (c in string.punctuation and c != '"')
            prev = c.isalpha()
        else:
            cat, bidi = unicodedata.category(c), unicodedata.bidirectional(c)
            ok = ((cat in ("Lu", "Ll", "Lt", "Lo") and bidi == "L") or (cat in ("Mn", "Mc") and prev)
                  or (cat == "Nd" and bidi in ("L", "EN"))) and not any(n in unicodedata.name(c, "") for n in QUOTE_NAMES)
            prev = ok and cat in ("Lu", "Ll", "Lt", "Lo", "Mn", "Mc")
        if not ok:
            return c
    return None


_OLDER_RULES = []                                   # non-empty inside older_rules()


@contextlib.contextmanager
def older_rules():
    """Render as an older brain did for a moment: every joiner and tag dropped, a `where` cut at 30 units (doctor
    tells that brain's hot.md from an edited one)."""
    global WHERE_SHOWN
    saved = WHERE_SHOWN
    WHERE_SHOWN = 30
    _OLDER_RULES.append(True)
    try:
        yield
    finally:
        WHERE_SHOWN = saved
        _OLDER_RULES.pop()


FLAG_TAGS = tuple("".join(chr(0xE0000 + ord(ch)) for ch in w) + "\U000E007F" for w in ("gbeng", "gbsct", "gbwls"))   # the RGI
                                                    # subdivision flags after U+1F3F4: any other tag run would be hidden text


def _joinable(c):
    """A character a ZWJ or ZWNJ may stand beside in the render: shown, not a space, not ASCII (no ASCII letter joins)."""
    return ord(c) > 0x7F and not c.isspace() and not is_bad(c)


def clean_line(s):
    """The render backstop: drop every control, format, noncharacter or invisible character, except a ZWJ or ZWNJ between two
    shown non-ASCII characters (an emoji sequence, a Persian or Indic word) and the tags of an RGI subdivision flag (U+1F3F4,
    then `gbeng`, `gbsct` or `gbwls` as tags, then U+E007F): there they join what is shown, elsewhere they would hide it (a tag
    run is invisible ASCII a reader of the render would never see)."""
    if isinstance(s, str) and s.isascii() and s.isprintable():     # nothing to drop, and the render's hot path
        return s
    s = str(s)
    if _OLDER_RULES:                                # doctor re-rendering as an older brain did
        return "".join(c for c in s if not is_bad(c))
    out, i, n = [], 0, len(s)
    while i < n:
        c = s[i]
        if c == "\U0001F3F4":
            flag = next((t for t in FLAG_TAGS if s.startswith(t, i + 1)), None)
            if flag:
                out.append(c + flag)
                i += 1 + len(flag)
                continue
        if c in "‌‍":
            if out and _joinable(out[-1][-1]) and i + 1 < n and _joinable(s[i + 1]):
                out.append(c)
        elif not is_bad(c):
            out.append(c)
        i += 1
    return "".join(out)


def printable(s):
    """One line safe for a terminal: every bad character, the newline included (it could forge a line), shown as \\uXXXX."""
    return "".join(c if not is_bad(c) else "\\u%04x" % ord(c) for c in str(s))


def sdlc_filter():
    """Path of vibemaestro-sdlc's gates/pr_sensitive.py: the plugin registry first, then the marketplace layout; else None."""
    return sdlc_file(os.path.join("gates", "pr_sensitive.py"))


def sdlc_file(rel):
    """Path of the file `rel` of vibemaestro-sdlc: the plugin registry first, then the marketplace layout; else None."""
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


def utf8_env():
    """The environment for a Python child that reads or prints text: UTF-8 on its pipes, as this side writes and reads them
    (Windows' default is the system code page, which lacks Vietnamese)."""
    return dict(os.environ, PYTHONIOENCODING="utf-8")


def sanitize(d, texts):
    """Run every text through sdlc's filter once; refuse (rc 1) on a hit, printing only the masked form, or when it cannot run."""
    texts = [t for t in texts if t]
    if not texts:
        return
    # the filter's patterns also run on a skeleton of each text: marks and selectors removed (one between every character of a
    # token would split it for the filter), then NFKC (fullwidth or styled letters back to plain ones)
    seen = set(texts)
    texts += [k for k in dict.fromkeys(skeleton(t) for t in texts) if k not in seen]
    f = sdlc_filter()
    if not f:
        raise Refused(1, "vibemaestro-sdlc's sensitive-value filter (gates/pr_sensitive.py) was not found; writes are refused "
                         "until it is installed")
    try:
        r = subprocess.run([sys.executable, f, "--text", "--cwd", d], input="\n".join(texts), capture_output=True,
                           encoding="utf-8", env=utf8_env(), timeout=30)
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


def worker():
    """A worker session keeps no hot memory: VIBEMAESTRO_ROLE is exactly `worker`, or INTENT_SLUG and SEAT are both set (the
    union, so the switch never loosens the older check)."""
    return os.environ.get("VIBEMAESTRO_ROLE") == "worker" or bool(os.environ.get("INTENT_SLUG") and os.environ.get("SEAT"))


def check_worker():
    if worker():
        raise Refused(4, "a worker session keeps no hot memory (VIBEMAESTRO_ROLE=worker, or INTENT_SLUG and SEAT are set)")


def check_caller():
    check_worker()
    if os.environ.get("BRAIN_EXTENSION"):
        raise Refused(4, "a brain extension's call never writes the brain: it answers, and brain writes")
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


def record_asked(d, session, mode, args, t=None, plan=None):
    """Void the session's earlier unused records, then write one for this dialog. Returns the record id. `plan`: the SHA-256 of
    a batch's dialog text (an owner import), which the CLI computes again before it writes."""
    with locked(d):
        void_records(d, session)
        rid = secrets.token_hex(16)
        rec = {"id": rid, "session": session, "mode": mode, "args": list(args), "t": time.time() if t is None else t}
        if plan is not None:
            rec["plan"] = plan
        _write_file(os.path.join(d, "asked", rid + ".json"), dumps(rec) + "\n")
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
    """[(argv, cwd or None, CLAUDE_CONFIG_DIR or None, HOME or None)] of the ancestor processes (Linux /proc, else `ps` without
    cwd; Windows: win_ancestors, the command line only, Unread when one cannot be read)."""
    if WINDOWS:
        return win_ancestors()
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


def _drive_abs(v):
    """`v` names a place whatever the working directory: absolute with a drive or a share (Windows' `\\x` is on the current
    drive)."""
    return os.path.isabs(v) and bool(os.path.splitdrive(v)[0])


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
    """The paths `git worktree list` names; a path need not be UTF-8 and may hold a newline (-z, where git has it)."""
    for z in (["-z"], []):
        try:
            r = subprocess.run(["git", "worktree", "list", "--porcelain"] + z, capture_output=True, timeout=10)
        except (OSError, subprocess.SubprocessError):
            return []
        if r.returncode == 0:
            out = os.fsdecode(r.stdout)
            return [l[len("worktree "):] for l in out.split("\0" if z else "\n") if l.startswith("worktree ")]
    return []


def _is_claude(argv):
    """An argv of Claude Code: its program (or node's script) named in CLAUDE_PROGRAMS or a path under claude/versions/."""
    head = argv[:argv.index("--")] if "--" in argv else argv
    return any(os.path.basename(a) in CLAUDE_PROGRAMS or "/claude/versions/" in a for a in head[:2])


def prompt_tool(argv):
    return any(a == "--permission-prompt-tool" or a.startswith("--permission-prompt-tool=") for a in argv)


def official_host(argv):
    """argv is the Claude Code of the VS Code extension or the Claude desktop app, whose dialog a person clicks: their entry point
    (CLAUDE_CODE_ENTRYPOINT, which Claude Code hands on to hooks and the Bash tool), the SDK's `--permission-prompt-tool=stdio`
    once, no -p. A process of the same user that sets that entry point and answers through the SDK passes too: the records
    guard against slips, not against a process of the same user."""
    head = argv[:argv.index("--")] if "--" in argv else argv
    return (os.environ.get("CLAUDE_CODE_ENTRYPOINT") in OFFICIAL_HOSTS and _is_claude(argv)
            and "-p" not in head and "--print" not in head and _flag_values(argv, "--permission-prompt-tool") == ["stdio"])


def claude_programs(pid):
    """The commands that run the Claude Code process `pid` again, to ask its version: its program (Linux: /proc/<pid>/exe, which
    still runs once an update replaced the file; Windows: the image Windows runs; else `ps -o comm=`, the whole path even
    with spaces), then the program with its script (an npm install: node cli.js). [] when they cannot be read or the process is
    not Claude Code."""
    try:
        if WINDOWS:
            argv, exe = split_cmdline(_win_info(pid)[1]), _win_image(pid)
        else:
            with open("/proc/%d/cmdline" % pid, "rb") as f:
                argv = [a.decode("utf-8", "replace") for a in f.read().split(b"\0") if a]
            exe = "/proc/%d/exe" % pid
    except OSError:
        if WINDOWS:
            return []
        try:
            exe = subprocess.run(["ps", "-o", "comm=", "-p", str(pid)], capture_output=True, text=True, timeout=5).stdout.strip()
            argv = subprocess.run(["ps", "-o", "args=", "-p", str(pid)], capture_output=True, text=True, timeout=5).stdout.split()
        except (OSError, subprocess.SubprocessError):
            return []
    if not os.path.isabs(exe) or not _is_claude(argv):       # never another program: CLAUDE_PID may be inherited or stale
        return []
    script = argv[1] if len(argv) > 1 and not argv[1].startswith("-") and os.path.isfile(argv[1]) else None
    return [[exe]] + ([[exe, script]] if script else [])


def claude_version():
    """(the running Claude Code's version, or None; [what was tried]), from the first `X.Y.Z (Claude Code)` line of `--version`
    run as: the program of the process CLAUDE_PID names (Claude Code sets it for hooks; CLAUDE_CODE_EXECPATH it sets only in the
    Bash tool's shell), then $CLAUDE_CODE_EXECPATH, then `claude` on PATH (a desktop app started from the GUI has none)."""
    pid, exe = os.environ.get("CLAUDE_PID", ""), os.environ.get("CLAUDE_CODE_EXECPATH", "")
    known = re.fullmatch(r"[0-9]{1,9}", pid)          # a plain number a pid can be, never one that overflows a call
    tries = [("the running Claude Code (process %s)" % pid, c) for c in (claude_programs(int(pid)) if known else [])]
    tries += [("CLAUDE_CODE_EXECPATH", [exe])] if os.path.isabs(exe) else []
    tried = []
    on_path = shutil.which("claude")                    # Windows: claude.cmd of an npm install too (PATHEXT)
    on_path = on_path if on_path and os.path.isabs(on_path) else None   # never the working directory's (Windows looks there)
    tries += [("`claude` on PATH", [on_path])] if on_path else []
    for what, cmd in tries:
        try:
            out = subprocess.run(cmd + ["--version"], capture_output=True, text=True, timeout=5).stdout
        except (OSError, subprocess.SubprocessError):
            out = ""
        m = re.search(r"(\d+)\.(\d+)\.(\d+)[^\n]*Claude Code", out or "")
        if m:
            return tuple(int(x) for x in m.groups()), tried
        tried += [] if what in tried else [what]
    return None, tried + ([] if on_path else ["`claude` on PATH"])


def auto_refusal():
    """Why owner items are refused in permission mode auto, or None: auto shows the dialog only from VERSION_FLOOR."""
    v, tried = claude_version()
    floor = ".".join(map(str, VERSION_FLOOR))
    if v is None:
        return ("permission mode auto shows the owner's permission dialog only from Claude Code %s, and its version cannot be "
                "read here (tried: %s). %s" % (floor, ", ".join(tried), AUTO_WHERE % "owner items are"))
    if v < VERSION_FLOOR:
        return ("permission mode auto: Claude Code %s is older than %s, whose auto mode can answer the permission dialog "
                "without the owner. %s" % (".".join(map(str, v)), floor, AUTO_WHERE % "owner items are"))
    return None


def answerers(project=None):
    """What can answer Claude Code's permission prompt in place of a human, as far as settings and processes show. It reads
    the union of every place the running session may take settings from (each config directory, each worktree of the
    repository, each ancestor's working directory), so a call from another directory or environment can only see more."""
    found = []
    try:
        anc = _ancestors()
    except Unread as e:
        anc = []
        found.append("a parent process whose command line the brain cannot read (%s)" % e)
    # ~/.claude by HOME and by the password database (HOME can be emptied or moved), this process's config directory (a
    # relative one from its cwd), and each ancestor's config directory and ~/.claude (relative ones from that ancestor's cwd)
    homes = (os.environ.get("HOME", ""), account_home()) + ((os.environ.get("USERPROFILE", ""),) if WINDOWS else ())
    cfgs = [os.path.join(h, ".claude") for h in homes if os.path.isabs(h)]   # Windows: Node and Bun take ~ from USERPROFILE
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
    # the official host's Claude Code is excused only when every process with a prompt tool has its command line: an SDK app
    # run inside the host inherits its entry point but not its command line, while a Git Bash fork of one process keeps it
    # (win_ancestors gives each process twice, split both ways: a process is its pair)
    step = 2 if WINDOWS else 1
    procs = [tuple(tuple(a) for a, _c, _g, _h in anc[i - i % step:i - i % step + step]) for i in range(len(anc))]
    tools = {procs[i] for i, (argv, _c, _g, _h) in enumerate(anc) if prompt_tool(argv)}
    for i, (argv, cwd, _, _) in enumerate(anc):
        if prompt_tool(argv) and not (official_host(argv) and tools == {procs[i]}):
            found.append("a process started with --permission-prompt-tool")
        for v in _flag_values(argv, "--settings"):
            if WINDOWS and not cwd and not v.lstrip().startswith("{") and not _drive_abs(v):
                found.append("a --settings of a parent process names a relative path, which the brain cannot find on Windows")
                s = None
            elif v.lstrip().startswith("{"):
                try:
                    s = json.loads(v)
                except ValueError:
                    s = None
            else:
                s = _json_file(v if os.path.isabs(v) or not cwd else os.path.join(cwd, v))
            if _has_permission_request(s):
                found.append("a PermissionRequest hook in --settings of a parent process")
        for v in _flag_values(argv, "--plugin-dir"):
            if WINDOWS and not cwd and not _drive_abs(v):
                found.append("a --plugin-dir of a parent process names a relative path, which the brain cannot find on Windows")
            elif _plugin_answers(v if os.path.isabs(v) or not cwd else os.path.join(cwd, v)):
                found.append("a PermissionRequest hook in a --plugin-dir of a parent process")
    return sorted(set(found))


# --- the installed brain ------------------------------------------------------------------------------------------------------
# The log is written by one code: the vibemaestro-brain the settings enable, whose hooks run. A `brain` from an older copy on
# PATH would write with older code, so a brain that is not the installed one refuses writes and says so on reads; when the
# installed one cannot be told, nothing is refused.

BRAIN_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WRITES = ("op", "owner", "import")                  # the commands that change an item


def installed_brain(project=None):
    """Real path of the vibemaestro-brain install the settings enable for the session's project (installed_plugins.json, the
    entry that applies to it); None when that cannot be told: no registry or one that does not read, none enabled, two
    enabled, or a path that is not a directory."""
    project = project or session_project()
    if not os.path.isabs(project):                  # the shell's directory was deleted: no project's settings to read
        return None
    project = os.path.realpath(project)
    reg = json_capped(os.path.join(config_dir(), "plugins", "installed_plugins.json"), EXT_FILE_MAX)
    ids = reg.get("plugins") if isinstance(reg, dict) else None
    enabled = enabled_ids(project) if isinstance(ids, dict) else {}
    found = {}
    for pid in sorted(ids) if isinstance(ids, dict) else []:
        if pid.split("@")[0] != "vibemaestro-brain" or enabled.get(pid) is not True:
            continue
        e = applicable(ids[pid], project)
        p = e.get("installPath") if isinstance(e, dict) else None
        if isinstance(p, str) and os.path.isabs(p) and os.path.isdir(p):
            found[os.path.normcase(os.path.realpath(p))] = os.path.realpath(p)
    return list(found.values())[0] if len(found) == 1 else None


def in_tree(root):
    """A brain's real root runs from a repository's tree: a `.git` beside `plugins/`, outside Claude Code's plugins directory
    (a marketplace clone there is an install copy). Such a brain only warns, here and in the hook."""
    return (os.path.lexists(os.path.join(os.path.dirname(os.path.dirname(root)), ".git"))
            and not inside(os.path.normcase(root), os.path.normcase(os.path.realpath(os.path.join(config_dir(), "plugins")))))


def foreign_brain():
    """(this brain's root, the installed one's, runs from a repository's tree) when this brain is not the installed one; None
    when it is, or when the installed one cannot be told."""
    inst = installed_brain()
    own = os.path.realpath(BRAIN_ROOT)
    if inst is None or same_path(own, inst):
        return None
    return own, inst, in_tree(own)


def brain_bins():
    """[(PATH entry, its brain's real root)] of the PATH entries that hold a brain (bin/brain beside scripts/brain.py, executable
    off Windows), in PATH order, each brain once. Not shutil.which: on Windows it finds no `brain`, which has no extension."""
    out, seen = [], set()
    for p in os.environ.get("PATH", "").split(os.pathsep):
        if not os.path.isabs(p):
            continue
        r = os.path.dirname(os.path.realpath(p))
        b = os.path.join(p, "brain")
        if (os.path.normcase(r) not in seen and os.path.isfile(b) and (WINDOWS or os.access(b, os.X_OK))
                and os.path.isfile(os.path.join(r, "scripts", "brain.py"))):
            seen.add(os.path.normcase(r))
            out.append((p, r))
    return out


def path_chain():
    """[(short command, {PATH entries it was started with})] of the processes above this one, nearest first; [] where their
    environment cannot be read (Linux /proc only)."""
    out, pid = [], os.getppid()
    while pid > 1 and len(out) < 64:
        try:
            with open("/proc/%d/environ" % pid, "rb") as f:
                env = f.read().split(b"\0")
            with open("/proc/%d/cmdline" % pid, "rb") as f:
                argv = [os.fsdecode(a) for a in f.read().split(b"\0") if a]
            with open("/proc/%d/stat" % pid) as f:
                ppid = int(f.read().rsplit(")", 1)[1].split()[1])
        except (OSError, ValueError, IndexError):
            break
        path = next((os.fsdecode(kv[5:]) for kv in env if kv.startswith(b"PATH=")), "")
        name = " ".join(os.path.basename(a) for a in argv[:2 if argv[1:2] and not argv[1].startswith("-") else 1])
        out.append((name[:60] or "?", {os.path.normpath(x) for x in path.split(os.pathsep) if x}))
        pid = ppid
    return out


def path_origin(entry, chain, marked):
    """Where a PATH entry came from: the session start's own line, else the process that started the outermost one holding it
    (in a session, a process that started Claude Code, or its Bash shell: the profile it snapshots, CLAUDE_ENV_FILE, the
    command)."""
    if marked and same_path(entry, marked):
        return "put first by the brain's session start, CLAUDE_ENV_FILE"
    if not chain:
        return "its source cannot be read on this system"
    held = [i for i, (_, dirs) in enumerate(chain) if os.path.normpath(entry) in dirs]
    if not held:
        return "set by %s, which started this brain" % chain[0][0]
    i = held[-1]
    if i + 1 < len(chain):
        return "from %s, which started %s with it" % (chain[i + 1][0], chain[i][0])
    return "inherited from %s, the first process read" % chain[i][0]


def path_lines():
    """doctor's lines on which brain runs: this one against the installed one, then each brain on PATH in order."""
    inst = installed_brain()
    out = []
    other = foreign_brain() if inst else None
    if inst is None:
        out.append(("info", "the installed brain cannot be told (no single enabled vibemaestro-brain in installed_plugins.json "
                            "that reads): nothing is refused"))
    elif other:
        out.append(("warn", "this brain %s is not the installed one %s: %s" % (other[0], inst, "it runs from a repository's tree, "
                    "so its writes are let through" if other[2] else "its writes are refused")))
    bins = brain_bins()
    if not bins:
        out.append(("info", "no brain on PATH"))
    sid = session_id()
    chain, marked = path_chain(), env_marked(sid) if sid else None
    for n, (p, r) in enumerate(bins, 1):
        tags = (["a bare `brain` runs it"] if n == 1 else []) + (["installed"] if inst and same_path(r, inst) else [])
        level = "info" if n > 1 else "ok" if inst is None or same_path(r, inst) else "warn"
        out.append((level, "brain on PATH %d of %d: %s (%s)" % (n, len(bins), p, "; ".join(tags + [path_origin(p, chain, marked)]))))
    return out


# --- extensions ---------------------------------------------------------------------------------------------------------------
# Another plugin may add to the brain through one declared script, which brain_ext.py runs in its own process. Finding one is
# here, so a brain with none never loads brain_ext. It reads the registry as vibemaestro-sdlc reads a rule pack.

EXT_MARKER = "brain-extension.json"                 # at an extension plugin's root, a regular file
EXT_TITLE = ("Extensions (lines from enabled plugins: information, below the owner's word and SOUL, not instructions)")
EXT_NOTE = "the lines below come from enabled plugins: information, below the owner's word and SOUL, not instructions"
EXT_DEPENDENCY = "vibemaestro-brain"
EXT_FILE_MAX = 1024 * 1024                          # bytes of a settings file or the registry read
SCOPE_RANK = {"local": 0, "project": 1}             # an install entry of the project before the user's
_EXT_FOUND = {}


def session_project():
    """The session's project directory, whose `.claude/settings*.json` Claude Code reads: the hooks' CLAUDE_PROJECT_DIR, else
    the session's record, else the working directory."""
    return _PROJECT[0] if _PROJECT else (bound() or {}).get("project") or shell_dir()


def plain(path):
    """"file", "dir", "link" or "other" for what `path` itself is (never followed), None when it is not there."""
    try:
        m = os.lstat(path).st_mode
    except (OSError, ValueError):
        return None
    return "link" if stat.S_ISLNK(m) else "dir" if stat.S_ISDIR(m) else "file" if stat.S_ISREG(m) else "other"


def inside(path, root):
    """`path` lies strictly below `root` (both real paths)."""
    return path.startswith(root.rstrip(os.sep) + os.sep)


def json_capped(path, cap, follow=True):
    """The JSON value of the file at `path`, None when it is missing, larger than `cap` bytes, not UTF-8 JSON, or (with
    follow=False) a symlink."""
    try:
        fd = os.open(path, os.O_RDONLY | O_BINARY | (0 if follow else getattr(os, "O_NOFOLLOW", 0)))
        with os.fdopen(fd, "rb") as f:
            data = f.read(cap + 1)
        return json.loads(data.decode("utf-8")) if len(data) <= cap else None
    except (OSError, ValueError, UnicodeDecodeError, RecursionError):
        return None


def applicable(entries, project):
    """The install entry of one plugin that applies to `project` (a real path): an entry with `projectPath` applies to that
    project only; a local entry before a project one before the rest. None when none does."""
    best = None
    for e in entries if isinstance(entries, list) else []:
        if not isinstance(e, dict):
            continue
        pp = e.get("projectPath")
        if pp is not None and (not isinstance(pp, str) or os.path.realpath(pp) != project):
            continue
        rank = SCOPE_RANK.get(e.get("scope"), len(SCOPE_RANK)) if isinstance(e.get("scope"), str) else len(SCOPE_RANK)
        if best is None or rank < best[0]:
            best = (rank, e)
    return best[1] if best else None


def enabled_ids(project):
    """{plugin id: bool} of `enabledPlugins` in the user, project, local and managed settings, a later file winning."""
    out = {}
    for p in [os.path.join(config_dir(), "settings.json"), os.path.join(project, ".claude", "settings.json"),
              os.path.join(project, ".claude", "settings.local.json")] + list(MANAGED_SETTINGS):
        obj = json_capped(p, EXT_FILE_MAX)
        ep = obj.get("enabledPlugins") if isinstance(obj, dict) else None
        if isinstance(ep, dict):
            out.update((k, v) for k, v in ep.items() if isinstance(v, bool))
    return out


def depends_on(manifest, name):
    """A plugin manifest lists `name` in `dependencies`: the name, `name@<marketplace>`, or an object with that `name`."""
    deps = manifest.get("dependencies") if isinstance(manifest, dict) else None
    for x in deps if isinstance(deps, list) else []:
        n = x if isinstance(x, str) else x.get("name") if isinstance(x, dict) else None
        if isinstance(n, str) and (n == name or n.startswith(name + "@")):
            return True
    return False


def extension_roots(project=None):
    """[(plugin id, real root)] of the plugins that extend the brain, in plugin-id order: an install entry that applies to the
    session's project, enabled by a settings file, its root inside `<config dir>/plugins/`, its manifest depending on
    vibemaestro-brain, and EXT_MARKER a regular file at its root. Read once per process and project; never raises."""
    if worker() or os.environ.get("BRAIN_OFF", "") not in ("", "0"):
        return []                                   # a brain that is off, or a worker's, calls no extension
    project = project or session_project()
    if not os.path.isabs(project):                  # no project to read (the shell's directory was deleted): no extension
        return []
    project = os.path.realpath(project)
    if project in _EXT_FOUND:
        return _EXT_FOUND[project]
    out = []
    try:
        plugins = os.path.join(config_dir(), "plugins")
        reg = json_capped(os.path.join(plugins, "installed_plugins.json"), EXT_FILE_MAX)
        ids = reg.get("plugins") if isinstance(reg, dict) else None
        top, enabled = os.path.realpath(plugins), None
        for pid in sorted(ids) if isinstance(ids, dict) else []:
            e = applicable(ids[pid], project)
            inst = e.get("installPath") if isinstance(e, dict) else None
            if not isinstance(inst, str) or not os.path.isabs(inst):
                continue
            root = os.path.realpath(inst)
            if not inside(root, top) or plain(os.path.join(root, EXT_MARKER)) != "file":
                continue
            if enabled is None:
                enabled = enabled_ids(project)
            if enabled.get(pid) is True and depends_on(json_capped(os.path.join(root, ".claude-plugin", "plugin.json"), 65536,
                                                                    follow=False), EXT_DEPENDENCY):
                out.append((pid, root))
    except Exception:  # noqa: BLE001 — finding an extension must never stop the brain
        out = []
    _EXT_FOUND[project] = out
    return out


def extensions(project=None):
    """The extensions of the session's project as brain_ext checked them (a list, with the skipped ones' notes in
    brain_ext.notes()); [] without importing brain_ext when no plugin ships the marker."""
    if not extension_roots(project):
        return []
    import brain_ext
    return brain_ext.found(project)


# --- render -------------------------------------------------------------------------------------------------------------------

def _left(seconds):
    if seconds <= 0:
        return "expired"
    h, m = int(seconds // 3600), int(seconds % 3600 // 60)
    return "%dd %dh" % (h // 24, h % 24) if h >= 48 else "%dh %02dm" % (h, m)


DAY_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}")       # whole (fullmatch): `$` would let a final newline through
DUE_AHEAD = 7                                       # days before its due day that a request is named on the Due line
CARD_MAX, CARD_LINE = 1000, 300                     # the review card, and one of its lines, in UTF-16 units
CARD_FOCUS = 3                                      # focus ids named per goal on the card, then a count: every goal shows
CARD_TITLE = "Review card (after compaction)"


def parse_day(s):
    """A `YYYY-MM-DD` day as a date; None for any other string and for a day the calendar does not have."""
    if not isinstance(s, str) or not DAY_RE.fullmatch(s):
        return None
    try:
        return datetime.date(int(s[:4]), int(s[5:7]), int(s[8:]))
    except ValueError:
        return None


def today(now=None):
    """Today's date in UTC, the zone every time of the brain is in."""
    return datetime.datetime.fromtimestamp(time.time() if now is None else now, datetime.timezone.utc).date()


def days_to(day, now):
    """Days from today (UTC) to `day`: 0 on the day, negative after it; None for a malformed day or none."""
    d = parse_day(day)
    return None if d is None else (d - today(now)).days


def when(n):
    """A day `n` days ahead: `in 6 d`, `TOMORROW`, `TODAY`, `OVERDUE 2 d`."""
    return "TODAY" if n == 0 else "TOMORROW" if n == 1 else "in %d d" % n if n > 0 else "OVERDUE %d d" % -n


def review_text(it, n):
    """A goal's review part `n` days before its review day: `review 12-31`, or `review OVERDUE 3 d` once it has passed."""
    return "review OVERDUE %d d" % -n if n < 0 else "review %s" % it["review"][5:10]


def review_part(it, now):
    """A goal's review part at `now`; "" when it holds no review day."""
    n = days_to(it.get("review"), now)
    return "" if n is None else review_text(it, n)


def last_of(st, iid):
    """The item `iid` continues as at the end of its supersede chain (itself when it was never superseded)."""
    it, seen = st["items"].get(iid) if isinstance(iid, str) else None, set()
    while it is not None and it["status"] == "superseded" and it.get("superseded_by") in st["items"] and it["id"] not in seen:
        seen.add(it["id"])
        it = st["items"][it["superseded_by"]]
    return it["id"] if it is not None else iid


def successor(st, iid):
    """The live item that `iid` is, or continues as through its supersede chain; None when the chain ends closed, archived,
    queued or nowhere. A focus or a goal superseded keeps its meaning, so what pointed to it points to its successor."""
    end = last_of(st, iid)
    return end if (st["items"].get(end) or {}).get("status") == "live" else None


def focus_of(st, it):
    """The live focus a Next item or a running session is tied to (`--focus`), None when it has none or the focus is no
    longer live."""
    return successor(st, it.get("focus")) if st is not None and it.get("focus") else None


def goal_of(st, it):
    """The goal a focus points to: the live one its stored goal continues as, else the stored id."""
    g = it.get("goal")
    return (successor(st, g) if st is not None else None) or g


def text_max(letter):
    """An item's text cap: the configuration's `text_caps` for its letter, else its `text_max`."""
    c = conf()
    return c["text_caps"].get(letter, c["text_max"])


def line_max(letter):
    return text_max(letter) + LINE_EXTRA + (GOAL_EXTRA if letter == "G" else 0)


def units(text):
    """The length Claude Code counts a hook string in: UTF-16 code units, so an emoji or another character past U+FFFF is 2."""
    return len(text.encode("utf-16-le")) // 2


def cut_units(text, n):
    """`text` cut to at most `n` UTF-16 units, never inside a character."""
    if units(text) <= n:
        return text
    out, used = [], 0
    for c in text:
        used += 2 if ord(c) > 0xFFFF else 1
        if used > n:
            break
        out.append(c)
    return "".join(out)


def _joins(text, k):
    """Whether text[k] is part of the symbol shown before it: a combining mark (an NFD accent, a variation selector, a vowel
    sign), a skin tone, a tag, either side of a zero-width joiner, the second of a flag's pair, a Hangul vowel or final."""
    c, p = ord(text[k]), ord(text[k - 1])
    if unicodedata.category(text[k]) in ("Mn", "Mc", "Me"):
        return True
    if 0x1F3FB <= c <= 0x1F3FF or 0xE0020 <= c <= 0xE007F or 0x200D in (c, p) or 0x1160 <= c <= 0x11FF or 0xD7B0 <= c <= 0xD7FF:
        return True
    if 0x1F1E6 <= c <= 0x1F1FF:                     # regional indicators pair from the start of their run
        r = k
        while r > 0 and 0x1F1E6 <= ord(text[r - 1]) <= 0x1F1FF:
            r -= 1
        return (k - r) % 2 == 1
    return False


def cut_symbols(text, n):
    """`text` cut to at most `n` UTF-16 units, never inside a shown symbol (`_joins`); one symbol longer than that (a letter
    and its many marks): the plain cut."""
    k = cut = len(cut_units(text, n))
    while 0 < k < len(text) and _joins(text, k):
        k -= 1
    return text[:k or cut]


_TAGGED = []                                        # doctor renders as an older brain did (older_tags)
_UNFOCUSED = []                                     # doctor renders as a brain before the focus rule did (older_focus)


@contextlib.contextmanager
def older_tags():
    """Render a session line as a brain of log format 6 did before the tags left the kit: `goal G1 · ` (`goal G1 (retired) · `)
    or `no goal · ` before `since`, from the fields it wrote, which the fold keeps. Only doctor renders so, to tell an older
    hot.md from an edit."""
    _TAGGED.append(True)
    try:
        yield
    finally:
        _TAGGED.pop()


@contextlib.contextmanager
def older_focus():
    """Render as a brain before the focus rule did: no `[opened by the session]` on a focus, no `[P1]` on a running session,
    sessions by id. Only doctor renders so, to tell such a brain's hot.md from an edit."""
    _UNFOCUSED.append(True)
    try:
        yield
    finally:
        _UNFOCUSED.pop()


def item_line(it, now, st=None, review=None):
    """`- X5 <text> · since 10-31` and the links that fit the line cap. The stored text is never cut under TEXT_CEIL: a cap
    lowered in the configuration applies to new writes, not to what is already written. A goal shows its review day and
    scope, a focus its goal, a request its due day; with the state `st`, a Next item or a running session tied to a live
    focus starts `[P1]`, and a focus the session opened `[opened by the session]`.
    `review` replaces a goal's review part (render_key tries the forms an earlier render could have shown)."""
    letter = it["id"][0]
    text = clean_line(it["text"])[:TEXT_CEIL]
    if letter == "W" and it.get("expires"):
        ts = parse_iso(it["expires"]) or 0
        date = "until %s (%s)" % (now_iso(ts)[5:16].replace("T", " ") + "Z", _left(ts - now))
    else:
        date = "since %s" % str(it.get("created", ""))[5:10]
    if letter == "T":
        date += " (hits %d)" % it.get("hits", 0)
    tag = ""
    if letter == "G":
        scope = "scope %s" % it["scope"] if isinstance(it.get("scope"), str) else ""
        date = " · ".join(x for x in (review_part(it, now) if review is None else review, scope, date) if x)
    elif letter == "D" and it.get("scope") == "global":   # a decision with none, or `project`, is the project's: not shown
        date = "scope global · %s" % date
    elif letter == "W":                             # before the time left, which render_key finds by its last " ("
        date = "%s · %s" % ("lowers %s%s" % (", ".join(it["lowers"]), "; excludes " + ", ".join(it["excludes"])
                                              if it.get("excludes") else "") if it.get("lowers") else "lowers no signing", date)
    elif letter == "P" and isinstance(it.get("goal"), str):
        g = last_of(st, it["goal"]) if st is not None else it["goal"]    # the goal it continues as, live or retired
        retired = st is not None and (st["items"].get(g) or {}).get("status") != "live"
        date = "goal %s%s · %s" % (g, " (retired)" if retired else "", date)
    elif letter == "S" and _TAGGED and isinstance(it.get("goal"), str):
        g = last_of(st, it["goal"]) if st is not None else it["goal"]
        date = "goal %s%s · %s" % (g, " (retired)" * (st is not None and (st["items"].get(g) or {}).get("status") != "live"), date)
    elif letter == "S" and _TAGGED and isinstance(it.get("no_goal"), str):
        date = "no goal · %s" % date
    elif letter == "R" and parse_day(it.get("due")):
        date = "due %s · %s" % (it["due"][5:10], date)
    elif letter in FOCUSED and not (letter == "S" and _UNFOCUSED):
        f = focus_of(st, it)
        tag = "[%s] " % f if f else ""
    if session_focus(it) and not _UNFOCUSED:        # first after the id: no text of its own can read as the owner's words
        tag = "[opened by the session] "
    line = "- %s %s%s · %s" % (clean_line(it["id"]), tag, text, clean_line(date))
    return line + links_tail(units(line), it)


def links_tail(used, it):
    """The ` · links …` tail of an item line whose first `used` UTF-16 units are written: as many links as fit, then `+N`."""
    links = [clean_line(l) for l in it.get("links") or []]
    if not links:
        return ""
    cap = line_max(str(it.get("id", ""))[:1])
    shown = []
    for i, l in enumerate(links):
        rest = len(links) - i - 1
        cand = " · links " + ", ".join(shown + [l]) + (" +%d" % rest if rest else "")
        if used + units(cand) > cap:
            break
        shown.append(l)
    more = len(links) - len(shown)
    tail = " · links " + ", ".join(shown) + (" +%d" % more if more else "") if shown else " · links +%d" % more
    return tail if used + units(tail) <= cap else ""


def quote_line(it):
    """The line under an item with the owner's words: `  "<quote>" · <where, ≤ 30>`, the quote cut for room only, at 120 under
    a pin and at 300 under a goal, a focus or a request (`brain show` prints it whole); None when its source holds no quote (an
    owner supersede of a pin stores none)."""
    src = it.get("source") if isinstance(it.get("source"), dict) else {}
    q = clean_line(src.get("quote") or "") if it["id"][0] in QUOTED else ""
    if not q.strip():
        return None
    shown = QUOTE_SHOWN if it["id"][0] == "D" else QUOTE_LONG
    if units(q) > shown:                            # in UTF-16 units, as Claude Code counts the string
        q = cut_symbols(q, shown - 1) + "…"
    where = cut_symbols(clean_line(src.get("where") or ""), WHERE_SHOWN)
    return '  "%s"%s' % (q, " · " + where if where.strip() else "")


def blocks_line(it):
    """A queue item's `  blocks: …` line, None for one that names nothing (an item an older brain wrote)."""
    b = clean_line(it.get("blocks") or "") if it["id"][0] == "Q" and isinstance(it.get("blocks"), str) else ""
    return "  blocks: %s" % cut_symbols(b, FIELD_MAX["blocks"]) if b.strip() else None


def goal_lines(it):
    """A goal's `  done when: …` and `  not doing: …` lines (each stored ≤ 200 units)."""
    return ["  %s: %s" % (label, cut_symbols(clean_line(it[key]), FIELD_MAX["done"]))
            for key, label in (("done", "done when"), ("not_doing", "not doing")) if isinstance(it.get(key), str)]


def done_items(st, now):
    """The R, N, X, S and Q items the log closed (`close` or `link-close`) in the last DONE_WINDOW seconds, newest first."""
    out = []
    for it in st["items"].values():
        t = parse_iso(it.get("retired") or "")
        if it["id"][0] in DONE_LETTERS and it["status"] == "closed" and t is not None and now - t < DONE_WINDOW:
            out.append((-t, -it["touched"], it["id"], it))
    return [x[3] for x in sorted(out)]


def done_line(it):
    """`- X5 owner/name#N a1b2c3d4e5f6 · <text>`: what closed it first (each anchor and merge commit of a link-close, else
    the close's pointer), the text last, so a long text is what the line cap cuts."""
    ln = it.get("linked")
    if isinstance(ln, dict):
        head = ", ".join(clean_line(a.get("anchor") or "") + (" " + clean_line(a["sha"]) if a.get("sha") else "")
                         for a in ln.get("anchors") or [] if isinstance(a, dict))
    else:
        head = clean_line(it.get("pointer") or "")
    return cut_units("- %s%s · %s" % (clean_line(it["id"]), " " + head if head else "", clean_line(it["text"])), line_max(it["id"][0]))


def done_lines(st, now):
    done = done_items(st, now)
    out = [done_line(it) for it in done[:DONE_SHOWN]]
    if len(done) > DONE_SHOWN:
        out.append("(+%d more: brain doctor)" % (len(done) - DONE_SHOWN))
    return out


HALF_TITLES = {"left": "## Brain · left brain%s v%d · %s/%s chars   (the owner's: change only with `brain owner`, through "
                       "the dialog)",
               "right": "## Brain · right brain%s v%d · %s/%s chars   (change only with `brain op`; Done is derived)"}
TITLE_SET = frozenset([t for _, t in SECTIONS] + [DONE_TITLE])
CONT = " (cont.)"
MATRIX_LINE = "Matrix: `brain matrix`"


def titled(fmt, version, cap, body, part=""):
    """The title (which part, version, own size in UTF-16 units, cap) above `body`, the size counted with the title in it."""
    size = 0
    for _ in range(3):
        text = "\n".join([fmt % (part, version, "{:,}".format(size), "{:,}".format(cap))] + body) + "\n"
        if units(text) == size:
            break
        size = units(text)
    return text


def retitled(text):
    """A string of `render_strings` with its title's size counted again (the hook added marks to it): as `titled` counts."""
    head, nl, rest = text.partition("\n")
    for _ in range(3):
        new = _SIZE.sub(lambda m: " · {:,}/{} chars".format(units(text), m.group(1)), head, count=1)
        if new == head:
            break
        head, text = new, new + nl + rest
    return text


def queue(st, letter):
    """A section's overflow queue, head first."""
    return sorted((it for it in st["items"].values() if it["id"][0] == letter and it["status"] == "queued"),
                  key=lambda i: (i.get("queued", 0), int(i["id"][1:])))


def queue_counts(st):
    """[(letter, items waiting)] of the right brain's sections whose queue is not empty, in render order; one pass."""
    n = {}
    for it in st["items"].values():
        if it["status"] == "queued":
            n[it["id"][0]] = n.get(it["id"][0], 0) + 1
    return [(l, n[l]) for l in dict(HALVES)["right"] if n.get(l)]


def overflow_line(st):
    """The one injected line that counts the queues, None while every queue is empty."""
    counts = ["%s %d" % c for c in queue_counts(st)]
    return "Overflow queue: %s (in the log, not injected: brain overflow)" % ", ".join(counts) if counts else None


def due_line(st, now):
    """`Due: R5 OVERDUE 2 d (10-29) · R3 TOMORROW (11-01) · R4 in 6 d (11-06)`: the live requests due within DUE_AHEAD days or
    past due, soonest first; None when there is none."""
    rows = []
    for it in live(st, "R"):
        n = days_to(it.get("due"), now)
        if n is not None and n <= DUE_AHEAD:
            rows.append((n, int(it["id"][1:]), "%s %s (%s)" % (it["id"], when(n), it["due"][5:10])))
    return "Due: " + " · ".join(r[2] for r in sorted(rows)) if rows else None


def item_groups(st, letter, now):
    """Each live item of a section, as one group: its line, the quote line of an item that holds the owner's words, and a goal's
    done and not-doing lines. By id, except Next and Sessions: the items tied to a live focus first, by the focus's id, then the
    rest."""
    def order(it):
        f = focus_of(st, it) if letter == "X" or (letter == "S" and not _UNFOCUSED) else None
        return (0, int(f[1:]), int(it["id"][1:])) if f else (1, 0, int(it["id"][1:]))

    out = []
    for it in sorted((i for i in st["items"].values() if i["id"][0] == letter and i["status"] == "live"), key=order):
        q, b = quote_line(it), blocks_line(it)
        out.append([item_line(it, now, st)] + ([q] if q else []) + ([b] if b else []) + (goal_lines(it) if letter == "G" else []))
    return out


def half_groups(st, half, now):
    """[(section title or None, [lines], whether the group opens its section)] of one half in render order: a section's title
    rides with its first item (alone when the section is empty), so a title never ends a string."""
    out = []

    def section(title, groups):
        out.append((title, [title] + (groups[0] if groups else []), True))
        out.extend((title, g, False) for g in groups[1:])

    if half == "right":
        for line in (due_line(st, now), overflow_line(st)):
            if line:
                out.append((None, [line], True))
    for letter in dict(HALVES)[half]:
        if letter == "F":                           # Done sits between Traps and Facts
            section(DONE_TITLE, [[l] for l in done_lines(st, now)])
        section(dict(SECTIONS)[letter], item_groups(st, letter, now))
    if half == "left":
        out.append((None, [MATRIX_LINE], True))
    return out


def budget(i):
    """Room for the body of string `i` (0-based): its title, the room the SessionStart pass adds to every string (marks and
    notes), string 1's lines of the hook and the last slot's line naming what was not injected are kept out of it."""
    return (STRING_MAX - TITLE_ROOM - ANNOTATE_ROOM - (FIRST_RESERVE if i == 0 else 0)
            - (LAST_RESERVE if i == SLOTS - 1 else 0))


def pack(groups, start):
    """The groups as chunks of lines, one chunk per string from string index `start`; a group moves whole, and a section that
    goes on in the next string gets its title again, marked ` (cont.)`."""
    chunks, used = [[]], 0
    for title, lines, opens in groups:
        size = sum(units(l) + 1 for l in lines)
        if chunks[-1] and used + size > budget(start + len(chunks) - 1):
            chunks.append([])
            used = 0
            if title and not opens:
                chunks[-1].append(title + CONT)
                used += units(title + CONT) + 1
        chunks[-1].extend(lines)
        used += size
    return chunks


def render_strings(st, now=None, limit=None):
    """[(half, text)]: the left brain's strings, then the right brain's, at least one each, every section's title shown. Each
    string is ≤ STRING_MAX units once the SessionStart pass has added its lines. With `limit`, the strings past it are dropped,
    and the last one kept ends with a line naming how many lines and which sections were not injected."""
    now = time.time() if now is None else now
    out = []                                        # (half, which string of it, body lines); titled last
    for half, _ in HALVES:
        chunks = pack(half_groups(st, half, now), len(out))
        out += [(half, ", %d of %d" % (k, len(chunks)) if len(chunks) > 1 else "", body) for k, body in enumerate(chunks, 1)]
    if limit and len(out) > limit:
        lines, names = 0, []
        for _, _, body in out[limit:]:
            for line in body:
                lines += 1
                base = line[:-len(CONT)] if line.endswith(CONT) else line
                if base in TITLE_SET and base not in names:
                    names.append(base)
        half, part, body = out[limit - 1]
        tail = "[brain: %d more lines not injected%s; brain render shows them]" % (lines, ": " + ", ".join(names) if names else "")
        out = out[:limit - 1] + [(half, part, body + [tail[:LAST_RESERVE - 1]])]   # inside the title's size
    return [(half, titled(HALF_TITLES[half], st["version"], STRING_MAX, body, part)) for half, part, body in out]


def render_all(st, now=None):
    """hot.md and `brain render`: every string, none dropped, one blank line between them."""
    return "\n".join(text for _, text in render_strings(st, now))


def half_of(letter):
    return "left" if letter in LEFT_LETTERS else "right"


def half_empty(st, half, now=None):
    """Nothing live or queued of the half's kinds, and for the right brain nothing in Done: SessionStart leaves the right
    brain's strings out unless one has a note (the left brain opens string 1, which is always printed)."""
    letters = dict(HALVES)[half]
    if any(it["status"] in ("live", "queued") and it["id"][0] in letters for it in st["items"].values()):
        return False
    return half != "right" or not done_items(st, time.time() if now is None else now)


# --- the review card ----------------------------------------------------------------------------------------------------------

def fit_items(head, items, sep, cap=CARD_LINE):
    """`head` and as many of `items` as fit `cap` UTF-16 units (a card line), then ` +N` for the rest."""
    line, shown = head, 0
    for i, x in enumerate(items):
        rest = len(items) - i - 1
        cand = line + (sep if shown else "") + x
        if units(cand) + (units(" +%d" % rest) if rest else 0) > cap:
            break
        line, shown = cand, shown + 1
    return line + (" +%d" % (len(items) - shown) if shown < len(items) else "")


FOCUS_FILE_MAX = 4096                               # bytes of a focus's counts file read: its JSON is a few hundred
FOCUS_TIME_RE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}")


def focus_counts(ids):
    """The card's counts line of each live focus in `ids`: the `line` of `kb.py focus`'s file for the session's project with its
    time, else `P1: not counted yet` (no file, one that cannot be read or does not parse, or one that names another focus).
    The file is `<state base>/vibemaestro/focus/<place key>/<P>.json`; the key is sdlc's (`project-` and 16 hex of the SHA-256
    of git's common directory), computed here: the brain reads sdlc's file and imports nothing from it.
    shortcut: outside git the key is of the directory, which sdlc never writes under: not counted yet, until a dotfiles repo
    or a non-git project needs counts."""
    if not ids:
        return []                                   # no focus: no git call
    try:
        key = "project-" + hashlib.sha256(project_dir(session_project()).encode("utf-8", "surrogateescape")).hexdigest()[:16]
        base = os.path.join(os.path.dirname(state_root()), "focus", key)
    except (OSError, ValueError, Refused):          # ValueError: a project path with a NUL or a lone surrogate
        return ["%s: not counted yet" % p for p in ids]
    out = []
    for p in ids:
        try:
            fd = os.open(os.path.join(base, p + ".json"), os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0) | O_BINARY)
            try:
                data = os.read(fd, FOCUS_FILE_MAX + 1) if stat.S_ISREG(os.fstat(fd).st_mode) else b""
            finally:
                os.close(fd)
            rec = json.loads(data.decode("utf-8")) if len(data) <= FOCUS_FILE_MAX else None
            line, t = rec.get("line"), rec.get("time")
            if rec.get("focus") != p or not isinstance(line, str) or not line.startswith(p + ": ") or not FOCUS_TIME_RE.match(str(t)):
                raise ValueError(p)
            out.append("%s (%s)" % (cut_units(clean_line(line), CARD_LINE - 14), t[5:16].replace("T", " ")))   # the time always shows
        except (OSError, ValueError, RecursionError, AttributeError):   # AttributeError: a JSON that is not an object
            out.append("%s: not counted yet" % p)
    return out


def card_lines(st, now, stale=(), loss=None, ops=None, d=None):
    """The lines of the review card this brain computes: one line per live goal (its review day, the live focus that points
    to it and, with the log's `ops`, its last progress), the dormant items, the sections at 85 % of their caps or over, the
    live items whose anchors closed (`stale`: [(id, "owner/name#N merged")]), the overflow queue, the record due and a backup
    that fails or falls behind (both from the state directory `d`), the loss score of the last compaction logged (`loss`:
    (score or None, its time) or None), the live Next items and sessions tied to no live focus, and, last of these, one
    counts line per live focus
    (from the session's project, see focus_counts). Without `ops`, no ledger line. An extension's lines follow these
    (brain_ext.start_lines)."""
    out = []
    led = None
    if ops is not None:
        import brain_ledger
        led = brain_ledger.card(st, ops, now, d)
    focus = sorted(live(st, "P"), key=lambda i: int(i["id"][1:]))
    for g in sorted(live(st, "G"), key=lambda i: int(i["id"][1:])):
        n = days_to(g.get("review"), now)
        mine = [p["id"] for p in focus if goal_of(st, p) == g["id"]]
        named = " ".join(mine[:CARD_FOCUS]) + (" +%d" % (len(mine) - CARD_FOCUS) if len(mine) > CARD_FOCUS else "")
        parts = ["%s review %s" % (g["id"], when(n) if n is not None else "not set"), "focus " + named if mine else "no focus"]
        parts += list(led["goals"].get(g["id"], ())) if led else []
        out.append(cut_units(" · ".join(parts), CARD_LINE))
    if led and led["dormant"]:
        out.append(led["dormant"])
    if led and led["soul"]:
        out.append(led["soul"])
    count = {letter: len(live(st, letter)) for letter, _ in SECTIONS}
    over = ["%s %d/%d" % (title.split(" (")[0], count[letter], cap(letter)) for letter, title in SECTIONS
            if count[letter] >= WARN_RATIO * cap(letter)]
    if over:
        out.append(fit_items("sections over 85 %: ", over, ", "))
    if stale:
        out.append(fit_items("anchors closed: ", ["%s %s" % (clean_line(i), clean_line(a)) for i, a in stale], " · "))
    q = ["%s %d" % c for c in queue_counts(st)]
    if q:
        out.append(fit_items("overflow queue: ", q, ", "))
    if led and led["record"]:
        out.append(led["record"])
    late = backup_card(d, now) if d else None
    if late:
        out.append(late)
    if loss and loss[0] == LOSS_PENDING:
        out.append("loss score of this compaction: not logged yet (brain doctor shows it)")
    elif loss:
        score, t = loss
        out.append("loss score of the last compaction logged: %s (%s)" % (
            "%.2f" % score if score is not None else "none (no anchor or no summary)", t[5:16].replace("T", " ")))
    loose = [it["id"] for letter in FOCUSED for it in sorted(live(st, letter), key=lambda i: int(i["id"][1:]))
             if not focus_of(st, it)]
    if loose:                                       # attach each to its focus, defer it or drop it
        out.append(fit_items("work with no focus: ", loose, ", "))
    out += focus_counts([p["id"] for p in focus])
    return out


def card_text(lines, title=CARD_TITLE):
    """The card in string 1 after a compaction (or, with another `title`, the extension block of another start): its title,
    then each line while the whole stays ≤ CARD_MAX units; the lines past it become one `(+N lines: brain doctor)`."""
    lines = ["- " + l for l in lines] or ["- nothing to review"]
    out, used = [title], units(title) + 1
    for i, l in enumerate(lines):
        rest = len(lines) - i - 1
        if used + units(l) + 1 + (units("(+%d lines: brain doctor)" % rest) + 1 if rest else 0) > CARD_MAX:
            out.append("(+%d lines: brain doctor)" % (len(lines) - i))
            break
        out.append(l)
        used += units(l) + 1
    return "\n".join(out) + "\n"


LOSS_PENDING = "pending"                            # last_loss: this session's compaction has no score logged yet


def last_loss(d, sid=None):
    """(loss score or None, its time) of the Episode Log's last `compact` line, None when it has none. With `sid` (the card,
    at SessionStart:compact, which Claude Code usually runs before PostCompact logs this compaction's): that session's last
    `compact` line, or (LOSS_PENDING, its time) when a `pre-compact` line of that session follows it, so the card never shows
    the previous compaction's score as this one's; a session with neither line reads the last of any session."""
    try:
        with open(os.path.join(d, "episodes.jsonl"), "rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - 262144))
            data = f.read()
    except OSError:
        return None
    lines = []
    for b in reversed(data.split(b"\n")):
        try:
            o = json.loads(b)
        except ValueError:
            continue
        if isinstance(o, dict) and o.get("kind") in ("compact", "pre-compact") and isinstance(o.get("t"), str) and parse_iso(o["t"]):
            lines.append(o)
    mine = [o for o in lines if sid and o.get("session") == sid]
    for o in mine or lines:
        if o["kind"] == "pre-compact" and mine:
            return LOSS_PENDING, o["t"]
        if o["kind"] == "compact":
            score = o.get("loss")
            return (score if isinstance(score, (int, float)) and not isinstance(score, bool) else None), o["t"]
    return None


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


def cap_warning(letter, n):
    """The 85 % line once a section holds `n` live items, None under it (or over the cap: a lowered cap demotes nothing)."""
    c = cap(letter)
    return "warning: %s at %d of %d" % (dict(SECTIONS)[letter], n, c) if WARN_RATIO * c <= n <= c else None


def check_cap(st, letter):
    """One more item of a left-brain section: refused at its cap, naming the least recently touched items, since the left brain
    has no overflow and the owner chooses what to retire or promote. Returns the 85 % warning, or None. A right-brain section
    never refuses: its add goes into the overflow queue (`placement`)."""
    cur = live(st, letter)
    if letter in LEFT_LETTERS and len(cur) >= cap(letter):
        raise Refused(1, "%s holds %d of %d live items, and the left brain has no overflow: ask the owner which to retire "
                         "(`brain owner unpin`) or move out to a pointer (`brain owner promote`); least recently touched: %s"
                      % (dict(SECTIONS)[letter], len(cur), cap(letter), ", ".join(it["id"] for it in cur[:5])))
    return cap_warning(letter, len(cur) + 1)


def moves_up(st, letter, live_after, place=None):
    """The ids that move from a section's overflow queue to live, head first, while the section would hold fewer than its cap
    with `live_after` live items. `place` (old id, new id or None): the old item's place in the queue goes to the new one, or
    is left (a close)."""
    q = [it["id"] for it in queue(st, letter)]
    if place:
        q = [place[1] if x == place[0] else x for x in q if x != place[0] or place[1]]
    return q[:max(0, cap(letter) - live_after)]


def placement(st, letter, iid):
    """(op name, the ids that move up, the line to print) of a new item `iid` of a right-brain section. It is queued when the
    section is at its cap once the queue's head has moved up, or when items still wait in the queue: first in, first out."""
    n = len(live(st, letter))
    up = moves_up(st, letter, n)
    waiting = len(queue(st, letter)) - len(up)
    if waiting or n + len(up) >= cap(letter):
        return "overflow-add", up, "queued %s (%s holds %d of %d; %d queued before it; not injected until it moves up)" % (
            iid, dict(SECTIONS)[letter], n + len(up), cap(letter), waiting)
    warn = cap_warning(letter, n + len(up) + 1)
    return "add", up, "added %s%s" % (iid, "\n" + warn if warn else "")


def moved(up):
    return "\nmoved up from the overflow queue: %s" % ", ".join(up) if up else ""


def get_item(st, iid, letters):
    """A live or queued item of `letters` (a queued item can be closed, superseded, touched and hit)."""
    it = st["items"].get(iid)
    if it is not None and it["status"] == "queued" and it["id"][0] in letters:
        return it
    return get_live(st, iid, letters)


def get_live(st, iid, letters):
    it = st["items"].get(iid)
    if it is None or it["status"] != "live":
        raise Refused(1, "%s is not a live item" % iid)
    if it["id"][0] not in letters:
        if it["id"][0] in OWNER_LETTERS:
            raise Refused(1, "%s is an owner item: only `brain owner …`, through the permission dialog, changes it" % iid)
        raise Refused(1, "%s is not an owner item; use `brain op`" % iid)
    return it


def write(build, ops_too=False):
    """Run `build(d, st) -> (op, texts, message, extra)` under the lock and append its op; returns the printed message. Refused
    while the project's configuration holds a wrong value. With `ops_too`, `build(d, st, ops)` also gets the log's ops (the
    ledger is read from them)."""
    check_caller()
    check_config()
    d = state_dir()
    with locked(d):
        raw, ops = verify(d)
        st = fold(ops)
        check_writer(st)
        test_pause()
        op, texts, msg, after = build(d, st, ops) if ops_too else build(d, st)
        sanitize(d, texts)
        t = now_iso()
        claim = {"op": "claim", "t": t, "by": by(), "takeover": False} if st["writer"] is None else None
        op = dict(op, t=t, by=by())
        trial = json.loads(dumps(st))               # fold first, append after: an op the fold refuses never reaches the log
        for i, o in enumerate([claim, op] if claim else [op], len(raw) + 1):
            apply(trial, json.loads(dumps(dict(o, seq=i))))
        if claim:
            raw = append(d, raw, claim)
            apply(st, dict(claim, seq=len(raw)))
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


def episode_line(d, session, kind, **fields):
    """Append one line to the Episode Log, `episodes.jsonl` (append-only, 0600, one write per line)."""
    ensure_dir(d)
    line = dict(fields, t=now_iso(), kind=kind, session=session or None)
    # shortcut: Windows appends by a seek then a write, so two hooks writing at the same instant can overwrite one line (every
    # reader skips a line that is not JSON); take the store lock here if lost episodes ever matter
    fd = os.open(os.path.join(d, "episodes.jsonl"), os.O_WRONLY | os.O_APPEND | os.O_CREAT | O_BINARY, 0o600)
    try:
        os.write(fd, (dumps(line) + "\n").encode("utf-8"))
    finally:
        os.close(fd)


def anchor_warning(letter, anchors):
    """"\nwarning: …" when the anchors of the item just written (its id letter) hold a bare #N that no default repository can
    resolve, else "". Only the kinds the stale check reads are warned about. A hint, never a refusal: whatever goes wrong here,
    the write stands."""
    try:
        import brain_stale
        w = brain_stale.bare_warning(anchors) if letter in brain_stale.LETTERS else ""
    except Exception:  # noqa: BLE001
        return ""
    return "\n" + w if w else ""


def closes_list(letter, values):
    """The `--closes` anchors of an item whose id letter is `letter`, each as `owner/name#N`, duplicates dropped. Refused (64)
    for a kind that never closes by a link, a bare `#N` or any other form, and more than CLOSES_MAX."""
    if not values:
        return []
    if letter not in CLOSES_LETTERS:
        raise Refused(64, "--closes is for a Now, Next, session, queue or request item: a goal, decision or window is the "
                          "owner's to retire, and a focus, a trap or a fact is closed by hand")
    import brain_stale
    out = []
    for v in values:
        a = brain_stale.closes_form(v)
        if a.lower() not in [o.lower() for o in out]:
            out.append(a)
    if len(out) > CLOSES_MAX:
        raise Refused(64, "at most %d --closes: name the issue or PR whose close means this item is done" % CLOSES_MAX)
    check_list("anchor", out)
    return out


def with_closes(anchors, closes):
    """`anchors` with each `closes` anchor added (a closes anchor is an anchor too: the loss score and the marks see it)."""
    return anchors + [c for c in closes if c not in anchors]


def closes_seen(named, kept=()):
    """The write-time lookup of `closes` anchors: the lines to print. `named` are new to the item: Refused(1) for a 404 or one
    already done. `kept` the item already names (carried over or named again): one already done is a warning, since the new
    item may close at the next writer SessionStart."""
    if not named and not kept:
        return ""
    import brain_stale
    return "".join("\n" + l for l in brain_stale.closes_check(named, kept))


def peek(iid=None, letter=None):
    """The checks a write makes, run once before a slow lookup so that it is not paid for a write that would be refused: a
    Claude Code session, the writer, a live item `iid` of `brain op`, room for one more `letter`. Returns the state read, under
    the lock (a read between another write's line and its head would see a log that does not match)."""
    check_caller()
    check_config()
    d = state_dir()
    st = empty_state()
    if os.path.isdir(d):                             # no state yet: nothing to read, and no directory to create
        with locked(d):
            _, st = load(d)
    check_writer(st)
    if iid:
        get_item(st, iid, OP_LETTERS)
    if letter:
        check_cap(st, letter)
    return st


def layer_args(letter, quote, where, goal, focus, due, done=None):
    """Refuse (64) an option of a focus, a request or a Next item on another kind, or one a focus or a request needs left out;
    check the owner's words (1: no rule of the dialog applies to them, only the text guards and `quote_max`, and a longer
    quote is refused, never cut). A focus without the owner's words is one the session opens: it names its goal and when it
    is done. Returns the source of the item's words."""
    if letter == "R" or (letter == "P" and (quote is not None or where is not None)):
        if quote is None or where is None:
            raise Refused(64, "a %s carries the owner's words: --owner-quote Q (verbatim) and --where W"
                          % ("focus" if letter == "P" else "request"))
        check_text("quote", quote, cap=quote_max())
        check_text("where", where)
    elif quote is not None or where is not None:
        raise Refused(64, "--owner-quote and --where are for a focus or a request (the owner's own items go through `brain owner`)")
    elif letter == "P" and (goal is None or done is None):
        gone = [o for o, v in (("--goal G1", goal), ("--done-when D", done)) if v is None]
        try:
            check_text("done when", done, required=done is not None, cap=quote_max())
        except Refused as e:                        # a done when given but unusable is named with the missing goal
            gone.append(e.msg)
        raise Refused(64, "a focus the session opens names its live goal and when it is done; missing: %s (a focus in the "
                      "owner's words takes --owner-quote Q --where W)" % ", ".join(gone))
    if (goal is not None) != (letter == "P"):
        raise Refused(64, "a focus points to one goal: --goal G1 (for a focus)")
    if goal is not None and not (goal[:1] == "G" and ID_RE.fullmatch(goal)):
        raise Refused(64, "--goal must name a goal, like G1")
    check_focus_due(letter, focus, due)
    return dict(SESSION_SOURCE, quote=quote, where=where) if quote is not None else dict(SESSION_SOURCE)


def changed(new, was):
    """A value given that differs from the stored one by more than its spaces and its Unicode form (None: not given, so no
    change)."""
    same = lambda v: unicodedata.normalize("NFC", " ".join((v or "").split()))
    return new is not None and same(new) != same(was)


def session_focus(it):
    """A focus the session opened: one that holds none of the owner's words (every focus an older brain wrote holds them)."""
    src = it.get("source") if isinstance(it.get("source"), dict) else {}
    return str(it.get("id", ""))[:1] == "P" and not (isinstance(src.get("quote"), str) and src["quote"])


JIRA_RX = re.compile(r"[A-Z][A-Z0-9_]+-[1-9][0-9]*")   # a Jira issue key like ABC-12: the shape of an intent's `jira:` (kb.py)
JIRA_MAX = 40                                       # a stored key is short; this keeps a long one out of the log


def check_jira(jira, ok, noun):
    """A `jira` key is for the kinds named in `noun` (`ok`: the letter that takes it); a malformed one is refused (64): the
    stored value is never synced, never sent, only shown."""
    if jira is None:
        return
    if not ok:
        raise Refused(64, "--jira is for %s" % noun)
    if len(jira) > JIRA_MAX or not JIRA_RX.fullmatch(jira):
        raise Refused(64, "--jira must be a Jira issue key like ABC-12 (capital letters, digits or _, a hyphen, a number from 1; "
                          "at most %d characters)" % JIRA_MAX)


def check_focus_words(letter, done, not_doing):
    """A focus's `done when` and `not doing`, stored whole like the quote (its text guards and `quote_max`): the owner's words
    on a focus in the owner's words, the session's on one it opened; 64 on another kind."""
    if letter != "P" and (done is not None or not_doing is not None):
        raise Refused(64, "--done-when and --not-doing are for a focus")
    check_text("done when", done, required=done is not None, cap=quote_max())
    check_text("not doing", not_doing, required=not_doing is not None, cap=quote_max())


def check_focus_due(letter, focus, due):
    """`--focus` names a focus on a Next item or a running session, `--due` a day of the calendar on a request (64 otherwise)."""
    if focus is not None and not (letter in FOCUSED and focus[:1] == "P" and ID_RE.fullmatch(focus)):
        raise Refused(64, "--focus P1 ties a Next item or a running session to a focus (for next and session only)")
    if due is not None and not (letter == "R" and parse_day(due)):
        raise Refused(64, "--due YYYY-MM-DD (a day of the calendar) is for a request")


def check_points(st, letter, goal=None, focus=None):
    """A focus points to a live goal, a Next item or a running session to a live focus (1 otherwise)."""
    for iid, want, noun in ((goal, "G", "goal"), (focus, "P", "focus")):
        if iid is not None and (st["items"].get(iid) or {}).get("status") != "live":
            raise Refused(1, "%s is not a live %s: a %s points to one that is" % (
                iid, noun, "focus" if want == "G" else "running session" if letter == "S" else "Next item"))


KIND_OF = {v: k for k, v in KINDS.items()}         # an id's letter: its kind's name


def ext_options(verb, kind, extopts, claims):
    """({(extension, option): value}, brain's claimable options left to brain) for `brain op VERB` of `kind`. `extopts`:
    {option: value} of the options extensions added to the parser; `claims`: {option: value} of brain's own options an
    extension may take for a kind brain does not use them on (a session's --goal). With no extension, nothing is imported and
    every claimable value stays brain's, whose own checks refuse it on the wrong kind."""
    given = any(v is not None for v in list((extopts or {}).values()) + list(claims.values()))
    if not given or not extensions():
        return {}, claims
    import brain_ext
    taken = {o: v for o, v in claims.items()
             if v is not None and kind not in brain_ext.CLAIMABLE[(verb, o)] and brain_ext.claimed(verb, kind, o)}
    return brain_ext.route(verb, kind, dict(extopts or {}, **taken)), {o: None if o in taken else v for o, v in claims.items()}


def ext_check(verb, kind, given, op, d, st, ops, texts):
    """(texts for the sensitive filter, note lines) of the extensions' checks of this write, under the lock, after brain's
    own (`texts`, the write's own, pass the sensitive filter first); ([], []) and no import when no extension checks anything."""
    if not extensions():
        return [], []
    import brain_ext
    return brain_ext.check(verb, kind, given, op, d, st, ops, texts)


def notes_text(notes):
    return "".join("\n" + n for n in notes)


def check_blocks(letter, blocks, required=True):
    """A queue item names the work it blocks until the owner acts: refused (64) without it on an add, and on any other
    kind; checked as a text of at most 200."""
    if letter != "Q":
        if blocks is not None:
            raise Refused(64, "--blocks is for a queue item: the work it blocks until the owner acts")
        return
    if blocks is None:
        if required:
            raise Refused(64, "a queue item names the work it blocks until the owner acts: --blocks B (an owner/name#N in it "
                              "is checked); what blocks nothing is a Next item or an issue, not the owner queue")
        return
    check_text("blocks", blocks)


def op_add(kind, text, links, anchors, expires, closes=(), quote=None, where=None, goal=None, focus=None, due=None,
           extopts=None, done=None, not_doing=None, jira=None, blocks=None):
    letter = KINDS.get(kind)
    if letter is None:
        raise Refused(64, "--kind must be one of %s" % ", ".join(KINDS))
    closes = closes_list(letter, list(closes))
    if letter in OWNER_LETTERS:
        raise Refused(1, "a %s is an owner item: only `brain owner add`, through the permission dialog, writes one" % kind)
    given, left = ext_options("add", kind, extopts, {"--goal": goal, "--focus": focus, "--due": due})
    goal, focus, due = left["--goal"], left["--focus"], left["--due"]
    source = layer_args(letter, quote, where, goal, focus, due, done)
    check_blocks(letter, blocks)
    check_focus_words(letter, done, not_doing)
    check_jira(jira, letter == "P", "a focus (a goal's goes through `brain owner add`)")
    check_text("text", text, cap=text_max(letter))
    check_list("link", links)
    anchors = with_closes(anchors, closes)
    check_list("anchor", anchors)
    if expires is not None and parse_iso(expires) is None:
        raise Refused(64, "--expires must be like 2026-10-17T22:00:00Z")
    seen = ""
    if closes:
        check_points(peek(letter=letter), letter, goal, focus)   # before a lookup that may take its 2 seconds
        seen = closes_seen(closes)

    def build(d, st, ops):
        check_points(st, letter, goal, focus)
        iid = next_id(st, letter)
        name, up, line = placement(st, letter, iid)
        item = {"id": iid, "kind": kind, "pinned": False, "text": text, "source": source,
                "expires": expires, "links": links, "anchors": anchors, "supersedes": None}
        if closes:
            item["closes"] = closes
        item.update({k: v for k, v in (("goal", goal), ("focus", focus), ("due", due), ("done", done),
                                       ("not_doing", not_doing), ("jira", jira), ("blocks", blocks)) if v is not None})
        op = {"op": name, "item": item}
        if up:
            op["promote"] = up
        own = [text, quote, where, done, not_doing, blocks] + links + anchors     # every text the filter must see
        texts, notes = ext_check("add", kind, given, op, d, st, ops, own)
        return (op, own + texts,
                line + moved(up) + seen + anchor_warning(letter, anchors) + notes_text(notes)
                + ("\nwarning: this focus has no --done-when; a charter for it will need one (brain op words adds it)"
                   if letter == "P" and done is None else ""), None)
    return write(build, ops_too=True)


def op_close(iid, reason, pointer, bulk, extopts=None):
    check_text("reason", reason)
    check_text("pointer", pointer, required=False)
    given, _ = ext_options("close", KIND_OF.get(iid[:1]), extopts, {})

    def build(d, st, ops):
        it = get_item(st, iid, OP_LETTERS + ("W",))    # a window too: ending it only narrows what the session may do
        if iid[0] == "R" and not pointer:
            raise Refused(1, "a request closes only with --pointer to what answered it (a PR, a SHA, a file, a message): the "
                             "owner asked for it")
        if iid[0] == "P" and not pointer:
            raise Refused(1, "a focus closes only with --pointer to what met its done when (a PR, a SHA, a file, a message), "
                             "or to the owner's words that retired it")
        if not bulk and iid[0] != "W" and budget_used(st, session_id(), time.time()) >= BUDGET_N:    # ending a window: never budgeted
            raise Refused(1, "retirement budget: %d retirements in 30 minutes already; add --bulk (logged) if this is a "
                             "deliberate sweep" % BUDGET_N)
        n = len(live(st, iid[0]))
        up = ([] if iid[0] in LEFT_LETTERS else moves_up(st, iid[0], n - 1) if it["status"] == "live"
              else moves_up(st, iid[0], n, (iid, None)))
        op = {"op": "close", "id": iid, "reason": reason, "pointer": pointer, "bulk": bulk}
        if up:
            op["promote"] = up
        texts, notes = ext_check("close", it["kind"], given, op, d, st, ops, [reason, pointer])
        ended = charters_end(iid, d, [reason, pointer] + texts)
        return op, [reason, pointer] + texts, "closed %s%s%s%s" % (iid, moved(up), notes_text(notes), ended), None
    return write(build, ops_too=True)


def charters_end(iid, d, texts):
    """"" for any item but a focus; for a focus that a close or a supersede ends, its charters revoked (revoke_charters), after
    every check of the op, its sensitive filter `texts` included (write's runs again): a revoke is never undone."""
    if iid[0] != "P":
        return ""
    sanitize(d, texts)
    return revoke_charters(iid)


NO_FCNTL = "No module named 'fcntl'"                 # vibemaestro-sdlc's baton on Windows: it locks with fcntl, which is POSIX
BATON_WINDOWS = "vibemaestro-sdlc's baton, which %s, does not run on Windows yet"


def revoke_charters(focus):
    """"\n<lines>" of vibemaestro-sdlc's `baton.py grant revoke --focus <P>` run from this project: each charter the owner signed for
    the focus from it ends with the focus ("" when none was in force). Refused (1) when it cannot run or fails: a closed or
    superseded focus never leaves its charter in force."""
    baton = sdlc_file(os.path.join("scripts", "baton.py"))
    if not baton:
        raise Refused(1, "vibemaestro-sdlc's baton.py was not found, so the charters of %s cannot be revoked; nothing was written"
                      % focus)
    try:
        r = subprocess.run([sys.executable, baton, "grant", "revoke", "--focus", focus], cwd=project_root(), capture_output=True,
                           encoding="utf-8", errors="replace", env=utf8_env(), timeout=60, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError) as e:
        raise Refused(1, "the charters of %s could not be revoked (%s); nothing was written" % (focus, e.__class__.__name__))
    if r.returncode != 0 and WINDOWS and NO_FCNTL in r.stderr + r.stdout:
        raise Refused(1, "%s cannot be closed or superseded: %s; nothing was written, and the rest of the brain works" % (
            focus, BATON_WINDOWS % "revokes its charters"))
    if r.returncode != 0:
        raise Refused(1, "the charters of %s could not be revoked (baton.py rc %d: %s)%s; nothing was written" % (
            focus, r.returncode, printable((r.stderr or r.stdout).strip()[:300]),
            ": this vibemaestro-sdlc predates `grant revoke --focus`, update it"     # its usage names only `grant revoke <id>`
            if r.returncode == 64 and "usage: baton.py grant revoke <id>" in r.stderr + r.stdout else ""))
    lines = [ln for ln in r.stdout.splitlines() if ln.startswith("grant ")]
    return "".join("\n" + printable(ln) for ln in lines)


def op_supersede(iid, text, reason, drop, add_anchors, shorter, bulk, closes=(), focus=None, due=None, extopts=None,
                 done=None, not_doing=None, blocks=None, quote=None, where=None):
    """A supersede of an S or Q item (a session's next step, a queue item's state) is status, not a decision: it spends no
    retirement budget and may shrink (spec R4 point 1); it still keeps every anchor. A focus or a request keeps the owner's
    words byte for byte (and a focus its goal), unless a focus's carries the owner's newer words (`quote` and `where`); a
    request may change its due day, a Next item or a running session its focus. A focus's text never carries progress: a
    supersede that changes only its text is refused."""
    if (quote is not None or where is not None) and iid[:1] != "P":
        raise Refused(64, "--owner-quote and --where on a supersede are for a focus the owner restated")
    if (quote is None) != (where is None):
        raise Refused(64, "the owner's newer words of a focus go together: --owner-quote Q (verbatim) and --where W")
    if quote is not None:
        check_text("quote", quote, cap=quote_max())
        check_text("where", where)
    status = iid[:1] in STATUS_LETTERS
    given, left = ext_options("supersede", KIND_OF.get(iid[:1]), extopts, {"--focus": focus, "--due": due})
    focus, due = left["--focus"], left["--due"]
    check_focus_due(iid[:1], focus, due)
    check_focus_words(iid[:1], done, not_doing)
    check_blocks(iid[:1], blocks, required=False)
    check_text("text", text, cap=text_max(iid[:1]))
    check_text("reason", reason)
    new_closes = closes_list(iid[:1], list(closes))
    check_list("anchor", drop + add_anchors)
    declared = peek(iid)["items"][iid].get("closes") or []
    final = new_closes or [c for c in declared if c not in drop]
    seen = closes_seen([c for c in new_closes if c.lower() not in [x.lower() for x in declared]],
                       [c for c in final if c.lower() in [x.lower() for x in declared]])

    def build(d, st, ops):
        old = get_item(st, iid, OP_LETTERS)
        check_points(st, iid[0], focus=focus)
        src = old.get("source") if isinstance(old.get("source"), dict) else {}
        if iid[0] == "P" and text != old["text"] and not any(changed(new, was) for new, was in (
                (done, old.get("done")), (not_doing, old.get("not_doing")), (quote, src.get("quote")))):
            raise Refused(1, "a focus's text names its wave and never carries progress: progress is a Now item (brain op add "
                             "--kind now). A supersede of a focus changes its --done-when or --not-doing, or carries the "
                             "owner's newer words (--owner-quote Q --where W); to rename the wave, close it with --pointer and "
                             "open a new focus")
        missing = [a for a in drop if a not in old.get("anchors", [])]
        if missing:
            raise Refused(1, "%s holds no anchor %r to drop" % (iid, missing[0]))
        anchors = [a for a in old.get("anchors", []) if a not in drop]
        anchors += [a for a in add_anchors if a not in anchors]
        carried = [c for c in old.get("closes") or [] if c not in drop]     # a dropped anchor leaves `closes` too
        closes = new_closes or carried
        anchors = with_closes(anchors, closes)
        lost = [a for a in old.get("anchors", []) if a not in anchors and a not in drop]
        if lost:
            raise Refused(1, "the new item would lose anchor %r; name it with --drop-anchor and a --reason" % lost[0])
        check_list("anchor", anchors)
        root = chain_root(st, old)
        if not shorter and not status and len(text) < SHRINK_MIN * len(root["text"]):
            raise Refused(1, "the new text is %d characters, under 60%% of the first item of its chain (%s, %d); a supersede "
                             "must not shrink meaning: pass --shorter with a --reason if it must"
                          % (len(text), root["id"], len(root["text"])))
        if not bulk and not status and budget_used(st, session_id(), time.time()) >= BUDGET_N:
            raise Refused(1, "retirement budget: %d retirements in 30 minutes already; add --bulk (logged) if this is a "
                             "deliberate sweep" % BUDGET_N)
        nid = next_id(st, iid[0])
        # the owner's words of a focus or a request go over byte for byte: a supersede rewrites the session's line only,
        # unless it carries the owner's newer words of a focus
        source = (dict(SESSION_SOURCE, quote=quote, where=where) if quote is not None
                  else dict(old["source"]) if iid[0] in ("P", "R") else dict(SESSION_SOURCE))
        item = {"id": nid, "kind": old["kind"], "pinned": False, "text": text, "source": source,
                "expires": old.get("expires"), "links": old.get("links", []), "anchors": anchors, "supersedes": iid}
        if closes:
            item["closes"] = closes
        carry = {"goal": old.get("goal"), "focus": focus or old.get("focus"), "due": due or old.get("due"),
                 "no_goal": old.get("no_goal"),           # a session's reason for no goal, as an older brain wrote it
                 "done": done or old.get("done"), "not_doing": not_doing or old.get("not_doing"),   # a focus's words
                 "jira": old.get("jira"), "blocks": blocks or old.get("blocks")}
        item.update({k: v for k, v in carry.items() if v is not None})
        if old.get("ext"):                          # every extension's entry goes over; its own check may replace it
            item["ext"] = dict(old["ext"])
        if isinstance(old.get("import"), dict):     # where an imported item came from goes with it
            item["import"] = old["import"]
        op = {"op": "supersede", "id": iid, "item": item, "reason": reason, "drop": drop, "shorter": shorter, "bulk": bulk}
        n = len(live(st, iid[0]))
        up = moves_up(st, iid[0], n, (iid, nid) if old["status"] == "queued" else None)
        placed = ""
        if old["status"] == "queued" and nid not in up:
            op["queued"] = True                     # the successor keeps the old item's place in the queue
            placed = " (queued in its place)"
        up = [x for x in up if x != nid]
        if up:
            op["promote"] = up
        kept = "\ncloses carried: %s" % ", ".join(carried) if carried and not new_closes else ""
        mine = [text, reason, done, not_doing, blocks, quote, where] + anchors   # every text of this op, for both checks
        texts, notes = ext_check("supersede", old["kind"], given, op, d, st, ops, mine)
        ended = charters_end(iid, d, mine + texts)  # a superseded focus ends too
        return op, mine + texts, "superseded %s with %s%s%s%s%s%s%s%s" % (
            iid, nid, placed, moved(up), kept, seen, anchor_warning(iid[0], anchors), notes_text(notes), ended), None
    return write(build, ops_too=True)


def why(e):
    """An error in a few words for a note line: its class, and `run brain doctor` when the log may be left past its head."""
    return e.__class__.__name__ + ("; run brain doctor" if "may be left past head.json" in str(e) else "")


def link_reason(anchors):
    """`<state> <anchor> <day>` per anchor, as many as fit the reason's cap, then `(+N more)`."""
    parts = ["%s %s %s" % (a["state"], a["anchor"], a["at"][:10]) for a in anchors]
    out = parts[0][:FIELD_MAX["reason"]]
    for i, p in enumerate(parts[1:], 1):
        rest = len(parts) - i - 1
        if len(out) + 2 + len(p) + (len(" (+%d more)" % rest) if rest else 0) > FIELD_MAX["reason"]:
            return out + " (+%d more)" % (len(parts) - i)
        out += "; " + p
    return out


def link_close(d, session, closes, how, wait=LOCK_WAIT):
    """Append one `link-close` per (item id, [anchor detail]) in `closes`, written as the writer `session` with `how` in its
    `by` ({"hook": "SessionStart"} or {"cmd": "close-linked"}), under the lock (waiting at most `wait` seconds). An item that
    is no longer live (closed or superseded after it was checked) is left alone; an item's `closes` never changes while it is
    live. An append that fails after some closes stops the run there. Returns (the state after, the ids closed, warnings or
    "": where it stopped first, then a cache warning)."""
    check_config()                                  # a config error stops every item write, a machine one too
    with locked(d, wait):
        raw, ops = verify(d)
        st = fold(ops)
        if not session or st["writer"] != session:
            raise Refused(3, "this session does not write this project's hot memory")
        done, err = [], None
        for iid, anchors in closes:
            it = st["items"].get(iid)
            if it is None or it["status"] != "live" or iid[0] not in CLOSES_LETTERS or not anchors:
                continue
            op = {"op": "link-close", "id": iid, "anchors": anchors, "reason": link_reason(anchors),
                  "pointer": anchors[0]["anchor"], "t": now_iso(), "by": dict(how, session=session)}
            up = moves_up(st, iid[0], len(live(st, iid[0])) - 1)
            if up:
                op["promote"] = up              # the room the close makes, in the same line
            try:
                check_text("reason", op["reason"])
                check_text("pointer", op["pointer"])
            except Refused:
                continue
            try:
                raw = append(d, raw, op)
            except OSError as e:                    # append cut the log back, or says it could not
                if not done:
                    raise
                err = e
                break
            apply(st, json.loads(raw[-1].decode("utf-8")))
            done.append(iid)
        warn = caches_after_append(d, st, raw) if done else ""
        if err is not None:
            warn = "\nwarning: stopped after %s (%s): the others stay live%s" % (", ".join(done), why(err), warn)
    return st, done, warn


def op_counter(iid, verb):
    def build(d, st):
        get_item(st, iid, OP_LETTERS)
        return {"op": verb, "id": iid}, [], "%s %s" % (verb, iid), None
    return write(build)


def op_words(iid, done, not_doing):
    """`brain op words P8 --done-when D --not-doing N`: a live focus's words, added in place (same id, no charter ends: a charter's
    digest of the focus's words is taken when it is signed and nothing rechecks it after). Only adds: a field already set goes through `supersede`."""
    if iid[:1] != "P":
        raise Refused(1, "words are for a focus: %s is not one" % iid)
    if done is None and not_doing is None:
        raise Refused(1, "words needs --done-when or --not-doing")
    check_focus_words("P", done, not_doing)

    def build(d, st):
        it = st["items"].get(iid)
        if it is None or it["status"] != "live":
            raise Refused(1, "%s is not a live focus" % iid)
        for key, label, v in (("done", "done when", done), ("not_doing", "not doing", not_doing)):
            if v is not None and it.get(key) is not None:
                raise Refused(1, "%s already has its %s; a change goes through `brain op supersede` (a new id)" % (iid, label))
        op = {"op": "words", "id": iid}
        op.update({k: v for k, v in (("done", done), ("not_doing", not_doing)) if v is not None})
        return op, [done, not_doing], "words %s: set %s" % (iid, ", ".join(
            l for l, v in (("done when", done), ("not doing", not_doing)) if v is not None)), None
    return write(build)


def op_link(iid, closes):
    """`brain op link X4 --closes owner/name#N`: `closes` anchors added to a live N, X, S, Q or R item in place (same id, no
    supersede, no retirement budget), checked as `add` checks them; an anchor the item already names is not added again, and the
    item keeps at most CLOSES_MAX."""
    named = closes_list(iid[:1], list(closes))
    if not named:
        raise Refused(64, "link needs --closes")

    def fresh(it):
        have = [c.lower() for c in it.get("closes") or []]
        out = [c for c in named if c.lower() not in have]
        if not out:
            raise Refused(1, "%s already closes with %s" % (iid, ", ".join(named)))
        if len(have) + len(out) > CLOSES_MAX:
            raise Refused(1, "%s already names %d closes; an item keeps at most %d" % (iid, len(have), CLOSES_MAX))
        return out

    it = peek(iid)["items"][iid]
    if it["status"] != "live":
        raise Refused(1, "%s is queued: link it once it is live" % iid)
    seen = closes_seen(fresh(it))                   # before the lock: the lookup may take its 2 seconds

    def build(d, st):
        it = get_live(st, iid, CLOSES_LETTERS)
        new = fresh(it)
        check_list("anchor", with_closes(it.get("anchors", []), new))
        return {"op": "link", "id": iid, "closes": new}, list(new), "linked %s: closes %s%s" % (
            iid, ", ".join(new), seen), None
    return write(build)


def op_evidence(rule, result, pointer, differed=None, session=None, via=None, extopts=None, as_pr=None, machine=False,
                proof=False):
    """`brain op held|broke RULE` and a trap's `brain op hit`: one `evidence` op. RULE is a live D, T or F item or a SOUL code;
    `session` a session item, recorded as the root of its chain, or else `as_pr` (`pr:owner/name#n`, brain op merge-evidence)
    stored as it is. A `machine` write (merge-evidence, from worker text) is refused (1) when the rule already has this result
    from this pointer (a hit is a held), and for a SOUL code not live (soul_codes), as is any write for one in a child of a
    parent SOUL, whose live codes are its file's. `proof` (merge-evidence's held from an answer the post-check accepted) is
    stored when given."""
    import brain_ledger as L
    kind, value = L.rule_arg(rule, hit=via == "hit")
    check_text("pointer", pointer, required=via != "hit")
    if result == "broke":
        check_text("differed", differed)
    verb = "hit" if via == "hit" else result
    given, _ = ext_options(verb, None, extopts, {})

    def build(d, st, ops):
        op = {"op": "evidence", "result": result, "soul" if kind == "soul" else "id": value}
        if kind == "id":
            L.check_rule_item(st, value, hit=via == "hit")
        op.update({k: v for k, v in (("pointer", pointer), ("differed", differed), ("via", via), ("proof", proof)) if v})
        if session is not None:
            op["session"] = L.check_session(st, session)
        elif as_pr:
            op["session"] = as_pr
        key = "[%s]" % value if kind == "soul" else value
        if kind == "soul" and (machine or L.parent_soul()) and value not in L.soul_codes(ops):   # a parent SOUL: its file's
            raise Refused(1, L.not_live(key))
        if machine and any(e["result"] == result and e["pointer"] == pointer
                           for e in (L.read(ops).get(key) or {}).get("events", [])):
            raise Refused(1, "%s has a %s from %s already" % (key, result, pointer))
        texts, notes = ext_check(verb, None, given, op, d, st, ops, [pointer, differed])
        led = L.read(ops + [dict(op, t=now_iso(), seq=len(ops) + 1, by=by())])   # the ledger with this entry, read once
        msg = "%s %s: %s" % ("hit" if via == "hit" else result, key, L.summary(led[key]["events"]))
        return op, [pointer, differed] + texts, msg + notes_text(notes), None
    return write(build, ops_too=True)


def op_progress(gid, measure, pointer, extopts=None):
    """`brain op progress G1 --measure M --pointer P`: a goal's progress measure, ledger data about the goal; the goal itself,
    the owner's, is not changed."""
    check_text("measure", measure)
    check_text("pointer", pointer)
    c = '"' if '"' in measure else quote_like(measure)
    if c:
        raise Refused(1, "measure holds U+%04X, a quote or a character that passes for one or reverses the line: the card shows "
                         "the measure in quotes before the goal's other parts, so it takes plain characters" % ord(c))
    given, _ = ext_options("progress", None, extopts, {})

    def build(d, st, ops):
        it = st["items"].get(gid)
        if it is None or gid[0] != "G" or it["status"] != "live":
            raise Refused(1, "progress is for a live goal: %s is not one" % gid)
        op = {"op": "progress", "id": gid, "measure": measure, "pointer": pointer}
        texts, notes = ext_check("progress", None, given, op, d, st, ops, [measure, pointer])
        return op, [measure, pointer] + texts, 'progress %s: "%s"%s' % (gid, measure, notes_text(notes)), None
    return write(build, ops_too=True)


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

GOAL_FIELDS = ("done", "not_doing", "review", "scope")     # a goal's own fields, after the text, the quote and the where
SCOPES = ("global", "project")
FIELDS_FOR = "--done, --not-doing and --review are for a goal, --scope for a goal or a decision"
# A window's scope: what vibemaestro-sdlc's baton runner may sign as coordinator-auto while the window is live, for the
# session that pinned it. The runner holds the same lists (baton.py WINDOW_*) and is what enforces them; here they refuse a scope
# the runner would never honour, before the dialog. A window with no --lower lowers nothing.
WINDOW_LOWERS = ("security-boundary", "publish", "no-way-back", "owner-acts", "recoverable-delete")
WINDOW_NEVER = ("secrets", "cluster-lane", "irreversible-delete", "history-rewrite", "money-org")
WINDOW_NEVER_BATONS = ("kit:bootstrap", "kit:coordinator-bootstrap", "kit:permissions-upgrade", "kit:plugin-install",
                       "kind:settings-merge")
WINDOW_LIFE_MAX = 24 * 3600
WINDOW_KIT = re.compile(r"kit:[a-z0-9][a-z0-9-]{0,63}\Z")     # baton.py KIT_RE and KEPT_NAME_MAX
WINDOW_WORDS_MAX = 8                                # each of --lower and --exclude: the dialog stays a phone's few lines
WINDOW_NEVER_SHOWN = "%s, a change to the machine's permissions or to who signs" % ", ".join(WINDOW_NEVER)
WINDOW_NEVER_WHY = "%s, %s, or a call naming a Claude Code settings file" % (", ".join(WINDOW_NEVER), ", ".join(WINDOW_NEVER_BATONS))


def window_scope_check(ns):
    """Refuse (1 or 64) a window's --lower and --exclude words the runner would never read, and a scoped window longer than a day."""
    lower, exclude = getattr(ns, "lower", None) or [], getattr(ns, "exclude", None) or []
    if not lower and not exclude:
        return
    if ns.kind != "window":
        raise Refused(64, "--lower and --exclude are for a window")
    if not lower:
        raise Refused(64, "--exclude narrows a window's --lower: a window with no --lower lowers nothing")
    for flag, words in (("--lower", lower), ("--exclude", exclude)):
        if len(set(words)) != len(words) or len(words) > WINDOW_WORDS_MAX:
            raise Refused(1, "%s names a word twice, or more than %d words" % (flag, WINDOW_WORDS_MAX))
        for w in words:
            if flag == "--lower" and (w in WINDOW_NEVER or w in WINDOW_NEVER_BATONS):
                raise Refused(1, "--lower %s: a window never lowers %s" % (w, WINDOW_NEVER_WHY))
            ok = w in WINDOW_LOWERS or WINDOW_KIT.match(w) or flag == "--exclude" and w in WINDOW_NEVER
            if not ok:
                raise Refused(1, "%s %s: a window names a stop category it may lower (%s) or a kit baton (kit:<name>)" % (
                    flag, printable(w), ", ".join(WINDOW_LOWERS)))
    ts = parse_iso(ns.expires or "")
    if ts is not None and ts > time.time() + WINDOW_LIFE_MAX:
        raise Refused(1, "a window with --lower lasts at most %d hours: --expires %s is later" % (WINDOW_LIFE_MAX // 3600, ns.expires))


def window_scope_line(item):
    """What a window's line says of its signing: its scope, or that it lowers none."""
    if not item.get("lowers"):
        return "lowers no signing"
    return "lowers signing for this session only: %s; never: %s%s" % (
        ", ".join(item["lowers"]), WINDOW_NEVER_SHOWN, "; excluded: " + ", ".join(item["excludes"]) if item.get("excludes") else "")
DECISION_KIND = "a lasting direction, never done"   # what a decision is, in the dialog after its id: from the kind, never the text


def owner_add_line(item):
    """An owner add's line of the dialog, from the item it writes: every field before the text, the text last."""
    letter, iid, w = item["id"][0], item["id"], (item.get("source") or {}).get("where")
    if letter == "G":
        return 'Pin owner goal %s (review %s, scope %s%s), from "%s", done when "%s", not doing "%s": "%s"' % (
            iid, item["review"], item["scope"], ", jira %s" % item["jira"] if item.get("jira") else "", w, item["done"],
            item["not_doing"], item["text"])
    if letter == "D":
        return 'Pin owner decision %s (%s)%s, from "%s": "%s"' % (iid, DECISION_KIND, " (scope %s)" % item["scope"]
                                                                 if item.get("scope") else "", w, item["text"])
    until = now_iso(parse_iso(item["expires"]))[5:16].replace("T", " ") + "Z"
    return 'Grant window %s until %s, from "%s", %s: "%s"' % (iid, until, w, window_scope_line(item), item["text"])


# --- the SOUL line of an owner step -----------------------------------------------------------------------------------------
# `--soul-line "[S14] text"` on the owner's SOUL step (promote, an extension's archive or pin): the step carries the line and
# the file (`soul_file`, by its real path), the dialog shows both, and once the step is written vibemaestro-sdlc's kit baton
# kit:soul-line adds the line to the file (or removes it, for a pin: the code back as a decision). The baton finds the step in
# this log itself and uses it once.

SOUL_LINE_RE = re.compile(r"\[(%s)\] (.+)" % SOUL_CODE.pattern)
SOUL_TEXT_MAX = 600
SOUL_RUN_SECONDS = 120


def soul_line_of(value, action):
    """{"code", "action", "text", "file", "sha"} of a `--soul-line` value, None without one; refused (1) for a value that is not
    `[S14] text` on one line (no quote, no other code, at most SOUL_TEXT_MAX characters) or with no `soul_file` set."""
    if value is None:
        return None
    m = SOUL_LINE_RE.fullmatch(value)
    text = m.group(2) if m else ""
    if (not m or text != text.strip() or len(text) > SOUL_TEXT_MAX or '"' in text or quote_like(text)
            or any(ord(c) < 32 or ord(c) == 127 for c in text) or re.search(r"\[%s\]" % SOUL_CODE.pattern, text)):
        raise Refused(1, '--soul-line is "[S14] its text": one line of at most %d characters, no quote, no control character and '
                         "no other SOUL code" % SOUL_TEXT_MAX)
    path = conf().get("soul_file")
    if not path:
        raise Refused(1, "--soul-line needs soul_file in %s: the file that holds the SOUL lines" % CONFIG_FILE)
    import brain_ledger as L
    if L.parent_soul():
        raise Refused(1, "soul_file %s is a parent SOUL, read-only here: only the brain of its directory changes its lines"
                      % printable(path))
    full = os.path.realpath(path if os.path.isabs(path) else os.path.join(config_root(), path))
    if printable(full) != full or quote_like(full):
        raise Refused(1, "soul_file resolves to a path with a character the dialog cannot show plainly: name it in plain "
                         "characters")
    return {"code": m.group(1), "action": action, "text": text, "file": full,
            "sha": hashlib.sha256(text.encode("utf-8")).hexdigest()}


def soul_line_for(ns):
    """The SOUL line an owner call carries ({code, action, text, file, sha}), resolved once per call and kept on `ns`, so the
    dialog and the digest bound to its record name the same file; None without --soul-line. A pin removes the line, a
    promote or an archive adds it."""
    if "_soul" not in vars(ns):
        value = getattr(ns, "soul_line", None)
        _, spec = ext_verb(ns.verb) if value is not None else (None, None)
        ns._soul = None if value is None else soul_line_of(value, "remove" if spec and spec["effect"] == "pin" else "add")
    return ns._soul


def soul_digest(sl):
    """What the owner's record binds of a SOUL line: its code, action, text and the resolved file, as the dialog showed them.
    A soul_file changed (or a link swapped) between the dialog and the write gives another digest, and the write is refused."""
    return hashlib.sha256(dumps({k: sl[k] for k in ("code", "action", "text", "file")}).encode("utf-8")).hexdigest()


def soul_suffix(sl):
    """The dialog's part for the SOUL line a step writes."""
    if not sl:
        return ""
    return '; then kit:soul-line %s the line "- [%s] %s" %s %s' % ("adds" if sl["action"] == "add" else "removes", sl["code"],
                                                               sl["text"], "to" if sl["action"] == "add" else "from",
                                                               printable(sl["file"]))


def pointer_code(pointer):
    codes = re.findall(r"\[(%s)\]" % SOUL_CODE.pattern, pointer or "")
    return codes[0] if len(codes) == 1 else None


def run_soul_line(sl):
    """Run kit:soul-line for the step just written; one line on what happened (the review card names a file and brain that
    still differ)."""
    tag = "[%s]" % sl["code"]
    baton = sdlc_file(os.path.join("scripts", "baton.py"))
    if not baton:
        return "the SOUL line %s was not written: vibemaestro-sdlc's baton.py was not found" % tag
    args = ["kit:soul-line", "--file", sl["file"], "--code", sl["code"], "--action", sl["action"], "--text", sl["text"]]
    try:
        r = subprocess.run([sys.executable, baton, "go"] + args, cwd=project_root(), capture_output=True, encoding="utf-8",
                           errors="replace", env=utf8_env(), timeout=SOUL_RUN_SECONDS)
        rc, last = r.returncode, ([l for l in (r.stdout + r.stderr).splitlines() if l.strip()] or [""])[-1]
    except (OSError, subprocess.SubprocessError) as e:
        rc, last = None, e.__class__.__name__
    with contextlib.suppress(Refused, OSError):
        episode_line(state_dir(), session_id(), "soul-line", code=sl["code"], action=sl["action"], rc=rc)
    if rc == 0:
        return "the SOUL line %s %s %s (kit:soul-line)" % (tag, "added to" if sl["action"] == "add" else "removed from",
                                                           printable(sl["file"]))
    if rc not in (0, None) and WINDOWS and NO_FCNTL in r.stdout + r.stderr:
        return "the SOUL line %s was not written: %s; the rest of the brain works" % (tag, BATON_WINDOWS % "writes it")
    if rc == 8:
        return ("the SOUL line %s waits for a signature (this machine's baton mode): the session runs `baton go %s` alone in "
                "a Bash call" % (tag, " ".join(shlex.quote(a) for a in args)))
    return "the SOUL line %s was not written (kit:soul-line %s: %s); the review card names the difference" % (
        tag, "rc %s" % rc if rc is not None else "did not run", printable(last)[:200])


def owner_line(ns, st, ops=(), d=None, session=None):
    """The one line of the dialog. Every field the session wrote is quoted, the source (or pointer) before the text, and the
    store refuses `"` in them, so no field can end its quotes and imitate another (round 4: a label blocklist could not keep
    up with look-alike letters and colons). An item's stored text is shown escaped (`escaped`): a lesson's or a fact's text,
    which the session wrote, may hold a `"` or a backslash. An extension's verb gets brain's own line for the write it is,
    with the extension's detail inside (brain_ext.dialog). A batch shows this line for each of its items."""
    if ns.verb == "add":
        letter = KINDS[ns.kind]
        check_cap(st, letter)                       # at a left cap: refused here, so the owner never approves a refused write
        item = {"id": next_id(st, letter), "text": ns.text, "source": {"where": ns.where}, "expires": ns.expires,
                "review": ns.review, "scope": ns.scope, "done": ns.done, "not_doing": ns.not_doing,
                "jira": getattr(ns, "jira", None), "lowers": getattr(ns, "lower", None), "excludes": getattr(ns, "exclude", None)}
        return owner_add_line(item)
    if ns.verb not in ("unpin", "supersede", "promote"):
        import brain_ext
        return brain_ext.dialog(ns, d, st, list(ops), session)
    it = get_live(st, ns.id, OWNER_LETTERS)
    noun = {"G": "goal", "D": "decision", "W": "window"}[ns.id[0]]
    text = escaped(it["text"])
    if ns.verb == "unpin":
        return 'Unpin owner %s %s: "%s"' % (noun, ns.id, text)
    if ns.verb == "supersede" and ns.id[0] == "G":     # each field it changes, before the text; the others carry over
        days = ", ".join("%s %s" % (k, getattr(ns, k)) for k in ("review", "scope") if getattr(ns, k, None) is not None)
        fields = "".join(', %s "%s"' % (label, getattr(ns, k)) for k, label in (("done", "done when"),
                                                                                ("not_doing", "not doing"))
                         if getattr(ns, k, None) is not None)
        if ns.text is None:                         # the text and the owner's words are carried
            return 'Change owner goal %s%s%s, its words unchanged: "%s"' % (ns.id, " (%s)" % days if days else "", fields, text)
        return 'Replace owner goal %s%s%s%s with: "%s"' % (ns.id, " (%s)" % days if days else "", fields,
                                                          "," if fields else "", ns.text)
    if ns.verb == "supersede" and ns.text is None:  # a decision's scope, its text and the owner's words carried
        return 'Set the scope of owner decision %s (%s) to %s, its words unchanged: "%s"' % (ns.id, DECISION_KIND, ns.scope, text)
    if ns.verb == "supersede":
        return 'Replace %s%s%s with: "%s"' % (ns.id, " (%s)" % DECISION_KIND if ns.id[0] == "D" else "",
                                              " (scope %s)" % ns.scope if getattr(ns, "scope", None) else "", ns.text)
    return 'Promote owner %s %s to "%s": "%s"%s' % (noun, ns.id, ns.pointer, text, soul_suffix(soul_line_for(ns)))

def owner_op(st, ops, verb, ns, confirm):
    """(op, texts for the filter, message) of one of brain's own owner items (add, unpin, promote, supersede) against `st`; an
    extension's verb is ext_owner's."""
    if verb == "add":
        letter = KINDS[ns.kind]
        warn = check_cap(st, letter)
        iid = next_id(st, letter)
        item = {"id": iid, "kind": ns.kind, "pinned": letter == "D", "text": ns.text,
                "source": {"type": "owner", "quote": ns.owner_quote, "where": ns.where},
                "expires": ns.expires, "links": ns.link, "anchors": ns.anchor, "supersedes": None}
        if letter == "G":
            item.update({k: getattr(ns, k) for k in GOAL_FIELDS})
            if getattr(ns, "jira", None) is not None:
                item["jira"] = ns.jira
        elif letter == "D" and getattr(ns, "scope", None):
            item["scope"] = ns.scope
        elif letter == "W" and getattr(ns, "lower", None):    # the session the runner lowers signing for, and only that one
            item.update({"lowers": list(ns.lower), "excludes": list(ns.exclude or []), "session": session_id()})
        texts = [ns.text, ns.owner_quote, ns.where, getattr(ns, "done", None), getattr(ns, "not_doing", None)]
        return {"op": "owner-add", "item": item, "confirm": confirm}, texts + ns.link + ns.anchor, "pinned %s%s%s" % (
            iid, "\n" + warn if warn else "", anchor_warning(letter, ns.anchor))
    old = get_live(st, ns.id, OWNER_LETTERS)
    if verb == "unpin":
        return {"op": "owner-unpin", "id": ns.id, "confirm": confirm}, [], "unpinned %s" % ns.id
    if verb == "promote":
        op = {"op": "owner-promote", "id": ns.id, "pointer": ns.pointer, "confirm": confirm}
        sl = soul_line_of(getattr(ns, "soul_line", None), "add")
        if sl:
            op["soul_line"] = sl
        return op, [ns.pointer] + ([sl["text"]] if sl else []), "promoted %s to %s" % (ns.id, ns.pointer)
    nid = next_id(st, ns.id[0])
    item = {"id": nid, "kind": old["kind"], "pinned": old.get("pinned", False), "text": old["text"] if ns.text is None
            else ns.text, "source": {"type": "owner", "quote": None, "where": "supersedes %s" % ns.id},
            "expires": old.get("expires"), "links": old.get("links", []), "anchors": old.get("anchors", []),
            "supersedes": ns.id}
    if ns.id[0] == "G" or ns.text is None:          # a goal's words go over byte for byte, and so does an unchanged text's
        item["source"] = dict(old["source"])
    if ns.id[0] == "G":                             # each field of a goal not given is carried
        item.update({k: getattr(ns, k, None) or old.get(k) for k in GOAL_FIELDS})
        if old.get("jira"):                         # a goal's Jira key goes over
            item["jira"] = old["jira"]
    elif ns.id[0] == "D" and (getattr(ns, "scope", None) or old.get("scope")):
        item["scope"] = getattr(ns, "scope", None) or old["scope"]
    if isinstance(old.get("import"), dict):         # where an imported item came from goes with it
        item["import"] = old["import"]
    if old.get("ext"):                              # every extension's entry goes over
        item["ext"] = dict(old["ext"])
    texts = [ns.text, getattr(ns, "done", None), getattr(ns, "not_doing", None)]
    return ({"op": "owner-supersede", "id": ns.id, "item": item, "reason": "superseded by the owner", "confirm": confirm},
            texts, "superseded %s with %s%s" % (ns.id, nid, anchor_warning(ns.id[0], item["anchors"])))

def stored_lines(item):
    """The item an owner write stored, a `field: value` line each (id, kind, text, the owner's words, a window's expiry): the
    result lands in the model's context the moment the dialog returns, the only place a mid-session pin reaches it."""
    quote = (item.get("source") or {}).get("quote")
    rows = [("id", item["id"]), ("kind", item["kind"]), ("text", item["text"]), ("quote", quote)]
    rows += [("expires", item.get("expires"))] if item["kind"] == "window" else []
    return "\n".join("%s: %s" % r for r in rows if r[1] is not None)


def ext_verb(verb):
    """The extension that adds the owner verb `verb`, and its spec; (None, None) for brain's own verbs."""
    if verb in ("add", "unpin", "supersede", "promote", "import", "backup", "batch") or not extensions():
        return None, None
    import brain_ext
    return brain_ext.owner_verb(verb)


def owner(args, verb, ns):
    """`brain owner <verb> …`: `args` is the argv after `owner`, matched item by item against an "asked" record."""

    def build(d, st, ops):
        rec, path = find_record(d, args, st)
        if rec is None:
            raise Refused(6, NO_DIALOG + " (no fresh, matching, unused record of an approved dialog in this session)")
        ans = answerers()
        if ans:
            raise Refused(6, "owner items are refused while something can answer the permission prompt in place of a human: "
                             + "; ".join(ans))
        confirm = {"asked": True, "mode": rec["mode"], "record": rec["id"]}
        after = lambda: os.path.exists(path) and os.unlink(path)
        if ext is not None:                         # an extension's verb: one of brain's own two owner writes
            out = ext_owner(ns, d, st, ops, confirm, after)
        else:
            op, texts, msg = owner_op(st, ops, verb, ns, confirm)
            out = op, texts, msg, after
        if out[0]["op"] == "ext" and rec.get("plan") != ext_digest(out[0]["ext"], out[0]["what"], out[0]["data"]):
            raise Refused(6, "%s's op is not the one the dialog showed: nothing written; ask the owner again" % out[0]["ext"])
        sl = out[0].get("soul_line")
        if sl and rec.get("plan") != soul_digest(sl):
            raise Refused(6, "the SOUL line's text or file (soul_file %s) is not the one the dialog showed: nothing written; "
                             "ask the owner again" % printable(sl["file"]))
        written["soul_line"] = sl
        written["item"] = out[0].get("item")
        return out

    if verb == "batch":
        return owner_batch(args, ns)
    if verb in ("import", "backup"):                # brain_transfer: never imported on a hook's path but guard-owner's for these
        import brain_transfer
        return (brain_transfer.owner_import if verb == "import" else brain_transfer.owner_backup)(args, ns)
    ext, _ = ext_verb(verb)
    owner_check(verb, ns)
    written = {}
    msg = write(build, ops_too=True)
    if written.get("soul_line"):                    # the step is in the log: the baton carries it out, outside the lock
        msg += "\n" + run_soul_line(written["soul_line"])
    if written.get("item"):                         # last, so no line it had moves; unpin and promote store no text
        msg += "\n" + stored_lines(written["item"])
    return msg


def ext_digest(name, what, data):
    """What the owner's record binds of an extension's owner op: the op the dialog showed, which the write must equal."""
    return digest(dumps({"ext": name, "what": what, "data": data}))


def ext_owner(ns, d, st, ops, confirm, after):
    """An extension's owner verb, once the record matched: brain's checks, then the extension's (its refusal, or its data),
    then brain's own write. `pin` pins a decision as `brain owner add --kind decision` does; `archive` moves a live item of the
    verb's letters out to the pointer, as `brain owner promote` does, a lesson or a fact making room for its queue; `op` writes
    the extension's own op (`ext`, its `what` the verb) with the data it answered, the one the dialog showed."""
    import brain_ext
    import brain_ledger as L
    _, spec = brain_ext.owner_verb(ns.verb)
    if spec["effect"] == "op":
        e, spec, data = brain_ext.owner_write(ns, d, st, ops)
        op = {"op": "ext", "ext": e["name"], "what": ns.verb, "data": data, "confirm": confirm}
        return (op, [getattr(ns, "ext_arg_" + a) for a in spec["args"]] + brain_ext.strings(data),
                "wrote %s's op %s" % (e["name"], ns.verb), after)
    if spec["effect"] == "pin":
        warn = check_cap(st, "D")
        iid = next_id(st, "D")
    else:
        get_live(st, ns.id, spec["letters"])
    e, spec, data = brain_ext.owner_write(ns, d, st, ops)
    gone = data.get("demoted_from") if spec["effect"] == "pin" and isinstance(data, dict) else None
    if isinstance(gone, str) and gone in L.parent_codes():
        raise Refused(1, "[%s] is a code of the parent SOUL file %s, read-only here: only the brain of its directory demotes it"
                      % (gone, clean_line(conf().get("soul_file"))))
    ext = {e["name"]: data} if isinstance(data, dict) else {}
    texts = brain_ext.strings(data) if ext else []
    sl = soul_line_of(getattr(ns, "soul_line", None), "remove" if spec["effect"] == "pin" else "add")
    if sl:                                          # the code the step moves: the extension's, or the pointer's
        named = (data or {}).get("demoted_from" if sl["action"] == "remove" else "soul") or (
            pointer_code(ns.pointer) if sl["action"] == "add" else None)
        if named != sl["code"]:
            raise Refused(1, "--soul-line names [%s], but this step %s %s" % (
                sl["code"], "demotes" if sl["action"] == "remove" else "promotes to",
                "[%s]" % named if isinstance(named, str) else "no SOUL code"))
        texts.append(sl["text"])
    if spec["effect"] == "pin":
        item = {"id": iid, "kind": "decision", "pinned": True, "text": ns.text,
                "source": {"type": "owner", "quote": ns.owner_quote, "where": ns.where},
                "expires": None, "links": ns.link, "anchors": ns.anchor, "supersedes": None}
        if ext:
            item["ext"] = ext
        args = [getattr(ns, "ext_arg_" + a) for a in spec["args"]]
        return (dict({"op": "owner-add", "item": item, "confirm": confirm}, **({"soul_line": sl} if sl else {})),
                [ns.text, ns.owner_quote, ns.where] + args + ns.link + ns.anchor + texts,
                "pinned %s (%s %s)%s%s" % (iid, e["name"], ns.verb, "\n" + warn if warn else "", anchor_warning("D", ns.anchor)),
                after)
    op = {"op": "owner-promote", "id": ns.id, "pointer": ns.pointer, "confirm": confirm}
    if ext:
        op["ext"] = ext
    if sl:
        op["soul_line"] = sl
    letter = ns.id[0]
    up = moves_up(st, letter, len(live(st, letter)) - 1) if letter not in LEFT_LETTERS else []
    if up:                                          # a lesson or a fact leaves a right-brain section: room for its queue
        op["promote"] = up
    return op, [ns.pointer] + texts, "promoted %s to %s (%s %s)%s" % (ns.id, ns.pointer, e["name"], ns.verb, moved(up)), after


def owner_check(verb, ns):
    """The field checks of `brain owner <verb>`, before any state is read; guard-owner runs the same ones before it asks."""
    get = lambda k: getattr(ns, k, None)
    _, spec = ext_verb(verb)
    args = [("arg", get("ext_arg_" + a)) for a in spec["args"]] if spec else []
    for field, value in [("text", get("text")), ("where", get("where")), ("pointer", get("pointer")), ("done", get("done")),
                         ("not-doing", get("not_doing"))] + args:
        if value and '"' in value:
            raise Refused(1, "%s holds a double quote: the dialog quotes each field, so a quote inside one could end it and "
                             "imitate another (write it without one)" % field)
        c = quote_like(value) if value and field != "text" else None
        if c:
            raise Refused(1, "%s holds U+%04X, which can pass for the dialog's quote or reverse the line; the source, "
                             "pointer, done and not-doing fields come before the text, so they take plain characters"
                          % (field, ord(c)))
    given = [k for k in GOAL_FIELDS if get(k) is not None]
    if verb == "add":
        if ns.kind not in ("goal", "decision", "window"):
            raise Refused(64, "brain owner add --kind goal|decision|window")
        if ns.kind == "goal" and len(given) < len(GOAL_FIELDS):
            raise Refused(64, "a goal needs --done D, --not-doing N, --review YYYY-MM-DD and --scope global|project")
        if ns.kind != "goal" and [k for k in given if k != "scope" or ns.kind != "decision"]:
            raise Refused(64, FIELDS_FOR)
        check_jira(getattr(ns, "jira", None), ns.kind == "goal", "a goal")
        check_text("text", ns.text, cap=text_max(KINDS[ns.kind]))
        check_text("quote", ns.owner_quote, cap=quote_max())
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
        window_scope_check(ns)
    elif verb == "supersede":
        if [k for k in given if ns.id[:1] != "G" and (k != "scope" or ns.id[:1] != "D")]:
            raise Refused(64, FIELDS_FOR)
        if ns.text is None and not given:
            raise Refused(64, "brain owner supersede ID needs --text T, or a field to change (a goal's, or a decision's "
                              "--scope): without --text the text and the owner's words are carried unchanged")
        if ns.text is not None:
            check_text("text", ns.text, cap=text_max(ns.id[:1]))
    elif verb == "promote" or spec and spec["effect"] == "archive":
        check_text("pointer", ns.pointer)
        sl = soul_line_of(get("soul_line"), "add")
        if sl and verb == "promote" and pointer_code(ns.pointer) != sl["code"]:
            raise Refused(1, "--soul-line names [%s]: the pointer names that one code, like \"CLAUDE.md [%s]\"" % (sl["code"],
                                                                                                             sl["code"]))
    elif spec and spec["effect"] == "op":          # an extension's op: only its own values
        for field, value in args:
            check_text(field, value)
    elif spec:                                      # an extension's pin: a decision's fields, and its own values
        soul_line_of(get("soul_line"), "remove")
        for field, value in args:
            check_text(field, value)
        check_text("text", ns.text, cap=text_max("D"))
        check_text("quote", ns.owner_quote, cap=quote_max())
        check_text("where", ns.where)
        check_list("link", ns.link)
        check_list("anchor", ns.anchor)
    goal_check(ns)


# --- brain owner batch FILE ----------------------------------------------------------------------------------------------------
# Several owner items through one dialog (one goal, one dialog, one turn on a phone). The file is read once, as
# bytes; the dialog shows a line per item, each its single form's line against the state the earlier items leave; the record
# binds the SHA-256 of those bytes and that text, so an edit the dialog does not show (a quote, an anchor), a swapped file, items
# reordered or the brain changed since are refused (6). Every item passes its single form's checks; all are written, or none.

BATCH_MIN, BATCH_MAX = 2, 5
BATCH_BYTES = 65536
BATCH_VERBS = ("add", "supersede", "unpin")
BATCH_DIALOG_MAX = 20000                            # UTF-16 units, as an owner import's dialog


def batch_read(path):
    """(the file's bytes, [(verb, ns, argv)]) of a batch file: a regular file (not a symlink, a FIFO or a device), at most
    BATCH_BYTES, holding a JSON array of BATCH_MIN to BATCH_MAX owner argv lists of BATCH_VERBS, each passing the single form's
    grammar and field checks. Refused (1) otherwise, naming the item."""
    import errno
    if not os.path.isabs(path):
        working_dir()                               # a relative name in a deleted directory: say that, not "cannot be read"
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0) | O_BINARY)
    except OSError as e:
        if e.errno == errno.ELOOP:
            raise Refused(1, "the batch file %s is a symlink: write the file itself" % printable(path))
        raise Refused(1, "the batch file %s cannot be read (%s)" % (printable(path), why(e)))
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise Refused(1, "the batch file %s is not a regular file" % printable(path))
        chunks, size = [], 0
        while size <= BATCH_BYTES:
            b = os.read(fd, BATCH_BYTES + 1 - size)
            if not b:
                break
            chunks.append(b)
            size += len(b)
    finally:
        os.close(fd)
    data = b"".join(chunks)
    if len(data) > BATCH_BYTES:
        raise Refused(1, "the batch file is over %d bytes" % BATCH_BYTES)
    try:
        items = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, ValueError, RecursionError):
        raise Refused(1, "the batch file is not JSON in UTF-8: write an array of owner argv lists")
    if not isinstance(items, list) or not all(isinstance(a, list) and a and all(isinstance(x, str) for x in a) for a in items):
        raise Refused(1, "the batch file must hold an array of owner argv lists, like [[\"unpin\", \"D3\"], …]")
    if not BATCH_MIN <= len(items) <= BATCH_MAX:
        raise Refused(1, "a batch holds %d to %d owner items, not %d (one item has its own dialog)"
                      % (BATCH_MIN, BATCH_MAX, len(items)))
    import brain
    import io
    out = []
    for k, argv in enumerate(items, 1):
        if argv[0] not in BATCH_VERBS:
            raise Refused(1, "item %d: a batch takes add, supersede and unpin, not %s" % (k, printable(argv[0])[:20]))
        err = io.StringIO()
        try:
            brain.owner_grammar(argv)
            with contextlib.redirect_stderr(err), contextlib.redirect_stdout(err):
                ns = brain.parser().parse_args(["owner"] + brain.owner_argv(argv))
            owner_check(ns.verb, ns)
        except SystemExit:
            msg = [l for l in err.getvalue().splitlines() if l.startswith("brain: ")]
            raise Refused(1, "item %d: %s" % (k, msg[-1][len("brain: "):] if msg else "brain owner: usage"))
        except Refused as e:
            raise Refused(e.rc if e.rc != 64 else 1, "item %d: %s" % (k, e.msg))
        out.append((ns.verb, ns, argv))
    return data, out


def batch_plan(st, ops, items, confirm):
    """(dialog text, [(op, texts, message)]): each item's single-form line and op against the state the earlier ones leave
    (a copy: `st` is not changed). Refused, naming the item, when one would be."""
    import copy
    st = copy.deepcopy(st)
    lines, built, seq, t = [], [], st["version"], now_iso()
    for k, (verb, ns, _) in enumerate(items, 1):
        try:
            line = owner_line(ns, st, ops)
            op, texts, msg = owner_op(st, ops, verb, ns, confirm)
        except Refused as e:
            raise Refused(e.rc, "item %d: %s" % (k, e.msg))
        lines.append("%d. %s" % (k, line))
        built.append((op, texts, msg))
        seq += 1
        apply(st, dict(op, t=t, by=by(), seq=seq))
    return "Owner batch of %d, one approval for all:\n%s" % (len(items), "\n".join(lines)), built


def batch_digest(data, text):
    return hashlib.sha256(data + b"\0" + text.encode("utf-8")).hexdigest()


def owner_batch_ask(d, path, st, ops):
    """(dialog text, its digest) that guard-owner asks with for `brain owner batch FILE`; Refused when the CLI would refuse the
    file, an item or a text (the sensitive-value filter runs first), so the owner never approves a refused batch."""
    data, items = batch_read(path)
    text, built = batch_plan(st, ops, items, {})
    if units(text) > BATCH_DIALOG_MAX:
        raise Refused(1, "the dialog would be %d units, past the %d of one dialog: fewer items" % (units(text), BATCH_DIALOG_MAX))
    sanitize(next((x for x in (d, state_root()) if x and os.path.isdir(x)), os.sep), [x for _, texts, _ in built for x in texts])
    return text, batch_digest(data, text)


def owner_batch(args, ns):
    """`brain owner batch FILE`: every item of the file, with a fresh record of the one dialog that listed them, whose digest
    the file's bytes (read once, here) and this state must give again; all written under one lock, or none."""
    check_caller()
    check_config()
    data, items = batch_read(ns.file)
    d = state_dir()
    with locked(d):
        raw, ops = verify(d)
        st = fold(ops)
        check_writer(st)
        rec, path = find_record(d, args, st)
        if rec is None:
            raise Refused(6, NO_DIALOG + " (no fresh, matching, unused record of an approved dialog in this session)")
        ans = answerers()
        if ans:
            raise Refused(6, "owner items are refused while something can answer the permission prompt in place of a human: "
                             + "; ".join(ans))
        test_pause()
        text, built = batch_plan(st, ops, items, {"asked": True, "mode": rec["mode"], "record": rec["id"]})
        if rec.get("plan") != batch_digest(data, text):
            raise Refused(6, "the batch file or this brain changed since the owner's dialog, or the dialog was not for this "
                             "batch: nothing was written; ask the owner again")
        sanitize(d, [x for _, texts, _ in built for x in texts])
        t = now_iso()
        claim = [{"op": "claim", "t": t, "by": by(), "takeover": False}] if st["writer"] is None else []
        n = len(raw)
        try:                                        # every line, the claim's too, in one write, or none
            raw = append_many(d, raw, claim + [dict(op, t=t, by=by()) for op, _, _ in built])
        except OSError as e:
            if "may be left past head.json" in str(e):      # append_many could not cut the log back: say so, as an import does
                raise Refused(1, "the batch could not be written, and the log may be left past head.json (%s): run brain doctor"
                              % e.__class__.__name__)
            raise Refused(1, "the batch could not be written (%s): nothing was written; the dialog's record is still usable"
                          % why(e))
        for line in raw[n:]:
            apply(st, json.loads(line.decode("utf-8")))
        done = [msg for _, _, msg in built]
        warn = caches_after_append(d, st, raw)
        with contextlib.suppress(OSError):
            os.unlink(path)
    return "; ".join(done) + warn + "".join("\n" + stored_lines(op["item"]) for op, _, _ in built if "item" in op)


def goal_check(ns):
    """A goal's fields as given: done and not-doing ≤ 200 units, a review day of the calendar that is not in the past, a scope
    of `global` (valid in every project) or `project`."""
    for field, key in (("done", "done"), ("not-doing", "not_doing")):
        if getattr(ns, key, None) is not None:
            check_text(field, getattr(ns, key))
    review, scope = getattr(ns, "review", None), getattr(ns, "scope", None)
    if review is not None:
        if parse_day(review) is None:
            raise Refused(64, "--review must be a day like 2026-12-31")
        if days_to(review, None) < 0:
            raise Refused(1, "--review %s is in the past: a goal's review day is today or later" % review)
    if scope is not None and scope not in SCOPES:
        raise Refused(64, "--scope must be global or project")


def show(iid, as_json=False):
    """`brain show ID`: every stored field of one item, live, queued or retired, one `field: value` line each; the owner's words
    whole, as stored (the render cuts a quote line for room, this never does). `--json`: the stored item as one JSON object."""
    d = state_dir()
    if not os.path.isdir(d):
        raise Refused(1, "no brain state for this project yet")
    with locked(d):
        _, st = load(d)
    it = st["items"].get(iid)
    if it is None:
        raise Refused(1, "%s is not an item of this brain" % iid)
    if as_json:
        return dumps(dict(it, id=iid))
    val = lambda v: v if isinstance(v, str) else dumps(v)
    src = it.get("source") if isinstance(it.get("source"), dict) else {}
    first = ("id", "kind", "status", "text")
    lines = ["%s: %s" % (k, val(it.get(k))) for k in first]
    lines += ["%s: %s" % (k, val(src[k])) for k in ("quote", "where") if src.get(k) is not None]
    lines += ["source: %s" % ("session" if src.get("type") == SESSION_SOURCE["type"] else val(src.get("type")))]
    if iid[0] == "P":
        lines.append("opened: %s" % ("by the session" if session_focus(it) else "in the owner's words"))
    lines += provenance_lines(it)
    if iid[0] == "D" and it.get("scope") is None:
        lines.append("scope: project (none stored)")
    lines += ["%s: %s" % (k, val(it[k])) for k in sorted(it) if k not in first + ("source", "import")]
    return "\n".join(lines)


def windows(as_json=False):
    """`brain windows`: the live windows, folded under the lock from the log once its whole chain is verified (rc 5 when it is
    broken), never from a cache (a cache's digest is no signature), with the newest time of any op (`last_t`): vibemaestro-sdlc's
    baton refuses to lower signing on a clock behind it. One line each without --json."""
    d = state_dir()
    if not os.path.isdir(d):
        raise Refused(1, "no brain state for this project yet")
    with locked(d):
        ops = verify(d)[1]
    st = fold(ops)
    ws = [dict(it, id=iid) for iid, it in sorted(st["items"].items()) if iid[0] == "W" and it["status"] == "live"]
    newest = max((t for t in (parse_iso(o.get("t")) for o in ops) if t is not None), default=None)
    if as_json:
        return dumps({"windows": ws, "last_t": now_iso(newest) if newest is not None else None})
    return "\n".join("%s until %s · %s: %s" % (w["id"], w.get("expires"), window_scope_line(w), clean_line(w["text"])) for w in ws
                     ) or "no live window"


def provenance_lines(it):
    """An imported item's `provenance:` line (the source project, its chain head, the old id) and, for a decision whose own
    quote is empty, the `words:` its chain held at the source; [] for an item written here."""
    p = it.get("import")
    if not isinstance(p, dict):
        return []
    head = str(p.get("head") or "")
    out = ["provenance: imported from %s (key %s) at head %s… (seq %s), was %s%s%s" % (
        p.get("from"), p.get("key"), head[:12], p.get("seq"), p.get("id"),
        "; a selection: its chain was not carried" if p.get("chain") == "selection" else "",
        "; this item superseded it here" if it.get("supersedes") else "")]
    w = p.get("words")
    if isinstance(w, dict):
        out.append('words: "%s" · %s (the owner\'s, on %s at the source)' % (w.get("quote"), w.get("where"), w.get("id")))
    return out


# --- backup, as the hooks read it ------------------------------------------------------------------------------------------
# The owner names a private place for backups (`brain owner backup DIR`, brain_transfer); it is kept in the state directory,
# never in the log. SessionStart and PreCompact read here whether one is due and start `brain backup --if-due` in the
# background; doctor and the review card read how backups keep up. Writing a bundle is brain_transfer's, which no hook
# imports.

def _isint(v):
    return isinstance(v, int) and not isinstance(v, bool)


BACKUP_FILE = "backup.json"
BACKUP_LAST = "backup-last.json"


def backup_conf(d):
    """{"dir", "every", "named"} of the place the owner named, None when none is."""
    c = _json_file(os.path.join(d, BACKUP_FILE))
    if (isinstance(c, dict) and isinstance(c.get("dir"), str) and os.path.isabs(c["dir"]) and _isint(c.get("every"))
            and 1 <= c["every"] <= 720):
        return c
    return None


def backup_last(d):
    """{"ok": the last backup written or None, "failed": the last failure since or None}."""
    c = _json_file(os.path.join(d, BACKUP_LAST))
    c = c if isinstance(c, dict) else {}
    return {k: c.get(k) if isinstance(c.get(k), dict) else None for k in ("ok", "failed")}


def backup_due(conf, last, head, now):
    """A backup is due: a place is named, the brain holds a line, and the last backup went to another place, or its head is
    not this one and it is at least the interval old (or there is none)."""
    ok = last["ok"]
    if not conf or not head or head.get("seq", 0) <= 0:
        return False
    if ok and ok.get("dir") != conf["dir"]:         # a place named since: it holds nothing of this brain yet
        return True
    if ok and ok.get("sha256") == head.get("sha256"):
        return False
    return not (ok and isinstance(ok.get("t"), (int, float)) and now - ok["t"] < conf["every"] * 3600)


def backup_overdue(conf, last, head, now):
    """Hours since the last backup (or since the place was named) when that is past twice the interval while the brain
    changed; None otherwise."""
    ok = last["ok"]
    if not conf or not head or head.get("seq", 0) <= 0:
        return None
    if ok and ok.get("dir") != conf["dir"]:         # a place named since: counted from when it was named
        ok = None
    if ok and ok.get("sha256") == head.get("sha256"):
        return None
    since = ok.get("t") if ok and isinstance(ok.get("t"), (int, float)) else parse_iso(conf.get("named") or "")
    if since is None or now - since <= 2 * conf["every"] * 3600:
        return None
    return int((now - since) // 3600)


def backup_kick(d, project):
    """From a hook: when a backup is due, start `brain backup --if-due` as a process of its own session in the project's
    directory, and never wait for it. Two small files are read when no backup is due; nothing at all when no place is named."""
    conf = backup_conf(d)
    if conf is None or not backup_due(conf, backup_last(d), read_head(d), time.time()):
        return False
    env = {k: v for k, v in os.environ.items() if k != "CLAUDE_CODE_SESSION_ID"}
    subprocess.Popen([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "brain.py"), "backup", "--if-due"],
                     cwd=project, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                     start_new_session=True, close_fds=True)
    return True


def backup_lines(d, now):
    """`brain doctor`'s view of the backups: [(level, text)]."""
    conf = backup_conf(d)
    if conf is None:
        return [("info", "backup: no place named; the owner names one through the dialog (brain owner backup DIR)")]
    last, head = backup_last(d), read_head(d)
    ok, failed = last["ok"], last["failed"]
    out = [("ok", "backup: to %s every %d h; last %s" % (conf["dir"], conf["every"], "%s (seq %s, %s)" % (
        now_iso(ok["t"]), ok.get("seq"), ok.get("file")) if ok and isinstance(ok.get("t"), (int, float)) else "none yet"))]
    if failed and isinstance(failed.get("t"), (int, float)):
        out.append(("warn", "the last backup failed at %s: %s" % (now_iso(failed["t"]), failed.get("error"))))
    late = backup_overdue(conf, last, head, now)
    if late is not None:
        out.append(("warn", "backups are overdue: %d h since the last (every %d h) while the brain changed" % (late, conf["every"])))
    return out


def backup_card(d, now):
    """The review card's backup line: a failing or overdue backup; None while backups keep up or none is named."""
    conf = backup_conf(d)
    if conf is None:
        return None
    last = backup_last(d)
    failed = last["failed"]
    if failed and isinstance(failed.get("t"), (int, float)):
        return cut_units("backup failing since %s: %s (brain doctor)" % (now_iso(failed["t"])[5:16].replace("T", " "),
                                                                          clean_line(failed.get("error") or "")), CARD_LINE)
    late = backup_overdue(conf, last, read_head(d), now)
    return "backup overdue: %d h since the last (every %d h; brain doctor)" % (late, conf["every"]) if late is not None else None


# --- doctor -------------------------------------------------------------------------------------------------------------------

def _version_tuple(s):
    m = re.search(r"(\d+)\.(\d+)\.(\d+)", s or "")
    return tuple(int(x) for x in m.groups()) if m else None


def session_format(d, sid):
    """The log format of `sid`'s last `session-start` or `session-format` episode line (none is 1), None when it has neither."""
    try:
        with open(os.path.join(d, "episodes.jsonl"), "rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - 262144))
            data = f.read()
    except OSError:
        return None
    for b in reversed(data.split(b"\n")):
        if sid.encode("utf-8", "replace") not in b:
            continue
        try:
            o = json.loads(b)
        except ValueError:
            continue
        if isinstance(o, dict) and o.get("session") == sid and o.get("kind") in ("session-start", "session-format"):
            n = o.get("format")
            return n if isinstance(n, int) and not isinstance(n, bool) else 1
    return None


def format_lines(d, now=None):
    """A `warn` per session whose last `session-start` or `session-format` episode line of the last 24 h has a log format below
    FORMAT (none is 1): that session runs an older brain, which refuses the log once it holds an op of a newer format. A
    session reloaded with /reload-plugins starts nothing, but its next `brain` command logs `session-format` (guard-owner)."""
    now = time.time() if now is None else now
    try:
        with open(os.path.join(d, "episodes.jsonl"), "rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - 262144))
            data = f.read()
    except OSError:
        return []
    last = {}                                       # session: its last start's format, or None once it ended
    for b in data.split(b"\n"):
        try:
            o = json.loads(b)
        except ValueError:
            continue
        kind = o.get("kind") if isinstance(o, dict) else None
        t = parse_iso(o.get("t") or "") if kind in ("session-start", "session-format", "session-end") else None
        if t is not None and 0 <= now - t < 86400 and isinstance(o.get("session"), str):
            if kind != "session-format" or o["session"] in last:     # a format line counts for a session started in the window
                last[o["session"]] = None if kind == "session-end" else ("start", o.get("format"))
    out = []
    for sid, v in sorted((k, v) for k, v in last.items() if v):
        n = v[1] if isinstance(v[1], int) and not isinstance(v[1], bool) else 1
        if n < FORMAT:
            out.append(("warn", "session %s… last started on an older brain (log format %d, this one writes %d): restart it on "
                                "this version (after /reload-plugins, any `brain` command in it clears this), since an older brain refuses to write to a log that holds a goal, focus, request, "
                                "session, queue or fact item, an item closed by a link, closes added later (link), a queued item, or a held, broke, "
                                "progress or demotion entry, an owner's SOUL code step or an extension's own op, and stops "
                                "injecting hot memory whenever it must read the log "
                                "again" % (sid[:8], n, FORMAT)))
    return out


def _caps_of(d):
    """The caps and lengths hot.md was rendered under, None when they are not known or not well formed."""
    try:
        with open(os.path.join(d, "hot.md.caps"), encoding="utf-8") as f:
            v = json.loads(f.read())
    except (OSError, UnicodeDecodeError, ValueError, RecursionError):
        return None
    ints = lambda m, key: isinstance(m, dict) and all(isinstance(k, str) and _int_in(x, key) for k, x in m.items())
    if (not isinstance(v, dict) or set(v) != set(CAPS_KEYS) or not ints(v["caps"], "caps") or not ints(v["text_caps"], "text_caps")
            or not _int_in(v["text_max"], "text_max") or not _int_in(v["quote_max"], "quote_max")):
        return None
    return v


def _rendered_then(md, st, then):
    """hot.md is exactly a render under the other caps and lengths it says it was rendered under: a config change, not an edit."""
    if not then or then == caps_values():
        return False
    with caps_as(then):
        return render_key(md, st) == render_key(render_all(st), st)


NEW_TITLES = (dict(SECTIONS)["G"], dict(SECTIONS)["P"], dict(SECTIONS)["R"])   # sections a brain of log format 4 did not render


def _older_tags(md, st, seq):
    """hot.md is the render of this very state by an older brain that tagged each session line with the goal it served (log
    format 6, before the tags left the kit): the same as a render made with those tags (`older_tags`), at the head's version.
    The tags take room on the line, so the render is made with them rather than the tags taken out of hot.md."""
    v = _MD_VERSION.match(md)
    if not v or int(v.group(1)) != seq:
        return False
    with older_tags():
        return render_key(md, st) == render_key(render_all(st), st)


def _older_layout(md, st, seq, then=None):
    """hot.md is the render of this very state by a brain of log format 4: the fresh render without the sections it did not
    have (the state holds no goal, focus or request, so they are empty titles), at the head's version, under the caps in force
    or under `then`, those it says it was rendered under (the config changed since)."""
    v = _MD_VERSION.match(md)
    if not v or int(v.group(1)) != seq or any(it["id"][0] in ("G", "P", "R") for it in st["items"].values()):
        return False
    for caps in [None] + ([then] if then and then != caps_values() else []):
        with caps_as(caps) if caps else contextlib.nullcontext():
            if render_key(md, st) == [l for l in render_key(render_all(st), st) if l not in NEW_TITLES]:
                return True
    return False


def _older_blocks(md, st, seq):
    """hot.md is the render of this very state, at the head's version, by an older brain that wrote no `  blocks:` line under
    a queue item (log format 8 before the owner queue named what it blocks)."""
    v = _MD_VERSION.match(md)
    if not v or int(v.group(1)) != seq or not any(isinstance(it.get("blocks"), str) for it in st["items"].values()):
        return False
    return render_key(md, st) == [l for l in render_key(render_all(st), st) if not l.startswith("  blocks: ")]


def _older_focus(md, st, seq):
    """hot.md is the render of this very state, at the head's version, by a brain before the focus rule (`older_focus`), when
    the state holds a focus the session opened or a running session tied to a focus."""
    v = _MD_VERSION.match(md)
    if not v or int(v.group(1)) != seq or not any(session_focus(it) or (it["id"][0] == "S" and it.get("focus"))
                                                  for it in st["items"].values()):
        return False
    with older_focus():
        return render_key(md, st) == render_key(render_all(st), st)


def _older_rules_render(md, st, seq):
    """hot.md is the render of this very state, at the head's version, by an older brain (`older_rules`)."""
    v = _MD_VERSION.match(md)
    if not v or int(v.group(1)) != seq:
        return False
    with older_rules():
        return render_key(md, st) == render_key(render_all(st), st)


def worst_case(now=None):
    """The strings SessionStart would need with every section of this store at its configured cap, every text at its cap with
    eight links, every quote of the owner's words at the quote cap, a goal's done and not-doing lines full, every request due
    soon, every Next item and running session tied to a focus, Done full: (strings, the most units in one)."""
    now = time.time() if now is None else now
    st, t = empty_state(), now_iso(now)
    soon = today(now + 86400 * 3).isoformat()
    for letter in CAPS:
        kind = [k for k, v in KINDS.items() if v == letter][0]
        for i in range(1, cap(letter) + 1):
            it = {"id": "%s%d" % (letter, i), "kind": kind, "text": "x" * text_max(letter), "links": ["l" * 80] * LIST_MAX,
                  "anchors": [], "status": "live", "created": t, "touched": i, "hits": 99,
                  "source": {"type": "owner", "quote": "q" * quote_max(), "where": "w" * 60},
                  "expires": now_iso(now + 86400 * 9) if letter == "W" else None}
            extra = {"G": {"done": "d" * 200, "not_doing": "n" * 200, "review": soon, "scope": "project"},
                     "D": {"scope": "global"}, "P": {"goal": "G1"}, "R": {"due": soon}, "X": {"focus": "P1"}, "S": {"focus": "P1"},
                     "Q": {"blocks": "b" * FIELD_MAX["blocks"]}}
            it.update(extra.get(letter, {}))
            st["items"][it["id"]] = it
    for i in range(1, DONE_SHOWN + 2):
        st["items"]["N%d" % (1000 + i)] = {"id": "N%d" % (1000 + i), "kind": "now", "text": "x" * text_max("N"),
                                            "status": "closed", "retired": t, "touched": 1000 + i, "created": t,
                                            "pointer": "p" * 80}
    st["version"] = 999999
    strings = render_strings(st, now)
    return len(strings), max(units(text) for _, text in strings)


def config_lines():
    """`brain doctor`'s view of the configuration: [(level, text)]."""
    c = conf()
    changed = ["%s %d" % (k, v) for k, v in sorted(c["caps"].items()) if v != DEFAULT_CAPS[k]]
    changed += ["text_max %d" % c["text_max"]] if c["text_max"] != TEXT_MAX else []
    changed += ["text_caps.%s %d" % (k, v) for k, v in sorted(c["text_caps"].items()) if TEXT_CAPS.get(k) != v]
    changed += ["quote_max %d" % c["quote_max"]] if c["quote_max"] != QUOTE_MAX else []
    changed += ["ledger.%s %d" % (k, v) for k, v in sorted(c["ledger"].items()) if v != LEDGER_DEFAULTS[k]]
    changed += ["untouched.%s %d" % (k, v) for k, v in sorted(c["untouched"].items()) if v != DEFAULT_UNTOUCHED[k]]
    out = [("ok", "config: %s" % ("%s: %s" % (CONFIG_FILE, ", ".join(changed) or "the defaults") if c["found"]
                                  else "no %s, the defaults" % CONFIG_FILE))]
    config_root()
    out += [("warn", n) for n in _ROOT[1]]
    out += [("problem", "%s %s: writes are refused, reads use the default" % (CONFIG_FILE, e)) for e in c["errors"]]
    out += [("warn", "%s: %s" % (CONFIG_FILE, w)) for w in c["warnings"]]
    out += [("warn", w) for w in left_cap_notes(c)]
    n, top = worst_case()
    if n > SLOTS:
        out.append(("warn", "the caps' worst case needs %d SessionStart strings, past the %d the plugin declares: the last "
                            "lines of a full brain would not be injected; lower a cap" % (n, SLOTS)))
    return out


def ext_doctor(d, st, ops):
    """Doctor's lines on the plugins that extend the brain (none, and no import, when no plugin ships the marker)."""
    if not extension_roots():
        return []
    import brain_ext
    return brain_ext.doctor_lines(d, st, ops)


def doctor():
    """[(level, text)] with level ok | warn | problem | info."""
    out = config_lines()
    out += path_lines()
    d = state_dir()
    if not os.path.isdir(d):
        out.append(("info", "no brain state for this project yet"))
        out += ext_doctor(None, None, None)
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
                key = render_key(md, st)
                v = _MD_VERSION.match(md)
                out.append(("ok", "hot.md matches a fresh render") if key == render_key(render_all(st), st) else
                           ("warn", "hot.md holds an older brain's render; `brain render` rewrites it, and so does the next "
                                    "write") if (md.startswith(OLDER_TITLE) and v and int(v.group(1)) == head["seq"]
                                                 or _older_layout(md, st, head["seq"], _caps_of(d))
                                                 or _older_tags(md, st, head["seq"])
                                                 or _older_rules_render(md, st, head["seq"])
                                                 or _older_blocks(md, st, head["seq"])
                                                 or _older_focus(md, st, head["seq"])) else
                           ("warn", "hot.md was rendered under other caps or lengths (%s changed); `brain render` rewrites "
                                    "it, and so does the next write" % CONFIG_FILE) if _rendered_then(md, st, _caps_of(d)) else
                           ("problem", "hot.md does not match a fresh render of the log: it was edited or is stale"))
            except (OSError, ValueError):
                out.append(("warn", "hot.md is missing or unreadable; `brain render` writes it"))
            waiting = ["%s %d" % c for c in queue_counts(st)]
            if waiting:
                out.append(("info", "overflow queue (not injected; `brain overflow` lists it): %s" % ", ".join(waiting)))
            out += [("info", "review card: %s" % l) for l in card_lines(st, time.time(), loss=last_loss(d), ops=ops, d=d)]
            out += ext_doctor(d, st, ops)
            done = done_items(st, time.time())
            out += [("info", "done (24 h), %d of %d: %s" % (i, len(done), done_line(it))) for i, it in enumerate(done, 1)]
            import brain_stale
            out += brain_stale.doctor_lines(st)
            out += format_lines(d)
            out += backup_lines(d, time.time())
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
            fd = os.open(os.path.join(d, "lock"), os.O_RDWR | os.O_CREAT | O_BINARY, 0o600)
            try:
                lock_nb(fd)
                out.append(("ok", "the lock is free"))
            except HELD:
                out.append(("warn", "the lock is held by another process right now"))
            finally:
                unlock(fd)
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
                elif open_to_others(os.path.join(root, n), st_):
                    loose.append(n + ("/" if n in dirs else ""))
        for p, label in ((d, "the state directory"), (state_root(), "the brain root")):
            if open_to_others(p, os.stat(p)):
                loose.append(label)
        if WINDOWS:
            out.append(("problem", "another account can use it, or a symlink: %s" % printable(", ".join(sorted(loose)))) if loose
                       else ("ok", "files and folders: this account's alone"))
        else:
            out.append(("problem", "group or other can read, or a symlink: %s" % printable(", ".join(sorted(loose)))) if loose
                       else ("ok", "file modes 0600 / 0700"))
    f = sdlc_filter()
    if not f:
        out.append(("problem", "vibemaestro-sdlc's sensitive-value filter was not found: every write is refused"))
    else:
        tok = "gh" + "p_" + "a1B2c3D4e5" * 3 + "a1B2c3"
        rc = [subprocess.run([sys.executable, f, "--text", "--cwd", d if os.path.isdir(d) else os.getcwd()], input=t,
                             capture_output=True, encoding="utf-8", env=utf8_env(), timeout=30).returncode for t in ("plain words", tok)]
        out.append(("ok", "the sensitive-value filter runs (clean 0, token 1)") if rc == [0, 1] else
                   ("problem", "the sensitive-value filter answers %s on clean text and a token, not 0 and 1" % rc))
    for a in answerers():
        out.append(("problem", "%s: owner items are refused while it is configured" % a))
    vt, tried = claude_version()
    if vt is None:
        out.append(("info", "Claude Code version unknown (tried: %s)" % ", ".join(tried)))
    elif vt < (2, 1, 211):
        out.append(("problem", "Claude Code %d.%d.%d is older than 2.1.211: auto mode may approve without the dialog, "
                               "so owner items need 2.1.211 or later" % vt))
    else:
        out.append(("ok", "Claude Code %d.%d.%d" % vt))
    for v in ("BRAIN_TEST", "BRAIN_TEST_PAUSE_MS"):
        if os.environ.get(v):
            out.append(("warn", "%s is set: it is for tests only" % v))
    return out
