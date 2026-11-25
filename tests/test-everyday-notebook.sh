#!/bin/bash
# =============================================================================
# The notebook of the everyday mode (vibemaestro-sdlc scripts/notebook_nudge.py, the second Stop hook, and templates/everyday-core.md):
# a session that changed files and left kb/current-state.md alone is asked once, at the end of the turn, to overwrite it.
# Run: bash tests/test-everyday-notebook.sh
# The hook runs as Claude Code runs it (the `command` of hooks/hooks.json, stdin = the Stop payload), on the real plugin with a scratch
# HOME. File times are set with touch -d, never by waiting, except where one turn must follow another (a short sleep).
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
PL="$SRC_ROOT/plugins/vibemaestro-sdlc"
HOOKS="$PL/hooks/hooks.json"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
export VIBEMAESTRO_NO_UPDATE_CHECK=1 PYTHONDONTWRITEBYTECODE=1
baton_set_mode "$XDG_STATE_HOME" manual
unset VIBEMAESTRO_PROFILE GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

OLD="2022-01-01 00:00:00"; TS_OLD="2023-06-01T00:00:00.000Z"        # a work file older than the turn's start (the transcript's first line)
NEW="2024-06-01 00:00:00"
NUDGE=$(hook_cmds "$HOOKS" Stop "" | grep -F notebook_nudge.py | head -n 1)
SAVE=$(hook_cmds "$HOOKS" Stop "" | grep -F quiet_save.py | head -n 1)

