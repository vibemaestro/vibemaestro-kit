#!/bin/bash
# =============================================================================
# Plugin vibemaestro-sdlc — rule packs: the rules/ of installed plugins that declare a dependency on vibemaestro-sdlc
# =============================================================================
# Run: bash tests/test-rule-packs.sh
#
# Offline, no `claude`: the Claude Code plugin registry (`installed_plugins.json`) is FABRICATED in the format measured on
# Claude Code 2.1.290; a real install is checked by
# tests/test-install.sh [P] with the fixture tests/fixtures/dependent-plugin. The plugin is a copy of the real one with fake
# sdlc rules (lib.sh mk_plugin: r-all `**`, r-clusters `clusters/**`, r-cmd `lenh-bay`, the core); its hooks run by the
# `command` strings of hooks/hooks.json, each under a timeout.
# Every check has a control that differs in one thing: the same rule text in a plugin without the dependency, the same plugin
# inside the plugins directory, the same registry in the other order.
#   [D] discovery: a pack rule on a matching command and edit, CLAUDE_CONFIG_DIR set, unset (HOME), empty, relative
#   [U] uninstall: the registry entry gone, the cache copy still on disk
#   [S] scope: an entry with a projectPath counts only in that project; local, then project, then user
#   [E] enabled: `enabledPlugins` false in user, project or local settings, the later one winning
#   [P] precedence: a pack never takes an sdlc rule name (core and disabled ones too); a repo rule replaces a pack rule
#   [O] order: two packs with one rule name: the first plugin id in sort order, in both registry orders
#   [C] containment: `..`, symlinked install dir, rules/, rule file, manifest, relative installPath, FIFO, malformed registry
#   [B] bounded cost: an oversized rule file is skipped, a long one under the cap is cheap, a catastrophic pack pattern is stopped
#   [F] front(): the linear parser gives the regex's values and stays linear
#   [K] kb.py config check knows pack rule names
#   [N] coordinated session: rule coordinated-work follows the core only in a sandbox session or when an enabled plugin of sdlc's own
#       marketplace that declares the dependency ships the marker file sdlc-coordinated; a solo session gets only its catalogue row
#   [R] every hook command ended rc 0
#   [X] planted breaks: each check goes red on a copy with one break
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
# shellcheck source=fixtures/flow.sh
. "$HERE/fixtures/flow.sh"
# shellcheck source=fixtures/ports.sh
. "$HERE/fixtures/ports.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
export PYTHONDONTWRITEBYTECODE=1
RCF="$TMP/hook-rcs"; : > "$RCF"
SDLC_DEP='[{"name": "vibemaestro-sdlc", "version": ">=2.5.0"}]'
WL='WARNING: rule packs:'

# ── hooks ─────────────────────────────────────────────────────────────────────
# cfgenv <dir|-> — CLAUDE_CONFIG_DIR for the hook: a value (even empty), or `-` for unset
cfgenv() { if [ "$1" = - ]; then unset CLAUDE_CONFIG_DIR; else export CLAUDE_CONFIG_DIR="$1"; fi; }
# hook <plugin> <app> <cfg|-> <event> <tool> <payload> [line] — the commands of hooks.json (only line N with [line]), each under
# a 20 s timeout, stdout joined; each rc is appended to $RCF
hook() {
  ( cfgenv "$3"; export CLAUDE_PROJECT_DIR="$2" CLAUDE_PLUGIN_ROOT="$1"
    hook_cmds "$1/hooks/hooks.json" "$4" "$5" | sed -n "${7:-1,\$}p" | while IFS= read -r c; do
      [ -n "$c" ] || continue
      printf '%s' "$6" | timeout 20 bash -c "$c" 2>/dev/null; echo "$?" >> "$RCF"
    done )
}
hb() { hook "$1" "$2" "$3" PreToolUse Bash "$(p_bash "$(sid)" "$4")"; }          # hb <plugin> <app> <cfg> <command>
hbs() { hook "$1" "$2" "$3" PreToolUse Bash "$(p_bash "$4" "$5")"; }              # hbs <plugin> <app> <cfg> <session id> <command>
he() { hook "$1" "$2" "$3" PreToolUse Edit "$(p_edit "$(sid)" "$2/$4")"; }       # he <plugin> <app> <cfg> <path in app>
hs() { ctx "$(hook "$1" "$2" "$3" SessionStart "" "$(p_start "$(sid)")" "${4:-2}")"; }   # hs <plugin> <app> <cfg> [1|2]: context
nwarn() { printf '%s\n' "$1" | grep -c -F "$WL"; }                                 # warning lines about rule packs
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
within() { [ "$1" -lt "$2" ] && ok "$3 ($1 ms)" || bad "$3 (took $1 ms)"; }      # within <ms> <limit ms> <label>

# ── fixture ───────────────────────────────────────────────────────────────────
inst_of() { printf '%s/plugins/cache/%s/%s/1.0.0' "$1" "${2#*@}" "${2%@*}"; }      # inst_of <cfg> <name@marketplace>
plug() {  # plug <dir> <name> <dependencies JSON> — a plugin directory: manifest and an empty rules/
  mkdir -p "$1/.claude-plugin" "$1/rules"
  printf '{"name": "%s", "version": "1.0.0", "dependencies": %s}\n' "$2" "$3" > "$1/.claude-plugin/plugin.json"
}
pack() {  # pack <cfg> <name@mkt> <rule tag> — a pack at its install path with one rule `<tag>-x` (clusters/**, frobnicate); prints the path
  local d; d=$(inst_of "$1" "$2"); plug "$d" "${2%@*}" "$SDLC_DEP"
  rule "$d" "$3-x.instructions.md" 'clusters/**' '\bfrobnicate\b' - "$(printf '%s' "$3" | tr a-z A-Z)-X"; printf '%s' "$d"
}
reg() {  # reg <cfg> <id=installPath[|projectPath[|scope]]>... — the registry, ids and entries in the order given, and <cfg>/settings.json
  # enabling every id (what an install writes)
  python3 - "$@" <<'PY'
import json, os, sys
cfg, plugins = sys.argv[1], {}
for it in sys.argv[2:]:
    pid, _, rest = it.partition("=")
    parts = rest.split("|")
    e = {"scope": "user", "installPath": parts[0], "version": "1.0.0", "installedAt": "2026-10-16T00:00:00.000Z"}
    if len(parts) > 1:
        e.update(scope=parts[2] if len(parts) > 2 else "project", projectPath=parts[1])
    plugins.setdefault(pid, []).append(e)
os.makedirs(os.path.join(cfg, "plugins"), exist_ok=True)
with open(os.path.join(cfg, "plugins", "installed_plugins.json"), "w") as f:
    json.dump({"version": 2, "plugins": plugins}, f, indent=1)
with open(os.path.join(cfg, "settings.json"), "w") as f:
    json.dump({"enabledPlugins": {k: True for k in plugins}}, f)
PY
}
sdlc_entry() { printf 'vibemaestro-sdlc@acme=%s' "$(inst_of "$1" vibemaestro-sdlc@acme)"; }
app() { local a; a=$(fresh)/app; mk_app "$a" >/dev/null; printf '%s' "$a"; }
cfg_json() { mkdir -p "$1/.vibemaestro"; printf '%s' "$2" > "$1/.vibemaestro/sdlc.json"; }

