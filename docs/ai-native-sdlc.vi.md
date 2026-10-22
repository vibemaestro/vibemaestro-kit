[English](ai-native-sdlc.md) | Tiếng Việt

# Phát triển phần mềm AI-native: hướng dẫn của Anthropic và bộ kit này

Trang này đặt cạnh nhau hai thứ: điều Anthropic công bố về cách làm phần mềm với Claude Code và agent, và điều bộ kit này
làm. Với mỗi giai đoạn của vòng đời phát triển phần mềm (SDLC) có ba phần: Anthropic khuyến nghị gì, kèm link tới trang nói
điều đó; file nào của kit hiện thực nó; và kit khác ở đâu, đi xa hơn ở đâu, hay còn thiếu gì.

Anthropic có công bố một khung làm việc mang đúng tên này. Bài "The AI-native SDLC playbook" [S1] mô tả sáu giai đoạn (Plan,
Design, Build, Test, Deploy, Maintain), và nói cùng ý tưởng đó còn được gọi là “the agentic SDLC, the AI SDLC, or simply agentic
software development” [S1]. Một bài đi kèm kể Anthropic bảo vệ SDLC AI-native của chính họ ra sao [S2]. Phần còn lại của hướng
dẫn nằm rải rác trong tài liệu Claude Code và blog kỹ thuật của Anthropic [S3]–[S31].

## Cách đọc trang này

**Giai đoạn.** Trang này dùng bảy giai đoạn: Plan, Specify, Build, Review, Test, Release và Operate. Cách ứng với sáu giai đoạn
của playbook: Specify là Design của playbook; Review và Release tách đôi Deploy của playbook (vòng review PR, và các cổng phê
duyệt cùng CI/CD); Operate là Maintain của playbook.

