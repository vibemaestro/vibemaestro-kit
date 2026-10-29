#!/usr/bin/env python3
"""A fake `gh` for kit:branch-delete (tests/test-baton-branch-delete.sh): a JSON world plus a local bare repository, offline.
It answers exactly the calls the kit makes; `--jq` is served for the expressions the kit uses (each by its text: a kit that
changes one fails here loudly), anything else exits 2. Branch SHAs and merged-ness come from the bare repository itself, so
the compare answer is git's.
    Every call must name `--hostname github.com` (the host git talks to); one that does not exits 2.
    FAKE_GH_WORLD  {"repos": {"<owner/name>": {"private", "visibility", "default_branch", "owner" (the login GitHub reports;
                                               default: the owner part of the name),
                                               "git_dir": the bare repository standing in for it,
                                               "protected": [branch, ...],
                                               "rules": {branch: [rule type, ...]} (repository rulesets, e.g. "deletion"),
                                               "pulls": [{"head": "<owner>:<branch>", "base": branch, "state": "open" (default)
                                                          or "closed", and for a closed one "number", "merged", "head_ref",
                                                          "head_repo", "head_sha", "merge_commit_sha"}]}},
                    "faults": {"compare_fails": true    the compare call answers HTTP 502,
                               "pulls_fails": true      the pull request list answers HTTP 502,
                               "rules_fails_silent": true  the rules read exits 1 with no output,
                               "closed_pulls_fail": true   the closed pull request list answers HTTP 502}}
    FAKE_LOG       each call is appended as one line `gh <args>`
"""
import json
import os
import re
import subprocess
import sys
import urllib.parse

a = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a") as f:
    f.write("gh %s\n" % " ".join(a))
W = json.load(open(os.environ["FAKE_GH_WORLD"]))
F = W.get("faults", {})


def die(msg, rc=1):
    sys.stderr.write(msg + "\n")
    sys.exit(rc)


