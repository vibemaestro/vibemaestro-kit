#!/usr/bin/env python3
"""`kb/` của REPO ĐANG ĐỨNG: dựng khung tối thiểu (init), tạo file theo khuôn tên (new), kiểm hình dạng (check).

Mọi việc đều ghi/đọc `kb/` của repo ở cwd. Không đọc hay ghi repo nào khác.

  kb.py init [--answers F.json] [--lang vi|en] [--adopt [--detect]] [--dry-run]
      dựng kb/{intent,specs,plans,decisions}/, kb/README.md, kb/current-state.md VÀ cấu hình `.vibemaestro/sdlc.json` của repo (chỉ khoá đã
      chọn: scaffold, giá trị dò được, câu trả lời), cộng `<rules.dirs[0]>/README.md` và `example.instructions.md` cho repo app. IDEMPOTENT:
      thứ đã có giữ nguyên byte (`kept`), config đã có không bao giờ bị viết lại (in `would add` / `differs`). `--adopt` cho repo đã có file
      quy trình: không ghi file luật, không sửa file nào, in việc phải làm tay.
      `--detect` (chỉ với `--adopt`) ĐỀ XUẤT; câu trả lời thắng. Câu trả lời hỏng thì rc 65 và không ghi gì. Chi tiết ở `init_setup.py`.
      `kb/README.md` sinh ra TỰ ĐỦ (bảng thư mục, quy ước tên, khuôn spec và khuôn current-state) — không trỏ sang repo nào khác.
      `--lang vi|en`: the scaffold's language (also the answer `language`); without it, the `language` of the config (absent: vi).
  kb.py new <intent|plan|spec> <slug> [--date YYYY-MM-DD]
      tạo kb/<loại>/<ngày>-<slug>.md từ khuôn có dấu placeholder (`tokens.spec.placeholder`). Không đè file đã có. Khuôn `spec` là
      khuôn bốn mục (`tokens.spec`: Bối cảnh, Mục tiêu, Ngoài phạm vi, Tiêu chí chấp nhận), in the prose of `language`.
  kb.py base --default <ref>
      prints the ref `intake` must cut its worktree from: `<ref>` (the default branch, e.g. origin/main) when it already
      has `kb/intent/`; otherwise `origin/chore/kb-init` (or its old name `origin/chore/kb-khoi-tao`) when the init-kb branch is pushed and
      has kb/ (the intent PR then carries the scaffold commit). Neither: rc 2, pointing at init-kb.
  kb.py check spec <<ngày>-<slug> | đường-dẫn>
      máy kiểm HÌNH DẠNG của một spec: đủ bốn mục đúng thứ tự (`## Thiết kế` tuỳ chọn, sau bốn mục), không rỗng, không
      còn dấu placeholder, mỗi tiêu chí có lệnh trong `…`, tiêu chí cuối nhắc `## Bằng chứng chạy`. Tên mục, tiêu đề bằng chứng
      và dấu placeholder lấy từ `tokens.spec` (preset `language: en`: Context, Goal, Out of scope, Acceptance criteria, Design,
      Run evidence, `<FILL`). KHÔNG kiểm lệnh có đúng/chạy
      được, và KHÔNG kiểm người đã duyệt — duyệt là lời của người, máy không có dấu "đã duyệt".
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
      `description` or `status`. A spec over `kb.spec_warn_bytes` is a `WARNING` line, rc stays 0. Read-only like find.
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
import json
import os
import re
import sys

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
KINDS = {"intent": "intent", "plan": "plans", "spec": "specs"}
SLUG_RX = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
DATE_RX = re.compile(r"^\d{4}-\d{2}-\d{2}$")

README = {"vi": """# `kb/` của repo này

Nơi repo ghi nhớ: yêu cầu, thiết kế, quyết định và hiện trạng — để người và phiên Claude Code sau không phải đoán.
Dựng bởi skill `init-kb` của plugin `vibemaestro-sdlc`; file này tự đủ, sửa tay thoải mái.

| Thư mục / file | Nội dung | Có nghĩa vụ cập nhật? |
|---|---|---|
| `intent/` | yêu cầu gốc bằng lời người đặt, 1-2 đoạn | không — bản ghi một lần |
| `specs/` | thiết kế: vì sao, đánh đổi, số đo; spec của một intent theo khuôn bên dưới | không — đóng lại khi thi hành xong |
| `plans/` | chia việc: cái gì phải đúng + lệnh nghiệm thu | không |
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

**Khuôn spec của một intent:** bốn mục `## ` đúng thứ tự — `## {context}`, `## {goal}`, `## {out_of_scope}`,
`## {criteria}`; `## {design}` (tuỳ chọn) đứng sau. Tiêu chí là **lệnh** + kết quả mong đợi; tiêu chí cuối luôn là:
PR có mục `## {evidence}`. Kiểm hình dạng: `kb.py check spec <ngày>-<slug>`.

