#!/usr/bin/env python3
"""Fixtures of the guarded merge for the fake `gh` (tests/fixtures/merge_gh.py): an all-green pull request, then named mutations.

    merge_fx.py <out.json> --skill <init-kb SKILL.md> [mutation[=arg] ...]

The base: repo acme/app, the PR numbered 7, head H, base `main` at B. The base config's deny globs are the list the `init-kb` skill proposes
(read from its text, so the test and the skill cannot drift apart), plus `deploy/**`, `image/**` and `**/*.pin`. Two changed
files (`src/app.py`, `docs/x.md`), two green checks of workflow `test`, not behind, no symlink. The head carries a config that
would widen everything (no deny glob, admin bypass on), which must have no effect. Each mutation changes one thing; `fx_*`
below, one per name.
"""
import json
import os
import re
import sys

REPO, PR = "acme/app", 7
H = "a1b2c3d4e5f60718293a4b5c6d7e8f9001122334"
H2 = "a1b2c3d4e5f60718293a4b5c6d7e8f9001122335"
B = "b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0"
R = "repos/%s/" % REPO
IMG = "ghcr.io/acme/app-image"
CFG = R + "contents/.vibemaestro/sdlc.json?ref="
CHECKS = R + "commits/%s/check-runs?filter=all&per_page=100" % H
JOBS = R + "actions/jobs/"
REV_FILE = ".github/workflows/image.yml"


def proposed_deny(skill):
    """The JSON list on the row of the init-kb merge questions that names `merge.deny_globs`."""
    for line in open(skill, encoding="utf-8"):
        if "`merge.deny_globs`" in line:
            lists = re.findall(r"`(\[.*?\])`", line)       # the last one: the Default column
            if lists:
                return json.loads(lists[-1])
    sys.exit("merge_fx: no proposed merge.deny_globs list in %s" % skill)


S2 = "c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0"
ADAPTER = 'def runs(repo, sha):\n    return [{"name": "ext", "status": "completed", "conclusion": "success", "started_at": "2026-10-16T10:00:00Z"}]\n'


def run(i, name, concl, t, suite=101, status="completed"):
    return {"id": i, "name": name, "status": status, "conclusion": concl, "started_at": t, "check_suite": {"id": suite},
            "app": {"slug": "github-actions"}}


def base(deny):
    cfg = {"schema": 1, "merge": {"deny_globs": deny + ["deploy/**", "image/**", "**/*.pin"], "image_bump": {
        "enabled": False, "tag_files": ["deploy/app.yaml"], "tree": "image/",
        "revision": {"file": REV_FILE, "pattern": "IMAGE_REVISION: \"(r[0-9]+)\""},
        "registry": {"backend": "ghcr", "host": "ghcr.io", "image": "acme/app-image"}}}}
    files = [{"filename": "src/app.py", "status": "modified", "patch": "@@ -1 +1 @@\n-a = 1\n+a = 2"},
             {"filename": "docs/x.md", "status": "added", "patch": "@@ -0,0 +1 @@\n+x"}]
    return {
        "repo": REPO,
        "pr": {"number": PR, "state": "OPEN", "isDraft": False, "baseRefName": "main", "headRefName": "feat/x", "headRefOid": H, "mergeable": "MERGEABLE",
               "changedFiles": 2, "url": "https://github.invalid/acme/app/pull/7",
               "title": "feat: TITLE-MUST-NOT-BE-LOGGED", "body": "BODY-MUST-NOT-BE-LOGGED"},
        "api": {
            R[:-1]: {"full_name": REPO, "default_branch": "main"},
            R + "git/ref/heads/main": {"ref": "refs/heads/main", "object": {"sha": B, "type": "commit"}},
            CFG + B: json.dumps(cfg),
            CFG + H: json.dumps({"schema": 1, "merge": {"deny_globs": [], "admin_bypass": True}}),
            R + "pulls/%d/files?per_page=100" % PR: files,
            R + "git/trees/%s?recursive=1" % H: {"sha": H, "truncated": False, "tree": [
                {"path": "src", "mode": "040000", "type": "tree"}, {"path": "src/app.py", "mode": "100644", "type": "blob"},
                {"path": "docs", "mode": "040000", "type": "tree"}, {"path": "docs/x.md", "mode": "100644", "type": "blob"}]},
            R + "compare/%s...%s" % (H, B): {"status": "behind", "ahead_by": 0, "behind_by": 1, "files": []},
            R + "actions/runs?head_sha=%s&per_page=100" % H: {"total_count": 2, "workflow_runs": [
                {"id": 11, "name": "test", "workflow_id": 9001, "check_suite_id": 101},
                {"id": 12, "name": "gates", "workflow_id": 9002, "check_suite_id": 102}]},
            CHECKS: {"total_count": 2, "check_runs": [run(201, "unit", "success", "2026-10-16T10:00:00Z"),
                                                       run(202, "lint", "success", "2026-10-16T10:00:00Z")]},
            R + "commits/%s/statuses?per_page=100" % H: [],
            "orgs/acme/packages/container/app-image": {"name": "app-image", "visibility": "private"},
            "orgs/acme/packages/container/app-image/versions?per_page=100": [
                {"id": 1, "metadata": {"container": {"tags": ["cc1-node22-r15"]}}},
                {"id": 2, "metadata": {"container": {"tags": ["cc1-node22-r16"]}}}],
            R + "contents/%s?ref=%s" % (REV_FILE, H): 'env:\n  IMAGE_REVISION: "r16"\n',
            # the base's trees, walked one level at a time to read the git mode of the guard's own inputs
            R + "git/trees/" + B: {"sha": B, "truncated": False, "tree": [
                {"path": ".vibemaestro", "mode": "040000", "type": "tree", "sha": "t0vm"},
                {"path": "tools", "mode": "040000", "type": "tree", "sha": "t0tools"}]},
            R + "git/trees/t0vm": {"sha": "t0vm", "tree": [{"path": "sdlc.json", "mode": "100644", "type": "blob"}]},
            R + "git/trees/t0tools": {"sha": "t0tools", "tree": [{"path": "ci.py", "mode": "100644", "type": "blob"}]},
        },
    }


