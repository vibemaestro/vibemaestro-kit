#!/usr/bin/env bash
# Purpose: create one or more new labels in one GitHub repository, each refused when the repository already has a label of that name
# Targets: the label list of the repository named by the first argument
# Blast: one new label per name, with GitHub's default colour and no description; no existing label, issue, pull request or setting changes
# Undo: none by this script: deleting a label removes it from every issue that carries it, an act the owner signs; undo names each label of the call the repository holds and exits non-zero, or passes when none landed
# Pre: the repository's labels can be read; no name of the call is a label there, its case ignored; read again right before each create
# Stops: none
#   Why none: a new label adds one name to a repository's label list and changes nothing that exists; a name the repository has
#   is refused at rehearse and again before its create, so nothing is replaced or recoloured. A label is not deleted by undo
#   (it would leave every issue that carries it by then): undo names it, so the owner may delete it.
# Usage: <owner/repo> <name> [<name>]...  (1 to 20 names; a name is 1 to 50 of A-Z a-z 0-9 : . _ / + -, starting with a letter or digit)
# Each: label-create *
#
# The kit baton kit:label-create: `<launcher> go kit:label-create <owner/repo> <name>...`. One plan line per name, in the given
# order; the run creates them in that order and stops at the first that fails: the labels before it stay, and its undo names them.
# GitHub compares label names without case, so `Type:Story` is refused where `type:story` exists, and a call naming both is refused.
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
MAX=20
USAGE="usage: go kit:label-create <owner/repo> <name> [<name>]...  (1 to $MAX names; a name is 1 to 50 of A-Z a-z 0-9 : . _ / + -, starting with a letter or digit)"
# usage <why> — the refusal on one line, control bytes of a refused argument dropped
usage() { printf 'REFUSE %s\n' "$(printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177')" >&2; echo "$USAGE" >&2; exit 64; }
lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

[ $# -gt 0 ] || usage "no repository named"
REPO=$1
shift
case "$REPO" in
  */*/* | /* | */ | -* | .* | */. | */.. | *[!A-Za-z0-9_./-]*) usage "repository must be owner/name: $REPO" ;;
  */*) ;;
  *) usage "repository must be owner/name: $REPO" ;;
esac
[ $# -gt 0 ] || usage "no label named"
[ $# -le "$MAX" ] || usage "more than $MAX labels in one run"
NAMES=()
SEEN=" "
for n in "$@"; do
  case "$n" in
    '' | [!A-Za-z0-9]* | *[!A-Za-z0-9:._/+-]*) usage "not a label name: $n" ;;
  esac
  [ ${#n} -le 50 ] || usage "a label name is at most 50 characters: $n"
  case "$SEEN" in *" $(lower "$n") "*) usage "$n is named twice (case ignored)" ;; esac
  SEEN="$SEEN$(lower "$n") "
  NAMES+=("$n")
done

# ── reads: the repository's labels, one per line, lower case ──
labels() { gh api --paginate "repos/$REPO/labels?per_page=100" --jq '.[].name' | tr 'A-Z' 'a-z'; }
has() { grep -Fxq -- "$(lower "$1")" <<< "$2"; }

# create <name> — read the labels again, then create it; GitHub's answer must name it
create() {
  local now got
  now=$(labels) || { echo "REFUSE cannot read the labels of $REPO" >&2; return 3; }
  if has "$1" "$now"; then
    echo "REFUSE $REPO has a label $1 now (case ignored): nothing replaced" >&2
    return 3
  fi
  got=$(gh api -X POST "repos/$REPO/labels" -f "name=$1" --jq .name) || return 3
  [ "$got" = "$1" ] || { echo "GitHub answered label $got, not $1" >&2; return 3; }
  echo "created label $1 in $REPO"
}

# ── the act: one plan line per name; a name the repository has refuses the whole call before anything is written ──
act() {
  local all n made=""
  all=$(labels) || { echo "REFUSE cannot read the labels of $REPO" >&2; return 3; }
  for n in "${NAMES[@]}"; do
    if has "$n" "$all"; then
      echo "REFUSE $REPO has a label $n already (case ignored): nothing to create, nothing to sign" >&2
      return 3
    fi
  done
  for n in "${NAMES[@]}"; do
    write "label-create $REPO $n" create "$n" \
      || { echo "STOPPED at label $n (it may have landed: the undo reads the labels again); created before the stop: ${made:-none}" >&2; return 3; }
    made="${made:+$made, }$n"
  done
  echo "PLAN-COUNT ${#NAMES[@]}"
}

# ── post-check: every name is a label of the repository ──
postcheck() {
  local all n
  all=$(labels) || { echo "cannot read the labels of $REPO" >&2; return 1; }
  for n in "${NAMES[@]}"; do
    has "$n" "$all" || { echo "$REPO has no label $n" >&2; return 1; }
    echo "$REPO has label $n"
  done
}

# ── undo: a label is never deleted here; name each label of the call that the repository holds ──
undo() {
  local all n left=""
  all=$(labels) || { echo "LEAVE cannot read the labels of $REPO: which labels landed is unknown" >&2; return 1; }
  for n in "${NAMES[@]}"; do
    if has "$n" "$all"; then
      left="${left:+$left, }$n"
    fi
  done
  [ -z "$left" ] || { echo "LEAVE labels $left in $REPO: deleting a label removes it from every issue that carries it, an act the owner signs" >&2; return 1; }
  echo "no label of the call is in $REPO: nothing to undo"
}

case "$PHASE" in
  rehearse) act; echo "VERDICT rehearse ok" ;;
  run) act; echo "VERDICT run ok" ;;
  postcheck) postcheck; echo "VERDICT postcheck ok" ;;
  undo) undo; echo "VERDICT undo ok" ;;
  *) echo "unknown phase: $PHASE" >&2; exit 64 ;;
esac
