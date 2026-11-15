#!/bin/bash
# =============================================================================
# kit:owner-merge: one owner signature for one or several owner merges, each pinned to its head, on a fake GitHub
# =============================================================================
# Run: bash tests/test-kit-owner-merge.sh
#
# A machine is a scratch home, state directory and project with a copy of the plugin under test; the fake `gh`
# (tests/fixtures/owner_merge_gh.py) answers the kit's four calls from a JSON world and logs each merge it accepted.
#   [one-pr]              go exits 8; the owner signs; run merges it pinned to its head; the post-check names the merge commit
#   [three-prs-one-plan]  three PRs, two in one repository: three plan lines, PLAN-COUNT 3, Each matched, go exits 8; one signature
#                         and one run merge all three in order, the second after GitHub's UNKNOWN once the first merged
#   [head-moved]          a head that moved before rehearse, or after the owner signed: refused, nothing merged
#   [accept-red-not-red]  an accepted red that is green or absent, a red not accepted for that PR: refused naming the PR; a real
#                         accepted red, percent-encoded with a space, passes and the plan line shows it decoded
#   [stop-at-conflict]    the second PR conflicts once the first merged: the run stops there, the first stays merged and is named
#                         by the run and its undo, and baton reports the state unknown, never ok
#   [usage]               malformed arguments: rc 64 naming why, before any read
#   [checks-read]         the checks as the guarded merge reads them: a `|` in a name, a green run of another workflow with the
#                         same name, a newer skipped run, a red commit status and a green run of a cancelled workflow run hide no
#                         red; any red conclusion (startup_failure) can be accepted
#   [queued]              a merge GitHub only queues: the post-check fails, and the undo names it as one that may still merge
#   [merge-5xx]           GitHub answers HTTP 502 to a merge call: merged at the signed head on the read-back is a merge (the run
#                         goes on, run ok, no revert advice); merged at another head stops it, the state unknown (rc 5); still open
#                         at the signed head is tried once more (merged then, or refused); a GraphQL refusal is not tried again;
#                         another base, a PR that stays unreadable, or a retry's exit 0 on a PR another hand merged: rc 5
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

K=kit:owner-merge
H1=1111111111111111111111111111111111111111
H2=2222222222222222222222222222222222222222
H3=3333333333333333333333333333333333333333
HX=9999999999999999999999999999999999999999
OUT="$TMP/out"; M=""; MP=""

# machine <key>=<head>... — a fresh machine whose world holds these open, mergeable PRs into main, each changing one workflow
# file, each head with two green checks
machine() {
  M=$(fresh); MP="$M/plugin"; mkdir -p "$M/home" "$M/state" "$M/proj" "$M/bin"
  mk_plugin_copy "$MP"
  python3 - "$M/world.json" "$@" <<'PY'
import json, sys
w = {"prs": {}, "checks": {}}
for kv in sys.argv[2:]:
    key, head = kv.split("=")
    w["prs"][key] = {"state": "OPEN", "isDraft": False, "head": head, "mergeable": "MERGEABLE", "base": "main",
                     "files": [".github/workflows/ci.yml"]}
    w["checks"]["%s@%s" % (key.split("#")[0], head)] = [["bash tests/run-all.sh", "2026-11-01T10:00:00Z", "completed", "success"],
                                                         ["internal-term scan", "2026-11-01T10:00:00Z", "completed", "success"]]
json.dump(w, open(sys.argv[1], "w"))
PY
  : > "$M/merges.log"
  printf '#!/bin/sh\nexec python3 -I -B "%s" "%s" "%s" "$@"\n' "$HERE/fixtures/owner_merge_gh.py" "$M/world.json" "$M/merges.log" > "$M/bin/gh"
  chmod +x "$M/bin/gh"
}
# wset <python statement over w> — change the world (the test's input, not a break)
wset() { python3 -c 'import json, sys; p = sys.argv[1]; w = json.load(open(p)); exec(sys.argv[2]); json.dump(w, open(p, "w"))' "$M/world.json" "$1"; }
# b <baton args...> — rc of the machine's baton.py, run from its project with the fake gh first on PATH; the output is in $OUT.
# A `sign --by owner` first goes through the plugin's guard hook (owner_asked), as the owner's click on the dialog does.
b() {
  local BT_ENV=(HOME="$M/home" CLAUDE_CONFIG_DIR="$M/home/.claude" CLAUDE_PROJECT_DIR="$M/proj")
  [ "${1:-} ${2:-} ${3:-}" = "sign --by owner" ] && owner_asked "$MP" "$M/proj" "$M/state" s-owner "${@:2}" >/dev/null
  ( export PATH="$M/bin:$PATH"; cd "$M/proj" && cenv HOME="$M/home" CLAUDE_CONFIG_DIR="$M/home/.claude" XDG_STATE_HOME="$M/state" \
      CLAUDE_PROJECT_DIR="$M/proj" CLAUDE_CODE_SESSION_ID=s-owner MERGE_GUARD_RETRY_WAIT_S=0 python3 "$MP/scripts/baton.py" "$@" ) > "$OUT" 2>&1
  echo $?
}
# signed <args...> — rehearse, then the owner signs with the seal it printed; prints the sign rc
signed() {
  local seal
  b rehearse "$K" "$@" >/dev/null
  seal=$(sed -n 's/^seal \([^ ]*\) .*/\1/p' "$OUT")
  b sign --by owner --seal "${seal:-none}" "$K" "$@"
}
# bc <baton args...> — b for a call that must be refused or fail: through capped (tests/fixtures/capped.sh), as a negative case runs
bc() { capped b "$@"; }
merges() { cat "$M/merges.log"; }
# runlog — the full output of the last quiet `run` (its last line names the file)
runlog() { cat "$(sed -n 's/^run: .* — \(\/.*\.log\)$/\1/p' "$OUT")"; }
plan_of() { printf 'squash-merge %s head %s into main (1 files sha b1e4fcd28055c712; checks %s, accepted red %s, no-checks no; image none none; admin %s; GitHub pins the head)' "$@"; }

