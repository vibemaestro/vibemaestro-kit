#!/usr/bin/env python3
"""PreToolUse Bash hook of vibemaestro-sdlc: the owner's dialog for `baton … sign --by owner` and for a mode change
(`baton … mode manual|auto|trust|untrust …`) (baton.py guard_owner).

On a literal call of either it answers `ask`, so Claude Code shows its dialog whatever the settings say, and writes the
record that the call needs; it denies where no owner answers the dialog (a sandbox, a subagent, plan, dontAsk,
bypassPermissions, a -p run, an answering hook). Every Bash call voids the session's unused record. It runs whatever the repo's
`hooks` config says: silencing it would only leave the owner unable to sign. Fail-open: an error is one line on stderr and rc 0,
which writes no record, so `sign --by owner` and the mode change refuse.
"""
import json
import os
import re
import sys

sys.dont_write_bytecode = True


# a mode change (baton.MODE_WRITES) after `mode`, quoted or escaped too: the shell's words, which guard_owner reads, drop those
MODE_WORDS = re.compile(r"\bmode[\s\"'\\]*(?:manual|auto|trust|untrust)")


def asked_dir():
    """baton.asked_dir() without importing baton (2,700 lines) on every Bash call."""
    x = os.environ.get("XDG_STATE_HOME", "")
    base = x if os.path.isabs(x) else os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(base, "vibemaestro", "baton", "asked")


def main():
    inp = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace") or "{}")
    if not isinstance(inp, dict):
        return 0
    cmd = str((inp.get("tool_input") or {}).get("command") or "") if isinstance(inp.get("tool_input"), dict) else ""
    if not (("sign" in cmd and "owner" in cmd) or MODE_WORDS.search(cmd)):   # the command only, not cwd or transcript_path
        try:
            if not os.listdir(asked_dir()):
                return 0
        except FileNotFoundError:
            return 0
        except OSError:
            pass                                        # any doubt takes the full path
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import baton
    out = baton.guard_owner(inp)
    if out:
        decision, reason = out
        try:
            sys.stdout.write(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": decision,
                                                                "permissionDecisionReason": reason}}) + "\n")
            sys.stdout.flush()
        except BaseException:
            baton.void_asked(str(inp.get("session_id") or ""))     # a record without its dialog must not stay
            raise
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:                              # fail-open: no record was written, so sign --by owner refuses
        sys.stderr.write("baton-guard: %s: %s\n" % (type(e).__name__, e))
        sys.exit(0)
