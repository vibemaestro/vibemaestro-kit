#!/bin/bash
# =============================================================================
# capped: a planted-break run is under a memory cap and a wall-time cap (tests/fixtures/capped.sh)
# =============================================================================
# Run: bash tests/test-capped-breaks.sh
#
# [A] the helper: a break that allocates past the cap is red by the memory cap within seconds and the next family still runs; one that
#     sleeps past the time cap, one that forks children, one that detaches a child with setsid are red by the time cap and leave no process
#     behind; children that each stay under the cap but together pass it are red by the memory cap; a control break that does neither keeps
#     its own exit code and output; the PLANT_CAP_* overrides and 0 work; cap_red; PLANT_CAP_LOG.
# [B] where the tool is missing: no `ps` (the memory cap says it is not enforced, the time cap holds); no `ulimit -v` (the backstop case
#     says SKIP, loudly).
# [H] plant_break (fixtures/plant.sh): red, green, an anchor not there once, a hang capped, -B added to python3 -I, no copy left.
# [L] the lint for what plant_break cannot make impossible: [L1] a suite's own planted-break helper reaches capped; [L2] no
#     python3 -I without -B. Planted offenders first, so a lint that stops matching turns this suite red.
# Caps are small here (a few hundred MB, a few seconds); the defaults (1024 MB, 600 s) are in the header of capped.sh.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"

UNIQ=$((RANDOM % 900 + 100))   # sleeps below are 3<UNIQ>.x seconds, so the leftover scan names only this run's processes
left() { ps -eo args= | grep -c "^sleep 3$UNIQ\.$1" || true; }
now() { date +%s; }

