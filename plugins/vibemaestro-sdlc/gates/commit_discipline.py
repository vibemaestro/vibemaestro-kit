#!/usr/bin/env python3
"""Gate: a PR carries the repo's commit unit, counted by a machine instead of left to goodwill.

Rule behind it (rule `commit-unit`): one task is one commit, one fix round is one commit, a side branch is folded before it is
handed in. This script is the one count behind every route (a local review script, CI on the PR).

Four measures on `BASE..HEAD` (what is already in BASE is not counted, so a catch-up merge of main and main's own commits are not
counted, provided BASE is the LATEST tip of main: with an older BASE a catch-up merge looks like a side branch):

  commits       non-merge commits in the PR              > commits.max_per_pr   -> red
  file-touch    non-merge commits that touch one file    > commits.max_touches  -> red
  side-merge    a merge commit with a parent that is not in BASE (a side branch merged with `merge` keeps its own commits) -> red
  unfolded      a subject that starts with `wip`, `fixup!`, `squash!` or `amend!`, or one review round (commits.round_pattern, group 1
                is the number) spread over several commits                                     -> red

`wip` counts only as the FIRST mark of a subject (`wip`, `WIP:`, `[WIP]`, or right after `type(scope):`); as a noun or a scope name
it does not. A commit belongs to exactly ONE round: the first round number found in its subject.

`commits` and `file-touch` are thresholds: a PR with a chain whose order is load-bearing declares ONE line in the PR body that starts
with the configured token (`tokens.commit_exception`, default `COMMIT EXCEPTION:`) followed by a reason of at least 15 characters.
The line does not count inside a code fence, an HTML comment, a blockquote, an indented block, or when the reason is only a `<...>`
placeholder. The FIRST such line decides: a placeholder or short line above a valid one leaves the PR red, as in 1.0.0.
The other two measures have no exemption: there is no good reason to hand in `wip` or to keep a side-branch merge.

Use:
    commit_discipline.py [BASE] [HEAD]            # default origin/main HEAD
        [--body-file FILE]    the PR body, read for the exemption line
        [--max-commits N] [--max-touches N]       override commits.max_per_pr / commits.max_touches
        [--config-ref REF]    read .vibemaestro/sdlc.json at this git ref (CI passes the base) instead of the working tree
        [--json]              print the measures as JSON
        [--cwd DIR]

rc 0 pass, 1 red, 2 could not conclude (a bad ref, an empty range: a merged branch also has an empty range and "green" there
would report a count that never ran), 64 usage, 65 invalid config. Standard library only.
"""
import argparse
import json
import re
import sys

try:
    import gate_common as gc
except ImportError as e:     # a partial vendored copy must not read as "red" (a traceback exits 1)
    sys.stderr.write("commit_discipline.py: could not conclude: %s\n" % e)
    sys.exit(2)

MIN_REASON = 15
PLACEHOLDER_RX = re.compile(r"<[^<>\n]*>")
# `wip` is a mark only at the START of a subject (or right after `type(scope)!:`); `fixup!`-style marks only at the start.
WIP_RX = re.compile(r"(?i)^\s*(?:[a-z][\w-]*(?:\([^)]*\))?!?:\s*)?[\[(]?\s*wip\b|^\s*(?:fixup|squash|amend)!")

SEP_COMMIT = "\x1e"
SEP_FIELD = "\x1f"


