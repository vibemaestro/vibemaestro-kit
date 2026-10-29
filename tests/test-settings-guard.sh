#!/bin/bash
# =============================================================================
# The settings guard: a plain-tool write that widens a Claude Code settings file's boundary is denied (scripts/settings-guard.py)
# =============================================================================
# Run: bash tests/test-settings-guard.sh
#
# The plugin's PreToolUse hook on Edit, Write, MultiEdit, NotebookEdit and Bash denies a change to a `.claude/settings*.json`
# (or `$CLAUDE_CONFIG_DIR/settings*.json`) that widens what a session may do, and names `kind:settings-merge`. Edit, Write and
# MultiEdit are judged on the exact after-state (narrowing inside `permissions` passes, a top-level key off the harmless list
# stops); Bash is judged on its text and only finds, so the known limits are asserted to pass, keeping the docs true. Each
# family runs on a copy of the real plugin, then again on copies with one planted break, and must go red on the intended check.
# The deny names the exact next step: the rules file's content, the launcher as the permission rules allow it, the settings path.
# The hook is run as Claude Code runs it: the hooks.json command, the payload on stdin. No network, nothing outside the scratch tree.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
# shellcheck source=fixtures/ports.sh
. "$HERE/fixtures/ports.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
# a short directory for unix sockets (a socket path is capped near 104 bytes; $TMP can be longer on a CI runner), one per suite run
SOCKD=$(mktemp -d /tmp/sg-sock.XXXXXX)
trap 'rm -rf "$TMP" "$SOCKD"' EXIT
clean_env "$TMP"
export PYTHONDONTWRITEBYTECODE=1
H0=$(tree_hash "$SRC_ROOT")

# the settings every case starts from: one rule of each list, a directory, a mode, a secret in env
BASE='{
  "permissions": {
    "allow": ["Bash(ls:*)"],
    "ask": ["Bash(rm:*)"],
    "deny": ["Read(./.env)"],
    "additionalDirectories": ["/srv/a"],
    "defaultMode": "default"
  },
  "hooks": {},
  "env": {"TOKEN": "sekret-123"},
  "model": "opus"
}'
GENV=()   # extra environment for the guard (CLAUDE_CONFIG_DIR)
GUARD_CAP=()   # a command prefix for the guard: fam_bounded sets GCAP, so a read that grows or blocks fails its check, not the machine
GCAP=()
if command -v prlimit >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1; then GCAP=(prlimit --as=2147483648 -- timeout 20); fi

