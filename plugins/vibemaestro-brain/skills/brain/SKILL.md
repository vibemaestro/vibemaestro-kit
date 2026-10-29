---
name: brain
description: "Use when: a long-running session must keep a decision, a delegation window, the current task, the next steps, a trap, a running session, what waits on the owner or a fact across compactions — add, close or supersede items with `brain op`, write the owner's own decisions and windows with `brain owner` (through Claude Code's permission dialog), re-claim the brain after /clear or --fork-session, or read why a brain command was refused."
---

# brain — hot memory that survives compaction

## Key rules (read these first; this skill is re-injected after a compaction only up to 5,000 tokens)

1. **The brain is re-injected at every `SessionStart`** (startup, resume, clear, compact, fork) as up to three blocks:
   `## Brain · hot memory` (pinned decisions with the owner's quote under each, windows, Now), `## Brain · sessions` (running
   sessions, the owner queue) and `## Brain · plan` (Next, Traps, Done in the last 24 h, Facts). The last two are left out while
   they are empty. Trust them over your memory of the conversation, and keep them true with item operations.
2. **Only two commands change it.** `brain op …` for Now (`N`), Next (`X`), Traps (`T`), sessions (`S`), the owner queue (`Q`)
   and facts (`F`); `brain owner …` for the owner's pinned decisions (`D`) and delegation windows (`W`). Never edit, write or
   redirect into the state directory (`brain doctor --path`): a guard denies the edit, and a hand change breaks the hash chain
   and stops every write (rc 5).
3. **One source: never keep this state in another file.** A memory file or a board beside the brain drifts from it, and
   nothing in it closes when its PR merges. Running work is an `S` item, what waits on the owner a `Q` item, a path or fact in
   use an `F` item. `S`: `<session name>: <next step>`, ≤ 450 characters, with pointers (PR, intent, record) instead of copied
   state, and `--closes` its PR. `Q`: `--closes` the PR or issue it waits on, or `close` it when the owner answers. `F`: paths
   as `~/…` or relative to a plugin root (a home path is refused as sensitive). Done is never written: it is what the log
   closed in the last 24 hours, with the anchor and merge commit first.
4. **Owner words go through `brain owner`, one literal command.** Write the decision text, the owner's quote verbatim and where
   it was said, with no variable, `$(…)`, backslash, glob or redirect, alone in its Bash call and alone in its turn (any
   other Bash call voids the pending dialog's record; no `"` in the text or source). The owner then sees one line
   in Claude Code's permission dialog — `Pin owner decision D3, from "<where>": "<text>"` — and approves or refuses it. No
   dialog, no write: in `dontAsk`, `plan`, `bypassPermissions`, a `-p` run, a subagent, or while a `PermissionRequest` hook could
   answer for the owner, it is refused, and you say so to the owner instead of retrying another way.
5. **Text is a delta, never a rewrite.** A changed meaning is `supersede` (both items kept, every anchor carried over, at least
   60% of the first text unless `--shorter` with a `--reason`). Done work is `close` with a `--reason` and a `--pointer` (PR, SHA,
   file). At most 5 retirements per 30 minutes; a deliberate sweep says `--bulk` (logged). An `S` or `Q` item is status, not a
   decision: its supersede (a new next step) spends no budget and may be shorter, and still keeps every anchor.
6. **Anchors are the exact strings a summary must keep** (a PR number, a 7-hex SHA, a path, a code word): add them with
   `--anchor`. The loss score of every compaction counts how many of them the summary dropped.
7. **A `stale:` mark is a question, not an order.** `· stale: #7 closed 2026-10-20` after an item means its anchor is a closed
   issue or a merged PR. Check, then `close` (with `--pointer`) or `supersede` it with `brain op`; for a pinned `D` item tell the owner, since only
   `brain owner unpin` or `supersede` changes it (`owner retires it`). An item with `closes` closes itself, in the writer's
   SessionStart, once its PR is merged or its issue completed (`auto-closed now:`); never name a dependency or a tracking issue
   in `closes`. `brain doctor` lists them fresh.
8. **One writer per project.** After `/clear` or `--fork-session` the session id changes: run `brain claim --take-over`
   (logged). A subagent never writes: it reports back, and the main session runs `brain op`.

## Commands

| Command | Use |
|---|---|
| `brain op add --kind now\|next\|trap --text T [--anchor A]… [--link L]…` | the current task (≤ 3), next steps (≤ 10), traps (≤ 13) |
| `brain op add --kind session\|queue\|fact --text T …` | running sessions (≤ 12), what waits on the owner (≤ 5), facts and paths in use (≤ 5) |
| `brain op add --kind now\|next\|session\|queue … --closes owner/name#N` | the issue or PR whose close means this item is done (≤ 2, `owner/name#N` or a URL) |
| `brain op close-linked` | after `auto-close held` and `brain doctor`: close every item whose `closes` are done |
| `brain op close ID --reason R [--pointer P]` | done or dropped |
| `brain op supersede ID --text T --reason R` | the meaning changed |
| `brain op touch ID`, `brain op hit ID` | still current; a trap was met again |
| `brain owner add --kind decision --text T --owner-quote Q --where W [--anchor A]…` | the owner decided |
| `brain owner add --kind window --text T --owner-quote Q --where W --expires 2026-10-17T22:00:00Z` | the owner delegated until a time |
| `brain owner unpin ID`, `owner supersede ID --text T`, `owner promote ID POINTER` | the owner retires or replaces one |
| `brain render`, `brain doctor` | see the block; check the chain, files, filter, answerers, version |

Texts are ≤ 150 characters (a session's ≤ 450), sensitive values are refused (masked in the message), and control or invisible
characters are refused. At a count cap an add is refused and names the item to close.

## When a command is refused

| rc | Meaning | Do |
|---|---|---|
| 1 | a rule (cap, budget, sensitive value, character, length) | follow the message; do not split or reword around it |
| 3 | another session writes this project's brain | `brain claim --take-over` if this is the same work continuing after `/clear` or in a fork |
| 4 | a sandbox worker | workers keep no hot memory |
| 5 | the log does not match its head | stop writing; run `brain doctor` and tell the owner |
| 6 | no approved owner dialog | tell the owner; ask in an interactive session in default, acceptEdits or auto mode |
| 7 | no `CLAUDE_CODE_SESSION_ID`: not run inside a Claude Code session | run it from a Claude Code session; do not `claim --take-over` |

## Around compaction

- `PreCompact` logs the trigger and the context size; `PostCompact` saves the summary (never injected) and its loss score in
  the Episode Log (`episodes.jsonl` in the state directory).
- `BRAIN_OFF=1` silences every hook (the probe's control arm).
- The `# Compact instructions` block for a project CLAUDE.md is `templates/compact-instructions.md` of this plugin.
