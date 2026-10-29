#!/usr/bin/env python3
"""Did the brain's SessionStart strings reach the model whole? Read a Claude Code transcript and the brain's Episode Log.

    python3 tests/live/brain-transcript-check.py <transcript.jsonl> --episodes <state dir>/episodes.jsonl --ids X1,S1,F1
            [--source compact|startup|resume|clear|any]
    python3 tests/live/brain-transcript-check.py --record <dir>     record the fixtures (a nested `claude` that needs no login)

For each SessionStart of the source (default `compact`) in the transcript, the `hook_additional_context` attachment holds what
reached the model: each brain string (`# vibemaestro-brain`, `## Brain · sessions`, `## Brain · plan`) is `inline` with its size,
`persisted` (Claude Code replaced it whole by a `<persisted-output>` preview: it was over the cap) or absent. The k-th SessionStart
of the source is paired with the k-th `session-start` line of the episode log with that source and the transcript's session
(its lines' `sessionId`).

Clean when, at every SessionStart: string 1 is inline; strings 2 and 3 are inline, or absent while the episode line says they
injected 0 or comes from an older brain (no field for them: a compaction before the upgrade, in the same transcript); an inline string has the size the episode line counted; each id of --ids is an item line of one of its strings.
rc 0 clean, 1 a check failed, 2 usage or no SessionStart of the source found. Standard library only.

--record writes three fixtures under <dir>, each a transcript and an episode log trimmed to the SessionStart lines, paths
replaced by `<scratch>`: `three-strings` (all three inline; ids X1, S1, F1), `no-sessions` (no S or Q: string 2 absent, its
episode line 0; ids X1, F1) and `plan-over-cap` (a copy of this checkout's brain with string 3's own cut raised past 10,000 and a
plan part over it: Claude Code persists it). Paths, and Claude Code's name for the project directory, read `<scratch>`. Each is a real run of this checkout's hooks under `claude -p` in a scratch config,
HOME and state root (the copy's manifest without its dependency on vibemaestro-sdlc, which a --plugin-dir load cannot resolve;
the SessionStart hooks do not use sdlc): the hooks run and the transcript is written before the API call is refused, so nothing
is spent.
"""
import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HEADS = (("1", "# vibemaestro-brain"), ("2", "## Brain · sessions"), ("3", "## Brain · plan"))
FIELDS = {"1": "injected", "2": "injected_sessions", "3": "injected_plan"}


def events(path, source):
    """[(source, [content strings])] of the SessionStart hook_additional_context attachments, in order."""
    out, last = [], None
    for line in open(path, encoding="utf-8"):
        try:
            o = json.loads(line)
        except ValueError:
            continue
        a = o.get("attachment") if isinstance(o, dict) else None
        if not isinstance(a, dict):
            continue
        name = a.get("hookName") or ""
        if a.get("type") in ("hook_success", "hook_non_blocking_error") and name.startswith("SessionStart:"):
            last = name.split(":", 1)[1]
        elif a.get("type") == "hook_additional_context" and a.get("hookEvent") == "SessionStart":
            if source in ("any", last):
                out.append((last, [c for c in a.get("content") or [] if isinstance(c, str)]))
    return out


def episode_lines(path, session, source):
    out = []
    for line in open(path, encoding="utf-8"):
        try:
            o = json.loads(line)
        except ValueError:
            continue
        if (isinstance(o, dict) and o.get("kind") == "session-start" and o.get("session") == session
                and (source == "any" or o.get("source") == source)):
            out.append(o)
    return out


def classify(contents):
    """{string number: ("inline", text) | ("persisted", preview)} of the brain strings among one SessionStart's contents."""
    found = {}
    for c in contents:
        for n, head in HEADS:
            if c.startswith(head):
                found[n] = ("inline", c)
            elif c.startswith("<persisted-output>") and head in c:
                found[n] = ("persisted", c)
    return found


def session_of(transcript):
    """The transcript's session id: its lines' `sessionId`, else its file name (Claude Code names it after the session)."""
    for line in open(transcript, encoding="utf-8"):
        try:
            sid = json.loads(line).get("sessionId")
        except (ValueError, AttributeError):
            continue
        if isinstance(sid, str) and sid:
            return sid
    return os.path.splitext(os.path.basename(transcript))[0]


