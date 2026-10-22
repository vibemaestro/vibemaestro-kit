#!/usr/bin/env bash
# =============================================================================
# Mở PR — adapter của skill ship
# =============================================================================
# Dùng (chạy từ worktree của repo đang làm việc; skill gọi qua "${CLAUDE_PLUGIN_ROOT}/scripts/open-pr.sh"):
#   open-pr.sh --title "type(scope): việc đã làm" \
#        --summary <file.md> --evidence <file.txt> \
#        [--head <branch>] [--base main] [--fixes "98 96"] [--closes "123"] \
#        [--draft] [--dry-run]
#
# `--closes` bỏ trống thì TỰ ĐỌC `issue: N` từ `kb/intent/<slug>.md` của repo đang đứng khi nhánh là
# `<branch.intent_prefix><slug>` — xem comment ngay trước khối đọc nó bên dưới.
#
# `--draft`: PR của một intent (một intent = một branch = một PR draft) — mở thẳng ở draft thay vì
# mở thường rồi `gh pr ready --undo`.
#
# Adapter MỎNG: nó chỉ tìm lõi `open_pr.py` (cạnh file này) rồi truyền tham số. Mọi quyết định — khuôn 4
# mục của thân PR, và ba phép từ chối (thiếu bằng chứng chạy · cổng sổ hiện trạng đỏ mà thân PR không có
# dòng miễn trừ · đang đứng ở cây chính) — nằm trong lõi. Vì sao không gọi `gh pr create` trần: lõi từ
# chối những ca mà lệnh trần để lọt, và không gì ép người mở PR theo cùng một chuẩn "đủ để mở PR".
#
# Transport: `gh pr create` only; the repo slug is read from `gh` and passed to the core as `--repo` (see the core's docstring).
#
# Exit: rc của lõi — 0 xong (in số PR) · 3 thiếu bằng chứng · 4 sổ hiện trạng · 5 không ở worktree
# · 64/66 arguments/file · 2 no `gh`, `python3` or core (the core's own 67 for no `gh` is never reached through
# this adapter) · 1 `gh` refused (65 is retired and reserved, see the core). The frozen list: CONTRACT.md.
# =============================================================================
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
CORE="$HERE/open_pr.py"            # lõi nằm cạnh adapter, trong thư mục plugin
export PYTHONDONTWRITEBYTECODE=1   # không ghi __pycache__ vào thư mục plugin (có thể là bản cài trong cache)

die() { echo "open-pr: $1" >&2; exit "${2:-1}"; }
# Messages come from messages.py beside this file, in the repo's `language` (vi for a config without the key): `say KEY ARG…`
# prints one (the key and its arguments if messages.py fails, after its own error). The refusals printed before the core,
# messages.py and python3 are known to be there cannot ask the table: they carry their own two texts and read `language` with
# sed (the key on one line, as every writer of the config puts it) from the repo of the current directory.
shell_en() { [ "$(sed -n 's/.*"language"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' "$(git rev-parse --show-toplevel 2>/dev/null || echo .)/.vibemaestro/sdlc.json" 2>/dev/null | head -n 1)" = en ]; }
say() { python3 "$HERE/messages.py" "$@" || printf '%s' "$*"; }

for f in "$CORE" "$HERE/messages.py"; do
    [ -r "$f" ] && continue
    if shell_en; then die "the core is missing: $f" 2; else die "thiếu lõi $f" 2; fi
done
if ! command -v python3 >/dev/null 2>&1; then
    if shell_en; then die "no \`python3\`" 2; else die "không có \`python3\`" 2; fi
fi

TITLE=""; SUM=""; EV=""; HEAD_BR=""; BASE="main"; FIXES=""; CLOSES=""; CRIT=""; DRY=0; DRAFT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --title)    TITLE="${2:-}"; shift 2 ;;
        --summary)  SUM="${2:-}";   shift 2 ;;
        --evidence) EV="${2:-}";    shift 2 ;;
        --head)     HEAD_BR="${2:-}"; shift 2 ;;
        --base)     BASE="${2:-}";  shift 2 ;;
        --fixes)    FIXES="${2:-}"; shift 2 ;;
        --closes)   CLOSES="${2:-}"; shift 2 ;;
        --crit)     CRIT="${2:-}";  shift 2 ;;
        --dry-run)  DRY=1; shift ;;
        --draft)    DRAFT=1; shift ;;
        *) die "$(say op.sh.unknown_arg "$1")" 64 ;;
    esac
