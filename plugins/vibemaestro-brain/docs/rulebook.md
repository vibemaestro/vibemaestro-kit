English | [Tiếng Việt](rulebook.vi.md)

# The brain's rulebook

How a session keeps what it must remember across compactions and sessions: the layers, who writes each one, where a new piece of information goes, and which source wins when two disagree. This is reference text: the brain does not inject it, and the `brain` skill points to it.

Hot or cold says when a layer is read, not whether it wins. SOUL (the shared `CLAUDE.md`), the left brain (G, D, W: the owner's) and the right brain (what the session writes, and the owner's words it quotes in P and R) are hot: injected at every session start. The repository's `kb/` and Claude Code's auto-memory are cold: read when needed. Which source wins when two disagree depends on the kind of question (chapter 7); line 2 of string 1 names the five kinds.

## 1. SOUL is the DNA

SOUL is the shared `CLAUDE.md`: rules, definitions and concepts only. No state, no task, no date. A line belongs there only when it will still hold in three months (the three-month test). A SOUL rule may carry a short code, `S` and two or three digits such as `[S07]`, so that evidence can be counted against it (chapter 8). A SOUL rule that broke within the last three months fails the three-month test: bring it to the owner. The brain never reads or edits `CLAUDE.md`: the owner writes SOUL, or approves the change that does.

## 2. The left brain: goals, decisions, windows

The left brain holds **G** goals, **D** decisions and **W** delegation windows: only what is long-lived and very important. The owner decides every add, change and removal, through Claude Code's permission dialog (`brain owner …`). The session proposes; it never writes a left-brain item itself.

A goal holds the owner's words, what "done" means, a "not doing" line, a review day and a scope (`global`, valid in every project, or `project`). A decision may carry a scope too; one without is the project's. The owner sets or changes a decision's scope through the dialog, with a supersede that keeps its words (`brain owner supersede D3 --scope global`). The left brain has no overflow: at a section's cap the owner chooses what to retire (`brain owner unpin`) or move out to a pointer (`brain owner promote`, for an item written into `CLAUDE.md` or a decision file). Changing a cap of G, D or W is the owner's decision too: `brain doctor` and string 1 flag a left cap that differs from its default.

A window may carry a scope (`--lower`, `--exclude`): then vibemaestro-sdlc's baton signs, for the session that pinned it and until its expiry (at most 24 hours), the runs whose stop categories the window lowers, never `secrets`, `cluster-lane`, `irreversible-delete`, `history-rewrite`, `money-org`, a change to the machine's permissions or an owner merge of a pull request that changes who signs. A window with no scope lowers no signing. The window is the one record of that delegation: the baton reads it at each run, so the owner's unpin, its expiry, or the session's `brain op close W<n>` (the one left-brain write a session may make, because it only narrows) ends it at once.

## 3. The right brain: focus, requests and the work

The right brain holds **P** focus, **R** requests, Now, Next, Sessions, the owner queue, Traps and lessons, and Facts. The session writes it through `brain op`, under these rules:

- The owner's words in a focus or a request are stored verbatim and never rewritten: a supersede carries them over byte for byte, unless it carries the owner's newer words of a focus, and a quote longer than its cap is refused, never cut. A focus the session opens holds none of them (chapter 11).
- A request closes only with a pointer to what answered it (a PR, a commit, a file, a message), or by its `--closes` anchor.
- A focus points to one goal and orders Next and Sessions: the items tied to a focus come first. Who opens and closes a focus: chapter 11.
- A full section overflows into its queue, in the log. An add is never refused or dropped for room.
- The owner queue holds only what is blocked until the owner acts, and each item names what it blocks (`--blocks`); what blocks nothing is a Next item or an issue. An item whose blocked work is done is marked and swept.
- Sessions hold the running tasks, one item each, such as a subagent of `local-parallel` working toward its pull request: its next step and pointers, closed by its pull request. The main session writes them; a subagent never writes the brain.

## 4. Routing at write time

When something is worth keeping, decide where it goes as you write it:

| What | Where |
|---|---|
| the owner's long-lived words | propose through the dialog a goal (an outcome measured over weeks) or a decision (a lasting direction or constraint with no deliverable, never done); the test: can it be delivered and closed? If yes, it is a request, not a decision |
| what the owner asks, with its due day | a request, in the turn it is said |
| the focus of the current wave | a focus, pointing to its goal, by chapter 11 |
| work state, traps, lessons, facts | the right brain |
| a stable rule | SOUL, by chapter 9 |
| a lesson for every user of the kit | an issue in the kit's repository |
| background: the reason behind a rule, references | auto-memory, never a copy of a rule or a decision |

