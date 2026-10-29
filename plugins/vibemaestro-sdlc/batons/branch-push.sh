#!/usr/bin/env bash
# Purpose: push one local branch of the clone this runs in as a new branch of its private GitHub repository, pinned to the local tip, create-only, from a scratch repository no clone config reaches
# Targets: github.com/<--repo>, the repository the clone's remote (--remote, default origin) names; one new branch ref there
# Blast: one new branch on that repository holding the commits only this clone had; nothing else (no force, no other ref, no tag)
# Undo: none by this script: deleting a branch is an act the owner signs; while the branch is there, undo names it and exits non-zero (a remote it cannot read: non-zero too)
# Pre: the clone's remote URL names https or ssh github.com/<--repo>; the local branch is at --head; the repository reads private (not internal, not public), can be read and has no branch of that name; no commit it lacks changes a path under .github/workflows or .github/actions; at the push, its plan line is in the signed plan
# Stops: none
#   Why none: the push adds one branch to a private repository and moves nothing that exists. A public or internal repository
#   (publish) and a new commit that changes a workflow (it would run on push with the repository's secrets) are refused at
#   rehearse, so they are never escalated to a signature: those stay hand-written batons the owner signs.
# Usage: --branch <name> --head <sha40> --repo <owner/name> [--remote <name>]  (run it from the clone that holds the branch)
# Expect: push new branch * at * to *
#
# The kit baton kit:branch-push. Run it from the clone, only through the baton runner:
#   <launcher> go kit:branch-push --branch <name> --head <full sha> --repo <owner/name> [--remote <name>]
# Where the push goes: the clone only says which repository and which transport (its remote URL must name https or ssh
# github.com/<--repo>); the URL used is built from --repo (https://github.com/<repo>.git or the ssh form). Every git call that
# talks to the remote or reads commits runs in a scratch bare repository made for this phase (`git init --template=`), with no
# system or global config (GIT_CONFIG_NOSYSTEM, GIT_CONFIG_GLOBAL=/dev/null) and fixed settings: no hooks, https and ssh only,
# TLS verified, gh's credentials, no tags, no submodules. It reads the clone's objects through `objects/info/alternates`, so
# nothing the clone's config, hooks or the user's global config say (pushurl, insteadOf, core.sshCommand, http.proxy,
# push.followTags, log.showSignature, a remote helper) reaches the push. Those git calls get an allowlisted environment
# (`env -i`): PATH, HOME, TMPDIR, the locale, SSH_AUTH_SOCK, GIT_SSH_COMMAND, gh's token variables (GH_TOKEN, GITHUB_TOKEN,
# GH_ENTERPRISE_TOKEN, GH_HOST, GH_CONFIG_DIR) and the proxy variables; so no env-config (GIT_CONFIG_COUNT), GIT_EXEC_PATH,
# CA file or other GIT_* variable reaches them, and a proxy only tunnels TLS that git verifies against the default CAs. The
# programs the caller's PATH and GIT_SSH_COMMAND name are the caller's choice, and baton binds both into the signature. The
# clone itself is read only by `git config --get` and `git rev-parse`.
# The plan line carries the URL, the branch, the tip and the number of commits the remote lacks, so the signature binds them;
# the push itself checks that its plan line is in the signed plan (BATON_PLAN) first, since a push cannot be undone. It sends
# the pinned SHA create-only (`--force-with-lease=refs/heads/<branch>:`, an empty expected value: GitHub refuses it when the
# branch appeared meanwhile), so it never moves a ref that exists. The commits the remote lacks are counted against the tips
# it advertises now that the clone holds; one it advertises and the clone lacks may make the count, and the workflow check,
# err on the safe side (the refusal says to fetch first).
# Branch names: what `git check-ref-format --branch` accepts, minus the names git resolves first as another ref (HEAD, *_HEAD,
# AUTO_MERGE, BISECT_EXPECTED_REV, a first component refs, heads, tags or remotes, a full 40-hex SHA).
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
usage() { echo "usage: baton rehearse|run kit:branch-push --branch <name> --head <full sha> --repo <owner/name> [--remote <name>]" >&2; }
BR="" TIP="" REPO="" REMOTE=origin
while [ $# -gt 0 ]; do
  case "$1" in
    --branch | --head | --repo | --remote)
      if [ $# -lt 2 ]; then
        usage
        exit 64
      fi
      case "$1" in
        --branch) BR=$2 ;;
        --head) TIP=$2 ;;
        --repo) REPO=$2 ;;
        --remote) REMOTE=$2 ;;
      esac
      shift 2
      ;;
    *)
      usage
      exit 64
      ;;
  esac
