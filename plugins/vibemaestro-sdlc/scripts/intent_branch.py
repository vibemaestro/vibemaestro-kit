#!/usr/bin/env python3
"""Lifecycle of the `intent/*` branch: the ONE path that creates, splits and integrates the branches of an intent.

The usage `--help` prints (the model, the decisions (a) to (g) this core enforces, why, the subcommands and the exit codes) is
`ib.usage` of messages.py, in the repo's `language`; every message this core prints is a key `ib.*` there.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.parse

# `open_pr.py` luôn nằm cạnh file này (skill cài theo cả thư mục), nên phép dò
# worktree chỉ có MỘT bản — kể cả phần gỡ GIT_DIR/GIT_WORK_TREE khỏi env.
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from open_pr import in_linked_worktree, worktree_hint, worktree_why  # noqa: E402
import kb_plan  # noqa: E402
import messages  # noqa: E402
import sdlc_config  # noqa: E402

RC_ENV, RC_INTENT_FILE, RC_BLOCK, RC_TARGET, RC_EXISTS, RC_USAGE = 2, 3, 4, 5, 6, 64
RC_WRONG_TREE = 7
RC_INTAKE = 9                    # under intake.focus required: no `type:`/`focus:`, or a focus not open; nothing was created

# Defaults of `branch.protected` and `branch.intent_prefix`; `main()` replaces them from `.vibemaestro/sdlc.json` of the repo.
PROTECTED = ("main", "master")

PREFIX = "intent/"

ISSUE_CODE = None   # `issue.code`: the repository's 3-letter code, or None (branches keep `intent/<date>-<slug>`)

INFRA_LABEL = None  # `infra.label`: the label an issue for work that needs infrastructure help carries, or None (off)

LANG = "vi"     # the language of the messages (messages.py): `main` sets it from the repo at `--cwd`


def M(key, *args):
    """A message of messages.py in the repo's language."""
    return messages.text(key, LANG, *args)


def apply_config(cwd):
    """Load the repo's config into PREFIX and PROTECTED. rc 0, or RC_USAGE (64) naming the key of an invalid config.
    A directory that is not a git repo keeps the defaults: the command reports that itself."""
    global PREFIX, PROTECTED, REBASE_IDENTITY, INTAKE_FOCUS, ISSUE_CODE, INFRA_LABEL
    rc, top = git("rev-parse", "--show-toplevel", cwd=cwd)
    if rc != 0:
        return 0
    cfg, probs, _present = sdlc_config.load(top)
    if probs:
        err("%s is invalid; fix it (kb.py config check lists every problem):\n%s" % (sdlc_config.CONFIG_REL, sdlc_config.render_problems(probs)))
        return RC_USAGE
    PREFIX = cfg["branch"]["intent_prefix"]
    PROTECTED = tuple(cfg["branch"]["protected"])
    REBASE_IDENTITY = cfg["rebase"]["identity"]
    INTAKE_FOCUS = cfg["intake"]["focus"]
    ISSUE_CODE = cfg["issue"]["code"]
    INFRA_LABEL = cfg["infra"]["label"]
    return 0


def err(msg):
    print("intent_branch: " + msg, file=sys.stderr)


def git(*args, cwd=None, env=None):
    """(rc, stdout+stderr stripped). Never raises: the caller decides. `env`: variables added to or overriding the environment."""
    try:
        r = subprocess.run(["git"] + list(args), cwd=cwd,
                           env=dict(os.environ, **env) if env else None,
                           capture_output=True, text=True, timeout=120)
    except Exception as e:                       # git không có, treo…
        return 1, str(e)
    return r.returncode, (r.stdout + r.stderr).strip()


# ---------------------------------------------------------------------------
# Git identity of the rebase inside `integrate`
# ---------------------------------------------------------------------------
# `git rebase` CREATES commits, so it needs a committer identity. The order, with no fourth source:
#   1. `rebase.identity` ({name, email}) of the config: it wins over everything, including the GIT_COMMITTER_* variables of the
#      environment, because a repo that declares a machine identity for machine commits wants exactly that one;
#   2. the identity git itself resolves: `git var GIT_COMMITTER_IDENT` reads GIT_COMMITTER_NAME/EMAIL of the environment and
#      `user.name`/`user.email` of git config, which is exactly what `git rebase` will read. The core reads no variable of its
#      own and invents no name or address: a sandbox session and a workstation already have an identity the way git wants it;
#   3. when git cannot resolve one, rc 2 BEFORE the rebase, with a hint naming both ways out. Letting the rebase die with
#      "Committer identity unknown" would return rc 4, as if the branch could not be integrated, and hide the real cause.
# `GIT_AUTHOR_*` alone is NOT enough: a rebase needs the committer, and `git var` says exactly that.
#
# `commit.gpgsign=false` is always passed: gpg picks the signing key BY `user.email`, so a machine identity on a host with a
# global `commit.gpgsign=true` goes looking for the key of that address and dies with "No secret key". Commits made by a rebase
# are machine commits, not a person's signature. (The premise is checkable with `git config --global --get commit.gpgsign`; the
# consequence cannot be replayed once patched: this records the reason, it is not a measurement.)
REBASE_IDENTITY = None             # `rebase.identity` of the config, set by apply_config
IDENTITY_HINT = ("no identity for the rebase: set `rebase.identity` ({name, email}) in %s, or set a git identity "
                 "(`git config user.name` and `user.email`, or GIT_COMMITTER_NAME and GIT_COMMITTER_EMAIL)" % sdlc_config.CONFIG_REL)