# project — a fresh project W with .claude/settings.json holding BASE (printed)
project() {
  local w; w=$(fresh); mkdir -p "$w/.claude" "$w/.vscode" "$w/app"
  printf '%s\n' "$BASE" > "$w/.claude/settings.json"
  printf '%s\n' "$BASE" > "$w/.vscode/settings.json"; printf '%s\n' "$BASE" > "$w/app/settings.json"
  printf '%s' "$w"
}
# guard <plugin> <cwd> <tool> <tool_input JSON> — the decision of the hooks.json command that runs settings-guard.py for <tool>
# (`none` when it prints nothing); `gw` prints its reason
guard() {
  local P=$1 cwd=$2 tool=$3 ti=$4 c pl out
  c=$(hook_cmds "$P/hooks/hooks.json" PreToolUse "$tool" | grep -F settings-guard)
  pl=$(printf '%s' "$ti" | python3 -c 'import json, sys
print(json.dumps({"session_id": "s-guard", "permission_mode": "auto", "cwd": sys.argv[1], "hook_event_name": "PreToolUse",
                  "tool_name": sys.argv[2], "tool_input": json.loads(sys.stdin.read())}))' "$cwd" "$tool")
  out=""
  [ -n "$c" ] && out=$(printf '%s' "$pl" | (cd "$cwd" && cenv CLAUDE_PLUGIN_ROOT="$P" ${GENV[@]+"${GENV[@]}"} ${GUARD_CAP[@]+"${GUARD_CAP[@]}"} bash -c "$c") 2>/dev/null)
  why "$out" > "$TMP/gw"
  local d; d=$(dec "$out"); printf '%s' "${d:-none}"
}
# the tool_input of each tool
gw() { cat "$TMP/gw"; }
ti_edit()  { python3 -c 'import json, sys; print(json.dumps({"file_path": sys.argv[1], "old_string": sys.argv[2], "new_string": sys.argv[3]}))' "$@"; }
ti_write() { python3 -c 'import json, sys; print(json.dumps({"file_path": sys.argv[1], "content": sys.argv[2]}))' "$@"; }
ti_multi() { python3 -c 'import json, sys
a = sys.argv[2:]
print(json.dumps({"file_path": sys.argv[1], "edits": [{"old_string": a[i], "new_string": a[i + 1]} for i in range(0, len(a), 2)]}))' "$@"; }
ti_bash()  { printf '%s' "$1" | python3 -c 'import json, sys; print(json.dumps({"command": sys.stdin.read()}))'; }   # stdin: a long text passes no argv cap
# with <json edit in python> — BASE changed by a python statement on `d`, as JSON text
with() { python3 -c 'import json, sys
d = json.loads(sys.argv[1]); exec(sys.argv[2]); print(json.dumps(d, indent=2))' "$BASE" "$1"; }
# shorthands on project W: e <old> <new> | w <content> | b <command> → the decision
e() { guard "$P" "$W" Edit "$(ti_edit "$W/.claude/settings.json" "$1" "$2")"; }
w() { guard "$P" "$W" Write "$(ti_write "$W/.claude/settings.json" "$1")"; }
b() { guard "$P" "$W" Bash "$(ti_bash "$1")"; }

ADD_ALLOW_OLD='"Bash(ls:*)"'
ADD_ALLOW_NEW='"Bash(ls:*)", "Bash(curl:*)"'

fam_edit() {  # [E] Edit, Write, MultiEdit, NotebookEdit: a widening change is denied, named, and points to the kind
  P=$1; W=$(project)
  eq "$(e "$ADD_ALLOW_OLD" "$ADD_ALLOW_NEW")" deny "[E] Edit adds an allow rule: deny"
  has "$(gw)" "Bash(curl:*)" "[E] …the reason names the added rule"
  has "$(gw)" "kind:settings-merge" "[E] …and the one way, kind:settings-merge"
  has "$(gw)" "owner" "[E] …and that the owner signs it"
  eq "$(w "$(with 'd["permissions"]["allow"].append("Bash(curl:*)")')")" deny "[E] Write adds an allow rule: deny"
  eq "$(guard "$P" "$W" MultiEdit "$(ti_multi "$W/.claude/settings.json" '"opus"' '"sonnet"' "$ADD_ALLOW_OLD" "$ADD_ALLOW_NEW")")" deny \
     "[E] MultiEdit changes model and adds an allow rule: deny"
  eq "$(e '"ask": ["Bash(rm:*)"]' '"ask": []')" deny "[E] Edit removes an ask rule: deny"
  eq "$(w "$(with 'd["permissions"]["ask"] = []')")" deny "[E] Write removes an ask rule: deny"
  eq "$(guard "$P" "$W" MultiEdit "$(ti_multi "$W/.claude/settings.json" '"ask": ["Bash(rm:*)"]' '"ask": []')")" deny "[E] MultiEdit removes an ask rule: deny"
  eq "$(e '"deny": ["Read(./.env)"]' '"deny": []')" deny "[E] Edit removes a deny rule: deny"
  eq "$(w "$(with 'del d["permissions"]["deny"]')")" deny "[E] Write drops the deny list: deny"
  eq "$(guard "$P" "$W" MultiEdit "$(ti_multi "$W/.claude/settings.json" '"deny": ["Read(./.env)"]' '"deny": ["Read(./x)"]')")" deny \
     "[E] MultiEdit rewrites a deny rule: deny"
  eq "$(e '"Bash(ls:*)"' '"Bash(ls -la:*)"')" deny "[E] Edit rewrites an allow rule (one removed, one added): deny"
  local m
  for m in acceptEdits auto bypassPermissions; do
    eq "$(e '"defaultMode": "default"' "\"defaultMode\": \"$m\"")" deny "[E] defaultMode default to $m: deny"
  done
  eq "$(e '"defaultMode": "default"' '"defaultMode": "yolo"')" deny "[E] defaultMode to an unknown value: deny"
  eq "$(e '"additionalDirectories": ["/srv/a"]' '"additionalDirectories": ["/srv/a", "/"]')" deny "[E] an additional directory added: deny"
  eq "$(e '"defaultMode": "default"' '"defaultMode": "default", "newThing": true')" deny "[E] an unknown new permissions key: deny"
  eq "$(e '"hooks": {}' '"hooks": {"PreToolUse": []}')" deny "[E] hooks changed: deny"
  eq "$(e '"sekret-123"' '"n3w-value-9"')" deny "[E] env changed: deny"
  has "$(gw)" "env" "[E] …the reason names the key env"
  hasnt "$(gw)" "sekret" "[S] …and never an env value (old)"
  hasnt "$(gw)" "n3w-value" "[S] …nor the new value"
  eq "$(e '"model": "opus"' '"model": "opus", "apiKeyHelper": "/bin/x"')" deny "[E] apiKeyHelper added: deny"
  eq "$(e '"model": "opus"' '"model": "opus", "enabledPlugins": {"x@y": true}')" deny "[E] enabledPlugins added: deny"
  eq "$(e '"model": "opus"' '"model": "opus", "disableAllHooks": true')" deny "[E] disableAllHooks added: deny"
  eq "$(e '"model": "opus"' '"model": "opus", "statusLine": {"type": "command", "command": "x"}')" deny "[E] statusLine added: deny"
  eq "$(e '"model": "opus"' '"model": "opus", "someFutureKey": 1')" deny "[E] an unknown new top-level key: deny"
  eq "$(w '{"permissions": ')" deny "[E] an after-state that is not JSON: deny"
  eq "$(w '[]')" deny "[E] an after-state that is not an object: deny"
  ln -s "$W/.claude/settings.json" "$W/link.json"
  eq "$(guard "$P" "$W" Edit "$(ti_edit "$W/link.json" "$ADD_ALLOW_OLD" "$ADD_ALLOW_NEW")")" deny "[E] Edit through a symlink to the settings: deny"
  eq "$(guard "$P" "$W" Write "$(ti_write "$W/.claude/settings.local.json" '{"permissions": {"allow": ["Bash(curl:*)"]}}')")" deny \
     "[E] Write of a new settings.local.json with an allow rule: deny"
  mkdir -p "$HOME/.claude"; printf '%s\n' "$BASE" > "$HOME/.claude/settings.json"
  eq "$(guard "$P" "$W" Edit "$(ti_edit "$HOME/.claude/settings.json" "$ADD_ALLOW_OLD" "$ADD_ALLOW_NEW")")" deny "[E] the user settings ~/.claude/settings.json: deny"
  rm -rf "$HOME/.claude"
  local cfg; cfg=$(fresh); printf '%s\n' "$BASE" > "$cfg/settings.json"
  GENV=(CLAUDE_CONFIG_DIR="$cfg")
  eq "$(guard "$P" "$W" Edit "$(ti_edit "$cfg/settings.json" "$ADD_ALLOW_OLD" "$ADD_ALLOW_NEW")")" deny "[E] \$CLAUDE_CONFIG_DIR/settings.json: deny"
  GENV=()
  eq "$(guard "$P" "$W" NotebookEdit '{"notebook_path": "'"$W"'/.claude/settings.json", "new_source": "x"}')" deny "[E] NotebookEdit on the settings: deny"
  mkdir -p "$W/.CLAUDE"; printf '%s\n' "$BASE" > "$W/.CLAUDE/SETTINGS.JSON"
  eq "$(guard "$P" "$W" Edit "$(ti_edit "$W/.CLAUDE/SETTINGS.JSON" "$ADD_ALLOW_OLD" "$ADD_ALLOW_NEW")")" deny \
     "[E] .CLAUDE/SETTINGS.JSON (the same file on a case-insensitive disk, macOS): deny"
  ln "$W/.claude/settings.json" "$W/hard.json"
  eq "$(guard "$P" "$W" Edit "$(ti_edit "$W/hard.json" "$ADD_ALLOW_OLD" "$ADD_ALLOW_NEW")")" deny "[E] Edit through a hard link to the settings: deny"
  rm -f "$W/hard.json"
  eq "$(w "$(with 'd["model"] = "opus"' | sed 's/"opus"/NaN/')")" deny "[E] an after-state JavaScript cannot parse (NaN): deny"
  mkdir -p "$W/dot"; printf '%s\n' "$BASE" > "$W/dot/s.json"; ln -s "$W/dot/s.json" "$W/.claude/settings.local.json"
  eq "$(guard "$P" "$W" Edit "$(ti_edit "$W/dot/s.json" "$ADD_ALLOW_OLD" "$ADD_ALLOW_NEW")")" deny \
     "[E] Edit of the file a settings link points to (a dotfiles repo): deny"
  rm -f "$W/.claude/settings.local.json"
  eq "$(e '“allow”: ["Bash(ls:*)"]' '"allow": ["Bash(ls:*)", "Bash(curl:*)"]')" deny \
     "[E] an Edit that does not match the settings exactly (curly quotes Claude Code may normalise): deny, could not check"
  printf '{"permissions": {"deny": ["Bash(rm:*)", null], "defaultMode": "Auto"}}\n' > "$W/.claude/settings.json"
  eq "$(w '{"permissions": {"deny": [], "defaultMode": "Auto"}}')" deny "[E] a deny rule removed from a list that also holds a non-string: deny"
  eq "$(w '{"permissions": {"deny": ["Bash(rm:*)", null], "defaultMode": "bypassPermissions"}}')" deny "[E] defaultMode from an unknown value to bypassPermissions: deny"
  printf '%s\n' "$BASE" > "$W/.claude/settings.json"
  local D; D=$(fresh); mkdir -p "$D/.claude/settings.json"
  eq "$(guard "$P" "$D" Edit "$(ti_edit "$D/.claude/settings.json" a b)")" deny "[E] a settings target that cannot be read: deny (could not check)"
}

fam_bash() {  # [B] Bash: a write shape onto a settings name in the text is denied, narrowing included
  P=$1; W=$(project)
  local S=.claude/settings.json c
  local CMDS=(
    "echo '{}' > $S"
    "echo x >> $S"
    "printf x >| $S"
    "jq '.permissions.allow += [\"Bash(curl:*)\"]' $S | tee $S"
    "sed -i 's/ls:/curl:/' $S"
    "sed -i.bak -e 's/ls:/curl:/' $S"
    "perl -pi -e 's/ls/curl/' $S"
    "python3 -c \"import json;p='$S';d=json.load(open(p));d['permissions']['allow'].append('Bash(curl:*)');json.dump(d,open(p,'w'))\""
    "python3 - <<'EOF'
import json
p = '$S'
d = json.load(open(p))
d['permissions']['allow'].append('Bash(curl:*)')
open(p, 'w').write(json.dumps(d))
EOF"
    "node -e \"require('fs').writeFileSync('$S','{}')\""
    "jq '.permissions.allow += [\"x\"]' $S > /tmp/s.json && mv /tmp/s.json $S"
    "jq '.permissions.allow += [\"x\"]' $S | sponge $S"
    "cp /tmp/new.json $S"
    "rm .claude/settings.local.json"
    "cd .claude && sed -i 's/a/b/' settings.json"
    "bash -c \"echo {} > $S\""
    "cat > ~/.claude/settings.json <<'EOF'
{}
EOF"
    "git checkout HEAD -- $S"
    "ln -sf /tmp/x.json $S"
    "dd if=/tmp/x.json of=$S"
    "truncate -s 0 $S"
    "echo {} > \"\$CLAUDE_CONFIG_DIR/settings.json\""
    "ln .claude/settings.json x.json"
    "cp /tmp/settings.json .claude/"
    "find .claude -name settings.json -exec sed -i s/a/b/ {} +"
    "find .claude -name 'settings*.json' -delete"
    "echo .claude/settings.json | xargs rm"
    "(cp /tmp/x.json .claude/settings.json)"
    "perl -e 'open(my \$f, \">\", \".claude/settings.json\"); print \$f 1'"
    "patch .claude/settings.json < /tmp/p.diff"
    "awk -i inplace '{print}' .claude/settings.json"
    "echo x > .CLAUDE/SETTINGS.JSON"
    "mv /tmp/settings.json ~/.claude/"
    "ln -s /tmp/settings.json .claude/"
    "cp -t .claude/ /tmp/settings.json"
    "cp /tmp/e.json .claude/settings.json 2>/dev/null"
    "cp /tmp/e.json .claude/settings.json # restore"
    "cd \"\$CLAUDE_CONFIG_DIR\" && echo {} > settings.json"
    "bash -c \"python3 -c 'open(\\\".claude/settings.json\\\",\\\"w\\\").write(1)'\""
    "python3 -c \"import pathlib; f=pathlib.Path('.claude/settings.json').open('w'); print('{}', file=f)\""
    "cat <<'EOF' | bash
rm .claude/settings.json
EOF"
    "bash <<'EOF'
rm .claude/settings.json
EOF"
    "git restore $S"
    "git -C . checkout -- $S"
    "ls .claude/settings*.json | xargs rm"
    "find .claude -name settings.json -exec rm {} \\;"
    "find .claude -type f -name settings.json -exec rm -f {} +"
    "find .claude -name settings.json -exec echo {} \\; -exec sed -i s/a/b/ {} \\;"
    "find .claude -name settings.json -exec cp /tmp/x {} \\;"
    "sed -i 's/ #.*//' $S"
    "cp 'a #1' $S"
    "eval \"rm $S\""
    "sudo -u root tee $S"
    "timeout -s KILL 5 rm $S"
    "setsid rm $S"
    "echo \`rm $S\`"
    "echo \$(rm $S)"
    "bash -lc \"rm $S\""
    "sh -ec 'rm $S'"
    "su -c \"rm $S\""
    "rsync -t /tmp/x $S"
    "rsync -t /tmp/settings.json .claude/"
    "find .claude -name settings.json | xargs cp /tmp/x"
    "find .claude -name settings.json | xargs -I{} cp /tmp/x {}"
    "find .claude -name settings.json | xargs git rm"
    "cat <<< x
rm $S
x"
    "rm .claude/*settings.json"
    "cp -rt .claude /tmp/settings.json"
    "cp --target-directory .claude /tmp/settings.json"
    "cp /tmp/settings.json .claude -v"
    "rm 2>&1 $S"
    "git commit -m \"\$(cat <<'EOF'
it's done
EOF
)\" && echo x > $S"
    "echo \"\$(cat <<'EOF'
(
EOF
)\"; rm $S"
    "python3 -c \"import os; os.system('echo x > .claude/settings.json')\""
    "python3 -c \"import subprocess; subprocess.run('echo x > .claude/settings.json', shell=True)\""
    "node -e \"require('child_process').execSync('echo x > .claude/settings.json')\""
    "perl -e 'system(\"echo x > .claude/settings.json\")'"
    "watch 'echo x > .claude/settings.json'"
    "flock /tmp/l -c 'echo x > .claude/settings.json'"
    "awk 'BEGIN{print \"x\" > \".claude/settings.json\"}'"
    "bash -c -- \"rm $S\""
    "bash -c \"\$(cat <<'EOF'
rm $S
EOF
)\""
    "function f { rm $S; }; f"
    "watch -n 1 'echo x > .claude/settings.json'"
    "parallel -j 2 'echo x > .claude/settings.json' ::: 1 2"
    "python3 -c \"import subprocess; subprocess.run(['sh', '-c', 'echo x > .claude/settings.json'])\""
  )
  for c in "${CMDS[@]}"; do
    eq "$(b "$c")" deny "[B] $(printf '%s' "$c" | head -n 1)"
  done
  GENV=(CLAUDE_CONFIG_DIR="$W/cfgd"); mkdir -p "$W/cfgd"
  eq "$(b 'cp /tmp/settings.json ${CLAUDE_CONFIG_DIR}')" deny "[B] cp into \${CLAUDE_CONFIG_DIR}"
  GENV=()
  eq "$(guard "$P" "$W/.claude" Bash "$(ti_bash 'cp /tmp/settings.json .')")" deny "[B] cp /tmp/settings.json . with the cwd in .claude"
  eq "$(guard "$P" "$W/.claude" Bash "$(ti_bash 'mv /tmp/settings.json ./')")" deny "[B] mv /tmp/settings.json ./ with the cwd in .claude"
  mkdir -p "$W/.claude/hooks" "$W/cfgdir"
  eq "$(guard "$P" "$W/.claude/hooks" Bash "$(ti_bash 'cd .. && echo x > settings.json')")" deny "[B] cd .. && echo x > settings.json from .claude/hooks"
  GENV=(CLAUDE_CONFIG_DIR="$W/cfgdir")
  eq "$(b 'cd cfgdir && echo x > settings.json')" deny "[B] cd into \$CLAUDE_CONFIG_DIR by its relative name"
  GENV=()
  eq "$(b "sed -i 's/ls:/curl:/' $S")" deny "[B] sed -i again"
  has "$(gw)" "kind:settings-merge" "[B] …the reason names kind:settings-merge"
  has "$(gw)" "Edit" "[B] …and Edit for a narrowing or a harmless key"
  has "$(gw)" "If the command only reads" "[B] …and how to phrase a read the text matched"
}

