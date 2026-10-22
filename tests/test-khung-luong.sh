#!/bin/bash
# =============================================================================
# Plugin vibemaestro-sdlc làm khung ở repo app — lời nhắc luồng, skill brainstorm, ship bổ sung, manifest
# =============================================================================
# Chạy: bash tests/test-khung-luong.sh
#
# Suite này KHÔNG chạy `claude` (trừ phần --help) và không cần model: nó chạy ĐÚNG chuỗi `command` SessionStart của hooks.json
# (lib.sh) trên một bản chép plugin ở repo app giả, then đọc skill bằng grep. Nó chứng minh MÃ HOOK IN RA GÌ; phiên Claude Code
# thật có làm theo lời nhắc hay không là *chưa kiểm* (cần login `claude`).
# Mỗi assert "không có X" đi cặp một ca dương trong cùng trạng thái — grep trả 0 vì chuỗi thật sự vắng, không vì dụng cụ hỏng.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
HOOKS="$PLUGIN/hooks/hooks.json"
[ -f "$HOOKS" ] || { echo "FAIL không có $HOOKS"; exit 1; }

TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"

PLX="$TMP/plugin"; mk_plugin "$PLX"      # bản chép plugin thật (skill + script thật), bộ luật giả
APP="$TMP/app"; mk_app "$APP"
# boi: stdout của hook SessionStart thứ hai (danh mục + nhắc) — plugin gốc là $CLAUDE_PLUGIN_ROOT của người gọi
boi() {  # boi <thư mục dự án> [VAR=val ...] — plugin = $PL (mặc định bản chép $PLX)
  local proj=$1; shift
  local c; c=$(hook_cmds "$HOOKS" SessionStart "" | sed -n 2p)
  printf '%s' "$(p_start "$(sid)")" | env "$@" CLAUDE_PROJECT_DIR="$proj" CLAUDE_PLUGIN_ROOT="${PL:-$PLX}" bash -c "$c" 2>/dev/null
}
loi() {  # loi <thư mục dự án> — stdout của hook SessionStart ĐẦU (lõi quy trình), cùng cách chạy với boi
  local proj=$1; shift
  local c; c=$(hook_cmds "$HOOKS" SessionStart "" | sed -n 1p)
  printf '%s' "$(p_start "$(sid)")" | env "$@" CLAUDE_PROJECT_DIR="$proj" CLAUDE_PLUGIN_ROOT="${PL:-$PLX}" bash -c "$c" 2>/dev/null
}
FLOW_HEAD='The work flow in an app repo'
flow_lines() {  # đoạn lời nhắc luồng: từ dòng mở đầu tới dòng trống đầu tiên
  awk -v h="$FLOW_HEAD" 'index($0,h){f=1} f&&$0==""{exit} f' <<<"$1"
}
rm_names_ok() {  # rm_names_ok <văn bản README> <tên marketplace> — rc 0 khi mọi `marketplace update X` và `…@X` dùng đúng tên, và có ≥ 1 lệnh để so
  local t=$1 n=$2 b
  printf '%s\n' "$t" | grep -qE '^claude plugin marketplace update ' || return 1
  printf '%s\n' "$t" | grep -qE 'vibemaestro-sdlc@' || return 1
  b=$(printf '%s\n' "$t" | grep -E '^claude plugin marketplace update ' | grep -vFx "claude plugin marketplace update $n" || true)
  b+=$(printf '%s\n' "$t" | grep -oE 'vibemaestro-sdlc@[A-Za-z0-9_.-]+' | grep -vFx "vibemaestro-sdlc@$n" || true)
  [ -z "$b" ]
}
flow_shape() {  # "<số dòng không trống> <số dòng trống> <dòng ngay trước danh mục có trống không 1|0>" của khối từ dòng mở đầu tới dòng
  # trước "The plugin's common rules are in" — không dừng ở dòng trống đầu tiên, nên bỏ dòng trống phân tách là lộ ra (flow_lines thì đo lẹm sang danh mục)
  awk -v h="$FLOW_HEAD" -v e="The plugin's common rules are in" 'index($0,h){f=1} f&&index($0,e){exit} f{if($0==""){b++;pb=1}else{n++;pb=0}} END{print n+0, b+0, pb+0}' <<<"$1"
}
mut_lacks() {  # mut_lacks <văn bản> <từ> <thành> <literal> <nhãn> — đối chứng cho `has`: bản bị phá đúng kiểu (a) KHÁC bản gốc, (b) mất literal
  local t=$1 from=$2 to=$3 lit=$4 lbl=$5 m
  m=${t//"$from"/"$to"}
  [ "$m" != "$t" ] || { bad "$lbl (phép phá không đổi gì — đối chứng vô nghĩa)"; return; }
  case "$m" in *"$lit"*) bad "$lbl (literal còn sau khi phá)";; *) ok "$lbl";; esac
}
mut_has() {  # mut_has <văn bản> <từ> <thành> <literal> <nhãn> — đối chứng cho `hasnt`: bản bị phá đúng kiểu (a) KHÁC bản gốc, (b) CÓ literal cấm
  local t=$1 from=$2 to=$3 lit=$4 lbl=$5 m
  m=${t//"$from"/"$to"}
  [ "$m" != "$t" ] || { bad "$lbl (phép phá không đổi gì — đối chứng vô nghĩa)"; return; }
  case "$m" in *"$lit"*) ok "$lbl";; *) bad "$lbl (literal cấm không xuất hiện sau khi phá)";; esac
}
seq_of() {  # seq_of <văn bản> — "1.brainstorm,2.spec,…": skill đầu tiên của mỗi dòng đánh số dưới 'Bước tiếp, theo thứ tự'
  awk '/Next steps, in order/{f=1;next} f&&/^[0-9]+\./{n=$1; if(match($0,/vibemaestro-sdlc:[a-z-]+/)) print n substr($0,RSTART+17,RLENGTH-17)}' <<<"$1" | paste -sd, -
}
fence_lang() {  # fence_lang <văn bản> <chuỗi> — nhãn ngôn ngữ của khối ``` chứa <chuỗi> (rỗng nếu không khối nào chứa)
  awk -v n="$2" '/^```/{ if(inb){ if(hit){print lang; exit} inb=0; hit=0 } else { inb=1; lang=substr($0,4); hit=0 } next } inb&&index($0,n){hit=1}' <<<"$1"
}
posof() { awk -v n="$2" 'index($0,n){print NR; exit}' <<<"$1"; }
mkpl() {  # mkpl <tên> [skill bỏ đi ...] — bản chép plugin thật, bỏ thư mục skill đã nêu
  local d="$TMP/pl-$1"; shift
  cp -r "$PLX" "$d"
  local s; for s in "$@"; do rm -rf "$d/skills/$s"; done
  echo "$d"
}

echo "== dụng cụ: seq_of / fence_lang trên ca không có gì → rỗng (không xanh vì rỗng) =="
eq "$(seq_of 'không có mục nào')" "" "seq_of trên văn bản không có 'Bước tiếp' → rỗng"
eq "$(fence_lang 'không có khối nào' 'x')" "" "fence_lang trên văn bản không có khối → rỗng"
eq "$(fence_lang $'```fish\nabc\n```\n```bash\nxyz\n```' 'xyz')" bash "fence_lang chọn đúng khối chứa chuỗi (không phải khối fish đứng trước)"

