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
# tests/fixtures/config_compat/compat_check.py; each family runs on the real plugin, then on a copy with one planted break. The
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

echo "== planted breaks: each family must go red on a plugin with one break =="
BRK() {  # BRK <label> <family> <needle> <file under the plugin> <old> <new>
  local d="$TMP/break-$1"; mk_plugin_copy "$d"
  mutate "$d/$4" "$5" "$6" && expect_red "$1" "$2" "$d" "$3"
}
BRK required-key-no-default fam_backward '[B] every schema key has a default' scripts/sdlc_config.py \
  '    "kb": ("obj", {"spec_warn_bytes": ("intnull", 1)}),' '    "kb": ("obj", {"spec_warn_bytes": ("intnull", 1), "required_new": ("int", 1)}),'
BRK floor-key-removed fam_backward '[B] a key the floor reader knows is still in the schema' scripts/sdlc_config.py \
  '        "inject": ("bool",),' ''
BRK nullable-subkey-retyped fam_backward '[B] a key the floor reader knows keeps its type' scripts/sdlc_config.py \
  '"planner": ("objnull", {"script": ("gitfile",), "inputs": ("gitfiles",)},' '"planner": ("objnull", {"script": ("gitfile",), "inputs": ("str",)},'
BRK item-key-dropped fam_backward '[B] a key of a list item' scripts/sdlc_config.py \
  'ITEM_FIELDS = {"tables": ("heading", "columns", "enums", "decorations"),' 'ITEM_FIELDS = {"tables": ("heading", "columns", "enums"),'
BRK item-key-kept fam_forward "[F] plugin reader: …a list item's unknown key too" scripts/sdlc_config.py \
  '        return [{k: x for k, x in item.items() if k in keep} if isinstance(item, dict) else item for item in v]' '        return v'
BRK key-unescaped fam_forward '[F] plugin reader: a key is printed with its control characters escaped' scripts/sdlc_config.py \
  '    return k if len(k) <= 120 else k[:119] + "…"' '    return key'
BRK note-every-copy fam_forward '[F] plugin reader: a note is printed once per process' scripts/sdlc_config.py \
  '            if line not in _NOTED:' '            if True:'
BRK get-prints-notes fam_cli '[C] sdlc_config.py get on that config prints the value alone' scripts/sdlc_config.py \
  'else load(repo_root(root), quiet=True)' 'else load(repo_root(root))'
BRK moved-value-unchecked fam_deprecated "[P] a moved value is checked against the new key's type" scripts/sdlc_config.py \
  '    if moved is not data:' '    if False:'
BRK forward-under-null-crashes fam_deprecated '[P] a new key under an object set to null' scripts/sdlc_config.py \
  '            if not isinstance(cur, dict):
                ok = False
                break' '            pass'
BRK floor-key-retyped fam_backward '[B] a key the floor reader knows keeps its type' scripts/sdlc_config.py \
  '        "draft": ("bool",),' '        "draft": ("str",),'
BRK unknown-key-refused fam_forward '[F] plugin reader: a config with keys of a newer plugin is valid' scripts/sdlc_config.py \
  '    probs = [p for p in out if not isinstance(p[1], Note)]' '    probs = list(out)'
BRK unknown-key-kept fam_forward '[F] plugin reader: …and is dropped from the effective config' scripts/sdlc_config.py \
  '    data = _forward(_strip(data, ("obj", SCHEMA_TREE)))' '    data = _forward(data)'
BRK wrong-type-ignored fam_forward '[F] plugin reader: a known key with a wrong type still refuses' scripts/sdlc_config.py \
  '            out.append((key, "must be true or false"))' '            pass'
BRK schema-hint-dropped fam_forward '[F] plugin reader: …naming the update to run' scripts/sdlc_config.py \
  'UPDATE_HINT = ("update the plugin (claude plugin marketplace update vibemaestro && claude plugin update vibemaestro-sdlc@vibemaestro), "' 'UPDATE_HINT = ("update the plugin, "'
BRK deprecated-not-forwarded fam_deprecated "[P] the old key's value moves to the new key" scripts/sdlc_config.py \
  '        if not found or _lookup(out, d["use"])[0]:' '        if True:'