fam_pass() {  # [P] no false stop: narrowing, harmless keys, reads, the kind and the bootstrap, other settings files
  P=$1; W=$(project)
  eq "$(e '"allow": ["Bash(ls:*)"]' '"allow": []')" none "[P] Edit removes an allow rule: passes"
  eq "$(e '"ask": ["Bash(rm:*)"]' '"ask": ["Bash(rm:*)", "Bash(git push:*)"]')" none "[P] Edit adds an ask rule: passes"
  eq "$(e '"deny": ["Read(./.env)"]' '"deny": ["Read(./.env)", "Bash(curl:*)"]')" none "[P] Edit adds a deny rule: passes"
  eq "$(w "$(with 'd["permissions"]["deny"].append("Bash(curl:*)"); d["permissions"]["allow"] = []')")" none "[P] Write adds a deny and drops the allow: passes"
  eq "$(e '"defaultMode": "default"' '"defaultMode": "plan"')" none "[P] defaultMode default to plan: passes"
  eq "$(e '"additionalDirectories": ["/srv/a"]' '"additionalDirectories": []')" none "[P] an additional directory removed: passes"
  eq "$(e '"defaultMode": "default"' '"defaultMode": "default", "disableBypassPermissionsMode": "disable"')" none "[P] disableBypassPermissionsMode set: passes"
  eq "$(e '"model": "opus"' '"model": "sonnet"')" none "[P] model changed: passes"
  eq "$(e '"model": "opus"' '"model": "opus", "attribution": {"commit": ""}, "includeCoAuthoredBy": false')" none "[P] attribution keys added: passes"
  eq "$(guard "$P" "$W" MultiEdit "$(ti_multi "$W/.claude/settings.json" '"opus"' '"sonnet"' '"allow": ["Bash(ls:*)"]' '"allow": []')")" none \
     "[P] MultiEdit: model and an allow rule removed: passes"
  eq "$(guard "$P" "$W" Edit "$(ti_edit "$W/.vscode/settings.json" "$ADD_ALLOW_OLD" "$ADD_ALLOW_NEW")")" none "[P] Edit of .vscode/settings.json: passes"
  eq "$(guard "$P" "$W" Write "$(ti_write "$W/app/settings.json" '{"hooks": 1}')")" none "[P] Write of app/settings.json: passes"
  eq "$(guard "$P" "$W" Write "$(ti_write "$W/rules.json" '{"allow": ["Bash(curl:*)"]}')")" none "[P] Write of the kind's rules file: passes"
  eq "$(guard "$P" "$W" Write "$(ti_write "$W/README.md" 'hello')")" none "[P] Write of an ordinary file: passes"
  printf '\357\273\277%s\n' "$BASE" > "$W/.claude/settings.json"
  eq "$(e '"model": "opus"' '"model": "sonnet"')" none "[P] Edit of model in a settings file that starts with a BOM: passes"
  printf '%s\n' "$BASE" > "$W/.claude/settings.json"
  printf '\357\273\277%s\n' "$BASE" > "$W/.claude/settings.json"
  eq "$(w '{"permissions": {"allow": [], "ask": [], "deny": []}, "model": "opus"}')" deny "[P] (a deny kept here) a BOM file whose Write drops the BOM and the ask and deny rules: deny"
  printf '%s\n' "$BASE" > "$W/.claude/settings.json"
  local blob t0 t1
  blob=$(python3 -c 'print("QUJD" * 50000)')
  t0=$(date +%s)
  eq "$(b "echo $blob | base64 -d > logo.png && jq .name config/settings.json")" none "[P] a 200 KB token next to a settings name: passes"
  eq "$(b "echo $blob > .claude/settings.json")" deny "[B] (a control kept here) the same 200 KB token written onto the settings: deny"
  t1=$(date +%s)
  [ $((t1 - t0)) -le 3 ] && ok "[P] …within 3 s ($((t1 - t0)) s)" || bad "[P] …within 3 s (took $((t1 - t0)) s)"
  blob=$(python3 -c 'print(" ".join(["settings.json"] * 1600))')
  t0=$(date +%s); GENV=(CLAUDE_CONFIG_DIR="$W/cfgd"); mkdir -p "$W/cfgd"
  eq "$(b "cd app && cat $blob")" none "[P] 1600 bare settings names with \$CLAUDE_CONFIG_DIR set: passes"
  GENV=(); t1=$(date +%s)
  [ $((t1 - t0)) -le 3 ] && ok "[P] …within 3 s ($((t1 - t0)) s)" || bad "[P] …within 3 s (took $((t1 - t0)) s)"
  local S=.claude/settings.json c
  local L="$HOME/.local/state/vibemaestro/baton/bin/baton"
  local CMDS=(
    "cat $S"
    "jq '.permissions' $S > /tmp/x.json"
    "jq '.permissions.allow' $S"
    "grep -n allow $S"
    "sed -n 1,20p $S"
    "head -n 5 $S"
    "cp $S /tmp/bak.json"
    "git diff $S"
    "git add $S"
    "git log -p -- $S"
    "diff $S /tmp/x.json"
    "ls -la .claude/"
    "python3 -c \"import json;print(json.load(open('$S'))['permissions'])\""
    "$L go kind:settings-merge $S /tmp/rules.json"
    "python3 $P/scripts/baton.py run kit:coordinator-bootstrap"
    "echo x > .vscode/settings.json"
    "sed -i s/a/b/ app/settings.json"
    "echo hi > /tmp/out.txt"
    "echo .claude/settings.json | xargs cat"
    "find .claude -name settings.json"
    "find .claude -name settings.json -exec cat {} +"
    "git rm --cached .claude/settings.local.json"
    "grep -n rm $S"
    "grep -c tee $S"
    "jq '.permissions.deny[] | select(contains(\"mv\"))' $S"
    "sed -i 's/4/2/' $W/.claude/worktrees/feat/.vscode/settings.json"
    "echo '{}' > $W/.claude/worktrees/feat/src/settings.json"
    "rm $W/.claude/worktrees/feat/build/settings.json"
    "sed -i s/a/b/ $W/.claude/worktrees/feat/appsettings.Development.json"
    "git add $S && git commit -m 'chore: rm stale allow rule from .claude/settings.json'"
    "git commit -m 'fix: restore the deny rules in .claude/settings.json'"
    "git commit -F - <<'EOF'
docs: the guard
rm .claude/settings.json is now stopped
EOF"
    "python3 -c \"import json,sys; json.dump(json.load(open('.claude/settings.json')), sys.stdout, indent=2)\""
    "git restore --staged $S"
    "cd frontend && sed -i 's/a/b/' settings.json && git add .claude/agents/x.md"
    "cat .claude-plugin/plugin.json && cp settings.default.json settings.json"
    "find .claude -name 'settings*.json' -exec cp {} /tmp/bak/ \\;"
    "ls .claude/settings*.json | xargs -I{} cp {} /tmp/bak/"
    "ls .claude/settings*.json | xargs sed -n '/allow/p'"
    "git commit -F - <<EOF
note: echo x > .claude/settings.json is denied
EOF"
    "git commit -m \"docs: tee > .claude/settings.json\""
    "echo \"see > .claude/settings.json\""
    "gh pr create --title 'guard' --body 'Stops sed -i on .claude/settings.json; rm it by hand'"
    "echo .claude/settings.json | xargs -I{} cp {} {}.bak"
    "python3 -c \"import json;print(json.load(open('.claude/settings.json'))['model'])\" 2>&1"
    "python3 -c \"import json;print(json.load(open('.claude/settings.json'))['model'])\" 2>/dev/null"
    "python3 -c \"import json;d=json.load(open('.claude/settings.json'));print(len(d['permissions']['allow'])>0)\""
    "perl -ne 'print \$_ if \$.>2' .claude/settings.json"
    "python3 -c \"import subprocess;print(subprocess.check_output(['cat','.claude/settings.json']))\""
    "git commit -m \"\$(cat <<'EOF'
docs: it's the guard for .claude/settings.json
EOF
)\""
    "jq . $S > /tmp/x.json && mv /tmp/x.json /tmp/y.json"
  )
  for c in "${CMDS[@]}"; do
    eq "$(b "$c")" none "[P] $c"
  done
}

