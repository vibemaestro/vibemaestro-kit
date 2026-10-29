[English](sdlc.md) | Tiếng Việt

# Nghiên cứu sdlc: plugin tốn bao nhiêu và đem lại gì trên việc của app

Plugin sdlc đưa mỗi việc qua một intent, một spec được người duyệt, và một pull request, rồi giữ những gì nó học được trong
`kb/` của repo. Trang này cho biết plugin tốn bao nhiêu token model tính đến commit cục bộ, và đem lại bao nhiêu code chạy đúng,
so với cùng model làm cùng các việc mà không có plugin. Pull request và các vòng review của nó không nằm trong phép đo. Trang
cũng nói cách đo và những điều các phép đo chưa cho thấy. Một phép đo thứ hai, ở cuối trang, hỏi plugin cùng `kb/` của nó đem
lại gì khi câu trả lời của một yêu cầu chỉ được ghi ở đó.

## Kết quả

- **Không có khác biệt đo được về chi phí cho mỗi việc làm đúng (0,76–1,25 theo cách chấm đã đặt trước khi việc cuối chạy).**
  Đó là tỉ số chi phí cho mỗi việc qua được các test ẩn, có plugin chia không plugin, qua hai chuỗi; khoảng này chứa 1,0. Theo
  cách chấm đã quyết, không plugin tốn ít hơn cho mỗi việc đạt: 1,01–1,25. Con số đó dựa vào một lựa chọn chấm cho việc cuối,
  đặt sau khi có kết quả, chuyển một lượt không plugin từ trượt sang đạt, và ở chuỗi thứ nhất còn dựa vào một việc duy nhất: lượt có
  plugin của việc cuối, trượt vì một quy tắc mà việc có nêu. Theo kết quả thô của các test ẩn, không loại trừ gì, tỉ số là 1,01–1,41.
- **Chi phí, review và kết luận đặt cạnh nhau:**

  | | chuỗi 1, có plugin | chuỗi 1, không plugin | chuỗi 2, có plugin | chuỗi 2, không plugin |
  |---|---|---|---|---|
  | đơn vị chi phí, năm việc | 4,81 M | 5,12 M | 4,79 M | 4,75 M |
  | số việc đạt (chấm đặt trước khi việc cuối chạy) | 3 trên 5 | 4 trên 5 | 4 trên 5 | 3 trên 5 |
  | số việc đạt (theo cách chấm đã quyết) | 3 trên 5 | 4 trên 5 | 4 trên 5 | 4 trên 5 |
  | điểm review (càng thấp càng tốt) | 24 | 16 | 26 | 30 |
  | số review nói việc đã đạt | 1 trên 5 | 2 trên 5 | 1 trên 5 | 2 trên 5 |

  Hai nhánh tiêu gần bằng nhau: khoảng 38,4 và 39,5 USD cho mười phiên mỗi nhánh. Tỉ số đi theo số việc đạt, không theo số
  tiền tiêu.
- **Trong các lượt này, plugin rẻ hơn ở một việc và đắt hơn ở hai việc** (mỗi con số là trung bình của hai lượt). Ở việc thứ ba, mỗi lượt tốn 1,30 M đơn vị so với 2,04 M; ở việc thứ tư,
  0,64 M so với 0,48 M; ở việc thứ năm, 0,82 M so với 0,48 M. Hai việc đầu gần ngang nhau.
- **Không thấy khoản tiết kiệm nào qua chuỗi.** Từ việc đầu đến việc thứ năm, chi phí không plugin đổi ×0,70 và ×0,64, có plugin
  đổi ×1,28 và ×0,90. Một khoản tiết kiệm tích lũy trong `kb/` sẽ hiện ra thành chi phí của plugin giảm nhanh hơn; với hai chuỗi,
  mỗi chuỗi năm việc cỡ khác nhau, số liệu này cũng không cho thấy điều ngược lại.
- **Không nhánh nào làm hồi quy bộ unit test.** Một lượt có plugin làm hỏng ba test ẩn của một việc trước.
- **Plugin thêm quy trình và lượt của người.** Có plugin, mọi lượt đều viết spec, và người trả lời 14 lần (10 lần duyệt
  spec, 4 lời nhắc quyền) so với một lần khi không plugin. Số lượt: 787 so với 637; token output: 760.207 so với 808.750.

## Phương pháp

