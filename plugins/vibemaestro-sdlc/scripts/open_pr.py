#!/usr/bin/env python3
"""Open a PR: the ONE path that opens a PR for a repo that uses the plugin, through `gh pr create`.

Why a runnable file and not an instruction: a bare `gh pr create` has no conditions, while this path refuses 6 cases (empty
title, empty summary, empty or missing evidence, no head that can be determined, a protected head, a body that cannot be
built). Two ways to open a PR are two standards of "enough to open a PR".

The DECISIONS live here: the shape of the PR body and the refusals. The adapter (`open-pr.sh`) only finds the core, reads the
slug from `gh` and passes the arguments.

Ba phép từ chối mà chỉ đường này có:

    (a) bằng chứng chạy rỗng/thiếu             → rc 3
    (b) cổng sổ hiện trạng đỏ, thân PR không có
        dòng `KHÔNG ĐỔI HIỆN TRẠNG: <lý do>`   → rc 4
    (c) đang đứng ở CÂY CHÍNH, không phải worktree → rc 5

(b) chạy cổng của `current_state_gate` theo `current_state.gate` của config: `builtin` gọi `current_state.decide` (profile của
repo; `watch: []` mặc định nên cổng không áp dụng), `off` bỏ qua, `external:<path>` gọi `decide(paths, body)` của script đó trong
repo đang làm việc — nguồn sự thật là script ấy, ở đây không có bản thứ hai. Repo KHÔNG có file config mà có
`scripts/check-current-state.py` thì script đó vẫn được gọi như trước.

Dùng:
    open_pr.py --title T --summary-file F --evidence-file F
               [--head BR] [--base main] [--crit-file F] [--fixes "98 96"]
               [--closes "123"] [--repo OWNER/NAME] [--payload-out P]
               [--draft] [--dry-run]

`--draft` mở PR ở trạng thái draft — PR của một intent (xem docstring `intent_branch.py`: một intent = một branch = một PR
draft). Chỉ thêm khoá `draft` vào payload khi cờ có mặt, nên payload của PR thường không đổi.

Transport: ONE, `gh pr create` (the user's logged-in `gh`). `--repo OWNER/NAME` names the target repository (the adapter
passes the slug it reads from `gh`); left out, `gh` chooses by the working directory. The environment NEVER selects another
network path: a token file or a token variable changes nothing (a sandbox session exports them). `--gh` is still accepted and
ignored for one minor version after this one, so an old adapter does not die with rc 64.

rc: 0 done · 64 bad arguments (also a title that violates `pr.title`, an invalid config) · 66 unreadable file · 67 no `gh` on the
    machine · 1 `gh` refused · 2 body cannot be built (an empty summary, or a body over `pr.body.*`: see `gates/pr_body.py`) · 3 evidence missing · 4 current-state gate · 5 not in a worktree
65 is RETIRED (it was "transport not declared") and reserved: never reused for config errors (those are 64 in a core; 65 is
only for `kb.py` and the gates).
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
sys.path.insert(1, os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "gates"))
import current_state  # noqa: E402
import kb_index  # noqa: E402
import kb_plan  # noqa: E402
import messages  # noqa: E402
import pr_body  # noqa: E402
import sdlc_config  # noqa: E402

MAX_EV_LINES = 80          # body PR của GitHub trần 65536 ký tự
KEEP_HEAD, KEEP_TAIL = 10, 70


def err(msg):
    print("open_pr: " + msg, file=sys.stderr)


LANG = "vi"     # the language of the messages: `main` sets it from the work tree it runs in


def M(key, *args):
    """A message of messages.py in the repo's language."""
    return messages.text(key, LANG, *args)


def git(*args, cwd=None, env=None):
    """(rc, stdout đã strip). Không ném — caller quyết định im hay nổ."""
    try:
        r = subprocess.run(["git"] + list(args), cwd=cwd, env=env,
                           capture_output=True, text=True, timeout=60)
    except Exception as e:                        # git không có, treo…
        return 1, str(e)
    return r.returncode, r.stdout.strip()


