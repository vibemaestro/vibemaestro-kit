#!/usr/bin/env python3
"""`kb/` của REPO ĐANG ĐỨNG: dựng khung tối thiểu (init), tạo file theo khuôn tên (new), kiểm hình dạng (check).

Mọi việc đều ghi/đọc `kb/` của repo ở cwd. Không đọc hay ghi repo nào khác.

  kb.py init [--answers F.json] [--lang vi|en] [--adopt [--detect]] [--dry-run] [--everyday]
      dựng kb/{intent,specs,plans,decisions}/, kb/README.md, kb/current-state.md VÀ cấu hình `.vibemaestro/sdlc.json` của repo (chỉ khoá đã
      chọn: scaffold, giá trị dò được, câu trả lời), cộng `<rules.dirs[0]>/README.md` và `example.instructions.md` cho repo app. IDEMPOTENT:
      thứ đã có giữ nguyên byte (`kept`), config đã có không bao giờ bị viết lại (in `would add` / `differs`). `--adopt` cho repo đã có file
      quy trình: không ghi file luật, không sửa file nào, in việc phải làm tay.
      `--detect` (chỉ với `--adopt`) ĐỀ XUẤT; câu trả lời thắng. Câu trả lời hỏng thì rc 65 và không ghi gì. Chi tiết ở `init_setup.py`.
      `--everyday` (chế độ đời thường của kit): chỉ `kb/current-state.md` và `kb/preferences.md`, rỗng, để Claude viết bằng tiếng của người dùng.
      `kb/README.md` sinh ra TỰ ĐỦ (bảng thư mục, quy ước tên, khuôn spec và khuôn current-state) — không trỏ sang repo nào khác.
      `--lang vi|en`: the scaffold's language (also the answer `language`); without it, the `language` of the config (absent: vi).
  kb.py new <intent|plan|real-run|spec> <slug> [--date YYYY-MM-DD]
      writes kb/<kind>/<date>-<slug>.md from a template with placeholder marks (`tokens.spec.placeholder`); never overwrites a file.
      The `spec` template is the five sections of a spec derived from a story (`tokens.spec`: goal, constraints, criteria, risks,
      clarify); the `plan` template has the columns Row, How, Delivers, Depends on, Trust touches, Link; in the prose of `language`.
  kb.py new intent <slug> --type story|task|bug [--focus P<n>] [--jira <KEY>]
      the intent with `type:` and `focus:` in its frontmatter and the card of its type: a story's is the story the owner approves,
      in the prose of `language` (the As / I want / so that line, context, AC, out of scope, appetite, questions), replacing the
      request paragraph; a task's `## What`, `## Why`, `## Check`; a bug's `## Reproduce`, `## Expected`, `## Test`, the same
      headings in every language. `--jira` writes `jira: <KEY>` (a Jira issue key, like
      ABC-12): stored and shown (check intent, plan status), never synced.
  kb.py check intent <<date>-<slug> | path> [--strict]
      judges the card of the intent's type: its sections, a story's As a / I want / so that, an `AC<n>` id and a quote (`"…"`, `“…”`
      or `(page decision <id> (<option>))`) on each AC. `type:` and `focus:` follow `intake.focus` (required: red, warn: a WARNING,
      off: not read). A Not doing line with neither a quote nor a page decision id is a WARNING, red under `--strict`. An intent
      already on the merge base only warns. A `key:` (`<CODE>-<n>`, create-intent writes it under `issue.code`) or a `jira:` not
      shaped as one is red; both are printed when they pass. rc 0 pass, 65 not.
      A story is the one the owner approves (STORY_PARTS) unless it has the first card's shape (a `## Story`, `## Acceptance
      criteria`, `## Not doing` or `## Measure` section, and no appetite part): its parts named by a bold lead or a heading, vi or en labels; red only for a missing or empty part (the As / I want / so that line, context, AC, out
      of scope, appetite), an AC number written twice or no number, more than 3 open questions; a question with no
      recommendation or reason, code, a path, a file name, a command or a story over 3500 characters is a WARNING. Such a story
      already on the merge base whose AC changed, was dropped or added is red until its decisions gain an item quoting the
      owner (an AC changes only by the owner's word); `check links` runs the same on the stories changed in the change. A first
      story card on a new intent is a WARNING.
  kb.py base --default <ref>
      prints the ref `intake` must cut its worktree from: `<ref>` (the default branch, e.g. origin/main) when it already
      has `kb/intent/`; otherwise `origin/chore/kb-init` (or its old name `origin/chore/kb-khoi-tao`) when the init-kb branch is pushed and
      has kb/ (the intent PR then carries the scaffold commit). Neither: rc 2, pointing at init-kb.
  kb.py check spec <<ngày>-<slug> | đường-dẫn> [--strict]
      A spec of the earlier shape — máy kiểm HÌNH DẠNG của một spec: đủ năm mục đúng thứ tự (`## Thiết kế` tuỳ chọn, sau chúng), không rỗng, không
      còn dấu placeholder, mỗi tiêu chí có lệnh trong `…`, tiêu chí cuối nhắc `## Bằng chứng chạy`. Tên mục, tiêu đề bằng chứng
      và dấu placeholder lấy từ `tokens.spec` (preset `language: en`: Context, Goal, Out of scope, Acceptance criteria, Design,
      Run evidence, `<FILL`). `## Inputs and failure cases` (một bảng ba cột, hoặc một dòng `none, because <lý do>`) bắt buộc ở
      spec mới (không có trên merge base của `check links`); spec đã có chỉ bị một dòng WARNING. KHÔNG kiểm lệnh có đúng/chạy
      được, và KHÔNG kiểm người đã duyệt — duyệt là lời của người, máy không có dấu "đã duyệt".
      A story spec (its intent, named by its `Intent:` line or naming it in `spec:`, says `type: story`) also traces its AC:
      every AC of the intent's `## Acceptance criteria` is in `## Mục tiêu`, every criterion but the last ends `→ AC<n>[, AC<m>]`,
      every id after an arrow is an AC of the intent, every AC is named (a spec that already existed only warns, unless
      `--strict`). An out-of-scope line with neither a quote (`"…"`, `“…”`) nor `(page decision <id> (<key>))` is a WARNING,
      red under `--strict` (what `open-pr.sh` runs on a story's branch).
      A spec holding `tokens.spec.constraints`, `.risks` or `.clarify` is a spec derived from a story: five sections in any
      order (goal, constraints, criteria, risks, clarify), none missing, empty or foreign, no command needed; against a story,
      every AC is named by a criterion's `→ AC<n>` and none the story lacks is named (red, as above). A criterion naming no AC
      or not written as when … then (khi … thì), a code block, a spec over 8000 characters: a WARNING, never red. A story's spec
      of the earlier shape is red when new or when its body changed (not its frontmatter), a WARNING otherwise; `check plan`
      judges a story's plan of the earlier columns (Must be true, Current state, Shared files, Acceptance, Model) red when new or
      when a row cell other than Link changed (what the owner's plan signature binds).
  kb.py check current-state [đường-dẫn]
      máy kiểm khuôn `kb/current-state.md` theo profile `current_state` của repo (không có config: preset `ledger`, chỉ trạng
      thái hiện hành, không dấu lịch sử, trong trần kích thước). Logic ở `current_state.py`.
  kb.py check current-state --diff <base>...<head> --body-file F [--config-ref REF]
      the diff gate: a changed path under `current_state.watch` needs the ledger in the diff, or a line of F (the PR body) that
      starts with a `tokens.no_state_change` token; the ledger must pass the template. rc 0 pass, 65 block or cannot conclude.
      `--config-ref REF` reads the profile (and an `external` script) from REF instead of the working tree: CI passes the PR's
      BASE so a PR cannot relax its own gate. Absent at REF means the defaults (the gate then does not apply).
  kb.py find <words...> [--type intent|spec|plan|decision] [--all] [--limit N]
  kb.py list [--type T] [--status S]
  kb.py outline <file>
      find what is in kb/ without reading it (logic in `kb_index.py`): one line per document (path | type | status | date |
      description [| superseded_by]); `find` ranks by matches in path, description and headings and hides superseded/done
      documents unless --all; `outline` prints the heading tree with line ranges and bytes so one section can be read with
      offset/limit. Read-only, never prints a body.
  kb.py check [--strict]
      the lifecycle of every kb/ document: rc 65 on an unknown `status`, a `supersedes`/`superseded_by` path that does not
      exist or does not point back, `superseded` without `superseded_by` (and the reverse); `--strict` also fails on a missing
      `description` or `status`. A spec over `kb.spec_warn_bytes` is a `WARNING` line, rc stays 0. Read-only like find. It also
      runs `check intent` on every intent new in the change (absent from the merge base; none when there is no base).
  kb.py plan status <plan file> [--json]
      the state of each row of a multi-PR plan, read from GitHub (planned, intent open, PR open with head and CI, merged with its
      commit, dropped with its reason), and the drift (version, dependency, two PRs for one row). Read-only; without `gh` or network
      the GitHub part says `not checked`. A row is linked by its Link cell or by an intent whose frontmatter has
      `plan: kb/plans/<file>.md#<row id>`, never by a mention. Logic in `kb_plan.py`.
  kb.py check links [--base REF | --all]
      the links between intents, specs and plans (`plan:`, `spec:`, a spec's `Intent:`, plan rows and Decisions): rc 65 on a broken
      one in a file changed against the merge base of REF (default origin/HEAD, else origin/main), an `OLD` line for older files.
  kb.py config check [--root DIR] · kb.py config migrate [--write]
      checks `.vibemaestro/sdlc.json` of DIR (default: the repo of the cwd): problems go to stderr with rc 65; warnings
      (duplicate rule paragraphs, rule-name collisions, unknown `rules.disable` names, missing `rules.dirs`), the
      `current_state.gate: external:<path>` review line and one `WARNING <key>: …` line per key this plugin ignores (an unknown
      key, a deprecated one) go to stdout, rc 0. Every other command here exits 65 on an invalid config.
      `config migrate` prints the config carried up to the plugin's schema (sdlc_config.MIGRATIONS); `--write` writes it.

Khung tối thiểu: bốn thư mục (mỗi cái một `.gitkeep`), README, current-state; tên file theo ngày.
rc: 0 xong · 2 không phải repo git / chưa init · 6 file đã có ·
64 sai tham số · 65 spec/current-state chưa đạt khuôn, hoặc config hỏng · 66 không thấy file để kiểm (current-state: kể cả file rỗng).
Chỉ dùng thư viện chuẩn, Python 3.8+.
"""
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
import unicodedata

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import current_state  # noqa: E402
import init_setup  # noqa: E402
import kb_index  # noqa: E402
import kb_plan as plans  # noqa: E402  (the module; `kb_plan()` below is the init plan)
import messages  # noqa: E402
import rule_packs  # noqa: E402
import rules as R  # noqa: E402
import sdlc_config as C  # noqa: E402
import vsdlc  # noqa: E402  (git_out, plugin_root và CORE_NAME dùng chung một nơi định nghĩa)

KB_BRANCH = vsdlc.SCAFFOLD_BRANCH          # the branch the skill init-kb creates and pushes; kb.py base looks for this name (defined in vsdlc.py, which the kb/ reminder reads too)
KB_BRANCH_OLD = vsdlc.SCAFFOLD_BRANCH_OLD  # its old name: an init-kb branch pushed before the rename is still found
KB_PROBE = vsdlc.SCAFFOLD_PROBE
DIRS = ("intent", "specs", "plans", "decisions")
KINDS = {"intent": "intent", "plan": "plans", "real-run": "records", "spec": "specs"}
SLUG_RX = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
DATE_RX = re.compile(r"^\d{4}-\d{2}-\d{2}$")

README = {"vi": """# `kb/` của repo này

Nơi repo ghi nhớ: yêu cầu, thiết kế, quyết định và hiện trạng — để người và phiên Claude Code sau không phải đoán.
Dựng bởi skill `init-kb` của plugin `vibemaestro-sdlc`; file này tự đủ, sửa tay thoải mái.

| Thư mục / file | Nội dung | Có nghĩa vụ cập nhật? |
|---|---|---|
| `intent/` | yêu cầu gốc bằng lời người đặt, 1-2 đoạn; với story: chính story chủ repo duyệt | không — bản ghi một lần |
| `specs/` | điều phải đúng, suy ra từ story: mục tiêu, ràng buộc, tiêu chí, rủi ro; spec của một intent theo khuôn bên dưới | có, khi code dạy điều mới (spec sống) |
| `plans/` | cách làm: mỗi PR một hàng, giao AC nào, phụ thuộc, chỗ cần ký; plan sống | có, khi code dạy điều mới |
| `decisions/` | chốt một lựa chọn, **kèm phương án bị loại** | không, nhưng nêu rõ khi bị thay |
| `current-state.md` | trạng thái hiện hành của repo | **có — file DUY NHẤT phải luôn đúng** |

**Tên file** `intent/`, `specs/`, `plans/`, `decisions/`: `<YYYY-MM-DD>-<slug>.md`, slug chữ thường không dấu, số, gạch nối.

**`decisions/` tới tay người sửa:** frontmatter `applyTo: "<glob>,<glob>"` làm plugin nhắc quyết định đó khi ai sửa file
khớp glob, khi `status` là `live` (hay `active` cũ, cùng nghĩa). Không khai `applyTo` thì không được nhắc.

**Lifecycle (frontmatter of any document):** `status: live | superseded | done | draft` (absent means `live`), and
`supersedes:` / `superseded_by:` (repo-relative paths; the two documents name each other). `draft`: not yet agreed or
approved. `live`: an open intent, a spec or decision in force, a plan being executed. `done`: an intent whose PR merged, a
plan whose tasks all merged, a one-off spec (port, rename, migration) that no longer describes the system, a one-time
decision fully carried out. `superseded`: replaced as a whole by `superseded_by`; a partial amendment is not supersession.
Check: `kb.py check [--strict]`.

**Finding things without reading them:** `kb.py find <words>` (superseded/done hidden unless `--all`), `kb.py list
[--type T] [--status S]`, `kb.py outline <file>` (line range and size of each section, to read one with offset/limit).

**Story** (intent loại story, viết bằng ngôn ngữ repo đặt): dòng "Là / tôi muốn / để", bối cảnh, AC đánh số (mỗi AC "khi … thì
…"), phần không làm, khẩu phần, phần **Lời người hỏi → AC** (đúng bảng khuôn viết: mỗi hàng một lời trích nguyên văn | các AC
nó đòi, AC1, AC2 hay AC1–AC3; mọi AC có mặt ở ít nhất một hàng), tối đa 3 câu hỏi; vừa một màn hình điện thoại, không lệnh,
tên tệp hay code. Mỗi câu hỏi có bốn phần có nhãn, mỗi nhãn mở một dòng: **Vì sao có câu hỏi này** (kèm một ví dụ),
**Mỗi phương án nghĩa là gì**, **Tác động**, **Đề xuất** (kèm lý do). Kiểm: `kb.py check intent <ngày>-<slug>`: thiếu phần, phần rỗng,
phần lời → AC không phải bảng ấy, lời không trỏ AC, AC không có hay AC không nằm hàng nào thì đỏ với story mới hoặc đổi thân;
story đã có trên merge base, thân không đổi, chỉ bị cảnh báo. Mã ngắn không giải thích trong ngoặc ngay sau nó (D24 (…)) và
AC không viết "khi … thì" chỉ bị cảnh báo.

**Khuôn spec của một intent:** năm mục `## `, thứ tự tuỳ ý — `## {goal}` (mỗi mục trỏ về AC, `→ AC<n>`), `## {constraints}`
(bảo mật, chi phí, tương thích; không phải cách làm), `## {criteria}` (theo hành vi, "khi … thì …", mỗi tiêu chí trỏ về AC),
`## {risks}` (rủi ro test phải phủ), `## {clarify}`. Không cách làm, không lệnh trừ khi chính lệnh là hành vi; khoảng 2 trang.
Spec dạng cũ (`## {context}`, `## {out_of_scope}`, `## Inputs and failure cases`, tiêu chí là lệnh) đã có chỉ bị cảnh báo; spec
của story mới viết hay bị sửa thì theo dạng mới. Kiểm hình dạng: `kb.py check spec <ngày>-<slug>`.

**Khuôn `current-state.md`:** chỉ trạng thái hiện hành, viết đè không nối thêm; không lịch sử (ngày đo, số PR, "trước
đây…"), không cách làm hay số liệu thí nghiệm — chi tiết nằm ở `specs/` và `decisions/`, file này chỉ trỏ tới. Có trần
kích thước. Kiểm: `kb.py check current-state`.
""", "en": """# `kb/` of this repo

Where the repo keeps its memory: requests, designs, decisions and the current state, so that people and later Claude Code
sessions do not have to guess. Set up by the `init-kb` skill of the `vibemaestro-sdlc` plugin; this file stands on its own, edit
it freely.

| Directory / file | Content | Kept up to date? |
|---|---|---|
| `intent/` | the original request in the words of the person who made it, 1-2 paragraphs; for a story: the story the owner approves | no: a one-time record |
| `specs/` | what must be true, derived from the story: goal, constraints, criteria, risks; the spec of an intent follows the shape below | yes, when the code teaches something (a living spec) |
| `plans/` | the how: one row per PR, the AC it delivers, what it depends on, what needs a signature; a living plan | yes, when the code teaches something |
| `decisions/` | one choice made, **with the options turned down** | no, but say so when one is replaced |
| `current-state.md` | the current state of the repo | **yes: the ONLY file that must always be true** |

**File names** in `intent/`, `specs/`, `plans/`, `decisions/`: `<YYYY-MM-DD>-<slug>.md`, the slug in lower case without accents,
digits and hyphens.

**`decisions/` reach the person editing:** a frontmatter `applyTo: "<glob>,<glob>"` makes the plugin remind of that decision
when someone edits a matching file, while its `status` is `live` (or the older `active`, same meaning). Without `applyTo` there
is no reminder.

**Lifecycle (frontmatter of any document):** `status: live | superseded | done | draft` (absent means `live`), and
`supersedes:` / `superseded_by:` (repo-relative paths; the two documents name each other). `draft`: not yet agreed or
approved. `live`: an open intent, a spec or decision in force, a plan being executed. `done`: an intent whose PR merged, a
plan whose tasks all merged, a one-off spec (port, rename, migration) that no longer describes the system, a one-time
decision fully carried out. `superseded`: replaced as a whole by `superseded_by`; a partial amendment is not supersession.
Check: `kb.py check [--strict]`.

**Finding things without reading them:** `kb.py find <words>` (superseded/done hidden unless `--all`), `kb.py list
[--type T] [--status S]`, `kb.py outline <file>` (line range and size of each section, to read one with offset/limit).

**Story** (an intent of type story, in the repository's language): the As / I want / so that line, context, numbered AC (each
"when … then …"), out of scope, appetite, a **Words of the person who asked → AC** part (the table the template writes: each row
one quote, as given | the AC it asks for, AC1, AC2 or AC1–AC3; every AC is in a row), at most 3 questions; it fits a phone
screen, with no command, file name or code. Each question has four labelled parts, each label opening a line:
**Why this question** (with one example), **What each option means**, **Impact**, **Recommendation** (with its reason). Check:
`kb.py check intent <date>-<slug>`: a missing or empty part, a words → AC part that is not that table, a quote with no AC, an
AC the story lacks or an AC in no row is red for a story new or with its body changed; a story on the merge base with its body
unchanged only warns. A short code word not explained in parentheses right after it (D24 (…)) and an AC not written as "when
… then" only warn.

**Shape of the spec of an intent:** five `## ` sections in any order: `## {goal}` (each pointing to an AC, `→ AC<n>`),
`## {constraints}` (security, cost, compatibility; not how it is built), `## {criteria}` (behaviour-level, "when … then …",
each pointing to an AC), `## {risks}` (the risks the tests cover), `## {clarify}`. No implementation, no command unless the
command is the behaviour; about two pages. An older spec of the earlier shape (`## {context}`, `## {out_of_scope}`,
`## Inputs and failure cases`, criteria as commands) only warns; a story's spec new or changed takes the new shape. Shape check:
`kb.py check spec <date>-<slug>`.

**Shape of `current-state.md`:** only the current state, overwritten, never appended to; no history (dates of measurements, PR
numbers, "used to…"), no how-to or experiment figures: details live in `specs/` and `decisions/`, this file only points to them.
It has a size limit. Check: `kb.py check current-state`.
"""}

