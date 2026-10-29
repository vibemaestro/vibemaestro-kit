#!/bin/bash
# =============================================================================
# kit:workflow-dispatch and kind:ci-rerun-failed in a sandbox session, through baton.py
# =============================================================================
# Run: bash tests/test-baton-pod-actions.sh
#
# A sandbox worker's token has no actions:write, so both runs refuse at rehearse (and at run) when SEAT and INTENT_SLUG are both
# set and not blank, the test of in_sandbox() in baton.py. Offline: a fake `gh` per kit (branch_dispatch_gh.py for the kit,
# baton_kinds_gh.py for the kind) logs every call, so "no gh call" is a read of the log.
#   [S] both set: each run refuses at rehearse and at run (the dispatch run also with the real signed plan line), naming the coordinator and what to dispatch or re-run; script rc 3,
#       baton rc 1; no gh call at all; go signs and runs nothing
#   [L] neither set (the laptop, a CI runner), or one only, or one blank or only spaces/tab/newline: rehearse ok, go dispatches / re-runs
#       as before (the dispatch run phase with a signed plan line dispatches)
#   [D] drift: the variables baton.py's SANDBOX_ENV names are the ones the kits test (all set: refused; each one blank: not)
#   [X] planted breaks: the check removed (family [S] red), made unconditional (family [L] red), on `||` (the one-only case red), or the trim removed (the spaces-only case red)
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
clean_env "$TMP"          # unsets SEAT and INTENT_SLUG: a case sets them itself, through SBX
export PYTHONDONTWRITEBYTECODE=1
export BATON_POSTCHECK_WAITS="0 0 0 0"
H0=$(tree_hash "$SRC_ROOT")
FBD="$TMP/fake-dispatch"; FBK="$TMP/fake-kind"; mkdir -p "$FBD" "$FBK"
printf '#!/bin/sh\nexec python3 -B "%s" "$@"\n' "$HERE/fixtures/branch_dispatch_gh.py" > "$FBD/gh"; chmod +x "$FBD/gh"
printf '#!/bin/sh\nexec python3 -B "%s" "$@"\n' "$HERE/fixtures/baton_kinds_gh.py" > "$FBK/gh"; chmod +x "$FBK/gh"

H1=$(printf '1a%.0s' $(seq 20)); B1=$(printf 'b1%.0s' $(seq 20))
BT_OUT="$TMP/bt.out"; ST=""
SBX=()        # the sandbox variables a case sets, as NAME=value words for env
REFUSE_D="REFUSE a sandbox session (SEAT and INTENT_SLUG are set): its token cannot write to Actions (HTTP 403). Ask the coordinator to dispatch workflow ci.yml on acme/app ref main"
REFUSE_K="REFUSE a sandbox session (SEAT and INTENT_SLUG are set): its token cannot write to Actions (HTTP 403). Ask the coordinator to re-run the failed jobs of run 77 of acme/app"
KD=kit:workflow-dispatch; KK=kind:ci-rerun-failed
DARGS="--repo acme/app --workflow ci.yml --ref main"; KARGS="acme/app 77"

# worlds: the two fakes' JSON (the dispatch fake: acme/app private, main at H1 holding ci.yml with workflow_dispatch; the kind fake:
# run 77 of acme/app failed at attempt 1)
world_d() { python3 - "$1/gh.json" <<'PY'
import json, sys
H1, B1 = "1a" * 20, "b1" * 20
wf = {".github/workflows/ci.yml": {"sha": B1, "text": "name: CI\non:\n  push:\n  workflow_dispatch:\n"}}
W = {"viewer": "bot", "next_run": 9000, "faults": {},
     "repos": {"acme/app": {"private": True, "visibility": "private", "branches": {"main": H1}, "files": {H1: wf}, "runs": []}}}
json.dump(W, open(sys.argv[1], "w"))
PY
}
world_k() { python3 - "$1/gh.json" <<'PY'
import json, sys
W = {"repos": {"acme/app": {"private": True, "visibility": "private"}},
     "runs": {"77": {"status": "completed", "conclusion": "failure", "run_attempt": 1, "head_sha": "c0ffee" * 6 + "c0ff", "name": "CI tests"}}}
json.dump(W, open(sys.argv[1], "w"))
PY
}
# bt <fake dir> <plugin> <dir> <baton args...> — rc of baton from <dir>, the sandbox variables SBX set, the fake gh first on PATH
bt() {
  local fb=$1 p=$2 d=$3; shift 3
  if [ $# -eq 2 ] && [ "$1" = mode ]; then baton_set_mode "$ST" "$2"; echo 0; return; fi
  ( cd "$d" && PATH="$fb:$PATH" env ${SBX[@]+"${SBX[@]}"} XDG_STATE_HOME="$ST" FAKE_LOG="$d/fake.log" FAKE_GH_WORLD="$d/gh.json" \
      python3 "$p/scripts/baton.py" "$@" ) > "$BT_OUT" 2>&1
  echo $?
}
# direct <fake dir> <phase> <dir> <script> <args...> — the script itself in a phase: its rc; stdout and stderr in $BT_OUT
direct() {
  local fb=$1 ph=$2 d=$3 s=$4 pl=""; shift 4
  if [ -n "${DPLAN:-}" ]; then printf '%s\n' "$DPLAN" > "$d/signed-plan"; pl="$d/signed-plan"; fi
  ( cd "$d" && PATH="$fb:$PATH" env ${SBX[@]+"${SBX[@]}"} ${pl:+BATON_PLAN="$pl"} BATON_PHASE="$ph" HOME="$d" XDG_STATE_HOME="$ST" FAKE_LOG="$d/fake.log" \
      FAKE_GH_WORLD="$d/gh.json" bash "$s" "$@" ) > "$BT_OUT" 2>&1
  echo $?
}
ncalls() { if [ -f "$1/fake.log" ]; then wc -l < "$1/fake.log" | tr -d ' '; else echo 0; fi; }
nwrites() { if [ -f "$1/fake.log" ]; then grep -cE '^gh (workflow run|run rerun|run cancel) ' "$1/fake.log" || true; else echo 0; fi; }
attempt() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["runs"]["77"]["run_attempt"])' "$1/gh.json"; }

