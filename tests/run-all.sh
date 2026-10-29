#!/bin/bash
# =============================================================================
# Chạy MỌI suite của repo: bash tests/run-all.sh
# =============================================================================
# Không cần secret, không cần repo nào khác, không cần checkout của hub, không đặt VIBEMAESTRO_HUB.
#   bash tests/run-all.sh                 chạy tất cả tests/test-*.sh, song song (số job mặc định từ số CPU, trần 8; under a cgroup v2 CPU
#                                         quota, at most that many CPUs: nproc shows the node's CPUs in a pod, not the quota)
#   bash tests/run-all.sh hook thu-tuc    chỉ các suite có tên chứa một trong các từ đó
#   bash tests/run-all.sh --changed <base> [--head <ref>]
#                                         only the suites tests/plan.py plans for the diff from the merge-base of <base> to <head>
#                                         (no --head: the working tree, uncommitted and untracked files included); exact names, the
#                                         planner's `plan:` line printed first. The planner exits non-zero, or names a suite with no
#                                         file here: the full suite runs. Not with filter words. Without --changed: as before.
#                                         <base> `@merge-parent:<pr head>` (test.yml on a PR): from the first parent of the merge
#                                         commit checked out, full when HEAD is not a two-parent merge of <pr head> (tests/plan.py)
#   bash tests/run-all.sh --jobs N …      N job song song; --jobs 1 = tuần tự đúng thứ tự cũ (bảng chữ cái)
#   RUN_ALL_JOBS=N bash tests/run-all.sh  như --jobs N (cờ thắng biến)
#   PLUGIN_REQUIRE_CLAUDE=1 bash …        thiếu CLI `claude` thì ĐỎ (mặc định: phần CLI SKIP, kêu to)
#   RUN_ALL_SUITE_DIR=<dir>               chỉ dành cho tests/test-run-all.sh: thư mục chứa test-*.sh thay cho thư mục này
#   RUN_ALL_PLANNER=<file>                only for tests/test-run-all.sh: the planner script run instead of tests/plan.py
#   RUN_ALL_CGROUP_DIR=<dir>              only for tests/test-run-all.sh: the cgroup v2 directory read instead of /sys/fs/cgroup
# Before its last line (and when INT/TERM stops it) the run prints `resources: …`: the jobs and why, and where the files exist the OOM
# kills during the run (memory.events), the cgroup's memory and pids peaks with their limits (peaks since the cgroup began, not only
# this run: on CI the job's container) and kernel.pid_max. Why: a suite stopped by SIGKILL (137) is an OOM only if that count moved;
# on the k3s runner an OOM kills the whole container (memory.oom.group), not one step.
# Every suite gets RUN_ALL_MODE, always set here (an inherited value is overwritten): `plan` under --changed (test.yml on a PR, a
# worker's local run; also when the planner falls back to the full suite), `full` otherwise (the scheduled
# test-full.yml, `bash tests/run-all.sh`).
# A suite may leave its slow mutation-style checks (planted breaks) to the full run; only the exact value `plan` may skip them, so a
# suite run alone, with no RUN_ALL_MODE, runs everything.
# rc 0 = mọi suite xanh. Mỗi suite in dòng tổng kết "N ok, M fail".
#
# Song song: mỗi suite chạy trong tiến trình riêng, đầu ra đệm vào một file và được in NGUYÊN KHỐI khi suite xong
# (không xen kẽ). Suite độc lập vì mỗi suite có cây mktemp, HOME, TMPDIR và GIT_CONFIG_GLOBAL riêng (lib.sh clean_env);
# phần đã đo được (bytecode ghi vào repo) do [L2] của tests/test-capped-breaks.sh canh. Ngoại lệ: suite `ledger` đọc số ok của các suite khác (SUITE_RESULTS_DIR)
# nên khi song song nó chạy SAU CÙNG; --jobs 1 giữ nguyên thứ tự bảng chữ cái cũ.
# Khác nhau giữa hai chế độ: song song thì stderr gộp vào stdout của khối, stdin là /dev/null, và tiến trình nền một suite bỏ lại in sau
# khi suite thoát thì mất. INT/TERM dừng cả các suite đang chạy (rc 130/143).
#
# Cổng "cây làm việc không đổi": trước khi chạy suite đầu, run-all ghi HEAD, nhánh đang đứng và dấu của index của repo chứa chính nó
# (`git rev-parse HEAD`, `git symbolic-ref -q HEAD`, `git ls-files -s | cksum`); sau suite cuối (và khi INT/TERM) ghi lại, khác thì
# in từng thứ khác và ĐỎ (rc 1) dù mọi suite xanh. Vì sao: một suite từng commit vào cây thật thay vì repo tạm của nó.
# So trước/sau, nên chạy trên cây bẩn vẫn được: chỉ phép đổi mới tính. Không phải
# git work tree thì in một dòng "guard: … skipped" rồi chạy tiếp. File chưa theo dõi hay sửa dở không thuộc cổng này.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SUITE_DIR=${RUN_ALL_SUITE_DIR:-$HERE}
export PYTHONDONTWRITEBYTECODE=1

