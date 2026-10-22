#!/bin/bash
# =============================================================================
# Máy kiểm khuôn kb/current-state.md: chỉ trạng thái hiện hành, trong trần kích thước
# =============================================================================
# Chạy: bash tests/test-current-state.sh
#
# Máy: `kb.py check current-state [đường-dẫn]` (logic ở scripts/current_state.py). Suite đo:
#   1. ca XANH: current-state tốt (viết đè, trạng thái hiện hành) và current-state do `kb.py init` dựng;
#   2. ca ĐỎ cho TỪNG dấu hiệu lịch sử (ngày, số PR/issue, commit SHA, từ chỉ quá khứ, mục lịch sử) — mỗi ca chỉ khác ca
#      xanh đúng MỘT dòng, nên đỏ là do dòng đó; máy phải nêu đúng nhãn;
#   3. ca KHÔNG-nhầm: câu trạng thái hợp lệ có chữ giống dấu hiệu (phân số 3/4 và 11/11 suite, "đang chuyển từ", "bootstrap ban
#      đầu", chữ PR không kèm số, `today()`, "luật #1") phải vẫn XANH — dấu hiệu quá rộng làm người dùng tắt máy. Mỗi ca nhầm
#      đã đo có ca ĐỎ đối chứng ngay cạnh (ngày thật 10/10, 11/10…) để bớt nhầm không làm máy mù;
#   4. trần: đúng trần thì xanh, hơn một đơn vị thì đỏ (dòng, byte, ký tự mỗi dòng);
#   5. một current-state kiểu "nhật ký" (nối thêm theo ngày, số PR, chi tiết cách làm) → ĐỎ nhiều chỗ, kể cả vượt trần.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
# shellcheck source=fixtures/flow.sh
. "$HERE/fixtures/flow.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
KBPY="$PLUGIN/scripts/kb.py"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
R="$TMP/repo"; mk_app "$R"; rm -rf "$R/kb"; mkdir -p "$R/kb"
CS="$R/kb/current-state.md"
chk() { (cd "$R" && python3 "$KBPY" check current-state "$@" 2>&1); }

GOOD='# Hiện trạng — ví dụ

Chỉ ghi trạng thái hiện hành. Chi tiết ở `kb/specs/` và `kb/decisions/`.

## Thành phần đang chạy

| Thành phần | Trạng thái |
|---|---|
| API | chạy trên cụm `prod`, 3 bản sao, cổng 8080 |
| Worker | 2 bản sao, đọc hàng đợi `jobs` |
| Cơ sở dữ liệu | PostgreSQL 16, một primary và một replica |

## Quy ước

- Mọi thay đổi đi qua PR, nhánh `intent/*`, một PR draft cho mỗi intent.
- Cấu hình bí mật nằm ở kho bí mật của tổ chức, không nằm trong repo.
- Chọn Redis làm hàng đợi: lý do và phương án bị loại ở `kb/decisions/2026-01-05-hang-doi.md`.

## Chưa có / đang tắt

- Chưa có môi trường staging.
- Backup tự động đang tắt.
'
printf '%s' "$GOOD" > "$CS"

echo "== 1. ca xanh =="
O=$(chk); rc=$?; eq "$rc" 0 "current-state tốt: rc 0 ($O)"
has "$O" 'passes the current-state shape' "…và máy nói đạt, kèm số dòng/byte"
INIT="$TMP/init-repo"; mk_app_remote "$INIT"; (cd "$INIT" && python3 "$KBPY" init >/dev/null 2>&1)
O=$(cd "$INIT" && python3 "$KBPY" check current-state 2>&1); eq "$?" 0 "current-state do kb.py init dựng: rc 0 ($O)"
O=$(chk "$CS"); eq "$?" 0 "truyền đường dẫn tường minh: rc 0"

