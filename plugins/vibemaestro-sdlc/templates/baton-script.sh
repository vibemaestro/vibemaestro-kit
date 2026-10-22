#!/usr/bin/env bash
# Purpose: example act, replace it: create one file holding the given text
# Targets: the file named by the first argument
# Blast: that one file; nothing else is read or written
# Undo: removes the file, only while it holds exactly the text this act writes
# Pre: the file is absent (an existing file with other content is refused, never overwritten)
# Stops: none
# Expect: create *
#
# A baton script (BatonRun), written by `baton new __NAME__`. Run it only through the baton runner of vibemaestro-sdlc:
#   python3 <plugin-root>/scripts/baton.py check|rehearse|run __NAME__.sh <args>
#   python3 <plugin-root>/scripts/baton.py sign --by owner --seal <seal rehearse printed> __NAME__.sh <args>
# Each one bare, as its own call: no `cd … &&` before it, no pipe after sign, run or go (a compound command matches no rule).
# `baton check` reads the header above: Purpose, Targets, Blast, Undo, Pre and Stops once each, and one Expect per planned write
# (a shell glob, matched in order against the PLAN lines that rehearse prints). Stops is `none`, or a comma list of
# irreversible-delete, secrets, security-boundary, cluster-lane, history-rewrite, money-org, publish, no-way-back, owner-acts;
# any of them means only the owner may sign.
#
# Phases (baton sets BATON_PHASE; a plain `bash __NAME__.sh` only rehearses):
#   rehearse   reads and checks, prints one PLAN line per write; nothing changes
#   run        the same code; write() executes
#   postcheck  re-reads the state and compares it with the expected after-state
#   undo       puts back what run changed; safe after a run that stopped half-way
# Fidelity: every change goes through write(), and nothing but write() and the dispatch at the end looks at the phase.
# Reads run in every phase, so rehearse exercises them. Per tool: `kubectl apply --dry-run=server` as a read before the write;
# GET reads for gh; `docker build` before a write that pushes; `claude plugin list` before a write that installs.
# Remote programs go through stdin into `bash -s` as a quoted heredoc (`ssh <host> bash -s <<'EOF'`, `kubectl exec -i <pod> --
# bash -s`), computed values first on the same stdin (`{ printf 'V=%q\n' "$v"; cat <<'EOF' … EOF } | ssh <host> bash -s`), never
# as arguments through `su -c` (the login shell may be fish). Print a remote read before deciding on it:
# `OUT=$(remote … 2>&1 || true)`, not a bare `CHK=$(remote …)` that set -e ends with its output lost; a read-only remote
# program ends with `true`.
# Put resolved values (absolute paths, full SHAs, tags) in the plan lines: the signature binds the plan the owner saw.
# A plan line holds what was read before the act (uid, sha, revision), never a value the act moves: the DO line would differ.
# Under pipefail, a command whose non-zero exit is normal (diff, grep with no match, cmp) is wrapped in a pipeline:
#   { diff -u old new || true; } | head -40
# No `source` of other files: the signature covers this file only. Never pass a secret as an argument: arguments are logged.
# A privileged command outside write() fails check: it would run in rehearse too. A helper that writes (put_text below) is
# called only through write(). Each phase runs in a process group of its own with stdin closed: nothing may prompt.
# bash 3.2 (macOS) runs this file: no associative arrays, no ${var,,}, no mapfile.
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
  echo "usage: bash __NAME__.sh <file> <text>" >&2
  exit 64
fi
DEST=$1
TEXT=$2
case "$DEST" in
  /*) ;;
  *) DEST="$PWD/$DEST" ;;
esac

# byte for byte (`$(cat …)` would drop trailing newlines and call a different file the same)
holds_text() { [ -f "$DEST" ] && cmp -s "$DEST" <(printf '%s\n' "$TEXT"); }
put_text() { printf '%s\n' "$TEXT" > "$DEST"; }

# ── the act: every change through write() ──
act() {
  if holds_text; then
    echo "same $DEST (nothing to do)"
    return 0
  fi
  if [ -e "$DEST" ]; then
    echo "REFUSE $DEST exists with other content" >&2
    return 3
  fi
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
