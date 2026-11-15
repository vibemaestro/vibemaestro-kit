"""vibemaestro-brain stale anchors, auto-close and the sweep: a live Now (N), Next (X), session (S), queue (Q), request (R), trap
(T), fact (F) or pinned (D) item whose anchor names a closed issue or a merged or closed PR on GitHub is marked, a live N, X, S, Q
or R item whose declared `closes` anchors are all done closes itself, and a live right-brain item untouched past its kind's
threshold (`untouched` in .vibemaestro/brain.json) is marked; nothing closes for age. A queue item's `blocks` anchors are
checked as its own: once every one is closed, its blocked work is done. The marked right-brain items are the sweep's
candidates: one `sweep:` line in string 1, and `brain sweep` lists them with the characters each would free.

An anchor counts only as a whole string: `#N` (against the item's own repository: the one repository its `owner/name#N`
anchors, URLs and `closes` name, when they name exactly one; else it is not checked), `owner/name#N` (as written) or a GitHub
`https://github.com/<owner>/<name>/issues/<N>` or `/pull/<N>` URL. BRAIN_DEFAULT_REPO is no longer read: in a session across
several repositories it resolved an item's `#N` against the wrong one. Each one is one
`gh api repos/<o>/<r>/issues/<n> --hostname github.com` (the issues endpoint answers for a PR too: `pull_request.merged_at`, and
`state_reason` for an issue). A merged PR that would close an item is also looked up at `…/pulls/<n>`: it closes only when it was
merged into its repository's default branch.

    annotate(parts, st, d, sid, ops)  SessionStart: the three parts of the render (one string each) with ` · stale: #7 closed 2026-10-20`
                               after each stale item and note lines, each in the part that holds its item; answers come from a
                               cache (600 s; a failed lookup 120 s), the rest are looked up in parallel under one 2.0 s deadline, ≤ 12
                               anchors, least recently checked first; in the writer's SessionStart (`sid` is the last claim) an item
                               whose every `closes` anchor is done closes (the op `link-close`), at most 5 at once; no `gh`, no
                               network, any error: no close, no marks and one note line, never a failure
    doctor_lines(st)           `brain doctor`: fresh lookups (no cache read or write, 20 s, ≤ 40 anchors): a warn per stale anchor,
                               what would close, what closed in 24 h, reopened issues, pins for the owner; it writes nothing
    close_linked()             `brain op close-linked`: the same checks with fresh lookups under doctor's bounds, no cap of 5
    closes_form(a), closes_check(anchors)   `--closes`: the stored form of an anchor, and its write-time lookup
    bare_warning(anchors)      the line `brain op` and `brain owner` print after a write that leaves a bare `#N` its item cannot resolve
    sweep_cmd()                `brain sweep`: the candidates by reason, each with the characters it would free; fresh lookups
                               under doctor's bounds, nothing written

The only log write is `link-close`, by the store's writer, at its SessionStart or in `close-linked`; besides it this module writes
`stale-cache.json` (not part of the log). Standard library only, Python 3.8.
"""
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time

import brain_store as s

DEADLINE = 2.0              # seconds for all the lookups of one SessionStart, both rounds
DOCTOR_DEADLINE = 20.0
WRITE_DEADLINE = 2.0        # the write-time lookup of `--closes`
MAX_START = 12              # distinct anchors looked up per SessionStart (round 1)
MAX_PULLS = 5               # PRs looked up at the pulls endpoint per SessionStart (round 2), not counted in MAX_START
MAX_REOPEN = 3              # reopen checks per SessionStart, inside MAX_START
MAX_DOCTOR = 40
BURST_MAX = 5               # items one SessionStart may close; past it none closes (a burst is more likely a wrong repo or gh)
REOPEN_WINDOW = 86400       # seconds a link-close's issue anchors are checked for a reopen
DOCTOR_UNCHECKED = 20       # unchecked item/anchor lines in one `brain doctor`; the rest is one count line
TTL_ANSWER = 600            # seconds a cached answer is used
TTL_FAILURE = 120           # seconds a failed lookup is not tried again
CACHE_MAX = 200
CACHE_KEEP = 86400
CACHE_FILE = "stale-cache.json"
CACHE_V = 2
CACHE_BYTES = 262144        # 200 entries are about 40 KB: a larger file is not ours
MARKS_MAX = 450             # characters the marks, the summary and the note add to one string (test [S] holds the worst case)
NOTE_MAX = 250              # characters of one string's auto-close line (closed now, reopened, held)
PER_ITEM = 2                # anchors named in one item's mark
LETTERS = ("N", "X", "S", "Q", "R", "T", "F", "D")   # the order of the lookups
HOST = ["--hostname", "github.com"]
JQ = '[.state, .closed_at, (.pull_request.merged_at // ""), (.state_reason // ""), (if .pull_request then "pr" else "issue" end)] | @tsv'
JQ_TITLE = JQ.replace('] | @tsv', ', (.title // "")] | @tsv')
PULLS_JQ = '[.base.ref, .base.repo.default_branch, (.merged_at // ""), (.merge_commit_sha // "")] | @tsv'
REPO = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
ANCHOR = re.compile(r"(?:([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+))?#([1-9][0-9]{0,8})")
URL = re.compile(r"https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/(?:issues|pull)/([1-9][0-9]{0,8})")
DATE = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}")
STAMP = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")
REASON = re.compile(r"[a-z_]{0,20}")
REF = re.compile(r"[A-Za-z0-9._/-]{1,40}")
SHA = re.compile(r"[0-9a-f]{40}")
SHA12 = re.compile(r"[0-9a-f]{12}")
SET_IT = "write owner/name#N (a bare #N resolves only against the one repository its item's other anchors name)"
NOTHING = {"closed": [], "held": 0, "error": None, "noted": (), "stale": [], "sweep": ""}


# --- which anchors ------------------------------------------------------------------------------------------------------------

def ignored_default():
    """BRAIN_DEFAULT_REPO when it is set (no longer read: doctor says so), else None."""
    return os.environ.get("BRAIN_DEFAULT_REPO") or None


def own_repo(anchors):
    """The one repository the qualified anchors (`owner/name#N`, a URL) of `anchors` name, None when they name none or several:
    a bare `#N` of the same item resolves against it, since it cannot then be another repository's."""
    repos = set()
    for a in anchors:
        m = parse_anchor(a)
        if m and m[0] and repo_ok(m[0]):
            repos.add(m[0].lower())
    return repos.pop() if len(repos) == 1 else None


def repo_ok(r):
    """`owner/name` with no `.` or `..` segment (`..` as the owner would climb out of `repos/`)."""
    return REPO.fullmatch(r) is not None and not any(p in (".", "..") for p in r.split("/"))


def parse_anchor(a):
    """(repository or None, number) for `#n`, `owner/name#n` or a GitHub issue or PR URL, whole string; None for any other."""
    if not isinstance(a, str):
        return None
    m = ANCHOR.fullmatch(a)
    if m is None:
        m = URL.fullmatch(a)
    return (m.group(1), m.group(2)) if m else None


def label(a, key):
    """What a mark calls an anchor: as written, except a URL, which is long and shows as its `owner/name#n` key."""
    return a if ANCHOR.fullmatch(a) else key


BLOCKS_ANCHORS = 2           # anchors of a queue item's `blocks` looked up, as many as `closes` may name


def blocks_anchors(it):
    """The first BLOCKS_ANCHORS `owner/name#N` anchors and GitHub URLs a queue item's `blocks` names, in prose (quoted, in
    brackets, a link, a possessive); a bare `#N` there is a number, not an anchor."""
    words = re.split(r"[\s()\[\]<>\"'`]+", str(it.get("blocks") or "")) if it["id"][0] == "Q" else []
    out, keys = [], []
    for w in (x.strip(",;:.!?") for x in words):
        k = anchor_key(w)
        if k and k not in keys:                 # one issue or PR once, however it is spelled
            out.append(w)
            keys.append(k)
    return out[:BLOCKS_ANCHORS]


def anchor_key(a):
    """`owner/name#n` in lower case for an anchor that names a repository `candidates` would look up (as written, or a URL);
    None otherwise."""
    m = parse_anchor(a)
    return ("%s#%s" % m).lower() if m and m[0] and repo_ok(m[0]) else None


