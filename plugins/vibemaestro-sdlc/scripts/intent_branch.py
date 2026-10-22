#!/usr/bin/env python3
"""Lifecycle of the `intent/*` branch: the ONE path that creates, splits and integrates the branches of an intent.

The usage `--help` prints (the model, the decisions (a) to (g) this core enforces, why, the subcommands and the exit codes) is
`ib.usage` of messages.py, in the repo's `language`; every message this core prints is a key `ib.*` there.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys

# `open_pr.py` luôn nằm cạnh file này (skill cài theo cả thư mục), nên phép dò
# worktree chỉ có MỘT bản — kể cả phần gỡ GIT_DIR/GIT_WORK_TREE khỏi env.
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from open_pr import in_linked_worktree, worktree_hint, worktree_why  # noqa: E402
import messages  # noqa: E402
import sdlc_config  # noqa: E402

RC_ENV, RC_INTENT_FILE, RC_BLOCK, RC_TARGET, RC_EXISTS, RC_USAGE = 2, 3, 4, 5, 6, 64
RC_WRONG_TREE = 7

# Defaults of `branch.protected` and `branch.intent_prefix`; `main()` replaces them from `.vibemaestro/sdlc.json` of the repo.
PROTECTED = ("main", "master")

PREFIX = "intent/"

LANG = "vi"     # the language of the messages (messages.py): `main` sets it from the repo at `--cwd`


def M(key, *args):
    """A message of messages.py in the repo's language."""
    return messages.text(key, LANG, *args)


def apply_config(cwd):
    """Load the repo's config into PREFIX and PROTECTED. rc 0, or RC_USAGE (64) naming the key of an invalid config.
    A directory that is not a git repo keeps the defaults: the command reports that itself."""
    global PREFIX, PROTECTED, REBASE_IDENTITY
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
def intent_doc_path(root, intent_branch):
    return os.path.join(root, "kb", "intent", slug_of(intent_branch) + ".md")


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
ISSUE_URL_RX = re.compile(r"/issues/(\d+)\s*$")
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
    text = open(doc_path, encoding="utf-8").read()
    line = "issue: %d" % number
    if FRONTMATTER_ISSUE_RX.search(text):
        new = FRONTMATTER_ISSUE_RX.sub(line, text, count=1)
    elif re.match(r"^---[ \t]*\r?\n", text):
        new = re.sub(r"^---[ \t]*\r?\n", "---\n%s\n" % line, text, count=1)
    else:
        return False
    with open(doc_path, "w", encoding="utf-8") as f:
        f.write(new)
    return True


def create_tracking_issue(doc_path, intent_branch, root, cwd):
    """(số_issue, lỗi). `lỗi` là None khi thành công — không bao giờ raise."""
    gh = shutil.which("gh")
    if not gh:
        return None, M("ib.no_gh")
    slug = slug_of(intent_branch)
    rel = os.path.relpath(doc_path, root)
    desc = doc_description(doc_path) or slug
    body = M("ib.issue_body", desc, rel)
    try:
        subprocess.run(
            [gh, "label", "create", ISSUE_LABEL, "--description", ISSUE_LABEL_DESC,
             "--color", ISSUE_LABEL_COLOR],
            cwd=cwd, capture_output=True, text=True, timeout=60)
    except Exception:
        pass                                     # the issue call below reports what is really wrong
    try:
        r = subprocess.run(
            [gh, "issue", "create", "--title", "intent: %s" % slug,
             "--body", body, "--label", ISSUE_LABEL],
            cwd=cwd, capture_output=True, text=True, timeout=60)
    except Exception as e:
        return None, str(e)
    if r.returncode != 0:
        return None, (r.stdout + r.stderr).strip()[:400]
    m = ISSUE_URL_RX.search(r.stdout.strip())
    if not m:
        return None, M("ib.issue_number", r.stdout.strip()[:200])
    return int(m.group(1)), None


def report_issue_created(doc, root, number):
    """In lời khai TRUNG THỰC về việc tạo issue #N — chỉ nói "đã ghi" khi
    `set_doc_issue` thật sự ghi được. Trước bản vá này, chỗ gọi hàm không đọc
    giá trị trả về nên hồ sơ không-frontmatter vẫn báo "đã ghi" dù không có
    dòng `issue:` nào được thêm."""
    if set_doc_issue(doc, number):
        err("created tracking issue #%d, recorded in %s" % (number, os.path.relpath(doc, root)))
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
    if FRONTMATTER_ISSUE_RX.search(open(doc, encoding="utf-8").read()):
        err(M("ib.retry_has_issue", os.path.relpath(doc, root)))
        return 0
    number, issue_err = create_tracking_issue(doc, intent, root, a.cwd)
    if number is None:
        err("could not create the tracking issue: %s" % issue_err)
        return 1
    report_issue_created(doc, root, number)
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
    if getattr(a, "issue", False):
        number, issue_err = create_tracking_issue(doc, intent, root, a.cwd)
        if number is None:
            err("could not create the tracking issue (best-effort, does NOT block the branch): %s\n"
                "       branch %s is created; add `issue: N` to %s by hand if needed.\n"
                "       NO TRACKING ISSUE WAS RECORDED. Check `gh issue list --label intent` first (a call that timed out "
                "may still have created one), then retry once the cause is fixed: "
                "intent-branch.sh retry-issue --slug %s"
                % (issue_err, intent, os.path.relpath(doc, root), slug_of(intent)))
        else:
            report_issue_created(doc, root, number)

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

    a = p.parse_args(argv)
    if not getattr(a, "cmd", None):
        p.print_usage(sys.stderr)
        return RC_USAGE
    rc = apply_config(a.cwd)
    if rc:
        return rc
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
