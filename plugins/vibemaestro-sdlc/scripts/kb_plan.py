#!/usr/bin/env python3
"""The multi-PR plan behind `kb.py plan status` and `kb.py check links`.

A plan (`kb/plans/<date>-<slug>.md`) is the one place a topic of two or more PRs is followed. It holds one row per PR in a
markdown table whose header names a row column and a link column (any other table is prose):

    | Row | Must be true | Acceptance | Depends on | Version | Model | Link |

    Row          a short id: letters, digits, `.`, `_`, `-` (`A`, `B1.1`, `13a`); `PR` is read as Row (older plans)
    Must be true one line; `Title` and `Delivers` are read as it (older plans)
    Depends on   row ids of the same plan, comma-separated; `—` for none
    Version      `<plugin> x.y.z`, comma-separated when the PR bumps several
    Link         `#N` (a PR), `intent/<slug>` (a branch), `kb/intent/<file>.md` (an intent), `dropped: <reason>`, or `—`

The row is written before its PR is dispatched and is never edited for status. The work links ITSELF to the row: its intent (and
spec) carry `plan: kb/plans/<file>.md#<row id>` in the frontmatter, and its PR is the one whose head branch is
`intent/<intent file stem>`. A PR is linked to a row only by that or by the row's own Link cell, never by a mention of the row id in
its title or body. So parallel PRs of one plan never touch the plan file, and the status is read, not written.

plan status <plan> [--json]
    Each row's state from GitHub: planned · intent open (issue and its state) · PR open (number, head, draft or ready, CI) ·
    merged (number, merge commit) · dropped (reason). Drift: two PRs for one row; the row's version differs from the manifest at
    the merge commit; a dependency not merged while its dependant is open; a dropped row with a merged PR. Intents are read from
    the working tree, at each PR head on an `intent/*` branch, and on the local `origin/intent/*` refs (as of the last fetch); a
    commit missing from the local object store is read with `gh api`. A `planned` row gets a note when an open or merged PR's title
    names it as `(row <id>)` and nothing links them (the state does not change). Without `gh` or network: the rows as the file says, the
    GitHub part labelled `not checked (<reason>)`, rc 0. Read-only: no write, no `git fetch`.

check links [--base REF | --all]
    The links between kb/ intents, specs and plans: a `plan:` resolves (file and row id); a spec's `Intent:` path exists and that
    intent names the spec (frontmatter `spec:` or the path in its text), and the reverse; an intent and its spec agree on `plan:`;
    in a plan, row ids are unique and well formed, `Depends on` ids exist, every `kb/…md` path in the rows and in `## Decisions`
    exists (a `#<row>` anchor on a plan path must be a row), and an intent in a Link cell names that row. A problem FAILS when its
    file or the file it points to changed against the merge base of REF (default `origin/HEAD`, else `origin/main`; the working
    tree and untracked kb/ files count); otherwise it is an `OLD` line. No base that resolves, or `--all`: every problem fails.

rc 0 done · 64 bad arguments · 65 check links failed · 66 the plan file cannot be read or has no row table.
Standard library only, Python 3.8+.
"""
import json
import os
import posixpath
import re
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kb_index  # noqa: E402