echo "== R1: lời nhắc luồng ở repo app, không phải sandbox =="
O=$(boi "$APP"); C=$(ctx "$O")
isjson "$O" && ok "hook danh mục in JSON hợp lệ" || bad "hook danh mục không in JSON: ${O:0:100}"
has "$C" "The plugin's common rules are in" "đối chứng dụng cụ: ngữ cảnh có danh mục luật (hook thật đã chạy)"
hasnt "$C" 'Sandbox session' "đối chứng: không phải sandbox (không có đoạn hành vi đầu tiên của sandbox)"
has "$C" "$FLOW_HEAD" "có lời nhắc luồng"
F=$(flow_lines "$C"); N=$(printf '%s\n' "$F" | grep -c .)
# Mọi assert về NỘI DUNG lời nhắc đo trên $F (đoạn lời nhắc), không phải $C: dòng "Skill của plugin (vừa kiểm là có mặt)…" cùng
# ngữ cảnh đã chứa mọi tên skill, nên đo trên $C thì chuỗi cụt hay đảo thứ tự vẫn xanh.
has "$C" 'Skills of the plugin' "đối chứng dụng cụ: ngữ cảnh còn dòng liệt kê skill (nơi tên skill có sẵn ngoài lời nhắc)"
has "$F" '`vibemaestro-sdlc:intake`' "nhắc skill intake (đầu chuỗi)"
has "$F" "the plugin's process WINS over the third-party process plugin" "plugin thắng plugin quy trình bên thứ ba (đúng chiều)"
hasnt "$F" 'the third-party process plugin WINS' "không đảo chiều: plugin quy trình bên thứ ba thắng plugin"
has "$F" "the user's instructions rank above its skills" "căn cứ: lời của chính plugin quy trình bên thứ ba"
# Căn cứ chỉ nêu điều KIỂM ĐƯỢC: plugin quy trình bên thứ ba chỉ liệt kê CLAUDE.md/AGENTS.md/GEMINI.md/yêu cầu trực tiếp — hook plugin không thuộc danh sách,
# nên lời nhắc không được nói "phiên sẽ coi đây là chỉ dẫn của người dùng".
has "$F" 'because this is the process the user set for this plugin in an app repo' "căn cứ: đây là quy trình người dùng đặt cho plugin này (điều đã biết)"
has "$F" '(a hook reminder, not CLAUDE.md)' "căn cứ: nói rõ đây là lời nhắc của hook, không phải CLAUDE.md"
for w in 'their own' 'has set this plugin as the frame' 'this block is that instruction' 'so the rule'; do hasnt "$F" "$w" "không quay lại khẳng định suy diễn (hook = chỉ dẫn người dùng): '$w'"; done
mut_has "$F" '(a hook reminder, not CLAUDE.md)' 'so the rule below is their own' 'their own' "đối chứng dụng cụ: quay lại câu suy diễn → 'their own' xuất hiện (hasnt bắt được)"
mut_lacks "$F" "the plugin's process WINS over the third-party process plugin" "the third-party process plugin WINS over the plugin's process" "the plugin's process WINS over the third-party process plugin" "đối chứng dụng cụ: đảo chiều thắng/thua → câu đúng chiều vắng (has bắt được)"
for w in '"redo"' '"make a plan"' '"design"' '"add a feature"' 'a UI change'; do has "$F" "$w" "nêu từ người dùng hay gõ: $w"; done
has "$F" 'do NOT use' "có câu cấm"
for sp in '`brainstorming` (the plugin already has' '`writing-plans` (the plugin already has' '`finishing-a-development-branch` (the plugin already has'; do
  has "$F" "$sp" "nêu skill không dùng: $sp"
