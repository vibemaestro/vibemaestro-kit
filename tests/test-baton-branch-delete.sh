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
#   [B] clone=<path> and the batch: a directory with no origin refuses with the origin named as not set; clone= reads the origin
#       from the named clone (another repository's origin, none, or a relative path refuses); a batch of four merged branches
#       plans four lines in the order given and one signature deletes them; one unmerged branch refuses the whole batch at
#       rehearse and at run, wherever it stands, with no plan line and nothing deleted; a call of the wrong shape, 51 branches,
#       a branch twice: refused; the post-check and the undo take each branch (all put back; a failed second delete)
#   [K] the scratch-repository and environment blocks are byte for byte kit:branch-push's (in both delete kits), and the gate's
#       git settings and environment are the kit's
# kit:branch-delete-recoverable (Stops recoverable-delete), the same fakes, a clone given as clone=<path>:
#   [W] check: the kit passes; a session or project: baton declaring recoverable-delete is refused, the word named as kit-only;
#       a Stops: none baton naming the bundles directory is refused
#   [A] go in mode auto stops for the owner (exit 8); coordinator-auto cannot sign it; nothing deleted, no bundle
#   [C] [R] rehearse refuses a shallow clone, one missing an object of head, one using alternates, a partial one, a worktree, no
#       repository, and what kit:branch-delete refuses except "unmerged"; nothing deleted, no bundle
#   [D] [U] a run bundles an unmerged head into the state directory, then deletes it; with the clone deleted and the remote
#       pruned, undo pushes it back from the bundle; the lease, and a branch there again at another SHA, are left
#   [P] the bundle write keeps the newest 200 bundles of the kit's exact name shape and removes nothing else; a state directory
#       with a trailing / names the same bundle in the kit and the gate
#   [G] the delete gate's recoverable form: no bundle, a bundle of another head, one with a prerequisite, a symlink, or one
#       outside bundles/: rc 3, nothing pushed; a complete bundle of the head: deleted
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
# longer holds), <root>/move-main-at (a number N) adds a commit to main at the Nth read of the remote's refs, <root>/race-pr marks PR #7 unmerged in the fake gh's world, <root>/lost deletes the branch its content names (done when empty) then drops the connection (an answer lost)
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
if [ "$cmd" = git-upload-pack ] && [ -e "$FAKE_SSH_ROOT/move-main-at" ]; then
  n=$(( $(cat "$FAKE_SSH_ROOT/move-main-count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FAKE_SSH_ROOT/move-main-count"
  if [ "$n" = "$(cat "$FAKE_SSH_ROOT/move-main-at")" ]; then
    gd="$FAKE_SSH_ROOT/$repo"
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t
    git --git-dir="$gd" update-ref refs/heads/main "$(git --git-dir="$gd" commit-tree -p refs/heads/main -m moved 'refs/heads/main^{tree}')"
  fi
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
bt() { BT_CWD="$2/clone" bt_in "$@"; }
# bt_in <plugin> <case dir> <baton args...> — bt from the directory in $BT_CWD
bt_in() { local p=$1 d=$2; shift 2; [ $# -eq 2 ] && [ "$1" = mode ] && { baton_set_mode "$ST" "$2"; echo 0; return; }; ( cd "$BT_CWD" && XDG_STATE_HOME="$ST" GIT_SSH_COMMAND="$FB/fakessh $d" FAKE_LOG="$d/fake.log" FAKE_GH_WORLD="$d/gh.json" python3 "$p/scripts/baton.py" "$@" ) > "$BT_OUT" 2>&1; echo $?; }
# kit_phase <plugin> <case dir> <phase> <signed plan file> <repo> <branch> <head> — the kit's own phase, run directly with its
# words as baton passes them (key=value, as typed); rc, output in $BT_OUT
kit_phase() {
  local p=$1 d=$2 ph=$3 plan=$4; shift 4
  ( cd "$d/clone" && XDG_STATE_HOME="$ST" GIT_SSH_COMMAND="$FB/fakessh $d" FAKE_LOG="$d/fake.log" FAKE_GH_WORLD="$d/gh.json" BATON_PHASE="$ph" BATON_PLAN="$plan" \
      BATON_PLUGIN_ROOT="$p" bash "$p/batons/branch-delete.sh" "repo=$1" "branch=$2" "head=$3" ) > "$BT_OUT" 2>&1; echo $?
}
# kit_two <plugin> <case dir> <run plan> <undo plan> <between> <repo> <branch> <head> — the kit's run phase, then the function
# <between> on the case dir (`:` for none), then its undo, from one process as baton runs them (the run record is keyed by that
# parent); prints "<run rc>/<undo rc>", the undo's output in $BT_OUT
kit_two() {
  local p=$1 d=$2 rp=$3 up=$4 between=$5; shift 5
  ( cd "$d/clone" || exit 99
    export XDG_STATE_HOME="$ST" GIT_SSH_COMMAND="$FB/fakessh $d" FAKE_LOG="$d/fake.log" FAKE_GH_WORLD="$d/gh.json" BATON_PLUGIN_ROOT="$p"
    BATON_PHASE=run BATON_PLAN="$rp" bash "$p/batons/branch-delete.sh" "repo=$1" "branch=$2" "head=$3" > /dev/null 2>&1; r=$?
    "$between" "$d"
    BATON_PHASE=undo BATON_PLAN="$up" bash "$p/batons/branch-delete.sh" "repo=$1" "branch=$2" "head=$3" > "$BT_OUT" 2>&1; printf '%s/%s' "$r" "$?" )
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
  eq "$(grep -c '^# Params:' "$P/batons/branch-delete.sh")/$(grep -c '^# Usage: repo=<owner/name> \[clone=<absolute path>\] branch=<name> head=<sha40>' "$P/batons/branch-delete.sh")" "0/1" \
    "[P] the header declares Usage (repo, optional clone, branch and head pairs) and no Params"
  # the kit reads its own words (Usage): a refused call is the kit's rc 1 through baton (its own phase: rc 64), before any read
  eq "$(bt "$P" "$d" rehearse $K --repo acme/app --branch done)" 1 "[P] the old flag form: rehearse rc 1 (a word that is not key=value)"
  has "$(cat "$BT_OUT")" "usage: baton rehearse|run kit:branch-delete repo=<owner/name> [clone=<absolute path>] branch=<name> head=<full sha> [branch=<name> head=<full sha>]...  (1 to 50 branches of one repository; only through the baton runner)" "[P] …it prints the usage line"
  eq "$(bt "$P" "$d" rehearse $K repo=acme/app branch=done)" 1 "[P] no head: rehearse rc 1"
  eq "$(bt "$P" "$d" rehearse $K repo=acme/app branch=done "head=${s:0:12}")" 1 "[P] a short head: rehearse rc 1"
  eq "$(bt "$P" "$d" rehearse $K repo=acme/app branch=done "head=$(printf '%s' "$s" | tr a-f A-F)")" 1 "[P] an upper-case head: rehearse rc 1"
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
    eq "$(bt "$P" "$d" rehearse $K repo=acme/app "branch=$b" "head=$s")" 1 "[R] a branch named $b: the kit refuses the call, rehearse rc 1"
    eq "$(kit_phase "$P" "$d" rehearse /dev/null acme/app "$b" "$s")" 64 "[R] the kit itself refuses a branch named $b: rc 64"
  done
  for b in 'a..b' '-x'; do
    eq "$(bt "$P" "$d" rehearse $K repo=acme/app "branch=$b" "head=$s")" 1 "[R] a branch named $b: the kit refuses the call, rehearse rc 1"
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

# failing_copy <plugin> <dir> — a copy of that plugin whose kit post-check fails, so run undoes
# (with FAKE_MOVE_TO_MAIN set to a bare repository, it first puts the branch there at main: a ref someone else made)
failing_copy() { cp -r "$1" "$2"; mutate "$2/batons/branch-delete.sh" '
postcheck_one() {' '
postcheck_one() {
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

# kit_raw <plugin> <case dir> <phase> <signed plan file> <words...> — the kit's own phase with the words as typed; rc, output in $BT_OUT
kit_raw() {
  local p=$1 d=$2 ph=$3 plan=$4; shift 4
  ( cd "$d/clone" && XDG_STATE_HOME="$ST" GIT_SSH_COMMAND="$FB/fakessh $d" FAKE_LOG="$d/fake.log" FAKE_GH_WORLD="$d/gh.json" BATON_PHASE="$ph" BATON_PLAN="$plan" \
      BATON_PLUGIN_ROOT="$p" bash "$p/batons/branch-delete.sh" "$@" ) > "$BT_OUT" 2>&1; echo $?
}
# plan_lines — the PLAN lines of the last baton output, without their prefix
plan_lines() { sed -n 's/^  PLAN //p' "$BT_OUT"; }

# [B] clone=<path> and the batch: branches done (main~1), release (main), m1 (main~2) and m2 (main~1) are merged, topic is not
fam_batch() {
  local P=$1 d s r t m1 m2 nd pl exp i args w u
  ST="$(fresh)/state"; d=$(setup acme/app); s=$(tip "$d" done); r=$(tip "$d" release); t=$(tip "$d" topic)
  git_ -C "$d/bare.git" update-ref refs/heads/m1 refs/heads/main~2; git_ -C "$d/bare.git" update-ref refs/heads/m2 refs/heads/main~1
  m1=$(tip "$d" m1); m2=$(tip "$d" m2); u="git@$GH:acme/app.git"
  nd="$d/nowhere"; git_ init -q "$nd"; mkdir "$d/plain"
  # a directory with no origin: the refusal says so; clone= names the clone the origin is read from
  for w in "$nd" "$d/plain"; do
    eq "$(BT_CWD="$w" bt_in "$P" "$d" rehearse $K repo=acme/app branch=done "head=$s")" 1 "[B1] rehearse from $(basename "$w"), a directory with no origin: rc 1"
    has "$(cat "$BT_OUT")" "REFUSE remote origin is not set: this kit deletes only on github.com/acme/app" "[B1] …refused with the origin named as not set"
  done
  eq "$(BT_CWD="$nd" bt_in "$P" "$d" rehearse $K repo=acme/app "clone=$d/clone" branch=done "head=$s")" 0 "[B2] the same from there with clone=<the clone>: rehearse rc 0"
  has "$(cat "$BT_OUT")" "PLAN delete merged branch done at $s (merged into main at $(tip "$d" main), ancestor) on $u" "[B2] …the same plan line as a run from the clone"
  eq "$(tip "$d" done)" "$s" "[B2] …rehearse deleted nothing"
  eq "$(BT_CWD="$nd" bt_in "$P" "$d" mode auto >/dev/null; BT_CWD="$nd" bt_in "$P" "$d" go $K repo=acme/app "clone=$d/clone" branch=done "head=$s")" 0 "[B2] go from a directory with no origin, with clone=: rc 0"
  has "$(cat "$BT_OUT")" "go: ok — 1 write" "[B2] …one write"
  eq "$(tip "$d" done)" "" "[B2] …the branch is gone"
  eq "$(grep '^gh ' "$d/fake.log" | grep -vc -- '--hostname github.com')" 0 "[B2] …every gh call names --hostname github.com"
  git_ -C "$d/bare.git" update-ref refs/heads/done "$s"
  git_ clone -q "$d/bare.git" "$d/clone2"; git_ -C "$d/clone2" remote set-url origin "git@$GH:acme/other.git"
  eq "$(BT_CWD="$nd" bt_in "$P" "$d" rehearse $K repo=acme/app "clone=$d/clone2" branch=done "head=$s")" 1 "[B3] clone= whose origin names another repository: rehearse rc 1"
  has "$(cat "$BT_OUT")" "REFUSE the origin of clone $d/clone2 is git@$GH:acme/other.git: this kit deletes only on github.com/acme/app" "[B3] …refused by name"
  eq "$(BT_CWD="$d/clone" bt_in "$P" "$d" rehearse $K repo=acme/app "clone=$nd" branch=done "head=$s")" 1 "[B3] clone= with no origin, though the current directory has one: rehearse rc 1"
  has "$(cat "$BT_OUT")" "REFUSE the origin of clone $nd is not set: this kit deletes only on github.com/acme/app" "[B3] …refused as not set (the current directory's origin is not used)"
  eq "$(bt "$P" "$d" rehearse $K repo=acme/app clone=clone branch=done "head=$s")" 1 "[B3] a clone= that is not an absolute path: rehearse rc 1"
  mkdir "$d/clone3" "$d/clone4"; ln -s "$d/clone/.git" "$d/clone3/.git"; printf 'gitdir: %s/clone/.git\n' "$d" > "$d/clone4/.git"
  for w in clone3 clone4; do
    eq "$(BT_CWD="$nd" bt_in "$P" "$d" rehearse $K repo=acme/app "clone=$d/$w" branch=done "head=$s")" 1 "[B3] clone= whose .git is a $( [ "$w" = clone3 ] && echo symlink || echo file ): rehearse rc 1"
    has "$(cat "$BT_OUT")" "REFUSE the origin of clone $d/$w is not set: this kit deletes only on github.com/acme/app" "[B3] …its origin reads as not set"
  done
  eq "$(tip "$d" done)" "$s" "[B3] …nothing deleted by any of them"
  # a batch of four merged branches: one plan line each, in the order given, one signature
  args=("branch=m2" "head=$m2" "branch=release" "head=$r" "branch=done" "head=$s" "branch=m1" "head=$m1")
  eq "$(bt "$P" "$d" rehearse $K repo=acme/app "${args[@]}")" 0 "[B4] rehearse four merged branches: rc 0"
  exp=""; for i in "m2 $m2" "release $r" "done $s" "m1 $m1"; do exp="$exp${exp:+$'\n'}delete merged branch ${i% *} at ${i#* } (merged into main at $(tip "$d" main), ancestor) on $u"; done
  eq "$(plan_lines)" "$exp" "[B4] …exactly four plan lines, one per branch, in the order given"
  eq "$(tip "$d" m1)$(tip "$d" m2)$(tip "$d" release)$(tip "$d" done)" "$m1$m2$r$s" "[B4] …rehearse deleted nothing"
  ST="$(fresh)/state"
  eq "$(bt "$P" "$d" mode auto >/dev/null; bt "$P" "$d" go $K repo=acme/app "${args[@]}")" 0 "[B4] go: rc 0"
  has "$(cat "$BT_OUT")" "go: ok — 4 write" "[B4] …four writes"
  eq "$(tip "$d" m1)|$(tip "$d" m2)|$(tip "$d" release)|$(tip "$d" done)|$(tip "$d" main)" "||||$(tip "$d" main)" "[B4] …the four branches are gone, main untouched"
  eq "$(find "$ST" -name 'kit-branch-delete-*.last' | wc -l | tr -d ' ')" 0 "[B4] …and a passing post-check drops every run record"
  # one branch that is not merged refuses the whole batch, wherever it stands: no plan line, nothing deleted
  ST="$(fresh)/state"; d=$(setup acme/app); s=$(tip "$d" done); r=$(tip "$d" release); t=$(tip "$d" topic)
  for args in "branch=done head=$s branch=release head=$r branch=topic head=$t" "branch=topic head=$t branch=done head=$s" "branch=done head=$s branch=topic head=$t branch=release head=$r"; do
    eq "$(bt "$P" "$d" rehearse $K repo=acme/app $args)" 1 "[B5] a batch with an unmerged branch ($args): rehearse rc 1"
    has "$(cat "$BT_OUT")" "REFUSE branch topic at $t is not merged into main" "[B5] …refused, naming the branch"
    eq "$(grep -c '^  PLAN ' "$BT_OUT")" 0 "[B5] …no plan line"
    eq "$(tip "$d" done)|$(tip "$d" release)|$(tip "$d" topic)" "$s|$r|$t" "[B5] …nothing deleted"
  done
  eq "$(bt "$P" "$d" mode auto >/dev/null; bt "$P" "$d" go $K repo=acme/app branch=done "head=$s" branch=topic "head=$t")/$(tip "$d" done)" "1/$s" "[B5] go with an unmerged branch in the batch: rc 1, the merged one is not deleted"
  # the run phase proves the whole batch again before its first delete: a signed plan of two, a call of three
  bt "$P" "$d" rehearse $K repo=acme/app branch=done "head=$s" branch=release "head=$r" >/dev/null; plan_lines > "$d/plan"
  eq "$(kit_raw "$P" "$d" run "$d/plan" repo=acme/app branch=done "head=$s" branch=release "head=$r" branch=topic "head=$t")/$(tip "$d" done)" "3/$s" "[B5] the run phase with an unmerged branch last: rc 3, the merged ones are not deleted"
  has "$(cat "$BT_OUT")" "REFUSE branch topic at $t is not merged into main" "[B5] …refused, naming the branch"
  # a call that is not the shape: refused before any read
  for args in "branch=done branch=release head=$r" "head=$s branch=done" "branch=done head=$s branch=done head=$s" "clone=$d/clone clone=$d/clone branch=done head=$s" \
    "branch=done head=$s clone=$d/clone" "branch=done head=$s repo=acme/app" "foo=bar branch=done head=$s" "branch=done head=${s:0:12}"; do
    lc=$(cat "$d/fake.log" | wc -l | tr -d ' ')
    eq "$(bt "$P" "$d" rehearse $K repo=acme/app $args)" 1 "[B6] a call of the wrong shape ($args): rehearse rc 1"
    has "$(cat "$BT_OUT")" "usage: baton rehearse|run kit:branch-delete" "[B6] …it prints the usage line"
    eq "$(tip "$d" done)/$(cat "$d/fake.log" | wc -l | tr -d ' ')" "$s/$lc" "[B6] …nothing deleted, and no gh or git call made (the refusal is before any read)"
  done
  for args in "repo= repo=acme/app branch=done head=$s" "repo=acme/app clone= branch=done head=$s" "repo=acme/app clone= clone=$d/clone branch=done head=$s" \
    "repo=acme/app" "repo=acme/app clone=$d/clone"; do
    eq "$(kit_raw "$P" "$d" rehearse /dev/null $args)" 64 "[B6] the kit itself, $args: rc 64"
  done
  eq "$(kit_raw "$P" "$d" rehearse /dev/null repo=acme/app branch=done "head=$s" branch=done "head=$s")" 64 "[B6] the kit itself: a branch given twice is rc 64"
  has "$(cat "$BT_OUT")" "REFUSE branch done is given twice" "[B6] …named"
  # the bound: 50 branches are read (none exists here), 51 are refused as a shape
  args=(); for i in $(seq 1 50); do args+=("branch=b$i" "head=$s"); done
  eq "$(bt "$P" "$d" rehearse $K repo=acme/app "${args[@]}")" 1 "[B7] 50 branches: rehearse rc 1 (the first does not exist)"
  has "$(cat "$BT_OUT")" "REFUSE $u has no branch b1" "[B7] …read, not refused as a shape"
  args+=("branch=b51" "head=$s")
  eq "$(bt "$P" "$d" rehearse $K repo=acme/app "${args[@]}")" 1 "[B7] 51 branches: rehearse rc 1"
  has "$(cat "$BT_OUT")" "(1 to 50 branches of one repository" "[B7] …refused as a shape, with the bound in the usage line"
}

# [B] the batch's post-check and undo take each branch: a base forced back past the SHAs after the first delete fails the post-check
# of every branch, and undo puts all of them back at their pinned SHAs; a delete that fails half way leaves the rest alone and puts
# the earlier ones back
fam_batch_undo() {
  local P=$1 d s r
  ST="$(fresh)/state"; d=$(setup acme/app); s=$(tip "$d" done); r=$(tip "$d" release); : > "$d/race-base"
  eq "$(bt "$P" "$d" mode auto >/dev/null; bt "$P" "$d" go $K repo=acme/app branch=done "head=$s" branch=release "head=$r")" 4 "[B8] a batch whose post-check fails (the base forced back): rc 4, undone"
  has "$(cat "$BT_OUT")" "DO recreate branch done at $s on git@$GH:acme/app.git" "[B8] …the undo recreates the first branch"
  has "$(cat "$BT_OUT")" "DO recreate branch release at $r on git@$GH:acme/app.git" "[B8] …and the second"
  eq "$(tip "$d" done)|$(tip "$d" release)" "$s|$r" "[B8] …both at their pinned SHAs"
  ST="$(fresh)/state"; d=$(setup acme/app); s=$(tip "$d" done); r=$(tip "$d" release); : > "$d/race"
  eq "$(bt "$P" "$d" mode auto >/dev/null; bt "$P" "$d" go $K repo=acme/app branch=release "head=$r" branch=done "head=$s")" 4 "[B9] a batch whose second delete is refused (the branch moved before the push): rc 4"
  eq "$(tip "$d" release)|$(tip "$d" done)" "$r|$(git_ -C "$d/bare.git" rev-parse main~2)" "[B9] …the first branch is put back, the second left where it moved"
  ST="$(fresh)/state"; d=$(setup acme/app); s=$(tip "$d" done); r=$(tip "$d" release); : > "$d/race"
  eq "$(bt "$P" "$d" mode auto >/dev/null; bt "$P" "$d" go $K repo=acme/app branch=done "head=$s" branch=release "head=$r")" 4 "[B9] a batch whose first delete is refused: rc 4"
  eq "$(tip "$d" release)|$(tip "$d" done)" "$r|$(git_ -C "$d/bare.git" rev-parse main~2)" "[B9] …the run stops there: the refused branch stays where it moved, the second is not deleted"
}

# [B] a batch is proven whole before anything is written: a default branch that moves while the branches are read, a head that
# moved after signing, and a post-check that fails at one branch of the batch
fam_batch_moved() {
  local P=$1 d s r m1 u
  ST="$(fresh)/state"; d=$(setup acme/app); s=$(tip "$d" done); r=$(tip "$d" release); u="git@$GH:acme/app.git"
  git_ -C "$d/bare.git" update-ref refs/heads/m1 refs/heads/main~2; m1=$(tip "$d" m1)
  echo 2 > "$d/move-main-at"
  eq "$(bt "$P" "$d" rehearse $K repo=acme/app branch=done "head=$s" branch=release "head=$r" branch=m1 "head=$m1")" 1 "[B10] the default branch moves while the second branch is read: rehearse rc 1"
  has "$(cat "$BT_OUT")" "REFUSE main moved from $(git_ -C "$d/bare.git" rev-parse main~1) to $(tip "$d" main) while the branches were read (at release): nothing is written" "[B10] …refused, naming both SHAs and the branch"
  eq "$(grep -c '^  PLAN ' "$BT_OUT")/$(tip "$d" done)|$(tip "$d" release)|$(tip "$d" m1)" "0/$s|$r|$m1" "[B10] …no plan line, nothing deleted"
  # signed with main as it was, then main moves before the run reads anything: no line is the signed one, nothing is deleted
  rm -f "$d/move-main-at" "$d/move-main-count"; d=$(setup acme/app); s=$(tip "$d" done); r=$(tip "$d" release)
  bt "$P" "$d" rehearse $K repo=acme/app branch=done "head=$s" branch=release "head=$r" >/dev/null; plan_lines > "$d/plan"
  echo 1 > "$d/move-main-at"
  eq "$(kit_raw "$P" "$d" run "$d/plan" repo=acme/app branch=done "head=$s" branch=release "head=$r")/$(tip "$d" done)|$(tip "$d" release)" "3/$s|$r" "[B10] main moved after signing: the run's first delete is refused (not the signed line), nothing deleted"
  # a line that reads another way at run (its proof) while the base is the same: refused for the whole batch, the line before it not deleted
  d=$(setup acme/app); s=$(tip "$d" done); r=$(tip "$d" release)
  bt "$P" "$d" rehearse $K repo=acme/app branch=done "head=$s" branch=release "head=$r" >/dev/null; plan_lines | sed '2s/ancestor/merged PR #9/' > "$d/plan"
  eq "$(kit_raw "$P" "$d" run "$d/plan" repo=acme/app branch=done "head=$s" branch=release "head=$r")/$(tip "$d" done)|$(tip "$d" release)" "3/$s|$r" "[B10] the second line is not the signed one: run rc 3, the first branch is not deleted"
  has "$(cat "$BT_OUT")" "REFUSE the plan line for release is not in the signed plan" "[B10] …refused, naming the branch"
  eq "$(kit_raw "$P" "$d" rehearse /dev/null repo=acme/app 'branch:x=done' "head:y=$s")" 64 "[B6] a key with a colon is not branch= or head=: rc 64"
  # a head that moved after signing, in the middle of a batch: refused by the run's proof pass before the first delete
  d=$(setup acme/app); s=$(tip "$d" done); r=$(tip "$d" release); git_ -C "$d/bare.git" update-ref refs/heads/m1 refs/heads/main~2; m1=$(tip "$d" m1)
  bt "$P" "$d" rehearse $K repo=acme/app branch=done "head=$s" branch=m1 "head=$m1" branch=release "head=$r" >/dev/null; plan_lines > "$d/plan"
  git_ -C "$d/bare.git" update-ref refs/heads/m1 refs/heads/main~1
  eq "$(kit_raw "$P" "$d" run "$d/plan" repo=acme/app branch=done "head=$s" branch=m1 "head=$m1" branch=release "head=$r")/$(tip "$d" done)|$(tip "$d" release)" "3/$s|$r" "[B11] a head moved after signing, second of three: run rc 3, the others not deleted"
  has "$(cat "$BT_OUT")" "REFUSE branch m1 is at $(tip "$d" m1) on $u, not at the pinned head $m1" "[B11] …refused by name"
  # a post-check that fails at one branch only (main forced back to main~2 holds m1, not done): undo puts back both
  ST="$(fresh)/state"; d=$(setup acme/app); s=$(tip "$d" done); git_ -C "$d/bare.git" update-ref refs/heads/m1 refs/heads/main~2; m1=$(tip "$d" m1); : > "$d/race-base"
  eq "$(bt "$P" "$d" mode auto >/dev/null; bt "$P" "$d" go $K repo=acme/app branch=m1 "head=$m1" branch=done "head=$s")" 4 "[B12] a batch whose post-check fails at one branch only: rc 4, undone"
  has "$(cat "$BT_OUT")" "DO recreate branch done at $s on $u" "[B12] …the failing branch is put back"
  has "$(cat "$BT_OUT")" "DO recreate branch m1 at $m1 on $u" "[B12] …and so is the one whose own check held (the batch goes back whole)"
  eq "$(tip "$d" m1)|$(tip "$d" done)" "$m1|$s" "[B12] …both at their pinned SHAs"
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
  out=$(python3 - "$P/batons/branch-delete-recoverable.sh" "$P/batons/branch-push.sh" <<'PY'
import re, sys
def blocks(p):
    t = open(p, encoding="utf-8").read()
    return {name: re.search(r"^%s\(\) \{\n.*?^\}\n" % name, t, re.S | re.M).group(0) for name in ("cleanenv", "sgit", "url_repo")}
a, b = blocks(sys.argv[1]), blocks(sys.argv[2])
print(" ".join(n for n in a if a[n] != b[n]) or "same")
PY
)
  eq "$out" same "[K] kit:branch-delete-recoverable's cleanenv(), sgit() and url_repo() are byte for byte kit:branch-push's"
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

# ── kit:branch-delete-recoverable and the stop word recoverable-delete ────────────────────────────────────────────────────────
RK=kit:branch-delete-recoverable
# rk_seq <case dir> <signed plan file> <repo> <branch> <head> <clone> <step>... — the kit's phases from one process, as baton runs
# them (the run record is keyed by that parent), from the case directory (not the clone): a step is a phase, its rc joined by /,
# or fn:<function>, run on the case dir; the last phase's output is in $BT_OUT
rk_seq() {
  local d=$1 plan=$2 st rcs=""; local a=("$3" "$4" "$5" "$6"); shift 6
  ( cd "$d" || exit 99
    export XDG_STATE_HOME="$ST" GIT_SSH_COMMAND="$FB/fakessh $d" FAKE_LOG="$d/fake.log" FAKE_GH_WORLD="$d/gh.json" \
      BATON_PLUGIN_ROOT="$PLUGIN" BATON_PLAN="$plan"
    for st in "$@"; do
      case "$st" in
        fn:*) "${st#fn:}" "$d" ;;
        *) BATON_PHASE=$st bash "$PLUGIN/batons/branch-delete-recoverable.sh" "${a[@]}" > "$BT_OUT" 2>&1; rcs="$rcs${rcs:+/}$?" ;;
      esac
    done
    printf '%s' "$rcs" )
}
# rk_plan <case dir> <branch> <head> [clone] — rehearse through baton; its plan lines into <case dir>/plan; rc
rk_plan() {
  local d=$1 r
  r=$(bt "$PLUGIN" "$d" rehearse $RK repo=acme/app "branch=$2" "head=$3" "clone=${4:-$d/clone}")
  sed -n 's/^  PLAN //p' "$BT_OUT" > "$d/plan"; printf '%s' "$r"
}
rbundle() { printf '%s/vibemaestro/baton/bundles/kit-branch-delete-recoverable-%s-%s.bundle' "$ST" \
  "$(printf 'acme/app %s' "$1" | sha256sum | cut -c1-16)" "$2"; }
bundles_n() { find "$ST/vibemaestro/baton/bundles" -name '*.bundle' 2>/dev/null | grep -c . ; }
# wipe <case dir> — the clone deleted, and the remote's objects no ref reaches pruned: only the bundle still holds them
wipe() {
  rm -rf "$1/clone"; git_ -C "$1/bare.git" reflog expire --expire=now --all; git_ -C "$1/bare.git" gc -q --prune=now
  git_ -C "$1/bare.git" cat-file -e "$(cat "$1/head")" 2>/dev/null; echo $? > "$1/wiped"     # 0 while the remote still has it
}
# bw <dir> <baton args...> — rc of baton run from <dir> (not a case clone); output in $BT_OUT
bw() { local w=$1; shift; ( cd "$w" && XDG_STATE_HOME="$ST" python3 "$PLUGIN/scripts/baton.py" "$@" ) > "$BT_OUT" 2>&1; echo $?; }

fam_rd_word() {
  local P=$1 W R
  ST="$(fresh)/state"; W=$(fresh)
  eq "$(bw "$W" check $RK)" 0 "[W0] check kit:branch-delete-recoverable: rc 0"
  eq "$(grep -cx '# Stops: recoverable-delete' "$P/batons/branch-delete-recoverable.sh")" 1 "[W0] …its header declares Stops recoverable-delete"
  bw "$W" new rdx --dir "$W" > /dev/null
  sed -i 's/^# Stops: none$/# Stops: recoverable-delete/' "$W/rdx.sh"     # the input: a session baton declaring the word, not a break
  eq "$(grep -cx '# Stops: recoverable-delete' "$W/rdx.sh")" 1 "[W1] the session baton's header declares it"
  eq "$(bw "$W" check "$W/rdx.sh")" 1 "[W1] a session baton declaring recoverable-delete: check rc 1"
  has "$(cat "$BT_OUT")" "header: Stops recoverable-delete is for kit batons shipped in a plugin (kit:<name>) only" "[W1] …named as a kit-only word"
  R=$(fresh); git_ init -q -b main "$R"; mkdir -p "$R/.vibemaestro/batons"; cp "$W/rdx.sh" "$R/.vibemaestro/batons/rdp.sh"
  eq "$(bw "$R" check project:rdp)" 1 "[W2] a project: baton declaring recoverable-delete: check rc 1"
  has "$(cat "$BT_OUT")" "header: Stops recoverable-delete is for kit batons shipped in a plugin (kit:<name>) only" "[W2] …named as a kit-only word"
  cat > "$W/rmb.sh" <<'SH'
#!/usr/bin/env bash
# Purpose: drop one file from the baton state directory
# Targets: the file under the state directory
# Blast: that one file
# Undo: none
# Pre: the file exists
# Stops: none
# Expect: remove *
set -euo pipefail
PHASE=${BATON_PHASE:-rehearse}
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
DEST="$HOME/.local/state/vibemaestro/baton/bundles/old.bundle"
act() { write "remove $DEST" rm -f -- "$DEST"; }
postcheck() { [ ! -e "$DEST" ]; }
undo() { :; }
case "$PHASE" in
  rehearse) act; echo "VERDICT rehearse ok" ;;
  run) act; echo "VERDICT run ok" ;;
  postcheck) postcheck; echo "VERDICT postcheck ok" ;;
  undo) undo; echo "VERDICT undo ok" ;;
  *) echo "unknown phase: $PHASE" >&2; exit 64 ;;
esac
SH
  sed 's|/baton/bundles/old.bundle|/baton/other/old.bundle|' "$W/rmb.sh" > "$W/rmo.sh"     # the input: the same baton, another directory
  eq "$(bw "$W" check "$W/rmo.sh")" 0 "[W4] control: the same Stops: none baton naming another directory of the state: check rc 0"
  eq "$(bw "$W" check "$W/rmb.sh")" 1 "[W4] a Stops: none session baton naming the state directory's bundles/ (through a name): check rc 1"
  has "$(cat "$BT_OUT")" "names the baton state directory's bundles/, which holds the only copy of what a recoverable delete removed" "[W4] …the bundles directory named"
  has "$(cat "$BT_OUT")" "only a kit: baton (Stops recoverable-delete) touches it" "[W4] …which only a kit may touch"
}

fam_rd_sign() {
  local P=$1 d t
  ST="$(fresh)/state"; d=$(setup acme/app); t=$(tip "$d" topic)
  eq "$(bt "$P" "$d" mode auto >/dev/null; bt "$P" "$d" go $RK repo=acme/app branch=topic "head=$t" "clone=$d/clone")" 8 \
    "[A1] go in mode auto: exit 8, the owner signs a recoverable-delete run"
  eq "$(tip "$d" topic)/$(bundles_n)" "$t/0" "[A1] …nothing deleted, no bundle written"
  eq "$(sg "$P" "$d" $RK repo=acme/app branch=topic "head=$t" "clone=$d/clone")" 3 "[A2] sign --by coordinator-auto: refused, rc 3"
  eq "$(bt "$P" "$d" run $RK repo=acme/app branch=topic "head=$t" "clone=$d/clone"):$(tip "$d" topic)/$(bundles_n)" "3:$t/0" \
    "[A2] …and run has no signature to use: rc 3, nothing deleted, no bundle"
}

fam_rd_refuse() {
  local P=$1 d t s m
  ST="$(fresh)/state"
  # rd_no <label> <reason> <case dir> <branch> <head> [clone] — rehearse rc 1, the reason named, the branch and no bundle left
  rd_no() {
    local before; before=$(tip "$3" "$4")
    eq "$(rk_plan "$3" "$4" "$5" "${6:-}")" 1 "$1: rehearse rc 1"
    has "$(cat "$BT_OUT")" "$2" "$1 …refused by name"
    eq "$(tip "$3" "$4")/$(bundles_n)" "$before/0" "$1 …nothing deleted, no bundle"
  }
  d=$(setup acme/app); t=$(tip "$d" topic)
  git_ clone -q --no-local --depth 1 --no-single-branch "$d/bare.git" "$d/shallow"; git_ -C "$d/shallow" remote set-url origin "git@$GH:acme/app.git"
  rd_no "[C1] a shallow clone" "the clone is shallow" "$d" topic "$t" "$d/shallow"
  git_ clone -q --no-local --single-branch -b main "$d/bare.git" "$d/single"; git_ -C "$d/single" remote set-url origin "git@$GH:acme/app.git"
  rd_no "[C2] a clone missing an object of head" "the clone lacks an object of $t" "$d" topic "$t" "$d/single"
  git_ clone -q --shared "$d/bare.git" "$d/shared"; git_ -C "$d/shared" remote set-url origin "git@$GH:acme/app.git"
  rd_no "[C3] a clone using alternates" "the clone uses alternates" "$d" topic "$t" "$d/shared"
  git_ clone -q "$d/bare.git" "$d/partial"; git_ -C "$d/partial" remote set-url origin "git@$GH:acme/app.git"
  git_ -C "$d/partial" config extensions.partialClone origin
  rd_no "[C4] a clone with extensions.partialClone" "the clone is partial" "$d" topic "$t" "$d/partial"
  git_ -C "$d/clone" worktree add -q "$d/wt" main 2>/dev/null
  rd_no "[C5] a worktree (its .git a file)" ".git is not a directory holding objects" "$d" topic "$t" "$d/wt"
  rd_no "[C6] no repository at clone" ".git is not a directory holding objects" "$d" topic "$t" "$d/none"
  git_ clone -q "$d/bare.git" "$d/grafted"; git_ -C "$d/grafted" remote set-url origin "git@$GH:acme/app.git"
  printf '%s\n' "$t" > "$d/grafted/.git/info/grafts"
  rd_no "[C7] a clone with grafts" "the clone has grafts" "$d" topic "$t" "$d/grafted"
  git_ clone -q "$d/bare.git" "$d/promisor"; git_ -C "$d/promisor" remote set-url origin "git@$GH:acme/app.git"
  : > "$d/promisor/.git/objects/pack/pack-0000000000000000000000000000000000000000.promisor"
  rd_no "[C8] a clone with a .promisor pack" "the clone is partial" "$d" topic "$t" "$d/promisor"
  s=$(tip "$d" done); m=$(tip "$d" main)
  rd_no "[R1] the default branch" "REFUSE main is the default branch" "$d" main "$m"
  rd_no "[R2] a tip off the pinned head" "not at the pinned head $m" "$d" done "$m"
  git_ -C "$d/bare.git" update-ref refs/tags/topic "$t"
  rd_no "[R3] a name that is also a tag" "has a tag topic" "$d" topic "$t"
  git_ -C "$d/bare.git" update-ref -d refs/tags/topic
  world "$d" 'A["protected"] = ["topic"]'
  rd_no "[R4] a protected branch" "branch topic is protected" "$d" topic "$t"
  world "$d" 'A["protected"] = []; A["pulls"] = [{"head": "acme:topic", "base": "main"}]'
  rd_no "[R5] an open pull request from it" "an open pull request has topic as its head" "$d" topic "$t"
  world "$d" 'A["pulls"] = [{"head": "acme:x", "base": "topic"}]'
  rd_no "[R6] an open pull request into it" "an open pull request has topic as its base" "$d" topic "$t"
  world "$d" 'A["pulls"] = []'
  git_ -C "$d/clone" remote set-url origin "git@$GH:acme/other.git"
  rd_no "[R7] a clone whose origin names another repository" "this kit deletes only on github.com/acme/app" "$d" topic "$t"
  d=$(setup acme/pub); t=$(tip "$d" topic)
  eq "$(bt "$P" "$d" rehearse $RK repo=acme/pub branch=topic "head=$t" "clone=$d/clone"):$(tip "$d" topic)" "1:$t" "[R8] a public repository: rehearse rc 1, nothing deleted"
  has "$(cat "$BT_OUT")" "does not read private" "[R8] …refused by name"
}

fam_rd_run() {
  local P=$1 d t s b
  ST="$(fresh)/state"; d=$(setup acme/app); t=$(tip "$d" topic); b=$(rbundle topic "$t")
  eq "$(rk_plan "$d" topic "$t")" 0 "[D1] rehearse an unmerged branch the clone holds: rc 0"
  has "$(cat "$d/plan")" "bundle branch topic at $t into $b" "[D1] …the first write bundles the head into the state directory"
  has "$(cat "$d/plan")" "delete branch topic at $t (kept in bundle $b) on git@$GH:acme/app.git" "[D1] …the second deletes, naming the bundle"
  eq "$(tip "$d" topic)/$(bundles_n)" "$t/0" "[D1] …rehearse deleted nothing, wrote no bundle"
  eq "$(rk_seq "$d" "$d/plan" acme/app topic "$t" "$d/clone" run postcheck)" "0/0" "[D1] the signed run and its post-check: rc 0/0"
  eq "$(tip "$d" topic)/$(bundles_n)" "/1" "[D1] …the branch is gone, one bundle kept"
  eq "$(git_ -C "$d/bare.git" bundle list-heads "$b")" "$t refs/heads/topic" "[D1] …the bundle's one head is the deleted one"
  eq "$(find "$ST" -name 'kit-branch-delete-recoverable-*.last' | grep -c .)" 0 "[D1] …and the passing post-check dropped the run record"
  ST="$(fresh)/state"; d=$(setup acme/app); t=$(tip "$d" topic); rk_plan "$d" topic "$t" > /dev/null; printf '%s' "$t" > "$d/head"
  eq "$(rk_seq "$d" "$d/plan" acme/app topic "$t" "$d/clone" run fn:wipe undo)" "0/0" "[U1] a run, then the clone deleted and the remote pruned, then undo: rc 0/0"
  eq "$(cat "$d/wiped")" 1 "[U1] …control: before undo, the remote no longer had the head's commit"
  has "$(cat "$BT_OUT")" "DO push branch topic at $t back to git@$GH:acme/app.git from the bundle $(rbundle topic "$t")" "[U1] …undo pushes from the bundle"
  eq "$(tip "$d" topic)" "$t" "[U1] …the branch is back at the pinned head"
  eq "$(git_ -C "$d/bare.git" rev-list --objects --missing=error "$t" > /dev/null 2>&1; echo $?)" 0 "[U1] …with every object of it on the remote"
  ST="$(fresh)/state"; d=$(setup acme/app); s=$(tip "$d" done); rk_plan "$d" done "$s" > /dev/null; : > "$d/race"
  eq "$(rk_seq "$d" "$d/plan" acme/app done "$s" "$d/clone" run undo)" "3/0" "[U2] a branch moved just before the push: the lease refuses (rc 3), undo has nothing to put back (rc 0)"
  eq "$(tip "$d" done)" "$(tip "$d" main~2)" "[U2] …the moved branch is left where it is"
  rm -f "$d/race"
  ST="$(fresh)/state"; d=$(setup acme/app); s=$(tip "$d" done); rk_plan "$d" done "$s" > /dev/null
  eq "$(rk_seq "$d" "$d/plan" acme/app done "$s" "$d/clone" run fn:regrow undo)" "0/1" "[U3] a branch there again at another SHA when undo runs: undo rc 1"
  has "$(cat "$BT_OUT")" "LEAVE branch done is at $(tip "$d" main)" "[U3] …named and left"
  eq "$(tip "$d" done)" "$(tip "$d" main)" "[U3] …the other ref untouched"
  # [P] the prune: 201 older bundles of the kit's exact name shape, a name with newlines (the oldest), and a file the newline
  # pieces name in the run's directory; the run keeps the newest 200 of the exact shape and removes nothing else
  ST="$(fresh)/state"; d=$(setup acme/app); t=$(tip "$d" topic); rk_plan "$d" topic "$t" > /dev/null
  has "$(cat "$d/plan")" "into $(rbundle topic "$t"), dropping the kit's bundles past the newest 200" "[P1] the bundle's plan line names the prune"
  mkdir -p "$ST/vibemaestro/baton/bundles"
  python3 - "$ST/vibemaestro/baton/bundles" <<'PY'
import os, sys, time
d, now = sys.argv[1], time.time()
for i in range(201):
    p = os.path.join(d, "kit-branch-delete-recoverable-%016x-%040x.bundle" % (i, i))
    open(p, "w").close(); os.utime(p, (now - 1000 + i, now - 1000 + i))      # i = 0 the oldest
p = os.path.join(d, "kit-branch-delete-recoverable-\nvictim\nx.bundle")
open(p, "w").close(); os.utime(p, (now - 5000, now - 5000))
p = os.path.join(d, "junk\nkit-branch-delete-recoverable-%016x-%040x.bundle" % (150, 150))    # a piece naming a kept bundle
open(p, "w").close(); os.utime(p, (now - 6000, now - 6000))
PY
  : > "$d/victim"
  eq "$(rk_seq "$d" "$d/plan" acme/app topic "$t" "$d/clone" run)" 0 "[P1] the run over 201 older bundles: rc 0"
  eq "$(python3 - "$ST/vibemaestro/baton/bundles" <<'PY'
import os, re, sys
names = os.listdir(sys.argv[1])
exact = [n for n in names if re.fullmatch(r"kit-branch-delete-recoverable-[0-9a-f]{16}-[0-9a-f]{40}\.bundle", n)]
fake = "kit-branch-delete-recoverable-%016x-%040x.bundle"
print(len(exact), fake % (1, 1) in names, fake % (2, 2) in names, fake % (150, 150) in names, sum("\n" in n for n in names))
PY
)" "200 False True True 2" "[P1] …the newest 200 of the exact shape kept (the new one and 199): the two oldest dropped, the next kept; a newline-named file whose piece names a kept bundle removes nothing; both newline-named files left"
  eq "$([ -e "$d/victim" ] && echo kept)" "kept" "[P1] …and the file a newline piece names in the run's directory is not removed"
  ST="$(fresh)/state/"; d=$(setup acme/app); t=$(tip "$d" topic); rk_plan "$d" topic "$t" > /dev/null
  eq "$(rk_seq "$d" "$d/plan" acme/app topic "$t" "$d/clone" run postcheck)/$(tip "$d" topic)" "0/0/" \
    "[P2] XDG_STATE_HOME with a trailing /: the kit and the gate name the same bundle, run and post-check rc 0/0"
}

# rgate <case dir> <gate args...> — the delete gate run directly with the state in $ST; rc, output in $BT_OUT
rgate() {
  local d=$1; shift
  ( cd "$d" && XDG_STATE_HOME="$ST" GIT_SSH_COMMAND="$FB/fakessh $d" python3 -I -B "$PLUGIN/gates/branch_delete.py" "$@" ) > "$BT_OUT" 2>&1; echo $?
}
fam_rd_gate() {
  local P=$1 d t b u line
  ST="$(fresh)/state"; d=$(setup acme/app); t=$(tip "$d" topic); b=$(rbundle topic "$t"); u="git@$GH:acme/app.git"
  line="delete branch topic at $t (kept in bundle $b) on $u"; printf '%s\n' "$line" > "$d/plan"
  g() { rgate "$d" --repo acme/app --branch topic --head "$t" --url "$u" --plan "$line" --expect-plan "$d/plan"; }
  eq "$(g):$(tip "$d" topic)" "3:$t" "[G1] the recoverable form with no bundle: rc 3, nothing deleted"
  has "$(cat "$BT_OUT")" "REFUSE $b cannot be read" "[G1] …named"
  mkdir -p "$(dirname "$b")"; git_ -C "$d/seed" bundle create -q "$b" refs/heads/main
  eq "$(g):$(tip "$d" topic)" "3:$t" "[G2] a bundle of another head at that path: rc 3, nothing deleted"
  has "$(cat "$BT_OUT")" "does not hold exactly $t refs/heads/topic" "[G2] …named"
  rm -f "$b"; git_ -C "$d/seed" bundle create -q "$b" main..topic
  eq "$(g):$(tip "$d" topic)" "3:$t" "[G3] a bundle that needs main's commits (a prerequisite): rc 3, nothing deleted"
  has "$(cat "$BT_OUT")" "does not hold every object of $t" "[G3] …named"
  rm -f "$b"; git_ -C "$d/seed" bundle create -q "$d/x.bundle" refs/heads/topic; ln -s "$d/x.bundle" "$b"
  eq "$(g):$(tip "$d" topic)" "3:$t" "[G4] a symlink at that path: rc 3, nothing deleted"
  has "$(cat "$BT_OUT")" "REFUSE $b is not a regular file" "[G4] …named"
  rm -f "$b"; line="delete branch topic at $t (kept in bundle $d/x.bundle) on $u"; printf '%s\n' "$line" > "$d/plan"
  eq "$(g):$(tip "$d" topic)" "3:$t" "[G5] a complete bundle outside the state directory's bundles/: rc 3, nothing deleted"
  has "$(cat "$BT_OUT")" "is not a bundle of this head under $ST/vibemaestro/baton/bundles" "[G5] …named"
  line="delete branch topic at $t (kept in bundle $b) on $u"; printf '%s\n' "$line" > "$d/plan"; cp "$d/x.bundle" "$b"
  eq "$(g):$(tip "$d" topic)" "0:" "[G6] the signed line and a complete bundle of the head: rc 0, deleted"
}

FAMILIES="fam_call fam_delete fam_refuse fam_signed fam_gate fam_lint fam_undo fam_batch fam_batch_undo fam_batch_moved fam_squash fam_share fam_rd_word fam_rd_sign fam_rd_refuse fam_rd_run fam_rd_gate"
for f in $FAMILIES; do echo "-- $f"; "$f" "$PLUGIN"; done

echo "== nothing written outside the scratch tree =="
eq "$(tree_hash "$SRC_ROOT")" "$H0" "the repository tree is unchanged by the suite"

echo; summary