MAP_HEAD = ("Area", "Component", "Status", "Description", "Check")         # the header of the skeleton's table when it has five columns


def skeleton_table(cols):
    """A table of `cols` columns with one placeholder row: the skeleton of a current-state whose profile requires a table."""
    head = list(MAP_HEAD) if cols == len(MAP_HEAD) else ["Column %d" % (i + 1) for i in range(cols)]
    return "\n## Components\n\n| %s |\n|%s\n| (none yet) |%s\n" % (" | ".join(head), "---|" * cols, " |" * (cols - 1))


CURRENT_STATE = {"vi": """# Hiện trạng — repo này

Chỉ ghi trạng thái hiện hành, viết đè khi repo đổi. Không lịch sử, không cách làm: chi tiết ở `kb/specs/` và `kb/decisions/`.

## Đang chạy

(chưa ghi — mỗi dòng một khẳng định đúng ngay bây giờ: "X chạy ở Y", "Z do W đảm nhận")

## Chưa có / đang tắt

(chưa ghi)
""", "en": """# Current state of this repo

Only the current state, overwritten when the repo changes. No history, no how-to: details are in `kb/specs/` and `kb/decisions/`.

## Running

(none yet: one line per claim that is true right now: "X runs on Y", "Z is handled by W")

## Missing / switched off

(none yet)
"""}

# `{fill}` is `tokens.spec.placeholder`; the section names of the spec template are the other `tokens.spec` keys
TEMPLATES = {"vi": {
    "intent": """---
description: "{fill}: một dòng — hiện trong issue theo dõi>"
---

# {fill}: tiêu đề>

*Ghi lại bằng lời người đặt — {date}.*

{fill}: yêu cầu gốc bằng lời của người đặt, 1-2 đoạn. Không phải thiết kế, không phải kế hoạch.>
""",
    "plan": """---
description: "{fill}: một dòng — plan này giao gì>"
issue: {fill}: số issue của chủ đề, hoặc bỏ dòng>
focus: {fill}: P<n>, trọng tâm của chủ đề>
---

# Plan — {fill}: chủ đề>

Intent: {fill}: kb/intent/… của chủ đề, hoặc bỏ> · Spec: {fill}: kb/specs/…, hoặc bỏ> · Issue: #{fill}: số>

Plan giữ cách làm: hướng đi và các PR, mỗi PR một hàng. Plan sống: khi code dạy điều mới, sửa plan và spec trong cùng PR; đổi
một AC của story thì hỏi chủ repo. Phiên nhận một hàng ghi `plan: <file này>#<hàng>` vào frontmatter intent của nó;
`kb.py plan status <file này>` đọc trạng thái từ GitHub. PR bị bỏ → `dropped: <lý do>` ở ô Link. Hàng release thêm cột Version.

## Hướng đi

{fill}: hướng đi, thứ tự các hàng và vì sao>

## Rows

| Row | How | Delivers | Depends on | Trust touches | Link |
|---|---|---|---|---|---|
| A | {fill}: cách làm của PR này, chạm vào đâu> | AC{fill}: số> (tiêu chí {fill}: số>) | — | {fill}: none, hoặc `<kind> [<owner/repo>:]<path> [<object>] [Stops: <words>]`, nối bằng ;> | — |

## Decisions

- {fill}: YYYY-MM-DD HH:MM> — "{fill}: lời của chủ repo, nguyên văn>" — [{fill}: nơi nói>]({fill}: link>)
""",
    "spec": """---
description: "{fill}: một dòng — spec này làm gì>"
---

# {fill}: tên spec>

Intent: {intent}

## {goal}

1. {fill}: điều phải đúng khi xong, nói bằng kết quả người thấy được> → AC{fill}: số>

## {constraints}

- {fill}: ràng buộc cứng: bảo mật, chi phí, tương thích; không phải cách làm>

## {criteria}

1. Khi {fill}: tình huống>, thì {fill}: hành vi thấy được>. → AC{fill}: số>

## {risks}

1. {fill}: rủi ro test phải phủ: đầu vào xấu, lạ, rỗng, quá cỡ, đồng thời, hỏng giữa chừng>

## {clarify}

{fill}: điểm cần làm rõ, mỗi điểm kèm đề xuất và lý do; không có thì ghi "không có">
""",
}, "en": {
    "intent": """---
description: "{fill}: one line, shown in the tracking issue>"
---

# {fill}: title>

*Recorded in the words of the person who gave the work — {date}.*

{fill}: the original request in the words of the person who made it, 1-2 paragraphs. Not a design, not a plan.>
""",
    "plan": """---
description: "{fill}: one line, what this plan delivers>"
issue: {fill}: the topic's issue number, or drop the line>
focus: {fill}: P<n>, the topic's focus>
---

# Plan — {fill}: topic>

Intent: {fill}: kb/intent/… of the topic, or drop it> · Spec: {fill}: kb/specs/…, or drop it> · Issue: #{fill}: number>

The plan holds the how: the approach and the PRs, one row per PR. It is living: when the code teaches something, update the plan
and the spec in the same PR; changing an AC of the story needs the owner's word. The session that takes a row writes
`plan: <this file>#<row>` into its intent's frontmatter; `kb.py plan status <this file>` reads the state from GitHub. A dropped
PR → `dropped: <reason>` in its Link cell. A release row adds a Version column.

## Approach

{fill}: the approach, the order of the rows and why>

## Rows

| Row | How | Delivers | Depends on | Trust touches | Link |
|---|---|---|---|---|---|
| A | {fill}: how this PR does it, what it touches> | AC{fill}: n> (criteria {fill}: n>) | — | {fill}: none, or `<kind> [<owner/repo>:]<path> [<object>] [Stops: <words>]`, `;` between them> | — |

## Decisions

- {fill}: YYYY-MM-DD HH:MM> — "{fill}: the owner's words, verbatim>" — [{fill}: where>]({fill}: link>)
""",
    "spec": """---
description: "{fill}: one line, what this spec does>"
---

# {fill}: spec name>

Intent: {intent}

## {goal}

1. {fill}: what must be true when done, said as a result a person can see> → AC{fill}: n>

## {constraints}

- {fill}: a hard constraint: security, cost, compatibility; not how it is built>

## {criteria}

1. When {fill}: the situation>, then {fill}: the behaviour a person sees>. → AC{fill}: n>

## {risks}

1. {fill}: a risk the tests must cover: a hostile, odd, empty, oversized, concurrent or half-failing input>

## {clarify}

{fill}: an open point, each with a recommendation and why; with none, write "none">
""",
}}
INTENT_BLANK = {"vi": "{fill}: đường dẫn kb/intent/…>", "en": "{fill}: path kb/intent/…>"}

# The real-run record (`kb.py new real-run`, kb/records/<date>-<slug>-real-run.md): the same labels in every language, as CARDS are.
# One `## Run <n>` section per command run; `real_run_problems` judges the fields.
REAL_RUN_BODY = """---
description: "{fill}: one line, what was run for this story>"
story: {intent}
ac: {fill}: the AC ids this run shows, AC<n>, AC<m>>
---

# Real run — {fill}: story>

## Run 1

Command: `{fill}: the command as typed>`
UTC: {fill}: YYYY-MM-DDTHH:MM:SSZ>
Run log id: {fill}: the id the run printed>

```text
{fill}: the output excerpt>
```
"""
for _lang in TEMPLATES:
    TEMPLATES[_lang]["real-run"] = REAL_RUN_BODY

# The card an intent of each type carries (`kb.py new intent --type`): a task's and a bug's headings are the same in every language,
# as INPUTS is; a story's labels are the repository's language (story_problems_v2 reads both). CARDS names the first story card.
CARDS = {"story": ("Story", "Acceptance criteria", "Not doing", "Measure"), "task": ("What", "Why", "Check"),
         "bug": ("Reproduce", "Expected", "Test")}
CARD_BODY = {
    "story": {"vi": """
**Là** {fill}: ai>, **tôi muốn** {fill}: điều muốn có>, **để** {fill}: vì sao>.

**Bối cảnh.** {fill}: chuyện đã xảy ra, con số đo được>

**Tiêu chí chấp nhận (AC)**
1. Khi {fill}: tình huống>, thì {fill}: điều người hỏi thấy được; không lệnh, tên tệp hay code>

**Không làm**
- {fill}: điều không làm, hoặc "không có">

**Khẩu phần.** {fill}: cỡ việc: ngày, số PR>

**Lời người hỏi → AC**

| Lời người hỏi | AC |
|---|---|
| "{fill}: lời người hỏi, trích nguyên văn>" | AC{fill}: số> |

**Câu hỏi**
1. {fill}: câu hỏi, tối đa 3; bỏ phần này khi không còn câu nào>
   - **Vì sao có câu hỏi này:** {fill}: tình huống buộc phải chọn, kèm một ví dụ>
   - **Mỗi phương án nghĩa là gì:** {fill}: (a) …, (b) …, theo việc hằng ngày của người hỏi>
   - **Tác động:** {fill}: mỗi phương án tốt hơn, tệ hơn ở đâu; điều gì khó quay lại>
   - **Đề xuất:** {fill}: phương án>. Lý do: {fill}: vì sao>.
""", "en": """
**As** {fill}: who>, **I want** {fill}: what>, **so that** {fill}: why>.

**Context.** {fill}: what happened, what was measured>

**Acceptance criteria**
1. When {fill}: the situation>, then {fill}: what the person who asked sees; no command, file name or code>

**Out of scope**
- {fill}: what is not done, or "none">

**Appetite.** {fill}: the size: days, PRs>

**Words of the person who asked → AC**

| Words of the person who asked | AC |
|---|---|
| "{fill}: their words, quoted as given>" | AC{fill}: number> |

**Questions**
1. {fill}: a question, 3 at most; drop this part when none is left>
   - **Why this question:** {fill}: the situation that forces the choice, with one example>
   - **What each option means:** {fill}: (a) …, (b) …, in the day-to-day of the person who asked>
   - **Impact:** {fill}: what each option makes better or worse; what is hard to undo>
   - **Recommendation:** {fill}: an option>. Because: {fill}: why>.
"""},
    "task": "\n## What\n\n{fill}: what is done>\n\n## Why\n\n{fill}: why now>\n\n## Check\n\n{fill}: the command that proves it>\n",
    "bug": "\n## Reproduce\n\n{fill}: the steps and what happens>\n\n## Expected\n\n{fill}: what should happen>\n\n"
           "## Test\n\n{fill}: the test that is red before the fix>\n",
}
FOCUS_RX = re.compile(r"^P[1-9][0-9]*$")
KEY_RX = re.compile(r"^[A-Z]{3}-[1-9][0-9]*$")                 # an intent's `key:`: `<issue.code>-<issue number>`
JIRA_RX = re.compile(r"^[A-Z][A-Z0-9_]+-[1-9][0-9]*$")         # an intent's `jira:`: a Jira issue key
# A quote: a "…" or “…” span of three characters or more, or a gate-page answer `(page decision <id> (<option>))`. The machine
# cannot tell who said it: the gate-2 page shows each one beside its line, and the owner reads it.
CARD_QUOTE_RX = re.compile(r'"[^"]{3,}"|“[^”]{3,}”|\(page decision [A-Za-z0-9_.-]+ \([A-Za-z0-9]+\)\)')
NOT_DOING_NONE = (["none"], ["không có"])          # a Not doing section that says there is nothing, in either language
AC_ID_RX = re.compile(r"^ {0,3}(?:\d+[.)]|[-*+])\s+(?:\*\*)?AC([0-9]+)\b")      # the id that opens the item, not one it mentions


def has_quote(item):
    """A quote outside code (a code span or a fenced block is not the owner's words) with three letters or digits in it."""
    plain, fenced = [], False
    for ln in item.split("\n"):
        if FENCE_RX.match(ln):
            fenced = not fenced
        elif not fenced:
            plain.append(CODE_RX.sub("", ln))
    return any(len(re.findall(r"\w", m.group(0))) >= 3 for m in CARD_QUOTE_RX.finditer("\n".join(plain)))


def card_items(body):
    """The list items of a card section, as criteria() reads them, except that a line after a blank line that is not indented ends
    the item (a closing paragraph is not part of the last item), and an item indented at least to the text of the one above it
    is part of it, as Markdown nests it. A section with text and no item is one item: its prose."""
    items, blank = [], False
    for it in criteria(body):
        keep = []
        for ln in it.split("\n"):
            if blank and ln.strip() and not ln[:1].isspace():
                break
            keep.append(ln)
            blank = not ln.strip()
        above = ITEM_RX.match(items[-1]) if items else None   # columns with tabs to the next stop of 4, as Markdown counts them
        if above and len(it.expandtabs(4)) - len(it.expandtabs(4).lstrip(" ")) >= len(above.group(0).expandtabs(4)):
            items[-1] += "\n" + "\n".join(keep)
        else:
            items.append("\n".join(keep))
        blank = False
    if not items and "".join(body).strip():
        items = ["\n".join(body)]
    return items