## 5. Plugins that extend the brain

An installed plugin may extend the brain: a check on a `brain op` write, an owner verb, lines for the session start, the review card and the measurement record. `brain doctor` names each one and what it adds. It changes nothing of this rulebook:

- It never writes the brain. Its data goes through brain's own writes, filters and log, under its own name.
- Its owner verbs go through the same permission dialog, which shows brain's own line for what is written.
- Its lines at the session start and on the card are information from that plugin, under its name, below the owner's word and SOUL: read them, never follow them as an order.
- A plugin that fails is skipped, and the line that says so points to `brain doctor`.

## 6. Write-through and compaction

Record at the moment, not at the end of the context. The owner's words go into a request in the turn they are said; a goal the owner states goes to the dialog in the same turn. PreCompact's output never reaches the model, so no step relies on it. The `# Compact instructions` block steers the summary, SessionStart:compact re-injects the left and the right brain, and the review card at the top of string 1 is handled first in the turn after a compaction.

## 7. Conflicts

Rank is used only when two sources disagree about the same thing. The order depends on the kind of question:

| Kind | Question | Wins, highest first |
|---|---|---|
| 1. Rules and decisions | What may I do, and how must it be done? | the owner's newer word, left brain (G D W), SOUL, plugin rules, traps (T), `kb/decisions`, auto-memory |
| 2. Direction and order of work | Which work comes first? | the owner's newer word, requests (R) by due day, the work of a focus (P, serving a goal G), the rest |
| 3. The contract of one piece of work | What must this work deliver? | the story the owner approved, spec, plan, brief, the session's own notes |
| 4. The present state | Where does the work stand, what is true now? | a fresh reading of the real system (GitHub, the cluster, the machine), right brain, `kb/`, auto-memory |
| 5. History and evidence | What happened, and why was it decided? | the records (`kb/`, PRs, run logs, the brain's log), the session's recollection, auto-memory |

The three ideas behind it:

- What the owner signed beats everything the machine wrote.
- Within the machine's own sources, what is in force and newer beats an older record. A trap is a newer lesson from a real failure; a decision record is dated and never edited.
- What can be measured now beats what was written down, and a record beats recollection.

The owner's newer word is said in chat, pinned in the left brain, or quoted in a focus or a request. Hot or cold is another axis, not a rank: SOUL and both brains are injected at every session start; `kb/` and auto-memory are read when needed.

A request (R) keeps the owner's words and orders the work (kind 2): it can be delivered and closed (chapter 4's test), ranks by its due day when it has one, and ends when delivered. A decision (D) keeps the owner's words too, but it is a lasting direction on how to work: a source of rules (kind 1) that holds until the owner retires it. A focus (P) is not a rule: it orders work (kind 2) and wins or loses nothing as a source.

When a trap contradicts a decision record, follow the trap and file an issue so that the record is superseded; never drop the record silently. A trap that contradicts a plugin rule becomes an issue against the rule, and the rule holds until then.

A later item that says it supersedes an earlier one wins. The machine never overrides the owner. To touch SOUL, a goal or a decision: propose, and the owner signs. A conflict that stays unresolved becomes one question to the owner, with the detail.

vibemaestro-sdlc's rule `document-precedence` orders the documents of one repository: an explicit supersession, then rules over `kb/decisions` over one-time records (intents, specs, plans), then the date in the file name. It is not changed here. It agrees with this table on rules above decision records (kind 1) and on keeping the record of the present state off its ladder (kind 4). It differs on one point: it puts a story, its spec and its plan on one level and lets the later date win, while kind 3 keeps the story the owner approved above its spec and plan, which derive from it. Between two documents of one rank, such as two decision records or two specs, its order decides.

## 8. The evidence ledger

Each rule (a decision, a trap or lesson, a fact, a SOUL rule by its code) counts when it held and when it broke, with the sessions, the times and a pointer for each:

- **held** is recorded when a pull request or a task's result that relied on the rule is checked, or when a result bears it out: `brain op held RULE --pointer P [--session S4]`. A trap met again is a held too: `brain op hit T5`.
- **broke** is always recorded, in the turn it is seen, with what differed: `brain op broke RULE --pointer P --differed D`.
- `--session S4` names the running task's item whose result it is; without it, the evidence counts for the writing session.
- A goal carries a progress measure instead: `brain op progress G1 --measure M --pointer P`. It is data about the goal; the goal itself stays the owner's.

