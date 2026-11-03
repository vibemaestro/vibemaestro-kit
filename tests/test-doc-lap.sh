#!/bin/bash
# =============================================================================
# Plugin vibemaestro-sdlc — ĐỘC LẬP: không hub, không ~/gitops, không biến cấu hình hub
# =============================================================================
# Chạy: bash tests/test-doc-lap.sh
#
# Yêu cầu: phiên mở ở repo app, KHÔNG có hub nào trên máy → SessionStart giao lõi quy trình + danh mục luật + lời nhắc
# kb/ mà không cảnh báo thiếu hub; intake/ship chạy được qua lõi nằm trong plugin; mã hook/skill không đọc đường dẫn nào
# ngoài thư mục plugin và repo đích.
#
#   1. QUÉT TĨNH: không dấu vết hub, kênh kanban hay đường dẫn máy chủ trong mã hook/skill/luật và hai lõi (không còn ngoại lệ);
#   2. HÀNH VI không hub: HOME trống, không VIBEMAESTRO_HUB → không cảnh báo, có lõi + danh mục;
#   3. HUB MỒI: đặt VIBEMAESTRO_HUB, CLAUDE_PLUGIN_OPTION_HUB_PATH và ~/gitops cùng trỏ vào một "hub giả có lỗi" (luật mâu
#      thuẫn, script nổ) → đầu ra của plugin KHÔNG đổi và không script mồi nào chạy.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
# shellcheck source=fixtures/flow.sh
. "$HERE/fixtures/flow.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
HOOKS="$PLUGIN/hooks/hooks.json"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
export GH_LOG="$TMP/gh.log"; : > "$GH_LOG"
BIN="$TMP/bin"; mk_gh "$BIN"; export PATH="$BIN:$PATH"
# DOC_LAP_SECTIONS="1 2 2b" runs only those sections; unset runs everything, then section 5.
# The path-independence case (section 5) runs this file on a copy with the selector set, which is how it avoids recursion.
want() { case " ${DOC_LAP_SECTIONS:-1 2 2b 3} " in *" $1 "*) return 0;; esac; return 1; }
# scrub <text> — replace the checkout and scratch paths by fixed words, so a check on the TEXT of an output never reads the
# path it was run from (a worktree named hub-x, or a checkout under ~/github, contains the substring `hub`).
scrub() {
  local s=$1 r1 r2 t1 t2
  r1=$SRC_ROOT; r2=$(cd "$SRC_ROOT" && pwd -P); t1=$TMP; t2=$(cd "$TMP" && pwd -P)
  s=${s//"$r2"/<src>}; s=${s//"$r1"/<src>}; s=${s//"$t2"/<tmp>}; s=${s//"$t1"/<tmp>}
  printf '%s' "$s"
}

echo "== 1. quét tĩnh: mã hook, skill, luật, adapter không nhắc tới hub / ~/gitops / sandbox-session =="
# Matched case-insensitively (`grep -i`): a case-sensitive pattern caught `Kanban` only and let `KANBAN`, `kanban`
# and `_KGW_GIT` through. Internal organisation and product names are not listed here: the term list is private and
# `scripts/scan-internal-terms.sh` owns it.
FORBID='VIBEMAESTRO_HUB|hub_path|hub-run|resolve_hub|sandbox-session|gitops|\.github/hooks|\.github/instructions|kubeconfig|claude-config|kanban|_kgw_'
# Không còn ngoại lệ: hai lõi (open_pr.py, intent_branch.py) được quét như mọi file khác — chúng không còn mang gì của hub hay của kênh kanban.
# scan_tree <root> — các dòng của cây plugin tại <root> khớp mẫu cấm hoặc chữ 'hub' (mỗi dòng một vấn đề); rỗng = sạch
# Every plugin under plugins/ is scanned with the whole pattern.
scan_tree() {  # scan_tree <root> — one line per problem in every plugin directory, empty when clean
  local root=$1 files f
  files=$(cd "$root" && find plugins -type f ! -name '*.pyc' | sort)
  for f in $files; do
    ( cd "$root" && { grep -InEi "$FORBID" "$f"; grep -Inw -i 'hub' "$f"; } | sed "s|^|$f:|" )
  done
}
SCAN_FILES=$(cd "$SRC_ROOT" && find plugins -type f ! -name '*.pyc' | sort)
nonempty "$SCAN_FILES" "đối chứng dụng cụ: danh sách file quét không rỗng"
case "$SCAN_FILES" in *plugins/vibemaestro-sdlc/scripts/open_pr.py*intent_branch.py*|*plugins/vibemaestro-sdlc/scripts/intent_branch.py*open_pr.py*) ok "hai lõi nằm trong danh sách quét (không còn ngoại lệ)";; *) bad "hai lõi không nằm trong danh sách quét";; esac
empty "$(scan_tree "$SRC_ROOT")" "plugin (kể cả hai lõi): 0 dòng khớp '$FORBID' và không một chữ 'hub'"
case "$SCAN_FILES" in *plugins/vibemaestro-brain/bin/brain*) ok "the brain plugin is in the scan list";; *) bad "the brain plugin is not scanned";; esac
# đối chứng dương cho phép quét: một dòng thử bị bắt
printf 'x ~/gitops/y\nVIBEMAESTRO_HUB=z\nhub-run.py\nKanban\nkanban\n_KGW_GIT\nHUB_PATH\nKUBECONFIG\n' | grep -ciE "$FORBID" | { read -r c; eq "$c" 8 "instrument control: the scan pattern catches all eight probe strings, in any case"; }
# bộ test cũng không với tay ra ngoài repo: không đường dẫn ~/gitops, không đọc cây cha của repo
test_hits() { (cd "$1" && grep -rInE '~/gitops|\$HOME/gitops|SRC_ROOT/\.\./|/home/agent' tests | grep -v 'test-doc-lap.sh' || true); }
TEST_HITS=$(test_hits "$SRC_ROOT")
empty "$TEST_HITS" "bộ test: không đường dẫn tới ~/gitops hay cây ngoài repo (ngoại lệ: chính file này, nơi ~/gitops là DỮ LIỆU của hub mồi)"
DX="$TMP/doc-lap-home"; mkdir -p "$DX/tests"
printf "X=/home/agent/y\n" > "$DX/tests/test-cai-dat.sh"; printf "Y=~/gitops/z\n" > "$DX/tests/other.sh"
eq "$(test_hits "$DX" | wc -l | tr -d ' ')" 2 "control: a /home/agent line and a ~/gitops line in two test files are both hits"
# không symlink, không đường dẫn tương đối trỏ ra khỏi plugin trong mã chạy
UPREL=$(cd "$SRC_ROOT" && grep -rInE '\.\./\.\.' plugins/vibemaestro-sdlc/scripts plugins/vibemaestro-sdlc/hooks --include='*.py' --include='*.sh' --include='*.json' | grep -v -E '^\S+:\s*[0-9]+:\s*#' || true)
empty "$UPREL" "mã hook/script không dùng '../..' để với ra ngoài thư mục plugin"

