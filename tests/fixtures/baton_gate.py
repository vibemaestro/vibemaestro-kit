"""baton_gate.py <gate> <file> <n>: hold a baton inside its Nth rehearse and change <file> while it waits.

The act under test reads <gate> when it is a fifo (`cat "$DEST.gate"`), so each rehearse blocks there. For i = 1..n this makes the
fifo, waits until a rehearse opens it for reading, appends one line to <file> at i = n, closes it (the rehearse goes on) and
removes it, so the rehearses after the Nth find no gate. Used by tests/test-baton.sh (fam_go_attack) to edit a script, or a file
its plan reads, between the steps of `baton go`. Exits non-zero when no rehearse reaches a gate within 20 seconds.
"""
import errno
import os
import sys
import time

gate, path, nth = sys.argv[1], sys.argv[2], int(sys.argv[3])
for i in range(1, nth + 1):
    os.mkfifo(gate)
    end = time.time() + 20
    while True:
        try:
            fd = os.open(gate, os.O_WRONLY | os.O_NONBLOCK)
            break
        except OSError as e:
            if e.errno != errno.ENXIO or time.time() > end:
                os.unlink(gate)
                sys.exit("baton_gate: no rehearse reached gate %d" % i)
            time.sleep(0.01)
    if i == nth:
        with open(path, "a") as f:
            f.write("# changed while baton was inside rehearse %d\n" % i)
    os.close(fd)
    os.unlink(gate)
