#!/bin/bash
# =============================================================================
# kit:coordinator-bootstrap: the coordinator bootstrap as one owner-signed kit run, on fake machines in one temp dir
# =============================================================================
# Run: bash tests/test-coordinator-bootstrap.sh
#
# A machine is a scratch HOME with its own Claude
# Code directory (CLAUDE_CONFIG_DIR), state directory (XDG_STATE_HOME) and project, and a copy of the plugin under test in its
# plugin cache with a registry entry, so the launcher the run installs accepts it; a fake `gh` answers `auth status`. Families:
#   [F] a fresh machine (no settings, no launcher): go stops for the owner; signed and run, permissions --check is rc 0, the
#       mode stays manual, the rules added are exactly the printed block; run again: refused, nothing to do, nothing changed
#   [B] machines already set up, or with settings of their own: refused byte for byte, or merged with every other key, rule and
#       explicit attribution value kept
#   [U] undo through baton's own path (a copy whose post-check fails): the settings and the launcher come back byte for byte, a
#       created settings file goes again; a settings file that changed since the run is left alone (rc 5)
#   [R] a merge that cannot reach permissions --check rc 0 is refused at rehearse; nothing written
#   [G] the report: a dependent plugin's lines only when it is installed (the fixture tests/fixtures/dependent-plugin), and only
#       its CHECK lines; a plugin that does not declare the dependency adds none; no path under the machine's home in a CHECK line
# Then each planted break (the brief's mutant first: an undo that does not restore) on its own copy must turn its family red.
# Assertions read exit codes, files, sha256 and JSON; of the output only the CHECK names, REFUSE and the baton verdict lines.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
# shellcheck source=fixtures/ports.sh
. "$HERE/fixtures/ports.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
DEP="$SRC_ROOT/tests/fixtures/dependent-plugin"; DEPN=dependent-fixture
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
export PYTHONDONTWRITEBYTECODE=1
H0=$(tree_hash "$SRC_ROOT")

FB="$TMP/fakebin"; mkdir -p "$FB"
printf '#!/bin/sh\n[ "$1 $2" = "auth status" ] && exit "${FAKE_GH_AUTH:-0}"\necho "fake gh: unexpected $*" >&2; exit 2\n' > "$FB/gh"
chmod +x "$FB/gh"; PATH="$FB:$PATH"; export PATH