def cfg_of(fx):
    return json.loads(fx["api"][CFG + B])


def set_cfg(fx, cfg):
    fx["api"][CFG + B] = json.dumps(cfg)


def checks(fx):
    return fx["api"][CHECKS]["check_runs"]


def add_runs(fx, *runs):
    checks(fx).extend(runs)
    fx["api"][CHECKS]["total_count"] = len(checks(fx))


def add_file(fx, path, status="added", patch="@@ -0,0 +1 @@\n+x", mode="100644", prev=None):
    f = {"filename": path, "status": status, "patch": patch}
    if prev:
        f["previous_filename"] = prev
    if patch is None:
        del f["patch"]
    fx["api"][R + "pulls/%d/files?per_page=100" % PR].append(f)
    fx["pr"]["changedFiles"] += 1
    if status != "removed":
        fx["api"][R + "git/trees/%s?recursive=1" % H]["tree"].append({"path": path, "mode": mode, "type": "blob"})


def job(fx, i, failed, ok=("Set up job",), status="completed"):
    fx["api"][JOBS + str(i)] = {"id": i, "status": status, "conclusion": "failure", "steps":
                                [{"name": s, "conclusion": "success"} for s in ok] +
                                [{"name": s, "conclusion": "failure"} for s in failed] + [{"name": "Complete job", "conclusion": "skipped"}]}


# ── mutations ──────────────────────────────────────────────────────────────────────────────────────
def fx_closed(fx, _a): fx["pr"]["state"] = "CLOSED"
def fx_draft(fx, _a): fx["pr"]["isDraft"] = True
def fx_conflict(fx, _a): fx["pr"]["mergeable"] = "CONFLICTING"
def fx_mergeable_late(fx, _a): fx["pr"]["mergeable_seq"] = ["UNKNOWN", "MERGEABLE"]
def fx_mergeable_unknown(fx, _a): fx["pr"]["mergeable_seq"] = ["UNKNOWN"]
def fx_moved_head(fx, _a): fx["pr"]["merge_head"] = H2
def fx_pr_view_fail(fx, _a): fx.setdefault("fail", {})["pr view"] = "boom"
def fx_after_merge_head(fx, _a): fx["pr"]["after_merge_head"] = H2
def fx_merge_mode(fx, a): fx["pr"]["merge_mode"] = a
def fx_view_fails_after_merge(fx, _a): fx["fail_after_merge"] = {"pr view": "boom"}


def fx_base_other(fx, _a):
    """the PR targets `scratch`, whose tip carries a config that allows everything (no deny glob, admin bypass on)."""
    fx["pr"]["baseRefName"] = "scratch"
    fx["api"][R + "git/ref/heads/scratch"] = {"ref": "refs/heads/scratch", "object": {"sha": S2, "type": "commit"}}
    fx["api"][CFG + S2] = json.dumps({"schema": 1, "merge": {"deny_globs": [], "admin_bypass": True}})
    fx["api"][R + "git/trees/" + S2] = fx["api"][R + "git/trees/" + B]
    fx["api"][R + "compare/%s...%s" % (H, S2)] = {"status": "ahead", "ahead_by": 0, "files": []}


def fx_status_only(fx, _a):
    """no check run at all, one commit status in success (anyone with push access can post one)."""
    fx["api"][CHECKS] = {"total_count": 0, "check_runs": []}
    fx["api"][R + "commits/%s/statuses?per_page=100" % H] = [{"id": 302, "context": "looks-good", "state": "success",
                                                              "created_at": "2026-10-16T10:00:00Z"}]


