#!/usr/bin/env python3
"""A fake `gh` for kit:owner-merge (tests/test-kit-owner-merge.sh): the calls the kit and the guard's check reader make, on a JSON
world file.

Usage: owner_merge_gh.py <world.json> <log> <gh args...>

The world:
  "prs": {"<owner/repo>#<n>": {"state", "isDraft", "head", "mergeable", "base", "files": [...], "unknown_reads": <n>,
          "queue": <bool>, "on_merge": {"<owner/repo>#<n>": {field: value}}}}
  "checks": {"<owner/repo>@<sha>": [[name, started_at, status, conclusion, workflow?]]}   (workflow defaults to "ci")
  "workflow_runs": {"<owner/repo>@<sha>/<workflow>": {"status", "conclusion"}}               (else completed, red when a run is)
  "statuses": {"<owner/repo>@<sha>": [[context, state, created_at]]}
GitHub's own answers: check-runs without `filter=all` lists only the newest run per name (GitHub's default `filter=latest`);
`pr view` prints the kit's seven fields joined by the unit separator; `pr merge` is refused unless the PR is OPEN, MERGEABLE and its head is --match-head-commit; then it reads MERGED with a merge
commit, mergeability UNKNOWN, and the PR's on_merge changes apply to the others; a PR with "queue" is only queued (an auto-merge
request, exit 0), as on a base that requires a merge queue. An open PR with unknown_reads > 0 reads UNKNOWN that many more
times. Each merge GitHub accepted is one log line `merge|queued <owner/repo>#<n> match <sha> admin yes|no`; any other call exits 2.
"""
import hashlib
import json
import sys

world_path, log_path, args = sys.argv[1], sys.argv[2], sys.argv[3:]
world = json.load(open(world_path))
GREEN = ("success", "skipped", "neutral")


def opt(name):
    return args[args.index(name) + 1] if name in args else None


def pr_key():
    return "%s#%s" % (opt("-R"), args[2])


def fail(msg, rc=1):
    sys.stderr.write(msg + "\n")
    sys.exit(rc)


def save():
    json.dump(world, open(world_path, "w"))


def commit_runs(repo, sha):
    """[(workflow, check run)] of one commit, ids and suites stable by workflow name."""
    rows = world.get("checks", {}).get("%s@%s" % (repo, sha), [])
    wfs = sorted(set(r[4] if len(r) > 4 else "ci" for r in rows))
    out = []
    for i, r in enumerate(rows):
        wf = r[4] if len(r) > 4 else "ci"
        out.append((wf, {"id": 1000 + i, "name": r[0], "started_at": r[1], "status": r[2], "conclusion": r[3] or None,
                         "app": {"slug": "github-actions"}, "check_suite": {"id": 500 + wfs.index(wf)}}))
    return wfs, out


if args[:2] == ["pr", "view"]:
    p = world["prs"].get(pr_key()) or fail("GraphQL: Could not resolve to a PullRequest")
    mergeable = p["mergeable"]
    if p["state"] == "OPEN" and p.get("unknown_reads", 0) > 0:
        p["unknown_reads"] -= 1
        mergeable = "UNKNOWN"
        save()
    print("\x1f".join([p["state"], str(p["isDraft"]).lower(), p["head"], mergeable, p["base"], p.get("mergeCommit", ""),
                        str(bool(p.get("autoMerge"))).lower()]))
elif args[:1] == ["api"] and args[1].startswith("repos/"):
    path, _, query = args[1].partition("?")
    parts = path.split("/")                              # repos/<owner>/<repo>/...
    repo = "%s/%s" % (parts[1], parts[2])
    if parts[3:4] == ["actions"] and parts[4:5] == ["runs"]:
        sha = dict(q.split("=") for q in query.split("&"))["head_sha"]
        wfs, runs = commit_runs(repo, sha)
        out = []
        for n, wf in enumerate(wfs):
            red = any(r["conclusion"] not in GREEN for w, r in runs if w == wf)
            st = world.get("workflow_runs", {}).get("%s@%s/%s" % (repo, sha, wf), {})
            out.append({"id": 900 + n, "check_suite_id": 500 + n, "name": wf, "workflow_id": 70 + n,
                        "path": ".github/workflows/%s.yml" % wf, "status": st.get("status", "completed"),
                        "conclusion": st.get("conclusion", "failure" if red else "success")})
        print(json.dumps({"total_count": len(out), "workflow_runs": out}))
    elif parts[3:4] == ["commits"] and parts[5:6] == ["check-runs"]:
        _wfs, runs = commit_runs(repo, parts[4])
        runs = [r for _w, r in runs]
        if "filter=all" not in query.split("&"):
            newest = {}
            for r in runs:
                if r["name"] not in newest or r["started_at"] > newest[r["name"]]["started_at"]:
                    newest[r["name"]] = r
            runs = list(newest.values())
        print(json.dumps({"total_count": len(runs), "check_runs": runs}))
    elif parts[3:4] == ["commits"] and parts[5:6] == ["statuses"]:
        rows = world.get("statuses", {}).get("%s@%s" % (repo, parts[4]), [])
        print(json.dumps([{"id": 3000 + i, "context": c, "state": s, "created_at": t} for i, (c, s, t) in enumerate(rows)]))
    else:
        fail("fake gh: unexpected %s" % " ".join(args), 2)
elif args[:2] == ["pr", "diff"] and "--name-only" in args:
    for f in world["prs"][pr_key()]["files"]:
        print(f)
elif args[:2] == ["pr", "merge"]:
    key, match = pr_key(), opt("--match-head-commit")
    p = world["prs"].get(key) or fail("no such pull request")
    if p["state"] != "OPEN":
        fail("Pull request %s is not open" % key)
    if match != p["head"]:
        fail("Head branch was modified. Review and try the merge again.")
    if p["mergeable"] != "MERGEABLE":
        fail("Pull request %s is not mergeable: the merge commit cannot be cleanly created." % key)
    if p.get("queue"):
        p["autoMerge"] = True
        word = "queued"
    else:
        p.update(state="MERGED", mergeable="UNKNOWN", mergeCommit=hashlib.sha1(key.encode()).hexdigest())
        for other, change in p.get("on_merge", {}).items():
            world["prs"][other].update(change)
        word = "merge"
    save()
    with open(log_path, "a") as f:
        f.write("%s %s match %s admin %s\n" % (word, key, match, "yes" if "--admin" in args else "no"))
else:
    fail("fake gh: unexpected %s" % " ".join(args), 2)
