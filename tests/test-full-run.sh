#!/bin/bash
# =============================================================================
# The scheduled full run: .github/workflows/test-full.yml and its issue step, tests/full-run-issue.py
# =============================================================================
# Run: bash tests/test-full-run.sh
#
#   1. the workflow's shape: cron `0 19 * * 0,3` plus workflow_dispatch and nothing else; permissions exactly contents: read and
#      issues: write; the CI_RUNNER runner; the full `bash tests/run-all.sh` (no --changed, no filter) with PLUGIN_REQUIRE_CLAUDE=1
#      and its own timeout; the issue step runs unless cancelled and is the only place the token appears; no other secret;
#      the optional export_rev input: the `full` job runs only when it is empty, the `export` job only when it is given
#      (ubuntu-latest, contents: read, no token, no secret, no issue, its own concurrency group, the suite run inside the export),
#      and the 40-hex check's own shell block is run against good and hostile values;
#   2. the issue step against a fake `gh` that keeps issues and labels in a JSON file: a failing run opens ONE issue (creating the
#      label when missing), a second failing run comments on it, a green run closes it, a green run with no issue writes nothing,
#      a skipped test step counts as red, a run on another ref writes nothing, an empty default branch is asked of the API, and a
#      `gh` failure makes the step red.
# No network: the fake `gh` is first on PATH.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
export PYTHONDONTWRITEBYTECODE=1
WF="$SRC_ROOT/.github/workflows/test-full.yml"
STEP="$HERE/full-run-issue.py"