def fx_status_named(fx, a):
    """a commit status in success named like a check (`a`)."""
    fx["api"][R + "commits/%s/statuses?per_page=100" % H] = [{"id": 303, "context": a, "state": "success",
                                                              "created_at": "2026-10-16T10:00:00Z"}]


def fx_same_workflow_name(fx, _a):
    """two workflow files both named `test`: unit red at 11:00 in one, unit green at 12:00 in the other."""
    fx["api"][R + "actions/runs?head_sha=%s&per_page=100" % H]["workflow_runs"].append(
        {"id": 13, "name": "test", "workflow_id": 9003, "check_suite_id": 103})
    fx["api"][R + "actions/runs?head_sha=%s&per_page=100" % H]["total_count"] = 3
    add_runs(fx, run(207, "unit", "failure", "2026-10-16T11:00:00Z", suite=101), run(208, "unit", "success", "2026-10-16T12:00:00Z", suite=103))


def fx_fraction_time(fx, _a):
    """unit green at 12:00:00Z, then red at 12:00:00.500Z (the latest, by half a second; the green run has the higher id, so
    a reader that drops the fraction and breaks the tie by id picks the green one)."""
    add_runs(fx, run(209, "unit", "failure", "2026-10-16T12:00:00.500Z"), run(210, "unit", "success", "2026-10-16T12:00:00Z"))
    job(fx, 209, ["Run tests"])


def fx_completed_no_start(fx, _a):
    """unit red at 11:00, then a completed green run with no start time."""
    add_runs(fx, run(211, "unit", "failure", "2026-10-16T11:00:00Z"), run(212, "unit", "success", None))
    job(fx, 211, ["Run tests"])


def fx_colon_check(fx, a):
    """a red check named `CI: unit` whose job's failed steps are `a` (`|`-separated)."""
    add_runs(fx, run(213, "CI: unit", "failure", "2026-10-16T11:00:00Z"))
    job(fx, 213, a.split("|"))


def fx_external_ci(fx, a):
    """ci.backend external:tools/ci.py at the base; `a` is `exit` for an adapter whose runs() calls sys.exit(0)."""
    cfg = cfg_of(fx)
    cfg["ci"] = {"backend": "external:tools/ci.py"}
    set_cfg(fx, cfg)
    body = {"exit": "import sys\ndef runs(repo, sha):\n    sys.exit(0)\n", "exit-load": "import sys\nsys.exit(0)\n"}.get(a, ADAPTER)
    fx["api"][R + "contents/tools/ci.py?ref=" + B] = body


def fx_base_moved(fx, _a):
    """main moved to S2 (another PR landed): the same config there, and the comparison with the head as it was against B."""
    fx["api"][R + "git/ref/heads/main"] = {"ref": "refs/heads/main", "object": {"sha": S2, "type": "commit"}}
    fx["api"][CFG + S2] = fx["api"][CFG + B]
    fx["api"][R + "git/trees/" + S2] = fx["api"][R + "git/trees/" + B]
    fx["api"][R + "compare/%s...%s" % (H, S2)] = fx["api"][R + "compare/%s...%s" % (H, B)]


def fx_default_branch(fx, a):
    """the repository's default branch is `a` (a legal name such as dev+main), and the PR targets it."""
    fx["api"][R[:-1]]["default_branch"] = a
    fx["pr"]["baseRefName"] = a
    fx["api"][R + "git/ref/heads/" + a.replace("+", "%2B")] = fx["api"].pop(R + "git/ref/heads/main")


RT = "d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0"


def release_at(fx, status):
    """the branch `release` exists at RT, and comparing the head with it gives `status` (ahead: the head is on release)."""
    fx["api"][R + "git/ref/heads/release"] = {"ref": "refs/heads/release", "object": {"sha": RT, "type": "commit"}}
    fx["api"][R + "compare/%s...%s" % (H, RT)] = {"status": status, "ahead_by": 1 if status == "ahead" else 0, "behind_by": 0, "files": []}


def fx_backmerge(fx, a):
    """the head ref is backmerge/<sha12>; `a`: on (the head is on release), identical (it is the release tip), off (it is not
    on release), none (there is no branch release)."""
    fx["pr"]["headRefName"] = "backmerge/" + H[:12]
    if a != "none":
        release_at(fx, {"on": "ahead", "identical": "identical", "off": "diverged"}[a])


def fx_on_release(fx, a):
    """the head ref is not backmerge/*, and the head is on release (`a`: on) or not (off)."""
    release_at(fx, "ahead" if a == "on" else "diverged")


def fx_input_symlink(fx, a):
    """at the base, the guard's input `a` (config or adapter) is a symlink, so a PR could change its target unseen."""
    key = {"config": R + "git/trees/t0vm", "adapter": R + "git/trees/t0tools"}[a]
    fx["api"][key]["tree"][0]["mode"] = "120000"


