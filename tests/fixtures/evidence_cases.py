#!/usr/bin/env python3
"""The cases of tests/test-gates-evidence.sh: the pr-evidence gate's decision, its patch-id carry-over on real git, and its workflow.

    evidence_cases.py <family> <plugin dir> <scratch dir>

One line per check: `ok\t<label>` or `FAIL\t<label>`. Families:
  decide    synthetic facts: what counts as review and E2E evidence, pinned to the head, stale, carried over, ignored
  carry     real git repositories: a pure merge of the base keeps the patch-id, a PR-side change after the evidence does not
  workflow  the template: the jobs' `if` evaluated per event (tests/fixtures/gh_expr.py), the re-run job's fences
"""
import os
import re
import subprocess
import sys

import yaml

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gh_expr  # noqa: E402

H, OLD = "a" * 40, "b" * 40


def say(cond, label):
    sys.stdout.write("%s\t%s\n" % ("ok" if cond else "FAIL", label))


def gate(plugin):
    sys.path.insert(0, os.path.join(plugin, "gates"))
    import pr_evidence
    return pr_evidence


def cfg_of(E, data):
    C = E.gc.sdlc_config
    return C.effective(data)


N = [0]


def c(body, assoc="MEMBER", t=None, author="alice", author_type="User", app=None):
    N[0] += 1
    return {"url": "https://example.invalid/c/%d" % N[0], "author": author, "association": assoc, "body": body,
            "created_at": t or "2026-10-20T10:%02d:00Z" % N[0], "id": N[0], "author_type": author_type, "app": app}


def bot(body, slug="acme-ai", author=None, app=None):
    """A comment as GitHub records one an App's installation token posted: Bot `<slug>[bot]`, association NONE, via the App."""
    return c(body, assoc="NONE", author=author or slug + "[bot]", author_type="Bot", app=app or slug)


def run(E, cfg, comments, files=(), capped=False, carry=None, base_moved=None):
    carry = carry or {}
    facts = {"head": H, "files": list(files), "capped": capped, "comments": comments, "base": "main", "base_moved": base_moved,
             "carry": lambda s: carry.get(s, (None, "the PR's own changes differ since then (patch-id p → q)"))}
    rc, lines = E.decide(facts, cfg)
    return rc, "\n".join(lines)


