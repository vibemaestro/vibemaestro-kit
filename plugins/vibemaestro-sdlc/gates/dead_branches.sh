#!/usr/bin/env bash
#
# dead_branches.sh - count the remote branches that are ALREADY inside the main line and still alive.
#
# A rule that only reminds ("delete the worktree and the branch after the merge") is not followed: a dead branch does nothing, but
# `git branch -r` stops being useful, because nobody can see which branches are live. This gate counts them.
#
# THE ORDER OF THE QUESTIONS IS PART OF THE MEASUREMENT.
#   An open intent branch CONTAINS main. If "is it in an open intent branch?" were asked BEFORE "is it in main?", every old branch
#   would be labelled "part of the current batch" and the count would fall to 0: a counter that is always green. So the first
#   question is "is it in main?", and tests/test-gates-dead.sh has a sure-positive case that pins that order.
#
# THIS GATE ONLY REPORTS, IT NEVER DELETES.
#   No line of this file runs `git push --delete` or `git branch -d`. Deleting remote branches in bulk is a person's decision; the
#   script PRINTS the cleanup command for a person to read and run.
#
# A squash-merged branch is not an ancestor of main (the squash is a new commit), so the count only UNDER-counts, never over-counts:
# a branch reported dead is certainly dead.
#
# Use:
#   dead_branches.sh                       read the remote refs that are already here
#   dead_branches.sh --fetch               `git fetch --prune` first (opt-in, so a test never leaves the machine)
#   dead_branches.sh --threshold N         the red threshold (default: dead_branches.max_merged_on_remote, 0)
#   dead_branches.sh --repo DIR            run on another repo (default: the repo of the current directory)
#   dead_branches.sh --remote origin --main main
#   dead_branches.sh --config-ref REF      read .vibemaestro/sdlc.json at this git ref (CI: the base) instead of the working tree
#
# Config: dead_branches.max_merged_on_remote, branch.protected (never counted; the first one that exists on the remote is the main
# line unless --main is given), branch.intent_prefix (an open intent branch is `<remote>/<prefix>*` that is not yet in main).
# rc 0 at or under the threshold, 1 over it, 2 cannot conclude (not a repo, no remote main), 64 usage, 65 invalid config.
#
set -Eeuo pipefail

HERE="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REMOTE=origin
MAIN=""
THRESHOLD=""
REPO=""
DO_FETCH=0
CONFIG_REF=""

usage() { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
  case "$1" in
    --remote)     [ $# -ge 2 ] || { echo "dead-branches: $1 needs a value" >&2; exit 64; }; REMOTE="$2"; shift 2 ;;
    --main)       [ $# -ge 2 ] || { echo "dead-branches: $1 needs a value" >&2; exit 64; }; MAIN="$2"; shift 2 ;;
    --threshold)  [ $# -ge 2 ] || { echo "dead-branches: $1 needs a value" >&2; exit 64; }; THRESHOLD="$2"; shift 2 ;;
    --repo)       [ $# -ge 2 ] || { echo "dead-branches: $1 needs a value" >&2; exit 64; }; REPO="$2"; shift 2 ;;
    --config-ref) [ $# -ge 2 ] && [ -n "$2" ] || { echo "dead-branches: $1 needs a value" >&2; exit 64; }; CONFIG_REF="$2"; shift 2 ;;
    --fetch)      DO_FETCH=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) printf 'dead-branches: unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
done
case "$THRESHOLD" in ''|*[!0-9]*) [ -z "$THRESHOLD" ] || { echo "dead-branches: --threshold must be a whole number" >&2; exit 64; } ;; esac

if [ -z "$REPO" ]; then REPO="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"; fi
g() { git -C "$REPO" "$@"; }
g rev-parse --git-dir >/dev/null 2>&1 || { printf 'dead-branches: %s is not a git repo\n' "$REPO" >&2; exit 2; }

# the repo config, through the same loader as every gate (exit 65 names the key; the message is already printed)
cfg() { python3 "$HERE/gate_common.py" get "$1" --root "$REPO" ${CONFIG_REF:+--config-ref "$CONFIG_REF"}; }
[ -n "$THRESHOLD" ] || THRESHOLD="$(cfg dead_branches.max_merged_on_remote)" || exit $?
PREFIX="$(cfg branch.intent_prefix)" || exit $?
PROTECTED="$(cfg branch.protected | python3 -I -c 'import json,sys; print("\n".join(json.load(sys.stdin)))')" || exit $?

# fetch is OPT-IN: a test runs on a throw-away repo and must never touch the network
if [ "$DO_FETCH" -eq 1 ]; then
  g fetch --prune "$REMOTE" >/dev/null 2>&1 || true
fi

if [ -z "$MAIN" ]; then
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    if g rev-parse --verify --quiet "refs/remotes/$REMOTE/$b" >/dev/null; then MAIN="$b"; break; fi
  done <<< "$PROTECTED"