def fx_base_tree_truncated(fx, _a):
    """the base's root tree comes back truncated, without the entry the walk needs."""
    root = fx["api"][R + "git/trees/" + B]
    root["truncated"] = True
    root["tree"] = [e for e in root["tree"] if e["path"] != "tools"]


def fx_merge_hang(fx, a):
    """`pr merge` does not answer for `a` seconds (it may still have reached GitHub)."""
    fx["pr"]["merge_hang_s"] = float(a)


def fx_deny_none(fx, _a):
    cfg = cfg_of(fx)
    cfg["merge"]["deny_globs"] = []
    set_cfg(fx, cfg)


def fx_stale_green(fx, _a):
    """unit: green at 10:00, then a rerun red at 11:00 (the latest)."""
    add_runs(fx, run(203, "unit", "failure", "2026-10-16T11:00:00Z"))
    job(fx, 203, ["Run tests"])


def fx_rerun_green(fx, _a):
    """unit: red at 09:00, then green at 10:00 (the latest): passes."""
    add_runs(fx, run(203, "unit", "failure", "2026-10-16T09:00:00Z"))


def fx_skipped_after_green(fx, _a):
    """unit: green at 10:00, then a duplicate run skipped by its `if:` that completes later (11:00): the green run counts."""
    add_runs(fx, run(203, "unit", "skipped", "2026-10-16T11:00:00Z"))


def fx_red_after_skipped(fx, _a):
    """unit: green at 10:00, skipped at 11:00, then a real rerun red at 12:00 (the newest real run)."""
    add_runs(fx, run(203, "unit", "skipped", "2026-10-16T11:00:00Z"), run(204, "unit", "failure", "2026-10-16T12:00:00Z"))
    job(fx, 204, ["Run tests"])


def fx_skipped_after_red(fx, _a):
    """unit: green at 10:00, a real rerun red at 10:30, then a run its `if:` skipped (an untouched edit) at 11:00: still red."""
    add_runs(fx, run(203, "unit", "failure", "2026-10-16T10:30:00Z"), run(204, "unit", "skipped", "2026-10-16T11:00:00Z"))
    job(fx, 203, ["Run tests"])


def fx_draft_then_ready(fx, _a):
    """unit: skipped on the draft at 09:00, then the ready_for_review run green at 10:00: the ready run counts."""
    fx["api"][CHECKS] = {"total_count": 2, "check_runs": [run(201, "unit", "skipped", "2026-10-16T09:00:00Z"),
                                                          run(202, "unit", "success", "2026-10-16T10:00:00Z")]}


def fx_pending(fx, _a): add_runs(fx, run(203, "e2e", None, "2026-10-16T11:00:00Z", status="in_progress"))


def fx_queued_after_green(fx, _a):
    """lint: green, then a rerun queued (not started yet, so the newest): pending."""
    add_runs(fx, run(204, "lint", None, None, status="queued"))


def fx_empty_checks(fx, _a):
    fx["api"][CHECKS] = {"total_count": 0, "check_runs": []}


def fx_only_skipped(fx, _a):
    fx["api"][CHECKS] = {"total_count": 1, "check_runs": [run(201, "unit", "skipped", "2026-10-16T10:00:00Z")]}


def fx_other_workflow_red(fx, _a):
    """gates/unit red at 09:00, test/unit green at 10:00: another workflow's job of the same name does not hide it."""
    add_runs(fx, run(205, "unit", "failure", "2026-10-16T09:00:00Z", suite=102))


def fx_status_error(fx, _a):
    fx["api"][R + "commits/%s/statuses?per_page=100" % H] = [{"id": 301, "context": "ci/ext", "state": "error",
                                                              "created_at": "2026-10-16T10:00:00Z"}]


def fx_required(fx, a):
    cfg = cfg_of(fx)
    cfg["merge"]["required_checks"] = a.split(",")
    set_cfg(fx, cfg)


def fx_e2e(fx, a):
    """a check `e2e` with the given conclusion (skipped: a path filter skipped it)."""
    add_runs(fx, run(206, "e2e", a, "2026-10-16T10:30:00Z"))


def fx_red_unit(fx, a):
    """unit red at 11:00 (the latest); its job's failed steps are the `|`-separated names."""
    add_runs(fx, run(203, "unit", "failure", "2026-10-16T11:00:00Z"))
    job(fx, 203, a.split("|"))


def fx_red_unit_cancelled(fx, _a):
    add_runs(fx, run(203, "unit", "cancelled", "2026-10-16T11:00:00Z"))
    job(fx, 203, ["Full suite before ready"])


def fx_red_only(fx, a):
    """every check red: unit with the given failed steps, lint gone."""
    fx["api"][CHECKS] = {"total_count": 1, "check_runs": [run(203, "unit", "failure", "2026-10-16T11:00:00Z")]}
    job(fx, 203, a.split("|"))


