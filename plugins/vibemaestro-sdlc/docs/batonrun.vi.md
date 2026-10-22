[English](batonrun.md) | Tiếng Việt

# BatonRun

BatonRun là phương pháp vibemaestro dùng cho mọi hành động ghi ra ngoài phiên làm việc: ghi lên GitHub, đẩy lên registry, đổi cấu hình Claude Code của người dùng, xoá dữ liệu, thay đổi trên hệ thống đang chạy. Tài liệu này là **chuẩn** của BatonRun: nguồn duy nhất cho câu hỏi BatonRun là gì, một run chạy ra sao và giới hạn nằm ở đâu. Mọi nơi khác trỏ về đây:

- skill `batonrun` ([`plugins/vibemaestro-sdlc/skills/batonrun/`](../skills/batonrun/SKILL.md)) giữ **chỉ dẫn vận hành**: các lệnh, khung script, những gì `check` từ chối, mã thoát, cách giữ hoặc sửa một run. Tài liệu này đi kèm plugin đã cài (`docs/batonrun.md` ở gốc plugin), nhưng skill giữ đủ mọi chỉ dẫn một phiên cần, kể cả danh sách dừng, nên phiên không phải đọc nó;
- rule `batonrun` (`plugins/vibemaestro-sdlc/rules/batonrun.instructions.md`) là **lời nhắc** khi một lệnh đặc quyền bị gõ thẳng;
- runner [`plugins/vibemaestro-sdlc/scripts/baton.py`](../scripts/baton.py) là **cỗ máy**: khi code và văn bản này khác nhau thì code là thứ chạy, và chỗ khác nhau là lỗi của một trong hai.

Các phép đo và bài học đằng sau thiết kế nằm ở [`docs/research/batonrun.vi.md`](../../../docs/research/batonrun.vi.md). Muốn xem toàn bộ kit, bắt đầu từ [README](../../../README.vi.md).

## 1. BatonRun là gì

### Định nghĩa

Owner (chủ sở hữu) là người sở hữu repository và ký các run rủi ro: khi làm một mình, đó là bạn. Một **run** là một lần chạy hành động của một quy trình lặp lại: nhiều lệnh hoặc script theo một chuỗi cố định, thực thi như một khối có cổng kiểm soát. Phiên viết hoặc chọn run, máy kiểm tra và tổng duyệt (rehearse) nó, nó được ký một lần, phiên chạy nó, máy kiểm tra lại sau khi chạy, hoàn tác khi lỗi và ghi log. Owner không bao giờ phải gõ các dòng lệnh.

- **Một run, một cổng.** Cả chuỗi được trình bày, ký và chạy như một khối: chữ ký bao phủ mọi bước, nên không bước nào trong chuỗi chạy mà chưa ký, và không gì ngoài chuỗi chạy được bằng chữ ký đó.
- **Run nhỏ nhất là một lần ghi đặc quyền** (một bình luận, một lần merge, một lần push). Một lần ghi vẫn đi qua run: mỗi lần ghi không tốn hơn cách chạy trực tiếp (mục 7).
- **Một run do một baton script mang.** Script giữ chuỗi; các lệnh và script của plugin mà nó gọi là các bước của nó (`kit:merge-pr` chạy cổng merge; một session baton có thể chạy `open-pr.sh` như một lần ghi). Script là đơn vị kiểm tra và ký; run là đơn vị công việc và đơn vị log.
- **Lặp lại là điểm mấu chốt.** Quy trình lặp lại với cùng các lệnh trở thành một run có tên, được giữ và dùng lại (mục 4), nên lần sau chỉ là một lệnh, không phải viết lại script.

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
| session baton | baton script mà phiên viết cho việc đang làm, tại một đường dẫn mới |
| kind | baton script có sẵn mà plugin cung cấp cho một dạng việc lặp lại, chạy bằng `kind:<name> <args>`; `new --from <kind>` ghi nó ra file để sửa |
| kit run | baton script mà plugin cung cấp và đã review, chạy bằng `kit:<name> …`; chỉ kit run mới được chạy một gate của plugin |
| library run | run giữ trên một máy cho quy trình đã làm hai lần, chạy lại theo tên (mục 4) |
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
| write | phiên viết baton script (hoặc chọn một kind hay kit run): header (Purpose, Targets, Blast, Undo, Pre, Stops, Expect), hành động với mọi thay đổi đi qua `write()`, một post-check, một undo | hành động được nêu trước khi chạy |
| check | kiểm tra tĩnh văn bản: các trường header, cổng `write()` và cách rẽ phase đúng nguyên văn, `set -euo pipefail`, không ghi ngoài `write()`, không script cục bộ hay `source`, không `diff`/`grep`/`cmp` trần trong pipeline, mẫu dừng so với `Stops`, `bash -n`, `shellcheck -S error` nếu đã cài | lỗi cú pháp và hình dạng, một lần ghi bỏ qua cổng, một hành động dừng chưa khai báo |
| rehearse | script chạy ở phase `rehearse`: mọi lần đọc đều chạy, mọi lần ghi chỉ in plan line; kế hoạch được so với Expect từng dòng | lỗi logic, nhắm sai đích, thiếu điều kiện tiên quyết, kế hoạch không như ý định |
| seal | mã băm trên byte script, tham số, thư mục, các biến điều hướng công cụ, và kế hoạch | mọi thay đổi sau thời điểm này |
| sign | seal được duyệt, bởi phiên (`coordinator-auto`, chỉ mode `auto` và `Stops: none`) hoặc bởi owner trong một hộp thoại | một sự duyệt cho thứ khác với thứ đã được trình |
| run | rehearse lại, rồi phase `run`: dòng DO của mỗi lần ghi phải đúng kế hoạch đã ký; chữ ký bị dùng hết | thế giới đã đổi từ lúc ký, chạy lần hai |
| post-check with undo | phase `postcheck` (đọc lại sau 1, 2, 4 và 8 giây); khi lỗi thì phase `undo`, so từng đích với trạng thái trước | một lần ghi không giữ được; trạng thái làm dở bị bỏ lại |
| log | một dòng cho mỗi sự kiện trong `log.tsv` (thời gian, sự kiện, tên, mã băm script, binding, tham số, thư mục, người ký, mode, kết quả, đã undo, đường dẫn đầu ra); toàn bộ đầu ra nằm dưới `runs/` | một hành động không được kiểm toán |

