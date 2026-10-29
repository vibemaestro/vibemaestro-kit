#!/bin/bash
# =============================================================================
# tests/run-all.sh itself: parallel mode, --jobs 1, filter words, summary lines, exit codes, the CPU quota and the resource line
# =============================================================================
# Run: bash tests/test-run-all.sh
#
# run-all.sh is driven over a tiny directory of STUB suites (RUN_ALL_SUITE_DIR), never over the real suites, so this costs a few
# seconds and cannot recurse into itself. Stubs: green, red (exit 1), crash (exit 7), chatty a/b (several lines with pauses, to catch
# interleaving), overlap a/b (log start/end around a 1 s sleep, to tell parallel from sequential without timing thresholds) and a
# ledger stub that is green only when the counts of every other suite are already in SUITE_RESULTS_DIR (the dependency of the real
# test-ledger.sh).
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"

TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
RUN="$HERE/run-all.sh"
LOG="$TMP/overlap.log"

# ── stub suites ──────────────────────────────────────────────────────────────
mk_stub() {  # mk_stub <dir> <name> <body…> — a suite that sources the real lib.sh (ok/summary) then runs <body>
  local d=$1 n=$2; shift 2
  { printf '#!/bin/bash\n. "%s/fixtures/lib.sh"\n' "$HERE"; printf '%s\n' "$@"; } > "$d/test-$n.sh"
}
mk_stubs() {  # mk_stubs <dir> [red 0|1]
  local d=$1 red=${2:-0}
  mkdir -p "$d"
  mk_stub "$d" green 'ok "green one"' 'ok "green two"' 'summary'
  mk_stub "$d" greenslow 'sleep 0.3' 'ok "late"' 'summary'
  [ "$red" = 1 ] && mk_stub "$d" red 'ok "before the break"' 'bad "planted red"' 'summary'
  mk_stub "$d" chatty-a 'for i in 1 2 3 4 5; do echo "A-line-$i"; sleep 0.03; done' 'ok a' 'summary'
  mk_stub "$d" chatty-b 'for i in 1 2 3 4 5; do echo "B-line-$i"; sleep 0.03; done' 'ok b' 'summary'
  # the ledger stub is green only when the counts of the suites before it are already there (the dependency of the real ledger suite)
  mk_stub "$d" ledger 'for s in green greenslow chatty-a chatty-b; do [ -f "$SUITE_RESULTS_DIR/test-$s" ] && ok "counts of $s present" || bad "counts of $s missing when the ledger ran"; done' 'summary'
  # a suite that sorts AFTER the ledger, as thu-tuc does in the real tree: tells "alphabetical" from "ledger deferred"
  mk_stub "$d" zeta 'ok "after the ledger alphabetically"' 'summary'
}
GREENDIR="$TMP/stubs-green"; REDDIR="$TMP/stubs-red"; OVLDIR="$TMP/stubs-overlap"
mk_stubs "$GREENDIR" 0; mk_stubs "$REDDIR" 1
mkdir -p "$OVLDIR"
mk_stub "$OVLDIR" overlap-a 'echo a-start >> "$OVERLAP_LOG"' 'sleep 0.6' 'echo a-end >> "$OVERLAP_LOG"' 'ok a' 'summary'
mk_stub "$OVLDIR" overlap-b 'echo b-start >> "$OVERLAP_LOG"' 'sleep 0.6' 'echo b-end >> "$OVERLAP_LOG"' 'ok b' 'summary'
mkdir -p "$TMP/stubs-crash"; mk_stub "$TMP/stubs-crash" green 'ok x' 'summary'; mk_stub "$TMP/stubs-crash" crash 'exit 7'

run() {  # run <dir> <args…> — OUT = stdout+stderr, RC = exit code
  local d=$1; shift
  : > "$LOG"
  OUT=$(env -u NET_LOG RUN_ALL_SUITE_DIR="$d" OVERLAP_LOG="$LOG" bash "$RUN" "$@" 2>&1); RC=$?
}
last() { printf '%s\n' "$OUT" | tail -n 1; }
NSTUB=$(ls "$GREENDIR"/test-*.sh | wc -l | tr -d ' ')
NRED=$(ls "$REDDIR"/test-*.sh | wc -l | tr -d ' ')

