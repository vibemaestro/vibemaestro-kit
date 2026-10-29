"""baton_gate.py <gate> <file> <n>: hold a baton inside its Nth rehearse and change <file> while it waits.

The act under test reads <gate> when it is a fifo (`cat "$DEST.gate"`), so each rehearse blocks there. The first gate is made before
anything else and the line `ready` printed on stdout: the caller starts `baton go` only after reading it, so the first rehearse
always finds a gate. For i = 1..n this waits until a rehearse opens the gate for reading, then releases it (closes its end, the
rehearse goes on). Before releasing rehearse i < n it renames a new fifo onto the gate's path (the waiting rehearse keeps the one it
opened), so the next rehearse finds a gate whatever the timing; at i = n it appends one line to <file> and removes the gate before
releasing, so the rehearses after the Nth find none. Used by tests/test-baton.sh (fam_go_attack) to edit a script, or a file its
plan reads, between the steps of `baton go`. Exits non-zero when no rehearse reaches a gate within 20 seconds.
"""
import errno
import os
import sys
import time

gate, path, nth = sys.argv[1], sys.argv[2], int(sys.argv[3])
os.mkfifo(gate)
print("ready", flush=True)
for i in range(1, nth + 1):
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
        os.unlink(gate)
    else:
        nxt = "%s.next" % gate
        os.mkfifo(nxt)
        os.rename(nxt, gate)
    os.close(fd)
