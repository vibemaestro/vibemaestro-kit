---
applyTo: "kb/current-state.md"
description: "The shape of kb/current-state.md: only the present state, overwritten and never appended, no history, no how-to; detail goes to specs/decisions; it has a size cap and a checker"
---

# The shape of `kb/current-state.md`

A session reads this file FIRST, so a spare line is wasted context. It answers one question: **how is this repo right now?** Not "how it got here".

- **It is the map, not the library.** Each line says what holds and points to where the detail lives; a session finds documents with
  `kb.py find <words>` and reads one section of a long spec through `kb.py outline <file>`, so nothing here copies them.
- **Only the present state.** Each line is a claim that is true RIGHT NOW ("X runs on Y", "Z is handled by W").
- **Overwrite, do not append.** When the system changes, correct the old line; do not add a line "changed from A to B".
- **NO history:** no measurement dates (a `current_state.labels` label's date is a clock, not history), no PR/issue numbers (`#NN`), no "formerly…", no change log; history is in `git log`.
- **NO how-to, NO experiment numbers:** the commands run, the reason for a choice, the alternatives dropped and the measurements live in `kb/specs/`
  and `kb/decisions/`. Current-state only points to them by path.
- **Not built yet / switched off** is a present state: write it plainly ("No CI for X yet"), without saying why.
- **Size cap** (the checker catches it): ≤ 120 lines, ≤ 12,000 bytes, each line ≤ 200 characters, a page its own cap; from 85% of a cap the
  checker prints `WARNING` (overwrite, do not append). Over a cap: detail is in the wrong place — move it to a spec/decision, do not raise the cap.

The checker: `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/kb.py" check current-state` (red on a sign of history, over a cap, an orphan page, a dead pointer).

## Where content goes

The ledger (this index and the pages of `current_state.pages` it points to) is not a place for rules: the index has no `applyTo`, and a page's `applyTo` only names the area it describes, so a rule written there reaches the session as state, not as a rule. Content travels by its type:

| Content | Place |
|---|---|
| an invariant when USING a component (call, command, limit, trap) | the skill or README of that component, read when it is used |
| an invariant when CHANGING an area ("do not break this") | a rule with `applyTo` for that area, or a decision in `kb/decisions/` with `applyTo` |
| why this choice, and the alternatives dropped | `kb/decisions/` |
| design, measurements, acceptance of one intent | `kb/specs/` |
| commands run and results for this PR | the PR body, section `tokens.evidence_heading` |
| history of changes | `git log` |
| process, how to | a rule or a skill |

A number that a command can count: write the command, not the number.
