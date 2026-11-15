#!/bin/bash
# =============================================================================
# The Python finder of the hooks (scripts/pyrun.sh in vibemaestro-sdlc and vibemaestro-brain): no hook fails only because Python is
# missing, the session gets one plain line that says what is missing, and where Python is found the hook runs exactly as before.
# Run: bash tests/test-pyrun.sh
# Each case runs the `command` strings of hooks/hooks.json through `bash -c`, as Claude Code does, with a PATH built for the case
# (a directory of links to the tools it may have). "Windows" is OS=Windows_NT, which Windows sets for every process; the
# Python shortcut of the Microsoft Store is stood in for by a `python3` that runs nothing and exits 9009, as the shortcut does.
# Not run here: a real Windows machine (Git Bash, the real shortcut, the real `py` launcher).
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
export VIBEMAESTRO_NO_UPDATE_CHECK=1
export PYTHONDONTWRITEBYTECODE=1               # the hooks run from the repository's own plugin directories: no __pycache__ there
SDLC="$SRC_ROOT/plugins/vibemaestro-sdlc"; BRAIN="$SRC_ROOT/plugins/vibemaestro-brain"
SH="$SDLC/hooks/hooks.json"; BH="$BRAIN/hooks/hooks.json"
PY=$(command -v python3); GIT=$(command -v git)
APP="$TMP/app"; mk_app "$APP"

# bindir <name> <tool>… — a directory holding links to the named tools of this machine (and nothing else)
bindir() {
  local d="$TMP/bin-$1" t; shift
  mkdir -p "$d"
  for t in bash sh "$@"; do
    if [ "${OS:-}" = Windows_NT ]; then   # Git Bash's ln -s copies a program without the DLLs it needs: a stand-in that runs it
      printf '#!/bin/sh\nexec "%s" "$@"\n' "$(command -v "$t")" > "$d/$t"; chmod +x "$d/$t"
    else ln -sf "$(command -v "$t")" "$d/$t"; fi
  done
  printf '%s' "$d"
}
fake() {  # fake <dir> <name> <body> — a stand-in program in that directory
  printf '#!%s\n%s\n' "$(command -v sh)" "$3" > "$1/$2"; chmod +x "$1/$2"
}

# hooks <hooks.json> <plugin root> <event> <tool> <payload> — each command's "rc=<n>" and stdout, one block per command; the
# command runs with the case's PATH (CASE_PATH) and OS (CASE_OS), the reading of hooks.json with this machine's
hooks() {
  local c out rc
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    out=$(cd "$APP" && printf '%s' "$5" | env PATH="${CASE_PATH:-$PATH}" ${CASE_OS:+OS=$CASE_OS} CLAUDE_PLUGIN_ROOT="$2" CLAUDE_PROJECT_DIR="$APP" \
          "$(command -v bash)" -c "$c" 2>/dev/null); rc=$?
    printf 'rc=%d\n%s\n' "$rc" "$out"
  done < <(hook_cmds "$1" "$3" "$4")
}
START='{"session_id":"sP1","hook_event_name":"SessionStart","source":"startup"}'
EDIT="{\"session_id\":\"sP1\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$APP/src/main.ts\"}}"
BASH_IN='{"session_id":"sP1","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status"}}'
GUARD="{\"session_id\":\"sP1\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$APP/.claude/settings.json\",\"content\":\"{\\\"permissions\\\":{\\\"allow\\\":[\\\"Bash(curl:*)\\\"]}}\"}}"
everything() {  # every hook of both plugins on a session start, an edit and a command
  hooks "$SH" "$SDLC" SessionStart "" "$START"; hooks "$BH" "$BRAIN" SessionStart "" "$START"
  hooks "$SH" "$SDLC" PreToolUse Edit "$EDIT"; hooks "$BH" "$BRAIN" PreToolUse Edit "$EDIT"
  hooks "$SH" "$SDLC" PreToolUse Bash "$BASH_IN"; hooks "$BH" "$BRAIN" PreToolUse Bash "$BASH_IN"
  hooks "$BH" "$BRAIN" UserPromptSubmit "" '{"session_id":"sP1","hook_event_name":"UserPromptSubmit","prompt":"hi"}'
  hooks "$SH" "$SDLC" SubagentStart general-purpose '{"session_id":"sP1","hook_event_name":"SubagentStart","agent_type":"general-purpose"}'
  hooks "$BH" "$BRAIN" PreCompact "" '{"session_id":"sP1","hook_event_name":"PreCompact","trigger":"auto"}'
  hooks "$BH" "$BRAIN" PostCompact "" '{"session_id":"sP1","hook_event_name":"PostCompact","trigger":"auto"}'
  hooks "$BH" "$BRAIN" SessionEnd "" '{"session_id":"sP1","hook_event_name":"SessionEnd","reason":"exit"}'
}
lines() { printf '%s\n' "$1" | grep -v '^rc=' | grep -c .; }

