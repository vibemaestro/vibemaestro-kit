#!/bin/bash
# =============================================================================
# Plugin vibemaestro-sdlc — BẢN CÀI TRONG CACHE chạy được (không dựa vào cây nguồn)
# =============================================================================
# Chạy: bash tests/test-ban-cai.sh
#       PLUGIN_REQUIRE_CLAUDE=1 bash …   # thiếu `claude` thì ĐỎ (mặc định: SKIP kêu to)
#
# Vì sao có suite riêng: các suite khác chạy plugin từ cây nguồn hoặc từ bản chép nguyên thư mục — nơi symlink hay đường
# dẫn tương đối trỏ ra ngoài plugin vẫn "chạy được". Bản cài thật (`claude plugin install`) CHỈ chép thư mục plugin vào
# cache và bỏ symlink trỏ ra ngoài. Ca duy nhất bắt được lỗi đó là chạy hook và skill TỪ BẢN CACHE, sau khi xoá cả cây
# nguồn. Pod/CI không có login `claude` thật nên ta chạy chính lệnh `command` của hooks.json với CLAUDE_PLUGIN_ROOT = installPath.
# Môi trường sạch: không hub, HOME trống.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
# shellcheck source=fixtures/flow.sh
. "$HERE/fixtures/flow.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
if ! command -v claude >/dev/null 2>&1; then
  if [ "${PLUGIN_REQUIRE_CLAUDE:-}" = 1 ]; then bad "không có 'claude' mà PLUGIN_REQUIRE_CLAUDE=1"; else
    echo "  SKIP *** thiếu 'claude' trên máy này — suite bản cài KHÔNG chạy ***"; fi
  summary; exit $?
fi
export CLAUDE_CONFIG_DIR="$TMP/cfg"; mkdir -p "$CLAUDE_CONFIG_DIR"
export GH_LOG="$TMP/gh.log"; : > "$GH_LOG"
BIN="$TMP/bin"; mk_gh "$BIN"; export PATH="$BIN:$PATH"
cl() { claude "$@" 2>&1; }

# install_from <thư mục repo> <config dir> → in installPath
install_from() {
  CLAUDE_CONFIG_DIR="$2" claude plugin marketplace add "$1" >/dev/null 2>&1
  CLAUDE_CONFIG_DIR="$2" claude plugin install vibemaestro-sdlc@vibemaestro >/dev/null 2>&1
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["plugins"]["vibemaestro-sdlc@vibemaestro"][0]["installPath"])' "$2/plugins/installed_plugins.json"
}

SRC="$TMP/src"; mkdir -p "$SRC"; (cd "$SRC_ROOT" && tar --exclude=.git -cf - .) | tar -x -C "$SRC"; find "$SRC" -name __pycache__ -prune -exec rm -rf {} +
IP=$(install_from "$SRC" "$CLAUDE_CONFIG_DIR")
nonempty "$IP" "cài từ thư mục: có installPath"
[ -d "$IP" ] && ok "bản cài có thật: $IP" || bad "installPath không tồn tại"
case "$IP" in "$SRC"*) bad "installPath nằm trong cây nguồn — không phải bản cache";; *) ok "bản cài nằm trong cache của CLI, không phải cây nguồn";; esac
rm -rf "$SRC"; [ ! -e "$SRC" ] && ok "đã XOÁ cây nguồn: từ đây chỉ còn bản cache" || bad "không xoá được cây nguồn"
for f in rules/workflow-core.instructions.md scripts/vsdlc.py scripts/rules.py scripts/hookout.py scripts/kb.py scripts/current_state.py scripts/intent_branch.py scripts/open_pr.py scripts/intent-branch.sh scripts/open-pr.sh skills/ship/SKILL.md hooks/hooks.json; do
  [ -f "$IP/$f" ] && ok "bản cache có $f" || bad "bản cache THIẾU $f"
done

HOOKS="$IP/hooks/hooks.json"
APP="$TMP/app"; mk_app "$APP"
S=$(sid)
LC=$(ctx "$(printf '%s' "$(p_start "$S")" | CLAUDE_PLUGIN_ROOT="$IP" CLAUDE_PROJECT_DIR="$APP" bash -c "$(hook_cmds "$HOOKS" SessionStart '' | sed -n 1p)" 2>/dev/null)")
BO=$(printf '%s' "$(p_start "$S")" | CLAUDE_PLUGIN_ROOT="$IP" CLAUDE_PROJECT_DIR="$APP" bash -c "$(hook_cmds "$HOOKS" SessionStart '' | sed -n 2p)" 2>/dev/null)
BC=$(ctx "$BO")
REALLAST=$(grep -v '^[[:space:]]*$' "$IP/rules/workflow-core.instructions.md" | tail -1)
nonempty "$LC" "SessionStart từ bản cache (lõi): có nội dung"
has "$LC" "${REALLAST:0:60}" "bản cache: lõi quy trình giao ĐỦ (dòng cuối có mặt)"
has "$BC" 'git-process.instructions.md' "bản cache: danh mục luật có git-process"
has "$BC" "vibemaestro-sdlc:intake" "bản cache: nhắc skill intake"
has "$BC" 'kb/current-state.md' "bản cache: nhắc kb/ của repo app"
hasnt "$LC$BC" 'WARNING' "bản cache: KHÔNG cảnh báo nào (không thiếu hub, không thiếu luật)"
hasnt "$LC$BC" 'hub' "bản cache, HOME trống, không hub: không một chữ 'hub'"
empty "$(sysm "$BO")" "bản cache: systemMessage rỗng"
O=$(printf '%s' "$(p_edit "$S" "$APP/src/main.ts")" | CLAUDE_PLUGIN_ROOT="$IP" CLAUDE_PROJECT_DIR="$APP" bash -c "$(hook_cmds "$HOOKS" PreToolUse Edit)" 2>/dev/null)
has "$O" "$APP/kb/decisions/d-app.md" "bản cache: PreToolUse Edit nhắc kb/decisions của repo app"
O=$(printf '%s' "$(p_bash "$S" 'git worktree add .claude/worktrees/x origin/main')" | CLAUDE_PLUGIN_ROOT="$IP" CLAUDE_PROJECT_DIR="$APP" bash -c "$(hook_cmds "$HOOKS" PreToolUse Bash)" 2>/dev/null)
has "$(ctx "$O")" "$IP/rules/git-process.instructions.md" "bản cache: PreToolUse Bash nhắc luật bằng đường dẫn tuyệt đối TRONG bản cache"

