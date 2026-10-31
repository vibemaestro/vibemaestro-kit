#!/bin/bash
# =============================================================================
# The local state file: outside a sandbox, the stage signal records what a sandbox session records
# =============================================================================
# Run: bash tests/test-local-state.sh
#
# With no `session-notify` on the PATH, `scripts/stage-signal.sh` writes `<state>/vibemaestro/sessions/<session>/<stem>.json`
# through `scripts/local_state.py` (the item `local-state` of CONTRACT.md): the stages, `ask` (the question on stdin), `done`
# (the report on stdin), `progress <step>` and `bind <stem> --agent <id>`. These families run the real script from a throw-away
# directory with a PATH that has no `session-notify`, a throw-away HOME and XDG_STATE_HOME, and read the file back as JSON.
# A refusal is rc 0, one stderr line, nothing written. Then each family goes red on a copy with one planted break.
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
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"

SID=0183b9ff-c54b-4705-bf18-3490bc605a10
SID2=11111111-2222-4333-8444-555555555555
STEM=2026-10-30-local-worker
STEM2=2026-10-30-other-task
FIELDS='schema state ts epoch event question source tail hint session progress progress_epoch intents local'
PLX=""; XS=""; HM=""; CWD=""
# LS <session|-> <args...> — the script with no session-notify, from $CWD; stdin passes through; `-` leaves the session id unset.
# CHILD=1 marks a subagent; NOXDG=1 leaves XDG_STATE_HOME unset; XDGV overrides its value.
LS() {
  local sid=$1; shift
  local e=(PATH="$(bare_path nogh)")
  [ "$sid" = - ] || e+=(CLAUDE_CODE_SESSION_ID="$sid")
  [ -n "${CHILD:-}" ] && e+=(CLAUDE_CODE_CHILD_SESSION=1)
  [ -n "${NOXDG:-}" ] || e+=(XDG_STATE_HOME="${XDGV:-$XS}")
  ( cd "${CWD:-$TMP}" && env -i HOME="$HM" "${e[@]}" bash "$PLX/scripts/stage-signal.sh" "$@" )
}
# f <session> <stem> — the file's path under $XS
f() { printf '%s/vibemaestro/sessions/%s/%s.json' "$XS" "$1" "$2"; }
# jf <file> <python expression on d> — a value of the JSON file, as JSON (a string printed bare)
jf() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); v=eval(sys.argv[2]); print(v if isinstance(v,str) else json.dumps(v, ensure_ascii=False))' "$1" "$2" 2>/dev/null || echo "<unreadable>"; }
mode() { python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.lstat(sys.argv[1]).st_mode)))' "$1" 2>/dev/null; }
fresh_state() { XS=$(fresh)/state; HM=$(fresh)/home; mkdir -p "$HM"; CWD=$(fresh); }
# within <secs> <stdin path> <args...> — the script with stdin from that path, its process group killed after <secs> s;
# prints "<whole seconds taken> <stderr lines>"
within() {
  local secs=$1 in=$2; shift 2
  python3 - "$secs" "$in" "$HM" "$(bare_path nogh)" "$SID" "$XS" "$PLX/scripts/stage-signal.sh" "${CWD:-$TMP}" "$@" 4>&- <<'PY'
import os, signal, subprocess, sys, time
secs, inp, hm, path, sid, xs, script, cwd = sys.argv[1:9]
t0 = time.monotonic()
p = subprocess.Popen(["bash", script] + sys.argv[9:], stdin=open(inp, "rb"), stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, cwd=cwd,
                     env={"HOME": hm, "PATH": path, "CLAUDE_CODE_SESSION_ID": sid, "XDG_STATE_HOME": xs}, start_new_session=True)
try:
    err = p.communicate(timeout=float(secs))[1]
except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL)
    err = p.communicate()[1]
print("%d %d" % (time.monotonic() - t0, len(err.decode("utf-8", "replace").splitlines())))
PY
}
nlines() { if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi; }