done
has "$F" 'Write the output into `kb/intent`, `kb/specs`, `kb/plans` of this very repo, not into the default output directory of the third-party process plugin (under `docs/`).' "câu đầu ra nguyên văn: vào kb/, KHÔNG vào thư mục đầu ra của plugin bên thứ ba (đo cả phủ định, không chỉ tên thư mục)"
hasnt "$F" 'the default output directory of the third-party process plugin is fine too' "không cho phép thư mục đầu ra của plugin bên thứ ba"
mut_lacks "$F" 'not into the default output directory of the third-party process plugin' 'the default output directory of the third-party process plugin is fine too' 'not into the default output directory of the third-party process plugin' "đối chứng dụng cụ: đảo nghĩa câu thư mục đầu ra (tên thư mục vẫn còn) → câu phủ định vắng"
mut_lacks "$F" 'not into the default output directory of the third-party process plugin' 'into the default output directory of the third-party process plugin' 'not into the default output directory of the third-party process plugin' "đối chứng dụng cụ: bỏ chữ 'không' → câu phủ định vắng"
has "$F" '`test-driven-development`' "skill bên thứ ba không trùng việc vẫn dùng: test-driven-development"
has "$F" '`systematic-debugging`' "… systematic-debugging"
has "$F" '`verification-before-completion`' "… verification-before-completion"
# Chuỗi nguyên văn, đủ thứ tự và đủ phần tử: cụt hay đảo bước đều làm literal này vắng.
CHAIN='`vibemaestro-sdlc:intake`, then `vibemaestro-sdlc:brainstorm` (when the request is still vague), then `vibemaestro-sdlc:spec`, then `vibemaestro-sdlc:plan` (when the work must be split), then `vibemaestro-sdlc:ship`'
has "$F" "$CHAIN" "chuỗi đủ năm skill, đúng thứ tự, brainstorm 'khi yêu cầu còn mơ hồ', plan 'khi cần chia việc'"
for s in brainstorm spec plan ship; do has "$F" "vibemaestro-sdlc:$s" "đoạn lời nhắc (không phải cả ngữ cảnh) nêu skill $s"; done
has "$F" 'Every request for a change' "có intake → câu 'mọi yêu cầu thay đổi … bắt đầu bằng intake'"
has "$F" 'starts with `vibemaestro-sdlc:intake`' "… và skill bắt đầu đúng là intake"
has "$F" 'Call the first skill of the chain BEFORE you read code' "câu mệnh lệnh: gọi skill đầu chuỗi trước khi đọc code"
has "$F" 'a clarifying question to the person is part of that skill itself' "… và nói hỏi người làm rõ là một phần của skill đầu chuỗi (khớp intake bước 2 'hỏi người nếu thiếu')"
[ "$N" -le 15 ] && [ "$N" -ge 4 ] && ok "đoạn lời nhắc dài $N dòng (≤ 15, và ≥ 4 chứng tỏ dụng cụ cắt đúng đoạn)" || bad "đoạn lời nhắc dài $N dòng (cần 4..15)"
# flow_lines dừng ở dòng trống đầu tiên, nên bỏ dòng trống phân tách làm nó đo lẹm sang danh mục (và "≤ 15" chỉ đúng nhờ fixture ít luật). flow_shape đo tới TRƯỚC danh mục.
read -r SN SB SP <<<"$(flow_shape "$C")"
[ "$SN" -le 15 ] && [ "$SN" -ge 4 ] && ok "khối trước danh mục luật: $SN dòng (≤ 15, đo tới dòng 'Luật chung của plugin', không nhờ dòng trống)" || bad "khối trước danh mục luật: $SN dòng (cần 4..15)"
eq "$SB $SP" "1 1" "đúng MỘT dòng trống, và nó ngay trước danh mục luật (đoạn tách khỏi danh mục, không có dòng trống giữa đoạn)"
eq "$SN" "$N" "đối chứng: hai cách đo (tới dòng trống / tới danh mục) cùng một số dòng khi đoạn tách đúng"
CNB=${C//$'\n\nThe plugin\'s common rules are in'/$'\nThe plugin\'s common rules are in'}      # phép phá: bỏ dòng trống sau đoạn
[ "$CNB" != "$C" ] && ok "đối chứng dụng cụ: phép bỏ dòng trống thật sự đổi ngữ cảnh" || bad "đối chứng dụng cụ: phép bỏ dòng trống không đổi gì"
read -r _ FSB _ <<<"$(flow_shape "$CNB")"
eq "$FSB" 0 "đối chứng dụng cụ: bỏ dòng trống sau đoạn → flow_shape thấy 0 dòng trống (assert 'đúng MỘT dòng trống' sẽ đỏ)"
eq "$(flow_lines 'không có gì ở đây' | grep -c .)" 0 "đối chứng dụng cụ: flow_lines trên chuỗi không có đoạn → 0 dòng"
# đối chứng cho has/hasnt trên $F: cùng đoạn nhưng đã bị phá đúng kiểu → literal phải vắng
FB=${F//'then `vibemaestro-sdlc:plan` (when the work must be split), then `vibemaestro-sdlc:ship`'/}
hasnt "$FB" "$CHAIN" "đối chứng dụng cụ: chuỗi cụt → literal chuỗi vắng"
FB=${F//"the plugin's process WINS over the third-party process plugin"/"the third-party process plugin WINS over the plugin's process"}
hasnt "$FB" "the plugin's process WINS over the third-party process plugin" "đối chứng dụng cụ: đảo chiều thắng/thua → câu đúng chiều vắng"
FB=${F//'Call the first skill of the chain BEFORE you read code'/}
hasnt "$FB" 'Call the first skill of the chain BEFORE you read code' "đối chứng dụng cụ: xoá câu mệnh lệnh → câu vắng"
P1=$(posof "$C" "$FLOW_HEAD"); P2=$(posof "$C" "The plugin's common rules are in")
[ -n "$P1" ] && [ -n "$P2" ] && [ "$P1" -lt "$P2" ] && ok "lời nhắc luồng đứng TRƯỚC danh mục luật (dòng $P1 < $P2)" || bad "lời nhắc luồng không đứng trước danh mục ($P1, $P2)"
[ "$(nchars "$C")" -le 9000 ] && ok "ngữ cảnh $(nchars "$C") ký tự, trong trần 9.000" || bad "ngữ cảnh vượt trần: $(nchars "$C")"

echo "== R1: hook lõi (SessionStart đầu) không mang lời nhắc luồng =="
OL=$(loi "$APP"); CL=$(ctx "$OL")
nonempty "$CL" "đối chứng dụng cụ: hook lõi chạy và in ngữ cảnh (ca dương — nếu rỗng thì phép 'không có' dưới đây vô nghĩa)"
hasnt "$CL" "$FLOW_HEAD" "hook lõi KHÔNG chứa lời nhắc luồng (nó ăn trần 10.000 ký tự riêng của lõi)"
hasnt "$CL" 'vibemaestro-sdlc:intake' "hook lõi không nhắc skill của chuỗi"
O=$(boi "$APP"); has "$(ctx "$O")" "$FLOW_HEAD" "đối chứng: hook thứ hai CÓ lời nhắc luồng (cùng repo app, cùng cách chạy)"

echo "== R1: a repo with the legacy hook markers is not silent (2.0.0) =="
PHR="$TMP/repo-co-hook"; mk_app "$PHR"; mkdir -p "$PHR/.claude"
printf '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"python3 a/instructions-for-path.py"},{"type":"command","command":"python3 a/instructions-for-command.py"}]}]}}\n' > "$PHR/.claude/settings.json"
O=$(boi "$PHR"); has "$(ctx "$O")" "$FLOW_HEAD" "cwd is a repo with the legacy hook markers: the flow reminder is given"
mkdir -p "$PHR/.vibemaestro"; printf '{"hooks": "off"}\n' > "$PHR/.vibemaestro/sdlc.json"
O=$(boi "$PHR"); empty "$O" "control: the same repo with hooks: off is silent (the check can see silence)"

echo "== R1/A7: skill vắng thì không được nhắc tên =="
PL=$(mkpl no-brainstorm brainstorm) O=$(PL="$PL" boi "$APP"); C=$(ctx "$O")
has "$C" "$FLOW_HEAD" "bỏ brainstorm: vẫn có lời nhắc luồng"
hasnt "$C" 'vibemaestro-sdlc:brainstorm' "bỏ brainstorm → không nhắc skill đó"
hasnt "$C" '`brainstorming` (the plugin already has' "bỏ brainstorm → không cấm skill brainstorming bên thứ ba (không có gì thay)"
has "$C" '`writing-plans` (the plugin already has' "đối chứng: plan còn → vẫn cấm writing-plans"
has "$(flow_lines "$C")" 'vibemaestro-sdlc:plan' "đối chứng: plan còn → lời nhắc luồng nhắc plan"
PL=$(mkpl no-plan plan) O=$(PL="$PL" boi "$APP"); C=$(ctx "$O")
hasnt "$C" 'vibemaestro-sdlc:plan' "bỏ plan → không nhắc plan"
hasnt "$C" '`writing-plans` (the plugin already has' "bỏ plan → không cấm writing-plans"
has "$C" '`brainstorming` (the plugin already has' "đối chứng: brainstorm còn → vẫn cấm skill brainstorming bên thứ ba"
PL=$(mkpl no-ship ship) O=$(PL="$PL" boi "$APP"); C=$(ctx "$O")
hasnt "$C" 'vibemaestro-sdlc:ship' "bỏ ship → không nhắc ship"
hasnt "$C" '`finishing-a-development-branch` (the plugin already has' "bỏ ship → không cấm finishing-a-development-branch"
PL=$(mkpl no-intake intake) O=$(PL="$PL" boi "$APP"); C=$(ctx "$O")
hasnt "$C" 'vibemaestro-sdlc:intake' "bỏ intake → không nhắc intake"
F=$(flow_lines "$C")
hasnt "$F" 'bắt đầu bằng' "bỏ intake → KHÔNG nói 'bắt đầu bằng <skill không phải đầu quy trình>'"
hasnt "$F" 'Every request for a change' "bỏ intake → không có câu 'Every request for a change …'"
has "$F" 'follows the skills present here, in the order of the work: `vibemaestro-sdlc:brainstorm` (when the request is still vague), then `vibemaestro-sdlc:spec`, then `vibemaestro-sdlc:plan` (when the work must be split), then `vibemaestro-sdlc:ship`' "bỏ intake → chuỗi còn lại nêu đúng thứ tự, nói rõ là skill có mặt"
has "$F" 'call it BEFORE you read code' "bỏ intake → vẫn có câu mệnh lệnh (gọi skill của khâu đang đứng)"
has "$F" "the plugin's process WINS over the third-party process plugin" "bỏ intake → vẫn có câu plugin thắng"
PL=$(mkpl chi-ship intake brainstorm spec plan) O=$(PL="$PL" boi "$APP"); C=$(ctx "$O"); F=$(flow_lines "$C")
has "$F" "$FLOW_HEAD" "chỉ còn ship: vẫn có lời nhắc luồng"
has "$F" '`vibemaestro-sdlc:ship`' "chỉ còn ship: nhắc ship"
hasnt "$F" 'starts with `vibemaestro-sdlc:ship`' "chỉ còn ship: không nói 'bắt đầu bằng ship'"
hasnt "$F" 'bắt đầu bằng' "chỉ còn ship: không câu 'bắt đầu bằng …' nào"
for s in intake brainstorm spec plan; do hasnt "$C" "vibemaestro-sdlc:$s" "chỉ còn ship: không nhắc $s (vắng)"; done
has "$F" '`finishing-a-development-branch` (the plugin already has' "chỉ còn ship: cấm finishing-a-development-branch (ship thay nó)"
hasnt "$F" '`brainstorming` (the plugin already has' "chỉ còn ship: không cấm brainstorming (brainstorm vắng)"
PL=$(mkpl chi-spec intake brainstorm plan ship) O=$(PL="$PL" boi "$APP"); C=$(ctx "$O"); F=$(flow_lines "$C")
has "$F" '`vibemaestro-sdlc:spec`' "chỉ còn spec: nhắc spec"
hasnt "$F" 'bắt đầu bằng' "chỉ còn spec: không câu 'bắt đầu bằng …' nào"
hasnt "$F" 'Every request for a change' "chỉ còn spec: không 'Every request for a change …'"
for s in intake brainstorm plan ship; do hasnt "$C" "vibemaestro-sdlc:$s" "chỉ còn spec: không nhắc $s (vắng)"; done
hasnt "$F" 'do NOT use' "chỉ còn spec: không có skill nào thay skill của plugin bên thứ ba → không câu cấm"
PL=$(mkpl chi-intake brainstorm spec plan ship) O=$(PL="$PL" boi "$APP"); C=$(ctx "$O"); F=$(flow_lines "$C")
has "$F" 'Every request for a change' "đối chứng: còn intake → có câu 'Every request for a change …' (ca âm ở trên thật sự khác)"
PL=$(mkpl chi-init-kb intake brainstorm spec plan ship) O=$(PL="$PL" boi "$APP"); C=$(ctx "$O")
hasnt "$C" "$FLOW_HEAD" "không skill nào của chuỗi có mặt → không có lời nhắc luồng"
hasnt "$C" 'plugin quy trình bên thứ ba' "… và không nhắc gì về plugin quy trình bên thứ ba"
has "$C" 'vibemaestro-sdlc:init-kb' "đối chứng: init-kb còn → vẫn được nhắc như cũ"

# lời nhắc của nhánh thiếu intake vẫn nêu các từ người dùng hay gõ (phiên chọn skill theo từ khoá, không theo mô tả)
for v in no-intake:intake chi-ship:intake,brainstorm,spec,plan chi-spec:intake,brainstorm,plan,ship; do
  PL=$(mkpl "t-${v%%:*}" $(tr ',' ' ' <<<"${v#*:}")) O=$(PL="$PL" boi "$APP"); F=$(flow_lines "$(ctx "$O")")
  hasnt "$F" 'bắt đầu bằng' "(${v%%:*}) nhánh thiếu intake: không câu 'bắt đầu bằng' — đối chứng cho các từ khoá dưới đây (cùng nhánh)"
  for w in '"redo"' '"make a plan"' '"design"' '"add a feature"' 'a UI change'; do has "$F" "$w" "(${v%%:*}) nhánh thiếu intake vẫn nêu từ người dùng hay gõ: $w"; done
  N=$(printf '%s\n' "$F" | grep -c .); [ "$N" -le 15 ] && [ "$N" -ge 4 ] && ok "(${v%%:*}) đoạn lời nhắc $N dòng (4..15)" || bad "(${v%%:*}) đoạn lời nhắc $N dòng (cần 4..15)"
done
mut_lacks "$F" '"redo"' 'XX' '"redo"' "đối chứng dụng cụ: xoá từ '"redo"' khỏi đoạn → vắng (has bắt được)"

unset PL      # `PL=$(mkpl …)` ở trên gán biến shell chính; các ca dưới dùng plugin thật trừ khi tự gán PL
echo "== R1/Y3: repo chưa có kb/ — lời nhắc luồng khớp kb_reminder và intake (init-kb trước) =="
NOKB="$TMP/app-nokb"; mk_app "$NOKB" 0
[ ! -d "$NOKB/kb" ] && ok "đối chứng dụng cụ: app giả không có kb/" || bad "mk_app 0 vẫn dựng kb/"
O=$(boi "$NOKB"); C=$(ctx "$O"); F=$(flow_lines "$C")
has "$C" 'This repo has no `kb/` yet: use the skill `vibemaestro-sdlc:init-kb`' "kb_reminder (không đổi): chưa có kb/ → init-kb trước"
has "$F" 'starts with `vibemaestro-sdlc:init-kb` (this repo has no `kb/` yet), then `vibemaestro-sdlc:intake`, then `vibemaestro-sdlc:brainstorm` (when the request is still vague)' "chưa có kb/ → lời nhắc luồng bắt đầu bằng init-kb rồi intake (khớp kb_reminder và intake 'Điều kiện')"
hasnt "$F" 'starts with `vibemaestro-sdlc:intake`' "chưa có kb/ → KHÔNG bảo bắt đầu thẳng bằng intake (mâu thuẫn kb_reminder)"
has "$F" 'Call the first skill of the chain BEFORE you read code' "chưa có kb/ → vẫn câu mệnh lệnh (skill đầu chuỗi giờ là init-kb)"
read -r SN SB SP <<<"$(flow_shape "$C")"
[ "$SN" -le 15 ] && [ "$SN" -ge 4 ] && eq "$SB $SP" "1 1" "chưa có kb/ → đoạn $SN dòng (≤ 15), tách khỏi danh mục bằng đúng một dòng trống" || bad "chưa có kb/ → đoạn $SN dòng (cần 4..15) hoặc dòng trống sai ($SB $SP)"
O=$(boi "$APP"); F=$(flow_lines "$(ctx "$O")")
hasnt "$F" 'init-kb' "đối chứng: repo CÓ kb/ → lời nhắc luồng không nhắc init-kb"
has "$F" 'starts with `vibemaestro-sdlc:intake`' "đối chứng: repo CÓ kb/ → bắt đầu thẳng bằng intake"
PL=$(mkpl nokb-no-initkb init-kb) O=$(PL="$PL" boi "$NOKB"); C=$(ctx "$O"); F=$(flow_lines "$C")
hasnt "$C" 'init-kb' "chưa có kb/ nhưng init-kb vắng → không nhắc init-kb ở đâu cả (A7)"
has "$F" 'starts with `vibemaestro-sdlc:intake`' "… và lời nhắc luồng bắt đầu thẳng bằng intake"
PL=$(mkpl nokb-no-intake intake) O=$(PL="$PL" boi "$NOKB"); F=$(flow_lines "$(ctx "$O")")
has "$F" '`vibemaestro-sdlc:init-kb` (this repo has no `kb/` yet), then `vibemaestro-sdlc:brainstorm`' "chưa có kb/, thiếu intake → init-kb vẫn đứng trước chuỗi còn lại"
hasnt "$F" 'bắt đầu bằng' "… và không nói 'bắt đầu bằng' (intake vắng)"
INK=$(cat "$PLUGIN/skills/intake/SKILL.md")
has "$INK" 'Condition: the repo already has `kb/` — if not, do `vibemaestro-sdlc:init-kb` first.' "intake: điều kiện kb/ nguyên văn (flow khớp câu này)"

echo "== P2: kb/ vắng ở cây này nhưng nhánh khung đã đẩy, chưa gộp — SessionStart chỉ tới nhánh, không bảo chạy init-kb lại =="
# ba ca: không có khung (chữ cũ nguyên), nhánh khung chưa gộp (chữ mới, theo language), khung đã gộp (cây có kb/: không nhắc)
unset PL      # the cases above leave PL on a plugin copy without `intake`
SC_EN='which is not merged yet: merge that branch or switch to it'
SC_VI='chưa được gộp: hãy gộp nhánh đó hoặc chuyển sang nhánh đó'
mk_scaffold() {  # mk_scaffold <repo> local|remote [nhánh] — nhánh khung (mặc định tên cũ chore/kb-khoi-tao) mang kb/intent, rồi về lại nhánh cũ
  local r=$1 where=$2 br=${3:-chore/kb-khoi-tao} cur
  cur=$(git_ -C "$r" symbolic-ref --short HEAD)
  git_ -C "$r" checkout -q -b "$br"
  mkdir -p "$r/kb/intent"; : > "$r/kb/intent/.keep"
  git_ -C "$r" add kb; git_ -C "$r" commit -qm scaffold
  if [ "$where" = remote ]; then
    git_ -C "$r" update-ref "refs/remotes/origin/$br" "$br"
    git_ -C "$r" checkout -q "$cur"; git_ -C "$r" branch -q -D "$br"
  else
    git_ -C "$r" checkout -q "$cur"
  fi
}
for lg in en vi none; do
  # ca 1: không có nhánh khung ở đâu cả
  N1="$TMP/sc-none-$lg"; mk_app "$N1" 0
  # ca 2: nhánh khung chưa gộp, local và remote
  N2="$TMP/sc-local-$lg"; mk_app "$N2" 0; mk_scaffold "$N2" local
  N3="$TMP/sc-remote-$lg"; mk_app "$N3" 0; mk_scaffold "$N3" remote
  # ca ngoài ba ca: khung đã gộp ở upstream của nhánh hiện tại, cây này chỉ chưa kéo về — không được nói "chưa gộp"
  N7="$TMP/sc-behind-$lg"; mk_app "$N7" 0; mk_scaffold "$N7" local chore/kb-init
  git_ -C "$N7" remote add origin "$TMP/khong-co-remote.git"; git_ -C "$N7" config branch.main.remote origin; git_ -C "$N7" config branch.main.merge refs/heads/main
  git_ -C "$N7" update-ref refs/remotes/origin/main chore/kb-init
  N5="$TMP/sc-newname-$lg"; mk_app "$N5" 0; mk_scaffold "$N5" local chore/kb-init
  N6="$TMP/sc-newname-remote-$lg"; mk_app "$N6" 0; mk_scaffold "$N6" remote chore/kb-init
  # ca 3: khung đã gộp — cây có kb/ (nhánh khung vẫn còn)
  N4="$TMP/sc-merged-$lg"; mk_app "$N4" 1; mk_scaffold "$N4" local
  for d in "$N1" "$N2" "$N3" "$N4" "$N5" "$N6" "$N7"; do
    [ "$lg" = none ] || { mkdir -p "$d/.vibemaestro"; printf '{"schema":1,"language":"%s"}\n' "$lg" > "$d/.vibemaestro/sdlc.json"; }
  done
  OLD='This repo has no `kb/` yet: use the skill `vibemaestro-sdlc:init-kb`'
  C=$(ctx "$(boi "$N1")"); F=$(flow_lines "$C")
  has "$C" "$OLD" "($lg) không có nhánh khung: chữ cũ nguyên (đối chứng của hai ca dưới)"
  has "$F" 'starts with `vibemaestro-sdlc:init-kb` (this repo has no `kb/` yet)' "($lg) không có nhánh khung: lời nhắc luồng vẫn bắt đầu bằng init-kb"
  hasnt "$C" "$SC_EN" "($lg) không có nhánh khung: không có chữ mới (en)"; hasnt "$C" "$SC_VI" "($lg) không có nhánh khung: không có chữ mới (vi)"
  for w in "$N2:local" "$N3:remote" "$N5:local-new" "$N6:remote-new"; do
    C=$(ctx "$(boi "${w%%:*}")"); F=$(flow_lines "$C")
    case "$lg" in vi|none) want=$SC_VI; other=$SC_EN;; en) want=$SC_EN; other=$SC_VI;; esac
    has "$C" "$want" "($lg, nhánh khung ${w##*:}) chữ mới theo language"
    hasnt "$C" "$other" "($lg, nhánh khung ${w##*:}) không lẫn chữ của ngôn ngữ kia"
    case "${w##*:}" in local) nm='`chore/kb-khoi-tao`';; remote) nm='`origin/chore/kb-khoi-tao`';; local-new) nm='`chore/kb-init`';; *) nm='`origin/chore/kb-init`';; esac
    has "$C" "$nm" "($lg, nhánh khung ${w##*:}) nêu tên nhánh (ref nào mang kb/)"
    hasnt "$C" "$OLD" "($lg, nhánh khung ${w##*:}) không còn câu 'chạy init-kb'"
    hasnt "$F" 'init-kb' "($lg, nhánh khung ${w##*:}) lời nhắc luồng không còn init-kb"
    has "$F" 'starts with `vibemaestro-sdlc:intake`' "($lg, nhánh khung ${w##*:}) lời nhắc luồng bắt đầu bằng intake"
  done
  C=$(ctx "$(boi "$N7")")
  has "$C" "$OLD" "($lg) kéo sau upstream: câu của main còn nguyên (lời khuyên 'kéo về' để sang một issue theo dõi riêng)"
  has "$(git_ -C "$N7" rev-parse --abbrev-ref '@{u}')" "origin/main" "($lg) kéo sau upstream: đối chứng dụng cụ — nhánh hiện tại có upstream"
  hasnt "$C" "$SC_EN" "($lg) kéo sau upstream (khung đã gộp ở origin/main): không nói 'chưa gộp' (en)"; hasnt "$C" "$SC_VI" "($lg) kéo sau upstream: không nói 'chưa gộp' (vi)"
  C=$(ctx "$(boi "$N4")"); F=$(flow_lines "$C")
  has "$C" 'This repo has a `kb/`.' "($lg) khung đã gộp: cây có kb/ → câu kb/ thường (đối chứng)"
  hasnt "$C" "$SC_EN" "($lg) khung đã gộp: không nhắc nhánh khung (en)"; hasnt "$C" "$SC_VI" "($lg) khung đã gộp: không nhắc nhánh khung (vi)"
  hasnt "$F" 'init-kb' "($lg) khung đã gộp: lời nhắc luồng không có init-kb"