fam_one_pr() {
  machine "o/r#1=$H1"
  eq "$(b check "$K")" 0 "[one-pr] check kit:owner-merge: rc 0"
  eq "$(b go "$K" o/r 1 "$H1")" 8 "[one-pr] go: exit 8 (Stops security-boundary, owner-acts: the owner signs)"
  hasline "$(sed 's/^ *//' "$OUT")" "1. $(plan_of o/r#1 "$H1" "2/2 green" none no)" "[one-pr] …the card's plan line: PR, head, files count and hash, checks, accepted reds, admin"
  empty "$(merges)" "[one-pr] …nothing merged before the signature"
  eq "$(signed o/r 1 "$H1")" 0 "[one-pr] the owner signs: rc 0"
  eq "$(b run "$K" o/r 1 "$H1")" 0 "[one-pr] run: rc 0"
  eq "$(merges)" "merge o/r#1 match $H1 admin no" "[one-pr] …one squash merge, pinned to the head"
  hasline "$(runlog | sed 's/^ *//')" "o/r#1 merged as b7938c3cf2ad172b2df04fedf29404ac96d9509c" "[one-pr] …the post-check names the merge commit"
}

fam_three() {
  local args=(o/r 1 "$H1" o/r 2 "$H2" --admin o/q 7 "$H3")
  machine "o/r#1=$H1" "o/r#2=$H2" "o/q#7=$H3"
  wset 'w["prs"]["o/r#1"]["on_merge"] = {"o/r#2": {"unknown_reads": 1}}'
  eq "$(b rehearse "$K" "${args[@]}")" 0 "[three-prs-one-plan] rehearse: rc 0"
  eq "$(grep -c '^ *PLAN squash-merge ' "$OUT")" 3 "[three-prs-one-plan] …three plan lines"
  hasline "$(sed 's/^ *//' "$OUT")" "PLAN-COUNT 3" "[three-prs-one-plan] …PLAN-COUNT 3"
  eq "$(grep -c '^ *ok  *squash-merge .*  ~  squash-merge \*$' "$OUT")" 3 "[three-prs-one-plan] …each plan line matches Each squash-merge *"
  hasline "$(sed 's/^ *//' "$OUT")" "PLAN $(plan_of o/r#2 "$H2" "2/2 green" none yes)" "[three-prs-one-plan] …the second line carries its own admin yes"
  eq "$(b go "$K" "${args[@]}")" 8 "[three-prs-one-plan] go: exit 8, one card"
  empty "$(merges)" "[three-prs-one-plan] …nothing merged before the signature"
  eq "$(signed "${args[@]}")" 0 "[three-prs-one-plan] ONE owner signature: rc 0"
  eq "$(b run "$K" "${args[@]}")" 0 "[three-prs-one-plan] one run: rc 0"
  eq "$(merges)" "merge o/r#1 match $H1 admin no
merge o/r#2 match $H2 admin yes
merge o/q#7 match $H3 admin no" "[three-prs-one-plan] …three merges in the given order, each pinned, admin only where asked"
  eq "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["prs"]["o/r#2"]["unknown_reads"])' "$M/world.json")" 0 \
     "[three-prs-one-plan] …the second PR was read again after GitHub answered UNKNOWN"
  hasline "$(runlog | sed 's/^ *//')" "o/q#7 merged as 43476b20d40fcf8b16cf79c61f553fbf1da8d291" "[three-prs-one-plan] …the post-check reads the last one merged"
}

