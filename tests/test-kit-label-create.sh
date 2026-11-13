#!/bin/bash
# =============================================================================
# kit:label-create: new labels in one repository, each refused when the repository has it, on a fake GitHub
# =============================================================================
# Run: bash tests/test-kit-label-create.sh
#
# A machine is a scratch home, state directory and project with a copy of the plugin under test, in mode auto; the fake `gh`
# (tests/fixtures/label_create_gh.py) answers the kit's two calls from a JSON world and logs each read and each label it created.
#   [create]          two plan lines, PLAN-COUNT 2, Each matched; go creates both in the given order, the post-check names each
#   [exists-refused]  a name the repository has, its case ignored: rehearse refuses the whole call, nothing created; a name
#                     that lands after the signature, or between two creates: the run refuses it, nothing replaced
#   [half-way]        GitHub fails the second of three: the first stays, the run and its undo name it, never ok
#   [phases]          a repository it cannot read: refused; the post-check and undo of a call where nothing landed
#   [usage]           malformed arguments, shell characters among them: rc 64 naming why, before any read
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

K=kit:label-create
OUT="$TMP/out"; M=""; MP=""

# machine <json labels> [<json fail list>] — a fresh machine in mode auto whose world holds these labels of o/r
machine() {
  M=$(fresh); MP="$M/plugin"; mkdir -p "$M/home" "$M/state" "$M/proj" "$M/bin"
  mk_plugin_copy "$MP"
  baton_set_mode "$M/state" auto
  printf '{"labels": {"o/r": %s}, "fail": %s}' "$1" "${2:-[]}" > "$M/world.json"
  : > "$M/labels.log"
  printf '#!/bin/sh\nexec python3 -I -B "%s" "%s" "%s" "$@"\n' "$HERE/fixtures/label_create_gh.py" "$M/world.json" "$M/labels.log" > "$M/bin/gh"
  chmod +x "$M/bin/gh"
}
# wset <python statement over w> — change the world (the test's input, not a break)
wset() { python3 -c 'import json, sys; p = sys.argv[1]; w = json.load(open(p)); exec(sys.argv[2]); json.dump(w, open(p, "w"))' "$M/world.json" "$1"; }
# b <baton args...> — rc of the machine's baton.py, run from its project with the fake gh first on PATH; the output is in $OUT
b() {
  ( export PATH="$M/bin:$PATH"; cd "$M/proj" && cenv HOME="$M/home" CLAUDE_CONFIG_DIR="$M/home/.claude" XDG_STATE_HOME="$M/state" \
      CLAUDE_PROJECT_DIR="$M/proj" CLAUDE_CODE_SESSION_ID=s-1 python3 "$MP/scripts/baton.py" "$@" ) > "$OUT" 2>&1
  echo $?
}
# bc <baton args...> — b for a call that must be refused or fail: through capped (tests/fixtures/capped.sh), as a negative case runs
bc() { capped b "$@"; }
created() { grep '^create ' "$M/labels.log" || true; }
labels_of() { python3 -c 'import json, sys; print(" ".join(json.load(open(sys.argv[1]))["labels"]["o/r"]))' "$M/world.json"; }
# runlog — the full output of the last quiet `go` (its last line names the file)
runlog() { cat "$(sed -n 's/^go: .* — \(\/.*\.log\)$/\1/p' "$OUT")"; }

fam_create() {
  machine '["bug"]'
  eq "$(b check "$K")" 0 "[create] check kit:label-create: rc 0"
  eq "$(b rehearse "$K" o/r type:story area/ui+x.y_z-1)" 0 "[create] rehearse: rc 0"
  hasline "$(sed 's/^ *//' "$OUT")" "PLAN label-create o/r type:story" "[create] …the first plan line"
  hasline "$(sed 's/^ *//' "$OUT")" "PLAN label-create o/r area/ui+x.y_z-1" "[create] …the second, every allowed character kept"
  hasline "$(sed 's/^ *//' "$OUT")" "PLAN-COUNT 2" "[create] …PLAN-COUNT 2"
  eq "$(grep -c '^ *ok  *label-create .*  ~  label-create \*$' "$OUT")" 2 "[create] …each plan line matches Each label-create *"
  empty "$(created)" "[create] …rehearse created nothing"
  eq "$(b go "$K" o/r type:story area/ui+x.y_z-1)" 0 "[create] go (Stops none, mode auto): rc 0"
  eq "$(created)" "create o/r type:story
create o/r area/ui+x.y_z-1" "[create] …both created, in the given order"
  eq "$(labels_of)" "bug type:story area/ui+x.y_z-1" "[create] …the existing label untouched"
  hasline "$(runlog | sed 's/^ *//')" "o/r has label area/ui+x.y_z-1" "[create] …the post-check reads each one back"
}