transcript() { printf '{"type":"user","timestamp":"%s"}\n' "$2" > "$1"; }          # transcript <file> <iso time>
run() {  # run <dir> <session> <transcript> <active true|false> [env…] — the nudge hook for a Stop in <dir>; stdout, then rc=<n>
  local d=$1 s=$2 t=$3 a=$4 out rc; shift 4
  out=$(cd "$d" && printf '{"session_id":"%s","hook_event_name":"Stop","cwd":"%s","transcript_path":"%s","stop_hook_active":%s}' "$s" "$d" "$t" "$a" \
        | env "$@" CLAUDE_PLUGIN_ROOT="$PL" CLAUDE_PROJECT_DIR="$d" bash -c "$NUDGE" 2>&1); rc=$?
  printf '%s\nrc=%d' "$out" "$rc"
}
reason() { printf '%s' "$1" | python3 -c 'import json,sys
d = json.loads(sys.stdin.read().rsplit("\nrc=", 1)[0]); print(d["decision"] + "|" + d["reason"])'; }
NONE=$(printf '\nrc=0')
# folder <dir> — an everyday notebook as the kit starts it: kb/ with an empty current-state, one work file older than the turn
folder() { mkdir -p "$1/kb"; : > "$1/kb/current-state.md"; : > "$1/kb/preferences.md"; printf 'x\n' > "$1/report.html"
           touch -d "$OLD" "$1/report.html" "$1/kb/current-state.md" "$1/kb/preferences.md"; }
sess() { printf 'n%s\n' "$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n')"; }

echo "== [N] one nudge when files changed and current-state did not =="
folder "$TMP/a"; transcript "$TMP/a.jsonl" "$TS_OLD"
S=$(sess); touch -d "$NEW" "$TMP/a/report.html"
O=$(run "$TMP/a" "$S" "$TMP/a.jsonl" false)
has "$O" '"decision": "block"' "[N1] a plain folder (no git) with kb/, a file changed in the turn, the map untouched: a block"
has "$(reason "$O")" "kb/current-state.md" "[N1] …it names kb/current-state.md"
has "$(reason "$O")" "kb/decisions/" "[N1] …a decisions file only when a choice was made"
has "$(reason "$O")" "kb/preferences.md" "[N1] …and the preferences file"
has "$O" "rc=0" "[N1] …exit 0"
folder "$TMP/en"; mkdir -p "$TMP/en/.vibemaestro"; printf '{"schema": 1, "language": "en"}\n' > "$TMP/en/.vibemaestro/sdlc.json"; touch -d "$NEW" "$TMP/en/report.html"
O=$(run "$TMP/en" "$(sess)" "$TMP/a.jsonl" false)
has "$(reason "$O")" "overwrite kb/current-state.md with where the work stands now" "[N2] language en: the reminder is in English"
has "$(reason "$O")" "present state only, short, no diary" "[N2] …and says the shape"
hasnt "$(reason "$O")" "ghi đè" "[N2] …and not in Vietnamese"
sed -i 's/"en"/"vi"/' "$TMP/en/.vibemaestro/sdlc.json"
has "$(reason "$(run "$TMP/en" "$(sess)" "$TMP/a.jsonl" false)")" "ghi đè kb/current-state.md" "[N2] language vi: the reminder is in Vietnamese"
has "$(reason "$O")" "block|" "[N2] the decision is block"
has "$(reason "$(run "$TMP/a" "$(sess)" "$TMP/a.jsonl" false)")" "ghi đè kb/current-state.md" "[N2] no language set: Vietnamese, like the rest of the kit"

echo "== [Q] nothing extra when there is nothing to say =="
folder "$TMP/q1"
eq "$(run "$TMP/q1" "$(sess)" "$TMP/a.jsonl" false)" "$NONE" "[Q1] a turn that changed no file: nothing, exit 0"
folder "$TMP/q2"; touch -d "$NEW" "$TMP/q2/report.html" "$TMP/q2/kb/current-state.md"; printf 'Dang lam bao cao.\n' > "$TMP/q2/kb/current-state.md"; touch -d "$NEW" "$TMP/q2/kb/current-state.md"
eq "$(run "$TMP/q2" "$(sess)" "$TMP/a.jsonl" false)" "$NONE" "[Q2] files changed and current-state updated in the same turn: nothing"
folder "$TMP/q3"; touch -d "$NEW" "$TMP/q3/report.html" "$TMP/q3/kb/current-state.md"
has "$(run "$TMP/q3" "$(sess)" "$TMP/a.jsonl" false)" '"decision": "block"' "[Q3] refusal: current-state touched but left empty is not an update: a block"
mkdir -p "$TMP/q4"; printf 'x\n' > "$TMP/q4/report.html"; touch -d "$NEW" "$TMP/q4/report.html"
eq "$(run "$TMP/q4" "$(sess)" "$TMP/a.jsonl" false)" "$NONE" "[Q4] a folder with no kb/ (the notebook offer is another hook's): nothing"
folder "$TMP/q5"; touch -d "$NEW" "$TMP/q5/report.html"
eq "$(run "$TMP/q5" "$(sess)" "$TMP/a.jsonl" true)" "$NONE" "[Q5] a Stop that follows the hook's own block (stop_hook_active): nothing"
folder "$TMP/q6"; git_ -C "$TMP/q6" init -q -b main; git_ -C "$TMP/q6" config --local vibemaestro.quietsave true   # the kit's own history
mkdir -p "$TMP/q6/kb/decisions" "$TMP/q6/node_modules" "$TMP/q6/ban-cu" "$TMP/q6/inner/.git" "$TMP/q6/inner/sub"
printf 'x\n' > "$TMP/q6/ban-cu/DAY-LA-BAN-CU.txt"; touch -d "$OLD" "$TMP/q6/ban-cu/DAY-LA-BAN-CU.txt"      # the kit's marker: its old copies
for f in kb/decisions/x.md .git/HEAD node_modules/m.js ban-cu/old.txt inner/sub/f.txt; do printf 'x\n' > "$TMP/q6/$f"; touch -d "$NEW" "$TMP/q6/$f"; done
eq "$(run "$TMP/q6" "$(sess)" "$TMP/a.jsonl" false)" "$NONE" "[Q6] only the notebook, the history, bulky folders, the kit's old copies and an inner repository changed: nothing"
mkdir -p "$TMP/q6/ban-cu-2"; printf 'x\n' > "$TMP/q6/ban-cu-2/mine.txt"; touch -d "$NEW" "$TMP/q6/ban-cu-2/mine.txt"
has "$(run "$TMP/q6" "$(sess)" "$TMP/a.jsonl" false)" '"decision": "block"' "[Q6] a folder named ban-cu-2 without the kit's marker is the person's own work: seen"
printf 'x\n' > "$TMP/q6/ban-cu-2/DAY-LA-BAN-CU.txt"; rm -rf "$TMP/q6/ban-cu-2/mine.txt"; touch -d "$NEW" "$TMP/q6/ban-cu-2/DAY-LA-BAN-CU.txt"
eq "$(run "$TMP/q6" "$(sess)" "$TMP/a.jsonl" false)" "$NONE" "[Q6] …and with the marker it is the kit's old copies: not seen"
mkdir -p "$TMP/q6/data"; printf 'x\n' > "$TMP/q6/data/t.csv"; touch -d "$NEW" "$TMP/q6/data/t.csv"
has "$(run "$TMP/q6" "$(sess)" "$TMP/a.jsonl" false)" '"decision": "block"' "[Q6] control: a changed file in a subfolder of the work is seen"
folder "$TMP/q7"; printf 'x\n' > "$TMP/q7/venv"; touch -d "$NEW" "$TMP/q7/venv"
has "$(run "$TMP/q7" "$(sess)" "$TMP/a.jsonl" false)" '"decision": "block"' "[Q7] a file (not a folder) named venv is the person's work: seen"
folder "$TMP/q8"; printf 'x\n' > "$TMP/q8/photo.jpg"; touch -d "now + 6 hours" "$TMP/q8/photo.jpg"
eq "$(run "$TMP/q8" "$(sess)" "$TMP/a.jsonl" false)" "$NONE" "[Q8] a file dated in the future (a clock, a zip) is not this turn's work: nothing"

echo "== [D] developer mode and coordinated sessions get nothing =="
folder "$TMP/d1"; touch -d "$NEW" "$TMP/d1/report.html"; mkdir -p "$TMP/d1/.vibemaestro"; printf '{"schema": 1, "profile": "developer"}\n' > "$TMP/d1/.vibemaestro/sdlc.json"
eq "$(run "$TMP/d1" "$(sess)" "$TMP/a.jsonl" false)" "$NONE" "[D1] a folder whose profile is developer: nothing"
folder "$TMP/d2"; touch -d "$NEW" "$TMP/d2/report.html"; git_ -C "$TMP/d2" init -q -b main; git_ -C "$TMP/d2" config --local vibemaestro.quietsave true; git_ -C "$TMP/d2" remote add origin "$TMP/d2.git"
eq "$(run "$TMP/d2" "$(sess)" "$TMP/a.jsonl" false)" "$NONE" "[D2] a repository the kit made that has a remote (the remote alone makes it developer): nothing"
folder "$TMP/d2b"; touch -d "$NEW" "$TMP/d2b/report.html"; git_ -C "$TMP/d2b" init -q -b main; git_ -C "$TMP/d2b" config --local vibemaestro.quietsave true
has "$(run "$TMP/d2b" "$(sess)" "$TMP/a.jsonl" false)" '"decision": "block"' "[D2] control: the same kit-made repository with no remote is nudged"
folder "$TMP/d3"; touch -d "$NEW" "$TMP/d3/report.html"
eq "$(run "$TMP/d3" "$(sess)" "$TMP/a.jsonl" false VIBEMAESTRO_ROLE=worker)" "$NONE" "[D3] a coordinated (worker) session in an everyday folder: nothing"
has "$(run "$TMP/d3" "$(sess)" "$TMP/a.jsonl" false)" '"decision": "block"' "[D3] control: the same folder in an ordinary session: a block"
folder "$TMP/d4"; touch -d "$NEW" "$TMP/d4/report.html"; mkdir -p "$TMP/d4/.vibemaestro"; printf '{"schema": 1, "hooks": "off"}\n' > "$TMP/d4/.vibemaestro/sdlc.json"
eq "$(run "$TMP/d4" "$(sess)" "$TMP/a.jsonl" false)" "$NONE" "[D4] hooks: off: nothing"

echo "== [L] never a loop: one nudge per piece of work =="
folder "$TMP/l"; S=$(sess); touch -d "$NEW" "$TMP/l/report.html"
has "$(run "$TMP/l" "$S" "$TMP/a.jsonl" false)" '"decision": "block"' "[L1] the first turn: a block"
eq "$(run "$TMP/l" "$S" "$TMP/a.jsonl" true)" "$NONE" "[L2] the Stop after that block: nothing"
sleep 0.1; printf 'more\n' >> "$TMP/l/report.html"
eq "$(run "$TMP/l" "$S" "$TMP/a.jsonl" false)" "$NONE" "[L3] a nudge that was ignored does not come back: the next turn changes a file, nothing"
sleep 0.1; printf 'Dang lam bao cao.\n' > "$TMP/l/kb/current-state.md"
eq "$(run "$TMP/l" "$S" "$TMP/a.jsonl" false)" "$NONE" "[L4] the session updated the map: nothing, and that is the end of the piece of work"
sleep 0.1; printf 'again\n' >> "$TMP/l/report.html"
has "$(run "$TMP/l" "$S" "$TMP/a.jsonl" false)" '"decision": "block"' "[L5] new work after an update is nudged again"
sleep 0.1; printf 'again\n' >> "$TMP/l/report.html"
eq "$(run "$TMP/l" "$S" "$TMP/a.jsonl" false)" "$NONE" "[L5] …and only once"
folder "$TMP/l4"; S=$(sess); touch -d "now + 6 hours" "$TMP/l4/photo.jpg" 2>/dev/null || { printf 'x\n' > "$TMP/l4/photo.jpg"; touch -d "now + 6 hours" "$TMP/l4/photo.jpg"; }
touch -d "$NEW" "$TMP/l4/report.html"
has "$(run "$TMP/l4" "$S" "$TMP/a.jsonl" false)" '"decision": "block"' "[L8] a folder holding a file dated in the future: the first turn is nudged"
sleep 0.1; printf 'Dang lam bao cao.\n' > "$TMP/l4/kb/current-state.md"
eq "$(run "$TMP/l4" "$S" "$TMP/a.jsonl" true)" "$NONE" "[L8] the session obeyed (the Stop after the block)"
eq "$(run "$TMP/l4" "$S" "$TMP/a.jsonl" false)" "$NONE" "[L8] a later turn that changed nothing is not nudged again, whatever the future file says"
folder "$TMP/l5"; S=$(sess); printf 'x\n' > "$TMP/l5/zip.txt"; touch -d "now + 3 seconds" "$TMP/l5/zip.txt"; touch -d "$NEW" "$TMP/l5/report.html"
has "$(run "$TMP/l5" "$S" "$TMP/a.jsonl" false)" '"decision": "block"' "[L9] a file dated 3 s ahead (a zip from another time zone), the first turn: nudged for the report"
printf 'Dang lam bao cao.\n' > "$TMP/l5/kb/current-state.md"
eq "$(run "$TMP/l5" "$S" "$TMP/a.jsonl" true)" "$NONE" "[L9] the session obeyed"
sleep 3.5
eq "$(run "$TMP/l5" "$S" "$TMP/a.jsonl" false)" "$NONE" "[L9] the clock passes the file's date in a turn that changed nothing: not nudged"
folder "$TMP/l6"; S=$(sess); touch -d "$NEW" "$TMP/l6/report.html"; touch -d "now + 6 hours" "$TMP/l6/kb/current-state.md"; printf 'Dang lam.\n' > "$TMP/l6/kb/current-state.md"; touch -d "now + 6 hours" "$TMP/l6/kb/current-state.md"
has "$(run "$TMP/l6" "$S" "$TMP/a.jsonl" false)" '"decision": "block"' "[L10] a current-state dated in the future is no proof that it was updated in the turn: nudged"
folder "$TMP/l2"; S=$(sess); touch -d "$NEW" "$TMP/l2/report.html"
eq "$(run "$TMP/l2" "$S" "$TMP/none.jsonl" false)" "$NONE" "[L6] no transcript and no earlier stamp: only a stamp, nothing said"
sleep 0.1; printf 'more\n' >> "$TMP/l2/report.html"
has "$(run "$TMP/l2" "$S" "$TMP/none.jsonl" false)" '"decision": "block"' "[L6] the next turn is measured from that stamp: a block"
folder "$TMP/l3"; touch -d "$NEW" "$TMP/l3/report.html"; S=$(sess)
eq "$(run "$TMP/l3" "$S" "$TMP/a.jsonl" false TMPDIR="$TMP/a.jsonl")" "$NONE" "[L7] a nudge that cannot be remembered is never made (no writable place for the session's stamp): nothing, exit 0"
has "$(run "$TMP/l3" "$S" "$TMP/a.jsonl" false)" '"decision": "block"' "[L7] control: with the place writable the same folder is nudged"

echo "== [S] beside the quiet save, in a folder with or without a history =="
folder "$TMP/s"; S=$(sess); touch -d "$NEW" "$TMP/s/report.html"
(cd "$TMP/s" && printf '{"session_id":"%s","hook_event_name":"Stop","cwd":"%s"}' "$S" "$TMP/s" | CLAUDE_PLUGIN_ROOT="$PL" CLAUDE_PROJECT_DIR="$TMP/s" bash -c "$SAVE" >/dev/null 2>&1)
eq "$(git -C "$TMP/s" rev-list --count HEAD 2>/dev/null || echo 0)" 1 "[S1] control: the quiet save made its commit before the nudge looked"
has "$(run "$TMP/s" "$S" "$TMP/a.jsonl" false)" '"decision": "block"' "[S1] a folder the kit keeps a history of (a repository with no remote, saved already): still a block"
eq "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["hooks"]["Stop"][0]["hooks"]; print([bool(h.get("async")) for h in d])' "$HOOKS")" "[True, False]" "[S2] the save stays async and silent, the nudge is a synchronous hook after it"

echo "== [B] bad input: exit 0 and nothing =="
folder "$TMP/b"; touch -d "$NEW" "$TMP/b/report.html"
for bad_in in '' 'not json' '[]' '{"cwd": 3}' '{"session_id": 7}' '{"session_id":"x"}'; do
  out=$(cd "$TMP/b" && printf '%s' "$bad_in" | CLAUDE_PLUGIN_ROOT="$PL" CLAUDE_PROJECT_DIR="$TMP/b" bash -c "$NUDGE" 2>&1; echo "rc=$?")
  eq "$out" "rc=0" "[B1] stdin $(printf '%s' "$bad_in" | head -c 20 | tr -d '\n') → exit 0, nothing"
done
eq "$(cd "$TMP" && printf '{"session_id":"x","cwd":"%s"}' "$TMP/nope" | CLAUDE_PLUGIN_ROOT="$PL" bash -c "$NUDGE" 2>&1; echo "rc=$?")" "rc=0" "[B2] a folder that does not exist: nothing, exit 0"
folder "$TMP/b3"; touch -d "$NEW" "$TMP/b3/report.html"; mkdir -p "$TMP/b3/.vibemaestro"; printf '{"schema": 1, "language": ' > "$TMP/b3/.vibemaestro/sdlc.json"
eq "$(run "$TMP/b3" "$(sess)" "$TMP/a.jsonl" false)" "$NONE" "[B3] a config that cannot be read: nothing, exit 0"
folder "$TMP/b4"; touch -d "$NEW" "$TMP/b4/report.html"; rm "$TMP/b4/kb/current-state.md"; mkdir "$TMP/b4/kb/current-state.md"
eq "$(run "$TMP/b4" "$(sess)" "$TMP/a.jsonl" false)" "$NONE" "[B4] a directory where current-state should be (nothing to overwrite): nothing, exit 0"
folder "$TMP/b6"; touch -d "$NEW" "$TMP/b6/report.html"; mkfifo "$TMP/b6.fifo"
eq "$(timeout 20 bash -c "$(declare -f run); NUDGE=$(printf '%q' "$NUDGE") PL=$(printf '%q' "$PL"); run \"$TMP/b6\" s6 \"$TMP/b6.fifo\" false")" "$NONE" "[B6] a transcript path that is a pipe: nothing, exit 0, no hang"
folder "$TMP/b5"; touch -d "$NEW" "$TMP/b5/report.html"; printf 'not a stamp\n{"timestamp": 5}\n' > "$TMP/b5.jsonl"
eq "$(run "$TMP/b5" "$(sess)" "$TMP/b5.jsonl" false)" "$NONE" "[B5] a transcript with no readable timestamp: nothing, exit 0"

