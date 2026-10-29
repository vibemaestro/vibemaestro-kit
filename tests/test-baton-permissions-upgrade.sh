#!/bin/bash
# =============================================================================
# kit:permissions-upgrade: the old broad ask rules swapped for the anchored ones in one owner-signed kit run, on fake machines
# =============================================================================
# Run: bash tests/test-baton-permissions-upgrade.sh
#
# A machine is a scratch HOME with its own Claude Code directory (CLAUDE_CONFIG_DIR), state directory (XDG_STATE_HOME) and project,
# the plugin under test in its plugin cache with a registry entry, the launcher installed, and user settings that hold the block
# printed before the anchored rules (its ask rules started with `*`) next to keys and rules of the user's own. Nothing runs for real: every
# write lands in the scratch tree. Families:
#   [S] the swap: permissions --check names the old rules; go stops for the owner; signed and run, exactly the old patterns are
#       gone, the anchored rules are there, every other key and rule is kept in place, the check is rc 0; run again: refused
#   [U] undo through baton's own path (a copy whose post-check fails): the file back byte for byte, its mode kept; a file that
#       changed after the run is left alone (rc 5)
#   [R] refused at rehearse, nothing written: no old rule, an old rule in the project's settings, a link, a finding the swap
#       cannot clear; the engine edited after signing or a plan with another engine sha256: refused, nothing written
# Then each planted break on its own copy must turn its family red.
# Assertions read exit codes, files, sha256 and JSON; of the output only REFUSE, LEAVE, PLAN and the baton verdict lines.
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
K=kit:permissions-upgrade

OUT="$TMP/out"; M=""; MP=""
sha_of() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"; }
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
# machine <plugin copy> — a new fake machine in $M with the plugin installed in its cache ($MP) and its launcher installed
machine() {
  local base
  M="$(fresh)/m"; base="$M/home/.claude/plugins/cache/vibemaestro"
  mkdir -p "$M/state" "$M/proj" "$base/vibemaestro-sdlc"
  MP="$base/vibemaestro-sdlc/0.3.1"; cp -R "$1" "$MP"
  grep -q '^LINEAGE = False ' "$MP/scripts/baton.py" || baton_isolate "$MP"
  printf '{"version": 2, "plugins": {"vibemaestro-sdlc@vibemaestro": [{"installPath": "%s"}]}}\n' "$MP" > "$M/home/.claude/plugins/installed_plugins.json"
  b permissions --install-launcher >/dev/null
}
SETTINGS() { printf '%s' "$M/home/.claude/settings.json"; }
# b <baton args...> — rc of the machine's own baton.py, run from its project; the output is in $OUT. The owner's sign goes through
# the plugin's guard hook first (owner_asked), as in a session whose owner clicks the dialog.
b() {
  [ "${1:-} ${2:-} ${3:-}" = "sign --by owner" ] && owner_asked "$MP" "$M/proj" "$M/state" s-owner "${@:2}" >/dev/null
  ( cd "$M/proj" && cenv HOME="$M/home" CLAUDE_CONFIG_DIR="$M/home/.claude" XDG_STATE_HOME="$M/state" CLAUDE_PROJECT_DIR="$M/proj" \
      CLAUDE_CODE_SESSION_ID=s-owner python3 "$MP/scripts/baton.py" "$@" ) > "$OUT" 2>&1
  echo $?
}
# gate <args...> — rc of the machine's own engine, called directly as a session could; the output is in $OUT
gate() {
  ( cd "$M/proj" && cenv HOME="$M/home" CLAUDE_CONFIG_DIR="$M/home/.claude" XDG_STATE_HOME="$M/state" CLAUDE_PROJECT_DIR="$M/proj" \
      python3 -I -B "$MP/gates/permissions_upgrade.py" "$@" ) > "$OUT" 2>&1
  echo $?
}
# owner_run — rehearse, sign as the owner with the seal shown, run; prints "<sign rc>/<run rc>"
owner_run() {
  local seal s
  b rehearse "$K" >/dev/null
  seal=$(sed -n 's/^seal \([^ ]*\) .*/\1/p' "$OUT")
  s=$(b sign --by owner --seal "${seal:-none}" "$K")
  printf '%s/%s' "$s" "$(b run "$K")"
}
printed() {
  ( cd "$M/proj" && cenv HOME="$M/home" CLAUDE_CONFIG_DIR="$M/home/.claude" XDG_STATE_HOME="$M/state" CLAUDE_PROJECT_DIR="$M/proj" \
      python3 "$MP/scripts/baton.py" permissions --print ) 2>/dev/null
}
jq_() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }
# old_block — the user settings as a machine set up before the anchored rules holds them: the printed allow and deny rules, the old ask list
# (the launcher's two prefix rules, `baton mode`, and the seven broad patterns), and keys and rules of the user's own
old_block() {
  printed > "$TMP/block.json"
  python3 - "$(SETTINGS)" "$TMP/block.json" "$M/state/vibemaestro/baton/bin/baton" <<'PY'
import json, sys
path, block, L = sys.argv[1:4]
blk = json.load(open(block))["permissions"]
own = "sign --by " + "owner"
old = ["Bash(%s %s:*)" % (L, own), "Bash(%s mode:*)" % L, "Bash(*baton* %s*)" % own, "Bash(baton mode:*)"] + [
    "Bash(*%s%s mode *)" % (p, q) for p in ("baton.py", "/baton") for q in ("", '"', "'")]
s = {"model": "x", "permissions": {"allow": ["Bash(ls:*)"] + blk["allow"], "ask": ["Bash(rm:*)"] + old, "deny": blk["deny"],
                                   "defaultMode": "default"},
     "attribution": {"commit": "", "pr": "", "sessionUrl": False}}
open(path, "w").write(json.dumps(s, indent=4))
PY
}
# fail_postcheck <plugin copy> [line] — that copy's kit run fails its post-check after doing <line>, so run must undo
fail_postcheck() {
  python3 - "$1/batons/permissions-upgrade.sh" "${2:-true}" <<'PY'
import re, sys
p, extra = sys.argv[1:3]
t = open(p).read()
t, n = re.subn(r"\npostcheck\(\) \{\n", "\npostcheck() {\n  %s\n  return 1\n" % extra, t, count=1)
assert n == 1, "no postcheck() in " + p
open(p, "w").write(t)
PY
}

