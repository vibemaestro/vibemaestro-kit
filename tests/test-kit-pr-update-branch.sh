#!/bin/bash
# =============================================================================
# kit:pr-update-branch: bring a PR's branch up to date with its base (update-branch API, head pinned), on a fake GitHub
# =============================================================================
# Run: bash tests/test-kit-pr-update-branch.sh
#
# A machine is a scratch home, state directory and project with a copy of the plugin under test, in mode auto; the fake `gh`
# (tests/fixtures/pr_update_branch_gh.py) answers the kit's four calls from a JSON world and logs each read and each write.
#   [update]    rehearse reads only, one plan line; go calls update-branch once with the head pin and, the
#               post-check prints the new head, also when GitHub shows the old head for two more reads
#   [refused]   a draft, a fork, a closed PR, a PR that is not behind, a conflict (read, and GitHub's 422), a head that moved (at
#               rehearse, after the signature, between the kit's read and its call): one REFUSE line, nothing written
#   [fails]     GitHub answers 500: the run says the update may have landed, never ok
#   [phases]    the post-check of a head that did not move, of one that has no signed parent, of a good one; undo of both states
#   [usage]     malformed arguments: rc 64 naming why, before any read; an upper-case sha is read as lower case
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
# shellcheck source=fixtures/ports.sh
. "$HERE/fixtures/ports.sh"
# shellcheck source=fixtures/baton-owner.sh
. "$HERE/fixtures/baton-owner.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
export PYTHONDONTWRITEBYTECODE=1
H0=$(tree_hash "$SRC_ROOT")

if ! command -v jq >/dev/null 2>&1; then
  echo "skip: jq is not installed (the fake gh serves the kit's --jq through it)"; exit 0
fi

K=kit:pr-update-branch
H=a1b2c3d4e5f60718293a4b5c6d7e8f9001122334   # the signed head
N=b1b2c3d4e5f60718293a4b5c6d7e8f9001122399   # the head after the merge commit
B=c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0   # the base tip
X=d1d2d3d4d5d6d7d8d9d0d1d2d3d4d5d6d7d8d9d0   # a head another hand pushed
OUT="$TMP/out"; M=""; MP=""

# machine — a fresh machine in mode auto whose world holds PR 7 of o/r: open, ready, same repository, behind main by 3
machine() {
  M=$(fresh); MP="$M/plugin"; mkdir -p "$M/home" "$M/state" "$M/proj" "$M/bin"
  mk_plugin_copy "$MP"
  baton_set_mode "$M/state" auto
  python3 - "$M/world.json" "$H" "$N" "$B" <<'EOF'
import json, sys
path, h, n, b = sys.argv[1:]
json.dump({"repo": "o/r", "ahead": 3, "new_head": n, "parents": {n: [h, b]},
           "pr": {"number": 7, "state": "open", "draft": False, "mergeable_state": "behind",
                  "head": {"sha": h, "ref": "feature/x", "repo": {"full_name": "o/r"}}, "base": {"ref": "main", "repo": {"full_name": "o/r"}}}},
          open(path, "w"))
EOF
  : > "$M/gh.log"
  printf '#!/bin/sh\nexec python3 -I -B "%s" "%s" "%s" "$@"\n' "$HERE/fixtures/pr_update_branch_gh.py" "$M/world.json" "$M/gh.log" > "$M/bin/gh"
  chmod +x "$M/bin/gh"
}
# wset <python statement over w> — change the world (the test's input, not a break)
wset() { python3 -c 'import json, sys; p = sys.argv[1]; w = json.load(open(p)); exec(sys.argv[2]); json.dump(w, open(p, "w"))' "$M/world.json" "$1"; }
# b <baton args...> — rc of the machine's baton.py, run from its project with the fake gh first on PATH; the output is in $OUT.
# PW is the runner's waits between post-check reads (none by default: one attempt)
PW=""
b() {
  ( export PATH="$M/bin:$PATH"; cd "$M/proj" && cenv HOME="$M/home" CLAUDE_CONFIG_DIR="$M/home/.claude" XDG_STATE_HOME="$M/state" BATON_POSTCHECK_WAITS="$PW" \
      CLAUDE_PROJECT_DIR="$M/proj" CLAUDE_CODE_SESSION_ID=s-1 python3 "$MP/scripts/baton.py" "$@" ) > "$OUT" 2>&1
  echo $?
}
# bc <baton args...> — b for a call that must be refused or fail: through capped (tests/fixtures/capped.sh), as a negative case runs
bc() { capped b "$@"; }
puts() { grep '^put ' "$M/gh.log" || true; }
updated() { python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("updated", False))' "$M/world.json"; }
# runlog — the full output of the last quiet `go` (its last line names the file)
runlog() { cat "$(sed -n 's/^go: .* — \(\/.*\.log\)$/\1/p' "$OUT")"; }
# kit <phase> <args...> — the kit's own phase, run directly with the fake gh first on PATH; rc, output in $OUT
# UO names the run's undo-record listing (BATON_UNDO_ONLY) when a case needs one
UO=""
kit() { local ph=$1; shift; ( export PATH="$M/bin:$PATH"; XDG_STATE_HOME="$M/state" BATON_UNDO_ONLY="$UO" BATON_PHASE=$ph bash "$PLUGIN/batons/pr-update-branch.sh" "$@" ) > "$OUT" 2>&1; echo $?; }
# called_record <repo> <pr> <head> — a run's record of a call that may still land, listed for the undo (as the kit writes it)
called_record() {
  mkdir -p "$M/state/vibemaestro/baton/records"
  printf '%s %s %s\n' "$1" "$2" "$3" > "$M/state/vibemaestro/baton/records/kit-pr-update-branch-called-1"
  printf '%s\n' "$M/state/vibemaestro/baton/records/kit-pr-update-branch-called-1" > "$M/uo"; UO="$M/uo"
}
ARGS=(--repo o/r --pr 7 --head "$H")

