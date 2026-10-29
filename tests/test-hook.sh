#!/bin/bash
# =============================================================================
# Plugin vibemaestro-sdlc — hook ở REPO APP: lõi quy trình, danh mục luật, tra luật theo file/lệnh, nhận ra sandbox
# =============================================================================
# Chạy: bash tests/test-hook.sh
#
# Suite này KHÔNG chạy `claude` và không cần model: hook là script đọc JSON ở stdin, nên ta dựng một bản
# chép plugin với bộ luật GIẢ (mk_plugin) + repo app giả trong thư mục tạm và chạy ĐÚNG chuỗi `command`
# ghi trong hooks/hooks.json (lib.sh). Môi trường sạch: không hub, không VIBEMAESTRO_HUB, HOME trống.
# Mỗi assert có ca đối chứng ngay cạnh: vế dương đi cặp vế âm trong CÙNG trạng thái.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
HOOKS="$PLUGIN/hooks/hooks.json"
[ -f "$HOOKS" ] || { echo "FAIL không có $HOOKS — plugin chưa được dựng"; exit 1; }

TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"

PL="$TMP/plugin"; mk_plugin "$PL"
APP="$TMP/app"; mk_app "$APP"
RULES="$PL/rules"

# vỏ gọi hook: plugin = bản chép giả; repo = $APP
sess_one() {  # sess_one <thứ tự 1..> <sid> — stdout của MỘT command SessionStart
  local c; c=$(hook_cmds "$HOOKS" SessionStart "" | sed -n "${1}p")
  printf '%s' "$(p_start "$2")" | bash -c "$c" 2>/dev/null
}
edit() { run_cmds "$HOOKS" PreToolUse Edit "$(p_edit "$1" "$2")"; }
write_() { run_cmds "$HOOKS" PreToolUse Write "$(p_edit "$1" "$2")"; }
nbedit() { run_cmds "$HOOKS" PreToolUse NotebookEdit "$(p_nb "$1" "$2")"; }
bashc() { run_cmds "$HOOKS" PreToolUse Bash "$(p_bash "$1" "$2")"; }
inapp() { CLAUDE_PROJECT_DIR="$APP" CLAUDE_PLUGIN_ROOT="$PL" "$@"; }

# Every string a hook prints is English. VN is the Vietnamese-letter class of the kit spec.
VN='[ăâđêôơưáàảãạấầẩẫậắằẳẵặéèẻẽẹếềểễệíìỉĩịóòỏõọốồổỗộớờởỡợúùủũụứừửữựýỳỷỹỵ]'
# The count is made by python3, not grep: a byte-oriented grep (GNU grep in the C locale) matches the bytes of "—" or "⚠" as Vietnamese letters.
vncount() { printf '%s' "$1" | python3 -c 'import re, sys; rx = re.compile(sys.argv[1], re.I); print(sum(1 for l in sys.stdin.buffer.read().decode("utf-8", "replace").split("\n") if rx.search(l)))' "$VN"; }
novn() { eq "$(vncount "$1")" 0 "$2: the hook output has no Vietnamese letter"; }
eq "$(vncount 'Bối cảnh')" 1 "instrument: the Vietnamese-letter class sees a Vietnamese word"
eq "$(vncount '⚠ WARNING — plain English → ≤')" 0 "instrument: …and neither English nor its symbols"

echo "== dây: hooks.json khai đúng ba hook =="
eq "$(hook_cmds "$HOOKS" SessionStart '' | grep -c .)" 4 "[I0] SessionStart: 4 command (lõi quy trình / danh mục+nhắc / current-state index, mỗi cái một trần 10.000 ký tự riêng; the update reminder, tests/test-update-check.sh)"
eq "$(hook_cmds "$HOOKS" PreToolUse Edit | grep -c .)" 2 "PreToolUse Edit: 2 commands (the rules, and the settings guard)"
eq "$(hook_cmds "$HOOKS" PreToolUse Write | grep -c .)" 2 "PreToolUse Write: 2 commands (the rules, and the settings guard)"
eq "$(hook_cmds "$HOOKS" PreToolUse NotebookEdit | grep -c .)" 2 "PreToolUse NotebookEdit: 2 commands (the rules, and the settings guard)"
eq "$(hook_cmds "$HOOKS" PreToolUse MultiEdit | grep -c .)" 1 "PreToolUse MultiEdit: 1 command (the settings guard)"
eq "$(hook_cmds "$HOOKS" PreToolUse Bash | grep -c .)" 3 "PreToolUse Bash: 3 commands (the rules, the guard of the owner's baton signature, the settings guard)"
eq "$(hook_cmds "$HOOKS" PreToolUse Read | grep -c .)" 0 "đối chứng: Read không có hook"

echo "== A1: SessionStart ở repo app =="
S=$(sid); L=$(inapp sess_one 1 "$S"); B=$(inapp sess_one 2 "$S")
isjson "$L" && ok "hook lõi in JSON hợp lệ" || bad "hook lõi không in JSON: ${L:0:100}"
isjson "$B" && ok "hook danh mục in JSON hợp lệ" || bad "hook danh mục không in JSON: ${B:0:100}"
LC=$(ctx "$L"); BC=$(ctx "$B")
has "$LC" 'DONG-DAU-LOI-QUY-TRINH' "(a) lõi quy trình: dòng đầu file lõi của plugin có trong phiên"
has "$LC" "$CORE_LAST" "(a) lõi quy trình: dòng CUỐI cũng có — nhận NỘI DUNG, không chỉ con trỏ"
hasnt "$LC" 'description:' "(a) frontmatter không bị in vào lõi"
has "$LC" "$RULES/$CORE_NAME" "(a) lõi quy trình nói nguồn: đường dẫn tuyệt đối tới file lõi trong plugin"
printf '\nDONG-MOI-SUA-SAU\n' >> "$RULES/$CORE_NAME"
has "$(ctx "$(inapp sess_one 1 "$(sid)")")" 'DONG-MOI-SUA-SAU' "(a) đọc từ plugin LÚC CHẠY: sửa file lõi là phiên sau thấy"
mk_core "$PL"
hasnt "$(ctx "$(inapp sess_one 1 "$(sid)")")" 'DONG-MOI-SUA-SAU' "(a) đối chứng: dựng lại lõi thì mất"
has "$BC" 'r-clusters.instructions.md' "(b) danh mục: có luật r-clusters"
has "$BC" 'PL-LUAT-CLUSTERS' "(b) danh mục: có mô tả luật"
has "$BC" 'clusters/**' "(b) danh mục: có applyTo"
has "$(printf '%s\n' "$BC" | grep -F 'r-cmd.instructions.md')" 'applyWhen' "(b) danh mục: luật theo lệnh ghi applyWhen"
hasnt "$(printf '%s\n' "$BC" | grep -F 'r-clusters.instructions.md')" 'applyWhen' "(b) đối chứng: luật theo file không ghi applyWhen"
has "$(printf '%s\n' "$BC" | grep -F 'r-block.instructions.md')" '[BLOCK]' "(b) danh mục: luật level:block có nhãn [CHẶN]"
hasnt "$BC" "$CORE_LAST" "(b) đối chứng: danh mục không lặp thân lõi quy trình"
has "$BC" "$RULES" "(b) danh mục: nói bộ luật nằm ở đâu (đường dẫn tuyệt đối trong plugin)"
has "$BC" 'kb/current-state.md' "(c) repo có kb/: nhắc đọc kb/current-state.md"
has "$BC" '`kb/current-state.md` is the map' "(c) repo có kb/: current-state is the map"
has "$BC" "\`python3 \"$PL/scripts/kb.py\"\`" "(c) repo có kb/: kb.py of this plugin, by its full path"
for w in '`find <words>`' '`list --type intent --status live`' '`outline <file>`'; do has "$BC" "$w" "(c) repo có kb/: names $w"; done
[ -f "$PL/scripts/kb.py" ] && ok "(c) the kb.py path named in the reminder is a file" || bad "(c) the reminder names a kb.py that does not exist"
hasnt "$BC" '2026-10-01-viec-dang-mo' "(c) repo có kb/: no list of files to read (the finders replace it)"
APP2="$TMP/app-khong-kb"; mk_app "$APP2" 0
B2=$(CLAUDE_PROJECT_DIR="$APP2" CLAUDE_PLUGIN_ROOT="$PL" sess_one 2 "$(sid)")
hasnt "$(ctx "$B2")" 'kb/current-state.md' "(c) đối chứng: repo KHÔNG có kb/ thì không nhắc"
nonempty "$(ctx "$B2")" "(c) đối chứng: repo không kb/ vẫn nhận danh mục luật"
hasnt "$LC$BC" 'WARNING' "plugin khoẻ: không cảnh báo nào"
empty "$(sysm "$L")$(sysm "$B")" "plugin khoẻ: systemMessage rỗng"
rm -f "$HOME/.kube/claude-config"; rm -rf "$HOME/.kube"
hasnt "$LC$BC" 'hub' "HOME trống, không hub nào trên máy: không một chữ 'hub' trong lõi/danh mục (không cảnh báo thiếu hub)"

echo "== plugin KHÔNG đụng KUBECONFIG (chi tiết hạ tầng nội bộ đã cắt khỏi plugin) =="
E_ENV="$TMP/envfile"; : > "$E_ENV"
KO=$(CLAUDE_ENV_FILE="$E_ENV" inapp sess_one 2 "$(sid)")
empty "$(cat "$E_ENV")" "có CLAUDE_ENV_FILE: plugin không ghi gì vào đó"
hasnt "$(sysm "$KO")$(ctx "$KO")" 'KUBECONFIG' "không nhắc KUBECONFIG ở bất kỳ đâu (context lẫn systemMessage)"
hasnt "$(sysm "$KO")$(ctx "$KO")" 'claude-config' "không cảnh báo thiếu ~/.kube/claude-config"
KO=$(env -u CLAUDE_ENV_FILE CLAUDE_PROJECT_DIR="$APP" CLAUDE_PLUGIN_ROOT="$PL" bash -c "$(declare -f sess_one hook_cmds p_start); HOOKS='$HOOKS'; sess_one 2 '$(sid)'")
hasnt "$(sysm "$KO")$(ctx "$KO")" 'CLAUDE_ENV_FILE' "không có CLAUDE_ENV_FILE: không nói 'KUBECONFIG chưa được đặt'"
# đối chứng dụng cụ: vỏ này THẤY được việc ghi vào CLAUDE_ENV_FILE nếu có (một lệnh ghi thử)
printf 'export X=1\n' >> "$E_ENV"; nonempty "$(cat "$E_ENV")" "đối chứng dụng cụ: file env ghi được thì đọc thấy (empty ở trên không phải xanh giả)"

echo "== sandbox: nhận ra bằng INTENT_SLUG + SEAT — cùng nội dung, thêm lời nhắc hành vi đầu tiên =="
sbx() {  # sbx <biến=giá trị…> — hook danh mục ở repo app
  env "$@" CLAUDE_PROJECT_DIR="$APP" CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$PL}" bash -c "$(declare -f sess_one hook_cmds p_start); HOOKS='$HOOKS'; sess_one 2 '$(sid)'"
}
SBX_ID="INTENT_SLUG=2026-10-10-viec SEAT=acme-it-ai"
O=$(CLAUDE_ENV_FILE="$E_ENV" sbx $SBX_ID)
isjson "$O" && ok "sandbox: hook vẫn in JSON hợp lệ" || bad "sandbox: hook không in JSON: ${O:0:100}"
hasnt "$(sysm "$O")$(ctx "$O")" 'WARNING' "sandbox: không cảnh báo nào"
has "$(ctx "$O")" 'r-clusters.instructions.md' "sandbox: plugin giao danh mục luật như ngoài sandbox"
has "$(ctx "$O")" 'kb/current-state.md' "sandbox: plugin vẫn nhắc kb/ của repo đang đứng"
LS=$(INTENT_SLUG=2026-10-10-viec SEAT=acme-it-ai inapp sess_one 1 "$(sid)")
has "$(ctx "$LS")" "$CORE_LAST" "sandbox: hook lõi quy trình vẫn giao đủ nội dung"
# A7 trong sandbox: plugin không skill → không nhắc skill nào của plugin
PLS="$TMP/plug-sbx"; cp -r "$PL" "$PLS"; rm -rf "$PLS/skills"
O=$(CLAUDE_PLUGIN_ROOT="$PLS" sbx $SBX_ID)
hasnt "$(ctx "$O")" 'vibemaestro-sdlc:' "sandbox, plugin không có skill: không nhắc skill nào của plugin (A7)"
O=$(sbx $SBX_ID)
has "$(ctx "$O")" 'vibemaestro-sdlc:init-kb' "đối chứng: skill của plugin có mặt thì sandbox cũng được nhắc"

