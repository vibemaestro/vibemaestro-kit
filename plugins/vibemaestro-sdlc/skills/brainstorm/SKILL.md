---
name: brainstorm
description: "Use when: the person gives a request in an app repo that is still vague or needs a direction chosen before the spec is written — \"clarify the request\", \"make a plan\", \"design\", \"redo\", \"add a feature\", a UI change. In an app repo this skill REPLACES the brainstorming skill of the third-party process plugin: the result goes into the \"Brainstorm result\" section of kb/intent/<date>-<slug>.md, no separate spec file is created."
---

# brainstorm — clarify the request before writing the spec

`intake` records the **person's own words** verbatim; `spec` records **what is correct and which command proves it**. Between the two
there is often a gap: the person's words do not say enough to write the criteria. This skill fills the gap with a structured
conversation and leaves **what was settled** in one place that `spec` can read. Settling the direction before the spec is cheaper than fixing
the spec — and much cheaper than fixing code that was built in the wrong direction.

Condition: an intent exists (`vibemaestro-sdlc:intake`) and you stand in the worktree of the branch `intent/<date>-<slug>`; with no intent, do `vibemaestro-sdlc:intake` first.

**Skip this skill** when the handover package already has a "Brainstorm result" section in the intent (it was done already — do not ask the person
again), or when the request already says enough about *what must be true* and *which command proves it*: go straight to `vibemaestro-sdlc:spec`.

**This skill writes no code, builds no scaffold, creates no spec file.** The code written for a spike is throwaway code,
labelled throwaway and not committed.

## Do

1. **Read before you ask.** The intent, `kb/current-state.md`, and enough of the related code that the questions are not silly. What
   can be read, do not ask the person. When the read of the code sweeps many files (a whole module, several directories or naming
   conventions), hand it to a read-only search agent on the configured search model
   (`python3 "${CLAUDE_PLUGIN_ROOT}/scripts/sdlc_config.py" get agents.search_model`, passed as the Agent tool's `model`) and keep its conclusion,
   not the file dumps; re-read yourself the lines a question rests on. A few known files you read yourself.
   If the read fails, use the plugin default (the same command with `--default`), tell the person what
   `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/kb.py" config check` names, and do not edit the config for them; if the
   `--default` read fails too, ask the person which model to use.

2. **Classify, tell the person, wait for agreement.** The test goes from the top down and stops at the first sentence that holds:
   - **Spike** — the question is *is it feasible / is it worth it*. The output is an answer with a recommendation, not code; a few minutes.
     After the spike, classify the real work again (Bounded/Architectural), or stop if the answer is "should not be done".
   - **Architectural** — changes a structure, adds a new component, or touches more than ~3 files / more than a day; high risk, hard to undo.
   - **Bounded** — the rest: small scope, a path already exists, low risk, easy to undo.

   Say one line: *"I classify this as X because …"*. If the person disagrees, classify again; if a wrong classification is found midway,
   change it and say so, do not carry on silently the old way.

3. **Ask ONE question per turn.** Several questions in one turn and the person answers the easy one and skips the hard one. Prefer a question
   with answers to choose from (a/b/c). Order: *what for* → *constraints* (time, cost, technology, what must not be touched) → *success criteria*
   (what the person sees when it is done, which command proves it). Bounded usually takes 1–2 questions; Architectural asks until nothing unknown is left.
   In a sandbox session (`INTENT_SLUG` and `SEAT` both set and not empty, checked by
   `[ -n "${INTENT_SLUG:-}" ] && [ -n "${SEAT:-}" ]`; a `session-ask` on PATH does not make a session a sandbox) and the `session-ask` command is installed, ask with
   `session-ask "<question>"` and then **end the turn** to wait for the answer; otherwise (a solo session, or a sandbox without the command) ask directly in the session.

4. **Propose 2–3 options** — mark them clearly **"Option 1 / Option 2 — pick one"**, do not mix them into one sequential line. For each option: what to do,
   what you gain, what you lose. End with a **recommendation and why**. If a Bounded task really has only one way, say "there is only one way" and
   why; do not invent a second option to make up the number.

5. **Present the design part by part, ask for agreement before the next part.** Bounded: one paragraph of 3–5 sentences (what to change, how, how
   to check, the risk). Architectural: split into parts the person can review separately (components, data flow, error handling, how to check,
   the way back) — put the whole thing in one turn and the person only nods.

6. **Write the result into the intent file ITSELF** — add a `## Brainstorm result` section at the **end** of `kb/intent/<date>-<slug>.md`,
   after the person's words (do not edit the person's words). The heading is in the language of the repo's `kb/` documents (`language` in the config); no script reads it:

   ```markdown
   ## Brainstorm result

   *Classification:* Bounded — <one-line reason>
   *Settled:*
   - <what the person agreed to, stated as a result>
   *Constraints:*
   - <what must not be touched, deadline, cost>
   *Option chosen:* <name> — <why>
   *Option rejected:* <name> — <why rejected>
   *Still open:* <questions for the spec or the person to answer last; "none" if there really are none>
   ```

   Then commit and push (one commit, `git add` by pathspec):

   ```bash
   git add kb/intent/<date>-<slug>.md
   git commit -m "docs(kb): brainstorm result <slug>"
   git push origin intent/<date>-<slug>
   ```

## Do not

- **Do not create a separate spec file and do not write into the default output directory of the third-party process plugin (under `docs/`).** In an app repo the output is `kb/`; the spec is created by
  `vibemaestro-sdlc:spec`, in the four-section shape.
- **Do not add any `## ` section to the spec** from this result — the machine check `kb.py check spec` accepts only the four sections and `## Design`.
  What was settled, `spec` takes into `## Context` / `## Goal`; the option chosen/rejected goes into `## Design` if the spec is large.
  (The section names come from `tokens.spec`: with `"language": "en"` they are `## Context`, `## Goal` and `## Design`; a repo on the default `vi` language has the Vietnamese names, which `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/sdlc_config.py" get tokens.spec` prints.)
- **Do not start coding while the person is reading**, and do not take "agreed with the design" as approval of the spec: approving the spec is a
  separate step of `spec`.

| Temptation | Why it is wrong |
|---|---|
| "This is too simple, skip the design" | A short 3-sentence design still exposes a wrong assumption; skip it and the wrong assumption shows up in the PR |
| "Ask everything in one go to be quick" | The person answers the easy question and skips the hard one; one question per turn |
| "Just a little more to make it whole" | The scope widens silently; what lies outside the person's words goes into "Still open", do not do it yourself |
| "Any option is fine" | With no recommendation the person has to analyse again from scratch |

## Next step

`vibemaestro-sdlc:spec` — create the spec from the intent (including the "Brainstorm result" section) and ask the person to approve **before editing code**.
A spike that concludes "do not do it": write the conclusion into the "Brainstorm result" section, push, tell the person, stop here.
