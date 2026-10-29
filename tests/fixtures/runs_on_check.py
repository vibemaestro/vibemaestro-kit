#!/usr/bin/env python3
"""Where can each job of a workflow directory land? Prints `jobs=<n>` and one `FAIL <file> <job>: <why>` line per job that can reach a
GitHub-hosted runner of a PRIVATE repository; rc 1 when there is any.

    runs_on_check.py <workflows dir>

The owner rule: every job of a private repository runs on our runners, and a missing runner variable must fail the run instead of falling
back to a paid hosted runner. In a public repository there is no runner of ours, so the same file falls back to ubuntu-latest there.
A job's `runs-on` is judged by evaluating it (tests/fixtures/gh_expr.py, which models fromJSON of non-JSON as a failed evaluation), not
by its spelling alone: it must answer as one of the two shapes of the kit,
    heavy   CI_RUNNER                       : the variable wins in both repositories; unset: public ubuntu-latest, private fails
    gate    CI_GATE_RUNNER, then CI_RUNNER  : the first one that is set wins; both unset: public ubuntu-latest, private fails
(an `internal` repository counts as not public: it fails too), AND be spelled exactly as the kit's expression for that shape: the tables
only probe variables and visibility, so a shortcut keyed on another context (an event, an input) would pass them. A literal label, a list,
a missing `runs-on` (a job that calls a reusable workflow) and a self-hosted label list are red on purpose: the kit has none, and a new one is
added here knowingly. The check reads *.yml and *.yaml, as Actions does.
"""
import glob
import os
import sys

try:
    import yaml
except ImportError:
    print("FAIL PyYAML is missing: the workflows cannot be read")
    sys.exit(1)

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gh_expr  # noqa: E402

PRIVATE, PUBLIC, INTERNAL = "private", "public", "internal"
FAILS = "<the evaluation fails>"   # what `runs-on` must give when no runner of ours is named: the run fails, it names no hosted label
# (variables set, visibility) -> what `runs-on` must answer
HEAVY = [({"CI_RUNNER": "our-runner"}, PRIVATE, "our-runner"), ({"CI_RUNNER": "our-runner"}, PUBLIC, "our-runner"),
         ({}, PUBLIC, "ubuntu-latest"), ({}, PRIVATE, FAILS), ({}, INTERNAL, FAILS), ({"CI_RUNNER": ""}, PRIVATE, FAILS)]
GATE = [({"CI_GATE_RUNNER": "gate", "CI_RUNNER": "our-runner"}, PRIVATE, "gate"), ({"CI_GATE_RUNNER": "gate"}, PRIVATE, "gate"),
        ({"CI_RUNNER": "our-runner"}, PRIVATE, "our-runner"), ({"CI_RUNNER": "our-runner"}, PUBLIC, "our-runner"),
        ({}, PUBLIC, "ubuntu-latest"), ({}, PRIVATE, FAILS), ({}, INTERNAL, FAILS), ({"CI_RUNNER": "", "CI_GATE_RUNNER": ""}, PRIVATE, FAILS)]
# the spelling of each shape (the guard answers ubuntu-latest in a public repository only, and fails otherwise)
GUARD = "(github.repository_visibility == 'public' && 'ubuntu-latest' || fromJSON('CI_RUNNER is not set in a private repository'))"
CANON = {"${{ vars.CI_RUNNER || %s }}" % GUARD, "${{ vars.CI_GATE_RUNNER || vars.CI_RUNNER || %s }}" % GUARD}


def answer(runs_on, vars_, visibility):
    """The label `runs-on` gives, or FAILS when its evaluation fails (a value of null or false is not a failure: it stays itself)."""
    ctx = {"vars": vars_, "github": {"repository_visibility": visibility}}
    try:
        return gh_expr.evaluate(runs_on, ctx)
    except gh_expr.EvalError:
        return FAILS


def misses(runs_on, table):
    return [(v, vis, want, answer(runs_on, v, vis)) for v, vis, want in table if answer(runs_on, v, vis) != want]


def judge(runs_on):
    """The reason this `runs-on` can reach a hosted runner of a private repository, or None."""
    if runs_on is None:
        return "no runs-on (a job that calls a reusable workflow): the runner is not the kit's to judge, add it here knowingly"
    if not isinstance(runs_on, str) or "${{" not in runs_on:
        return "runs-on is %r: a literal label (or a list) names a runner for every repository, hosted or not" % (runs_on,)
    try:
        bad_heavy, bad_gate = misses(runs_on, HEAVY), misses(runs_on, GATE)
    except ValueError as e:
        return "runs-on cannot be judged (%s)" % e
    if bad_heavy and bad_gate:
        v, vis, want, got = min(bad_heavy, bad_gate, key=len)[0]
        return "runs-on answers %r (wanted %r) with variables %s in a %s repository" % (got, want, sorted(v) or "unset", vis)
    if runs_on.strip() not in CANON:
        return "runs-on answers right to the probes but is not spelled as the kit's expression (a context the probes do not vary may reach a hosted label)"
    return None


def main(d):
    errs, n = [], 0
    for f in sorted(glob.glob(os.path.join(d, "*.yml")) + glob.glob(os.path.join(d, "*.yaml"))):
        jobs = (yaml.safe_load(open(f, encoding="utf-8")) or {}).get("jobs") or {}
        for name, job in jobs.items():
            n += 1
            why = judge((job or {}).get("runs-on"))
            if why:
                errs.append("FAIL %s %s: %s" % (os.path.basename(f), name, why))
    print("jobs=%d" % n)
    for e in errs:
        print(e)
    return 1 if errs else 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: runs_on_check.py <workflows dir>")
        sys.exit(64)
    sys.exit(main(sys.argv[1]))