echo "== the workflow's shape =="
O=$(python3 - "$WF" "$TMP/check-rev.sh" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
on = d.get("on", d.get(True))
print("triggers=%s" % sorted(on.keys()))
print("cron=%s" % [c.get("cron") for c in on["schedule"]])
print("perms=%s" % sorted(d.get("permissions", {}).items()))
jobs = d["jobs"]
print("jobs=%s" % sorted(jobs))
j = jobs["full"]
print("jobperms=%s" % j.get("permissions"))
print("runs-on=%s" % j["runs-on"])
steps = j["steps"]
issue_steps = [s for s in steps if "full-run-issue.py" in str(s.get("run", ""))]
full = [s for s in steps if "run-all.sh" in str(s.get("run", ""))]
print("fullsteps=%d" % len(full))
if full:
    f = full[0]
    print("fullrun=%s" % [l.strip() for l in f["run"].splitlines() if "run-all.sh" in l])
    print("fullenv=%s" % f.get("env"))
    print("fulltimeout=%s" % f.get("timeout-minutes"))
    print("fullid=%s" % f.get("id"))
    print("fullsoft=%s/%s" % (f.get("continue-on-error"), f.get("if")))
print("jobsoft=%s/%s" % (j.get("continue-on-error"), j.get("if")))
print("untimed=%s" % [s.get("name") or s.get("uses") for s in steps[:steps.index(issue_steps[0])] if "timeout-minutes" not in s] if issue_steps else "no issue step")
issue = issue_steps
print("issuesteps=%d" % len(issue))
if issue:
    print("issueif=%s" % issue[0].get("if"))
    print("issueoutcome=%s" % issue[0].get("env", {}).get("OUTCOME"))
token = [i for i, s in enumerate(steps) if "github.token" in str(s) or "GITHUB_TOKEN" in str(s)]
print("tokensteps=%s" % ["issue" if steps[i] in issue else "other" for i in token])
print("concurrency=%s" % d.get("concurrency"))
print("dispatch=%s" % on["workflow_dispatch"])
x = jobs["export"]
print("xif=%s" % x.get("if"))
print("xruns-on=%s" % x["runs-on"])
print("xperms=%s" % x.get("permissions"))
print("xconc=%s" % x.get("concurrency"))
print("xsoft=%s" % x.get("continue-on-error"))
xs = x["steps"]
print("xuntimed=%s" % [s.get("name") or s.get("uses") for s in xs if "timeout-minutes" not in s])
print("xcheckout=%s" % [s["with"] for s in xs if str(s.get("uses", "")).startswith("actions/checkout@")])
print("xcheck_first=%s" % (xs[0].get("name", "").startswith("Check export_rev")))
print("xexport=%s" % [s["run"].strip() for s in xs if "export-public.sh" in str(s.get("run", ""))])
xfull = [s for s in xs if "run-all.sh" in str(s.get("run", ""))]
print("xfull=%s|%s|%s|%s" % ([s["run"].strip() for s in xfull], [s.get("env") for s in xfull], [s.get("working-directory") for s in xfull], [s.get("timeout-minutes") for s in xfull]))
xgit = [(i, s["run"].split()) for i, s in enumerate(xs) if "git init" in str(s.get("run", ""))]
print("xgit=%s|%s" % ([i for i, _ in xgit], [xs[i].get("working-directory") for i, _ in xgit]))
print("xorder=%s" % [i for i, s in enumerate(xs) if "export-public.sh" in str(s.get("run", "")) or "git init" in str(s.get("run", "")) or "run-all.sh" in str(s.get("run", ""))])
print("xjobtimeout=%s" % x.get("timeout-minutes"))
print("xgitcmds=%s" % [l.strip() for s in xs if "git init" in str(s.get("run", "")) for l in s["run"].splitlines() if l.strip().startswith(("git init", "git add", "git -c"))])
import re
expr = re.compile(r"\$\{\{[^}]*(inputs|export_rev)")   # any form: inputs.x, inputs['x'], github.event.inputs.x
print("xrun_inputs=%s" % [s.get("name") for s in xs if expr.search(str(s.get("run", "")))])
print("xguards=%s" % [s.get("name") for s in xs if "if" in s or "continue-on-error" in s])
print("xenv_inputs=%s" % [(s.get("name"), s["env"]) for s in xs if "inputs." in str(s.get("env", ""))])
print("fullrun_inputs=%s" % [s.get("name") for s in steps if expr.search(str(s.get("run", "")))])
open(sys.argv[2], "w").write([s for s in xs if s.get("name", "").startswith("Check export_rev")][0]["run"])
co = [s for s in steps if str(s.get("uses", "")).startswith("actions/checkout@")]
print("creds=%s" % (co[0].get("with", {}).get("persist-credentials") if co else None))
PY
)
has "$O" "triggers=['schedule', 'workflow_dispatch']" "triggers: schedule and workflow_dispatch only (no pull_request, no pull_request_target)"
has "$O" "cron=['0 19 * * 0,3']" "cron 0 19 * * 0,3 (Monday and Thursday 02:00 +07)"
has "$O" "perms=[('contents', 'read'), ('issues', 'write')]" "permissions: exactly contents: read and issues: write"
has "$O" "jobs=['export', 'full']" "two jobs: full (as before) and export"
has "$O" "jobperms=None" "the job does not widen permissions"
has "$O" "runs-on=\${{ vars.CI_RUNNER || 'ubuntu-latest' }}" "runner: vars.CI_RUNNER, falling back to ubuntu-latest"
has "$O" "fullsteps=1" "one step runs run-all.sh"
has "$O" "fullrun=['bash tests/run-all.sh 2>&1 | tee \"\$RUNNER_TEMP/full.log\"']" "it runs the FULL suite: bash tests/run-all.sh, no --changed, no filter word"
has "$O" "fullenv={'PLUGIN_REQUIRE_CLAUDE': '1'}" "the full step requires the claude CLI and gets no token"
has "$O" "fulltimeout=60" "the full step has its own timeout (a hang is a red step)"
has "$O" "fullid=full" "the full step has id full (the issue step reads its outcome)"
has "$O" "fullsoft=None/None" "the full step has no continue-on-error and no if (a red suite cannot leave the job green)"
has "$O" "jobsoft=None/\${{ inputs.export_rev == '' }}" "the full job has no continue-on-error, and its only if is: export_rev is empty (the schedule, a dispatch without the input)"
has "$O" "untimed=[]" "every step before the issue step has its own timeout (a hang there must not cancel the job and skip the issue)"
has "$O" "issuesteps=1" "one issue step"
has "$O" "issueif=\${{ !cancelled() }}" "the issue step runs when the tests are red (not only on success)"
has "$O" "issueoutcome=\${{ steps.full.outcome }}" "the issue step reads the full step's outcome"
has "$O" "tokensteps=['issue']" "the token appears in the issue step only"
has "$O" "creds=False" "checkout keeps no credentials"
hasnt "$(sed -e 's/github\.token//g' "$WF")" "secrets." "no secret in the workflow"