fam_shape() {  # [L1] each verb writes the contract's shape at the contract's place
  PLX=$1; fresh_state; local F out rc
  F=$(f "$SID" "$STEM")
  out=$(LS "$SID" spec "$STEM" 2>&1 </dev/null); rc=$?
  eq "$rc" 0 "[L1] spec: rc 0"; empty "$out" "[L1] spec: no output"
  [ -f "$F" ] && ok "[L1] spec: the file is <state>/vibemaestro/sessions/<session>/<stem>.json" || bad "[L1] spec: the file is <state>/vibemaestro/sessions/<session>/<stem>.json"
  eq "$(jf "$F" '" ".join(d)')" "$FIELDS" "[L1] the fields are the sandbox's schema 1 fields and local, in order"
  eq "$(jf "$F" 'd["schema"]')" 1 "[L1] schema 1"
  eq "$(jf "$F" 'd["local"]')" "{\"v\": 1, \"stem\": \"$STEM\", \"agent\": null, \"child\": false}" "[L1] local: v 1, the stem, no agent, not a child"
  eq "$(jf "$F" '[d["state"], d["event"], d["session"], d["hint"], d["question"], d["tail"]]')" "[\"working\", \"stage\", \"$SID\", false, null, null]" "[L1] spec: working, event stage, the session id"
  eq "$(jf "$F" 'd["intents"]["'"$STEM"'"]["stage"], d["intents"]["'"$STEM"'"]["subagents"], d["intents"]["'"$STEM"'"]["text"]')" "[\"spec\", 0, \"$STEM: spec stage started\"]" "[L1] spec: the intent entry with its fixed phrase"
  eq "$(jf "$F" 'd["ts"][:2]+str(type(d["epoch"]).__name__)')" "20int" "[L1] ts and epoch are written"
  LS "$SID" review "$STEM" --subagents 2 </dev/null
  eq "$(jf "$F" 'd["intents"]["'"$STEM"'"]["stage"], d["intents"]["'"$STEM"'"]["subagents"], d["intents"]["'"$STEM"'"]["text"]')" "[\"review\", 2, \"$STEM: review round started\"]" "[L1] review --subagents 2: the stage, the count, its phrase"
  LS "$SID" progress ci-green "$STEM" </dev/null
  eq "$(jf "$F" '[d["state"], d["event"], d["progress"], type(d["progress_epoch"]).__name__]')" "[\"working\", \"progress\", \"$STEM: CI green\", \"int\"]" "[L1] progress ci-green: its fixed phrase and time"
  printf 'SPEC ready: kb/specs/%s.md on intent/%s\n' "$STEM" "$STEM" | LS "$SID" ask "$STEM"
  eq "$(jf "$F" '[d["state"], d["event"], d["source"], d["question"]]')" "[\"waiting\", \"ask\", \"ask\", \"SPEC ready: kb/specs/$STEM.md on intent/$STEM\"]" "[L1] ask: waiting, with the question"
  eq "$(jf "$F" 'd["intents"]["'"$STEM"'"]["stage"]')" review "[L1] ask: the intent entry is kept"
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["source"]="<script>"; json.dump(d,open(p,"w"))' "$F"
  LS "$SID" bind "$STEM" --agent first </dev/null
  eq "$(jf "$F" '[d["state"], d["source"]]')" '["waiting", "ask"]' "[L1] a carried source is not kept: it is ask while waiting"
  printf 'https://example.invalid/o/r/change/7 %s\nchange 7 ready\n' "$(printf 'a%.0s' $(seq 40))" | LS "$SID" done "$STEM"
  eq "$(jf "$F" '[d["state"], d["event"], d["question"], d["source"], d["tail"].split(chr(10))[0]]')" "[\"done\", \"done\", null, null, \"https://example.invalid/o/r/change/7 $(printf 'a%.0s' $(seq 40))\"]" "[L1] done: the report, the question cleared"
  local ep; ep=$(jf "$F" 'd["epoch"]')
  LS "$SID" bind "$STEM" --agent adde064be16b0dacc </dev/null
  eq "$(jf "$F" '[d["state"], d["event"], d["local"]["agent"], d["epoch"]]')" "[\"done\", \"bind\", \"adde064be16b0dacc\", $ep]" "[L1] bind: the agent id, the state and its epoch unchanged"
  LS "$SID" code "$STEM" </dev/null
  eq "$(jf "$F" '[d["state"], d["tail"], d["local"]["agent"]]')" "[\"working\", null, \"adde064be16b0dacc\"]" "[L1] a stage after done: working again, the report cleared, the agent kept"
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["ts"]="<b>x</b>"; d["epoch"]="x"; json.dump(d,open(p,"w"))' "$F"
  LS "$SID" progress tests-pass "$STEM" </dev/null
  eq "$(jf "$F" '[bool(__import__("re").fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", d["ts"])), type(d["epoch"]).__name__]')" '[true, "int"]' "[L1] a carried ts or epoch that is not a time is written anew"
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["ts"]="9999-99-99T99:99:99Z"; json.dump(d,open(p,"w"))' "$F"
  LS "$SID" progress tests-pass "$STEM" </dev/null
  eq "$(jf "$F" 'd["ts"] == __import__("datetime").datetime.fromtimestamp(d["epoch"], __import__("datetime").timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")')" true "[L1] a carried ts that is not its epoch's time is written anew with it"
  # a subagent: its env has the main session's id and CLAUDE_CODE_CHILD_SESSION=1
  CHILD=1 LS "$SID" spec "$STEM2" </dev/null
  eq "$(jf "$(f "$SID" "$STEM2")" '[d["session"], d["local"]["child"], d["local"]["agent"]]')" "[\"$SID\", true, null]" "[L1] a subagent's write lands in its main session's directory, child true, not bound yet"
  LS "$SID" code "$STEM2" </dev/null
  eq "$(jf "$(f "$SID" "$STEM2")" 'd["local"]["child"]')" true "[L1] child stays true when the main session writes the file"
  # the place without XDG_STATE_HOME, and with a relative one
  NOXDG=1 LS "$SID" spec "$STEM" </dev/null
  [ -f "$HM/.local/state/vibemaestro/sessions/$SID/$STEM.json" ] && ok "[L1] without XDG_STATE_HOME: under \$HOME/.local/state" || bad "[L1] without XDG_STATE_HOME: under \$HOME/.local/state"
  rm -rf "$HM/.local"; XDGV=rel/state LS "$SID" spec "$STEM" </dev/null
  [ -f "$HM/.local/state/vibemaestro/sessions/$SID/$STEM.json" ] && ok "[L1] a relative XDG_STATE_HOME is ignored" || bad "[L1] a relative XDG_STATE_HOME is ignored"
  # the stem from the checked-out intent branch
  local A; A=$(mk_origin); git_ -C "$A" checkout -q -b "intent/2026-10-30-from-branch"
  CWD=$A LS "$SID" code </dev/null
  eq "$(jf "$(f "$SID" 2026-10-30-from-branch)" 'd["intents"]["2026-10-30-from-branch"]["stage"]')" code "[L1] the stem comes from the intent branch when left out"
}

