#!/usr/bin/env bash
# Purpose: delete one branch of a private GitHub repository at a pinned head that is proven merged into its default branch, with a lease on that SHA, through the plugin's delete gate from a scratch repository no clone config reaches
# Targets: the github.com repository named by repo, which the clone's origin names; its branch ref refs/heads/<branch>; a run record under the baton state directory
# Blast: one branch ref at the pinned head, whose commit the default branch already holds, or whose merged PR keeps it (refs/pull/<n>/head); no commit is lost (no tag, no other ref, no unmerged branch)
# Undo: recreates the branch at the pinned SHA through the API (create-only), while it is absent, when the run record says this run's delete landed; a refused delete is left alone; a branch there again at another SHA is left and named (non-zero); an unknown outcome (the branch gone) recreates it when its proof no longer holds or a read of it fails, and is left for the owner (non-zero) when the proof still keeps the SHA, the record names no proof, or the repository no longer reads as private or cannot be listed
# Pre: the clone's origin URL names https or ssh github.com/<repo>; the repository reads private; the branch exists at the pinned head, is not the default branch, is not protected, no ruleset forbids its deletion, it has no tag of its name and no open pull request from or into it; the head is an ancestor of the default branch's tip (compare API), or a merged PR of this repository's branch at that head into the default branch proves the merge (a squash or a rebase: its merge commit on the default tip, refs/pull/<n>/head at the head); at the delete, its plan line is in the signed plan; after it, the same proof still holds
# Stops: none
#   Why none: the stop list counts a branch delete as irreversible because a hand-written check cannot prove it merged. This
#   kit proves it from GitHub before it acts (the pinned head is an ancestor of the default branch's tip, or its merged PR's
#   merge commit is on the default branch and refs/pull/<n>/head keeps the head), deletes only that SHA (a lease), proves it
#   again after the delete (the post-check fails, and undo puts the ref back, when the proof no longer holds), so nothing that
#   cannot come back is lost. An unmerged branch (a SHA only another branch holds included), a tip moved off the pinned head,
#   a tag, a protected or default branch, an open pull request and a public or internal repository are refused at rehearse:
#   those stay hand-written batons the owner signs.
# Params: repo=repo branch=ref head=sha40
# Expect: delete merged branch * at * (merged into * at *, *) on *
#
# The kit baton kit:branch-delete. Run it from a clone of the repository, only through the baton runner:
#   <launcher> go kit:branch-delete repo='<owner/name>' branch='<name>' head='<full sha>'
# head pins the branch: a branch whose tip on the remote is another SHA is refused (at rehearse, and again when the run reads
# it), and the delete's lease is on it. The base is the repository's default branch, always. The clone only says which
# transport to use (its origin URL must name https or ssh github.com/<repo>); the URL is built from repo, and every git call to
# the remote runs in a scratch bare repository made for this phase with no system or global config and an allowlisted
# environment, as kit:branch-push. Every API call names github.com (--hostname), the host git talks to. The clone's refs are
# never read: the branch and default-branch SHAs come from the remote's own listing; merged-ness is one of two proofs: the
# compare API shows the head an ancestor of the default tip, or a merged PR of this repository's branch at that head into the
# default branch has its merge commit on the default tip and refs/pull/<n>/head at the head (a squash or a rebase merge). The
# plan line carries the branch, the head, the default branch, its SHA and the proof (ancestor, or merged PR #<n>), so the
# signature binds exactly what was proven. The run reads them all again (a default branch that moved gives another plan line,
# a branch that moved is refused). The delete itself is the plugin's gate gates/branch_delete.py, run inside write(): it checks
# that the plan line is in the signed plan and names this delete, then pushes with a lease on the head, so GitHub refuses it if
# the branch moved since; no delete is written in this file. A run record (one per target and runner process) says whether
# this run's delete landed: undo recreates the branch then; when the outcome is unknown (a failed or cut-off push, the branch
# gone) it recreates it when its proof no longer holds or a read of the proof fails, so no commit is lost, and else leaves it
# for the owner (the proof still holds, the record names no proof, or the repository cannot be read as before); a branch there
# again at another SHA is left and named.
# Branch names: letters, digits and `._/-`, what `git check-ref-format` accepts, minus the names git resolves first as another
# ref (HEAD, *_HEAD, AUTO_MERGE, BISECT_EXPECTED_REV, a first component refs, heads, tags or remotes, a full 40-hex SHA).
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
usage() { echo "usage: baton rehearse|run kit:branch-delete repo=<owner/name> branch=<name> head=<full sha>  (only through the baton runner)" >&2; }
if [ -z "${BATON_PLUGIN_ROOT:-}" ] || [ $# -ne 3 ]; then
  usage
  exit 64
fi
P_REPO="$1"
P_BRANCH="$2"
P_HEAD="$3"
REPO="$P_REPO" BR="$P_BRANCH" SHA="$P_HEAD" REMOTE=origin
if ! [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || ! [[ "$SHA" =~ ^[0-9a-f]{40}$ ]]; then
  usage
  exit 64
fi
# branchname <name> — rc 0 when this kit takes the name as a branch name
branchname() {
  local b=$1 first=${1%%/*}
  [[ "$b" =~ ^[A-Za-z0-9._/-]+$ ]] && git check-ref-format "refs/heads/$b" > /dev/null 2>&1 && [[ "$b" != -* ]] \
    && ! [[ "$b" =~ ^(HEAD|[A-Z_]+_HEAD|AUTO_MERGE|BISECT_EXPECTED_REV)$ ]] && [ "$first" != refs ] && [ "$first" != heads ] \
    && [ "$first" != tags ] && [ "$first" != remotes ] && ! [[ "$b" =~ ^[0-9a-fA-F]{40}$ ]]
}
if ! branchname "$BR"; then
  echo "REFUSE branch $BR: not a branch name this kit takes (letters, digits and ._/- only; git refuses it, or resolves it first as another ref)" >&2
  exit 64
fi
URL=$(git config --get "remote.$REMOTE.url" || true)
# the repository the URL names, lower-cased, or nothing when it is not github.com over https or ssh
url_repo() {
  local u=$1 r="" host=github.com
  case "$u" in
    "https://$host/"*) r=${u#"https://$host/"} ;;
    "git@$host:"*) r=${u#"git@$host:"} ;;
    "ssh://git@$host/"*) r=${u#"ssh://git@$host/"} ;;
  esac
  r=${r%.git}
  r=${r%/}
  if [[ "$r" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    printf '%s' "$r" | tr '[:upper:]' '[:lower:]'
  fi
}
HOST=github.com
case "$URL" in
  https://*) PUSH_URL="https://$HOST/$REPO.git" ;;
  *) PUSH_URL="git@$HOST:$REPO.git" ;;
esac

# the baton state directory, as baton computes it; the run record lives under it
case "${XDG_STATE_HOME:-}" in
  /*) STATE_BASE=$XDG_STATE_HOME ;;
  *) STATE_BASE="$HOME/.local/state" ;;
esac
sha256_text() {
  if command -v sha256sum > /dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
  else
    printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
  fi
}
# one record per target (repository and branch) and per baton process ($PPID: the runner that runs this run's phases, run,
# post-check and undo): another run, or one running at the same time, never reads this run's record
RECORD="$STATE_BASE/vibemaestro/baton/records/kit-branch-delete-$(sha256_text "$REPO $BR" | cut -c1-16)-$PPID.last"
# plan_id — the sha256 of the signed plan baton hands the run and its undo (BATON_PLAN): which run a record belongs to
plan_id() {
  if [ -n "${BATON_PLAN:-}" ] && [ -f "$BATON_PLAN" ]; then
    sha256_text "$(cat "$BATON_PLAN")"
  fi
}

# the scratch repository: no config but these settings, no hooks, no objects (a delete sends none)
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/kit-branch-delete.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT
# cleanenv <command> [args...] — the command with the allowlisted environment only, and no git config but its own
cleanenv() {
  local v keep=()
  for v in PATH HOME TMPDIR LANG LC_ALL LC_CTYPE SSH_AUTH_SOCK GIT_SSH_COMMAND GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GH_HOST \
    GH_CONFIG_DIR HTTPS_PROXY https_proxy HTTP_PROXY http_proxy NO_PROXY no_proxy ALL_PROXY all_proxy; do
    if [ -n "${!v+x}" ]; then
      keep+=("$v=${!v}")
    fi
  done
  env -i ${keep[@]+"${keep[@]}"} GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 GIT_PAGER=cat "$@"
}
sgit() {
  cleanenv git -c core.hooksPath=/dev/null -c protocol.allow=never -c protocol.https.allow=always -c protocol.ssh.allow=always \
    -c http.sslVerify=true -c push.followTags=false -c push.recurseSubmodules=no -c submodule.recurse=false \
    -c log.showSignature=false -c credential.helper= -c 'credential.helper=!gh auth git-credential' -C "$SCRATCH/repo.git" "$@"
}
cleanenv git init -q --bare --template= "$SCRATCH/repo.git"
BASE="" BASESHA="" NOW="" PLANLINE="" OWNER="" FULL="" DEFAULT="" PROOF="" PRN="" SQ="" CMP=""

# refs <ref>... — those refs as the remote advertises them now, "<sha> <ref>" per line; a remote that cannot be read fails
refs() { sgit ls-remote "$PUSH_URL" "$@"; }
# ref_sha <listing> <ref> — that ref's SHA in the listing, empty when it has none (exact: ls-remote's patterns match a tail)
ref_sha() {
  local sha ref
  while read -r sha ref; do
    if [ "$ref" = "$2" ]; then
      printf '%s' "$sha"
    fi
  done <<< "$1"
}
# repo_info — sets OWNER, FULL (owner/name as GitHub reports it), DEFAULT and BASE (the default branch, the only base) from the API; rc 3 on a repository that
# does not read private
repo_info() {
  local info priv vis
  info=$(gh api --hostname "$HOST" "repos/$REPO" --jq '"\(.private) \(.visibility) \(.default_branch) \(.owner.login) \(.full_name)"' 2>&1 || true)
  read -r priv vis DEFAULT OWNER FULL _ <<< "$info"
  if [ "$priv $vis" != "true private" ] || ! branchname "$DEFAULT" || ! [[ "$OWNER" =~ ^[A-Za-z0-9_.-]+$ ]] \
    || ! [[ "$FULL" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "REFUSE $REPO does not read private, or has no default branch ($info): this kit deletes on private repositories only" >&2
    return 3
  fi
  BASE=$DEFAULT
}
# merged <base sha> <sha> — rc 0 when the compare API shows <sha> an ancestor of <base sha>; the answer is in CMP
merged() {
  CMP=$(gh api --hostname "$HOST" "repos/$REPO/compare/$1...$2" --jq '"\(.status) \(.ahead_by)"' 2>&1 || true)
  [[ "$CMP" =~ ^(behind|identical)\ 0$ ]]
}
# squash_pr — rc 0 when a merged pull request proves the branch at $SHA merged into $BASE at $BASESHA without being an ancestor
# (a squash, or a rebase: either way the PR's merge commit is on the base and refs/pull/<n>/head keeps the branch's commits);
# sets PRN. The number comes from GitHub's own list, never from an argument: merged PRs whose head is this repository's branch
# at $SHA now and whose base is $BASE, tried from the lowest number up; the first that pr_holds proves is used
squash_pr() {
  local list n mc cands=""
  PRN="" SQ=""
  if ! list=$(gh api --hostname "$HOST" --paginate "repos/$REPO/pulls?state=closed&head=$OWNER:$BR&base=$BASE&per_page=100" \
    --jq ".[] | select(.merged_at != null and .base.ref == \"$BASE\" and .head.ref == \"$BR\" and .head.sha == \"$SHA\" and (.head.repo.full_name // \"\" | ascii_downcase) == \"$(printf '%s' "$FULL" | tr '[:upper:]' '[:lower:]')\") | \"\(.number) \(.merge_commit_sha)\"" 2>&1); then
    SQ="the pull request list cannot be read (${list:-no answer})"
    return 1
  fi
  while read -r n mc; do
    [ -n "$n" ] || continue
    if ! [[ "$n" =~ ^[1-9][0-9]*$ ]] || ! [[ "$mc" =~ ^([0-9a-f]{40}|null)$ ]]; then
      SQ="the pull request list gave an answer this kit cannot read ($n $mc)"
      return 1
    fi
    cands="$cands $n"
  done <<< "$list"
  if [ -z "$cands" ]; then
    SQ="no merged pull request from this repository's $BR at $SHA into $BASE"
    return 1
  fi
  for n in $(printf '%s\n' $cands | sort -n); do
    if pr_holds "$n" "$BASESHA"; then
      PRN=$n
      return 0
    fi
  done
  SQ="none of the merged PRs $(printf '#%s ' $(printf '%s\n' $cands | sort -n))holds; the last tried: $SQ"
  return 1
}
# pr_holds <n> <base sha> — rc 0 while PR #<n> proves the merge (at rehearse, the run, the post-check and undo alike): merged, from $BR at $SHA into $BASE, its merge commit on the
# base at <base sha>, refs/pull/<n>/head at $SHA; the answer is in SQ
pr_holds() {
  local info merged mc head base all
  info=$(gh api --hostname "$HOST" "repos/$REPO/pulls/$1" --jq '"\(.merged_at != null) \(.merge_commit_sha) \(.head.sha) \(.base.ref)"' 2>&1 || true)
  read -r merged mc head base _ <<< "$info"
  if [ "$merged" != true ] || [ "$head" != "$SHA" ] || [ "$base" != "$BASE" ] || ! [[ "$mc" =~ ^[0-9a-f]{40}$ ]]; then
    SQ="PR #$1 does not show a merge of $BR at $SHA into $BASE ($info)"
    return 1
  fi
  if ! all=$(refs "refs/pull/$1/head") || [ "$(ref_sha "$all" "refs/pull/$1/head")" != "$SHA" ]; then
    SQ="refs/pull/$1/head is not at $SHA, or cannot be read"
    return 1
  fi
  if ! merged "$2" "$mc"; then
    SQ="the merge commit $mc of PR #$1 is not on $BASE at $2 (compare: ${CMP:-no answer})"
    return 1
  fi
}
# proof_text <proof> — how the plan line names it: ancestor, or merged PR #<n>
proof_text() {
  case "$1" in
    pr:*) printf 'merged PR #%s' "${1#pr:}" ;;
    *) printf '%s' "$1" ;;
  esac
}
# held <proof> <base sha> — rc 0 while the proof still keeps $SHA's commits on GitHub: in the base (ancestor), or the merged PR's
# proof holds (pr_holds)
held() {
  if ! valid_proof "$1"; then
    SQ="the run record names no proof this kit knows (${1:-none})"
    return 1
  fi
  case "$1" in
    ancestor) merged "$2" "$SHA" ;;
    pr:*) pr_holds "${1#pr:}" "$2" ;;
  esac
}
# valid_proof <proof> — rc 0 for ancestor or pr:<number>
valid_proof() { [[ "$1" =~ ^(ancestor|pr:[1-9][0-9]*)$ ]]; }
# record <state> — the run record: the signed plan's id, the SHA, the delete's state (pushing, deleted, refused, unknown) and the
# proof (ancestor, or pr:<n>)
record() { mkdir -p "$(dirname "$RECORD")" && printf '%s %s %s %s\n' "$(plan_id)" "$SHA" "$1" "$PROOF" > "$RECORD"; }
# del — only the signed plan's delete, leased on the pinned SHA, written by the plugin's delete gate (it refuses a plan line
# that is not in the signed plan or names another delete, and pushes with the lease); the record says whether it landed
del() {
  local rc=0 all
  find "$(dirname "$RECORD")" -name 'kit-branch-delete-*.last' -mtime +7 -exec rm -f {} + 2> /dev/null || true
  record pushing
  python3 -I -B "$BATON_PLUGIN_ROOT/gates/branch_delete.py" --repo "$REPO" --branch "$BR" --head "$SHA" --url "$PUSH_URL" \
    --plan "$PLANLINE" --expect-plan "${BATON_PLAN:-}" || rc=$?
  case "$rc" in
    0)
      record deleted
      ;;
    3 | 64)
      record refused
      echo "REFUSE the delete gate refused before any push (rc $rc): nothing deleted" >&2
      return 3
      ;;
    *)
      # a push that fails may still have landed (an answer lost after receive-pack): only a branch still there proves it did not
      if all=$(refs "refs/heads/$BR") && [ -n "$(ref_sha "$all" "refs/heads/$BR")" ]; then
        record refused
        echo "REFUSE the push was refused (the branch moved since the check, or the remote said no): nothing deleted" >&2
      else
        record unknown
        echo "REFUSE the push failed and $BR is gone, or cannot be read: whether this run deleted it is unknown" >&2
      fi
      return 3
      ;;
  esac
}

# ── the act: every change through write() ──
act() {
  local named want all prot rules n q ahead anc
  named=$(url_repo "$URL")
  want=$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')
  if [ -z "$named" ] || [ "$named" != "$want" ]; then
    echo "REFUSE remote $REMOTE is ${URL:-not set}: this kit deletes only on github.com/$REPO" >&2
    return 3
  fi
  repo_info
  if [ "$BR" = "$DEFAULT" ]; then
    echo "REFUSE $BR is the default branch: never deleted by this kit" >&2
    return 3
  fi
  if ! all=$(refs "refs/heads/$BR" "refs/heads/$BASE" "refs/tags/$BR"); then
    echo "REFUSE cannot read the refs of $PUSH_URL" >&2
    return 3
  fi
  NOW=$(ref_sha "$all" "refs/heads/$BR")
  BASESHA=$(ref_sha "$all" "refs/heads/$BASE")
  if ! [[ "$NOW" =~ ^[0-9a-f]{40}$ ]]; then
    echo "REFUSE $PUSH_URL has no branch $BR" >&2
    return 3
  fi
  if [ "$NOW" != "$SHA" ]; then
    echo "REFUSE branch $BR is at $NOW on $PUSH_URL, not at the pinned head $SHA: a tip that moved off the pinned SHA is never deleted" >&2
    return 3
  fi
  if ! [[ "$BASESHA" =~ ^[0-9a-f]{40}$ ]]; then
    echo "REFUSE $PUSH_URL has no default branch $BASE" >&2
    return 3
  fi
  if [ -n "$(ref_sha "$all" "refs/tags/$BR")" ]; then
    echo "REFUSE $PUSH_URL has a tag $BR: a name that is also a tag is never deleted by this kit" >&2
    return 3
  fi
  prot=$(gh api --hostname "$HOST" "repos/$REPO/branches/$BR" --jq '.protected' 2>&1 || true)
  if [ "$prot" != false ]; then
    echo "REFUSE branch $BR is protected, or its protection cannot be read ($prot)" >&2
    return 3
  fi
  rules=$(gh api --hostname "$HOST" --paginate "repos/$REPO/rules/branches/$BR" --jq '.[] | select(.type == "deletion") | .type' 2>&1) \
    || rules="unreadable: ${rules:-no answer}"
  if [ -n "$rules" ]; then
    echo "REFUSE a ruleset forbids deleting $BR, or the rules cannot be read ($rules)" >&2
    return 3
  fi
  for q in "head=$OWNER:$BR" "base=$BR"; do
    n=$(gh api --hostname "$HOST" "repos/$REPO/pulls?state=open&$q&per_page=1" --jq 'length' 2>&1 || true)
    if [ "$n" != 0 ]; then
      echo "REFUSE an open pull request has $BR as its ${q%%=*}, or the list cannot be read ($n)" >&2
      return 3
    fi
  done
  if merged "$BASESHA" "$SHA"; then
    PROOF=ancestor
  else
    ahead="" anc=${CMP:-no answer}              # the ancestor compare's answer, before squash_pr's compares replace CMP
    if [[ "$CMP" =~ ^[a-z]+\ ([0-9]+)$ ]]; then
      ahead="; commits only on the branch: ${BASH_REMATCH[1]}"
    fi
    if ! squash_pr; then
      echo "REFUSE branch $BR at $SHA is not merged into $BASE at $BASESHA: not an ancestor (compare: $anc$ahead), and no merged pull request proves it ($SQ); an unmerged branch is a hand-written baton the owner signs" >&2
      return 3
    fi
    PROOF="pr:$PRN"
  fi
  PLANLINE="delete merged branch $BR at $SHA (merged into $BASE at $BASESHA, $(proof_text "$PROOF")) on $PUSH_URL"
  write "$PLANLINE" del
}

# ── post-check: the branch is gone, and its proof still holds (else undo puts it back) ──
postcheck() {
  local all now base _plan _state
  if [ -f "$RECORD" ]; then
    read -r _plan SHA _state PROOF < "$RECORD"   # the post-check gets no signed plan: the run's own record names the SHA and proof
  fi
  repo_info
  all=$(refs "refs/heads/$BR" "refs/heads/$BASE")
  now=$(ref_sha "$all" "refs/heads/$BR")
  base=$(ref_sha "$all" "refs/heads/$BASE")
  echo "$PUSH_URL $BR is ${now:+at }${now:-gone}; $BASE is at ${base:-nothing}"
  [ -z "$now" ] || return 1
  if [ -z "$SHA" ] || [ -z "$base" ] || ! held "$PROOF" "$base"; then
    echo "the proof (${PROOF:-none}) no longer holds ${SHA:-the deleted SHA} with $BASE at ${base:-nothing} (${SQ:-compare: ${CMP:-none}})" >&2
    return 1
  fi
  rm -f -- "$RECORD"            # the run holds: no undo reads this record, and a later process with this PID never finds it
}

# recreate — the branch back at the deleted SHA, create-only (the API refuses a ref that exists)
recreate() { gh api --hostname "$HOST" -X POST "repos/$REPO/git/refs" -f "ref=refs/heads/$BR" -f "sha=$SHA" > /dev/null; }

# ── undo: from the run record; the branch back at its SHA only when this run's delete landed ──
undo() {
  local plan state all now mine base
  if [ ! -f "$RECORD" ]; then
    echo "no run record: this run never pushed a delete, nothing to put back"
    return 0
  fi
  read -r plan SHA state PROOF < "$RECORD"
  mine=$(plan_id)
  if [ -z "$mine" ]; then
    echo "LEAVE no signed plan (BATON_PLAN): cannot tell whether $RECORD is this run's" >&2
    return 1
  fi
  if [ "$plan" != "$mine" ]; then
    echo "the run record $RECORD is an earlier run's: nothing of this run to put back"
    return 0
  fi
  if ! all=$(refs "refs/heads/$BR"); then
    echo "LEAVE cannot read the refs of $PUSH_URL: whether $BR is there is unknown" >&2
    return 1
  fi
  now=$(ref_sha "$all" "refs/heads/$BR")
  case "$state" in
    refused)
      echo "this run's delete was refused: nothing to put back (branch $BR is ${now:-gone})"
      ;;
    pushing | unknown)
      if [ "$now" = "$SHA" ]; then
        echo "branch $BR is still at $now: the delete did not land, nothing to put back"
      elif [ -n "$now" ]; then
        # a branch there now at another SHA proves nothing about this run's delete: it may have landed and been pushed again
        echo "LEAVE branch $BR is at $now on $PUSH_URL, not the pinned $SHA, and whether this run deleted it is unknown: changed since the run" >&2
        return 1
      else
        # gone, by this run or another: put it back unless its proof reads as still keeping the commit (one that cannot be
        # read counts as not keeping it: the branch comes back, no commit lost)
        if ! valid_proof "$PROOF"; then
          echo "LEAVE $BR is gone, whether this run deleted it is unknown, and the run record names no proof (${PROOF:-none}): left for the owner" >&2
          return 1
        fi
        repo_info
        all=$(refs "refs/heads/$BASE")
        base=$(ref_sha "$all" "refs/heads/$BASE")
        if [ -n "$base" ] && held "$PROOF" "$base"; then
          echo "LEAVE $BR is gone and whether this run deleted it is unknown; its proof ($(proof_text "$PROOF")) still keeps $SHA on GitHub (no commit lost): left for the owner" >&2
          return 1
        fi
        write "recreate branch $BR at $SHA on $PUSH_URL (its proof does not read as holding)" recreate
        all=$(refs "refs/heads/$BR")
        [ "$(ref_sha "$all" "refs/heads/$BR")" = "$SHA" ] || return 1
      fi
      ;;
    deleted)
      if [ "$now" = "$SHA" ]; then
        echo "$PUSH_URL has $BR at $SHA: nothing to put back"
      elif [ -n "$now" ]; then
        echo "LEAVE branch $BR is at $now on $PUSH_URL, not the deleted $SHA: changed since the run" >&2
        return 1
      else
        write "recreate branch $BR at $SHA on $PUSH_URL" recreate
        all=$(refs "refs/heads/$BR")
        [ "$(ref_sha "$all" "refs/heads/$BR")" = "$SHA" ]
      fi
      ;;
    *)
      echo "LEAVE the run record $RECORD holds an unknown state ($state)" >&2
      return 1
      ;;
  esac
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
