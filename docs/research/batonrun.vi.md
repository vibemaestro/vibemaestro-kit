[English](batonrun.md) | Tiếng Việt

# Nghiên cứu BatonRun: một run tốn bao nhiêu

BatonRun chạy mọi lần ghi ra ngoài phiên thành một baton script được kiểm, diễn tập, ký và kiểm sau khi chạy
(xem [BatonRun](../../plugins/vibemaestro-sdlc/docs/batonrun.vi.md)). Trang này nêu chi phí đó tính bằng token của model, đo theo hai cách:
cả phiên cho mọi lần ghi đi qua BatonRun so với phiên không có plugin, và, trong một phiên đã nạp plugin, một baton so với gọi
tool trực tiếp. Trang nêu cách đo, những gì việc dùng nó đã cho thấy, và điều các phép đo chưa cho thấy.

## Kết quả

### Cả phiên, so với không có plugin

- **Qua một phiên 18 việc, một phiên cho mọi lần ghi đi qua BatonRun tốn khoảng 3 đến 3,7 lần một phiên không có plugin,
  tính trên mỗi lần ghi đúng.** Qua 18 việc trong một phiên, tỉ số là 3,05–3,67 qua bốn cặp phiên: khoảng 43k–49k đơn vị chi phí mỗi lần ghi đúng so
  với 13k–14k. Ở việc đầu tiên trong một phiên mới, tỉ số là 4,35 với một việc phức tạp và 3,39 với một việc đơn giản.
- **Không hòa vốn trong 18 việc.** Tỉ số chi phí mỗi lần ghi khoảng 3,5 ở việc đầu, 3,9–4,0 ở bốn việc kế tiếp, 3,6 ở việc
  thứ sáu, và 3,3–3,5 từ việc thứ bảy trở đi. Chi phí mỗi lần ghi giảm ở cả hai nhánh qua các việc đầu và tăng lại ở các việc gặp lỗi cài sẵn; một việc
  điển hình về sau tốn khoảng 41k–43k đơn vị với BatonRun và 12k–13k khi không có. Ngữ cảnh phiên của plugin, khoảng 12k–15k đơn
  vị mỗi phiên, chỉ là phần nhỏ trong chi phí của một phiên; phần theo từng việc mới là phần ở lại. Trong phần thêm, cache read
  chiếm 42–47 %, output 32–36 % và cache write 21–22 %; một phiên có BatonRun viết khoảng 4,4 đến 4,9 lần số token output và dùng
  khoảng 1,3 đến 2,3 lượt thêm mỗi việc.
- **Nạp plugin tự nó không làm phiên dùng BatonRun.** Khi đã nạp plugin và prompt không yêu cầu BatonRun, không phiên nào trong
  năm phiên báo có baton; một phiên như vậy tốn 1,41 lần (việc phức tạp) và 2,06 lần (việc đơn giản) một phiên không có plugin,
  chủ yếu do ngữ cảnh phiên của plugin.
- **Độ đúng như nhau ở hai nhánh.** Qua 18 việc chính, mọi lần ghi đều đúng ở mọi phiên, trừ một lần mà các phiên BatonRun để
  chưa làm vì cần owner. Không việc nào để lại thay đổi không được yêu cầu trong ref, ticket, settings hay tệp đã cài của lab; ba
  việc hoàn tác đều đúng; hai việc có lỗi cài sẵn dừng mà không đổi gì.
- **BatonRun không được lợi từ việc làm một loại ghi lần thứ hai hơn một phiên không có plugin.** Ở ba trong bốn loại, lần lặp
  giảm ít hơn với BatonRun, và khoảng của các phiên không chồng nhau; push nhánh thì chồng nhau. Lần sau trên lần đầu, theo từng phiên:
  ticket thứ hai 0,43–0,45 với BatonRun và 0,39–0,40 khi không có; lần cài tệp thứ hai 0,95–0,96 và 0,88–0,90; lần push nhánh thứ
  hai 0,57–1,01 và 0,88–1,16; lần hoàn tác thứ hai 0,89–1,02 và 0,71. Phần lớn baton là một script mới; không lượt chạy nào được đọc dùng `--reuse`, nên
  việc dùng lại không được đo.

