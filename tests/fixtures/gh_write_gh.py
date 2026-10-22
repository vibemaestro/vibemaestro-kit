#!/usr/bin/env python3
"""A fake `gh` for kit:gh-write (gates/gh_write.py): an in-memory GitHub REST API behind `gh api`, kept in a JSON state file,
that logs every call. It never touches the network.

    FAKE_GH_LOG    file each call is appended to, one JSON object per line: {"argv": [...], "method": M, "path": P, "payload": {...}}
    FAKE_GH_STATE  the world (JSON), read and written back on every call:
        "viewer"   the login the GraphQL query `query{viewer{login}}` answers; `GET user` is HTTP 403, as for a GitHub App
                   installation token; "viewer_id" the databaseId `query{viewer{login databaseId}}` answers (default 4242);
                   the two pull-request mutations (ready, back to draft) by node id `PR_<n>` are writes; any other GraphQL exits 1
        "repos"    {owner/name: {"private": bool, "visibility": str, "labels": [names],
                                  "issues": {"<n>": {"title", "body", "state", "state_reason", "labels": [names], "user", "pr": bool,
                                                     "head": sha (a PR's head, default "ab" * 20), "merged": bool,
                                                     "head_ref", "base_ref" (default "feature", "main"), "draft": bool,
                                                     "closed_by": login (set by a close through this fake, cleared by a reopen)}},
                                  "comments": {"<id>": {"issue": n, "body", "user"}},
                                  "branches": {name: commit sha}, "commits": {sha: {"tree", "parents", "message", "author",
                                  "committer"}}, "trees": {sha: {path: base64 content (mode 100644) | {"content", "mode"}}},
                                  "blobs": {git blob id: base64 content}}}; `GET git/trees/<id>` lists one directory of a
                                  tree; a subdirectory's id is the hash of its contents, so equal subtrees share an id
                                  (as in git), and it is registered under "trees" when first listed. A tree POST entry with
                                  sha null deletes its path and a path under a file is HTTP 422, as on GitHub
        "next_issue", "next_comment"   the numbers the next create gets
        "faults"   {"lag": true | n            list endpoints omit what this fake created (a list that lags behind a create);
                                               a number n: only the first n list reads after a create lag, then it catches up,
                    "fail_write": k            the k-th write call (POST or PATCH, counted from 1) is refused (HTTP 422), nothing changes,
                    "land_then_fail": k        the k-th write lands, then gh exits 1 with HTTP 502 (the outcome looks unknown),
                    "append_after_write": [k, file]   right after the k-th write, a space is appended to that file (the spec edited),
                    "store": "add-nl" | "strip-nl" | "flip"   every body a write stores is altered so,
                    "swap": [[repo, "issues"|"comments", key, {field: value}] | [repo, "repo", {field: value}]], the
                                               updates that land once, when one of these triggers first fires:
                    "swap_at_read": [path, m]  just before the m-th GET of that path (the world moves between two reads),
                    "swap_after_write": k      right after the k-th write landed (someone edits after the run),
                    "bad_blob": true           a blob POST answers an id that is not git's id of the bytes,
                    "drop_base_tree": true     a tree POST ignores base_tree (the new tree holds only its entries)}
Repository names match whatever the case; the answers carry the world's own case. A path the world does not hold is HTTP 404. Any method other than GET, POST and PATCH exits 1 (and is logged, so a test sees it).
"""
import json
import os
import sys
import urllib.parse

A = sys.argv[1:]
STATE = os.environ["FAKE_GH_STATE"]
W = json.load(open(STATE))
F = W.setdefault("faults", {})
W["calls"] = W.get("calls", 0) + 1


def out(v):
    sys.stdout.write(json.dumps(v) + "\n")


def die(msg, rc=1):
    json.dump(W, open(STATE, "w"))
    sys.stderr.write(msg + "\n")
    sys.exit(rc)


if not A or A[0] != "api":
    die("fake gh: only `gh api` is served")
