#!/bin/bash
# =============================================================================
# vibemaestro-brain: the owner's SOUL step carries its line (`--soul-line "[S14] text"`), the dialog shows it, and kit:soul-line
# writes it into the project's soul_file right after the step
# =============================================================================
# Run: bash tests/test-brain-soul-line.sh
#
# Offline. The brain and sdlc of the kit copy side by side, the baton mode of each project's state auto; owner writes go through
# an "asked" record, as guard-owner leaves it after the owner's click.
#   [p] promote: the dialog line names the line and the file; the step's op carries soul_line; the baton adds the line; the review
#       card shows no difference; in mode manual the step is written and the line waits, the message says how to run it
#   [r] refused before any write: no soul_file, a value with no code, a quote, a second code, a code the pointer does not name
#   [e] an extension's archive adds the line (the code from the pointer); its pin removes it when the extension demotes that
#       code, and is refused when it demotes another or none
#   [b] the record binds the line and the file the dialog showed: soul_file pointed elsewhere (or through a new link) between
#       the dialog and the write, or a record with no binding: refused (6), nothing written, no baton run; one call resolves
#       the file once (the dialog and the digest name the same file even when a link moves between them); a soul_file with a
#       character the dialog cannot show plainly: refused
# =============================================================================
set -uo pipefail
if [ -z "${BRAIN_SUITE_REEXEC:-}" ]; then
  export PYTHONUSERBASE="${PYTHONUSERBASE:-$(python3 -m site --user-base 2>/dev/null)}"
  exec env -u CLAUDE_CONFIG_DIR -u CLAUDE_CODE_SESSION_ID BRAIN_SUITE_REEXEC=1 HOME=/nonexistent bash "$0" "$@"
fi
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap '[ -n "$TMP" ] && rm -rf "$TMP"' EXIT
clean_env "$TMP"
# shellcheck source=fixtures/brain.sh
. "$HERE/fixtures/brain.sh"
brain_kit "$SRC_ROOT"
FIX="$HERE/fixtures/brain-extension"
BO=$(printf 'brain %s' owner)
EID=brain-ext-example@m

