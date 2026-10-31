#!/bin/bash
# =============================================================================
# BatonRun: `go` at exit 8 and `rehearse` in a sandbox pod print the hand-off, not the owner's commands (scripts/baton.py)
# =============================================================================
# Run: bash tests/test-baton-go-pod.sh
#
# A pod never gets the owner's signature (the guard refuses `sign --by owner` there), so the lines `go` prints after the decision
# card must not hand a pod session a sign command to try. Each family runs on a copy of the real plugin, then again on copies with
# one planted break, and must go red on the intended check. Offline; nothing outside the scratch tree.
#   [P] a pod (SEAT and INTENT_SLUG set): exit 8 as before, the card as before, then the hand-off naming the call (name, args, seal);
#       no `sign --by owner`, no `on the owner's go:`, no `then:` line, no mode command anywhere in what go printed; a session
#       script, on a stop-list stop or held only by mode manual, gets the pack and PR steps and a call to project:<name> (never a
#       pod path), or, without Params, the one step to take first; a kind hands over its own name
#   [K] a pod keeps a Stops: none script as project: on its mode-manual stop, saying it never ran; outside a pod pack refuses it
#   [R] rehearse in a pod: no owner command, one line that go hands the call to the coordinator
#   [G] no pod: the whole output of go and rehearse equals the golden recorded from main before the change (paths, stamp and seal
#       normalised)
#   [X] planted breaks: the pod branch off (families [P] and [R] red), the pod branch on everywhere (family [G] red)
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
      -e 's#[0-9a-f]\{16\}\.[0-9a-f]\{16\}#<SEAL>#g' -e 's#\(records/[a-z-]*\)-[0-9a-f]\{16\}\.last#\1-<ID>.last#g' \
      -e 's#\(records/[a-z-]*\)-[0-9a-f]\{16\}-\([0-9a-f]\{64\}\.json\)#\1-<ID>-\2#g' "$BT_OUT"
}
# the three stops: a session script on the stop-list, a kind on the stop-list, a Stops: none script held only by mode manual
mk_cases() {
  W=$(fresh); ST="$W/state"; git init -q "$W"          # a project: keep needs the project's root
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
# no_sign_line <label> — nothing in what go printed is a sign command, a mode command or the lines that carried one; the mode
# words are built here, at run time
no_sign_line() {
  local out m=mo; out=$(cat "$BT_OUT"); m="${m}de"
  hasnt "$out" "sign --by owner" "$1: no 'sign --by owner' anywhere in the output"
  hasnt "$out" "baton.py $m" "$1: no $m command of the entry"
  hasnt "$out" "baton $m" "$1: no $m command named"
  hasnt "$out" "$m <answer>" "$1: no $m question"
  hasnt "$out" "on the owner's go:" "$1: no \"on the owner's go:\" line"
  [ "$(grep -c '^then: ' "$BT_OUT")" = 0 ] && ok "$1: no 'then:' line" || bad "$1: no 'then:' line"
  hasnt "$out" "baton.py run " "$1: no run command"
  hasnt "$out" "--queue" "$1: no go --queue offered"
}

# no_params_step <label> — the one step a session script without Params gets in a pod, and nothing to hand over yet
no_params_step() {
  has "$(cat "$BT_OUT")" "this script cannot be handed over yet: add a \`# Params:\` header" "$1: no Params, so the step is to add them"
  has "$(cat "$BT_OUT")" "then \`go\` on it again with key=value args; that \`go\` prints the hand-off" "$1: …then go again"
  hasnt "$(cat "$BT_OUT")" "hand the call to the coordinator" "$1: no hand-off to follow yet"
  hasnt "$(cat "$BT_OUT")" " pack " "$1: no pack step for bytes that must change first"
  hasnt "$(cat "$BT_OUT")" "seal " "$1: no seal that the edit would make stale"
}
# coordinator_call — the line that names the call for the coordinator (its args are the caller's values, as rehearsed)
coordinator_call() { grep 'tell the coordinator the call' "$BT_OUT"; }

fam_pod() {
  local P=$1 W kase seal m
  mk_cases; BT_ENV=("${POD[@]}")
  for kase in script kind manual; do
    run_case "$P" "$W" "$kase"
    eq "$RC" 8 "[P] $kase: exit 8 in a pod"
    case "$(head -n 1 "$BT_OUT")" in "== OWNER DECISION: "*) ok "[P] $kase: the output starts with the card";; *) bad "[P] $kase: the output starts with the card";; esac
    no_sign_line "[P] $kase"
    has "$(tail -n 1 "$BT_OUT")" "go: stopped after rehearse (exit 8, waiting for the owner)" "[P] $kase: the last line is go's stop line"
    if [ "$kase" != kind ]; then no_params_step "[P] $kase"; continue; fi   # no Params: sent back to go, no seal to hand over yet
    has "$(cat "$BT_OUT")" "hand the call to the coordinator" "[P] $kase: the hand-off is printed"
    seal=$(grep -o -m1 '[0-9a-f]\{16\}\.[0-9a-f]\{16\}' "$BT_OUT" | head -n 1)
    nonempty "$seal" "[P] $kase: a seal is printed"
    has "$(grep -c "seal $seal" "$BT_OUT")" 1 "[P] $kase: the seal is named once, in the call to hand over"
  done
  mkb_params "$P" "$W/pp.sh"
  eq "$(bt "$P" "$W" go "$W/pp.sh" dest="$W/dst")" 8 "[P] params: exit 8 in a pod"
  has "$(cat "$BT_OUT")" "pack $W/pp.sh project:pp" "[P] params: step 1 is the pack command, as project:pp"
  has "$(cat "$BT_OUT")" "commit .vibemaestro/batons/pp.sh on your branch and open the PR" "[P] params: step 2 names the file and the PR"
  has "$(cat "$BT_OUT")" "name project:pp, args dest=$W/dst, seal " "[P] params: the call names project:pp, the args and the seal"
  has "$(cat "$BT_OUT")" "(of this copy)" "[P] params: the seal is said to be of this copy"
  hasnt "$(cat "$BT_OUT")" "never ran" "[P] params: a stop-list keep is not said to be one that never ran"
  hasnt "$(cat "$BT_OUT")" "a \`# Params:\` header" "[P] params: no Params advice for a baton that declares them"
  eq "$(coordinator_call | sed 's/.*the call: name \([^,]*\), args .*/\1/')" project:pp "[P] params: the call's name is project:pp, no pod path"
  no_sign_line "[P] params"
  run_case "$P" "$W" kind
  has "$(cat "$BT_OUT")" "name kind:settings-merge, args $W/settings.json $W/rules.json, seal " "[P] kind: the call names kind:settings-merge, the args and the seal"
  hasnt "$(cat "$BT_OUT")" " pack " "[P] kind: nothing to pack"
  python3 "$HERE/fixtures/baton_params.py" make "$P" "$W/pn.sh" "dest=path" "{dest}/** — the file"   # Stops: none, Params
  eq "$(bt "$P" "$W" go "$W/pn.sh" dest="$W/dst")" 8 "[P] manual params: exit 8 in a pod (mode manual)"
  no_sign_line "[P] manual params"
  has "$(cat "$BT_OUT")" "pack $W/pn.sh project:pn" "[P] manual params: step 1 is the pack command, as project:pn"
  has "$(cat "$BT_OUT")" "commit .vibemaestro/batons/pn.sh on your branch and open the PR" "[P] manual params: step 2 names the file and the PR"
  has "$(coordinator_call)" "name project:pn, args dest=$W/dst, seal " "[P] manual params: the call names project:pn, the args and the seal"
  has "$(coordinator_call)" "it never ran" "[P] manual params: the call says it never ran"
  has "$(coordinator_call)" "the coordinator's go is its first run" "[P] manual params: …so the coordinator's go is its first run"
  eq "$(coordinator_call | sed 's/.*the call: name \([^,]*\), args .*/\1/')" project:pn "[P] manual params: the call's name is project:pn, no pod path"
  [ ! -e "$W/.vibemaestro/batons/pn.sh" ] && ok "[P] manual params: go kept nothing" || bad "[P] manual params: go kept nothing"
  # [K] the keep the hand-off names: in the pod, project: only, on the mode-manual stop; never outside a pod
  BT_ENV=()
  eq "$(bt "$P" "$W" pack "$W/pn.sh" project:pn)" 3 "[K] outside a pod: pack refuses the Stops: none bytes that never ran"
  has "$(cat "$BT_OUT")" "no ok run of these bytes" "[K] outside a pod: …as no ok run"
  BT_ENV=("${POD[@]}")
  eq "$(bt "$P" "$W" pack "$W/pn.sh" project:pn)" 0 "[K] pod: pack keeps the Stops: none bytes on the mode-manual stop"
  has "$(cat "$BT_OUT")" "kept project:pn (new) — Stops none" "[K] pod: kept as project:pn, Stops none"
  has "$(cat "$BT_OUT")" "— it never ran: Stops none, held only by a sandbox pod's mode manual, so the coordinator's go is its first run —" "[K] pod: the pack line says it never ran"
  has "$(cat "$ST"/vibemaestro/baton/kept/*/pn/000001.json)" '"never_ran": "it never ran' "[K] pod: the keep record says it never ran"
  # a Stops line of commas only declares no stop either: the same keep, marked the same way
  python3 "$HERE/fixtures/baton_params.py" make "$P" "$W/pc.sh" "dest=path" "{dest}/** — the file"
  sed -i 's/^# Stops: none$/# Stops: ,/' "$W/pc.sh"
  eq "$(bt "$P" "$W" go "$W/pc.sh" dest="$W/dst")" 8 "[K] pod: Stops: , stops in mode manual: exit 8"
  has "$(coordinator_call)" "it never ran" "[K] pod: Stops: , …the call says it never ran"
  eq "$(bt "$P" "$W" pack "$W/pc.sh" project:pc)" 0 "[K] pod: Stops: , …pack keeps it"
  has "$(cat "$BT_OUT")" "it never ran" "[K] pod: Stops: , …its pack line says it never ran"
  hasnt "$(cat "$BT_OUT")" "the owner signs after merge" "[K] pod: Stops: , …and not that the owner signs it"
  has "$(cat "$ST"/vibemaestro/baton/kept/*/pc/000001.json)" '"never_ran"' "[K] pod: Stops: , …its keep record says it never ran"
  # a basename pack refuses (a kit's name) is not handed over as the call's name
  python3 "$HERE/fixtures/baton_params.py" make "$P" "$W/gh-write.sh" "dest=path" "{dest}/** — the file"
  eq "$(bt "$P" "$W" go "$W/gh-write.sh" dest="$W/dst")" 8 "[P] kit-named script: exit 8 in a pod"
  has "$(coordinator_call)" "name project:<name>," "[P] kit-named script: the call leaves the name to pick"
  hasnt "$(cat "$BT_OUT")" "project:gh-write" "[P] kit-named script: no project:gh-write that pack would refuse"
  python3 "$HERE/fixtures/baton_params.py" make "$P" "$W/fix-v2.sh" "dest=path" "{dest}/** — the file"
  eq "$(bt "$P" "$W" go "$W/fix-v2.sh" dest="$W/dst")" 8 "[P] copy-named script: exit 8 in a pod"
  has "$(coordinator_call)" "name project:<name>," "[P] copy-named script: the call leaves the name to pick"
  [ -f "$W/.vibemaestro/batons/pn.sh" ] && ok "[K] pod: the file is in the project" || bad "[K] pod: the file is in the project"
  python3 "$HERE/fixtures/baton_params.py" make "$P" "$W/pq.sh" "dest=path" "{dest}/** — the file"
  printf '\n' >> "$W/pq.sh"                           # other bytes, no stop logged for them
  eq "$(bt "$P" "$W" pack "$W/pq.sh" project:pq)" 3 "[K] pod: Stops: none bytes with no logged stop are refused"
  hasnt "$(cat "$BT_OUT")" "kept " "[K] pod: …and nothing is kept"
  # [R] rehearse in a pod: the verdict, then one line that go hands the call over
  local r c
  for c in "$W/stop.sh $W/o.txt hello" "$W/plain.sh $W/o.txt hello" "$W/pp.sh dest=$W/dst"; do
    # shellcheck disable=SC2086  # the case's words, split on purpose
    r=$(bt "$P" "$W" rehearse $c)
    eq "$r" 0 "[R] rehearse ${c%% *}: rc 0 in a pod"
    no_sign_line "[R] rehearse ${c%% *}"
    eq "$(tail -n 1 "$BT_OUT")" "rehearse ok. In a sandbox pod nobody signs as the owner: when this call needs the owner, go on it hands it to the coordinator" "[R] rehearse ${c%% *}: the last line hands the call to go"
    has "$(cat "$BT_OUT")" "seal " "[R] rehearse ${c%% *}: the verdict keeps its seal line"
  done
  eq "$(bt "$P" "$W" go --nope "$W/stop.sh")" 64 "[P] go's usage in a pod: rc 64"
  m=mo; m="${m}de"                                    # built at run time
  hasnt "$(cat "$BT_OUT")" "sign --by owner" "[P] go's usage in a pod: no 'sign --by owner'"
  hasnt "$(cat "$BT_OUT")" "baton.py $m" "[P] go's usage in a pod: no $m command"
  eq "$(bt "$P" "$W" go --queue "$W/stop.sh" "$W/o.txt" hello)" 64 "[P] go --queue in a pod: refused, rc 64"
  hasnt "$(cat "$BT_OUT")" "sign --by owner" "[P] go --queue in a pod: no sign line in the refusal"
  nsig=$(find "$ST/vibemaestro/baton/signatures" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
  eq "$nsig" 0 "[P] nothing was signed"
  [ ! -e "$W/o.txt" ] && ok "[P] nothing was written" || bad "[P] nothing was written"
}