method, path, payload, paginate, k = "GET", None, None, False, 1
while k < len(A):
    a = A[k]
    if a == "-X":
        method = A[k + 1]
        k += 2
    elif a == "--input":
        payload = json.load(open(A[k + 1], encoding="utf-8"))
        k += 2
    elif a == "--paginate":
        paginate = True
        k += 1
    elif path is None and not a.startswith("-"):
        path = a
        k += 1
    else:
        die("fake gh: unexpected argument %r" % a)
with open(os.environ["FAKE_GH_LOG"], "a", encoding="utf-8") as f:
    f.write(json.dumps({"argv": A, "method": method, "path": path, "payload": payload}, ensure_ascii=False) + "\n")



def swap():
    if W.get("swapped"):
        return
    W["swapped"] = True
    for s in F.get("swap", []):
        if s[1] == "repo":
            W["repos"][s[0]].update(s[2])
        else:
            W["repos"][s[0]][s[1]].setdefault(str(s[2]), {}).update(s[3])


if method == "POST" and path == "graphql" and payload in ({"query": "query{viewer{login}}"},
                                                         {"query": "query{viewer{login databaseId}}"}):  # reads, not writes
    v = {"login": W["viewer"]}
    if "databaseId" in payload["query"]:
        v["databaseId"] = W.get("viewer_id", 4242)
    out({"data": {"viewer": v}})
    json.dump(W, open(STATE, "w"))
    sys.exit(0)
if method == "POST" and path == "graphql" and not (isinstance(payload, dict) and isinstance(payload.get("query"), str)
                                                   and payload["query"].startswith("mutation(")):
    die("fake gh: GraphQL serves only the viewer reads and the two pull-request mutations, not %r" % payload)
if method == "GET":
    reads = W.setdefault("reads", {})
    reads[path] = reads.get(path, 0) + 1
    if F.get("swap_at_read") == [path, reads[path]]:
        swap()
if method not in ("GET", "POST", "PATCH"):
    die("HTTP 405: the fake serves GET, POST and PATCH only (%s %s)" % (method, path))
if method != "GET":
    W["writes"] = W.get("writes", 0) + 1
    if F.get("fail_write") == W["writes"]:
        die("HTTP 422: injected refusal of write %d" % W["writes"])

def sha_of(*parts):
    import hashlib
    return hashlib.sha1(json.dumps(parts, sort_keys=True).encode()).hexdigest()


def blob_id(b64):
    import base64
    import hashlib
    data = base64.b64decode(b64)
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def entry_of(v):
    """(base64 content, mode) of a tree value."""
    return (v, "100644") if isinstance(v, str) else (v.get("content", ""), v.get("mode", "100644"))


def pr_obj(repo, n, i):
    return {"number": int(n), "title": i["title"], "body": i.get("body"), "state": i["state"], "node_id": "PR_%s" % n,
            "head": {"sha": i.get("head", "ab" * 20), "ref": i.get("head_ref", "feature")},
            "base": {"ref": i.get("base_ref", "main")}, "merged": bool(i.get("merged")), "draft": bool(i.get("draft")),
            "user": {"login": i.get("user", "someone")}}


if method == "POST" and path == "graphql":               # a mutation: a write on the pull request its node id names
    q = payload["query"]
    node = (payload.get("variables") or {}).get("id", "")
    hit = None
    for rname, rr in W["repos"].items():
        for n, i in rr["issues"].items():
            if i.get("pr") and "PR_%s" % n == node:
                hit = i
    if hit is None:
        die("gh: GraphQL: Could not resolve to a node with the global id of '%s'" % node)
    if "markPullRequestReadyForReview" in q:
        hit["draft"], name, draft = False, "markPullRequestReadyForReview", False
    elif "convertPullRequestToDraft" in q:
        hit["draft"], name, draft = True, "convertPullRequestToDraft", True
    else:
        die("fake gh: unknown mutation %r" % q)
    if F.get("swap_after_write") == W["writes"]:          # the after-write faults, as done() fires them for REST writes
        swap()
    if (F.get("append_after_write") or [None])[0] == W["writes"]:
        with open(F["append_after_write"][1], "a") as f:
            f.write(" ")
    if F.get("land_then_fail") == W["writes"]:            # counted (and fail_write refused) with every write above
        die("HTTP 502: the write landed, the answer was lost")
    out({"data": {name: {"pullRequest": {"isDraft": draft}}}})
    json.dump(W, open(STATE, "w"))
    sys.exit(0)

