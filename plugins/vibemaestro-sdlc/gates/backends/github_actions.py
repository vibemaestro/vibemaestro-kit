"""CI backend `github-actions`: the check runs and commit statuses of a commit, read through `gh api` (GET only).

runs(repo, sha) lists every run, superseded ones included (`filter=all`): the guard keeps the latest per check itself. Each item:
    {kind: "check" | "status", id, name, workflow, workflow_id, app, status, conclusion, started_at}
The workflow name and id come from the workflow runs of the same commit (check suite id to workflow); two workflow files may share
a name, never an id. A status in `error` reads as `failure`, a `pending` one has no conclusion. The number of check runs read must
equal `total_count`, or the read could not conclude.

failed_steps(repo, run): for a GitHub Actions check run (its id is the job id), the names of the steps
whose conclusion is not success, skipped or neutral; None when the job is not complete or the run is not an Actions job.
"""
from backends import api, api_list, api_pages
from gate_common import Infra

OK_STEPS = ("success", "skipped", "neutral")
STATUS_CONCLUSION = {"success": "success", "failure": "failure", "error": "failure", "pending": None}


def runs(repo, sha):
    suites = {}
    for page in api_pages("repos/%s/actions/runs?head_sha=%s&per_page=100" % (repo, sha)):
        for r in (page or {}).get("workflow_runs") or []:
            suites[r["check_suite_id"]] = (r.get("name") or "", r.get("workflow_id"))
    out, total = [], None
    for page in api_pages("repos/%s/commits/%s/check-runs?filter=all&per_page=100" % (repo, sha)):
        total = (page or {}).get("total_count", total)
        for c in (page or {}).get("check_runs") or []:
            wf = suites.get((c.get("check_suite") or {}).get("id"), ("", None))
            out.append({"kind": "check", "id": c.get("id"), "name": c.get("name") or "", "workflow": wf[0], "workflow_id": wf[1],
                        "app": (c.get("app") or {}).get("slug") or "", "status": c.get("status"),
                        "conclusion": c.get("conclusion"), "started_at": c.get("started_at")})
    total = len(out) if total is None else total
    if len(out) != total:
        raise Infra("read %d check runs of %s, GitHub counts %d" % (len(out), sha[:12], total))
    for s in api_list("repos/%s/commits/%s/statuses?per_page=100" % (repo, sha)):
        out.append({"kind": "status", "id": s.get("id"), "name": s.get("context") or "", "workflow": "", "app": "status",
                    "status": "in_progress" if s.get("state") == "pending" else "completed",
                    "conclusion": STATUS_CONCLUSION.get(s.get("state"), "failure"),
                    "started_at": s.get("created_at")})
    return out


def failed_steps(repo, run):
    if run.get("kind") != "check" or run.get("app") != "github-actions" or not run.get("id"):
        return None
    job = api("repos/%s/actions/jobs/%s" % (repo, run["id"]))
    if job.get("status") != "completed":
        return None
    return [s.get("name") or "" for s in job.get("steps") or [] if s.get("conclusion") not in OK_STEPS]