# ---------------------------------------------------------------------------
# (c) cô lập worktree
# ---------------------------------------------------------------------------
# A gate written in an instruction (`[ "$(pwd)" = "$W" ] || FATAL`) is only words; the real
# block has to sit in code that every way of opening a PR goes through, which is here.
#
# Phép phân biệt là git-dir vs git-common-dir: trong worktree liên kết, `.git`
# là FILE trỏ về `<cây-chính>/.git/worktrees/<tên>`, nên hai đường dẫn khác
# nhau. Ở cây chính chúng trùng. So `$(pwd)` với một biến thì yếu hơn, vì biến
# đó do chính agent đặt — nhưng phép này cũng KHÔNG tuyệt đối:
#
#   * `rev-parse` tôn trọng `GIT_DIR`/`GIT_WORK_TREE` trong env, nên đặt
#     `GIT_DIR=<repo>/.git/worktrees/<wt>` rồi đứng ở cây chính là lọt, và
#     `GIT_DIR=<repo>/.git` khi đang ở worktree thật là bị từ chối nhầm.
#     Đo 26/09, cả hai chiều. Vì thế ta dò với env đã GỠ ba biến đó: phép kiểm
#     phải hỏi "thư mục này là gì", không phải "env đang trỏ đâu".
#   * trong một SUBMODULE, git-dir cũng trùng git-common-dir. Không repo nào
#     của dây chuyền là submodule nên hành vi giữ nguyên, nhưng thông điệp lỗi
#     phải nói đúng cả hai ca thay vì khẳng định chắc "đang ở cây chính".
#
# ⚠ `--path-format=absolute` đòi git >= 2.31. Đo 26/09: máy trạm 2.50.1 và một image
# runner 2.47.3 (đọc bằng `git --version`). Cả hai qua ngưỡng.
_GIT_ENV_STRIP = ("GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE")


def _clean_git_env():
    e = dict(os.environ)
    for k in _GIT_ENV_STRIP:
        e.pop(k, None)
    return e


def in_linked_worktree(cwd):
    env = _clean_git_env()
    rc1, gd = git("rev-parse", "--absolute-git-dir", cwd=cwd, env=env)
    rc2, gc = git("rev-parse", "--path-format=absolute", "--git-common-dir",
                  cwd=cwd, env=env)
    if rc1 or rc2 or not gd or not gc:
        return None                               # không phải repo git
    return os.path.realpath(gd) != os.path.realpath(gc)


# Lời nhắc chỗ đặt worktree khi bị từ chối vì đứng ở CÂY CHÍNH — MỘT khuôn cho
# mọi nơi in nó (`open_pr` rc 5, `intent_branch` worker-branch/integrate rc 7;
# `intent_branch` import từ đây, như `in_linked_worktree`).
def worktree_hint(cwd, lang="vi"):
    """Đường dẫn gợi ý cho `git worktree add`: `<clone>/.claude/worktrees/<tên>`.

    Chỉ là LỜI NHẮC trong thông điệp lỗi, lõi không tự tạo worktree (quyết định
    kb/decisions/2026-10-03-worker-branch-tu-choi-checkout-cay-chinh.md). Đặt
    TRONG clone vì công cụ Read/Write/Edit chỉ tự cho phép trong thư mục làm việc
    cố định lúc khởi động phiên; ngoài nó là hộp thoại xin quyền (đo 08/10).
    """
    rc, out = git("rev-parse", "--show-toplevel", cwd=cwd, env=_clean_git_env())
    return messages.text("op.worktree_path", lang, out) if rc == 0 and out else messages.text("op.worktree_clone", lang)


def worktree_why(lang="vi"):
    """The line after `worktree_hint` that says why the worktree goes inside the clone."""
    return messages.text("op.worktree_why", lang)


