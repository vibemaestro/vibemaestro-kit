#!/bin/bash
# =============================================================================
# Config compatibility: an older reader meets a newer config, a newer reader meets an older one (rule config-compat)
# =============================================================================
# Run: bash tests/test-config-compat.sh
#
# The floor is the oldest reader the kit supports: a snapshot of sdlc_config.py, tests/fixtures/config_compat/floor/reader.py (one stdlib
# file, so a shallow CI clone needs no history), named by sha256 in floor.txt. Both it and the plugin's reader get this repo's
# .vibemaestro/sdlc.json ({} on the public export, which does not carry it) and future-keys.json (keys a newer plugin may define): no problem, one note per unknown key. A known key
# with a wrong type and a newer schema still refuse. The plugin's reader also gets old configs, and its schema is compared with
# the floor's: a key the floor reads that vanished or changed type must be listed in DEPRECATED. The checks themselves are
# tests/fixtures/config_compat/compat_check.py; each family runs on the real plugin. The
# deny family holds the default deny globs (row d, Q2a): only .vibemaestro/batons/** left the default; an own list is kept.
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
FX="$HERE/fixtures/config_compat"
REPO_CFG="$SRC_ROOT/.vibemaestro/sdlc.json"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"

# The repo config is on public.private: the private tree has it, the public export does not (fixtures/lib.sh tree_shape), and the
# readers then get {} for "this repo's config", what a public clone reads
echo "== the tree =="
case "$(tree_shape "$SRC_ROOT")" in
  private) [ -f "$REPO_CFG" ] && ok "the private tree: the readers get this repo's .vibemaestro/sdlc.json" || bad "the private tree: .vibemaestro/sdlc.json is not a file";;
  export) ok "the public export: no .vibemaestro/sdlc.json (it is private), the readers get {}"; REPO_CFG="";;
  *) bad "the tree is neither the private repo nor the public export (fixtures/lib.sh tree_shape: kb/, .vibemaestro/sdlc.json, a plugin LICENSE)";;
esac
PLX=""

# compat <family> — the checker's lines as ok/bad (a checker that dies is one failed check, not silence)
compat() {
  local out line rc
  out=$(cenv python3 -I -B "$FX/compat_check.py" "$1" "$PLX" "$FX/floor" "$FX" "$REPO_CFG" 2>&1); rc=$?
  [ "$rc" = 0 ] || bad "[$1] the checker exits $rc: ${out:0:300}"
  while IFS= read -r line; do
    case "$line" in
      ok$'\t'*) ok "${line#ok$'\t'}";;
      FAIL$'\t'*) bad "${line#FAIL$'\t'}";;
    esac
  done <<<"$out"
}
fam_forward()    { PLX=$1; compat forward; }
fam_backward()   { PLX=$1; compat backward; }
fam_deprecated() { PLX=$1; compat deprecated; }
fam_migrate()    { PLX=$1; compat migrate; }
fam_deny()       { PLX=$1; compat deny; }

# the command line a person runs: kb.py config check warns and exits 0, a newer schema exits 65 naming the update
fam_cli() {
  PLX=$1; local R out rc
  R=$(fresh); git_ init -q "$R"; mkdir -p "$R/.vibemaestro"; cp "$FX/future-keys.json" "$R/.vibemaestro/sdlc.json"
  out=$(cd "$TMP" && cenv python3 "$PLX/scripts/kb.py" config check --root "$R" 2>&1); rc=$?
  eq "$rc" 0 "[C] kb.py config check on keys of a newer plugin: rc 0"
  has "$out" "WARNING future_section: unknown key (ignored" "[C] …a WARNING line names the unknown section"
  has "$out" "WARNING pr.future_key: unknown key (ignored" "[C] …and the unknown nested key"
  out=$(cd "$R" && cenv python3 "$PLX/scripts/kb.py" list --type intent 2>&1); rc=$?
  eq "$rc" 0 "[C] another kb.py command on that config runs: rc 0"
  has "$out" "WARNING .vibemaestro/sdlc.json: future_section: unknown key" "[C] …and prints the note on stderr"
  out=$(cd "$TMP" && cenv python3 "$PLX/scripts/sdlc_config.py" get branch.intent_prefix --root "$R" 2>&1); rc=$?
  eq "$rc:$out" "0:intent/" "[C] sdlc_config.py get on that config prints the value alone (the adapters capture it with 2>&1)"
  out=$(cd "$R" && cenv python3 "$PLX/scripts/kb.py" config migrate 2>&1); rc=$?
  eq "$rc" 0 "[C] kb.py config migrate on a config at the plugin's schema: rc 0"; has "$out" "nothing to migrate" "[C] …nothing to migrate"
  printf '{"schema": 99}' > "$R/.vibemaestro/sdlc.json"
  out=$(cd "$TMP" && cenv python3 "$PLX/scripts/kb.py" config check --root "$R" 2>&1); rc=$?
  eq "$rc" 65 "[C] kb.py config check on a newer schema: rc 65"
  has "$out" "claude plugin update vibemaestro-sdlc@vibemaestro" "[C] …naming the update to run"
}

FAMILIES="fam_forward fam_backward fam_deprecated fam_migrate fam_cli fam_deny"

echo "== the real plugin =="
PL0="$TMP/plugin-real"; mk_plugin_copy "$PL0"
for f in $FAMILIES; do echo "-- $f"; "$f" "$PL0"; done

echo; summary