**`go`** chạy các bước từ check đến log trong một lệnh và dừng ở bước đầu tiên lỗi, với mã thoát của bước đó và toàn bộ đầu ra của nó. Khi mọi bước đều đạt, nó in một dòng, `go: ok — <n> writes — <run log>`, và đó là tất cả những gì phiên báo cáo. Run cần owner (một từ Stops, hoặc mode `manual`, kể cả khi chưa chọn mode nào: mục 6) dừng sau rehearse với mã thoát 8 và các dữ kiện cho decision card; không có gì được ký và không có gì chạy. Các lệnh riêng (`check`, `rehearse`, `sign`, `run`, `log`) vẫn còn để owner ký và để chẩn đoán.

`go` chỉ chạy một session baton (và chỉ đọc file `--spec` của `kit:gh-write` và file rule của `kind:settings-merge`) từ một file được ghi trong 120 giây gần nhất, để một lần Write không thành công không bị nhầm là script mới; `go --reuse` chỉ định một file cũ hơn mà những byte đó là ý muốn dùng lại. Một session baton là một lần Write ra đường dẫn mới và `go <path>` trong cùng một lượt phản hồi. Dạng `go -` cũng tồn tại, nhưng nó không phải cách chạy một baton, vì Claude Code chặn heredoc chứa khung baton và heredoc là cách duy nhất để đưa dữ liệu vào nó (mục 8). Nó đọc script từ stdin, lưu một lần dưới state directory và chạy file đó, nên cùng một ràng buộc sha256 vẫn giữ từ check đến run.

### Lệnh

Mỗi lệnh có dạng `<launcher> <subcommand> …`. Khi chưa cài launcher (mục 9) hãy dùng `python3 <plugin root>/scripts/baton.py`. Các tuỳ chọn của runner đứng trước đường dẫn script; mọi thứ sau đường dẫn là tham số của chính script.

| Lệnh | Việc nó làm |
|---|---|
| `new <name> [--dir D] [--from <kind>]` | ghi `D/<name>.sh` từ template, hoặc từ một kind (`new --from <kind>`); không bao giờ ghi đè (mã thoát 6) |
| `check <script>` | kiểm tra tĩnh văn bản; mã thoát 0 hoặc 1 |
| `rehearse <script> [args…]` | check, rồi phase rehearse; in kế hoạch so với Expect và seal |
| `sign --by owner\|coordinator-auto --seal <seal> <script> [args…]` | check, chính sách mode, rehearse lại, rồi bản ghi chữ ký; `--by` đứng đầu, một lần, thành hai từ; seal không phải cái đã trình thì bị từ chối (mã thoát 3) |
| `run <script> [args…]` | lần chạy đã ký: rehearse lại, run, post-check, undo khi lỗi; một dòng `run: ok — <n> writes — <run log>` khi đạt |
| `go [--by coordinator-auto] [--reuse] <script> [args…]` | check, rehearse, seal, sign, run, post-check và log trong một lệnh; vòng đời ở trên. `<script>` là một đường dẫn, `kind:<name>` hoặc `kit:<name>`. `go -` lấy script từ stdin: không bao giờ dùng nó cho baton, Claude Code chặn |
| `log [--tail N]` | N dòng cuối của `log.tsv` (mặc định 20) |
| `log --last` | đường dẫn log của run mới nhất; nó được đặt trước khi script bắt đầu nên một run bị kill vẫn tìm được ở đây |
| `log --wait-names N1,N2,… [--timeout S] [--since T]` | chờ (tối đa 580 giây) đến khi dòng run mới nhất của mỗi script được nêu tên là ok; mã thoát 9 khi hết hạn |
| `mode [manual\|auto]` | in mode phê duyệt, hoặc đặt nó (mục 6) |
| `permissions --print` | in khối cài đặt người dùng cho bản cài này (mục 9) |
| `permissions --check [--settings F]…` | so các rule đang có với khối đó; không ghi gì; mã thoát 7 khi một rule thiếu, cũ hoặc không an toàn |
| `permissions --install-launcher` | chép launcher vào `<state-dir>/bin/baton` |
| `help [<topic>]` | in tóm tắt lệnh, hoặc một file tham chiếu của skill: `act`, `kinds`, `kits`, `modes`, `permissions`, `setup`, `limits` |

