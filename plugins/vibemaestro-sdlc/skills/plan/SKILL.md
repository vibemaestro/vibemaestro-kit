---
name: plan
description: "Use when: a topic needs two or more PRs (or a new PR is decided for a topic that has a plan), or someone asks what the state of a topic is — after a shallow recon of the current state, write or extend kb/plans/<date>-<slug>.md (one row per PR: must be true, current state @SHA, shared files, acceptance, depends on, version on a group's release row only, model, link; the owner's decisions verbatim), link each dispatched intent to its row, and read the live state with kb.py plan status instead of collecting it from issues, PRs and specs."
---

# plan — the plan of a topic that takes several PRs

One intent = one branch = one PR = one session. A topic too big for one PR is split across PRs, and the plan is the one place that
split lives: what each PR must make true, how it is accepted, what it waits for, which release row ships it, and what the owner decided.
Its state is read from GitHub by a command, never written into the plan, so a later session answers "where is this topic?" from one
file and one command instead of re-reading issues, PRs, comments and specs.

## When

- **A topic needs 2 or more PRs:** write its plan before work on the second PR starts. A single-PR intent needs no plan.
- **A topic has a plan and a new PR is decided:** add a row. **A PR is dropped:** write `dropped: <reason>` in its Link cell.
- **Someone asks what the state of a topic is:** run `kb.py plan status` on its plan (below) and read the plan; open an issue, PR or
  spec only for what the status flags.

## Recon, before rows are written or extended

A row written from the spec alone, when the code has drifted, misleads the worker that takes it. So before writing or extending rows,
hand one read-only subagent (`agents.search_model`) the spec, `kb/current-state.md`, the open PRs (`gh pr list`) and the SHA of
`origin/main`. For each row it answers, as facts at that SHA: does this exist already? where is the seam (the existing file and
function the row meets)? is the data or interface the row needs there? which files does it share with other rows or open PRs? It
reads only enough code to answer and decides no implementation: no design, no steps, no "should". A finding longer than one line goes
to `kb/records/<date>-<slug>-recon.md`, facts only. Check what it returns yourself before you write it down (its answer is a claim).

## Write the plan

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/kb.py" new plan <slug>
```

Fill every `<FILL: …>` (`<ĐIỀN: …>` in a Vietnamese repo). The file has:

- **Frontmatter** `description` and `issue` (the topic's issue), and a line naming the topic's intent, spec and issue when they exist.
- **`## Rows`**, one row per PR, in a table with the header
  `| Row | Must be true | Current state @SHA | Shared files | Acceptance | Depends on | Version | Model | Link |` (a plan written without the two
  recon columns is read and checked as before):
  - **Row:** a short id (`A`, `B1.2`, `13a`), never reused.
  - **Must be true:** one line, said as a result; a spec or decision that holds the detail is named here or in the Link cell.
  - **Current state @SHA** (the header keeps `@`)**:** the recon's facts in one short line ending in `@<sha>` (the `origin/main` it read), with a link to the
    recon note when longer; `—` for none. `kb.py check links` fails a cell that is not `—` and has no `@<sha>`.
  - **Shared files:** existing files, as repo-root paths, that this row and another row or an open PR both touch, or `—`.
  - **Acceptance:** the command and what it must print. The session that does the row runs it; whoever checks the PR runs it again.
  - **Depends on:** row ids of this plan, or `—`. Two rows may run in parallel only when neither depends on the other and they share no
    file. Rows that share a file are sequenced here, or one writes `(merge main)` in its Shared files: it runs in parallel with
    every row it shares with and merges main before it is ready. `kb.py check links` fails two rows that share a file with neither.
  - **Version:** `—` on every row, unless the repo publishes versioned plugins (skill `release`): then a feature group's
    **release row**, the row that runs the release once the group's other rows have merged (it depends on them), carries
    `<plugin> x.y.z`, comma-separated when it raises several, and a hotfix row may carry a patch.
  - **Model:** model and effort for the session that does the row (rubric: design or risky → Opus xhigh; clear implementation → Opus high or
    Sonnet high; mechanical → Sonnet medium).
  - **Link:** `—` until the row's work links itself (next section); `#N` or `intent/<slug>` only for work that cannot (a PR merged
    before its intent had `plan:`, a branch that differs from its intent's file name); `dropped: <reason>` for a dropped row (a `#N` there is read as the row's own PR, so name a PR that absorbed the work as
    "row C", not as its number).
