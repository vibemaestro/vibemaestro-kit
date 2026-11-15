#!/bin/bash
# =============================================================================
# The kit's everyday mode (vibemaestro-sdlc scripts/everyday.py, wired in vsdlc.py): how the mode is chosen, and what a session
# in everyday mode gets instead of the developer process.
# Run: bash tests/test-everyday-mode.sh
# The hooks run as Claude Code runs them (the `command` strings of hooks/hooks.json) on a copy of the plugin with stand-in rules
# (mk_plugin): r-all (applyTo **), r-cmd (applyWhen lenh-bay), r-block (a plugin rule, level block). Developer mode itself is
# pinned byte for byte by tests/test-devmode-same.sh; here each step of the choice has its refusal case next to it.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
export VIBEMAESTRO_NO_UPDATE_CHECK=1
baton_set_mode "$XDG_STATE_HOME" manual        # no machine policy line in what the hooks print
unset VIBEMAESTRO_PROFILE                      # the person's own choice must not reach the cases (each sets it where it means to)
PL="$TMP/plugin"; mk_plugin "$PL"
HOOKS="$PL/hooks/hooks.json"

# hk <dir> <event> <tool> <payload> — stdout of every command of that event, joined (each a JSON or nothing)
hk() {
  local c
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    (cd "$1" && printf '%s' "$4" | CLAUDE_PLUGIN_ROOT="$PL" CLAUDE_PROJECT_DIR="$1" bash -c "$c" 2>/dev/null)
  done < <(hook_cmds "$HOOKS" "$2" "$3")
}
core() { hk "$1" SessionStart "" "$(p_start "$(sid)")" | head -c 100000 | python3 -c 'import json, sys, re
t = sys.stdin.read()
d = json.JSONDecoder(); i = 0
while i < len(t):                      # the first JSON is the core hook (the first SessionStart command)
    o, i = d.raw_decode(t, i); print(json.dumps(o)); break' ; }
start_cmd() {  # start_cmd <dir> <n> — the n-th SessionStart command alone (1 core, 2 context)
  local c; c=$(hook_cmds "$HOOKS" SessionStart "" | sed -n "${2}p")
  (cd "$1" && p_start "$(sid)" | CLAUDE_PLUGIN_ROOT="$PL" CLAUDE_PROJECT_DIR="$1" bash -c "$c" 2>/dev/null)
}
sub() { local c; c=$(hook_cmds "$HOOKS" SubagentStart general-purpose | head -n 1)
  (cd "$1" && printf '{"session_id":"%s","hook_event_name":"SubagentStart","agent_type":"general-purpose"}' "$(sid)" \
     | CLAUDE_PLUGIN_ROOT="$PL" CLAUDE_PROJECT_DIR="$1" bash -c "$c" 2>/dev/null); }
modeof() {  # modeof <dir> — "everyday:<reason words>" or "developer" from what the core hook delivers
  local o; o=$(start_cmd "$1" 1)
  case "$(ctx "$o")" in
    *"The general way of working"*) echo developer;;
    *"everyday mode, because"*) printf 'everyday:%s\n' "$(ctx "$o" | sed -nE 's/.*everyday mode, because ([^;]*);.*/\1/p' | head -n 1)";;
    *) echo "neither: ${o:0:80}";;
  esac
}
plain() { mkdir -p "$1/src"; printf 'x\n' > "$1/src/report.html"; }               # a folder that is not a git repository
repo() { mkdir -p "$1/src"; printf 'x\n' > "$1/src/app.js"; git_ -C "$1" init -q -b main; git_ -C "$1" add -A; git_ -C "$1" commit -qm c1; }
denied() { printf '%s' "$1" | grep -c '"permissionDecision": "deny"'; }   # the joined output of several commands holds one deny
remote() { git_ init -q --bare "$1.git"; git_ -C "$1" remote add origin "$1.git"; }
key() { mkdir -p "$1/.vibemaestro"; printf '{"schema": 1, "profile": "%s"}\n' "$2" > "$1/.vibemaestro/sdlc.json"; }
WHY_DEFAULT="this folder is not connected to a Git remote and is not a developer's repository"
WHY_FOLDER='this folder'"'"'s .vibemaestro/sdlc.json sets "profile": "everyday"'
WHY_PERSON="the person's setting VIBEMAESTRO_PROFILE=everyday"

