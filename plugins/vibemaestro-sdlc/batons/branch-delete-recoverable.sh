#!/usr/bin/env bash
# Purpose: delete one branch of a private GitHub repository at a pinned head that a local clone holds whole, merged or not, after bundling that head into the baton state directory, with a lease on that SHA, through the plugin's delete gate
# Targets: the github.com repository named by repo, which the clone's origin names; its branch ref refs/heads/<branch>; one bundle and a run record under the baton state directory
# Blast: one branch ref at the pinned head; its commits stay in a verified bundle of that head under the baton state directory, kept as run logs are (the newest 200); no tag, no other ref
# Undo: pushes the branch back from the bundle at the pinned SHA, create-only, while it is absent, when the run record says this run's delete landed or its outcome is unknown; a refused delete is left alone; a branch there again at another SHA is left and named (non-zero); it needs neither the clone nor its config
# Pre: clone is a plain clone (its .git a directory: not a worktree, submodule or bare repository), not shallow, not partial (no extensions.partialClone, no promisor remote, no .promisor pack), with no alternates and no grafts, and holds every object of head; its origin URL names https or ssh github.com/<repo>; the repository reads private; the branch exists at the pinned head, is not the default branch, is not protected, no ruleset forbids its deletion, it has no tag of its name and no open pull request from or into it; at the delete, its plan line is in the signed plan and the bundle it names verifies with that one head
# Stops: recoverable-delete
#   Why recoverable-delete: the branch need not be merged, so GitHub may be the only other place its commits live. The run's
#   first write bundles the pinned head from the clone into the baton state directory and verifies the bundle (a complete
#   history, that one head); only then does the delete gate delete, leased on the SHA, and only after it checks that bundle again.
#   Undo, and the owner later, push the branch back from the bundle, so nothing is lost while the bundle is kept. It is still a
#   stop word: the owner signs each run.
# Params: repo=repo branch=ref head=sha40 clone=path
# Expect: bundle branch * at * into *
# Expect: delete branch * at * (kept in bundle *) on *
#
# The kit baton kit:branch-delete-recoverable. Run it only through the baton runner:
#   <launcher> go kit:branch-delete-recoverable repo='<owner/name>' branch='<name>' head='<full sha>' clone='<absolute path>'
# head pins the branch: a branch whose tip on the remote is another SHA is refused (at rehearse, and again when the run reads
# it), and the delete's lease is on it. The clone gives the objects and the transport (its origin URL must name https or ssh
# github.com/<repo>); no git command runs inside it: its config file is read as a file, and its object directory is the
# alternate of the kit's scratch repository, where the proof (rev-list --objects --missing=error) and the bundle run. Every git
# call to the remote runs in that scratch repository with no system or global config and an allowlisted environment, as
# kit:branch-delete; every API call names github.com (--hostname). The bundle is
# <state dir>/bundles/kit-branch-delete-recoverable-<sha256 of "repo branch", 16 hex>-<head>.bundle: the plan names it, so the
# signature binds it. The delete itself is the plugin's gate gates/branch_delete.py, run inside write(): it checks the plan
# line is in the signed plan and names this delete and this bundle, that the bundle verifies with that one head, then pushes
# with a lease on the head; no delete is written in this file. A run record (one per target and runner process) holds the
# delete's state and the push URL, so undo reads neither the clone nor its config.
# Branch names: those kit:branch-delete takes.
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
usage() { echo "usage: baton rehearse|run kit:branch-delete-recoverable repo=<owner/name> branch=<name> head=<full sha> clone=<absolute path>  (only through the baton runner)" >&2; }
if [ -z "${BATON_PLUGIN_ROOT:-}" ] || [ $# -ne 4 ]; then
  usage
  exit 64
fi
P_REPO="$1"
P_BRANCH="$2"
P_HEAD="$3"
P_CLONE="$4"
REPO="$P_REPO" BR="$P_BRANCH" SHA="$P_HEAD" CLONE="$P_CLONE"
if ! [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || ! [[ "$SHA" =~ ^[0-9a-f]{40}$ ]] || ! [[ "$CLONE" =~ ^/[A-Za-z0-9._/@+-]+$ ]]; then
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
GD="$CLONE/.git"
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

# the baton state directory, as baton computes it; the run record and the bundles live under it
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
TKEY=$(sha256_text "$REPO $BR" | cut -c1-16)
BDIR="$STATE_BASE/vibemaestro/baton/bundles"
BUNDLE="$BDIR/kit-branch-delete-recoverable-$TKEY-$SHA.bundle"
BUNDLES_KEPT=200            # baton's RUNS_KEPT: a bundle is kept as long as run logs are
# one record per target (repository and branch) and per baton process ($PPID: the runner that runs this run's phases, run,
# post-check and undo): another run, or one running at the same time, never reads this run's record
RECORD="$STATE_BASE/vibemaestro/baton/records/kit-branch-delete-recoverable-$TKEY-$PPID.last"
# plan_id — the sha256 of the signed plan baton hands the run and its undo (BATON_PLAN): which run a record belongs to
plan_id() {
  if [ -n "${BATON_PLAN:-}" ] && [ -f "$BATON_PLAN" ]; then
    sha256_text "$(cat "$BATON_PLAN")"
  fi
}

# the scratch repository: no config but these settings, no hooks; in act, the clone's objects as its alternate
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/kit-branch-delete-recoverable.XXXXXX")
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
# cfile <key> — a value of the clone's own config file, read as a file (no include, no git run inside the clone); empty when none
cfile() { cleanenv git config --file "$GD/config" "$@" 2> /dev/null || true; }
URL=""
if [ -f "$GD/config" ]; then
  URL=$(cfile --get remote.origin.url)
fi
case "$URL" in
  https://*) PUSH_URL="https://$HOST/$REPO.git" ;;
  *) PUSH_URL="git@$HOST:$REPO.git" ;;
esac
BASE="" NOW="" OWNER="" DEFAULT=""

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
# repo_info — sets OWNER, DEFAULT and BASE from the API; rc 3 on a repository that does not read private
repo_info() {
  local info priv vis
  info=$(gh api --hostname "$HOST" "repos/$REPO" --jq '"\(.private) \(.visibility) \(.default_branch) \(.owner.login) \(.full_name)"' 2>&1 || true)
  read -r priv vis DEFAULT OWNER _ <<< "$info"
  if [ "$priv $vis" != "true private" ] || ! branchname "$DEFAULT" || ! [[ "$OWNER" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    echo "REFUSE $REPO does not read private, or has no default branch ($info): this kit deletes on private repositories only" >&2
    return 3
  fi
  BASE=$DEFAULT
}
# clone_holds — rc 0 when the clone is a plain, complete clone that holds every object of $SHA: the proof runs in the scratch
# repository with the clone's object directory as its only alternate (the clone's refs, config and hooks never run)
clone_holds() {
  local why="" pr
  if [ -L "$GD" ] || [ ! -d "$GD" ] || [ ! -d "$GD/objects" ] || [ -e "$GD/commondir" ]; then
    why="$CLONE/.git is not a directory holding objects (a worktree, a submodule, a bare repository or no repository)"
  elif [ -e "$GD/shallow" ]; then
    why="the clone is shallow"
  elif [ -e "$GD/objects/info/alternates" ] || [ -e "$GD/objects/info/http-alternates" ]; then
    why="the clone uses alternates: its objects may live in another repository"
  elif [ -e "$GD/info/grafts" ]; then
    why="the clone has grafts"
  else
    pr=$(cfile --get-regexp '^(extensions\.partialclone|remote\..*\.(promisor|partialclonefilter))$')
    if [ -n "$pr" ] || [ -n "$(find "$GD/objects/pack" -maxdepth 1 -name '*.promisor' 2> /dev/null | head -n 1)" ]; then
      why="the clone is partial (a promisor remote): it may lack objects it fetches on demand"
    fi
  fi
  if [ -z "$why" ]; then
    mkdir -p "$SCRATCH/repo.git/objects/info"
    printf '%s\n' "$GD/objects" > "$SCRATCH/repo.git/objects/info/alternates"
    if ! sgit rev-list --objects --missing=error "$SHA" > /dev/null 2>&1; then
      why="the clone lacks an object of $SHA"
    fi
  fi
  if [ -n "$why" ]; then
    echo "REFUSE clone $CLONE: $why; this kit deletes only a head the clone holds whole (a full, plain clone that has fetched it)" >&2
    return 3
  fi
}
# bundle_ok <file> — rc 0 when the file is a regular bundle whose one head is $SHA refs/heads/$BR and that unbundles into an
# empty repository with every object of $SHA (a complete history: no prerequisite)
bundle_ok() {
  local v heads
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  v=$(mktemp -d "$SCRATCH/verify.XXXXXX")
  cleanenv git init -q --bare --template= "$v/v.git"
  heads=$(cleanenv git -c core.hooksPath=/dev/null -C "$v/v.git" bundle list-heads "$1" 2> /dev/null) || return 1
  [ "$heads" = "$SHA refs/heads/$BR" ] || return 1
  cleanenv git -c core.hooksPath=/dev/null -C "$v/v.git" bundle unbundle "$1" > /dev/null 2>&1 || return 1
  cleanenv git -c core.hooksPath=/dev/null -C "$v/v.git" rev-list --objects --missing=error "$SHA" > /dev/null 2>&1
}
# record <state> — the run record: the signed plan's id, the SHA, the delete's state (pushing, deleted, refused, unknown) and
# the push URL
record() { mkdir -p "$(dirname "$RECORD")" && printf '%s %s %s %s\n' "$(plan_id)" "$SHA" "$1" "$PUSH_URL" > "$RECORD"; }
# mkbundle — the head bundled from the scratch repository (the clone's objects as its alternate), verified, then moved into
# place; the kit's bundles beyond the newest $BUNDLES_KEPT are dropped (the plan line says so): only names of the kit's exact
# shape, each as a path under the bundles directory
mkbundle() {
  local tmp old
  mkdir -p "$BDIR"
  tmp=$(mktemp "$BDIR/.kit-branch-delete-recoverable.XXXXXX")
  sgit update-ref "refs/heads/$BR" "$SHA"
  if ! sgit bundle create -q "$tmp" "refs/heads/$BR" > /dev/null 2>&1 || ! bundle_ok "$tmp"; then
    rm -f -- "$tmp"
    echo "REFUSE the bundle of $BR at $SHA did not verify: nothing deleted" >&2
    return 3
  fi
  mv -f -- "$tmp" "$BUNDLE"
  local n=0
  # shellcheck disable=SC2012     # -q shows a newline in a name as ?, so such a name matches the exact shape in no piece
  ls -1tq "$BDIR" | while IFS= read -r old; do
    [[ "$old" =~ ^kit-branch-delete-recoverable-[0-9a-f]{16}-[0-9a-f]{40}\.bundle$ ]] || continue
    n=$((n + 1))
    if [ "$n" -gt "$BUNDLES_KEPT" ]; then
      rm -f -- "$BDIR/$old"
    fi
  done
}
# del — only the signed plan's delete, leased on the pinned SHA, written by the plugin's delete gate (it refuses a plan line
# that is not in the signed plan, names another delete or a bundle that does not verify, and pushes with the lease); the
# record says whether it landed
del() {
  local rc=0 all
  find "$(dirname "$RECORD")" -name 'kit-branch-delete-recoverable-*.last' -mtime +7 -exec rm -f {} + 2> /dev/null || true
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
  local named want all prot rules n q
  clone_holds
  named=$(url_repo "$URL")
  want=$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')
  if [ -z "$named" ] || [ "$named" != "$want" ]; then
    echo "REFUSE the origin of clone $CLONE is ${URL:-not set}: this kit deletes only on github.com/$REPO" >&2
    return 3
  fi
  repo_info
  if [ "$BR" = "$DEFAULT" ]; then
    echo "REFUSE $BR is the default branch: never deleted by this kit" >&2
    return 3
  fi
  if ! all=$(refs "refs/heads/$BR" "refs/tags/$BR"); then
    echo "REFUSE cannot read the refs of $PUSH_URL" >&2
    return 3
  fi
  NOW=$(ref_sha "$all" "refs/heads/$BR")
  if ! [[ "$NOW" =~ ^[0-9a-f]{40}$ ]]; then
    echo "REFUSE $PUSH_URL has no branch $BR" >&2
    return 3
  fi
  if [ "$NOW" != "$SHA" ]; then
    echo "REFUSE branch $BR is at $NOW on $PUSH_URL, not at the pinned head $SHA: a tip that moved off the pinned SHA is never deleted" >&2
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
  write "bundle branch $BR at $SHA into $BUNDLE, dropping the kit's bundles past the newest $BUNDLES_KEPT" mkbundle
  PLANLINE="delete branch $BR at $SHA (kept in bundle $BUNDLE) on $PUSH_URL"
  write "$PLANLINE" del
}

# read_record — sets SHA, STATE and PUSH_URL from this run's record; rc 1 when there is none
read_record() {
  local _plan url
  [ -f "$RECORD" ] || return 1
  read -r _plan SHA STATE url < "$RECORD"
  case "$url" in
    "https://$HOST/$REPO.git" | "git@$HOST:$REPO.git") PUSH_URL=$url ;;    # the record names no other remote
  esac
  BUNDLE="$BDIR/kit-branch-delete-recoverable-$TKEY-$SHA.bundle"
}

# ── post-check: the branch is gone, and the bundle still verifies with its head (else undo puts it back) ──
postcheck() {
  local all now STATE=""
  read_record || true          # the post-check gets no signed plan: the run's own record names the SHA and the URL
  all=$(refs "refs/heads/$BR")
  now=$(ref_sha "$all" "refs/heads/$BR")
  echo "$PUSH_URL $BR is ${now:+at }${now:-gone}"
  [ -z "$now" ] || return 1
  if ! bundle_ok "$BUNDLE"; then
    echo "the bundle $BUNDLE does not verify with $SHA refs/heads/$BR" >&2
    return 1
  fi
  rm -f -- "$RECORD"            # the run holds: no undo reads this record, and a later process with this PID never finds it
}

# restore — the branch back at the deleted SHA from the bundle, create-only (the lease asks that the ref be absent)
restore() {
  bundle_ok "$BUNDLE" || { echo "LEAVE the bundle $BUNDLE does not verify: nothing pushed" >&2; return 1; }
  sgit bundle unbundle "$BUNDLE" > /dev/null
  sgit push -q --force-with-lease="refs/heads/$BR:" "$PUSH_URL" "$SHA:refs/heads/$BR"
}

# ── undo: from the run record; the branch back at its SHA when this run's delete landed, or may have ──
undo() {
  local plan all now mine STATE=""
  if [ ! -f "$RECORD" ]; then
    echo "no run record: this run never pushed a delete, nothing to put back"
    return 0
  fi
  read -r plan _ < "$RECORD"
  mine=$(plan_id)
  if [ -z "$mine" ]; then
    echo "LEAVE no signed plan (BATON_PLAN): cannot tell whether $RECORD is this run's" >&2
    return 1
  fi
  if [ "$plan" != "$mine" ]; then
    echo "the run record $RECORD is an earlier run's: nothing of this run to put back"
    return 0
  fi
  read_record
  if ! all=$(refs "refs/heads/$BR"); then
    echo "LEAVE cannot read the refs of $PUSH_URL: whether $BR is there is unknown" >&2
    return 1
  fi
  now=$(ref_sha "$all" "refs/heads/$BR")
  case "$STATE" in
    refused)
      echo "this run's delete was refused: nothing to put back (branch $BR is ${now:-gone})"
      ;;
    pushing | unknown | deleted)
      if [ "$now" = "$SHA" ]; then
        echo "$PUSH_URL has $BR at $SHA: nothing to put back"
      elif [ -n "$now" ]; then
        echo "LEAVE branch $BR is at $now on $PUSH_URL, not the pinned $SHA: changed since the run" >&2
        return 1
      else
        # gone, by this run or another: the bundle puts the same commit back, so no commit is lost either way
        write "push branch $BR at $SHA back to $PUSH_URL from the bundle $BUNDLE" restore
        all=$(refs "refs/heads/$BR")
        [ "$(ref_sha "$all" "refs/heads/$BR")" = "$SHA" ] || return 1
      fi
      ;;
    *)
      echo "LEAVE the run record $RECORD holds an unknown state ($STATE)" >&2
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
