#!/usr/bin/env python3
"""The multi-PR plan behind `kb.py plan status` and `kb.py check links`.

A plan (`kb/plans/<date>-<slug>.md`) is the one place a topic of two or more PRs is followed. It holds one row per PR in a
markdown table whose header names a row column and a link column (any other table is prose):

    | Row | Must be true | Acceptance | Depends on | Version | Model | Link |

    Row          a short id: letters, digits, `.`, `_`, `-` (`A`, `B1.1`, `13a`); `PR` is read as Row (older plans)
    Must be true one line; `Title` and `Delivers` are read as it (older plans)
    Depends on   row ids of the same plan, comma-separated; `—` for none
    Version      `<plugin> x.y.z`, comma-separated when the PR bumps several
    Current state @SHA   optional (the plan's recon; the header must hold `@`): one line ending in `@<sha>`, the `origin/main` it
                 was read at; `—` for none
    Shared files         optional: repo-root paths, `,` or `;` between them, that another row or an open PR touches too; `(merge main)` marks a row
                 that runs in parallel and merges main before it is ready
    Link         `#N` (a PR), `intent/<slug>` (a branch), `kb/intent/<file>.md` (an intent), `dropped: <reason>`, or `—`

The row is written before its PR is dispatched and is never edited for status. The work links ITSELF to the row: its intent (and
spec) carry `plan: kb/plans/<file>.md#<row id>` in the frontmatter, and its PR is the one whose head branch is
`intent/<intent file stem>`, or `intent/<key>-<slug>` when the intent's frontmatter says `key: <key>` (`issue.code`). A PR is linked to a row only by that or by the row's own Link cell, never by a mention of the row id in
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
    exists (a `#<row>` anchor on a plan path must be a row), and an intent in a Link cell names that row. In a table with the recon
    columns: a Current state cell that is not `—` holds `@<7-40 hex>`, and two rows (not dropped) that share a file are ordered
    through `Depends on` (either way, transitively) or one of the two marks it `merge main`. A problem FAILS when its
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
import sdlc_config  # noqa: E402

COLUMNS = {                                   # header words (lower case, parentheses dropped) → the column
    "row": "row", "pr": "row", "hàng": "row",
    "must be true": "must", "title": "must", "delivers": "must", "phải đúng": "must",
    "acceptance": "acceptance", "nghiệm thu": "acceptance",
    "depends on": "depends", "phụ thuộc": "depends",
    "version": "version", "phiên bản": "version",
    "model": "model",
    "current state": "current", "hiện trạng": "current",
    "shared files": "shared", "file chung": "shared",
    "trust touches": "touches",
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
SHA_RX = re.compile(r"@([0-9a-f]{7,40})\b", re.I)                                # the recon SHA of a Current state cell
MERGE_MAIN_RX = re.compile(r"\(?\s*merge main\s*\)?", re.I)
DROPPED_RX = re.compile(r"^(?:dropped|bỏ)\b\s*:?\s*(.*)$", re.I)
NONE_CELL = ("", "—", "–", "-", "none", "không")
GH_TIMEOUT = 60
PR_LIMIT = 1000
PR_ARGS = ["pr", "list", "--state", "all", "--limit", str(PR_LIMIT), "--json",
           "number,state,headRefName,headRefOid,mergeCommit,isDraft,url,title,labels"]
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


def _header_word(cell):
    """A header cell's words: plain, its parentheses and `@…` dropped, lower case."""
    return re.sub(r"\(.*?\)|@\S*", "", _plain(cell)).strip().lower()


def _header_key(cell):
    k = COLUMNS.get(_header_word(cell))
    return None if k == "current" and "@" not in cell else k     # `Current state` without `@SHA`: an older plan's own column


def header_keys(header):
    """The column kinds of a table's header cells. `Title` reads as the Must be true column (an earlier plan's) only when no other
    header is one; beside a Delivers or Must be true column it is the row's own short title."""
    keys = [_header_key(c) for c in header]
    if any(k == "must" and _header_word(c) != "title" for k, c in zip(keys, header)):
        keys = ["title" if k == "must" and _header_word(c) == "title" else k for k, c in zip(keys, header)]
    return keys


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


def _shared(cell):
    """(paths, merge main) of a Shared files cell."""
    p = _plain(cell)
    mm = bool(MERGE_MAIN_RX.search(p))
    p = MERGE_MAIN_RX.sub("", p)
    return [x for x in (y.strip() for y in re.split(r"[,;]", p)) if x and x.lower() not in NONE_CELL], mm


