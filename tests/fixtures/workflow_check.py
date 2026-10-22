#!/usr/bin/env python3
"""Check one rendered gate workflow: its structure, then its `run:` step executed against scratch repos and the fake gh.

    workflow_check.py build <work dir> <plugin dir>                       build the scratch repos and fixtures once
    workflow_check.py check <work dir> <plugin dir> <kind> <workflow.yml>  print one `FAIL ...` line per problem; rc 1 when there is any

kind: commit-discipline | pr-title | pr-body | pr-sensitive | dead-branches.

The structure is read with a YAML parser, not grep: a mutation that moves a line to another key must be seen. Structure problems stop the
check before anything runs (the run would only repeat them). The run is the step's own shell block, executed with the shell Actions uses
(`bash --noprofile --norc -eo pipefail`), a fake `gh`, and a checkout that looks like what the runner has: the BASE branch of the repo.
A template that is not safe, or does not conclude, or lets a PR relax its own gate, is red here; each such fault is planted by
tests/test-gates-workflows.sh and must turn this red.
"""
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys

try:
    import yaml
except ImportError:
    print("FAIL PyYAML is missing: the workflow cannot be read")
    sys.exit(1)

HERE = os.path.dirname(os.path.abspath(__file__))
RUNNER_VAR, RUNNER_DEFAULT = "CI_RUNNER", "ubuntu-latest"
PR_TYPES = {"opened", "edited", "synchronize", "reopened", "ready_for_review"}
SPEC = {
    "commit-discipline": {"events": {"pull_request": PR_TYPES}, "ref": "github.event.pull_request.base.ref", "depth0": True,
                          "script": "commit_discipline.py", "if": {"github.event.pull_request.draft == false && (github.event.action != 'edited' || github.event.changes.base || github.event.changes.body && (contains(github.event.changes.body.from, 'COMMIT EXCEPTION:') || contains(github.event.pull_request.body, 'COMMIT EXCEPTION:')))"}, "config_ref": True},
    "pr-title": {"events": {"pull_request": PR_TYPES}, "ref": "github.event.pull_request.base.ref", "depth0": False,
                 "script": "pr_title.py", "if": {"github.event.pull_request.draft == false && (github.event.action != 'edited' || github.event.changes.title || github.event.changes.base)"}, "config_ref": True},
    "pr-body": {"events": {"pull_request": PR_TYPES}, "ref": "github.event.pull_request.base.ref", "depth0": False,
                "script": "pr_body.py", "if": {"github.event.pull_request.draft == false && (github.event.action != 'edited' || github.event.changes.body || github.event.changes.base)"}, "config_ref": True},
    "pr-sensitive": {"events": {"pull_request": PR_TYPES, "issue_comment": {"created", "edited"}, "pull_request_review": {"submitted", "edited"},
                                "pull_request_review_comment": {"created", "edited"}},
                     "ref": "github.event.repository.default_branch", "depth0": False, "script": "pr_sensitive.py",
                     "if": {"(github.event_name != 'issue_comment' || github.event.issue.pull_request) && (github.event.repository.private == false || (github.event_name == 'issue_comment' && toJSON(github.event.issue.draft) == 'false') || (github.event_name != 'issue_comment' && github.event.pull_request.draft == false)) && (github.event_name != 'pull_request' || github.event.action != 'edited' || github.event.changes.body || github.event.changes.base)"}, "config_ref": False},
    "dead-branches": {"events": {"schedule": None, "workflow_dispatch": None}, "ref": None, "depth0": True, "script": "dead_branches.sh",
                      "if": {None}, "config_ref": False},
}
EXPR_OK = {"secrets.GITHUB_TOKEN", "github.event.pull_request.number", "github.event.pull_request.base.ref", "github.repository",
           "github.event.pull_request.number || github.event.issue.number"}
IDENT = {"name": "t", "email": "t@t"}


def sh(args, cwd, env=None):
    e = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
    e.update(env or {})
    p = subprocess.run(args, cwd=cwd, env=e, capture_output=True, text=True)
    if p.returncode != 0:
        raise RuntimeError("%s failed: %s" % (" ".join(args[:4]), p.stderr[:300]))
    return p.stdout


def git(cwd, *a):
    return sh(["git", "-c", "commit.gpgsign=false"] + list(a), cwd)


def sha256(v):
    return hashlib.sha256(v.encode()).hexdigest()


