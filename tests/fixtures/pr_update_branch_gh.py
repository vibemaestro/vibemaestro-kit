#!/usr/bin/env python3
"""A fake `gh` for kit:pr-update-branch (tests/test-kit-pr-update-branch.sh): the four calls the kit makes, on a JSON world file.

Usage: pr_update_branch_gh.py <world.json> <log> <gh args...>

The world: {"repo": "o/r", "pr": {GitHub's pull request JSON: number, state, draft, head{sha, repo{full_name}}, base{ref, repo{full_name}},
mergeable_state}, "ahead": <commits the base is ahead of the head>, "new_head": "<sha>", "parents": {"<sha>": ["<sha>", ...]},
"conflict": bool, "spam": bool, "put_fail": bool, "race_head": "<sha>", "lag": <reads that still answer the old head after the update>}.
  api repos/<r>/pulls/<n> --jq <expr>            the PR JSON through the real `jq -r <expr>`, so the kit's own expression is the one that
                                                 runs; logs `read pr <r> <n>`; the head is new_head once updated (after "lag" reads)
  api repos/<r>/compare/<head>...<base> --jq .ahead_by     prints "ahead"; logs `read compare <r> <head>...<base>`
  api repos/<r>/commits/<sha> --jq .parents[].sha          prints the parents of <sha>, one per line; logs `read commit <r> <sha>`
  api -X PUT repos/<r>/pulls/<n>/update-branch -f expected_head_sha=<sha>      (GitHub documents no other body parameter)
      logs `put <r> <n> expected_head_sha=<sha>` first; 422 when <sha> is not the head ("race_head" first becomes
      the head: another hand pushed between the kit's read and its call), 422 on "conflict" and on "spam" (GitHub's "endpoint has been spammed"), 500 on "put_fail"; else the head
      becomes new_head (after "lag" reads) and GitHub's 202 answer is printed.
A repository or pull request that is not the world's answers 404. Any other call exits 2.
"""
import copy
import json
import subprocess
import sys

world_path, log_path, args = sys.argv[1], sys.argv[2], sys.argv[3:]
world = json.load(open(world_path))


def save():
    json.dump(world, open(world_path, "w"))


def log(line):
    with open(log_path, "a") as f:
        f.write(line + "\n")


def fail(msg, rc=1):
    sys.stderr.write(msg + "\n")
    sys.exit(rc)


def pr_json():
    pr = copy.deepcopy(world["pr"])
    if world.get("updated"):
        if world.get("lag", 0) > 0:
            world["lag"] -= 1
            save()
        else:
            pr["head"]["sha"] = world["new_head"]
    return pr


def check_repo(repo):
    if repo != world["repo"]:
        fail("gh: Not Found (HTTP 404)")


if len(args) == 4 and args[0] == "api" and args[2] == "--jq" and args[1].startswith("repos/"):
    path, expr = args[1], args[3]
    parts = path.split("/")
    check_repo("/".join(parts[1:3]))
    if parts[3] == "pulls" and len(parts) == 5:
        if int(parts[4]) != world["pr"]["number"]:
            fail("gh: Not Found (HTTP 404)")
        log("read pr %s %s" % (world["repo"], parts[4]))
        doc = pr_json()
    elif parts[3] == "compare" and expr == ".ahead_by":
        log("read compare %s %s" % (world["repo"], "/".join(parts[4:])))
        doc = {"ahead_by": world["ahead"]}
    elif parts[3] == "commits" and len(parts) == 5:
        log("read commit %s %s" % (world["repo"], parts[4]))
        doc = {"parents": [{"sha": s} for s in world.get("parents", {}).get(parts[4], [])]}
    else:
        fail("pr_update_branch_gh.py: unexpected call: %r" % (args,), 2)
    r = subprocess.run(["jq", "-r", expr], input=json.dumps(doc), capture_output=True, text=True)
    sys.stdout.write(r.stdout)
    sys.stderr.write(r.stderr)
    sys.exit(r.returncode)
elif len(args) == 6 and args[:3] == ["api", "-X", "PUT"] and args[4] == "-f" and args[3].endswith("/update-branch"):
    parts = args[3].split("/")
    check_repo("/".join(parts[1:3]))
    if parts[3] != "pulls" or int(parts[4]) != world["pr"]["number"]:
        fail("gh: Not Found (HTTP 404)")
    log("put %s %s %s" % (world["repo"], parts[4], args[5]))
    if "race_head" in world:
        world["pr"]["head"]["sha"] = world["race_head"]
        save()
    if args[5] != "expected_head_sha=" + world["pr"]["head"]["sha"] or world.get("updated"):
        fail("gh: Validation Failed (HTTP 422): expected head sha didn't match current head ref.")
    if world.get("conflict"):
        fail("gh: Validation Failed (HTTP 422): merge conflict between base and head")
    if world.get("spam"):
        fail("gh: Validation failed, or the endpoint has been spammed. (HTTP 422)")
    if world.get("put_fail"):
        fail("gh: Server Error (HTTP 500)")
    world["updated"] = True
    save()
    print('{"message": "Updating pull request branch.", "url": "https://api.github.com/repos/%s/pulls/%s"}' % (world["repo"], parts[4]))
else:
    fail("pr_update_branch_gh.py: unexpected call: %r" % (args,), 2)