echo "== all green =="
for mode in "--jobs 4" "--jobs 1" ""; do
  # shellcheck disable=SC2086
  run "$GREENDIR" $mode
  eq "$RC" 0 "green stubs [${mode:-default jobs}]: rc 0"
  eq "$(last)" "XANH $NSTUB/$NSTUB suite" "green stubs [${mode:-default jobs}]: last line is 'XANH N/N suite'"
  has "$OUT" "################ greenslow" "green stubs [${mode:-default jobs}]: a suite header per suite"
  has "$OUT" "2 ok, 0 fail" "green stubs [${mode:-default jobs}]: the suite's own summary line is kept"
  hasnt "$OUT" "FAIL " "green stubs [${mode:-default jobs}]: no failing assertion, including the ledger dependency"
done

echo "== a red suite makes run-all red (parallel, sequential, default) =="
for mode in "--jobs 4" "--jobs 1" ""; do
  # shellcheck disable=SC2086
  run "$REDDIR" $mode
  eq "$RC" 1 "red stub [${mode:-default jobs}]: rc 1"
  eq "$(last)" "ĐỎ 1/$NRED suite: red (rc 1)" "red stub [${mode:-default jobs}]: last line names the red suite and its rc"
  has "$OUT" "planted red" "red stub [${mode:-default jobs}]: the red suite's output is shown"
  has "$OUT" "late" "red stub [${mode:-default jobs}]: the green suites still ran and were printed"
done
run "$TMP/stubs-crash" --jobs 4
eq "$RC" 1 "a suite that exits 7: rc 1"
eq "$(last)" "ĐỎ 1/2 suite: crash (rc 7)" "…and run-all reports the rc 7"
run "$TMP/stubs-crash" --jobs 1
eq "$(last)" "ĐỎ 1/2 suite: crash (rc 7)" "…the same under --jobs 1"

echo "== output of parallel suites is not interleaved =="
run "$GREENDIR" --jobs 4 chatty
eq "$RC" 0 "two chatty suites in parallel: rc 0"
# every line between a header and the next header must carry the same A-/B- prefix as the suite named in the header
BAD=$(printf '%s\n' "$OUT" | awk '/^################ /{cur=$2; next} /^(A|B)-line-/{ want=(cur=="chatty-a")?"A":"B"; if (substr($0,1,1)!=want) print cur ": " $0 }')
empty "$BAD" "no line of one suite printed inside the block of the other"
eq "$(printf '%s\n' "$OUT" | grep -c '^A-line-')" 5 "all five A lines are there"
eq "$(printf '%s\n' "$OUT" | grep -c '^B-line-')" 5 "all five B lines are there"
# control: the instrument sees interleaving when it is there
BAD=$(printf '################ chatty-a\nA-line-1\nB-line-1\n' | awk '/^################ /{cur=$2; next} /^(A|B)-line-/{ want=(cur=="chatty-a")?"A":"B"; if (substr($0,1,1)!=want) print cur ": " $0 }')
nonempty "$BAD" "control: the same check flags a planted interleaved block"

echo "== parallel really overlaps, --jobs 1 really does not =="
overlap() { awk '/-start/{s++} /-end/{ if (s<2) { print "no"; exit } else { print "yes"; exit } }' "$LOG"; }
run "$OVLDIR" --jobs 4
eq "$(overlap)" yes "--jobs 4: both overlap suites started before either ended"
run "$OVLDIR" --jobs 1
eq "$(overlap)" no "--jobs 1: the first suite ended before the second started"
eq "$(tr '\n' ' ' < "$LOG")" "a-start a-end b-start b-end " "--jobs 1: strictly one after the other, alphabetical"
run "$OVLDIR" -j 4
eq "$(overlap)" yes "-j 4 is the same as --jobs 4"
run "$OVLDIR" --jobs=4
eq "$(overlap)" yes "--jobs=4 is the same as --jobs 4"
: > "$LOG"; OUT=$(env -u NET_LOG RUN_ALL_JOBS=1 RUN_ALL_SUITE_DIR="$OVLDIR" OVERLAP_LOG="$LOG" bash "$RUN" 2>&1); RC=$?
eq "$(overlap)" no "RUN_ALL_JOBS=1: sequential"
: > "$LOG"; OUT=$(env -u NET_LOG RUN_ALL_JOBS=1 RUN_ALL_SUITE_DIR="$OVLDIR" OVERLAP_LOG="$LOG" bash "$RUN" --jobs 4 2>&1); RC=$?
eq "$(overlap)" yes "the --jobs flag wins over RUN_ALL_JOBS"
NCPU=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)
if [ "$NCPU" -ge 2 ]; then
  # with no CPU quota (an empty fake cgroup): a host or container quota under 2 CPUs would rightly make this run one job at a time
  mkdir -p "$TMP/no-cgroup"; RUN_ALL_CGROUP_DIR="$TMP/no-cgroup" run "$OVLDIR"
  eq "$(overlap)" yes "default jobs (derived from $NCPU CPUs) overlap independent suites"
