#!/usr/bin/env python3
"""A fake `gh` for the guarded merge and its backends: serves `pr view`, `pr merge` and GET `api` calls from a JSON fixture, and logs
every argv as one JSON line. It never touches the network.

    FAKE_GH_LOG    file each call's argv is appended to (one JSON array per line)
    FAKE_GH_FX     the fixture (JSON):
        "repo"     owner/name every `pr` call must name with --repo, and every `api` path under repos/ must start with
        "pr"       the object `pr view` prints (only the --json fields asked for); "mergeable_seq": a list served one value per
                   call, the last one repeated; "merge_head": the head GitHub sees at merge time (default: headRefOid);
                   "after_merge_head", "after_merge_base": the head and base `pr view` reports once merged (default: as before);
                   "merge_mode": "queue" (`pr merge` exits 0 and nothing merges, as with a merge queue) or "auto" (the same,
                   and `pr view` then shows an autoMergeRequest); "merge_5xx": one fault per `pr merge` call, the first first, a 5xx
                   in the words of gh's GraphQL client (`non-200 OK status code: 502 …`): "landed" merges and then answers 502 (the
                   answer was lost), "lost" answers 502 and merges nothing, "dropped" merges
                   and then loses the connection (gh: `http2: client connection lost`), "raced" has another hand merge the PR just before the
                   call; "queue_head": the head a queued PR reads (another hand moved it, its auto-merge dropped); on a PR merged already `pr merge` does as gh does: `! Pull request … was already merged`, exit 0, no pin
        "fail_after_merge"  like "fail", for the calls made once the PR merged
        "api"      {path: value}; the path is the call's, without a leading `/`, query included. A string is served raw; an object
                   {"__pages__": [p1, p2, ...]} is served page by page; a list is served one element per page; any other value is
                   one page; {"__seq__": [v1, v2, ...]} serves v1 to the first call of that path, v2 to the second, the last one
                   repeated; a value {"__die__": "<stderr>"} makes that call exit 1 with the message (a 5xx, a dropped connection),
                   so {"__seq__": [{"__die__": "gh: Server Error (HTTP 500)"}, <page>]} fails once and then answers. Without --paginate only the first page is printed (so a call that forgets --paginate loses data, as
                   with the real gh); with --paginate the pages are printed one after the other, the way the real gh prints them.
                   A path that is not in the fixture is a 404. {"__b64__": "<base64>"} is served as those bytes (an artifact zip).
        "git"      {owner/name: a git directory}: `api` paths under those repositories are served too; one not in "api" that reads
                   `repos/<r>/contents/<path>[?ref=<rev>]` is `git show <rev>:<path>` there (no ref: the branch main), else a 404;
                   as GitHub does, a `.` or `..` part of <path> is resolved and an empty part (`//`) is a 404
        "git_refs" {rev: a ref of those git directories}: a rev read as that ref (a PR's head sha served as a branch)
        "fail"     {path or "pr view" or "pr merge": message}: that call exits 1 with an HTTP 500 message
    FAKE_GH_STATE  a file `pr merge` writes when it merges; `pr view` then prints state MERGED and the merge commit
    FAKE_GH_FX2, FAKE_GH_SWAP_AT   the world moves: once the base branch ref (`git/ref/heads/…`) was read SWAP_AT times, every
                   later call is served from FX2 instead of FX
"""
import base64
import hashlib
import json
import os
import posixpath
import re
import subprocess
import sys
import time
import urllib.parse

A = sys.argv[1:]
with open(os.environ["FAKE_GH_LOG"], "a") as f:
    f.write(json.dumps(A) + "\n")
SWAP = os.environ["FAKE_GH_LOG"] + ".swap"
reads = int(open(SWAP).read()) if os.path.exists(SWAP) else 0
FX2 = os.environ.get("FAKE_GH_FX2")
FX = json.load(open(FX2 if FX2 and reads >= int(os.environ.get("FAKE_GH_SWAP_AT", "0")) else os.environ["FAKE_GH_FX"]))
STATE = os.environ.get("FAKE_GH_STATE", "")
FAIL = dict(FX.get("fail", {}))
if STATE and os.path.exists(STATE):
    FAIL.update(FX.get("fail_after_merge", {}))


