#!/bin/bash
# =============================================================================
# The kit baton kit:workflow-dispatch (batons/workflow-dispatch.sh), through baton.py
# =============================================================================
# Run: bash tests/test-baton-workflow-dispatch.sh
#
# Offline: a fake `gh` (tests/fixtures/branch_dispatch_gh.py) holds the repository, its branch heads, the workflow file at each
# head and the workflow runs, logs every call, and makes the run(s) a dispatch creates.
#   [D] go: rehearse plans the record and the dispatch (head, blob, inputs) and makes no write call; the run dispatches once,
#       the post-check sees exactly one new run, the inputs reach `gh workflow run`
#   [R] refusals at rehearse: a public or internal repository, no such branch, no workflow file, no workflow_dispatch (one
#       only in a comment too), a bad input key or workflow name; no dispatch
#   [M] the world moved after signing (the head): run refuses before the dispatch
#   [U] undo cancels only the run this dispatch made: not a run that matched before, not another actor's, not a finished one;
#       two new runs of the viewer are left alone (rc 5); a later run's undo leaves an earlier run's record
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
H0=$(tree_hash "$SRC_ROOT")
FB="$TMP/fakebin"; mkdir -p "$FB"
printf '#!/bin/sh\nexec python3 -B "%s" "$@"\n' "$HERE/fixtures/branch_dispatch_gh.py" > "$FB/gh"; chmod +x "$FB/gh"
PATH="$FB:$PATH"; export PATH