# ---------------------------------------------------------------------------
# Thân PR — khuôn 4 mục, dựng ở ĐÚNG MỘT chỗ
# ---------------------------------------------------------------------------
def plan_row_line(root, head, slug=""):
    """The one `Plan row:` line for the PR of `intent/<stem>` when `kb/intent/<stem>.md` has `plan: <file>#<row>`, else "". It is
    for people: `kb.py plan status` finds the PR by its branch, never by this line."""
    if not head.startswith("intent/"):
        return ""
    try:
        with open(os.path.join(root, "kb", "intent", head[len("intent/"):] + ".md"), encoding="utf-8") as f:
            fm = kb_index.front_block(f.read().split("\n"))[0]
    except (OSError, UnicodeDecodeError):
        return ""
    ref = kb_plan.parse_plan_ref(fm.get("plan"))
    if not ref:
        return ""
    if slug:
        return "Plan row: [%s of %s](https://%s/%s/blob/%s/%s)" % (ref[1], ref[0], os.environ.get("GH_HOST") or "github.com", slug, head, ref[0])
    return "Plan row: `%s` of `%s`" % (ref[1], ref[0])


def build_body(summary, evidence, crit="", fixes="", root="", closes="", cfg=None, plan=""):
    """Thuần: không đụng git, không đọc env. Test offline được. `cfg` là config hiệu lực (mặc định = hành vi cũ)."""
    cfg = cfg or sdlc_config.defaults()
    tk = cfg["tokens"]
    ev = evidence.rstrip()
    lines = ev.splitlines()
    if len(lines) > MAX_EV_LINES:
        ev = "\n".join(lines[:KEEP_HEAD]
                       + [tk["evidence_cut"].replace("{n}", str(len(lines) - MAX_EV_LINES))]
                       + lines[-KEEP_TAIL:])
    exempt = ev.lstrip().startswith(tk["not_run"])
    head_note = tk["not_run_note"] + "\n\n" if exempt else ""
    fence = evidence_fence(ev)

    # Hàm TỰ thêm `## Tóm tắt`, nên cắt tiêu đề đó nếu file tóm tắt đã có sẵn.
    # Đo trên một PR thật: body hiện `## Tóm tắt` HAI lần vì
    # agent viết tiêu đề vào file. Chỉ dẫn "đừng viết tiêu đề" là lời nhờ; cắt ở
    # đây là việc chắc chắn xảy ra. Cắt cả biến thể `###` và khoảng trắng thừa.
    # `(\r?\n+|\Z)`: file CHỈ có dòng tiêu đề thì sau .strip() không còn newline,
    # regex đòi newline sẽ không khớp và tiêu đề lọt vào body thành hai lần.
    summ = re.sub(r"\A#{1,6}[ \t]*" + re.escape(tk["summary_heading"]) + r"[ \t]*(\r?\n+|\Z)", "", summary.strip()).strip()
    if not summ:
        raise ValueError(messages.text("op.summary_heading_only", cfg["language"]))

    # Checklist tiêu chí: mỗi dòng thành `- [ ]`, GIỮ nguyên văn. Bỏ dấu đầu dòng
    # cũ (`-`, `*`, `1.`) và mọi `[x]`/`[ ]` agent đã tự đặt.
    crit_block = ""
    items = []
    for ln in (crit or "").strip().splitlines():
        t = re.sub(r"^\s*(?:[-*]|\d+\.)\s*(?:\[[ xX]\]\s*)?", "", ln).strip()
        if t:
            items.append("- [ ] " + t)
    if items:
        crit_block = ("## %s\n\n%s\n\n"
                      "%s\n\n" % (tk["criteria_heading"], "\n".join(items), tk["criteria_note"].replace("{evidence}", tk["evidence_heading"])))

    # `Vá cho #NN` phải ở ĐẦU body và đúng chữ — máy đếm bằng `--json number,body`
    # + `contains("Vá cho #")` (git-workflow điều 6). Chấp nhận số trần, số có `#` và danh
    # sách cách nhau bằng dấu phẩy: khuôn đầu vào của agent không ổn định, khuôn đầu ra thì phải.
    fix_nums, seen = [], set()
    for n in re.findall(r"\d+", fixes or ""):
        if n not in seen:
            seen.add(n)
            fix_nums.append(n)
    fix_block = "".join("%s #%s\n" % (tk["fixes_line"], n) for n in fix_nums)
    if fix_block:
        fix_block += "\n"

    # `Closes #N` — GitHub tự đóng issue theo dõi intent khi PR này merge. Cùng
    # vị trí (đầu body) và cùng cách đọc số (`\d+`) với `Vá cho #NN`, nhưng là
    # MỘT dòng khác chủ: issue theo dõi, không phải PR bị vá. Quyết định:
    # kb/decisions/2026-10-01-gan-vong-doi-intent-voi-github-issues.md.
    close_nums, seen_c = [], set()
    for n in re.findall(r"\d+", closes or ""):
        if n not in seen_c:
            seen_c.add(n)
            close_nums.append(n)
    close_block = "".join("%s #%s\n" % (cfg["pr"]["closing"]["keyword"], n) for n in close_nums)
    if close_block:
        close_block += "\n"
    if plan:                                 # the plan row of the intent (plan_row_line): one line, above the summary
        close_block += plan + "\n\n"

    # No flow checklist: its ticks were claims nothing checked. The pr-evidence gate checks the review and E2E evidence pinned to
    # the head instead (`pr.flow` and `pr.tester_exempt` are deprecated: sdlc_config.DEPRECATED).
    return ("%s%s## %s\n\n%s\n\n%s## %s\n\n%s%s\n%s\n%s\n"
            % (fix_block, close_block, tk["summary_heading"], summ, crit_block, tk["evidence_heading"], head_note, fence, ev, fence))