fam_text() {  # [L2] the question and the report: stdin only, data, cut
  PLX=$1; fresh_state; local F q long out
  F=$(f "$SID" "$STEM")
  # shellcheck disable=SC2016
  q='Approve? $(touch '"$TMP"'/pwned-q) `touch '"$TMP"'/pwned-b` ; "quoted" \ back'
  printf '%s\n' "$q" | LS "$SID" ask "$STEM"
  eq "$(jf "$F" 'd["question"]')" "$q" "[L2] the question is stored verbatim"
  [ ! -e "$TMP/pwned-q" ] && [ ! -e "$TMP/pwned-b" ] && ok "[L2] …and never run (\$(…) and backticks create no file)" || bad "[L2] …and never run (\$(…) and backticks create no file)"
  printf '  indented first line\n\nsecond line\n\n' | LS "$SID" ask "$STEM"
  eq "$(jf "$F" 'd["question"]')" "$(printf '  indented first line\n\nsecond line')" "[L2] the question is kept as given, less its trailing line ends"
  long=$(python3 -c 'print("Q"*2500)')
  printf '%s' "$long" | LS "$SID" ask "$STEM"
  eq "$(jf "$F" '[len(d["question"]), d["question"][-1]]')" '[2000, "…"]' "[L2] a question is cut to 2000 characters"
  python3 -c 'print("https://example.invalid/o/r/change/7 " + "b"*40); print("R"*800)' | LS "$SID" done "$STEM"
  eq "$(jf "$F" '[len(d["tail"]), d["tail"][-1], d["tail"].startswith("https://example.invalid/o/r/change/7 ")]')" '[500, "…", true]' "[L2] a report is cut to its first 500 characters (the PR line kept)"
  ( set -o pipefail; python3 -c 'print("x"*300000)' | LS "$SID" done "$STEM" ) 2>/dev/null
  eq "$?" 0 "[L2] a 300 KB report through a pipe: the pipeline's rc is 0 (the rest of stdin is read, no SIGPIPE)"
  local fifo r; fifo=$(fresh)/in; mkfifo "$fifo"; exec 4<>"$fifo"
  r=$(within 15 "$fifo" ask "$STEM"); exec 4>&-
  [ "${r% *}" -lt 9 ] && ok "[L2] a stdin that stays open and silent: refused within the wait, with no timeout on the PATH" || bad "[L2] a stdin that stays open and silent: refused within the wait, with no timeout on the PATH (${r% *} s)"
  eq "${r#* }" 1 "[L2] …one stderr line says so"
  rm -rf "$XS"; r=$(within 15 /dev/zero done "$STEM")
  [ "${r% *}" -lt 9 ] && ok "[L2] an endless stdin: the read stops at its cap, with no timeout on the PATH" || bad "[L2] an endless stdin: the read stops at its cap, with no timeout on the PATH (${r% *} s)"
  eq "${r#* }" 0 "[L2] …it is not refused (the cap ends it, not the deadline)"
  eq "$(jf "$F" '[d["state"], len(d["tail"]), d["tail"][0] == chr(0)]')" '["done", 500, true]' "[L2] …and its report is recorded, cut"
  # a stdin that trickles one byte a second never ends: the whole read has one deadline
  local tp; fifo=$(fresh)/in; mkfifo "$fifo"; exec 4<>"$fifo"
  python3 -c 'import sys,time
f=open(sys.argv[1],"w")
for _ in range(30): f.write("x"); f.flush(); time.sleep(1)' "$fifo" 4>&- & tp=$!
  r=$(within 15 "$fifo" ask "$STEM"); kill "$tp" 2>/dev/null; wait "$tp" 2>/dev/null; exec 4>&-
  [ "${r% *}" -lt 9 ] && ok "[L2] a trickling stdin: refused within the wait, with no timeout on the PATH" || bad "[L2] a trickling stdin: refused within the wait, with no timeout on the PATH (${r% *} s)"
  eq "${r#* }" 1 "[L2] …one stderr line says so"
  rm -rf "$XS"; out=$(LS "$SID" ask "$STEM" "a question as an argument" 2>&1 </dev/null)
  [ ! -e "$F" ] && ok "[L2] a text given as an argument is not recorded" || bad "[L2] a text given as an argument is not recorded"
  eq "$(nlines "$out")" 1 "[L2] …one stderr line says so"
}