echo "== the export_rev input and the export job =="
has "$O" "dispatch={'inputs': {'export_rev': {'description': " "workflow_dispatch has the one input export_rev"
has "$O" "'required': False, 'type': 'string', 'default': ''}}}" "…optional, a string, empty by default"
has "$O" "concurrency={'group': \"test-full\${{ inputs.export_rev && format('-export-{0}', inputs.export_rev) || '' }}\", 'cancel-in-progress': False}" "concurrency: group test-full with the input empty (as before), its own group with a rev; never cancels"
has "$O" "xif=\${{ inputs.export_rev != '' }}" "the export job runs only when export_rev is given"
has "$O" "xruns-on=ubuntu-latest" "the export job runs on ubuntu-latest, not on the CI_RUNNER variable"
has "$O" "xperms={'contents': 'read'}" "the export job asks for contents: read only (no issues: write)"
has "$O" "xconc=None" "no job-level concurrency (a job-level group would not release the workflow-level one)"
has "$O" "xsoft=None" "the export job has no continue-on-error"
has "$O" "xuntimed=[]" "every export step has its own timeout"
has "$O" "xcheckout=[{'fetch-depth': 0, 'persist-credentials': False}]" "the export job checks out every branch and keeps no credentials"
has "$O" "xcheck_first=True" "the 40-hex check is the first step, before checkout and export"
has "$O" "xexport=['bash scripts/export-public.sh \"\$REV\" \"\$RUNNER_TEMP/export\"']" "the rev is exported with scripts/export-public.sh to a directory of the runner"
has "$O" "xgit=[3]|['\${{ runner.temp }}/export']" "the export is made a git work tree (git init) inside the export directory, after the export"
has "$O" "xjobtimeout=105" "the export job's timeout holds the 90-minute suite step plus the install and export steps"
has "$O" "xgitcmds=['git init -q .', 'git add -Af', 'git -c user.name=export -c user.email=export@localhost -c commit.gpgsign=false commit -qm \"public export\"']" "the work tree is made with git init, git add -Af (ignored files too, as the export digest does) and one commit"
has "$O" "xorder=[2, 3, 5]" "order: export, git work tree, then the suite"
has "$O" "xfull=['bash tests/run-all.sh']|[{'PLUGIN_REQUIRE_CLAUDE': '1'}]|['\${{ runner.temp }}/export']|[90]" "the FULL suite runs inside the export, claude CLI required, its own timeout (90: the pod measured 53.7 min)"
has "$O" "xrun_inputs=[]" "no run: block of the export job holds an input expression (it reaches the shell through env only)"
has "$O" "xguards=[]" "no export step has an if or continue-on-error: a refused export_rev stops every step after the check"
has "$O" "fullrun_inputs=[]" "…nor one of the full job"
has "$O" "xenv_inputs=[('Check export_rev is a full commit SHA (40 hex)', {'REV': '\${{ inputs.export_rev }}'}), ('Export the public tree of export_rev', {'REV': '\${{ inputs.export_rev }}'})]" "the input reaches exactly two steps, each as REV in env"
XJOB=$(python3 -c 'import sys,yaml,json; print(json.dumps(yaml.safe_load(open(sys.argv[1]))["jobs"]["export"]))' "$WF")
hasnt "$XJOB" "github.token" "the export job holds no token"
hasnt "$XJOB" "GITHUB_TOKEN" "…no GITHUB_TOKEN"
hasnt "$XJOB" "secrets." "…no secret"
hasnt "$XJOB" "vars." "…no repository variable"
hasnt "$XJOB" "full-run-issue" "…and no issue step"