done

echo "== R1/BUDGET: bộ luật nhiều — lời nhắc luồng không rơi khi danh mục bị cắt mô tả =="
unset PL
mk_light() { local d=$1 n=$2 i; mk_plugin "$d"; for i in $(seq 1 "$n"); do
  rule "$d" "r-ext-$i.instructions.md" 'plugins/**' - - "MO-TA-DAI-$i $(printf 'chữ-đệm%.0s ' $(seq 1 25))"; done; }
PLL="$TMP/plugin-light"; mk_light "$PLL" 8
O=$(PL="$PLL" boi "$APP"); C=$(ctx "$O")
has "$C" 'MO-TA-DAI-1 ' "đối chứng: ít luật (8) → mô tả luật còn nguyên (chưa phải nhánh cắt)"
PLH="$TMP/plugin-heavy"; mk_light "$PLH" 70
O=$(PL="$PLH" boi "$APP"); C=$(ctx "$O"); F=$(flow_lines "$C")
hasnt "$C" 'MO-TA-DAI-' "70 luật → danh mục bị cắt hết mô tả (vòng for dl đã tới dl=0)"
has "$C" 'r-ext-70.instructions.md' "… mà danh mục vẫn liệt kê luật cuối (không mất hàng)"
has "$C" "$FLOW_HEAD" "ở nhánh dl=0 lời nhắc luồng VẪN còn"
has "$F" 'vibemaestro-sdlc:intake' "… và còn nội dung (nhắc intake)"
read -r SN SB SP <<<"$(flow_shape "$C")"
[ "$SN" -le 15 ] && [ "$SN" -ge 4 ] && eq "$SB $SP" "1 1" "70 luật: đoạn $SN dòng (≤ 15) tách khỏi danh mục 70 dòng bằng đúng một dòng trống" || bad "70 luật: đoạn $SN dòng / dòng trống $SB $SP"
N=$(printf '%s\n' "$F" | grep -c .); [ "$N" -le 15 ] && [ "$N" -ge 4 ] && ok "70 luật: flow_lines cũng đo $N dòng (≤ 15)" || bad "70 luật: flow_lines đo $N dòng (cần 4..15; > 15 nghĩa là đoạn dính liền danh mục)"
P1=$(posof "$C" "$FLOW_HEAD"); P2=$(posof "$C" "The plugin's common rules are in")
[ -n "$P1" ] && [ -n "$P2" ] && [ "$P1" -lt "$P2" ] && ok "70 luật: lời nhắc luồng vẫn đứng trước danh mục ($P1 < $P2)" || bad "70 luật: thứ tự lời nhắc/danh mục sai ($P1, $P2)"
[ "$(nchars "$C")" -le 9000 ] && ok "70 luật: ngữ cảnh $(nchars "$C") ký tự, trong trần 9.000 (nên nhánh dl=0 mới đủ chỗ cho cả lời nhắc luồng)" || bad "70 luật: ngữ cảnh vượt trần: $(nchars "$C")"

