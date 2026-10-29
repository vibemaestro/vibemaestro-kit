---
name: ship
description: "Use when: the work of an intent in an app repo is done and a PR must be opened — update the repo's kb/current-state.md, run the acceptance commands and record the evidence, then open a draft PR with the plugin's scripts/open-pr.sh (do not open a PR with a bare gh command)."
---

# ship — open the PR for the intent of an app repo

The PR is opened through the plugin's core because the core refuses the cases that a bare `gh` command lets through: missing run evidence
(rc 3), standing in the main tree instead of a worktree (rc 5), and — if the repo has `scripts/check-current-state.py` —
a red current-state gate with no exemption line in the PR body (rc 4).

Condition: you stand in a worktree, on the branch `intent/<date>-<slug>`; all child tasks have merged back.

## Do

1. **The current-state ledger.** If the change alters the repo's current state, **overwrite** `kb/current-state.md` in this very PR
   so that it matches the state now in force — do not append, do not write a measurement date / PR number / "previously…", do not write how it is done
   (push detail to `kb/specs/` or `kb/decisions/`, current-state only points to it). Then run the machine check:

   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/kb.py" check current-state
   ```

   rc `0` is green; rc `65` names each violating line (a history mark, over the cap) — fix until green. A repo with no
   `kb/current-state.md` (no `init-kb` yet) or an empty file gets rc `66` from the machine: this step is **not** a hard gate in a repo with no shape yet
   — say so in the PR body and build the shape with `vibemaestro-sdlc:init-kb` in a PR of its own. The core's gate (`open-pr.sh`) applies only
   when the repo has `scripts/check-current-state.py`; the machine check here is a step of the skill, it does not replace that gate.
2. **Links and blanks:** `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/kb.py" check links` passes (a broken intent, spec or plan link in a file you
   changed fails; `open-pr.sh` adds the `Plan row:` line itself when the intent has `plan:`), and
   `git grep -nF '<FILL' -- kb` must come out empty (the mark is `tokens.spec.placeholder`: `<FILL` in a
   repo with `"language": "en"`; a repo on the default `vi` language greps for the Vietnamese mark that `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/sdlc_config.py" get tokens.spec.placeholder` prints).
3. **Acceptance with the repo's commands** (the test/build the app repo declares). Write the **commands and the real output** into an
   evidence file outside the repo (the session's temp directory). If it cannot run, the first line of the file says
   `NOT RUN: <concrete reason>` (token `tokens.not_run`: `NOT RUN:` with `"language": "en"`; a repo on the default `vi` language uses the Vietnamese token that `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/sdlc_config.py" get tokens.not_run` prints). Write one more file, a summary: what changed, why.
   - **Only the suites your diff touches:** when the repo has a suite planner (for example `bash tests/run-all.sh --changed origin/main`),
     run the planner's suites for your diff, not the whole suite; CI runs the plan on the head, and the full suite runs on the schedule.
   - **The evidence is plain text:** command lines and their real output as they are, no Markdown and no fences of your own. The
     core puts it in one code block whose fence is longer than any run of backticks in it, so output that holds fences or
     `## ` lines stays inside the block.
   - **Body cap:** the whole body 3000 characters, the summary 10 lines, the evidence 30 lines (`pr.body.*`): `open-pr.sh` refuses a
     longer body (exit 2) and the `pr-body` gate checks the live one; detail goes to the spec, `kb/` or a round comment.
   - **Line limit:** the core also cuts an evidence file over 80 lines (first 10 and last 70, with the `tokens.evidence_cut`
     marker), which only matters when `pr.body.evidence_max_lines` is 0. Keep the file to the commands that prove the criteria and
     the lines of their output that show the result.
4. **Open the draft PR through the plugin's core:**

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/open-pr.sh" --title "type(scope): what was done" \
       --summary <summary-file> --evidence <evidence-file> --base <default branch> --closes <issue number> --draft
   ```

   - Unless `--dry-run`, `open-pr.sh` sends the `ship` stage signal itself (`scripts/stage-signal.sh`: a no-op without a sandbox, never fails the script).
   - Pass `--closes` **explicitly**: take the number from the `issue:` line of `kb/intent/<date>-<slug>.md`. (Standing on the branch
     `intent/<slug>`, `open-pr.sh` also reads that number by itself from the intent of the repo you stand in and prints it; a number passed by hand still wins.)
     A PR with no issue (like the PR that builds the kb scaffold) leaves the flag out.
   - After creating the PR with `--closes`, the core polls GitHub (a few seconds) for the closing link and prints either
     `closing link confirmed` or `WARNING: could not confirm …`. A warning does not change the exit code: report it to the
     user, check the PR page's linked-issue sidebar, and do **not** open a second PR.
   - `--base`: the default branch of the app repo (`main` unless said otherwise).
   - The PR body follows the core's shape; the two files you write are your whole contribution. `--dry-run` to read
     the payload without touching the network.
5. **Before moving to ready or reporting done:** follow the whole `before-ready` rule that the hook reminds you of when you run
   `gh pr ready` (evidence on the final version, a review with fresh context). A draft PR is only a place to review, not a review that has happened.
   Spawn the review agent on the configured review model: `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/sdlc_config.py" get agents.review_model`
   prints it, and it goes into the Agent tool's `model`. Give the agent the PR and the head SHA it reviews, not your conclusion.
   At the start of each review round run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/stage-signal.sh" review --subagents <n>` (`<n>` reviewers launched; a no-op without a sandbox).
   If the read fails, use the plugin default (the same command with `--default`), tell the person what
   `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/kb.py" config check` names, and do not edit the config for them; if the
   `--default` read fails too, ask the person which model to use.

## What evidence is, and what it is not

Evidence is a **command that ran on the last pushed version, with its exit code and real output** — not the claim of the person who
wrote it. A script that is clean under `bash -n` can still die on its first line when it really runs; a failure of that kind shows up only after **one run**,
not through a syntax check, through reading the diff, or through re-reading the code yourself.

| What is often submitted instead | Why it does not count |
|---|---|
| `bash -n` / `python -m py_compile` | says only that the syntax is right, not that it runs |
| `git diff --stat` | says how many lines you changed, not that they run |
| "re-read the code, the logic is right" | the opinion of the writer about their own work |
| "tests should pass" / "it will run" | the future tense is not evidence |
| listing the criteria and ticking them yourself | a tick is a conclusion, not data |
| the output of a run BEFORE the fix | it must be the run on the last version you pushed |

A change that truly cannot run (docs only, comments only) puts `NOT RUN: <concrete reason>` on the first line of the evidence file (the token of `tokens.not_run`, as in step 3) —
that is a named exemption, not a back door for a change that has code.

**Three questions before reporting done** — report only when you can answer all three:

1. Which command did I run on the **last pushed version**, and what was the exit code?
2. Is that output in the PR body, in the `## Run evidence` section?
3. Which acceptance criterion has **no** command proving it yet? Name it in the report — do not leave the reader to find out.

The report states **the measured result** (`PR #N · <k> files · <command> exit 0`), not a feeling like "fully completed".

**The merger.** The session does not merge the intent's PR itself. When you ask the person to review or merge it, name the PR as a markdown link with the full URL inside the sentence, next to the action asked: `[PR <n>](https://<host>/<org>/<repo>/pull/<n>)`; a bare number is not enough.