OUT="$TMP/out"; M=""; MP=""
sha_of() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"; }
# version_of <plugin dir> — the cache directory Claude Code would name: the manifest version, else a commit SHA (the private kit
# carries no version: a git marketplace keys the install by its commit; $SUBDIR, when set, names it as a git-subdir source does)
version_of() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version") or sys.argv[2])' "$1/.claude-plugin/plugin.json" "${SUBDIR:-4dc7de6c9e01}"; }
# unversioned <plugin dir> <new dir> — a copy whose manifest carries no `version` (the private kit's shape)
unversioned() {
  cp -R "$1" "$2"
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d.pop("version", None); json.dump(d, open(p, "w"), indent=2)' "$2/.claude-plugin/plugin.json"
}
# machine <plugin copy> [dependent plugin copy] — a new fake machine in $M with the plugin installed in its cache ($MP); $DEPDIR,
# when set, names the dependent plugin's directory
machine() {
  local base v g
  M="$(fresh)/m"; base="$M/home/.claude/plugins/cache/vibemaestro"
  mkdir -p "$M/state" "$M/proj" "$base/vibemaestro-sdlc"
  v=$(version_of "$1"); MP="$base/vibemaestro-sdlc/$v"; cp -R "$1" "$MP"
  if [ -n "${2:-}" ]; then
    g="$base/$DEPN/${DEPDIR:-$(version_of "$2")}"; mkdir -p "$(dirname "$g")"; cp -R "$2" "$g"
    printf '{"version": 2, "plugins": {"vibemaestro-sdlc@vibemaestro": [{"installPath": "%s"}], "%s@vibemaestro": [{"installPath": "%s"}]}}\n' "$MP" "$DEPN" "$g" \
      > "$M/home/.claude/plugins/installed_plugins.json"
  else
    printf '{"version": 2, "plugins": {"vibemaestro-sdlc@vibemaestro": [{"installPath": "%s"}]}}\n' "$MP" > "$M/home/.claude/plugins/installed_plugins.json"
  fi
}
SETTINGS() { printf '%s' "$M/home/.claude/settings.json"; }
LAUNCHER() { printf '%s' "$M/state/vibemaestro/baton/bin/baton"; }
# b <baton args...> — rc of the machine's own baton.py, run from its project; the output is in $OUT
b() {
  ( cd "$M/proj" && cenv HOME="$M/home" CLAUDE_CONFIG_DIR="$M/home/.claude" XDG_STATE_HOME="$M/state" CLAUDE_PROJECT_DIR="$M/proj" \
      ${FIXTURE_REPORT:+FIXTURE_REPORT="$FIXTURE_REPORT"} ${FAKE_GH_AUTH:+FAKE_GH_AUTH="$FAKE_GH_AUTH"} python3 "$MP/scripts/baton.py" "$@" ) > "$OUT" 2>&1
  echo $?
}
# gate <args...> — rc of the machine's own engine, called directly as a session could; the output is in $OUT
gate() {
  ( cd "$M/proj" && cenv HOME="$M/home" CLAUDE_CONFIG_DIR="$M/home/.claude" XDG_STATE_HOME="$M/state" CLAUDE_PROJECT_DIR="$M/proj" \
      python3 -I -B "$MP/gates/coordinator_bootstrap.py" "$@" ) > "$OUT" 2>&1
  echo $?
}
# gate_in <phase> <plan file> <args...> — gate, with BATON_PHASE and BATON_PLAN set as baton sets them for a phase
gate_in() {
  local ph=$1 pl=$2; shift 2
  ( cd "$M/proj" && cenv HOME="$M/home" CLAUDE_CONFIG_DIR="$M/home/.claude" XDG_STATE_HOME="$M/state" CLAUDE_PROJECT_DIR="$M/proj" \
      BATON_PHASE="$ph" BATON_PLAN="$pl" python3 -I -B "$MP/gates/coordinator_bootstrap.py" "$@" ) > "$OUT" 2>&1
  echo $?
}
# owner_run — rehearse, sign as the owner with the seal shown, run; prints "<sign rc>/<run rc>"
owner_run() {
  local seal s
  b rehearse kit:coordinator-bootstrap >/dev/null
  seal=$(sed -n 's/^seal \([^ ]*\) .*/\1/p' "$OUT")
  s=$(b sign --by owner --seal "${seal:-none}" kit:coordinator-bootstrap)
  printf '%s/%s' "$s" "$(b run kit:coordinator-bootstrap)"
}
# printed — the block `permissions --print` prints on this machine, as JSON (stdout only)
printed() {
  ( cd "$M/proj" && cenv HOME="$M/home" CLAUDE_CONFIG_DIR="$M/home/.claude" XDG_STATE_HOME="$M/state" CLAUDE_PROJECT_DIR="$M/proj" \
      python3 "$MP/scripts/baton.py" permissions --print ) 2>/dev/null
}
# jq_ <file> <python expression over d> — one value of a JSON file
jq_() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }
# set_up_by_hand — what a machine set up before this run holds: the launcher, and the printed block merged into the settings
set_up_by_hand() {
  b permissions --install-launcher >/dev/null
  printed > "$TMP/block.json"
  python3 - "$(SETTINGS)" "$TMP/block.json" <<'PY'
import json, os, sys
path, block = sys.argv[1:3]
s = json.load(open(path)) if os.path.exists(path) else {}
blk = json.load(open(block))
for k, v in blk["permissions"].items():
    have = s.setdefault("permissions", {}).setdefault(k, [])
    have += [x for x in v if x not in have]
s.setdefault("attribution", blk["attribution"])
open(path, "w").write(json.dumps(s, indent=4))
PY
}
# fail_postcheck <plugin copy> [line] — that copy's kit run fails its post-check after doing <line>, so run must undo
fail_postcheck() {
  python3 - "$1/batons/coordinator-bootstrap.sh" "${2:-true}" <<'PY'
import re, sys
p, extra = sys.argv[1:3]
t = open(p).read()
t, n = re.subn(r"\npostcheck\(\) \{\n", "\npostcheck() {\n  %s\n  return 1\n" % extra, t, count=1)
assert n == 1, "no postcheck() in " + p
open(p, "w").write(t)
PY
}

