#!/usr/bin/env python3
"""Judge the `concurrency` block of workflows per event: only a new commit on a PR cancels, nothing else cancels or replaces a run.

    concurrency_check.py <workflow.yml>...      one line per finding (`FAIL <file>: <why>`) and one `ok <file>` per clean file; rc 1
                                                on any finding
    concurrency_check.py --eval-if <workflow.yml> <scenario>
                                                `<job> true|false` per job: its `if` for one named event (SCENARIOS), so a suite
                                                can assert what a gate runs on

Drafts (no CI on a draft): in an in-scope workflow with a pull_request trigger, `ready_for_review` is in the types, and every job's
`if` is false for every event it can get on a draft of a private repository (the PR's `draft`, or the issue's for a comment) and
true for a new commit of a ready PR.

A workflow is IN SCOPE when it runs on a pull-request event (pull_request, pull_request_target, issue_comment, pull_request_review,
pull_request_review_comment). An in-scope workflow must have a workflow-level `concurrency` with:
  - `cancel-in-progress` true for a pull_request `synchronize` (a new commit) and false for every other event it can get;
  - one group for two runs of `synchronize` on one PR, another group for another PR, another for another workflow;
  - for every other event, a group of its own: two runs of the same event get two groups, and none is a commit group (a shared
    group would let the newer run replace a pending commit run, whatever cancel-in-progress says).
A workflow out of scope may have no block; if it has one, it must never cancel (a shared group that queues is its own choice). The values are computed with tests/fixtures/gh_expr.py
(an expression it cannot read is a finding: fail closed).
"""
import os
import re
import sys

import yaml

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gh_expr  # noqa: E402

PR_EVENTS = ("pull_request", "pull_request_target", "issue_comment", "pull_request_review", "pull_request_review_comment")
# (event name, action) per event a workflow can get; the PR-type actions are those of pull_request
PR_ACTIONS = ("opened", "synchronize", "reopened", "edited", "ready_for_review", "labeled", "unlabeled", "closed",
              "converted_to_draft", "review_requested", "assigned")


def triggers(doc):
    on = doc.get("on", doc.get(True))           # YAML 1.1 reads the bare key `on` as True
    if isinstance(on, str):
        return {on: {}}
    if isinstance(on, list):
        return {k: {} for k in on}
    return {k: (v or {}) for k, v in (on or {}).items()}


def events(trig):
    """[(label, github context minus workflow and run_id)] the workflow can be started by."""
    out = []
    for name, spec in trig.items():
        if name in ("pull_request", "pull_request_target"):
            types = spec.get("types") if isinstance(spec, dict) else None
            for a in (types or ("opened", "synchronize", "reopened")):
                out.append(("%s/%s" % (name, a), {"event_name": name, "ref": "refs/pull/7/merge",
                                                  "event": {"action": a, "pull_request": {"number": 7}}}))
        elif name == "issue_comment":
            for a in ((spec or {}).get("types") or ("created", "edited", "deleted")):
                out.append(("issue_comment/%s" % a, {"event_name": name, "ref": "refs/heads/main",
                                                     "event": {"action": a, "issue": {"number": 7, "pull_request": {}}}}))
        elif name in ("pull_request_review", "pull_request_review_comment"):
            dflt = ("submitted", "edited", "dismissed") if name == "pull_request_review" else ("created", "edited", "deleted")
            for a in ((spec or {}).get("types") or dflt):
                out.append(("%s/%s" % (name, a), {"event_name": name, "ref": "refs/pull/7/merge",
                                                  "event": {"action": a, "pull_request": {"number": 7}}}))
        elif name == "push":
            branches = (spec or {}).get("branches") or ["main"]
            for b in branches:
                b = b.replace("*", "x")
                out.append(("push/%s" % b, {"event_name": "push", "ref": "refs/heads/" + b, "event": {}}))
        else:
            out.append((name, {"event_name": name, "ref": "refs/heads/main", "event": {}}))
    return out


TOKEN = "COMMIT EXCEPTION:"         # the default exemption token, which the rendered templates carry
SCENARIOS = {
    # name: (event_name, action, pull_request fields or None, issue fields or None, changes, repository private)
    "edit-title": ("pull_request", "edited", {"body": "plain body"}, None, {"title": {"from": "old title"}}, True),
    "edit-title-token": ("pull_request", "edited", {"body": TOKEN + " a reason"}, None, {"title": {"from": "old"}}, True),
    "edit-body": ("pull_request", "edited", {"body": "new body"}, None, {"body": {"from": "old body"}}, True),
    "edit-body-token-before": ("pull_request", "edited", {"body": "new body"}, None, {"body": {"from": TOKEN + " a reason"}}, True),
    "edit-body-token-after": ("pull_request", "edited", {"body": TOKEN + " a reason"}, None, {"body": {"from": "old"}}, True),
    "edit-base": ("pull_request", "edited", {"body": "plain body"}, None, {"base": {"ref": {"from": "old-base"}}}, True),
    "draft-public": ("pull_request", "synchronize", {"draft": True}, None, None, False),
    "draft-private": ("pull_request", "synchronize", {"draft": True}, None, None, True),
    "ready": ("pull_request", "ready_for_review", {}, None, None, True),
    "comment-draft-private": ("issue_comment", "created", None, {"draft": True}, None, True),
    "comment-draft-public": ("issue_comment", "created", None, {"draft": True}, None, False),
    "comment-ready": ("issue_comment", "created", None, {"draft": False}, None, True),
    "comment-nodraft-private": ("issue_comment", "created", None, {"draft": None}, None, True),
    "comment-edited-ready": ("issue_comment", "edited", None, {"draft": False}, {"body": {"from": "x"}}, True),
}


