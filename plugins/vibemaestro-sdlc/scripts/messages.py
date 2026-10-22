#!/usr/bin/env python3
"""The messages the sdlc scripts print to a person, in the repo's `language`: one table, one reader.

    messages.py [--root DIR] KEY [ARG...]     print the text of KEY with ARG... for the repo at DIR (default: the top of the git
                                              work tree holding the current directory, else the current directory); no newline.
                                              The two shell adapters print their refusals through this. rc 64 for an unknown key.

`TABLE` maps a key to its `vi` and `en` text. `vi` is the text the plugin printed before the table existed, byte for byte; `en` is
English. A message that was English already is not in the table: it prints the same in both languages. A text with `%`
placeholders is formatted with the arguments, the same placeholders in both languages (tests/test-messages-language.sh checks).

`language(root)` is the `language` of `<root>/.vibemaestro/sdlc.json` when it is one of `LANGUAGES`, else `vi`, the default of a
config without the key. It reads the file itself instead of through `sdlc_config.load`, which falls back to the defaults for an
invalid config: a refusal about that config must still speak the repo's language. It never raises.

Messages are not configuration: a repo cannot reword them (what the plugin writes INTO documents is `tokens`, in sdlc_config.py).
Standard library only, Python 3.8+. It imports nothing of the plugin, so `install_gates.py` vendors it beside sdlc_config.py.
"""
import json
import os
import subprocess
import sys

LANGUAGES = ("vi", "en")
CONFIG_REL = ".vibemaestro/sdlc.json"


def language(root):
    """`vi` or `en` for the repo at `root` (see the module docstring)."""
    try:
        with open(os.path.join(root or ".", CONFIG_REL), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError, RecursionError):
        return "vi"
    lang = data.get("language") if isinstance(data, dict) else None
    return lang if lang in LANGUAGES else "vi"


def language_at(cwd):
    """`language` of the repo whose work tree holds `cwd` (its top level, else `cwd` itself)."""
    return language(_toplevel(cwd) or cwd)


def text(key, lang, *args):
    """The text of `key` in `lang` (an unknown language reads `vi`), formatted with `args` when there are any. It never raises: a
    key this table does not have (a gate vendored from a newer plugin than its table) prints as the key and its arguments."""
    try:
        t = TABLE[key]["en" if lang == "en" else "vi"]
        return t % args if args else t
    except (KeyError, TypeError, ValueError):
        return " ".join([key] + [str(a) for a in args])


