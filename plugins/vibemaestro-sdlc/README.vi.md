[English](README.md) | Tiếng Việt

# vibemaestro-sdlc

Plugin Claude Code cho một phiên làm việc trong repo ứng dụng, đem lại một quy trình duy nhất: **intent → spec → plan → ship**. Plugin ghi lại điều người dùng yêu cầu, đòi một spec đã được duyệt trước khi viết code, chia việc lớn thành các task, rồi mở pull request kèm bằng chứng chạy. Quy trình, luật, hook và script đều nằm trong thư mục plugin. Lúc chạy, plugin không đọc repo nào khác.

Phiên bản: xem `.claude-plugin/plugin.json`. Ghi chú phát hành: [CHANGELOG.md](CHANGELOG.md). Giao diện đóng băng cho consumer tự động: [CONTRACT.md](CONTRACT.md).

## Plugin làm gì

Trong phiên mở ở repo ứng dụng, plugin làm bốn việc.

1. **Lúc mở phiên**, plugin giao cho phiên lõi làm việc ([workflow-core](rules/workflow-core.instructions.md)), danh mục luật, lời nhắc về chuỗi skill và lời nhắc về `kb/` của chính repo đó. Việc này cần hai hook `SessionStart`, vì Claude Code giới hạn mỗi hook in ra tối đa 10.000 ký tự.
2. **Trước khi sửa file** (`Edit`, `Write`, `NotebookEdit`), plugin nhắc mọi luật có `applyTo` khớp file đó, và mọi file `kb/decisions/*.md` của repo có `applyTo` khớp.
3. **Trước khi chạy lệnh shell** (`Bash`), plugin nhắc mọi luật có `applyWhen` khớp lệnh. Luật có `level: block` thì chặn lệnh thay vì chỉ nhắc. Luật nào của plugin cũng không dùng `block`; luật của repo thì có thể.
4. **Trong phiên worker** (cả hai biến môi trường `INTENT_SLUG` và `SEAT` cùng có giá trị, như một công cụ mở phiên thay bạn có thể đặt; phiên bạn tự mở không có biến nào trong hai biến đó), plugin thêm một lời nhắc: ghi intent nguyên văn, viết spec, xin người duyệt, rồi mới sửa code. Đây là lời nhắc, không phải cổng chặn.

Tính chất của hook:

- Hook không bao giờ làm công cụ lỗi cứng. Mọi lệnh hook thoát với mã 0, kể cả khi đầu vào không phải JSON.
- Plugin hỏng (thiếu `rules/`, thiếu lõi) thì cảnh báo to ở đầu phiên. Plugin không giả vờ đã giao luật.
- Luật khớp được hiện một lần mỗi phiên. Một lệnh bị chặn bởi `level: block` thì bị chặn mỗi lần.
- Hook còn cảnh báo khi bản checkout tụt sau nhánh upstream, thêm ghi chú về kích thước và về trang sổ khi bạn sửa file sổ, và thêm một dòng lúc mở phiên khi phép kiểm quyền BatonRun thấy thiếu gì đó.
- Hook im khi `.vibemaestro/sdlc.json` đặt `"hooks": "off"`. Repo có hook tra luật riêng trong `.claude/settings.json` phải đặt `"hooks": "off"` hoặc gỡ chúng đi: hai bộ hook cộng dồn, không tự loại trùng.
- Luật của plugin khác đã cài và khai phụ thuộc vào plugin này được chính các hook này giao.

Quy trình, theo skill:

```
intake → brainstorm (chỉ khi yêu cầu còn mơ hồ) → spec → plan (chỉ khi phải chia việc) → ship
```

Mọi yêu cầu thay đổi đều bắt đầu bằng `intake`. Người dùng duyệt spec trước khi có code. Hành động đặc quyền (merge, đẩy lên registry, xóa) đi qua `batonrun`.

## Một việc hay nhiều việc

Plugin làm cho một người trên một máy, với `vibemaestro-brain` bên cạnh.

- **Một việc** chạy trong phiên bạn mở, từ `intake` đến một pull request nháp. Bạn duyệt spec và bạn merge pull request.
- **Nhiều việc cùng lúc:** skill `local-parallel`. Phiên chính mở một subagent cho mỗi việc, mỗi subagent trong một git worktree riêng, từ `intake` đến một pull request nháp, chuyển từng spec cho bạn, giữ hàng đợi, hậu kiểm từng pull request và merge nó bằng `kit:merge-pr`.

Plugin không cần plugin nào khác và không đọc repo nào khác.

## Yêu cầu

| Cần | Dùng cho | Ghi chú |
|---|---|---|
| Claude Code CLI (`claude`) | mọi thứ | đã thử với 2.1.290 |
| `python3` 3.8 trở lên | hook, `kb.py`, các lõi, các cổng | chỉ thư viện chuẩn |
| `git` | mọi thứ | quy trình làm việc trong worktree nằm trong repo |
| `bash` | các adapter `.sh` | đã thử trên Linux và macOS |
| `gh` (GitHub CLI), đã đăng nhập | `intake` (issue theo dõi), `ship` (mở PR), `install-gates` (kiểm runner), `batonrun` | quy trình viết cho GitHub |

Chưa thử trên Windows.

## Cài đặt và cập nhật

Plugin nằm trong marketplace `vibemaestro`, id plugin `vibemaestro-sdlc@vibemaestro`.

```bash
claude plugin marketplace add vibemaestro/vibemaestro-kit
claude plugin install vibemaestro-sdlc@vibemaestro
```

Muốn dùng một bản sao cục bộ hoặc một bản fork, hãy đưa thư mục của nó cho `claude plugin marketplace add`. Cài xong, mở phiên mới trong repo ứng dụng. Kiểm bằng `claude plugin list`: dòng `Version:` là phiên bản đã cài.

Để cập nhật:

```bash
claude plugin marketplace update vibemaestro
claude plugin update vibemaestro-sdlc@vibemaestro
```

