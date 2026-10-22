"""vibemaestro-brain cost: a Claude Code transcript's `usage`, at baseline A's weights.

One call per `message.id` of an `assistant` record: Claude Code writes each content block of a response as its own record with the
same id and `usage` (measured: 72 records for 36 calls), so a sum over records counts most calls twice. When records of one id
differ, each field counts at its largest. Records with `isSidechain: true` or model `<synthetic>` are skipped and counted.
Units are base-input tokens: input 1x, cache read 0.05x, cache write 2x (1-hour) or 1.25x (5-minute), 2x when the write has no
TTL split (A's assumption), output 5x. Used by `brain cost`, by the pre-compact running sums (from a saved byte offset) and by
the live probe. Standard library only, Python 3.8.
"""
import calendar
import collections
import contextlib
import glob
import json
import os
import re
import time

W_INPUT = 1.0
W_READ = 0.05
W_1H = 2.0
W_5M = 1.25
W_OTHER = 2.0
W_OUTPUT = 5.0
FIELDS = ("input", "read", "write_1h", "write_5m", "write_other", "output")
GAP = 3600                      # seconds between two calls that make a gap (a 1-hour cache has expired)
RECENT = 64                     # message ids kept across offsets: one response's records are written together
KEPT = 200                      # design value: running-sums files kept, newest first (like the summaries)
CHUNK = 1 << 20
TIME_BUDGET = 5.0               # design value: seconds pre-compact spends parsing before it saves where it stopped

_TS = re.compile(r"^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.\d+)?(?:Z|\+00:00)$")


def epoch(ts):
    m = _TS.match(ts) if isinstance(ts, str) else None
    return calendar.timegm(tuple(int(x) for x in m.groups()) + (0, 0, 0)) if m else None


def _int(v):
    try:
        return max(0, int(v))
    except (TypeError, ValueError):
        return 0


def values(u):
    """The six token fields of one `usage` object."""
    cc = u.get("cache_creation") if isinstance(u.get("cache_creation"), dict) else {}
    w1h, w5m = _int(cc.get("ephemeral_1h_input_tokens")), _int(cc.get("ephemeral_5m_input_tokens"))
    total = _int(u.get("cache_creation_input_tokens"))
    return [_int(u.get("input_tokens")), _int(u.get("cache_read_input_tokens")), w1h, w5m, max(0, total - w1h - w5m),
            _int(u.get("output_tokens"))]


def context(v):
    return v[0] + v[1] + v[2] + v[3] + v[4]