fam_limits() {  # [K] the known limits stay as the docs name them: these writes are not seen (asserted, so the docs stay true)
  P=$1; W=$(project)
  eq "$(b 'f=.claude/sett; echo x > ${f}ings.json')" none "[K] a name built at run time is not seen"
  eq "$(b 'bash ./write-settings.sh')" none "[K] a script file run is not seen"
  eq "$(b 'git apply /tmp/p.diff')" none "[K] a patch that names the file inside is not seen"
}

fam_nul() {  # [F] a NUL byte in a Bash text that names the settings: denied (could not check), not passed
  P=$1; W=$(project)
  local pl out
  pl=$(python3 -c 'import json, sys; print(json.dumps({"tool_name": "Bash", "cwd": sys.argv[1], "tool_input": {"command": "echo x > .claude/settings.json\u0000"}}))' "$W")
  out=$(printf '%s' "$pl" | (cd "$W" && cenv CLAUDE_PLUGIN_ROOT="$P" bash -c "$(hook_cmds "$P/hooks/hooks.json" PreToolUse Bash | grep -F settings-guard)") 2>/dev/null)
  eq "$(dec "$out")" deny "[F] a NUL byte in a Bash text naming the settings: deny"
}

fam_wiring() {  # [H] hooks.json runs the guard for each tool, as its own entry, and the repo config cannot silence it
  P=$1; local t
  for t in Edit Write MultiEdit NotebookEdit Bash; do
    has "$(hook_cmds "$P/hooks/hooks.json" PreToolUse "$t")" 'scripts/settings-guard.py' "[H] hooks.json: PreToolUse $t runs settings-guard.py"
  done
  W=$(project); mkdir -p "$W/.vibemaestro"; printf '{"hooks": "off"}\n' > "$W/.vibemaestro/sdlc.json"
  eq "$(e "$ADD_ALLOW_OLD" "$ADD_ALLOW_NEW")" deny "[H] hooks: off in the repo config: still deny"
  eq "$(printf 'not json' | (cd "$W" && cenv CLAUDE_PLUGIN_ROOT="$P" bash -c "$(hook_cmds "$P/hooks/hooks.json" PreToolUse Bash | grep -F settings-guard)") >/dev/null 2>&1; echo $?)" 0 \
     "[H] a payload that is not JSON: rc 0, nothing blocked"
}

