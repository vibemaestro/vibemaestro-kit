#!/bin/bash
# =============================================================================
# The kit baton kit:branch-push (batons/branch-push.sh), through baton.py
# =============================================================================
# Run: bash tests/test-baton-branch-push.sh
#
# Offline: real git, a clone whose origin URL is the ssh form for github.com/<owner/name>, and GIT_SSH_COMMAND set to a fake ssh
# (written below) that runs git's upload-pack or receive-pack on a local bare repository under the case directory: git resolves
# the URL as is, with no rewrite (the kit refuses one). A fake `gh` (tests/fixtures/branch_dispatch_gh.py) answers the
# repository's visibility. The bare repository's main already holds a workflow file, so only new commits are judged.
#   [P] go: rehearse plans the push (URL, branch, tip, commits the remote lacks) and pushes nothing; the run pushes the pinned
#       tip as a new branch and the post-check reads it there
#   [R] refusals at rehearse, no push: a public or internal repository, a remote that is not github.com/<--repo>, a pushurl,
#       insteadOf or pushInsteadOf rule that sends the remote elsewhere, a remote that cannot be read, a local branch off
#       --head, a branch the remote already has, a new commit that changes a workflow (any case), each branch name git
#       resolves first as another ref; a stale clone is judged on the new commits only
#   [S] at the push: a plan line not in the signed plan pushes nothing; a branch that appears just before the push is not
#       moved (create-only)
#   [U] undo: a branch it cannot delete is named and the run ends rc 5; a push that never landed undoes cleanly
#   [X] planted breaks: each family goes red on a plugin copy with one break in the kit
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
# shellcheck source=fixtures/ports.sh
. "$HERE/fixtures/ports.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
export PYTHONDONTWRITEBYTECODE=1
export BATON_POSTCHECK_WAITS="0 0 0 0"   # a failed post-check is undone at once
# gitconf — the suite's global git config: an identity only (a case that plants a rewrite rule calls it again after)
gitconf() { printf '[user]\n\tname = t\n\temail = t\n' > "$GIT_CONFIG_GLOBAL"; }
gitconf
H0=$(tree_hash "$SRC_ROOT")
FB="$TMP/fakebin"; mkdir -p "$FB"
printf '#!/bin/sh\nexec python3 -B "%s" "$@"\n' "$HERE/fixtures/branch_dispatch_gh.py" > "$FB/gh"; chmod +x "$FB/gh"
# the fake ssh: `fakessh <root> <options> <host> "git-upload-pack '<owner/name>.git'"` runs that pack command on
# <root>/<owner/name>.git (the case directory, given in GIT_SSH_COMMAND, the one variable of the suite the kit passes on);
# <root>/down makes it fail (a remote that cannot be read); <root>/race makes a receive-pack first create refs/heads/topic
# at main (a branch that appears just before the push)
cat > "$FB/fakessh" <<'EOF'
#!/usr/bin/env bash
FAKE_SSH_ROOT=$1; shift
while [ $# -gt 1 ]; do shift; done
cmd=${1%% *}; repo=${1#* }; repo=${repo//\'/}; repo=${repo#/}
[ ! -e "$FAKE_SSH_ROOT/down" ] || { echo "fakessh: connection refused" >&2; exit 255; }
if [ "$cmd" = git-receive-pack ] && [ -e "$FAKE_SSH_ROOT/race" ]; then
  git --git-dir="$FAKE_SSH_ROOT/$repo" update-ref refs/heads/topic refs/heads/main
fi
exec git "${cmd#git-}" "$FAKE_SSH_ROOT/$repo"
EOF
chmod +x "$FB/fakessh"
PATH="$FB:$PATH"; export PATH
GH=github.com
BT_OUT="$TMP/bt.out"; ST=""

# setup <owner/name> — a case directory (printed): a bare repository standing in for github.com/<owner/name> (main holds README.md
# and .github/workflows/ci.yml), reached by the fake ssh; a clone of it whose origin URL is the ssh form for that repository;
# the fake gh's world (acme/app private, acme/pub public, acme/int internal, acme/other private)
setup() {
  local d repo=$1
  d=$(fresh)
  mkdir -p "$d/$(dirname "$repo")"
  git_ init -q --bare -b main "$d/$repo.git"; ln -s "$d/$repo.git" "$d/bare.git"
  git_ init -q -b main "$d/seed"
  mkdir -p "$d/seed/.github/workflows"; printf 'on: push\n' > "$d/seed/.github/workflows/ci.yml"; printf 'hi\n' > "$d/seed/README.md"
  git_ -C "$d/seed" add -A; git_ -C "$d/seed" commit -q -m seed; git_ -C "$d/seed" push -q "$d/bare.git" main
  git_ clone -q "$d/bare.git" "$d/clone"
  git_ -C "$d/clone" remote set-url origin "git@$GH:$repo.git"
  python3 - "$d/gh.json" <<'PY'
import json, sys
json.dump({"viewer": "bot", "next_run": 1, "repos": {
    "acme/app": {"private": True, "visibility": "private"}, "acme/pub": {"private": False, "visibility": "public"},
    "acme/int": {"private": True, "visibility": "internal"}, "acme/other": {"private": True, "visibility": "private"}}},
    open(sys.argv[1], "w"))
PY
  printf '%s' "$d"
}
# topic <dir> [path] — a local branch topic with one commit (docs/a.md, or the path given); prints its tip
topic() {
  local c="$1/clone" p=${2:-docs/a.md}
  git_ -C "$c" checkout -q -b topic
  mkdir -p "$c/$(dirname "$p")"; printf 'x\n' > "$c/$p"; git_ -C "$c" add -A; git_ -C "$c" commit -q -m "add $p"
  git_ -C "$c" rev-parse HEAD
}
remote_tip() { git_ -C "$1/bare.git" rev-parse --verify -q "refs/heads/$2" || true; }
# bt <plugin> <case dir> <baton args...> — rc of baton run from the clone with the state in $ST; its output is in $BT_OUT
bt() { local p=$1 d=$2; shift 2; [ $# -eq 2 ] && [ "$1" = mode ] && { baton_set_mode "$ST" "$2"; echo 0; return; }; ( cd "$d/clone" && XDG_STATE_HOME="$ST" GIT_SSH_COMMAND="$FB/fakessh $d" FAKE_LOG="$d/fake.log" FAKE_GH_WORLD="$d/gh.json" python3 "$p/scripts/baton.py" "$@" ) > "$BT_OUT" 2>&1; echo $?; }
# kit_phase <plugin> <case dir> <phase> <signed plan file> <kit args...> — the kit's own phase, run directly; rc, output in $BT_OUT
kit_phase() {
  local p=$1 d=$2 ph=$3 plan=$4; shift 4
  ( cd "$d/clone" && XDG_STATE_HOME="$ST" GIT_SSH_COMMAND="$FB/fakessh $d" FAKE_LOG="$d/fake.log" FAKE_GH_WORLD="$d/gh.json" BATON_PHASE="$ph" BATON_PLAN="$plan" \
      BATON_PLUGIN_ROOT="$p" bash "$p/batons/branch-push.sh" "$@" ) > "$BT_OUT" 2>&1; echo $?
}
sg() {
  local p=$1 d=$2 seal; shift 2
  bt "$p" "$d" mode auto >/dev/null
  seal=$( ( cd "$d/clone" && XDG_STATE_HOME="$ST" GIT_SSH_COMMAND="$FB/fakessh $d" FAKE_LOG="$d/fake.log" FAKE_GH_WORLD="$d/gh.json" python3 "$p/scripts/baton.py" rehearse "$@" ) 2>/dev/null \
          | sed -n 's/^seal \([^ ]*\) .*/\1/p')
  bt "$p" "$d" sign --by coordinator-auto --seal "${seal:-none}" "$@"
}
K=kit:branch-push

fam_push() {
  local P=$1 d t
  ST="$(fresh)/state"; d=$(setup acme/app); t=$(topic "$d")
  eq "$(bt "$P" "$d" rehearse $K --branch topic --head "$t" --repo acme/app)" 0 "[P] rehearse: rc 0"
  has "$(cat "$BT_OUT")" "PLAN push new branch topic at $t to git@$GH:acme/app.git (1 commits it lacks)" "[P] …the plan names the URL, branch, tip and the commits the remote lacks"
  eq "$(remote_tip "$d" topic)" "" "[P] …rehearse pushed nothing"
  eq "$(sg "$P" "$d" $K --branch topic --head "$t" --repo acme/app)/$(bt "$P" "$d" run $K --branch topic --head "$t" --repo acme/app)" "0/0" "[P] sign and run: rc 0"
  eq "$(remote_tip "$d" topic)" "$t" "[P] …the remote has topic at the pinned tip"
  ST="$(fresh)/state"; d=$(setup acme/app); t=$(topic "$d")
  git_ -C "$d/clone" remote rename origin up
  eq "$(bt "$P" "$d" mode auto >/dev/null; bt "$P" "$d" go $K --branch topic --head "$t" --repo acme/app --remote up)" 0 "[P] go with --remote up: rc 0"
  eq "$(remote_tip "$d" topic)" "$t" "[P] …pushed to the repository that remote names"
}

# misroute <case dir> — a second bare repository acme/pub beside acme/app, where a push sent elsewhere would land
misroute() { git_ init -q --bare -b main "$1/acme/pub.git"; }
pub_tip() { git_ -C "$1/acme/pub.git" rev-parse --verify -q refs/heads/topic || true; }

fam_steer() {
  local P=$1 d t
  ST="$(fresh)/state"; d=$(setup acme/app); t=$(topic "$d"); misroute "$d"
  git_ -C "$d/clone" config remote.origin.pushurl "git@$GH:acme/pub.git"
  git_ -C "$d/clone" config "url.git@$GH:acme/pub.git.pushInsteadOf" "git@$GH:acme/app.git"
  printf '[url "git@%s:acme/pub.git"]\n\tinsteadOf = git@%s:acme/app.git\n' "$GH" "$GH" >> "$GIT_CONFIG_GLOBAL"
  eq "$(bt "$P" "$d" mode auto >/dev/null; bt "$P" "$d" go $K --branch topic --head "$t" --repo acme/app)" 0 "[G] a pushurl, a pushInsteadOf and a global insteadOf rule toward acme/pub: go rc 0"
  eq "$(remote_tip "$d" topic):$(pub_tip "$d")" "$t:" "[G] …the push lands in acme/app, nothing in acme/pub"
  gitconf
  ST="$(fresh)/state"; d=$(setup acme/app); t=$(topic "$d"); misroute "$d"
  mkdir -p "$d/sshbin"; printf '#!/bin/sh\nexec "%s" "%s" "$@"\n' "$FB/fakessh" "$d" > "$d/sshbin/ssh"; chmod +x "$d/sshbin/ssh"
  printf '#!/bin/sh\n: > "%s/evil-ssh"\nexec "%s" "%s" "$@"\n' "$d" "$FB/fakessh" "$d" > "$d/evil"; chmod +x "$d/evil"
  git_ -C "$d/clone" config core.sshCommand "$d/evil"
  mkdir -p "$d/clone/.git/hooks"; printf '#!/bin/sh\n: > "%s/evil-hook"\n' "$d" > "$d/clone/.git/hooks/pre-push"; chmod +x "$d/clone/.git/hooks/pre-push"
  git_ -C "$d/clone" config log.showSignature true; git_ -C "$d/clone" config gpg.program "$d/evil"
  git_ -C "$d/clone" config push.followTags true; git_ -C "$d/clone" tag -a -m v v9.9.9 "$t"
  baton_set_mode "$ST" auto
  ( cd "$d/clone" && env -u GIT_SSH_COMMAND PATH="$d/sshbin:$PATH" XDG_STATE_HOME="$ST" GIT_SSH_COMMAND="$FB/fakessh $d" FAKE_LOG="$d/fake.log" FAKE_GH_WORLD="$d/gh.json" \
      sh -c 'python3 "$1/scripts/baton.py" go kit:branch-push --branch topic --head "$2" --repo acme/app' _ "$P" "$t" ) > "$BT_OUT" 2>&1
  eq "$?:$(remote_tip "$d" topic)" "0:$t" "[G] the clone's core.sshCommand, pre-push hook, log.showSignature with gpg.program and push.followTags set: go rc 0, topic pushed"
  eq "$(ls "$d" | grep -c '^evil-')" 0 "[G] …none of the clone's programs ran (no ssh command, no hook, no gpg)"
  eq "$(git_ -C "$d/acme/app.git" tag | grep -c .)" 0 "[G] …and no tag was pushed"
  ST="$(fresh)/state"; d=$(setup acme/app); t=$(topic "$d"); misroute "$d"; mkdir -p "$d/nowhere"
  baton_set_mode "$ST" auto
  ( cd "$d/clone" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.git@$GH:acme/pub.git.pushInsteadOf" GIT_CONFIG_VALUE_0="git@$GH:acme/app.git" \
      GIT_EXEC_PATH="$d/nowhere" GIT_SSL_CAINFO="$d/nowhere/ca.pem" GIT_SSH_COMMAND="$FB/fakessh $d" XDG_STATE_HOME="$ST" FAKE_LOG="$d/fake.log" FAKE_GH_WORLD="$d/gh.json" \
      sh -c 'python3 "$1/scripts/baton.py" go kit:branch-push --branch topic --head "$2" --repo acme/app' _ "$P" "$t" ) > "$BT_OUT" 2>&1
  eq "$?:$(remote_tip "$d" topic):$(pub_tip "$d")" "0:$t:" "[G] env-config (a pushInsteadOf toward acme/pub), GIT_EXEC_PATH and GIT_SSL_CAINFO in the environment: the push lands in acme/app only"
}

fam_refuse() {
  local P=$1 d t b
  ST="$(fresh)/state"
  d=$(setup acme/pub); t=$(topic "$d")
  eq "$(bt "$P" "$d" rehearse $K --branch topic --head "$t" --repo acme/pub)" 1 "[R] a public repository: rehearse rc 1"
  has "$(cat "$BT_OUT")" "REFUSE acme/pub does not read private" "[R] …refused by name"
  d=$(setup acme/int); t=$(topic "$d")
  eq "$(bt "$P" "$d" rehearse $K --branch topic --head "$t" --repo acme/int)" 1 "[R] an internal repository: rehearse rc 1"
  d=$(setup acme/app); t=$(topic "$d"); git_ clone -q --bare "$d/bare.git" "$d/acme/other.git"   # a twin a misrouted push would reach
  eq "$(bt "$P" "$d" rehearse $K --branch topic --head "$t" --repo acme/other)" 1 "[R] a remote that names another repository than --repo: rehearse rc 1"
  has "$(cat "$BT_OUT")" "REFUSE remote origin is git@$GH:acme/app.git" "[R] …refused by name"
  d=$(setup acme/app); git_ -C "$d/clone" remote set-url origin "https://$GH/acme/app.git"; t=$(topic "$d")
  eq "$(bt "$P" "$d" rehearse $K --branch topic --head "$t" --repo acme/other)" 1 "[R] an https remote that names another repository: rehearse rc 1"
  d=$(setup acme/app); git_ -C "$d/clone" remote set-url origin "$d/bare.git"; t=$(topic "$d")
  eq "$(bt "$P" "$d" rehearse $K --branch topic --head "$t" --repo acme/app)" 1 "[R] a remote that is not github.com (a local path): rehearse rc 1"
  d=$(setup acme/app); t=$(topic "$d"); : > "$d/down"
  eq "$(bt "$P" "$d" rehearse $K --branch topic --head "$t" --repo acme/app)" 1 "[R] a remote that cannot be read: rehearse rc 1"
  has "$(cat "$BT_OUT")" "REFUSE cannot read the branches of git@$GH:acme/app.git" "[R] …refused as a remote that cannot be read"
  d=$(setup acme/app); t=$(topic "$d")
  eq "$(bt "$P" "$d" rehearse $K --branch topic --head "$(git_ -C "$d/clone" rev-parse main)" --repo acme/app)" 1 "[R] a local branch that is not at --head (main's tip): rehearse rc 1"
  GIT_SSH_COMMAND="$FB/fakessh $d" git_ -C "$d/clone" push -q origin topic
  eq "$(bt "$P" "$d" rehearse $K --branch topic --head "$t" --repo acme/app)" 1 "[R] a branch the remote already has: rehearse rc 1"
  has "$(cat "$BT_OUT")" "REFUSE git@$GH:acme/app.git already has a branch topic" "[R] …refused by name"
  for b in .github/workflows/x.yml .GitHub/Workflows/x.yml .github/actions/a/action.yml '.github/workflows/é.yml' "$(printf '.github/workflows/a\tb.yml')"; do
    d=$(setup acme/app); t=$(topic "$d" "$b")
    eq "$(bt "$P" "$d" rehearse $K --branch topic --head "$t" --repo acme/app)" 1 "[R] a new commit that changes $b: rehearse rc 1"
  done
  has "$(cat "$BT_OUT")" "REFUSE a commit git@$GH:acme/app.git lacks changes" "[R] …refused by name"
  d=$(setup acme/app); git_ -C "$d/clone" checkout -q -b b2; printf 'b\n' > "$d/clone/b.md"; git_ -C "$d/clone" add b.md; git_ -C "$d/clone" commit -q -m b2
  GIT_SSH_COMMAND="$FB/fakessh $d" git_ -C "$d/clone" push -q origin b2; git_ -C "$d/clone" checkout -q -b topic main
  git_ -C "$d/clone" merge -q --no-commit --no-ff b2 2>/dev/null; printf 'on: push\njobs: {evil: {runs-on: x}}\n' > "$d/clone/.github/workflows/ci.yml"
  git_ -C "$d/clone" add -A; git_ -C "$d/clone" commit -q -m "merge b2"; t=$(git_ -C "$d/clone" rev-parse HEAD)
  ( cd "$d/clone" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=log.diffMerges GIT_CONFIG_VALUE_0=off GIT_SSH_COMMAND="$FB/fakessh $d" XDG_STATE_HOME="$ST" \
      FAKE_LOG="$d/fake.log" FAKE_GH_WORLD="$d/gh.json" python3 "$P/scripts/baton.py" rehearse $K --branch topic --head "$t" --repo acme/app ) > "$BT_OUT" 2>&1
  eq "$?" 1 "[R] a workflow change made inside a merge, with log.diffMerges=off in env-config: rehearse rc 1"
  d=$(setup acme/app); t=$(topic "$d"); tr=$(git_ -C "$d/clone" rev-parse "$t^{tree}"); rm -f "$d/clone/.git/objects/${tr:0:2}/${tr:2}"
  eq "$(bt "$P" "$d" rehearse $K --branch topic --head "$t" --repo acme/app)" 1 "[R] a commit walk that fails (a tree missing): rehearse rc 1, not a pass"
  has "$(cat "$BT_OUT")" "REFUSE cannot list the paths the new commits change" "[R] …refused by name"
  d=$(setup acme/app); t=$(topic "$d" .github/workflows/evil.yml); git_ -C "$d/clone" update-ref refs/remotes/origin/zzz "$t"
  eq "$(bt "$P" "$d" rehearse $K --branch topic --head "$t" --repo acme/app)" 1 "[R] a workflow change hidden behind a local tracking ref the remote does not have: rehearse rc 1"
  d=$(setup acme/app); t=$(topic "$d")
  git_ clone -q "$d/bare.git" "$d/other"; mkdir -p "$d/other/.github/workflows"; printf 'x\n' > "$d/other/.github/workflows/b.yml"
  git_ -C "$d/other" add -A; git_ -C "$d/other" commit -q -m "main moves on"; git_ -C "$d/other" push -q origin main
  eq "$(bt "$P" "$d" rehearse $K --branch topic --head "$t" --repo acme/app)" 1 "[R] a stale clone (the remote's main moved past the last fetch): the check errs on the safe side, rc 1"
  has "$(cat "$BT_OUT")" "fetch first" "[R] …and the refusal says to fetch first"
  GIT_SSH_COMMAND="$FB/fakessh $d" git_ -C "$d/clone" fetch -q origin
  eq "$(bt "$P" "$d" rehearse $K --branch topic --head "$t" --repo acme/app)" 0 "[R] …after a fetch, topic's commit alone is judged: rc 0"
  has "$(cat "$BT_OUT")" "(1 commits it lacks)" "[R] …and counted"
  d=$(setup acme/app); t=$(topic "$d")
  for b in HEAD FETCH_HEAD heads/x tags/v1 remotes/origin/x refs/heads/x "$(printf 'A%.0s' $(seq 40))" 'a..b'; do
    git_ -C "$d/clone" branch -q -f "$b" "$t" 2>/dev/null
    eq "$(bt "$P" "$d" rehearse $K --branch "$b" --head "$t" --repo acme/app)" 1 "[R] a branch named $b: rehearse rc 1"
  done
  eq "$(git_ -C "$d/bare.git" for-each-ref --format=x refs/heads | grep -c x)" 1 "[R] …no push in any of them (the remote holds main only)"
}

# failing_copy <plugin> <dir> — a copy of that plugin (a broken one included) whose kit post-check fails, so run undoes
failing_copy() { cp -r "$1" "$2"; mutate "$2/batons/branch-push.sh" '
postcheck() {
' '
postcheck() {
  return 1
'; }

fam_undo() {
  local P=$1 d t C
  C="$(fresh)/plugin"; failing_copy "$P" "$C"
  ST="$(fresh)/state"; d=$(setup acme/app); t=$(topic "$d")
  eq "$(sg "$C" "$d" $K --branch topic --head "$t" --repo acme/app)/$(bt "$C" "$d" run $K --branch topic --head "$t" --repo acme/app)" "0/5" "[U] a push that landed and a post-check that fails: undo cannot delete the branch, rc 5"
  has "$(cat "$BT_OUT")" "LEAVE branch topic at $t on git@$GH:acme/app.git" "[U] …it names the branch it leaves"
  eq "$(remote_tip "$d" topic)" "$t" "[U] …the branch stays"
  eq "$(kit_phase "$P" "$d" undo /dev/null --branch other --head "$t" --repo acme/app)" 0 "[U] the undo of a push that never landed: rc 0"
  has "$(cat "$BT_OUT")" "nothing landed" "[U] …and it says so"
  : > "$d/down"
  eq "$(kit_phase "$P" "$d" undo /dev/null --branch topic --head "$t" --repo acme/app)" 1 "[U] an undo that cannot read the remote: rc 1, not 'nothing landed'"
  has "$(cat "$BT_OUT")" "LEAVE cannot read the branches" "[U] …it says what it could not tell"
}

fam_signed() {
  local P=$1 d t
  ST="$(fresh)/state"; d=$(setup acme/app); t=$(topic "$d")
  printf 'push new branch topic at %s to git@%s:acme/app.git (9 commits it lacks)\n' "$t" "$GH" > "$d/plan-other"
  eq "$(kit_phase "$P" "$d" run "$d/plan-other" --branch topic --head "$t" --repo acme/app):$(remote_tip "$d" topic)" "3:" "[S] a run phase whose push line is not in the signed plan: refused, nothing pushed"
  d=$(setup acme/app); t=$(topic "$d"); bt "$P" "$d" rehearse $K --branch topic --head "$t" --repo acme/app >/dev/null
  sed -n 's/^  PLAN //p' "$BT_OUT" > "$d/plan"; : > "$d/race"
  ne "$(kit_phase "$P" "$d" run "$d/plan" --branch topic --head "$t" --repo acme/app)" 0 "[S] a branch that appears just before the push: the push fails"
  eq "$(remote_tip "$d" topic)" "$(git_ -C "$d/bare.git" rev-parse main)" "[S] …and the branch that appeared is not moved (create-only)"
}

FAMILIES="fam_push fam_steer fam_refuse fam_undo fam_signed"
for f in $FAMILIES; do echo "-- $f"; "$f" "$PLUGIN"; done

echo "== planted breaks: each family must go red on a plugin copy with one break in the kit =="
KBRK() {  # KBRK <label> <family> <needle> <old> <new>
  local label=$1 fam=$2 needle=$3 d; d="$TMP/break-$label"; mk_plugin_copy "$d"
  mutate "$d/batons/branch-push.sh" "$4" "$5" && expect_red "$label" "$fam" "$d" "$needle"
}
KBRK public-allowed fam_refuse '[R] a public repository: rehearse rc 1' '  if [ "$vis" != "true private" ]; then' '  if false; then'
KBRK any-remote fam_refuse '[R] a remote that names another repository' '  if [ -z "$named" ] || [ "$named" != "$want" ]; then' '  if [ -z "$named" ]; then'
KBRK any-host fam_refuse '[R] a remote that is not github.com' '  if [ -z "$named" ] || [ "$named" != "$want" ]; then' '  if [ "$named" != "$want" ] && [ -n "$named" ]; then'
KBRK tip-unchecked fam_refuse '[R] a local branch that is not at --head' '  if [ "$local_tip" != "$TIP" ]; then' '  if false; then'
KBRK remote-branch-unchecked fam_refuse '[R] a branch the remote already has' '  if [ -n "$(remote_sha "$all")" ]; then' '  if false; then'
KBRK workflow-allowed fam_refuse '[R] a new commit that changes .github/workflows/x.yml' '  if [ -n "$wf" ]; then' '  if false; then'
KBRK workflow-case-sensitive fam_refuse '[R] a new commit that changes .GitHub/Workflows/x.yml' "    case \"\$(printf '%s' \"\$path\" | tr '[:upper:]' '[:lower:]')\" in" '    case "$path" in'
KBRK quoted-paths fam_refuse '[R] a new commit that changes .github/workflows/é.yml' 'sgit log -z --diff-merges=separate --no-renames --format= --name-only' 'sgit log --diff-merges=separate --no-renames --format= --name-only'
KBRK git-names-allowed fam_refuse '[R] a branch named FETCH_HEAD' '|| [[ "$BR" =~ ^(HEAD|[A-Z_]+_HEAD|AUTO_MERGE|BISECT_EXPECTED_REV)$ ]]' '|| [[ "$BR" =~ ^(HEAD)$ ]]'
KBRK namespace-allowed fam_refuse '[R] a branch named heads/x' '  || [ "$FIRST" = refs ] || [ "$FIRST" = heads ] || [ "$FIRST" = tags ] || [ "$FIRST" = remotes ]' '  || [ "$FIRST" = refs ]'
KBRK read-failure-open fam_refuse '[R] …refused as a remote that cannot be read' '  if ! all=$(heads); then
    echo "REFUSE cannot read' '  if ! all=$(heads || true); then
    echo "REFUSE cannot read'
KBRK tracking-refs-trusted fam_refuse '[R] a workflow change hidden behind a local tracking ref' '  done <<< "$all"
  # every path' '  done < <(printf "%s\n" "$all"; git for-each-ref --format="%(objectname) x" refs/remotes/)
  # every path'
KBRK clone-config-used fam_steer '[G] …the push lands in acme/app, nothing in acme/pub' '  sgit push -q --force-with-lease="refs/heads/$BR:" "$PUSH_URL" "$TIP:refs/heads/$BR"' '  sgit push -q --force-with-lease="refs/heads/$BR:" "$PUSH_URL" "$TIP:refs/heads/$BR"; git push -q --force-with-lease="refs/heads/$BR:" "$REMOTE" "$TIP:refs/heads/$BR" || true'
KBRK env-passed fam_steer '[G] env-config (a pushInsteadOf toward acme/pub)' '  env -i ${keep[@]+"${keep[@]}"} GIT_CONFIG_NOSYSTEM=1' '  env ${keep[@]+"${keep[@]}"} GIT_CONFIG_NOSYSTEM=1'
KBRK merges-undiffed fam_refuse '[R] a workflow change made inside a merge' ' log -z --diff-merges=separate ' ' log -z '
KBRK walk-fails-open fam_refuse '[R] a commit walk that fails' '  if ! walk=$(sgit log -z --diff-merges=separate --no-renames --format= --name-only "$TIP" ${known[@]+--not "${known[@]}"} | tr '"'"'\0'"'"' '"'"'\n'"'"'); then' '  if ! walk=$(sgit log -z --diff-merges=separate --no-renames --format= --name-only "$TIP" ${known[@]+--not "${known[@]}"} | tr '"'"'\0'"'"' '"'"'\n'"'"' || true); then'
KBRK clone-programs-run fam_steer "[G] …none of the clone's programs ran" '  cleanenv git -c core.hooksPath=/dev/null' '  cleanenv git -c core.hooksPath="$(git rev-parse --path-format=absolute --git-common-dir)/hooks" -c core.sshCommand="$(git config core.sshCommand)"'
KBRK push-unsigned fam_signed '[S] a run phase whose push line is not in the signed plan' '  if [ -z "${BATON_PLAN:-}" ] || ! grep -Fqx -- "$PLANLINE" "$BATON_PLAN"; then' '  if false; then'
KBRK push-not-create-only fam_signed '[S] …and the branch that appeared is not moved' '  sgit push -q --force-with-lease="refs/heads/$BR:" "$PUSH_URL" "$TIP:refs/heads/$BR"' '  sgit push -q "$PUSH_URL" "$TIP:refs/heads/$BR"'
KBRK undo-silent fam_undo '[U] a push that landed and a post-check that fails' '  echo "LEAVE branch $BR at $now on $PUSH_URL: deleting a branch is an act the owner signs (irreversible-delete)" >&2
  return 1' '  return 0'
KBRK undo-blind fam_undo "[U] an undo that cannot read the remote" '  if ! all=$(heads); then
    echo "LEAVE' '  if ! all=$(heads || true); then
    echo "LEAVE'
QN=0; okdef=$(declare -f ok); baddef=$(declare -f bad); sp=$PASS; sf=$FAIL
ok() { :; }; bad() { QN=$((QN+1)); }
PLC="$TMP/break-none"; mk_plugin_copy "$PLC"
for f in $FAMILIES; do "$f" "$PLC" >/dev/null 2>&1; done
eval "$okdef"; eval "$baddef"; PASS=$sp; FAIL=$sf
eq "$QN" 0 "control: an unbroken copy passes every family (no failed check)"

echo "== nothing written outside the scratch tree =="
eq "$(tree_hash "$SRC_ROOT")" "$H0" "the repository tree is unchanged by the suite"

echo; summary
