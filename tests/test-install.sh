#!/bin/bash
# =============================================================================
# Kit — install the plugins from the marketplace: vibemaestro-brain and a plugin that depends on vibemaestro-sdlc each bring
# sdlc, and the dependent plugin's rules reach the session
# =============================================================================
# Run: bash tests/test-install.sh
#      PLUGIN_REQUIRE_CLAUDE=1 bash …   # no `claude` is RED (default: the CLI part is SKIPPED, loudly)
#
# The dependent plugin is the fixture tests/fixtures/dependent-plugin (`dependent-fixture`: sdlc named bare, one rule on
# clusters/**, no hooks), added to the marketplace of each COPY of the repo, never to the real one.
# PART 1, static (no `claude`): the two manifests and the marketplace (sdlc, then brain), the fixture's manifest, rule and no hooks.
# PART 2, CLI (`claude`, no login, no model): on a COPY of the repo, each case with its own CLAUDE_CONFIG_DIR, so `~/.claude` and
#   the repo tree are never touched.
#   [V] `claude plugin validate` on the marketplace and the plugins: the only warning is the missing version (the private repo carries
#       none); `--strict` on the public form (version 0.1.0, the range >=0.1.0, as the export writes them); control: a broken
#       manifest fails
#   [A] config A: installing the dependent plugin prints `(+ 1 dependency: vibemaestro-sdlc)`, 2 enabled, sdlc recorded as
#       auto-installed
#   [P] the REAL rule-pack path: the hooks of the CACHED sdlc, run by the `command` strings of its hooks.json, name the dependent
#       plugin's rule on an edit under clusters/, not on another edit; uninstalling the plugin removes it
#   [B] config B: sdlc alone: no dependency line, 1 plugin, no pack rule
#   [C] config C: a dependent copy whose bound sdlc cannot meet installs with rc 0 but fails to load (the bound is enforced); a copy
#       that puts the public range >=0.1.0 on the private sdlc (no version) fails to load too: why the private repo names sdlc bare;
#       on a released export (sdlc 0.1.0) the same range is met and the copy is enabled
# The manifests' shape follows the tree (fixtures/lib.sh tree_shape): the private repo and an unreleased export carry no version,
#   a released export carries the CHANGELOG's version, and brain's range >=0.1.0 on sdlc once sdlc is released
#   [E] config E: installing brain prints `(+ 1 dependency: vibemaestro-sdlc)`; with the dependent plugin, three plugins are
#       enabled; the installed `brain` finds sdlc's sensitive-value filter through the real registry
# =============================================================================
set -uo pipefail
# the brain's answerer check reads the HOME of every ancestor from its initial environment, which forked subshells share:
# start again without the launcher's (clean_env then points HOME into the scratch tree; the user base is pinned first)
if [ -z "${ACCOUNT_HOME_REEXEC:-}" ]; then
  export PYTHONUSERBASE="${PYTHONUSERBASE:-$(python3 -m site --user-base 2>/dev/null)}"
  exec env -u CLAUDE_CONFIG_DIR ACCOUNT_HOME_REEXEC=1 HOME=/nonexistent bash "$0" "$@"
fi
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
# shellcheck source=fixtures/account-home.sh
. "$HERE/fixtures/account-home.sh"

DEP="$SRC_ROOT/tests/fixtures/dependent-plugin"; DEPN=dependent-fixture
BRAIN="$SRC_ROOT/plugins/vibemaestro-brain"
SDLC="$SRC_ROOT/plugins/vibemaestro-sdlc"
MP="$SRC_ROOT/.claude-plugin/marketplace.json"
RULE=fixture-clusters.instructions.md          # the dependent plugin's rule on clusters/**
NR=$(find "$DEP/rules" -name '*.instructions.md' -type f | wc -l | tr -d ' ')
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
export PYTHONDONTWRITEBYTECODE=1