SPEC_REQUIRED = ("context", "goal", "out_of_scope", "criteria")   # keys of `tokens.spec`, in the order the sections must come
H2_RX = re.compile(r"^## +(.*?)(?:\s+#+)?\s*$")     # the optional closing hashes are not part of the name (as GitHub reads it)
FENCE_RX = re.compile(r"^\s*(```|~~~)")
ITEM_RX = re.compile(r"^ {0,3}(?:\d+[.)]|[-*+])\s+")
CODE_RX = re.compile(r"`[^`\n]+`")
# The section every new spec carries between the out-of-scope section and the criteria: one exact heading in every language (an
# outside playbook writes it), not a `tokens.spec` key. Its body is a table of three columns, or one `none, because` line with a reason.
INPUTS = "Inputs and failure cases"
INPUTS_NONE_RX = re.compile(r"^(?:none\s*,?\s*because|không có\s*,?\s*vì)\b\s*(.*)$", re.IGNORECASE)
INPUTS_FROM = "2026-11-02"      # with no git base to read, a spec whose file name is dated on or after this needs the section
SEP_CELL_RX = re.compile(r"^:?-+:?$")
LINE_WRAP_RX = re.compile(r"^(?: {0,3}(?:\d+[.)]|[-*+])\s+)?(?P<mark>`+|\*{1,2}|_{1,2})?(?P<body>.*?)(?P=mark)?$")
SPEC_DATE_RX = re.compile(r"^(\d{4}-\d{2}-\d{2})-")


def placeholder_marks(sp):
    """The placeholder of `sp` first, then that of every language preset: a spec written before the repo changed language still
    has the other language's blanks."""
    marks = [sp["placeholder"]]
    for lang in C.LANGUAGES:
        m = C.effective({"language": lang})["tokens"]["spec"]["placeholder"]
        if m not in marks:
            marks.append(m)
    return marks


def lang_of(cfg):
    """(language, `tokens.spec`) of an effective config: the language picks the prose of the scaffold, the tokens its names."""
    return cfg["language"], cfg["tokens"]["spec"]


def fill(text, sp, **kw):
    """`text` with `{fill}` (the placeholder mark) and the section names of `tokens.spec` filled in, plus `kw`."""
    return text.format(fill=sp["placeholder"], **dict(sp, **kw))


def die(msg, rc):
    sys.stderr.write("kb: %s\n" % msg)
    return rc


LANG = "vi"     # the language of the messages: `main` sets it from the repo it runs in


def M(key, *args):
    """A message of messages.py in the repo's language."""
    return messages.text(key, LANG, *args)


def repo_root():
    top = vsdlc.git_out(os.getcwd(), "rev-parse", "--show-toplevel")
    return os.path.realpath(top) if top else None


def write_new(path, text):
    """Ghi file nếu CHƯA có; trả True nếu đã ghi. `x` = lỗi nếu tồn tại (không đè kể cả khi race)."""
    try:
        with open(path, "x", encoding="utf-8") as f:
            f.write(text)
    except FileExistsError:
        return False
    return True


def kb_plan(root, state_rel, template, table_cols=None, cfg=None):
    """[(rel path, text | None)] of what `init` writes for `kb/`: a `.gitkeep` per empty directory, the README and the current-state
    skeleton (at `current_state.path`; with a table of `table_cols` columns when the profile requires one), in the language of `cfg`
    (the effective config the scaffold is for; default: the plugin defaults). None = a directory that already holds files: kept as it is."""
    lang, sp = lang_of(cfg or C.defaults())
    plan = []
    for d in DIRS:
        p = os.path.join(root, "kb", d)
        plan.append(("kb/%s/.gitkeep" % d, "") if not os.path.isdir(p) or not os.listdir(p) else ("kb/%s/" % d, None))
    plan.append(("kb/README.md", fill(README[lang], sp)))
    plan.append((state_rel, CURRENT_STATE[lang] + (skeleton_table(table_cols) if table_cols else "")))
    return plan


def cmd_init(root, args):
    """`init` (see init_setup.py): the `kb/` scaffold, `.vibemaestro/sdlc.json`, the rules scaffold; `--adopt` for a repo that has process files."""
    return init_setup.run(root, args, kb_plan, cmd_config_check, config_notices)


def cmd_new(root, kind, slug, date, cfg=None, itype=None, focus=None, jira=None):
    if kind not in KINDS:
        return die(M("kb.kind", kind, ", ".join(sorted(KINDS))), 64)
    if (itype or focus or jira is not None) and kind != "intent":
        return die("--type, --focus and --jira are for `kb.py new intent`", 64)
    if jira is not None and not JIRA_RX.match(jira):
        return die("--jira must be a Jira issue key like ABC-12", 64)
    if itype is not None and itype not in CARDS:
        return die("--type must be story, task or bug", 64)
    if focus is not None and not FOCUS_RX.match(focus):
        return die("--focus must be a focus id like P1", 64)
    if focus and not itype:
        return die("--focus goes with --type story|task|bug", 64)
    if not SLUG_RX.match(slug or ""):
        return die(M("kb.slug", slug), 64)
    sub = os.path.join(root, "kb", KINDS[kind])
    if kind == "real-run":
        os.makedirs(sub, exist_ok=True)                  # `init` does not scaffold kb/records/
    if not os.path.isdir(sub):
        return die(M("kb.no_dir", KINDS[kind]), 2)
    name = "%s-%s%s.md" % (date, slug, "-real-run" if kind == "real-run" else "")
    path = os.path.join(sub, name)
    intent_rel = "kb/intent/%s-%s.md" % (date, slug)
    # spec trỏ về intent cùng <ngày>-<slug> nếu file đó đã có; chưa có thì để dấu placeholder (không bịa đường dẫn)
    lang, sp = lang_of(cfg or C.defaults())
    intent = intent_rel if os.path.isfile(os.path.join(root, intent_rel)) else fill(INTENT_BLANK[lang], sp)
    text = fill(TEMPLATES[lang][kind], sp, date=date, intent=intent)
    if itype:
        f = focus or fill("{fill}: P<n>>", sp)
        text = text.replace("\n---\n", "\ntype: %s\nfocus: %s\n---\n" % (itype, f), 1)     # the frontmatter's closing line
        card = CARD_BODY[itype]
        if itype == "story":                # the story is the request: its card replaces the request's paragraph
            text, card = text.rstrip("\n").rsplit("\n\n", 1)[0] + "\n", card[lang]
        text += "\nType: %s · Focus: %s\n" % (itype, f) + fill(card, sp)
    if jira:
        text = text.replace("\n---\n", "\njira: %s\n---\n" % jira, 1)
    if not write_new(path, text):
        return die("%s already exists: not overwritten" % os.path.relpath(path, root), 6)
    if kind == "real-run":
        sys.stdout.write("created %s\nfill every `%s: …>` of each run, then check it: kb.py check\n" % (os.path.relpath(path, root), sp["placeholder"]))
    elif kind == "spec":
        sys.stdout.write("created %s\nfill every `%s: …>`, then check the shape: kb.py check spec %s-%s\n"
                         % (os.path.relpath(path, root), sp["placeholder"], date, slug))
        if intent == intent_rel:
            sys.stdout.write("link it back: add `spec: kb/%s/%s` to the frontmatter of %s (kb.py check links)\n"
                             % (KINDS[kind], name, intent_rel))
    else:
        sys.stdout.write("created %s\nslug for intent-branch.sh: %s-%s\n" % (os.path.relpath(path, root), date, slug))
    return 0


def _front_len(lines):
    """Số dòng của frontmatter ở đầu file (0 nếu không có)."""
    if lines and lines[0].strip() == "---":
        for i in range(1, len(lines)):
            if lines[i].strip() == "---":
                return i + 1
    return 0


def spec_sections(text):
    """[(tên mục `## `, [dòng thân])] theo thứ tự; dòng trong khối rào ``` không tính là tiêu đề."""
    lines = text.splitlines()
    out, fenced = [], False
    for ln in lines[_front_len(lines):]:
        if FENCE_RX.match(ln):
            fenced = not fenced
        m = None if fenced else H2_RX.match(ln)
        if m:
            out.append((m.group(1), []))
        elif out:
            out[-1][1].append(ln)
    return out


def criteria(body):
    """Mỗi tiêu chí = một mục danh sách ở đầu dòng, kèm các dòng nối tiếp tới mục sau (trả list chuỗi)."""
    items, fenced = [], False
    for ln in body:
        if FENCE_RX.match(ln):
            fenced = not fenced
        if not fenced and ITEM_RX.match(ln):
            items.append(ln)
        elif items:
            items[-1] += "\n" + ln
    return items


def has_command(item):
    return bool(CODE_RX.search(item)) or "```" in item


def table_cells(line):
    """The cells of a table row as GitHub renders it: split on every `|` that is not escaped (`\\|`), inside a code span too,
    the outer pipes dropped."""
    cells = [c.replace("\\|", "|").strip() for c in re.split(r"(?<!\\)\|", line.strip())]
    return cells[1 if line.strip().startswith("|") else 0:len(cells) - 1 if re.search(r"(?<!\\)\|$", line.strip()) else None]


def _plain_line(ln):
    """A line of the section as a reader means it: NFC, without a list marker in front and without one wrapping code span or
    emphasis (`` `none, because …` `` and `- none, because …` are the line `none, because …`)."""
    m = LINE_WRAP_RX.match(unicodedata.normalize("NFC", ln.strip()))
    return m.group("body").strip() if m else ln.strip()


def _is_row(ln):
    """A table row as GitHub reads one: a line with a `|` that is not escaped (the outer pipes are optional)."""
    return bool(re.search(r"(?<!\\)\|", ln))


def _is_sep(ln):
    cells = table_cells(ln)
    return _is_row(ln) and bool(cells) and all(SEP_CELL_RX.match(c) for c in cells)


def _header_at(lines, i):
    """`lines[i]` is a delimiter row with a header line right above it (a `|` line, not itself a delimiter, not indented 4+)."""
    h = lines[i - 1] if i > 0 else ""
    return _is_sep(lines[i]) and _is_row(h) and not _is_sep(h) and not h.startswith(("    ", "\t"))


def inputs_problems(body):
    """Why the body of `## Inputs and failure cases` is not ONE table of three filled columns or one `none, because <reason>`
    line. The table is read without rendering: the header line, the delimiter row under it, then the consecutive lines that
    hold a `|`, up to a blank line or a line without one. Lines around the table are not judged (spec skill: what passes)."""
    lines, fenced = [], False
    for ln in body:                     # a fence line and a fenced line stay as a blank line: they end a table, never glue one
        if FENCE_RX.match(ln):
            fenced = not fenced
            lines.append("")
        else:
            lines.append("" if fenced else ln.rstrip())
    if not "".join(body).strip():
        return ["section `## %s` is empty: a table of input or failure / expected behaviour / test, or one line "
                "`none, because <reason>`" % INPUTS]
    seps = [i for i in range(len(lines)) if _header_at(lines, i)]
    if not seps:
        nones = [m for m in (INPUTS_NONE_RX.match(_plain_line(ln)) for ln in lines if ln.strip()) if m]
        if nones:
            if not re.search(r"\w", nones[0].group(1)):
                return ["section `## %s` says none with no reason: write `none, because <reason>`" % INPUTS]
            return []
        return ["section `## %s` has no table (a header row, a `|---|` row, then one row per input) and no `none, because` line"
                % INPUTS]
    def run_end(d):                     # the index after the last row of the table whose delimiter is at `d`
        e = d + 1
        while e < len(lines) and lines[e].strip() and _is_row(lines[e]):
            e += 1
        return e
    starts, end = [], -1
    for i in seps:                      # a table is a run; a header+delimiter pair inside an earlier run is rows of it
        if i > end:
            starts.append(i)
            end = run_end(i)
    if len(starts) > 1:
        return ["section `## %s` holds %d tables: keep one, with one row per input or failure" % (INPUTS, len(starts))]
    d = starts[0]
    rows = lines[d + 1:run_end(d)]
    out = []
    for what, ln in (("header", lines[d - 1]), ("delimiter row", lines[d])):
        n = len(table_cells(ln))
        if n != 3:
            out.append("section `## %s`: the table's %s has %d column(s), it needs 3 (input or failure | expected behaviour | test)"
                       % (INPUTS, what, n))
    if not rows:
        out.append("section `## %s` has a header but no row: one row per input or failure, or one line `none, because <reason>`"
                   % INPUTS)
    for i, r in enumerate(rows, 1):
        cells = table_cells(r)
        if len(cells) != 3 or not all(cells):
            out.append("section `## %s`, row %d: needs three filled cells (input or failure | expected behaviour | test), has %d "
                       "filled of %d (a `|` inside a cell, code included, is written `\\|`)"
                       % (INPUTS, i, sum(1 for x in cells if x), len(cells)))
    return out


def new_in_change(path):
    """(True | False | None, why): the file is absent from the merge base `kb.py check links` judges by (kb_plan.merge_base);
    None when there is no git or no base."""
    d = os.path.dirname(os.path.abspath(path))
    top = vsdlc.git_out(d, "rev-parse", "--show-toplevel")
    if top:
        mb, ref = plans.merge_base(top)
        if mb:
            rel = _repo_rel(path, top)
            listed = vsdlc.git_out(top, "ls-tree", "--name-only", mb, "--", rel)
            if listed is not None:
                return (not listed), "%s %s on the merge base of %s (%s)" % (rel, "is not" if not listed else "is", ref, mb[:7])
    return None, "no git base to read"


def spec_is_new(path):
    """(True | False | None, why): the spec is new in this change (new_in_change); with no git or no base, its file-name date
    against INPUTS_FROM; None when neither can say."""
    new, why = new_in_change(path)
    if new is not None:
        return new, why
    m = SPEC_DATE_RX.match(os.path.basename(path))
    if m:
        return m.group(1) >= INPUTS_FROM, "no git base to read; the file name is dated %s (the section is required from %s)" % (
            m.group(1), INPUTS_FROM)
    return None, "no git base to read and no date in the file name"


def spec_problems(text, sp=None, warn=None):
    """Danh sách lý do spec chưa đạt khuôn; rỗng = đạt HÌNH DẠNG (không kiểm nội dung đúng). `sp` = `tokens.spec` (tên mục,
    tiêu đề bằng chứng, dấu placeholder); mặc định của plugin khi không truyền. With a list `warn`, the problems of
    `## Inputs and failure cases` (missing, empty, malformed, misplaced) go there instead: a spec that already existed only warns."""
    sp = sp or C.defaults()["tokens"]["spec"]
    req, opt, crit, evidence = [sp[k] for k in SPEC_REQUIRED], sp["design"], sp["criteria"], sp["evidence"]
    secs = spec_sections(text)
    names = [n for n, _ in secs]
    out, inp = [], (warn if warn is not None else [])
    for n in req:
        if n not in names:
            out.append("section `## %s` is missing" % n)
        elif names.count(n) > 1:
            out.append("section `## %s` appears %d times" % (n, names.count(n)))
    near = [n for n in names if n != INPUTS and " ".join(n.rstrip(":. ").split()).casefold() == INPUTS.casefold()]
    for n in near:
        inp.append("section `## %s` must be written exactly `## %s` (one heading in every language)" % (n, INPUTS))
    if INPUTS not in names and not near:
        inp.append("section `## %s` is missing: a table of input or failure / expected behaviour / test between `## %s` and "
                   "`## %s`, or one line `none, because <reason>`" % (INPUTS, sp["out_of_scope"], crit))
    elif names.count(INPUTS) > 1:
        inp.append("section `## %s` appears %d times" % (INPUTS, names.count(INPUTS)))
    for n in names:
        if n not in req and n != opt and n != INPUTS and n not in near:
            out.append("unknown section `## %s`: only the five sections and `## %s` are accepted; a minor point goes in as `###` inside `## %s`"
                       % (n, opt, opt))
    known = [n for n in names if n in req or n == opt]
    want = [n for n in req if n in names] + ([opt] if opt in names else [])
    if not out and known != want:
        out.append("sections out of order: found `%s`, need `%s` (`## %s`, when present, comes AFTER the others)"
                   % (" > ".join(known), " > ".join(want), opt))
    if not out and names.count(INPUTS) == 1:
        i = names.index(INPUTS)
        if not (sp["out_of_scope"] in names[:i] and crit in names[i + 1:]):
            inp.append("section `## %s` is out of place: it comes after `## %s` and before `## %s`" % (INPUTS, sp["out_of_scope"], crit))
    for n, body in secs:
        if (n in req or n == opt) and not "".join(body).strip():
            out.append("section `## %s` is empty" % n)
    if names.count(INPUTS) == 1:
        inp.extend(inputs_problems(next(b for n, b in secs if n == INPUTS)))
    if warn is None:
        out.extend(inp)
    for mark in placeholder_marks(sp):
        left = text.count(mark)
        if left:
            out.append("%d `%s: …>` blank(s) still to fill" % (left, mark))
    body = next((b for n, b in secs if n == crit), None)
    if body is not None and "".join(body).strip():
        items = criteria(body)
        if not items:
            out.append("section `## %s` has no criterion: each criterion is a list item (`1. …`)" % crit)
        for i, it in enumerate(items, 1):
            if not has_command(it):
                out.append("criterion %d has no command: a criterion is a COMMAND + the expected result, the command in `…`" % i)
        if items and evidence not in items[-1]:
            out.append("the last criterion must be: the PR has a `## %s` section" % evidence)
    return out