unset PL      # các ca trên gán PL ở shell chính; từ đây dùng lại plugin thật
echo "== R1: sandbox — đoạn hành vi đầu tiên giữ nguyên, lời nhắc luồng cũng có =="
O=$(boi "$APP" INTENT_SLUG=2026-10-10-viec SEAT=acme-aws); C=$(ctx "$O")
has "$C" 'Sandbox session — first behaviour, in this order' "đoạn sandbox còn nguyên"
has "$C" 'record the intent VERBATIM' "bước 1 sandbox còn nguyên"
has "$C" "$FLOW_HEAD" "sandbox cũng có lời nhắc luồng (mọi môi trường)"
O=$(boi "$APP" INTENT_SLUG=2026-10-10-viec); C=$(ctx "$O")
hasnt "$C" 'Phiên sandbox' "đối chứng: chỉ một biến → không phải sandbox, hành vi laptop"
has "$C" "$FLOW_HEAD" "… mà lời nhắc luồng vẫn có"

echo "== R1/Y4: phạm vi của A7 ghi ở docstring =="
DOC=$(python3 -c 'import ast,sys; t=ast.parse(open(sys.argv[1]).read()); print([ast.get_docstring(n) for n in ast.walk(t) if isinstance(n,ast.FunctionDef) and n.name=="flow_reminder"][0])' "$PLUGIN/scripts/vsdlc.py")
nonempty "$DOC" "đối chứng dụng cụ: đọc được docstring của flow_reminder"
has "$DOC" 'chỉ skill CỦA PLUGIN' "docstring: A7 chỉ kiểm skill của plugin"
has "$DOC" 'KHÔNG qua kiểm' "docstring: tên skill của plugin bên thứ ba được nhắc không qua kiểm"
for w in 'skill X của plugin quy trình bên thứ ba' 'vẫn dùng'; do has "$DOC" "$w" "docstring nói rõ chỗ nhắc không kiểm: $w"; done
mut_lacks "$DOC" 'KHÔNG qua kiểm' 'qua kiểm' 'KHÔNG qua kiểm' "đối chứng dụng cụ: bỏ chữ KHÔNG khỏi docstring → câu phạm vi vắng"
mut_lacks "$DOC" 'chỉ skill CỦA PLUGIN' 'mọi skill' 'chỉ skill CỦA PLUGIN' "đối chứng dụng cụ: đọc rộng 'mọi skill' → câu phạm vi vắng"