def read_plan(root, rel):
    """{path, rows, problems, decision_lines} of a plan, or None when the file cannot be read. A row: {id, line, must, acceptance,
    depends, versions, model, link, cells, cols, current_cell, current, shared, merge_main, touches, header, link_col}; `current`
    is {sha, text} or None, `cols` the column kinds its table has, `touches` the Trust touches cell as written (None without the
    column), `title` the Title cell as written (None without it), `header` its table's header cells, `link_col` the index of its Link cell; problems: [(line, message)] of the table
    itself; focus: its frontmatter's `focus:` (None without one)."""
    try:
        with open(os.path.join(root, *rel.split("/")), encoding="utf-8") as f:
            return read_plan_text(f.read(), rel)
    except (OSError, UnicodeDecodeError):
        return None


def read_plan_text(text, rel):
    """read_plan of a plan's text (as read at a commit through the API)."""
    lines = text.split("\n")
    rows, probs, decision_lines, head_lines, tables = [], [], [], [], 0
    fence, in_decisions, in_comment, seen_h2 = None, False, False, False
    front, flen = kb_index.front_block(lines)
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
            header = _cells(ln)
            keys = header_keys(header)
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
                        cur = _plain(get("current"))
                        sha = SHA_RX.search(cur)
                        shared, mm = _shared(get("shared"))
                        rows.append({"id": rid, "line": j + 1, "must": _plain(get("must")), "acceptance": get("acceptance"),
                                     "depends": _ids(get("depends")), "versions": VERSION_RX.findall(_plain(get("version"))),
                                     "model": _plain(get("model")), "link": parse_link(get("link"), rel), "cells": cells,
                                     "cols": set(col), "current_cell": cur,
                                     "current": {"sha": sha.group(1), "text": cur} if sha else None,
                                     "shared": shared, "merge_main": mm,
                                     "touches": get("touches") if "touches" in col else None,
                                     "title": get("title") if "title" in col else None,
                                     "header": header, "link_col": col["link"]})
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
    return {"path": rel, "rows": rows, "problems": probs, "decision_lines": decision_lines, "head_lines": head_lines, "tables": tables,
            "focus": front.get("focus") or None}


def parse_plan_ref(value):
    """(plan path, row id) of a `plan:` value, or None."""
    m = PLAN_REF_RX.match((value or "").strip())
    return (posixpath.normpath(m.group(1)), m.group(2)) if m else None


def _front(text):
    return kb_index.front_block(text.split("\n"))[0]


# ── trust touches: what a row declares it changes in the trust layer (plan-approved merges, gates/merge_guard.py `touches`) ──
# the kinds a path touch may name: `other` is one exact path (and object) no gate judged otherwise, `test` test data by its path
TOUCH_KINDS = ("script", "baton", "workflow", "rbac", "admission", "vault-policy", "config", "other", "test")
TOUCH_OBJECT_KINDS = ("rbac", "admission", "vault-policy")     # these name the rendered object <Kind>/<namespace or ->/<name>
# what judges a later PR, whatever a repository's config adds (judges): the floor, never covered by a plan signature
TOUCH_JUDGES = (".vibemaestro/sdlc.json", ".vibemaestro/risk-tier.yaml")
TOUCH_JUDGE_DIRS = (".vibemaestro/gates/",)
TOUCH_REPO_RX = re.compile(r"^([A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9_.-]+):(.+)$")
TOUCH_PATH_RX = re.compile(r"^[^\x00-\x20\x7f*?\[\]{}\\:]+$")             # exact: no glob, space, control or backslash
TOUCH_OBJECT_RX = re.compile(r"^[A-Za-z][A-Za-z0-9]*/(?:-|[a-z0-9][a-z0-9.-]*)/[A-Za-z0-9][A-Za-z0-9.:_-]*$")
TOUCH_OTHER_OBJECT_RX = re.compile(r"^[^\x00-\x20\x7f]+(?: [^\x00-\x20\x7f]+)?$")   # risk-tier's label `<group/Kind> <ns/name>` or a key
TOUCH_WORD_RX = re.compile(r"^[a-z][a-z-]*$")
TOUCH_RUN_RX = re.compile(r"^(?:kit|project):[a-z0-9][a-z0-9._-]*$")      # a reviewed baton: never user:, a session file or a kind:
TOUCH_RUNS_RX = re.compile(r"\sruns:\s*(\S*)\s*$")
TOUCH_PRS_RX = re.compile(r"^PRs:\s*(\S*)$")
TOUCH_AGAIN = "(signs again)"
TOUCH_COUNT_MAX = 20                                           # `PRs: <n>` and `runs: <n>`: 1 to this, 1 when absent
PLUGIN_DIR = ".claude-plugin"
# test data by its path (risk-tier's rule less what reads the content): no agent instruction file or directory, no secret-file name
TEST_DIRS = ("tests", "test")
TEST_AGENT_MD = ("claude", "agents", "agent", "gemini", "qwen", "crush", "skill")
TEST_AGENT_DIRS = ("skills", "agents", "commands", "rules", "prompts", "hooks")