Rồi mở phiên mới. Bản cài được lưu cache, và `claude plugin update` báo `nothing to update` cho tới khi một bản phát hành đổi `version` (xem [Chính sách phiên bản](#chính-sách-phiên-bản)).

`vibemaestro-brain` khai phụ thuộc `vibemaestro-sdlc`. Cài nó là cài luôn plugin này.

## Bắt đầu nhanh

Mở một phiên trong repo ứng dụng và bảo Claude chạy skill `init-kb`. Skill ghi `kb/` (`intent/`, `specs/`, `plans/`, `decisions/`, một `README.md`, `current-state.md`), `.vibemaestro/sdlc.json` và một thư mục luật có một luật mẫu, commit chúng trên branch `chore/kb-init` và push lên. Nó không ghi đè gì và chạy lại an toàn. Merge branch đó trước để khởi đầu gọn; khi nó chưa được merge, `intake` cắt branch intent đầu tiên từ `chore/kb-init`, và pull request đó mang theo commit dựng khung. Rồi mô tả một thay đổi; lời nhắc lúc mở phiên chỉ Claude tới `vibemaestro-sdlc:intake`.

Các script đứng sau skill cũng chạy tay được. Các lệnh dùng `$SDLC` cho thư mục plugin: bản đã cài, `~/.claude/plugins/cache/vibemaestro/vibemaestro-sdlc/<version>/`, hoặc `plugins/vibemaestro-sdlc` của một bản checkout. Trong phiên, các skill dùng `${CLAUDE_PLUGIN_ROOT}` cho cùng thư mục đó.

```bash
export SDLC=<thư mục plugin>
cd <repo ứng dụng của bạn>
python3 "$SDLC/scripts/kb.py" init --lang en --dry-run
python3 "$SDLC/scripts/install_gates.py" --dry-run
```

`kb.py init --dry-run` in những gì `init-kb` sẽ ghi, không ghi gì. Khi đã có config, `python3 "$SDLC/scripts/kb.py" config check` kiểm nó. `install_gates.py --dry-run` liệt kê các file cổng sẽ được ghi.

## Skill

Skill được gọi theo tên, `vibemaestro-sdlc:<tên>`. Chúng ghi vào `kb/` của repo bạn đang đứng.

| Skill | Việc làm | Kích hoạt khi |
|---|---|---|
| `init-kb` | Dựng `kb/` tự đủ và config của repo (`.vibemaestro/sdlc.json`, một thư mục luật). Chạy lại an toàn; `--adopt` cho repo đã có file quy trình. | repo chưa có `kb/`, thiếu một thư mục của nó, hoặc vừa dùng plugin |
| `intake` | Ghi yêu cầu bằng lời của người dùng thành `kb/intent/<ngày>-<slug>.md`, tạo branch `intent/<ngày>-<slug>` và issue theo dõi. | người dùng giao một việc mới |
| `brainstorm` | Làm rõ yêu cầu mơ hồ và ghi mục `Brainstorm result` vào file intent. Không tạo file spec riêng. | yêu cầu còn mơ hồ hoặc cần chọn hướng |
| `spec` | Viết `kb/specs/<ngày>-<slug>.md` theo khuôn bốn mục (bối cảnh, mục tiêu, ngoài phạm vi, tiêu chí chấp nhận) và xin người dùng duyệt trước khi có code. | intent đã ghi và chưa có spec nào được duyệt |
| `plan` | Viết `kb/plans/<ngày>-<slug>.md`, mỗi PR một hàng kèm lệnh nghiệm thu; nối intent vào hàng; đọc trạng thái sống bằng `kb.py plan status`. | một chủ đề cần hai PR trở lên, hoặc có người hỏi trạng thái của nó |
| `ship` | Viết đè `kb/current-state.md`, chạy các lệnh nghiệm thu, ghi bằng chứng, rồi mở PR draft bằng `scripts/open-pr.sh`. | việc của một intent đã xong |
| `release` | Cắt PR release hoặc PR hotfix của một repo marketplace plugin bằng `scripts/release.py`; công bố bản release đã merge là bước riêng của repo. | hàng release của plan đến hạn, hoặc plugin đã cài cần hotfix |
| `install-gates` | Cài sáu cổng quy trình thành workflow GitHub kèm script. Hỏi cổng nào và runner nào. Không bao giờ ghi đè. | repo muốn có các cổng đứng sau luật |
| `batonrun` | Chạy một hành động ghi ra ngoài phiên thành một baton script: kiểm, diễn tập, ký, chạy, kiểm sau, ghi log. | merge, đẩy registry, xóa, force-push, đổi cấu hình plugin của người dùng |
| `coordinator-bootstrap` | Dựng một máy cho BatonRun trong một run do chủ ký: launcher và khối quyền. | một máy mới, hoặc kiểm quyền lúc mở phiên báo lỗi |
| `local-parallel` | Chạy nhiều việc cùng lúc trên một máy: mỗi việc một subagent (worktree riêng, `intake` đến PR nháp, model `agents.worker_model`); phiên chính giữ hàng đợi, chuyển lời duyệt spec, hậu kiểm từng PR và merge bằng `kit:merge-pr`. | người dùng muốn làm nhiều việc song song |

Các cách đọc `kb/` mà không nạp cả file: `kb.py find <từ khóa>`, `kb.py list [--type T] [--status S]`, `kb.py outline <file>`. Cả ba chỉ đọc.

## Cổng (gate)

Cổng là một script biến một luật thành đạt hoặc không đạt. Cổng thoát 0 khi đạt, 1 khi đỏ, 2 khi không kết luận được (không bao giờ xanh), 64 khi dùng sai, 65 khi config không hợp lệ. Trong CI, workflow đọc config từ nhánh **base** của pull request, nên một PR không thể nới cổng của chính nó bằng cách sửa `.vibemaestro/sdlc.json`.

`install-gates` (hoặc `scripts/install_gates.py`) cài sáu cổng này thành workflow trong `.github/workflows/` và script trong `.vibemaestro/gates/`:

| Cổng | Đỏ khi |
|---|---|
| `commit-discipline` | PR có hơn `commits.max_per_pr` commit; một file bị hơn `commits.max_touches` commit chạm vào; một nhánh phụ được merge vào bằng merge commit; một subject bắt đầu bằng `wip`, `fixup!`, `squash!` hoặc `amend!`; hoặc một vòng review bị rải ra nhiều commit. Một dòng `COMMIT EXCEPTION: <lý do>` trong thân PR chỉ miễn hai điều đầu. Luật: `commit-unit`. |
| `pr-sensitive` | thân PR, một comment của PR hoặc một commit message chứa secret, IP công khai, account ID, e-mail, số điện thoại hoặc đường dẫn thư mục home cá nhân. Đầu ra chỉ hiện giá trị đã che. Luật: `pr-no-leaks`. |
| `pr-title` | tiêu đề vi phạm `pr.title.pattern` hoặc `pr.title.max_len`; một branch ngoài `branch.intent_prefix` vi phạm `branch.pattern`; hoặc, khi `pr.title.intent_form: reject`, một PR ready đã mang code mà vẫn giữ tiêu đề của file intent. Mọi kiểm tra đều tắt theo mặc định. |
| `pr-body` | thân PR vượt `pr.body.max_chars`, phần tóm tắt vượt `pr.body.summary_max_lines` dòng, hoặc phần bằng chứng vượt `pr.body.evidence_max_lines` dòng. Luật: `pr-body-shape`. |
| `pr-evidence` | không comment AI review nào ghim head hiện tại của PR (một comment vòng của owner, thành viên hoặc cộng tác viên mà dòng đầu là `tokens.round_comment_prefix`, SHA đầy đủ của head, chữ review và một số vòng); hoặc PR đổi một đường dẫn của `evidence.ui_paths` mà không comment nào ghim head có `E2E pass` hay `E2E không chạy: <lý do 15+ ký tự>` (cả `E2E not run:`). Bằng chứng ghim một head cũ chỉ được tính khi head chỉ thêm các lần merge sạch của base và không gì khác (không xung đột nào giải tay, cùng patch-id), và cổng nói nó mang bằng chứng từ đâu. Comment của owner, thành viên hoặc cộng tác viên trên một PR đã ready chạy lại check bằng chứng đỏ trên head. Luật: `pr-body-shape`. |
| `dead-branches` | có hơn `dead_branches.max_merged_on_remote` branch trên remote đã nằm trong dòng chính. Cổng chỉ báo cáo và in lệnh dọn; không bao giờ xóa. |

Khi nào chúng chạy:
- Không chạy trên draft: chuyển sang ready (`ready_for_review`) mới bắt đầu một vòng. Vì vậy test liên quan chạy ở máy, và review với ngữ cảnh mới diễn ra, trước khi bạn chuyển PR sang ready; CI là cổng lúc ready. Ở repo public, `pr-sensitive` vẫn quét draft, vì một draft public đã lộ rồi.
- Sửa PR chỉ chạy lại những cổng đọc phần vừa đổi: `pr-body` và `pr-sensitive` khi thân đổi, `pr-title` khi tiêu đề đổi, và `commit-discipline` khi thân cũ hoặc thân mới có token miễn trừ.
- Một commit mới hủy các lần chạy của head mà nó thay thế. Không sự kiện nào khác hủy một lần chạy, và không sự kiện nào thế chỗ một lần đang chờ.
- Một lần chạy bị bỏ qua không kiểm gì: merge guard giữ kết luận của lần chạy thật gần nhất trên head đó, và một check bắt buộc chưa có lần chạy thật nào là đỏ.

`install_gates.py` không bao giờ ghi đè file: file đã có được giữ nguyên, và `kept (differs)` đánh dấu file khác với thứ plugin sẽ ghi. Nó không ghi `.vibemaestro/sdlc.json`; nó in ra mỗi cổng đọc những key nào. Có `gh` thì nó kiểm tiếp, chỉ đọc, rằng biến repo tên `ci.runner_var` đã được đặt, và in một cảnh báo khi chưa.

Hai kiểm tra nữa chạy bên trong các script bạn vốn đã gọi, không phải workflow:

- `scripts/open-pr.sh` chạy giới hạn của `pr-body` và cổng sổ hiện trạng (`current_state.gate`) trước khi mở PR.
- `kb.py check current-state` kiểm khuôn của `kb/current-state.md`: không dấu hiệu lịch sử, và trần kích thước ở `current_state.limits`.

Cổng merge có bảo vệ (`gates/merge_guard.py`), bộ chạy ghi GitHub (`gates/gh_write.py`) và động cơ dựng máy (`gates/coordinator_bootstrap.py`) không được cài vào repo. Chúng là động cơ của các kit baton `kit:merge-pr`, `kit:gh-write` và `kit:coordinator-bootstrap`, do một phiên chạy qua BatonRun. Cổng merge chỉ merge một PR khi mọi điều kiện đều đúng (check xanh, head là SHA đã báo, không có đường dẫn bị cấm, không tụt sau base) và đọc luật của nó ở `merge.*`.

## Luật và cách hook giao luật

Luật là một file Markdown trong `rules/` có front matter nói khi nào áp dụng. Hook so file sắp sửa với `applyTo` (glob) và lệnh sắp chạy với `applyWhen` (biểu thức chính quy). Luật khớp được hiện cho phiên ngay trước lệnh gọi công cụ, mỗi luật một lần mỗi phiên. `workflow-core` không có trường nào trong hai trường đó và được giao nguyên văn khi mở phiên.

| File luật | Tới tay khi |
|---|---|
| `workflow-core.instructions.md` | mở phiên |
| `coordinated-work.instructions.md` | mở phiên, chỉ trong phiên có điều phối: phiên sandbox, hoặc phiên có một plugin đang bật cùng marketplace, phụ thuộc plugin này và mang file `sdlc-coordinated` ở gốc; ngoài ra chỉ là một dòng danh mục |
| `git-process.instructions.md` | `git worktree add`, `intent-branch.sh worker-branch`, `git rebase`, `git merge`, `git commit --amend`, `git push --force` |
| `commit-unit.instructions.md` | `git commit`, `git rebase`, `git reset --soft`, `gh pr ready` |
| `pr-body-shape.instructions.md` | `gh pr create`, `gh pr edit`, `gh pr comment`, `open-pr.sh` |
| `pr-no-leaks.instructions.md` | `gh pr create/edit/comment/review/merge/close/reopen`, `gh issue create/edit/comment/close/reopen`, `gh api` ghi vào comments, pulls hoặc issues, `open-pr.sh`, `git commit` |
| `before-ready.instructions.md` | `gh pr ready` |
| `measurement-commands.instructions.md` | `gh pr/issue/run/release/workflow/label/repo list`, `grep -c`, `git log A..B` |
| `document-precedence.instructions.md` | sửa file dưới `kb/`, `docs/` hoặc một thư mục luật đã cấu hình |
| `public-tree.instructions.md` | sửa một file ngoài `kb/` và `public.private`, ở repo có đặt `public.private` |
| `current-state-shape.instructions.md` | sửa `kb/current-state.md` |
| `version-policy.instructions.md` | sửa `**/.claude-plugin/plugin.json`, `**/.claude-plugin/marketplace.json` hoặc `.changes/**` |
| `docs-final.instructions.md` | sửa một file `README*`, `DEVELOPMENT*`, `CONTRIBUTING*`, `SECURITY*` hoặc `CODE_OF_CONDUCT*` ở gốc, bất kỳ `README.md` hoặc `README.*.md` nào, hoặc một file dưới `docs/` |
| `batonrun.instructions.md` | lệnh đặc quyền chạy thẳng, trong số đó có `gh pr merge`, `gh repo delete`, `gh release delete`, `gh secret set`, `gh api` ghi, `docker push` (cả `buildx --push`), `claude plugin install/uninstall/update/marketplace`, `git push --force` hoặc `--mirror`, `BATON_PHASE=` gõ tay |

Mỗi luật nói gì, một dòng:

- `git-process`: worktree riêng nằm trong repo; một intent là một branch là một PR draft; một task là một commit; không push lên main, không force push; commit đã được review thì bất biến.
- `commit-unit`: một commit là một task hoặc một vòng sửa, không phải một buổi gõ phím; gộp các vòng sửa trước khi ready.
- `pr-body-shape`: thân PR là trạng thái hiện hành, viết đè mỗi vòng, và ngắn; lịch sử các vòng đi vào comment.
- `pr-no-leaks`: không secret, IP công khai, account ID, e-mail hay đường dẫn cá nhân trong thân PR, comment hoặc commit message.
- `before-ready`: trước khi ready cần bằng chứng chạy trên bản cuối, hiện trạng đúng, một review bằng context mới, và không tự merge.
- `measurement-commands`: chạy một ca chắc chắn dương làm đối chứng trước khi trích một con số đếm.
- `document-precedence`: khi hai tài liệu mâu thuẫn, supersession tường minh thắng, rồi tới mức ràng buộc, rồi tới ngày.
- `public-tree`: ở repo công bố cây của mình, mọi file ngoài `kb/` và `public.private` là public: không gì riêng tư, không trỏ vào `kb/`, không số issue riêng, và test chạy được chỉ từ cây đó.
- `current-state-shape`: file chỉ ghi trạng thái hiện hành, viết đè, có trần kích thước.
- `coordinated-work`: chỉ khi một phiên điều phối giao việc cho một phiên thực thi mỗi pull request: các vai, brief là hợp đồng, bước hậu kiểm của phiên điều phối.
- `docs-final`: README và `docs/` là bản mô tả công khai cuối cùng của những gì đang có: không ngày tháng, lịch sử, quyết định, con trỏ vào `kb/` hay tên riêng tư; `kb/` giữ những thứ đó.
- `version-policy`: xem [Chính sách phiên bản](#chính-sách-phiên-bản).
- `batonrun`: xem [BatonRun](#batonrun).

Repo thêm luật riêng ở các thư mục liệt kê trong `rules.dirs` (`kb.py init` tạo `.vibemaestro/rules`). Luật của repo trùng tên thì thay luật của plugin. `rules.disable` tắt một luật theo tên; `workflow-core` không tắt được. Để chạy một lệnh mà luật `level: block` chặn, đặt tiền tố `RULES_GATE=off` ngay trong lệnh đó.

## Cấu hình

Config là một file tùy chọn ở gốc repo: `.vibemaestro/sdlc.json`. Không có file thì mọi giá trị mặc định bên dưới đều áp dụng. File được trộn lên các mặc định, nên chỉ cần liệt kê điều khác đi.

```json
{
  "schema": 1,
  "language": "en",
  "commits": { "max_per_pr": 10 },
  "agents": { "review_model": "fable" }
}
```

Quy tắc của định dạng:

- Một key lạ ở bất kỳ độ sâu nào là một cảnh báo, không phải một vấn đề: plugin bỏ qua nó, vì một plugin mới hơn có thể biết nó. Một key đã biết mang giá trị sai là một vấn đề. Key bắt đầu bằng `_` bị bỏ qua không cảnh báo, nên bạn có thể để một `_comment`.
- Tương thích (luật `config-compat`):
  - key mới là tùy chọn và có mặc định;
  - key đổi tên hay bị bỏ vẫn được đọc trong một khung ngừng dùng, và lời cảnh báo nêu key thay nó;
  - thay đổi phá vỡ thì nâng `schema`, và `python3 "$SDLC/scripts/kb.py" config migrate [--write]` đưa config lên.
  - Chỉ đặt một key mới trong một repo khi mọi plugin đọc nó (trên mọi máy và CI runner) đã ít nhất ở phiên bản sàn; trước đó mặc định được dùng.
- Vấn đề do bên gọi xử lý. Hook cảnh báo một lần mỗi phiên rồi chạy tiếp với mặc định. `kb.py` và các cổng thoát 65 và nêu tên key. Lõi branch và lõi PR thoát 64.
- Đọc một giá trị hiệu lực: `python3 "$SDLC/scripts/sdlc_config.py" get <key.chấm>`. Đọc mặc định của plugin cho một key, dù file nói gì: thêm `--default`.
- Kiểm file, và liệt kê cảnh báo (ví dụ một thư mục luật không tồn tại): `python3 "$SDLC/scripts/kb.py" config check`.
- `"language"` là `vi` hoặc `en`. Nó đặt tên các mục của spec, tiêu đề thân PR và các dòng luồng. Mặc định là `vi`; đặt `en` để dùng tiếng Anh. Key bạn đặt trong `tokens` thắng ngôn ngữ.

Subagent chạy trên model của đúng việc nó làm. Skill đọc `agents.<key>` và truyền làm `model` của công cụ Agent. Giá trị là một trong các alias `fable`, `opus`, `sonnet`, `haiku`.

Mọi key của schema 1, kèm mặc định của plugin. Chỗ nào mặc định phụ thuộc `language`, giá trị tiếng Anh nằm trong ngoặc.

| Key | Mặc định | Ý nghĩa |
|---|---|---|
| `schema` | `1` | Số schema của config, phiên bản lớn của định dạng. Plugin từ chối số lớn hơn của nó và nêu lệnh cập nhật cần chạy. |
| `hooks` | `"auto"` | `"off"` làm mọi hook của plugin im. |
| `language` | `"vi"` | `"vi"` hoặc `"en"`: ngôn ngữ của tên mục spec, tiêu đề thân PR và các dòng luồng. `kb.py init` ghi khoá này vào mọi config mới, `"en"` nếu không được trả lời, nên chỉ config tạo từ trước mới dùng mặc định. |
| `branch.intent_prefix` | `"intent/"` | Tiền tố của branch intent. |
| `branch.protected` | `["main", "master"]` | Các branch không bao giờ là head của PR và không bao giờ bị tính là chết. |
| `branch.pattern` | `null` | Regex mà branch head ngoài tiền tố intent phải khớp. Do `pr-title` dùng. |
| `pr.title.pattern` | `null` | Regex mà tiêu đề PR phải khớp (`open-pr.sh` và `pr-title`). |
| `pr.title.max_len` | `null` | Độ dài tối đa của tiêu đề PR. |
| `pr.title.intent_form` | `"allow"` | `"reject"` làm đỏ PR ready đã mang code mà vẫn giữ tiêu đề của file intent. |
| `pr.body.max_chars` | `3000` | Trần của thân PR tính bằng ký tự. `0` tắt giới hạn. |
| `pr.body.summary_max_lines` | `10` | Trần số dòng không rỗng của phần tóm tắt. `0` tắt. |
| `pr.body.evidence_max_lines` | `30` | Trần số dòng không rỗng của phần bằng chứng. `0` tắt. |
| `pr.draft` | `false` | `true` mở mọi PR ở trạng thái draft. |
| `pr.flow` | bốn dòng, dòng đầu đã tick | Bị bỏ qua: thân PR không có danh sách luồng; cổng `pr-evidence` kiểm bằng chứng. Config nào đặt nó sẽ nhận một cảnh báo. |
| `pr.tester_exempt` | `null` | Bị bỏ qua: miễn E2E là dòng `E2E không chạy: <lý do>` trong một comment ghim head (`pr-evidence`). Config nào đặt nó sẽ nhận một cảnh báo. |
| `pr.closing.keyword` | `"Closes"` | Từ khóa đóng của GitHub mà `open-pr.sh` viết trước số issue. Một trong `close`, `closes`, `closed`, `fix`, `fixes`, `fixed`, `resolve`, `resolves`, `resolved`. |
| `pr.closing.verify` | `true` | Sau khi mở PR, `open-pr.sh` đọc lại xem GitHub đã nối issue đóng chưa. |
| `pr.closing.tries` | `10` | Số lần đọc liên kết đó trước khi bỏ cuộc. |
| `pr.closing.wait_s` | `2` | Số giây giữa hai lần đọc. |
| `pr.closing.deadline_s` | `30` | Tổng số giây cho mọi lần đọc. |
| `commits.max_per_pr` | `15` | Số commit không-merge tối đa trong một PR (`commit-discipline`). |
| `commits.max_touches` | `4` | Số commit tối đa được chạm vào một file. |
| `commits.round_pattern` | `\bround\s*(\d+)\b` | Regex tìm số vòng review (nhóm 1) trong subject của commit. Subject được so khớp ở dạng chữ thường, bỏ dấu, `đ` thành `d`. |
| `current_state.path` | `"kb/current-state.md"` | File sổ hiện trạng. |
| `current_state.template` | `"ledger"` | `"ledger"` (chỉ trạng thái hiện hành, trần chặt) hoặc `"map"` (một bản đồ: không trần số dòng, 28000 byte, 400 ký tự mỗi dòng, không kiểm dấu hiệu lịch sử, một bảng năm cột bắt buộc). `map` cũng đặt `table`, nên không kết hợp được với `table_own_width: true`. |
| `current_state.limits.lines` | `120` | Số dòng tối đa; `null` là không giới hạn. |
| `current_state.limits.bytes` | `12000` | Số byte tối đa. |
| `current_state.limits.line_chars` | `200` | Số ký tự tối đa trên một dòng. |
| `current_state.limits.warn_ratio` | `0.85` | Từ tỉ lệ này của một trần, bộ kiểm in thêm dòng `WARNING` (mã thoát không đổi). |
| `current_state.forbid` | cả mười một dấu hiệu lịch sử | Id của các dấu hiệu lịch sử mà bộ kiểm từ chối (ngày, số PR, commit SHA, từ chỉ quá khứ, dấu cập nhật, tiêu đề lịch sử). |
| `current_state.forbid_patterns` | `[]` | Dấu hiệu bổ sung: các object gồm `id` và `regex`. |
| `current_state.table` | `null` | `{"columns": N, "required": bool}`: mọi bảng không thuộc một mục của `tables` phải có N cột; `required: true` còn đòi ít nhất một bảng. |
| `current_state.table_own_width` | `false` | `true` kiểm mỗi bảng không thuộc mục nào theo độ rộng dòng tiêu đề của chính nó. Nó là lựa chọn thay cho `table`: đặt `table: null` trước. |
| `current_state.tables` | `[]` | Kiểm tra từng bảng: tên cột, giá trị cho phép. |
| `current_state.no_empty_cells` | `false` | `true` từ chối ô bảng rỗng. |
| `current_state.exempt.min_reason_chars` | `0` | Độ dài tối thiểu của lý do sau dòng miễn `tokens.no_state_change`. |
| `current_state.watch` | `[]` | Tiền tố đường dẫn mà thay đổi phải đi kèm một lần sửa sổ, hoặc một dòng miễn. |
| `current_state.watch_exclude` | `[]` | Tiền tố nằm dưới một tiền tố được canh mà không bao giờ buộc phải sửa sổ. |
| `current_state.pages` | `null` | Glob của một thư mục phẳng chứa các trang sổ, ví dụ `kb/state/*.md`. |
| `current_state.page_limits.lines` | `null` | Số dòng tối đa của một trang; `null` là không giới hạn. |
| `current_state.page_limits.bytes` | `8000` | Số byte tối đa của một trang. |
| `current_state.page_limits.line_chars` | `400` | Số ký tự tối đa trên một dòng của trang. |
| `current_state.page_limits.warn_ratio` | `0.85` | Tỉ lệ cảnh báo của trần trang. |
| `current_state.inject` | `false` | `true`: hook SessionStart bơm mục lục hiện trạng vào lúc mở phiên và sau mỗi lần compaction. |
| `current_state.gate` | `"builtin"` | Cổng diff đứng sau `open-pr.sh`: `"builtin"`, `"off"`, hoặc `"external:<đường dẫn>"` (một script của repo). Script ngoài bị thiếu thì chặn. |
| `current_state.labels` | `null` | `{"regex": <có nhóm tên date>, "max_age_days": N}`: nhãn không có ngày, hoặc cũ hơn, sẽ bị cảnh báo. |
| `rules.dirs` | `[]` | Các thư mục luật của repo, tính từ gốc repo (`kb.py init` ghi `[".vibemaestro/rules"]`). |
| `rules.disable` | `[]` | Tên các luật cần tắt, có hoặc không có `.instructions.md`. |
| `public.private` | `null` | Các glob giữ riêng khi repo công bố cây của mình: repo công bố mọi file ngoài `kb/` và các glob này. `null` nghĩa là không công bố; `[]` là câu trả lời hợp lệ. Viết một thư mục là `dir/**`. Bật luật `public-tree`. |
| `evidence.ui_paths` | `null` | Các glob của đường dẫn UI trong repo, cho cổng `pr-evidence`: PR đổi một đường dẫn như vậy cần bằng chứng E2E ghim head. `null` nghĩa là không có UI, không đòi E2E. Chỉ đặt khi mọi plugin đọc config đã biết key này (luật `config-compat`). |
| `sensitive.allowlist` | `".pr-sensitive-allow"` | File các hash sha256 của giá trị mà cổng `pr-sensitive` được cho qua, mỗi dòng một hash kèm `# lý do`. Trong CI đọc từ nhánh base. |
| `sensitive.scan` | `["pr_body", "pr_comments", "commit_messages"]` | Những gì `pr-sensitive` quét. |
| `dead_branches.max_merged_on_remote` | `0` | Số branch remote đã merge mà còn sống tối đa trước khi `dead-branches` đỏ. |
| `ci.runner_var` | `"CI_RUNNER"` | Tên biến repo chọn nhãn runner của các workflow đã cài. Các job cổng đã cài đọc trước biến tùy chọn `CI_GATE_RUNNER` (runner nhẹ cho các cổng) và lùi về biến này. |
| `ci.runner_default` | `"ubuntu-latest"` | Nhãn runner khi biến đó chưa đặt. |
| `ci.backend` | `"github-actions"` | Backend CI mà cổng merge có bảo vệ đọc check từ đó: `github-actions` (giá trị dựng sẵn duy nhất) hoặc `external:<đường dẫn>`. Các workflow đã cài là GitHub Actions trong cả hai trường hợp. |
| `merge.deny_globs` | `null` | Các đường dẫn mà cổng merge có bảo vệ từ chối ở làn thường. `null` nghĩa là chưa đặt, và cổng từ chối chạy; `[]` là một câu trả lời hợp lệ. `kb.py init` ghi ba glob. |
| `merge.admin_bypass` | `false` | `true` cho phép `--admin` ở cổng merge có bảo vệ. Nó không đổi điều kiện nào. |
| `merge.required_checks` | `[]` | Tên các check phải xanh. Rỗng thì đòi ít nhất một check run xanh. |
| `merge.planner` | `null` | `{"script", "inputs"}`: bộ lập kế hoạch test của repo, mà merge có bảo vệ chạy với `--behind auto` để xét một pull request tụt sau base. |
| `merge.log` | `null` | Tên file của log merge trong thư mục state của người dùng; `null` nghĩa là `merge-log.jsonl`. |
| `merge.image_bump.enabled` | `false` | Bật làn image-bump của cổng merge có bảo vệ. |
| `merge.image_bump.tag_files` | `[]` | Các file mà làn này được đổi dòng, chỉ để dời tag của image đã cấu hình. |
| `merge.image_bump.tree` | `null` | Một tiền tố thư mục mà làn này cũng chấp nhận thay đổi bên dưới. |
| `merge.image_bump.revision` | `null` | `{"file", "pattern"}`: nơi làn này đọc revision mà nó kiểm. |
| `merge.image_bump.registry` | `null` | `{"backend": "ghcr", "host", "image"}`: registry nơi làn này kiểm tag mới đã tồn tại. |
| `rebase.identity` | `null` | `{"name", "email"}` dùng làm committer khi `intent-branch.sh integrate` phải rebase. Nó thắng biến môi trường. |
| `upstream_issues` | `true` | Được chấp nhận và kiểm hợp lệ; không có gì trong plugin này đọc nó. |
| `agents.review_model` | `"opus"` | Model của review bằng context mới trước khi ready (`ship`, `before-ready`). |
| `agents.search_model` | `"haiku"` | Model của một lần tìm chỉ đọc (`brainstorm`). |
| `agents.worker_model` | `"sonnet"` | Model của worker dựng một task (`plan`, `batonrun`, `workflow-core`). |
| `kb.spec_warn_bytes` | `40000` | `kb.py check` liệt kê spec lớn hơn mức này. `null` tắt. |
| `tokens.summary_heading` | `"Tóm tắt"` (`"Summary"`) | Tiêu đề phần tóm tắt của thân PR. |
| `tokens.criteria_heading` | `"Tiêu chí chấp nhận"` (`"Acceptance criteria"`) | Tiêu đề danh sách tiêu chí. |
| `tokens.evidence_heading` | `"Bằng chứng chạy"` (`"Run evidence"`) | Tiêu đề phần bằng chứng. |
| `tokens.flow_heading` | `"Luồng"` (`"Flow"`) | Một tiêu đề mà `pr-body` đọc làm ranh giới mục khi thân PR có nó; thân do `open-pr.sh` viết không có. |
| `tokens.fixes_line` | `"Vá cho"` (`"Patch for"`) | Tiền tố dòng cho một issue mà PR vá nhưng không đóng. |
| `tokens.not_run` | `"KHÔNG CHẠY:"` (`"NOT RUN:"`) | Dấu mở đầu phần bằng chứng không chạy được. |
| `tokens.no_state_change` | `["NO STATE CHANGE:"]` | Các dấu của dòng miễn cho PR không đổi hiện trạng. |
| `tokens.commit_exception` | `"COMMIT EXCEPTION:"` | Dấu của dòng miễn ngưỡng số commit hoặc số lần chạm file. |
| `tokens.round_comment_prefix` | `"SHA:"` | Tiền tố của comment PR ghi một vòng review. |
| `tokens.evidence_cut` | `"… (cắt {n} dòng giữa) …"` (`"… ({n} lines cut from the middle) …"`) | Dấu thay đoạn giữa của một bằng chứng dài; `{n}` là số dòng bị cắt. |
| `tokens.not_run_note` | văn bản tiếng Việt (văn bản tiếng Anh) | Cảnh báo đặt trên phần bằng chứng bắt đầu bằng `tokens.not_run`. |
| `tokens.criteria_note` | văn bản tiếng Việt (văn bản tiếng Anh) | Ghi chú dưới danh sách tiêu chí; `{evidence}` là tiêu đề phần bằng chứng. |
| `tokens.spec.context` | `"Bối cảnh"` (`"Context"`) | Tiêu đề mục spec thứ nhất. |
| `tokens.spec.goal` | `"Mục tiêu"` (`"Goal"`) | Tiêu đề mục spec thứ hai. |
| `tokens.spec.out_of_scope` | `"Ngoài phạm vi"` (`"Out of scope"`) | Tiêu đề mục spec thứ ba. |
| `tokens.spec.criteria` | `"Tiêu chí chấp nhận"` (`"Acceptance criteria"`) | Tiêu đề mục spec thứ tư. |
| `tokens.spec.design` | `"Thiết kế"` (`"Design"`) | Tiêu đề mục thiết kế tùy chọn. |
| `tokens.spec.evidence` | `"Bằng chứng chạy"` (`"Run evidence"`) | Tiêu đề mà tiêu chí cuối của spec phải nêu tên. |
| `tokens.spec.placeholder` | `"<ĐIỀN"` (`"<FILL"`) | Dấu của chỗ trống còn lại trong khung; `kb.py check spec` từ chối spec còn dấu này. |

## Chính sách phiên bản

Mục này áp dụng cho repo xuất bản plugin, như chính kit. Repo ứng dụng không cần nó.

- **Một pull request thường không sửa version.** Pull request đổi `plugins/<tên>/` thêm một file thay đổi `.changes/<slug>.md` thay vào đó:

  ```
  ---
  plugins: vibemaestro-sdlc
  level: patch
  ---
  Một dòng mà người dùng plugin đã cài hiểu được: điều gì đổi với họ.
  ```

  `level` là `patch` cho một bản vá, `minor` cho một tính năng, `major` cho thay đổi phá vỡ (với plugin này, một hàng của `CONTRACT.md` bị xóa hoặc đổi tên). Plugin 0.x được phép phá vỡ trong một bản minor.
- **PR release** (skill `release`, do hàng release của plan khởi động) biến mọi file thay đổi đang chờ thành một bước version cho mỗi plugin, ghi các mục `CHANGELOG.md`, và đặt `Frozen at` trong `CONTRACT.md` khi bề mặt của nó đã đổi.
- **PR hotfix** rẽ từ nhánh `release`, nên tính năng chưa phát hành không bao giờ đi theo. Nó nâng một bản patch. Một PR back-merge từ `backmerge/<sha12>` đưa nó về main và merge bằng merge commit, không bao giờ squash.
- **Sau khi một trong hai merge**, một baton script do bạn ký dời nhánh `release` tới commit release, hoặc, sau một hotfix, đẩy `backmerge/<sha12>` và mở pull request của nó; repo công bố bản phát hành theo cách riêng của mình. Bản phát hành công khai của chính kit ghi version đã phát hành của từng plugin vào `plugin.json` của nó và gắn tag `<plugin>--v<version>`.
- Main luôn sẵn sàng phát hành sau mỗi lần merge, vì một release ship mọi file thay đổi đang chờ.

Các lệnh, chỉ đọc trừ khi có ghi chú:

```bash
python3 "$SDLC/scripts/release.py" check          # thay đổi này có là thay đổi thường, release, hotfix hay back-merge hợp lệ không?
python3 "$SDLC/scripts/release.py" plan           # một lần cắt sẽ làm gì ở đây
python3 "$SDLC/scripts/release.py" cut            # ghi cây làm việc thành một release
python3 "$SDLC/scripts/release.py" cut --hotfix   # tương tự cho một hotfix
```

`release.py check` chạy trong CI. Nó thoát 0 khi thay đổi khớp loại của nó, 1 khi đỏ, 3 khi phép kiểm không chạy được ở máy cục bộ (trong CI trường hợp đó là đỏ), 64 khi dùng sai.

## BatonRun

Một lần ghi ra ngoài phiên (ghi GitHub như merge, đẩy registry, đổi cấu hình plugin của người dùng, force push, xóa) là một **run**: một baton script duy nhất được kiểm, diễn tập theo kế hoạch nó khai, ký, chạy, kiểm sau, hoàn tác khi hỏng, và ghi log. Phiên tự chạy nó bằng `baton.py go <script>`; chủ không bao giờ bị giao dòng lệnh để gõ. Một số run cần chữ ký của chủ. Chế độ (`manual` hoặc `auto`) quyết định run nào, và chỉ chủ mới đổi chế độ. Viết tay một baton chỉ cần skill `batonrun`; chuẩn và danh mục run nằm ở [docs/batonrun.vi.md](docs/batonrun.vi.md).

## Xử lý sự cố

Chạy các lệnh này trong repo đang có vấn đề. `$SDLC` là thư mục plugin (xem [Bắt đầu nhanh](#bắt-đầu-nhanh)). Một số thông báo của script bằng tiếng Việt.

| Triệu chứng | Lệnh | Nó cho bạn biết |
|---|---|---|
| Plugin không nạp, hoặc bạn muốn biết version | `claude plugin list` | Trạng thái và dòng `Version:` của mọi plugin đã cài. `claude plugin install` thoát 0 ngay cả khi thiếu một phụ thuộc, nên hãy đọc lệnh này. |
| Manifest có vẻ hỏng | `claude plugin validate "$SDLC"` | `Validation passed`, hoặc điều gì sai. |
| Không thấy lời nhắc nào | `python3 "$SDLC/scripts/sdlc_config.py" get hooks` | `off` nghĩa là repo đã làm hook im. |
| Cảnh báo về config lúc mở phiên, hoặc một script thoát 65 | `python3 "$SDLC/scripts/kb.py" config check` | Key không hợp lệ và lý do, kèm các cảnh báo, chẳng hạn một key plugin này không biết (plugin mới hơn có thể biết: `claude plugin update vibemaestro-sdlc@vibemaestro`). |
| Một tài liệu trong `kb/` bị từ chối | `python3 "$SDLC/scripts/kb.py" check` | Lỗi vòng đời trong front matter và các spec vượt `kb.spec_warn_bytes`. |
| Một spec bị từ chối | `python3 "$SDLC/scripts/kb.py" check spec <ngày>-<slug>` | Mục thiếu, rỗng hay sai chỗ; chỗ trống còn lại; tiêu chí không có lệnh. Mã thoát 65. |
| `kb/current-state.md` bị từ chối | `python3 "$SDLC/scripts/kb.py" check current-state` | Từng dòng vi phạm, hoặc kích thước vượt trần. Mã thoát 65. |
| Liên kết giữa intent, spec và plan bị hỏng | `python3 "$SDLC/scripts/kb.py" check links --base origin/main` | Các liên kết hỏng trong những file thay đổi của bạn. |
| `intent-branch.sh` thoát 3, 6 hoặc 7 | đọc thông báo | 3: `kb/intent/<slug>.md` chưa tồn tại. 6: branch đã có. 7: chạy sai chỗ, ví dụ `worker-branch` hoặc `integrate` trong cây chính thay vì một worktree liên kết. |
| `open-pr.sh` thoát 3, 4 hoặc 5 | đọc thông báo | 3: thiếu bằng chứng. 4: cổng sổ hiện trạng từ chối. 5: không đứng trong worktree liên kết. 2: thân PR vượt giới hạn `pr.body.*`. |
| Kiểm version đỏ | `python3 "$SDLC/scripts/release.py" check` | Luật nào của loại thay đổi đó bị vi phạm. |
| BatonRun báo thiếu một quyền | `python3 "$SDLC/scripts/baton.py" permissions --check` | Mã thoát 7 và một dòng `fix:` kèm các lệnh cần chạy. `--print` hiện khối quyền, `--install-launcher` cài launcher. |
| Một cổng đỏ trong CI | chạy chính script đó, ví dụ `python3 .vibemaestro/gates/commit_discipline.py origin/main HEAD` | Phép đo nào hỏng. Mã thoát 2 nghĩa là không kết luận được. |
| Một lệnh bị luật `level: block` chặn | đặt `RULES_GATE=off` ngay trong lệnh | Bỏ qua khối chặn cho đúng lệnh đó. |

## Tài liệu liên quan

- [CONTRACT.md](CONTRACT.md): giao diện đóng băng cho consumer tự động, kèm mọi mã thoát.
- [CHANGELOG.md](CHANGELOG.md): mỗi bản phát hành đổi gì.
- [docs/batonrun.vi.md](docs/batonrun.vi.md): chuẩn BatonRun.
- [docs/ai-native-sdlc.vi.md](../../docs/ai-native-sdlc.vi.md): vòng đời phát triển phần mềm AI-native mà plugin này hiện thực.
- [docs/README.vi.md](../../docs/README.vi.md): mục lục tài liệu của toàn bộ kit.
- [README.vi.md của kit](../../README.vi.md) và [vibemaestro-brain](../vibemaestro-brain/README.vi.md): kit và các plugin còn lại của nó, phụ thuộc vào plugin này.