def die(msg, rc=1):
    sys.stderr.write(msg + "\n")
    sys.exit(rc)


def opt(name):
    return A[A.index(name) + 1] if name in A and A.index(name) + 1 < len(A) else None


def merged():
    return bool(STATE) and os.path.exists(STATE)


def pr_view():
    if "pr view" in FAIL:
        die("HTTP 500: %s" % FAIL["pr view"])
    if opt("--repo") != FX["repo"]:
        die("fake gh: pr view without --repo %s" % FX["repo"])
    pr = dict(FX["pr"])
    seq = pr.pop("mergeable_seq", None)
    pr.pop("merge_head", None)
    pr.pop("after_merge_head", None)
    pr.pop("after_merge_base", None)
    pr.pop("merge_hang_s", None)
    pr.pop("merge_5xx", None)
    mode = pr.pop("merge_mode", None)
    pr["autoMergeRequest"] = {"mergeMethod": "SQUASH"} if mode == "auto" and STATE and os.path.exists(STATE + ".auto") else None
    qhead = pr.pop("queue_head", None)
    if qhead and STATE and os.path.exists(STATE + ".auto"):
        pr["headRefOid"], pr["autoMergeRequest"] = qhead, None
    if seq:
        cnt = os.environ["FAKE_GH_LOG"] + ".mergeable"
        n = int(open(cnt).read()) if os.path.exists(cnt) else 0
        open(cnt, "w").write(str(n + 1))
        pr["mergeable"] = seq[min(n, len(seq) - 1)]
    if merged():
        st = json.load(open(STATE))
        pr["state"], pr["mergeCommit"] = "MERGED", {"oid": st["merge_sha"]}
        pr["headRefOid"] = FX["pr"].get("after_merge_head") or pr["headRefOid"]
        pr["baseRefName"] = FX["pr"].get("after_merge_base") or pr.get("baseRefName")
    fields = (opt("--json") or "").split(",")
    sys.stdout.write(json.dumps({k: pr.get(k) for k in fields if k}) + "\n")


def pr_merge():
    if "pr merge" in FAIL:
        die("HTTP 500: %s" % FAIL["pr merge"])
    if opt("--repo") != FX["repo"]:
        die("fake gh: pr merge without --repo %s" % FX["repo"])
    faults, fault = FX["pr"].get("merge_5xx") or [], None
    if faults:
        cnt = os.environ["FAKE_GH_LOG"] + ".merge5xx"
        n = int(open(cnt).read()) if os.path.exists(cnt) else 0
        open(cnt, "w").write(str(n + 1))
        fault = faults[n] if n < len(faults) else None
    if fault == "lost":
        die("non-200 OK status code: 502 Bad Gateway body: \"<html><body><h1>502 Server Error</h1></body></html>\"")
    if fault == "raced" and STATE:
        json.dump({"merge_sha": "e" * 40, "args": ["raced"]}, open(STATE, "w"))
    if merged():
        sys.stderr.write("! Pull request %s/#%s was already merged\n" % (FX["repo"], A[2]))
        return
    want = opt("--match-head-commit")
    head = FX["pr"].get("merge_head") or FX["pr"]["headRefOid"]
    if want is not None and want != head:
        die("GraphQL: Head branch was modified. Review and try the merge again. (mergePullRequest)")
    if FX["pr"].get("merge_hang_s"):
        time.sleep(FX["pr"]["merge_hang_s"])
    if FX["pr"].get("merge_mode") in ("queue", "auto"):
        if STATE:
            open(STATE + ".auto", "w").write("queued")
        sys.stdout.write("Pull request #%s will be added to the merge queue when ready\n" % A[2])
        return
    if STATE:
        json.dump({"merge_sha": "f" * 40, "args": A}, open(STATE, "w"))
    if fault == "dropped":
        die("Post \"https://api.github.com/graphql\": http2: client connection lost")
    if fault == "landed":
        die("non-200 OK status code: 502 Bad Gateway body: \"<html><body><h1>502 Server Error</h1></body></html>\"")
    sys.stdout.write("Squashed and merged pull request #%s\n" % A[2])