**Trích dẫn.** `[S1]` trỏ tới dòng S1 trong bảng [Nguồn](#nguồn). Chữ trong ngoặc kép cong là nguyên văn tiếng Anh của nguồn,
ngắn hơn 25 từ. Mọi chỗ khác là diễn giải.

**Từ chỉ trạng thái.**

| Từ | Nghĩa |
|---|---|
| đã có (shipped) | Có trong một plugin của kit |
| khoảng trống (gap) | Chưa làm; ghi ra để bạn khỏi tưởng là đã có |

**Đường dẫn.** Link trỏ tới file có trong các plugin hoặc trong `docs/`. Một đường dẫn trong backtick không có link (ví dụ
`tests/run-all.sh`) là file của repo kit nằm ngoài các plugin; nó không được cài cùng plugin.

Kit có hai plugin, cho một người với một seat Claude trên một máy:
[`vibemaestro-sdlc`](../plugins/vibemaestro-sdlc/) (quy trình làm việc) và
[`vibemaestro-brain`](../plugins/vibemaestro-brain/) (bộ nhớ cho phiên chạy dài).

## Tóm tắt nhanh

| Giai đoạn | Anthropic khuyến nghị | Kit | Trạng thái |
|---|---|---|---|
| Plan | Ghi ý định bằng lời người yêu cầu thành một file được commit; một người chấp nhận nó [S1] | skill `intake` ghi `kb/intent/<date>-<slug>.md` trước khi có nhánh; skill `brainstorm` | đã có |
| Specify | Một spec viết từ ý định, được người duyệt trước khi viết code [S1], [S3] | skill `spec`: bốn mục, tiêu chí là lệnh; hỏi duyệt trước khi code | đã có (duyệt là kỷ luật, không phải cổng) |
| Build | CLAUDE.md ngắn, skill cho chính sách, hook cho điều bắt buộc, worktree và subagent [S1], [S5] | Luật do hook đưa tới đúng lúc thao tác; mỗi intent một worktree; model riêng cho từng việc của subagent | đã có |
| Review | Review với ngữ cảnh mới; agent viết code không được tự duyệt [S1], [S3] | luật `before-ready`; model review lấy từ config; tác giả không bao giờ tự merge PR của mình; người merge, hoặc phiên chính của `local-parallel` merge qua merge có canh gác | đã có (review là kỷ luật, không phải cổng) |
| Test | Cho agent một phép kiểm chạy được; đưa bằng chứng; eval cho cấu hình của agent [S1], [S3] | Tiêu chí spec là lệnh; `open-pr.sh` từ chối PR không có bằng chứng chạy | đã có; eval là khoảng trống |
| Release | Hook làm cổng phê duyệt; agent làm tới cổng production thì dừng [S1] | BatonRun cho mọi thao tác ghi đặc quyền; change file và script release | đã có |
| Operate | Phát hiện bằng logic tất định; phát hiện quay lại thành intent mới; định danh agent quyền tối thiểu [S1], [S2] | Ghi vào hệ thống đang chạy đi qua BatonRun | khoảng trống: không có vòng giám sát, không có định danh agent |
| Mọi giai đoạn | Quản lý ngữ cảnh; giữ trạng thái trong file; sandbox và quyền [S3], [S18], [S16] | `kb/` làm bộ nhớ của repo; plugin brain; luật quyền cho baton | đã có |

## Plan

### Anthropic khuyến nghị gì

- Ghi ý tưởng một lần, thành file. Giai đoạn Plan của playbook: “Intent is captured once, in the originator's own words, as a
  version-controlled artifact the next stage can act on.” [S1]
- Để file đó cạnh code. Với một sản phẩm đơn lẻ, playbook gợi ý thư mục `intent/` trong repo sản phẩm, và nói product owner
  xem và chấp nhận intent trước khi nó đi tiếp [S1].
- Brainstorm với Claude tới khi ý tưởng cụ thể: phạm vi, người dùng, ràng buộc, thế nào là thành công [S1].
- Người quyết định làm gì; Claude quyết định làm thế nào. Trong phân tích khoảng 400.000 phiên Claude Code, “people make most of
  the planning decisions (what to do) and Claude makes most of the execution decisions (how to do it).” [S28]
- Chỉ lập kế hoạch khi có ích: “If you could describe the diff in one sentence, skip the plan.” [S3] Chính đội Claude Code đã
  chuyển phần lớn việc lập kế hoạch vào pull request và bản mẫu, họ gọi là lập kế hoạch đúng lúc (just-in-time) [S26].

### Kit làm gì

- Skill [`intake`](../plugins/vibemaestro-sdlc/skills/intake/SKILL.md) ghi yêu cầu **nguyên văn** vào
  `kb/intent/<date>-<slug>.md`, rồi tạo nhánh `intent/<date>-<slug>` và một issue theo dõi qua
  [`intent-branch.sh`](../plugins/vibemaestro-sdlc/scripts/intent-branch.sh). Lõi từ chối tạo nhánh khi chưa có file intent
  (mã thoát 3, [`intent_branch.py`](../plugins/vibemaestro-sdlc/scripts/intent_branch.py)).
- Skill [`brainstorm`](../plugins/vibemaestro-sdlc/skills/brainstorm/SKILL.md) làm rõ một yêu cầu còn mơ hồ và ghi kết quả vào
  file intent, dưới một tiêu đề riêng.
- Skill [`plan`](../plugins/vibemaestro-sdlc/skills/plan/SKILL.md) dành cho chủ đề cần từ hai pull request trở lên: một file
  kế hoạch, mỗi pull request một dòng, quyết định của owner được trích nguyên văn. `kb.py plan status` đọc trạng thái thật của
  từng dòng ([`kb.py`](../plugins/vibemaestro-sdlc/scripts/kb.py)).
- Luật [`git-process`](../plugins/vibemaestro-sdlc/rules/git-process.instructions.md): một intent, một nhánh, một pull request
  nháp.

### Kit khác ở đâu

- **Khác:** playbook để Claude viết intent rồi người khởi xướng sửa [S1]. Kit giữ nguyên lời người yêu cầu, và đặt phần Claude
  làm rõ vào một mục riêng. Lý do: người đọc sau phân biệt được điều được hỏi với điều được diễn giải.
- **Xa hơn:** thứ tự "intent trước, nhánh sau" do script ép, không chỉ được mô tả.
- **Khác:** `plan.md` của playbook là kế hoạch hiện thực cho một thay đổi [S1]. Trong kit, nội dung đó nằm trong spec (giai đoạn
  sau); một plan của kit là tầng nhiều PR phía trên.
- **Khoảng trống:** không có máy nào ghi nhận rằng một người đã *chấp nhận* intent. Sự chấp nhận chỉ hiện ra qua câu trả lời
  của người đó trong phiên.

## Specify

### Anthropic khuyến nghị gì

- Biến intent đã chấp nhận thành spec yêu cầu và thiết kế, theo các skill của tổ chức, có đánh dấu điểm đáng lo; một người
  xem lại và nó được commit cạnh intent [S1].
- Để Claude phỏng vấn bạn, rồi viết spec, rồi mở một phiên mới để thực hiện [S3]. “The most useful specs are self-contained”
  [S3]: spec nêu file và giao diện liên quan, và điều nằm ngoài phạm vi.
- Thống nhất thế nào là "xong" trước khi viết code; bài của Anthropic về harness chạy dài gọi đó là sprint contract [S22].
- Để bên lập kế hoạch ở mức bối cảnh sản phẩm và thiết kế tổng thể, vì một lỗi trong spec quá chi tiết sẽ lan xuống phần
  build [S22].
- Với việc dài, liệt kê các tính năng vào một file, lúc đầu đều đánh dấu chưa đạt, và cấm agent xoá hay sửa test [S21].

### Kit làm gì

- Skill [`spec`](../plugins/vibemaestro-sdlc/skills/spec/SKILL.md) viết `kb/specs/<date>-<slug>.md` theo bốn mục (bối cảnh,
  mục tiêu, ngoài phạm vi, tiêu chí chấp nhận). Mỗi tiêu chí là **một lệnh và kết quả mong đợi**. Tiêu chí cuối luôn đòi pull
  request có mục bằng chứng chạy.
- `kb.py check spec` kiểm hình dạng: đủ mục, đúng thứ tự, không còn chỗ trống, tiêu chí nào cũng có lệnh
  ([`kb.py`](../plugins/vibemaestro-sdlc/scripts/kb.py)).
- Skill hỏi người duyệt spec trước khi sửa bất kỳ dòng code nào. Một subagent của `local-parallel` thay vào đó kết thúc lượt
  bằng đường dẫn spec, và phiên chính chuyển spec cho người duyệt.

### Kit khác ở đâu

- **Xa hơn:** tiêu chí là lệnh nên sprint contract [S22] chạy được. Chính các lệnh đó thành bằng chứng ở giai đoạn Test.
- **Khoảng trống:** duyệt spec là kỷ luật, không phải cổng. Phép kiểm hình dạng không biết người đã duyệt hay chưa. Playbook
  lưu ý plan mode tự ép cổng của nó: “Plan mode enforces this itself, since Claude cannot edit files until the engineer accepts
  the plan.” [S1] Kit không có hook nào chặn sửa file trước khi được duyệt.
- **Khoảng trống:** kit không có skill mã hoá chính sách thương hiệu, bảo mật hay UX của một tổ chức cho bước viết spec như
  playbook mô tả [S1]. Một repo có thể thêm luật riêng (xem Build).

## Build

### Anthropic khuyến nghị gì

- Giữ CLAUDE.md ngắn và trong git: “Keep CLAUDE.md under 200 lines.” [S5] Commit nó để cả nhóm cùng đóng góp [S3].
- Biến một lần sửa lặp lại thành thay đổi trong file: “A repeated mistake or a recurring review comment is a CLAUDE.md edit,
  not a one-off correction in chat.” [S5]
- Dùng skill cho kiến thức phải áp dụng nhất quán, dùng hook cho điều phải luôn đúng: “A skill is an advisory control while a
  hook is the deterministic layer behind it.” [S1] “Put guardrails in hooks.” [S5]
- CLAUDE.md và file bộ nhớ là ngữ cảnh, không phải cưỡng chế: “Claude treats them as context, not enforced configuration.” [S10]
- Chạy nhiều phiên song song, mỗi phiên một git worktree [S1], [S4]: “Two or three sessions is a sensible starting point.” [S1]
  Việc lập trình khó chia song song hơn việc nghiên cứu [S19].
- Dùng subagent cho việc có phạm vi: “Each subagent runs in its own context window with a custom system prompt, specific tool
  access, and independent permissions.” [S6]
- Đóng gói skill, hook, subagent và MCP server thành plugin, được Claude Code cài và nạp như một khối [S9]; skill theo chuẩn mở
  Agent Skills [S8], [S20].
- Chỉ cài skill từ nguồn tin cậy, và kiểm tra kỹ trước khi dùng [S20].

### Kit làm gì

- Kit là hai plugin Claude Code trong một marketplace (`.claude-plugin/marketplace.json`). Mỗi plugin chỉ là skill, hook, luật
  và script thông thường.
- **Luật đúng lúc thao tác.** Hook của plugin sdlc ([`hooks.json`](../plugins/vibemaestro-sdlc/hooks/hooks.json)) đọc file
  Claude sắp sửa hoặc lệnh nó sắp chạy, rồi chỉ đưa luật khớp: glob `applyTo` cho việc sửa file
  ([`pre-edit.py`](../plugins/vibemaestro-sdlc/scripts/pre-edit.py)), mẫu `applyWhen` cho lệnh
  ([`pre-bash.py`](../plugins/vibemaestro-sdlc/scripts/pre-bash.py)). Luật ở `level: block` chặn lệnh
  ([`rules.py`](../plugins/vibemaestro-sdlc/scripts/rules.py)). Lúc mở phiên chỉ đưa cách làm việc và danh mục luật
  ([`session-start.py`](../plugins/vibemaestro-sdlc/scripts/session-start.py)).
- **Luật có sẵn.** Các luật trong [`plugins/vibemaestro-sdlc/rules/`](../plugins/vibemaestro-sdlc/rules/) (đơn vị commit,
  quy trình git, thân PR, chống lộ, đo đạc, chính sách version và các luật khác). Một repo thêm thư mục luật riêng trong
  `.vibemaestro/sdlc.json` ([`sdlc_config.py`](../plugins/vibemaestro-sdlc/scripts/sdlc_config.py)).
- **Worktree.** Luật [`git-process`](../plugins/vibemaestro-sdlc/rules/git-process.instructions.md) đòi một worktree riêng bên
  trong repo; `open-pr.sh` từ chối mở pull request từ cây chính (mã thoát 5,
  [`open_pr.py`](../plugins/vibemaestro-sdlc/scripts/open_pr.py)).
- **Subagent chạy đúng model.** Ba khoá config cho mỗi việc của subagent một model: `agents.review_model` (mặc định `opus`),
  `agents.search_model` (`haiku`) và `agents.worker_model` (`sonnet`).
- **Nhiều việc cùng lúc.** Skill [`local-parallel`](../plugins/vibemaestro-sdlc/skills/local-parallel/SKILL.md): phiên chính
  chia việc và mở một subagent cho mỗi việc trên `agents.worker_model`, mỗi subagent trong worktree riêng từ intake tới một pull
  request nháp. Phiên chính giữ hàng đợi, chuyển từng spec cho người duyệt, kiểm lại từng pull request và merge nó.

### Kit khác ở đâu

- **Xa hơn:** thay vì một CLAUDE.md ngày càng dài, kit chỉ nạp một luật khi file hay lệnh của nó khớp. Ngữ cảnh lúc mở phiên
  vì thế nhỏ, điều quan trọng vì “Claude's context window fills up fast, and performance degrades as it fills.” [S3]
- **Khác:** phần lớn hook của kit chỉ nhắc; chỉ luật `level: block` mới chặn. Hook "fail open": lỗi thì thoát 0 và để lệnh chạy,
  nên plugin hỏng không bao giờ chặn công việc. Nó đổi "guardrails in hooks" của [S5] lấy công việc không bao giờ bị một plugin hỏng chặn lại.
- **Xa hơn:** phiên chính coi báo cáo của subagent là một lời khẳng định, và chạy lại lệnh chấp nhận trước khi tin
  ([`workflow-core`](../plugins/vibemaestro-sdlc/rules/workflow-core.instructions.md)). Giới hạn của playbook, chỉ thêm phiên khi
  review còn theo kịp [S1], thành một quy trình viết ra.

## Review

### Anthropic khuyến nghị gì

- Review với ngữ cảnh mới: “A fresh context improves code review since Claude won't be biased toward code it just wrote.” [S3]
- Giữ tách bạch trách nhiệm: “Separation of duties is preserved, because the agent that wrote the code has no way to approve
  it.” [S1] Người duyệt qua branch protection [S1].
- Chạy cùng một bộ lượt review cho mọi pull request, phát hiện xếp theo mức nghiêm trọng [S1]; dịch vụ Code Review của
  Anthropic xếp lỗi theo mức nghiêm trọng và “It won't approve PRs” [S24].
- Đặt sự chú ý của người vào chỗ cần. Anthropic dành review của người cho code chịu quy định hoặc quan trọng, phần còn lại lấy
  mẫu theo rủi ro [S2]; đội Claude Code gọi đó là “human review where it matters” [S26].
- Chạy review bảo mật trước khi mở pull request [S2]; `/security-review` và `/code-review` có sẵn cho việc này [S31].
- Trong GitHub Actions, chỉ cấp cho workflow quyền nó cần, và để một người xem thay đổi của Claude trước khi merge [S12].

### Kit làm gì

- Luật [`before-ready`](../plugins/vibemaestro-sdlc/rules/before-ready.instructions.md) được đưa tới khi phiên chạy
  `gh pr ready`. Nó đòi một vòng review ngữ cảnh mới trên diff cuối (agent khác hoặc người; tác giả tự đọc lại không tính),
  chạy trên `agents.review_model`, được dùng tầng mạnh nhất cho thay đổi rủi ro cao. Nó cũng nói phiên không tự merge pull
  request của mình.
- Luật [`pr-body-shape`](../plugins/vibemaestro-sdlc/rules/pr-body-shape.instructions.md) giữ thân PR là trạng thái hiện tại;
  lịch sử từng vòng nằm trong comment.
- Một việc: người merge pull request. Nhiều việc với `local-parallel`: phiên chính merge pull request của một subagent qua
  kit run `kit:merge-pr` ([`merge-pr.sh`](../plugins/vibemaestro-sdlc/batons/merge-pr.sh),
  [`merge_guard.py`](../plugins/vibemaestro-sdlc/gates/merge_guard.py)): chạy thử trước, rồi một lần merge ghim vào head đã
  review, bị từ chối khi một điều kiện canh gác hỏng (head đổi, check đỏ, xung đột, file ngoài phạm vi brief).

### Kit khác ở đâu

- **Xa hơn:** merge ghim vào đúng head đã review, nên một lần push sau review không lọt vào được.
- **Khoảng trống:** review ngữ cảnh mới là kỷ luật, không phải cổng: không gì chặn `gh pr ready` khi chưa review.
- **Khoảng trống:** không có file chính sách review dùng chung với các lượt cố định và xếp hạng mức nghiêm trọng, như REVIEW.md
  của playbook [S1].
- **Khoảng trống:** không bước nào chạy `/security-review` trước khi mở pull request. Gate thông tin nhạy cảm (Release) chỉ bắt
  bí mật trong chữ của PR, không bắt lỗ hổng trong code.

## Test

### Anthropic khuyến nghị gì

- “Always give Claude a way to verify its own work, whether tests, a build, or a screenshot diff.” [S1]
- Đòi bằng chứng: “Have Claude show evidence rather than asserting success” [S3]. “If you can't verify it, don't ship it.” [S3]
- Với một bug, “write a failing test that reproduces the issue, then fix it” [S3]; playbook thêm một hook chặn agent sửa test
  trong lúc sửa lỗi [S1].
- Để một agent khác chấm: “Separating the agent doing the work from the agent judging it proves to be a strong lever” [S22].
- Kiểm cả cấu hình của agent: “Evals are the AI-native equivalent of stage-gate QA.” [S1] Playbook chạy eval trong CI mỗi khi
  CLAUDE.md, skill hay hook đổi [S1].
- Chạy cùng các phép kiểm ở máy và trong CI, để “the same checks you run locally fire on every push or PR” [S25].
- Tính trước tải CI: ở Anthropic, “Our CI job volume increased 25x over 6 months.” [S29] Họ đáp lại bằng phân tích ảnh hưởng
  của test (test impact analysis); “Claude prefers smaller, more granular PRs” [S29].

### Kit làm gì

- Tiêu chí spec là lệnh kèm kết quả mong đợi (Specify), nên kế hoạch kiểm có trước code.
- Skill [`ship`](../plugins/vibemaestro-sdlc/skills/ship/SKILL.md) chạy các lệnh chấp nhận và ghi output thật vào một file bằng
  chứng. `open-pr.sh` từ chối mở pull request khi file đó thiếu hoặc rỗng (mã thoát 3,
  [`open_pr.py`](../plugins/vibemaestro-sdlc/scripts/open_pr.py)); một lần chạy không thể làm phải ghi lý do ở dòng đầu.
- Luật [`before-ready`](../plugins/vibemaestro-sdlc/rules/before-ready.instructions.md) hỏi lệnh nào đã chạy trên **head đã
  push cuối cùng**, và tiêu chí nào còn chưa có lệnh.
- Luật [`measurement-commands`](../plugins/vibemaestro-sdlc/rules/measurement-commands.instructions.md): trước khi đưa ra một con
  số, chạy một phép đối chứng chắc chắn dương, vì kết quả rỗng có thể do dụng cụ đo hỏng.
- CI của chính kit chỉ chạy các suite mà thay đổi chạm tới (`tests/run-all.sh --changed`, trong `.github/workflows/test.yml`) và
  chạy toàn bộ suite hai lần mỗi tuần (`.github/workflows/test-full.yml`). Test của kit cố ý làm hỏng một bản sao của code và
  đòi kết quả đỏ ("planted breaks").

### Kit khác ở đâu

- **Xa hơn:** không mở được pull request qua kit khi thiếu bằng chứng chạy; máy kiểm bằng chứng có mặt, không kiểm ý nghĩa.
- **Cùng ý với [S29]:** mỗi pull request chỉ chạy các suite bị ảnh hưởng, toàn bộ suite chạy theo lịch.
- **Khoảng trống:** không có bộ eval chạy skill và luật của kit với một model. Test chứng minh script đúng và hook đưa luật tới;
  một phiên thật có làm theo hay không thì chưa đo. Đây là play eval liên tục của playbook [S1], và kit chưa có.
- **Khoảng trống:** không hook nào chặn sửa file test trong lúc sửa lỗi.

## Release

### Anthropic khuyến nghị gì

- Dùng hook làm cổng phê duyệt. Một hook có thể dừng thao tác tới khi một người được chỉ định duyệt, đúng thứ việc chặn phát
  hành cần [S1].
- “The governing principle is that the agent may act up to the production gate and cannot pass it.” [S1]
- Chuẩn bị đường lui trước khi cần: “rehearse the rollback paths before the agent ever needs them” [S1].
- Chạy Claude không tương tác trong pipeline bằng `claude -p` [S11], cho các bước cần phán đoán như phân loại một lần build
  hỏng hay soạn changelog [S1]. Trong CI khoá chặt, dùng chế độ quyền từ chối mọi thứ chưa được cho phép trước [S3], [S15].
- Giữ bí mật ngoài repo và ngoài tầm với của agent [S12], [S16].
- Giữ dấu vết kiểm toán: “The chain of commits is also the audit trail” [S1].

### Kit làm gì

- **BatonRun.** Mọi thao tác ghi ra ngoài phiên (merge, ghi qua GitHub API, push lên registry, xoá, đổi cài đặt Claude Code của
  người dùng) là một lần chạy của một script baton: được kiểm, diễn tập so với các dòng `Expect`, niêm phong, ký, chạy, kiểm lại
  trạng thái sau so với trạng thái mong đợi, hoàn tác khi lệch, và ghi log
  ([skill `batonrun`](../plugins/vibemaestro-sdlc/skills/batonrun/SKILL.md),
  [`baton.py`](../plugins/vibemaestro-sdlc/scripts/baton.py), [tiêu chuẩn](../plugins/vibemaestro-sdlc/docs/batonrun.md)). Chữ ký gắn với hash của script và
  tham số. Ở chế độ manual owner ký từng lần chạy; ở chế độ auto phiên tự ký lần chạy thường và chỉ hỏi owner khi lần chạy
  nằm trong danh sách dừng.
- **Quyền.** `baton.py permissions --print` in các luật quyền Claude Code một máy cần, và `--check` báo luật thiếu hay không an
  toàn.
- **Version.** Pull request đổi một plugin thì thêm một change file dưới `.changes/` và không sửa version (luật
  [`version-policy`](../plugins/vibemaestro-sdlc/rules/version-policy.instructions.md)). Một pull request release, do skill
  [`release`](../plugins/vibemaestro-sdlc/skills/release/SKILL.md) cắt bằng
  [`release.py`](../plugins/vibemaestro-sdlc/scripts/release.py) (`check`, `plan`, `cut`), gộp change file vào `CHANGELOG.md`
  của từng plugin, với tiêu đề đầu tiên là version đã phát hành. Sau khi nó merge, một baton script do chủ ký dời nhánh
  `release` tới nó. Bản phát hành công khai của chính kit ghi từng version vào `plugin.json` của nó và gắn tag
  `<plugin>--v<version>`.
- **Hợp đồng.** [`CONTRACT.md`](../plugins/vibemaestro-sdlc/CONTRACT.md) liệt kê điều một bên dùng tự động được phép dựa vào;
  một test đỏ khi bề mặt đó đổi mà không có change file đúng mức.
- **Gate.** Skill [`install-gates`](../plugins/vibemaestro-sdlc/skills/install-gates/SKILL.md) cài sáu mẫu workflow GitHub
  ([`gates/workflows/`](../plugins/vibemaestro-sdlc/gates/workflows/)): kỷ luật commit, giá trị nhạy cảm trong chữ của PR, tiêu
  đề PR, thân PR, bằng chứng review và nhánh chết. Mỗi job cho pull request checkout nhánh **base** (hoặc nhánh mặc định), không bao giờ là head
  của PR, nên pull request không sửa được script hay config đang chấm nó. Riêng file workflow vẫn lấy từ pull request, nên
  một thay đổi dưới `.github/` cần được review.

### Kit khác ở đâu

- **Xa hơn:** cổng phát hành của playbook là một hook hỏi trước một lệnh [S1]. Một lần duyệt baton phủ cả chuỗi thao tác ghi,
  có kế hoạch và cách hoàn tác hiện ra trước, và mất hiệu lực nếu script đổi. Mỗi lần chạy một lần duyệt, không phải mỗi lệnh
  một lần, là cách kit đáp lại sự mệt mỏi vì phê duyệt [S16].
- **Xa hơn:** change file giúp các pull request song song không bao giờ sửa cùng một dòng version, nên các phiên song song của
  [S1] không đụng nhau khi phát hành.
- **Xa hơn:** bản phát hành công khai của kit được quét tìm một danh sách thuật ngữ và secret trước khi công bố (`scripts/export-gate.sh`).
- **Khoảng trống:** kit không dùng Claude trong CI cho các bước phán đoán như phân loại build hỏng hay soạn changelog;
  changelog do một script gộp từ các change file.

## Operate

### Anthropic khuyến nghị gì

- Khép vòng: một trigger gọi Claude mà không cần người, và điều nó tìm thấy quay lại thành một intent mới [S1].
- Giữ việc phát hiện tất định: “detection stays entirely deterministic, with no model involved” [S1].
- “Give every agent a single-purpose identity with the minimum permissions for its job.” [S2]
- Cho agent xử lý sự cố bắt đầu ở chế độ chỉ đọc: Anthropic mô tả “a read-only Claude in your incident channel that diagnoses,
  escalates, and learns” [S30], với tài khoản dịch vụ riêng [S30].
- Với tác vụ theo lịch, nói rõ thế nào là thành công và làm gì với kết quả [S4].

### Kit làm gì

- Không gì trong kit theo dõi một hệ thống đang chạy. Ghi vào hệ thống đang chạy là một baton script như mọi hành động đặc quyền
  khác (Release); một thay đổi trên cluster đang chạy nằm ngoài làn đã duyệt mang từ dừng `cluster-lane`, nên owner ký
  ([BatonRun](../plugins/vibemaestro-sdlc/docs/batonrun.vi.md#6-phê-duyệt-chế-độ-danh-sách-dừng-chữ-ký-của-owner)).

### Kit khác ở đâu

- **Một phần cùng ý với [S2]:** mọi thao tác ghi đi qua một lần chạy có chữ ký; kit không dựng định danh agent nào của riêng nó.
- **Khoảng trống:** không có vòng giám sát. Không gì trong kit theo dõi production, phát hiện vượt ngưỡng hay ghi phát hiện
  ngược lại thành intent.
- **Khoảng trống:** không có agent xử lý sự cố và không xuất số liệu.

## Xuyên suốt mọi giai đoạn: ngữ cảnh, bộ nhớ và quyền

### Anthropic khuyến nghị gì

- Ngữ cảnh là ràng buộc chính: “Claude's context window fills up fast, and performance degrades as it fills.” [S3] Xoá ngữ cảnh
  giữa hai việc không liên quan, và dặn Claude giữ gì khi compact [S3].
- Giữ trạng thái ngoài cửa sổ ngữ cảnh: “Structured note-taking, or agentic memory, is a technique where the agent regularly
  writes notes persisted to memory outside of the context window.” [S18]
- Với việc dài, giữ một file tiến độ và lịch sử git; phiên mới nên “Read the git logs and progress files to get up to speed on
  what was recently worked on.” [S21]
- Chỉ compaction thì không phải lúc nào cũng đủ: “compaction isn't sufficient” [S21]. Lời khuyên phụ thuộc model: về sau họ bỏ
  việc reset ngữ cảnh vì “The resets had become dead weight.” [S23], [S22]
- Một hook SessionStart với matcher `compact` có thể nạp lại ngữ cảnh quan trọng sau mỗi lần compact [S7]; CLAUDE.md ở gốc
  project còn nguyên sau compaction [S10].
- Mỗi thành phần của harness “encodes an assumption about what the model can't do on its own” [S22]; xem lại nó khi model đổi
  [S23]. Bắt đầu bằng cách đơn giản nhất chạy được [S17].
- Quyền tối thiểu và cách ly: sandbox cần cách ly cả hệ thống file lẫn mạng [S14], [S16]; nó “reduces risk but is not a complete
  isolation boundary” [S14]. Anthropic báo rằng “sandboxing safely reduces permission prompts by 84%” [S16]. Chế độ bypass chỉ
  dành cho container và VM cách ly [S15]. Con người vẫn chịu trách nhiệm duyệt lệnh [S13].
- Con người vẫn chịu trách nhiệm: “Humans remain accountable for every decision that requires judgment.” [S1] Nghiên cứu của
  chính Anthropic cảnh báo “paradox of supervision”: giám sát Claude cần đúng những kỹ năng lập trình mà việc dùng nhiều có thể
  làm mai một [S27].

### Kit làm gì

- **Repo là bộ nhớ.** `kb/` chứa intent, spec, plan và quyết định. `kb/current-state.md` nói repo đang thế nào: nó được ghi
  đè, không bao giờ viết nối, và có giới hạn kích thước do `kb.py check current-state` kiểm (luật
  [`current-state-shape`](../plugins/vibemaestro-sdlc/rules/current-state-shape.instructions.md)). `kb.py find`, `list` và
  `outline` tìm đúng một mục mà không phải đọc cả file ([`kb.py`](../plugins/vibemaestro-sdlc/scripts/kb.py)).
- **Trạng thái phải sống qua compaction** nằm trong thân PR và `kb/`, không chỉ trong cuộc hội thoại
  ([`workflow-core`](../plugins/vibemaestro-sdlc/rules/workflow-core.instructions.md)).
- **Plugin brain** ([README](../plugins/vibemaestro-brain/README.md)) giữ một bộ nhớ nóng nhỏ cho phiên chạy dài: quyết định
  của owner, cửa sổ uỷ quyền, việc đang làm, việc kế tiếp và bẫy, tối đa 6.000 ký tự. Hook `SessionStart` của nó nạp lại bộ nhớ
  này ở mỗi lần khởi động, kể cả sau compaction; `PreCompact` và `PostCompact` ghi log từng lần compact và một điểm mất mát, tức
  tỉ lệ anchor của các mục còn sống mà bản tóm tắt đã bỏ mất ([`hooks.json`](../plugins/vibemaestro-brain/hooks/hooks.json)).
  Log được nối chuỗi bằng hash, và mục của owner chỉ được ghi sau hộp thoại xin quyền của Claude Code. Một khối
  `# Compact instructions` cho CLAUDE.md nằm trong
  [`compact-instructions.md`](../plugins/vibemaestro-brain/templates/compact-instructions.md).
- **Quyền:** các luật quyền của BatonRun (Release).

### Kit khác ở đâu

- **Xa hơn:** brain đo xem compaction làm mất gì thay vì giả định; kết quả nằm trong
  [bản tổng hợp nghiên cứu về brain](research/brain.vi.md).
- **Xa hơn:** file current-state được ghi đè, không viết nối, nên phiên mới đọc hiện tại, không phải một log cần phát lại.
- **Xa hơn:** hook SessionStart của plugin sdlc có thể đưa chỉ mục current-state của repo vào lúc mở phiên và sau mỗi lần
  compact (`current_state.inject`, mặc định tắt).

## Kit đi xa hơn ở đâu, và vì sao

### BatonRun cho thao tác ghi đặc quyền

Hướng dẫn của Anthropic đặt việc duyệt vào hook [S1] và cảnh báo sự mệt mỏi vì phê duyệt [S16]. Kit biến một thao tác đặc
quyền thành một **lần chạy**: một script, được diễn tập, ký theo hash của nó, do phiên tự chạy, kiểm lại và ghi log. Owner không
bao giờ phải gõ lệnh theo hướng dẫn của model, và một chữ ký phủ một chuỗi cố định. Chi tiết: [BatonRun](../plugins/vibemaestro-sdlc/docs/batonrun.vi.md) và
[bản tổng hợp nghiên cứu về BatonRun](research/batonrun.vi.md).

### Change file thay cho sửa version

Chạy nhiều phiên song song là thực hành cốt lõi trong [S1]. Khi mỗi pull request tự nâng version, các pull request song song sẽ
xung đột. Kit cho mỗi pull request một change file riêng, và để một pull request release duy nhất đặt version.

### Brain cho compaction

Chính các bài của Anthropic, theo thời gian, nói khác nhau về compaction và reset ngữ cảnh, và nói câu trả lời tuỳ model [S21],
[S22], [S23]. Kit giữ một bộ nhớ nóng nhỏ, được kiểm, nạp lại sau mỗi lần compact, và ghi điểm mất mát, để câu hỏi đó đo được
cho từng phiên.

### Repo là bộ nhớ

Playbook commit một sản phẩm ở mỗi giai đoạn [S1], và harness chạy dài giữ file tiến độ [S21]. Kit làm cả hai với một vòng đời
được kiểm: intent, spec và plan có hình dạng cố định, liên kết giữa chúng được kiểm (`kb.py check links`), và file current-state
có giới hạn kích thước.

### Gate chấm theo nhánh base

Playbook dùng managed settings để không kỹ sư hay file project nào nới được luật [S1]. Gate CI của kit áp cùng ý đó cho pull
request: mỗi gate đọc script và config của nó từ nhánh base, nên pull request không sửa được script hay config của chính người chấm nó.
Riêng file workflow vẫn lấy từ pull request, nên một thay đổi dưới `.github/` cần được review.

## Khoảng trống đã biết

| Khoảng trống | Hướng dẫn của Anthropic | Sẽ nằm ở đâu |
|---|---|---|
| Duyệt spec không phải cổng | Plan mode chặn sửa file tới khi kế hoạch được chấp nhận [S1] | một hook trong `vibemaestro-sdlc` |
| Review ngữ cảnh mới không phải cổng | Tách bạch trách nhiệm [S1] | một hook trên `gh pr ready` |
| Không có lượt review dùng chung có mức nghiêm trọng | Các lượt trong REVIEW.md [S1]; Code Review xếp theo mức nghiêm trọng [S24] | một skill review |
| Không có bước review bảo mật | `/security-review` trước khi mở PR [S2], [S31] | skill `ship` |
| Không có eval cho skill và luật với một model | Eval liên tục khi cấu hình đổi [S1] | CI của kit |
| Không chặn sửa file test khi sửa lỗi | Một hook chặn sửa test [S1] | một hook |
| Không có vòng giám sát hay agent sự cố | Phát hiện tất định; phát hiện thành intent [S1]; trực sự cố chỉ đọc [S30] | ngoài kit |
| Hook fail open | Hook là đảm bảo [S3], [S5] | không: hook fail open theo thiết kế |

## Thuật ngữ

- **applyTo**: frontmatter của một luật: danh sách glob file. Khi phiên sắp sửa một file khớp, hook giao luật đó.
- **applyWhen**: frontmatter của một luật: một biểu thức chính quy trên lệnh Bash sắp chạy. Khi khớp, hook giao luật đó; với `level: block` thì nó chặn lệnh.
- **baton script**: trong BatonRun, script mang một run, có phần đầu (mục đích, đích, phạm vi ảnh hưởng, hoàn tác, điều kiện trước, điểm dừng, expect), một nhánh diễn tập in ra kế hoạch, và một bước hoàn tác. Chữ ký gắn với hash của script và các tham số của nó. Xem [BatonRun](../plugins/vibemaestro-sdlc/docs/batonrun.vi.md#2-thuật-ngữ).
- **BatonRun**: cách của kit cho hành động đặc quyền: một quy trình lặp lại chạy thành một run có cổng (viết, kiểm, diễn tập, niêm phong, ký, chạy, kiểm sau, ghi log). Hình ảnh là cây đũa của nhạc trưởng: chỉ phiên chạy hành động cầm nó. Chuẩn là [BatonRun](../plugins/vibemaestro-sdlc/docs/batonrun.vi.md).
- **brief**: hợp đồng mà phiên chính giao cho một subagent trong `local-parallel`: điều phải đúng, các lệnh nghiệm thu và phạm vi. Gặp điều gì ngoài phạm vi, subagent dừng lại và hỏi. Báo cáo của nó là một lời khẳng định, không phải bằng chứng.
- **consumer contract** (hợp đồng consumer): [`CONTRACT.md`](../plugins/vibemaestro-sdlc/CONTRACT.md), danh sách điều một bên dùng tự động được phép dựa vào trong một major version, được test hợp đồng của kit kiểm.
- **current-state ledger** (sổ hiện trạng): `kb/current-state.md`: repo hiện ra sao, viết đè và không bao giờ viết nối, có trần kích thước và danh sách dấu hiệu lịch sử bị từ chối.
- **fail open**: hook mà khi lỗi thì thoát 0 và để lệnh gọi công cụ chạy tiếp, nên một plugin hỏng không chặn được việc.
- **fresh-context review** (review ngữ cảnh mới): review do một agent hay một người không viết thay đổi và chưa thấy lập luận của tác giả thực hiện, trên diff cuối đã ghim. Tác giả tự đọc lại việc của mình không tính.
- **gate** (cổng): một phép kiểm có đếm và đỏ lên, khác với luật, thứ chỉ nhắc.
- **guarded merge** (merge có canh): lệnh merge chỉ merge khi các phép canh đạt (SHA của head, check mới nhất, xung đột, danh sách cấm, phạm vi của brief), và mặc định chạy thử.
- **intent**: `kb/intent/<ngày>-<slug>.md`, lời của chính người yêu cầu, ghi trước khi có branch. Một intent là một branch là một pull request nháp.
- **kb**: thư mục `kb/` của một repo: intent, spec, plan, quyết định và file hiện trạng.
- **main session** (phiên chính): trong `local-parallel`, phiên mà người nói chuyện cùng: nó chia việc, giao brief cho mỗi subagent một việc, chuyển spec cho người duyệt, kiểm lại và merge. Nó không sửa file nào của một việc.
- **planted break** (phá thử): một test chép code, cố ý phá bản chép ở một chỗ, và đòi suite phải đỏ.
- **spec**: `kb/specs/<ngày>-<slug>.md`: bốn mục theo thứ tự, tiêu chí là lệnh, được một người duyệt trước khi có code.
- **worker**: một subagent xây một việc theo một brief, từ intake tới một pull request nháp. Kết quả của nó là một lời khẳng định; phiên chính chạy lại lệnh nghiệm thu trước khi tin.

## Nguồn

| Id | Title | URL |
|---|---|---|
| S1 | The AI-native SDLC playbook | https://claude.com/resources/articles/the-ai-native-sdlc-playbook |
| S2 | How Anthropic secures its AI-native software development lifecycle | https://claude.com/resources/articles/how-anthropic-secures-its-ai-native-software-development-lifecycle |
| S3 | Best practices for Claude Code | https://code.claude.com/docs/en/best-practices |
| S4 | Common workflows | https://code.claude.com/docs/en/common-workflows |
| S5 | Extend Claude Code | https://code.claude.com/docs/en/features-overview |
| S6 | Create custom subagents | https://code.claude.com/docs/en/sub-agents |
| S7 | Automate actions with hooks | https://code.claude.com/docs/en/hooks-guide |
| S8 | Extend Claude with skills | https://code.claude.com/docs/en/skills |
| S9 | Plugins overview | https://code.claude.com/docs/en/plugins/overview |
| S10 | How Claude remembers your project | https://code.claude.com/docs/en/memory |
| S11 | Run Claude Code programmatically | https://code.claude.com/docs/en/headless |
| S12 | Claude Code GitHub Actions | https://code.claude.com/docs/en/github-actions |
| S13 | Security | https://code.claude.com/docs/en/security |
| S14 | Configure the sandboxed Bash tool | https://code.claude.com/docs/en/sandboxing |
| S15 | Choose a permission mode | https://code.claude.com/docs/en/permission-modes |
| S16 | Beyond permission prompts: making Claude Code more secure and autonomous | https://www.anthropic.com/engineering/claude-code-sandboxing |
| S17 | Building effective agents | https://www.anthropic.com/engineering/building-effective-agents |
| S18 | Effective context engineering for AI agents | https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents |
| S19 | How we built our multi-agent research system | https://www.anthropic.com/engineering/multi-agent-research-system |
| S20 | Equipping agents for the real world with Agent Skills | https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills |
| S21 | Effective harnesses for long-running agents | https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents |
| S22 | Harness design for long-running application development | https://www.anthropic.com/engineering/harness-design-long-running-apps |
| S23 | Scaling Managed Agents: Decoupling the brain from the hands | https://www.anthropic.com/engineering/managed-agents |
| S24 | Code Review for Claude Code | https://claude.com/resources/articles/code-review |
| S25 | Building verification loops in Claude Code with skills | https://claude.com/resources/articles/building-verification-loops-in-claude-code-with-skills |
| S26 | Running an AI-native engineering org | https://claude.com/resources/articles/running-an-ai-native-engineering-org |
| S27 | How AI is transforming work at Anthropic | https://www.anthropic.com/research/how-ai-is-transforming-work-at-anthropic |
| S28 | Agentic coding and persistent returns to expertise | https://www.anthropic.com/research/claude-code-expertise |
| S29 | Agentic coding is straining CI. Here's how we scaled test impact analysis at Anthropic | https://claude.com/resources/articles/agentic-coding-is-straining-ci-heres-how-we-scaled-test-impact-analysis-at-anthropic |
| S30 | How Claude Tag serves as Anthropic's first responder for CI/CD failures | https://claude.com/resources/articles/ai-ci-cd-on-call |
| S31 | Commands | https://code.claude.com/docs/en/commands |