**App và các việc.** Một repo app Node cỡ vừa: một server, một client JS thuần, test nằm cạnh module, khoảng 360–470 unit test.
Các việc là năm pull request đã merge trong một vùng của app, chạy lại theo thứ tự merge; sáu pull request khác merge xen giữa
chúng đến dưới dạng lịch sử mà không nhánh nào làm. Trước mỗi việc, code được đặt lại về lịch sử của app ngay trước pull request
đó, nên mọi lượt của một việc đều bắt đầu từ cùng một code. Mỗi việc ghi yêu cầu gốc, các quyết định mà pull request gốc đã chốt,
và một đoạn kết dừng việc ở commit cục bộ.

**Nhánh.**

| Nhánh | Phiên có gì |
|---|---|
| P | app kèm `kb/` của nó và plugin sdlc; `kb/` của P mang từ việc này sang việc sau |
| N | bản xuất công khai của app, không `kb/`, không plugin |

Code của P bằng code của N ở mọi bước. Cây của N cho việc thứ năm là một độ lệch đã nêu: bản xuất của app bị đỏ ở đó.

Cả hai nhánh chạy Claude Code 2.1.290 với Sonnet 5.5 ở mức effort high, một phiên mới cho mỗi việc, trong sandbox có repo cục
bộ và không có remote. Mỗi nhánh chạy hai chuỗi năm việc, và hai phiên của một cặp bắt đầu mỗi việc cùng lúc.

**Đếm gì.**

- *Đơn vị chi phí:* token của phiên từ lúc nhận việc đến khi xong việc: lần đầu thử push hoặc mở pull request sau commit cuối,
  lúc người vận hành dừng, hoặc trần 120 phút, cái nào đến trước. Token được nhân theo giá, tính bằng đơn vị giá input cơ bản
  của Opus 5.5: Sonnet 5.5 input ×0,5, output ×2,5, cache read ×0,05. Cache write 1 giờ được lấy ×1,0, gấp đôi giá input, là
  một giả định, không phải giá công bố. USD là đơn vị ÷ 250.000, một ước tính.
- *Một việc làm đúng:* các test của chính pull request gốc mà việc đó nêu (hai đến năm test mỗi việc) đều đạt trên commit cuối
  của lượt, khi đặt các file test đó vào. Bản merge gốc qua được chúng và code trước nó trượt chúng, theo tên, ở mọi việc.
- *Phép đo chính:* mỗi chuỗi, đơn vị chi phí của năm việc ÷ số việc làm đúng, lấy của P chia của N. Khi khoảng qua hai chuỗi
  chứa 1,0, kết quả là "không có khác biệt đo được".
- *Hồi quy:* bộ unit test so với code bắt đầu của việc, và các test ẩn của mỗi việc trước chạy trên mọi commit sau. Một test mà
  chính các pull request gốc cũng cố ý đổi thì không tính.
- *Review mù:* thay đổi code của mỗi lượt (bỏ `kb/` và file của plugin) được review mà không biết nhánh.
  - Một người review Opus 5.5 mới đọc việc, bản vá và app đã vá, và được chạy test của nó.
  - Một người thứ hai kiểm từng phát hiện.
  - Một người thứ ba cho mỗi việc phán quyết các phát hiện của cả bốn thay đổi theo một chuẩn.
  - Điểm: 3 × chặn + 2 × lớn + 1 × nhỏ, chỉ tính các phát hiện được phán là thật.

**Loại trừ khi chấm.** Ba việc có một test khẳng định điều mà văn bản của việc không nêu hoặc nói ngược lại. Cả ba áp dụng cho
cả hai nhánh, và mỗi loại trừ được đặt sau khi có kết quả của chính việc đó, trừ phần đầu của việc thứ năm.
- Test đầu của việc thứ ba cần tên repo mà văn bản cấm.
- Một test của việc thứ tư cần một quy tắc mà văn bản bỏ sót.
- Ở việc thứ năm, các khẳng định về chi phí của một test và một tag không được chấm. Các khẳng định về chi phí được gạt ra
  trước khi việc đó chạy. Tag được gạt ra sau khi có kết quả của nó.

## Điều các phép đo chưa cho thấy

- **Mẫu nhỏ.** Hai chuỗi mỗi nhánh, một app, một vùng của nó, một model. Theo cách chấm đã quyết, một cặp chuỗi nằm ở tỉ số
  1,01.
- **Cách chấm dựa vào phán đoán.** Ba trong năm việc được chấm có loại trừ, và trừ một loại trừ, tất cả được đặt sau khi có kết
  quả của việc đó; loại trừ cuối được đặt sau khi cả chuỗi đã chạy xong. Vì vậy câu kết luận dùng cách chấm đã đặt trước khi
  việc cuối chạy.
- **Pull request không được đo.** Mọi lượt dừng ở commit cục bộ, ở cả hai nhánh; chi phí mở pull request, các vòng review và
  việc merge không có trong số liệu.