fam_head_moved() {
  machine "o/r#1=$H1" "o/r#2=$HX"
  eq "$(bc rehearse "$K" o/r 1 "$H1" o/r 2 "$H2")" 1 "[head-moved] rehearse: rc 1"
  has "$(cat "$OUT")" "REFUSE o/r#2: head is $HX, not the post-checked $H2" "[head-moved] …names the PR and its head"
  has "$(cat "$OUT")" "the rehearse phase exited 3" "[head-moved] …the kit's own exit is 3"
  eq "$(bc go "$K" o/r 1 "$H1" o/r 2 "$H2")" 1 "[head-moved] go: rc 1, stopped at rehearse"
  empty "$(merges)" "[head-moved] …nothing merged, not even the PR before it"
  machine "o/r#1=$H1" "o/r#2=$H2"
  eq "$(signed o/r 1 "$H1" o/r 2 "$H2")" 0 "[head-moved] the owner signs both"
  wset 'w["prs"]["o/r#2"]["head"] = "'"$HX"'"'
  eq "$(bc run "$K" o/r 1 "$H1" o/r 2 "$H2")" 3 "[head-moved] the second head moved after the signature: run refused (rc 3)"
  has "$(cat "$OUT")" "REFUSE o/r#2: head is $HX, not the post-checked $H2" "[head-moved] …naming the PR"
  empty "$(merges)" "[head-moved] …nothing merged"
  eq "$(bc run "$K" o/r 1 "$H1" o/r 2 "$H2" o/r 3 "$H3")" 3 "[head-moved] a PR appended after the seal: run refused (rc 3)"
  empty "$(merges)" "[head-moved] …nothing merged"
}

fam_accept() {
  machine "o/r#1=$H1" "o/r#2=$H2"
  wset 'w["checks"]["o/r@'"$H1"'"][1][3] = "failure"'
  eq "$(bc rehearse "$K" o/r 1 "$H1" --accept-red bash%20tests/run-all.sh o/r 2 "$H2")" 1 "[accept-red-not-red] accept a green check: rc 1"
  has "$(cat "$OUT")" "REFUSE o/r#1: --accept-red bash tests/run-all.sh: it is not red (ci/bash tests/run-all.sh|completed|success|green)" \
      "[accept-red-not-red] …names the PR, the check and its state"
  eq "$(bc rehearse "$K" o/r 1 "$H1" --accept-red lint o/r 2 "$H2")" 1 "[accept-red-not-red] accept a check the head lacks: rc 1"
  has "$(cat "$OUT")" "REFUSE o/r#1: --accept-red lint: no such check on the head" "[accept-red-not-red] …no such check"
  eq "$(bc rehearse "$K" o/r 1 "$H1" o/r 2 "$H2")" 1 "[accept-red-not-red] a red not accepted: rc 1"
  has "$(cat "$OUT")" "REFUSE o/r#1: checks: 1 green + 0 accepted red of 2 on the head" "[accept-red-not-red] …counts green and accepted red"
  wset 'w["checks"]["o/r@'"$H2"'"][1][3] = "failure"'
  eq "$(bc rehearse "$K" o/r 1 "$H1" --accept-red internal-term%20scan o/r 2 "$H2")" 1 "[accept-red-not-red] the same red on the next PR, accepted only for the first: rc 1"
  has "$(cat "$OUT")" "REFUSE o/r#2: checks: 1 green + 0 accepted red of 2 on the head" "[accept-red-not-red] …the acceptance binds its own PR"
  eq "$(b rehearse "$K" o/r 1 "$H1" --accept-red internal-term%20scan o/r 2 "$H2" --accept-red internal-term%20scan)" 0 \
     "[accept-red-not-red] a real red, percent-encoded with a space, accepted for each PR: rc 0"
  hasline "$(sed 's/^ *//' "$OUT")" "PLAN $(plan_of o/r#1 "$H1" "1/2 green" "internal-term scan" no)" "[accept-red-not-red] …the plan line shows the name decoded"
}

fam_conflict() {
  machine "o/r#1=$H1" "o/r#2=$H2"
  wset 'w["prs"]["o/r#1"]["on_merge"] = {"o/r#2": {"mergeable": "CONFLICTING"}}'
  eq "$(b go "$K" o/r 1 "$H1" o/r 2 "$H2")" 8 "[stop-at-conflict] go: exit 8"
  eq "$(signed o/r 1 "$H1" o/r 2 "$H2")" 0 "[stop-at-conflict] the owner signs both"
  eq "$(bc run "$K" o/r 1 "$H1" o/r 2 "$H2")" 5 "[stop-at-conflict] run: rc 5, the state unknown"
  eq "$(merges)" "merge o/r#1 match $H1 admin no" "[stop-at-conflict] …the first merged, the second not"
  has "$(cat "$OUT")" "REFUSE o/r#2: GitHub reports CONFLICTING" "[stop-at-conflict] …the run names why it stopped"
  has "$(cat "$OUT")" "STOPPED at o/r#2: a precondition fails; merged before the stop: o/r#1" "[stop-at-conflict] …and the PR already merged"
  has "$(cat "$OUT")" "merged, not undone: o/r#1 as b7938c3cf2ad172b2df04fedf29404ac96d9509c: open a revert PR" "[stop-at-conflict] …the undo names it too"
  has "$(cat "$OUT")" "run FAILED (run-failed) and undo FAILED: the state is unknown, tell the owner" "[stop-at-conflict] …baton reports the state unknown"
  hasnt "$(cat "$OUT")" "run ok" "[stop-at-conflict] …never run ok"
  empty "$(ls "$M/state/vibemaestro/baton/records" 2>/dev/null | grep '^kit-owner-merge-unconfirmed-')" "[stop-at-conflict] …no undo record left: the merge before the stop was settled (R3-2)"
  hasnt "$(cat "$OUT")" "kept for putting the state back by hand" "[stop-at-conflict] …and baton keeps nothing for it"
}