fam_pod() {  # [Q] in a pod the owner never signs: the guard's message and the kind's exit 8 name the coordinator, no sign line
  P=$1; W=$(project); local st out
  GENV=(INTENT_SLUG=t SEAT=t)
  eq "$(e "$ADD_ALLOW_OLD" "$ADD_ALLOW_NEW")" deny "[Q] in a pod: deny"
  has "$(gw)" "coordinator" "[Q] …the reason hands the call to the coordinator"
  hasnt "$(gw)" "go --queue kind:" "[Q] …and offers no go --queue call"
  GENV=()
  hasnt "$(e "$ADD_ALLOW_OLD" "$ADD_ALLOW_NEW"; gw)" "In a pod" "[Q] outside a pod the reason has no pod sentence"
  st=$(fresh); printf '{"allow": ["Bash(python3 tools/job-7.py:*)"]}\n' > "$W/rules.json"
  out=$(cd "$W" && cenv XDG_STATE_HOME="$st" INTENT_SLUG=t SEAT=t python3 "$P/scripts/baton.py" go kind:settings-merge \
        "$W/.claude/settings.json" "$W/rules.json" 2>&1; echo "rc=$?")
  has "$out" "rc=8" "[Q] go kind:settings-merge in a pod: exit 8"
  hasnt "$out" "sign --by owner" "[Q] …no sign line"
  hasnt "$out" "on the owner's go" "[Q] …no 'on the owner's go' step"
  hasnt "$out" "go --queue kind:" "[Q] …no go --queue call"
  has "$out" "coordinator" "[Q] …it names the coordinator"
  out=$(cd "$W" && cenv XDG_STATE_HOME="$st" python3 "$P/scripts/baton.py" go kind:settings-merge \
        "$W/.claude/settings.json" "$W/rules.json" 2>&1; echo "rc=$?")
  has "$out" "on the owner's go: " "[Q] outside a pod: the owner's sign line stays"
}