# ── building the scratch repos ───────────────────────────────────────────────────────────────────
def mk_origin(work, name, plugin, gates=True, cfg=None):
    d = os.path.join(work, name)
    os.makedirs(d)
    bare, w = os.path.join(d, "origin.git"), os.path.join(d, "w")
    git(d, "init", "-q", "--bare", "-b", "main", bare)
    git(d, "clone", "-q", bare, w)
    with open(os.path.join(w, "seed.txt"), "w") as f:
        f.write("seed\n")
    if cfg is not None:
        os.makedirs(os.path.join(w, ".vibemaestro"))
        with open(os.path.join(w, ".vibemaestro", "sdlc.json"), "w") as f:
            f.write(json.dumps(cfg))
    if gates:
        sh([sys.executable, os.path.join(plugin, "scripts", "install_gates.py"), "--root", w], w)
    git(w, "add", "-A")
    git(w, "commit", "-q", "-m", "seed")
    git(w, "branch", "-M", "main")
    git(w, "push", "-q", "-u", "origin", "main")
    return w


def commits(w, n, prefix="f"):
    for i in range(1, n + 1):
        p = os.path.join(w, "%s%d.txt" % (prefix, i))
        with open(p, "w") as f:
            f.write("x\n")
        git(w, "add", p)
        git(w, "commit", "-q", "-m", "feat: task %d" % i)


def publish_pr(w, n=1):
    """Push the current branch as refs/pull/<n>/head, then put the checkout back on main (what the runner has)."""
    git(w, "push", "-q", "origin", "HEAD:refs/pull/%d/head" % n)
    git(w, "checkout", "-q", "main")