fam_exists() {
  machine '["bug", "Type:Story"]'
  eq "$(bc go "$K" o/r focus:P8 type:story)" 1 "[exists-refused] a name the repository has, in another case: go rc 1"
  has "$(cat "$OUT")" "REFUSE o/r has a label type:story already (case ignored): nothing to create, nothing to sign" "[exists-refused] …names it"
  has "$(cat "$OUT")" "the rehearse phase exited 3" "[exists-refused] …the kit's own exit is 3"
  empty "$(created)" "[exists-refused] …nothing created, not even the name before it"
  machine '["bug"]'
  local seal
  b rehearse "$K" o/r focus:P8 type:task >/dev/null; seal=$(sed -n 's/^seal \([^ ]*\) .*/\1/p' "$OUT")
  eq "$(b sign --by coordinator-auto --seal "${seal:-none}" "$K" o/r focus:P8 type:task)" 0 "[exists-refused] signed while neither exists"
  wset 'w["labels"]["o/r"].append("TYPE:TASK")'
  eq "$(bc run "$K" o/r focus:P8 type:task)" 3 "[exists-refused] one landed after the signature: run rc 3"
  has "$(cat "$OUT")" "REFUSE o/r has a label type:task already (case ignored)" "[exists-refused] …refused before any create"
  empty "$(created)" "[exists-refused] …nothing created"
  eq "$(labels_of)" "bug TYPE:TASK" "[exists-refused] …nothing replaced"
  machine '["bug"]'
  wset 'w["then_add"] = {"type:story": "FOCUS:P8"}'
  eq "$(bc go "$K" o/r type:story focus:P8)" 5 "[exists-refused] one lands between two creates: go rc 5, the state unknown"
  has "$(cat "$OUT")" "REFUSE o/r has a label focus:P8 now (case ignored): nothing replaced" "[exists-refused] …read again before its create"
  eq "$(created)" "create o/r type:story" "[exists-refused] …only the one before it created"
  eq "$(labels_of)" "bug type:story FOCUS:P8" "[exists-refused] …the other hand's label untouched"
}

fam_half_way() {
  machine '["bug"]' '["focus:P8"]'
  eq "$(bc go "$K" o/r type:story focus:P8 type:task)" 5 "[half-way] GitHub fails the second: go rc 5, the state unknown"
  eq "$(created)" "create o/r type:story" "[half-way] …the first created, the third never tried"
  has "$(cat "$OUT")" "STOPPED at label focus:P8 (it may have landed: the undo reads the labels again); created before the stop: type:story" \
      "[half-way] …the run names the one created"
  has "$(cat "$OUT")" "LEAVE labels type:story in o/r: deleting a label removes it from every issue that carries it, an act the owner signs" \
      "[half-way] …the undo names it and deletes nothing"
  eq "$(labels_of)" "bug type:story" "[half-way] …the label stays"
  hasnt "$(cat "$OUT")" "run ok" "[half-way] …never run ok"
}

# kit <phase> <args...> — the kit's own phase, run directly with the fake gh first on PATH; rc, output in $OUT
kit() { local ph=$1; shift; ( export PATH="$M/bin:$PATH"; BATON_PHASE=$ph bash "$PLUGIN/batons/label-create.sh" "$@" ) > "$OUT" 2>&1; echo $?; }