class Sums(object):
    """Running sums over calls, fed record by record; `state()` and `load()` carry them across byte offsets. `keep` is how many
    message ids are remembered (None: all, for a whole file or several files whose forks repeat ids)."""

    def __init__(self, keep=RECENT):
        self.keep = keep
        self.tokens = [0] * len(FIELDS)
        self.calls = 0
        self.ctx_sum = 0
        self.ctx_max = 0
        self.first = None           # (epoch, iso) of the first call
        self.last = None            # (epoch, iso) of the last call
        self.gaps = []              # [start iso, end iso, seconds, key of the call after, its write]
        self.skipped = {"sidechain": 0, "synthetic": 0, "unreadable": 0}
        self.recent = collections.OrderedDict()   # key → the values counted for it
        self.anon = 0

    def add_record(self, rec):
        if not isinstance(rec, dict) or rec.get("type") != "assistant":
            return
        m = rec.get("message")
        if not isinstance(m, dict) or not isinstance(m.get("usage"), dict):
            return
        if rec.get("isSidechain") is True:
            self.skipped["sidechain"] += 1
            return
        if m.get("model") == "<synthetic>":
            self.skipped["synthetic"] += 1
            return
        key = m.get("id") if isinstance(m.get("id"), str) and m.get("id") else None
        if key is None:
            self.anon += 1
            key = "#anon-%d" % self.anon
        self.add(key, rec.get("timestamp"), values(m["usage"]))

    def add(self, key, ts, v):
        prev = self.recent.get(key)
        if prev is not None:
            new = [max(a, b) for a, b in zip(prev, v)]
            for i, (a, b) in enumerate(zip(prev, new)):
                self.tokens[i] += b - a
            c0, c1 = context(prev), context(new)
            self.ctx_sum += c1 - c0
            self.ctx_max = max(self.ctx_max, c1)
            for g in self.gaps:
                if g[3] == key:
                    g[4] = new[2] + new[3] + new[4]
            self.recent[key] = new
            self.recent.move_to_end(key)
            return
        self.calls += 1
        for i, x in enumerate(v):
            self.tokens[i] += x
        c = context(v)
        self.ctx_sum += c
        self.ctx_max = max(self.ctx_max, c)
        t = epoch(ts)
        if t is not None:
            if self.last is not None and t - self.last[0] > GAP:
                self.gaps.append([self.last[1], ts, t - self.last[0], key, v[2] + v[3] + v[4]])
            if self.first is None:
                self.first = (t, ts)
            if self.last is None or t >= self.last[0]:
                self.last = (t, ts)
        self.recent[key] = list(v)
        while self.keep is not None and len(self.recent) > self.keep:
            self.recent.popitem(last=False)

    def recent_list(self):
        return [[k, v] for k, v in self.recent.items()]

    def state(self):
        return {"tokens": self.tokens, "calls": self.calls, "ctx_sum": self.ctx_sum, "ctx_max": self.ctx_max,
                "first": self.first, "last": self.last, "gaps": self.gaps, "skipped": self.skipped, "anon": self.anon}

    @classmethod
    def load(cls, st):
        s = cls()
        if not isinstance(st, dict):
            return s
        try:
            s.tokens = [int(x) for x in st["tokens"]][:len(FIELDS)]
            s.tokens += [0] * (len(FIELDS) - len(s.tokens))
            s.calls, s.ctx_sum, s.ctx_max = int(st["calls"]), int(st["ctx_sum"]), int(st["ctx_max"])
            s.first = tuple(st["first"]) if st.get("first") else None
            s.last = tuple(st["last"]) if st.get("last") else None
            s.gaps = [list(g) for g in st.get("gaps") or []]
            s.skipped.update(st.get("skipped") or {})
            s.anon = int(st.get("anon") or 0)
            for k, v in st.get("recent") or []:
                s.recent[k] = [int(x) for x in v]
        except (KeyError, TypeError, ValueError):
            return cls()
        return s

    def report(self):
        t = dict(zip(FIELDS, self.tokens))
        units = {"read": t["read"] * W_READ,
                 "write": t["write_1h"] * W_1H + t["write_5m"] * W_5M + t["write_other"] * W_OTHER,
                 "output": t["output"] * W_OUTPUT, "input": t["input"] * W_INPUT}
        total = sum(units.values())
        units["total"] = total
        split = {k: (round(units[k] / total, 4) if total else 0.0) for k in ("read", "write", "output", "input")}
        return {"calls": self.calls, "tokens": t, "units": units, "split": split,
                "context_mean": round(self.ctx_sum / self.calls, 2) if self.calls else 0, "context_max": self.ctx_max,
                "first": self.first[1] if self.first else None, "through": self.last[1] if self.last else None,
                "gaps": [{"start": g[0], "end": g[1], "seconds": g[2], "rewrite": g[4]} for g in self.gaps],
                "skipped": dict(self.skipped)}


def feed(path, sums, offset=0, budget=None, final=False):
    """Parse `path` from byte `offset` to its last complete line into `sums`; returns the offset after the last line read.
    Only lines naming `usage` are decoded. With `final`, a cut last line counts as unreadable. With `budget` (seconds), stops
    at a line boundary once it is spent. Raises OSError when the file cannot be read."""
    deadline = None if budget is None else time.time() + budget
    with open(path, "rb") as f:
        f.seek(offset)
        buf = b""
        while True:
            chunk = f.read(CHUNK)
            if not chunk:
                break
            buf += chunk
            lines = buf.split(b"\n")
            buf = lines.pop()
            for line in lines:
                offset += len(line) + 1
                _line(sums, line)
            if deadline is not None and time.time() > deadline:
                return offset
    if final and buf.strip():
        sums.skipped["unreadable"] += 1
    return offset