# DPLAN: the signed plan's line a direct run hands the script (BATON_PLAN); empty: no plan
DPLAN=""
KDS="batons/workflow-dispatch.sh"; KKS="templates/baton-kinds/ci-rerun-failed.sh"

fam_sandbox() {
  local P=$1 W
  SBX=(SEAT=pod-seat INTENT_SLUG=pod-intent)
  ST="$(fresh)/state"; W=$(fresh); world_d "$W"
  # shellcheck disable=SC2086
  eq "$(bt "$FBD" "$P" "$W" rehearse $KD $DARGS)" 1 "[S] dispatch: rehearse rc 1 in a sandbox session"
  has "$(cat "$BT_OUT")" "$REFUSE_D" "[S] dispatch: …the one line names the coordinator, the workflow, the repository and the ref"
  eq "$(ncalls "$W")" 0 "[S] dispatch: …no gh call at all (no read, no write)"
  eq "$(direct "$FBD" rehearse "$W" "$PLUGIN/$KDS" $DARGS)" 3 "[S] dispatch: the script's rehearse exits 3"
  eq "$(direct "$FBD" run "$W" "$PLUGIN/$KDS" $DARGS)" 3 "[S] dispatch: …and its run phase exits 3 too, before any call"
  eq "$(ncalls "$W")" 0 "[S] dispatch: …still no gh call"
  DPLAN="dispatch workflow ci.yml on acme/app ref main at $H1 blob $B1 inputs none"
  # shellcheck disable=SC2086
  eq "$(direct "$FBD" run "$W" "$PLUGIN/$KDS" $DARGS)/$(ncalls "$W")" "3/0" "[S] dispatch: the run phase holding the REAL signed plan line still exits 3, no gh call (the guard stands before the write, not behind the plan check)"
  DPLAN=""
  eq "$(bt "$FBD" "$P" "$W" mode auto >/dev/null; bt "$FBD" "$P" "$W" go $KD $DARGS)" 1 "[S] dispatch: go stops at rehearse (rc 1)"
  has "$(cat "$BT_OUT")" "Ask the coordinator to dispatch workflow ci.yml" "[S] dispatch: …go prints the refusal"
  eq "$(nwrites "$W")/$(ncalls "$W")" "0/0" "[S] dispatch: …nothing signed or run: no dispatch, no call"
  ST="$(fresh)/state"; W=$(fresh); world_k "$W"
  eq "$(bt "$FBK" "$P" "$W" rehearse $KK $KARGS)" 1 "[S] rerun: rehearse rc 1 in a sandbox session"
  has "$(cat "$BT_OUT")" "$REFUSE_K" "[S] rerun: …the one line names the coordinator, the run and the repository"
  eq "$(ncalls "$W")" 0 "[S] rerun: …no gh call at all (no read, no write)"
  eq "$(direct "$FBK" rehearse "$W" "$PLUGIN/$KKS" $KARGS)" 3 "[S] rerun: the script's rehearse exits 3"
  eq "$(direct "$FBK" run "$W" "$PLUGIN/$KKS" $KARGS)" 3 "[S] rerun: …and its run phase exits 3 too, before any call"
  eq "$(ncalls "$W")" 0 "[S] rerun: …still no gh call"
  eq "$(bt "$FBK" "$P" "$W" mode auto >/dev/null; bt "$FBK" "$P" "$W" go $KK $KARGS)" 1 "[S] rerun: go stops at rehearse (rc 1)"
  has "$(cat "$BT_OUT")" "Ask the coordinator to re-run the failed jobs of run 77" "[S] rerun: …go prints the refusal"
  eq "$(nwrites "$W")/$(attempt "$W")" "0/1" "[S] rerun: …nothing signed or run: no rerun, the run is still at attempt 1"
}