def evidence_fence(text):
    """The backtick fence around the evidence: one longer than the longest run of backticks in it, and at least three. A fence
    closes only on a run at least as long as the one that opened it, so fences inside the evidence stay plain text."""
    return "`" * max(3, max((len(r) for r in re.findall(r"`+", text)), default=0) + 1)


# ---------------------------------------------------------------------------
# (b) cổng sổ hiện trạng — `current_state.run_gate`, không viết bản thứ hai
# ---------------------------------------------------------------------------
# `decide(paths, body) -> (rc, msg)` là hàm thuần, builtin (current_state.py) hay script của repo (`external`).
# Viết lại logic ở đây là dựng bản thứ hai để trôi khỏi CI — chính thứ file này sinh ra để tránh.
LEGACY_GATE_SCRIPT = "scripts/check-current-state.py"


def current_state_gate(top, base_ref, head_ref, body, cfg=None, present=True):
    """(rc, msg). rc 0 = qua (kể cả khi cổng không áp dụng). `present`: có file config; không có file mà repo có
    `scripts/check-current-state.py` thì chạy script đó (hành vi trước khi có profile)."""
    cfg = cfg or sdlc_config.defaults()
    profile = current_state.profile_from_config(cfg)
    if not present and os.path.isfile(os.path.join(top, *LEGACY_GATE_SCRIPT.split("/"))):
        profile["gate"] = "external:" + LEGACY_GATE_SCRIPT
    if profile["gate"] == "off":
        return 0, "current_state.gate is off: the gate does not apply"
    if profile["gate"] == "builtin" and not profile["watch"]:
        if present and os.path.isfile(os.path.join(top, *LEGACY_GATE_SCRIPT.split("/"))):
            err("WARNING: the repo has %s but the config picks the builtin gate and watches no path, so that script does NOT run. To "
                "keep it: set current_state.gate to external:%s." % (LEGACY_GATE_SCRIPT, LEGACY_GATE_SCRIPT))
        return 0, "the profile watches no path (current_state.watch is empty): the gate does not apply"

    # Dải so là `base...head`, đúng lệnh ghi trong docstring của cổng. Base có
    # thể là tên nhánh local chưa tồn tại (worker vừa cắt từ origin), nên thử
    # `origin/<base>` trước.
    rng = None
    for cand in ("origin/" + base_ref, base_ref):
        rc, _ = git("rev-parse", "--verify", "--quiet", cand + "^{commit}", cwd=top)
        if rc == 0:
            rng = cand
            break
    if rng is None:
        return 1, ("cannot resolve base `%s` to diff against: the current-state gate "
                   "CANNOT conclude. Fetch the base, then run again." % base_ref)

    rc, out = git("-c", "core.quotePath=false", "diff", "--name-only", "--no-renames",
                  "%s...%s" % (rng, head_ref), cwd=top)
    if rc != 0:
        return 1, "`git diff %s...%s` failed: the current-state gate cannot conclude" % (rng, head_ref)
    return current_state.run_gate(profile, [l.strip() for l in out.split("\n") if l.strip()], body, top)