fam_isolation() {  # [L3] one file per session and stem
  PLX=$1; fresh_state; local a b
  LS "$SID" spec "$STEM" </dev/null; LS "$SID" code "$STEM2" </dev/null; LS "$SID2" ship "$STEM" </dev/null
  eq "$(jf "$(f "$SID" "$STEM")" 'd["intents"]["'"$STEM"'"]["stage"]')" spec "[L3] two stems of one session: the first file keeps its stage"
  eq "$(jf "$(f "$SID" "$STEM2")" 'd["intents"]["'"$STEM2"'"]["stage"]')" code "[L3] …and the second has its own"
  eq "$(jf "$(f "$SID2" "$STEM")" '[d["session"], d["intents"]["'"$STEM"'"]["stage"]]')" "[\"$SID2\", \"ship\"]" "[L3] two sessions with one stem: two files, each with its session"
  a=$(cat "$(f "$SID" "$STEM")"); LS "$SID2" code "$STEM" </dev/null; b=$(cat "$(f "$SID" "$STEM")")
  eq "$b" "$a" "[L3] a write of another session leaves this session's file byte for byte"
}

fam_files() {  # [L4] mode, atomic write, links
  PLX=$1; fresh_state; local D out tgt
  LS "$SID" spec "$STEM" </dev/null; LS "$SID" code "$STEM" </dev/null
  D="$XS/vibemaestro/sessions/$SID"
  eq "$(mode "$D/$STEM.json")" 0o600 "[L4] the file is mode 0600"
  eq "$(mode "$D")" 0o700 "[L4] the session directory is mode 0700"
  eq "$(find "$D" -name '*.tmp.*' | wc -l | tr -d ' ')" 0 "[L4] no temp file is left"
  eq "$(cd "$D" && ls | sort | tr '\n' ' ')" "$STEM.json $STEM.lock " "[L4] the directory holds the file and its lock only"
  # a session directory that is a link
  tgt=$(fresh); mkdir -p "$XS/vibemaestro/sessions"; ln -s "$tgt" "$XS/vibemaestro/sessions/$SID2"
  out=$(LS "$SID2" spec "$STEM" 2>&1 </dev/null)
  eq "$(ls -A "$tgt" | wc -l | tr -d ' ')" 0 "[L4] a linked session directory is refused: nothing written through it"
  eq "$(nlines "$out")" 1 "[L4] …one stderr line says so"
  # temp files left by killed writers: cleared under the lock, another pid's and the writer's own (the shell plants it, then execs)
  printf 'stale' > "$D/.$STEM.json.tmp.0"
  ( cd "$CWD" && env -i HOME="$HM" PATH="$(bare_path nogh)" CLAUDE_CODE_SESSION_ID="$SID" XDG_STATE_HOME="$XS" \
      bash -c 'printf stale > "$1/.$2.json.tmp.$$"; exec python3 -I -B "$3/scripts/local_state.py" ship "$2"' _ "$D" "$STEM" "$PLX" </dev/null )
  eq "$(jf "$D/$STEM.json" 'd["intents"]["'"$STEM"'"]["stage"]')" ship "[L4] a stale temp file of the writer's pid does not block the write"
  [ ! -e "$D/.$STEM.json.tmp.0" ] && ok "[L4] a stale temp file of another pid is cleared" || bad "[L4] a stale temp file of another pid is cleared"
  # a sessions directory that is a link
  local XS1; XS1=$XS; XS=$(fresh)/state; tgt=$(fresh); mkdir -p "$XS/vibemaestro"; ln -s "$tgt" "$XS/vibemaestro/sessions"
  out=$(LS "$SID" spec "$STEM" 2>&1 </dev/null)
  eq "$(find "$tgt" -type f | wc -l | tr -d ' ')" 0 "[L4] a linked sessions directory is refused: nothing written through it"
  eq "$(nlines "$out")" 1 "[L4] …one stderr line says so"
  XS=$(fresh)/state; tgt=$(fresh); mkdir -p "$XS"; ln -s "$tgt" "$XS/vibemaestro"
  out=$(LS "$SID" spec "$STEM" 2>&1 </dev/null)
  eq "$(find "$tgt" -type f | wc -l | tr -d ' ')" 0 "[L4] a linked vibemaestro directory is refused: nothing written through it"
  eq "$(nlines "$out")" 1 "[L4] …one stderr line says so"
  XS=$XS1
  # a target that is a link
  tgt=$(fresh)/elsewhere.json; echo keep > "$tgt"; rm -f "$D/$STEM.json"; ln -s "$tgt" "$D/$STEM.json"
  out=$(LS "$SID" code "$STEM" 2>&1 </dev/null)
  eq "$(cat "$tgt")" keep "[L4] a linked target is refused: the file it points to is unchanged"
  [ -L "$D/$STEM.json" ] && ok "[L4] …and the link is not replaced" || bad "[L4] …and the link is not replaced"
  eq "$(nlines "$out")" 1 "[L4] …one stderr line says so"
}

