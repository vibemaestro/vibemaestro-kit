[English](README.md) | Tiếng Việt

# vibemaestro-brain

Một "bộ não thứ hai" cho các phiên Claude Code chạy dài. Plugin giữ quyết định, cửa sổ ủy quyền, việc đang làm, các bước tiếp theo và các bẫy của phiên trong một nhật ký nhỏ nằm ngoài repository, rồi đưa nhật ký đó trở lại context sau mỗi lần nén (compaction).

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

Brain giữ các mục ngắn thuộc tám loại, chia làm ba phần.

| Phần | Loại | Chữ | Là gì | Số mục còn sống tối đa |
|---|---|---|---|---|
| bộ nhớ nóng | Quyết định đã ghim | `D` | quyết định owner đã nói, kèm nguyên văn lời owner | 10 |
| bộ nhớ nóng | Cửa sổ | `W` | việc owner cho phép làm không cần hỏi, đến một thời điểm | 5 |
| bộ nhớ nóng | Đang làm | `N` | việc đang làm | 3 |
| phiên | Phiên | `S` | một phiên đang chạy: bước tiếp theo của nó, kèm con trỏ (PR, intent, record) | 12 |
| phiên | Hàng chờ owner | `Q` | việc đang chờ owner | 5 |
| kế hoạch | Tiếp theo | `X` | các bước tiếp theo | 10 |
| kế hoạch | Bẫy | `T` | một lỗi cần tránh, đếm mỗi lần gặp lại | 13 |
| kế hoạch | Sự kiện | `F` | một đường dẫn hay sự kiện đang dùng (`~/…` hoặc tương đối với gốc plugin) | 5 |

Mỗi văn bản dài tối đa 150 ký tự, của phiên là 450. Phần kế hoạch còn hiện **Done**: các mục Now, Next, phiên và hàng chờ mà nhật ký đã đóng trong 24 giờ qua, mới nhất trước, tối đa 7 dòng rồi một dòng đếm, mỗi dòng `- X5 owner/name#N <commit merge> · <văn bản>` (anchor và commit trước, văn bản sau cùng, nên văn bản dài là phần bị cắt). Không gì ghi Done: nó được đọc từ nhật ký. Dưới mỗi quyết định đã ghim, một dòng hiện lời owner, `  "<nguyên văn, tối đa 120 ký tự>" · <nơi nói, tối đa 30>`.

**Ba chuỗi, mỗi chuỗi dưới mức trần của Claude Code.** Claude Code chuyển nguyên vẹn chuỗi của một lệnh hook tới mô hình nếu dài tối đa 10.000 ký tự, đếm theo đơn vị UTF-16 (một emoji tính là 2), và thay chuỗi dài hơn bằng một bản xem trước ngắn. Vì vậy mỗi phần là một lệnh `SessionStart` riêng, và mỗi chuỗi nằm dưới mức trần đó do cách dựng, không bao giờ nhờ việc thay thế:

| Chuỗi | Chứa | Tối đa |
|---|---|---|
| `# vibemaestro-brain` | bộ nhớ nóng (bản render tối đa 6.000 ký tự) và Shelf index | 8.000 |
| `## Brain · sessions` | các phiên và hàng chờ owner | 9.500 |
| `## Brain · plan` | Next, Traps, Done và Facts | 9.500 |

Mỗi giới hạn là một nhát cắt cứng ở ranh giới dòng, nêu tên phần bị cắt; ở các mức trần trên, với mọi dòng đầy và mọi ghi chú, không chuỗi nào chạm tới nó. Chuỗi không có gì để hiện (các mục trống, không ghi chú) được bỏ qua. Claude Code chạy song song các lệnh của một plugin trong cùng một sự kiện, nên lệnh của chuỗi thứ nhất đọc nhật ký, tra anchor và render cả ba phần một lần, rồi trao cho hai lệnh kia chuỗi của chúng; mỗi lệnh nhận phần của mình đúng một lần.

Kho lưu trữ theo các quy tắc sau:

- **Một nhật ký thao tác là sự thật.** `hot.jsonl` chứa một thao tác mỗi dòng. Mỗi dòng mang SHA-256 của dòng trước nó, và `head.json` giữ phần đuôi. Mỗi lần ghi đều kiểm tra toàn bộ chuỗi và phần đầu (head) trước. Nhật ký bị cắt hoặc sửa tay sẽ chặn mọi lần ghi (rc 5).
- **Chỉ có thao tác trên mục.** Các thao tác là `add`, `close`, `supersede`, `touch` và `hit`, cùng một thao tác brain tự ghi, `link-close`: mục Now, Next, phiên hoặc hàng chờ tự đóng khi issue hay PR nó nêu bằng `--closes` đã xong (xem [Tự đóng](#tự-đóng)). Không có sửa, thay thế hay nhập hàng loạt. Một `supersede` giữ cả hai mục, mang theo mọi anchor, và giữ ít nhất 60% văn bản đầu tiên của chuỗi, trừ khi bạn truyền `--shorter` kèm lý do.
- **Hạn mức ngừng dùng.** `brain op close` và `brain op supersede` bị từ chối khi phiên đã cho 5 mục nghỉ trong 30 phút gần nhất (các lần cho nghỉ của owner cũng được tính). Một đợt dọn có chủ đích truyền `--bulk`, và nhật ký ghi lại điều đó. Mục phiên hay hàng chờ là trạng thái, không phải quyết định: `supersede` của nó (bước tiếp theo mới) không tốn hạn mức và có thể ngắn hơn 60%.
- **Anchor.** Một mục có thể mang anchor: các chuỗi chính xác mà bản tóm tắt phải giữ, như số PR, SHA 7 ký tự hex, đường dẫn hay một từ mã. Sau mỗi lần nén, brain ghi một *điểm mất mát* (loss score): tỷ lệ anchor của các mục còn sống mà bản tóm tắt đã làm rơi.
- **Mục của owner đi qua hộp thoại xin quyền.** Chỉ owner mới tạo hoặc đổi được mục `D` hay `W`. Lệnh là `brain owner …`, và nó chỉ ghi sau khi owner duyệt một hộp thoại xin quyền một dòng của Claude Code, ví dụ `Pin owner decision D3, from "<where>": "<text>"`. Không có hộp thoại được duyệt thì lệnh dừng với rc 6. Một mô hình đơn độc không ghi được mục owner. Hộp thoại không có ở chế độ `dontAsk`, `plan` và `bypassPermissions`, trong một lần chạy `-p`, trong subagent, và khi có hook `PermissionRequest` hoặc `--permission-prompt-tool` có thể trả lời thay con người. Trong các trường hợp đó phiên báo cho owner, không thử cách khác.
- **Không có bí mật.** Mọi văn bản đi qua bộ lọc giá trị nhạy cảm của vibemaestro-sdlc (`gates/pr_sensitive.py --text`). Có một lần trúng, hoặc thiếu bộ lọc, thì lần ghi bị từ chối. Brain cũng từ chối ký tự điều khiển và ký tự định dạng, ký tự hiển thị thành khoảng trống, và văn bản trống.
- **Một người ghi.** Phiên đầu tiên ghi sẽ sở hữu brain của dự án. Phiên khác cần `brain claim --take-over`, và nhật ký ghi lại việc đó. Một phiên worker (phiên có đặt cả `INTENT_SLUG` và `SEAT`, như một công cụ mở phiên thay bạn có thể đặt) không bao giờ ghi (rc 4).

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
brain render --check                   # kích thước và số mục so với mức trần
brain doctor                           # chuỗi, cache, bộ lọc, quyền file
brain matrix                           # brain đang giữ gì, từng ô một
```

`brain render --check` in, ví dụ:

```text
hot memory render: 208 of 6,000 characters
  Pinned (owner): 0 of 10
  Windows: 0 of 5
  Now: 1 of 3
sessions render: 180 of 9,500 characters
  Sessions: 1 of 12
  Owner queue: 0 of 5
plan render: 246 of 9,500 characters
  Next: 1 of 10
  Traps: 1 of 13
  Done (24 h): 0
  Facts: 0 of 5
```

`brain render` in ba phần mà các hook đưa vào context:

```text
## Brain · hot memory v5 · 208/6,000 chars   (re-injected after compaction; change only with `brain op` or `brain owner`)
Pinned (owner)
Windows
Now
- N1 Write the README · since 10-19
Matrix: `brain matrix`

## Brain · sessions v5 · 180/9,500 chars   (re-injected after compaction; change only with `brain op`)
Sessions
- S1 docs-run: README review, then the PR · since 10-19
Owner queue

## Brain · plan v5 · 246/9,500 chars   (re-injected after compaction; change only with `brain op`; Done is derived)
Next
- X1 Run every command · since 10-19
Traps
- T1 Never hand-edit the state directory · since 10-19 (hits 0)
Done (24 h)
Facts
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
| `SessionStart` (mọi nguồn: startup, resume, clear, compact, fork) | Ba lệnh đưa vào ba chuỗi (xem [Cách hoạt động](#cách-hoạt-động)): bộ nhớ nóng, rồi Shelf index (các skill Claude có thể gọi, tối đa 1.000 ký tự), tối đa 8.000 ký tự; phiên và kế hoạch, mỗi chuỗi tối đa 9.500, bỏ qua khi trống. Chuỗi dài hơn bị cắt ở ranh giới dòng và chỗ cắt được nêu tên. Mục Now, Next, phiên, hàng chờ hoặc đã ghim còn sống mà anchor là issue đã đóng hoặc PR đã merge hay đã đóng được thêm dấu `stale:` (xem [Anchor đã cũ](#anchor-đã-cũ)). Với người ghi của dự án, mục có mọi anchor `closes` đã xong được đóng trước, và một dòng ghi chú trong chuỗi của nó nói ra điều đó (xem [Tự đóng](#tự-đóng)). |
| `PreCompact` | Ghi lý do nén và kích thước context, đọc từ phần đuôi của transcript. Cộng các lần gọi API kể từ vị trí byte đã lưu lần trước vào tổng chi phí đang chạy của phiên. Không bao giờ chặn việc nén. |
| `PostCompact` | Lưu bản tóm tắt vào `summaries/` (quyền 0600, không bao giờ được đưa vào context, giữ 200 bản mới nhất) và ghi điểm mất mát. |
| `SessionEnd` | Xóa các bản ghi hộp thoại đang chờ của phiên, ghi lần kết thúc, và thêm một dòng `cost` từ các tổng đã lưu. Phiên chưa từng nén thì không có dòng `cost`: ở bước này transcript không được đọc. |
| `PreToolUse` trên Bash, `brain op …` | Từ chối việc ghi bộ nhớ nóng từ một subagent. |
| `PreToolUse` trên Bash, mọi lệnh | `guard-owner`: với một lệnh bắt đầu bằng `brain owner` (`brain` trên `PATH`, một đường dẫn tới `bin/brain`, hoặc `python3` chạy `scripts/brain.py`), hỏi owner bằng dòng hộp thoại, hoặc từ chối. Với lệnh khác, nó không đưa ra quyết định nào, kể cả lệnh chỉ nhắc tới hai chữ đó: thân một here-document, một chuỗi trong ngoặc, một `echo` hay một `grep`. |
| `PreToolUse` trên Edit, Write, NotebookEdit | Từ chối việc sửa file dưới thư mục gốc trạng thái của brain. |

Khi `guard-owner` từ chối, nó nêu lý do: do subagent, do lệnh không "nguyên văn" (hãy viết một lệnh `brain owner …` đứng riêng trong lệnh Bash, không dùng biến, thay thế lệnh, dấu gạch ngược, glob, `~` hay chuyển hướng), do chế độ không có hộp thoại, hoặc do có thứ trả lời thay, như hook `PermissionRequest`.

Mọi hook im lặng khi `BRAIN_OFF` được đặt (khác rỗng và khác `0`) và trong phiên worker. Ba hook đầu cũng im lặng trong dự án chưa có bộ nhớ nóng, và `SessionEnd` không ghi gì khi dự án chưa có thư mục trạng thái. Hook luôn "lỗi thì cho qua": một lỗi chỉ là một dòng trên stderr và không bao giờ chặn phiên.

Episode Log, `episodes.jsonl`, chứa một dòng cho mỗi lần phiên bắt đầu, lần gọi owner, lần phiên kết thúc, chi phí và lần tự đóng, và hai dòng cho mỗi lần nén (một dòng `pre-compact` và một dòng `compact`). `templates/compact-instructions.md` là khối `# Compact instructions` bạn có thể dán vào `CLAUDE.md` của dự án để chính bản tóm tắt giữ lại quyết định của owner, cửa sổ, PR đang mở, các phiên, bộ hẹn giờ và việc đang làm. Bạn tự đặt nó bằng tay.

## Lệnh

`bin/brain` chạy `scripts/brain.py`. Mỗi lệnh in `brain: …` trên stderr khi dừng.

| Lệnh | Làm gì | Mã thoát |
|---|---|---|
| `brain op add --kind now\|next\|trap\|session\|queue\|fact --text T [--link L]… [--anchor A]… [--closes A]… [--expires ISO]` | Thêm một mục thuộc loại đó; `--closes` (chỉ Now, Next, phiên và hàng chờ, tối đa 2) nêu issue hoặc PR mà khi nó đóng nghĩa là mục đã xong. | 0; 1 bị từ chối; 3 không phải người ghi; 4 worker; 5 nhật ký hỏng |
| `brain op close ID --reason R [--pointer P] [--bulk]` | Đóng một mục là đã xong hoặc đã bỏ. | như trên |
| `brain op supersede ID --text T --reason R [--drop-anchor A]… [--anchor A]… [--closes A]… [--shorter] [--bulk]` | Thay một mục bằng mục mới; giữ cả hai trong nhật ký. Mục mới mang theo `closes` của mục cũ, trừ khi `--closes` nêu cái riêng. | như trên |
| `brain op close-linked` | Đóng mọi mục có mọi anchor `closes` đã xong, theo lần tra mới, không giới hạn 5 mục một lúc. In ra mục đã đóng và mục bỏ qua, kèm lý do. | như trên; 1 không tìm thấy `gh` |
| `brain op touch ID` | Đánh dấu một mục vẫn còn hiệu lực. | như trên |
| `brain op hit ID` | Đếm một cái bẫy gặp lại (chỉ với bẫy). | như trên |
| `brain owner add --kind decision\|window --text T --owner-quote Q --where W [--anchor A]… [--link L]… [--expires ISO]` | Ghim một quyết định của owner, hoặc cấp một cửa sổ (cửa sổ cần `--expires`, một thời điểm trong tương lai). | 0; 6 chưa có hộp thoại được duyệt; còn lại như trên |
| `brain owner unpin ID` | Cho một mục của owner nghỉ. | như trên |
| `brain owner supersede ID --text T` | Thay một mục của owner. | như trên |
| `brain owner promote ID POINTER` | Chuyển một mục của owner ra khỏi bộ nhớ nóng sang một con trỏ (ví dụ một file quyết định). | như trên |
| `brain claim [--take-over]` | Nhận vai người ghi; `--take-over` nhận từ phiên khác, và nhật ký ghi lại. | 0; 3 người ghi khác hoặc không có session id; 4 worker |
| `brain render [--check]` | In ba phần; `--check` in kích thước từng phần so với mức trần của nó và số mục từng loại thay vào đó. | 0; 1 vượt một mức trần hoặc chưa có trạng thái; 5 nhật ký hỏng |
| `brain doctor [--path]` | Kiểm tra chuỗi, head, cache, quyền file, bộ lọc, các thứ có thể trả lời thay và phiên bản Claude Code, liệt kê mọi mục đã đóng trong 24 giờ qua (Done hiện 7), và tra các anchor của mục còn sống (một dòng `warn` cho mỗi anchor đã cũ, và việc tự đóng sẽ làm hoặc đã làm); `--path` in thư mục trạng thái. | 0; 1 có vấn đề, mỗi vấn đề được nêu tên |
| `brain matrix [--json]` | In Brain Matrix. Xem [Mô hình chi phí](#mô-hình-chi-phí). | 0 |
| `brain cost TRANSCRIPT [--merge-log F] [--json]` | Tính giá lượng token dùng của một transcript. Xem [Mô hình chi phí](#mô-hình-chi-phí). | 0; 2 không đọc được |

Mọi lệnh thoát 64 khi dùng sai cú pháp và 70 khi lỗi nội bộ (được nêu tên, không bao giờ là traceback). `brain op` không bao giờ đụng vào mục `D` hay `W`: `close` hay `supersede` chỉ áp dụng cho mục `N`, `X`, `T`, `S`, `Q` và `F`.

`brain owner` chặt chẽ, vì hộp thoại xin quyền hiện đúng các token mà lệnh chạy. Hãy viết đầy đủ từng tùy chọn, đưa giá trị làm đối số kế tiếp (không dùng `--opt=value`; giá trị có thể bắt đầu bằng `-`), và chỉ đưa tùy chọn một giá trị một lần. Văn bản, nguồn (`--where`) và con trỏ không được chứa dấu nháy kép. `--owner-quote` là lời của owner, nguyên văn; `--where` nói lời đó được nói ở đâu.

Khi một thao tác đã vào nhật ký mà cache không ghi lại được, thao tác vẫn có hiệu lực (rc 0, kèm cảnh báo) và lần đọc sau gấp lại nhật ký.

## Skill

| Skill | Ai gọi | Làm gì |
|---|---|---|
| `brain` | Claude, khi một phiên cần giữ quyết định, cửa sổ, việc đang làm, bước tiếp theo hoặc bẫy qua các lần nén | Dạy các quy tắc ở trên: khi nào chạy `brain op`, cách ghi mục owner qua hộp thoại, ý nghĩa từng mã thoát, cách nhận lại vai người ghi sau `/clear` hoặc `--fork-session`. |
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

Anchor là chuỗi chính xác mà bản tóm tắt phải giữ (`--anchor`). Khi một mục Now, Next, phiên, hàng chờ hoặc quyết định đã ghim còn sống có anchor là issue đã đóng, PR đã merge hoặc PR đã đóng, brain nói ra điều đó và không đụng vào mục: chỉ người ghi mới đóng hoặc thay thế nó, bằng `brain op` (quyết định đã ghim thì owner, bằng `brain owner`). Ngoại lệ duy nhất là các anchor `closes` của chính mục (xem [Tự đóng](#tự-đóng)). Việc tra dùng `gh` với tài khoản của chính nó, luôn trên `github.com` (`--hostname github.com`).

- **Anchor nào.** Chỉ anchor nguyên chuỗi, một trong ba dạng:
  - `owner/name#N`, kiểm đúng như viết;
  - URL issue hoặc PR của GitHub, `https://github.com/owner/name/issues/N` hoặc `https://github.com/owner/name/pull/N` (sau số không có gì nữa), kiểm như chính `owner/name#N` đó;
  - `#N` trần, kiểm trong repository nêu ở `BRAIN_DEFAULT_REPO`.

  Hai dạng đầu không cần đặt gì, nên là dạng dùng cho phiên làm việc trên nhiều repository. Mọi anchor khác, và mọi con số trong văn bản của mục, bị bỏ qua. Bẫy, cửa sổ và sự kiện không được kiểm.
- **Ghi anchor trần.** `brain op add`, `brain op supersede`, `brain owner add` và `brain owner supersede` in thêm một dòng `warning:` sau thông báo thường lệ khi mục Now, Next, phiên, hàng chờ hoặc quyết định đã ghim được ghi mang `#N` trần mà `BRAIN_DEFAULT_REPO` chưa đặt hoặc không phải `owner/name`. Dòng đó nêu từng anchor trần và dạng nên viết thay. Nó không bao giờ từ chối: mục vẫn được ghi và mã thoát là 0. Một `supersede` nêu cả các anchor trần mà nó mang sang (đổi bằng `--drop-anchor '#N' --anchor owner/name#N`).
- **`brain doctor`** tra từng anchor như vậy trên GitHub bằng `gh api` và in một dòng `warn` cho mỗi anchor đã cũ (`stale anchor: X5 #7 (owner/name#N) closed <date>`; `merged` cho PR đã merge, `closed unmerged` cho PR đóng mà không merge, `closed not planned` cho issue đóng vì không làm). Dòng của một quyết định đã ghim có thêm lệnh owner chạy (`owner retires it: brain owner unpin D3, or brain owner supersede D3 --text …`). Nó không đọc hay ghi cache, và một `warn` không đổi mã thoát. Với các mục còn sống có anchor nó không kiểm được (`#N` trần khi `BRAIN_DEFAULT_REPO` không dùng được), nó in số lượng và một dòng `info` cho mỗi mục và anchor (`not checked: X3 #7`), tối đa 20 dòng, rồi `not checked: +K more anchors`.
- **`SessionStart`** thêm ` · stale: #7 closed 2026-10-20` sau dòng của mục, chỉ trong các chuỗi được đưa vào (không ở `hot.md` hay `brain render`), và một dòng ghi chú `stale-anchor check:` trong chuỗi thứ nhất khi thiếu `gh`, một lần tra lỗi hoặc quá hạn, anchor trần bị bỏ qua vì `BRAIN_DEFAULT_REPO` chưa đặt, hoặc chưa phải anchor nào cũng có câu trả lời. Dấu và ghi chú cộng lại không quá 450 ký tự mỗi chuỗi.
- **Nhanh và an toàn khi không có mạng.** Câu trả lời được cache trong `stale-cache.json` ở thư mục trạng thái (600 giây; lần tra lỗi 120 giây). Mỗi `SessionStart` tra tối đa 12 anchor, anchor lâu chưa kiểm nhất trước, song song trong một hạn 2 giây, rồi bị dừng; nên mọi anchor đều được tới lượt sau vài lần phiên bắt đầu. Không có `gh` hoặc không có mạng nghĩa là không dấu và một dòng ghi chú, không bao giờ là lỗi.

## Tự đóng

Mục Now, Next, phiên hoặc hàng chờ có thể nêu issue hoặc PR mà khi nó đóng nghĩa là *mục này đã xong*, bằng `--closes` (tối đa 2, mỗi cái là `owner/name#N` hoặc URL issue hay PR của GitHub; `#N` trần bị từ chối, kể cả khi có `BRAIN_DEFAULT_REPO`). Hãy nêu chính việc của mục, không bao giờ nêu thứ mục đang chờ, và không bao giờ nêu issue theo dõi của nhiều PR. Anchor `closes` cũng là anchor, nên nó tính vào giới hạn 8 và được đánh dấu như các anchor khác.

- **Lúc ghi**, anchor được tra một lần (2 giây): lệnh in trạng thái và tiêu đề của nó (tiêu đề không được lưu), và từ chối (rc 1) anchor GitHub không biết và anchor mới đã merge hoặc đã hoàn thành, vì mục đó chỉ có thể bị đánh dấu, không bao giờ tự đóng. Một `supersede` giữ anchor mà mục đã nêu (mang sang, hoặc nêu lại) thì chỉ cảnh báo khi anchor đó đã xong: mục mới có thể tự đóng ở lần phiên bắt đầu tới, và `--drop-anchor` giữ nó còn sống. Không có câu trả lời (không có mạng, không có `gh`) thì lệnh vẫn ghi, kèm dòng `closes not checked: owner/name#N`.
- **Lúc `SessionStart`**, trong phiên đang ghi brain của dự án (lần `brain claim` cuối), một mục tự đóng khi mọi anchor `closes` của nó đã xong sau lúc mục nêu nó được ghi: PR đã merge vào nhánh mặc định của repository (lần tra thứ hai, `…/pulls/N`, kiểm nhánh đích), hoặc issue đã đóng là hoàn thành theo lần tra ngay trong lần phiên bắt đầu đó (câu trả lời issue từ cache không bao giờ làm đóng, vì issue có thể mở lại). Thao tác là `link-close`, kèm lý do, con trỏ, và trạng thái, thời điểm, commit merge của từng anchor; nó không tính vào hạn mức cho mục nghỉ. Chuỗi đã chứa mục hiện một dòng ghi chú, `auto-closed now: X5 (owner/name#N merged <month-day>)`, một lần, và mục chuyển sang Done.
- **Không bao giờ đóng:** PR đóng mà không merge hoặc merge vào nhánh khác, issue đóng vì không làm, vì trùng hoặc không có lý do, anchor còn mở, lần tra lỗi hoặc quá hạn, và mọi mục trong lần bắt đầu của phiên khác. Những mục này giữ dấu stale. Quyết định đã ghim, cửa sổ, bẫy và sự kiện không bao giờ tự đóng: ghim có anchor đã xong được đánh dấu `owner retires it`.
- **Đóng dồn bị giữ lại.** Khi hơn 5 mục sẽ đóng cùng lúc thì không mục nào đóng: chúng được đánh dấu, và ghi chú nói `auto-close held: N items at once; check brain doctor, then brain op close-linked`. `brain op close-linked` kiểm y như vậy bằng lần tra mới (20 giây, tối đa 40 anchor) và đóng mọi mục đạt.
- **Issue mở lại.** Trong 24 giờ sau một lần đóng, các anchor issue của mục đã đóng thỉnh thoảng được tra lại (tối đa 3 mỗi lần phiên bắt đầu). Cái nào mở lại sẽ thêm `reopened: X5 owner/name#N, re-add it with brain op add` vào dòng ghi chú; không có thao tác mở lại.
- **`brain doctor`** không ghi gì; nó in `would close:` cho mục mà lần phiên bắt đầu tới sẽ đóng, `auto-closed:` cho mỗi lần đóng trong 24 giờ qua, và các dòng mở lại.
- **Cập nhật.** Hãy khởi động lại mọi phiên của dự án trên phiên bản này trước khi có mục tự đóng hoặc trước khi ghi mục phiên, hàng chờ hay sự kiện: brain cũ hơn từ chối ghi vào nhật ký có `link-close` hoặc một trong các loại đó, và ngừng đưa bộ nhớ nóng vào mỗi khi nó phải đọc lại nhật ký đó. `brain doctor` cảnh báo phiên mà lần bắt đầu cuối chạy brain cũ hơn. Không hỗ trợ quay về phiên bản cũ hơn khi đã có một thao tác như vậy được ghi.

## Cấu hình

Brain không có file cấu hình. Nó đọc các biến môi trường sau.

| Biến | Tác dụng |
|---|---|
| `BRAIN_OFF` | Giá trị nào khác rỗng và khác `0` đều làm mọi hook im lặng. Dùng cho một lượt đối chứng. |
| `BRAIN_DEFAULT_REPO` | `owner/name`: repository mà anchor trần `#N` trỏ tới; anchor `owner/name#N` hay URL issue hoặc PR không cần nó (xem [Anchor đã cũ](#anchor-đã-cũ)). Đặt theo từng dự án trong khối `env` của `.claude/settings.json`. |
| `XDG_STATE_HOME` | Gốc của thư mục trạng thái; mặc định là `~/.local/state`. |
| `CLAUDE_CODE_SESSION_ID` | Do Claude Code đặt. Brain nhận ra người ghi qua biến này, và CLI tìm dự án của phiên qua nó. |
| `CLAUDE_PROJECT_DIR` | Do Claude Code đặt cho hook. Nó nêu dự án của phiên, và hook dùng nó để tìm skill và settings của dự án. |
| `INTENT_SLUG` và `SEAT` | Khi đặt cả hai, phiên là phiên worker: hook im lặng và việc ghi dừng với rc 4. |
| `HOME` | Nơi tìm thư mục trạng thái mặc định và settings cấp người dùng của Claude Code. |
| `CLAUDE_CONFIG_DIR` | Thư mục cấu hình của Claude Code (mặc định `~/.claude`). Brain đọc plugin đang bật, skill và settings ở đó, và tìm bộ lọc của vibemaestro-sdlc qua nó. |
| `CLAUDE_CODE_EXECPATH` | Do Claude Code đặt. Hook `guard-owner` chạy nó với `--version` để kiểm tra phiên bản. |
| `CLAUDE_CODE_REMOTE` | Do Claude Code đặt. Khi bằng `true`, `brain matrix` báo code intelligence là chưa khởi động. |

`BRAIN_TEST`, `BRAIN_TEST_PAUSE_MS`, `BRAIN_TEST_ASK_MODES` và `BRAIN_TEST_SOURCES` dành cho bộ test của chính plugin. Đừng đặt chúng: `brain doctor` cảnh báo khi `BRAIN_TEST` được đặt.

### Nơi lưu trạng thái

`$XDG_STATE_HOME/vibemaestro/brain/<project>-<12 hex>/`, hoặc `~/.local/state/vibemaestro/brain/…` khi `XDG_STATE_HOME` chưa đặt. Mỗi repository một thư mục, và mọi worktree của repository dùng chung. File có quyền 0600. `brain doctor --path` in thư mục đó. Brain không ghi gì vào repository.

Một phiên giữ một dự án, thư mục nó khởi động, dù shell của nó `cd` đi đâu. Hook đọc dự án từ `CLAUDE_PROJECT_DIR` và ghi lại theo session id; `brain`, chạy từ Bash của phiên, đọc bản ghi đó. Khi shell đang ở dự án khác, `brain` vẫn dùng dự án của phiên và in một dòng nêu cả hai. Bản ghi không tin được thì bị từ chối (rc 1), không đọc hay ghi gì. Ngoài một phiên Claude Code, hoặc trước khi hook nào chạy, dự án là dự án chứa thư mục hiện tại.

| File | Chứa |
|---|---|
| `hot.jsonl`, `head.json` | nhật ký thao tác và hash phần đuôi của nó |
| `hot.json`, `archive.jsonl`, `owner.json`, `hot.md` | các cache và bản render, dựng lại từ nhật ký |
| `asked/` | các bản ghi hộp thoại owner đang chờ |
| `lock` | khóa file mà mọi lần ghi đều lấy |
| `episodes.jsonl` | Episode Log |
| `summaries/` | các bản tóm tắt nén đã lưu (200 bản mới nhất) |
| `cost/` | tổng chi phí đang chạy và vị trí byte của từng phiên |

Còn hai thư mục nữa nằm cạnh các thư mục dự án dưới `…/vibemaestro/brain/`: `pending/` chứa một dấu cho mỗi phiên có bản ghi hộp thoại đang chờ lệnh của nó, và `sessions/` chứa một bản ghi cho mỗi phiên đang chạy, nêu dự án của nó (xoá khi phiên kết thúc, trừ sau `/clear` hay khi chuyển sang phiên khác, hoặc sau 30 ngày).

Đừng bao giờ sửa các file này. Một guard sẽ từ chối việc sửa, và một thay đổi bằng tay làm gãy chuỗi hash và chặn mọi lần ghi.

## Phụ thuộc vào vibemaestro-sdlc

`plugin.json` khai báo phụ thuộc vào `vibemaestro-sdlc`. Brain dùng hai thứ từ đó:

- **Bộ lọc giá trị nhạy cảm**, `gates/pr_sensitive.py`. Mọi lần ghi đi qua nó. Nếu thiếu bộ lọc, mọi lần ghi bị từ chối, và `brain doctor` báo một vấn đề.
- **Merge log**, mà `brain cost --merge-log` đọc để đếm các PR đã merge.

Claude Code không nạp một plugin mà phụ thuộc của nó chưa bật, nên hook của brain chỉ chạy khi vibemaestro-sdlc cũng được bật. Matrix liệt kê index của repository như một ô dùng chung: vibemaestro-sdlc đưa nó vào khi tùy chọn `current_state.inject` bật (mặc định tắt). Xem [vibemaestro-sdlc](../vibemaestro-sdlc/README.vi.md).

## Yêu cầu

- Claude Code. Mục của owner cần phiên bản 2.1.211 trở lên khi phiên chạy ở chế độ `auto`; `brain doctor` kiểm tra điều này.
- `vibemaestro-sdlc`, được cài cùng brain.
- Python 3.8 trở lên và `git` trên `PATH`. Các script chỉ dùng thư viện chuẩn.
- Hệ thống POSIX: kho lưu dùng khóa file `fcntl`.

## Giới hạn

- Chưa có recall và chưa tự loại bỏ mục: bạn hoặc Claude cho các mục nghỉ, trừ mục có `closes` đã xong (xem [Tự đóng](#tự-đóng)). Cửa sổ hết hạn được hiện là đã hết hạn nhưng không bị xóa.
- Cột token của Matrix là số ký tự ÷ 4, không phải số đo thực.
- Brain có giúp ích hay không chưa được chứng minh ở cỡ của phép thử thoát cấp đầu; xem [Phép thử thoát cho thấy gì](#phép-thử-thoát-cho-thấy-gì).
