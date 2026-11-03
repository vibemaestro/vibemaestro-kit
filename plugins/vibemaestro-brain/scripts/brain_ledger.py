"""vibemaestro-brain ledger: what each rule's evidence says, and what the thresholds make of it, read from the log.

A rule is a live decision (D), a trap or lesson (T), a fact (F), or a rule of CLAUDE.md by its code (`S07`, shown `[S07]`). The
session records `held` and `broke` (`brain op held|broke`, a trap's `brain op hit`) and a goal's progress (`brain op progress`)
as ops in the hash-chained log. The ledger is computed from those ops whenever it is read, never kept in the fold or a cache: a
compaction loses nothing, the chain guards every entry, and an older brain's log folds as it did. Each event counts under the
rule it was written for.

The thresholds (`ledger` in .vibemaestro/brain.json) mark a rule in `brain ledger` and the record: `promote?` (it held enough to
pin it, or to write it into CLAUDE.md), `drift` (it broke too often of late), `dormant` (an item untouched). The review card
names the dormant items after a compaction; `brain ledger --record` prints the measurement record of a period. Standard
library only.
"""
import json
import math
import os
import re
import time

import brain_store as s

DAY = 86400
RECORD_EVERY = 30           # days after the last record printed (or the first evidence) that the next one is due
RECORD_TAIL = 4 * 1024 * 1024   # bytes of the Episode Log a record reads for the compactions of its period
RECORD_FILE = "ledger-record.json"   # the time of the last full record (at least RECORD_EVERY days), read by the card's due line
RULE_LETTERS = s.RULE_LETTERS
NOUNS = {"G": "goal", "D": "decision", "W": "window", "P": "focus", "R": "request", "N": "Now item", "S": "session",
         "Q": "owner-queue item", "X": "Next item", "T": "trap", "F": "fact"}
CODE = s.SOUL_CODE.pattern                                # one spelling per code: S07, S12, S120 (never S014 beside S14)
CODE_ARG = re.compile(r"\[(%s)\]|(%s)" % (CODE, CODE))       # on the command line, brackets optional (a bracket is a shell glob)
DEFAULTS = s.LEDGER_DEFAULTS


def th():
    """The thresholds in force: the project's `ledger` keys over the defaults."""
    return s.conf()["ledger"]


def plural(n, word):
    return "%d %s%s" % (n, word, "" if n == 1 else "s")


def day(t):
    return s.now_iso(t)[:10]


def mmdd(t):
    return s.now_iso(t)[5:10]


# --- the rule a command names -------------------------------------------------------------------------------------------------

def rule_arg(rule, hit=False):
    """("soul", "S07") or ("id", "D3") for a command's RULE; a trap hit takes an item id only. Refused (64) otherwise."""
    m = CODE_ARG.fullmatch(rule or "")
    if m and not hit:
        return "soul", m.group(1) or m.group(2)
    if s.ID_RE.fullmatch(rule or ""):
        return "id", rule
    if hit:
        raise s.Refused(64, "hit names a trap, like T5")
    raise s.Refused(64, "RULE names a decision D3, a trap T5, a fact F2 or a SOUL code like [S07] (S and two digits, or "
                        "three with no leading zero)")


# --- the ledger, read from the log -------------------------------------------------------------------------------------------

def read(ops):
    """{key: {"key", "events"}}: every evidence and progress op of the log in log order, keyed by the item id or `[S07]` it was
    written for. An event: {"t", "time", "seq", "result" (held, broke or progress), "session" (a session item's id, or `~` and
    the writing session), "pointer", "differed", "measure", "via"}."""
    out = {}
    for op in ops:
        kind = op.get("op")
        if kind in ("evidence", "progress"):
            k = op.get("id") or "[%s]" % op.get("soul")
            who = op.get("session") or "~" + str((op.get("by") or {}).get("session") or "")
            out.setdefault(k, {"key": k, "events": []})["events"].append(
                {"t": op.get("t"), "time": s.parse_iso(op.get("t") or "") or 0, "seq": op.get("seq") or 0,
                 "result": op.get("result") if kind == "evidence" else "progress", "session": who,
                 "pointer": op.get("pointer"), "differed": op.get("differed"), "measure": op.get("measure"),
                 "via": op.get("via")})
    return out