def fam_decide(plugin, scratch):
    E = gate(plugin)
    plain = cfg_of(E, {})
    ui = cfg_of(E, {"evidence": {"ui_paths": ["web/**"]}})
    rev = "SHA: %s — review round 1 (fresh-context Opus)"
    web = [{"filename": "web/app.ts"}]

    def case(label, want_rc, needle, cfg, comments, **kw):
        rc, out = run(E, cfg, comments, **kw)
        say(rc == want_rc and needle in out, "[D] %s: rc %d, says %r (%s)" % (label, want_rc, needle, out.replace("\n", " | ")[:220]))

    case("no comment at all", 1, "no AI-review comment pins the head " + H, plain, [])
    case("a review pinned to the head", 0, "review ok", plain, [c(rev % H)])
    case("a review pinned to an older head", 1, "pins %s; the head is %s" % (OLD, H), plain, [c(rev % OLD)])
    case("a short SHA", 1, "only the full 40-hex head counts", plain, [c(rev % H[:7])])
    case("a review by an outside commenter", 1, "ignored: ", plain, [c(rev % H, assoc="NONE", author="mallory")])
    case("…an outside commenter is not evidence even with a member's stale one", 1, "pins %s" % OLD, plain,
         [c(rev % OLD), c(rev % H, assoc="CONTRIBUTOR")])
    case("a review only inside a code fence", 1, "no AI-review comment", plain, [c("```\n" + rev % H + "\n```")])
    case("a review only inside an HTML comment", 1, "no AI-review comment", plain, [c("<!-- " + rev % H + " -->")])
    case("a first line without a round number", 1, "no AI-review comment", plain, [c("SHA: %s — review done" % H)])
    case("a first line without the word review", 1, "no AI-review comment", plain, [c("SHA: %s — round 1 merged main" % H)])
    case("the SHA not right after the prefix", 1, "no AI-review comment", plain, [c("SHA: see %s review round 1" % H)])
    case("the newest review decides: an older one on the head, a newer one stale", 1, "pins %s" % OLD, plain,
         [c(rev % H), c(rev % OLD)])
    case("a stale review carried over a pure merge (same patch-id)", 0, "carried from %s" % OLD, plain, [c(rev % OLD)],
         carry={OLD: ("p" * 40, "")})
    case("…its message names the base", 0, "only merges of main", plain, [c(rev % OLD)], carry={OLD: ("p" * 40, "")})
    case("a stale review whose PR-side changes differ", 1, "patch-id p → q", plain, [c(rev % OLD)])
    case("a stale review that cannot be compared", 1, "pins %s" % OLD, plain, [c(rev % OLD)], carry={OLD: (None, "x is not an ancestor")})
    case("the base moved since the run's event", 1, "the PR's base is now", plain, [c(rev % H)], base_moved="… the PR's base is now dev …")
    case("no UI paths set: no E2E asked", 0, "evidence.ui_paths is not set", plain, [c(rev % H)], files=web)
    case("a non-UI change: no E2E asked", 0, "no changed path matches", ui, [c(rev % H)], files=[{"filename": "lib/a.py"}])
    case("a UI change without E2E evidence", 1, "changes UI paths (web/app.ts)", ui, [c(rev % H)], files=web)
    case("a rename out of a UI path", 1, "changes UI paths (web/old.ts)", ui, [c(rev % H)],
         files=[{"filename": "lib/new.ts", "previous_filename": "web/old.ts"}])
    case("a file list at the API cap counts as UI", 1, "the list is cut", ui, [c(rev % H)], capped=True)
    case("a UI change with E2E pass on the head", 0, "e2e ok", ui, [c(rev % H + "\n\nE2E pass: 12 specs")], files=web)
    case("E2E pass in a comment of its own", 0, "e2e ok", ui, [c(rev % H), c("SHA: %s\nE2E pass" % H)], files=web)
    case("E2E không chạy with a reason", 0, "not run: the UI change is a label", ui,
         [c(rev % H + "\nE2E không chạy: the UI change is a label")], files=web)
    case("E2E không chạy with no reason", 1, "needs a reason of at least 15", ui, [c(rev % H + "\nE2E không chạy:")], files=web)
    case("E2E not run with a short reason", 1, "needs a reason of at least 15", ui, [c(rev % H + "\nE2E not run: no time")], files=web)
    case("an E2E line pinned to an older head", 1, "the latest E2E line", ui, [c(rev % H), c("SHA: %s\nE2E pass" % OLD)], files=web)
    case("an E2E line carried over a pure merge", 0, "e2e ok", ui, [c(rev % H), c("SHA: %s\nE2E pass" % OLD)], files=web,
         carry={OLD: ("p" * 40, "")})
    case("E2E pass inside a fence does not count", 1, "changes UI paths", ui, [c(rev % H + "\n```\nE2E pass\n```")], files=web)
    case("E2E pass by an outside commenter does not count", 1, "changes UI paths", ui,
         [c(rev % H), c("SHA: %s\nE2E pass" % H, assoc="NONE")], files=web)
    case("a review typed with CRLF line ends, a fenced block, then E2E pass", 0, "e2e ok", ui,
         [c((rev % H) + "\r\n\r\n```\r\nlog\r\n```\r\nE2E pass\r\n")], files=web)
    case("E2E pass-through is not a pass", 1, "changes UI paths", ui, [c(rev % H + "\nE2E pass-through broken")], files=web)
    case("a reason of zero-width spaces is no reason", 1, "needs a reason of at least 15", ui,
         [c(rev % H + "\nE2E không chạy: " + "\u200b" * 20)], files=web)
    case("E2E pass inside a script element (GitHub renders none of it)", 1, "changes UI paths", ui,
         [c(rev % H + "\n<script>\nE2E pass\n</script>")], files=web)
    case("E2E không chạy typed in NFD still reads", 0, "not run:", ui,
         [c(rev % H + "\n" + __import__("unicodedata").normalize("NFD", "E2E không chạy: the UI change is a label"))], files=web)
    case("an edited OLD comment does not become the newest (posting time decides)", 0, "review ok", plain,
         [c(rev % OLD, t="2026-10-20T09:00:00Z"), c(rev % H, t="2026-10-20T10:00:00Z")])
    appcfg = cfg_of(E, {"evidence": {"trusted_app": "acme-ai"}})
    case("a review by the trusted App's bot", 0, "review ok", appcfg, [bot(rev % H)])
    case("…the same comment with evidence.trusted_app unset: ignored (as before)", 1, "ignored: ", plain, [bot(rev % H)])
    case("…unset, the ignored line names the key", 1, "evidence.trusted_app is not set, so no App counts", plain, [bot(rev % H)])
    case("a review by another App's bot", 1, "ignored: ", appcfg, [bot(rev % H, slug="other-ai")])
    case("the App's slug in another case (the fence ignores case too)", 0, "review ok", appcfg, [bot(rev % H, app="ACME-ai")])
    rc, out = run(E, appcfg, [c(rev % H, assoc="NONE", author="mallory")])
    say(rc == 1 and "ignored: " in out and "trusted_app" not in out,
        "[D] a plain outside user's ignored line carries no App reason (%s)" % out.replace("\n", " | ")[:160])
    case("a user account named like the slug", 1, "ignored: ", appcfg, [c(rev % H, assoc="NONE", author="acme-ai", app="acme-ai")])
    case("a user account whose login reads <slug>[bot]", 1, "ignored: ", appcfg,
         [c(rev % H, assoc="NONE", author="acme-ai[bot]", app="acme-ai")])
    case("a person posting through the App with their own token", 1, "ignored: ", appcfg,
         [c(rev % H, assoc="NONE", author="mallory", app="acme-ai")])
    case("the App's bot login, posted through another App", 1, "ignored: ", appcfg, [bot(rev % H, app="other-ai")])
    case("another App's bot login, posted through the App", 1, "ignored: ", appcfg, [bot(rev % H, slug="other-ai", app="acme-ai")])
    case("…a person via the App: the ignored line says only the App's bot counts", 1, "only the bot of evidence.trusted_app counts: "
         "acme-ai[bot], posted through acme-ai", appcfg, [c(rev % H, assoc="NONE", author="mallory", app="acme-ai")])
    case("the App's bot login with no App recorded", 1, "ignored: ", appcfg,
         [c(rev % H, assoc="NONE", author="acme-ai[bot]", author_type="Bot")])
    case("E2E pass by the trusted App's bot", 0, "e2e ok", cfg_of(E, {"evidence": {"ui_paths": ["web/**"], "trusted_app": "acme-ai"}}),
         [bot(rev % H + "\nE2E pass")], files=web)
    prefixed = cfg_of(E, {"tokens": {"round_comment_prefix": "Vòng:"}})
    case("the prefix comes from the config", 0, "review ok", prefixed, [c("Vòng: %s — review round 1" % H)])
    case("…and the default prefix no longer counts", 1, "no AI-review comment", prefixed, [c(rev % H)])


