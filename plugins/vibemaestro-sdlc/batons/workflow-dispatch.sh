#!/usr/bin/env bash
# Purpose: dispatch one workflow_dispatch run of a workflow of a private repository on a branch, pinned to the branch head and the workflow file's blob
# Targets: the repository (--repo), the workflow file (--workflow, under .github/workflows) and the branch (--ref) named; a run record under the baton state directory
# Blast: one queued run of that workflow on that branch (runner time, and whatever the pinned workflow itself does); nothing in the repository changes
# Undo: cancels the run this dispatch made while it is queued or in progress; a finished run stays (GitHub keeps every run); the run record is removed; an earlier run's record (another signed plan) is left alone
# Pre: not a sandbox session (SEAT and INTENT_SLUG set: refused, ask the coordinator); the repository reads private (not internal, not public); the branch exists (letters, digits and ._/-); the workflow file is on its head and declares a workflow_dispatch trigger; each input key is letters, digits, _ and -; at the dispatch, its plan line is in the signed plan
# Stops: none
#   Why none: it starts, in a private repository, one run of a workflow whose bytes the plan line pins (the blob at the branch
#   head), and the run can be cancelled while it runs. A public or internal repository is refused at rehearse, so it is never
#   escalated to a signature.
# Usage: --repo <owner/name> --workflow <file.yml> --ref <branch> [--input <key>=<value>]...  (it declares workflow_dispatch)
# Expect: record *
# Expect: dispatch workflow * on * ref * at * blob * inputs *
#
# The kit baton kit:workflow-dispatch. Run it only through the baton runner:
#   <launcher> go kit:workflow-dispatch --repo <owner/name> --workflow <file.yml> --ref <branch> [--input <key>=<value>]...
# Which run is this dispatch's: GitHub's dispatch call answers no run id, so the run writes a record first (the sha256 of the
# signed plan, BATON_PLAN, the pinned head, the viewer's login and the ids of the runs that already match), checks that its
# plan line is in the signed plan, dispatches, marks the record `sent` once gh accepted the call, then waits up to 60 s for
# one new run to show. A run matches when it is of that workflow, event workflow_dispatch, on that branch and triggered by
# the viewer (the login of the `gh api graphql` viewer), at any head; the new one is a matching id the record does not hold.
# No local clock is compared with GitHub's. The post-check wants exactly one new run, at the pinned head (gh dispatches by
# branch name, so a branch that moved in between runs other bytes: that run fails the post-check and undo cancels it). Undo
# cancels the one new run only when the record says `sent`; more than one new match, a new match without `sent`, or `sent`
# with no run showing after a further 30 s, are left for the owner (exit 5).
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

# gh_state <api path> — sets GH_STATE to exists (HTTP 200) or absent (HTTP 404); anything else stops the script
gh_state() {
  local out rc=0 proto code
  out=$(gh api --include "$1") || rc=$?
  read -r proto code _ <<< "${out%%$'\n'*}"
  case "$rc $proto ${code%$'\r'}" in
    "0 HTTP/"*" 200") GH_STATE=exists ;;
    [1-9]*" HTTP/"*" 404") GH_STATE=absent ;;
    *)
      echo "gh_state $1: exit $rc: $proto $code" >&2
      exit 75
      ;;
  esac
}

# ── arguments and reads: every phase runs them ──
usage() {
  echo "usage: baton rehearse|run kit:workflow-dispatch --repo <owner/name> --workflow <file.yml> --ref <branch> [--input <key>=<value>]..." >&2
}
REPO="" WF="" REF="" INPUTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo | --workflow | --ref | --input)
      if [ $# -lt 2 ]; then
        usage
        exit 64
      fi
      case "$1" in
        --repo) REPO=$2 ;;
        --workflow) WF=$2 ;;
        --ref) REF=$2 ;;
        --input)
          if ! [[ "$2" =~ ^[A-Za-z0-9_-]+=[^[:cntrl:]]*$ ]]; then
            echo "REFUSE input $2: a key of letters, digits, _ and -, then =, then a value with no control character" >&2
            exit 64
          fi
          INPUTS+=("$2")
          ;;
      esac
      shift 2
      ;;
    *)
      usage
      exit 64
      ;;
  esac
