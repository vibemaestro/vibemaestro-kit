[English](brain.md) | Tiếng Việt

# Nghiên cứu brain: điều đã biết về compaction và brain

Trang này nêu điều đã biết về `vibemaestro-brain` và về compaction của Claude Code: mỗi kết quả là gì, đúng trong điều kiện
nào, và điều gì chưa được chứng minh. Về thiết kế của brain, xem
[README của plugin brain](../../plugins/vibemaestro-brain/README.vi.md).

**Nhãn.** Con số ghi **docs** lấy từ tài liệu Claude Code; **giá trị thiết kế** là con số chọn trong thiết kế, không đo;
*chưa kiểm* là điều được nêu hoặc nghi ngờ, chưa từng xác minh. Mọi con số khác do kit đo.

**Thuật ngữ.** Probe tách một phiên thành hai nhánh: nhánh H bật brain và nhánh C, đối chứng, tắt brain. Mã thoát của nó:
0 đạt, 1 không đạt, 2 dừng hoặc vô hiệu, và 3 khi C cũng đạt 10/10, nên brain chưa được chứng minh là cần. Shelf index là
danh sách skill mà brain đưa vào lại.

## Kết quả

| Câu hỏi | Kết quả | Điều kiện |
|---|---|---|
| Chi phí token của một phiên chạy dài đi vào đâu? | 64% cache read, 24% cache write, 12% output; ngữ cảnh trung bình khoảng 413k token mỗi lần gọi (tối đa 936k) | một phiên dài 2,4 ngày với 2.089 lần gọi ở luồng chính; trọng số là giả định (cache read 0,05×, cache write 1 giờ 2×, output 5×) |
| Compaction lúc rảnh có chạy trong một phiên như vậy không? | 0 trên 8 khoảng rảnh trên một giờ; sau mỗi khoảng là một lần ghi lại toàn bộ ngữ cảnh 200–680k token | compaction lúc rảnh mặc định bật từ Claude Code 2.1.290 (**docs**); phiên chạy 2.1.299 và 2.1.301; nguyên nhân *chưa kiểm* |
| Hook có thấy ngữ cảnh lớn tới đâu không? | đuôi transcript mang các bản ghi `usage`, và `CLAUDE_CODE_SESSION_ID` có trong môi trường Bash của phiên, nên một hook đọc được chúng | một lần đọc, lấy từ môi trường Bash của phiên, không phải từ bên trong một hook; transcript có thể trễ hơn lượt hiện tại (**docs**) |
| Một lần compaction làm rơi gì mà một phiên chạy dài cần? | transcript ghi danh sách skill một lần, lúc mở phiên, và không lần nào sau compaction; một lần đưa vào lại bị cắt ở độ dài cố định có thể mất đúng dòng nêu tên một skill | một phiên; model còn thấy danh sách trong mỗi request hay không *chưa kiểm* |
| `brain cost` đếm token có đúng không? | khớp một phép đếm độc lập theo từng trường; bộ đọc cộng mọi bản ghi `usage` sẽ đếm phần lớn lần gọi hai lần, vì mỗi khối nội dung lặp lại `usage` của response của nó | một transcript |
| Hook của brain chậm cỡ nào? | trung vị: session-start 62,6 ms, guard-edit 38,1, guard-bash 14,7, guard-owner 13,9 (chỉ khởi động Python: 10,3) | một máy, 40 lượt mỗi hook |
| Hộp thoại của owner có hiện và ghi như thiết kế không? | `acceptEdits` và `auto`: hộp thoại hiện, dòng đủ, mục được ghi; `dontAsk`, `plan` và `-p`: không ghi gì | một máy, Claude Code 2.1.302; các lượt dành cho `default` chạy ở `auto`, mặc định của máy đó; chưa thử `bypassPermissions` |
| Script có điều khiển được một lần compaction thật không? | có: auto-compaction ở mức sàn cửa sổ 100k, hoặc `/compact` headless; khối mà `SessionStart:compact` để lại được đọc sau `--resume` | khối được lưu trong transcript thành một bản ghi `hook_additional_context` |
| Phụ thuộc sdlc tốn gì bên trong probe? | dưới `--setting-sources project,local` sdlc đã cài không được bật, nên Claude Code không nạp brain; khi không tắt tiếng, sdlc thêm 11.276 ký tự mỗi lần mở phiên | Claude Code 2.1.303; chi phí token của số ký tự đó là phép tính ở 4 ký tự mỗi token |
| Sau một lần compaction thật, brain có giữ được quyết định mà bản tóm tắt làm mất không? | nhánh H 10/10 và nhánh C 10/10 ở mỗi lượt trong 3 lượt: mã thoát 3, brain chưa được chứng minh là cần ở cỡ này | một lần compaction, 10 quyết định mỗi cái kèm một phương án gần đúng được thả ra, khoảng 225k token ngữ cảnh; khối giữ ở 1.688 ký tự, dưới trần 8.000 ký tự |
| Ngữ cảnh SessionStart có còn qua `resume` và `clear` không? | `resume` giữ nó: nó được lưu trong chuỗi transcript; `/clear` làm rỗng ngữ cảnh | `clear` theo **docs**, chưa đo |