fam_fresh() {
  local P=$1 s l sigs seal
  machine "$P"
  eq "$(b check kit:coordinator-bootstrap)" 0 "[F] check kit:coordinator-bootstrap: rc 0"
  eq "$(b rehearse kit:coordinator-bootstrap)" 0 "[F] rehearse on a fresh machine: rc 0"
  hasline "$(cat "$OUT")" "PLAN-COUNT 2" "[F] …two writes: the launcher and the settings"
  has "$(cat "$OUT")" "CHECK launcher: missing" "[F] …the report names the launcher missing"
  has "$(cat "$OUT")" "CHECK mode: manual" "[F] …and the mode manual"
  eq "$(b go kit:coordinator-bootstrap)" 8 "[F] go: exit 8 (Stops security-boundary: the owner signs)"
  [ ! -e "$(SETTINGS)" ] && [ ! -e "$(LAUNCHER)" ] && ok "[F] …nothing written before the owner's signature" || bad "[F] …nothing written before the owner's signature"
  eq "$(b sign --by coordinator-auto --seal x kit:coordinator-bootstrap)" 3 "[F] the session cannot sign it as coordinator-auto: rc 3"
  eq "$(owner_run)" "0/0" "[F] signed by the owner and run: rc 0"
  eq "$(b permissions --check)" 0 "[F] …permissions --check: rc 0"
  [ -x "$(LAUNCHER)" ] && ok "[F] …the launcher is installed" || bad "[F] …the launcher is installed"
  b mode >/dev/null; eq "$(tail -n 1 "$OUT")" manual "[F] …the mode is still manual"
  [ ! -e "$M/state/vibemaestro/baton/mode" ] && ok "[F] …and the mode file was never written" || bad "[F] …and the mode file was never written"
  printed > "$TMP/printed.json"
  eq "$(jq_ "$(SETTINGS)" 'json.dumps(d, sort_keys=True)')" "$(jq_ "$TMP/printed.json" 'json.dumps(d, sort_keys=True)')" \
     "[F] the added rules equal the printed block exactly (no rule beyond it)"
  s=$(sha_of "$(SETTINGS)"); l=$(sha_of "$(LAUNCHER)"); sigs=$(ls "$M/state/vibemaestro/baton/signatures" | wc -l | tr -d ' ')
  eq "$(b rehearse kit:coordinator-bootstrap)" 1 "[F] run again: the rehearse fails (rc 1)"
  has "$(cat "$OUT")" "REFUSE nothing to do" "[F] …REFUSE nothing to do"
  has "$(cat "$OUT")" "the rehearse phase exited 3" "[F] …the run's own exit is 3"
  eq "$(b go kit:coordinator-bootstrap)" 1 "[F] go again: rc 1, stopped at rehearse"
  eq "$(sha_of "$(SETTINGS)")/$(sha_of "$(LAUNCHER)")" "$s/$l" "[F] …the settings and the launcher are unchanged"
  eq "$(ls "$M/state/vibemaestro/baton/signatures" | wc -l | tr -d ' ')" "$sigs" "[F] …and nothing was signed"
  machine "$P"
  b rehearse kit:coordinator-bootstrap >/dev/null
  has "$(grep '^PLAN bootstrap ' "$OUT")" ", engine sha256 " "[F] every plan line binds the engine's sha256"
  seal=$(sed -n 's/^seal \([^ ]*\) .*/\1/p' "$OUT")
  eq "$(b sign --by owner --seal "${seal:-none}" kit:coordinator-bootstrap)" 0 "[F] a second fresh machine: signed by the owner"
  printf '\n# changed after the signature\n' >> "$MP/gates/coordinator_bootstrap.py"
  eq "$(b run kit:coordinator-bootstrap)" 3 "[F] the engine edited after signing: run refused (rc 3)"
  [ ! -e "$(SETTINGS)" ] && [ ! -e "$(LAUNCHER)" ] && ok "[F] …nothing written" || bad "[F] …nothing written"
  machine "$P"
  b rehearse kit:coordinator-bootstrap >/dev/null
  sed -n 's/^PLAN \(bootstrap .*, engine sha256 \)[0-9a-f]\{64\}$/\1'"$(printf '0%.0s' $(seq 64))"'/p' "$OUT" > "$TMP/wrong-sha.plan"
  eq "$(wc -l < "$TMP/wrong-sha.plan" | tr -d ' ')" 2 "[F] instrument: a plan of both lines with another engine sha256"
  eq "$(gate do settings --expect-plan "$TMP/wrong-sha.plan")" 3 "[F] a write whose signed engine sha256 is not the engine's: refused (rc 3)"
  eq "$(gate do launcher --expect-plan "$TMP/wrong-sha.plan")" 3 "[F] …the launcher write too"
  [ ! -e "$(SETTINGS)" ] && [ ! -e "$(LAUNCHER)" ] && ok "[F] …and nothing written" || bad "[F] …and nothing written"
  eq "$(gate_in run "$TMP/wrong-sha.plan" plan)" 3 "[F] the run phase's plan under another engine sha256: refused (rc 3)"
  eq "$(gate_in rehearse "" plan)" 0 "[F] …control: the rehearse's plan: rc 0"
}