def scenario(name):
    ev, action, pr, issue, changes, private = SCENARIOS[name]
    event = {"action": action, "repository": {"private": private}}
    if pr is not None:
        event["pull_request"] = dict({"number": 7, "draft": False, "body": "b"}, **pr)
    if issue is not None:
        event["issue"] = {k: v for k, v in dict({"number": 7, "pull_request": {}, "draft": False}, **issue).items() if v is not None}
    if changes is not None:
        event["changes"] = changes
    return {"event_name": ev, "ref": "refs/pull/7/merge", "event": event}


def job_if(job, gh):
    """The value of a job's `if` for one github context (no `if` runs the job); a bare expression or one in ${{ }}."""
    cond = job.get("if", True) if isinstance(job, dict) else True
    if isinstance(cond, bool):
        return cond
    text = str(cond).strip()
    val = gh_expr.evaluate(text, {"github": gh}) if "${{" in text else gh_expr.expression(text, {"github": gh})
    return gh_expr.truthy(val)


def _draft(ctx, private=True):
    """The same event on a draft PR of a repository (private by default)."""
    out = dict(ctx, event=dict(ctx["event"], repository={"private": private}))
    for k in ("pull_request", "issue"):
        if isinstance(out["event"].get(k), dict):
            out["event"][k] = dict(out["event"][k], draft=True)
    return out


def _conjuncts(text):
    """The top-level `&&` operands of an `if` (outside parentheses and quotes), stripped; ${{ }} removed. [] when a
    top-level `||` is in it: `&&` binds tighter, so no operand then holds for the whole expression. [] too for any text
    it cannot read as one expression (a `${{ }}` that is only part of it, which GitHub reads as a string, or unbalanced
    parentheses or quotes): fail closed."""
    text = text.strip()
    if text.startswith("${{") and text.endswith("}}"):
        text = text[3:-2]
    if "${{" in text or "}}" in text:
        return []
    out, cur, depth, i, q = [], "", 0, 0, False
    while i < len(text):
        c = text[i]
        if q:
            cur += c
            if c == "'":
                if text[i + 1:i + 2] == "'":
                    cur += "'"
                    i += 1
                else:
                    q = False
        elif c == "'":
            q, cur = True, cur + c
        elif c == "(":
            depth, cur = depth + 1, cur + c
        elif c == ")":
            depth, cur = depth - 1, cur + c
            if depth < 0:
                return []
        elif depth == 0 and text[i:i + 2] == "||":
            return []
        elif depth == 0 and text[i:i + 2] == "&&":
            out.append(cur.strip())
            cur, i = "", i + 1
        else:
            cur += c
        i += 1
    if q or depth:
        return []
    return out + [cur.strip()]


def _not_pr_job(job):
    """A job whose `if` requires, as a top-level `&&` operand, an event that is not pull_request or pull_request_target.
    Read from the text, not evaluated: a field the probe context lacks evaluates to null and cannot fake it (fail closed)."""
    cond = job.get("if") if isinstance(job, dict) else None
    if not isinstance(cond, str):
        return False
    for part in _conjuncts(cond):
        m = re.fullmatch(r"github\.event_name\s*==\s*'([a-z_]+)'", part)
        if m and m.group(1) not in ("pull_request", "pull_request_target"):
            return True
    return False


def drafts(doc, trig, name):
    """Findings of the draft rule for an in-scope workflow."""
    errs = []
    if "pull_request" in trig:
        types = (trig["pull_request"] or {}).get("types") if isinstance(trig["pull_request"], dict) else None
        if types is not None and "ready_for_review" not in types:
            errs.append("pull_request types lack ready_for_review: going ready would not start the round")
    on_commit = {}                                          # job -> runs on a new commit of a ready PR
    for jid, job in (doc.get("jobs") or {}).items():
        for label, ctx in events(trig):
            if ctx["event_name"] not in PR_EVENTS:          # a push to main or a dispatch has no draft
                continue
            ctx = dict(ctx, workflow=name, run_id=1)
            ctx["event"] = dict(ctx["event"], repository={"private": True})
            for k in ("pull_request", "issue"):
                if isinstance(ctx["event"].get(k), dict):
                    ctx["event"][k] = dict(ctx["event"][k], draft=False, body="b")
            if job_if(job, _draft(ctx)):
                errs.append("job %s runs on a draft (%s, private repository)" % (jid, label))
            if ctx["event_name"] in ("pull_request", "pull_request_target") and ctx["event"]["action"] == "synchronize":
                on_commit[jid] = on_commit.get(jid, False) or job_if(job, ctx)
    # every job checks a new commit of a ready PR, except one whose `if` names another event (a comment-only re-run)
    for jid in sorted(on_commit):
        if not on_commit[jid] and not _not_pr_job(doc["jobs"][jid]):
            errs.append("job %s does not run on a new commit of a ready PR" % jid)
    if on_commit and not any(on_commit.values()):
        errs.append("no job runs on a new commit of a ready PR (jobs: %s)" % ", ".join(sorted(on_commit)))
    return errs