JOBS=${RUN_ALL_JOBS:-}
FILTER=()
CHANGED=0; BASE=""; HEAD_REF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --jobs|-j) [ $# -ge 2 ] || { echo "FAIL: $1 cần một số"; exit 2; }; JOBS=$2; shift 2;;
    --jobs=*)  JOBS=${1#--jobs=}; shift;;
    --changed) [ $# -ge 2 ] || { echo "FAIL: --changed needs a base ref"; exit 2; }; CHANGED=1; BASE=$2; shift 2;;
    --head)    [ $# -ge 2 ] || { echo "FAIL: --head needs a ref"; exit 2; }; HEAD_REF=$2; shift 2;;
    *)         FILTER+=("$1"); shift;;
  esac
done
if [ "$CHANGED" = 0 ] && [ -n "$HEAD_REF" ]; then echo "FAIL: --head only goes with --changed"; exit 2; fi
if [ "$CHANGED" = 1 ] && [ ${#FILTER[@]} -gt 0 ]; then echo "FAIL: --changed does not take filter words (${FILTER[*]})"; exit 2; fi
if [ "$CHANGED" = 1 ]; then RUN_ALL_MODE=plan; else RUN_ALL_MODE=full; fi
export RUN_ALL_MODE
CGROUP_DIR=${RUN_ALL_CGROUP_DIR:-/sys/fs/cgroup}
if [ -z "$JOBS" ]; then
  # CPU count (Linux, macOS), capped: more jobs than this only adds contention for the few slow suites.
  JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)
  case "$JOBS" in ''|*[!0-9]*) JOBS=2;; esac
  JOBS_WHY="$JOBS CPUs"
  # A cgroup v2 CPU quota (cpu.max: "<quota> <period>", or "max <period>" for none) below that: no more suites than the CPUs the run
  # may use. Past the quota the suites are throttled, which widens every timing race (measured: 8 jobs on a 6-CPU runner pod).
  if { read -r CPU_Q CPU_P < "$CGROUP_DIR/cpu.max"; } 2>/dev/null; then
    case "$CPU_Q.$CPU_P" in
      *[!0-9.]*|.*|*.|*.0) ;;
      *) CPU_N=$((CPU_Q / CPU_P)); [ "$CPU_N" -ge 1 ] || CPU_N=1
         if [ "$CPU_N" -lt "$JOBS" ]; then JOBS_WHY="cpu quota $CPU_N of $JOBS CPUs"; JOBS=$CPU_N; fi;;
    esac
  fi
  if [ "$JOBS" -gt 8 ]; then JOBS_WHY="cap 8 of $JOBS_WHY"; JOBS=8; fi
else
  JOBS_WHY="asked"
fi
case "$JOBS" in ''|*[!0-9]*|0) echo "FAIL: số job phải là số nguyên dương, được '$JOBS'"; exit 2;; esac

# On a CI runner /tmp is a small volume (1 GiB on the k3s runner pod) and RUNNER_TEMP, under the work directory, a large one (4 GiB):
# the suites' trees go there, in a directory of this run that cleanup removes. A TMPDIR the caller set is left as it is.
RUNNER_TMP_OWN=""
if [ -n "${RUNNER_TEMP:-}" ] && [ -z "${TMPDIR:-}" ] && [ -d "$RUNNER_TEMP" ]; then
  if RUNNER_TMP_OWN=$(mktemp -d "$RUNNER_TEMP/run-all.XXXXXX" 2>/dev/null); then export TMPDIR="$RUNNER_TMP_OWN"; else RUNNER_TMP_OWN=""; fi
fi

# what the run had and used, from the cgroup v2 files that exist (none outside Linux): one line printed before the last one
OOM_BEFORE=$(awk '$1 == "oom_kill" {print $2}' "$CGROUP_DIR/memory.events" 2>/dev/null)
mib() { case "$1" in ''|*[!0-9]*) echo "$1";; *) echo "$(($1 / 1048576)) MiB";; esac; }
resources() {
  local line="resources: jobs $JOBS ($JOBS_WHY)" f v a
  f=$CGROUP_DIR/memory.peak; [ -r "$f" ] && line="$line; cgroup memory peak $(mib "$(cat "$f")") of $(mib "$(cat "$CGROUP_DIR/memory.max" 2>/dev/null)")"
  a=$(awk '$1 == "oom_kill" {print $2}' "$CGROUP_DIR/memory.events" 2>/dev/null)
  case "$OOM_BEFORE.$a" in *[!0-9.]*|.*|*.) ;; *) line="$line; oom kills $((a - OOM_BEFORE))";; esac
  f=$CGROUP_DIR/pids.peak; [ -r "$f" ] && line="$line; cgroup pids peak $(cat "$f") of $(cat "$CGROUP_DIR/pids.max" 2>/dev/null)"
  v=$(cat /proc/sys/kernel/pid_max 2>/dev/null) && line="$line; pid_max $v"
  echo "$line"
}