# a shell function that allocates for ever, in 10 MB steps, and one family-shaped function that only reports
alloc_family() { python3 -c 'import time
x = []
while True:
    x.append(bytearray(b"1" * 10_000_000))
    time.sleep(0.01)'; }
quiet_family() { echo "family output"; return 3; }

echo "== [A] memory cap =="
t0=$(now); out=$(PLANT_CAP_MEM_MB=200 PLANT_CAP_SECS=60 capped alloc_family 2>&1); rc=$?; t1=$(now)
eq "$rc" 248 "a function that allocates past the cap: rc 248"
has "$out" "cap hit: memory 200MB" "…and the run prints which cap was hit"
[ $((t1 - t0)) -lt 10 ] && ok "…within seconds ($((t1 - t0)) s), far below the time cap" || bad "…took $((t1 - t0)) s"
# the harness keeps going: a family list where the second family is the one that allocates
ran=""
for fam in quiet_family alloc_family quiet_family; do
  out=$(PLANT_CAP_MEM_MB=200 capped "$fam" 2>&1); rc=$?
  ran="$ran $fam:$rc"
done
eq "$ran" " quiet_family:3 alloc_family:248 quiet_family:3" "a capped family does not stop the next one: it runs and keeps its own code"

# the same through a child process (an external command), and through four children that each stay under the cap
# the command holds its 1 GB for 4 s (16 polls of 0.25 s) so the watchdog always samples it: the outcome does not depend on the poll;
# a cap that does not fire ends the command by itself after 4 s with rc 0, red here and not by luck
t0=$(now); PLANT_CAP_MEM_MB=200 capped python3 -c 'import time; x = [bytearray(b"1" * 10_000_000) for _ in range(100)]; time.sleep(4)' >/dev/null 2>&1; rc=$?; t1=$(now)
eq "$rc" 248 "an external command that builds a 1 GB list: rc 248"
[ $((t1 - t0)) -lt 10 ] && ok "…in $((t1 - t0)) s" || bad "…took $((t1 - t0)) s"
PLANT_CAP_MEM_MB=250 capped bash -c 'for i in 1 2 3 4; do python3 -c "import time; x = bytearray(b\"1\" * 100_000_000); time.sleep(20)" & done; wait' >/dev/null 2>&1; rc=$?
eq "$rc" 248 "four children of 100 MB each, together past a 250 MB cap: rc 248 (the sum, not each one)"
PLANT_CAP_MEM_MB=0 capped python3 -c 'x = bytearray(b"1" * 300_000_000)' >/dev/null 2>&1; rc=$?
eq "$rc" 0 "PLANT_CAP_MEM_MB=0 switches the memory cap off (300 MB goes through)"

echo "== [A] time cap =="
t0=$(now); out=$(PLANT_CAP_SECS=2 capped sleep "3$UNIQ.1" 2>&1); rc=$?; t1=$(now)
eq "$rc" 247 "a command that sleeps past the time cap: rc 247"
has "$out" "cap hit: wall time 2s" "…and the run prints which cap was hit"
[ $((t1 - t0)) -le 4 ] && ok "…at the cap ($((t1 - t0)) s)" || bad "…after $((t1 - t0)) s"
PLANT_CAP_SECS=2 capped bash -c "sleep 3$UNIQ.2 & sleep 3$UNIQ.2 & (sleep 3$UNIQ.2 &); wait" >/dev/null 2>&1; rc=$?
eq "$rc" 247 "a break that forks children: rc 247"
sleep 0.3; eq "$(left 2)" 0 "…and no child is left"
if command -v setsid >/dev/null 2>&1; then
  PLANT_CAP_SECS=2 capped bash -c "setsid sleep 3$UNIQ.3 & wait" >/dev/null 2>&1; rc=$?
  eq "$rc" 247 "a break whose child leaves the process group with setsid: rc 247"
  sleep 0.3; eq "$(left 3)" 0 "…and that child is killed too (the descendant walk)"
else
  echo "  SKIP *** no setsid: the detached-child case DID NOT RUN ***"
fi
PLANT_CAP_SECS=0 capped sleep 1 >/dev/null 2>&1; rc=$?
eq "$rc" 0 "PLANT_CAP_SECS=0 switches the time cap off (a 1 s sleep ends by itself)"
out=$(PLANT_CAP_SECS=1 capped bash -c 'sleep 30' 2>&1); rc=$?
has "$out" "wall time 1s" "the override is read at each call (1 s)"

echo "== [A] what a run leaves behind =="
t0=$(now); out=$(PLANT_CAP_SECS=2 capped bash -c "exec -a orph sleep 3$UNIQ.7 & echo hi" 2>&1); rc=$?; t1=$(now)
eq "$out" "hi" "an orphan left by a run that ends by itself: the capture ends with the run's own output"
[ $((t1 - t0)) -le 2 ] && ok "…at once ($((t1 - t0)) s), not when the orphan ends (it sleeps 3$UNIQ.7 s)" || bad "…took $((t1 - t0)) s: the orphan held the capture open"
sleep 0.3; eq "$(left 7)" 0 "…and the orphan is killed"
PLANT_CAP_MEM_MB=200 PLANT_CAP_SECS=20 capped bash -c 'python3 -c "import os,time
if os.fork() == 0:
    os.setsid()
    if os.fork() == 0:
        x = bytearray(b\"1\" * 400_000_000); time.sleep(30)
    os._exit(0)"; sleep 8' >/dev/null 2>&1; rc=$?
eq "$rc" 248 "a daemon (double fork + setsid) that holds 400 MB past a 200 MB cap: rc 248 (found through the run's token)"
sleep 0.3; eq "$(ps -eo args= | grep -c '^python3 -c import os,time')" 0 "…and the daemon is killed"
if command -v setsid >/dev/null 2>&1; then
  PLANT_CAP_SECS=2 capped bash -c "trap '' TERM INT HUP; for i in 1 2 3 4 5 6; do setsid -f bash -c 'exec -a nohup-race sleep 3$UNIQ.8' ; done; sleep 30" >/dev/null 2>&1; rc=$?
  eq "$rc" 247 "six setsid -f children and a TERM-ignoring parent: rc 247"
  sleep 0.3; eq "$(left 8)" 0 "…and none of the six is left"
fi

echo "== [A] sibling runs: the cleanup of one run never reaches another =="
# sib <capped.sh> — two capped runs side by side from `( … ) &` subshells, the shape of tests/test-hub-shaped-flow.sh's faulty runs:
# `short` ends while `long` is inside its second step; prints every step's code. Seen on CI as one step of a sibling ended 137.
sib() {
  bash -c '. "$1"
flow() { python3 -c "import sys, time; time.sleep(float(sys.argv[1]))" "$1"; echo "$2-a $?"; python3 -c "import sys, time; time.sleep(float(sys.argv[1]))" "$3"; echo "$2-b $?"; }
( capped flow 0.1 short 0.1 ) & ( capped flow 0.1 long 2 ) & wait' _ "$1" 2>/dev/null | sort | tr '\n' ' '
}
# planted <name> <old> <new> — writes $TMP/capped-<name>.sh, capped.sh with one text replaced; rc 1 and a FAIL when <old> is not there once
planted() {
  python3 -c 'import sys
src, dst, old, new = sys.argv[1:5]
s = open(src).read()
sys.exit(1) if s.count(old) != 1 else open(dst, "w").write(s.replace(old, new))' "$HERE/fixtures/capped.sh" "$TMP/capped-$1.sh" "$2" "$3" \
    || { bad "planted $1: the text to replace is not in capped.sh once"; return 1; }
}
eq "$(sib "$HERE/fixtures/capped.sh")" "long-a 0 long-b 0 short-a 0 short-b 0 " "two sibling runs: every step of both ends by itself"
toks=$(bash -c '. "$1"; ( capped sh -c "echo \$CAPPED_RUN" ) & ( capped sh -c "echo \$CAPPED_RUN" ) & wait' _ "$HERE/fixtures/capped.sh" | sort -u | wc -l | tr -d ' ')
eq "$toks" 2 "…and their tokens differ"
if [ -d /proc/self ]; then
  if planted shared-token 'tok="${BASHPID:-$$}.${mark##*/}"' 'tok=shared'; then
    eq "$(sib "$TMP/capped-shared-token.sh")" "long-a 0 long-b 137 short-a 0 short-b 0 " \
      "…planted: one token for both runs → the first to end SIGKILLs the other's step (137), the CI signature"
  fi
  CAPPED_RUN="t$UNIQ.1" sleep "3$UNIQ.2" & a=$!; CAPPED_RUN="t$UNIQ.12" sleep "3$UNIQ.2" & b=$!; sleep 0.3
  eq "$(_cap_sweep "t$UNIQ.1" | tr '\n' ' ')" "$a " "the token sweep takes the exact token, not a longer one that starts with it"
  kill "$a" "$b" 2>/dev/null; { wait "$a" "$b"; } 2>/dev/null
else
  echo "  SKIP *** no /proc: the token checks (shared token, exact sweep) DID NOT RUN ***"
fi
out=$(bash -c 'unset BASHPID; set -u; . "$1"; capped echo hi' _ "$HERE/fixtures/capped.sh" 2>&1)
eq "$out" "hi" "no BASHPID (bash 3.2) under set -u: capped still runs"

echo "== [A] the arguments and the environment of the caps =="
out=$(PLANT_CAP_SECS=2s capped sleep 1 2>&1); rc=$?
eq "$rc" 2 "a cap that is not a whole number (2s) is refused: rc 2"; has "$out" "whole numbers" "…with a message"
out=$(PLANT_CAP_MEM_MB=1g bash -c ". '$HERE/fixtures/capped.sh'; echo sourced" 2>&1); rc=$?
eq "$rc" 2 "an exported PLANT_CAP_MEM_MB=1g stops the suite at source time: rc 2"; hasnt "$out" "sourced" "…before anything runs"
out=$(capped true <&- 2>&1); rc=$?
eq "$rc" 0 "a closed stdin: the command still runs (rc 0)"; empty "$out" "…and says nothing"
t0=$SECONDS; PLANT_CAP_SECS=3 capped sleep "3$UNIQ.9" >/dev/null 2>&1; t1=$SECONDS
[ $((t1 - t0)) -ge 3 ] && ok "a 3 s time cap does not fire early ($((t1 - t0)) s)" || bad "a 3 s time cap fired after $((t1 - t0)) s"
H="$TMP/hits"; rm -f "$TMPDIR/.cap-hits"
PLANT_CAP_SECS=1 capped sleep "3$UNIQ.9" >/dev/null 2>&1; PLANT_CAP_SECS=1 capped sleep "3$UNIQ.9" >/dev/null 2>&1; capped true
eq "$(wc -l < "$TMPDIR/.cap-hits" | tr -d ' ')" 2 "each cap hit is counted in .cap-hits (two hits, one clean run)"
RV=SUITE_RESULTS; RV="${RV}_DIR"   # built at runtime (a rule of the deleted suite-independence suite)
SUM=$(env -u "$RV" bash -c ". '$HERE/fixtures/lib.sh'; TMPDIR='$TMPDIR'; summary" 2>&1 | grep -c "note: 2 planted run(s) ended by a cap")
eq "$SUM" 1 "summary prints how many runs ended by a cap"

echo "== [A] a control break stays judged on its own result =="
out=$(capped quiet_family 2>&1); rc=$?
eq "$rc" 3 "a function that exits 3: rc 3"; eq "$out" "family output" "…its output, byte for byte, and no cap line"
out=$(capped bash -c 'echo to-out; echo to-err >&2; exit 0' 2>&1); rc=$?
eq "$rc" 0 "a command that exits 0: rc 0"; eq "$out" $'to-out\nto-err' "…stdout and stderr both pass through"
out=$(capped bash -c 'printf "%s" "$0"' kept-arg); eq "$out" kept-arg "arguments reach the command"
out=$(capped python3 -c 'import sys; sys.stdout.write(sys.stdin.read())' <<< "stdin kept"); eq "$out" "stdin kept" "stdin reaches the command"
cap_red 0 "x" >/dev/null; eq "$?" 1 "cap_red: rc 0 is not a cap"
cap_red 1 "x" >/dev/null; eq "$?" 1 "cap_red: rc 1 is not a cap"
cap_red 3 "x" >/dev/null; eq "$?" 1 "cap_red: rc 3 is not a cap"
o=$(cap_red 247 "break [t]"); eq "$?" 0 "cap_red 247: returns 0"; has "$o" "break [t]: red by the time cap" "…and says which cap"
o=$(cap_red 248 "break [m]"); eq "$?" 0 "cap_red 248: returns 0"; has "$o" "break [m]: red by the memory cap" "…and says which cap"

echo "== [A] the log =="
LOGF="$TMP/cap.log"
PLANT_CAP_LOG="$LOGF" capped bash -c 'sleep 0.6; exit 4' >/dev/null 2>&1
PLANT_CAP_LOG="$LOGF" PLANT_CAP_SECS=1 capped sleep "3$UNIQ.4" >/dev/null 2>&1
eq "$(wc -l < "$LOGF" | tr -d ' ')" 2 "PLANT_CAP_LOG: one line per capped run"
eq "$(awk 'NR==1{print $1}' "$LOGF")" 4 "…the exit code of the first"
eq "$(awk 'NR==2{print $1}' "$LOGF")" 247 "…the cap code of the second"
[ "$(awk 'NR==1{print $2}' "$LOGF")" -gt 0 ] 2>/dev/null && ok "…a peak above 0 MB ($(awk 'NR==1{print $2}' "$LOGF") MB)" || bad "…no peak in: $(cat "$LOGF")"

echo "== [A] the backstop (PLANT_CAP_VMEM_MB, ulimit -v) =="
if ( ulimit -v 4000000 ) 2>/dev/null; then
  out=$(PLANT_CAP_VMEM_MB=300 capped python3 -c 'import mmap; mmap.mmap(-1, 2_000_000_000)' 2>&1); rc=$?
  ne "$rc" 0 "a 2 GB mapping under a 300 MB address-space limit fails (rc $rc)"
  hasnt "$out" "cap hit" "…as the program's own failure, not labelled as a cap"
  PLANT_CAP_VMEM_MB=0 capped python3 -c 'import mmap; mmap.mmap(-1, 2_000_000_000)' >/dev/null 2>&1; eq "$?" 0 "without the backstop the same mapping works (virtual only, nothing touched)"
else
  echo "  SKIP *** ulimit -v does not work in this shell: the backstop case DID NOT RUN ***"
  out=$(PLANT_CAP_VMEM_MB=300 capped true 2>&1); has "$out" "ulimit -v is not available" "…and the helper says so"
fi

echo "== [B] where a tool is missing =="
NOPS="$TMP/no-ps"; mkdir -p "$NOPS"
for c in bash sh sleep kill awk mktemp cat cut sed head rm date python3 env true; do p=$(command -v "$c") && ln -sf "$p" "$NOPS/$c"; done
out=$(PATH="$NOPS" PLANT_CAP_MEM_MB=200 PLANT_CAP_SECS=2 bash -c ". '$HERE/fixtures/capped.sh'; capped sleep 3$UNIQ.5" 2>&1); rc=$?
eq "$rc" 247 "without ps the time cap still holds (rc 247)"
has "$out" "memory cap is not enforced here" "…and the missing memory cap is said, not silent"
eq "$(printf '%s\n' "$out" | grep -c "not enforced here")" 1 "…once, not at every poll"
out=$(PATH="$NOPS" PLANT_CAP_MEM_MB=0 PLANT_CAP_SECS=2 bash -c ". '$HERE/fixtures/capped.sh'; capped sleep 3$UNIQ.6" 2>&1)
hasnt "$out" "not enforced" "with the memory cap off nothing is said about it"

echo "== [A] cost =="
t0=$(date +%s%N 2>/dev/null || echo 0)
for i in 1 2 3 4 5 6 7 8 9 10; do capped true; done
t1=$(date +%s%N 2>/dev/null || echo 0)
if [ "$t0" != 0 ] && [ "$t1" -gt "$t0" ]; then
  ms=$(( (t1 - t0) / 10000000 ))
  [ "$ms" -lt 500 ] && ok "a capped run of a command that ends at once costs $ms ms" || bad "a capped no-op costs $ms ms"
fi

# ── [H] plant_break (fixtures/plant.sh): one planted break, run the one way ─────────────────────────────────────────
echo "== [H] plant_break =="
H="$TMP/h-tree"; mkdir -p "$H"
printf 'a = 1\n' > "$H/f.txt"
printf 'X = 1\n' > "$H/mod.py"
printf '%s\n' '# an import from the copy: with -B no __pycache__ appears next to it' 'import os, sys' \
  'here = os.path.dirname(os.path.abspath(__file__))' 'sys.path.insert(0, here)' 'import mod' \
  'print("RESULT 1 0" if os.path.isdir(os.path.join(here, "__pycache__")) else "RESULT 0 1")' > "$H/run.py"
judge() { sh -c 'if grep -q "a = 2" "$1/f.txt"; then echo "  FAIL h x: y"; echo "RESULT 0 1"; else echo "RESULT 1 0"; fi' judge "$1"; }
out=$(plant_break "h-red" "$H" f.txt 'a = 1' 'a = 2' -- judge @COPY@)
has "$out" "ok   planted h-red: red (1 failing case(s))" "[H] a family red on the copy is ok"
out=$(plant_break "h-green" "$H" f.txt 'a = 1' 'a = 3' -- judge @COPY@)
has "$out" "FAIL planted h-green: stayed green" "[H] a family green on the copy is a FAIL"
out=$(plant_break "h-gone" "$H" f.txt 'b = 1' 'b = 2' -- judge @COPY@)
has "$out" "the planted text occurs 0 times, not once" "[H] an anchor not there once is a FAIL that says why"
out=$(plant_break "h-same" "$H" f.txt 'a = 1' 'a = 1' -- judge @COPY@)
has "$out" "the planted text and its replacement are the same" "[H] a mutation that changes nothing is a FAIL"
out=$(PLANT_CAP_SECS=1 plant_break "h-hang" "$H" f.txt 'a = 1' 'a = 2' -- sleep "3$UNIQ.7")
has "$out" "ok   planted h-hang: red by the time cap" "[H] a break that hangs is red by the time cap"
eq "$(left 7)" 0 "[H] …and its sleep is gone"
out=$(plant_break "h-bytecode" "$H" run.py '# an import' '# the import' -- python3 -I @COPY@/run.py)
has "$out" "ok   planted h-bytecode: red" "[H] python3 -I in the command runs with -B: no __pycache__ next to the imported module"
out=$(cd "$H" && python3 -I run.py); rm -rf "${H:?}/__pycache__"
eq "$out" "RESULT 1 0" "[H] control: the same python3 -I without plant_break writes __pycache__ (the check above sees -B)"
eq "$(ls -d "$TMPDIR"/plant.* 2>/dev/null | wc -l | tr -d ' ')" 0 "[H] every copy is removed when its break ends, red, green or capped"
[ "$(cat "$H/f.txt")" = "a = 1" ] && ok "[H] the source tree is untouched" || bad "[H] the source tree changed"
mkdir -p "$TMP/a&b"
out=$(TMPDIR="$TMP/a&b" plant_break "h-amp" "$H" f.txt 'a = 1' 'a = 2' -- judge @COPY@)
has "$out" "ok   planted h-amp: red" "[H] @COPY@ is replaced literally, also in a path with \`&\`"
out=$(plant_break "h-norun" "$H" f.txt 'a = 1' 'a = 2' -- false @COPY@)
has "$out" "the command gave no RESULT line" "[H] a command that never ran its family is a FAIL that says so, not \"stayed green\""

# ── [L] the lint: what plant_break cannot make impossible ─────────────────────────────────────────────────────────────
# [L1] a suite that defines a planted-break helper of its own hands it to capped, plant_break or expect_red (the ports fixture,
#      which goes through capped) somewhere in its code: an uncapped break can take the runner (a suite killed with 137 under parallel load).
# [L2] no `python3 -I` without `-B` on a code line (-I ignores PYTHONDONTWRITEBYTECODE: __pycache__ was once written into
#      plugins/ while parallel suites copied it). A line that starts with a `plant` or `plant_break` call is skipped: its
#      arguments are the mutation's text, not a command.
# Everything else the deleted test-suite-independence.sh and the old [G] parser checked guarded no measured failure.
echo "== [L] lint =="
HW='([A-Za-z0-9]+_)*(plant|planted|mutant|mutants|BRK[A-Z]*|expect_red|red_at|fault|faults|sabotage)(_[A-Za-z0-9]+)*'   # whole _-words: `default` is not `fault`
lint() {  # lint <file> — one line per problem, empty when clean
  local code n; n=$(basename "$1")
  code=$(grep -nvE '^[[:space:]]*#' "$1")
  # here-strings, not `printf | grep -q`: under pipefail a grep -q that stops at its first match gives printf a SIGPIPE on a big
  # file, the pipeline fails, and `! … grep -q capped` would read as "never calls capped" (seen on CI for test-contract.sh)
  if grep -qE "^[0-9]+:[[:space:]]*(function[[:space:]]+)?$HW[[:space:]]*(\(\))?[[:space:]]*\{" <<<"$code" &&
     ! grep -qE '(^|[^[:alnum:]_])(capped|plant_break|expect_red)([^[:alnum:]_]|$)' <<<"$code"; then
    echo "$n: [L1] defines a planted-break helper and never calls capped, plant_break or expect_red"
  fi
  printf '%s\n' "$code" | grep -vE "^[0-9]+:[[:space:]]*(plant|plant_break)[[:space:]]" | grep -E 'python3( +-[A-Za-z]+)* +-I( |$)' |
    grep -vE 'python3( +-[A-Za-z]+)* +-B([^[:alnum:]_-]|$)' | sed "s/^/$n: [L2] python3 -I without -B: /"
}
L="$TMP/lint"; mkdir -p "$L"
printf '%s\n' 'plant() { "$@"; }' 'plant x' > "$L/test-l1-bad.sh"
printf '%s\n' 'plant() { plant_break "$@"; }' > "$L/test-l1-ok.sh"
printf '%s\n' 'BRKX() { expect_red "$@"; }' > "$L/test-l1-ports.sh"
printf '%s\n' 'show_defaults() { echo x; }' 'fam_default_off() { :; }' > "$L/test-l1-default.sh"
printf '%s\n' 'mutant_probe python3 -I x.py' > "$L/test-l2-other-word.sh"
{ echo 'out=$(capped true)'; i=0; while [ $i -lt 20000 ]; do echo "echo padding line $i"; i=$((i + 1)); done; echo 'plant() { "$@"; }'; } > "$L/test-l1-big.sh"
printf '%s\n' 'out=$(python3 -I "$x")' > "$L/test-l2-bad.sh"
printf '%s\n' 'out=$(python3 -I -B "$x")' '"[S] a label that names python3 -I -B: ask"' "plant \"a\" EP \"\$E\" 'setup() { python3 -I x' 'y'" '# python3 -I in a comment' > "$L/test-l2-ok.sh"
has "$(lint "$L/test-l1-bad.sh")" "[L1]" "[L1] planted: a helper that runs its break uncapped is flagged"
empty "$(lint "$L/test-l1-ok.sh")$(lint "$L/test-l1-ports.sh")" "[L1] control: plant_break and expect_red count as capped"
empty "$(lint "$L/test-l1-big.sh")" "[L1] control: a capped call early and the helper late in a file bigger than a pipe buffer is not flagged (no SIGPIPE race)"
empty "$(lint "$L/test-l1-default.sh")" "[L1] control: a name with \`default\` in it is not a planted-break helper (whole words)"
has "$(lint "$L/test-l2-bad.sh")" "[L2]" "[L2] planted: python3 -I without -B is flagged"
empty "$(lint "$L/test-l2-ok.sh")" "[L2] control: -I -B (also before a colon), a plant line's mutation text and a comment are not flagged"
has "$(lint "$L/test-l2-other-word.sh")" "[L2]" "[L2] planted: only plant and plant_break lines are skipped, not any helper word"
N=0; O=""
for f in "$HERE"/test-*.sh "$HERE"/fixtures/*.sh; do
  case "$(basename "$f")" in test-capped-breaks.sh|capped.sh|plant.sh) continue;; esac   # these define the words they check
  N=$((N + 1)); O="$O$(lint "$f")"
done
[ "$N" -ge 60 ] && ok "[L] instrument: the glob found $N suites and fixtures" || bad "[L] instrument: only $N files found"
empty "$O" "[L] every suite and fixture passes [L1] and [L2]"

rm -f "$TMPDIR/.cap-hits"   # the hits above are this suite's own probes
echo; summary