# refused <label> <session> <stdin text|-> <args...> — rc 0, one stderr line, no file anywhere under the state directory
refused() {
  local label=$1 sid=$2 in=$3 out rc; shift 3; rm -rf "$XS"
  if [ "$in" = - ]; then out=$(LS "$sid" "$@" 2>&1 </dev/null); rc=$?; else out=$(printf '%s' "$in" | LS "$sid" "$@" 2>&1); rc=$?; fi
  eq "$rc" 0 "[L5] $label: rc 0"
  eq "$(nlines "$out")" 1 "[L5] $label: one stderr line"
  eq "$(find "$XS" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')" 0 "[L5] $label: nothing written"
}
fam_refusals() {  # [L5] a refusal never fails the caller and writes nothing
  PLX=$1; fresh_state; local out rc ready pid D
  refused "a bad stem" "$SID" - spec 'My Stem'
  refused "a stem that is not <date>-<slug>" "$SID" - spec my-intent
  refused "an unknown step" "$SID" - progress deployed "$STEM"
  refused "a bad agent id" "$SID" - bind "$STEM" --agent 'a/b'
  refused "bind without its stem" "$SID" - bind --agent abc
  refused "a bad session id" '../../x' - spec "$STEM"
  refused "an empty question" "$SID" '   ' ask "$STEM"
  refused "an unknown verb" "$SID" - deploy "$STEM"
  refused "--subagents over 99" "$SID" - review "$STEM" --subagents 100
  rm -rf "$XS"; out=$(LS - spec "$STEM" 2>&1 </dev/null); rc=$?
  eq "$rc" 0 "[L5] no CLAUDE_CODE_SESSION_ID: rc 0"; empty "$out" "[L5] no CLAUDE_CODE_SESSION_ID: silent"
  [ ! -e "$XS" ] && ok "[L5] no CLAUDE_CODE_SESSION_ID: nothing written" || bad "[L5] no CLAUDE_CODE_SESSION_ID: nothing written"
  # another writer holds the lock
  rm -rf "$XS"; D="$XS/vibemaestro/sessions/$SID"; mkdir -p "$D"; ready=$(fresh)/ready
  python3 -c 'import fcntl,os,sys,time; fd=os.open(sys.argv[1], os.O_WRONLY|os.O_CREAT, 0o600); fcntl.flock(fd, fcntl.LOCK_EX); open(sys.argv[2],"w").close(); time.sleep(8)' "$D/$STEM.lock" "$ready" &
  pid=$!
  while [ ! -e "$ready" ]; do :; done
  out=$(LS "$SID" spec "$STEM" 2>&1 </dev/null); rc=$?
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  eq "$rc" 0 "[L5] a held lock: rc 0"; eq "$(nlines "$out")" 1 "[L5] a held lock: one stderr line"
  [ ! -e "$D/$STEM.json" ] && ok "[L5] a held lock: nothing written" || bad "[L5] a held lock: nothing written"
}