# ── the story the owner approves (story process v2): a short story in the intent, its parts named by a bold lead or a heading ──
# story_is_v2 tells it from the first card. Its labels are words in vi or en, matched at the start of the label (`**Bối cảnh.**`,
# `**Tiêu chí chấp nhận (AC)**`, `## Questions`); a bold lead that is no label, or that opens a sentence, is text.
STORY_PARTS = (("context", ("bối cảnh", "context")), ("ac", ("tiêu chí chấp nhận", "acceptance criteria")),
               ("not_doing", ("không làm", "ngoài phạm vi", "out of scope", "not doing")), ("appetite", ("khẩu phần", "appetite")),
               ("questions", ("câu hỏi", "questions")), ("decisions", ("quyết định", "decisions")),
               ("trace", ("lời người hỏi", "words of the person who asked")))
STORY_NEEDS = (("context", "Context"), ("ac", "Acceptance criteria"), ("not_doing", "Out of scope"), ("appetite", "Appetite"))
STORY_REASON = ("lý do", "vì", "because", "why", "reason")     # the words of a recommendation's reason, vi and en
# The four labelled parts of an open question, matched at the start of a label opening a line of the question (`**Tác động:** …`,
# `- *Impact:* …`), and the words of the example its why part gives (a missing one only warns: the machine cannot read meaning).
QUESTION_PARTS = (("why", "why this question", ("vì sao", "why")),
                  ("options", "what each option means", ("mỗi phương án", "phương án", "what each option", "each option", "options")),
                  ("impact", "impact", ("tác động", "impact")), ("recommend", "recommendation", ("đề xuất", "recommend")))
QUESTION_LABEL_RX = re.compile(r"^\s*(?:(?:\d+[.)]|[-*+])\s+)?(?:\*\*(?P<b>[^*\n]+?)\*\*|\*(?P<i>[^*\n]+?)\*|_(?P<u>[^_\n]+?)_)(?P<rest>.*)$")
AC_RANGE_RX = re.compile(r"\bAC(\d+)\s*[–-]\s*AC(\d+)\b")       # AC1–AC3 or AC1-AC3: every AC from the first to the last
AC_ID = r"AC\d+(?:\s*[–-]\s*AC\d+)?"
AC_CELL_RX = re.compile(r"^%s(?:\s*,\s*%s)*$" % (AC_ID, AC_ID))        # the AC cell of a words → AC row: ids, a comma list
EXAMPLE_WORDS = ("ví dụ", "vd", "chẳng hạn", "example", "e.g", "for instance")
TRACE_NAME = {"vi": "Lời người hỏi → AC", "en": "Words of the person who asked → AC"}   # its label as messages name it
CODE_WORD_RX = re.compile(r"\b[A-Z]{1,4}[0-9]+\b")         # a short code word: letters then digits (D24, AC6, T36, X218)
STORY_LABEL_RX = re.compile(r"^ {0,3}(?:#{2,6}\s+(?P<h>.+?)\s*#*\s*$|\*\*(?P<b>[^*\n]+?)\*\*(?P<rest>.*)$)")
STORY_LINE_RX = (re.compile(r"\blà\b.*\btôi muốn\b.*\bđể\b", re.S), re.compile(r"\bas\b.*\bi want\b.*\bso that\b", re.S))
STORY_ITEM_RX = re.compile(r"^( {0,3})(?:(\d+)[.)]|[-*+])(\s+)\S")
HEADING_RX = re.compile(r"^ {0,3}#{1,6}(?:\s|$)")                 # a Markdown heading line
TITLE_RX = re.compile(r"^\s*(?:\*{1,2}|_{1,2})[^*_].*?(?:\*{1,2}|_{1,2})\s*$")   # a line that is all emphasis: a group's title
STORY_FILE_RX = re.compile(r"(?<![\w/.-])(?:[\w.-]+/)*[\w-]+\.(?:py|sh|md|json|ya?ml|js|mjs|ts|tsx|toml|txt|ini|cfg|go|rs|rb|sql)\b")
STORY_MAX_CHARS = 3500          # about one phone screen: over it the story only warns, its length is a hint, not a defect
STORY_MAX_QUESTIONS = 3


def story_part(text):
    """(lines, index of the first) of an intent's story: its whole body after the frontmatter (the story lives in the intent)."""
    lines = text.splitlines()
    first = _front_len(lines)
    return lines[first:], first


def story_is_v2(text):
    """A story intent is the story the owner approves unless it has the first card's shape. A `## Measure` section (the first
    card's own) makes it the first card unless both the story's own parts, context and appetite, are labelled outside it; a
    `## Story`, `## Acceptance criteria` or `## Not doing` section does too, unless a context or appetite part is labelled."""
    names = set(n for n, _ in spec_sections(text or ""))
    keep, measure, fenced = [], False, False
    for ln in story_part(text or "")[0]:
        if FENCE_RX.match(ln):
            fenced = not fenced
        m = None if fenced else H2_RX.match(ln)
        measure = (m.group(1) == "Measure") if m else measure
        if not measure:
            keep.append(ln)
    keys = set(story_parts(keep))
    if "Measure" in names:
        return {"context", "appetite"} <= keys
    return not names & {"Story", CARD_AC, "Not doing"} or bool(keys & {"context", "appetite"})


def story_label(line, para_start=True):
    """(part key, the text after a bold lead) when `line` is the label of a story part, else (None, None). A heading is one; a bold
    lead is one at the left margin when it is alone on its line, a run-in heading (`**Bối cảnh.** …`) or opens a paragraph
    (`para_start`: after a blank line); a bold word inside an item or a sentence (`**Không làm** gì thêm …`) is text."""
    m = STORY_LABEL_RX.match(line)
    if not m:
        return None, None
    raw = (m.group("h") or m.group("b")).strip()
    rest = m.group("rest") or ""
    if m.group("b") and (line[:1].isspace() or not (not rest.strip() or para_start or raw.endswith((".", ":"))
                                                     or rest.lstrip().startswith((".", ":")))):
        return None, None
    name = unicodedata.normalize("NFC", raw.rstrip(".:").strip()).casefold()
    key = next((k for k, words in STORY_PARTS if name.startswith(words)), None)
    return (key, rest.lstrip(" .:") if m.group("b") else "") if key else (None, None)


def story_parts(lines):
    """{part key: [(line index, line)]}: a part runs from its label to the next label; the text after a bold lead is its first line."""
    parts, cur, fenced = {}, None, False
    for i, ln in enumerate(lines):
        if FENCE_RX.match(ln):
            fenced = not fenced
        key, rest = (None, None) if fenced else story_label(ln, i == 0 or not lines[i - 1].strip() or lines[i - 1].lstrip().startswith("#"))
        if key:
            cur = key
            parts.setdefault(key, []).append((i, rest))
        elif cur:
            parts[cur].append((i, ln))
    return parts


def story_items(part):
    """[(number or None, first line index, text)] of the top-level list items of a part: an item indented to the text of the one
    above, as Markdown nests it, and a line glued under it or indented belong to that one; a line at the margin after a blank
    line (a group's title, a closing paragraph) ends it."""
    items, col, closed, blank = [], 0, False, False
    for i, ln in part:
        m = STORY_ITEM_RX.match(ln.expandtabs(4))
        if m and (not items or closed or len(m.group(1)) < col):
            items.append([m.group(2), i, ln])
            col, closed = m.end(3), False
        elif items and ln.strip() and not closed:
            if (blank and not ln[:1].isspace()) or HEADING_RX.match(ln):
                closed = True
            else:
                items[-1][2] += "\n" + ln
        blank = not ln.strip()
    return [tuple(x) for x in items]


def story_ac_list(parts):
    """[(id or None, line index)] of the AC items of a story's parts: an `**AC<n>` in the item's first line, else its number."""
    out = []
    for n, i, it in story_items(parts.get("ac", [])):
        m = AC_ID_RX.search(it.split("\n")[0])
        out.append((m.group(1) if m else n, i))
    return out


def story_ac_ids(itext):
    """The AC ids (digit strings, in order) of a story intent: the `1. **AC<n>` items of the first card's `## Acceptance
    criteria`, else the numbers the owner wrote under the story's AC label (an `**AC<n>` in an item wins over its number)."""
    if not story_is_v2(itext):
        return list(dict.fromkeys(AC_ITEM_RX.findall(_prose(dict(spec_sections(itext or "")).get(CARD_AC, [])))))
    return list(dict.fromkeys(x for x, _i in story_ac_list(story_parts(story_part(itext or "")[0])) if x))


def has_word(text, words):
    low = unicodedata.normalize("NFC", text).casefold()
    return any(re.search(r"(?<!\w)%s(?!\w)" % re.escape(x), low) for x in words)


def question_parts(item):
    """{part key: its text} of an open question: a part runs from its label, a bold or italic lead opening a line after the
    question's first and ending in `.` or `:` (`**Tác động:** …`), to the next label; any other line is text of the part above."""
    got, cur = {}, None
    for ln in item.split("\n")[1:]:
        m = QUESTION_LABEL_RX.match(ln)
        raw = (m.group("b") or m.group("i") or m.group("u")).strip() if m else ""
        if m and not (raw.endswith((".", ":")) or not m.group("rest").strip() or m.group("rest").lstrip().startswith((".", ":"))):
            m = None                                     # `**Tác động** thì …`: a bold word opening a sentence is text
        name = unicodedata.normalize("NFC", raw.rstrip(".:").strip()).casefold() if m else ""
        key = next((k for k, _n, words in QUESTION_PARTS if name.startswith(words)), None) if m else None
        if key:
            cur = key
            got[key] = got.get(key, "") + " " + m.group("rest").lstrip(" .:")
        elif cur:
            got[cur] += "\n" + ln
    return got


def trace_problems(parts, first, marks, label):
    """[problem] of the story's words → AC part: the table the template writes and nothing else (a header, its `---` line, then one
    row per quote: the quote | the AC ids as a comma list or a range AC1–AC3); each id is an AC of the story and each AC is in a
    row. A part still holding a blank is judged by the blank alone."""
    if "trace" not in parts:
        return ["the story has no `%s` part: a table, each quote of the person who asked | the AC ids it asks for" % label]
    part = [(i, ln.strip()) for i, ln in parts["trace"] if ln.strip()]
    if any(m in ln for _i, ln in part for m in marks):
        return []
    cells = [[c.strip() for c in ln.strip("|").split("|")] for _i, ln in part]
    if (len(part) < 2 or not all(ln.startswith("|") and ln.endswith("|") and len(c) == 2 for (_i, ln), c in zip(part, cells))
            or not all(SEP_CELL_RX.match(c) for c in cells[1])):
        return ["the story's `%s` part must be the table the template writes: | quote | AC |, its `---` line, one row per quote"
                % label]
    if len(part) == 2:
        return ["the story's `%s` part has no row: one per quote, | \"quote\" | AC1, AC2 |" % label]
    ids, out, seen = set(x for x, _i in story_ac_list(parts) if x), [], set()
    for (i, _ln), (quote, acs) in zip(part[2:], cells[2:]):
        if not has_quote(quote):
            out.append("line %d: a words → AC row has no quote of the person who asked (\"…\")" % (first + i + 1))
        if not acs:
            out.append("line %d: the quote %s maps to no AC" % (first + i + 1, quote))
            continue
        if not AC_CELL_RX.match(acs):
            out.append("line %d: the AC cell `%s` is not AC ids: a comma list or a range, AC1, AC2 or AC1–AC3" % (first + i + 1, acs))
            continue
        refs = ac_refs(acs)
        out += ["line %d: AC%s is not an AC of the story" % (first + i + 1, n) for n in refs if n not in ids]
        seen.update(refs)
    for n in sorted(ids - seen, key=int):
        out.append("AC%s is in no row of the words → AC part: which words of the person who asked does it answer?" % n)
    return out


def ac_refs(cell):
    """The AC ids (digit strings) of an AC cell: `AC2`, and every id of a range `AC1–AC3` (its two ends when over 100 wide)."""
    out = []
    for m in AC_RANGE_RX.finditer(cell):
        lo, hi = int(m.group(1)), int(m.group(2))
        out += [str(n) for n in (range(lo, hi + 1) if 0 <= hi - lo <= 100 else (lo, hi))]
    return out + re.findall(r"\bAC(\d+)\b", AC_RANGE_RX.sub(" ", cell))


def code_word_warnings(lines, first, acs, focus):
    """[warning] per short code word (D24, T36) the story uses and never explains: no use of it is followed directly by its
    explanation in parentheses, `D24 (…)`. The story's own AC ids and its focus are known words; a quote of the person who asked
    and a code span are not judged."""
    blank = lambda m: " " * len(m.group(0))  # noqa: E731  (blanked in place: a word keeps its column in the line)
    uses, told, fenced = {}, set(), False
    for i, ln in enumerate(lines):
        if FENCE_RX.match(ln):
            fenced = not fenced
            continue
        prose = CARD_QUOTE_RX.sub(blank, CODE_RX.sub(blank, ln))
        for m in [] if fenced else CODE_WORD_RX.finditer(prose):
            w = m.group(0)
            uses.setdefault(w, first + i + 1)
            if re.match(r" ?\(", ln[m.end():]):
                told.add(w)
    return ["line %d: %s is a short code word the story never explains: say what it is once, `%s (…)`" % (n, w, w)
            for w, n in sorted(uses.items(), key=lambda x: x[1])
            if w not in told and w != focus and not (w.startswith("AC") and w[2:] in acs)]


def story_problems_v2(text, marks=(), lang="vi"):
    """(problems, warnings, shape) of a story in the v2 shape. Red, and few: a missing part (the As / I want / so that line,
    context, AC, out of scope, appetite), an AC list with no number or a number twice, more than 3 open questions. `shape`, red for
    a story new or changed in the change and a warning on an older one: an open question missing one of its four labelled parts or
    with one empty, the words → AC part missing, a quote mapping to no AC, an AC id the story lacks, an AC in no row. Everything
    that could stop a reasonable story only warns: a why with no example, a recommendation with no reason, an AC not written as
    when … then, a short code word never explained, code, a file name or a command, the length."""
    lines, first = story_part(text)
    parts = story_parts(lines)
    focus = kb_index.front_block((text or "").splitlines())[0].get("focus", "")
    out, warns, shape = [], [], []
    paras = re.split(r"\n\s*\n", unicodedata.normalize("NFC", _prose(lines).replace("**", "")).casefold())
    if not any(rx.search(p) for p in paras for rx in STORY_LINE_RX):
        out.append("the story has no As … I want … so that … line (in vi or en)")
    for key, name in STORY_NEEDS:
        if key not in parts:
            out.append("the story has no %s part: its label in vi or en as a heading, or in bold at the left margin, alone on its "
                       "line, as `**%s.**` or opening a paragraph" % (name, name))
        elif not "".join(ln for _i, ln in parts[key]).strip():
            out.append("the story's %s part is empty" % name)
    if "ac" in parts and "".join(ln for _i, ln in parts["ac"]).strip():
        nums = [n for n, _i in story_ac_list(parts)]
        if not any(nums):
            out.append("the story's AC are not numbered: each is a list item `1. …`, its number is its id (AC1)")
        for n in sorted(set(x for x in nums if x and nums.count(x) > 1), key=int):
            out.append("AC%s appears twice: number the AC once across the groups" % n)
    qs = [it for it in story_items(parts.get("questions", [])) if it[2].strip()]
    if len(qs) > STORY_MAX_QUESTIONS:
        out.append("the story asks %d questions: at most %d (an answered one goes under the decisions)" % (len(qs), STORY_MAX_QUESTIONS))
    for k, (_n, i, it) in enumerate(qs, 1):
        got = question_parts(it)
        for key, name, _w in QUESTION_PARTS:
            if key not in got:
                shape.append("line %d: question %d has no `%s` part (a label opening its own line)" % (first + i + 1, k, name))
            elif not re.search(r"\w", got[key]):
                shape.append("line %d: question %d: its `%s` part is empty" % (first + i + 1, k, name))
        if re.search(r"\w", got.get("why", "")) and not has_word(got["why"], EXAMPLE_WORDS):
            warns.append("line %d: question %d: its why part gives no example" % (first + i + 1, k))
        if re.search(r"\w", got.get("recommend", "")) and not has_word(got["recommend"], STORY_REASON):
            warns.append("line %d: question %d: its recommendation gives no reason" % (first + i + 1, k))
    shape += trace_problems(parts, first, marks, TRACE_NAME.get(lang, TRACE_NAME["en"]))
    for (n, i), (_m, _j, it) in zip(story_ac_list(parts), story_items(parts.get("ac", []))):
        if not any(rx.search(unicodedata.normalize("NFC", _prose(it.split("\n"))).casefold()) for rx in WHEN_THEN_RX):
            warns.append("line %d: AC%s is not written as when … then" % (first + i + 1, n or "?"))
    warns += code_word_warnings(lines, first, set(story_ac_ids(text)), focus)
    fenced = False
    for i, ln in enumerate(lines):
        if FENCE_RX.match(ln):
            if not fenced:
                warns.append("line %d: a code block in the story: the owner reads no code" % (first + i + 1))
            fenced = not fenced
            continue
        if fenced:
            continue
        hits = STORY_FILE_RX.findall(ln) + ["`%s`" % c for c in re.findall(r"`([^`\n]+)`", ln) if len(c.split()) > 1]
        for h in hits:
            warns.append("line %d: %s looks like a file name or a command: the owner reads neither (a warning: the owner's own "
                         "words may name one)" % (first + i + 1, h))
    size = len("\n".join(lines).strip())
    if size > STORY_MAX_CHARS:
        warns.append("the story is %d characters, over %d (about one phone screen): cut it down" % (size, STORY_MAX_CHARS))
    return out, warns, shape