fam_update() {
  machine
  eq "$(b check "$K")" 0 "[update] check kit:pr-update-branch: rc 0"
  eq "$(b rehearse "$K" "${ARGS[@]}")" 0 "[update] rehearse: rc 0"
  hasline "$(sed 's/^ *//' "$OUT")" "PLAN pr-update-branch o/r 7 $H" "[update] …one plan line naming repository, PR and the head"
  eq "$(grep -c '^ *ok  *pr-update-branch .*  ~  pr-update-branch \*$' "$OUT")" 1 "[update] …it matches Each pr-update-branch *"
  empty "$(puts)" "[update] …rehearse made no write call"
  eq "$(grep '^read ' "$M/gh.log" | sort -u | tr '\n' ';')" "read compare o/r $H...main;read pr o/r 7;" "[update] …rehearse read the PR and its distance from main"
  eq "$(b go "$K" "${ARGS[@]}")" 0 "[update] go (Stops none, mode auto): rc 0"
  eq "$(puts)" "put o/r 7 expected_head_sha=$H" "[update] …one update-branch call, pinned to the head, no other parameter"
  hasline "$(runlog | sed 's/^ *//')" "new head $N" "[update] …the post-check prints the new head"
  eq "$(grep -c "^read commit o/r $N\$" "$M/gh.log")" 1 "[update] …and read that commit's parents once"
  machine
  wset 'w["lag"] = 2'
  PW="0 0"
  eq "$(b go "$K" "${ARGS[@]}")" 0 "[update] GitHub shows the old head for two more reads: go still rc 0"
  hasline "$(runlog | sed 's/^ *//')" "new head $N" "[update] …the post-check read again until the new head showed"
  eq "$(puts | wc -l | tr -d ' ')" 1 "[update] …and the call was made once"
  machine
  wset 'w["lag"] = 2'
  PW=""
  eq "$(bc go "$K" "${ARGS[@]}")" 5 "[update] the same with no second read: the post-check fails and the undo cannot say nothing landed, go rc 5"
  has "$(cat "$OUT")" "the head of PR 7 is still $H: not updated" "[update] …the post-check says the head did not move"
  has "$(cat "$OUT")" "LEAVE the head of PR 7 is still $H, but this run called update-branch and GitHub makes the merge commit a moment after it accepts the call: it may still land." "[update] …the undo says the merge commit may still land"
  has "$(cat "$OUT")" "run FAILED (postcheck-failed) and undo FAILED: the state is unknown, tell the owner" "[update] …and the run says the state is unknown"
}

