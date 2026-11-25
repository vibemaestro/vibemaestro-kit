# `kb/` của repo này

Nơi repo ghi nhớ: yêu cầu, thiết kế, quyết định và hiện trạng — để người và phiên Claude Code sau không phải đoán.
Dựng bởi skill `init-kb` của plugin `vibemaestro-sdlc`; file này tự đủ, sửa tay thoải mái.

| Thư mục / file | Nội dung | Có nghĩa vụ cập nhật? |
|---|---|---|
| `intent/` | yêu cầu gốc bằng lời người đặt, 1-2 đoạn; với story: chính story chủ repo duyệt | không — bản ghi một lần |
| `specs/` | điều phải đúng, suy ra từ story: mục tiêu, ràng buộc, tiêu chí, rủi ro; spec của một intent theo khuôn bên dưới | có, khi code dạy điều mới (spec sống) |
| `plans/` | cách làm: mỗi PR một hàng, giao AC nào, phụ thuộc, chỗ cần ký; plan sống | có, khi code dạy điều mới |
| `decisions/` | chốt một lựa chọn, **kèm phương án bị loại** | không, nhưng nêu rõ khi bị thay |
| `current-state.md` | trạng thái hiện hành của repo | **có — file DUY NHẤT phải luôn đúng** |

**Tên file** `intent/`, `specs/`, `plans/`, `decisions/`: `<YYYY-MM-DD>-<slug>.md`, slug chữ thường không dấu, số, gạch nối.

**`decisions/` tới tay người sửa:** frontmatter `applyTo: "<glob>,<glob>"` làm plugin nhắc quyết định đó khi ai sửa file
khớp glob, khi `status` là `live` (hay `active` cũ, cùng nghĩa). Không khai `applyTo` thì không được nhắc.

**Lifecycle (frontmatter of any document):** `status: live | superseded | done | draft` (absent means `live`), and
`supersedes:` / `superseded_by:` (repo-relative paths; the two documents name each other). `draft`: not yet agreed or
approved. `live`: an open intent, a spec or decision in force, a plan being executed. `done`: an intent whose PR merged, a
plan whose tasks all merged, a one-off spec (port, rename, migration) that no longer describes the system, a one-time
decision fully carried out. `superseded`: replaced as a whole by `superseded_by`; a partial amendment is not supersession.
Check: `kb.py check [--strict]`.

**Finding things without reading them:** `kb.py find <words>` (superseded/done hidden unless `--all`), `kb.py list
[--type T] [--status S]`, `kb.py outline <file>` (line range and size of each section, to read one with offset/limit).

**Story** (intent loại story, viết bằng ngôn ngữ repo đặt): dòng "Là / tôi muốn / để", bối cảnh, AC đánh số (mỗi AC "khi … thì
…"), phần không làm, estimation, phần **Lời người hỏi → AC** (đúng bảng khuôn viết: mỗi hàng một lời trích nguyên văn | các AC
nó đòi, AC1, AC2 hay AC1–AC3; mọi AC có mặt ở ít nhất một hàng), tối đa 3 câu hỏi; vừa một màn hình điện thoại, không lệnh,
tên tệp hay code; context và AC nói người hỏi muốn gì và sẽ thấy gì bằng lời thường, còn giá trị chính xác, tên tham số, mã trạng thái, luật so khớp và giao thức thuộc spec, và câu trả lời cho câu hỏi kỹ thuật vào spec, không ghi ngược vào AC. Mỗi câu hỏi có bốn phần có nhãn, mỗi nhãn mở một dòng: **Vì sao có câu hỏi này** (kèm một ví dụ),
**Mỗi phương án nghĩa là gì**, **Tác động**, **Đề xuất** (kèm lý do). Kiểm: `kb.py check intent <ngày>-<slug>`: thiếu phần, phần rỗng,
phần lời → AC không phải bảng ấy, lời không trỏ AC, AC không có hay AC không nằm hàng nào thì đỏ với story mới hoặc đổi thân;
story đã có trên merge base, thân không đổi, chỉ bị cảnh báo. Mã ngắn không giải thích trong ngoặc ngay sau nó (D24 (…)) và
AC không viết "khi … thì" chỉ bị cảnh báo.

**Khuôn spec của một intent:** năm mục `## `, thứ tự tuỳ ý — `## Mục tiêu` (mỗi mục trỏ về AC, `→ AC<n>`), `## Ràng buộc`
(bảo mật, chi phí, tương thích; không phải cách làm), `## Tiêu chí chấp nhận` (theo hành vi, "khi … thì …", mỗi tiêu chí trỏ về AC),
`## Rủi ro cần test phủ` (rủi ro test phải phủ), `## Cần làm rõ`. Không cách làm, không lệnh trừ khi chính lệnh là hành vi; khoảng 2 trang.
Spec dạng cũ (`## Bối cảnh`, `## Ngoài phạm vi`, `## Inputs and failure cases`, tiêu chí là lệnh) đã có chỉ bị cảnh báo; spec
của story mới viết hay bị sửa thì theo dạng mới. Kiểm hình dạng: `kb.py check spec <ngày>-<slug>`.

**Khuôn `current-state.md`:** chỉ trạng thái hiện hành, viết đè không nối thêm; không lịch sử (ngày đo, số PR, "trước
đây…"), không cách làm hay số liệu thí nghiệm — chi tiết nằm ở `specs/` và `decisions/`, file này chỉ trỏ tới. Có trần
kích thước. Kiểm: `kb.py check current-state`.