echo "== 2. hành vi KHÔNG hub: HOME trống, không VIBEMAESTRO_HUB =="
APP="$TMP/app"; mk_app "$APP"
[ -z "$(ls -A "$HOME")" ] && ok "HOME trống ($HOME)" || bad "HOME không trống"
[ -z "${VIBEMAESTRO_HUB:-}" ] && [ -z "${CLAUDE_PLUGIN_OPTION_HUB_PATH:-}" ] && ok "VIBEMAESTRO_HUB và CLAUDE_PLUGIN_OPTION_HUB_PATH không đặt" || bad "biến hub còn đặt"
[ ! -e "$HOME/gitops" ] && ok "không có ~/gitops" || bad "có ~/gitops"
run_session() {  # run_session <plugin dir> <repo> → "lõi\x1f danh mục\x1f sysmsg" (hai hook SessionStart)
  local pl=$1 repo=$2 s; s=$(sid)
  local a b
  a=$(printf '%s' "$(p_start "$s")" | CLAUDE_PLUGIN_ROOT="$pl" CLAUDE_PROJECT_DIR="$repo" bash -c "$(hook_cmds "$pl/hooks/hooks.json" SessionStart '' | sed -n 1p)" 2>/dev/null)
  b=$(printf '%s' "$(p_start "$s")" | CLAUDE_PLUGIN_ROOT="$pl" CLAUDE_PROJECT_DIR="$repo" bash -c "$(hook_cmds "$pl/hooks/hooks.json" SessionStart '' | sed -n 2p)" 2>/dev/null)
  printf '%s' "$a"; printf '\x1f'; printf '%s' "$b"
}
OUT=$(run_session "$PLUGIN" "$APP")
LC=$(ctx "${OUT%%$'\x1f'*}"); BC=$(ctx "${OUT#*$'\x1f'}"); SYS=$(sysm "${OUT%%$'\x1f'*}")$(sysm "${OUT#*$'\x1f'}")
REALLAST=$(grep -v '^[[:space:]]*$' "$PLUGIN/rules/$CORE_NAME" | tail -1)
has "$LC" "${REALLAST:0:60}" "lõi quy trình tới phiên (dòng cuối có mặt)"
has "$BC" 'git-process.instructions.md' "danh mục luật tới phiên (có git-process)"
has "$BC" 'kb/current-state.md' "lời nhắc kb/ tới phiên"
hasnt "$LC$BC$SYS" 'WARNING' "không cảnh báo nào"
hasnt "$(scrub "$LC$BC$SYS")" 'hub' "không một chữ 'hub' (không cảnh báo thiếu hub), đo trên văn bản đã bỏ đường dẫn checkout"
empty "$SYS" "systemMessage rỗng"
APP0="$TMP/app-khong-kb"; mk_app "$APP0" 0
BC0=$(ctx "$(run_session "$PLUGIN" "$APP0" | sed 's/.*\x1f//')")
has "$BC0" 'vibemaestro-sdlc:init-kb' "repo chưa có kb/: nhắc init-kb (không hub vẫn chạy)"