echo "== part 1: manifest, dependency, marketplace =="
# The private repo carries no version: a marketplace added from a directory without git keys each install `unknown` (measured).
# The public export carries each plugin's released version (none before the first release) and turns the bare sdlc dependency
# into the range >=0.1.0 (scripts/export-public.sh). TS names the tree, SV and BVW the versions the manifests must carry.
TS=$(tree_shape "$SRC_ROOT"); SV=$(want_version "$SRC_ROOT" "$SDLC"); BVW=$(want_version "$SRC_ROOT" "$BRAIN")
GV=unknown; BV=${BVW:-unknown}
python3 - "$DEP/.claude-plugin/plugin.json" "$SDLC/.claude-plugin/plugin.json" "$MP" "$SV" <<'PY' && ok "fixture manifest: name, no version, vibemaestro-sdlc named bare (no range); sdlc version ${SV:-none} on the $TS tree; marketplace: sdlc first, brain second, nothing else" || bad "fixture manifest, sdlc manifest or marketplace entries wrong"
import json, re, sys
g, s, m = (json.load(open(f)) for f in sys.argv[1:4])
assert g["name"] == "dependent-fixture" and "version" not in g, g
assert g["dependencies"] == ["vibemaestro-sdlc"], g["dependencies"]
assert "hooks" not in g and "userConfig" not in g, g
assert (s.get("version") == sys.argv[4] if sys.argv[4] else "version" not in s), (s.get("version", "<absent>"), sys.argv[4])
names = [p["name"] for p in m["plugins"]]
assert names == ["vibemaestro-sdlc", "vibemaestro-brain"], names
assert m["plugins"][0]["source"] == "./plugins/vibemaestro-sdlc" and m["plugins"][0].get("description"), m["plugins"][0]
assert m["plugins"][1]["source"] == "./plugins/vibemaestro-brain" and m["plugins"][1].get("description"), m["plugins"][1]
PY
# the export writes the range when the DEPENDENCY is released (sdlc's version), whatever brain's own
python3 - "$BRAIN/.claude-plugin/plugin.json" "$BVW" "$SV" <<'PY' && ok "brain manifest: name, version ${BVW:-none} on the $TS tree, vibemaestro-sdlc $([ -n "$SV" ] && echo "as the range >=0.1.0 (sdlc released)" || echo "named bare")" || bad "brain manifest or its dependency wrong"
import json, re, sys
b = json.load(open(sys.argv[1])); want, sdlc = sys.argv[2:4]
assert b["name"] == "vibemaestro-brain" and (b.get("version") == want if want else "version" not in b), (b.get("version", "<absent>"), want)
assert b.get("description") and b.get("author", {}).get("name"), b
dep = [{"name": "vibemaestro-sdlc", "version": ">=0.1.0"}] if sdlc else ["vibemaestro-sdlc"]
assert b["dependencies"] == dep, b["dependencies"]
PY
[ -x "$BRAIN/bin/brain" ] && ok "brain ships an executable bin/brain" || bad "no executable bin/brain"
[ ! -e "$DEP/hooks" ] && ok "the fixture ships no hooks: its rules reach the session through the sdlc engine" || bad "the fixture has a hooks/ directory"
[ "$NR" -ge 1 ] && [ "$NR" = "$(find "$DEP/rules" -type f | wc -l | tr -d ' ')" ] && ok "rules/ holds $NR rule files and nothing else" || bad "rules/ is empty or holds other files"
F="$DEP/rules/$RULE"
has "$(sed -n 2,3p "$F")" 'applyTo: "clusters/**"' "the rule $RULE applies to clusters/**"
has "$(sed -n 3,4p "$F")" 'description: "' "the rule $RULE has a description (the SessionStart catalogue shows it)"
[ "$(wc -l < "$F")" -le 40 ] && ok "the rule $RULE is within the rule budget (40 lines)" || bad "the rule $RULE is over 40 lines"
[ ! -e "$SDLC/rules/$RULE" ] && ok "no sdlc rule has the name $RULE (a pack never takes an sdlc rule name)" || bad "name clash with sdlc"

