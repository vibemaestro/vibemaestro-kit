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
# [L] the lint: [L1] a suite's own planted-break helper reaches capped; [L2] no python3 -I without -B; [L3]-[L5] no planted
#     break (fixtures/planted_lint.py): a rewrite of a copy run to go red, a call of expect_red or plant_break, a helper named for a
#     break; a file listed in fixtures/planted-baseline.txt (it held breaks when the rule changed) may still hold them, a listed file
#     that holds none is a note. Planted offenders first, so a lint that stops matching turns this suite red.
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
N=0; O=""; FILES=()
for f in "$HERE"/test-*.sh "$HERE"/fixtures/*.sh; do
  case "$(basename "$f")" in test-capped-breaks.sh|capped.sh|plant.sh) continue;; esac   # these define the words they check
  N=$((N + 1)); O="$O$(lint "$f")"; FILES+=("$f")
done
[ "$N" -ge 60 ] && ok "[L] instrument: the glob found $N suites and fixtures" || bad "[L] instrument: only $N files found"
empty "$O" "[L] every suite and fixture passes [L1] and [L2]"

# [L3]-[L5]: no planted break. The kit's tests prove a change by being red on main before it and green after; a check that a
# copy of the code with a planted break goes red adds run time and nothing a reviewer reads. fixtures/planted_lint.py says what
# it sees and what it cannot.
nb() { python3 -I -B "$HERE/fixtures/planted_lint.py" "$HERE/fixtures" "$@" 2>&1; }   # a traceback is output: no control passes on it
mk() { local f="$L/$1"; shift; printf '%s\n' "$@" > "$f"; printf '%s' "$f"; }
PYRW=$'python3 - "$d/x.py" <<\'PY\'\nimport sys\np = sys.argv[1]; s = open(p).read()\nopen(p, "w").write(s.replace("a", "b"))\nPY'
F=$(mk test-l3-py.sh 'run_one() {' '  d=$(mktemp -d); cp -R "$P" "$d"' "  $PYRW" '  o=$(capped run "$d"); rc=$?' '  eq "$rc" 1 x' '}')
has "$(nb "$F")" "[L3]" "[L3] planted: a Python rewrite of a copy, then a capped run, is flagged"
F=$(mk test-l3-sed.sh 'sed "s/a/b/" "$SRC" > "$TMP/copy.sh"' 'out=$(capped bash "$TMP/copy.sh"); rc=$?')
has "$(nb "$F")" "[L3]" "[L3] planted: a sed of a script into a copy, then a capped run, is flagged"
F=$(mk test-l3-via.sh 'edit_it() { sed -i "s/a/b/" "$1"; }' 'go() { capped bash "$1"; }' 'edit_it "$c"' 'o=$(go "$c")')
has "$(nb "$F")" "[L3]" "[L3] planted: the rewrite and the capped run in two helpers of the file are flagged where they meet"
F=$(mk test-l3-mutate.sh 'mutate "$d/x.py" a b' 'o=$(capped fam "$d")')
has "$(nb "$F")" "[L3]" "[L3] planted: mutate (ports.sh), then a capped run, is flagged"
F=$(mk test-l3-perl.sh "perl -pi -e 's/a/b/' \"\$d/x.pl\"" 'if capped run "$d"; then bad x; fi')
has "$(nb "$F")" "[L3]" "[L3] planted: perl -pi, then a capped run after if, is flagged"
F=$(mk test-l4.sh 'expect_red "x" fam_x "$d" needle')
has "$(nb "$F")" "[L4]" "[L4] planted: a call of expect_red is flagged"
F=$(mk test-l4b.sh 'out=$(plant_break "x" "$T" f.txt a b -- judge @COPY@)')
has "$(nb "$F")" "[L4]" "[L4] planted: a call of plant_break is flagged"
F=$(mk test-l5.sh 'BRKX() { :; }' 'xbreak() { :; }' 'mutant_run() { :; }')
eq "$(nb "$F" | grep -c '\[L5\]')" 3 "[L5] planted: helpers named BRKX, xbreak and mutant_run are each flagged"
F=$(mk test-l5-quoted-heredoc.sh "f x \$'git <<OPS\\nOPS'" 'has "$(t "$P" "go <<OPS")" x' 'BRKY() { :; }' 'cat <<OPS' 'text' 'OPS')
has "$(nb "$F")" "[L5] a helper named for a planted break: 3:" "[L5] planted: a \`<<\` inside quotes (\$'…', \"\$(… \"…\")\") opens no here-document, so the helper before a real one is still seen"
F=$(mk test-l3-input.sh "printf 'a bad line\n' > \"\$R/f.txt\"" 'block | sed "s/\$/\r/" > "$R/crlf.md"' 'O=$(capped run); eq "$?" 1 "a bad input is red"')
empty "$(nb "$F")" "[L3] control: an input written new (printf >, sed on a pipe), then a capped checker, is a functional case"
F=$(mk test-l3-marker.sh 'sed -i "s/a/b/" "$R/map"   # the guard'"'"'s input, not a break' 'o=$(capped guard); eq "$?" 1 x')
empty "$(nb "$F")" "[L3] control: a rewrite that says it builds a checker's input (not a break) is not flagged"
F=$(mk test-l3-label.sh 'red() { o=$(capped guard); }' 'sed -i "s/a/b/" "$R/map"' 'eq "$x" 1 "the oracle disagrees (red)"')
empty "$(nb "$F")" "[L3] control: a quoted label that reads like a call (… (red)) is not a call"
F=$(mk test-l3-helper.sh 'red() {  # a checker given a bad input: not a break' '  o=$(capped guard); rc=$?' '}' 'sed -i "s/a/b/" "$R/map"' 'red x')
empty "$(nb "$F")" "[L3] control: a helper that says it runs a checker on its input (not a break) is not a break's run"
F=$(mk test-l3-out.sh 'python3 -c "import sys; sys.stdout.write(sys.stdin.read())" < "$f"' 'o=$(capped run)')
empty "$(nb "$F")" "[L3] control: Python that reads stdin and writes stdout rewrites no file"
F=$(mk test-l5-ok.sh 'fam_default_off() { :; }' 'plant_input() {  # writes the checker'"'"'s input, not a break' '  :' '}')
empty "$(nb "$F")" "[L5] control: a name with no break word, and a break-like name that carries the marker, are not flagged"

F=$(mk test-l4-brain.sh "plant x case_x scripts/brain_owner.py 'if not ok:' 'if False:'")
has "$(nb "$F")" "[L4]" "[L4] planted: a call of brain.sh's plant (it rewrites a copy and runs it capped) is flagged"
F=$(mk test-l4-gates.sh 'BRKG x fam_x needle "$old" "$new"' 'BRKS y fam_y needle "$old" "$new"')
eq "$(nb "$F" | grep -c '\[L4\]')" 2 "[L4] planted: calls of gates.sh's BRKG and BRKS (they call mutate and expect_red) are flagged"
F=$(mk test-l4-shadow.sh 'plant() {  # plant <class> <line> — the line in a tracked file of the scratch repo: the checker'"'"'s input, not a break' '  printf "%s\n" "$2" > "$R/p.txt"' '}' 'plant kb "$KBPATH"')
empty "$(nb "$F")" "[L4] control: a file that defines its own plant (an input builder with the marker) is not calling brain.sh's"
for form in "write_text:python3 -c 'from pathlib import Path; p = Path(\"\$d/x.py\"); p.write_text(p.read_text().replace(\"a\", \"b\"))'" \
            "sed -Ei:sed -Ei 's/a/b/' \"\$d/x.py\"" "sed --in-place:sed --in-place 's/a/b/' \"\$d/x.py\"" \
            "perl -p -i:perl -p -i -e 's/a/b/' \"\$d/x.pl\"" "sed <:sed 's/a/b/' < \"\$PL/x.py\" > \"\$d/x.py\"" \
            "sed --:sed -e 's/a/b/' -- \"\$PL/x.py\" > \"\$d/x.py\"" "awk:awk '{print}' \"\$PL/x.py\" > \"\$d/x.py\"" \
            "sed literal path:sed 's/a/b/' plugins/x.py > \"\$d/x.py\""; do
  F=$(mk test-l3-form.sh "${form#*:}" 'o=$(capped run "$d")')
  has "$(nb "$F")" "[L3]" "[L3] planted: the rewrite form ${form%%:*}, then a capped run, is flagged"
done
F=$(mk test-l3-marker-line.sh "sed -i 's/return 1/return 0/' \"\$d/pl/scripts/guard.py\"" 'printf "x\n" > "$R/in.txt"   # the checker'"'"'s input, not a break' 'O=$(capped python3 -B "$d/pl/scripts/guard.py")')
has "$(nb "$F")" "[L3] a planted break: a rewrite (line 1)" "[L3] planted: the marker on another line of top-level code does not hide a rewrite"
F=$(mk test-l3-restore.sh 'go() {' '  o=$(capped bash "$1")' "  sed -i 's/b/a/' \"\$1\"" '}' "sed -i 's/a/b/' \"\$c\"; go \"\$c\"")
has "$(nb "$F")" "[L3]" "[L3] planted: a rewrite, then a helper that runs capped and restores after, is flagged at the call"
F=$(mk test-l3-restore-ok.sh 'f() { o=$(capped bash "$1"); sed -i "s/b/a/" "$1"; }' 'f "$x"')
empty "$(nb "$F")" "[L3] control: a run then a rewrite on one line (a restore) is not a rewrite run to go red"
F=$(mk test-l3-wrapper.sh "sed -i \"s/\$v/z/\" \"\$c\"" 'out=$(timeout 5 capped bash "$c")')
has "$(nb "$F")" "[L3]" "[L3] planted: capped behind a wrapper (timeout 5) is still a red-expected run"
F=$(mk test-r2-copy.sh 'd=$(fresh)/p; mk_plugin_copy "$d"' "printf 'bad line\\n' > \"\$d/input.txt\"" 'o=$(capped cenv python3 -B "$d/scripts/check.py" "$d/input.txt"); eq "$?" 1 "a bad input is red"')
empty "$(nb "$F")" "[L3] control: a plugin copy (its isolation is not a break), a bad input written new, a capped check: a functional case"
F=$(mk test-r2-twice.sh 'go() { o=$(capped bash "$1"); sed -i "s/b/a/" "$1"; }' 'go "$x"' 'go "$y"')
empty "$(nb "$F")" "[L3] control: a run-then-restore helper called twice: the restore of one call is not a rewrite for the next"
F=$(mk test-r2-heredoc-marker.sh "python3 - \"\$R/map\" <<'PY'   # the guard's input, not a break" 'import sys' 'p = sys.argv[1]; s = open(p).read()' 'open(p, "w").write(s.replace("a", "b"))' 'PY' 'o=$(capped guard)')
empty "$(nb "$F")" "[L3] control: the marker on the line that opens a here-document covers the rewrite in its body"
F=$(mk test-r2-arith.sh 'bit() { echo $((1 << n)); }' 'BRKZ() { :; }')
has "$(nb "$F")" "[L5] a helper named for a planted break: 2:" "[L5] planted: \$((1 << n)) is a shift, not a here-document that hides the next helper"
F=$(mk test-r2-multiline.sh "sed -i 's/a/b/' \"\$d/x.py\"" "cfg=\$(python3 -c '" "import sys; print(sys.stdin.read())' <<EOF" 'k: v' '' 'EOF' ')' 'o=$(capped run "$d")')
has "$(nb "$F")" "[L3]" "[L3] planted: a quote opened on one line and closed on the next (then a here-document with a blank line) does not hide the run"
F=$(mk test-r2-pyrestore.sh "go() { o=\$(capped bash \"\$1\"); python3 -c 'import sys; p = sys.argv[1]; open(p, \"w\").write(open(p).read().replace(\"b\", \"a\"))' \"\$1\"; }" 'go "$x"')
empty "$(nb "$F")" "[L3] control: run, then a restore in Python on the same line, is not a break (the write sorts where it is)"
F=$(mk test-r2-functional.sh 'case_bad_map() {  # the guard given a bad map: its input, not a break' '  mutate "$R/map" a b' '  o=$(capped guard)' '}')
empty "$(nb "$F")" "[L3] control: a helper with the marker is not scanned, its mutate included"
F=$(mk test-r2-wrapper.sh "sed -i 's/a/b/' \"\$c\"" 'o=$(timeout -s KILL 5 capped bash "$c")' "sed -i 's/a/b/' \"\$e\"" 'o=$(env -u HOME capped bash "$e")')
eq "$(nb "$F" | grep -c '\[L3\]')" 2 "[L3] planted: capped behind timeout -s KILL 5 and env -u HOME is still a run"
FX="$L/fx"; mkdir -p "$FX"
printf '%s\n' 'chk() { o=$(capped bash "$1"); sed -i "s/b/a/" "$1"; }' 'setup() { sed -i "s/a/b/" "$1"; }' 'go_red() { sed -i "s/a/b/" "$1"; o=$(capped bash "$1"); }' > "$FX/a.sh"
printf '%s\n' 'setup() { o=$(capped x); }' > "$FX/b.sh"
F=$(mk test-r2-fx.sh 'chk "$f"' 'setup "$d"' 'go_red "$e"')
eq "$(python3 -I -B "$HERE/fixtures/planted_lint.py" "$FX" "$F" 2>&1 | grep -c '\[L4\]')" 1 "[L4] a fixture helper is a break only when a body of it rewrites and then runs (go_red), not run-then-restore (chk) nor two same-named helpers that each do half (setup)"
F=$(mk test-r3-capped-sed.sh 'mk() { cp -R "$P" "$d"; capped sed -i "s/a/b/" "$d/x.py"; }' 'mk' 'o=$(capped bash "$d/x.py")')
has "$(nb "$F")" "[L3]" "[L3] planted: a capped command that is itself the rewrite (capped sed -i) is a rewrite, and the run after it is flagged"
F=$(mk test-r3-capped-py.sh 'edit_copy() {' "  capped python3 - \"\$1\" <<'PY'" 'import sys' 'p = sys.argv[1]; s = open(p).read()' 'open(p, "w").write(s.replace("a", "b"))' 'PY' '}' 'edit_copy "$c"' 'o=$(capped bash "$c")')
has "$(nb "$F")" "[L3]" "[L3] planted: capped python3 whose here-document writes the file is a rewrite, not a run"
F=$(mk test-r3-arith.sh "MS=\$(( \$(python3 -c 'print(int(1.5*1000))') - t0 ))" '' 'sabotage() { :; }')
has "$(nb "$F")" "[L5]" "[L5] planted: a \`))\` inside a quote within \$((…)) does not end it, so the next helper is seen"
F=$(mk test-r3-subst.sh 'gate() { OUT=$(${GATE_BIN:+capped} bash "${GATE_BIN:-$G}"); }' 'plant() { sed "$2" "$G" > "$TMP/b-$1/g.sh"; printf "%s" "$TMP/b-$1/g.sh"; }' 'broken() { GATE_BIN="$2" gate; }' 'broken "[B1]" "$(plant b1 s/a/b/)" x' 'broken "[B2]" "$(plant b2 s/c/d/)" y')
eq "$(nb "$F" | grep '\[L3\]' | sed 's/.*(line \([0-9]*\)) run to go red: \([0-9]*\):.*/\1-\2/' | tr '\n' ' ')" "4-4 5-5 " "[L3] planted: a rewrite in \$(…) runs before the command it is an argument of (\${X:+capped} is a run): each break pairs with its own run"
F=$(mk test-r3-wrapper.sh "sed -i 's/a/b/' \"\$c\"" 'o=$(timeout --signal KILL 5 capped bash "$c")' "sed -i 's/a/b/' \"\$e\"" 'o=$(env -C /tmp capped bash "$e")')
eq "$(nb "$F" | grep -c '\[L3\]')" 2 "[L3] planted: timeout --signal KILL 5 and env -C dir are wrappers"
F=$(mk test-r4-later-heredoc.sh 'sed -i "s/a/b/" "$f"' "capped bash \"\$f\"; python3 - \"\$f\" <<'PY'" 'p = __import__("sys").argv[1]; s = open(p).read()' 'open(p, "w").write(s.replace("b", "a"))' 'PY')
has "$(nb "$F")" "[L3]" "[L3] planted: a here-document opened by a later command on the line does not make the capped run a rewrite"
F=$(mk test-r4-edge.sh 'v1() { sed s/a/b/ "$G" > "$T/v1"; printf %s "$T/v1"; }' 'expect_bad() { o=$(capped bash "$1"); [ -n "$o" ]; }' 'expect_bad "$(v1)"' 'capped bash "$(sed -i s/a/b/ "$c"; echo "$c")"')
eq "$(nb "$F" | grep -c '\[L3\]')" 2 "[L3] planted: a call that ends a \$(…) and a rewrite that starts one sort inside it, before the run"
F=$(mk test-r4-nested-quote.sh 'sed -i "s/a/b/" "$d/x.py"' 'o="$(cd "$d" && capped bash x.py 2>&1)"')
has "$(nb "$F")" "[L3]" "[L3] planted: a capped run inside \"\$(… \"\$d\" …)\" is seen through the nested quote"
F=$(mk test-l5-words.sh 'breaking_change() { :; }' 'line_breaks_crlf() { :; }' 'breakdown_ok() { :; }')
empty "$(nb "$F")" "[L5] control: breaking, breaks and breakdown are not break words"