echo "== [P0] instrument =="
NOPY=$(bindir nopy git)
eq "$(PATH="$NOPY" bash -c 'command -v python3 python py' | grep -c .)" 0 "instrument: the case PATH has no python3, python or py"
eq "$(PATH="$NOPY" bash -c 'command -v git' | grep -c .)" 1 "instrument: …and has git"
eq "$(cmp -s "$SDLC/scripts/pyrun.sh" "$BRAIN/scripts/pyrun.sh" && echo same)" same "[P0] the finder is the same file in both plugins"

echo "== [P1] no Python: no hook fails, one line per session start =="
OUT=$(CASE_PATH="$NOPY" everything)
eq "$(printf '%s\n' "$OUT" | grep '^rc=' | sort -u | tr '\n' ' ')" "rc=0 " "[P1] every hook of both plugins exits 0 (main: 127)"
eq "$(printf '%s\n' "$OUT" | grep -c '^rc=')" 34 "instrument: all 34 commands ran (session start 4 + 15, edit 2 + 1, command 3 + 4, prompt, subagent, pre- and post-compact, session end)"
eq "$(lines "$OUT")" 1 "[P1] the session gets exactly one line, not one per hook"
# a compaction drops what the session was told, so the line comes again on that start, once
eq "$(lines "$(CASE_PATH="$NOPY" hooks "$SH" "$SDLC" SessionStart "" '{"session_id":"sP1","hook_event_name":"SessionStart","source":"compact"}'; CASE_PATH="$NOPY" hooks "$BH" "$BRAIN" SessionStart "" '{"session_id":"sP1","hook_event_name":"SessionStart","source":"compact"}')")" 1 \
   "[P1] after a compaction, one line again"
L=$(printf '%s\n' "$OUT" | grep -v '^rc=' | grep .)
isjson "$L" && ok "[P1] the line is the hook JSON Claude Code reads" || bad "[P1] the line is not JSON: ${L:0:120}"
has "$(sysm "$L")" "no Python 3.8 or newer, so the kit is not running" "[P1] the person reads what is missing and that the kit is paused"
has "$(sysm "$L")" "nothing is blocked" "[P1] …and that nothing is blocked"
has "$(ctx "$L")" "the way to install it that fits this machine best" "[P1] Claude is asked to propose the install for this machine, not fixed steps"
hasnt "$(sysm "$L")" "no Git" "[P1] Git is there: the line does not name it"
eq "$(CASE_PATH="$NOPY" hooks "$SH" "$SDLC" PreToolUse Write "$GUARD")" "$(printf 'rc=0\n\nrc=0\n')" "[P1] an edit is let through, silently, when no guard can run"

echo "== [P2] neither Python nor Git =="
BARE=$(bindir bare)
L=$(CASE_PATH="$BARE" hooks "$SH" "$SDLC" SessionStart "" "$START" | grep -v '^rc=' | grep .)
has "$(sysm "$L")" "no Python 3.8 or newer and no Git" "[P2] the one line names both"