def build(work, plugin):
    fx = {}
    def put(name, obj):
        p = os.path.join(work, "fx-%s.json" % name)
        json.dump(obj, open(p, "w"))
        fx[name] = p
    # commit discipline
    w = mk_origin(work, "c_red", plugin); git(w, "checkout", "-q", "-b", "pr"); commits(w, 16); publish_pr(w)
    put("c_red", {"pr view": {"body": ""}})
    put("c_exempt", {"pr view": {"body": "## Summary\nx\nCOMMIT EXCEPTION: rename the API then move callers then drop the old path\n"}})
    put("c_fail", {"__fail__": True})
    w = mk_origin(work, "c_green", plugin); git(w, "checkout", "-q", "-b", "pr"); commits(w, 1); publish_pr(w)
    w = mk_origin(work, "c_tamper", plugin, cfg={"commits": {"max_per_pr": 3}})
    git(w, "checkout", "-q", "-b", "pr"); commits(w, 4)
    with open(os.path.join(w, ".vibemaestro", "sdlc.json"), "w") as f:
        f.write(json.dumps({"commits": {"max_per_pr": 50}}))
    git(w, "commit", "-qam", "feat: relax the limit")
    with open(os.path.join(w, ".vibemaestro", "gates", "commit_discipline.py"), "w") as f:
        f.write("import sys\nsys.exit(0)\n")
    git(w, "commit", "-qam", "feat: neutralise the gate"); publish_pr(w)
    w = mk_origin(work, "c_nogates", plugin, gates=False); git(w, "checkout", "-q", "-b", "pr"); commits(w, 16); publish_pr(w)
    # title
    mk_origin(work, "t", plugin, cfg={"pr": {"title": {"intent_form": "reject", "max_len": 30}}})
    mk_origin(work, "t_nogates", plugin, gates=False)
    put("t_red", {"pr view": {"title": "docs(kb): intent x", "isDraft": False, "headRefName": "feat/x"}, "pulls/5/files": ["kb/a.md", "src/b.yaml"], "__require_paginate__": True, "__require_repo__": "acme/service"})
    put("t_green", {"pr view": {"title": "fix(api): x", "isDraft": False, "headRefName": "feat/x"}, "pulls/5/files": ["src/b.yaml"], "__require_paginate__": True, "__require_repo__": "acme/service"})
    put("t_long", {"pr view": {"title": "fix(api): a title that is longer than thirty", "isDraft": False, "headRefName": "feat/x"}, "pulls/5/files": ["src/b.yaml"]})
    # body: the base config sets a 100-character cap; the body is read through gh, never from the event
    mk_origin(work, "b", plugin, cfg={"pr": {"body": {"max_chars": 100}}})
    mk_origin(work, "b_nogates", plugin, gates=False)
    put("b_long", {"pr view": {"body": "x" * 101}, "__require_repo__": "acme/service"})
    put("b_ok", {"pr view": {"body": "x" * 100}, "__require_repo__": "acme/service"})
    # sensitive: the checkout is the default branch; its own allowlist exempts IP_HEAD, the base (by the API) exempts IP_OK
    ip = lambda *x: ".".join(x)
    ip1, ip2, ip3, ip_ok, ip_head = ip("103", "97", "12", "44"), ip("45", "117", "80", "9"), ip("1", "54", "200", "7"), ip("62", "210", "1", "8"), ip("77", "88", "9", "10")
    mail, phone = "jane.doe" + "@" + "gmail.com", "0" + "912345678"
    sha, base = "c0ffee" + "ab" * 17, "ba5e" + "cd" * 18
    w = mk_origin(work, "s", plugin)
    with open(os.path.join(w, ".pr-sensitive-allow"), "w") as f:
        f.write("%s  # head exempts itself\n" % sha256(ip_head))
    mk_origin(work, "s_nogates", plugin, gates=False)
    def sens(mode):
        dirty = {"body": "node " + ip1, "comment": "contact " + mail, "review-comment": "edge " + ip2, "review": "call " + phone, "commit": "fix: ufw allow from " + ip3}
        t = dirty if mode == "dirty" else {k: "ok" for k in dirty}
        if mode == "allow":
            t = dict(t, body="node %s and %s" % (ip_ok, ip_head))
        ok = lambda i: {"id": i, "body": "ok"}
        commits_ = [{"sha": "0" * 40, "commit": {"message": "chore: ok"}}, {"sha": sha, "commit": {"message": t["commit"]}}]
        if mode == "trunc":
            commits_ = [{"sha": "%040x" % i, "commit": {"message": "chore: ok"}} for i in range(250)]
        return {"pulls/7": {"number": 7, "body": t["body"], "base": {"sha": base}},
                "contents/.vibemaestro/sdlc.json?ref=" + base: '{"sensitive": {"allowlist": "ops/allow.txt"}}',
                "contents/ops/allow.txt?ref=" + base: "# base\n%s  # test case\n" % sha256(ip_ok),
                "issues/7/comments": [ok(21), {"id": 11, "body": t["comment"]}], "pulls/7/comments": [ok(22), {"id": 12, "body": t["review-comment"]}],
                "pulls/7/reviews": [ok(23), {"id": 13, "body": t["review"]}], "pulls/7/commits": commits_, "__require_paginate__": True, "__require_repo__": "acme/service"}
    for m in ("dirty", "clean", "allow", "trunc"):
        put("s_" + m, sens(m))
    json.dump({"values": [ip1, ip2, ip3, mail, phone], "ip_ok": ip_ok, "ip_head": ip_head, "sha": sha}, open(os.path.join(work, "sens.json"), "w"))
    # dead branches
    w = mk_origin(work, "d_red", plugin); git(w, "checkout", "-q", "-b", "old"); commits(w, 1); git(w, "checkout", "-q", "main"); git(w, "merge", "-q", "--ff-only", "old")
    git(w, "push", "-q", "origin", "main", "old"); git(w, "fetch", "-q", "origin")
    mk_origin(work, "d_clean", plugin)
    w = mk_origin(work, "d_nogates", plugin, gates=False); git(w, "checkout", "-q", "-b", "old"); commits(w, 1); git(w, "checkout", "-q", "main"); git(w, "merge", "-q", "--ff-only", "old")
    git(w, "push", "-q", "origin", "main", "old"); git(w, "fetch", "-q", "origin")
    json.dump(fx, open(os.path.join(work, "fx.json"), "w"))
    bindir = os.path.join(work, "bin")
    os.makedirs(bindir)
    shim = os.path.join(bindir, "gh")
    with open(shim, "w") as f:
        f.write('#!/bin/sh\nexec python3 "%s/gate_gh.py" "$@"\n' % HERE)
    os.chmod(shim, os.stat(shim).st_mode | stat.S_IEXEC)


_RUNS = 0