u = urllib.parse.urlsplit(path)
qs = dict(urllib.parse.parse_qsl(u.query))
parts = [urllib.parse.unquote(p) for p in u.path.split("/")]
API = "https://api.github.com/"


def stored(body):
    m = F.get("store")
    if m == "add-nl":
        return body + "\n"
    if m == "strip-nl":
        return body[:-1] if body.endswith("\n") else body
    if m == "flip":
        return body[:-1] + ("x" if not body.endswith("x") else "y") if body else "x"
    return body


def issue_obj(repo, n, i):
    o = {"number": int(n), "title": i["title"], "body": i.get("body"), "state": i["state"],
         "state_reason": i.get("state_reason"), "labels": [{"name": x} for x in i.get("labels", [])],
         "user": {"login": i.get("user", "someone")}, "html_url": "https://github.com/%s/issues/%s" % (repo, n)}
    if i.get("pr"):
        o["pull_request"] = {}
    if i.get("closed_by"):
        o["closed_by"] = {"login": i["closed_by"]}
    return o


def comment_obj(repo, cid, c):
    return {"id": int(cid), "body": c["body"], "user": {"login": c.get("user", "someone")},
            "issue_url": API + "repos/%s/issues/%d" % (repo, c["issue"])}


def nf():
    die("gh: Not Found (HTTP 404)")


def done(v):
    if method != "GET" and F.get("swap_after_write") == W["writes"]:
        swap()
    if method != "GET" and (F.get("append_after_write") or [None])[0] == W["writes"]:
        with open(F["append_after_write"][1], "a") as f:
            f.write(" ")
    if method != "GET" and F.get("land_then_fail") == W["writes"]:
        die("HTTP 502: the write landed, the answer was lost")
    out(v)
    json.dump(W, open(STATE, "w"))
    sys.exit(0)


if parts == ["user"]:
    die("gh: Resource not accessible by integration (HTTP 403)")
if len(parts) < 3 or parts[0] != "repos":
    nf()
repo = next((k for k in W["repos"] if k.lower() == (parts[1] + "/" + parts[2]).lower()), None)
R = W["repos"].get(repo)
if R is None:
    nf()
rest = parts[3:]
lag_on = F.get("lag") is True or (type(F.get("lag")) is int and F["lag"] > 0 and method == "GET"      # counted from the first
                                   and bool(W.get("created_issues") or W.get("created_comments"))  # read after a create
                                   and (rest in (["issues"], ["pulls"]) or (len(rest) == 3 and rest[2] == "comments")))
if lag_on and type(F.get("lag")) is int:
    F["lag"] -= 1                                        # one list read used up
lag = set(map(str, W.get("created_issues", []))) if lag_on else set()
lagc = set(map(str, W.get("created_comments", []))) if lag_on else set()

