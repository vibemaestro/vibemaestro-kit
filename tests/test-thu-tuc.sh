#!/bin/bash
# =============================================================================
# Plugin vibemaestro-sdlc — thủ tục init-kb / intake / spec / plan / ship ở REPO APP, qua lõi NẰM TRONG plugin
# =============================================================================
# Chạy: bash tests/test-thu-tuc.sh
#
# Không cần `claude`, không cần model, không chạm GitHub: repo app là repo giả có `origin` cục bộ, `gh` là script
# giả đặt đầu PATH (ghi cwd + argv), lõi `intent_branch.py`/`open_pr.py` và hai adapter `.sh` là bản THẬT của plugin.
# Môi trường sạch: không hub, không VIBEMAESTRO_HUB, HOME trống, không cây repo nào khác.
# Mỗi assert có ca đối chứng cạnh nó (dương cạnh âm, cùng trạng thái).
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
export GH_LOG="$TMP/gh.log"; : > "$GH_LOG"
export OPEN_PR_LINK_WAIT_S=0      # the closing-link poll must not sleep in tests
BIN="$TMP/bin"; mk_gh "$BIN"; export PATH="$BIN:$PATH"

# Bản chép plugin dùng cho cả luồng: chạy thủ tục từ BẢN CHÉP (như bản cài trong cache), cây nguồn không bị đụng.
PLG="$TMP/plugin"; cp -r "$PLUGIN" "$PLG"; find "$PLG" -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null
KBPY="$PLG/scripts/kb.py"; IB="$PLG/scripts/intent-branch.sh"; OP="$PLG/scripts/open-pr.sh"
PLG_H0=$(tree_hash_all "$PLG")
MAIN_STATE0=$(git -C "$SRC_ROOT" status --porcelain | sha1sum | cut -d' ' -f1)
# python3 của macOS mặc định đặt pycache_prefix ra ~/Library/Caches nên KHÔNG BAO GIỜ ghi __pycache__ vào cây nguồn — phép đếm
# __pycache__ sẽ mù. Shim `-X pycache_prefix=` (rỗng) trả về hành vi chuẩn (ghi cạnh nguồn) để phép đo có nghĩa.
PYSHIM="$TMP/pyshim"; mkdir -p "$PYSHIM"; REALPY=$(command -v python3)
printf '#!/bin/sh\nexec "%s" -X pycache_prefix= "$@"\n' "$REALPY" > "$PYSHIM/python3"; chmod +x "$PYSHIM/python3"
export PATH="$PYSHIM:$PATH"

for f in "$KBPY" "$IB" "$OP" "$PLG/scripts/intent_branch.py" "$PLG/scripts/open_pr.py"; do
  [ -f "$f" ] && ok "plugin có $(basename "$f") (lõi và adapter nằm TRONG thư mục plugin)" || bad "thiếu $f"
done
[ ! -e "$PLG/scripts/hub-run.py" ] && ok "plugin không còn hub-run.py" || bad "hub-run.py còn trong plugin"

echo "== dụng cụ: harness bố cục kb/ bắt được ca xấu và qua ca tốt =="
GOOD="$TMP/kb-tot"; mkdir -p "$GOOD"/{intent,specs,plans,decisions}; : > "$GOOD/README.md"; : > "$GOOD/current-state.md"; : > "$GOOD/intent/2026-10-08-demo.md"
kb_layout_problems "$GOOD" >/dev/null; eq "$?" 0 "đối chứng dương: kb/ đúng bố cục qua harness"
BADKB="$TMP/kb-xau"; cp -r "$GOOD" "$BADKB"; mkdir -p "$BADKB/lessons"; : > "$BADKB/intent/demo.md"
O=$(kb_layout_problems "$BADKB"); rc=$?
ne "$rc" 0 "đối chứng âm: thư mục lạ + tên sai làm harness ĐỎ (rc $rc)"
has "$O" 'lessons' "…đỏ đúng lý do (thư mục lạ lessons)"; has "$O" 'intent/demo.md' "…và tên file sai khuôn"

echo "== A4: init-kb dựng khung tối thiểu =="
APP="$TMP/app"; mk_app_remote "$APP"
O=$(cd "$APP" && python3 "$KBPY" init --lang vi 2>&1); rc=$?
eq "$rc" 0 "kb.py init trên repo chưa có kb/: rc 0"
for d in intent specs plans decisions; do [ -d "$APP/kb/$d" ] && ok "tạo kb/$d/" || bad "thiếu kb/$d/"; done
for f in README.md current-state.md; do [ -f "$APP/kb/$f" ] && ok "tạo kb/$f" || bad "thiếu kb/$f"; done
[ -z "$(git_ -C "$APP" status --porcelain --ignored kb | grep -F '!!')" ] && ok "khung không bị .gitignore nuốt" || bad "có file khung bị ignore"
git_ -C "$APP" add kb; N=$(git_ -C "$APP" ls-files kb | grep -c '/\.gitkeep$')
eq "$N" 4 "git add kb/ thấy đủ 4 thư mục (mỗi cái một .gitkeep)"
git_ -C "$APP" reset -q
R=$(cat "$APP/kb/README.md" 2>/dev/null)
for pat in 'applyTo' '| Thư mục' 'YYYY-MM-DD' 'Bối cảnh' 'Ngoài phạm vi' 'Tiêu chí chấp nhận' 'Bằng chứng chạy' 'current-state' 'superseded'; do has "$R" "$pat" "README repo app TỰ ĐỦ: có '$pat'"; done
for pat in 'hub' 'gitops' 'kanban' '/home/'; do hasnt "$R" "$pat" "README repo app không tham chiếu thứ ngoài repo: '$pat'"; done
CS=$(cat "$APP/kb/current-state.md")
hasnt "$CS" '2026' "current-state.md sinh ra KHÔNG mang ngày đo (ngày là lịch sử)"
hasnt "$CS" '<ĐIỀN' "current-state.md sinh ra không còn dấu <ĐIỀN (ship kiểm git grep <ĐIỀN)"
has "$CS" 'trạng thái hiện hành' "current-state.md sinh ra nói khuôn: chỉ trạng thái hiện hành"
O=$(cd "$APP" && python3 "$KBPY" check current-state 2>&1); rc=$?
eq "$rc" 0 "current-state sinh ra qua máy kiểm khuôn: rc 0 ($O)"
O=$(kb_layout_problems "$APP/kb"); rc=$?
eq "$rc" 0 "khung sinh ra qua harness bố cục (thư mục, README, current-state, đặt tên) ($O)"

echo "== A4: init-kb idempotent — chạy lần hai không đè gì =="
H1=$(tree_hash_all "$APP/kb")
O=$(cd "$APP" && python3 "$KBPY" init --lang vi --date 2026-12-31 2>&1); rc=$?
eq "$rc" 0 "chạy lần hai: rc 0"
eq "$(tree_hash_all "$APP/kb")" "$H1" "chạy lần hai: băm cả cây kb/ (nội dung + đường dẫn) không đổi"
printf '\nGhi chú của người.\n' >> "$APP/kb/README.md"; printf '\nDòng người thêm.\n' >> "$APP/kb/current-state.md"
H2=$(tree_hash_all "$APP/kb")
(cd "$APP" && python3 "$KBPY" init --lang vi >/dev/null 2>&1)
eq "$(tree_hash_all "$APP/kb")" "$H2" "README/current-state đã bị người sửa: init không đè (băm không đổi)"
printf -- '---\ndescription: "quyết định có sẵn"\napplyTo: "src/**"\n---\n\n# Phương án bị loại\n' > "$APP/kb/decisions/2026-01-01-co-san.md"
rm -rf "$APP/kb/plans"; H3=$(tree_hash_all "$APP/kb/decisions")
(cd "$APP" && python3 "$KBPY" init --lang vi >/dev/null 2>&1)
[ -d "$APP/kb/plans" ] && ok "thiếu kb/plans/: init dựng lại đúng phần thiếu" || bad "init không dựng lại kb/plans/"
eq "$(tree_hash_all "$APP/kb/decisions")" "$H3" "decision có sẵn không bị chạm"
SUB="$TMP/app-sub"; mk_app_remote "$SUB"; (cd "$SUB/src" && python3 "$KBPY" init --lang vi >/dev/null 2>&1)
[ -d "$SUB/kb" ] && [ ! -e "$SUB/src/kb" ] && ok "chạy từ thư mục con: kb/ nằm ở GỐC repo, không ở thư mục con" || bad "kb/ sai chỗ khi chạy từ thư mục con"