fam_setup() {
  local P=$1 s
  machine "$P"
  printf '{\n    "model": "x",\n    "permissions": {"allow": ["Bash(ls:*)"]}\n}' > "$(SETTINGS)"
  set_up_by_hand
  s=$(sha_of "$(SETTINGS)")
  eq "$(b permissions --check)" 0 "[B] control: the machine set up by hand passes permissions --check"
  eq "$(b rehearse kit:coordinator-bootstrap)" 1 "[B] a machine already set up: rehearse fails"
  has "$(cat "$OUT")" "REFUSE nothing to do" "[B] …REFUSE nothing to do"
  eq "$(sha_of "$(SETTINGS)")" "$s" "[B] …the settings are byte-identical"
  machine "$P"
  printf '{"model": "x", "permissions": {"allow": ["Bash(ls:*)"], "deny": ["Edit(//x/**)"]}, "attribution": {"commit": "custom"}}' > "$(SETTINGS)"
  eq "$(owner_run)" "0/0" "[B] settings of its own: signed and run, rc 0"
  eq "$(jq_ "$(SETTINGS)" 'd["model"], d["permissions"]["allow"][0], d["permissions"]["deny"][0]')" "('x', 'Bash(ls:*)', 'Edit(//x/**)')" \
     "[B] …every other key and rule kept, in place"
  eq "$(jq_ "$(SETTINGS)" 'd["attribution"]["commit"]')" custom "[B] …an explicit attribution value is kept"
  eq "$(jq_ "$(SETTINGS)" 'sorted(d["attribution"])')" "['commit', 'pr', 'sessionUrl']" "[B] …the absent attribution keys are added"
  eq "$(b permissions --check)" 0 "[B] …permissions --check: rc 0"
  machine "$P"
  printf '{"attribution": false}\n' > "$(SETTINGS)"
  eq "$(owner_run)" "0/0" "[B] attribution false: signed and run, rc 0"
  eq "$(jq_ "$(SETTINGS)" 'd["attribution"]')" False "[B] …an explicit false is never flipped"
  machine "$P"
  b permissions --install-launcher >/dev/null; mkdir -p "$M/proj/.claude"; printed > "$TMP/block.json"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); json.dump({"permissions": d["permissions"]}, open(sys.argv[2], "w"))' \
    "$TMP/block.json" "$M/proj/.claude/settings.json"
  printf '{"model": "x"}\n' > "$(SETTINGS)"
  eq "$(owner_run)" "0/0" "[B] rules in force from the project's settings, attribution absent: signed and run, rc 0"
  eq "$(jq_ "$(SETTINGS)" 'sorted(d)')" "['attribution', 'model']" "[B] …only attribution added: no rule again, no empty permissions object"
}

