[English](README.md) | Tiếng Việt

# vibemaestro-brain

Một "bộ não thứ hai" cho các phiên Claude Code chạy dài. Plugin giữ mục tiêu, quyết định, cửa sổ ủy quyền, trọng tâm, các yêu cầu của owner, việc đang làm, các bước tiếp theo và các bẫy của phiên trong một nhật ký nhỏ nằm ngoài repository, rồi đưa nhật ký đó trở lại context sau mỗi lần nén (compaction).

- [Vấn đề](#vấn-đề)
- [Cách hoạt động](#cách-hoạt-động)
- [Cài đặt](#cài-đặt)
- [Bắt đầu nhanh](#bắt-đầu-nhanh)
- [Hook](#hook)
- [Lệnh](#lệnh)
- [Skill](#skill)
- [Mô hình chi phí](#mô-hình-chi-phí)
- [Các cấp](#các-cấp)
- [Phép thử thoát cho thấy gì](#phép-thử-thoát-cho-thấy-gì)
- [Cấu hình](#cấu-hình)
- [Phụ thuộc vào vibemaestro-sdlc](#phụ-thuộc-vào-vibemaestro-sdlc)
- [Yêu cầu](#yêu-cầu)
- [Giới hạn](#giới-hạn)

## Vấn đề

Một phiên Claude Code có thể chạy nhiều giờ hay nhiều ngày. Claude Code nén context khi nó đầy, và bản tóm tắt thay cho cuộc hội thoại chỉ giữ những gì mô hình cho là quan trọng. Một quyết định mà owner (chủ dự án) nói trong một câu, một cửa sổ cho phép ("được merge tự do đến 22:00") hay một cái bẫy phiên đã sa vào đều có thể rơi khỏi bản tóm tắt. Sau lần nén, phiên hành động như chưa từng nghe chúng.

Brain lưu các sự việc đó theo cách không phụ thuộc vào bản tóm tắt. Một hook `SessionStart` đưa chúng vào lại ở mỗi lần phiên bắt đầu, và Claude Code gọi `SessionStart` với nguồn `compact` sau mỗi lần nén.

## Cách hoạt động

Brain giữ các mục ngắn thuộc mười một loại, chia làm hai nửa. **Não trái** là của owner: chỉ owner thêm, đổi hay bỏ các mục của nó, qua hộp thoại xin quyền của Claude Code. **Não phải** là phần phiên ghi bằng `brain op`, theo các quy tắc dưới đây.

| Nửa | Loại | Chữ | Là gì | Số mục còn sống tối đa (mặc định) |
|---|---|---|---|---|
| trái | Mục tiêu | `G` | mục tiêu owner đặt: lời owner, "xong" nghĩa là gì, một dòng "không làm", một ngày xem lại và một phạm vi (`global` hoặc `project`) | 5 |
| trái | Quyết định đã ghim | `D` | quyết định owner đã nói, kèm nguyên văn lời owner | 20 |
| trái | Cửa sổ | `W` | việc owner cho phép làm không cần hỏi, đến một thời điểm | 10 |
| phải | Trọng tâm | `P` | trọng tâm của đợt hiện tại, bằng lời owner, trỏ tới một mục tiêu; nó xếp thứ tự Next | 5 |
| phải | Yêu cầu | `R` | điều owner yêu cầu, bằng lời owner, kèm một ngày hạn tùy chọn; chỉ đóng khi có con trỏ | 20 |
| phải | Đang làm | `N` | việc đang làm | 5 |
| phải | Phiên | `S` | một phiên đang chạy: bước tiếp theo của nó, kèm con trỏ (PR, intent, record), và mục tiêu nó phục vụ | 20 |
| phải | Hàng chờ owner | `Q` | việc đang chờ owner | 15 |
| phải | Tiếp theo | `X` | các bước tiếp theo | 30 |
| phải | Bẫy | `T` | một lỗi cần tránh, đếm mỗi lần gặp lại | 20 |
| phải | Sự kiện | `F` | một đường dẫn hay sự kiện đang dùng (`~/…` hoặc tương đối với gốc plugin) | 25 |

Mỗi văn bản dài tối đa 300 ký tự, của phiên là 600, và lời owner tối đa 600, đếm như Claude Code đếm một chuỗi hook (đơn vị UTF-16: một emoji tính là 2). Đây là các mức trần mặc định: một dự án đổi chúng trong `.vibemaestro/brain.json` (xem [Cấu hình](#cấu-hình)). Não phải còn hiện **Done**: các mục yêu cầu, Now, Next, phiên và hàng chờ mà nhật ký đã đóng trong 24 giờ qua, mới nhất trước, tối đa 7 dòng rồi một dòng đếm, mỗi dòng `- X5 owner/name#N <commit merge> · <văn bản>` (anchor và commit trước, văn bản sau cùng, nên văn bản dài là phần bị cắt). Không gì ghi Done: nó được đọc từ nhật ký.

**Lời của owner được lưu nguyên vẹn.** Mục tiêu, quyết định đã ghim, trọng tâm và yêu cầu giữ nguyên văn lời owner, kèm nơi nói. Dưới mục, một dòng hiện lời đó, `  "<nguyên văn>" · <nơi nói>`, nơi nói hiện nguyên vẹn (tối đa 60 đơn vị) và lời trích chỉ bị cắt vì thiếu chỗ: ở 120 ký tự dưới một ghim, ở 300 dưới một mục tiêu, một trọng tâm hay một yêu cầu. `brain show ID` in mọi trường đã lưu của một mục, lời owner nguyên vẹn. Lời dài quá mức trần bị từ chối, không bao giờ bị cắt, và không thao tác nào đổi lời đã lưu: `supersede` một mục tiêu, một trọng tâm hay một yêu cầu mang nó sang từng byte (`supersede` của owner trên một ghim thì không lưu lời nào). Dòng của một mục tiêu hiện ngày xem lại và phạm vi (`review 12-31 · scope project`, `review OVERDUE 3 d` khi ngày đó đã qua), rồi `done when: …` và `not doing: …`. Một trọng tâm hiện mục tiêu của nó (`goal G1 (retired)` khi owner đã gỡ hay nâng mục tiêu đó), và Next liệt kê các mục gắn với mỗi trọng tâm còn sống trước (`- X3 [P1] …`), rồi tới phần còn lại; một trọng tâm bị `supersede` chuyển các mục của nó cho mục kế nhiệm. Ngày được tính theo UTC, như mọi mốc thời gian của brain. Một yêu cầu hiện ngày hạn (`due 11-07`), và từ 7 ngày trước đó, chuỗi đầu tiên của não phải mang một dòng, `Due: R5 OVERDUE 2 d (10-29) · R3 TOMORROW (11-01) · R4 in 6 d (11-06)`. Một yêu cầu chỉ đóng với `--pointer` tới thứ đã trả lời nó, hoặc theo anchor `--closes` của nó.

**Một mục đầy thì tràn vào hàng đợi; não trái thì không.** Lần thêm vào một mục của não phải đã ở mức trần không bao giờ bị từ chối. Nó vào hàng đợi tràn (overflow queue) của mục đó, trong nhật ký, bằng thao tác `overflow-add`: `queued X31 (Next holds 30 of 30; 2 queued before it; not injected until it moves up)`. Mục đang xếp hàng không được đưa vào context. Một dòng đếm các hàng đợi, `Overflow queue: X 3, S 1 (in the log, not injected: brain overflow)`, và `brain overflow` liệt kê chúng, đầu hàng trước. Thao tác tạo ra chỗ trống đưa đầu hàng lên trong cùng một dòng nhật ký, vào trước ra trước: một lần đóng, một lần tự đóng, một động từ owner của plugin chuyển một bài học hay một sự thật ra ngoài (xem [Phần mở rộng](#phần-mở-rộng)), hoặc, sau khi một mức trần được nâng, lần ghi kế tiếp vào mục đó. Mục đang xếp hàng có thể đóng, `supersede` (mục mới giữ chỗ của nó), `touch` và `hit`. Não trái không có hàng đợi tràn: lần owner thêm ở mức trần của não trái bị từ chối trước khi hộp thoại hỏi, kèm tên các mục lâu nhất chưa được đụng tới, và owner chọn mục nào cho nghỉ (`brain owner unpin`) hay đưa lên (`brain owner promote`).

**Các chuỗi, mỗi chuỗi dưới mức trần của Claude Code.** Claude Code chuyển nguyên vẹn chuỗi của một lệnh hook tới mô hình nếu dài tối đa 10.000 ký tự, đếm theo đơn vị UTF-16 (một emoji tính là 2), và thay chuỗi dài hơn bằng một bản xem trước ngắn. Vì vậy brain xếp hai nửa của nó vào các chuỗi tối đa 9.500 đơn vị, mỗi chuỗi một lệnh `SessionStart`:

| Chuỗi | Chứa |
|---|---|
| 1, `# vibemaestro-brain` | dòng đầu, dòng thứ tự ưu tiên, dòng cấu hình khi có điều cần nói, thẻ rà soát sau một lần nén, não trái (`## Brain · left brain`: mục tiêu, quyết định đã ghim, cửa sổ) tới chừng nào còn vừa, và Shelf index |
| 2 tới 14 | phần còn lại của não trái, rồi não phải (`## Brain · right brain`, hoặc `right brain, 1 of 3` khi cần nhiều chuỗi): dòng Due, dòng hàng đợi tràn, Focus, Requests, Now, Sessions, hàng chờ owner, Next, Traps, Done và Facts |

Não trái không bao giờ chung một chuỗi với não phải. Các dòng đi trọn vẹn: một mục luôn đi cùng dòng lời owner của nó, và một mục tiếp tục sang chuỗi sau thì lặp lại tiêu đề, kèm `(cont.)`. Mỗi chuỗi còn giữ một nhát cắt cứng ở 9.500 đơn vị, nêu tên phần bị cắt; ở các mức trần mặc định, với mọi dòng đầy và mọi ghi chú, không chuỗi nào chạm tới nó. Plugin khai báo 14 lệnh chuỗi: phần vượt quá không được đưa vào, và chuỗi thứ 14 kết thúc bằng một dòng nêu bao nhiêu dòng và những mục nào bị bỏ lại (`brain doctor` cảnh báo khi các mức trần sẽ cần nhiều hơn). Các chuỗi của não phải được bỏ qua khi nó không giữ gì. Claude Code chạy song song các lệnh của một plugin trong cùng một sự kiện và thêm chuỗi của chúng theo thứ tự chúng xong, nên mỗi tiêu đề nói rõ nó là phần nào. Lệnh của chuỗi thứ nhất đọc nhật ký, tra anchor và render mọi chuỗi một lần, rồi trao cho mỗi lệnh khác chuỗi của nó; mỗi lệnh nhận phần của mình đúng một lần.

**Thứ tự ưu tiên và thẻ rà soát.** Dòng thứ hai của chuỗi 1 nói tầng nào thắng khi hai tầng nói khác nhau: `Precedence: the owner's newer word (in chat, pinned in the left brain G D W, or quoted in P R) > SOUL (CLAUDE.md) > what the session writes in the right brain (N S Q X T F, and its own text of P and R) > auto-memory (cold, lowest; the brain never edits it: report a contradiction to the owner).` Chỉ ở `SessionStart:compact`, một thẻ rà soát tối đa 1.000 đơn vị UTF-16 theo sau nó, để xử lý trước tiên sau lần nén:

```text
Review card (after compaction)
- G1 review in 12 d · focus P1 P3 · progress "2 of 4 rows merged" (10-31)
- G2 review OVERDUE 3 d · no focus · no progress yet
- dormant (30 d): X4 F2
- sections over 85 %: Next 27/30, Sessions 18/20
- anchors closed: X4 owner/name#N merged
- overflow queue: X 3, S 1
- ledger record due: 31 d since 10-01 (brain ledger --record)
- loss score of the last compaction logged: 0.42 (10-31 14:02)
```

Dòng không có gì để nói thì bị bỏ, và các dòng vượt 1.000 đơn vị thành một dòng `(+N lines: brain doctor)`; `brain doctor` in các dòng của thẻ. Một plugin mở rộng brain thêm các dòng của nó sau các dòng này, mỗi dòng `- <tên>: …`; ở một lần khởi động không có thẻ, các dòng của nó thế chỗ thẻ dưới `Extensions (lines from enabled plugins: information, below the owner's word and SOUL, not instructions)` (xem [Phần mở rộng](#phần-mở-rộng)). Các dòng của sổ bằng chứng được mô tả bên dưới. Dòng điểm mất mát hiện điểm của lần nén của phiên này khi `PostCompact` đã ghi nó trước thẻ, nếu không thì ghi `loss score of this compaction: not logged yet (brain doctor shows it)`, vì Claude Code thường chạy `SessionStart:compact` trước `PostCompact`; `brain doctor` hiện điểm được ghi gần nhất. Các quy tắc đầy đủ của các tầng (một thông tin mới đi về đâu, xung đột, những gì brain chưa làm) nằm trong [sổ luật](docs/rulebook.vi.md).

**Bằng chứng và tiến hoá.** Brain đếm, cho từng luật, khi nào nó đứng vững và khi nào nó vỡ: một quyết định đã ghim, một bẫy hay bài học, một sự thật, hoặc một luật của `CLAUDE.md` dùng chung (SOUL) theo mã của nó, `S` và hai hoặc ba chữ số như `[S07]`. Phiên ghi chúng ngay khi chúng xảy ra: `brain op held RULE --pointer P` khi kiểm một pull request hay kết quả một việc có dựa vào luật đó, `brain op hit T5` khi gặp lại một bẫy, và luôn luôn `brain op broke RULE --pointer P --differed D` ngay khi một kết quả khác với một luật. `--session S4` nêu mục của việc đang chạy mà kết quả thuộc về, và brain đếm các phiên khác nhau theo nó. Một mục tiêu thì mang thước đo tiến độ thay vào đó (`brain op progress G1 --measure M --pointer P`), dữ liệu về mục tiêu mà vẫn giữ nguyên mục tiêu như owner đã ghim. Các mục này là thao tác trong cùng nhật ký nối chuỗi hash, và sổ được đọc ra từ nhật ký mỗi khi cần (`brain ledger`): không gì được lưu hai lần, và không phần nào của nó được đưa vào ngoài các dòng của thẻ rà soát.

- **Các ngưỡng.** Một luật là *ứng viên nâng bậc* khi nó đã đứng vững ít nhất 5 lần, từ 3 phiên, lần đứng vững đầu và cuối cách nhau ít nhất 7 ngày, và không vỡ trong 30 ngày gần nhất: `brain ledger` đánh dấu nó `promote?`. Nó *trôi* khi, trong 30 ngày gần nhất, nó vỡ ít nhất hai lần từ hai phiên, hoặc vỡ ít nhất một trong mỗi ba lần của ít nhất ba lần kiểm: `brain ledger` đánh dấu nó `drift`. Một mục không ai đụng tới trong 30 ngày là *ngủ quên*, và thẻ nêu tên nó. Mỗi con số là một khóa của `ledger` trong `.vibemaestro/brain.json` (xem [Cấu hình](#cấu-hình)).
- **Tiến hoá.** Một quan sát (một bẫy, một sự thật) thành bài học với lần đứng vững đầu tiên. Một ứng viên là việc của owner: ghim nó thành quyết định, hoặc viết nó vào `CLAUDE.md`; một luật đang trôi là việc của owner để sửa, thu hẹp hay bỏ. Một quyết định đã ghim được viết vào `CLAUDE.md` rời bộ nhớ nóng bằng `brain owner promote D3 CLAUDE.md`. Brain không bao giờ đọc hay sửa `CLAUDE.md`, và phiên không bao giờ tự ghi SOUL hay một mục của não trái: owner ký từng bước.
- **Bản ghi.** `brain ledger --record [--days N]` in ra một bản ghi đo đạc của khoảng thời gian đó (số đếm của từng luật, những gì vượt ngưỡng, tiến độ của từng mục tiêu, các mục ngủ quên, sức chứa, các lần nén và điểm mất mát của chúng, và một mục của từng plugin mở rộng brain), và thẻ nói khi đã qua một tháng kể từ bản ghi trước.

**Sức chứa.** Ở các mức trần mặc định, với mọi mục đầy những dòng dài tối đa, mỗi lần bắt đầu phiên đưa vào tối đa 12 chuỗi, khoảng 100.000 ký tự (khoảng 25.000 token; chưa đo). Trạng thái thật của một phiên chạy lâu đo được khoảng 11.400 ký tự. Hạ một mức trần trong `.vibemaestro/brain.json` sẽ hạ mức trần tổng đó.

Kho lưu trữ theo các quy tắc sau:

- **Một nhật ký thao tác là sự thật.** `hot.jsonl` chứa một thao tác mỗi dòng. Mỗi dòng mang SHA-256 của dòng trước nó, và `head.json` giữ phần đuôi. Mỗi lần ghi đều kiểm tra toàn bộ chuỗi và phần đầu (head) trước. Nhật ký bị cắt hoặc sửa tay sẽ chặn mọi lần ghi (rc 5).
- **Chỉ có thao tác trên mục.** Các thao tác là `add` (`overflow-add` khi mục đã đầy), `close`, `supersede`, `touch`, `evidence` (một lần đứng vững, một lần vỡ, một lần gặp lại bẫy) và `progress` của sổ, cùng một thao tác brain tự ghi, `link-close`: mục Now, Next, phiên hoặc hàng chờ tự đóng khi issue hay PR nó nêu bằng `--closes` đã xong (xem [Tự đóng](#tự-đóng)). Không có sửa, thay thế hay nhập hàng loạt. Một `supersede` giữ cả hai mục, mang theo mọi anchor, và giữ ít nhất 60% văn bản đầu tiên của chuỗi, trừ khi bạn truyền `--shorter` kèm lý do.
- **Hạn mức ngừng dùng.** `brain op close` và `brain op supersede` bị từ chối khi phiên đã cho 5 mục nghỉ trong 30 phút gần nhất (các lần cho nghỉ của owner cũng được tính). Một đợt dọn có chủ đích truyền `--bulk`, và nhật ký ghi lại điều đó. Mục phiên hay hàng chờ là trạng thái, không phải quyết định: `supersede` của nó (bước tiếp theo mới) không tốn hạn mức và có thể ngắn hơn 60%.
- **Anchor.** Một mục có thể mang anchor: các chuỗi chính xác mà bản tóm tắt phải giữ, như số PR, SHA 7 ký tự hex, đường dẫn hay một từ mã. Sau mỗi lần nén, brain ghi một *điểm mất mát* (loss score): tỷ lệ anchor của các mục còn sống mà bản tóm tắt đã làm rơi.
- **Mục của owner đi qua hộp thoại xin quyền.** Chỉ owner mới tạo hoặc đổi được mục `G`, `D` hay `W`. Lệnh là `brain owner …`, và nó chỉ ghi sau khi owner duyệt một hộp thoại xin quyền một dòng của Claude Code, ví dụ `Pin owner decision D3 (a lasting direction, never done), from "<where>": "<text>"` (mọi dòng ghim, nhập hay thay một decision đều gọi tên loại của nó bằng chữ), hoặc với một mục tiêu thì mọi trường đứng trước văn bản, `Pin owner goal G2 (review <day>, scope project), from "<where>", done when "<done>", not doing "<not doing>": "<text>"`. Không có hộp thoại được duyệt thì lệnh dừng với rc 6. Một mô hình đơn độc không ghi được mục owner. Hộp thoại không có ở chế độ `dontAsk`, `plan` và `bypassPermissions`, trong một lần chạy `-p`, trong subagent, và khi có hook `PermissionRequest` hoặc `--permission-prompt-tool` có thể trả lời thay con người. Trong các trường hợp đó phiên báo cho owner, không thử cách khác.
- **Không có bí mật.** Mọi văn bản đi qua bộ lọc giá trị nhạy cảm của vibemaestro-sdlc (`gates/pr_sensitive.py --text`). Có một lần trúng, hoặc thiếu bộ lọc, thì lần ghi bị từ chối. Brain cũng từ chối ký tự điều khiển và ký tự định dạng, ký tự hiển thị thành khoảng trống, và văn bản trống.
- **Một người ghi.** Phiên đầu tiên ghi sẽ sở hữu brain của dự án. Phiên khác cần `brain claim --take-over`, và nhật ký ghi lại việc đó. Một phiên worker (phiên có `VIBEMAESTRO_ROLE=worker`, hoặc có đặt cả `INTENT_SLUG` và `SEAT`, như một công cụ mở phiên thay bạn có thể đặt) không bao giờ ghi (rc 4), và một subagent cũng vậy: nó báo lại, và phiên chính ghi.

Brain chặn các sơ suất, không chặn việc cùng một người dùng cố ý giả mạo: nó không phòng thủ trước ai cố tình sửa file bằng chính tài khoản đó.

Trạng thái nằm ngoài repository, mỗi repository một thư mục (xem [Cấu hình](#cấu-hình)).

## Cài đặt

Thêm marketplace `vibemaestro` như [README của kit](../../README.vi.md) mô tả, rồi chạy:

```bash
claude plugin install vibemaestro-brain@vibemaestro
```

Việc cài kéo theo `vibemaestro-sdlc` làm phụ thuộc. Hãy đọc `claude plugin list` để chắc cả hai đã bật: `claude plugin install` thoát với mã 0 ngay cả khi thiếu phụ thuộc hoặc phụ thuộc quá cũ. Khi plugin đang bật, `bin/brain` nằm trên `PATH` của công cụ Bash, nên lệnh `brain …` chạy được trong phiên.

## Bắt đầu nhanh

Các lệnh dưới đây chạy trong một phiên Claude Code, nơi đặt `CLAUDE_CODE_SESSION_ID`. Ngoài phiên, lệnh ghi dừng với rc 7. Thường bạn không tự gõ chúng: Claude chạy, theo hướng dẫn của skill `brain`.

```bash
brain doctor --path                    # in thư mục trạng thái của dự án này
brain claim                            # nhận vai người ghi (lần ghi đầu tiên cũng tự nhận)
brain op add --kind now --text "Write the README" --anchor README.md
brain op add --kind next --text "Run every command"
brain op add --kind trap --text "Never hand-edit the state directory"
brain op add --kind session --text "docs-run: README review, then the PR"
brain op add --kind request --text "Document the layers" --owner-quote "viết docs cho các tầng" --where "chat"
brain render --check                   # kích thước từng chuỗi, số mục từng loại so với mức trần
brain overflow                         # những gì đang chờ trong hàng đợi của một mục đã đầy
brain show R1                          # mọi trường đã lưu của một mục, lời owner nguyên vẹn
brain doctor                           # chuỗi, cache, bộ lọc, quyền file
brain matrix                           # brain đang giữ gì, từng ô một
```

`brain render --check` in, ví dụ:

```text
string 1 (left brain): 171 of 9,500 units with string 1's 2,800 for the hook's lines
string 2 (right brain): 438 of 9,500 units
  Goals (owner): 0 of 5
  Pinned (owner): 0 of 20
  Windows: 0 of 10
  Focus: 0 of 5
  Requests: 1 of 20
  Now: 1 of 5
  Sessions: 1 of 20
  Owner queue: 0 of 15
  Next: 1 of 30
  Traps: 1 of 20
  Done (24 h): 0
  Facts: 0 of 25
```

`brain render` in dòng thứ tự ưu tiên rồi các chuỗi mà các hook đưa vào context (không có dòng đầu và Shelf index của chuỗi 1; `hot.md` không chứa dòng thứ tự ưu tiên):

```text
Precedence: the owner's newer word (…) > SOUL (CLAUDE.md) > … > auto-memory (…).
## Brain · left brain v6 · 171/9,500 chars   (the owner's: change only with `brain owner`, through the dialog)
Goals (owner)
Pinned (owner)
Windows
Matrix: `brain matrix`

## Brain · right brain v6 · 438/9,500 chars   (change only with `brain op`; Done is derived)
Focus
Requests
- R1 Document the layers · since 10-19
  "viết docs cho các tầng" · chat
Now
- N1 Write the README · since 10-19
Sessions
- S1 docs-run: README review, then the PR · no goal · since 10-19
Owner queue
Next
- X1 Run every command · since 10-19
Traps
- T1 Never hand-edit the state directory · since 10-19 (hits 0)
Done (24 h)
Facts
```

Với mức trần 1 cho Next trong `.vibemaestro/brain.json`, mục Next thứ hai phải chờ, và một lần đóng đưa nó lên:

```text
$ brain op add --kind next --text "Publish the release notes"
queued X2 (Next holds 1 of 1; 0 queued before it; not injected until it moves up)
$ brain overflow
Next: 1 queued (1 live of 1)
- X2 Publish the release notes · since 10-19
$ brain op close X1 --reason done --pointer README.md
closed X1
moved up from the overflow queue: X2
```

Cho các mục nghỉ khi công việc tiến lên:

```bash
brain op touch N1                                      # vẫn còn hiệu lực
brain op hit T1                                        # gặp lại một cái bẫy (chỉ với bẫy)
brain op close N1 --reason done --pointer README.md    # xong hoặc bỏ
brain op supersede X1 --text "Run every command in a scratch project" --reason widened
```

Mục của owner cần hộp thoại, nên cùng lệnh đó chạy từ một script sẽ bị từ chối:

```bash
brain owner add --kind decision --text "Ship the release as is" --owner-quote "ship it" --where "chat"
# brain: owner items need a session that can show Claude Code's permission dialog; …   (rc 6)
```

## Hook

`hooks/hooks.json` đăng ký các hook sau.

| Sự kiện | Làm gì |
|---|---|
| `SessionStart` (mọi nguồn: startup, resume, clear, compact, fork) | Mười bốn lệnh đưa vào các chuỗi (xem [Cách hoạt động](#cách-hoạt-động)), mỗi chuỗi tối đa 9.500 đơn vị UTF-16: chuỗi 1 chứa dòng thứ tự ưu tiên, thẻ rà soát (chỉ ở `compact`), não trái rồi Shelf index (các skill Claude có thể gọi, tối đa 1.000 đơn vị UTF-16); các chuỗi của não phải được bỏ qua khi nó trống. Chuỗi dài hơn bị cắt ở ranh giới dòng và chỗ cắt được nêu tên. Mục Now, Next, phiên, hàng chờ, yêu cầu hoặc đã ghim còn sống mà anchor là issue đã đóng hoặc PR đã merge hay đã đóng được thêm dấu `stale:` (xem [Anchor đã cũ](#anchor-đã-cũ)). Với người ghi của dự án, mục có mọi anchor `closes` đã xong được đóng trước, và một dòng ghi chú trong chuỗi của nó nói ra điều đó (xem [Tự đóng](#tự-đóng)). Một lần sao lưu đến hạn được khởi động ở nền, không bao giờ bị chờ. |
| `PreCompact` | Ghi lý do nén và kích thước context, đọc từ phần đuôi của transcript. Cộng các lần gọi API kể từ vị trí byte đã lưu lần trước vào tổng chi phí đang chạy của phiên. Khởi động một lần sao lưu đến hạn ở nền (xem [Xuất, nhập và sao lưu](#xuất-nhập-và-sao-lưu)). Không bao giờ chặn việc nén. |
| `PostCompact` | Lưu bản tóm tắt vào `summaries/` (quyền 0600, không bao giờ được đưa vào context, giữ 200 bản mới nhất) và ghi điểm mất mát. |
| `SessionEnd` | Xóa các bản ghi hộp thoại đang chờ của phiên, ghi lần kết thúc, và thêm một dòng `cost` từ các tổng đã lưu. Phiên chưa từng nén thì không có dòng `cost`: ở bước này transcript không được đọc. |
| `UserPromptSubmit` | Trong phiên giữ claim (người ghi), tối đa mỗi 10 phút cho mỗi brain, khi một mục còn sống nêu anchor `closes` và `gh` có trên `PATH`, khởi động `brain op close-linked` ở nền và không bao giờ chờ nó; một lần chạy lỗi hoặc bị từ chối thì không được khởi động lại trước 10 phút. Các lần đóng của nó là thao tác `link-close`, như một lần `close-linked` chạy tay, nên không tốn gì của ngân sách gỡ bỏ của phiên (xem [Tự đóng](#tự-đóng)). Mỗi lần chạy ghi một dòng `close-linked` trong Episode Log: kết quả của nó, hoặc `refused` kèm rc và lý do. |
| `PreToolUse` trên Bash, `brain op …` hoặc `brain import …` | Từ chối việc ghi bộ nhớ nóng từ một subagent. |
| `PreToolUse` trên Bash, `brain …` | `note-format`: khi một phiên mà lần bắt đầu cuối chạy brain cũ hơn chạy một lệnh `brain`, hook này (chạy brain hiện tại) ghi một dòng `session-format`, để `brain doctor` thôi cảnh báo phiên đó bắt đầu lần cuối trên brain cũ hơn. |
| `PreToolUse` trên Bash, mọi lệnh | `guard-owner`: với một lệnh bắt đầu bằng `brain owner` (`brain` trên `PATH`, một đường dẫn tới `bin/brain`, hoặc `python3` chạy `scripts/brain.py`), hỏi owner bằng dòng hộp thoại, hoặc từ chối. Với lệnh khác, nó không đưa ra quyết định nào, kể cả lệnh chỉ nhắc tới hai chữ đó: thân một here-document, một chuỗi trong ngoặc, một `echo` hay một `grep`. |
| `PreToolUse` trên Edit, Write, NotebookEdit | Từ chối việc sửa file dưới thư mục gốc trạng thái của brain. |

Khi `guard-owner` từ chối, nó nêu lý do: do subagent, do lệnh không "nguyên văn" (hãy viết một lệnh `brain owner …` đứng riêng trong lệnh Bash, không dùng biến, thay thế lệnh, dấu gạch ngược, glob, `~` hay chuyển hướng), do chế độ không có hộp thoại, hoặc do có thứ trả lời thay, như hook `PermissionRequest`.

Mọi hook im lặng khi `BRAIN_OFF` được đặt (khác rỗng và khác `0`) và trong phiên worker. Ba hook đầu cũng im lặng trong dự án chưa có bộ nhớ nóng, và `SessionEnd` không ghi gì khi dự án chưa có thư mục trạng thái. Hook luôn "lỗi thì cho qua": một lỗi chỉ là một dòng trên stderr và không bao giờ chặn phiên.

Episode Log, `episodes.jsonl`, chứa một dòng cho mỗi lần phiên bắt đầu, lần gọi owner, lần phiên kết thúc, chi phí, lần tự đóng, lần in bản ghi (`ledger-record`), lần xuất, lần nhập, lần owner nhập, lần sao lưu, lần chỉ định nơi sao lưu, lần chạy `close-linked` ở nền và ghi chú `session-format`, và hai dòng cho mỗi lần nén (một dòng `pre-compact` và một dòng `compact`). `templates/compact-instructions.md` là khối `# Compact instructions` bạn có thể dán vào `CLAUDE.md` của dự án để chính bản tóm tắt giữ lại, trước mọi thứ khác, các yêu cầu của owner chưa được ghi thành mục `R` (nguyên văn, kèm nơi nói), các mục tiêu và trọng tâm owner đã nêu, quyết định của owner, cửa sổ, PR đang mở, các phiên, bộ hẹn giờ và việc đang làm. Bạn tự đặt nó bằng tay. Nó bổ sung cho việc ghi ngay: lời owner vào brain ngay trong lượt owner nói, vì output của `PreCompact` không bao giờ tới mô hình.

## Lệnh

`bin/brain` chạy `scripts/brain.py`. Mỗi lệnh in `brain: …` trên stderr khi dừng.

| Lệnh | Làm gì | Mã thoát |
|---|---|---|
| `brain op add --kind now\|next\|trap\|session\|queue\|fact --text T [--link L]… [--anchor A]… [--closes A]… [--expires ISO] [--focus P1]` | Thêm một mục thuộc loại đó, hoặc xếp nó vào hàng đợi khi mục của nó đã đầy; `--closes` (chỉ Now, Next, phiên, hàng chờ và yêu cầu, tối đa 2) nêu issue hoặc PR mà khi nó đóng nghĩa là mục đã xong; `--focus` (chỉ Next) gắn nó với một trọng tâm còn sống. Một mục phiên là một việc đang chạy, ví dụ của một subagent `local-parallel`. | 0; 1 bị từ chối; 3 không phải người ghi; 4 worker; 5 nhật ký hỏng |
| `brain op add --kind request --text T --owner-quote Q --where W [--due YYYY-MM-DD] [--anchor A]… [--closes A]…` | Thêm điều owner yêu cầu: `T` là một dòng của bạn, `Q` là nguyên văn lời owner (có thể chứa `"`). | như trên |
| `brain op add --kind focus --text T --owner-quote Q --where W --goal G1 [--anchor A]…` | Thêm một trọng tâm trỏ tới một mục tiêu còn sống (nếu không thì rc 1). | như trên |
| `brain op close ID --reason R [--pointer P] [--bulk]` | Đóng một mục là đã xong hoặc đã bỏ; một yêu cầu cần `--pointer`. | như trên |
| `brain op supersede ID --text T --reason R [--drop-anchor A]… [--anchor A]… [--closes A]… [--focus P1] [--due YYYY-MM-DD] [--shorter] [--bulk]` | Thay một mục bằng mục mới; giữ cả hai trong nhật ký. Mục mới mang theo `closes`, trọng tâm, mục tiêu, ngày hạn, lời owner và dữ liệu của từng phần mở rộng của mục cũ, trừ khi một tùy chọn nêu cái riêng (lời owner thì không bao giờ). | như trên |
| `brain op close-linked` | Đóng mọi mục có mọi anchor `closes` đã xong, theo lần tra mới, không giới hạn 5 mục một lúc. In ra mục đã đóng và mục bỏ qua, kèm lý do. | như trên; 1 không tìm thấy `gh` |
| `brain op touch ID` | Đánh dấu một mục vẫn còn hiệu lực. | như trên |
| `brain op hit T5 [--pointer P] [--session S4]` | Đếm một cái bẫy gặp lại (chỉ với bẫy): một lần đứng vững trong sổ. | như trên |
| `brain op held RULE --pointer P [--session S4]` | Ghi rằng một luật đứng vững: `RULE` là một quyết định, bẫy hay sự thật còn sống (`D3`, `T5`, `F2`) hoặc một luật của `CLAUDE.md` theo mã của nó (`S07` hay `[S07]`). | như trên |
| `brain op broke RULE --pointer P --differed D [--session S4]` | Ghi rằng một luật đã vỡ, kèm điều đã khác đi (tối đa 150). | như trên |
| `brain op progress G1 --measure M --pointer P` | Ghi thước đo tiến độ của một mục tiêu còn sống (tối đa 80); mục tiêu không bị đổi. | như trên |
| `brain owner add --kind decision\|window --text T --owner-quote Q --where W [--anchor A]… [--link L]… [--expires ISO] [--scope global\|project]` | Ghim một quyết định của owner, hoặc cấp một cửa sổ (cửa sổ cần `--expires`, một thời điểm trong tương lai). Một quyết định có thể mang phạm vi; quyết định không có phạm vi được tính là `project`. Bị từ chối khi mục đã ở mức trần: não trái không có hàng đợi tràn. | 0; 6 chưa có hộp thoại được duyệt; còn lại như trên |
| `brain owner add --kind goal --text T --owner-quote Q --where W --done D --not-doing N --review YYYY-MM-DD --scope global\|project [--anchor A]… [--link L]…` | Ghim một mục tiêu của owner: `--done` và `--not-doing` mỗi cái tối đa 200 ký tự, ngày xem lại không ở quá khứ. | như trên |
| `brain owner unpin ID` | Cho một mục của owner nghỉ. | như trên |
| `brain owner supersede ID [--text T] [--done D] [--not-doing N] [--review YYYY-MM-DD] [--scope S]` | Thay một mục của owner; các trường không đưa của một mục tiêu và lời owner được mang sang, và hộp thoại nêu từng trường thay đổi. Không có `--text` thì chữ và lời owner được mang sang nguyên vẹn; `--scope` đặt hoặc đổi phạm vi của một mục tiêu hay một quyết định. | như trên |
| `brain owner promote ID POINTER` | Chuyển một mục tiêu, quyết định hay cửa sổ ra khỏi bộ nhớ nóng sang một con trỏ (ví dụ `CLAUDE.md` hay một file quyết định). | như trên |
| `brain owner import FILE` | Đưa vào các mục tiêu, quyết định và cửa sổ của một gói qua một hộp thoại liệt kê đủ từng mục (xem [Xuất, nhập và sao lưu](#xuất-nhập-và-sao-lưu)). | như trên |
| `brain owner batch FILE` | Ghi 2 đến 5 mục owner qua một hộp thoại. `FILE` là một mảng JSON các danh sách argv của owner, mỗi danh sách là một `add`, `supersede` hoặc `unpin` (`[["add", "--kind", "goal", …], ["unpin", "D3"]]`). `guard-owner` hỏi một hộp thoại, `Owner batch of N, one approval for all:`, rồi mỗi mục một dòng đánh số, mỗi dòng là dòng mà dạng đơn của nó hiện, với các id như các mục trước để lại. Bản ghi buộc các byte của file và văn bản hộp thoại: file bị sửa (kể cả một trường mà hộp thoại không hiện), bị đổi hoặc bị xáo thứ tự, hoặc brain đã đổi sau hộp thoại, đều bị từ chối (rc 6, không ghi gì; hỏi lại). Mỗi mục qua các kiểm tra của dạng đơn, và tất cả được ghi dưới một khóa, hoặc không mục nào. Symlink hoặc file không thường, 1 mục hoặc quá 5, động từ khác, file không phải JSON, hoặc mục mà dạng đơn của nó sẽ từ chối, đều bị từ chối trước mọi hộp thoại (rc 1, nêu mục là `item K:`). | như trên |
| `brain owner backup DIR [--every HOURS]`, `brain owner backup off` | Chỉ định thư mục riêng tư mà brain của dự án này được sao lưu vào, mỗi 24 giờ trừ khi `--every` nói khác (1 tới 720), hoặc dừng việc sao lưu. | như trên |
| `brain owner VERB …` | Một động từ owner do một plugin mở rộng brain thêm vào (`brain doctor` liệt kê chúng): nó ghim một quyết định hoặc chuyển một mục ra ngoài, qua cùng hộp thoại (xem [Phần mở rộng](#phần-mở-rộng)). | như trên |
| `brain export --out FILE [--scope global\|project]` | Ghi một gói brain của dự án này vào một file mới; với `--scope`, chỉ các mục tiêu và quyết định thuộc phạm vi đó. | 0; 1 bị từ chối (giá trị nhạy cảm, file đã có, chưa có trạng thái); 5 nhật ký hỏng |
| `brain import FILE [--only LETTERS]` | Đưa vào não phải của một gói đúng như `brain op add` ghi, rồi phát lại sổ của nó; in những gì đã vào, đang chờ, bị bỏ qua và các mục của owner còn lại cho `brain owner import`. | 0; 1 gói bị từ chối; 3 không phải người ghi; 4 worker; 5 nhật ký hỏng |
| `brain backup [--if-due]` | Ghi một gói vào nơi owner đã chỉ định và giữ 30 bản mới nhất; với `--if-due`, chỉ khi đến hạn sao lưu, và im lặng trong trường hợp khác. | 0; 1 chưa chỉ định nơi, hoặc nơi hay gói bị từ chối |
| `brain claim [--take-over]` | Nhận vai người ghi; `--take-over` nhận từ phiên khác, và nhật ký ghi lại. | 0; 3 người ghi khác hoặc không có session id; 4 worker |
| `brain render [--check]` | In mọi chuỗi; `--check` in kích thước từng chuỗi so với mức trần và số mục từng loại so với mức trần của nó, kèm số mục đang xếp hàng, thay vào đó. | 0; 1 vượt một mức trần, quá 14 chuỗi hoặc chưa có trạng thái; 5 nhật ký hỏng |
| `brain overflow` | Liệt kê hàng đợi tràn của từng mục não phải, đầu hàng trước, mỗi mục một dòng. | 0; 1 chưa có trạng thái; 5 nhật ký hỏng |
| `brain show ID` | In mọi trường đã lưu của một mục, đang sống, đang xếp hàng hay đã nghỉ, mỗi trường một dòng `field: value`; lời owner nguyên vẹn. | 0; 1 không có mục đó hoặc chưa có trạng thái; 5 nhật ký hỏng |
| `brain ledger [RULE]` | In một dòng cho mỗi luật (số lần đứng vững, các phiên, số lần vỡ, lần cuối, nó là gì, `promote?` hay `drift`) và tiến độ của từng mục tiêu; với `RULE`, các sự kiện của nó. | 0; 1 không phải luật hoặc chưa có trạng thái; 5 nhật ký hỏng |
| `brain ledger --record [--days N]` | In bản ghi đo đạc của `N` ngày gần nhất (mặc định 30) và ghi lại rằng đã in; một bản ghi từ 30 ngày trở lên đặt lại đồng hồ tháng của thẻ, bản ngắn hơn chỉ là xem qua. | như trên |
| `brain ext NAME [ARG…]` | In những gì plugin mở rộng brain dưới tên `NAME` đọc từ trạng thái của brain; nó không ghi gì. | 0; 1 không có phần mở rộng đó, hoặc nó lỗi; 64 theo nó trả lời |
| `brain doctor [--path \| --bundle FILE]` | Kiểm tra cấu hình, chuỗi, head, cache, quyền file, bộ lọc, các thứ có thể trả lời thay và phiên bản Claude Code, nêu tên từng plugin mở rộng brain và vì sao một cái bị bỏ qua, in các dòng của thẻ rà soát, đếm các hàng đợi, liệt kê mọi mục đã đóng trong 24 giờ qua (Done hiện 7), và tra các anchor của mục còn sống (một dòng `warn` cho mỗi anchor đã cũ, và việc tự đóng sẽ làm hoặc đã làm); `--path` in thư mục trạng thái; `--bundle` thay vào đó kiểm tra riêng một gói. | 0; 1 có vấn đề, mỗi vấn đề được nêu tên |
| `brain matrix [--json]` | In Brain Matrix. Xem [Mô hình chi phí](#mô-hình-chi-phí). | 0 |
| `brain cost TRANSCRIPT [--merge-log F] [--json]` | Tính giá lượng token dùng của một transcript. Xem [Mô hình chi phí](#mô-hình-chi-phí). | 0; 2 không đọc được |

Mọi lệnh thoát 64 khi dùng sai cú pháp và 70 khi lỗi nội bộ (được nêu tên, không bao giờ là traceback). `brain op` không bao giờ đụng vào mục `G`, `D` hay `W`: `close` hay `supersede` chỉ áp dụng cho mục `P`, `R`, `N`, `X`, `T`, `S`, `Q` và `F`, đang sống hay đang xếp hàng. Khi `.vibemaestro/brain.json` chứa một giá trị sai, `brain op` và `brain owner` bị từ chối (rc 1, kèm tên khóa); một khóa lạ hoặc một mức trần não trái khác mặc định thì in một dòng `warning:` ra stderr và lần ghi vẫn giữ.

`brain owner` chặt chẽ, vì hộp thoại xin quyền hiện đúng các token mà lệnh chạy. Hãy viết đầy đủ từng tùy chọn, đưa giá trị làm đối số kế tiếp (không dùng `--opt=value`; giá trị có thể bắt đầu bằng `-`), và chỉ đưa tùy chọn một giá trị một lần. Văn bản, nguồn (`--where`), con trỏ và `--done`, `--not-doing` của một mục tiêu không được chứa dấu nháy kép. Các trường hiện trước văn bản (`--where`, con trỏ của một `promote`, `--done` và `--not-doing` của một mục tiêu, thước đo tiến độ của một mục tiêu, nơi sao lưu, và các trường owner của một mục được nhập) chỉ nhận chữ của các hệ chữ viết từ trái sang phải (kèm dấu kết hợp ngay sau một chữ), chữ số thập phân của hệ chữ từ trái sang phải hoặc chữ số châu Âu, dấu cách, và dấu câu ASCII trừ `"`; ký tự có tên như dấu ngoặc kép, dấu phẩy trên (prime), gershayim, dấu lặp (ditto), dấu nháy đơn kép hay dấu sắc kép thì không bao giờ được nhận. Mọi thứ khác, như emoji, chữ viết từ phải sang trái, chữ số Ả Rập-Ấn hay dấu nháy cong, đều bị từ chối (rc 1, bởi lệnh và bởi `guard-owner` trước khi nó hỏi), nêu ký tự dưới dạng `U+XXXX`. Văn bản, đứng cuối dòng, giữ quy tắc riêng của nó. `--owner-quote` là lời của owner, nguyên văn; `--where` nói lời đó được nói ở đâu.

Khi một thao tác đã vào nhật ký mà cache không ghi lại được, thao tác vẫn có hiệu lực (rc 0, kèm cảnh báo) và lần đọc sau gấp lại nhật ký.

## Skill

| Skill | Ai gọi | Làm gì |
|---|---|---|
| `brain` | Claude, khi một phiên cần giữ mục tiêu, quyết định, cửa sổ, trọng tâm, yêu cầu, việc đang làm, bước tiếp theo hoặc bẫy qua các lần nén | Dạy các quy tắc ở trên: khi nào chạy `brain op`, cách ghi mục owner qua hộp thoại, ghi lời owner ngay trong lượt owner nói, mục của một việc đang chạy, ghi đứng vững, vỡ và tiến độ ngay trong lượt, điều `promote?` và `drift` đòi ở owner, thứ tự ưu tiên, thẻ rà soát và các dòng của phần mở rộng, ý nghĩa từng mã thoát, cách nhận lại vai người ghi sau `/clear` hoặc `--fork-session`. Nó trỏ tới [sổ luật](docs/rulebook.vi.md). |
| `matrix` | Bạn, bằng `/matrix` (mô hình không tự gọi) | Chạy `brain matrix` và hiển thị đầu ra nguyên vẹn. |

## Mô hình chi phí

Hai lệnh cho thấy token đi đâu.

**`brain cost TRANSCRIPT`** đọc các trường `usage` của một transcript Claude Code (Claude Code giữ chúng dưới `~/.claude/projects/`) và tính giá bằng *token đầu vào cơ sở* (base-input tokens), theo các trọng số sau:

| Phần | Trọng số |
|---|---|
| input | 1× |
| cache read | 0,05× |
| cache write | 2× (1 giờ) hoặc 1,25× (5 phút); 2× khi lần ghi không tách theo TTL |
| output | 5× |

Lệnh in tỷ lệ giữa read, write, output và input, tổng số đơn vị, context trung bình và lớn nhất mỗi lần gọi, và từng khoảng nghỉ quá một giờ cùng lần ghi lại cache sau đó. Với `--merge-log F` (merge log của vibemaestro-sdlc: các dòng JSON có `result`, `time`, `repo` và `pr`) nó còn in số đơn vị trên mỗi PR đã merge trong khoảng thời gian của transcript. `--json` in cùng dữ liệu dưới dạng một đối tượng JSON. Transcript không đọc được thì rc 2.

Lệnh đếm một lần gọi cho mỗi `message.id`: Claude Code ghi mỗi khối nội dung của một phản hồi thành một bản ghi riêng với cùng `usage`, nên cộng thẳng các bản ghi sẽ đếm đôi hầu hết các lần gọi. Bản ghi sidechain (subagent) và `<synthetic>` bị bỏ qua, và đầu ra có đếm chúng.

```text
$ brain cost t.jsonl --merge-log merge.jsonl
brain cost · t.jsonl · 3 calls (main thread); skipped: 0 sidechain, 0 <synthetic>, 0 unreadable lines
split at A's weights (input 1x, cache read 0.05x, cache write 2x 1h / 1.25x 5m, output 5x): read 1.1% · write 96.1% · output 2.8% · input 0.0%
units: 216,520 base-input tokens — read 2,500 · write 208,000 · output 6,000 · input 20
…
merged PRs in the span: 1 · units per merged PR 216,520
```

(Đầu ra ghi "A's weights": đó là các trọng số ở trên, lấy từ phiên cơ sở mà các phép đo chi phí được so sánh với.)

**`brain matrix`** in Brain Matrix: bảy hàng, mỗi hàng một ô của Know/Do × hot/warm/cold (Do·warm có hai hàng: Workbench, và code intelligence do các plugin bên ngoài cung cấp). Mỗi hàng cho biết nơi lưu, kích thước theo ký tự (và ≈ token theo 4 ký tự một token, chưa hiệu chuẩn), khi nào được nạp, quy tắc quên, lần hợp nhất cuối, có sống sót qua lần nén hay không, và cảnh báo. Dưới các hàng là những gì brain đã làm trong phiên này: số dòng hook theo từng sự kiện, số ký tự đã đưa vào, các lần nén kèm lý do và kích thước context lần cuối, điểm mất mát gần nhất, dòng `cost` gần nhất, và các thao tác `--bulk`, `--shorter`, `--drop-anchor`. Brain không kèm mã nào cho code intelligence: hàng đó chỉ liệt kê các plugin đang bật có tên `*-lsp`, plugin có `.lsp.json` hoặc `lspServers`, và serena.

## Các cấp

Brain được xây theo từng cấp. Mỗi cấp kết thúc bằng một phép thử, và cấp sau bắt đầu sau phép thử đó.

| Cấp | Mục tiêu | Trạng thái |
|---|---|---|
| Sống sót qua lần nén | Đưa các quyết định đã ghim vào lại sau mỗi lần nén. | **Đã có**: kho lưu, hook, skill, matrix, cost, probe. |
| Tự quên | Hết hạn, đóng khi PR được merge, loại bớt ở mức trần, Artifact Index của các PR đang mở, một lượt Sleep, đối chiếu mềm lời trích của owner. | Chưa có. |
| Compact Pilot | Giảm chi phí cho mỗi PR đã merge bằng cửa sổ nén được chỉnh và chẩn đoán lúc rảnh. | Chưa có. |

## Phép thử thoát cho thấy gì

Phép thử thoát của cấp đầu (ba lượt, một lần nén và 10 quyết định đã ghim trong khoảng 225k token context) cho 10/10 khi có brain và 10/10 cho nhóm đối chứng không có brain: brain chưa được chứng minh là cần ở cỡ này. Một phép thử khó hơn, với nhiều lần nén liên tiếp, chưa được chạy.

Phương pháp, các con số và những phép đo khác nằm trong [docs/research/brain.vi.md](../../docs/research/brain.vi.md).

## Anchor đã cũ

Anchor là chuỗi chính xác mà bản tóm tắt phải giữ (`--anchor`). Khi một mục Now, Next, phiên, hàng chờ, yêu cầu hoặc quyết định đã ghim còn sống có anchor là issue đã đóng, PR đã merge hoặc PR đã đóng, brain nói ra điều đó và không đụng vào mục: chỉ người ghi mới đóng hoặc thay thế nó, bằng `brain op` (quyết định đã ghim thì owner, bằng `brain owner`). Ngoại lệ duy nhất là các anchor `closes` của chính mục (xem [Tự đóng](#tự-đóng)). Việc tra dùng `gh` với tài khoản của chính nó, luôn trên `github.com` (`--hostname github.com`).

- **Anchor nào.** Chỉ anchor nguyên chuỗi, một trong ba dạng:
  - `owner/name#N`, kiểm đúng như viết;
  - URL issue hoặc PR của GitHub, `https://github.com/owner/name/issues/N` hoặc `https://github.com/owner/name/pull/N` (sau số không có gì nữa), kiểm như chính `owner/name#N` đó;
  - `#N` trần, chỉ kiểm trong repository của chính mục: repository duy nhất mà các anchor `owner/name#N`, URL issue hoặc PR của GitHub và anchor `closes` của nó nêu, khi chúng nêu đúng một repository. Mục nêu không repository nào hoặc nhiều repository thì không có repository duy nhất, và `#N` trần của nó không được kiểm.

  Hai dạng đầu tự nêu repository của mình, nên là dạng dùng cho phiên làm việc trên nhiều repository. Mọi anchor khác, và mọi con số trong văn bản của mục, bị bỏ qua. Bẫy, cửa sổ và sự kiện không được kiểm.
- **Ghi anchor trần.** `brain op add`, `brain op supersede`, `brain owner add` và `brain owner supersede` in thêm một dòng `warning:` sau thông báo thường lệ khi mục Now, Next, phiên, hàng chờ, yêu cầu hoặc quyết định đã ghim được ghi mang `#N` trần và không nêu repository duy nhất nào: `warning: #N is not checked for staleness (the item names no single repository to resolve it against); write owner/name#N (a GitHub issue or PR URL also works)`. Dòng đó nêu từng anchor trần và dạng nên viết thay. `#N` trần vẫn được nhận, và lệnh không bao giờ từ chối: mục vẫn được ghi và mã thoát là 0 (`--closes` vẫn từ chối `#N` trần). Một `supersede` nêu cả các anchor trần mà nó mang sang (đổi bằng `--drop-anchor '#N' --anchor owner/name#N`).
- **`brain doctor`** tra từng anchor như vậy trên GitHub bằng `gh api` và in một dòng `warn` cho mỗi anchor đã cũ (`stale anchor: X5 #7 (owner/name#N) closed <date>`, trong đó `#7` trần được kiểm trong repository duy nhất mà mục của nó nêu; `merged` cho PR đã merge, `closed unmerged` cho PR đóng mà không merge, `closed not planned` cho issue đóng vì không làm). Dòng của một quyết định đã ghim có thêm lệnh owner chạy (`owner retires it: brain owner unpin D3, or brain owner supersede D3 --text …`). Nó không đọc hay ghi cache, và một `warn` không đổi mã thoát. Với các mục còn sống có anchor trần nó không kiểm được (mục không nêu repository duy nhất nào), nó in `info  stale anchors: N bare anchors on M items naming no single repository are not checked; write owner/name#N` và một dòng `info` cho mỗi anchor (`not checked: X3 #7`), tối đa 20 dòng, rồi `not checked: +K more anchors`. Khi `BRAIN_DEFAULT_REPO` đang được đặt, nó in một dòng `warn` (`BRAIN_DEFAULT_REPO is set (<value>) but no longer read: …`).
- **`SessionStart`** thêm ` · stale: #7 closed 2026-10-20` sau dòng của mục, chỉ trong các chuỗi được đưa vào (không ở `hot.md` hay `brain render`), và một dòng ghi chú `stale-anchor check:` trong chuỗi thứ nhất khi thiếu `gh`, một lần tra lỗi hoặc quá hạn, một anchor trần bị bỏ qua (`skipped for #7: no single repository of its item`), hoặc chưa phải anchor nào cũng có câu trả lời. Dấu và ghi chú cộng lại không quá 450 ký tự mỗi chuỗi.
- **Nhanh và an toàn khi không có mạng.** Câu trả lời được cache trong `stale-cache.json` ở thư mục trạng thái (600 giây; lần tra lỗi 120 giây). Mỗi `SessionStart` tra tối đa 12 anchor, anchor lâu chưa kiểm nhất trước, song song trong một hạn 2 giây, rồi bị dừng; nên mọi anchor đều được tới lượt sau vài lần phiên bắt đầu. Không có `gh` hoặc không có mạng nghĩa là không dấu và một dòng ghi chú, không bao giờ là lỗi.

## Tự đóng

Mục Now, Next, phiên, hàng chờ hoặc yêu cầu có thể nêu issue hoặc PR mà khi nó đóng nghĩa là *mục này đã xong*, bằng `--closes` (tối đa 2, mỗi cái là `owner/name#N` hoặc URL issue hay PR của GitHub; `#N` trần bị từ chối). Hãy nêu chính việc của mục, không bao giờ nêu thứ mục đang chờ, và không bao giờ nêu issue theo dõi của nhiều PR. Anchor `closes` cũng là anchor, nên nó tính vào giới hạn 8 và được đánh dấu như các anchor khác.

- **Lúc ghi**, anchor được tra một lần (2 giây): lệnh in trạng thái và tiêu đề của nó (tiêu đề không được lưu), và từ chối (rc 1) anchor GitHub không biết và anchor mới đã merge hoặc đã hoàn thành, vì mục đó chỉ có thể bị đánh dấu, không bao giờ tự đóng. Một `supersede` giữ anchor mà mục đã nêu (mang sang, hoặc nêu lại) thì chỉ cảnh báo khi anchor đó đã xong: mục mới có thể tự đóng ở lần phiên bắt đầu tới, và `--drop-anchor` giữ nó còn sống. Không có câu trả lời (không có mạng, không có `gh`) thì lệnh vẫn ghi, kèm dòng `closes not checked: owner/name#N`.
- **Lúc `SessionStart`**, trong phiên đang ghi brain của dự án (lần `brain claim` cuối), một mục tự đóng khi mọi anchor `closes` của nó đã xong sau lúc mục nêu nó được ghi: PR đã merge vào nhánh mặc định của repository (lần tra thứ hai, `…/pulls/N`, kiểm nhánh đích), hoặc issue đã đóng là hoàn thành theo lần tra ngay trong lần phiên bắt đầu đó (câu trả lời issue từ cache không bao giờ làm đóng, vì issue có thể mở lại). Thao tác là `link-close`, kèm lý do, con trỏ, và trạng thái, thời điểm, commit merge của từng anchor; nó không tính vào hạn mức cho mục nghỉ. Chuỗi đã chứa mục hiện một dòng ghi chú, `auto-closed now: X5 (owner/name#N merged <month-day>)`, một lần, và mục chuyển sang Done.
- **Không bao giờ đóng:** PR đóng mà không merge hoặc merge vào nhánh khác, issue đóng vì không làm, vì trùng hoặc không có lý do, anchor còn mở, lần tra lỗi hoặc quá hạn, và mọi mục trong lần bắt đầu của phiên khác. Những mục này giữ dấu stale. Mục tiêu, quyết định đã ghim, cửa sổ, trọng tâm, bẫy và sự kiện không bao giờ tự đóng theo liên kết: ghim có anchor đã xong được đánh dấu `owner retires it`. Một yêu cầu tự đóng theo liên kết thì lấy anchor của nó làm con trỏ.
- **Ở lời nhắc của người ghi**, ngoài `SessionStart`, hook `UserPromptSubmit` khởi động `brain op close-linked` ở nền (xem [Hook](#hook)), nên một phiên dài đóng được những gì đã merge mà không cần lần bắt đầu mới. Các lần đóng là thao tác `link-close` và mỗi lần chạy ghi một dòng `close-linked` trong Episode Log.
- **Đóng dồn bị giữ lại.** Khi hơn 5 mục sẽ đóng cùng lúc thì không mục nào đóng: chúng được đánh dấu, và ghi chú nói `auto-close held: N items at once; check brain doctor, then brain op close-linked`. `brain op close-linked` kiểm y như vậy bằng lần tra mới (20 giây, tối đa 40 anchor) và đóng mọi mục đạt.
- **Issue mở lại.** Trong 24 giờ sau một lần đóng, các anchor issue của mục đã đóng thỉnh thoảng được tra lại (tối đa 3 mỗi lần phiên bắt đầu). Cái nào mở lại sẽ thêm `reopened: X5 owner/name#N, re-add it with brain op add` vào dòng ghi chú; không có thao tác mở lại.
- **`brain doctor`** không ghi gì; nó in `would close:` cho mục mà lần phiên bắt đầu tới sẽ đóng, `auto-closed:` cho mỗi lần đóng trong 24 giờ qua, và các dòng mở lại.
- **Cập nhật.** Hãy khởi động lại mọi phiên của dự án trên phiên bản này trước khi có mục tự đóng, trước khi ghi mục mục tiêu, trọng tâm, yêu cầu, phiên, hàng chờ hay sự kiện, hoặc trước khi có mục xếp hàng: brain cũ hơn từ chối ghi vào nhật ký có `link-close`, một trong các loại đó hoặc một mục xếp hàng, và ngừng đưa bộ nhớ nóng vào mỗi khi nó phải đọc lại nhật ký đó. `brain doctor` cảnh báo phiên mà lần bắt đầu cuối chạy brain cũ hơn, và nói hãy khởi động lại nó trên phiên bản này; sau `/reload-plugins`, bất kỳ lệnh `brain` nào trong phiên đó xóa cảnh báo. Không hỗ trợ quay về phiên bản cũ hơn khi đã có một thao tác như vậy được ghi.

## Xuất, nhập và sao lưu

Brain của một dự án có thể được ghi ra một file, được kiểm tra riêng, được đưa vào một dự án khác, hoặc được đưa trở lại chính dự án đó sau khi mất, và có thể được sao lưu vào một nơi riêng tư do owner chỉ định.

- **Gói (bundle).** `brain export --out FILE` ghi một file JSON, quyền 0600, là một file mới nằm ngoài thư mục trạng thái. File chứa nhật ký từng dòng đúng như khi ghi, nên chuỗi hash của nó kiểm tra được, phần đầu chuỗi (head), và các bản chép của những gì nhật ký chứa: mọi mục đang sống và đang xếp hàng cùng loại, anchor và lời của owner, hàng đợi tràn và sổ bằng chứng. Các đường dẫn của máy này trở thành chỗ giữ chỗ (placeholder): work tree của dự án là `<project>`, thư mục gốc trạng thái là `<brain-state>` và `XDG_STATE_HOME` chứa nó là `<state-home>`, thư mục cấu hình của Claude Code là `<claude-dir>` và thư mục home là `~`. Một dòng bị đổi giữ nguyên hash gốc của nó, nên chuỗi vẫn đi tiếp qua dòng đó, nhưng chuỗi không bảo đảm cho nội dung của dòng ấy: việc nhập không đưa vào gì mà dòng đó đã ghi, và nêu tên những gì đã bỏ qua. Bộ lọc giá trị nhạy cảm chạy trên toàn bộ gói, và một lần trúng sẽ dừng việc xuất. Một gói ghi `"version": 1`. Với `--scope global` (hoặc `project`), gói chỉ chứa các mục tiêu và quyết định thuộc phạm vi đó cùng các dòng đã ghi ra chúng, không có dòng nào khác của dự án; một gói chọn lọc như vậy không mang theo chuỗi của nó. Việc xuất chỉ đọc, nên không cần phiên.
- **Kiểm tra.** `brain doctor --bundle FILE` kiểm tra một gói mà không đụng tới brain nào: hình dạng, chuỗi và head, các bản chép có bằng kết quả gộp (fold) nhật ký của nó không, và chữ của nó theo các guard của việc ghi và bộ lọc.
- **Nhập gồm hai lệnh.** `brain import FILE [--only LETTERS]` đưa vào não phải (trọng tâm, yêu cầu, Now, các phiên, hàng chờ của owner, Next, bẫy, sự thật) đúng như `brain op add` ghi: mức trần, hàng đợi và các guard đều áp dụng, id được giữ khi còn trống, và một mục có mục tiêu hay trọng tâm chưa được đưa vào sẽ chờ lần chạy sau. Sau đó nó phát lại sổ bằng chứng của những gì đã có ở đây, mỗi sự kiện ở đúng thời điểm gốc. `brain owner import FILE` đưa vào các mục tiêu, quyết định và cửa sổ qua một hộp thoại cấp quyền duy nhất liệt kê đủ từng mục, mỗi dòng theo dạng mà hộp thoại đơn lẻ dùng. Chữ của hộp thoại gắn với bản ghi của nó, nên một gói hay một brain đã đổi sau hộp thoại sẽ bị từ chối. Chạy nửa của owner trước, rồi chạy lại `brain import` cho những gì đã chờ nó.
- **Một mục được nhập giữ lại gì.** Lời của owner, từng byte, và một dòng nguồn gốc (provenance) mà `brain show ID` in ra: dự án nguồn, khóa của nó, head của chuỗi và id cũ của mục. Một lần supersede mang dòng nguồn gốc sang.
- **Dữ liệu của một phần mở rộng** (`ext.<tên>`) đi theo gói, trong nhật ký của nó, nhưng `brain import` không đưa nó vào.
- **Gói là dữ liệu.** Chữ của gói qua các guard của việc ghi: độ dài, ký tự điều khiển và ký tự vô hình, giá trị nhạy cảm. Gói trượt một guard bị từ chối toàn bộ. Một mục chỉ vượt giới hạn riêng của brain này (mức trần chữ nhỏ hơn, một mục não trái đã đầy, một cửa sổ đã hết hạn) thì bị bỏ qua và được nêu tên. Không gì trong gói được chạy hay được dùng làm đường dẫn. Việc nhập chỉ thêm vào nhật ký, thành một lô dưới khóa của kho, do người ghi của dự án ghi.
- **Gói bị từ chối.** Gói của chính brain này, một brain là trạng thái cũ hơn của chính chuỗi trong gói, gói cũ hơn một gói đã nhập từ cùng dự án, và gói rẽ nhánh khỏi gói đó. Cùng một gói nhập hai lần không đưa vào gì mới; một gói mới hơn nêu tên các mục nguồn của nó đã cho nghỉ từ đó.
- **Sao lưu.** Qua hộp thoại, `brain owner backup DIR [--every HOURS]` chỉ định thư mục riêng tư mà các bản sao lưu vào: một đường dẫn tuyệt đối tới một thư mục thật của tài khoản này, quyền 0700, nằm ngoài mọi git work tree, ngoài dự án và ngoài thư mục gốc trạng thái. `brain owner backup off` dừng chúng. Nơi này được giữ trong thư mục trạng thái, không bao giờ trong nhật ký. `brain backup` ghi một gói đầy đủ vào đó và giữ 30 bản mới nhất. Khi đến hạn sao lưu (brain đã đổi và bản sao lưu gần nhất cũ hơn khoảng thời gian, mặc định 24 giờ), các hook `SessionStart` và `PreCompact` khởi động `brain backup --if-due` ở nền, và không hook nào chờ nó. Bạn cũng có thể chạy `brain backup` từ bộ hẹn giờ của riêng bạn, trong thư mục của dự án. `brain doctor` nêu nơi sao lưu và bản sao lưu gần nhất, và cảnh báo khi sao lưu lỗi hay bị chậm; thẻ rà soát cũng nói ra.
- **Khôi phục.** Sau khi mất, owner dời thư mục trạng thái cũ sang chỗ khác nếu nó vẫn còn (`brain doctor --path` nêu nó). Rồi `brain owner import BACKUP` và `brain import BACKUP` đưa brain trở lại vào trạng thái trống, với cùng id, lời của owner, ngày của các mục, hàng đợi và sổ. Các sự kiện của một mã luật (`brain op held S07`) được đưa về; một mục đã chuyển ra một con trỏ, và bằng chứng của một luật đã bị supersede, ở lại trong gói.

## Phần mở rộng

Một plugin khác có thể thêm vào brain qua một script đã khai báo: một phép kiểm trên một lần ghi `brain op`, một động từ của owner, các dòng cho lúc khởi động phiên, thẻ rà soát và bản ghi đo đạc, và một lệnh đọc. Brain chạy script trong một tiến trình riêng, đưa nó dữ liệu và nhận dữ liệu về; phần mở rộng không bao giờ ghi brain. Brain ghi điều nó trả lời, qua các đường ghi và bộ lọc của chính brain, dưới tên của phần mở rộng. Một brain không có phần mở rộng nào thì không nạp phần nào của cơ chế này.

**Khi nào một plugin là phần mở rộng.** Nó được cài cho dự án (một mục có `projectPath` chỉ tính cho dự án đó) và được bật trong settings của người dùng, dự án, local hay managed; đường dẫn cài đặt của nó nằm trong `<config dir>/plugins/`; `.claude-plugin/plugin.json` của nó có `vibemaestro-brain` trong `dependencies`; và gốc của nó có file thường `brain-extension.json`. Đọc tối đa 4, theo thứ tự id của plugin.

```json
{
  "schema": 1,
  "name": "example",
  "script": "brain/extension.py",
  "checks": [
    {"verb": "add", "kinds": ["session"], "options": ["--ticket"]},
    {"verb": "supersede", "kinds": ["session"], "options": ["--ticket"]},
    {"verb": "broke"}
  ],
  "owner": [
    {"verb": "vouch", "effect": "pin", "args": ["tag"]},
    {"verb": "shelve", "effect": "archive", "letters": ["T", "F"]}
  ],
  "calls": ["start", "record", "read"]
}
```

| Khóa | Luật |
|---|---|
| `schema` | `1` |
| `name` | `[a-z][a-z0-9-]{1,23}`, duy nhất giữa các phần mở rộng: tên mà dữ liệu của nó được lưu dưới đó và các dòng của nó mở đầu bằng |
| `script` | một file `.py` dưới gốc plugin (Python 3.8, thư viện chuẩn) |
| `checks` | các lần ghi `brain op` nó kiểm: `verb` là `add`, `supersede`, `close`, `held`, `broke`, `hit` hoặc `progress`; `kinds` (cho `add`, `supersede` và `close`; bỏ trống là mọi loại) nêu các loại của não phải; `options` thêm tối đa 4 tùy chọn, mỗi cái một giá trị. Tùy chọn của chính brain không phải của nó, trừ `--goal`, `--focus` và `--due` cho một loại brain không dùng chúng. |
| `owner` | các động từ owner nó thêm, không bao giờ là `add`, `unpin`, `supersede`, `promote`, `import`, `backup` hay của phần mở rộng khác: `pin` (`brain owner VERB [ARG…] --text T --owner-quote Q --where W [--anchor A]… [--link L]…`, một quyết định được ghim đúng như `brain owner add --kind decision` ghim, với tối đa 2 `args` có tên) hoặc `archive` (`brain owner VERB ID POINTER`, một mục còn sống thuộc `letters` của nó, trong `G D W T F`, được chuyển ra ngoài như `brain owner promote` chuyển) |
| `calls` | nó trả lời những lời gọi nào trong `start`, `record` và `read` |

Một manifest phạm một luật, hoặc hai phần mở rộng trùng tên, trùng động từ owner hay trùng tùy chọn, bị bỏ qua, và `brain doctor` nói vì sao.

**Brain gọi nó thế nào.** `python -I -B <script>` ở gốc plugin, một đối tượng JSON vào stdin và một ra stdout (tối đa 64 KiB), trong 1 giây ở một hook và 3 giây ở CLI, và mọi phần mở rộng của một sự kiện trong 2 giây ở một hook và 6 giây ở CLI; quá thời hạn thì cả nhóm tiến trình bị giết. Mọi lời gọi chạy dưới khóa của kho. Lời gọi không có `CLAUDE_CODE_SESSION_ID` và có một `XDG_STATE_HOME` trống, nên một lần ghi `brain` do nó khởi chạy bị từ chối (rc 4). Mọi đầu vào có `schema`, `call`, `extension`, `now`, `project`, `config` (các ngưỡng `ledger` và các mức trần) và `state` (mọi mục theo id); mọi lời gọi trừ một lần start không có thẻ còn có `ops`, các thao tác của nhật ký như đã lưu.

| Lời gọi | Khi nào | Cho thêm | Trả lời |
|---|---|---|---|
| `check` | một lần ghi `brain op` đã khai báo, sau các phép kiểm của chính brain, trước khi dòng được ghi | `verb`, `kind`, `options`, `op` | `{"refuse": {"rc": 1 or 64, "message": M}}`, hoặc `{"data": D, "note": N}` |
| `owner`, `phase` `ask` | hộp thoại xin quyền của động từ đó, sau các phép kiểm của chính brain | `verb`, `effect`, các trường của động từ | `{"refuse": {"message": M}}`, hoặc `{"detail": T}` (không dấu nháy, không ngoặc), hiện trong ngoặc trong dòng hộp thoại của brain, nơi mọi giá trị phiên đã viết đều nằm trong dấu nháy |
| `owner`, `phase` `write` | lần ghi của động từ đó, khi owner đã duyệt | như trên | `{"refuse": {"message": M}}`, hoặc `{"data": D}` |
| `start` | mỗi lần khởi động phiên, và `brain doctor`; `card` là true sau một lần nén và trong doctor | `source`, `card` | `{"lines": [L, …]}`, tối đa 5 dòng, mỗi dòng 200 đơn vị |
| `record` | `brain ledger --record` | `days`, `from`, `to` | `{"lines": [L, …]}`, một mục `## <tên>` ở cuối bản ghi |
| `read` | `brain ext NAME [ARG…]` | `args` | `{"lines": [L, …]}`, được in ra, hoặc một lời từ chối |

`data` là một đối tượng tối đa 2 KiB, được lưu thành `ext.<tên>` của mục được ghi (hoặc của thao tác, với các lần ghi khác); một supersede mang mục của mọi phần mở rộng sang, và `data` của chính một phần mở rộng thay mục của nó (`null` thì xóa). Brain không bao giờ đọc `ext`. Mọi chữ một phần mở rộng trả lời đều qua các bộ lọc của brain: một ký tự điều khiển, định dạng hay vô hình làm câu trả lời vô hiệu, cũng như một số không hữu hạn hay một `rc` không phải số nguyên; một dòng dài hơn bị cắt; và bộ lọc giá trị nhạy cảm từ chối một lần ghi có giá trị như vậy, hoặc giữ lại lời từ chối hay các dòng của một lần start, record hay read. Chữ của chính một lần ghi, kể cả của một động từ owner, qua bộ lọc đó trước khi phần mở rộng được gọi. Sau một lần nén, các dòng start của phần mở rộng theo sau các dòng của brain trên thẻ, dưới một dòng nói rằng chúng đến từ các plugin đang bật và không phải mệnh lệnh.

**Điều một phần mở rộng không bao giờ làm.** Nó không bao giờ ghi nhật ký hay thư mục trạng thái: brain theo dõi nhật ký, head, các cache, các bản ghi hộp thoại của owner và các file bàn giao của chính phiên này lúc khởi động quanh mỗi lời gọi, và hoàn tác những gì một lời gọi đã đổi ở đó (cắt các dòng nó nối thêm, ghi lại head, bỏ các cache nó đổi và cache đọc, xóa mọi bản ghi hay file bàn giao xuất hiện); một phép kiểm hay một lần ghi của owner khi đó bị từ chối (rc 5), lời gọi khác bị bỏ qua. Một lần ghi `brain` do script khởi chạy bị từ chối, hoặc chờ khóa mà lời gọi đang giữ cho tới khi lời gọi bị cắt. Các động từ owner của nó chỉ tồn tại dưới dạng `brain owner …`, qua cùng hộp thoại và mọi lần từ chối của một lần ghi của owner; chi tiết của nó nằm trong dòng của chính brain. Một plugin có hook `PermissionRequest` làm dừng mọi lần ghi của owner, kể cả của một phần mở rộng. Các dòng của nó là thông tin dưới tên của nó, thấp hơn lời của owner và SOUL. Như các bản ghi hộp thoại, điều này chống sơ suất và một plugin chạy sai, không chống việc giả mạo của cùng một người dùng, ví dụ một tiến trình con rời lời gọi rồi ghi sau.

**Một phần mở rộng thiếu, hỏng hay chậm** (không trả lời kịp, thoát khác 0, câu trả lời không phải một đối tượng JSON hay phạm một luật) bị bỏ qua: chuỗi 1 hiện một dòng thế chỗ các dòng của nó, một lần ghi nó kiểm vẫn đi tiếp kèm một cảnh báo (và bị từ chối khi lệnh mang một tùy chọn của nó), động từ owner của nó không dùng được, và `brain doctor` nêu lần bỏ qua gần nhất.

Ví dụ trong `tests/fixtures/brain-extension/` của repository này thêm một ticket cho mỗi mục phiên, một quyết định được bảo chứng và một bài học được cất đi, cùng các dòng của chúng; `tests/test-brain-extension.sh` chạy nó.

## Cấu hình

Các mức trần nằm trong `.vibemaestro/brain.json` ở gốc work tree chính của dự án của phiên: mọi worktree của một repository dùng chung một brain, nên tất cả đọc đúng file này, và một phiên bắt đầu trong thư mục con cũng đọc nó. Ngoại lệ là repository có thư mục git tách khỏi work tree (`git init --separate-git-dir`, hoặc `.git` trỏ tới một thư mục ở nơi khác): git không ghi lại work tree chính của nó, nên mỗi worktree đọc file riêng của mình dù chúng dùng chung một brain. Hãy đặt cùng một file trong từng worktree; `brain doctor` cảnh báo trong worktree như vậy. Khóa nào cũng không bắt buộc và đều có mặc định; không có file thì dùng mặc định.

```json
{"schema": 1,
 "caps": {"G": 5, "D": 20, "W": 10, "P": 5, "R": 20, "N": 5, "X": 30, "S": 20, "Q": 15, "T": 20, "F": 25},
 "text_max": 300, "text_caps": {"S": 600}, "quote_max": 600,
 "ledger": {"promote_held": 5, "promote_sessions": 3, "promote_days": 7, "promote_clean_days": 30,
            "drift_broke": 2, "drift_sessions": 2, "drift_checks": 3, "drift_one_in": 3, "drift_days": 30, "dormant_days": 30}}
```

| Khóa | Mặc định | Khoảng | Tác dụng |
|---|---|---|---|
| `caps` | như trên | 1 tới 100 mỗi loại | số mục còn sống của mỗi mục |
| `text_max` | 300 | 50 tới 1.000 | văn bản của một mục, mọi loại trừ các loại trong `text_caps`, theo đơn vị UTF-16 |
| `text_caps` | `{"S": 600}` | 50 tới 1.000 mỗi loại | văn bản của một mục, theo chữ, theo đơn vị UTF-16 |
| `quote_max` | 600 | 100 tới 2.000 | lời owner của một mục tiêu, một ghim, một trọng tâm hay một yêu cầu, theo đơn vị UTF-16; lời dài hơn bị từ chối, không bao giờ bị cắt |
| `ledger.promote_held`, `promote_sessions` | 5, 3 | 1 tới 100 | số lần đứng vững của một ứng viên nâng bậc, và số phiên khác nhau chúng đến từ |
| `ledger.promote_days`, `promote_clean_days` | 7, 30 | 0 tới 365 | số ngày giữa lần đứng vững đầu và cuối, và số ngày không vỡ |
| `ledger.drift_broke`, `drift_sessions` | 2, 2 | 1 tới 100 | trôi: số lần vỡ trong cửa sổ, từ chừng này phiên |
| `ledger.drift_checks`, `drift_one_in` | 3, 3 | 1 tới 100 | hoặc trôi: ít nhất chừng này lần kiểm, vỡ một trong mỗi chừng này lần |
| `ledger.drift_days`, `dormant_days` | 30, 30 | 1 tới 365 | cửa sổ mà phép đo trôi đọc; số ngày một mục không ai đụng tới trước khi thành ngủ quên |

- **Bản đọc cũ hơn và mới hơn.** Một khóa lạ thì cảnh báo và bị bỏ qua. Một khóa đã biết với giá trị sai, `schema` lớn hơn 1, hoặc một file không phải JSON hay không phải file thường làm mọi lần ghi bị từ chối (rc 1) cho tới khi sửa: `brain op`, `brain owner` (`guard-owner` từ chối trước khi hộp thoại hỏi) và `brain op close-linked`, còn lần tự đóng lúc bắt đầu phiên không đóng gì và nói ra điều đó. Mọi lần đọc (các hook, `brain render`, `brain doctor`) dùng giá trị mặc định của khóa đó và nói ra điều đó. Hook không bao giờ hỏng hay chờ vì file này.
- **Mức trần của não trái là của owner.** Mức trần của `G`, `D` và `W` giới hạn những gì owner giữ ghim, nên đổi chúng là quyết định của owner. Trong một repository có cổng merge giữ `.vibemaestro/*`, owner là người merge thay đổi của file; dù thế nào, `brain doctor` cũng cảnh báo, và chuỗi 1 mang một dòng, khi một mức trần não trái khác mặc định.
- **Hạ mức trần không bỏ gì.** Các mục còn sống vượt mức vẫn sống, và lần thêm mới xếp hàng cho tới khi số mục xuống dưới mức; hạ mức trần văn bản thì áp dụng cho lần ghi mới.
- **Các ngưỡng chỉ đề xuất.** Một lần nâng bậc, một lần trôi hay một mục ngủ quên được nêu ra để owner quyết; không ngưỡng nào tự di chuyển một mục.
- `brain doctor` in các mức trần và các ngưỡng mà file thay đổi và từng cảnh báo; chuỗi 1 mang một dòng `brain config:` khi file có cảnh báo, có lỗi hoặc có mức trần não trái khác mặc định.

Brain cũng đọc các biến môi trường sau.

| Biến | Tác dụng |
|---|---|
| `BRAIN_OFF` | Giá trị nào khác rỗng và khác `0` đều làm mọi hook im lặng. Dùng cho một lượt đối chứng. |
| `BRAIN_DEFAULT_REPO` | Bị bỏ qua; `brain doctor` cảnh báo khi nó đang được đặt. Anchor trần `#N` chỉ được tra trong repository của chính mục (xem [Anchor đã cũ](#anchor-đã-cũ)); hãy viết `owner/name#N`. |
| `XDG_STATE_HOME` | Gốc của thư mục trạng thái; mặc định là `~/.local/state`. |
| `CLAUDE_CODE_SESSION_ID` | Do Claude Code đặt. Brain nhận ra người ghi qua biến này, và CLI tìm dự án của phiên qua nó. |
| `CLAUDE_PROJECT_DIR` | Do Claude Code đặt cho hook. Nó nêu dự án của phiên, và hook dùng nó để tìm skill và settings của dự án. |
| `VIBEMAESTRO_ROLE` | Đúng bằng `worker`: phiên là phiên worker, như khi đặt cả `INTENT_SLUG` và `SEAT`. |
| `INTENT_SLUG` và `SEAT` | Khi đặt cả hai, phiên là phiên worker: hook im lặng và việc ghi dừng với rc 4. |
| `HOME` | Nơi tìm thư mục trạng thái mặc định và settings cấp người dùng của Claude Code. |
| `CLAUDE_CONFIG_DIR` | Thư mục cấu hình của Claude Code (mặc định `~/.claude`). Brain đọc plugin đang bật, skill và settings ở đó, tìm các plugin mở rộng nó, và tìm bộ lọc của vibemaestro-sdlc qua nó. |
| `CLAUDE_CODE_EXECPATH` | Do Claude Code đặt. Hook `guard-owner` chạy nó với `--version` để kiểm tra phiên bản. |
| `CLAUDE_CODE_REMOTE` | Do Claude Code đặt. Khi bằng `true`, `brain matrix` báo code intelligence là chưa khởi động. |

`BRAIN_TEST`, `BRAIN_TEST_PAUSE_MS`, `BRAIN_TEST_ASK_MODES` và `BRAIN_TEST_SOURCES` dành cho bộ test của chính plugin. Đừng đặt chúng: `brain doctor` cảnh báo khi `BRAIN_TEST` được đặt.

### Nơi lưu trạng thái

`$XDG_STATE_HOME/vibemaestro/brain/<project>-<12 hex>/`, hoặc `~/.local/state/vibemaestro/brain/…` khi `XDG_STATE_HOME` chưa đặt. Mỗi repository một thư mục, và mọi worktree của repository dùng chung. File có quyền 0600. `brain doctor --path` in thư mục đó. Brain không ghi gì vào repository.

Một phiên giữ một dự án, thư mục nó khởi động, dù shell của nó `cd` đi đâu. Hook đọc dự án từ `CLAUDE_PROJECT_DIR` và ghi lại theo session id; `brain`, chạy từ Bash của phiên, đọc bản ghi đó. Khi shell đang ở dự án khác, `brain` vẫn dùng dự án của phiên và in một dòng nêu cả hai. Bản ghi không tin được thì bị từ chối (rc 1), không đọc hay ghi gì. Ngoài một phiên Claude Code, hoặc trước khi hook nào chạy, dự án là dự án chứa thư mục hiện tại. Đường dẫn dự án không cần là UTF-8 hợp lệ: thư mục trạng thái được đặt tên từ các byte của đường dẫn. Khi thư mục làm việc của shell không còn tồn tại, `brain` bị từ chối (rc 1: `the working directory no longer exists … cd into the project and run it again`), không đọc hay ghi gì, và các hook im lặng.

| File | Chứa |
|---|---|
| `hot.jsonl`, `head.json` | nhật ký thao tác và hash phần đuôi của nó |
| `hot.json`, `archive.jsonl`, `owner.json`, `hot.md` | các cache và bản render, dựng lại từ nhật ký |
| `asked/` | các bản ghi hộp thoại owner đang chờ |
| `lock` | khóa file mà mọi lần ghi đều lấy |
| `episodes.jsonl` | Episode Log |
| `summaries/` | các bản tóm tắt nén đã lưu (200 bản mới nhất) |
| `cost/` | tổng chi phí đang chạy và vị trí byte của từng phiên |
| `ledger-record.json` | thời điểm của bản ghi gần nhất dài từ 30 ngày trở lên (`brain ledger --record`), mà dòng đến hạn của thẻ rà soát đếm từ đó |
| `backup.json`, `backup-last.json`, `backup.lock` | nơi sao lưu owner đã chỉ định và khoảng thời gian; bản sao lưu gần nhất đã ghi và lần lỗi gần nhất; khóa của một lần sao lưu đang chạy |

Còn hai thư mục nữa nằm cạnh các thư mục dự án dưới `…/vibemaestro/brain/`: `pending/` chứa một dấu cho mỗi phiên có bản ghi hộp thoại đang chờ lệnh của nó, và `sessions/` chứa một bản ghi cho mỗi phiên đang chạy, nêu dự án của nó (xoá khi phiên kết thúc, trừ sau `/clear` hay khi chuyển sang phiên khác, hoặc sau 30 ngày).

Đừng bao giờ sửa các file này. Một guard sẽ từ chối việc sửa, và một thay đổi bằng tay làm gãy chuỗi hash và chặn mọi lần ghi.

## Phụ thuộc vào vibemaestro-sdlc

`plugin.json` khai báo phụ thuộc vào `vibemaestro-sdlc`. Brain dùng hai thứ từ đó:

- **Bộ lọc giá trị nhạy cảm**, `gates/pr_sensitive.py`. Mọi lần ghi đi qua nó. Nếu thiếu bộ lọc, mọi lần ghi bị từ chối, và `brain doctor` báo một vấn đề.
- **Merge log**, mà `brain cost --merge-log` đọc để đếm các PR đã merge.

Claude Code không nạp một plugin mà phụ thuộc của nó chưa bật, nên hook của brain chỉ chạy khi vibemaestro-sdlc cũng được bật. Matrix liệt kê index của repository như một ô dùng chung: vibemaestro-sdlc đưa nó vào khi tùy chọn `current_state.inject` bật (mặc định tắt). Xem [vibemaestro-sdlc](../vibemaestro-sdlc/README.vi.md).

Mỗi bản phát hành công khai của brain đòi phiên bản vibemaestro-sdlc mà nó được phát hành cùng: `plugin.json` của nó ghi phiên bản đó làm mức thấp nhất (`>=`), và ghi chú phát hành nêu các phiên bản được phát hành cùng nhau. Hãy cập nhật cả hai cùng lúc. Nếu chỉ cập nhật brain trên một vibemaestro-sdlc cũ hơn, brain không nạp được, và `/plugin` nêu phiên bản vibemaestro-sdlc mà nó cần.

## Yêu cầu

- Claude Code. Mục của owner cần phiên bản 2.1.211 trở lên khi phiên chạy ở chế độ `auto`; `brain doctor` kiểm tra điều này.
- `vibemaestro-sdlc`, được cài cùng brain.
- Python 3.8 trở lên và `git` trên `PATH`. Các script chỉ dùng thư viện chuẩn.
- Hệ thống POSIX: kho lưu dùng khóa file `fcntl`.

## Giới hạn

- Chưa có recall và chưa tự loại bỏ mục: bạn hoặc Claude cho các mục nghỉ, trừ mục có `closes` đã xong (xem [Tự đóng](#tự-đóng)). Một mục não phải đã đầy xếp các mục mới vào hàng đợi thay vì bỏ mục nào. Cửa sổ hết hạn được hiện là đã hết hạn nhưng không bị xóa.
- Cột token của Matrix là số ký tự ÷ 4, không phải số đo thực.
- Gói không được ký: chuỗi của nó cho thấy một chỗ sửa hay một chỗ ghép, không cho thấy ai đã ghi. Hộp thoại của owner quyết định cái gì vào não trái.
- Chỗ giữ chỗ che một đường dẫn trước người đọc không đoán ra được nó: hash mà một dòng bị đổi giữ lại xác nhận một lần đoán.
- Nguồn gốc của một mục là lời của gói: một gói được dựng có thể tự nhận một nguồn gốc, và nhờ đó làm một mục, hay một mục thật đến sau, bị tính là đã có ở đây. Bằng chứng của nó không bao giờ đi tới một mục chỉ tự nhận là tiếp nối mục khác.
- Brain có giúp ích hay không chưa được chứng minh ở cỡ của phép thử thoát cấp đầu; xem [Phép thử thoát cho thấy gì](#phép-thử-thoát-cho-thấy-gì).