cfg_new() {  # cfg_new — a fresh Claude Code config directory with no plugin, for this project
  export CLAUDE_CONFIG_DIR="$TMP/cfg$NP"
  rm -rf "$CLAUDE_CONFIG_DIR"; mkdir -p "$CLAUDE_CONFIG_DIR/plugins"
  printf '{"version": 2, "plugins": {}}\n' > "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
  printf '{"enabledPlugins": {}}\n' > "$CLAUDE_CONFIG_DIR/settings.json"
}
install() {  # install <source dir> — the example extension copied into the plugin cache, registered and enabled
  local ext="$CLAUDE_CONFIG_DIR/plugins/cache/m/brain-ext-example/1.0.0"
  rm -rf "$ext"; mkdir -p "$(dirname "$ext")"; cp -R "$1" "$ext"
  mkdir -p "$ext/.claude-plugin"; [ -f "$ext/plugin.json" ] && mv "$ext/plugin.json" "$ext/.claude-plugin/plugin.json"
  python3 - "$CLAUDE_CONFIG_DIR" "$EID" "$ext" <<'PY'
import json, os, sys
cfg, pid, root = sys.argv[1:4]
p = os.path.join(cfg, "plugins", "installed_plugins.json"); r = json.load(open(p))
r["plugins"][pid] = [{"scope": "user", "installPath": root}]; json.dump(r, open(p, "w", newline=""))
p = os.path.join(cfg, "settings.json"); s = json.load(open(p))
s["enabledPlugins"][pid] = True; json.dump(s, open(p, "w", newline=""))
PY
}
variant() {  # variant <python> — a copy of the example whose answer(q) runs first (None falls back to the example's own); VAR
             # its directory (an input built for the brain, not a break)
  VAR="$TMP/var-$NP"
  rm -rf "$VAR"; cp -R "$FIX" "$VAR"; cp "$FIX/brain/extension.py" "$VAR/brain/example.py"
  { printf 'import json, os, sys\nsys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))\nimport example\n'
    printf '%s\n' "$1"
    printf 'q = json.loads(sys.stdin.read())\nout = answer(q)\nsys.stdout.write(json.dumps(example.answer(q) if out is None else out))\n'
  } > "$VAR/brain/extension.py"
}
np() {  # a project with a brain, a SOUL file, soul_file set, baton mode auto
  newp; cfg_new; br op add --kind now --text "the task at hand"
  printf '# Shared rules\n- [S07] one review round\n' > "$P/SOUL.md"
  mkdir -p "$P/.vibemaestro"; printf '{"soul_file": "SOUL.md"}\n' > "$P/.vibemaestro/brain.json"
  baton_set_mode "$XDG_STATE_HOME" auto
}
cmdline() { python3 -c 'import shlex, sys; print(shlex.join(sys.argv[1:]))' "$@"; }
gown() {  # gown <args after owner…> — guard-owner, default mode, on that literal command, for session SID in project P
  hk guard-owner "$(python3 -c 'import json, sys
print(json.dumps({"session_id": sys.argv[1], "cwd": sys.argv[2], "hook_event_name": "PreToolUse", "tool_name": "Bash",
                  "permission_mode": "default", "tool_input": {"command": sys.argv[3]}}))' "$SID" "$P" "$(cmdline $BO "$@")")"
}
owner_g() { gown "$@"; br owner "$@"; }   # owner_g <args after owner…> — the owner's dialog through guard-owner, then the write
lastop() { grep '"op":"owner-' "$(sdir)/hot.jsonl" | tail -n 1; }
card() { bpy 'import time, brain_ledger as L
st, ops, led = L.snapshot(s.state_dir()); print("\n".join(s.card_lines(st, time.time(), ops=ops, d=s.state_dir())))'; }

case_promote() {
  if [ "${OS:-}" = Windows_NT ]; then c_skip "[p] a promote writes its SOUL line through kit:soul-line" "a SOUL line is written through vibemaestro-sdlc's baton go, which does not run on Windows yet (a signed run needs the owner's dialog)"; return; fi
  local real
  np; owner_ok add --kind decision --text "one owner, one signature" --owner-quote q --where chat
  real=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$P/SOUL.md")
  gown promote D1 "CLAUDE.md [S14]" --soul-line "[S14] one owner, one signature"
  c_eq "$(hfield permissionDecision)" ask "[p] guard-owner asks"
  c_eq "$(hfield permissionDecisionReason)" "Promote owner decision D1 to \"CLAUDE.md [S14]\": \"one owner, one signature\"; then kit:soul-line adds the line \"- [S14] one owner, one signature\" to $real" \
       "[p] the dialog names the line and the file"
  br owner promote D1 "CLAUDE.md [S14]" --soul-line "[S14] one owner, one signature"
  c_rc 0 "[p] the step is written (the record guard-owner left)"
  c_has "$OUT" "the SOUL line [S14] added to $real (kit:soul-line)" "[p] the baton added the line"
  c_eq "$(cat "$P/SOUL.md")" "$(printf '# Shared rules\n- [S07] one review round\n- [S14] one owner, one signature')" "[p] the file holds it after the last SOUL line"
  c_has "$(lastop)" "\"soul_line\":{\"action\":\"add\",\"code\":\"S14\"" "[p] the step's op carries the line"
  c_has "$(card)" "SOUL file SOUL.md differs: [S07] not promoted" "[p] the card: S14 agrees, only the hand-written S07 differs"
  c_hasnt "$(card)" "[S14]" "[p] …and S14 is not named"
  # mode manual: the step stands, the line waits for a signature
  np; rm -f "$XDG_STATE_HOME/vibemaestro/baton/mode"; baton_set_mode "$XDG_STATE_HOME" manual
  owner_ok add --kind decision --text "x" --owner-quote q --where chat
  owner_g promote D1 "CLAUDE.md [S15]" --soul-line "[S15] x"
  c_rc 0 "[p] mode manual: the step is written"
  c_has "$OUT" "the SOUL line [S15] waits for a signature (this machine's baton mode)" "[p] …the line waits"
  c_has "$OUT" "baton go kit:soul-line --file" "[p] …with the call the session runs"
  c_eq "$(grep -c S15 "$P/SOUL.md")" 0 "[p] …and the file is unchanged"
}

case_refused() {
  local s
  np; owner_ok add --kind decision --text "x" --owner-quote q --where chat; s=$(cat "$P/SOUL.md")
  printf '{}\n' > "$P/.vibemaestro/brain.json"
  owner_ok promote D1 "CLAUDE.md [S14]" --soul-line "[S14] x"; c_rc 1 "[r] no soul_file: refused"
  c_has "$OUT" "--soul-line needs soul_file" "[r] …says so"
  printf '{"soul_file": "SOUL.md"}\n' > "$P/.vibemaestro/brain.json"
  owner_ok promote D1 "CLAUDE.md [S14]" --soul-line "no code here"; c_rc 1 "[r] a value with no code: refused"
  owner_ok promote D1 "CLAUDE.md [S14]" --soul-line '[S14] a "quoted" word'; c_rc 1 "[r] a quote: refused"
  owner_ok promote D1 "CLAUDE.md [S14]" --soul-line "[S14] see [S07]"; c_rc 1 "[r] a second code: refused"
  owner_ok promote D1 "CLAUDE.md [S14]" --soul-line "[S15] x"; c_rc 1 "[r] a code the pointer does not name: refused"
  gown promote D1 "CLAUDE.md [S14]" --soul-line "[S15] x"; c_eq "$(hfield permissionDecision)" deny "[r] …and guard-owner denies it before asking"
  c_eq "$(bpy 'print(s.load(s.state_dir())[1]["items"]["D1"]["status"])')|$(cat "$P/SOUL.md")" "live|$s" "[r] nothing written: D1 live, the file unchanged"
}

case_ext() {
  if [ "${OS:-}" = Windows_NT ]; then c_skip "[e] an extension's verb writes and removes a SOUL line" "a SOUL line is written through vibemaestro-sdlc's baton go, which does not run on Windows yet (a signed run needs the owner's dialog)"; return; fi
  np; install "$FIX"
  br op add --kind trap --text "check the base before a rebase"
  owner_g shelve T1 "CLAUDE.md [S14]" --soul-line "[S14] check the base before a rebase"; c_rc 0 "[e] the extension's archive: written"
  c_has "$OUT" "the SOUL line [S14] added to" "[e] …and the line added"
  c_eq "$(grep -c '^- \[S14\] check the base before a rebase$' "$P/SOUL.md")" 1 "[e] …in the file"
  owner_ok vouch tag-1 --text "x" --owner-quote q --where chat --soul-line "[S14] check the base before a rebase"
  c_rc 1 "[e] a pin that demotes no SOUL code: refused"; c_has "$OUT" "this step demotes no SOUL code" "[e] …says so"
  variant 'def answer(q):
    if q["call"] == "owner" and q["effect"] == "pin" and q["phase"] != "ask":
        return {"data": {"demoted_from": q["args"]["tag"]}}'
  install "$VAR"
  owner_ok vouch S09 --text "x" --owner-quote q --where chat --soul-line "[S14] check the base before a rebase"
  c_rc 1 "[e] a pin that demotes another code: refused"
  owner_g vouch S14 --text "check the base, by hand" --owner-quote q --where chat --soul-line "[S14] check the base before a rebase"
  c_rc 0 "[e] a pin that demotes S14: written"
  c_has "$OUT" "the SOUL line [S14] removed from" "[e] …and the line removed"
  c_eq "$(cat "$P/SOUL.md")" "$(printf '# Shared rules\n- [S07] one review round')" "[e] …the file as before the archive"
}

case_bind() {
  local s
  np; owner_ok add --kind decision --text "x" --owner-quote q --where chat; printf 'other\n' > "$P/OTHER.md"; s=$(cat "$P/SOUL.md")
  gown promote D1 "CLAUDE.md [S14]" --soul-line "[S14] x"; c_eq "$(hfield permissionDecision)" ask "[b] instrument: the owner is asked (SOUL.md)"
  printf '{"soul_file": "OTHER.md"}\n' > "$P/.vibemaestro/brain.json"
  br owner promote D1 "CLAUDE.md [S14]" --soul-line "[S14] x"; c_rc 6 "[b] soul_file changed after the dialog: refused (6)"
  c_has "$OUT" "is not the one the dialog showed" "[b] …says so"
  c_eq "$(bpy 'print(s.load(s.state_dir())[1]["items"]["D1"]["status"])')|$(cat "$P/OTHER.md")|$(cat "$P/SOUL.md")" "live|other|$s" \
       "[b] nothing written: D1 live, both files unchanged"
  printf '{"soul_file": "SOUL.md"}\n' > "$P/.vibemaestro/brain.json"
  gown promote D1 "CLAUDE.md [S14]" --soul-line "[S14] x"
  if can_link; then
    mv "$P/SOUL.md" "$P/REAL.md"; ln -s OTHER.md "$P/SOUL.md"
    br owner promote D1 "CLAUDE.md [S14]" --soul-line "[S14] x"; c_rc 6 "[b] a link swapped in after the dialog: refused (6)"
    rm "$P/SOUL.md"; mv "$P/REAL.md" "$P/SOUL.md"
  else c_skip "[b] a link swapped in after the dialog" "ln -s copies here instead of linking"; fi
  owner_ok promote D1 "CLAUDE.md [S14]" --soul-line "[S14] x"; c_rc 6 "[b] a record that binds no line: refused (6)"
  c_eq "$(cat "$P/OTHER.md")|$(cat "$P/SOUL.md")" "other|$s" "[b] …no file written"
  if can_link; then
  mkdir -p "$P/a" "$P/b"; printf 'a\n' > "$P/a/S.md"; printf 'b\n' > "$P/b/S.md"; ln -s a "$P/cur"
  printf '{"soul_file": "cur/S.md"}\n' > "$P/.vibemaestro/brain.json"
  c_eq "$(bpy 'import os, brain
ns = brain.parser().parse_args(["owner", "promote", "D1", "CLAUDE.md [S14]", "--soul-line", "[S14] x"])
one = s.soul_line_for(ns)["file"]
os.replace("cur", "old"); os.symlink("b", "cur")
two = s.soul_line_for(ns)["file"]
print(os.path.basename(os.path.dirname(one)), os.path.basename(os.path.dirname(two)))')" "a a" "[b] one call resolves the file once: the link moved, the call still names a/S.md"
  else c_skip "[b] one call resolves the file once" "ln -s copies here instead of linking"; fi
  printf '{"soul_file": "SO\\u200bUL.md"}\n' > "$P/.vibemaestro/brain.json"
  owner_ok promote D1 "CLAUDE.md [S14]" --soul-line "[S14] x"; c_rc 1 "[b] a soul_file with an invisible character: refused"
  c_has "$OUT" "cannot show plainly" "[b] …says why"
}

echo "== cases =="
for c in case_promote case_refused case_ext case_bind; do run_case $c; done
cd "$TMP" || exit 1

summary
