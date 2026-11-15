#!/usr/bin/env bash
# Purpose: add or remove one SOUL line (`- [S14] text`) in the file that holds a project's SOUL rules, exactly as an owner step of that project's brain names it, so nobody edits the file by hand
# Targets: the one file the owner step names; a backup, a run record and a used-step marker under <state-dir>/records
# Blast: one line of that file added after its last SOUL line (or at its end) or removed; every other byte kept, the file's mode kept
# Undo: puts the file back byte for byte from the backup, only for the record of this signed run and only while the file holds the bytes the run wrote, and frees the owner step again; a file that changed since is left alone (LEAVE, exit 5)
# Pre: the project's brain log holds an owner op (written through the owner's dialog) whose soul_line names this code, action, text and file, and no run used it yet; the file is a regular UTF-8 file of at most 1 MiB named by its real path; add: no line names the code yet; remove: exactly one does, with the step's text; at the write, the plan line is in the signed plan and the file still has the planned sha256
# Stops: none
#   Why none: the owner already decided in the brain's dialog, which showed the exact line and file; this run only carries out
#   that step, refuses any other line, file or a step used before, can be rehearsed, and its undo puts the bytes back.
# Usage: --file <absolute path> --code <S14> --action add|remove --text <the line's text>
# Each: soul-line *
#
# The kit baton kit:soul-line, run by vibemaestro-brain right after the owner's SOUL step (`brain owner promote … --soul-line …`,
# or an extension's step), or by the session with the same arguments: <launcher> go kit:soul-line --file F --code S14 --action
# add --text T. The engine is gates/soul_line.py: the plan (one line naming the change, the file's sha256 before and after and
# the owner step), the write checked against the signed plan (BATON_PLAN), the post-check and the undo. It finds the owner
# step in the brain's log of the project the run stands in, never from an argument. A kit signature binds this file only, so
# every plan line carries the sha256 of the engine; the write hashes it again and refuses a line whose sha256 differs.
# This script is plugin code: baton lets a kit baton, and nothing else, run a plugin gate as python3 -I -B "$BATON_PLUGIN_ROOT/gates/…".
# bash 3.2 (macOS) runs this file: no associative arrays, no ${var,,}, no mapfile.
set -euo pipefail
PHASE=${BATON_PHASE:-rehearse}

# write <plan line> <command> [args...] — the one gate for every change
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
if [ -z "${BATON_PLUGIN_ROOT:-}" ]; then
  echo "kit:soul-line runs only through the baton runner (baton go kit:soul-line --file F --code S14 --action add --text T)" >&2
  exit 64
fi
if [ $# -ne 8 ]; then
  echo "usage: baton go kit:soul-line --file <absolute path> --code <S14> --action add|remove --text <the line's text>" >&2
  exit 64
fi
ARGS=("$@")

engine_sha() { python3 -I -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' \
  "$BATON_PLUGIN_ROOT/gates/soul_line.py"; }
engine() { python3 -I -B "$BATON_PLUGIN_ROOT/gates/soul_line.py" "$@" < /dev/null; }
engine_do() { engine do --expect-plan "${BATON_PLAN:?no signed plan}" "${ARGS[@]}"; }

# ── the act: the plan, then its one write through write() ──
act() {
  local line code
  line=$(engine plan "${ARGS[@]}")
  code=$(engine_sha)
  case "$line" in
    "soul-line add "* | "soul-line remove "*) ;;
    *)
      echo "REFUSE the engine planned an unknown step: $line" >&2
      return 3
      ;;
  esac
  printf 'PLAN-COUNT 1\n'
  write "$line, engine sha256 $code" engine_do
}

# ── post-check: the file holds the bytes the run wrote ──
postcheck() {
  engine postcheck "${ARGS[@]}"
}

# ── undo: the bytes back, while the file is what this signed run left ──
undo() {
  engine undo --expect-plan "${BATON_PLAN:-}" "${ARGS[@]}"
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