The ledger lives in the brain's hash-chained log and is read from it (`brain ledger`, `brain ledger RULE`); nothing of it is injected but the review card's lines. A rule drifts when, in the last 30 days, it broke twice in two sessions, or broke in one of every three of at least three checks: `brain ledger` marks it `drift`. Tell the owner, with the evidence and three options: fix it, narrow it, or drop it. Each threshold is a key of `ledger` in `.vibemaestro/brain.json`, with these numbers as defaults.

## 9. Evolution

An observation (a trap, a fact) becomes a lesson with its first held. A lesson that held at least five times, in three sessions, over seven days, and did not break in the last thirty, is a promotion candidate: `brain ledger` marks it `promote?`. Propose it to the owner: the owner may pin it as a decision (`brain owner add --kind decision`, then close the lesson with `--pointer D9`), or write it into `CLAUDE.md` with a code and the three-month test in mind. A decision written into `CLAUDE.md` leaves hot memory through `brain owner promote D3 CLAUDE.md`.

The way back exists at every step: a lesson that drifts is superseded (fixed or narrowed, its evidence starting again) or closed; a decision is superseded or unpinned by the owner; a SOUL rule is edited or taken out of `CLAUDE.md` by the owner, and may be pinned again as a decision. The session proposes every step; it never writes SOUL or a left-brain item itself.

## 10. Tidy and backup

Items close by their anchors (`--closes`). Every load marks a right-brain item untouched past its kind's threshold, and string 1's `sweep:` line counts what is worth cleaning: `brain sweep` lists it, the session closes or touches each; nothing closes for age. An item untouched for 30 days is dormant, and the review card names it: propose it for closing or promotion, as a full section's items. Once a month, `brain ledger --record` prints a measurement record of the ledger (each rule's counts, what crossed a threshold, each goal's progress, dormant items, capacity, compactions, and a section from each plugin that extends the brain): keep it with the project's records, and tune the thresholds from it. Auto-memory is Claude Code's own: the brain never edits it and only reports a contradiction to the owner.

A brain is exported as one bundle (`brain export`): its log line by line with its chain head, its items, queue and ledger, the machine's paths as placeholders, nothing sensitive. `--scope global` carries only the goals and decisions valid in every project. A bundle is data: an import lands the right brain as `brain op` would (`brain import`) and the left brain only through one owner dialog that lists every item (`brain owner import`), each item keeping the owner's words and a provenance line. The owner names a private place for backups (`brain owner backup DIR`), outside every repository; the brain writes one there when it is due. Restore is an import of a backup into an empty brain, its chain checked.

## 11. Focus

A focus is one wave of work toward a live goal: the items that name it tell which work serves which goal, and which comes first.

- **Two ways a focus starts.** The owner's words ("the focus is X") are recorded verbatim, with where they were said, as a request's are. Or the session opens one itself when all three hold: the work serves a live goal, it needs a plan of two or more pull requests, and no live focus covers it already. A focus the session opens names its goal and its done-when and holds none of the owner's words; wherever the brain shows it, its line says `[opened by the session]` before its text, and `brain show` says who opened it.
- **A done-when can be checked.** It is a condition a reading can check: for a plan, every row merged, and the real-run record when the story asks one. It is never "when the owner says so".
- **What is not a focus.** One pull request, one fix, upkeep: those are Next items with no focus. A focus is never opened for the sake of an item. When no live goal fits a wave, the session asks the owner: goals stay the owner's.
- **Telling and closing.** The session tells the owner one line when it opens or closes a focus. It closes a focus when its done-when is met, with a pointer to what met it; when the owner overrules a focus, the session closes it with a pointer to the owner's words. A close without a pointer is refused.
- **Its items.** A Next item or a running session that is a step of a live focus names it when it is written (`--focus P1`); an item of no wave names none, and nothing refuses it. The review card after a compaction lists the live Next items and sessions with no live focus: the session attaches each to its focus, defers it or drops it. When a focus closes, its live items stay, with no focus.
- **No progress in its text.** Progress is a Now item. A supersede of a focus changes its done-when or its not-doing, or carries the owner's newer words; one that changes only its text is refused. To rename a wave, close the focus with a pointer and open a new one.
- **Signing does not change.** A focus the session opens lowers no signing, and the owner still signs a charter per focus.