BRK deprecated-note-unnamed fam_deprecated '[P] its note names the new key' scripts/sdlc_config.py \
  '        what = "use %s instead%s" % (d["use"], " (when both are set, %s wins)" % d["use"] if not d.get("removed") else "")' '        what = "use the new key instead"'
BRK deprecated-not-noted fam_deprecated '[P] a deprecated key with no new form' scripts/sdlc_config.py \
  '        if not d.get("removed") and _lookup(data, key)[0]:' '        if False:'
BRK migrate-skips-step fam_migrate '[M] a planted step carries a config up one schema' scripts/sdlc_config.py \
  '        out = MIGRATIONS[n](out)' '        pass'
BRK migrate-writes-invalid fam_migrate '[M] config migrate --write with a result that would be invalid' scripts/kb.py \
  '    bad = C.problems(out)' '    bad = []'
BRK migrate-leaves-temp fam_migrate '[M] config migrate --write writes the migrated config, and no temp file is left' scripts/kb.py \
  '            os.replace(tmp, C.config_path(root))
        finally:
            if os.path.lexists(tmp):
                os.unlink(tmp)' '            import shutil; shutil.copy(tmp, C.config_path(root))
        finally:
            pass'
BRK problem-key-raw fam_forward '[F] plugin reader: …a problem key from the file too' scripts/sdlc_config.py \
  '    return [(_safe(k), why) for k, why in probs], notes' '    return probs, notes'
BRK cli-note-silent fam_cli '[C] …a WARNING line names the unknown section' scripts/kb.py \
  '        lines = ["WARNING %s: %s" % (k, why) for k, why in C.load_notes(root)] + lines' '        pass'
BRK deny-batons-kept fam_deny '[D] the default leaves .vibemaestro/batons/merge-x.sh' scripts/sdlc_config.py \
  'MERGE_DENY_DEFAULT = (".github/workflows/**", ".vibemaestro/*", ".vibemaestro/gates/**", ".vibemaestro/rules/**", "**/*secret*")' 'MERGE_DENY_DEFAULT = (".github/workflows/**", ".vibemaestro/**", "**/*secret*")'
BRK deny-config-open fam_deny '[D] the default denies .vibemaestro/sdlc.json' scripts/sdlc_config.py \
  'MERGE_DENY_DEFAULT = (".github/workflows/**", ".vibemaestro/*", ".vibemaestro/gates/**", ".vibemaestro/rules/**", "**/*secret*")' 'MERGE_DENY_DEFAULT = (".github/workflows/**", ".vibemaestro/gates/**", ".vibemaestro/rules/**", "**/*secret*")'
BRK deny-gates-open fam_deny '[D] the default denies .vibemaestro/gates/x.py' scripts/sdlc_config.py \
  'MERGE_DENY_DEFAULT = (".github/workflows/**", ".vibemaestro/*", ".vibemaestro/gates/**", ".vibemaestro/rules/**", "**/*secret*")' 'MERGE_DENY_DEFAULT = (".github/workflows/**", ".vibemaestro/*", ".vibemaestro/rules/**", "**/*secret*")'
BRK deny-own-merged fam_deny '[D] plugin reader: a config that sets merge.deny_globs keeps exactly its list' scripts/sdlc_config.py \
  '    return _normalise(_merge(_with_preset(data), data))' '    out = _normalise(_merge(_with_preset(data), data)); out["merge"]["deny_globs"] = list(MERGE_DENY_DEFAULT); return out'
PLC="$TMP/break-none"; mk_plugin_copy "$PLC"
QN=0; okdef=$(declare -f ok); baddef=$(declare -f bad); sp=$PASS; sf=$FAIL
ok() { :; }; bad() { QN=$((QN+1)); }
for f in $FAMILIES; do "$f" "$PLC" >/dev/null 2>&1; done
eval "$okdef"; eval "$baddef"; PASS=$sp; FAIL=$sf
eq "$QN" 0 "control: an unbroken copy passes every family (no failed check)"

echo; summary
