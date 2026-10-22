---
name: local-parallel
description: "Use when: on one machine (no sandbox, only vibemaestro-sdlc and vibemaestro-brain), the person wants several tasks done in parallel — the main session splits the work into tasks, starts one subagent per task (its own worktree, intake to a draft PR), keeps the queue, relays spec approvals, post-checks each PR and merges it with kit:merge-pr."
---

# local-parallel — several tasks at once on one machine

Local way of working: one machine, `vibemaestro-sdlc` and `vibemaestro-brain`, no sandbox. The main session takes
the coordinating role of rule `coordinated-work` (read `${CLAUDE_PLUGIN_ROOT}/rules/coordinated-work.instructions.md`: it talks with the person, briefs, decides, post-checks, merges, and edits no file of a task);
each task runs in a subagent started with the Agent tool on `agents.worker_model`, which does what a sandbox worker does: intake to a
draft PR. One task at a time needs none of this: run the normal flow in the main session.

Read the model before the first start: `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/sdlc_config.py" get agents.worker_model` (and
`agents.review_model` for the review); if the read fails, the core's fallback (`--default`) applies.

Before the first PR, check the repo has CI: `kit:merge-pr` (section 4) merges only a PR with at least one green check run on its
head (with `merge.required_checks` unset), so a repo with no CI cannot merge any task. Skill `vibemaestro-sdlc:install-gates` adds one.

## 1. Split and queue

- One task = one intent = one branch = one PR. Tasks that touch the same files, or wait on another's merge, run one after another;
  the others run in parallel.
- Two or more PRs: write the plan first (skill `plan`), one row per task; that table is the queue and survives a compaction.
  `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/kb.py" plan status <plan file>` reads where each row stands (branch, PR, merged).
  Keep in the conversation only which subagent (on `agents.worker_model`) holds which row, so you can resume it by name.

## 2. Start one task each

Each start is one Agent tool call with `model` set to the value of `agents.worker_model`, run in the background; independent tasks
go out in one message so they run at once. The brief is the subagent's first prompt, in this order:

1. *Contract:* "The brief is your contract: anything outside it, stop and report the question as your final
   message." What the main session will check: the head SHA you report, CI on it, the changed files.
2. *Why:* the person's words, verbatim, with the date; what was measured.
3. *What must be true:* numbered results, each with the command that proves it.
4. *Scope:* allowed paths, and the paths that are not allowed. Write the allowed globs to a file too (one per line): it is the
   `--brief <file>` of the merge in section 4.
5. *Flow:* run `vibemaestro-sdlc:intake` (its step 1 gives the task its own worktree under `.claude/worktrees/`; never edit the
   main tree), then `vibemaestro-sdlc:spec`, then end the turn with `SPEC ready: <spec path> on <branch>`. After approval: build,
   `vibemaestro-sdlc:ship` (draft PR), rule `before-ready`, then end with `PR #N ready: head <full sha>` and nothing after it.

## 3. While the tasks run

A subagent (on `agents.worker_model`) has no `session-ask` and cannot start another agent, so some steps come back to you:

- `SPEC ready …`: show the person the spec path and get their approval (silence is not approval), then resume that task with
  `SendMessage` and the person's words. A question outside the brief: answer it, or ask the person, the same way.
- **The fresh-context review** of rule `before-ready`: you start it, one Agent call on `agents.review_model`, pinned to the PR head,
  and send its findings to the subagent through `SendMessage`; the subagent answers with one fix commit.
- **A stop-list baton** (skill `batonrun`): the task never signs it; it reports the baton path and what it does, and you take it
  to the owner.
- **A brain write:** a subagent (on `agents.worker_model`) never writes brain (brain refuses it, rc 4); it lists the lines in its
  report and you run `brain op` from the main session.

## 4. Post-check and merge

For each `PR #N ready: head <sha>` (a claim until these agree):

1. `gh pr view N --json headRefOid,mergeable`: the head is the reported SHA; `CONFLICTING` gets no CI at all.
2. `gh pr checks N`: green on that head.
3. `gh pr diff N --name-only`: every file inside the brief's scope.

Then merge through BatonRun, never a bare `gh pr merge`:
`<launcher> go kit:merge-pr --repo <owner/name> --pr N --head <full sha> --brief <scope file>` (skill `batonrun`, `kits.md`).
After one merge, a parallel PR may be behind main or conflict on `kb/current-state.md`: resume its subagent (on
`agents.worker_model`) to merge main into its branch and report the new head; never push to its branch or update it from outside,
which moves the head and voids the evidence.
When the queue is empty, `kb.py plan status` shows every row merged.