echo "== A4: init-kb từ chối chỗ không phải repo app =="
NOGIT="$TMP/khong-git"; mkdir -p "$NOGIT"
O=$(cd "$NOGIT" && python3 "$KBPY" init --lang vi 2>&1); rc=$?
ne "$rc" 0 "ngoài repo git: từ chối (rc $rc)"; [ ! -e "$NOGIT/kb" ] && ok "ngoài repo git: không tạo kb/" || bad "tạo kb/ ngoài repo git"
# a repo whose settings name the two legacy project hook scripts: no refusal since 2.0.0, kb.py works as in any app repo
PH="$TMP/repo-co-hook-du-an"; mk_app_remote "$PH"; mkdir -p "$PH/.claude"
printf '{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"python3 x/instructions-for-path.py"},{"type":"command","command":"python3 x/instructions-for-command.py"}]}]}}\n' > "$PH/.claude/settings.json"
O=$(cd "$PH" && python3 "$KBPY" init --lang vi 2>&1); rc=$?
eq "$rc" 0 "a repo with the legacy hook markers: init runs (rc 0, no refusal since 2.0.0)"
[ -f "$PH/kb/current-state.md" ] && ok "…and writes kb/" || bad "…kb/current-state.md missing after init"
O=$(cd "$PH" && python3 "$KBPY" new intent x 2>&1); rc=$?; eq "$rc" 0 "a repo with the legacy hook markers: 'new' runs (rc 0)"
O=$(cd "$PH" && python3 "$KBPY" check current-state 2>&1); rc=$?; eq "$rc" 0 "a repo with the legacy hook markers: 'check' runs (rc 0)"

