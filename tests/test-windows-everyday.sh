#!/bin/bash
# =============================================================================
# The everyday mode on real Windows: what the Linux suites only stand in for (tests/test-pyrun.sh, tests/test-quiet-save.sh).
# Run: bash tests/test-windows-everyday.sh   (Git for Windows' bash; .github/workflows/windows-everyday.yml runs it on a
#      GitHub-hosted Windows runner by hand). Anywhere else every family prints SKIP with its reason and the suite exits 0.
#
#   [H] hook start with no Python on PATH, with the Store shortcut only, with only the `py` launcher, with a Windows-form plugin root
#   [S] the quiet save on NTFS: a save, secret names in any case, the bytes a copy gives back, the profile's own folders refused
#   [V] Vietnamese file and folder names with the console on code page 1258 and PYTHONIOENCODING unset
#   [C] CRLF line endings in info/exclude and in .ignore
#   [J] the folder of old copies: a real junction named ban-cu, a person's Ban-Cu, a case variant of the kit's own, a read-only file
#   [L] a file another process holds open (no sharing) during a save
#
# The hooks run as Claude Code runs them on Windows: the `command` strings of hooks/hooks.json through bash, the payload's cwd and
# CLAUDE_PROJECT_DIR in Windows form. Python reads USERPROFILE, not HOME, on Windows: every family runs with a scratch USERPROFILE,
# except [S4], which needs the real profile and runs only on a GitHub-hosted runner (GITHUB_ACTIONS=true and
# RUNNER_ENVIRONMENT=github-hosted: a self-hosted runner sets the first too), never on a person's machine.
# Git keeps the machine's own system settings (Git for Windows installs core.autocrlf there): what a person's machine has.
# A case whose precondition this machine lacks prints SKIP and the reason, never ok.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
SKIPS=0
skip() { SKIPS=$((SKIPS+1)); printf '  SKIP %s: %s\n' "$1" "$2"; }

if [ "${OS:-}" != Windows_NT ]; then
  for f in H S V C J L; do skip "[$f]" "not Windows (OS is not Windows_NT)"; done
  echo "$SKIPS skipped"; summary; exit
fi