def git_identity(cwd):
    """(git args, env overrides) for the rebase, or None when no committer identity can be resolved."""
    args, env = ["-c", "commit.gpgsign=false"], {}
    if REBASE_IDENTITY:
        n, e = REBASE_IDENTITY["name"], REBASE_IDENTITY["email"]
        # The env variables outrank `-c user.*`, so they are overridden too, or an ambient GIT_COMMITTER_* would win.
        env = {"GIT_COMMITTER_NAME": n, "GIT_COMMITTER_EMAIL": e}
        return ["-c", "user.name=%s" % n, "-c", "user.email=%s" % e] + args, env
    rc, _ = git("var", "GIT_COMMITTER_IDENT", cwd=cwd)
    return (args, env) if rc == 0 else None


def repo_root(cwd):
    rc, out = git("rev-parse", "--show-toplevel", cwd=cwd)
    if rc != 0:
        err(M("ib.not_repo", cwd))
        return None
    return out


def norm_intent(name):
    """`slug` hoặc `intent/slug` → `intent/slug`. Trả None nếu rỗng."""
    if not name:
        return None
    name = name.strip().strip("/")
    if not name:
        return None
    return name if name.startswith(PREFIX) else PREFIX + name


def slug_of(intent_branch):
    return intent_branch[len(PREFIX):]


def ref_exists(ref, cwd):
    rc, _ = git("rev-parse", "--verify", "--quiet", ref + "^{commit}", cwd=cwd)
    return rc == 0


def is_protected(branch, cwd):
    """Nhánh nguồn có phải main/master, dưới BẤT KỲ cách viết nào?

    `main`, `heads/main`, `refs/heads/main` là cùng một nhánh; `origin/main` là
    ref remote-tracking — rebase checkout nó ra detached HEAD rồi push nội dung
    của main vào intent. Hỏi git tên đầy đủ (`--symbolic-full-name`) thay vì
    đoán tiền tố; phép gỡ tiền tố theo văn bản giữ lại cho ref không tồn tại,
    vì chặn này đứng TRƯỚC phép kiểm tồn tại.
    """
    names = [branch]
    rc, full = git("rev-parse", "--symbolic-full-name", branch, cwd=cwd)
    if rc == 0 and full:
        names.append(full.splitlines()[0])
    for n in names:
        for pre in ("refs/heads/", "heads/"):
            if n.startswith(pre):
                n = n[len(pre):]
                break
        if n in PROTECTED:
            return True
        parts = n.split("/")
        if n.startswith("refs/remotes/") and len(parts) == 4 and parts[3] in PROTECTED:
            return True
    return False


def resolve_tip(intent_branch, cwd, override=None):
    """Ref mang tip của intent. origin trước — nó là bản mọi worker cùng thấy."""
    for cand in ([override] if override else []) + \
                ["origin/" + intent_branch, intent_branch]:
        if ref_exists(cand, cwd):
            return cand
    return None


def branch_held_elsewhere(branch, cwd):
    """Worktree KHÁC đang giữ branch này? Trả về đường dẫn worktree đó, hay None.

    `git worktree list --porcelain` in từng khối `worktree <path>` / `branch
    refs/heads/<name>`. Đọc nó thay vì đoán, vì thông điệp của `git checkout`
    trong ca này ("is already used by worktree at") là thứ đổi theo phiên bản
    git — neo vào văn bản lỗi là neo vào bản dịch.
    """
    rc, out = git("worktree", "list", "--porcelain", cwd=cwd)
    if rc != 0:
        return None
    here, path = None, None
    rc2, this_dir = git("rev-parse", "--show-toplevel", cwd=cwd)
    for line in out.splitlines():
        if line.startswith("worktree "):
            path = line[len("worktree "):]
        elif line.startswith("branch refs/heads/"):
            if line[len("branch refs/heads/"):] == branch:
                here = path
    if here and rc2 == 0 and os.path.realpath(here) == os.path.realpath(this_dir):
        return None                              # chính mình giữ — không vướng
    return here


# ---------------------------------------------------------------------------
# (a) cổng kb/intent — tạo branch intent phải có hồ sơ intent trước
# ---------------------------------------------------------------------------
# Tên file suy được từ tên branch nên phép kiểm là CHÍNH XÁC, không phải đoán:
# `intent/<ngày>-<slug>` ↔ `kb/intent/<ngày>-<slug>.md`. Đọc cây làm việc chứ
# không đọc `origin/main`: PM ghi file rồi mới tạo branch, nên lúc cổng chạy
# file thường còn chưa commit.
# A key branch `intent/<KEY>-<slug>` (`issue.code`) is the intent whose frontmatter says `key: <KEY>` (kb_plan.intent_of_branch).
def intent_doc_path(root, intent_branch):
    rel = kb_plan.intent_of_branch(root, slug_of(intent_branch)) or "kb/intent/%s.md" % slug_of(intent_branch)
    return os.path.join(root, rel)