# fam_laptop: no variable, or an incomplete pair: today's behaviour
fam_laptop() {
  local P=$1 W cfg lab
  SBX=()
  ST="$(fresh)/state"; W=$(fresh); world_d "$W"
  # shellcheck disable=SC2086
  eq "$(bt "$FBD" "$P" "$W" rehearse $KD $DARGS)" 0 "[L] dispatch: no variable, rehearse rc 0"
  has "$(cat "$BT_OUT")" "PLAN dispatch workflow ci.yml on acme/app ref main at $H1" "[L] dispatch: …the plan is the usual one"
  eq "$(bt "$FBD" "$P" "$W" mode auto >/dev/null; bt "$FBD" "$P" "$W" go $KD $DARGS)" 0 "[L] dispatch: go rc 0"
  eq "$(nwrites "$W")" 1 "[L] dispatch: …one dispatch"
  ST="$(fresh)/state"; W=$(fresh); world_d "$W"
  DPLAN="dispatch workflow ci.yml on acme/app ref main at $H1 blob $B1 inputs none"
  # shellcheck disable=SC2086
  eq "$(direct "$FBD" run "$W" "$PLUGIN/$KDS" $DARGS)/$(nwrites "$W")" "0/1" "[L] dispatch: the same signed plan line, no variable: the run phase dispatches (control of the [S] check with the plan)"
  DPLAN=""
  ST="$(fresh)/state"; W=$(fresh); world_k "$W"
  eq "$(bt "$FBK" "$P" "$W" rehearse $KK $KARGS)" 0 "[L] rerun: no variable, rehearse rc 0"
  has "$(cat "$BT_OUT")" "PLAN rerun-failed acme/app run 77 attempt 1" "[L] rerun: …the plan is the usual one"
  eq "$(bt "$FBK" "$P" "$W" mode auto >/dev/null; bt "$FBK" "$P" "$W" go $KK $KARGS)" 0 "[L] rerun: go rc 0"
  eq "$(attempt "$W")" 2 "[L] rerun: …the run is at attempt 2"
  for cfg in 1 2 3 4 5 6; do
    case $cfg in
      1) lab="SEAT=only-seat";              SBX=("SEAT=only-seat") ;;
      2) lab="INTENT_SLUG=only-intent";     SBX=("INTENT_SLUG=only-intent") ;;
      3) lab="INTENT_SLUG empty";           SBX=("SEAT=pod-seat" "INTENT_SLUG=") ;;
      4) lab="INTENT_SLUG spaces only";     SBX=("SEAT=pod-seat" "INTENT_SLUG=   ") ;;
      5) lab="SEAT spaces only";            SBX=("SEAT=  " "INTENT_SLUG=pod-intent") ;;
      6) lab="INTENT_SLUG tab and newline"; SBX=("SEAT=pod-seat" "INTENT_SLUG=$(printf ' \t\n ')") ;;
    esac
    ST="$(fresh)/state"; W=$(fresh); world_d "$W"
    # shellcheck disable=SC2086
    eq "$(bt "$FBD" "$P" "$W" rehearse $KD $DARGS)" 0 "[L] dispatch: only one set or one blank ($lab): rehearse rc 0, not refused"
    ST="$(fresh)/state"; W=$(fresh); world_k "$W"
    eq "$(bt "$FBK" "$P" "$W" rehearse $KK $KARGS)" 0 "[L] rerun: only one set or one blank ($lab): rehearse rc 0, not refused"
  done
  SBX=()
}