TABLE = {
    # ── kb.py ────────────────────────────────────────────────────────────────────────────────────────────────────────
    "kb.kind": {
        "vi": "loại '%s' không có — chỉ: %s",
        "en": "there is no kind '%s'; the kinds are: %s"},
    "kb.slug": {
        "vi": "slug '%s' không hợp lệ — chữ thường không dấu, số, gạch nối (vd: them-thanh-toan)",
        "en": "slug '%s' is not valid: lower case letters without accents, digits and hyphens (e.g. add-payment)"},
    "kb.no_dir": {
        "vi": "repo chưa có kb/%s/ — chạy `kb.py init` trước (skill vibemaestro-sdlc:init-kb)",
        "en": "the repo has no kb/%s/: run `kb.py init` first (skill vibemaestro-sdlc:init-kb)"},
    "kb.check_what": {
        "vi": "chỉ kiểm được 'spec' hoặc 'current-state' (dùng: kb.py check spec <<ngày>-<slug> | đường-dẫn> | "
              "kb.py check current-state [đường-dẫn])",
        "en": "only 'spec' or 'current-state' can be checked (usage: kb.py check spec <<date>-<slug> | path> | "
              "kb.py check current-state [path])"},
    "kb.cs_unreadable": {
        "vi": "không đọc được %s — repo chưa có kb/current-state.md (chưa init-kb?)",
        "en": "cannot read %s: the repo has no kb/current-state.md (init-kb not run?)"},
    "kb.cs_empty": {
        "vi": "%s rỗng — chưa có khuôn current-state; dựng bằng `vibemaestro-sdlc:init-kb` hoặc viết trạng thái hiện hành vào đó",
        "en": "%s is empty: no current-state shape yet; build it with `vibemaestro-sdlc:init-kb` or write the present state into it"},
    "kb.not_repo": {
        "vi": "cwd không nằm trong repo git: %s",
        "en": "the current directory is not in a git repo: %s"},
    "kb.date": {
        "vi": "--date phải là YYYY-MM-DD",
        "en": "--date must be YYYY-MM-DD"},
    "kb.usage": {
        "vi": "dùng: kb.py init [--answers F.json] [--lang vi|en] [--adopt [--detect]] [--dry-run] | kb.py new <intent|plan|spec> <slug> "
              "[--date D] | kb.py base --default <ref> | kb.py check spec <ngày-slug|đường-dẫn> | kb.py check current-state [đường-dẫn] | "
              "%s | %s",
        "en": "usage: kb.py init [--answers F.json] [--lang vi|en] [--adopt [--detect]] [--dry-run] | kb.py new <intent|plan|spec> <slug> "
              "[--date D] | kb.py base --default <ref> | kb.py check spec <date-slug|path> | kb.py check current-state [path] | "
              "%s | %s"},
    "kb.check_usage": {
        "vi": "dùng: kb.py check [--strict] | kb.py check spec <ngày-slug|đường-dẫn> | kb.py check current-state [đường-dẫn]",
        "en": "usage: kb.py check [--strict] | kb.py check spec <date-slug|path> | kb.py check current-state [path]"},
    "kb.new_usage": {
        "vi": "dùng: kb.py new <intent|plan|spec> <slug>",
        "en": "usage: kb.py new <intent|plan|spec> <slug>"},

    # ── current_state.py: the problems of `kb.py check current-state` and of the current-state gate ─────────────────────
    "cs.over_lines": {
        "vi": "vượt trần dòng: %d > %d — chi tiết đang nằm sai chỗ, đẩy sang kb/specs/ hoặc kb/decisions/",
        "en": "over the line cap: %d > %d; detail is in the wrong place, move it to kb/specs/ or kb/decisions/"},
    "cs.over_bytes": {
        "vi": "vượt trần byte: %d > %d — chi tiết đang nằm sai chỗ, đẩy sang kb/specs/ hoặc kb/decisions/",
        "en": "over the byte cap: %d > %d; detail is in the wrong place, move it to kb/specs/ or kb/decisions/"},
    "cs.long_line": {
        "vi": "dòng dài %d > %d ký tự — chi tiết trong một ô/dòng, đẩy sang spec/decision",
        "en": "line of %d > %d characters: detail in one cell or line, move it to a spec or a decision"},
    "cs.history_sign": {
        "vi": "dấu hiệu lịch sử [%s]: %r — current-state chỉ ghi trạng thái hiện hành%s",
        "en": "history sign [%s]: %r; current-state records only the present state%s"},
    "cs.forbidden": {
        "vi": "dấu hiệu bị cấm [%s]: %r — current-state chỉ ghi trạng thái hiện hành",
        "en": "forbidden sign [%s]: %r; current-state records only the present state"},
    "cs.history_heading": {
        "vi": "tiêu đề mục kiểu lịch sử — lịch sử đã có trong git log và PR, không ghi vào current-state",
        "en": "a history-style section heading: history is in the git log and the PRs, not in current-state"},
    "cs.sign.date_iso": {"vi": "ngày (YYYY-MM-DD)", "en": "date (YYYY-MM-DD)"},
    "cs.sign.date_slash_ymd": {"vi": "ngày (YYYY/MM/DD)", "en": "date (YYYY/MM/DD)"},
    "cs.sign.date_dm": {"vi": "ngày (dd/mm)", "en": "date (dd/mm)"},
    "cs.sign.date_words_month": {"vi": "ngày (tháng N năm YYYY)", "en": "date (month N of year YYYY, in Vietnamese)"},
    "cs.sign.date_words_day": {"vi": "ngày (ngày N tháng M)", "en": "date (day N of month M, in Vietnamese)"},
    "cs.sign.date_words_dm": {"vi": "ngày (ngày N/M)", "en": "date (day N/M, in Vietnamese)"},
    "cs.sign.pr_ref": {"vi": "số PR/issue", "en": "PR/issue number"},
    "cs.sign.commit_sha": {"vi": "commit SHA", "en": "commit SHA"},
    "cs.sign.past_words": {"vi": "từ chỉ lịch sử", "en": "past-tense word"},
    "cs.sign.update_stamp": {"vi": "dòng ghi ngày cập nhật", "en": "last-updated line"},
    "cs.render_head": {
        "vi": "kb: %s chưa đạt khuôn current-state (%d vấn đề):",
        "en": "kb: %s does not pass the current-state shape (%d problem(s)):"},
    "cs.line": {"vi": "dòng %d: ", "en": "line %d: "},
    "cs.more_problems": {"vi": "- … và %d vấn đề nữa", "en": "- … and %d more problem(s)"},
    "cs.unit_lines": {"vi": "dòng", "en": "line(s)"},
    "cs.unit_bytes": {"vi": "byte", "en": "byte(s)"},
    "cs.over_by": {
        "vi": "Quá trần %d %s (%s > %s): rút ít nhất bấy nhiêu.",
        "en": "Over the cap by %d %s (%s > %s): cut at least that much."},   # the unit: line(s) / byte(s)
    "cs.added_head": {
        "vi": "PR này đã thêm %d dòng vào %s (so với %s), đây là chỗ để rút:",
        "en": "This PR added %d line(s) to %s (against %s); this is where to cut:"},
    "cs.added_line": {"vi": "  dòng %d: %s", "en": "  line %d: %s"},
    "cs.added_more": {"vi": "  … và %d dòng nữa", "en": "  … and %d more line(s)"},
    "cs.fix": {
        "vi": "Sửa: viết đè trạng thái hiện hành; chi tiết/lịch sử/cách làm sang kb/specs/ hoặc kb/decisions/.",
        "en": "Fix: overwrite with the present state; detail, history and how-to go to kb/specs/ or kb/decisions/."},

    # ── intent_branch.py ─────────────────────────────────────────────────────────────────────────────────────────────
    "ib.usage": {
        "vi": """Lifecycle of the `intent/*` branch: the ONE path that creates, splits and integrates the branches of an intent.

Mô hình: một intent = một branch = một PR draft. PM ghi `kb/intent/<slug>.md`,
tạo `intent/<slug>` từ `origin/main`, mở PR draft. Worker cắt branch con TỪ
`intent/*`, làm trong worktree riêng, rồi góp ngược vào `intent/*`.

Thứ chứa QUYẾT ĐỊNH nằm ở đây, không ở lời dặn:

    (a) tạo `intent/<slug>` khi chưa có `kb/intent/<slug>.md`   → rc 3
    (b) branch con cắt từ một base `intent/*` KHÔNG tồn tại      → rc 5
    (c) góp ngược mà branch không phải hậu duệ tip `intent/*`:
        TỰ rebase; rebase hỏng (conflict) → rc 4 và DỪNG         → rc 4
    (d) góp ngược không ff được sau khi đã rebase                → rc 4
    (e) góp ngược từ CÂY CHÍNH (hoặc submodule), hay nhánh nguồn
        là `main`/`master` (mọi cách viết: `heads/main`,
        `refs/heads/main`, `origin/main`), hay env đặt biến định
        vị repo (`GIT_DIR`…) — từ chối TRƯỚC fetch/rebase/push   → rc 7
    (f) `worker-branch` KHÔNG `--no-checkout` mà đứng ở CÂY CHÍNH
        (hoặc submodule), hay env đặt `GIT_DIR`… — từ chối TRƯỚC
        khi tạo branch; `--no-checkout` thì cho qua               → rc 7
    (g) a rebase is needed and git cannot resolve a committer identity
        (config `rebase.identity`, then git): refused BEFORE the rebase → rc 2

Vì sao (e) chặn cả khi có `--branch`: `git rebase <tip> <branch>` checkout
nhánh đó NGAY TRONG cwd, nên chạy ở cây chính là đổi nhánh của cây chung dù
nhánh nguồn là gì. Phép dò worktree dùng chung `open_pr.in_linked_worktree`.
Lời nhắc chỗ đặt worktree trong thông điệp rc 7 (`open_pr.worktree_hint` +
`WORKTREE_WHY`) nói worktree phải nằm TRONG clone.

Vì sao (c) phải là code chứ không phải một dòng trong skill: `--ff-only` giữ
lịch sử `intent/*` tuyến tính, nhưng người tích hợp gặp `--ff-only` đỏ thì phản
xạ tự nhiên là gõ `git merge` thường — và lịch sử mất tuyến tính mà không có gì
đỏ lên. Đường này KHÔNG BAO GIỜ gọi `git merge` không có `--ff-only`, nên ca đó
không tồn tại: hoặc rebase xong rồi ff, hoặc `block`.

`--to` khai TƯỜNG MINH, KHÔNG auto-detect:
  `--to local`    merge `--ff-only` vào branch `intent/*` của repo đang đứng.
                  Git chỉ cho MỘT worktree giữ một branch, nên đường này hỏng
                  (rc 5) khi `intent/*` đang bị worktree khác chiếm — đó là
                  trạng thái bình thường khi PM còn mở worktree của intent.
  `--to origin`   `git push origin <branch>:refs/heads/<intent>`. Push thường
                  của git vốn đã từ chối non-fast-forward, nên đây là cùng một
                  phép chặn ở tầng khác. Đây là đường nhiều worker song song
                  dùng: mỗi worker một worktree, không ai checkout `intent/*`.
Tự đoán giữa hai đường là tự chọn chỗ ghi cho người dùng, nên không có mặc định.

Dùng:
    intent_branch.py create-intent --slug <ngày-slug> [--base origin/main]
                                   [--no-checkout] [--issue]
    intent_branch.py worker-branch --intent <intent/slug|slug> --name <branch>
                                   [--no-checkout]
    intent_branch.py integrate     --intent <intent/slug|slug> --to local|origin
                                   [--branch <br>] [--no-fetch] [--no-rebase]
    intent_branch.py retry-issue   --slug <ngày-slug>
                                   # đường thử lại khi `create-intent --issue`
                                   # lần đầu không tạo được issue (quyền/mạng);
                                   # `create-intent` không dùng lại được vì
                                   # branch đã tồn tại thì nó từ chối ở rc 6.

rc: 0 xong · 1 `retry-issue` không tạo được issue (best-effort, KHÔNG dùng cho
    `create-intent`/`worker-branch`/`integrate` — ba lệnh đó dùng các rc có tên
    dưới đây) · 2 môi trường (không phải git repo, thiếu git) · 3 thiếu
    `kb/intent/<slug>.md` · 4 không góp ngược được — BLOCK · 5 base/đích không
    dùng được · 6 branch đã tồn tại (dedup/race) · 7 integrate, hay
    worker-branch có checkout, đứng sai chỗ (cây chính/submodule, nhánh nguồn
    main/master, hoặc env `GIT_DIR`…)
    · 64 sai tham số
""",
        "en": """Lifecycle of the `intent/*` branch: the ONE path that creates, splits and integrates the branches of an intent.

Model: one intent = one branch = one draft PR. The PM writes `kb/intent/<slug>.md`,
creates `intent/<slug>` from `origin/main` and opens a draft PR. A worker cuts a child
branch FROM `intent/*`, works in a worktree of its own, then integrates back into `intent/*`.

The DECISIONS live here, not in instructions:

    (a) creating `intent/<slug>` with no `kb/intent/<slug>.md`    → rc 3
    (b) a child branch cut from an `intent/*` base that does NOT
        exist                                                     → rc 5
    (c) integrating a branch that does not descend from the
        `intent/*` tip: it rebases ITSELF; a failed rebase
        (conflict) → rc 4 and STOP                                → rc 4
    (d) integrating cannot fast-forward after the rebase         → rc 4
    (e) integrating from the MAIN TREE (or a submodule), from a
        `main`/`master` source branch (any spelling: `heads/main`,
        `refs/heads/main`, `origin/main`), or with a repo-locating
        variable (`GIT_DIR`…) set: refused BEFORE fetch/rebase/push → rc 7
    (f) `worker-branch` WITHOUT `--no-checkout` from the MAIN TREE
        (or a submodule), or with `GIT_DIR`… set: refused BEFORE
        the branch is created; `--no-checkout` passes              → rc 7
    (g) a rebase is needed and git cannot resolve a committer identity
        (config `rebase.identity`, then git): refused BEFORE the rebase → rc 2

Why (e) refuses even with `--branch`: `git rebase <tip> <branch>` checks that
branch out RIGHT IN the cwd, so running it in the main tree switches the
branch of the shared tree whatever the source branch is.

Why (c) is code and not a line in a skill: `--ff-only` keeps the history of
`intent/*` linear, but an integrator who meets a red `--ff-only` naturally
types a plain `git merge`, and the history loses its linearity with nothing
turning red. This path NEVER calls `git merge` without `--ff-only`, so that
case does not exist: either it rebases and fast-forwards, or it blocks.

`--to` is EXPLICIT, never auto-detected:
  `--to local`    `--ff-only` merge into the `intent/*` branch of this repo.
                  Git lets ONE worktree hold a branch, so this path fails
                  (rc 5) when another worktree holds `intent/*`, which is the
                  normal state while the PM keeps the intent's worktree open.
  `--to origin`   `git push origin <branch>:refs/heads/<intent>`. A plain push
                  already refuses a non-fast-forward, so this is the same
                  block at another layer. It is the path of parallel workers:
                  one worktree each, nobody checks `intent/*` out.
Guessing between the two would choose where to write for the user, so there is no default.

Usage:
    intent_branch.py create-intent --slug <date-slug> [--base origin/main]
                                   [--no-checkout] [--issue]
    intent_branch.py worker-branch --intent <intent/slug|slug> --name <branch>
                                   [--no-checkout]
    intent_branch.py integrate     --intent <intent/slug|slug> --to local|origin
                                   [--branch <br>] [--no-fetch] [--no-rebase]
    intent_branch.py retry-issue   --slug <date-slug>
                                   # the retry when `create-intent --issue`
                                   # could not create the issue the first time
                                   # (permission/network); `create-intent`
                                   # cannot be reused: the branch exists, so
                                   # it refuses with rc 6.

rc: 0 done · 1 `retry-issue` could not create the issue (best-effort, NOT used
    by `create-intent`/`worker-branch`/`integrate`: those use the named rcs
    below) · 2 environment (not a git repo, no git) · 3 no
    `kb/intent/<slug>.md` · 4 cannot integrate: BLOCK · 5 base/target not
    usable · 6 the branch exists (dedup/race) · 7 integrate, or
    worker-branch with a checkout, run from the wrong place (main
    tree/submodule, a main/master source branch, or `GIT_DIR`… set)
    · 64 bad arguments
"""},
    "ib.help_issue": {
        "vi": "tạo GitHub issue theo dõi (best-effort), ghi số issue vào frontmatter hồ sơ intent",
        "en": "create the GitHub tracking issue (best-effort) and record its number in the intent file's frontmatter"},
    "ib.not_repo": {"vi": "không phải git repo: %s", "en": "not a git repo: %s"},
    "ib.no_gh": {"vi": "không có `gh` trên máy", "en": "no `gh` on this machine"},
    "ib.issue_body": {"vi": "%s\n\nChi tiết: `%s`\n", "en": "%s\n\nDetails: `%s`\n"},
    "ib.issue_number": {
        "vi": "không đọc được số issue từ output `gh issue create`: %r",
        "en": "cannot read an issue number from the output of `gh issue create`: %r"},
    "ib.no_slug": {"vi": "thiếu --slug", "en": "--slug is missing"},
    "ib.retry_no_doc": {"vi": "chưa có %s", "en": "%s does not exist yet"},
    "ib.retry_has_issue": {
        "vi": "hồ sơ đã có dòng `issue:` — không tạo thêm (idempotent): %s",
        "en": "the intent file already has an `issue:` line: no new issue (idempotent): %s"},
    "ib.slug_slash": {"vi": "slug không được chứa `/`: %s", "en": "a slug cannot hold `/`: %s"},
    "ib.no_doc": {
        "vi": "chưa có %s — `kb/intent/` là việc TRƯỚC khi tạo branch, không phải việc dọn sau",
        "en": "%s does not exist yet: `kb/intent/` comes BEFORE the branch, not as a cleanup after it"},
    "ib.empty_doc": {
        "vi": "%s rỗng — hồ sơ intent là lời người đặt, không phải file giữ chỗ",
        "en": "%s is empty: an intent file holds the requester's words, it is not a placeholder"},
    "ib.exists": {"vi": "branch %s đã tồn tại — dedup hoặc race", "en": "branch %s already exists: a duplicate or a race"},
    "ib.no_base": {"vi": "base %s không tồn tại", "en": "base %s does not exist"},
    "ib.create_failed": {"vi": "không tạo được %s từ %s: %s", "en": "cannot create %s from %s: %s"},
    "ib.wb_env": {
        "vi": "env đang đặt %s — phép dò worktree bỏ qua chúng nhưng `git checkout` thì không, nên có thể chuyển nhánh của repo khác. "
              "KHÔNG tạo %s. Bỏ các biến đó rồi chạy lại với `--cwd <worktree>`, hoặc thêm `--no-checkout`.",
        "en": "the environment sets %s: the worktree probe ignores them but `git checkout` does not, so it could switch the branch "
              "of another repo. NOT creating %s. Unset those variables and run again with `--cwd <worktree>`, or add `--no-checkout`."},
    "ib.no_gitdir": {"vi": "không dò được git-dir ở `%s`", "en": "cannot find the git-dir at `%s`"},
    "ib.wb_main_tree": {
        "vi": "đang đứng ở CÂY CHÍNH của repo (hoặc một submodule) — KHÔNG tạo %s. `checkout -b` sẽ chuyển nhánh của cây chung, "
              "nơi có thể đang mang việc dở của phiên khác. Tạo branch không checkout rồi làm trong worktree riêng:\n"
              "       scripts/intent-branch.sh worker-branch --intent %s --name %s --no-checkout\n"
              "       git worktree add %s %s\n"
              "       %s",
        "en": "this is the MAIN TREE of the repo (or a submodule): NOT creating %s. `checkout -b` would switch the branch of the "
              "shared tree, which may hold another session's unfinished work. Create the branch without a checkout, then work in "
              "a worktree of your own:\n"
              "       scripts/intent-branch.sh worker-branch --intent %s --name %s --no-checkout\n"
              "       git worktree add %s %s\n"
              "       %s"},
    "ib.no_intent": {"vi": "thiếu --intent", "en": "--intent is missing"},
    "ib.no_name": {"vi": "thiếu --name", "en": "--name is missing"},
    "ib.wb_prefix": {
        "vi": "branch con không được mang tiền tố `%s`: %s — nó là branch làm việc, không phải đơn vị tích hợp",
        "en": "a child branch cannot carry the prefix `%s`: %s; it is a working branch, not the unit of integration"},
    "ib.wb_no_tip": {
        "vi": "base %s không tồn tại ở local lẫn origin — PM phải tạo và đẩy branch intent trước",
        "en": "base %s exists neither locally nor on origin: the PM must create and push the intent branch first"},
    "ib.int_env": {
        "vi": "env đang đặt %s — phép dò worktree bỏ qua chúng nhưng lệnh git ghi thì không, nên hai bên có thể nhìn hai repo khác "
              "nhau. KHÔNG góp ngược. Bỏ các biến đó rồi chạy lại với `--cwd <worktree>`.",
        "en": "the environment sets %s: the worktree probe ignores them but the git commands that write do not, so the two could "
              "see two different repos. NOT integrating. Unset those variables and run again with `--cwd <worktree>`."},
    "ib.int_main_tree": {
        "vi": "đang đứng ở CÂY CHÍNH của repo (hoặc một submodule), không phải worktree liên kết — KHÔNG góp ngược. Rebase sẽ "
              "checkout nhánh ngay trong cây chung, nơi có thể đang mang việc dở của phiên khác.\n"
              "       cd vào worktree của bạn rồi chạy lại; chưa có thì:\n"
              "       git worktree add -b <branch> %s origin/%s\n"
              "       %s",
        "en": "this is the MAIN TREE of the repo (or a submodule), not a linked worktree: NOT integrating. The rebase would check "
              "the branch out right in the shared tree, which may hold another session's unfinished work.\n"
              "       cd into your worktree and run again; if you have none:\n"
              "       git worktree add -b <branch> %s origin/%s\n"
              "       %s"},
    "ib.no_head": {
        "vi": "không xác định được branch đang đứng — khai `--branch`",
        "en": "cannot tell the current branch: pass `--branch`"},
    "ib.int_self": {"vi": "branch góp ngược không được chính là %s", "en": "the branch to integrate cannot be %s itself"},
    "ib.int_protected": {
        "vi": "nhánh nguồn là `%s` — KHÔNG góp ngược nhánh mặc định vào %s (rebase sẽ viết lại `%s` lên việc chưa review). "
              "Góp nhánh con của bạn: `--branch <nhánh-con>`, hoặc checkout nó trong worktree.",
        "en": "the source branch is `%s`: NOT integrating the default branch into %s (the rebase would rewrite `%s` onto "
              "unreviewed work). Integrate your child branch: `--branch <child-branch>`, or check it out in the worktree."},
    "ib.no_branch": {"vi": "branch %s không tồn tại", "en": "branch %s does not exist"},
    "ib.int_no_tip": {"vi": "%s không tồn tại ở local lẫn origin", "en": "%s exists neither locally nor on origin"},
    "ib.int_not_descendant": {
        "vi": "%s không phải hậu duệ của %s (tip đã nhích) — TỪ CHỐI góp ngược. `--no-rebase` đang bật nên không tự rebase.",
        "en": "%s does not descend from %s (the tip moved): integration REFUSED. `--no-rebase` is on, so no automatic rebase."},
    "ib.int_rebasing": {
        "vi": "%s cũ hơn %s — rebase trước khi ff (tự động)",
        "en": "%s is older than %s: rebasing before the fast-forward (automatic)"},
    "ib.int_rebase_failed": {
        "vi": "rebase %s lên %s HỎNG — BLOCK. Conflict ở file thuộc phạm vi task của bạn thì tự sửa rồi chạy lại; ngoài phạm vi thì "
              "dừng và hỏi.\n%s",
        "en": "rebase of %s onto %s FAILED: BLOCK. A conflict in a file of your task's scope: fix it yourself and run again; "
              "outside the scope: stop and ask.\n%s"},
    "ib.int_still_behind": {
        "vi": "rebase xong mà %s vẫn không phải hậu duệ %s — BLOCK",
        "en": "the rebase finished but %s still does not descend from %s: BLOCK"},
    "ib.int_push": {
        "vi": "push %s → %s bị từ chối (non-fast-forward hoặc mạng) — BLOCK\n%s",
        "en": "push %s → %s refused (non-fast-forward or network): BLOCK\n%s"},
    "ib.int_held": {
        "vi": "%s đang bị worktree khác giữ (%s) — git chỉ cho MỘT worktree giữ một branch. Dùng `--to origin`.",
        "en": "%s is held by another worktree (%s): git lets ONE worktree hold a branch. Use `--to origin`."},
    "ib.int_local_copy": {"vi": "không tạo được bản local của %s: %s", "en": "cannot create the local copy of %s: %s"},
    "ib.int_checkout": {"vi": "không checkout được %s: %s", "en": "cannot check out %s: %s"},
    "ib.int_ff": {"vi": "ff-only %s → %s bị từ chối — BLOCK\n%s", "en": "ff-only %s → %s refused: BLOCK\n%s"},

    # ── intent-branch.sh (the adapter; its refusals before python3 runs carry their own two texts) ────────────────────
    "ib.sh.no_subcommand": {
        "vi": "thiếu lệnh con: create-intent | worker-branch | integrate | retry-issue",
        "en": "a subcommand is missing: create-intent | worker-branch | integrate | retry-issue"},
    "ib.sh.task_commits": {
        "vi": "intent-branch: %s có %s commit so với điểm cắt %s — một task = một\n"
              "       commit, một vòng sửa theo review = một commit. KHÔNG góp ngược, KHÔNG tự squash.\n"
              "       Squash về ĐIỂM CẮT (merge-base), không về tip — reset về tip là xoá việc\n"
              "       người khác vừa góp:\n"
              "         git reset --soft \"$(git merge-base HEAD %s)\"\n"
              "         git commit           # một message cho cả việc\n"
              "       rồi chạy lại. Thứ tự các bước là load-bearing và mỗi bước revert được độc\n"
              "       lập thì khai `--load-bearing`.",
        "en": "intent-branch: %s has %s commits over its cut point %s: one task = one\n"
              "       commit, one review fix round = one commit. NOT integrating, NOT squashing for you.\n"
              "       Squash onto the CUT POINT (merge-base), not onto the tip: a reset to the tip deletes\n"
              "       work others just integrated:\n"
              "         git reset --soft \"$(git merge-base HEAD %s)\"\n"
              "         git commit           # one message for the whole task\n"
              "       then run again. When the order of the steps is load-bearing and each step can be reverted\n"
              "       on its own, pass `--load-bearing`."},

    # ── open_pr.py ───────────────────────────────────────────────────────────────────────────────────────────────────
    "op.worktree_path": {"vi": "%s/.claude/worktrees/<tên>", "en": "%s/.claude/worktrees/<name>"},
    "op.worktree_clone": {"vi": "<clone>/.claude/worktrees/<tên>", "en": "<clone>/.claude/worktrees/<name>"},
    "op.worktree_why": {
        "vi": "(đặt worktree TRONG clone — ngoài thư mục làm việc là hộp thoại xin quyền; quy trình Git điều 1.)",
        "en": "(put the worktree INSIDE the clone: outside the working directory every edit asks for permission; git process, rule 1.)"},
    "op.summary_heading_only": {
        "vi": "summary_file chỉ có tiêu đề, không có nội dung",
        "en": "summary_file holds only the heading, no content"},
    "op.gh_error": {"vi": "gh pr create lỗi: %s", "en": "gh pr create failed: %s"},
    "op.cannot_read": {"vi": "không đọc được %s: %s", "en": "cannot read %s: %s"},
    "op.title_empty": {"vi": "--title rỗng", "en": "--title is empty"},
    "op.not_repo": {"vi": "`%s` không nằm trong một repo git", "en": "`%s` is not in a git repo"},
    "op.main_tree": {
        "vi": "git-dir trùng git-common-dir ở `%s` — đây là CÂY CHÍNH của repo (hoặc một submodule), không phải worktree liên kết. "
              "KHÔNG mở PR.\n"
              "       Cây chung có thể đang mang việc dở của session khác (git-workflow điều 1).\n"
              "       git worktree add -b <branch> %s origin/%s\n"
              "       %s",
        "en": "the git-dir is the git-common-dir at `%s`: this is the MAIN TREE of the repo (or a submodule), not a linked worktree. "
              "NOT opening the PR.\n"
              "       The shared tree may hold another session's unfinished work (git process, rule 1).\n"
              "       git worktree add -b <branch> %s origin/%s\n"
              "       %s"},
    "op.summary_empty": {"vi": "summary_file rỗng: %s", "en": "summary_file is empty: %s"},
    "op.evidence_empty": {
        "vi": "evidence_file rỗng/thiếu: %s — KHÔNG mở PR.\n"
              "       Chạy lệnh chứng minh thay đổi của bạn hoạt động rồi ghi CẢ lệnh\n"
              "       lẫn output thật vào file đó. Không chạy được thì dòng đầu ghi:\n"
              "         %s <lý do cụ thể>",
        "en": "evidence_file is empty or missing: %s: NOT opening the PR.\n"
              "       Run the command that proves your change works, then write BOTH the command\n"
              "       and its real output into that file. If it cannot run, the first line says:\n"
              "         %s <the concrete reason>"},
    "op.no_head": {
        "vi": "không xác định được branch head (detached?) — truyền `--head <branch>`",
        "en": "cannot tell the head branch (detached?): pass `--head <branch>`"},
    "op.head_protected": {
        "vi": "head là '%s' — PR phải mở TỪ branch riêng, không phải từ %s",
        "en": "the head is '%s': a PR opens FROM a branch of its own, not from %s"},
    "op.payload_out": {"vi": "không ghi được --payload-out: %s", "en": "cannot write --payload-out: %s"},

    # ── open-pr.sh (the adapter; its refusals before python3 runs carry their own two texts) ──────────────────────────
    "op.sh.unknown_arg": {"vi": "tham số lạ: %s", "en": "unknown argument: %s"},
    "op.sh.no_title": {"vi": "thiếu --title", "en": "--title is missing"},
    "op.sh.no_summary": {"vi": "thiếu --summary <file>", "en": "--summary <file> is missing"},
    "op.sh.no_evidence": {
        "vi": "thiếu --evidence <file> — bằng chứng chạy là ĐIỀU KIỆN mở PR",
        "en": "--evidence <file> is missing: run evidence is a CONDITION for opening a PR"},
    "op.sh.no_gh": {"vi": "không có `gh`", "en": "no `gh`"},

    # ── gates/pr_evidence.py and the config loader: the E2E exemption line they name ────────────────────────────────────
    "pe.e2e_missing": {
        "vi": "this PR changes UI paths (%s) and no comment pinned to the head %s has \"E2E pass\" or \"E2E không chạy: <reason>\".",
        "en": "this PR changes UI paths (%s) and no comment pinned to the head %s has \"E2E pass\" or \"E2E not run: <reason>\"."},
    "pe.e2e_short": {
        "vi": "✗ e2e: \"E2E không chạy:\" needs a reason of at least %d characters (%s)",
        "en": "✗ e2e: \"E2E not run:\" needs a reason of at least %d characters (%s)"},
    "config.tester_exempt_note": {
        "vi": "the E2E exemption is a line `E2E không chạy: <reason>` in a comment pinned to the head (pr-evidence)",
        "en": "the E2E exemption is a line `E2E not run: <reason>` in a comment pinned to the head (pr-evidence)"},
}


def _toplevel(cwd):
    """The top of the git work tree holding `cwd` (stdout only: git may write to stderr on success), or None."""
    try:
        r = subprocess.run(["git", "-C", cwd or ".", "rev-parse", "--show-toplevel"], capture_output=True, text=True, timeout=10)
    except Exception:
        return None
    return r.stdout.strip() if r.returncode == 0 and r.stdout.strip() else None


def main(argv):
    root = None
    if argv[:1] == ["--root"] and len(argv) >= 2:
        root, argv = argv[1], argv[2:]
    if not argv or argv[0] not in TABLE:
        sys.stderr.write("messages: usage: messages.py [--root DIR] KEY [ARG...] (unknown key: %s)\n" % (argv[0] if argv else ""))
        return 64
    sys.stdout.write(text(argv[0], language(root) if root is not None else language_at(os.getcwd()), *argv[1:]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