echo "== [M] how the mode is chosen, the first answer wins =="
plain "$TMP/p1"
eq "$(modeof "$TMP/p1")" "everyday:$WHY_DEFAULT" "[M4] a folder that is not a git repository: everyday, by default"
repo "$TMP/r1"
eq "$(modeof "$TMP/r1")" developer "[M4] refusal: a repository that was there before, with no remote: developer, as today"
repo "$TMP/k1"; git_ -C "$TMP/k1" config --local vibemaestro.quietsave true
eq "$(modeof "$TMP/k1")" "everyday:$WHY_DEFAULT" "[M4] a repository the kit created (its mark in the local git config): everyday"
repo "$TMP/k2"; git_ -C "$TMP/k2" config --local vibemaestro.quietsave false
eq "$(modeof "$TMP/k2")" developer "[M4] refusal: the mark set to anything but true is no mark: developer"
repo "$TMP/g1"; remote "$TMP/g1"
eq "$(modeof "$TMP/g1")" developer "[M2] a repository with a remote: developer"
eq "$(VIBEMAESTRO_PROFILE=everyday modeof "$TMP/g1")" developer "[M2] refusal: the person's everyday does not move a folder with a remote"
eq "$(VIBEMAESTRO_PROFILE=everyday modeof "$TMP/r1")" "everyday:$WHY_PERSON" "[M3] the person's everyday: a repository with no remote follows it"
eq "$(VIBEMAESTRO_PROFILE=developer modeof "$TMP/p1")" developer "[M3] the person's developer: a plain folder follows it"
eq "$(VIBEMAESTRO_PROFILE=Everyday modeof "$TMP/r1")" "everyday:$WHY_PERSON" "[M3] the person's value is read without case"
eq "$(VIBEMAESTRO_PROFILE=sometimes modeof "$TMP/p1")" "everyday:$WHY_DEFAULT" "[M3] refusal: a value that names no mode is no choice"
repo "$TMP/f1"; remote "$TMP/f1"; key "$TMP/f1" everyday
eq "$(modeof "$TMP/f1")" "everyday:$WHY_FOLDER" "[M1] the folder's key everyday wins over a remote"
plain "$TMP/f2"; key "$TMP/f2" developer
eq "$(VIBEMAESTRO_PROFILE=everyday modeof "$TMP/f2")" developer "[M1] the folder's key developer wins over the person and the default"
plain "$TMP/f3"; key "$TMP/f3" weekend
O=$(start_cmd "$TMP/f3" 1)
has "$(sysm "$O")" ".vibemaestro/sdlc.json is invalid (profile)" "[M1] refusal: a value the key does not know is refused as invalid, naming the key (main: an unknown-key note)"
eq "$(modeof "$TMP/f3")" "everyday:$WHY_DEFAULT" "[M1] …and the choice goes on as if the key were not set"

echo "== [G] a git that fails inside a repository is developer, as before the mode existed =="
eq "$(GIT_TEST_ASSUME_DIFFERENT_OWNER=1 git -C "$TMP/g1" remote 2>&1 | grep -c 'dubious ownership')" 1 "instrument: git refuses the repository (dubious ownership)"
eq "$(GIT_TEST_ASSUME_DIFFERENT_OWNER=1 modeof "$TMP/g1")" developer "[G1] a repository with a remote that git refuses to read: developer"
eq "$(GIT_TEST_ASSUME_DIFFERENT_OWNER=1 VIBEMAESTRO_PROFILE=everyday modeof "$TMP/g1")" developer "[G1] …even with the person's everyday (the remote cannot be ruled out)"
plain "$TMP/dangle"; printf 'gitdir: %s/gone/.git/worktrees/x\n' "$TMP" > "$TMP/dangle/.git"
eq "$(modeof "$TMP/dangle")" developer "[G2] a dangling .git file: developer"
eq "$(modeof "$TMP/p1")" "everyday:$WHY_DEFAULT" "[G2] control: no .git anywhere above: everyday"

echo "== [W] a worker or coordinated session stays developer =="
O=$(VIBEMAESTRO_ROLE=worker start_cmd "$TMP/p1" 1)
has "$(ctx "$O")" "DONG-DAU-LOI-QUY-TRINH" "[W1] a worker in a plain folder gets the process core"
hasnt "$(sysm "$O")" "everyday mode, because" "[W1] …and no everyday line"
has "$(ctx "$(VIBEMAESTRO_ROLE=worker start_cmd "$TMP/p1" 2)")" "Sandbox session" "[W1] …and its sandbox first steps"
eq "$(VIBEMAESTRO_ROLE=worker VIBEMAESTRO_PROFILE=everyday modeof "$TMP/r1")" developer "[W1] the person's everyday does not move a worker"
eq "$(VIBEMAESTRO_ROLE=reader modeof "$TMP/p1")" "everyday:$WHY_DEFAULT" "[W1] refusal: another value of the role is no worker"
hasnt "$(ctx "$(VIBEMAESTRO_ROLE=worker sub "$TMP/p1")")" 'Keep a notebook in `kb/`' "[W2] a worker's subagent in a plain folder gets the developer subagent core"
has "$(VIBEMAESTRO_ROLE=worker hk "$TMP/p1" PreToolUse Edit "$(p_edit "$(sid)" "$TMP/p1/src/report.html")")" "r-all.instructions.md" \
    "[W2] a worker's edit in a plain folder is reminded of the plugin's rules"

