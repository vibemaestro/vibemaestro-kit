---
name: spec
description: "Use when: the intent of an app repo is recorded (kb/intent/<date>-<slug>.md, branch intent/<date>-<slug>) and there is no approved spec yet — create kb/specs/<date>-<slug>.md in the spec shape (goal, constraints, behaviour-level criteria pointing to the story's AC, risks to cover, open points), commit it to the intent branch, then ask for approval (session-ask in a sandbox, ask directly in a solo session) BEFORE editing code."
---

# spec — derive the spec from the intent and get it approved before code

The intent says **what the person wants** (for a story: the story the owner approved); the spec says **what must be true**, as
behaviour, derived from it, and which risks the tests must cover. It holds no implementation: the how belongs to the plan
(`vibemaestro-sdlc:plan`) or to the session's own judgement. The spec is approved **before** the first line of code: approving two
pages is much cheaper than reviewing a PR built in the wrong direction. Who approves: in a coordinated session the coordinator;
the owner is asked only when the spec would change an AC of the story. In a solo session the person approves the story and the
spec in one ask. The spec shape is the one recorded in this repo's own `kb/README.md` (built by `init-kb`).

Condition: an intent exists (`vibemaestro-sdlc:intake`) and you stand in the worktree of the branch `intent/<date>-<slug>`.
If not, do `intake` first.

## Do

1. **Create the skeleton file** — the same `<date>-<slug>` as the intent, so the two files go as a pair:

   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/kb.py" new spec <slug> --date <date>
   ```

   The command creates `kb/specs/<date>-<slug>.md` with the five sections `## Goal`, `## Constraints`, `## Acceptance criteria`,
   `## Risks to cover` and `## To clarify`, and points `Intent:` at the intent file if it already exists. Link it back: add
   `spec: kb/specs/<date>-<slug>.md` to the intent's frontmatter (and the intent's `plan:` line, if it has one, to the spec's) and
   commit the intent with the spec.

   **The section names come from the repo's config** (`tokens.spec`): the English names in this skill are the ones of
   `"language": "en"`, and the blanks are `<FILL: …>`; a repo on the default `vi` language has Vietnamese names, which
   `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/sdlc_config.py" get tokens.spec` prints; where the repo says otherwise, keep the names the
   generated template carries, which are the ones `kb.py check spec` requires. The spec is kb content: write it in the repo's
   `language` (`sdlc_config.py get language`). The check counts the placeholder of every language (`<FILL`, and the Vietnamese one
   that `tokens.spec.placeholder` holds by default), so a spec that writes about one quotes the word without its `<`.

2. **Fill in** — only from the intent: the story, its decisions and, for a task or a bug, a `## Brainstorm result` section.
   **Add no idea of your own** and do not widen the scope beyond the story. A missing piece of information becomes an open point
   in `## To clarify`; do not guess.
   - The technical detail the story must not carry lives here: exact values, parameter names, status codes, matching rules, protocols. When
     you answer a technical question, write the answer into this spec and never into the story's AC.
   - `## Goal`: what must be true when done, said as a result a person sees, each line pointing to the AC it serves (`→ AC<n>`).
   - `## Constraints`: hard limits only: security, cost, compatibility. Not how it is built: a "constraint" that names a file, a
     function, a library or an order of steps is the plan's.
   - `## Acceptance criteria`: behaviour, written as "when … then …" (vi: "khi … thì …"), each ending `→ AC<n>[, AC<m>]`; every AC
     of the story has at least one. No command, unless the command is the behaviour (a CLI's output); no evidence line (the PR's
     evidence section is the `ship` skill's).
   - `## Risks to cover`: the inputs and failures the tests must cover, chosen by risk, about 10 at most: the hostile input
     (injection, a path outside the tree, a huge or binary value), the odd one (unicode, spaces, a symlink), the empty one, the
     oversized one, two runs at once, a failure half way, the wrong type. Most review defects are an input nobody listed. How a good
     test looks: rule `test-quality` of the plugin (`rules/test-quality.instructions.md`).
   - `## To clarify`: the open points, each with a recommendation and why; `none` when there are none. A point that would change
     an AC of the story goes to the owner.
   - About two pages for a usual story, and at most 32768 bytes (`kb.spec_max_bytes`; the whole file, UTF-8): a warning from 80
     percent, red over it on a spec the change touches. Over: split it by service or module, one spec for each, each with its own
     intent. Delete every `<FILL: …>`; the `description:` line in the frontmatter is one line.

3. **Check the shape by machine** and fix until rc `0`:

   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/kb.py" check spec <date>-<slug>
   ```

   Red: one of the five sections missing, twice or empty, another `## ` section, a blank left, an AC of the story that no criterion
   names, an AC named that the story lacks. A warning, never red (also under `--strict`): a criterion not written as when … then
   or naming no AC, a code block, a spec over 8000 characters. A story's spec of the earlier shape (`## Context`, `## Out of scope`,
   `## Inputs and failure cases`, criteria as commands) passes with a warning until its body changes (its frontmatter does not
   count); new or with a changed body, it takes the five sections. A task's or a bug's spec may keep either shape. The check reads the shape, not whether a criterion is right, and it is
   **not** a gate: nothing stops you editing code before the approval — keeping the discipline is your job.