fam_next() {  # [N] the deny names the exact next step: the rules file's content, the launcher as it is typed, the real settings path
  P=$1; W=$(project); local S="$W/.claude/settings.json" st out cmd v
  eq "$(e "$ADD_ALLOW_OLD" "$ADD_ALLOW_NEW")" deny "[N] Edit adds an allow rule: deny"
  has "$(gw)" 'Write {"allow": ["Bash(curl:*)"]} to a fresh path outside `.claude/`' "[N] …the rules file content is printed"
  has "$(gw)" "go kind:settings-merge $S <that path>" "[N] …and the real settings path"
  has "$(gw)" "\`python3 $P/scripts/baton.py go kind:settings-merge" "[N] …and with no launcher installed, the plugin's baton.py"
  for v in '<launcher>' '<settings.json>' '<rules.json>'; do hasnt "$(gw)" "$v" "[N] …no placeholder $v"; done
  eq "$(w "$(with 'd["permissions"]["allow"].append("Bash(curl:*)"); d["permissions"]["ask"].append("Bash(git push:*)")')")" deny \
     "[N] Write adds an allow and an ask rule: deny"
  has "$(gw)" '{"allow": ["Bash(curl:*)"], "ask": ["Bash(git push:*)"]}' "[N] …the rules file holds both"
  eq "$(e '"defaultMode": "default"' '"defaultMode": "auto"')" deny "[N] defaultMode up, no rule added: deny"
  has "$(gw)" "Write the rules you mean to add" "[N] …it says what the session writes there"
  hasnt "$(gw)" 'Write {"allow"' "[N] …and prints no rules file"
  eq "$(b "sed -i 's/ls:/curl:/' .claude/settings.json")" deny "[N] Bash sed -i: deny"
  has "$(gw)" "go kind:settings-merge .claude/settings.json <that path>" "[N] …the word the command wrote to"
  has "$(gw)" "Write the rules you mean to add" "[N] …and what the session writes there"
  (cd "$W" && cenv python3 "$P/scripts/baton.py" permissions --install-launcher) >/dev/null 2>&1
  eq "$(e "$ADD_ALLOW_OLD" "$ADD_ALLOW_NEW")" deny "[N] with the launcher installed under HOME: deny"
  has "$(gw)" "\`~/.local/state/vibemaestro/baton/bin/baton go kind:settings-merge $S <that path>\`" \
      "[N] an installed launcher under HOME: the ~/ spelling the permission rules allow"
  rm -rf "$HOME/.local/state/vibemaestro"
  st=$(fresh); (cd "$W" && cenv XDG_STATE_HOME="$st" python3 "$P/scripts/baton.py" permissions --install-launcher) >/dev/null 2>&1
  GENV=(XDG_STATE_HOME="$st")
  eq "$(e "$ADD_ALLOW_OLD" "$ADD_ALLOW_NEW")" deny "[N] with the launcher installed outside HOME: deny"
  has "$(gw)" "\`$st/vibemaestro/baton/bin/baton go kind:settings-merge $S" "[N] an installed launcher outside HOME: its path"
  GENV=()
  # follow the message as a session would: Write the printed rules, run the printed command; the kind stops for the owner (exit 8)
  e "$ADD_ALLOW_OLD" "$ADD_ALLOW_NEW" >/dev/null
  v=$(python3 - "$TMP/gw" "$W/rules-next.json" <<'PY'
import re, sys
m = re.search(r"Write (\{.*?\}) to a fresh path outside `\.claude/`.*?, then run `(.*?) <that path>`", open(sys.argv[1]).read())
open(sys.argv[2], "w").write(m.group(1))
print(m.group(2))
PY
)
  out=$(cd "$W" && cenv bash -c "$v $W/rules-next.json" 2>&1; echo "rc=$?")
  has "$out" "rc=8" "[N] the printed rules and command, run as printed: the kind stops for the owner (exit 8)"
  printf '[]\n' > "$W/rules-bad.json"
  out=$(cd "$W" && cenv bash -c "$v $W/rules-bad.json" 2>&1; echo "rc=$?")
  hasnt "$out" "rc=8" "[N] control: the same command with a rules file that is not an object does not reach exit 8"
  # a Write that creates the settings file: the kind merges only into a file that exists, so the step names `{}` first
  local N="$W/.claude/settings.local.json"
  eq "$(guard "$P" "$W" Write "$(ti_write "$N" '{"permissions": {"allow": ["Bash(curl:*)"]}}')")" deny "[N] Write creates a settings file with an allow rule: deny"
  has "$(gw)" "Write {} to $N (Read it first if it exists; it widens nothing" "[N] …it names writing {} to the new file first"
  eq "$(guard "$P" "$W" Write "$(ti_write "$N" '{}')")" none "[N] …and that Write of {} passes the guard"
  printf '{}\n' > "$N"; printf '{"allow": ["Bash(curl:*)"]}\n' > "$W/rules-new.json"
  out=$(cd "$W" && cenv bash -c "${v% *} $N $W/rules-new.json" 2>&1; echo "rc=$?")
  has "$out" "rc=8" "[N] …then the printed command on it: the kind stops for the owner (exit 8)"
  printf 'not json\n' > "$N"
  eq "$(guard "$P" "$W" Write "$(ti_write "$N" '{"permissions": {"allow": ["Bash(curl:*)"]}}')")" deny "[N] Write over a settings file that is not JSON: deny"
  has "$(gw)" "The file holds no JSON object the kind can merge into" "[N] …it says the kind cannot merge into it"
  hasnt "$(gw)" 'Write {"allow"' "[N] …and offers no rules file"
  printf '\357\273\277{}\n' > "$N"
  eq "$(guard "$P" "$W" Write "$(ti_write "$N" '{"permissions": {"allow": ["Bash(curl:*)"]}}')")" deny "[N] Write over a settings file with a byte-order mark: deny"
  has "$(gw)" "The file holds no JSON object the kind can merge into" "[N] a settings file with a byte-order mark: the kind (json.load) cannot read it"
  : > "$N"
  eq "$(guard "$P" "$W" Write "$(ti_write "$N" '{"permissions": {"allow": ["Bash(curl:*)"]}}')")" deny "[N] Write over a 0-byte settings file: deny"
  has "$(gw)" "Write {} to $N (Read it first if it exists; it widens nothing" "[N] a 0-byte settings file: {} first"
  rm -f "$N"
  eq "$(guard "$P" "$W" Edit "$(ti_edit "$N" '"x"' '"y"')")" deny "[N] an Edit that cannot apply to a missing file: deny"
  has "$(gw)" "Write {} to $N (Read it first if it exists; it widens nothing" "[N] an Edit that cannot apply to a missing file: {} first"
  eq "$(b 'echo hi > .claude/settings.local.json')" deny "[N] Bash writes a missing settings file: deny"
  has "$(gw)" "Write {} to $W/.claude/settings.local.json (Read it first" "[N] Bash on a missing settings file: {} first, at its absolute path"
  printf '%s\n' "$BASE" > "$W/.claude/settings.json"
  eq "$(b 'cd .claude && echo x > settings.json')" deny "[N] Bash after a cd: deny"
  hasnt "$(gw)" "Write {} to" "[N] …the word is relative to another directory: no {} step"
  local c
  for c in "bash -c 'cd .claude; echo x > settings.json'" "cd && echo x > .claude/settings.local.json" \
           "git -C .claude checkout settings.json" "env -C .claude tee settings.local.json" "dd of=.claude/settings.local.json"; do
    eq "$(b "$c")" deny "[N] $c: deny"
    hasnt "$(gw)" "Write {} to" "[N] $c: no {} step (the directory is not sure)"
  done
  has "$(gw)" "go kind:settings-merge .claude/settings.local.json <that path>" "[N] dd of=: the command names the file, not of="
  python3 -c 'print("[" * 100000 + "]" * 100000)' > "$W/.claude/settings.deep.json"
  eq "$(guard "$P" "$W" Write "$(ti_write "$W/.claude/settings.deep.json" '{"permissions": {"allow": ["Bash(curl:*)"]}}')")" deny \
     "[N] a deeply nested settings file: Write still denied"
  eq "$(b 'echo hi > .claude/settings.deep.json')" deny "[N] a deeply nested settings file: Bash still denied"
  local F="$W/.claude/settings.fifo.json" pid t0 t1; mkfifo "$F"
  ( sleep 20; exec 3>"$F" ) & pid=$!
  t0=$(date +%s); v=$(b 'echo hi > .claude/settings.fifo.json'); t1=$(date +%s)
  kill "$pid" 2>/dev/null; pkill -P "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  eq "$v/$(( t1 - t0 < 10 ))" "deny/1" "[N] a FIFO named as a settings file: denied at once, never read"
  # a path that needs quoting, and no value other than rule strings in the rules file
  local W2; W2="$(fresh)/p q"; mkdir -p "$W2/.claude"; printf '%s\n' "$BASE" > "$W2/.claude/settings.json"
  eq "$(guard "$P" "$W2" Edit "$(ti_edit "$W2/.claude/settings.json" "$ADD_ALLOW_OLD" "$ADD_ALLOW_NEW")")" deny "[N] a settings path with a space: deny"
  has "$(gw)" "go kind:settings-merge '$W2/.claude/settings.json' <that path>" "[N] …the path is shell-quoted"
  eq "$(guard "$P" "$W2" Write "$(ti_write "$W2/.claude/settings.local.json" '{"permissions": {"allow": ["Bash(curl:*)"]}}')")" deny \
     "[N] Write creates a settings file under a path with a space: deny"
  has "$(gw)" "Write {} to $W2/.claude/settings.local.json (Read it first" "[N] …the Write step names the path as the Write tool takes it (unquoted)"
  eq "$(w "$(with 'd["permissions"]["allow"].append("Bash(curl:*)"); d["env"]["TOKEN"] = "n3w-value-9"')")" deny \
     "[N] Write adds an allow rule and changes env: deny"
  has "$(gw)" 'Write {"allow": ["Bash(curl:*)"]} to' "[N] …the rules file holds the rule only"
  hasnt "$(gw)" "sekret" "[N] …no env value (old)"
  hasnt "$(gw)" "n3w-value" "[N] …nor the new one"
}