# refused <label> <expected line> — go on the current machine is refused with that one line, nothing written
refused() {
  eq "$(bc go "$K" "${ARGS[@]}")" 1 "[refused] $1: go rc 1"
  has "$(cat "$OUT")" "the rehearse phase exited 3" "[refused] …$1: the kit's own exit is 3"
  hasline "$(sed 's/^ *//' "$OUT")" "$2" "[refused] …$1: the line"
  eq "$(grep -c '^ *REFUSE' "$OUT")" 1 "[refused] …$1: one REFUSE line"
  empty "$(puts)" "[refused] …$1: no write call"
  eq "$(updated)" False "[refused] …$1: the branch is as it was"
}
fam_refused() {
  machine; wset 'w["pr"]["draft"] = True'
  refused "a draft PR" "REFUSE PR 7 of o/r is a draft: nothing written"
  machine; wset 'w["pr"]["head"]["repo"]["full_name"] = "fork/r"'
  refused "a fork PR" "REFUSE PR 7 of o/r comes from a fork (fork/r): not updated here"
  machine; wset 'w["pr"]["head"]["repo"] = None'
  refused "a PR whose fork is deleted" "REFUSE PR 7 of o/r comes from a fork (-): not updated here"
  machine; wset 'w["pr"]["head"]["ref"] = "backmerge/v1"'
  refused "a back-merge PR" "REFUSE PR 7 of o/r is a back-merge (backmerge/v1): the base is never merged into it, the release process resolves it"
  machine; wset 'w["pr"]["state"] = "closed"'
  refused "a closed PR" "REFUSE PR 7 of o/r is closed, not open: nothing to update"
  machine; wset 'w["ahead"] = 0'
  refused "a PR that is not behind" "REFUSE PR 7 of o/r is not behind main: nothing to update"
  machine; wset 'w["pr"]["mergeable_state"] = "dirty"'
  refused "a PR that conflicts (GitHub reads it dirty)" "REFUSE PR 7 of o/r conflicts with main: nothing written, the author resolves it"
  machine; wset 'w["pr"]["head"]["sha"] = "'"$X"'"'
  refused "a head that moved before the rehearse" "REFUSE the head of PR 7 moved: it is $X, the signed head is $H: nothing written"

  # after the signature: another hand pushed
  machine
  local seal
  b rehearse "$K" "${ARGS[@]}" >/dev/null; seal=$(sed -n 's/^seal \([^ ]*\) .*/\1/p' "$OUT")
  eq "$(b sign --by coordinator-auto --seal "${seal:-none}" "$K" "${ARGS[@]}")" 0 "[refused] signed at the head"
  wset 'w["pr"]["head"]["sha"] = "'"$X"'"'
  eq "$(bc run "$K" "${ARGS[@]}")" 3 "[refused] a head that moved after the signature: run rc 3"
  has "$(cat "$OUT")" "REFUSE the head of PR 7 moved: it is $X, the signed head is $H: nothing written" "[refused] …the line"
  empty "$(puts)" "[refused] …no write call"

  # between the kit's read and its call: GitHub's pin refuses with 422, and the kit reads the PR again to say why
  machine
  b rehearse "$K" "${ARGS[@]}" >/dev/null; seal=$(sed -n 's/^seal \([^ ]*\) .*/\1/p' "$OUT")
  b sign --by coordinator-auto --seal "${seal:-none}" "$K" "${ARGS[@]}" >/dev/null
  wset 'w["race_head"] = "'"$X"'"'
  eq "$(bc run "$K" "${ARGS[@]}")" 4 "[refused] a push between the kit's read and its call: run rc 4 (failed, nothing of ours to undo)"
  has "$(cat "$OUT")" "which is not a merge commit over the signed head $H: another hand moved the branch, this run has no call that may still land: nothing to undo" "[refused] …the undo says the push was not this run's"
  eq "$(puts)" "put o/r 7 expected_head_sha=$H" "[refused] …the call went out with the pin"
  has "$(cat "$OUT")" "REFUSE the head of PR 7 moved: it is $X, the signed head is $H: nothing written" "[refused] …GitHub's 422 is named a moved head"
  eq "$(updated)" False "[refused] …the branch is as it was"

  # GitHub's 422 for a conflict its mergeable_state did not show yet
  machine; wset 'w["conflict"] = True'
  b rehearse "$K" "${ARGS[@]}" >/dev/null; seal=$(sed -n 's/^seal \([^ ]*\) .*/\1/p' "$OUT")
  b sign --by coordinator-auto --seal "${seal:-none}" "$K" "${ARGS[@]}" >/dev/null
  eq "$(bc run "$K" "${ARGS[@]}")" 4 "[refused] a conflict only the API sees (422): run rc 4 (failed, nothing to undo)"
  has "$(cat "$OUT")" "REFUSE PR 7 of o/r conflicts with its base (GitHub answered 422): nothing written, the author resolves it" "[refused] …the line"
  eq "$(updated)" False "[refused] …the branch is as it was"

  # GitHub's other 422 ("the endpoint has been spammed") is not called a conflict
  machine; wset 'w["spam"] = True'
  b rehearse "$K" "${ARGS[@]}" >/dev/null; seal=$(sed -n 's/^seal \([^ ]*\) .*/\1/p' "$OUT")
  b sign --by coordinator-auto --seal "${seal:-none}" "$K" "${ARGS[@]}" >/dev/null
  eq "$(bc run "$K" "${ARGS[@]}")" 4 "[refused] GitHub's 422 for a spammed endpoint: run rc 4"
  has "$(cat "$OUT")" "REFUSE GitHub refused the update of PR 7 (422): nothing written: gh: Validation failed, or the endpoint has been spammed. (HTTP 422)" "[refused] …the line names GitHub's words, not a conflict"
  hasnt "$(cat "$OUT")" "conflicts with its base" "[refused] …never says conflict"
  eq "$(updated)" False "[refused] …the branch is as it was"
}