# ---------------------------------------------------------------------------
# Issue GitHub theo dõi intent (01/10/2026)
# ---------------------------------------------------------------------------
# Quyết định và lý do: kb/decisions/2026-10-01-gan-vong-doi-intent-voi-github-
# issues.md. Nội dung chỉ nằm ở `kb/intent/<slug>.md` — issue chỉ là một bản
# tóm tắt + link, hai nơi không lệch nhau.
#
# Tạo issue là BEST-EFFORT, không chặn việc tạo branch: môi trường có thể thiếu
# `gh`, mạng, hoặc quyền `Issues` của token — đã đo 01/10, một GitHub App cài ở
# một repo KHÔNG có quyền đó (403 "Resource not accessible by integration" trên
# cả GET lẫn POST `/issues`, trong khi tạo LABEL bằng cùng token vẫn thành công). Branch là thứ `integrate`
# cần để góp ngược; issue chỉ là theo dõi. Hỏng thì báo rõ ra stderr, KHÔNG giả
# vờ đã tạo (không điền số issue bịa, không thử đường vòng nào khác).
ISSUE_LABEL = "intent"
# A fresh repo has only GitHub's default labels, so `gh issue create --label intent` fails there. The label is
# created (and its result ignored) right before the issue: `gh label create` on an existing label exits 1 and changes
# nothing, so this is idempotent. Fixed constants, not configuration.
ISSUE_LABEL_COLOR = "5319e7"
ISSUE_LABEL_DESC = "Tracks a kb/intent record"
ISSUE_URL_RX = re.compile(r"(\S*/issues/(\d+))\s*$")
FRONTMATTER_ISSUE_RX = re.compile(r"^issue:\s*\d+\s*$", re.M)


def doc_description(doc_path):
    """Giá trị `description:` trong frontmatter — một dòng, có/không nháy kép."""
    try:
        text = open(doc_path, encoding="utf-8").read()
    except OSError:
        return None
    m = re.search(r'^description:\s*"?(.*?)"?\s*$', text, re.M)
    return m.group(1) if m else None


def set_doc_issue(doc_path, number):
    """Ghi/sửa dòng `issue: N` trong frontmatter của hồ sơ intent. Idempotent.

    Trả True nếu có GHI THẬT, False nếu hồ sơ không mở đầu bằng `---` (không
    frontmatter) — khi đó không dòng nào khớp để sửa, và hồ sơ ĐƯỢC GIỮ NGUYÊN
    thay vì âm thầm không đổi gì trong khi người gọi tưởng đã ghi xong.
    """
    return set_front_line(doc_path, FRONTMATTER_ISSUE_RX, "issue: %d" % number)