fam_swap() {
  local P=$1 s sigs
  machine "$P"; old_block
  eq "$(b permissions --check)" 7 "[S] instrument: the old block fails permissions --check (rc 7)"
  eq "$(grep -c 'the old broad ask rule .*kit:permissions-upgrade' "$OUT")" 7 "[S] …each of the 7 old patterns named, with the kit"
  eq "$(b check "$K")" 0 "[S] check $K: rc 0"
  eq "$(b rehearse "$K")" 0 "[S] rehearse: rc 0"
  hasline "$(cat "$OUT")" "  PLAN-COUNT 1" "[S] …one write"
  has "$(grep '^  PLAN upgrade settings ' "$OUT")" "ask -7 [" "[S] …the plan line removes 7 rules"
  has "$(grep '^  PLAN upgrade settings ' "$OUT")" '"Bash(*baton.py\" mode *)"' "[S] …and names each one"
  has "$(grep '^  PLAN upgrade settings ' "$OUT")" ", engine sha256 " "[S] …and binds the engine's sha256"
  s=$(sha_of "$(SETTINGS)")
  eq "$(b go "$K")" 8 "[S] go: exit 8 (Stops security-boundary: the owner signs)"
  has "$(grep '^  Why: ' "$OUT")" "an owner in auto confirms the mode once more (one dialog) and trusts the remote list again" \
      "[S] …the decision card names the cost of this version (the mode confirmed once more, the remote list again)"
  eq "$(sha_of "$(SETTINGS)")" "$s" "[S] …nothing written before the owner's signature"
  baton_set_mode "$M/state" auto; b rehearse "$K" >/dev/null
  eq "$(b sign --by coordinator-auto --seal "$(sed -n 's/^seal \([^ ]*\) .*/\1/p' "$OUT")" "$K")" 3 \
     "[S] mode auto: the session cannot sign it as coordinator-auto (rc 3)"
  eq "$(owner_run)" "0/0" "[S] signed by the owner and run: rc 0"
  eq "$(b permissions --check)" 0 "[S] …permissions --check: rc 0"
  printed > "$TMP/now.json"
  eq "$(python3 - "$(SETTINGS)" "$TMP/now.json" <<'PY'
import json, sys
s, p = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))["permissions"]
ask = s["permissions"]["ask"]
print(" ".join([str(not any(r.startswith("Bash(*") for r in ask)), str(all(r in ask for r in p["ask"])), ask[0],
                str(s["model"]), str(s["permissions"]["defaultMode"]), str(s["permissions"]["allow"][0]),
                str(s["permissions"]["deny"] == p["deny"]), str(sorted(s["attribution"]))]))
