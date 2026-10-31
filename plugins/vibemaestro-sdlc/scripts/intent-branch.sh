#!/usr/bin/env bash
# =============================================================================
# Vòng đời branch `intent/*` — adapter của skill intake / plan
# =============================================================================
# Dùng (chạy từ repo đang làm việc; skill gọi qua "${CLAUDE_PLUGIN_ROOT}/scripts/intent-branch.sh"):
#   intent-branch.sh create-intent --slug <ngày-slug> [--base origin/main] [--no-issue]
#   intent-branch.sh worker-branch --intent <slug> --name <branch> [--no-checkout]
#       (từ cây chính BẮT BUỘC `--no-checkout`, rồi `git worktree add`; thiếu → rc 7)
#   intent-branch.sh integrate     --intent <slug> --to local|origin [--load-bearing]
#   intent-branch.sh retry-issue   --slug <ngày-slug>
#
# Adapter MỎNG, với HAI ngoại lệ ghi ở cuối file (đếm commit của `integrate`, và tiêm `--issue`
# mặc định cho `create-intent`). Còn lại nó chỉ tìm lõi `intent_branch.py` (cạnh file này) rồi
# truyền tham số nguyên trạng. Mọi quyết định — cổng `kb/intent/<slug>.md` phải có trước khi tạo
# branch, branch con phải cắt từ tip `intent/*`, và **rebase trước khi ff** — nằm trong lõi.
#
# Vì sao có file này: mô hình một-intent-một-branch đòi worker góp commit vào MỘT branch chung. Bước
# `--ff-only` hỏng thì phản xạ là gõ `git merge` thường, và lịch sử `intent/*` mất tuyến tính mà không
# có gì đỏ lên. Đường này không có nhánh nào gọi `git merge` thiếu `--ff-only`, nên ca đó không tồn tại.
#
# `--to` khai TƯỜNG MINH, không auto-detect — xem docstring của lõi.
#
# Exit: rc của lõi — 0 xong · 1 `retry-issue` không tạo được issue (best-effort, không áp cho ba lệnh
# con kia) · 2 môi trường · 3 thiếu `kb/intent/<slug>.md` · 4 không góp ngược được (BLOCK) · 5 base/đích
# không dùng được · 6 branch đã tồn tại · 7 `integrate`, hay `worker-branch` thiếu `--no-checkout`, đứng
# sai chỗ (cây chính/submodule, nhánh nguồn main/master, hoặc env đặt `GIT_DIR`… — cd vào worktree của
# bạn) · 8 nhánh task hơn 1 commit so với điểm cắt (squash về merge-base, hoặc `--load-bearing` khi thứ
# tự các bước là load-bearing) · 64 sai tham số.
# =============================================================================
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
CORE="$HERE/intent_branch.py"      # lõi nằm cạnh adapter, trong thư mục plugin (kèm open_pr.py mà nó import)

die() { echo "intent-branch: $1" >&2; exit "${2:-1}"; }
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
[ $# -gt 0 ] || die "$(say ib.sh.no_subcommand)" 64

# -----------------------------------------------------------------------------
# `integrate`: một task = một commit — rc 8 (luật `git-process` của plugin, mục 4)
# -----------------------------------------------------------------------------
# Phép này ở ADAPTER, không ở lõi: lõi còn được gọi thẳng bởi người dùng khác của nó (không qua
# adapter này), nên luật đơn vị commit không nằm trong lõi. Lõi không biết `--load-bearing`, nên adapter
# TIÊU THỤ cờ đó — chuyển xuống là argparse của lõi từ chối (rc 2).
# Đếm so với ĐIỂM CẮT (merge-base với tip intent, cùng thứ tự ref như
# `resolve_tip` của lõi): tip nhích vì worker khác góp vào thì commit của họ
# không bị đếm. Không fetch: lõi chặn cây chính (rc 7) TRƯỚC mọi fetch, adapter
# không được làm ngược lại; ref `origin/intent/*` local luôn ≥ điểm cắt vì nhánh
# con được cắt từ chính nó. Không phân giải được gì thì để lõi báo lỗi của nó.
SUB="" CWD="." INTENT="" BRANCH="" IREF="" SLUG="" LB=0 NOISSUE=0 ARGS=()
while [ $# -gt 0 ]; do
    a="$1"; shift
    case "$a" in
        --load-bearing) [ "$SUB" = integrate ] && { LB=1; continue; } ;;
        --no-issue) [ "$SUB" = create-intent ] && { NOISSUE=1; continue; } ;;
        --cwd=*) CWD="${a#*=}" ;;
        --cwd) ARGS+=("$a"); CWD="${1:-.}"; a="${1:-}"; shift || true ;;
        --intent=*) INTENT="${a#*=}" ;;
        --intent) ARGS+=("$a"); INTENT="${1:-}"; a="${1:-}"; shift || true ;;
        --branch=*) BRANCH="${a#*=}" ;;
        --branch) ARGS+=("$a"); BRANCH="${1:-}"; a="${1:-}"; shift || true ;;
        --slug=*) SLUG="${a#*=}" ;;
        --slug) ARGS+=("$a"); SLUG="${1:-}"; a="${1:-}"; shift || true ;;
        --intent-ref=*) IREF="${a#*=}" ;;
        --intent-ref) ARGS+=("$a"); IREF="${1:-}"; a="${1:-}"; shift || true ;;
        create-intent|worker-branch|integrate) [ -z "$SUB" ] && SUB="$a" ;;
    esac
    ARGS+=("$a")