fam_undo() {
  local P=$1 C s l
  C="$P.pcfail"; rm -rf "$C"; cp -R "$P" "$C"; fail_postcheck "$C"
  machine "$C"
  printf '{ "model":"x",\n\t"permissions": {"allow": []} }' > "$(SETTINGS)"
  mkdir -p "$(dirname "$(LAUNCHER)")"; printf '#!/bin/sh\necho old launcher\n' > "$(LAUNCHER)"; chmod 700 "$(LAUNCHER)"
  s=$(sha_of "$(SETTINGS)"); l=$(sha_of "$(LAUNCHER)")
  eq "$(owner_run)" "0/4" "[U] a run whose post-check fails: rc 4, undone"
  eq "$(sha_of "$(SETTINGS)")" "$s" "[U] settings byte-identical after undo"
  eq "$(sha_of "$(LAUNCHER)")" "$l" "[U] the old launcher is back byte for byte"
  printf '#!/bin/sh\necho planted\n' > "$M/state/vibemaestro/baton/records/coordinator-bootstrap-launcher-$l.bak"
  eq "$(owner_run)" "0/4" "[U] a planted backup under the old launcher's name: rc 4, undone"
  eq "$(sha_of "$(LAUNCHER)")" "$l" "[U] …the planted backup is not trusted: the old launcher is back"
  machine "$C"
  eq "$(owner_run)" "0/4" "[U] a fresh machine, post-check fails: rc 4, undone"
  [ ! -e "$(SETTINGS)" ] && ok "[U] …the settings file the run created is gone" || bad "[U] …the settings file the run created is gone"
  [ ! -e "$(LAUNCHER)" ] && ok "[U] …the launcher the run installed is gone" || bad "[U] …the launcher the run installed is gone"
  C="$P.pcmove"; rm -rf "$C"; cp -R "$P" "$C"
  fail_postcheck "$C" 'printf " " >> "$CLAUDE_CONFIG_DIR/settings.json"'
  machine "$C"
  printf '{"permissions": {}}\n' > "$(SETTINGS)"
  eq "$(owner_run)" "0/5" "[U] the settings changed after the run: rc 5, the state left to the owner"
  has "$(cat "$OUT")" "LEAVE" "[U] …the output says what it left"
  eq "$(tail -c 1 "$(SETTINGS)")" " " "[U] …the changed file is left as it is"
  C="$P.pcgone"; rm -rf "$C"; cp -R "$P" "$C"
  fail_postcheck "$C" 'rm -f "$CLAUDE_CONFIG_DIR/settings.json"'
  machine "$C"
  printf '{"permissions": {}}\n' > "$(SETTINGS)"
  eq "$(owner_run)" "0/5" "[U] the settings file deleted after the merge: rc 5, never reported as undone"
  C="$P.pckind"; rm -rf "$C"; cp -R "$P" "$C"
  fail_postcheck "$C" 'printf "\\necho EVIL >> \"\$HOME/kind-ran\"\\n" >> "$BATON_PLUGIN_ROOT/templates/baton-kinds/settings-merge.sh"'
  machine "$C"
  printf '{"permissions": {}}\n' > "$(SETTINGS)"
  eq "$(owner_run)" "0/5" "[U] the kind changed after the run: rc 5, its undo is never run"
  [ ! -e "$M/home/kind-ran" ] && ok "[U] …the changed kind never ran" || bad "[U] …the changed kind never ran"
  has "$(cat "$OUT")" "LEAVE the engine changed since the signature" "[U] …the output says why it left the merge"
}