echo "== part 2: claude plugin (offline, no model) =="
if ! command -v claude >/dev/null 2>&1; then
  if [ "${PLUGIN_REQUIRE_CLAUDE:-}" = 1 ]; then bad "no 'claude' while PLUGIN_REQUIRE_CLAUDE=1"; else
    echo "  SKIP *** no 'claude' on this machine — part 2 (validate, install, list, the real rule-pack path) DID NOT RUN ***"; fi
  summary; exit $?
fi
H0=$(tree_hash "$SRC_ROOT" 2>/dev/null)
copy_kit() { mkdir -p "$1"; (cd "$SRC_ROOT" && tar --exclude=./.git --exclude=./.claude -cf - .) | tar -x -C "$1"; find "$1" -name __pycache__ -prune -exec rm -rf {} +; }
# add_dep <copy> — the fixture as a plugin of the copy's marketplace, appended after the real entries
add_dep() {
  cp -R "$DEP" "$1/plugins/$DEPN"
  python3 -c 'import json,sys; p,n=sys.argv[1:]; d=json.load(open(p)); d["plugins"].append({"name": n, "source": "./plugins/" + n, "description": "a plugin that depends on sdlc"}); json.dump(d,open(p,"w"),indent=2)' \
    "$1/.claude-plugin/marketplace.json" "$DEPN"
}
CP="$TMP/kit"; copy_kit "$CP"; add_dep "$CP"
cl() { claude "$@" 2>&1; }                                   # cl <args> — with the CLAUDE_CONFIG_DIR of the case
use_cfg() { export CLAUDE_CONFIG_DIR="$TMP/cfg-$1"; mkdir -p "$CLAUDE_CONFIG_DIR"; }
ipath() {  # ipath <plugin name> — installPath of its entry in the case's registry, empty when none
  python3 - "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json" "$1" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for k, v in d.get("plugins", {}).items():
    if k.split("@")[0] == sys.argv[2] and v:
        print(v[0]["installPath"])
PY
}
brain_store_isolate() {  # brain_store_isolate <brain_store.py> <dir> — as brain_kit does for the brain suites (a copy of its own: the installed one)
  mkdir -p "$2/managed" "$2/account"
  python3 - "$1" "$2/managed" "$2/account" "$$" <<'PY' || { bad "brain_store_isolate: a line to isolate was not found in $1"; return 1; }
import re, sys
p, m, a, pid = sys.argv[1:5]
s = open(p, encoding="utf-8").read()
subs = ((r"(?m)^MANAGED_SETTINGS = \(.*\)$", 'MANAGED_SETTINGS = ("%s/managed-settings.json",)\nSUITE_PID = %s' % (m, pid)),
        (r"(?m)^        return pwd\.getpwuid\(os\.getuid\(\)\)\.pw_dir$", '        return "%s"' % a),
        (r"(?m)^        if pid <= 1:$", "        if pid <= 1 or pid == SUITE_PID:"))
for pat, new in subs:
    s, n = re.subn(pat, lambda _: new, s)
    if n != 1:
        sys.exit(1)
open(p, "w", encoding="utf-8").write(s)
PY
}

APP="$TMP/app"; mk_app "$APP" >/dev/null
block() {  # block <list output> <plugin id> — that plugin's lines of `claude plugin list`, from its `❯` line to the next one
  printf '%s\n' "$1" | awk -v id="$2" '/^  ❯ /{on = ($2 == id)} on'
}
edit_ctx() {  # edit_ctx <sdlc install path> <path in app> — the context the cached sdlc's PreToolUse Edit hooks give
  local c out=""
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    out+=$(p_edit "$(sid)" "$APP/$2" | CLAUDE_PLUGIN_ROOT="$1" CLAUDE_PROJECT_DIR="$APP" timeout 20 bash -c "$c" 2>/dev/null)
  done < <(hook_cmds "$1/hooks/hooks.json" PreToolUse Edit)
  ctx "$out"
}

