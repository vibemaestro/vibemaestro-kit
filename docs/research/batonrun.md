English | [Tiếng Việt](batonrun.vi.md)

# BatonRun research: what a run costs

BatonRun runs every write outside the session as one checked, rehearsed, signed and post-checked baton script
(see [BatonRun](../../plugins/vibemaestro-sdlc/docs/batonrun.md)). This page states what that costs in model tokens, measured two ways:
whole sessions that send every write through BatonRun against sessions with no plugin, and, inside one session with the
plugin loaded, a baton against plain tool calls. It covers how it was measured, what using it has shown, and what the
measurements do not show.

## Findings

### Whole sessions, against no plugin

- **Over an 18-task session, a session that sends every write through BatonRun costs about 3 to 3.7 times a session with
  no plugin, per correct write.** Over 18 tasks in one session the ratio is 3.05–3.67 over four pairs of sessions: about 43k–49k cost units per
  correct write against 13k–14k. On the first task in a fresh session it is 4.35 on a complex task and 3.39 on a simple one.
- **No break-even within 18 tasks.** The ratio of cost per write is about 3.5 on the first task, 3.9–4.0 on the next four,
  3.6 on the sixth, and 3.3–3.5 from the seventh task on. The cost per write falls in both arms over the first tasks and rises again with the
  tasks that hit a planted failure; a typical later task costs about 41k–43k units with BatonRun and 12k–13k without. The
  plugin's session context, about 12k–15k units per session, is a small part of a session's cost; the per-task part is what
  stays. Of the extra, cache reads are 42–47 %, output 32–36 % and cache writes 21–22 %; a session with BatonRun writes about
  4.4 to 4.9 times the output tokens and takes about 1.3 to 2.3 more turns per task.
- **Loading the plugin does not by itself make a session use BatonRun.** With the plugin loaded and a prompt that does not ask
  for BatonRun, none of five sessions reports a baton; such a session costs 1.41 times (complex task) and 2.06 times (simple
  task) a session with no plugin, mostly from the plugin's session context.
- **Correctness is the same in both arms.** Over the 18 main tasks, every write is correct in every session, except one that
  the BatonRun sessions leave undone because it needs the owner. No task leaves an unasked change in the lab's refs, tickets,
  settings or installed files; three undo tasks are correct; two tasks with a planted failure stop with nothing changed.
- **BatonRun gains no more from doing a kind of write a second time than a session with no plugin.** In three of four kinds
  the repeat drops less with BatonRun, and the session ranges do not overlap; branch push overlaps. Later over first, per session: a
  second ticket 0.43–0.45 with BatonRun and 0.39–0.40 without; a second file install 0.95–0.96 and 0.88–0.90; a second branch
  push 0.57–1.01 and 0.88–1.16; a second undo 0.89–1.02 and 0.71. Most batons are a new script; no run read uses `--reuse`, so reuse is not
  measured.

### Stops and the owner's signature

- **A session declares a stop for an act that cannot be undone, and nobody signs it.** Deleting a ticket that the tracker
  cannot restore, which no lint pattern covers, stops for the owner in both BatonRun sessions: the session declares
  `irreversible-delete` itself. Adding an allow rule through the settings-merge kit, whose kind declares the stop, stops for
  the owner in both. Without the permission rules, what keeps such a write from running is not an owner dialog (none opens) but
  the session not signing, or the auto-mode classifier denying its own `sign --by owner` (below).
- **The stop lint and the stop definition differ on a merged branch.** The `irreversible-delete` category covers unmerged
  branches. The lint, a backstop for a stop left out of the header, flags any `git push --delete` of a branch, merged or not,
  and does not match `git push … origin ":$REF"` with the refspec in quotes, or `git update-ref -d`. Asked to delete a merged
  branch whose commit stays in `main`, a BatonRun session declares no stop, writes an undo that recreates the branch, and the
  run goes ahead under the session's own signature in auto mode: that fits the definition, not the lint.