fam_unreachable() {
  local P=$1 s
  machine "$P"
  printf '{"permissions": {"allow": ["Bash(*)"]}}\n' > "$(SETTINGS)"
  s=$(sha_of "$(SETTINGS)")
  eq "$(b rehearse kit:coordinator-bootstrap)" 1 "[R] an allow rule that lets sign --by owner through: rehearse fails"
  has "$(cat "$OUT")" "REFUSE adding rules cannot reach permissions --check rc 0" "[R] …refused: the merge cannot reach rc 0"
  has "$(cat "$OUT")" "UNSAFE" "[R] …it names the finding"
  eq "$(sha_of "$(SETTINGS)")" "$s" "[R] …the settings are unchanged"
  [ ! -e "$(LAUNCHER)" ] && ok "[R] …no launcher installed" || bad "[R] …no launcher installed"
}

fam_report() {
  local P=$1 G=$2
  machine "$P"
  FAKE_GH_AUTH=1 b rehearse kit:coordinator-bootstrap >/dev/null
  has "$(cat "$OUT")" "CHECK dependent plugins: none" "[G] without the dependent plugin: no dependent plugin"
  hasnt "$(cat "$OUT")" "CHECK fixture-" "[G] …and none of its lines"
  has "$(cat "$OUT")" "CHECK gh: MISSING" "[G] gh not logged in: CHECK gh: MISSING"
  machine "$P" "$G"
  FIXTURE_REPORT=1 b rehearse kit:coordinator-bootstrap >/dev/null
  has "$(cat "$OUT")" "CHECK $DEPN: $(version_of "$G") (installed; its report follows)" "[G] with the dependent plugin: its version"
  has "$(cat "$OUT")" "CHECK vibemaestro-sdlc: $(version_of "$P") (running; latest installed $(version_of "$P"))" "[G] sdlc at its version directory ($(version_of "$P"): the manifest version, else a SHA): running and latest installed name it"
  has "$(cat "$OUT")" "CHECK fixture-env: ok" "[G] …its line, run in the session's environment"
  has "$(cat "$OUT")" "CHECK fixture-next: info" "[G] …its next line"
  hasnt "$(cat "$OUT")" "fixture noise" "[G] …and not its line without the CHECK prefix"
  hasnt "$(grep '^CHECK ' "$OUT")" "$M/home" "[G] no CHECK line spells the machine's home"
  b rehearse kit:coordinator-bootstrap >/dev/null
  has "$(cat "$OUT")" "CHECK fixture-env: MISSING" "[G] …the same line without its variable"
  python3 - "$M/home/.claude/plugins/cache/vibemaestro/$DEPN/$(version_of "$G")/.claude-plugin/plugin.json" <<'PY2'
import json, sys
m = json.load(open(sys.argv[1])); m.pop("dependencies", None); json.dump(m, open(sys.argv[1], "w"))
PY2
  FIXTURE_REPORT=1 b rehearse kit:coordinator-bootstrap >/dev/null
  hasnt "$(cat "$OUT")" "CHECK fixture-" "[G] a plugin that does not declare the dependency adds no line"
  # two sdlc installs: the registry's latest entry is reported, not the highest number
  machine "$P"; cp -R "$P" "$(dirname "$MP")/9.9.9"
  printf '{"version": 2, "plugins": {"vibemaestro-sdlc@vibemaestro": [{"installPath": "%s", "lastUpdated": "2026-10-20T03:00:00.000Z"}, {"installPath": "%s", "lastUpdated": "2026-10-20T03:05:00.000Z"}]}}\n' \
    "$(dirname "$MP")/9.9.9" "$MP" > "$M/home/.claude/plugins/installed_plugins.json"
  b rehearse kit:coordinator-bootstrap >/dev/null
  has "$(cat "$OUT")" "(running; latest installed $(version_of "$P"))" "[G] two installs: the registry's latest ($(version_of "$P")), not the highest number 9.9.9"
  # a git-subdir plugin source (measured 22/10): both install directories are <12 hex>-<8 hex>, the suffix differs per plugin. That is
  # the private kit, whose manifests carry no version: copies without one, so a released tree (sdlc 0.1.0) gives the same case
  local PU GU; PU="$(fresh)/sdlc"; GU="$(fresh)/dep"; unversioned "$P" "$PU"; unversioned "$G" "$GU"
  SUBDIR=3d15f5b67818-be49dd83 DEPDIR=3d15f5b67818-adc9e2e3 machine "$PU" "$GU"
  case "$MP" in */vibemaestro-sdlc/3d15f5b67818-be49dd83) ok "[G] instrument: sdlc installed at a git-subdir directory" ;; *) bad "[G] instrument: sdlc installed at a git-subdir directory" ;; esac
  FIXTURE_REPORT=1 b rehearse kit:coordinator-bootstrap >/dev/null
  has "$(cat "$OUT")" "CHECK vibemaestro-sdlc: 3d15f5b67818-be49dd83 (running; latest installed 3d15f5b67818-be49dd83)" "[G] sdlc at a git-subdir directory: running and latest installed name it"
  has "$(cat "$OUT")" "CHECK $DEPN: 3d15f5b67818-adc9e2e3 (installed; its report follows)" "[G] a dependent plugin at a git-subdir directory: listed with its version"
}