def _line(sums, line):
    if b'"usage"' not in line:
        return
    try:
        rec = json.loads(line.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        sums.skipped["unreadable"] += 1
        return
    sums.add_record(rec)


def parse(path, sums=None):
    s = Sums(keep=None) if sums is None else sums
    feed(path, s, final=True)
    return s


def merged_in_span(path, first, last):
    """PRs the sdlc merge log records as merged between two ISO times, each (repo, PR) once; None when it cannot be read."""
    lo, hi = epoch(first), epoch(last)
    if lo is None or hi is None:
        return 0
    prs = set()
    try:
        f = open(path, encoding="utf-8")
    except OSError:
        return None
    with f:
        for raw in f:
            try:
                o = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(o, dict) or o.get("result") != "merged":
                continue
            t = epoch(o.get("time"))
            if t is None:
                continue
            if not (lo <= t <= hi):
                continue
            prs.add((o.get("repo"), o.get("pr")))
    return len(prs)


# --- running sums for pre-compact and the cost line ---------------------------------------------------------------------------

def sums_path(d, session):
    import hashlib
    return os.path.join(d, "cost", hashlib.sha256(session.encode("utf-8")).hexdigest()[:32] + ".json")


def read_state(p):
    try:
        with open(p, encoding="utf-8") as f:
            st = json.load(f)
        return st if isinstance(st, dict) else None
    except (OSError, ValueError):
        return None


def update(d, session, transcript, write_file, budget=TIME_BUDGET):
    """pre-compact: add the calls written since the saved offset; a shorter file or another path restarts at 0."""
    p = sums_path(d, session)
    state = read_state(p) or {}
    try:
        size = os.path.getsize(transcript)
    except (OSError, TypeError):
        return None
    offset = state.get("offset") if isinstance(state.get("offset"), int) else 0
    if state.get("transcript") != transcript or offset > size:
        state, offset = {}, 0
    sums = Sums.load(dict(state.get("sums") or {}, recent=state.get("recent")))
    offset = feed(transcript, sums, offset, budget=budget)
    state = {"transcript": transcript, "sums": sums.state(), "reported": state.get("reported")}
    state["offset"] = offset
    state["recent"] = sums.recent_list()
    cd = os.path.dirname(p)
    if not os.path.isdir(cd):
        os.mkdir(cd, 0o700)
    write_file(p, json.dumps(state, separators=(",", ":")) + "\n")
    old = sorted(glob.glob(os.path.join(cd, "*.json")), key=lambda f: os.path.getmtime(f) if os.path.exists(f) else 0)
    for f in old[:-KEPT]:
        with contextlib.suppress(OSError):
            os.unlink(f)
    return sums


def cached_report(d, session):
    """session-end: (the report of the saved sums, whether they changed since this session's last cost line), or (None,
    False) when this session never compacted. No transcript read."""
    state = read_state(sums_path(d, session))
    if not state or not isinstance(state.get("sums"), dict):
        return None, False
    return Sums.load(state["sums"]).report(), state.get("reported") != state.get("offset")


def mark_reported(d, session, write_file):
    """After session-end's cost line: the sums at this offset are reported, so a later session-end with no new compaction
    appends no second copy."""
    p = sums_path(d, session)
    state = read_state(p)
    if state:
        state["reported"] = state.get("offset")
        write_file(p, json.dumps(state, separators=(",", ":")) + "\n")


# --- the CLI's text -------------------------------------------------------------------------------------------------------------

def _n(x):
    return "{:,.0f}".format(x)


def _dur(seconds):
    h, m = int(seconds // 3600), int(seconds % 3600 // 60)
    return "%dh %02dm" % (h, m)


def text(name, r, merged=None):
    t, u, s = r["tokens"], r["units"], r["split"]
    sk = r["skipped"]
    out = ["brain cost · %s · %d calls (main thread); skipped: %d sidechain, %d <synthetic>, %d unreadable line%s"
           % (name, r["calls"], sk["sidechain"], sk["synthetic"], sk["unreadable"], "" if sk["unreadable"] == 1 else "s"),
           "split at A's weights (input 1x, cache read 0.05x, cache write 2x 1h / 1.25x 5m, output 5x): "
           "read %.1f%% · write %.1f%% · output %.1f%% · input %.1f%%"
           % (s["read"] * 100, s["write"] * 100, s["output"] * 100, s["input"] * 100),
           "units: %s base-input tokens — read %s · write %s · output %s · input %s"
           % (_n(u["total"]), _n(u["read"]), _n(u["write"]), _n(u["output"]), _n(u["input"])),
           "tokens: input %s · cache read %s · cache write %s (1h %s · 5m %s · no split %s) · output %s"
           % (_n(t["input"]), _n(t["read"]), _n(t["write_1h"] + t["write_5m"] + t["write_other"]), _n(t["write_1h"]),
              _n(t["write_5m"]), _n(t["write_other"]), _n(t["output"])),
           "context per call: mean %s · max %s" % (_n(r["context_mean"]), _n(r["context_max"])),
           "gaps over 1 h: %d" % len(r["gaps"])]
    for g in r["gaps"]:
        out.append("  %s → %s (%s), re-write %s" % (g["start"], g["end"], _dur(g["seconds"]), _n(g["rewrite"])))
    if merged is not None:
        out.append("merged PRs in the span: %d · units per merged PR %s"
                   % (merged, _n(u["total"] / merged) if merged else "n/a"))
    return "\n".join(out)