echo "== sandbox: lời nhắc HÀNH VI ĐẦU TIÊN (intake → spec → session-ask → code) =="
# `session-ask` phải ĐO được là có/vắng: máy chạy suite có thể là sandbox (có sẵn session-ask trong PATH), nên ca "vắng" dùng
# PATH đã lọc mọi thư mục chứa session-ask, ca "có" đặt một session-ask giả lên đầu PATH.
ASKBIN="$TMP/askbin"; mkdir -p "$ASKBIN"; printf '#!/bin/sh\nexit 0\n' > "$ASKBIN/session-ask"; chmod +x "$ASKBIN/session-ask"
NOASK_PATH=$(python3 -c '
import os
print(":".join(d for d in os.environ["PATH"].split(":") if not os.access(os.path.join(d, "session-ask"), os.X_OK)))')
[ -z "$(PATH="$NOASK_PATH" command -v session-ask)" ] && ok "dụng cụ: PATH đã lọc không còn session-ask" || bad "dụng cụ: PATH đã lọc vẫn thấy session-ask"
[ -n "$(PATH="$NOASK_PATH" command -v python3)" ] && [ -n "$(PATH="$NOASK_PATH" command -v bash)" ] && [ -n "$(PATH="$NOASK_PATH" command -v git)" ] \
  && ok "dụng cụ: PATH đã lọc vẫn thấy python3, bash, git" || bad "dụng cụ: lọc PATH làm mất python3/bash/git"
[ -n "$(PATH="$ASKBIN:$NOASK_PATH" command -v session-ask)" ] && ok "dụng cụ: session-ask giả đứng đầu PATH thì thấy được" || bad "dụng cụ: session-ask giả không thấy"
O=$(sbx $SBX_ID PATH="$ASKBIN:$NOASK_PATH"); C=$(ctx "$O")
LINE=$(printf '%s\n' "$C" | grep -F 'Sandbox session — first behaviour')
nonempty "$LINE" "sandbox, session-ask có trong PATH: có lời nhắc hành vi đầu tiên"
novn "$C" "sandbox with session-ask"
has "$LINE" 'vibemaestro-sdlc:intake' "…nhắc intake (ghi intent nguyên văn)"
has "$LINE" 'VERBATIM' "…nói rõ intent ghi nguyên văn"
has "$LINE" 'vibemaestro-sdlc:spec' "…nhắc skill spec (tạo spec từ intent)"
has "$LINE" 'session-ask' "…nhắc session-ask (xin người duyệt spec)"
has "$LINE" 'edit code' "…và nói chỉ sửa code sau khi người duyệt"
order_ok() { python3 -c '
import sys
t, *ks = sys.argv[1:]
pos = [t.find(k) for k in ks]
sys.exit(0 if all(p >= 0 for p in pos) and pos == sorted(pos) else 1)' "$@"; }
order_ok "$LINE" 'vibemaestro-sdlc:intake' 'vibemaestro-sdlc:spec' 'session-ask' 'ONLY AFTER the person has approved' && ok "…đúng thứ tự: intake → spec → session-ask → code" || bad "lời nhắc sai thứ tự"
order_ok "$LINE" 'vibemaestro-sdlc:spec' 'vibemaestro-sdlc:intake' && bad "dụng cụ order_ok không nhận ra thứ tự ngược" || ok "đối chứng dụng cụ: order_ok từ chối thứ tự ngược"
[ "$(nchars "$C")" -lt 9000 ] && ok "sandbox, luật giả: hook danh mục $(nchars "$C") < 9000 ký tự" || bad "sandbox: hook danh mục $(nchars "$C") ≥ 9000"
O=$(sbx $SBX_ID PATH="$NOASK_PATH"); C=$(ctx "$O")
has "$C" 'Sandbox session — first behaviour' "sandbox, KHÔNG có session-ask: vẫn có lời nhắc hành vi đầu tiên"
novn "$C" "sandbox without session-ask"
hasnt "$C" 'session-ask' "A7: không có session-ask trong PATH → KHÔNG nhắc session-ask ở bất kỳ đâu"
has "$C" 'ask in words' "…bước xin duyệt còn, nói bằng lời"
has "$C" 'vibemaestro-sdlc:spec' "…và vẫn nhắc skill spec"
# ca âm: không phải sandbox → không có lời nhắc, kể cả khi session-ask có trong PATH
for spec in "chỉ INTENT_SLUG|INTENT_SLUG=2026-10-10-viec" "chỉ SEAT|SEAT=acme-it-ai" "không biến nào|X_KHONG_LIEN_QUAN=1" \
            "INTENT_SLUG rỗng + SEAT|INTENT_SLUG= SEAT=acme-it-ai" "INTENT_SLUG + SEAT rỗng|INTENT_SLUG=2026-10-10-viec SEAT="; do
  lbl=${spec%%|*}; vars=${spec#*|}
  # shellcheck disable=SC2086
  C=$(ctx "$(sbx $vars PATH="$ASKBIN:$NOASK_PATH")")
  hasnt "$C" 'first behaviour' "không phải sandbox ($lbl), session-ask trong PATH: KHÔNG có lời nhắc sandbox"
  hasnt "$C" 'session-ask' "không phải sandbox ($lbl): không nhắc session-ask"
done
# A7: plugin thiếu skill spec → không nhắc spec/session-ask; thiếu cả intake và spec → không nhắc gì của phiên sandbox
PLA="$TMP/plug-a7"; cp -r "$PL" "$PLA"; rm -rf "$PLA/skills/spec"
C=$(ctx "$(CLAUDE_PLUGIN_ROOT="$PLA" sbx $SBX_ID PATH="$ASKBIN:$NOASK_PATH")")
hasnt "$C" 'vibemaestro-sdlc:spec' "sandbox, plugin không có skill spec: không nhắc spec"
hasnt "$C" 'session-ask' "sandbox, plugin không có skill spec: không nhắc session-ask (không có spec để xin duyệt)"
has "$C" 'vibemaestro-sdlc:intake' "đối chứng: skill intake còn thì vẫn nhắc intake"
rm -rf "$PLA/skills/intake"
C=$(ctx "$(CLAUDE_PLUGIN_ROOT="$PLA" sbx $SBX_ID PATH="$ASKBIN:$NOASK_PATH")")
hasnt "$C" 'Phiên sandbox' "sandbox, plugin thiếu cả intake và spec: không có lời nhắc phiên sandbox"

echo "== A1: kích thước — mỗi hook dưới trần 10.000 ký tự có biên =="
LIM=9000
[ "$(nchars "$LC")" -lt "$LIM" ] && ok "luật giả: hook lõi $(nchars "$LC") < $LIM ký tự" || bad "hook lõi $(nchars "$LC") ≥ $LIM"
[ "$(nchars "$BC")" -lt "$LIM" ] && ok "luật giả: hook danh mục $(nchars "$BC") < $LIM ký tự" || bad "hook danh mục $(nchars "$BC") ≥ $LIM"
# Bộ luật THẬT của plugin (không phải bản giả): lõi phải vừa trần — đỏ khi file lõi hoặc danh mục phình quá.
REALCORE="$PLUGIN/rules/$CORE_NAME"
[ -f "$REALCORE" ] && ok "plugin có lõi quy trình thật: rules/$CORE_NAME" || bad "plugin thiếu rules/$CORE_NAME"
S=$(sid); RL=$(CLAUDE_PROJECT_DIR="$APP" CLAUDE_PLUGIN_ROOT="$PLUGIN" sess_one 1 "$S"); RB=$(CLAUDE_PROJECT_DIR="$APP" CLAUDE_PLUGIN_ROOT="$PLUGIN" sess_one 2 "$S")
RLC=$(ctx "$RL"); RBC=$(ctx "$RB")
[ "$(nchars "$RLC")" -lt "$LIM" ] && ok "luật THẬT: hook lõi $(nchars "$RLC") < $LIM ký tự" || bad "luật thật: hook lõi $(nchars "$RLC") ≥ $LIM"
[ "$(nchars "$RBC")" -lt "$LIM" ] && ok "luật THẬT: hook danh mục $(nchars "$RBC") < $LIM ký tự" || bad "luật thật: hook danh mục $(nchars "$RBC") ≥ $LIM"
REALLAST=$(grep -v '^[[:space:]]*$' "$REALCORE" | tail -1)
has "$RLC" "${REALLAST:0:60}" "luật THẬT: dòng cuối của lõi có trong phiên (nhận đủ nội dung, không bị cắt)"
hasnt "$RLC" 'đã cắt' "luật THẬT: lõi không bị cắt"
for r in git-process pr-no-leaks before-ready current-state-shape; do
  has "$RBC" "$r.instructions.md" "luật THẬT: danh mục có luật $r"
done
has "$RBC" "$PLUGIN/rules" "luật THẬT: danh mục in đường dẫn TUYỆT ĐỐI tới thư mục luật của plugin"
hasnt "$RLC$RBC" 'WARNING' "luật THẬT: không cảnh báo nào"
novn "$RLC$RBC" "real rules, both SessionStart hooks"

echo "== A2: PreToolUse Edit/Write/NotebookEdit ở repo app =="
O=$(inapp edit "$(sid)" "$APP/clusters/x.yaml")
has "$O" "$RULES/r-all.instructions.md" "luật khớp '**' — đường dẫn tuyệt đối trong plugin"
has "$O" "$RULES/r-clusters.instructions.md" "luật khớp applyTo clusters/**"
O=$(inapp edit "$(sid)" "$APP/docs/y.md")
has "$O" 'r-all.instructions.md' "đối chứng: file khác vẫn nhận luật '**'"
hasnt "$O" 'r-clusters.instructions.md' "đối chứng: file ngoài clusters/ không nhận luật clusters"
O=$(inapp edit "$(sid)" "$APP/src/main.ts")
has "$O" "$APP/kb/decisions/d-app.md" "kb/decisions của REPO APP khớp applyTo (glob theo gốc repo app)"
O2=$(inapp edit "$(sid)" "$APP/docs/y.md")
hasnt "$O2" 'd-app.md' "đối chứng: file ngoài src/ không nhận quyết định src/**"
# quyết định status khác active không bơm
printf -- '---\napplyTo: "src/**"\nstatus: superseded\ndescription: "CU"\n---\n' > "$APP/kb/decisions/d-cu.md"
hasnt "$(inapp edit "$(sid)" "$APP/src/main.ts")" 'd-cu.md' "quyết định status: superseded không được bơm"
rm -f "$APP/kb/decisions/d-cu.md"
# the lifecycle word `live` means what `active` meant: the decision is delivered; `done` is not
printf -- '---\napplyTo: "src/**"\nstatus: live\ndescription: "SONG"\n---\n' > "$APP/kb/decisions/d-song.md"
printf -- '---\napplyTo: "src/**"\nstatus: done\ndescription: "XONG"\n---\n' > "$APP/kb/decisions/d-xong.md"
O=$(inapp edit "$(sid)" "$APP/src/main.ts")
has "$O" 'd-song.md' "quyết định status: live được bơm như active"
hasnt "$O" 'd-xong.md' "quyết định status: done không được bơm"
rm -f "$APP/kb/decisions/d-song.md" "$APP/kb/decisions/d-xong.md"
S=$(sid)
O1=$(inapp edit "$S" "$APP/clusters/x.yaml"); O2=$(inapp edit "$S" "$APP/clusters/x.yaml")
nonempty "$O1" "lần đầu trong phiên: có lời nhắc"
empty "$O2" "lần hai cùng phiên: im (mỗi tài liệu một lần mỗi phiên)"
O3=$(inapp edit "$(sid)" "$APP/clusters/x.yaml")
nonempty "$O3" "đối chứng: phiên KHÁC lại được nhắc"
# dedup lời nhắc quyết định khi đường dẫn repo DÀI: tên marker từng chứa nguyên đường dẫn → > 255 byte → OSError bị nuốt → nhắc lặp mỗi lần Edit
S=$(sid); O1=$(inapp edit "$S" "$APP/src/main.ts"); O2=$(inapp edit "$S" "$APP/src/main.ts")
has "$O1" 'd-app.md' "repo đường dẫn ngắn: lần đầu có lời nhắc quyết định"
hasnt "$O2" 'd-app.md' "repo đường dẫn ngắn: lần hai cùng phiên: không nhắc lại quyết định"
APPL="$TMP/app-$(printf 'd%.0s' $(seq 1 220))"; mk_app "$APPL"
[ "${#APPL}" -ge 200 ] && ok "dụng cụ: đường dẫn repo dài ${#APPL} ký tự (>= 200)" || bad "đường dẫn repo chưa đủ dài (${#APPL})"
S=$(sid); O1=$(CLAUDE_PROJECT_DIR="$APPL" CLAUDE_PLUGIN_ROOT="$PL" edit "$S" "$APPL/src/main.ts"); O2=$(CLAUDE_PROJECT_DIR="$APPL" CLAUDE_PLUGIN_ROOT="$PL" edit "$S" "$APPL/src/main.ts")
has "$O1" 'd-app.md' "repo đường dẫn DÀI: lần đầu có lời nhắc quyết định"
hasnt "$O2" 'd-app.md' "repo đường dẫn DÀI: lần hai cùng phiên: không nhắc lại quyết định (marker không vỡ vì tên quá dài)"
rm -rf "$APPL"
has "$(inapp write_ "$(sid)" "$APP/clusters/x.yaml")" 'r-clusters.instructions.md' "Write cũng đi qua hook"
has "$(inapp nbedit "$(sid)" "$APP/clusters/x.yaml")" 'r-clusters.instructions.md' "NotebookEdit (notebook_path) cũng đi qua hook"
OUT="$TMP/ngoai/z.yaml"; mkdir -p "$TMP/ngoai"; : > "$OUT"
empty "$(inapp edit "$(sid)" "$OUT")" "đối chứng: file ngoài repo app và ngoài worktree của nó → im"
git_ -C "$APP" worktree add -q "$APP/.claude/worktrees/w1" -b w1
mkdir -p "$APP/.claude/worktrees/w1/src"; : > "$APP/.claude/worktrees/w1/src/n.ts"
has "$(inapp edit "$(sid)" "$APP/.claude/worktrees/w1/src/n.ts")" "$APP/kb/decisions/d-app.md" "file trong worktree của repo app: glob vẫn theo gốc worktree"
git_ -C "$APP" worktree add -q "$TMP/wt-ngoai" -b w2; mkdir -p "$TMP/wt-ngoai/src"; : > "$TMP/wt-ngoai/src/m.ts"
has "$(inapp edit "$(sid)" "$TMP/wt-ngoai/src/m.ts")" 'r-all.instructions.md' "file trong worktree NGOÀI cây repo app (cùng kho): vẫn được nhắc luật"
APPX="$TMP/app-khac"; mk_app "$APPX"
empty "$(inapp edit "$(sid)" "$APPX/clusters/x.yaml")" "đối chứng: file của một repo KHÁC (không chung kho) → im"

echo "== A3: PreToolUse Bash ở repo app =="
O=$(inapp bashc "$(sid)" "lenh-bay --x")
has "$(ctx "$O")" 'r-cmd.instructions.md' "luật applyWhen khớp lệnh"
has "$(ctx "$O")" "$RULES/r-cmd.instructions.md" "đường dẫn luật là TUYỆT ĐỐI (từ repo app, đường tương đối không mở được)"
hasnt "$(ctx "$O")" '- rules/r-cmd' "đối chứng: không có đường tương đối trần"
empty "$(inapp bashc "$(sid)" "ls -la")" "đối chứng: lệnh không khớp luật nào → im"
S=$(sid)
O1=$(inapp bashc "$S" "lenh-bay a"); O2=$(inapp bashc "$S" "lenh-bay b")
nonempty "$O1" "lệnh khớp lần đầu: nhắc"; empty "$O2" "lệnh khớp lần hai cùng phiên: im"
O=$(inapp bashc "$(sid)" "nguy-hiem --x")
eq "$(dec "$O")" deny "luật level:block → permissionDecision deny"
has "$(why "$O")" 'PL-LUAT-CHAN-NGUY-HIEM' "deny kèm lý do là mô tả luật"
novn "$O" "a block (deny with its reason)"
S=$(sid); inapp bashc "$S" "nguy-hiem a" >/dev/null
eq "$(dec "$(inapp bashc "$S" "nguy-hiem b")")" deny "chặn không dedup: lần hai vẫn deny"
O=$(inapp bashc "$(sid)" "RULES_GATE=off nguy-hiem --x")
ne "$(dec "$O")" deny "đối chứng: RULES_GATE=off trong lệnh thì không chặn"
# luật THẬT của plugin: lệnh khớp ở cả hai chiều
realbash() { CLAUDE_PROJECT_DIR="$APP" CLAUDE_PLUGIN_ROOT="${RPL:-$PLUGIN}" run_cmds "$HOOKS" PreToolUse Bash "$(p_bash "$(sid)" "$1")"; }
has "$(ctx "$(realbash 'git worktree add .claude/worktrees/x origin/main')")" 'git-process.instructions.md' "luật THẬT: git worktree add → nhắc git-process"
has "$(ctx "$(realbash 'bash scripts/intent-branch.sh worker-branch --intent x --name y')")" 'git-process.instructions.md' "luật THẬT: intent-branch.sh worker-branch → nhắc git-process"
has "$(ctx "$(realbash 'git commit -m x')")" 'pr-no-leaks.instructions.md' "luật THẬT: git commit → nhắc pr-no-leaks"
has "$(ctx "$(realbash 'gh pr ready 12')")" 'before-ready.instructions.md' "luật THẬT: gh pr ready → nhắc before-ready"
empty "$(realbash 'ls -la')" "luật THẬT, đối chứng: ls -la không khớp luật nào"
novn "$(realbash 'git worktree add .claude/worktrees/x origin/main')$(realbash 'git commit -m x')$(realbash 'gh pr ready 12')" "real command reminders"
OCS=$(CLAUDE_PROJECT_DIR="$APP" CLAUDE_PLUGIN_ROOT="$PLUGIN" run_cmds "$HOOKS" PreToolUse Edit "$(p_edit "$(sid)" "$APP/kb/current-state.md")")
has "$OCS" 'current-state-shape.instructions.md' "luật THẬT: sửa kb/current-state.md → nhắc current-state-shape (applyTo)"
novn "$OCS" "real edit reminder"
OCS=$(CLAUDE_PROJECT_DIR="$APP" CLAUDE_PLUGIN_ROOT="$PLUGIN" run_cmds "$HOOKS" PreToolUse Edit "$(p_edit "$(sid)" "$APP/src/main.ts")")
hasnt "$OCS" 'current-state-shape' "luật THẬT, đối chứng: sửa src/main.ts không nhắc current-state-shape"

echo "== C6: the generic rules answer on their own triggers (real rules; a positive and a near-miss each) =="
# fires <command> <rule> / silent <command> <rule>: one fresh session per call, so the once-per-session dedup never hides a case.
# Commands carry no double quote (they are put into a JSON string by p_bash).
fires()  { has "$(ctx "$(realbash "$1")")" "$2.instructions.md" "C6: '$1' reminds $2"; }
silent() { hasnt "$(ctx "$(realbash "$1")")" "$2.instructions.md" "C6: '$1' does not remind $2"; }
realedit() { CLAUDE_PROJECT_DIR="${RAPP:-$APP}" CLAUDE_PLUGIN_ROOT="${RPL:-$PLUGIN}" run_cmds "$HOOKS" PreToolUse Edit "$(p_edit "$(sid)" "${RAPP:-$APP}/$1")"; }
sessone_real() { CLAUDE_PROJECT_DIR="${RAPP:-$APP}" CLAUDE_PLUGIN_ROOT="${RPL:-$PLUGIN}" sess_one 2 "$(sid)"; }
fires_path()  { has "$(ctx "$(realedit "$1")")" "$2.instructions.md" "C6: editing $1 reminds $2"; }
silent_path() { hasnt "$(ctx "$(realedit "$1")")" "$2.instructions.md" "C6: editing $1 does not remind $2"; }

fires 'gh pr list --search x' measurement-commands
fires 'gh issue list --state all' measurement-commands
fires 'gh run list --limit 5' measurement-commands
fires 'grep -c foo file' measurement-commands
fires 'grep -rci foo src' measurement-commands
fires 'grep --count foo file' measurement-commands
fires 'git log origin/main..HEAD --oneline' measurement-commands
fires 'git log main...feature' measurement-commands
silent 'gh pr view 3' measurement-commands
silent 'gh pr checks 3' measurement-commands
silent 'grep -n foo file' measurement-commands
silent 'grep -rl --include=*.c foo src' measurement-commands
silent 'grep -C 3 foo file' measurement-commands
silent 'git log --oneline -5' measurement-commands
silent 'git log -- ../x' measurement-commands
fires 'gh -R o/r pr list' measurement-commands
fires 'gh workflow list' measurement-commands
fires 'git rev-list --count main..HEAD' measurement-commands
fires 'git rev-list --count HEAD' measurement-commands
fires 'git shortlog -sn main..HEAD' measurement-commands
fires 'git -C /x log main..feature' measurement-commands
fires 'egrep -c foo file' measurement-commands
fires 'rg --count foo src' measurement-commands
fires 'git log --oneline \\n  main..HEAD' measurement-commands
silent "git log --grep=x...y" measurement-commands
silent 'git log -- a/../b' measurement-commands
silent 'git rev-list HEAD' measurement-commands
silent 'gh label view x' measurement-commands
# Rule-match gap 1: a quoted range and a range with one side empty (silent on 1.1.1); `\"` is a double quote inside the JSON payload
fires 'git log \"$A..$B\"' measurement-commands
fires "git log '\$A..\$B'" measurement-commands
fires 'git log ..HEAD' measurement-commands
fires 'git log HEAD..' measurement-commands
fires 'git log --oneline \"origin/main..HEAD\" | wc -l' measurement-commands
fires 'git log \"$A\"..\"$B\"' measurement-commands
fires 'git rev-list HEAD...origin/main' measurement-commands
silent 'git log' measurement-commands
silent 'git log -1' measurement-commands
silent 'git log ..' measurement-commands
silent 'git log -- \"../x\"' measurement-commands
silent 'git log --format=\"%h .. %s\"' measurement-commands
silent 'git diff \"$A..$B\"' measurement-commands
# review round 1: one-sided with a quoted side, a command substitution before the dots, a quoted -C; ellipses in text stay silent
fires 'git log ..\"$B\"' measurement-commands
fires "git log ...'origin/main'" measurement-commands
fires 'git log --oneline $(git describe --tags --abbrev=0)..HEAD' measurement-commands
fires 'git log --oneline \"$(git describe --abbrev=0)..HEAD\"' measurement-commands
fires 'git -C \"my repo\" log main..HEAD' measurement-commands
silent 'git log --grep \"WIP...\"' measurement-commands
# review round 2: a three-dot range with an empty right side, on a revision-shaped left side
fires 'git log HEAD...' measurement-commands
fires 'git log \"$A\"...' measurement-commands
fires 'git log origin/main... | wc -l' measurement-commands
fires 'git log -1 $(echo hi)...' measurement-commands
silent 'git log -- src/...' measurement-commands
silent 'git log --pretty=format:\"%h %s...\"' measurement-commands
silent "git log -1 --format='%s' # check this..." measurement-commands
# planted break: the 1.1.1 range part of the regex in a copy of the plugin, and the new triggers go silent (the four cases above are
# not proved by some other part of the regex)
PB76="$TMP/plugin-76"; cp -r "$PLUGIN" "$PB76"
python3 - "$PB76/rules/measurement-commands.instructions.md" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
new = r"(?:\s(?!-)[\x22\x27]?(?:[^\s\x22\x27]*?[^\s\x22\x27/.][\x22\x27]?(?:\.\.\.?(?=[\x22\x27]?[^\s\x22\x27./])|\.\.(?=[\s|;&)\x22\x27]|$))|(?:HEAD|\$[^\s\x22\x27.]+|[^\s\x22\x27]*?/[^\s\x22\x27./]+)[\x22\x27]?\.\.\.(?=[\s|;&)\x22\x27]|$)|\.\.\.?[\x22\x27]?[^\s\x22\x27./])|[)\x60][\x22\x27]?(?:\.\.\.?[\x22\x27]?[^\s\x22\x27./]|\.\.\.?(?=[\s|;&)\x22\x27]|$)))|"
old = r"\s(?!-)[^\s\x22\x27]*?[^\s\x22\x27/.]\.\.\.?[^\s\x22\x27.]|"
assert s.count(new) == 1, "the range part of the regex moved: update this planted break"
open(p, "w").write(s.replace(new, old))
PY
for c in 'git log \"$A..$B\"' 'git log ..HEAD' 'git log HEAD..'; do
  o=$(RPL="$PB76" capped realbash "$c"); crc=$?   # capped: memory and time caps (fixtures/capped.sh)
  cap_red "$crc" "planted break (1.1.1 regex): '$c'" || hasnt "$(ctx "$o")" measurement-commands.instructions.md "planted break (1.1.1 regex): '$c' goes silent"
done
o=$(RPL="$PB76" capped realbash 'git log main..HEAD'); crc=$?
case "$crc" in 247|248) bad "planted break, control: a cap stopped the copy (rc $crc)";; *) has "$(ctx "$o")" measurement-commands.instructions.md "planted break, control: the copy still reminds on 'git log main..HEAD'";; esac

# Rule-match gap 3: pr-no-leaks carries the self-scan and allowlist paragraph (absent on 1.1.1), with the allowlist path
# read from the config, and the commands it names do what it says
gap3() {  # gap3 <plugin dir> <tag> — the checks of gap 3 against one plugin tree
  local PKL="$1/rules/pr-no-leaks.instructions.md" SCANP CMDS SCAN_CMD ALLOW_CMD R3 OUT rc H PB
  SCANP=$(grep -F '**Scan it yourself, and the allowlist.**' "$PKL")
  nonempty "$SCANP" "gap 3: pr-no-leaks has the self-scan and allowlist paragraph"
  has "$SCANP" 'get sensitive.allowlist' "gap 3: the allowlist path is read from the config key sensitive.allowlist"
  hasnt "$(cat "$PKL")" '.pr-sensitive-allow' "gap 3: the rule writes no allowlist file name (the default comes from the config)"
  has "$SCANP" 'base branch' "gap 3: the paragraph says the CI gate reads the allowlist of the base branch"
  # run the two commands exactly as the paragraph spells them, on a copy of the plugin (no bytecode in the real one)
  PB="$TMP/plugin-76d-$2"; cp -r "$1" "$PB"
  CMDS=$(python3 -c 'import re, sys; print("\n".join(re.findall(r"`(python3 [^`]+)`", open(sys.argv[1]).read())))' \
           "$PB/rules/pr-no-leaks.instructions.md" | grep -F -e pr_sensitive.py -e 'get sensitive.allowlist')
  eq "$(printf '%s\n' "$CMDS" | grep -c .)" 2 "gap 3: the paragraph names two commands (the scan, the allowlist path)"
  SCAN_CMD=$(printf '%s\n' "$CMDS" | grep -F pr_sensitive.py); ALLOW_CMD=$(printf '%s\n' "$CMDS" | grep -F sdlc_config.py)
  R3="$TMP/app-76-scan-$2"; mk_app "$R3"; mkdir -p "$R3/.vibemaestro" "$R3/policy"
  printf '{"schema": 1, "sensitive": {"allowlist": "policy/allow.txt"}}' > "$R3/.vibemaestro/sdlc.json"
  runrule() { ( cd "$R3" && CLAUDE_PLUGIN_ROOT="$PB" bash -c "$1" ); }
  eq "$(runrule "$ALLOW_CMD")" policy/allow.txt "gap 3: the allowlist command prints the file the config names"
  printf 'Contact the owner at ops-lead@acme-corp.test for access.\n' > "$R3/body.md"
  OUT=$(runrule "$SCAN_CMD"); rc=$?
  eq "$rc" 1 "gap 3: the scan command is red (rc 1) on a planted e-mail (a sure positive)"
  hasnt "$OUT" 'ops-lead@acme-corp.test' "gap 3: …and does not repeat the value"
  # the sha256 of the exact value, computed here: the scan prints it only outside GitHub Actions (a public log must not carry it)
  H=$(python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' 'ops-lead@acme-corp.test')
  printf '%s  # test: a fake address\n' "$H" > "$R3/policy/allow.txt"
  runrule "$SCAN_CMD" >/dev/null; eq "$?" 0 "gap 3: one sha256 line in the file the config names clears it (rc 0)"
}
gap3 "$PLUGIN" real
# planted break: the paragraph removed from a copy, and the same checks go red
PB76E="$TMP/plugin-76e"; cp -r "$PLUGIN" "$PB76E"
grep -v -F '**Scan it yourself, and the allowlist.**' "$PLUGIN/rules/pr-no-leaks.instructions.md" > "$PB76E/rules/pr-no-leaks.instructions.md"
NF=$( (FAIL=0; gap3 "$PB76E" broken >/dev/null; echo "$FAIL") )
[ "$NF" -ge 5 ] && ok "planted break: no self-scan paragraph, the gap 3 checks go red ($NF failed)" || bad "planted break: the gap 3 checks stay green without the paragraph ($NF failed)"

fires_path kb/specs/2026-10-14-x.md document-precedence
fires_path kb/decisions/2026-10-14-y.md document-precedence
fires_path docs/guide.md document-precedence
silent_path src/main.ts document-precedence
silent_path kb-notes/x.md document-precedence
silent_path README.md document-precedence
# Rule-match gap 2: an edit under a configured `rules.dirs` directory reminds (`${rules.dirs}/**`; silent on 1.1.1)
RAPP76="$TMP/app-76"; mk_app "$RAPP76"
mkdir -p "$RAPP76/.vibemaestro" "$RAPP76/policy/rules" "$RAPP76/.github/instructions" "$RAPP76/other"
printf '{"schema": 1, "rules": {"dirs": ["policy/rules", "./.github/instructions/"]}}' > "$RAPP76/.vibemaestro/sdlc.json"
for f in policy/rules/x.instructions.md .github/instructions/y.instructions.md other/z.instructions.md; do : > "$RAPP76/$f"; done
RAPP="$RAPP76" fires_path policy/rules/x.instructions.md document-precedence
RAPP="$RAPP76" fires_path .github/instructions/y.instructions.md document-precedence
RAPP="$RAPP76" silent_path other/z.instructions.md document-precedence
RAPP="$RAPP76" silent_path policy/x.md document-precedence
# a directory name with a glob character is taken literally
RAPPG="$TMP/app-76g"; mk_app "$RAPPG"; mkdir -p "$RAPPG/.vibemaestro" "$RAPPG/r*" "$RAPPG/rx"
printf '{"schema": 1, "rules": {"dirs": ["r*"]}}' > "$RAPPG/.vibemaestro/sdlc.json"; : > "$RAPPG/r*/a.md"; : > "$RAPPG/rx/b.md"
RAPP="$RAPPG" fires_path 'r*/a.md' document-precedence
RAPP="$RAPPG" silent_path rx/b.md document-precedence
RAPP="$RAPP76" fires_path kb/specs/2026-10-14-x.md document-precedence
silent_path policy/rules/x.instructions.md document-precedence   # no config: the token matches nothing
has "$(ctx "$(RAPP="$RAPP76" sessone_real)")" 'policy/rules/**' "the catalogue shows \${rules.dirs} expanded to the configured directories"
# a decision of the repo can use the token too
dec_ "$RAPP76" d-rules.md '${rules.dirs}/**' 'APP-QD-RULES-DIRS'
has "$(RAPP="$RAPP76" realedit policy/rules/x.instructions.md)" 'd-rules.md' "a decision with applyTo \${rules.dirs}/** is reminded on an edit there"
hasnt "$(RAPP="$RAPP76" realedit other/z.instructions.md)" 'd-rules.md' "…and not elsewhere"
# planted break: the token removed from the rule, and the edit goes silent
PB76B="$TMP/plugin-76b"; cp -r "$PLUGIN" "$PB76B"
sed -i.bak 's|,${rules.dirs}/\*\*"|"|' "$PB76B/rules/document-precedence.instructions.md"; rm -f "$PB76B/rules/"*.bak
hasnt "$(head -3 "$PB76B/rules/document-precedence.instructions.md")" 'rules.dirs' "planted break: the copy's applyTo has no token"
RPL="$PB76B" RAPP="$RAPP76" silent_path policy/rules/x.instructions.md document-precedence
# planted break: the engine does not expand the token (the 1.1.1 engine), and the edit goes silent
PB76C="$TMP/plugin-76c"; cp -r "$PLUGIN" "$PB76C"
python3 - "$PB76C/scripts/rules.py" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "        for d in dirs:\n            p = pat.replace("
assert s.count(old) == 1, "apply_to_regexes moved: update this planted break"
open(p, "w").write(s.replace(old, "        for d in ():\n            p = pat.replace("))
PY
RPL="$PB76C" RAPP="$RAPP76" silent_path policy/rules/x.instructions.md document-precedence
# `${public.tree}` (rule public-tree): every path of a repo that sets `public.private`, but the root kb/ and those globs
RAPPP="$TMP/app-public"; mk_app "$RAPPP"
mkdir -p "$RAPPP/.vibemaestro" "$RAPPP/tests/fixtures/f/kb" "$RAPPP/kb/specs" "$RAPPP/ops/a" "$RAPPP/.changes"
printf '{"schema": 1, "public": {"private": [".vibemaestro/sdlc.json", "ops/**"]}}' > "$RAPPP/.vibemaestro/sdlc.json"
for f in tests/x.sh tests/fixtures/f/kb/x.md kb/specs/a.md ops/a/b.yaml .changes/a.md README.md .vibemaestro/sdlc.json.bak; do : > "$RAPPP/$f"; done
RAPP="$RAPPP" fires_path tests/x.sh public-tree
RAPP="$RAPPP" fires_path .changes/a.md public-tree
RAPP="$RAPPP" fires_path README.md public-tree
RAPP="$RAPPP" fires_path tests/fixtures/f/kb/x.md public-tree      # a kb/ below the root is not the private kb/
RAPP="$RAPPP" silent_path kb/specs/a.md public-tree
RAPP="$RAPPP" silent_path .vibemaestro/sdlc.json public-tree
RAPP="$RAPPP" fires_path .vibemaestro/sdlc.json.bak public-tree   # a private glob matches the whole path
RAPP="$RAPPP" silent_path ops/a/b.yaml public-tree
silent_path src/main.ts public-tree                                 # no `public.private`: the repo does not publish
has "$(ctx "$(RAPP="$RAPPP" sessone_real)")" '** except kb/** .vibemaestro/sdlc.json ops/**' "the catalogue shows \${public.tree} as what it stands for"
hasnt "$(ctx "$(sessone_real)")" 'public-tree.instructions.md' "…and lists no public-tree rule in a repo that does not publish"
RAPPE="$TMP/app-public-empty"; mk_app "$RAPPE"; mkdir -p "$RAPPE/.vibemaestro"
printf '{"schema": 1, "public": {"private": []}}' > "$RAPPE/.vibemaestro/sdlc.json"
RAPP="$RAPPE" fires_path .vibemaestro/sdlc.json public-tree          # an empty list publishes everything but kb/
# planted break: the engine does not expand the token, and the edit goes silent
PBPT="$TMP/plugin-public-tree"; cp -r "$PLUGIN" "$PBPT"
python3 - "$PBPT/scripts/rules.py" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "            rx = public_regex(dirs)\n"
assert s.count(old) == 1, "apply_to_regexes moved: update this planted break"
open(p, "w").write(s.replace(old, "            rx = None\n"))
PY
RPL="$PBPT" RAPP="$RAPPP" silent_path tests/x.sh public-tree

fires 'git commit -m x' commit-unit
fires 'git commit --amend' commit-unit
fires 'git rebase --rebase-merges origin/x' commit-unit
fires 'git reset --soft HEAD~2' commit-unit
fires 'gh pr ready 12' commit-unit
silent 'git commit-tree HEAD' commit-unit
silent 'git rebase-helper x' commit-unit
silent 'git reset --hard HEAD' commit-unit
silent 'gh pr view 12' commit-unit
silent 'git status' commit-unit

fires 'gh pr create --draft --title x' pr-body-shape
fires 'gh pr edit 12 --body-file body.md' pr-body-shape
fires 'gh pr comment 12 --body-file round.md' pr-body-shape
fires 'bash open-pr.sh --title x --summary s --evidence e' pr-body-shape
silent 'gh pr view 12' pr-body-shape
silent 'gh pr ready 12' pr-body-shape
silent 'gh pr checks 12' pr-body-shape
silent 'git commit -m x' pr-body-shape
fires 'gh pr ready 12' before-ready
silent 'gh pr view 12' before-ready
silent 'gh pr edit 12 --body-file body.md' before-ready

fires 'git rebase origin/main' git-process
fires 'git merge origin/main' git-process
fires 'git merge --ff-only origin/x' git-process
fires 'git commit --amend --no-edit' git-process
fires 'git push --force-with-lease' git-process
fires 'git push origin intent/x -f' git-process
fires 'git worktree add .claude/worktrees/x origin/main' git-process
silent 'git merge-base HEAD origin/main' git-process
silent 'git push origin intent/x' git-process
silent 'git push -u origin intent/x' git-process
silent 'git commit -m x' git-process
silent 'git fetch origin' git-process
fires 'git -C /x push --force' git-process
fires 'git -C /x rebase main' git-process
fires 'git -c core.editor=true rebase main' git-process
fires 'git -C /x commit --amend' git-process
fires 'git -C /x merge main' git-process
fires 'git push -fu origin x' git-process
fires 'git push -uf origin x' git-process
fires 'git push origin +main' git-process
fires 'git push origin x \\n  --force-with-lease' git-process
silent 'git push -u origin x' git-process
silent 'git push --follow-tags origin x' git-process
silent 'git -C /x merge-base a b' git-process
silent 'git -C /x status' git-process
fires 'git -C /x commit -m x' commit-unit
fires 'git -C /x reset --soft HEAD~1' commit-unit
fires 'git reset \\n  --soft HEAD~1' commit-unit
fires 'gh -R o/r pr ready 3' commit-unit
fires 'gh -R o/r pr ready 3' before-ready
silent 'git -C /x commit-tree HEAD' commit-unit

L=pr-no-leaks
fires 'gh pr create --title x' $L
fires 'gh pr edit 12 --body-file b.md' $L
fires 'gh pr comment 12 --body-file b.md' $L
fires 'gh pr review 12 --comment --body x' $L
fires 'gh issue create --title x --body-file b.md' $L
fires 'gh issue edit 3 --body-file b.md' $L
fires 'gh issue comment 3 --body-file b.md' $L
fires 'gh api repos/o/r/issues/1/comments -f body=x' $L
fires 'gh api repos/o/r/pulls/3/comments -F body=@b.md' $L
fires 'gh api -X POST repos/o/r/issues/1/comments --input b.json' $L
fires 'gh api repos/o/r/pulls/3/reviews --method POST --field body=x' $L
fires 'gh api repos/o/r/issues/comments/9 --method=PATCH --raw-field body=x' $L
fires 'bash scripts/review-post.sh 12 b.md' $L
fires 'python3 tools/pr_comment.py 12 b.md' $L
fires 'bash open-pr.sh --title x --summary s --evidence e' $L
fires 'git commit -m x' $L
silent 'gh pr view 12' $L
silent 'gh pr list' $L
silent 'gh issue list' $L
silent 'gh issue view 3' $L
silent 'gh api repos/o/r/pulls/3/comments' $L
silent 'gh api -X GET repos/o/r/issues/1/comments' $L
silent 'gh api repos/o/r/issues --jq .[].title' $L
silent 'gh api repos/o/r/actions/runs -f x=y' $L
silent 'gh api user' $L
silent 'bash scripts/review-list.sh 12' $L
silent 'git commit-tree HEAD' $L
silent 'git status' $L
fires 'gh pr merge 3 --squash --body x' $L
fires 'gh pr close 3 --comment x' $L
fires 'gh issue close 3 --comment x' $L
fires 'gh issue reopen 3' $L
fires 'gh -R o/r pr create --title x' $L
fires 'gh issue -R o/r comment 3 -b x' $L
fires 'gh api graphql -f query=mutation{addComment}' $L
fires 'gh api repos/o/r/issues/1/comments -fbody=x' $L
fires 'gh api repos/o/r/issues/1/comments --method post --input b.json' $L
fires 'gh api repos/o/r/issues -f title=x' $L
fires 'gh api repos/o/r/issues/1/comments \\n  -f body=x' $L
fires 'bash review-post-full.sh 12 b.md' $L
fires 'git -C /x commit -m x' $L
silent 'gh api graphql -f query=viewer{login}' $L
silent 'gh api repos/o/r/git/refs -f ref=refs/heads/issues-fix -f sha=y' $L
silent 'gh api user -f name=pulls' $L
silent 'gh api repos/o/r/contents/issues.md -X PUT -f message=x' $L
silent 'python3 pr-comments-report.py' $L
silent 'gh pr status' $L
silent 'gh pr diff 3' $L

fires_path kb/current-state.md current-state-shape
fires_path .vibemaestro/sdlc.json config-compat
fires_path plugins/vibemaestro-sdlc/scripts/sdlc_config.py config-compat
fires_path .vibemaestro/gates/sdlc_config.py config-compat
silent_path plugins/vibemaestro-sdlc/scripts/kb.py config-compat
silent_path kb/specs/2026-10-14-x.md current-state-shape
silent_path docs/current-state.md current-state-shape
silent_path src/kb/current-state.md current-state-shape
# version-policy: the manifests, the marketplace and the change files, never kb/current-state.md (app repos must not see it)
MF=plugin.json   # spelled apart: a literal manifest path here would read, to the coverage guard, as this suite using the real manifests
fires_path "plugins/x/.claude-plugin/$MF" version-policy
fires_path ".claude-plugin/$MF" version-policy
fires_path .claude-plugin/marketplace.json version-policy
fires_path .changes/2026-10-20-x.md version-policy
silent_path kb/current-state.md version-policy
silent_path README.md version-policy
silent_path "plugins/x/$MF" version-policy
VPB=$(awk 'f==2{print} /^---$/{f++}' "$PLUGIN/rules/version-policy.instructions.md" | grep -c .)
[ "$VPB" -le 10 ] && ok "version-policy: the body is $VPB non-empty lines (max 10)" || bad "version-policy: the body is $VPB non-empty lines (max 10)"

# the catalogue lists every new rule
for r in commit-unit pr-body-shape document-precedence measurement-commands docs-final; do
  has "$RBC" "$r.instructions.md" "C6: the session catalogue lists the rule $r"
done

# budget: a rule that is long is skimmed. New rules at most 40 lines, all rules together at most 363, the measured total of the rules directory (300 until the rule version-policy, whose 13 lines raised it to 313: no sdlc rule had a superseded bump line to drop; then the rules docs-final, 14 lines, public-tree, 13 lines, and config-compat, 12 lines: no rule text they supersede; then coordinated-work, 15 lines, which took 3 lines net out of workflow-core: 363; then one line in batonrun, at the moment of exit 8 a session must not sign as the owner: 364; then one line in coordinated-work, the first step of a brief built from a plan row: 365).
NEW_RULES="commit-unit pr-body-shape document-precedence measurement-commands docs-final public-tree config-compat coordinated-work"
for r in $NEW_RULES; do
  n=$(wc -l < "$PLUGIN/rules/$r.instructions.md" | tr -d ' ')
  [ "$n" -le 40 ] && ok "C6 budget: $r is $n lines (max 40)" || bad "C6 budget: $r is $n lines (max 40)"
done
TOTAL=$(cat "$PLUGIN"/rules/*.instructions.md | wc -l | tr -d ' ')
[ "$TOTAL" -le 365 ] && ok "C6 budget: all rules together are $TOTAL lines (max 365)" || bad "C6 budget: all rules together are $TOTAL lines (max 365)"
# control for the instrument: the count sees a rule that grows
printf '%s\n' $(seq 1 60) > "$TMP/long.md"; [ "$(wc -l < "$TMP/long.md" | tr -d ' ')" -gt 40 ] && ok "C6 budget: control, a 60-line file is over the cap" || bad "C6 budget: the line count does not see a long file"

# the generic rules carry no project term, and name configurable tokens by key, not by literal
RF=$(for r in $NEW_RULES; do printf '%s ' "$PLUGIN/rules/$r.instructions.md"; done)
ALLRF=$(ls "$PLUGIN"/rules/*.instructions.md | grep -v "/$CORE_NAME\$")
TERMS='kanban|telegram|gitops|cluster|vault|kubectl|(^|[^[:alnum:]])hub([^[:alnum:]]|$)|ladipage|hubspot'
empty "$(grep -n -i -E "$TERMS" $ALLRF)" "C6: no rule but the core names a hub, cluster, kanban or Telegram term"
printf 'a kanban dispatch on the hub cluster\n' | grep -c -i -E "$TERMS" | { read -r c; eq "$c" 1 "C6: control, the term pattern catches a planted line"; }
empty "$(grep -n -F -e 'SHA:' -e 'COMMIT EXCEPTION' -e 'NGOAI LE COMMIT' -e 'NO STATE CHANGE' -e 'Bằng chứng chạy' $ALLRF)" "C6: token literals are not written in the rules (only their config keys)"
has "$(cat $RF)" 'tokens.round_comment_prefix' "C6: the round-comment token is named by its config key"
has "$(cat $RF)" 'tokens.commit_exception' "C6: the commit-exception token is named by its config key"

# the fixture's rule directory and the plugin rules say different things (criterion: no duplicate paragraph)
SHAPED_OUT=$(python3 "$PLUGIN/scripts/kb.py" config check --root "$SRC_ROOT/tests/fixtures/hub-shaped" 2>&1)
hasnt "$SHAPED_OUT" 'duplicate paragraph' "C6: kb.py config check on the hub-shaped fixture reports no duplicate paragraph"
for r in $NEW_RULES git-process pr-no-leaks current-state-shape before-ready; do
  X="$TMP/dup-$r"; cp -r "$SRC_ROOT/tests/fixtures/hub-shaped" "$X"; cp "$PLUGIN/rules/$r.instructions.md" "$X/.github/instructions/copy-$r.instructions.md"
  has "$(python3 "$PLUGIN/scripts/kb.py" config check --root "$X" 2>&1)" 'duplicate paragraph' "C6: control, a copy of $r in the fixture's rule directory is reported"
done

echo "== A7: chỉ nhắc skill vừa kiểm là có mặt =="
PL7="$TMP/plug7"; cp -r "$PL" "$PL7"; rm -rf "$PL7/skills"
for s in init-kb intake spec plan ship; do mkdir -p "$PL7/skills/$s"; printf -- '---\nname: %s\ndescription: giả\n---\n' "$s" > "$PL7/skills/$s/SKILL.md"; done
b7() { CLAUDE_PLUGIN_ROOT="$PL7" CLAUDE_PROJECT_DIR="$APP" sess_one 2 "$(sid)"; }
C=$(ctx "$(b7)")
has "$C" 'vibemaestro-sdlc:init-kb' "skill init-kb có mặt → được nhắc"
has "$C" 'vibemaestro-sdlc:ship' "skill ship có mặt → được nhắc"
rm -rf "$PL7/skills/init-kb"
C=$(ctx "$(b7)")
hasnt "$C" 'init-kb' "xoá skill init-kb → lời nhắc về nó BIẾN MẤT"
has "$C" 'vibemaestro-sdlc:intake' "đối chứng: skill còn lại vẫn được nhắc"
mv "$PL7/skills/plan" "$PL7/skills/plan-doi-ten"
hasnt "$(ctx "$(b7)")" 'vibemaestro-sdlc:plan`' "đổi tên skill plan → hết nhắc tên cũ"
has "$(ctx "$(b7)")" 'vibemaestro-sdlc:plan-doi-ten`' "…the renamed directory is named by its new name (the skill line follows the directory)"
rm -rf "$PL7/skills"
hasnt "$(ctx "$(b7)")" 'vibemaestro-sdlc:' "không có skill nào → không nhắc skill nào"
hasnt "$BC" 'sandbox-session' "plugin không nhắc skill của repo nào khác (không có hub): không 'sandbox-session'"
mv "$RULES/r-cmd.instructions.md" "$TMP/r-cmd.bak"
hasnt "$(ctx "$(inapp sess_one 2 "$(sid)")")" 'r-cmd.instructions.md' "xoá luật r-cmd khỏi plugin → hết trong danh mục"
has "$(ctx "$(inapp sess_one 2 "$(sid)")")" 'r-clusters.instructions.md' "đối chứng: luật còn lại vẫn có"
mv "$TMP/r-cmd.bak" "$RULES/r-cmd.instructions.md"
printf -- '---\napplyTo: "x/**"\nstatus: superseded\ndescription: "LUAT-DA-THAY"\n---\n' > "$RULES/r-cu.instructions.md"
hasnt "$(ctx "$(inapp sess_one 2 "$(sid)")")" 'LUAT-DA-THAY' "luật status: superseded không vào danh mục"
rm -f "$RULES/r-cu.instructions.md"

echo "== bộ luật là của CHÍNH plugin đang chạy (CLAUDE_PLUGIN_ROOT), không phải nơi nào khác =="
PL2="$TMP/plugin2"; mk_plugin "$PL2"; rule "$PL2" r-clusters.instructions.md 'clusters/**' - - 'PL-HAI-LUAT-CLUSTERS'
O=$(CLAUDE_PLUGIN_ROOT="$PL2" CLAUDE_PROJECT_DIR="$APP" sess_one 2 "$(sid)")
has "$(ctx "$O")" 'PL-HAI-LUAT-CLUSTERS' "CLAUDE_PLUGIN_ROOT trỏ plugin thứ hai → danh mục là bộ luật của nó"
O=$(CLAUDE_PLUGIN_ROOT="$PL" CLAUDE_PROJECT_DIR="$APP" sess_one 2 "$(sid)")
has "$(ctx "$O")" 'PL-LUAT-CLUSTERS' "đối chứng: trỏ về plugin đầu → thấy bản đầu"
hasnt "$(ctx "$O")" 'PL-HAI-LUAT-CLUSTERS' "đối chứng: …và không thấy bản của plugin kia"
has "$(CLAUDE_PLUGIN_ROOT="$PL2" CLAUDE_PROJECT_DIR="$APP" edit "$(sid)" "$APP/clusters/x.yaml")" "$PL2/rules" "PreToolUse Edit dùng bộ luật của plugin thứ hai"
has "$(CLAUDE_PLUGIN_ROOT="$PL2" CLAUDE_PROJECT_DIR="$APP" bashc "$(sid)" "lenh-bay")" "$PL2/rules" "PreToolUse Bash dùng bộ luật của plugin thứ hai"
# plugin chạy từ vị trí của chính nó khi không có CLAUDE_PLUGIN_ROOT (Bash tool/CLI không phải lúc nào cũng có biến này)
c=$(hook_cmds "$HOOKS" SessionStart "" | sed -n 2p | sed "s|\${CLAUDE_PLUGIN_ROOT}|$PL2|")
O=$(printf '%s' "$(p_start "$(sid)")" | env -u CLAUDE_PLUGIN_ROOT CLAUDE_PROJECT_DIR="$APP" bash -c "$c" 2>/dev/null)
has "$(ctx "$O")" 'PL-HAI-LUAT-CLUSTERS' "không có CLAUDE_PLUGIN_ROOT: plugin dùng bộ luật cạnh chính file script của nó"

echo "== plugin hỏng thì nói to, không chặn công cụ =="
chk_warn() {  # chk_warn <nhãn> <ctx> <sys>
  has "$2" 'WARNING' "$1: additionalContext (model đọc) có CẢNH BÁO"
  nonempty "$3" "$1: systemMessage (người đọc) không rỗng"
  novn "${2%%$'\n\n'*}$3" "$1 (the warning block and the message for the person)"
}
PB="$TMP/plug-hong"; mk_plugin "$PB"; rm -rf "$PB/rules"
pb() { CLAUDE_PLUGIN_ROOT="$PB" CLAUDE_PROJECT_DIR="$APP" "$@"; }
for k in 1 2; do O=$(pb sess_one "$k" "$(sid)"); chk_warn "plugin thiếu rules/, SessionStart#$k" "$(ctx "$O")" "$(sysm "$O")"; done
S=$(sid)
O=$(pb edit "$S" "$APP/clusters/x.yaml"); chk_warn "plugin thiếu rules/, Edit" "$(ctx "$O")" "$(sysm "$O")"
empty "$(dec "$O")" "plugin thiếu rules/, Edit: không chặn công cụ"
empty "$(pb edit "$S" "$APP/clusters/x.yaml")" "Edit lần hai cùng phiên: cảnh báo không lặp"
O=$(pb bashc "$S" "ls"); chk_warn "plugin thiếu rules/, Bash" "$(ctx "$O")" "$(sysm "$O")"
empty "$(dec "$O")" "plugin thiếu rules/, Bash: không chặn công cụ"
PB2="$TMP/plug-hong2"; mk_plugin "$PB2"; rm "$PB2/rules/$CORE_NAME"
O=$(CLAUDE_PLUGIN_ROOT="$PB2" CLAUDE_PROJECT_DIR="$APP" sess_one 1 "$(sid)"); chk_warn "plugin thiếu file lõi quy trình" "$(ctx "$O")" "$(sysm "$O")"
hasnt "$(ctx "$O")" 'DONG-DAU-LOI-QUY-TRINH' "thiếu lõi: không giả vờ đã giao lõi (A7)"
PB3="$TMP/plug-hong3"; mk_plugin "$PB3"; mk_core "$PB3" 400
O=$(CLAUDE_PLUGIN_ROOT="$PB3" CLAUDE_PROJECT_DIR="$APP" sess_one 1 "$(sid)")
[ "$(nchars "$(ctx "$O")")" -lt 10000 ] && ok "lõi 400 đoạn: output vẫn dưới trần 10.000 ký tự ($(nchars "$(ctx "$O")"))" || bad "lõi lớn vượt trần"
has "$(ctx "$O")" 'DONG-DAU-LOI-QUY-TRINH' "lõi quá trần: phần đầu vẫn tới phiên"
has "$(ctx "$O")" "$PB3/rules/$CORE_NAME" "lõi quá trần: nói rõ file đầy đủ ở đâu (đường dẫn tuyệt đối)"
chk_warn "lõi quá trần" "$(ctx "$O")" "$(sysm "$O")"

echo "== fail-open =="
for stdin in '' 'khong-phai-json' '{"tool_input":'; do
  for t in Edit Bash; do
    c=$(hook_cmds "$HOOKS" PreToolUse $t | head -1)
    out=$(printf '%s' "$stdin" | CLAUDE_PROJECT_DIR="$APP" CLAUDE_PLUGIN_ROOT="$PL" bash -c "$c" 2>/dev/null); rc=$?
    eq "$rc" 0 "stdin hỏng (${stdin:0:12}) → $t rc 0"
    empty "$out" "stdin hỏng (${stdin:0:12}) → $t không in gì"
  done
done
c=$(hook_cmds "$HOOKS" SessionStart '' | head -1)
printf 'khong-phai-json' | CLAUDE_PROJECT_DIR="$APP" CLAUDE_PLUGIN_ROOT="$PL" bash -c "$c" >/dev/null 2>&1; eq "$?" 0 "SessionStart stdin hỏng → rc 0"
# git vắng khỏi PATH
mkdir -p "$TMP/nogit"; ln -sf "$(command -v python3)" "$TMP/nogit/python3"; ln -sf "$(command -v bash)" "$TMP/nogit/bash"
for spec in "PreToolUse Edit $(p_edit x "$APP/clusters/x.yaml")" "PreToolUse Bash $(p_bash x "lenh-bay")"; do
  ev=${spec%% *}; rest=${spec#* }; t=${rest%% *}; pl=${rest#* }
  c=$(hook_cmds "$HOOKS" "$ev" "$t" | head -1)
  out=$(printf '%s' "$pl" | PATH="$TMP/nogit" CLAUDE_PROJECT_DIR="$APP" CLAUDE_PLUGIN_ROOT="$PL" "$TMP/nogit/bash" -c "$c" 2>/dev/null); rc=$?
  eq "$rc" 0 "git vắng khỏi PATH → $t rc 0"
  [ "$(dec "$out")" != deny ] && ok "git vắng khỏi PATH → $t không deny" || bad "git vắng → $t bị deny"
done
c=$(hook_cmds "$HOOKS" SessionStart '' | head -1)
printf '%s' "$(p_start x)" | PATH="$TMP/nogit" CLAUDE_PROJECT_DIR="$APP" CLAUDE_PLUGIN_ROOT="$PL" "$TMP/nogit/bash" -c "$c" >/dev/null 2>&1; eq "$?" 0 "git vắng khỏi PATH → SessionStart rc 0"
# mã tra luật nổ ngay trong plugin (rules.py ném lỗi lúc import) → hook rc 0, KHÔNG deny, nhưng nói to (không im lặng) và không in stack trace
PX="$TMP/plug-no"; mk_plugin "$PX"; printf 'raise RuntimeError("no")\n' > "$PX/scripts/rules.py"
for t in edit bashc sess1 sess2; do
  case $t in
    edit)  c=$(hook_cmds "$HOOKS" PreToolUse Edit); sx=h7e; pl=$(p_edit $sx "$APP/clusters/x.yaml");;
    bashc) c=$(hook_cmds "$HOOKS" PreToolUse Bash); sx=h7b; pl=$(p_bash $sx "lenh-bay");;
    sess1) c=$(hook_cmds "$HOOKS" SessionStart '' | sed -n 1p); sx=h7s; pl=$(p_start $sx);;
    sess2) c=$(hook_cmds "$HOOKS" SessionStart '' | sed -n 2p); sx=h7s2; pl=$(p_start $sx);;
  esac
  out=$(printf '%s' "$pl" | CLAUDE_PROJECT_DIR="$APP" CLAUDE_PLUGIN_ROOT="$PX" bash -c "$c" 2>"$TMP/err.$t"); rc=$?
  eq "$rc" 0 "mã tra luật nổ lúc import → hook plugin ($t) rc 0"
  [ "$(dec "$out")" != deny ] && ok "mã tra luật nổ lúc import → ($t) không deny" || bad "mã tra luật nổ → ($t) deny"
  isjson "$out" && ok "mã tra luật nổ lúc import → ($t) in JSON hook hợp lệ" || bad "mã tra luật nổ → ($t) không in JSON: ${out:0:100}"
  chk_warn "mã tra luật nổ lúc import ($t)" "$(ctx "$out")" "$(sysm "$out")"
  has "$(ctx "$out")" 'RuntimeError' "mã tra luật nổ lúc import ($t): cảnh báo nêu tên lỗi"
  hasnt "$out" 'Traceback' "mã tra luật nổ lúc import ($t): không đổ stack trace vào cảnh báo"
  [ "$(printf '%s' "$out" | wc -c)" -lt 1500 ] && ok "mã tra luật nổ lúc import ($t): cảnh báo ngắn" || bad "cảnh báo quá dài ($t)"
  # một lần mỗi phiên: lần hai cùng session_id im (PreToolUse không được lặp mỗi lần Edit/Bash)
  out2=$(printf '%s' "$pl" | CLAUDE_PROJECT_DIR="$APP" CLAUDE_PLUGIN_ROOT="$PX" bash -c "$c" 2>/dev/null)
  empty "$out2" "mã tra luật nổ lúc import ($t): lần hai cùng phiên không lặp cảnh báo"
done
# đối chứng: plugin lành, cùng lệnh → không cảnh báo (cảnh báo ở trên là do rules.py nổ, không phải vô cớ)
c=$(hook_cmds "$HOOKS" PreToolUse Edit)
out=$(printf '%s' "$(p_edit h7ok "$APP/clusters/x.yaml")" | CLAUDE_PROJECT_DIR="$APP" CLAUDE_PLUGIN_ROOT="$PL" bash -c "$c" 2>/dev/null)
hasnt "$out" 'WARNING' "đối chứng: plugin lành → Edit không cảnh báo"
# stdin không phải JSON + import hỏng: vẫn rc 0 và vẫn cảnh báo (không sid → không dedup)
c=$(hook_cmds "$HOOKS" SessionStart '' | head -1)
out=$(printf 'khong-phai-json' | CLAUDE_PROJECT_DIR="$APP" CLAUDE_PLUGIN_ROOT="$PX" bash -c "$c" 2>/dev/null); rc=$?
eq "$rc" 0 "mã nổ lúc nạp + stdin hỏng → SessionStart rc 0"
has "$(ctx "$out")" 'WARNING' "mã nổ lúc nạp + stdin hỏng → vẫn cảnh báo"

echo "== D: quyết định theo path — các dạng glob của applyTo (porting the hub's test-decisions-for-path; each case a positive and a negative) =="
# The hub's _kanban_decisions_for test asserted these forms because a glob that matches wrong fails silently: nothing turns red, the
# decision is just never delivered. Here the real hook runs on a fresh app, one decision per glob form, and one Edit per probe path.
APPD="$TMP/app-dec"; mk_app "$APPD" 0
dec_ "$APPD" dg-lit.md 'infra/agent/agent-files.map' 'LITERAL'
dec_ "$APPD" dg-skills.md 'infra/agent/skills/**' 'DEEP-DIR'
dec_ "$APPD" dg-deep.md '**/*.yaml' 'DEEP-EXT'
dec_ "$APPD" dg-star.md 'clusters/*/kustomization.yaml' 'ONE-SEGMENT'
printf -- '---\napplyTo: "infra/agent/agent-files.map"\nstatus: superseded\ndescription: "SUPERSEDED"\n---\n\n# s\n' > "$APPD/kb/decisions/dg-cu.md"
printf -- '---\ndescription: "NO-APPLYTO"\n---\n\n# n\n' > "$APPD/kb/decisions/dg-none.md"
dprobe() {  # dprobe <path in the app> — the hook's output for an Edit of that path, in a session of its own (each document once per session)
  mkdir -p "$APPD/$(dirname "$1")"; [ -e "$APPD/$1" ] || : > "$APPD/$1"   # an existing decision file is probed as it is
  CLAUDE_PROJECT_DIR="$APPD" CLAUDE_PLUGIN_ROOT="$PL" edit "$(sid)" "$APPD/$1"
}
O=$(dprobe infra/agent/agent-files.map)
has "$O" 'kb/decisions/dg-lit.md' "[D1] a literal applyTo: the file itself gets the decision"
hasnt "$O" 'dg-skills.md' "[D1] …a decision whose glob does not match is not delivered"
hasnt "$(dprobe infra/agent/agent-files.map.bak)" 'dg-lit.md' "[D1] …a longer name (agent-files.map.bak) does not match a literal"
hasnt "$(dprobe infra/agent/agent-filesxmap)" 'dg-lit.md' "[D1] …the dot of a literal is a dot, not a wildcard"
has "$(dprobe infra/agent/skills/reviewer/SKILL.md)" 'dg-skills.md' "[D2] dir/** matches a file nested two levels down"
hasnt "$(dprobe infra/agent/other/SKILL.md)" 'dg-skills.md' "[D2] …dir/** does not match a sibling directory"
hasnt "$(dprobe infra/agent/skills-x/a.md)" 'dg-skills.md' "[D2] …dir/** does not match a directory that only shares the prefix"
has "$(dprobe clusters/acme-prod/app/x.yaml)" 'dg-deep.md' "[D3] **/*.yaml matches a file nested deep (the replacement order of **/ before **)"
has "$(dprobe top.yaml)" 'dg-deep.md' "[D3] …and a file at the root"
hasnt "$(dprobe clusters/acme-prod/app/x.yml)" 'dg-deep.md' "[D3] …**/*.yaml does not match another extension (.yml)"
hasnt "$(dprobe clusters/acme-prod/app/x.yaml.bak)" 'dg-deep.md' "[D3] …nor a name that only starts with the extension"
has "$(dprobe clusters/acme-prod/kustomization.yaml)" 'dg-star.md' "[D4] a mid-path * matches exactly one segment"
hasnt "$(dprobe clusters/a/b/kustomization.yaml)" 'dg-star.md' "[D4] …the * does not cross a /"
hasnt "$(dprobe clusters/kustomization.yaml)" 'dg-star.md' "[D4] …and does not match zero segments"
O=$(dprobe infra/agent/agent-files.map)
hasnt "$O" 'dg-cu.md' "[D5] a decision with status: superseded is not delivered, while the same applyTo delivers dg-lit.md"
# the hook names the edited file in its lead line, so the delivered form is the bullet "- <absolute path>"; the control is the bullet of dg-lit.md
has "$(dprobe infra/agent/agent-files.map)" "- $APPD/kb/decisions/dg-lit.md" "[D6] control: a delivered decision is a bullet with its absolute path"
hasnt "$(dprobe kb/decisions/dg-none.md)" "- $APPD/kb/decisions/dg-none.md" "[D6] a decision with no applyTo is never delivered, not even on an edit of itself"
hasnt "$(dprobe src/app.ts)" 'kb/decisions' "[D7] a path no glob matches: no decision at all (no empty heading either)"
APPE="$TMP/app-dec-none"; mk_app "$APPE" 0; mkdir -p "$APPE/src"; : > "$APPE/src/a.ts"
hasnt "$(CLAUDE_PROJECT_DIR="$APPE" CLAUDE_PLUGIN_ROOT="$PL" edit "$(sid)" "$APPE/src/a.ts")" 'kb/decisions' "[D7] a repo with no kb/decisions: no decision, no error text"

echo "== B1.7: the current-state index at SessionStart startup and compact, a string of its own =="
# The third SessionStart command injects the repo's index when `current_state.inject` is on. Every case below runs the real hook
# command of hooks.json on a plugin copy (the family takes it), so each planted break after the family turns its case red.
# shellcheck source=fixtures/ports.sh
. "$HERE/fixtures/ports.sh"
IDXON='{"schema": 1, "current_state": {"inject": true}}'
s_idx() {  # s_idx <plugin> <project> <source> — stdout of the index command
  local c; c=$(hook_cmds "$HOOKS" SessionStart "" | sed -n 3p)
  printf '{"session_id":"%s","hook_event_name":"SessionStart","source":"%s"}' "$(sid)" "$3" | CLAUDE_PROJECT_DIR="$2" CLAUDE_PLUGIN_ROOT="$1" bash -c "$c" 2>/dev/null
}
s_cat() {  # s_cat <plugin> <project> <source> — the context of the catalogue command (boi-canh)
  local c; c=$(hook_cmds "$HOOKS" SessionStart "" | sed -n 2p)
  ctx "$(printf '{"session_id":"%s","hook_event_name":"SessionStart","source":"%s"}' "$(sid)" "$3" | CLAUDE_PROJECT_DIR="$2" CLAUDE_PLUGIN_ROOT="$1" bash -c "$c" 2>/dev/null)"
}
mk_idx_app() {  # mk_idx_app <dir> <config json|-> <index text|-> — a git repo on main with that config and that index
  mkdir -p "$1/kb" "$1/src"; : > "$1/src/a.ts"
  [ "$2" = - ] || { mkdir -p "$1/.vibemaestro"; printf '%s' "$2" > "$1/.vibemaestro/sdlc.json"; }
  [ "$3" = - ] || printf '%s\n' "$3" > "$1/kb/current-state.md"
  git_ -C "$1" init -q -b main; git_ -C "$1" add -A; git_ -C "$1" commit -qm c1
}
mk_units() {  # mk_units <file> <units> — an index of exactly <units> UTF-16 units, starting IDX-HEAD and ending IDX-END
  python3 - "$1" "$2" <<'PY'
import sys
n = int(sys.argv[2]); head, end = "# IDX-HEAD\n", "IDX-END\n"
need = n - len(head) - len(end)
open(sys.argv[1], "w", encoding="utf-8", newline="").write(head + ("x" * 99 + "\n") * (need // 100) + "y" * (need % 100) + end)
PY
}
units() { python3 -c 'import sys; print(len(sys.stdin.read().encode("utf-16-le")) // 2)' <<<"$1"; }
IDX_NOWHERE='ssh://git@example.invalid/acme/app.git'
fam_index() {
  local P=$1 A O B R d REM SEED
  d=$(fresh); A="$d/app"; mk_idx_app "$A" "$IDXON" $'# State\n\n- IDX-TREE-LINE runs on the test box'
  O=$(s_idx "$P" "$A" startup)
  isjson "$O" && ok "[I1] startup: the index command prints valid hook JSON" || bad "[I1] startup: no valid JSON: ${O:0:100}"
  has "$(ctx "$O")" 'IDX-TREE-LINE' "[I1] startup: the context holds the index text"
  has "$(ctx "$O")" 'Current-state index of this repo, kb/current-state.md' "[I1] startup: …under its lead line, naming the file"
  has "$(ctx "$(s_idx "$P" "$A" compact)")" 'IDX-TREE-LINE' "[I2] compact: the context holds the index text again"
  empty "$(s_idx "$P" "$A" resume)" "[I3] resume: the index command prints nothing (measured and proposed, not injected)"
  empty "$(s_idx "$P" "$A" clear)" "[I4] clear: the index command prints nothing"
  empty "$(s_idx "$P" "$A" '')" "[I4b] no source in the payload: nothing"
  has "$(s_cat "$P" "$A" startup)" 'in a block of its own that starts "Current-state index of this repo"' "[I5] injected: the catalogue says the map is in context"
  hasnt "$(s_cat "$P" "$A" startup)" 'read it first' "[I5] …instead of \"read it first\""
  B=$(s_cat "$P" "$A" resume)
  has "$B" '`kb/current-state.md` is the map (what holds now, where to read more): read it first.' "[I5b] resume: today's sentence, word for word"
  hasnt "$B" 'block of its own' "[I5b] …and not the injected one"
  # exactly as today: injection off, no index, hooks off, an invalid config
  d=$(fresh); mk_idx_app "$d/off" - $'# State\n\n- IDX-TREE-LINE'
  empty "$(s_idx "$P" "$d/off" startup)" "[I6] no config (inject off by default): nothing"
  has "$(s_cat "$P" "$d/off" startup)" '`kb/current-state.md` is the map (what holds now, where to read more): read it first.' "[I6] …and today's sentence"
  mk_idx_app "$d/noidx" "$IDXON" -
  empty "$(s_idx "$P" "$d/noidx" startup)" "[I7] inject on, no index file: nothing"
  hasnt "$(s_cat "$P" "$d/noidx" startup)" 'is the map' "[I7] …and no sentence about the map, as today"
  mk_idx_app "$d/hoff" '{"schema": 1, "hooks": "off", "current_state": {"inject": true}}' $'# State\n\n- IDX-TREE-LINE'
  empty "$(s_idx "$P" "$d/hoff" startup)" "[I8] hooks off: nothing"
  mk_idx_app "$d/bad" '{"schema": 1, "current_state": {"inject": true}, "pr": {"draft": 1}}' $'# State\n\n- IDX-TREE-LINE'
  empty "$(s_idx "$P" "$d/bad" startup)" "[I8b] an invalid config: nothing from this command (the defaults hold inject off; the other two report it)"
  mk_idx_app "$d/newer" '{"schema": 1, "current_state": {"inject": true}, "bogus": 1}' $'# State\n\n- IDX-TREE-LINE'
  has "$(s_idx "$P" "$d/newer" startup)" IDX-TREE-LINE "[I8c] a key of a newer plugin is only a warning: the index is still injected (rule config-compat)"
  # the cap: 9,000 characters is injected whole, 9,001 is not injected at all
  mk_units "$A/kb/current-state.md" 9000
  O=$(s_idx "$P" "$A" startup); R=$(ctx "$O")
  has "$R" 'IDX-END' "[I9b] 9000 characters: injected whole (its last line is there)"
  [ "$(units "$R")" -le 10000 ] && ok "[I9c] …and the whole string is within 10000 ($(units "$R"))" || bad "[I9c] the string is $(units "$R") > 10000"
  mk_units "$A/kb/current-state.md" 9001
  O=$(s_idx "$P" "$A" startup); R=$(ctx "$O")
  hasnt "$R" 'IDX-HEAD' "[I9] 9001 characters: no index text"
  has "$R" 'NOT injected' "[I9] …one warning instead, saying it was not injected"
  has "$(sysm "$O")" 'not injected' "[I9] …and the person sees it"
  python3 -c 'import sys; open(sys.argv[1], "w").write("x" * (1 << 20) + "y\n")' "$A/kb/current-state.md"
  has "$(ctx "$(s_idx "$P" "$A" startup)")" 'over 1048576 bytes' "[I9d] an index over 1 MiB is over the cap without being read"
  # the label list: the renderer alone (the collector needs B1.6, see [I15])
  R=$(python3 - "$P/scripts" <<'PY'
import re, sys
sys.path.insert(0, sys.argv[1])
import vsdlc
u = lambda s: len(s.encode("utf-16-le")) // 2
rows = [("kb/state/p%d.md" % (i % 7), i + 1, "*chưa kiểm từ 2026-10-%02d*" % (1 + i % 28), None if i % 9 == 4 else (i * 3) % 40)
        for i in range(100)]
bad = []
for room in (1000, 300):
    out = vsdlc.render_labels(rows, room, 7)
    ls = out.split("\n")
    if u(out) > room:
        bad.append("room %d: %d units" % (room, u(out)))
    m = re.fullmatch(r"- \.\.\. and (\d+) more, not listed \(size cap\)", ls[-1])
    body = ls[1:-1]
    if not m or len(body) + int(m.group(1)) != 100:
        bad.append("room %d: the last line does not count the rest: %r" % (room, ls[-1]))
    if not all(re.fullmatch(r"- kb/state/p\d\.md:\d+ (no date|\d+ days?( OLD)?) \*chưa kiểm từ 2026-10-\d\d\*", x) for x in body):
        bad.append("room %d: a line is not whole: %r" % (room, body))
    ages = [None if " no date " in x else int(re.search(r":\d+ (\d+) day", x).group(1)) for x in body]
    k = ages.count(None)
    if not k or any(a is not None for a in ages[:k]) or ages[k:] != sorted(ages[k:], reverse=True):
        bad.append("room %d: not no-date first then oldest first: %r" % (room, ages))
full = vsdlc.render_labels(rows[:3], 1000, 7).split("\n")
if len(full) != 4 or "more" in full[-1]:
    bad.append("three labels that fit: %r" % full)
if vsdlc.render_labels(rows, 20, 7) != "" or vsdlc.render_labels([], 1000, 7) != "":
    bad.append("no room or no rows must be empty")
odd = vsdlc.render_labels([("kb/state/a\nb.md", 1, "*x*", 3)] + rows[:2], 1000, 7).split("\n")
if len(odd) != 4 or not all(x.startswith("- ") for x in odd[1:]):
    bad.append("a file name with a newline breaks a line: %r" % odd)
ov = vsdlc.render_labels(rows, 300, 7, over=True).split("\n")
m = re.fullmatch(r"- \.\.\. and (\d+) more, not listed \(size cap\)", ov[-1])
if "ran over" not in ov[0] or not m or len(ov) - 2 + int(m.group(1)) != 100:
    bad.append("ran over: not in the heading, or counted as a label: %r" % ov[:2])
print("; ".join(bad) or "OK")
PY
)
  eq "$R" OK "[I13] the label list: within its room (1000, 300), whole lines, no date first, one line counting the rest"
  # the label list in the string: with B1.6's labels stubbed (the scan), within 1000 and the whole within 10000
  R=$(python3 - "$P/scripts" "$A" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import current_state as S, sdlc_config as C, vsdlc
u = lambda s: len(s.encode("utf-16-le")) // 2
S.labels = lambda text, profile=None, today=None: ([(i, "*chưa kiểm từ 2026-10-01*", None, 18) for i in range(1, 300)], False)
cfg = C.load(sys.argv[2])[0]
cfg["current_state"]["labels"] = {"regex": "x", "max_age_days": 7}
bad = []
for n, what in ((9000, "big"), (40, "small")):
    open(sys.argv[2] + "/kb/current-state.md", "w").write("# IDX\n" + "x" * (n - 7) + "\n")
    ctx, _ = vsdlc.session_index(sys.argv[2], cfg)
    tail = ctx.split("\n\nUnchecked labels", 1)
    if len(tail) != 2:
        bad.append("%s: no label list" % what)
        continue
    if u(ctx) > 10000:
        bad.append("%s: the whole string is %d > 10000" % (what, u(ctx)))
    if u("Unchecked labels" + tail[1]) > 1000:
        bad.append("%s: the list is %d > 1000" % (what, u("Unchecked labels" + tail[1])))
print("; ".join(bad) or "OK")
PY
)
  case "$R" in *big:*) bad "[I14] index of 9000 with labels: $R";; *) ok "[I14] index of 9000 with labels: the whole string stays within 10000";; esac
  case "$R" in *small:*) bad "[I14b] small index with labels: $R";; *) ok "[I14b] small index with labels: the list stays within 1000";; esac
  # [I15] end to end with B1.6's scanning: only where it exists (on this branch alone it does not)
  if grep -q '^def labels(' "$P/scripts/current_state.py"; then
    mk_idx_app "$d/lab" '{"schema": 1, "current_state": {"inject": true, "labels": {"regex": "\\*chưa kiểm(?: từ (?P<date>[^*]*))?\\*", "max_age_days": 7}}}' \
      $'# State\n\n- A runs *chưa kiểm từ 2020-01-01*\n- B runs *chưa kiểm*'
    R=$(ctx "$(s_idx "$P" "$d/lab" startup)")
    has "$R" 'Unchecked labels of the ledger' "[I15] B1.6 present: the list follows the index"
    has "$R" 'kb/current-state.md:4 no date' "[I15] …a label with no date, by file and line"
    has "$R" 'kb/current-state.md:3' "[I15] …a dated label, by file and line"
    has "$R" ' OLD ' "[I15] …marked OLD past max_age_days"
    if grep -q '^def list_pages(' "$P/scripts/current_state.py"; then
      mk_idx_app "$d/labp" '{"schema": 1, "current_state": {"inject": true, "pages": "kb/state/*.md", "labels": {"regex": "\\*chưa kiểm(?: từ (?P<date>[^*]*))?\\*", "max_age_days": 7}}}' \
        $'# State\n\n- A: `kb/state/a.md`'
      mkdir -p "$d/labp/kb/state"; printf '# A\n\n- A runs *chưa kiểm từ 2020-01-02*\n' > "$d/labp/kb/state/a.md"
      has "$(ctx "$(s_idx "$P" "$d/labp" startup)")" 'kb/state/a.md:3' "[I15] B1.5 present: a label on a page is listed by page and line"
    else
      printf '  SKIP [I15] a label on a page needs B1.5 (current_state.list_pages): run in the trial merge\n'
    fi
  else
    printf '  SKIP [I15] the end-to-end label list needs B1.6 (current_state.labels): run in the trial merge\n'
  fi
  # a tree behind origin/main: the ref's index, marked
  REM="$d/remote.git"; git_ init -q --bare -b main "$REM"
  SEED="$d/seed"; git_ clone -q "$REM" "$SEED" 2>/dev/null; git_ -C "$SEED" checkout -q -b main 2>/dev/null
  mk_idx_seed() { mkdir -p "$SEED/kb" "$SEED/.vibemaestro" "$SEED/src"; printf '%s' "$IDXON" > "$SEED/.vibemaestro/sdlc.json"; printf '%s\n' "$1" > "$SEED/kb/current-state.md"; }
  push_s() { git_ -C "$SEED" add -A && git_ -C "$SEED" commit -qm "$1" && git_ -C "$SEED" push -q origin HEAD:main 2>/dev/null; }
  clone_s() { git_ clone -q "$REM" "$1" 2>/dev/null; git_ -C "$1" remote set-url origin "$IDX_NOWHERE"; }
  fetch_s() { git_ -C "$1" fetch -q "$REM" '+refs/heads/*:refs/remotes/origin/*'; }
  mk_idx_seed $'# State\n\n- IDX-TREE-LINE'; push_s c1
  clone_s "$d/behind"; clone_s "$d/both"; clone_s "$d/other"
  printf '%s\n' $'# State\n\n- IDX-ORIGIN-LINE' > "$SEED/kb/current-state.md"; push_s c2
  fetch_s "$d/behind"; fetch_s "$d/both"
  O=$(s_idx "$P" "$d/behind" startup); R=$(ctx "$O")
  has "$R" 'IDX-ORIGIN-LINE' "[I10] tree behind origin/main, the ref changed the index: the ref's text is injected"
  hasnt "$R" 'IDX-TREE-LINE' "[I10] …not the tree's stale text"
  has "$R" '[from origin/main: this tree is behind it by 1 commit' "[I10] …marked as the rule overlay marks it"
  has "$(sysm "$O")" 'injected from origin/main' "[I10] …and the person is told"
  git_ -C "$d/behind" merge -q --ff-only origin/main
  R=$(ctx "$(s_idx "$P" "$d/behind" startup)")
  has "$R" 'IDX-ORIGIN-LINE' "[I10b] control: brought up to date, the same text"
  hasnt "$R" '[from origin/main' "[I10b] …with no mark"
  printf '%s\n' $'# State\n\n- IDX-LOCAL-EDIT' > "$d/both/kb/current-state.md"
  R=$(ctx "$(s_idx "$P" "$d/both" startup)")
  has "$R" 'IDX-LOCAL-EDIT' "[I11] both changed it: the tree's own edit is injected"
  has "$R" 'changed it too and this tree is behind it' "[I11] …marked as such"
  : > "$SEED/src/b.ts"; push_s c3; fetch_s "$d/behind"
  R=$(ctx "$(s_idx "$P" "$d/behind" startup)")
  has "$R" 'IDX-ORIGIN-LINE' "[I12] behind, but the ref did not change the index: the tree's text"
  hasnt "$R" '[from origin/main' "[I12] …unmarked"
  # round 1: the whole string within 10,000 at a long path (the short mark), a ref text over the cap, an index over 1 MiB
  LP="$d/$(printf 'p%.0s' {1..200})/$(printf 'q%.0s' {1..200})/$(printf 'r%.0s' {1..200})"; mkdir -p "$(dirname "$LP")"
  clone_s "$LP"; mk_units "$LP/kb/current-state.md" 9000
  printf '%s\n' $'# State\n\n- IDX-C4' > "$SEED/kb/current-state.md"; push_s c4; fetch_s "$LP"
  R=$(ctx "$(s_idx "$P" "$LP" startup)")
  has "$R" 'IDX-END' "[I21] both changed a 9000-character index at a 600-character path: still injected whole"
  [ "$(units "$R")" -le 10000 ] && ok "[I21] …within 10000 ($(units "$R"))" || bad "[I21] the string is $(units "$R") > 10000"
  has "$R" "changed it too and this tree is behind it by" "[I21] …with the short mark"
  hasnt "$R" "the ref's text: git" "[I21] …which has no command"
  mk_units "$SEED/kb/current-state.md" 9001; push_s c5; fetch_s "$d/other"
  R=$(ctx "$(s_idx "$P" "$d/other" startup)")
  has "$R" 'kb/current-state.md of origin/main is 9001 characters' "[I25] origin/main's text over the cap: the warning says whose text it is"
  has "$R" '[from origin/main: this tree is behind it by' "[I25] …and keeps the mark"
  python3 -c 'import sys; open(sys.argv[1], "w").write("# BIG\n" + ("z" * 99 + "\n") * 11000)' "$SEED/kb/current-state.md"; push_s c6
  clone_s "$d/bigc"
  printf '%s\n' $'# State\n\n- IDX-SMALL-FIX' > "$SEED/kb/current-state.md"; push_s c7; fetch_s "$d/bigc"
  R=$(ctx "$(s_idx "$P" "$d/bigc" startup)")
  has "$R" 'IDX-SMALL-FIX' "[I24] an index over 1 MiB the tree never changed, fixed on origin/main: the ref's text"
  has "$R" '[from origin/main' "[I24] …marked"
  # round 1: only a regular file inside the tree is read
  echo 'SECRET-OUTSIDE' > "$d/secret.txt"; mk_idx_app "$d/sym" "$IDXON" -; ln -s ../../secret.txt "$d/sym/kb/current-state.md"
  R=$(ctx "$(s_idx "$P" "$d/sym" startup)")
  hasnt "$R" 'SECRET-OUTSIDE' "[I18] a symlinked index: the file it points to is not injected"
  has "$R" 'kb/current-state.md is a symlink: it was NOT injected' "[I18] …one warning naming why"
  mkdir -p "$d/outdir"; echo '# OUT-DIR-INDEX' > "$d/outdir/current-state.md"; mk_idx_app "$d/symd" "$IDXON" -
  rm -rf "$d/symd/kb"; ln -s ../outdir "$d/symd/kb"
  R=$(ctx "$(s_idx "$P" "$d/symd" startup)")
  hasnt "$R" 'OUT-DIR-INDEX' "[I18b] kb/ a symlink out of the tree: not injected"
  has "$R" 'sits under a symlink that leaves the tree' "[I18b] …one warning naming why"
  mk_idx_app "$d/fifo" "$IDXON" -; mkfifo "$d/fifo/kb/current-state.md"
  O=$(printf '{"session_id":"x","source":"startup"}' | CLAUDE_PROJECT_DIR="$d/fifo" CLAUDE_PLUGIN_ROOT="$P" timeout 8 bash -c "$(hook_cmds "$HOOKS" SessionStart "" | sed -n 3p)" 2>/dev/null)
  eq "$?" 0 "[I19] a FIFO as the index: rc 0 at once (no hang until the hook timeout)"
  has "$(ctx "$O")" 'is not a regular file: it was NOT injected' "[I19] …one warning"
  mk_idx_app "$d/noperm" "$IDXON" $'# State\n\n- NOPERM-LINE'; chmod 000 "$d/noperm/kb/current-state.md"
  if [ -r "$d/noperm/kb/current-state.md" ]; then
    printf '  SKIP [I20] this user reads a mode-000 file (root): the unreadable case cannot be built\n'
  else
    has "$(ctx "$(s_idx "$P" "$d/noperm" startup)")" 'cannot be read' "[I20] an unreadable index: one warning, not silence"
  fi
  chmod 644 "$d/noperm/kb/current-state.md"
  # round 1: the catalogue names the configured index; CRLF counts as LF
  mk_idx_app "$d/cpath" '{"schema": 1, "current_state": {"inject": true, "path": "docs/state.md"}}' $'# Old kb index'
  mkdir -p "$d/cpath/docs"; printf '# State\n\n- CPATH-LINE\n' > "$d/cpath/docs/state.md"
  has "$(ctx "$(s_idx "$P" "$d/cpath" startup)")" 'CPATH-LINE' "[I22] current_state.path docs/state.md: that file is injected"
  B=$(s_cat "$P" "$d/cpath" startup)
  has "$B" '`docs/state.md` is the map' "[I22] …and the catalogue names it"
  hasnt "$B" '`kb/current-state.md` is the map' "[I22] …not kb/current-state.md"
  mk_units "$A/kb/current-state.md" 8990; python3 -c 'import sys; p = sys.argv[1]; t = open(p).read(); open(p, "w", newline="").write(t.replace("\n", "\r\n"))' "$A/kb/current-state.md"
  [ "$(python3 -c 'import sys; print(len(open(sys.argv[1], newline="").read()))' "$A/kb/current-state.md")" -gt 9000 ] \
    && ok "[I23] instrument: the CRLF index is over 9000 characters raw" || bad "[I23] instrument: the CRLF index is not over 9000 raw"
  R=$(ctx "$(s_idx "$P" "$A" startup)")
  has "$R" 'IDX-END' "[I23] a CRLF checkout of an 8990-character index: injected (CRLF counts as LF)"
  case "$R" in *$'\r'*) bad "[I23] …the injected text still holds CR";; *) ok "[I23] …as LF text";; esac
  printf '# State\n\n- IDX-TREE-LINE\n' > "$A/kb/current-state.md"
  # never blocks: a corrupt index, a directory, git missing, stdin that is not JSON
  printf '# St\xff\xfeate\n' > "$A/kb/current-state.md"
  O=$(s_idx "$P" "$A" startup); eq "$?" 0 "[I16] an index that is not UTF-8 → rc 0"
  isjson "$O" && ok "[I16] …valid hook JSON" || bad "[I16] an index that is not UTF-8: ${O:0:100}"
  rm -f "$A/kb/current-state.md"; mkdir "$A/kb/current-state.md"
  O=$(s_idx "$P" "$A" startup); eq "$?" 0 "[I16b] the index path is a directory → rc 0"
  has "$(ctx "$O")" 'is not a regular file: it was NOT injected' "[I16b] …one warning, nothing read"
  rmdir "$A/kb/current-state.md"; printf '# State\n\n- IDX-TREE-LINE\n' > "$A/kb/current-state.md"
  mkdir -p "$d/nogit"; ln -sf "$(command -v python3)" "$d/nogit/python3"; ln -sf "$(command -v bash)" "$d/nogit/bash"
  O=$(printf '{"session_id":"x","source":"startup"}' | PATH="$d/nogit" CLAUDE_PROJECT_DIR="$A" CLAUDE_PLUGIN_ROOT="$P" "$d/nogit/bash" -c "$(hook_cmds "$HOOKS" SessionStart "" | sed -n 3p)" 2>/dev/null)
  eq "$?" 0 "[I16c] git missing from PATH → rc 0"; has "$(ctx "$O")" 'IDX-TREE-LINE' "[I16c] …the tree's text, unmarked"
  O=$(printf 'not-json' | CLAUDE_PROJECT_DIR="$A" CLAUDE_PLUGIN_ROOT="$P" bash -c "$(hook_cmds "$HOOKS" SessionStart "" | sed -n 3p)" 2>/dev/null)
  eq "$?" 0 "[I16d] stdin that is not JSON → rc 0"; empty "$O" "[I16d] …and nothing"
}
fam_index "$PL"
echo "== the skill line names every skill directory =="
fam_skill_list() {  # fam_skill_list <plugin dir> — the "Skills of the plugin" line against skills/<name>/SKILL.md of that plugin
  local p=$1 c line want got
  c=$(hook_cmds "$HOOKS" SessionStart '' | sed -n 2p)
  line=$(ctx "$(printf '%s' "$(p_start "$(sid)")" | CLAUDE_PROJECT_DIR="$APP" CLAUDE_PLUGIN_ROOT="$p" bash -c "$c" 2>/dev/null)" | grep -F 'Skills of the plugin')
  want=$(for f in "$p"/skills/*/SKILL.md; do [ -f "$f" ] && basename "$(dirname "$f")"; done | sort)
  got=$(printf '%s' "$line" | grep -oE 'vibemaestro-sdlc:[a-z0-9-]+' | sed 's/^vibemaestro-sdlc://' | sort)
  nonempty "$want" "[S0] instrument: the plugin has skill directories"
  eq "$got" "$want" "[S1] the skill line names every skills/<name>/SKILL.md, no more"
}
fam_skill_list "$PLUGIN"
SKP="$TMP/skill-planted"; mk_plugin_copy "$SKP"; mkdir -p "$SKP/skills/zz-planted"; printf -- '---\nname: zz-planted\n---\n' > "$SKP/skills/zz-planted/SKILL.md"
fam_skill_list "$SKP"
has "$(ctx "$(printf '%s' "$(p_start "$(sid)")" | CLAUDE_PROJECT_DIR="$APP" CLAUDE_PLUGIN_ROOT="$SKP" bash -c "$(hook_cmds "$HOOKS" SessionStart '' | sed -n 2p)" 2>/dev/null)")" \
  'vibemaestro-sdlc:zz-planted' "[S2] a new skill directory appears in the line with no code change"
SKB="$TMP/skill-break"; mk_plugin_copy "$SKB"
mutate "$SKB/scripts/vsdlc.py" '    mine = all_skills()' '    mine = plugin_skills()' && expect_red skill-line-chain-only fam_skill_list "$SKB" '[S1]'

IBRK() {  # IBRK <label> <needle> <file under scripts/> <old> <new> — one planted break, and fam_index must go red on <needle>
  local d="$TMP/ibreak-$1"; mk_plugin_copy "$d"
  mutate "$d/scripts/$3" "$4" "$5" && expect_red "$1" fam_index "$d" "$2"
}
IBRK idx-no-compact '[I2]' vsdlc.py 'INDEX_SOURCES = ("startup", "compact")' 'INDEX_SOURCES = ("startup",)'
IBRK idx-every-source '[I3]' vsdlc.py 'INDEX_SOURCES = ("startup", "compact")' 'INDEX_SOURCES = ("startup", "compact", "resume", "clear")'
IBRK idx-switch-ignored '[I6]' vsdlc.py '    if probs or cfg["hooks"] == "off" or not cfg["current_state"].get("inject"):' '    if probs or cfg["hooks"] == "off":'
IBRK idx-hooks-off-ignored '[I8]' vsdlc.py '    if probs or cfg["hooks"] == "off" or not cfg["current_state"].get("inject"):' '    if probs or not cfg["current_state"].get("inject"):'
IBRK idx-sentence-never '[I5]' vsdlc.py 'kb_reminder(troot, index_injects(cfg, source), ' 'kb_reminder(troot, False, '
IBRK idx-sentence-always '[I5b]' vsdlc.py 'kb_reminder(troot, index_injects(cfg, source), ' 'kb_reminder(troot, True, '
IBRK idx-sentence-path '[I22]' vsdlc.py 'kb_reminder(troot, index_injects(cfg, source), cfg["current_state"]["path"], cfg["language"])' 'kb_reminder(troot, index_injects(cfg, source), lang=cfg["language"])'
IBRK idx-cap-off '[I9]' vsdlc.py '    if not o["big"] and n <= S.INJECT_MAX_CHARS:' '    if not o["big"]:'
IBRK idx-cap-off-by-one '[I9b]' vsdlc.py '    if not o["big"] and n <= S.INJECT_MAX_CHARS:' '    if not o["big"] and n < S.INJECT_MAX_CHARS:'
IBRK idx-big-read '[I9d]' vsdlc.py '    if len(raw) > limit:' '    if False:'
IBRK idx-stale-tree-text '[I10]' vsdlc.py 'out.update(text=R._nl(files[rel]), ref=' 'out.update(text=local, ref='
IBRK idx-stale-unmarked '[I10]' vsdlc.py 'out.update(mark=R.upstream_mark(up, rel, troot, kind), short=_short_mark(up, kind))' 'out.update(mark="", short="")'
IBRK idx-symlink-read '[I18]' vsdlc.py '    if stat.S_ISLNK(st.st_mode):' '    if False:'
IBRK idx-dir-symlink-read '[I18b]' vsdlc.py '    if here != top and not here.startswith(' '    if False and not here.startswith('
IBRK idx-fifo-read '[I19]' vsdlc.py '    if not stat.S_ISREG(st.st_mode):' '    if False:'
IBRK idx-no-short-mark '[I21]' vsdlc.py 'for m in ((mark, o["short"]) if mark else ("",)):' 'for m in ((mark,) if mark else ("",)):'
IBRK idx-crlf-kept '[I23]' vsdlc.py '    return R._nl(raw.decode("utf-8", "replace")), False, None' '    return raw.decode("utf-8", "replace"), False, None'
IBRK idx-big-is-tree-edit '[I24]' vsdlc.py 'or big and (
            _read_index(troot, rel, COMPARE_MAX_READ)[0] != R._nl(base.get(rel)))):' 'or big):'
IBRK idx-ref-warning-unmarked '[I25]' vsdlc.py '(" of %s" % ref) if ref else ""' '""'
IBRK idx-label-name-raw '[I13]' vsdlc.py '(_oneline(f), i, when, lab)' '(f, i, when, lab)'
IBRK idx-ran-over-dropped '[I13]' vsdlc.py '"; the scan ran over its timer, so some are not listed" if over else ""' '""'
IBRK idx-overlay-skipped '[I10]' vsdlc.py 'files=(rel,), decisions=False) if probe' 'files=(), decisions=False) if probe'
IBRK idx-both-dropped '[I11]' vsdlc.py '    elif isinstance(base, dict) and (why' '    elif False and (why'
IBRK idx-render-uncapped '[I13]' vsdlc.py '        if used + n + (reserve if k < len(lines) - 1 else 0) > room:' '        if False:'
IBRK idx-render-no-rest '[I13]' vsdlc.py '            out.append(more % (len(lines) - k))' '            pass'
IBRK idx-render-order '[I13]' vsdlc.py 'key=lambda r: (r[3] is not None, -(r[3] or 0), r[0], r[1])' 'key=lambda r: (r[0], r[1])'
IBRK idx-labels-past-hook-cap '[I14]' vsdlc.py 'min(LABELS_MAX, HOOK_CAP - S.inject_chars(body) - 2)' 'LABELS_MAX'
IBRK idx-labels-past-1000 '[I14b]' vsdlc.py 'min(LABELS_MAX, HOOK_CAP - S.inject_chars(body) - 2)' 'HOOK_CAP - S.inject_chars(body) - 2'
IBRK idx-no-tail '[I14]' vsdlc.py 'return body + ("\n\n" + tail if tail else ""), sysmsg' 'return body, sysmsg'
IBRK idx-unchanged-ref-marked '[I12]' vsdlc.py '    elif rel not in files or (local is not None' '    elif (local is not None'
QN=0; okdef=$(declare -f ok); baddef=$(declare -f bad); sp=$PASS; sf=$FAIL
ok() { :; }; bad() { QN=$((QN+1)); }
IPC="$TMP/ibreak-none"; mk_plugin_copy "$IPC"; fam_index "$IPC" >/dev/null 2>&1
eval "$okdef"; eval "$baddef"; PASS=$sp; FAIL=$sf
eq "$QN" 0 "control: an unbroken copy passes fam_index (no failed check)"
# a failure inside the index command is one warning naming it, rc 0 (current_state.py raising on import)
IPX="$TMP/idx-raise"; mk_plugin_copy "$IPX"; printf 'raise RuntimeError("no")\n' > "$IPX/scripts/current_state.py"
d=$(mktemp -d "$TMP/f.XXXXXX"); mk_idx_app "$d/app" "$IDXON" $'# State\n\n- IDX-TREE-LINE'
O=$(s_idx "$IPX" "$d/app" startup); eq "$?" 0 "[I17] the index code raises → rc 0"
has "$(ctx "$O")" 'the current-state index could not be injected (RuntimeError)' "[I17] …one warning naming the failure"
has "$(ctx "$O")" 'read kb/current-state.md first' "[I17] …telling the session to read the file"
mutate "$IPX/scripts/vsdlc.py" '    except Exception as e:
        msg = "the current-state index could not be injected' '    except ZeroDivisionError as e:
        msg = "the current-state index could not be injected' \
  && hasnt "$(ctx "$(s_idx "$IPX" "$d/app" startup)")" 'could not be injected' "[I17] planted break: without the guard the specific warning is gone (the probe sees it)"

echo "== G2: plugin không ghi vào repo app / cây plugin =="
# Plugin và repo app DỰNG MỚI cho phần này: cây đã chạy hook nhiều lần ở trên thì __pycache__ (nếu có) đã nằm sẵn
# trong lần băm đầu và phép so không còn thấy nó.
PL="$TMP/plugin-g2"; mk_plugin "$PL"; APP="$TMP/app-g2"; mk_app "$APP"
H0=$(tree_hash "$PL"); P0=$(git_state "$APP"); A0=$(tree_hash "$APP")
PYSHIM="$TMP/pyshim"; mkdir -p "$PYSHIM"; REALPY=$(command -v python3)
# python3 của macOS mặc định đặt pycache_prefix ra ~/Library/Caches nên KHÔNG BAO GIỜ ghi __pycache__ cạnh nguồn — phép đo sẽ mù.
# Shim `-X pycache_prefix=` (rỗng) trả về hành vi chuẩn để phép đo có nghĩa.
printf '#!/bin/sh\nexec "%s" -X pycache_prefix= "$@"\n' "$REALPY" > "$PYSHIM/python3"; chmod +x "$PYSHIM/python3"
S=$(sid)
PATH="$PYSHIM:$PATH" inapp sess_one 1 "$S" >/dev/null; PATH="$PYSHIM:$PATH" inapp sess_one 2 "$S" >/dev/null
PATH="$PYSHIM:$PATH" inapp edit "$S" "$APP/clusters/x.yaml" >/dev/null
PATH="$PYSHIM:$PATH" inapp bashc "$S" "lenh-bay" >/dev/null; PATH="$PYSHIM:$PATH" inapp bashc "$S" "nguy-hiem" >/dev/null
eq "$(tree_hash "$PL")" "$H0" "cây plugin: băm không đổi sau cả luồng (không __pycache__, không file lạ)"
eq "$(find "$PL" -name __pycache__ | wc -l | tr -d ' ')" 0 "cây plugin: không có __pycache__"
eq "$(git_state "$APP")" "$P0" "repo app: git status không đổi"
eq "$(tree_hash "$APP")" "$A0" "repo app: băm cây không đổi"
# đối chứng dương cho dụng cụ: import KHÔNG tắt bytecode thì plugin có __pycache__ — phép đếm thấy được
PLC="$TMP/plugin-ctl"; cp -r "$PL" "$PLC"
(cd "$PLC/scripts" && PYTHONDONTWRITEBYTECODE= PATH="$PYSHIM:$PATH" python3 -c 'import rules')
[ "$(find "$PLC" -name __pycache__ | wc -l)" -gt 0 ] && ok "đối chứng dương: import thường thì có __pycache__ (phép đo bắt được)" || bad "phép đo __pycache__ không bắt được ca dương"
printf 'x' >> "$PL/rules/zz-tam"; ne "$(tree_hash "$PL")" "$H0" "đối chứng dụng cụ: thêm một file vào plugin → băm đổi"; rm -f "$PL/rules/zz-tam"

summary