def fx_file(fx, a): add_file(fx, a)
def fx_symlink(fx, a): add_file(fx, a, mode="120000")
def fx_submodule(fx, a): add_file(fx, a, mode="160000", patch=None)
def fx_removed(fx, a): add_file(fx, a, status="removed")


def fx_rename(fx, a):
    old, new = a.split(":")
    add_file(fx, new, status="renamed", prev=old)


def fx_tree_truncated(fx, _a): fx["api"][R + "git/trees/%s?recursive=1" % H]["truncated"] = True
def fx_count_mismatch(fx, _a): fx["pr"]["changedFiles"] += 1


def fx_behind(fx, a):
    fx["api"][R + "compare/%s...%s" % (H, B)] = {"status": "diverged", "ahead_by": 2, "behind_by": 1,
                                                 "files": [{"filename": f, "status": "modified"} for f in a.split(",")]}


MB = "d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0"     # the merge base of head and base
TM = "e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0"     # GitHub's test merge of the PR


def text(lines):
    return "\n".join(lines) + "\n"


def fx_shared(fx, a):
    """`<path>[:<fault>]`: main and the PR both modified <path> since the merge base MB, main its first fact, the PR its last;
    GitHub's test merge TM (parents B, H) holds the merged text, built here by hand. Faults: conflict (both edit the first fact),
    differs (TM holds other bytes), stale (TM's parents are another base), renamed (main renamed <path> away), added (both sides
    added <path>), link (a symlink at the base), nul (the PR's text holds a NUL byte), over-cap (each side adds a long line: each
    under the ledger's byte cap, the merge over it)."""
    path, _sep, fault = a.partition(":")
    lines = ["# Current state", ""] + ["- fact %d holds" % i for i in range(1, 11)]
    ours, theirs = list(lines), list(lines)
    ours[2], theirs[11] = "- fact 1 holds on main", "- fact 10 holds in the PR"
    merged = list(ours)
    merged[11] = theirs[11]
    if fault == "conflict":
        theirs[2] = "- fact 1 holds in the PR"
    if fault == "nul":
        theirs[11] = merged[11] = "- fact 10 holds in the PR\x00"
    if fault == "over-cap":
        ours, theirs = list(lines), list(lines)
        ours.insert(2, "- " + "m" * 150)
        theirs.append("- " + "p" * 150)
        merged = ours + [theirs[-1]]
        cfg = cfg_of(fx)
        cfg.setdefault("current_state", {})["limits"] = {"bytes": len(text(lines)) + 200}
        set_cfg(fx, cfg)
    status = "added" if fault == "added" else "modified"
    put_shared(fx, path, status, fault, lines, ours, theirs,
               merged if fault != "differs" else merged + ["- a line only GitHub's merge has"])


def put_shared(fx, path, status, fault, lines, ours, theirs, merged):
    """main and the PR both changed <path> since MB: the PR's file, the comparison, the base tree entry, the four texts and
    GitHub's test merge TM (parents B, H; S2, H when `fault` is stale)."""
    add_file(fx, path, status=status, patch="@@ -12 +12 @@\n-- fact 10 holds\n+- fact 10 holds in the PR")
    bfile = {"filename": path, "status": status}
    if fault == "renamed":
        bfile = {"filename": path.rsplit("/", 1)[0] + "/moved.md", "previous_filename": path, "status": "renamed"}
    fx["api"][R + "compare/%s...%s" % (H, B)] = {"status": "diverged", "ahead_by": 1, "behind_by": 1,
                                                 "merge_base_commit": {"sha": MB}, "files": [bfile]}
    base_tree_add(fx, path, "120000" if fault == "link" else "100644")
    q = R + "contents/%s?ref=" % path
    fx["api"][q + MB], fx["api"][q + B], fx["api"][q + H] = text(lines), text(ours), text(theirs)
    fx["api"][q + TM] = text(merged)
    fx["api"][R + "pulls/%d" % PR] = dict(fx["api"].get(R + "pulls/%d" % PR) or {"number": PR}, merge_commit_sha=TM)
    fx["api"][R + "git/commits/" + TM] = {"sha": TM, "parents": [{"sha": S2 if fault == "stale" else B}, {"sha": H}]}


def base_tree_add(fx, path, mode):
    """put <path> (at most one directory deep) into the base's trees, which the guard walks one level at a time."""
    top, _sep, name = path.rpartition("/")
    root = fx["api"][R + "git/trees/" + B]["tree"]
    if not top:
        root.append({"path": name, "mode": mode, "type": "blob"})
        return
    if not any(e["path"] == top for e in root):
        root.append({"path": top, "mode": "040000", "type": "tree", "sha": "t0" + top})
    sub = fx["api"].setdefault(R + "git/trees/t0" + top, {"sha": "t0" + top, "tree": []})["tree"]
    sub[:] = [e for e in sub if e["path"] != name] + [{"path": name, "mode": mode, "type": "blob"}]


