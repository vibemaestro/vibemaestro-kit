#!/usr/bin/env python3
"""Fixtures of tests/test-baton-pack.sh: a `baton pack` stopped at one step, a racer on the next keep record, and a holder of a
name's lock. Each runs the plugin copy's own baton.py in this process (so a planted break in that copy shows), from the current
directory, with the caller's environment (XDG_STATE_HOME, XDG_DATA_HOME).

  baton_pack.py cut <plugin> after-target|after-retire|in-lock <pack args...>   pack, stopped: os._exit(137) after that step
                                                                                 (in-lock: SIGKILL while it holds the lock)
  baton_pack.py race <plugin> <pack args...>       pack; a racer writes the next <seq>.json between the count and the link
  baton_pack.py wait <plugin> <seconds> <pack args...>  pack, waiting at most that long for a name's lock
  baton_pack.py slow <plugin> <fn> <seconds> <baton args...>   baton, sleeping that long after fn returns (a wide race window)
  baton_pack.py term <plugin> <fn> <pack args...>  pack; SIGTERM to itself right after fn returns
  baton_pack.py nospace <plugin> <pack args...>    pack; writing the target's bytes fails with ENOSPC
  baton_pack.py hold <lock file> <seconds>         hold the lock (flock) that long; prints `held` once it is held
Prints the rc of the pack (cut never returns one)."""
import errno
import fcntl
import json
import os
import signal
import sys
import time

sys.dont_write_bytecode = True


def load(plugin):
    sys.path.insert(0, os.path.join(plugin, "scripts"))
    import baton                                                    # noqa: E402  the copy's own baton.py
    return baton


def main(argv):
    if argv[0] == "hold":
        fd = os.open(argv[1], os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        print("held", flush=True)
        time.sleep(float(argv[2]))
        return 0
    b = load(argv[1])
    if argv[0] == "cut":
        step, args = argv[2], argv[3:]
        if step == "in-lock":
            def killed(*_a, **_k):
                os.kill(os.getpid(), signal.SIGKILL)
            b.pack_put_file = killed
        else:
            name = {"after-target": "pack_target", "after-retire": "retire_source"}[step]
            real = getattr(b, name)

            def cut(*a, **k):
                real(*a, **k)
                os._exit(137)
            setattr(b, name, cut)
        return b.main(["pack"] + args)
    if argv[0] in ("slow", "term"):
        fn, real = argv[2], getattr(b, argv[2])

        def after(*a, **k):
            r = real(*a, **k)
            if argv[0] == "slow":
                time.sleep(float(argv[3]))
            else:
                os.kill(os.getpid(), signal.SIGTERM)
            return r
        setattr(b, fn, after)
        return b.main(argv[4:] if argv[0] == "slow" else ["pack"] + argv[3:])
    if argv[0] == "nospace":
        def full(_data):
            raise OSError(errno.ENOSPC, "No space left on device")
        b.memoryview = full                                         # pack_put_file's write loop starts with memoryview(data)
        return b.main(["pack"] + argv[2:])
    if argv[0] == "wait":
        b.PACK_LOCK_WAIT = float(argv[2])
        return b.main(["pack"] + argv[3:])
    if argv[0] == "race":
        real, raced = os.link, []

        def link(src, dst, *a, **k):
            if not raced and dst.endswith(".json"):
                raced.append(dst)
                with open(dst, "w", encoding="utf-8") as f:
                    json.dump({"sha256": "f" * 64, "name": "racer", "kept_by": "local", "kept_at": "2026-10-24T08:00:00Z"}, f)
            return real(src, dst, *a, **k)
        os.link = link
        rc = b.main(["pack"] + argv[2:])
        print("raced %s" % (os.path.basename(raced[0]) if raced else "none"))
        return rc
    return 64


if __name__ == "__main__":
    rc = main(sys.argv[1:])
    print("rc %s" % rc)
    sys.exit(0)