## Probe chạy thế nào

Mỗi lượt cài 10 quyết định của owner, mỗi quyết định có một anchor chính xác, cộng một lượt của owner cho mỗi quyết định thả
ra một phương án gần đúng là "chưa quyết". Phần đệm đưa ngữ cảnh lên khoảng 120k token (**giá trị thiết kế**). Phiên được tách
hai lần từ cùng một điểm, nên hai nhánh chung từng byte trước compaction; mỗi nhánh được compaction, ở mức sàn 100k của cửa sổ
auto-compaction, sau một bước trung tính. 10 câu hỏi được hỏi ở một tiến trình thứ hai, nên compaction không bao giờ thấy
chúng, và một script chấm câu trả lời theo anchor chính xác, không bao giờ bằng model. Các lượt dùng Opus, 3 lượt mỗi probe.

## Điều rút ra

- Chi phí lớn nhất của một phiên dài là đọc lại một ngữ cảnh lớn ở mỗi lần gọi, nên việc của brain là làm cho compaction
  sớm trở nên an toàn, không phải né compaction. `brain cost` dùng các trọng số ở trên.
- Brain tự liệt kê lại skill (Shelf index, ở mỗi `SessionStart`, tối đa 1.000 ký tự: **giá trị thiết kế**), và một lần đưa
  vào lại không được cắt mất những dòng quan trọng.
- `brain cost` đếm một lần gọi cho mỗi `message.id`.
- Probe compaction sau một bước trung tính và hỏi câu hỏi ở một tiến trình thứ hai, nên compaction không bao giờ thấy chúng.
  Mỗi phiên probe nạp sdlc với hook đã tắt tiếng (`.vibemaestro/sdlc.json` `{"hooks": "off"}`), và bước preflight kiểm các
  phụ thuộc trong manifest của brain trước khi tốn gì.
- Test sống của hộp thoại owner chọn mọi mục menu theo chữ và con trỏ, không bao giờ theo vị trí.

## Điều chưa được chứng minh

- **Brain là cần.** Ở một lần compaction và 10 quyết định, bản tóm tắt của chính Claude Code đã giữ mọi quyết định.
- **Nhiều lần compaction liên tiếp**, nhiều quyết định hơn, và quyết định cũ hơn những gì một bản tóm tắt giữ.
- **Một khối `# Compact instructions` ở cấp người dùng** so với không có khối và so với brain.
- **Vì sao compaction lúc rảnh không chạy**, và `brain cost` tái tạo được tỉ lệ chi phí ở trên trên transcript của phiên đó.
- **Tự quên trong một ngày**, và chi phí thấp hơn cho mỗi PR đã merge.
- **`bypassPermissions` và chính `default`** trong hộp thoại của owner.
- **Model còn thấy danh sách skill hay không** sau một lần compaction: transcript chỉ ghi các attachment.