if want 2b; then
echo "== 2b. skill intake → ship qua lõi trong plugin, không hub (gh giả) =="
APPR="$TMP/app-remote"; mk_app_remote "$APPR"
(cd "$APPR" && python3 "$PLUGIN/scripts/kb.py" init >/dev/null 2>&1); git_ -C "$APPR" add -A; git_ -C "$APPR" commit -qm kb; git_ -C "$APPR" push -q origin main; git_ -C "$APPR" fetch -q origin
WT="$APPR/.claude/worktrees/w"; git_ -C "$APPR" worktree add -q --detach "$WT" origin/main
(cd "$WT" && python3 "$PLUGIN/scripts/kb.py" new intent viec --date 2026-10-11 >/dev/null 2>&1)
printf -- '---\ndescription: "mô tả"\n---\n\nLời người đặt.\n' > "$WT/kb/intent/2026-10-11-viec.md"
O=$(cd "$WT" && bash "$PLUGIN/scripts/intent-branch.sh" create-intent --slug 2026-10-11-viec 2>&1); eq "$?" 0 "intake: create-intent không hub: rc 0 ($O)"
eq "$(git_ -C "$WT" rev-parse --abbrev-ref HEAD)" "intent/2026-10-11-viec" "intake: branch intent/2026-10-11-viec tạo ở repo app"
has "$(cat "$WT/kb/intent/2026-10-11-viec.md")" 'issue: 42' "intake: issue (gh giả) ghi vào intent"
printf 'Sửa gì và vì sao.\n' > "$TMP/sum.md"; printf '$ echo ok\nok\n' > "$TMP/ev.txt"
O=$(cd "$WT" && bash "$PLUGIN/scripts/open-pr.sh" --title "docs(kb): thử" --summary "$TMP/sum.md" --evidence "$TMP/ev.txt" --base main --draft --dry-run 2>&1); eq "$?" 0 "ship: open-pr.sh --draft --dry-run không hub: rc 0"
has "$O" 'Closes #42' "ship: thân PR dry-run có 'Closes #42'"
has "$O" '"draft": true' "ship: payload là PR draft"