PL="$SRC_ROOT/plugins/vibemaestro-sdlc"
HOOKS="$PL/hooks/hooks.json"
REAL_PROFILE=$(cygpath -u "${USERPROFILE:-}")
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
JUNCTIONS=()
cleanup() {  # a junction is removed as a link first, so nothing ever deletes through it
  local j; for j in "${JUNCTIONS[@]}"; do [ -e "$j" ] && MSYS_NO_PATHCONV=1 cmd.exe /c rmdir "$(cygpath -w "$j")" >/dev/null 2>&1; done
  [ -n "${CP0:-}" ] && chcp.com "$CP0" >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT
clean_env "$TMP"
unset GIT_CONFIG_NOSYSTEM
export USERPROFILE; USERPROFILE=$(cygpath -w "$HOME")
export LC_ALL=C.UTF-8 VIBEMAESTRO_NO_UPDATE_CHECK=1 PYTHONDONTWRITEBYTECODE=1
baton_set_mode "$XDG_STATE_HOME" manual
unset VIBEMAESTRO_PROFILE GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL PYTHONIOENCODING PYTHONUTF8
echo "machine: $(python3 --version 2>&1 | tr -d '\r'), $(git --version), system core.autocrlf=$(git config --system --get core.autocrlf || echo unset)"

win() { cygpath -w "$1"; }
payload() {  # payload <dir> <event> — the hook payload Claude Code sends on Windows: cwd in Windows form, backslashes escaped
  printf '{"session_id":"s1","hook_event_name":"%s","source":"startup","cwd":"%s"}' "$2" "$(win "$1" | sed 's/\\/\\\\/g')"
}
hook() {  # hook <event> <n> <dir> [env…] — the n-th command of that event run in <dir>; prints its stdout (CR removed), then rc=<n>
  local ev=$1 n=$2 d=$3 c out rc; shift 3
  c=$(hook_cmds "$HOOKS" "$ev" "" | tr -d '\r' | sed -n "${n}p")
  out=$(cd "$d" && payload "$d" "$ev" | env CLAUDE_PLUGIN_ROOT="$PL" CLAUDE_PROJECT_DIR="$(win "$d")" "$@" bash -c "$c" 2>/dev/null); rc=$?
  printf '%s\nrc=%d' "$(printf '%s' "$out" | tr -d '\r')" "$rc"
}
stop() { hook Stop 1 "$@"; }
start() { hook SessionStart 1 "$@" | sed '$d'; }   # the session-start core hook's JSON: the kit's lines go to Claude's context
# (additionalContext), said to the person in their own language; the person-visible systemMessage carries none of them
qs() {  # qs <dir> <args…> — quiet_save.py the way the history skill runs it; stdout (CR removed), then rc=<n>
  local d=$1 out rc; shift
  out=$(/bin/sh "$PL/scripts/pyrun.sh" scripts/quiet_save.py "$@" --dir "$(win "$d")" 2>&1); rc=$?
  printf '%s\nrc=%d' "$(printf '%s' "$out" | tr -d '\r')" "$rc"
}
saves() { git -C "$1" rev-list --count HEAD 2>/dev/null || echo 0; }
tracked() { git -C "$1" -c core.quotepath=off ls-files | sort | tr '\n' ' '; }
folder() { mkdir -p "$1"; printf '<h1>Q3</h1>\n' > "$1/report.html"; }
NOPY="/usr/bin:$(dirname "$(command -v git)")"   # Git for Windows' own tools (bash, sh, coreutils) and git's own folder; no Python
found() { PATH=$1 command -v "$2" 2>/dev/null; }
MISSING="vibemaestro: this machine has no Python 3.8 or newer, so the kit is not running in this session (nothing is blocked). Ask Claude how to set it up on this machine."

echo "== [H] hook start without Python, and with only the py launcher =="
P="$TMP/h"; folder "$P"
if [ -n "$(found "$NOPY" python3)$(found "$NOPY" python)$(found "$NOPY" py)" ] || [ -z "$(found "$NOPY" git)" ]; then
  skip "[H1]" "Git for Windows' own folders hold a Python, or no git: no PATH without Python can be built"
else
  O=$(hook SessionStart 1 "$P" PATH="$NOPY")
  eq "$(sysm "$(printf '%s' "$O" | sed '$d')")" "$MISSING" "[H1] no Python on PATH: the session start says it in one plain line (a hook that crashed would say nothing)"
  eq "${O##*rc=}" 0 "[H1] …and exits 0"
  eq "$(hook PreToolUse 1 "$P" PATH="$NOPY")" "$(printf '\nrc=0')" "[H1] no Python: the first edit guard prints nothing and exits 0 (an edit is not blocked)"
  eq "$(stop "$P" PATH="$NOPY")" "$(printf '\nrc=0')" "[H1] no Python: the Stop hook prints nothing and exits 0"
fi
STORE=$(cygpath -u "${LOCALAPPDATA:-/nonexistent}")/Microsoft/WindowsApps
if [ ! -e "$STORE/python3.exe" ]; then
  skip "[H2]" "this machine has no Store shortcut python3.exe in WindowsApps"
elif "$STORE/python3.exe" -c 'pass' </dev/null >/dev/null 2>&1; then
  skip "[H2]" "the Store's python3.exe runs a real Python here, so it is no stand-in for a missing one"
else
  O=$(hook SessionStart 1 "$P" PATH="$NOPY:$STORE")
  eq "$(sysm "$(printf '%s' "$O" | sed '$d')")" "$MISSING" "[H2] only the Store shortcut on PATH: taken for no Python (a shortcut that runs nothing is not used)"
fi
PYDIR=$(dirname "$(command -v py 2>/dev/null || echo /nonexistent/py)")
if [ -z "$(found "$NOPY:$PYDIR" py)" ] || [ -n "$(found "$NOPY:$PYDIR" python3)$(found "$NOPY:$PYDIR" python)" ]; then
  skip "[H3]" "no py launcher on this machine, or its folder also holds python"
elif ! PATH="$NOPY:$PYDIR" py -3 -c 'import sys; sys.exit(sys.version_info < (3, 8))' </dev/null >/dev/null 2>&1; then
  skip "[H3]" "the py launcher finds no Python 3.8 or newer here"
else
  E="$TMP/h3"; mkdir -p "$E"
  eq "$(PATH="$NOPY:$PYDIR" qs "$E" list)" "$(printf 'Nothing changed: this folder has no saves yet.\nrc=1')" "[H3] only py on PATH: the kit's script runs through py -3 (no Python found would print nothing)"
  O=$(hook SessionStart 1 "$P" PATH="$NOPY:$PYDIR")
  ne "$(sysm "$(printf '%s' "$O" | sed '$d')")" "$MISSING" "[H3] …and the session start does not say Python is missing"
  eq "${O##*rc=}" 0 "[H3] …and exits 0"
  isjson "$(printf '%s' "$O" | sed '$d')" && ok "[H3] …with whole JSON (a crash under py would print nothing)" || bad "[H3] the session start under py printed no whole JSON"
fi
P4="$TMP/h4"; folder "$P4"
(cd "$P4" && payload "$P4" Stop | env CLAUDE_PLUGIN_ROOT="$(win "$PL")" CLAUDE_PROJECT_DIR="$(win "$P4")" bash -c "$(hook_cmds "$HOOKS" Stop "" | tr -d '\r')" >/dev/null 2>&1); rc=$?
eq "$rc:$(saves "$P4")" "0:1" "[H4] the plugin root in Windows form (C:\\…): the Stop hook still finds its script and saves once"

echo "== [S] the quiet save on NTFS =="
P="$TMP/s"; folder "$P"; mkdir -p "$P/kb"; printf 'viec\n' > "$P/kb/viec.md"
for f in .ENV Prod.Env ID_RSA ID_ED25519.pub Secrets.yaml CREDENTIALS server.PEM; do printf 'x\n' > "$P/$f"; done
eq "$(stop "$P")" "$(printf '\nrc=0')" "[S1] the Stop hook prints nothing and exits 0"
eq "$(saves "$P")" 1 "[S1] one save is made on NTFS"
eq "$(tracked "$P")" "kb/viec.md report.html " "[S2] secret names in another case (.ENV, Prod.Env, ID_RSA, ID_ED25519.pub, Secrets.yaml, CREDENTIALS, server.PEM) are not saved"
B="$TMP/bytes"; mkdir -p "$B"; printf 'lf one\nlf two\n' > "$B/lf.txt"; printf 'crlf one\r\ncrlf two\r\n' > "$B/crlf.txt"
cp "$B/lf.txt" "$B/crlf.txt" "$P/"; stop "$P" >/dev/null
O=$(qs "$P" copy 1)
eq "${O##*rc=}" 0 "[S3] the newest save is copied"
C=$(ls -d "$P"/ban-cu/*/ 2>/dev/null | head -n 1)
cmp -s "$B/lf.txt" "${C}lf.txt" && ok "[S3] a file with LF comes back from the copy byte for byte" || bad "[S3] a file with LF comes back changed from the copy (line endings rewritten?)"
cmp -s "$B/crlf.txt" "${C}crlf.txt" && ok "[S3] a file with CRLF comes back from the copy byte for byte" || bad "[S3] a file with CRLF comes back changed from the copy"
if [ "${GITHUB_ACTIONS:-}" != true ] || [ "${RUNNER_ENVIRONMENT:-}" != github-hosted ]; then
  skip "[S4]" "the profile's own folders are only used on a GitHub-hosted runner (RUNNER_ENVIRONMENT=github-hosted), never on a person's machine"
elif [ -z "$REAL_PROFILE" ] || [ ! -d "$REAL_PROFILE" ]; then
  skip "[S4]" "USERPROFILE is not a folder here"
else
  made=()   # the folders this run created on the runner, removed after (deepest first)
  for rel in Desktop Documents OneDrive OneDrive/Documents; do
    D="$REAL_PROFILE/$rel"
    if [ -e "$D/.git" ]; then skip "[S4] $rel" "it already holds a .git"; continue; fi
    [ -d "$D" ] || { mkdir -p "$D"; made=("$D" "${made[@]}"); }
    printf 'x\n' > "$D/kit-test-$$.txt"
    O=$(stop "$D" USERPROFILE="$(win "$REAL_PROFILE")")
    eq "$O|$(test -e "$D/.git" && echo git || echo none)" "$(printf '\nrc=0')|none" "[S4] $rel of the real profile ($(win "$D")): not turned into a history, nothing printed, rc 0"
    J=$(start "$D" USERPROFILE="$(win "$REAL_PROFILE")")
    has "$(ctx "$J")" "itself is not saved" "[S4] …because the kit refused the place: the next session start tells Claude so (any other early return would not)"
    hasnt "$(sysm "$J")" "itself is not saved" "[S4] …and shows the person no fixed-language line of it"
    rm -f "$D/kit-test-$$.txt"
  done
  for D in "${made[@]}"; do rmdir "$D" 2>/dev/null; done
fi

echo "== [V] Vietnamese names, console code page 1258, PYTHONIOENCODING unset =="
# chcp sets the console's code page; the hooks' output is a pipe, which Python writes in the system (ANSI) code page, not the
# console's. So these cases prove the names survive the machine's system code page with the console on 1258, as Claude Code runs
# hooks; a system code page of 1258 itself is a machine setting (a Vietnamese Windows), not something a test can switch.
CP0=$(chcp.com 2>/dev/null | tr -dc '0-9')
if [ -z "$CP0" ] || ! chcp.com 1258 >/dev/null 2>&1; then
  CP0=; skip "[V]" "no console whose code page can be set to 1258"
else
  P="$TMP/v"; mkdir -p "$P/Tài liệu"; printf 'q3\n' > "$P/Tài liệu/Báo cáo quý 3.html"
  printf 'nfd\n' > "$P/$(printf 'Ghi chu\xcc\x81.txt')"   # "Ghi chú" with a combining accent (NFD), as macOS writes it
  eq "$(stop "$P")" "$(printf '\nrc=0')" "[V1] the Stop hook under code page 1258 prints nothing and exits 0"
  eq "$(tracked "$P")" "$(printf 'Ghi chu\xcc\x81.txt') Tài liệu/Báo cáo quý 3.html " "[V1] the Vietnamese names (NFC folder and file, an NFD file) are saved as they are"
  O=$(qs "$P" list)
  has "$O" "Tài liệu/Báo cáo quý 3.html (added)" "[V2] the list names the Vietnamese file right through a pipe in the system code page (an unset encoding would print ? or crash)"
  eq "${O##*rc=}" 0 "[V2] …and exits 0"
  O=$(qs "$P" copy 1)
  eq "${O##*rc=}" 0 "[V3] the save with Vietnamese names is copied"
  F=$(ls -d "$P"/ban-cu/*/"Tài liệu"/"Báo cáo quý 3.html" 2>/dev/null | head -n 1)
  eq "$(cat "$F" 2>/dev/null)" q3 "[V3] …and the copy holds Tài liệu/Báo cáo quý 3.html with its content"
  O=$(hook SessionStart 1 "$P")
  eq "${O##*rc=}" 0 "[V4] the session start in a folder of Vietnamese names exits 0 under code page 1258"
  isjson "$(printf '%s' "$O" | sed '$d')" && ok "[V4] …and prints whole JSON (an encoding crash would cut it)" || bad "[V4] the session start printed no whole JSON under code page 1258"
fi

echo "== [C] CRLF in info/exclude and .ignore =="
P="$TMP/c"; folder "$P"; stop "$P" >/dev/null
EX="$P/.git/info/exclude"
{ tr -d '\r' < "$EX" | sed 's/$/\r/'; printf '*.bak\r\n'; } > "$TMP/exclude.crlf" && cp "$TMP/exclude.crlf" "$EX"   # an editor saved it with CRLF: input, not a break
printf 'x\n' > "$P/notes.bak"; printf 'x\n' > "$P/.env"; printf 'y\n' > "$P/plan.txt"; stop "$P" >/dev/null
eq "$(tracked "$P")" "plan.txt report.html " "[C1] info/exclude with CRLF lines: the person's *.bak and the kit's .env still keep those files out of the save"
H1=$(sha1sum < "$EX"); N0=$(saves "$P"); printf 'z\n' >> "$P/plan.txt"; stop "$P" >/dev/null
eq "$(( $(saves "$P") - N0 ))|$(sha1sum < "$EX")" "1|$H1" "[C1] …and a later save (made) leaves info/exclude as it is (it does not grow on every save)"
printf 'node_modules/\r\n' > "$P/.ignore"
eq "$(qs "$P" copy 1 | tail -n 1)" "rc=0" "[C2] a copy with a CRLF .ignore is made"
printf 'node_modules/\r\n/ban-cu/\n' > "$TMP/ignore.want"
cmp -s "$P/.ignore" "$TMP/ignore.want" && ok "[C2] …and .ignore gets the one line /ban-cu/ after its CRLF lines, nothing else changed" || bad "[C2] .ignore is not 'node_modules/<CRLF>/ban-cu/<LF>' after the copy: $(od -c "$P/.ignore" | head -n 3 | tr '\n' ' ')"
P="$TMP/c3"; folder "$P"; stop "$P" >/dev/null; printf 'node_modules/\r\n/ban-cu/\r\n' > "$P/.ignore"; cp "$P/.ignore" "$TMP/ignore3.want"
O=$(qs "$P" copy 1)
eq "${O##*rc=}|$(test -d "$P/ban-cu" && echo copied || echo none)" "0|copied" "[C3] a copy with .ignore already holding /ban-cu/ (CRLF) is made"
cmp -s "$P/.ignore" "$TMP/ignore3.want" && ok "[C3] .ignore already holding /ban-cu/ with CRLF: not one byte added" || bad "[C3] a .ignore holding /ban-cu/<CRLF> got another line"

echo "== [J] the folder of old copies: junctions, case variants, read-only files =="
P="$TMP/j"; O_="$TMP/outside"; folder "$P"; mkdir -p "$O_"; stop "$P" >/dev/null
MSYS_NO_PATHCONV=1 cmd.exe /c mklink /J "$(win "$P/ban-cu")" "$(win "$O_")" >/dev/null 2>&1 && JUNCTIONS+=("$P/ban-cu")
if [ ! -d "$P/ban-cu" ]; then
  skip "[J1]" "mklink /J could not make a junction here"
else
  O=$(qs "$P" copy 1)
  has "$O" "copied into ban-cu-2/" "[J1] a junction named ban-cu is not taken for the kit's folder: the copy goes into ban-cu-2/"
  eq "$(ls -A "$O_" | wc -l | tr -d ' ')" 0 "[J1] …and nothing is written through the junction outside the work folder"
  RC=0; O=$(capped /bin/sh "$PL/scripts/pyrun.sh" scripts/quiet_save.py drop-copy ban-cu/x --dir "$(win "$P")" 2>&1) || RC=$?
  eq "$RC|$(ls -A "$O_" | wc -l | tr -d ' ')" "1|0" "[J1] drop-copy of a name under the junction (ban-cu/x, not on the kit's list) is refused with rc 1, the outside folder still empty"
  has "$O" "Nothing changed: ban-cu/x is not one of the kit's old copies." "[J1] …refused by the kit in its own words (a crash also exits 1)"
fi
P="$TMP/j2"; folder "$P"; stop "$P" >/dev/null; mkdir -p "$P/Ban-Cu"; printf 'mine\n' > "$P/Ban-Cu/mine.txt"
O=$(qs "$P" copy 1)
has "$O" "copied into ban-cu-2/" "[J2] the person's folder Ban-Cu (another case of the kit's name, the same name on NTFS) is passed over: the copy goes into ban-cu-2/"
eq "$(ls -A "$P/Ban-Cu" | tr '\n' ' ')|$(cat "$P/Ban-Cu/mine.txt")" "mine.txt |mine" "[J2] …and Ban-Cu holds only the person's file, unchanged"
P="$TMP/j3"; folder "$P"; stop "$P" >/dev/null; qs "$P" copy 1 >/dev/null
N=$(ls "$P/ban-cu" | grep -v '^DAY-LA-BAN-CU.txt$' | head -n 1)
RC=0; O=$(capped /bin/sh "$PL/scripts/pyrun.sh" scripts/quiet_save.py drop-copy "BAN-CU/$N" --dir "$(win "$P")" 2>&1) || RC=$?
eq "$RC|${N:+named}|$(test -d "$P/ban-cu/$N" && echo kept || echo gone)" "1|named|kept" "[J3] drop-copy of the kit's own copy named in another case (BAN-CU/…) is refused, the copy kept"
has "$O" "is not one of the kit's old copies." "[J3] …refused by the kit in its own words (a crash also exits 1)"
P="$TMP/j4"; folder "$P"; stop "$P" >/dev/null; qs "$P" copy 1 >/dev/null
N=$(ls "$P/ban-cu" | grep -v '^DAY-LA-BAN-CU.txt$' | head -n 1)
MSYS_NO_PATHCONV=1 attrib.exe +R "$(win "$P/ban-cu/$N/report.html")" >/dev/null 2>&1
if [ -w "$P/ban-cu/$N/report.html" ]; then
  skip "[J4]" "attrib +R did not make the file read-only here"
else
  O=$(qs "$P" drop-copy "ban-cu/$N")
  eq "$O" "$(printf 'The old copy ban-cu/%s is removed.\nrc=0' "$N")" "[J4] drop-copy of a copy holding a read-only file removes it and says so (Windows refuses to delete a read-only file as such)"
  eq "$(test -e "$P/ban-cu/$N" && echo there || echo gone)" gone "[J4] …and the copy is gone"
fi

hold() {  # hold <file> <tag> — PowerShell keeps <file> open with no sharing until `free <tag>`; rc 1 when it could not
  rm -f "$TMP/$2.ready" "$TMP/$2.release"
  powershell.exe -NoProfile -NonInteractive -Command "\$f = [System.IO.File]::Open('$(win "$1")', 'Open', 'ReadWrite', 'None'); New-Item -ItemType File '$(win "$TMP/$2.ready")' | Out-Null; while (-not (Test-Path '$(win "$TMP/$2.release")')) { Start-Sleep -Milliseconds 100 }; \$f.Close()" >/dev/null 2>&1 &
  eval "HOLD_$2=\$!"
  for _ in $(seq 1 150); do [ -e "$TMP/$2.ready" ] && return 0; sleep 0.2; done
  free "$2"; return 1
}
free() { : > "$TMP/$1.release"; eval "wait \"\$HOLD_$1\"" 2>/dev/null; }

P="$TMP/j5"; folder "$P"; stop "$P" >/dev/null; qs "$P" copy 1 >/dev/null
N=$(ls "$P/ban-cu" | grep -v '^DAY-LA-BAN-CU.txt$' | head -n 1)
if ! hold "$P/ban-cu/$N/report.html" j5; then
  skip "[J5]" "PowerShell could not hold a file of the copy open without sharing"
else
  O=$(qs "$P" drop-copy "ban-cu/$N")
  free j5
  has "$O" "The old copy ban-cu/$N could not be removed whole (" "[J5] drop-copy while a file of the copy is held open: one plain line (main: a traceback)"
  has "$O" "); what is left of it stays on the kit's list, so asking again removes the rest." "[J5] …which says the copy stays listed"
  eq "${O##*rc=}|$(printf '%s' "$O" | grep -c Traceback)" "1|0" "[J5] …rc 1, no traceback"
  eq "$(qs "$P" drop-copy "ban-cu/$N")" "$(printf 'The old copy ban-cu/%s is removed.\nrc=0' "$N")" "[J5] …the copy stayed listed, so asking again once the file is free removes the rest"
fi

echo "== [L] a file another process holds open during a save =="
P="$TMP/l"; folder "$P"; printf 'a\n' > "$P/a.txt"; printf 'b1\n' > "$P/b.txt"; stop "$P" >/dev/null
printf 'b2\n' > "$P/b.txt"; printf 'c\n' > "$P/c.txt"
if ! hold "$P/b.txt" l; then
  skip "[L]" "PowerShell could not hold b.txt open without sharing"
else
  eq "$(stop "$P")" "$(printf '\nrc=0')" "[L1] the Stop hook with b.txt held open prints nothing and exits 0"
  free l
  eq "$(cat "$P/a.txt")|$(cat "$P/b.txt")|$(cat "$P/c.txt")" "a|b2|c" "[L1] …and no file of the folder is lost or changed"
  J=$(start "$P")
  has "$(ctx "$J")" "the last quiet save of this folder did not happen" "[L1] the next session start tells Claude in one plain line that the save did not keep the work"
  hasnt "$(sysm "$J")" "quiet save" "[L1] …and shows the person no fixed-language line of it"
  N0=$(saves "$P"); stop "$P" >/dev/null
  eq "$(( $(saves "$P") - N0 ))|$(git -C "$P" show HEAD:b.txt 2>/dev/null)|$(tracked "$P")" "1|b2|a.txt b.txt c.txt report.html " "[L2] once b.txt is free, the next turn saves the work: b.txt's new text and the new c.txt"
fi

echo; echo "$SKIPS skipped"; summary
