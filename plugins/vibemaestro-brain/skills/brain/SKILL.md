---
name: brain
description: "Use when: a long-running session must keep a decision, a delegation window, the current task, the next steps or a trap across compactions — add, close or supersede hot memory items with `brain op`, write the owner's own decisions and windows with `brain owner` (through Claude Code's permission dialog), re-claim the brain after /clear or --fork-session, or read why a brain command was refused."
---

# brain — hot memory that survives compaction

## Key rules (read these first; this skill is re-injected after a compaction only up to 5,000 tokens)

1. **Hot memory is re-injected at every `SessionStart`** (startup, resume, clear, compact, fork) as the block
   `## Brain · hot memory`. Trust that block over your memory of the conversation, and keep it true with item operations.
2. **Only two commands change it.** `brain op …` for Now (`N`), Next (`X`) and Traps (`T`); `brain owner …` for the owner's
   pinned decisions (`D`) and delegation windows (`W`). Never edit, write or redirect into the state directory
   (`brain doctor --path`): a guard denies the edit, and a hand change breaks the hash chain and stops every write (rc 5).
3. **Owner words go through `brain owner`, one literal command.** Write the decision text, the owner's quote verbatim and where
   it was said, with no variable, `$(…)`, backslash, glob or redirect, alone in its Bash call and alone in its turn (any
   other Bash call voids the pending dialog's record; no `"` in the text or source). The owner then sees one line
   in Claude Code's permission dialog — `Pin owner decision D3, from "<where>": "<text>"` — and approves or refuses it. No
   dialog, no write: in `dontAsk`, `plan`, `bypassPermissions`, a `-p` run, a subagent, or while a `PermissionRequest` hook could
   answer for the owner, it is refused, and you say so to the owner instead of retrying another way.
4. **Text is a delta, never a rewrite.** A changed meaning is `supersede` (both items kept, every anchor carried over, at least
   60% of the first text unless `--shorter` with a `--reason`). Done work is `close` with a `--reason` and a `--pointer` (PR, SHA,
   file). At most 5 retirements per 30 minutes; a deliberate sweep says `--bulk` (logged).
5. **Anchors are the exact strings a summary must keep** (a PR number, a 7-hex SHA, a path, a code word): add them with
   `--anchor`. The loss score of every compaction counts how many of them the summary dropped.
6. **One writer per project.** After `/clear` or `--fork-session` the session id changes: run `brain claim --take-over`
   (logged). A subagent never writes: it reports back, and the main session runs `brain op`.

## Commands

| Command | Use |
|---|---|
| `brain op add --kind now\|next\|trap --text T [--anchor A]… [--link L]…` | the current task (≤ 3), next steps (≤ 5), traps (≤ 4) |
| `brain op close ID --reason R [--pointer P]` | done or dropped |
| `brain op supersede ID --text T --reason R` | the meaning changed |
| `brain op touch ID`, `brain op hit ID` | still current; a trap was met again |
| `brain owner add --kind decision --text T --owner-quote Q --where W [--anchor A]…` | the owner decided |
| `brain owner add --kind window --text T --owner-quote Q --where W --expires 2026-10-17T22:00:00Z` | the owner delegated until a time |
| `brain owner unpin ID`, `owner supersede ID --text T`, `owner promote ID POINTER` | the owner retires or replaces one |
| `brain render`, `brain doctor` | see the block; check the chain, files, filter, answerers, version |

Texts are ≤ 150 characters, sensitive values are refused (masked in the message), and control or invisible characters are
refused. At a count cap an add is refused and names the item to close.

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
