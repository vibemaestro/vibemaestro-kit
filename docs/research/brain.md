English | [Tiếng Việt](brain.vi.md)

# Brain research: what is known about compaction and the brain

This page states what is known about `vibemaestro-brain` and about Claude Code's compaction: what each finding is, the
conditions it holds under, and what is not shown. For the design of the brain, see
[the brain plugin README](../../plugins/vibemaestro-brain/README.md).

**Labels.** A number marked **docs** comes from the Claude Code documentation; **design value** is a number chosen in the
design, not measured; *not checked* is stated or suspected, never verified. Every other number was measured by the kit.

**Terms.** The probe forks one session into two arms: arm H with the brain on and arm C, the control, with the brain off. Its
exit codes: 0 pass, 1 fail, 2 stopped or void, and 3 when C also scores 10/10, so the brain is not shown necessary. The
Shelf index is the skill list the brain re-injects.

## Findings

| Question | Finding | Conditions |
|---|---|---|
| Where does the token cost of a long-running session go? | 64% cache read, 24% cache write, 12% output; the context averages about 413k tokens per call (max 936k) | one session of 2.4 days and 2,089 main-thread calls; weights assumed (cache read 0.05×, 1-hour cache write 2×, output 5×) |
| Does idle compaction fire in such a session? | 0 of 8 idle gaps over one hour; each gap is followed by a full context re-write of 200–680k tokens | idle compaction is on by default from Claude Code 2.1.290 (**docs**); the session ran 2.1.299 and 2.1.301; the cause is *not checked* |
| Can a hook see how big the context is? | the tail of the transcript carries `usage` records, and `CLAUDE_CODE_SESSION_ID` is in the session's Bash environment, so a hook can read them | one reading, taken from the session's Bash environment, not from inside a hook; the transcript may lag the current turn (**docs**) |
| What does a compaction drop that a long-running session needs? | the transcript logs the skill list once, at session start, and none after a compaction; a re-injection cut at a fixed length can lose the one line that names a skill | one session; whether the model still sees the list in each request is *not checked* |
| Does `brain cost` count tokens right? | it matches an independent count field by field; a parser that sums every `usage` record counts most calls twice, because each content block repeats its response's `usage` | one transcript |
| How slow are the brain's hooks? | medians: session-start 62.6 ms, guard-edit 38.1, guard-bash 14.7, guard-owner 13.9 (starting Python alone: 10.3) | one machine, 40 runs per hook |
| Does the owner dialog show and write as designed? | `acceptEdits` and `auto`: the dialog shows, the line is whole, the item is written; `dontAsk`, `plan` and `-p`: nothing written | one machine, Claude Code 2.1.302; the runs meant for `default` ran as `auto`, that machine's default; `bypassPermissions` not tested |
| Can a script drive a real compaction? | yes: auto-compaction at the 100k window floor, or headless `/compact`; the block that `SessionStart:compact` leaves is read after `--resume` | the block is stored in the transcript as a `hook_additional_context` record |
| What does the sdlc dependency cost inside the probe? | under `--setting-sources project,local` the installed sdlc is not enabled, so Claude Code does not load the brain; unsilenced, sdlc adds 11,276 characters per session start | Claude Code 2.1.303; the token cost of those characters is arithmetic at 4 characters per token |
| After a real compaction, does the brain keep decisions the summary loses? | arm H 10/10 and arm C 10/10 in each of 3 runs: exit 3, the brain is not shown necessary at this size | one compaction, 10 decisions each with a floated near miss, about 225k tokens of context; the block stays at 1,688 characters, under the 8,000-character cap |
| Does SessionStart context survive `resume` and `clear`? | `resume` keeps it: it is stored in the transcript chain; `/clear` empties the context | `clear` from the **docs**, not measured |

## How the probe runs

Each run plants 10 owner decisions, each with an exact anchor, plus one owner turn per decision that floats a near miss as
"not decided". Filler brings the context to about 120k tokens (**design value**). The session is forked twice from one point,
so both arms share every byte before the compaction; each arm is compacted, at the 100k auto-compaction window floor, behind a
neutral step. The 10 questions are asked in a second process, so the compaction never sees them, and a script grades the
answers by exact anchor, never a model. The runs use Opus, 3 runs per probe.

## What follows from it

- The dominant cost of a long session is re-reading a big context on every call, so the brain's job is to make early
  compaction safe, not to avoid compaction. `brain cost` uses the weights above.
- The brain re-lists skills itself (the Shelf index, at every `SessionStart`, at most 1,000 characters: **design value**), and
  a re-injection must not cut the lines that matter.
- `brain cost` counts one call per `message.id`.
- The probe compacts behind a neutral step and asks its questions in a second process, so the compaction never sees them. Each
  probe session loads sdlc with its hooks silenced (`.vibemaestro/sdlc.json` `{"hooks": "off"}`), and the preflight checks the
  brain's manifest dependencies before anything is spent.
- The live owner-dialog test picks every menu option by its text and the cursor, never by position.

## What is not shown

- **That the brain is needed.** At one compaction and 10 decisions, Claude Code's own summary kept every decision.
- **Several compactions in a row**, more decisions, and decisions older than what one summary keeps.
- **A user-level `# Compact instructions` block** compared with no block and with the brain.
- **Why idle compaction does not fire**, and `brain cost` reproducing the cost split above on that session's transcript.
- **Forgetting by itself over a day**, and a lower cost per merged PR.
- **`bypassPermissions` and `default` itself** in the owner dialog.
- **Whether the model still sees the skill list** after a compaction: the transcript logs attachments only.