### Mã thoát

| Mã | Nghĩa |
|---|---|
| 0 | xong |
| 1 | script không đạt check hoặc rehearse (không có dòng verdict, kế hoạch khác Expect), hoặc `go` gặp một file đã cũ |
| 2 | môi trường: không có `bash`, hoặc không ghi được state directory |
| 3 | bị từ chối, chưa chạy gì: không chữ ký nào khớp, mode không cho phép người ký, hoặc lệnh dừng trước phase run |
| 4 | run hoặc post-check của nó lỗi, và undo đã đưa trạng thái về như cũ |
| 5 | không rõ trạng thái: run lỗi và undo cũng lỗi, hoặc run bị ngắt; báo owner ngay |
| 6 | `new`: file đã tồn tại |
| 7 | `permissions --check`: một rule thiếu, cũ hoặc không an toàn |
| 8 | `go`: baton cần chữ ký của owner; chưa ký gì, chưa chạy gì |
| 9 | `log --wait-names`: một script được nêu tên chưa có dòng run ok khi hết hạn |
| 64 | dùng sai cú pháp |
| 66 | không đọc được script, hoặc `log --last` khi chưa có run nào bắt đầu |

### Header

Mỗi baton script bắt đầu bằng các trường này, mỗi trường một dòng. `check` từ chối khi thiếu một trường, một trường xuất hiện hai lần hoặc `Expect` rỗng; `Each` chỉ dành cho kit script và thay cho các dòng `Expect`.

| Trường | Nội dung |
|---|---|
| `Purpose` | run làm gì, trong một câu; phiên tìm dòng này khi muốn tìm một run đã giữ |
| `Targets` | nó đụng tới những gì |
| `Blast` | nhiều nhất nó có thể thay đổi gì |
| `Undo` | cách đưa về như cũ, hoặc những gì nó để lại |
| `Pre` | điều gì phải đúng trước khi chạy |
| `Stops` | `none`, hoặc một hay nhiều từ của danh sách dừng (mục 6); owner ký khi nó không phải `none` |
| `Expect` | một dòng cho mỗi lần ghi, là shell glob trên cả plan line, theo thứ tự (bên dưới) |
| `Each` | chỉ kit script: một glob cho mọi plan line, cho run mà số lần ghi đến từ đầu vào của nó (`kit:gh-write`) |

**Expect khớp thế nào.** Rehearse thu một plan line cho mỗi lời gọi `write()`, theo thứ tự chúng chạy, và so dòng thứ i với dòng `Expect` thứ i như một shell glob trên cả dòng, phân biệt hoa thường. `*` là một chuỗi ký tự bất kỳ (kể cả dấu cách và `/`), `?` là một ký tự. Đây không phải khớp tiền tố, và số dòng phải bằng nhau: thiếu hoặc thừa một dòng là một dòng FAIL. Ví dụ plan `create docs/a b.txt` khớp `create *`; plan `create docs/a.txt` không khớp `create`.

### Khung mẫu

Một baton script đạt `check`. Thay header, hành động, post-check và undo; chép `write()`, `gh_state()` và `case` cuối nguyên văn. Để hỏi một đối tượng GitHub có tồn tại không, gọi `gh_state <api path>` như một câu lệnh riêng, rồi kiểm tra `$GH_STATE` (`exists` hoặc `absent`; giá trị khác thì script dừng).