def check(transcript, episodes, ids, source):
    session = session_of(transcript)
    evs = events(transcript, source)
    if not evs:
        print("no SessionStart%s in %s" % ("" if source == "any" else ":" + source, transcript))
        return 2
    eps = episode_lines(episodes, session, source)
    bad = 0
    for k, (src, contents) in enumerate(evs, 1):
        ep = eps[k - 1] if k - 1 < len(eps) else None
        found, fails, parts = classify(contents), [], []
        if ep is None:
            fails.append("no session-start episode line for it")
        for n, _ in HEADS:
            how, text = found.get(n, (None, ""))
            want = ep.get(FIELDS[n]) if ep else None
            older = ep is not None and (ep.get("format") if isinstance(ep.get("format"), int) else 1) < 3
            if n != "1" and older and FIELDS[n] not in ep and how is None:
                parts.append("string %s none (an older brain, format %s)" % (n, ep.get("format", 1)))
                continue
            if how == "inline":
                parts.append("string %s inline %s" % (n, "{:,}".format(len(text))))
                if isinstance(want, int) and want != len(text):
                    fails.append("string %s is %d characters, the episode line counted %d" % (n, len(text), want))
            elif how == "persisted":
                parts.append("string %s persisted" % n)
                fails.append("string %s was replaced by a preview: over the cap" % n)
            else:
                parts.append("string %s absent" % n)
                if n == "1" or want != 0:
                    fails.append("string %s is absent while the episode line says %r" % (n, want))
        shown = "\n".join(t for how, t in found.values() if how == "inline")
        missing = [i for i in ids if not re.search(r"(?m)^- %s " % re.escape(i), shown)]
        if ids:
            parts.append("ids %s" % ("found" if not missing else "missing " + ", ".join(missing)))
        if missing:
            fails.append("ids not found: %s" % ", ".join(missing))
        bad += bool(fails)
        print("SessionStart:%s %d · %s · %s" % (src, k, " · ".join(parts), "clean" if not fails else "FAIL: " + "; ".join(fails)))
    return 1 if bad else 0


# --- --record ---------------------------------------------------------------------------------------------------------------

SEED = r"""
import json, sys
sys.path.insert(0, sys.argv[1])
import brain_store as s
d = s.state_dir(sys.argv[2])
by = {"session": "rec", "agent": None}
kinds = {v: k for k, v in s.KINDS.items()}
s.ensure_dir(d)
raw = s.append(d, [], {"op": "claim", "t": s.now_iso(), "by": by, "takeover": False})
for spec in sys.argv[3:]:
    iid, _, text = spec.partition("=")
    item = {"id": iid, "kind": kinds[iid[0]], "pinned": iid[0] == "D", "text": text, "expires": None, "links": [], "anchors": [],
            "source": {"type": "owner", "quote": "the owner's words", "where": "chat"} if iid[0] in "DW" else {"type": "coordinator"},
            "supersedes": None}
    raw = s.append(d, raw, {"op": "owner-add" if iid[0] in "DW" else "add", "t": s.now_iso(), "item": item, "by": by})
s.write_caches(d, s.fold([json.loads(b) for b in raw]), s.head_of(raw))
"""
FIXTURES = {
    "three-strings": ["D1=ship R4 after the gate", "N1=fix the parser", "S1=w-auth: review round 2, then the docs",
                      "Q1=owner: approve the budget", "X1=release 0.3.0", "T1=never edit the log by hand",
                      "F1=kit CLI: ~/bin/kit"],
    "no-sessions": ["N1=fix the parser", "X1=release 0.3.0", "F1=kit CLI: ~/bin/kit"],
    "plan-over-cap": ["N1=fix the parser"] + ["T%d=%s" % (i, "t" * 150) for i in range(1, 61)],
}


