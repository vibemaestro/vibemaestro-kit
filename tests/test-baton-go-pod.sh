#!/bin/bash
# =============================================================================
# BatonRun: `go` at exit 8 in a sandbox pod prints the hand-off, not the sign and run lines (scripts/baton.py, cmd_go)
# =============================================================================
# Run: bash tests/test-baton-go-pod.sh
#
# A pod never gets the owner's signature (the guard refuses `sign --by owner` there), so the lines `go` prints after the decision
# card must not hand a pod session a sign command to try. Each family runs on a copy of the real plugin, then again on copies with
# one planted break, and must go red on the intended check. Offline; nothing outside the scratch tree.
#   [P] a pod (SEAT and INTENT_SLUG set): exit 8 as before, the card as before, then the hand-off naming the call (name, args, seal);
#       no `sign --by owner`, no `on the owner's go:`, no `then:` line anywhere in what go printed; a session script on a stop-list
#       stop also gets the pack and PR steps, a kind or a stop that is only mode manual does not
#   [G] no pod: the whole output equals the golden recorded from main before the change (paths, stamp and seal normalised)
#   [X] planted breaks: the pod branch off (family [P] red), the pod branch on everywhere (family [G] red)
# GOLDEN_WRITE=1 bash tests/test-baton-go-pod.sh rewrites the golden files from the real plugin's non-pod output.
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
GOLDEN="$HERE/fixtures/go-exit8-golden"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
clean_env "$TMP"          # unsets SEAT and INTENT_SLUG: a case sets them itself, through BT_ENV
export PYTHONDONTWRITEBYTECODE=1
H0=$(tree_hash "$SRC_ROOT")
BT_OUT="$TMP/bt.out"; ST=""; BT_ENV=()
POD=(SEAT=pod-seat INTENT_SLUG=pod-intent)

# bt <plugin> <dir> <baton args...> — rc of baton from <dir>, state in $ST, plus BT_ENV; output in $BT_OUT
bt() {
  local p=$1 d=$2; shift 2
  ( cd "$d" && cenv XDG_STATE_HOME="$ST" CLAUDE_CODE_SESSION_ID=s-pod ${BT_ENV[@]+"${BT_ENV[@]}"} python3 "$p/scripts/baton.py" "$@" ) > "$BT_OUT" 2>&1
  echo $?
}
# norm <plugin> <dir> — $BT_OUT with the run's own paths, stamp and seal replaced, so a golden does not depend on the scratch tree
norm() {
  sed -e "s#$2#<W>#g" -e "s#$ST#<ST>#g" -e "s#$1#<P>#g" -e 's#[0-9]\{8\}T[0-9]\{6\}Z-[0-9]*#<STAMP>#g' \
      -e 's#[0-9a-f]\{16\}\.[0-9a-f]\{16\}#<SEAL>#g' -e 's#\(records/[a-z-]*\)-[0-9a-f]\{16\}\.last#\1-<ID>.last#g' "$BT_OUT"
}
# the three stops: a session script on the stop-list, a kind on the stop-list, a Stops: none script held only by mode manual
mk_cases() {
  W=$(fresh); ST="$W/state"
  cp "$SRC_ROOT/tests/fixtures/baton-positional.sh" "$W/plain.sh"
  cp "$W/plain.sh" "$W/stop.sh"; mutate "$W/stop.sh" '# Stops: none' '# Stops: publish, secrets'
  printf '{"permissions": {"allow": []}}\n' > "$W/settings.json"; printf '{"ask": ["Bash(rm:*)"]}\n' > "$W/rules.json"
}
# mkb_params <plugin> <out> — a stop-list baton that declares Params (the shape pack keeps)
mkb_params() { python3 "$HERE/fixtures/baton_params.py" make "$1" "$2" "dest=path" "{dest}/** — the file"; sed -i 's/^# Stops: none$/# Stops: publish/' "$2"; }
# run_case <plugin> <dir> <case> — go for the case; rc in $RC, output in $BT_OUT
run_case() {
  case "$3" in
    script) RC=$(bt "$1" "$2" go "$2/stop.sh" "$2/o.txt" hello);;
    kind)   RC=$(bt "$1" "$2" go kind:settings-merge "$2/settings.json" "$2/rules.json");;
    manual) RC=$(bt "$1" "$2" go "$2/plain.sh" "$2/o.txt" hello);;
  esac
}
# no_sign_line <label> — nothing in what go printed is a sign command or the lines that carried one
no_sign_line() {
  local out; out=$(cat "$BT_OUT")
  hasnt "$out" "sign --by owner" "$1: no 'sign --by owner' anywhere in the output"
  hasnt "$out" "on the owner's go:" "$1: no \"on the owner's go:\" line"
  [ "$(grep -c '^then: ' "$BT_OUT")" = 0 ] && ok "$1: no 'then:' line" || bad "$1: no 'then:' line"
  hasnt "$out" "baton.py run " "$1: no run command"
  hasnt "$out" "--queue" "$1: no go --queue offered"
}

