#!/usr/bin/env bash
# Purpose: replace the old broad baton ask rules (a leading *, which asked for any command that only mentioned a sign or a mode call) with the anchored ones in the user settings. With this sdlc version an owner in auto confirms the mode once more (one dialog) and trusts the remote list again: a mode or remote list set before it reads as not chosen
# Targets: <claude-dir>/settings.json; a backup and a run record under <state-dir>/records
# Blast: that one file's permissions.ask: exactly the old patterns removed, the anchored rules that are absent added; no other rule or list changes (the file is written back as two-space JSON, and a key written twice keeps its last value)
# Undo: puts the file back byte for byte from the backup (its mode kept), only for the record of this signed run and only while the file holds the bytes the run wrote; a file that changed since is left alone (LEAVE, exit 5)
# Pre: this session runs the installed vibemaestro-sdlc; the user settings are JSON, not a symbolic link, and hold an old pattern; no other settings scope holds one; the swap reaches permissions --check with no rule finding (else refused, rc 3)
# Stops: security-boundary
#   Why: it removes ask rules from the owner's permission settings and adds others: a permission change, so the owner signs, in every mode.
# Usage: no arguments (every value is this machine's)
# Each: upgrade *
#
# The kit baton kit:permissions-upgrade, for a machine whose user settings hold the permission block printed before the anchored rules:
# <launcher> go kit:permissions-upgrade, then the owner's sign at exit 8. It takes no argument. The engine is
# gates/permissions_upgrade.py: the plan (one line naming every rule removed and added, the file's sha256 before and after),
# the write checked against the signed plan (BATON_PLAN), the post-check and the undo. A file that holds none of the old patterns
# is refused at rehearse with `REFUSE nothing to do` and exit 3. A kit signature binds this file only, so every plan line
# carries the sha256 of the code that writes (the engine and baton.py, which prints the anchored rules); the write hashes them
# again and refuses a line whose sha256 is not the one it computes.
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
  echo "kit:permissions-upgrade runs only through the baton runner (baton go|rehearse|run kit:permissions-upgrade)" >&2
  exit 64
fi
if [ $# -ne 0 ]; then
  echo "usage: baton go kit:permissions-upgrade (no argument: every value is this machine's)" >&2
  exit 64
fi

# engine_sha — one sha256 over the code the write runs, read here so the signature binds it (the write checks it again)
engine_sha() {
  python3 -I -c 'import hashlib, sys
h = hashlib.sha256()
for name in sys.argv[1:]:
    h.update(hashlib.sha256(open(name, "rb").read()).hexdigest().encode() + b"\n")
print(h.hexdigest())' "$BATON_PLUGIN_ROOT/gates/permissions_upgrade.py" "$BATON_PLUGIN_ROOT/scripts/baton.py"
}
engine() { python3 -I -B "$BATON_PLUGIN_ROOT/gates/permissions_upgrade.py" "$@" < /dev/null; }
engine_do() { python3 -I -B "$BATON_PLUGIN_ROOT/gates/permissions_upgrade.py" do --expect-plan "${BATON_PLAN:?no signed plan}" < /dev/null; }

# ── the act: the plan, then its one write through write() ──
act() {
  local line code
  line=$(engine plan)
  code=$(engine_sha)
  case "$line" in
    "upgrade settings "*) ;;
    *)
      echo "REFUSE the engine planned an unknown step: $line" >&2
      return 3
      ;;
  esac
  printf 'PLAN-COUNT 1\n'
  write "$line, engine sha256 $code" engine_do
}

# ── post-check: permissions --check finds no rule finding ──
postcheck() {
  engine postcheck
}

# ── undo: the file back byte for byte, while it is what this signed run left ──
undo() {
  engine undo --expect-plan "${BATON_PLAN:-}"
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