### Điểm dừng và chữ ký của owner

- **Phiên khai điểm dừng cho một hành động không hoàn tác được, và không ai ký nó.** Xóa một ticket mà công cụ ticket không
  khôi phục được, thứ không pattern lint nào phủ, dừng chờ owner ở cả hai phiên BatonRun: phiên tự khai `irreversible-delete`.
  Thêm một allow rule qua kit settings-merge, có kind tự khai điểm dừng, dừng chờ owner ở cả hai. Không có quy tắc quyền, thứ giữ
  cho một lần ghi như vậy không chạy không phải hộp thoại owner (không hộp thoại nào mở) mà là phiên không ký, hoặc bộ phân loại
  auto-mode từ chối lệnh `sign --by owner` của chính phiên (bên dưới).
- **Lint điểm dừng và định nghĩa điểm dừng khác nhau ở một nhánh đã merge.** Loại `irreversible-delete` phủ các nhánh chưa merge.
  Lint, một lớp chặn phụ cho điểm dừng bị bỏ sót khỏi header, bắt mọi `git push --delete` một nhánh, đã merge hay chưa, và không
  khớp `git push … origin ":$REF"` với refspec trong ngoặc kép, hay `git update-ref -d`. Khi được yêu cầu xóa một nhánh đã merge
  có commit vẫn nằm trong `main`, một phiên BatonRun không khai điểm dừng, viết bước hoàn tác tạo lại nhánh, và run chạy với chữ
  ký của chính phiên ở mode auto: điều đó khớp định nghĩa, không khớp lint.
- **Không có quy tắc quyền thì ký thay owner không mở hộp thoại nào.** Với một điểm dừng, phiên chạy `sign --by owner`, lệnh được
  thiết kế để mở hộp thoại quyền của Claude Code cho owner; ở mode auto chỉ quy tắc `ask` từ `baton.py permissions --print` mở
  nó. Không có quy tắc đó, lệnh chạy như một lệnh thường: baton không kiểm rằng có người đã duyệt, và bộ phân loại auto-mode của
  Claude Code là lớp chặn duy nhất (nó đã từ chối cả hai lần thử được đo). Hãy áp các quy tắc quyền trước khi dựa vào
  chữ ký của owner.

### Trong một phiên đã nạp plugin

Các lượt chạy subagent trong một phiên, nơi mọi nhánh đều đã nạp plugin, skill được đọc một lần, và prompt nêu phương pháp. Chúng
đếm lượt của phiên chính mỗi lần ghi, không đếm token: trong các điều kiện đó một baton ngang bằng gọi trực tiếp. So với một phiên
không có plugin, cả một phiên có BatonRun dùng khoảng 1,3 đến 2,3 lượt thêm mỗi việc và khoảng 4,4 đến 4,9 lần số output.

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

### Cả phiên

**Task.** Hai nghiên cứu. Nghiên cứu đầu giao một task cho một phiên mới: task C hoặc S bên dưới. Nghiên cứu thứ hai giao 20
việc nối tiếp cho một phiên mỗi nhánh, trên một lab cục bộ đóng vai GitHub: một git remote bare có hook từ chối một số commit,
một công cụ ticket cho issue và pull request, và một tệp settings của dự án. Các việc là ticket, nhánh, một lần merge, hai lần
cài tệp, một tag, ba việc hoàn tác, hai việc có lỗi cài sẵn (một hook từ chối, một ticket bị khóa) và, cuối cùng, hai ca dừng
(một allow rule, việc xóa một nhánh đã merge, thứ mà lint điểm dừng bắt khi viết thành `git push --delete`). Hai việc này nằm ngoài phép đo chính, vì một lần ghi bị để
chưa làm khiến lab của hai nhánh khác nhau ở mọi việc sau đó.