# ── --behind auto ──────────────────────────────────────────────────────────────────────────────────────
TM_OLD = "e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1e1"  # a test merge GitHub made against an older base
PLAN_PY = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir, "plan.py")  # the kit's real planner
PLANNER = {"script": "tests/plan.py", "inputs": ["tests/suites.map", "tests/map-exclusions.txt"]}
# the PR's files: src/app.py wakes app, docs/x.md wakes docs-check
MAP = """@full tests/plan.py tests/map-exclusions.txt
@always plan
@with web api
%core src/core/*
app src/app.py %core
web src/web/*
api src/api/*
docs-check docs/*
lib lib/*
plan tests/plan-input.txt
"""
# what a PR's own map could say: src/core/* moved from app to lib (base-only src/core/z.py would then miss the PR's app)
MAP_HEAD = MAP.replace("app src/app.py %core", "app src/app.py").replace("lib lib/*", "lib lib/* %core")
EXCL = ("ops/*  notes no suite reads\nkb/*  the knowledge base: no suite here reads it\n.vibemaestro/*  the guard's config\n"
        # agent instructions no suite here reads: so only (b) refuses them, and a break of (b) turns its case green
        "[A-Z]*.md  agent instructions at the root\n.claude/*  agent config\nguides/*  a rules directory\n"
        + "".join("%s/*  agent instructions\n" % d for d in ("skills", "agents", "commands", "rules", "prompts", "hooks")))
# what main's map says since the merge base: src/new/* moved onto web's line (map MAP at MB)
MAP_MOVED = MAP.replace("web src/web/*", "web src/web/* src/new/*")
# the base's planner as a probe: it answers `leak` for any path when it sees a token, a PATH, a HOME other than its directory,
# or can open a socket; else nothing
PROBE = """import os, socket, sys
sys.stdin.buffer.read()
bad = [k for k in os.environ if "TOKEN" in k or k.startswith(("GH_", "GITHUB"))]
if os.environ.get("PATH") or os.environ.get("HOME") != os.getcwd():
    bad.append("env")
try:
    socket.socket().close()
    bad.append("socket")
except OSError:
    pass
if bad:
    print("leak")
"""


def fx_planner(fx, a):
    """merge.planner in the base config: the kit's real tests/plan.py, MAP and EXCL, served at the base B and in its trees. `a`:
    link (the map is a symlink at the base), missing (the exclusion list is not at the base), probe (the planner is PROBE)."""
    cfg = cfg_of(fx)
    cfg["merge"]["planner"] = PLANNER
    set_cfg(fx, cfg)
    with open(PLAN_PY, encoding="utf-8") as f:
        texts = {"tests/plan.py": PROBE if a == "probe" else f.read(), "tests/suites.map": MAP, "tests/map-exclusions.txt": EXCL}
    for rel, t in texts.items():
        if a == "missing" and rel == "tests/map-exclusions.txt":
            continue
        fx["api"][R + "contents/%s?ref=%s" % (rel, B)] = fx["api"][R + "contents/%s?ref=%s" % (rel, MB)] = t
        base_tree_add(fx, rel, "120000" if a == "link" and rel == "tests/suites.map" else "100644")
    fx["api"][R + "git/trees/" + MB] = fx["api"][R + "git/trees/" + B]    # the merge base holds the same files


def fx_auto(fx, a):
    """GitHub's REST view of the PR for --behind auto: merge_commit_sha TM with the parents (B, H) and mergeable true. `a`:
    conflict (fresh, mergeable false), conflict-null (no test merge at all, mergeable false), stale (TM's parents are an
    older base on every read), late (TM_OLD of an older base, then no test merge, then TM fresh: the third read)."""
    key = R + "pulls/%d" % PR
    pr = dict(fx["api"].get(key) or {"number": PR}, merge_commit_sha=TM if a != "conflict-null" else None,
              mergeable=a not in ("conflict", "conflict-null"))
    fx["api"].setdefault(R + "git/commits/" + TM, {"sha": TM, "parents": [{"sha": B}, {"sha": H}]})
    if a == "stale":
        fx["api"][R + "git/commits/" + TM] = {"sha": TM, "parents": [{"sha": S2}, {"sha": H}]}
    if a == "late":
        fx["api"][R + "git/commits/" + TM_OLD] = {"sha": TM_OLD, "parents": [{"sha": S2}, {"sha": H}]}
        pr = {"__seq__": [dict(pr, merge_commit_sha=TM_OLD), dict(pr, merge_commit_sha=None, mergeable=None), pr]}
    fx["api"][key] = pr


def fx_base_also(fx, a):
    """main also changed these files (comma-separated), which the PR does not touch."""
    c = fx["api"][R + "compare/%s...%s" % (H, B)]
    c["files"] = (c.get("files") or []) + [{"filename": f, "status": "modified"} for f in a.split(",")]
    c["ahead_by"] = max(c.get("ahead_by") or 0, 1)