# fam_hook — a dependent plugin's hook is not code the signature binds: it runs at rehearse only, and its lines lose control bytes
fam_hook() {
  local P=$1 G=$2 h
  machine "$P" "$G"
  h="$M/home/.claude/plugins/cache/vibemaestro/$DEPN/$(version_of "$G")/scripts/bootstrap_report.py"
  cat > "$h" <<'PY2'
import os
with open(os.path.join(os.environ["HOME"], "hook-phases"), "a") as f:
    f.write(os.environ.get("BATON_PHASE", "-") + "\n")
print("CHECK planted: ok \x1b[2Jcleared")
PY2
  b rehearse kit:coordinator-bootstrap >/dev/null
  has "$(cat "$OUT")" "CHECK planted: ok [2Jcleared" "[H] the hook's line is shown at rehearse"
  eq "$(LC_ALL=C grep -c "$(printf '\033')" "$OUT")" 0 "[H] …with its control bytes dropped"
  eq "$(owner_run)" "0/0" "[H] signed by the owner and run: rc 0"
  has "$(cat "$M/home/hook-phases")" "rehearse" "[H] instrument: the hook logs its phase"
  hasnt "$(cat "$M/home/hook-phases")" "run" "[H] the hook never runs in the signed run phase"
}

echo "== the real plugin =="
REAL="$TMP/real"; cp -R "$PLUGIN" "$REAL"; GREAL="$TMP/dependent"; cp -R "$DEP" "$GREAL"
for fam in fam_fresh fam_setup fam_undo fam_unreachable; do echo "-- $fam"; "$fam" "$REAL"; done
echo "-- fam_report"; fam_report "$REAL" "$GREAL"
echo "-- fam_hook"; fam_hook "$REAL" "$GREAL"

echo "== planted breaks: each family must go red on a plugin copy with one break =="
# BRK <label> <family> <needle> <file under the plugin> <old> <new>
BRK() {
  local label=$1 fam=$2 needle=$3 d; d="$TMP/break-$label"; cp -R "$PLUGIN" "$d"
  mutate "$d/$4" "$5" "$6" && expect_red "$label" "$fam" "$d" "$needle"
}
fam_hook_g() { fam_hook "$1" "$GREAL"; }
fam_report_g() { fam_report "$1" "$GREAL"; }
BRK undo-does-not-restore fam_undo '[U] settings byte-identical after undo' gates/coordinator_bootstrap.py \
    '            rc, out = kind("undo", user, rules)' '            rc, out = 0, ["VERDICT undo ok"]'
BRK nothing-to-do-runs fam_fresh '[F] …REFUSE nothing to do' gates/coordinator_bootstrap.py \
    '    if not p.lines:' '    if False:'