done
[ -n "$TITLE" ] || die "$(say op.sh.no_title)" 64
[ -n "$SUM" ]   || die "$(say op.sh.no_summary)" 64
[ -n "$EV" ]    || die "$(say op.sh.no_evidence)" 64

# `--closes` tự đọc từ frontmatter `issue: N` của hồ sơ intent khi KHÔNG truyền tay: PR draft của một
# intent thường mở ngay trên nhánh `intent/<slug>` (nơi `create-intent` vừa ghi số issue), nên bắt gõ
# lại số đó là một bước thừa hay bị quên. Intent đọc từ repo ĐANG LÀM VIỆC (cwd), không từ nơi chứa
# plugin. Đây chỉ đoán MỘT tham số không nhạy cảm, luôn in ra để minh bạch; `--closes` tường minh vẫn
# thắng tuyệt đối.
if [ -z "$CLOSES" ]; then
    TOP=$(git rev-parse --show-toplevel 2>/dev/null) || TOP=""
    BR=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || BR=""
    # `branch.intent_prefix` of the repo's config (default `intent/`); an invalid config is rc 64 here, as in the core
    PFX=$(python3 "$HERE/sdlc_config.py" get branch.intent_prefix 2>&1) || die "$PFX" 64
    case "$BR" in
        "$PFX"?*)
            DOC="$TOP/kb/intent/${BR#"$PFX"}.md"
            if [ -n "$TOP" ] && [ -r "$DOC" ] && N=$(grep -m1 -E '^issue:[[:space:]]*[0-9]+[[:space:]]*$' "$DOC" 2>/dev/null); then
                CLOSES="${N#issue:}"; CLOSES="${CLOSES// /}"
                echo "open-pr: --closes $CLOSES read from $DOC (branch $BR)" >&2
            fi
            ;;
    esac
fi

if [ "$DRY" -eq 1 ]; then
    # `--dry-run` chỉ dựng thân PR và chạy các phép từ chối — không chạm mạng,
    # nên KHÔNG đòi `gh`. Đòi nó ở đây là bắt bộ test phải có `gh` để kiểm một
    # đường không bao giờ gọi `gh`.
    exec python3 "$CORE" --title "$TITLE" --summary-file "$SUM" \
        --evidence-file "$EV" --base "$BASE" \
        ${HEAD_BR:+--head "$HEAD_BR"} ${FIXES:+--fixes "$FIXES"} \
        ${CLOSES:+--closes "$CLOSES"} \
        ${CRIT:+--crit-file "$CRIT"} ${DRAFT:+--draft} --dry-run
fi

command -v gh >/dev/null 2>&1 || die "$(say op.sh.no_gh)" 2

# `gh` đã đăng nhập trên máy trạm, nên slug đọc từ nó thay vì bắt người gõ tay.
# PAT không đi qua đây: transcript phiên ghi nguyên văn mọi lệnh lên đĩa.
SLUG=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) || SLUG=""

ARGS=(--title "$TITLE" --summary-file "$SUM" --evidence-file "$EV" --base "$BASE")
[ -n "$HEAD_BR" ] && ARGS+=(--head "$HEAD_BR")
[ -n "$FIXES" ]   && ARGS+=(--fixes "$FIXES")
[ -n "$CLOSES" ]  && ARGS+=(--closes "$CLOSES")
[ -n "$CRIT" ]    && ARGS+=(--crit-file "$CRIT")
[ -n "$DRAFT" ]   && ARGS+=(--draft)

# The one transport is `gh`, and the core never reads the environment to choose a network path: a sandbox session exports a
# token file, a workstation may export a PAT (`gh`, `act` and local CI scripts read it), and no variable changes what the
# adapter does (test-core-pr.sh pins that). The slug read from `gh` goes to the core as `--repo`; with no slug `gh` chooses
# by the working directory.
[ -n "$SLUG" ] && ARGS+=(--repo "$SLUG")
exec python3 "$CORE" "${ARGS[@]}"