4. **Commit, push, then ask for the approval** (one commit, `git add` by pathspec):

   ```bash
   git add kb/specs/<date>-<slug>.md
   git commit -m "docs(kb): spec <slug>"
   git push origin intent/<date>-<slug>
   ```

   Ask for approval **after** pushing, so that the person can read exactly that file:
   - In a sandbox session (`VIBEMAESTRO_ROLE=worker`, or, deprecated and leaving in the next release, `INTENT_SLUG` and `SEAT` both set and
     not blank; checked by `[ "${VIBEMAESTRO_ROLE:-}" = worker ] || { [ -n "$(printf %s "${INTENT_SLUG:-}" | tr -d '[:space:]')" ] && [ -n "$(printf %s "${SEAT:-}" | tr -d '[:space:]')" ]; }`; a `session-ask` on PATH does not make a session a sandbox), when the `session-ask` command is installed, call
     `session-ask "Spec kb/specs/<date>-<slug>.md is pushed to intent/<date>-<slug>. Approve so I can start coding, or name what needs changing. Open points: <…>"`
     (the coordinator answers it; it asks the owner only when an AC of the story would change)
     then **end the turn** and wait for the person's message. The command records the `waiting` status so that the person is woken up; the session stays alive.
   - Otherwise (a solo session, or a sandbox without the `session-ask` command), give the spec path in your reply and ask the person right in the session.
     First record the question with `bash "${CLAUDE_PLUGIN_ROOT}/scripts/stage-signal.sh" ask <date>-<slug>`, the question on stdin
     through a quoted heredoc (`<<'EOF'`): outside a sandbox it marks the intent waiting in the local state file a dashboard reads; in a
     sandbox it does nothing.

5. **No code edit without an approval.** Approval is **the person's reply** through the person's channel; the machine has
   no "approved" mark, and silence is not approval. If the person asks for the spec to change, change it, run step 3 again, commit,
   push, ask for approval again. In a solo session, ask for the story and the spec in that one question. With an approval, first run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/stage-signal.sh" code <date>-<slug>` (the dashboard
   shows coding started: in a sandbox through `session-notify`, else in the local state file of the session; it never fails), then carry on: `vibemaestro-sdlc:plan` if the work must be split, or code in this
   worktree and then `vibemaestro-sdlc:ship`. The spec is living: when the code teaches something, update the spec (and the plan) in the same PR and say so in the PR
   body; that needs no new approval. Changing an AC of the story does: ask the owner (through the coordinator), and record the
   answer as a decision of the story with the owner's words quoted — `kb.py check intent` and `kb.py check links` are red on a
   story already on the base whose AC changed without one. Never silently work differently from the spec.

## An intent whose spec is already approved

A session that starts work on an intent whose spec is **already approved** (the second PR of a plan row, a run PR after a spec PR, a
brief that names the spec as approved) does not run steps 1-4 and does not write a second spec. At its first code step (before its PR is opened) it runs
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/stage-signal.sh" code <stem>` (`<stem>` is the intent's `<date>-<slug>`; pass it, the branch may not be
`intent/<stem>`), then carries on as step 5 says after the signal (`plan` or code, then `ship`). Once per intent and session: skip it when this session already sent `code` through step 5.

"Already approved" is only one of these: the brief or the person names the spec as approved, or the spec file is on `origin`'s default branch
(after `git fetch origin`; its PR merged). A spec that exists only on a branch this session wrote, or a `SPEC ready` nobody answered, is not approved: nothing is sent
before the approval, and step 5 stays the only sender on that path.