```bash
#!/usr/bin/env bash
# Purpose: create one file holding a text
# Targets: the file named by the first argument
# Blast: that one file
# Undo: removes the file while it holds that text
# Pre: the file is absent
# Stops: none
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
DEST=$1
TEXT=$2
holds() { [ -f "$DEST" ] && cmp -s "$DEST" <(printf '%s\n' "$TEXT"); }
put() { printf '%s\n' "$TEXT" > "$DEST"; }
act() {
  if [ -e "$DEST" ]; then
    echo "REFUSE $DEST exists" >&2
    return 3
  fi
  write "create $DEST" put
}
postcheck() { holds; }
undo() {
  if holds; then
    write "remove $DEST" rm -f -- "$DEST"
  fi
  ! holds
}
case "$PHASE" in
  rehearse)
    act
    echo "VERDICT rehearse ok"
    ;;
  run)
    act
    echo "VERDICT run ok"
    ;;
  postcheck)
    postcheck
    echo "VERDICT postcheck ok"
    ;;
  undo)
    undo
    echo "VERDICT undo ok"
    ;;
  *)
    echo "unknown phase: $PHASE" >&2
    exit 64
    ;;
esac
```

### Chạy thử

Đoạn này chạy khung mẫu từ đầu đến cuối trong một state directory tạm. Chạy trong bash, từ thư mục gốc của một bản checkout repository này, trong một phiên shell. Lưu khung mẫu ở trên thành `demo.sh` trong thư mục tạm, rồi chạy `go` trong vòng 120 giây sau khi lưu (hoặc thêm `--reuse`).

```bash
BATON="python3 $PWD/plugins/vibemaestro-sdlc/scripts/baton.py"
export XDG_STATE_HOME="$(mktemp -d)"
DEMO="$(mktemp -d)"
# save the skeleton as "$DEMO/demo.sh", then:
cd "$DEMO"
$BATON check demo.sh
$BATON rehearse demo.sh "$DEMO/out.txt" hello
$BATON mode auto
$BATON go demo.sh "$DEMO/out.txt" hello
cat "$DEMO/out.txt"
$BATON log --tail 3
```

`XDG_STATE_HOME` trỏ mode, chữ ký và log vào một thư mục dùng một lần, nên bản chạy thử không bao giờ đổi mode phê duyệt thật của bạn. Sau `mode auto`, phiên được tự ký run `Stops: none` này, nên `go` kết thúc bằng một dòng `go: ok` và `out.txt` chứa `hello`. Ở mode `manual`, cũng lệnh `go` đó dừng sau rehearse với mã thoát 8 và decision card cho owner.

## 4. Khi nào một quy trình thành run, và run nằm ở đâu

**Mọi lần ghi ra ngoài phiên đều là một run**, ngay từ lần đầu: không có ngưỡng nào dưới đó một lần ghi đặc quyền được gõ thẳng. Điều mà quy tắc hai lần quyết định là run có được **giữ** hay không:

- **Làm hai lần → một library run.** Lần thứ hai phiên viết cùng một chuỗi, nó giữ script thành library run trên máy đó và từ đó chạy theo tên.
- **Dùng giữa nhiều phiên hoặc nhiều repo → một kit run.** Library run mà các phiên hay repo khác cần sẽ tự đề xuất vào kit (bên dưới) và thành một kit run hoặc một kind, tức code plugin đã review.
- Một chuỗi dùng một lần vẫn là session baton: viết ở đường dẫn mới, chạy, ghi log, không giữ.

**Run nằm ở đâu.**

| Run | Nằm ở | Chạy bằng |
|---|---|---|
| kit run | `plugins/vibemaestro-sdlc/batons/<name>.sh` (code plugin có phiên bản; các gate nó chạy nằm trong `gates/`) | `<launcher> go kit:<name> …` |
| kind | `plugins/vibemaestro-sdlc/templates/baton-kinds/` | `<launcher> go kind:<name> <args>` |
| run của plugin phụ thuộc | thư mục `batons/` của plugin đó (một plugin cùng marketplace phụ thuộc `vibemaestro-sdlc`) | `<launcher> go kit:<name> …` (`help kits`: cách tìm và tin nó) |
| library run | `<library>` = `$XDG_DATA_HOME/vibemaestro/batons/`, nếu không có thì `~/.local/share/vibemaestro/batons/`: theo từng máy, ngoài mọi repository | `<launcher> go --reuse <library>/<name>.sh …` |
| session baton | một đường dẫn mới do phiên viết (thư mục tạm); không bao giờ qua stdin (`go -` với heredoc baton bị chặn, mục 8) | `<launcher> go <path> …` |

**Library** là một quy ước, không phải một lệnh: phiên giữ run ở đó bằng tool Write (state directory bị đóng với các tool ghi, library thì không) và chạy bằng `go --reuse`, vì file cũ hơn 120 giây mà `go` đòi ở một file mới. `--reuse` chỉ dùng sau khi đã đọc sha256 và dòng `Purpose:` của file (một lệnh `go` thường trên file cũ in cả hai, kèm lệnh `--reuse` chính xác, và không chạy gì), khi đúng những byte đó là ý muốn. Library run không phải code đã review: mỗi lần chạy nó đều được check, rehearse và ký như một session baton, nó không được chạy gate, và `Stops:` của nó quyết định ai ký. Tham số của nó mang những gì thay đổi giữa các lần chạy; nó không giữ bí mật hay giá trị riêng của một repository mà tham số có thể mang thay. Tên launcher `lib:<name>` cho nó chưa được xây.

