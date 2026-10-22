---
description: "<ĐIỀN: một dòng — plan này giao gì>"
issue: <ĐIỀN: số issue của chủ đề, hoặc bỏ dòng>
---

# Plan — <ĐIỀN: chủ đề>

Intent: <ĐIỀN: kb/intent/… của chủ đề, hoặc bỏ> · Spec: <ĐIỀN: kb/specs/…, hoặc bỏ> · Issue: #<ĐIỀN: số>

Mỗi PR một hàng, ghi TRƯỚC khi giao PR đó và không sửa để ghi trạng thái: `kb.py plan status <file này>` đọc trạng thái từ GitHub.
Phiên nhận một hàng ghi `plan: <file này>#<hàng>` vào frontmatter intent (và spec) của nó. PR mới → hàng mới; PR bị bỏ → `dropped: <lý do>` ở ô Link.

## Rows

| Row | Must be true | Acceptance | Depends on | Version | Model | Link |
|---|---|---|---|---|---|---|
| A | <ĐIỀN: một dòng> | `<ĐIỀN: lệnh>` → <ĐIỀN: kết quả> | — | <ĐIỀN: — hoặc, ở hàng release, plugin x.y.z> | <ĐIỀN: model, effort> | — |

## Decisions

- <ĐIỀN: YYYY-MM-DD HH:MM> — "<ĐIỀN: lời của chủ repo, nguyên văn>" — [<ĐIỀN: nơi nói>](<ĐIỀN: link>)