def git(cwd, *a):
    return subprocess.run(["git", "-C", cwd] + list(a), stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True,
                          env=dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t",
                                   GIT_COMMITTER_EMAIL="t@t")).stdout.decode().strip()


def commit(cwd, path, text, msg):
    os.makedirs(os.path.dirname(os.path.join(cwd, path)) or cwd, exist_ok=True)
    with open(os.path.join(cwd, path), "w") as f:
        f.write(text)
    git(cwd, "add", path)
    git(cwd, "commit", "-q", "-m", msg)
    return git(cwd, "rev-parse", "HEAD")


def fam_carry(plugin, scratch):
    E = gate(plugin)
    r = os.path.join(scratch, "carry")
    os.makedirs(r)
    git(r, "init", "-q", "-b", "main")
    commit(r, "README", "base\n", "base")
    git(r, "checkout", "-q", "-b", "pr")
    ev = commit(r, "src/a.py", "if not ok:\n    deny()\nrun()\n", "the PR's change")
    git(r, "checkout", "-q", "main")
    commit(r, "docs/b.md", "main moved\n", "main moves")
    git(r, "checkout", "-q", "pr")
    git(r, "merge", "-q", "--no-edit", "main")
    merged = git(r, "rev-parse", "HEAD")
    pid, why = E.carry_fn(r, "main", merged)(ev)
    say(pid is not None, "[C] a pure merge of the base after the evidence carries it over (%s)" % (why or pid[:12]))
    ws = commit(r, "src/a.py", "if not ok:\n    deny()\n    run()\n", "a whitespace-only change that changes what runs")
    pid, why = E.carry_fn(r, "main", ws)(ev)
    say(pid is None, "[C] a whitespace-only PR-side change after the evidence does not carry (%s)" % why)
    git(r, "reset", "-q", "--hard", merged)
    git(r, "checkout", "-q", "main")
    commit(r, "docs/c.md", "main moves again\n", "main moves again")
    git(r, "checkout", "-q", "pr")
    git(r, "merge", "-q", "--no-ff", "--no-commit", "main")
    with open(os.path.join(r, "src/a.py"), "w") as f:
        f.write("if not ok:\n    deny()\n    run()\n")
    git(r, "add", "src/a.py")
    git(r, "commit", "-q", "--no-edit")
    evil = git(r, "rev-parse", "HEAD")
    pid, why = E.carry_fn(r, "main", evil)(ev)
    say(pid is None and ("differ" in why or "not a clean merge" in why),
        "[C] a merge that slips a whitespace change into the PR's file does not carry (%s)" % why)
    git(r, "reset", "-q", "--hard", merged)
    block = "".join("%d\n" % i for i in range(1, 7))
    commit(r, "lib/two.txt", "0\n" + block + "0\n" + block + "0\n", "two identical blocks")
    git(r, "checkout", "-q", "-b", "pr2", "main")
    git(r, "merge", "-q", "--no-edit", "pr")
    git(r, "checkout", "-q", "pr")
    moved_base = git(r, "rev-parse", "HEAD")
    first = "0\n1\n2\n3\nCHECK\n4\n5\n6\n0\n" + block + "0\n"
    ev2 = commit(r, "lib/two.txt", first, "the reviewed change in the first block")
    git(r, "checkout", "-q", "main")
    commit(r, "docs/d.md", "main moves a third time\n", "main moves a third time")
    git(r, "checkout", "-q", "pr")
    git(r, "merge", "-q", "--no-ff", "--no-commit", "main")
    with open(os.path.join(r, "lib/two.txt"), "w") as f:
        f.write("0\n" + block + "0\n1\n2\n3\nCHECK\n4\n5\n6\n0\n")
    git(r, "add", "lib/two.txt")
    git(r, "commit", "-q", "--no-edit")
    moved = git(r, "rev-parse", "HEAD")
    pid, why = E.carry_fn(r, "main", moved)(ev2)
    say(pid is None and "not a clean merge" in why,
        "[C] a merge that moves the reviewed change to an identical block elsewhere does not carry (%s)" % why)
    git(r, "reset", "-q", "--hard", merged)
    same = commit(r, "src/c.py", "x\n", "a commit of its own")
    git(r, "revert", "--no-edit", "HEAD")
    reverted = git(r, "rev-parse", "HEAD")
    pid, why = E.carry_fn(r, "main", reverted)(ev)
    say(pid is None and "commits of its own" in why, "[C] commits of the PR's own after the evidence, even ones that cancel out, do not carry (%s)" % why)
    git(r, "reset", "-q", "--hard", merged)
    git(r, "checkout", "-q", "-b", "other", "main")
    stranger = commit(r, "src/a.py", "if not ok:\n    deny()\nrun()\n", "the same change on another line of history")
    git(r, "checkout", "-q", "pr")
    pid, why = E.carry_fn(r, "main", merged)(stranger)
    say(pid is None and "not an ancestor" in why, "[C] evidence on a SHA that is not an ancestor of the head does not carry (%s)" % why)
    pid, why = E.carry_fn(r, "main", merged)("f" * 40)
    say(pid is None and "not an ancestor" in why, "[C] an evidenced SHA that is not in the repository does not carry, and says why")
    facts = {"head": merged, "files": [], "capped": False, "base": "main", "carry": E.carry_fn(r, "main", merged),
             "comments": [c("SHA: %s — review round 1 (fresh-context Opus)" % ev)]}
    rc, lines = E.decide(facts, cfg_of(E, {}))
    say(rc == 0 and any("carried from %s" % ev in ln for ln in lines), "[C] decide on real git: the review carries over the merge")
    facts["head"], facts["carry"] = ws, E.carry_fn(r, "main", ws)
    git(r, "checkout", "-q", "-B", "pr", ws)
    rc, lines = E.decide(facts, cfg_of(E, {}))
    say(rc == 1 and any("pins %s; the head is %s" % (ev, ws) in ln for ln in lines),
        "[C] decide on real git: a PR-side change after the review is red, naming both SHAs")