def plugin_path(path):
    """True when a path has a `.claude-plugin` segment at any depth, its case ignored (and the trailing dots and spaces a Windows
    disk drops): a marketplace or plugin manifest, which chooses the code every machine installs. The floor."""
    return any(s.rstrip(" .").casefold() == PLUGIN_DIR for s in path.split("/"))


def test_data_path(path):
    """True when `path` is test data by its path alone: a directory segment exactly `tests` or `test`, no `templates` or `batons`
    one above it, no dot segment, not `*.sh`, Markdown or an agent file, not under an agent directory, not a secret-file name
    (as risk-tier's rule names them). Other test code is test data too, as risk-tier reads it. A path ending in `/` is a
    directory, read as a file directly inside it."""
    segs = (path + "x" if path.endswith("/") else path).split("/")
    low = [s.casefold() for s in segs]
    return (any(s in TEST_DIRS for s in segs[:-1]) and "templates" not in low[:-1] and "batons" not in low[:-1]
            and not any(s.startswith(".") for s in segs) and not low[-1].endswith((".sh", ".md", ".markdown", ".mdx"))
            and low[-1].split(".")[0] not in TEST_AGENT_MD and not any(s in TEST_AGENT_DIRS for s in low[:-1])
            and not any(".sops." in s or s.endswith(".sops") or "kubeconfig" in s for s in low))


def _count(text, what):
    """(n, problem) of a `PRs:` or `runs:` value: 1 to TOUCH_COUNT_MAX."""
    ok = re.fullmatch(r"[1-9][0-9]?", text or "") and int(text) <= TOUCH_COUNT_MAX
    return (int(text), None) if ok else (None, "%s: a count of 1 to %d" % (what, TOUCH_COUNT_MAX))


