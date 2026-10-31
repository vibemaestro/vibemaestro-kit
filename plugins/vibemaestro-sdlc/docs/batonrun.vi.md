[English](batonrun.md) | Tiếng Việt

# BatonRun

BatonRun là phương pháp vibemaestro dùng cho những hành động ghi ra ngoài phiên làm việc mà không chỉ là một lần ghi đơn giản: một luồng nhiều lần ghi lên GitHub, đẩy lên registry, đổi cấu hình Claude Code của người dùng, xoá dữ liệu, thay đổi trên hệ thống đang chạy. Tài liệu này là **chuẩn** của BatonRun: nguồn duy nhất cho câu hỏi BatonRun là gì, một run chạy ra sao và giới hạn nằm ở đâu. Mọi nơi khác trỏ về đây:

- skill `batonrun` ([`plugins/vibemaestro-sdlc/skills/batonrun/`](../skills/batonrun/SKILL.md)) giữ **chỉ dẫn vận hành** để viết một baton: các lệnh, tham số, khung script, những gì `check` từ chối, mã thoát, cách giữ hoặc sửa một baton. Tài liệu này đi kèm plugin đã cài (`docs/batonrun.md` ở gốc plugin), nhưng skill giữ đủ mọi chỉ dẫn một phiên cần, kể cả danh sách dừng, nên phiên không phải đọc nó;
- rule `batonrun` (`plugins/vibemaestro-sdlc/rules/batonrun.instructions.md`) là **lời nhắc** khi một lệnh đặc quyền bị gõ thẳng: một lần ghi đơn giản thì cứ làm, còn lại thành một run;
- runner [`plugins/vibemaestro-sdlc/scripts/baton.py`](../scripts/baton.py) là **cỗ máy**: khi code và văn bản này khác nhau thì code là thứ chạy, và chỗ khác nhau là lỗi của một trong hai.

Các phép đo và bài học đằng sau thiết kế nằm ở [`docs/research/batonrun.vi.md`](../../../docs/research/batonrun.vi.md). Muốn xem toàn bộ kit, bắt đầu từ [README](../../../README.vi.md).

## 1. BatonRun là gì

### Định nghĩa

Owner (chủ sở hữu) là người sở hữu repository và ký các run rủi ro: khi làm một mình, đó là bạn. Một **run** là một lần chạy hành động của một quy trình lặp lại: nhiều lệnh hoặc script theo một chuỗi cố định, thực thi như một khối có cổng kiểm soát. Phiên viết hoặc chọn run, máy kiểm tra và tổng duyệt (rehearse) nó, nó được ký một lần, phiên chạy nó, máy kiểm tra lại sau khi chạy, hoàn tác khi lỗi và ghi log. Owner không bao giờ phải gõ các dòng lệnh.

- **Một run, một cổng.** Cả chuỗi được trình bày, ký và chạy như một khối: chữ ký bao phủ mọi bước, nên không bước nào trong chuỗi chạy mà chưa ký, và không gì ngoài chuỗi chạy được bằng chữ ký đó.
- **Một lần ghi đơn giản không phải run.** Lần ghi chỉ một bước, hoàn tác được bằng một lệnh trực tiếp không nằm trong danh sách dừng, bản thân nó không nằm trong danh sách dừng, và không phải một luồng đã gặp trước đó thì là một lời gọi tool trực tiếp: một bình luận trên issue, một ticket mới. Mọi thứ khác là một run: một luồng nhiều lần ghi, một hành động không hoàn tác được (merge, push lên branch dùng chung), một hành động owner ký, và một luồng đã gặp trước đó. Một luồng bị cắt thành nhiều lần ghi đơn giản vẫn là một run (mục 8).
- **Một run do một baton script mang.** Script giữ chuỗi; các lệnh và script của plugin mà nó gọi là các bước của nó (`kit:merge-pr` chạy cổng merge; một session baton có thể chạy `open-pr.sh` như một lần ghi). Script là đơn vị kiểm tra và ký; run là đơn vị công việc và đơn vị log.
- **Lặp lại là điểm mấu chốt.** Quy trình lặp lại trở thành một baton đã giữ: một script chung khai báo tham số của nó, giữ một lần bằng `baton pack` và gọi theo tên với giá trị mới (mục 4). Lần sau chỉ là một lệnh `baton go <place>:<name> key='value'…`, không phải viết lại script.

### Tên gọi và hình ảnh

Hình ảnh là **cây đũa chỉ huy**: chỉ phiên chạy hành động cầm nó, và chưa có gì được chơi cho đến khi nó giơ lên. Nghĩa chạy tiếp sức không phải là ý định. Phương pháp là BatonRun, CLI là `baton`, một script là một baton script.

### Quan hệ với CodeAct

CodeAct là một thiết kế agent từ một bài báo ICML 2024, cũng được `CodeActAgent` của OpenHands dùng. BatonRun giữ lõi của CodeAct: hành động là code, không phải một lời gọi tool bằng JSON, nên nhiều tool kết hợp trong một bước với vòng lặp và nhánh, và agent đọc đầu ra rồi sửa script. Khác nhau ở chỗ tác dụng phụ được phép xảy ra. OpenHands làm chúng vô hại bằng sandbox nên vòng lặp của nó tự chạy. Một cluster thật, registry, GitHub hay cấu hình người dùng không thể đặt vào sandbox, nên BatonRun có một vòng trong không hệ quả (viết, check, rehearse, sửa) và một bước ngoài có cổng: một lần chạy đúng script đã ký.

### BatonRun không phải là gì

- **Không phải lá chắn chống một phiên cố tình lừa.** Nó bảo vệ một phiên trung thực nhưng có thể sai sót: quên một bước, sửa sau khi được duyệt, đổi tham số, thế giới đã thay đổi, chạy lần hai. Một phiên tự viết bản ghi, chạy script bằng `bash` thường, chép `baton.py` đi nơi khác hoặc dựng tên lúc chạy là đang giả mạo; chặn việc đó là việc của tool chỉ đọc và các rule deny của owner (mục 8).
- **Không phải sandbox.** Các lần ghi là thật. Rehearse chỉ cho thấy kế hoạch, không mô phỏng thế giới.
- **Không phải chốt chặn lệnh gõ tay.** Rule nhắc và hook cảnh báo; không cái nào từ chối lệnh.
- **Không phải chỗ để bí mật hay credential trong văn bản.** Baton script, các plan line và log của nó đều là văn bản thường, nên credential không thuộc về chúng.

## 2. Thuật ngữ

| Thuật ngữ | Nghĩa |
|---|---|
| owner | người ký các run cần người, và đặt chế độ (mode) |
| session | phiên Claude Code nói chuyện với owner và chạy baton thay owner; chữ ký tự động của nó được viết là `coordinator-auto` |
| run | một lần chạy hành động của một quy trình lặp lại, thực thi như một khối có cổng (mục 1); một dòng trong log |
| baton script | script bash mang một run: phần đầu (header), hành động, post-check, undo, cổng `write()`, và một `case` cuối theo các phase |
| session baton | baton script mà phiên viết cho việc đang làm, tại một đường dẫn mới; được giữ bằng `baton pack` ở lần thứ hai gặp luồng đó |
| kind | baton script có sẵn mà plugin cung cấp cho một dạng việc lặp lại, chạy bằng `kind:<name> <args>`; `new --from <kind>` ghi nó ra file để sửa |
| kit run | baton script mà plugin cung cấp và đã review, chạy bằng `kit:<name> …`; chỉ kit run mới được chạy một gate của plugin |
| baton đã giữ (kept baton) | baton script được giữ bằng `baton pack` ở đúng một nơi, `project:` (`.vibemaestro/batons/` của repository) hoặc `user:` (thư viện của máy này); nó chỉ chạy với đúng những byte mà bản ghi giữ của nó ghim, và được gọi là `<place>:<name>` kèm giá trị (mục 4) |
| Params | trường header khai báo các giá trị của một baton, các từ `key=type`; một lời gọi truyền các từ `key='value'`, mỗi giá trị được kiểm theo kiểu của nó trước khi bất cứ gì chạy (mục 3) |
| Usage | trường header của một kit hoặc kind gọi được: tóm tắt các cờ hay từ nó nhận, do chính code của nó kiểm |
| launcher | `<state-dir>/bin/baton`, lệnh cố định duy nhất mà các permission rule gọi tên; nó chạy `baton.py` mới nhất đã cài |
| state directory | `$XDG_STATE_HOME/vibemaestro/baton`, nếu không có thì `~/.local/state/vibemaestro/baton`: mode, chữ ký, log và đầu ra của các run; nằm ngoài mọi repository |
| phase | `rehearse`, `run`, `postcheck` hoặc `undo`: runner đặt `BATON_PHASE`, `case` cuối của script rẽ nhánh theo nó |
| plan line | dòng văn bản của một lời gọi `write "<plan line>" <command…>`: một lần ghi làm gì, với giá trị đã được phân giải (SHA đầy đủ, đường dẫn, repo, host) |
| Expect | các dòng header nói run phải sinh ra những plan line nào, mỗi lần ghi một dòng, dưới dạng shell glob |
| seal | mã băm mà rehearse in ra trên byte của script, tham số, thư mục, các biến điều hướng và kế hoạch; `sign` phải gọi đúng tên nó |
| signature | bản ghi rằng seal đã được duyệt, bởi `owner` hoặc `coordinator-auto`; một chữ ký cho phép một lần chạy |
| Stops | trường header nêu các nhóm trong danh sách dừng mà run đụng tới; `none` hoặc một từ bất kỳ của danh sách dừng (mục 6) |
| mode | quyết định thường trực của owner, `manual` hoặc `auto`, về việc ai được ký một run `Stops: none` |
| decision card | bản tóm tắt ngắn trình cho owner ngay trước khi owner ký (mục 6) |
| `go` | lệnh duy nhất làm trọn vòng đời (mục 3) |