def set_front_line(doc_path, rx, line):
    """Replace the frontmatter line `rx` matches with `line`, or add `line` right under the opening `---`; a line of the same
    shape in the body is never touched. False (nothing written) when the file has no closed `---` block (kb_index.front_block)."""
    import kb_index
    lines = open(doc_path, encoding="utf-8").read().split("\n")
    n = kb_index.front_block(lines)[1]
    if not n:
        return False
    at = next((i for i in range(1, n - 1) if rx.match(lines[i])), None)
    if at is None:
        lines.insert(1, line)
    else:
        lines[at] = line
    with open(doc_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    return True


def front_issue(doc_path):
    """The `issue:` value of the intent's frontmatter, stripped ("" when there is none); never a body line."""
    return str(doc_front(doc_path).get("issue") or "").strip()


def set_doc_key(doc_path, key):
    """Write `key: <key>` into the intent's frontmatter (set_front_line). Idempotent."""
    return set_front_line(doc_path, re.compile(r"^key:"), "key: %s" % key)


def keyed_intent(a, doc, root):
    """(rc, branch) under `issue.code`: the branch `intent/<CODE>-<issue>-<slug>` of the intent at `doc`, its key written as `key:`.
    The branch needs the issue number, so the issue is opened first, unless the intent's frontmatter names one (a worker's, or a
    retry); rc 1 when it cannot be: no branch is created without its key."""
    rel = os.path.relpath(doc, root)
    stem = os.path.basename(doc)[:-len(".md")]
    import kb_index
    if not kb_index.front_block(open(doc, encoding="utf-8").read().split("\n"))[1]:
        err("issue.code is %s: the key goes into the intent's frontmatter, and %s has none (a `---` block at its top); nothing "
            "was created" % (ISSUE_CODE, rel))
        return 1, None
    issue = front_issue(doc)
    if issue and not re.match(r"^[1-9][0-9]*$", issue):
        err("issue.code is %s: `issue: %s` in %s is not an issue number; nothing was created" % (ISSUE_CODE, issue, rel))
        return 1, None
    if not issue and not getattr(a, "issue", False):
        err("issue.code is %s: the branch is named after the issue, and %s has no `issue: N` and --no-issue opens none; nothing "
            "was created (run without --no-issue, or add `issue: N` by hand)" % (ISSUE_CODE, rel))
        return 1, None
    if not ref_exists(a.base, a.cwd):
        err(M("ib.no_base", a.base))
        return RC_TARGET, None
    if issue:
        number = int(issue)
    else:
        number, issue_err, url = create_tracking_issue(doc, PREFIX + stem, root, a.cwd, a.infra)
        if number is None:
            err("could not create the tracking issue: %s\n"
                "       issue.code is %s, so the branch needs its number: NO BRANCH WAS CREATED. Check `gh issue list --label "
                "intent` first (a call that timed out may still have created one: add `issue: N` to %s), then run create-intent "
                "again once the cause is fixed" % (issue_err, ISSUE_CODE, rel))
            return 1, None
        report_issue_created(doc, root, number, url)
    key = "%s-%d" % (ISSUE_CODE, number)
    set_doc_key(doc, key)
    err("key %s recorded in %s" % (key, rel))
    return 0, PREFIX + kb_plan.branch_names("kb/intent/%s.md" % stem, {"key": key})[1]


def create_tracking_issue(doc_path, intent_branch, root, cwd, infra=None):
    """(số_issue, lỗi, URL của issue). `lỗi` là None khi thành công — không bao giờ raise. `infra`: the `Infra:` line of work that
    needs infrastructure help (sdlc_config.infra_line); under `infra.label` the body carries it and the issue the label, or its
    title the `[<label>] ` prefix when the repository lacks the label, which is never created."""
    gh = shutil.which("gh")
    if not gh:
        return None, M("ib.no_gh"), None
    slug = slug_of(intent_branch)
    rel = os.path.relpath(doc_path, root)
    desc = doc_description(doc_path) or slug
    body = M("ib.issue_body", desc, rel)
    fm = doc_front(doc_path)
    valid = {"type": fm.get("type") in INTENT_TYPES, "focus": bool(FOCUS_RX.match(fm.get("focus", "")))}
    labels = [(ISSUE_LABEL, ISSUE_LABEL_DESC, ISSUE_LABEL_COLOR)] + [
        ("%s:%s" % (k, fm[k]), "The intent's %s" % k, CARD_LABEL_COLOR) for k in ("type", "focus") if valid[k]]
    for name, ldesc, color in labels:
        try:
            subprocess.run([gh, "label", "create", name, "--description", ldesc, "--color", color],
                           cwd=cwd, capture_output=True, text=True, timeout=60)
        except Exception:
            pass                                 # the issue call below reports what is really wrong
    title, names = "intent: %s" % slug, [name for name, _d, _c in labels]
    if infra and INFRA_LABEL:
        try:
            has = subprocess.run([gh, "api", "repos/{owner}/{repo}/labels/%s" % urllib.parse.quote(INFRA_LABEL, safe="")],
                                 cwd=cwd, capture_output=True, text=True, timeout=60).returncode == 0
        except Exception:
            has = False                          # unread counts as absent: the title prefix still marks the issue
        title, names = sdlc_config.infra_mark(INFRA_LABEL, has, title, names)
        body = body.rstrip("\n") + "\n\n" + infra + "\n"
    try:
        r = subprocess.run(
            [gh, "issue", "create", "--title", title,
             "--body", body] + [x for name in names for x in ("--label", name)],
            cwd=cwd, capture_output=True, text=True, timeout=60)
    except Exception as e:
        return None, str(e), None
    if r.returncode != 0:
        return None, (r.stdout + r.stderr).strip()[:400], None
    m = ISSUE_URL_RX.search(r.stdout.strip())
    if not m:
        return None, M("ib.issue_number", r.stdout.strip()[:200]), None
    return int(m.group(2)), None, m.group(1)


# ---------------------------------------------------------------------------
# Intake: an intent says its type and its focus (the story process, AC1)
# ---------------------------------------------------------------------------
# `create-intent` judges an intent with no `type:` or `focus:`, or whose focus is not an open one, by `intake.focus`: `required`
# refuses (RC_INTAKE, nothing created), `warn` (the default) prints one WARNING line and goes on, `off` reads nothing.
# Where the focus is read: (a) where a brain answers, `brain show <P> --json` of the vibemaestro-brain installed beside this sdlc
# copy (the registry baton.py reads for a dependent's kits, brain_script); (b) in a worker, where the brain keeps no memory, the `type:<t>` and
# `focus:<P>` labels the gate-1 session set on the issue the intent's `issue: N` names; (c) neither: refused, naming both.
INTAKE_FOCUS = "warn"
INTENT_TYPES = ("story", "task", "bug")
FOCUS_RX = re.compile(r"^P[1-9][0-9]*$")
CARD_LABEL_COLOR = "0e8a16"


def doc_front(doc_path):
    """{key: value} of the intent's frontmatter (kb_index.front_block), {} when it cannot be read."""
    import kb_index
    try:
        return kb_index.front_block(open(doc_path, encoding="utf-8").read().splitlines())[0]
    except OSError:
        return {}


def brain_script():
    """The brain.py of the vibemaestro-brain installed beside this sdlc copy, or None. As baton.py's installed_sdlc reads it: this
    copy is <plugins>/cache/<marketplace>/vibemaestro-sdlc/<version>, and <plugins>/installed_plugins.json (version 2) lists
    vibemaestro-brain@<marketplace> and this copy as vibemaestro-sdlc@<marketplace>; the brain's latest `lastUpdated` entry wins."""
    me = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
    market_dir = os.path.dirname(os.path.dirname(me))
    if os.path.basename(os.path.dirname(me)) != "vibemaestro-sdlc" or os.path.basename(os.path.dirname(market_dir)) != "cache":
        return None
    try:
        reg = json.load(open(os.path.join(os.path.dirname(os.path.dirname(market_dir)), "installed_plugins.json"), encoding="utf-8"))
        ids, market = (reg["plugins"] if reg.get("version") == 2 else {}), os.path.basename(market_dir)
        if not any(isinstance(x.get("installPath"), str) and os.path.isabs(x["installPath"]) and os.path.realpath(x["installPath"]) == me
                   for x in ids.get("vibemaestro-sdlc@%s" % market, [])):
            return None                          # a cache-shaped directory the registry does not list as this copy
        entries = ids["vibemaestro-brain@%s" % market]
        e = max((x for x in entries if isinstance(x.get("installPath"), str) and os.path.isabs(x["installPath"])),
                key=lambda x: str(x.get("lastUpdated") or ""))
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return None
    p = os.path.join(os.path.realpath(e["installPath"]), "scripts", "brain.py")
    return p if os.path.isfile(p) else None


def worker():
    """vsdlc.in_sandbox, read here so the core imports no hook library: VIBEMAESTRO_ROLE=worker, or INTENT_SLUG and SEAT both set."""
    return os.environ.get("VIBEMAESTRO_ROLE") == "worker" or bool(os.environ.get("INTENT_SLUG") and os.environ.get("SEAT"))


def focus_from_brain(brain, focus, root):
    """None when `focus` is a live focus of the brain of `root`, else why not."""
    try:
        r = subprocess.run([sys.executable, brain, "show", focus, "--json"], cwd=root, capture_output=True, text=True, timeout=60)
    except Exception as e:
        return "the brain did not answer: %s" % e
    try:
        it = json.loads(r.stdout) if r.returncode == 0 else None
    except ValueError:
        it = None
    if not isinstance(it, dict):
        return "%s is not an open focus of this brain (brain show: %s)" % (focus, (r.stderr or r.stdout).strip()[:200] or "rc %d" % r.returncode)
    if it.get("kind") != "focus" or it.get("status") != "live":
        return "%s is not an open focus of this brain (it is a %s item, %s)" % (focus, it.get("kind"), it.get("status"))
    return None


def labels_of_issue(number, cwd):
    """(set of label names, None) of issue #number, or (None, why)."""
    gh = shutil.which("gh")
    if not gh:
        return None, M("ib.no_gh")
    try:
        r = subprocess.run([gh, "issue", "view", str(number), "--json", "labels"], cwd=cwd, capture_output=True, text=True, timeout=60)
    except Exception as e:
        return None, str(e)
    try:
        return {l["name"] for l in json.loads(r.stdout)["labels"]}, None
    except (ValueError, KeyError, TypeError):
        return None, "gh issue view %d: rc %d %s" % (number, r.returncode, (r.stderr or r.stdout).strip()[:200])


def intake_refusal(doc, root, cwd):
    """None when the intent may be created, else the refusal naming what is missing (AC1)."""
    if INTAKE_FOCUS == "off":
        return None
    fm = doc_front(doc)
    t, f = fm.get("type", ""), fm.get("focus", "")
    missing = [] if t in INTENT_TYPES else ["`type:` (story, task or bug)"]
    if not FOCUS_RX.match(f):
        missing.append("`focus:` (an open focus of the brain, like P1)")
    if missing:
        return "%s has no %s in its frontmatter: kb.py new intent <slug> --type <t> --focus <P> writes both" % (
            os.path.relpath(doc, root), " and no ".join(missing))
    if worker():
        issue = front_issue(doc)
        want = ["type:%s" % t, "focus:%s" % f]
        if not issue.isdigit():
            return ("a worker reads the focus from the labels %s of the intent's issue, and %s has no `issue: N`: the gate-1 "
                    "session, where the brain answers, sets them" % (" and ".join(want), os.path.relpath(doc, root)))
        number = int(issue)
        have, why = labels_of_issue(number, cwd)
        if have is None:
            return "a worker reads the focus from the labels of issue #%d, and they cannot be read: %s" % (number, why)
        gone = [w for w in want if w not in have]
        if gone:
            return ("issue #%d has no label %s: the gate-1 session, where the brain answers, sets %s on it"
                    % (number, " and no ".join(gone), " and ".join(want)))
        return None
    brain = brain_script()
    if brain is None:
        return ("no way to read whether %s is an open focus: no brain answers here (vibemaestro-brain is not installed beside "
                "this sdlc copy) and this is not a worker reading the issue's type:/focus: labels; install the brain, run from a "
                "worker whose issue carries the labels, or set intake.focus to \"warn\" or \"off\" in %s" % (f, sdlc_config.CONFIG_REL))
    return focus_from_brain(brain, f, root)


REQUEST_RX = re.compile(r"^R[1-9][0-9]*$")


def link_request(doc, root, number, url):
    """A story whose frontmatter names the brain request it answers (`request: R<n>`) gets its new issue as that request's
    `closes` (`brain op link`), so the request closes itself once the story's issue is completed. Only where a brain answers
    and not in a worker (the coordinator links a worker's); one line either way, never a failure."""
    fm = doc_front(doc)
    req = str(fm.get("request") or "").strip()
    if fm.get("type") != "story" or not req or worker():
        return
    brain = brain_script()
    if brain is None:
        return
    if not REQUEST_RX.match(req):
        err("request: %s in %s is not a request id like R3: not linked to issue #%d" % (req, os.path.relpath(doc, root), number))
        return
    try:
        r = subprocess.run([sys.executable, brain, "op", "link", req, "--closes", url], cwd=root, capture_output=True,
                           text=True, timeout=60)
        rc, why = r.returncode, (r.stderr or r.stdout).strip()[:300]
    except Exception as e:
        rc, why = None, str(e)
    if rc == 0:
        err("request %s closes with issue #%d now (brain op link)" % (req, number))
    else:
        err("request %s not linked to issue #%d: %s; run brain op link %s --closes %s" % (req, number, why, req, url))


def report_issue_created(doc, root, number, url):
    """In lời khai TRUNG THỰC về việc tạo issue #N — chỉ nói "đã ghi" khi
    `set_doc_issue` thật sự ghi được. Trước bản vá này, chỗ gọi hàm không đọc
    giá trị trả về nên hồ sơ không-frontmatter vẫn báo "đã ghi" dù không có
    dòng `issue:` nào được thêm."""
    if set_doc_issue(doc, number):
        err("created tracking issue #%d, recorded in %s" % (number, os.path.relpath(doc, root)))
        link_request(doc, root, number, url)
    else:
        err("created issue #%d BUT could not record it in %s: the file does not start "
            "with `---` (no frontmatter). Add the line `issue: %d` at its top by hand."
            % (number, os.path.relpath(doc, root), number))


def cmd_retry_issue(a):
    """Đường thử lại khi lần `create-intent --issue` đầu không tạo được issue
    (quyền/mạng) — KHÔNG đi qua `create-intent`: branch `intent/<slug>` đã tồn
    tại thì `create-intent` từ chối ngay ở rc `RC_EXISTS` (6), trước khi kịp
    thử gọi `gh issue create`. Quyết định
    `kb/decisions/2026-10-01-gan-vong-doi-intent-voi-github-issues.md` từng ghi
    sai là "tạo lại khi `create-intent` chạy lần kế" — lệnh đó không bao giờ tới
    được bước tạo issue trên một intent đã có branch; đây là đường thật.

    Idempotent: hồ sơ đã có `issue:` thì KHÔNG tạo thêm (tránh N issue cho cùng
    một intent). Không đòi branch `intent/<slug>` phải tồn tại — chỉ cần hồ sơ
    `kb/intent/<slug>.md`, vì issue chỉ theo dõi hồ sơ, không theo dõi branch.
    """
    root = repo_root(a.cwd)
    if root is None:
        return RC_ENV
    intent = norm_intent(a.slug)
    if not intent:
        err(M("ib.no_slug"))
        return RC_USAGE
    doc = intent_doc_path(root, intent)
    if not os.path.isfile(doc):
        err(M("ib.retry_no_doc", os.path.relpath(doc, root)))
        return RC_INTENT_FILE
    if front_issue(doc).isdigit():
        err(M("ib.retry_has_issue", os.path.relpath(doc, root)))
        return 0
    number, issue_err, url = create_tracking_issue(doc, intent, root, a.cwd, a.infra)
    if number is None:
        err("could not create the tracking issue: %s" % issue_err)
        return 1
    report_issue_created(doc, root, number, url)
    return 0


def cmd_create_intent(a):
    root = repo_root(a.cwd)
    if root is None:
        return RC_ENV
    intent = norm_intent(a.slug)
    if not intent:
        err(M("ib.no_slug"))
        return RC_USAGE
    if "/" in slug_of(intent):
        err(M("ib.slug_slash", slug_of(intent)))
        return RC_USAGE

    doc = intent_doc_path(root, intent)
    if not os.path.isfile(doc):
        err(M("ib.no_doc", os.path.relpath(doc, root)))
        return RC_INTENT_FILE
    if os.path.getsize(doc) == 0:
        err(M("ib.empty_doc", os.path.relpath(doc, root)))
        return RC_INTENT_FILE

    why = intake_refusal(doc, root, a.cwd)
    if why and INTAKE_FOCUS == "required":
        err("refused, no branch or issue created: " + why)
        return RC_INTAKE
    if why:
        err("WARNING (intake.focus: warn): " + why)

    if ISSUE_CODE:
        rc, intent = keyed_intent(a, doc, root)
        if rc:
            return rc

    if ref_exists(intent, a.cwd) or ref_exists("origin/" + intent, a.cwd):
        err(M("ib.exists", intent))
        return RC_EXISTS

    if not ref_exists(a.base, a.cwd):
        err(M("ib.no_base", a.base))
        return RC_TARGET

    if a.no_checkout:
        rc, out = git("branch", intent, a.base, cwd=a.cwd)
    else:
        rc, out = git("checkout", "-b", intent, a.base, cwd=a.cwd)
    if rc != 0:
        err(M("ib.create_failed", intent, a.base, out))
        return RC_TARGET

    # Opt-in (`--issue`): core mặc định KHÔNG tạo issue, để lệnh gọi lõi trực
    # tiếp (test, dùng tay) không bất ngờ đụng mạng/gh. Adapter
    # (`scripts/intent-branch.sh`) tiêm cờ này mặc định cho `create-intent` —
    # quyết định "máy tạo issue" thuộc về adapter, không thuộc lõi.
    if ISSUE_CODE:
        pass                                     # keyed_intent handled the issue before the branch
    elif getattr(a, "issue", False) and worker() and front_issue(doc).isdigit():
        err("a worker's intent already names its issue (the one gate 1 labelled): no new issue is opened")
    elif getattr(a, "issue", False):
        number, issue_err, url = create_tracking_issue(doc, intent, root, a.cwd, a.infra)
        if number is None:
            err("could not create the tracking issue (best-effort, does NOT block the branch): %s\n"
                "       branch %s is created; add `issue: N` to %s by hand if needed.\n"
                "       NO TRACKING ISSUE WAS RECORDED. Check `gh issue list --label intent` first (a call that timed out "
                "may still have created one), then retry once the cause is fixed: "
                "intent-branch.sh retry-issue --slug %s"
                % (issue_err, intent, os.path.relpath(doc, root), slug_of(intent)))
        else:
            report_issue_created(doc, root, number, url)

    print(intent)
    return 0


# ---------------------------------------------------------------------------
# Chặn checkout ngay trong cây chính — dùng chung cho `worker-branch` và `integrate`
# ---------------------------------------------------------------------------
# Biến env quyết định git GHI vào repo/cây/index/object store nào. Phép dò
# worktree (`in_linked_worktree`) gỡ chúng để hỏi "`--cwd` là gì"; lệnh ghi thì
# vẫn nghe chúng. Env trỏ cây chính + `--cwd` là worktree liên kết thì phép dò
# thấy worktree còn checkout/rebase lại chạy trong cây chính. Từ chối thay vì
# gỡ: không đoán được người gọi muốn repo nào. KHÔNG gồm `GIT_CONFIG_*` —
# credential push có thể được truyền qua `GIT_CONFIG_COUNT`.
REPO_LOCATION_ENV = ("GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE",
                     "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES")


def _refuse_checkout_in_main_tree(a):
    """rc 7 nếu `worker-branch` sắp `checkout -b` trong cây chính, 0 nếu được.

    Một worker gọi KHÔNG có `--no-checkout` từ worktree liên kết của nó cần đứng
    trên branch mới ngay sau đó — đừng đổi mặc định. Phương án bị loại:
    kb/decisions/2026-10-03-worker-branch-tu-choi-checkout-cay-chinh.md.
    """
    env_set = [k for k in REPO_LOCATION_ENV if k in os.environ]
    if env_set:
        err(M("ib.wb_env", ", ".join(env_set), a.name))
        return RC_WRONG_TREE
    wt = in_linked_worktree(a.cwd)
    if wt is None:
        err(M("ib.no_gitdir", a.cwd))
        return RC_ENV
    if not wt:
        err(M("ib.wb_main_tree", a.name, a.intent, a.name, worktree_hint(a.cwd, LANG), a.name, worktree_why(LANG)))
        return RC_WRONG_TREE
    return 0


# ---------------------------------------------------------------------------
# (b) branch con LUÔN cắt từ tip của intent, không cắt từ main
# ---------------------------------------------------------------------------
def cmd_worker_branch(a):
    if repo_root(a.cwd) is None:
        return RC_ENV
    intent = norm_intent(a.intent)
    if not intent:
        err(M("ib.no_intent"))
        return RC_USAGE
    if not a.name:
        err(M("ib.no_name"))
        return RC_USAGE
    if a.name.startswith(PREFIX):
        err(M("ib.wb_prefix", PREFIX, a.name))
        return RC_USAGE

    tip = resolve_tip(intent, a.cwd, a.intent_ref)
    if tip is None:
        err(M("ib.wb_no_tip", intent))
        return RC_TARGET

    if ref_exists(a.name, a.cwd) or ref_exists("origin/" + a.name, a.cwd):
        err(M("ib.exists", a.name))
        return RC_EXISTS

    # (f) checkout chỉ được chạy trong worktree LIÊN KẾT — cùng phép chặn với
    # `integrate` (e), cùng rc 7. Đặt SAU các phép đọc (rc 5/6/64 giữ nghĩa cũ
    # dù gọi từ đâu), TRƯỚC lệnh ghi đầu tiên: bị từ chối thì không có branch
    # nào được tạo. `--no-checkout` chỉ tạo ref, không đụng HEAD/cây/index, nên
    # không cần chặn — đó chính là đường cây chính được phép đi.
    if not a.no_checkout:
        rc = _refuse_checkout_in_main_tree(a)
        if rc:
            return rc
        rc, out = git("checkout", "-b", a.name, tip, cwd=a.cwd)
    else:
        rc, out = git("branch", a.name, tip, cwd=a.cwd)
    if rc != 0:
        err(M("ib.create_failed", a.name, tip, out))
        return RC_TARGET
    print(a.name)
    return 0


# ---------------------------------------------------------------------------
# (c)(d) góp ngược — rebase là CƠ HỌC, merge thường không tồn tại ở đây
# ---------------------------------------------------------------------------


def cmd_integrate(a):
    env_set = [k for k in REPO_LOCATION_ENV if k in os.environ]
    if env_set:
        err(M("ib.int_env", ", ".join(env_set)))
        return RC_WRONG_TREE
    if repo_root(a.cwd) is None:
        return RC_ENV
    intent = norm_intent(a.intent)
    if not intent:
        err(M("ib.no_intent"))
        return RC_USAGE

    # (e) TRƯỚC mọi lệnh ghi: rebase checkout nhánh nguồn ngay trong cwd.
    wt = in_linked_worktree(a.cwd)
    if wt is None:
        err(M("ib.no_gitdir", a.cwd))
        return RC_ENV
    if not wt:
        err(M("ib.int_main_tree", worktree_hint(a.cwd, LANG), intent, worktree_why(LANG)))
        return RC_WRONG_TREE

    branch = a.branch
    if not branch:
        rc, branch = git("rev-parse", "--abbrev-ref", "HEAD", cwd=a.cwd)
        if rc != 0 or branch in ("", "HEAD"):
            err(M("ib.no_head"))
            return RC_USAGE
    if branch == intent:
        err(M("ib.int_self", intent))
        return RC_USAGE
    if is_protected(branch, a.cwd):
        err(M("ib.int_protected", branch, intent, branch))
        return RC_WRONG_TREE
    if not ref_exists(branch, a.cwd):
        err(M("ib.no_branch", branch))
        return RC_TARGET

    if not a.no_fetch:
        # Tip của intent nhích trong lúc worker làm việc là ca THƯỜNG, không
        # phải ngoại lệ — đó chính là lý do khối rebase dưới đây tồn tại.
        git("fetch", "origin", cwd=a.cwd)

    tip = resolve_tip(intent, a.cwd, a.intent_ref)
    if tip is None:
        err(M("ib.int_no_tip", intent))
        return RC_TARGET

    rc, _ = git("merge-base", "--is-ancestor", tip, branch, cwd=a.cwd)
    if rc != 0:
        # Branch CŨ HƠN tip intent. Đây là chỗ người tích hợp hay gõ `git merge`
        # thường và sinh merge commit im lặng.
        if a.no_rebase:
            err(M("ib.int_not_descendant", branch, tip))
            return RC_BLOCK
        ident = git_identity(a.cwd)
        if ident is None:
            err("%s is older than %s and needs a rebase, but there is %s. Nothing was changed." % (branch, tip, IDENTITY_HINT))
            return RC_ENV
        err(M("ib.int_rebasing", branch, tip))
        rc, out = git(*(ident[0] + ["rebase", tip, branch]), cwd=a.cwd, env=ident[1])
        if rc != 0:
            git("rebase", "--abort", cwd=a.cwd)
            err(M("ib.int_rebase_failed", branch, tip, out))
            return RC_BLOCK
        rc, _ = git("merge-base", "--is-ancestor", tip, branch, cwd=a.cwd)
        if rc != 0:
            err(M("ib.int_still_behind", branch, tip))
            return RC_BLOCK

    if a.to == "origin":
        # `git push` vốn từ chối non-fast-forward; không có `--force` ở đây nên
        # không đường nào đẻ ra merge commit hay viết đè việc của worker khác.
        rc, out = git("push", "origin",
                      "%s:refs/heads/%s" % (branch, intent), cwd=a.cwd)
        if rc != 0:
            err(M("ib.int_push", branch, intent, out))
            return RC_BLOCK
        print("%s → origin/%s" % (branch, intent))
        return 0

    held = branch_held_elsewhere(intent, a.cwd)
    if held:
        err(M("ib.int_held", intent, held))
        return RC_TARGET
    if not ref_exists(intent, a.cwd):
        rc, out = git("branch", intent, tip, cwd=a.cwd)
        if rc != 0:
            err(M("ib.int_local_copy", intent, out))
            return RC_TARGET
    rc, out = git("checkout", intent, cwd=a.cwd)
    if rc != 0:
        err(M("ib.int_checkout", intent, out))
        return RC_TARGET
    # `--ff-only` là phép chặn cuối. KHÔNG có nhánh nào ở file này gọi `git
    # merge` thiếu cờ đó.
    rc, out = git("merge", "--ff-only", branch, cwd=a.cwd)
    if rc != 0:
        err(M("ib.int_ff", branch, intent, out))
        return RC_BLOCK
    print("%s → %s" % (branch, intent))
    return 0


class _PreParser(argparse.ArgumentParser):
    """A parser that raises instead of exiting: `main` reads `--cwd` with it before the real parser exists."""
    def error(self, message):
        raise ValueError(message)


def main(argv):
    global LANG
    # the language is read before the parser is built, so that `--help` speaks it too: the repo is the one `--cwd` names, read
    # by a parser that knows only `--cwd` (any spelling argparse accepts: `--cwd=DIR`, an abbreviation)
    pre = _PreParser(add_help=False)
    pre.add_argument("--cwd", default=".")
    try:
        cwd = pre.parse_known_args(argv)[0].cwd
    except ValueError:                   # `--cwd` with no value: the real parser below reports it (or prints --help)
        cwd = "."
    LANG = messages.language_at(cwd)
    # the English usage is laid out by hand; the `vi` one has always been reflowed by argparse, and keeps that
    p = argparse.ArgumentParser(add_help=True, description=M("ib.usage"),
                                formatter_class=argparse.RawDescriptionHelpFormatter if LANG == "en" else argparse.HelpFormatter)
    p.add_argument("--cwd", default=".")
    sub = p.add_subparsers(dest="cmd")

    c = sub.add_parser("create-intent")
    c.add_argument("--slug", required=True)
    c.add_argument("--base", default="origin/main")
    c.add_argument("--no-checkout", action="store_true")
    c.add_argument("--issue", action="store_true",
                    help=M("ib.help_issue"))
    c.set_defaults(fn=cmd_create_intent)

    w = sub.add_parser("worker-branch")
    w.add_argument("--intent", required=True)
    w.add_argument("--name", required=True)
    w.add_argument("--intent-ref", default=None)
    w.add_argument("--no-checkout", action="store_true")
    w.set_defaults(fn=cmd_worker_branch)

    i = sub.add_parser("integrate")
    i.add_argument("--intent", required=True)
    i.add_argument("--branch", default=None)
    i.add_argument("--intent-ref", default=None)
    i.add_argument("--to", choices=("local", "origin"), required=True)
    i.add_argument("--no-fetch", action="store_true")
    i.add_argument("--no-rebase", action="store_true")
    i.set_defaults(fn=cmd_integrate)

    r = sub.add_parser("retry-issue")
    r.add_argument("--slug", required=True)
    r.set_defaults(fn=cmd_retry_issue)
    for x in (c, r):                     # the issue asks for infrastructure help (`infra.label`): both or neither
        x.add_argument("--infra-blocked", default=None, help=M("ib.help_infra_blocked"))
        x.add_argument("--infra-tried", default=None, help=M("ib.help_infra_tried"))

    a = p.parse_args(argv)
    if not getattr(a, "cmd", None):
        p.print_usage(sys.stderr)
        return RC_USAGE
    a.infra = None
    if getattr(a, "infra_blocked", None) is not None or getattr(a, "infra_tried", None) is not None:
        try:
            a.infra = sdlc_config.infra_line(a.infra_blocked or "", a.infra_tried or "")
        except ValueError as e:
            err("refused, nothing created: %s (give --infra-blocked and --infra-tried both)" % e)
            return RC_USAGE
    rc = apply_config(a.cwd)
    if rc:
        return rc
    return a.fn(a)


if __name__ == "__main__":
    for _s in filter(None, (sys.stdout, sys.stderr)):   # Windows writes a pipe in the system code page, which lacks Vietnamese and the arrows
        _s.reconfigure(encoding="utf-8", errors="backslashreplace")
    sys.exit(main(sys.argv[1:]))