BRK extra-allow-rule fam_fresh '[F] the added rules equal the printed block exactly' gates/coordinator_bootstrap.py \
    '    rules["attribution"] = snip["attribution"]' '    rules["attribution"] = snip["attribution"]; rules["allow"] = rules.get("allow", []) + ["Bash(curl:*)"]'
BRK attribution-flipped fam_setup '[B] …an explicit attribution value is kept' templates/baton-kinds/settings-merge.sh \
    '        have.update((k, attr[k]) for k in new)' '        have.update(attr)'
BRK unreachable-merged fam_unreachable '[R] …refused: the merge cannot reach rc 0' gates/coordinator_bootstrap.py \
    '    if after:' '    if False:'
BRK engine-unbound fam_fresh '[F] the engine edited after signing: run refused (rc 3)' batons/coordinator-bootstrap.sh \
    '  code=$(engine_sha)' '  code=unbound'
BRK backup-trusted fam_undo '[U] …the planted backup is not trusted' gates/coordinator_bootstrap.py \
    '        if not (os.path.isfile(backup) and not os.path.islink(backup) and sha_file(backup) == sha(old)):' '        if not os.path.exists(backup):'
BRK engine-sha-unchecked fam_fresh '[F] a write whose signed engine sha256 is not the engine' gates/coordinator_bootstrap.py \
    '        if p.refusal or len(mine) != 1 or mine[0] + ENGINE_SUFFIX + code not in signed:' \
    '        if p.refusal or len(mine) != 1 or not any(s.startswith(mine[0] + ENGINE_SUFFIX) for s in signed):'
BRK hook-in-run fam_hook_g '[H] the hook never runs in the signed run phase' gates/coordinator_bootstrap.py \
    'hooks=os.environ.get("BATON_PHASE") != "run"' 'hooks=True'
BRK hook-escape fam_hook_g '[H] …with its control bytes dropped' gates/coordinator_bootstrap.py \
    '"".join(c for c in ln if c.isprintable())' 'ln'
BRK kind-unbound-undo fam_undo '[U] …the changed kind never ran' gates/coordinator_bootstrap.py \
    '    kind_ok = bind_kind(signed)' '    kind_ok = bind_kind(signed) or True'
BRK kind-unbound-plan fam_fresh '[F] the run phase' gates/coordinator_bootstrap.py \
    '        if not bind_kind(signed_lines(os.environ.get("BATON_PLAN"))):' '        if False:'
BRK highest-number-reported fam_report_g "[G] two installs: the registry's latest" gates/coordinator_bootstrap.py \
    '            out.append((stamp, -i, v, real))' '            out.append(("", -i, v, real))'
BRK subdir-install-skipped fam_report_g '[G] a dependent plugin at a git-subdir directory' gates/coordinator_bootstrap.py \
    '(?:-[0-9a-f]{8})?|unknown)\Z")' '|unknown)\Z")'
BRK bare-dependency-missed fam_report_g '[G] with the dependent plugin: its version' gates/coordinator_bootstrap.py \
    '    n = d if isinstance(d, str) else d.get("name")' '    n = None if isinstance(d, str) else d.get("name")'
BRK non-check-line-kept fam_report_g '[G] …and not its line without the CHECK prefix' gates/coordinator_bootstrap.py \
    'splitlines() if ln.startswith("CHECK ")]' 'splitlines()]'
BRK home-in-report fam_report_g "[G] no CHECK line spells the machine's home" gates/coordinator_bootstrap.py \
    '    print(("CHECK %s: %s %s" % (name, status, detail)).rstrip())' '    print(("CHECK %s: %s %s %s" % (name, status, detail, os.path.expanduser("~"))).rstrip())'
BRK launcher-not-restored fam_undo '[U] the old launcher is back byte for byte' gates/coordinator_bootstrap.py \
    '        rc = undo_launcher(pid) or rc' '        rc = OK or rc'

echo "== nothing written outside the scratch tree =="
eq "$(tree_hash "$SRC_ROOT")" "$H0" "the repository tree is unchanged by the suite"

echo; summary