def candidates(st):
    """[(item id, anchor as written, key or None)] of the live items of LETTERS in lookup order; key is `owner/name#n` in lower
    case, None for a bare `#n` whose item names no single repository (`own_repo`). An anchor of any other shape is not listed."""
    out = []
    for letter in LETTERS:
        for it in sorted((i for i in st["items"].values() if i["id"][0] == letter and i["status"] == "live"),
                         key=lambda i: int(i["id"][1:])):
            anchors = list(it.get("anchors") or [])
            every = [c for c in it.get("closes") or [] if c not in anchors] + anchors
            default = own_repo(every)                   # a bare #N resolves against the item's own anchors, never its blocks
            every += [b for b in blocks_anchors(it) if b not in every]
            for a in every:
                m = parse_anchor(a)
                if not m:
                    continue
                repo = m[0] or default
                if repo and not repo_ok(repo):
                    continue
                out.append((it["id"], a, ("%s#%s" % (repo, m[1])).lower() if repo else None))
    return out


def distinct(cands, limit):
    keys = []
    for _, _, k in cands:
        if k and k not in keys:
            keys.append(k)
    return keys[:limit], len(keys)


def bare_skipped(cands):
    out = []
    for _, a, k in cands:
        if k is None and a not in out:
            out.append(a)
    return out


def unchecked(cands):
    """[(item id, anchor)] of the live items' anchors that have no repository to resolve against, each pair once, in lookup order."""
    out = []
    for iid, a, k in cands:
        if k is None and (iid, a) not in out:
            out.append((iid, a))
    return out


def bare_warning(anchors):
    """The warning a write prints when `anchors` (the item's, its `closes` among them) hold a bare `#N` and name no single
    repository to resolve it against, else ""."""
    if own_repo([a for a in anchors if isinstance(a, str)]):
        return ""
    bare = []
    for a in anchors:
        m = ANCHOR.fullmatch(a) if isinstance(a, str) else None
        if m and not m.group(1) and a not in bare:
            bare.append(a)
    if not bare:
        return ""
    return ("warning: %s %s not checked for staleness (the item names no single repository to resolve %s against); write %s (a "
            "GitHub issue or PR URL also works)" % (", ".join(bare), "is" if len(bare) == 1 else "are",
                                                    "it" if len(bare) == 1 else "them", ", ".join("owner/name" + a for a in bare)))


def closes_form(a):
    """The stored form of one `--closes` value: `owner/name#N`, as written or from an issue or PR URL. Refused (64) for a bare
    `#N` (a closes anchor names the item's repository: a bare one would close on another repository's number) and for any
    other string."""
    m = ANCHOR.fullmatch(a) if isinstance(a, str) else None
    if m and not m.group(1):
        raise s.Refused(64, "--closes %s: a bare #N is refused; write owner/name%s or the issue or PR URL"
                        % (s.printable(a), s.printable(a)))
    m = m or (URL.fullmatch(a) if isinstance(a, str) else None)
    if not m or not repo_ok(m.group(1)):
        raise s.Refused(64, "--closes %s: write owner/name#N or a GitHub issue or PR URL" % s.printable(str(a))[:100])
    return "%s#%s" % (m.group(1), m.group(2))


def linked_items(st):
    """[(item, [key])] of the live items of CLOSES_LETTERS with `closes`, each key `owner/name#n` in lower case; an item with a
    `closes` value that is not a qualified anchor never closes, so it is left out."""
    out = []
    for it in sorted(st["items"].values(), key=lambda i: (i["id"][0], int(i["id"][1:]))):
        if it["id"][0] not in s.CLOSES_LETTERS or it["status"] != "live":
            continue
        keys = []
        for c in it.get("closes") or []:
            m = parse_anchor(c)
            keys.append(("%s#%s" % m).lower() if m and m[0] and repo_ok(m[0]) else None)
        if keys and None not in keys:
            out.append((it, keys))
    return out


def reopen_keys(st, now):
    """{key: [(item id, anchor)]} of the issue anchors of the link-closes of the last REOPEN_WINDOW seconds."""
    out = {}
    for it in st["items"].values():
        ln = it.get("linked")
        t = s.parse_iso(ln.get("t") or "") if isinstance(ln, dict) else None
        if it["status"] != "closed" or t is None or not 0 <= now - t < REOPEN_WINDOW:
            continue
        for a in ln.get("anchors") or []:
            m = parse_anchor(a.get("anchor")) if isinstance(a, dict) and a.get("state") == "completed" else None
            if m and m[0] and repo_ok(m[0]):
                out.setdefault(("%s#%s" % m).lower(), []).append((it["id"], a["anchor"]))
    return out


# --- the lookups --------------------------------------------------------------------------------------------------------------

def api_argv(key, endpoint, jq):
    """`gh` argv (after `gh`) of one lookup of `owner/name#n` at `issues` or `pulls`, always on github.com."""
    repo, _, n = key.rpartition("#")
    return ["api", "repos/%s/%s/%s" % (repo, endpoint, n)] + HOST + ["--jq", jq]


def parse(out, title=False):
    """The issues answer {state, reason, at, date, pr} from the one --jq line, else None: only what matches is read. `state` is
    open, closed or merged; `at` is the full UTC stamp of the close or merge and `date` its day; with `title`, also `title`."""
    parts = out.rstrip("\n").split("\t")
    if len(parts) != (6 if title else 5):
        return None
    state, closed, merged, reason, kind = parts[:5]
    if kind not in ("pr", "issue") or REASON.fullmatch(reason) is None:
        return None
    r = {"state": state, "reason": reason, "at": "", "date": "", "pr": kind == "pr"}
    if title:
        r["title"] = parts[5]
    if state == "open":
        return r
    if state != "closed":
        return None
    if merged:
        return dict(r, state="merged", at=merged, date=merged[:10]) if r["pr"] and STAMP.fullmatch(merged) else None
    return dict(r, at=closed, date=closed[:10]) if STAMP.fullmatch(closed) else None


def parse_pulls(out):
    """{base_ok, sha} from the pulls endpoint's --jq line (`ref` too when the base is another branch), else None."""
    parts = out.rstrip("\n").split("\t")
    if len(parts) != 4:
        return None
    ref, default, merged, sha = parts
    if not ref or not default or not STAMP.fullmatch(merged) or not SHA.fullmatch(sha):
        return None
    if ref == default:
        return {"base_ok": True, "sha": sha[:12]}
    return {"base_ok": False, "sha": sha[:12], "ref": ref if REF.fullmatch(ref) else ""}


def _drain(f):
    """What an exited gh wrote, without waiting for EOF: a child that inherited the pipe keeps it open."""
    if f is None:
        return ""
    os.set_blocking(f.fileno(), False)
    try:
        return (f.read(4096) or b"").decode("utf-8", "replace")
    except OSError:
        return ""


def _harvest(p):
    """(rc, stdout, stderr) of a gh that has exited; its group is killed at once (a child holding the pipe), not later."""
    text, err = _drain(p.stdout), _drain(p.stderr)
    for f in (p.stdout, p.stderr):
        if f is not None:
            f.close()
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except OSError:
        pass
    return p.returncode, text, err


def run(jobs, deadline, errors=False):
    """{key: (rc, stdout, stderr) or None}: one `gh <jobs[key]…>` per key, all at once, each in its own process group with no
    tty and stdin closed (stderr read only with `errors`); every one still running at `deadline` seconds is killed with its
    children and answers None."""
    env = dict(os.environ, GH_PROMPT_DISABLED="1", GH_NO_UPDATE_NOTIFIER="1")
    procs = {}
    for k, argv in jobs.items():
        try:
            procs[k] = subprocess.Popen(["gh"] + argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE if errors else subprocess.DEVNULL, env=env, start_new_session=True)
        except (OSError, ValueError):
            procs[k] = None
    end = time.monotonic() + deadline
    out = {k: None for k in jobs}
    waiting = {k: p for k, p in procs.items() if p is not None}
    while waiting:
        for k, p in list(waiting.items()):
            if p.poll() is not None:                    # exited: read what it wrote now, and clear what it left in its group
                out[k] = _harvest(p)
                del waiting[k]
        if waiting:
            if time.monotonic() >= end:
                break
            time.sleep(0.01)
    for k, p in list(waiting.items()):                  # one last look: an answer that came in as the deadline passed
        if p.poll() is not None:
            out[k] = _harvest(p)
            del waiting[k]
    for p in waiting.values():                          # still running at the deadline: the whole group, then reap
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        p.wait()
        p.stdout.close()
        if p.stderr is not None:
            p.stderr.close()
    return out