# [L6] the suites' clean environment: a suite run from inside a Claude Code session (CLAUDE_CODE_SESSION_ID, CLAUDE_CODE_CHILD_SESSION and
# XDG_STATE_HOME set) that calls the script without `cenv` writes nothing under the session's real state directory.
# A child suite sources the fixtures in $FXD (the real ones, or a broken copy), runs clean_env, then the script with its inherited env.
FXD="$HERE/fixtures"
fam_suite_env() {
  PLX=$1; local real child out
  real=$(fresh)/real-state; mkdir -p "$real"; child=$(fresh)/child.sh
  cat > "$child" <<'CHILD'
set -u
. "$1/lib.sh"; . "$1/ports.sh"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P); trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
PATH="$(bare_path nogh)" bash "$2/scripts/stage-signal.sh" spec 2026-10-30-suite-env </dev/null
PATH="$(bare_path nogh)" bash "$2/scripts/stage-signal.sh" ask 2026-10-30-suite-env <<<'a test question'
CHILD
  out=$(env CLAUDE_CODE_SESSION_ID=s-real CLAUDE_CODE_CHILD_SESSION=1 XDG_STATE_HOME="$real" bash "$child" "$FXD" "$PLX" 2>&1)
  eq "$(find "$real" -type f | wc -l | tr -d ' ')" 0 "[L6] a suite run inside a session writes nothing under the real state directory"
  empty "$out" "[L6] …and the signal says nothing there (no session id reaches it)"
}

FAMILIES="fam_shape fam_text fam_isolation fam_files fam_refusals fam_suite_env"

echo "== the real scripts =="
PL0="$TMP/plugin-real"; mk_plugin_copy "$PL0"
[ -f "$PL0/scripts/local_state.py" ] && ok "instrument: the plugin copy has the writer" || bad "instrument: the writer is missing from the copy"
for fm in $FAMILIES; do echo "-- $fm"; "$fm" "$PL0"; done

