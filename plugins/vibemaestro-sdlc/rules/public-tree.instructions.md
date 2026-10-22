---
applyTo: "${public.tree}"
description: "This repo publishes its tree minus kb/ and public.private: every other file is public when it merges; nothing private, no pointer into kb/"
---

# Outside kb/, every file is public

This file ships to people who have no `kb/`. Prose in a doc also follows `docs-final.instructions.md`. CI job `public-tree` (`scripts/public-tree.py`, where the repository runs it) checks 1 and 2 on every change; its baseline only shrinks.

1. Nothing private: no secret or real token, no person's name, e-mail or machine path, no real host, IP, account, organisation or internal repository (use a reserved name such as `example.invalid`, `.test` or `example.com`, and the documentation ranges).
2. No pointer into `kb/`, no private issue, PR or plan-row number (in public, `#N` is someone else's issue), no who-decided-when: give the reason.
3. A test runs from this tree alone, with no secret and no other repository; a login, CLI or service it needs is checked first, and its absence is a skip that names it.
4. A file that must stay private goes on `public.private`, not into a comment.
