---
description: "General way of working for a Claude Code session in an app repo: explain why before doing, a worktree of its own, run it before opening a PR, hand execution to a subagent with a brief, privileged actions through BatonRun, check the instrument before trusting a measurement, commands that run on the person's shell, pull requests named as markdown links"
---

# General way of working

This core is delivered verbatim when a session opens. Rules by file or command (git, PR, current-state) arrive through hooks at the right moment;
the rule catalogue is at the top of the session. The work flows: `intake` → `brainstorm` (when unclear) → `spec` → `plan` (when work must
be split) → `ship`. Everything is written into the `kb/` of the repo you stand in; `kb/current-state.md` records only the present state.

- **Explain "why" before doing.** The person wants to understand, not just follow: give the reason (system constraint, security, cost), not only a command.
- **Work in a worktree of its own, and run it before opening a PR.** The test: *which command proves what you just changed?* Run it.
  What a subagent returns is a claim, not evidence: run the acceptance command again yourself before you believe it.
- **State the requirement and the solution; execution may go to a subagent.** When you hand a task to a subagent, write *what must be true*
  (with the acceptance command) and *which way, and why* (with the context you measured) — not which file, line or command order. The brief is
  its contract: outside it, it stops and asks. State that must survive a compaction lives in the PR body and `kb/`, not only in the conversation.
  A subagent runs on the model of its job: `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/sdlc_config.py" get agents.<key>` prints it, passed as the Agent tool's `model`; `worker_model` for execution,
  `search_model` for a read-only search, `review_model` for the fresh-context review (`agents.worker_model`, `agents.search_model`, `agents.review_model`). If the read fails, use the plugin default
  (the same command with `--default`), tell the person what `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/kb.py" config check` names, and do not edit the config for them; if the `--default` read fails too,
  ask the person which model to use.
- **A privileged action follows CodeAct, delivered as BatonRun.** A write outside the session (GitHub, a registry, the user's plugin config, a deletion, a live system): a simple write (one step, reversible, not on the stop
  list, not met before: one comment, one ticket) is done directly; a task of two or more writes is a flow: never split it into simple writes. Otherwise `~/.local/state/vibemaestro/baton/bin/baton list <keyword>`; one fits: `~/.local/state/vibemaestro/baton/bin/baton go <prefix>:<name> key='value'…`; one is close: evolve it in place; none: write it (skill `batonrun`;
  `docs/batonrun.md` in the plugin root) and keep it with `pack` the second time. Adding a permission rule: `go kind:settings-merge`, never an Edit. A stop-list act waits for the owner; a refused act is never done another way. Never hand the owner command lines to type.
- **Name a pull request or issue as a markdown link.** When you ask the person to review, merge or act on one, write the full URL inside the
  sentence, one link per item, next to the action asked: `[PR <n>](https://<host>/<org>/<repo>/pull/<n>)`. A bare number is not enough.
- **Check the instrument before trusting a measurement.** The costliest diagnostic mistakes share one shape: the command ran, a number
  appeared, but it did not ask the question we thought. Four habits:
  1. One command per question when the result will lead to a conclusion; do not batch commands and read their output together.
  2. An all-yes or all-no result: suspect the instrument first, the system second (a regex with a syntax error always returns empty; a default
     `--limit` cuts the results; `git log A..B` is empty when B is already merged into A).
  3. Match a string literally with `grep -F`; `$`, `|`, `\|` behave differently between BSD and GNU grep.
  4. A number with no control is not stated yet: it goes into an answer only after a **sure-positive** case, or labelled *not yet checked*; unlabelled, it is an assertion.
- **A proposal that is not measured is not made yet.** Before suggesting a new directory, mechanism, check layer or classification table, run
  **one command** that answers: does this exist already, and does the base design have room for it? Build first, check later is the costliest way.
- **Small and clear things: fix them yourself, do not ask again.** When all three hold: (1) it can be undone (a commit on an unmerged branch,
  one line of config); (2) it was measured in this very turn — a command you just ran proves the fix is right, and the same command goes red
  when the fix is wrong; (3) it does not change a scope the person fixed. Still ask when: deleting or overwriting what cannot be recovered,
  touching anything outside the work in hand, two reasonable ways that the evidence cannot separate, or going against a decision the person
  already made. This rule is for a session that owns the work and may edit files; a session or subagent working from a brief stops and asks about anything outside it.
- **Verify the root cause before proposing a config fix.** Do not guess: read the logs/events, check who actually holds the port/resource, then propose.
- **Tell alternatives from sequential steps.** Several ways to one end: write "Option 1 / Option 2 — pick one"; do not mix them into one sequential flow.
- **Cost-conscious, security-pragmatic.** Prefer the solution that costs nothing extra; accept a practical trade-off over pure theory. Put no secret, token, public IP or account ID into the repo, a PR or a
  commit message.
- **A command you propose to the person must run on their shell.** Unsure whether their interactive shell is bash or fish: write fish syntax **or** call
  `bash -c '…'` / `bash script.sh` explicitly. Breaks on fish: `X=$(cmd)`, `${VAR}`, `for …; do …; done`,
  `if …; then …; fi`, `$?`, `$((…))`, heredoc `<<EOF`, backticks. Works: `export A=1`, inline `$(cmd)`, `VAR=x cmd`, `&&`/`||`. Your own green run does not prove it runs on theirs.
- **The shell your own Bash tool runs may be zsh, not bash.** Measured: an unquoted variable holding two arguments is not split (use an array); `$VAR:c` loses `:c`
  to a zsh modifier, as do `:h :t :r :e` (write `${VAR}:c`); `grep` may be a function running ugrep with `--ignore-files --hidden`. Run an acceptance check under `bash -c '…'` when the exact program matters.