echo "== P2: init-kb — <default branch> tìm được ở repo clone VÀ ở repo git init + remote add + push, bằng một lệnh dự phòng =="
IKS="$PLUGIN/skills/init-kb/SKILL.md"
SETHEAD='git remote set-head origin --auto'; SYMREF='git symbolic-ref --short refs/remotes/origin/HEAD'
has "$(grep -F '<default branch>`: run' "$IKS")" "\`$SETHEAD\`" "init-kb: dòng <default branch> nêu lệnh dự phòng"
has "$(grep -F '<default branch>`: run' "$IKS")" "\`$SYMREF\`" "init-kb: …rồi đọc lại origin/HEAD"
BAREX="$TMP/p2-remote.git"; git_ init -q --bare -b main "$BAREX"
P2F="$TMP/p2-fresh"; mkdir -p "$P2F"; git_ -C "$P2F" init -q -b main; : > "$P2F/f"; git_ -C "$P2F" add f; git_ -C "$P2F" commit -qm c1
git_ -C "$P2F" remote add origin "$BAREX"; git_ -C "$P2F" push -q -u origin main
P2C="$TMP/p2-clone"; git_ clone -q "$BAREX" "$P2C"
O=$(git_ -C "$P2F" symbolic-ref --short refs/remotes/origin/HEAD 2>&1); rc=$?
eq "$rc" 128 "đối chứng chữ cũ (chỉ lệnh symbolic-ref) ở repo git init + remote add + push: rc 128"
O=$(git_ -C "$P2C" symbolic-ref --short refs/remotes/origin/HEAD 2>&1); rc=$?
eq "$rc 0:$O" "0 0:origin/main" "đối chứng dương: ở repo clone chữ cũ chạy được (origin/main)"
for r in "$P2C:clone" "$P2F:git init + remote add + push"; do
  d=${r%%:*}; nm=${r#*:}
  git_ -C "$d" remote set-head origin --auto >/dev/null 2>&1; rc1=$?
  O=$(git_ -C "$d" symbolic-ref --short refs/remotes/origin/HEAD 2>&1); rc2=$?
  eq "$rc1/$rc2/$O" "0/0/origin/main" "chữ mới ($nm): set-head --auto rồi symbolic-ref in origin/main"
done

echo "== A4: first run — kb.py base chọn nơi cắt worktree intake (init-kb chưa merge / đã merge / chưa chạy) =="
FR="$TMP/app-first-run"; mk_app_remote "$FR"
O=$(cd "$FR" && python3 "$KBPY" base --default origin/main 2>&1); rc=$?
eq "$rc" 2 "kb.py base: chưa kb/ ở main và chưa có nhánh init-kb: rc 2"; has "$O" 'init-kb' "…chỉ đường init-kb"
git_ -C "$FR" worktree add -q -b chore/kb-init "$FR/.claude/worktrees/kb" origin/main
(cd "$FR/.claude/worktrees/kb" && python3 "$KBPY" init --lang vi >/dev/null && git_ add kb && git_ commit -qm "docs(kb): dựng khung kb/ cho repo")
O=$(cd "$FR" && python3 "$KBPY" base --default origin/main 2>&1); rc=$?
eq "$rc" 2 "kb.py base: nhánh init-kb mới commit local, chưa đẩy: vẫn rc 2 (chỉ dò ref đã đẩy)"
git_ -C "$FR/.claude/worktrees/kb" push -q -u origin chore/kb-init; git_ -C "$FR" fetch -q origin
O=$(cd "$FR" && python3 "$KBPY" base --default origin/main 2>/dev/null); rc=$?
eq "$rc" 0 "kb.py base: nhánh init-kb đã đẩy: rc 0"; eq "$O" "origin/chore/kb-init" "…in đúng ref nhánh init-kb (stdout chỉ có ref)"
has "$(cd "$FR" && python3 "$KBPY" base --default origin/main 2>&1 >/dev/null)" 'carry the scaffold commit' "…stderr nói PR sẽ mang commit khởi tạo"
# tái hiện lỗi và cách sửa cạnh nhau, cùng trạng thái repo
git_ -C "$FR" worktree add -q --detach "$FR/.claude/worktrees/from-main" origin/main
O=$(cd "$FR/.claude/worktrees/from-main" && python3 "$KBPY" new intent x --date 2026-10-08 2>&1); rc=$?
eq "$rc" 2 "tái hiện: worktree cắt từ origin/main (chưa kb/): kb.py new intent rc 2"
BASE=$(cd "$FR" && python3 "$KBPY" base --default origin/main 2>/dev/null)
git_ -C "$FR" worktree add -q --detach "$FR/.claude/worktrees/from-base" "$BASE"
O=$(cd "$FR/.claude/worktrees/from-base" && python3 "$KBPY" new intent x --date 2026-10-08 2>&1); rc=$?
eq "$rc" 0 "sau sửa: worktree cắt từ ref kb.py base in ra: kb.py new intent rc 0 ($O)"
printf -- '---\ndescription: "first run"\n---\n\n# t\n\nx\n' > "$FR/.claude/worktrees/from-base/kb/intent/2026-10-08-x.md"
O=$(cd "$FR/.claude/worktrees/from-base" && bash "$IB" create-intent --slug 2026-10-08-x --base "$BASE" --no-issue 2>&1); rc=$?
eq "$rc" 0 "create-intent --base <ref in ra>: rc 0 ($O)"
has "$(git_ -C "$FR/.claude/worktrees/from-base" log --format=%s origin/main..intent/2026-10-08-x)" 'dựng khung kb/' "branch intent chứa commit khởi tạo kb/ (PR sẽ mang theo)"
# đối chứng dương: kb/ đã merge vào main → in chính nhánh mặc định
git_ -C "$FR/.claude/worktrees/kb" push -q origin chore/kb-init:main; git_ -C "$FR" fetch -q origin
O=$(cd "$FR" && python3 "$KBPY" base --default origin/main 2>&1); rc=$?
eq "$rc" 0 "đối chứng dương: kb/ đã ở main: rc 0"; eq "$O" "origin/main" "…in origin/main, không có lời cảnh báo"
O=$(cd "$FR" && python3 "$KBPY" base 2>&1); rc=$?; eq "$rc" 64 "kb.py base thiếu --default: rc 64"
O=$(cd "$FR" && python3 "$KBPY" base --default origin/khong-co 2>&1); rc=$?; eq "$rc" 64 "kb.py base --default là ref không có: rc 64 (không rơi âm thầm sang nhánh init-kb)"
# the init-kb branch's old name, pushed before the rename: still found; with both pushed, the new name wins
FO="$TMP/app-old-kb-branch"; mk_app_remote "$FO"
git_ -C "$FO" worktree add -q -b chore/kb-khoi-tao "$FO/.claude/worktrees/kb" origin/main
(cd "$FO/.claude/worktrees/kb" && python3 "$KBPY" init --lang vi >/dev/null && git_ add kb && git_ commit -qm "docs(kb): scaffold" && git_ push -q -u origin chore/kb-khoi-tao)
git_ -C "$FO" fetch -q origin
O=$(cd "$FO" && python3 "$KBPY" base --default origin/main 2>/dev/null); rc=$?
eq "$rc" 0 "kb.py base: only the old-name init-kb branch pushed: rc 0"; eq "$O" "origin/chore/kb-khoi-tao" "…prints the old-name ref"
git_ -C "$FO/.claude/worktrees/kb" push -q origin chore/kb-khoi-tao:chore/kb-init; git_ -C "$FO" fetch -q origin
O=$(cd "$FO" && python3 "$KBPY" base --default origin/main 2>/dev/null); eq "$O" "origin/chore/kb-init" "…both pushed: the new name wins"
# probe là kb/intent/, không phải current-state.md: repo thiếu current-state nhưng có kb/intent/ vẫn dùng được nhánh mặc định
PR="$TMP/app-partial-kb"; mk_app_remote "$PR"; mkdir -p "$PR/kb/intent"; : > "$PR/kb/intent/.gitkeep"
git_ -C "$PR" add -A; git_ -C "$PR" commit -qm "partial kb"; git_ -C "$PR" push -q origin main; git_ -C "$PR" fetch -q origin
O=$(cd "$PR" && python3 "$KBPY" base --default origin/main 2>&1); rc=$?
eq "$rc" 0 "kb/ chỉ có kb/intent/ (thiếu current-state.md): rc 0"; eq "$O" "origin/main" "…vẫn in nhánh mặc định (kb.py new intent chạy được ở đó)"
has "$(cat "$PLUGIN/skills/intake/SKILL.md")" 'scripts/kb.py" base --default' "skill intake gọi kb.py base để chọn nơi cắt worktree"
has "$(cat "$PLUGIN/skills/init-kb/SKILL.md")" 'git push -u origin chore/kb-init' "skill init-kb đẩy nhánh khởi tạo (kb.py base chỉ thấy ref đã đẩy)"

echo "== A5: kb.py new — file đúng chỗ, đúng tên, không đè =="
NOKB="$TMP/app-chua-kb"; mk_app_remote "$NOKB"
O=$(cd "$NOKB" && python3 "$KBPY" new intent demo --date 2026-10-08 2>&1); rc=$?
ne "$rc" 0 "repo chưa có kb/: 'new' từ chối thay vì tự dựng (rc $rc)"; has "$O" 'init' "…và chỉ đường init"
[ ! -e "$NOKB/kb" ] && ok "…không tạo gì" || bad "tạo kb/ khi chưa init"
O=$(cd "$APP" && python3 "$KBPY" new intent demo --date 2026-10-08 2>&1); rc=$?
eq "$rc" 0 "new intent: rc 0"
F="$APP/kb/intent/2026-10-08-demo.md"
[ -f "$F" ] && ok "kb/intent/2026-10-08-demo.md đúng chỗ, đúng khuôn <ngày>-<slug>.md" || bad "thiếu $F"
has "$O" '2026-10-08-demo' "in slug đầy đủ để đưa cho intent-branch.sh"
has "$(sed -n 1,3p "$F")" 'description:' "frontmatter có description (create-intent đọc nó làm mô tả issue)"
has "$(cat "$F")" '<ĐIỀN' "khung mang dấu <ĐIỀN: …> để người/model điền trước khi giao"
printf 'ĐÃ SỬA\n' >> "$F"; H=$(sha1sum < "$F")
O=$(cd "$APP" && python3 "$KBPY" new intent demo --date 2026-10-08 2>&1); rc=$?
ne "$rc" 0 "new lần hai cùng tên: từ chối (rc $rc)"; eq "$(sha1sum < "$F")" "$H" "…và không đè file đã có"
(cd "$APP" && python3 "$KBPY" new plan demo --date 2026-10-08 >/dev/null 2>&1); [ -f "$APP/kb/plans/2026-10-08-demo.md" ] && ok "new plan → kb/plans/" || bad "new plan sai chỗ"
(cd "$APP" && python3 "$KBPY" new spec demo --date 2026-10-08 >/dev/null 2>&1); [ -f "$APP/kb/specs/2026-10-08-demo.md" ] && ok "new spec → kb/specs/" || bad "new spec sai chỗ"
eq "$(grep -c '^applyTo:' "$APP/kb/specs/2026-10-08-demo.md" 2>/dev/null)" 0 "spec sinh ra không khai applyTo (kênh giao luật chỉ đọc kb/decisions/)"
has "$(cat "$APP/kb/specs/2026-10-08-demo.md")" 'Intent: kb/intent/2026-10-08-demo.md' "spec sinh ra trỏ về intent cùng <ngày>-<slug> khi file intent đã có"
(cd "$APP" && python3 "$KBPY" new spec chua-co-intent --date 2026-10-08 >/dev/null 2>&1)
has "$(grep -F 'Intent:' "$APP/kb/specs/2026-10-08-chua-co-intent.md")" '<ĐIỀN' "đối chứng: chưa có file intent cùng tên thì để dấu <ĐIỀN>, không bịa đường dẫn"
for s in 'Demo' 'a b' 'a/b' 'dẹp' '-x' 'x-' 'a--b' '' '..'; do
  B=$(find "$APP/kb" -type f | wc -l)
  (cd "$APP" && python3 "$KBPY" new intent "$s" --date 2026-10-08 >/dev/null 2>&1); rc=$?
  [ "$rc" -ne 0 ] && [ "$(find "$APP/kb" -type f | wc -l)" = "$B" ] && ok "slug '$s' bị từ chối, không tạo file" || bad "slug '$s' lọt (rc $rc)"
done
(cd "$APP" && python3 "$KBPY" new intent a1-b2 --date 2026-10-08 >/dev/null 2>&1); [ -f "$APP/kb/intent/2026-10-08-a1-b2.md" ] && ok "đối chứng: slug 'a1-b2' hợp lệ được nhận" || bad "slug hợp lệ bị từ chối"
B=$(find "$APP/kb" -type f | wc -l); (cd "$APP" && python3 "$KBPY" new lesson x --date 2026-10-08 >/dev/null 2>&1); rc=$?
[ "$rc" -ne 0 ] && [ ! -e "$APP/kb/lessons" ] && [ "$(find "$APP/kb" -type f | wc -l)" = "$B" ] && ok "loại lạ 'lesson': từ chối, không đẻ thư mục ngoài khuôn" || bad "loại lạ lọt (rc $rc)"
O=$(kb_layout_problems "$APP/kb"); rc=$?
eq "$rc" 0 "sau khi sinh intent/plan/spec: kb/ vẫn qua harness bố cục ($O)"

echo "== A5: lõi và adapter chạy từ vị trí của chính plugin (không cần gì ngoài thư mục plugin) =="
O=$(cd "$APP" && bash "$IB" 2>&1); rc=$?
eq "$rc" 64 "intent-branch.sh thiếu lệnh con: rc 64 (adapter tìm thấy lõi, nói cách dùng)"
O=$(cd "$APP" && bash "$OP" 2>&1); rc=$?
eq "$rc" 64 "open-pr.sh thiếu --title: rc 64"
mv "$PLG/scripts/intent_branch.py" "$TMP/ib.bak"
O=$(cd "$APP" && bash "$IB" create-intent --slug x 2>&1); rc=$?
eq "$rc" 2 "đối chứng: bỏ lõi khỏi thư mục plugin → intent-branch.sh rc 2"; has "$O" 'thiếu lõi' "…và nói thiếu lõi"
mv "$TMP/ib.bak" "$PLG/scripts/intent_branch.py"
mv "$PLG/scripts/open_pr.py" "$TMP/op.bak"
O=$(cd "$APP" && bash "$OP" --title t --summary a --evidence b 2>&1); rc=$?
eq "$rc" 2 "đối chứng: bỏ lõi open_pr.py khỏi thư mục plugin → open-pr.sh rc 2"; has "$O" 'thiếu lõi' "…và nói thiếu lõi"
mv "$TMP/op.bak" "$PLG/scripts/open_pr.py"

echo "== A5: intake — intent vào kb/ của repo app, qua lõi của plugin, issue ở repo app =="
git_ -C "$APP" add -A; git_ -C "$APP" commit -qm "kb khung" ; git_ -C "$APP" push -q origin main; git_ -C "$APP" fetch -q origin
WT="$APP/.claude/worktrees/demo"
git_ -C "$APP" worktree add -q --detach "$WT" origin/main; [ -d "$WT" ] && ok "worktree intake TRONG repo app (.claude/worktrees/…)" || bad "không dựng được worktree"
(cd "$WT" && python3 "$KBPY" new intent flow --date 2026-10-08 >/dev/null 2>&1)
printf -- '---\ndescription: "dòng mô tả cho issue"\n---\n\n# Việc thử\n\nLời người đặt.\n' > "$WT/kb/intent/2026-10-08-flow.md"
: > "$GH_LOG"
O=$(cd "$WT" && bash "$IB" create-intent --slug 2026-10-08-flow 2>&1); rc=$?
eq "$rc" 0 "create-intent từ cwd = worktree repo app: rc 0 ($O)"
eq "$(git_ -C "$WT" rev-parse --abbrev-ref HEAD)" "intent/2026-10-08-flow" "branch intent/2026-10-08-flow tạo ngay trong worktree"
eq "$(git_ -C "$APP" rev-parse --abbrev-ref HEAD)" "main" "cây chính của repo app KHÔNG bị đổi nhánh"
eq "$(grep -c '^issue: 42$' "$WT/kb/intent/2026-10-08-flow.md")" 1 "số issue từ gh giả được ghi vào frontmatter của intent"
has "$(cat "$GH_LOG")" "CWD=$WT" "gh issue create chạy với cwd = repo app (nơi gh chọn repo theo remote)"
has "$(cat "$GH_LOG")" '[issue] [create]' "…đúng lệnh gh issue create"
hasnt "$(cat "$GH_LOG")" '[--repo]' "…không ép --repo: repo do cwd quyết"
eq "$(find "$PLG" -name __pycache__ | wc -l | tr -d ' ')" 0 "lõi chạy qua adapter không để __pycache__ trong thư mục plugin (PYTHONDONTWRITEBYTECODE)"
# đối chứng dụng cụ: gọi lõi TRỰC TIẾP (không qua adapter, bytecode bật) thì plugin BỊ ghi __pycache__ — phép đếm thấy được
PLC="$TMP/plugin-ctl"; cp -r "$PLG" "$PLC"
printf -- '---\ndescription: "x"\n---\nx\n' > "$WT/kb/intent/2026-10-08-ctl.md"
(cd "$WT" && env -u PYTHONDONTWRITEBYTECODE python3 "$PLC/scripts/intent_branch.py" create-intent --slug 2026-10-08-ctl --no-checkout >/dev/null 2>&1)
[ "$(find "$PLC" -name __pycache__ | wc -l)" -gt 0 ] && ok "đối chứng dương: gọi lõi trực tiếp thì plugin có __pycache__ (phép đo bắt được)" || bad "phép đo __pycache__ không bắt được ca dương"
rm -f "$WT/kb/intent/2026-10-08-ctl.md"; git_ -C "$WT" branch -q -D intent/2026-10-08-ctl 2>/dev/null
git_ -C "$WT" add kb/intent/2026-10-08-flow.md; git_ -C "$WT" commit -qm "docs(kb): intent flow"
git_ -C "$WT" push -q -u origin intent/2026-10-08-flow 2>&1 | tail -1
O=$(cd "$WT" && bash "$IB" create-intent --slug 2026-10-08-flow 2>&1); rc=$?
eq "$rc" 6 "đối chứng: tạo lại cùng intent → rc 6 (branch đã tồn tại, lõi chặn)"
O=$(cd "$WT" && bash "$IB" create-intent --slug 2026-10-08-khong-co-file 2>&1); rc=$?
eq "$rc" 3 "đối chứng: intent chưa có file kb/intent/<slug>.md → rc 3 (cổng của lõi)"

echo "== A5: intake — nhãn \`intent\` thiếu ở repo mới: lõi tự tạo (label present / missing / refused) =="
LBL="$TMP/labels.txt"
new_intent() {  # new_intent <slug> — hồ sơ intent hợp lệ trong $WT, trả về slug đầy đủ qua file
  printf -- '---\ndescription: "label case"\n---\n\n# t\n\nx\n' > "$WT/kb/intent/2026-10-08-$1.md"
}
printf 'bug\nenhancement\n' > "$LBL"; new_intent lbl-missing; : > "$GH_LOG"
O=$(cd "$WT" && GH_LABELS_FILE="$LBL" bash "$IB" create-intent --slug 2026-10-08-lbl-missing --no-checkout 2>&1); rc=$?
eq "$rc" 0 "label missing: create-intent rc 0 ($O)"
eq "$(grep -c '^issue: 42$' "$WT/kb/intent/2026-10-08-lbl-missing.md")" 1 "label missing: issue vẫn được tạo (issue: 42 ghi vào intent)"
has "$(cat "$GH_LOG")" '[label] [create] [intent]' "label missing: lõi gọi gh label create intent"
has "$(cat "$LBL")" 'intent' "label missing: nhãn intent có mặt sau lệnh"
new_intent lbl-present; : > "$GH_LOG"
O=$(cd "$WT" && GH_LABELS_FILE="$LBL" bash "$IB" create-intent --slug 2026-10-08-lbl-present --no-checkout 2>&1); rc=$?
eq "$rc" 0 "label present: create-intent rc 0 ($O)"
eq "$(grep -c '^issue: 42$' "$WT/kb/intent/2026-10-08-lbl-present.md")" 1 "label present: issue được tạo (kết quả label create bị bỏ qua)"
eq "$(grep -c '^intent$' "$LBL")" 1 "label present: nhãn không bị nhân đôi"
new_intent lbl-refused; : > "$GH_LOG"
O=$(cd "$WT" && GH_LABEL_CREATE_FAIL=1 bash "$IB" create-intent --slug 2026-10-08-lbl-refused --no-checkout 2>&1); rc=$?
eq "$rc" 0 "refused: create-intent vẫn rc 0 (best-effort, branch đã tạo)"
eq "$(grep -c '^issue:' "$WT/kb/intent/2026-10-08-lbl-refused.md")" 0 "refused: không có dòng issue: (không bịa số)"
has "$O" 'retry-issue --slug 2026-10-08-lbl-refused' "refused: lời cảnh báo nêu đúng lệnh retry-issue"
has "$O" 'gh issue list --label intent' "refused: cảnh báo bảo kiểm issue đã có chưa trước khi retry (tránh trùng)"
O=$(cd "$WT" && GH_LABEL_CREATE_FAIL=1 bash "$IB" retry-issue --slug 2026-10-08-lbl-refused 2>&1); rc=$?
eq "$rc" 1 "refused: retry-issue rc 1"
printf 'bug\n' > "$LBL"
O=$(cd "$WT" && GH_LABELS_FILE="$LBL" bash "$IB" retry-issue --slug 2026-10-08-lbl-refused 2>&1); rc=$?
eq "$rc" 0 "đối chứng dương: hết bị từ chối, retry-issue rc 0 ($O)"
eq "$(grep -c '^issue: 42$' "$WT/kb/intent/2026-10-08-lbl-refused.md")" 1 "…và issue được ghi"
for s in lbl-missing lbl-present lbl-refused; do git_ -C "$WT" branch -q -D "intent/2026-10-08-$s" 2>/dev/null; rm -f "$WT/kb/intent/2026-10-08-$s.md"; done

echo "== A5: plan + worker-branch + integrate — qua lõi của plugin, base/đích là repo app =="
(cd "$WT" && python3 "$KBPY" new plan flow --date 2026-10-08 >/dev/null 2>&1)
[ -f "$WT/kb/plans/2026-10-08-flow.md" ] && ok "plan ghi vào kb/plans/ của repo app (worktree)" || bad "plan không có"
git_ -C "$WT" add kb/plans/2026-10-08-flow.md; git_ -C "$WT" commit -qm "docs(kb): plan flow"; git_ -C "$WT" push -q origin intent/2026-10-08-flow 2>&1 | tail -1
O=$(cd "$APP" && bash "$IB" worker-branch --intent 2026-10-08-flow --name task/flow-1 2>&1); rc=$?
eq "$rc" 7 "worker-branch từ CÂY CHÍNH repo app không --no-checkout: rc 7 (lõi bảo vệ cây chung)"
O=$(cd "$APP" && bash "$IB" worker-branch --intent 2026-10-08-flow --name task/flow-1 --no-checkout 2>&1); rc=$?
eq "$rc" 0 "worker-branch --no-checkout: rc 0 ($O)"
git_ -C "$APP" worktree add -q "$APP/.claude/worktrees/t1" task/flow-1
TW="$APP/.claude/worktrees/t1"; echo y > "$TW/src/y.ts"; git_ -C "$TW" add src/y.ts; git_ -C "$TW" commit -qm "feat(src): y"
O=$(cd "$TW" && bash "$IB" integrate --intent 2026-10-08-flow --to origin 2>&1); rc=$?
eq "$rc" 0 "integrate --to origin từ worktree task: rc 0 ($O)"
eq "$(git_ -C "$APP.git" branch --list 'intent/2026-10-08-flow' | grep -c .)" 1 "origin của repo app có intent/2026-10-08-flow (đẩy vào repo app)"
O=$(cd "$APP" && bash "$IB" integrate --intent 2026-10-08-flow --to origin 2>&1); rc=$?
eq "$rc" 7 "đối chứng: integrate từ cây chính repo app: rc 7"
# một task = một commit (adapter): hai commit → rc 8
O=$(cd "$APP" && bash "$IB" worker-branch --intent 2026-10-08-flow --name task/flow-2 --no-checkout 2>&1)
git_ -C "$APP" worktree add -q "$APP/.claude/worktrees/t2" task/flow-2
T2="$APP/.claude/worktrees/t2"; echo a > "$T2/src/a.ts"; git_ -C "$T2" add src/a.ts; git_ -C "$T2" commit -qm "feat: a"
echo b > "$T2/src/b.ts"; git_ -C "$T2" add src/b.ts; git_ -C "$T2" commit -qm "feat: b"
O=$(cd "$T2" && bash "$IB" integrate --intent 2026-10-08-flow --to origin 2>&1); rc=$?
eq "$rc" 8 "hai commit so với điểm cắt: integrate rc 8 (một task = một commit)"

echo "== A5: spec — khuôn bốn mục, máy kiểm HÌNH DẠNG, commit lên branch intent, xin duyệt trước khi code =="
order_ok() { python3 -c '
import sys
t, *ks = sys.argv[1:]
pos = [t.find(k) for k in ks]
sys.exit(0 if all(p >= 0 for p in pos) and pos == sorted(pos) else 1)' "$@"; }
chk() { (cd "$WT" && python3 "$KBPY" check spec "$@" 2>&1); }
git_ -C "$WT" fetch -q origin; git_ -C "$WT" merge -q --ff-only origin/intent/2026-10-08-flow 2>&1 | tail -1
SPECF="$WT/kb/specs/2026-10-08-flow.md"
O=$(cd "$WT" && python3 "$KBPY" new spec flow --date 2026-10-08 2>&1); rc=$?
eq "$rc" 0 "new spec flow trong worktree intent: rc 0"
[ -f "$SPECF" ] && ok "kb/specs/2026-10-08-flow.md cạnh intent cùng <ngày>-<slug>" || bad "thiếu $SPECF"
has "$O" 'check spec 2026-10-08-flow' "lệnh in cách kiểm tiếp (kb.py check spec …)"
eq "$(grep -E '^## ' "$SPECF")" "$(printf '## Bối cảnh\n## Mục tiêu\n## Ngoài phạm vi\n## Tiêu chí chấp nhận')" "khung có ĐÚNG bốn mục ## theo thứ tự Bối cảnh, Mục tiêu, Ngoài phạm vi, Tiêu chí chấp nhận"
has "$(cat "$SPECF")" 'Intent: kb/intent/2026-10-08-flow.md' "khung trỏ về intent của branch"
O=$(chk 2026-10-08-flow); rc=$?
eq "$rc" 65 "ca âm: khung chưa điền → check rc 65"; has "$O" '<ĐIỀN' "…và nói lý do là còn <ĐIỀN"
# khuôn nhất quán: README repo app (do init dựng) nêu đủ tên mục của khuôn spec, đúng thứ tự
REAL=$(cat "$APP/kb/README.md")
for sec in 'Bối cảnh' 'Mục tiêu' 'Ngoài phạm vi' 'Tiêu chí chấp nhận' 'Thiết kế' 'Bằng chứng chạy'; do has "$REAL" "$sec" "kb/README.md nêu '$sec' của khuôn spec"; done
order_ok "$REAL" '## Bối cảnh`, `## Mục tiêu`, `## Ngoài phạm vi`,' '`## Tiêu chí chấp nhận`' '`## Thiết kế`' && ok "kb/README.md: bốn mục đúng thứ tự, Thiết kế SAU bốn mục" || bad "kb/README.md: thứ tự khuôn spec sai"
cat > "$TMP/spec-ok.md" <<'EOS'
---
description: "Thêm cờ --dry-run vào script X"
---

# Cờ --dry-run cho script X

Intent: kb/intent/2026-10-08-flow.md

## Bối cảnh

Script X ghi thẳng vào đích, người dùng không xem trước được.

## Mục tiêu

`x.sh --dry-run` in việc sẽ làm mà không ghi gì.

## Ngoài phạm vi

Không đổi định dạng log.

## Tiêu chí chấp nhận

1. `bash x.sh --dry-run` → rc `0`, không file nào đổi (`git status --short` rỗng)
2. `bash test-x.sh` → `0 fail`
3. PR có mục `## Bằng chứng chạy` ghi output thật của các lệnh trên.
EOS
cp "$TMP/spec-ok.md" "$SPECF"
O=$(chk 2026-10-08-flow); rc=$?
eq "$rc" 0 "ca dương: spec điền đủ bốn mục → check rc 0 ($O)"
has "$O" 'no mark shows a person approved it' "…và nói rõ máy KHÔNG biết người đã duyệt (không phải cổng duyệt)"
O=$(chk kb/specs/2026-10-08-flow.md); rc=$?; eq "$rc" 0 "ca dương: truyền đường dẫn thay vì <ngày>-<slug> → rc 0"
{ cat "$TMP/spec-ok.md"; printf '\n## Thiết kế\n\nHướng chọn.\n\n### Phương án bị loại\n\n```\n## Bối cảnh giả trong khối rào\n```\n'; } > "$SPECF"
O=$(chk 2026-10-08-flow); rc=$?; eq "$rc" 0 "ca dương: spec lớn có ## Thiết kế SAU bốn mục (và ### con, và ## giả trong khối rào) → rc 0 ($O)"
neg() {  # <nhãn> <chuỗi báo mong đợi> <lệnh sed trên spec-ok.md>
  sed "$3" "$TMP/spec-ok.md" > "$SPECF"
  O=$(chk 2026-10-08-flow); rc=$?
  eq "$rc" 65 "ca âm [$1]: check rc 65"; has "$O" "$2" "ca âm [$1]: máy nêu đúng lý do"
}
for sec in 'Bối cảnh' 'Mục tiêu' 'Ngoài phạm vi' 'Tiêu chí chấp nhận'; do neg "thiếu mục $sec" "section \`## $sec\` is missing" "/^## $sec\$/d"; done
{ sed '/^## Bối cảnh$/d' "$TMP/spec-ok.md"; printf '\n```\n## Bối cảnh\n```\n'; } > "$SPECF"
O=$(chk 2026-10-08-flow); rc=$?
eq "$rc" 65 "ca âm [tiêu đề Bối cảnh chỉ nằm trong khối rào]: rc 65 (tiêu đề giả không tính)"; has "$O" 'section `## Bối cảnh` is missing' "…và vẫn báo thiếu"
neg "mục lạ" 'unknown section `## Phạm vi`' 's/^## Ngoài phạm vi$/## Phạm vi/'
python3 - "$TMP/spec-ok.md" "$SPECF" <<'PY'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
a, b = "## Mục tiêu", "## Ngoài phạm vi"
i, j = t.index(a), t.index(b)
k = t.index("## Tiêu chí chấp nhận")
open(sys.argv[2], "w", encoding="utf-8").write(t[:i] + t[j:k] + t[i:j] + t[k:])
PY
O=$(chk 2026-10-08-flow); rc=$?; eq "$rc" 65 "ca âm [Ngoài phạm vi đứng trước Mục tiêu]: check rc 65"; has "$O" 'sections out of order' "…nêu thứ tự sai"
python3 - "$TMP/spec-ok.md" "$SPECF" <<'PY'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
k = t.index("## Tiêu chí chấp nhận")
open(sys.argv[2], "w", encoding="utf-8").write(t[:k] + "## Thiết kế\n\nx\n\n" + t[k:])
PY
O=$(chk 2026-10-08-flow); rc=$?; eq "$rc" 65 "ca âm [Thiết kế đứng TRƯỚC Tiêu chí chấp nhận]: check rc 65"; has "$O" 'sections out of order' "…nêu thứ tự sai"
python3 - "$TMP/spec-ok.md" "$SPECF" <<'PY'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
open(sys.argv[2], "w", encoding="utf-8").write(t.replace("Không đổi định dạng log.\n", ""))
PY
O=$(chk 2026-10-08-flow); rc=$?; eq "$rc" 65 "ca âm [mục Ngoài phạm vi rỗng]: check rc 65"; has "$O" 'section `## Ngoài phạm vi` is empty' "…nêu mục rỗng"
neg "tiêu chí không có lệnh" 'criterion 2 has no command' 's/^2\. .*/2. chạy test cho xanh/'
neg "tiêu chí cuối không phải Bằng chứng chạy" 'the last criterion must be' 's/^3\. .*/3. xong thì báo người dùng `ok`/'
neg "còn <ĐIỀN" '`<ĐIỀN: …>` blank(s) still to fill' 's/^Script X ghi.*/<ĐIỀN: bối cảnh>/'
printf -- '---\ndescription: "x"\n---\n\n# Rỗng\n' > "$SPECF"
O=$(chk 2026-10-08-flow); rc=$?; eq "$rc" 65 "ca âm [không có mục nào]: check rc 65"
for sec in 'Bối cảnh' 'Mục tiêu' 'Ngoài phạm vi' 'Tiêu chí chấp nhận'; do has "$O" "section \`## $sec\` is missing" "…báo thiếu '$sec'"; done
O=$(chk 2026-10-08-khong-co); rc=$?; eq "$rc" 66 "spec không tồn tại: rc 66"
O=$(chk lesson x); rc=$?; eq "$rc" 64 "loại lạ 'lesson': rc 64"
cp "$TMP/spec-ok.md" "$SPECF"
git_ -C "$WT" add kb/specs/2026-10-08-flow.md; git_ -C "$WT" commit -qm "docs(kb): spec flow"
O=$(git_ -C "$WT" push -q origin intent/2026-10-08-flow 2>&1); rc=$?; eq "$rc" 0 "push spec lên intent/2026-10-08-flow: rc 0 ($O)"
has "$(git_ -C "$APP.git" show intent/2026-10-08-flow:kb/specs/2026-10-08-flow.md 2>&1)" '## Tiêu chí chấp nhận' "spec đã commit và đẩy lên intent/2026-10-08-flow của repo app (xin duyệt SAU khi đẩy)"
git_ -C "$WT" fetch -q origin
SP=$(cat "$PLG/skills/spec/SKILL.md" 2>/dev/null)
has "$SP" 'kb.py" new spec' "spec: kb.py new spec"; has "$SP" 'kb.py" check spec' "spec: kb.py check spec"
has "$SP" 'session-ask' "spec: xin duyệt bằng session-ask"; hasnt "$SP" 'command -v session-ask' "spec: không nhận sandbox bằng session-ask trong PATH"
has "$SP" 'end the turn' "spec: sau session-ask thì kết thúc lượt chờ tin"
has "$SP" 'No code edit without an approval' "spec: chưa duyệt thì không sửa code"
has "$SP" '**not** a gate' "spec: nói rõ check không phải cổng (không chặn sửa code)"
has "$SP" 'Run evidence' "spec: tiêu chí cuối là mục Bằng chứng chạy"
has "$SP" 'git push origin intent/' "spec: đẩy lên branch intent trước khi xin duyệt"
has "$SP" '`kb/README.md`' "spec: khuôn nằm ở kb/README.md của CHÍNH repo (không phải repo khác)"
order_ok "$SP" 'new spec' 'check spec' 'git push origin intent/' 'session-ask "Spec' && ok "spec: thứ tự tạo → kiểm → đẩy → xin duyệt" || bad "spec: thứ tự các bước sai"
has "$(cat "$PLG/skills/intake/SKILL.md")" 'vibemaestro-sdlc:spec' "intake: bước tiếp là skill spec (trước khi sửa code)"
# F3: spec and brainstorm decide "sandbox" by the sandbox-env contract (INTENT_SLUG and SEAT both set, not empty), never by
# a `session-ask` on PATH. The check line is taken FROM each skill and run under each env, with a fake session-ask on PATH.
ASKD="$TMP/askdir"; mkdir -p "$ASKD"; printf '#!/bin/sh\nexit 0\n' > "$ASKD/session-ask"; chmod +x "$ASKD/session-ask"
[ -n "$(PATH="$ASKD:$PATH" command -v session-ask)" ] && ok "F3 dụng cụ: session-ask giả có trong PATH" || bad "F3 dụng cụ: session-ask giả không thấy"
BS=$(cat "$PLG/skills/brainstorm/SKILL.md")
sbx() { env -u INTENT_SLUG -u SEAT "$@" PATH="$ASKD:$PATH" bash -c "$CHK" && echo sandbox || echo solo; }
for nm in spec brainstorm; do
  if [ "$nm" = spec ]; then txt=$SP; call='session-ask "Spec'; else txt=$BS; call='session-ask "<question>"'; fi
  CHK=$(printf '%s\n' "$txt" | grep -F '[ -n "${INTENT_SLUG:-}"' | head -1 | sed -n 's/.*`\(\[ -n[^`]*\)`.*/\1/p')
  has "$CHK" '${SEAT:-}' "F3 $nm: the check line was taken from the skill ($CHK)"
  hasnt "$txt" 'command -v session-ask' "F3 $nm: no sandbox detection by session-ask in PATH"
  order_ok "$txt" '[ -n "${INTENT_SLUG:-}"' "$call" && ok "F3 $nm: the contract check comes before the session-ask call" || bad "F3 $nm: the contract check does not precede the session-ask call"
  order_ok "$txt" '[ -n "${INTENT_SLUG:-}"' 'command is installed' "$call" && ok "F3 $nm: the call needs the contract and the installed command" || bad "F3 $nm: the call is not tied to the installed command"
  has "$txt" 'without the' "F3 $nm: a sandbox without the session-ask command asks in the session"
  eq "$(sbx)" solo "F3 $nm: neither variable, session-ask on PATH → solo (ask the person in the session)"
  eq "$(sbx INTENT_SLUG=x)" solo "F3 $nm: only INTENT_SLUG → solo"
  eq "$(sbx SEAT=y)" solo "F3 $nm: only SEAT → solo"
  eq "$(sbx INTENT_SLUG= SEAT=y)" solo "F3 $nm: INTENT_SLUG empty → solo"
  eq "$(sbx INTENT_SLUG=x SEAT=)" solo "F3 $nm: SEAT empty → solo"
  eq "$(sbx INTENT_SLUG=x SEAT=y)" sandbox "F3 $nm: control — both set → sandbox (session-ask)"
done

echo "== A5: ship — open-pr.sh từ cwd = repo app, thân PR có Closes #issue =="
git_ -C "$WT" fetch -q origin; git_ -C "$WT" merge -q --ff-only origin/intent/2026-10-08-flow 2>&1 | tail -1
printf 'Sửa gì và vì sao.\n' > "$TMP/sum.md"; printf '$ echo ok\nok\n' > "$TMP/ev.txt"
: > "$GH_LOG"; export GH_STDIN="$TMP/pr-body.txt"; : > "$GH_STDIN"
O=$(cd "$WT" && bash "$OP" --title "feat(demo): việc thử" --summary "$TMP/sum.md" --evidence "$TMP/ev.txt" --base main --closes 42 --draft 2>&1); rc=$?
eq "$rc" 0 "open-pr từ worktree repo app: rc 0 ($O)"
has "$(cat "$GH_LOG")" "CWD=$WT" "gh chạy với cwd = repo app"
has "$(cat "$GH_LOG")" '[repo] [view]' "slug repo lấy từ gh theo cwd (repo app)"
has "$(cat "$GH_LOG")" '[--repo] [acme/app-demo]' "gh pr create nhắm repo app"
has "$(cat "$GH_LOG")" '[--head] [intent/2026-10-08-flow]' "head = nhánh intent của repo app"
has "$(cat "$GH_LOG")" '[--base] [main]' "base = nhánh mặc định của repo app"
has "$(cat "$GH_LOG")" '[--draft]' "PR của intent mở ở draft"
has "$(cat "$GH_STDIN")" 'Closes #42' "thân PR có 'Closes #42' (--closes truyền tường minh)"
has "$(cat "$GH_STDIN")" 'Bằng chứng chạy' "thân PR theo khuôn của lõi (có mục Bằng chứng chạy)"
O=$(cd "$APP" && bash "$OP" --title "feat(demo): việc thử" --summary "$TMP/sum.md" --evidence "$TMP/ev.txt" --base main --dry-run 2>&1); rc=$?
eq "$rc" 5 "đối chứng: open-pr từ CÂY CHÍNH repo app: rc 5 (lõi từ chối)"
: > "$TMP/ev-rong.txt"
O=$(cd "$WT" && bash "$OP" --title "feat(demo): việc thử" --summary "$TMP/sum.md" --evidence "$TMP/ev-rong.txt" --base main --dry-run 2>&1); rc=$?
eq "$rc" 3 "đối chứng: thiếu bằng chứng chạy: rc 3 (phép từ chối của lõi vẫn áp ở repo app)"

echo "== A5: ship — closing link: lõi kiểm GitHub đã liên kết issue chưa, và nói to khi chưa xác nhận =="
ship_pr() {  # ship_pr [--closes N] — mở PR qua adapter từ $WT; stderr+stdout vào $O, rc vào $rc
  O=$(cd "$WT" && bash "$OP" --title "feat(demo): việc thử" --summary "$TMP/sum.md" --evidence "$TMP/ev.txt" --base main --draft "$@" 2>&1); rc=$?
}
rm -f "$GH_LOG.cnt"; : > "$GH_LOG"
GH_CLOSING_JSON='[42]' ship_pr --closes 42
eq "$rc" 0 "closing link: GitHub trả [42]: rc 0"; has "$O" 'closing link confirmed' "…nói đã xác nhận"; hasnt "$O" 'WARNING' "…không cảnh báo"
rm -f "$GH_LOG.cnt"
GH_CLOSING_JSON='[42]' GH_CLOSING_AFTER=3 ship_pr --closes 42
eq "$rc" 0 "closing link: điền chậm (3 lần đầu [], rồi [42]): rc 0"; has "$O" 'closing link confirmed' "…poll đợi tới khi có (không cảnh báo sớm)"
eq "$(cat "$GH_LOG.cnt")" 4 "…đúng 4 lần đọc (dừng ngay khi xác nhận)"
rm -f "$GH_LOG.cnt"
GH_CLOSING_JSON='[]' ship_pr --closes 42
eq "$rc" 0 "closing link: GitHub luôn trả []: vẫn rc 0 (PR đã tồn tại; không đổi exit code)"
has "$O" 'WARNING: could not confirm that PR #7 closes #42' "…cảnh báo nêu PR và issue"; has "$O" 'no closing issue' "…nêu GitHub báo gì"
eq "$(cat "$GH_LOG.cnt")" 10 "…đọc đủ 10 lần rồi mới cảnh báo"
has "$O" 'after 10 reads' "…và nói đã đọc 10 lần"
rm -f "$GH_LOG.cnt"
GH_CLOSING_JSON='[9]' ship_pr --closes 42
has "$O" 'WARNING' "closing link: GitHub liên kết issue KHÁC ([9]): cảnh báo"; has "$O" 'GitHub lists #9' "…nêu issue đang được liên kết"
rm -f "$GH_LOG.cnt"
GH_PRVIEW_FAIL=1 ship_pr --closes 42
eq "$rc" 0 "closing link: gh pr view lỗi: rc 0"; has "$O" 'could not read closingIssuesReferences' "…cảnh báo nói không đọc được"
rm -f "$GH_LOG.cnt"
CLICOLOR_FORCE=1 GH_CLOSING_JSON='[42]' ship_pr --closes 42
has "$O" 'closing link confirmed' "closing link: gh ép màu (CLICOLOR_FORCE): lõi xin output thuần nên vẫn xác nhận được"
rm -f "$GH_LOG.cnt"; T0=$(date +%s)
GH_PRVIEW_HANG=1 OPEN_PR_LINK_DEADLINE_S=2 ship_pr --closes 42
T1=$(date +%s); eq "$rc" 0 "closing link: gh treo: rc 0"; has "$O" 'could not confirm' "…cảnh báo sau hạn tổng, không treo theo gh"
[ $((T1-T0)) -lt 15 ] && ok "…tổng thời gian bị chặn bởi hạn (<15 s, thực tế $((T1-T0)) s)" || bad "poll vượt hạn tổng ($((T1-T0)) s)"
git_ -C "$WT" checkout -q --detach; rm -f "$GH_LOG.cnt"; : > "$GH_LOG"
GH_CLOSING_JSON='[42]' ship_pr --head intent/2026-10-08-flow
eq "$rc" 0 "đối chứng: không --closes và không đứng trên intent/*: rc 0"
hasnt "$(cat "$GH_LOG")" '[pr] [view]' "…và không đọc closingIssuesReferences (không có gì để kiểm)"
git_ -C "$WT" checkout -q intent/2026-10-08-flow

echo "== A5: --closes tự đọc 'issue: N' từ intent của repo ĐANG ĐỨNG (không từ nơi chứa plugin) =="
body_of() { python3 -c 'import json,sys; print(json.loads(sys.stdin.read().strip().splitlines()[-1])["body"])'; }
O=$(cd "$WT" && bash "$OP" --title "feat(demo): việc thử" --summary "$TMP/sum.md" --evidence "$TMP/ev.txt" --base main --dry-run 2>/dev/null | body_of)
has "$O" 'Closes #42' "đứng trên intent/* của repo app, không --closes: thân PR có 'Closes #42' (đọc từ kb/intent của repo app)"
O=$(cd "$WT" && bash "$OP" --title "feat(demo): việc thử" --summary "$TMP/sum.md" --evidence "$TMP/ev.txt" --base main --closes 9 --dry-run 2>/dev/null | body_of)
has "$O" 'Closes #9' "đối chứng dương: --closes tường minh thắng ('Closes #9')"
hasnt "$O" 'Closes #42' "…và không còn số tự đọc"
git_ -C "$WT" checkout -q --detach
O=$(cd "$WT" && bash "$OP" --title "feat(demo): việc thử" --summary "$TMP/sum.md" --evidence "$TMP/ev.txt" --base main --head intent/2026-10-08-flow --dry-run 2>/dev/null | body_of)
hasnt "$O" 'Closes #' "đối chứng âm: không đứng trên nhánh intent/* thì không tự đọc (không 'Closes #')"
git_ -C "$WT" checkout -q intent/2026-10-08-flow

echo "== A5: luật applyWhen của plugin TỚI TAY khi skill chạy lõi qua adapter =="
HOOKS="$PLUGIN/hooks/hooks.json"
prebash() { printf '%s' "$(p_bash "$(sid)" "$1")" | CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PROJECT_DIR="$APP" bash -c "$(hook_cmds "$HOOKS" PreToolUse Bash | sed -n 1p)" 2>/dev/null; }
O=$(prebash "bash \\\"\${CLAUDE_PLUGIN_ROOT}/scripts/intent-branch.sh\\\" worker-branch --intent 2026-10-08-flow --name t --no-checkout")
has "$(ctx "$O")" 'git-process.instructions.md' "intent-branch.sh worker-branch → hook nhắc luật git-process (applyWhen khớp chữ trên dòng lệnh)"
O=$(prebash "bash $IB create-intent --slug 2026-10-08-flow")
hasnt "$(ctx "$O")" 'git-process.instructions.md' "đối chứng: create-intent không khớp luật git-process (applyWhen chỉ worker-branch / worktree add)"
O=$(prebash "bash $OP --title x --summary a --evidence b --draft")
has "$(ctx "$O")" 'pr-no-leaks.instructions.md' "open-pr.sh → hook nhắc luật pr-no-leaks"

echo "== G2: không thủ tục nào ghi vào thư mục plugin hay cây nguồn =="
eq "$(tree_hash_all "$PLG")" "$PLG_H0" "băm bản chép plugin (kể cả __pycache__) trước/sau cả luồng: không đổi"
eq "$(git -C "$SRC_ROOT" status --porcelain | sha1sum | cut -d' ' -f1)" "$MAIN_STATE0" "git status của cây repo plugin đang kiểm: không đổi"
touch "$PLG/scripts/__tam"; [ "$(tree_hash_all "$PLG")" != "$PLG_H0" ] && ok "đối chứng dụng cụ: thêm một file vào plugin thì băm đổi" || bad "băm plugin không nhạy"
rm -f "$PLG/scripts/__tam"

echo "== skill: sáu thủ tục có mặt, gọi lõi của plugin, không viết lại lõi, không tham chiếu thứ ngoài plugin =="
for s in init-kb intake spec plan ship; do
  F="$PLUGIN/skills/$s/SKILL.md"
  [ -f "$F" ] || { bad "thiếu skills/$s/SKILL.md"; continue; }
  T=$(cat "$F")
  eq "$(sed -n 2p "$F")" "name: $s" "skills/$s: frontmatter name khớp tên thư mục"
  has "$(sed -n 1,6p "$F")" 'description: "Use when:' "skills/$s: description kiểu 'Use when:'"
  hasnt "$T" '/home/' "skills/$s: không chứa đường dẫn máy cá nhân"
  for pat in 'gh pr create' 'gh issue create' 'git merge' 'git checkout -b' 'git push --force' 'git push -f' 'hub-run' 'VIBEMAESTRO_HUB' 'sandbox-session' 'gitops' 'kanban'; do hasnt "$T" "$pat" "skills/$s: không chứa '$pat'"; done
done
has "$(cat "$PLUGIN/skills/init-kb/SKILL.md")" 'kb.py' "init-kb gọi kb.py init"
I=$(cat "$PLUGIN/skills/intake/SKILL.md")
has "$I" 'scripts/intent-branch.sh' "intake gọi lõi của plugin: scripts/intent-branch.sh"; has "$I" 'intent-branch.sh" create-intent' "intake: intent-branch.sh create-intent"
has "$I" 'kb.py" new intent' "intake: kb.py new intent"
has "$I" '.claude/worktrees' "intake: làm trong worktree TRONG clone"
P=$(cat "$PLUGIN/skills/plan/SKILL.md")
has "$P" 'kb.py" new plan' "plan: kb.py new plan"; has "$P" 'worker-branch' "plan: worker-branch của lõi"; has "$P" 'integrate' "plan: integrate của lõi"
S=$(cat "$PLUGIN/skills/ship/SKILL.md")
has "$S" 'scripts/open-pr.sh' "ship: open-pr.sh của plugin"; has "$S" '--closes' "ship: truyền --closes tường minh"
has "$S" '--draft' "ship: PR của intent mở --draft"; has "$S" 'current-state.md' "ship: cập nhật kb/current-state.md của repo"
has "$S" '<FILL' "ship: kiểm không còn dấu <ĐIỀN: trước khi mở PR"
has "$S" 'kb.py" check current-state' "ship: gọi máy kiểm current-state trước khi mở PR"
has "$S" 'overwrite' "ship: dạy viết đè current-state (không nối thêm)"
has "$S" '**not** a hard gate' "ship: máy kiểm current-state không là cổng chặn cứng khi repo chưa có khuôn"
order_ok "$S" 'check current-state' '<FILL' 'open-pr.sh" --title' && ok "ship: thứ tự kiểm current-state → kiểm <ĐIỀN → mở PR" || bad "ship: thứ tự bước sai"
K=$(cat "$PLUGIN/skills/init-kb/SKILL.md")
for w in 'present state' 'Overwrite' 'No history' 'kb/specs/' 'kb/decisions/' 'check current-state' 'size cap'; do has "$K" "$w" "init-kb dạy khuôn current-state: '$w'"; done
# mỗi lời gọi lõi trong skill chỉ dùng lệnh con mà lõi có thật
CMDS=$(cat "$PLUGIN"/skills/*/SKILL.md 2>/dev/null | grep -oE 'intent-branch\.sh"? [a-z-]+' | awk '{print $2}' | sort -u)
nonempty "$CMDS" "skill có gọi intent-branch (dụng cụ trích lệnh con thấy được)"
HELP=$(python3 "$PLG/scripts/intent_branch.py" --help 2>&1)
for c in $CMDS; do has "$HELP" "$c" "lệnh con '$c' trong skill có thật ở lõi"; done
case "$HELP" in *nhap-bay*) bad "dụng cụ: help của lõi chứa 'nhap-bay'";; *) ok "đối chứng: lệnh con bịa 'nhap-bay' không có trong help của lõi";; esac
# mọi ${CLAUDE_PLUGIN_ROOT}/scripts/X trong skill trỏ tới file có thật
for ref in $(grep -ohE '\$\{CLAUDE_PLUGIN_ROOT\}/scripts/[A-Za-z0-9_.-]+' "$PLUGIN"/skills/*/SKILL.md | sed 's|^\${CLAUDE_PLUGIN_ROOT}/||' | sort -u); do
  [ -f "$PLUGIN/$ref" ] && ok "skill trỏ tới $ref: file có thật trong plugin" || bad "skill trỏ tới $ref — KHÔNG có file"
done
# lõi là bản của plugin
N=$(grep -rlE 'def create_tracking_issue|def build_body' "$PLUGIN/scripts" --include='*.py' | wc -l | tr -d ' '); eq "$N" 2 "lõi (create_tracking_issue, build_body) nằm trong plugin/scripts: 2 file"

echo; summary
