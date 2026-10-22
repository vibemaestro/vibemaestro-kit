#!/usr/bin/env python3
"""GitHub issue, comment and pull-request writes from one JSON spec, run as the kit baton kit:gh-write.

    gh_write.py --spec <file>                                  plan: conditions, one `op-plan:` line per op, `PLAN-COUNT <n>`
    gh_write.py --spec <file> --do <i> --expect-plan <file>    run op i, only when its plan line is line i of the signed plan
    gh_write.py --spec <file> --postcheck                      every op of the open run, read back by number, byte for byte
    gh_write.py --spec <file> --undo-plan                      one `undo-step: <i> …` line per op of the open run to undo
    gh_write.py --spec <file> --undo-step <i>                  undo op i, only while the live state is still the run's
    gh_write.py --spec <file> --recover [--do <k> --expect-plan <file> | --postcheck | --undo-plan]
                                                               the undo of a run left open (interrupted, or an undo that failed),
                                                               as a plan of its own: one `op-plan:` line per undo step

The plan mode is a read. It prints one condition line per check (`ok`, `FAIL`) and, when all hold, the plan. Every plan line
carries the sha256 of the spec file, so a signature over the plan binds the spec, and through its pins each body file.

Spec (JSON): {"gh-write": 1, "ops": [op, ...]}, 1 to 20 ops. Each op has `op` and `repo` (owner/name) and only the keys of its
kind:
  issue-create   title, body, marker [labels, id]
  issue-comment  issue (a number, or "@<id>" of an earlier issue-create in the same repo), body, marker [closed_ok]
  comment-edit   comment (its id), body
  issue-edit     issue, title and/or body
  pr-body-edit   pr, body
  issue-reopen   issue
  issue-close    issue, reason (completed | not_planned)
  pr-close       pr, head (the full 40-hex head SHA the PR must still have)
  pr-ready       pr, head: a draft pull request, open at that head, marked ready for review
  pr-create      base, branch, head, title, draft, body: a pull request from the existing branch of the same repository, open
                 at the head SHA, into base; refused while an open pull request from that branch into base exists
  file-pr        base, branch, path, content_file, content_sha256, title, draft, body: one file added, or replacing the
                 regular file at the path on base, proposed as a pull request: a new branch at base's tip with one commit
                 (author and committer the viewer's GitHub noreply address, never an e-mail of the account; a replaced file
                 keeps its mode), then the pull request. The plan line names base's tip, what the path holds there (`replaces
                 blob <sha> mode <mode>` or `replaces none`) and the author, so a base or file that moved since signing refuses
                 the op; a directory, a link, a submodule, content equal to the file, and a path under .github/workflows or
                 .github/actions (a workflow definition; any other file runs in CI as on a branch the session pushes) are refused
A branch name is letters, digits and `._/-`: no `..`, no empty component, none that starts with `.` or ends in `.lock` or `.`,
no leading `-`, and none git reserves (HEAD, *_HEAD, AUTO_MERGE, BISECT_EXPECTED_REV, a first component refs, heads,
tags or remotes, 40 hex); a path is
segments of letters, digits and `._-`, no `.` or `..` segment and no `.git` segment. `content_file` is read like `body_file` and
pinned by `content_sha256` (at most 1 MiB, any bytes). `draft` is true or false, so the plan line says which.
A body is `body` (inline, pinned by the spec's own sha256) or `body_file` (inside the spec's directory, links resolved) with
`sha256` (of the file's bytes). `{{issue:<id>}}` in a body becomes `owner/name#N` of that earlier create when the op runs.
The posted body is the text with ONE final newline removed, if it has one (posted_body, the only place that handles it); the
post-check compares the live body with exactly those bytes. A marker is a string the body holds and no other op's body holds;
the plan refuses a create when an issue of the viewer already holds it, and a comment when a comment on the target already
holds it. The issue kinds (edit, reopen, close) refuse a pull request; a comment on one is fine; pr-close closes only a pull request,
open, whose head is still the pinned SHA (its plan line names it), and its undo reopens it only while it is closed, not merged,
and closed by the viewer (its `closed_by`), so a close by someone else after the run stays.
pr-ready's undo turns the pull request back into a draft while it is open, ready and still at the pinned head. pr-create's and
file-pr's undo closes the pull request the run opened while it is open, not merged and at the head the run gave it (a closed
pull request stays in the history). file-pr's branch stays: this baton never deletes, so while the branch is there its undo
names it and fails (the run ends with rc 5 and the owner, who may delete a branch, is told); once the branch is gone it holds.
issue-comment, issue-edit, issue-close, pr-body-edit and pr-close refuse a closed issue or a closed or merged pull request, except an issue-comment with `"closed_ok": true`: it passes there, and its plan line says
`on a closed target (closed_ok)`, so the signed plan and the baton log show it (a measured result posted after an auto-close or a merge).

The scope fence: a deletion (`refuse-delete`), a repository creation (`refuse-repo-create`), an unknown kind or key, and a spec
that breaks the rules above are misuse (rc 64), refused before any call. A repository that is not private, or is internal
(`refuse-public`), fails the condition `private`, read at plan time and again inside each run step. Every `gh` call goes
through api(), which allows only GET reads, two GraphQL reads (VIEWER_QUERY: the login, which `GET user` refuses a GitHub App
installation token with HTTP 403; VIEWER_ID_QUERY: the login and its id, for file-pr's noreply address), two GraphQL
mutations (a pull request marked ready, or back to draft, by its node id), seven POSTs (an issue, a comment, a pull request,
and file-pr's blob, tree, commit and branch ref under refs/heads/) and three PATCHes (an issue, a comment, a pull request's body
or state), each with its own set of fields; anything else raises before `gh` runs. No call moves or deletes a ref.

The journal of a run, $XDG_STATE_HOME/vibemaestro/gh-write/<spec sha256>.json (else ~/.local/state/…), mode 0600, is created
atomically by op 1 and names the spec file's real path and a run id. It holds each op's before-state, saved before its write,
and what the write returned, or that GitHub refused it (an HTTP 4xx: nothing landed). It is `open` until a post-check passes
(`done`) or an undo ends (`undone`). The post-check and the undo find the run by the spec file's path, not by its current bytes,
so an edit of the spec during a run cannot hide the run from its undo. An open run of the same spec bytes or of the same spec
file fails the condition `journal`; `--recover` undoes it.

Exit codes: 0 every condition holds, or the step did what it said; 1 a condition fails (each named), a run step refuses (the
signed plan differs, the world moved, the journal), the post-check differs, or an undo step left a state alone (it changed
since the run, or a write may have landed and cannot be found); 2 could not conclude (a `gh` error, output that is not JSON,
the journal); 64 misuse (the spec breaks a rule, bad arguments).

Standard library only, Python 3.8+.
"""
import base64
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse

sys.dont_write_bytecode = True
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
import gate_common as G  # noqa: E402  (puts the loader's directory on the path)
from backends import json_values  # noqa: E402

OK, FAIL, INFRA, USAGE = 0, 1, 2, 64
GH_TIMEOUT_S = 60
MAX_OPS = 20
MAX_BODY = 65536
MAX_FILE = 1 << 20
ARCHIVED_KEPT = 100
KINDS = {
    "issue-create": ({"title", "marker"}, {"labels", "id"}, True),
    "issue-comment": ({"issue", "marker"}, {"closed_ok"}, True),
    "comment-edit": ({"comment"}, set(), True),
    "issue-edit": ({"issue"}, {"title"}, None),
    "pr-body-edit": ({"pr"}, set(), True),
    "issue-reopen": ({"issue"}, set(), False),
    "issue-close": ({"issue", "reason"}, set(), False),
    "pr-close": ({"pr", "head"}, set(), False),
    "pr-ready": ({"pr", "head"}, set(), False),
    "pr-create": ({"base", "branch", "head", "title", "draft"}, set(), True),
    "file-pr": ({"base", "branch", "path", "content_file", "content_sha256", "title", "draft"}, set(), True),
}                                                       # kind: (required keys, optional keys, body: required / optional / none)
BODY_KEYS = {"body", "body_file", "sha256"}
REPO_RE = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
ID_RE = re.compile(r"[a-z][a-z0-9-]{0,31}")
TOKEN_RE = re.compile(r"\{\{issue:([^{}]*)\}\}")
SHA_RE = re.compile(r"[0-9a-f]{64}")
HEAD_RE = re.compile(r"[0-9a-f]{40}")
CONTROL = re.compile(r"[\x00-\x1f\x7f]")
BRANCH_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9._/-]{0,199}")
SEGMENT_RE = re.compile(r"[A-Za-z0-9._-]{1,100}")
FENCED_DIRS = (".github/workflows/", ".github/actions/")      # workflow definitions: file-pr never writes one
GIT_NAMES = re.compile(r"HEAD|[A-Z_]+_HEAD|AUTO_MERGE|BISECT_EXPECTED_REV")      # git's own root refs (FETCH_HEAD, …)
FILE_MODES = ("100644", "100755")                       # a regular file, plain or executable: what file-pr may replace
NOREPLY_HOST = "users.noreply.github.com"
RETRACTED = "Retracted: the baton run that posted this comment was undone."
REASONS = ("completed", "not_planned")
CLOSE_REASONS = ("completed", "not_planned", "duplicate")    # a reason undo may close with again


def say(msg, out=None):
    (out or sys.stdout).write(msg + "\n")
    (out or sys.stdout).flush()


def sha256(data):
    return hashlib.sha256(data if isinstance(data, bytes) else data.encode("utf-8")).hexdigest()


class Refuse(Exception):
    """The spec breaks a rule: misuse, refused before any call."""
    def __init__(self, name, msg):
        Exception.__init__(self, "%s: %s" % (name, msg))
        self.name = name


class Stop(Exception):
    """A run step, a post-check or an undo step refuses (rc 1); this process wrote nothing."""


class NotFound(G.Infra):
    pass


class Rejected(G.Infra):
    """GitHub answered the write with an HTTP 4xx: it did not land."""


# ── the one door to GitHub ─────────────────────────────────────────────────────────────────────────────────────────────────────
_R = r"repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+"
WRITES = (
    ("POST", re.compile(r"%s/issues" % _R), {"title", "body", "labels"}),
    ("POST", re.compile(r"%s/issues/[0-9]+/comments" % _R), {"body"}),
    ("PATCH", re.compile(r"%s/issues/[0-9]+" % _R), {"title", "body", "state", "state_reason"}),
    ("PATCH", re.compile(r"%s/issues/comments/[0-9]+" % _R), {"body"}),
    ("PATCH", re.compile(r"%s/pulls/[0-9]+" % _R), {"body", "state"}),
    ("POST", re.compile(r"%s/pulls" % _R), {"title", "body", "head", "base", "draft"}),
    ("POST", re.compile(r"%s/git/blobs" % _R), {"content", "encoding"}),
    ("POST", re.compile(r"%s/git/trees" % _R), {"base_tree", "tree"}),
    ("POST", re.compile(r"%s/git/commits" % _R), {"message", "tree", "parents", "author", "committer"}),
    ("POST", re.compile(r"%s/git/refs" % _R), {"ref", "sha"}),
)
READS = re.compile(r"%s(?:/[A-Za-z0-9_.%%/-]*)?(?:\?[A-Za-z0-9_=&%%.-]*)?" % _R)
# The login the author check and the creator filter compare with. `GET user` answers HTTP 403 to a GitHub App installation token
# (the sandbox pod); this query answers it with the app's login, the same string REST shows as `user.login`.
VIEWER_QUERY = "query{viewer{login}}"
VIEWER_ID_QUERY = "query{viewer{login databaseId}}"
# pr-ready and its undo: the only GraphQL writes, each on one pull request named by its node id (REST has no ready/draft call).
READY_MUTATION = "mutation($id:ID!){markPullRequestReadyForReview(input:{pullRequestId:$id}){pullRequest{isDraft}}}"
DRAFT_MUTATION = "mutation($id:ID!){convertPullRequestToDraft(input:{pullRequestId:$id}){pullRequest{isDraft}}}"


