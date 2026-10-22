[English](DEVELOPMENT.md) | Tiếng Việt

# Phát triển

Cách làm việc trên chính kit, trong một bản checkout hay một bản fork: bố cục repo, cài từ một bản checkout, test, hợp đồng
consumer, phát hành và lấy repo theo một SHA. Muốn dùng kit, bắt đầu từ [README](README.vi.md); mục lục tài liệu là
[`docs/README.vi.md`](docs/README.vi.md). Kit không nhận pull request: câu hỏi, báo lỗi và đề xuất gửi vào issue của repo công khai
(xem [Đóng góp](README.vi.md#đóng-góp)).

## Bố cục

```
.claude-plugin/marketplace.json            marketplace "vibemaestro"
plugins/vibemaestro-sdlc/                  plugin quy trình: hook, luật, skill, script, cổng, baton, CONTRACT.md
plugins/vibemaestro-brain/                 plugin bộ nhớ: lệnh brain, hook, skill
docs/                                      các khái niệm, chuẩn BatonRun, kết quả nghiên cứu
.changes/                                  mỗi pull request đổi một plugin có một file thay đổi
.github/actions/fetch-plugin/action.yml    chép repo tại một SHA vào một thư mục
.github/workflows/                         CI: test, cổng export, kiểm thân PR
tests/                                     run-all.sh, các suite, fixture
scripts/                                   bản export công khai, cổng quét của nó và bộ quét thuật ngữ
```

Bên trong `plugins/vibemaestro-sdlc/`:

```
hooks/hooks.json            các lệnh SessionStart và PreToolUse (Edit, Write, NotebookEdit, Bash)
scripts/vsdlc.py            lõi hook; session-start.py, pre-edit.py và pre-bash.py là các điểm vào của nó
scripts/hookout.py          đầu ra hook: cảnh báo và khử trùng mỗi phiên một lần
scripts/rules.py            tra luật (applyTo, applyWhen, level: block); rule_packs.py luật của các plugin phụ thuộc
scripts/sdlc_config.py      đọc và kiểm config
scripts/kb.py               lệnh kb; kb_index.py (find, list, outline, check), kb_plan.py (plan status), init_setup.py (init)
scripts/current_state.py    các phép kiểm current-state và cổng diff
scripts/intent_branch.py    lõi branch, sau intent-branch.sh; open_pr.py lõi PR, sau open-pr.sh
scripts/install_gates.py    cài các cổng vào một repo
scripts/release.py          check, plan và cut một bản phát hành
scripts/baton.py            bộ chạy BatonRun; baton-launcher.py launcher ổn định
gates/                      các script cổng, gate_common.py, và workflows/ (mẫu workflow ghim SHA)
batons/                     các kit baton (kit:merge-pr, kit:gh-write, …)
templates/                  khung baton và các baton kind
```

Mọi thứ một plugin cần lúc chạy nằm trong thư mục của chính nó: bản cài của Claude Code chỉ chép thư mục đó và bỏ các symlink
trỏ ra ngoài nó, nên plugin không có symlink và không có đường dẫn `../..` với ra ngoài.

## Cài từ một bản checkout

```bash
claude plugin marketplace add <đường dẫn tới bản checkout>
claude plugin install vibemaestro-sdlc@vibemaestro
```

Rồi mở phiên mới trong một repo ứng dụng và kiểm `claude plugin list`. `tests/test-install.sh` chứng minh việc cài từ một thư
mục cục bộ. Thế nào là một bản cập nhật tuỳ vào `plugin.json` của plugin:

- **có `version`** (một cây đã phát hành mang version đã phát hành của từng plugin): bản cài được khoá theo version đó, và
  `claude plugin update` không thấy gì mới cho tới khi nó đổi; muốn thử một chỗ sửa, hãy nâng `version` trong `plugin.json`
  của plugin đó;
- **không có `version`**, Claude Code tự tính một version từ git và mỗi commit mới là một bản cập nhật: marketplace thêm từ một
  repo git hoặc URL lấy SHA commit của repo marketplace; thêm từ một thư mục cục bộ là bản checkout git thì lấy SHA HEAD của bản
  checkout (hãy pull trước); một thư mục cục bộ không có `.git` là `unknown`, và `plugin update` trả lời `refreshed from
  source`, nên nó theo đúng những gì thư mục đang chứa.

Cập nhật:

```bash
claude plugin marketplace update vibemaestro
claude plugin update vibemaestro-sdlc@vibemaestro
```

Khi không có version, phụ thuộc vào plugin anh em được ghi tên trần, không kèm khoảng version: một khoảng so với version mà Claude Code tính từ commit
sẽ nạp lỗi ("installed version unknown"). Một bản phát hành ghi version đã phát hành vào manifest của plugin và một khoảng
version trên mỗi phụ thuộc vào plugin anh em.

## Chạy test

```bash
bash tests/run-all.sh
```

Các suite không cần secret, không cần repo nào khác, không cần đặt biến vị trí nào. Cần: `python3` có PyYAML
(`pip3 install --user pyyaml`), `git` và `bash`; chúng chạy trên macOS (userland BSD) và Linux (userland GNU).

- Một suite: `bash tests/run-all.sh hook` (khớp theo tên). Chỉ các suite mà thay đổi chạm tới:
  `bash tests/run-all.sh --changed origin/main`; bộ lập kế hoạch `tests/plan.py` đọc `tests/suites.map`.
- Không có CLI `claude` thì các phần cần nó (validate, cài từ thư mục, chạy hook từ bản đã cài) in một dòng `SKIP`.
  `PLUGIN_REQUIRE_CLAUDE=1 bash tests/run-all.sh` buộc chúng phải chạy.
- Test kiểm code, không kiểm tài liệu: một đường dẫn trong `tests/map-exclusions.txt` (các README, `docs/`, ghi chú phát
  hành) không đánh thức suite nào, nên một thay đổi chỉ về tài liệu chỉ chạy các suite `@always`.
- Kiểm manifest bằng `claude plugin validate plugins/<tên>` và marketplace bằng `claude plugin validate .`.

CI: `.github/workflows/test.yml` chạy kế hoạch các suite đổi ở mỗi pull request và mỗi lần push vào `main`, trên runner do biến
repo `CI_RUNNER` chỉ định (runner của GitHub khi biến chưa đặt). Các job cổng (`export-gate`, `pr-body`, `scan-terms`) chạy
trên biến repo tùy chọn `CI_GATE_RUNNER` (một runner nhẹ), không có thì dùng `CI_RUNNER`. `.github/workflows/test-full.yml` chạy đủ bộ test hai lần một
tuần (Chủ nhật và thứ Tư, 19:00 UTC); một lần chạy đỏ mở một issue có nhãn `full-run-red`.

## Hợp đồng consumer

Plugin sdlc có một hợp đồng consumer viết thành văn,
[`plugins/vibemaestro-sdlc/CONTRACT.md`](plugins/vibemaestro-sdlc/CONTRACT.md), đi kèm trong plugin. Với mọi bản phát hành của major version ghi ở dòng `Frozen at`, nó đóng băng các mục nó liệt kê,
trong đó có: tên marketplace và id plugin; bố cục; action `.github/actions/fetch-plugin` và input duy nhất `dest` của nó; việc
nhận ra phiên worker bằng cả `INTENT_SLUG` và `SEAT`; việc thư mục plugin vẫn chạy khi được chép riêng ra khỏi một marketplace
đã clone; các điểm vào và script cổng cùng mọi mã thoát; config schema 1 với các key của nó; và cách tìm luật của một plugin
phụ thuộc. Mọi thứ khác (văn bản luật và skill, thông báo, các lõi Python sau hai adapter) có thể đổi trong một bản minor.

- `bash tests/test-contract.sh` chứng minh từng mục trên cây và đỏ khi danh sách và cây không khớp;
  `bash tests/test-contract.sh <id>` chứng minh một mục.
- Mọi pull request chạm vào `plugins/` giữ nó xanh. Một thay đổi bề mặt sửa `CONTRACT.md` trong cùng pull request và thêm một
  file thay đổi ghi `vibemaestro-sdlc` ở mức `major` (bỏ, đổi tên hoặc đổi nghĩa một thứ) hoặc `minor` (thêm hoặc viết lại); bản
  phát hành mang nó đặt `Frozen at`. Suite kiểm điều này so với `main`, cả trong CI.
- Một consumer tự động (một job CI, một bản build chép plugin) ghim một SHA đầy đủ của repo này ở một chỗ và chỉ dời nó bằng một pull
  request chạy test hợp đồng của chính nó. Máy laptop không ghim: nó cài từ marketplace và cập nhật.

## Phát hành

Một pull request đổi `plugins/<tên>/` thêm một file thay đổi dưới `.changes/` và không ghi version ở đâu cả; khuôn dạng nằm ở
[`.changes/README.md`](.changes/README.md). Một pull request phát hành biến mọi file thay đổi đang chờ thành một mục
`## <version>` trong `CHANGELOG.md` của từng plugin được nêu; chính sách version và các lệnh nằm trong README của sdlc,
[Chính sách phiên bản](plugins/vibemaestro-sdlc/README.vi.md#chính-sách-phiên-bản).

## Lấy repo theo một SHA

Composite action `.github/actions/fetch-plugin` chép toàn bộ repo tại SHA được gọi (không có `.git`) vào một thư mục, để làm
build context hoặc để lấy plugin theo một SHA đã ghim. Nó không cần secret và không gọi mạng.

```yaml
- uses: <owner>/<repo>/.github/actions/fetch-plugin@<SHA đầy đủ>
  with:
    dest: plugin-ctx          # input duy nhất, bắt buộc
```

`tests/test-fetch-plugin.sh` chạy bước `run` của action trên một bản checkout. Workflow của repo khác chỉ gọi được action khi Actions
của repo này được chia sẻ cho nó. Một repo khác dùng hai lõi branch và PR
(`intent_branch.py`, `open_pr.py` và hai adapter `.sh` của chúng) thì lấy chúng ghim theo một SHA của repo này: hai lõi đọc repo
mà chúng chạy trong đó, không đọc nơi chứa plugin.