# ── the spec derived from a story (v2): five sections, behaviour-level criteria pointing to the story's AC ─────────────────
SPEC_V2 = ("goal", "constraints", "criteria", "risks", "clarify")      # keys of `tokens.spec`; any order
SPEC_V2_ONLY = ("constraints", "risks", "clarify")                      # a spec holding one of these is in the v2 shape
SPEC_V2_MAX_CHARS = 8000        # about two pages: over it the spec only warns
WHEN_THEN_RX = (re.compile(r"\bkhi\b.*\bthì\b", re.S), re.compile(r"\bwhen\b.*\bthen\b", re.S))
V2_TRACE_RX = re.compile(r"(?:→|->)\s*(AC\d+(?:\s*,\s*AC\d+)*)")


def spec_is_v2(text, sp):
    """A spec holding a section only the v2 shape has; a v2 name a repo also gave a first-shape section (config) does not count."""
    names = [n for n, _ in spec_sections(text or "")]
    first = set(sp[k] for k in SPEC_REQUIRED + ("design",))
    return any(sp[k] in names and sp[k] not in first for k in SPEC_V2_ONLY)


def spec_v2_problems(text, sp):
    """(problems, warnings) of a v2 spec's shape. Red: one of the five sections missing, twice or empty, another `## ` section,
    a blank left, no criterion. A warning: a criterion not written as when … then, a code block, a spec over two pages."""
    secs = spec_sections(text)
    names = [n for n, _ in secs]
    want = [sp[k] for k in SPEC_V2]
    out, warns = [], []
    for n in want:
        if n not in names:
            out.append("section `## %s` is missing" % n)
        elif names.count(n) > 1:
            out.append("section `## %s` appears %d times" % (n, names.count(n)))
    for n, body in secs:
        if n not in want:
            out.append("section `## %s` is not one of the five: %s" % (n, ", ".join("`## %s`" % w for w in want)))
        elif not "".join(body).strip():
            out.append("section `## %s` is empty (write `none` when there is nothing)" % n)
    for mark in placeholder_marks(sp):
        if text.count(mark):
            out.append("%d `%s: …>` blank(s) still to fill" % (text.count(mark), mark))
    body = next((b for n, b in secs if n == sp["criteria"]), [])
    items = [it for it in card_items(body) if ITEM_RX.match(it)]
    if "".join(body).strip() and not items:
        out.append("section `## %s` has no criterion: each is a list item (`1. …`)" % sp["criteria"])
    for i, it in enumerate(items, 1):
        low = unicodedata.normalize("NFC", _prose(it.split("\n"))).casefold()
        if not any(rx.search(low) for rx in WHEN_THEN_RX):
            warns.append("criterion %d is not written as when … then: a criterion says a behaviour" % i)
    lines = text.splitlines()
    if any(FENCE_RX.match(ln) for ln in lines):
        warns.append("the spec holds a code block: the spec says what, the plan says how")
    size = len("\n".join(lines[_front_len(lines):]).strip())
    if size > SPEC_V2_MAX_CHARS:
        warns.append("the spec is %d characters, over %d (about two pages): cut it down" % (size, SPEC_V2_MAX_CHARS))
    return out, warns


def base_text(path, base=None):
    """(the text of `path` at the merge base of `base` (kb_plan.merge_base) or None when it is not there, whether a base was read)."""
    top = vsdlc.git_out(os.path.dirname(os.path.abspath(path)), "rev-parse", "--show-toplevel")
    mb = plans.merge_base(top, base)[0] if top else None
    return (vsdlc.git_out(top, "show", "%s:%s" % (mb, _repo_rel(path, top))) if mb else None), mb is not None


def _body(text):
    lines = (text or "").splitlines()
    return "\n".join(ln.rstrip() for ln in lines[_front_len(lines):]).strip()


def spec_body_changed(path, text, base=None):
    """True when the spec is new in the change or its body changed (its frontmatter alone, such as `status:`, does not count);
    None when there is no base to read."""
    old, read = base_text(path, base)
    return None if not read else old is None or _body(old) != _body(text)


def plan_rows_changed(root, rel, base=None):
    """True when the plan is new in the change or a row cell other than Link changed (what the owner's plan signature binds:
    kb_plan.row_cells; a Link cell, the Decisions or the prose do not count); None when there is no base to read."""
    old, read = base_text(os.path.join(root, rel), base)
    if not read:
        return None
    now = plans.read_plan(root, rel)
    cells = lambda doc: [plans.row_cells(r) for r in doc["rows"]] if doc else []  # noqa: E731
    return old is None or cells(plans.read_plan_text(old, rel)) != cells(now)


def _fold(t):
    """The words of an AC, its list marker, heading marks, emphasis, code marks and blanks folded away: a reformatting is no change."""
    return " ".join(re.sub(r"[*_`]", "", re.sub(r"(?m)^\s*(?:\d+[.)]|[-*+]|#+)\s+", "", t)).split())


def story_acs(text):
    """({AC id: its text, folded}, the AC part without its group titles, folded) of a v2 story."""
    parts = story_parts(story_part(text)[0])
    out = {}
    for (n, _i), (_m, _j, it) in zip(story_ac_list(parts), story_items(parts.get("ac", []))):
        if n:
            out.setdefault(n, _fold(it))
    return out, _fold("\n".join(ln for _i, ln in parts.get("ac", []) if not (HEADING_RX.match(ln) or TITLE_RX.match(ln))))


def story_decisions(text):
    """The decision items of a v2 story, folded, with whether each holds the owner's quote."""
    return [(_fold(it), has_quote(it)) for _n, _i, it in story_items(story_parts(story_part(text)[0]).get("decisions", []))]


def ac_change_problem(path, text, base=None):
    """The red line when a v2 story already on the merge base changed, added or dropped an AC (or other text of its AC part) in
    this change and the decisions gained no item with the owner's quote (one more item, quoted; an old one edited is not new):
    an AC changes only by the owner's word (AC7). The machine cannot tell whose words a quote holds: the owner reads the story.
    None otherwise, and with no base to read."""
    old, _read = base_text(path, base)
    if old is None or not story_is_v2(old):
        return None
    (was, wpart), (now, npart) = story_acs(old), story_acs(text)
    moved = ["AC%s" % n for n in sorted(set(was) ^ set(now) | set(n for n in was if n in now and was[n] != now[n]), key=int)]
    if not moved and wpart != npart:
        moved = ["the AC part's text"]
    before, after = story_decisions(old), story_decisions(text)
    seen = set(t for t, _q in before)
    if not moved or (len(after) > len(before) and any(q and t not in seen for t, q in after)):
        return None
    return ("%s changed since the merge base and no new decision of the story holds the owner's quote: an AC changes only by the "
            "owner's word (add it as a decision, quoted)" % ", ".join(moved))


def ac_guard(root, rel, base=None):
    """[the AC guard's line] for an intent `check links` finds changed: a story the owner approves, already on the merge base."""
    path = os.path.join(root, rel)
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except (OSError, UnicodeDecodeError):
        return []
    if kb_index.front_block(text.split("\n"))[0].get("type") != "story" or not story_is_v2(text):
        return []
    moved = ac_change_problem(path, text, base)
    return [moved] if moved else []


def card_problems(text, sp, mode="warn", hints=None, fresh=None, lang="vi"):
    """(problems, warnings) of an intent's card: `type:` and `focus:` (judged by `intake.focus` `mode`: required is a problem, warn
    a warning, off nothing), the sections of its type, a story's As a / I want / so that, an `AC<n>` id and a quote on each AC, a
    Measure. A Not doing line with neither a quote nor a page decision id is a warning: the gate-2 page makes it a mandatory
    decision, whose answer becomes its quote (`--strict` makes it a problem). A v2 story's shape problems (story_problems_v2) go
    to `fresh` when given, else they are problems."""
    lines = text.splitlines()
    fm = kb_index.front_block(lines)[0]
    out, warns = [], []
    t, f = fm.get("type", ""), fm.get("focus", "")
    fields = []
    if t not in CARDS:
        fields.append("frontmatter `type:` must be story, task or bug%s" % (" (it is `%s`)" % t if t else ", and there is none"))
    if f and not FOCUS_RX.match(f):
        fields.append("frontmatter `focus: %s` is not a focus id like P1" % f)
    elif not f:
        fields.append("frontmatter `focus:` is missing: an open focus of the brain, like P1")
    if mode != "off":
        (out if mode == "required" else warns).extend(fields)
    for k, rx, shape in (("key", KEY_RX, "`<issue.code>-<issue number>`, like KIT-12"), ("jira", JIRA_RX, "a Jira issue key, like ABC-12")):
        if k in fm and not rx.match(fm[k]):
            out.append("frontmatter `%s: %s` is not %s" % (k, fm[k], shape))
    secs = spec_sections(text)
    body = {n: b for n, b in secs}
    names = [n for n, _ in secs]
    v2 = t == "story" and story_is_v2(text)              # the story the owner approves (v2), else the first card
    if v2:
        p, w, s = story_problems_v2(text, placeholder_marks(sp), lang)
        out = out + p + (s if fresh is None else [])
        if fresh is not None:
            fresh.extend(s)
        (hints if hints is not None else warns).extend(w)  # warnings `--strict` keeps as warnings: they never block a story
    for n in () if v2 else CARDS.get(t, ()):
        if names.count(n) > 1:
            out.append("section `## %s` appears %d times" % (n, names.count(n)))
        elif n not in body:
            out.append("section `## %s` is missing (a %s card: %s)" % (n, t, ", ".join("## " + x for x in CARDS[t])))
        elif not "".join(body[n]).strip():
            out.append("section `## %s` is empty" % n)
    if t == "story" and not v2 and "".join(body.get("Story", ())).strip():
        story = " ".join(body["Story"]).casefold()
        gone = [w for w in ("As a", "I want", "so that") if w.casefold() not in story]
        if gone:
            out.append("`## Story` needs As a / I want / so that: no %s" % ", ".join("`%s`" % w for w in gone))
    if t == "story" and not v2 and "".join(body.get("Acceptance criteria", ())).strip():
        items, seen = [it for it in card_items(body["Acceptance criteria"]) if ITEM_RX.match(it)], set()
        if not items:
            out.append("`## Acceptance criteria` has no AC: each is a list item `1. **AC1: <title>.** … (\"<quote>\")`")
        for i, it in enumerate(items, 1):
            m = AC_ID_RX.search(it.split("\n")[0])
            name = "AC%s" % m.group(1) if m else "AC item %d" % i
            if not m:
                out.append("AC item %d has no `AC<n>` id" % i)
            elif name in seen:
                out.append("%s appears twice" % name)
            seen.add(name)
            if not has_quote(it):
                out.append("%s has no quote: the owner's words in \"…\", or (page decision <id> (<option>))" % name)
    if t == "story" and not v2:
        nd = card_items(body.get("Not doing", ()))
        if [x.strip().rstrip(".").casefold() for x in nd] in NOT_DOING_NONE:
            nd = []                              # the section says there is nothing: no proposal to quote
        for i, it in enumerate(nd, 1):
            if not has_quote(it):
                warns.append("Not doing line %d has neither the owner's quote nor a page decision id: gate 2 makes it a "
                             "mandatory decision (red under --strict)" % i)
    for mark in placeholder_marks(sp):
        if text.count(mark):
            out.append("%d `%s: …>` blank(s) still to fill" % (text.count(mark), mark))
    return out, warns


def check_intent_file(path, root, cfg, strict, older):
    """rc 0 or 65 of one intent's card, its lines printed; `older` (on the merge base already): every problem only warns."""
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return die("cannot read %s" % path, 66)
    hints, shape = [], []
    probs, warns = card_problems(text, cfg["tokens"]["spec"], cfg["intake"]["focus"], hints, shape, cfg["language"])
    fm, code = kb_index.front_block(text.splitlines())[0], cfg["issue"]["code"]
    if code and fm.get("key") and KEY_RX.match(fm["key"]) and fm["key"] != "%s-%s" % (code, str(fm.get("issue") or "").strip()):
        probs.append("frontmatter `key: %s` is not `%s-<issue>` with this intent's `issue: %s` (issue.code is %s)"
                     % (fm["key"], code, fm.get("issue") or "", code))
    if strict:
        probs, warns = probs + warns, []
    if older:
        probs, warns = [], warns + probs
    is_story = fm.get("type") == "story"
    if is_story and story_is_v2(text):
        moved = ac_change_problem(path, text) if older else None   # an AC of a story already on the base
        probs += [moved] if moved else []
        if older and not spec_body_changed(path, text):            # a card on the base, unchanged, keeps passing
            hints += [w + " (a story on the merge base whose body is unchanged only warns)" for w in shape]
        else:
            probs += shape
    elif is_story and not older:
        hints.append("the first story card: a new story takes the story the owner approves (kb.py new intent --type story writes it)")
    rel = os.path.relpath(path, root)
    for w in warns:
        sys.stdout.write("WARNING %s: %s%s\n" % (rel, w, " (an intent already on the merge base only warns)" if older else ""))
    for w in hints:
        sys.stdout.write("WARNING %s: %s\n" % (rel, w))
    sys.stdout.flush()
    if probs:
        sys.stderr.write("kb: %s does not pass its card (%d problem(s)):\n%s\n" % (rel, len(probs), "\n".join("- " + p for p in probs)))
        return 65
    if kb_index.front_block(text.splitlines())[0].get("type") not in CARDS:
        sys.stdout.write("%s has no card type (story, task or bug): no card to judge.\n" % rel)
        return 0
    fm = kb_index.front_block(text.splitlines())[0]
    ids = " ".join("%s: %s" % (k, fm[k]) for k in ("key", "jira") if fm.get(k))
    if fm.get("type") == "story" and story_is_v2(text):
        acs = story_ac_ids(text)
        sys.stdout.write("%s passes its story%s: %d AC (%s).\n" % (rel, " (%s; jira is never synced)" % ids if ids else "",
                                                                   len(acs), ", ".join("AC" + n for n in acs)))
        return 0
    sys.stdout.write("%s passes its card%s. A quote is checked for shape only: the owner reads who said it on the gate-2 page.\n"
                     % (rel, " (%s; jira is never synced)" % ids if ids else ""))
    return 0


def check_new_intents(root, cfg, strict):
    """rc of the card check on every intent new in this change (absent from the merge base); 0 when there is no base."""
    d = os.path.join(root, "kb", "intent")
    mb = plans.merge_base(root)[0] if os.path.isdir(d) else None
    listed = vsdlc.git_out(root, "ls-tree", "--name-only", mb, "--", "kb/intent/") if mb else None
    if listed is None:
        return 0
    rc, on_base = 0, set(listed.split("\n"))
    for n in sorted(os.listdir(d)):
        if n.endswith(".md") and not n.startswith(".") and "kb/intent/" + n not in on_base:
            rc = check_intent_file(os.path.join(d, n), root, cfg, strict, False) or rc
    return rc


# ── the real-run record of a story (AC8) ─────────────────────────────────────────────────────────────
RUN_FIELD_RX = re.compile(r"^\s*(?:[-*+]\s+)?(Command|UTC|Run log id):[ \t]*(.*?)\s*$")
UTC_RX = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?Z")


def real_run_problems(text, sp):
    """[problem] of a real-run record: the frontmatter names the story (`story:`) and the AC ids (`ac:`), and each `## Run <n>`
    section has a `Command:`, a `UTC:` time, a `Run log id:` and a fenced output excerpt. A blank still holding the placeholder is
    missing. Whether the command ran, or the id exists in a log, the machine cannot tell: the owner reads the record."""
    marks = placeholder_marks(sp)

    def blank(v):
        v = (v or "").replace("`", "").strip()
        return not v or any(m in v for m in marks)

    fm = kb_index.front_block(text.splitlines())[0]
    probs = ["the frontmatter has no `story:` (the story's intent path, its `key:` or `#<issue>`)"] if blank(fm.get("story")) else []
    if blank(fm.get("ac")) or not re.search(r"\bAC\d+\b", fm["ac"]):
        probs.append("the frontmatter has no `ac:` naming the AC ids the run shows (AC<n>, AC<m>)")
    runs = [(n, b) for n, b in spec_sections(text) if re.match(r"run(?![a-z])", n.lower())]
    if not runs:
        probs.append("no `## Run <n>` section: each command run is one")
    for name, body in runs:
        got, shot, fenced = {}, False, False
        for ln in body:
            if FENCE_RX.match(ln):
                fenced = not fenced
            elif fenced:
                shot = shot or not blank(ln)
            else:
                m = RUN_FIELD_RX.match(ln)
                if m:
                    got.setdefault(m.group(1), m.group(2))
        probs += ["`## %s` has no `%s:` line" % (name, f) for f in ("Command", "UTC", "Run log id") if blank(got.get(f))]
        if not blank(got.get("UTC")) and not UTC_RX.fullmatch(got["UTC"].replace("`", "").strip()):
            probs.append("`## %s`: `UTC:` is not a UTC time (YYYY-MM-DDTHH:MM:SSZ)" % name)
        if not shot:
            probs.append("`## %s` has no output excerpt (a fenced block)" % name)
    return probs


