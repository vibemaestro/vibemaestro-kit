#!/bin/bash
# =============================================================================
# Composite action .github/actions/fetch-plugin — chép repo tại SHA vào một thư mục (cho CI của repo khác)
# =============================================================================
# Chạy: bash tests/test-fetch-plugin.sh
#
# Chạy PHẦN `run` của action trên bản checkout này, mô phỏng GITHUB_ACTION_PATH như runner đặt
# (<_actions>/<owner>/<repo>/<sha>/.github/actions/fetch-plugin: gốc repo = ba cấp trên). Chỉ chứng minh điều đã chạy:
# việc workflow của repo khác thật sự đọc được action sau khi có PR chạy là *chưa kiểm*.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"

ACT="$SRC_ROOT/.github/actions/fetch-plugin/action.yml"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
[ -f "$ACT" ] || { bad "thiếu $ACT"; summary; exit 1; }

echo "== khai báo của action =="
python3 - "$ACT" <<'PY' && ok "action.yml: composite, input dest bắt buộc, một bước bash" || bad "action.yml sai khuôn"
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert d["runs"]["using"] == "composite"
assert d["inputs"]["dest"]["required"] is True
steps = d["runs"]["steps"]
assert len(steps) == 1 and steps[0]["shell"] == "bash" and "${{ inputs.dest }}" in steps[0]["env"]["DEST"]
PY
RUN=$(python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["runs"]["steps"][0]["run"])' "$ACT")
nonempty "$RUN" "trích được phần run của bước"
for pat in 'curl' 'wget' 'git clone' 'git fetch' 'gh ' 'secrets.' 'token' 'npm ' 'pip '; do hasnt "$RUN$(cat "$ACT")" "$pat" "action không dùng '$pat' (không mạng, không secret, không repo khác)"; done
has "$RUN" 'GITHUB_ACTION_PATH' "gốc repo tính từ GITHUB_ACTION_PATH"
has "$RUN" '--exclude=.git' "loại .git"

# repo nguồn giả lập "bản action runner tải về": bản chép checkout này, CÓ .git (để chứng minh .git bị loại)
mk_src() {  # mk_src <dir>
  mkdir -p "$1"; (cd "$SRC_ROOT" && tar --exclude=.git --exclude=__pycache__ -cf - .) | tar -x -C "$1"
  git_ -C "$1" init -q -b main; git_ -C "$1" add -A; git_ -C "$1" commit -qm src
}
SRC="$TMP/_actions/org/repo/0123abc"; mk_src "$SRC"
ACTPATH="$SRC/.github/actions/fetch-plugin"
runact() {  # runact <dest> [cwd] — chạy run của action
  (cd "${2:-$TMP}" && GITHUB_ACTION_PATH="$ACTPATH" DEST="$1" bash -c "$RUN" 2>&1)
}

echo "== chạy: dest tuyệt đối =="
O=$(runact "$TMP/ctx"); rc=$?
eq "$rc" 0 "chạy action: rc 0"
for f in .claude-plugin/marketplace.json plugins/vibemaestro-sdlc/.claude-plugin/plugin.json plugins/vibemaestro-sdlc/scripts/intent_branch.py plugins/vibemaestro-sdlc/rules/workflow-core.instructions.md tests/run-all.sh .github/actions/fetch-plugin/action.yml; do
  [ -f "$TMP/ctx/$f" ] && ok "dest có $f" || bad "dest THIẾU $f"
done
[ ! -e "$TMP/ctx/.git" ] && ok "dest KHÔNG có .git" || bad "dest có .git"
[ -e "$SRC/.git" ] && ok "đối chứng: nguồn mô phỏng CÓ .git (nên 'không .git' ở trên là do action loại)" || bad "nguồn mô phỏng không có .git"
# nội dung = đúng các file được theo dõi của nguồn, từng byte
MISS=0; while IFS= read -r f; do cmp -s "$SRC/$f" "$TMP/ctx/$f" || { MISS=$((MISS+1)); echo "lệch: $f"; }; done < <(git -C "$SRC" ls-files)
eq "$MISS" 0 "mọi file được git theo dõi ở nguồn có trong dest, giống từng byte"
eq "$(cd "$TMP/ctx" && find . -type f | wc -l | tr -d ' ')" "$(git -C "$SRC" ls-files | wc -l | tr -d ' ')" "dest có đúng số file của nguồn (không thừa, không thiếu)"
has "$O" 'Cấp 1:' "action in tiêu đề danh sách cấp 1"
for e in plugins tests scripts .claude-plugin; do has "$O" "$e" "danh sách cấp 1 nêu '$e'"; done   # what the public tree has too (no kb/)
has "$O" "$SRC" "action nói chép từ đâu (gốc repo của action)"

echo "== chạy: dest tương đối + đã có file trong dest =="
mkdir -p "$TMP/ws"; mkdir -p "$TMP/ws/build-ctx"; echo CU > "$TMP/ws/build-ctx/plugins-cu.txt"
O=$(runact "build-ctx" "$TMP/ws"); rc=$?
eq "$rc" 0 "dest tương đối (so với thư mục làm việc): rc 0"
[ -f "$TMP/ws/build-ctx/plugins/vibemaestro-sdlc/.claude-plugin/plugin.json" ] && ok "dest tương đối: có plugin.json" || bad "dest tương đối thiếu plugin.json"
[ -f "$TMP/ws/build-ctx/plugins-cu.txt" ] && ok "file có sẵn trong dest không bị xoá (chỉ ghi chồng file trùng tên)" || bad "action xoá file có sẵn"
echo SUA >> "$TMP/ws/build-ctx/README.md"; runact "build-ctx" "$TMP/ws" >/dev/null
cmp -s "$TMP/ws/build-ctx/README.md" "$SRC/README.md" && ok "file trùng tên bị ghi đè bằng bản của repo" || bad "file trùng tên không được ghi đè"

echo "== đối chứng: lỗi thì nói to =="
O=$(cd "$TMP" && GITHUB_ACTION_PATH="$ACTPATH" DEST="" bash -c "$RUN" 2>&1); rc=$?
eq "$rc" 64 "thiếu dest: rc 64"; has "$O" 'thiếu input dest' "…và nói thiếu input dest"
O=$(cd "$TMP" && GITHUB_ACTION_PATH="$TMP/khong-phai-repo/.github/actions/fetch-plugin" DEST="$TMP/x" bash -c "$RUN" 2>&1); rc=$?
ne "$rc" 0 "GITHUB_ACTION_PATH không nằm trong repo plugin: rc ≠ 0 (rc $rc)"
# đối chứng dụng cụ: sửa nguồn thì dest đổi theo (phép so không mù)
echo "them" >> "$SRC/README.md"; runact "$TMP/ctx2" >/dev/null
cmp -s "$SRC/README.md" "$TMP/ctx2/README.md" && ! cmp -s "$TMP/ctx/README.md" "$TMP/ctx2/README.md" && ok "đối chứng dụng cụ: sửa README ở nguồn → dest mới khác dest cũ, khớp nguồn" || bad "phép so file mù"

summary
