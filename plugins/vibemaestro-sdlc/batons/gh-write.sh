#!/usr/bin/env bash
# Purpose: the GitHub issue, comment and pull-request writes one JSON spec lists, each pinned, rehearsed and post-checked byte for byte (gates/gh_write.py)
# Targets: the issues, comments, pull requests and new branches the spec names, in repositories that read private (not internal, not public)
# Blast: the spec's ops only: create issues, add comments, edit a comment, an issue's title or body or a PR body, reopen or close an issue, close a PR, mark a draft PR ready, open a PR from a pushed branch, add one new branch whose one commit adds or replaces one file, and its PR; never a deletion, a moved ref, a tag, a repository, a label or a setting
# Undo: puts saved bodies, titles and states back, closes created issues as not planned (their marker removed), retracts new comments by editing them, turns a PR it marked ready back into a draft, closes a PR it opened; it leaves alone what changed since the run, and a branch file-pr made, which it names (then rc 5); notifications already sent stay sent
# Pre: each repository is private, each target exists in the state its op needs, markers are absent, labels exist, body and content files match their sha256, pinned heads and the base tip still hold, a new branch is absent, no unfinished run of the spec; read again inside each op's write
# Stops: none
#   Why none: every write is undone by undo (an edit, a reopen, a close, a PR back to draft) or retracted without a deletion (a
#   created issue is closed as not planned, a new comment is edited to a retraction, an opened PR is closed), and its audience is
#   a private repository's members. A new branch with one commit that adds or replaces one file is not undone: it changes no existing
#   branch, its path may not be a workflow, and the undo names it so the owner may delete it. A deletion, a repository creation and a repository that is not
#   private are refused at rehearse, so they are never escalated to a signature: those stay hand-written and owner-signed.
# Each: gh-write *
#
# The kit baton kit:gh-write. Run it only through the baton runner; the coordinator's three commands:
#   <launcher> rehearse kit:gh-write --spec <file>
#   <launcher> sign --by coordinator-auto --seal <seal rehearse printed> kit:gh-write --spec <file>
#   <launcher> run kit:gh-write --spec <file>
# A run left open (interrupted, or an undo that failed) blocks every later rehearse of the spec; its undo is a run of its own:
#   <launcher> rehearse|sign …|run kit:gh-write --spec <file> --recover
# The spec's format is in `python3 gates/gh_write.py --help`. Rehearse is the engine's plan mode: one condition line per check and
# one plan line per op, each carrying the spec's sha256, so the signature binds the spec and through its pins every body file.
# The run hands each op the signed plan (BATON_PLAN): an op whose plan line no longer matches is refused before it writes.
# Each, instead of Expect lines: every plan line matches the glob, and there are exactly as many as the PLAN-COUNT line the engine
# prints (the ops of the spec).
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
  echo "kit:gh-write runs only through the baton runner (baton rehearse|sign|run kit:gh-write --spec <file>)" >&2
  exit 64
fi
if [ $# -lt 2 ] || [ $# -gt 3 ] || [ "$1" != "--spec" ] || [ -z "$2" ] || { [ $# -eq 3 ] && [ "$3" != "--recover" ]; }; then
  echo "usage: baton rehearse|run kit:gh-write --spec <file> [--recover]" >&2
  exit 64
fi
ARGS=("$@")

# the engine: a read in every phase (plan, --postcheck, --undo-plan), a write only through write()
engine() { python3 -I -B "$BATON_PLUGIN_ROOT/gates/gh_write.py" "${ARGS[@]}" "$@" < /dev/null; }
engine_do() { python3 -I -B "$BATON_PLUGIN_ROOT/gates/gh_write.py" "${ARGS[@]}" --do "$1" --expect-plan "${BATON_PLAN:?no signed plan}" < /dev/null; }
engine_undo() { python3 -I -B "$BATON_PLUGIN_ROOT/gates/gh_write.py" "${ARGS[@]}" --undo-step "$1" < /dev/null; }

# ── the act: one write() per op of the spec ──
act() {
  local out line i=0 rc=0
  out=$(engine 2>&1) || rc=$?
  printf '%s\n' "$out"
  if [ "$rc" -ne 0 ]; then
    echo "REFUSE the spec or a condition fails (rc $rc): nothing to write, nothing to sign" >&2
    return 3
  fi
  while IFS= read -r line; do
    case "$line" in
      "op-plan: "*)
        i=$((i + 1))
        write "${line#op-plan: }" engine_do "$i"
        ;;
    esac
  done <<< "$out"
  if [ "$i" -eq 0 ]; then
    echo "REFUSE the engine printed no op-plan line" >&2
    return 3
  fi
}

# ── post-check: every op read back by its number or id, byte for byte ──
postcheck() {
  engine --postcheck
}

# ── undo: one write() per op of the open run, newest first; a step that finds a changed state leaves it and fails ──
undo() {
  local out line rest bad=0
  out=$(engine --undo-plan)
  printf '%s\n' "$out"
  while IFS= read -r line; do
    case "$line" in
      "undo-step: "*)
        rest=${line#undo-step: }
        write "undo $rest" engine_undo "${rest%% *}" || bad=1
        ;;
    esac
  done <<< "$out"
  [ "$bad" -eq 0 ]
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
