#!/usr/bin/env bash
# Purpose: merge one pull request through the guarded merge of vibemaestro-sdlc (gates/merge_guard.py), pinned to the reported head
# Targets: the pull request named by --repo and --pr, and its base branch
# Blast: one squash merge into the base branch, and one line per guard run in the merge log; nothing else
# Undo: none by this script: a merge is not reversible. The way back is a revert PR, opened and reviewed like any PR; undo here only confirms that nothing merged when the run failed before the merge
# Pre: every condition of the guard holds at rehearse, and again inside the merge call, which GitHub pins with --match-head-commit
# Stops: none
#   Why none (the owner's standing rule): the coordinator merges a PR whose guard passes. A merge cannot be undone, but its dry run
#   is its rehearse, so no-way-back (neither rehearsable nor reversible) does not apply. A PR that touches merge.deny_globs fails the
#   guard at rehearse, so it is refused and never escalated to a signature. --admin passes only when merge.admin_bypass is true in
#   the base branch's config, which is the repo owner's standing rule.
# Usage: --repo <owner/name> --pr <n> --head <sha40> --brief <file> [--behind auto, never beside --behind-ok] [merge_guard.py options]
# Expect: merge *
#
# The kit baton kit:merge-pr. Run it only through the baton runner; the coordinator's three commands:
#   <launcher> rehearse kit:merge-pr --repo <owner/name> --pr <n> --head <full sha> --brief <file> [guard options]
#   <launcher> sign --by coordinator-auto --seal <seal rehearse printed> kit:merge-pr <the same arguments>
#   <launcher> run kit:merge-pr <the same arguments>
# The arguments are the guard's (python3 gates/merge_guard.py --help), without --merge or --status: rehearse is the guard's dry run,
# run is its --merge with the signed plan (BATON_PLAN), refused before anything merges when the world moved since signing;
# post-check and undo read --status. The plan line is the guard's merge-plan line, which carries the full head,
# the base SHA, the digest of the brief's globs and of the guard's code, so the signature binds them too.
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
  echo "kit:merge-pr runs only through the baton runner (baton rehearse|sign|run kit:merge-pr …)" >&2
  exit 64
fi
if [ $# -eq 0 ]; then
  echo "usage: baton rehearse|run kit:merge-pr --repo <owner/name> --pr <n> --head <full sha> --brief <file> [guard options]" >&2
  exit 64
fi
ARGS=("$@")
HEAD=""
PREV=""
for a in "$@"; do
  case "$a" in
    --merge | --merge=* | --status | --status=*)
      echo "kit:merge-pr takes the guard's arguments without $a: rehearse is the dry run, run merges, post-check reads the state" >&2
      exit 64
      ;;
    --head=*) HEAD=${a#--head=} ;;
  esac
  if [ "$PREV" = "--head" ]; then
    HEAD=$a
  fi
  PREV=$a
done
HEAD=$(printf '%s' "$HEAD" | tr 'ABCDEF' 'abcdef')

# the guard: a read in every phase (dry run, or --status), and the merge only through write()
guard_read() { python3 -I -B "$BATON_PLUGIN_ROOT/gates/merge_guard.py" ${ARGS[@]+"${ARGS[@]}"} "$@"; }
guard_merge() { python3 -I -B "$BATON_PLUGIN_ROOT/gates/merge_guard.py" ${ARGS[@]+"${ARGS[@]}"} --merge --expect-plan "${BATON_PLAN:?no signed plan}"; }

# ── the act: every change through write() ──
act() {
  local out plan rc=0
  out=$(guard_read 2>&1) || rc=$?
  printf '%s\n' "$out"
  if [ "$rc" -ne 0 ]; then
    echo "REFUSE the guarded merge says no (rc $rc): nothing to merge, nothing to sign" >&2
    return 3
  fi
  plan=$(printf '%s\n' "$out" | sed -n 's/^merge-plan: //p')
  if [ -z "$plan" ]; then
    echo "REFUSE the guard printed no merge-plan line" >&2
    return 3
  fi
  write "$plan" guard_merge
}

# ── post-check: the PR reads merged, at the head that was checked ──
postcheck() {
  local st
  st=$(guard_read --status)
  echo "state: $st"
  case "$st" in
    "merged "*) ;;
    *) echo "the PR is not merged" >&2; return 1 ;;
  esac
  case "$st" in
    *" head $HEAD") ;;
    *) echo "merged, but not at the head $HEAD that was checked" >&2; return 1 ;;
  esac
}

# ── undo: a merge cannot be undone; this only confirms that nothing merged ──
undo() {
  local st
  st=$(guard_read --status)
  echo "state: $st"
  case "$st" in
    "merged "*)
      echo "a merge is not reversible: open a revert PR, have it reviewed, and tell the owner now" >&2
      return 1
      ;;
    "queued "* | "pending "*)
      echo "the merge is queued or pending and may still happen: tell the owner now (a revert PR once it lands)" >&2
      return 1
      ;;
  esac
  echo "nothing merged: nothing to undo"
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