**Đặt tên và tìm kiếm.** Một run có tên kebab-case ngắn nói nó làm gì (`merge-pr`, `gh-write`, `ci-rerun-failed`), và dòng header `Purpose:` nói điều đó trong một câu; dòng đó là thứ phiên tìm khi cần một run (`grep '^# Purpose:' <library>/*.sh`). Các kit run và kind được liệt kê ở mục 5. Không có lệnh nào liệt kê chúng: `<launcher> help kits` và `<launcher> help kinds` in các file tham chiếu của skill về cách chạy chúng. Phiên giao nhiều run cho một subagent đặt tên chúng `<prefix>-<act>.sh` với tiền tố riêng, để `log --wait-names` chờ đúng những tên đó.

**Run bị kill.** `run` và `go` in một dòng khi đạt, nên một run bị kill trước khi kết thúc (SIGKILL, hết thời gian của tool) không in gì. Trước khi script bắt đầu, runner ghi một dòng `run-start` vào `log.tsv` và đường dẫn log của run vào `runs/LAST`; `<launcher> log --last` in đường dẫn đó.

**Một library run tự đề xuất vào kit thế nào.** Mở một issue trong repo công khai của kit, mang script, nó làm gì, log cho thấy bao nhiêu lần chạy và chúng có đạt không, và còn cần ở đâu nữa. Run thuộc miền của sdlc thành một run `kit:` hoặc một `kind:` trong `vibemaestro-sdlc`. Run thuộc về một plugin phụ thuộc được đưa vào thư mục `batons/` của plugin đó và chạy dưới dạng `kit:<name>`, qua mọi bước kiểm tra như một kit của sdlc; một tên mà hai plugin cùng có thì không chạy ở đâu cả, nên tên kit là duy nhất giữa các plugin.

### Một run phát triển như thế nào

Quy tắc: **một run đại diện cho một quy trình, nên quy trình đổi thì cập nhật run đó, không bao giờ tách ra một bản sao.** Phép thử là nó có còn là cùng một quy trình hay không: cùng mục đích, đích và rủi ro.

- Một bước cần mọi lần: thêm vào run.
- Một bước thỉnh thoảng mới cần: một tham số của run. Chữ ký ràng buộc tham số, nên plan cho thấy nó.
- Mục đích khác hoặc đích khác, hoặc một từ Stops mới: một run mới có tên riêng.
- Một bước gặp lần đầu: lần này là session baton; lần thứ hai thì gộp vào run (quy tắc hai lần áp dụng cho cả thay đổi).

Rào chắn:

- Một thay đổi trong cùng quy trình mà mở rộng những gì run đụng tới thì cập nhật header của nó. Một từ Stops mới tạo ra một run mới (ở trên), và owner ký run đó từ đó về sau.
- Một kit run chỉ đổi qua một kit PR; trong lúc đó bước thêm chạy thành một run riêng ngay sau nó.
- Chữ ký ràng buộc sha256 của script và log ghi lại nó, nên phiên bản nào của run đã chạy vẫn biết được.

## 5. Danh mục run

Các kit run và kind, mỗi cái một dòng. Skill nêu cách gọi chúng; phiên bản plugin ràng buộc chúng vào chữ ký.

| Run | Làm gì | Stops |
|---|---|---|
| `kit:merge-pr` | merge có cổng kiểm soát: rehearse là lần chạy thử của cổng (head được ghim, CI, xung đột, deny glob, glob của brief, …), run merge đúng head đã ký; merge không đảo ngược được, đường lui là một revert PR. Tham số: `--repo`, `--pr`, `--head`, `--brief` và các tuỳ chọn của cổng | none |
| `kit:gh-write` | các lần ghi GitHub nhỏ từ một spec JSON: issue-create, issue-comment, comment-edit, issue-edit, pr-body-edit, issue-reopen, issue-close, pr-close và pr-ready (ghim head), pr-create (từ một branch đã push, ghim head), file-pr (một file được thêm hoặc thay trên một branch mới từ đỉnh base, blob bị thay được ghim, rồi PR của nó); từ chối repo công khai, việc xoá, việc tạo repo và một đường dẫn workflow; undo không bao giờ xoá, và nêu tên branch nó để lại. Tham số: `--spec <file>` | none |
| `kit:coordinator-bootstrap` | dựng một máy mới hoặc vừa chuyển cho BatonRun: một báo cáo máy, rồi launcher và khối permission đã in (tắt attribution nếu chưa có khoá) qua `kind:settings-merge`; bị từ chối ở rehearse khi không có gì để làm; undo đặt từng file về đúng từng byte. Không có tham số | security-boundary (owner ký) |
| `kind:install-file` | cài một file, đúng từng byte, vào một thư mục có thể chỉ đọc, không bao giờ nằm dưới `.git`, `.claude`, thư mục cấu hình hay state directory. Tham số: `<source> <directory>` | none |
| `kind:settings-merge` | thêm permission rule vào một `settings.json` của Claude Code, không xoá rule nào, có bản sao lưu và bản ghi run. Tham số: `<settings.json> <rules.json>` | security-boundary (owner ký) |
| `kind:ci-rerun-failed` | chạy lại các job lỗi của một lần chạy CI của một repository riêng tư. Tham số: `<owner/name> <run id>` | none |