def collect(base, head, cwd="."):
    """Raw facts of the range `base..head`. Touches git, decides nothing."""
    for ref in (base, head):
        if not gc.ref_ok(ref, cwd):
            raise gc.Infra("ref `%s` does not read" % ref)
    rng = "%s..%s" % (base, head)
    out = gc.must(["log", "--no-merges", "--name-only", "--format=%s%%H%s%%s%s" % (SEP_COMMIT, SEP_FIELD, SEP_FIELD), rng], cwd)
    commits = []
    for chunk in out.split(SEP_COMMIT)[1:]:
        sha, subject, files = chunk.split(SEP_FIELD, 2)
        commits.append({"sha": sha, "subject": subject, "files": [f for f in files.split("\n") if f]})
    merges = []
    for line in gc.must(["rev-list", "--merges", "--parents", rng], cwd).splitlines():
        sha, parents = line.split()[0], line.split()[1:]
        foreign = []
        for par in parents[1:]:
            rc = gc.git(["merge-base", "--is-ancestor", par, base], cwd)[0]
            if rc == 1:
                foreign.append(par)
            elif rc != 0:
                raise gc.Infra("merge-base --is-ancestor %s %s failed" % (par[:7], base))
        merges.append({"sha": sha, "foreign_parents": foreign})
    n_all = int(gc.must(["rev-list", "--count", rng], cwd).strip())
    return {"commits": commits, "merges": merges, "n_all": n_all}


def first_line(body, token):
    """The text after the token on the FIRST exemption line (outside fences and comments), or None. The line needs one character
    after the token, so a bare token line is skipped, as in 1.0.0 (a token and only spaces, or a `\r` of a CRLF body, is a line)."""
    m = re.search(r"^ {0,3}" + re.escape(token) + r"[ \t]*(.+?)[ \t]*$", gc.strip_fences(body or ""), re.M)
    return m.group(1) if m else None


def exemption(body, token):
    """The reason of the first exemption line, or None when that line is too short or only a placeholder: a valid line below it
    does not count (as in 1.0.0)."""
    why = first_line(body, token)
    if why is None or len(PLACEHOLDER_RX.sub("", why).strip()) < MIN_REASON:
        return None
    return why


def round_of(subject, rx):
    """The first review-round number in a subject, or None. The subject is normalised first (lower case, no accents, `đ` as `d`:
    sdlc_config.round_plain), so a word written with or without accents (composed or decomposed) is one round."""
    m = rx.search(gc.sdlc_config.round_plain(subject))
    return m.group(1) if m else None


def measure(facts, rx):
    touch = {}
    for c in facts["commits"]:
        for f in set(c["files"]):
            touch[f] = touch.get(f, 0) + 1
    rounds = {}
    for c in facts["commits"]:
        n = round_of(c["subject"], rx)   # one commit belongs to one round: repeating an older round does not count
        if n is not None:
            rounds.setdefault(n, []).append(c["sha"])
    return {
        "commits": len(facts["commits"]),
        "merges_total": len(facts["merges"]),
        "side_merges": [m for m in facts["merges"] if m["foreign_parents"]],
        "file_touch": touch,
        "max_touch": max(touch.values()) if touch else 0,
        "markers": [c for c in facts["commits"] if WIP_RX.search(c["subject"])],
        "round_split": dict((n, s) for n, s in rounds.items() if len(s) > 1),
    }


def _list(items, n=3):
    return ", ".join(items[:n]) + (", ..." if len(items) > n else "")


def decide(facts, body, limits, token, rx):
    """(rc, findings, measures). Pure: testable offline. `limits` = (max_commits, max_touches)."""
    max_commits, max_touches = limits
    m = measure(facts, rx)
    why = exemption(body, token)
    found = []   # (kind, text, waivable)
    if m["commits"] > max_commits:
        found.append(("commits", "%d non-merge commits (limit %d)" % (m["commits"], max_commits), True))
    hot = sorted(((n, f) for f, n in m["file_touch"].items() if n > max_touches), key=lambda t: (-t[0], t[1]))
    if hot:
        found.append(("file-touch", "%d files touched again and again (limit %d commits per file): %s"
                      % (len(hot), max_touches, _list(["%s x%d" % (f, n) for n, f in hot])), True))
    if m["side_merges"]:
        found.append(("side-merge", "%d side-branch merges keep the branch's own commits (%s); two causes are easy to mix up: BASE is "
                      "older than main (a catch-up merge is counted: fetch and run again with origin/main) or `git pull` merged the "
                      "PR branch into itself (rebase, do not merge origin/<branch>)"
                      % (len(m["side_merges"]), _list([x["sha"][:7] for x in m["side_merges"]])), False))
    if m["markers"]:
        found.append(("unfolded", "%d commits carry a wip/fixup/squash mark (%s)"
                      % (len(m["markers"]), _list([c["sha"][:7] for c in m["markers"]])), False))
    if m["round_split"]:
        found.append(("unfolded", "a review round is split over several commits: %s"
                      % ", ".join("round %s x%d" % (n, len(s)) for n, s in sorted(m["round_split"].items())), False))
    blocking = [f for f in found if not (f[2] and why)]
    m["exempt"] = why if why and any(f[2] for f in found) else None
    return (1 if blocking else 0), found, m


