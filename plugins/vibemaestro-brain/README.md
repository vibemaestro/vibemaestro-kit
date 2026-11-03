English | [Tiếng Việt](README.vi.md)

# vibemaestro-brain

A second brain for long-running Claude Code sessions. It keeps the goals, decisions, delegation windows, focus, the owner's requests, current task, next steps and traps of a session in a small log outside the repository, and puts that log back into the context after every compaction.

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

The brain holds short items of eleven kinds, in two halves. The **left brain** is the owner's: only the owner adds, changes or removes its items, through Claude Code's permission dialog. The **right brain** is what the session writes with `brain op`, under the rules below.

| Half | Kind | Letter | What it is | Live items at most (default) |
|---|---|---|---|---|
| left | Goal | `G` | a goal the owner set: the owner's words, what "done" means, a "not doing" line, a review day and a scope (`global` or `project`) | 5 |
| left | Pinned decision | `D` | a decision the owner stated, with the owner's words | 20 |
| left | Window | `W` | something the owner allowed without asking, until a time | 10 |
| right | Focus | `P` | the focus of the current wave, in the owner's words, pointing to one goal; it orders Next | 5 |
| right | Request | `R` | what the owner asked, in the owner's words, with an optional due day; it closes only with a pointer | 20 |
| right | Now | `N` | the task in hand | 5 |
| right | Session | `S` | a running session: its next step, with pointers (PR, intent, record), and the goal it serves | 20 |
| right | Owner queue | `Q` | what waits on the owner | 15 |
| right | Next | `X` | the next steps | 30 |
| right | Trap | `T` | a mistake to avoid, counted each time it recurs | 20 |
| right | Fact | `F` | a path or fact in use (`~/…` or relative to a plugin root) | 25 |

