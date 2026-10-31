#!/usr/bin/env python3
"""Gate: the PR carries an AI review pinned to its CURRENT head and, when it changes UI paths, E2E evidence pinned to it too.

Evidence lives in PR comments (the round comments the rule pr-body-shape asks for). A comment counts when:
  - its author's association is OWNER, MEMBER or COLLABORATOR (anyone can comment on a public PR), or its author is the bot
    account of the App `evidence.trusted_app` names (read at the BASE): login `<slug>[bot]`, type Bot, and posted through
    that App (`performed_via_github_app.slug`). No user login can hold `[` or `]`, and GitHub writes all three from the token
    that posted; the last one alone is not enough, as a person posting through the App with their own token carries it too;
  - after fenced code blocks and HTML comments are removed (gate_common.strip_fences), its first line is `tokens.round_comment_prefix`
    followed by a full 40-hex SHA: `SHA: <sha> — review round 2 (fresh-context Opus)`. A short SHA never counts.
What a counted comment can hold:
  - an AI review: its first line also holds the word `review` and a round number (`commits.round_pattern`);
  - an E2E line: `E2E pass`, or `E2E not run: <reason>`, or the same line in Vietnamese ("khong chay" with its accents: the regex below spells it with escapes) with a reason of at least 15 characters.
For each kind the newest such comment (by when it was posted) decides. It passes when its SHA is the head, or when it carries over: the
SHA is an ancestor of the head, every commit after it that is not on the base is a clean merge (no conflict resolved by hand), and `git diff $(git merge-base <base>
<sha>) <sha> | git patch-id --verbatim` is the same non-empty id at the SHA and at the head (a pure merge of the base,
whitespace counted). Any change of the PR's own after the evidence is a new head that needs evidence of its own.

E2E is asked only when a changed path (a renamed file's old path included) matches a glob of `evidence.ui_paths`, read at the BASE
(`--config-ref`); null means the repo has no UI. A file list at the API's cap (3000 files) counts as touching UI.

This checks a declaration pinned to the head, not who wrote the review: a member can still post a comment without having reviewed.

    pr_evidence.py --pr N --repo OWNER/NAME --head SHA --base REF --base-ref NAME --config-ref REF [--cwd DIR]
        the head and the base name come from the run's event (a re-run replays it); the base ref is what the PR's own changes
        are measured against (origin/<base>)
    pr_evidence.py --facts FILE [--config-ref REF] [--cwd DIR]      the same decision on recorded facts (tests): JSON {head, files,
                                                                     capped, comments, base, carry: {sha: [patch-id, why]}}
Exit codes: 0 pass, 1 red, 2 could not conclude, 64 bad usage, 65 invalid config. Standard library only, Python 3.8+.
"""
import json
import os
import re
import subprocess
import sys
import unicodedata

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import gate_common as gc  # noqa: E402
import messages  # noqa: E402  (found beside sdlc_config.py, where gate_common put it on the path)

TRUSTED = ("OWNER", "MEMBER", "COLLABORATOR")
FILES_CAP = 3000
MIN_REASON = 15
E2E_PASS = re.compile(r"^ {0,3}E2E pass(?![\w/?-])", re.M | re.I)
E2E_SKIP = re.compile(r"^ {0,3}E2E (?:kh\u00f4ng ch\u1ea1y|not run):[ \t]*(.*)$", re.M | re.I)
NAME = "pr-evidence"


def say(text):
    sys.stdout.write("%s: %s\n" % (NAME, text))


SCRIPT = re.compile(r"<script\b.*?(?:</script\s*>|\Z)", re.I | re.S)   # GitHub renders nothing of a script element


def visible(body):
    """The text a reader sees: line ends as LF, NFC, script elements, fenced blocks and HTML comments removed."""
    text = unicodedata.normalize("NFC", (body or "").replace("\r\n", "\n").replace("\r", "\n"))
    return gc.strip_fences(SCRIPT.sub(lambda m: "\n" * m.group(0).count("\n"), text))


def first_line(body):
    for ln in visible(body).split("\n"):
        if ln.strip():
            return ln.strip()
    return ""


def pinned(c, prefix):
    """(full sha or None, short sha or None) of a comment's first line."""
    ln = first_line(c.get("body"))
    if not ln.startswith(prefix):
        return None, None
    rest = ln[len(prefix):].lstrip()
    m = re.match(r"([0-9a-fA-F]{40})\b", rest)
    if m:
        return m.group(1).lower(), None
    m = re.match(r"([0-9a-fA-F]{7,39})\b", rest)
    return None, (m.group(1).lower() if m else None)


