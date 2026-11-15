#!/usr/bin/env python3
"""The kit's two modes in a folder: `developer` (the software flow: intent, spec, plan, pull request, gates) and `everyday` (a
person who keeps a notebook of ordinary work in kb/ and no git flow). `mode` decides, the first answer wins:

  1. the folder's key `profile` in .vibemaestro/sdlc.json, `everyday` or `developer`;
  2. a folder with a git remote is developer, as it always was;
  3. the person's choice, VIBEMAESTRO_PROFILE (the `env` block of their Claude Code settings), only for a folder with no remote;
  4. the default: a folder that is not a git repository, or a repository the kit created for the quiet save (git config MARK),
     is everyday; a repository that was there before is developer.

Standard library only; never raises. A folder is "not a repository" only when no `.git` lies in it or above it: a git that fails
inside a repository (dubious ownership, a broken install, a dangling .git file, a timeout) is developer, as before the mode existed."""
import hashlib
import json
import os
import re
import subprocess
import time

MODES = ("everyday", "developer")
PERSON_VAR = "VIBEMAESTRO_PROFILE"
MARK = "vibemaestro.quietsave"          # set to `true` in the local git config of a repository the kit itself created
SAVE_STALE = 600                        # seconds: a save that started and wrote no result by then was stopped (git calls: 60 s each)


def _git(troot, *args):
    """The stripped stdout of `git -C troot <args>`, or None when git is missing, fails or times out."""
    try:
        p = subprocess.run(["git", "-C", troot] + list(args), stdin=subprocess.DEVNULL, capture_output=True, text=True,
                           encoding="utf-8", errors="surrogateescape", timeout=3)
    except (OSError, subprocess.SubprocessError):
        return None
    return p.stdout.strip() if p.returncode == 0 else None


def _under_git(troot):
    """A `.git` (a directory or a file) in `troot` or one of its parents."""
    d = os.path.abspath(troot)
    while True:
        if os.path.lexists(os.path.join(d, ".git")):
            return True
        up = os.path.dirname(d)
        if up == d:
            return False
        d = up


def kit_made(troot):
    """`troot/.git/config` carries the kit's mark and no remote, read as text (for when git itself refuses the folder)."""
    try:
        with open(os.path.join(troot, ".git", "config"), encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        return False
    return (re.search(r"(?im)^\s*\[vibemaestro\]\s*$(?:\n(?!\s*\[).*)*?\n\s*quietsave\s*=\s*true\s*$", text) is not None
            and re.search(r'(?im)^\s*\[remote(\s+"|\.)', text) is None)


def mode(troot, profile="auto"):
    """(mode, reason) for the folder `troot`, reason one of `folder`, `remote`, `person`, `default`."""
    if profile in MODES:
        return profile, "folder"
    remotes = _git(troot, "remote")                 # None outside a repository
    if remotes:
        return "developer", "remote"
    if remotes is None and _under_git(troot):
        # git failed inside a repository: developer, it may have a remote; unless the folder's own history is the kit's (read from its
        # config file, git cannot), so the save reports the failure instead of stopping without a word
        return ("everyday", "default") if kit_made(troot) else ("developer", "default")
    person = os.environ.get(PERSON_VAR, "").strip().lower()
    if person in MODES:
        return person, "person"
    if remotes is None or _git(troot, "config", "--local", "--get", MARK) == "true":
        return "everyday", "default"
    return "developer", "default"


# ── the quiet save's trace (scripts/quiet_save.py writes it, the everyday session start reads it) ──────────────────────────
def trace_path(troot):
    """The file where the quiet save leaves its last result for the folder `troot`, under the state directory."""
    x = os.environ.get("XDG_STATE_HOME", "")
    base = x if x and os.path.isabs(x) else os.path.join(os.path.expanduser("~"), ".local", "state")
    key = hashlib.sha256(os.path.realpath(troot).encode("utf-8", "surrogateescape")).hexdigest()[:16]
    return os.path.join(base, "vibemaestro", "quiet-save", key + ".json")


def save_trouble(troot, now=None):
    """One plain line when the last quiet save of `troot` did not save the work (it failed, was skipped to keep something safe,
    or started and never wrote its result); "" otherwise. Never raises."""
    try:
        with open(trace_path(troot), encoding="utf-8") as f:
            d = json.load(f)
        state, why, at = d.get("state"), str(d.get("why") or ""), float(d.get("at") or 0)
    except (OSError, ValueError, TypeError, AttributeError):
        return ""
    if state == "started" and (now if now is not None else time.time()) - at > SAVE_STALE:
        return "the last quiet save of this folder did not finish (it was stopped or timed out); the next turn saves again"
    if state in ("failed", "skipped"):
        return "the last quiet save of this folder did not happen: %s" % why
    if state == "partial":
        return "the last quiet save of this folder kept the folder but not %s" % why
    return ""