Each text is at most 300 characters, a session's 600, and the owner's words at most 600, counted as Claude Code counts a hook string (UTF-16 units: an emoji counts 2). These caps are defaults: a project changes them in `.vibemaestro/brain.json` (see [Configuration](#configuration)). The right brain also shows **Done**: the request, Now, Next, session and queue items the log closed in the last 24 hours, newest first, at most 7 lines and then a count, each `- X5 owner/name#N <merge commit> · <text>` (the anchor and commit first, the text last, so a long text is what the line loses). Nothing writes Done: it is read from the log.

**The owner's words are stored whole.** A goal, a pinned decision, a focus and a request keep the owner's words verbatim, with where they were said. Under the item, one line shows them, `  "<quote>" · <where>`, the source whole (at most 60 units) and the quote cut for room only: at 120 characters under a pin, at 300 under a goal, a focus or a request. `brain show ID` prints every stored field of one item, the words whole. A quote over its cap is refused, never cut, and no operation changes a stored quote: a supersede of a goal, a focus or a request carries it over byte for byte (an owner supersede of a pin stores none). A goal's item line shows its review day and scope (`review 12-31 · scope project`, `review OVERDUE 3 d` once the day has passed), then `done when: …` and `not doing: …`. A focus shows its goal (`goal G1 (retired)` once the owner unpinned or promoted it), and Next lists the items tied to each live focus first (`- X3 [P1] …`), then the rest; a superseded focus passes its items to its successor. Days count in UTC, as every time of the brain does. A request shows its due day (`due 11-07`), and from 7 days before, the first right-brain string carries one line, `Due: R5 OVERDUE 2 d (10-29) · R3 TOMORROW (11-01) · R4 in 6 d (11-06)`. A request closes only with `--pointer` to what answered it, or by its `--closes` anchor.

**A full section overflows; the left brain does not.** An add to a right-brain section at its cap is never refused. It goes into that section's overflow queue, in the log, as the op `overflow-add`: `queued X31 (Next holds 30 of 30; 2 queued before it; not injected until it moves up)`. A queued item is not injected. One line counts the queues, `Overflow queue: X 3, S 1 (in the log, not injected: brain overflow)`, and `brain overflow` lists them, head first. The op that makes room moves the queue's head up in the same log line, first in, first out: a close, an auto-close, an owner verb of a plugin that moves a lesson or a fact out (see [Extensions](#extensions)), or, after a cap was raised, the next write to that section. A queued item can be closed, superseded (the new item keeps its place), touched and hit. The left brain has no overflow: an owner add at a left cap is refused before the dialog asks, naming the items least recently touched, and the owner chooses which to retire (`brain owner unpin`) or promote (`brain owner promote`).

**Strings, each under Claude Code's cap.** Claude Code passes one hook command's string to the model whole up to 10,000 characters, counted in UTF-16 units (an emoji counts 2), and replaces a longer one by a short preview. So the brain packs its two halves into strings of at most 9,500 units, one `SessionStart` command each:

| String | Holds |
|---|---|
| 1, `# vibemaestro-brain` | the head line, the precedence line, the configuration line when it has something to say, the review card after a compaction, the left brain (`## Brain · left brain`: goals, pinned decisions, windows) as far as it fits, and the Shelf index |
| 2 to 14 | the rest of the left brain, then the right brain (`## Brain · right brain`, or `right brain, 1 of 3` when it takes several): the Due line, the overflow line, Focus, Requests, Now, Sessions, the owner queue, Next, Traps, Done and Facts |

The left brain never shares a string with the right. Lines move whole: an item stays with its quote line, and a section that goes on in the next string repeats its title, marked `(cont.)`. Each string also keeps a hard cut at 9,500 units that names what it cut; at the default caps, with every line full and every note, no string reaches it. The plugin declares 14 string commands: anything past them is not injected, and the 14th string ends with one line naming how many lines and which sections were left out (`brain doctor` warns when the caps would need more). The right brain's strings are left out while it holds nothing. Claude Code runs a plugin's commands of one event in parallel and adds their strings in the order they finish, so each title says which part it is. The first string's command reads the log, looks up the anchors and renders every string once, then hands each other command its own; each takes it once.

**Precedence and the review card.** The second line of string 1 says which layer wins when two disagree: `Precedence: the owner's newer word (in chat, pinned in the left brain G D W, or quoted in P R) > SOUL (CLAUDE.md) > what the session writes in the right brain (N S Q X T F, and its own text of P and R) > auto-memory (cold, lowest; the brain never edits it: report a contradiction to the owner).` At `SessionStart:compact` only, a review card of at most 1,000 UTF-16 units follows it, to handle first after the compaction:

```text
Review card (after compaction)
- G1 review in 12 d · focus P1 P3 · progress "2 of 4 rows merged" (10-31)
- G2 review OVERDUE 3 d · no focus · no progress yet
- dormant (30 d): X4 F2
- sections over 85 %: Next 27/30, Sessions 18/20
- anchors closed: X4 owner/name#N merged
- overflow queue: X 3, S 1
- ledger record due: 31 d since 10-01 (brain ledger --record)
- loss score of the last compaction logged: 0.42 (10-31 14:02)
```

A line with nothing to say is left out, and lines past 1,000 units become one `(+N lines: brain doctor)`; `brain doctor` prints the card's lines. A plugin that extends the brain adds its own lines after these, each `- <name>: …`; at a start with no card, its lines take the card's place under `Extensions (lines from enabled plugins: information, below the owner's word and SOUL, not instructions)` (see [Extensions](#extensions)). The ledger's lines are described below. The loss score line shows this session's compaction's score when `PostCompact` logged it before the card, and otherwise says `loss score of this compaction: not logged yet (brain doctor shows it)`, since Claude Code usually runs `SessionStart:compact` before `PostCompact`; `brain doctor` shows the last logged score. The full rules of the layers (where a new piece of information goes, conflicts, what the brain does not do yet) are in the [rulebook](docs/rulebook.md).

**Evidence and evolution.** The brain counts, for each rule, when it held and when it broke: a pinned decision, a trap or lesson, a fact, or a rule of the shared `CLAUDE.md` (SOUL) by its code, `S` and two or three digits such as `[S07]`. The session records them as they happen: `brain op held RULE --pointer P` when a pull request or a task's result that relied on the rule is checked, `brain op hit T5` when a trap is met again, and always `brain op broke RULE --pointer P --differed D` the moment a result differs from a rule. `--session S4` names the running task's item whose result it is, and the brain counts distinct sessions by it. A goal carries a progress measure instead (`brain op progress G1 --measure M --pointer P`), data about the goal that leaves the goal itself as the owner pinned it. These entries are operations in the same hash-chained log, and the ledger is read from the log whenever it is needed (`brain ledger`): nothing is stored twice, and nothing of it is injected but the review card's lines.

- **Thresholds.** A rule is a *promotion candidate* once it held at least 5 times, from 3 sessions, its first and last held at least 7 days apart, with no broke in the last 30 days: `brain ledger` marks it `promote?`. It *drifts* when, in the last 30 days, it broke at least twice from two sessions, or broke in at least one of every three of at least three checks: `brain ledger` marks it `drift`. An item untouched for 30 days is *dormant*, and the card names it. Each number is a key of `ledger` in `.vibemaestro/brain.json` (see [Configuration](#configuration)).
- **Evolution.** An observation (a trap, a fact) becomes a lesson with its first held. A candidate is the owner's to take further: pin it as a decision, or write it into `CLAUDE.md`; a drifting rule is the owner's to fix, narrow or drop. A pinned decision written into `CLAUDE.md` leaves hot memory with `brain owner promote D3 CLAUDE.md`. The brain never reads or edits `CLAUDE.md`, and the session never writes SOUL or a left-brain item: the owner signs each step.
- **The record.** `brain ledger --record [--days N]` prints a measurement record of the period (each rule's counts, what crossed a threshold, each goal's progress, dormant items, capacity, compactions and their loss scores, and a section from each plugin that extends the brain), and the card says when a month has passed since the last one.

**Capacity.** At the default caps, with every section full of full-length lines, every session start injects at most 12 strings, about 100,000 characters (about 25,000 tokens; not measured). A long-running session's real state measured about 11,400 characters. Lowering a cap in `.vibemaestro/brain.json` lowers that ceiling.

The store follows these rules:

- **One op log is the truth.** `hot.jsonl` holds one operation per line. Each line carries the SHA-256 of the line before it, and `head.json` holds the tail. Every write first checks the whole chain and the head. A log that was cut or edited by hand stops all writes (rc 5).
- **Item operations only.** The operations are `add` (`overflow-add` when the section is full), `close`, `supersede`, `touch`, the ledger's `evidence` (a held, a broke, a trap's hit) and `progress`, and one the brain writes itself, `link-close`: a Now, Next, session or queue item closes when the issue or PR it names with `--closes` is done (see [Auto-close](#auto-close)). There is no edit, replace or import. A supersede keeps both items, carries every anchor over, and keeps at least 60% of the first text of its chain unless you pass `--shorter` with a reason.
- **A retirement budget.** `brain op close` and `brain op supersede` are refused once the session has retired 5 items in the last 30 minutes (owner retirements count too). A deliberate sweep passes `--bulk`, and the log records it. A session or queue item is status, not a decision: its supersede (a new next step) spends no budget and may be shorter than 60%.
- **Anchors.** An item can carry anchors: exact strings a summary must keep, such as a PR number, a 7-hex SHA, a path or a code word. After each compaction the brain logs a *loss score*: the share of the live items' anchors that the summary dropped.
- **Owner items go through the permission dialog.** Only the owner can create or change a `G`, `D` or `W` item. The command is `brain owner …`, and it writes only after the owner approves a one-line Claude Code permission dialog, for example `Pin owner decision D3 (a lasting direction, never done), from "<where>": "<text>"` (every line that pins, imports or replaces a decision names its kind in words), or for a goal every field before the text, `Pin owner goal G2 (review <day>, scope project), from "<where>", done when "<done>", not doing "<not doing>": "<text>"`. With no approved dialog the command stops with rc 6. A model alone cannot write an owner item. The dialog is unavailable in `dontAsk`, `plan` and `bypassPermissions` modes, in a `-p` run, in a subagent, and while a `PermissionRequest` hook or a `--permission-prompt-tool` could answer in place of a person. In those cases the session tells the owner instead of trying another way.
- **No secrets.** Every text passes through the sensitive-value filter of vibemaestro-sdlc (`gates/pr_sensitive.py --text`). A hit, or a missing filter, refuses the write. The brain also refuses control and format characters, characters that render as nothing, and blank text.
- **One writer.** The first session that writes owns the project's brain. Another session needs `brain claim --take-over`, which the log records. A worker session (one with `VIBEMAESTRO_ROLE=worker`, or with both `INTENT_SLUG` and `SEAT` set, as a tool that starts sessions for you may set them) never writes (rc 4), and neither does a subagent: it reports back, and the main session writes.

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
brain op add --kind request --text "Document the layers" --owner-quote "viết docs cho các tầng" --where "chat"
brain render --check                   # each string's size, each section's count against its cap
brain overflow                         # what waits in a full section's queue
brain show R1                          # every stored field of one item, the owner's words whole
brain doctor                           # chain, caches, filter, file modes
brain matrix                           # what the brain holds, cell by cell
```

`brain render --check` prints, for example:

```text
string 1 (left brain): 171 of 9,500 units with string 1's 2,800 for the hook's lines
string 2 (right brain): 438 of 9,500 units
  Goals (owner): 0 of 5
  Pinned (owner): 0 of 20
  Windows: 0 of 10
  Focus: 0 of 5
  Requests: 1 of 20
  Now: 1 of 5
  Sessions: 1 of 20
  Owner queue: 0 of 15
  Next: 1 of 30
  Traps: 1 of 20
  Done (24 h): 0
  Facts: 0 of 25
```

`brain render` prints the precedence line and then the strings that the hooks inject (without string 1's head line and the Shelf index; `hot.md` does not hold the precedence line):

```text
Precedence: the owner's newer word (…) > SOUL (CLAUDE.md) > … > auto-memory (…).
## Brain · left brain v6 · 171/9,500 chars   (the owner's: change only with `brain owner`, through the dialog)
Goals (owner)
Pinned (owner)
Windows
Matrix: `brain matrix`

## Brain · right brain v6 · 438/9,500 chars   (change only with `brain op`; Done is derived)
Focus
Requests
- R1 Document the layers · since 10-19
  "viết docs cho các tầng" · chat
Now
- N1 Write the README · since 10-19
Sessions
- S1 docs-run: README review, then the PR · no goal · since 10-19
Owner queue
Next
- X1 Run every command · since 10-19
Traps
- T1 Never hand-edit the state directory · since 10-19 (hits 0)
Done (24 h)
Facts
```

With a cap of 1 for Next in `.vibemaestro/brain.json`, a second Next item waits, and a close moves it up:

```text
$ brain op add --kind next --text "Publish the release notes"
queued X2 (Next holds 1 of 1; 0 queued before it; not injected until it moves up)
$ brain overflow
Next: 1 queued (1 live of 1)
- X2 Publish the release notes · since 10-19
$ brain op close X1 --reason done --pointer README.md
closed X1
moved up from the overflow queue: X2
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
| `SessionStart` (every source: startup, resume, clear, compact, fork) | Fourteen commands inject the strings (see [How it works](#how-it-works)), each at most 9,500 UTF-16 units: string 1 holds the precedence line, the review card (at `compact` only), the left brain and then the Shelf index (the skills Claude can invoke, at most 1,000 UTF-16 units); the right brain's strings are left out when it is empty. A longer string is cut at whole lines and the cut is named. A live Now, Next, session, queue, request or pinned item whose anchor names a closed issue or a merged or closed PR gets a `stale:` mark (see [Stale anchors](#stale-anchors)). For the project's writer, an item whose `closes` anchors are all done is closed first, and one note line in its string says so (see [Auto-close](#auto-close)). A due backup is started in the background, never waited on. |
| `PreCompact` | Logs the trigger and the context size, read from the tail of the transcript. Adds the API calls since the last saved byte offset to the session's running cost sums. Starts a due backup in the background (see [Export, import and backup](#export-import-and-backup)). It never blocks the compaction. |
| `PostCompact` | Saves the summary to `summaries/` (mode 0600, never injected, the newest 200 kept) and logs the loss score. |
| `SessionEnd` | Deletes the session's pending dialog records, logs the end, and appends a `cost` line from the saved sums. A session that never compacted gets no `cost` line: the transcript is not read here. |
| `UserPromptSubmit` | In the session that holds the claim (the writer), at most every 10 minutes per brain, when a live item names a `closes` anchor and `gh` is on the `PATH`, starts `brain op close-linked` in the background and never waits on it; a run that fails or is refused is not started again before 10 minutes. Its closes are `link-close` ops, like a hand-run `close-linked`, so they spend none of the session's retirement budget (see [Auto-close](#auto-close)). Each run logs one `close-linked` line in the Episode Log: its outcome, or `refused` with the rc and why. |
| `PreToolUse` on Bash, `brain op …` or `brain import …` | Denies a hot-memory write from a subagent. |
| `PreToolUse` on Bash, `brain …` | `note-format`: when a session whose last start ran an older brain runs a `brain` command, this hook (which runs the current brain) logs one `session-format` line, so `brain doctor` stops warning that the session last started on an older brain. |
| `PreToolUse` on Bash, every call | `guard-owner`: for a command that starts with `brain owner` (`brain` on the `PATH`, a path to `bin/brain`, or `python3` running `scripts/brain.py`), asks the owner with the dialog line, or denies. On any other command it gives no decision, including one that only mentions the words: a here-document body, a quoted string, an `echo` or a `grep`. |
| `PreToolUse` on Edit, Write, NotebookEdit | Denies an edit under the brain's state root. |

When `guard-owner` denies, it names the reason: a subagent, a command that is not literal (write one `brain owner …` command alone in its Bash call, with no variable, substitution, backslash, glob, `~` or redirect), a mode with no dialog, or an answerer such as a `PermissionRequest` hook.

All hooks are silent when `BRAIN_OFF` is set (other than empty or `0`) and in a worker session. The first three are also silent in a project with no hot memory yet, and `SessionEnd` writes nothing when the project has no state directory. Hooks fail open: an error is one line on stderr and never blocks the session.

The Episode Log, `episodes.jsonl`, holds one line per session start, owner call, session end, cost, auto-close, printed record (`ledger-record`), export, import, owner import, backup, named backup place, background `close-linked` run and `session-format` note, and two per compaction (a `pre-compact` line and a `compact` line). `templates/compact-instructions.md` is a `# Compact instructions` block you can paste into a project `CLAUDE.md` so that the summary itself keeps, before anything else, the owner's requests not yet written as `R` items (verbatim, with where they were said), the goals and focus the owner named, owner decisions, windows, open PRs, sessions, timers and the current task. You place it by hand. It complements writing through: the owner's words go into the brain in the turn they are said, since `PreCompact`'s output never reaches the model.

## Commands

`bin/brain` runs `scripts/brain.py`. Every command prints `brain: …` on stderr when it stops.

| Command | What it does | Exit code |
|---|---|---|
| `brain op add --kind now\|next\|trap\|session\|queue\|fact --text T [--link L]… [--anchor A]… [--closes A]… [--expires ISO] [--focus P1]` | Adds an item of that kind, or queues it when its section is full; `--closes` (Now, Next, session, queue and request only, at most 2) names the issue or PR whose close means the item is done; `--focus` (Next only) ties it to a live focus. A session item is a running task, such as a `local-parallel` subagent's. | 0; 1 refused; 3 not the writer; 4 worker; 5 log broken |
| `brain op add --kind request --text T --owner-quote Q --where W [--due YYYY-MM-DD] [--anchor A]… [--closes A]…` | Adds what the owner asked: `T` is your one line, `Q` the owner's words verbatim (they may hold `"`). | as above |
| `brain op add --kind focus --text T --owner-quote Q --where W --goal G1 [--anchor A]…` | Adds a focus pointing to a live goal (rc 1 otherwise). | as above |
| `brain op close ID --reason R [--pointer P] [--bulk]` | Closes an item as done or dropped; a request needs `--pointer`. | as above |
| `brain op supersede ID --text T --reason R [--drop-anchor A]… [--anchor A]… [--closes A]… [--focus P1] [--due YYYY-MM-DD] [--shorter] [--bulk]` | Replaces an item with a new one; keeps both in the log. The new item carries the old one's `closes`, focus, goal, due day, the owner's words and each extension's data unless an option names its own (never the owner's words). | as above |
| `brain op close-linked` | Closes every item whose `closes` anchors are all done, from fresh lookups, with no cap of 5 at once. Prints what it closed and what it skipped, with why. | as above; 1 `gh` not found |
| `brain op touch ID` | Marks an item still current. | as above |
| `brain op hit T5 [--pointer P] [--session S4]` | Counts a trap met again (traps only): a held in the ledger. | as above |
| `brain op held RULE --pointer P [--session S4]` | Records that a rule held: `RULE` is a live decision, trap or fact (`D3`, `T5`, `F2`) or a rule of `CLAUDE.md` by its code (`S07` or `[S07]`). | as above |
| `brain op broke RULE --pointer P --differed D [--session S4]` | Records that a rule broke, with what differed (at most 150). | as above |
| `brain op progress G1 --measure M --pointer P` | Records a live goal's progress measure (at most 80); the goal is not changed. | as above |
| `brain owner add --kind decision\|window --text T --owner-quote Q --where W [--anchor A]… [--link L]… [--expires ISO] [--scope global\|project]` | Pins an owner decision, or grants a window (a window needs `--expires`, a time in the future). A decision may carry a scope; one without counts as `project`. Refused at the section's cap: the left brain has no overflow. | 0; 6 no approved dialog; otherwise as above |
| `brain owner add --kind goal --text T --owner-quote Q --where W --done D --not-doing N --review YYYY-MM-DD --scope global\|project [--anchor A]… [--link L]…` | Pins an owner goal: `--done` and `--not-doing` at most 200 characters each, a review day that is not in the past. | as above |
| `brain owner unpin ID` | Retires an owner item. | as above |
| `brain owner supersede ID [--text T] [--done D] [--not-doing N] [--review YYYY-MM-DD] [--scope S]` | Replaces an owner item; a goal's fields not given and its words carry over, and the dialog names each field that changes. Without `--text`, the text and the owner's words carry over unchanged; `--scope` sets or changes a goal's or a decision's scope. | as above |
| `brain owner promote ID POINTER` | Moves a goal, decision or window out of hot memory to a pointer (`CLAUDE.md` or a decision file, for example). | as above |
| `brain owner import FILE` | Lands a bundle's goals, decisions and windows through one dialog that lists every one of them (see [Export, import and backup](#export-import-and-backup)). | as above |
| `brain owner batch FILE` | Writes 2 to 5 owner items through one dialog. `FILE` is a JSON array of owner argv lists, each an `add`, `supersede` or `unpin` (`[["add", "--kind", "goal", …], ["unpin", "D3"]]`). `guard-owner` asks one dialog, `Owner batch of N, one approval for all:`, then one numbered line per item, each the line its single form shows, with the ids as the earlier items leave them. The record binds the file's bytes and the dialog's text: a file edited (even in a field the dialog does not show), swapped or reordered, or a brain that changed after the dialog, is refused (rc 6, nothing written; ask again). Every item passes its single form's checks, and all are written under one lock, or none. A symlink or a file that is not regular, 1 item or more than 5, another verb, a file that is not JSON, or an item its single form would refuse is refused before any dialog (rc 1, naming the item as `item K:`). | as above |
| `brain owner backup DIR [--every HOURS]`, `brain owner backup off` | Names the private directory this project's brain is backed up to, every 24 hours unless `--every` says otherwise (1 to 720), or stops the backups. | as above |
| `brain owner VERB …` | An owner verb a plugin that extends the brain adds (`brain doctor` lists them): it pins a decision or moves an item out, through the same dialog (see [Extensions](#extensions)). | as above |
| `brain export --out FILE [--scope global\|project]` | Writes a bundle of this project's brain into a new file; with `--scope`, only the goals and decisions of that scope. | 0; 1 refused (a sensitive value, an existing file, no state yet); 5 log broken |
| `brain import FILE [--only LETTERS]` | Lands a bundle's right brain as `brain op add` writes it, then replays its ledger; prints what landed, what waits, what was skipped and the owner items left for `brain owner import`. | 0; 1 the bundle refused; 3 not the writer; 4 worker; 5 log broken |
| `brain backup [--if-due]` | Writes a bundle into the place the owner named and keeps the newest 30; with `--if-due`, only when a backup is due, and silently otherwise. | 0; 1 no place named, or the place or the bundle refused |
| `brain claim [--take-over]` | Takes the writer role; `--take-over` takes it from another session, and the log records it. | 0; 3 another writer or no session id; 4 worker |
| `brain render [--check]` | Prints every string; `--check` prints each string's size against the cap and each section's count against its cap, with what is queued, instead. | 0; 1 over a cap, more than 14 strings, or no state yet; 5 log broken |
| `brain overflow` | Lists each right-brain section's overflow queue, head first, one line per item. | 0; 1 no state yet; 5 log broken |
| `brain show ID` | Prints every stored field of one item, live, queued or retired, one `field: value` line each; the owner's words whole. | 0; 1 no such item or no state yet; 5 log broken |
| `brain ledger [RULE]` | Prints one line per rule (held, sessions, broke, last, what it is, `promote?` or `drift`) and each goal's progress; with `RULE`, its events. | 0; 1 not a rule or no state yet; 5 log broken |
| `brain ledger --record [--days N]` | Prints the measurement record of the last `N` days (30 by default) and logs that it did; a record of 30 days or more restarts the card's monthly due clock, a shorter one is a look. | as above |
| `brain ext NAME [ARG…]` | Prints what the plugin that extends the brain as `NAME` reads from the brain's state; it writes nothing. | 0; 1 no such extension, or it failed; 64 as it answers |
| `brain doctor [--path \| --bundle FILE]` | Checks the configuration, the chain, head, caches, file modes, the filter, the answerers and the Claude Code version, names each plugin that extends the brain and why one was skipped, prints the review card's lines, counts the queues, lists every item closed in the last 24 hours (Done shows 7), and looks up the anchors of live items (a `warn` per stale one, and what auto-close would do or did); `--path` prints the state directory; `--bundle` checks one bundle instead, on its own. | 0; 1 a problem, each named |
| `brain matrix [--json]` | Prints the Brain Matrix. See [Cost model](#cost-model). | 0 |
| `brain cost TRANSCRIPT [--merge-log F] [--json]` | Prices a transcript's token usage. See [Cost model](#cost-model). | 0; 2 cannot read |

Any command exits 64 on a usage error and 70 on an internal error (named, never a traceback). `brain op` never touches a `G`, `D` or `W` item: a `close` or `supersede` applies to `P`, `R`, `N`, `X`, `T`, `S`, `Q` and `F` items only, live or queued. While `.vibemaestro/brain.json` holds a wrong value, `brain op` and `brain owner` are refused (rc 1, naming the key); an unknown key or a left cap off its default prints a `warning:` line on stderr and the write stands.

`brain owner` is strict, because the permission dialog shows the same tokens the command runs with. Spell each option in full, give its value as the next argument (no `--opt=value`; a value may start with `-`), and give a single-value option once. A text, a source (`--where`), a pointer and a goal's `--done` and `--not-doing` may not contain a double quote. The fields shown before the text (`--where`, a promote's pointer, a goal's `--done` and `--not-doing`, a goal's progress measure, the backup place, and an imported item's owner fields) take only letters of left-to-right scripts (with the combining marks right after a letter), decimal digits of a left-to-right script or European digits, the space, and ASCII punctuation other than `"`; a character named like a quotation mark, prime, gershayim, ditto, double apostrophe or double acute is never allowed. Anything else, such as an emoji, a right-to-left letter, an Arabic-Indic digit or a curly quote, is refused (rc 1, by the command and by `guard-owner` before it asks), naming the character as `U+XXXX`. The text, last on the line, keeps its own rule. `--owner-quote` is the owner's words, verbatim; `--where` says where they were said.

When an op is logged but the caches cannot be rewritten, the op still stands (rc 0, with a warning) and the next read folds the log again.

## Skills

| Skill | Who invokes it | What it does |
|---|---|---|
| `brain` | Claude, when a session must keep a goal, decision, window, focus, request, task, next step or trap across compactions | Teaches the rules above: when to run `brain op`, how to write an owner item through the dialog, writing the owner's words through in the turn they are said, a running task's item, recording held, broke and progress in the turn, what `promote?` and `drift` ask of the owner, the precedence, the review card and an extension's lines, what each exit code means, how to re-claim after `/clear` or `--fork-session`. It points to the [rulebook](docs/rulebook.md). |
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

An anchor is the exact string a summary must keep (`--anchor`). When a live Now, Next, session, queue, request or pinned-decision item has an anchor that is a closed issue, a merged PR or a closed PR, the brain says so and leaves the item alone: only the writer closes or supersedes it, with `brain op` (a pinned decision: the owner, with `brain owner`). The one exception is an item's own `closes` anchors (see [Auto-close](#auto-close)). The lookups use `gh` with its own login, always on `github.com` (`--hostname github.com`).

- **Which anchors.** Only a whole anchor in one of three forms:
  - `owner/name#N`, checked as written;
  - a GitHub issue or PR URL, `https://github.com/owner/name/issues/N` or `https://github.com/owner/name/pull/N` (nothing after the number), checked as the same `owner/name#N`;
  - a bare `#N`, checked only in the item's own repository: the one repository that its `owner/name#N` anchors, GitHub issue or PR URLs and `closes` anchors name, when they name exactly one. An item that names none or several has no single repository, and its bare `#N` is not checked.

  The first two name their repository, so they are the forms for a session that works across several repositories. Any other anchor, and any number in an item's text, is ignored. Traps, windows and facts are not checked.
- **Writing a bare anchor.** `brain op add`, `brain op supersede`, `brain owner add` and `brain owner supersede` print one `warning:` line after their usual message when the Now, Next, session, queue, request or pinned-decision item they write carries a bare `#N` and names no single repository: `warning: #N is not checked for staleness (the item names no single repository to resolve it against); write owner/name#N (a GitHub issue or PR URL also works)`. The line names each bare anchor and the form to write instead. A bare `#N` is still accepted, and the command never refuses: the item is written and the exit code is 0 (`--closes` still refuses a bare `#N`). A supersede names the bare anchors it carries over (replace one with `--drop-anchor '#N' --anchor owner/name#N`).
- **`brain doctor`** looks every such anchor up on GitHub with `gh api` and prints one `warn` line per stale anchor (`stale anchor: X5 #7 (owner/name#N) closed <date>`, where a bare `#7` is checked in the one repository its item names; `merged` for a merged PR, `closed unmerged` for a PR closed without a merge, `closed not planned` for an issue closed as not planned). A pinned decision's line adds the command the owner runs (`owner retires it: brain owner unpin D3, or brain owner supersede D3 --text …`). It does not read or write the cache, and a `warn` does not change its exit code. For the live items whose bare anchors it cannot check (the item names no single repository), it prints `info  stale anchors: N bare anchors on M items naming no single repository are not checked; write owner/name#N` and one `info` line per anchor (`not checked: X3 #7`), at most 20, then `not checked: +K more anchors`. While `BRAIN_DEFAULT_REPO` is set it prints one `warn` (`BRAIN_DEFAULT_REPO is set (<value>) but no longer read: …`).
- **`SessionStart`** adds ` · stale: #7 closed 2026-10-20` after the item's line, in the injected strings only (not in `hot.md` or `brain render`), and one `stale-anchor check:` note line in the first string when `gh` is missing, a lookup failed or timed out, a bare anchor was skipped (`skipped for #7: no single repository of its item`), or not every anchor has an answer yet. Marks and notes together stay within 450 characters per string.
- **Fast and offline-safe.** Answers are cached in `stale-cache.json` in the state directory (600 seconds; a failed lookup 120 seconds). At most 12 lookups run per `SessionStart`, the least recently checked anchors first, in parallel under one 2-second deadline, then are killed; so every anchor is reached within a few session starts. No `gh` or no network means no marks and one note line, never a failure.

## Auto-close

A Now, Next, session, queue or request item can name the issue or PR whose close means *this item is done*, with `--closes` (at most 2, each `owner/name#N` or a GitHub issue or PR URL; a bare `#N` is refused). Name the item's own work, never a dependency it waits on and never a tracking issue of several PRs. A `closes` anchor is also an anchor, so it counts toward the 8 and is marked like the others.

- **At write time** the anchor is looked up once (2 seconds): the command prints its state and title (the title is not stored), and refuses (rc 1) an anchor GitHub does not know and a new one already merged or completed, since that item could only be marked, never closed. A supersede that keeps an anchor its item already names (carried over, or named again) warns instead when it is done: the new item may close at the next session start, and `--drop-anchor` keeps it live. With no answer (offline, no `gh`) the write goes through with `closes not checked: owner/name#N`.
- **At `SessionStart`**, in the session that writes the project's brain (the last `brain claim`), an item closes when every one of its `closes` anchors is done after the item that named it was written: a PR merged into its repository's default branch (a second lookup, `…/pulls/N`, checks the base), or an issue closed as completed by a lookup made in that very session start (a cached issue answer never closes, since an issue can be reopened). The op is `link-close`, with a reason, a pointer and each anchor's state, time and merge commit; it does not count toward the retirement budget. The string that held the item shows one note line, `auto-closed now: X5 (owner/name#N merged <month-day>)`, once, and the item moves to Done.
- **Never closed:** a PR closed unmerged or merged into another branch, an issue closed as not planned, as a duplicate or with no reason, an open anchor, a lookup that failed or timed out, and any item of another session's start. These keep their stale mark. A goal, a pinned decision, a window, a focus, a trap or a fact never closes by a link: a pin whose anchor is done is marked `owner retires it`. A request that closes by a link carries its anchor as the pointer.
- **At a writer's prompt**, besides `SessionStart`, the `UserPromptSubmit` hook starts `brain op close-linked` in the background (see [Hooks](#hooks)), so a long session closes what merged without a new start. The closes are `link-close` ops and each run logs one `close-linked` line in the Episode Log.
- **A burst is held.** When more than 5 items would close at once, none does: they are marked, and the note says `auto-close held: N items at once; check brain doctor, then brain op close-linked`. `brain op close-linked` makes the same checks with fresh lookups (20 seconds, at most 40 anchors) and closes every item that passes.
- **Reopened issues.** For 24 hours after a close, the issue anchors of the closed item are looked up again now and then (at most 3 per session start). One that is open again adds `reopened: X5 owner/name#N, re-add it with brain op add` to the note line; there is no reopen op.
- **`brain doctor`** writes nothing; it prints `would close:` for an item the next session start would close, `auto-closed:` for each close of the last 24 hours, and the reopened lines.
- **Updating.** Restart every session of a project on this version before an item closes by a link, a goal, focus, request, session, queue or fact item is written, or an item is queued: an older brain refuses to write to a log that holds a `link-close`, one of those kinds or a queued item, and stops injecting hot memory whenever it has to read that log again. `brain doctor` warns about a session whose last start ran an older brain, and says to restart it on this version; after `/reload-plugins`, any `brain` command in that session clears the warning. Going back to an older version is not supported once one is written.

## Export, import and backup

A project's brain can be written to one file, checked on its own, brought into another project, or brought back into the same one after a loss, and it can be backed up to a private place the owner names.

- **The bundle.** `brain export --out FILE` writes one JSON file, mode 0600, as a new file outside the state directory. It holds the log line by line as it was written, so its hash chain can be checked, the chain head, and copies of what the log holds: every live and queued item with its kind, anchors and the owner's words, the overflow queue and the evidence ledger. This machine's paths become placeholders: the project's work tree is `<project>`, the state root `<brain-state>` and the `XDG_STATE_HOME` it sits in `<state-home>`, Claude Code's config directory `<claude-dir>` and the home directory `~`. A line that changed keeps its original hash, so the chain goes on across it, but the chain does not vouch for that line's content: an import lands nothing such a line wrote, and names what it skipped. The sensitive-value filter runs over the whole bundle, and a hit stops the export. A bundle says `"version": 1`. With `--scope global` (or `project`), the bundle holds only the goals and decisions of that scope and the lines that wrote them, no other line of the project; such a selection does not carry its chain. Export only reads, so it needs no session.
- **Checking.** `brain doctor --bundle FILE` checks one bundle without touching any brain: its shape, its chain and head, that its copies equal the fold of its log, and its text against the write guards and the filter.
- **Importing is two commands.** `brain import FILE [--only LETTERS]` lands the right brain (focus, requests, Now, sessions, the owner queue, Next, traps, facts) as `brain op add` writes it: the caps, the queue and the guards apply, ids are kept when they are free, and an item whose goal or focus has not landed waits for a later run. It then replays the evidence ledger of what is here, each event at its source time. `brain owner import FILE` lands the goals, decisions and windows through one permission dialog that lists every one of them, each line in the form the single dialog uses. The dialog's text is bound to its record, so a bundle or a brain that changed after the dialog is refused. Run the owner's half first, then `brain import` again for what waited on it.
- **What an imported item keeps.** The owner's words, byte for byte, and a provenance line that `brain show ID` prints: the source project, its key, its chain head and the item's old id. A supersede carries the provenance over.
- **An extension's data** (`ext.<name>`) travels in the bundle, in its log, but `brain import` does not land it.
- **A bundle is data.** Its text passes the guards of a write: length, control and invisible characters, sensitive values. A bundle that fails one is refused whole. An item that only exceeds this brain's own limits (a smaller text cap, a full left section, an expired window) is skipped and named. Nothing in a bundle is run or used as a path. An import only appends to the log, as one batch under the store lock, written by the project's writer.
- **Refused bundles.** A bundle of this very brain, a brain that is an older state of the bundle's own chain, a bundle older than one already imported from the same project, and a bundle that forks from it. The same bundle twice lands nothing new; a newer one names the items its source has retired since.
- **Backup.** Through the dialog, `brain owner backup DIR [--every HOURS]` names the private directory the backups go to: an absolute path to a real directory of this account, mode 0700, outside every git work tree, the project and the state root. `brain owner backup off` stops them. The place is kept in the state directory, never in the log. `brain backup` writes a full bundle there and keeps the newest 30. When a backup is due (the brain changed and the last backup is older than the interval, 24 hours by default), the `SessionStart` and `PreCompact` hooks start `brain backup --if-due` in the background, and no hook waits on it. You may also run `brain backup` from your own scheduler, in the project's directory. `brain doctor` names the place and the last backup and warns when backups fail or fall behind; the review card says so too.
- **Restore.** After a loss, the owner moves the old state directory aside if it is still there (`brain doctor --path` names it). Then `brain owner import BACKUP` and `brain import BACKUP` bring the brain back into the empty state, with the same ids, the owner's words, the items' dates, the queue and the ledger. A rule code's events (`brain op held S07`) come back; an item moved out to a pointer, and the evidence of a superseded rule, stay in the bundle.

## Extensions

Another plugin may add to the brain through one declared script: a check on a `brain op` write, an owner verb, lines for the session start, the review card and the measurement record, and a read command. The brain runs the script in a process of its own, gives it data and takes data back; the extension never writes the brain. Brain writes what it answers, through its own write paths and filters, under the extension's name. A brain with no extension loads none of this.

**What makes a plugin an extension.** It is installed for the project (an entry with `projectPath` counts for that project only) and enabled in the user, project, local or managed settings; its install path lies inside `<config dir>/plugins/`; its `.claude-plugin/plugin.json` lists `vibemaestro-brain` in `dependencies`; and its root holds the regular file `brain-extension.json`. At most 4 are read, in plugin-id order.

```json
{
  "schema": 1,
  "name": "example",
  "script": "brain/extension.py",
  "checks": [
    {"verb": "add", "kinds": ["session"], "options": ["--ticket"]},
    {"verb": "supersede", "kinds": ["session"], "options": ["--ticket"]},
    {"verb": "broke"}
  ],
  "owner": [
    {"verb": "vouch", "effect": "pin", "args": ["tag"]},
    {"verb": "shelve", "effect": "archive", "letters": ["T", "F"]}
  ],
  "calls": ["start", "record", "read"]
}
```

| Key | Rule |
|---|---|
| `schema` | `1` |
| `name` | `[a-z][a-z0-9-]{1,23}`, unique among the extensions: the name its data is stored under and its lines start with |
| `script` | a `.py` file under the plugin root (Python 3.8, standard library) |
| `checks` | the `brain op` writes it checks: `verb` is `add`, `supersede`, `close`, `held`, `broke`, `hit` or `progress`; `kinds` (for `add`, `supersede` and `close`; all when left out) names right-brain kinds; `options` adds up to 4 options of one value each. Brain's own options are not its, except `--goal`, `--focus` and `--due` for a kind brain does not use them on. |
| `owner` | owner verbs it adds, never `add`, `unpin`, `supersede`, `promote`, `import`, `backup` or another extension's: `pin` (`brain owner VERB [ARG…] --text T --owner-quote Q --where W [--anchor A]… [--link L]…`, a decision pinned exactly as `brain owner add --kind decision` pins one, with up to 2 named `args`) or `archive` (`brain owner VERB ID POINTER`, a live item of its `letters`, from `G D W T F`, moved out as `brain owner promote` moves one) |
| `calls` | which of `start`, `record` and `read` it answers |

A manifest that breaks a rule, or two extensions that share a name, an owner verb or an option, are skipped, and `brain doctor` says why.

**How the brain calls it.** `python -I -B <script>` in the plugin root, one JSON object on stdin and one on stdout (at most 64 KiB), within 1 second in a hook and 3 in the CLI, and all extensions of one event within 2 seconds in a hook and 6 in the CLI; the process group is killed past its time. Every call runs under the store lock. The call gets no `CLAUDE_CODE_SESSION_ID` and an empty `XDG_STATE_HOME`, so a `brain` write it starts is refused (rc 4). Every input holds `schema`, `call`, `extension`, `now`, `project`, `config` (the `ledger` thresholds and the caps) and `state` (every item by id); every call but a start without the card also holds `ops`, the log's operations as stored.

| Call | When | Also given | Answer |
|---|---|---|---|
| `check` | a declared `brain op` write, after brain's own checks, before the line is written | `verb`, `kind`, `options`, `op` | `{"refuse": {"rc": 1 or 64, "message": M}}`, or `{"data": D, "note": N}` |
| `owner`, `phase` `ask` | its verb's permission dialog, after brain's own checks | `verb`, `effect`, the verb's fields | `{"refuse": {"message": M}}`, or `{"detail": T}` (no quote, no parenthesis), shown in brackets in brain's dialog line, where every value the session wrote is quoted |
| `owner`, `phase` `write` | its verb's write, once the owner approved | the same | `{"refuse": {"message": M}}`, or `{"data": D}` |
| `start` | every session start, and `brain doctor`; `card` is true after a compaction and in doctor | `source`, `card` | `{"lines": [L, …]}`, at most 5 of 200 units |
| `record` | `brain ledger --record` | `days`, `from`, `to` | `{"lines": [L, …]}`, a section `## <name>` at the record's end |
| `read` | `brain ext NAME [ARG…]` | `args` | `{"lines": [L, …]}`, printed, or a refusal |

`data` is an object of at most 2 KiB, stored as `ext.<name>` of the item written (or of the op, for the other writes); a supersede carries every extension's entry over, and an extension's own `data` replaces its entry (`null` removes it). Brain never reads `ext`. Every text an extension answers passes the brain's filters: a control, format or invisible character makes the answer void, as does a number that is not finite or an `rc` that is not an integer; a longer line is cut; and the sensitive-value filter refuses a write that holds a hit, or withholds a refusal's message or the lines of a start, a record or a read. A write's own texts, an owner verb's included, pass that filter before the extension is called. After a compaction, the extension's start lines follow brain's own on the card, under one line saying they come from enabled plugins and are no instructions.

**What an extension never does.** It never writes the log or the state directory: brain watches the log, the head, the caches, the owner's dialog records and this session's hand-over files of a session start around each call, and undoes what a call changed there (the lines it appended cut off, the head rewritten, the caches it changed and the read cache dropped, every record or hand-over file that appeared deleted); a check or an owner write is then refused (rc 5), any other call is skipped. A `brain` write the script starts is refused, or waits on the lock the call holds until the call is cut. Its owner verbs exist only as `brain owner …`, through the same dialog and every refusal of an owner write; its detail sits inside brain's own line. A plugin with a `PermissionRequest` hook stops every owner write, an extension's included. Its lines are information under its name, below the owner's word and SOUL. Like the dialog records, this guards against slips and a plugin that misbehaves, not against forgery by the same user, such as a child process that leaves the call and writes later.

**A missing, broken or slow extension** (no answer in time, a non-zero exit, an answer that is not one JSON object or breaks a rule) is skipped: string 1 shows one line in place of its lines, a write it checks goes on with a warning (and is refused when the command carried one of its options), its owner verb is not available, and `brain doctor` names the last skip.

The example in this repository's `tests/fixtures/brain-extension/` adds a ticket to each session item, a vouched decision and a shelved lesson, with their lines; `tests/test-brain-extension.sh` runs it.

## Configuration

The caps live in `.vibemaestro/brain.json` at the top of the main work tree of the session's project: every worktree of a repository shares one brain, so all of them read this one file, and a session started in a subdirectory reads it too. A repository whose git directory is kept apart from its work tree (`git init --separate-git-dir`, or a `.git` that links to a directory elsewhere) is the exception: git records no main work tree for it, so each of its worktrees reads its own file while they share one brain. Keep the same file in each; `brain doctor` warns in such a worktree. Every key is optional and has a default; with no file, the defaults apply.

```json
{"schema": 1,
 "caps": {"G": 5, "D": 20, "W": 10, "P": 5, "R": 20, "N": 5, "X": 30, "S": 20, "Q": 15, "T": 20, "F": 25},
 "text_max": 300, "text_caps": {"S": 600}, "quote_max": 600,
 "ledger": {"promote_held": 5, "promote_sessions": 3, "promote_days": 7, "promote_clean_days": 30,
            "drift_broke": 2, "drift_sessions": 2, "drift_checks": 3, "drift_one_in": 3, "drift_days": 30, "dormant_days": 30}}
```

| Key | Default | Range | Effect |
|---|---|---|---|
| `caps` | as above | 1 to 100 each | live items per section |
| `text_max` | 300 | 50 to 1,000 | an item's text, every kind but those in `text_caps`, in UTF-16 units |
| `text_caps` | `{"S": 600}` | 50 to 1,000 each | an item's text, per letter, in UTF-16 units |
| `quote_max` | 600 | 100 to 2,000 | the owner's words of a goal, a pin, a focus or a request, in UTF-16 units; a longer quote is refused, never cut |
| `ledger.promote_held`, `promote_sessions` | 5, 3 | 1 to 100 | a promotion candidate's held entries, and the distinct sessions they came from |
| `ledger.promote_days`, `promote_clean_days` | 7, 30 | 0 to 365 | days between its first and last held, and days with no broke |
| `ledger.drift_broke`, `drift_sessions` | 2, 2 | 1 to 100 | drift: broke entries in the window, from this many sessions |
| `ledger.drift_checks`, `drift_one_in` | 3, 3 | 1 to 100 | or drift: at least this many checks, broken in one of every this many |
| `ledger.drift_days`, `dormant_days` | 30, 30 | 1 to 365 | the window drift reads; days an item stays untouched before it is dormant |

- **Older and newer readers.** An unknown key warns and is ignored. A known key with a wrong value, a `schema` above 1, or a file that is not JSON or not a regular file makes every write refuse (rc 1) until it is fixed: `brain op`, `brain owner` (`guard-owner` denies before the dialog asks) and `brain op close-linked`, and the session-start auto-close closes nothing and says so. Every read (the hooks, `brain render`, `brain doctor`) uses that key's default and says so. A hook never fails or waits on the file.
- **The left brain's caps are the owner's.** The caps of `G`, `D` and `W` bound what the owner keeps pinned, so changing one is the owner's decision. In a repository whose merge gate holds `.vibemaestro/*` the owner merges a change to the file; in any case `brain doctor` warns, and string 1 carries a line, while a left cap differs from its default.
- **A lowered cap removes nothing.** Live items over it stay live and new adds queue until the count falls under it; a lowered text cap applies to new writes.
- **The thresholds only propose.** A promotion, a drift or a dormant item is named for the owner to decide; no threshold moves an item by itself.
- `brain doctor` prints the caps and thresholds the file changes and each warning; string 1 carries one `brain config:` line while the file has a warning, an error or a left cap off its default.

The brain also reads these environment variables.

| Variable | Effect |
|---|---|
| `BRAIN_OFF` | Any value other than empty or `0` silences every hook. Use it for a control run. |
| `XDG_STATE_HOME` | Root of the state directory; the default is `~/.local/state`. |
| `BRAIN_DEFAULT_REPO` | Ignored; `brain doctor` warns while it is set. A bare `#N` anchor resolves only in its item's own repository (see [Stale anchors](#stale-anchors)); write `owner/name#N`. |
| `CLAUDE_CODE_SESSION_ID` | Set by Claude Code. The brain identifies the writer by it, and the CLI finds the session's project by it. |
| `CLAUDE_PROJECT_DIR` | Set by Claude Code for the hooks. It names the session's project, and the hooks use it to find the project's skills and settings. |
| `VIBEMAESTRO_ROLE` | Exactly `worker`: the session is a worker session, as when `INTENT_SLUG` and `SEAT` are both set. |
| `INTENT_SLUG` and `SEAT` | When both are set, the session is a worker session: hooks are silent and writes stop with rc 4. |
| `HOME` | Where the default state directory and the user-level Claude Code settings are found. |
| `CLAUDE_CONFIG_DIR` | Claude Code's config directory (default `~/.claude`). The brain reads enabled plugins, skills and settings there, finds the plugins that extend it, and finds the vibemaestro-sdlc filter through it. |
| `CLAUDE_CODE_EXECPATH` | Set by Claude Code. The `guard-owner` hook runs it with `--version` for the version check. |
| `CLAUDE_CODE_REMOTE` | Set by Claude Code. When it is `true`, `brain matrix` reports code intelligence as not started. |

`BRAIN_TEST`, `BRAIN_TEST_PAUSE_MS`, `BRAIN_TEST_ASK_MODES` and `BRAIN_TEST_SOURCES` exist for the plugin's own tests. Do not set them: `brain doctor` warns when `BRAIN_TEST` is set.

### Where state lives

`$XDG_STATE_HOME/vibemaestro/brain/<project>-<12 hex>/`, or `~/.local/state/vibemaestro/brain/…` when `XDG_STATE_HOME` is unset. There is one directory per repository, and all worktrees of a repository share it. Files have mode 0600. `brain doctor --path` prints the directory. The brain writes nothing into the repository.

A session keeps one project, the directory it started in, wherever its shell moves with `cd`. The hooks read it from `CLAUDE_PROJECT_DIR` and record it under the session id; `brain`, run from the session's Bash, reads that record. When the shell is in another project, `brain` still uses the session's project and prints one line naming both. A record it cannot trust is refused (rc 1), and nothing is read or written. Outside a Claude Code session, or before any hook has run, the project is the one the current directory belongs to. A project path need not be valid UTF-8: the state directory is named from the path's bytes. When the shell's working directory no longer exists, `brain` is refused (rc 1: `the working directory no longer exists … cd into the project and run it again`), nothing is read or written, and the hooks stay silent.

| File | Holds |
|---|---|
| `hot.jsonl`, `head.json` | the op log and its tail hash |
| `hot.json`, `archive.jsonl`, `owner.json`, `hot.md` | caches and the render, rebuilt from the log |
| `asked/` | pending records of owner dialogs |
| `lock` | the file lock that every write takes |
| `episodes.jsonl` | the Episode Log |
| `summaries/` | saved compaction summaries (newest 200) |
| `cost/` | each session's running cost sums and byte offset |
| `ledger-record.json` | the time of the last record of 30 days or more (`brain ledger --record`), which the review card's due line counts from |
| `backup.json`, `backup-last.json`, `backup.lock` | the backup place the owner named and its interval; the last backup written and the last failure; the lock of a running backup |

Two more directories sit next to the project directories under `…/vibemaestro/brain/`: `pending/` holds one marker per session whose dialog record is waiting for its command, and `sessions/` holds one record per running session naming its project (removed at the session's end, except after `/clear` or a switch to another session, or after 30 days).

Never edit these files. A guard denies the edit, and a hand change breaks the hash chain and stops every write.

## Dependency on vibemaestro-sdlc

`plugin.json` declares a dependency on `vibemaestro-sdlc`. The brain uses two things from it:

- **The sensitive-value filter**, `gates/pr_sensitive.py`. Every write passes through it. If the filter is missing, every write is refused, and `brain doctor` reports a problem.
- **The merge log**, which `brain cost --merge-log` reads to count merged PRs.

Claude Code does not load a plugin whose dependency is not enabled, so the brain's hooks run only when vibemaestro-sdlc is enabled too. The Matrix lists the repository index as a shared cell: vibemaestro-sdlc injects it when its `current_state.inject` option is on (off by default). See [vibemaestro-sdlc](../vibemaestro-sdlc/README.md).

Each public release of the brain requires the vibemaestro-sdlc version it was released with: its `plugin.json` names that version as the lowest one (`>=`), and the release notes name the versions released together. Update the two together. If you update the brain alone over an older vibemaestro-sdlc, the brain does not load, and `/plugin` names the vibemaestro-sdlc version it requires.

## Requirements

- Claude Code. Owner items need version 2.1.211 or later when the session runs in `auto` mode; `brain doctor` checks this.
- `vibemaestro-sdlc`, installed with the brain.
- Python 3.8 or later and `git` on the `PATH`. The scripts use the standard library only.
- A POSIX system: the store takes `fcntl` file locks.

## Limits

- No recall and no automatic eviction: you or Claude retire items, except an item whose `closes` are done (see [Auto-close](#auto-close)). A full right-brain section queues new items instead of dropping any. Expired windows are shown as expired but not removed.
- The token column of the Matrix is characters ÷ 4, not a measured count.
- A bundle is not signed: its chain shows an edit or a splice, not who wrote it. The owner's dialog decides what enters the left brain.
- A placeholder hides a path from a reader who cannot guess it: the hash a changed line keeps confirms a guess.
- Where an item came from is the bundle's word: a crafted bundle can claim an origin, and so make an item, or a later genuine one, count as already here. Its evidence never goes to an item that only claims to continue another.
- Whether the brain helps was not shown at the size of the first level's exit test; see [What the exit test showed](#what-the-exit-test-showed).