def git(gd, *args):
    r = subprocess.run(["git", "--git-dir", gd] + list(args), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    return r.returncode, r.stdout.strip()


def out(v):
    sys.stdout.write("%s\n" % v)
    sys.exit(0)


if a[:1] != ["api"]:
    die("fake gh: unexpected call: %s" % " ".join(a), 2)
args = a[1:]
method, jq, fields, path, host = "GET", None, {}, None, None
i = 0
while i < len(args):
    x = args[i]
    if x == "-X":
        method = args[i + 1]; i += 2
    elif x == "--paginate":
        i += 1
    elif x == "--hostname":
        host = args[i + 1]; i += 2
    elif x == "--jq":
        jq = args[i + 1]; i += 2
    elif x == "-f":
        k, _, v = args[i + 1].partition("="); fields[k] = v; i += 2
    elif path is None and not x.startswith("-"):
        path = x; i += 1
    else:
        die("fake gh: unexpected argument %s" % x, 2)
if host != "github.com":
    die("fake gh: a call without --hostname github.com: %s" % " ".join(a), 2)
u = urllib.parse.urlsplit(path or "")
q = dict(urllib.parse.parse_qsl(u.query))
m = re.match(r"^repos/([^/]+/[^/]+)(?:/(.*))?$", u.path)
if not m or m.group(1) not in W["repos"]:
    die("gh: Not Found (HTTP 404)")
repo, rest = m.group(1), m.group(2) or ""
R = W["repos"][repo]
gd = R["git_dir"]

if method == "GET" and rest == "" and jq == '"\\(.private) \\(.visibility) \\(.default_branch) \\(.owner.login) \\(.full_name)"':
    owner = R.get("owner", repo.split("/")[0])
    out("%s %s %s %s %s/%s" % ("true" if R["private"] else "false", R["visibility"], R["default_branch"], owner, owner, repo.split("/")[1]))

mr = re.match(r"^rules/branches/(.+)$", rest)
if method == "GET" and mr and jq == '.[] | select(.type == "deletion") | .type':
    if F.get("rules_fails_silent"):
        sys.exit(1)
    sys.stdout.write("".join("deletion\n" for r in R.get("rules", {}).get(mr.group(1), []) if r == "deletion"))
    sys.exit(0)

mb = re.match(r"^branches/(.+)$", rest)
if method == "GET" and mb and jq == ".protected":
    if git(gd, "rev-parse", "--verify", "-q", "refs/heads/" + mb.group(1))[0] != 0:
        die("gh: Branch not found (HTTP 404)")
    out("true" if mb.group(1) in R.get("protected", []) else "false")

if method == "GET" and rest == "pulls" and jq == "length" and q.get("state") == "open":
    if F.get("pulls_fails"):
        die("gh: Server Error (HTTP 502)")
    opened = [p for p in R.get("pulls", []) if p.get("state", "open") == "open"]
    if "head" in q:
        out(sum(1 for p in opened if p["head"] == q["head"]))
    if "base" in q:
        out(sum(1 for p in opened if p["base"] == q["base"]))

# the kit's squash query: GitHub filters by state, head label and base; the kit's --jq select(...) is evaluated here clause by
# clause (an `and` of the forms the kit writes, so a planted break that drops or changes one is answered as jq would)
def clause(c, p):
    c = c.strip()
    if c == "true":
        return True
    if c == ".merged_at != null":
        return bool(p.get("merged"))
    m = re.match(r'^\.(base\.ref|head\.ref|head\.sha) == "([^"]*)"$', c)
    if m:
        return {"base.ref": p["base"], "head.ref": p.get("head_ref"), "head.sha": p.get("head_sha")}[m.group(1)] == m.group(2)
    m = re.match(r'^\(\.head\.repo\.full_name // "" \| ascii_downcase\) == "([^"]*)"$', c)
    if m:
        return (p.get("head_repo") or "").lower() == m.group(1)
    m = re.match(r'^\(?"([^"]*)" (==|!=) "([^"]*)"\)?$', c)
    if m:
        return (m.group(1) == m.group(3)) == (m.group(2) == "==")
    die("fake gh: a squash filter clause it cannot read: %s" % c, 2)
SQJ = re.compile(r'^\.\[\] \| select\((.*)\) \| "\\\(\.number\) \\\(\.merge_commit_sha\)"$')
ms = SQJ.match(jq or "")
if method == "GET" and rest == "pulls" and ms and q.get("state") == "closed" and "head" in q and "base" in q:
    if F.get("closed_pulls_fail"):
        die("gh: Server Error (HTTP 502)")
    clauses = ms.group(1).split(" and ")
    for p in R.get("pulls", []):
        if p.get("state") != "closed" or p["head"] != q["head"] or p["base"] != q["base"]:
            continue
        if all(clause(c, p) for c in clauses):
            sys.stdout.write("%d %s\n" % (p["number"], p["merge_commit_sha"]))
    sys.exit(0)

mn = re.match(r"^pulls/([0-9]+)$", rest)
if method == "GET" and mn and jq == '"\\(.merged_at != null) \\(.merge_commit_sha) \\(.head.sha) \\(.base.ref)"':
    for p in R.get("pulls", []):
        if p.get("number") == int(mn.group(1)):
            out("%s %s %s %s" % ("true" if p.get("merged") else "false", p.get("merge_commit_sha") or "null", p.get("head_sha"), p["base"]))
    die("gh: Not Found (HTTP 404)")

mc = re.match(r"^compare/([0-9a-f]{40})\.\.\.([0-9a-f]{40})$", rest)
if method == "GET" and mc and jq == '"\\(.status) \\(.ahead_by)"':
    if F.get("compare_fails"):
        die("gh: Server Error (HTTP 502)")
    base, head = mc.group(1), mc.group(2)
    rc1, ahead = git(gd, "rev-list", "--count", "%s..%s" % (base, head))
    rc2, behind = git(gd, "rev-list", "--count", "%s..%s" % (head, base))
    if rc1 or rc2:
        die("gh: Not Found (HTTP 404)")
    ahead, behind = int(ahead), int(behind)
    status = "identical" if not ahead and not behind else "behind" if not ahead else "ahead" if not behind else "diverged"
    out("%s %d" % (status, ahead))

if method == "POST" and rest == "git/refs" and jq is None and set(fields) == {"ref", "sha"}:
    ref, sha = fields["ref"], fields["sha"]
    if not ref.startswith("refs/heads/") or not re.match(r"^[0-9a-f]{40}$", sha):
        die("gh: Validation Failed (HTTP 422)")
    if git(gd, "cat-file", "-e", sha + "^{commit}")[0] != 0:
        die("gh: Object does not exist (HTTP 422)")
    if git(gd, "update-ref", ref, sha, "")[0] != 0:                 # create-only: an empty old value
        die("gh: Reference already exists (HTTP 422)")
    out('{"ref": "%s"}' % ref)

die("fake gh: unexpected call: %s" % " ".join(a), 2)