fam_fails() {
  machine; wset 'w["put_fail"] = True'
  eq "$(bc go "$K" "${ARGS[@]}")" 5 "[fails] GitHub answers 500: go rc 5, the call may have landed, the state unknown"
  has "$(cat "$OUT")" "LEAVE the head of PR 7 is still $H, but this run called update-branch" "[fails] …the undo does not say nothing landed"
  has "$(cat "$OUT")" "REFUSE GitHub did not take the update of PR 7 (it may have landed: the post-check and undo read the PR): gh: Server Error (HTTP 500)" "[fails] …says it may have landed"
  hasnt "$(cat "$OUT")" "run ok" "[fails] …never run ok"
}

fam_phases() {
  machine
  eq "$(kit postcheck "${ARGS[@]}")" 1 "[phases] post-check of a head that did not move: rc 1"
  has "$(cat "$OUT")" "the head of PR 7 is still $H: not updated" "[phases] …says so"
eq "$(kit undo "${ARGS[@]}")" 0 "[phases] undo of a head that did not move, by a run with no call that may still land: rc 0"
  has "$(cat "$OUT")" "the head of PR 7 is still $H and this run has no call that may still land: nothing updated, nothing to undo" "[phases] …nothing to undo"
  called_record o/r 7 "$H"
  eq "$(kit undo "${ARGS[@]}")" 1 "[phases] undo of a head that did not move, by a run that called update-branch: rc 1"
  has "$(cat "$OUT")" "LEAVE the head of PR 7 is still $H, but this run called update-branch and GitHub makes the merge commit a moment after it accepts the call: it may still land. Read the head again before relying on it; tell the owner" "[phases] …it may still land"
  called_record o/r 8 "$H"
  eq "$(kit undo "${ARGS[@]}")" 0 "[phases] a record of another PR is not this run's call: rc 0"
  called_record o/r 7 "$H"
  wset 'w["updated"] = True; w["parents"] = {"'"$N"'": ["'"$X"'", "'"$B"'"]}'
  eq "$(kit postcheck "${ARGS[@]}")" 1 "[phases] post-check of a new head without the signed head as a parent: rc 1"
  has "$(cat "$OUT")" "the head of PR 7 is $N, which is not a merge commit over the signed head $H (its parents are not $H and the base): another hand moved the branch" "[phases] …names it"
eq "$(kit undo "${ARGS[@]}")" 1 "[phases] undo of a head that is not a merge over the signed head, by a run that called: rc 1"
  has "$(cat "$OUT")" "which is not a merge commit over the signed head $H, but this run called update-branch: whether its merge commit lies beneath that head is unknown; tell the owner" "[phases] …it cannot say its merge is not beneath"
  UO=""
  eq "$(kit undo "${ARGS[@]}")" 0 "[phases] the same head, by a run with no call that may still land: rc 0"
  has "$(cat "$OUT")" "which is not a merge commit over the signed head $H: another hand moved the branch, this run has no call that may still land: nothing to undo" "[phases] …another hand's push, not this run's"
  wset 'w["parents"] = {"'"$N"'": ["'"$H"'"]}'
  eq "$(kit postcheck "${ARGS[@]}")" 1 "[phases] post-check of an ordinary commit someone pushed on the signed head (one parent): rc 1"
  has "$(cat "$OUT")" "which is not a merge commit over the signed head $H" "[phases] …it is not taken for the base's merge"
  wset 'w["parents"] = {"'"$N"'": ["'"$H"'", "'"$B"'"]}'
  eq "$(kit postcheck "${ARGS[@]}")" 0 "[phases] post-check of a merge commit over the signed head: rc 0"
  has "$(cat "$OUT")" "new head $N" "[phases] …prints the new head"
  eq "$(kit undo "${ARGS[@]}")" 1 "[phases] undo after the update: rc 1, the merge commit stays"
  has "$(cat "$OUT")" "LEAVE the branch of PR 7 holds $N: after $H, a merge commit of main (or another hand's commit). It cannot be taken back cleanly: dropping it is a force-push, a revert adds a second commit." "[phases] …says what it leaves"
  empty "$(puts)" "[phases] nothing written by any phase here"
  eq "$(kit undo --repo q/r --pr 7 --head "$H")" 1 "[phases] undo on a repository it cannot read: rc 1"
  has "$(cat "$OUT")" "LEAVE cannot read pull request 7 of q/r: whether the branch was updated is unknown" "[phases] …says what it cannot know"
}