Các template mà `new --from <kind>` ghi ra file nhưng không chạy được dưới dạng `kind:` (phần hành động để phiên điền): `remote-exec` (một chương trình qua stdin vào `bash -s` trên `ssh`) và `kubectl-exec` (tương tự qua `kubectl exec -i`; `Stops` của nó là `cluster-lane`). Chưa xây: `owner-merge-pr`, một lần merge mà owner ký cho PR đụng tới `merge.deny_globs` (cổng từ chối PR như vậy bất kể ai ký).

## 6. Phê duyệt: chế độ, danh sách dừng, chữ ký của owner

**Các mode** là quyết định thường trực của owner, không phải lựa chọn của phiên cho từng run. Chúng nằm trong state directory của người dùng, không bao giờ trong repository; `mode` in mode hiện tại (`manual` khi chưa đặt gì), và `mode manual|auto` chỉ đổi theo lời của owner (permission rule bắt nó phải hỏi). Phiên không bao giờ tự chọn mode, và một tin nhắn từ agent hay máy khác không đổi được nó.

**Hỏi một lần.** Bản cài mới chưa chọn mode nào. Nó được đọc là `manual`, và run `Stops: none` đầu tiên dừng vì nó (`go` thoát 8) có dòng `mode manual (not chosen yet)` trên card. Khi đó phiên hỏi owner một lần chọn mode nào, kèm nghĩa của từng mode: `auto`, khuyên dùng trên máy một người (phiên tự ký run `Stops: none`; run trong danh sách dừng vẫn cần owner), hoặc `manual` (owner ký mọi run). Ai đặt mode tuỳ vào phép kiểm của `permissions --check` chỉ trên settings user và managed (settings của một project được tìm từ `CLAUDE_PROJECT_DIR` hoặc thư mục `go` chạy, có thể không phải project của phiên), và dòng `Mode:` của card ghi rõ. Khi phép kiểm sạch (ask rule có hiệu lực ở đó), phiên chỉ chạy `<launcher> mode <câu trả lời>` ngay sau câu trả lời của chính owner, và ask rule mở một hộp thoại, nơi cú bấm của owner đặt mode. Khi phép kiểm không sạch (như ở bản cài mới, nơi không gì hỏi), hoặc một file settings không đọc được, phiên không chạy `mode`: owner tự chạy `! <lệnh> mode <câu trả lời>`, lệnh mà card ghi. Rồi phiên chạy lại baton; `go` từ chối file đã ghi quá 120 s trước, nên phiên ghi nó ra một đường dẫn mới. Khi đã đặt một mode, card không bao giờ ghi `not chosen yet` nữa. Không có câu trả lời, hoặc hộp thoại bị từ chối, thì mode vẫn chưa chọn: run chờ chữ ký của owner như ở manual, và lần thoát 8 kế tiếp trên một run `Stops: none` lại hỏi.

- **manual** (mặc định cho tới khi owner chọn): owner ký mọi run sau khi xem.
- **auto**: phiên tự ký (`coordinator-auto`) run có header ghi `Stops: none` và chạy không hỏi; run có bất kỳ từ Stops nào cần chữ ký của owner, như ở manual.
- Ở auto, điều kiện tiên quyết thất bại hay Expect không khớp không phải là điểm dừng: phiên sửa script và rehearse lại, miễn là bản sửa không mở rộng những gì run đụng tới. Bản sửa mở rộng thì cần owner.

**Danh sách dừng.** Run làm bất kỳ việc nào dưới đây phải khai báo trong `Stops:`, và khi đó chỉ owner ký, ở mọi mode:

