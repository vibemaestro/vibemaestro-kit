#!/usr/bin/env python3
"""A fake `gh` for the gate suites: serves the few calls the gates make from a JSON fixture and logs its argv.

    FAKE_GH_LOG  file the argv of every call is appended to
    FAKE_GH_FX   JSON fixture: {"pr view": {...}, "<path after repos/<owner>/<repo>/>": <list or object or string>,
                                "__fail__": true, "__require_paginate__": true,
                                "__require_repo__": "<owner/name that every call must name>"}

`gh pr view` prints fx["pr view"]. `gh api repos/<x>/<y>/<key>`: a list is served ONE ELEMENT PER PAGE, so a call without
--paginate sees only page 1 (a value planted on page 2 is lost); with --paginate --slurp the output is the array of pages, with
--paginate alone the arrays are printed one after the other like the real gh; with --jq the elements are printed one per line.
A string is served raw (the `contents` endpoint with Accept: raw); a key that is not in the fixture is a 404 (rc 1).
"""
import json
import os
import sys


def emit(text):
    """UTF-8 bytes, whatever the locale: the real gh prints the PR text as it is, not ASCII-escaped."""
    sys.stdout.buffer.write(text.encode("utf-8"))
    sys.stdout.buffer.flush()


a = sys.argv[1:]
with open(os.environ["FAKE_GH_LOG"], "a") as f:
    f.write(" ".join(a) + "\n")
fx = json.load(open(os.environ["FAKE_GH_FX"]))
if fx.get("__require_repo__") and fx["__require_repo__"] not in " ".join(a):
    sys.stderr.write("fake gh: the call does not name the repo %s\n" % fx["__require_repo__"])
    sys.exit(1)
if fx.get("__fail__"):
    sys.stderr.write("gh: network error\n")
    sys.exit(1)
if a[:2] == ["pr", "view"]:
    for flag in ("-q", "--jq"):       # `-q .body` prints that field raw, the way gh does
        if flag in a:
            v = fx["pr view"][a[a.index(flag) + 1].lstrip(".")]
            emit((v if isinstance(v, str) else json.dumps(v, ensure_ascii=False)) + "\n")
            sys.exit(0)
    emit(json.dumps(fx["pr view"], ensure_ascii=False) + "\n")
    sys.exit(0)
if a[:1] != ["api"]:
    sys.stderr.write("fake gh: not simulated: %s\n" % " ".join(a))
    sys.exit(1)
ep = next(x for x in a[1:] if x.startswith("repos/"))
key = ep.split("/", 3)[3]
if key not in fx:
    sys.stderr.write("gh: Not Found (HTTP 404)\n")
    sys.exit(1)
data = fx[key]
if isinstance(data, str):
    emit(data)
    sys.exit(0)
if not isinstance(data, list):
    emit(json.dumps(data, ensure_ascii=False) + "\n")
    sys.exit(0)
if fx.get("__require_paginate__") and "--paginate" not in a:
    sys.stderr.write("fake gh: the call lacks --paginate\n")
    sys.exit(1)
pages = [data[i:i + 1] for i in range(len(data))] or [[]]
if "--paginate" not in a:
    pages = pages[:1]
if "--jq" in a:
    for pg in pages:
        for x in pg:
            emit(str(x) + "\n")
elif "--slurp" in a:
    emit(json.dumps(pages, ensure_ascii=False) + "\n")
else:
    emit("".join(json.dumps(pg, ensure_ascii=False) for pg in pages) + "\n")