fam_checks_read() {
  machine "o/r#1=$H1"
  wset 'w["checks"]["o/r@'"$H1"'"].append(["lint|skipped|completed|success", "2026-11-01T10:00:00Z", "completed", "failure"])'
  eq "$(bc rehearse "$K" o/r 1 "$H1")" 1 "[checks-read] a red run whose name holds |: rc 1"
  has "$(cat "$OUT")" "REFUSE o/r#1: checks: 2 green + 0 accepted red of 3 on the head" "[checks-read] …it counts red, not as the green it spells"
  machine "o/r#1=$H1"
  wset 'w["checks"]["o/r@'"$H1"'"] += [["build", "2026-11-01T10:00:00Z", "completed", "failure", "ci"], ["build", "2026-11-01T10:05:00Z", "completed", "success", "other"]]'
  eq "$(bc rehearse "$K" o/r 1 "$H1")" 1 "[checks-read] a red build, and a later green build of another workflow: rc 1"
  has "$(cat "$OUT")" "REFUSE o/r#1: checks: 3 green + 0 accepted red of 4 on the head" "[checks-read] …the green one hides nothing"
  machine "o/r#1=$H1"
  wset 'w["checks"]["o/r@'"$H1"'"] += [["build", "2026-11-01T10:00:00Z", "completed", "failure"], ["build", "2026-11-01T10:05:00Z", "completed", "skipped"]]'
  eq "$(bc rehearse "$K" o/r 1 "$H1")" 1 "[checks-read] a red build, then a skipped run of it (GitHub lists only the newest by default): rc 1"
  has "$(cat "$OUT")" "REFUSE o/r#1: checks: 2 green + 0 accepted red of 3 on the head" "[checks-read] …every run is read, and the skipped one hides no red"
  machine "o/r#1=$H1"
  wset 'w["statuses"] = {"o/r@'"$H1"'": [["external-ci", "failure", "2026-11-01T10:00:00Z"]]}'
  eq "$(bc rehearse "$K" o/r 1 "$H1")" 1 "[checks-read] a red commit status beside green check runs: rc 1"
  has "$(cat "$OUT")" "REFUSE o/r#1: checks: 2 green + 0 accepted red of 3 on the head" "[checks-read] …the status counts"
  eq "$(bc rehearse "$K" o/r 1 "$H1" --no-checks)" 1 "[checks-read] --no-checks on a head with a status: rc 1"
  wset 'w["checks"] = {}'
  eq "$(bc rehearse "$K" o/r 1 "$H1" --no-checks)" 1 "[checks-read] --no-checks on a head with only a red status: rc 1"
  has "$(cat "$OUT")" "REFUSE o/r#1: --no-checks: the head has 1 checks; judge them instead" "[checks-read] …the status is a check"
  machine "o/r#1=$H1"
  wset 'w["workflow_runs"] = {"o/r@'"$H1"'/ci": {"status": "completed", "conclusion": "cancelled"}}'
  eq "$(bc rehearse "$K" o/r 1 "$H1")" 1 "[checks-read] green check runs of a cancelled workflow run: rc 1"
  has "$(cat "$OUT")" "REFUSE o/r#1: checks: 0 green + 0 accepted red of 2 on the head" "[checks-read] …read red: a token rewrites a check run, not its workflow run"
  machine "o/r#1=$H1"
  wset 'w["workflow_runs"] = {"o/r@'"$H1"'/ci": {"status": "completed", "conclusion": "failure"}}'
  eq "$(bc rehearse "$K" o/r 1 "$H1")" 1 "[checks-read] a red workflow run whose check runs all say green: rc 1"
  has "$(cat "$OUT")" "REFUSE o/r#1: checks: 0 green + 0 accepted red of 2 on the head" "[checks-read] …read red: one of them was rewritten"
  machine "o/r#1=$H1"
  wset 'w["checks"]["o/r@'"$H1"'"] = [[c[0], c[1], c[2], "skipped"] for c in w["checks"]["o/r@'"$H1"'"]]'
  eq "$(bc rehearse "$K" o/r 1 "$H1")" 1 "[checks-read] only skipped runs on the head: rc 1"
  has "$(cat "$OUT")" "REFUSE o/r#1: no check run passed on the head (only skipped runs or statuses)" "[checks-read] …no check run passed"
  wset 'w["checks"] = {}; w["statuses"] = {"o/r@'"$H1"'": [["external-ci", "success", "2026-11-01T10:00:00Z"]]}'
  eq "$(bc rehearse "$K" o/r 1 "$H1")" 1 "[checks-read] only a success status, no check run: rc 1"
  has "$(cat "$OUT")" "REFUSE o/r#1: no check run passed on the head (only skipped runs or statuses)" "[checks-read] …a status alone does not pass"
  machine "o/r#1=$H1"
  wset 'w["prs"]["o/r#1"]["base"] = "rel|x"'
  eq "$(b rehearse "$K" o/r 1 "$H1")" 0 "[checks-read] a base branch whose name holds |: rc 0"
  has "$(cat "$OUT")" "PLAN squash-merge o/r#1 head $H1 into rel|x (1 files" "[checks-read] …the base read whole"
  machine "o/r#1=$H1"
  wset 'w["checks"]["o/r@'"$H1"'"][1][3] = "startup_failure"'
  eq "$(b rehearse "$K" o/r 1 "$H1" --accept-red internal-term%20scan)" 0 "[checks-read] a startup_failure, accepted: rc 0"
  hasline "$(sed 's/^ *//' "$OUT")" "PLAN $(plan_of o/r#1 "$H1" "1/2 green" "internal-term scan" no)" "[checks-read] …accepted red, by name"
}