def allowed(method, path, payload):
    """True when (method, path, the payload's keys) is one of the calls this engine may make: the scope fence in code."""
    if ".." in path.split("?")[0].split("/"):
        return False
    if method == "GET":
        return payload is None and bool(READS.fullmatch(path))
    if method == "POST" and path == "graphql":                # the two reads and the two mutations, nothing else through GraphQL
        if payload in ({"query": VIEWER_QUERY}, {"query": VIEWER_ID_QUERY}):
            return True
        return (isinstance(payload, dict) and set(payload) == {"query", "variables"}
                and payload["query"] in (READY_MUTATION, DRAFT_MUTATION) and isinstance(payload["variables"], dict)
                and set(payload["variables"]) == {"id"} and isinstance(payload["variables"]["id"], str))
    for m, rx, keys in WRITES:
        if method == m and rx.fullmatch(path):
            if path.endswith("/git/refs") and not (isinstance(payload, dict) and str(payload.get("ref", "")).startswith("refs/heads/")):
                return False                                    # a new branch only: never a tag or another namespace
            return isinstance(payload, dict) and bool(payload) and set(payload) <= keys and values_ok(path, payload)
    return False


def values_ok(path, payload):
    """The values the spec checks, checked again at the door (defence in depth for a kit a session signs itself): a branch ref
    and a PR head are branch names of the same repository, a tree gets one regular file outside the fenced directories, a
    commit's author and committer are a GitHub noreply address."""
    if path.endswith("/git/refs"):
        return branch_ok(payload["ref"][len("refs/heads/"):])
    if path.endswith("/pulls"):
        return all(branch_ok(payload.get(k)) for k in ("head", "base") if k in payload)
    if path.endswith("/git/trees"):                     # a base tree and one blob entry: never a deletion (sha null), never inline
        tree = payload.get("tree")
        return (HEAD_RE.fullmatch(str(payload.get("base_tree", ""))) is not None and isinstance(tree, list) and len(tree) == 1
                and isinstance(tree[0], dict) and set(tree[0]) == {"path", "mode", "type", "sha"}
                and tree[0]["mode"] in FILE_MODES and tree[0]["type"] == "blob" and HEAD_RE.fullmatch(str(tree[0]["sha"]))
                is not None and path_ok(tree[0]["path"]))
    if path.endswith("/git/commits"):
        return all(isinstance(payload.get(k), dict) and str(payload[k].get("email", "")).endswith("@" + NOREPLY_HOST)
                   for k in ("author", "committer"))
    return True


def api(method, path, payload=None, pages=False):
    """One `gh api` call through the allowlist; the parsed JSON (a list of every element with `pages`)."""
    if not allowed(method, path, payload):
        raise G.Infra("refused by the call allowlist: %s %s" % (method, path))
    exe = shutil.which("gh")
    if not exe:
        raise G.Infra("no gh on PATH")
    args = [exe, "api", path] if method == "GET" else [exe, "api", "-X", method, path]
    tmp = None
    try:
        if payload is not None:
            fd, tmp = tempfile.mkstemp(prefix="gh-write-", suffix=".json")
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(payload, f, ensure_ascii=False)
            args += ["--input", tmp]
        if pages:
            args.append("--paginate")
        try:
            p = subprocess.run(args, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               timeout=GH_TIMEOUT_S)
        except subprocess.TimeoutExpired:
            raise G.Infra("gh api %s %s timed out after %ds" % (method, path, GH_TIMEOUT_S))
    finally:
        if tmp:
            os.unlink(tmp)
    err = p.stderr.decode("utf-8", "replace").strip()
    if p.returncode != 0:
        if "HTTP 404" in err:
            raise NotFound("not found: %s" % path)
        if method != "GET" and path != "graphql" and re.search(r"\bHTTP 4(?!08)[0-9][0-9]\b", err):     # 408: the server timed out, outcome unknown
            raise Rejected("gh api %s %s was refused: %s" % (method, path, err[:200]))
        raise G.Infra("gh api %s %s failed: %s" % (method, path, err[:200]))
    vals = json_values(p.stdout.decode("utf-8", "replace"))
    if not pages:
        if len(vals) != 1:
            raise G.Infra("gh api %s printed %d JSON values, not 1" % (path, len(vals)))
        return vals[0]
    out = []
    for v in vals:
        if not isinstance(v, list):
            raise G.Infra("gh api %s: a page is not a list" % path)
        out.extend(v)
    return out


def get(path, pages=False):
    return api("GET", path, None, pages)


# ── the spec ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────
def _pairs(pairs):
    d = {}
    for k, v in pairs:
        if k in d:
            raise Refuse("refuse-spec", "the key %r is given twice in one object" % k)
        d[k] = v
    return d


def posted_body(text):
    """The bytes a body is posted as: its text with ONE final newline removed. The one place the trailing newline is handled."""
    return text[:-1] if text.endswith("\n") else text


def branch_ok(name):
    """A branch name this engine writes or reads: BRANCH_RE, and none of git's forbidden shapes it could still hold (git
    refuses a component that starts with '.' or ends in '.lock' or '.', anywhere in the name), and none of the names git
    reserves or reads first as another ref: its root refs (HEAD, *_HEAD, AUTO_MERGE, BISECT_EXPECTED_REV), a first component
    refs, heads, tags or remotes, a 40-hex SHA. A name like a remote's (origin/x) is not known here and is not refused."""
    return (isinstance(name, str) and bool(BRANCH_RE.fullmatch(name)) and ".." not in name and "@{" not in name
            and all(c and not c.startswith(".") and not c.endswith((".lock", ".")) for c in name.split("/"))
            and not GIT_NAMES.fullmatch(name) and name.split("/")[0] not in ("refs", "heads", "tags", "remotes")
            and not re.fullmatch(r"[0-9a-fA-F]{40}", name))


def path_ok(path):
    """A repository path file-pr may write: segments of SEGMENT_RE, no '.', '..' or .git segment, not a workflow definition."""
    segs = path.split("/") if isinstance(path, str) else []
    return (bool(segs) and all(SEGMENT_RE.fullmatch(s) and s not in (".", "..") and s.lower() != ".git" for s in segs)
            and not any(path.lower().startswith(f) for f in FENCED_DIRS))


def fence_open_at_end(text):
    """True when a fenced code block is still open at the end of the text (an inner fence closed the outer one)."""
    fence = None
    for ln in text.split("\n"):
        if fence:
            if re.match(r"^ {0,3}%s{%d,}[ \t]*$" % (re.escape(fence[0]), len(fence)), ln):
                fence = None
            continue
        m = re.match(r"^ {0,3}(`{3,}|~{3,})", ln)
        if m and not (m.group(1)[0] == "`" and "`" in ln[m.end():]):
            fence = m.group(1)
    return fence is not None


def same_repo(a, b):
    """GitHub names a repository whatever the case; the API answers with its own case."""
    return a.lower() == b.lower()


