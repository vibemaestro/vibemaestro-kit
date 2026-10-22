[English](batonrun.md) | Tiếng Việt

# Nghiên cứu BatonRun: một run tốn bao nhiêu

BatonRun chạy mọi lần ghi ra ngoài phiên thành một baton script được kiểm, diễn tập, ký và kiểm sau khi chạy
(xem [BatonRun](../../plugins/vibemaestro-sdlc/docs/batonrun.vi.md)). Trang này nêu chi phí đó tính bằng token của model so với gọi tool trực tiếp, cách đo,
những gì việc dùng nó đã cho thấy, và điều các phép đo chưa cho thấy.

## Kết quả

- **Mỗi lần ghi, BatonRun ngang bằng gọi tool trực tiếp.** Với `baton go` và các kit baton, một baton thêm từ −1 đến 0
  lượt của phiên chính so với gọi tool trực tiếp, không tính lần đọc skill một lần. Chính số lượt của nhánh trực tiếp dao động
  ±1 hoặc hơn, nên đây là ngang bằng, không phải tiết kiệm.
- **Kiểm tra của máy gần như không tốn gì; lượt của model mới tốn.** Chạy các phase bằng lệnh rời (`new`, `check`,
  `rehearse`, `sign`, `run`, `log`) tốn khoảng 3,5 lần gọi tool trực tiếp ở cả hai cỡ task, do khoảng 6–7 lượt model thêm
  mỗi task. Vì vậy `baton go` chạy từ check tới log bằng một lệnh và in một dòng.
- **Phần còn lại là một lần mỗi phiên.** Đọc skill mất 2–3 lượt: khoảng 41k–62k đơn vị chi phí ở ngữ cảnh 413k token,
  18k–33k ký tự.
- **Giao các run cho một worker subagent mặc định không có lợi.** Khi đã đọc skill, chạy baton ngay trong phiên chính rẻ hơn.
  Worker chỉ giúp ở task nhiều baton đầu tiên của một phiên, hoặc để giữ ngữ cảnh lớn của phiên chính nhỏ lại.
- **Tính đúng giữ được trong phạm vi phép kiểm phủ tới.** Một phép kiểm độc lập thấy mọi đối tượng đúng ở mọi lượt chạy. Khi
  một baton hỏng, nguyên nhân là lỗi trong script của chính agent; baton dừng hoặc kết thúc với mã thoát 5, và không để lại
  trạng thái sai.

## Phương pháp

**Task.** Mỗi task chạy trong một repo nháp, dưới tiền tố tên riêng; `main` không bị đụng tới.

| Task | Agent làm gì | Đối tượng |
|---|---|---|
| C (phức tạp) | 4 label; một milestone hạn khoảng 7 ngày; một nhánh từ `main` với 3 file một dòng thành 3 commit; một tag ở đầu nhánh; một bản release nháp liệt kê các file; kiểm mọi đối tượng và thuộc tính | 8 |
| S (đơn giản) | một label; kiểm nó | 1 |

**Nhánh.** Một mệnh đề phương pháp trong một prompt giống hệt nhau quyết định nhánh.

| Nhánh | Phương pháp |
|---|---|
| D | Gọi tool trực tiếp. "Do not write a baton script and do not use BatonRun." |
| B | Mọi lần ghi qua một baton với các lệnh rời: `new`, `check`, `rehearse`, `sign`, `run`, `log`. |
| B′ | Mọi lần ghi qua BatonRun với `baton go` (một lệnh từ check tới log), và một kit baton khi có kit baton phủ lần ghi đó. |
| B‴ | Agent chính giao toàn bộ việc baton cho một worker subagent, chờ một lần, rồi kiểm các dòng log. |

**Lượt chạy.** Mỗi lượt là một subagent `general-purpose` mới trên Opus, từng lượt một, các nhánh xen kẽ nhau. Không chạy được
`claude -p` headless trong môi trường thử nghiệm, vì không credential nào tới được tiến trình con. Đối tượng của mỗi lượt bị xoá
sau lượt đó, ngoài phép đo.

**Đếm gì.**

- *Lượt:* số id tin nhắn assistant khác nhau trong transcript của lượt chạy.
- *Đơn vị chi phí:* token nhân theo giá, tính bằng đơn vị giá input cơ bản của Opus: cache read ×0,05, cache write 5 phút
  ×1,25, cache write 1 giờ ×2, input không cache ×1, output ×5. Một subagent được tính theo giá model của chính nó, cùng đơn vị.