- **`## Decisions`:** one bullet per owner decision: date and time, the words verbatim (not translated), a link to where they were
  given (issue comment, PR, kb file). An open proposal the owner has not decided is written as open.

A row must give a fresh session everything it needs when its brief is only the plan file and the row id: what must be true, the
acceptance, the spec and decision links, the dependencies, and on a release row the version. What the plan says is *what must be true*, not which file or
line to change. A brief built from a row starts with one quick step: check the row's Current state facts at the current
`origin/main` before coding, and stop and ask (`session-ask` in a sandbox) when one no longer holds. When the row's spec is already approved (as that section defines it), the session does not run the `spec` skill: at its first code step it sends the `code` stage as the section "An intent whose spec is already approved" of that skill says. A plan may hold several row tables (one per level); any table with `Row` and `Link` columns is a row table.

Commit the plan in a PR of its own topic (the first PR, or a docs-only PR), then check its links (below).

## Link a row's work to its row

The session that takes a row records the link in its own PR, so the plan file is not edited once the row's work has started and parallel PRs of one
plan never conflict on it:

- the intent's frontmatter gets `plan: kb/plans/<file>.md#<row id>`, and `spec: kb/specs/<file>.md` once the spec exists;
- the spec's frontmatter gets the same `plan:` line (its `Intent:` line already names the intent);
- `open-pr.sh` puts one line `Plan row: …` above the summary of the PR body by itself, from the intent's `plan:`. It is for people:
  `plan status` finds the PR by its branch `intent/<intent file stem>`, never by this line or by a mention of the row id.

A row's own PR does not edit the plan, with one exception: a release row's PR corrects its Version cell when another release merged
first and the release took the next number.

## Read the state

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/kb.py" plan status kb/plans/<file>.md          # --json for a tool
```

One line per row: `planned` (with its recon `@<sha>`), `intent open` (with its issue), `PR open` (number, head SHA, draft or ready, CI), `merged` (number,
merge commit, the version at that commit), `dropped` (reason). Then `drift`: two PRs for one row, a version that differs from the one
merged, a dependency not merged while its dependant is open, a dropped row with a merged PR. Notes name a closed unmerged PR or a
linked intent that was not found, and a `planned` row that nothing links when an open or merged PR's title names it as `(row <id>)`
(a hint only: the state stays `planned`; write the PR number in the Link cell). It is read-only and does not fetch: an intent that exists only on a branch you never fetched and
has no PR yet shows `planned`. Without `gh` or network it prints what the file says and labels GitHub `not checked`.

## Check the links

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/kb.py" check links
```

It fails (rc 65) on a broken link in a file changed against the merge base of `origin/HEAD` (else `origin/main`; `--base REF` to
choose): a `plan:` whose file or row does not exist, an intent and spec that do not name each other, a `Depends on` id or a `kb/…`
path in a plan that does not exist, a Link cell intent whose `plan:` names another row. A broken link in an older file is an `OLD`
line and does not fail. Each `FAIL` line says what to add. In this kit's own CI the suite `kb-links` runs it.

## Reference: child branches inside one intent

Rarely used (no child branch exists in the kit). When one intent's work is split into tasks on one PR, each task gets a child
branch from the intent tip and is folded back with one commit:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/intent-branch.sh" worker-branch --intent <date>-<slug> --name <branch> --no-checkout
git worktree add .claude/worktrees/<name> <branch>
# work, one task = one commit, then from that worktree:
bash "${CLAUDE_PLUGIN_ROOT}/scripts/intent-branch.sh" integrate --intent <date>-<slug> --to origin
```

`--no-checkout` is required from the main tree (rc 7: the core never switches the shared tree's branch). More than one commit is
refused at integrate (rc 8: squash to the cut point). A conflict stops with rc 4: fix it when the file is in the task's scope,
otherwise stop and ask. Push the intent before cutting a child branch; remove the worktree and branch once the PR merges.

A worker spawned as a subagent runs on the configured worker model
(`python3 "${CLAUDE_PLUGIN_ROOT}/scripts/sdlc_config.py" get agents.worker_model`, passed as the Agent tool's `model`); a worker in
another session is told that model in its brief. If the read fails, use the plugin default (the same command with `--default`), tell
the person what `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/kb.py" config check` names, and do not edit the config for them; if the
`--default` read fails too, ask the person which model to use.
