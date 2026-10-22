#!/usr/bin/env python3
"""The probe's own hook logger (tests/live/brain-probe.sh), loaded through `claude --settings` for SessionStart, PreCompact and
PostCompact in both arms. It is the compaction's sure-positive that does not depend on the brain (arm C runs with BRAIN_OFF=1,
so the brain logs nothing there): one JSON line per event to $BRAIN_PROBE_LOG, and each PostCompact's compact_summary saved
0600 next to it. It prints nothing, so it injects nothing, and always exits 0.
"""
import json
import os
import sys
import time


def main():
    path = os.environ.get("BRAIN_PROBE_LOG", "")
    if not os.path.isabs(path):
        return
    try:
        inp = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        return
    if not isinstance(inp, dict):
        return
    summary = inp.get("compact_summary")
    line = {"t": time.time(), "event": inp.get("hook_event_name"), "session_id": inp.get("session_id"),
            "transcript_path": inp.get("transcript_path"), "source": inp.get("source"), "trigger": inp.get("trigger"),
            "summary_chars": len(summary) if isinstance(summary, str) else None}
    if isinstance(summary, str):
        d = path + ".summaries"
        os.makedirs(d, mode=0o700, exist_ok=True)
        name = os.path.join(d, "%s-%d.md" % (str(inp.get("session_id"))[:64], int(time.time() * 1000)))
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(summary)
        line["summary_file"] = name
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        os.write(fd, (json.dumps(line) + "\n").encode("utf-8"))
    finally:
        os.close(fd)


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # noqa: BLE001 — a logger must never block a session
        sys.stderr.write("brain-probe log hook: %s\n" % e.__class__.__name__)
    sys.exit(0)