fi
if want 3; then
echo "== 3. hub MỒI: plugin không đọc, không chạy bất cứ thứ gì ở đó =="
BAIT="$TMP/bait"; mk_bait_hub "$BAIT"
[ -f "$BAIT/.github/hooks/instructions-for-path.py" ] && [ -f "$BAIT/.github/instructions/$CORE_NAME" ] && ok "dụng cụ: hub mồi có đủ bố cục mà hub cũ đòi" || bad "hub mồi thiếu bố cục"
# đối chứng dụng cụ: mồi THẬT SỰ nổ khi bị chạy / mang dấu khi bị đọc
python3 "$BAIT/.github/hooks/instructions-for-path.py" >/dev/null 2>&1; eq "$?" 3 "đối chứng dụng cụ: script mồi nổ rc 3 khi bị chạy"
[ -e "$BAIT/bait-ran" ] && ok "đối chứng dụng cụ: script mồi để lại file bait-ran khi bị chạy (phép kiểm 'không chạy' có nghĩa)" || bad "script mồi không để lại vết"
rm -f "$BAIT/bait-ran"
bait_probe() {  # bait_probe <plugin dir> — in các vấn đề (mỗi dòng một vấn đề); rỗng = plugin độc lập khỏi hub mồi
  local pl=$1 out lc bc app="$TMP/probe-app" rc s a e b
  rm -rf "$app" "$BAIT/bait-ran"; mk_app "$app"
  mkdir -p "$HOME"; rm -rf "$HOME/gitops"; cp -r "$BAIT" "$HOME/gitops"; rm -f "$HOME/gitops/bait-ran"
  export VIBEMAESTRO_HUB="$BAIT" CLAUDE_PLUGIN_OPTION_HUB_PATH="$BAIT"
  s=$(sid)
  a=$(printf '%s' "$(p_start "$s")" | CLAUDE_PLUGIN_ROOT="$pl" CLAUDE_PROJECT_DIR="$app" bash -c "$(hook_cmds "$pl/hooks/hooks.json" SessionStart '' | sed -n 1p)" 2>/dev/null)
  b=$(printf '%s' "$(p_start "$s")" | CLAUDE_PLUGIN_ROOT="$pl" CLAUDE_PROJECT_DIR="$app" bash -c "$(hook_cmds "$pl/hooks/hooks.json" SessionStart '' | sed -n 2p)" 2>/dev/null)
  e=$(printf '%s' "$(p_edit "$s" "$app/src/main.ts")" | CLAUDE_PLUGIN_ROOT="$pl" CLAUDE_PROJECT_DIR="$app" bash -c "$(hook_cmds "$pl/hooks/hooks.json" PreToolUse Edit)" 2>/dev/null)
  rc=$(printf '%s' "$(p_bash "$s" 'ls -la')" | CLAUDE_PLUGIN_ROOT="$pl" CLAUDE_PROJECT_DIR="$app" bash -c "$(hook_cmds "$pl/hooks/hooks.json" PreToolUse Bash)" 2>/dev/null; echo "rc=$?")
  out="$a$b$e$rc"
  unset VIBEMAESTRO_HUB CLAUDE_PLUGIN_OPTION_HUB_PATH
  case "$out" in *BAIT-HUB*) echo "đầu ra hook chứa dấu BAIT-HUB (plugin đã đọc hub mồi)";; esac
  case "$out" in *'"permissionDecision": "deny"'*) echo "hub mồi (luật chặn mọi thứ) làm hook deny";; esac
  case "$a$b" in *'WARNING'*) echo "SessionStart cảnh báo (WARNING) dù không hub";; esac
  [ -n "$a" ] || echo "hook lõi SessionStart không in gì"
  [ -n "$b" ] || echo "hook danh mục SessionStart không in gì"
  case "$a" in *"$REALLAST_PROBE"*) ;; *) echo "lõi quy trình của plugin KHÔNG tới phiên";; esac
  [ ! -e "$BAIT/bait-ran" ] || echo "script của hub mồi đã bị chạy (bait-ran)"
  [ ! -e "$HOME/gitops/bait-ran" ] || echo "script của ~/gitops mồi đã bị chạy"
  # intake qua lõi của plugin, hub mồi có sẵn scripts/intent-branch.sh để bị gọi nhầm
  local r="$TMP/probe-remote"; rm -rf "$r" "$r.git"; mk_app_remote "$r"; (cd "$r" && python3 "$pl/scripts/kb.py" init >/dev/null 2>&1)
  git_ -C "$r" add -A; git_ -C "$r" commit -qm kb; git_ -C "$r" push -q origin main; git_ -C "$r" fetch -q origin
  git_ -C "$r" worktree add -q --detach "$r/.claude/worktrees/w" origin/main
  (cd "$r/.claude/worktrees/w" && python3 "$pl/scripts/kb.py" new intent viec --date 2026-10-11 >/dev/null 2>&1)
  printf -- '---\ndescription: "m"\n---\n\nx\n' > "$r/.claude/worktrees/w/kb/intent/2026-10-11-viec.md"
  (cd "$r/.claude/worktrees/w" && VIBEMAESTRO_HUB="$BAIT" bash "$pl/scripts/intent-branch.sh" create-intent --slug 2026-10-11-viec >/dev/null 2>&1) \
    || echo "intake (intent-branch.sh create-intent) không chạy được nếu hub mồi có mặt"
  [ ! -e "$BAIT/bait-ran" ] || echo "intake đã chạy script của hub mồi"
  rm -f "$BAIT/bait-ran"
  # ship qua adapter open-pr.sh: hub mồi cũng có sẵn scripts/open-pr.sh để bị gọi nhầm. Hai nhánh của adapter
  # (--dry-run và nhánh `gh`) đều phải chạy lõi của plugin; một nhánh thôi thì phá thử chèn ở nhánh kia vẫn lọt.
  local w="$r/.claude/worktrees/w" po
  printf 'Sửa gì và vì sao.\n' > "$TMP/probe-sum.md"; printf '$ echo ok\nok\n' > "$TMP/probe-ev.txt"
  po=$(cd "$w" && VIBEMAESTRO_HUB="$BAIT" bash "$pl/scripts/open-pr.sh" --title "docs(kb): thử" --summary "$TMP/probe-sum.md" \
        --evidence "$TMP/probe-ev.txt" --base main --draft --dry-run 2>&1) \
    || echo "ship (open-pr.sh --dry-run) không chạy được nếu hub mồi có mặt"
  case "$po" in *'Closes #42'*) ;; *) echo "ship (open-pr.sh --dry-run) không dựng thân PR của plugin khi hub mồi có mặt";; esac
  [ ! -e "$BAIT/bait-ran" ] || echo "ship (--dry-run) đã chạy script của hub mồi"
  rm -f "$BAIT/bait-ran"
  # OPEN_PR_LINK_WAIT_S=0: the fake gh reports no closing issue, so the core re-reads ten times and, left at its default, sleeps 2 s
  # between reads (about 18 s per probe, twelve probes). The reads still happen; only the pause between them goes.
  po=$(cd "$w" && VIBEMAESTRO_HUB="$BAIT" OPEN_PR_LINK_WAIT_S=0 bash "$pl/scripts/open-pr.sh" --title "docs(kb): thử" --summary "$TMP/probe-sum.md" \
        --evidence "$TMP/probe-ev.txt" --base main --draft 2>&1) \
    || echo "ship (open-pr.sh, nhánh gh) không chạy được nếu hub mồi có mặt"
  [ "$(printf '%s\n' "$po" | tail -1)" = 7 ] || echo "ship (open-pr.sh, nhánh gh) không in số PR (7, từ gh giả) khi hub mồi có mặt"
  case "$po" in *BAIT-HUB*) echo "ship (nhánh gh): đầu ra chứa dấu BAIT-HUB (plugin đã chạy hub mồi)";; esac
  [ ! -e "$BAIT/bait-ran" ] || echo "ship (nhánh gh) đã chạy script của hub mồi"
  rm -f "$BAIT/bait-ran"
}
REALLAST_PROBE="${REALLAST:0:60}"
PROBLEMS=$(bait_probe "$PLUGIN")
empty "$PROBLEMS" "plugin THẬT với VIBEMAESTRO_HUB + CLAUDE_PLUGIN_OPTION_HUB_PATH + ~/gitops cùng trỏ hub mồi: đầu ra sạch, không script mồi nào chạy"