echo "== [P7] Windows: a hook's output is UTF-8 whatever the system code page =="
# Windows writes a pipe in the system code page (cp1252 on most machines); PYTHONIOENCODING=cp1252 stands in for it here, and on a
# real Windows run the machine's own page is the test. A message holding a character the page lacks (the process core's arrow, a
# Vietnamese rule) was dropped whole: rc 0, nothing printed, so the core was lost and a block rule's deny with it (main: both lost).
eq "$(PYTHONIOENCODING=cp1252 "$PY" -c 'print("→")' >/dev/null 2>&1; echo $?)" 1 "instrument: under the stand-in, a Python that prints an arrow fails"
VR="$TMP/vrules"; mk_app "$VR"; mkdir -p "$VR/.vibemaestro/rules"
printf '{"schema": 1, "rules": {"dirs": [".vibemaestro/rules"]}}\n' > "$VR/.vibemaestro/sdlc.json"
printf -- '---\napplyWhen: "xoa-het"\nlevel: block\ndescription: "Luật chặn: không được xoá hết dữ liệu"\n---\n\n# Không xoá hết\n\nLệnh xoá hết bị chặn.\n' \
  > "$VR/.vibemaestro/rules/chan-xoa.instructions.md"
XOA='{"session_id":"sP7","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"xoa-het --now"}}'
denies() { printf '%s' "$1" | grep -c '"permissionDecision": "deny"'; }
w1252() { (export PYTHONIOENCODING="$1"; shift; APP="$VR" CASE_OS=Windows_NT hooks "$@"); }   # w1252 <encoding> <hooks args…>
O=$(w1252 cp1252 "$SH" "$SDLC" SessionStart "" "$START" | sed -n 2p)
has "$(ctx "$O")" "The general way of working" "[P7] the process core (it holds an arrow) reaches a developer session in full"
O=$(w1252 cp1252 "$SH" "$SDLC" PreToolUse Bash "$XOA")
eq "$(denies "$O")" 1 "[P7] a block rule written in Vietnamese still blocks: the deny is not dropped (a lost deny lets the command run)"
has "$(printf '%s\n' "$O" | grep -F '"deny"' | while IFS= read -r l; do why "$l"; done)" "Luật chặn: không được xoá hết dữ liệu" "[P7] …and the reason names the rule in its own words"
eq "$(denies "$(w1252 cp1258 "$SH" "$SDLC" PreToolUse Bash "$XOA")")" 1 "[P7] a PYTHONIOENCODING the person set (cp1258) does not drop it either"
XOA_VI='{"session_id":"sP7v","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"xoa-het thư mục Báo cáo"}}'
eq "$(denies "$(w1252 cp1252 "$SH" "$SDLC" PreToolUse Bash "$XOA_VI")")" 1 "[P7] a command with Vietnamese words is read whole and still blocked (cp1252 could not read the payload: no deny)"
eq "$(cd "$VR" && PYTHONIOENCODING=cp1252 "$PY" "$SDLC/scripts/sdlc_config.py" get tokens.spec.placeholder | tr -d '\r'; echo "rc=${PIPESTATUS[0]}")" "$(printf '<ĐIỀN\nrc=0')" \
   "[P7] a script Claude runs directly (sdlc_config.py) prints Vietnamese under the system code page (main: a traceback)"

if [ "${OS:-}" = Windows_NT ]; then
  echo "  SKIP [P3]-[P6]: they swap Python and Git for stand-ins on a PATH of links, read the execute bit and compare argv paths, none of"
  echo "       which Windows has; tests/test-windows-everyday.sh [H] runs the finder there with no Python and with only py"
  summary; exit
fi