- *Thời gian:* con số của harness cho subagent.
- *Tính đúng:* sau mỗi lượt, một phép kiểm chỉ đọc riêng (không phải lời khẳng định của chính lượt chạy) tìm mọi đối tượng và
  thuộc tính. Nó được thử trước trên một đối chứng dương (thấy đủ đối tượng) và một đối chứng âm (không thấy gì).

**Quy về một phiên dài.** Một subagent bắt đầu ở khoảng 20k token ngữ cảnh; một phiên chạy dài trung bình khoảng 413k
token mỗi lần gọi. Chênh lệch được quy về ngữ cảnh đó theo `lượt thêm × 413.000 × 0,05 + chênh lệch output × 5`. Một lượt thêm
ở 413k tốn 20.650 đơn vị (chỉ cache read).

## Những gì việc dùng nó đã cho thấy

- **Permission rule.** Không có allow rule, bộ phân loại auto-mode của Claude Code chặn baton script chạy shell từ xa. Rule
  nêu đường dẫn plugin có version thì gãy sau mỗi lần cập nhật plugin, và rule đường dẫn khớp với `Edit(path)`, không phải
  `Write(path)`. Vì vậy `baton.py permissions` in và kiểm các rule nêu một launcher ổn định (`--install-launcher`).
- **Launcher trần.** Allow rule chỉ khớp lệnh launcher trần: `cd <dir> && <launcher> go … | grep …` không khớp rule nào, và
  bộ phân loại từ chối nó. Hook cảnh báo một lệnh launcher có pipe, `&&`, `;` hoặc redirect, và `run` in một dòng khi thành công.
- **`go -` với heredoc.** Allow rule `Bash(<launcher> go:*)` khớp `go -`, nhưng một kiểm tra có sẵn của Claude Code từ chối
  heredoc có thân chứa các khối ngoặc nhọn của khung mẫu kèm dấu nháy ("Contains brace with quote character"), trước mọi
  rule. Vì vậy một baton viết tay là một lần Write ra đường dẫn mới, rồi `go <path>`.
- **Tiến trình nền trong một lần ghi.** `(cd "$V" && … nohup node … &)` làm `baton run` treo sau khi mọi lần ghi đã chạy: `&`
  gắn với cả danh sách, nên một bản sao fork của script giữ ống output của baton mở. `check` không cảnh báo điều này; hãy để
  tiến trình nền ngoài các lần ghi của baton.
- **Chữ ký đã dùng.** Lần `run` thứ hai trên một chữ ký đã dùng bị từ chối với mã thoát 3, và không gì chạy: một chữ ký, một run.

## Điều các phép đo chưa cho thấy

- **Chưa đạt một lượt đọc tài liệu mỗi phiên.** Lần đọc một lần mất 2–3 lượt. Một nguyên nhân có thể, cách prompt của task
  nói về undo và stop, chưa được kiểm.
- **Ngữ cảnh mỗi lần ghi vẫn cao hơn gọi trực tiếp.** Ngưỡng "số ký tự của nhánh trực tiếp + 10%" chưa đạt.
- **"Mọi baton ok ngay lần `go` đầu" chưa ổn định:** 9 hoặc 10 trên 10, tuỳ bộ lượt chạy.
- **Mẫu nhỏ.** n = 2 hoặc 3 mỗi nhánh và mỗi task, một repo nháp, một model chính, một người vận hành. Chính nhánh trực
  tiếp ở task C dao động từ 5 đến 12 lượt, nên chênh lệch một lượt là nhiễu.
- **Giới hạn của công cụ đo.** Các lượt là subagent, không phải phiên headless; mức effort của chúng chưa được kiểm; token
  output là cận dưới. Phép quy về 413k giả định số lượt đo ở khoảng 14–90k ngữ cảnh vẫn giữ ở 413k, điều này chưa được kiểm,
  và nó chỉ tính cache read của một lượt thêm.
- **Chưa có đường hoà vốn.** Hai cỡ task cho biết dấu, không cho biết độ dốc.
- **Một ngoại lệ lint chưa được đo:** chỉ xoá các đối tượng do chính baton đó tạo.
