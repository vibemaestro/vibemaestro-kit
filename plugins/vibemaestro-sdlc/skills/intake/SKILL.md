---
name: intake
description: "Use when: the person gives a new piece of work in an app repo and it must become an intent in the kb/ of this very repo — write kb/intent/<date>-<slug>.md, create the branch intent/<date>-<slug> and the tracking issue in the app repo through the plugin's scripts/intent-branch.sh."
---

# intake — record the intent of an app repo

An intent is the **original request in the person's own words** (1–2 paragraphs; for a story, the story the owner approves), quoted as given, in their language (what you add around it is in the repo's `language`), recorded **before** the branch is created: the plugin's core
refuses to create `intent/<slug>` when `kb/intent/<slug>.md` does not exist yet (rc 3). One intent = one branch =
one draft PR. The intent is recorded in the repo the work goes into; work that goes through two repos gets one intent on each side,
and the two point links at each other.

Condition: the repo already has `kb/` — if not, do `vibemaestro-sdlc:init-kb` first.

## Do

1. **A worktree of its own, inside the repo** (do not edit the main tree, do not put a sibling directory outside the repo):

   ```bash
   git fetch origin
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/kb.py" base --default origin/<default branch>
   git worktree add --detach .claude/worktrees/<name> <base>
   cd .claude/worktrees/<name>
   ```

   `<base>` is the line `kb.py base` printed: `origin/<default branch>` when it already has `kb/`, or `origin/chore/kb-init`
   when the `init-kb` PR is not merged yet (then the intent PR carries the scaffold commit — say so in its body). rc 2
   means there is no `kb/` anywhere: run `vibemaestro-sdlc:init-kb` and push its branch first.
   When the intent PR carries the scaffold commit and the `init-kb` PR merges first, rebase the intent branch onto the default
   branch: a plain rebase drops the scaffold commit, but if the scaffold was squash-merged or had extra commits,
   `kb/current-state.md` conflicts — keep the intent branch's version.

2. **Create the skeleton file** and fill it with the person's words (ask the person if something is missing, do not make it up):

   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/kb.py" new intent <slug> --type story|task|bug --focus P<n>
   ```

   Every intent says its **type** and its **focus**: `story` (a feature the owner asked for), `task` (a small piece of work) or `bug`,
   and `P<n>`, the open focus of the brain it serves (`brain show P<n>`; ask the person when it is not clear which one). The command writes
   both into the frontmatter and the card of the type. A story's card is the story the owner approves, in the repository's
   `language` (`sdlc_config.py get language`), and it is the request itself: the As / I want / so that line, context, numbered AC
   that say what the owner sees (no command, file name or code), out of scope, appetite, at most 3 open questions each with a
   recommendation and why; it fits a phone screen. With a coordinator, the coordinator writes it after brainstorming with the owner
   and hands it over verbatim; in a solo session, write it with the person (`vibemaestro-sdlc:brainstorm`). A task gets `## What`,
   `## Why` and `## Check`; a bug `## Reproduce`, `## Expected` and `## Test`. `kb.py check intent <date>-<slug>` judges the card:
   red for a missing part or more than 3 open questions, a warning for code, a path or a long story. An older intent with the first
   story card (`## Story`, `## Acceptance criteria`, `## Not doing`, `## Measure`) is still read.
   The command prints the file path and a line `slug for intent-branch.sh: <date>-<slug>`. The slug is lower case, no accents,
   digits, hyphens. Delete every blank marked `<FILL: …>` (in a repo with the default `vi` language the blank carries the Vietnamese placeholder word that `tokens.spec.placeholder` holds); the `description:` line in the frontmatter becomes the description of the issue.
   When the brief names a plan row (a plan file and a row id), add `plan: kb/plans/<file>.md#<row id>` to the frontmatter: it is how
   `kb.py plan status` finds this intent and its PR (`vibemaestro-sdlc:plan`).
   If the handover package already carries a "Brainstorm result" section (the person clarified it in an earlier step), copy it verbatim to the
   end of the intent file under the heading `## Brainstorm result`, and **do not brainstorm again**.

