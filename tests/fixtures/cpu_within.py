#!/usr/bin/env python3
"""cpu_within <cpu seconds> <command...> — bound a scan by its own CPU time, not by the clock.

Prints the command's rc (stdout and stderr of the command are dropped), or `cpu` when the command used more than <cpu seconds> of CPU
(user+sys, summed over the command and the children it waited for), or `timeout` when the wall-clock backstop ran out (a hang).

Why: a check that a scan is linear ("in under 5 s") must go red for a super-linear regex and stay green on a loaded runner. Wall time
measures the runner's load; CPU time measures the scan. Two measures work together: RLIMIT_CPU kills a runaway scan at the bound (a
regression fails in seconds, not after minutes), and getrusage of the waited-for children is the verdict (it adds the processes of a
command that runs other programs, which a per-process limit does not).

The wall-clock backstop is CPU_WITHIN_WALL seconds (default 120); the whole command group is killed when it runs out, when this
script is stopped (SIGTERM, SIGINT) and when it ends, so no background child of the command outlives the check.
"""
import os
import resource
import signal
import subprocess
import sys


def main(argv):
    if len(argv) < 3:
        print("usage: cpu_within.py <cpu seconds> <command...>", file=sys.stderr)
        return 2
    limit = float(argv[1])
    wall = float(os.environ.get("CPU_WITHIN_WALL", "120"))
    soft = int(limit) if limit == int(limit) else int(limit) + 1

    def cap():
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))  # SIGXCPU's default action dumps core: not into the caller's directory
        resource.setrlimit(resource.RLIMIT_CPU, (soft, soft + 1))

    def kill_group():
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

    def stopped(signum, _frame):
        kill_group()
        sys.exit(128 + signum)

    before = resource.getrusage(resource.RUSAGE_CHILDREN)
    p = subprocess.Popen(argv[2:], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, preexec_fn=cap, start_new_session=True)
    signal.signal(signal.SIGTERM, stopped)
    signal.signal(signal.SIGINT, stopped)
    try:
        try:
            rc = p.wait(timeout=wall)
        except subprocess.TimeoutExpired:
            kill_group()
            p.wait()
            print("timeout")
            return 0
        after = resource.getrusage(resource.RUSAGE_CHILDREN)
        used = (after.ru_utime - before.ru_utime) + (after.ru_stime - before.ru_stime)
        print("cpu" if used > limit or rc == -signal.SIGXCPU else rc)
        return 0
    finally:
        kill_group()


if __name__ == "__main__":
    sys.exit(main(sys.argv))