# ── [D] discovery ─────────────────────────────────────────────────────────────
fam_discovery() {
  local P=$1 A C D N O S H HD out
  A=$(app); C=$(fresh)/cfg
  D=$(pack "$C" dep@acme dep)
  N=$(inst_of "$C" nodep@acme); plug "$N" nodep '[]'; rule "$N" nodep-x.instructions.md 'clusters/**' '\bfrobnicate\b' - 'NODEP-X'
  O=$(inst_of "$C" other@acme); plug "$O" other '["base"]'; rule "$O" other-x.instructions.md 'clusters/**' '\bfrobnicate\b' - 'OTHER-X'
  S=$(inst_of "$C" strdep@acme); plug "$S" strdep '["vibemaestro-sdlc@acme"]'; rule "$S" strdep-x.instructions.md - '\bfrobnicate\b' - 'STRDEP-X'
  reg "$C" "$(sdlc_entry "$C")" "dep@acme=$D" "nodep@acme=$N" "other@acme=$O" "strdep@acme=$S"
  out=$(hb "$P" "$A" "$C" "frobnicate now")
  has "$out" "$D/rules/dep-x.instructions.md" "[D] a pack rule is reminded on a matching command (CLAUDE_CONFIG_DIR set)"
  has "$out" "$S/rules/strdep-x.instructions.md" "[D] the string form vibemaestro-sdlc@<marketplace> declares the dependency too"
  hasnt "$out" "NODEP-X" "[D] control: the same rule in a plugin with no dependency is not reminded"
  hasnt "$out" "OTHER-X" "[D] control: the same rule in a plugin that depends on another plugin is not reminded"
  out=$(hb "$P" "$A" "$C" "ls -la")
  hasnt "$out" "$D/rules" "[D] control: a command the pack rule does not match"
  out=$(he "$P" "$A" "$C" clusters/x.yaml)
  has "$out" "$D/rules/dep-x.instructions.md" "[D] a pack rule is reminded on a matching edit"
  has "$out" "$P/rules/r-clusters.instructions.md" "[D] instrument: the sdlc rule of that path is reminded in the same call"
  hasnt "$out" "$N/rules" "[D] control: the edit rule of a plugin with no dependency is not reminded"
  out=$(he "$P" "$A" "$C" src/main.ts)
  hasnt "$out" "$D/rules" "[D] control: an edit outside the pack rule's applyTo"
  out=$(hs "$P" "$A" "$C")
  has "$out" "dep-x.instructions.md — DEP-X" "[D] the SessionStart catalogue lists the pack rule"
  has "$out" "[rule pack of dep@acme]" "[D] …and names its plugin"
  hasnt "$out" "nodep-x" "[D] control: the catalogue does not list the rule of a plugin with no dependency"
  eq "$(printf '%s\n' "$out" | grep -n -e '^- r-cmd' -e '^- dep-x' | cut -d: -f2 | cut -c1-7 | paste -sd' ' -)" "- r-cmd - dep-x" \
    "[D] the pack rows come after the sdlc rows (the size cap trims them first)"
  eq "$(nwarn "$out")" 0 "[D] a well-formed registry: no rule-pack warning"
  H=$(fresh)/home; HD=$(pack "$H/.claude" homedep@acme home); reg "$H/.claude" "homedep@acme=$HD"
  out=$(HOME="$H" hb "$P" "$A" - "frobnicate now")
  has "$out" "$HD/rules/home-x.instructions.md" "[D] CLAUDE_CONFIG_DIR unset: the registry under HOME/.claude is read"
  hasnt "$out" "$D/rules" "[D] …and not the other one"
  has "$(HOME="$H" he "$P" "$A" - clusters/x.yaml)" "$HD/rules/home-x.instructions.md" "[D] CLAUDE_CONFIG_DIR unset: …on a matching edit too"
  out=$(HOME="$H" hb "$P" "$A" "$C" "frobnicate now")
  has "$out" "$D/rules/dep-x.instructions.md" "[D] both registries exist: CLAUDE_CONFIG_DIR's is read"
  hasnt "$out" "$HD/rules" "[D] …and only that one"
  out=$(HOME="$H" hb "$P" "$A" "" "frobnicate now")
  has "$out" "$HD/rules/home-x.instructions.md" "[D] CLAUDE_CONFIG_DIR empty: as unset"
  out=$(HOME="$H" hb "$P" "$A" "rel/cfg" "frobnicate now")
  hasnt "$out" "-x.instructions.md" "[D] CLAUDE_CONFIG_DIR relative: no pack is read (neither registry)"
  out=$(HOME="$H" hs "$P" "$A" "rel/cfg")
  eq "$(nwarn "$out")" 1 "[D] CLAUDE_CONFIG_DIR relative: one warning line"
  has "$out" "CLAUDE_CONFIG_DIR" "[D] …naming the variable"
}

# ── [U] uninstall ─────────────────────────────────────────────────────────────
fam_uninstall() {
  local P=$1 A C D N out
  A=$(app); C=$(fresh)/cfg; D=$(pack "$C" dep@acme dep); N=$(pack "$C" keep@acme keep)
  reg "$C" "$(sdlc_entry "$C")" "dep@acme=$D" "keep@acme=$N"
  out=$(hb "$P" "$A" "$C" "frobnicate now")
  has "$out" "$D/rules/dep-x.instructions.md" "[U] instrument: installed, the pack rule is reminded"
  reg "$C" "$(sdlc_entry "$C")" "keep@acme=$N"
  out=$(hb "$P" "$A" "$C" "frobnicate now")
  hasnt "$out" "$D/rules" "[U] uninstalled (no registry entry): the pack rule is absent"
  has "$out" "$N/rules/keep-x.instructions.md" "[U] control: the pack still installed is still reminded"
  [ -f "$D/rules/dep-x.instructions.md" ] && ok "[U] instrument: the cache copy of the uninstalled pack is still on disk (as measured)" \
    || bad "[U] instrument: the cache copy of the uninstalled pack is still on disk (as measured)"
  out=$(he "$P" "$A" "$C" clusters/x.yaml)
  hasnt "$out" "$D/rules" "[U] uninstalled: absent on a matching edit too"
  has "$out" "$N/rules/keep-x.instructions.md" "[U] …instrument: the pack still installed is reminded on that edit"
  rm -f "$C/plugins/installed_plugins.json"
  out=$(hs "$P" "$A" "$C")
  eq "$(nwarn "$out")" 0 "[U] no registry at all: silent"
  hasnt "$out" "rule pack of" "[U] …and no pack in the catalogue"
}

# ── [S] scope ─────────────────────────────────────────────────────────────────
fam_scope() {
  local P=$1 A B C D U L out
  A=$(app); B=$(app); C=$(fresh)/cfg; D=$(pack "$C" dep@acme dep)
  reg "$C" "dep@acme=$D|$A"
  has "$(hb "$P" "$A" "$C" "frobnicate now")" "$D/rules/dep-x.instructions.md" "[S] a project-scope entry: reminded in its project"
  hasnt "$(hb "$P" "$B" "$C" "frobnicate now")" "$D/rules" "[S] a project-scope entry: absent in another project"
  U=$(fresh)/user; plug "$U" dep "$SDLC_DEP"; rule "$U" dep-x.instructions.md - '\bfrobnicate\b' - 'USER-COPY'
  L=$(fresh)/local; plug "$L" dep "$SDLC_DEP"; rule "$L" dep-x.instructions.md - '\bfrobnicate\b' - 'LOCAL-COPY'
  mkdir -p "$C/plugins/cache/acme/dep/u" "$C/plugins/cache/acme/dep/l"; cp -R "$U/." "$C/plugins/cache/acme/dep/u/"; cp -R "$L/." "$C/plugins/cache/acme/dep/l/"
  reg "$C" "dep@acme=$C/plugins/cache/acme/dep/u" "dep@acme=$D|$A" "dep@acme=$C/plugins/cache/acme/dep/l|$A|local"
  out=$(hb "$P" "$A" "$C" "frobnicate now")
  has "$out" "LOCAL-COPY" "[S] user, project and local entries in this project: the local one applies"
  hasnt "$out" "USER-COPY" "[S] …not the user one"
  out=$(hb "$P" "$B" "$C" "frobnicate now")
  has "$out" "USER-COPY" "[S] the same registry in another project: the user entry applies"
}

# ── [E] enabled ───────────────────────────────────────────────────────────────
fam_enabled() {
  local P=$1 A C D
  A=$(app); C=$(fresh)/cfg; D=$(pack "$C" dep@acme dep); reg "$C" "$(sdlc_entry "$C")" "dep@acme=$D"
  printf '{"enabledPlugins": {"dep@acme": true}}' > "$C/settings.json"
  has "$(hb "$P" "$A" "$C" "frobnicate now")" "$D/rules" "[E] instrument: enabled in the user settings, reminded"
  printf '{"enabledPlugins": {"dep@acme": false}}' > "$C/settings.json"
  hasnt "$(hb "$P" "$A" "$C" "frobnicate now")" "$D/rules" "[E] disabled in the user settings: absent"
  mkdir -p "$A/.claude"; printf '{"enabledPlugins": {"dep@acme": true}}' > "$A/.claude/settings.json"
  has "$(hb "$P" "$A" "$C" "frobnicate now")" "$D/rules" "[E] enabled in the project settings over the user's false: reminded"
  printf '{"enabledPlugins": {"dep@acme": false}}' > "$A/.claude/settings.local.json"
  hasnt "$(hb "$P" "$A" "$C" "frobnicate now")" "$D/rules" "[E] disabled in the local settings over the project's true: absent"
  printf '{"enabledPlugins": ' > "$A/.claude/settings.local.json"
  has "$(hb "$P" "$A" "$C" "frobnicate now")" "$D/rules" "[E] a malformed local settings file names nothing: the project's true holds"
  rm -f "$A/.claude/settings.json" "$A/.claude/settings.local.json"; printf '{"enabledPlugins": {}}' > "$C/settings.json"
  hasnt "$(hb "$P" "$A" "$C" "frobnicate now")" "$D/rules" "[E] named by no settings file: not served (measured: Claude Code shows it disabled)"
  rm -f "$C/settings.json"
  hasnt "$(hb "$P" "$A" "$C" "frobnicate now")" "$D/rules" "[E] no settings file at all: not served"
}

# ── [J] the session's project directory (CLAUDE_PROJECT_DIR), not the git root ─────────────────────────
fam_projdir() {
  local P=$1 A C D out
  A=$(app); mkdir -p "$A/sub"; C=$(fresh)/cfg; D=$(pack "$C" dep@acme dep); reg "$C" "dep@acme=$D"
  has "$(hb "$P" "$A/sub" "$C" "frobnicate now")" "$D/rules" "[J] instrument: a session in a subdirectory is served the pack"
  mkdir -p "$A/sub/.claude"; printf '{"enabledPlugins": {"dep@acme": false}}' > "$A/sub/.claude/settings.json"
  hasnt "$(hb "$P" "$A/sub" "$C" "frobnicate now")" "$D/rules" "[J] false in the session directory's project settings: not served"
  mv "$A/sub/.claude" "$A/.claude"
  has "$(hb "$P" "$A/sub" "$C" "frobnicate now")" "$D/rules" "[J] the same file at the git root does not count for a session in a subdirectory (as measured)"
  hasnt "$(hb "$P" "$A" "$C" "frobnicate now")" "$D/rules" "[J] …and does for a session at the root"
  rm -rf "$A/.claude"; reg "$C" "dep@acme=$D|$A"
  has "$(hb "$P" "$A" "$C" "frobnicate now")" "$D/rules" "[J] a project entry for the root: served at the root"
  hasnt "$(hb "$P" "$A/sub" "$C" "frobnicate now")" "$D/rules" "[J] …not in a session opened in a subdirectory"
}