def evaluate(cond, gh, variables=None):
    text = str(cond).strip()
    ctx = {"github": gh, "vars": variables or {}}
    v = gh_expr.evaluate(text, ctx) if "${{" in text else gh_expr.expression(text, ctx)
    return gh_expr.truthy(v)


def fam_workflow(plugin, scratch):
    path = os.path.join(plugin, "gates", "workflows", "pr-evidence.yml")
    doc = yaml.safe_load(re.sub(r"@@([A-Z_]+)@@", r"marker-\1", open(path, encoding="utf-8").read()))
    jobs = doc.get("jobs") or {}
    ev, rr = jobs.get("evidence") or {}, jobs.get("rerun") or {}

    def pr(action, draft=False, changes=None):
        e = {"action": action, "pull_request": {"number": 7, "draft": draft}, "repository": {"private": True}}
        if changes:
            e["changes"] = changes
        return {"event_name": "pull_request", "event": e}

    def comment(assoc, body="SHA: %s — review round 1" % H, draft=False, is_pr=True):
        issue = {"number": 7, "draft": draft}
        if is_pr:
            issue["pull_request"] = {}
        return {"event_name": "issue_comment",
                "event": {"action": "created", "issue": issue, "comment": {"author_association": assoc, "body": body}}}

    say(evaluate(ev.get("if"), pr("synchronize")), "[W] evidence runs on a new commit of a ready PR")
    say(evaluate(ev.get("if"), pr("ready_for_review")), "[W] …and when the PR goes ready")
    say(not evaluate(ev.get("if"), pr("synchronize", draft=True)), "[W] …not on a draft")
    say(not evaluate(ev.get("if"), pr("edited", changes={"body": {"from": "x"}})), "[W] …not on a body edit (it reads comments)")
    say(evaluate(ev.get("if"), pr("edited", changes={"base": {"ref": {"from": "x"}}})), "[W] …but on a new base (the patch-id base)")
    say(not evaluate(ev.get("if"), comment("MEMBER")), "[W] …and never on a comment (the rerun job handles it)")
    say(evaluate(rr.get("if"), comment("MEMBER")), "[W] rerun: a member's comment on a ready PR")
    for assoc in ("NONE", "CONTRIBUTOR", "FIRST_TIME_CONTRIBUTOR", "FIRST_TIMER", "MANNEQUIN", None):
        say(not evaluate(rr.get("if"), comment(assoc)), "[W] rerun: a comment by %s re-runs nothing (the job does not start)" % assoc)
    say(not evaluate(rr.get("if"), comment("MEMBER", draft=True)), "[W] rerun: not on a draft")
    say(not evaluate(rr.get("if"), comment("MEMBER", draft=None)), "[W] rerun: a payload without the draft field counts as a draft")
    say(not evaluate(rr.get("if"), comment("MEMBER", is_pr=False)), "[W] rerun: not on a plain issue")
    say(not evaluate(rr.get("if"), pr("synchronize")), "[W] rerun: not on a pull_request event")

    def by(login, kind="Bot", app=None, assoc="NONE"):
        e = comment(assoc)
        e["event"]["comment"]["user"] = {"login": login, "type": kind}
        e["event"]["comment"]["performed_via_github_app"] = {"slug": app} if app else None
        return e
    appvar = {"PR_EVIDENCE_APP": "acme-ai"}
    say(evaluate(rr.get("if"), by("acme-ai[bot]", app="acme-ai"), appvar), "[W] rerun: the App PR_EVIDENCE_APP names re-runs")
    say(not evaluate(rr.get("if"), by("acme-ai[bot]", app="acme-ai")), "[W] rerun: …not with PR_EVIDENCE_APP unset")
    say(not evaluate(rr.get("if"), by("acme-ai[bot]", app="acme-ai"), {"PR_EVIDENCE_APP": ""}), "[W] rerun: …not with it empty")
    say(not evaluate(rr.get("if"), by("[bot]", app=""), {"PR_EVIDENCE_APP": ""}), "[W] rerun: …an empty variable trusts no '[bot]'")
    say(not evaluate(rr.get("if"), by("other-ai[bot]", app="other-ai"), appvar), "[W] rerun: another App re-runs nothing")
    say(not evaluate(rr.get("if"), by("other-ai[bot]", app="acme-ai"), appvar), "[W] rerun: another App's bot via the App re-runs nothing")
    say(not evaluate(rr.get("if"), by("acme-ai", kind="User", app="acme-ai"), appvar), "[W] rerun: a user named like the slug re-runs nothing")
    say(not evaluate(rr.get("if"), by("acme-ai[bot]", kind="User", app="acme-ai"), appvar), "[W] rerun: a User typed '<slug>[bot]' re-runs nothing")
    say(not evaluate(rr.get("if"), by("mallory", kind="User", app="acme-ai"), appvar), "[W] rerun: a person via the App re-runs nothing")
    say(not evaluate(rr.get("if"), by("acme-ai[bot]", app="other-ai"), appvar), "[W] rerun: the bot login through another App re-runs nothing")
    say(not evaluate(rr.get("if"), by("acme-ai[bot]"), appvar), "[W] rerun: the bot login with no App recorded re-runs nothing")
    say(not evaluate(rr.get("if"), dict(by("acme-ai[bot]", app="acme-ai"), event=dict(by("acme-ai[bot]", app="acme-ai")["event"],
                                                                                       issue={"number": 7, "draft": True, "pull_request": {}})),
                     appvar), "[W] rerun: the App's comment on a draft re-runs nothing")
    cond, depth, cut = str(rr.get("if", "")).strip(), 0, None
    for i, ch in enumerate(cond):   # the first top-level operand of the `&&` chain: a `(…)` group, whole
        depth += {"(": 1, ")": -1}.get(ch, 0)
        if depth == 0 and cond.startswith("&&", i):
            cut = i
            break
    first = cond[:cut].strip()
    closes = [i for i in range(len(first)) if first[:i + 1].count("(") == first[:i + 1].count(")")]
    say(first.startswith("(") and closes[:1] == [len(first) - 1] and "author_association" in first and "vars.PR_EVIDENCE_APP" in first
        and "event_name" not in first and "issue" not in first,
        "[W] rerun: the commenter (an association, or the App) is the first operand its if checks, one group")
    steps = rr.get("steps") or []
    say(not any("uses" in s for s in steps), "[W] rerun: no action at all (no checkout)")
    runs = "\n".join(s.get("run", "") for s in steps)
    say(not re.search(r"\.vibemaestro|\./|python3|bash |source |\$\{\{", runs),
        "[W] rerun: its script runs no repository file and interpolates no expression (values come through env)")
    say(rr.get("permissions") == {"actions": "write", "pull-requests": "read"}, "[W] rerun: actions: write and a read, nothing else")
    say(ev.get("permissions") == {"contents": "read", "pull-requests": "read", "issues": "read"}, "[W] evidence: read only")
    say(doc.get("permissions") == {"contents": "read"}, "[W] the workflow's own permissions are contents: read")
    say(all("write" not in str(j.get("permissions")) for n, j in jobs.items() if n != "rerun"), "[W] only rerun can write")
    co = [s for s in (ev.get("steps") or []) if "uses" in s]
    say(len(co) == 1 and co[0].get("with", {}).get("ref") == "${{ github.event.pull_request.base.ref }}"
        and co[0].get("with", {}).get("fetch-depth") == 0, "[W] evidence checks out the BASE, with history (for the patch-id)")
    evrun = "\n".join(s.get("run", "") for s in ev.get("steps") or [])
    say("--config-ref \"origin/$BASE_REF\"" in evrun, "[W] evidence reads the config at the base")
    env = {k: v for st in ev.get("steps") or [] for k, v in (st.get("env") or {}).items()}
    say(env.get("HEAD_SHA") == "${{ github.event.pull_request.head.sha }}" and '--head "$HEAD_SHA"' in evrun and '--base-ref "$BASE_REF"' in evrun,
        "[W] evidence judges the head and base of its own event (a re-run replays its event)")
    say('select(.name == "evidence")' in runs and "skipped" in runs, "[W] rerun: it picks the newest run whose evidence job did not skip")
    types = ((doc.get("on") or doc.get(True) or {}).get("pull_request") or {}).get("types") or []
    say("ready_for_review" in types, "[W] ready_for_review starts the round")


def main(argv):
    fam, plugin, scratch = argv
    globals()["fam_" + fam](plugin, scratch)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
