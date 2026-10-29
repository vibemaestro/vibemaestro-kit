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

The brain holds short items of eight kinds, in three parts.

| Part | Kind | Letter | What it is | Live items at most |
|---|---|---|---|---|
| hot memory | Pinned decision | `D` | a decision the owner stated, with the owner's words | 10 |
| hot memory | Window | `W` | something the owner allowed without asking, until a time | 5 |
| hot memory | Now | `N` | the task in hand | 3 |
| sessions | Session | `S` | a running session: its next step, with pointers (PR, intent, record) | 12 |
| sessions | Owner queue | `Q` | what waits on the owner | 5 |
| plan | Next | `X` | the next steps | 10 |
| plan | Trap | `T` | a mistake to avoid, counted each time it recurs | 13 |
| plan | Fact | `F` | a path or fact in use (`~/…` or relative to a plugin root) | 5 |

Each text is at most 150 characters, a session's 450. The plan part also shows **Done**: the Now, Next, session and queue items the log closed in the last 24 hours, newest first, at most 7 lines and then a count, each `- X5 owner/name#N <merge commit> · <text>` (the anchor and commit first, the text last, so a long text is what the line loses). Nothing writes Done: it is read from the log. Under each pinned decision, one line shows the owner's words, `  "<quote, at most 120 characters>" · <where, at most 30>`.

**Three strings, each under Claude Code's cap.** Claude Code passes one hook command's string to the model whole up to 10,000 characters, counted in UTF-16 units (an emoji counts 2), and replaces a longer one by a short preview. So each part is its own `SessionStart` command, and each string stays under that cap by construction, never by the replacement:

| String | Holds | At most |
|---|---|---|
| `# vibemaestro-brain` | hot memory (its render at most 6,000 characters) and the Shelf index | 8,000 |
| `## Brain · sessions` | sessions and the owner queue | 9,500 |
| `## Brain · plan` | Next, Traps, Done and Facts | 9,500 |

Each limit is a hard cut at whole lines that names what it cut; at the caps above, with every line full and every note, no string reaches it. A string with nothing to show (its sections empty, no note) is left out. Claude Code runs a plugin's commands of one event in parallel, so the first string's command reads the log, looks up the anchors and renders all three once, and hands the other two their strings; each takes its own once.

The store follows these rules:

- **One op log is the truth.** `hot.jsonl` holds one operation per line. Each line carries the SHA-256 of the line before it, and `head.json` holds the tail. Every write first checks the whole chain and the head. A log that was cut or edited by hand stops all writes (rc 5).
- **Item operations only.** The operations are `add`, `close`, `supersede`, `touch` and `hit`, and one the brain writes itself, `link-close`: a Now, Next, session or queue item closes when the issue or PR it names with `--closes` is done (see [Auto-close](#auto-close)). There is no edit, replace or import. A supersede keeps both items, carries every anchor over, and keeps at least 60% of the first text of its chain unless you pass `--shorter` with a reason.
- **A retirement budget.** `brain op close` and `brain op supersede` are refused once the session has retired 5 items in the last 30 minutes (owner retirements count too). A deliberate sweep passes `--bulk`, and the log records it. A session or queue item is status, not a decision: its supersede (a new next step) spends no budget and may be shorter than 60%.
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
brain op add --kind session --text "docs-run: README review, then the PR"
brain render --check                   # sizes and counts against the caps
brain doctor                           # chain, caches, filter, file modes
brain matrix                           # what the brain holds, cell by cell
```

`brain render --check` prints, for example:

```text
hot memory render: 208 of 6,000 characters
  Pinned (owner): 0 of 10
  Windows: 0 of 5
  Now: 1 of 3
sessions render: 180 of 9,500 characters
  Sessions: 1 of 12
  Owner queue: 0 of 5
plan render: 246 of 9,500 characters
  Next: 1 of 10
  Traps: 1 of 13
  Done (24 h): 0
  Facts: 0 of 5
```

`brain render` prints the three parts that the hooks inject:

```text
## Brain · hot memory v5 · 208/6,000 chars   (re-injected after compaction; change only with `brain op` or `brain owner`)
Pinned (owner)
Windows
Now
- N1 Write the README · since 10-19
Matrix: `brain matrix`

## Brain · sessions v5 · 180/9,500 chars   (re-injected after compaction; change only with `brain op`)
Sessions
- S1 docs-run: README review, then the PR · since 10-19
Owner queue

## Brain · plan v5 · 246/9,500 chars   (re-injected after compaction; change only with `brain op`; Done is derived)
Next
- X1 Run every command · since 10-19
Traps
- T1 Never hand-edit the state directory · since 10-19 (hits 0)
Done (24 h)
Facts
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
| `SessionStart` (every source: startup, resume, clear, compact, fork) | Three commands inject the three strings (see [How it works](#how-it-works)): hot memory, then the Shelf index (the skills Claude can invoke, at most 1,000 characters), at most 8,000 characters; sessions and plan, at most 9,500 each, left out when empty. A longer string is cut at whole lines and the cut is named. A live Now, Next, session, queue or pinned item whose anchor names a closed issue or a merged or closed PR gets a `stale:` mark (see [Stale anchors](#stale-anchors)). For the project's writer, an item whose `closes` anchors are all done is closed first, and one note line in its string says so (see [Auto-close](#auto-close)). |
| `PreCompact` | Logs the trigger and the context size, read from the tail of the transcript. Adds the API calls since the last saved byte offset to the session's running cost sums. It never blocks the compaction. |
| `PostCompact` | Saves the summary to `summaries/` (mode 0600, never injected, the newest 200 kept) and logs the loss score. |
| `SessionEnd` | Deletes the session's pending dialog records, logs the end, and appends a `cost` line from the saved sums. A session that never compacted gets no `cost` line: the transcript is not read here. |
| `PreToolUse` on Bash, `brain op …` | Denies a hot-memory write from a subagent. |
| `PreToolUse` on Bash, every call | `guard-owner`: for a command that starts with `brain owner` (`brain` on the `PATH`, a path to `bin/brain`, or `python3` running `scripts/brain.py`), asks the owner with the dialog line, or denies. On any other command it gives no decision, including one that only mentions the words: a here-document body, a quoted string, an `echo` or a `grep`. |
| `PreToolUse` on Edit, Write, NotebookEdit | Denies an edit under the brain's state root. |

When `guard-owner` denies, it names the reason: a subagent, a command that is not literal (write one `brain owner …` command alone in its Bash call, with no variable, substitution, backslash, glob, `~` or redirect), a mode with no dialog, or an answerer such as a `PermissionRequest` hook.

All hooks are silent when `BRAIN_OFF` is set (other than empty or `0`) and in a worker session. The first three are also silent in a project with no hot memory yet, and `SessionEnd` writes nothing when the project has no state directory. Hooks fail open: an error is one line on stderr and never blocks the session.

The Episode Log, `episodes.jsonl`, holds one line per session start, owner call, session end, cost and auto-close, and two per compaction (a `pre-compact` line and a `compact` line). `templates/compact-instructions.md` is a `# Compact instructions` block you can paste into a project `CLAUDE.md` so that the summary itself keeps owner decisions, windows, open PRs, sessions, timers and the current task. You place it by hand.

## Commands

`bin/brain` runs `scripts/brain.py`. Every command prints `brain: …` on stderr when it stops.

| Command | What it does | Exit code |
|---|---|---|
| `brain op add --kind now\|next\|trap\|session\|queue\|fact --text T [--link L]… [--anchor A]… [--closes A]… [--expires ISO]` | Adds an item of that kind; `--closes` (Now, Next, session and queue only, at most 2) names the issue or PR whose close means the item is done. | 0; 1 refused; 3 not the writer; 4 worker; 5 log broken |
| `brain op close ID --reason R [--pointer P] [--bulk]` | Closes an item as done or dropped. | as above |
| `brain op supersede ID --text T --reason R [--drop-anchor A]… [--anchor A]… [--closes A]… [--shorter] [--bulk]` | Replaces an item with a new one; keeps both in the log. The new item carries the old one's `closes` unless `--closes` names its own. | as above |
| `brain op close-linked` | Closes every item whose `closes` anchors are all done, from fresh lookups, with no cap of 5 at once. Prints what it closed and what it skipped, with why. | as above; 1 `gh` not found |
| `brain op touch ID` | Marks an item still current. | as above |
| `brain op hit ID` | Counts a trap met again (traps only). | as above |
| `brain owner add --kind decision\|window --text T --owner-quote Q --where W [--anchor A]… [--link L]… [--expires ISO]` | Pins an owner decision, or grants a window (a window needs `--expires`, a time in the future). | 0; 6 no approved dialog; otherwise as above |
| `brain owner unpin ID` | Retires an owner item. | as above |
| `brain owner supersede ID --text T` | Replaces an owner item. | as above |
| `brain owner promote ID POINTER` | Moves an owner item out of hot memory to a pointer (a decision file, for example). | as above |
| `brain claim [--take-over]` | Takes the writer role; `--take-over` takes it from another session, and the log records it. | 0; 3 another writer or no session id; 4 worker |
| `brain render [--check]` | Prints the three parts; `--check` prints each part's size against its cap and each section's count instead. | 0; 1 over a cap or no state yet; 5 log broken |
| `brain doctor [--path]` | Checks the chain, head, caches, file modes, the filter, the answerers and the Claude Code version, lists every item closed in the last 24 hours (Done shows 7), and looks up the anchors of live items (a `warn` per stale one, and what auto-close would do or did); `--path` prints the state directory. | 0; 1 a problem, each named |
| `brain matrix [--json]` | Prints the Brain Matrix. See [Cost model](#cost-model). | 0 |
| `brain cost TRANSCRIPT [--merge-log F] [--json]` | Prices a transcript's token usage. See [Cost model](#cost-model). | 0; 2 cannot read |

Any command exits 64 on a usage error and 70 on an internal error (named, never a traceback). `brain op` never touches a `D` or `W` item: a `close` or `supersede` applies to `N`, `X`, `T`, `S`, `Q` and `F` items only.

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

## Stale anchors

An anchor is the exact string a summary must keep (`--anchor`). When a live Now, Next, session, queue or pinned-decision item has an anchor that is a closed issue, a merged PR or a closed PR, the brain says so and leaves the item alone: only the writer closes or supersedes it, with `brain op` (a pinned decision: the owner, with `brain owner`). The one exception is an item's own `closes` anchors (see [Auto-close](#auto-close)). The lookups use `gh` with its own login, always on `github.com` (`--hostname github.com`).

- **Which anchors.** Only a whole anchor in one of three forms:
  - `owner/name#N`, checked as written;
  - a GitHub issue or PR URL, `https://github.com/owner/name/issues/N` or `https://github.com/owner/name/pull/N` (nothing after the number), checked as the same `owner/name#N`;
  - a bare `#N`, checked in the repository named by `BRAIN_DEFAULT_REPO`.

  The first two need no setting, so they are the forms for a session that works across several repositories. Any other anchor, and any number in an item's text, is ignored. Traps, windows and facts are not checked.
- **Writing a bare anchor.** `brain op add`, `brain op supersede`, `brain owner add` and `brain owner supersede` print one `warning:` line after their usual message when the Now, Next, session, queue or pinned-decision item they write carries a bare `#N` and `BRAIN_DEFAULT_REPO` is unset or not `owner/name`. The line names each bare anchor and the form to write instead. It never refuses: the item is written and the exit code is 0. A supersede names the bare anchors it carries over (replace one with `--drop-anchor '#N' --anchor owner/name#N`).
- **`brain doctor`** looks every such anchor up on GitHub with `gh api` and prints one `warn` line per stale anchor (`stale anchor: X5 #7 (owner/name#N) closed <date>`; `merged` for a merged PR, `closed unmerged` for a PR closed without a merge, `closed not planned` for an issue closed as not planned). A pinned decision's line adds the command the owner runs (`owner retires it: brain owner unpin D3, or brain owner supersede D3 --text …`). It does not read or write the cache, and a `warn` does not change its exit code. For the live items whose anchors it cannot check (a bare `#N` with no usable `BRAIN_DEFAULT_REPO`), it prints a count and one `info` line per item and anchor (`not checked: X3 #7`), at most 20, then `not checked: +K more anchors`.
- **`SessionStart`** adds ` · stale: #7 closed 2026-10-20` after the item's line, in the injected strings only (not in `hot.md` or `brain render`), and one `stale-anchor check:` note line in the first string when `gh` is missing, a lookup failed or timed out, bare anchors were skipped because `BRAIN_DEFAULT_REPO` is not set, or not every anchor has an answer yet. Marks and notes together stay within 450 characters per string.
- **Fast and offline-safe.** Answers are cached in `stale-cache.json` in the state directory (600 seconds; a failed lookup 120 seconds). At most 12 lookups run per `SessionStart`, the least recently checked anchors first, in parallel under one 2-second deadline, then are killed; so every anchor is reached within a few session starts. No `gh` or no network means no marks and one note line, never a failure.

## Auto-close

A Now, Next, session or queue item can name the issue or PR whose close means *this item is done*, with `--closes` (at most 2, each `owner/name#N` or a GitHub issue or PR URL; a bare `#N` is refused, even with `BRAIN_DEFAULT_REPO`). Name the item's own work, never a dependency it waits on and never a tracking issue of several PRs. A `closes` anchor is also an anchor, so it counts toward the 8 and is marked like the others.

- **At write time** the anchor is looked up once (2 seconds): the command prints its state and title (the title is not stored), and refuses (rc 1) an anchor GitHub does not know and a new one already merged or completed, since that item could only be marked, never closed. A supersede that keeps an anchor its item already names (carried over, or named again) warns instead when it is done: the new item may close at the next session start, and `--drop-anchor` keeps it live. With no answer (offline, no `gh`) the write goes through with `closes not checked: owner/name#N`.
- **At `SessionStart`**, in the session that writes the project's brain (the last `brain claim`), an item closes when every one of its `closes` anchors is done after the item that named it was written: a PR merged into its repository's default branch (a second lookup, `…/pulls/N`, checks the base), or an issue closed as completed by a lookup made in that very session start (a cached issue answer never closes, since an issue can be reopened). The op is `link-close`, with a reason, a pointer and each anchor's state, time and merge commit; it does not count toward the retirement budget. The string that held the item shows one note line, `auto-closed now: X5 (owner/name#N merged <month-day>)`, once, and the item moves to Done.
- **Never closed:** a PR closed unmerged or merged into another branch, an issue closed as not planned, as a duplicate or with no reason, an open anchor, a lookup that failed or timed out, and any item of another session's start. These keep their stale mark. A pinned decision, a window, a trap or a fact never closes: a pin whose anchor is done is marked `owner retires it`.
- **A burst is held.** When more than 5 items would close at once, none does: they are marked, and the note says `auto-close held: N items at once; check brain doctor, then brain op close-linked`. `brain op close-linked` makes the same checks with fresh lookups (20 seconds, at most 40 anchors) and closes every item that passes.
- **Reopened issues.** For 24 hours after a close, the issue anchors of the closed item are looked up again now and then (at most 3 per session start). One that is open again adds `reopened: X5 owner/name#N, re-add it with brain op add` to the note line; there is no reopen op.
- **`brain doctor`** writes nothing; it prints `would close:` for an item the next session start would close, `auto-closed:` for each close of the last 24 hours, and the reopened lines.
- **Updating.** Restart every session of a project on this version before an item closes by a link or a session, queue or fact item is written: an older brain refuses to write to a log that holds a `link-close` or one of those kinds, and stops injecting hot memory whenever it has to read that log again. `brain doctor` warns about a session whose last start ran an older brain. Going back to an older version is not supported once one is written.

## Configuration

The brain has no settings file. It reads these environment variables.

| Variable | Effect |
|---|---|
| `BRAIN_OFF` | Any value other than empty or `0` silences every hook. Use it for a control run. |
| `XDG_STATE_HOME` | Root of the state directory; the default is `~/.local/state`. |
| `BRAIN_DEFAULT_REPO` | `owner/name`: the repository a bare `#N` anchor refers to; an `owner/name#N` anchor or an issue or PR URL does not need it (see [Stale anchors](#stale-anchors)). Set it per project in the `env` block of `.claude/settings.json`. |
| `CLAUDE_CODE_SESSION_ID` | Set by Claude Code. The brain identifies the writer by it, and the CLI finds the session's project by it. |
| `CLAUDE_PROJECT_DIR` | Set by Claude Code for the hooks. It names the session's project, and the hooks use it to find the project's skills and settings. |
| `INTENT_SLUG` and `SEAT` | When both are set, the session is a worker session: hooks are silent and writes stop with rc 4. |
| `HOME` | Where the default state directory and the user-level Claude Code settings are found. |
| `CLAUDE_CONFIG_DIR` | Claude Code's config directory (default `~/.claude`). The brain reads enabled plugins, skills and settings there, and finds the vibemaestro-sdlc filter through it. |
| `CLAUDE_CODE_EXECPATH` | Set by Claude Code. The `guard-owner` hook runs it with `--version` for the version check. |
| `CLAUDE_CODE_REMOTE` | Set by Claude Code. When it is `true`, `brain matrix` reports code intelligence as not started. |

`BRAIN_TEST`, `BRAIN_TEST_PAUSE_MS`, `BRAIN_TEST_ASK_MODES` and `BRAIN_TEST_SOURCES` exist for the plugin's own tests. Do not set them: `brain doctor` warns when `BRAIN_TEST` is set.

### Where state lives

`$XDG_STATE_HOME/vibemaestro/brain/<project>-<12 hex>/`, or `~/.local/state/vibemaestro/brain/…` when `XDG_STATE_HOME` is unset. There is one directory per repository, and all worktrees of a repository share it. Files have mode 0600. `brain doctor --path` prints the directory. The brain writes nothing into the repository.

A session keeps one project, the directory it started in, wherever its shell moves with `cd`. The hooks read it from `CLAUDE_PROJECT_DIR` and record it under the session id; `brain`, run from the session's Bash, reads that record. When the shell is in another project, `brain` still uses the session's project and prints one line naming both. A record it cannot trust is refused (rc 1), and nothing is read or written. Outside a Claude Code session, or before any hook has run, the project is the one the current directory belongs to.

| File | Holds |
|---|---|
| `hot.jsonl`, `head.json` | the op log and its tail hash |
| `hot.json`, `archive.jsonl`, `owner.json`, `hot.md` | caches and the render, rebuilt from the log |
| `asked/` | pending records of owner dialogs |
| `lock` | the file lock that every write takes |
| `episodes.jsonl` | the Episode Log |
| `summaries/` | saved compaction summaries (newest 200) |
| `cost/` | each session's running cost sums and byte offset |

Two more directories sit next to the project directories under `…/vibemaestro/brain/`: `pending/` holds one marker per session whose dialog record is waiting for its command, and `sessions/` holds one record per running session naming its project (removed at the session's end, except after `/clear` or a switch to another session, or after 30 days).

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

- No recall and no automatic eviction: you or Claude retire items, except an item whose `closes` are done (see [Auto-close](#auto-close)). Expired windows are shown as expired but not removed.
- The token column of the Matrix is characters ÷ 4, not a measured count.
- Whether the brain helps was not shown at the size of the first level's exit test; see [What the exit test showed](#what-the-exit-test-showed).