# the check's own shell block, run the way Actions runs it (bash -e), on good and hostile values
rev_rc() { ( cd "$TMP/rc" && REV="$1" bash -e "$TMP/check-rev.sh" > /dev/null 2>&1 ); }
mkdir -p "$TMP/rc"
GOOD=0123456789abcdef0123456789abcdef01234567
rev_rc "$GOOD"; eq "$?" 0 "export_rev: a 40-hex sha passes"
rev_rc "0123456789ABCDEF0123456789ABCDEF01234567"; eq "$?" 0 "…upper case too"
for bad_rev in "" "${GOOD:0:39}" "${GOOD}0" "${GOOD:0:39}g" "main" "refs/heads/main" "--help" "$GOOD $GOOD" "\$(touch $TMP/rc/pwned)" "\`touch $TMP/rc/pwned\`" "$GOOD; touch $TMP/rc/pwned" "'$GOOD'" "$GOOD"$'\n' $'\n'"$GOOD" "${GOOD:0:20}"$'\n'"${GOOD:20}"; do
  rev_rc "$bad_rev"; ne "$?" 0 "export_rev refused: $(printf '%q' "$bad_rev" | cut -c1-60)"
done
[ ! -e "$TMP/rc/pwned" ] && ok "…and nothing a hostile value spells was executed" || bad "a hostile export_rev was executed"
has "$(cat "$WF")" "set -o pipefail" "the tee keeps run-all.sh's exit code (pipefail)"

echo "== the issue step, fake gh =="
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'PY'
#!/usr/bin/env python3
import json, os, sys
st_path = os.environ["FAKE_GH_STATE"]
st = json.load(open(st_path))
a = sys.argv[1:]
with open(os.environ["FAKE_GH_LOG"], "a") as log:
    log.write(" ".join(a) + "\n")
if os.environ.get("FAKE_GH_FAIL") and a[:2] == os.environ["FAKE_GH_FAIL"].split():
    print("HTTP 502", file=sys.stderr); sys.exit(1)
def opt(name):
    return a[a.index(name) + 1] if name in a else None
out = ""
if a[0] == "api":
    out = json.dumps({"default_branch": st["default_branch"]})
elif a[:2] == ["issue", "list"]:
    out = json.dumps([{"number": i["number"]} for i in st["issues"] if i["state"] == opt("--state") and opt("--label") in i["labels"]])
elif a[:2] == ["label", "list"]:
    out = json.dumps([{"name": l} for l in st["labels"]])
elif a[:2] == ["label", "create"]:
    st["labels"].append(a[2])
elif a[:2] == ["issue", "create"]:
    n = 100 + len(st["issues"]); body = sys.stdin.read()
    st["issues"].append({"number": n, "state": "open", "labels": [opt("--label")], "title": opt("--title"), "body": body, "comments": []})
elif a[:2] == ["issue", "comment"]:
    [i for i in st["issues"] if i["number"] == int(a[2])][0]["comments"].append(sys.stdin.read())
elif a[:2] == ["issue", "close"]:
    i = [i for i in st["issues"] if i["number"] == int(a[2])][0]; i["state"] = "closed"; i["comments"].append(opt("--comment"))
else:
    print("fake gh: unexpected call %s" % a, file=sys.stderr); sys.exit(2)
