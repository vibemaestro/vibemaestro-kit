"""A fake `gh` for `kb.py plan status` (tests/test-kb-plan.sh): pull requests, CI, issues and files in a JSON world, offline.

    FAKE_GH_WORLD  {"prs": [{number, state, headRefName, headRefOid, mergeCommit, isDraft, url, title, body}],
                    "checks": {"<pr number>": [statusCheckRollup items]}, "issues": {"<number>": "OPEN" | "CLOSED"},
                    "files": {"<sha>:<path>": "<text>"}}
    FAKE_GH_FAIL   set: every call fails as a network error does (rc 1, `error connecting to api.github.com`)
    FAKE_GH_FAIL_AFTER=N  every call after the first N fails as a rate limit does (rc 1, `HTTP 403: API rate limit exceeded`)
    FAKE_GH_NO_ISSUES     set: `gh issue view` fails for every issue (it cannot resolve the number)
    FAKE_LOG       each call is appended as one line `gh <args>`

    gh pr list --state all|open --limit N --json F       the PRs (all fields of the world, as `gh` returns what it is asked and more)
    gh issue view N --json state                          {"state": …}, or rc 1 when the world has no such issue
    gh api repos/{owner}/{repo}/contents/<path>?ref=<sha> -H …   the text of "<sha>:<path>", or HTTP 404
Anything else exits 2.
"""
import json
import os
import sys

a = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a") as f:
    f.write("gh %s\n" % " ".join(a))
if os.environ.get("FAKE_GH_FAIL"):
    sys.stderr.write("error connecting to api.github.com\n")
    sys.exit(1)
if os.environ.get("FAKE_GH_FAIL_AFTER"):
    with open(os.environ["FAKE_LOG"]) as f:
        n = sum(1 for _ in f)                    # this call is already logged
    if n > int(os.environ["FAKE_GH_FAIL_AFTER"]):
        sys.stderr.write("gh: HTTP 403: API rate limit exceeded\n")
        sys.exit(1)
W = json.load(open(os.environ["FAKE_GH_WORLD"]))

if a[:2] == ["pr", "list"] and "--state" in a:
    state = a[a.index("--state") + 1]
    prs = [p for p in W.get("prs", []) if state == "all" or p["state"] == state.upper()]
    if "statusCheckRollup" in a[a.index("--json") + 1]:
        prs = [{"number": p["number"], "statusCheckRollup": W.get("checks", {}).get(str(p["number"]), [])} for p in prs]
    print(json.dumps(prs))
    sys.exit(0)
if a[:2] == ["issue", "view"] and len(a) >= 3:
    st = None if os.environ.get("FAKE_GH_NO_ISSUES") else W.get("issues", {}).get(a[2])
    if st is None:
        sys.stderr.write("GraphQL: Could not resolve to an issue or pull request with the number of %s.\n" % a[2])
        sys.exit(1)
    print(json.dumps({"state": st}))
    sys.exit(0)
if a[:1] == ["api"] and len(a) >= 2 and a[1].startswith("repos/{owner}/{repo}/contents/") and "?ref=" in a[1]:
    path, sha = a[1][len("repos/{owner}/{repo}/contents/"):].split("?ref=", 1)
    text = W.get("files", {}).get("%s:%s" % (sha, path))
    if text is None:
        sys.stderr.write("gh: Not Found (HTTP 404)\n")
        sys.exit(1)
    sys.stdout.write(text)
    sys.exit(0)
sys.stderr.write("fake gh: unknown call %s\n" % " ".join(a))
sys.exit(2)