echo "-- [V] validate"
for t in "$CP" "$CP/plugins/vibemaestro-sdlc" "$CP/plugins/$DEPN" "$CP/plugins/vibemaestro-brain"; do
  use_cfg v; O=$(cl plugin validate "$t"); rc=$?
  eq "$rc" 0 "[V] validate ${t#"$TMP"/} rc 0"; has "$O" 'Validation passed' "[V] validate ${t#"$TMP"/}: passed"
  empty "$(printf '%s\n' "$O" | grep '❯' | grep -v 'No version specified')" "[V] validate ${t#"$TMP"/}: no warning but the missing version"
done
# the public form, as scripts/export-public.sh writes it for a release: version 0.1.0, the range >=0.1.0 on sdlc
CPP="$TMP/kit-public"; copy_kit "$CPP"
for n in vibemaestro-sdlc vibemaestro-brain; do
  python3 - "$CPP/plugins/$n/.claude-plugin/plugin.json" <<'PY'
import json, sys
p = sys.argv[1]; m = json.load(open(p))
m = dict([("name", m["name"]), ("version", "0.1.0")] + [(k, v) for k, v in m.items() if k != "name"])
if "dependencies" in m:
    m["dependencies"] = [{"name": "vibemaestro-sdlc", "version": ">=0.1.0"}]
json.dump(m, open(p, "w"), indent=2)
PY
done
for t in "$CPP" "$CPP/plugins/vibemaestro-sdlc" "$CPP/plugins/vibemaestro-brain"; do
  use_cfg v; O=$(cl plugin validate --strict "$t"); rc=$?
  eq "$rc" 0 "[V] the public form: validate --strict ${t#"$TMP"/} rc 0"; has "$O" '✔ Validation passed' "[V] the public form: validate --strict ${t#"$TMP"/}: passed"
done
BADP="$TMP/bad-brain"; cp -r "$CP/plugins/vibemaestro-brain" "$BADP"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["version"]=5; json.dump(d,open(p,"w"))' "$BADP/.claude-plugin/plugin.json"
cl plugin validate --strict "$BADP" >/dev/null; ne "$?" 0 "[V] control: a brain manifest with a numeric version fails validate"

echo "-- [A] config A: install the dependent plugin"
use_cfg a
O=$(cl plugin marketplace add "$CP"); eq "$?" 0 "[A] marketplace add rc 0"
O=$(cl plugin install $DEPN@vibemaestro); rc=$?
eq "$rc" 0 "[A] install $DEPN@vibemaestro rc 0"
has "$O" '(+ 1 dependency: vibemaestro-sdlc)' "[A] install prints (+ 1 dependency: vibemaestro-sdlc)"
L=$(cl plugin list)
eq "$(printf '%s\n' "$L" | grep -c 'Status: ✔ enabled')" 2 "[A] claude plugin list: 2 enabled"
has "$L" 'vibemaestro-sdlc@vibemaestro' "[A] list: sdlc"; has "$L" "$DEPN@vibemaestro" "[A] list: the dependent plugin"
has "$(block "$L" $DEPN@vibemaestro)" "Version: $GV" "[A] list: the dependent plugin's block has the manifest's version ($GV)"
has "$(block "$L" $DEPN@vibemaestro)" 'Status: ✔ enabled' "[A] list: the dependent plugin's block is enabled"
nonempty "$(block "$L" vibemaestro-sdlc@vibemaestro | grep -F 'Status: ✔ enabled')" "[A] list: the sdlc block is enabled"
eq "$(block "$L" nope@vibemaestro | wc -l | tr -d ' ')" 0 "[A] instrument: block of an id that is not listed is empty"
eq "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["plugins"]; print(d["vibemaestro-sdlc@vibemaestro"][0].get("auto"))' \
  "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json")" True "[A] the registry records sdlc as an auto-installed dependency"