def snapshot(d):
    """(state, ops, ledger) of the state directory `d`, read under the lock; empty when it holds no state yet."""
    if not os.path.isdir(d):
        return s.empty_state(), [], {}
    with s.locked(d):
        _, st, ops = s.load_ops(d)
    return st, ops, read(ops)


def label(session):
    return "session " + session[1:9] if session.startswith("~") else session


def split(events):
    return ([e for e in events if e["result"] == "held"], [e for e in events if e["result"] == "broke"])


def sessions(events):
    return {e["session"] for e in events}


def summary(events):
    held, broke = split(events)
    return "held %d from %s, broke %d" % (len(held), plural(len(sessions(held)), "session"), len(broke))


def state_of(st, key):
    """(state, other): ("live", None) for a live or queued item rule, ("active", None) for a code of CLAUDE.md, and for the
    others ("superseded", successor), ("closed"|"archived"|"gone", None)."""
    if key.startswith("["):
        return "active", None
    it = st["items"].get(key)
    if it is None:
        return "gone", None
    if it["status"] in ("live", "queued"):
        return "live", None
    if it["status"] == "superseded":
        return "superseded", s.last_of(st, key)
    return it["status"], None


def kind_word(led, key):
    """What the rule `key` is: SOUL (a code), goal, decision, or a lesson (a trap or fact that held) or an observation."""
    if key.startswith("["):
        return "SOUL"
    letter = key[0]
    if letter == "G":
        return "goal"
    if letter == "D":
        return "decision"
    held, _ = split((led.get(key) or {}).get("events") or [])
    return "lesson" if held else "observation"


def order(key):
    """Sections' order, then the number; the SOUL codes last."""
    if key.startswith("["):
        return (99, int(key[2:-1]), key)
    letters = [l for l, _ in s.SECTIONS]
    return (letters.index(key[0]) if key[0] in letters else 98, int(key[1:]) if key[1:].isdigit() else 0, key)


# --- the thresholds -----------------------------------------------------------------------------------------------------------

def promote_ok(events, now, t):
    """At least promote_held held from promote_sessions sessions, the first and last promote_days apart, no broke in the last
    promote_clean_days days."""
    held, broke = split(events)
    if len(held) < t["promote_held"] or len(sessions(held)) < t["promote_sessions"]:
        return False
    times = [e["time"] for e in held]
    if max(times) - min(times) < t["promote_days"] * DAY:
        return False
    return not any(now - e["time"] < t["promote_clean_days"] * DAY for e in broke)


def drift_of(events, now, t):
    """(broke, checks, sessions that broke) of the last drift_days days when the rule drifts: drift_broke broke from
    drift_sessions sessions, or at least drift_checks checks with a broke in one of every drift_one_in; None otherwise."""
    w = [e for e in events if e["result"] in ("held", "broke") and now - e["time"] < t["drift_days"] * DAY]
    b = [e for e in w if e["result"] == "broke"]
    if b and ((len(b) >= t["drift_broke"] and len(sessions(b)) >= t["drift_sessions"])
              or (len(w) >= t["drift_checks"] and len(b) * t["drift_one_in"] >= len(w))):
        return len(b), len(w), len(sessions(b))
    return None


def last_seen(led):
    """{key: the time of its last event}."""
    return {k: max(e["time"] for e in v["events"]) for k, v in led.items() if v["events"]}