echo "== R2: skill brainstorm =="
BS="$PLUGIN/skills/brainstorm/SKILL.md"
[ -f "$BS" ] && ok "skills/brainstorm/SKILL.md có mặt" || bad "thiếu skills/brainstorm/SKILL.md"
eq "$(sed -n 1p "$BS")" '---' "frontmatter mở ở dòng 1"
eq "$(sed -n 2p "$BS")" 'name: brainstorm' "name khớp tên thư mục"
has "$(sed -n 3p "$BS")" 'description: "Use when:' "description theo giọng 'Use when:'"
eq "$(sed -n 4p "$BS")" '---' "frontmatter đóng ở dòng 4"
D=$(sed -n 3p "$BS")
for w in 'clarify the request' 'make a plan' 'design' 'redo' 'add a feature' 'brainstorming skill of the third-party process plugin'; do has "$D" "$w" "description nêu: $w"; done
NL=$(wc -l < "$BS" | tr -d ' ')
[ "$NL" -le 200 ] && [ "$NL" -ge 40 ] && ok "dài $NL dòng (≤ 200; ≥ 40 chứng tỏ không phải file rỗng)" || bad "dài $NL dòng"
KW='kanban|--skill|profile|skill_view'
K=$(grep -c -E "$KW" "$BS" || true)
eq "$K" 0 "brainstorm không chứa từ khoá kênh kanban ($KW)"
eq "$(printf 'x --skill y\n' | grep -c -E "$KW" || true)" 1 "đối chứng dụng cụ: mẫu bắt được '--skill' trên chuỗi thử"
[ "$(printf 'Dùng kanban và skill_view của kênh ngoài\n' | grep -c -i -E "$KW" || true)" -gt 0 ] && ok "đối chứng dương: mẫu grep bắt được từ khoá trên chuỗi thử (không xanh vì mẫu hỏng)" || bad "mẫu grep không bắt được ca dương thật"
eq "$(grep -c -i -E 'kanban|skill_view' "$BS" || true)" 0 "không chứa kể cả khi bỏ phân biệt hoa/thường"
for w in Spike Bounded Architectural 'ONE question' 'Option 1 / Option 2' 'Brainstorm result'; do has "$(cat "$BS")" "$w" "brainstorm nêu: $w"; done
for f in intake spec; do
  [ "$(grep -cF 'Brainstorm result' "$PLUGIN/skills/$f/SKILL.md" || true)" -ge 1 ] && ok "skill $f nhắc mục 'Kết quả brainstorm'" || bad "skill $f không nhắc 'Kết quả brainstorm'"