H1=$(printf '1a%.0s' $(seq 20)); H2=$(printf '2b%.0s' $(seq 20)); B1=$(printf 'b1%.0s' $(seq 20))
BT_OUT="$TMP/bt.out"; ST=""
# world <dir> [python statements on W] — the fake's world: viewer bot; acme/app private, branch main at H1 holding ci.yml with
# a workflow_dispatch trigger; acme/pub public; acme/int internal
world() { python3 - "$1/gh.json" "${2:-}" <<'PY'
import json, sys
H1, B1 = "1a" * 20, "b1" * 20
wf = {".github/workflows/ci.yml": {"sha": B1, "text": "name: CI\non:\n  push:\n  workflow_dispatch:\n    inputs:\n      level: {}\n"},
      ".github/workflows/nightly.yml": {"sha": "c3" * 20, "text": "on:\n  schedule:\n    - cron: '0 3 * * *'\n  # workflow_dispatch: later\n"},
      ".github/workflows/deploy.yml": {"sha": "c4" * 20, "text": "on: push\njobs:\n  a:\n    if: github.event_name == 'workflow_dispatch'\n"}}
W = {"viewer": "bot", "next_run": 9000, "faults": {},
     "repos": {"acme/app": {"private": True, "visibility": "private", "branches": {"main": H1, "a/b": H1}, "files": {H1: wf}, "runs": []},
               "acme/pub": {"private": False, "visibility": "public", "branches": {"main": H1}, "files": {H1: wf}, "runs": []},
               "acme/int": {"private": True, "visibility": "internal", "branches": {"main": H1}, "files": {H1: wf}, "runs": []}}}
exec(sys.argv[2])
json.dump(W, open(sys.argv[1], "w"))
PY
}
# wq <dir> <python expression on W> — a value of the world now (R is acme/app)
wq() { python3 - "$1/gh.json" "$2" <<'PY'
import json, sys
W = json.load(open(sys.argv[1]))
R = W["repos"]["acme/app"]
print(eval(sys.argv[2]))
PY
}
# bt <plugin> <dir> <baton args...> — rc of baton run from <dir> with the state in $ST; its output is in $BT_OUT
bt() { local p=$1 d=$2; shift 2; [ $# -eq 2 ] && [ "$1" = mode ] && { baton_set_mode "$ST" "$2"; echo 0; return; }; ( cd "$d" && XDG_STATE_HOME="$ST" FAKE_LOG="$d/fake.log" FAKE_GH_WORLD="$d/gh.json" python3 "$p/scripts/baton.py" "$@" ) > "$BT_OUT" 2>&1; echo $?; }
# sg <plugin> <dir> <args...> — rehearse to read the seal, sign it as coordinator-auto (mode auto); the rc of sign
sg() {
  local p=$1 d=$2 seal; shift 2
  bt "$p" "$d" mode auto >/dev/null
  seal=$( ( cd "$d" && XDG_STATE_HOME="$ST" FAKE_LOG="$d/fake.log" FAKE_GH_WORLD="$d/gh.json" python3 "$p/scripts/baton.py" rehearse "$@" ) 2>/dev/null \
          | sed -n 's/^seal \([^ ]*\) .*/\1/p')
  bt "$p" "$d" sign --by coordinator-auto --seal "${seal:-none}" "$@"
}
ndispatch() { grep -c '^gh workflow run ' "$1/fake.log" || true; }
K=kit:workflow-dispatch
ARGS="--repo acme/app --workflow ci.yml --ref main"

fam_dispatch() {
  local P=$1 W
  ST="$(fresh)/state"; W=$(fresh); world "$W"
  # shellcheck disable=SC2086
  eq "$(bt "$P" "$W" rehearse $K $ARGS --input level=3)" 0 "[D] rehearse: rc 0"
  has "$(cat "$BT_OUT")" "PLAN dispatch workflow ci.yml on acme/app ref main at $H1 blob $B1 inputs level=3" "[D] …the plan pins the head, the workflow blob and the inputs"
  has "$(cat "$BT_OUT")" "PLAN record " "[D] …and the run record before it"
  eq "$(ndispatch "$W")" 0 "[D] …rehearse made no dispatch"
  # shellcheck disable=SC2086
  eq "$(sg "$P" "$W" $K $ARGS --input level=3)/$(bt "$P" "$W" run $K $ARGS --input level=3)" "0/0" "[D] sign and run: rc 0"
  eq "$(ndispatch "$W")" 1 "[D] …one dispatch"
  eq "$(grep -c '^gh workflow run ci.yml --repo acme/app --ref main -f level=3$' "$W/fake.log")" 1 "[D] …with the input as -f"
  eq "$(wq "$W" '[(r["id"], r["status"], r["head_sha"] == "'"$H1"'") for r in R["runs"]]')" "[(9000, 'queued', True)]" "[D] …one queued run at the pinned head"
  ST="$(fresh)/state"; W=$(fresh); world "$W"
  # shellcheck disable=SC2086
  eq "$(bt "$P" "$W" mode auto >/dev/null; bt "$P" "$W" go $K $ARGS)" 0 "[D] go with no input: rc 0"
  has "$(cat "$BT_OUT")" "go: ok — 2 writes" "[D] …two writes: the record and the dispatch"
}

fam_refuse() {
  local P=$1 W
  ST="$(fresh)/state"; W=$(fresh); world "$W"
  eq "$(bt "$P" "$W" rehearse $K --repo acme/pub --workflow ci.yml --ref main)" 1 "[R] a public repository: rehearse rc 1"
  has "$(cat "$BT_OUT")" "REFUSE acme/pub does not read private" "[R] …refused by name"
  eq "$(bt "$P" "$W" rehearse $K --repo acme/int --workflow ci.yml --ref main)" 1 "[R] an internal repository: rehearse rc 1"
  eq "$(bt "$P" "$W" rehearse $K --repo acme/app --workflow ci.yml --ref nope)" 1 "[R] no such branch: rehearse rc 1"
  has "$(cat "$BT_OUT")" "REFUSE acme/app has no branch nope" "[R] …refused by name"
  eq "$(bt "$P" "$W" rehearse $K --repo acme/app --workflow absent.yml --ref main)" 1 "[R] no such workflow file: rehearse rc 1"
  eq "$(bt "$P" "$W" rehearse $K --repo acme/app --workflow nightly.yml --ref main)" 1 "[R] a workflow whose workflow_dispatch is only in a comment: rehearse rc 1"
  has "$(cat "$BT_OUT")" "declares no workflow_dispatch" "[R] …refused by name"
  eq "$(bt "$P" "$W" rehearse $K --repo acme/app --workflow deploy.yml --ref main)" 1 "[R] a workflow that names workflow_dispatch only in a step condition: rehearse rc 1"
  # shellcheck disable=SC2086
  eq "$(bt "$P" "$W" rehearse $K $ARGS --input 'bad key=1')" 1 "[R] an input key with a space: rehearse rc 1"
  eq "$(bt "$P" "$W" rehearse $K --repo acme/app --workflow '../x.yml' --ref main)" 1 "[R] a workflow name with a path: rehearse rc 1"
  eq "$(bt "$P" "$W" rehearse $K --repo acme/app --workflow ci.yml --ref 'a..b')" 1 "[R] a ref git refuses: rehearse rc 1"
  eq "$(bt "$P" "$W" rehearse $K --repo acme/app --workflow ci.yml --ref 'main#x')" 1 "[R] a ref with # (an API path would drop the rest): rehearse rc 1"
  eq "$(bt "$P" "$W" rehearse $K --repo acme/app --workflow ci.yml --ref 'fix+x')" 1 "[R] a ref with + (a query would read a space): rehearse rc 1"
  ST="$(fresh)/state"; W2=$(fresh); world "$W2" 'R = W["repos"]["acme/app"]; R["branches"]["a_b"] = R["branches"]["main"]'
  bt "$P" "$W2" mode auto >/dev/null
  bt "$P" "$W2" go $K --repo acme/app --workflow ci.yml --ref a/b >/dev/null; bt "$P" "$W2" go $K --repo acme/app --workflow ci.yml --ref a_b >/dev/null
  eq "$(ls "$ST/vibemaestro/baton/records" | sed 's/-[0-9]*\.last$//' | sort -u | wc -l | tr -d ' ')" 2 "[R] refs a/b and a_b get run records of their own"
  eq "$(ndispatch "$W")" 0 "[R] …no dispatch in any of them"
}

fam_moved() {
  local P=$1 W
  ST="$(fresh)/state"; W=$(fresh); world "$W"
  # shellcheck disable=SC2086
  eq "$(sg "$P" "$W" $K $ARGS)" 0 "[M] sign: rc 0"
  python3 - "$W/gh.json" "$H2" <<'PY'
import json, sys
W = json.load(open(sys.argv[1])); R = W["repos"]["acme/app"]
R["branches"]["main"] = sys.argv[2]; R["files"][sys.argv[2]] = R["files"]["1a" * 20]
json.dump(W, open(sys.argv[1], "w"))
PY
  # shellcheck disable=SC2086
  eq "$(bt "$P" "$W" run $K $ARGS)" 3 "[M] the branch moved after signing: run refused (rc 3)"
  eq "$(ndispatch "$W")" 0 "[M] …no dispatch"
  ST="$(fresh)/state"; W=$(fresh); world "$W" 'R = W["repos"]["acme/app"]; R["files"]["'"$H2"'"] = R["files"]["'"$H1"'"]; W["faults"]["dispatch_moves_head"] = "'"$H2"'"'
  # shellcheck disable=SC2086
  eq "$(sg "$P" "$W" $K $ARGS)/$(bt "$P" "$W" run $K $ARGS)" "0/4" "[M] the branch moved during the dispatch (gh dispatches by name): the post-check sees the other head, undo cancels it (rc 4)"
  eq "$(wq "$W" '[(r["status"], r["head_sha"][:2]) for r in R["runs"]]')" "[('completed', '2b')]" "[M] …the run of unsigned bytes is cancelled"
  ST="$(fresh)/state"; W=$(fresh); world "$W"
  bt "$P" "$W" rehearse $K $ARGS >/dev/null
  printf 'record x\ndispatch workflow ci.yml on acme/app ref main at %s blob other inputs none\n' "$H1" > "$W/plan-other"
  ( cd "$W" && XDG_STATE_HOME="$ST" FAKE_LOG="$W/fake.log" FAKE_GH_WORLD="$W/gh.json" BATON_PHASE=run BATON_PLAN="$W/plan-other" BATON_PLUGIN_ROOT="$P" \
      bash "$P/batons/workflow-dispatch.sh" $ARGS ) > "$BT_OUT" 2>&1
  eq "$?:$(ndispatch "$W")" "3:0" "[M] a run phase whose dispatch line is not in the signed plan: refused before the dispatch"
}

# failing_copy <plugin> <dir> — a copy of that plugin (a broken one included) whose kit post-check fails, so run undoes
failing_copy() { cp -r "$1" "$2"; mutate "$2/batons/workflow-dispatch.sh" '
postcheck() {
' '
postcheck() {
  return 1
'; }

fam_undo() {
  local P=$1 W C
  C="$(fresh)/plugin"; failing_copy "$P" "$C"
  ST="$(fresh)/state"; W=$(fresh); world "$W" 'W["repos"]["acme/app"]["runs"].append({"id": 8000, "workflow": "ci.yml", "event": "workflow_dispatch", "branch": "main", "head_sha": "1a" * 20, "actor": "bot", "status": "queued"})
W["faults"]["dispatch_extra_actor"] = "someone"'
  # shellcheck disable=SC2086
  eq "$(sg "$C" "$W" $K $ARGS)/$(bt "$C" "$W" run $K $ARGS)" "0/4" "[U] a post-check that fails: run rc 4, undone"
  eq "$(wq "$W" '[(r["id"], r["status"]) for r in R["runs"]]')" "[(8000, 'queued'), (9000, 'completed'), (9001, 'queued')]" "[U] …only this dispatch's run is cancelled: not the one that matched before, not another actor's"
  ST="$(fresh)/state"; W=$(fresh); world "$W" 'W["faults"]["dispatch_fails"] = True'
  # shellcheck disable=SC2086
  eq "$(sg "$P" "$W" $K $ARGS)/$(bt "$P" "$W" run $K $ARGS)" "0/4" "[U] gh refuses the dispatch: run rc 4, undo says nothing landed"
  has "$(cat "$BT_OUT")" "gh never accepted the dispatch: nothing landed" "[U] …and says so"
  ST="$(fresh)/state"; W=$(fresh); world "$W" 'W["faults"]["dispatch_fails_after"] = True'
  # shellcheck disable=SC2086
  eq "$(sg "$P" "$W" $K $ARGS)/$(bt "$P" "$W" run $K $ARGS)" "0/5" "[U] a dispatch whose answer was lost: its new run is not cancelled (it may be another's), rc 5"
  eq "$(wq "$W" '[r["status"] for r in R["runs"]]')" "['queued']" "[U] …the new run is left as it is"
  ST="$(fresh)/state"; W=$(fresh); world "$W" 'W["faults"]["dispatch_creates"] = 0'
  # shellcheck disable=SC2086
  eq "$(sg "$P" "$W" $K $ARGS)/$(bt "$P" "$W" run $K $ARGS)" "0/5" "[U] gh accepted the dispatch and no run ever shows: left for the owner, rc 5"
  has "$(cat "$BT_OUT")" "LEAVE gh accepted the dispatch" "[U] …and says so"
  ST="$(fresh)/state"; W=$(fresh); world "$W" 'W["faults"]["dispatch_creates"] = 2'
  # shellcheck disable=SC2086
  eq "$(sg "$P" "$W" $K $ARGS)/$(bt "$P" "$W" run $K $ARGS)" "0/5" "[U] two new runs of the viewer: the post-check fails, undo leaves both (rc 5)"
  has "$(cat "$BT_OUT")" "LEAVE 2 new runs" "[U] …and says what it left"
  eq "$(wq "$W" '[r["status"] for r in R["runs"]]')" "['queued', 'queued']" "[U] …neither is cancelled"
  ST="$(fresh)/state"; W=$(fresh); world "$W"
  # shellcheck disable=SC2086
  eq "$(sg "$P" "$W" $K $ARGS)/$(bt "$P" "$W" run $K $ARGS)" "0/0" "[U] a run that held, then a byte-identical one whose run phase fails before its record"
  python3 - "$W/gh.json" <<'PY'
import json, sys
W = json.load(open(sys.argv[1])); W["faults"]["repo_read_fails_in_run"] = True; json.dump(W, open(sys.argv[1], "w"))
PY
  # shellcheck disable=SC2086
  eq "$(sg "$P" "$W" $K $ARGS)/$(bt "$P" "$W" run $K $ARGS)" "0/4" "[U] …the second run fails and is undone (rc 4)"
  eq "$(wq "$W" '[r["status"] for r in R["runs"]]')" "['queued']" "[U] …and its undo does not cancel the first run's run (its record is the first run's)"
  ST="$(fresh)/state"; W=$(fresh); world "$W"
  # shellcheck disable=SC2086
  eq "$(sg "$P" "$W" $K $ARGS)/$(bt "$P" "$W" run $K $ARGS)" "0/0" "[U] a dispatch that held: its record stays"
  printf 'another signed plan\n' > "$W/plan2"
  ( cd "$W" && XDG_STATE_HOME="$ST" FAKE_LOG="$W/fake.log" FAKE_GH_WORLD="$W/gh.json" BATON_PHASE=undo BATON_PLAN="$W/plan2" BATON_PLUGIN_ROOT="$P" \
      bash "$P/batons/workflow-dispatch.sh" $ARGS ) > "$BT_OUT" 2>&1
  eq "$?/$(wq "$W" '[r["status"] for r in R["runs"]]')" "0/['queued']" "[U] the undo of a later run that wrote nothing does not cancel the earlier run"
  has "$(cat "$BT_OUT")" "no run record" "[U] …it finds no record of its own (records are kept per runner process)"
}

FAMILIES="fam_dispatch fam_refuse fam_moved fam_undo"
for f in $FAMILIES; do echo "-- $f"; "$f" "$PLUGIN"; done

echo "== planted breaks: each family must go red on a plugin copy with one break in the kit =="
KBRK() {  # KBRK <label> <family> <needle> <old> <new>
  local label=$1 fam=$2 needle=$3 d; d="$TMP/break-$label"; mk_plugin_copy "$d"
  mutate "$d/batons/workflow-dispatch.sh" "$4" "$5" && expect_red "$label" "$fam" "$d" "$needle"
}
KBRK public-allowed fam_refuse '[R] a public repository: rehearse rc 1' '  if [ "$vis" != "true private" ]; then' '  if false; then'
KBRK no-dispatch-trigger fam_refuse "[R] a workflow that names workflow_dispatch only in a step condition" '    line=${line%%[[:space:]]#*}' '    line=${line%%[[:space:]]#*}; [[ "$line" == *workflow_dispatch* ]] && return 0'
KBRK input-key-open fam_refuse '[R] an input key with a space' '          if ! [[ "$2" =~ ^[A-Za-z0-9_-]+=[^[:cntrl:]]*$ ]]; then' '          if false; then'
KBRK head-unpinned fam_moved '[M] the branch moved after signing' '  PLANLINE="dispatch workflow $WF on $REPO ref $REF at $head blob $blob inputs ${INPUTS[*]:-none}"' '  PLANLINE="dispatch workflow $WF on $REPO ref $REF at pinned blob $blob inputs ${INPUTS[*]:-none}"'
KBRK moved-head-accepted fam_moved '[M] the branch moved during the dispatch' '  [ "$at" = "$head" ] || { echo' '  true || { echo'
KBRK plan-unchecked fam_moved '[M] a run phase whose dispatch line is not in the signed plan' '  if [ -z "${BATON_PLAN:-}" ] || ! grep -Fqx -- "$PLANLINE" "$BATON_PLAN"; then' '  if false; then'
KBRK ref-charset-open fam_refuse '[R] a ref with #' '  || ! [[ "$REF" =~ ^[A-Za-z0-9_][A-Za-z0-9._/-]*$ ]] || ! git check-ref-format "refs/heads/$REF" > /dev/null 2>&1; then' '  || ! git check-ref-format "refs/heads/$REF" > /dev/null 2>&1; then'
KBRK record-name-collides fam_refuse '[R] refs a/b and a_b get run records of their own' 'RECORD="$RECORDS/kit-workflow-dispatch-$(sha256_text "$REPO $WF $REF" | cut -c1-16)-$PPID.last"' 'RECORD="$RECORDS/kit-workflow-dispatch-${REF//\//_}-$PPID.last"'
KBRK record-shared-by-plans fam_undo "[U] …and its undo does not cancel the first run's run" 'RECORD="$RECORDS/kit-workflow-dispatch-$(sha256_text "$REPO $WF $REF" | cut -c1-16)-$PPID.last"' 'RECORD="$RECORDS/kit-workflow-dispatch-$(sha256_text "$REPO $WF $REF" | cut -c1-16)-0.last"'
KBRK cancel-unsent fam_undo "[U] a dispatch whose answer was lost" '  if [ "$n" -eq 1 ] && [ "$sent" != sent ]; then' '  if false; then'
KBRK unsent-silent fam_undo "[U] gh accepted the dispatch and no run ever shows" '  if [ "$n" -eq 0 ] && [ "$sent" = sent ]; then' '  if false; then'
KBRK before-runs-counted fam_undo "[U] …only this dispatch's run is cancelled" '      *",$id,"*) ;;' '      *",nothing,"*) ;;'
KBRK any-actor fam_undo "[U] …only this dispatch's run is cancelled" '    --jq ".workflow_runs[] | select(.triggering_actor.login == \"$1\") | \"\(.id) \(.status) \(.head_sha)\""' '    --jq ".workflow_runs[] | select(.triggering_actor.login == \"$1\") | \"\(.id) \(.status) \(.head_sha)\""; gh api "repos/$REPO/actions/workflows/$WF/runs?event=workflow_dispatch&branch=$REF&per_page=100" --jq ".workflow_runs[] | select(.triggering_actor.login == \"someone\") | \"\(.id) \(.status) \(.head_sha)\""'
KBRK many-cancelled fam_undo '[U] two new runs of the viewer' '  if [ "$n" -gt 1 ]; then' '  if false; then'
QN=0; okdef=$(declare -f ok); baddef=$(declare -f bad); sp=$PASS; sf=$FAIL
ok() { :; }; bad() { QN=$((QN+1)); }
PLC="$TMP/break-none"; mk_plugin_copy "$PLC"
for f in $FAMILIES; do "$f" "$PLC" >/dev/null 2>&1; done
eval "$okdef"; eval "$baddef"; PASS=$sp; FAIL=$sf
eq "$QN" 0 "control: an unbroken copy passes every family (no failed check)"

echo "== nothing written outside the scratch tree =="
eq "$(tree_hash "$SRC_ROOT")" "$H0" "the repository tree is unchanged by the suite"

echo; summary