def fetch(keys, deadline):
    """{key: issues answer or None} (see parse), one lookup per key, all at once under `deadline` seconds."""
    got = run({k: api_argv(k, "issues", JQ) for k in keys}, deadline)
    return {k: parse(r[1]) if r and r[0] == 0 else None for k, r in got.items()}


def fetch_pulls(keys, deadline):
    """{key: {base_ok, sha[, ref]} or None} from the pulls endpoint, one lookup per PR, all at once under `deadline` seconds."""
    got = run({k: api_argv(k, "pulls", PULLS_JQ) for k in keys}, deadline)
    return {k: parse_pulls(r[1]) if r and r[0] == 0 else None for k, r in got.items()}


def with_bases(answers, keys, left):
    """`answers` (fresh issues answers) with the pulls answer merged into each merged PR among `keys`, looked up at once in the
    `left` seconds; a PR it does not answer keeps no base, so it does not close."""
    merged = sorted({k for k in keys if (answers.get(k) or {}).get("state") == "merged"})
    if merged and left >= 0.05:
        for k, b in fetch_pulls(merged, left).items():
            if b is not None:
                answers[k] = dict(answers[k], **b)
    return answers


# --- the cache ----------------------------------------------------------------------------------------------------------------

ENTRY_FIELDS = {"t", "state", "date", "at", "reason", "pr", "base_ok", "sha", "ref"}


def read_cache(d):
    """{key: entry} from `stale-cache.json`; {} when it is missing, unreadable or its digest does not match. A file of version 1
    (an older brain wrote it: a date, no stamp) is read too, each entry kept with `legacy`: it marks, and never closes."""
    try:
        with open(os.path.join(d, CACHE_FILE), encoding="utf-8") as f:
            raw = f.read(CACHE_BYTES + 1)
        if len(raw) > CACHE_BYTES:
            return {}
        c = json.loads(raw)
        e = c["entries"]
        if c.get("v") not in (1, CACHE_V) or c.get("digest") != s.digest(s.dumps(e)):
            return {}
        if c["v"] == 1:
            e = {k: dict(v, legacy=True) for k, v in e.items() if isinstance(v, dict) and set(v) == {"t", "state", "date"}}
        now = time.time()
        return {k: v for k, v in e.items() if isinstance(v, dict) and entry_ok(v, now)}
    except Exception:  # noqa: BLE001 — whatever a damaged or hostile file raises (RecursionError too): no cache
        return {}


def entry_ok(v, now):
    """A cached answer in the shape this module writes: a time between 1970 and now, and a date, which reaches the block, that is a plain date or empty."""
    st, date, t = v.get("state"), v.get("date"), v.get("t")
    if isinstance(t, bool) or not isinstance(t, (int, float)) or not 0 < t <= now + 60:   # not NaN, inf, a huge int or a far future
        return False
    if not (set(v) == {"t", "state", "date", "legacy"} and v["legacy"] is True) and not detail_ok(v):
        return False
    if st in ("closed", "merged"):
        return isinstance(date, str) and DATE.fullmatch(date) is not None
    return st in ("open", "unknown") and date == ""


def detail_ok(v):
    """The fields of a version-2 entry: the stamp of its date (none when open or unknown), the close reason, the kind, and for a
    merged PR whose pulls lookup is due (`base_ok` null) or done, its base and merge commit."""
    at, reason, pr, state = v.get("at"), v.get("reason"), v.get("pr"), v.get("state")
    if not (set(v) <= ENTRY_FIELDS and isinstance(at, str) and isinstance(reason, str) and REASON.fullmatch(reason)
            and isinstance(pr, bool)):
        return False
    if state in ("closed", "merged"):
        if not (STAMP.fullmatch(at) and at[:10] == v.get("date")) or (state == "merged" and not pr):
            return False
    elif at:
        return False
    if "base_ok" not in v:
        return not ({"sha", "ref"} & set(v))
    b = v["base_ok"]
    if state != "merged" or not (b is None or b is True or b is False):
        return False
    if b is None:
        return not ({"sha", "ref"} & set(v))
    sha, ref = v.get("sha"), v.get("ref", "")
    return (isinstance(sha, str) and SHA12.fullmatch(sha) is not None and isinstance(ref, str)
            and (b is True and "ref" not in v or b is False and (ref == "" or REF.fullmatch(ref) is not None)))


def write_cache(d, entries, now=None):
    now = time.time() if now is None else now
    keep = sorted(((k, v) for k, v in entries.items() if now - v["t"] < CACHE_KEEP), key=lambda kv: -kv[1]["t"])[:CACHE_MAX]
    e = dict(keep)
    s._write_file(os.path.join(d, CACHE_FILE), s.dumps({"v": CACHE_V, "digest": s.digest(s.dumps(e)), "entries": e}) + "\n")


def fresh(entry, now):
    age = now - entry["t"]
    if entry.get("base_ok") is not None:
        return 0 <= age < CACHE_KEEP                    # a merge whose base was looked up is final: kept for the cache's day
    return 0 <= age < (TTL_FAILURE if entry["state"] == "unknown" else TTL_ANSWER)


def settled(entry, now):
    """No issues lookup is due: the cached answer is fresh, or it is a merge whose pulls lookup is due (a merge is final)."""
    return entry is not None and (fresh(entry, now) or "base_ok" in entry)


def entry(r, now, linked):
    """The cache entry of an issues answer `r` (None: a failed lookup); a merged PR that a `closes` names waits for its pulls
    lookup (`base_ok` null)."""
    if r is None:
        return {"t": now, "state": "unknown", "date": "", "at": "", "reason": "", "pr": False}
    e = {"t": now, "state": r["state"], "date": r["date"], "at": r["at"], "reason": r["reason"], "pr": r["pr"]}
    if linked and r["state"] == "merged":
        e["base_ok"] = None
    return e


def answer_of(e):
    """A cached entry as an answer (None for a failed lookup): the entry itself, without its time."""
    return None if e is None or e["state"] == "unknown" else {k: v for k, v in e.items() if k != "t"}


# --- when an item is done -----------------------------------------------------------------------------------------------------

def is_done(r, fresh_now):
    """Round 1's answer says done: a merged PR (a merge cannot be undone, so a cached one counts), or an issue closed as
    completed by a lookup of this run (an issue can be reopened, so a cached answer does not)."""
    if r is None:
        return False
    if r.get("pr") is True:
        return r["state"] == "merged"
    return r.get("pr") is False and r["state"] == "closed" and r.get("reason") == "completed" and fresh_now


def is_final(r, fresh_now):
    """Done, and for a merge, into the default branch of its repository (the pulls lookup), with its merge commit."""
    if not is_done(r, fresh_now):
        return False
    if r["state"] == "merged":
        return r.get("base_ok") is True and bool(r.get("sha"))
    return True


def done_after(st, it, key, at):
    """`at` (a full UTC stamp) is later than the `created` of the earliest item of `it`'s supersede chain whose `closes` holds
    `key` without a gap (an item of the chain that dropped it, or the item it was linked to by `brain op link`, ends the walk)
    and, for a linked `key`, than the time it was linked: an item first written, or linked, about work already done is never closed."""
    first, seen = it, set()
    while it is not None and it["id"] not in seen and key in [c.lower() for c in it.get("closes") or []]:
        seen.add(it["id"])
        first = it
        if isinstance(it.get("closes_at"), dict) and key in it["closes_at"]:
            break                                   # the key joined the chain here, by a link
        it = st["items"].get(it.get("supersedes") or "")
    t, c = s.parse_iso(at or ""), s.parse_iso(first.get("created") or "")
    linked = s.parse_iso((first.get("closes_at") or {}).get(key)) if isinstance(first.get("closes_at"), dict) else None
    c = max(c, linked) if c is not None and linked is not None else c
    return t is not None and c is not None and t > c