## 3. Vòng đời

| Bước | Điều xảy ra | Bắt được gì |
|---|---|---|
| write | phiên tìm một baton đã giữ, kit hoặc kind bằng `baton list`, hoặc viết baton script: header (Purpose, Targets, Blast, Undo, Pre, Stops, Params, Expect), hành động với mọi thay đổi đi qua `write()`, một post-check, một undo | hành động được nêu trước khi chạy |
| check | kiểm tra tĩnh văn bản: các trường header, `Params` và cách script đọc giá trị của nó, cổng `write()` và cách rẽ phase đúng nguyên văn, `set -euo pipefail`, không ghi ngoài `write()`, không script cục bộ hay `source`, không `diff`/`grep`/`cmp` trần trong pipeline, mẫu dừng so với `Stops`, `bash -n`, `shellcheck -S error` nếu đã cài | lỗi cú pháp và hình dạng, một lần ghi bỏ qua cổng, một hành động dừng chưa khai báo |
| rehearse | các giá trị được kiểm theo `Params`; script chạy ở phase `rehearse`: mọi lần đọc đều chạy, mọi lần ghi chỉ in plan line; kế hoạch được so với Expect từng dòng, và từng plan line với Targets đã khai báo | lỗi logic, nhắm sai đích, thiếu điều kiện tiên quyết, kế hoạch không như ý định |
| seal | mã băm trên byte script, nơi giữ nó, các giá trị (và sha256 của mỗi giá trị là file), thư mục, các biến điều hướng công cụ, và kế hoạch | mọi thay đổi sau thời điểm này |
| sign | seal được duyệt, bởi phiên (`coordinator-auto`, chỉ mode `auto` và `Stops: none`) hoặc bởi owner trong một hộp thoại | một sự duyệt cho thứ khác với thứ đã được trình |
| run | rehearse lại, rồi phase `run`: dòng DO của mỗi lần ghi phải đúng kế hoạch đã ký; chữ ký bị dùng hết | thế giới đã đổi từ lúc ký, chạy lần hai |
| post-check with undo | phase `postcheck` (đọc lại sau 1, 2, 4 và 8 giây); khi lỗi thì phase `undo`, so từng đích với trạng thái trước | một lần ghi không giữ được; trạng thái làm dở bị bỏ lại |
| log | một dòng cho mỗi sự kiện trong `log.tsv` (thời gian, sự kiện, tên, mã băm script, binding, tham số, thư mục, người ký, mode, kết quả, đã undo, đường dẫn đầu ra); toàn bộ đầu ra nằm dưới `runs/` | một hành động không được kiểm toán |

**`go`** chạy các bước từ check đến log trong một lệnh và dừng ở bước đầu tiên lỗi, với mã thoát của bước đó và toàn bộ đầu ra của nó. Khi mọi bước đều đạt, nó in một dòng, `go: ok — <n> writes — <run log>`, và đó là tất cả những gì phiên báo cáo. Run cần owner (một từ Stops, hoặc mode `manual`, kể cả khi chưa chọn mode nào: mục 6) dừng sau rehearse với mã thoát 8 và các dữ kiện cho decision card; không có gì được ký và không có gì chạy. Các lệnh riêng (`check`, `rehearse`, `sign`, `run`, `log`) vẫn còn để owner ký và để chẩn đoán.

`go` chỉ chạy một session baton (và chỉ đọc một giá trị `input`, file `--spec` của `kit:gh-write` và file rule của `kind:settings-merge`) từ một file được ghi trong 120 giây gần nhất, để một lần Write không thành công không bị nhầm là script mới; `go --reuse` chỉ định một file cũ hơn mà những byte đó là ý muốn dùng lại. Baton đã giữ không có cổng này: nó chỉ chạy với những byte mà bản ghi giữ của nó ghim. Một session baton là một lần Write ra đường dẫn mới và `go <path>` trong cùng một lượt phản hồi. Dạng `go -` cũng tồn tại, nhưng nó không phải cách chạy một baton, vì Claude Code chặn heredoc chứa khung baton và heredoc là cách duy nhất để đưa dữ liệu vào nó (mục 8). Nó đọc script từ stdin, lưu một lần dưới state directory và chạy file đó, nên cùng một ràng buộc sha256 vẫn giữ từ check đến run.

### Lệnh

Mỗi lệnh có dạng `<launcher> <subcommand> …`. Khi chưa cài launcher (mục 9) hãy dùng `python3 <plugin root>/scripts/baton.py`. Các tuỳ chọn của runner đứng trước script; mọi thứ sau nó là của script: các từ `key='value'` cho baton có `Params`, các cờ hay từ mà `Usage` nêu cho một kit hoặc kind. Một script là một đường dẫn (session baton), `kit:<name>`, `kind:<name>`, `project:<name>` hoặc `user:<name>`; tiền tố khác, hoặc một tên trần, bị từ chối.

| Lệnh | Việc nó làm |
|---|---|
| `new <name> [--dir D] [--from <kind>]` | ghi `D/<name>.sh` từ template, hoặc từ một kind (`new --from <kind>`); không bao giờ ghi đè (mã thoát 6) |
| `check <script>` | kiểm tra tĩnh văn bản; mã thoát 0 hoặc 1 |
| `list [<keyword>…]` | một dòng cho mỗi baton (`kit:`, `kind:`, `project:`, `user:`) có tên, Purpose hoặc Params chứa mọi từ khoá, tối đa 25: ai ký, số lần chạy, `reviewed` hoặc `not reviewed, kept by …`, Purpose và Params hoặc Usage; khi chỉ một baton khớp, in toàn bộ mục của nó |
| `pack <path> <project\|user>:<name>` | giữ một script đã chạy ok: ghi `<place>/<name>.sh` và một bản ghi giữ ghim sha256 của nó; một lần giữ `user:` in một dòng `owner:` cho owner. `pack <project\|user>:<name> <nơi kia>:<name>` chuyển một baton đã giữ. Trong sandbox, một `<name>` trần là `project:<name>` và `user:` bị từ chối (mục 4) |
| `pack --retire <project\|user>:<name> <sha256>` | bỏ ghim một sha256; file vẫn còn |
| `rehearse <script> [args…]` | check, rồi phase rehearse; in kế hoạch so với Expect và seal |
| `sign --by owner\|coordinator-auto --seal <seal> <script> [args…]` | check, chính sách mode, rehearse lại, rồi bản ghi chữ ký; `--by` đứng đầu, một lần, thành hai từ; seal không phải cái đã trình thì bị từ chối (mã thoát 3); `--by owner` còn cần bản ghi mà hook của plugin viết khi mở hộp thoại của owner cho đúng lệnh đó, không có thì mã thoát 3 |
| `sign --by owner --queued <id>` | owner ký một mục trong hàng chờ, từ một phiên Claude Code của chính owner: cùng hook, hộp thoại và bản ghi dùng một lần; chữ ký được ghi vào mục (mục 6) |
| `run <script> [args…]` | lần chạy đã ký: rehearse lại, run, post-check, undo khi lỗi; một dòng `run: ok — <n> writes — <run log>` khi đạt |
| `run --queued <id>` | cùng lần chạy đó cho một mục đã ký trong hàng chờ, từ thư mục đã xếp hàng, một lần, trước khi hết hạn; plan phải bằng plan đã niêm phong |
| `go [--by coordinator-auto \| --queue] [--reuse] <script> [args…]` | check, rehearse, seal, sign, run, post-check và log trong một lệnh; vòng đời ở trên. Với `--queue`, một baton cần owner được xếp vào hàng chờ cho owner thay vì dừng ở mã thoát 8: một dòng nêu mục đó (mục 6). `<script>` là một đường dẫn, `kind:<name>`, `kit:<name>`, `project:<name>` hoặc `user:<name>`. `go -` lấy script từ stdin: không bao giờ dùng nó cho baton, Claude Code chặn |
| `log [--tail N]` | N dòng cuối của `log.tsv` (mặc định 20) |
| `log --last` | đường dẫn log của run mới nhất; nó được đặt trước khi script bắt đầu nên một run bị kill vẫn tìm được ở đây |
| `log --wait-names N1,N2,… [--timeout S] [--since T]` | chờ (tối đa 580 giây) đến khi dòng run mới nhất của mỗi script được nêu tên là ok; mã thoát 9 khi hết hạn |
| `log --queue` | các mục trong hàng chờ: pending, signed, expired, used hoặc damaged, mỗi mục kèm thẻ và lệnh kế tiếp |
| `log --wait-queued <id> [--timeout S]` | chờ (mặc định 580 giây, tối đa 24 giờ) đến khi mục được ký (mã thoát 0); mã thoát 3 khi mục không thể được ký nữa (hết hạn, đã dùng, hỏng, không có), 9 khi hết hạn chờ |
| `mode [manual\|auto]` | in mode phê duyệt, hoặc đặt nó (mục 6) |
| `mode remotes`, `mode trust\|untrust <remote>` | in danh sách remote của owner, hoặc thêm hay bỏ một remote ở dạng chuẩn `host/path` (mục 4); như mode, chỉ theo lời owner |
| `permissions --print` | in khối cài đặt người dùng cho bản cài này (mục 9) |
| `permissions --check [--settings F]…` | so các rule đang có với khối đó; không ghi gì; mã thoát 7 khi một rule thiếu, cũ hoặc không an toàn |
| `permissions --install-launcher [--force]` | chép launcher vào `<state-dir>/bin/baton`; một bản trong cache mà registry không còn ghi thì từ chối với mã thoát 10 và không ghi gì, trừ khi có `--force` |
| `help [<topic>]` | in tóm tắt lệnh, hoặc một file tham chiếu của skill: `act`, `kinds`, `kits`, `modes`, `permissions`, `setup`, `limits` |

