---
description: "<ĐIỀN: một dòng — plan này giao gì>"
issue: <ĐIỀN: số issue của chủ đề, hoặc bỏ dòng>
focus: <ĐIỀN: P<n>, trọng tâm của chủ đề>
---

# Plan — <ĐIỀN: chủ đề>

Intent: <ĐIỀN: kb/intent/… của chủ đề, hoặc bỏ> · Spec: <ĐIỀN: kb/specs/…, hoặc bỏ> · Issue: #<ĐIỀN: số>

Plan giữ cách làm: hướng đi và các PR, mỗi PR một hàng. Plan sống: khi code dạy điều mới, sửa plan và spec trong cùng PR; đổi
một AC của story thì hỏi chủ repo. Phiên nhận một hàng ghi `plan: <file này>#<hàng>` vào frontmatter intent của nó;
`kb.py plan status <file này>` đọc trạng thái từ GitHub. PR bị bỏ → `dropped: <lý do>` ở ô Link. Hàng release thêm cột Version.

## Hướng đi

<ĐIỀN: hướng đi, thứ tự các hàng và vì sao>

## Rows

| Row | Title | How | Delivers | Depends on | Trust touches | Link |
|---|---|---|---|---|---|---|
| A | <ĐIỀN: kết quả ngắn của PR, khoảng 60 ký tự, không đường dẫn, không code> | <ĐIỀN: cách làm của PR này, chạm vào đâu> | AC<ĐIỀN: số> (tiêu chí <ĐIỀN: số>) | — | <ĐIỀN: none, hoặc `<kind> [<owner/repo>:]<path> [<object>] [Stops: <words>]`, nối bằng ;> | — |

## Decisions

- <ĐIỀN: YYYY-MM-DD HH:MM> — "<ĐIỀN: lời của chủ repo, nguyên văn>" — [<ĐIỀN: nơi nói>](<ĐIỀN: link>)