- **Without the permission rules, signing as the owner opens no dialog.** For a stop, the session runs `sign --by owner`, which
  is meant to open Claude Code's permission dialog for the owner; in auto mode only the `ask` rule from
  `baton.py permissions --print` opens it. Without that rule the command runs as a plain command: baton does not check that a
  person approved, and Claude Code's auto-mode classifier is the only guard (it denied both measured attempts).
  Apply the permission rules before relying on an owner signature.

### Inside one session with the plugin loaded

Subagent runs in one session where every arm has the plugin loaded, the skill is read once, and the prompt names the method.
They count main-session turns per write, not tokens: under those conditions a baton is at parity with plain calls. Against a
session with no plugin, a whole session with BatonRun takes about 1.3 to 2.3 more turns per task and about 4.4 to 4.9 times
the output.

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

### Whole sessions

**Tasks.** Two studies. The first gives one task to a fresh session: task C or S below. The second gives 20 tasks in
sequence to one session per arm, on a local lab that stands for GitHub: a bare git remote whose hook refuses some commits, a
ticket tool for issues and pull requests, and a project settings file. The tasks are tickets, branches, a merge, two file
installs, a tag, three undo tasks, two tasks with a planted failure (a refusing hook, a locked ticket) and, last, two stop
cases (an allow rule, the delete of a merged branch, which the stop lint flags when written as `git push --delete`). Those two are outside the main measure,
because a write left undone makes the arms' labs differ for every later task.

**Arms.**

| Arm | What the session has |
|---|---|
| BatonRun | the sdlc plugin and no other plugin; one line in the prompt: every write goes through BatonRun |
| Plugin loaded | the sdlc plugin and no other plugin; the prompt without that line (first study only) |
| No plugin | no plugin; the prompt without that line |

The sessions run without the baton launcher and the permission rules, which only the owner adds, so batons run as
`python3 <plugin>/scripts/baton.py`.

**Sessions.** Claude Code 2.1.290, Opus 5.5 at high effort, in a sandbox. First study: 2 to 6 sessions per arm and task.
Second study: two sessions per arm; both sessions of a pair get each task at the same moment. Nobody signs as the owner: a
write that needs the owner is skipped and reported.

**What is counted.**

- *Cost units:* as below, from each session's transcript, per task. Claude Code's own cost figure for each 20-task session
  is 4 USD per million units at these weights; the transcripts hold 80–87 % of those units, which puts the ratio about 4–9 %
  above the one from Claude Code's figure.
- *A correct write:* the lab's state before and after each task: the writes the task asks for, with any other change counted
  as left behind. An undo is checked against the state before the undone task.
- *Main measure (20 tasks):* cost units ÷ correct writes over the first 18 tasks. A task on which any session needed the
  owner is left out of every session.

### Inside one session

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
- **Whole sessions: small samples, one lab.** Two sessions per arm over 20 tasks, 2 to 6 per arm and task in the first
  study; one model at one effort; a local lab with no network latency or API limits, whose remote is a directory a session can
  write. Writes to GitHub through kit batons are not part of the 20-task study, and its task mix repeats each kind of write
  twice at most.
- **Whole sessions without the permission rules.** A user who applied `permissions --print` may see other prompts and costs.
  The prompts of the arms differ by the one line that asks for BatonRun.
- **Output at high effort includes thinking,** so how much of the output is baton scripts is not known.
- **Small samples inside one session.** n = 2 or 3 per arm and task, one scratch repository, one main model, one operator. The plain arm's own
  turns on task C range from 5 to 12, so a difference of one turn is noise.
- **Instrument limits.** The runs are subagents, not headless sessions; their effort level is not checked; output tokens are
  a lower bound. The 413k projection assumes that turn counts measured at about 14–90k of context hold at 413k, which is not
  checked, and it prices only the cache read of an extra turn.
- **No break-even curve inside one session.** Two task sizes give a sign, not a slope; the 20-task sessions give the curve.
- **One lint exemption is not measured:** deleting only objects that the same baton created.