if method == "GET":
    if not rest:
        done(dict({"full_name": repo, "private": R["private"]}, **({"visibility": R["visibility"]} if "visibility" in R else {})))
    if rest[0] == "labels" and len(rest) == 2:
        done({"name": rest[1]}) if rest[1] in R.get("labels", []) else nf()
    if rest == ["issues"]:
        items = [issue_obj(repo, n, i) for n, i in sorted(R["issues"].items(), key=lambda kv: -int(kv[0]))
                 if n not in lag and (not qs.get("creator") or i.get("user") == qs["creator"])]
        done(items)
    if len(rest) == 2 and rest[0] == "issues" and rest[1].isdigit():
        i = R["issues"].get(rest[1])
        done(issue_obj(repo, rest[1], i)) if i else nf()
    if len(rest) == 3 and rest[0] == "issues" and rest[2] == "comments":
        if rest[1] not in R["issues"]:
            nf()
        done([comment_obj(repo, c, v) for c, v in sorted(R["comments"].items(), key=lambda kv: int(kv[0]))
              if v["issue"] == int(rest[1]) and c not in lagc])
    if len(rest) == 3 and rest[:2] == ["issues", "comments"]:
        c = R["comments"].get(rest[2])
        done(comment_obj(repo, rest[2], c)) if c else nf()
    if len(rest) == 2 and rest[0] == "pulls":
        i = R["issues"].get(rest[1])
        done(pr_obj(repo, rest[1], i)) if i and i.get("pr") else nf()
    if rest == ["pulls"]:
        owner, _c, hb = qs.get("head", ":").partition(":")
        done([pr_obj(repo, n, i) for n, i in sorted(R["issues"].items(), key=lambda kv: int(kv[0]))
              if i.get("pr") and n not in lag and (qs.get("state", "open") == "all" or i["state"] == qs.get("state", "open"))
              and (not hb or i.get("head_ref", "feature") == hb) and (not qs.get("base") or i.get("base_ref", "main") == qs["base"])])
    if rest[:3] == ["git", "ref", "heads"] and len(rest) > 3:
        b = "/".join(rest[3:])
        done({"ref": "refs/heads/" + b, "object": {"sha": R["branches"][b]}}) if b in R.get("branches", {}) else nf()
    if rest[:2] == ["git", "trees"] and len(rest) == 3:
        files = R.get("trees", {}).get(rest[2])
        if files is None:
            nf()
        kids, subs = {}, {}
        for fp, v in files.items():
            name, slash, tail = fp.partition("/")
            if slash:
                subs.setdefault(name, {})[tail] = v
            else:
                c, m = entry_of(v)
                kids[name] = {"path": name, "mode": m, "type": "commit" if m == "160000" else "blob", "sha": blob_id(c)}
        for name, sub in subs.items():
            sid = sha_of("tree", sub)
            R["trees"][sid] = sub
            kids[name] = {"path": name, "mode": "040000", "type": "tree", "sha": sid}
        done({"sha": rest[2], "tree": sorted(kids.values(), key=lambda x: x["path"]), "truncated": False})
    if rest[:2] == ["git", "commits"] and len(rest) == 3:
        c = R.get("commits", {}).get(rest[2])
        done({"sha": rest[2], "tree": {"sha": c["tree"]}, "parents": [{"sha": x} for x in c["parents"]],
              "author": c.get("author"), "committer": c.get("committer"), "message": c.get("message")}) if c else nf()
    if rest[:1] == ["contents"] and len(rest) > 1:
        ref = qs.get("ref", "main")
        c = R.get("commits", {}).get(R.get("branches", {}).get(ref, ref))
        files = R.get("trees", {}).get(c["tree"], {}) if c else {}
        fp = "/".join(rest[1:])
        if fp in files:
            done({"path": fp, "type": "file", "encoding": "base64", "content": entry_of(files[fp])[0]})
        if any(k.startswith(fp + "/") for k in files):
            done([{"path": k, "type": "file"} for k in files if k.startswith(fp + "/")])
        nf()
    nf()

if method == "POST" and rest == ["issues"]:
    n = str(W["next_issue"])
    W["next_issue"] += 1
    R["issues"][n] = {"title": payload["title"], "body": stored(payload.get("body", "")), "state": "open", "state_reason": None,
                      "labels": payload.get("labels", []), "user": W["viewer"]}
    W.setdefault("created_issues", []).append(int(n))
    done(issue_obj(repo, n, R["issues"][n]))
if method == "POST" and len(rest) == 3 and rest[0] == "issues" and rest[2] == "comments":
    if rest[1] not in R["issues"]:
        nf()
    c = str(W["next_comment"])
    W["next_comment"] += 1
    R["comments"][c] = {"issue": int(rest[1]), "body": stored(payload["body"]), "user": W["viewer"]}
    W.setdefault("created_comments", []).append(int(c))
    done(comment_obj(repo, c, R["comments"][c]))