**Khuôn `current-state.md`:** chỉ trạng thái hiện hành, viết đè không nối thêm; không lịch sử (ngày đo, số PR, "trước
đây…"), không cách làm hay số liệu thí nghiệm — chi tiết nằm ở `specs/` và `decisions/`, file này chỉ trỏ tới. Có trần
kích thước. Kiểm: `kb.py check current-state`.
""", "en": """# `kb/` of this repo

Where the repo keeps its memory: requests, designs, decisions and the current state, so that people and later Claude Code
sessions do not have to guess. Set up by the `init-kb` skill of the `vibemaestro-sdlc` plugin; this file stands on its own, edit
it freely.

| Directory / file | Content | Kept up to date? |
|---|---|---|
| `intent/` | the original request in the words of the person who made it, 1-2 paragraphs | no: a one-time record |
| `specs/` | design: why, trade-offs, measurements; the spec of an intent follows the shape below | no: closed once carried out |
| `plans/` | the split of the work: what must be true + the acceptance command | no |
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

**Shape of the spec of an intent:** four `## ` sections in this order: `## {context}`, `## {goal}`, `## {out_of_scope}`,
`## {criteria}`; `## {design}` (optional) comes after them. A criterion is a **command** + the expected result; the last
criterion is always: the PR has a `## {evidence}` section. Shape check: `kb.py check spec <date>-<slug>`.

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
---

# Plan — {fill}: chủ đề>

Intent: {fill}: kb/intent/… của chủ đề, hoặc bỏ> · Spec: {fill}: kb/specs/…, hoặc bỏ> · Issue: #{fill}: số>

Mỗi PR một hàng, ghi TRƯỚC khi giao PR đó và không sửa để ghi trạng thái: `kb.py plan status <file này>` đọc trạng thái từ GitHub.
Phiên nhận một hàng ghi `plan: <file này>#<hàng>` vào frontmatter intent (và spec) của nó. PR mới → hàng mới; PR bị bỏ → `dropped: <lý do>` ở ô Link.

## Rows

| Row | Must be true | Acceptance | Depends on | Version | Model | Link |
|---|---|---|---|---|---|---|
| A | {fill}: một dòng> | `{fill}: lệnh>` → {fill}: kết quả> | — | {fill}: — hoặc, ở hàng release, plugin x.y.z> | {fill}: model, effort> | — |

## Decisions

- {fill}: YYYY-MM-DD HH:MM> — "{fill}: lời của chủ repo, nguyên văn>" — [{fill}: nơi nói>]({fill}: link>)
""",
    "spec": """---
description: "{fill}: một dòng — spec này làm gì>"
---

# {fill}: tên spec>

Intent: {intent}

## {context}

{fill}: vì sao có việc này, đo được gì ở hiện trạng — rút từ intent và kết quả brainstorm, không thêm ý của agent.>

## {goal}

{fill}: điều phải đúng sau khi xong, nói bằng kết quả người thấy được.>

## {out_of_scope}

{fill}: điều không làm. Ghi "không có" nếu thật sự không có.>

## {criteria}

1. `{fill}: lệnh chứng minh>` → {fill}: kết quả mong đợi>
2. PR có mục `## {evidence}` ghi output thật của các lệnh trên.
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
---

# Plan — {fill}: topic>

Intent: {fill}: kb/intent/… of the topic, or drop it> · Spec: {fill}: kb/specs/…, or drop it> · Issue: #{fill}: number>

One row per PR, written BEFORE that PR is dispatched and never edited for status: `kb.py plan status <this file>` reads it from GitHub.
The session that takes a row writes `plan: <this file>#<row>` into its intent's (and spec's) frontmatter. A new PR → a new row; a dropped
one → `dropped: <reason>` in its Link cell.

## Rows

| Row | Must be true | Acceptance | Depends on | Version | Model | Link |
|---|---|---|---|---|---|---|
| A | {fill}: one line> | `{fill}: command>` → {fill}: expected> | — | {fill}: — or, on a release row, plugin x.y.z> | {fill}: model, effort> | — |

## Decisions

- {fill}: YYYY-MM-DD HH:MM> — "{fill}: the owner's words, verbatim>" — [{fill}: where>]({fill}: link>)
""",
    "spec": """---
description: "{fill}: one line, what this spec does>"
---

# {fill}: spec name>

Intent: {intent}

## {context}

{fill}: why this work exists, what was measured in the current state — taken from the intent and the brainstorm result, no
ideas of the agent.>

## {goal}

{fill}: what must be true when done, said as a result a person can see.>

## {out_of_scope}

{fill}: what is not done. Write "none" if there really is nothing.>

## {criteria}