fam_queued() {
  machine "o/r#1=$H1" "o/r#2=$H2"
  wset 'w["prs"]["o/r#1"]["queue"] = True'
  eq "$(signed o/r 1 "$H1" o/r 2 "$H2")" 0 "[queued] the owner signs both"
  eq "$(bc run "$K" o/r 1 "$H1" o/r 2 "$H2")" 5 "[queued] the first PR only queued: rc 5, the state unknown"
  eq "$(merges)" "queued o/r#1 match $H1 admin no
merge o/r#2 match $H2 admin no" "[queued] …GitHub queued the first, merged the second"
  has "$(cat "$OUT")" "o/r#1 is not merged at $H1 (state OPEN)" "[queued] …the post-check names the one not merged"
  has "$(cat "$OUT")" "queued, may still merge: o/r#1: disable its auto-merge or take it out of the queue now" "[queued] …the undo names it as queued"
  has "$(cat "$OUT")" "merged, not undone: o/r#2 as ff3375404e9f892364ea66c74d4f553d7540944a: open a revert PR" "[queued] …and the merged one"
  has "$(cat "$OUT")" "run FAILED (postcheck-failed) and undo FAILED: the state is unknown, tell the owner" "[queued] …never undo ok"
}

fam_5xx() {
  machine "o/r#1=$H1" "o/r#2=$H2"
  wset 'w["prs"]["o/r#1"]["merge_5xx"] = ["landed"]'
  eq "$(signed o/r 1 "$H1" o/r 2 "$H2")" 0 "[merge-5xx] the owner signs both"
  eq "$(b run "$K" o/r 1 "$H1" o/r 2 "$H2")" 0 "[merge-5xx] 502 on the first merge, which landed at its signed head: run rc 0"
  has "$(cat "$OUT")" "run: ok" "[merge-5xx] …run: ok"
  eq "$(merges)" "merge o/r#1 match $H1 admin no
merge o/r#2 match $H2 admin no" "[merge-5xx] …one call each: the run went on to the second PR"
  has "$(runlog)" "o/r#1: the merge call failed (HTTP 502), but the PR reads merged at its signed head as b7938c3cf2ad172b2df04fedf29404ac96d9509c: the merge landed" \
      "[merge-5xx] …the run names the 502 and the merge it read back"
  hasnt "$(cat "$OUT"; runlog)" "open a revert PR" "[merge-5xx] …no revert advice (the header's Undo line names one only in general)"

  machine "o/r#1=$H1"
  wset 'w["prs"]["o/r#1"].update(merge_5xx=["landed"], merged_head="'"$HX"'")'
  eq "$(signed o/r 1 "$H1")" 0 "[merge-5xx] the owner signs"
  eq "$(bc run "$K" o/r 1 "$H1")" 5 "[merge-5xx] 502, and the PR reads merged at another head: rc 5, the state unknown"
  has "$(cat "$OUT")" "STOPPED at o/r#1: the merge call failed (HTTP 502) and the PR reads MERGED at head $HX into main, merge commit b7938c3cf2ad172b2df04fedf29404ac96d9509c: not merged at its signed head and base, the state is unknown; merged before the stop: none" \
      "[merge-5xx] …the run stops there, naming what it read and the state unknown"
  has "$(cat "$OUT")" "run FAILED (run-failed) and undo FAILED: the state is unknown, tell the owner" "[merge-5xx] …never run ok"

  machine "o/r#1=$H1"
  wset 'w["prs"]["o/r#1"].update(merge_5xx=["landed"], merged_base="release")'
  eq "$(signed o/r 1 "$H1")" 0 "[merge-5xx] the owner signs"
  eq "$(bc run "$K" o/r 1 "$H1")" 5 "[merge-5xx] 502, and the PR reads merged at its head but into another base: rc 5"
  has "$(cat "$OUT")" "the PR reads MERGED at head $H1 into release" "[merge-5xx] …the base is part of the signed merge"

  machine "o/r#1=$H1"
  wset 'w["prs"]["o/r#1"].update(merge_5xx=["landed"], view_fail_after_merge=2)'
  eq "$(signed o/r 1 "$H1")" 0 "[merge-5xx] the owner signs"
  eq "$(b run "$K" o/r 1 "$H1")" 0 "[merge-5xx] 502 on a merge that landed, and the PR unreadable twice: read again, run rc 0"
  eq "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["view_fail"])' "$M/world.json")" 0 "[merge-5xx] …both failed reads were spent"

  machine "o/r#1=$H1"
  wset 'w["prs"]["o/r#1"].update(merge_5xx=["landed"], view_fail_after_merge=9)'
  eq "$(signed o/r 1 "$H1")" 0 "[merge-5xx] the owner signs"
  eq "$(bc run "$K" o/r 1 "$H1")" 5 "[merge-5xx] 502, and the PR stays unreadable: rc 5, the state unknown"
  has "$(cat "$OUT")" "STOPPED at o/r#1: the merge call failed (HTTP 502) and the PR cannot be read back: it may have merged, the state is unknown; merged before the stop: none" \
      "[merge-5xx] …the stop says it may have merged, not that it was refused"
  has "$(cat "$OUT")" "unread, and the run's merge call may have landed: o/r#1: the state is unknown" "[merge-5xx] …the undo, unable to read it, holds it as unknown (N1b)"
  hasnt "$(cat "$OUT")" "the way back is a revert PR each" "[merge-5xx] …with no revert advice"

  machine "o/r#1=$H1" "o/r#2=$H2"
  wset 'w["prs"]["o/r#2"].update(merge_5xx=["landed"], view_fail_after_merge=3)'
  eq "$(signed o/r 1 "$H1" o/r 2 "$H2")" 0 "[merge-5xx] the owner signs both"
  eq "$(bc run "$K" o/r 1 "$H1" o/r 2 "$H2")" 5 "[merge-5xx] the second merge lands with a 502 and stays unreadable through the run: rc 5"
  has "$(cat "$OUT")" "merged, not undone: o/r#1 as b7938c3cf2ad172b2df04fedf29404ac96d9509c: open a revert PR" \
      "[merge-5xx] …the undo keeps the revert line for the merge before the stop"
  has "$(cat "$OUT")" "merged at its signed head, not confirmed by the run: o/r#2 as ff3375404e9f892364ea66c74d4f553d7540944a: the owner decides whether it stays" \
      "[merge-5xx] …and leaves the merge the run could not confirm to the owner"
  hasnt "$(cat "$OUT")" "o/r#2 as ff3375404e9f892364ea66c74d4f553d7540944a: open a revert PR" "[merge-5xx] …no revert advice for it"

  machine "o/r#1=$H1"
  wset 'w["prs"]["o/r#1"].update(merge_5xx=["lost", "late"])'
  eq "$(signed o/r 1 "$H1")" 0 "[merge-5xx] the owner signs"
  eq "$(bc run "$K" o/r 1 "$H1")" 5 "[merge-5xx] 502 twice, the second merge lands but reads open until after the run: rc 5 (N1a)"
  has "$(cat "$OUT")" "STOPPED at o/r#1: the merge call failed (HTTP 502) on one more try, the PR open at its signed head; a merge call may still land, the state is unknown; merged before the stop: none" \
      "[merge-5xx] …the run stops refused, as it read, and says a call may still land"
  has "$(cat "$OUT")" "merged at its signed head, not confirmed by the run: o/r#1 as b7938c3cf2ad172b2df04fedf29404ac96d9509c: the owner decides whether it stays" \
      "[merge-5xx] …the undo, reading it merged, leaves it to the owner"
  hasnt "$(cat "$OUT")" "open a revert PR" "[merge-5xx] …no revert advice for the run's own merge (the symptom this fixes)"

  machine "o/r#1=$H1"
  wset 'w["prs"]["o/r#1"].update(merge_5xx=["lost", "late"], late_reads=2)'
  eq "$(signed o/r 1 "$H1")" 0 "[merge-5xx] the owner signs"
  eq "$(bc run "$K" o/r 1 "$H1")" 5 "[merge-5xx] 502 twice, the second merge reads open through the run and its undo: rc 5, the state unknown (R1)"
  has "$(cat "$OUT")" "open at its signed head, and the run's merge call may still land: o/r#1: the state is unknown" "[merge-5xx] …the undo holds it"
  hasnt "$(cat "$OUT")" "nothing merged: nothing to undo" "[merge-5xx] …never 'nothing merged'"

  machine "o/r#1=$H1"
  wset 'w["prs"]["o/r#1"]["merge_5xx"] = ["dropped"]'
  eq "$(signed o/r 1 "$H1")" 0 "[merge-5xx] the owner signs"
  eq "$(b run "$K" o/r 1 "$H1")" 0 "[merge-5xx] the merge lands, then gh loses the connection (http2: client connection lost): run rc 0 (B1)"
  has "$(runlog)" "o/r#1: the merge call failed (an error that is not GitHub's refusal), but the PR reads merged at its signed head as b7938c3cf2ad172b2df04fedf29404ac96d9509c: the merge landed" \
      "[merge-5xx] …any error but GitHub's refusal may have landed"

  machine "o/r#1=$H1" "o/r#2=$H2"
  wset 'w["prs"]["o/r#1"].update(merge_5xx=["lost"], queue=True, after_call={"head": "'"$HX"'", "autoMerge": False})'
  eq "$(signed o/r 1 "$H1" o/r 2 "$H2")" 0 "[merge-5xx] the owner signs both"
  eq "$(bc run "$K" o/r 1 "$H1" o/r 2 "$H2")" 4 "[merge-5xx] 502, the second call queues it, then its head moves (the queue drops it): the run stops, undo confirms nothing merged, rc 4 (D1)"
  has "$(cat "$OUT")" "STOPPED at o/r#1: the merge call exited 0 on the second try and the PR reads OPEN at head $HX into main" \
      "[merge-5xx] …the run stops there, the state unknown"
  eq "$(merges)" "502 o/r#1 match $H1
queued o/r#1 match $H1 admin no" "[merge-5xx] …and does not go on to merge the second PR"

  machine "o/r#1=$H1"
  wset 'w["prs"]["o/r#1"].update(merge_5xx=["lost"], queue=True, after_call={"autoMerge": False})'
  eq "$(signed o/r 1 "$H1")" 0 "[merge-5xx] the owner signs"
  eq "$(bc run "$K" o/r 1 "$H1")" 5 "[merge-5xx] 502, the second call queues it with no auto-merge request (a merge queue), the post-check fails: rc 5 (R3-1)"
  has "$(cat "$OUT")" "open at its signed head, and the run's merge call may still land: o/r#1: the state is unknown" "[merge-5xx] …the undo holds it"
  hasnt "$(cat "$OUT")" "nothing merged: nothing to undo" "[merge-5xx] …never 'nothing merged'"

  machine "o/r#1=$H1" "o/r#2=$H2"
  wset 'w["prs"]["o/r#1"].update(merge_5xx=["lost"], queue=True, after_call={"autoMerge": False}); w["prs"]["o/r#2"]["merge_5xx"] = ["refused"]'
  eq "$(signed o/r 1 "$H1" o/r 2 "$H2")" 0 "[merge-5xx] the owner signs both"
  eq "$(bc run "$K" o/r 1 "$H1" o/r 2 "$H2")" 5 "[merge-5xx] the first queued after a 502, the second refused: rc 5"
  has "$(cat "$OUT")" "STOPPED at o/r#2: the merge was refused; merged before the stop: none; queued after a failed call, may still land: o/r#1 (the owner decides)" \
      "[merge-5xx] …the stop line names the queued PR as one that may still land, not as one to revert"
  hasnt "$(cat "$OUT")" "open a revert PR" "[merge-5xx] …no revert advice"
  has "$(cat "$OUT")" "open at its signed head, and the run's merge call may still land: o/r#1: the state is unknown" "[merge-5xx] …the undo holds the first"

  machine "o/r#1=$H1"
  wset 'w["prs"]["o/r#1"].update(merge_5xx=["lost"], queue=True)'
  eq "$(signed o/r 1 "$H1")" 0 "[merge-5xx] the owner signs"
  eq "$(bc run "$K" o/r 1 "$H1")" 5 "[merge-5xx] 502, then the second call only queues it: rc 5, as a first call that queues"
  has "$(cat "$OUT")" "queued, may still merge: o/r#1: disable its auto-merge or take it out of the queue now" "[merge-5xx] …the undo names it queued"

  machine "o/r#1=$H1"
  wset 'w["prs"]["o/r#1"].update(merge_5xx=["lost", "raced"], merged_head="'"$HX"'")'
  eq "$(signed o/r 1 "$H1")" 0 "[merge-5xx] the owner signs"
  eq "$(bc run "$K" o/r 1 "$H1")" 5 "[merge-5xx] 502, then another hand merges another head and the retry exits 0 (already merged): rc 5"
  has "$(cat "$OUT")" "STOPPED at o/r#1: the merge call exited 0 on the second try and the PR reads MERGED at head $HX into main" \
      "[merge-5xx] …the retry's exit 0 is read again, not taken as the merge"

  machine "o/r#1=$H1"
  wset 'w["prs"]["o/r#1"]["merge_5xx"] = ["lost", "lost"]'
  eq "$(signed o/r 1 "$H1")" 0 "[merge-5xx] the owner signs"
  eq "$(bc run "$K" o/r 1 "$H1")" 5 "[merge-5xx] 502 twice, the PR still open at its head: the run fails, and its undo, the calls maybe still landing, says the state unknown (rc 5)"
  eq "$(merges)" "502 o/r#1 match $H1
502 o/r#1 match $H1" "[merge-5xx] …exactly one more try"
  has "$(cat "$OUT")" "o/r#1: the merge call failed (HTTP 502) and the PR, read again after 0 s, is still open at its signed head: one more try" \
      "[merge-5xx] …names the retry"
  has "$(cat "$OUT")" "STOPPED at o/r#1: the merge call failed (HTTP 502) on one more try, the PR open at its signed head; a merge call may still land, the state is unknown; merged before the stop: none" \
      "[merge-5xx] …then the refused stop"
  has "$(cat "$OUT")" "open at its signed head, and the run's merge call may still land: o/r#1: the state is unknown" "[merge-5xx] …the undo holds it open, never 'nothing merged' (R1)"

  machine "o/r#1=$H1"
  wset 'w["prs"]["o/r#1"]["merge_5xx"] = ["lost"]'
  eq "$(signed o/r 1 "$H1")" 0 "[merge-5xx] the owner signs"
  eq "$(b run "$K" o/r 1 "$H1")" 0 "[merge-5xx] 502 once, the PR still open: the second try merges, run rc 0"
  eq "$(merges)" "502 o/r#1 match $H1
merge o/r#1 match $H1 admin no" "[merge-5xx] …a lost call, then the merge"

  machine "o/r#1=$H1"
  wset 'w["prs"]["o/r#1"]["merge_5xx"] = ["timeout"]'
  eq "$(signed o/r 1 "$H1")" 0 "[merge-5xx] the owner signs"
  eq "$(b run "$K" o/r 1 "$H1")" 0 "[merge-5xx] GitHub's own query timeout (status 200), the PR still open: tried once more, run rc 0"
  eq "$(merges)" "timeout o/r#1 match $H1
merge o/r#1 match $H1 admin no" "[merge-5xx] …a timed-out call, then the merge"

  machine "o/r#1=$H1"
  eq "$(signed o/r 1 "$H1")" 0 "[merge-5xx] the owner signs"
  : > "$M/state/vibemaestro/baton/records"      # not a break: the run's input, a records path that is a file, so no record can be written
  eq "$(bc run "$K" o/r 1 "$H1")" 4 "[merge-5xx] the undo record cannot be written: no merge call, nothing merged (rc 4)"
  empty "$(merges)" "[merge-5xx] …no merge call made"
  has "$(cat "$OUT")" "cannot be written: no merge call made; merged before the stop: none" "[merge-5xx] …the stop says why"

  machine "o/r#1=$H1"
  wset 'w["prs"]["o/r#1"]["merge_5xx"] = ["blocked"]'
  eq "$(signed o/r 1 "$H1")" 0 "[merge-5xx] the owner signs"
  eq "$(bc run "$K" o/r 1 "$H1")" 4 "[merge-5xx] gh's own refusal before any request (not mergeable: base branch policy): nothing merged (rc 4)"
  eq "$(merges)" "blocked o/r#1 match $H1" "[merge-5xx] …not tried again"
  has "$(cat "$OUT")" "STOPPED at o/r#1: the merge was refused; merged before the stop: none" "[merge-5xx] …the refused stop"

  machine "o/r#1=$H1"
  wset 'w["prs"]["o/r#1"]["merge_5xx"] = ["refused"]'
  eq "$(signed o/r 1 "$H1")" 0 "[merge-5xx] the owner signs"
  eq "$(bc run "$K" o/r 1 "$H1")" 4 "[merge-5xx] a GraphQL refusal, no HTTP status: the run fails, nothing merged (rc 4)"
  eq "$(merges)" "refused o/r#1 match $H1" "[merge-5xx] …not tried again"
}