fi
MAIN_REF="$REMOTE/$MAIN"
[ -n "$MAIN" ] && g rev-parse --verify --quiet "refs/remotes/$MAIN_REF" >/dev/null \
  || { printf 'dead-branches: no main line found on %s (looked for the protected branches); fetch first? (try --fetch)\n' "$REMOTE" >&2; exit 2; }

# ── list the remote branches: skip symbolic refs, the main line and every protected branch ─────────────────────
# `refs/remotes/origin/HEAD` shortens to **`origin`**, NOT `origin/HEAD`, so filtering with `grep -vxF origin/HEAD` misses it, and it
# only shows up after the first `git fetch`. The real question is `%(symref)` empty.
all_branches=$(g for-each-ref --format='%(refname:short)%09%(symref)' "refs/remotes/$REMOTE" \
  | awk -F'\t' '$2 == "" { print $1 }' | grep -vxF "$MAIN_REF" || true)
while IFS= read -r b; do
  [ -n "$b" ] || continue
  all_branches=$(printf '%s\n' "$all_branches" | grep -vxF "$REMOTE/$b" || true)
done <<< "$PROTECTED"

# ── QUESTION 1 (must be first): which branches are already ENTIRELY in main? ───────────────────────────────────
# `branch -r --merged <ref>` = the remote branches whose tip is an ancestor of <ref>.
# `grep -f` with an EMPTY list matches every line, the opposite of what we want, so guard with an if.
if [ -z "$all_branches" ]; then
  merged_main=""
else
  merged_main=$(g branch -r --merged "$MAIN_REF" --format='%(refname:short)' \
    | grep -vxF "$MAIN_REF" | grep -xF -f <(printf '%s\n' "$all_branches") || true)
fi

is_in() { printf '%s\n' "$2" | grep -qxF "$1"; }

# ── an open intent branch = an intent branch that is NOT in main yet ───────────────────────────────────────────
open_intents=""
while IFS= read -r b; do
  [ -n "$b" ] || continue
  case "$b" in
    "$REMOTE/$PREFIX"*) ;;
    *) continue ;;
  esac
  # `is_in ... && continue` would let `set -e` kill the script when is_in returns 1: spell out the if
  if is_in "$b" "$merged_main"; then continue; fi
  open_intents="$open_intents$b"$'\n'
done <<< "$all_branches"

# ── QUESTION 2 (only for the branches NOT in group 1): which open intent contains it? ──────────────────────────
dead=""; in_intent=""; unmerged=""
while IFS= read -r b; do
  [ -n "$b" ] || continue

  if is_in "$b" "$merged_main"; then
    dead="$dead$b"$'\n'           # group 1: deletable
    continue
  fi

  hit=""
  while IFS= read -r i; do
    [ -n "$i" ] || continue
    if [ "$i" = "$b" ]; then continue; fi   # an intent branch is not "inside" itself
    if g merge-base --is-ancestor "$b" "$i" 2>/dev/null; then hit="$i"; break; fi
  done <<< "$open_intents"

  if [ -n "$hit" ]; then
    in_intent="$in_intent$b  <- $hit"$'\n'   # group 2: in use
  else
    unmerged="$unmerged$b"$'\n'              # group 3: not merged anywhere
  fi
done <<< "$all_branches"

count() { printf '%s' "$1" | grep -c . || true; }
n_dead=$(count "$dead"); n_intent=$(count "$in_intent"); n_unmerged=$(count "$unmerged")

printf '== remote branches on %s ==\n' "$REMOTE"
printf '  already in %-24s %s\n' "$MAIN (deletable):" "$n_dead"
printf '  %-31s %s\n' "only in an open intent branch:" "$n_intent"
printf '  %-31s %s\n' "not merged anywhere:" "$n_unmerged"

if [ "$n_intent" -gt 0 ]; then
  printf '\nbranches that serve an open intent - KEEP:\n'
  printf '%s' "$in_intent" | sed 's/^/  /'
fi

if [ "$n_dead" -eq 0 ]; then
  printf '\n[ ok ] no dead branch on %s\n' "$REMOTE"
  exit 0
fi

printf '\nbranches entirely inside %s:\n' "$MAIN_REF"
printf '%s' "$dead" | sed 's/^/  /'

# ── the cleanup command: PRINTED, never run ─────────────────────────────────────────────────────────────────────
printf '\ncleanup command - read the list above and run it YOURSELF (this script deletes nothing):\n'
printf '\n  git push %s --delete \\\n' "$REMOTE"
printf '%s' "$dead" | sed "s#^$REMOTE/##" | sed 's/^/    /' | sed '$ !s/$/ \\/'
printf '\n\n  git worktree prune\n'

if [ "$n_dead" -gt "$THRESHOLD" ]; then
  printf '\n[ FAIL ] %s dead branches > threshold %s\n' "$n_dead" "$THRESHOLD"
  exit 1
fi
printf '\n[ ok ] %s dead branches <= threshold %s\n' "$n_dead" "$THRESHOLD"
exit 0
