# shellcheck shell=bash
# =============================================================================
# Shared by tests/test-brain-*.sh: a kit copy in the scratch tree, one fresh project per case, and planted breaks.
# =============================================================================
# A case is a shell function that runs its checks through c_eq / c_has / c_hasnt / c_rc. Run normally (run_case) each check
# prints ok/FAIL; run on a plugin copy with one planted break (plant), it runs quiet and must end with at least one failed check.
# The brain is always run from a copy (KIT), never from the checkout, so no __pycache__ lands in the repository and a break is
# planted on a copy of its own: KIT/plugins/vibemaestro-brain next to KIT/plugins/vibemaestro-sdlc, the marketplace layout the
# brain finds sdlc's sensitive-value filter in.
# Needs lib.sh (ok, bad, git_) and clean_env already called.

brain_kit() {  # brain_kit <src root> — copies the brain and sdlc into $TMP/kit; sets KIT and BROOT
  KIT="$TMP/kit"
  mkdir -p "$KIT/plugins"
  cp -R "$1/plugins/vibemaestro-brain" "$1/plugins/vibemaestro-sdlc" "$KIT/plugins/"
  find "$KIT" -name __pycache__ -prune -exec rm -rf {} +
  BROOT="$KIT/plugins/vibemaestro-brain"
  # The answerer check reads the machine around it: the managed settings (a sandbox pod holds a PermissionRequest hook there),
  # the account's home from the password database, and every ancestor process's cwd and CLAUDE_CONFIG_DIR. A suite must not
  # depend on the machine it is launched from, so the copy reads the scratch tree's managed settings and account home, and
  # stops its ancestor walk at the suite's own shell (SUITE_PID, on Windows that shell's Windows process id): only the
  # processes a case starts are its ancestors. The suites re-exec without CLAUDE_CONFIG_DIR, because a forked subshell shows
  # the suite shell's initial environment.
  MANAGED="$TMP/managed"; ACCOUNT="$TMP/account"; mkdir -p "$MANAGED" "$ACCOUNT"
  local me=$$; [ "${OS:-}" != Windows_NT ] || me=$(cat "/proc/$$/winpid")
  python3 - "$BROOT/scripts/brain_store.py" "$MANAGED" "$ACCOUNT" "$me" <<'PY' || { bad "brain_kit: a line to isolate was not found in the copy"; return 1; }
import re, sys
p, m, a, pid = sys.argv[1:5]
s = open(p, encoding="utf-8").read()
subs = ((r"(?m)^MANAGED_SETTINGS = .*$", 'MANAGED_SETTINGS = ("%s/managed-settings.json",)\nSUITE_PID = %s' % (m, pid)),
        (r"(?m)^        return (?:win_profile\(\) if WINDOWS else )?pwd\.getpwuid\(os\.getuid\(\)\)\.pw_dir$", '        return "%s"' % a),
        (r"(?m)^        if pid <= 1:$", "        if pid <= 1 or pid == SUITE_PID:"),
        (r"(?m)^    chain = win_chain\(os\.getpid\(\), table, _win_info, bridge=_msys_bridge\(\)\)$",
         "    chain = win_chain(os.getpid(), table, _win_info, SUITE_PID, bridge=_msys_bridge())"))
for pat, new in subs:
    s, n = re.subn(pat, lambda _: new, s)
    if n != 1:
        sys.exit(1)
open(p, "w", encoding="utf-8", newline="").write(s)
PY
  export PYTHONDONTWRITEBYTECODE=1
}

# Windows (Git Bash running Windows' own Python): Python ends a printed line with CR LF, so every python3 a suite runs is read
# without the CR (the rc stays Python's: pipefail); br and hk drop it from what they capture. The suites' own helpers run in
# UTF-8 mode (they read and write files without naming an encoding); -X is not handed to a child and nothing is exported, so
# the brain itself (bin/brain, a hook, what they start) runs in the system code page, as on a person's machine.
if [ "${OS:-}" = Windows_NT ]; then
  python3() { command python3 -X utf8 "$@" | sed 's/\r$//'; }
