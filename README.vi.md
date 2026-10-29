[English](README.md) | Tiếng Việt

# vibemaestro-kit

Các plugin Claude Code giúp phiên lập trình của bạn có quy trình viết sẵn, luật tới đúng lúc cần, hành động đặc quyền an toàn và bộ nhớ sống sót qua compaction.

## Đây là gì

vibemaestro-kit là một marketplace Claude Code tên `vibemaestro`, gồm hai plugin. Kit làm cho một người xây dựng phần mềm bằng Claude Code trên một máy, với một seat Claude. Ghép lại, hai plugin biến một phiên Claude Code thành cách giao một thay đổi lặp lại được:

- quy trình từ yêu cầu tới pull request đã được review, ghi ngay trong repo của bạn để phiên sau bắt đầu từ những gì đã ghi;
- luật và phép kiểm chỉ tới phiên khi nó sửa file khớp hoặc chạy lệnh khớp;
- một cách có kiểm soát để chạy hành động ghi ra ngoài phiên (merge, force-push, xoá);
- một bộ nhớ nóng nhỏ mà phiên dài giữ được qua các lần compaction.

## Hai plugin

| Plugin | Mục đích | Tài liệu |
|---|---|---|
| `vibemaestro-sdlc` | Quy trình: intake, spec, plan, ship. Luật theo file hoặc lệnh, cổng CI, BatonRun. Dùng được ở mọi repo ứng dụng. | [plugins/vibemaestro-sdlc/README.vi.md](plugins/vibemaestro-sdlc/README.vi.md) |
| `vibemaestro-brain` | Bộ nhớ nóng sống sót qua compaction: lệnh `brain`, nhật ký chỉ ghi thêm, quyết định của bạn chỉ ghi qua hộp thoại cấp quyền. Cần `vibemaestro-sdlc`. | [plugins/vibemaestro-brain/README.vi.md](plugins/vibemaestro-brain/README.vi.md) |

Cài `vibemaestro-brain` thì `vibemaestro-sdlc` được cài theo.

## Yêu cầu

| Cần | Dùng cho |
|---|---|
| Claude Code (CLI `claude`); đã thử với 2.1.290 | mọi thứ; mục quyết định của brain cần 2.1.211 trở lên ở chế độ `auto` |
| `python3` 3.8 trở lên, `git`, `bash` | hook và script; đã thử trên Linux và macOS, chưa thử trên Windows; brain cần hệ POSIX |
| `gh`, đã đăng nhập (`gh auth login`) | issue theo dõi lúc intake, pull request lúc ship, ghi lên GitHub trong BatonRun |
| Một repo GitHub cho dự án của bạn | issue và pull request; không có remote thì intake vẫn ghi intent và branch, bỏ qua issue |

Lúc chạy, các plugin không phụ thuộc repo nào khác.

## Cài đặt

Thêm marketplace, rồi cài cả hai plugin. Chọn một trong hai cách.

### Từ GitHub

```bash
claude plugin marketplace add vibemaestro/vibemaestro-kit
claude plugin install vibemaestro-sdlc@vibemaestro
claude plugin install vibemaestro-brain@vibemaestro
```

### Từ bản clone

Dùng cách này để đọc mã nguồn trước, để thử một bản fork, hoặc khi không vào được GitHub lúc cài. Đưa thư mục của bản clone (`./` hoặc đường dẫn tuyệt đối) cho `claude plugin marketplace add`:

```bash
git clone https://github.com/vibemaestro/vibemaestro-kit.git
claude plugin marketplace add ./vibemaestro-kit
claude plugin install vibemaestro-sdlc@vibemaestro
claude plugin install vibemaestro-brain@vibemaestro
```

### Kiểm bản cài

Cả hai plugin phải hiện `Status: ✔ enabled`; `claude plugin install` trả về 0 cả khi thiếu dependency, nên hãy đọc danh sách này:

```bash
claude plugin list
```

### Cập nhật