fam_bounded() {  # [R] one bounded reader for every file a payload names: a device, a FIFO, a file over 1 MiB are denied, never read whole
  P=$1; W=$(project); local k f why
  if [ ${#GCAP[@]} -eq 0 ]; then echo "  SKIP *** no prlimit or timeout here: [R] runs without its 2 GiB and 20 s caps ***"; fi
  local kinds="zero fifo big dir"
  ln -s /dev/zero "$W/.claude/settings.zero.json"; mkfifo "$W/.claude/settings.fifo.json"; mkdir "$W/.claude/settings.dir.json"
  python3 -c 'import sys; open(sys.argv[1], "w").write("{\"permissions\": {\"allow\": []}, \"pad\": \"" + "x" * (1 << 20) + "\"}")' "$W/.claude/settings.big.json"
  # a socket path is capped near 104 bytes and the scratch tree can be longer (a CI runner's temp, a planted-break run): bind it
  # in a short directory and link the settings name to it; the guard resolves the link, as for /dev/zero
  local sk; sk=$(mktemp -d "$SOCKD/s.XXXXXX")       # one per family run: planted-break runs end before the family does
  if python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$sk/s" 2>/dev/null; then
    ln -s "$sk/s" "$W/.claude/settings.sock.json"; kinds="$kinds sock"
  else echo "  SKIP *** no unix socket here: [R] sock DID NOT RUN ***"; fi
  printf '{}\n' > "$W/.claude/settings.mode0.json"; chmod 000 "$W/.claude/settings.mode0.json"
  if [ -r "$W/.claude/settings.mode0.json" ]; then echo "  SKIP *** running as root: [R] mode0 DID NOT RUN ***"; else kinds="$kinds mode0"; fi
  GUARD_CAP=(${GCAP[@]+"${GCAP[@]}"})
  for k in $kinds; do
    f="$W/.claude/settings.$k.json"; why="it is not a regular file"
    case "$k" in big) why="it is over 1048576 bytes";; mode0) why="cannot open it (PermissionError)";; esac
    eq "$(guard "$P" "$W" Edit "$(ti_edit "$f" '"allow": []' '"allow": ["Bash(curl:*)"]')")" deny "[R] $k: Edit denied within the caps"
    has "$(gw)" "could not be checked: $why" "[R] $k: Edit names why"
    eq "$(guard "$P" "$W" Write "$(ti_write "$f" '{"permissions": {"allow": ["Bash(curl:*)"]}}')")" deny "[R] $k: Write denied within the caps"
    has "$(gw)" "could not be checked: $why" "[R] $k: Write names why"
    eq "$(guard "$P" "$W" MultiEdit "$(ti_multi "$f" '"allow": []' '"allow": ["Bash(curl:*)"]')")" deny "[R] $k: MultiEdit denied within the caps"
    has "$(gw)" "could not be checked: $why" "[R] $k: MultiEdit names why"
    eq "$(b "echo x > .claude/settings.$k.json")" deny "[R] $k: Bash denied within the caps"
  done
  chmod 600 "$W/.claude/settings.mode0.json"
  local n
  for n in 0 1; do
    python3 -c 'import sys
head, tail = "{\"model\": \"a\", \"permissions\": {\"allow\": []}, \"pad\": \"", "\"}"
open(sys.argv[1], "w").write(head + "x" * ((1 << 20) + int(sys.argv[2]) - len(head) - len(tail)) + tail)' "$W/.claude/settings.m$n.json" "$n"
  done
  eq "$(wc -c < "$W/.claude/settings.m0.json" | tr -d ' ')/$(wc -c < "$W/.claude/settings.m1.json" | tr -d ' ')" "1048576/1048577" "[R] instrument: the two files are 1 MiB and 1 MiB + 1"
  eq "$(guard "$P" "$W" Edit "$(ti_edit "$W/.claude/settings.m0.json" '"model": "a"' '"model": "b"')")" none "[R] exactly 1 MiB: read whole, a harmless Edit passes"
  eq "$(guard "$P" "$W" Edit "$(ti_edit "$W/.claude/settings.m1.json" '"model": "a"' '"model": "b"')")" deny "[R] 1 MiB + 1: denied"
  has "$(gw)" "could not be checked: it is over 1048576 bytes" "[R] 1 MiB + 1: …over the cap"
  printf '{\r\n  "model": "a",\r\n  "permissions": {"allow": []}\r\n}\r\n' > "$W/.claude/settings.crlf.json"
  eq "$(guard "$P" "$W" Edit "$(ti_edit "$W/.claude/settings.crlf.json" $'"model": "a",\n  "permissions"' $'"model": "b",\n  "permissions"')")" none \
     "[R] a CRLF file: read as text mode reads it, so a harmless Edit passes as on main"
  eq "$(guard "$P" "$W" Edit "$(ti_edit "$W/.claude/settings.crlf.json" '"allow": []' '"allow": ["Bash(curl:*)"]')")" deny "[R] a CRLF file: a widening Edit is denied"
  GUARD_CAP=()
}

FAMILIES="fam_edit fam_bash fam_pass fam_limits fam_wiring fam_pod fam_nul fam_next fam_bounded"
echo "== the real plugin =="
REAL="$TMP/real"; mk_plugin_copy "$REAL"
for f in $FAMILIES; do echo "-- $f"; "$f" "$REAL"; done

echo "== planted breaks: each family must go red on a plugin copy with one break =="
# BRK <label> <family> <needle> <file under the plugin> <old> <new> — a plugin copy with the replacement, then expect_red
BRK() {
  local label=$1 fam=$2 needle=$3 f=$4 d; d="$TMP/break-$label"; mk_plugin_copy "$d"
  mutate "$d/$f" "$5" "$6" || return
  expect_red "$label" "$fam" "$d" "$needle"
}
G=scripts/settings-guard.py
BRK redirect-unseen fam_bash "[B] echo '{}' >" $G '            return t, "a redirection"' '            pass'
BRK in-place-unseen fam_bash '[B] sed -i' $G '                return (hits or [x])[0], nm + " in place"' '                pass'
BRK interpreter-unseen fam_bash '[B] python3 -c' $G '        return next(x for x in named if w.claude(x)), "inline code that writes"' '        pass'
BRK runner-ignored fam_bash '[B] sudo -u root tee' $G '            if (k == first or runner) and nm in RUNNERS:' '            if False:'
BRK exec-ignored fam_bash '[B] find .claude -name settings.json -exec rm' $G '        if x in EXEC_FLAGS:' '        if False:'
BRK shell-string-unread fam_bash '[B] bash -lc' $G '        if nm in SHELLS + ("su", "flock"):' '        if False:'
BRK substitution-unread fam_bash '[B] echo `rm' $G '    for inner in nested:' '    for inner in []:'
BRK heredoc-as-commands fam_pass "[P] git commit -F -" $G '                if shell or run:' '                if True:'
BRK heredoc-shell-skipped fam_bash "[B] cat <<'EOF' | bash" $G '                if shell or run:' '                if False:'
BRK unclosed-swallowed fam_bash "[B] git commit -m \"\$(cat <<'EOF'" $G '                    nested.append(cmd[k:])          # unclosed: its text is read as commands too' '                    i = n; continue'
BRK shellout-unseen fam_bash "[B] python3 -c \"import os; os.system" $G '        for lit in literals(cmd):' '        for lit in []:'
BRK cd-arg-unread fam_bash '[B] cd .. && echo x > settings.json from .claude/hooks' $G 'x in cds or ".claude" in x.lower() or "CLAUDE_CONFIG_DIR" in x or x in (".", "./", "..", "../", "$PWD", "${PWD}")' '".claude" in x.lower() or "CLAUDE_CONFIG_DIR" in x or x in (".", "./", "$PWD", "${PWD}")'
BRK nul-fails-open fam_nul '[F] a NUL byte' $G '            if not NAME.search(cmd):' '            if True:'
BRK command-word-ignored fam_pass '[P] grep -n rm' $G '        if k == first or runner:' '        if True:'
BRK worktree-path fam_pass "[P] sed -i 's/4/2/'" $G \
    '                    ok = (claude_dir(d, self.cwd) or bool(settings_path(expand(w2, self.cwd), self.cwd))) if d else self.bare' \
    '                    ok = (".claude/" in w2.lower() or claude_dir(d, self.cwd)) if d else self.bare'
BRK allow-unchecked fam_edit '[E] Edit adds an allow rule' $G '            if k in GROWS and sa - sb:' '            if False:'
BRK shrink-unchecked fam_edit '[E] Edit removes an ask rule' $G '            if k in SHRINKS and sb - sa:' '            if False:'
BRK harmless-open fam_edit '[E] an unknown new top-level key' $G \
    '        if k != "permissions" and k not in HARMLESS and b.get(k, MISSING) != a.get(k, MISSING):' \
    '        if k != "permissions" and k not in HARMLESS and k in ("hooks", "env", "apiKeyHelper", "enabledPlugins", "disableAllHooks", "statusLine") and b.get(k, MISSING) != a.get(k, MISSING):'