def is_review(c, cfg):
    ln = first_line(c.get("body"))
    plain = gc.sdlc_config.round_plain(ln)
    return bool(re.search(r"\breview\b", plain, re.I)) and bool(re.search(cfg["commits"]["round_pattern"], plain))


def e2e_of(c):
    """None, ('pass', ''), or ('skip', reason) for the E2E line of a comment (the last one in it wins)."""
    text = visible(c.get("body"))
    found = []
    for m in E2E_PASS.finditer(text):
        found.append((m.start(), ("pass", "")))
    for m in E2E_SKIP.finditer(text):
        found.append((m.start(), ("skip", m.group(1).strip())))
    return max(found)[1] if found else None


def reason_len(reason):
    """The characters of a reason a reader sees: no spaces and no format characters (a zero-width space is not a reason)."""
    return sum(1 for ch in reason if not ch.isspace() and unicodedata.category(ch) != "Cf")


def app_posted(c, app):
    """True when the comment was posted by the bot account of the App `app` itself (Bot `<app>[bot]`, through `app`)."""
    return (bool(app) and c.get("author_type") == "Bot" and (c.get("app") or "").lower() == app
            and (c.get("author") or "").lower() == app + "[bot]")


def ui_hits(files, capped, globs):
    if globs is None:
        return None
    if capped:
        return ["(%d files or more: the list is cut, counted as UI)" % FILES_CAP]
    hits = []
    for f in files:
        for p in (f.get("filename"), f.get("previous_filename")):
            if p and any(gc.sdlc_config.glob_match(g, p) for g in globs):
                hits.append(p)
                break
    return hits


def decide(facts, cfg):
    """(rc, lines). `facts`: head, files, capped, comments [{url, author, author_type, app, association, body, created_at, id}], base (its name, for
    messages), carry(sha) -> (patch-id or None, why): the shared patch-id when evidence at `sha` carries over to the head."""
    head = (facts.get("head") or "").lower()
    if not re.fullmatch(r"[0-9a-f]{40}", head):
        raise gc.Infra("the PR's head SHA is unknown")
    prefix = cfg["tokens"]["round_comment_prefix"]
    lines, red = [], False
    app = cfg["evidence"].get("trusted_app")
    trusted, ignored = [], []
    if facts.get("base_moved"):
        return gc.RED, ["✗ base: %s" % facts["base_moved"]]
    for c in sorted(facts.get("comments") or [], key=lambda c: (c.get("created_at") or "", c.get("id") or 0)):
        sha, short = pinned(c, prefix)
        if sha is None and short is None:
            continue
        if c.get("association") not in TRUSTED and not app_posted(c, app):
            ignored.append(c)
            continue
        trusted.append((c, sha, short))
    for c in ignored:
        why = ""
        if c.get("author_type") == "Bot" or c.get("app"):
            why = ("; of an App, only the bot of evidence.trusted_app counts: %s[bot], posted through %s" % (app, app) if app else
                   "; evidence.trusted_app is not set, so no App counts")
        lines.append("ignored: %s (author %s is %s%s)" % (c.get("url"), c.get("author"), c.get("association"), why))
    base = facts.get("base") or "the base"

    def judge(kind, pick, missing, fix):
        nonlocal red
        cands = [(c, sha, short) for c, sha, short in trusted if pick(c)]
        if not cands:
            red = True
            lines.append("✗ %s: %s" % (kind, missing))
            return None
        c, sha, short = cands[-1]
        if sha is None:
            red = True
            lines.append("✗ %s: %s starts \"%s %s\"; only the full 40-hex head counts (rule pr-body-shape)" % (kind, c.get("url"), prefix, short))
            return None
        if sha == head:
            return c, "pins the head %s" % head
        pid, why = facts["carry"](sha)
        if pid:
            return c, "carried from %s: the PR's own changes are identical (patch-id %s), the head adds only merges of %s" % (sha, pid[:12], base)
        red = True
        lines.append("✗ %s: the latest %s (%s) pins %s; the head is %s, and %s. %s" % (kind, "AI-review comment" if kind == "review" else
                                                                                      "E2E line", c.get("url"), sha, head, why, fix))
        return None

    got = judge("review", lambda c: is_review(c, cfg),
                "no AI-review comment pins the head %s. After a fresh-context review of this head, post a comment whose first line is "
                "\"%s %s — review round N (<model>)\"." % (head, prefix, head),
                "Review the head again and post its round comment.")
    if got:
        lines.append("review ok: %s %s" % (got[0].get("url"), got[1]))
    hits = ui_hits(facts.get("files") or [], facts.get("capped"), cfg["evidence"]["ui_paths"])
    if hits is None:
        lines.append("e2e not required: evidence.ui_paths is not set")
    elif not hits:
        lines.append("e2e not required: no changed path matches evidence.ui_paths")
    else:
        shown = ", ".join(hits[:3]) + (", +%d more" % (len(hits) - 3) if len(hits) > 3 else "")
        got = judge("e2e", lambda c: e2e_of(c) is not None,
                    messages.text("pe.e2e_missing", cfg["language"], shown, head),
                    "Run E2E on the head, or state why not, in a comment pinned to it.")
        if got:
            kind, reason = e2e_of(got[0])
            if kind == "skip" and reason_len(reason) < MIN_REASON:
                red = True
                lines.append(messages.text("pe.e2e_short", cfg["language"], MIN_REASON, got[0].get("url")))
            else:
                lines.append("e2e ok: %s (%s) %s" % (got[0].get("url"), "pass" if kind == "pass" else "not run: " + reason, got[1]))
    return (gc.RED if red else gc.OK), lines