fam_pod() {
  local P=$1 W kase seal
  mk_cases; BT_ENV=("${POD[@]}")
  for kase in script kind manual; do
    run_case "$P" "$W" "$kase"
    eq "$RC" 8 "[P] $kase: exit 8 in a pod"
    case "$(head -n 1 "$BT_OUT")" in "== OWNER DECISION: "*) ok "[P] $kase: the output starts with the card";; *) bad "[P] $kase: the output starts with the card";; esac
    no_sign_line "[P] $kase"
    has "$(cat "$BT_OUT")" "hand the call to the coordinator" "[P] $kase: the hand-off is printed"
    has "$(tail -n 1 "$BT_OUT")" "go: stopped after rehearse (exit 8, waiting for the owner)" "[P] $kase: the last line is go's stop line"
    if [ "$kase" = script ]; then continue; fi          # a script without Params is sent back to go: no seal to hand over yet
    seal=$(grep -o -m1 '[0-9a-f]\{16\}\.[0-9a-f]\{16\}' "$BT_OUT" | head -n 1)
    nonempty "$seal" "[P] $kase: a seal is printed"
    has "$(grep -c "seal $seal" "$BT_OUT")" 1 "[P] $kase: the seal is named once, in the call to hand over"
  done
  run_case "$P" "$W" script
  has "$(cat "$BT_OUT")" "a script without a \`# Params:\` header cannot be kept" "[P] script: no Params, so it is sent back to go"
  has "$(cat "$BT_OUT")" "run \`go\` on it again with key=value args" "[P] script: …to go again, which prints the hand-off"
  hasnt "$(cat "$BT_OUT")" " pack " "[P] script: no pack step for bytes that must change first"
  hasnt "$(cat "$BT_OUT")" "seal " "[P] script: no seal that the edit would make stale"
  mkb_params "$P" "$W/pp.sh"
  eq "$(bt "$P" "$W" go "$W/pp.sh" dest="$W/dst")" 8 "[P] params: exit 8 in a pod"
  has "$(cat "$BT_OUT")" "pack $W/pp.sh project:pp" "[P] params: step 1 is the pack command, as project:pp"
  has "$(cat "$BT_OUT")" "commit .vibemaestro/batons/pp.sh on your branch and open the PR" "[P] params: step 2 names the file and the PR"
  has "$(cat "$BT_OUT")" "name project:pp, args dest=$W/dst, seal " "[P] params: the call names project:pp, the args and the seal"
  has "$(cat "$BT_OUT")" "(of this copy)" "[P] params: the seal is said to be of this copy"
  hasnt "$(cat "$BT_OUT")" "without a \`# Params:\`" "[P] params: no Params advice for a baton that declares them"
  no_sign_line "[P] params"
  run_case "$P" "$W" kind
  has "$(cat "$BT_OUT")" "name kind:settings-merge, args $W/settings.json $W/rules.json, seal " "[P] kind: the call names kind:settings-merge, the args and the seal"
  hasnt "$(cat "$BT_OUT")" " pack " "[P] kind: nothing to pack"
  run_case "$P" "$W" manual
  has "$(cat "$BT_OUT")" "name $W/plain.sh, args $W/o.txt hello, seal " "[P] manual: the call names the script, the args and the seal"
  hasnt "$(cat "$BT_OUT")" " pack " "[P] manual: no pack (it keeps an ok run, not this stop)"
  eq "$(bt "$P" "$W" go --queue "$W/stop.sh" "$W/o.txt" hello)" 64 "[P] go --queue in a pod: refused, rc 64"
  hasnt "$(cat "$BT_OUT")" "sign --by owner" "[P] go --queue in a pod: no sign line in the refusal"
  nsig=$(find "$ST/vibemaestro/baton/signatures" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
  eq "$nsig" 0 "[P] nothing was signed"
  [ ! -e "$W/o.txt" ] && ok "[P] nothing was written" || bad "[P] nothing was written"
}

fam_nopod() {
  local P=$1 W kase
  mk_cases; BT_ENV=()
  for kase in script kind manual; do
    run_case "$P" "$W" "$kase"
    eq "$RC" 8 "[G] $kase: exit 8 outside a pod"
    if [ -n "${GOLDEN_WRITE:-}" ]; then mkdir -p "$GOLDEN"; norm "$P" "$W" > "$GOLDEN/$kase.txt"; fi
    has "$(cat "$BT_OUT")" "on the owner's go: " "[G] $kase: the sign line is printed"
    if [ -f "$GOLDEN/$kase.txt" ] && [ "$(norm "$P" "$W")" = "$(cat "$GOLDEN/$kase.txt")" ]; then ok "[G] $kase: the output equals the golden"
    else bad "[G] $kase: the output equals the golden ($(norm "$P" "$W" | diff - "$GOLDEN/$kase.txt" 2>&1 | head -n 4 | tr '\n' '|'))"; fi
  done
}

echo "== the real plugin =="
REAL="$TMP/real"; mk_plugin_copy "$REAL"
echo "-- fam_pod"; fam_pod "$REAL"
echo "-- fam_nopod"; fam_nopod "$REAL"

echo "== planted breaks: each family must go red on a plugin copy with one break in baton.py =="
# BRK <label> <family> <needle> <old> <new> — a plugin copy with the replacement in baton.py, then expect_red
BRK() {
  local label=$1 fam=$2 needle=$3 d; shift 3; d="$TMP/break-$label"; mk_plugin_copy "$d"
  while [ $# -ge 2 ]; do mutate "$d/scripts/baton.py" "$1" "$2" || return; shift 2; done
  expect_red "$label" "$fam" "$d" "$needle"
}
BRK pod-branch-off fam_pod "[P] script: no 'sign --by owner' anywhere" '            if in_sandbox():                            # a pod has no owner' '            if False:                            # a pod has no owner'
BRK pod-everywhere fam_nopod '[G] script: the output equals the golden' '            if in_sandbox():                            # a pod has no owner' '            if True:                            # a pod has no owner'

echo "== nothing written outside the scratch tree =="
eq "$(tree_hash "$SRC_ROOT")" "$H0" "the repository tree is unchanged by the suite"
echo; summary