# ---------------------------------------------------------------------------
# GitHub fills `closingIssuesReferences` a moment AFTER the PR exists: three PRs opened by this path read `[]` ~1 s after
# creation and `[N]` ~3 s after (one coarser sample: populated within 11 s), so a read right after `gh pr create` looks like
# "not linked" when it is only early. Poll briefly, then say so loudly instead of leaving a silent gap. Never changes the
# exit code: the PR exists, and a failed read must not make a caller retry and open a duplicate. The poll is bounded by a
# total deadline so a hanging `gh` cannot outlast a caller's own timeout.
LINK_TRIES = 10
LINK_WAIT_S = 2.0                                  # env OPEN_PR_LINK_WAIT_S overrides (tests set 0)
LINK_DEADLINE_S = 30.0                             # whole poll, including the reads; env OPEN_PR_LINK_DEADLINE_S overrides
LINK_READ_TIMEOUT_S = 15.0


def _plain_env():
    """`gh -q` prints ANSI-coloured, multi-line JSON when colour is forced; ask for plain output."""
    env = dict(os.environ)
    for k in ("CLICOLOR_FORCE", "GH_FORCE_TTY"):
        env.pop(k, None)
    env["NO_COLOR"] = "1"
    return env


def closing_numbers(gh, pr, slug, timeout):
    """Issue numbers GitHub reports as closed by the PR, or None when the read failed."""
    cmd = [gh, "pr", "view", str(pr), "--json", "closingIssuesReferences",
           "-q", "[.closingIssuesReferences[].number]"]
    if slug:
        cmd += ["--repo", slug]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=_plain_env())
        if r.returncode != 0:
            return None
        nums = json.loads(r.stdout)
        return [int(n) for n in nums]
    except Exception:
        return None