def real_run_need(root, rel, fm):
    """Why the story intent `rel` (frontmatter `fm`) asks a real run, or None: a `baton` or `run` touch in a row, not dropped, of a
    plan that names it (its `plan:`, or a plan whose `Intent:` or `Spec:` line names it), or `real_run: required` in the
    frontmatter of its spec."""
    specs = kb_index.paths_of(fm.get("spec"))
    linked = [p for p, _a in plans.kb_paths(fm.get("plan") or "")]
    for pr in dict.fromkeys(linked + plans._docs(root, "plans")):
        doc = plans.read_plan(root, pr)
        if doc is None:
            continue
        (ip, sp_path), _p = plans.plan_refs(doc)
        if pr not in linked and ip != rel and sp_path not in specs:
            continue
        for r in doc["rows"]:
            kinds = [(t.split() or [""])[0].lower() for t in (r["touches"] or "").replace("`", "").split(";")]
            if not r["link"]["dropped"] and ("baton" in kinds or "run" in kinds):
                return "its plan %s row %s holds a %s touch" % (pr, r["id"], "baton" if "baton" in kinds else "run")
    for sp_path in specs:
        text = plans._read(root, sp_path)
        if text and kb_index.front_block(text.split("\n"))[0].get("real_run", "").strip().lower() == "required":
            return "its spec %s says `real_run: required`" % sp_path
    return None


def check_real_runs(root, cfg):
    """rc 65 (the lines on stderr) when a record kb/records/*-real-run.md misses a field, or a story intent `status: done` that
    asks a real run has no record naming it; 0 otherwise. A record names a story by its `story:` value: the intent's path, its
    `key:` or `#<its issue>`. A task or bug intent, an open story and a story that asks no real run are not judged."""
    rdir, idir = os.path.join(root, "kb", "records"), os.path.join(root, "kb", "intent")
    probs, recs = [], {}
    for n in sorted(os.listdir(rdir)) if os.path.isdir(rdir) else []:
        text = plans._read(root, "kb/records/" + n) if n.endswith("-real-run.md") else None
        if text is None:
            continue
        probs += [("kb/records/" + n, why) for why in real_run_problems(text, cfg["tokens"]["spec"])]
        for v in kb_index.front_block(text.split("\n"))[0].get("story", "").replace(",", " ").split():
            recs.setdefault(v, "kb/records/" + n)
    for n in sorted(os.listdir(idir)) if os.path.isdir(idir) else []:
        rel = "kb/intent/" + n
        text = plans._read(root, rel) if n.endswith(".md") else None
        fm = kb_index.front_block(text.split("\n"))[0] if text else {}
        why = real_run_need(root, rel, fm) if fm.get("type") == "story" and fm.get("status") == "done" else None
        if not why:
            continue
        rec = next((recs[v] for v in (rel, fm.get("key"), "#" + fm["issue"] if fm.get("issue") else None) if v in recs), None)
        if rec:
            sys.stdout.write("real-run: %s has its record %s\n" % (rel, rec))
        else:
            probs.append((rel, "status is done, but no kb/records/<date>-<slug>-real-run.md names this story (%s); write one "
                          "(kb.py new real-run <slug>) with `story: %s`" % (why, rel)))
    if probs:
        sys.stderr.write("kb: real-run check failed (%d problem(s)):\n%s\n" % (len(probs), "\n".join("- %s: %s" % pw for pw in probs)))
        return 65
    return 0


CARD_AC = "Acceptance criteria"     # the story card's heading, one name in every language
AC_ITEM_RX = re.compile(r"^ {0,3}\d+[.)]\s+\*\*AC(\d+)\b", re.MULTILINE)
TRACE_RX = re.compile(r"→\s*(AC\d+(?:\s*,\s*AC\d+)*)")
QUOTE_RX = re.compile(r"\"([^\"]*)\"|“([^”]*)”")
PAGE_DECISION_RX = re.compile(r"\(page decision [^\s()]+ \([^()]+\)\)")


def _prose(body):
    """The lines of `body` outside fenced blocks and `<!-- … -->` comments, as one string: what a reader sees."""
    keep, fenced = [], False
    for ln in body:
        if FENCE_RX.match(ln):
            fenced = not fenced
        elif not fenced:
            keep.append(ln)
    return re.sub(r"<!--.*?-->", "", "\n".join(keep), flags=re.DOTALL)


def _quoted(line):
    """A line holds a quote of at least three non-blank characters, or a page decision id."""
    return bool(PAGE_DECISION_RX.search(line)) or any(len("".join(g).strip()) >= 3 for g in QUOTE_RX.findall(line))


def _story_intent(root, rel, by_line):
    """(intent path, its text) of the first story among the intents tied to the spec `rel`: those in `by_line` (named by an
    `Intent:` line) and every intent whose `spec:` names it; a task intent tied to the same spec never hides it. None when no
    intent says `type: story`."""
    idir = os.path.join(root, "kb", "intent")
    cands = by_line + (["kb/intent/" + n for n in sorted(os.listdir(idir)) if n.endswith(".md")] if os.path.isdir(idir) else [])
    for ip in cands:
        try:
            with open(os.path.join(root, ip), encoding="utf-8") as f:
                itext = f.read()
        except (OSError, UnicodeDecodeError):
            continue
        fm = kb_index.front_block(itext.split("\n"))[0]
        if fm.get("type") == "story" and (ip in by_line or rel in kb_index.paths_of(fm.get("spec"))):
            return ip, itext
    return None


def story_problems(text, path, root, sp):
    """(problems, out-of-scope warnings, number of AC) of a spec whose intent says `type: story`; None for any other spec, which
    keeps the shape rules alone. The intent is the one its `Intent:` line names or one whose `spec:` names it, the first of
    them that is a story (a dropped `Intent:` line, or a task intent tied to the same spec, does not hide a story). The AC ids
    are the story's (story_ac_ids). A v2 spec is traced by story_trace_v2; the fourth item is warnings `--strict` keeps."""
    m = re.search(r"(?m)^[*_ ]*Intent:[*_ ]*(.*)$", text)
    by_line = [p for p, _a in plans.kb_paths(m.group(1)) if p.startswith("kb/intent/")][:1] if m else []
    found = _story_intent(root, _repo_rel(path, root), by_line)
    if not found:
        return None
    ip, itext = found
    secs = dict(spec_sections(text))
    ids = story_ac_ids(itext)
    if spec_is_v2(text, sp):
        return story_trace_v2(secs, ip, ids, sp)
    out = [] if ids else ["the intent %s lists no AC (`1. **AC<n>: …**` items under `## %s`)" % (ip, CARD_AC)]
    goal = set(AC_ITEM_RX.findall(_prose(secs.get(sp["goal"], []))))
    out += ["AC%s of the intent is missing from `## %s` (a dropped AC: an AC leaves only by the owner's decision)" % (n, sp["goal"])
            for n in ids if n not in goal]
    items, named = criteria(secs.get(sp["criteria"], [])), set()
    for i, it in enumerate(items, 1):
        if i < len(items) and not re.search(TRACE_RX.pattern + r"\s*$", it.strip()):
            out.append("criterion %d does not end `→ AC<n>[, AC<m>]`: name the AC it proves" % i)
        for a in re.findall(r"AC(\d+)", " ".join(TRACE_RX.findall(it))):
            named.add(a)
            if a not in ids:
                out.append("criterion %d names AC%s, which is not an AC of the intent" % (i, a))
    out += ["AC%s is named by no criterion" % n for n in ids if n in goal and n not in named]
    body = secs.get(sp["out_of_scope"], [])
    lines = criteria(body) or [ln for ln in body if ln.strip()]
    warns = ["out-of-scope line `%s` holds neither the owner's quote (`\"…\"`) nor a page decision id "
             "(`(page decision <id> (<key>))`)" % " ".join(ln.split())[:80]
             for ln in lines if re.sub(r"^[-*+]\s+|\.$", "", ln.strip()).casefold() != "none" and not _quoted(ln)]
    return out, warns, len(ids), []


def story_trace_v2(secs, ip, ids, sp):
    """(problems, [], number of AC, warnings) of a v2 spec against its story's AC: each AC is named by a criterion (`→ AC<n>`),
    and no AC the story lacks is named in the goal or a criterion. A criterion that names no AC only warns."""
    out = [] if ids else ["the story %s lists no numbered AC" % ip]
    warns, named = [], set()
    for a in dict.fromkeys(re.findall(r"AC(\d+)", " ".join(V2_TRACE_RX.findall(_prose(secs.get(sp["goal"], [])))))):
        if a not in ids:
            out.append("`## %s` names AC%s, which is not an AC of the story" % (sp["goal"], a))
    for i, it in enumerate([x for x in card_items(secs.get(sp["criteria"], [])) if ITEM_RX.match(x)], 1):
        got = list(dict.fromkeys(re.findall(r"AC(\d+)", " ".join(V2_TRACE_RX.findall(it)))))
        if not got:
            warns.append("criterion %d names no AC (`→ AC<n>`)" % i)
        for a in got:
            named.add(a)
            if a not in ids:
                out.append("criterion %d names AC%s, which is not an AC of the story" % (i, a))
    out += ["AC%s of the story is named by no criterion (`→ AC%s`)" % (n, n) for n in ids if n not in named]
    return out, [], len(ids), warns


PLAN_ROW_RX = re.compile(r"^(?:Delivers\s+(AC\d+(?:\s*,\s*AC\d+)*)\s*:|enabling\s*:\s*\w)", re.I)
# a lean plan's Delivers cell, `AC1, AC2 (criteria 1–3)` or `AC3`, as well: read only for a plan whose spec is v2, and by focus
PLAN_DELIVERS_RX = re.compile(r"^(?:(?:Delivers\s+)?(AC\d+(?:\s*,\s*AC\d+)*)(?=\s*(?:[:(]|$))|enabling\s*:\s*\w)", re.I)


PLAN_OLD_COLS = {"acceptance", "model", "current", "shared"}     # columns only the earlier plan shape has


def plan_is_old(doc):
    """A plan whose row table has a column of the earlier shape (Must be true, Acceptance, Current state, Shared files, Model):
    a header kb_plan reads as `must` that is not `Delivers` is the earlier Must be true, in any language its COLUMNS know."""
    return any(r["cols"] & PLAN_OLD_COLS or any(plans._header_key(h) == "must" and _header_word(h) != "delivers"
                                                 for h in r["header"]) for r in doc["rows"])


def _header_word(cell):
    """A header cell as kb_plan._header_key reads it: plain, its parentheses and `@…` dropped, lower case."""
    return re.sub(r"\(.*?\)|@\S*", "", plans._plain(cell)).strip().lower()


PLAN_OLD_MSG = ("a story's plan new in this change, or whose row cells changed, takes the lean columns: Row, How, Delivers, Depends "
                "on, Trust touches, Link")


def plan_trace(root, rel, sp, base=None):
    """([(line, message)], story, AC ids) of the plan `rel`'s AC trace (`story`: the spec's intent says `type: story`, which
    makes the findings red; any other plan only warns): every row's Must be true starts `Delivers AC<n>[, AC<m>]:` or
    `enabling: <reason>`, each id is an AC of the spec the plan's `Spec:` line names (its `## Mục tiêu` list), each AC is delivered
    by a row not dropped, and the frontmatter has `focus:`. The `check links` problems are not here: `check plan` adds them."""
    doc, text = plans.read_plan(root, rel), plans._read(root, rel)
    if doc is None or text is None:
        return [(1, "cannot read %s" % rel)], False, []
    (ip, spec), rp = plans.plan_refs(doc)
    found = _story_intent(root, spec, [ip] if ip else [])
    story = found is not None
    probs = [(1, m) for m in rp if "kb/specs/" in m]
    if not kb_index.front_block(text.split("\n"))[0].get("focus"):
        probs.append((1, "the frontmatter has no `focus: P<n>`"))
    stext = plans._read(root, spec) if spec else None
    if spec and stext is None:
        probs.append((1, "the spec %s cannot be read" % spec))
    v2 = stext is not None and spec_is_v2(stext, sp)          # a v2 spec points to the story's AC: they are read there
    ids = story_ac_ids(found[1]) if v2 and found else list(dict.fromkeys(
        AC_ITEM_RX.findall(_prose(dict(spec_sections(stext or "")).get(sp["goal"], [])))))
    if stext is not None and not ids:
        probs.append((1, "the story %s lists no numbered AC" % found[0] if v2 and found else
                      "the spec %s lists no AC (`1. **AC<n>: …**` items under `## %s`)" % (spec, sp["goal"])))
    if not doc["rows"]:
        probs.append((1, "the plan has no row table (a header with Row and Link columns)"))
    delivered, dropped = set(), {}
    for r in doc["rows"]:
        m = (PLAN_DELIVERS_RX if v2 else PLAN_ROW_RX).match(r["must"])
        if not m:
            probs.append((r["line"], "row %s: Must be true starts neither `Delivers AC<n>[, AC<m>]:` nor `enabling: <reason>`%s"
                                     % (r["id"], " (a Delivers cell: `AC<n>[, AC<m>]`)" if v2 else "")))
            continue
        for n in re.findall(r"(?i)AC(\d+)", m.group(1) or ""):
            if stext is not None and ids and n not in ids:
                probs.append((r["line"], "row %s: Delivers AC%s, which is not an AC of %s" % (r["id"], n, found[0] if v2 and found else spec)))
            if r["link"]["dropped"]:
                dropped.setdefault(n, []).append(r["id"])
            else:
                delivered.add(n)
    if story and plan_is_old(doc) and plan_rows_changed(root, rel, base):
        probs.append((1, PLAN_OLD_MSG))
    for n in ids:
        if n not in delivered:
            probs.append((1, "AC%s is delivered by no row that is not dropped%s" % (
                n, " (only by dropped row %s)" % ", ".join(dropped[n]) if n in dropped else "")))
    return probs, story, ids


def cmd_check_plan(root, target, cfg):
    path = target if "/" in target or target.endswith(".md") else os.path.join(root, "kb", "plans", target + ".md")
    path = path if os.path.isabs(path) else os.path.join(os.getcwd(), path)
    if not os.path.isfile(path):
        return die("cannot read %s" % path, 66)
    rel = _repo_rel(path, root)
    found, story, ids = plan_trace(root, rel, cfg["tokens"]["spec"])
    found = found + [(ln, "links: " + m) for src, ln, m, _t in plans.link_problems(root) if src == rel]
    if found and story:
        sys.stderr.write("kb: %s does not pass the plan trace (%d problem(s)):\n%s\n" % (rel, len(found), "\n".join("- line %d: %s" % f for f in found)))
        return 65
    for ln, m in found:
        sys.stdout.write("WARNING %s:%d: %s (red only for a plan whose intent says type: story)\n" % (rel, ln, m))
    doc = plans.read_plan(root, rel)
    if story and doc and plan_is_old(doc) and not plan_rows_changed(root, rel):
        sys.stdout.write("WARNING %s: the earlier plan columns: a WARNING while its row cells are unchanged (a Link cell and the "
                         "Decisions do not count); once one changes, it takes the lean columns\n" % rel)
    sys.stdout.write("%s passes the plan trace.\n" % rel if not found else "%s: %d finding(s) as WARNING, none red: not a story plan.\n" % (rel, len(found)))
    if ids and not found:
        nums = sorted(int(n) for n in ids)
        span = "AC%d to AC%d" % (nums[0], nums[-1]) if nums == list(range(nums[0], nums[-1] + 1)) and len(nums) > 1 else ", ".join("AC" + n for n in ids)
        sys.stdout.write("plan: %d AC (%s), each delivered by a row that is not dropped.\n" % (len(ids), span))
    return 0


