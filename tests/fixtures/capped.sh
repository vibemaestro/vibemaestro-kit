# shellcheck shell=bash
# =============================================================================
# capped — a memory cap and a wall-time cap for a planted-break run (sourced by lib.sh; defines functions only)
# =============================================================================
# Why: a planted break can build a 2.3 GB list in 5 s and the CI runner is lost with no log. A planted break is a program
# that is wrong on purpose, so a suite must not hand it the machine. Every red-expected run goes through `capped`; a green-expected
# run never does.
#
#   capped <command or shell function> [args…]   runs it in its own process group; stdout, stderr, stdin and the exit code are its own,
#                                                except when a cap fires:
#     rc 247  the wall-time cap fired   (CAP_RC_TIME)   stderr: `cap hit: wall time 600s`
#     rc 248  the memory cap fired      (CAP_RC_MEM)    stderr: `cap hit: memory 1024MB (group at 1210MB)`
#   A command that exits 247 or 248 on its own is indistinguishable from a cap hit: no healthy command in the repo does.
#   cap_red <rc> <label>                         rc 247/248: prints `ok   <label>: red by the memory|time cap`, returns 0 (the caller
#                                                counts the break as caught and skips that break's other assertions); else returns 1.
#   Every hit is also counted in $TMPDIR/.cap-hits, and summary (lib.sh) prints `note: N planted run(s) ended by a cap`, so a cap that is
#   set too low, or exported by mistake, shows in the suite's output instead of passing every break as "caught".
#
# Caps (environment, whole numbers, 0 switches that cap off; anything else stops the suite at source time):
#   PLANT_CAP_MEM_MB  default 1024  the summed resident size (RSS) of every process of the run, polled every 0.25 s. Resident, not
#                                   virtual, because that is what starves a runner and because a probe may reserve a lot and touch
#                                   little (a mutant `CAP = 1 << 40` reserves 1 TB at under 100 MB resident). A
#                                   fork, a child or a touched mapping shows up; an untouched mapping costs nothing.
#   PLANT_CAP_SECS    default 600   wall time of the run.
#   PLANT_CAP_VMEM_MB default 0     off. A per-process `ulimit -v` set in the run (inherited by its children, not summed): the
#                                   backstop for an allocator faster than one poll interval. A stop by it is the program's own
#                                   failure (MemoryError, ENOMEM): red like any non-zero exit, not labelled as a cap.
#   PLANT_CAP_LOG     unset         a file: one line per capped run, `rc peak_MB seconds command`, to retune the defaults.
#
# What it reaches, and what it does not:
#   - The run, its children, a child that changed its process group, one that called setsid and is still a child: found through the
#     process table (group, then parent chain) and killed with the group. A run that daemonised (double fork + setsid) is found through
#     the token CAPPED_RUN=<id> that every process of the run inherits, by reading /proc/*/environ (Linux); it is counted for memory
#     and killed. Where there is no /proc, or the daemon cleared its environment (`env -i`), it is not.
#   - The same cleanup runs when the run ends by itself: an orphan left behind would hold the pipe of a `$(...)` capture open past the
#     time cap.
#   - Overshoot: the memory cap is checked every 0.25 s, so the group can pass it by (number of allocating processes) x (allocation
#     rate) x 0.25 s before it is killed (one process at a rate of 0.5 GB/s: about 125 MB; eight at 1 GB in one go: gigabytes).
#     PLANT_CAP_VMEM_MB is the answer where that matters.
#   - RSS counts a shared page once per process, so a run of many small processes reads high (conservative); memory that is not process
#     RSS (files in tmpfs such as /dev/shm) is not counted.
#   - The watchdog is a sibling of the run; a break that kills its siblings (`pkill`, `kill -KILL -- -$$`) stops both caps.
#   - Where `ulimit -v` does not work (macOS) the backstop says so on stderr and the other caps hold; where `ps` gives no sizes the memory
#     cap says it is not enforced and the time cap holds.
#   - Side effects: it uses fd 9 for a moment; `$!` is the watchdog's pid afterwards; a run that reads a terminal is stopped by SIGTTIN
#     (job control puts it in a background group) until the time cap; the time cap can fire up to a second after the number of seconds.
# =============================================================================

CAP_RC_TIME=247; CAP_RC_MEM=248
for _cap_v in PLANT_CAP_MEM_MB PLANT_CAP_SECS PLANT_CAP_VMEM_MB; do
  case "${!_cap_v-0}" in ''|*[!0-9]*) echo "capped.sh: $_cap_v must be a whole number of MB or seconds (0 = off), got '${!_cap_v}'" >&2; exit 2;; esac
done
unset _cap_v

# _cap_sweep <token> — the pids of every process whose environment carries the token (Linux; prints nothing elsewhere)
_cap_sweep() {
  [ -d /proc/self ] || return 0
  grep -laF "CAPPED_RUN=$1" /proc/[0-9]*/environ 2>/dev/null | sed 's|/proc/\([0-9]*\)/environ|\1|'
}