json.dump(st, open(st_path, "w"))
print(out)
PY
chmod +x "$TMP/bin/gh"
export FAKE_GH_STATE="$TMP/state.json" FAKE_GH_LOG="$TMP/gh.log"
printf '{"default_branch": "main", "labels": [], "issues": []}\n' > "$FAKE_GH_STATE"
printf '...\nĐỎ 2/57 suite: hook (rc 1) gates (rc 1)\n' > "$TMP/red.log"
printf '...\nXANH 57/57 suite\n' > "$TMP/green.log"
step() {  # step <outcome> <ref> [<default branch>] [<log>] → the step's rc; writes nothing but its own output
  : > "$FAKE_GH_LOG"
  PATH="$TMP/bin:$PATH" python3 "$STEP" --repo org/repo --run-url "https://example.invalid/run/1" --outcome "$1" --ref "$2" \
    --default-branch "${3-main}" --log "${4:-$TMP/red.log}" > "$TMP/out" 2>&1
}
q() { python3 -c "import json,sys; s=json.load(open('$FAKE_GH_STATE')); print(eval(sys.argv[1]))" "$1"; }
calls() { grep -c . "$FAKE_GH_LOG"; }
writes() { grep -cE '^(issue (create|comment|close)|label create)' "$FAKE_GH_LOG"; }

step failure refs/heads/main; rc=$?
eq "$rc" 0 "red run on main: rc 0 ($(tr '\n' ' ' < "$TMP/out"))"
eq "$(q "s['labels']")" "['full-run-red']" "the missing label full-run-red was created"
eq "$(q "[(i['state'], i['labels']) for i in s['issues']]")" "[('open', ['full-run-red'])]" "ONE open issue labelled full-run-red"
has "$(q "s['issues'][0]['body']")" "ĐỎ 2/57 suite: hook (rc 1) gates (rc 1)" "the issue names the red suites"
has "$(q "s['issues'][0]['body']")" "https://example.invalid/run/1" "the issue links the run"
grep -q '^label create full-run-red' "$FAKE_GH_LOG" && ok "gh label create full-run-red was called" || bad "no gh label create"

step failure refs/heads/main; rc=$?
eq "$rc" 0 "second red run: rc 0"
eq "$(q "len(s['issues'])")" "1" "a second red run opens no second issue"
eq "$(q "len(s['issues'][0]['comments'])")" "1" "…it comments on the open one"
hasnt "$(cat "$FAKE_GH_LOG")" "label create" "…and does not touch the label"

step skipped refs/heads/main; rc=$?
eq "$(q "(s['issues'][0]['state'], len(s['issues'][0]['comments']))")" "('open', 2)" "a skipped test step (the run did not run) counts as red: the issue stays open, one more comment"
has "$(q "s['issues'][0]['comments'][-1]")" "outcome: \`skipped\`" "…and the comment names the outcome"

step failure refs/heads/feature
eq "$(writes)" "0" "a red run on another ref writes nothing to GitHub"

step success refs/heads/main "" "$TMP/green.log"; rc=$?
eq "$rc" 0 "green run, default branch asked of the API: rc 0 ($(tr '\n' ' ' < "$TMP/out"))"
grep -q '^api repos/org/repo' "$FAKE_GH_LOG" && ok "an empty --default-branch is read from gh api repos/<repo>" || bad "the API was not asked for the default branch"
eq "$(q "[i['state'] for i in s['issues']]")" "['closed']" "a green run closes the issue"

step success refs/heads/main main "$TMP/green.log"
eq "$(writes)" "0" "a green run with no open issue writes nothing"

printf '{"default_branch": "main", "labels": ["full-run-red", "bug"], "issues": []}\n' > "$FAKE_GH_STATE"
step failure refs/heads/main
hasnt "$(cat "$FAKE_GH_LOG")" "label create" "the label already there: not created again"
eq "$(q "len(s['issues'])")" "1" "…and the issue is opened"

printf '{"default_branch": "main", "labels": [], "issues": []}\n' > "$FAKE_GH_STATE"
FAKE_GH_FAIL="issue create" step failure refs/heads/main; rc=$?
eq "$rc" 1 "a gh failure makes the issue step red (rc 1)"
FAKE_GH_FAIL="issue list" step success refs/heads/main; rc=$?
eq "$rc" 1 "…also on a green run"

summary