### Mã thoát

| Mã | Nghĩa |
|---|---|
| 0 | xong |
| 1 | script không đạt check hoặc rehearse (không có dòng verdict, kế hoạch khác Expect hoặc Targets đã khai báo), hoặc `go` gặp một file hay giá trị `input` đã cũ; `pack`: nguồn không đạt check của một baton đã giữ |
| 2 | môi trường: không có `bash`, hoặc không ghi được state directory; `pack`: một khoá bị giữ 30 giây |
| 3 | bị từ chối, chưa chạy gì: không chữ ký nào khớp, mode không cho phép người ký, lệnh dừng trước phase run, hoặc một baton đã giữ không được ghim trên máy này và cũng không được review (mục 4); một mục hàng chờ chưa ký, hết hạn, đã dùng, hỏng, do chính phiên ký xếp hàng, hoặc không còn khớp; `log --wait-queued`: mục không thể được ký nữa; `pack`: không có lần chạy ok nào của đúng những byte này, những byte đó đã được giữ dưới tên khác, một Stops khác |
| 4 | run hoặc post-check của nó lỗi, và undo đã đưa trạng thái về như cũ |
| 5 | không rõ trạng thái: run lỗi và undo cũng lỗi, hoặc run bị ngắt (cả một lần `pack` bị ngắt: chạy lại đúng lệnh đó để hoàn tất); báo owner ngay |
| 6 | `new`: file đã tồn tại |
| 7 | `permissions --check`: một rule thiếu, cũ hoặc không an toàn |
| 8 | `go`: baton cần chữ ký của owner; chưa ký gì, chưa chạy gì |
| 9 | `log --wait-names`: một script được nêu tên chưa có dòng run ok khi hết hạn; `log --wait-queued`: mục chưa được ký khi hết hạn chờ |
| 10 | `permissions --check`, hoặc `--install-launcher` không có `--force`: vibemaestro-sdlc của phiên không phải bản đã cài (phiên mở trước một lần cập nhật plugin); khởi động lại Claude Code; không ghi gì |
| 64 | dùng sai cú pháp: một lời gọi không khớp `Params` (thiếu, thừa hoặc lặp một key, một từ không có `=`, một giá trị sai kiểu), một tiền tố lạ hoặc một tên trần; `pack`: không có nơi giữ ngoài sandbox, `user:` trong sandbox, một tên kit, kind hoặc tên bản sao; `mode trust`: không phải remote mạng; `go --queue` trong sandbox, không có session id, đi với `--by`, hoặc trên một baton mà phiên tự ký được; `--queued` với id sai dạng, người ký khác owner, hoặc thêm từ sau id |
| 66 | không đọc được script (không có baton đã giữ đó, không có gốc project), `log --last` khi chưa có run nào bắt đầu, hoặc `pack --retire` không có bản ghi của sha đó |

### Header

Mỗi baton script bắt đầu bằng các trường này, mỗi trường một dòng. `check` từ chối khi thiếu một trường, một trường xuất hiện hai lần hoặc `Expect` rỗng; `Each` chỉ dành cho kit script và thay cho các dòng `Expect`. Một baton khai báo `Params`, hoặc `Usage` nếu là kit hay kind gọi được; một baton đã giữ khai báo `Params` với ít nhất một key.

| Trường | Nội dung |
|---|---|
| `Purpose` | run làm gì, trong một câu; phiên tìm dòng này khi muốn tìm một run đã giữ |
| `Targets` | nó đụng tới những gì; ở baton có `Params`, là các mẫu đứng trước ` — ` (`{dest}`, `{dir}/**`, `{repo}#{issue}`, `{ns}/{pod}`), rồi đến lời văn: mỗi plan line nêu ít nhất một mẫu, và mọi từ là đường dẫn tuyệt đối, repository, URL hay `refs/` trong đó phải khớp một mẫu (bản sao của giá trị file được miễn; một từ như `--to=/x` không được đọc là đường dẫn, nên hãy viết đường dẫn thành một từ riêng). Targets không đọc được thành mẫu thì không được kiểm, và `pack` từ chối chúng |
| `Blast` | nhiều nhất nó có thể thay đổi gì |
| `Undo` | cách đưa về như cũ, hoặc những gì nó để lại |
| `Pre` | điều gì phải đúng trước khi chạy |
| `Stops` | `none`, hoặc một hay nhiều từ của danh sách dừng (mục 6); owner ký khi nó không phải `none` |
| `Params` | `none`, hoặc các từ `key=type`: `int`, `sha40`, `sha256`, `name`, `repo`, `ref`, `path` (tuyệt đối), `url` (https), `file` (một file có sẵn), `input` (một file được viết cho lời gọi này), `under:<dir>`, `enum:<a>\|<b>`. Mọi key đều bắt buộc và chỉ đưa một lần. Không giá trị nào chứa dấu cách, dấu nháy hay `$`, nên văn bản tự do (một tiêu đề, một nội dung) là một file `input`. Script đọc các giá trị một lần, trong một khối dòng `P_<KEY>="$<n>"` theo thứ tự khai báo; giá trị là file đến dưới dạng một bản sao chỉ đọc. Một bí mật (một khoá riêng, một token, một thông tin đăng nhập cụm) là một giá trị `path`, mà script đưa vào stdin của một lệnh và không bao giờ in ra: một giá trị `file` hay `input` được chép vào thư mục trạng thái (một lời gọi không tới được phase run thì xoá bản chép của nó khi kết thúc, trừ khi một tiến trình baton khác đang giữ nó; bản chép mà một run đã dùng được giữ lại, 200 bản mới nhất, cho tới khi một lời gọi sau với cùng các byte mà không chạy kết thúc), nên giá trị nào trông như vật liệu khoá (một header khoá riêng, một trường `client-key-data`, một token có dạng đã biết) bị từ chối (exit 64) |
| `Usage` | chỉ kit và kind gọi được: tóm tắt các cờ hay từ của chúng |
| `Expect` | một dòng cho mỗi lần ghi, là shell glob trên cả plan line, theo thứ tự (bên dưới) |
| `Each` | chỉ kit script: một glob cho mọi plan line, cho run mà số lần ghi đến từ đầu vào của nó (`kit:gh-write`) |

**Expect khớp thế nào.** Rehearse thu một plan line cho mỗi lời gọi `write()`, theo thứ tự chúng chạy, và so dòng thứ i với dòng `Expect` thứ i như một shell glob trên cả dòng, phân biệt hoa thường. `*` là một chuỗi ký tự bất kỳ (kể cả dấu cách và `/`), `?` là một ký tự. Đây không phải khớp tiền tố, và số dòng phải bằng nhau: thiếu hoặc thừa một dòng là một dòng FAIL. Ví dụ plan `create docs/a b.txt` khớp `create *`; plan `create docs/a.txt` không khớp `create`.

### Khung mẫu

Một baton script đạt `check`, và đạt `pack` khi đã chạy ok. Thay header, khối giá trị, hành động, post-check và undo; chép `write()`, `gh_state()` và `case` cuối nguyên văn. Để hỏi một đối tượng GitHub có tồn tại không, gọi `gh_state <api path>` như một câu lệnh riêng, rồi kiểm tra `$GH_STATE` (`exists` hoặc `absent`; giá trị khác thì script dừng).

```bash
#!/usr/bin/env bash
# Purpose: create one file holding the bytes of an input file
# Targets: {dest} — the file dest names
# Blast: that one file
# Undo: removes the file while it holds those bytes
# Pre: the file is absent
# Stops: none
# Params: dest=path body=input
# Expect: create *
set -euo pipefail
PHASE=${BATON_PHASE:-rehearse}
write() {
  local plan=$1
  shift
  case "$PHASE" in
    rehearse)
      printf 'PLAN %s\n' "$plan"
      printf '%s\n' "$plan" >> "${BATON_WRITES:-/dev/null}"
      ;;
    run | undo)
      printf 'DO %s\n' "$plan"
      printf '%s\n' "$plan" >> "${BATON_WRITES:-/dev/null}"
      "$@"
      ;;
    *)
      printf 'write called in phase %s: %s\n' "$PHASE" "$plan" >&2
      return 70
      ;;
  esac
}
gh_state() {
  local out rc=0 proto code
  out=$(gh api --include "$1") || rc=$?
  read -r proto code _ <<< "${out%%$'\n'*}"
  case "$rc $proto ${code%$'\r'}" in
    "0 HTTP/"*" 200") GH_STATE=exists ;;
    [1-9]*" HTTP/"*" 404") GH_STATE=absent ;;
    *)
      echo "gh_state $1: exit $rc: $proto $code" >&2
      exit 75
      ;;
  esac
}
P_DEST="$1"
P_BODY="$2"
holds() { [ -f "$P_DEST" ] && cmp -s "$P_DEST" "$P_BODY"; }
put() { cat -- "$P_BODY" > "$P_DEST"; }
act() {
  [ ! -e "$P_DEST" ] || { echo "REFUSE $P_DEST exists" >&2; return 3; }
  write "create $P_DEST" put
}
postcheck() { holds; }
undo() {
  if holds; then
    write "remove $P_DEST" rm -f -- "$P_DEST"
  fi
  ! holds
}
case "$PHASE" in
  rehearse) act; echo "VERDICT rehearse ok" ;;
  run) act; echo "VERDICT run ok" ;;
  postcheck) postcheck; echo "VERDICT postcheck ok" ;;
  undo) undo; echo "VERDICT undo ok" ;;
  *) echo "unknown phase: $PHASE" >&2; exit 64 ;;
esac
```