# _cap_tree <root pid> [<extra pids, whitespace separated>] — one line `rss_kb pid pid …`: the root's process group, every descendant
# of the root and the extra pids
_cap_tree() {
  ps -eo pid=,ppid=,pgid=,rss= 2>/dev/null | awk -v root="$1" -v extra="${2:-}" '
    { pid[NR]=$1; ppid[NR]=$2; pgid[NR]=$3; rss[NR]=$4; n=NR }
    END {
      in_set[root]=1
      m=split(extra, ex, " "); for (i=1; i<=m; i++) in_set[ex[i]]=1
      do { grew=0
        for (i=1; i<=n; i++) if (!(pid[i] in in_set) && ((ppid[i] in in_set) || pgid[i]==root)) { in_set[pid[i]]=1; grew=1 }
      } while (grew)
      for (i=1; i<=n; i++) if (pid[i] in in_set) { s+=rss[i]; list=list " " pid[i] }
      print s+0 list
    }'
}

# _cap_kill <root pid> <token> — kill the group, the descendants and the token carriers; repeat until nothing of them is left
_cap_kill() {
  local i line p
  for i in 1 2 3 4 5; do
    line=$(_cap_tree "$1" "$(_cap_sweep "$2")")
    kill -KILL -- "-$1" 2>/dev/null
    case "$line" in
      *" "*) for p in ${line#* }; do kill -KILL "$p" 2>/dev/null; done;;
      *) break;;   # nothing left (or no ps: only the group was signalled, never pid 0, our own group)
    esac
    sleep 0.05
  done
}

capped() {
  local mb=${PLANT_CAP_MEM_MB:-1024} secs=${PLANT_CAP_SECS:-600} vmb=${PLANT_CAP_VMEM_MB:-0}
  local v
  for v in "$mb" "$secs" "$vmb"; do
    case "$v" in ''|*[!0-9]*) echo "capped: the caps must be whole numbers (memory '$mb' MB, time '$secs' s, address space '$vmb' MB)" >&2; return 2;; esac
  done
  local pid wd rc mark tok had_m=0 t0=$SECONDS
  mark=$(mktemp "${TMPDIR:-/tmp}/capped.XXXXXX")
  tok="$$.$RANDOM$RANDOM.$SECONDS"
  case $- in *m*) had_m=1;; esac
  set -m   # the run becomes the leader of a process group of its own
  { exec 9<&0; } 2>/dev/null || exec 9</dev/null   # a background job gets /dev/null for stdin; the run is given the caller's
  (
    trap - EXIT   # the caller's cleanup trap (rm -rf "$TMP") must not run in the run's subshell
    exec 9<&-
    export CAPPED_RUN=$tok
    if [ "$vmb" -gt 0 ]; then
      ulimit -v $((vmb * 1024)) 2>/dev/null || echo "cap: ulimit -v is not available here: the backstop is not set" >&2
    fi
    "$@"
  ) <&9 &
  pid=$!
  exec 9<&-
  [ "$had_m" = 1 ] || set +m
  (
    trap - EXIT
    local t=$SECONDS peak=0 line rss said=0
    while kill -s 0 "$pid" 2>/dev/null; do   # (a liveness probe of the run itself)
      sleep 0.25 >/dev/null 2>&1   # its own fds closed to the caller: a killed watchdog must not leave a sleep holding a `$(...)` pipe open
      line=$(_cap_tree "$pid" "$(_cap_sweep "$tok")"); rss=${line%% *}
      [ "${rss:-0}" -gt "$peak" ] && peak=$rss
      echo "peak $((peak / 1024))" > "$mark.peak"
      if [ "$secs" -gt 0 ] && [ $((SECONDS - t)) -gt "$secs" ]; then echo time > "$mark"
      elif [ "$mb" -gt 0 ] && [ "${rss:-0}" -gt $((mb * 1024)) ]; then echo "memory $((rss / 1024))" > "$mark"
      else
        if [ "$mb" -gt 0 ] && [ "$said" = 0 ] && [ "${rss:-0}" -eq 0 ]; then
          echo "cap: the memory cap is not enforced here (ps gave no sizes)" >&2; said=1
        fi
        continue
      fi
      _cap_kill "$pid" "$tok"
      exit 0
    done
  ) >/dev/null &
  wd=$!
  { wait "$pid"; } 2>/dev/null; rc=$?
  kill -KILL "$wd" 2>/dev/null; { wait "$wd"; } 2>/dev/null   # KILL, not TERM: a TERM that lands before the subshell clears its traps runs the caller's EXIT trap
  _cap_kill "$pid" "$tok"   # whatever the run left behind: an orphan would hold the pipe of a `$(...)` capture open
  case "$(cat "$mark" 2>/dev/null)" in
    time*)   echo "cap hit: wall time ${secs}s" >&2; rc=$CAP_RC_TIME; echo "$rc" >> "${TMPDIR:-/tmp}/.cap-hits" 2>/dev/null;;
    memory*) echo "cap hit: memory ${mb}MB (group at $(cut -d' ' -f2 "$mark")MB)" >&2; rc=$CAP_RC_MEM; echo "$rc" >> "${TMPDIR:-/tmp}/.cap-hits" 2>/dev/null;;
  esac
  if [ -n "${PLANT_CAP_LOG:-}" ]; then
    echo "$rc $(sed -n 's/^peak //p' "$mark.peak" 2>/dev/null | head -1) $((SECONDS - t0)) $1" >> "$PLANT_CAP_LOG" 2>/dev/null
  fi
  rm -f "$mark" "$mark.peak"
  return $rc
}

cap_red() {  # cap_red <rc> <label>
  case "$1" in
    "$CAP_RC_TIME") ok "$2: red by the time cap";;
    "$CAP_RC_MEM")  ok "$2: red by the memory cap";;
    *) return 1;;
  esac
}
