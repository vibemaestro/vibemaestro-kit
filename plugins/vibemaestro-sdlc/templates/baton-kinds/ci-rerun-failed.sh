#!/usr/bin/env bash
# Purpose: re-run the failed jobs of one workflow run of a private repository, by its run id
# Targets: the workflow run the arguments name (its failed and cancelled jobs, and the jobs that need them); a run record under the baton state directory
# Blast: one new attempt of that run and the CI time of its re-run jobs; nothing in the repository changes
# Undo: cancels the new attempt while it is queued or in progress; a finished attempt stays (GitHub keeps every attempt); the run record is removed; an earlier run's record (another signed plan) is left alone
# Pre: the repository is private (not internal, not public); the run is completed with conclusion failure, cancelled or timed_out
# Stops: none
#   Why none: it re-runs, on the same commit, jobs CI already ran once, in a private repository: no code, no setting, nothing
#   published, and the new attempt can be cancelled while it runs. A public or internal repository is refused at rehearse.
# Expect: record *
# Expect: rerun-failed *
#
# A baton script of kind ci-rerun-failed (BatonRun): run as is with `<launcher> go kind:ci-rerun-failed <owner/name> <run id>` (no
# script to write), or written by `baton new __NAME__ --from ci-rerun-failed` to change it. The contract (the header above, the
# phases, the write() gate, check, rehearse, sign, run) is the one `baton new` writes without --from: its comments explain each
# part. Run the launcher bare, one command per call.
# The plan carries what was read before the act: the run's attempt, head sha and workflow. The attempt is what the rerun moves,
# so undo cannot find it from a read: the run writes it into a run record first (one per repository and run id), and the
# rerun's write waits (up to 60 s) for the new attempt to show, so the post-check is not a race. The record holds the sha256 of
# the signed plan (BATON_PLAN), which baton hands the run and its undo: a record stays after a run that held, and undo cancels
# only for its own run's record.
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
usage() { echo "usage: bash __NAME__.sh <owner/name> <run id>" >&2; }
if [ $# -ne 2 ]; then
  usage
  exit 64
fi
REPO=$1
RUN=$2
if ! [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || ! [[ "$RUN" =~ ^[0-9]+$ ]]; then
  usage
  exit 64
fi
# the baton state directory, as baton computes it; the run record lives under it
case "${XDG_STATE_HOME:-}" in
  /*) STATE_BASE=$XDG_STATE_HOME ;;
  *) STATE_BASE="$HOME/.local/state" ;;
esac
RECORDS="$STATE_BASE/vibemaestro/baton/records"
run_key() { printf '%s %s' "$REPO" "$RUN" | python3 -I -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:16])'; }
RECORD="$RECORDS/__NAME__-$(run_key).last"

# fields <json> <key>... — the keys' values, tab-separated (null as -, true/false in lower case); exit 1 on anything but an object
fields() {
  python3 -I -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
except ValueError:
    sys.exit(1)
if not isinstance(d, dict):
    sys.exit(1)
v = [d.get(k) for k in sys.argv[2:]]
print("\t".join("-" if x is None else str(x).lower() if isinstance(x, bool) else str(x).replace("\t", " ") for x in v))' "$@"
}
# run_read <key>... — the run's fields now; a read gh refuses prints what it said and fails
run_read() {
  local out
  out=$(gh api "repos/$REPO/actions/runs/$RUN" 2>&1 || true)
  fields "$out" "$@" || { printf '%s\n' "$out" >&2; return 1; }
}
# plan_id — the sha256 of the signed plan baton hands the run and its undo (BATON_PLAN): which run a record belongs to
plan_id() {
  if [ -n "${BATON_PLAN:-}" ] && [ -f "$BATON_PLAN" ]; then
    python3 -I -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$BATON_PLAN"
  fi
}
record() { mkdir -p "$RECORDS" && printf '%s %s\n' "$1" "$(plan_id)" > "$RECORD"; }
# rerun <attempt read before> — the rerun, then a wait for the next attempt to show (60 s at most)
rerun() {
  local i=0 now
  gh run rerun "$RUN" --failed -R "$REPO"
  while [ "$i" -lt 30 ]; do
    now=$(run_read run_attempt || echo 0)
    if [ "$now" -gt "$1" ] 2>/dev/null; then
      return 0
    fi
    sleep 2
    i=$((i + 1))
  done
  echo "the new attempt of run $RUN did not show within 60 s" >&2
  return 1
}

# ── the act: every change through write() ──
act() {
  local out vals priv vis status concl attempt head wf
  out=$(gh api "repos/$REPO" 2>&1 || true)
  if ! vals=$(fields "$out" private visibility); then
    printf '%s\n' "$out"
    echo "REFUSE cannot read the repository $REPO" >&2
    return 3
  fi
  IFS=$'\t' read -r priv vis <<< "$vals"
  if [ "$priv" != true ] || [ "$vis" = public ] || [ "$vis" = internal ]; then
    echo "REFUSE $REPO is not private (private $priv, visibility $vis): this kind re-runs CI of private repositories only" >&2
    return 3
  fi
  if ! vals=$(run_read status conclusion run_attempt head_sha name); then
    echo "REFUSE cannot read run $RUN of $REPO" >&2
    return 3
  fi
  IFS=$'\t' read -r status concl attempt head wf <<< "$vals"
  if [ "$status" != completed ]; then
    echo "REFUSE run $RUN is $status, not completed: nothing to re-run yet" >&2
    return 3
  fi
  case "$concl" in
    failure | cancelled | timed_out) ;;
    *)
      echo "REFUSE run $RUN ended $concl: no failed job to re-run" >&2
      return 3
      ;;
  esac
  write "record $RECORD: run $RUN of $REPO at attempt $attempt" record "$attempt"
  write "rerun-failed $REPO run $RUN attempt $attempt head $head workflow $wf" rerun "$attempt"
}

# ── post-check: the run is at the attempt after the one the record holds ──
postcheck() {
  local n now _run
  [ -f "$RECORD" ] || return 1
  read -r n _run < "$RECORD"
  now=$(run_read run_attempt)
  echo "run $RUN: attempt $now, the record says $n before the rerun"
  [ "$now" = "$((n + 1))" ]
}

# ── undo: from the record; the attempt the rerun made is cancelled while it runs, any other attempt is left (exit 5) ──
undo() {
  local n vals now status runid mine
  if [ ! -f "$RECORD" ]; then
    echo "no run record: the rerun never ran, nothing to cancel"
    return 0
  fi
  read -r n runid < "$RECORD"
  mine=$(plan_id)
  if [ -z "$mine" ]; then
    echo "LEAVE no signed plan (BATON_PLAN): cannot tell whether $RECORD is this run's" >&2
    return 1
  fi
  if [ "${runid:-}" != "$mine" ]; then
    echo "the run record $RECORD is an earlier run's: nothing of this run to cancel"
    return 0
  fi
  vals=$(run_read run_attempt status)
  IFS=$'\t' read -r now status <<< "$vals"
  if [ "$now" = "$n" ]; then
    echo "same run $RUN at attempt $n: the rerun never landed"
  elif [ "$now" = "$((n + 1))" ] && [ "$status" = completed ]; then
    echo "attempt $now of run $RUN has finished: it stays (GitHub keeps every attempt)"
  elif [ "$now" = "$((n + 1))" ]; then
    write "cancel $REPO run $RUN attempt $now" gh run cancel "$RUN" -R "$REPO"
  else
    echo "LEAVE run $RUN is at attempt $now, not $n or $((n + 1)): another rerun came in between; left alone" >&2
    return 1
  fi
  write "drop the run record $RECORD" rm -f -- "$RECORD"
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
