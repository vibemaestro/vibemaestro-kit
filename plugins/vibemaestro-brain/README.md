English | [Tiếng Việt](README.vi.md)

# vibemaestro-brain

A second brain for long-running Claude Code sessions. It keeps the decisions, delegation windows, current task, next steps and traps of a session in a small log outside the repository, and puts that log back into the context after every compaction.

- [The problem](#the-problem)
- [How it works](#how-it-works)
- [Install](#install)
- [Quick start](#quick-start)
- [Hooks](#hooks)
- [Commands](#commands)
- [Skills](#skills)
- [Cost model](#cost-model)
- [Levels](#levels)
- [What the exit test showed](#what-the-exit-test-showed)
- [Configuration](#configuration)
- [Dependency on vibemaestro-sdlc](#dependency-on-vibemaestro-sdlc)
- [Requirements](#requirements)
- [Limits](#limits)

## The problem

A Claude Code session can run for hours or days. Claude Code compacts its context when it fills up, and the summary that replaces the conversation keeps what the model judges important. A decision the owner stated in one sentence, a permission window ("merge freely until 22:00") or a trap the session already fell into can drop out of that summary. After the compaction the session acts as if it never heard them.

The brain stores those facts in a form that does not depend on the summary. A `SessionStart` hook re-injects them at every session start, and Claude Code fires `SessionStart` with the source `compact` after every compaction.

## How it works

The brain holds *hot memory*: a few short items of five kinds.

| Kind | Letter | What it is | Live items at most |
|---|---|---|---|
| Pinned decision | `D` | a decision the owner stated, with the owner's words | 10 |
| Window | `W` | something the owner allowed without asking, until a time | 5 |
| Now | `N` | the task in hand | 3 |
| Next | `X` | the next steps | 5 |
| Trap | `T` | a mistake to avoid, counted each time it recurs | 4 |

Each text is at most 150 characters. The rendered block (`brain render`) stays at or under 6,000 characters.

The store follows these rules:

- **One op log is the truth.** `hot.jsonl` holds one operation per line. Each line carries the SHA-256 of the line before it, and `head.json` holds the tail. Every write first checks the whole chain and the head. A log that was cut or edited by hand stops all writes (rc 5).
- **Item operations only.** The operations are `add`, `close`, `supersede`, `touch` and `hit`. There is no edit, replace or import. A supersede keeps both items, carries every anchor over, and keeps at least 60% of the first text of its chain unless you pass `--shorter` with a reason.
- **A retirement budget.** `brain op close` and `brain op supersede` are refused once the session has retired 5 items in the last 30 minutes (owner retirements count too). A deliberate sweep passes `--bulk`, and the log records it.
- **Anchors.** An item can carry anchors: exact strings a summary must keep, such as a PR number, a 7-hex SHA, a path or a code word. After each compaction the brain logs a *loss score*: the share of the live items' anchors that the summary dropped.
- **Owner items go through the permission dialog.** Only the owner can create or change a `D` or `W` item. The command is `brain owner …`, and it writes only after the owner approves a one-line Claude Code permission dialog, for example `Pin owner decision D3, from "<where>": "<text>"`. With no approved dialog the command stops with rc 6. A model alone cannot write an owner item. The dialog is unavailable in `dontAsk`, `plan` and `bypassPermissions` modes, in a `-p` run, in a subagent, and while a `PermissionRequest` hook or a `--permission-prompt-tool` could answer in place of a person. In those cases the session tells the owner instead of trying another way.
- **No secrets.** Every text passes through the sensitive-value filter of vibemaestro-sdlc (`gates/pr_sensitive.py --text`). A hit, or a missing filter, refuses the write. The brain also refuses control and format characters, characters that render as nothing, and blank text.
- **One writer.** The first session that writes owns the project's brain. Another session needs `brain claim --take-over`, which the log records. A worker session (one with both `INTENT_SLUG` and `SEAT` set, as a tool that starts sessions for you may set them) never writes (rc 4).

The brain guards against slips, not against forgery by the same user: it does not defend against someone who deliberately edits files as the same account.

State lives outside the repository, one directory per repository (see [Configuration](#configuration)).

## Install

Add the `vibemaestro` marketplace as the [kit README](../../README.md) describes, then:

```bash
claude plugin install vibemaestro-brain@vibemaestro
```

The install brings `vibemaestro-sdlc` as a dependency. Read `claude plugin list` to confirm both are enabled: `claude plugin install` exits 0 even when a dependency is missing or too old. While the plugin is enabled, `bin/brain` is on the `PATH` of the Bash tool, so `brain …` works in a session.

## Quick start

The commands below run inside a Claude Code session, which sets `CLAUDE_CODE_SESSION_ID`. Outside a session, writes stop with rc 7. You usually do not type them: Claude runs them, guided by the `brain` skill.

```bash
brain doctor --path                    # print this project's state directory
brain claim                            # take the writer role (the first write also claims it)
brain op add --kind now --text "Write the README" --anchor README.md
brain op add --kind next --text "Run every command"
brain op add --kind trap --text "Never hand-edit the state directory"
brain render --check                   # size and counts against the caps
brain doctor                           # chain, caches, filter, file modes
brain matrix                           # what the brain holds, cell by cell
```

`brain render --check` prints, for example:

```text
hot memory render: 320 of 6,000 characters
  Pinned (owner): 0 of 10
  Windows: 0 of 5
  Now: 1 of 3
  Next: 1 of 5
  Traps: 1 of 4
```

`brain render` prints the block that the hook injects:

```text
## Brain · hot memory v4 · 320/6,000 chars   (re-injected after compaction; change only with `brain op` or `brain owner`)
Pinned (owner)
Windows
Now
- N1 Write the README · since 10-19
Next
- X1 Run every command · since 10-19
Traps
- T1 Never hand-edit the state directory · since 10-19 (hits 0)
Matrix: `brain matrix`
```

Retire items as the work moves on:

```bash
brain op touch N1                                      # still current
brain op hit T1                                        # a trap was met again (traps only)
brain op close N1 --reason done --pointer README.md    # done or dropped
brain op supersede X1 --text "Run every command in a scratch project" --reason widened
```

An owner item needs the dialog, so the same command from a script is refused:

```bash
brain owner add --kind decision --text "Ship the release as is" --owner-quote "ship it" --where "chat"
# brain: owner items need a session that can show Claude Code's permission dialog; …   (rc 6)
```

## Hooks

`hooks/hooks.json` registers these hooks.

| Event | What it does |
|---|---|
| `SessionStart` (every source: startup, resume, clear, compact, fork) | Injects one block: hot memory, then the Shelf index (the skills Claude can invoke, at most 1,000 characters). The block is at most 8,000 characters; a longer block is cut at whole lines and the cut is named. |
| `PreCompact` | Logs the trigger and the context size, read from the tail of the transcript. Adds the API calls since the last saved byte offset to the session's running cost sums. It never blocks the compaction. |
| `PostCompact` | Saves the summary to `summaries/` (mode 0600, never injected, the newest 200 kept) and logs the loss score. |
| `SessionEnd` | Deletes the session's pending dialog records, logs the end, and appends a `cost` line from the saved sums. A session that never compacted gets no `cost` line: the transcript is not read here. |
| `PreToolUse` on Bash, `brain op …` | Denies a hot-memory write from a subagent. |
| `PreToolUse` on Bash, every call | `guard-owner`: for a `brain owner …` command, asks the owner with the dialog line, or denies. On any other command it gives no decision. |
| `PreToolUse` on Edit, Write, NotebookEdit | Denies an edit under the brain's state root. |

When `guard-owner` denies, it names the reason: a subagent, a command that is not literal (write one `brain owner …` command alone in its Bash call, with no variable, substitution, backslash, glob, `~` or redirect), a mode with no dialog, or an answerer such as a `PermissionRequest` hook.

All hooks are silent when `BRAIN_OFF` is set (other than empty or `0`) and in a worker session. The first three are also silent in a project with no hot memory yet, and `SessionEnd` writes nothing when the project has no state directory. Hooks fail open: an error is one line on stderr and never blocks the session.

The Episode Log, `episodes.jsonl`, holds one line per session start, owner call, session end and cost, and two per compaction (a `pre-compact` line and a `compact` line). `templates/compact-instructions.md` is a `# Compact instructions` block you can paste into a project `CLAUDE.md` so that the summary itself keeps owner decisions, windows, open PRs, sessions, timers and the current task. You place it by hand.

## Commands

`bin/brain` runs `scripts/brain.py`. Every command prints `brain: …` on stderr when it stops.

| Command | What it does | Exit code |
|---|---|---|
| `brain op add --kind now\|next\|trap --text T [--link L]… [--anchor A]… [--expires ISO]` | Adds a Now, Next or Trap item. | 0; 1 refused; 3 not the writer; 4 worker; 5 log broken |
| `brain op close ID --reason R [--pointer P] [--bulk]` | Closes an item as done or dropped. | as above |
| `brain op supersede ID --text T --reason R [--drop-anchor A]… [--anchor A]… [--shorter] [--bulk]` | Replaces an item with a new one; keeps both in the log. | as above |
| `brain op touch ID` | Marks an item still current. | as above |
| `brain op hit ID` | Counts a trap met again (traps only). | as above |
| `brain owner add --kind decision\|window --text T --owner-quote Q --where W [--anchor A]… [--link L]… [--expires ISO]` | Pins an owner decision, or grants a window (a window needs `--expires`, a time in the future). | 0; 6 no approved dialog; otherwise as above |
| `brain owner unpin ID` | Retires an owner item. | as above |
| `brain owner supersede ID --text T` | Replaces an owner item. | as above |
| `brain owner promote ID POINTER` | Moves an owner item out of hot memory to a pointer (a decision file, for example). | as above |
| `brain claim [--take-over]` | Takes the writer role; `--take-over` takes it from another session, and the log records it. | 0; 3 another writer or no session id; 4 worker |
| `brain render [--check]` | Prints the hot-memory block; `--check` prints sizes and counts instead. | 0; 1 over the cap or no state yet; 5 log broken |
| `brain doctor [--path]` | Checks the chain, head, caches, file modes, the filter, the answerers and the Claude Code version; `--path` prints the state directory. | 0; 1 a problem, each named |
| `brain matrix [--json]` | Prints the Brain Matrix. See [Cost model](#cost-model). | 0 |
| `brain cost TRANSCRIPT [--merge-log F] [--json]` | Prices a transcript's token usage. See [Cost model](#cost-model). | 0; 2 cannot read |

Any command exits 64 on a usage error and 70 on an internal error (named, never a traceback). `brain op` never touches a `D` or `W` item, and a `close` or `supersede` applies to `N`, `X` and `T` items only.

`brain owner` is strict, because the permission dialog shows the same tokens the command runs with. Spell each option in full, give its value as the next argument (no `--opt=value`; a value may start with `-`), and give a single-value option once. A text, a source (`--where`) and a pointer may not contain a double quote. `--owner-quote` is the owner's words, verbatim; `--where` says where they were said.

When an op is logged but the caches cannot be rewritten, the op still stands (rc 0, with a warning) and the next read folds the log again.

## Skills

| Skill | Who invokes it | What it does |
|---|---|---|
| `brain` | Claude, when a session must keep a decision, window, task, next step or trap across compactions | Teaches the rules above: when to run `brain op`, how to write an owner item through the dialog, what each exit code means, how to re-claim after `/clear` or `--fork-session`. |
| `matrix` | You, as `/matrix` (the model does not invoke it) | Runs `brain matrix` and shows its output as it is. |

## Cost model

Two commands show where the tokens go.

**`brain cost TRANSCRIPT`** reads the `usage` fields of a Claude Code transcript (Claude Code keeps them under `~/.claude/projects/`) and prices them in *base-input tokens*, using these weights:

| Part | Weight |
|---|---|
| input | 1× |
| cache read | 0.05× |
| cache write | 2× (1-hour) or 1.25× (5-minute); 2× when the write has no TTL split |
| output | 5× |

It prints the split between read, write, output and input, the units in total, the mean and maximum context per call, and each gap over one hour with the cache re-write after it. With `--merge-log F` (the merge log of vibemaestro-sdlc: JSON lines with `result`, `time`, `repo` and `pr`) it also prints the units per merged PR in the transcript's time span. `--json` prints the same data as one JSON object. A transcript that cannot be read is rc 2.

It counts one call per `message.id`: Claude Code writes each content block of a response as its own record with the same `usage`, so a plain sum over records counts most calls twice. Sidechain (subagent) records and `<synthetic>` records are skipped, and the output counts them.

```text
$ brain cost t.jsonl --merge-log merge.jsonl
brain cost · t.jsonl · 3 calls (main thread); skipped: 0 sidechain, 0 <synthetic>, 0 unreadable lines
split at A's weights (input 1x, cache read 0.05x, cache write 2x 1h / 1.25x 5m, output 5x): read 1.1% · write 96.1% · output 2.8% · input 0.0%
units: 216,520 base-input tokens — read 2,500 · write 208,000 · output 6,000 · input 20
…
merged PRs in the span: 1 · units per merged PR 216,520
```

(The output says "A's weights": the weights above, taken from the baseline session that the cost measurements are compared against.)

**`brain matrix`** prints the Brain Matrix: seven rows, one per cell of Know/Do × hot/warm/cold (Do·warm has two rows: the Workbench, and code intelligence provided by external plugins). Each row gives the store, its size in characters (and ≈ tokens at 4 characters per token, not calibrated), when it is loaded, its forgetting rule, when it was last consolidated, whether it survives compaction, and warnings. Below the rows it reports what the brain did in this session: hook lines per event, characters injected, compactions with the last trigger and context size, the last loss score, the last `cost` line, and the `--bulk`, `--shorter` and `--drop-anchor` ops. The brain ships no code for code intelligence: that row only lists enabled plugins named `*-lsp`, plugins with `.lsp.json` or `lspServers`, and serena.

## Levels

The brain is built in levels. Each level ends with a test, and the next level starts after it.

| Level | Goal | State |
|---|---|---|
| Survive compaction | Re-inject pinned decisions after every compaction. | **Available**: store, hooks, skills, matrix, cost, probe. |
| Forget by itself | Expiry, closing by merged PR, eviction at caps, an Artifact Index of open PRs, a Sleep pass, a soft cross-check of owner quotes. | Not available yet. |
| Compact Pilot | Lower the cost per merged PR with a tuned compaction window and idle diagnosis. | Not available yet. |

## What the exit test showed

The exit test of the first level (three runs, one compaction and 10 pinned decisions in about 225k tokens of context) gave 10/10 with the brain and 10/10 for the control without it: the brain was not shown necessary at that size. A harder test, with several compactions in a row, has not been run.

The method, the numbers and the other measurements are in [docs/research/brain.md](../../docs/research/brain.md).

## Configuration

The brain has no settings file. It reads these environment variables.

| Variable | Effect |
|---|---|
| `BRAIN_OFF` | Any value other than empty or `0` silences every hook. Use it for a control run. |
| `XDG_STATE_HOME` | Root of the state directory; the default is `~/.local/state`. |
| `CLAUDE_CODE_SESSION_ID` | Set by Claude Code. The brain identifies the writer by it. |
| `CLAUDE_PROJECT_DIR` | Set by Claude Code. The hooks use it to find the project's skills and settings. |
| `INTENT_SLUG` and `SEAT` | When both are set, the session is a worker session: hooks are silent and writes stop with rc 4. |
| `HOME` | Where the default state directory and the user-level Claude Code settings are found. |
| `CLAUDE_CONFIG_DIR` | Claude Code's config directory (default `~/.claude`). The brain reads enabled plugins, skills and settings there, and finds the vibemaestro-sdlc filter through it. |
| `CLAUDE_CODE_EXECPATH` | Set by Claude Code. The `guard-owner` hook runs it with `--version` for the version check. |
| `CLAUDE_CODE_REMOTE` | Set by Claude Code. When it is `true`, `brain matrix` reports code intelligence as not started. |

`BRAIN_TEST`, `BRAIN_TEST_PAUSE_MS`, `BRAIN_TEST_ASK_MODES` and `BRAIN_TEST_SOURCES` exist for the plugin's own tests. Do not set them: `brain doctor` warns when `BRAIN_TEST` is set.

### Where state lives

`$XDG_STATE_HOME/vibemaestro/brain/<project>-<12 hex>/`, or `~/.local/state/vibemaestro/brain/…` when `XDG_STATE_HOME` is unset. There is one directory per repository, and all worktrees of a repository share it. Files have mode 0600. `brain doctor --path` prints the directory. The brain writes nothing into the repository.

| File | Holds |
|---|---|
| `hot.jsonl`, `head.json` | the op log and its tail hash |
| `hot.json`, `archive.jsonl`, `owner.json`, `hot.md` | caches and the render, rebuilt from the log |
| `asked/` | pending records of owner dialogs |
| `lock` | the file lock that every write takes |
| `episodes.jsonl` | the Episode Log |
| `summaries/` | saved compaction summaries (newest 200) |
| `cost/` | each session's running cost sums and byte offset |

One more directory, `pending/`, sits next to the project directories under `…/vibemaestro/brain/`: it holds one marker per session whose dialog record is waiting for its command.

Never edit these files. A guard denies the edit, and a hand change breaks the hash chain and stops every write.

## Dependency on vibemaestro-sdlc

`plugin.json` declares a dependency on `vibemaestro-sdlc`. The brain uses two things from it:

- **The sensitive-value filter**, `gates/pr_sensitive.py`. Every write passes through it. If the filter is missing, every write is refused, and `brain doctor` reports a problem.
- **The merge log**, which `brain cost --merge-log` reads to count merged PRs.

Claude Code does not load a plugin whose dependency is not enabled, so the brain's hooks run only when vibemaestro-sdlc is enabled too. The Matrix lists the repository index as a shared cell: vibemaestro-sdlc injects it when its `current_state.inject` option is on (off by default). See [vibemaestro-sdlc](../vibemaestro-sdlc/README.md).

## Requirements

- Claude Code. Owner items need version 2.1.211 or later when the session runs in `auto` mode; `brain doctor` checks this.
- `vibemaestro-sdlc`, installed with the brain.
- Python 3.8 or later and `git` on the `PATH`. The scripts use the standard library only.
- A POSIX system: the store takes `fcntl` file locks.

## Limits

- No recall and no automatic eviction: you or Claude retire items. Expired windows are shown as expired but not removed.
- The token column of the Matrix is characters ÷ 4, not a measured count.
- Whether the brain helps was not shown at the size of the first level's exit test; see [What the exit test showed](#what-the-exit-test-showed).