# ── [P] precedence ────────────────────────────────────────────────────────────
fam_precedence() {
  local P=$1 A C D out core0 core1
  A=$(app); C=$(fresh)/cfg; D=$(pack "$C" dep@acme dep)
  rule "$D" r-cmd.instructions.md - 'lenh-bay' - 'PACK-R-CMD'
  rule "$D" workflow-core.instructions.md - 'lenh-bay' - 'PACK-CORE'
  rule "$D" quy-trinh-git.instructions.md - 'lenh-bay' - 'PACK-OLD-NAME'
  reg "$C" "$(sdlc_entry "$C")" "dep@acme=$D"
  out=$(hb "$P" "$A" "$C" "lenh-bay now")
  has "$out" "$P/rules/r-cmd.instructions.md" "[P] a pack rule named like an sdlc rule: the sdlc rule is reminded"
  hasnt "$out" "$D/rules/r-cmd" "[P] …and the pack's file is not"
  hasnt "$out" "PACK-R-CMD" "[P] …nor its description"
  hasnt "$out" "PACK-CORE" "[P] a pack rule named like the process core is not reminded"
  hasnt "$out" "PACK-OLD-NAME" "[P] a pack rule named like the OLD name of a renamed sdlc rule is not reminded either"
  out=$(hs "$P" "$A" "$C")
  eq "$(printf '%s\n' "$out" | grep -F "$WL" | grep -c -F 'r-cmd.instructions.md')" 1 "[P] one warning line for the sdlc name"
  eq "$(printf '%s\n' "$out" | grep -F "$WL" | grep -c -F 'workflow-core.instructions.md')" 1 "[P] one warning line for the core name"
  eq "$(printf '%s\n' "$out" | grep -F "$WL" | grep -c -F 'quy-trinh-git.instructions.md')" 1 "[P] one warning line for the old name of a renamed rule"
  core0=$(hs "$P" "$A" - 1); core1=$(hs "$P" "$A" "$C" 1)
  nonempty "$core1" "[P] instrument: the core hook speaks"
  eq "$core1" "$core0" "[P] the core delivered at session start is the sdlc one, with or without the pack"
  cfg_json "$A" '{"schema": 1, "rules": {"disable": ["r-cmd"]}}'
  out=$(hb "$P" "$A" "$C" "lenh-bay frobnicate")
  hasnt "$out" "r-cmd.instructions.md" "[P] the repo disabled the sdlc rule: the pack's file of that name does not take its place"
  has "$out" "$D/rules/dep-x.instructions.md" "[P] …instrument: the pack's other rule is reminded in the same call"
  A=$(app); mkdir -p "$A/policy"
  { printf -- '---\napplyWhen: "\\bfrobnicate\\b"\ndescription: "REPO-X"\n---\n\n# repo\n'; } > "$A/policy/dep-x.instructions.md"
  cfg_json "$A" '{"schema": 1, "rules": {"dirs": ["policy"]}}'
  out=$(hb "$P" "$A" "$C" "frobnicate now")
  has "$out" "$A/policy/dep-x.instructions.md" "[P] a repo rule named like a pack rule: the repo rule is reminded"
  hasnt "$out" "$D/rules/dep-x" "[P] …and the pack's is not"
  has "$(hs "$P" "$A" "$C")" "replaces the rule of the same name in the rule pack of dep@acme" "[P] …said at session start"
  A=$(app); cfg_json "$A" '{"schema": 1, "rules": {"disable": ["dep-x"]}}'
  out=$(hb "$P" "$A" "$C" "frobnicate lenh-bay")
  hasnt "$out" "$D/rules/dep-x" "[P] rules.disable turns a pack rule off"
  has "$out" "$P/rules/r-cmd.instructions.md" "[P] …instrument: the sdlc rule of the same command is reminded in the same call"
  has "$(hs "$P" "$A" "$C")" "turned off the rule dep-x.instructions.md of the rule pack of dep@acme" "[P] …said at session start"
}

# ── [O] order ─────────────────────────────────────────────────────────────────
fam_order() {
  local P=$1 A C X Z order out
  A=$(app)
  for order in "aaa zzz" "zzz aaa"; do
    C=$(fresh)/cfg
    X=$(pack "$C" aaa@acme aaa); rule "$X" shared.instructions.md - 'shared-cmd' - 'FROM-AAA'
    Z=$(pack "$C" zzz@acme zzz); rule "$Z" shared.instructions.md - 'shared-cmd' - 'FROM-ZZZ'
    if [ "$order" = "aaa zzz" ]; then reg "$C" "aaa@acme=$X" "zzz@acme=$Z"; else reg "$C" "zzz@acme=$Z" "aaa@acme=$X"; fi
    eq "$(python3 -c 'import json,sys; print(" ".join(k.split("@")[0] for k in json.load(open(sys.argv[1]))["plugins"]))' "$C/plugins/installed_plugins.json")" \
      "$order" "[O] instrument: the registry lists the ids in the order $order"
    out=$(hb "$P" "$A" "$C" "shared-cmd now")
    has "$out" "FROM-AAA" "[O] registry order $order: the rule of the first plugin id in sort order is reminded"
    hasnt "$out" "FROM-ZZZ" "[O] registry order $order: the other is not"
    out=$(hs "$P" "$A" "$C")
    eq "$(printf '%s\n' "$out" | grep -F "$WL" | grep -c -F 'shared.instructions.md')" 1 "[O] registry order $order: one warning line"
    has "$(hb "$P" "$A" "$C" "frobnicate now")" "$Z/rules/zzz-x.instructions.md" "[O] control: the second pack's other rule is still reminded"
  done
  A=$(app); cfg_json "$A" '{"schema": 1, "rules": {"disable": ["shared"]}}'
  out=$(hs "$P" "$A" "$C")
  eq "$(nwarn "$out")" 0 "[O] the repo disabled the shared name: no 'both ship' warning (neither file is delivered)"
  eq "$(printf '%s\n' "$out" | grep -c -F 'turned off the rule shared.instructions.md of the rule pack of')" 2 "[O] …each pack's file is said to be off"
}

# ── [C] containment ───────────────────────────────────────────────────────────
# evil <dir> — a pack that depends on sdlc, with rule evil-x (frobnicate)
evil() { plug "$1" evil "$SDLC_DEP"; rule "$1" evil-x.instructions.md - '\bfrobnicate\b' - 'EVIL-X'; }
# contained <plugin> <app> <cfg> <label> — the pack is not reminded, the sdlc rule is, one warning line
contained() {
  local out
  out=$(hb "$1" "$2" "$3" "frobnicate lenh-bay")
  hasnt "$out" "EVIL-X" "[C] $4: the pack rule is not reminded"
  has "$out" "$1/rules/r-cmd.instructions.md" "[C] $4: the sdlc rule of the same command still is"
  eq "$(nwarn "$(hs "$1" "$2" "$3")")" 1 "[C] $4: one warning line"
}
fam_containment() {
  local P=$1 A C E D out t0 t1
  A=$(app)
  C=$(fresh)/cfg; D=$(inst_of "$C" evil@acme); mkdir -p "$D"; evil "$D"; reg "$C" "evil@acme=$D"
  has "$(hb "$P" "$A" "$C" "frobnicate lenh-bay")" "EVIL-X" "[C] control: the same pack inside the plugins directory is reminded"
  C=$(fresh)/cfg; evil "$C/outside/evil"; mkdir -p "$C/plugins/cache"; reg "$C" "evil@acme=$C/plugins/cache/../../outside/evil"
  contained "$P" "$A" "$C" "installPath escapes with .."
  C=$(fresh)/cfg; E=$(fresh)/evil; evil "$E"; D=$(inst_of "$C" evil@acme); mkdir -p "$(dirname "$D")"; ln -s "$E" "$D"; reg "$C" "evil@acme=$D"
  contained "$P" "$A" "$C" "installPath is a symlink out"
  C=$(fresh)/cfg; E=$(fresh)/evil; evil "$E"; D=$(inst_of "$C" evil@acme); plug "$D" evil "$SDLC_DEP"; rmdir "$D/rules"; ln -s "$E/rules" "$D/rules"
  reg "$C" "evil@acme=$D"; contained "$P" "$A" "$C" "rules/ is a symlink out"
  C=$(fresh)/cfg; E=$(fresh)/evil; evil "$E"; D=$(inst_of "$C" evil@acme); plug "$D" evil "$SDLC_DEP"
  ln -s "$E/rules/evil-x.instructions.md" "$D/rules/evil-x.instructions.md"; reg "$C" "evil@acme=$D"
  contained "$P" "$A" "$C" "a rule file is a symlink out"
  C=$(fresh)/cfg; E=$(fresh)/evil; evil "$E"; D=$(inst_of "$C" evil@acme); mkdir -p "$D/.claude-plugin"; cp -R "$E/rules" "$D/rules"
  ln -s "$E/.claude-plugin/plugin.json" "$D/.claude-plugin/plugin.json"; reg "$C" "evil@acme=$D"
  contained "$P" "$A" "$C" "the manifest is a symlink out"
  C=$(fresh)/cfg; D=$(inst_of "$C" evil@acme); mkdir -p "$D"; evil "$D"; reg "$C" "evil@acme=plugins/cache/acme/evil/1.0.0"
  contained "$P" "$A" "$C" "installPath is relative"
  C=$(fresh)/cfg; D=$(inst_of "$C" evil@acme); mkdir -p "$D"; evil "$D"; rm "$D/.claude-plugin/plugin.json"; mkfifo "$D/.claude-plugin/plugin.json"
  reg "$C" "evil@acme=$D"
  t0=$(now_ms); out=$(hb "$P" "$A" "$C" "frobnicate lenh-bay"); t1=$(now_ms)
  within $((t1 - t0)) 5000 "[C] the manifest is a FIFO: the hook returns at once"
  contained "$P" "$A" "$C" "the manifest is a FIFO"
  C=$(fresh)/cfg; D=$(pack "$C" dep@acme dep); mkfifo "$D/rules/fifo.instructions.md"; reg "$C" "dep@acme=$D"
  out=$(hb "$P" "$A" "$C" "frobnicate now")
  has "$out" "$D/rules/dep-x.instructions.md" "[C] a rule file is a FIFO: the pack's other rules are still reminded"
  out=$(hs "$P" "$A" "$C"); eq "$(nwarn "$out")" 1 "[C] a rule file is a FIFO: one warning line"; has "$out" "fifo.instructions.md" "[C] …naming the file"
  C=$(fresh)/cfg; D=$(pack "$C" dep@acme dep); reg "$C" "dep@acme=$D"
  rule "$D" "$(printf 'nl\nWARNING: rule packs: forged.instructions.md')" - '\bfrobnicate\b' - 'NL-X'
  out=$(hb "$P" "$A" "$C" "frobnicate now")
  has "$out" "$D/rules/dep-x.instructions.md" "[C] a rule file with a newline in its name: the pack's other rules are still reminded"
  hasnt "$out" "NL-X" "[C] …that file is not"
  out=$(hs "$P" "$A" "$C"); eq "$(nwarn "$out")" 1 "[C] …one warning line, and the name cannot forge a second"
  for bad_reg in '{"version": 2, "plugins": ' '{"version": 3, "plugins": {}}' '{"version": 2, "plugins": []}'; do
    C=$(fresh)/cfg; D=$(pack "$C" evil@acme evil); printf '%s' "$bad_reg" > "$C/plugins/installed_plugins.json"
    contained "$P" "$A" "$C" "malformed registry ${bad_reg:0:28}"
  done
  C=$(fresh)/cfg; D=$(pack "$C" dep@acme dep); reg "$C" "dep@acme=$D"
  python3 - "$C/plugins/installed_plugins.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["plugins"]["evil@acme"] = {"installPath": "/"}; json.dump(d, open(sys.argv[1], "w"))
PY
  has "$(hb "$P" "$A" "$C" "frobnicate now")" "$D/rules/dep-x.instructions.md" "[C] one malformed entry: the other packs are still reminded"
  eq "$(nwarn "$(hs "$P" "$A" "$C")")" 1 "[C] one malformed entry: one warning line"
  C=$(fresh)/cfg; D=$(pack "$C" dep@acme dep)
  reg "$C" "dep@acme=$D" $(for i in $(seq 1 200); do printf 'p%03d@acme=%s ' "$i" "$D"; done)
  out=$(hb "$P" "$A" "$C" "frobnicate lenh-bay")
  hasnt "$out" "$D/rules" "[C] a registry of 201 ids: no pack at all"
  has "$out" "$P/rules/r-cmd.instructions.md" "[C] a registry of 201 ids: the sdlc rule of the same command still is"
  eq "$(nwarn "$(hs "$P" "$A" "$C")")" 1 "[C] a registry of 201 ids: one warning line"
}

