#!/usr/bin/env python3
"""Drive one function of the guarded merge's backends (gates/backends) and print its result as JSON.

    backends_drive.py <gates dir> <ci|registry> <backend spec> <function> [args...] [--ext-root DIR]

An `external:<path>` spec is read from <ext root>/<path> (the guard reads it from the PR's base commit; here a local directory
stands in for it). rc: 0 the JSON result, 65 the backend is unusable (ConfigError), 2 could not conclude (Infra).
"""
import json
import os
import sys

sys.dont_write_bytecode = True
args = sys.argv[1:]
ext_root = None
if "--ext-root" in args:
    i = args.index("--ext-root")
    ext_root, args = args[i + 1], args[:i] + args[i + 2:]
gates, kind, spec, fn, rest = args[0], args[1], args[2], args[3], args[4:]
sys.path.insert(0, gates)
import gate_common  # noqa: E402
import backends  # noqa: E402


def fetch(rel):
    p = os.path.join(ext_root or ".", rel)
    if not os.path.isfile(p):
        return None
    with open(p, encoding="utf-8") as f:
        return f.read()


try:
    b = backends.load(kind, spec, fetch)
    if fn == "digest":
        out = b.digest
    elif fn == "failed_steps":
        out = b.failed_steps(rest[0], json.loads(rest[1]))
    else:
        out = getattr(b, fn)(*rest)
except gate_common.ConfigError as e:
    sys.stderr.write("config: %s\n" % e)
    sys.exit(65)
except gate_common.Infra as e:
    sys.stderr.write("infra: %s\n" % e)
    sys.exit(2)
sys.stdout.write(json.dumps(out, sort_keys=True) + "\n")
