#!/usr/bin/env python3
"""Runner of tests/test-gate-current-state.sh: one gate call per process, the answer on stdout.

    gate_run.py <scripts dir> <profile root> shape <ledger file>
    gate_run.py <scripts dir> <profile root> diff <ledger file or -> <body file or -> [changed path ...]
    gate_run.py <scripts dir> <profile root> ledger

`ledger` judges the whole ledger under the profile root (the index at `current_state.path`, the pages of `current_state.pages`):
the rc (1 when there is any problem), then one `file|line|class` per problem.

`<profile root>` is a directory with an optional `.vibemaestro/sdlc.json`; the profile is what `sdlc_config.load` makes of it
(presets applied), so the suite goes through the real loader. `shape` prints the rc (1 when there is any problem) and then one
`line|class` per problem; `diff` calls `decide(paths, body, profile)` and prints its rc, then the first line of its message.
`-` as the ledger means "read it under the profile root", which is what a gate run in a checkout does.
"""
import sys

scripts, root, mode = sys.argv[1:4]
sys.path.insert(0, scripts)
sys.dont_write_bytecode = True
import current_state as S  # noqa: E402
import sdlc_config as C  # noqa: E402

cfg, probs, _present = C.load(root)
if probs:
    print(97)
    print("config problem: %s" % probs)
    sys.exit(0)
profile = S.profile_from_config(cfg)
if mode == "ledger":
    import os
    try:
        index = open(os.path.join(root, *profile["path"].split("/")), "rb").read()
    except OSError:
        index = None
    found = S.ledger_problems(root, profile, index)
    print(1 if found else 0)
    for rel, n, cls, _why in sorted(found):
        print("%s|%d|%s" % (rel, n, cls))
elif mode == "shape":
    with open(sys.argv[4], "rb") as f:
        found = S.problems_classified(f.read(), profile)
    print(1 if found else 0)
    for n, cls, _why in sorted(found):
        print("%d|%s" % (n, cls))
else:
    ledger = None if sys.argv[4] == "-" else open(sys.argv[4], "rb").read()
    body = "" if sys.argv[5] == "-" else open(sys.argv[5], encoding="utf-8").read()
    rc, msg = S.decide(sys.argv[6:], body, profile, ledger=ledger, root=root)
    print(rc)
    print(msg.split("\n")[0])