| Từ | Run … |
|---|---|
| `irreversible-delete` | xoá dữ liệu không thể lấy lại: volume có dữ liệu, namespace, phiên bản package, repository, nhánh chưa merge, tag, đường dẫn secret, cơ sở dữ liệu |
| `secrets` | đọc, in, ghi hoặc xoay vòng một secret |
| `security-boundary` | mở rộng một ranh giới: RBAC, admission hoặc network policy, công khai một thứ, một lối vòng quyền admin ngoài rule sẵn có của owner |
| `cluster-lane` | thay đổi một cluster đang chạy ngoài làn đã duyệt: tạm dừng reconciliation, drain node |
| `history-rewrite` | force-push hoặc viết lại lịch sử trên nhánh dùng chung |
| `money-org` | đụng tới thanh toán, gói dịch vụ hoặc quản trị tổ chức (tạo hay đổi tên repository, thành viên) |
| `publish` | đăng ra ngoài: nơi công khai, repository của người khác |
| `no-way-back` | không thể rehearse cũng không thể undo |
| `owner-acts` | là hành động mà một quyết định trước đó của owner chỉ định chính owner làm |

`check` đánh dấu một dòng thân script trông như hành động dừng, nêu nhóm, từ và header cần thêm; lint đó là lưới đỡ, không phải chứng minh: một run khai báo những gì nó làm, không phải những gì lint tìm thấy. Lint chỉ biết một số hành động trên cluster (`flux suspend`, `kubectl … drain|cordon`).

**Chữ ký của owner** là cú nhấp của owner trong một hộp thoại: phiên chạy `sign --by owner --seal <seal> …`, permission rule bắt lệnh đó phải hỏi, và hộp thoại hiển thị nó. Khi `go` dừng với mã thoát 8, nó in các dữ kiện cho owner (các lần ghi làm gì, vì sao, blast, undo, lý do dừng, đã kiểm gì) và hai lệnh để chạy khi owner đồng ý. Seal không còn khớp với thứ đã trình thì bị từ chối. **Không hiện hộp thoại, hoặc hộp thoại bị từ chối, nghĩa là chưa được xác nhận**: phiên ghi run là đang chờ và nói rõ như vậy; không bao giờ thử lại `sign` trong vòng lặp và không bao giờ coi im lặng là đồng ý.

**Decision card.** Ngay trước hộp thoại của owner, phiên viết, bằng ngôn ngữ của owner, tối đa bảy dòng ngắn: nó ghi gì, ở đâu, vì sao (quyết định hay nhu cầu), tác động, undo (hoặc "không thể hoàn tác"), một rủi ro, và đã kiểm gì (check ok, rehearse ok, plan khớp Expect, N lần ghi). Mô tả của lệnh `sign`, thứ hộp thoại hiển thị, là dòng đầu của card; seal, đường dẫn và đầu ra rehearse đi sau, làm chi tiết.

## 7. Chi phí

**Mục tiêu**: một run không được tốn hơn cách chạy trực tiếp (gọi tool, hoặc một script do model viết rồi chạy), với độ an toàn không đổi. Khi thành công chỉ in thành công; khi lỗi thì in chi tiết.

**Mỗi lần ghi, run ngang bằng cách chạy trực tiếp.** Còn lại là phần một lần mỗi phiên: đọc skill mất 2 đến 3 lượt. Các kiểm tra là kiểm tra của máy và gần như không tốn gì; chi phí là các lượt của model và đầu ra giữ trong ngữ cảnh, nên `go` tồn tại, nên nó in một dòng, và nên phần lõi của skill đủ cho một run thường. Các phép so sánh đứng sau điều này dùng mẫu nhỏ (2 đến 3 mỗi nhánh và mỗi task) chạy bằng subagent, và số lượt của nhánh chạy trực tiếp tự dao động ±1 hoặc hơn: hãy đọc là "ngang bằng", không phải "tiết kiệm". Phương pháp và số liệu nằm ở [`docs/research/batonrun.vi.md`](../../../docs/research/batonrun.vi.md).

**Chạy nhiều run.** Mặc định chạy tại chỗ, bao nhiêu cũng được. Chỉ giao ba run trở lên cho một subagent worker để giữ ngữ cảnh chính còn nhỏ khi nó đã lớn (trên khoảng 400k token): giao việc chỉ rẻ hơn ở task nhiều run đầu tiên của một phiên. Phiên chính khi đó chờ trên log theo đúng tên script (`log --wait-names`), và tin dòng log, là bằng chứng của máy, chứ không tin báo cáo của worker.

## 8. Giới hạn

Những gì baton không bảo vệ:

- **Trung thực, không phải thù địch.** BatonRun bảo vệ một phiên có thể sai sót, không phải một phiên cố tình lừa (mục 1). `check` đọc văn bản; nó không chạy văn bản, nên một cách gián tiếp che giấu một run (`eval`, tên dựng lúc chạy, launcher nằm sau một biến) là giả mạo, không phải kẽ hở để lách.
- **Rule và hook khuyên; chúng không chặn.** Rule nhắc một lần mỗi phiên khi một lệnh đặc quyền bị gõ thẳng, chỉ trên dòng lệnh. Hook cảnh báo với mọi lệnh launcher `sign`, `run` hoặc `go` không "trần" (pipe, chuỗi lệnh, redirect, substitution, tiền tố hoặc shell wrapper), vì khi đó các allow rule không khớp và bộ phân loại auto-mode của Claude Code quyết định.
- **Permission rule khớp theo văn bản lệnh,** không theo thứ shell biến nó thành, và rule Edit bao phủ các tool ghi và các lệnh file mà Claude Code nhận ra, không phải mọi tiến trình. `permissions --check` chỉ đọc các rule: không đọc `defaultMode`, lần khởi động bỏ qua quyền, hay cấu hình của bộ phân loại.
- **Script của plugin được tin từ gốc plugin mà `baton.py` chạy từ đó,** chỉ như lệnh của một lần ghi có sha256 trong plan line; `scripts/` bị đổi giữa một phase sẽ được phát hiện sau phase, không bị ngăn.
- **Điều `go` không biết:** một file mới có chứa đúng thứ ý muốn không (một Edit không áp dụng được), và bất cứ điều gì về một file mà chính script đọc, trừ khi sha256 của nó nằm trong plan line.
- **Mode đến từ owner, không đến từ một tin nhắn.** Một phiên không thể bảo agent hay máy khác đổi mode phê duyệt của nó.
- **`go -` với một baton bị Claude Code chặn.** Ở permission mode mặc định (đã thử với Claude Code 2.1.303, `-p --permission-mode default`, allow rule `Bash(<launcher> go:*)`) allow rule khớp một heredoc `go -` ngắn, nhưng heredoc chứa khung baton bị chặn trước khi rule nào được áp dụng, bởi kiểm tra riêng của tool ("Contains brace with quote character (expansion obfuscation)"), vốn kích hoạt với mọi thân hàm `{ … }` có chứa dấu nháy (`write()`, `gh_state()`). Auto mode chưa được thử. Default là mode được hỗ trợ, nên chuẩn không phụ thuộc vào auto: một session baton là một lần Write ra đường dẫn mới và `go <path>`. Kiểm tra đó là kiểm tra an toàn của tool; khung mẫu không bị sửa hình dạng để né nó. Hook im lặng với một heredoc `go -` có delimiter đặt trong nháy, dù heredoc đó bị chặn với baton, và nêu tên mọi dạng khác (delimiter không đặt trong nháy để shell khai triển phần thân trước khi baton đọc byte nào; một dòng sau dòng đóng là một lệnh riêng).
- **Merge, publish và những việc tương tự không thể hoàn tác.** Run nói điều đó trong `Undo:`; khi nó lỗi sau khi thế giới đã đổi, nó kết thúc với mã thoát 5 và owner được báo ngay.

## 9. Cài đặt quyền

Một lần mỗi máy, phiên chạy ba lệnh và owner áp dụng kết quả; plugin không bao giờ tự ghi settings:

1. `permissions --install-launcher` chép launcher vào `<state-dir>/bin/baton`. Nó chạy vibemaestro-sdlc mới nhất đã cài từ plugin cache và từ chối mọi `baton.py` khác.
2. `permissions --print` in khối cài đặt người dùng; owner thêm nó qua phần settings của Claude Code.
3. `permissions --check` cho biết các rule đang có có giữ đúng cách chia hay không (mã thoát 0) hoặc nêu từng rule thiếu, cũ hoặc không an toàn (mã thoát 7).

Kit run `kit:coordinator-bootstrap` có thể làm bước 1 và 2 trong một run do owner ký (skill `coordinator-bootstrap`).

**Cách chia.** Cho phép các lệnh `new`, `check`, `rehearse`, `run`, `go`, `log` và `sign --by coordinator-auto` của launcher. Hỏi với `sign --by owner` và `mode`, ở mọi cách viết của lệnh. Deny các tool ghi của Claude Code trên toàn bộ thư mục plugins của cấu hình Claude Code (cache và `installed_plugins.json` mà launcher tin) và trên state directory. Cùng khối đó tắt attribution của Claude Code (không có trailer đồng tác giả, không có dòng PR, không có URL phiên).

**Vì sao an toàn.** `run` bị chữ ký chặn cổng. `coordinator-auto` bị chính `baton.py` từ chối ngoài mode `auto` và với mọi run có `Stops` khác `none`, nên phiên chỉ ký được những gì quy tắc thường trực của owner đã cho phép. Chữ ký của owner và mode luôn mở hộp thoại. Một allow rule trên một lệnh chỉ an toàn bằng mức những thứ nó chạy không ghi được, điều mà các rule deny giữ. Các rule gọi tên launcher vì một permission rule không thể khớp "phiên bản bất kỳ" ở giữa đường dẫn. Nâng cấp plugin không cần làm gì; SessionStart nói trong một dòng khi kiểm tra thất bại.