Trong một phiên Claude Code, chạy `/plugin`, mở **Marketplaces**, chọn `vibemaestro` và cập nhật nó. Rồi chạy `/reload-plugins` để phiên đang chạy nạp bản mới (một phiên mới cũng nạp nó).

Từ shell: với bản cài từ clone, hãy pull bản clone trước:

```bash
git -C <clone> pull
```

Rồi, với cả hai cách:

```bash
claude plugin marketplace update vibemaestro
claude plugin update vibemaestro-sdlc@vibemaestro
claude plugin update vibemaestro-brain@vibemaestro
```

Rồi chạy `/reload-plugins` trong phiên đang chạy, hoặc mở phiên mới.

**Tự cập nhật.** Claude Code không tự cập nhật một marketplace bên thứ ba cho đến khi bạn bật nó: `/plugin`, **Marketplaces**, `vibemaestro`, **Enable auto-update**. Khi đó nó cập nhật plugin lúc một phiên mở và báo lại; chạy `/reload-plugins` để nạp bản mới.

**Lời nhắc cập nhật.** Khi có bản public mới hơn của vibemaestro-sdlc hay vibemaestro-brain, lúc mở phiên hiện một dòng: tên plugin, bản đang cài và bản mới, cách cập nhật, và link tới ghi chú phát hành. Mỗi plugin đọc tag của repo public tối đa một lần mỗi ngày, chạy nền, không token, và không gửi gì về bạn hay máy của bạn; nên dòng này hiện ở phiên sau lần đọc đó, tối đa một lần mỗi ngày cho mỗi plugin. Bản cài mà manifest không có version, như một clone của cây phát triển, không hiện gì. Để tắt nó:

- mọi nơi: đặt `VIBEMAESTRO_NO_UPDATE_CHECK` là `1`, chẳng hạn trong khối `env` của `~/.claude/settings.json`; biến `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` của chính Claude Code cũng tắt nó;
- trong một repo: `"update_check": false` trong `.vibemaestro/sdlc.json` của repo đó.

## Dùng lần đầu trong repo của bạn

Làm một lần. Mở một phiên Claude Code mới trong repo ứng dụng của bạn.