def render(rc, found, m):
    if not found:
        return "pass - %d non-merge commits, no file touched more than %d times, no side-branch merge" % (m["commits"], m["max_touch"])
    head = "FAIL" if rc else "pass (named exemption: %s)" % m["exempt"][:60]
    return head + " - " + "; ".join("%s: %s" % (k, t) for k, t, _ in found)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("base", nargs="?", default="origin/main")
    ap.add_argument("head", nargs="?", default="HEAD")
    ap.add_argument("--body-file")
    ap.add_argument("--max-commits", type=int)
    ap.add_argument("--max-touches", type=int)
    ap.add_argument("--config-ref")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--cwd", default=".")
    try:
        a = ap.parse_args(argv)
    except SystemExit as e:
        return gc.USAGE if e.code else 0
    body = ""
    if a.body_file:
        try:
            with open(a.body_file, encoding="utf-8") as fh:
                body = fh.read()
        except OSError as e:
            sys.stderr.write("commit-discipline: cannot read --body-file: %s\n" % e)
            return gc.USAGE
    cfg = gc.load_config(a.cwd, a.config_ref)
    limits = (a.max_commits if a.max_commits is not None else cfg["commits"]["max_per_pr"],
              a.max_touches if a.max_touches is not None else cfg["commits"]["max_touches"])
    rx = re.compile(cfg["commits"]["round_pattern"])
    if gc.sdlc_config.round_never_matches(cfg["commits"]["round_pattern"]):
        sys.stderr.write("WARNING commits.round_pattern %s\n" % gc.sdlc_config.ROUND_NEVER_MATCHES)   # stderr: --json stays one JSON
    facts = collect(a.base, a.head, a.cwd)
    if not facts["n_all"]:
        raise gc.Infra("range `%s..%s` is empty: the branch is already merged, or a ref is wrong" % (a.base, a.head))
    rc, found, m = decide(facts, body, limits, cfg["tokens"]["commit_exception"], rx)
    if a.json:
        out = dict(m)
        out["rc"] = rc
        out["found"] = [{"kind": k, "text": t, "waivable": w} for k, t, w in found]
        out["file_touch"] = dict((f, n) for f, n in m["file_touch"].items() if n > limits[1])
        out["markers"] = [c["sha"] for c in m["markers"]]
        print(json.dumps(out, ensure_ascii=False))
    else:
        print("commit-discipline: " + render(rc, found, m))
        if rc:
            print("  Fold the chain to the unit of rule `commit-unit` (only a chain no review has seen may be rewritten). A chain whose "
                  "order is load-bearing: add to the PR body `%s <reason of at least %d characters>`."
                  % (cfg["tokens"]["commit_exception"], MIN_REASON))
            if any(w for _, _, w in found) and first_line(body, cfg["tokens"]["commit_exception"]) is not None and not m["exempt"]:
                print("  The first `%s` line of the body is a placeholder or shorter than %d characters: only the first such line "
                      "counts, a line below it does not." % (cfg["tokens"]["commit_exception"], MIN_REASON))
    return rc


if __name__ == "__main__":
    sys.exit(gc.run_gate("commit-discipline", main))
