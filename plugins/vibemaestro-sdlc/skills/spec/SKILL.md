---
name: spec
description: "Use when: the intent of an app repo is recorded (kb/intent/<date>-<slug>.md, branch intent/<date>-<slug>) and there is no spec the person has approved yet — create kb/specs/<date>-<slug>.md in the four-section shape, commit it to the intent branch, then ask the person to approve (session-ask in a sandbox, ask directly in a solo session) BEFORE editing code."
---

# spec — design an intent and ask the person to approve before code

The intent says **what the person wants**; the spec says **what is correct and which command proves it**. The person approves the spec
**before** the first line of code: approving one page of text is much cheaper than reviewing a PR that was built in the
wrong direction. The spec shape is the four-section shape recorded in this repo's own `kb/README.md` (built by `init-kb`).

Condition: an intent exists (`vibemaestro-sdlc:intake`) and you stand in the worktree of the branch `intent/<date>-<slug>`.
If not, do `intake` first.

## Do

1. **Create the skeleton file** — the same `<date>-<slug>` as the intent, so the two files go as a pair:

   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/kb.py" new spec <slug> --date <date>
   ```

   The command creates `kb/specs/<date>-<slug>.md` in the four-section shape `## Context`, `## Goal`, `## Out of scope`,
   `## Acceptance criteria` and points `Intent:` at the intent file if it already exists. Link it back: add `spec: kb/specs/<date>-<slug>.md`
   to the intent's frontmatter (and the intent's `plan:` line, if it has one, to the spec's) and commit the intent with the spec.

   **The section names come from the repo's config** (`tokens.spec`): with `"language": "en"` they are `## Context`, `## Goal`,
   `## Out of scope`, `## Acceptance criteria`, the optional `## Design`, the last criterion names `## Run evidence`, and the
   blanks are `<FILL: …>`. The English names in this skill are the ones of `"language": "en"`; a repo on the default `vi` language has
   Vietnamese names, which `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/sdlc_config.py" get tokens.spec` prints; where the repo says otherwise,
   keep the names the generated template carries, which are the ones `kb.py check spec` requires. The check counts the placeholder of every
   language (`<FILL`, and the Vietnamese one that `tokens.spec.placeholder` holds by default), so a spec that writes about one quotes the word without its `<`.

2. **Fill in** — only from the intent and, if the intent has a `## Brainstorm result` section (written by `vibemaestro-sdlc:brainstorm` or by the
   handover package), take **what was settled, the constraints, the option chosen/rejected** from there (into `## Context` / `## Goal`; the option
   chosen/rejected into `## Design` if the spec is large). **Add no idea of your own** and do not widen the
   scope beyond the person's words. If the spec needs a piece of information that is missing, write it down as a question for the person in step 4;
   do not guess.
   - `## Acceptance criteria`: each criterion is **one command + the expected result** (``1. `bash t.sh` → `0 fail` ``),
     not a description. **The last criterion is always: the PR has a `## Run evidence` section** holding the real output of the commands above.
   - A large spec gets a `## Design` **after** the four sections (the direction chosen, the options rejected, why); minor points inside it go
     in as `###`. Add no other `## ` section — the machine will report it as an unknown section.
   - Delete every `<FILL: …>`; the `description:` line in the frontmatter is a one-line description.

3. **Check the shape by machine** and fix until rc `0`:

   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/kb.py" check spec <date>-<slug>
   ```

   This command checks only the **shape**: all four sections in the right order, none empty, no `<FILL` left, every criterion has a command
   in backticks, the last criterion mentions `## Run evidence`. It does **not** know whether a command is right or runs, and
   it is **not** a gate: nothing stops you editing code before you have run it — keeping the discipline is your job.

4. **Commit, push, then ask the person to approve** (one commit, `git add` by pathspec):

   ```bash
   git add kb/specs/<date>-<slug>.md
   git commit -m "docs(kb): spec <slug>"
   git push origin intent/<date>-<slug>
   ```

   Ask for approval **after** pushing, so that the person can read exactly that file:
   - In a sandbox session (`INTENT_SLUG` and `SEAT` both set and not empty, checked by
     `[ -n "${INTENT_SLUG:-}" ] && [ -n "${SEAT:-}" ]`; a `session-ask` on PATH does not make a session a sandbox), when the `session-ask` command is installed, call
     `session-ask "Spec kb/specs/<date>-<slug>.md is pushed to intent/<date>-<slug>. Approve so I can start coding, or name what needs changing. Open points: <…>"`
     then **end the turn** and wait for the person's message. The command records the `waiting` status so that the person is woken up; the session stays alive.
   - Otherwise (a solo session, or a sandbox without the `session-ask` command), give the spec path in your reply and ask the person right in the session.

5. **No code edit without an approval.** Approval is **the person's reply** through the person's channel; the machine has
   no "approved" mark, and silence is not approval. If the person asks for the spec to change, change it, run step 3 again, commit,
   push, ask for approval again. With an approval, first run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/stage-signal.sh" code` (the sandbox dashboard
   shows coding started; the command does nothing without a sandbox and never fails), then carry on: `vibemaestro-sdlc:plan` if the work must be split, or code in this
   worktree and then `vibemaestro-sdlc:ship`. While working, if you find the spec wrong, fix the spec in a commit of its own and tell the person;
   do not silently work differently from the spec.