- **Không có test trình duyệt.** Cả phần kiểm lẫn người review đều không chạy bộ end-to-end; các phát hiện về test end-to-end
  đến từ việc đọc chúng.
- **Độ phủ của review không đều.** Một điểm chỉ tính những gì người review của nó tìm ra. Một lỗi có trong cả bốn thay đổi của
  việc thứ ba chỉ được ghi cho ba trong số đó.
- **Che mù chỉ một phần.** Một bản vá có thể để lộ nhánh có plugin (một tham chiếu tới đường dẫn `kb/` bị thay bằng một dấu).
  Người chạy các review và phần kiểm của chúng biết mỗi thay đổi đến từ lượt nào; các người review thì không. Các người review
  chạy trên cùng một máy, không có gì giữ họ trong thư mục của riêng mình. Điều đó đã xảy ra một lần: một phép kiểm đầu tiên
  trích một bản sao muộn hơn của app tìm thấy ở nơi khác, và người phân xử của nó đã gạt bằng chứng đó sang một bên.
- **Lượt của người không được tính giá.** 14 lần can thiệp khi có plugin là thời gian của người; ảnh hưởng của chúng tới chi phí
  chỉ là token của các lượt chúng mở ra.
- **Các quyết định đã được đưa sẵn.** Cả hai nhánh nhận, kèm mỗi việc, các quyết định mà pull request gốc đã chốt; nghiên cứu đo
  việc thực hiện, không đo việc tự tìm ra các quyết định đó.

## Khi câu trả lời chỉ được ghi trong `kb/`

Phép đo ở trên đưa các quyết định vào đề bài cho cả hai nhánh, nên nó đo việc làm, không đo việc tìm ra điều đã quyết. Phép đo
này hỏi: khi câu trả lời đúng của một yêu cầu chỉ được ghi trong `kb/` của app, plugin cùng `kb/` đó đem lại gì, so với cùng
model không có cả hai?

### Kết quả

- **Có plugin và `kb/` của nó, điểm cao hơn ở bốn trên năm việc và hoà ở việc thứ năm.** Như vậy đạt mức đã đặt trước khi chạy
  (ít nhất bốn trên năm), nhưng sát nút: mỗi việc chạy hai lần mỗi nhánh, và hai trong bốn lần thắng dựa vào một lượt duy nhất
  không plugin. Nhánh có plugin tìm ra câu trả lời chỉ ghi trong `kb/` thường hơn ở ba trên năm việc.

  | Việc | Câu trả lời được ghi ở đâu | Điểm, có plugin (lượt 1, lượt 2) | Điểm, không plugin (lượt 1, lượt 2) | Đơn vị chi phí, có plugin ÷ không |
  |---|---|---|---|---|
  | vì sao nhân vật rảnh vẫn ở trên màn hình | lý do trong một spec | 2, 2 trên 3 | 1, 2 trên 3 | 1,77 |
  | một con số phí lấy từ đâu | một quyết định | 2, 1 trên 3 | 0, 0 trên 3 | 1,04 |
  | thêm một tính năng mà một spec trước đã loại | phương án bị loại trong một spec | 2, 2 trên 6 | 4, 0 trên 6 | 0,75 |
  | đẩy một tag có build image không | bản đồ trạng thái hiện tại | 3, 2 trên 3 | 0, 0 trên 3 | 1,35 |
  | một lỗi chỉ biết qua triệu chứng | một trường hợp thiết kế trong một spec | 4, 4 trên 4 | 4, 0 trên 4 | 1,62 |

  Điểm trên 6 và trên 4 là tổng điểm của hai người review.
- **Sự kiện chỉ ghi trong `kb/` thì được tìm ra; lý do và việc đã loại thì không.** Nguồn gốc của khoản phí và cách
  build image: nhánh có plugin nêu được ở cả bốn lượt, nhánh kia không lượt nào (nó nói repo không có nguồn). Lý do đằng sau
  quy tắc nhân vật rảnh: không lượt nào của nhánh nào nêu, dù nhánh có plugin đã đọc spec chứa nó; khác biệt ở việc đó là nhánh
  có plugin gọi quy tắc là chủ ý thiết kế ở cả hai lượt, nhánh kia ở một lượt. Việc đã loại trước đó: không
  nhánh nào tìm ra. Nhánh có plugin viết một spec đề xuất chính tính năng đã bị loại ở cả hai lượt, và chỉ dừng vì nó hỏi trước;
  nhánh kia có một lần làm luôn mà không hỏi.