# fam_drift: the names baton.py's SANDBOX_ENV holds are the ones both kits test
fam_drift() {
  local P=$1 W names n v cfg
  names=$(python3 -I -B - "$P/scripts/baton.py" <<'PY'
import re, sys
m = re.search(r'(?m)^SANDBOX_ENV = \(([^)]*)\)', open(sys.argv[1], encoding="utf-8").read())
print(" ".join(re.findall(r'"([A-Z_]+)"', m.group(1))) if m else "")
PY
)
  eq "$(printf '%s\n' $names | wc -l | tr -d ' ')" 2 "[D] baton.py's SANDBOX_ENV names two variables ($names)"
  SBX=(); for n in $names; do SBX+=("$n=x"); done
  ST="$(fresh)/state"; W=$(fresh); world_d "$W"
  # shellcheck disable=SC2086
  eq "$(bt "$FBD" "$P" "$W" rehearse $KD $DARGS)" 1 "[D] dispatch: every variable of SANDBOX_ENV set: refused"
  ST="$(fresh)/state"; W=$(fresh); world_k "$W"
  eq "$(bt "$FBK" "$P" "$W" rehearse $KK $KARGS)" 1 "[D] rerun: every variable of SANDBOX_ENV set: refused"
  for v in $names; do
    SBX=(); for n in $names; do if [ "$n" = "$v" ]; then SBX+=("$n="); else SBX+=("$n=x"); fi; done
    ST="$(fresh)/state"; W=$(fresh); world_d "$W"
    # shellcheck disable=SC2086
    eq "$(bt "$FBD" "$P" "$W" rehearse $KD $DARGS)" 0 "[D] dispatch: $v blank, the others set: not refused"
    ST="$(fresh)/state"; W=$(fresh); world_k "$W"
    eq "$(bt "$FBK" "$P" "$W" rehearse $KK $KARGS)" 0 "[D] rerun: $v blank, the others set: not refused"
  done
  SBX=()
}

FAMILIES="fam_sandbox fam_laptop fam_drift"
for f in $FAMILIES; do echo "-- $f"; "$f" "$PLUGIN"; done

echo "== planted breaks: each family must go red on a plugin copy with one break in a kit =="
KBRK() {  # KBRK <label> <family> <needle> <file in the plugin> <old> <new>
  local label=$1 fam=$2 needle=$3 file=$4 d; d="$TMP/break-$label"; mk_plugin_copy "$d"
  mutate "$d/$file" "$5" "$6" && expect_red "$label" "$fam" "$d" "$needle"
}
CHK='  if in_sandbox; then'
KBRK dispatch-check-removed fam_sandbox '[S] dispatch: rehearse rc 1 in a sandbox session' "$KDS" "$CHK" '  if false; then'
KBRK dispatch-check-always fam_laptop '[L] dispatch: no variable, rehearse rc 0' "$KDS" "$CHK" '  if true; then'
KBRK dispatch-one-variable fam_laptop '[L] dispatch: only one set or one blank (SEAT=only-seat)' "$KDS" \
  '  [ -n "${s//[[:space:]]/}" ] && [ -n "${i//[[:space:]]/}" ]' '  [ -n "${s//[[:space:]]/}" ] || [ -n "${i//[[:space:]]/}" ]'
KBRK dispatch-trim-removed fam_laptop '[L] dispatch: only one set or one blank (INTENT_SLUG spaces only)' "$KDS" \
  '  [ -n "${s//[[:space:]]/}" ] && [ -n "${i//[[:space:]]/}" ]' '  [ -n "$s" ] && [ -n "$i" ]'
KBRK rerun-trim-removed fam_laptop '[L] rerun: only one set or one blank (INTENT_SLUG spaces only)' "$KKS" \
  '  [ -n "${s//[[:space:]]/}" ] && [ -n "${i//[[:space:]]/}" ]' '  [ -n "$s" ] && [ -n "$i" ]'
KBRK rerun-check-removed fam_sandbox '[S] rerun: rehearse rc 1 in a sandbox session' "$KKS" "$CHK" '  if false; then'
KBRK rerun-check-always fam_laptop '[L] rerun: no variable, rehearse rc 0' "$KKS" "$CHK" '  if true; then'
KBRK rerun-one-variable fam_laptop '[L] rerun: only one set or one blank (SEAT=only-seat)' "$KKS" \
  '  [ -n "${s//[[:space:]]/}" ] && [ -n "${i//[[:space:]]/}" ]' '  [ -n "${s//[[:space:]]/}" ] || [ -n "${i//[[:space:]]/}" ]'
KBRK drift-third-variable fam_drift '[D] dispatch: POD blank, the others set' scripts/baton.py \
  'SANDBOX_ENV = ("INTENT_SLUG", "SEAT")' 'SANDBOX_ENV = ("INTENT_SLUG", "SEAT", "POD")'
QN=0; okdef=$(declare -f ok); baddef=$(declare -f bad); sp=$PASS; sf=$FAIL
ok() { :; }; bad() { QN=$((QN+1)); }
PLC="$TMP/break-none"; mk_plugin_copy "$PLC"
for f in $FAMILIES; do "$f" "$PLC" >/dev/null 2>&1; done
eval "$okdef"; eval "$baddef"; PASS=$sp; FAIL=$sf
eq "$QN" 0 "control: an unbroken copy passes every family (no failed check)"

echo "== nothing written outside the scratch tree =="
eq "$(tree_hash "$SRC_ROOT")" "$H0" "the repository tree is unchanged by the suite"

echo; summary
