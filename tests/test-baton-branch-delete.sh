#!/bin/bash
# =============================================================================
# The kit baton kit:branch-delete (batons/branch-delete.sh) and its delete gate (gates/branch_delete.py), through baton.py
# =============================================================================
# Run: bash tests/test-baton-branch-delete.sh
#
# Offline: real git, a clone whose origin URL is the ssh form for github.com/<owner/name>, and GIT_SSH_COMMAND set to a fake ssh
# (written below) that runs git's upload-pack or receive-pack on a local bare repository under the case directory. A fake `gh`
# (tests/fixtures/branch_delete_gh.py) answers the repository, protection, open pull requests, the compare API (computed by git
# on the same bare repository) and the API's ref create. The bare repository's main holds a merged branch `done` (an ancestor of
# main), an unmerged branch `topic`, and a branch `release` that holds `done` too. Every call pins the branch's head:
# `repo=<owner/name> branch=<name> head=<sha>`.
#   [P] the call: check ok; Params repo, branch and head and no Usage; the old flag form, a missing or short head: rc 64
#   [D] go: rehearse plans the delete (branch, SHA, default branch, its SHA, URL) and deletes nothing; the run deletes the
#       merged branch and the post-check sees it gone; every gh call names github.com
#   [R] refusals at rehearse, nothing deleted: an unmerged branch, a SHA held only by another branch, a tip moved off the pinned
#       head, the default branch, a protected branch, a ruleset that forbids its deletion, a name that is also a tag, an open
#       pull request from it or into it (by the owner GitHub reports, after a rename too), a missing branch or default branch,
#       a public or internal repository, a remote that names another repository, a remote that cannot be read, a compare or
#       pull list that cannot be read, names baton or the kit itself does not take
#   [S] at the delete: a plan line not in the signed plan deletes nothing; a force-push between sign and run is refused; a tip
#       moved before the run phase's read is refused by the kit; a branch moved just before the push is not deleted (the lease)
#       and its undo is clean (rc 4, nothing put back); a branch someone else deletes just before the push, or a delete whose
#       answer is lost, is an unknown outcome left for the owner (rc 5, not put back, the base holding the SHA); a base forced
#       back past the SHA just before the push, or after a lost answer: undo puts the branch back (rc 4)
#   [G] the delete gate run directly: a plan line not in the signed plan, or one naming another branch, head or URL: rc 3,
#       nothing pushed; a URL, head, branch, missing argument or plan line holding a newline: rc 64; the https URL of the repository is
#       taken; a branch moved before the push: rc 1 (the lease); the signed line at the head: rc 0, deleted
#   [L] the kit's text holds no hand-written delete: with every sgit call spelled git it still passes check (control: a push
#       delete put back fails it)
#   [U] undo: a delete followed by a failing post-check puts the branch back at its pinned SHA; with no run record, or another
#       run's record, nothing is put back; with no signed plan it is left (rc 1); a branch there again at another SHA, after a
#       delete or an unknown outcome, is named and left (the run ends rc 5)
#   [K] the scratch-repository and environment blocks are byte for byte kit:branch-push's, and the gate's git settings and
#       environment are the kit's
#   [X] planted breaks: each guard goes red on a plugin copy with that guard broken in the kit or the gate
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
printf '[user]\n\tname = t\n\temail = t\n' > "$GIT_CONFIG_GLOBAL"
H0=$(tree_hash "$SRC_ROOT")
FB="$TMP/fakebin"; mkdir -p "$FB"
printf '#!/bin/sh\nexec python3 -B "%s" "$@"\n' "$HERE/fixtures/branch_delete_gh.py" > "$FB/gh"; chmod +x "$FB/gh"
# the fake ssh: `fakessh <root> <options> <host> "git-upload-pack '<owner/name>.git'"` runs that pack command on
# <root>/<owner/name>.git; <root>/down makes it fail; before a receive-pack, <root>/race moves refs/heads/done to its parent (a
# branch that moves just before the delete), <root>/vanish deletes it (someone else deletes it), <root>/race-base forces main
# back to main~2 (a base that no longer holds done), <root>/race-pull moves refs/pull/7/head to main (a squash proof that no
# longer holds), <root>/race-pr marks PR #7 unmerged in the fake gh's world, <root>/lost deletes the branch its content names (done when empty) then drops the connection (an answer lost)
cat > "$FB/fakessh" <<'EOF'
#!/usr/bin/env bash
FAKE_SSH_ROOT=$1; shift
while [ $# -gt 1 ]; do shift; done
cmd=${1%% *}; repo=${1#* }; repo=${repo//\'/}; repo=${repo#/}
[ ! -e "$FAKE_SSH_ROOT/down" ] || { echo "fakessh: connection refused" >&2; exit 255; }
if [ "$cmd" = git-receive-pack ] && [ -e "$FAKE_SSH_ROOT/race" ]; then
  git --git-dir="$FAKE_SSH_ROOT/$repo" update-ref refs/heads/done refs/heads/done~1
fi
if [ "$cmd" = git-receive-pack ] && [ -e "$FAKE_SSH_ROOT/vanish" ]; then
  git --git-dir="$FAKE_SSH_ROOT/$repo" update-ref -d refs/heads/done
fi
if [ "$cmd" = git-receive-pack ] && [ -e "$FAKE_SSH_ROOT/race-base" ]; then
  git --git-dir="$FAKE_SSH_ROOT/$repo" update-ref refs/heads/main refs/heads/main~2
fi
if [ "$cmd" = git-receive-pack ] && [ -e "$FAKE_SSH_ROOT/race-pull" ]; then
  git --git-dir="$FAKE_SSH_ROOT/$repo" update-ref refs/pull/7/head refs/heads/main
fi
if [ "$cmd" = git-receive-pack ] && [ -e "$FAKE_SSH_ROOT/race-pr" ]; then
  python3 -c 'import json, sys; W = json.load(open(sys.argv[1])); W["repos"]["acme/app"]["pulls"][0]["merged"] = False; json.dump(W, open(sys.argv[1], "w"))' "$FAKE_SSH_ROOT/gh.json"
fi
if [ "$cmd" = git-receive-pack ] && [ -e "$FAKE_SSH_ROOT/lost" ]; then
  b=$(cat "$FAKE_SSH_ROOT/lost"); git --git-dir="$FAKE_SSH_ROOT/$repo" update-ref -d "refs/heads/${b:-done}"
  echo "fakessh: connection reset" >&2; exit 255
fi
exec git "${cmd#git-}" "$FAKE_SSH_ROOT/$repo"
EOF
chmod +x "$FB/fakessh"
PATH="$FB:$PATH"; export PATH
GH=github.com
BT_OUT="$TMP/bt.out"; ST=""

# setup <owner/name> — a case directory (printed): a bare repository for github.com/<owner/name> with main (three commits),
# done (main~1: merged), release (main: holds done) and topic (one commit off main: not merged); a clone whose origin URL is the
# ssh form for that repository; the fake gh's world (acme/app private, acme/pub public, acme/int internal, acme/other private)
setup() {
  local d repo=$1 r
  d=$(fresh)
  mkdir -p "$d/$(dirname "$repo")"
  git_ init -q --bare -b main "$d/$repo.git"; ln -s "$d/$repo.git" "$d/bare.git"
  git_ init -q -b main "$d/seed"
  for r in one two three; do printf '%s\n' "$r" > "$d/seed/$r.md"; git_ -C "$d/seed" add -A; git_ -C "$d/seed" commit -q -m "$r"; done
  git_ -C "$d/seed" push -q "$d/bare.git" main main~1:refs/heads/done main:refs/heads/release
  git_ -C "$d/seed" checkout -q -b topic; printf 't\n' > "$d/seed/t.md"; git_ -C "$d/seed" add -A; git_ -C "$d/seed" commit -q -m topic
  git_ -C "$d/seed" push -q "$d/bare.git" topic
  git_ clone -q "$d/bare.git" "$d/clone"
  git_ -C "$d/clone" remote set-url origin "git@$GH:$repo.git"
  python3 - "$d/gh.json" "$d" <<'PY'
import json, sys
d = sys.argv[2]
def r(name, private, vis):
    return {"private": private, "visibility": vis, "default_branch": "main", "git_dir": "%s/%s.git" % (d, name),
            "protected": [], "pulls": []}
json.dump({"repos": {"acme/app": r("acme/app", True, "private"), "acme/pub": r("acme/pub", False, "public"),
                     "acme/int": r("acme/int", True, "internal"), "acme/other": r("acme/other", True, "private")}},
          open(sys.argv[1], "w"))
PY
  printf '%s' "$d"
}
# world <case dir> <python statement on W> — edit the fake gh's world
world() { python3 - "$1/gh.json" "$2" <<'PY'
import json, sys
W = json.load(open(sys.argv[1])); A = W["repos"]["acme/app"]
exec(sys.argv[2])
json.dump(W, open(sys.argv[1], "w"))
PY
}
tip() { git_ -C "$1/bare.git" rev-parse --verify -q "refs/heads/$2" || true; }
# bt <plugin> <case dir> <baton args...> — rc of baton run from the clone with the state in $ST; its output is in $BT_OUT
bt() { local p=$1 d=$2; shift 2; [ $# -eq 2 ] && [ "$1" = mode ] && { baton_set_mode "$ST" "$2"; echo 0; return; }; ( cd "$d/clone" && XDG_STATE_HOME="$ST" GIT_SSH_COMMAND="$FB/fakessh $d" FAKE_LOG="$d/fake.log" FAKE_GH_WORLD="$d/gh.json" python3 "$p/scripts/baton.py" "$@" ) > "$BT_OUT" 2>&1; echo $?; }
# kit_phase <plugin> <case dir> <phase> <signed plan file> <repo> <branch> <head> — the kit's own phase, run directly with its
# values as baton passes them (positional, in the declared order); rc, output in $BT_OUT
kit_phase() {
  local p=$1 d=$2 ph=$3 plan=$4; shift 4
  ( cd "$d/clone" && XDG_STATE_HOME="$ST" GIT_SSH_COMMAND="$FB/fakessh $d" FAKE_LOG="$d/fake.log" FAKE_GH_WORLD="$d/gh.json" BATON_PHASE="$ph" BATON_PLAN="$plan" \
      BATON_PLUGIN_ROOT="$p" bash "$p/batons/branch-delete.sh" "$@" ) > "$BT_OUT" 2>&1; echo $?
}
# kit_two <plugin> <case dir> <run plan> <undo plan> <between> <repo> <branch> <head> — the kit's run phase, then the function
# <between> on the case dir (`:` for none), then its undo, from one process as baton runs them (the run record is keyed by that
# parent); prints "<run rc>/<undo rc>", the undo's output in $BT_OUT
kit_two() {
  local p=$1 d=$2 rp=$3 up=$4 between=$5; shift 5
  ( cd "$d/clone" || exit 99
    export XDG_STATE_HOME="$ST" GIT_SSH_COMMAND="$FB/fakessh $d" FAKE_LOG="$d/fake.log" FAKE_GH_WORLD="$d/gh.json" BATON_PLUGIN_ROOT="$p"
    BATON_PHASE=run BATON_PLAN="$rp" bash "$p/batons/branch-delete.sh" "$@" > /dev/null 2>&1; r=$?
    "$between" "$d"
    BATON_PHASE=undo BATON_PLAN="$up" bash "$p/batons/branch-delete.sh" "$@" > "$BT_OUT" 2>&1; printf '%s/%s' "$r" "$?" )
}
regrow() { git_ -C "$1/bare.git" update-ref refs/heads/done refs/heads/main; }    # someone pushes done again, at main
# gate <plugin> <case dir> <gate args...> — the delete gate run directly, as the kit runs it; rc, output in $BT_OUT
gate() {
  local p=$1 d=$2; shift 2
  ( cd "$d/clone" && GIT_SSH_COMMAND="$FB/fakessh $d" FAKE_LOG="$d/fake.log" FAKE_GH_WORLD="$d/gh.json" python3 -I -B "$p/gates/branch_delete.py" "$@" ) > "$BT_OUT" 2>&1; echo $?
}
sg() {
  local p=$1 d=$2 seal; shift 2
  bt "$p" "$d" mode auto >/dev/null
  seal=$( ( cd "$d/clone" && XDG_STATE_HOME="$ST" GIT_SSH_COMMAND="$FB/fakessh $d" FAKE_LOG="$d/fake.log" FAKE_GH_WORLD="$d/gh.json" python3 "$p/scripts/baton.py" rehearse "$@" ) 2>/dev/null \
          | sed -n 's/^seal \([^ ]*\) .*/\1/p')
  bt "$p" "$d" sign --by coordinator-auto --seal "${seal:-none}" "$@"
}
K=kit:branch-delete

fam_call() {
  local P=$1 d s
  ST="$(fresh)/state"; d=$(setup acme/app); s=$(tip "$d" done)
  eq "$(bt "$P" "$d" check $K)" 0 "[P] check kit:branch-delete: rc 0"
  has "$(cat "$BT_OUT")" "check ok" "[P] …check ok"
  eq "$(grep -cx '# Params: repo=repo branch=ref head=sha40' "$P/batons/branch-delete.sh")/$(grep -c '^# Usage:' "$P/batons/branch-delete.sh")" "1/0" \
    "[P] the header declares Params repo, branch and head, and no Usage"
  eq "$(bt "$P" "$d" rehearse $K --repo acme/app --branch done)" 64 "[P] the old flag form: rc 64 (a word that is not key=value)"
  eq "$(bt "$P" "$d" rehearse $K repo=acme/app branch=done)" 64 "[P] no head: rc 64"
  eq "$(bt "$P" "$d" rehearse $K repo=acme/app branch=done "head=${s:0:12}")" 64 "[P] a short head: rc 64"
  eq "$(bt "$P" "$d" rehearse $K repo=acme/app branch=done "head=$(printf '%s' "$s" | tr a-f A-F)")" 64 "[P] an upper-case head: rc 64"
  eq "$(tip "$d" done)" "$s" "[P] …nothing deleted by any of them"
}

fam_delete() {
  local P=$1 d s m
  ST="$(fresh)/state"; d=$(setup acme/app); s=$(tip "$d" done); m=$(tip "$d" main)
  eq "$(bt "$P" "$d" rehearse $K repo=acme/app branch=done "head=$s")" 0 "[D] rehearse a merged branch at its pinned head: rc 0"
  has "$(cat "$BT_OUT")" "PLAN delete merged branch done at $s (merged into main at $m, ancestor) on git@$GH:acme/app.git" "[D] …the plan names the branch, its SHA, the default branch, its SHA and the URL"
  eq "$(tip "$d" done)" "$s" "[D] …rehearse deleted nothing"
  eq "$(sg "$P" "$d" $K repo=acme/app branch=done "head=$s")/$(bt "$P" "$d" run $K repo=acme/app branch=done "head=$s")" "0/0" "[D] sign and run: rc 0"
  eq "$(tip "$d" done):$(tip "$d" main)" ":$m" "[D] …the branch is gone, main untouched"
  ST="$(fresh)/state"; d=$(setup acme/app); s=$(tip "$d" done)
  eq "$(bt "$P" "$d" mode auto >/dev/null; bt "$P" "$d" go $K repo=acme/app branch=done "head=$s")" 0 "[D] go: rc 0"
  has "$(cat "$BT_OUT")" "go: ok — 1 write" "[D] …one write"
  eq "$(tip "$d" done)" "" "[D] …the branch is gone"
  eq "$(grep '^gh ' "$d/fake.log" | grep -vc -- '--hostname github.com')" 0 "[D] …every gh call names --hostname github.com"
  eq "$(find "$ST" -name 'kit-branch-delete-*.last' | wc -l | tr -d ' ')" 0 "[D] …and a passing post-check drops the run record"
}

fam_refuse() {
  local P=$1 d b s
  ST="$(fresh)/state"
  d=$(setup acme/app); s=$(tip "$d" done)
  eq "$(bt "$P" "$d" rehearse $K repo=acme/app branch=topic "head=$(tip "$d" topic)")" 1 "[R] an unmerged branch: rehearse rc 1"
  has "$(cat "$BT_OUT")" "REFUSE branch topic at $(tip "$d" topic) is not merged into main" "[R] …refused by name, with the commits only on it"
  # done is at main~1; the call pins main~2, merged too: only the tip check stops it
  eq "$(bt "$P" "$d" rehearse $K repo=acme/app branch=done "head=$(git_ -C "$d/bare.git" rev-parse main~2)")" 1 "[R] a tip moved off the pinned head (the pinned SHA merged too): rehearse rc 1"
  has "$(cat "$BT_OUT")" "REFUSE branch done is at $s on git@$GH:acme/app.git, not at the pinned head" "[R] …refused by name"
  eq "$(bt "$P" "$d" rehearse $K repo=acme/app branch=main "head=$(tip "$d" main)")" 1 "[R] the default branch: rehearse rc 1"
  has "$(cat "$BT_OUT")" "REFUSE main is the default branch" "[R] …refused by name"
  world "$d" 'A["default_branch"] = "release"'               # release (at main) a default branch that is not main
  eq "$(bt "$P" "$d" rehearse $K repo=acme/app branch=release "head=$(tip "$d" release)")" 1 "[R] the default branch when it is not main: rehearse rc 1"
  world "$d" 'A["default_branch"] = "nope"'
  eq "$(bt "$P" "$d" rehearse $K repo=acme/app branch=done "head=$s")" 1 "[R] a default branch the remote does not have: rehearse rc 1"
  world "$d" 'A["default_branch"] = "main"; A["rules"] = {"done": ["deletion"]}'
  eq "$(bt "$P" "$d" rehearse $K repo=acme/app branch=done "head=$s")" 1 "[R] a ruleset that forbids deleting the branch: rehearse rc 1"
  has "$(cat "$BT_OUT")" "REFUSE a ruleset forbids deleting done" "[R] …refused by name"
  world "$d" 'A["rules"] = {}; W["faults"] = {"rules_fails_silent": True}'
  eq "$(bt "$P" "$d" rehearse $K repo=acme/app branch=done "head=$s")" 1 "[R] a ruleset read that fails with no output: rehearse rc 1, not a pass"
  has "$(cat "$BT_OUT")" "REFUSE a ruleset forbids deleting done, or the rules cannot be read (unreadable: no answer)" "[R] …refused as unreadable"
  world "$d" 'W["faults"] = {}; A["owner"] = "acme-new"; A["pulls"] = [{"head": "acme-new:done", "base": "main"}]'
  eq "$(bt "$P" "$d" rehearse $K repo=acme/app branch=done "head=$s")" 1 "[R] an open pull request from the branch, the owner renamed (GitHub reports acme-new): rehearse rc 1"
  world "$d" 'A.pop("owner"); A["pulls"] = []; A["protected"] = ["done"]'
  eq "$(bt "$P" "$d" rehearse $K repo=acme/app branch=done "head=$s")" 1 "[R] a protected branch: rehearse rc 1"
  has "$(cat "$BT_OUT")" "REFUSE branch done is protected" "[R] …refused by name"
  world "$d" 'A["protected"] = []; A["pulls"] = [{"head": "acme:done", "base": "main"}]'
  eq "$(bt "$P" "$d" rehearse $K repo=acme/app branch=done "head=$s")" 1 "[R] an open pull request from the branch: rehearse rc 1"
  has "$(cat "$BT_OUT")" "REFUSE an open pull request has done as its head" "[R] …refused by name"
  world "$d" 'A["pulls"] = [{"head": "acme:topic", "base": "done"}]'
  eq "$(bt "$P" "$d" rehearse $K repo=acme/app branch=done "head=$s")" 1 "[R] an open pull request into the branch: rehearse rc 1"
  has "$(cat "$BT_OUT")" "REFUSE an open pull request has done as its base" "[R] …refused by name"
  world "$d" 'A["pulls"] = []; W["faults"] = {"pulls_fails": True}'
  eq "$(bt "$P" "$d" rehearse $K repo=acme/app branch=done "head=$s")" 1 "[R] a pull request list that cannot be read: rehearse rc 1, not a pass"
  world "$d" 'W["faults"] = {"compare_fails": True}'
  eq "$(bt "$P" "$d" rehearse $K repo=acme/app branch=done "head=$s")" 1 "[R] a compare that cannot be read: rehearse rc 1, not a pass"
  world "$d" 'W["faults"] = {}'
  git_ -C "$d/bare.git" tag done main~1
  eq "$(bt "$P" "$d" rehearse $K repo=acme/app branch=done "head=$s")" 1 "[R] a name that is also a tag: rehearse rc 1"
  has "$(cat "$BT_OUT")" "REFUSE git@$GH:acme/app.git has a tag done" "[R] …refused by name"
  git_ -C "$d/bare.git" tag -d done >/dev/null
  eq "$(bt "$P" "$d" rehearse $K repo=acme/app branch=gone "head=$s")" 1 "[R] a branch the remote does not have: rehearse rc 1"
  has "$(cat "$BT_OUT")" "REFUSE git@$GH:acme/app.git has no branch gone" "[R] …refused by name"
  : > "$d/down"
  eq "$(bt "$P" "$d" rehearse $K repo=acme/app branch=done "head=$s")" 1 "[R] a remote that cannot be read: rehearse rc 1"
  has "$(cat "$BT_OUT")" "REFUSE cannot read the refs of git@$GH:acme/app.git" "[R] …refused by name"
  rm -f "$d/down"
  eq "$(tip "$d" done)/$(tip "$d" main)/$(tip "$d" release)" "$s/$(tip "$d" main)/$(tip "$d" main)" "[R] …nothing deleted in any of them"
  # a SHA held only by another branch: release (protected, not the default branch) fast-forwarded to topic, side at topic
  d=$(setup acme/app)
  git_ -C "$d/bare.git" update-ref refs/heads/release refs/heads/topic; git_ -C "$d/bare.git" update-ref refs/heads/side refs/heads/topic
  world "$d" 'A["protected"] = ["release"]'
  eq "$(bt "$P" "$d" rehearse $K repo=acme/app branch=side "head=$(tip "$d" topic)")" 1 "[R] a SHA held only by another branch (release, protected), not by main: rehearse rc 1"
  has "$(cat "$BT_OUT")" "REFUSE branch side at $(tip "$d" topic) is not merged into main" "[R] …refused as not merged into the default branch"
  d=$(setup acme/pub)
  eq "$(bt "$P" "$d" rehearse $K repo=acme/pub branch=done "head=$(tip "$d" done)")" 1 "[R] a public repository: rehearse rc 1"
  has "$(cat "$BT_OUT")" "REFUSE acme/pub does not read private" "[R] …refused by name"
  d=$(setup acme/int)
  eq "$(bt "$P" "$d" rehearse $K repo=acme/int branch=done "head=$(tip "$d" done)")" 1 "[R] an internal repository: rehearse rc 1"
  d=$(setup acme/app); s=$(tip "$d" done); git_ clone -q --bare "$d/bare.git" "$d/acme/other.git"
  eq "$(bt "$P" "$d" rehearse $K repo=acme/other branch=done "head=$s")" 1 "[R] a remote that names another repository than repo: rehearse rc 1"
  has "$(cat "$BT_OUT")" "REFUSE remote origin is git@$GH:acme/app.git" "[R] …refused by name"
  # each name exists on the remote as a merged branch (main~1): baton's ref type refuses it at the call, and so does the kit
  for b in HEAD FETCH_HEAD heads/done tags/v1 remotes/x refs/heads/done "$(printf 'a%.0s' $(seq 40))" 'do#ne'; do
    git_ -C "$d/bare.git" update-ref "refs/heads/$b" refs/heads/main~1
    eq "$(bt "$P" "$d" rehearse $K repo=acme/app "branch=$b" "head=$s")" 64 "[R] a branch named $b: baton refuses the call, rc 64"
    eq "$(kit_phase "$P" "$d" rehearse /dev/null acme/app "$b" "$s")" 64 "[R] the kit itself refuses a branch named $b: rc 64"
  done
  for b in 'a..b' '-x'; do
    eq "$(bt "$P" "$d" rehearse $K repo=acme/app "branch=$b" "head=$s")" 64 "[R] a branch named $b: baton refuses the call, rc 64"
    eq "$(kit_phase "$P" "$d" rehearse /dev/null acme/app "$b" "$s")" 64 "[R] the kit itself refuses a branch named $b: rc 64"
  done
  eq "$(git_ -C "$d/bare.git" for-each-ref --format=x refs/heads | grep -c x)" 12 "[R] …nothing deleted in any of them (main, done, release, topic and the eight names)"
}

fam_signed() {
  local P=$1 d s m
  ST="$(fresh)/state"; d=$(setup acme/app); s=$(tip "$d" done); m=$(tip "$d" main)
  printf 'delete merged branch done at %s (merged into main at %s, ancestor) on git@%s:acme/other.git\n' "$s" "$m" "$GH" > "$d/plan-other"
  eq "$(kit_phase "$P" "$d" run "$d/plan-other" acme/app done "$s"):$(tip "$d" done)" "3:$s" "[S] a run phase whose delete line is not in the signed plan: refused, nothing deleted"
  eq "$(sg "$P" "$d" $K repo=acme/app branch=done "head=$s")" 0 "[S] signed while done is at main~1"
  git_ -C "$d/bare.git" update-ref refs/heads/done refs/heads/main~2
  eq "$(bt "$P" "$d" run $K repo=acme/app branch=done "head=$s")" 3 "[S] a force-push between sign and run (to main~2, merged too): run refused"
  has "$(cat "$BT_OUT")" "not at the pinned head $s" "[S] …as a tip that moved off the pinned head"
  eq "$(tip "$d" done)" "$(tip "$d" main~2)" "[S] …and not deleted"
  d=$(setup acme/app); s=$(tip "$d" done); bt "$P" "$d" rehearse $K repo=acme/app branch=done "head=$s" >/dev/null
  sed -n 's/^  PLAN //p' "$BT_OUT" > "$d/plan"
  git_ -C "$d/bare.git" update-ref refs/heads/done refs/heads/topic
  eq "$(kit_phase "$P" "$d" run "$d/plan" acme/app done "$s")/$(tip "$d" done)" "3/$(tip "$d" topic)" "[S] the run phase itself reads a tip moved off the pinned head: refused, not deleted"
  has "$(cat "$BT_OUT")" "not at the pinned head $s" "[S] …refused by the kit before the gate"
  d=$(setup acme/app); s=$(tip "$d" done); bt "$P" "$d" rehearse $K repo=acme/app branch=done "head=$s" >/dev/null
  sed -n 's/^  PLAN //p' "$BT_OUT" > "$d/plan"; : > "$d/race"
  ne "$(kit_phase "$P" "$d" run "$d/plan" acme/app done "$s")" 0 "[S] a branch that moves just before the push: the delete fails"
  eq "$(tip "$d" done)" "$(git_ -C "$d/bare.git" rev-parse main~2)" "[S] …and the branch is not deleted (the lease)"
  ST="$(fresh)/state"; d=$(setup acme/app); s=$(tip "$d" done); : > "$d/race"
  eq "$(bt "$P" "$d" mode auto >/dev/null; bt "$P" "$d" go $K repo=acme/app branch=done "head=$s")/$(tip "$d" done)" "4/$(git_ -C "$d/bare.git" rev-parse main~2)" "[S] go, the branch moves just before the push: rc 4 (failed, undone), the moved branch left as it is"
  has "$(cat "$BT_OUT")" "this run's delete was refused: nothing to put back" "[S] …the undo says nothing was deleted (no false alarm)"
  ST="$(fresh)/state"; d=$(setup acme/app); s=$(tip "$d" done); : > "$d/vanish"
  eq "$(bt "$P" "$d" mode auto >/dev/null; bt "$P" "$d" go $K repo=acme/app branch=done "head=$s")/$(tip "$d" done)" "5/" "[S] go, someone else deletes the branch just before the push: rc 5 (left for the owner), not put back"
  has "$(cat "$BT_OUT")" "whether this run deleted it is unknown; its proof (ancestor) still keeps" "[S] …it says the outcome is unknown and that main still holds the SHA"
  ST="$(fresh)/state"; d=$(setup acme/app); s=$(tip "$d" done); : > "$d/lost"
  eq "$(bt "$P" "$d" mode auto >/dev/null; bt "$P" "$d" go $K repo=acme/app branch=done "head=$s")/$(tip "$d" done)" "5/" "[S] go, the delete lands but its answer is lost: rc 5, left for the owner (main holds the SHA)"
  ST="$(fresh)/state"; d=$(setup acme/app); s=$(tip "$d" done); : > "$d/lost"; : > "$d/race-base"
  eq "$(bt "$P" "$d" mode auto >/dev/null; bt "$P" "$d" go $K repo=acme/app branch=done "head=$s")/$(tip "$d" done)" "4/$s" "[S] go, the delete lands, its answer is lost and the base is forced back: undo puts the branch back (rc 4)"
  ST="$(fresh)/state"; d=$(setup acme/app); s=$(tip "$d" done); : > "$d/race-base"
  eq "$(bt "$P" "$d" mode auto >/dev/null; bt "$P" "$d" go $K repo=acme/app branch=done "head=$s")/$(tip "$d" done)" "4/$s" "[S] go, the base forced back past the SHA just before the push: the post-check fails, undo puts the branch back (rc 4)"
}

fam_gate() {
  local P=$1 d s m u line
  d=$(setup acme/app); s=$(tip "$d" done); m=$(tip "$d" main); u="git@$GH:acme/app.git"
  line="delete merged branch done at $s (merged into main at $m, ancestor) on $u"
  printf 'delete something else\n' > "$d/plan-none"; printf 'a line before\n%s\n' "$line" > "$d/plan"
  eq "$(gate "$P" "$d" --repo acme/app --branch done --head "$s" --url "$u" --plan "$line" --expect-plan "$d/plan-none"):$(tip "$d" done)" "3:$s" "[G] a plan line not in the signed plan: rc 3, nothing deleted"
  printf 'delete merged branch topic at %s (merged into main at %s, ancestor) on %s\n' "$s" "$m" "$u" > "$d/plan-bad"
  eq "$(gate "$P" "$d" --repo acme/app --branch done --head "$s" --url "$u" --plan "$(cat "$d/plan-bad")" --expect-plan "$d/plan-bad"):$(tip "$d" done)" "3:$s" "[G] a signed plan line naming another branch: rc 3, nothing deleted"
  printf 'delete merged branch done at %s (merged into main at %s, ancestor) on %s\n' "$m" "$m" "$u" > "$d/plan-bad"
  eq "$(gate "$P" "$d" --repo acme/app --branch done --head "$s" --url "$u" --plan "$(cat "$d/plan-bad")" --expect-plan "$d/plan-bad"):$(tip "$d" done)" "3:$s" "[G] a signed plan line naming another head: rc 3, nothing deleted"
  printf 'delete merged branch done at %s (merged into main at %s, ancestor) on git@%s:acme/other.git\n' "$s" "$m" "$GH" > "$d/plan-bad"
  eq "$(gate "$P" "$d" --repo acme/app --branch done --head "$s" --url "$u" --plan "$(cat "$d/plan-bad")" --expect-plan "$d/plan-bad"):$(tip "$d" done)" "3:$s" "[G] a signed plan line naming another URL: rc 3, nothing deleted"
  eq "$(gate "$P" "$d" --repo acme/app --branch done --head "$s" --url "https://example.com/acme/app.git" --plan "$line" --expect-plan "$d/plan")" 64 "[G] a URL that is not github.com/<repo>: rc 64"
  eq "$(gate "$P" "$d" --repo acme/app --branch done --head "$s" --url "git@$GH:acme/other.git" --plan "$line" --expect-plan "$d/plan")" 64 "[G] the URL of another repository: rc 64"
  eq "$(gate "$P" "$d" --repo acme/app --branch done --head "${s:0:12}" --url "$u" --plan "$line" --expect-plan "$d/plan")" 64 "[G] a short head: rc 64"
  eq "$(gate "$P" "$d" --repo acme/app --branch heads/done --head "$s" --url "$u" --plan "$line" --expect-plan "$d/plan")" 64 "[G] a branch name the kit does not take: rc 64"
  eq "$(gate "$P" "$d" --repo acme/app --branch done --head "$s" --url "$u" --plan "$line")" 64 "[G] no signed plan given: rc 64"
  eq "$(gate "$P" "$d" --repo acme/app --branch done --head "$s" --url "$u" --plan "$line"$'\n'"x" --expect-plan "$d/plan")" 64 "[G] a plan line holding a newline: rc 64"
  eq "$(gate "$P" "$d" --repo acme/app --branch done --head "$s" --url "https://$GH/acme/app.git" --plan "$line" --expect-plan "$d/plan")" 3 "[G] the https URL of the repository is taken (rc 3 from the plan check, not 64)"
  eq "$(tip "$d" done)" "$s" "[G] …nothing deleted by any of them"
  : > "$d/race"
  eq "$(gate "$P" "$d" --repo acme/app --branch done --head "$s" --url "$u" --plan "$line" --expect-plan "$d/plan")/$(tip "$d" done)" "1/$(tip "$d" main~2)" "[G] a branch moved just before the push: rc 1, the lease keeps it"
  rm -f "$d/race"; git_ -C "$d/bare.git" update-ref refs/heads/done "$s"
  eq "$(gate "$P" "$d" --repo acme/app --branch done --head "$s" --url "$u" --plan "$line" --expect-plan "$d/plan")/$(tip "$d" done)" "0/" "[G] the signed plan line, the branch at the head: rc 0, deleted"
}

# [L] baton's stop-hint lint reads git calls; the kit's own scratch-repository git is spelled sgit, so it is read again with every sgit
# call spelled git: the kit's text must hold no delete for it to find
fam_lint() {
  local P=$1 W C
  W=$(fresh); mkdir -p "$W/clone"
  C="$W/as-git"; cp -r "$P" "$C"; sed -i 's/\bsgit /git /g' "$C/batons/branch-delete.sh"
  eq "$(bt "$C" "$W" check $K)" 0 "[L] the kit with every sgit call spelled git passes check: no hand-written delete in its text"
  C="$W/control"; cp -r "$P" "$C"
  mutate "$C/batons/branch-delete.sh" '  record pushing' '  record pushing
  sgit push -q --force-with-lease="refs/heads/$BR:$SHA" "$PUSH_URL" ":refs/heads/$BR"'
  sed -i 's/\bsgit /git /g' "$C/batons/branch-delete.sh"
  eq "$(bt "$C" "$W" check $K)" 1 "[L] control: the same spelling with a push delete put back in the kit fails check"
  has "$(cat "$BT_OUT")" "irreversible-delete" "[L] …as irreversible-delete"
}

# failing_copy <plugin> <dir> — a copy of that plugin (a broken one included) whose kit post-check fails, so run undoes
# (with FAKE_MOVE_TO_MAIN set to a bare repository, it first puts the branch there at main: a ref someone else made)
failing_copy() { cp -r "$1" "$2"; mutate "$2/batons/branch-delete.sh" '
postcheck() {' '
postcheck() {
  if [ -n "${FAKE_MOVE_TO_MAIN:-}" ]; then
    git --git-dir="$FAKE_MOVE_TO_MAIN" update-ref "refs/heads/$BR" refs/heads/main
  fi
  return 1
'; }

fam_undo() {
  local P=$1 d s C
  C="$(fresh)/plugin"; failing_copy "$P" "$C"
  ST="$(fresh)/state"; d=$(setup acme/app); s=$(tip "$d" done)
  eq "$(sg "$C" "$d" $K repo=acme/app branch=done "head=$s")/$(bt "$C" "$d" run $K repo=acme/app branch=done "head=$s")" "0/4" "[U] a delete and a post-check that fails: run undone, rc 4"
  has "$(cat "$BT_OUT")" "DO recreate branch done at $s on git@$GH:acme/app.git" "[U] …the undo recreates the branch"
  eq "$(tip "$d" done)" "$s" "[U] …at the pinned SHA"
  eq "$(kit_phase "$P" "$d" undo /dev/null acme/app done "$s")" 0 "[U] an undo with no run record: rc 0"
  has "$(cat "$BT_OUT")" "this run never pushed a delete, nothing to put back" "[U] …and it says so"
  ST="$(fresh)/state"; d=$(setup acme/app); s=$(tip "$d" done)
  export FAKE_MOVE_TO_MAIN="$d/bare.git"        # the failing post-check puts done back at main first: someone else's ref
  eq "$(sg "$C" "$d" $K repo=acme/app branch=done "head=$s")/$(bt "$C" "$d" run $K repo=acme/app branch=done "head=$s")" "0/5" "[U] a branch there again at another SHA when undo runs: rc 5"
  unset FAKE_MOVE_TO_MAIN
  has "$(cat "$BT_OUT")" "LEAVE branch done is at $(tip "$d" main)" "[U] …and named"
  # the run record belongs to the signed plan of the run that wrote it
  d=$(setup acme/app); s=$(tip "$d" done); bt "$P" "$d" rehearse $K repo=acme/app branch=done "head=$s" >/dev/null
  sed -n 's/^  PLAN //p' "$BT_OUT" > "$d/plan"; printf 'delete merged branch done at %s (another run) on x\n' "$s" > "$d/plan-2"
  ST="$(fresh)/state"
  eq "$(kit_two "$P" "$d" "$d/plan" "$d/plan-2" : acme/app done "$s")" "0/0" "[U] an undo whose signed plan is another run's: rc 0"
  has "$(cat "$BT_OUT")" "is an earlier run's: nothing of this run to put back" "[U] …it says the record is another run's"
  eq "$(tip "$d" done)" "" "[U] …and the branch is not put back for another run"
  d=$(setup acme/app); s=$(tip "$d" done); bt "$P" "$d" rehearse $K repo=acme/app branch=done "head=$s" >/dev/null
  sed -n 's/^  PLAN //p' "$BT_OUT" > "$d/plan"; ST="$(fresh)/state"
  eq "$(kit_two "$P" "$d" "$d/plan" "" : acme/app done "$s")" "0/1" "[U] an undo with no signed plan: rc 1, left"
  has "$(cat "$BT_OUT")" "LEAVE no signed plan" "[U] …it says it cannot tell whose record it is"
  # an unknown outcome (the answer lost, the branch gone), then someone pushes done again at main before undo runs
  d=$(setup acme/app); s=$(tip "$d" done); bt "$P" "$d" rehearse $K repo=acme/app branch=done "head=$s" >/dev/null
  sed -n 's/^  PLAN //p' "$BT_OUT" > "$d/plan"; ST="$(fresh)/state"; : > "$d/lost"
  eq "$(kit_two "$P" "$d" "$d/plan" "$d/plan" regrow acme/app done "$s")" "3/1" "[U] an unknown outcome, the branch there again at another SHA: undo rc 1, left"
  has "$(cat "$BT_OUT")" "LEAVE branch done is at $(tip "$d" main)" "[U] …named, not called a delete that did not land"
  eq "$(tip "$d" done)" "$(tip "$d" main)" "[U] …the other ref left as it is"
}

# [K] the blocks both kits share must stay the same bytes: a hardening of one is a hardening of the other; and the delete gate
# pushes with the same git settings and environment as the kit's own scratch repository
fam_share() {
  local P=$1 out
  out=$(python3 - "$P/batons/branch-delete.sh" "$P/batons/branch-push.sh" <<'PY'
import re, sys
def blocks(p):
    t = open(p, encoding="utf-8").read()
    return {name: re.search(r"^%s\(\) \{\n.*?^\}\n" % name, t, re.S | re.M).group(0) for name in ("cleanenv", "sgit", "url_repo")}
a, b = blocks(sys.argv[1]), blocks(sys.argv[2])
print(" ".join(n for n in a if a[n] != b[n]) or "same")
PY
)
  eq "$out" same "[K] cleanenv(), sgit() and url_repo() are byte for byte kit:branch-push's"
  out=$(python3 - "$P/batons/branch-delete.sh" "$P/gates/branch_delete.py" <<'PY' 2>&1
import importlib.util, re, shlex, sys
t = open(sys.argv[1], encoding="utf-8").read()
def body(name):
    return re.search(r"^%s\(\) \{\n(.*?)^\}\n" % name, t, re.S | re.M).group(1).replace("\\\n", " ")
w = shlex.split(body("sgit"))
cfg = [w[i + 1] for i in range(len(w) - 1) if w[i] == "-c"]
ce = body("cleanenv")
keep = re.search(r"for v in (.*?); do", ce, re.S).group(1).split()
fixed = re.search(r'"\$\{keep\[@\]\}"\} (.*?) "\$@"', ce).group(1).split()
spec = importlib.util.spec_from_file_location("branch_delete_gate", sys.argv[2])
g = importlib.util.module_from_spec(spec)
spec.loader.exec_module(g)
diff = [n for n, a, b in (("config", list(g.GIT_CONFIG), cfg), ("env", list(g.ENV_KEEP), keep),
                          ("fixed", ["%s=%s" % kv for kv in g.ENV_FIXED], fixed)) if a != b]
print(" ".join(diff) or "same")
PY
)
  eq "$out" same "[K] the delete gate's git settings and environment are the kit's sgit() and cleanenv()"
}

# squash <case dir> — topic squash-merged into main as PR #7: a squash commit on main (printed), refs/pull/7/head at topic, and
# the PR in the fake gh's world (closed, merged, head acme:topic of acme/app at topic's SHA, base main, its merge commit)
squash() {
  local d=$1 t mc
  t=$(tip "$d" topic)
  git_ -C "$d/seed" checkout -q main; git_ -C "$d/seed" merge -q --squash topic >/dev/null; git_ -C "$d/seed" commit -q -m "topic (#7)"
  git_ -C "$d/seed" push -q "$d/bare.git" main; mc=$(git_ -C "$d/seed" rev-parse HEAD)
  git_ -C "$d/bare.git" update-ref refs/pull/7/head "$t"
  world "$d" "A['pulls'] = [{'number': 7, 'state': 'closed', 'merged': True, 'head': 'acme:topic', 'head_ref': 'topic', 'head_repo': 'acme/app', 'head_sha': '$t', 'base': 'main', 'merge_commit_sha': '$mc'}]"
  printf '%s' "$mc"
}
# pr <case dir> <python statement on P, the PR #7 record> — edit it
pr() { world "$1" "P = A['pulls'][0]; $2"; }
# rt <plugin> <case dir> — rehearse topic at its tip now; rc, output in $BT_OUT
rt() { bt "$1" "$2" rehearse $K repo=acme/app branch=topic "head=$(tip "$2" topic)"; }
# gt <plugin> <case dir> — go topic at its tip now; rc, output in $BT_OUT
gt() { local t; t=$(tip "$2" topic); bt "$1" "$2" mode auto >/dev/null; bt "$1" "$2" go $K repo=acme/app branch=topic "head=$t"; }

fam_squash() {
  local P=$1 d t m mc
  ST="$(fresh)/state"; d=$(setup acme/app); t=$(tip "$d" topic); mc=$(squash "$d"); m=$(tip "$d" main)
  eq "$(rt "$P" "$d")" 0 "[Q] rehearse a squash-merged branch: rc 0"
  has "$(cat "$BT_OUT")" "PLAN delete merged branch topic at $t (merged into main at $m, merged PR #7) on git@$GH:acme/app.git" "[Q] …the plan names the proof: merged PR #7"
  eq "$(gt "$P" "$d")/$(tip "$d" topic)" "0/" "[Q] go: the squash-merged branch is deleted"
  eq "$(git_ -C "$d/bare.git" rev-parse refs/pull/7/head)" "$t" "[Q] …its commits stay reachable at refs/pull/7/head"
  ST="$(fresh)/state"; d=$(setup acme/app); t=$(tip "$d" topic); mc=$(squash "$d")
  world "$d" "A['pulls'].append(dict(A['pulls'][0], number=12)); A['pulls'][0]['number'] = 15"
  git_ -C "$d/bare.git" update-ref refs/pull/12/head "$t"; git_ -C "$d/bare.git" update-ref refs/pull/15/head "$t"
  eq "$(rt "$P" "$d")" 0 "[Q] two merged PRs of the branch (#15, #12): rc 0"
  has "$(cat "$BT_OUT")" ", merged PR #12) on" "[Q] …the lowest number is the proof"
  d=$(setup acme/app); t=$(tip "$d" topic); mc=$(squash "$d")
  world "$d" "A['pulls'].append(dict(A['pulls'][0], number=15)); A['pulls'][0]['number'] = 12; A['pulls'][0]['merge_commit_sha'] = '$t'"
  git_ -C "$d/bare.git" update-ref refs/pull/12/head "$t"; git_ -C "$d/bare.git" update-ref refs/pull/15/head "$t"
  eq "$(rt "$P" "$d")" 0 "[Q] the lowest PR (#12) does not hold (its merge commit is not on main), #15 does: rc 0"
  has "$(cat "$BT_OUT")" ", merged PR #15) on" "[Q] …the next PR is the proof"
  d=$(setup acme/app); squash "$d" >/dev/null; pr "$d" 'P["base"] = "release"'
  eq "$(rt "$P" "$d")" 1 "[Q] a PR merged into another base: rehearse rc 1"
  has "$(cat "$BT_OUT")" "no merged pull request from this repository's topic at" "[Q] …refused by name"
  d=$(setup acme/app); squash "$d" >/dev/null; pr "$d" 'P["merged"] = False'
  eq "$(rt "$P" "$d")" 1 "[Q] a PR closed without merging: rehearse rc 1"
  d=$(setup acme/app); squash "$d" >/dev/null
  git_ -C "$d/seed" checkout -q topic; printf 'late\n' > "$d/seed/late.md"; git_ -C "$d/seed" add -A; git_ -C "$d/seed" commit -q -m late
  git_ -C "$d/seed" push -q "$d/bare.git" topic
  eq "$(rt "$P" "$d")" 1 "[Q] a branch pushed after its PR merged (head SHA differs): rehearse rc 1"
  d=$(setup acme/app); squash "$d" >/dev/null; pr "$d" 'P["head"] = "fork:topic"; P["head_repo"] = "fork/app"'
  eq "$(rt "$P" "$d")" 1 "[Q] a fork's PR: rehearse rc 1"
  d=$(setup acme/app); squash "$d" >/dev/null; pr "$d" 'P["head_repo"] = None'
  eq "$(rt "$P" "$d")" 1 "[Q] a PR whose head repository is gone (a deleted fork, head.repo null): rehearse rc 1"
  d=$(setup acme/app); squash "$d" >/dev/null; pr "$d" 'P["head_repo"] = "acme/app-copy"'
  eq "$(rt "$P" "$d")" 1 "[Q] a PR whose head is another repository of the owner: rehearse rc 1"
  d=$(setup acme/app); squash "$d" >/dev/null; git_ -C "$d/bare.git" update-ref -d refs/pull/7/head
  eq "$(rt "$P" "$d")" 1 "[Q] no refs/pull/7/head: rehearse rc 1"
  has "$(cat "$BT_OUT")" "refs/pull/7/head is not at" "[Q] …refused by name"
  d=$(setup acme/app); squash "$d" >/dev/null; git_ -C "$d/bare.git" update-ref refs/pull/7/head refs/heads/main
  eq "$(rt "$P" "$d")" 1 "[Q] refs/pull/7/head at another SHA: rehearse rc 1"
  d=$(setup acme/app); squash "$d" >/dev/null; pr "$d" "P['merge_commit_sha'] = '$(tip "$d" topic)'"
  eq "$(rt "$P" "$d")" 1 "[Q] a merge commit not on the base: rehearse rc 1"
  has "$(cat "$BT_OUT")" "of PR #7 is not on main at" "[Q] …refused by name"
  d=$(setup acme/app); squash "$d" >/dev/null; world "$d" 'W["faults"] = {"closed_pulls_fail": True}'
  eq "$(rt "$P" "$d")" 1 "[Q] a closed PR list that cannot be read: rehearse rc 1"
  eq "$(git_ -C "$d/bare.git" for-each-ref --format=x refs/heads/topic | grep -c x)" 1 "[Q] …nothing deleted"
  ST="$(fresh)/state"; d=$(setup acme/app); t=$(tip "$d" topic); squash "$d" >/dev/null; : > "$d/race-pull"
  eq "$(gt "$P" "$d")/$(tip "$d" topic)" "4/$t" "[Q] go, the pull ref moves just before the push: the post-check fails, undo puts the branch back (rc 4)"
  ST="$(fresh)/state"; d=$(setup acme/app); t=$(tip "$d" topic); squash "$d" >/dev/null; : > "$d/race-pr"
  eq "$(gt "$P" "$d")/$(tip "$d" topic)" "4/$t" "[Q] go, the PR no longer reads merged when the post-check runs: undo puts the branch back (rc 4)"
  ST="$(fresh)/state"; d=$(setup acme/app); squash "$d" >/dev/null; printf topic > "$d/lost"
  eq "$(gt "$P" "$d")/$(tip "$d" topic)" "5/" "[Q] go, a lost answer while the squash proof holds: rc 5, left for the owner"
  has "$(cat "$BT_OUT")" "its proof (merged PR #7) still keeps" "[Q] …it names the proof"
  ST="$(fresh)/state"; d=$(setup acme/app); t=$(tip "$d" topic); squash "$d" >/dev/null; printf topic > "$d/lost"; : > "$d/race-pull"
  eq "$(gt "$P" "$d")/$(tip "$d" topic)" "4/$t" "[Q] go, a lost answer and the pull ref moved: undo puts the branch back (rc 4)"
}

FAMILIES="fam_call fam_delete fam_refuse fam_signed fam_gate fam_lint fam_undo fam_squash fam_share"
for f in $FAMILIES; do echo "-- $f"; "$f" "$PLUGIN"; done

echo "== planted breaks: each family must go red on a plugin copy with one break in the kit or the gate =="
KBRK() {  # KBRK <label> <family> <needle> <old> <new> — a break in the kit
  local label=$1 fam=$2 needle=$3 d; d="$TMP/break-$label"; mk_plugin_copy "$d"
  mutate "$d/batons/branch-delete.sh" "$4" "$5" && expect_red "$label" "$fam" "$d" "$needle"
}
GBRK() {  # GBRK <label> <family> <needle> <old> <new> — a break in the delete gate
  local label=$1 fam=$2 needle=$3 d; d="$TMP/break-$label"; mk_plugin_copy "$d"
  mutate "$d/gates/branch_delete.py" "$4" "$5" && expect_red "$label" "$fam" "$d" "$needle"
}
KBRK unmerged-allowed fam_refuse '[R] an unmerged branch' '  if merged "$BASESHA" "$SHA"; then
    PROOF=ancestor' '  if true; then
    PROOF=ancestor'
KBRK compare-fails-open fam_refuse '[R] a compare that cannot be read' '  [[ "$CMP" =~ ^(behind|identical)\ 0$ ]]' '  ! [[ "$CMP" =~ ^(ahead|diverged) ]]'
KBRK default-allowed fam_refuse '[R] the default branch: rehearse' '  if [ "$BR" = "$DEFAULT" ]; then' '  if false; then'
KBRK base-not-default fam_refuse '[R] a SHA held only by another branch' '  BASE=$DEFAULT' '  BASE=release'
KBRK moved-tip-allowed fam_refuse '[R] a tip moved off the pinned head' '  if [ "$NOW" != "$SHA" ]; then' '  if false; then'
KBRK protected-allowed fam_refuse '[R] a protected branch' '  if [ "$prot" != false ]; then' '  if false; then'
KBRK ruleset-allowed fam_refuse '[R] a ruleset that forbids deleting the branch' '  if [ -n "$rules" ]; then' '  if false; then'
KBRK ruleset-fails-open fam_refuse '[R] a ruleset read that fails' '    || rules="unreadable: ${rules:-no answer}"' '    || rules=""'
KBRK tag-allowed fam_refuse '[R] a name that is also a tag' '  if [ -n "$(ref_sha "$all" "refs/tags/$BR")" ]; then' '  if false; then'
KBRK pull-head-allowed fam_refuse '[R] an open pull request from the branch: rehearse' '  for q in "head=$OWNER:$BR" "base=$BR"; do' '  for q in "base=$BR"; do'
KBRK pull-base-allowed fam_refuse '[R] an open pull request into the branch' '  for q in "head=$OWNER:$BR" "base=$BR"; do' '  for q in "head=$OWNER:$BR"; do'
KBRK owner-from-flag fam_refuse '[R] an open pull request from the branch, the owner renamed' '  read -r priv vis DEFAULT OWNER FULL _ <<< "$info"' '  read -r priv vis DEFAULT _ FULL _ <<< "$info"; OWNER=${REPO%%/*}'
KBRK pulls-fail-open fam_refuse '[R] a pull request list that cannot be read' '    if [ "$n" != 0 ]; then' '    if [ "$n" -gt 0 ] 2>/dev/null; then'
KBRK public-allowed fam_refuse '[R] a public repository' '  if [ "$priv $vis" != "true private" ] || ! branchname "$DEFAULT"' '  if ! branchname "$DEFAULT"'
KBRK any-remote fam_refuse '[R] a remote that names another repository' '  if [ -z "$named" ] || [ "$named" != "$want" ]; then' '  if [ -z "$named" ]; then'
KBRK names-allowed fam_refuse '[R] the kit itself refuses a branch named heads/done' '[ "$first" != refs ] && [ "$first" != heads ] \' '[ "$first" != refs ] && true \'
KBRK host-unpinned fam_delete '[D] …every gh call names --hostname github.com' '  CMP=$(gh api --hostname "$HOST" "repos/$REPO/compare/' '  CMP=$(gh api "repos/$REPO/compare/'
KBRK run-tip-unchecked fam_signed '[S] …refused by the kit before the gate' '  if [ "$NOW" != "$SHA" ]; then' '  if [ "$PHASE" != run ] && [ "$NOW" != "$SHA" ]; then'
KBRK refused-recorded-as-deleted fam_signed '[S] go, the branch moves just before the push' '        record refused
        echo "REFUSE the push was refused' '        record deleted
        echo "REFUSE the push was refused'
KBRK lost-answer-trusted fam_signed '[S] go, the delete lands, its answer is lost and the base is forced back' '        record unknown' '        record refused'
KBRK unknown-recreated-always fam_signed '[S] go, someone else deletes the branch just before the push: rc 5' '        if [ -n "$base" ] && held "$PROOF" "$base"; then' '        if false; then'
KBRK record-kept fam_delete '[D] …and a passing post-check drops the run record' '  rm -f -- "$RECORD"            #' '  : "$RECORD"            #'
KBRK kit-push-back fam_lint '[L] the kit with every sgit call spelled git passes check' '  record pushing' '  record pushing
  sgit push -q --force-with-lease="refs/heads/$BR:$SHA" "$PUSH_URL" ":refs/heads/$BR"'
KBRK squash-proof-off fam_squash '[Q] rehearse a squash-merged branch' '    if ! squash_pr; then' '    if true; then'
KBRK squash-repo-unchecked fam_squash '[Q] a PR whose head is another repository of the owner' '(.head.repo.full_name // \"\" | ascii_downcase) == \"$(printf' '\"x\" != \"$(printf'
KBRK squash-pullref-unchecked fam_squash '[Q] no refs/pull/7/head' '  if ! all=$(refs "refs/pull/$1/head") || [ "$(ref_sha "$all" "refs/pull/$1/head")" != "$SHA" ]; then' '  if false; then'
KBRK squash-merge-commit-unchecked fam_squash '[Q] a merge commit not on the base' '  if ! merged "$2" "$mc"; then' '  if false; then'
KBRK squash-no-fallback fam_squash '[Q] the lowest PR (#12) does not hold' '    if pr_holds "$n" "$BASESHA"; then' '    pr_holds "$n" "$BASESHA" || return 1
    if true; then'
KBRK pr-fields-unchecked fam_squash '[Q] go, the PR no longer reads merged' '  if [ "$merged" != true ] || [ "$head" != "$SHA" ] || [ "$base" != "$BASE" ] || ! [[ "$mc" =~ ^[0-9a-f]{40}$ ]]; then' '  if ! [[ "$mc" =~ ^[0-9a-f]{40}$ ]]; then'
KBRK squash-list-fails-open fam_squash '[Q] a closed PR list that cannot be read' '    SQ="the pull request list cannot be read (${list:-no answer})"
    return 1' '    SQ="the pull request list cannot be read (${list:-no answer})"; list="7 null"'
KBRK squash-lowest-not-chosen fam_squash '[Q] …the lowest number is the proof' '| sort -n); do' '| sort -rn); do'
KBRK squash-postcheck-unproven fam_squash '[Q] go, the pull ref moves just before the push' '    pr:*) pr_holds "${1#pr:}" "$2" ;;' '    pr:*) return 0 ;;'
KBRK postcheck-base-unchecked fam_signed '[S] go, the base forced back past the SHA' '  if [ -z "$SHA" ] || [ -z "$base" ] || ! held "$PROOF" "$base"; then' '  if false; then'
KBRK undo-silent fam_undo '[U] …the undo recreates the branch' '        write "recreate branch $BR at $SHA on $PUSH_URL" recreate' '        :'
KBRK undo-overwrites fam_undo '[U] …and named' '      elif [ -n "$now" ]; then
        echo "LEAVE branch $BR is at $now on $PUSH_URL, not the deleted' '      elif false; then
        echo "LEAVE branch $BR is at $now on $PUSH_URL, not the deleted'
KBRK share-drift fam_share '[K] cleanenv(), sgit() and url_repo()' '    -c log.showSignature=false -c credential.helper=' '    -c credential.helper='
KBRK undo-unrecorded fam_undo '[U] an undo with no run record' '  if [ ! -f "$RECORD" ]; then
    echo "no run record' '  if false; then
    echo "no run record'
KBRK undo-plan-unchecked fam_undo '[U] …and the branch is not put back for another run' '  if [ "$plan" != "$mine" ]; then' '  if false; then'
KBRK undo-unsigned-trusted fam_undo '[U] an undo with no signed plan' '  if [ -z "$mine" ]; then' '  if false; then'
KBRK unknown-other-sha-trusted fam_undo '[U] an unknown outcome, the branch there again at another SHA' '      if [ "$now" = "$SHA" ]; then
        echo "branch $BR is still at $now: the delete did not land' '      if [ -n "$now" ]; then
        echo "branch $BR is still at $now: the delete did not land'
GBRK gate-head-any fam_gate '[G] a short head' 'or not SHA.match(a.head) or' 'or False or'
GBRK gate-branch-any fam_gate '[G] a branch name the kit does not take' 'not branchname(a.branch)' 'False'
GBRK gate-newline-plan fam_gate '[G] a plan line holding a newline' 'or "\n" in a.plan or' 'or False or'
GBRK gate-plan-unchecked fam_gate '[G] a plan line not in the signed plan' '    if plan not in signed:' '    if False:'
GBRK gate-plan-unbound fam_gate '[G] a signed plan line naming another branch' '    if not m or m.group(1, 2, 3) != (a.branch, a.head, a.url):' '    if not m:'
GBRK gate-url-any fam_gate '[G] the URL of another repository' '    if a.url not in urls:' '    if False:'
GBRK gate-no-lease fam_signed '[S] …and the branch is not deleted (the lease)' '"--force-with-lease=refs/heads/%s:%s" % (a.branch, a.head)' '"--force"'
GBRK gate-share-drift fam_share "[K] the delete gate's git settings" '"log.showSignature=false", ' ''
QN=0; okdef=$(declare -f ok); baddef=$(declare -f bad); sp=$PASS; sf=$FAIL
ok() { :; }; bad() { QN=$((QN+1)); }
PLC="$TMP/break-none"; mk_plugin_copy "$PLC"
for f in $FAMILIES; do "$f" "$PLC" >/dev/null 2>&1; done
eval "$okdef"; eval "$baddef"; PASS=$sp; FAIL=$sf
eq "$QN" 0 "control: an unbroken copy passes every family (no failed check)"

echo "== nothing written outside the scratch tree =="
eq "$(tree_hash "$SRC_ROOT")" "$H0" "the repository tree is unchanged by the suite"

echo; summary