class Op:
    def __init__(self, i, d, spec_dir, creates):
        self.i, self.raw = i, d
        if not isinstance(d, dict):
            raise Refuse("refuse-spec", "op %d is not an object" % i)
        kind = d.get("op")
        if not isinstance(kind, str):
            raise Refuse("refuse-spec", "op %d has no `op`" % i)
        low = kind.lower()
        if "delete" in low or "remove" in low:
            raise Refuse("refuse-delete", "op %d is %r: this baton never deletes; a deletion is hand-written and owner-signed" % (i, kind))
        if re.search(r"repo", low) and "create" in low:
            raise Refuse("refuse-repo-create", "op %d is %r: this baton never creates a repository" % (i, kind))
        if kind not in KINDS:
            raise Refuse("refuse-unknown-op", "op %d is %r; the kinds are %s" % (i, kind, ", ".join(sorted(KINDS))))
        self.kind = kind
        req, opt, body = KINDS[kind]
        allowed_keys = {"op", "repo"} | req | opt | (BODY_KEYS if body is not False else set())
        extra = sorted(set(d) - allowed_keys)
        if extra:
            raise Refuse("refuse-unknown-key", "op %d (%s) has %s; it takes %s" % (i, kind, ", ".join(extra), ", ".join(sorted(allowed_keys))))
        missing = sorted(req - set(d))
        if missing:
            raise Refuse("refuse-spec", "op %d (%s) needs %s" % (i, kind, ", ".join(missing)))
        repo = d.get("repo")
        if not isinstance(repo, str) or not REPO_RE.fullmatch(repo) or any(p in (".", "..") for p in repo.split("/")):
            raise Refuse("refuse-spec", "op %d: repo %r is not owner/name" % (i, repo))
        self.repo = repo
        self.id = d.get("id")
        if self.id is not None and (not isinstance(self.id, str) or not ID_RE.fullmatch(self.id)):
            raise Refuse("refuse-spec", "op %d: id %r is not lower-case letters, digits and '-' (at most 32)" % (i, self.id))
        self.title = d.get("title")
        if self.title is not None and (not isinstance(self.title, str) or not 1 <= len(self.title) <= 256
                                       or CONTROL.search(self.title)):
            raise Refuse("refuse-spec", "op %d: a title is 1 to 256 characters with no control character" % i)
        self.labels = d.get("labels", [])
        if not isinstance(self.labels, list) or len(self.labels) > 10 or any(
                not isinstance(x, str) or not 1 <= len(x) <= 50 or CONTROL.search(x) for x in self.labels) \
                or len(set(self.labels)) != len(self.labels):
            raise Refuse("refuse-spec", "op %d: labels is a list of at most 10 distinct names, 1 to 50 characters each" % i)
        self.marker = d.get("marker")
        if self.marker is not None and (not isinstance(self.marker, str) or not 4 <= len(self.marker) <= 200
                                        or CONTROL.search(self.marker)):
            raise Refuse("refuse-spec", "op %d: a marker is 4 to 200 characters with no control character" % i)
        self.closed_ok = d.get("closed_ok", False)
        if not isinstance(self.closed_ok, bool):
            raise Refuse("refuse-spec", "op %d: closed_ok is true or false" % i)
        self.reason = d.get("reason")
        if kind == "issue-close" and self.reason not in REASONS:
            raise Refuse("refuse-spec", "op %d: reason is completed or not_planned" % i)
        self.head = d.get("head")
        if kind in ("pr-close", "pr-ready", "pr-create") and (not isinstance(self.head, str) or not HEAD_RE.fullmatch(self.head)):
            raise Refuse("refuse-spec", "op %d: head is the pull request's full head SHA, 40 lower-case hex digits" % i)
        self.base, self.branch = d.get("base"), d.get("branch")
        for k in ("base", "branch"):
            if k in d and not branch_ok(d[k]):
                raise Refuse("refuse-spec", "op %d: %s %r is not a branch name this op writes (letters, digits and ._/-; no '..', "
                             "no empty component, none starting with '.' or ending in '.lock' or '.', no leading '-', not HEAD "
                             "or *_HEAD, not under refs/, heads/, tags/ or remotes/, not 40 hex)" % (i, k, d[k]))
        if self.base is not None and self.base == self.branch:
            raise Refuse("refuse-spec", "op %d: branch and base are the same branch" % i)
        self.draft = d.get("draft")
        if "draft" in d and not isinstance(self.draft, bool):
            raise Refuse("refuse-spec", "op %d: draft is true or false" % i)
        self.path, self.content, self.content_pin = d.get("path"), None, None
        if kind == "file-pr":
            self.path = self.read_path(d)
            self.content, self.content_pin = self.read_content(d, spec_dir)
        self.number, self.ref = None, None
        key = {"comment-edit": "comment", "pr-body-edit": "pr", "pr-close": "pr", "pr-ready": "pr"}.get(kind, "issue")
        if key in d:
            v = d[key]
            if isinstance(v, str) and v.startswith("@") and kind == "issue-comment":
                ref = v[1:]
                if ref not in creates:
                    raise Refuse("refuse-ref", "op %d: %s is not the id of an earlier issue-create" % (i, v))
                if creates[ref].repo != repo:
                    raise Refuse("refuse-ref", "op %d: %s was created in %s, not in %s" % (i, v, creates[ref].repo, repo))
                self.ref = ref
            elif isinstance(v, int) and not isinstance(v, bool) and v > 0:
                self.number = v
            else:
                raise Refuse("refuse-spec", "op %d: %s %r is not a positive number%s" % (
                    i, key, v, " or @<id>" if kind == "issue-comment" else ""))
        self.template, self.pin = None, None
        has = [k for k in ("body", "body_file") if k in d]
        if body is True and len(has) != 1 or body is None and len(has) > 1:
            raise Refuse("refuse-body", "op %d (%s): give exactly one of body and body_file" % (i, kind))
        if "sha256" in d and "body_file" not in d:
            raise Refuse("refuse-body", "op %d: sha256 pins a body_file" % i)
        if "body" in d:
            if not isinstance(d["body"], str):
                raise Refuse("refuse-body", "op %d: body is a string" % i)
            self.template = d["body"]
        elif "body_file" in d:
            self.template = self.read_body(d, spec_dir)
        if self.template is not None:
            if "\x00" in self.template or "\r" in self.template:
                raise Refuse("refuse-body", "op %d: a body holds no NUL and no CR" % i)
            if len(posted_body(self.template)) > MAX_BODY:
                raise Refuse("refuse-body", "op %d: a body is at most %d characters" % (i, MAX_BODY))
            for t in TOKEN_RE.findall(self.template):
                if t not in creates:
                    raise Refuse("refuse-ref", "op %d: {{issue:%s}} names no earlier issue-create" % (i, t))
        if kind == "issue-edit" and self.title is None and self.template is None:
            raise Refuse("refuse-spec", "op %d (issue-edit) changes nothing: give a title or a body" % i)
        self.fence_open = self.template is not None and fence_open_at_end(self.template)

    def read_pinned(self, refusal, key, pin_key, rel, pin, spec_dir, cap=None):
        """The bytes of a file a spec names beside it (body_file, content_file): a relative path without '..' that stays inside
        the spec's directory once links are resolved, pinned by a sha256, at most `cap` bytes. One reader for both, so the
        containment check exists once."""
        i = self.i
        if not isinstance(rel, str) or not rel or os.path.isabs(rel) or ".." in rel.replace("\\", "/").split("/"):
            raise Refuse(refusal, "op %d: %s is a relative path without '..'" % (i, key))
        if not isinstance(pin, str) or not SHA_RE.fullmatch(pin):
            raise Refuse(refusal, "op %d: %s needs %s, 64 lower-case hex digits" % (i, key, pin_key))
        path = os.path.join(spec_dir, rel)
        real, root = os.path.realpath(path), os.path.realpath(spec_dir)
        if os.path.commonpath([real, root]) != root:
            raise Refuse(refusal, "op %d: %s %s leads outside the spec's directory" % (i, key, rel))
        try:
            with open(real, "rb") as f:
                data = f.read() if cap is None else f.read(cap + 1)
        except OSError as e:
            raise Refuse(refusal, "op %d: cannot read %s %s: %s" % (i, key, rel, e.strerror or e))
        if cap is not None and len(data) > cap:
            raise Refuse(refusal, "op %d: %s %s is larger than %d bytes" % (i, key, rel, cap))
        return data, (rel, pin, sha256(data))

    def read_body(self, d, spec_dir):
        i, rel = self.i, d["body_file"]
        data, self.pin = self.read_pinned("refuse-body", "body_file", "sha256", rel, d.get("sha256"), spec_dir)
        try:
            return data.decode("utf-8")
        except UnicodeDecodeError:
            raise Refuse("refuse-body", "op %d: body_file %s is not UTF-8" % (i, rel))

    def read_path(self, d):
        i, path = self.i, d["path"]
        segs = path.split("/") if isinstance(path, str) else []
        if not segs or any(not SEGMENT_RE.fullmatch(s) or s in (".", "..") or s.lower() == ".git" for s in segs):
            raise Refuse("refuse-spec", "op %d: path %r is not segments of letters, digits and ._- joined by '/' (no '.', '..' or "
                         ".git segment)" % (i, path))
        if any(path.lower().startswith(f) for f in FENCED_DIRS):
            raise Refuse("refuse-workflow", "op %d: path %s is under %s: this op does not write a workflow definition; propose "
                         "it through a reviewed branch instead" % (i, path, " or ".join(FENCED_DIRS)))
        return path

    def read_content(self, d, spec_dir):
        """(bytes, (rel, pin, actual)) of content_file: any bytes, at most MAX_FILE."""
        return self.read_pinned("refuse-content", "content_file", "content_sha256", d["content_file"], d["content_sha256"],
                                spec_dir, MAX_FILE)

    def refs(self):
        return sorted(set(TOKEN_RE.findall(self.template or "")))

    def target_key(self):
        if self.kind == "issue-create":
            return None
        if self.kind in ("pr-create", "file-pr"):
            return ("branch", self.repo.lower(), self.branch)
        if self.kind == "comment-edit":
            return ("comment", self.repo.lower(), self.number)
        return ("issue", self.repo.lower(), self.ref or self.number)


class Spec:
    def __init__(self, path):
        try:
            with open(path, "rb") as f:
                self.raw = f.read()
        except OSError as e:
            raise Refuse("refuse-spec", "cannot read the spec %s: %s" % (path, e.strerror or e))
        self.path, self.given = os.path.realpath(path), path
        self.sha = sha256(self.raw)
        try:
            d = json.loads(self.raw.decode("utf-8"), object_pairs_hook=_pairs)
        except Refuse:
            raise
        except (UnicodeDecodeError, ValueError) as e:
            raise Refuse("refuse-spec", "the spec is not UTF-8 JSON (%s)" % e)
        if not isinstance(d, dict) or set(d) != {"gh-write", "ops"} or d.get("gh-write") != 1:
            raise Refuse("refuse-spec", 'the spec is {"gh-write": 1, "ops": [...]} and nothing else')
        ops = d["ops"]
        if not isinstance(ops, list) or not 1 <= len(ops) <= MAX_OPS:
            raise Refuse("refuse-spec", "ops is a list of 1 to %d operations" % MAX_OPS)
        creates, self.ops, seen, markers = {}, [], {}, set()
        for i, od in enumerate(ops, 1):
            op = Op(i, od, os.path.dirname(self.path), creates)
            if op.id is not None:
                if op.id in creates:
                    raise Refuse("refuse-spec", "op %d: id %r is given twice" % (i, op.id))
                creates[op.id] = op
            if op.marker is not None:
                if op.marker in markers:
                    raise Refuse("refuse-spec", "op %d: the marker is used by an earlier op" % i)
                markers.add(op.marker)
            k = op.target_key()
            if k is not None:
                prev = seen.get(k)
                if prev is not None and not (prev == "issue-comment" and op.kind == "issue-comment"):
                    raise Refuse("refuse-same-target", "op %d (%s) targets what an earlier op (%s) already does: one op per "
                                 "issue, PR or comment, except several comments" % (i, op.kind, prev))
                seen[k] = op.kind if prev is None else prev
            self.ops.append(op)
        for op in self.ops:                             # a marker in another op's body would fail that op mid-run
            for other in self.ops:
                if other is not op and op.marker is not None and other.template is not None and op.marker in other.template:
                    raise Refuse("refuse-spec", "op %d's marker is in the body of op %d: a marker belongs to one op" % (op.i, other.i))
        self.n = len(self.ops)
        self.by_id = creates


def spec_sha_now(path):
    """The sha256 of the spec file's bytes now, or None when it cannot be read."""
    try:
        with open(path, "rb") as f:
            return sha256(f.read())
    except OSError:
        return None


# ── the journal ────────────────────────────────────────────────────────────────────────────────────────────────────────────────
def journal_dir():
    return os.path.join(G.state_home(), "vibemaestro", "gh-write")


def journal_file(sha):
    return os.path.join(journal_dir(), sha + ".json")


def journals():
    """Every journal in the directory, each with `_file`. One that cannot be read is Infra: it may be an open run, which must not
    be overlooked, so the error names the file for the owner."""
    d, out = journal_dir(), []
    if not os.path.isdir(d):
        return out
    for name in sorted(os.listdir(d)):
        if not name.endswith(".json") or name.startswith("."):
            continue
        p = os.path.join(d, name)
        try:
            with open(p, encoding="utf-8") as f:
                j = json.load(f)
        except (OSError, ValueError) as e:
            raise G.Infra("the journal %s cannot be read: %s" % (p, e))
        if not isinstance(j, dict) or not isinstance(j.get("entries"), dict) or not isinstance(j.get("spec"), str) \
                or not isinstance(j.get("paths"), list):
            raise G.Infra("the journal %s is not a journal of this version (no spec, entries or paths); when it is not an open "
                          "run, the owner may move it out of %s" % (p, d))
        j["_file"] = p
        out.append(j)
    return out


def spec_paths(path):
    """The spellings a run of this spec file is found by: as given (absolute) and with its links resolved."""
    return sorted(set((os.path.abspath(path), os.path.realpath(path))))


def open_runs(sha=None, path=None):
    names = set(spec_paths(path)) if path else set()
    return [j for j in journals() if j.get("state") == "open" and (j["spec"] == sha or names & set(j["paths"]))]


def lost_runs(sha=None, path=None):
    """Closed runs of this spec that left a write whose outcome is unknown (it may have landed, the list did not show it): a
    rerun could post it twice, so they block the spec until the owner has looked and moved the journal out of the directory."""
    names = set(spec_paths(path)) if path else set()
    return [j for j in journals() if j.get("state") == "left" and (j["spec"] == sha or names & set(j["paths"]))
            and any(e.get("status") == "left" and e.get("left") == LOST for e in j["entries"].values())]


def the_open_run(path):
    """The one open run of this spec file, None when there is none; Stop when there are several."""
    runs = open_runs(path=path)
    if len(runs) > 1:
        raise Stop("%d open runs of %s: left for the owner" % (len(runs), path))
    return runs[0] if runs else None


def write_json(path, j):
    fd, tmp = tempfile.mkstemp(prefix=".journal-", dir=journal_dir())
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump({k: v for k, v in j.items() if k != "_file"}, f, ensure_ascii=False, indent=1, sort_keys=True)
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, 0o600)
    return tmp


