#!/usr/bin/env bash
# Purpose: bring a pull request's branch up to date with its base: GitHub's update-branch API (it only merges, there is no rebase), pinned to the signed head
# Targets: the head branch of the pull request named by --repo and --pr
# Blast: one merge commit of the base into that branch (the branch moves forward by it; nothing is rewritten), and the checks GitHub starts on the new head; nothing else
# Undo: none by this script: a merge commit on a branch cannot be taken back cleanly (dropping it is a force-push, a revert adds a second commit). Undo confirms that nothing was updated, or names the head the branch now holds and what it leaves, for the owner to decide
# Pre: the PR is open, not a draft, not a back-merge, from a branch of the same repository, its head is the signed head, it is behind its base and GitHub does not report a conflict; read again right before the call, which GitHub pins with expected_head_sha
# Stops: none
#   Why none: the call adds one commit on top of the signed head and moves no ref backwards (no rebase, no force). expected_head_sha
#   makes GitHub refuse it when the branch moved after the signature. A conflict, a fork, a draft, a closed PR or a PR that is not behind
#   are refused at rehearse and again before the call, so nothing is written. A back-merge (head ref backmerge/*) is refused too: the
#   release process resolves it above the release tip and never merges the base into that branch. The merge commit stays (see Undo), which is why the
#   run is followed by a read of the new head and a wait for CI on it before the PR merges.
# Usage: --repo <owner/name> --pr <n> --head <sha40>
# Expect: pr-update-branch *
#
# The kit baton kit:pr-update-branch: `<launcher> go kit:pr-update-branch --repo <owner/name> --pr <n> --head <full sha>`. The head is
# the PR's head the coordinator rehearsed kit:merge-pr at; the post-check prints `new head <sha>`, the head to wait for CI on and to
# merge at. The call sends only expected_head_sha: GitHub's endpoint merges the base into the branch and has no other mode. GitHub
# answers the call at once and makes the merge commit a moment later: a failed post-check is read again by the runner.
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
USAGE="usage: go kit:pr-update-branch --repo <owner/name> --pr <n> --head <full sha>"
# usage <why> — the refusal on one line, control bytes of a refused argument dropped
usage() { printf 'REFUSE %s\n' "$(printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177')" >&2; echo "$USAGE" >&2; exit 64; }

REPO="" PR="" HEAD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo | --pr | --head)
      [ $# -ge 2 ] || usage "$1 takes a value"
      case "$1" in --repo) REPO=$2 ;; --pr) PR=$2 ;; --head) HEAD=$2 ;; esac
      shift 2
      ;;
    *) usage "unknown argument: $1" ;;
  esac