### Chạy thử

Đoạn này chạy khung mẫu từ đầu đến cuối trong một state directory tạm rồi giữ nó. Chạy trong bash, từ thư mục gốc của một bản checkout repository này, trong một phiên shell. Lưu khung mẫu ở trên thành `demo.sh` trong thư mục tạm, rồi chạy `go` trong vòng 120 giây sau khi lưu nó và viết file input (hoặc thêm `--reuse`).

```bash
BATON="python3 $PWD/plugins/vibemaestro-sdlc/scripts/baton.py"
export XDG_STATE_HOME="$(mktemp -d)" XDG_DATA_HOME="$(mktemp -d)"
DEMO="$(mktemp -d)"
# save the skeleton as "$DEMO/demo.sh", then:
cd "$DEMO"
printf 'hello\n' > body.txt
$BATON check demo.sh
$BATON rehearse demo.sh dest="$DEMO/out.txt" body="$DEMO/body.txt"
mkdir -p "$XDG_STATE_HOME/vibemaestro/baton" && printf 'auto\ndialog %032d\n' 0 > "$XDG_STATE_HOME/vibemaestro/baton/mode"   # chỉ cho state nháp: đổi mode thật là cú bấm của owner (các mode)
$BATON go demo.sh dest="$DEMO/out.txt" body="$DEMO/body.txt"
cat "$DEMO/out.txt"
$BATON pack demo.sh user:demo-put
$BATON list demo
$BATON log --tail 3
```

`XDG_STATE_HOME` và `XDG_DATA_HOME` trỏ mode, chữ ký, log và thư viện vào các thư mục dùng một lần, nên bản chạy thử không bao giờ đổi mode phê duyệt hay thư viện thật của bạn. Sau `mode auto`, phiên được tự ký run `Stops: none` này, nên `go` kết thúc bằng một dòng `go: ok` và `out.txt` chứa `hello`. Ở mode `manual`, cũng lệnh `go` đó dừng sau rehearse với mã thoát 8 và decision card cho owner. `pack` giữ script thành `user:demo-put` và in dòng `owner:` của nó; từ đó `go user:demo-put dest=… body=…` chạy nó với giá trị khác.

## 4. Khi nào một quy trình thành run, và run nằm ở đâu

**Một lần ghi đơn giản thì làm trực tiếp.** Một bước, hoàn tác được bằng một lệnh trực tiếp không nằm trong danh sách dừng, bản thân không nằm trong danh sách dừng, không phải một luồng đã gặp: phiên gọi tool luôn. Mọi thứ khác là một run, và phiên tìm một run có sẵn trước khi viết mới:

1. `baton list <keyword>`.
2. **Có một cái vừa** (cùng mục đích, đích và rủi ro): `baton go <place>:<name> key='value'…`, mỗi giá trị trong dấu nháy đơn, vì dòng lệnh của phiên là một shell. Văn bản tự do đến từ bên ngoài (tiêu đề một issue, một tin nhắn) đi vào một file `input` do phiên viết, không bao giờ lên dòng lệnh.
3. **Có một cái gần vừa:** phát triển nó tại chỗ (bên dưới), không bao giờ sao chép.
4. **Không có cái nào:** viết nó thành session baton có `Params`, chạy nó, và lần thứ hai gặp luồng đó thì giữ nó bằng `baton pack`.

**Run nằm ở đâu.**

| Run | Nằm ở | Chạy bằng |
|---|---|---|
| kit run | `plugins/vibemaestro-sdlc/batons/<name>.sh` (code plugin có phiên bản; các gate nó chạy nằm trong `gates/`) | `<launcher> go kit:<name> …` |
| kind | `plugins/vibemaestro-sdlc/templates/baton-kinds/` | `<launcher> go kind:<name> <args>` |
| run của plugin phụ thuộc | thư mục `batons/` của plugin đó (một plugin cùng marketplace phụ thuộc `vibemaestro-sdlc`) | `<launcher> go kit:<name> …` (`help kits`: cách tìm và tin nó) |
| project baton | `<project root>/.vibemaestro/batons/<name>.sh`, commit cùng repository và review trong pull request của nó | `<launcher> go project:<name> key='value'…` |
| user baton | `$XDG_DATA_HOME/vibemaestro/batons/`, nếu không có thì `~/.local/share/vibemaestro/batons/`: thư viện của máy này, ngoài mọi repository | `<launcher> go user:<name> key='value'…` |
| session baton | một đường dẫn mới do phiên viết (thư mục tạm); không bao giờ qua stdin (`go -` với heredoc baton bị chặn, mục 8) | `<launcher> go <path> …` |

Một lời gọi luôn nêu nơi giữ; không có tra cứu qua nhiều nơi, nên không gì trong một repository hay thư viện có thể thế chỗ một baton `kit:` hay `kind:`.

**Giữ: `baton pack`.** `pack <path> project:<name>` hoặc `pack <path> user:<name>` giữ một session baton đã chạy ok. Nó từ chối một script không có lần chạy `ok` nào của đúng những byte đó trong log, một script không đạt `check` của baton đã giữ (cần `Params` với ít nhất một key và `Targets` dạng mẫu), những byte đã được giữ dưới tên khác, một tên đã được giữ với `Stops` khác, một tên `kit:` hay `kind:` và một tên bản sao (`-v<digits>`, `-<7 hex trở lên>`). Nó ghi file và một bản ghi giữ trong state directory, ghim sha256: baton đã giữ chỉ chạy với những byte được ghim, ở mọi bước, nên một file sửa tay không gọi được cho đến khi được giữ lại. `pack` không commit; project baton được commit trên branch và review trong pull request của nó. User baton không ai review: `list`, dòng ký, dòng thành công của `go` và decision card ghi `not reviewed, kept by …`, và mỗi lần giữ `user:`, mới hay phát triển, in một dòng bắt đầu bằng `owner:` mà phiên chép vào câu trả lời kế tiếp cho owner. `pack --retire <place>:<name> <sha256>` bỏ ghim một sha; `pack project:<name> user:<name>` (hoặc ngược lại) chuyển một baton đã giữ.

**Trong sandbox.** Một phiên trong pod sandbox (`INTENT_SLUG` và `SEAT` đều được đặt) chỉ giữ ở `project:`: `pack <path> <name>` giữ `project:<name>`, còn một lần giữ `user:` hay một lần chuyển sang `user:` bị từ chối (mã thoát 64), vì thư viện của pod mất cùng pod. Pod không bao giờ có chữ ký của owner, nên một luồng dừng chờ owner được giao cho coordinator:

1. Phiên chạy `go <path> key='value'…` đến decision card của owner (mã thoát 8): check, rehearse và plan so với Expect và Targets đều đạt. Trong sandbox, đầu ra nêu lời gọi để giao cho coordinator thay cho một dòng sign, dưới một tên mà máy của coordinator chạy được: không có sign, `run` hay `go --queue` nào là bước kế tiếp ở đó, và không hiện lệnh mode nào. Trong sandbox, lần dừng đó được ghi log cho đúng những byte này khi nó đến từ `Stops` của baton, hoặc từ mode `manual` với một script của phiên (một đường dẫn) có `Stops: none`. Một script của phiên không có `Params` được báo trước một bước: thêm chúng, rồi `go` lại. `rehearse` trong pod cũng không nêu lệnh nào của owner: dòng cuối của nó nói rằng `go` giao lời gọi cho coordinator.
2. `pack <path> <name>` giữ những byte đó là `project:<name>` dựa trên lần dừng đã ghi log thay cho một lần chạy `ok`; dòng của nó ghi `not run: stop-list, the owner signs after merge`. Một script `Stops: none` chỉ được giữ dựa trên một lần dừng ghi log ở mode `manual`: dòng của nó, bản ghi giữ của nó và phần giao việc đều nói nó chưa chạy lần nào, nên `go` của coordinator là lần chạy đầu của nó. Chỉ trong sandbox và chỉ vào `project:`; ở mọi chỗ khác `pack` cần một lần chạy `ok`.
3. Phiên commit baton trên branch của nó, mở pull request và báo coordinator lời gọi.
4. Coordinator merge nó sau bước hậu kiểm của mình, rồi chạy nó với chữ ký của owner, hoặc, với một script `Stops: none` đã giữ mà chưa chạy lần nào, với `coordinator-auto` của chính nó khi mode của nó là `auto` (lần chạy đầu của nó): là `project:<name>` từ một checkout của default branch đã merge khi remote của repository đó có trong danh sách remote của owner (bên dưới), nếu không thì từ một bản scratch mới của file đã merge, rồi giữ nó bằng `pack`.

**Merge một project baton.** Các deny glob mặc định mà `kb.py init` ghi, và guarded merge thêm vào pull request đầu tiên của một repository, chặn `.vibemaestro/*` (config), `.vibemaestro/gates/**` và `.vibemaestro/rules/**`, và để `.vibemaestro/batons/` cho guard như mọi code khác. Một repository có `merge.deny_globs` ghi `.vibemaestro/**` thì mọi project baton vẫn là merge của owner.