fam_nopod() {
  local P=$1 W kase
  mk_cases; BT_ENV=()
  for kase in rehearse-script rehearse-manual; do
    case "$kase" in
      rehearse-script) RC=$(bt "$P" "$W" rehearse "$W/stop.sh" "$W/o.txt" hello);;
      rehearse-manual) RC=$(bt "$P" "$W" rehearse "$W/plain.sh" "$W/o.txt" hello);;
    esac
    eq "$RC" 0 "[G] $kase: rc 0 outside a pod"
    if [ -n "${GOLDEN_WRITE:-}" ]; then mkdir -p "$GOLDEN"; norm "$P" "$W" > "$GOLDEN/$kase.txt"; fi
    has "$(cat "$BT_OUT")" "rehearse ok. After the owner's go: " "[G] $kase: the owner's line is printed"
    if [ -f "$GOLDEN/$kase.txt" ] && [ "$(norm "$P" "$W")" = "$(cat "$GOLDEN/$kase.txt")" ]; then ok "[G] $kase: the output equals the golden"
    else bad "[G] $kase: the output equals the golden ($(norm "$P" "$W" | diff - "$GOLDEN/$kase.txt" 2>&1 | head -n 4 | tr '\n' '|'))"; fi
  done
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
BRK rehearse-pod-off fam_pod '[R] rehearse' '    if in_sandbox():                                    # a pod has no owner: its guard' '    if False:                                    # a pod has no owner: its guard'
BRK rehearse-pod-everywhere fam_nopod '[G] rehearse-script: the output equals the golden' '    if in_sandbox():                                    # a pod has no owner: its guard' '    if True:                                    # a pod has no owner: its guard'
BRK usage-sign-in-pod fam_pod "[P] go's usage in a pod: no 'sign --by owner'" '("" if in_sandbox() else "the owner signs' '("" if False else "the owner signs'
BRK handoff-kit-name fam_pod '[P] kit-named script: the call leaves the name to pick' 'name not in kit_names() and' 'True and'
BRK handoff-copy-name fam_pod '[P] copy-named script: the call leaves the name to pick' '                not COPY_NAME.search(name) else' '                True else'
BRK no-stop-words fam_pod '[K] pod: Stops: , …its pack line says it never ran' '    return s is not None and not set(s.split(", ")) - {"none", ""}' '    return s == "none"'
BRK pack-manual-anywhere fam_pod '[K] outside a pod: pack refuses' '    if not (in_sandbox() and t.kept.prefix == "project" and stops_of(t.text) is not None):' '    if not (t.kept.prefix == "project" and stops_of(t.text) is not None):'

echo "== nothing written outside the scratch tree =="
eq "$(tree_hash "$SRC_ROOT")" "$H0" "the repository tree is unchanged by the suite"
echo; summary