def fx_base_map(fx, _a):
    """main changed tests/suites.map since the merge base MB (MAP there, MAP_MOVED at B), and the PR did not. Apply after
    `planner`."""
    fx["api"][R + "contents/tests/suites.map?ref=" + B] = MAP_MOVED
    c = fx["api"][R + "compare/%s...%s" % (H, B)]
    c["files"] = (c.get("files") or []) + [{"filename": "tests/suites.map", "status": "modified"}]
    c["ahead_by"], c["merge_base_commit"] = max(c.get("ahead_by") or 0, 1), {"sha": MB}


def fx_shared_map(fx, _a):
    """main and the PR both added a suite line to tests/suites.map (planner data), far apart: git merges them clean. Apply
    after `planner`: the base's map is then main's side."""
    lines = MAP.rstrip("\n").split("\n")
    ours, theirs = list(lines), list(lines)
    ours.insert(3, "ops-b ops/b/*")
    theirs.append("tools tools/*")
    merged = list(ours) + ["tools tools/*"]
    put_shared(fx, "tests/suites.map", "modified", "", lines, ours, theirs, merged)


def head_planner_files(fx, script, map_text):
    """the planner's three files as the PR's head has them: a guard that read them there would run these."""
    with open(PLAN_PY, encoding="utf-8") as f:
        texts = {"tests/plan.py": script or f.read(), "tests/suites.map": map_text, "tests/map-exclusions.txt": EXCL}
    for rel, t in texts.items():
        fx["api"][R + "contents/%s?ref=%s" % (rel, H)] = t


def fx_head_planner(fx, a):
    """the PR changes tests/plan.py; its head version writes the marker file `a` and prints nothing (no suite: it would accept)."""
    add_file(fx, "tests/plan.py", status="modified", patch="@@ -1 +1 @@\n-#!/usr/bin/env python3\n+import sys")
    head_planner_files(fx, "import sys\nsys.stdin.buffer.read()\nopen(%r, 'w').write('ran')\n" % a, MAP)


def fx_head_map(fx, _a):
    """the PR changes tests/suites.map to MAP_HEAD, under which its sides would not meet."""
    add_file(fx, "tests/suites.map", status="modified", patch="@@ -5 +5 @@\n-app src/app.py %core\n+app src/app.py")
    head_planner_files(fx, None, MAP_HEAD)


def fx_bootstrap(fx, a):
    """main has no config; the PR adds it (the skill's deny globs, the rules directory init writes, admin bypass and the image lane
    on) and a rules file under .vibemaestro/. `a`: empty-deny (the added config denies nothing), modified (the
    PR modifies the config instead of adding it), external (the added config names an external CI adapter), no-deny (it sets
    no merge.deny_globs), workflow (the PR also adds a workflow, which the added deny globs refuse)."""
    head = cfg_of(fx)                               # the base's rules, and a forged grant: admin bypass and the image lane on
    del fx["api"][CFG + B]
    head["merge"]["admin_bypass"] = True
    head["merge"]["image_bump"]["enabled"] = True
    head["rules"] = {"dirs": [".vibemaestro/rules"]}
    if a == "empty-deny":
        head["merge"]["deny_globs"] = []
    if a == "external":
        head["ci"] = {"backend": "external:tools/ci.py"}
    if a == "no-deny":
        head = {"schema": 1}
    fx["api"][CFG + H] = json.dumps(head)
    add_file(fx, ".vibemaestro/sdlc.json", status="modified" if a == "modified" else "added")
    add_file(fx, ".vibemaestro/rules/README.md")
    if a == "workflow":
        add_file(fx, ".github/workflows/ci.yml")


def fx_rules_dirs(fx, a):
    """rules.dirs in the base config: the comma-separated directories `a` (rule Markdown an agent loads as instructions)."""
    cfg = cfg_of(fx)
    cfg["rules"] = {"dirs": a.split(",")}
    set_cfg(fx, cfg)


def fx_ledger(fx, a):
    """current_state.path is `a` in the base config."""
    cfg = cfg_of(fx)
    cfg.setdefault("current_state", {})["path"] = a
    set_cfg(fx, cfg)


def fx_config_unreadable(fx, _a): fx.setdefault("fail", {})[CFG + B] = "boom"
def fx_no_config(fx, _a): del fx["api"][CFG + B]
def fx_bad_config(fx, _a): fx["api"][CFG + B] = '{"merge": {"deny_globs": ["[x"]}}'
def fx_config_no_merge(fx, _a): fx["api"][CFG + B] = '{"schema": 1}'


def fx_admin_on(fx, _a):
    cfg = cfg_of(fx)
    cfg["merge"]["admin_bypass"] = True
    set_cfg(fx, cfg)


def fx_registry_none(fx, _a):
    cfg = cfg_of(fx)
    cfg["merge"]["image_bump"]["registry"] = None
    set_cfg(fx, cfg)