def verify_closing_link(gh, pr, slug, closes, closing=None):
    """Print whether GitHub linked the PR to each issue in `closes` (list of digit strings). Always returns None."""
    want = [int(n) for n in closes]
    closing = closing or {}
    tries = int(closing.get("tries", LINK_TRIES))
    # `pr.closing` gives the values; the OPEN_PR_LINK_* variables stay as overrides (the tests set them)
    dflt_wait, dflt_budget = float(closing.get("wait_s", LINK_WAIT_S)), float(closing.get("deadline_s", LINK_DEADLINE_S))
    try:
        wait = float(os.environ.get("OPEN_PR_LINK_WAIT_S", dflt_wait))
    except ValueError:
        wait = dflt_wait
    try:
        budget = float(os.environ.get("OPEN_PR_LINK_DEADLINE_S", dflt_budget))
    except ValueError:
        budget = dflt_budget
    got, reads = None, 0
    deadline = time.monotonic() + budget
    for i in range(tries):
        left = deadline - time.monotonic()
        if left <= 0:
            break
        got = closing_numbers(gh, pr, slug, min(LINK_READ_TIMEOUT_S, left))
        reads += 1
        if got is not None and all(n in got for n in want):
            print("closing link confirmed: PR #%s closes %s" % (pr, ", ".join("#%d" % n for n in want)),
                  file=sys.stderr)
            return
        if i < tries - 1:
            time.sleep(wait)
    missing = want if got is None else [n for n in want if n not in got]
    why = "could not read closingIssuesReferences" if got is None else "GitHub lists %s" % (
        ", ".join("#%d" % n for n in got) or "no closing issue")
    print("WARNING: could not confirm that PR #%s closes %s (%s after %d reads). The PR exists; merging may not "
          "close the issue. Open the PR page as a user and check the linked-issue sidebar; only if it is empty, edit "
          "the PR body so `Closes #N` is on its own line." % (
              pr, ", ".join("#%d" % n for n in missing), why, reads), file=sys.stderr)


def create_pr(payload, slug, closes=None, closing=None):
    """rc 0 and the PR number on stdout, rc 1 when `gh` refuses, rc 67 when the machine has no `gh`."""
    gh = shutil.which("gh")
    if not gh:
        err("no `gh` on this machine")
        return 67
    cmd = [gh, "pr", "create", "--title", payload["title"],
           "--base", payload["base"], "--head", payload["head"],
           "--body-file", "-"]
    if payload.get("draft"):
        cmd.append("--draft")
    if slug:
        cmd += ["--repo", slug]
    try:
        r = subprocess.run(cmd, input=payload["body"],
                           capture_output=True, text=True, timeout=120)
    except Exception as e:
        print(M("op.gh_error", e), file=sys.stderr)
        return 1
    if r.returncode != 0:
        print("gh pr create rc=%s: %s" % (r.returncode, r.stderr[:400]), file=sys.stderr)
        return 1
    # `gh` in URL của PR; số PR là phần cuối.
    m = re.search(r"/pull/(\d+)", r.stdout)
    print(m.group(1) if m else r.stdout.strip())
    if m and closes and (closing or {}).get("verify", True):
        verify_closing_link(gh, m.group(1), slug, closes, closing)
    return 0


def read_file(path, what):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError as e:
        err(M("op.cannot_read", what, e))
        return None