# ── [B] bounded cost ──────────────────────────────────────────────────────────
fam_cost() {
  local P=$1 A C D out t0 t1
  A=$(app); C=$(fresh)/cfg; D=$(pack "$C" dep@acme dep); reg "$C" "dep@acme=$D"
  python3 - "$D/rules" <<'PY'
import os, sys
d = sys.argv[1]
for name, n, tag in (("big-x", 20000, "BIG-X"), ("long-x", 15000, "LONG-X")):
    with open(os.path.join(d, name + ".instructions.md"), "w") as f:
        f.write('---\napplyWhen: "\\bfrobnicate\\b"\ndescription: "%s %s"\n---\n\n# x\n' % (tag, " " * n))
PY
  [ "$(wc -c < "$D/rules/big-x.instructions.md")" -gt 16384 ] && ok "[B] instrument: big-x is over 16 KiB" || bad "[B] instrument: big-x is over 16 KiB"
  [ "$(wc -c < "$D/rules/long-x.instructions.md")" -le 16384 ] && ok "[B] instrument: long-x is within 16 KiB" || bad "[B] instrument: long-x is within 16 KiB"
  t0=$(now_ms); out=$(hb "$P" "$A" "$C" "frobnicate now"); t1=$(now_ms)
  hasnt "$out" "$D/rules/big-x" "[B] a rule file with an oversized frontmatter is skipped"
  has "$out" "$D/rules/long-x.instructions.md" "[B] control: a 15 000-character frontmatter line within the cap is served"
  has "$out" "$D/rules/dep-x.instructions.md" "[B] …and the pack's other rule"
  within $((t1 - t0)) 3000 "[B] …in under 3 s"
  out=$(hs "$P" "$A" "$C")
  eq "$(nwarn "$out")" 1 "[B] the oversized file: one warning line"; has "$out" "big-x.instructions.md" "[B] …naming the file"
}
fam_slow() {
  local P=$1 A C D out t0 t1 long ss
  A=$(app); C=$(fresh)/cfg; D=$(pack "$C" dep@acme dep); reg "$C" "dep@acme=$D"
  rule "$D" slow-x.instructions.md - '(a+)+$' - 'SLOW-X'
  long="lenh-bay $(printf 'a%.0s' $(seq 1 40))b"
  t0=$(now_ms); out=$(hb "$P" "$A" "$C" "$long"); t1=$(now_ms)
  within $((t1 - t0)) 3000 "[B] a catastrophic pack applyWhen: the hook returns in under 3 s"
  has "$out" "$P/rules/r-cmd.instructions.md" "[B] …the sdlc rule of that command is reminded"
  eq "$(ctx "$out" | grep -c -F 'slow-x.instructions.md of dep@acme ran over')" 1 "[B] …one warning line names the pack rule"
  ss=$(sid); hbs "$P" "$A" "$C" "$ss" "$long" >/dev/null           # this session meets the slow rule once
  t0=$(now_ms); out=$(hbs "$P" "$A" "$C" "$ss" "frobnicate $long"); t1=$(now_ms)
  within $((t1 - t0)) 800 "[B] the slow rule is skipped for the rest of the session: the next call is quick"
  has "$out" "$D/rules/dep-x.instructions.md" "[B] …and the pack's other rule is still matched"
  hasnt "$out" "ran over" "[B] …and the warning is not repeated"
  rule "$D" slow-x.instructions.md 'src/**' - - 'SLOW-X'
  t0=$(now_ms); out=$(hb "$P" "$A" "$C" "$long"); t1=$(now_ms)
  has "$out" "$P/rules/r-cmd.instructions.md" "[B] control: without the pattern the same command reminds the sdlc rule"
  within $((t1 - t0)) 800 "[B] control: …quickly"
  rule "$D" slow-x.instructions.md '**a**a**a**a**a**a**a**a**a**a**a**a**b' - - 'SLOW-X'
  long="src/$(printf 'a%.0s' $(seq 1 60)).ts"
  t0=$(now_ms); out=$(he "$P" "$A" "$C" "$long"); t1=$(now_ms)
  within $((t1 - t0)) 3000 "[B] a catastrophic pack applyTo: the hook returns in under 3 s"
  has "$out" "$P/rules/r-all.instructions.md" "[B] …the sdlc rule of that path is reminded"
  has "$out" "ran over" "[B] …with the warning"
}

# ── [F] front() ───────────────────────────────────────────────────────────────
fam_front() {
  local P=$1 out
  out=$(python3 - "$P/scripts" "$SRC_ROOT" <<'PY'
import glob, os, random, re, sys, time
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[1])
import rules as R
def old(text, key):
    lines = (text or "").split("\n")
    if not lines or lines[0].strip() != "---":
        return ""
    for line in lines[1:]:
        if line.strip() == "---":
            return ""
        m = re.match(r'^%s:\s*"?(.*?)"?\s*$' % re.escape(key), line)
        if m:
            return m.group(1)
    return ""
n = bad = 0
for f in glob.glob(os.path.join(sys.argv[2], "plugins", "**", "*.md"), recursive=True) + glob.glob(os.path.join(sys.argv[2], "kb", "**", "*.md"), recursive=True):
    t = open(f, encoding="utf-8", errors="replace").read()
    for k in ("applyTo", "applyWhen", "level", "description", "status"):
        n += 1; bad += old(t, k) != R.front(t, k)
random.seed(7)
alpha = ['"', ' ', '\t', '\r', 'a', ':', '\u00a0', '\u2003', '\x1c', '\x85']
for _ in range(20000):
    t = "---\nkey:" + "".join(random.choice(alpha) for _ in range(random.randint(0, 8))) + "\n---\n"
    n += 1; bad += old(t, "key") != R.front(t, "key")
t = "---\napplyWhen: x" + " " * 65536 + "y\n---\n"
s = time.perf_counter(); R.front(t, "applyWhen"); ms = (time.perf_counter() - s) * 1000
print(n, bad, "fast" if ms < 200 else "slow:%d" % ms)
PY
)
  set -- $out
  [ "${1:-0}" -gt 20000 ] && ok "[F] instrument: $1 cases compared" || bad "[F] instrument: too few cases compared ($out)"
  eq "${2:-x}" 0 "[F] front() gives the old regex's value on every rule, kb file and fuzz case"
  eq "${3:-x}" fast "[F] front() on a 64 KiB frontmatter line takes under 200 ms"
}