PY
)" "True True Bash(rm:*) x default Bash(ls:*) True ['commit', 'pr', 'sessionUrl']" \
     "[S] …no rule starts with *, every anchored rule is there; the user's own ask rule, keys, allow and deny rules kept in place"
  eq "$(jq_ "$(SETTINGS)" 'len(d["permissions"]["ask"])')" "$(jq_ "$TMP/now.json" '1 + len(d["permissions"]["ask"])')" \
     "[S] …the ask list is the user's rule and the anchored rules, nothing else (the old prefix rules among them, once)"
  s=$(sha_of "$(SETTINGS)"); sigs=$(ls "$M/state/vibemaestro/baton/signatures" | wc -l | tr -d ' ')
  eq "$(b rehearse "$K")" 1 "[S] run again: the rehearse fails (rc 1)"
  has "$(cat "$OUT")" "REFUSE nothing to do" "[S] …REFUSE nothing to do"
  eq "$(b go "$K")/$(sha_of "$(SETTINGS)")" "1/$s" "[S] go again: rc 1, the settings unchanged"
  eq "$(ls "$M/state/vibemaestro/baton/signatures" | wc -l | tr -d ' ')" "$sigs" "[S] …and nothing was signed"
  eq "$(gate postcheck)" 0 "[S] the engine's post-check on the swapped file: rc 0"
  machine "$P"; old_block
  eq "$(gate postcheck)" 1 "[S] the engine's post-check on the old block: rc 1"
}

fam_undo() {
  local P=$1 C s
  C="$P.pcfail"; rm -rf "$C"; cp -R "$P" "$C"; fail_postcheck "$C"
  machine "$C"; old_block; chmod 640 "$(SETTINGS)"
  s=$(sha_of "$(SETTINGS)")
  eq "$(owner_run)" "0/4" "[U] a run whose post-check fails: rc 4, undone"
  eq "$(sha_of "$(SETTINGS)")/$(mode_of "$(SETTINGS)")" "$s/640" "[U] the settings back byte for byte, their mode kept"
  C="$P.pcmove"; rm -rf "$C"; cp -R "$P" "$C"
  fail_postcheck "$C" 'printf " " >> "$CLAUDE_CONFIG_DIR/settings.json"'
  machine "$C"; old_block
  eq "$(owner_run)" "0/5" "[U] the settings changed after the run: rc 5, the state left to the owner"
  has "$(cat "$OUT")" "LEAVE" "[U] …the output says what it left"
  eq "$(tail -c 1 "$(SETTINGS)")" " " "[U] …the changed file is left as it is"
}

fam_refused() {
  local P=$1 s seal
  machine "$P"; printed > "$(SETTINGS)"
  eq "$(b rehearse "$K")" 1 "[R] the anchored block already: rehearse fails"
  has "$(cat "$OUT")" "REFUSE nothing to do" "[R] …nothing to do"
  machine "$P"
  eq "$(b rehearse "$K")" 1 "[R] no user settings file: rehearse fails"
  [ ! -e "$(SETTINGS)" ] && ok "[R] …and none is created" || bad "[R] …and none is created"
  machine "$P"; old_block; mkdir -p "$M/proj/.claude"
  printf '{"permissions": {"ask": ["Bash(*baton* sign --by owner*)"]}}\n' > "$M/proj/.claude/settings.json"
  s=$(sha_of "$(SETTINGS)")
  eq "$(b rehearse "$K")" 1 "[R] an old pattern in the project's settings too: rehearse fails"
  has "$(cat "$OUT")" "REFUSE an old ask rule sits in another settings scope" "[R] …refused, the scope named"
  has "$(cat "$OUT")" "$M/proj/.claude/settings.json" "[R] …with its file"
  eq "$(sha_of "$(SETTINGS)")" "$s" "[R] …the user settings unchanged"
  machine "$P"; old_block
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["permissions"]["allow"].append("Bash(*)"); json.dump(d, open(p, "w"))' "$(SETTINGS)"
  s=$(sha_of "$(SETTINGS)")
  eq "$(b rehearse "$K")" 1 "[R] an allow rule the swap cannot clear: rehearse fails"
  has "$(cat "$OUT")" "REFUSE the swap cannot reach a clean permissions --check" "[R] …refused, it cannot reach a clean check"
  has "$(cat "$OUT")" "UNSAFE" "[R] …it names the finding"
  eq "$(sha_of "$(SETTINGS)")" "$s" "[R] …unchanged"
  machine "$P"; old_block; mv "$(SETTINGS)" "$M/home/.claude/real.json"; ln -s real.json "$(SETTINGS)"
  eq "$(b rehearse "$K")" 1 "[R] the user settings a symbolic link: rehearse fails"
  has "$(cat "$OUT")" "is a symbolic link" "[R] …refused, named"
  machine "$P"; old_block; s=$(sha_of "$(SETTINGS)")
  b rehearse "$K" >/dev/null
  sed -n 's/^  PLAN \(upgrade .*, engine sha256 \)[0-9a-f]\{64\}$/\1'"$(printf '0%.0s' $(seq 64))"'/p' "$OUT" > "$TMP/wrong-sha.plan"
  eq "$(wc -l < "$TMP/wrong-sha.plan" | tr -d ' ')" 1 "[R] instrument: the plan line with another engine sha256"
  eq "$(gate do --expect-plan "$TMP/wrong-sha.plan")/$(sha_of "$(SETTINGS)")" "3/$s" "[R] a write whose signed engine sha256 is not the engine's: refused (rc 3), nothing written"
  b rehearse "$K" >/dev/null; seal=$(sed -n 's/^seal \([^ ]*\) .*/\1/p' "$OUT")
  eq "$(b sign --by owner --seal "${seal:-none}" "$K")" 0 "[R] signed by the owner"
  printf '\n# changed after the signature\n' >> "$MP/gates/permissions_upgrade.py"
  eq "$(b run "$K")/$(sha_of "$(SETTINGS)")" "3/$s" "[R] the engine edited after signing: run refused (rc 3), nothing written"
}