def fx_lane(fx, a):
    """the lane on, and a bump PR: the tag file, a file of the image tree and the revision file; `a` picks a fault."""
    cfg = cfg_of(fx)
    cfg["merge"]["image_bump"]["enabled"] = True
    set_cfg(fx, cfg)
    files = fx["api"][R + "pulls/%d/files?per_page=100" % PR]
    del files[:]
    fx["pr"]["changedFiles"] = 0
    new = "cc1-node22-r17" if a == "tag-missing" else "cc1-node22-r16"
    other = "cc1-node22-r99" if a == "two-tags" else new
    manifest = ("@@ -10,4 +10,4 @@\n   containers:\n-    - image: %s:cc1-node22-r15\n+    - image: %s:%s\n"
                "-      app.kubernetes.io/version: \"cc1-node22-r15\"\n+      app.kubernetes.io/version: \"%s\"\n" % (IMG, IMG, new, other))
    if a == "non-tag":
        manifest += "@@ -30 +30 @@\n-    replicas: 1\n+    replicas: 3\n"
    add_file(fx, "deploy/app.yaml", status="modified", patch=manifest)
    add_file(fx, "image/Dockerfile", status="modified", patch="@@ -1 +1 @@\n-FROM node:20\n+FROM node:22")
    rev = "r17" if a == "tag-missing" else "r16"
    add_file(fx, REV_FILE, status="modified", patch='@@ -3 +3 @@\n-  IMAGE_REVISION: "r15"\n+  IMAGE_REVISION: "%s"' % rev)
    fx["api"][R + "contents/%s?ref=%s" % (REV_FILE, H)] = 'env:\n  IMAGE_REVISION: "%s"\n' % rev
    if a == "pin":
        add_file(fx, "image/plugin.pin", status="modified", patch="@@ -1 +1 @@\n-abc\n+def")
    if a == "outside":
        add_file(fx, "src/app.py", status="modified", patch="@@ -1 +1 @@\n-a\n+b")
    if a == "rename-tag":                            # a second tag file renamed into the tree, its content rewritten
        cfg = cfg_of(fx)
        cfg["merge"]["image_bump"]["tag_files"].append("deploy/other.yaml")
        set_cfg(fx, cfg)
        add_file(fx, "image/other.yaml", status="renamed", prev="deploy/other.yaml", patch="@@ -1 +1 @@\n-kind: Deployment\n+kind: Nothing")
    if a == "sidecar":                               # another image's line carrying the same tag text
        files = fx["api"][R + "pulls/%d/files?per_page=100" % PR]
        files[0]["patch"] += "@@ -40 +40 @@\n-    - image: docker.io/someone/sidecar:cc1-node22-r15\n+    - image: docker.io/someone/sidecar:%s\n" % new
    if a == "args":                                  # an argument that holds the old tag text
        files = fx["api"][R + "pulls/%d/files?per_page=100" % PR]
        files[0]["patch"] += '@@ -50 +50 @@\n-    args: ["--allow-from=cc1-node22-r15"]\n+    args: ["--allow-from=%s"]\n' % new
    if a == "no-newline":                            # the image line is the file's last line, with no final newline
        files = fx["api"][R + "pulls/%d/files?per_page=100" % PR]
        files[0]["patch"] = ("@@ -10 +10 @@\n-    - image: %s:cc1-node22-r15\n\\ No newline at end of file\n"
                             "+    - image: %s:%s\n\\ No newline at end of file" % (IMG, IMG, new))
    if a == "rev-rename":                           # the revision file renamed into the image tree
        files = fx["api"][R + "pulls/%d/files?per_page=100" % PR]
        for f in files:
            if f["filename"] == REV_FILE:
                f["filename"], f["status"], f["previous_filename"] = "image/image.yml", "renamed", REV_FILE
    if a == "revision-other":
        fx["api"][R + "contents/%s?ref=%s" % (REV_FILE, H)] = 'env:\n  IMAGE_REVISION: "r18"\n'


def fx_lane_off(fx, _a):
    cfg = cfg_of(fx)
    cfg["merge"]["image_bump"]["enabled"] = False
    set_cfg(fx, cfg)


def main(argv):
    out, skill, muts = argv[0], None, []
    rest = argv[1:]
    while rest:
        if rest[0] == "--skill":
            skill, rest = rest[1], rest[2:]
        else:
            muts.append(rest[0])
            rest = rest[1:]
    fx = base(proposed_deny(skill))
    for m in muts:
        name, _sep, arg = m.partition("=")
        fn = globals().get("fx_" + name.replace("-", "_"))
        if fn is None:
            sys.exit("merge_fx: no mutation %s" % name)
        fn(fx, arg)
    with open(out, "w") as f:
        json.dump(fx, f, indent=1)


if __name__ == "__main__":
    main(sys.argv[1:])