# ── [K] kb.py config check ────────────────────────────────────────────────────
fam_kb() {
  local P=$1 A C D out
  A=$(app); C=$(fresh)/cfg; D=$(pack "$C" dep@acme dep); rule "$D" r-cmd.instructions.md - 'lenh-bay' - 'PACK-R-CMD'; reg "$C" "dep@acme=$D"
  cfg_json "$A" '{"schema": 1, "rules": {"disable": ["dep-x"]}}'
  out=$(CLAUDE_CONFIG_DIR="$C" python3 "$P/scripts/kb.py" config check --root "$A" 2>&1)
  hasnt "$out" "matches no plugin rule" "[K] rules.disable naming a pack rule: no 'matches no plugin rule'"
  has "$out" "r-cmd.instructions.md, a name of a vibemaestro-sdlc rule" "[K] a pack rule with an sdlc name is reported"
  cfg_json "$A" '{"schema": 1, "rules": {"disable": ["no-such-rule"]}}'
  out=$(CLAUDE_CONFIG_DIR="$C" python3 "$P/scripts/kb.py" config check --root "$A" 2>&1)
  has "$out" "matches no plugin rule" "[K] control: a name of no rule is still reported"
}

# ── [Y] robustness: a pattern or an entry that raises ────────────────────────
fam_robust() {
  local P=$1 A C D out
  A=$(app); mkdir -p "$A/policy"
  printf -- '---\napplyWhen: "repo-stop"\nlevel: block\ndescription: "REPO-BLOCK"\n---\n' > "$A/policy/repo-block.instructions.md"
  cfg_json "$A" '{"schema": 1, "rules": {"dirs": ["policy"]}}'
  C=$(fresh)/cfg; D=$(pack "$C" dep@acme dep); reg "$C" "dep@acme=$D"
  out=$(hb "$P" "$A" "$C" "repo-stop now")
  eq "$(dec "$out")" deny "[Y] instrument: the repo block rule denies its command"
  rule "$D" zz-overflow.instructions.md - 'a{4294967296}' - 'OVF'
  rule "$D" zz-deep.instructions.md - "$(python3 -c 'print("(" * 500 + "a" + ")" * 500)')" - 'DEEP'
  out=$(hb "$P" "$A" "$C" "repo-stop now")
  eq "$(dec "$out")" deny "[Y] pack patterns too big to compile (a huge repeat, deep nesting): the repo block rule still denies"
  has "$(why "$out")" "$A/policy/repo-block.instructions.md" "[Y] …naming the repo rule"
  out=$(hb "$P" "$A" "$C" "lenh-bay frobnicate")
  has "$out" "$P/rules/r-cmd.instructions.md" "[Y] …the sdlc rule is still reminded"
  has "$out" "$D/rules/dep-x.instructions.md" "[Y] …and the pack's other rule too: only the broken rules are skipped"
  hasnt "$out" "lỗi nội bộ" "[Y] …with no internal-error warning"
  C=$(fresh)/cfg; D=$(pack "$C" dep@acme dep); reg "$C" "dep@acme=$D"
  python3 - "$C/plugins/installed_plugins.json" "$C/settings.json" "$D" <<'PY'
import json, sys
reg, st, d = sys.argv[1:4]
r, s = json.load(open(reg)), json.load(open(st))
r["plugins"]["bad1@acme"] = [{"scope": [], "installPath": d + "/../none"}]
r["plugins"]["bad2@acme"] = [{"scope": "user", "installPath": d + "\u0000x"}]
r["plugins"]["bad3@acme"] = [{"scope": "project", "projectPath": "/x\u0000y", "installPath": d}]
for k in ("bad1@acme", "bad2@acme", "bad3@acme"):
    s["enabledPlugins"][k] = True
json.dump(r, open(reg, "w")); json.dump(s, open(st, "w"))
PY
  has "$(hb "$P" "$A" "$C" "frobnicate now")" "$D/rules/dep-x.instructions.md" \
    "[Y] entries with a list as scope, a NUL in installPath or in projectPath: the other pack is still served"
  out=$(hs "$P" "$A" "$C")
  hasnt "$out" "internal error" "[Y] …no internal error"
  eq "$(nwarn "$out")" 1 "[Y] …one warning line, for the unusable installPath"; has "$out" "bad2@acme" "[Y] …naming it"
}

# ── [L] paths: long ones, and symlink chains inside a plugin ─────────────────
fam_paths() {
  local P=$1 A C D L X i out t0 t1
  A=$(app)
  C=$(fresh)/cfg; D=$(pack "$C" dep@acme dep); L=$(python3 -c 'print("/a" * 3000)')
  reg "$C" "dep@acme=$D" "long@acme=$C/plugins$L"
  t0=$(now_ms); out=$(hs "$P" "$A" "$C"); t1=$(now_ms)
  within $((t1 - t0)) 3000 "[L] an installPath of 6 000 characters: SessionStart returns quickly"
  eq "$(nwarn "$out")" 1 "[L] …one warning line"
  has "$(hb "$P" "$A" "$C" "frobnicate now")" "$D/rules/dep-x.instructions.md" "[L] …the other pack is still served"
  C=$(fresh)/cfg; D=$(pack "$C" dep@acme dep); reg "$C" "dep@acme=$D"; mkdir -p "$D/chain"
  printf -- '---\napplyWhen: "\\bfrobnicate\\b"\ndescription: "CHAINED"\n---\n' > "$D/chain/l150"
  for i in $(seq 149 -1 0); do ln -s "l$((i + 1))" "$D/chain/l$i"; done
  printf -- '---\napplyWhen: "\\bfrobnicate\\b"\ndescription: "SHORT-CHAIN"\n---\n' > "$D/chain/s10"
  for i in $(seq 9 -1 0); do ln -s "s$((i + 1))" "$D/chain/s$i"; done
  ln -s ../chain/s0 "$D/rules/short.instructions.md"
  for i in $(seq 1 90); do ln -s ../chain/l0 "$D/rules/chained$i.instructions.md"; done
  t0=$(now_ms); out=$(hb "$P" "$A" "$C" "frobnicate now"); t1=$(now_ms)
  within $((t1 - t0)) 3000 "[L] 91 rule files that are symlinks (chains of 150 and 10 links, inside the plugin): the hook returns quickly"
  hasnt "$out" "CHAINED" "[L] a rule file that is a symlink is skipped, however long its chain"
  hasnt "$out" "SHORT-CHAIN" "[L] …and however short"
  has "$out" "$D/rules/dep-x.instructions.md" "[L] control: the pack's plain rule file is served"
  eq "$(nwarn "$(hs "$P" "$A" "$C")")" 1 "[L] …one warning line for the pack's skipped files"
  C=$(fresh)/cfg; mkdir -p "$C/plugins"
  python3 - "$C" <<'PY'
import json, os, sys
cfg = sys.argv[1]
real = os.path.join(cfg, "plugins", "cache", "acme", "real")
deep = os.path.join(cfg, "plugins", "deep")
os.mkdir(deep)
for _ in range(1900):                          # one level at a time: os.makedirs recurses once per level
    deep = os.path.join(deep, "d")
    os.mkdir(deep)
# 19 links, not 38: the kernel follows at most 40 symlinks in one lookup, and a path walk that restarts under filesystem load
# (another suite creating and removing files in parallel) appears to count the links it already followed again, so a chain over
# 20 can fail with ELOOP. Measured in the guarded-merge PR on the pack loader: 38 links left 8 of 100 loads short of 8 packs,
# 30 links 3 of 100, 21 links 1 of 150, 19 and 15 links 0 of 150. With 19 links the planted break python-walks (Python walks
# the path instead of the kernel) still turns this case red.
for k in range(19, 0, -1):                     # L1 -> L2 -> ... -> L19 -> real, each target an absolute path through `deep`
    os.symlink(real if k == 19 else os.path.join(deep, "L%d" % (k + 1)), os.path.join(deep, "L%d" % k))
plugins = {}
for i in range(8):
    d = os.path.join(real, "p%d" % i)
    os.makedirs(os.path.join(d, ".claude-plugin"))
    os.makedirs(os.path.join(d, "rules"))
    json.dump({"name": "p%d" % i, "dependencies": ["vibemaestro-sdlc"]}, open(os.path.join(d, ".claude-plugin", "plugin.json"), "w"))
    open(os.path.join(d, "rules", "p%d-x.instructions.md" % i), "w").write('---\napplyWhen: "deep-cmd"\ndescription: "DEEP-%d"\n---\n' % i)
    plugins["p%d@acme" % i] = [{"scope": "user", "installPath": os.path.join(deep, "L1", "p%d" % i)}]
json.dump({"version": 2, "plugins": plugins}, open(os.path.join(cfg, "plugins", "installed_plugins.json"), "w"))
json.dump({"enabledPlugins": {k: True for k in plugins}}, open(os.path.join(cfg, "settings.json"), "w"))
PY
  t0=$(now_ms); out=$(hb "$P" "$A" "$C" "deep-cmd now"); t1=$(now_ms)
  within $((t1 - t0)) 3000 "[L] 8 installPaths through 19 links of 3 900 characters each (the kernel accepts them): the hook returns quickly"
  eq "$(ctx "$out" | grep -c -F 'DEEP-')" 8 "[L] …and all 8 packs are served (resolved by the kernel, not walked by Python)"
  C=$(fresh)/cfg; D=$(pack "$C" dep@acme dep); X=$(inst_of "$C" other@acme); mkdir -p "$X/.claude-plugin" "$X/chain"
  printf '{"name": "other"}' > "$X/chain/m900"; for i in $(seq 899 -1 0); do ln -s "m$((i + 1))" "$X/chain/m$i"; done
  ln -s ../chain/m0 "$X/.claude-plugin/plugin.json"; reg "$C" "dep@acme=$D" "other@acme=$X"
  t0=$(now_ms); out=$(hb "$P" "$A" "$C" "frobnicate now"); t1=$(now_ms)
  within $((t1 - t0)) 3000 "[L] a manifest behind 900 symlinks: the hook returns quickly"
  has "$out" "$D/rules/dep-x.instructions.md" "[L] …the other pack is served"
}