SP=$(ipath vibemaestro-sdlc); GP=$(ipath "$DEPN")
case "$SP|$GP" in "$CLAUDE_CONFIG_DIR/plugins/cache/"*"|$CLAUDE_CONFIG_DIR/plugins/cache/"*) ok "[A] both install paths are cache copies under the config directory";;
  *) bad "[A] install paths not in the cache: $SP $GP";; esac

echo "-- [P] the real rule-pack path"
O=$(edit_ctx "$SP" clusters/c1/kustomization.yaml)
has "$O" "$GP/rules/$RULE" "[P] an edit under clusters/ names the dependent plugin's rule $RULE, from its cache copy"
O=$(edit_ctx "$SP" src/main.ts)
hasnt "$O" "$RULE" "[P] control: an edit of src/main.ts does not name it"
O=$(edit_ctx "$SP" kb/specs/x.md)
has "$O" "$SP/rules/document-precedence.instructions.md" "[P] instrument: the cached sdlc hooks name an sdlc rule on its path"

echo "-- [P] uninstall the dependent plugin"
O=$(cl plugin uninstall $DEPN@vibemaestro); eq "$?" 0 "[P] uninstall $DEPN rc 0"
L=$(cl plugin list)
eq "$(printf '%s\n' "$L" | grep -c 'Status: ✔ enabled')" 1 "[P] after uninstall: 1 enabled"
has "$L" 'vibemaestro-sdlc@vibemaestro' "[P] after uninstall: sdlc stays"
[ -d "$GP/rules" ] && ok "[P] the dependent plugin's cache copy is still on disk, so the next check shows the registry decides" || bad "[P] its cache copy is gone: the next check proves less"
O=$(edit_ctx "$SP" clusters/c1/kustomization.yaml)
hasnt "$O" "$RULE" "[P] after uninstall: the clusters/ edit no longer names the pack rule"
O=$(edit_ctx "$SP" kb/specs/x.md)
has "$O" "$SP/rules/document-precedence.instructions.md" "[P] instrument: the sdlc hooks still answer after uninstall"

echo "-- [B] config B: sdlc alone"
use_cfg b
cl plugin marketplace add "$CP" >/dev/null
O=$(cl plugin install vibemaestro-sdlc@vibemaestro); eq "$?" 0 "[B] install vibemaestro-sdlc@vibemaestro rc 0"
hasnt "$O" 'dependency' "[B] install prints no dependency"
L=$(cl plugin list)
eq "$(printf '%s\n' "$L" | grep -c '^  ❯')" 1 "[B] claude plugin list: 1 plugin"
hasnt "$L" "$DEPN" "[B] list: no dependent plugin"
SPB=$(ipath vibemaestro-sdlc)
O=$(edit_ctx "$SPB" clusters/c1/kustomization.yaml)
hasnt "$O" "$RULE" "[B] sdlc alone: a clusters/ edit names no pack rule"

echo "-- [C] config C: a bound sdlc cannot meet"
use_cfg c
CP2="$TMP/kit-bound"; copy_kit "$CP2"; add_dep "$CP2"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["dependencies"]=[{"name": "vibemaestro-sdlc", "version": ">=99.0.0"}]; json.dump(d,open(p,"w"))' \
  "$CP2/plugins/$DEPN/.claude-plugin/plugin.json"
cl plugin marketplace add "$CP2" >/dev/null
O=$(cl plugin install $DEPN@vibemaestro); eq "$?" 0 "[C] install with an unmet bound still exits 0 (so checks read the list)"
L=$(cl plugin list)
GB=$(block "$L" $DEPN@vibemaestro); SB=$(block "$L" vibemaestro-sdlc@vibemaestro)
has "$GB" 'failed to load' "[C] list: the dependent plugin's block says failed to load"
has "$GB" '>=99.0.0' "[C] list: its block names the bound"
has "$SB" 'Status: ✔ enabled' "[C] list: the sdlc block is enabled"
hasnt "$SB" 'failed to load' "[C] list: the sdlc block did not fail"
use_cfg c2
CP3="$TMP/kit-range"; copy_kit "$CP3"; add_dep "$CP3"
python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["dependencies"]=[{"name": "vibemaestro-sdlc", "version": ">=0.1.0"}]; json.dump(d,open(p,"w"))' \
  "$CP3/plugins/$DEPN/.claude-plugin/plugin.json"