echo "== 2. ca đỏ cho từng dấu hiệu: ca xanh + MỘT dòng =="
red() {  # red <nhãn> <dòng thêm> <nhãn máy mong đợi>
  { printf '%s' "$GOOD"; printf '%s\n' "$2"; } > "$CS"
  O=$(capped chk); rc=$?   # capped: memory and time caps (fixtures/capped.sh)
  cap_red "$rc" "[$1]" && return
  eq "$rc" 65 "[$1] rc 65"; has "$O" "$3" "[$1] máy nêu nhãn '$3'"
  has "$O" 'dòng ' "[$1] máy nêu số dòng vi phạm"
}
red "ngày ISO" '- Triển khai xong ngày 2026-10-11.' 'ngày (YYYY-MM-DD)'
red "ngày dd/mm" '- Đo 27/09: 12 bản sao.' 'ngày (dd/mm)'
red "ngày dd/mm/yyyy" '- Cập nhật 7/9/2026 cho worker.' 'ngày (dd/mm)'
red "số PR dạng #" '- Worker thêm ở #123.' 'số PR/issue'
red "số PR dạng PR N" '- Sửa ở PR 45.' 'số PR/issue'
red "số PR dạng URL" '- Xem https://github.com/x/y/pull/77 để biết thêm.' 'số PR/issue'
red "commit SHA" '- Bản này từ commit 3f2a9c1b.' 'commit SHA'
red "trước đây" '- Trước đây API chạy trên VM.' 'từ chỉ lịch sử'
red "đã đo" '- Độ trễ đã đo là 40 ms.' 'từ chỉ lịch sử'
red "đã gỡ" '- Cache Memcached đã gỡ.' 'từ chỉ lịch sử'
red "nhật ký" '- Nhật ký thay đổi: thêm worker.' 'từ chỉ lịch sử'
red "dòng cập nhật" 'Cập nhật lần cuối: thứ hai.' 'dòng ghi ngày cập nhật'
red "tiêu đề mục lịch sử" '## Lịch sử thay đổi' 'tiêu đề mục kiểu lịch sử'
red "tiêu đề changelog" '### Changelog' 'tiêu đề mục kiểu lịch sử'
red "tiếng Anh: previously" '- Previously the API ran on a VM.' 'từ chỉ lịch sử'
red "ngày YYYY/MM/DD" '- Từ 2026/10/11 dùng Y.' 'ngày (YYYY/MM/DD)'
red "tháng N năm YYYY" '- Tháng 10 năm 2026 chuyển sang repo riêng.' 'ngày (tháng N năm YYYY)'
red "tháng N/YYYY" '- Hạn đổi khoá: tháng 3/2027.' 'ngày (tháng N năm YYYY)'
red "ngày N tháng M" '- Ngày 11 tháng 10 đã thêm hook X.' 'ngày (ngày N tháng M)'
red "ngày N/M" '- Ngày 5/9 thêm worker.' 'ngày (ngày N/M)'
red "hôm nay kiểu nhật ký" '- Đo hôm nay: 12 bản sao.' 'từ chỉ lịch sử'
red "hôm nay đã…" '- Hôm nay đã chuyển worker sang node mới.' 'từ chỉ lịch sử'
# ngày thật mà hai số bằng nhau / hợp lệ vẫn PHẢI đỏ (đối chứng cho các ca xanh "11/11 suite" ở mục 3)
red "ngày thật 10/10" '- Đo 10/10: 12 bản sao.' 'ngày (dd/mm)'
red "ngày thật 11/11" '- Thêm hook ngày 11/11.' 'ngày'
red "ngày thật 11/10 cuối dòng" '- Chuyển sang repo riêng 11/10' 'ngày (dd/mm)'
red "ngày thật 10/12 trong ngoặc" '- Worker thêm (10/12).' 'ngày (dd/mm)'
red "số PR một chữ số" '- Sửa ở (#4).' 'số PR/issue'
red "số PR một chữ số sau PR" '- Xem PR #7.' 'số PR/issue'
# đối chứng cho phép đo "chỉ khác MỘT dòng": ca xanh gốc vẫn xanh
printf '%s' "$GOOD" > "$CS"; chk >/dev/null; eq "$?" 0 "đối chứng: bỏ dòng thêm → lại xanh (đỏ ở trên là do đúng một dòng đó)"

