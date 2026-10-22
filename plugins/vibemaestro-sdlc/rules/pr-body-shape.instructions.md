---
applyWhen: "\bgh(?:\s+(?:-R|--repo)[\s=]+\S+)?\s+pr(?:\s+(?:-R|--repo)[\s=]+\S+)?\s+(?:create|edit|comment)\b|open-pr\.sh"
description: "The PR body is the current state, overwritten each round; round history goes in comments that start with tokens.round_comment_prefix; lessons go to kb/, not the body"
---

# PR body shape

The body is the **current state** of the PR, overwritten, never appended: no "Round N" sections, no session log. A machine caps it: at most **3000 characters** in all, the summary at most **10 lines**, the evidence at most **30 lines** (`pr.body.max_chars`, `pr.body.summary_max_lines`, `pr.body.evidence_max_lines`; `0` turns one off). `open-pr.sh` refuses a longer body (exit 2) and the `pr-body` gate is red on a PR whose live body is over, one rewritten with `gh pr edit` included. The detail goes elsewhere: what outlives the PR to `kb/specs/` or `kb/decisions/` (nobody rereads a body after the merge), what happened in a round to a comment (below).

`open-pr.sh` builds it. You write two files and the core adds the headings (`tokens.summary_heading`, `tokens.evidence_heading`, and `tokens.criteria_heading` when criteria are given):

- the **summary** file, without a heading: what changed and why, then risks and what to look at, manual steps, what is out of scope, if any: 10 lines in all, 5 are usually enough;
- the **evidence** file: the commands and their last result lines, a few lines each, 30 at most. The core refuses an empty one. Full logs stay outside the PR, or in a comment after you have read them back.

After every round, rewrite summary, risks and evidence so they match the new head:

    gh pr view <N> --json body -q .body > body.md   # edit it, then:
    python3 "${CLAUDE_PLUGIN_ROOT}/gates/pr_body.py" --body-file body.md   # rc 1 names each limit that is broken
    gh pr edit <N> --body-file body.md

What happened in a round goes in a **comment**, one per round, whose first line is the token `tokens.round_comment_prefix` followed by the full SHA of the head it describes; for a review round the line also says `review round N`, and E2E evidence is a line `E2E pass` or `E2E not run: <reason>` in such a comment. The `pr-evidence` gate reads these on the current head; the body has no flow checklist.

The title of an intent PR starts as a description of its record (it is right while the PR holds only `kb/`). Before ready, once the diff carries files outside `kb/`, rewrite it as `type(scope): what was done`: what the PR brings into main.