- **Với lỗi, nhánh có plugin làm theo thiết kế đã ghi.** Có plugin, cả hai lượt dẫn trường hợp thiết kế và sửa lỗi đúng như
  thiết kế (các test ẩn qua). Không plugin, một lượt sửa lỗi theo cùng cách, từ code; lượt kia coi lỗi là thiết kế và đổi hành vi theo hướng ngược lại (các
  test ẩn trượt).
- **Chi phí: khoảng 1,17× trên các việc này, 3,53× trên hai lỗi sửa một dòng.** Trên năm việc, nhánh có plugin dùng 966.311
  đơn vị chi phí so với 829.118. Trên hai lỗi đối chứng, nơi `kb/` không chứa gì liên quan, cả hai nhánh đều sửa được cả hai,
  và nhánh có plugin tốn gấp 3,53: mỗi lượt viết một intent và một spec rồi xin duyệt trước khi sửa một dòng. Nhánh có plugin
  hỏi người tất cả 6 lần, nhánh kia hai lần.

### Phương pháp

Các nhánh và sandbox như ở trên, khác hai điểm: mỗi lượt là một phiên mới trên bản app riêng của nó, không chuỗi, không lịch
sử; và chi phí của một lượt được tính đến khi phiên tự kết thúc hoặc trần 60 phút. Năm việc là yêu cầu thô, mỗi việc có một điểm chính mà một lần tìm cho thấy không có trong cây của nhánh kia (các tệp công khai của app, theo allowlist của bản xuất); hai việc đối
chứng là lỗi một dòng mà `kb/` không động tới. Hai lượt mỗi nhánh cho mỗi việc `kb/` và một lượt cho mỗi việc đối chứng: 24
phiên, khoảng 11 USD kể cả người review.

Đặt trước mọi lượt chạy: câu trả lời đúng của mỗi việc, các điểm để chấm, các test ẩn, và một câu trả lời soạn sẵn cho mọi câu
hỏi, giống nhau ở cả hai nhánh (với tính năng đã bị loại, đó là quyết định đã ghi).

Cách chấm: một người review Opus 5.5 mới cho mỗi cặp lượt chấm cả hai theo các điểm, từ lời của phiên và thay đổi code của nó,
che mù: từ để lộ nhánh, đường dẫn `kb/` và tên nhánh git được thay đi. Khi hai lượt của một nhánh trên một việc lệch nhau từ 2
điểm trở lên, một người review thứ hai chấm lại cả hai cặp và hai điểm được cộng lại. Lỗi và các việc đối chứng còn được chấm
bằng test ẩn.

### Điều phép đo này chưa cho thấy

- **Mẫu nhỏ.** Hai lượt mỗi nhánh mỗi việc, một app, một model. Hai trong bốn lần thắng (quy tắc nhân vật rảnh và lỗi) mỗi
  lần dựa vào một lượt duy nhất không plugin; nếu một trong hai là hoà, mức đặt ra sẽ không đạt.
- **Việc được chọn.** Một người chọn chúng từ một `kb/` mà họ đã đọc; lần tìm chứng minh câu trả lời không có trong bản xuất
  công khai, không chứng minh các việc như vậy là điển hình.
- **Câu trả lời soạn sẵn thưởng cho việc hỏi.** Một lượt hỏi trước khi làm tính năng đã bị loại sẽ nhận được quyết định đã ghi.
- **Người review có thể sai.** Một điểm tính những gì lời của phiên nói, theo cách một người review đọc. Hai việc được chấm hai
  lần nhận điểm giống hệt nhau từ cả hai người review.
- **Không phải lần thắng nào cũng là câu trả lời trong `kb/`.** Ở quy tắc nhân vật rảnh, khác biệt là một điểm mà nhánh kia
  cũng được chấm ở một lượt, không phải lý do chỉ ghi trong `kb/`; ở việc khoản phí, hai trên ba điểm tìm được mà không cần `kb/`. Không có
  việc loại "một thay đổi phải giữ một quyết định đã ghi": với mọi ứng viên, cây của nhánh kia đã chứa câu trả lời.
- **Che mù chỉ một phần.** Một spec hay một bước xin duyệt trong lời của nhánh có plugin có thể lộ ra, và ở năm trên mười lượt
  được chấm của nhánh có plugin, tên script của plugin hoặc ngày của một spec không được thay đi. Điều này được phát hiện sau khi
  có mọi điểm; nay cả hai đều được thay đi, và mọi lượt review đọc một văn bản còn sót chúng được một người review mới làm lại: không
  điểm nào thay đổi.
- **Thời gian không được dùng.** Thời gian hoạt động lẫn cả thời gian chờ test.