def dormant(st, ops, led, now, t=None):
    """The live items of every section but G (its review day) and W (its expiry) whose last activity, the time of the op their
    `touched` names or their last ledger event, is dormant_days days old or older: by section, then id."""
    t = t or th()
    last, out = last_seen(led), []
    for letter, _ in s.SECTIONS:
        if letter in ("G", "W"):
            continue
        for it in sorted(s.live(st, letter), key=lambda i: int(i["id"][1:])):
            seq = it.get("touched")
            when = s.parse_iso(ops[seq - 1].get("t") or "") if isinstance(seq, int) and 0 < seq <= len(ops) else None
            times = [x for x in (when, last.get(it["id"])) if x is not None]
            if times and now - max(times) >= t["dormant_days"] * DAY:
                out.append(it["id"])
    return out


def standing(st, led, key, now, t):
    """What the thresholds say of the rule `key` now: a subset of ["promote?", "drift"], empty for a rule that is not live and
    for a goal."""
    state, _ = state_of(st, key)
    events = (led.get(key) or {}).get("events") or []
    if state not in ("live", "active") or key[0] == "G":
        return []
    out = []
    if not key.startswith("[") and st["items"][key]["status"] == "live" and promote_ok(events, now, t):
        out.append("promote?")
    if drift_of(events, now, t):
        out.append("drift")
    return out


# --- a goal's progress -------------------------------------------------------------------------------------------------------

def chain(st, iid):
    """`iid` and every item its supersede chain came from."""
    out, it = [], st["items"].get(iid)
    while it is not None and it["id"] not in out:
        out.append(it["id"])
        it = st["items"].get(it.get("supersedes")) if it.get("supersedes") else None
    return out


def progress_of(st, led, gid):
    """The last progress event of the goal `gid` or of a goal it superseded, None when it has none."""
    evs = [e for k in chain(st, gid) for e in (led.get(k) or {}).get("events", []) if e["result"] == "progress"]
    return max(evs, key=lambda e: (e["time"], e["seq"])) if evs else None


def goal_parts(st, led, gid):
    """The progress part of a goal's line on the card and in the ledger."""
    p = progress_of(st, led, gid)
    return ('progress "%s" (%s)' % (s.clean_line(p["measure"] or ""), mmdd(p["time"])) if p else "no progress yet",)


# --- the review card's ledger lines -------------------------------------------------------------------------------------------

def record_since(d, led):
    """The time the next record counts from: the last full record's (`ledger-record.json`, which `brain ledger --record`
    writes for a record of at least RECORD_EVERY days), else the first evidence or progress op; None when the ledger is
    empty and no full record was printed."""
    try:
        with open(os.path.join(d, RECORD_FILE), encoding="utf-8") as f:
            t = json.loads(f.read()).get("t")
        if isinstance(t, (int, float)) and not isinstance(t, bool) and math.isfinite(t) and t <= time.time() + 3600:
            return float(t)                         # a hand-made NaN, infinity or future time would hide the line for good
    except (OSError, ValueError, AttributeError, OverflowError):   # an integer past a float's range: not a time either
        pass
    times = [e["time"] for v in led.values() for e in v["events"]]
    return min(times) if times else None


def recorded(d, days, now=None):
    """After `brain ledger --record --days N`: one `ledger-record` line in the Episode Log, and, for a record of at least
    RECORD_EVERY days, its time in `ledger-record.json` (a shorter one is a look, and leaves the monthly clock alone)."""
    now = time.time() if now is None else now
    s.episode_line(d, s.session_id(), "ledger-record", days=days)
    if days >= RECORD_EVERY:
        s._write_file(os.path.join(d, RECORD_FILE), s.dumps({"t": now, "days": days}) + "\n")


def episodes(d, nbytes):
    """The Episode Log's lines of its last `nbytes` bytes, as dicts."""
    try:
        with open(os.path.join(d, "episodes.jsonl"), "rb") as f:
            f.seek(0, os.SEEK_END)
            f.seek(max(0, f.tell() - nbytes))
            data = f.read()
    except OSError:
        return []
    out = []
    for b in data.split(b"\n"):
        try:
            o = json.loads(b)
        except ValueError:
            continue
        if isinstance(o, dict):
            out.append(o)
    return out


