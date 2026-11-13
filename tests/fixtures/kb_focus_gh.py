"""A fake `gh` for `kb.py focus` (tests/test-kb-focus.sh): issues, pull requests and files of several repositories, offline.

    FAKE_GH_WORLD  {"<owner/name>": {"issues": [{number, title, state, labels: [{name}]}],
                                     "prs": [{number, state, headRefName, headRefOid, mergeCommit, isDraft, url, title, labels}],
                                     "files": {"<sha or HEAD>:<path>": "<text>"}}}
                   a call with no `-R` reads the repository FAKE_GH_HERE names (the one at the working directory)
    FAKE_GH_FAIL   set: every call fails as a network error does (rc 1, `error connecting to api.github.com`)
    FAKE_LOG       each call is appended as one line `gh <args>`

    gh issue list [-R o/n] --label L --state all --limit N --json F    the issues carrying the label L
    gh pr list [-R o/n] --state all|open --limit N --json F             the PRs
    gh issue view [-R o/n] N --json state                               {"state": …}
    gh api repos/<o/n>/contents/<path>?ref=<ref> -H …                   the text of "<ref>:<path>", or HTTP 404
    gh api graphql -f query=… -f o=<owner> -f n=<name>                  the entries of each `HEAD:<dir>` the query names, with the
                                                                        text of "HEAD:<dir>/<name>"
A repository the world does not have answers as GitHub does for one the token cannot see. Anything else exits 2.
"""
import json
import os
import re
import sys

a = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a") as f:
    f.write("gh %s\n" % " ".join(a))
if os.environ.get("FAKE_GH_FAIL"):
    sys.stderr.write("error connecting to api.github.com\n")
    sys.exit(1)
W = json.load(open(os.environ["FAKE_GH_WORLD"]))
repo = os.environ.get("FAKE_GH_HERE", "")
if "-R" in a:
    i = a.index("-R")
    repo, a = a[i + 1], a[:i] + a[i + 2:]


def world(name):
    if name not in W:
        sys.stderr.write("GraphQL: Could not resolve to a Repository with the name '%s'. (repository)\n" % name)
        sys.exit(1)
    return W[name]


if a[:2] == ["issue", "list"] and "--label" in a:
    label = a[a.index("--label") + 1]
    print(json.dumps([i for i in world(repo).get("issues", []) if label in [lb["name"] for lb in i.get("labels", [])]]))
    sys.exit(0)
if a[:2] == ["pr", "list"] and "--state" in a:
    state = a[a.index("--state") + 1]
    print(json.dumps([p for p in world(repo).get("prs", []) if state == "all" or p["state"] == state.upper()]))
    sys.exit(0)
if a[:2] == ["issue", "view"] and len(a) >= 3:
    st = next((i["state"] for i in world(repo).get("issues", []) if str(i["number"]) == a[2]), None)
    if st is None:
        sys.stderr.write("GraphQL: Could not resolve to an issue or pull request with the number of %s.\n" % a[2])
        sys.exit(1)
    print(json.dumps({"state": st}))
    sys.exit(0)
m = re.match(r"^repos/([^/]+/[^/]+)/contents/(.+)\?ref=(.+)$", a[1]) if a[:1] == ["api"] and len(a) >= 2 else None
if m:
    name = repo if m.group(1) == "{owner}/{repo}" else m.group(1)
    text = world(name).get("files", {}).get("%s:%s" % (m.group(3), m.group(2)))
    if text is None:
        sys.stderr.write("gh: Not Found (HTTP 404)\n")
        sys.exit(1)
    sys.stdout.write(text)
    sys.exit(0)
if a[:2] == ["api", "graphql"]:
    fields = dict(x.split("=", 1) for x in a[2:] if "=" in x)
    files = world("%s/%s" % (fields["o"], fields["n"])).get("files", {})
    out = {}
    for i, d in enumerate(re.findall(r'HEAD:([^"]+)"', fields["query"])):
        names = sorted(k[len("HEAD:%s/" % d):] for k in files if k.startswith("HEAD:%s/" % d))
        out["d%d" % i] = {"entries": [{"name": n, "object": {"text": files["HEAD:%s/%s" % (d, n)]}} for n in names]} if names else None
    print(json.dumps({"data": {"repository": out}}))
    sys.exit(0)
sys.stderr.write("fake gh: unknown call %s\n" % " ".join(a))
sys.exit(2)