COLUMNS = {                                   # header words (lower case, parentheses dropped) → the column
    "row": "row", "pr": "row", "hàng": "row",
    "must be true": "must", "title": "must", "delivers": "must", "phải đúng": "must",
    "acceptance": "acceptance", "nghiệm thu": "acceptance",
    "depends on": "depends", "phụ thuộc": "depends",
    "version": "version", "phiên bản": "version",
    "model": "model",
    "link": "link", "liên kết": "link",
}
DECISIONS_RX = re.compile(r"\b(decisions?|quyết định)\b", re.I)   # a `## …` heading of owner decisions ("Decisions", "Owner decisions")
ROW_ID_RX = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
PLAN_REF_RX = re.compile(r"^(kb/plans/[^#\s]+\.md)#([A-Za-z0-9][A-Za-z0-9._-]*)$")
KB_PATH_RX = re.compile(r"(?:(?<=(?<!\.)\./)|(?<![\w/.-]))(kb/[A-Za-z0-9._/-]+?\.md)(?![A-Za-z0-9_/-]|\.[A-Za-z0-9])(#[A-Za-z0-9][A-Za-z0-9._-]*)?")
RAW_REL_RX = re.compile(r"(?<![\w/.-])((?:\.\./)+[A-Za-z0-9._/-]+?\.md)(?![A-Za-z0-9_/-]|\.[A-Za-z0-9])(#[A-Za-z0-9][A-Za-z0-9._-]*)?")
MD_LINK_RX = re.compile(r"\]\(\s*([^)\s#]+\.md)(#[A-Za-z0-9][A-Za-z0-9._-]*)?\s*\)")      # a relative markdown link `[x](../a.md)`
PR_RX = re.compile(r"(?<![\w#&/])#(\d+)\b")                               # `#N`, not `o/r#N`, not `…/#N` in a URL
PULL_RX = re.compile(r"https?://[^\s/]+/([^\s/]+/[^\s/]+)/pull/(\d+)\b")  # a PR URL: counted only when it is this repository's
BRANCH_RX = re.compile(r"(?<![\w/.-])(intent/[A-Za-z0-9._/-]+)")          # the whole token: no backtracking to a shorter prefix
VERSION_RX = re.compile(r"([A-Za-z][A-Za-z0-9_.-]*)\s+v?(\d+\.\d+\.\d+)\b")
DROPPED_RX = re.compile(r"^(?:dropped|bỏ)\b\s*:?\s*(.*)$", re.I)
NONE_CELL = ("", "—", "–", "-", "none", "không")
GH_TIMEOUT = 60
PR_LIMIT = 1000
CI_FAIL = {"FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "ERROR"}


# ── reading a plan ──────────────────────────────────────────────────────────────────────────────────
def _cells(line):
    """The cells of a markdown table line; `\\|` is a pipe inside a cell."""
    s = line.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|") and not s.endswith("\\|"):
        s = s[:-1]
    return [c.replace("\\|", "|").strip() for c in re.split(r"(?<!\\)\|", s)]


def _plain(cell):
    """A cell without markdown emphasis and code marks."""
    return re.sub(r"[*`]", "", cell).strip()


def _header_key(cell):
    return COLUMNS.get(re.sub(r"\(.*?\)", "", _plain(cell)).strip().lower())


def kb_paths(text, src=""):
    """[(repo path, anchor)] of the kb/ paths in `text`: written from the repo root (`kb/…`, `./kb/…`), or relative (a markdown
    link, or a path that starts with `../`) and resolved against the directory of `src`."""
    out = [(posixpath.normpath(p), a) for p, a in KB_PATH_RX.findall(text)]
    for t, a in MD_LINK_RX.findall(text) + RAW_REL_RX.findall(text):     # relative to the file: `[x](../a.md)`, `../a.md`
        if re.match(r"^[a-z]+:", t) or t.startswith("/"):
            continue
        q = posixpath.normpath(posixpath.join(posixpath.dirname(src), t)) if not t.startswith("kb/") else posixpath.normpath(t)
        if q.startswith("kb/") and (q, a) not in out:
            out.append((q, a))
    return out


def parse_link(cell, src=""):
    """{prs, pulls, branches, intents, dropped, empty} of a Link cell; `pulls` are (owner/repo, N) of PR URLs; `empty` is true when
    the cell is not `—`/`dropped:` and names no PR, branch or intent (a link the parser cannot read)."""
    plain = _plain(cell)
    m = DROPPED_RX.match(plain)
    seen = set()
    prs = [int(n) for n in PR_RX.findall(plain) if not (n in seen or seen.add(n))]
    pulls = [(o.lower(), int(n)) for o, n in PULL_RX.findall(plain)]
    branches = [b.rstrip(".") for b in BRANCH_RX.findall(plain) if not b.rstrip(".").endswith(".md")]
    intents = [p for p, _a in kb_paths(plain, src) if p.startswith("kb/intent/")]
    named = prs or pulls or branches or intents
    return {"prs": prs, "pulls": pulls, "branches": branches, "intents": intents,   # a dropped row still names its PR: a merge is drift
            "dropped": (m.group(1).strip() or "no reason written") if m else None,
            "empty": not named and not m and plain.split(" ")[0].lower() not in NONE_CELL}


def _ids(cell):
    p = _plain(cell)
    if p.lower() in NONE_CELL:
        return []
    return [x for x in re.split(r"[,\s]+", p) if x and x.lower() not in NONE_CELL]


def read_plan(root, rel):
    """{path, rows, problems, decision_lines} of a plan, or None when the file cannot be read. A row: {id, line, must, acceptance,
    depends, versions, model, link, cells}; problems: [(line, message)] of the table itself."""
    try:
        with open(os.path.join(root, *rel.split("/")), encoding="utf-8") as f:
            lines = f.read().split("\n")
    except (OSError, UnicodeDecodeError):
        return None
    rows, probs, decision_lines, head_lines, tables = [], [], [], [], 0
    fence, in_decisions, in_comment, seen_h2 = None, False, False, False
    flen = kb_index.front_block(lines)[1]
    i = flen
    while i < len(lines):
        ln = lines[i]
        if in_comment or re.match(r"^ {0,3}<!--", ln):              # an HTML comment block is not rendered: no rows, no links
            in_comment = "-->" not in ln
            i += 1
            continue
        fm = re.match(r"^ {0,3}(`{3,}|~{3,})", ln)
        if fm:
            fence = None if fence and fm.group(1)[0] == fence[0] and len(fm.group(1)) >= len(fence) else (fence or fm.group(1))
            i += 1
            continue
        if fence:
            i += 1
            continue
        h = re.match(r"^ {0,3}(#{1,6})\s+(.*?)\s*#*\s*$", ln)
        if h:
            if len(h.group(1)) == 2:
                in_decisions, seen_h2 = bool(DECISIONS_RX.search(h.group(2))), True
            i += 1
            continue
        if in_decisions:
            decision_lines.append((i + 1, ln))
        elif not seen_h2 and i >= flen:                               # the preamble: the plan's own Intent/Spec/Issue lines
            head_lines.append((i + 1, ln))
        nxt = lines[i + 1] if i + 1 < len(lines) else ""
        if ln.lstrip().startswith("|") and re.match(r"^\s*\|?\s*:?-{3,}", nxt):
            keys = [_header_key(c) for c in _cells(ln)]
            j = i + 2
            if "row" in keys and "link" in keys:
                tables += 1
                col = {}
                for n, k in enumerate(keys):
                    if k and k not in col:          # the first column of a kind wins
                        col[k] = n
                while j < len(lines) and lines[j].lstrip().startswith("|"):
                    cells = _cells(lines[j])
                    get = lambda k: cells[col[k]] if k in col and col[k] < len(cells) else ""  # noqa: E731
                    rid = _plain(get("row"))
                    if not ROW_ID_RX.match(rid):
                        probs.append((j + 1, "row id '%s' is not a short id (letters, digits, . _ -)" % rid))
                    else:
                        rows.append({"id": rid, "line": j + 1, "must": _plain(get("must")), "acceptance": get("acceptance"),
                                     "depends": _ids(get("depends")), "versions": VERSION_RX.findall(_plain(get("version"))),
                                     "model": _plain(get("model")), "link": parse_link(get("link"), rel), "cells": cells})
                    j += 1
            else:
                while j < len(lines) and lines[j].lstrip().startswith("|"):
                    j += 1
            i = j
            continue
        i += 1
    seen = {}
    for r in rows:
        if r["id"] in seen:
            probs.append((r["line"], "row id '%s' is used twice (first on line %d)" % (r["id"], seen[r["id"]])))
        else:
            seen[r["id"]] = r["line"]
    return {"path": rel, "rows": rows, "problems": probs, "decision_lines": decision_lines, "head_lines": head_lines, "tables": tables}


def parse_plan_ref(value):
    """(plan path, row id) of a `plan:` value, or None."""
    m = PLAN_REF_RX.match((value or "").strip())
    return (posixpath.normpath(m.group(1)), m.group(2)) if m else None


def _front(text):
    return kb_index.front_block(text.split("\n"))[0]


# ── git and gh, read-only ───────────────────────────────────────────────────────────────────────────
def _git(root, *args, data=None):
    try:
        r = subprocess.run(["git", "-C", root] + list(args), input=data, capture_output=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return 1, b""
    return r.returncode, r.stdout


def git_read_many(root, specs):
    """{"<rev>:<path>": text or None} for every spec, in one `git cat-file --batch` (None: no such object locally)."""
    out = {}
    if not specs:
        return out
    rc, data = _git(root, "cat-file", "--batch", data=("\n".join(specs) + "\n").encode())
    if rc != 0:
        return {s: None for s in specs}
    pos = 0
    for s in specs:
        nl = data.find(b"\n", pos)
        head = data[pos:nl].decode("utf-8", "replace")
        pos = nl + 1
        parts = head.split()
        if len(parts) == 3 and parts[1] == "blob":
            n = int(parts[2])
            out[s] = data[pos:pos + n].decode("utf-8", "replace")
            pos += n + 1
        else:
            out[s] = None
    return out


def git_has(root, sha):
    return bool(sha) and _git(root, "cat-file", "-e", sha + "^{commit}")[0] == 0


class GitHub:
    """The read-only calls `plan status` makes. `reason` is set when GitHub cannot be read at all (no gh, or the PR list failed);
    `errors` lists every later call that failed, so a status read in part says so instead of passing for checked."""

    def __init__(self, root):
        self.root, self.reason, self.errors, self.calls, self.down = root, None, [], 0, False
        self.gh = shutil.which("gh")
        if not self.gh:
            self.reason = "no gh on PATH"

    def _run(self, args):
        if self.reason or self.down:
            return None
        self.calls += 1
        env = {k: v for k, v in os.environ.items() if k not in ("GH_PAGER", "PAGER")}
        env["GH_PAGER"], env["NO_COLOR"] = "cat", "1"
        try:
            return subprocess.run([self.gh] + args, cwd=self.root, capture_output=True, text=True, timeout=GH_TIMEOUT, env=env)
        except (OSError, subprocess.SubprocessError) as e:
            self.down = True                      # one timeout is enough: every later call would wait as long
            self.errors.append("gh %s did not answer (%s); later calls skipped" % (" ".join(args[:2]), e.__class__.__name__))
            return None

    @staticmethod
    def _last(r):
        return (r.stderr.strip().splitlines() or ["rc %d" % r.returncode])[-1][:160]

    def json(self, args):
        """The parsed answer, or None with the failure in `errors`."""
        r = self._run(args)
        if r is None:
            return None
        if r.returncode != 0:
            self.errors.append("gh %s: %s" % (" ".join(args[:2]), self._last(r)))
            return None
        try:
            return json.loads(r.stdout or "null")
        except ValueError:
            self.errors.append("gh %s returned no JSON" % " ".join(args[:2]))
            return None

    def file_at(self, sha, path):
        """(text, read): the text of `path` at commit `sha` through the contents API. A 404 is (None, True), the file is absent; any
        other failure is (None, False), recorded in `errors`."""
        r = self._run(["api", "repos/{owner}/{repo}/contents/%s?ref=%s" % (path, sha), "-H", "Accept: application/vnd.github.raw"])
        if r is None:
            return None, False
        if r.returncode == 0:
            return r.stdout, True
        if "HTTP 404" in r.stderr or "Not Found" in r.stderr:
            return None, True
        self.errors.append("gh api %s at %s: %s" % (path, sha[:7], self._last(r)))
        return None, False


# ── plan status ─────────────────────────────────────────────────────────────────────────────────────
def ci_state(rollup):
    if not rollup:
        return "none"
    pending = False
    for c in rollup:
        concl = (c.get("conclusion") or "").upper()
        state = (c.get("state") or "").upper()
        status = (c.get("status") or "").upper()
        if concl in CI_FAIL or state in CI_FAIL:
            return "fail"
        if c.get("__typename") == "StatusContext" or ("state" in c and "status" not in c):   # a commit status
            pending = pending or state != "SUCCESS"
        elif status != "COMPLETED":                                                       # a check run
            pending = True
    return "pending" if pending else "pass"


def local_intents(root):
    """{path: frontmatter} of kb/intent/*.md in the working tree."""
    out = {}
    d = os.path.join(root, "kb", "intent")
    for n in sorted(os.listdir(d)) if os.path.isdir(d) else ():
        if n.endswith(".md"):
            try:
                with open(os.path.join(d, n), encoding="utf-8") as f:
                    out["kb/intent/" + n] = _front(f.read())
            except (OSError, UnicodeDecodeError):
                continue
    return out


def manifest_version(root, gh, sha, name):
    """The version `name` has at commit `sha`: its manifest's `version`, else (a manifest with none: the private kit) the released
    version its CHANGELOG.md records (the first `## ` heading when it is X.Y.Z); None when neither can be read."""
    cands = ["plugins/%s/.claude-plugin/plugin.json" % name, "plugins/vibemaestro-%s/.claude-plugin/plugin.json" % name,
             ".claude-plugin/plugin.json", "package.json"]
    logs = ["plugins/%s/CHANGELOG.md" % name, "plugins/vibemaestro-%s/CHANGELOG.md" % name]
    texts = git_read_many(root, ["%s:%s" % (sha, p) for p in cands + logs]) if git_has(root, sha) else {}
    read = lambda p: texts.get("%s:%s" % (sha, p)) if texts else gh.file_at(sha, p)[0]
    found = None
    for p in cands:
        t = read(p)
        if not t:
            continue
        try:
            m = json.loads(t)
        except ValueError:
            continue
        if isinstance(m, dict) and m.get("name") in (name, "vibemaestro-" + name):
            if m.get("version"):
                return str(m["version"])
            found = p
            break
    released = None
    if found and found.startswith("plugins/"):
        for line in (read(found.rsplit("/.claude-plugin/", 1)[0] + "/CHANGELOG.md") or "").split("\n"):
            if line.startswith("## "):
                v = line[3:].strip()
                released = v if re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", v) else None
                break
    return released if found else None


def status(root, rel, gh=None):
    """The status of the plan at `rel` as a dict (what `--json` prints), or None when it cannot be read."""
    plan = read_plan(root, rel)
    if plan is None:
        return None
    gh = gh or GitHub(root)
    ref_of = lambda r: "%s#%s" % (rel, r["id"])  # noqa: E731
    intents = {p: dict(fm, path=p, source="working tree") for p, fm in local_intents(root).items()}

    prs = gh.json(["pr", "list", "--state", "all", "--limit", str(PR_LIMIT), "--json",
                   "number,state,headRefName,headRefOid,mergeCommit,isDraft,url,title"])
    if prs is None:
        gh.reason = gh.reason or (gh.errors[-1] if gh.errors else "gh pr list failed")
    elif len(prs) >= PR_LIMIT:
        gh.errors.append("the PR list is capped at %d: older PRs were not read" % PR_LIMIT)
    by_branch, by_num, slug = {}, {}, None
    for p in prs or []:
        by_num[p["number"]] = p
        by_branch.setdefault(p.get("headRefName") or "", []).append(p)
        m = re.match(r"https?://[^/]+/([^/]+/[^/]+)/pull/\d+", p.get("url") or "")
        slug = slug or (m.group(1).lower() if m else None)
    ci, ci_read = {}, True
    n_open = sum(1 for p in prs or [] if p["state"] == "OPEN")
    if n_open:
        got = gh.json(["pr", "list", "--state", "open", "--limit", "200", "--json", "number,statusCheckRollup"])
        ci_read = got is not None and len(got) < 200           # a missing PR's CI is `not checked`, never `none`
        if got is not None and len(got) >= 200:
            gh.errors.append("the open-PR CI list is capped at 200")
        for c in got or []:
            ci[c["number"]] = ci_state(c.get("statusCheckRollup"))

    # intents that are not in the working tree: at each PR head (open) or merge commit (merged), then on origin/intent/* refs
    if prs is not None:
        want = []
        for p in prs:
            b = p.get("headRefName") or ""
            if not b.startswith("intent/") or p["state"] == "CLOSED":
                continue
            path = "kb/intent/%s.md" % b[len("intent/"):]
            if path in intents:
                intents[path].setdefault("pr", p["number"])
                continue
            sha = p["headRefOid"] if p["state"] == "OPEN" else (p.get("mergeCommit") or {}).get("oid")
            if sha:
                want.append((p, path, sha))
        local = git_read_many(root, ["%s:%s" % (sha, path) for _p, path, sha in want if git_has(root, sha)])
        for p, path, sha in want:
            key = "%s:%s" % (sha, path)
            text = local.get(key) if key in local else gh.file_at(sha, path)[0]
            if text is not None and path not in intents:
                intents[path] = dict(_front(text), path=path, pr=p["number"],
                                     source="PR #%d %s" % (p["number"], "head" if p["state"] == "OPEN" else "merge commit"))
    rc, out = _git(root, "for-each-ref", "--format=%(refname:short)", "refs/remotes/origin/intent/")
    refs = [r for r in out.decode().split() if r.startswith("origin/intent/")] if rc == 0 else []
    missing = [(r, "kb/intent/%s.md" % r[len("origin/intent/"):]) for r in refs]
    missing = [(r, p) for r, p in missing if p not in intents]
    for (r, p), text in zip(missing, git_read_many(root, ["%s:%s" % (r, p) for r, p in missing]).values()):
        if text is not None:
            intents[p] = dict(_front(text), path=p, source="%s (last fetch)" % r)

    back = {}
    for p, fm in intents.items():
        ref = parse_plan_ref(fm.get("plan"))
        if ref and ref[0] == rel:
            back.setdefault(ref[1], []).append(p)

    checked = prs is not None
    res_rows, drift, notes, issue_cache = [], [], [], {}
    for r in plan["rows"]:
        link = r["link"]
        linked = list(dict.fromkeys(link["intents"] + ["kb/intent/%s.md" % b[len("intent/"):] for b in link["branches"]]
                                    + back.get(r["id"], [])))
        row = {"id": r["id"], "line": r["line"], "must": r["must"], "depends": r["depends"],
               "version": ", ".join("%s %s" % v for v in r["versions"]), "model": r["model"],
               "intents": linked, "prs": [], "state": None, "notes": []}
        if not checked:
            row["state"] = "dropped" if link["dropped"] else "not checked"
            if link["dropped"]:
                row["reason"] = link["dropped"]
            row["prs"] = [{"number": n} for n in link["prs"]] + [{"number": n, "repo": o} for o, n in link["pulls"]]   # unverified
            res_rows.append(row)
            continue
        cands = {}
        for o, n in link["pulls"]:
            if slug and o == slug:
                link["prs"].append(n)
            else:
                row["notes"].append("a PR URL of another repository is not this row's PR: %s/pull/%d" % (o, n))
        for n in link["prs"]:
            if n in by_num:
                cands[n] = by_num[n]
            else:
                row["notes"].append("#%d is not a PR of this repository" % n)
        for p in linked:
            for pr in by_branch.get("intent/" + p[len("kb/intent/"):-3], []):
                cands[pr["number"]] = pr
        for p in back.get(r["id"], []):
            n = intents[p].get("pr")
            if n in by_num:
                cands[n] = by_num[n]
        merged = sorted((p for p in cands.values() if p["state"] == "MERGED"), key=lambda p: p["number"])
        opened = sorted((p for p in cands.values() if p["state"] == "OPEN"), key=lambda p: p["number"])
        for p in sorted(cands.values(), key=lambda p: p["number"]):
            row["prs"].append({"number": p["number"], "state": p["state"], "head": (p.get("headRefOid") or "")[:7],
                               "merge": ((p.get("mergeCommit") or {}).get("oid") or "")[:7], "draft": p.get("isDraft"),
                               "ci": ci.get(p["number"], "none" if ci_read else "not checked") if p["state"] == "OPEN" else None,
                               "url": p.get("url")})
            if p["state"] == "CLOSED":
                row["notes"].append("PR #%d closed unmerged" % p["number"])
        if link["dropped"]:
            row["state"], row["reason"] = "dropped", link["dropped"]
            if merged:
                drift.append("%s: dropped (%s) but PR #%d merged" % (r["id"], link["dropped"], merged[0]["number"]))
        elif merged:
            m = merged[-1]
            row.update(state="merged", pr=m["number"], merge=(m.get("mergeCommit") or {}).get("oid", ""))
            if len(merged) > 1:
                drift.append("%s: %d PRs merged for one row (%s)" % (r["id"], len(merged), ", ".join("#%d" % p["number"] for p in merged)))
            if opened:
                drift.append("%s: merged as #%d, and PR #%d is still open for it" % (r["id"], m["number"], opened[0]["number"]))
            got = []
            for name, want_v in r["versions"]:
                have = manifest_version(root, gh, row["merge"], name) if row["merge"] else None
                got.append({"plugin": name, "planned": want_v, "merged": have})
                if have is None:
                    row["notes"].append("%s version at the merge commit not checked (no manifest read)" % name)
                elif have != want_v:
                    drift.append("%s: planned %s %s, merged %s %s (#%d)" % (r["id"], name, want_v, name, have, m["number"]))
            row["versions"] = got
        elif opened:
            o = opened[-1]
            row.update(state="PR open", pr=o["number"], head=o.get("headRefOid", ""), draft=o.get("isDraft"),
                       ci=ci.get(o["number"], "none" if ci_read else "not checked"))
            if len(opened) > 1:
                drift.append("%s: %d PRs open for one row (%s)" % (r["id"], len(opened), ", ".join("#%d" % p["number"] for p in opened)))
        elif linked and any(p in intents for p in linked):
            row["state"] = "intent open"
            fm = intents[next(p for p in linked if p in intents)]
            num = str(fm.get("issue") or "").strip()
            if num.isdigit():
                if num not in issue_cache:
                    js = gh.json(["issue", "view", num, "--json", "state"])
                    issue_cache[num] = (js or {}).get("state", "not checked")
                row["issue"] = {"number": int(num), "state": issue_cache[num]}
                if issue_cache[num] == "CLOSED":
                    row["notes"].append("issue #%s is closed and no PR of the row merged" % num)
        else:
            row["state"] = "planned"
            if linked:
                row["notes"].append("linked intent not found: %s" % ", ".join(linked))
            # a hint, never a state: the title of an open or merged PR that names this row as `(row <id>)`, a row nothing links to
            title_rx = re.compile(r"\(row %s\)" % re.escape(r["id"]), re.I)
            for p in sorted(prs, key=lambda p: p["number"]):
                if p["state"] in ("OPEN", "MERGED") and title_rx.search(p.get("title") or ""):
                    row["notes"].append("PR #%d (%s) has a title that names this row, but the row does not link it: write its number in the Link cell"
                                        % (p["number"], p["state"].lower()))
        if len(back.get(r["id"], [])) > 1:
            row["notes"].append("%d intents name this row: %s" % (len(back[r["id"]]), ", ".join(back[r["id"]])))
        res_rows.append(row)

    if checked:
        st = {x["id"]: x["state"] for x in res_rows}
        for x in res_rows:
            if x["state"] in ("intent open", "PR open"):
                for d in x["depends"]:
                    if d not in st:
                        drift.append("%s depends on %s, which is not a row of this plan" % (x["id"], d))
                    elif st[d] != "merged":
                        drift.append("%s is %s but its dependency %s is %s" % (x["id"], x["state"], d, st[d]))
    for line, msg in plan["problems"]:
        notes.append("line %d: %s" % (line, msg))
    return {"plan": rel, "rows": res_rows, "drift": drift, "notes": notes, "tables": plan["tables"],
            "github": ("not checked (%s)" % gh.reason if not checked else "checked (%d PRs read)" % len(prs) if not gh.errors
                       else "partly checked (%d PRs read; %d call(s) failed: %s)" % (len(prs), len(gh.errors), gh.errors[0])),
            "github_errors": list(gh.errors),
            "github_checked": checked}


def render(st):
    n = len(st["rows"])
    out = ["%s: %d row%s · GitHub: %s" % (st["plan"], n, "" if n == 1 else "s", st["github"])]
    w = max([len(r["id"]) for r in st["rows"]] + [3])
    for r in st["rows"]:
        s = r["state"]
        if s == "merged":
            vs = "".join(" · %s %s%s" % (v["plugin"], v["merged"] or v["planned"] + " (not checked)",
                                          "" if v["merged"] in (None, v["planned"]) else " ≠ planned " + v["planned"])
                         for v in r.get("versions", []))
            detail = "#%d %s%s" % (r["pr"], r["merge"][:7], vs)
        elif s == "PR open":
            detail = "#%d head %s · %s · CI %s" % (r["pr"], r["head"][:7], "draft" if r.get("draft") else "ready", r.get("ci") or "none")
        elif s == "intent open":
            iss = r.get("issue")
            detail = ", ".join(r["intents"][:1]) + (" · issue #%d %s" % (iss["number"], iss["state"].lower()) if iss else "")
        elif s == "dropped":
            detail = r.get("reason", "")
        elif s == "not checked":
            known = ["#%d" % p["number"] for p in r["prs"]] + r["intents"]
            detail = ", ".join(known) if known else "no link written"
        else:
            detail = ("depends on " + ", ".join(r["depends"])) if r["depends"] else ""
        what = kb_index.cut(r["must"], 60)
        out.append("  %-*s  %-11s  %s%s" % (w, r["id"], s, detail, ("  — " + what) if what else ""))
        for n in r["notes"]:
            out.append("  %-*s  note: %s" % (w, "", n))
    if st["drift"]:
        out.append("drift (%d):" % len(st["drift"]))
        out.extend("  - " + d for d in st["drift"])
    elif st["github_checked"] and not st["github_errors"]:
        out.append("drift: none")
    elif st["github_checked"]:
        out.append("drift: none found, but GitHub was read only in part: a state or drift may be missing")
    for e in st["github_errors"]:
        out.append("not checked: " + e)
    for n in st["notes"]:
        out.append("note: " + n)
    return "\n".join(out)


# ── check links ─────────────────────────────────────────────────────────────────────────────────────
def _read(root, rel):
    try:
        with open(os.path.join(root, *rel.split("/")), encoding="utf-8") as f:
            return f.read()
    except (OSError, UnicodeDecodeError):
        return None


def _line_of(text, needle, default=1):
    for i, ln in enumerate(text.split("\n"), 1):
        if needle in ln:
            return i
    return default


def _docs(root, sub):
    d = os.path.join(root, "kb", sub)
    return ["kb/%s/%s" % (sub, n) for n in sorted(os.listdir(d)) if n.endswith(".md")] if os.path.isdir(d) else []


def link_problems(root):
    """[(file, line, message, [files it points to])] over kb/intent, kb/specs and kb/plans."""
    probs = []
    plans = {}

    def plan_of(p):
        if p not in plans:
            plans[p] = read_plan(root, p) if os.path.isfile(os.path.join(root, *p.split("/"))) else None
        return plans[p]

    def check_ref(src, text, key, value):
        ref = parse_plan_ref(value)
        ln = _line_of(text, key + ":")
        if not ref:
            probs.append((src, ln, "%s: '%s' is not kb/plans/<file>.md#<row id>" % (key, value), []))
            return None
        pl = plan_of(ref[0])
        if pl is None:
            probs.append((src, ln, "%s: %s does not exist" % (key, ref[0]), [ref[0]]))
        elif ref[1] not in {r["id"] for r in pl["rows"]}:
            probs.append((src, ln, "%s: %s has no row '%s'" % (key, ref[0], ref[1]), [ref[0]]))
        return ref

    texts = {}
    for p in _docs(root, "intent") + _docs(root, "specs") + _docs(root, "plans"):
        texts[p] = _read(root, p) or ""
    fronts = {p: _front(t) for p, t in texts.items()}

    def names(src, path):
        """`src` names `path`: in its frontmatter `spec:`, or as a path in its text (whole path, `./` or a relative link)."""
        return path in kb_index.paths_of(fronts[src].get("spec")) or path in {q for q, _a in kb_paths(texts[src], src)}

    for p in _docs(root, "intent") + _docs(root, "specs"):
        t, fm = texts[p], fronts[p]
        for k in fm:
            if k != k.lower() and k.lower() in ("plan", "spec", "issue"):
                probs.append((p, _line_of(t, k + ":"), "frontmatter key '%s' must be written '%s'" % (k, k.lower()), []))
        if fm.get("plan"):
            check_ref(p, t, "plan", fm["plan"])
    for p in _docs(root, "intent"):
        t, fm = texts[p], fronts[p]
        for s in kb_index.paths_of(fm.get("spec")):
            ln = _line_of(t, "spec:")
            if s not in texts:
                probs.append((p, ln, "spec: %s does not exist" % s, [s]))
            elif not names(s, p):
                probs.append((p, ln, "spec: %s does not name this intent back (its Intent: line)" % s, [s]))
    for s in _docs(root, "specs"):
        t = texts[s]
        for m in re.finditer(r"(?m)^[*_ ]*Intent:[*_ ]*(.*)$", t):
            ln = t[:m.start()].count("\n") + 1
            for ip, _a in kb_paths(m.group(1), s):
                if not ip.startswith("kb/intent/"):
                    continue
                if ip not in texts:
                    probs.append((s, ln, "Intent: %s does not exist" % ip, [ip]))
                    continue
                if not names(ip, s):
                    probs.append((s, ln, "Intent: %s does not name this spec (add `spec: %s` to its frontmatter)" % (ip, s), [ip]))
                a, b = parse_plan_ref(fronts[ip].get("plan")), parse_plan_ref(fronts[s].get("plan"))
                if a and b and a != b:
                    probs.append((s, _line_of(t, "plan:"), "plan: %s#%s, but its intent %s says %s#%s" % (b + (ip,) + a), [ip]))
                elif b and not a:
                    probs.append((s, _line_of(t, "plan:"), "plan: is in the spec but not in its intent %s, which is what "
                                  "plan status reads: add `plan: %s#%s` to the intent" % ((ip,) + b), [ip]))
    for p in _docs(root, "plans"):
        pl = plan_of(p)
        if pl is None:
            continue
        ids = {r["id"] for r in pl["rows"]}
        for ln, msg in pl["problems"]:
            probs.append((p, ln, msg, []))
        lines = [(r["line"], " | ".join(r["cells"])) for r in pl["rows"]] + pl["decision_lines"] + pl["head_lines"]
        for r in pl["rows"]:
            if r["link"]["empty"]:
                probs.append((p, r["line"], "row %s: its Link cell names no PR (#N), branch (intent/…) or intent (kb/intent/…), "
                              "and is not — or dropped:" % r["id"], []))
            for d in r["depends"]:
                if d not in ids:
                    probs.append((p, r["line"], "row %s depends on '%s', which is not a row of this plan" % (r["id"], d), []))
            for ip in r["link"]["intents"]:
                if ip in texts:
                    ref = parse_plan_ref(fronts[ip].get("plan"))
                    if ref != (p, r["id"]):
                        probs.append((p, r["line"], "row %s links %s, whose plan: is '%s', not %s#%s"
                                      % (r["id"], ip, fronts[ip].get("plan", ""), p, r["id"]), [ip]))
        for ln, text in lines:
            for q, anchor in kb_paths(_plain(text), p):
                if not os.path.isfile(os.path.join(root, *q.split("/"))):
                    probs.append((p, ln, "%s does not exist" % q, [q]))
                elif anchor and q.startswith("kb/plans/"):
                    tp = plan_of(q)
                    if tp is not None and anchor[1:] not in {x["id"] for x in tp["rows"]}:
                        probs.append((p, ln, "%s has no row '%s'" % (q, anchor[1:]), [q]))
    return probs


def changed_files(root, base):
    """(set of changed repo paths or None for 'every file', label of the base)."""
    refs = [base] if base else ["origin/HEAD", "origin/main"]
    for ref in refs:
        rc, sha = _git(root, "rev-parse", "--verify", "--quiet", ref + "^{commit}")
        if rc == 0:
            break
    else:
        return None, "no base (%s does not resolve)" % " or ".join(refs)
    sha = sha.decode().strip()
    rc, mb = _git(root, "merge-base", sha, "HEAD")
    mb = mb.decode().strip() if rc == 0 and mb.strip() else sha
    rc1, diff = _git(root, "diff", "--name-only", "--no-renames", mb)
    rc2, new = _git(root, "ls-files", "--others", "--exclude-standard", "--", "kb")
    if rc1 or rc2:
        return None, "git diff against %s failed" % ref
    return set(diff.decode().split("\n")) | set(new.decode().split("\n")) - {""}, "%s (merge base %s)" % (ref, mb[:7])


def check_links(root, base=None, all_=False):
    probs = link_problems(root)
    changed, label = (None, "--all") if all_ else changed_files(root, base)
    fails = olds = 0
    for src, ln, msg, targets in sorted(probs, key=lambda x: (x[0], x[1])):
        hard = changed is None or src in changed or any(t in changed for t in targets)
        fails += hard
        olds += not hard
        sys.stdout.write("%s %s:%d: %s\n" % ("FAIL" if hard else "OLD ", src, ln, msg))
    sys.stdout.write("links: %d failing, %d in unchanged files · base: %s\n" % (fails, olds, label))
    return 65 if fails else 0


# ── command line (called by kb.py) ──────────────────────────────────────────────────────────────────
USAGE = "kb.py plan status <plan file> [--json] | kb.py check links [--base REF | --all]"


def main(root, cmd, args):
    if cmd == "plan":
        if not args or args[0] != "status":
            return kb_index._die("usage: " + USAGE, 64)
        pos = [a for a in args[1:] if a != "--json"]
        if len(pos) != 1 or any(a.startswith("--") and a != "--json" for a in args[1:]):
            return kb_index._die("usage: " + USAGE, 64)
        full = os.path.realpath(pos[0] if os.path.isabs(pos[0]) else os.path.join(os.getcwd(), pos[0]))
        rel = os.path.relpath(full, root).replace(os.sep, "/")
        st = status(root, rel)
        if st is None:
            return kb_index._die("cannot read %s" % pos[0], 66)
        if not st["tables"]:
            return kb_index._die("%s has no row table (a header with Row and Link columns)" % rel, 66)
        sys.stdout.write((json.dumps(st, ensure_ascii=False, indent=1) if "--json" in args else render(st)) + "\n")
        return 0
    if cmd == "links":
        base, all_, i = None, False, 0
        while i < len(args):
            if args[i] == "--all":
                all_, i = True, i + 1
            elif args[i] == "--base" and i + 1 < len(args):
                base, i = args[i + 1], i + 2
            else:
                return kb_index._die("usage: " + USAGE, 64)
        if all_ and base:
            return kb_index._die("--base and --all exclude each other (usage: %s)" % USAGE, 64)
        return check_links(root, base, all_)
    return kb_index._die("usage: " + USAGE, 64)