echo "== skill chạy từ bản cache: init-kb → intake → ship (gh giả) =="
APPR="$TMP/app-remote"; mk_app_remote "$APPR"
O=$(cd "$APPR" && python3 "$IP/scripts/kb.py" init 2>&1); eq "$?" 0 "kb.py init từ bản cache: rc 0"
O=$(cd "$APPR" && python3 "$IP/scripts/kb.py" check current-state 2>&1); eq "$?" 0 "kb.py check current-state từ bản cache: rc 0 ($O)"
git_ -C "$APPR" add -A; git_ -C "$APPR" commit -qm kb; git_ -C "$APPR" push -q origin main; git_ -C "$APPR" fetch -q origin
WT="$APPR/.claude/worktrees/w"; git_ -C "$APPR" worktree add -q --detach "$WT" origin/main
(cd "$WT" && python3 "$IP/scripts/kb.py" new intent viec --date 2026-10-11 >/dev/null 2>&1)
printf -- '---\ndescription: "mô tả"\n---\n\nLời người đặt.\n' > "$WT/kb/intent/2026-10-11-viec.md"
O=$(cd "$WT" && bash "$IP/scripts/intent-branch.sh" create-intent --slug 2026-10-11-viec 2>&1); rc=$?
eq "$rc" 0 "intent-branch.sh create-intent từ bản cache: rc 0 ($O)"
eq "$(git_ -C "$WT" rev-parse --abbrev-ref HEAD)" "intent/2026-10-11-viec" "…branch intent tạo trong worktree repo app"
has "$(cat "$WT/kb/intent/2026-10-11-viec.md")" 'issue: 42' "…issue (gh giả) ghi vào intent"
printf 'Sửa gì và vì sao.\n' > "$TMP/sum.md"; printf '$ echo ok\nok\n' > "$TMP/ev.txt"
O=$(cd "$WT" && bash "$IP/scripts/open-pr.sh" --title "docs(kb): thử" --summary "$TMP/sum.md" --evidence "$TMP/ev.txt" --base main --draft --dry-run 2>&1); rc=$?
eq "$rc" 0 "open-pr.sh --dry-run từ bản cache: rc 0"
has "$O" 'Closes #42' "…thân PR dry-run có 'Closes #42' (tự đọc từ intent của repo app)"
eq "$(find "$IP" -name __pycache__ | wc -l | tr -d ' ')" 0 "chạy xong: bản cache không có __pycache__"

echo "== ĐỐI CHỨNG DƯƠNG: plugin dựa vào thứ NGOÀI thư mục plugin thì bản cache chạy ĐỎ =="
# Plugin xấu: rules/ là symlink tới thư mục ngoài plugin. Chạy từ cây nguồn thì mọi thứ "bình thường";
# cài vào cache thì symlink bị bỏ và hook phải nói to.
SRCB="$TMP/src-bad"; mkdir -p "$SRCB"; (cd "$SRC_ROOT" && tar --exclude=.git -cf - .) | tar -x -C "$SRCB"
mkdir -p "$TMP/ngoai-rules"; cp "$SRCB/plugins/vibemaestro-sdlc/rules/"*.md "$TMP/ngoai-rules/"
rm -rf "$SRCB/plugins/vibemaestro-sdlc/rules"; ln -s "$TMP/ngoai-rules" "$SRCB/plugins/vibemaestro-sdlc/rules"
SRCOUT=$(printf '%s' "$(p_start "$(sid)")" | CLAUDE_PLUGIN_ROOT="$SRCB/plugins/vibemaestro-sdlc" CLAUDE_PROJECT_DIR="$APP" bash -c "$(hook_cmds "$SRCB/plugins/vibemaestro-sdlc/hooks/hooks.json" SessionStart '' | sed -n 1p)" 2>/dev/null)
hasnt "$(ctx "$SRCOUT")" 'WARNING' "plugin xấu chạy từ cây nguồn: trông BÌNH THƯỜNG (đây là cái bẫy mà suite này tồn tại để bắt)"
IPB=$(install_from "$SRCB" "$TMP/cfg-bad")
[ ! -e "$IPB/rules" ] && ok "bản cache của plugin xấu: symlink rules/ bị BỎ" || bad "cache vẫn có rules/ của plugin xấu"
BADOUT=$(printf '%s' "$(p_start "$(sid)")" | CLAUDE_PLUGIN_ROOT="$IPB" CLAUDE_PROJECT_DIR="$APP" bash -c "$(hook_cmds "$IPB/hooks/hooks.json" SessionStart '' | sed -n 1p)" 2>/dev/null)
has "$(ctx "$BADOUT")" 'WARNING' "…và hook chạy từ bản cache NÓI TO (WARNING): suite này bắt được lỗi phụ thuộc ngoài plugin"
echo; summary