def word(r):
    """What a mark says an answer is: merged, merged into <ref>, closed, closed unmerged, closed not planned, …"""
    if r["state"] == "merged":
        return "merged into %s" % (r.get("ref") or "another branch") if r.get("base_ok") is False else "merged"
    if r["state"] != "closed":
        return r["state"]
    if r.get("pr") is True:
        return "closed unmerged"
    return {"not_planned": "closed not planned", "duplicate": "closed duplicate"}.get(r.get("reason"), "closed")


def why_not(st, it, key, r, fresh_now):
    """None when the anchor `key` of `it` lets the item close; else why not, in a few words."""
    if r is None:
        return "%s not answered" % key
    if not is_final(r, fresh_now):
        if r["state"] == "merged" and r.get("base_ok") is None:
            return "%s merged, its base branch not looked up yet" % key
        if r.get("pr") is False and is_done(r, True) and not fresh_now:
            return "%s completed, from the cache (an issue closes only from a fresh lookup)" % key
        return "%s %s" % (key, word(r) + (" " + r["date"] if r.get("date") else ""))
    if not done_after(st, it, key, r["at"]):
        return "%s done %s, before %s was written" % (key, r["at"], it["id"])
    return None


def verdict(st, it, keys, answers, looked):
    """None when every `closes` anchor of `it` is done (see why_not); else the first reason it does not close."""
    why = [why_not(st, it, k, answers.get(k), k in looked) for k in keys]
    return next((w for w in why if w), None)


def details(it, keys, answers):
    """The anchors of a `link-close` op: as the item wrote them, with state, time and, for a PR, the merge commit."""
    out, names = [], {c.lower(): c for c in it.get("closes") or [] if isinstance(c, str)}
    for k in keys:
        r = answers[k]
        d = {"anchor": names.get(k, k), "state": "merged" if r["pr"] else "completed", "at": r["at"]}
        if r["pr"]:
            d["sha"] = r.get("sha")
        out.append(d)
    return out


# --- SessionStart -------------------------------------------------------------------------------------------------------------

def _short(items, n=3):
    return ", ".join(items[:n]) + (" +%d" % (len(items) - n) if len(items) > n else "")


def stale_items(cands, answers):
    """[(item id, 'stale: #7 closed 2026-10-20; …')] in the block's order, at most PER_ITEM anchors named per item; a pinned
    item's mark says the owner retires it."""
    per, order = {}, []
    for iid, a, k in cands:
        r = answers.get(k) if k else None
        if r and r["state"] in ("closed", "merged"):
            note = "%s %s %s" % (s.clean_line(label(a, k)), word(r), r["date"])
            if iid not in per:
                per[iid] = []
                order.append(iid)
            if note not in per[iid]:
                per[iid].append(note)
    return [(i, "stale: " + "; ".join(per[i][:PER_ITEM]) + (", owner retires it" if i[0] == "D" else "")) for i in order]


def card_stale(cands, answers, gone):
    """[(item id, "owner/name#N merged")] for the review card: the first closed anchor of each live item that has one."""
    out, seen = [], set()
    for iid, a, k in cands:
        r = answers.get(k) if k else None
        if r and r["state"] in ("closed", "merged") and iid not in seen and iid not in gone:
            seen.add(iid)
            out.append((iid, "%s %s" % (s.clean_line(label(a, k)), word(r))))
    return out


def lay_out(part, marks, note, auto="", reserve=0):
    """One part of the render with each mark after its item's line; the marks, a summary, the note and `reserve` (string 1's sweep
    line, which the hook puts higher up) together stay ≤ MARKS_MAX characters, and the auto-close line (≤ NOTE_MAX) comes last."""
    room = MARKS_MAX - (len(note) + 1 if note else 0) - reserve
    summary = "(+%d more marks: brain sweep, brain doctor)"
    if sum(len(text) + 3 for _, text in marks) > room:
        room -= len(summary % 999) + 1
    shown, used = {}, 0
    for iid, text in marks:
        if used + len(text) + 3 > room:
            break
        shown[iid] = text
        used += len(text) + 3
    lines = []
    for line in part.splitlines():
        m = s._ITEM.match(line)
        lines.append(line + " · " + shown[m.group(1)] if m and m.group(1) in shown else line)
    if len(shown) < len(marks):
        lines.append(summary % (len(marks) - len(shown)))
    if note:
        lines.append(note)
    if auto:
        lines.append(auto)
    return "\n".join(lines) + "\n"


def fit(parts):
    """One line of `[(head, [entry], tail)]` parts joined by `; `, ≤ NOTE_MAX characters: entries are dropped from the end of
    the longest part, and each part that lost some says `(+N more: brain doctor)`."""
    parts = [(h, list(e), t, 0) for h, e, t in parts if e or not t]
    while True:
        line = "; ".join(h + ", ".join(e) + t + (" (+%d more: brain doctor)" % n if n else "") for h, e, t, n in parts)
        if len(line) <= NOTE_MAX or not any(len(e) > 1 for _, e, _, _ in parts):
            return s.clean_line(line[:NOTE_MAX])
        i = max(range(len(parts)), key=lambda j: len(parts[j][1]))
        h, e, t, n = parts[i]
        parts[i] = (h, e[:-1], t, n + 1)


def auto_line(closed, reopened, held, error):
    """The note line of what auto-close did in this SessionStart, "" when it did nothing to tell."""
    parts = []
    if closed:
        parts.append(("auto-closed now: ", ["%s (%s)" % (iid, ", ".join(
            "%s %s %s" % (a["anchor"], a["state"], a["at"][5:10]) for a in anchors)) for iid, anchors in closed], ""))
    if held:
        parts.append(("auto-close held: %d items at once; check brain doctor, then brain op close-linked" % held, [], ""))
    if error:
        parts.append(("auto-close: %s" % error, [], ""))
    if reopened:
        parts.append(("reopened: ", ["%s %s" % (iid, a) for iid, a in reopened], ", re-add it with brain op add"))
    return fit(parts) if parts else ""


def last_touched(it, ops, now):
    """When `it` was last written, touched, hit or linked: the time of the op its `touched` names, else its `created`; `now`
    for an op past `ops` (written in this SessionStart after the log was read, as a promotion by a link-close)."""
    seq = it.get("touched")
    if isinstance(seq, int) and not isinstance(seq, bool) and seq > len(ops):
        return now
    op = ops[seq - 1] if isinstance(seq, int) and not isinstance(seq, bool) and 0 < seq else {}
    return s.parse_iso(op.get("t") or "") or s.parse_iso(it.get("created") or "")