**Nhánh.**

| Nhánh | Phiên có gì |
|---|---|
| BatonRun | plugin sdlc và không plugin nào khác; một dòng trong prompt: mọi lần ghi đi qua BatonRun |
| Đã nạp plugin | plugin sdlc và không plugin nào khác; prompt không có dòng đó (chỉ nghiên cứu đầu) |
| Không plugin | không có plugin; prompt không có dòng đó |

Các phiên chạy không có launcher của baton và các quy tắc quyền, thứ chỉ owner thêm vào, nên baton chạy bằng
`python3 <plugin>/scripts/baton.py`.

**Phiên.** Claude Code 2.1.290, Opus 5.5 ở effort cao, trong một sandbox. Nghiên cứu đầu: 2 đến 6 phiên mỗi nhánh và task.
Nghiên cứu thứ hai: hai phiên mỗi nhánh; hai phiên của một cặp nhận mỗi việc cùng lúc. Không ai ký thay owner: một lần ghi cần
owner bị bỏ qua và được báo cáo.

**Đếm gì.**

- *Đơn vị chi phí:* như bên dưới, từ transcript của mỗi phiên, theo từng việc. Con số chi phí của chính Claude Code cho mỗi phiên
  20 việc là 4 USD mỗi triệu đơn vị với các trọng số này; transcript chứa 80–87 % số đơn vị đó, khiến tỉ số cao hơn khoảng
  4–9 % so với tỉ số tính từ con số của Claude Code.
- *Một lần ghi đúng:* trạng thái lab trước và sau mỗi việc: các lần ghi việc yêu cầu, và mọi thay đổi khác tính là để lại. Một
  lần hoàn tác được kiểm so với trạng thái trước việc bị hoàn tác.
- *Phép đo chính (20 việc):* đơn vị chi phí ÷ số lần ghi đúng qua 18 việc đầu. Một việc mà ở đó có phiên nào cần owner bị loại
  khỏi mọi phiên.

### Trong một phiên

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
- **Cả phiên: mẫu nhỏ, một lab.** Hai phiên mỗi nhánh qua 20 việc, 2 đến 6 mỗi nhánh và task ở nghiên cứu đầu; một model ở
  một mức effort; một lab cục bộ không có độ trễ mạng hay giới hạn API, có remote là một thư mục mà phiên ghi được. Ghi lên GitHub
  qua kit baton không thuộc nghiên cứu 20 việc, và tổ hợp việc của nó lặp mỗi loại ghi nhiều nhất hai lần.
- **Cả phiên không có quy tắc quyền.** Một người dùng đã áp `permissions --print` có thể gặp lời nhắc và chi phí khác. Prompt
  của các nhánh khác nhau ở một dòng yêu cầu BatonRun.
- **Output ở effort cao gồm cả phần suy nghĩ,** nên không biết bao nhiêu phần output là baton script.
- **Mẫu nhỏ trong một phiên.** n = 2 hoặc 3 mỗi nhánh và mỗi task, một repo nháp, một model chính, một người vận hành. Chính nhánh trực
  tiếp ở task C dao động từ 5 đến 12 lượt, nên chênh lệch một lượt là nhiễu.
- **Giới hạn của công cụ đo.** Các lượt là subagent, không phải phiên headless; mức effort của chúng chưa được kiểm; token
  output là cận dưới. Phép quy về 413k giả định số lượt đo ở khoảng 14–90k ngữ cảnh vẫn giữ ở 413k, điều này chưa được kiểm,
  và nó chỉ tính cache read của một lượt thêm.
- **Chưa có đường hoà vốn trong một phiên.** Hai cỡ task cho biết dấu, không cho biết độ dốc; các phiên 20 việc cho đường đó.
- **Một ngoại lệ lint chưa được đo:** chỉ xoá các đối tượng do chính baton đó tạo.
