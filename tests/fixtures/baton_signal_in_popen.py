"""baton_signal_in_popen.py <SIGNAME[+SIGNAME…]> <ready file> <baton.py> <baton args...>: run baton.py and send it the signals, in
that order, from inside subprocess.Popen while it starts the phase's process.

Only the phase's own Popen (its env carries BATON_PHASE), not baton's other subprocesses. After the child is started, and before
Popen returns, this waits for <ready file> (the act under test makes it once it has started a child of its own), then signals baton:
the point where an act's own `kill -TERM "$PPID"` lands when baton is slow to leave Popen (under load). Several names: the signals
are all pending at once when baton unblocks them. Used by tests/test-baton.sh (fam_start_interrupt). Waits at most 20 seconds for
the file, then signals anyway.
"""
import os
import runpy
import signal
import subprocess
import sys
import time

sigs, ready = [getattr(signal, n) for n in sys.argv[1].split("+")], sys.argv[2]
_execute_child = subprocess.Popen._execute_child


def execute_child(self, *args, **kwargs):
    _execute_child(self, *args, **kwargs)
    env = args[6] if len(args) > 6 else kwargs.get("env")
    if not (env and env.get("BATON_PHASE")):
        return
    end = time.time() + 20
    while not os.path.exists(ready) and time.time() < end:
        time.sleep(0.01)
    for sig in sigs:
        os.kill(os.getpid(), sig)


if signal.SIGINT in sigs:   # a caller that ignores SIGINT (a background job) would leave Python without its handler
    signal.signal(signal.SIGINT, signal.default_int_handler)
subprocess.Popen._execute_child = execute_child
sys.argv = sys.argv[3:]
runpy.run_path(sys.argv[0], run_name="__main__")