echo "== planted breaks: each family must go red on a copy with one break =="
BRK() {  # BRK <label> <family> <needle> <script> <old> <new>
  local d="$TMP/break-$1"; mk_plugin_copy "$d"
  mutate "$d/scripts/$4" "$5" "$6" && expect_red "$1" "$2" "$d" "$3"
}
BRK mode-wide fam_files '[L4] the file is mode 0600' local_state.py 'os.fchmod(f.fileno(), 0o600)' 'os.fchmod(f.fileno(), 0o644)'
BRK temp-left fam_files '[L4] no temp file is left' local_state.py '        os.replace(tmp, path)' '        os.link(tmp, path) if not os.path.exists(path) else os.replace(tmp, path); open(tmp, "w").close()'
BRK stale-temp-blocks fam_files '[L4] a stale temp file of the writer' local_state.py '            os.unlink(old)                       # a writer killed' '            0 and os.unlink(old)                 # a writer killed'
BRK stale-temp-own-pid fam_files '[L4] a stale temp file of another pid' local_state.py '".%s.json.tmp.*" % stem' '".%s.json.tmp.%d" % (stem, os.getpid())'
BRK top-link-followed fam_files '[L4] a linked vibemaestro directory' local_state.py 'if os.path.islink(top) or os.path.islink(base):' 'if os.path.islink(base):'
BRK stdin-no-deadline fam_text '[L2] a trickling stdin' local_state.py 'if left <= 0 or not select.select([fd], [], [], left)[0]:' 'if not select.select([fd], [], [], STDIN_WAIT)[0]:'
BRK drain-uncapped fam_text '[L2] …it is not refused (the cap ends it' local_state.py '    while n <= DRAIN_MAX:' '    while True:'
BRK stdin-no-wait fam_text '[L2] a stdin that stays open and silent' local_state.py 'if left <= 0 or not select.select([fd], [], [], left)[0]:' 'if False:'
BRK source-carried fam_shape '[L1] a carried source' local_state.py '(text if verb == "ask" else c.get("question")), "ask"' '(text if verb == "ask" else c.get("question")), c.get("source")'
BRK ts-pair-kept fam_shape '[L1] a carried ts that is not its epoch' local_state.py 'renew = changed or integer(c.get("epoch")) is None or c.get("ts") != ts_text(c.get("epoch"))' 'renew = changed or integer(c.get("epoch")) is None'
BRK sessions-link-followed fam_files '[L4] a linked sessions directory' local_state.py 'if os.path.islink(top) or os.path.islink(base):' 'if os.path.islink(top):'
BRK text-stripped fam_text '[L2] the question is kept as given' local_state.py '.decode("utf-8", "replace").rstrip("\r\n")' '.decode("utf-8", "replace").strip()'
BRK stdin-undrained fam_text '[L2] a 300 KB report' local_state.py '        if not chunk:' '        if not chunk or n:'
BRK link-followed fam_files '[L4] a linked session directory is refused' local_state.py 'if not os.path.isdir(d) or os.path.islink(d) or' 'if not os.path.isdir(d) or'
BRK cut-long fam_text '[L2] a question is cut to 2000 characters' local_state.py 'QUESTION_MAX = 2000' 'QUESTION_MAX = 20000'
BRK report-tail fam_text '[L2] a report is cut to its first 500' local_state.py '    return s if len(s) <= n else s[: n - 1] + "…"' '    return s if len(s) <= n else "…" + s[-(n - 1):]'
BRK one-dir fam_isolation '[L3] two sessions with one stem' local_state.py '    d = os.path.join(base, session)' '    d = os.path.join(base, "all")'
BRK child-lost fam_shape '[L1] child stays true' local_state.py 'child = loc.get("child") is True or os.environ' 'child = os.environ'
BRK bind-moves-state fam_shape '[L1] bind: the agent id, the state' local_state.py '"bind": c.get("state", "working")}' '"bind": "working"}'
BRK refusal-fails fam_refusals '[L5] a bad stem: rc 0' stage-signal.sh '    exit 0 # local: the signal never fails the caller' '    exit 1'
# the clean environment broken: a copy of the fixtures whose clean_env keeps the session's variables
FXB="$TMP/fixtures-break"; cp -R "$HERE/fixtures" "$FXB"
if mutate "$FXB/lib.sh" '  unset CLAUDE_CODE_SESSION_ID CLAUDE_CODE_CHILD_SESSION' '  :'; then
  mutate "$FXB/lib.sh" '  export XDG_STATE_HOME="$HOME/.local/state"' '  :' \
    && { FXD=$FXB; expect_red suite-env-kept fam_suite_env "$PL0" '[L6] a suite run inside a session writes nothing'; FXD="$HERE/fixtures"; }
fi
PLC="$TMP/break-none"; mk_plugin_copy "$PLC"
QN=0; okdef=$(declare -f ok); baddef=$(declare -f bad); sp=$PASS; sf=$FAIL
ok() { :; }; bad() { QN=$((QN+1)); }
for fm in $FAMILIES; do "$fm" "$PLC" >/dev/null 2>&1; done
eval "$okdef"; eval "$baddef"; PASS=$sp; FAIL=$sf
eq "$QN" 0 "control: an unbroken copy passes every family (no failed check)"

echo; summary