echo "== 3. ca KHÔNG-nhầm: câu trạng thái hợp lệ phải vẫn xanh =="
green() {  # green <nhãn> <dòng thêm>
  { printf '%s' "$GOOD"; printf '%s\n' "$2"; } > "$CS"
  O=$(chk); rc=$?; eq "$rc" 0 "[$1] vẫn xanh${O:+ ($O)}"
}
green "phân số 3/4" '- 3/4 bản sao API ở trạng thái Ready.'
green "phân số 8/28" '- Có 8/28 trường đã điền.'
green "đang chuyển từ" '- Đang chuyển từ ArgoCD sang FluxCD.'
green "bootstrap ban đầu" '- Bootstrap ban đầu chưa có kho bí mật.'
green "chữ PR không số" '- Mọi thay đổi vào main đi qua PR có review.'
green "cổng và số thập phân" '- Cổng 8080, phiên bản 2.4.1, timeout 30.5 giây.'
green "lịch sử là con trỏ" '- Lịch sử thay đổi xem ở git log.'
green "tiêu đề số" '## 4. Quy ước đặt tên'
green "ký tự #3 trong mã" '- Ngôn ngữ C#7 và F#.'
# ca nhầm đo trên current-state thật của một repo hạ tầng nội bộ: mỗi ca xanh ở đây có ca đỏ cặp ở mục 2
green "11/11 suite" '- Test: 11/11 suite xanh; 3/4 replica.'
green "10/12 suite" '- Bộ test: 10/12 suite xanh.'
green "12/12 xanh" '- Kiểm thử đạt 12/12.'
green "10/10 xanh (điểm)" '- 10/10 xanh trên cả hai máy.'
green "11/11 test" '- Chạy 11/11 test mỗi lần PR mở.'
green "hôm nay trong mô tả hàm" '- Hàm `today()` trả về ngày hôm nay theo UTC.'
green "hôm nay là trạng thái" '- Giữ hành vi hôm nay, không đổi mặc định.'
green "luật #1" '- Luật cứng #1 cấm sửa thư mục gốc; priority #1 là an toàn.'
green "mục tiêu #2" '- Ưu tiên #2: giảm độ trễ.'
green "thư mục theo ngày" '- Dữ liệu lưu ở data/2026/10/11/ theo từng lô.'
green "tháng/ngày không số" '- Báo cáo chạy hằng tháng; ngày làm việc là thứ hai tới thứ sáu.'
green "tháng và năm tách rời" '- Hạn mức 3 tháng, tính theo năm tài chính.'

echo "== 4. trần kích thước =="
pad() {  # pad <số dòng> <số ký tự mỗi dòng> → văn bản
  python3 -c 'import sys; n,w=int(sys.argv[1]),int(sys.argv[2]); print("\n".join(("- dòng %d "%i).ljust(w,"x") for i in range(n)))' "$1" "$2"
}
printf '%s\n' "$(pad 120 60)" > "$CS"; O=$(chk); eq "$?" 0 "đúng trần 120 dòng: xanh"
printf '%s\n' "$(pad 121 60)" > "$CS"; O=$(chk); rc=$?; eq "$rc" 65 "121 dòng: đỏ"; has "$O" 'vượt trần dòng' "…nêu vượt trần dòng"
printf '%s\n' "$(pad 5 200)" > "$CS"; O=$(chk); eq "$?" 0 "dòng đúng 200 ký tự: xanh"
printf '%s\n' "$(pad 5 201)" > "$CS"; O=$(chk); rc=$?; eq "$rc" 65 "dòng 201 ký tự: đỏ"; has "$O" 'dòng dài' "…nêu dòng quá dài"
printf '%s' "$(pad 60 199)" | head -c 11990 > "$CS"; O=$(chk); eq "$?" 0 "dưới 12.000 byte: xanh ($(wc -c < "$CS") byte)"
python3 -c 'print("\n".join(("- dòng %d "%i).ljust(150,"x") for i in range(81)))' > "$CS"
[ "$(wc -c < "$CS")" -gt 12000 ] && ok "dụng cụ: văn bản thử vượt 12.000 byte ($(wc -c < "$CS"))" || bad "dụng cụ: văn bản thử không vượt 12.000 byte"
O=$(chk); rc=$?; eq "$rc" 65 "trên 12.000 byte (81 dòng ≤ 120): đỏ"; has "$O" 'vượt trần byte' "…nêu vượt trần byte"
hasnt "$O" 'vượt trần dòng' "…và KHÔNG nêu trần dòng (hai trần độc lập)"