def card(st, ops, now, d=None):
    """{"goals" ({gid: parts}), "dormant", "record"}: the card's ledger lines (each a line or None) and each goal's progress
    part; `d`, the state directory, holds the last record's time."""
    led, t = read(ops), th()
    since = record_since(d, led) if d else None
    out = {"goals": {g["id"]: goal_parts(st, led, g["id"]) for g in s.live(st, "G")}}
    dorm = dormant(st, ops, led, now, t)
    out["dormant"] = s.fit_items("dormant (%d d): " % t["dormant_days"], dorm, " ") if dorm else None
    out["record"] = ("ledger record due: %d d since %s (brain ledger --record)" % ((now - since) // DAY, mmdd(since))
                     if since is not None and now - since >= RECORD_EVERY * DAY else None)
    return out


# --- what a write checks ------------------------------------------------------------------------------------------------------

def check_rule_item(st, iid, hit=False):
    """A live (or queued) D, T or F item `iid` for a held or broke; a trap for a hit. Refused (1) with the reason otherwise."""
    it = st["items"].get(iid)
    if it is None:
        raise s.Refused(1, "%s is not an item of this brain" % iid)
    letter = iid[0]
    if hit and letter != "T":
        raise s.Refused(1, "hit counts traps only")
    if letter == "G":
        raise s.Refused(1, "%s is a goal: a goal carries a progress measure (`brain op progress %s --measure M --pointer P`), "
                           "not held or broke" % (iid, iid))
    if letter not in RULE_LETTERS:
        raise s.Refused(1, "%s is a %s, not a rule: held and broke count a decision (D), a trap or lesson (T), a fact (F) or a "
                           "SOUL code like [S07]" % (iid, NOUNS.get(letter, "kind")))
    if it["status"] == "live" or (hit and it["status"] == "queued"):
        return it
    if it["status"] == "queued":
        raise s.Refused(1, "%s waits in the overflow queue: held and broke count once it moves up (a hit on a queued trap "
                           "counts, as a held)" % iid)
    if it["status"] == "superseded":
        nxt = s.last_of(st, iid)
        raise s.Refused(1, "%s is superseded by %s: record against %s" % (iid, nxt, nxt))
    raise s.Refused(1, "%s is not live (%s): evidence counts for a live rule" % (iid, it["status"]))


def check_session(st, session):
    """The root of the supersede chain of the session item `session` (one session keeps one identity); refused (1) otherwise."""
    it = st["items"].get(session) if isinstance(session, str) else None
    if it is None or session[0] != "S":
        raise s.Refused(1, "--session names a session item of this brain, like S4 (%s is not one)" % session)
    return s.chain_root(st, it)["id"]


# --- brain ledger -------------------------------------------------------------------------------------------------------------

def line(st, led, key, now):
    """`D3 · decision · held 7 from 4 sessions · broke 0 · last 11-01 owner/name#N` and its state and standing; a goal's line
    carries its progress instead."""
    e = led.get(key) or {"events": []}
    head = "%s · %s" % (key, kind_word(led, key))
    if key[0] == "G":
        return "%s · %s" % (head, goal_parts(st, led, key)[0])
    if not [x for x in e["events"] if x["result"] in ("held", "broke")]:
        out = head + " · no evidence yet"
    else:
        held, broke = split(e["events"])
        last = e["events"][-1]
        out = "%s · held %d from %s · broke %d · last %s %s" % (head, len(held), plural(len(sessions(held)), "session"),
                                                               len(broke), mmdd(last["time"]), s.clean_line(last["pointer"] or "-"))
    state, other = state_of(st, key)
    if state == "superseded":
        out += " · superseded by %s" % other
    elif state not in ("live", "active"):
        out += " · %s" % state
    return out + "".join(" · " + tag for tag in standing(st, led, key, now, th()))


def table(st, ops, led, now):
    keys = sorted(set(led) | {g["id"] for g in s.live(st, "G")}, key=order)
    if not keys:
        return "the ledger is empty: no held, broke or progress yet"
    dorm = set(dormant(st, ops, led, now))
    return "\n".join(line(st, led, k, now) + (" · dormant" if k in dorm else "") for k in keys)


def rule_key(st, rule):
    """The ledger key of `brain ledger RULE`: a SOUL code, or a D, T, F or G item of this brain."""
    kind, value = rule_arg(rule)
    if kind == "soul":
        return "[%s]" % value
    it = st["items"].get(value)
    if it is None:
        raise s.Refused(1, "%s is not an item of this brain" % value)
    if value[0] not in RULE_LETTERS + ("G",):
        raise s.Refused(1, "%s is a %s, not a rule: the ledger counts decisions, traps and lessons, facts, SOUL codes and "
                           "goals' progress" % (value, NOUNS.get(value[0], "kind")))
    return value


def events_text(st, led, key, now):
    e = led.get(key) or {"events": []}
    out = [line(st, led, key, now)]
    for x in e["events"]:
        what = ('"%s"' % s.clean_line(x["measure"] or "") if x["result"] == "progress" else x["result"]
                + (" (a trap hit)" if x.get("via") == "hit" else ""))
        out.append("%s %s %s %s%s" % (s.now_iso(x["time"])[:16].replace("T", " ") + "Z", what, label(x["session"]),
                                     s.clean_line(x["pointer"] or "-"),
                                     ": " + s.clean_line(x["differed"]) if x.get("differed") else ""))
    return "\n".join(out)


# --- the measurement record ---------------------------------------------------------------------------------------------------

def crossings(st, led):
    """{key: [(time, "drift"|"promote", key)]}: each time a rule entered drift or became a promotion candidate, replayed at
    each event's time and at each time a window lets an event go (a check leaving the drift window, a broke leaving the clean
    days), so a candidate that appears with time is seen, until the rule ends (an item closed, superseded or archived). A code
    of CLAUDE.md is never a promotion candidate."""
    t, out = th(), {}
    for key, e in led.items():
        if key[0] == "G":
            continue
        evs = sorted([x for x in e["events"] if x["result"] in ("held", "broke")], key=lambda x: (x["time"], x["seq"]))
        it = st["items"].get(key) if not key.startswith("[") else None
        end = s.parse_iso(it.get("retired") or "") if it is not None and it["status"] not in ("live", "queued") else None
        times = sorted({x["time"] for x in evs} | {x["time"] + t["drift_days"] * DAY for x in evs}
                       | {x["time"] + t["promote_clean_days"] * DAY for x in evs if x["result"] == "broke"})
        was = {"drift": False, "promote": False}
        for at in times:
            if end is not None and at > end:        # times are whole seconds: an entry of the end's own second came before it
                break
            upto = [x for x in evs if x["time"] <= at]
            now = {"drift": bool(drift_of(upto, at, t)), "promote": not key.startswith("[") and promote_ok(upto, at, t)}
            for k in ("drift", "promote"):
                if now[k] and not was[k]:
                    out.setdefault(key, []).append((at, k, key))
            was = now
    return out


def record(d, st, ops, led, now, days, project):
    """The body of a measurement record of the last `days` days, in Markdown, read from the log and the Episode Log."""
    t, t0 = th(), now - days * DAY
    inside = lambda x: x is not None and t0 <= x <= now
    off = ["%s %d" % (k, v) for k, v in sorted(t.items()) if v != DEFAULTS[k]]
    out = ["# brain ledger record: %s · %s to %s (%d d)" % (project, day(t0), day(now), days), "",
           "Thresholds: promote %d held from %d sessions over %d d, no broke in %d d · drift %d broke from %d sessions, or a broke "
           "in 1 of every %d of at least %d checks, in %d d · dormant %d d (%s)" % (
               t["promote_held"], t["promote_sessions"], t["promote_days"], t["promote_clean_days"], t["drift_broke"],
               t["drift_sessions"], t["drift_one_in"], t["drift_checks"], t["drift_days"], t["dormant_days"],
               "ledger: " + ", ".join(off) if off else "the defaults"), "", "## Rules", ""]
    dorm = set(dormant(st, ops, led, now, t))
    rules = [k for k in sorted(led, key=order) if k[0] != "G"]
    for key in rules:
        held, broke = split(led[key]["events"])
        hp, bp = [e for e in held if inside(e["time"])], [e for e in broke if inside(e["time"])]
        state, other = state_of(st, key)
        stand = standing(st, led, key, now, t) + (["dormant"] if key in dorm else [])
        if state not in ("live", "active"):
            stand.append("%s%s" % (state, " to %s" % other if other else ""))
        out.append("- %s · %s · held %d / %d from %s · broke %d / %d · %s" % (
            key, kind_word(led, key), len(hp), len(held), plural(len(sessions(held)), "session"), len(bp), len(broke),
            ", ".join(stand) or "none"))
    if not rules:
        out.append("- none")
    out += ["", "## Crossings", ""]
    cross, entered, lines = crossings(st, led), {}, []
    for key, xs in cross.items():
        for when, kind, name in xs:
            if kind == "drift":
                entered[name] = min(entered.get(name, when), when)
            if inside(when):
                lines.append((when, "- %s: %s on %s" % ("drift" if kind == "drift" else "promote candidate", name, day(when))))
    for op in ops:
        when = s.parse_iso(op.get("t") or "")
        if not inside(when):
            continue
        k, iid = op.get("op"), op.get("id")
        if k == "owner-promote":
            lines.append((when, "- moved out by the owner: %s to %s on %s" % (iid, s.clean_line(op.get("pointer") or "-"),
                                                                              day(when))))
        elif k in ("supersede", "close", "owner-supersede", "owner-unpin") and iid in entered and entered[iid] <= when:
            how = {"supersede": "superseded", "close": "closed", "owner-supersede": "superseded by the owner",
                   "owner-unpin": "unpinned by the owner"}[k]
            lines.append((when, "- way back: %s %s on %s, after its drift" % (iid, how, day(when))))
    out += [l for _, l in sorted(lines, key=lambda x: x[0])] or ["- none"]
    out += ["", "## Goals' progress", ""]
    prog = []
    for key in sorted((k for k in led if k[0] == "G"), key=order):
        evs = [e for e in led[key]["events"] if e["result"] == "progress" and inside(e["time"])]
        if evs:
            prog.append("- %s: %s" % (key, " · ".join('%s "%s" (%s)' % (mmdd(e["time"]), s.clean_line(e["measure"] or ""),
                                                                       s.clean_line(e["pointer"] or "-")) for e in evs)))
    out += prog or ["- none"]
    out += ["", "## Dormant at the end", ""]
    by = {}
    for iid in dormant(st, ops, led, now, t):
        by.setdefault(iid[0], []).append(iid)
    out.append("- " + " · ".join("%s: %s" % (dict(s.SECTIONS)[l].split(" (")[0], " ".join(ids)) for l, ids in
                                 sorted(by.items(), key=lambda x: order(x[0] + "1"))) if by else "- none")
    out += ["", "## Capacity at the end", ""]
    out.append("- " + " · ".join("%s %d/%d" % (title.split(" (")[0], len(s.live(st, l)), s.cap(l)) for l, title in s.SECTIONS)
               + ("; queued: " + ", ".join("%s %d" % q for q in s.queue_counts(st)) if s.queue_counts(st) else ""))
    out += ["", "## Compactions", ""]
    comp = [o for o in episodes(d, RECORD_TAIL) if o.get("kind") == "compact" and inside(s.parse_iso(o.get("t") or ""))]
    scores = ["%.2f" % o["loss"] if isinstance(o.get("loss"), (int, float)) and not isinstance(o.get("loss"), bool) else "none"
              for o in comp]
    out.append("- %d in the period%s" % (len(comp), "; loss scores: " + ", ".join(scores) if scores else ""))
    if s.extension_roots():                         # a plugin that extends the brain adds its own section
        import brain_ext
        out += brain_ext.record_lines(d, st, ops, days, t0, now)
    return "\n".join(out)
