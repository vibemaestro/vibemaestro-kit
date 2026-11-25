#!/usr/bin/env bash
# Purpose: merge 1 to 8 pull requests kit:merge-pr refuses by design (a squash; a back-merge with a merge commit, as kit:merge-pr's back-merge lane says), under one owner signature, each pinned to its head; per PR its accepted red checks, a required image and the admin bypass are bound by the signature
# Targets: the pull requests named by the arguments (repository, number), and their base branches; a record under <state-dir>/records of a merge the run could not confirm, kept only for its undo
# Blast: one merge per PR (a squash, or a merge commit for a back-merge), into its base branch, in the given order; nothing else
# Undo: none: a merge is not reversible. A run that stops half way keeps the merges before the stop; the run and its undo name each of them, and the way back is a revert PR for each, opened at once and told to the owner
# Pre: for every PR: it is open, not draft, its head is the given SHA, GitHub reports it MERGEABLE, kit:merge-pr's back-merge lane does not refuse it, every check run and status on that head (the latest per workflow and name) is green except the checks named by --accept-red (which must exist and be red), or with --no-checks the head has none, the --require-image tag exists, and the changed files hash to the value in its plan line; read again before each merge, the plan line equal to the signed one
# Stops: security-boundary, owner-acts
#   Why: an owner merge is a PR kit:merge-pr refuses by design, so the owner decides it from the card and signs; --admin
#   bypasses branch protection.
# Usage: <owner/repo> <pr> <sha40> [--accept-red <check>]... [--require-image <ref>] [--no-checks] [--admin], again per PR (1 to 8)
# Each: merge *
#
# The kit baton kit:owner-merge: one card and one owner dialog for a sitting of owner merges. The session's three steps:
#   <launcher> go kit:owner-merge <groups>          (exit 8: the card; the owner signs `sign --by owner --seal <seal> …`)
#   <launcher> run kit:owner-merge <groups>
# A word that is not an option starts the next PR's group of three words. Every word is a plain word (the owner's dialog shows the
# command as typed), so a check name with a space or a parenthesis is percent-encoded (`build%20%28linux%29`); the plan line shows it
# decoded. Run merges in the given order and reads each PR again just before its merge: a later PR of the same repository merges
# when GitHub reports it MERGEABLE after the earlier merge (it answers UNKNOWN while it recomputes: read again, up to 6 times 5 s
# apart). A conflict, a moved head, a changed plan line or a refused merge stops the run at that PR; the merges before it stay.
# A merge call that fails with anything but GitHub's refusal (a 5xx, a timeout, a dropped connection) may have landed: the PR,
# read back, decides (merged at the signed head and base: done; open there: one more call; else the state is unknown), and a stop
# from there names the PR in a record its undo reads (and a PR a second call only queued stays in it as the run goes on), so the
# undo leaves that PR to the owner when it reads it unread, open or merged at its signed head, instead of advising a revert.
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