def untouched(st, ops, now):
    """[(item id, whole days untouched)] of the live right-brain items untouched for their kind's threshold or longer, in the
    render's section order."""
    out, order = [], [letter for letter, _ in s.SECTIONS]
    for it in sorted(st["items"].values(), key=lambda i: (order.index(i["id"][0]), int(i["id"][1:]))):
        days = s.untouched_days(it["id"][0])
        t = last_touched(it, ops, now) if days and it["status"] == "live" else None
        if t is not None and now - t >= days * 86400:
            out.append((it["id"], int((now - t) // 86400)))
    return out


def item_units(strings):
    """{item id: UTF-16 units of its rendered line and the lines under it} over the render's strings: what closing it frees."""
    out, here = {}, None
    for _, text in strings:
        for line in text.splitlines(True):
            m = s._ITEM.match(line)
            if m:
                here = m.group(1)
            elif not line.startswith("  "):
                here = None
            if here:
                out[here] = out.get(here, 0) + s.units(line)
    return out


REASONS = ("blocked work done", "closed anchors", "queue without blocks", "untouched")


def sweep_rows(st, cands, answers, idle, sizes):
    """[(reason, item id, why, units)] in REASONS order: each live right-brain item once, under its first reason (a queue item
    whose `blocks` anchor closed, any other closed anchor, a queue item an older brain wrote with no `blocks`, untouched); the
    left brain never."""
    rows, seen = [], set()
    shut = lambda k: (answers.get(k) or {}).get("state") in ("closed", "merged")
    keys = {iid: {anchor_key(a) for a in blocks_anchors(st["items"][iid])} for iid in {c[0] for c in cands}}
    keys = {iid: ks for iid, ks in keys.items() if ks}   # by key: a queue item's blocked work is done once every one is
    done = {iid for iid, ks in keys.items() if all(shut(k) for k in ks)}
    closed = {}
    for iid, _, k in cands:
        if k and shut(k):
            closed.setdefault(iid, set()).add(k)
    for iid, why in stale_items(cands, answers):
        part = iid in keys and iid not in done and closed.get(iid, set()) <= keys[iid]
        if s.half_of(iid[0]) == "right" and not part:   # part of a queue item's blocked work done: a mark, no candidate
            rows.append(("blocked work done" if iid in done else "closed anchors", iid, why, sizes.get(iid, 0)))
            seen.add(iid)
    rows += [("queue without blocks", it["id"], "names no work it blocks: supersede it with --blocks, or close it",
              sizes.get(it["id"], 0)) for it in sorted(s.live(st, "Q"), key=lambda i: int(i["id"][1:]))
             if it["id"] not in seen and not isinstance(it.get("blocks"), str)]
    seen |= {r[1] for r in rows}
    rows += [("untouched", iid, "untouched %d d (%s: %d d)" % (n, dict(s.SECTIONS)[iid[0]], s.untouched_days(iid[0])),
              sizes.get(iid, 0)) for iid, n in idle if iid not in seen and s.half_of(iid[0]) == "right"]
    return sorted(rows, key=lambda r: REASONS.index(r[0]))


def sweep_line(rows):
    """String 1's one line when anything is worth cleaning, "" otherwise."""
    if not rows:
        return ""
    n = {r: [x for x in rows if x[0] == r] for r in REASONS}
    parts = ["%d blocked work done" % len(n["blocked work done"])] if n["blocked work done"] else []
    if n["closed anchors"]:
        parts.append("%d closed anchor%s" % (len(n["closed anchors"]), "" if len(n["closed anchors"]) == 1 else "s"))
    if n["queue without blocks"]:
        parts.append("%d queue without blocks" % len(n["queue without blocks"]))
    if n["untouched"]:
        parts.append("%d untouched %d+ d" % (len(n["untouched"]), min(s.untouched_days(x[1][0]) for x in n["untouched"])))
    return "sweep: %d item%s to clean (~{:,} chars): %s; brain sweep lists them".format(sum(x[3] for x in rows)) % (
        len(rows), "" if len(rows) == 1 else "s", ", ".join(parts))


def merged_marks(marks, idle):
    """The stale marks and the untouched marks, one text per item, in the block's order of the stale ones first."""
    by = dict(marks)
    for iid, n in idle:
        by[iid] = (by[iid] + " · " if iid in by else "") + "untouched %d d" % n
    order = [i for i, _ in marks] + [i for i, _ in idle if i not in dict(marks)]
    return [(i, by[i]) for i in order]


def sweep_cmd():
    """`brain sweep`: every candidate by reason with the characters it would free, from fresh lookups (doctor's bounds); it
    writes nothing, not even the lookup cache."""
    d = s.state_dir()
    if not os.path.isdir(d):
        raise s.Refused(1, "no brain state for this project yet")
    with s.locked(d):
        st, ops = s.load_ops(d)[1:]
    now, answers, note = time.time(), {}, ""
    cands = candidates(st)
    keys, total = distinct([c for c in cands if s.half_of(c[0][0]) == "right"], MAX_DOCTOR)
    if keys and shutil.which("gh") is None:
        note = "closed anchors not checked: gh not found\n"
    elif keys:
        answers = {k: r for k, r in fetch(keys, DOCTOR_DEADLINE).items() if r is not None}
        if len(answers) < total:
            note = "closed anchors: %d of %d anchors answered\n" % (len(answers), total)
    rows = sweep_rows(st, cands, answers, untouched(st, ops, now), item_units(s.render_strings(st, now=now)))
    out = [sweep_line(rows) or "sweep: nothing to clean"]
    for reason in REASONS:
        mine = [r for r in rows if r[0] == reason]
        if mine:
            out.append("%s (%d):" % (reason, len(mine)))
            out += ["  %s (~%d chars): %s" % (iid, n, s.clean_line(why)) for _, iid, why, n in mine]
    if rows:
        out.append("close: brain op close ID --reason R [--pointer P] [--bulk]; keep: brain op touch ID")
    sys.stdout.write(note + "".join(s.printable(l) + "\n" for l in out))
    return None


def annotate(strings, st, d, sid=None, ops=None):
    """([(half, text to inject)], the number of stale items, what auto-close did: {"closed": [(id, anchors)], "held": n, "error":
    text or None, "noted": {indexes of the strings given a note line}, "stale": [(id, its first closed anchor)] for the review
    card, "sweep": string 1's sweep line or ""}, the state after). With the log's `ops`, an item untouched past its kind's
    threshold is marked too, without any lookup. `strings` is the render's
    (`brain_store.render_strings`); a mark goes after its item's line, an auto-close line in the first string of the item's
    half, and the check's own note, a held burst and an error in string 1. Never raises: an error is no marks and one note line
    in string 1."""
    try:
        return _annotate(strings, st, d, sid, ops)
    except Exception as e:  # noqa: BLE001 — a SessionStart must never fail for a lookup
        out = list(strings)
        out[0] = (out[0][0], out[0][1] + "stale-anchor check: skipped (%s)\n" % e.__class__.__name__)
        return out, 0, dict(NOTHING, noted={0}), st


def round_one(keys, reopen, linked, cache, now):
    """The keys round 1 looks up, at most MAX_START: up to MAX_REOPEN reopen checks first, then the other anchors, least
    recently checked first (never-checked `closes` anchors, then never-checked plain ones, lead); a settled key is answered
    from the cache."""
    age = lambda k: (0 if k not in cache and k in linked else 1 if k not in cache else 2, cache[k]["t"] if k in cache else 0)
    again = sorted((k for k in reopen if not settled(cache.get(k), now)), key=age)[:MAX_REOPEN]
    queue = sorted((k for k in keys if k not in again and not settled(cache.get(k), now)), key=age)
    return (again + queue)[:MAX_START]


def round_two(cache, linked, burst, looked, left, now):
    """Round 2: the pulls lookups of the merged PRs a `closes` names whose base is not known (`base_ok` null), those pending from
    an earlier SessionStart first (least recently tried first, a tie by key), then this burst's, at most MAX_PULLS, in the
    `left` seconds.
    Updates the cache, an unanswered one with the time it was tried (so five that keep failing do not hold every slot);
    returns the keys it tried."""
    due = sorted((k for k in linked if "base_ok" in (cache.get(k) or {}) and cache[k]["base_ok"] is None),
                 key=lambda k: (cache[k]["t"], k))
    due = ([k for k in due if k not in looked] + [k for k in due if k in looked and k in burst])[:MAX_PULLS]
    if not due or left < 0.05:
        return []
    for k, b in fetch_pulls(due, left).items():
        if b is not None:
            cache[k].update(b)
        else:
            cache[k]["t"] = now                     # tried now: the others' turn comes first next time
    return due


def _annotate(strings, st, d, sid, ops=None):
    t0 = time.monotonic()
    cands = candidates(st)
    keys, total = distinct(cands, None)
    bare = bare_skipped(cands)
    now = time.time()
    nx = linked_items(st)
    linked = {k for _, ks in nx for k in ks}
    writer = bool(sid) and st["writer"] == sid
    reopen = reopen_keys(st, now) if writer else {}          # the writer's SessionStart: only it can re-add an item
    notes, answers, looked, did, reopened = [], {}, set(), dict(NOTHING), []
    checked, failed = 0, 0
    if keys or reopen:
        if shutil.which("gh") is None:
            notes.append("skipped, gh not found")
        else:
            cache = read_cache(d)
            look = round_one(keys, reopen, linked, cache, now)
            got = fetch(look, DEADLINE) if look else {}
            for k, r in got.items():
                cache[k] = entry(r, now, k in linked)
            looked = {k for k, r in got.items() if r is not None}
            answers = {k: answer_of(cache[k]) for k in set(keys) | set(reopen) if settled(cache.get(k), now)}
            burst = [it for it, ks in nx if all(is_done(answers.get(k), k in looked) for k in ks)]
            held = len(burst) > BURST_MAX if writer else False       # counted after round 1: a burst spends no pulls lookup
            pulled = round_two(cache, linked, {k for it, ks in nx if it in burst for k in ks}, looked,
                               DEADLINE - (time.monotonic() - t0), now) if writer and not held else []
            answers.update({k: answer_of(cache[k]) for k in pulled})
            closing = [(it, ks) for it, ks in nx if writer and not held and verdict(st, it, ks, answers, looked) is None]
            did["held"] = len(burst) if held else 0
            if got or pulled:
                try:
                    write_cache(d, cache, now)
                except OSError:
                    pass
            checked = sum(1 for k in keys if settled(cache.get(k), now))
            failed = sum(1 for k in keys if settled(cache.get(k), now) and answers.get(k) is None)
            if closing:
                rows = [(it["id"], details(it, ks, answers)) for it, ks in closing]
                try:
                    st, done, warn = s.link_close(d, sid, rows, {"hook": "SessionStart"})
                    did["closed"] = [(iid, an) for iid, an in rows if iid in done]
                    did["error"] = s.clean_line(warn.strip().split("\n")[0][:120]) or None     # where it stopped, first
                    strings = s.render_strings(st, limit=s.SLOTS)
                except Exception as e:  # noqa: BLE001 — a lock held past LOCK_WAIT, a chain refusal: no close, the marks stay
                    msg = e.msg if isinstance(e, s.Refused) else s.why(e)
                    msg = "%s has an error: brain doctor" % s.CONFIG_FILE if msg.startswith(s.CONFIG_FILE) else msg
                    did["error"] = "nothing closed (%s)" % s.clean_line(msg[:80])
            reopened = [(iid, a) for k, pairs in reopen.items() if (answers.get(k) or {}).get("state") == "open"
                        for iid, a in pairs]
    if failed:
        notes.append("incomplete, %d of %d lookups failed or timed out" % (failed, checked))
    if keys and total > checked and "skipped, gh not found" not in notes:
        notes.append("checked %d of %d" % (checked, total))
    if bare:
        notes.append("skipped for %s: no single repository of its item" % _short([s.clean_line(a) for a in bare]))
    note = "stale-anchor check: " + "; ".join(notes) if notes else ""
    gone = {iid for iid, _ in did["closed"]}
    stale = [m for m in stale_items(cands, answers) if m[0] not in gone]
    did["stale"] = card_stale(cands, answers, gone)
    idle = untouched(st, ops, now) if ops is not None else []
    did["sweep"] = sweep_line(sweep_rows(st, [c for c in cands if c[0] not in gone], answers, idle, item_units(strings)))
    marks = merged_marks(stale, idle)
    first = {}                                      # each half's first string: where its auto-close lines go
    for i, (half, _) in enumerate(strings):
        first.setdefault(half, i)
    out, noted = [], set()
    for i, (half, text) in enumerate(strings):
        held = {m.group(1) for m in map(s._ITEM.match, text.splitlines()) if m}
        mine = lambda pairs: [x for x in pairs if first.get(s.half_of(x[0][0])) == i]
        auto = auto_line(mine(did["closed"]), mine(reopened), did["held"] if i == 0 else 0,
                         did["error"] if i == 0 else None)
        pnote = note if i == 0 else ""
        if pnote or auto:
            noted.add(i)
        laid = lay_out(text, [m for m in marks if m[0] in held], pnote, auto, len(did["sweep"]) + 1 if i == 0 and did["sweep"] else 0)
        out.append((half, s.retitled(laid) if laid != text else text))
    did["noted"] = noted
    return out, len(stale), did, st


# --- brain op close-linked ----------------------------------------------------------------------------------------------------

def close_linked():
    """`brain op close-linked`: every live item whose `closes` anchors are all done, by fresh lookups under doctor's
    bounds (20 s, ≤ 40 keys) and with no cap of BURST_MAX, closes as the op `link-close`. Refused (3) when this session does
    not write the project's hot memory. Returns what it closed and what it skipped, with why."""
    s.check_caller()
    s.check_config()                                # before 20 seconds of lookups that link_close would then refuse
    d = s.state_dir()
    if not os.path.isdir(d):
        raise s.Refused(1, "no brain state for this project yet")
    _, st = s.load(d)
    if st["writer"] != s.session_id():
        raise s.Refused(3, "close-linked: this session does not write this project's hot memory (%s); nothing was looked up"
                        % ("no session has written it yet" if st["writer"] is None else "another session does"))
    nx = linked_items(st)
    if not nx:
        return "close-linked: no live Now, Next, session or queue item names a closes anchor"
    if shutil.which("gh") is None:
        raise s.Refused(1, "close-linked: gh not found; nothing was looked up or closed")
    keys, _ = distinct([(None, None, k) for _, ks in nx for k in ks], None)
    look = keys[:MAX_DOCTOR]
    t0 = time.monotonic()
    answers = {k: r for k, r in fetch(look, DOCTOR_DEADLINE).items() if r is not None}
    with_bases(answers, look, DOCTOR_DEADLINE - (time.monotonic() - t0))
    closing, lines = [], []
    for it, ks in nx:
        if any(k not in look for k in ks):
            lines.append("skipped %s: past %d keys; run close-linked again once others are closed" % (it["id"], MAX_DOCTOR))
            continue
        why = verdict(st, it, ks, answers, set(answers))
        if why:
            lines.append("skipped %s: %s" % (it["id"], why))
        else:
            closing.append((it["id"], details(it, ks, answers)))
    done = []
    if closing:
        _, done, warn = s.link_close(d, s.session_id(), closing, {"cmd": "close-linked"}, wait=None)
        lines = ["closed %s (%s)" % (iid, s.link_reason(anchors)) for iid, anchors in closing if iid in done] + lines
        if warn:
            lines.append(warn.strip())
        if done:
            s.episode_line(d, s.session_id(), "auto-close", cmd="close-linked", ids=done,
                           anchors=[a["anchor"] for iid, an in closing if iid in done for a in an])
    return "\n".join(lines) if lines else "close-linked: nothing to close"


# --- evidence from merged PRs -------------------------------------------------------------------------------------------------
# A PR that vibemaestro-sdlc's merge guard merged (a `merged` line of its merge log) names the rules it applied in its body, as
# plain lines the worker copies from its brief: `Rules applied: D3, T5, [S07]` and `Traps met: T2`. Each code that is a live
# rule gets one held (a trap met, one hit), pointing to the PR. The body is worker text: only those two lines, outside a fenced
# code block, are read, and nothing but a held or a hit for a code of this brain is ever written.

MERGE_FILE = "merge-evidence.json"      # the merge log's offset read so far and the PRs whose body is still to read
MERGE_LOOK = 10                         # PRs looked up per run; the rest wait for the next one
MERGE_TRIES = 5                         # reads of one PR's body that may fail before it is dropped, named
MERGE_WAIT = 200                        # PRs kept waiting at most; past it the oldest are dropped, each named
LABELS = {"Rules applied:": "held", "Traps met:": "hit"}
CODES_MAX, LABEL_LINE = 12, 300         # codes on one line, characters of one line: past either, the line is not read
END = "--end--"                         # the answer's last line: an answer cut short (a pipe read stops at 4096 bytes) lacks it
PR_KEY = re.compile(r"[a-z0-9_.-]+/[a-z0-9_.-]+#[1-9][0-9]{0,8}")
BODY_JQ = ('(.body // "" | split("\\n") | .[] | sub("\\r$"; "") | select(test("^ {0,3}(```|~~~)") or startswith("Rules applied:") '
           'or startswith("Traps met:")) | .[0:400]), "%s"' % END)


def merge_log():
    """The merge guard's log beside the brain's state root (its default name, as `brain matrix` reads it)."""
    # shortcut: a merge log renamed by the base config's merge.log is not read; read that key when someone sets it
    return os.path.join(os.path.dirname(s.state_root()), "merge-log.jsonl")


def merged_since(offset):
    """(new offset, [owner/name#n]) of the `merged` lines of the merge log after byte `offset`, in log order; a log shorter
    than `offset` (rotated) is read from its start, a line cut at the end is left for the next read."""
    try:
        with open(merge_log(), "rb") as f:
            f.seek(0, os.SEEK_END)
            if f.tell() < offset:
                offset = 0
            f.seek(offset)
            data = f.read()
    except OSError:
        return offset, []
    keys = []
    whole = data[:data.rfind(b"\n") + 1]
    for b in whole.split(b"\n"):
        try:
            o = json.loads(b)
        except ValueError:
            continue
        if not isinstance(o, dict) or o.get("mode") != "merge" or o.get("result") != "merged":
            continue
        pr, repo = o.get("pr"), o.get("repo")
        if isinstance(pr, int) and not isinstance(pr, bool) and pr > 0 and isinstance(repo, str) and repo_ok(repo):
            keys.append("%s#%d" % (repo.lower(), pr))
    return offset + len(whole), keys


def label_codes(text):
    """({"held": [codes], "hit": [codes]}, [notes]) of the plain label lines of a PR body (the --jq lines: fences and label
    lines): a line inside a fence, a label given twice, a line over LABEL_LINE characters or CODES_MAX codes is not read."""
    fence, seen, notes = None, {}, []
    for ln in text.split("\n"):
        m = re.match(r" {0,3}(`{3,}|~{3,})(.*)$", ln)
        if m:
            if fence is None:
                fence = m.group(1)
            elif m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence) and not m.group(2).strip():
                fence = None                        # a closing fence: the opening's character, as long or longer, no info
            continue
        label = next((k for k in LABELS if ln.startswith(k)), None)
        if label is None or fence:
            continue
        seen.setdefault(label, []).append(ln[len(label):])
    out = {"held": [], "hit": []}
    for label, rows in seen.items():
        if len(rows) > 1:
            notes.append("%s given %d times: not read" % (label, len(rows)))
            continue
        codes = [c.strip() for c in rows[0].split(",") if c.strip()]
        if len(rows[0]) + len(label) > LABEL_LINE or len(codes) > CODES_MAX:
            notes.append("%s over %d characters or %d codes: not read" % (label, LABEL_LINE, CODES_MAX))
            continue
        out[LABELS[label]] = codes
    return out, notes


def pr_session(st, key):
    """The session item (its chain's root) whose `closes` names the PR `key`, else the PR itself as `pr:owner/name#n`: the
    session a held from that PR counts under, so three PRs are three sessions."""
    for it in sorted(st["items"].values(), key=lambda i: int(i["id"][1:])):
        if it["id"][0] == "S" and key in [str(c).lower() for c in it.get("closes") or []]:
            return s.chain_root(st, it)["id"], None
    return None, "pr:" + key


def known_repos(st):
    """The repositories (lower case) this brain knows: its project's `origin` on GitHub and every one an item's anchors or
    `closes` name. A PR of another repository is not read: the merge log is the machine's, item ids are the brain's."""
    out = set()
    for it in st["items"].values():
        for a in list(it.get("anchors") or []) + list(it.get("closes") or []):
            m = parse_anchor(a)
            if m and m[0]:
                out.add(m[0].lower())
    url = s._git(s.project_root(), "remote", "get-url", "origin") or ""
    m = re.search(r"github\.com[:/]+([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?/?\s*$", url)
    if m:
        out.add(m.group(1).lower())
    return out


def read_mem(path):
    """(offset or None, {PR: failed reads}) of `merge-evidence.json`: a bad waiting entry is left out alone, an offset that is
    not a whole number ≥ 0 (or no file) is None, a first run."""
    try:
        with open(path, encoding="utf-8") as f:
            mem = json.loads(f.read())
    except (OSError, ValueError):
        return None, {}
    mem = mem if isinstance(mem, dict) else {}
    offset = mem.get("offset")
    if isinstance(offset, bool) or not isinstance(offset, int) or offset < 0:
        offset = None
    wait = {}
    for e in mem.get("wait") if isinstance(mem.get("wait"), list) else []:
        if (isinstance(e, list) and len(e) == 2 and isinstance(e[0], str) and PR_KEY.fullmatch(e[0])
                and repo_ok(e[0].split("#")[0]) and isinstance(e[1], int) and not isinstance(e[1], bool) and 0 <= e[1] < MERGE_TRIES):
            wait[e[0]] = e[1]
    return offset, wait


def rule_skip(st, ops, led, code, pr, via, done):
    """(why `code` of the PR `pr` is not written whatever the moment, its ledger key): not a live rule, a SOUL code no owner step
    promoted, a held from that PR already (in the log, or `done` in this run); why None when it may be written: a refusal after
    this check is the moment's (a take-over, the filter)."""
    import brain_ledger as L
    try:
        kind, value = L.rule_arg(code, hit=via == "hit")
        if kind == "id":
            L.check_rule_item(st, value, hit=via == "hit")
        elif value not in L.soul_live(ops):
            return "[%s] is not a SOUL code an owner step promoted (or it was demoted)" % value, None
    except s.Refused as e:
        return e.msg.split("\n")[0], None
    key = "[%s]" % value if kind == "soul" else value
    if key in done or any(e["result"] == "held" and e["pointer"] == pr for e in (led.get(key) or {}).get("events", [])):
        return "%s has a held from %s already" % (key, pr), key
    return None, key


def write_codes(d, k, codes, session, pr, lines):
    """Write the hits, then the helds, of the PR `k`; a code a rule check refuses is skipped and named. False when a write is
    refused for another reason (the others are still tried): the PR is read again at the next run, and what it wrote already is
    not written twice."""
    import brain_ledger as L
    st, ops, led = L.snapshot(d)
    done, ok = set(), True
    for via, cs in (("hit", codes["hit"]), (None, codes["held"])):    # a trap met and applied: its hit is the PR's held
        for c in cs:
            why, key = rule_skip(st, ops, led, c, k, via, done)
            if why:
                lines.append("skipped %s %s: %s" % (s.printable(c)[:20], k, why))
                continue
            try:
                msg = s.op_evidence(c, "held", k, session=session, via=via, as_pr=pr, machine=True)
            except s.Refused as e:
                lines.append("waiting %s: %s %s was refused (%s)" % (k, s.printable(c)[:20], "hit" if via else "held",
                                                                    e.msg.split("\n")[0]))
                ok = False
                continue
            lines.append("%s (%s)" % (msg.split("\n")[0], k))
            done.add(key)
    return ok


def merge_evidence():
    """`brain op merge-evidence`: the held and hit of every PR of a known repository merged since the last run, by fresh body
    lookups (MERGE_LOOK per run, DOCTOR_DEADLINE seconds). Refused (3) when this session does not write the project's hot
    memory. A first run starts at the log's end: PRs merged before it are not read. Returns what it wrote and what it skipped,
    with why."""
    s.check_caller()
    s.check_config()
    d = s.state_dir()
    if not os.path.isdir(d):
        raise s.Refused(1, "no brain state for this project yet")
    _, st = s.load(d)
    if st["writer"] != s.session_id():
        raise s.Refused(3, "merge-evidence: this session does not write this project's hot memory (%s); nothing was read"
                        % ("no session has written it yet" if st["writer"] is None else "another session does"))
    path = os.path.join(d, MERGE_FILE)
    offset, wait = read_mem(path)
    if offset is None:                              # the first run (or a damaged file, said so): from now on
        damaged = os.path.exists(path)
        offset, _ = merged_since(0)
        s._write_file(path, json.dumps({"offset": offset, "wait": [[k, n] for k, n in wait.items()]}) + "\n")
        return "merge-evidence: %sstarted at the end of the merge log; PRs merged from now on are read%s" % (
            "%s held no offset: " % MERGE_FILE if damaged else "", "; %d waiting kept" % len(wait) if wait else "")
    offset, new = merged_since(offset)
    known, lines = known_repos(st), []
    for k in new:
        if k.split("#")[0] not in known:
            lines.append("skipped %s: not a repository this brain names" % k)
        else:
            wait.setdefault(k, 0)
    queue = list(wait)
    look = queue[:MERGE_LOOK] if shutil.which("gh") else []
    got = run({k: api_argv(k, "pulls", BODY_JQ) for k in look}, DOCTOR_DEADLINE) if look else {}
    for k in look:
        r = got.get(k)
        body = r[1] if r and r[0] == 0 else None
        if body is None or not (body.endswith("\n" + END + "\n") or body == END + "\n"):
            wait[k] += 1
            why = "no answer" if not r else "gh rc %d" % r[0] if r[0] else "an answer cut short"
            if wait[k] >= MERGE_TRIES:
                del wait[k]
                lines.append("dropped %s: its body was not read in %d tries (%s)" % (k, MERGE_TRIES, why))
            else:
                lines.append("waiting %s: its body was not read (%s)" % (k, why))
            continue
        codes, notes = label_codes(body[:-len(END) - 1])
        lines += ["%s: %s" % (k, n) for n in notes]
        session, pr = pr_session(st, k)
        if not write_codes(d, k, codes, session, pr, lines):
            wait[k] += 1                            # the moment refused (a take-over, the filter): read again next run
            if wait[k] >= MERGE_TRIES:
                del wait[k]
                lines.append("dropped %s: a write was refused in %d tries" % (k, MERGE_TRIES))
            continue
        del wait[k]
    for k in list(wait)[:-MERGE_WAIT] if len(wait) > MERGE_WAIT else []:
        del wait[k]
        lines.append("dropped %s: past %d PRs waiting" % (k, MERGE_WAIT))
    s._write_file(path, json.dumps({"offset": offset, "wait": [[k, n] for k, n in wait.items()]}) + "\n")
    if not lines:
        return "merge-evidence: no PR merged since the last run" if not queue else "merge-evidence: no gh, %d PR(s) wait" % len(queue)
    return "\n".join(lines)


# --- --closes at write time ---------------------------------------------------------------------------------------------------

def closes_check(anchors, kept=()):
    """The write-time lookup of `closes` anchors (`owner/name#N`): one `gh` each, all at once, WRITE_DEADLINE seconds. For
    `anchors`, new to the item: the lines to print (state and title; the title is not stored), or `closes not checked: …` when
    there was no answer; Refused (1) for an anchor GitHub does not know (404), and for one already merged or completed, which
    could only ever be marked. For `kept`, anchors the item already names (a supersede carries them, or names them again): a
    warning for one already done, since the new item may close at the next writer SessionStart (the chain's first item was
    written before it was done)."""
    if shutil.which("gh") is None:
        return ["closes not checked: %s" % a for a in anchors]
    every = list(anchors) + [a for a in kept if a not in anchors]
    got = run({a.lower(): api_argv(a.lower(), "issues", JQ_TITLE) for a in every}, WRITE_DEADLINE, errors=True)
    lines = []
    for a in kept:
        r = got.get(a.lower())
        ans = parse(r[1], title=True) if r and r[0] == 0 else None
        if ans is not None and is_done(ans, True):
            lines.append("closes %s is already %s (%s): the new item may close at the next writer SessionStart; "
                         "--drop-anchor %s keeps it live" % (a, "merged" if ans["pr"] else "completed", ans["date"], a))
    for a in anchors:
        r = got.get(a.lower())
        if r and r[0] != 0 and "HTTP 404" in r[2]:
            raise s.Refused(1, "--closes %s: GitHub has no such issue or PR (404); check the owner, name and number" % a)
        ans = parse(r[1], title=True) if r and r[0] == 0 else None
        if ans is None:
            lines.append("closes not checked: %s" % a)
        elif is_done(ans, True):
            raise s.Refused(1, "--closes %s is already %s (%s): an item that names it could never close, only be marked; close "
                               "the item, or name the issue or PR whose close is still to come"
                            % (a, "merged" if ans["pr"] else "completed", ans["date"]))
        else:
            lines.append("closes %s: %s %s · %s" % (a, "PR" if ans["pr"] else "issue",
                                                     word(ans) + (" " + ans["date"] if ans["date"] else ""),
                                                     s.clean_line(ans["title"][:80])))   # cut, then cleaned: a cut never leaves a partial run
    return lines


# --- brain doctor -------------------------------------------------------------------------------------------------------------

def doctor_lines(st):
    """[(level, text)] for `brain doctor`; fresh lookups, nothing read from or written to the cache."""
    try:
        return _doctor(st)
    except Exception as e:  # noqa: BLE001 — a doctor line must not hide the others
        return [("info", "stale anchors: the check failed (%s)" % e.__class__.__name__)]


def _doctor(st):
    ignored = ignored_default()
    out = []
    if ignored is not None:
        out.append(("warn", "BRAIN_DEFAULT_REPO is set (%s) but no longer read: a bare #N resolves only against the one "
                            "repository its item's other anchors name; write owner/name#N, and remove the variable"
                    % s.printable(ignored)[:60]))
    cands = candidates(st)
    now = time.time()
    reopen = reopen_keys(st, now)
    for it in sorted((i for i in st["items"].values() if i["status"] == "closed" and isinstance(i.get("linked"), dict)),
                     key=lambda i: i["touched"]):
        t = s.parse_iso(it["linked"].get("t") or "")
        if t is not None and 0 <= now - t < REOPEN_WINDOW:
            out.append(("info", "auto-closed: %s at %s, %s" % (it["id"], it["linked"]["t"], "; ".join(
                "%s %s" % (a.get("anchor"), a.get("state")) for a in it["linked"].get("anchors") or [] if isinstance(a, dict)))))
    keys, total = distinct([(None, None, k) for k in reopen] + cands, MAX_DOCTOR)
    total = len(set(reopen) | {k for _, _, k in cands if k})
    skipped = unchecked(cands)
    if skipped:
        ids = {i for i, _ in skipped}
        out.append(("info", "stale anchors: %d bare anchor%s on %d item%s naming no single repository %s not checked; %s"
                    % (len(skipped), "" if len(skipped) == 1 else "s", len(ids), "" if len(ids) == 1 else "s",
                       "is" if len(skipped) == 1 else "are", SET_IT)))
    for iid, a in skipped[:DOCTOR_UNCHECKED]:
        out.append(("info", "not checked: %s %s" % (iid, s.clean_line(a))))
    if len(skipped) > DOCTOR_UNCHECKED:
        more = len(skipped) - DOCTOR_UNCHECKED
        out.append(("info", "not checked: +%d more anchor%s" % (more, "" if more == 1 else "s")))
    if not keys:
        return out
    if shutil.which("gh") is None:
        return out + [("info", "stale anchors: gh not found, nothing was checked")]
    t0 = time.monotonic()
    answers = fetch(keys, DOCTOR_DEADLINE)
    nx = linked_items(st)
    with_bases(answers, [k for _, ks in nx for k in ks], DOCTOR_DEADLINE - (time.monotonic() - t0))
    seen = set()
    for iid, a, k in cands:
        r = answers.get(k) if k else None
        if r and r["state"] in ("closed", "merged") and (iid, k) not in seen:
            seen.add((iid, k))
            via = "" if a.lower() == k else " (%s)" % k
            pin = (", owner retires it: brain owner unpin %s, or brain owner supersede %s --text …" % (iid, iid)
                   if iid[0] == "D" else "")
            out.append(("warn", "stale anchor: %s %s%s %s %s%s" % (iid, s.clean_line(a), via, word(r), r["date"], pin)))
    looked = {k for k, r in answers.items() if r is not None}
    would = [(it, ks) for it, ks in nx if verdict(st, it, ks, answers, looked) is None]
    for it, ks in would:
        out.append(("info", "would close: %s %s" % (it["id"], "; ".join(
            "%s %s %s" % (a["anchor"], a["state"], a["at"][:10]) for a in details(it, ks, answers)))))
    for k, pairs in sorted(reopen.items()):
        if (answers.get(k) or {}).get("state") == "open":
            for iid, a in pairs:
                out.append(("warn", "reopened: %s %s, re-add it with brain op add" % (iid, s.clean_line(a))))
    failed = sum(1 for k in keys if answers.get(k) is None)
    if failed:
        out.append(("info", "stale anchors: %d of %d lookups failed or timed out" % (failed, len(keys))))
    if total > len(keys):
        out.append(("info", "stale anchors: checked %d of %d" % (len(keys), total)))
    if not seen and not failed:
        out.append(("ok", "stale anchors: none among %d checked" % len(keys)))
    return out
