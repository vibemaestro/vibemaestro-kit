---
applyTo: "kb/**,docs/**,${rules.dirs}/**"
description: "When two documents disagree: an explicit supersession wins, then the binding level (rules, decisions, one-time records), then the date in the file name; current-state answers a different question"
---

# Two sources disagree: which one wins

Documents are not updated together: a change to a rule rarely touches an old spec, and an old spec owes nobody an update. A conflict is therefore normal, and the reader must settle it in a minute without asking. Read this before you cite a document as the ground for a change. Stop at the first step that answers.

1. **An explicit statement wins.** A decision with `status: superseded` in its frontmatter (the engine stops delivering it), or a block under a heading saying "superseded (date)" with a link to the current text, has lost. The author knows; the reader only guesses.
2. **Binding level beats date.** Rules (what must be done) over decisions in `kb/decisions/` (a considered choice with the alternatives that were dropped; to change one, bring a new measurement) over one-time records (`kb/intent`, `kb/specs`, `kb/plans`, snapshots taken when they were decided, which owe nobody an update). A newer one-time record never overrides a rule: it can only justify a PR that edits the rule file.
3. **Same level: the date in the file name** (`YYYY-MM-DD-slug`). Not `git log -1`: it says when the file was last touched, and a typo fix is not a decision.

Two rules that contradict each other have no step 3: it is a bug to fix in the PR you are working on. Find the sentence that is wrong and delete it; do not rank them by date.

The ledger (`kb/current-state.md` and the pages it points to) is not on this ladder. It answers *how things are now*, not *what to do*, and every file of it must always be true. Found stale, fix it in the PR you are in; never follow a newer document and leave the ledger wrong.

Leave a trace in the PR that met the conflict:

1. The loser gets a supersession statement pointing to the current text. Do not delete it: others link to it.
2. Sweep for other copies of the old decision with a pattern that you first ran on one certain positive; a phrase search misses copies that say the same thing in other words.