# ── running a step ───────────────────────────────────────────────────────────────────────────────
def run_step(script, work, scenario, env, fx=None, gha=False):
    cwd = os.path.join(work, scenario, "w")
    subprocess.run(["git", "update-ref", "-d", "refs/remotes/origin/pr-head"], cwd=cwd, capture_output=True)   # no state from an earlier run
    global _RUNS
    _RUNS += 1
    tmp = os.path.join(work, "rt-%d-%s" % (_RUNS, scenario))
    os.makedirs(tmp, exist_ok=True)
    log = os.path.join(tmp, "gh.log")
    open(log, "w").close()
    path = os.path.join(tmp, "step.sh")
    open(path, "w").write(script)
    e = dict(os.environ, PATH=os.path.join(work, "bin") + os.pathsep + os.environ["PATH"], RUNNER_TEMP=tmp, GH_TOKEN="t", FAKE_GH_LOG=log, **env)
    if fx:
        e["FAKE_GH_FX"] = json.load(open(os.path.join(work, "fx.json")))[fx]
    e.pop("GITHUB_ACTIONS", None)
    if gha:
        e["GITHUB_ACTIONS"] = "true"
    p = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", path], cwd=cwd, env=e, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr, open(log).read()


def code_only(s):
    return "\n".join(re.sub(r"(^|\s)#.*$", "", l) for l in s.splitlines())


def structure(wf, kind, text):
    sp, errs = SPEC[kind], []
    if "@@" in text:
        errs.append("a template marker (@@...@@) is left in the rendered workflow")
    if re.search(r"cancel-in-progress:\s*true", text):
        errs.append("cancel-in-progress: true: a later event would cancel the run that is attached to the PR's checks")
    if "continue-on-error" in text:
        errs.append("continue-on-error swallows a red gate")
    d = yaml.safe_load(text) or {}
    on = d.get("on", d.get(True)) or {}
    for ev, types in sp["events"].items():
        if ev not in on:
            errs.append("missing trigger %s" % ev)
        elif types is not None:
            got = set(((on[ev] or {}).get("types")) or [])
            if types - got:
                errs.append("trigger %s lacks types %s" % (ev, sorted(types - got)))
    extra = set(on) - set(sp["events"])
    if extra:
        errs.append("unexpected trigger %s" % sorted(extra))
    perms = d.get("permissions")
    if not isinstance(perms, dict) or any(v != "read" for v in perms.values()) or "contents" not in perms:
        errs.append("permissions must be a mapping of read-only scopes that includes contents")
    jobs = [j or {} for j in (d.get("jobs") or {}).values()]
    if len(jobs) != 1:
        return errs + ["expected exactly one job, found %d" % len(jobs)]
    job = jobs[0]
    if job.get("runs-on") != "${{ vars.CI_GATE_RUNNER || vars.%s || '%s' }}" % (RUNNER_VAR, RUNNER_DEFAULT):
        errs.append("runs-on is %r, not the runner variable with its fallback" % job.get("runs-on"))
    cond = job.get("if")
    cond = None if cond is None else " ".join(str(cond).split())
    if cond not in sp["if"]:
        errs.append("job `if:` %r is not the approved condition: the gate may not run" % cond)
    steps = job.get("steps") or []
    for s in steps:
        u = s.get("uses")
        if u is None:
            continue
        if not (re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}", u) or u.startswith("./")):
            errs.append("`uses: %s` is neither local nor pinned by a full commit SHA" % u)
        elif not u.startswith("actions/checkout@") and not u.startswith("./"):
            errs.append("`uses: %s`: only actions/checkout is allowed in a gate template" % u)
    co = [s for s in steps if str(s.get("uses", "")).startswith("actions/checkout@")]
    run = [s for s in steps if sp["script"] in str(s.get("run", ""))]
    if len(co) != 1 or len(run) != 1:
        return errs + ["need exactly one checkout and one step that runs %s" % sp["script"]]
    w = co[0].get("with") or {}
    ref = w.get("ref")
    ref_expr = None if ref is None else re.sub(r"^\$\{\{\s*|\s*\}\}$", "", str(ref))
    if ref_expr != sp["ref"]:
        errs.append("checkout ref is %r, wanted %r: the gate must run the scripts and the config of the BASE, never the PR head" % (ref, sp["ref"]))
    extra_keys = set(w) - {"ref", "fetch-depth"}
    if extra_keys:
        errs.append("checkout takes unexpected options %s (for example `repository:` would check out another repo)" % sorted(extra_keys))
    if sp["depth0"] and w.get("fetch-depth") != 0:
        errs.append("checkout must have fetch-depth: 0 (a shallow clone has no merge base or no remote branches)")
    st = run[0]
    body = str(st["run"])
    code = code_only(body)
    for e in re.findall(r"\$\{\{(.*?)\}\}", code):
        errs.append("`run` interpolates ${{%s}}: data must go through env" % e)
    for k, v in (st.get("env") or {}).items():
        for e in re.findall(r"\$\{\{(.*?)\}\}", str(v)):
            if e.strip() not in EXPR_OK:
                errs.append("env %s takes `${{%s}}`: not on the approved list" % (k, e))
    if "GITHUB_EVENT_PATH" in code:
        errs.append("`run` reads $GITHUB_EVENT_PATH: the payload is a stale snapshot")
    if re.search(r"\bset\s+(-\w*x|-o\s+xtrace)|\bbash\s+-\w*x", code):
        errs.append("xtrace is on: the log would print commands with their values")
    if re.search(r"\|\|\s*true\b", code):
        errs.append("`|| true` swallows the gate's exit code")
    if sp["config_ref"] and "--config-ref" not in code:
        errs.append("the gate is run without --config-ref (the config of the base)")
    if "set -euo pipefail" not in code:
        errs.append("the step does not start with set -euo pipefail")
    return errs