BRK value-printed fam_edit '[S] …nor the new value' $G '            out.append("changes the key `%s`" % k)' '            out.append("changes the key `%s` to %s" % (k, json.dumps(a.get(k))))'
BRK links-unseen fam_edit '[E] Edit through a symlink' $G \
    '    if named_settings(p, cfg) or named_settings(real, cfg) or same_file(real, cwd):' '    if named_settings(p, cfg):'
BRK link-target-unseen fam_edit '[E] Edit through a hard link' $G \
    '                    if os.path.samestat(st, os.stat(os.path.join(d, n))):' '                    if False:'
BRK exact-match-trusted fam_edit '[E] an Edit that does not match the settings exactly' $G \
    '            raise Unchecked("the edit does not match the file exactly, so its result cannot be computed")' '            return text'
BRK case-sensitive fam_edit '[E] .CLAUDE/SETTINGS.JSON' $G 'fnmatch.fnmatchcase(os.path.basename(q).lower(), "settings*.json")' 'fnmatch.fnmatchcase(os.path.basename(q), "settings*.json")'
BRK nan-accepted fam_edit '[E] an after-state JavaScript cannot parse' $G '        d = json.loads(text, parse_constant=no_constant)' '        d = json.loads(text)'
BRK bom-before-unread fam_pass '[P] (a deny kept here) a BOM file' $G '    b = as_object(before[1:] if bb else before or "{}") or {}' '    b = as_object(before or "{}") or {}'
BRK narrowing-gated fam_pass '[P] Edit removes an allow rule' $G '            if k in GROWS and sa - sb:' '            if k in GROWS and sa != sb:'
BRK mode-any-change fam_pass '[P] defaultMode default to plan' $G '            if rank(va) > rank(vb, before=True):' '            if rank(va) != rank(vb, before=True):'
BRK multiedit-unwired fam_wiring '[H] hooks.json: PreToolUse MultiEdit' hooks/hooks.json '"matcher": "Edit|Write|MultiEdit|NotebookEdit|Bash"' '"matcher": "Edit|Write|NotebookEdit|Bash"'
BRK rules-unprinted fam_next '[N] …the rules file content is printed' $G '    return (real, found, added_rules(b, a)) if found else None' '    return (real, found, None) if found else None'
BRK path-placeholder fam_next '[N] …and the real settings path' $G '    q = shlex.quote(path) if os.path.isabs(path) else path' '    q = "<settings.json>"'
BRK launcher-placeholder fam_next '[N] an installed launcher under HOME' $G '            return baton.tilde_launcher() or shlex.quote(baton.launcher_path())' '            return LAUNCHER'
BRK baton-py-placeholder fam_next "[N] …and with no launcher installed, the plugin's baton.py" $G '        return "python3 " + shlex.quote(os.path.abspath(baton.__file__))' '        return LAUNCHER'
BRK new-file-unnamed fam_next '[N] …it names writing {} to the new file first' $G $'        if text is None:\n            return NEW_FILE, full' $'        if text is None:\n            return "", full'
BRK empty-unnamed fam_next '[N] a 0-byte settings file: {} first' $G $'        if not text.strip():\n            return NEW_FILE, full' $'        if not text.strip():\n            return "", full'
BRK not-object-unnamed fam_next '[N] …it says the kind cannot merge into it' $G '        return ("" if not text.startswith(BOM) and as_object(text) is not None else NOT_OBJECT), full' '        return "", full'
BRK bom-unnamed fam_next '[N] a settings file with a byte-order mark' $G '        return ("" if not text.startswith(BOM) and as_object(text) is not None else NOT_OBJECT), full' '        return ("" if as_object(text[1:] if text.startswith(BOM) else text) is not None else NOT_OBJECT), full'
BRK state-unread fam_next '[N] an Edit that cannot apply to a missing file: {} first' $G '    first, full = kind_state(path, cwd)' '    first, full = "", path'
BRK write-step-quoted fam_next '[N] …the Write step names the path as the Write tool takes it' $G '"holding a JSON object), then " % full if first == NEW_FILE' '"holding a JSON object), then " % shlex.quote(full) if first == NEW_FILE'
BRK state-raises fam_next '[N] a deeply nested settings file: Bash still denied' $G '    except BaseException:                           # RecursionError on a deeply nested file, among others' '    except OSError:'
BRK fifo-read fam_next '[N] a FIFO named as a settings file' $G 'os.O_RDONLY | getattr(os, "O_NONBLOCK", 0)' 'os.O_RDONLY'
BRK reader-blocking fam_bounded '[R] fifo: Edit denied within the caps' $G 'os.O_RDONLY | getattr(os, "O_NONBLOCK", 0)' 'os.O_RDONLY'
BRK reader-type-unchecked fam_bounded '[R] dir: Edit names why' $G '        if not stat.S_ISREG(os.fstat(fd).st_mode):' '        if False:'
# the planted break that reads /dev/zero whole caps itself at 512 MiB (RLIMIT_AS), so it cannot take a pod or a runner down
BRK reader-unbounded fam_bounded '[R] zero: Edit names why' $G $'        if not stat.S_ISREG(os.fstat(fd).st_mode):\n            raise Unchecked("it is not a regular file, so it is not read")\n        f = os.fdopen(fd, "rb")\n    except BaseException:\n        os.close(fd)\n        raise\n    with f:\n        data = f.read(MAX_READ + 1)' $'        f = os.fdopen(fd, "rb")\n    except BaseException:\n        os.close(fd)\n        raise\n    import resource\n    resource.setrlimit(resource.RLIMIT_AS, (1 << 29, 1 << 29))\n    with f:\n        data = f.read()'
BRK sock-unnamed fam_bounded '[R] sock: Edit names why' $G '            other = not stat.S_ISREG(os.stat(path).st_mode)' '            other = False'
BRK reader-size-unchecked fam_bounded '[R] big: Edit names why' $G '    if len(data) > MAX_READ:' '    if False:'
BRK reader-boundary fam_bounded '[R] exactly 1 MiB' $G '    if len(data) > MAX_READ:' '    if len(data) >= MAX_READ:'
BRK crlf-dropped fam_bounded '[R] a CRLF file: read as text mode reads it' $G '.replace("\r\n", "\n").replace("\r", "\n")' ''
BRK cd-state fam_next '[N] …the word is relative to another directory' $G '                        cwd="" if OTHER_DIR.search(cmd) else cwd))' '                        cwd=cwd))'
BRK other-dir-narrow fam_next '[N] cd && echo x > .claude/settings.local.json: no {} step' $G '(?<![\w-])(?:cd|pushd|popd|eval)(?![\w-])' '(?<![\w-])(?:pushd|popd|eval)(?![\w-])'
BRK of-prefix-kept fam_next '[N] dd of=: the command names the file' $G 're.sub(r"^[A-Za-z_][\w-]*=", "", hit[0])' 'hit[0]'
BRK rules-after-env fam_next '[N] …nor the new one' $G '    return out if "allow" in out else None' '    return dict(out, env=a.get("env")) if "allow" in out else None'
BRK path-unquoted fam_next '[N] …the path is shell-quoted' $G '    q = shlex.quote(path) if os.path.isabs(path) else path' '    q = path'
BRK rules-whole-object fam_next '[N] …no env value (old)' $G '    return out if "allow" in out else None' '    return dict(out, env=b.get("env")) if "allow" in out else None'
BRK ask-dropped fam_next '[N] …the rules file holds both' $G '    for k in ("allow", "ask", "deny"):' '    for k in ("allow",):'

echo "== nothing written outside the scratch tree =="
eq "$(tree_hash "$SRC_ROOT")" "$H0" "the repository tree is unchanged by the suite"
echo; summary