# Each suite leaves its "ok fail" counts here (lib.sh summary); tests/test-ledger.sh reads them rather than running the suites again.
SUITE_RESULTS_DIR=$(mktemp -d); export SUITE_RESULTS_DIR
OUTDIR=$(mktemp -d)
ROOT_OF_RUN=$(CDPATH= cd -- "$HERE/.." && pwd)
# The guard's git runs without the variables that move a repository (GIT_DIR and friends would point it at another one).
ggit() { env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR -u GIT_OBJECT_DIRECTORY git -C "$ROOT_OF_RUN" "$@"; }
guard_snapshot() {  # → three lines: HEAD, branch, index fingerprint of the repository that holds this script
  ggit rev-parse -q --verify HEAD 2>/dev/null || echo "(unborn)"
  ggit symbolic-ref -q HEAD 2>/dev/null || echo "(detached)"
  ggit ls-files -s 2>&1 | cksum
}
GUARD=0; GUARD_BEFORE=""
if ggit rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  GUARD=1; GUARD_BEFORE=$(guard_snapshot)
else
  echo "guard: not a git work tree, skipped (the worktree-unchanged check needs one)"
fi
GUARD_CHANGED=""
guard_check() {  # sets GUARD_CHANGED to the names of what differs and prints one line per difference; silent when nothing changed
  [ "$GUARD" = 1 ] || return 0
  local after before_h before_b before_i after_h after_b after_i
  after=$(guard_snapshot)
  { read -r before_h; read -r before_b; read -r before_i; } <<EOF_B
$GUARD_BEFORE
EOF_B
  { read -r after_h; read -r after_b; read -r after_i; } <<EOF_A
$after
EOF_A
  GUARD_CHANGED=""
  [ "$before_h" = "$after_h" ] || { GUARD_CHANGED="$GUARD_CHANGED HEAD"; echo "guard: HEAD changed: before $before_h, after $after_h"; }
  [ "$before_b" = "$after_b" ] || { GUARD_CHANGED="$GUARD_CHANGED branch"; echo "guard: branch changed: before $before_b, after $after_b"; }
  [ "$before_i" = "$after_i" ] || { GUARD_CHANGED="$GUARD_CHANGED index"; echo "guard: index changed: fingerprint before $before_i, after $after_i"; }
  GUARD_CHANGED=${GUARD_CHANGED# }
}
cleanup() { rm -rf "$SUITE_RESULTS_DIR" "$OUTDIR" ${RUNNER_TMP_OWN:+"$RUNNER_TMP_OWN"}; }
trap cleanup EXIT
PIDS=()
# On INT/TERM the running suites are stopped too (not only run-all): a CI timeout must not leave orphans writing into a removed tree.
stop() { local p; for p in ${PIDS[@]+"${PIDS[@]}"}; do kill -TERM "$p" 2>/dev/null; done; for p in ${PIDS[@]+"${PIDS[@]}"}; do wait "$p" 2>/dev/null; done; guard_check; resources; exit "$1"; }
trap 'stop 130' INT
trap 'stop 143' TERM

# --changed: the planner's list, exact names. Anything it cannot give (rc != 0, a name with no suite file) is the full suite.
PLANNED=""
if [ "$CHANGED" = 1 ]; then
  PLANNER=${RUN_ALL_PLANNER:-$HERE/plan.py}
  PLAN_ERR="$OUTDIR/plan.err"
  if PLAN_OUT=$(python3 "$PLANNER" "$BASE" ${HEAD_REF:+"$HEAD_REF"} 2>"$PLAN_ERR"); then
    cat "$PLAN_ERR"
    PLANNED=$'\n'"$PLAN_OUT"$'\n'
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      if [ ! -f "$SUITE_DIR/test-$p.sh" ]; then echo "plan: \`$p\` has no tests/test-$p.sh: running the full suite"; PLANNED=""; break; fi
    done <<< "$PLAN_OUT"
    [ -n "$PLAN_OUT" ] || { echo "plan: the planner printed no suite: running the full suite"; PLANNED=""; }
  else
    rc=$?; cat "$PLAN_ERR"; echo "plan: the planner failed (rc $rc): running the full suite"
  fi
fi

NAMES=(); FILES=()
for f in "$SUITE_DIR"/test-*.sh; do
  [ -f "$f" ] || continue
  n=$(basename "$f" .sh); n=${n#test-}
  if [ -n "$PLANNED" ]; then
    case "$PLANNED" in *$'\n'"$n"$'\n'*) ;; *) continue;; esac
  fi
  if [ ${#FILTER[@]} -gt 0 ]; then
    m=0; for w in "${FILTER[@]}"; do case "$n" in *"$w"*) m=1;; esac; done
    [ "$m" = 1 ] || continue
  fi
  NAMES+=("$n"); FILES+=("$f")
done
TOTAL=${#NAMES[@]}
RCS=()

show() {  # show <index> — print one finished suite's block
  echo "################ ${NAMES[$1]}"
  cat "$OUTDIR/$1.out"
}

if [ "$TOTAL" -gt 0 ]; then
  if [ "$JOBS" -eq 1 ]; then
    for i in "${!NAMES[@]}"; do
      echo "################ ${NAMES[$i]}"
      bash "${FILES[$i]}"; RCS[$i]=$?
    done
  else
    # Order of launch: the known-slow suites first (longest first), then every other suite but `ledger` in alphabetical order, then
    # `ledger` once all the others are done. Why: the longest suite sets the wall time of the run only if it starts early; in
    # alphabetical order a 40-minute suite started after the first 50 and the run met its 45-minute timeout.
    # The list is a launch order only, never a filter: a name that is not in this run (a filter, a plan) is skipped.
    SLOW_FIRST=(merge-guard plugin-version baton baton-gh-write config)
    ORDER=(); LEDGER=-1
    for n in "${SLOW_FIRST[@]}"; do
      for i in "${!NAMES[@]}"; do [ "${NAMES[$i]}" = "$n" ] && ORDER+=("$i"); done
    done
    for i in "${!NAMES[@]}"; do
      case " ${SLOW_FIRST[*]} " in *" ${NAMES[$i]} "*) continue;; esac
      if [ "${NAMES[$i]}" = ledger ]; then LEDGER=$i; else ORDER+=("$i"); fi
    done
    NEXT=0; RUNNING=(); DONE=0; LEDGER_STARTED=0
    start() { # start <index> — the suite itself is the background job, so its pid is the one a signal must reach
      bash "${FILES[$1]}" > "$OUTDIR/$1.out" 2>&1 < /dev/null &
      PIDS[$1]=$!
      RUNNING+=("$1")
    }
    while [ "$DONE" -lt "$TOTAL" ]; do
      # reap finished suites, print each block as it finishes
      STILL=()
      if [ ${#RUNNING[@]} -gt 0 ]; then
        for i in "${RUNNING[@]}"; do
          # bash reaps a finished job and keeps its status; `kill -0` then fails and `wait <pid>` returns that status
          if kill -0 "${PIDS[$i]}" 2>/dev/null; then STILL+=("$i"); else wait "${PIDS[$i]}"; RCS[$i]=$?; unset "PIDS[$i]"; show "$i"; DONE=$((DONE+1)); fi
        done
      fi
      RUNNING=(); [ ${#STILL[@]} -eq 0 ] || RUNNING=("${STILL[@]}")
      # fill the free slots
      while [ ${#RUNNING[@]} -lt "$JOBS" ] && [ "$NEXT" -lt ${#ORDER[@]} ]; do start "${ORDER[$NEXT]}"; NEXT=$((NEXT+1)); done
      if [ "$NEXT" -ge ${#ORDER[@]} ] && [ ${#RUNNING[@]} -eq 0 ] && [ "$LEDGER" -ge 0 ] && [ "$LEDGER_STARTED" = 0 ]; then
        start "$LEDGER"; LEDGER_STARTED=1
      fi
      [ "$DONE" -lt "$TOTAL" ] && sleep 0.1
    done
    wait
  fi
fi

resources
echo "################"
if [ "$TOTAL" -eq 0 ]; then echo "FAIL: không suite nào được chạy"; exit 1; fi
RED=()
for i in "${!NAMES[@]}"; do
  [ "${RCS[$i]}" -eq 0 ] || RED+=("${NAMES[$i]} (rc ${RCS[$i]})")
done
guard_check
if [ ${#RED[@]} -gt 0 ]; then
  echo "ĐỎ ${#RED[@]}/$TOTAL suite: ${RED[*]}${GUARD_CHANGED:+; guard: the worktree changed during the run ($GUARD_CHANGED)}"; exit 1
fi
if [ -n "$GUARD_CHANGED" ]; then echo "ĐỎ guard: the worktree changed during the run ($GUARD_CHANGED)"; exit 1; fi
echo "XANH $TOTAL/$TOTAL suite"