else
  ok "default jobs: one CPU, overlap not asserted"
fi

echo "== the CPU quota (cgroup v2 cpu.max) and the resource line =="
# a fake cgroup v2 directory (RUN_ALL_CGROUP_DIR): nproc shows the node's CPUs in a pod, the quota is what the run may use
CG="$TMP/cgroup"; mkdir -p "$CG"
cgrun() {  # cgrun <dir> <args…> — run with the fake cgroup and no RUN_ALL_JOBS
  local d=$1; shift
  : > "$LOG"
  OUT=$(env -u NET_LOG -u RUN_ALL_JOBS RUN_ALL_CGROUP_DIR="$CG" RUN_ALL_SUITE_DIR="$d" OVERLAP_LOG="$LOG" OOM_EVENTS="$CG/memory.events" bash "$RUN" "$@" 2>&1); RC=$?
}
res() { printf '%s\n' "$OUT" | grep '^resources: ' | sed 's/;.*//'; }
NJ=$NCPU; WHY="$NCPU CPUs"; [ "$NJ" -le 8 ] || { NJ=8; WHY="cap 8 of $NCPU CPUs"; }
quota() {  # quota <cpus> — the resource line's jobs part for a quota of <cpus>
  if [ "$1" -lt "$NCPU" ] && [ "$1" -le 8 ]; then echo "resources: jobs $1 (cpu quota $1 of $NCPU CPUs)"; else echo "resources: jobs $NJ ($WHY)"; fi
}
printf '600000 100000\n' > "$CG/cpu.max"; cgrun "$GREENDIR"
eq "$(res)" "$(quota 6)" "cpu.max 600000 100000 (the k3s runner's 6 CPUs): at most 6 jobs"
eq "$RC" 0 "…and the run is green"
printf '50000 100000\n' > "$CG/cpu.max"; cgrun "$GREENDIR"
eq "$(res)" "$(quota 1)" "a quota under one CPU: one job, not zero"
printf 'max 100000\n' > "$CG/cpu.max"; cgrun "$GREENDIR"
eq "$(res)" "resources: jobs $NJ ($WHY)" "cpu.max max (no quota): the CPU count, as before"
printf '600000 0\n' > "$CG/cpu.max"; cgrun "$GREENDIR"
eq "$(res)" "resources: jobs $NJ ($WHY)" "a period of 0 is no quota (no division by zero)"
rm -f "$CG/cpu.max"; cgrun "$GREENDIR"
eq "$(res)" "resources: jobs $NJ ($WHY)" "no cpu.max file: the CPU count, as before"
printf '600000 100000\n' > "$CG/cpu.max"; cgrun "$GREENDIR" --jobs 3
eq "$(res)" "resources: jobs 3 (asked)" "--jobs wins over the quota"
OUT=$(env -u NET_LOG RUN_ALL_JOBS=2 RUN_ALL_CGROUP_DIR="$CG" RUN_ALL_SUITE_DIR="$GREENDIR" bash "$RUN" 2>&1)
eq "$(res)" "resources: jobs 2 (asked)" "RUN_ALL_JOBS wins over the quota"
printf '104857600\n' > "$CG/memory.peak"; printf '2147483648\n' > "$CG/memory.max"; printf 'low 0\noom 2\noom_kill 2\n' > "$CG/memory.events"
OOMDIR="$TMP/stubs-oom"; mkdir -p "$OOMDIR"
mk_stub "$OOMDIR" oom 'printf "low 0\noom 5\noom_kill 5\n" > "$OOM_EVENTS"' 'ok "an OOM kill counted meanwhile"' 'summary'
cgrun "$OOMDIR"
has "$OUT" "cgroup memory peak 100 MiB of 2048 MiB" "the resource line: the cgroup's memory peak and limit"
has "$OUT" "oom kills 3" "…the OOM kills during the run only (5 at the end, 2 at the start)"
eq "$(printf '%s\n' "$OUT" | tail -n 3 | head -n 1 | cut -c1-11)" "resources: " "…on the line before the last block (the last line stays the verdict)"
rm -f "$CG/memory.events"; cgrun "$GREENDIR"
hasnt "$OUT" "oom kills" "no memory.events: the OOM count is left out, not guessed"