done
[ -n "$REPO" ] || usage "no --repo"
[ -n "$PR" ] || usage "no --pr"
[ -n "$HEAD" ] || usage "no --head"
case "$REPO" in
  */*/* | /* | */ | -* | .* | */. | */.. | *[!A-Za-z0-9_./-]*) usage "--repo must be owner/name: $REPO" ;;
  */*) ;;
  *) usage "--repo must be owner/name: $REPO" ;;
esac
case "$PR" in
  0* | *[!0-9]*) usage "--pr must be a pull request number: $PR" ;;
esac
HEAD=$(printf '%s' "$HEAD" | tr 'ABCDEF' 'abcdef')
case "$HEAD" in
  *[!0-9a-f]*) usage "--head must be a full 40-character sha: $HEAD" ;;
esac
[ ${#HEAD} -eq 40 ] || usage "--head must be a full 40-character sha: $HEAD"

# ── reads ──
# read_pr — the PR's fields into P_*; fails when GitHub cannot be read
read_pr() {
  local row
  row=$(gh api "repos/$REPO/pulls/$PR" --jq '[.state, (.draft | tostring), .head.sha, (.head.repo.full_name // "-"), .base.repo.full_name, (.mergeable_state // "-"), .base.ref, .head.ref] | join(" ")') || return 1
  read -r P_STATE P_DRAFT P_HEAD P_HREPO P_BREPO P_MSTATE P_BASE P_HREF <<< "$row"
}
lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

# check — the conditions, one refusal line for the first that fails (exit 3), nothing written
check() {
  local behind
  if ! read_pr; then
    echo "REFUSE cannot read pull request $PR of $REPO" >&2
    return 3
  fi
  if [ "$P_STATE" != open ]; then
    echo "REFUSE PR $PR of $REPO is $P_STATE, not open: nothing to update" >&2
    return 3
  fi
  if [ "$P_DRAFT" = true ]; then
    echo "REFUSE PR $PR of $REPO is a draft: nothing written" >&2
    return 3
  fi
  if [ "$(lower "$P_HREPO")" != "$(lower "$P_BREPO")" ]; then
    echo "REFUSE PR $PR of $REPO comes from a fork ($P_HREPO): not updated here" >&2
    return 3
  fi
  case "$P_HREF" in
    backmerge/*)
      echo "REFUSE PR $PR of $REPO is a back-merge ($P_HREF): the base is never merged into it, the release process resolves it" >&2
      return 3
      ;;
  esac
  if [ "$P_HEAD" != "$HEAD" ]; then
    echo "REFUSE the head of PR $PR moved: it is $P_HEAD, the signed head is $HEAD: nothing written" >&2
    return 3
  fi
  if [ "$P_MSTATE" = dirty ]; then
    echo "REFUSE PR $PR of $REPO conflicts with $P_BASE: nothing written, the author resolves it" >&2
    return 3
  fi
  if ! behind=$(gh api "repos/$REPO/compare/$HEAD...$P_BASE" --jq .ahead_by) || [ -z "$behind" ] || [ -n "${behind//[0-9]/}" ]; then
    echo "REFUSE cannot read how far PR $PR is behind $P_BASE" >&2
    return 3
  fi
  if [ "$behind" -eq 0 ]; then
    echo "REFUSE PR $PR of $REPO is not behind $P_BASE: nothing to update" >&2
    return 3
  fi
  echo "PR $PR of $REPO at $HEAD is behind $P_BASE by $behind commit(s)"
}

# A call that may still land is named in a record kept only for its undo (BATON_UNDO_ONLY), as kit:owner-merge does: written before
# the call, dropped when GitHub refuses it outright (nothing written); kept when GitHub accepts it or fails some other way, because
# GitHub makes the merge commit a moment after it answers, so an undo that reads the old head cannot say nothing landed.
case "${XDG_STATE_HOME:-}" in
  /*) STATE_BASE=$XDG_STATE_HOME ;;
  *) STATE_BASE="$HOME/.local/state" ;;
esac
CALLED="$STATE_BASE/vibemaestro/baton/records/kit-pr-update-branch-called-$$-$RANDOM$RANDOM"
# mark_called — fails when the record cannot be written (the call is then not made)
mark_called() {
  [ -n "${BATON_UNDO_ONLY:-}" ] || return 0
  mkdir -p "${CALLED%/*}" && printf '%s %s %s\n' "$REPO" "$PR" "$HEAD" > "$CALLED" && printf '%s\n' "$CALLED" >> "$BATON_UNDO_ONLY"
}
# called_in_undo — in undo: succeeds when the run's record names this PR at this head
called_in_undo() {
  local p
  { [ -n "${BATON_UNDO_ONLY:-}" ] && [ -f "$BATON_UNDO_ONLY" ]; } || return 1
  while IFS= read -r p; do
    case "$p" in
      */kit-pr-update-branch-called-*) [ -f "$p" ] && [ "$(cat "$p")" = "$REPO $PR $HEAD" ] && return 0 ;;
    esac
  done < "$BATON_UNDO_ONLY"
  return 1
}