done
# a ref of letters, digits and ._/- only: it goes into API paths and query strings unencoded, where # + & % = would change them
if ! [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || ! [[ "$WF" =~ ^[A-Za-z0-9_.-]+\.ya?ml$ ]] \
  || ! [[ "$REF" =~ ^[A-Za-z0-9_][A-Za-z0-9._/-]*$ ]] || ! git check-ref-format "refs/heads/$REF" > /dev/null 2>&1; then
  usage
  exit 64
fi
# the baton state directory, as baton computes it; the run record lives under it
case "${XDG_STATE_HOME:-}" in
  /*) STATE_BASE=$XDG_STATE_HOME ;;
  *) STATE_BASE="$HOME/.local/state" ;;
esac
RECORDS="$STATE_BASE/vibemaestro/baton/records"
FIELDS=()
for kv in ${INPUTS[@]+"${INPUTS[@]}"}; do
  FIELDS+=(-f "$kv")
done

sha256_file() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}
sha256_text() {
  if command -v sha256sum > /dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
  else
    printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
  fi
}
# one record per target (repository, workflow and branch, by their hash) and per baton process ($PPID: the runner that runs
# this run's phases, run, post-check and undo, from one process): another run, even with a byte-identical signed plan, or one
# running at the same time, never reads this run's record
RECORD="$RECORDS/kit-workflow-dispatch-$(sha256_text "$REPO $WF $REF" | cut -c1-16)-$PPID.last"
PLANLINE=""
# plan_id — the sha256 of the signed plan baton hands the run and its undo (BATON_PLAN): which run a record belongs to
plan_id() {
  if [ -n "${BATON_PLAN:-}" ] && [ -f "$BATON_PLAN" ]; then
    sha256_file "$BATON_PLAN"
  fi
}
viewer() { gh api graphql -f query='query{viewer{login}}' --jq .data.viewer.login; }
# matching <login> — the runs this dispatch could have made, at any head: one "<id> <status> <head sha>" per line
matching() {
  gh api "repos/$REPO/actions/workflows/$WF/runs?event=workflow_dispatch&branch=$REF&per_page=100" \
    --jq ".workflow_runs[] | select(.triggering_actor.login == \"$1\") | \"\(.id) \(.status) \(.head_sha)\""
}
# new_runs — the matching runs the record does not hold, one "<id> <status> <head sha>" per line
new_runs() {
  local plan head login before _sent id status at
  read -r plan head login before _sent < "$RECORD"
  while read -r id status at; do
    [ -n "$id" ] || continue
    case "$before" in
      *",$id,"*) ;;
      *) printf '%s %s %s\n' "$id" "$status" "$at" ;;
    esac
  done < <(matching "$login")
}
# lines <text> — how many lines the text holds (0 when empty)
lines() {
  if [ -z "$1" ]; then
    echo 0
  else
    printf '%s\n' "$1" | wc -l | tr -d ' '
  fi
}
record() {
  local before
  before=$(matching "$2" | cut -d' ' -f1 | tr '\n' ',')
  mkdir -p "$RECORDS" && printf '%s %s %s %s\n' "$(plan_id)" "$1" "$2" ",${before}" > "$RECORD"
  find "$RECORDS" -name 'kit-workflow-dispatch-*.last' -mtime +7 -exec rm -f {} +     # records of runs over a week old
}
# dispatch — only the signed plan's dispatch; the record says `sent` once gh accepted it; then a wait for one new run (60 s)
dispatch() {
  local i=0 line
  if [ -z "${BATON_PLAN:-}" ] || ! grep -Fqx -- "$PLANLINE" "$BATON_PLAN"; then
    echo "REFUSE the dispatch line is not in the signed plan (the branch or the workflow moved since signing): nothing dispatched" >&2
    return 3
  fi
  gh workflow run "$WF" --repo "$REPO" --ref "$REF" ${FIELDS[@]+"${FIELDS[@]}"}
  read -r line < "$RECORD"
  printf '%s sent\n' "$line" > "$RECORD.new" && mv -f "$RECORD.new" "$RECORD"     # whole or not at all
  while [ "$i" -lt 30 ]; do
    if [ -n "$(new_runs)" ]; then
      return 0
    fi
    sleep 2
    i=$((i + 1))
  done
  echo "no new run of $WF on $REF showed within 60 s" >&2
  return 1
}
# declares_dispatch <workflow text> — a workflow_dispatch trigger: `on: workflow_dispatch`, `on: [..., workflow_dispatch]`, or
# a `workflow_dispatch:` key or `- workflow_dispatch` item on a line of its own; a comment or a step's expression does not count
declares_dispatch() {
  local line
  while IFS= read -r line; do
    line=${line%%[[:space:]]#*}
    if [[ "$line" =~ ^(on|\"on\"|\'on\'):[^#]*(^|[^A-Za-z0-9_])workflow_dispatch([^A-Za-z0-9_]|$) ]] \
      || [[ "$line" =~ ^[[:space:]]+(-[[:space:]]*)?[\"\']?workflow_dispatch[\"\']?[[:space:]]*(:[[:space:]]*(\{.*\}|null|~)?)?[[:space:]]*$ ]]; then
      return 0
    fi
  done <<< "$1"
  return 1
}

# in_sandbox — a sandbox pod session: SEAT and INTENT_SLUG both set and not blank (the test of in_sandbox() in baton.py: one alone
# can sit in a laptop shell). Its token has no actions:write, so a write to Actions there ends in HTTP 403 after the owner's sign.
in_sandbox() {
  local s=${SEAT:-} i=${INTENT_SLUG:-}
  [ -n "${s//[[:space:]]/}" ] && [ -n "${i//[[:space:]]/}" ]
}

# ── the act: every change through write() ──
act() {
  local vis head blob body login
  if in_sandbox; then
    echo "REFUSE a sandbox session (SEAT and INTENT_SLUG are set): its token cannot write to Actions (HTTP 403). Ask the coordinator to dispatch workflow $WF on $REPO ref $REF" >&2
    return 3
  fi
  vis=$(gh api "repos/$REPO" --jq '"\(.private) \(.visibility)"' 2>&1 || true)
  if [ "$vis" != "true private" ]; then
    echo "REFUSE $REPO does not read private (private, visibility: $vis): this kit dispatches in private repositories only" >&2
    return 3
  fi
  gh_state "repos/$REPO/git/ref/heads/$REF"
  if [ "$GH_STATE" != exists ]; then
    echo "REFUSE $REPO has no branch $REF" >&2
    return 3
  fi
  head=$(gh api "repos/$REPO/git/ref/heads/$REF" --jq .object.sha)
  gh_state "repos/$REPO/contents/.github/workflows/$WF?ref=$head"
  if [ "$GH_STATE" != exists ]; then
    echo "REFUSE .github/workflows/$WF is not on $REF at $head" >&2
    return 3
  fi
  blob=$(gh api "repos/$REPO/contents/.github/workflows/$WF?ref=$head" --jq .sha)
  body=$(gh api -H 'Accept: application/vnd.github.raw' "repos/$REPO/contents/.github/workflows/$WF?ref=$head")
  if ! declares_dispatch "$body"; then
    echo "REFUSE .github/workflows/$WF at $head declares no workflow_dispatch" >&2
    return 3
  fi
  login=$(viewer)
  write "record the runs of $WF on $REF by $login before the dispatch" record "$head" "$login"
  PLANLINE="dispatch workflow $WF on $REPO ref $REF at $head blob $blob inputs ${INPUTS[*]:-none}"
  write "$PLANLINE" dispatch
}

# ── post-check: exactly one new run, at the pinned head ──
postcheck() {
  local runs n plan head _rest id status at
  [ -f "$RECORD" ] || return 1
  read -r plan head _rest < "$RECORD"
  runs=$(new_runs)
  n=$(lines "$runs")
  echo "new runs of $WF on $REF: ${runs:-none}"
  [ "$n" -eq 1 ] || return 1
  read -r id status at <<< "$runs"
  [ "$at" = "$head" ] || { echo "run $id is at $at, not the signed head $head" >&2; return 1; }
}

# ── undo: from the record; the one run this dispatch made is cancelled while it runs ──
undo() {
  local plan head login before sent mine runs id status at n i=0
  if [ ! -f "$RECORD" ]; then
    echo "no run record: the dispatch never ran, nothing to cancel"
    return 0
  fi
  read -r plan head login before sent < "$RECORD"
  mine=$(plan_id)
  if [ -z "$mine" ]; then
    echo "LEAVE no signed plan (BATON_PLAN): cannot tell whether $RECORD is this run's" >&2
    return 1
  fi
  if [ "$plan" != "$mine" ]; then
    echo "the run record $RECORD is an earlier run's: nothing of this run to cancel"
    return 0
  fi
  runs=$(new_runs)
  n=$(lines "$runs")
  while [ "$n" -eq 0 ] && [ "$sent" = sent ] && [ "$i" -lt 6 ]; do      # gh accepted it: the run may list late
    sleep 5
    runs=$(new_runs)
    n=$(lines "$runs")
    i=$((i + 1))
  done
  if [ "$n" -gt 1 ]; then
    echo "LEAVE $n new runs of $WF on $REF (${runs//$'\n'/; }): cannot tell which one this dispatch made; left alone" >&2
    return 1
  fi
  if [ "$n" -eq 1 ] && [ "$sent" != sent ]; then
    echo "LEAVE run ${runs%% *} of $WF is new, but gh never accepted this dispatch: it may be someone else's; left alone" >&2
    return 1
  fi
  if [ "$n" -eq 0 ] && [ "$sent" = sent ]; then
    echo "LEAVE gh accepted the dispatch and no new run of $WF on $REF shows after 30 s more: left for the owner (the record stays)" >&2
    return 1
  fi
  if [ "$n" -eq 1 ]; then
    read -r id status at <<< "$runs"
    if [ "$status" = completed ]; then
      echo "run $id of $WF has finished: it stays (GitHub keeps every run)"
    else
      write "cancel $REPO run $id of $WF (at $at)" gh run cancel "$id" -R "$REPO"
    fi
  else
    echo "no new run of $WF on $REF and gh never accepted the dispatch: nothing landed"
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