3. **Create the branch + issue through the plugin's core** — do not create a branch or an issue with a bare git/gh command:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/intent-branch.sh" create-intent --slug <date>-<slug> --base <base>
   ```

   `create-intent` reads the intent's `type:` and `focus:` first. Where a brain answers, the focus must be an open one of that brain;
   in a session with `VIBEMAESTRO_ROLE=worker` (the brain keeps no memory there), the intent's `issue: N` must carry the labels `type:<t>` and `focus:<P>` that the
   gate-1 session set. What happens when they are missing or the focus is not open follows `intake.focus` in
   `.vibemaestro/sdlc.json`: `required` refuses with rc 9 and creates nothing, naming what is missing; `warn` (the default) prints one
   WARNING line and goes on; `off` (a repository run without the brain) reads neither. The issue it opens gets the labels `intent`,
   `type:<t>` and `focus:<P>`.
   (`create-intent` also sends the `spec` stage signal through `scripts/stage-signal.sh`: to `session-notify` in a sandbox, to the local state file elsewhere.)
   The branch `intent/<date>-<slug>` is created **right in the worktree** (the main tree does not change branch), cut
   from exactly the `<base>` of step 1 (always pass `--base`: the default `origin/main` is wrong when the repo's default branch is not `main` or `kb/` is not merged yet). The issue is created
   in the repo that `gh` picks from the directory you stand in — that is, the app repo — and the issue number is written into the line
   `issue: N` of the frontmatter. Creating the issue is best-effort: on a permission/network error the branch still exists; retry
   with `intent-branch.sh retry-issue --slug <date>-<slug>` (called the same way as above).
   The core creates the `intent` label itself when the repo lacks it. If stderr still shows `NO TRACKING ISSUE WAS RECORDED`
   (no permission to create labels or issues, no network), the branch exists but no issue was recorded: check `gh issue list --label intent` (a timed-out call may have created one), tell the user,
   do not treat intake as finished, and run `retry-issue` once the cause is fixed.
   **When `.vibemaestro/sdlc.json` sets `issue.code`** (the repository's 3-letter code, like `KIT`), the branch is named after the
   issue: `create-intent` opens the issue first (or takes the `issue: N` the intent already names), writes the key
   `<CODE>-<issue number>` as the intent's `key:` and creates `intent/<KEY>-<slug>` (the slug without its date); the file keeps
   `kb/intent/<date>-<slug>.md`, and the command prints the branch name: use it in step 4. If the issue cannot be opened, no branch is
   created (rc 1): fix the cause, then run `create-intent` again. A Jira issue key the person gives goes in as `jira: <KEY>`
   (`kb.py new intent … --jira <KEY>`): stored and shown, never synced.

4. **Commit and push** (one commit, `git add` by pathspec):

   ```bash
   git add kb/intent/<date>-<slug>.md
   git commit -m "docs(kb): intent <slug>"
   git push -u origin intent/<date>-<slug>      # under issue.code: the intent/<KEY>-<slug> that create-intent printed
   ```

## A repo without a remote

A repo can start with no remote (`git remote` prints nothing): there is no `origin/<default branch>`, no issue tracker and no push.
`kb.py base` only reads `origin/…` refs, so it refuses there (rc 64 or 2, "push its branch first"): skip it. The path:

1. `init-kb` has committed the scaffold on the local branch `chore/kb-init` (no push). That branch is the base.
2. Worktree and intent file as in step 1 and 2 above, without `git fetch origin` and `kb.py base` (both need the remote), with
   `chore/kb-init` (the local branch, not `origin/…`) as `<base>`.
3. Create the branch without an issue:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/intent-branch.sh" create-intent --slug <date>-<slug> --base chore/kb-init --no-issue
   ```

4. Commit the intent file as in step 4, without the push.
5. Once the repo has a GitHub remote and the branches are pushed, open the tracking issue and record it:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/intent-branch.sh" retry-issue --slug <date>-<slug>
   ```

   It writes `issue: N` into the intent file's frontmatter: commit that line on the intent branch. Before the remote exists it
   fails with "no git remotes found" and changes nothing; tell the user the intake has no tracking issue yet.

Tell the user: the issue number, the branch name, the intent path. Next steps, in order (steps 1 and 3 only when their condition holds):

1. The request is still vague (cannot say what is correct yet, or there are still many directions) → `vibemaestro-sdlc:brainstorm`;
   if the intent already has a "Brainstorm result" section or the request is already clear, skip this step.
2. `vibemaestro-sdlc:spec` — derive the spec from the intent and get it approved **before editing code** (the coordinator approves; a solo person approves story and spec in one ask).
3. `vibemaestro-sdlc:plan` when the work must be split across several tasks; if it need not be split, work straight in this worktree.
4. `vibemaestro-sdlc:ship` — when the work is done, open the PR.

A change needed in **another repo** (infrastructure, another service) is not done in this session: write in the app repo's intent what that change must provide
and the sentence "wait for the PR of that repo to merge" if the app repo's PR depends on it, then tell the user. Work that goes through two repos gets one
intent on each side, and the two point links at each other.
