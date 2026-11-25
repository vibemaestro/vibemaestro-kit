---
name: plan
description: "Use when: a topic needs two or more PRs (or a new PR is decided for a topic that has a plan), or someone asks what the state of a topic is — after a shallow recon of the current state, write or extend kb/plans/<date>-<slug>.md (one row per PR: how, the AC it delivers, depends on, trust touches, link, a version on a group's release row only; the owner's decisions verbatim; a living plan), link each dispatched intent to its row, and read the live state with kb.py plan status instead of collecting it from issues, PRs and specs."
---

# plan — the plan of a topic that takes several PRs

One intent = one branch = one PR = one session. A topic too big for one PR is split across PRs, and the plan is the one place that
split lives: how each PR builds it, which AC of the story it delivers, what it waits for, what needs a signature, which release row
ships it, and what the owner decided. The what and the acceptance live in the spec; the plan holds the how.
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
reads only enough code to answer and decides no implementation: no design, no steps, no "should". Its facts feed each row's How; a
finding longer than one line goes to `kb/records/<date>-<slug>-recon.md`, facts only. Check what it returns yourself before you write it down (its answer is a claim).

## Write the plan

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/kb.py" new plan <slug>
```

Fill every `<FILL: …>` (`<ĐIỀN: …>` in a Vietnamese repo). The file has:

- **Frontmatter** `description`, `issue` (the topic's issue) and `focus` (its focus, `P<n>`), and a line naming the topic's intent, spec and issue when they exist.
- **`## Rows`**, one row per PR, in a table with the header `| Row | Title | How | Delivers | Depends on | Trust touches | Link |`, and a
  `Version` column when a release row needs one. A plan of the earlier columns (Must be true, Current state @SHA, Shared files,
  Acceptance, Model) is still read and checked as before; a story's plan new, or whose row cells change (a Link cell and the Decisions do not count), takes the lean columns (`kb.py check plan`).
  - **Row:** a short id (`A`, `B1.2`, `13a`), never reused.
  - **Title:** the outcome of this PR in a few words, about 60 characters, in the repository's `language`, for people to read (it is the
    title of the row's ticket): no path, no code. `kb.py check plan` is red for a Title that is empty, over 80 characters, on more than
    one line or has a backtick, in a story's plan new or whose row cells changed.
  - **How:** the approach of this PR in a few lines: what it builds on (the recon's facts), what it changes, what it touches.
  - **Delivers:** the AC of the story this PR delivers, `AC1, AC2`, with the spec's criteria numbers when they help
    (`AC4 (criteria 7–9)`), or `enabling: <reason>` for a row that delivers no AC itself. Every AC is delivered by a row that is not dropped.
  - **Trust touches:** what the row's PRs change in the trust layer and run, so the owner signs it with the plan: `none`, or
    `;`-separated items. A touch: `<kind> [<owner/repo>:]<path> [<object>] [Stops: <words>]` (the repository defaults to the
    plan's), kinds `script`, `baton` (with its `Stops:`, `removed` for a deleted baton), `workflow`, `rbac`, `admission`,
    `vault-policy` (these three name the rendered object `<Kind>/<namespace or ->/<name>`), `config` (under `.vibemaestro/`),
    `other <exact path> [<object>]` (one file or one object no other kind fits; never `-`) and `test <path>` or
    `test <directory>/` (test data under a `tests` or `test` directory). `run <kit:name or project:name> Stops: <words>
    [runs: <n>]` declares a baton run, `PRs: <n>` how many PRs use the row (1 to 20, 1 when absent). Exact paths, no glob. End a
    touch in `(signs again)` to keep it the owner's; the floor must carry it, or the owner's dialog refuses the plan: what judges a
    later PR (the config, an adapter, the planner, a touch check's inputs, `.vibemaestro/risk-tier.yaml`, `.vibemaestro/gates/`), a
    `.claude-plugin` path, a baton whose Stops drop a word of `SIGN_AGAIN_STOPS`, a run with one, and a `secrets` run outside
    `PLAN_SECRETS_KITS`. `—` (no cell) cannot be signed. The plan's preamble names one intent and one spec (`Intent: … · Spec: …`)
    and the spec has numbered acceptance criteria. The owner signs the whole plan with `baton.py sign --by owner --approve <spec>`
    (`{plan: [{repo, path, commit}], expires}`, at most 30 days); `kit:merge-pr` then merges up to each row's PRs whose every
    trust-layer change is one of its touches, where the base's `merge.touch_checks` is set, while the intent, the spec and the
    row's cells are as signed (`docs/batonrun.md`, section 6). A change to any of them, a row's Link and the Decisions apart, is
    outside the signature until the owner signs again; a new row is not signed.
  - **Depends on:** row ids of this plan, or `—`. Two rows may run in parallel only when neither depends on the other and they share no
    file; rows that share a file are sequenced here.
  - **Version** (a release row only): when the repo publishes versioned plugins (skill `release`), a feature group's **release row**,
    the row that runs the release once the group's other rows have merged (it depends on them), carries `<plugin> x.y.z`,
    comma-separated when it raises several, and a hotfix row may carry a patch.
  - **Link:** `—` until the row's work links itself (next section); `#N` or `intent/<slug>` only for work that cannot (a PR merged
    before its intent had `plan:`, a branch that differs from its intent's file name); `dropped: <reason>` for a dropped row (a `#N` there is read as the row's own PR, so name a PR that absorbed the work as
    "row C", not as its number).
- **`## Decisions`:** one bullet per owner decision: date and time, the words verbatim (not translated), a link to where they were
  given (issue comment, PR, kb file). An open proposal the owner has not decided is written as open.

A row must give a fresh session everything it needs when its brief is only the plan file and the row id: the how, the AC it
delivers (their criteria and risks are in the spec), the dependencies, the touches, and on a release row the version. A brief built
from a row starts with one quick step: check that what the row's How builds on still holds at the current `origin/main`, and stop
and ask (`session-ask` in a sandbox) when it no longer does. When the row's spec is already approved (as that section defines it), the session does not run the `spec` skill: at its first code step it sends the `code` stage as the section "An intent whose spec is already approved" of that skill says. A plan may hold several row tables (one per level); any table with `Row` and `Link` columns is a row table.

A plan is at most 32768 bytes (`kb.plan_max_bytes`; the whole file, UTF-8): a warning from 80 percent, red over it on a plan the
change touches (`kb.py check plan <file>` says its size). Over: split it into waves, one plan for each, the later ones linked
from the first.

Commit the plan in a PR of its own topic (the first PR, or a docs-only PR), then check its links (below).

## Link a row's work to its row

The session that takes a row records the link in its own PR, so the plan file is not edited once the row's work has started and parallel PRs of one
plan never conflict on it:

- the intent's frontmatter gets `plan: kb/plans/<file>.md#<row id>`, and `spec: kb/specs/<file>.md` once the spec exists;
- the spec's frontmatter gets the same `plan:` line (its `Intent:` line already names the intent);
- `open-pr.sh` puts one line `Plan row: …` above the summary of the PR body by itself, from the intent's `plan:`. It is for people:
  `plan status` finds the PR by its branch `intent/<intent file stem>`, never by this line or by a mention of the row id.

**The plan is living.** When the code teaches something, the row's PR updates its own row (and the spec) in the same PR and says
so in its body, with no new approval; a change to an AC of the story needs the owner's word (`kb.py check intent` and `kb.py check links` refuse a
story whose AC changed without a new quoted decision). Edit only your own row, so parallel PRs rarely meet in the file, and merge main
when they do. A row whose cells change after the owner signed the plan is outside that signature until the owner signs again.

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