BASE="$HERE/fixtures/planted-baseline.txt"
NB=$(python3 -I -B "$HERE/fixtures/planted_lint.py" "$HERE/fixtures" "${FILES[@]}" 2>"$TMP/nb.err"); NRC=$?
eq "$NRC:$(cat "$TMP/nb.err")" "0:" "[L] the lint read every suite and fixture (rc 0, nothing on stderr): a crash must not pass for a clean tree"
LISTED=$(sed 's/#.*//' "$BASE" | tr -d ' \t\r' | grep .)   # a comment, whole-line or after a name, is no entry
[ "$(printf '%s\n' "$LISTED" | grep -c .)" -ge 1 ] && ok "[L] instrument: the baseline lists $(printf '%s\n' "$LISTED" | grep -c .) files" || bad "[L] instrument: the baseline is empty"
# here-strings, not `printf | grep -q`: under pipefail an early-exiting grep -q gives printf a SIGPIPE and a listed file reads as unlisted
NEW=$(printf '%s\n' "$NB" | grep . | while IFS= read -r line; do grep -qxF -- "${line%%:*}" <<<"$LISTED" || printf '%s\n' "$line"; done)
empty "$NEW" "[L] no planted break outside the files the baseline lists (fixtures/planted-baseline.txt)"
HELD=$(printf '%s\n' "$NB" | grep . | while IFS= read -r line; do printf '%s\n' "${line%%:*}"; done | sort -u)
CLEAN=$(printf '%s\n' "$LISTED" | while IFS= read -r n; do grep -qxF -- "$n" <<<"$HELD" || printf '%s ' "$n"; done)
[ -z "$CLEAN" ] || echo "  note: listed in the baseline, no planted break left: $CLEAN"

rm -f "$TMPDIR/.cap-hits"   # the hits above are this suite's own probes
echo; summary