def main(argv):
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--title", required=True)
    ap.add_argument("--summary-file", required=True)
    ap.add_argument("--evidence-file", required=True)
    ap.add_argument("--head", default="")
    ap.add_argument("--base", default="main")
    ap.add_argument("--crit-file", default="")
    ap.add_argument("--fixes", default="")
    ap.add_argument("--closes", default="")
    ap.add_argument("--payload-out", default="")
    ap.add_argument("--draft", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--repo", default="")
    ap.add_argument("--gh", action="store_true")        # accepted and ignored: the one transport is gh (deprecated, one minor)
    try:
        a = ap.parse_args(argv[1:])
    except SystemExit:
        return 64

    global LANG
    cwd = os.getcwd()
    rc, top = git("rev-parse", "--show-toplevel", cwd=cwd)      # stdout only; reused for the config below
    top = top if rc == 0 else ""
    LANG = messages.language(top or cwd)
    if not a.title.strip():
        err(M("op.title_empty"))
        return 64

    # ── (c) worktree ────────────────────────────────────────────────────────
    wt = in_linked_worktree(cwd)
    if wt is None:
        err(M("op.not_repo", cwd))
        return 5
    if not wt:
        err(M("op.main_tree", cwd, worktree_hint(cwd, LANG), a.base, worktree_why(LANG)))
        return 5

    # ── config: `.vibemaestro/sdlc.json` of this work tree; an invalid one is rc 64 naming the key ────────────────
    cfg, probs, _present = sdlc_config.load(top or cwd)
    if probs:
        err("%s is invalid; fix it (kb.py config check lists every problem):\n%s"
            % (sdlc_config.CONFIG_REL, sdlc_config.render_problems(probs)))
        return 64
    tcfg = cfg["pr"]["title"]
    if tcfg["pattern"] and not re.search(tcfg["pattern"], a.title):
        err("title does not match pr.title.pattern (%s)" % tcfg["pattern"])
        return 64
    if tcfg["max_len"] and len(a.title) > tcfg["max_len"]:
        err("title is %d characters, pr.title.max_len is %d" % (len(a.title), tcfg["max_len"]))
        return 64

    # ── summary ─────────────────────────────────────────────────────────────
    summary = read_file(a.summary_file, "summary_file")
    if summary is None:
        return 66
    if not summary.strip():
        err(M("op.summary_empty", a.summary_file))
        return 2

    # ── (a) bằng chứng chạy ─────────────────────────────────────────────────
    evidence = read_file(a.evidence_file, "evidence_file")
    if evidence is None or not evidence.strip():
        err(M("op.evidence_empty", a.evidence_file, cfg["tokens"]["not_run"]))
        return 3

    crit = ""
    if a.crit_file:
        crit = read_file(a.crit_file, "crit_file") or ""

    # ── head ────────────────────────────────────────────────────────────────
    head = a.head.strip()
    if not head:
        rc, head = git("rev-parse", "--abbrev-ref", "HEAD", cwd=cwd)
        if rc:
            head = ""
    if not head or head == "HEAD":
        err(M("op.no_head"))
        return 64
    if head in cfg["branch"]["protected"]:
        err(M("op.head_protected", head, head))
        return 64

    # ── thân PR ─────────────────────────────────────────────────────────────
    # `top` đã tính ở khối config: dòng `Tester: E2E` cần đọc `package.json` và
    # file quyết định trên cây để biết có điền sẵn miễn trừ được không.
    try:
        body = build_body(summary, evidence, crit, a.fixes, top or cwd, a.closes, cfg, plan_row_line(top or cwd, head, a.repo.strip()))
    except ValueError as e:
        err(str(e))
        return 2

    # ── the cap on the body (pr.body.*), the same function the pr-body gate runs on a body rewritten with `gh pr edit` ──────
    over = pr_body.check_body(body, cfg)
    if over:
        err("the PR body is over its cap — NOT opening the PR.\n%s\n"
            "       the summary file has %d non-empty lines, the evidence file %d (the body adds its own headings and fences)."
            % (pr_body.report(over, cfg), sum(1 for ln in summary.splitlines() if ln.strip()),
               sum(1 for ln in evidence.splitlines() if ln.strip())))
        return 2

    # ── (b) cổng sổ hiện trạng — sau khi có body, vì miễn trừ nằm TRONG body ─
    cs_rc, cs_msg = current_state_gate(top or cwd, a.base, head, body, cfg, _present)
    if cs_rc:
        err("the current-state gate refuses: the PR is NOT opened.\n" + cs_msg)
        return 4
    print("current-state gate: %s" % cs_msg, file=sys.stderr)

    payload = {"title": a.title, "head": head, "base": a.base, "body": body}
    if a.draft or cfg["pr"]["draft"]:
        payload["draft"] = True
    if a.payload_out:
        try:
            with open(a.payload_out, "w", encoding="utf-8") as f:
                json.dump(payload, f, ensure_ascii=False)
        except OSError as e:
            err(M("op.payload_out", e))
            return 66

    if a.dry_run:
        sys.stdout.write(json.dumps(payload, ensure_ascii=False) + "\n")
        return 0

    closes = []
    for n in re.findall(r"\d+", a.closes or ""):
        if n not in closes:
            closes.append(n)
    return create_pr(payload, a.repo.strip(), closes, cfg["pr"]["closing"])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