# ── arguments: every phase parses them ──
MAX=8
USAGE="usage: go kit:owner-merge <owner/repo> <pr> <head sha40> [--accept-red <check>]... [--require-image <ref>] [--no-checks] [--admin] [<owner/repo> <pr> <head sha40> [options]]...  (1 to $MAX PRs; each option belongs to the PR before it; a check name is percent-encoded: internal-term%20scan)"
usage() { echo "REFUSE $1" >&2; echo "$USAGE" >&2; exit 64; }
[ $# -gt 0 ] || usage "no pull request named"
G_REPO=()
G_PR=()
G_HEAD=()
G_ACC=()
G_IMG=()
G_NOCHK=()
G_ADMIN=()
N=0
while [ $# -gt 0 ]; do
  case "$1" in
    *[!A-Za-z0-9_./:@%+,=-]*) usage "not a plain word: $1" ;;
  esac
  case "$1" in
    --*)
      [ "$N" -gt 0 ] || usage "$1 before the first pull request"
      i=$((N - 1))
      case "$1" in
        --no-checks) G_NOCHK[$i]=yes; shift ;;
        --admin) G_ADMIN[$i]=yes; shift ;;
        --accept-red | --require-image)
          [ $# -ge 2 ] && [ -n "$2" ] && case "$2" in --*) false ;; esac || usage "$1 needs a value (${G_REPO[$i]}#${G_PR[$i]})"
          case "$2" in *[!A-Za-z0-9_./:@%+,=-]*) usage "not a plain word: $2" ;; esac
          if [ "$1" = --accept-red ]; then G_ACC[$i]="${G_ACC[$i]} $2"; else G_IMG[$i]=$2; fi
          shift 2
          ;;
        *) usage "unknown option $1" ;;
      esac
      ;;
    *)
      [ $# -ge 3 ] || usage "a pull request needs three words: <owner/repo> <pr> <head sha40> (got: $*)"
      case "$1" in
        */*/* | /* | */ | -* | .* | *[!A-Za-z0-9_./-]*) usage "repository must be owner/name: $1" ;;
        */*) ;;
        *) usage "repository must be owner/name: $1" ;;
      esac
      case "$2" in
        '' | 0* | *[!0-9]*) usage "pull request must be a number: $2" ;;
      esac
      case "$3" in
        *[!0-9a-f]*) usage "head must be a full SHA, 40 lower-case hex characters: $3" ;;
      esac
      [ ${#3} -eq 40 ] || usage "head must be 40 hex characters: $3"
      for ((j = 0; j < N; j++)); do
        [ "${G_REPO[$j]}#${G_PR[$j]}" != "$1#$2" ] || usage "$1#$2 is named twice"
      done
      [ "$N" -lt "$MAX" ] || usage "more than $MAX pull requests in one run"
      G_REPO[$N]=$1
      G_PR[$N]=$2
      G_HEAD[$N]=$3
      G_ACC[$N]=""
      G_IMG[$N]=""
      G_NOCHK[$N]=no
      G_ADMIN[$N]=no
      N=$((N + 1))
      shift 3
      ;;
  esac
done
for ((i = 0; i < N; i++)); do
  [ "${G_NOCHK[$i]}" = no ] || [ -z "${G_ACC[$i]}" ] || usage "--no-checks never goes beside --accept-red (${G_REPO[$i]}#${G_PR[$i]})"
done

# decode <percent-encoded check name> — the name as GitHub shows it; no `|` or control character (the check lines split on `|`)
decode() {
  python3 -I -c 'import sys, urllib.parse
n = urllib.parse.unquote(sys.argv[1], errors="strict")
if not n or "|" in n or any(ord(c) < 32 or ord(c) == 127 for c in n):
    sys.exit(1)
print(n)' "$1"
}
for ((i = 0; i < N; i++)); do
  for c in ${G_ACC[$i]}; do
    decode "$c" > /dev/null || usage "--accept-red $c: not a check name once decoded (${G_REPO[$i]}#${G_PR[$i]})"
  done
done

# ── reads: what one PR is now ──
# view <i> [wait] — state, draft, head, mergeable, base, merge commit, auto-merge request and head ref of PR i, split on the unit
# separator (no branch name holds a control character); with `wait`, read again
# while GitHub answers UNKNOWN for an open PR (it recomputes mergeability after its base moves), up to 6 times 5 s apart
view() {
  local info try
  for try in 1 2 3 4 5 6; do
    info=$(gh pr view "${G_PR[$1]}" -R "${G_REPO[$1]}" --json state,isDraft,headRefOid,mergeable,baseRefName,mergeCommit,autoMergeRequest,headRefName \
      -q '[.state, .isDraft, .headRefOid, .mergeable, .baseRefName, (.mergeCommit.oid // ""), (.autoMergeRequest != null), .headRefName] | map(tostring) | join("\u001f")') \
      || return 1
    case "${2:-}/$info" in "wait/OPEN"$'\x1f'*$'\x1f'UNKNOWN$'\x1f'*) [ "$try" = 6 ] || sleep 5 ;; *) break ;; esac
  done
  IFS=$'\x1f' read -r ST DRAFT R_HEAD MERGEABLE BASE MC QUEUED HEAD_REF <<EOF
$info
EOF
  [ -n "$ST" ]
}

# ci <repo> <head> [accepted check name]... — the checks of a head as the guarded merge reads them (gates/backends/github_actions.py
# and merge_guard.latest_runs): every check run (filter=all, as many as GitHub counts) and commit status, the latest per workflow
# and name, a skipped run never hiding another. A run is green when completed success, skipped or neutral and its workflow run is
# neither cancelled, still running, nor red with every one of its check runs green (a token can rewrite a check run, not its
# workflow run); pending when not completed; red otherwise.
# An accepted name (or workflow/name) must name a red run. Prints `COUNTS <all> <green> <accepted red> <green check runs not
# skipped>`, then one `check` line each.
ci() {
  python3 -I -B -c '
import json, sys
sys.path.insert(0, sys.argv[1])
try:
    from backends import github_actions
    import merge_guard
    runs = merge_guard.latest_runs(github_actions.runs(sys.argv[2], sys.argv[3]))
except Exception as e:
    sys.exit("cannot read the checks of %s: %s" % (sys.argv[3], e))
GREEN = ("success", "skipped", "neutral")
def own(r):
    if r.get("status") != "completed":
        return "pending"
    return "red" if r.get("_bad_time") or r.get("conclusion") not in GREEN else "green"
def state(r):
    run = r.get("run") or {}
    if own(r) != "green" or not run:
        return own(r)
    if run.get("status") != "completed" or run.get("conclusion") == "cancelled":
        return "red"
    # a red workflow run whose check runs all say green: one was rewritten
    mates = [o for o in runs if (o.get("run") or {}).get("id") == run.get("id")]
    return "red" if run.get("conclusion") not in GREEN and all(own(o) == "green" for o in mates) else "green"
show = lambda r: json.dumps("%s|%s|%s|%s" % (merge_guard.label(r), r.get("status"), r.get("conclusion"), state(r)))[1:-1]
accepted = set()
for n in sys.argv[4:]:
    named = [i for i, r in enumerate(runs) if n in (r.get("name"), merge_guard.label(r))]
    if not named:
        sys.exit("--accept-red %s: no such check on the head" % n)
    red = [i for i in named if state(runs[i]) == "red"]
    if not red:
        sys.exit("--accept-red %s: it is not red (%s)" % (n, ", ".join(show(runs[i]) for i in named)))
    accepted.update(red)
real = sum(state(r) == "green" and r.get("kind") == "check" and r.get("conclusion") != "skipped" for r in runs)
print("COUNTS %d %d %d %d" % (len(runs), sum(state(r) == "green" for r in runs), len(accepted), real))
for r in runs:
    print("  check " + show(r))
' "$BATON_PLUGIN_ROOT/gates" "$@"
}

# lane <repo> <head> <base> <head ref> — the guarded merge's back-merge lane (merge_guard.backmerge), read now: one line
# `backmerge <ok|n/a|FAIL|??>: <why>`, then `LANE merge-commit` (a backmerge/* head that is the release tip, or one merge of it with
# a commit of the base, into the default branch) or `LANE squash`; fails, after the first line, when the lane refuses (another
# backmerge/* head, or another head already on release or holding a release tip the base lacks) or cannot be read
lane() {
  python3 -I -B -c '
import sys
sys.path.insert(0, sys.argv[1])
class V(object):
    said = []
    def cond(self, _n, good, detail, notes=()): self.said.append(("ok" if good else "FAIL", detail))
    def na(self, _n, detail): self.said.append(("n/a", detail))
    def unknown(self, _n, detail, notes=()): self.said.append(("??", detail))
try:
    import merge_guard
    a = type("A", (), {"repo": sys.argv[2], "head": sys.argv[3]})
    mc = merge_guard.backmerge(a, {"headRefName": sys.argv[5]}, sys.argv[4], V())
except Exception as e:
    V.said, mc = [("??", "it cannot be read: %s" % e)], False
verdict, why = V.said[-1] if V.said else ("??", "it said nothing")
print("backmerge %s: %s" % (verdict, why))
if verdict in ("FAIL", "??"):
    sys.exit(1)
print("LANE " + ("merge-commit" if mc else "squash"))
' "$BATON_PLUGIN_ROOT/gates" "$@"
}

# check <i> — every read of PR i and its preconditions; sets PLAN_LINE and METHOD, or prints `REFUSE <repo>#<pr> …` and returns 3
check() {
  local i=$1 id="${G_REPO[$1]}#${G_PR[$1]}" head=${G_HEAD[$1]} img=${G_IMG[$1]} checks files files_sha n_files n_all n_green
  local n_acc n_real acc_list="" c names=() img_state=none lanes
  view "$i" wait || { echo "REFUSE $id: cannot read the pull request" >&2; return 3; }
  lanes=$(lane "${G_REPO[$i]}" "$head" "$BASE" "$HEAD_REF") || { echo "REFUSE $id: $lanes" >&2; return 3; }
  METHOD=$(printf '%s\n' "$lanes" | sed -n 's/^LANE //p')
  [ -n "$METHOD" ] || { echo "REFUSE $id: the back-merge lane printed no verdict: $lanes" >&2; return 3; }
  for c in ${G_ACC[$i]}; do
    names+=("$(decode "$c")")
  done
  checks=$(ci "${G_REPO[$i]}" "$head" ${names[@]+"${names[@]}"} 2>&1) || { echo "REFUSE $id: $checks" >&2; return 3; }
  read -r n_all n_green n_acc n_real <<EOF
$(printf '%s\n' "$checks" | sed -n 's/^COUNTS //p')
EOF
  [ -n "$n_real" ] || { echo "REFUSE $id: the checks of $head read no counts" >&2; return 3; }
  acc_list=$(printf '%s\n' ${names[@]+"${names[@]}"} | awk 'NF' | sort -u | paste -sd, -)
  if [ -n "$img" ]; then
    command -v docker > /dev/null || { echo "REFUSE $id: --require-image needs docker to read $img, and there is none" >&2; return 3; }
    if docker manifest inspect "$img" > /dev/null 2>&1; then img_state=present; else img_state=absent; fi
  fi
  files=$(gh pr diff "${G_PR[$i]}" -R "${G_REPO[$i]}" --name-only | sort) || { echo "REFUSE $id: cannot read the changed files" >&2; return 3; }
  files_sha=$(printf '%s\n' "$files" | python3 -I -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:16])')
  n_files=$(printf '%s\n' "$files" | awk 'NF' | wc -l | tr -d ' ')
  echo "READ $id: state $ST draft $DRAFT head $R_HEAD ($HEAD_REF) mergeable $MERGEABLE base $BASE; checks $n_green/$n_all green, accepted red: ${acc_list:-none}; image ${img:-none} $img_state; $n_files files (sha $files_sha)"
  printf '%s\n' "$checks" | grep '^  check ' || true
  printf '%s\n' "$lanes" | sed -n 's/^backmerge /  backmerge /p'
  [ "$ST" != MERGED ] || { echo "REFUSE $id is already merged (merge commit $MC)" >&2; return 3; }
  [ "$ST" = OPEN ] || { echo "REFUSE $id is $ST" >&2; return 3; }
  [ "$DRAFT" = false ] || { echo "REFUSE $id is a draft" >&2; return 3; }
  [ "$QUEUED" = false ] || { echo "REFUSE $id has an auto-merge request already" >&2; return 3; }
  [ "$R_HEAD" = "$head" ] || { echo "REFUSE $id: head is $R_HEAD, not the post-checked $head" >&2; return 3; }
  [ "$MERGEABLE" = MERGEABLE ] || { echo "REFUSE $id: GitHub reports $MERGEABLE" >&2; return 3; }
  if [ "${G_NOCHK[$i]}" = yes ]; then
    [ "$n_all" -eq 0 ] || { echo "REFUSE $id: --no-checks: the head has $n_all checks; judge them instead" >&2; return 3; }
  else
    { [ "$n_all" -gt 0 ] && [ $((n_green + n_acc)) = "$n_all" ]; } \
      || { echo "REFUSE $id: checks: $n_green green + $n_acc accepted red of $n_all on the head" >&2; return 3; }
    [ "$n_real" -gt 0 ] || { echo "REFUSE $id: no check run passed on the head (only skipped runs or statuses)" >&2; return 3; }
  fi
  [ "$img_state" != absent ] || { echo "REFUSE $id: the required image $img does not exist" >&2; return 3; }
  PLAN_LINE="merge $id head $head into $BASE by $METHOD ($n_files files sha $files_sha; checks $n_green/$n_all green, accepted red ${acc_list:-none}, no-checks ${G_NOCHK[$i]}; image ${img:-none} $img_state; admin ${G_ADMIN[$i]}; GitHub pins the head)"
}

MERGED=""                                 # the PRs this run merged, in order; only merge() adds to it
UNSETTLED=""                              # the PRs a second call only queued after a call that may have landed
# unsettled — on stdin gh's error text of a failed merge call; prints why the call may still have reached GitHub (a 5xx, a
# timeout, a dropped connection, any text that is not GitHub's refusal), or fails on GitHub's refusal (a GraphQL error, a 4xx):
# the guard's own reading (gates/backends); "-" for a refusal, so a helper that cannot run fails toward "may have landed"
unsettled() {
  python3 -I -B -c 'import sys
sys.path.insert(0, sys.argv[1])
import backends
print(backends.unsettled(sys.stdin.read()) or "-")' "$BATON_PLUGIN_ROOT/gates"
}
# wait_s — the wait before a failed merge call's read-back, and between its reads: the guard's (backends.retry_waits, 5 s)
wait_s() {
  python3 -I -B -c 'import sys
sys.path.insert(0, sys.argv[1])
import backends
print("%g" % backends.retry_waits()[0])' "$BATON_PLUGIN_ROOT/gates"
}
# readback <i> <wait> — view PR i, asked again up to 3 times <wait> s apart while it cannot be read
readback() {
  local r
  for r in 1 2 3; do
    view "$1" && return 0
    [ "$r" = 3 ] || sleep "$2"
  done
  return 1
}
STOP_WHY=""                               # why merge() stopped, for the stop line; set by merge()
# every PR whose merge call may still land is named in a record kept only for its undo (BATON_UNDO_ONLY): added before its first
# call, dropped once the run settles it (merged at its signed head; its first call refused; its first call's exit 0, taken as
# before, the post-check judging it), the file removed when it names
# none; a stop, or a queued second call, leaves it there, so the undo leaves that PR to the owner rather than advising a revert
# of a merge that may be the signed one
case "${XDG_STATE_HOME:-}" in
  /*) STATE_BASE=$XDG_STATE_HOME ;;
  *) STATE_BASE="$HOME/.local/state" ;;
esac
UNCONFIRMED="$STATE_BASE/vibemaestro/baton/records/kit-owner-merge-unconfirmed-$$-$RANDOM$RANDOM"
LISTED=no
# in_flight <id> — the record names PR <id> too (a signed run only); fails when it cannot be written
in_flight() {
  [ -n "${BATON_UNDO_ONLY:-}" ] || return 0
  mkdir -p "${UNCONFIRMED%/*}" && printf '%s\n' "$1" >> "$UNCONFIRMED" || return 1
  [ "$LISTED" = yes ] || { printf '%s\n' "$UNCONFIRMED" >> "$BATON_UNDO_ONLY" && LISTED=yes; }
}
# settled <id> — the run settles PR <id> (merged at its signed head; its first call refused, or exited 0 as before): the record
# drops it, and is removed when it names no other
settled() {
  local rest g=0
  [ "$LISTED" = yes ] || return 0
  rest=$(grep -vxF "$1" "$UNCONFIRMED") || g=$?
  case $g in
    0) { printf '%s\n' "$rest" > "$UNCONFIRMED.new" && mv -f "$UNCONFIRMED.new" "$UNCONFIRMED"; } \
         || { rm -f "$UNCONFIRMED.new"; false; } ;;    # the other ids survive a failed write
    1) rm -f "$UNCONFIRMED" ;;
    *) false ;;
  esac || echo "the undo record $UNCONFIRMED cannot be updated after $1 settled: the undo may hold $1, or not read the record; tell the owner" >&2
}
# unconfirmed_ids — in undo: the PRs its run's records name, one per line
unconfirmed_ids() {
  local p
  { [ -n "${BATON_UNDO_ONLY:-}" ] && [ -f "$BATON_UNDO_ONLY" ]; } || return 0
  while IFS= read -r p; do
    case "$p" in */kit-owner-merge-unconfirmed-*) [ ! -f "$p" ] || cat "$p" ;; esac
  done < "$BATON_UNDO_ONLY"
}
# merge <i> — the merge of PR i by its METHOD (a squash, or a merge commit for a back-merge), pinned to its head, only while the plan line just computed is the signed one. The first
# call's answer is taken as before (0: merged or queued, the post-check judges; GitHub's refusal: the refused stop); any other
# failure (a 5xx, a timeout, a dropped connection) may have landed, and from there on one place decides, on the PR read
# back after a short wait (gh exits 0 on a PR merged already, without the head pin, so a second call's exit 0 is read back too):
# merged at the signed head into the signed base, the merge is done; open at the signed head and base, one more call, or, after
# the second, a queued merge (exit 0) for the post-check or the refused stop; anything else, the state unknown. The undo record
# names the PR from before its first call until the run settles it, so every stop after a call that may have landed leaves it
# there, and a PR the second call only queued stays in it as the run goes on; a record that cannot be written stops the run
# before the call
merge() {
  local i=$1 id="${G_REPO[$1]}#${G_PR[$1]}" base=$BASE head=${G_HEAD[$1]} try out rc why said wait at admin=() flag=--squash
  STOP_WHY="the merge was refused"
  [ "$PLAN_LINE" = "$(sed -n "$((i + 1))p" "${BATON_PLAN:?no signed plan}")" ] \
    || { echo "REFUSE $id: its plan line is not the signed one (the world moved)" >&2; return 3; }
  [ "${G_ADMIN[$i]}" = no ] || admin=(--admin)
  [ "$METHOD" = squash ] || flag=--merge                # the plan line just compared names the method
  in_flight "$id" || { STOP_WHY="the undo record $UNCONFIRMED cannot be written: no merge call made"; return 1; }
  for try in 1 2; do
    rc=0
    out=$(gh pr merge "${G_PR[$i]}" -R "${G_REPO[$i]}" "$flag" ${admin[@]+"${admin[@]}"} --match-head-commit "$head" 2>&1) || rc=$?
    why=""
    if [ "$rc" = 0 ]; then
      [ -z "$out" ] || printf '%s\n' "$out"
      [ "$try" = 2 ] || break
      said="exited 0 on the second try"
    else
      [ -z "$out" ] || printf '%s\n' "$out" >&2
      why=$(printf '%s\n' "$out" | unsettled) || why="an error the kit could not read"
      [ "$why" != - ] || why=""
      [ -n "$why" ] || [ "$try" = 2 ] || { settled "$id"; return 1; }    # a refusal of the first call: nothing may have landed
      said="failed (${why:-rc $rc})"
    fi
    # the call may have landed: the PR, read back, decides
    wait=$(wait_s) || wait=5
    [ -z "$why" ] || sleep "$wait"
    if ! readback "$i" "$wait"; then
      STOP_WHY="the merge call $said and the PR cannot be read back: it may have merged, the state is unknown"
      return 1
    fi
    at=no
    [ "$R_HEAD" != "$head" ] || [ "$BASE" != "$base" ] || at=yes
    if [ "$ST" = MERGED ] && [ -n "$MC" ] && [ "$at" = yes ]; then
      if [ "$rc" = 0 ]; then said="$said and"; else said="$said, but"; fi
      echo "$id: the merge call $said the PR reads merged at its signed head as $MC: the merge landed"
      break
    fi
    if [ "$ST" = OPEN ] && [ "$at" = yes ]; then
      if [ "$try" = 1 ]; then
        echo "$id: the merge call $said and the PR, read again after ${wait} s, is still open at its signed head: one more try"
        continue
      fi
      if [ "$rc" = 0 ]; then                       # the second call only queued it: the post-check judges, and the first call may
        UNSETTLED="${UNSETTLED:+$UNSETTLED, }$id"  # still land, so the record keeps it
        return 0
      fi
      STOP_WHY="the merge call $said on one more try, the PR open at its signed head; a merge call may still land, the state is unknown"
      return 1
    fi
    STOP_WHY="the merge call $said and the PR reads $ST at head $R_HEAD into $BASE, merge commit ${MC:-none}: not merged at its signed head and base, the state is unknown"
    return 1
  done
  settled "$id"
  MERGED="${MERGED:+$MERGED, }$id"
}