def parse_cell(cell, repo):
    """({touches, prs}, problems) of a Trust touches cell: None for no cell (empty or `—`); {[], 1} for `none`; else one item per
    `;`, each a touch `<kind> [<owner/repo>:]<path> [<object>] [Stops: <words>]`, `run <kit:name or project:name> Stops: <words>
    [runs: <n>]` or `PRs: <n>` (the row's PRs, 1 when absent); a touch may end in `(signs again)`. A touch is {kind, repo, path,
    object, stops, runs, again}: repo defaults to the plan's `repo`; stops None or the words as baton's stops_of joins them (sorted,
    `, `); object None, <Kind>/<namespace or ->/<name>, or for `other` the exact object of its finding; runs the count of a run
    touch, else None; a `test` path may end in `/` (every file under that directory). A path with a `.claude-plugin` segment is
    refused unless marked `(signs again)`. Which Stops words exist, and the rest of the floor, are baton's to judge."""
    p = (cell or "").replace("`", "").strip()                         # not _plain: a `*` is a glob here, never emphasis
    if p in ("", "—", "–", "-"):
        return None, []
    if p.lower() == "none":
        return {"touches": [], "prs": 1}, []
    out, probs, prs = [], [], None
    for raw in p.split(";"):
        t = raw.strip()
        again = t.endswith(TOUCH_AGAIN)
        t = t[:-len(TOUCH_AGAIN)].strip() if again else t
        pm = TOUCH_PRS_RX.match(t)
        if pm:
            n, why = _count(pm.group(1), "PRs")
            why = why or ("PRs is given twice" if prs is not None else "PRs takes no mark" if again else None)
            if why:
                probs.append("%s: %s" % (raw.strip(), why))
            prs = prs or n
            continue
        rm = TOUCH_RUNS_RX.search(t)
        if rm:
            t = t[:rm.start()]
        head, sep, words = t.partition("Stops:")
        ws = head.split()
        if not ws:
            probs.append("an empty touch in %r" % p)
            continue
        kind = ws[0]
        if kind not in TOUCH_KINDS + ("run",):
            probs.append("%s: the kind is none of %s" % (raw.strip(), ", ".join(TOUCH_KINDS + ("run",))))
            continue
        m = TOUCH_REPO_RX.match(ws[1]) if len(ws) > 1 and kind != "run" else None
        where, path = (m.group(1), m.group(2)) if m else (repo, ws[1] if len(ws) > 1 else "")
        obj = " ".join(ws[2:]) or None
        stops = sorted(set(w.strip() for w in words.split(",") if w.strip())) if sep else None
        runs, why = None, []
        if kind == "run":
            if not TOUCH_RUN_RX.match(path):
                why.append("a run touch names one kit: or project: baton, never a user: baton, a session file or a kind:")
            runs, w = _count(rm.group(1), "runs") if rm else (1, None)
            why += [w] if w else []
        elif rm:
            why.append("only a run touch names runs")
        segs = (path[:-1] if kind == "test" and path.endswith("/") else path).split("/")
        if kind != "run" and (not path or not TOUCH_PATH_RX.match(path) or path.startswith("/") or path == "-"
                              or any(s in ("", ".", "..") for s in segs)):
            why.append("the path is exact and relative: no glob, space, `:`, `.` or `..` part, never `-`")
        elif kind == "test" and not test_data_path(path):
            why.append("test names test data: a path under a `tests` or `test` directory (no templates, batons, dot or agent "
                       "directory above it; not *.sh, Markdown, an agent or a secret-file name), or such a directory ending in `/`")
        if kind in TOUCH_OBJECT_KINDS:
            if obj is None or not TOUCH_OBJECT_RX.match(obj):
                why.append("%s names one object <Kind>/<namespace or ->/<name>" % kind)
        elif kind == "other":
            if obj is not None and not TOUCH_OTHER_OBJECT_RX.match(obj):
                why.append("other names one path and at most one object (a rendered object's `<group/Kind> <ns/name>`, a key)")
        elif obj is not None:
            why.append("only %s and other name an object" % ", ".join(TOUCH_OBJECT_KINDS))
        if (kind in ("baton", "run")) != (stops is not None) or (stops is not None and not (stops and all(TOUCH_WORD_RX.match(w) for w in stops))):
            why.append("a %s touch names its Stops: <words> (stop words, none%s)" % (kind, " or removed" if kind == "baton" else "")
                       if kind in ("baton", "run") else "only a baton or run touch names Stops")
        if kind != "run" and plugin_path(path) and not again:
            why.append("a .claude-plugin path is the floor (it chooses the code every machine installs): mark it %s" % TOUCH_AGAIN)
        if why:
            probs.append("%s: %s" % (raw.strip(), "; ".join(why)))
        else:
            out.append({"kind": kind, "repo": where, "path": path, "object": obj, "stops": ", ".join(stops) if stops else None,
                        "runs": runs, "again": again})
    return {"touches": out, "prs": prs or 1}, probs


def parse_touches(cell, repo):
    """(touches, problems) of a Trust touches cell, as parse_cell reads it: touches None for no cell."""
    c, probs = parse_cell(cell, repo)
    return (c["touches"] if c is not None else None), probs


def row_cells(row):
    """A plan row's cells but its Link cell, each [its column's header, the cell]: what a plan signature binds of the row."""
    head = row["header"]
    return [[head[i] if i < len(head) else "", c] for i, c in enumerate(row["cells"]) if i != row["link_col"]]


def plan_refs(doc):
    """((intent path, spec path), problems) of a parsed plan: the one `kb/intent/` path after `Intent:` and the one `kb/specs/`
    path after `Spec:` on its preamble line(s)."""
    text = " ".join(ln for _n, ln in doc.get("head_lines") or [])
    out, probs = [], []
    for key, d in (("Intent", "kb/intent/"), ("Spec", "kb/specs/")):
        m = re.search(r"\b%s:([^·]*)" % key, text)
        got = list(dict.fromkeys(q for q, _a in kb_paths(m.group(1), doc.get("path") or "") if q.startswith(d))) if m else []
        if len(got) != 1:
            probs.append("the plan's preamble names %d %s path(s) after `%s:`, not one" % (len(got), d, key))
        out.append(got[0] if len(got) == 1 else None)
    return tuple(out), probs


# a spec's acceptance criteria: the `## ` section `kb.py check spec` requires, by the name each language preset gives it
# shortcut: not a repo's own tokens.spec.criteria; read the plan repository's config when one renames it
CRITERIA_HEADINGS = tuple(sdlc_config.effective({"language": lang})["tokens"]["spec"]["criteria"] for lang in sdlc_config.LANGUAGES)


