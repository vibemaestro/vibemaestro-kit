#!/usr/bin/env python3
# =============================================================================
# The scheduled full run's issue step (.github/workflows/test-full.yml): ONE labelled issue while the full suite is red
# =============================================================================
#   python3 tests/full-run-issue.py --repo <owner/name> --run-url <url> --outcome <step outcome> --ref <github.ref>
#                                   [--default-branch <name>] [--log <file>]
#
#   red (any outcome but `success`: failure, cancelled, skipped — a run that did not run is not green)
#       → the label LABEL is created when the repository lacks it; then a comment on the open issue with that label (the oldest
#         when there are several), or a new issue with that label when none is open. The body names the red suites (the
#         `ĐỎ …` line of run-all.sh in the log) and the run link.
#   green → every open issue with that label is closed with a comment linking the run.
#   a ref that is not the default branch (workflow_dispatch elsewhere) → no issue is touched.
# The default branch comes from --default-branch, or from `gh api repos/<repo>` when that is empty (the schedule event may
# not carry it). Exit 0 when the issue state was handled, 1 when a `gh` call failed (the step is red, and so is the job).
# This step never decides the job's colour: the test step does. Tested offline with a fake `gh`: tests/test-full-run.sh.
# =============================================================================
import argparse
import json
import re
import subprocess
import sys

LABEL = "full-run-red"
TITLE = "Scheduled full test run is red"


class GhError(Exception):
    pass


def gh(*args, stdin=None):
    r = subprocess.run(["gh"] + list(args), input=stdin, capture_output=True, text=True)
    if r.returncode != 0:
        raise GhError("gh %s: rc %d: %s" % (" ".join(args[:2]), r.returncode, r.stderr.strip()[:300]))
    return r.stdout


def red_line(log):
    try:
        with open(log, encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return "(no log)"
    for line in reversed(lines):
        if re.match(r"^(ĐỎ|XANH|FAIL)\b", line):
            return line.strip()[:2000]
    return "(the log has no summary line: the run stopped before run-all.sh finished)"


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--run-url", required=True)
    ap.add_argument("--outcome", required=True)
    ap.add_argument("--ref", required=True)
    ap.add_argument("--default-branch", default="")
    ap.add_argument("--log", default="")
    a = ap.parse_args(argv)
    try:
        default = a.default_branch or json.loads(gh("api", "repos/%s" % a.repo))["default_branch"]
        if a.ref != "refs/heads/%s" % default:
            print("full-run-issue: %s is not the default branch (%s): no issue is touched" % (a.ref, default))
            return 0
        open_issues = sorted(int(i["number"]) for i in json.loads(
            gh("issue", "list", "--repo", a.repo, "--label", LABEL, "--state", "open", "--json", "number", "--limit", "100")))
        if a.outcome == "success":
            for n in open_issues:
                gh("issue", "close", str(n), "--repo", a.repo, "--comment", "The scheduled full run is green again: %s" % a.run_url)
                print("full-run-issue: green, closed #%d" % n)
            if not open_issues:
                print("full-run-issue: green, no open issue")
            return 0
        body = ("The scheduled full run of `bash tests/run-all.sh` is red (test step outcome: `%s`).\n\n"
                "Summary line: `%s`\n\nRun: %s\n" % (a.outcome, red_line(a.log) if a.log else "(no log)", a.run_url))
        if open_issues:
            gh("issue", "comment", str(open_issues[0]), "--repo", a.repo, "--body-file", "-", stdin=body)
            print("full-run-issue: red, commented on #%d" % open_issues[0])
            return 0
        labels = json.loads(gh("label", "list", "--repo", a.repo, "--search", LABEL, "--json", "name", "--limit", "100"))
        if not any(l.get("name") == LABEL for l in labels):
            gh("label", "create", LABEL, "--repo", a.repo, "--color", "B60205",
               "--description", "The scheduled full test run is red")
            print("full-run-issue: created the label %s" % LABEL)
        gh("issue", "create", "--repo", a.repo, "--title", TITLE, "--label", LABEL, "--body-file", "-", stdin=body)
        print("full-run-issue: red, opened an issue")
        return 0
    except (GhError, ValueError, KeyError) as e:
        print("full-run-issue: %s" % e, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