def api():
    rest = [a for a in A[1:]]
    method = "GET"
    path, raw, paginate, i = None, False, False, 0
    while i < len(rest):
        a = rest[i]
        if a in ("-X", "--method"):
            method, i = rest[i + 1], i + 2
        elif a in ("-H", "--header"):
            raw = raw or rest[i + 1].lower() == "accept: application/vnd.github.raw"
            i += 2
        elif a == "--paginate":
            paginate, i = True, i + 1
        elif a.startswith("-"):
            die("fake gh: api option %s is not served" % a)
        else:
            path, i = a, i + 1
    if method != "GET":
        die("fake gh: api %s is a write; the guard never writes through the api" % method)
    path = (path or "").lstrip("/")
    if "/git/ref/heads/" in path:
        open(SWAP, "w").write(str(reads + 1))
    repos = [FX["repo"]] + list(FX.get("git", {}))
    if path.startswith("repos/") and not any(path == "repos/" + r or path.startswith("repos/%s/" % r) for r in repos):
        die("fake gh: api path outside repos/%s/: %s" % ("/, repos/".join(repos), path))
    if path in FAIL:
        die("gh: Server Error (HTTP 500): %s" % FAIL[path])
    api_map = FX.get("api", {})
    if path not in api_map:
        m = re.fullmatch(r"repos/([^/]+/[^/]+)/contents/([^?]+)(?:\?ref=(.+))?", path)
        git = FX.get("git", {}).get(m.group(1)) if m else None
        rev = FX.get("git_refs", {}).get(m.group(3), m.group(3)) if m and m.group(3) else "main"
        rel = urllib.parse.unquote(m.group(2)) if m else ""
        rel = rel if "//" in rel else posixpath.normpath(rel)
        r = subprocess.run(["git", "-C", git, "show", "%s:%s" % (rev, rel)], stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL) if git else None
        if r is None or r.returncode != 0:
            die("gh: Not Found (HTTP 404)")
        if not raw:
            die("fake gh: a raw file asked without the raw Accept header: %s" % path)
        sys.stdout.buffer.write(r.stdout)
        return
    v = api_map[path]
    if isinstance(v, dict) and "__seq__" in v:
        cnt = os.environ["FAKE_GH_LOG"] + ".seq-" + hashlib.sha256(path.encode()).hexdigest()[:16]
        n = int(open(cnt).read()) if os.path.exists(cnt) else 0
        open(cnt, "w").write(str(n + 1))
        v = v["__seq__"][min(n, len(v["__seq__"]) - 1)]
    if isinstance(v, dict) and "__die__" in v:
        die(v["__die__"])
    if isinstance(v, dict) and "__b64__" in v:
        sys.stdout.flush()
        sys.stdout.buffer.write(base64.b64decode(v["__b64__"]))
        return
    if isinstance(v, str):
        if not raw:
            die("fake gh: a raw file asked without the raw Accept header: %s" % path)
        sys.stdout.write(v)
        return
    pages = v["__pages__"] if isinstance(v, dict) and "__pages__" in v else ([[x] for x in v] or [[]]) if isinstance(v, list) else [v]
    for p in (pages if paginate else pages[:1]):
        sys.stdout.write(json.dumps(p))
    sys.stdout.write("\n")


if A[:2] == ["pr", "view"]:
    pr_view()
elif A[:2] == ["pr", "merge"]:
    pr_merge()
elif A[:1] == ["api"]:
    api()
else:
    die("fake gh: %s is not served" % " ".join(A[:2]))