# ── the real facts ───────────────────────────────────────────────────────────────────────────────────────────────────────
def gh_json(args):
    try:
        p = subprocess.run(["gh"] + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise gc.Infra("gh could not run: %s" % e)
    if p.returncode != 0:
        raise gc.Infra("gh %s failed: %s" % (args[1] if len(args) > 1 else "", p.stderr.decode("utf-8", "replace").strip()[:160]))
    try:
        return json.loads(p.stdout.decode("utf-8", "replace"))
    except ValueError:
        raise gc.Infra("gh printed no JSON")


def pages(path):
    """Every item of a paginated list (`--paginate --slurp` gives a list of pages)."""
    data = gh_json(["api", "--paginate", "--slurp", path])
    if not isinstance(data, list) or not all(isinstance(p, list) for p in data):
        raise gc.Infra("gh api %s did not print pages of a list" % path.split("?")[0])
    return [x for p in data for x in p]


def carry_fn(cwd, base, head):
    """carry(sha) -> (patch-id or None, why). Evidence pinned to `sha` carries over to `head` only when `sha` is an ancestor of the
    head, every commit between them that is not on the base is a merge, each such merge is the clean merge of its two parents
    (no conflict resolved by hand, no edit), and `git diff $(git merge-base base X) X | git patch-id --verbatim` (whitespace
    counts) is the same non-empty id for both: the head adds merges of the base and nothing of its own."""
    ids, cache = {}, {}

    def pid(sha):
        if sha in ids:
            return ids[sha]
        rc, mb, _err = gc.git(["merge-base", base, sha], cwd)
        rc2, diff, _err = gc.git(["diff", "--binary", mb.strip(), sha], cwd, binary=True) if rc == 0 and mb.strip() else (1, b"", "")
        if rc2 != 0 or not diff:
            ids[sha] = None
            return None
        p = subprocess.run(["git", "patch-id", "--verbatim"], input=diff, cwd=cwd, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE)
        out = p.stdout.decode("ascii", "replace").split()
        ids[sha] = out[0] if p.returncode == 0 and out else None
        return ids[sha]

    def unclean_merge(sha):
        """None when every merge after `sha` is a clean merge of its two parents (its tree is what `git merge-tree` makes of
        them), else why: a conflict resolution or an edit in a merge can move the PR's own change unseen by a patch-id."""
        rc, merges, _err = gc.git(["rev-list", "--merges", "%s..%s" % (sha, head), "--not", base], cwd)
        if rc != 0:
            return "the merges after %s cannot be listed" % sha[:12]
        for m in merges.split():
            rc, parents, _err = gc.git(["rev-list", "--parents", "-n", "1", m], cwd)
            ps = parents.split()[1:]
            if rc != 0:
                return "the merge %s cannot be read" % m[:12]
            if len(ps) != 2:
                return "the merge %s has %d parents: only a two-parent merge of the base carries evidence" % (m[:12], len(ps))
            rc, tree, _err = gc.git(["merge-tree", "--write-tree", "--no-messages", ps[0], ps[1]], cwd)
            mine = gc.git(["rev-parse", m + "^{tree}"], cwd)[1].strip()
            if rc != 0 or tree.split()[:1] != [mine]:
                return ("the merge %s is not a clean merge of its parents (a conflict resolution, an edit, or a git without "
                        "merge-tree --write-tree): the evidence does not carry over it" % m[:12])
        return None

    def carry(sha):
        if sha in cache:
            return cache[sha]
        if gc.git(["cat-file", "-e", sha + "^{commit}"], cwd)[0] != 0:
            gc.git(["fetch", "--no-tags", "-q", "origin", sha], cwd)
        if gc.git(["merge-base", "--is-ancestor", sha, head], cwd)[0] != 0:
            res = (None, "%s is not an ancestor of the head (not fetched, or rewritten since)" % sha[:12])
        else:
            rc, own, _err = gc.git(["rev-list", "--no-merges", "%s..%s" % (sha, head), "--not", base], cwd)
            mine, theirs = pid(sha), pid(head)
            dirty = None if rc != 0 or own.strip() else unclean_merge(sha)
            if rc != 0 or own.strip():
                res = (None, "the head adds commits of its own since %s (%s)" % (sha[:12], ", ".join(x[:12] for x in own.split()[:3])))
            elif dirty:
                res = (None, dirty)
            elif not mine or not theirs:
                res = (None, "the PR's own changes cannot be read at %s" % (sha[:12] if not mine else "the head"))
            elif mine != theirs:
                res = (None, "the PR's own changes differ since then (patch-id %s → %s)" % (mine[:12], theirs[:12]))
            else:
                res = (mine, "")
        cache[sha] = res
        return res
    return carry


def live_facts(pr, repo, base, cwd, head, base_name):
    """The facts of the PR, for the head and base the run's event names (a re-run replays its event: it must not judge another
    head, or read the config of a base the PR has left)."""
    data = gh_json(["api", "repos/%s/pulls/%s" % (repo, pr)])
    live_base = ((data.get("base") or {}).get("ref") or "") if isinstance(data, dict) else ""
    moved = None
    if base_name and live_base != base_name:
        moved = ("this run read the config and the gate of %s, but the PR's base is now %s: the run of the new base's event decides"
                 % (base_name, live_base or "unknown"))
    files = pages("repos/%s/pulls/%s/files?per_page=100" % (repo, pr))
    comments = pages("repos/%s/issues/%s/comments?per_page=100" % (repo, pr))
    return {"head": head, "files": files, "capped": len(files) >= FILES_CAP, "carry": carry_fn(cwd, base, head),
            "base": base_name or base, "base_moved": moved,
            "comments": [{"url": c.get("html_url"), "author": (c.get("user") or {}).get("login"), "id": c.get("id"),
                          "author_type": (c.get("user") or {}).get("type"),
                          "app": (c.get("performed_via_github_app") or {}).get("slug"),
                          "association": c.get("author_association"), "body": c.get("body") or "",
                          "created_at": c.get("created_at")} for c in comments if isinstance(c, dict)]}


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    opts, i = {}, 0
    while i < len(argv):
        k = argv[i]
        if k in ("--pr", "--repo", "--config-ref", "--base", "--cwd", "--facts", "--head", "--base-ref") and i + 1 < len(argv):
            opts[k], i = argv[i + 1], i + 2
        else:
            opts = None
            break
    live = opts is not None and all(k in opts for k in ("--pr", "--repo", "--base", "--head")) and "--facts" not in opts
    if opts is None or not (live or ("--facts" in opts and not any(k in opts for k in ("--pr", "--repo", "--base")))):
        sys.stderr.write("usage: pr_evidence.py --pr N --repo OWNER/NAME --base REF --head SHA [--base-ref NAME] [--config-ref REF] [--cwd DIR] | "
                         "--facts FILE [--config-ref REF] [--cwd DIR]\n")
        return gc.USAGE
    cwd = opts.get("--cwd", ".")
    cfg = gc.load_config(cwd, opts.get("--config-ref"))
    if live:
        facts = live_facts(opts["--pr"], opts["--repo"], opts["--base"], cwd, opts["--head"].lower(), opts.get("--base-ref"))
    else:
        try:
            with open(opts["--facts"], encoding="utf-8") as f:
                facts = json.load(f)
        except (OSError, ValueError) as e:
            raise gc.Infra("cannot read the facts: %s" % e.__class__.__name__)
        carries = facts.get("carry") or {}
        facts["carry"] = lambda sha: tuple(carries.get(sha) or (None, "not carried in these facts"))
    rc, lines = decide(facts, cfg)
    for ln in lines:
        say(ln)
    return rc


if __name__ == "__main__":
    sys.exit(gc.run_gate(NAME, main))
