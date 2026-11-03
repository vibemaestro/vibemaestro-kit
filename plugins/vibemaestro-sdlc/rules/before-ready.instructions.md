---
applyWhen: "\bgh(?:\s+(?:-R|--repo)[\s=]+\S+)?\s+pr(?:\s+(?:-R|--repo)[\s=]+\S+)?\s+ready\b"
description: "Before moving a draft PR to ready: evidence run on the final version, the current state correct, a review with fresh context, no self-merge"
---

# Before moving a PR to ready

A draft PR is only a place to review, not a review that has happened. CI does not run on a draft (except `pr-sensitive` in a public repository): the related suites run locally and the review of item 5 happens BEFORE ready, and going ready starts CI, the ready-time gate. Before moving it to ready, be able to answer every question below:

1. Which acceptance command ran on the **last pushed head**, with what exit code? Is its output in the PR body's evidence section (`tokens.evidence_heading`)?
2. Which acceptance criterion of the spec has **no** command proving it yet? Name it in the PR body; do not let the reader find it.
3. Has `kb/current-state.md` been overwritten to match the present state, and is the checker
   `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/kb.py" check current-state` green (if the repo has that shape)?
4. Does `git grep -nF "$(python3 "${CLAUDE_PLUGIN_ROOT}/scripts/sdlc_config.py" get tokens.spec.placeholder)" -- kb` come back empty (no unfilled
   scaffold left)? The mark is the config's `tokens.spec.placeholder`, so it follows the repo's `language`.
5. Has a review round with **fresh context** (another agent, or a person) been done on the final diff? The author rereading their own work
   does not count as a review. A review agent runs on the configured review model: it is what
   `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/sdlc_config.py" get agents.review_model` prints, passed as the Agent tool's `model`.
   If the read fails, use the plugin default (the same command with `--default`), tell the person what
   `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/kb.py" config check` names, and do not edit the config for them; if the
   `--default` read fails too, ask the person which model to use.
   A high-risk change (a gate, a core, security, data that cannot be recovered) may run its review on `fable`, the strongest
   tier; a repo whose changes are mostly high-risk sets `agents.review_model` to `fable` (a repo with installed gates refreshes
   `.vibemaestro/gates/sdlc_config.py` no later than the PR that adds any `agents.*` key: see `install-gates`). Brief the reviewer with the template `skills/ship/reviewer-brief.md` of the plugin.
6. Is the chain of commits no review has seen folded to one commit per task or round (rule `commit-unit`)?
7. Do summary, risks and evidence describe the head, not an earlier round (rule `pr-body-shape`)?
8. Does the PR carry files outside `kb/`? Then the title must say what the PR brings into main as `type(scope): what was done`, not describe the intent record.
9. Did **every fix round** end with its own fresh-context re-review that read each changed function **whole**, with its callers and its tests, not only the fix diff? A round reviewed on its diff alone leaves the last fix with no reviewer. A small fix may be re-reviewed on the cheaper `agents.worker_model`; any other round on `agents.review_model`, as in item 5.
10. For **each defect fixed**, did you list the other places in the change with the same class of defect (the same input unchecked, the same error path, the same type confusion) and fix or test them **in the same commit**? Name the sweep in the round's comment: the class, where you looked, what you found.
11. Is this the **second fix of the same class**? Then stop patching: find the root cause in the shared code, or question the design (and say so to whoever briefed you) before another patch.

A session does not merge the intent's PR itself: a person merges.