def scenarios(work, plugin, kind, step):
    errs, body = [], str(step["run"])
    def fail(m):
        errs.append(m)
    def need(cond, m):
        if not cond:
            fail(m)
    if kind == "commit-discipline":
        env = {"PR_NUMBER": "1", "BASE_REF": "main"}
        rc, out, log = run_step(body, work, "c_red", env, "c_red")
        need(rc != 0 and "16 non-merge commits" in out, "a PR of 16 commits: the step must be red, rc %d: %s" % (rc, out[-200:]))
        rc, out, _ = run_step(body, work, "c_green", env, "c_red")
        need(rc == 0, "a PR of 1 commit: the step must be green, rc %d: %s" % (rc, out[-200:]))
        rc, out, log = run_step(body, work, "c_red", env, "c_exempt")
        need(rc == 0 and "pr view" in log, "an exemption line in the body (read through gh): the step must be green and must have asked gh, rc %d" % rc)
        rc, out, _ = run_step(body, work, "c_green", env, "c_fail")
        need(rc != 0, "gh failing: the step must not be green (a count on an empty body is not the PR's answer)")
        rc, out, _ = run_step(body, work, "c_tamper", env, "c_red")
        need(rc != 0 and "(limit 3)" in out, "a PR that relaxes its own limit and neutralises its own gate: judged by the base it must be red, rc %d: %s" % (rc, out[-200:]))
        rc, out, _ = run_step(body, work, "c_nogates", env, "c_red")
        need(rc == 0 and "::warning::" in out, "no gates on the base branch: pass with a ::warning::, rc %d" % rc)
    elif kind == "pr-title":
        env = {"PR_NUMBER": "5", "REPO": "acme/service", "BASE_REF": "main"}
        rc, out, _ = run_step(body, work, "t", env, "t_red")
        need(rc != 0 and "INTENT-FILE" in out, "an intent-form title on a ready PR with code: red, rc %d: %s" % (rc, out[-200:]))
        rc, out, _ = run_step(body, work, "t", env, "t_green")
        need(rc == 0, "a proper title: green, rc %d: %s" % (rc, out[-200:]))
        rc, out, _ = run_step(body, work, "t", env, "t_long")
        need(rc != 0 and "max_len" in out, "a title over the base's pr.title.max_len: red (the config is read at the base), rc %d: %s" % (rc, out[-200:]))
        rc, out, _ = run_step(body, work, "t", env, "c_fail")
        need(rc != 0, "gh failing: the step must not be green")
        rc, out, _ = run_step(body, work, "t_nogates", env, "t_green")
        need(rc == 0 and "::warning::" in out, "no gates on the base branch: pass with a ::warning::, rc %d" % rc)
    elif kind == "pr-body":
        env = {"PR_NUMBER": "5", "REPO": "acme/service", "BASE_REF": "main"}
        rc, out, log = run_step(body, work, "b", env, "b_long")
        need(rc != 0 and "pr.body.max_chars (100)" in out, "a body over the base's pr.body.max_chars: red (the config is read at the base), rc %d: %s" % (rc, out[-200:]))
        need("pr view" in log, "the body must be read through gh")
        rc, out, _ = run_step(body, work, "b", env, "b_ok")
        need(rc == 0, "a body at the limit: green, rc %d: %s" % (rc, out[-200:]))
        rc, out, _ = run_step(body, work, "b", env, "c_fail")
        need(rc != 0, "gh failing: the step must not be green")
        rc, out, _ = run_step(body, work, "b_nogates", env, "b_ok")
        need(rc == 0 and "::warning::" in out, "no gates on the base branch: pass with a ::warning::, rc %d" % rc)
    elif kind == "pr-sensitive":
        meta = json.load(open(os.path.join(work, "sens.json")))
        env = {"REPO": "acme/service", "PR": "7", "GITHUB_EVENT_PATH": os.path.join(work, "no-event.json")}
        json.dump({"pull_request": {"number": 7, "body": "clean"}}, open(env["GITHUB_EVENT_PATH"], "w"))   # a stale payload with a clean body
        for gha in (False, True):
            tag = " (GITHUB_ACTIONS=true)" if gha else ""
            rc, out, log = run_step(body, work, "s", env, "s_dirty", gha=gha)
            need(rc != 0, "a dirty PR: the step must be red%s (is the failure swallowed?)" % tag)
            for v in meta["values"]:
                need(v not in out, "the log leaks a whole value %s...%s" % (v[:4], tag))
            for where in ("body", "comment 11", "review-comment 12", "review 13", "commit " + meta["sha"][:8]):
                need("RED  PR #7 %s:" % where in out, "no RED line for the source '%s'%s" % (where, tag))
            called = {x for l in log.splitlines() for x in l.split() if x.startswith("repos/")}
            for ep in ("pulls/7", "issues/7/comments", "pulls/7/comments", "pulls/7/reviews", "pulls/7/commits"):
                need("repos/acme/service/" + ep in called, "the API was not called for %s%s" % (ep, tag))
        rc, out, _ = run_step(body, work, "s", env, "s_clean")
        need(rc == 0, "a clean PR: green, rc %d: %s" % (rc, out[-200:]))
        rc, out, _ = run_step(body, work, "s", env, "s_allow", gha=True)
        ok_mask, head_mask = "%s...[%d]" % (meta["ip_ok"][:4], len(meta["ip_ok"])), "%s...[%d]" % (meta["ip_head"][:4], len(meta["ip_head"]))
        need("RED  PR #7 body: public-ipv4 " + ok_mask not in out, "a value exempt at the BASE (read through the API) is still red")
        need(rc != 0 and "RED  PR #7 body: public-ipv4 " + head_mask in out, "a value that only the checkout's allowlist (the PR head) exempts must stay red, rc %d" % rc)
        need(meta["ip_ok"] not in out and meta["ip_head"] not in out, "the log leaks a whole value in the allowlist case")
        rc, out, _ = run_step(body, work, "s", env, "s_trunc")
        need(rc == 0 and "at most 250 commits" in out, "250 commits: a warning about the unscanned part and rc 0, rc %d" % rc)
        rc, out, _ = run_step(body, work, "s", env, "c_fail")
        need(rc != 0, "gh failing: the step must not be green")
        rc, out, _ = run_step(body, work, "s_nogates", env, "s_clean")
        need(rc == 0 and "::warning::" in out, "no gates on the default branch: pass with a ::warning::, rc %d" % rc)
    elif kind == "dead-branches":
        rc, out, _ = run_step(body, work, "d_red", {})
        need(rc != 0 and "origin/old" in out, "a merged branch on the remote: red, rc %d: %s" % (rc, out[-200:]))
        rc, out, _ = run_step(body, work, "d_clean", {})
        need(rc == 0, "no dead branch: green, rc %d: %s" % (rc, out[-200:]))
        rc, out, _ = run_step(body, work, "d_nogates", {})
        need(rc == 0 and "::warning::" in out, "no gates on this branch: pass with a ::warning::, rc %d" % rc)
    return errs


def check(work, plugin, kind, wf):
    text = open(wf, encoding="utf-8").read()
    errs = structure(wf, kind, text)
    if errs:
        return errs
    d = yaml.safe_load(text)
    step = [s for j in d["jobs"].values() for s in j["steps"] if SPEC[kind]["script"] in str(s.get("run", ""))][0]
    return scenarios(work, plugin, kind, step)


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "build":
        build(sys.argv[2], sys.argv[3])
    elif cmd == "check":
        errs = check(sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])
        for e in errs:
            print("  FAIL " + e)
        sys.exit(1 if errs else 0)
    else:
        sys.exit(64)