fi
hookpy() {  # hookpy <script> <args…> — a hook script as pyrun.sh runs it: on Windows with UTF-8 streams unless the case set others
  if [ "${OS:-}" = Windows_NT ]; then PYTHONIOENCODING="${PYTHONIOENCODING:-utf-8}" command python3 "$@"; else command python3 "$@"; fi
}
wargs() {  # wargs <arg>… — WARGS: the arguments, each path in the scratch tree in the form a Windows session types (C:/…);
  # the brain takes its arguments as typed there (bin/brain), as guard-owner reads them
  local a; WARGS=()
  for a in "$@"; do
    # only the prefix: cygpath would also resolve a .. the argument must keep, as a person types it
    if [ "${OS:-}" = Windows_NT ]; then case "$a" in "$TMP"|"$TMP"/*) a="$(cygpath -m "$TMP")${a#"$TMP"}";; esac; fi
    WARGS+=("$a")
  done
}
wcwd() { if [ "${OS:-}" = Windows_NT ]; then cygpath -w "$1"; else printf '%s' "$1"; fi; }   # a directory as Python's getcwd gives it
nocr() { if [ "${OS:-}" = Windows_NT ]; then local t=${1//$'\r\n'/$'\n'}; printf '%s' "${t%$'\r'}"; else printf '%s' "$1"; fi; }

Q=0; CASE_FAIL=0; NP=0
_c() {  # _c <0|1 passed> <label> <detail>
  if [ "$1" = 1 ]; then [ "$Q" = 1 ] || ok "$2"; else CASE_FAIL=1; [ "$Q" = 1 ] || bad "$2 ($3)"; fi
}
c_eq()    { [ "$1" = "$2" ] && _c 1 "$3" || _c 0 "$3" "got '${1:0:300}', want '$2'"; }
c_has()   { case "$1" in *"$2"*) _c 1 "$3";; *) _c 0 "$3" "missing '$2' in '${1:0:300}'";; esac; }
c_hasnt() { case "$1" in *"$2"*) _c 0 "$3" "has '$2'";; *) _c 1 "$3";; esac; }
c_rc()    { c_eq "$RC" "$1" "$2"; }
c_skip()  { [ "$Q" = 1 ] || printf '  SKIP %s: %s\n' "$1" "$2"; }   # c_skip <label> <why> — a check this system cannot make

newp() {  # newp — a fresh git project and a fresh state root; cd into the project; SID back to sA
  NP=$((NP+1))
  P="$TMP/proj$NP"; mkdir -p "$P"
  git_ -C "$P" init -q -b main
  export XDG_STATE_HOME="$TMP/state$NP"
  cd "$P" || return 1
  SID=sA
  unset INTENT_SLUG SEAT VIBEMAESTRO_ROLE BRAIN_TEST BRAIN_TEST_PAUSE_MS CLAUDE_PROJECT_DIR
}

br() {  # br <args…> — run the brain of BROOT as session SID; sets OUT (stdout+stderr) and RC
  wargs "$@"
  OUT=$(CLAUDE_CODE_SESSION_ID="$SID" "$BROOT/bin/brain" ${WARGS[@]+"${WARGS[@]}"} 2>&1); RC=$?
  OUT=$(nocr "$OUT")
}

bpy() {  # bpy <python code> — run code with brain_store imported as s, in the current project
  CLAUDE_CODE_SESSION_ID="$SID" python3 -c "import sys; sys.path.insert(0, sys.argv[1]); import brain_store as s
$1" "$BROOT/scripts"
}

sdir() { bpy 'print(s.state_dir())'; }

rec() {  # rec <mode> <session> <args after owner…> — an "asked" record, written as guard-owner writes it
  local mode=$1 ses=$2; shift 2
  CLAUDE_CODE_SESSION_ID="$SID" python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import brain_store as s
s.record_asked(s.state_dir(), sys.argv[3], sys.argv[2], sys.argv[4:])' "$BROOT/scripts" "$mode" "$ses" "$@"
}

owner_ok() {  # owner_ok <args after owner…> — a fresh default-mode record for SID, then `brain owner <args>`
  rec default "$SID" "$@"; br owner "$@"
}

hin() {  # hin <key=value>… — hook input JSON; a value that parses as JSON stays JSON, any other is a string. On Windows a path
  # key (cwd, file_path, notebook_path, transcript_path) is handed over in the form Claude Code sends there (C:/…)
  MSYS_NO_PATHCONV=1 python3 -c 'import json, os, subprocess, sys
PATHS = ("cwd", "file_path", "notebook_path", "transcript_path")
def win(v):
    if os.name != "nt" or not v.startswith("/"):
        return v
    return subprocess.run(["cygpath", "-m", v], capture_output=True, text=True, check=True).stdout.strip()
def fix(o):
    return {k: win(v) if k in PATHS and isinstance(v, str) else fix(v) for k, v in o.items()} if isinstance(o, dict) else o
d = {}
for kv in sys.argv[1:]:
    k, _, v = kv.partition("=")
    try:
        d[k] = json.loads(v)
    except ValueError:
        d[k] = v
print(json.dumps(fix(d), ensure_ascii=False))' "$@"
}

hk() {  # hk <event> <hook input JSON> — run BROOT's brain_hook.py as Claude Code does; sets OUT (stdout), ERR (stderr), RC
  local e
  e=$(mktemp)
  OUT=$(printf '%s' "$2" | hookpy "$BROOT/scripts/brain_hook.py" "$1" 2>"$e"); RC=$?
  OUT=$(nocr "$OUT"); ERR=$(nocr "$(cat "$e")"); rm -f "$e"
}

hfield() {  # hfield <field> — a field of hookSpecificOutput in OUT ("" when OUT is empty or has no such field)
  printf '%s' "$OUT" | python3 -c 'import json, sys
t = sys.stdin.read().strip()
print(json.loads(t).get("hookSpecificOutput", {}).get(sys.argv[1], "") if t else "")' "$1"
}

run_case() {  # run_case <case function>
  Q=0; CASE_FAIL=0; BROOT="$KIT/plugins/vibemaestro-brain"
  echo "-- $1"
  "$1"
}

plant() {  # plant <name> <case function> <file under the plugin> <old text> <new text> — the case must go red on the copy
  local name=$1 fn=$2 file=$3 old=$4 new=$5 d="$TMP/brk-$1" saved=$BROOT
  mkdir -p "$d/plugins"
  cp -R "$KIT/plugins/vibemaestro-brain" "$d/plugins/"
  ln -s "$KIT/plugins/vibemaestro-sdlc" "$d/plugins/vibemaestro-sdlc"
  if ! python3 - "$d/plugins/vibemaestro-brain/$file" "$old" "$new" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p, encoding="utf-8").read()
if s.count(old) != 1:
    sys.exit(1)
open(p, "w", encoding="utf-8", newline="").write(s.replace(old, new))
PY
  then bad "[X] $name: the break does not apply (the text is not found exactly once in $file)"; return; fi
  local crc rf="$d.case"; rm -f "$rf"
  Q=1; CASE_FAIL=0; BROOT="$d/plugins/vibemaestro-brain"
  capped _plant_case "$fn" "$rf"; crc=$?   # capped: memory and time caps (fixtures/capped.sh)
  Q=0; BROOT=$saved
  if cap_red "$crc" "[X] $name ($fn)"; then NP=$((NP+1)); return; fi
  read -r CASE_FAIL NP < "$rf" 2>/dev/null || { CASE_FAIL=0; NP=$((NP+1)); }
  [ "$CASE_FAIL" = 1 ] && ok "[X] $name turns $fn red" || bad "[X] $name: $fn stays green with the break"
}

_plant_case() {  # _plant_case <case function> <result file> — the case in the capped subshell; its verdict and project counter go back through the file
  "$1" >/dev/null 2>&1
  echo "$CASE_FAIL $NP" > "$2"
}
