English | [Tiếng Việt](batonrun.vi.md)

# BatonRun research: what a run costs

BatonRun runs every write outside the session as one checked, rehearsed, signed and post-checked baton script
(see [BatonRun](../../plugins/vibemaestro-sdlc/docs/batonrun.md)). This page states what that costs in model tokens compared with plain tool calls, how it
was measured, what using it has shown, and what the measurements do not show.

## Findings

- **Per write, BatonRun is at parity with plain tool calls.** With `baton go` and the kit batons, a baton adds −1 to 0
  main-session turns over plain tool calls, the one-time skill read excluded. The plain arm's own turns vary by ±1 or more,
  so this is parity, not a saving.
- **The machine checks cost almost nothing; model turns do.** Running the phases as separate commands (`new`, `check`,
  `rehearse`, `sign`, `run`, `log`) costs about 3.5 times plain tool calls on both task sizes, from about 6–7 extra model
  turns per task. That is why `baton go` runs check to log as one command and prints one line.
- **What is left is once per session.** Reading the skill takes 2–3 turns: about 41k–62k cost units at a 413k-token
  context, 18k–33k characters.
- **Delegating runs to one worker subagent does not pay by default.** Once the skill is read, running batons in the main
  session is cheaper. A worker helps only on a session's first multi-baton task, or to keep a large main context small.
- **Correctness holds within what the check covers.** An independent check found every object correct in every run. When a
  baton failed, the cause was a bug in the agent's own script; the baton stopped or ended with exit 5, and no wrong state was
  left.

## Method

**Tasks.** Each task runs in a scratch repository under its own name prefix; `main` is not touched.

| Task | What the agent does | Objects |
|---|---|---|
| C (complex) | 4 labels; a milestone due in about 7 days; a branch from `main` with 3 one-line files as 3 commits; a tag on the branch head; a draft release that lists the files; verify every object and property | 8 |
| S (simple) | one label; verify it | 1 |

**Arms.** One method clause in an otherwise identical prompt sets the arm.

| Arm | Method |
|---|---|
| D | Plain tool calls. "Do not write a baton script and do not use BatonRun." |
| B | Every write through one baton with separate commands: `new`, `check`, `rehearse`, `sign`, `run`, `log`. |
| B′ | Every write through BatonRun with `baton go` (one command from check to log), and a kit baton where one covers the write. |
| B‴ | The main agent hands the whole baton job to one worker subagent, waits once, and checks the log lines. |

**Runs.** Every run is a fresh `general-purpose` subagent on Opus, one at a time, with the arms alternating. Headless
`claude -p` is not possible in the test environment, because no credential reaches a child process. Each run's objects are
deleted after the run, outside the measurement.

**What is counted.**

- *Turns:* distinct assistant message ids in the run's transcript.
- *Cost units:* tokens weighted by price, in units of the Opus base input price: cache read ×0.05, 5-minute cache write
  ×1.25, 1-hour cache write ×2, uncached input ×1, output ×5. A subagent is priced at its own model's rates in the same units.
- *Duration:* the harness figure for the subagent.
- *Correctness:* after each run, a separate read-only check (not the run's own claim) looks for every object and property. It
  is tested first on a positive control (all objects found) and a negative control (none found).

**Projection to a long session.** A subagent starts at about 20k tokens of context; a long-running session averages about
413k tokens per call. The difference is projected to that context as `extra turns × 413,000 × 0.05 + output difference × 5`.
One extra turn at 413k costs 20,650 units (cache read only).

## What using it has shown

- **Permission rules.** Without allow rules, Claude Code's auto-mode classifier blocks baton scripts that run a remote shell.
  Rules that name a versioned plugin path break on every plugin update, and path rules match on `Edit(path)`, not
  `Write(path)`. So `baton.py permissions` prints and checks rules that name a stable launcher (`--install-launcher`).
- **The bare launcher.** Allow rules match only the bare launcher command: `cd <dir> && <launcher> go … | grep …` matches no
  rule, and the classifier denies it. The hook warns on a launcher command with a pipe, `&&`, `;` or a redirect, and `run`
  prints one line on success.
- **`go -` with a heredoc.** The allow rule `Bash(<launcher> go:*)` matches `go -`, but a built-in check of Claude Code
  denies a heredoc whose body holds the skeleton's brace groups with quotes ("Contains brace with quote character"), before
  any rule. A hand-written baton is therefore a Write to a fresh path, then `go <path>`.
- **A background process in a write.** `(cd "$V" && … nohup node … &)` makes `baton run` hang after every write has run: the
  `&` binds to the whole list, so a forked copy of the script holds baton's output pipe open. `check` does not warn about it;
  keep background processes out of a baton's writes.
- **A used signature.** A second `run` on a used signature is refused with exit 3, and nothing runs: one signature, one run.

## What the measurements do not show

- **One documentation turn per session is not reached.** The one-time read takes 2–3 turns. A likely cause, the task
  prompt's wording on undo and stop items, is not checked.
- **Context per write stays above plain calls.** The bound "plain-call characters + 10%" is not met.
- **"Every baton ok on its first `go`" is not stable:** 9 or 10 of 10, depending on the run set.
- **Small samples.** n = 2 or 3 per arm and task, one scratch repository, one main model, one operator. The plain arm's own
  turns on task C range from 5 to 12, so a difference of one turn is noise.
- **Instrument limits.** The runs are subagents, not headless sessions; their effort level is not checked; output tokens are
  a lower bound. The 413k projection assumes that turn counts measured at about 14–90k of context hold at 413k, which is not
  checked, and it prices only the cache read of an extra turn.
- **No break-even curve.** Two task sizes give a sign, not a slope.
- **One lint exemption is not measured:** deleting only objects that the same baton created.