# ── [Z] size: many matching pack rules, the catalogue, the limits ─────────────
fam_size() {
  local P=$1 A C D X i n out raw base long
  A=$(app); C=$(fresh)/cfg; D=$(pack "$C" dep@acme dep); reg "$C" "dep@acme=$D"
  long=$(printf 'd%.0s' $(seq 1 300))
  rule "$D" m1.instructions.md '**' '\bfrobnicate\b' - "MANY-1 $long"
  for i in $(seq 2 30); do rule "$D" "m$i.instructions.md" '**' '\bfrobnicate\b' - "MANY-$i"; done
  out=$(hb "$P" "$A" "$C" "frobnicate lenh-bay")
  eq "$(ctx "$out" | grep -c -F "$D/rules/")" 10 "[Z] 31 matching pack rules: 10 lines in the command reminder"
  has "$out" "and 21 more rule-pack rule(s) match" "[Z] …and one line counts the rest"
  has "$out" "$P/rules/r-cmd.instructions.md" "[Z] …the sdlc rule is there"
  hasnt "$out" "$(printf 'd%.0s' $(seq 1 201))" "[Z] …a pack rule's description is cut to 200 characters"
  [ "$(nchars "$(ctx "$out")")" -lt 9000 ] && ok "[Z] …the reminder stays under 9 000 characters" || bad "[Z] …the reminder stays under 9 000 characters"
  out=$(he "$P" "$A" "$C" src/main.ts)
  has "$out" "$A/kb/decisions/d-app.md" "[Z] the edit reminder keeps the repo's decision after the pack lines"
  eq "$(ctx "$out" | grep -c -F "$D/rules/")" 10 "[Z] …with 10 pack lines"
  mkdir -p "$A/policy"; cfg_json "$A" '{"schema": 1, "rules": {"dirs": ["policy"]}}'
  printf -- '---\napplyWhen: "repo-long"\ndescription: "REPO-LONG %s"\n---\n' "$(printf 'r%.0s' $(seq 1 140))" > "$A/policy/repo-long.instructions.md"
  C=$(fresh)/cfg; D=$(pack "$C" dep@acme dep); reg "$C" "dep@acme=$D"
  for i in $(seq 1 30); do rule "$D" "m$i.instructions.md" '**' '\bfrobnicate\b' - "MANY-$i $long"; done
  base=$(hs "$P" "$A" -); out=$(hs "$P" "$A" "$C")
  has "$out" "more rule(s) not listed here" "[Z] instrument: 31 long pack rows do not fit in the catalogue"
  [ "$(printf '%s\n' "$base" | grep '^- repo-long' | wc -c)" -gt 150 ] && ok "[Z] instrument: without packs the repo row has its 150-character description" \
    || bad "[Z] instrument: without packs the repo row has its 150-character description"
  eq "$(printf '%s\n' "$out" | grep '^- repo-long')" "$(printf '%s\n' "$base" | grep '^- repo-long')" "[Z] the pack rows go first: the repo's and the plugin's rows stay whole"
  eq "$(printf '%s\n' "$out" | grep '^- r-cmd')" "$(printf '%s\n' "$base" | grep '^- r-cmd')" "[Z] …the sdlc row too"
  [ "$(nchars "$out")" -le 9000 ] && ok "[Z] …and the catalogue fits" || bad "[Z] …and the catalogue fits"
  C=$(fresh)/cfg; X="$C/plugins/cache/acme/$(printf 'n%.0s' $(seq 1 250))/$(printf 'o%.0s' $(seq 1 250))/$(printf 'p%.0s' $(seq 1 250))/$(printf 'q%.0s' $(seq 1 250))/1.0.0"
  plug "$X" longp "$SDLC_DEP"; for i in $(seq 1 12); do rule "$X" "lp$i.instructions.md" - '\bfrobnicate\b' - "LP-$i"; done; reg "$C" "longp@acme=$X"
  out=$(hb "$P" "$A" "$C" "frobnicate lenh-bay")
  [ "$(nchars "$(ctx "$out")")" -lt 9000 ] && ok "[Z] 12 matching rules of a pack with a 1 100-character path: the reminder stays under 9 000 characters" \
    || bad "[Z] 12 matching rules of a pack with a 1 100-character path: the reminder stays under 9 000 characters ($(nchars "$(ctx "$out")"))"
  has "$out" "more rule-pack rule(s) match" "[Z] …the pack lines past 3 000 characters are counted"
  has "$out" "$P/rules/r-cmd.instructions.md" "[Z] …the sdlc rule is there"
  A=$(app); mkdir -p "$A/policy"; cfg_json "$A" '{"schema": 1, "rules": {"dirs": ["policy"]}}'
  for i in $(seq 1 28); do printf -- '---\napplyWhen: "rr%d"\ndescription: "RR-%d %s"\n---\n' "$i" "$i" "$(printf 'r%.0s' $(seq 1 145))" > "$A/policy/rr$i.instructions.md"; done
  C=$(fresh)/cfg; reg "$C" $(for i in 1 2 3 4 5 6; do printf '%s%d@acme=cache/x%d ' "$(printf 'q%.0s' $(seq 1 250))" "$i" "$i"; done)
  base=$(hs "$P" "$A" -); out=$(hs "$P" "$A" "$C")
  [ "$(printf '%s\n' "$base" | grep '^- rr1\.' | wc -c)" -gt 150 ] && ok "[Z] instrument: 28 repo rules fit whole without packs" \
    || bad "[Z] instrument: 28 repo rules fit whole without packs"
  has "$out" "problem(s), not listed here" "[Z] 6 long pack warnings do not fit: they become one line"
  eq "$(printf '%s\n' "$out" | grep '^- rr')" "$(printf '%s\n' "$base" | grep '^- rr')" "[Z] …before any repo row is shortened"
  A=$(app); C=$(fresh)/cfg
  for n in t1 t2; do X=$(pack "$C" $n@acme $n); for i in $(seq 1 99); do printf -- '---\nstatus: retired\n---\n' > "$X/rules/$n-r$i.instructions.md"; done; done
  X=$(pack "$C" t3@acme t3)
  reg "$C" "t1@acme=$(inst_of "$C" t1@acme)" "t2@acme=$(inst_of "$C" t2@acme)" "t3@acme=$X"
  hasnt "$(hb "$P" "$A" "$C" "frobnicate now")" "$X/rules" "[Z] two packs of 100 retired rule files use up the limit: the third is not read"
  C=$(fresh)/cfg; D=$(pack "$C" dep@acme dep); reg "$C" "dep@acme=$D"
  printf -- '---\napplyTo: "x\033[31m"\ndescription: "ESC\033[31m LS\342\200\250 CR\r end"\n---\n' > "$D/rules/aaa-ctl.instructions.md"
  out=$(hs "$P" "$A" "$C")
  has "$out" "aaa-ctl.instructions.md — ESC?[31m LS? CR? end" "[Z] the catalogue shows a pack rule's text on one line, control characters as ?"
  eq "$(printf '%s' "$out" | python3 -c 'import sys; t=sys.stdin.read(); print(sum(c in t for c in "\x1b \r"))')" 0 "[Z] …no escape, line separator or carriage return"
  C=$(fresh)/cfg; X=$(pack "$C" big@acme big); for i in $(seq 1 100); do printf -- '---\ndescription: "x"\n---\n' > "$X/rules/r$i.instructions.md"; done
  reg "$C" "big@acme=$X"
  hasnt "$(hb "$P" "$A" "$C" "frobnicate now")" "$X/rules" "[Z] a pack of 101 rule files is ignored"
  eq "$(nwarn "$(hs "$P" "$A" "$C")")" 1 "[Z] …one warning line"
  C=$(fresh)/cfg; D=$(pack "$C" dep@acme dep); reg "$C" "dep@acme=$D"
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["pad"]="x"*(1<<20); json.dump(d,open(p,"w"))' "$C/plugins/installed_plugins.json"
  hasnt "$(hb "$P" "$A" "$C" "frobnicate now")" "$D/rules" "[Z] a registry over 1 MiB is ignored"
  eq "$(nwarn "$(hs "$P" "$A" "$C")")" 1 "[Z] …one warning line"
  C=$(fresh)/cfg; D=$(pack "$C" dep@acme dep); reg "$C" "dep@acme=$D"
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["pad"]="x"*(64<<10); json.dump(d,open(p,"w"))' "$D/.claude-plugin/plugin.json"
  hasnt "$(hb "$P" "$A" "$C" "frobnicate now")" "$D/rules" "[Z] a manifest over 64 KiB: the plugin is ignored"
  eq "$(nwarn "$(hs "$P" "$A" "$C")")" 1 "[Z] …one warning line"
  C=$(fresh)/cfg
  for n in p1 p2 p3; do X=$(pack "$C" $n@acme $n); for i in $(seq 1 99); do printf -- '---\ndescription: "x"\n---\n' > "$X/rules/$n-r$i.instructions.md"; done; done
  reg "$C" "p1@acme=$(inst_of "$C" p1@acme)" "p2@acme=$(inst_of "$C" p2@acme)" "p3@acme=$(inst_of "$C" p3@acme)"
  out=$(hb "$P" "$A" "$C" "frobnicate now")
  has "$out" "$(inst_of "$C" p2@acme)/rules/p2-x.instructions.md" "[Z] three packs of 100 rules: the first two are served (200 rules in all)"
  hasnt "$out" "$(inst_of "$C" p3@acme)/rules" "[Z] …the third pack is not read"
  out=$(hs "$P" "$A" "$C"); eq "$(nwarn "$out")" 1 "[Z] …one warning line"; has "$out" "reached their limit" "[Z] …saying the limit was reached"
  C=$(fresh)/cfg; reg "$C" $(for i in 1 2 3 4 5 6 7; do printf 'rel%d@acme=cache/x%d ' "$i" "$i"; done)
  raw=$(hook "$P" "$A" "$C" SessionStart "" "$(p_start "$(sid)")" 2)
  eq "$(nwarn "$(ctx "$raw")")" 6 "[Z] 7 problems: 5 warning lines and one that counts the other 2"
  has "$(ctx "$raw")" "and 2 more problem(s)" "[Z] …that line says 2"
  has "$(sysm "$raw")" "7 warning(s)" "[Z] …and the system message counts 7"
}