if method == "POST" and rest == ["git", "blobs"]:
    s = blob_id(payload["content"]) if not F.get("bad_blob") else "0" * 40
    R.setdefault("blobs", {})[s] = payload["content"]
    done({"sha": s})
if method == "POST" and rest == ["git", "trees"]:
    base = {} if F.get("drop_base_tree") else dict(R.get("trees", {}).get(payload.get("base_tree"), {}))
    for e in payload["tree"]:
        if e.get("sha") is None and "content" not in e:   # GitHub: a null sha deletes the path
            base = {k: v for k, v in base.items() if k != e["path"] and not k.startswith(e["path"] + "/")}
            continue
        if e.get("sha") not in R.get("blobs", {}):
            die("HTTP 422: tree entry names no blob")
        parts = e["path"].split("/")
        if any("/".join(parts[:k]) in base for k in range(1, len(parts))):
            die("HTTP 422: a path under a file")
        base = {k: v for k, v in base.items() if not k.startswith(e["path"] + "/")}   # a blob over a directory replaces it
        base[e["path"]] = R["blobs"][e["sha"]] if e.get("mode", "100644") == "100644" else {"content": R["blobs"][e["sha"]],
                                                                                              "mode": e["mode"]}
    s = sha_of("tree", base)
    R.setdefault("trees", {})[s] = base
    done({"sha": s})
if method == "POST" and rest == ["git", "commits"]:
    if payload.get("tree") not in R.get("trees", {}):
        die("HTTP 422: no such tree")
    s = sha_of("commit", payload, W["writes"])
    R.setdefault("commits", {})[s] = {"tree": payload["tree"], "parents": payload["parents"], "message": payload["message"],
                                      "author": payload.get("author"), "committer": payload.get("committer")}
    done({"sha": s})
if method == "POST" and rest == ["git", "refs"]:
    b = payload["ref"][len("refs/heads/"):]
    if b in R.setdefault("branches", {}):
        die("HTTP 422: Reference already exists")
    if payload["sha"] not in R.get("commits", {}):
        die("HTTP 422: Object does not exist")
    R["branches"][b] = payload["sha"]
    done({"ref": payload["ref"], "object": {"sha": payload["sha"]}})
if method == "POST" and rest == ["pulls"]:
    if payload["head"] not in R.get("branches", {}) or payload["base"] not in R.get("branches", {}):
        die("HTTP 422: Validation Failed (head or base branch missing)")
    if any(i.get("pr") and i["state"] == "open" and i.get("head_ref") == payload["head"] and i.get("base_ref") == payload["base"]
           for i in R["issues"].values()):
        die("HTTP 422: A pull request already exists")
    n = str(W["next_issue"])
    W["next_issue"] += 1
    R["issues"][n] = {"title": payload["title"], "body": stored(payload.get("body", "")), "state": "open", "user": W["viewer"],
                      "pr": True, "head": R["branches"][payload["head"]], "head_ref": payload["head"],
                      "base_ref": payload["base"], "draft": bool(payload.get("draft"))}
    W.setdefault("created_issues", []).append(int(n))
    done(pr_obj(repo, n, R["issues"][n]))
if method == "PATCH" and len(rest) == 2 and rest[0] in ("issues", "pulls"):
    i = R["issues"].get(rest[1])
    if not i or (rest[0] == "pulls" and not i.get("pr")):
        nf()
    for key, v in payload.items():
        i[key] = stored(v) if key == "body" else v
    if payload.get("state") == "open":
        i["state_reason"] = "reopened"
        i.pop("closed_by", None)
    elif payload.get("state") == "closed":
        i["closed_by"] = W["viewer"]
    done(issue_obj(repo, rest[1], i))
if method == "PATCH" and len(rest) == 3 and rest[:2] == ["issues", "comments"]:
    c = R["comments"].get(rest[2])
    if not c:
        nf()
    c["body"] = stored(payload["body"])
    done(comment_obj(repo, rest[2], c))
nf()