# ── the act: PR by PR in the given order, each read and checked just before its write; a stop names every merge before it ──
stopped() {
  echo "STOPPED at ${G_REPO[$1]}#${G_PR[$1]}: $2; merged before the stop: ${MERGED:-none}${UNSETTLED:+; queued after a failed call, may still land: $UNSETTLED (the owner decides)}" >&2
  [ -z "$MERGED" ] || echo "a merge is not undone: open a revert PR for each merged PR, and tell the owner now" >&2
  return 3
}
act() {
  local i
  for ((i = 0; i < N; i++)); do
    check "$i" || { stopped "$i" "a precondition fails"; return 3; }
    write "$PLAN_LINE" merge "$i" || { stopped "$i" "${STOP_WHY:-the merge was refused}"; return 3; }
  done
  echo "PLAN-COUNT $N"
}

# ── post-check: every PR merged, at its head ──
postcheck() {
  local i
  for ((i = 0; i < N; i++)); do
    view "$i" && [ "$ST" = MERGED ] && [ -n "$MC" ] && [ "$R_HEAD" = "${G_HEAD[$i]}" ] \
      || { echo "${G_REPO[$i]}#${G_PR[$i]} is not merged at ${G_HEAD[$i]} (state ${ST:-unread})" >&2; return 1; }
    echo "${G_REPO[$i]}#${G_PR[$i]} merged as $MC"
  done
}