# ── [W] dedup: a pack rule never answers for a repo rule of its name ─────────
fam_dedup() {
  local P=$1 A C D ss
  A=$(app); C=$(fresh)/cfg; D=$(pack "$C" dep@acme dep); rule "$D" deploy.instructions.md - '.' - 'PACK-DEPLOY'; reg "$C" "dep@acme=$D"
  ss=$(sid)
  has "$(hbs "$P" "$A" "$C" "$ss" "ls")" "PACK-DEPLOY" "[W] instrument: the pack rule is reminded in this session"
  mkdir -p "$A/policy"; printf -- '---\napplyWhen: "kubectl"\ndescription: "REPO-DEPLOY"\n---\n' > "$A/policy/deploy.instructions.md"
  cfg_json "$A" '{"schema": 1, "rules": {"dirs": ["policy"]}}'
  has "$(hbs "$P" "$A" "$C" "$ss" "kubectl apply -f x")" "$A/policy/deploy.instructions.md" \
    "[W] later in the session a repo rule of the same name appears: it is reminded"
}

# ── [N] coordinated session ───────────────────────────────────────────────────
# installed <cfg> <plugin> — the plugin under test as an installed sdlc copy of marketplace acme, with the plugin's real rules (the
# core and coordinated-work), registered; prints its path
installed() {
  local d; d=$(inst_of "$1" vibemaestro-sdlc@acme); mkdir -p "$(dirname "$d")"; cp -r "$2" "$d"
  rm -rf "$d/rules"; cp -r "$PLUGIN/rules" "$d/rules"; printf '%s' "$d"
}
fixture_dep() {  # fixture_dep <cfg> <name@mkt> [marker] — the fixture dependent plugin at its install path, with the marker on request
  local d; d=$(inst_of "$1" "$2"); mkdir -p "$(dirname "$d")"; cp -r "$SRC_ROOT/tests/fixtures/dependent-plugin" "$d"
  [ "${3:-}" = marker ] && : > "$d/sdlc-coordinated"; printf '%s' "$d"
}
CW='The coordinating session states the requirement and the solution'
fam_coordinated() {
  local P=$1 A C S G O N out cat
  A=$(app); C=$(fresh)/cfg; S=$(installed "$C" "$P"); G=$(fixture_dep "$C" dependent-fixture@acme marker)
  reg "$C" "$(sdlc_entry "$C")" "dependent-fixture@acme=$G"
  out=$(hs "$S" "$A" "$C" 1)
  has "$out" "General way of working" "[N] instrument: the first SessionStart hook delivers the core"
  has "$out" "$CW" "[N] marker shipped by an enabled dependent plugin of the same marketplace: coordinated-work follows the core"
  rm "$G/sdlc-coordinated"
  out=$(hs "$S" "$A" "$C" 1); cat=$(hs "$S" "$A" "$C" 2)
  hasnt "$out" "$CW" "[N] solo control: the same plugin without the marker: not delivered"
  eq "$(printf '%s\n' "$out" | grep -c -i coordinat)" 0 "[N] solo control: the core names no coordinator"
  has "$cat" "- coordinated-work.instructions.md — Only when the work is coordinated" "[N] solo control: the catalogue lists its row"
  mkdir "$G/sdlc-coordinated"
  hasnt "$(hs "$S" "$A" "$C" 1)" "$CW" "[N] the marker is a directory: not delivered"
  rmdir "$G/sdlc-coordinated"; ln -s "$G/.claude-plugin/plugin.json" "$G/sdlc-coordinated"
  hasnt "$(hs "$S" "$A" "$C" 1)" "$CW" "[N] the marker is a symlink: not delivered"
  rm "$G/sdlc-coordinated"
  out=$(INTENT_SLUG=2026-01-01-x SEAT=s1 hs "$S" "$A" "$C" 1)
  has "$out" "$CW" "[N] sandbox arm: INTENT_SLUG and SEAT set, no marker: delivered"
  hasnt "$(SEAT=s1 hs "$S" "$A" "$C" 1)" "$CW" "[N] control: SEAT alone is not a sandbox: not delivered"
  # the marker on plugins that do not qualify, each next to the sdlc copy of marketplace acme
  C=$(fresh)/cfg; S=$(installed "$C" "$P"); O=$(fixture_dep "$C" dependent-fixture@other marker)
  reg "$C" "$(sdlc_entry "$C")" "dependent-fixture@other=$O"
  hasnt "$(hs "$S" "$A" "$C" 1)" "$CW" "[N] the marker in a plugin of another marketplace: not delivered"
  C=$(fresh)/cfg; S=$(installed "$C" "$P"); N=$(fixture_dep "$C" dependent-fixture@acme marker)
  printf '{"name": "dependent-fixture", "dependencies": []}\n' > "$N/.claude-plugin/plugin.json"
  reg "$C" "$(sdlc_entry "$C")" "dependent-fixture@acme=$N"
  hasnt "$(hs "$S" "$A" "$C" 1)" "$CW" "[N] the marker in a plugin that does not declare the dependency: not delivered"
  C=$(fresh)/cfg; S=$(installed "$C" "$P"); G=$(fixture_dep "$C" dependent-fixture@acme marker)
  reg "$C" "$(sdlc_entry "$C")" "dependent-fixture@acme=$G"
  printf '{"enabledPlugins": {"dependent-fixture@acme": false, "vibemaestro-sdlc@acme": true}}' > "$C/settings.json"
  hasnt "$(hs "$S" "$A" "$C" 1)" "$CW" "[N] the marker plugin disabled in the user settings: not delivered"
  reg "$C" "$(sdlc_entry "$C")" "dependent-fixture@acme=$G"
  O=$(fresh)/sdlc; cp -r "$P" "$O"; rm -rf "$O/rules"; cp -r "$PLUGIN/rules" "$O/rules"      # the real rules, outside the cache
  hasnt "$(hs "$O" "$A" "$C" 1)" "$CW" "[N] sdlc run from a copy outside the plugin cache (no marketplace): not delivered"
  # a marketplace added from a directory: Claude Code runs sdlc from inside its installLocation (measured, 2.1.290)
  C=$(fresh)/cfg; S="$C/plugins/marketplaces/acme/plugins/vibemaestro-sdlc"; mkdir -p "$(dirname "$S")"; cp -r "$P" "$S"
  rm -rf "$S/rules"; cp -r "$PLUGIN/rules" "$S/rules"; G=$(fixture_dep "$C" dependent-fixture@acme marker)
  reg "$C" "vibemaestro-sdlc@acme=$S" "dependent-fixture@acme=$G"
  printf '{"acme": {"source": {"source": "directory", "path": "%s"}, "installLocation": "%s"}}' "$C/plugins/marketplaces/acme" "$C/plugins/marketplaces/acme" > "$C/plugins/known_marketplaces.json"
  has "$(hs "$S" "$A" "$C" 1)" "$CW" "[N] sdlc run from a directory marketplace's installLocation (known_marketplaces.json): delivered"
  printf '{"acme": {"installLocation": "%s"}}' "$(fresh)" > "$C/plugins/known_marketplaces.json"
  hasnt "$(hs "$S" "$A" "$C" 1)" "$CW" "[N] control: the marketplace's installLocation does not hold the sdlc copy: not delivered"
  # two nested locations: the deepest one holding the copy is its marketplace, whatever the names' order
  printf '{"aaa": {"installLocation": "%s"}, "acme": {"installLocation": "%s"}}' "$C" "$C/plugins/marketplaces/acme" > "$C/plugins/known_marketplaces.json"
  has "$(hs "$S" "$A" "$C" 1)" "$CW" "[N] a broader marketplace location that also holds the copy, its name sorted first: the deepest wins, delivered"
  printf '{not json' > "$C/plugins/known_marketplaces.json"
  hasnt "$(hs "$S" "$A" "$C" 1)" "$CW" "[N] known_marketplaces.json not JSON: not delivered"
  # the marker plugin's install path outside the plugins directory
  C=$(fresh)/cfg; S=$(installed "$C" "$P"); O=$(fresh)/elsewhere; cp -r "$SRC_ROOT/tests/fixtures/dependent-plugin" "$O"; : > "$O/sdlc-coordinated"
  reg "$C" "$(sdlc_entry "$C")" "dependent-fixture@acme=$O"
  hasnt "$(hs "$S" "$A" "$C" 1)" "$CW" "[N] the marker plugin's installPath is outside the plugins directory: not delivered"
}