echo "== ordering and filters =="
run "$GREENDIR" --jobs 1
eq "$(printf '%s\n' "$OUT" | grep '^################ ' | tr -d '#' | tr -s ' ' | tr '\n' ',')" " chatty-a, chatty-b, green, greenslow, ledger, zeta," "--jobs 1: suites in alphabetical order (ledger in its alphabetical place)"
run "$GREENDIR" --jobs 4
eq "$(printf '%s\n' "$OUT" | grep '^################ ' | tail -n 1)" "################ ledger" "--jobs 4: the ledger block is printed last (it runs after every other suite)"
# the known-slow suites are launched first: with 2 jobs and three stubs, the slow one must start before the alphabetically later bbb
SLOWDIR="$TMP/stubs-slowfirst"; CTLDIR="$TMP/stubs-slowfirst-ctl"; MGDIR="$TMP/stubs-slowfirst-mg"; mkdir -p "$SLOWDIR" "$CTLDIR" "$MGDIR"
for pair in "$SLOWDIR:plugin-version" "$CTLDIR:zz-core" "$MGDIR:merge-guard"; do
  d=${pair%%:*}; slow=${pair#*:}
  mk_stub "$d" aaa 'echo aaa >> "$OVERLAP_LOG"' 'sleep 0.5' 'ok a' 'summary'
  mk_stub "$d" bbb 'echo bbb >> "$OVERLAP_LOG"' 'ok b' 'summary'
  mk_stub "$d" "$slow" "echo $slow >> \"\$OVERLAP_LOG\"" 'sleep 0.3' 'ok s' 'summary'
done
pos() { awk -v n="$1" '$0==n{print NR; exit}' "$LOG"; }
run "$SLOWDIR" --jobs 2
[ "$(pos plugin-version)" -lt "$(pos bbb)" ] && ok "--jobs 2: plugin-version starts before the alphabetically earlier bbb (slow suites first)" || bad "--jobs 2: plugin-version started after bbb ($(tr '\n' ' ' < "$LOG"))"
eq "$(last)" "XANH 3/3 suite" "…and every suite still runs and is counted"
run "$MGDIR" --jobs 2
[ "$(pos merge-guard)" -lt "$(pos bbb)" ] && ok "--jobs 2: merge-guard (the longest suite) starts before the alphabetically earlier bbb" || bad "--jobs 2: merge-guard started after bbb ($(tr '\n' ' ' < "$LOG"))"
run "$CTLDIR" --jobs 2
[ "$(pos zz-core)" -gt "$(pos bbb)" ] && ok "control: a suite that is not in the slow list starts in alphabetical order (zz-core after bbb)" || bad "control: zz-core started before bbb ($(tr '\n' ' ' < "$LOG")): the check cannot tell the orders apart"
run "$GREENDIR" --jobs 4 green chatty-a
eq "$(last)" "XANH 3/3 suite" "filter words: 'green' matches green and greenslow, 'chatty-a' one more"
has "$OUT" "################ chatty-a" "filter words: the named suite ran"
hasnt "$OUT" "################ chatty-b" "filter words: a suite no word matches did not run"
run "$GREENDIR" --jobs 4 no-such-suite
eq "$RC" 1 "no suite matches: rc 1"
has "$OUT" "FAIL: không suite nào được chạy" "…with the old message"
run "$GREENDIR" ledger
eq "$RC" 1 "the ledger stub alone is red: its dependency (the counts of the others) is real, not decorative"
for bad in 0 abc -3; do
  run "$GREENDIR" --jobs "$bad" green
  eq "$RC" 2 "--jobs $bad is refused with rc 2"
done
RC=0; OUT=$(env -u NET_LOG RUN_ALL_SUITE_DIR="$GREENDIR" bash "$RUN" --jobs 2>&1) || RC=$?
eq "$RC" 2 "--jobs without a number is refused with rc 2"

echo "== the worktree guard: HEAD, branch and index must not change during a run =="
# run-all watches the repository that holds the script. Here a COPY of run-all sits in a throw-away repository (tests/run-all.sh inside it) and
# stub suites act on that repository through GUARD_REPO; they use the plain git binary, as they do not call clean_env (git_ would refuse).
sgit() { command git -c user.email=s@s -c user.name=s -c commit.gpgsign=false -C "$1" "${@:2}"; }
gr_new() {  # gr_new <name> — a fresh repository with a copy of run-all.sh in tests/, one commit; prints its path
  local g; g=$(mktemp -d "$TMP/guard.XXXXXX"); mkdir -p "$g/tests"; cp "$RUN" "$g/tests/run-all.sh"
  command git init -q -b main "$g"; echo seed > "$g/seed.txt"; sgit "$g" add -A; sgit "$g" commit -qm seed
  echo "$g"
}
grun() {  # grun <repo> <stub dir> <args…> — OUT and RC of the copy of run-all inside <repo>
  local g=$1 d=$2; shift 2
  OUT=$(env -u NET_LOG RUN_ALL_SUITE_DIR="$d" GUARD_REPO="$g" bash "$g/tests/run-all.sh" "$@" 2>&1); RC=$?
}
gstub() {  # gstub <name> <body…> — a one-suite stub dir; prints it
  local d; d=$(mktemp -d "$TMP/gstub.XXXXXX"); mk_stub "$d" act "$@" 'summary'; echo "$d"
}
S_NONE=$(gstub 'ok "touches nothing"')
S_COMMIT=$(gstub 'command git -c user.email=s@s -c user.name=s -c commit.gpgsign=false -C "$GUARD_REPO" commit --allow-empty -qm planted' 'ok "committed"')
S_STAGE=$(gstub 'echo y > "$GUARD_REPO/new.txt"' 'command git -C "$GUARD_REPO" add new.txt' 'ok "staged"')
S_BRANCH=$(gstub 'command git -C "$GUARD_REPO" checkout -qb other' 'ok "switched branch"')
S_COMMIT_RED=$(gstub 'command git -c user.email=s@s -c user.name=s -c commit.gpgsign=false -C "$GUARD_REPO" commit --allow-empty -qm planted' 'bad "planted red"')
for mode in "--jobs 4" "--jobs 1"; do
  g=$(gr_new x); grun "$g" "$S_NONE" $mode
  eq "$RC" 0 "guard [$mode] control, a suite that changes nothing: rc 0"
  eq "$(last)" "XANH 1/1 suite" "guard [$mode] control: last line is XANH 1/1"
  hasnt "$OUT" "guard:" "guard [$mode] control: no line from the guard"
  g=$(gr_new x); grun "$g" "$S_COMMIT" $mode
  eq "$RC" 1 "guard [$mode] a suite that commits in the repository: rc 1 though the suite is green"
  eq "$(last)" "ĐỎ guard: the worktree changed during the run (HEAD)" "guard [$mode] ...the last line names HEAD"
  has "$OUT" "guard: HEAD changed: before $(sgit "$g" rev-parse HEAD~1), after $(sgit "$g" rev-parse HEAD)" "guard [$mode] ...and prints both values"
  g=$(gr_new x); grun "$g" "$S_STAGE" $mode
  eq "$RC" 1 "guard [$mode] a suite that stages a file: rc 1"
  eq "$(last)" "ĐỎ guard: the worktree changed during the run (index)" "guard [$mode] ...the last line names the index"
  g=$(gr_new x); grun "$g" "$S_BRANCH" $mode
  eq "$RC" 1 "guard [$mode] a suite that checks out another branch: rc 1"
  eq "$(last)" "ĐỎ guard: the worktree changed during the run (branch)" "guard [$mode] ...the last line names the branch"
  g=$(gr_new x); grun "$g" "$S_COMMIT_RED" $mode
  eq "$RC" 1 "guard [$mode] a red suite that also commits: rc 1"
  eq "$(last)" "ĐỎ 1/1 suite: act (rc 1); guard: the worktree changed during the run (HEAD)" "guard [$mode] ...both reasons on the last line"
done
# GIT_DIR in the environment of the run points plain git at another repository; the guard must still watch the one that holds run-all
OTHER=$(mktemp -d "$TMP/other.XXXXXX"); command git init -q -b main "$OTHER"
g=$(gr_new x)
S_COMMIT_ENV=$(gstub 'env -u GIT_DIR git -c user.email=s@s -c user.name=s -c commit.gpgsign=false -C "$GUARD_REPO" commit --allow-empty -qm planted' 'ok "committed"')   # the stub itself must reach the watched repository
OUT=$(env -u NET_LOG GIT_DIR="$OTHER/.git" RUN_ALL_SUITE_DIR="$S_COMMIT_ENV" GUARD_REPO="$g" bash "$g/tests/run-all.sh" --jobs 1 2>&1); RC=$?
eq "$RC" 1 "guard: GIT_DIR in the environment does not hide a commit in the watched repository (rc 1)"
eq "$(last)" "ĐỎ guard: the worktree changed during the run (HEAD)" "guard: ...and the last line names HEAD"
# a repository with no commit yet: HEAD is 'unborn' on both sides, and a staged file is still seen
U=$(mktemp -d "$TMP/unborn.XXXXXX"); mkdir -p "$U/tests"; cp "$RUN" "$U/tests/run-all.sh"; command git init -q -b main "$U"
grun "$U" "$S_STAGE" --jobs 1
eq "$RC" 1 "guard: a staged file in a repository with no commit: rc 1"
eq "$(last)" "ĐỎ guard: the worktree changed during the run (index)" "guard: ...the index, not HEAD, is what changed"
U=$(mktemp -d "$TMP/unborn.XXXXXX"); mkdir -p "$U/tests"; cp "$RUN" "$U/tests/run-all.sh"; command git init -q -b main "$U"
grun "$U" "$S_NONE" --jobs 1
eq "$RC" 0 "guard: a repository with no commit and an untouched index is green (control)"
g=$(gr_new x); echo y > "$g/staged.txt"; sgit "$g" add staged.txt; echo z > "$g/untracked.txt"
grun "$g" "$S_NONE" --jobs 4
eq "$RC" 0 "guard: a run that starts on a dirty tree and changes nothing is green (before and after are compared, not cleanliness)"
NOGIT="$TMP/nogit"; mkdir -p "$NOGIT/tests"; cp "$RUN" "$NOGIT/tests/run-all.sh"
grun "$NOGIT" "$S_NONE" --jobs 4
eq "$RC" 0 "guard: outside a git work tree the run is not failed"
has "$OUT" "guard: not a git work tree, skipped" "guard: ...and says that the check was skipped"
eq "$(last)" "XANH 1/1 suite" "guard: ...the verdict line is unchanged"

echo "== a signal stops the running suites, not only run-all =="
SIGDIR="$TMP/stubs-signal"; mkdir -p "$SIGDIR"
mk_stub "$SIGDIR" sleeper 'touch "$SIG_MARK.started"' 'sleep 1.5' 'touch "$SIG_MARK.after"' 'summary'
# SIGTERM only: a job started with & by a non-interactive shell ignores SIGINT, so this harness cannot deliver one (a real Ctrl-C
# reaches the whole process group; run-all.sh traps INT the same way and forwards TERM to its suites).
MARK="$TMP/sig-term"
env -u NET_LOG RUN_ALL_SUITE_DIR="$SIGDIR" SIG_MARK="$MARK" bash "$RUN" --jobs 2 > "$TMP/sig-term.out" 2>&1 &
RP=$!
for _ in $(seq 1 50); do [ -e "$MARK.started" ] && break; sleep 0.1; done
[ -e "$MARK.started" ] && ok "SIGTERM: the stub suite started" || bad "SIGTERM: the stub suite never started"
kill -TERM "$RP"; wait "$RP"; RC=$?
eq "$RC" 143 "SIGTERM: run-all exits 143"
sleep 2
[ ! -e "$MARK.after" ] && ok "SIGTERM: the running suite was stopped too (it never reached its next command)" || bad "SIGTERM: the suite ran on as an orphan"
has "$(cat "$TMP/sig-term.out")" "resources: jobs 2 (asked)" "SIGTERM (a CI timeout): the resource line is printed all the same"

echo "== --changed runs the planner's suites, exact names; anything it cannot give is the full suite =="
# A stub planner (RUN_ALL_PLANNER): it logs its arguments, prints PLAN_OUT one name per line, a `plan:` line on stderr, exits PLAN_RC.
cat > "$TMP/planner.py" <<'PY'
import os, sys
open(os.environ["PLAN_ARGS"], "w").write(" ".join(sys.argv[1:]))
print("plan: stub — %s" % os.environ.get("PLAN_WHY", "planned"), file=sys.stderr)
for n in os.environ.get("PLAN_OUT", "").split():
    print(n)
sys.exit(int(os.environ.get("PLAN_RC", "0")))
PY
crun() {  # crun <PLAN_OUT> <PLAN_RC> <run-all args…>
  local po=$1 prc=$2; shift 2
  OUT=$(env -u NET_LOG RUN_ALL_SUITE_DIR="$GREENDIR" RUN_ALL_PLANNER="$TMP/planner.py" PLAN_ARGS="$TMP/plan-args" PLAN_OUT="$po" PLAN_RC="$prc" \
    bash "$RUN" --jobs 4 "$@" 2>&1); RC=$?
}
crun "green chatty-a" 0 --changed base-ref
eq "$RC" 0 "--changed: rc 0"
eq "$(last)" "XANH 2/2 suite" "--changed: only the two planned suites ran"
has "$OUT" "################ chatty-a" "…chatty-a ran"
hasnt "$OUT" "################ chatty-b" "…chatty-b, not planned, did not"
eq "$(printf '%s\n' "$OUT" | head -n 1)" "plan: stub — planned" "…and the planner's stderr line comes first"
eq "$(cat "$TMP/plan-args")" "base-ref" "the planner gets the base (no head: the working tree)"
crun "green" 0 --changed @merge-parent:0123abc
eq "$(cat "$TMP/plan-args")" "@merge-parent:0123abc" "--changed @merge-parent:<pr head> (test.yml on a PR): the planner gets the word as it is"
crun "green" 0 --changed base-ref --head head-ref
eq "$(cat "$TMP/plan-args")" "base-ref head-ref" "--head is passed to the planner as its second argument"
eq "$(last)" "XANH 1/1 suite" "…one planned suite, one run"
crun "chatty" 0 --changed b
eq "$(last)" "XANH $NSTUB/$NSTUB suite" "exact names: a planned 'chatty' (a substring of two suites) has no file, so the full suite runs"
has "$OUT" "plan: \`chatty\` has no tests/test-chatty.sh: running the full suite" "…and run-all says why"
crun "green" 3 --changed b
eq "$(last)" "XANH $NSTUB/$NSTUB suite" "a planner that exits 3: the full suite runs"
has "$OUT" "plan: the planner failed (rc 3): running the full suite" "…and run-all says why"
crun "" 0 --changed b
eq "$(last)" "XANH $NSTUB/$NSTUB suite" "a planner that prints no suite: the full suite runs"
crun "ledger green greenslow chatty-a chatty-b" 0 --changed b
hasnt "$OUT" "FAIL " "a plan with the ledger: it still runs last, after the others left their counts"
crun "green" 0 --changed b green
eq "$RC" 2 "--changed with filter words: rc 2 (refused)"
crun "green" 0 --head h
eq "$RC" 2 "--head without --changed: rc 2 (refused)"
crun "green" 0 --changed
eq "$RC" 2 "--changed without a base: rc 2"
run "$GREENDIR" --jobs 4
eq "$(last)" "XANH $NSTUB/$NSTUB suite" "without --changed: every suite, as before"

echo "== RUN_ALL_MODE: plan under --changed, full otherwise, whatever the caller exported =="
# A suite may skip its planted breaks only when RUN_ALL_MODE is exactly `plan`; the scheduled full run must never inherit `plan`.
MODEDIR="$TMP/stubs-mode"; mkdir -p "$MODEDIR"
mk_stub "$MODEDIR" mode 'echo "mode=[${RUN_ALL_MODE-unset}]"' 'ok mode' 'summary'
mrun() {  # mrun <inherited RUN_ALL_MODE or -> <PLAN_RC> <run-all args…> — the planner plans `mode`
  local inh=$1 prc=$2; shift 2
  local e=(env -u NET_LOG -u RUN_ALL_MODE); [ "$inh" = - ] || e+=(RUN_ALL_MODE="$inh")
  OUT=$("${e[@]}" RUN_ALL_SUITE_DIR="$MODEDIR" RUN_ALL_PLANNER="$TMP/planner.py" PLAN_ARGS="$TMP/plan-args" PLAN_OUT=mode PLAN_RC="$prc" \
    bash "$RUN" "$@" 2>&1); RC=$?
}
for j in 4 1; do
  mrun - 0 --jobs "$j" --changed b;      has "$OUT" "mode=[plan]" "mode [--jobs $j]: --changed → the suite sees RUN_ALL_MODE=plan"
  mrun - 3 --jobs "$j" --changed b;      has "$OUT" "mode=[plan]" "mode [--jobs $j]: --changed whose planner fails (full suite) → still plan"
  mrun - 0 --jobs "$j";                  has "$OUT" "mode=[full]" "mode [--jobs $j]: no --changed → full"
  mrun plan 0 --jobs "$j";               has "$OUT" "mode=[full]" "mode [--jobs $j]: an inherited RUN_ALL_MODE=plan without --changed → full (overwritten)"
  mrun full 0 --jobs "$j" --changed b;   has "$OUT" "mode=[plan]" "mode [--jobs $j]: an inherited RUN_ALL_MODE=full under --changed → plan (overwritten)"
done
eq "$RC" 0 "mode: the stub suite is green"

echo "== the suites' trees go under RUNNER_TEMP when only that is set =="
# On the CI runner /tmp is a 1 GiB volume and RUNNER_TEMP a 4 GiB one: run-all points TMPDIR at a
# directory of its own under RUNNER_TEMP, and removes it. A TMPDIR the caller set stays; no RUNNER_TEMP (or a missing one) changes nothing.
TDIR="$TMP/stubs-tmpdir"; mkdir -p "$TDIR"
mk_stub "$TDIR" where 'echo "tmpdir=[${TMPDIR-unset}]"' 'ok where' 'summary'
RT="$TMP/runner-temp"; mkdir -p "$RT"; CUSTOM="$TMP/custom-tmp"; mkdir -p "$CUSTOM"
trun() {  # trun <command to run run-all: bash or a copy> <env words…> — OUT/RC; TMPDIR and RUNNER_TEMP are unset unless a word sets them
  local runner=$1; shift
  OUT=$(env -u NET_LOG -u TMPDIR -u RUNNER_TEMP "$@" RUN_ALL_SUITE_DIR="$TDIR" bash "$runner" --jobs 1 2>&1); RC=$?
}
trun "$RUN" RUNNER_TEMP="$RT"
has "$OUT" "tmpdir=[$RT/run-all." "RUNNER_TEMP alone: the suite's TMPDIR is a run-all directory under it"
eq "$RC" 0 "…and the run is green"
eq "$(ls -A "$RT" | wc -l | tr -d ' ')" 0 "…and run-all removed that directory when it ended"
trun "$RUN" RUNNER_TEMP="$RT" TMPDIR="$CUSTOM"
has "$OUT" "tmpdir=[$CUSTOM]" "RUNNER_TEMP and TMPDIR both set: the caller's TMPDIR stays"
eq "$(ls -A "$RT" | wc -l | tr -d ' ')" 0 "…and nothing is made under RUNNER_TEMP"
trun "$RUN"
has "$OUT" "tmpdir=[unset]" "neither set: TMPDIR is left unset"
trun "$RUN" RUNNER_TEMP="$TMP/no-such-dir"
has "$OUT" "tmpdir=[unset]" "RUNNER_TEMP that is not a directory: TMPDIR is left unset"
mk_stub "$TDIR" zred 'echo "tmpdir=[${TMPDIR-unset}]"' 'bad "planted red"' 'summary'
trun "$RUN" RUNNER_TEMP="$RT"
eq "$RC" 1 "a red suite makes the run red"
eq "$(ls -A "$RT" | wc -l | tr -d ' ')" 0 "…and the directory under RUNNER_TEMP is removed after a red run too"
rm -f "$TDIR/test-zred.sh"
trun_out() { trun "$@"; printf '%s' "$OUT"; }
# BRKT <label> <sed expression on run-all.sh> <needle> — a copy of run-all.sh with one break; the case above for RUNNER_TEMP alone must go red
BRKT() {
  local f="$TMP/run-all-$1.sh" out
  sed "$2" "$RUN" > "$f"
  ne "$(cmp -s "$RUN" "$f"; echo $?)" 0 "instrument: [$1] changes run-all.sh"
  out=$(capped trun_out "$f" RUNNER_TEMP="$RT"; printf '\n[left %s]' "$(ls -A "$RT" | wc -l | tr -d ' ')")
  has "$out" "$3" "break [$1]: the RUNNER_TEMP case goes red"
  rm -rf "${RT:?}"/*
}
BRKT no-runner-temp 's#^if \[ -n "${RUNNER_TEMP:-}" \] && \[ -z "${TMPDIR:-}" \] && \[ -d "$RUNNER_TEMP" \]; then$#if false; then#' 'tmpdir=[unset]'
BRKT dir-kept 's#^cleanup() { rm -rf "$SUITE_RESULTS_DIR" "$OUTDIR" .*#cleanup() { rm -rf "$SUITE_RESULTS_DIR" "$OUTDIR"; }#' '[left 1]'

echo "== the default suite directory is the real one =="
OUT=$(bash "$RUN" --jobs 2 batonrun-standard 2>&1); RC=$?
eq "$RC" 0 "no RUN_ALL_SUITE_DIR: the real suite 'batonrun-standard' runs"
eq "$(printf '%s\n' "$OUT" | tail -n 1)" "XANH 1/1 suite" "…and the last line is 'XANH 1/1 suite'"

echo; summary