fam_phases() {
  machine '["bug"]'
  eq "$(bc rehearse "$K" q/r type:story)" 1 "[phases] a repository it cannot read: rehearse rc 1"
  has "$(cat "$OUT")" "REFUSE cannot read the labels of q/r" "[phases] …names it"
  has "$(cat "$OUT")" "the rehearse phase exited 3" "[phases] …the kit's own exit is 3"
  eq "$(kit postcheck o/r type:story)" 1 "[phases] post-check of a label that is not there: rc 1"
  has "$(cat "$OUT")" "o/r has no label type:story" "[phases] …names it"
  eq "$(kit undo o/r type:story)" 0 "[phases] undo when none landed: rc 0"
  has "$(cat "$OUT")" "no label of the call is in o/r: nothing to undo" "[phases] …says so"
  eq "$(kit undo q/r type:story)" 1 "[phases] undo on a repository it cannot read: rc 1"
  has "$(cat "$OUT")" "LEAVE cannot read the labels of q/r: which labels landed is unknown" "[phases] …says what it cannot know"
  empty "$(created)" "[phases] nothing created"
}

# usage_case <label> <needle> <args...> — rehearse refused with the kit's rc 64, naming why
usage_case() {
  local label=$1 needle=$2; shift 2
  eq "$(bc rehearse "$K" "$@")" 1 "[usage] $label: rc 1"
  has "$(cat "$OUT")" "the rehearse phase exited 64" "[usage] …$label: the kit's exit is 64"
  has "$(cat "$OUT")" "$needle" "[usage] …$label: names why"
}
fam_usage() {
  local many=() i long=a
  machine '["bug"]'
  for i in $(seq 1 21); do many+=("l$i"); done
  for i in $(seq 1 50); do long="${long}b"; done
  usage_case "no repository" "REFUSE no repository named"
  usage_case "no label" "REFUSE no label named" o/r
  usage_case "not owner/name" "REFUSE repository must be owner/name: r" r type:story
  usage_case "three parts" "REFUSE repository must be owner/name: o/r/x" o/r/x type:story
  usage_case "a parent directory" "REFUSE repository must be owner/name: ../x" ../x type:story
  usage_case "a name of .." "REFUSE repository must be owner/name: o/.." o/.. type:story
  usage_case "an option-shaped repository" "REFUSE repository must be owner/name: -o/r" -o/r type:story
  usage_case "a command substitution" 'REFUSE not a label name: x$(touch pwned)' o/r 'x$(touch pwned)'
  usage_case "a semicolon" "REFUSE not a label name: a;b" o/r ok 'a;b'
  usage_case "a space" "REFUSE not a label name: good first issue" o/r 'good first issue'
  usage_case "a quote" "REFUSE not a label name: it's" o/r "it's"
  usage_case "an option-shaped name" "REFUSE not a label name: -f" o/r -f
  usage_case "a gh option" "REFUSE not a label name: --jq" o/r --jq
  usage_case "a newline" "REFUSE not a label name: ab" o/r $'a\nb'
  eq "$(grep -c '^ *REFUSE' "$OUT")" 1 "[usage] …the refusal of a name with a newline is one line"
  usage_case "51 characters" "REFUSE a label name is at most 50 characters: $long" o/r "$long"
  usage_case "the same name twice, case ignored" "REFUSE Type:Story is named twice (case ignored)" o/r type:story Type:Story
  usage_case "21 names" "REFUSE more than 20 labels in one run" o/r "${many[@]}"
  has "$(cat "$OUT")" "(1 to 20 names; a name is 1 to 50 of A-Z a-z 0-9 : . _ / + -, starting with a letter or digit)" \
      "[usage] the usage line names the bounds and the characters"
  empty "$(cat "$M/labels.log")" "[usage] nothing created, no label even read"
  eq "$(find "$M" -name pwned | wc -l | tr -d ' ')" 0 "[usage] the command substitution never ran"
}

fam_create
fam_exists
fam_half_way
fam_phases
fam_usage

echo "== nothing written outside the scratch tree =="
eq "$(tree_hash "$SRC_ROOT")" "$H0" "the repository tree is unchanged by the suite"

echo; summary