def cmd_check(root, what, target, cfg=None, strict=False):
    if what == "current-state":
        return cmd_check_current_state(root, target, cfg or C.defaults())
    if what == "intent":
        path = target if "/" in target or target.endswith(".md") else os.path.join(root, "kb", "intent", target + ".md")
        path = path if os.path.isabs(path) else os.path.join(os.getcwd(), path)
        return check_intent_file(path, root, cfg or C.defaults(), strict, new_in_change(path)[0] is False)
    if what != "spec":
        return die(M("kb.check_what"), 64)
    if "/" in target or target.endswith(".md"):
        path = target if os.path.isabs(target) else os.path.join(os.getcwd(), target)
    else:
        path = os.path.join(root, "kb", "specs", target + ".md")
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return die("cannot read %s" % path, 66)
    new, why = spec_is_new(path)
    warns = None if new else []
    sp = (cfg or C.defaults())["tokens"]["spec"]
    v2 = spec_is_v2(text, sp)
    probs, hints = spec_v2_problems(text, sp) if v2 else (spec_problems(text, sp, warns), [])
    story = story_problems(text, path, root, sp)
    if story:
        (probs if new or strict else warns).extend(story[0])     # --strict (open-pr.sh) judges an older spec too
        if strict:
            probs.extend(story[1])
        hints += story[3]
    if story is not None and not v2:
        five = ", ".join("`## %s`" % sp[k] for k in SPEC_V2)
        if spec_body_changed(path, text):           # one problem, the shape to take: the earlier shape's own would mislead
            probs, warns, story = ["a story's spec new or changed in this change takes the five sections: %s" % five], [], None
        else:
            hints.append("the earlier spec shape: a WARNING while its body is unchanged; once it changes, it takes the five "
                         "sections: %s" % five)
    rel = os.path.relpath(path, root)
    for w in warns or ():
        sys.stdout.write("WARNING %s: %s (required on a new spec only: %s)\n" % (rel, w, why))
    for w in story[1] if story and not strict else ():
        sys.stdout.write("WARNING %s: %s (red under --strict)\n" % (rel, w))
    for w in hints:
        sys.stdout.write("WARNING %s: %s\n" % (rel, w))
    sys.stdout.flush()                  # before the refusal on stderr: one order, buffered or not
    if probs:
        sys.stderr.write("kb: %s does not pass the spec shape (%d problem(s)):\n%s\n"
                         % (rel, len(probs), "\n".join("- " + p for p in probs)))
        return 65
    if v2:
        sys.stdout.write("%s passes the spec shape (the five sections of a spec derived from a story). The machine checks "
                         "presence, not whether a criterion is right, and no mark shows a person approved it.\n" % rel)
    else:
        sys.stdout.write("%s passes the spec shape. The machine checks only presence, order and a command per criterion: "
                         "not whether a command is right or runs, and no mark shows a person approved it.\n" % rel)
    if story and not story[0]:
        sys.stdout.write("story: %d AC, each %snamed by a criterion.\n" % (story[2], "" if v2 else "in `## %s` and each " % sp["goal"]))
    return 0


def _repo_rel(path, root):
    """`path` as git prints it from the top of the worktree that holds it, through its directory's real path (a symlinked directory
    or another worktree of the repo names the same page; a page that is itself a symlink keeps its own name); `root` when git cannot say."""
    real = os.path.join(os.path.realpath(os.path.dirname(os.path.abspath(path))), os.path.basename(path))
    top = vsdlc.git_out(os.path.dirname(real), "rev-parse", "--show-toplevel") or root
    return os.path.relpath(real, os.path.realpath(top)).replace(os.sep, "/")


def cmd_check_current_state(root, target, cfg):
    """Kiểm khuôn current-state theo profile của repo. Mặc định file `current_state.path` (`kb/current-state.md`) của repo đang đứng;
    with `current_state.pages` set and no file named, the whole ledger: the index, every page under the page cap, orphans and
    dead pointers. A page named as the file is judged by the page cap alone."""
    profile = current_state.profile_from_config(cfg)
    path = (target if os.path.isabs(target) else os.path.join(os.getcwd(), target)) if target else os.path.join(root, *profile["path"].split("/"))
    try:
        with open(path, "rb") as f:
            raw = f.read()
    except OSError:
        return die(M("kb.cs_unreadable", path), 66)
    rel = os.path.relpath(path, root)
    if not raw.strip():
        # File rỗng = chưa có khuôn, cùng loại với "không có file": rc 66 (skill ship không coi là cổng chặn cứng), không phải "đạt".
        return die(M("kb.cs_empty", rel), 66)
    page = target and current_state.is_page(_repo_rel(path, root), profile)
    whole = not target and profile.get("pages")
    if page:
        profile = current_state.page_profile(profile)
    if whole:
        probs = current_state.ledger_problems(root, profile, raw)
        if probs:
            sys.stderr.write(current_state.render_ledger(probs, root, profile["language"]) + "\n")
            return 65
    else:
        probs = current_state.problems_classified(raw, profile)
        if probs:
            sys.stderr.write(current_state.render(rel, probs, root, profile["language"]) + "\n")
            return 65
    lim = profile["limits"]
    sys.stdout.write("%s passes the current-state shape: %d lines, %d bytes (cap %s lines, %d bytes)%s. The machine reads only "
                     "the form of each line, not its meaning, so it does not replace reading it again.\n"
                     % (rel, len(raw.decode("utf-8", "replace").splitlines()), len(raw),
                        "no" if lim["lines"] is None else lim["lines"], lim["bytes"],
                        ", no sign of history" if profile["forbid"] or profile["forbid_patterns"] else ""))
    if whole:
        pl = profile["page_limits"]
        sys.stdout.write("%d page(s) %s pass the page cap (%s lines, %d bytes, %d characters a line); no orphan page, no dead pointer.\n"
                         % (len(current_state.list_pages(root, profile)[0]), profile["pages"],
                            "no cap on" if pl["lines"] is None else pl["lines"], pl["bytes"], pl["line_chars"]))
        for w in current_state.ledger_warnings(root, profile, raw, rel):
            sys.stdout.write(w + "\n")
        return 0
    warn = current_state.size_warning(raw, profile, rel)
    if warn:
        sys.stdout.write(warn + "\n")
    for w in current_state.label_warnings(raw, profile, rel):
        sys.stdout.write(w + "\n")
    return 0


def _git(root, *args):
    import subprocess
    try:
        r = subprocess.run(("git", "-C", root) + args, capture_output=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return 1, b""
    return r.returncode, r.stdout


def config_at_ref(root, ref, scratch):
    """(effective config, problems, script root) of the config committed at `ref`. The file is written into `scratch`, where
    `load` reads it; absent at the ref means the defaults. The external script, if the profile names one, is extracted too."""
    rc, out = _git(root, "show", "%s:%s" % (ref, C.CONFIG_REL))
    if rc == 0:
        os.makedirs(os.path.dirname(C.config_path(scratch)), exist_ok=True)
        with open(C.config_path(scratch), "wb") as f:
            f.write(out)
    cfg, probs, _present = C.load(scratch)
    gate = cfg["current_state"]["gate"]
    if not probs and gate.startswith("external:"):
        rel = gate[len("external:"):]
        rc, out = _git(root, "show", "%s:%s" % (ref, rel))
        if rc == 0:
            dest = os.path.join(scratch, *rel.split("/"))
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, "wb") as f:
                f.write(out)
            # a script that finds the ledger relative to its own location needs it beside it: the ledger of the checkout
            led = cfg["current_state"]["path"]
            try:
                with open(os.path.join(root, *led.split("/")), "rb") as f:
                    data = f.read()
                os.makedirs(os.path.dirname(os.path.join(scratch, *led.split("/"))), exist_ok=True)
                with open(os.path.join(scratch, *led.split("/")), "wb") as f:
                    f.write(data)
            except OSError:
                pass
    return cfg, probs


def cmd_check_current_state_diff(root, cfg, rng, body_file, ref):
    import tempfile
    scratch = None
    try:
        script_root = root
        if ref:
            if _git(root, "rev-parse", "--verify", "--quiet", ref + "^{commit}")[0] != 0:
                return die("--config-ref %s does not resolve to a commit: the diff gate cannot tell which profile judges (fetch it and retry)" % ref, 65)
            scratch = tempfile.mkdtemp(prefix="kb-config-ref-")
            cfg, probs = config_at_ref(root, ref, scratch)
            if probs:
                sys.stderr.write("kb: %s at %s is invalid:\n%s\n" % (C.CONFIG_REL, ref, C.render_problems(probs)))
                return 65
            script_root = scratch
        try:
            with open(body_file, encoding="utf-8", errors="replace") as f:
                body = f.read()
        except OSError:
            return die("cannot read --body-file %s" % body_file, 66)
        rc, out = _git(root, "-c", "core.quotePath=false", "diff", "--name-only", "--no-renames", rng)
        if rc != 0:
            return die("`git diff --name-only %s` failed: the diff gate cannot conclude (fetch the base and retry)" % rng, 65)
        paths = [ln.strip() for ln in out.decode("utf-8", "replace").split("\n") if ln.strip()]
        grc, msg = current_state.run_gate(current_state.profile_from_config(cfg), paths, body, root, script_root)
        if grc:
            sys.stderr.write("kb: current-state diff gate blocks %s:\n%s\n" % (rng, msg))
            return 65
        sys.stdout.write("current-state diff gate: %s\n" % msg)
        return 0
    finally:
        if scratch:
            import shutil
            shutil.rmtree(scratch, ignore_errors=True)


# ── kb.py focus: one place to follow a focus (the story process, AC7, AC11) ──────────────────────────
FOCUS_USAGE = "kb.py focus <P> [--repo owner/name]… [--json]"
FOCUS_STATES = ("gate 1", "gate 2", "in progress", "waiting for the owner", "done")
GH_REPO_RX = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9_.-]+$")
SLUG_OF_URL_RX = re.compile(r"[:/]([A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9_.-]+?)(?:\.git)?/?$")
GOAL_HEADINGS = tuple(C.effective({"language": lang})["tokens"]["spec"]["goal"] for lang in C.LANGUAGES)


def focus_words(root, p):
    """{"done_when": …, "not_doing": …} of the focus `p`, as the brain beside this sdlc copy answers `brain show <p> --json` (the
    lookup intake uses); {} when no brain answers. The brain is a command here, never imported: sdlc does not depend on it."""
    import intent_branch
    brain = intent_branch.brain_script()
    if not brain:
        return {}
    try:
        r = subprocess.run([sys.executable, brain, "show", p, "--json"], cwd=root, capture_output=True, text=True, timeout=60)
        it = json.loads(r.stdout) if r.returncode == 0 else {}
    except (OSError, subprocess.SubprocessError, ValueError):
        return {}
    it = it if isinstance(it, dict) else {}
    return {key: it[k].strip() for k, key in (("done", "done_when"), ("not_doing", "not_doing"))
            if isinstance(it.get(k), str) and it[k].strip()}


def spec_ac_ids(text):
    """The AC ids of a spec's Goal (`1. **AC<n>: …**` items), in order."""
    secs = dict(spec_sections(text or ""))
    return list(dict.fromkeys(n for h in GOAL_HEADINGS for n in AC_ITEM_RX.findall(_prose(secs.get(h, [])))))


def focus_repo(root, p, repo, down=None):
    """{repo, github, checked, stories} of the focus `p` in one repository: the one at `root` (`repo` None) or owner/name, read
    through gh at its default branch. A story is an issue labelled `focus:<p>`; its intents are those whose `issue:` names it.
    `down`: why gh did not answer for an earlier repository; this one is then not asked, so a hung gh is waited for once.
    shortcut: another repository's intents are read at its default branch and its PR heads, not on its `intent/*` branches with
    no PR (no local refs of it): such a story reads as gate 1; list those branches through the API when that matters."""
    gh = plans.GitHub(root, repo)
    out = {"repo": repo, "stories": [], "checked": False, "down": down}
    if down:
        out["github"] = "not checked (%s)" % down
        return out
    issues = gh.json(["issue", "list", "--label", "focus:" + p, "--state", "all", "--limit", str(plans.PR_LIMIT),
                      "--json", "number,title,state,labels"])
    prs = gh.json(plans.PR_ARGS) if issues is not None else None
    src = gh.tree("kb/intent", "kb/plans") if repo and prs is not None else None
    if prs is None or (repo and src is None):
        out["github"] = "not checked (%s)" % (gh.reason or gh.errors[-1])
        out["down"] = gh.errors[-1] if gh.down else None
        return out
    for what, got in (("issue", issues), ("PR", prs)):
        if len(got) >= plans.PR_LIMIT:                # a capped list would count old stories wrong: say so, write no counts
            gh.errors.append("the %s list is capped at %d: older ones were not read" % (what, plans.PR_LIMIT))
    intents = plans.gather_intents(root, gh, prs, src)
    if src is None:
        d = os.path.join(root, "kb", "plans")
        rels = ["kb/plans/" + n for n in sorted(os.listdir(d)) if n.endswith(".md")] if os.path.isdir(d) else []
        docs = {rel: plans.read_plan(root, rel) for rel in rels}
    else:
        docs = {rel: plans.read_plan_text(t, rel) for rel, t in sorted(src.items()) if rel.startswith("kb/plans/") and t is not None}
    plan_of = {}                                   # intent path → (plan path, spec path) of the plan whose `Intent:` names it
    for rel, doc in docs.items():
        if doc is not None and doc["rows"]:
            (ip, sp), _probs = plans.plan_refs(doc)
            plan_of.setdefault(ip, (rel, sp))
    for iss in sorted(issues, key=lambda x: x["number"]):
        n, notes = iss["number"], []
        mine = sorted(path for path, fm in intents.items() if str(fm.get("issue", "")).strip() == str(n))
        heads = {"intent/" + b for path in mine for b in plans.branch_names(path, intents[path])}   # the stem, and a key branch
        its = sorted((x for x in prs if x.get("headRefName") in heads), key=lambda x: x["number"])
        opened = [x for x in its if x["state"] == "OPEN"]
        merged = [x for x in its if x["state"] == "MERGED"]
        labels = {lb["name"] for x in [iss] + opened for lb in x.get("labels") or []}
        itype = next((lb[5:] for lb in sorted(labels) if lb.startswith("type:")), None) or next(
            (intents[x].get("type") for x in mine if intents[x].get("type")), "-")
        plan, spec = next((plan_of[x] for x in mine if x in plan_of), (None, None))
        spec = spec or next((intents[x]["spec"] for x in mine if intents[x].get("spec")), None)
        rows = None
        if plan:
            st = plans.status(root, plan, gh, src)
            rows = st["rows"] if st else None
        ids = []
        if spec:
            text = (plans._read(root, spec) if src is None else gh.file_at("HEAD", spec)[0])
            ids = spec_ac_ids(text)
            for x in [] if ids else [x for x in mine if intents[x].get("type") == "story"]:    # a v2 spec: the story's AC
                ids = story_ac_ids(plans._read(root, x) if src is None else src.get(x))
                if ids:
                    break
        if rows is not None:
            done_ids = {a for r in rows if r["state"] == "merged"
                        for a in re.findall(r"(?i)AC(\d+)", (PLAN_DELIVERS_RX.match(r["must"]) or [None, ""])[1] or "")}
        else:
            done_ids = set(ids) if merged else set()       # a one-PR story: its PR merged delivers every AC
        ac = {"delivered": len([a for a in ids if a in done_ids]), "total": len(ids)} if ids else None
        open_rows = [r["id"] for r in rows or [] if r["state"] not in ("merged", "dropped")]
        if iss["state"] == "CLOSED":
            state = "done"
            notes += ["PR #%d is still open" % x["number"] for x in opened]
        elif "waiting:owner" in labels:
            state = "waiting for the owner"
        elif not mine:
            state = "gate 1"
        elif opened or open_rows:
            state = "in progress"
        elif merged or rows:
            state = "in progress"
            notes.append("%s merged, the issue is open" % ("every row" if rows else "PR #%d" % merged[-1]["number"]))
        else:
            state = "gate 2"
        out["stories"].append({"number": n, "key": ("%s#%d" % (repo, n)) if repo else "#%d" % n, "type": itype, "state": state,
                               "ac": ac, "title": iss.get("title") or "", "intents": mine, "plan": plan,
                               "prs": [x["number"] for x in its], "notes": notes})
    out["checked"], out["down"] = not gh.errors, gh.errors[-1] if gh.down else None
    out["github"] = "checked (%d issue(s))" % len(issues) if not gh.errors else "partly checked (%d call(s) failed: %s)" % (
        len(gh.errors), gh.errors[0])
    return out


def place_key(root):
    """The place key baton gives this repository (baton.project_root): of git's common directory, so every worktree shares it.
    shortcut: None for a repository at HOME, where baton keys the nearest .vibemaestro/ instead; read that when a dotfiles repo
    needs counts."""
    home = os.environ.get("HOME", "")
    rc, out = _git(root, "rev-parse", "--git-common-dir")
    if rc != 0 or (os.path.isabs(home) and os.path.realpath(home) == root):
        return None
    common = os.path.realpath(os.path.join(root, out.decode("utf-8", "surrogateescape").strip()))
    return "project-" + hashlib.sha256(common.encode("utf-8", "surrogateescape")).hexdigest()[:16]


def own_slug(root):
    """owner/name of this repository's `origin`, lower case, or None."""
    rc, out = _git(root, "remote", "get-url", "origin")
    m = SLUG_OF_URL_RX.search(out.decode("utf-8", "replace").strip()) if rc == 0 else None
    return m.group(1).lower() if m else None