# update — the call; a refusal of GitHub is classified by reading the PR again
update() {
  local out
  mark_called || { echo "REFUSE cannot write the undo record under $STATE_BASE: nothing written" >&2; return 3; }
  if out=$(gh api -X PUT "repos/$REPO/pulls/$PR/update-branch" -f "expected_head_sha=$HEAD" 2>&1); then
    echo "update-branch accepted for PR $PR: GitHub makes the merge commit a moment later, the post-check reads the new head"
    return 0
  fi
  case "$out" in
    *422*)
      rm -f "$CALLED"                                   # GitHub refused it outright: nothing landed, nothing to undo
      if read_pr && [ "$P_HEAD" != "$HEAD" ]; then
        echo "REFUSE the head of PR $PR moved: it is $P_HEAD, the signed head is $HEAD: nothing written" >&2
      elif printf '%s' "$out" | grep -qi 'conflict'; then
        echo "REFUSE PR $PR of $REPO conflicts with its base (GitHub answered 422): nothing written, the author resolves it" >&2
      else
        echo "REFUSE GitHub refused the update of PR $PR (422): nothing written: $(printf '%s' "$out" | head -n 1)" >&2
      fi
      ;;
    *) echo "REFUSE GitHub did not take the update of PR $PR (it may have landed: the post-check and undo read the PR): $(printf '%s' "$out" | head -n 1)" >&2 ;;
  esac
  return 3
}

# ── the act: every change through write() ──
act() {
  check || return 3
  write "pr-update-branch $REPO $PR $HEAD" update
}

# ── post-check: the PR's head is a new commit with the signed head as a parent ──
postcheck() {
  local parents
  read_pr || { echo "cannot read pull request $PR of $REPO" >&2; return 1; }
  if [ "$P_HEAD" = "$HEAD" ]; then
    echo "the head of PR $PR is still $HEAD: not updated" >&2
    return 1
  fi
  parents=$(gh api "repos/$REPO/commits/$P_HEAD" --jq '.parents[].sha') || { echo "cannot read the commit $P_HEAD" >&2; return 1; }
  if [ "$(printf '%s\n' "$parents" | sed -n 1p)" != "$HEAD" ] || [ "$(printf '%s\n' "$parents" | grep -c .)" -ne 2 ]; then
    echo "the head of PR $PR is $P_HEAD, which is not a merge commit over the signed head $HEAD (its parents are not $HEAD and the base): another hand moved the branch" >&2
    return 1
  fi
  echo "new head $P_HEAD"
}

# ── undo: a merge commit is never taken back here; confirm nothing was updated, or name what stays ──
undo() {
  local parents called=no
  called_in_undo && called=yes
  read_pr || { echo "LEAVE cannot read pull request $PR of $REPO: whether the branch was updated is unknown" >&2; return 1; }
  if [ "$P_HEAD" = "$HEAD" ]; then
    if [ "$called" = yes ]; then
      echo "LEAVE the head of PR $PR is still $HEAD, but this run called update-branch and GitHub makes the merge commit a moment after it accepts the call: it may still land. Read the head again before relying on it; tell the owner" >&2
      return 1
    fi
    echo "the head of PR $PR is still $HEAD and this run has no call that may still land: nothing updated, nothing to undo"
    return 0
  fi
  parents=$(gh api "repos/$REPO/commits/$P_HEAD" --jq '.parents[].sha') || { echo "LEAVE cannot read the commit $P_HEAD, the head of PR $PR: whether this run's update landed is unknown" >&2; return 1; }
  if [ "$(printf '%s\n' "$parents" | sed -n 1p)" != "$HEAD" ] || [ "$(printf '%s\n' "$parents" | grep -c .)" -ne 2 ]; then
    if [ "$called" = yes ]; then
      echo "LEAVE the head of PR $PR is $P_HEAD, which is not a merge commit over the signed head $HEAD, but this run called update-branch: whether its merge commit lies beneath that head is unknown; tell the owner" >&2
      return 1
    fi
    echo "the head of PR $PR is $P_HEAD, which is not a merge commit over the signed head $HEAD: another hand moved the branch, this run has no call that may still land: nothing to undo"
    return 0
  fi
  echo "LEAVE the branch of PR $PR holds $P_HEAD: after $HEAD, a merge commit of $P_BASE (or another hand's commit). It cannot be taken back cleanly: dropping it is a force-push, a revert adds a second commit. Its checks run on it; tell the owner, who decides" >&2
  return 1
}

case "$PHASE" in
  rehearse) act; echo "VERDICT rehearse ok" ;;
  run) act; echo "VERDICT run ok" ;;
  postcheck) postcheck; echo "VERDICT postcheck ok" ;;
  undo) undo; echo "VERDICT undo ok" ;;
  *) echo "unknown phase: $PHASE" >&2; exit 64 ;;
esac