**Project baton đã review.** Một baton `project:` chạy mà không cần bản ghi giữ trên máy này khi tất cả đều đúng, được kiểm ở mọi bước như pin: gốc project nằm trong git; `refs/remotes/origin/HEAD` trỏ tới một branch của origin; URL của origin, ở dạng chuẩn (`host/path`: không scheme, userinfo hay `.git`, host viết thường), có trong danh sách remote của owner; và byte của nó, dưới dạng git blob, đúng là blob tại đường dẫn của nó trên branch đó. Khi đó nhãn của nó là `reviewed on <url> <branch>`. Danh sách nằm trong state directory, ngoài mọi repository, và rỗng cho đến khi owner đặt nó: `mode remotes` in nó, `mode trust <remote>` và `mode untrust <remote>` đổi nó, mỗi lệnh qua dialog của owner như cho mode. Một remote viết kèm user hay token trước `@` (trừ dạng `git@host:path` của git) bị từ chối (mã thoát 64): viết nó không kèm những thứ đó. Một file đã sửa trên branch, một baton chỉ có trên branch khác, một link trên origin, một sha đã retire, một remote không có trong danh sách (một đường dẫn tương đối, hay một URL kết thúc bằng `/.git`, không bao giờ có trong đó), một gốc project không phải gốc của repository và một baton `user:` đều cần bản ghi giữ; lời từ chối (mã thoát 3) nói điều kiện nào không đạt.

**Baton đã giữ không phải code đáng tin.** Mỗi lời gọi chạy check, rehearse, kế hoạch so với Expect và Targets, seal, sign, run, post-check và log, như một session baton. Nó không được chạy gate, không giữ bí mật, và `Stops:` của nó quyết định ai ký; ở mode `auto` phiên được ký một baton `Stops: none` mà phiên khác đã giữ.

**Đặt tên và tìm kiếm.** Một baton có tên kebab-case ngắn nói nó làm gì (`merge-pr`, `gh-write`, `ci-rerun-failed`), và dòng header `Purpose:` nói điều đó trong một câu. `baton list <keyword>…` tìm nó: một dòng cho mỗi baton có tên, Purpose hoặc Params chứa mọi từ khoá, tối đa 25, và toàn bộ mục khi chỉ một baton khớp. Phiên giao nhiều run cho một subagent đặt tên chúng `<prefix>-<act>.sh` với tiền tố riêng, để `log --wait-names` chờ đúng những tên đó.

**Run bị kill.** `run` và `go` in một dòng khi đạt, nên một run bị kill trước khi kết thúc (SIGKILL, hết thời gian của tool) không in gì. Trước khi script bắt đầu, runner ghi một dòng `run-start` vào `log.tsv` và đường dẫn log của run vào `runs/LAST`; `<launcher> log --last` in đường dẫn đó.

**Từ baton đã giữ lên kit.** Một baton mà các repository khác cần trở thành `project:` baton của từng repository, hoặc một kit: mở một issue trong repo công khai của kit, mang script, nó làm gì, log cho thấy bao nhiêu lần chạy và chúng có đạt không, và còn cần ở đâu nữa. Run thuộc miền của sdlc thành một run `kit:` hoặc một `kind:` trong `vibemaestro-sdlc`. Run thuộc về một plugin phụ thuộc được đưa vào thư mục `batons/` của plugin đó và chạy dưới dạng `kit:<name>`, qua mọi bước kiểm tra như một kit của sdlc; một tên mà hai plugin cùng có thì không chạy ở đâu cả, nên tên kit là duy nhất giữa các plugin.

### Một run phát triển như thế nào

Quy tắc: **một baton đã giữ đại diện cho một quy trình, nên quy trình đổi thì cập nhật nó, không bao giờ tách ra một bản sao.** Phép thử là nó có còn là cùng một quy trình hay không: cùng mục đích, đích và rủi ro.

- Một bước cần mọi lần: thêm vào baton.
- Một bước thỉnh thoảng mới cần, hoặc một giá trị đổi giữa các lần chạy: một tham số. Chữ ký ràng buộc các giá trị, nên plan cho thấy chúng.
- Mục đích khác hoặc đích khác, hoặc một từ Stops mới: một baton mới có tên riêng.
- Một bước gặp lần đầu: lần này là session baton; lần thứ hai thì gộp vào baton đã giữ.

Để phát triển một baton, chép file đã giữ ra một đường dẫn mới, sửa nó, chạy nó với giá trị, rồi `pack` lại dưới cùng tên. Với project baton, mọi sha đã giữ vẫn gọi được cho đến khi bị bỏ ghim, và git giữ các phiên bản cũ; với user baton, chỉ lần giữ mới nhất gọi được, còn các bản ghi giữ và log giữ các bản cũ.

Rào chắn:

- Một thay đổi trong cùng quy trình mà mở rộng những gì baton đụng tới thì cập nhật header của nó. Một từ Stops mới tạo ra một baton mới (ở trên), và owner ký nó từ đó về sau.
- `pack` từ chối tên bản sao và cùng những byte dưới một tên thứ hai, nên sao chép không phải lối tắt rẻ.
- Một kit run chỉ đổi qua một kit PR; trong lúc đó bước thêm chạy thành một run riêng ngay sau nó.
- Chữ ký ràng buộc sha256 của script và log ghi lại nó, nên phiên bản nào của baton đã chạy vẫn biết được.

## 5. Danh mục run

Các kit run và kind, mỗi cái một dòng; `baton list` in đúng như vậy kèm số lần chạy của từng cái. Phần lớn giữ tham số mà code của chính chúng kiểm, nên khai báo `Usage`; `kit:branch-delete` khai báo `Params`, và cột cho thấy cách gọi nó. Phiên bản plugin ràng buộc chúng vào chữ ký. Project baton và user baton không nằm trong bảng này: chúng là của riêng repository và của máy, và `baton list` cho thấy chúng.

| Run | Làm gì | Usage | Stops |
|---|---|---|---|
| `kit:merge-pr` | merge có cổng kiểm soát: rehearse là lần chạy thử của cổng (head được ghim, CI, xung đột, deny glob, glob của brief, …), run merge đúng head đã ký; merge không đảo ngược được, đường lui là một revert PR | `--repo <owner/name> --pr <n> --head <sha40> --brief <file> [--behind auto] [guard options]` | none |
| `kit:gh-write` | các lần ghi GitHub nhỏ từ một spec JSON: issue-create, issue-comment, comment-edit, issue-edit, pr-body-edit, issue-reopen, issue-close, pr-close và pr-ready (ghim head), pr-create (từ một branch đã push, ghim head), file-pr (một file được thêm hoặc thay trên một branch mới từ đỉnh base, blob bị thay được ghim, rồi PR của nó); từ chối repo công khai, việc xoá, việc tạo repo và một đường dẫn workflow; undo không bao giờ xoá, và nêu tên branch nó để lại | `--spec <file> [--recover]` | none |
| `kit:branch-push` | đẩy một branch cục bộ của clone nơi nó chạy thành một branch mới trên repository GitHub riêng tư của nó, đúng đỉnh đã ghim, không bao giờ ép; đẩy từ một repository nháp mà cấu hình hay hook của clone không chạm tới; từ chối repository công khai hay internal, remote khác github.com/`--repo`, branch remote đã có, commit mới đổi một workflow, và tên mà git hiểu thành ref khác; undo nêu tên branch nó không xoá được (exit 5) | `--branch <name> --head <sha40> --repo <owner/name> [--remote <name>]` | none |
| `kit:branch-delete` | xoá một branch của repository GitHub riêng tư ở một head đã ghim, đã merge vào branch mặc định, chạy từ một clone của repository: rehearse từ chối branch có đỉnh không phải head đã ghim, chứng minh từ GitHub rằng head là tổ tiên của đỉnh branch mặc định, hoặc rằng một PR đã merge của branch này (cùng repository, đúng head đó) vào branch mặc định có merge commit nằm trên branch đó và `refs/pull/<n>/head` ở head (merge kiểu squash hay rebase), rồi ghim cả hai SHA và cách chứng minh vào dòng kế hoạch; lệnh xoá là gate của plugin chạy trong `write()`, gate kiểm dòng kế hoạch đã ký rồi đẩy với lease trên head; post-check chứng minh lại; từ chối branch chưa merge, branch mặc định hay branch được bảo vệ, branch mà ruleset cấm xoá, tên trùng một tag, pull request đang mở từ hay vào branch, và repository công khai hay internal; undo tạo lại branch ở SHA đã ghim khi chính lần chạy này đã xoá nó | `repo=<owner/name> branch=<name> head=<sha40>` | none |
| `kit:plugin-update` | cập nhật mọi plugin của marketplace `vibemaestro` trên máy (phạm vi user) qua `claude plugin marketplace update` và `claude plugin update`, không bao giờ `-y`: `vibemaestro-sdlc` và `vibemaestro-brain` lên kit main ở một SHA đầy đủ, mỗi plugin cục bộ của marketplace (`./plugins/<name>`) lên main của marketplace, đọc từ GitHub và ghim trong dòng plan; plugin đã ở đích thì bỏ qua. Rehearse đọc bố cục marketplace (marketplace riêng của kit, hoặc cả hai plugin là nguồn `git-subdir` của một repository github.com qua https ở ref `main`; mọi mục khác là plugin cục bộ) và từ chối mọi bố cục khác, bố cục không chỉ ra repository kit nào hay chỉ ra hơn một, mục có khóa ngoài name, source và description, thư mục plugin là symlink, cây của bản clone khác HEAD của nó, hay origin bị viết lại, và từ chối SHA không phải kit main; lần chạy giữ bản sao từng byte của `installed_plugins.json` và `known_marketplaces.json`, rồi sau khi cập nhật marketplace đòi cùng bố cục và plugin cục bộ, kit main và main của marketplace không đổi, và bản clone ở đúng main đó; post-check đòi `gitCommitSha` của mỗi bản cài là đích của nó, phiên bản là 12 hex của đích (đứng riêng hoặc thêm `-<8 hex>`), đúng đường dẫn cache, `plugin.json` không có version và template launcher mới chấp nhận nó, rồi in bước cài đặt tiếp theo; undo đặt lại cả hai file đúng từng byte, trừ khi phần khác trong chúng đã đổi, một plugin của lần chạy đã bị đổi từ đó, hay bản sao chỉ tới một bản cài đã mất, và nêu các thư mục cache cùng bản clone mà nó để lại | `<full kit sha>` | none |
| `kit:workflow-dispatch` | khởi chạy một run `workflow_dispatch` trong một repository riêng tư, ghim đỉnh branch và blob của file workflow, có bản ghi run và kiểm tra với plan đã ký trước khi dispatch; undo chỉ huỷ đúng một run mới do lần dispatch này tạo | `--repo <owner/name> --workflow <file.yml> --ref <branch> [--input <key>=<value>]…` | none |
| `kit:coordinator-bootstrap` | dựng một máy mới hoặc vừa chuyển cho BatonRun: một báo cáo máy, rồi launcher và khối permission đã in (tắt attribution nếu chưa có khoá) qua `kind:settings-merge`; bị từ chối ở rehearse khi không có gì để làm; undo đặt từng file về đúng từng byte | không có | security-boundary (owner ký) |
| `kind:install-file` | cài một file, đúng từng byte, vào một thư mục có thể chỉ đọc, không bao giờ nằm dưới `.git`, `.claude`, thư mục cấu hình hay state directory | `<source> <directory>` | none |
| `kind:settings-merge` | thêm permission rule vào một `settings.json` của Claude Code, không xoá rule nào, có bản ghi run và một bản sao lưu chỉ giữ cho undo (xoá khi run đứng vững hoặc undo đã trả file về; giữ lại cho owner khi trạng thái không rõ) | `<settings.json> <rules.json>` | security-boundary (owner ký) |
| `kind:ci-rerun-failed` | chạy lại các job lỗi của một lần chạy CI của một repository riêng tư | `<owner/name> <run id>` | none |