FAMS="fam_discovery fam_uninstall fam_scope fam_enabled fam_projdir fam_precedence fam_order fam_containment fam_cost fam_slow fam_robust fam_paths fam_size fam_dedup fam_front fam_kb fam_coordinated"
PL="$TMP/plugin"; mk_plugin "$PL"
for f in $FAMS; do echo "-- $f"; "$f" "$PL"; done

echo "-- [R] rc"
nonempty "$(cat "$RCF")" "[R] instrument: hook commands ran ($(wc -l < "$RCF" | tr -d ' '))"
empty "$(grep -v -x 0 "$RCF" | sort | uniq -c)" "[R] every hook command ended rc 0 (no timeout, no crash)"

echo "== planted breaks: each check must go red on a copy with one break =="
# BRK <label> <family> <needle> <file under scripts/> <old> <new>
BRK() { local d; d=$(fresh)/p; mk_plugin "$d"; mutate "$d/scripts/$4" "$5" "$6" && expect_red "$1" "$2" "$d" "$3"; }
BRK any-plugin fam_discovery '[D] control: the same rule in a plugin with no dependency' rule_packs.py '            return True
    return False' '            return True
    return True'
BRK config-dir-ignored fam_discovery '[D] both registries exist' rule_packs.py '    c = os.environ.get("CLAUDE_CONFIG_DIR", "")' '    c = ""'
BRK registry-order fam_order '[O] registry order zzz aaa: the rule of the first' rule_packs.py '    for pid in sorted(ids):' '    for pid in ids:'
BRK project-anywhere fam_scope '[S] a project-scope entry: absent in another project' rule_packs.py \
  '        if pp is not None and real(pp)[0] != project:' '        if False:'
BRK disabled-served fam_enabled '[E] disabled in the user settings' rule_packs.py \
  '            if enabled.get(pid) is not True:    # measured: a plugin no settings file enables is not enabled' '            if False:'
BRK unnamed-served fam_enabled '[E] named by no settings file' rule_packs.py \
  '            if enabled.get(pid) is not True:    # measured: a plugin no settings file enables is not enabled' '            if enabled.get(pid) is False:'
BRK git-root-settings fam_projdir '[J] false in the session directory' vsdlc.py '    return os.environ.get("CLAUDE_PROJECT_DIR") or troot' '    return troot'
BRK slow-not-remembered fam_slow '[B] the slow rule is skipped for the rest of the session' vsdlc.py \
  'r[0] in mine and not _marked(_slow_key(mine, r[0]), sid)]' 'r[0] in mine]'
BRK sdlc-name-taken fam_precedence '[P] …and the pack'"'"'s file is not' rules.py '                if n in own:' '                if False:'
BRK old-name-pack-served fam_precedence '[P] a pack rule named like the OLD name' rules.py '        own |= set(keep) | set(RENAMED_RULES) ' '        own |= set(keep) | set() '
BRK repo-loses fam_precedence '[P] …and the pack'"'"'s is not' rules.py '                elif repo.get(n):' '                elif False:'
BRK escape-followed fam_containment '[C] installPath escapes with ..: the pack rule is not reminded' rule_packs.py '    if not _inside(real_inst, root):' '    if False:'
d=$(fresh)/p; mk_plugin "$d"
mutate "$d/scripts/rule_packs.py" '(links if e.is_symlink() else names).append(e.name)' 'names.append(e.name)' \
  && mutate "$d/scripts/rule_packs.py" 'MAX_RULE, nofollow=True)' 'MAX_RULE)' \
  && expect_red file-escape-followed fam_containment "$d" '[C] a rule file is a symlink out: the pack rule'
BRK name-unfiltered fam_containment '[C] …that file is not' rule_packs.py '        if not n.isprintable():' '        if False:'
BRK size-uncapped fam_cost '[B] a rule file with an oversized frontmatter is skipped' rule_packs.py 'MAX_RULE = 16 << 10' 'MAX_RULE = 1 << 30'
BRK slow-budget fam_slow '[B] a catastrophic pack applyWhen: the hook returns in under 3 s' rules.py 'PACK_MATCH_SECONDS = 1.0 ' 'PACK_MATCH_SECONDS = 4.0 '
BRK front-quadratic fam_front '[F] front() on a 64 KiB' rules.py '    head = key + ":"' '    head = key + ":"
    for line in lines[1:]:
        if line.strip() == "---":
            return ""
        m = re.match(r'"'"'^%s:\s*"?(.*?)"?\s*$'"'"' % re.escape(key), line)
        if m:
            return m.group(1)'
d=$(fresh)/p; mk_plugin "$d"
mutate "$d/scripts/rules.py" '        except Exception:                      # re.error, and OverflowError or RecursionError of a pattern too big to compile' '        except re.error:' \
  && mutate "$d/scripts/rules.py" '            try:
                out.extend(match([r]))
            except Exception:
                continue' '            out.extend(match([r]))' \
  && expect_red overflow-escapes fam_robust "$d" '[Y] pack patterns too big to compile'
BRK python-walks fam_paths '[L] …and all 8 packs are served' rule_packs.py '            p = os.readlink("/proc/self/fd/%d" % fd)' '            p = os.readlink("/nonexistent")'
BRK chars-uncapped fam_size '[Z] 12 matching rules of a pack with a 1 100-character path' vsdlc.py 'PACK_CHARS_MAX = 3000' 'PACK_CHARS_MAX = 10 ** 9'
BRK warnings-squeeze fam_size '[Z] …before any repo row is shortened' vsdlc.py '        for warns in (pw, pw_one):' '        for warns in (pw,):'
BRK retired-free fam_size '[Z] two packs of 100 retired rule files' rule_packs.py '    budget["rules"] -= len(names)               # every file read counts, live or not' '    pass'
BRK lines-uncapped fam_size '[Z] 31 matching pack rules: 10 lines' vsdlc.py 'PACK_LINES_MAX = 10 ' 'PACK_LINES_MAX = 1000 '
BRK sdlc-rows-trimmed fam_size '[Z] the pack rows go first' vsdlc.py '            body = compose(own_l + pack_l[:keep], len(pack_l) - keep, warns)' '            pass'
BRK catalogue-raw fam_size '[Z] the catalogue shows a pack rule' vsdlc.py '            f = {k: _oneline(v) for k, v in f.items()}' '            pass'
BRK totals-uncapped fam_size '[Z] …the third pack is not read' rule_packs.py 'MAX_PACK_RULES = 200 ' 'MAX_PACK_RULES = 100000 '
BRK dedup-shared fam_dedup '[W] later in the session' vsdlc.py '    if mine and name in mine:' '    if False:'
BRK marker-any-file fam_coordinated '[N] the marker is a directory: not delivered' rule_packs.py \
  '        if ok and plain(os.path.join(real_inst, COORDINATED_MARKER)) == "file":' '        if ok and plain(os.path.join(real_inst, COORDINATED_MARKER)) is not None:'
BRK marker-any-market fam_coordinated '[N] the marker in a plugin of another marketplace' rule_packs.py '        if m != market or name == DEPENDENCY:' '        if name == DEPENDENCY:'
BRK marker-no-dependency fam_coordinated '[N] the marker in a plugin that does not declare the dependency' rule_packs.py \
  '            ok = man is not None and depends_on_sdlc(_json(man))' '            ok = man is not None'
BRK marker-disabled-served fam_coordinated '[N] the marker plugin disabled' rule_packs.py '        if enabled.get(cid) is not True:
            continue
        inst = entry.get("installPath")' '        inst = entry.get("installPath")'
BRK marker-ignored fam_coordinated '[N] marker shipped by an enabled dependent plugin' vsdlc.py \
  '    return in_sandbox() or rule_packs.coordinated(root, _project(troot)) is not None' '    return in_sandbox()'
BRK sandbox-ignored fam_coordinated '[N] sandbox arm' vsdlc.py \
  '    return in_sandbox() or rule_packs.coordinated(root, _project(troot)) is not None' '    return rule_packs.coordinated(root, _project(troot)) is not None'
BRK marketplace-anywhere fam_coordinated '[N] sdlc run from a copy outside the plugin cache' rule_packs.py '    me = os.path.realpath(sdlc_root)' '    return "acme"'
BRK known-location-unchecked fam_coordinated '[N] control: the marketplace'"'"'s installLocation does not hold' rule_packs.py '        if real_loc and _inside(me, real_loc) and (' '        if real_loc and ('
BRK marker-escape-followed fam_coordinated '[N] the marker plugin'"'"'s installPath is outside' rule_packs.py \
  '        if not real_inst or not _inside(real_inst, root) or plain(' '        if not real_inst or plain('
BRK nested-first-wins fam_coordinated '[N] a broader marketplace location that also holds the copy' rule_packs.py \
  'and (best is None or len(real_loc) > len(best[1])):' 'and best is None:'
BRK kb-blind fam_kb "[K] rules.disable naming a pack rule" kb.py '    packs, problems = rule_packs.load(root, root)' '    packs, problems = [], []'

echo; summary