done
eq "$(grep -cF 'Brainstorm result' "$PLUGIN/skills/ship/SKILL.md" || true)" 0 "đối chứng: ship KHÔNG nhắc 'Kết quả brainstorm' (grep -cF phân biệt được file có/không)"
has "$(cat "$PLUGIN/skills/intake/SKILL.md")" 'vibemaestro-sdlc:brainstorm' "intake gợi brainstorm khi yêu cầu mơ hồ"
has "$(cat "$PLUGIN/skills/intake/SKILL.md")" 'do not brainstorm again' "intake không brainstorm lại khi gói đã có kết quả"
has "$(cat "$PLUGIN/skills/spec/SKILL.md")" '## Brainstorm result' "spec lấy từ mục '## Kết quả brainstorm' của intent"
has "$(cat "$PLUGIN/skills/spec/SKILL.md")" '`## Context`, `## Goal`, `## Out of scope`' "spec vẫn khuôn bốn mục (không đổi)"
hasnt "$(cat "$BS")" 'kb.py new spec' "brainstorm không tạo file spec"
has "$(cat "$BS")" '**Do not create a separate spec file and do not write into the default output directory of the third-party process plugin (under `docs/`).**' "brainstorm: câu cấm tạo spec riêng / viết vào thư mục đầu ra của plugin bên thứ ba còn nguyên"
BS_NODOCS=$(cat "$BS"); BS_NODOCS=${BS_NODOCS//'(under `docs/`)'/}
hasnt "$BS_NODOCS" 'docs/' "brainstorm không dặn ghi vào thư mục nào dưới docs/ (chỉ câu cấm, nêu 'dưới docs/', được phép)"
hasnt "$(cat "$BS")" 'Create the spec in' "brainstorm không có câu 'Tạo spec ở …'"
# Mẫu/thay thế đặt vào biến rồi mở rộng có nháy kép: bash 3.2 (macOS) không phân tích được `${x//'…`…/…'/…}`.
BSB_FROM='**Do not create a separate spec file and do not write into the default output directory of the third-party process plugin (under `docs/`).**'; BSB_TO='**Create the spec in `docs/specs/`.**'
BSB=${BS_TEXT:-$(cat "$BS")}; BSB=${BSB//"$BSB_FROM"/"$BSB_TO"}
has "$BSB" 'docs/specs' "đối chứng dụng cụ: bản brainstorm bị phá đúng kiểu → có 'docs/specs' (hasnt ở trên bắt được)"
has "$(cat "$BS")" 'with no intent, do `vibemaestro-sdlc:intake` first' "brainstorm: chưa có intent thì làm intake trước"
# Đích ghi (điểm thiết kế cốt lõi): CHÍNH file intent, không phải spec — nguyên văn bước 6 và dòng git add.
BST=$(cat "$BS")
B6='6. **Write the result into the intent file ITSELF** — add a `## Brainstorm result` section at the **end** of `kb/intent/<date>-<slug>.md`,'
has "$BST" "$B6" "brainstorm bước 6: ghi vào CHÍNH file intent, mục '## Kết quả brainstorm' ở cuối (nguyên văn)"
has "$BST" 'git add kb/intent/<date>-<slug>.md' "brainstorm: git add file intent"
hasnt "$BST" 'kb/specs/<date>-<slug>.md' "brainstorm không trỏ tới file spec làm đích ghi"
hasnt "$BST" 'Write the result into the spec file' "brainstorm không có câu 'ghi kết quả vào file spec'"
mut_lacks "$BST" 'Write the result into the intent file ITSELF** — add a `## Brainstorm result` section at the **end** of `kb/intent/<date>-<slug>.md`' 'Write the result into the spec file** — add a `## Brainstorm result` section at the **end** of `kb/specs/<date>-<slug>.md`' "$B6" "đối chứng dụng cụ: đổi đích ghi intent → spec: câu bước 6 nguyên văn vắng"
mut_has "$BST" 'Write the result into the intent file ITSELF** — add a `## Brainstorm result` section at the **end** of `kb/intent/<date>-<slug>.md`' 'Write the result into the spec file** — add a `## Brainstorm result` section at the **end** of `kb/specs/<date>-<slug>.md`' 'kb/specs/<date>-<slug>.md' "đối chứng dụng cụ: cùng phép phá → hasnt 'kb/specs/<ngày>-<slug>.md' bắt được"
has "$(cat "$PLUGIN/skills/intake/SKILL.md")" 'Next steps, in order' "intake: 'Bước tiếp' nói rõ là tuần tự"
# Tiêu đề nói "theo thứ tự" thì THỨ TỰ phải được đo: số thứ tự → skill, đúng brainstorm → spec → plan → ship.
eq "$(seq_of "$INK")" "1.brainstorm,2.spec,3.plan,4.ship" "intake 'Bước tiếp, theo thứ tự': 1 brainstorm → 2 spec → 3 plan → 4 ship"
INKS=$(printf '%s\n' "$INK" | sed -e 's/^2\. `vibemaestro-sdlc:spec`/2. `vibemaestro-sdlc:SHIPX`/' -e 's/^4\. `vibemaestro-sdlc:ship`/4. `vibemaestro-sdlc:spec`/' -e 's/SHIPX/ship/')
[ "$INKS" != "$INK" ] && ne "$(seq_of "$INKS")" "1.brainstorm,2.spec,3.plan,4.ship" "đối chứng dụng cụ: hoán đổi spec/ship trong 'Bước tiếp' → seq_of đổi (assert thứ tự đỏ)" || bad "đối chứng dụng cụ: phép hoán đổi không đổi gì"
INKS=$(printf '%s\n' "$INK" | awk '/^2\. `vibemaestro-sdlc:spec`/{a=$0;next} /^3\. /&&a{print; print a; a=""; next} {print}')
[ "$INKS" != "$INK" ] && ne "$(seq_of "$INKS")" "1.brainstorm,2.spec,3.plan,4.ship" "đối chứng dụng cụ: dời dòng spec xuống sau plan → seq_of đổi" || bad "đối chứng dụng cụ: phép dời dòng không đổi gì"
has "$(cat "$PLUGIN/skills/intake/SKILL.md")" '`vibemaestro-sdlc:plan` when the work must be split' "intake: plan chỉ khi cần chia việc"
has "$(cat "$PLUGIN/skills/plan/SKILL.md")" 'split across PRs' "control: the plan skill also says the work is split (both skills say it)"

echo "== R3: ship bổ sung =="
SH="$(cat "$PLUGIN/skills/ship/SKILL.md")"
for w in 'bash -n' 'py_compile' 'git diff --stat' 're-read the code' 'should pass' 'ticking them yourself' 'run BEFORE the fix' 'Three questions before reporting done' 'open-pr.sh'; do
  has "$SH" "$w" "ship nêu: $w"
done
for w in 'Which command did I run on the **last pushed version**, and what was the exit code?' \
         'Is that output in the PR body, in the `## Run evidence` section?' \
         'Which acceptance criterion has **no** command proving it yet? Name it in the report' \
         'puts `NOT RUN: <concrete reason>`' 'a named exemption, not a back door for a change that has code'; do
  has "$SH" "$w" "ship nêu nguyên văn: ${w:0:50}…"
done
# Lệnh mở PR: đo ở THÂN (frontmatter/mô tả cũng có 'open-pr.sh', nên đo chuỗi trần là xanh giả), và cấm `gh pr create` trần.
SHP='bash "${CLAUDE_PLUGIN_ROOT}/scripts/open-pr.sh" --title'
has "$SH" "$SHP" "ship bước 4: lệnh mở PR là scripts/open-pr.sh của plugin (nguyên văn, trong thân)"
hasnt "$SH" 'gh pr create' "ship không dặn mở PR bằng gh pr create trần"
has "$SH" "open a draft PR with the plugin's scripts/open-pr.sh (do not open a PR with a bare gh command)" "ship: mô tả nêu open-pr.sh và cấm gh trần"
mut_lacks "$SH" 'scripts/open-pr.sh" --title' 'scripts/gh pr create --title' "$SHP" "đối chứng dụng cụ: đổi open-pr.sh → gh pr create ở bước 4 → lệnh nguyên văn vắng"
mut_has "$SH" 'scripts/open-pr.sh" --title' 'scripts/gh pr create --title' 'gh pr create' "đối chứng dụng cụ: cùng phép phá → 'gh pr create' xuất hiện (hasnt bắt được)"
# Bảng "không phải bằng chứng": đo CẢ ô lý do (đo tên không đủ — đảo lý do vẫn giữ tên).
for r in '| `bash -n` / `python -m py_compile` | says only that the syntax is right, not that it runs |' \
         '| `git diff --stat` | says how many lines you changed, not that they run |' \
         '| "re-read the code, the logic is right" | the opinion of the writer about their own work |' \
         '| "tests should pass" / "it will run" | the future tense is not evidence |' \
         '| listing the criteria and ticking them yourself | a tick is a conclusion, not data |' \
         '| the output of a run BEFORE the fix | it must be the run on the last version you pushed |'; do
  has "$SH" "$r" "ship bảng 'không phải bằng chứng', hàng nguyên văn: ${r:0:44}…"
done
hasnt "$SH" 'enough to prove it runs' "ship không nói bash -n đủ để chứng minh chạy được"
mut_lacks "$SH" 'says only that the syntax is right, not that it runs' 'enough to prove it runs' '| `bash -n` / `python -m py_compile` | says only that the syntax is right, not that it runs |' "đối chứng dụng cụ: đảo lý do hàng bash -n (tên còn) → hàng nguyên văn vắng"
mut_has "$SH" 'says only that the syntax is right, not that it runs' 'enough to prove it runs' 'enough to prove it runs' "đối chứng dụng cụ: cùng phép phá → câu cấm xuất hiện (hasnt bắt được)"
SHB=${SH//'3. Which acceptance criterion has **no**'/'3. xx **no**'}
hasnt "$SHB" 'Which acceptance criterion has **no** command proving it yet' "đối chứng dụng cụ: câu 3 bị sửa → literal câu 3 vắng"
eq "$(printf '%s' "$SH" | grep -cE '_kanban_open_pr|kanban' || true)" 0 "ship không còn gọi kanban"
[ "$(printf 'gọi _kanban_open_pr rồi kanban\n' | grep -cE '_kanban_open_pr|kanban' || true)" -ge 1 ] && ok "đối chứng dương: mẫu grep thấy 'kanban' trên chuỗi thử" || bad "mẫu grep không bắt được ca dương"

echo "== R4: manifest =="
# the private repo carries no version; the public export carries its CHANGELOG's released version (none before the first release)
V=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("version", "<absent>"))' "$PLUGIN/.claude-plugin/plugin.json")
TS=$(tree_shape "$SRC_ROOT"); WV=$(want_version "$SRC_ROOT" "$PLUGIN")
eq "$V" "${WV:-<absent>}" "plugin.json on the $TS tree carries the version ${WV:-none} (private: none; export: the CHANGELOG's released version; release.py, tests/test-plugin-version.sh)"
has "$(cat "$PLUGIN/skills/ship/SKILL.md")" 'plugin' "đối chứng: skill ship đọc được"
if command -v claude >/dev/null 2>&1; then
  claude plugin update --help >/dev/null 2>&1 && ok "claude plugin update tồn tại (--help rc 0)" || bad "claude plugin update --help đỏ"
  claude plugin marketplace update --help >/dev/null 2>&1 && ok "claude plugin marketplace update tồn tại (--help rc 0)" || bad "claude plugin marketplace update --help đỏ"
  claude plugin definitely-not-a-command >/dev/null 2>&1; [ $? -ne 0 ] && ok "đối chứng: lệnh con bịa → rc ≠ 0" || bad "claude nhận lệnh con bịa — phép kiểm --help vô nghĩa"
else
  echo "  SKIP *** thiếu 'claude' trên máy này — kiểm lệnh --help KHÔNG chạy ***"
  [ "${PLUGIN_REQUIRE_CLAUDE:-}" = 1 ] && bad "không có 'claude' mà PLUGIN_REQUIRE_CLAUDE=1"
fi
summary