1. `{fill}: command that proves it>` → {fill}: expected result>
2. The PR has a `## {evidence}` section with the real output of the commands above.
""",
}}
INTENT_BLANK = {"vi": "{fill}: đường dẫn kb/intent/…>", "en": "{fill}: path kb/intent/…>"}


SPEC_REQUIRED = ("context", "goal", "out_of_scope", "criteria")   # keys of `tokens.spec`, in the order the sections must come
H2_RX = re.compile(r"^## +(.*?)\s*$")
FENCE_RX = re.compile(r"^\s*(```|~~~)")
ITEM_RX = re.compile(r"^ {0,3}(?:\d+[.)]|[-*+])\s+")
CODE_RX = re.compile(r"`[^`\n]+`")


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


def cmd_new(root, kind, slug, date, cfg=None):
    if kind not in KINDS:
        return die(M("kb.kind", kind, ", ".join(sorted(KINDS))), 64)
    if not SLUG_RX.match(slug or ""):
        return die(M("kb.slug", slug), 64)
    sub = os.path.join(root, "kb", KINDS[kind])
    if not os.path.isdir(sub):
        return die(M("kb.no_dir", KINDS[kind]), 2)
    name = "%s-%s.md" % (date, slug)
    path = os.path.join(sub, name)
    intent_rel = "kb/intent/%s-%s.md" % (date, slug)
    # spec trỏ về intent cùng <ngày>-<slug> nếu file đó đã có; chưa có thì để dấu placeholder (không bịa đường dẫn)
    lang, sp = lang_of(cfg or C.defaults())
    intent = intent_rel if os.path.isfile(os.path.join(root, intent_rel)) else fill(INTENT_BLANK[lang], sp)
    if not write_new(path, fill(TEMPLATES[lang][kind], sp, date=date, intent=intent)):
        return die("%s already exists: not overwritten" % os.path.relpath(path, root), 6)
    if kind == "spec":
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


def spec_problems(text, sp=None):
    """Danh sách lý do spec chưa đạt khuôn bốn mục; rỗng = đạt HÌNH DẠNG (không kiểm nội dung đúng). `sp` = `tokens.spec` (tên mục,
    tiêu đề bằng chứng, dấu placeholder); mặc định của plugin khi không truyền."""
    sp = sp or C.defaults()["tokens"]["spec"]
    req, opt, crit, evidence = [sp[k] for k in SPEC_REQUIRED], sp["design"], sp["criteria"], sp["evidence"]
    secs = spec_sections(text)
    names = [n for n, _ in secs]
    out = []
    for n in req:
        if n not in names:
            out.append("section `## %s` is missing" % n)
        elif names.count(n) > 1:
            out.append("section `## %s` appears %d times" % (n, names.count(n)))
    for n in names:
        if n not in req and n != opt:
            out.append("unknown section `## %s`: only the four sections and `## %s` are accepted; a minor point goes in as `###` inside `## %s`"
                       % (n, opt, opt))
    known = [n for n in names if n in req or n == opt]
    want = [n for n in req if n in names] + ([opt] if opt in names else [])
    if not out and known != want:
        out.append("sections out of order: found `%s`, need `%s` (`## %s`, when present, comes AFTER the four sections)"
                   % (" > ".join(known), " > ".join(want), opt))
    for n, body in secs:
        if (n in req or n == opt) and not "".join(body).strip():
            out.append("section `## %s` is empty" % n)
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


def cmd_check(root, what, target, cfg=None):
    if what == "current-state":
        return cmd_check_current_state(root, target, cfg or C.defaults())
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
    probs = spec_problems(text, (cfg or C.defaults())["tokens"]["spec"])
    rel = os.path.relpath(path, root)
    if probs:
        sys.stderr.write("kb: %s does not pass the spec shape (%d problem(s)):\n%s\n"
                         % (rel, len(probs), "\n".join("- " + p for p in probs)))
        return 65
    sys.stdout.write("%s passes the four-section spec shape. The machine checks only presence, order and a command per criterion: "
                     "not whether a command is right or runs, and no mark shows a person approved it.\n" % rel)
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
    date, rest, i = None, [], 0
    while i < len(argv):
        if argv[i] == "--date":
            date = argv[i + 1] if i + 1 < len(argv) else ""
            i += 2
        else:
            rest.append(argv[i])
            i += 1
    return date, rest


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
    return kb_index.main(root, argv[0], argv[1:], cfg)


def main(argv):
    global LANG
    LANG = messages.language_at(os.getcwd())
    rc = read_only(argv)
    if rc is not None:
        return rc
    date, rest = parse(argv)
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
    if not rest or rest[0] not in ("init", "new", "check", "base", "plan"):
        return die(M("kb.usage", kb_index.USAGE, plans.USAGE), 64)
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
    if rest[0] == "check" and rest[1:2] == ["links"]:
        return plans.main(root, "links", rest[2:])
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
        if len(rest) != 3:
            return die(M("kb.check_usage"), 64)
        return cmd_check(root, rest[1], rest[2], cfg)
    if len(rest) != 3:
        return die(M("kb.new_usage"), 64)
    return cmd_new(root, rest[1], rest[2], date, cfg)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