done
if [ -z "$BR" ] || ! [[ "$TIP" =~ ^[0-9a-f]{40}$ ]] || ! [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
  || ! [[ "$REMOTE" =~ ^[A-Za-z0-9_.-]+$ ]]; then
  usage
  exit 64
fi
FIRST=${BR%%/*}
if ! git check-ref-format "refs/heads/$BR" > /dev/null 2>&1 || [[ "$BR" == -* ]] || [[ "$BR" =~ ^(HEAD|[A-Z_]+_HEAD|AUTO_MERGE|BISECT_EXPECTED_REV)$ ]] \
  || [ "$FIRST" = refs ] || [ "$FIRST" = heads ] || [ "$FIRST" = tags ] || [ "$FIRST" = remotes ] || [[ "$BR" =~ ^[0-9a-fA-F]{40}$ ]]; then
  echo "REFUSE branch $BR: not a branch name this kit pushes (git refuses it, or resolves it first as another ref)" >&2
  exit 64
fi
URL=$(git config --get "remote.$REMOTE.url" || true)
# the repository the URL names, lower-cased, and its transport, or nothing when it is not github.com over https or ssh
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

# the scratch repository: no config but these settings, no hooks, the clone's objects through alternates
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/kit-branch-push.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT
OBJECTS=$(git rev-parse --path-format=absolute --git-common-dir)/objects
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
printf '%s\n' "$OBJECTS" > "$SCRATCH/repo.git/objects/info/alternates"
PLANLINE=""

# heads — the branches the remote advertises now, "<sha> <ref>" per line; a remote that cannot be read fails
heads() { sgit ls-remote --heads "$PUSH_URL"; }
# remote_sha <heads> — the remote branch's SHA in that listing, empty when it has none
remote_sha() {
  local sha ref
  while read -r sha ref; do
    if [ "$ref" = "refs/heads/$BR" ]; then
      printf '%s' "$sha"
    fi
  done <<< "$1"
}
# push — only the signed plan's push, create-only
push() {
  if [ -z "${BATON_PLAN:-}" ] || ! grep -Fqx -- "$PLANLINE" "$BATON_PLAN"; then
    echo "REFUSE the push line is not in the signed plan (the world moved since signing): nothing pushed" >&2
    return 3
  fi
  sgit push -q --force-with-lease="refs/heads/$BR:" "$PUSH_URL" "$TIP:refs/heads/$BR"
}

# ── the act: every change through write() ──
act() {
  local named want vis local_tip known path n=0 wf="" all sha _ref missing=0 hint walk
  named=$(url_repo "$URL")
  want=$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')
  if [ -z "$named" ] || [ "$named" != "$want" ]; then
    echo "REFUSE remote $REMOTE is ${URL:-not set}: this kit pushes only to github.com/$REPO" >&2
    return 3
  fi
  vis=$(gh api "repos/$REPO" --jq '"\(.private) \(.visibility)"' 2>&1 || true)
  if [ "$vis" != "true private" ]; then
    echo "REFUSE $REPO does not read private (private, visibility: $vis): this kit pushes to private repositories only" >&2
    return 3
  fi
  local_tip=$(git rev-parse --verify -q "refs/heads/$BR" || true)
  if [ "$local_tip" != "$TIP" ]; then
    echo "REFUSE local branch $BR is at ${local_tip:-nothing}, not $TIP" >&2
    return 3
  fi
  if ! all=$(heads); then
    echo "REFUSE cannot read the branches of $PUSH_URL" >&2
    return 3
  fi
  if [ -n "$(remote_sha "$all")" ]; then
    echo "REFUSE $PUSH_URL already has a branch $BR" >&2
    return 3
  fi
  # what the new commits are counted against: the tips the remote advertises now that this clone holds (a tip it lacks is
  # left out, so the count and the check may only err on the safe side)
  known=()
  while read -r sha _ref; do
    if [ -z "$sha" ]; then
      continue
    elif sgit cat-file -e "$sha^{commit}" 2> /dev/null; then
      known+=("$sha")
    else
      missing=$((missing + 1))
    fi
  done <<< "$all"
  # every path a new commit changes, merges against each parent; a walk that fails is a refusal, never an empty list
  if ! walk=$(sgit log -z --diff-merges=separate --no-renames --format= --name-only "$TIP" ${known[@]+--not "${known[@]}"} | tr '\0' '\n'); then
    echo "REFUSE cannot list the paths the new commits change" >&2
    return 3
  fi
  while IFS= read -r path; do
    case "$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')" in
      .github/workflows/* | .github/actions/*) wf=$path ;;
    esac
  done <<< "$walk"
  if [ -n "$wf" ]; then
    hint=""
    [ "$missing" -eq 0 ] || hint=" (if the remote already has it: $missing of its branch tips are not in this clone, fetch first)"
    echo "REFUSE a commit $PUSH_URL lacks changes $wf: a workflow change runs on push with the repository's secrets; push it with a hand-written baton the owner signs$hint" >&2
    return 3
  fi
  n=$(sgit rev-list --count "$TIP" ${known[@]+--not "${known[@]}"})
  PLANLINE="push new branch $BR at $TIP to $PUSH_URL ($n commits it lacks)"
  write "$PLANLINE" push
}

# ── post-check: the remote branch is at the tip ──
postcheck() {
  local all now
  all=$(heads)
  now=$(remote_sha "$all")
  echo "$PUSH_URL $BR is at ${now:-nothing}"
  [ "$now" = "$TIP" ]
}

# ── undo: a branch cannot be deleted here; while it is there, undo names it and fails ──
undo() {
  local all now
  if ! all=$(heads); then
    echo "LEAVE cannot read the branches of $PUSH_URL: whether $BR landed is unknown" >&2
    return 1
  fi
  now=$(remote_sha "$all")
  if [ -z "$now" ]; then
    echo "$PUSH_URL has no branch $BR: nothing landed"
    return 0
  fi
  echo "LEAVE branch $BR at $now on $PUSH_URL: deleting a branch is an act the owner signs (irreversible-delete)" >&2
  return 1
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