Các template mà `new --from <kind>` ghi ra file nhưng không chạy được dưới dạng `kind:` (phần hành động để phiên điền), mỗi cái khai báo `Params`: `remote-exec` (một chương trình qua stdin vào `bash -s` trên `ssh`; `host`, `rpath`, `body`) và `kubectl-exec` (tương tự qua `kubectl exec -i`, API server được truyền vào và so với server của context; `Stops` của nó là `cluster-lane`). Chưa xây: `owner-merge-pr`, một lần merge mà owner ký cho PR đụng tới `merge.deny_globs` (cổng từ chối PR như vậy bất kể ai ký).

## 6. Phê duyệt: chế độ, danh sách dừng, chữ ký của owner

**Các mode** là quyết định thường trực của owner, không phải lựa chọn của phiên cho từng run. Chúng nằm trong state directory của người dùng, không bao giờ trong repository; `mode` in mode hiện tại (`manual` khi chưa đặt gì), và `mode manual|auto` chỉ đổi theo lời của owner: như `sign --by owner`, lệnh đổi cần bản ghi hộp thoại của owner mà hook của plugin ghi cho lệnh nguyên văn, và lệnh không có bản ghi bị từ chối. Phiên không bao giờ tự chọn mode, và một tin nhắn từ agent hay máy khác không đổi được nó.

**Hỏi một lần.** Bản cài mới chưa chọn mode nào. Nó được đọc là `manual`, và run `Stops: none` đầu tiên dừng vì nó (`go` thoát 8) có dòng `mode manual (not chosen yet)` trên card. Khi đó phiên hỏi owner một lần chọn mode nào, kèm nghĩa của từng mode: `auto`, khuyên dùng trên máy một người (phiên tự ký run `Stops: none`; run trong danh sách dừng vẫn cần owner), hoặc `manual` (owner ký mọi run). Chỉ ngay sau câu trả lời của chính owner, phiên chạy lệnh mà dòng `Mode:` của card ghi, `<launcher> mode <câu trả lời>`, một mình trong lệnh Bash: hook của plugin mở hộp thoại, và cú bấm của owner ở đó đặt mode. Rồi phiên chạy lại baton; `go` từ chối file đã ghi quá 120 s trước, nên phiên ghi nó ra một đường dẫn mới. Khi đã đặt một mode, card không bao giờ ghi `not chosen yet` nữa. Không có câu trả lời, hoặc hộp thoại bị từ chối, thì mode vẫn chưa chọn: run chờ chữ ký của owner như ở manual, và lần thoát 8 kế tiếp trên một run `Stops: none` lại hỏi.

- **manual** (mặc định cho tới khi owner chọn): owner ký mọi run sau khi xem.
- **auto**: phiên tự ký (`coordinator-auto`) run có header ghi `Stops: none` và chạy không hỏi, kể cả một baton mà phiên khác đã giữ (dòng ký của nó ghi `not reviewed, kept by …`); run có bất kỳ từ Stops nào cần chữ ký của owner, như ở manual.
- Ở auto, điều kiện tiên quyết thất bại hay Expect không khớp không phải là điểm dừng: phiên sửa script và rehearse lại, miễn là bản sửa không mở rộng những gì run đụng tới. Bản sửa mở rộng thì cần owner.

**Danh sách dừng.** Run làm bất kỳ việc nào dưới đây phải khai báo trong `Stops:`, và khi đó chỉ owner ký, ở mọi mode:

| Từ | Run … |
|---|---|
| `irreversible-delete` | xoá dữ liệu không thể lấy lại: volume có dữ liệu, namespace, phiên bản package, repository, nhánh và tag (check không chứng minh được một nhánh đã merge, nên xoá nhánh hay tag bằng tay cần chủ; nhánh đã merge của repository GitHub đi qua `kit:branch-delete`), đường dẫn secret, cơ sở dữ liệu |
| `secrets` | đọc, in, ghi hoặc xoay vòng một secret |
| `security-boundary` | mở rộng một ranh giới: RBAC, admission hoặc network policy, công khai một thứ, một lối vòng quyền admin ngoài rule sẵn có của owner |
| `cluster-lane` | thay đổi một cluster đang chạy ngoài làn đã duyệt: tạm dừng reconciliation, drain node |
| `history-rewrite` | force-push hoặc viết lại lịch sử trên nhánh dùng chung |
| `money-org` | đụng tới thanh toán, gói dịch vụ hoặc quản trị tổ chức (tạo hay đổi tên repository, thành viên) |
| `publish` | đăng ra ngoài: nơi công khai, repository của người khác |
| `no-way-back` | không thể rehearse cũng không thể undo |
| `owner-acts` | là hành động mà một quyết định trước đó của owner chỉ định chính owner làm |

Một lời gọi có đối số hay giá trị Param nêu một file settings của Claude Code (một `settings*.json` nằm ngay trong một thư mục `.claude`, thư mục settings managed hay `$CLAUDE_CONFIG_DIR`), hoặc chính một thư mục như thế, hoặc một tên khác của một cái như thế (một hard link, file hay thư mục mà một link settings trỏ tới, trừ khi đó là một thiết bị hay, sau một tên file, một thư mục), là `security-boundary` dù `Stops:` của nó ghi gì. `go`, `rehearse`, `sign` và `run` quyết định trên giá trị đã bind, không trên văn bản: `~`, `$VAR`, `..`, đường dẫn tương đối, link và glob đều được phân giải, và phần sau một dấu `=` cũng được đọc. Chỉ owner ký nó: `go` dừng với mã thoát 8, `sign --by coordinator-auto` và lần `run` của một chữ ký như thế bị từ chối, mỗi lần nêu đối số trong một dòng. Một giá trị được đọc như một đường dẫn, không bao giờ được dò tìm một đường dẫn giữa những từ khác, và một thư mục con của `.claude` không phải. Một file thường có hard link khác mà baton không định vị được cũng được tính: tên kia của nó có thể là một file settings trong một `.claude` mà không lần dò nào tới được, nên owner ký.

`check` đánh dấu một dòng thân script trông như hành động dừng, nêu nhóm, từ và header cần thêm; lint đó là lưới đỡ, không phải chứng minh: một run khai báo những gì nó làm, không phải những gì lint tìm thấy. Lint chỉ biết một số hành động trên cluster (`flux suspend`, `kubectl … drain|cordon`).

**Một thay đổi settings ngoài baton bị từ chối.** Thêm một permission rule là `security-boundary`, và một phiên có thể làm việc đó bằng một tool thường, ngoài mọi baton. Hook `settings-guard.py` của plugin chạy trước mọi lần gọi Edit, Write, MultiEdit, NotebookEdit và Bash, ở mọi mode, trên laptop của owner cũng như trong pod, bất kể cấu hình `hooks` của repository nói gì. Nó xét một file settings của Claude Code: một `settings*.json` trong thư mục `.claude` hoặc trong `$CLAUDE_CONFIG_DIR`, không phân biệt hoa thường của tên, kể cả qua một symbolic link hay hard link, và file mà một link settings trỏ tới.