fam_order() {  # [B] the old block that also lacks a rule: kit:coordinator-bootstrap adds it, then this kit swaps; neither blocks the other
  local P=$1
  machine "$P"; old_block
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["permissions"]["allow"] = [r for r in d["permissions"]["allow"] if " go:" not in r]; json.dump(d, open(p, "w"))' "$(SETTINGS)"
  eq "$(b rehearse "$K")" 1 "[B] the old block lacking the allow for go: this kit refuses"
  has "$(cat "$OUT")" "with kit:coordinator-bootstrap" "[B] …and sends the owner to kit:coordinator-bootstrap"
  eq "$(K=kit:coordinator-bootstrap owner_run)" "0/0" "[B] kit:coordinator-bootstrap: its run adds the missing rule with the old ask rules still there: rc 0"
  eq "$(b permissions --check)" 7 "[B] …the old ask rules are left for this kit"
  hasnt "$(cat "$OUT")" "MISSING" "[B] …nothing is missing any more"
  eq "$(owner_run)" "0/0" "[B] then this kit: rc 0"
  eq "$(b permissions --check)" 0 "[B] …permissions --check: rc 0"
}

FAMILIES="fam_swap fam_undo fam_refused fam_order"
echo "== the real plugin =="
REAL="$TMP/real"; mk_plugin_copy "$REAL"
for f in $FAMILIES; do echo "-- $f"; "$f" "$REAL"; done

echo "== planted breaks: each one must turn its family red =="
# BRK <label> <family> <needle> <file under the plugin> <old> <new> [<old> <new>...]
BRK() {
  local label=$1 fam=$2 needle=$3 file=$4 d; shift 4; d="$TMP/break-$label"; mk_plugin_copy "$d"
  while [ $# -ge 2 ]; do mutate "$d/$file" "$1" "$2" || return; shift 2; done
  expect_red "$label" "$fam" "$d" "$needle"
}
G=gates/permissions_upgrade.py
BRK undo-no-restore fam_undo '[U] the settings back byte for byte' $G '        write_atomic(user, old, int(rec.get("mode", 0o600)))' '        pass'
BRK undo-mode-lost fam_undo '[U] the settings back byte for byte' $G '        write_atomic(user, old, int(rec.get("mode", 0o600)))' '        write_atomic(user, old, 0o600)'
BRK undo-blind fam_undo '[U] …the changed file is left as it is' $G '    if now == rec.get("after"):' '    if True:'
BRK removes-extra fam_swap "[S] …no rule starts with *, every anchored rule is there; the user's own" $G \
    '    kept = [r for r in ask if r not in B.OLD_ASKS]' '    kept = [r for r in ask if r not in B.OLD_ASKS and r != "Bash(rm:*)"]'
BRK keeps-old fam_swap '[S] …permissions --check: rc 0' $G '    kept = [r for r in ask if r not in B.OLD_ASKS]' '    kept = [r for r in ask if r not in B.OLD_ASKS[1:]]'
BRK postcheck-blind fam_swap "[S] the engine's post-check on the old block: rc 1" $G '    return OK if not found else FAIL' '    return OK'
BRK engine-unbound fam_refused '[R] a write whose signed engine sha256' $G \
    '    if p.refusal or p.line + ENGINE_SUFFIX + engine_hash() not in signed:' '    if p.refusal or not any(ln.startswith(p.line) for ln in signed):'
BRK other-scope-ignored fam_refused '[R] …refused, the scope named' $G '    if elsewhere:' '    if False:'
BRK unclean-accepted fam_refused '[R] an allow rule the swap cannot clear' $G '    if after:' '    if False:'
BRK bootstrap-blocks-on-old fam_order '[B] kit:coordinator-bootstrap: its run adds the missing rule' gates/coordinator_bootstrap.py \
    '    return f[1].startswith(B.OLD_ASK_FINDING)' '    return False'
BRK stops-none fam_swap '[S] mode auto: the session cannot sign it' batons/permissions-upgrade.sh '# Stops: security-boundary' '# Stops: none'

echo "== nothing written outside the scratch tree =="
eq "$(tree_hash "$SRC_ROOT")" "$H0" "the repository tree is unchanged by the suite"
echo; summary