def criteria(text):
    """The numbered items of a spec's acceptance criteria section, each item's lines joined by one space; [] when none."""
    items, inside, fence = [], False, False
    for ln in text.split("\n"):
        if re.match(r"^\s*(```|~~~)", ln):                         # a heading inside a fence, anywhere, is an example
            fence = not fence
        h = None if fence else re.match(r"^##?\s+(.*?)(?:\s+#+)?\s*$", ln)
        if h:
            inside = ln.startswith("## ") and h.group(1).strip().casefold() in [c.casefold() for c in CRITERIA_HEADINGS]
            continue
        if not inside:
            continue
        m = None if fence else re.match(r"^ {0,3}\d+[.)]\s+(.*)$", ln)
        if m:
            items.append(m.group(1).strip())
        elif items and ln.strip():
            items[-1] += " " + ln.strip()
    return items


def touch_kind(path):
    """The kind of a changed path the merge guard denies, by a fixed table; `judges` and a `.claude-plugin` segment come first
    (the floor, whatever this says), and rbac, admission and vault-policy come only from a touch check's findings."""
    parents = [s.casefold() for s in path.split("/")[:-1]]          # a baton directory as signing-rules finds one
    if "batons" in parents or any(parents[i:i + 2] == ["templates", "baton-kinds"] for i in range(len(parents))):
        return "baton"
    if path.startswith((".github/workflows/", ".github/actions/")):
        return "workflow"
    if path.startswith(".vibemaestro/"):
        return "config"
    if path.endswith(".sh"):
        return "script"
    return "test" if test_data_path(path) else "other"


def judges(cfg):
    """The paths that judge a later PR under a repository's config (parsed, effective or as written; None for none): the config,
    each `external:` adapter, the planner's script and inputs, every merge.touch_inputs workflow and path, and TOUCH_JUDGES."""
    cfg = cfg if isinstance(cfg, dict) else {}
    m = cfg.get("merge") if isinstance(cfg.get("merge"), dict) else {}
    reg = (m.get("image_bump") or {}).get("registry") if isinstance(m.get("image_bump"), dict) else None
    out = set(TOUCH_JUDGES)
    for spec in ((cfg.get("ci") or {}).get("backend") if isinstance(cfg.get("ci"), dict) else None,
                 reg.get("backend") if isinstance(reg, dict) else None):
        if isinstance(spec, str) and spec.startswith("external:"):
            out.add(spec[len("external:"):])
    pl = m.get("planner") if isinstance(m.get("planner"), dict) else {}
    named = [pl.get("script")] + list(pl.get("inputs") or [])
    for v in (m.get("touch_inputs") or {}).values() if isinstance(m.get("touch_inputs"), dict) else ():
        if isinstance(v, dict):
            named += [v.get("workflow")] + list(v.get("paths") or [])
    return set(posixpath.normpath(p) for p in out.union(x for x in named if isinstance(x, str) and x))