fi

if [ -z "${DOC_LAP_SECTIONS:-}" ]; then
echo "== 5. the guard does not depend on the checkout path, and the network shims are alive =="
# The copy holds the tracked and untracked files of this checkout (not .git, not .claude/worktrees) under a path that
# contains both `hub` and `github`. Sections 1, 2 and 2b of the copy's own file run there; they read the SessionStart output,
# which carries the plugin path, so a check that reads the path would be red here (it was, on origin/main).
# copy_repo <dest> — the tracked and untracked (not ignored) files that exist now; without a git checkout (a tarball), everything but .git and worktrees.
copy_repo() {
  if git -C "$SRC_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    (cd "$SRC_ROOT" && git ls-files -z -co --exclude-standard | while IFS= read -r -d '' f; do [ -e "$f" ] && printf '%s\0' "$f"; done | tar --null -T - -cf -) | tar -x -C "$1"
  else
    (cd "$SRC_ROOT" && tar --exclude=.git --exclude=.claude -cf - .) | tar -x -C "$1"
  fi
}
HUBCOPY="$TMP/github/hub-x/clone"; mkdir -p "$HUBCOPY"
copy_repo "$HUBCOPY"
case "$HUBCOPY" in *hub*github*|*github*hub*) ok "instrument: the copy path contains hub and github";; *) bad "instrument: the copy path lacks hub or github: $HUBCOPY";; esac
[ -f "$HUBCOPY/tests/test-doc-lap.sh" ] && [ -f "$HUBCOPY/plugins/vibemaestro-sdlc/scripts/vsdlc.py" ] && ok "instrument: the copy has this suite and the plugin" || bad "instrument: the copy is incomplete"
O=$(env -u SUITE_RESULTS_DIR DOC_LAP_SECTIONS="1 2 2b" bash "$HUBCOPY/tests/test-doc-lap.sh" 2>&1); rc=$?
eq "$rc" 0 "sections 1, 2, 2b of the suite on a copy under a path with hub and github: rc 0 ($(printf '%s' "$O" | grep -c FAIL) FAIL lines)"
has "$(printf '%s\n' "$O" | tail -1)" ' 0 fail' "…and its last line reports 0 fail"
# the shims: each network tool exits 97 and leaves a trace; the guard sees it; the log is reset afterwards
for n in $NET_TOOLS; do
  "$n" probe-argument >/dev/null 2>&1; eq "$?" 97 "shim $n exits 97"
done
O=$(net_guard_empty); rc=$?
eq "$rc" 1 "control: the guard reports a non-empty log after the four calls"
for n in $NET_TOOLS; do has "$O" "$n probe-argument" "…and names $n with its arguments"; done
: > "$NET_LOG"; net_guard_empty >/dev/null; eq "$?" 0 "the guard is empty again once the log is emptied (summary asserts it for this suite)"
fi

echo; summary