def cmd_focus(root, args):
    p, repos, as_json, i = None, [], False, 0
    while i < len(args):
        if args[i] == "--json":
            as_json, i = True, i + 1
        elif args[i] == "--repo" and i + 1 < len(args) and GH_REPO_RX.match(args[i + 1]):
            repos, i = repos + [args[i + 1]], i + 2
        elif p is None and re.match(r"^P[1-9][0-9]*$", args[i]):
            p, i = args[i], i + 1
        else:
            return die("usage: " + FOCUS_USAGE, 64)
    if p is None:
        return die("usage: " + FOCUS_USAGE, 64)
    here, seen = own_slug(root), set()
    res = {"focus": p, "time": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "repos": []}
    res.update(focus_words(root, p))
    down = None
    for repo in [None] + [r[:-4] if r.lower().endswith(".git") else r for r in repos]:
        key = (repo or here or "").lower() or None
        if repo and key in seen | {here}:
            continue                                  # one repository named twice is read once: a story is never counted twice
        seen.add(key)
        res["repos"].append(dict(focus_repo(root, p, repo, down), repo=repo or here))
        down = res["repos"][-1].pop("down")
    this = res["repos"][0]
    if this["github"].startswith("not checked"):      # the kb side still answers: this repository's intents of the focus
        res["kb"] = sorted(path for path, fm in plans.gather_intents(root, plans.GitHub(root), None).items() if fm.get("focus") == p)
    counted = all(r["checked"] for r in res["repos"])
    stories = [s for r in res["repos"] for s in r["stories"]]
    res["counts"] = {s: sum(1 for x in stories if x["state"] == s) for s in FOCUS_STATES} if counted else None
    res["line"] = ("%s: %s" % (p, " · ".join("%s %d" % kv for kv in res["counts"].items())) if counted else
                   "%s: not counted (GitHub not checked for %s)" % (
                       p, ", ".join(r["repo"] or here or "this repository" for r in res["repos"] if not r["checked"])))
    res["written"] = None
    if counted:
        dkey, x = place_key(root), os.environ.get("XDG_STATE_HOME", "")
        why = "no place key for this directory"
        if dkey:
            d = os.path.join(x if os.path.isabs(x) else os.path.join(os.path.expanduser("~"), ".local", "state"), "vibemaestro", "focus", dkey)
            try:
                os.makedirs(d, exist_ok=True)
                tmp = os.path.join(d, ".%s.json.%d" % (p, os.getpid()))
                with open(tmp, "w", encoding="utf-8") as f:
                    json.dump({k: res[k] for k in ("focus", "time", "counts", "line")}, f, ensure_ascii=False)
                os.replace(tmp, os.path.join(d, p + ".json"))
                res["written"] = "focus/%s/%s.json" % (dkey, p)
            except OSError as e:
                why = "the state directory cannot be written: %s" % (e.strerror or e)
        res["not_written"] = None if res["written"] else why
    else:
        res["not_written"] = "not every repository was read"
    if as_json:
        sys.stdout.write(json.dumps(res, ensure_ascii=False, indent=1) + "\n")
        return 0
    out = ["%s: %s: %s" % (p, key.replace("_", " "), res[key]) for key in ("done_when", "not_doing") if key in res]
    for r in res["repos"]:
        out.append("%s: GitHub %s" % (r["repo"] or here or "this repository", r["github"]))
        w = max([len(s["key"]) for s in r["stories"]] + [4])
        for s in r["stories"]:
            ac = "AC %d/%d" % (s["ac"]["delivered"], s["ac"]["total"]) if s["ac"] else "AC -"
            out.append("  %-*s  %-5s  %-21s  %-8s  %s" % (w, s["key"], s["type"], s["state"], ac, kb_index.cut(s["title"], 70)))
            out.extend("  %-*s  note: %s" % (w, "", nt) for nt in s["notes"])
    for path in res.get("kb", []):
        out.append("  %s  (kb side: focus %s, state not checked)" % (path, p))
    out.append(res["line"])
    out.append("counts written: %s" % res["written"] if res["written"] else "counts not written: " + res["not_written"])
    sys.stdout.write("\n".join(out) + "\n")
    return 0


def cmd_base(root, default):
    """Ref to cut the intake worktree from. stdout is the ref only (usable in `$(...)`); explanations go to stderr."""
    if not default:
        return die("usage: kb.py base --default <ref> (e.g. origin/main)", 64)

    if vsdlc.git_out(root, "rev-parse", "--verify", "--quiet", default + "^{commit}") is None:
        return die("--default %s is not a commit in this repo (typo? run `git fetch origin`)" % default, 64)

    def has_kb(ref):
        return vsdlc.git_out(root, "cat-file", "-e", "%s:%s" % (ref, KB_PROBE)) is not None

    if has_kb(default):
        sys.stdout.write(default + "\n")
        return 0
    scaffold = "origin/" + KB_BRANCH
    if not has_kb(scaffold) and has_kb("origin/" + KB_BRANCH_OLD):
        scaffold = "origin/" + KB_BRANCH_OLD
    if has_kb(scaffold):
        sys.stderr.write("kb: %s has no kb/ yet (the init-kb PR is not merged) - cutting from %s. The intent PR will carry "
                         "the scaffold commit: say so in the PR body (or merge the init-kb PR first and rerun this).\n"
                         % (default, scaffold))
        sys.stdout.write(scaffold + "\n")
        return 0
    return die("%s has no kb/ and %s is not available - run the skill vibemaestro-sdlc:init-kb (and push its branch) first; "
               "if it is pushed but this clone is single-branch, `git fetch origin %s` and retry" % (default, scaffold, KB_BRANCH), 2)


# ── config check ───────────────────────────────────────────────────────────────
def _paragraphs(text):
    """Normalised paragraphs (lower case, single spaces) of 120 characters or more, frontmatter removed."""
    body = vsdlc.strip_front(text)
    out = set()
    for para in re.split(r"\n\s*\n", body):
        norm = " ".join(para.lower().split())
        if len(norm) >= 120:
            out.add(norm)
    return out


def config_notices(root, cfg):
    """[stdout lines] for a VALID config: rule collisions, unknown disables, missing dirs, duplicate paragraphs, review items."""
    out = []
    plugin = vsdlc.plugin_root()
    rcfg = cfg["rules"]
    for d in rcfg["dirs"]:
        if not os.path.isdir(os.path.join(root, *d.split("/"))):
            out.append("WARNING rules.dirs: %s is not a directory here (nothing is delivered from it)" % d)
    packs, problems = rule_packs.load(root, root)
    plugin_names = {n for n, _t in R.load_rules(plugin)} | {n for _p, _d, prs in packs for n, _t in prs}
    for n in rcfg["disable"]:
        full = R.canonical(R.rule_file_name(n))         # an old name is warned about once below (note `renamed`)
        if full == vsdlc.CORE_NAME:
            out.append("WARNING rules.disable: %s is the process core, it is always delivered" % full)
        elif full not in plugin_names:
            out.append("WARNING rules.disable: %s matches no plugin rule" % n)
    rules, paths, notes = R.load_all(plugin, root, rcfg, keep=(vsdlc.CORE_NAME,), packs=packs)
    out.extend(vsdlc.pack_warnings(notes, problems, limit=None)[0])
    mine = R.pack_of(notes)
    for kind, name, detail in notes:
        if kind == "replaced":
            out.append("WARNING rule %s/%s replaces the plugin rule of the same name" % (detail, name))
        elif kind == "pack-replaced":
            out.append("WARNING rule %s/%s replaces the rule of the same name in the rule pack of %s" % (detail[1], name, vsdlc._short(detail[0])))
        elif kind == "renamed":
            out.append("WARNING rules.disable: %s was renamed to %s; the old name still works, use the new one" % (name, detail))
        elif kind == "old-name":
            out.append("WARNING rule %s/%s has the old name of the plugin rule %s and replaces it; the old name still works, rename "
                       "the file" % (detail[0], name, detail[1]))
        elif kind == "core-name":
            out.append("WARNING rule %s/%s has the name of the process core, which always comes from the plugin: this file is "
                       "not delivered; rename it" % (detail, name))
        elif kind == "shadowed":
            out.append("WARNING rule %s/%s has the name of %s/%s: only the first directory in rules.dirs is delivered; rename one"
                       % (detail[0], name, detail[1], detail[2]))
    repo_files = {n: paths[n] for n, _t in rules
                  if n not in mine and not paths[n].startswith(os.path.join(plugin, R.RULES_DIR) + os.sep)}
    texts = dict(rules)
    plugin_paras = {}
    for n, t in rules:
        if n not in repo_files:
            for para in _paragraphs(t):
                plugin_paras.setdefault(para, n)
    for n in sorted(repo_files):
        for para in sorted(_paragraphs(texts[n])):
            if para in plugin_paras:
                out.append("WARNING duplicate paragraph: %s repeats %s (\"%s...\"); delete one of them so it is not reminded twice"
                           % (os.path.relpath(repo_files[n], root), plugin_paras[para], para[:50]))
    if C.round_never_matches(cfg["commits"]["round_pattern"]):
        out.append("WARNING commits.round_pattern %s" % C.ROUND_NEVER_MATCHES)
    if cfg["current_state"]["gate"].startswith("external:"):
        out.append("REVIEW current_state.gate: %s runs a script of this repo (locally the working tree's, in CI the base "
                   "ref's); read it like code you are about to run" % cfg["current_state"]["gate"])
    return out


def cmd_config_migrate(root, write):
    """`kb.py config migrate [--write]`: the config carried up to the plugin's schema (sdlc_config.MIGRATIONS). Without --write
    it prints the result and changes nothing."""
    data, probs, present = C._read(root)
    if not present:
        sys.stdout.write("%s: no config file; nothing to migrate\n" % C.CONFIG_REL)
        return 0
    if probs:
        sys.stderr.write("kb: %s\n" % C.render_problems(probs))
        return 65
    try:
        out, steps = C.migrate(data)
    except ValueError as e:
        sys.stderr.write("kb: %s: %s\n" % (C.CONFIG_REL, e))
        return 65
    if not steps:
        sys.stdout.write("%s is schema %d, the schema this plugin reads: nothing to migrate\n" % (C.CONFIG_REL, out.get("schema", 1)))
        return 0
    bad = C.problems(out)
    if bad:
        sys.stderr.write("kb: the migrated config would be invalid, nothing written:\n%s\n" % C.render_problems(bad))
        return 65
    text = json.dumps(out, indent=2, ensure_ascii=False) + "\n"
    if write:
        tmp = C.config_path(root) + ".migrate.tmp"
        try:
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(text)
            os.replace(tmp, C.config_path(root))
        finally:
            if os.path.lexists(tmp):
                os.unlink(tmp)
        sys.stdout.write("%s migrated to schema %d (steps %s); review the diff and commit it\n"
                         % (C.CONFIG_REL, steps[-1], ", ".join(map(str, steps))))
    else:
        sys.stdout.write(text)
    return 0


def cmd_config_check(root):
    cfg, probs, present = C.load(root, quiet=True)
    if not present:
        sys.stdout.write("%s: no config file; the defaults apply (they equal the behaviour of a repo without one)\n" % C.CONFIG_REL)
        return 0
    lines = []
    if not probs:
        lines = config_notices(root, cfg)
    if probs:
        sys.stderr.write("kb: %s is invalid (%d problem(s)):\n%s\n" % (C.CONFIG_REL, len(probs), C.render_problems(probs)))
    else:
        sys.stdout.write("%s is valid (schema %d)\n" % (C.CONFIG_REL, cfg["schema"]))
        lines = ["WARNING %s: %s" % (k, why) for k, why in C.load_notes(root)] + lines
    for ln in lines:
        sys.stdout.write(ln + "\n")
    return 65 if probs else 0


def parse(argv):
    """(date, rest, {"--type": v, "--focus": v, "--jira": v}): the options of `new`, each with its value."""
    date, rest, card, i = None, [], {}, 0
    while i < len(argv):
        if argv[i] == "--date":
            date = argv[i + 1] if i + 1 < len(argv) else ""
            i += 2
        elif argv[i] in ("--type", "--focus", "--jira") and argv[:1] == ["new"]:
            card[argv[i]] = argv[i + 1] if i + 1 < len(argv) else ""
            i += 2
        else:
            rest.append(argv[i])
            i += 1
    return date, rest, card


def read_only(argv):
    """rc of a read-only kb_index command (find, list, outline, `check` with no target), or None when `argv` is another command.
    Runs before `parse`, so a word such as `--date` reaches find as it was typed."""
    if not argv or not (argv[0] in ("find", "list", "outline") or (argv[0] == "check" and all(a == "--strict" for a in argv[1:]))):
        return None
    root = repo_root()
    if not root:
        return die(M("kb.not_repo", os.getcwd()), 2)
    cfg, probs, _present = C.load(root)
    if probs:
        sys.stderr.write("kb: %s is invalid; fix it (kb.py config check lists every problem):\n%s\n" % (C.CONFIG_REL, C.render_problems(probs)))
        return 65
    rc = kb_index.main(root, argv[0], argv[1:], cfg)
    if argv[0] == "check" and rc in (0, 65):
        rc = check_new_intents(root, cfg, "--strict" in argv) or rc
        rc = check_real_runs(root, cfg) or rc
    return rc


def main(argv):
    global LANG
    LANG = messages.language_at(os.getcwd())
    rc = read_only(argv)
    if rc is not None:
        return rc
    date, rest, card = parse(argv)
    if date is None:
        date = datetime.date.today().isoformat()
    if not DATE_RX.match(date):
        return die(M("kb.date"), 64)
    if rest and rest[0] == "config":
        # `config check` is the one command that must work with an invalid config
        root, args = None, rest[1:]
        if args[:1] == ["migrate"] and args[1:] in ([], ["--write"]):
            root = repo_root()
            if not root:
                return die("kb.py config migrate [--write]: run inside a git repo", 2)
            return cmd_config_migrate(root, args[1:] == ["--write"])
        if args[:1] == ["check"]:
            args = args[1:]
            if args[:1] == ["--root"] and len(args) == 2:
                root = os.path.realpath(args[1])
            elif not args:
                root = repo_root()
            if root and os.path.isdir(root):
                return cmd_config_check(root)
            return die("kb.py config check [--root DIR]: DIR must be a directory (or run inside a git repo)", 64 if args else 2)
        return die("usage: kb.py config check [--root DIR] | kb.py config migrate [--write]", 64)
    if not rest or rest[0] not in ("init", "new", "check", "base", "plan", "focus"):
        return die(M("kb.usage", kb_index.USAGE, plans.USAGE + " | " + FOCUS_USAGE), 64)
    root = repo_root()
    if not root:
        return die(M("kb.not_repo", os.getcwd()), 2)
    cfg, probs, _present = C.load(root)
    if probs:
        sys.stderr.write("kb: %s is invalid; fix it (kb.py config check lists every problem):\n%s\n" % (C.CONFIG_REL, C.render_problems(probs)))
        return 65
    if rest[0] == "base":
        if len(rest) != 3 or rest[1] != "--default":
            return die("usage: kb.py base --default <ref>", 64)
        return cmd_base(root, rest[2])
    if rest[0] == "init":
        return cmd_init(root, rest[1:])
    if rest[0] == "plan":
        return plans.main(root, "plan", rest[1:])
    if rest[0] == "focus":
        return cmd_focus(root, rest[1:])
    if rest[0] == "check" and rest[1:2] == ["links"]:
        return plans.main(root, "links", rest[2:], lambda rel, base=None: plan_trace(root, rel, cfg["tokens"]["spec"], base)[:2],
                          guard=lambda rel, base: ac_guard(root, rel, base))
    if rest[0] == "check" and rest[1:2] == ["plan"] and len(rest) == 3:
        return cmd_check_plan(root, rest[2], cfg)
    if rest[0] == "check":
        if len(rest) == 2 and rest[1] == "current-state":
            return cmd_check(root, "current-state", "", cfg)
        if len(rest) > 2 and rest[1] == "current-state" and rest[2].startswith("--"):
            opts, i = {}, 2
            while i + 1 < len(rest) and rest[i] in ("--diff", "--body-file", "--config-ref"):
                opts[rest[i]], i = rest[i + 1], i + 2
            if i != len(rest) or "--diff" not in opts or "--body-file" not in opts:
                return die("usage: kb.py check current-state --diff <base>...<head> --body-file F [--config-ref REF]", 64)
            return cmd_check_current_state_diff(root, cfg, opts["--diff"], opts["--body-file"], opts.get("--config-ref"))
        args = [x for x in rest[2:] if x != "--strict"]
        if rest[1:2] == ["intent"] and len(args) == 1 and rest[2:].count("--strict") <= 1 and not args[0].startswith("--"):
            return cmd_check(root, "intent", args[0], cfg, "--strict" in rest)
        strict = rest[1] == "spec" and "--strict" in rest[2:]
        if strict:
            rest = [a for a in rest if a != "--strict"]
        if len(rest) != 3:
            return die(M("kb.check_usage"), 64)
        return cmd_check(root, rest[1], rest[2], cfg, strict)
    if len(rest) != 3:
        return die(M("kb.new_usage"), 64)
    return cmd_new(root, rest[1], rest[2], date, cfg, card.get("--type"), card.get("--focus"), card.get("--jira"))


if __name__ == "__main__":
    for _s in filter(None, (sys.stdout, sys.stderr)):   # Windows writes a pipe in the system code page, which lacks Vietnamese and the arrows
        _s.reconfigure(encoding="utf-8", errors="backslashreplace")
    sys.exit(main(sys.argv[1:]))