# usage_case <label> <needle> <args...> — rehearse refused with the kit's rc 64, naming why
usage_case() {
  local label=$1 needle=$2; shift 2
  eq "$(bc rehearse "$K" "$@")" 1 "[usage] $label: rc 1"
  has "$(cat "$OUT")" "the rehearse phase exited 64" "[usage] …$label: the kit's exit is 64"
  has "$(cat "$OUT")" "$needle" "[usage] …$label: names why"
}
fam_usage() {
  machine
  usage_case "no arguments" "REFUSE no --repo"
  usage_case "no PR" "REFUSE no --pr" --repo o/r --head "$H"
  usage_case "no head" "REFUSE no --head" --repo o/r --pr 7
  usage_case "an option without its value" "REFUSE --head takes a value" --repo o/r --pr 7 --head
  usage_case "an unknown option" "REFUSE unknown argument: --force" --repo o/r --pr 7 --head "$H" --force
  usage_case "a repository that is not owner/name" "REFUSE --repo must be owner/name: r" --repo r --pr 7 --head "$H"
  usage_case "an option-shaped repository" "REFUSE --repo must be owner/name: -o/r" --repo -o/r --pr 7 --head "$H"
  usage_case "a command substitution in the repository" 'REFUSE --repo must be owner/name: o/$(touch pwned)' --repo 'o/$(touch pwned)' --pr 7 --head "$H"
  usage_case "a PR that is not a number" "REFUSE --pr must be a pull request number: 7x" --repo o/r --pr 7x --head "$H"
  usage_case "PR 0" "REFUSE --pr must be a pull request number: 0" --repo o/r --pr 0 --head "$H"
  usage_case "a short head" "REFUSE --head must be a full 40-character sha: a1b2c3d" --repo o/r --pr 7 --head a1b2c3d
  usage_case "a head that is not hex" "REFUSE --head must be a full 40-character sha: ${H%?}g" --repo o/r --pr 7 --head "${H%?}g"
  has "$(cat "$OUT")" "usage: go kit:pr-update-branch --repo <owner/name> --pr <n> --head <full sha>" "[usage] the usage line names the arguments"
  empty "$(cat "$M/gh.log")" "[usage] nothing read, nothing written"
  eq "$(find "$M" -name pwned | wc -l | tr -d ' ')" 0 "[usage] the command substitution never ran"
  eq "$(b rehearse "$K" --repo o/r --pr 7 --head "$(printf '%s' "$H" | tr 'a-f' 'A-F')")" 0 "[usage] an upper-case sha is accepted"
  hasline "$(sed 's/^ *//' "$OUT")" "PLAN pr-update-branch o/r 7 $H" "[usage] …and planned as lower case"
}

fam_update
fam_refused
fam_fails
fam_phases
fam_usage

echo "== nothing written outside the scratch tree =="
eq "$(tree_hash "$SRC_ROOT")" "$H0" "the repository tree is unchanged by the suite"

echo; summary
