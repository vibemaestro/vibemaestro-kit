# `kb/` của repo này

Nơi repo ghi nhớ: yêu cầu, thiết kế, quyết định và hiện trạng — để người và phiên Claude Code sau không phải đoán.
Dựng bởi skill `init-kb` của plugin `vibemaestro-sdlc`; file này tự đủ, sửa tay thoải mái.

| Thư mục / file | Nội dung | Có nghĩa vụ cập nhật? |
|---|---|---|
| `intent/` | yêu cầu gốc bằng lời người đặt, 1-2 đoạn | không — bản ghi một lần |
| `specs/` | thiết kế: vì sao, đánh đổi, số đo; spec của một intent theo khuôn bên dưới | không — đóng lại khi thi hành xong |
| `plans/` | chia việc: cái gì phải đúng + lệnh nghiệm thu | không |
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

**Khuôn spec của một intent:** bốn mục `## ` đúng thứ tự — `## Bối cảnh`, `## Mục tiêu`, `## Ngoài phạm vi`,
`## Tiêu chí chấp nhận`; `## Thiết kế` (tuỳ chọn) đứng sau. Tiêu chí là **lệnh** + kết quả mong đợi; tiêu chí cuối luôn là:
PR có mục `## Bằng chứng chạy`. Kiểm hình dạng: `kb.py check spec <ngày>-<slug>`.

**Khuôn `current-state.md`:** chỉ trạng thái hiện hành, viết đè không nối thêm; không lịch sử (ngày đo, số PR, "trước
đây…"), không cách làm hay số liệu thí nghiệm — chi tiết nằm ở `specs/` và `decisions/`, file này chỉ trỏ tới. Có trần
kích thước. Kiểm: `kb.py check current-state`.