# usage_case <label> <needle> <args...> — rehearse refused with the kit's rc 64, naming why
usage_case() {
  local label=$1 needle=$2; shift 2
  eq "$(bc rehearse "$K" "$@")" 1 "[usage] $label: rc 1"
  has "$(cat "$OUT")" "the rehearse phase exited 64" "[usage] …$label: the kit's exit is 64"
  has "$(cat "$OUT")" "$needle" "[usage] …$label: names why"
}
fam_usage() {
  local nine=() i
  machine "o/r#1=$H1"
  for i in 1 2 3 4 5 6 7 8 9; do nine+=(o/r "$i" "$H1"); done
  usage_case "no PR" "REFUSE no pull request named"
  usage_case "short head" "REFUSE head must be 40 hex characters: abc" o/r 1 abc
  usage_case "upper-case head" "REFUSE head must be a full SHA, 40 lower-case hex characters: ABC" o/r 1 ABC
  usage_case "not a number" "REFUSE pull request must be a number: x1" o/r x1 "$H1"
  usage_case "not owner/name" "REFUSE repository must be owner/name: r" r 1 "$H1"
  usage_case "the same PR twice" "REFUSE o/r#1 is named twice" o/r 1 "$H1" o/r 1 "$H1"
  usage_case "--no-checks beside --accept-red" "REFUSE --no-checks never goes beside --accept-red (o/r#1)" o/r 1 "$H1" --no-checks --accept-red ci
  usage_case "an option first" "REFUSE --admin before the first pull request" --admin o/r 1 "$H1"
  usage_case "an option with no value" "REFUSE --accept-red needs a value (o/r#1)" o/r 1 "$H1" --accept-red
  usage_case "an unknown option" "REFUSE unknown option --force" o/r 1 "$H1" --force
  usage_case "nine PRs" "REFUSE more than 8 pull requests in one run" "${nine[@]}"
  usage_case "a name with | once decoded" "REFUSE --accept-red a%7Cb: not a check name once decoded (o/r#1)" o/r 1 "$H1" --accept-red a%7Cb
  usage_case "a word with a space" "REFUSE not a plain word: internal-term scan" o/r 1 "$H1" --accept-red "internal-term scan"
  has "$(cat "$OUT")" "(1 to 8 PRs; each option belongs to the PR before it; a check name is percent-encoded: internal-term%20scan)" \
      "[usage] the usage line names the bound and the per-PR options"
  empty "$(merges)" "[usage] nothing merged"
}

fam_one_pr
fam_three
fam_head_moved
fam_accept
fam_conflict
fam_usage
fam_checks_read
fam_queued
fam_5xx

echo "== nothing written outside the scratch tree =="
eq "$(tree_hash "$SRC_ROOT")" "$H0" "the repository tree is unchanged by the suite"

echo; summary