cl plugin marketplace add "$CP3" >/dev/null; cl plugin install $DEPN@vibemaestro >/dev/null
GB=$(block "$(cl plugin list)" $DEPN@vibemaestro)
if [ -z "$SV" ]; then
  has "$GB" 'failed to load' "[C] the public range >=0.1.0 on the private sdlc (no version): the dependent plugin fails to load (why private names sdlc bare)"
  has "$GB" 'installed version unknown' "[C] …the list says the installed version is unknown"
else
  has "$GB" 'Status: ✔ enabled' "[C] the public range >=0.1.0 on the released sdlc ($SV): the dependent plugin is enabled"
  hasnt "$GB" 'failed to load' "[C] …and did not fail to load"
fi

echo "-- [E] config E: install brain, then the dependent plugin"
use_cfg e
cl plugin marketplace add "$CP" >/dev/null
O=$(cl plugin install vibemaestro-brain@vibemaestro); eq "$?" 0 "[E] install vibemaestro-brain@vibemaestro rc 0"
has "$O" '(+ 1 dependency: vibemaestro-sdlc)' "[E] install prints (+ 1 dependency: vibemaestro-sdlc)"
L=$(cl plugin list)
has "$(block "$L" vibemaestro-brain@vibemaestro)" "Version: $BV" "[E] list: the brain block has the manifest's version ($BV)"
has "$(block "$L" vibemaestro-brain@vibemaestro)" 'Status: ✔ enabled' "[E] list: brain is enabled"
nonempty "$(block "$L" vibemaestro-sdlc@vibemaestro | grep -F 'Status: ✔ enabled')" "[E] list: sdlc came with it, enabled"
O=$(cl plugin install $DEPN@vibemaestro); eq "$?" 0 "[E] install $DEPN@vibemaestro too: rc 0"
L=$(cl plugin list)
eq "$(printf '%s\n' "$L" | grep -c 'Status: ✔ enabled')" 3 "[E] claude plugin list: three plugins enabled"
BP=$(ipath vibemaestro-brain)
# [Y] the installed brain's answerer check reads .claude of the account's home and of every ancestor process (their initial HOME):
# the copy in the scratch cache reads the scratch tree instead and stops at this shell (brain_store_isolate), measured by home_leaks (fixtures/account-home.sh),
# and the suite itself was started with HOME=/nonexistent (top of the file), so a subshell carries no real HOME
brain_store_isolate "$BP/scripts/brain_store.py" "$TMP/brain-iso"
eq "$(grep -c '^SUITE_PID = ' "$BP/scripts/brain_store.py")" 1 "[Y1] the installed brain is isolated from the machine: its ancestor walk stops at the suite's shell"
eq "$(home_leaks "$BP/scripts" brain_store _ancestors)" "True []" "[Y2] the ancestors the brain sees from below the suite: at least one, none with a HOME outside the scratch tree"
has "$(HOME=/ctl-real home_leaks "$BP/scripts" brain_store _ancestors)" "'/ctl-real'" "[Y3] control: a bash above the call that was started with another HOME is named, so [Y2] can see a leak"
O=$(cd "$APP" && XDG_STATE_HOME="$TMP/state-e" "$BP/bin/brain" doctor 2>&1)
has "$O" "the sensitive-value filter runs (clean 0, token 1)" "[E] the installed brain finds sdlc's filter through the registry"
hasnt "$O" "was not found" "[E] instrument: no missing-filter line"

unset CLAUDE_CONFIG_DIR
eq "$(tree_hash "$SRC_ROOT")" "$H0" "part 2 wrote nothing into the repo tree (it ran on copies)"
summary