echo "== 5. current-state kiểu 'nhật ký' → đỏ nhiều chỗ =="
cat > "$CS" <<'EOS'
# Hiện trạng hệ

**Đo ngày 14/09/2026, bổ sung 07/10 (mục 7: bộ chọn test theo diff; 08/10 cùng mục: mức `suites`).**
11/10: mục 2 hàng `api` — phiên hai repo nhận luật qua `--settings` nên đọc không còn hộp thoại, đo bằng claude 2.1.290 thật với API giả và một phiên E2E đứng hơn 80 phút, image `r9`, cách làm: thêm một luật Read vào tệp cấu hình do entrypoint sinh ra.
10/10: mục 2 hàng `worker` — bốn policy mới cho #337 và lỗ xoá/sửa; trước đây dùng PAT, nay dùng App.

## 2. Những gì ĐANG chạy

| Thành phần | Trạng thái |
|---|---|
| api | đã nghiệm thu live 07/10 (4 kịch bản), một lỗi bản chụp: #313 |
EOS
O=$(chk); rc=$?; eq "$rc" 65 "kiểu nhật ký: rc 65"
for lab in 'ngày (dd/mm)' 'số PR/issue' 'từ chỉ lịch sử' 'dòng dài'; do has "$O" "$lab" "kiểu nhật ký: có lỗi loại '$lab'"; done
N=$(printf '%s\n' "$O" | grep -c '^- dòng ')
[ "$N" -ge 8 ] && ok "kiểu nhật ký: $N dòng vi phạm được nêu" || bad "kiểu nhật ký: chỉ $N dòng vi phạm"

echo "== 6. lệnh =="
rm -f "$CS"; O=$(chk); rc=$?; eq "$rc" 66 "không có kb/current-state.md: rc 66"; has "$O" 'init-kb' "…và chỉ đường init-kb"
# file RỖNG hoặc chỉ khoảng trắng = chưa có khuôn: cùng rc 66 với "không có file" (skill ship không coi là cổng chặn cứng), KHÔNG rc 0
: > "$CS"; O=$(chk); rc=$?; eq "$rc" 66 "file kb/current-state.md rỗng (0 byte): rc 66, không phải 'đạt khuôn'"; has "$O" 'rỗng' "…nói rõ file rỗng"; has "$O" 'init-kb' "…và chỉ đường init-kb"
hasnt "$O" 'passes the current-state shape' "…không nói 'đạt khuôn' (the pass line)"
printf '  \n\n\t\n' > "$CS"; O=$(chk); eq "$?" 66 "file chỉ có khoảng trắng: rc 66"
printf '# Hiện trạng\n' > "$CS"; O=$(chk); eq "$?" 0 "đối chứng: file có một dòng nội dung: rc 0 (chỉ file rỗng mới thành cảnh báo)"
O=$(cd "$R" && python3 "$KBPY" check current-state a b 2>&1); eq "$?" 64 "thừa đối số: rc 64"
O=$(cd "$R" && python3 "$KBPY" check lesson 2>&1); eq "$?" 64 "loại lạ: rc 64"

echo; summary