echo "== [P3] Linux with Python: the finder is the python3 of before =="
# the finder runs a script of the plugin it sits in: the real finder, as an installed copy whose modes were dropped (no execute
# bit), in a stand-in plugin with a probe script
K="$TMP/kit"; mkdir -p "$K/scripts"; cp "$SDLC/scripts/pyrun.sh" "$K/scripts/pyrun.sh"; chmod 644 "$K/scripts/pyrun.sh"
printf 'import sys\nprint(repr(sys.argv), repr(sys.stdin.read()))\nsys.exit(3)\n' > "$K/scripts/probe.py"
eq "$([ -x "$K/scripts/pyrun.sh" ] && echo exec || echo noexec)" noexec "instrument: the stand-in finder has no execute bit"
eq "$(printf 'in put' | /bin/sh "$K/scripts/pyrun.sh" scripts/probe.py 'a b' --say; echo "rc=$?")" "$(printf "['$K/scripts/probe.py', 'a b', '--say'] 'in put'\nrc=3")" "[P3] the script path, its arguments, stdin, stdout and the exit code pass through, with no execute bit"
eq "$(printf '' | /bin/sh "$K/scripts/pyrun.sh" --say scripts/probe.py x; echo "rc=$?")" "$(printf "['$K/scripts/probe.py', 'x'] ''\nrc=3")" "[P3] a leading --say is the finder's own flag, never the script's"
NOSH="$TMP/bin-nosh"; mkdir -p "$NOSH"; ln -s "$PY" "$NOSH/python3"   # python3 alone: no sh, no bash on this PATH
eq "$(PATH="$NOSH" "$(command -v bash)" -c 'command -v sh bash' | grep -c .)" 0 "instrument: that PATH has no sh and no bash"
eq "$(printf '' | env PATH="$NOSH" "$(command -v bash)" -c "/bin/sh \"$K/scripts/pyrun.sh\" scripts/probe.py"; echo "rc=$?")" "$(printf "['$K/scripts/probe.py'] ''\nrc=3")" "[P3] through /bin/sh it needs no sh on PATH"
WIDE=$(bindir wide python3 git ps)
D1=$(CASE_PATH="$WIDE" hooks "$SH" "$SDLC" PreToolUse Write "$GUARD")
has "$D1" '"permissionDecision": "deny"' "[P3] the settings guard still refuses an allow rule written into the settings"
# Each command of both files against the `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/<script>" <args>` it stands for, on the same
# payloads, each form with a state and temp directory of its own (a hook's once-per-session marks would hide the second run's reminder).
old_form() { sed -E 's#^/bin/sh "\$\{CLAUDE_PLUGIN_ROOT\}/scripts/pyrun\.sh" (--say )?"scripts/([^"]+)"#python3 "${CLAUDE_PLUGIN_ROOT}/scripts/\2"#'; }
SHAPE='^/bin/sh "\$\{CLAUDE_PLUGIN_ROOT\}/scripts/pyrun\.sh" (--say )?"scripts/[a-z_-]+\.py"( [a-z0-9-]+)?$'
ALL=$(python3 -c 'import json, sys
for f in sys.argv[1:]:
    for blocks in json.load(open(f))["hooks"].values():
        for b in blocks:
            for h in b["hooks"]: print(f + "\t" + h["command"])' "$SH" "$BH")
eq "$(printf '%s\n' "$ALL" | cut -f2 | grep -cE "$SHAPE")" 34 "[P3] all 34 commands (sdlc 10, brain 24) have the finder's shape"
eq "$(printf '%s\n' "$ALL" | cut -f2 | old_form | grep -c '^python3 "${CLAUDE_PLUGIN_ROOT}/scripts/')" 34 "instrument: each turns back into its python3 form"
same=0 differ=""
for in in "$START" "$EDIT" "$BASH_IN" "$GUARD" '{"session_id":"sP2","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"brain owner pin --text x"}}' 'not json'; do
  while IFS=$'\t' read -r f c; do
    root=$SDLC; [ "$f" = "$BH" ] && root=$BRAIN
    o=$(printf '%s' "$c" | old_form)
    a=$(cd "$APP" && printf '%s' "$in" | XDG_STATE_HOME="$TMP/st-new" TMPDIR="$TMP/st-new" CLAUDE_PLUGIN_ROOT="$root" CLAUDE_PROJECT_DIR="$APP" bash -c "$c" 2>&1; echo "rc=$?")
    b=$(cd "$APP" && printf '%s' "$in" | XDG_STATE_HOME="$TMP/st-old" TMPDIR="$TMP/st-old" CLAUDE_PLUGIN_ROOT="$root" CLAUDE_PROJECT_DIR="$APP" bash -c "$o" 2>&1; echo "rc=$?")
    [ "${a//st-new/st}" = "${b//st-old/st}" ] && same=$((same+1)) || differ="$differ | $c on ${in:0:60}"   # a path may name the state dir
  done <<< "$ALL"
done
eq "$same" 204 "[P3] all 204 runs (34 commands × 6 payloads) print the same stdout and stderr, with the same exit code, as their python3 form${differ:+ (differ:$differ)}"

echo "== [P4] Windows: a Store shortcut is skipped, python and py -3 are found =="
WIN=$(bindir win git ps)
fake "$WIN" python3 'exit 9009'
fake "$WIN" python "exec \"$PY\" \"\$@\""
W1=$(CASE_OS=Windows_NT CASE_PATH="$WIN" hooks "$SH" "$SDLC" PreToolUse Write "$GUARD")
eq "$W1" "$D1" "[P4] behind a dead python3 shortcut, python runs the guard: the same refusal as on Linux"
L1=$(CASE_PATH="$WIDE" hooks "$SH" "$SDLC" SessionStart "" "$START" | sed -n 2p)
W2=$(CASE_OS=Windows_NT CASE_PATH="$WIN" hooks "$SH" "$SDLC" SessionStart "" "$START" | sed -n 2p)
has "$(ctx "$W2")" "The general way of working" "[P4] the core hook delivers the process core through python"
eq "$(ctx "$W2")" "$(ctx "$L1")" "[P4] …the same core as on Linux"
PYL=$(bindir pyl git ps)
fake "$PYL" python3 'exit 9009'
fake "$PYL" py "[ \"\$1\" = -3 ] || exit 9; shift; exec \"$PY\" \"\$@\""
W3=$(CASE_OS=Windows_NT CASE_PATH="$PYL" hooks "$SH" "$SDLC" PreToolUse Write "$GUARD")
eq "$W3" "$D1" "[P4] with only the py launcher, py -3 runs the guard"
OLD=$(bindir old git)
fake "$OLD" python "case \"\$*\" in *version_info*) exit 1;; esac; echo RAN-OLD-PYTHON"
W4=$(CASE_OS=Windows_NT CASE_PATH="$OLD" hooks "$SH" "$SDLC" SessionStart "" "$START")
hasnt "$W4" "RAN-OLD-PYTHON" "[P4] a Python older than 3.8 is not used"
has "$(sysm "$(printf '%s\n' "$W4" | sed -n 2p)")" "no Python 3.8 or newer" "[P4] …and the session hears that no usable Python was found"
eq "$(printf '%s\n' "$W4" | grep '^rc=' | sort -u | tr '\n' ' ')" "rc=0 " "[P4] …with every hook at rc 0"

echo "== [P6] Linux without python3: python is used when it is 3.8+ =="
ONLYPY=$(bindir onlypy git ps)
fake "$ONLYPY" python "exec \"$PY\" \"\$@\""
eq "$(CASE_PATH="$ONLYPY" hooks "$SH" "$SDLC" PreToolUse Write "$GUARD")" "$D1" "[P6] with only python on PATH, it runs the guard: the same refusal (main: 127)"
PY2=$(bindir py2 git)
fake "$PY2" python "case \"\$*\" in *version_info*) exit 1;; esac; echo RAN-PYTHON-2"
P6=$(CASE_PATH="$PY2" hooks "$SH" "$SDLC" SessionStart "" "$START")
hasnt "$P6" "RAN-PYTHON-2" "[P6] a python older than 3.8 is not used"
has "$(sysm "$(printf '%s\n' "$P6" | sed -n 2p)")" "no Python 3.8 or newer" "[P6] …and the session hears that no usable Python was found"

echo "== [P5] Python but no Git: the core hook says so, once =="
NOGIT=$(bindir nogit python3 ps)
G=$(CASE_PATH="$NOGIT" hooks "$SH" "$SDLC" SessionStart "" "$START")
has "$(sysm "$(printf '%s\n' "$G" | sed -n 2p)")" "this machine has no Git" "[P5] the core hook names the missing Git (main: no word of it)"
has "$(ctx "$(printf '%s\n' "$G" | sed -n 2p)")" "the way to install it that fits this machine best" "[P5] …and asks Claude to propose the install for this machine"
eq "$(printf '%s\n' "$G" | grep -c 'this machine has no Git')" 1 "[P5] only the core hook says it, not the other session-start hooks"
hasnt "$(sysm "$(CASE_PATH="$WIDE" hooks "$SH" "$SDLC" SessionStart "" "$START" | sed -n 2p)")" "no Git" "[P5] with Git there, no word of it"

summary