- **Edit, Write, MultiEdit** được xét trên đúng file sau lần gọi. Bị từ chối: thêm một allow rule hay một additional directory; bỏ một ask hay deny rule; `defaultMode` lên cao hơn theo thứ tự `plan`, `dontAsk`, `default`, `acceptEdits`, `auto`, `bypassPermissions` (một giá trị lạ tính là cao nhất); bỏ `disableBypassPermissionsMode: "disable"`; đổi bất kỳ khoá nào khác của `permissions`; để lại một file không phải object JSON; đổi bất kỳ khoá cấp cao nhất nào trừ `$schema`, `model`, `outputStyle`, `attribution`, `includeCoAuthoredBy`, `cleanupPeriodDays`, `language`, `alwaysThinkingEnabled`, `spinnerTipsEnabled` và `theme`. Vậy `hooks`, `env`, `statusLine`, `apiKeyHelper`, các khoá MCP, `enabledPlugins`, `sandbox`, `disableAllHooks` và mọi khoá Claude Code thêm sau này đều bị từ chối. Một thay đổi thu hẹp thì đi qua: bỏ một allow rule hay một additional directory, thêm một ask hay deny rule, `defaultMode` xuống thấp hơn. Một Edit không khớp đúng từng ký tự với file cũng bị từ chối (Edit của Claude Code so khớp lỏng hơn, nên không biết trước kết quả).
- **NotebookEdit** trên một file settings bị từ chối.
- **Bash** được xét trên văn bản lệnh, nên mọi lần ghi mà hook tìm thấy lên một tên settings đều bị từ chối, kể cả thu hẹp: một redirect, `tee`, `sponge`, `cp`, `install` hay `rsync` lên nó, chép, chuyển hay link một file tên settings vào một thư mục `.claude` (cả `-t`), `mv`, `ln`, `rm`, `truncate`, `dd of=`, `patch`, `sed`, `perl`, `awk` hay `yq` sửa tại chỗ, một trình soạn thảo, `git checkout|restore|rm|mv|stash` có nêu tên nó, `curl -o`, `wget -O`, `find -delete` hay `-exec` một lệnh ghi, `xargs` một lệnh ghi, code interpreter viết thẳng trong lệnh (`python -c`, một heredoc, `node -e`) có nêu tên nó và có ghi. Hook tách từ như shell tách, nên một câu trong nháy (một commit message) là một từ và không nêu tên gì. Từ đầu tiên là lệnh; sau một runner (`sudo`, `timeout`, `env`, `xargs`, `find -exec` và những thứ tương tự) mọi từ ghi phía sau cũng tính. Một chuỗi mà shell chạy (`bash -c`, `eval`, `su -c`, `$(…)`, backtick, một heredoc đưa vào shell, một chuỗi literal trong code interpreter) được đọc lại như lệnh; thân các heredoc khác là dữ liệu. Chỉ một file mà thư mục chứa nó là `.claude` mới tính (một checkout `.claude/worktrees/…` phía trên không tính). Đọc thì đi qua.

Con đường duy nhất là `<launcher> go kind:settings-merge <settings.json> <rules.json>`: nó thêm allow, ask và deny rule rồi dừng chờ owner (thoát 8). Trên laptop của owner cũng vậy, một thay đổi settings đi qua kind đó, để owner ký. Một thay đổi mà kind không làm (`defaultMode`, bỏ một ask hay deny rule, một khoá khác) chờ owner. Trong pod, owner không bao giờ ký: sau mã thoát 8, phiên giao cho coordinator lời gọi mà đầu ra nêu, và lời từ chối cũng nói vậy. Các lần ghi của một baton chạy trong tiến trình riêng của nó, nơi không hook nào thấy, nên `kind:settings-merge` và `kit:coordinator-bootstrap` không bị chặn. Những gì hook không thấy nằm ở mục 8.

**Chữ ký của owner** là cú nhấp của owner trong một hộp thoại: ngay sau thẻ quyết định, phiên chạy `sign --by owner --seal <seal> …` một mình trong lần gọi Bash, hook của plugin bắt lệnh đó phải hỏi bất kể permission rule nói gì, và hộp thoại hiển thị nó. Hook viết một bản ghi dùng một lần cho đúng lệnh đó, và `sign` từ chối khi không có nó. Hook từ chối lệnh ở nơi không có owner trả lời hộp thoại: trong sandbox, từ subagent, ở mode hay lượt `-p` không có hộp thoại, khi một hook hoặc permission-prompt tool có thể trả lời thay. Phiên không bao giờ tự chạy lệnh đó, chạy thử, hay chạy lại sau khi bị từ chối. Khi `go` dừng với mã thoát 8, nó in các dữ kiện cho owner (các lần ghi làm gì, vì sao, blast, undo, lý do dừng, đã kiểm gì) và hai lệnh để chạy khi owner đồng ý; trong pod sandbox nó in bước bàn giao thay vào đó (pack thành `project:`, mở PR, giao cho coordinator lời gọi: tên, đối số, seal) và không chạy `sign` hay `go --queue`; `rehearse` ở đó không in lệnh sign nào. Seal không còn khớp với thứ đã trình thì bị từ chối. **Không hiện hộp thoại, hoặc hộp thoại bị từ chối, nghĩa là chưa được xác nhận**: phiên ghi run là đang chờ và nói rõ như vậy; không bao giờ thử lại `sign` trong vòng lặp và không bao giờ coi im lặng là đồng ý.

**Hàng chờ của owner.** Một hộp thoại đang mở giữ phiên đã hỏi đứng im tới khi owner bấm, và bản ghi của nó sống 10 phút. Khi owner vắng, phiên chạy `go --queue <script> [args…]` thay cho `go`: cùng check, rehearse và seal, rồi một mục ở `<state-dir>/queue/<id>.json` (riêng tư) giữ seal, các đối số như đã đưa và như đã bind, thư mục, sha256 của script, plan, thẻ quyết định, phiên và tiến trình Claude Code đã xếp hàng, thời điểm và hạn 24 giờ sau đó, cùng một sha256 trên tất cả. Nó in một dòng nêu mục đó và phiên làm tiếp; `log --wait-queued <id>`, chạy nền, kết thúc khi mục được ký. Owner ký từ một phiên Claude Code của chính mình, lúc mình chọn: `/vibemaestro-sdlc:owner-sign` liệt kê các mục đang chờ (`log --queue`) và chạy `sign --by owner --queued <id>` một lần cho mỗi mục owner chọn, một mình trong lần gọi Bash; hook mở hộp thoại, hiện thẻ của mục, và viết bản ghi như với `--seal`. Chữ ký vào mục và nêu sha256 của nó. Phiên đã xếp hàng một mục không ký được mục đó: hook từ chối lệnh, không mở hộp thoại, từ session id đó hoặc từ tiến trình Claude Code của nó dưới một session id mới (sau `/clear`), và `sign` từ chối lần nữa. `run --queued <id>` chạy một mục đã ký một lần, từ thư mục đã xếp hàng, trước khi hết hạn: rehearse của nó phải cho đúng plan đã niêm phong (head, base hay file đã dời là bị từ chối), rồi run, post-check và log như `run`. Một mục có byte bị đổi sau khi hộp thoại mở hoặc sau khi ký, một mục hết hạn, chưa ký hoặc đã dùng đều bị từ chối. Như các bản ghi chữ ký, một mục chặn sơ suất, không chặn một tiến trình cùng user viết lại cả mục lẫn chữ ký. Mode `manual` và `auto`, danh sách dừng và pod như trên: pod không xếp hàng gì và không bao giờ ký thay owner.

**Decision card.** Ngay trước hộp thoại của owner, phiên viết, bằng ngôn ngữ của owner, tối đa bảy dòng ngắn: nó ghi gì, ở đâu, vì sao (quyết định hay nhu cầu), tác động, undo (hoặc "không thể hoàn tác"), một rủi ro, và đã kiểm gì (check ok, rehearse ok, plan khớp Expect, N lần ghi). Mô tả của lệnh `sign`, thứ hộp thoại hiển thị, là dòng đầu của card; seal, đường dẫn và đầu ra rehearse đi sau, làm chi tiết.

## 7. Chi phí

**Điều đã đo.** Đưa mọi lần ghi qua run tốn hơn cách làm trực tiếp: trong một phiên 18 task, phiên đưa mọi lần ghi qua BatonRun tốn 3,05 đến 3,67 lần một phiên không có plugin cho mỗi lần ghi đúng, không hoà vốn trong 18 task đó, và làm một loại ghi lần thứ hai với BatonRun không lợi hơn khi không có nó, vì hầu hết baton được viết mới mỗi lần. Phần theo từng task chiếm phần lớn: phiên viết khoảng 4,4 đến 4,9 lần số token đầu ra. Độ đúng như nhau ở cả hai nhánh. Phương pháp và số liệu nằm ở [`docs/research/batonrun.vi.md`](../../../docs/research/batonrun.vi.md).

**Điều suy ra.** Một lần ghi đơn giản là lời gọi trực tiếp, không phải run, nên nó tốn đúng như cách trực tiếp. Một luồng đã gặp không viết lại: `baton list` tìm ra baton đã giữ và một lệnh `go` với giá trị mới chạy nó, không đọc skill, không viết script. Các kiểm tra là kiểm tra của máy và gần như không tốn gì; chi phí là các lượt của model và đầu ra giữ trong ngữ cảnh, nên `go` tồn tại, nên nó in một dòng, và nên skill chỉ được đọc khi viết hoặc sửa một baton. Giữ-rồi-gọi tiết kiệm bao nhiêu so với viết mới thì chưa đo.

**Chạy nhiều run.** Mặc định chạy tại chỗ, bao nhiêu cũng được. Chỉ giao ba run trở lên cho một subagent worker để giữ ngữ cảnh chính còn nhỏ khi nó đã lớn (trên khoảng 400k token): giao việc chỉ rẻ hơn ở task nhiều run đầu tiên của một phiên. Phiên chính khi đó chờ trên log theo đúng tên script (`log --wait-names`), và tin dòng log, là bằng chứng của máy, chứ không tin báo cáo của worker.

## 8. Giới hạn

Những gì baton không bảo vệ:

- **Trung thực, không phải thù địch.** BatonRun bảo vệ một phiên có thể sai sót, không phải một phiên cố tình lừa (mục 1). `check` đọc văn bản; nó không chạy văn bản, nên một cách gián tiếp che giấu một run (`eval`, tên dựng lúc chạy, launcher nằm sau một biến) là giả mạo, không phải kẽ hở để lách.
- **Rule và lời cảnh báo launcher của nó khuyên; chúng không chặn.** Rule nhắc một lần mỗi phiên khi một lệnh đặc quyền bị gõ thẳng, chỉ trên dòng lệnh. Hook cảnh báo với mọi lệnh launcher `sign`, `run` hoặc `go` không "trần" (pipe, chuỗi lệnh, redirect, substitution, tiền tố hoặc shell wrapper), vì khi đó các allow rule không khớp và bộ phân loại auto-mode của Claude Code quyết định.
- **Permission rule khớp theo văn bản lệnh,** không theo thứ shell biến nó thành, và rule Edit bao phủ các tool ghi và các lệnh file mà Claude Code nhận ra, không phải mọi tiến trình. `permissions --check` chỉ đọc các rule: không đọc `defaultMode`, lần khởi động bỏ qua quyền, hay cấu hình của bộ phân loại.
- **Script của plugin được tin từ gốc plugin mà `baton.py` chạy từ đó,** chỉ như lệnh của một lần ghi có sha256 trong plan line; `scripts/` bị đổi giữa một phase sẽ được phát hiện sau phase, không bị ngăn.
- **Điều `go` không biết:** một file mới có chứa đúng thứ ý muốn không (một Edit không áp dụng được), và bất cứ điều gì về một file mà chính script đọc, trừ khi sha256 của nó nằm trong plan line.
- **Mode đến từ owner, không đến từ một tin nhắn.** Một phiên không thể bảo agent hay máy khác đổi mode phê duyệt của nó, hay danh sách remote của nó.
- **"Reviewed" tin vào cái nhìn cục bộ về origin.** Một project baton đã review được kiểm với `refs/remotes/origin/HEAD`, một ref cục bộ, tại đường dẫn của baton tính từ gốc repository, và với URL mà git fetch origin từ đó (`git remote get-url origin`, sau `insteadOf`); git đó chạy không mang các biến `GIT_*` của người gọi. Dời ref bằng tay (`git update-ref`, một lần fetch từ URL khác URL được kiểm) là giả mạo, như sửa state directory.
- **`go -` với một baton bị Claude Code chặn.** Ở permission mode mặc định (đã thử với Claude Code 2.1.303, `-p --permission-mode default`, allow rule `Bash(<launcher> go:*)`) allow rule khớp một heredoc `go -` ngắn, nhưng heredoc chứa khung baton bị chặn trước khi rule nào được áp dụng, bởi kiểm tra riêng của tool ("Contains brace with quote character (expansion obfuscation)"), vốn kích hoạt với mọi thân hàm `{ … }` có chứa dấu nháy (`write()`, `gh_state()`). Auto mode chưa được thử. Default là mode được hỗ trợ, nên chuẩn không phụ thuộc vào auto: một session baton là một lần Write ra đường dẫn mới và `go <path>`. Kiểm tra đó là kiểm tra an toàn của tool; khung mẫu không bị sửa hình dạng để né nó. Hook im lặng với một heredoc `go -` có delimiter đặt trong nháy, dù heredoc đó bị chặn với baton, và nêu tên mọi dạng khác (delimiter không đặt trong nháy để shell khai triển phần thân trước khi baton đọc byte nào; một dòng sau dòng đóng là một lệnh riêng).
- **Một giá trị an toàn trong shell, không phải trong mọi công cụ.** Một giá trị `Params` đến script như một từ argv có kiểu đã kiểm: nó không thể kết thúc một từ shell, bắt đầu một tuỳ chọn hay thêm một plan line. Một công cụ đọc code hay file của riêng nó từ giá trị đó vẫn có thể hiểu sai; `check` từ chối một giá trị trong `eval`, thân heredoc, tên lệnh, `gh -F` và `curl -d`, và `limits.md` của skill nêu dạng an toàn cho phần còn lại (`jq --arg`, `gh -f`, `--` trước toán hạng, không đặt giá trị trong chương trình `sed`, `awk` hay `find -name`). Văn bản tự do từ bên ngoài đi qua một file `input`, không bao giờ qua dòng lệnh. Một bí mật đi qua một giá trị `path`, không bao giờ qua giá trị `file` hay `input`, vốn được chép và giữ lại: giá trị nào trông như vật liệu khoá bị từ chối (exit 64). Một giá trị `path`, `under:`, `file` hay `input` bị từ chối (exit 64) khi đoạn cuối của đường dẫn, tức basename, bắt đầu bằng `-`, `+` hoặc `@`; một đoạn ở giữa thì được.
- **Một luồng bị cắt thành các lần ghi đơn giản thì không thấy được.** Không gì phân biệt được một luồng bị cắt thành từng lần ghi với những lần ghi đơn lẻ thật; rule và skill gọi việc cắt đó là điều không được làm.
- **Settings guard tìm; nó không chứng minh.** Nó đọc Bash như văn bản. Nó không thấy một tên dựng lúc chạy (một biến, `$(…)`, ghép chuỗi, một glob không có `settings` trong đó), một file script được chạy, một baton do phiên viết (`check` gắn `security-boundary` cho lần ghi của nó lên một đường dẫn settings, và một lời gọi có đối số nêu một file settings thì dừng chờ owner, mục 6), `git apply`, `git am`, một archive được giải nén, một checkout hay merge không nêu tên file, một thư mục được chép nguyên lên `.claude`, một lần ghi qua một link đã tạo từ trước dưới tên khác, một MCP tool ghi file, một lần ghi trên máy khác (`ssh host '…'`), hay file trạng thái ứng dụng `~/.claude.json`. Nó cũng từ chối một `python -c` đọc settings rồi ghi một file khác, một `.claude/settings*.json` mà Claude Code không đọc (một bản sao lưu, một ví dụ, một fixture của test), và một từ ghi đứng sau một runner mà chỉ là đối số (`sudo grep rm .claude/settings.json`). Một file settings có comment được tính là không phải JSON.
- **Merge, publish và những việc tương tự không thể hoàn tác.** Run nói điều đó trong `Undo:`; khi nó lỗi sau khi thế giới đã đổi, nó kết thúc với mã thoát 5 và owner được báo ngay.

## 9. Cài đặt quyền

Một lần mỗi máy, phiên chạy ba lệnh và owner áp dụng kết quả; plugin không bao giờ tự ghi settings:

1. `permissions --install-launcher` chép launcher vào `<state-dir>/bin/baton`. Nó chạy vibemaestro-sdlc mới nhất đã cài từ plugin cache và từ chối mọi `baton.py` khác. Chạy lệnh này từ vibemaestro-sdlc đã cài, bản mà registry (`installed_plugins.json`) ghi: một bản trong cache mà registry không còn ghi (phiên mở trước một lần cập nhật plugin) từ chối với mã thoát 10 và không ghi gì.
2. `permissions --print` in khối cài đặt người dùng; owner thêm nó qua phần settings của Claude Code.
3. `permissions --check` cho biết các rule đang có có giữ đúng cách chia hay không (mã thoát 0) hoặc nêu từng rule thiếu, cũ hoặc không an toàn (mã thoát 7). Một phiên có vibemaestro-sdlc không phải bản đã cài thì nhận một dòng thay vào đó, nêu cả hai phiên bản: khởi động lại Claude Code (mã thoát 10).

Kit run `kit:coordinator-bootstrap` có thể làm bước 1 và 2 trong một run do owner ký (skill `coordinator-bootstrap`).

**Sau khi nâng cấp plugin.** Nâng cấp không cần làm gì khi bản launcher đã cài vẫn chạy được phiên bản mới: nó chọn mục mới nhất của registry. Khi nó không chạy được (một bản cài trước khi thư mục phiên bản mang tên một commit git thì từ chối hết chúng), mọi baton bị từ chối cho đến khi bước 1 chạy lại từ vibemaestro-sdlc đã cài, rồi bước 3. Phép kiểm nêu trường hợp này đầu tiên, SessionStart cũng vậy, trước khi baton đầu tiên thất bại; `kit:plugin-update` tự in cả hai bước sau khi cập nhật plugin. Một phiên mở trước lần cập nhật vẫn chạy plugin cũ: phép kiểm của nó bảo khởi động lại Claude Code, và không bao giờ đưa ra launcher của plugin đó.

**Cách chia.** Cho phép các lệnh `new`, `check`, `rehearse`, `run`, `go`, `list`, `pack`, `log` và `sign --by coordinator-auto` của launcher. Hỏi với `sign --by owner` và `mode`, ở mọi cách viết của lệnh. Deny các tool ghi của Claude Code trên toàn bộ thư mục plugins của cấu hình Claude Code (cache và `installed_plugins.json` mà launcher tin) và trên state directory. Cùng khối đó tắt attribution của Claude Code (không có trailer đồng tác giả, không có dòng PR, không có URL phiên).

**Vì sao an toàn.** `run` bị chữ ký chặn cổng. `coordinator-auto` bị chính `baton.py` từ chối ngoài mode `auto` và với mọi run có `Stops` khác `none`, nên phiên chỉ ký được những gì quy tắc thường trực của owner đã cho phép. Chữ ký của owner và mode luôn mở hộp thoại. Một allow rule trên một lệnh chỉ an toàn bằng mức những thứ nó chạy không ghi được, điều mà các rule deny giữ. Các rule gọi tên launcher vì một permission rule không thể khớp "phiên bản bất kỳ" ở giữa đường dẫn. SessionStart nói trong một dòng khi kiểm tra thất bại.

