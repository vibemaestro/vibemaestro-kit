#!/usr/bin/env bash
# Purpose: the contract's dependent-calls probe: create one file holding the given text, as a kit baton an owner must sign
# Targets: the file named by the first argument, and <file>.env (the runner env each phase saw)
# Blast: those two files; nothing else is read or written
# Undo: removes the file, only while it holds exactly the text this act writes
# Pre: the file is absent (an existing file with other content is refused, never overwritten)
# Stops: owner-acts
# Usage: <file> <text>
# Each: create *
#
# tests/test-contract.sh (family dependents) stages this file as <plugin copy>/batons/dep-probe.sh, so it resolves as
# kit:dep-probe, and drives it the way a dependent repository drives its own kit batons: check, rehearse, mode auto, sign
# (coordinator-auto refused, owner after the guard hook's record), run with its post-check. Each phase appends one line to
# <file>.env: the BATON_* names the runner set for it, sorted (the probe tells the phases apart by the call that ran them).
set -euo pipefail
PHASE=${BATON_PHASE:-rehearse}

# write <plan line> <command> [args...] — the one gate for every change. A change whose after-state shows late (a log line,
# a status) waits for it inside the command it runs, with a time limit, so the post-check is not a race.
write() {
  local plan=$1
  shift
  case "$PHASE" in
    rehearse)
      printf 'PLAN %s\n' "$plan"
      printf '%s\n' "$plan" >> "${BATON_WRITES:-/dev/null}"
      ;;
    run | undo)
      printf 'DO %s\n' "$plan"
      printf '%s\n' "$plan" >> "${BATON_WRITES:-/dev/null}"
      "$@"
      ;;
    *)
      printf 'write called in phase %s: %s\n' "$PHASE" "$plan" >&2
      return 70
      ;;
  esac
}

# ── arguments and reads: every phase runs them ──
if [ $# -ne 2 ]; then
  echo "usage: kit:dep-probe <file> <text>" >&2
  exit 64
fi
DEST=$1
TEXT=$2
case "$DEST" in
  /*) ;;
  *) DEST="$PWD/$DEST" ;;
esac

env | sed -n 's/^\(BATON_[A-Z_]*\)=.*/\1/p' | sort | paste -s -d ' ' - >> "$DEST.env"

# byte for byte (`$(cat …)` would drop trailing newlines and call a different file the same)
holds_text() { [ -f "$DEST" ] && cmp -s "$DEST" <(printf '%s\n' "$TEXT"); }
put_text() { printf '%s\n' "$TEXT" > "$DEST"; }

# ── the act: every change through write() ──
act() {
  if holds_text; then
    echo "same $DEST (nothing to do)"
    echo "PLAN-COUNT 0"
    return 0
  fi
  if [ -e "$DEST" ]; then
    echo "REFUSE $DEST exists with other content" >&2
    return 3
  fi
  echo "PLAN-COUNT 1"
  write "create $DEST" put_text
}

# ── post-check: the expected after-state ──
postcheck() {
  holds_text
}

# ── undo: back to the before-state, safe on a partial run; it fails when the act's bytes are still there ──
# Compare every target with its before-state, or name in the Undo header what it leaves. When undo cannot recompute a name
# from a read (a backup named after a sha the act changes), the act writes a record through write() and undo works from it
# only while the target still matches it.
undo() {
  if holds_text; then
    write "remove $DEST" rm -f -- "$DEST"
  fi
  ! holds_text
}

case "$PHASE" in
  rehearse)
    act
    echo "VERDICT rehearse ok"
    ;;
  run)
    act
    echo "VERDICT run ok"
    ;;
  postcheck)
    postcheck
    echo "VERDICT postcheck ok"
    ;;
  undo)
    undo
    echo "VERDICT undo ok"
    ;;
  *)
    echo "unknown phase: $PHASE" >&2
    exit 64
    ;;
esac