done

if [ "$SUB" = integrate ] && [ "$LB" -eq 0 ] && [ -n "$INTENT" ]; then
    gitc() { git -C "$CWD" "$@" 2>/dev/null; }
    [ -n "$BRANCH" ] || BRANCH=$(gitc rev-parse --abbrev-ref HEAD) || BRANCH=""
    # `branch.intent_prefix` of the repo's config (default `intent/`); an invalid config is rc 64 here, as in the core
    PFX=$(python3 "$HERE/sdlc_config.py" get branch.intent_prefix --root "$CWD" 2>&1) || die "$PFX" 64
    I="${INTENT#/}"; I="${I%/}"; case "$I" in "$PFX"*) ;; *) I="$PFX$I" ;; esac
    TIP=""
    for c in ${IREF:+"$IREF"} "origin/$I" "$I"; do
        gitc rev-parse --verify --quiet "$c^{commit}" >/dev/null && { TIP="$c"; break; }
    done
    if [ -n "$TIP" ] && [ -n "$BRANCH" ] && [ "$BRANCH" != HEAD ] \
       && CUT=$(gitc merge-base "$TIP" "$BRANCH") \
       && N=$(gitc rev-list --count "$CUT..$BRANCH") && [ "$N" -gt 1 ]; then
        printf '%s\n' "$(say --root "$(gitc rev-parse --show-toplevel || echo "$CWD")" ib.sh.task_commits "$BRANCH" "$N" "${CUT:0:12}" "$TIP")" >&2
        exit 8
    fi
fi

# -----------------------------------------------------------------------------
# `create-intent`: máy tạo issue theo dõi MẶC ĐỊNH — kênh Claude Code
# -----------------------------------------------------------------------------
# Quyết định "máy tạo, không dựa vào luật nhắc" thuộc adapter này, không thuộc lõi dùng
# chung với người dùng khác của nó (lõi mặc định KHÔNG tạo issue — xem `--issue` ở
# `intent_branch.py`, để gọi lõi trực tiếp, kể cả trong test, không bất ngờ
# đụng mạng/gh). `--no-issue` bị TIÊU THỤ ở trên, không chuyển xuống lõi.
if [ "$SUB" = create-intent ] && [ "$NOISSUE" -eq 0 ]; then
    ARGS+=(--issue)
fi

# Không ghi __pycache__ vào thư mục plugin (có thể là bản cài trong cache).
# `create-intent` that succeeded records the intent's spec stage (stage-signal.sh: `session-notify` in a sandbox, the local state
# file without one; it never fails this script). The core is no longer exec'd, so its rc is kept.
signal() { bash "$HERE/stage-signal.sh" "$@" || true; }
# Only `create-intent` has something to do after the core; every other subcommand still `exec`s it (a signal to this pid reaches it).
[ "$SUB" = create-intent ] || PYTHONDONTWRITEBYTECODE=1 exec python3 "$CORE" "${ARGS[@]}"
PYTHONDONTWRITEBYTECODE=1 python3 "$CORE" "${ARGS[@]}"; RC=$?
# the stem is the slug without `branch.intent_prefix` (the core accepts `--slug intent/<slug>`); no `--slug` spelled out: no signal
PFX=$(python3 "$HERE/sdlc_config.py" get branch.intent_prefix --root "$CWD" 2>/dev/null) || PFX="intent/"
SLUG="${SLUG#"$PFX"}"
[ "$RC" -eq 0 ] && [ -n "$SLUG" ] && signal spec "$SLUG"
exit "$RC"