1. **Dựng `kb/`.** Bảo Claude chạy skill `vibemaestro-sdlc:init-kb`. Skill hỏi vài câu, rồi ghi thư mục `kb` (intent, spec, plan, quyết định và file hiện trạng) cùng một file cấu hình nhỏ `.vibemaestro/sdlc.json`, và không ghi đè gì. Một câu hỏi là ngôn ngữ của tài liệu `kb` và nội dung pull request: skill đề xuất tiếng Anh (`en`), hoặc tiếng Việt (`vi`) nếu bạn viết cho nó bằng tiếng Việt, và ghi câu trả lời vào cấu hình. Skill commit kết quả trên branch `chore/kb-init` và push lên: hãy mở pull request của nó và merge. Dù chọn ngôn ngữ nào, một số thông báo lỗi của script vẫn bằng tiếng Việt.
2. **Thiết lập BatonRun trên máy này (nên làm).** Một lần ghi đơn giản ra ngoài phiên (một bước, hoàn tác được bằng một lệnh trực tiếp, như một comment trên issue) là một lời gọi trực tiếp; một luồng ghi, hoặc một lần ghi không hoàn tác được hay cần bạn ký (merge, force-push), chạy thành một baton script, được giữ và gọi theo tên khi gặp lại. Push branch thường và mở pull request không phải baton. Không thiết lập thì mọi lệnh baton đều hỏi bạn; `local-parallel` merge qua baton. Bảo Claude thiết lập BatonRun trên máy này (skill `vibemaestro-sdlc:batonrun`, phần tham chiếu setup). Nó cài một launcher nhỏ và in ra một khối luật quyền; bạn thêm khối đó vào user settings của Claude Code (`/permissions`, hoặc `~/.claude/settings.json`). Plugin không bao giờ ghi settings của bạn. Skill `vibemaestro-sdlc:coordinator-bootstrap` làm cùng việc thiết lập đó trong một run bạn ký. Có khối này, các lệnh baton thường ngày chạy không cần hỏi, còn chữ ký của bạn và việc đổi chế độ thì luôn hỏi bạn. Chi tiết: [BatonRun, cài đặt quyền](plugins/vibemaestro-sdlc/docs/batonrun.vi.md#9-cài-đặt-quyền).
3. **Thêm một CI check (tuỳ chọn).** Merge có bảo vệ cần ít nhất một check xanh trên pull request. Skill `vibemaestro-sdlc:install-gates` thêm các cổng quy trình thành GitHub workflow; nó hỏi cổng nào và runner nào, và không bao giờ ghi đè file.

## Luồng làm việc

Mô tả một thay đổi bằng lời thường. Lời nhắc lúc mở phiên chỉ Claude tới `vibemaestro-sdlc:intake`, và Claude chỉ hỏi bạn ở chỗ cần một người quyết:

1. **Intake.** Claude ghi nguyên văn yêu cầu của bạn thành `kb/intent/<date>-<slug>.md`, tạo branch `intent/<date>-<slug>` trong một git worktree riêng, và mở một issue theo dõi.
2. **Brainstorm**, chỉ khi yêu cầu còn mơ hồ. Claude hỏi những câu chọn ra hướng đi và ghi câu trả lời vào intent.
3. **Spec.** Claude viết `kb/specs/<date>-<slug>.md` theo bốn mục: bối cảnh, mục tiêu, ngoài phạm vi, tiêu chí chấp nhận, trong đó mỗi tiêu chí là một lệnh và kết quả mong đợi. **Bạn duyệt spec trước khi sửa bất kỳ dòng code nào**, hoặc nói cần đổi gì.
4. **Plan**, chỉ khi việc cần nhiều pull request: một file plan, mỗi pull request một dòng.
5. **Ship.** Claude làm việc, cập nhật `kb/current-state.md`, chạy các lệnh nghiệm thu và mở một pull request nháp kèm output thật của chúng làm bằng chứng.
6. **Review.** Trước khi pull request rời trạng thái nháp, một subagent có ngữ cảnh mới review diff cuối; phiên sửa những gì nó tìm ra, rồi chuyển pull request sang ready (`gh pr ready`) và báo bạn. Chuyển sang ready khởi động các cổng CI, nếu bạn đã cài.
7. **Merge.** Phiên đã viết thay đổi không tự merge nó. **Bạn merge pull request đã ready** trên GitHub, sau khi đọc.

Muốn làm nhiều việc cùng lúc, hãy gọi skill `vibemaestro-sdlc:local-parallel`. Phiên chính chia việc, mở một subagent cho mỗi việc (mỗi subagent trong worktree riêng, từ intake tới pull request nháp), chuyển từng spec cho bạn duyệt, kiểm lại từng pull request và merge nó qua merge có bảo vệ `kit:merge-pr`, vốn cần một CI check xanh (bước 3 của phần dùng lần đầu). Ở chế độ `manual`, mặc định, mỗi lần merge đó cần chữ ký của bạn.

Duyệt spec và review là luật phiên làm theo, không phải cổng chặn. Hook fail-open: lỗi không bao giờ chặn việc của bạn. Các cổng CI, nếu bạn cài, kiểm hình thức commit, văn bản nhạy cảm, tiêu đề, nội dung pull request, bằng chứng review và branch chết. Bức tranh đầy đủ, theo từng giai đoạn và so với hướng dẫn của Anthropic: [docs/ai-native-sdlc.vi.md](docs/ai-native-sdlc.vi.md).

## Brain

Một phiên chạy nhiều giờ hay nhiều ngày sẽ bị compaction khi ngữ cảnh đầy, và bản tóm tắt có thể đánh rơi một quyết định bạn nói một lần hay một lỗi phiên đã mắc. Brain giữ vài mục ngắn bên ngoài repo (quyết định bạn ghim, cửa sổ cho phép, việc đang làm, bước tiếp theo và bẫy, tối đa 6.000 ký tự) và đưa chúng trở lại ngữ cảnh sau mỗi lần compaction.

Bạn hiếm khi gõ lệnh brain: Claude chạy chúng, theo skill `vibemaestro-brain:brain`. Một quyết định hay một cửa sổ của bạn chỉ được ghi sau khi bạn duyệt một hộp thoại cấp quyền một dòng của Claude Code, nên model một mình không thể bịa ra. `/matrix` cho thấy brain đang giữ gì và đã bơm gì vào. Brain có cần ở một cỡ phiên nào đó hay không vẫn là câu hỏi mở: xem [Bằng chứng](#bằng-chứng). Chi tiết: [plugins/vibemaestro-brain/README.vi.md](plugins/vibemaestro-brain/README.vi.md).

## Mô hình an toàn

BatonRun là cách phiên thực hiện một luồng ghi ra ngoài phiên, vượt quá một lần ghi đơn giản (chuẩn đầy đủ: [plugins/vibemaestro-sdlc/docs/batonrun.vi.md](plugins/vibemaestro-sdlc/docs/batonrun.vi.md)).

- Một baton script giữ cả chuỗi lệnh. Nó được kiểm, diễn tập để hiện từng lần ghi, rồi ký. Chữ ký gắn với hash của script nên mọi sửa đổi về sau làm nó mất hiệu lực.
- Sau đó run được kiểm lại, hoàn tác nếu kết quả sai, và ghi nhật ký. Bạn không bao giờ phải gõ lệnh theo chỉ dẫn.
- Bạn chọn chế độ: `manual`, mặc định (bạn ký mọi run), hoặc `auto` (phiên tự ký run bình thường; run nằm trong danh sách dừng, như xoá không hoàn lại được, luôn hỏi bạn).

## Tài liệu

Mục lục là [docs/README.vi.md](docs/README.vi.md). Nó liệt kê hai plugin, SDLC AI-native, BatonRun và các nghiên cứu đi kèm.

## Bằng chứng

Các ghi chú nghiên cứu nêu những gì đã biết về chi phí token của BatonRun và về lợi ích của brain, kể cả điều các phép thử chưa cho thấy: brain chưa được chứng minh là cần thiết ở cỡ đã thử. Ghi chú thứ ba đo plugin sdlc tốn bao nhiêu và đem lại gì trên việc của app: không có khác biệt đo được về chi phí cho mỗi việc làm đúng (0,76–1,25 theo cách chấm đã đặt trước khi việc cuối chạy). Chúng nằm ở [docs/research/](docs/research/).

## Phát hành

Mỗi plugin có version riêng. Một bản phát hành được gắn tag `<plugin>--v<version>` trong repo công khai `vibemaestro/vibemaestro-kit`, và có một GitHub Release cùng tên. Ghi chú của nó là mục của version đó trong `CHANGELOG.md` của plugin, kèm **Upgrade notes** (điều người dùng hiện có phải làm hay sẽ thấy), và cách cập nhật. Kit không có trong thư mục plugin của Anthropic.

## Đóng góp

Kit không nhận pull request. Hãy mở issue ở [Issues của `vibemaestro/vibemaestro-kit`](https://github.com/vibemaestro/vibemaestro-kit/issues) để hỏi, báo lỗi hoặc đề xuất; người bảo trì phân loại chúng bằng tay. Muốn chạy plugin từ một bản checkout hay một bản fork, hoặc chạy các bộ test, hãy đọc [DEVELOPMENT.vi.md](DEVELOPMENT.vi.md).

## Báo cáo bảo mật

Nếu bạn thấy một lỗ hổng hoặc một secret bị lộ, hãy báo cáo riêng tư: mở tab Security của repo và chọn **Report a vulnerability**, hoặc vào thẳng [https://github.com/vibemaestro/vibemaestro-kit/security/advisories/new](https://github.com/vibemaestro/vibemaestro-kit/security/advisories/new). Đừng báo cáo trong issue công khai.

## Giấy phép

Apache License 2.0: xem file `LICENSE` và `NOTICE` ở gốc repo. Mỗi thư mục plugin mang một bản sao của cả hai file.