def is_judge(path, judged):
    """True when `path` judges a later PR, its case ignored: a deny glob matches whatever the case, and a checkout on a
    case-insensitive disk reads `.vibemaestro/SDLC.json` as the config."""
    p = path.casefold()
    return p in set(j.casefold() for j in judged) or p.startswith(tuple(d.casefold() for d in TOUCH_JUDGE_DIRS))


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
    `errors` lists every later call that failed, so a status read in part says so instead of passing for checked. `repo`
    (owner/name) reads that repository instead of the one at `root`; a JSON answer is read once per set of arguments."""

    def __init__(self, root, repo=None):
        self.root, self.reason, self.errors, self.calls, self.down = root, None, [], 0, False
        self.repo, self.memo = repo, {}
        self.gh = shutil.which("gh")
        if not self.gh:
            self.reason = "no gh on PATH"

    def _run(self, args):
        if self.reason or self.down:
            return None
        if self.repo:
            args = [a.replace("{owner}/{repo}", self.repo) for a in args] if args[0] == "api" else args[:2] + ["-R", self.repo] + args[2:]
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
        key = tuple(args)
        if key not in self.memo:
            self.memo[key] = self._json(args)
        return self.memo[key]

    def _json(self, args):
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

    def tree(self, *dirs):
        """{path: text} of the files of each directory at the head of `repo`'s default branch, in one GraphQL call; None when it
        fails. A directory that does not exist reads as empty."""
        owner, name = self.repo.split("/", 1)
        q = "query($o:String!,$n:String!){repository(owner:$o,name:$n){%s}}" % " ".join(
            'd%d:object(expression:"HEAD:%s"){...on Tree{entries{name object{...on Blob{text}}}}}' % (i, d) for i, d in enumerate(dirs))
        got = self.json(["api", "graphql", "-f", "query=" + q, "-f", "o=" + owner, "-f", "n=" + name])
        repo = ((got or {}).get("data") or {}).get("repository")
        if repo is None:
            if got is not None:
                self.errors.append("gh api graphql: %s has no repository %s" % (" ".join(dirs), self.repo))
            return None
        return {"%s/%s" % (d, e["name"]): (e.get("object") or {}).get("text")
                for i, d in enumerate(dirs) for e in ((repo.get("d%d" % i) or {}).get("entries") or [])}


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


# ── key branches (`issue.code`): `intent/<key>-<slug>` is the intent kb/intent/<date>-<slug>.md whose frontmatter says `key: <key>` ──
KEY_RX = re.compile(r"^[A-Z]{3}-[1-9][0-9]*$")
KEY_BRANCH_RX = re.compile(r"^([A-Z]{3}-[1-9][0-9]*)-(.+)$")
DATE_STEM_RX = re.compile(r"^\d{4}-\d{2}-\d{2}-")


def branch_names(path, fm):
    """The branch names (after `intent/`) of the intent at `path`: its stem, and `<key>-<slug>` when its `key:` is a key."""
    stem = path[len("kb/intent/"):-len(".md")]
    key = str(fm.get("key") or "").strip()
    return [stem] + (["%s-%s" % (key, DATE_STEM_RX.sub("", stem, count=1))] if KEY_RX.match(key) else [])


def key_candidates(names, rest):
    """The kb/intent paths among `names` whose stem, less its date, is the slug of the key branch `rest` (`<key>-<slug>`); [] when
    `rest` is not one. A candidate is that intent only when its `key:` says the same key (branch_names)."""
    m = KEY_BRANCH_RX.match(rest)
    return [n for n in names if n.startswith("kb/intent/") and n.endswith(".md")
            and DATE_STEM_RX.sub("", n[len("kb/intent/"):-3], count=1) == m.group(2)] if m else []


def intent_of_branch(root, rest):
    """The kb/intent path in the working tree of the branch `intent/<rest>` (any prefix): `kb/intent/<rest>.md`, else the intent
    whose `key:` names the branch; None when neither."""
    if os.path.isfile(os.path.join(root, "kb", "intent", rest + ".md")):
        return "kb/intent/%s.md" % rest
    d = os.path.join(root, "kb", "intent")
    for p in key_candidates(["kb/intent/" + n for n in sorted(os.listdir(d))] if os.path.isdir(d) else [], rest):
        try:
            with open(os.path.join(root, p), encoding="utf-8") as f:
                if rest in branch_names(p, _front(f.read())):
                    return p
        except (OSError, UnicodeDecodeError):
            continue
    return None


def intent_names_at(root, gh, rev):
    """The kb/intent/ paths at commit `rev`: `git ls-tree` when it is local, else the contents API."""
    if git_has(root, rev):
        rc, out = _git(root, "ls-tree", "--name-only", rev, "--", "kb/intent/")
        return out.decode("utf-8", "replace").split("\n") if rc == 0 else []
    got = gh.json(["api", "repos/{owner}/{repo}/contents/kb/intent?ref=%s" % rev])
    return ["kb/intent/" + x["name"] for x in got if isinstance(x, dict) and isinstance(x.get("name"), str)] if isinstance(got, list) else []


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


def gather_intents(root, gh, prs, src=None):
    """{path: frontmatter + path, source (+ pr)} of every intent: in the working tree (`src`, {path: text} read from another
    repository's default branch, in its place), at each PR head (open) or merge commit (merged) of an `intent/` branch, then on
    origin/intent/* refs (this repository only)."""
    base = local_intents(root) if src is None else {p: _front(t or "") for p, t in src.items()
                                                    if p.startswith("kb/intent/") and p.endswith(".md")}
    intents = {p: dict(fm, path=p, source="working tree" if src is None else "default branch") for p, fm in base.items()}
    named = lambda: {b: p for p, fm in sorted(intents.items()) for b in branch_names(p, fm)}  # noqa: E731
    # a key branch's intent is found by listing kb/intent/ at that commit (key_candidates) and reading the one whose `key:` names it
    if prs is not None:
        want, local_named = [], named()
        for p in prs:
            b = p.get("headRefName") or ""
            if not b.startswith("intent/") or p["state"] == "CLOSED":
                continue
            rest = b[len("intent/"):]
            if rest in local_named:
                intents[local_named[rest]].setdefault("pr", p["number"])
                continue
            sha = p["headRefOid"] if p["state"] == "OPEN" else (p.get("mergeCommit") or {}).get("oid")
            if sha:
                keyed = key_candidates(intent_names_at(root, gh, sha), rest) if KEY_BRANCH_RX.match(rest) else []
                want.extend((p, rest, path, sha) for path in ["kb/intent/%s.md" % rest] + keyed)
        local = git_read_many(root, ["%s:%s" % (sha, path) for _p, _r, path, sha in want if git_has(root, sha)])
        for p, rest, path, sha in want:
            key = "%s:%s" % (sha, path)
            text = local.get(key) if key in local else gh.file_at(sha, path)[0]
            fm = _front(text) if text is not None else None
            if fm is not None and path not in intents and rest in branch_names(path, fm):
                intents[path] = dict(fm, path=path, pr=p["number"],
                                     source="PR #%d %s" % (p["number"], "head" if p["state"] == "OPEN" else "merge commit"))
    if src is not None:
        return intents
    rc, out = _git(root, "for-each-ref", "--format=%(refname:short)", "refs/remotes/origin/intent/")
    refs = [r for r in out.decode().split() if r.startswith("origin/intent/")] if rc == 0 else []
    known = named()
    missing = [(r, rest, p) for r in refs for rest in [r[len("origin/intent/"):]] if rest not in known
               for p in ["kb/intent/%s.md" % rest] + (key_candidates(intent_names_at(root, gh, r), rest) if KEY_BRANCH_RX.match(rest) else [])]
    for (r, rest, p), text in zip(missing, git_read_many(root, ["%s:%s" % (r, p) for r, _rest, p in missing]).values()):
        fm = _front(text) if text is not None else None
        if fm is not None and p not in intents and rest in branch_names(p, fm):
            intents[p] = dict(fm, path=p, source="%s (last fetch)" % r)
    return intents


def status(root, rel, gh=None, src=None):
    """The status of the plan at `rel` as a dict (what `--json` prints), or None when it cannot be read. `src`: {path: text} of
    another repository's kb at its default branch (gh then reads that repository), in place of the working tree."""
    plan = read_plan(root, rel) if src is None else read_plan_text(src[rel], rel) if src.get(rel) is not None else None
    if plan is None:
        return None
    gh = gh or GitHub(root)

    prs = gh.json(PR_ARGS)
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

    intents = gather_intents(root, gh, prs, src)

    back = {}
    for p, fm in intents.items():
        ref = parse_plan_ref(fm.get("plan"))
        if ref and ref[0] == rel:
            back.setdefault(ref[1], []).append(p)

    checked = prs is not None
    res_rows, drift, notes, issue_cache = [], [], [], {}
    intent_of = {b: p for p, fm in sorted(intents.items()) for b in branch_names(p, fm)}
    for r in plan["rows"]:
        link = r["link"]
        linked = list(dict.fromkeys(link["intents"] + [intent_of.get(b[len("intent/"):], "kb/intent/%s.md" % b[len("intent/"):])
                                                       for b in link["branches"]] + back.get(r["id"], [])))
        row = {"id": r["id"], "line": r["line"], "must": r["must"], "depends": r["depends"],
               "version": ", ".join("%s %s" % v for v in r["versions"]), "model": r["model"],
               "intents": linked, "prs": [], "state": None, "notes": [],
               "current": r["current"], "shared": r["shared"], "merge_main": r["merge_main"],
               "jira": next((str(intents[p]["jira"]) for p in linked if p in intents and intents[p].get("jira")), None)}   # shown, never synced
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
            for b in branch_names(p, intents.get(p, {})):
                for pr in by_branch.get("intent/" + b, []):
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
            detail = " · ".join(([("depends on " + ", ".join(r["depends"]))] if r["depends"] else [])
                                + (["@" + r["current"]["sha"][:7]] if r.get("current") else []))
        detail += " · jira %s" % r["jira"] if r.get("jira") else ""
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
        deps = {r["id"]: r["depends"] for r in pl["rows"]}

        def reach(a, b):
            """row `a` depends on row `b`, directly or through other rows."""
            todo, seen = list(deps.get(a, [])), set()
            while todo:
                x = todo.pop()
                if x == b:
                    return True
                if x not in seen:
                    seen.add(x)
                    todo.extend(deps.get(x, []))
            return False

        live = [r for r in pl["rows"] if "shared" in r["cols"] and not r["link"]["dropped"]]
        for n, a in enumerate(live):
            for b in live[n + 1:]:
                for f in [f for f in a["shared"] if f in b["shared"]]:
                    if a["merge_main"] or b["merge_main"]:
                        continue
                    if not (reach(a["id"], b["id"]) or reach(b["id"], a["id"])):
                        probs.append((p, b["line"], "rows %s and %s share %s but neither depends on the other: order them in "
                                      "Depends on, or mark one `(merge main)` in Shared files" % (a["id"], b["id"], f), []))
        for r in pl["rows"]:
            if r["link"]["empty"]:
                probs.append((p, r["line"], "row %s: its Link cell names no PR (#N), branch (intent/…) or intent (kb/intent/…), "
                              "and is not — or dropped:" % r["id"], []))
            for d in r["depends"]:
                if d not in ids:
                    probs.append((p, r["line"], "row %s depends on '%s', which is not a row of this plan" % (r["id"], d), []))
            if ("current" in r["cols"] and r["current"] is None and _plain(r["current_cell"]).lower() not in NONE_CELL
                    and not r["link"]["dropped"]):
                probs.append((p, r["line"], "row %s: its Current state cell is not pinned to a SHA (@<sha> of origin/main when it "
                              "was read)" % r["id"], []))
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


def merge_base(root, base=None):
    """(merge-base commit or None, the ref it came from or why there is none): of REF (default `origin/HEAD`, else
    `origin/main`) and HEAD, the ref's own commit when they share none. The one base `check links` and `check spec` judge by."""
    refs = [base] if base else ["origin/HEAD", "origin/main"]
    for ref in refs:
        rc, sha = _git(root, "rev-parse", "--verify", "--quiet", ref + "^{commit}")
        if rc == 0:
            break
    else:
        return None, "no base (%s does not resolve)" % " or ".join(refs)
    sha = sha.decode().strip()
    rc, mb = _git(root, "merge-base", sha, "HEAD")
    return (mb.decode().strip() if rc == 0 and mb.strip() else sha), ref


def changed_files(root, base):
    """(set of changed repo paths or None for 'every file', label of the base)."""
    mb, ref = merge_base(root, base)
    if mb is None:
        return None, ref
    rc1, diff = _git(root, "diff", "--name-only", "--no-renames", mb)
    rc2, new = _git(root, "ls-files", "--others", "--exclude-standard", "--", "kb")
    if rc1 or rc2:
        return None, "git diff against %s failed" % ref
    return set(diff.decode().split("\n")) | set(new.decode().split("\n")) - {""}, "%s (merge base %s)" % (ref, mb[:7])


def check_links(root, base=None, all_=False, trace=None, guard=None):
    """`trace(plan path, base)` → ([(line, message)], story): the AC trace of a changed plan, red for a story plan; any other plan only
    warns, once, so an older plan on main never turns red. `guard(intent path, base)` → [message]: red lines of an intent changed
    in the change (kb.py: an AC of a story changed without the owner's word)."""
    probs = link_problems(root)
    changed, label = (None, "--all") if all_ else changed_files(root, base)
    fails = olds = 0
    for src, ln, msg, targets in sorted(probs, key=lambda x: (x[0], x[1])):
        hard = changed is None or src in changed or any(t in changed for t in targets)
        fails += hard
        olds += not hard
        sys.stdout.write("%s %s:%d: %s\n" % ("FAIL" if hard else "OLD ", src, ln, msg))
    for p in _docs(root, "plans") if trace else ():
        found, story = trace(p, base) if changed is None or p in changed else ([], False)
        for ln, msg in found if story else ():
            sys.stdout.write("FAIL %s:%d: plan trace: %s\n" % (p, ln, msg))
            fails += 1
        if found and not story:
            sys.stdout.write("WARNING %s:%d: plan trace: %d finding(s), the first: %s (not a story plan: nothing red; "
                             "kb.py check plan lists them)\n" % (p, found[0][0], len(found), found[0][1]))
    for p in _docs(root, "intent") if guard and changed is not None else ():
        for msg in guard(p, base) if p in changed else ():
            sys.stdout.write("FAIL %s:1: %s\n" % (p, msg))
            fails += 1
    sys.stdout.write("links: %d failing, %d in unchanged files · base: %s\n" % (fails, olds, label))
    return 65 if fails else 0


# ── command line (called by kb.py) ──────────────────────────────────────────────────────────────────
USAGE = "kb.py plan status <plan file> [--json] | kb.py check plan <plan file> | kb.py check links [--base REF | --all]"


def main(root, cmd, args, trace=None, guard=None):
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
        return check_links(root, base, all_, trace, guard)
    return kb_index._die("usage: " + USAGE, 64)
