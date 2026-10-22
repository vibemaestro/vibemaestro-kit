"""A fake `gh` for the kind ci-rerun-failed (tests/test-baton-kinds.sh): workflow runs in a JSON world, offline.

    FAKE_GH_WORLD  {"repos": {"<owner/name>": {"private", "visibility"}},
                    "runs": {"<id>": {"status", "conclusion", "run_attempt", "head_sha", "name"}}, "jump": n}
    FAKE_LOG       each call is appended as one line `gh <args>`

    gh api repos/<r>                         the repository, or HTTP 404
    gh api repos/<r>/actions/runs/<id>       the run, or HTTP 404
    gh run rerun <id> --failed -R <r>        the attempt grows by `jump` (default 1) and the run is queued
    gh run cancel <id> -R <r>                the run ends cancelled
Anything else exits 2.
"""
import json
import os
import sys

a = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a") as f:
    f.write("gh %s\n" % " ".join(a))
path = os.environ["FAKE_GH_WORLD"]
W = json.load(open(path))


def answer(v):
    if not v:
        sys.stderr.write("gh: Not Found (HTTP 404)\n")
        sys.exit(1)
    print(json.dumps(v))
    sys.exit(0)


if a[:1] == ["api"] and len(a) == 2:
    parts = a[1].split("/")
    repo = "/".join(parts[1:3])
    if len(parts) == 3 and parts[0] == "repos":
        answer(W["repos"].get(repo))
    if len(parts) == 6 and parts[0] == "repos" and parts[3:5] == ["actions", "runs"] and repo in W["repos"]:
        answer(W["runs"].get(parts[5]))
    answer(None)
if len(a) == 6 and a[:2] == ["run", "rerun"] and a[3:5] == ["--failed", "-R"] and a[5] in W["repos"] and a[2] in W["runs"]:
    r = W["runs"][a[2]]
    r.update(run_attempt=r["run_attempt"] + W.get("jump", 1), status="queued", conclusion=None)
elif len(a) == 5 and a[:2] == ["run", "cancel"] and a[3] == "-R" and a[4] in W["repos"] and a[2] in W["runs"]:
    W["runs"][a[2]].update(status="completed", conclusion="cancelled")
else:
    sys.stderr.write("fake gh: unexpected %s\n" % a)
    sys.exit(2)
json.dump(W, open(path, "w"))
