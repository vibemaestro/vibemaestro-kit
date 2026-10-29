#!/bin/bash
# =============================================================================
# BatonRun: `sign --by owner` signs only after the owner's dialog (scripts/baton-guard.py, baton.py guard_owner / owner_proof)
# =============================================================================
# Run: bash tests/test-baton-owner-dialog.sh
#
# The plugin's PreToolUse Bash hook answers `ask` on a literal `sign --by owner` call and writes the record the sign needs; it
# denies where no owner answers the dialog. Each family runs on a copy of the real plugin (its baton isolated from the machine:
# baton_isolate), then again on copies with one planted break, and must go red on the intended check. The hook is run as
# Claude Code runs it (the payload on stdin); the session is CLAUDE_CODE_SESSION_ID. No network, nothing outside the scratch tree.
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
BT_OUT="$TMP/bt.out"; ST=""; BT_ENV=()

# bt <plugin> <dir> <session> <baton args...> — rc of baton from <dir> as <session> (plus BT_ENV); output in $BT_OUT. No guard.
bt() {
  local p=$1 d=$2 ses=$3; shift 3
  [ "${1:-}" = mode ] && [ $# -gt 1 ] && mode_asked "$p" "$d" "$ST" "$ses" "${@:2}" >/dev/null
  ( cd "$d" && cenv XDG_STATE_HOME="$ST" CLAUDE_CODE_SESSION_ID="$ses" ${BT_ENV[@]+"${BT_ENV[@]}"} python3 "$p/scripts/baton.py" "$@" ) \
    > "$BT_OUT" 2>&1; echo $?
}
# setup <plugin> — a fresh state and directory W holding act.sh (the template), its seal in SEAL, CMD the literal sign command
setup() {
  ST="$(fresh)/state"; W=$(fresh); BT_ENV=()
  cp "$SRC_ROOT/tests/fixtures/baton-positional.sh" "$W/act.sh"   # a positional baton (no Params): <file> <text>
  reseal "$1"
}
# reseal <plugin> — SEAL and CMD again under BT_ENV (a steering variable such as CLAUDE_CONFIG_DIR is part of the binding)
reseal() {
  SEAL=$( (cd "$W" && cenv XDG_STATE_HOME="$ST" ${BT_ENV[@]+"${BT_ENV[@]}"} python3 "$1/scripts/baton.py" rehearse act.sh "$W/out.txt" hello) 2>/dev/null \
          | sed -n 's/^seal \([^ ]*\) .*/\1/p')
  CMD="python3 $1/scripts/baton.py sign --by owner --seal $SEAL $W/act.sh $W/out.txt hello"
}
asked_n() { find "$ST/vibemaestro/baton/asked" -name '*.json' 2>/dev/null | grep -c .; }
sign() { bt "$1" "$W" "${2:-s-owner}" sign --by owner --seal "$SEAL" "$W/act.sh" "$W/out.txt" hello; }
signed_n() { find "$ST/vibemaestro/baton/signatures" -name '*.json' 2>/dev/null | grep -c .; }
# hook <plugin> <json fields> — the guard with a payload of the base fields (session s-owner, mode default, cwd W, CMD) updated by
# the given JSON object; prints the decision
hook() {
  local pl extra=${2:-'{}'}
  pl=$(python3 -c 'import json, sys
d = {"session_id": "s-owner", "permission_mode": "default", "cwd": sys.argv[1], "hook_event_name": "PreToolUse",
     "tool_name": "Bash", "tool_input": {"command": sys.argv[2]}}
d.update(json.loads(sys.argv[3]))
print(json.dumps(d))' "$W" "$CMD" "$extra")
  printf '%s' "$pl" | ( cd "$W" && cenv XDG_STATE_HOME="$ST" ${BT_ENV[@]+"${BT_ENV[@]}"} ${WRAP[@]+"${WRAP[@]}"} python3 "$1/scripts/baton-guard.py" ) \
    2>/dev/null | HOOK_FIELD="${HOOK_FIELD:-permissionDecision}" python3 -c 'import json, os, sys
t = sys.stdin.read().strip()
print(json.loads(t)["hookSpecificOutput"][os.environ["HOOK_FIELD"]] if t else "none")'
}
WRAP=()
# fake_claude <dir> — a program named claude that runs its arguments after its own options (not exec: it stays an ancestor)
fake_claude() {
  printf '#!/bin/bash\nwhile [ $# -gt 0 ]; do case $1 in -p|--print) shift;; --permission-prompt-tool) shift 2;; *) break;; esac; done\n"$@"\n' > "$1/claude"
  chmod +x "$1/claude"
}
# version_exe <dir> <version> — a program that prints the Claude Code version line, for CLAUDE_CODE_EXECPATH
version_exe() { printf '#!/bin/sh\necho "%s (Claude Code)"\n' "$2" > "$1/claude-v"; chmod +x "$1/claude-v"; printf '%s' "$1/claude-v"; }
PRH='{"hooks":{"PermissionRequest":[{"hooks":[{"type":"command","command":"true"}]}]}}'

fam_owner_record() {  # [A] the record: none, one, used once, voided by the next call, bound to session, argv, directory, time
  local P=$1 W2 rec
  setup "$P"
  eq "$(sign "$P")/$(signed_n)" "3/0" "[A] no record of the dialog: sign --by owner rc 3, nothing signed"
  has "$(cat "$BT_OUT")" "no fresh record of the owner's dialog" "[A] …the refusal names the missing dialog"
  eq "$(hook "$P")/$(asked_n)" "ask/1" "[A] the guard, mode default: ask, one record"
  eq "$(sign "$P")/$(signed_n)/$(asked_n)" "0/1/0" "[A] the owner clicked: sign rc 0, signed, the record used up"
  eq "$(sign "$P")" 3 "[A] the record serves once: the same sign again rc 3"
  hook "$P" >/dev/null
  eq "$(CMD="ls -la" hook "$P")/$(asked_n)" "none/0" "[A] the session's next Bash call voids an unused record (a rejected dialog)"
  eq "$(sign "$P")" 3 "[A] …and the sign after it: rc 3"
  hook "$P" '{"session_id": "s-other"}' >/dev/null
  eq "$(sign "$P")" 3 "[A] a record of another session: rc 3"
  hook "$P" >/dev/null
  eq "$(bt "$P" "$W" s-owner sign --by owner --seal "$SEAL" "$W/act.sh" "$W/out.txt" hello extra)" 3 "[A] a record for other arguments: rc 3"
  W2=$(fresh); hook "$P" "{\"cwd\": \"$W2\"}" >/dev/null
  eq "$(sign "$P")" 3 "[A] a record asked from another directory: rc 3"
  rm -f "$ST"/vibemaestro/baton/asked/*.json; hook "$P" >/dev/null; rec=$(find "$ST/vibemaestro/baton/asked" -name '*.json')
  python3 -c 'import json, sys; p = sys.argv[1]; r = json.load(open(p)); r["t"] -= 601; open(p, "w").write(json.dumps(r))' "$rec"
  eq "$(sign "$P")" 3 "[A] an expired record (601 s): rc 3"
  rm -f "$ST"/vibemaestro/baton/asked/*.json; hook "$P" >/dev/null; rec=$(find "$ST/vibemaestro/baton/asked" -name '*.json')
  python3 -c 'import json, sys; p = sys.argv[1]; r = json.load(open(p)); r["mode"] = "bypassPermissions"; open(p, "w").write(json.dumps(r))' "$rec"
  eq "$(sign "$P")" 3 "[A] a record whose mode shows no dialog: rc 3"
  hook "$P" >/dev/null
  eq "$(bt "$P" "$W" "" sign --by owner --seal "$SEAL" "$W/act.sh" "$W/out.txt" hello)" 3 "[A] no Claude Code session (no CLAUDE_CODE_SESSION_ID): rc 3"
  rm -f "$ST"/vibemaestro/baton/asked/*.json
  CMD="python3 $P/scripts/baton.py sign --by owner --seal $SEAL $W/nosuch.sh" hook "$P" >/dev/null
  eq "$(bt "$P" "$W" s-owner sign --by owner --seal "$SEAL" "$W/nosuch.sh")/$(asked_n)" "66/0" \
     "[A] a sign that fails before the script is read (rc 66) still used the record up"
  eq "$(CMD="python3 $P/scripts/baton.py sign --by owner --seal" hook "$P")/$(asked_n)/$(bt "$P" "$W" s-owner sign --by owner --seal)" "deny/0/64" \
     "[A] a malformed sign (no seal): the guard denies, sign rc 64"
}

fam_owner_modes() {  # [M] the modes: a dialog only in default, acceptEdits, and auto from 2.1.211
  local P=$1 m
  setup "$P"
  for m in plan dontAsk bypassPermissions unknown-mode; do
    eq "$(hook "$P" "{\"permission_mode\": \"$m\"}")/$(asked_n)" "deny/0" "[M] mode $m: the guard denies, no record"
    eq "$(sign "$P")" 3 "[M] mode $m: sign rc 3"
  done
  BT_ENV=(CLAUDE_CODE_EXECPATH="$(version_exe "$W" 2.1.210)")
  eq "$(hook "$P" '{"permission_mode": "auto"}')/$(asked_n)" "deny/0" "[M] mode auto below 2.1.211: the guard denies, no record"
  BT_ENV=(CLAUDE_CODE_EXECPATH="$(version_exe "$W" 2.1.211)")
  eq "$(hook "$P" '{"permission_mode": "auto"}')/$(asked_n)" "ask/1" "[M] mode auto at 2.1.211: ask"
  BT_ENV=()
  eq "$(sign "$P")" 0 "[M] …the owner clicked: sign rc 0"
  mkdir -p "$W/fakebin"; printf '#!/bin/sh\necho v22.11.0\n' > "$W/node"; chmod +x "$W/node"
  printf '#!/bin/sh\necho "2.1.100 (Claude Code)"\n' > "$W/fakebin/claude"; chmod +x "$W/fakebin/claude"
  BT_ENV=(CLAUDE_CODE_EXECPATH="$W/node" PATH="$W/fakebin:$PATH")
  eq "$(hook "$P" '{"permission_mode": "auto"}')/$(asked_n)" "deny/0" "[M] mode auto, EXECPATH is node (v22.11.0), claude 2.1.100: the guard denies"
  printf '#!/bin/sh\necho "2.1.211 (Claude Code)"\n' > "$W/fakebin/claude"
  eq "$(hook "$P" '{"permission_mode": "auto"}')" ask "[M] …node as EXECPATH, claude 2.1.211 on PATH: ask"
  BT_ENV=()
  eq "$(hook "$P" '{"permission_mode": "acceptEdits"}')" ask "[M] mode acceptEdits: ask"
  eq "$(sign "$P")" 0 "[M] …sign rc 0"
}

fam_owner_who() {  # [W] who answers: a sandbox, a subagent, a -p run, an answering hook or prompt tool
  local P=$1 iso
  setup "$P"; iso="$P.isolate"; fake_claude "$W"
  BT_ENV=(INTENT_SLUG=s SEAT=1)
  eq "$(hook "$P")/$(asked_n)" "deny/0" "[W] a sandbox session (INTENT_SLUG and SEAT): the guard denies, no record"
  BT_ENV=()
  hook "$P" >/dev/null
  eq "$(BT_ENV=(INTENT_SLUG=s SEAT=1); sign "$P")/$(asked_n)" "3/0" "[W] a sandbox session with a record: sign rc 3, the record used up"
  BT_ENV=(SEAT=1); hook "$P" >/dev/null
  eq "$(sign "$P")" 0 "[W] control: SEAT alone is no sandbox, sign rc 0"
  BT_ENV=()
  eq "$(hook "$P" '{"agent_id": "a1"}')/$(asked_n)" "deny/0" "[W] a subagent (agent_id): the guard denies, no record"
  WRAP=(bash "$W/claude" -p)
  eq "$(hook "$P")/$(asked_n)" "deny/0" "[W] a -p run: the guard denies, no record"
  WRAP=(); hook "$P" >/dev/null
  eq "$(cd "$W" && cenv XDG_STATE_HOME="$ST" CLAUDE_CODE_SESSION_ID=s-owner bash "$W/claude" -p $CMD >/dev/null 2>&1; echo $?)" 3 \
     "[W] a -p run with a record: sign rc 3"
  mkdir -p "$W/inst/claude/versions"; cp "$W/claude" "$W/inst/claude/versions/2.1.230"
  WRAP=(bash "$W/inst/claude/versions/2.1.230" -p)
  eq "$(hook "$P")/$(asked_n)" "deny/0" "[W] a -p run of a versioned Claude Code binary: the guard denies"
  WRAP=(bash "$W/claude" --permission-prompt-tool mcp__x__y)
  eq "$(hook "$P")/$(asked_n)" "deny/0" "[W] a --permission-prompt-tool ancestor: the guard denies"
  WRAP=()
  printf '%s' "$PRH" > "$iso/managed-settings.json"
  eq "$(hook "$P")/$(asked_n)" "deny/0" "[W] a PermissionRequest hook in the managed settings: the guard denies"
  rm -f "$iso/managed-settings.json"; hook "$P" >/dev/null; printf '%s' "$PRH" > "$iso/managed-settings.json"
  eq "$(sign "$P")" 3 "[W] …the same appearing after the ask: sign rc 3"
  rm -f "$iso/managed-settings.json"
  eq "$(sign "$P")" 3 "[W] …and the refused attempt used the record up: once the hook is gone, the same sign rc 3"
  mkdir -p "$W/cc"; printf '%s' "$PRH" > "$W/cc/settings.json"; BT_ENV=(CLAUDE_CONFIG_DIR="$W/cc")
  eq "$(hook "$P")/$(asked_n)" "deny/0" "[W] a PermissionRequest hook in the user settings: the guard denies"
  BT_ENV=()
}

fam_owner_spelling() {  # [S] the literal call only; other commands are not the guard's
  local P=$1 c
  setup "$P"
  for c in "cd $W && $CMD" "X=1 $CMD" "env $CMD" "$CMD; true" "$CMD | cat" "python3 $P/scripts/baton.py sign --by owner --seal \$(echo $SEAL) $W/act.sh $W/out.txt hello" \
           "$CMD > out.txt" "python3 $P/scripts/baton.py sign --by owner --seal $SEAL act*.sh $W/out.txt hello" \
           "$CMD;" "$CMD &" "$CMD &&" "( $CMD )"; do
    eq "$(CMD="$c" hook "$P")/$(asked_n)" "deny/0" "[S] not literal, denied: ${c:0:40}…${c: -24}"
  done
  eq "$(CMD="bash -c '$CMD'" hook "$P")/$(asked_n)" "none/0" "[S] a wrapper the guard does not read: no record"
  eq "$(CMD="$CMD"$'\n' hook "$P")/$(CMD=$'\n'"$CMD" hook "$P")" "ask/ask" "[S] a newline before or after the call is not an operator: ask"
  eq "$(CMD=$'\x1f\n'"$CMD" hook "$P")/$(CMD="$CMD"$'\n\x1f' hook "$P")/$(CMD="$CMD"$'\r' hook "$P")/$(asked_n)" "deny/deny/deny/0" \
     "[S] a control character and a newline around the call (a hidden command), or a trailing CR: denied"
  eq "$(CMD="python3 -Sc $P/scripts/baton.py sign --by owner --seal $SEAL $W/act.sh $W/out.txt hello" hook "$P")/$(asked_n)" "none/0" \
     "[S] python3 -Sc (inline code, not baton.py): no record"
  eq "$(sign "$P")" 3 "[S] …so the sign it runs: rc 3"
  for c in "grep -n 'sign --by owner' baton.py" "git commit -m 'baton sign --by owner'" "python3 $P/scripts/baton.py sign --by coordinator-auto --seal S act.sh $W/out.txt hello"; do
    eq "$(CMD="$c" hook "$P")" none "[S] not an owner sign, no opinion: ${c:0:50}"
  done
  local nb zw other; nb=$(printf '\302\240'); zw=$(printf '\342\200\213'); other="$(fresh)/baton.py"; cp "$P/scripts/baton.py" "$other"
  # each case by a fixed name: the command holds machine paths, the label must not
  denied() { eq "$(CMD="$2" hook "$P")/$(asked_n)" "deny/0" "[S] not the printed shape, denied: $1"; }
  denied "a ~/ program" "~/bin/baton sign --by owner --seal $SEAL $W/act.sh $W/out.txt hello"
  denied "a quoted program" "'$P/scripts/baton.py' sign --by owner --seal $SEAL $W/act.sh $W/out.txt hello"
  denied "NBSP before # (a hidden command)" "$CMD${nb}# ; touch $W/PWNED"
  denied "0x1f before # (a hidden command)" "$CMD"$'\x1f'"# ; touch $W/PWNED"
  denied "an invisible character before the program" "python3 ${zw}$P/scripts/baton.py sign --by owner --seal $SEAL $W/act.sh $W/out.txt hello"
  denied "a relative baton.py" "python3 scripts/baton.py sign --by owner --seal $SEAL $W/act.sh $W/out.txt hello"
  denied "a baton.py outside this plugin" "python3 $other sign --by owner --seal $SEAL $W/act.sh $W/out.txt hello"
  denied "--seal=" "python3 $P/scripts/baton.py sign --by owner --seal=$SEAL $W/act.sh $W/out.txt hello"
  denied "a relative script" "python3 $P/scripts/baton.py sign --by owner --seal $SEAL act.sh $W/out.txt hello"
  denied "-- before the script" "python3 $P/scripts/baton.py sign --by owner --seal $SEAL -- $W/act.sh $W/out.txt hello"
  denied "a malformed seal" "python3 $P/scripts/baton.py sign --by owner --seal x$SEAL $W/act.sh $W/out.txt hello"
  denied "a quoted argument" "$CMD 'two words'"
  denied "a tab" "$CMD"$'\t'"x"
  denied "a trailing NBSP" "$CMD${nb}"
  eq "$(CMD="python3 -I -B $P/scripts/baton.py sign --by owner --seal $SEAL $W/act.sh $W/out.txt hello" hook "$P")/$(asked_n)" "ask/1" \
     "[S] the printed shape with python3 -I -B: ask"
  eq "$(CMD="python3 $P/scripts/baton.py sign --by owner --seal $SEAL kit:coordinator-bootstrap" hook "$P")/$(asked_n)" "ask/1" \
     "[S] a kit by name (kit:<name>): ask"
  eq "$(hook "$P")/$(sign "$P")" "ask/0" "[S] the printed shape itself: ask, and its record signs the same argv: rc 0"
}

fam_owner_rules() {  # [R] the permission rules: none needed (the guard opens the dialog), an allow that matches refuses
  local P=$1 cc
  setup "$P"; cc="$W/cc"; mkdir -p "$cc"; BT_ENV=(CLAUDE_CONFIG_DIR="$cc"); reseal "$P"
  hook "$P" >/dev/null
  eq "$(sign "$P")" 0 "[R] no permission rules at all (a fresh machine): the guard's dialog suffices, rc 0"
  ( cd "$W" && cenv XDG_STATE_HOME="$ST" CLAUDE_CONFIG_DIR="$cc" python3 "$P/scripts/baton.py" permissions --print ) > "$cc/settings.json" 2>/dev/null
  hook "$P" >/dev/null
  eq "$(sign "$P")" 0 "[R] the printed rules installed, the owner clicked: rc 0"
  printf '{"permissions": {"allow": ["Bash(*)"]}}\n' > "$cc/settings.json"
  eq "$(hook "$P")/$(asked_n)" "deny/0" "[R] an allow rule that matches sign --by owner: the guard denies before any dialog"
  printf '{}\n' > "$cc/settings.json"; hook "$P" >/dev/null; printf '{"permissions": {"allow": ["Bash(*)"]}}\n' > "$cc/settings.json"
  eq "$(sign "$P")" 3 "[R] an allow rule that appears after the ask: sign rc 3"
  has "$(cat "$BT_OUT")" "Bash(*)" "[R] …the refusal names the rule"
  BT_ENV=()
}

fam_owner_auto() {  # [C] sign --by coordinator-auto is unchanged: no record, no guard
  local P=$1
  setup "$P"
  bt "$P" "$W" s-owner mode auto >/dev/null
  eq "$(bt "$P" "$W" s-x sign --by coordinator-auto --seal "$SEAL" "$W/act.sh" "$W/out.txt" hello)/$(asked_n)" "0/0" "[C] mode auto, Stops none: sign --by coordinator-auto rc 0 with no record"
  eq "$(BT_ENV=(INTENT_SLUG=s SEAT=1); bt "$P" "$W" "" sign --by coordinator-auto --seal "$SEAL" "$W/act.sh" "$W/out.txt" hello)" 0 "[C] …in a sandbox too"
}

# mset <plugin> <args after `mode`...> — the mode command itself, no guard on the way (as a call no dialog asked for); prints rc
mset() { local p=$1; shift; ( cd "$W" && cenv XDG_STATE_HOME="$ST" CLAUDE_CODE_SESSION_ID=s-owner ${BT_ENV[@]+"${BT_ENV[@]}"} python3 "$p/scripts/baton.py" mode "$@" ) > "$BT_OUT" 2>&1; echo $?; }
mode_now() { head -n 1 "$ST/vibemaestro/baton/mode" 2>/dev/null || echo unset; }
remotes_now() { grep -v '^dialog ' "$ST/vibemaestro/baton/remotes" 2>/dev/null | tr '\n' ' '; }
# shell_runs <command> — the command as Bash runs it for the session, from W; prints rc
shell_runs() { ( cd "$W" && cenv XDG_STATE_HOME="$ST" CLAUDE_CODE_SESSION_ID=s-owner bash -c "$1" ) > "$BT_OUT" 2>&1; echo $?; }

fam_owner_mode() {  # [D] a mode change takes the owner's dialog record, as sign --by owner does; a wrapped one fails closed
  local P=$1 M c py name
  setup "$P"; M="python3 $P/scripts/baton.py mode"
  eq "$(mset "$P" auto)/$(mode_now)" "3/unset" "[D] no record of the dialog: mode auto rc 3, the mode unchanged"
  has "$(cat "$BT_OUT")" "mode refused: no fresh record of the owner's dialog" "[D] …the refusal names the missing dialog"
  eq "$(CMD="$M auto" hook "$P")/$(asked_n)" "ask/1" "[D] the literal mode auto: the guard asks, one record"
  eq "$(mset "$P" auto)/$(mode_now)/$(asked_n)" "0/auto/0" "[D] the owner clicked: mode auto rc 0, the mode set, the record used up"
  eq "$(mset "$P" auto)" 3 "[D] the record serves once: the same mode auto again rc 3"
  eq "$(mset "$P" manual)/$(mode_now)" "3/auto" "[D] no record for mode manual: rc 3, the mode unchanged"
  CMD="$M manual" hook "$P" >/dev/null
  eq "$(mset "$P" auto)/$(mode_now)" "3/auto" "[D] a record for mode manual does not serve mode auto: rc 3"
  CMD="$M manual" hook "$P" >/dev/null
  eq "$(mset "$P" manual)/$(mode_now)" "0/manual" "[D] …its own call: rc 0, the mode set"
  eq "$(mset "$P")/$(cat "$BT_OUT")" "0/manual" "[D] reading the mode needs no record: rc 0"
  eq "$(mset "$P" remotes)" 0 "[D] reading the remote list needs no record: rc 0"
  eq "$(mset "$P" trust github.com/acme/app)/$(remotes_now)" "3/" "[D] no record: mode trust rc 3, the remote list unchanged"
  CMD="$M trust github.com/acme/app" hook "$P" >/dev/null
  eq "$(mset "$P" trust github.com/acme/app)/$(remotes_now)" "0/github.com/acme/app " "[D] the owner clicked: mode trust rc 0, the remote listed"
  eq "$(mset "$P" untrust github.com/acme/app)/$(remotes_now)" "3/github.com/acme/app " "[D] no record: mode untrust rc 3, the list unchanged"
  eq "$(mset "$P" sideways)/$(asked_n)" "64/0" "[D] a mode that is not one: usage rc 64 before any record"
  # every wrapped form: the guard writes no record (no opinion, or a deny), and the call it would run is refused, mode unchanged
  py=$(command -v python3); printf '%s auto\n' "$M" > "$W/m.sh"
  for name in "env" "VAR=" "bash -c" "sh -c" "eval" "an interpreter path" "a heredoc into bash" "a script file" "cd &&" "a pipe" "nohup"; do
    case $name in
      env) c="env $M auto";; VAR=) c="X=1 $M auto";; "bash -c") c="bash -c '$M auto'";; "sh -c") c="sh -c '$M auto'";;
      eval) c="eval '$M auto'";; "an interpreter path") c="$py $P/scripts/baton.py mode auto";;
      "a heredoc into bash") c=$'bash <<\'EOF\'\n'"$M auto"$'\nEOF';; "a script file") c="bash $W/m.sh";;
      "cd &&") c="cd $W && $M auto";; "a pipe") c="true | $M auto";; nohup) c="nohup $M auto";;
    esac
    eq "$(CMD="$c" hook "$P" | sed 's/^deny$/none/')/$(asked_n)" "none/0" "[D] wrapped ($name): the guard asks nothing, no record"
    eq "$(shell_runs "$c")/$(mode_now)" "3/manual" "[D] wrapped ($name): refused rc 3, the mode unchanged"
  done
  CMD="$M auto" hook "$P" >/dev/null
  eq "$(CMD="env $M auto" hook "$P")/$(asked_n)/$(shell_runs "env $M auto")/$(mode_now)" "deny/0/3/manual" \
     "[D] a record from the literal ask does not serve a wrapped call: the hook voids it on that call and denies, refused"
  denied_m() { eq "$(CMD="$2" hook "$P")/$(asked_n)" "deny/0" "[D] not the printed shape, denied: $1"; }
  denied_m "a quoted program" "'$P/scripts/baton.py' mode auto"
  denied_m "an extra word" "$M auto now"
  denied_m "trust without a remote" "$M trust"
  denied_m "a relative baton.py" "python3 scripts/baton.py mode auto"
  denied_m "a remote with userinfo" "$M trust https://github.com@evil.example/acme/app"
  # a wrapped call the hook sees outside a heredoc's body is denied: an ask rule could still show a dialog no click makes work
  for name in "env" "VAR=" "cd &&" "a pipe" "nohup" "a variable in the path"; do
    case $name in
      env) c="env $M auto";; VAR=) c="X=1 $M auto";; "cd &&") c="cd $W && $M auto";; "a pipe") c="true | $M auto";;
      nohup) c="nohup $M auto";; "a variable in the path") c="python3 \$PLUGIN/scripts/baton.py mode auto";;
    esac
    eq "$(CMD="$c" hook "$P")/$(asked_n)" "deny/0" "[D] wrapped ($name), outside a heredoc: denied, no record"
  done
  eq "$(CMD=$'cat > note.md <<\'EOF\'\n'"$M auto"$'\nEOF' hook "$P")/$(asked_n)" "none/0" \
     "[D] a mode call as a heredoc's body line: no opinion (it would refuse itself), no record"
  eq "$(CMD=$'git commit -m "fix: the \\"ask\\" rule\n'"$M auto"$'\nend"' hook "$P")/$(asked_n)" "none/0" \
     "[D] a commit message with an escaped quote and a line that quotes the mode call: no opinion, no record"
  eq "$(CMD=$'git commit -m "fix: the \\"ask\\" rule\n'"python3 $P/scripts/baton.py sign --by owner --seal $SEAL kit:x"$'\nend"' hook "$P")/$(asked_n)" \
     "none/0" "[D] …one that quotes the owner's sign call: no opinion, no record"
  eq "$(CMD="$M \"auto\"" hook "$P")/$(asked_n)" "deny/0" "[D] a quoted mode word: the hook still reads the call, denied"
  eq "$(CMD="$M \\auto" hook "$P")/$(asked_n)" "deny/0" "[D] an escaped mode word: denied"
  eq "$(mset "$P" trust https://github.com@evil.example/acme/app)/$(remotes_now)" "64/github.com/acme/app " \
     "[D] a remote with userinfo: the call refuses it (rc 64), the list unchanged"
  has "$(CMD="$M trust https://GitHub.com/acme/other.git" HOOK_FIELD=permissionDecisionReason hook "$P")" \
      "trusts the remote github.com/acme/other for" "[D] the trust dialog names the remote as it will be written (canonical)"
  CMD="ls" hook "$P" >/dev/null
  BT_ENV=(INTENT_SLUG=s SEAT=1)
  eq "$(CMD="$M auto" hook "$P")/$(asked_n)" "deny/0" "[D] a sandbox session: the guard denies the mode change, no record"
  BT_ENV=(); CMD="$M auto" hook "$P" >/dev/null
  eq "$(BT_ENV=(INTENT_SLUG=s SEAT=1); mset "$P" auto)/$(mode_now)" "3/manual" "[D] a sandbox session with a record: rc 3, mode unchanged"
  eq "$(CMD="$M auto" hook "$P" '{"agent_id": "a1"}')/$(asked_n)" "deny/0" "[D] a subagent: the guard denies, no record"
  eq "$(CMD="$M auto" hook "$P" '{"permission_mode": "bypassPermissions"}')/$(asked_n)" "deny/0" "[D] a mode with no dialog: denied, no record"
}

# old_copy <plugin> <dir> — a copy of the plugin as a version from before the record left it: its mode and trust write the value
# with no owner's dialog line and check no record (the writers of every sdlc before the record), placed as a cache version dir
old_copy() {
  cp -R "$1" "$2"
  mutate "$2/scripts/baton.py" '    rid = owner_sets_mode(["mode"] + rest)              # the owner' '    rid = None              # the owner' &&
  mutate "$2/scripts/baton.py" 'write_private(os.path.join(d, "mode"), "%s\ndialog %s\n" % (rest[0], rid))' \
                               'write_private(os.path.join(d, "mode"), rest[0] + "\n")' &&
  mutate "$2/scripts/baton.py" $'    rid = owner_sets_mode(["mode"] + rest)\n    have = read_remotes()' $'    rid = None\n    have = read_remotes()' &&
  mutate "$2/scripts/baton.py" ' + "dialog %s\n" % rid)' ')'
}

fam_owner_oldcopy() {  # [O] a mode or trust written by an older baton.py (no dialog line) counts for nothing, through any wrapper
  local P=$1 OC c name
  setup "$P"; OC="$(fresh)/home/.claude/plugins/cache/vibemaestro/vibemaestro-sdlc/0.0.1"; mkdir -p "$(dirname "$OC")"
  old_copy "$P" "$OC" || return
  baton_set_mode "$ST" manual
  for name in "env" "bash -c" "python3 -I -B"; do
    case $name in
      env) c="env python3 $OC/scripts/baton.py mode";; "bash -c") c="bash -c 'python3 $OC/scripts/baton.py mode \"\$0\" \$1'";;
      "python3 -I -B") c="python3 -I -B $OC/scripts/baton.py mode";;
    esac
    eq "$(shell_runs "$c auto")/$(mode_now)" "0/auto" "[O] instrument: the old copy, $name: mode auto rc 0, its file says auto"
    eq "$(mset "$P")/$(cat "$BT_OUT")" "0/manual" "[O] $name: this baton reads the mode as manual (no owner's dialog line)"
    eq "$(shell_runs "$c trust github.com/acme/app")/$(remotes_now)" "0/github.com/acme/app " "[O] instrument: the old copy, $name: trust rc 0, its file lists the remote"
    mset "$P" remotes >/dev/null
    has "$(cat "$BT_OUT")" "(none)" "[O] $name: this baton reads the remote list as empty"
    rm -f "$ST/vibemaestro/baton/remotes"; baton_set_mode "$ST" manual
  done
  CMD="python3 $P/scripts/baton.py mode auto" hook "$P" >/dev/null
  eq "$(mset "$P" auto)/$(mset "$P")/$(cat "$BT_OUT")" "0/0/auto" "[O] control: this baton with the owner's dialog: mode auto, read back as auto"
}

fam_owner_version() {  # [V] run takes an owner signature only with the dialog it names (record version 2)
  local P=$1 sig
  setup "$P"; hook "$P" >/dev/null; sign "$P" >/dev/null
  sig=$(find "$ST/vibemaestro/baton/signatures" -name '*.json' | head -1)
  python3 -c 'import json, sys; p = sys.argv[1]; r = json.load(open(p)); r["v"] = 1; r.pop("dialog", None); open(p, "w").write(json.dumps(r))' "$sig"
  eq "$(bt "$P" "$W" s-owner run act.sh "$W/out.txt" hello)" 3 "[V] an owner signature with no dialog id (an older baton wrote it): run rc 3"
  setup "$P"; hook "$P" >/dev/null; sign "$P" >/dev/null
  eq "$(bt "$P" "$W" s-owner run act.sh "$W/out.txt" hello)" 0 "[V] control: the signature with its dialog runs, rc 0"
}

# fam_owner_lineage runs the guard and the sign under a stand-in for the Claude Code process: a script whose own pid is the
# CLAUDE_PID the guard reads, as Claude Code's is, and whose children are the Bash calls.
LINEAGE_SH='ask() { printf "%s" "$PAYLOAD" | CLAUDE_PID=$$ python3 "$GUARD" >/dev/null 2>&1; }
call() { ( cd "$W" && CLAUDE_CODE_SESSION_ID=s-owner $CMD >/dev/null 2>&1; echo $? ); }
case $1 in
  normal) ask; call;;
  sbpoller) ( until [ -e "$W/go" ]; do sleep 0.05; done; ( cd "$W" && INTENT_SLUG=x SEAT=y CLAUDE_CODE_SESSION_ID=s-owner $CMD >/dev/null 2>&1; echo $? ) > "$W/poll.rc" ) &
          sleep 0.3; ask; : > "$W/go"; wait; echo "$(cat "$W/poll.rc")/$(call)"; rm -f "$W/go";;
  poller) ( until [ -e "$W/go" ]; do sleep 0.05; done; call > "$W/poll.rc" ) &
          sleep 0.3; ask; : > "$W/go"; wait; echo "$(cat "$W/poll.rc")/$(call)"; rm -f "$W/go";;
  ask) ask;;
esac'
fam_owner_lineage() {  # [L] only a process the asking Claude Code process started after the ask uses the record
  local P=$1 L pl
  L="$P.lineage"; rm -rf "$L"; cp -r "$P" "$L"; mutate "$L/scripts/baton.py" 'LINEAGE = False ' 'LINEAGE = True ' || return
  setup "$L"; printf '%s\n' "$LINEAGE_SH" > "$W/claude-standin.sh"
  pl=$(python3 -c 'import json, sys
print(json.dumps({"session_id": "s-owner", "permission_mode": "default", "cwd": sys.argv[1], "tool_name": "Bash",
                  "tool_input": {"command": sys.argv[2]}}))' "$W" "$CMD")
  standin() { (cd "$W" && cenv XDG_STATE_HOME="$ST" W="$W" CMD="$CMD" PAYLOAD="$pl" GUARD="$L/scripts/baton-guard.py" bash "$W/claude-standin.sh" "$1"); }
  eq "$(standin normal)/$(signed_n)" "0/1" "[L] the command the asking Claude Code process starts after the ask: sign rc 0"
  eq "$(standin poller)" "3/0" "[L] a poller started before the ask, under the same Claude Code process: sign rc 3; the dialog's own call after it: rc 0"
  eq "$(standin sbpoller)" "3/0" "[L] the same poller claiming a sandbox: sign rc 3, and the record stays for the dialog's call: rc 0"
  standin ask
  eq "$(asked_n)/$(sign "$L")" "1/3" "[L] a process outside the Claude Code process that asked (another session): sign rc 3"
  CMD="python3 $L/scripts/baton.py mode auto"
  pl=$(python3 -c 'import json, sys
print(json.dumps({"session_id": "s-owner", "permission_mode": "default", "cwd": sys.argv[1], "tool_name": "Bash",
                  "tool_input": {"command": sys.argv[2]}}))' "$W" "$CMD")
  eq "$(standin poller)/$(head -n 1 "$ST/vibemaestro/baton/mode")" "3/0/auto" \
     "[L] a mode change: a poller started before the ask rc 3, the dialog's own call rc 0, the mode set"
}

fam_owner_wiring() {  # [H] hooks.json runs the guard on every Bash call, as its own entry
  local P=$1
  has "$(hook_cmds "$P/hooks/hooks.json" PreToolUse Bash)" 'scripts/baton-guard.py' "[H] hooks.json: a PreToolUse Bash command runs baton-guard.py"
  setup "$P"
  eq "$(printf '{"session_id":"s-owner","permission_mode":"default","cwd":"%s","tool_name":"Bash","tool_input":{"command":"%s"}}' "$W" "$CMD" \
        | (cd "$W" && cenv XDG_STATE_HOME="$ST" CLAUDE_PLUGIN_ROOT="$P" bash -c "$(hook_cmds "$P/hooks/hooks.json" PreToolUse Bash | grep baton-guard)") \
        | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["hookSpecificOutput"]["permissionDecision"])')/$(asked_n)" "ask/1" \
     "[H] the hooks.json command, as Claude Code runs it: ask and a record"
}

FAMILIES="fam_owner_record fam_owner_modes fam_owner_who fam_owner_spelling fam_owner_rules fam_owner_auto fam_owner_mode fam_owner_oldcopy
fam_owner_version fam_owner_lineage fam_owner_wiring"
echo "== the real plugin =="
REAL="$TMP/real"; mk_plugin_copy "$REAL"
for f in $FAMILIES; do echo "-- $f"; "$f" "$REAL"; done

echo "== planted breaks: each family must go red on a plugin copy with one break in baton.py =="
# BRK <label> <family> <needle> <old> <new> [<old> <new>]... — a plugin copy with the replacements in baton.py, then expect_red
BRK() {
  local label=$1 fam=$2 needle=$3 d; shift 3; d="$TMP/break-$label"; mk_plugin_copy "$d"
  while [ $# -ge 2 ]; do mutate "$d/scripts/baton.py" "$1" "$2" || return; shift 2; done
  expect_red "$label" "$fam" "$d" "$needle"
}
BRK no-proof fam_owner_record '[A] no record of the dialog' '    dialog = owner_signs(asked) if by == "owner" else None' '    dialog = "planted" if by == "owner" else None'
BRK record-reused fam_owner_record '[A] the record serves once' '            os.unlink(path)                             # one dialog, one sign' '            pass                             # one dialog, one sign'
BRK late-use fam_owner_record '[A] a sign that fails before the script is read' \
    '    dialog = owner_signs(asked) if by == "owner" else None' \
    '    dialog = owner_signs(asked) if by == "owner" and os.path.exists(asked[4]) else None'
BRK no-void fam_owner_record "[A] the session's next Bash call voids" '    void_asked(sid)                                     # every Bash' '    pass                                     # every Bash'
BRK session-unbound fam_owner_record '[A] a record of another session' '        if (session and r.get("session") == session and' '        if (session and'
BRK argv-unbound fam_owner_record '[A] a record for other arguments' ' and r.get("argv") == list(argv) and' ' and'
BRK cwd-unbound fam_owner_record '[A] a record asked from another directory' ' and r.get("cwd") == cwd' ''
BRK age-unchecked fam_owner_record '[A] an expired record' 'and 0 <= age <= ASKED_MAX_AGE and' 'and'
BRK record-mode-unchecked fam_owner_record '[A] a record whose mode' '                and r.get("mode") in DIALOG_MODES and' '                and'
BRK mode-unchecked fam_owner_modes '[M] mode plan: the guard denies' '    if not (mode in ("default", "acceptEdits") or (mode == "auto" and version_ok())):' '    if False:'
BRK floor-unchecked fam_owner_modes '[M] mode auto below 2.1.211' '            return tuple(int(x) for x in m.groups()) >= VERSION_FLOOR' '            return True'
BRK version-of-node fam_owner_modes '[M] mode auto, EXECPATH is node' '[^\n]*Claude Code", out' '", out'
BRK sandbox-ignored fam_owner_who '[W] a sandbox session' '    return all(os.environ.get(v, "").strip() for v in SANDBOX_ENV)' '    return False'
BRK subagent-ignored fam_owner_who '[W] a subagent' '    if inp.get("agent_id"):' '    if False:'
BRK print-ignored fam_owner_who '[W] a -p run' '    for argv, _c, _g, _h in anc:' '    for argv, _c, _g, _h in []:'
BRK answerers-ignored fam_owner_who '[W] a PermissionRequest hook in the managed settings' '    found = []
    cfgs = [' '    return []
    cfgs = ['
BRK refused-record-kept fam_owner_who '[W] …and the refused attempt used the record up' \
    '        return "something can answer the dialog in place of a human: " + "; ".join(ans), path' \
    '        return "something can answer the dialog in place of a human: " + "; ".join(ans), None'
# the literal check (LITERAL) is a first, more specific message; owner_shape is the gate: breaking only the first one
# changes no outcome, so its breaks are shape-unchecked and program-unresolved
BRK unsafe-guard-ignored fam_owner_rules '[R] an allow rule that matches sign --by owner: the guard denies' \
    $'    if bad:\n        return deny(' $'    if False:\n        return deny('
BRK unsafe-cli-ignored fam_owner_rules '[R] an allow rule that appears after the ask' \
    $'    if bad:\n        return "; ".join(bad)' $'    if False:\n        return "; ".join(bad)'
BRK auto-needs-record fam_owner_auto '[C] mode auto, Stops none' '    dialog = owner_signs(asked) if by == "owner" else None' '    dialog = owner_signs(asked)'
# the sign side's own checks, each with the guard's left as it is
BRK sandbox-cli-ignored fam_owner_who '[W] a sandbox session with a record' \
    $'    if in_sandbox():\n        return ("a sandbox session: whoever answers its dialog is not the owner, so' \
    $'    if False:\n        return ("a sandbox session: whoever answers its dialog is not the owner, so'
BRK print-cli-ignored fam_owner_who '[W] a -p run with a record' \
    $'    if print_run(anc):\n        return "a -p run: no one answers its dialog", path' $'    if False:\n        return "a -p run: no one answers its dialog", path'
BRK answerers-cli-ignored fam_owner_who '[W] …the same appearing after the ask' \
    $'    if ans:\n        return "something can answer the dialog in place of a human: " + "; ".join(ans), path' \
    $'    if False:\n        return "something can answer the dialog in place of a human: " + "; ".join(ans), path'
BRK versioned-path-missed fam_owner_who '[W] a -p run of a versioned' ' or "/claude/versions/" in a for a' ' for a'
BRK newline-is-operator fam_owner_spelling '[S] a newline before or after the call' '.get("command")) or "").strip(" \t\n")   # bash' '.get("command")) or "")   # bash'
BRK trim-too-wide fam_owner_spelling '[S] a control character and a newline around the call' '.strip(" \t\n")' '.strip()'
BRK shape-unchecked fam_owner_spelling '[S] not the printed shape, denied' \
    '    shaped = mode_shape(cmd) if is_mode else owner_shape(cmd)' '    shaped = mode_shape(cmd) if is_mode else found[0][1]'
BRK program-unresolved fam_owner_spelling '[S] not the printed shape, denied: a baton.py outside this plugin' \
    '        if not (i < len(ws) and os.path.isabs(ws[i]) and os.path.realpath(ws[i]) == os.path.realpath(os.path.abspath(__file__))):' \
    '        if not (i < len(ws) and os.path.basename(ws[i]) == "baton.py"):'
BRK python-options-open fam_owner_spelling '[S] python3 -Sc' '        while j < len(ws) and ws[j] in PY_FLAGS:' '        while j < len(ws) and ws[j].startswith("-"):'
BRK run-takes-v1 fam_owner_version '[V] an owner signature with no dialog id' \
    '    if why is None and signer == "owner" and (rec.get("v") != 2 or not rec.get("dialog")):' '    if False:'
BRK lineage-refusal-uses-record fam_owner_lineage "[L] a poller started before the ask" \
    $'"owner\'s dialog runs may use the record"), None, rec' $'"owner\'s dialog runs may use the record"), path, rec'
BRK lineage-unchecked fam_owner_lineage '[L] a poller started before the ask' \
    '        if child is None or rec.get("after") is None or child < rec["after"]:' '        if False:'
# a mode change: the record is the guard (cmd_mode, cmd_remotes, owner_sets_mode), the hook only asks for the literal shape
BRK mode-no-proof fam_owner_mode '[D] wrapped (env): refused rc 3' \
    '    rid = owner_sets_mode(["mode"] + rest)              # the owner' '    rid = "0" * 32              # the owner'
BRK trust-no-proof fam_owner_mode '[D] no record: mode trust rc 3' \
    $'    rid = owner_sets_mode(["mode"] + rest)\n    have = read_remotes()' $'    rid = "0" * 32\n    have = read_remotes()'
BRK mode-record-reused fam_owner_mode '[D] the record serves once' \
    '            os.unlink(path)                             # one dialog, one attempt' '            pass                             # one dialog, one attempt'
BRK mode-shape-unchecked fam_owner_mode '[D] not the printed shape, denied: a quoted program' \
    '    shaped = mode_shape(cmd) if is_mode else owner_shape(cmd)' '    shaped = found[0][1] if is_mode else owner_shape(cmd)'
BRK mode-sandbox-ignored fam_owner_mode '[D] a sandbox session with a record' \
    $'    if in_sandbox():\n        return ("a sandbox session: whoever answers its dialog is not the owner, so the owner %s' \
    $'    if False:\n        return ("a sandbox session: whoever answers its dialog is not the owner, so the owner %s'
BRK mode-proof-ignored fam_owner_oldcopy '[O] env: this baton reads the mode as manual' \
    '    if not proven(lines[1:]):' '    if False:'
BRK remotes-proof-ignored fam_owner_oldcopy '[O] env: this baton reads the remote list as empty' \
    $'    if not proven(lines):\n        return []' $'    if False:\n        return []'
BRK userinfo-shown fam_owner_mode '[D] not the printed shape, denied: a remote with userinfo' \
    '    return rest if len(rest) == 3 and plain_remote(rest[2]) else None' '    return rest if len(rest) == 3 else None'
BRK wrapped-mode-unopposed fam_owner_mode '[D] wrapped (env), outside a heredoc: denied' \
    '        if any("<<" in t for t, _f in segs[:at]):' '        if True:'
BRK escaped-quote-splits fam_owner_mode '[D] a commit message with an escaped quote' \
    $' as bash reads it: no split there\n                flags.add("escape")\n                cur.append(cmd[i:i + 2])\n                i += 2\n                continue' \
    $' as bash reads it: no split there\n                flags.add("escape")'
BRK heredoc-body-denied fam_owner_mode "[D] a mode call as a heredoc's body line" \
    '        if any("<<" in t for t, _f in segs[:at]):' '        if False:'
d="$TMP/break-mode-hook-blind"; mk_plugin_copy "$d"
mutate "$d/scripts/baton-guard.py" ' or MODE_WORDS.search(cmd))' ')' && expect_red mode-hook-blind fam_owner_mode "$d" '[D] the literal mode auto: the guard asks'
d="$TMP/break-mode-words-plain"; mk_plugin_copy "$d"
mutate "$d/scripts/baton-guard.py" 'MODE_WORDS = re.compile(' \
    'MODE_WORDS = re.compile(r"\bmode\s+(?:manual|auto|trust|untrust)\b") or re.compile(' &&
  expect_red mode-words-plain fam_owner_mode "$d" '[D] a quoted mode word: the hook still reads the call, denied'

echo "== nothing written outside the scratch tree =="
eq "$(tree_hash "$SRC_ROOT")" "$H0" "the repository tree is unchanged by the suite"
echo; summary