echo "== [C] the scan has a cap, and the hook stays cheap =="
# the cap is tested in-process with the module's own constants lowered, on trees whose walk order does not matter
mkdir -p "$TMP/cap1/kb"; printf 'x\n' > "$TMP/cap1/only"; touch -d "$NEW" "$TMP/cap1/only"                                   # one directory, one changed file
mkdir -p "$TMP/cap2/kb" "$TMP/cap2/z"; for d in a b c d e; do mkdir "$TMP/cap2/$d"; done; printf 'x\n' > "$TMP/cap2/z/f"; touch -d "$NEW" "$TMP/cap2/z/f"   # six folders, the changed file in one
scan() { PYTHONPATH="$PL/scripts" python3 -c 'import sys, time, notebook_nudge as N
N.SCAN_ENTRIES = int(sys.argv[2]); N.SCAN_SECS = float(sys.argv[3])
print(N.changed_since(sys.argv[1], 1.7e9, time.time()))' "$@"; }
eq "$(scan "$TMP/cap1" 1 5)" True "[C1] control: room for the one file, it is found"
eq "$(scan "$TMP/cap1" 0 5)" False "[C1] no room for even the first file: the scan stops at that file, before its time is read, and says nothing"
eq "$(scan "$TMP/cap1" 5 -1)" False "[C1] a deadline already passed: the scan stops at that file and says nothing"
eq "$(scan "$TMP/cap2" 100 5)" True "[C1] control: six folders, room to look: the changed file is found"
eq "$(scan "$TMP/cap2" 3 5)" False "[C1] six folders over a cap of three: the scan stops before it enters them, with no file looked at"
mkdir -p "$TMP/flat"; python3 -c 'import sys; [open("%s/f%05d" % (sys.argv[1], i), "w").close() for i in range(20000)]' "$TMP/flat"
folder "$TMP/flat2"; mv "$TMP/flat" "$TMP/flat2/data"; find "$TMP/flat2/data" -type f -exec touch -d "$OLD" {} +
START=$(python3 -c 'import time; print(time.time())')
O=$(run "$TMP/flat2" "$(sess)" "$TMP/a.jsonl" false)
SECS=$(python3 -c 'import sys,time; print("%.2f" % (time.time() - float(sys.argv[1])))' "$START")
eq "$O" "$NONE" "[C2] one folder of 20,000 old files: nothing said, exit 0"
eq "$(python3 -c 'import sys; print("fast" if float(sys.argv[1]) < 3.0 else "slow " + sys.argv[1])' "$SECS")" fast "[C2] …in under 3 s for the whole hook (took ${SECS} s)"

echo "== [K] the core the session is given at its start =="
SC=$(hook_cmds "$HOOKS" SessionStart "" | sed -n 1p); folder "$TMP/k"
CORE=$(ctx "$(cd "$TMP/k" && p_start "$(sess)" | CLAUDE_PLUGIN_ROOT="$PL" CLAUDE_PROJECT_DIR="$TMP/k" bash -c "$SC" 2>/dev/null)")
has "$CORE" "at the end of each task" "[K1] the everyday core names the trigger: at the end of each task"
hasnt "$CORE" "as you go" "[K1] …and no longer says \"as you go\""
has "$CORE" "the present state only, a few lines, no diary" "[K1] …and says the shape of the state file"
has "$CORE" "only when a choice was made" "[K1] …decisions only when a choice was made"
has "$CORE" "add to \`kb/preferences.md\` only what the person said" "[K1] …and preferences only from the person's own words"
summary