# ── undo: a merge cannot be undone; name each PR that merged ──
# signed_base <i> — the base PR i's signed plan line names
signed_base() {
  sed -n "$(($1 + 1))p" "${BATON_PLAN:-/dev/null}" | sed -n 's/^merge [^ ]* head [0-9a-f]* into \(.*\) by [a-z-]* ([0-9]* files sha .*/\1/p'
}
undo() {
  local i id rd left="" held="" mine sbase
  mine=$(unconfirmed_ids)
  for ((i = 0; i < N; i++)); do
    id="${G_REPO[$i]}#${G_PR[$i]}"
    rd=yes
    view "$i" || rd=no
    if printf '%s\n' "$mine" | grep -qxF "$id"; then
      # a merge call of the run on this PR may still land (the PR it stopped on, or one a second call only queued): never revert
      # advice, the owner decides
      if [ "$rd" = no ]; then
        echo "unread, and the run's merge call may have landed: $id: the state is unknown"
        held="${held:+$held, }$id (unread)"
        continue
      elif [ "$ST" = MERGED ] && [ "$R_HEAD" = "${G_HEAD[$i]}" ]; then
        sbase=$(signed_base "$i")
        if [ "$BASE" = "$sbase" ]; then
          echo "merged at its signed head, not confirmed by the run: $id as ${MC:-?}: the owner decides whether it stays"
        else
          echo "merged at its signed head into $BASE, not the signed ${sbase:-base}, not confirmed by the run: $id as ${MC:-?}: the owner decides"
        fi
        held="${held:+$held, }$id"
        continue
      elif [ "$ST" = OPEN ] && [ "$QUEUED" != true ] && [ "$R_HEAD" = "${G_HEAD[$i]}" ]; then
        echo "open at its signed head, and the run's merge call may still land: $id: the state is unknown (a merge queue may hold it: take it out if the owner says so)"
        held="${held:+$held, }$id (open)"
        continue
      fi
    fi
    if [ "$rd" = no ]; then
      left="${left:+$left, }$id (unread)"
    elif [ "$ST" = MERGED ]; then
      echo "merged, not undone: $id as $MC: open a revert PR"
      left="${left:+$left, }$id"
    elif [ "$ST" = OPEN ] && [ "$QUEUED" = true ]; then
      echo "queued, may still merge: $id: disable its auto-merge or take it out of the queue now"
      left="${left:+$left, }$id (queued)"
    fi
  done
  [ -z "$held" ] || echo "a merge call of this run may still land: $held; tell the owner now, who decides whether it stays (no revert before that)" >&2
  [ -z "$left" ] || { echo "a merge cannot be undone here: $left; the way back is a revert PR each (a queued one taken out first), told to the owner now" >&2; return 1; }
  [ -z "$held" ] || return 1
  echo "nothing merged: nothing to undo"
}

case "$PHASE" in
  rehearse) act; echo "VERDICT rehearse ok" ;;
  run) act; echo "VERDICT run ok" ;;
  postcheck) postcheck; echo "VERDICT postcheck ok" ;;
  undo) undo; echo "VERDICT undo ok" ;;
  *) echo "unknown phase: $PHASE" >&2; exit 64 ;;
esac