def record(out):
    claude = shutil.which("claude")
    if not claude:
        print("skip: claude is not on PATH")
        return 2
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    os.makedirs(out, exist_ok=True)
    for name, specs in FIXTURES.items():
        t = os.path.realpath(tempfile.mkdtemp(prefix="brain-rec-"))
        try:
            brain = os.path.join(t, "brain")
            shutil.copytree(os.path.join(root, "plugins", "vibemaestro-brain"), brain,
                            ignore=shutil.ignore_patterns("__pycache__"))
            man = os.path.join(brain, ".claude-plugin", "plugin.json")   # --plugin-dir cannot resolve its dependency on sdlc
            m = json.load(open(man, encoding="utf-8"))
            m.pop("dependencies", None)
            json.dump(m, open(man, "w", encoding="utf-8"))
            if name == "plan-over-cap":                  # string 3's own cut raised past Claude Code's cap
                p = os.path.join(brain, "scripts", "brain_store.py")
                src = open(p, encoding="utf-8").read()
                assert src.count("STRING_MAX = 9500 ") == 1
                open(p, "w", encoding="utf-8").write(src.replace("STRING_MAX = 9500 ", "STRING_MAX = 20000 "))
            proj, cfg, home, state = (os.path.join(t, x) for x in ("project", "config", "home", "state"))
            for x in (proj, cfg, home, state, os.path.join(t, "tmp")):
                os.makedirs(x)
            subprocess.run(["git", "init", "-q", proj], check=True)
            env = {"HOME": home, "PATH": os.path.dirname(claude) + ":/usr/local/bin:/usr/bin:/bin", "CLAUDE_CONFIG_DIR": cfg,
                   "XDG_STATE_HOME": state, "TMPDIR": os.path.join(t, "tmp"), "PYTHONDONTWRITEBYTECODE": "1"}
            subprocess.run([sys.executable, "-c", SEED, os.path.join(brain, "scripts"), proj] + specs, env=env, check=True)
            subprocess.run([claude, "-p", "hi", "--plugin-dir", brain], cwd=proj, env=env, stdin=subprocess.DEVNULL,
                           capture_output=True, timeout=120)
            tr = (glob.glob(os.path.join(cfg, "projects", "*", "*.jsonl")) or [None])[0]
            eps = (glob.glob(os.path.join(state, "vibemaestro", "brain", "*", "episodes.jsonl")) or [None])[0]
            if not tr or not eps:
                print("skip: %s: no transcript or episode log was written" % name)
                return 2
            slug = re.sub(r"[^A-Za-z0-9]", "-", t)           # Claude Code's name for the project's directory under projects/
            scrub = lambda text: text.replace(t, "<scratch>").replace(slug, "<scratch>")
            keep = []
            for line in open(tr, encoding="utf-8"):
                o = json.loads(line)
                a = o.get("attachment") if isinstance(o, dict) else None
                if isinstance(a, dict) and (a.get("hookEvent") == "SessionStart" or str(a.get("hookName", "")).startswith("SessionStart")):
                    keep.append(scrub(json.dumps({"type": o.get("type"), "attachment": a, "sessionId": o.get("sessionId")},
                                                 ensure_ascii=False)))
            with open(os.path.join(out, name + ".jsonl"), "w", encoding="utf-8") as f:
                f.write("\n".join(keep) + "\n")
            with open(os.path.join(out, name + ".episodes.jsonl"), "w", encoding="utf-8") as f:
                f.writelines(scrub(l) for l in open(eps, encoding="utf-8") if '"kind":"session-start"' in l)
            print("recorded %s: %d transcript lines" % (name, len(keep)))
        finally:
            shutil.rmtree(t, ignore_errors=True)
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("transcript", nargs="?")
    ap.add_argument("--episodes")
    ap.add_argument("--ids", default="")
    ap.add_argument("--source", default="compact", choices=["compact", "startup", "resume", "clear", "any"])
    ap.add_argument("--record", metavar="DIR")
    a = ap.parse_args()
    if a.record:
        return record(a.record)
    if not (a.transcript and a.episodes):
        ap.print_usage()
        return 2
    return check(a.transcript, a.episodes, [i for i in a.ids.split(",") if i], a.source)


if __name__ == "__main__":
    sys.exit(main())