def save_journal(j):
    """Write the journal back, only while its file still holds this run (another process may have closed it meanwhile)."""
    try:
        with open(j["_file"], encoding="utf-8") as f:
            now = json.load(f)
    except (OSError, ValueError) as e:
        raise G.Infra("the journal %s cannot be read back: %s" % (j["_file"], e))
    if not isinstance(now, dict) or now.get("run") != j["run"]:
        raise Stop("journal: %s no longer holds run %s: left for the owner" % (j["_file"], j["run"]))
    os.replace(write_json(j["_file"], j), j["_file"])


def open_journal(spec, given):
    """Op 1: the run's journal <spec sha256>.json, which exists only while the run is open. It is written whole into a temporary
    file and linked into place (os.link fails when the name exists), so two runs of the same bytes never both start and no
    reader ever sees a half-written journal."""
    d = journal_dir()
    os.makedirs(d, mode=0o700, exist_ok=True)
    if open_runs(sha=spec.sha, path=given):
        raise Stop("journal: an unfinished run of this spec is open: recover it (--recover) or tell the owner")
    if lost_runs(sha=spec.sha, path=given):
        raise Stop("journal: a run of this spec left a write whose outcome is unknown: the owner looks first")
    j = {"spec": spec.sha, "paths": spec_paths(given), "n": spec.n, "state": "open", "run": os.urandom(8).hex(),
         "started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "entries": {}}
    p = journal_file(spec.sha)
    tmp = write_json(p, j)
    try:
        for attempt in (1, 2):
            try:
                os.link(tmp, p)
                break
            except FileExistsError:
                held = _read(p)
                if attempt == 2 or held is None or held.get("state") == "open":
                    raise Stop("journal: another run of this spec holds %s" % p)
                try:                                    # a closed run that never moved aside (a crash while closing)
                    os.rename(p, os.path.join(journal_dir(), "%s.%s.json" % (spec.sha, held.get("run") or "closed")))
                except FileNotFoundError:
                    pass
    finally:
        os.unlink(tmp)
    j["_file"] = p
    prune_archived()
    return j


def _read(path):
    try:
        with open(path, encoding="utf-8") as f:
            v = json.load(f)
        return v if isinstance(v, dict) else None
    except (OSError, ValueError):
        return None


def close_journal(j, state):
    """The run is over: its journal moves aside to <sha>.<run>.json first, by the process that closed it, and then records its
    end there. A crash in between leaves an open run under its archive name, which recovery still finds; <sha>.json is free."""
    dest = os.path.join(journal_dir(), "%s.%s.json" % (j["spec"], j["run"]))
    held = _read(j["_file"])
    if not held or held.get("run") != j["run"]:
        raise Stop("journal: %s no longer holds run %s: left for the owner" % (j["_file"], j["run"]))
    if j["_file"] != dest:
        try:
            os.rename(j["_file"], dest)
        except FileNotFoundError:
            raise Stop("journal: run %s was closed by another process meanwhile" % j["run"])
        j["_file"] = dest
    j["state"] = state
    j["closed"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    save_journal(j)


def prune_archived():
    """Keep the newest ARCHIVED_KEPT closed runs. Only a run that closed cleanly (done, undone) is ever deleted: an open run
    under its archive name, or one that left a state for the owner, stays whatever its age."""
    d, old = journal_dir(), []
    for n in os.listdir(d):
        if n.count(".") == 2 and n.endswith(".json"):
            held = _read(os.path.join(d, n))
            if not held or held.get("state") not in ("done", "undone"):
                continue
            try:
                old.append((os.path.getmtime(os.path.join(d, n)), n))
            except OSError:
                pass
    for _t, n in sorted(old)[:-ARCHIVED_KEPT] if len(old) > ARCHIVED_KEPT else []:
        try:
            os.unlink(os.path.join(d, n))
        except OSError:
            pass


# ── reading the world ──────────────────────────────────────────────────────────────────────────────────────────────────────────
class World:
    """Reads, each once per process."""
    def __init__(self):
        self.cache = {}

    def read(self, path, pages=False):
        if path not in self.cache:
            try:
                self.cache[path] = get(path, pages)
            except NotFound:
                self.cache[path] = None
        return self.cache[path]

    def viewer(self):
        if "\0viewer" not in self.cache:
            u = api("POST", "graphql", {"query": VIEWER_QUERY})
            login = ((u.get("data") or {}).get("viewer") or {}).get("login") if isinstance(u, dict) else None
            if not isinstance(login, str) or not login:
                raise G.Infra("the GraphQL viewer read gave no login")
            self.cache["\0viewer"] = login
        return self.cache["\0viewer"]

    def viewer_id(self):
        """(login, database id) of the viewer: the noreply address of a commit file-pr makes is <id>+<login>@users.noreply."""
        if "\0viewer-id" not in self.cache:
            u = api("POST", "graphql", {"query": VIEWER_ID_QUERY})
            v = ((u.get("data") or {}).get("viewer") or {}) if isinstance(u, dict) else {}
            login, did = v.get("login"), v.get("databaseId")
            if not isinstance(login, str) or not login or not isinstance(did, int) or isinstance(did, bool) or did <= 0:
                raise G.Infra("the GraphQL viewer read gave no login and id")
            self.cache["\0viewer-id"] = (login, did)
        return self.cache["\0viewer-id"]


def short(text):
    return sha256(text)[:16]


def body_of(obj):
    b = obj.get("body") if isinstance(obj, dict) else None
    return b if isinstance(b, str) else ""


def q(s):
    return urllib.parse.quote(s, safe="")


def noreply(login, did):
    return "%d+%s@%s" % (did, login, NOREPLY_HOST)


def kind_of_draft(draft):
    return "draft" if draft else "ready"


def open_prs_from(w, repo, branch, base, state="open"):
    """The pull requests of repo from its own branch into base (GitHub filters by owner:branch; base is checked here too)."""
    owner = repo.split("/")[0]
    got = w.read("repos/%s/pulls?state=%s&head=%s&base=%s&per_page=100" % (repo, state, q("%s:%s" % (owner, branch)), q(base)),
                 pages=True) or []
    return [x for x in got if isinstance(x, dict) and ((x.get("head") or {}).get("ref") == branch)
            and ((x.get("base") or {}).get("ref") == base)]


def ref_tip(w, repo, branch):
    """The SHA the branch points at, or None when there is no such branch (git/ref/ is an exact match, not a prefix)."""
    ref = w.read("repos/%s/git/ref/heads/%s" % (repo, branch))
    return ((ref or {}).get("object") or {}).get("sha") if isinstance(ref, dict) else None


def git_blob_sha(data):
    """The id git gives these bytes as a blob: what GitHub answers for the blob and lists in a tree."""
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


def tree_entry(w, repo, commit, path):
    """(entry or None, the commit's root tree) for path at commit, read one tree at a time. The entry is the tree's own
    dict (mode, type, sha); a path whose parent is not a directory answers an entry with type "blocked"."""
    c = w.read("repos/%s/git/commits/%s" % (repo, commit))
    root = ((c or {}).get("tree") or {}).get("sha") if isinstance(c, dict) else None
    if not isinstance(root, str) or not HEAD_RE.fullmatch(root):
        raise G.Infra("commit %s of %s gave no tree" % (commit, repo))
    tree, segs = root, path.split("/")
    for k, seg in enumerate(segs):
        listing = w.read("repos/%s/git/trees/%s" % (repo, tree))
        if not isinstance(listing, dict) or not isinstance(listing.get("tree"), list) or listing.get("truncated"):
            raise G.Infra("tree %s of %s cannot be read whole" % (tree, repo))
        hit = next((x for x in listing["tree"] if isinstance(x, dict) and x.get("path") == seg), None)
        if hit is None:
            return None, root
        if k == len(segs) - 1:
            return hit, root
        if hit.get("type") != "tree":
            return dict(hit, type="blocked"), root
        tree = hit.get("sha")
    return None, root


def tree_drift(w, repo, base_commit, commit, path):
    """What the commit changed besides the one path: the two trees are read level by level along the path, and every
    listing must match the base's apart from the entry on the path (a new directory holds only that entry)."""
    def root_of(c):
        o = w.read("repos/%s/git/commits/%s" % (repo, c))
        return ((o or {}).get("tree") or {}).get("sha") if isinstance(o, dict) else None

    def listing(tree):
        if tree is None:
            return {}
        got = w.read("repos/%s/git/trees/%s" % (repo, tree))
        if not isinstance(got, dict) or not isinstance(got.get("tree"), list) or got.get("truncated"):
            raise G.Infra("tree %s of %s cannot be read whole" % (tree, repo))
        return {x.get("path"): (x.get("mode"), x.get("type"), x.get("sha")) for x in got["tree"] if isinstance(x, dict)}
    out, old, new, segs = [], root_of(base_commit), root_of(commit), path.split("/")
    if not old or not new:
        raise G.Infra("commit %s or %s of %s gave no tree" % (base_commit, commit, repo))
    for n, seg in enumerate(segs):
        a, b = listing(old), listing(new)
        moved = sorted(k for k in set(a) | set(b) if k != seg and a.get(k) != b.get(k))
        if moved:
            out.append("the commit also changes %s" % ", ".join("/".join(segs[:n] + [k]) for k in moved[:5]))
        old = a[seg][2] if seg in a and a[seg][1] == "tree" else None
        new = b[seg][2] if seg in b and b[seg][1] == "tree" else None
    return out


def is_private(r):
    """A repository whose audience is its members: private, not internal (the whole enterprise) and not public."""
    return isinstance(r, dict) and r.get("private") is True and r.get("visibility") not in ("public", "internal")


class Plan:
    """The conditions and the plan line of each op, read from the live state (and the journal, for @refs)."""
    def __init__(self, spec, world, journal=None, only=None):
        self.spec, self.w, self.journal = spec, world, journal
        self.conds, self.lines = [], {}
        self.files = {}                                 # file-pr: op -> (base tip, its tree, mode, replaces, author e-mail, login)
        self.only = only

    def cond(self, name, good, detail):
        self.conds.append((name, bool(good), detail))
        return bool(good)

    def created(self, ref):
        """The number an earlier create of this run got, from the journal (None at plan time)."""
        if not self.journal:
            return None
        for e in self.journal["entries"].values():
            if e.get("id") == ref and e.get("number") and e.get("status") == "done":
                return e["number"]
        return None

    def render(self, op):
        """(text to post, digest for the plan line). A body citing a create is shown by its template's digest at every phase,
        so the plan line is the same at rehearse and at run; the posted bytes are fixed once the create's number is known."""
        if op.template is None:
            return None, None
        if op.refs():
            text = posted_body(op.template)
            nums = {r: self.created(r) for r in op.refs()}
            if all(nums.values()):
                text = TOKEN_RE.sub(lambda m: "%s#%d" % (self.spec.by_id[m.group(1)].repo, nums[m.group(1)]), text)
            else:
                text = None
            return text, "body template %s %dB" % (short(op.template), len(op.template.encode("utf-8")))
        text = posted_body(op.template)
        return text, "body %s %dB" % (short(text), len(text.encode("utf-8")))

    def go(self):
        sp, w = self.spec, self.w
        if self.only is None:
            runs, lost = open_runs(sha=sp.sha, path=sp.given), lost_runs(sha=sp.sha, path=sp.given)
            self.cond("journal", not runs and not lost,
                      "an unfinished run of this spec or this spec file is open: recover it (--recover) or tell the owner" if runs
                      else "run %s left a write whose outcome is unknown: the owner checks GitHub, then moves %s out of the journal "
                           "directory" % (lost[0]["run"], lost[0]["_file"]) if lost else "no unfinished run of this spec")
        viewer = w.viewer()
        for repo in sorted(set(op.repo for op in sp.ops if self.only is None or op.i == self.only)):
            r = w.read("repos/%s" % repo)
            if r is None:
                self.cond("exists", False, "repository %s not found" % repo)
                continue
            vis = r.get("visibility")
            self.cond("private", is_private(r), "%s is %s" % (repo, vis) if is_private(r)
                      else "refuse-public %s is not private (private %s, visibility %s): this baton writes to private "
                           "repositories only" % (repo, r.get("private"), vis))
        for op in sp.ops:
            if self.only is not None and op.i != self.only:
                continue
            self.lines[op.i] = self.one(op, viewer)

    def one(self, op, viewer):
        w, sp = self.w, self.spec
        tag = "op %d (%s)" % (op.i, op.kind)
        if op.pin:
            rel, pin, actual = op.pin
            self.cond("pinned", pin == actual, "%s: body_file %s sha256 %s%s" % (
                tag, rel, actual[:16], "" if pin == actual else ", pinned %s" % pin[:16]))
        text, digest = self.render(op)
        if op.template is not None:
            self.cond("fences", not op.fence_open, "%s: %s" % (
                tag, "a fenced block of the body is still open at its end (an inner fence closed the outer one)"
                if op.fence_open else "every fenced block of the body is closed"))
        if op.marker is not None:
            self.cond("marker-in-body", op.template is not None and op.marker in op.template, "%s: the body %s the marker" % (
                tag, "holds" if op.template is not None and op.marker in op.template else "does not hold"))
        head = "gh-write %d/%d spec %s %s" % (op.i, sp.n, sp.sha, op.kind)
        if op.kind == "pr-create":
            return self.pr_create(op, tag, head, digest)
        if op.kind == "file-pr":
            return self.file_pr(op, tag, head, digest)
        if op.kind == "issue-create":
            for lab in op.labels:
                self.cond("labels", w.read("repos/%s/labels/%s" % (op.repo, q(lab))) is not None,
                          "%s: label %s in %s" % (tag, json.dumps(lab), op.repo))
            mine = w.read("repos/%s/issues?state=all&creator=%s&per_page=100" % (op.repo, q(viewer)), pages=True)
            hit = [x.get("number") for x in (mine or []) if op.marker in body_of(x)]
            self.cond("marker-absent", not hit, "%s: %s" % (tag, "no issue of %s holds the marker" % viewer if not hit
                                                            else "issue #%s already holds the marker" % hit[0]))
            return "%s %s title %s labels %s %s%s" % (head, op.repo, json.dumps(op.title), json.dumps(op.labels), digest,
                                                     " as @%s" % op.id if op.id else "")
        if op.kind == "comment-edit":
            c = w.read("repos/%s/issues/comments/%d" % (op.repo, op.number))
            if not self.cond("exists", c is not None, "%s: comment %d in %s" % (tag, op.number, op.repo)):
                return None
            login = (c.get("user") or {}).get("login")
            self.cond("author", login == viewer, "%s: comment %d is by %s%s" % (
                tag, op.number, login, "" if login == viewer else ", not by %s: this baton edits only its own" % viewer))
            was = body_of(c)
            self.cond("changes", text != was, "%s: the new body %s the live one" % (tag, "differs from" if text != was else "equals"))
            return "%s %s comment %d was %s %s" % (head, op.repo, op.number, short(was), digest)
        target = "#%d" % op.number if op.number else "@%s" % op.ref
        if op.ref:
            num = self.created(op.ref)
            if num is None:
                self.cond("exists", self.only is None, "%s: %s is created by an earlier op of this spec" % (tag, target))
                if op.kind == "issue-comment":
                    self.cond("open", True, "%s: %s is new" % (tag, target))
                    self.cond("marker-absent", True, "%s: %s is new" % (tag, target))
                return "%s %s%s %s" % (head, op.repo, target, digest)
        else:
            num = op.number
        if op.kind in ("pr-body-edit", "pr-close", "pr-ready"):
            obj = w.read("repos/%s/pulls/%d" % (op.repo, num))
        else:
            obj = w.read("repos/%s/issues/%d" % (op.repo, num))
        if not self.cond("exists", obj is not None, "%s: %s%s%s" % (tag, op.repo, "#%d" % num, " is not a pull request (an issue, or no such number)" if
                                                                     obj is None and op.kind in ("pr-close", "pr-ready") else "")):
            return None
        if op.kind in ("issue-edit", "issue-reopen", "issue-close"):
            pr = obj.get("pull_request") is not None
            self.cond("not-pr", not pr, "%s: %s#%d is %s" % (tag, op.repo, num, "a pull request: an issue op does not act on "
                                                              "one" if pr else "an issue"))
        state = obj.get("state")
        if op.kind == "issue-reopen":
            self.cond("closed", state == "closed", "%s: %s#%d is %s" % (tag, op.repo, num, state))
            return "%s %s%s was closed %s" % (head, op.repo, target, obj.get("state_reason") or "none")
        closed_ok = op.kind == "issue-comment" and op.closed_ok and state == "closed"
        self.cond("open", state == "open" or closed_ok, "%s: %s#%d is %s%s" % (tag, op.repo, num, state, " (closed_ok)" if closed_ok else ""))
        if op.kind == "issue-close":
            return "%s %s%s reason %s" % (head, op.repo, target, op.reason)
        if op.kind in ("pr-close", "pr-ready"):
            live = (obj.get("head") or {}).get("sha")
            self.cond("head", live == op.head, "%s: %s#%d head %s%s" % (tag, op.repo, num, live, "" if live == op.head
                                                                          else ", pinned %s: the PR moved" % op.head))
            if op.kind == "pr-ready":
                self.cond("draft", obj.get("draft") is True, "%s: %s#%d is %s" % (
                    tag, op.repo, num, "a draft" if obj.get("draft") is True else "not a draft: nothing to mark ready"))
            return "%s %s%s head %s" % (head, op.repo, target, op.head)
        if op.kind == "issue-comment":
            cs = w.read("repos/%s/issues/%d/comments?per_page=100" % (op.repo, num), pages=True)
            hit = [x.get("id") for x in (cs or []) if op.marker in body_of(x)]
            self.cond("marker-absent", not hit, "%s: %s" % (tag, "no comment on %s#%d holds the marker" % (op.repo, num)
                                                            if not hit else "comment %s already holds the marker" % hit[0]))
            return "%s %s%s %s%s" % (head, op.repo, target, "on a closed target (closed_ok) " if closed_ok else "", digest)
        was = body_of(obj)
        if op.kind == "pr-body-edit":
            self.cond("changes", text != was, "%s: the new body %s the live one" % (tag, "differs from" if text != was else "equals"))
            return "%s %s%s was %s %s" % (head, op.repo, target, short(was), digest)
        parts, change = [], False
        if op.title is not None:
            parts.append("title %s was-title %s" % (json.dumps(op.title), short(obj.get("title") or "")))
            change = change or op.title != obj.get("title")
        if op.template is not None:
            parts.append("was %s %s" % (short(was), digest))
            change = change or text != was
        self.cond("changes", change, "%s: the edit %s" % (tag, "changes something" if change else "changes nothing"))
        return "%s %s%s %s" % (head, op.repo, target, " ".join(parts))

    def branch_tip(self, repo, branch):
        return ref_tip(self.w, repo, branch)

    def pr_create(self, op, tag, head, digest):
        base_tip = self.branch_tip(op.repo, op.base)
        self.cond("base", base_tip is not None, "%s: base branch %s of %s %s" % (
            tag, op.base, op.repo, "exists" if base_tip else "does not exist"))
        live = self.branch_tip(op.repo, op.branch)
        self.cond("head", live == op.head, "%s: branch %s of %s %s" % (
            tag, op.branch, op.repo, "is at the pinned head" if live == op.head else
            "does not exist: push it first" if live is None else "is at %s, pinned %s: the branch moved" % (live, op.head)))
        prs = open_prs_from(self.w, op.repo, op.branch, op.base)
        self.cond("pr-absent", not prs, "%s: %s" % (tag, "no open pull request %s -> %s" % (op.branch, op.base) if not prs
                                                     else "pull request #%s %s -> %s is already open" % (prs[0].get("number"), op.branch, op.base)))
        return "%s %s base %s branch %s at %s %s title %s %s" % (head, op.repo, op.base, op.branch, op.head,
                                                                kind_of_draft(op.draft), json.dumps(op.title), digest)

    def file_pr(self, op, tag, head, digest):
        """Adds the file, or replaces the one at the path on base. The plan line names the base tip, what the path holds there
        (`replaces blob <sha> mode <mode>` or `replaces none`) and the commit's author, so the signature binds all three."""
        rel, pin, actual = op.content_pin
        self.cond("pinned", pin == actual, "%s: content_file %s sha256 %s%s" % (
            tag, rel, actual[:16], "" if pin == actual else ", pinned %s" % pin[:16]))
        base_tip = self.branch_tip(op.repo, op.base)
        self.cond("base", base_tip is not None, "%s: base branch %s of %s %s" % (
            tag, op.base, op.repo, "is at %s" % base_tip if base_tip else "does not exist"))
        live = self.branch_tip(op.repo, op.branch)
        self.cond("branch-absent", live is None, "%s: branch %s of %s %s" % (
            tag, op.branch, op.repo, "does not exist yet" if live is None else "already exists (at %s)" % live))
        replaces, mode, root = "none", FILE_MODES[0], None
        if base_tip:
            entry, root = tree_entry(self.w, op.repo, base_tip, op.path)
            kind = None if entry is None else ("file" if entry.get("type") == "blob" and entry.get("mode") in FILE_MODES
                                               else entry.get("type") if entry.get("type") in ("tree", "blocked")
                                               else "link" if entry.get("mode") == "120000" else "submodule or other")
            self.cond("path", kind in (None, "file"), "%s: %s on %s %s" % (
                tag, op.path, op.base, "is absent: the file is added" if kind is None else
                "is a file: it is replaced" if kind == "file" else "is a directory" if kind == "tree" else
                "lies under a file, a link or a submodule" if kind == "blocked" else "is a %s, not a regular file" % kind))
            if kind == "file":
                replaces, mode = "blob %s mode %s" % (entry.get("sha"), entry.get("mode")), entry.get("mode")
                self.cond("changes", entry.get("sha") != git_blob_sha(op.content), "%s: the content %s the file on %s" % (
                    tag, "differs from" if entry.get("sha") != git_blob_sha(op.content) else "equals", op.base))
        login, did = self.w.viewer_id()
        self.files[op.i] = (base_tip, root, mode, replaces, noreply(login, did), login)
        return "%s %s base %s at %s branch %s path %s replaces %s content %s %dB author %s %s title %s %s" % (
            head, op.repo, op.base, base_tip, op.branch, json.dumps(op.path), replaces, actual[:16], len(op.content),
            noreply(login, did), kind_of_draft(op.draft), json.dumps(op.title), digest)

    def failed(self):
        return [c for c in self.conds if not c[1]]

    def show(self):
        for name, good, detail in self.conds:
            say("  %-4s  %s: %s" % ("ok" if good else "FAIL", name, detail))


# ── the modes ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────
def mode_plan(spec):
    p = Plan(spec, World())
    p.go()
    p.show()
    if p.failed():
        say("gh_write: %d condition%s failed: %s" % (len(p.failed()), "" if len(p.failed()) == 1 else "s",
                                                     ", ".join(sorted(set(c[0] for c in p.failed())))), sys.stderr)
        return FAIL
    for op in spec.ops:
        say("op-plan: %s" % p.lines[op.i])
    say("PLAN-COUNT %d" % spec.n)
    return OK


def signed_plan(path, n, prefix):
    """The signed plan's lines, checked: n lines, line k starting with prefix(k)."""
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().split("\n")
    except (OSError, ValueError) as e:
        raise Stop("refuse-plan: cannot read the signed plan: %s" % e)
    if lines and lines[-1] == "":
        lines.pop()
    if len(lines) != n:
        raise Stop("refuse-plan: the signed plan has %d lines, this run %d steps" % (len(lines), n))
    for k, ln in enumerate(lines, 1):
        if not ln.startswith(prefix(k)):
            raise Stop("refuse-plan: signed plan line %d is not step %d/%d of this run (%s…)" % (k, k, n, prefix(k)[:60]))
    return lines


def mode_do(spec, i, plan_file):
    lines = signed_plan(plan_file, spec.n, lambda k: "gh-write %d/%d spec %s " % (k, spec.n, spec.sha))
    if not 1 <= i <= spec.n:
        raise Stop("refuse-plan: --do %d: the spec has %d ops" % (i, spec.n))
    op = spec.ops[i - 1]
    if i == 1:
        j = None                                        # op 1 cites nothing; its journal opens once its checks hold
        if open_runs(sha=spec.sha, path=spec.given):
            raise Stop("journal: an unfinished run of this spec is open: recover it (--recover) or tell the owner")
    else:
        runs = [r for r in open_runs(sha=spec.sha) if set(spec_paths(spec.given)) & set(r["paths"])]
        if len(runs) != 1:
            raise Stop("journal: op %d without its open run of this spec" % i)
        j = runs[0]
        unfinished = [k for k in range(1, i) if (j["entries"].get(str(k)) or {}).get("status") != "done"]
        if unfinished:
            raise Stop("journal: op %d before op %d finished" % (i, unfinished[0]))
    p = Plan(spec, World(), journal=j, only=i)
    p.go()
    p.show()
    if p.failed():
        raise Stop("op %d: a condition fails now (the world moved since signing): nothing written" % i)
    if p.lines[i] != lines[i - 1]:
        raise Stop("op %d: its plan line now differs from the signed one (the world moved): nothing written\n  signed %s\n  now    %s"
                   % (i, lines[i - 1], p.lines[i]))
    if j is None:
        j = p.journal = open_journal(spec, spec.given)
    text, _d = p.render(op)
    e = {"op": i, "kind": op.kind, "repo": op.repo, "id": op.id, "marker": op.marker, "reason": op.reason, "status": "sent"}
    w = p.w
    if op.kind == "issue-create":
        e.update(posted=text, title=op.title, labels=op.labels)
        payload, path, method = {"title": op.title, "body": text}, "repos/%s/issues" % op.repo, "POST"
        if op.labels:
            payload["labels"] = list(op.labels)
    elif op.kind == "issue-comment":
        num = op.number or p.created(op.ref)
        e.update(number=num, posted=text)
        payload, path, method = {"body": text}, "repos/%s/issues/%d/comments" % (op.repo, num), "POST"
    elif op.kind == "comment-edit":
        c = w.read("repos/%s/issues/comments/%d" % (op.repo, op.number))
        e.update(comment=op.number, before={"body": body_of(c)}, posted=text)
        payload, path, method = {"body": text}, "repos/%s/issues/comments/%d" % (op.repo, op.number), "PATCH"
    elif op.kind == "pr-body-edit":
        pr = w.read("repos/%s/pulls/%d" % (op.repo, op.number))
        e.update(number=op.number, before={"body": body_of(pr)}, posted=text)
        payload, path, method = {"body": text}, "repos/%s/pulls/%d" % (op.repo, op.number), "PATCH"
    elif op.kind == "pr-close":
        e.update(number=op.number, head=op.head, before={"state": "open"})
        payload, path, method = {"state": "closed"}, "repos/%s/pulls/%d" % (op.repo, op.number), "PATCH"
    elif op.kind == "pr-ready":
        pr = w.read("repos/%s/pulls/%d" % (op.repo, op.number))
        node = pr.get("node_id")
        if not isinstance(node, str) or not node:
            raise G.Infra("pull request %s#%d has no node id" % (op.repo, op.number))
        e.update(number=op.number, head=op.head, node=node, before={"draft": True})
        payload, path, method = {"query": READY_MUTATION, "variables": {"id": node}}, "graphql", "POST"
    elif op.kind == "pr-create":
        e.update(base=op.base, branch=op.branch, head=op.head, title=op.title, draft=op.draft, posted=text)
        payload = {"title": op.title, "body": text, "head": op.branch, "base": op.base, "draft": op.draft}
        path, method = "repos/%s/pulls" % op.repo, "POST"
    elif op.kind == "file-pr":
        return file_pr_do(p, op, e, j, text)
    else:
        obj = w.read("repos/%s/issues/%d" % (op.repo, op.number))
        e.update(number=op.number, before={"body": body_of(obj), "title": obj.get("title"), "state": obj.get("state"),
                                           "state_reason": obj.get("state_reason")})
        path, method, payload = "repos/%s/issues/%d" % (op.repo, op.number), "PATCH", {}
        if op.kind == "issue-edit":
            if op.title is not None:
                payload["title"] = e["title"] = op.title
            if text is not None:
                payload["body"] = e["posted"] = text
        elif op.kind == "issue-reopen":
            payload["state"] = "open"
        else:
            payload.update(state="closed", state_reason=op.reason)
    j["entries"][str(i)] = e
    save_journal(j)                                     # the before-state is on disk before the write
    try:
        res = api(method, path, payload)
    except (Rejected, NotFound):
        e["status"] = "rejected"                        # GitHub said no: nothing landed, nothing to undo
        save_journal(j)
        raise
    if op.kind == "issue-create":
        num = res.get("number") if isinstance(res, dict) else None
        if not isinstance(num, int):
            raise G.Infra("the create of op %d returned no issue number" % i)
        e["number"] = num
    elif op.kind == "issue-comment":
        cid = res.get("id") if isinstance(res, dict) else None
        if not isinstance(cid, int):
            raise G.Infra("the comment of op %d returned no comment id" % i)
        e["comment"] = cid
    elif op.kind == "pr-create":
        pnum = res.get("number") if isinstance(res, dict) else None
        if not isinstance(pnum, int):
            raise G.Infra("the pull request of op %d returned no number" % i)
        e["number"] = pnum
    elif op.kind == "pr-ready":
        got = (((res.get("data") or {}).get("markPullRequestReadyForReview") or {}).get("pullRequest") or {}) \
            if isinstance(res, dict) and not res.get("errors") else {}
        if got.get("isDraft") is not False:
            raise G.Infra("the ready mutation of op %d did not answer isDraft false" % i)
    e["status"] = "done"
    save_journal(j)
    say("done op %d: %s %s%s" % (i, op.kind, op.repo, "#%d" % e["number"] if e.get("number") else
                                 " comment %d" % e["comment"] if e.get("comment") else ""))
    return OK


def file_pr_do(p, op, e, j, text):
    """file-pr's writes, each saved in the journal before the next: blob, tree and commit (objects no ref reaches, invisible until
    the branch exists), then the branch ref, then the pull request. Every input is what p.go() just read and matched against the
    signed plan line: the commit's parent is the base tip it names, the file keeps the mode of the file it replaces. Each SHA
    GitHub answers is checked: the blob's must be git's id of the pinned bytes."""
    w, repo, i = p.w, op.repo, op.i
    base_tip, root, mode, replaces, email, login = p.files[i]
    who = {"name": login, "email": email}
    blob_want = git_blob_sha(op.content)
    e.update(base=op.base, base_tip=base_tip, branch=op.branch, path=op.path, content_sha256=op.content_pin[2], blob=blob_want,
             mode=mode, replaces=replaces, title=op.title, draft=op.draft, posted=text)
    j["entries"][str(i)] = e
    save_journal(j)

    def sha_of(answer, what):
        s = answer.get("sha") if isinstance(answer, dict) else None
        if not isinstance(s, str) or not HEAD_RE.fullmatch(s):
            raise G.Infra("the %s of op %d returned no SHA" % (what, i))
        return s
    blob = sha_of(api("POST", "repos/%s/git/blobs" % repo, {"content": base64.b64encode(op.content).decode("ascii"),
                                                            "encoding": "base64"}), "blob")
    if blob != blob_want:
        raise G.Infra("the blob of op %d is %s, not git's id of the pinned bytes %s" % (i, blob, blob_want))
    tree = sha_of(api("POST", "repos/%s/git/trees" % repo, {"base_tree": root, "tree": [
        {"path": op.path, "mode": mode, "type": "blob", "sha": blob}]}), "tree")
    csha = sha_of(api("POST", "repos/%s/git/commits" % repo, {"message": op.title, "tree": tree, "parents": [base_tip],
                                                              "author": who, "committer": who}), "commit")
    e["commit"] = csha
    save_journal(j)
    try:
        api("POST", "repos/%s/git/refs" % repo, {"ref": "refs/heads/%s" % op.branch, "sha": csha})
    except (Rejected, NotFound):
        e["status"] = "rejected"                        # no branch: the objects above are unreachable, nothing to undo
        save_journal(j)
        raise
    e["ref"] = "created"
    save_journal(j)
    try:
        res = api("POST", "repos/%s/pulls" % repo, {"title": op.title, "body": text, "head": op.branch, "base": op.base,
                                                    "draft": op.draft})
    except (Rejected, NotFound):
        e["pr"] = "rejected"                            # GitHub said no: the branch exists, no pull request does
        save_journal(j)
        raise
    pnum = res.get("number") if isinstance(res, dict) else None
    if not isinstance(pnum, int):
        raise G.Infra("the pull request of op %d returned no number" % i)
    e.update(number=pnum, status="done")
    save_journal(j)
    say("done op %d: file-pr %s#%d branch %s commit %s" % (i, repo, pnum, op.branch, csha))
    return OK


def differ(name, live, want):
    """'' when equal byte for byte, else a short description."""
    a, b = live.encode("utf-8"), want.encode("utf-8")
    if a == b:
        return ""
    k = next((x for x in range(min(len(a), len(b))) if a[x] != b[x]), min(len(a), len(b)))
    return "%s differs: live %dB, posted %dB, first difference at byte %d" % (name, len(a), len(b), k)


def pr_problems(w, e):
    """What differs between the pull request a pr-ready, pr-create or file-pr op made and the live one."""
    k, repo, out = e["kind"], e["repo"], []
    obj = w.read("repos/%s/pulls/%d" % (repo, e["number"]))
    if obj is None:
        return ["%s#%d is not a pull request there" % (repo, e["number"])]
    want_head = e.get("commit") if k == "file-pr" else e["head"]
    live_head = (obj.get("head") or {}).get("sha")
    if obj.get("state") != "open" or obj.get("merged"):
        out.append("state is %s%s, not open" % (obj.get("state"), " (merged)" if obj.get("merged") else ""))
    if live_head != want_head:
        out.append("head is %s, not %s" % (live_head, want_head))
    if k == "pr-ready":
        if obj.get("draft") is not False:
            out.append("it is still a draft")
        return out
    if (obj.get("head") or {}).get("ref") != e["branch"] or (obj.get("base") or {}).get("ref") != e["base"]:
        out.append("it is %s -> %s, not %s -> %s" % ((obj.get("head") or {}).get("ref"), (obj.get("base") or {}).get("ref"),
                                                    e["branch"], e["base"]))
    if obj.get("draft") is not e["draft"]:
        out.append("draft is %s, not %s" % (obj.get("draft"), e["draft"]))
    if obj.get("title") != e["title"]:
        out.append("title differs")
    out.append(differ("body", body_of(obj), e["posted"]))
    if k == "file-pr":
        entry, _root = tree_entry(w, repo, e["commit"], e["path"])
        if not entry or entry.get("sha") != e["blob"] or entry.get("mode") != e["mode"]:
            out.append("%s at %s is not blob %s mode %s (the pinned bytes)" % (
                e["path"], e["commit"][:12], e["blob"][:12], e["mode"]))
        out.extend(tree_drift(w, repo, e["base_tip"], e["commit"], e["path"]))
        c = w.read("repos/%s/git/commits/%s" % (repo, e["commit"]))
        parents = [x.get("sha") for x in (c or {}).get("parents") or [] if isinstance(x, dict)] if isinstance(c, dict) else []
        if parents != [e["base_tip"]]:
            out.append("commit %s does not have the one parent %s" % (e["commit"][:12], e["base_tip"][:12]))
    return out


def mode_postcheck(spec_path):
    j = the_open_run(spec_path)
    if not j:
        raise Stop("no open run of this spec file to post-check")
    if spec_sha_now(spec_path) != j["spec"]:
        raise Stop("the spec file changed during the run (sha256 %s at op 1): the run cannot be confirmed" % j["spec"][:16])
    w, bad = World(), 0
    for i in range(1, j["n"] + 1):
        e = j["entries"].get(str(i))
        problems = []
        if not e or e.get("status") != "done":
            problems.append("op %d did not finish" % i)
        else:
            k, repo = e["kind"], e["repo"]
            if k in ("pr-ready", "pr-create", "file-pr"):
                problems.extend(pr_problems(w, e))
            elif k == "issue-comment" or k == "comment-edit":
                c = w.read("repos/%s/issues/comments/%d" % (repo, e["comment"]))
                if c is None:
                    problems.append("comment %d is not there" % e["comment"])
                else:
                    problems.append(differ("body", body_of(c), e["posted"]))
                    url = str(c.get("issue_url") or "")
                    on = url.rsplit("/repos/", 1)[-1] if "/repos/" in url else ""
                    if k == "issue-comment" and not same_repo(on, "%s/issues/%d" % (repo, e["number"])):
                        problems.append("comment %d is not on %s#%d" % (e["comment"], repo, e["number"]))
            else:
                obj = w.read(("repos/%s/pulls/%d" if k in ("pr-body-edit", "pr-close") else "repos/%s/issues/%d") % (repo, e["number"]))
                if obj is None:
                    problems.append("%s#%d is not there" % (repo, e["number"]))
                else:
                    if "posted" in e:
                        problems.append(differ("body", body_of(obj), e["posted"]))
                    if e.get("title") is not None and obj.get("title") != e["title"]:
                        problems.append("title differs")
                    want = {"issue-create": "open", "issue-reopen": "open", "issue-close": "closed", "pr-close": "closed"}.get(k)
                    if want and obj.get("state") != want:
                        problems.append("state is %s, not %s" % (obj.get("state"), want))
                    if k == "pr-close" and obj.get("merged"):
                        problems.append("merged, not closed")
                    if k == "issue-close" and obj.get("state_reason") != e["reason"]:
                        problems.append("closed as %s, not %s" % (obj.get("state_reason"), e["reason"]))
                    if k == "issue-create":
                        have = set(x.get("name") for x in obj.get("labels") or [] if isinstance(x, dict))
                        if not set(e.get("labels") or []) <= have:
                            problems.append("labels %s missing" % sorted(set(e["labels"]) - have))
        problems = [x for x in problems if x]
        say("  %-4s  postcheck: op %d %s" % ("ok" if not problems else "FAIL", i, "; ".join(problems) or "holds, byte for byte"))
        bad += bool(problems)
    if bad:
        return FAIL
    close_journal(j, "done")
    return OK


def pending_undo(j):
    return [int(k) for k, e in sorted(j["entries"].items(), key=lambda kv: -int(kv[0]))
            if e.get("status") in ("sent", "done")]


def describe_undo(e):
    k, repo = e["kind"], e["repo"]
    num = "%s#%s" % (repo, e.get("number") or "?")
    return {"issue-create": "close %s as not planned (created by op %d)" % (num, e["op"]),
            "issue-comment": "retract comment %s on %s (posted by op %d)" % (e.get("comment") or "?", num, e["op"]),
            "comment-edit": "put back the body of comment %s in %s" % (e.get("comment"), repo),
            "issue-edit": "put back the title and body of %s" % num,
            "pr-body-edit": "put back the body of %s" % num,
            "issue-reopen": "close %s again" % num,
            "issue-close": "reopen %s" % num,
            "pr-close": "reopen pull request %s (closed by op %d)" % (num, e["op"]),
            "pr-ready": "turn pull request %s back into a draft (marked ready by op %d)" % (num, e["op"]),
            "pr-create": "close pull request %s (opened by op %d)" % (num, e["op"]),
            "file-pr": "close pull request %s (opened by op %d); branch %s stays, named for the owner" % (
                num, e["op"], e.get("branch"))}[k]


def mode_undo_plan(spec_path):
    j = the_open_run(spec_path)
    if not j:
        say("nothing to undo: no open run of this spec file")
        return OK
    if not pending_undo(j):                             # every write GitHub refused, or none started: the run is over
        close_journal(j, "undone")
        say("nothing to undo: no write of this run landed")
        return OK
    for i in pending_undo(j):
        say("undo-step: %d %s" % (i, describe_undo(j["entries"][str(i)])))
    return OK


def find_by_marker(path, marker, tries=2):
    """A list lookup (fine for an undo check), with a short retry for a list that lags behind a create."""
    for t in range(tries):
        hits = [x for x in get(path, pages=True) if marker in body_of(x)]
        if hits or t == tries - 1:
            return hits
        time.sleep(1)
    return []


LOST = "the write may have landed and the list does not show it yet: left for the owner"


def undo_entry(j, i):
    """Undo one entry; "undone", "untouched" (the write never landed), or a refusal text (the state is left alone)."""
    e = j["entries"][str(i)]
    k, repo, w = e["kind"], e["repo"], World()
    if k == "issue-create":
        num = e.get("number")
        if not num:
            hits = find_by_marker("repos/%s/issues?state=all&creator=%s&per_page=100" % (repo, q(w.viewer())), e["marker"])
            if len(hits) > 1:
                return "%d issues hold the marker: left alone" % len(hits)
            if not hits:
                return LOST
            num = e["number"] = hits[0].get("number")
        obj = w.read("repos/%s/issues/%d" % (repo, num))
        if obj is None or obj.get("state") == "closed":
            return "undone"
        payload = {"state": "closed", "state_reason": "not_planned"}
        if body_of(obj) == e["posted"] and e.get("marker"):
            payload["body"] = e["posted"].replace(e["marker"], "")     # our own body: a later run of the spec is not blocked
        api("PATCH", "repos/%s/issues/%d" % (repo, num), payload)
        return "undone"
    if k == "issue-comment":
        cid = e.get("comment")
        if not cid:
            hits = find_by_marker("repos/%s/issues/%d/comments?per_page=100" % (repo, e["number"]), e["marker"])
            if len(hits) > 1:
                return "%d comments hold the marker: left alone" % len(hits)
            if not hits:
                return LOST
            cid = e["comment"] = hits[0].get("id")
        c = w.read("repos/%s/issues/comments/%d" % (repo, cid))
        live = body_of(c) if c is not None else None
        if c is None or live == RETRACTED:
            return "undone"
        if live != e["posted"]:
            return "comment %d changed since the run: left alone" % cid
        api("PATCH", "repos/%s/issues/comments/%d" % (repo, cid), {"body": RETRACTED})
        return "undone"
    if k in ("comment-edit", "pr-body-edit"):
        path = ("repos/%s/issues/comments/%d" % (repo, e["comment"]) if k == "comment-edit"
                else "repos/%s/pulls/%d" % (repo, e["number"]))
        obj = w.read(path)
        live = body_of(obj) if obj is not None else None
        if live == e["before"]["body"]:
            return "untouched"
        if live != e["posted"]:
            return "the body changed since the run: left alone"
        api("PATCH", path, {"body": e["before"]["body"]})
        return "undone"
    if k == "pr-ready":
        path = "repos/%s/pulls/%d" % (repo, e["number"])
        obj = w.read(path)
        if obj is None:
            return "%s#%d is gone: left alone" % (repo, e["number"])
        if obj.get("draft") is True:
            return "untouched"
        if obj.get("state") != "open" or obj.get("merged"):
            return "%s#%d is %s since the run: left alone" % (repo, e["number"], "merged" if obj.get("merged") else obj.get("state"))
        if (obj.get("head") or {}).get("sha") != e["head"]:
            return "%s#%d has a new head since the run: left alone" % (repo, e["number"])
        res = api("POST", "graphql", {"query": DRAFT_MUTATION, "variables": {"id": e["node"]}})
        got = (((res.get("data") or {}).get("convertPullRequestToDraft") or {}).get("pullRequest") or {}) \
            if isinstance(res, dict) and not res.get("errors") else {}
        if got.get("isDraft") is not True:
            raise G.Infra("the draft mutation did not answer isDraft true")
        return "undone"
    if k in ("pr-create", "file-pr"):
        return undo_opened_pr(w, e)
    if k == "pr-close":
        path = "repos/%s/pulls/%d" % (repo, e["number"])
        obj = w.read(path)
        if obj is None:
            return "%s#%d is gone: left alone" % (repo, e["number"])
        if obj.get("merged"):
            return "%s#%d was merged since the run: left alone" % (repo, e["number"])
        if obj.get("state") == "open":
            return "untouched"
        iss = w.read("repos/%s/issues/%d" % (repo, e["number"]))           # a PR's `closed_by` is on its issue view
        who = ((iss or {}).get("closed_by") or {}).get("login")
        if who != w.viewer():
            return "%s#%d was closed by %s, not by this run: left alone" % (repo, e["number"], who or "someone unknown")
        api("PATCH", path, {"state": "open"})
        return "undone"
    path = "repos/%s/issues/%d" % (repo, e["number"])
    obj = w.read(path)
    b = e["before"]
    if obj is None:
        return "%s#%d is gone: left alone" % (repo, e["number"])
    if k == "issue-edit":
        mine = (e.get("title") is None or obj.get("title") == e["title"]) and ("posted" not in e or body_of(obj) == e["posted"])
        if obj.get("title") == b["title"] and body_of(obj) == b["body"]:
            return "untouched"
        if not mine:
            return "the title or body changed since the run: left alone"
        payload = {}
        if e.get("title") is not None:
            payload["title"] = b["title"]
        if "posted" in e:
            payload["body"] = b["body"]
        api("PATCH", path, payload)
        return "undone"
    if k == "issue-reopen":
        if obj.get("state") == "closed":
            return "untouched"
        reason = b.get("state_reason") if b.get("state_reason") in CLOSE_REASONS else "completed"
        api("PATCH", path, {"state": "closed", "state_reason": reason})
        return "undone"
    if obj.get("state") == "open":
        return "untouched"
    if obj.get("state_reason") != e["reason"]:
        return "closed as %s since the run: left alone" % obj.get("state_reason")
    api("PATCH", path, {"state": "open"})
    return "undone"


def undo_opened_pr(w, e):
    """Close the pull request a pr-create or file-pr op opened, while it is open, not merged and at the head the run gave it.
    A create whose answer was lost is found by its branch and the viewer. file-pr's branch is never deleted: while it is
    there, the step names it and fails (the skill's rule for an undo that cannot delete)."""
    r = undo_pr_only(w, e)
    if r != "undone" or e["kind"] != "file-pr" or not e.get("ref"):
        return r
    if ref_tip(World(), e["repo"], e["branch"]) is None:      # a fresh read: the owner may have deleted it meanwhile
        return "undone"
    return "branch %s of %s stays: this baton never deletes a branch; the owner deletes it (irreversible-delete)" % (
        e["branch"], e["repo"])


def run_prs(w, e, want, tries=2):
    """The pull requests that may be the one a create whose answer was lost opened: from its branch into its base, by the
    viewer, at the head the run gave it (an older PR from the same branch is at another head). A list that lags behind a create
    is read again once, after a second, as find_by_marker does."""
    for k in range(tries):
        got = get("repos/%s/pulls?state=all&head=%s&base=%s&per_page=100" % (
            e["repo"], q("%s:%s" % (e["repo"].split("/")[0], e["branch"])), q(e["base"])), pages=True)
        hits = [x for x in got if isinstance(x, dict) and (x.get("head") or {}).get("ref") == e["branch"]
                and (x.get("base") or {}).get("ref") == e["base"] and (x.get("head") or {}).get("sha") == want
                and (x.get("user") or {}).get("login") == w.viewer()]
        if hits or k == tries - 1:
            return hits
        time.sleep(1)
    return []


def undo_pr_only(w, e):
    repo, num = e["repo"], e.get("number")
    kept = ("; branch %s of %s stays (this baton never deletes a branch)" % (e["branch"], repo)
            if e["kind"] == "file-pr" and e.get("ref") else "")
    want = e.get("commit") if e["kind"] == "file-pr" else e["head"]
    pr_unsent = e["kind"] == "file-pr" and not e.get("ref")      # the PR POST comes only after the ref answered
    if not num:
        if e["kind"] == "file-pr" and not e.get("ref"):
            at = ref_tip(w, repo, e["branch"])
            if at is None or not e.get("commit"):
                return "untouched"                      # no branch, or none this run could have made: nothing of the run lands
            if at != e.get("commit"):
                return "branch %s of %s is at %s, not this run's commit: left alone" % (e["branch"], repo, at)
            e["ref"] = "created"
            kept = "; branch %s of %s stays (this baton never deletes a branch)" % (e["branch"], repo)
        theirs = run_prs(w, e, want)
        if len(theirs) > 1:
            return "%d pull requests of %s from %s: left alone" % (len(theirs), w.viewer(), e["branch"])
        if len(theirs) == 0:
            if e["kind"] == "file-pr" and (e.get("pr") == "rejected" or pr_unsent):
                say("undo op %d: no pull request was opened%s" % (e["op"], kept))
                return "undone"
            return LOST                                 # it may have landed and the list does not show it yet
        num = e["number"] = theirs[0].get("number")
    path = "repos/%s/pulls/%d" % (repo, num)
    obj = w.read(path)
    if obj is None:
        return "%s#%d is gone: left alone" % (repo, num)
    if obj.get("merged"):
        return "%s#%d was merged since the run: left alone%s" % (repo, num, kept)
    if obj.get("state") != "open":
        say("undo op %d: %s#%d is already closed%s" % (e["op"], repo, num, kept))
        return "undone"
    if (obj.get("head") or {}).get("sha") != want:
        return "%s#%d has a new head since the run: left alone%s" % (repo, num, kept)
    api("PATCH", path, {"state": "closed"})
    if kept:
        say("undo op %d: closed %s#%d%s" % (e["op"], repo, num, kept))
    return "undone"


def mode_undo_step(spec_path, i, recovering=False):
    """Undo op i of the open run. In a recovery, a state the undo must leave alone is marked `left` and the recovery goes on;
    the run then closes as `left`, and the recovery's post-check fails, so the owner is told."""
    j = the_open_run(spec_path)
    if not j or str(i) not in j["entries"]:
        say("nothing to undo for op %d" % i)
        return OK
    e = j["entries"][str(i)]
    if e.get("status") not in ("sent", "done"):
        say("op %d is already %s" % (i, e.get("status")))
        return OK
    result = undo_entry(j, i)
    if result not in ("undone", "untouched"):
        if not recovering:
            save_journal(j)
            raise Stop("undo op %d: %s" % (i, result))
        e["status"], e["left"] = "left", result
        say("LEFT op %d: %s" % (i, result))
    else:
        e["status"] = result
        say("undo op %d: %s" % (i, result))
    if not pending_undo(j):
        close_journal(j, "left" if any(x.get("status") == "left" for x in j["entries"].values()) else "undone")
    else:
        save_journal(j)
    return OK


# ── --recover: the undo of a run left open, as a plan of its own ────────────────────────────────────────────────────────────────
def recover_lines(j, steps=None):
    """[(entry, plan line)]: the steps of a recovery, newest op first; a run with nothing to undo still has one step, which
    closes the journal."""
    steps = steps if steps is not None else (pending_undo(j) or [0])
    m = len(steps)
    return [(i, "gh-write recover %d/%d run %s spec %s %s" % (
        k, m, j["run"], j["spec"], "op %d: %s" % (i, describe_undo(j["entries"][str(i)])) if i else "close the journal (nothing to undo)"))
        for k, i in enumerate(steps, 1)]


def mode_recover_plan(spec_path):
    j = the_open_run(spec_path)
    say("  %-4s  journal: %s" % ("ok" if j else "FAIL", "an open run of this spec file (run %s, started %s)" % (j["run"], j.get("started"))
                                 if j else "no open run of this spec file: nothing to recover"))
    if not j:
        return FAIL
    lines = recover_lines(j)
    for _i, ln in lines:
        say("op-plan: %s" % ln)
    say("PLAN-COUNT %d" % len(lines))
    return OK


def mode_recover_do(spec_path, k, plan_file):
    """Recovery step k of the signed plan. Its steps are frozen in the journal by the first step of this signed plan, so the
    later steps still match it after the earlier ones have changed the journal."""
    j = the_open_run(spec_path)
    if not j:
        raise Stop("no open run of this spec file to recover")
    try:
        with open(plan_file, "rb") as f:
            psha = sha256(f.read())
    except OSError as e:
        raise Stop("refuse-plan: cannot read the signed plan: %s" % e)
    frozen = j.get("recover") if isinstance(j.get("recover"), dict) and j["recover"].get("plan") == psha else None
    if frozen is None and k != 1:
        raise Stop("refuse-plan: recover step %d of a plan whose first step never ran" % k)
    steps = frozen["steps"] if frozen else (pending_undo(j) or [0])
    lines = recover_lines(j, steps)
    signed = signed_plan(plan_file, len(lines), lambda x: "gh-write recover %d/%d run %s " % (x, len(lines), j["run"]))
    if not 1 <= k <= len(lines) or signed[k - 1] != lines[k - 1][1]:
        raise Stop("refuse-plan: recover step %d differs from the signed one (the run moved): nothing written" % k)
    if frozen is None:                                  # the signed plan holds: its steps are frozen for its later steps
        j["recover"] = {"plan": psha, "steps": steps}
        save_journal(j)
    i = lines[k - 1][0]
    if i == 0:
        close_journal(j, "undone")
        say("recover: the journal is closed")
        return OK
    return mode_undo_step(spec_path, i, recovering=True)


def mode_recover_postcheck(spec_path):
    if the_open_run(spec_path):
        raise Stop("the run is still open after the recovery")
    names = set(spec_paths(spec_path))
    mine = sorted((j for j in journals() if names & set(j["paths"])), key=lambda j: j.get("closed") or "")
    last = mine[-1] if mine else None
    if last and last.get("state") == "left":
        left = ["op %s: %s" % (k, e.get("left")) for k, e in sorted(last["entries"].items()) if e.get("status") == "left"]
        say("  FAIL  postcheck: the run is closed, but its undo left %d state%s alone: %s" % (
            len(left), "" if len(left) == 1 else "s", "; ".join(left)))
        return FAIL
    say("  ok    postcheck: no open run of this spec file")
    return OK


USAGE_TEXT = __doc__.split("\n\n")[0]


def main(argv):
    if argv in (["-h"], ["--help"]):
        say(__doc__.strip())
        return OK
    a, k = {}, 0
    flags = {"--spec": True, "--do": True, "--expect-plan": True, "--postcheck": False, "--undo-plan": False, "--undo-step": True,
             "--recover": False}
    while k < len(argv):
        f = argv[k]
        if f not in flags or f in a:
            say("gh_write: unknown or repeated argument %r\n%s" % (f, USAGE_TEXT), sys.stderr)
            return USAGE
        if flags[f]:
            if k + 1 >= len(argv):
                say("gh_write: %s needs a value" % f, sys.stderr)
                return USAGE
            a[f] = argv[k + 1]
            k += 2
        else:
            a[f] = True
            k += 1
    modes = [m for m in ("--do", "--postcheck", "--undo-plan", "--undo-step") if m in a]
    if "--spec" not in a or len(modes) > 1 or ("--do" in a) != ("--expect-plan" in a) or ("--recover" in a and "--undo-step" in a):
        say("gh_write: --spec, and at most one of --do (with --expect-plan), --postcheck, --undo-plan, --undo-step\n%s"
            % USAGE_TEXT, sys.stderr)
        return USAGE
    for f in ("--do", "--undo-step"):
        if f in a and not re.fullmatch(r"[1-9][0-9]*", a[f]):
            say("gh_write: %s takes a step number" % f, sys.stderr)
            return USAGE
    path = a["--spec"]
    try:
        if "--recover" in a:                            # the spec's bytes may be anything now: the run is found by its path
            if "--do" in a:
                return mode_recover_do(path, int(a["--do"]), a["--expect-plan"])
            if "--postcheck" in a:
                return mode_recover_postcheck(path)
            if "--undo-plan" in a:
                raise Stop("a recovery is an undo; it is not undone in turn: tell the owner what it left")
            return mode_recover_plan(path)
        if "--postcheck" in a:
            return mode_postcheck(path)
        if "--undo-plan" in a:
            return mode_undo_plan(path)
        if "--undo-step" in a:
            return mode_undo_step(path, int(a["--undo-step"]))
        spec = Spec(path)
        if "--do" in a:
            return mode_do(spec, int(a["--do"]), a["--expect-plan"])
        return mode_plan(spec)
    except Refuse as e:
        say("REFUSE %s" % e, sys.stderr)
        return USAGE
    except Stop as e:
        say("REFUSE %s" % e, sys.stderr)
        return FAIL
    except (G.Infra, OSError) as e:
        say("gh_write: could not conclude: %s" % e, sys.stderr)
        return INFRA


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