echo "== [K] a mode key that is not a known string, or a broken config: refused, the choice goes on =="
plain "$TMP/k3"; mkdir -p "$TMP/k3/.vibemaestro"; printf '{"schema": 1, "profile": 1}\n' > "$TMP/k3/.vibemaestro/sdlc.json"
has "$(sysm "$(start_cmd "$TMP/k3" 1)")" ".vibemaestro/sdlc.json is invalid (profile)" "[K1] a number for the key: refused as invalid, naming the key"
eq "$(modeof "$TMP/k3")" "everyday:$WHY_DEFAULT" "[K1] …and the choice goes on as if the key were not set"
plain "$TMP/k4"; mkdir -p "$TMP/k4/.vibemaestro"; printf '{"schema": 1, "profile": "developer"' > "$TMP/k4/.vibemaestro/sdlc.json"
has "$(sysm "$(start_cmd "$TMP/k4" 1)")" ".vibemaestro/sdlc.json" "[K2] a config that does not parse: a warning that names the file"
eq "$(modeof "$TMP/k4")" "everyday:$WHY_DEFAULT" "[K2] …and the choice goes on with the defaults (its developer key is not read)"

echo "== [E] what an everyday session gets =="
O=$(start_cmd "$TMP/p1" 1)
eq "$(sysm "$O")" "" "[E1] the person sees no line at session start: nothing in a fixed language"
has "$(ctx "$O")" "vibemaestro-sdlc: everyday mode, because" "[E1] Claude's context carries the mode and why…"
has "$(ctx "$O")" 'for the developer flow, connect the folder to GitHub or set "profile": "developer"' "[E1] …and how to change it"
has "$(ctx "$O")" "The kit's lines in your context are for you, not the person" "[E1] …and tells Claude those lines are for it, to say in the person's language"
has "$(ctx "$O")" 'When `kb/` is missing, offer it once, at the first piece of work worth' "[E10] the core leads Claude to offer the notebook at the first work worth keeping"
has "$(ctx "$O")" '`kb/preferences.md`' "[E10] …and to keep the person's preferences in kb/preferences.md, not only in its own memory"
has "$(ctx "$O")" "only what the person said they like or asked you to remember, in their own words" "[E10] …only what the person said, in their words"
hasnt "$(ctx "$O")" "short plans" "[E10] …and no made-up example preference Claude could copy as the person's"
hasnt "$(ctx "$(start_cmd "$TMP/r1" 1)")" '`kb/preferences.md`' "[E10] control: a developer repository's context has none of it"
has "$(ctx "$O")" 'Keep a notebook in `kb/`' "[E1] the session gets the everyday core"
has "$(ctx "$O")" "Speak the person's language" "[E1] …which asks for the person's language, plainly"
hasnt "$(ctx "$O")" "DONG-DAU-LOI-QUY-TRINH" "[E1] …and not the developer process core"
has "$(ctx "$(start_cmd "$TMP/r1" 1)")" "DONG-DAU-LOI-QUY-TRINH" "[E1] control: a developer repository gets the process core"
eq "$(start_cmd "$TMP/p1" 2)" "" "[E2] the second session-start hook says nothing: no flow reminder, no rule catalogue"
has "$(ctx "$(start_cmd "$TMP/r1" 2)")" "PL-LUAT-MOI-FILE" "[E2] control: a developer repository gets the rule catalogue"
S=$(sub "$TMP/p1")
has "$(ctx "$S")" 'Keep a notebook in `kb/`' "[E3] a subagent gets the everyday core"
hasnt "$(sysm "$S")" "everyday mode, because" "[E3] …without the person's line"
hasnt "$(ctx "$(sub "$TMP/r1")")" 'Keep a notebook in `kb/`' "[E3] control: a developer subagent gets its own core"
E=$(hk "$TMP/p1" PreToolUse Edit "$(p_edit "$(sid)" "$TMP/p1/src/report.html")")
hasnt "$E" "r-all.instructions.md" "[E4] an edit is not reminded of the plugin's developer rules"
has "$(hk "$TMP/r1" PreToolUse Edit "$(p_edit "$(sid)" "$TMP/r1/src/app.js")")" "r-all.instructions.md" "[E4] control: in a developer repository it is"
dec_ "$TMP/p1" d-report.md 'src/**' 'QD-BAO-CAO'
DREP="kb/decisions/d-report.md"; [ "${OS:-}" = Windows_NT ] && DREP='kb\\decisions\\d-report.md'   # an absolute path in the system's form; hk gives raw JSON, so each \ is escaped
has "$(hk "$TMP/p1" PreToolUse Edit "$(p_edit "$(sid)" "$TMP/p1/src/report.html")")" "$DREP" "[E4] the folder's own decisions are still reminded"
hasnt "$(hk "$TMP/p1" PreToolUse Bash "$(p_bash "$(sid)" "lenh-bay now")")" "PL-LUAT-LENH-BAY" "[E5] a command is not reminded of the plugin's rules"
has "$(hk "$TMP/r1" PreToolUse Bash "$(p_bash "$(sid)" "lenh-bay now")")" "PL-LUAT-LENH-BAY" "[E5] control: in a developer repository it is"
mkdir -p "$TMP/p1/.vibemaestro/rules"
printf '{"schema": 1, "rules": {"dirs": [".vibemaestro/rules"]}}\n' > "$TMP/p1/.vibemaestro/sdlc.json"
printf -- '---\napplyWhen: "xoa-het"\nlevel: block\ndescription: "REPO-CHAN-XOA-HET"\n---\n\n# x\n' > "$TMP/p1/.vibemaestro/rules/r-xoa.instructions.md"
eq "$(denied "$(hk "$TMP/p1" PreToolUse Bash "$(p_bash "$(sid)" "xoa-het now")")")" 1 "[E5] the folder's own block rule still refuses its command"
eq "$(denied "$(hk "$TMP/p1" PreToolUse Bash "$(p_bash "$(sid)" "ls")")")" 0 "[E5] control: …and only its command"
W="{\"session_id\":\"$(sid)\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$TMP/p1/.claude/settings.json\",\"content\":\"{\\\"permissions\\\":{\\\"allow\\\":[\\\"Bash(curl:*)\\\"]}}\"}}"
eq "$(denied "$(hk "$TMP/p1" PreToolUse Write "$W")")" 1 "[E6] the settings guard still refuses an allow rule written into the settings"
# the plain folder of tests/test-khung-luong.sh, without the person's developer choice: the everyday prompt (owner decision 1)
PK="$TMP/plain-with-kb"; mkdir -p "$PK/kb"; printf '# map\n' > "$PK/kb/current-state.md"
O=$(start_cmd "$PK" 1)
has "$(ctx "$O")" "everyday mode, because $WHY_DEFAULT" "[E8] a plain folder with kb/ and no profile set gets the everyday line (in Claude's context)"
has "$(ctx "$O")" 'Keep a notebook in `kb/`' "[E8] …and the everyday core"
eq "$(start_cmd "$PK" 2)" "" "[E8] …and no developer kb pointer or rule catalogue"
has "$(ctx "$(VIBEMAESTRO_PROFILE=developer start_cmd "$PK" 2)")" 'This repo has a `kb/`' "[E8] control: with the person's developer choice, the kb pointer of today"
plain "$TMP/off"; mkdir -p "$TMP/off/.vibemaestro"; printf '{"schema": 1, "hooks": "off"}\n' > "$TMP/off/.vibemaestro/sdlc.json"
eq "$(start_cmd "$TMP/off" 1)$(start_cmd "$TMP/off" 2)" "" "[E7] hooks: off keeps an everyday folder silent too"
# the advice follows why the mode holds: with the folder's key everyday, connecting GitHub changes nothing
O=$(start_cmd "$TMP/f1" 1)
has "$(ctx "$O")" 'because this folder'"'"'s .vibemaestro/sdlc.json sets "profile": "everyday"; for the developer flow, set "profile": "developer" in .vibemaestro/sdlc.json.' "[E9] the folder's key: the line says to change the key"
hasnt "$(ctx "$O")" "connect the folder to GitHub" "[E9] …and not to connect GitHub"
has "$(ctx "$(VIBEMAESTRO_PROFILE=everyday start_cmd "$TMP/r1" 1)")" "or set VIBEMAESTRO_PROFILE=developer" "[E9] the person's choice: the line names the setting"
C=$(hk "$TMP/p1" SessionStart "" '{"session_id":"sE10","hook_event_name":"SessionStart","source":"compact"}')
has "$C" 'Keep a notebook in' "[E10] after a compaction the everyday core comes again"
hasnt "$C" "DONG-DAU-LOI-QUY-TRINH" "[E10] …and not the developer core"
summary
