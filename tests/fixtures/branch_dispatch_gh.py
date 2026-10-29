#!/usr/bin/env python3
"""A fake `gh` for kit:branch-push and kit:workflow-dispatch (tests/test-baton-branch-push.sh, tests/test-baton-workflow-dispatch.sh):
a JSON world, offline. It answers exactly the calls the two kits make; `--jq` is served for the expressions they use (each by
its text: a kit that changes one fails here loudly), anything else exits 2.

    FAKE_GH_WORLD  {"viewer": login,
                    "repos": {"<owner/name>": {"private", "visibility",
                                               "branches": {name: head sha},
                                               "files": {head sha: {path: {"sha": blob sha, "text": file text}}},
                                               "runs": [{"id", "workflow", "event", "branch", "head_sha", "actor", "status",
                                                         "inputs"}]}},
                    "next_run": n,
                    "faults": {"dispatch_creates": n      runs one dispatch makes (default 1),
                               "dispatch_extra_actor": login  one more run by that login, beside the viewer's,
                               "dispatch_moves_head": sha     the branch head moves to sha right before the run is made,
                               "dispatch_fails": true         `gh workflow run` exits 1 and makes nothing,
                               "dispatch_fails_after": true   it makes its run(s), then exits 1 (an answer lost),
                               "repo_read_fails_in_run": true  the repository read fails (HTTP 502) when BATON_PHASE is run}}
    FAKE_LOG       each call is appended as one line `gh <args>`
"""
import json
import os
import re
import sys
import urllib.parse

a = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a") as f:
    f.write("gh %s\n" % " ".join(a))
path = os.environ["FAKE_GH_WORLD"]
W = json.load(open(path))
F = W.get("faults", {})


def save():
    json.dump(W, open(path, "w"))


def die(msg, rc=1):
    sys.stderr.write(msg + "\n")
    sys.exit(rc)


def take(flag, args):
    """(value of flag, args without it) — the first occurrence only."""
    if flag in args:
        i = args.index(flag)
        return args[i + 1], args[:i] + args[i + 2:]
    return None, args


def repo_of(p):
    parts = urllib.parse.urlsplit(p).path.split("/")          # as an HTTP client sends it: no query, no #fragment
    if len(parts) < 3 or parts[0] != "repos":
        return None, None, []
    name = "/".join(parts[1:3])
    return name, W["repos"].get(name), parts[3:]


def jq(expr, v):
    if expr == '"\\(.private) \\(.visibility)"':
        return "%s %s" % (str(v["private"]).lower(), v["visibility"])
    if expr in (".object.sha", ".sha"):
        return v["object"]["sha"] if expr == ".object.sha" else v["sha"]
    if expr == ".data.viewer.login":
        return v["data"]["viewer"]["login"]
    m = re.fullmatch(r'\.workflow_runs\[\] \| select\(\.triggering_actor\.login == "([^"]*)"\) \| "\\\(\.id\) \\\(\.status\) \\\(\.head_sha\)"', expr)
    if m:
        return "\n".join("%d %s %s" % (r["id"], r["status"], r["head_sha"]) for r in v["workflow_runs"]
                         if r["triggering_actor"]["login"] == m.group(1))
    die("fake gh: --jq %r is not one the kits use" % expr, 2)


def out(v, expr):
    if expr is None:
        print(json.dumps(v))
    else:
        s = jq(expr, v)
        if s:
            print(s)
    save()
    sys.exit(0)


if a[:1] == ["api"]:
    rest = a[1:]
    expr, rest = take("--jq", rest)
    accept, rest = take("-H", rest)
    include = "--include" in rest
    rest = [x for x in rest if x != "--include"]
    if rest[:1] == ["graphql"]:
        if rest[1:] != ["-f", "query=query{viewer{login}}"]:
            die("fake gh: graphql serves only the viewer query", 2)
        out({"data": {"viewer": {"login": W["viewer"]}}}, expr)
    if len(rest) != 1:
        die("fake gh: unexpected api call %s" % a, 2)
    name, R, sub = repo_of(rest[0])
    qs = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(rest[0]).query))

    def found(v):
        if include:
            print("HTTP/2.0 200 OK\n")
        out(v, expr)

    def missing():
        if include:
            print("HTTP/2.0 404 Not Found\n")
        die("gh: Not Found (HTTP 404)")

    if R is None:
        missing()
    if not sub:
        if F.get("repo_read_fails_in_run") and os.environ.get("BATON_PHASE") == "run":
            die("gh: HTTP 502: injected failure of the repository read in the run phase")
        found({"full_name": name, "private": R["private"], "visibility": R["visibility"]})
    if sub[:3] == ["git", "ref", "heads"] and len(sub) > 3:
        b = "/".join(sub[3:])
        found({"ref": "refs/heads/" + b, "object": {"sha": R["branches"][b]}}) if b in R.get("branches", {}) else missing()
    if sub[:1] == ["contents"]:
        fp = "/".join(sub[1:])
        f = R.get("files", {}).get(qs.get("ref", ""), {}).get(fp)
        if f is None:
            missing()
        if accept == "Accept: application/vnd.github.raw":
            sys.stdout.write(f["text"])
            save()
            sys.exit(0)
        found({"path": fp, "sha": f["sha"]})
    if sub[:2] == ["actions", "workflows"] and len(sub) == 4 and sub[3] == "runs":
        wf = sub[2]
        runs = [r for r in R.get("runs", []) if r["workflow"] == wf and r["event"] == qs.get("event")
                and r["branch"] == qs.get("branch") and ("head_sha" not in qs or r["head_sha"] == qs["head_sha"])]
        found({"total_count": len(runs), "workflow_runs": [
            {"id": r["id"], "status": r["status"], "head_sha": r["head_sha"], "triggering_actor": {"login": r["actor"]}}
            for r in sorted(runs, key=lambda r: -r["id"])]})
    missing()

if a[:2] == ["workflow", "run"] and len(a) >= 7:
    wf, rest = a[2], a[3:]
    name, rest = take("--repo", rest)
    ref, rest = take("--ref", rest)
    inputs = []
    while rest[:1] == ["-f"]:
        inputs.append(rest[1])
        rest = rest[2:]
    R = W["repos"].get(name)
    if rest or R is None or ref not in R.get("branches", {}):
        die("fake gh: unexpected workflow run %s" % a, 2)
    if F.get("dispatch_fails"):
        die("gh: HTTP 422: injected refusal of the dispatch")
    if F.get("dispatch_moves_head"):
        R["branches"][ref] = F["dispatch_moves_head"]
    actors = [W["viewer"]] * F.get("dispatch_creates", 1) + ([F["dispatch_extra_actor"]] if F.get("dispatch_extra_actor") else [])
    for who in actors:
        R.setdefault("runs", []).append({"id": W["next_run"], "workflow": wf, "event": "workflow_dispatch", "branch": ref,
                                         "head_sha": R["branches"][ref], "actor": who, "status": "queued", "inputs": inputs})
        W["next_run"] += 1
    save()
    if F.get("dispatch_fails_after"):
        die("gh: HTTP 502: the dispatch landed, the answer was lost")
    sys.exit(0)

if len(a) == 5 and a[:2] == ["run", "cancel"] and a[3] == "-R":
    R = W["repos"].get(a[4])
    hit = [r for r in (R or {}).get("runs", []) if str(r["id"]) == a[2]]
    if not hit:
        die("gh: run %s not found" % a[2])
    hit[0]["status"] = "completed"
    hit[0]["conclusion"] = "cancelled"
    save()
    sys.exit(0)

die("fake gh: unexpected %s" % a, 2)