def judge(path):
    errs = []
    try:
        # a template's install markers (@@NAME@@) are not YAML; any value stands in for them
        doc = yaml.safe_load(re.sub(r"@@([A-Z_]+)@@", r"marker-\1", open(path, encoding="utf-8").read()))
    except Exception as e:  # noqa: BLE001 - any parse failure is a finding
        return ["cannot read the YAML: %s" % e]
    if not isinstance(doc, dict):
        return ["not a workflow"]
    trig = triggers(doc)
    in_scope = any(t in PR_EVENTS for t in trig)
    conc = doc.get("concurrency")
    if in_scope:
        try:
            errs += drafts(doc, trig, doc.get("name") or os.path.basename(path))
        except ValueError as e:
            errs.append("cannot judge a job's if (%s)" % e)
    for jid, job in (doc.get("jobs") or {}).items():          # a job-level group cancels and queues on its own
        if isinstance(job, dict) and "concurrency" in job:
            errs.append("job %s has a concurrency block of its own (the workflow-level block is the one rule)" % jid)
    if conc is None:
        return errs + (["runs on a PR event and has no workflow-level concurrency block"] if in_scope else [])
    if isinstance(conc, str):
        conc = {"group": conc}
    if not isinstance(conc, dict) or "group" not in conc:
        return ["concurrency has no group"]
    name = doc.get("name") or os.path.basename(path)

    def run(ctx, run_id, workflow=name, number=None):
        c = {"github": dict(ctx, workflow=workflow, run_id=run_id)}
        if number is not None:
            c = {"github": dict(c["github"], event=_renumber(ctx["event"], number))}
        try:
            return (gh_expr.evaluate(conc["group"], c), gh_expr.truthy(gh_expr.evaluate(conc.get("cancel-in-progress", False), c)))
        except ValueError as e:
            raise ValueError("cannot judge the expression (%s)" % e)

    try:
        evs = events(trig)
        commit = None
        for label, ctx in evs:
            g1, c1 = run(ctx, 101)
            g2, _c2 = run(ctx, 102)
            is_commit = ctx["event_name"] in ("pull_request", "pull_request_target") and ctx["event"]["action"] == "synchronize"
            if is_commit:
                commit = g1
                if not c1:
                    errs.append("%s: a new commit does not cancel the run of the head it replaces" % label)
                if g1 != g2:
                    errs.append("%s: two commits of one PR land in two groups (%r, %r), so the older run is never cancelled" % (label, g1, g2))
                if run(ctx, 101, number=8)[0] == g1:
                    errs.append("%s: two PRs share the group %r" % (label, g1))
                if run(ctx, 101, workflow=name + "-other")[0] == g1:
                    errs.append("%s: the group %r does not name the workflow" % (label, g1))
            else:
                if c1:
                    errs.append("%s: cancels a run in progress (only a new commit may)" % label)
                if in_scope and g1 == g2:
                    errs.append("%s: two runs share the group %r, so the newer replaces the pending one" % (label, g1))
        if commit is not None:
            for label, ctx in evs:
                if not (ctx["event_name"] in ("pull_request", "pull_request_target") and ctx["event"]["action"] == "synchronize") \
                        and run(ctx, 101)[0] == commit:
                    errs.append("%s: lands in the commit group %r" % (label, commit))
        elif in_scope and any(t in ("pull_request", "pull_request_target") for t in trig):
            pass                                   # a PR workflow without synchronize: nothing to cancel, nothing to check
    except ValueError as e:
        errs.append(str(e))
    return errs


def _renumber(event, n):
    ev = dict(event)
    for k in ("pull_request", "issue"):
        if isinstance(ev.get(k), dict):
            ev[k] = dict(ev[k], number=n)
    return ev


def load(path):
    return yaml.safe_load(re.sub(r"@@([A-Z_]+)@@", r"marker-\1", open(path, encoding="utf-8").read()))


def main(argv):
    if argv[:1] == ["--eval-if"] and len(argv) == 3:
        doc = load(argv[1])
        for jid, job in (doc.get("jobs") or {}).items():
            gh = dict(scenario(argv[2]), workflow=doc.get("name") or "w", run_id=1)
            sys.stdout.write("%s %s\n" % (jid, "true" if job_if(job, gh) else "false"))
        return 0
    bad = 0
    for p in argv:
        errs = judge(p)
        for e in errs:
            sys.stdout.write("FAIL %s: %s\n" % (p, e))
        if not errs:
            sys.stdout.write("ok %s\n" % p)
        bad += bool(errs)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
