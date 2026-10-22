"""baton_term_at.py [--log-dir D] <prefix> <command...>: run the command, send it SIGTERM when an output line starts with <prefix>,
print its rc.

The command's output goes to stdout as it comes. With --log-dir, the line is looked for in the files of D as well (`baton go`
writes a run's output to its run log under runs/ and prints only one line); files already in D are left out. Used by tests/test-baton.sh (fam_go_retry)
to interrupt `baton go` while it waits to read a failed post-check again. Prints "no-line" and stops the command when the line
never comes within 30 seconds.
"""
import os
import signal
import subprocess
import sys
import threading
import time

log_dir = None
args = sys.argv[1:]
if args[:1] == ["--log-dir"]:
    log_dir, args = args[1], args[2:]
prefix, cmd = args[0], args[1:]
try:
    before = set(os.listdir(log_dir)) if log_dir else set()     # earlier runs' logs are not this run's
except OSError:
    before = set()
proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
seen = []
lock = threading.Lock()
timer = threading.Timer(30, proc.kill)
timer.start()


def hit(line):
    with lock:
        if not seen and line.startswith(prefix):
            seen.append(line)
            proc.send_signal(signal.SIGTERM)


def watch():
    while proc.poll() is None and not seen:
        try:
            names = os.listdir(log_dir)
        except OSError:
            names = []
        for n in sorted(set(names) - before):
            try:
                with open(os.path.join(log_dir, n), encoding="utf-8", errors="replace") as f:
                    for line in f:
                        hit(line)
            except OSError:
                pass
        time.sleep(0.02)


if log_dir:
    threading.Thread(target=watch, daemon=True).start()
for raw in proc.stdout:
    line = raw.decode("utf-8", "replace")
    sys.stdout.write(line)
    hit(line)
rc = proc.wait()
timer.cancel()
print("rc %d" % rc if seen else "no-line")
