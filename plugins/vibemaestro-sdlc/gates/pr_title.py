#!/usr/bin/env python3
"""Gate: the title and the branch of a PR follow the repo's naming, and an intent PR does not keep its intent-file title once it carries code.

Checks (each one is inert until the config turns it on; the defaults make this gate pass everything):

  pr.title.pattern      the title must match this regex (`re.search`, the way `open_pr.py` applies it when it opens a PR)
  pr.title.max_len      the title may not be longer
  branch.pattern        a head branch that does NOT start with branch.intent_prefix must match this regex
  pr.title.intent_form  `reject`: a PR that is not a draft, whose title is still in the intent-file form (`intent:` or `docs(kb):`),
                        and whose diff has a file outside `kb/`, is red. An intent PR is opened as a draft while it has only
                        `kb/intent/<slug>.md`, and then a title that describes the file is right; nothing else reminds anyone to
                        rewrite it when the PR becomes ready and carries code, so the title lies about the PR.
                        Pattern, length and branch are checked for drafts too; the intent form only for a PR that is not a draft.
                        A diff that only touches `kb/` with a `docs(kb):` title is fine.

Use:
    echo '{"title": "...", "draft": false, "files": ["a", "kb/b"], "head": "feat/x"}' | pr_title.py
    pr_title.py --pr N [--repo OWNER/NAME]    read the current state through `gh` (title, draft, head branch, the files, paginated),
                                              not from an event payload
        [--config-ref REF]                    read .vibemaestro/sdlc.json at this git ref (CI: the base) instead of the working tree
        [--cwd DIR]

Not knowing is not a pass: a payload with no `files` when the intent-form check applies, or with no `head` when `branch.pattern` is
set, is red. A payload that is not JSON is rc 1 as well.
rc 0 pass (or not applicable), 1 red, 2 could not conclude (`gh` failed), 64 usage, 65 invalid config. A red here is a signal on the PR
(a repo may not make it a required check); it is not a merge blocker by itself.
Standard library only.
"""
import json
import re
import subprocess
import sys

try:
    import gate_common as gc
except ImportError as e:     # a partial vendored copy must not read as "red" (a traceback exits 1)
    sys.stderr.write("%s: could not conclude: %s\n" % ("pr_title.py", e))
    sys.exit(2)

PROFILE_RX = re.compile(r"^\s*(intent:|docs\(kb\):)", re.I)


def is_intent_shaped(title):
    return bool(PROFILE_RX.match(title or ""))


def decide(title, draft, files, head, cfg):
    """(rc, message). Pure: no network, no git, testable offline. `files` or `head` may be None (unknown)."""
    t = cfg["pr"]["title"]
    title = title or ""
    problems, applied = [], []
    if t["pattern"]:
        applied.append("pattern")
        if not re.search(t["pattern"], title):
            problems.append("the title %r does not match pr.title.pattern (%s)" % (title, t["pattern"]))
    if t["max_len"]:
        applied.append("max_len")
        if len(title) > t["max_len"]:
            problems.append("the title is %d characters, over pr.title.max_len (%d)" % (len(title), t["max_len"]))
    prefix = cfg["branch"]["intent_prefix"]
    if cfg["branch"]["pattern"]:
        applied.append("branch")
        if head is None:
            problems.append("the payload has no `head`: without the branch name branch.pattern cannot be checked")
        elif not head.startswith(prefix) and not re.search(cfg["branch"]["pattern"], head):
            problems.append("the branch %r neither starts with %s nor matches branch.pattern (%s)" % (head, prefix, cfg["branch"]["pattern"]))
    if t["intent_form"] == "reject":
        if draft:
            applied.append("intent_form (draft: not applied)")
        elif not is_intent_shaped(title):
            applied.append("intent_form")
        elif files is None:
            applied.append("intent_form")
            problems.append("the payload has no `files`: not knowing what the PR touches is not a pass")
        else:
            applied.append("intent_form")
            outside = sorted(f for f in files if isinstance(f, str) and not f.startswith("kb/"))
            if outside:
                problems.append(
                    "the title %r is still in the INTENT-FILE form (`intent: ...` / `docs(kb): ...`) but the diff has %d files outside `kb/` "
                    "(for example `%s`). Before the PR is ready, rewrite it as `type(scope): what was done`, describing what the PR puts "
                    "into main: gh pr edit <PR> --title \"type(scope): what was done\"" % (title, len(outside), outside[0]))
    if problems:
        return gc.RED, "; ".join(problems)
    if not applied:
        return gc.OK, "no title or branch rule is configured - the gate does not apply"
    return gc.OK, "title and branch follow the configured rules (%s)" % ", ".join(applied)


def _gh(args):
    try:
        p = subprocess.run(["gh"] + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise gc.Infra("gh could not run: %s" % e)
    if p.returncode != 0:
        raise gc.Infra("gh %s failed: %s" % (" ".join(args[:2]), p.stderr.decode("utf-8", "replace").strip()[:160]))
    return p.stdout.decode("utf-8", "replace")   # UTF-8 on purpose, not the locale: a PR is not ASCII


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    pr = repo = ref = None
    cwd = "."
    i = 0
    while i < len(argv):
        k = argv[i]
        if k in ("--pr", "--repo", "--config-ref", "--cwd") and i + 1 < len(argv):
            v = argv[i + 1]
            if k == "--pr":
                pr = v
            elif k == "--repo":
                repo = v
            elif k == "--config-ref":
                ref = v
            else:
                cwd = v
            i += 2
        else:
            sys.stderr.write("usage: pr_title.py [--pr N [--repo OWNER/NAME]] [--config-ref REF] [--cwd DIR]   (JSON on stdin without --pr)\n")
            return gc.USAGE
    cfg = gc.load_config(cwd, ref)
    if pr is not None:
        meta = json.loads(_gh(["pr", "view", pr] + (["-R", repo] if repo else []) + ["--json", "title,isDraft,headRefName"]))
        files_out = _gh(["api", "repos/%s/pulls/%s/files" % (repo or "{owner}/{repo}", pr), "--paginate", "--jq", ".[].filename"])
        files = [ln for ln in files_out.splitlines() if ln]
        rc, msg = decide(meta.get("title"), bool(meta.get("isDraft")), files, meta.get("headRefName"), cfg)
        print(("FAIL " if rc else "ok   ") + "#%s: %s" % (pr, msg))
        return rc
    raw = sys.stdin.read().strip()
    try:
        payload = json.loads(raw) if raw else {}
    except ValueError as e:
        print("FAIL cannot read the payload: %s" % e)
        return gc.RED
    if not isinstance(payload, dict):
        print("FAIL the payload must be a JSON object")
        return gc.RED
    rc, msg = decide(payload.get("title"), bool(payload.get("draft")), payload.get("files"), payload.get("head"), cfg)
    print(("FAIL " if rc else "ok   ") + msg)
    return rc


if __name__ == "__main__":
    sys.exit(gc.run_gate("pr-title", main))
