English | [Tiếng Việt](ai-native-sdlc.vi.md)

# AI-native software development: Anthropic's guidance and this kit

This page compares what Anthropic publishes about building software with Claude Code and agents with what this kit does. It
has three parts for each stage of the software development life cycle (SDLC): what Anthropic recommends, with a link to the
page that says it; which kit file implements it; and where the kit differs, goes further or has a gap.

Anthropic does publish a framework under this name. "The AI-native SDLC playbook" [S1] describes six stages (Plan, Design,
Build, Test, Deploy, Maintain). It says the same idea is also called “the agentic SDLC, the AI SDLC, or simply agentic software
development” [S1]. A companion article describes how Anthropic secures its own AI-native SDLC [S2]. The rest of Anthropic's
guidance is spread over the Claude Code documentation and the engineering blog [S3]–[S31].

## How to read this page

**Stages.** This page uses seven stages: Plan, Specify, Build, Review, Test, Release and Operate. They map to the playbook's
six stages as follows: Specify is the playbook's Design; Review and Release split the playbook's Deploy (the PR review loop,
and the approval gates with CI/CD); Operate is the playbook's Maintain.

**Citations.** `[S1]` points to the line S1 of the [Sources](#sources) table. Text in curly quotes is copied word for word from the
source and is shorter than 25 words. Everything else is a paraphrase.

**Status words.**

| Word | Meaning |
|---|---|
| shipped | In a plugin of this kit |
| gap | Not built; written down so you do not assume it exists |

**Paths.** Links go to files that ship in the plugins or in `docs/`. A path in backticks with no link (for example
`tests/run-all.sh`) is a file of the kit repository outside the plugins; it is not installed with them.

The kit has two plugins, for one person with one Claude seat on one machine:
[`vibemaestro-sdlc`](../plugins/vibemaestro-sdlc/) (the working process) and
[`vibemaestro-brain`](../plugins/vibemaestro-brain/) (memory for long-running sessions).

## At a glance

| Stage | Anthropic recommends | The kit | Status |
|---|---|---|---|
| Plan | Capture the intent in the requester's words as a committed file; a person accepts it [S1] | `intake` skill writes `kb/intent/<date>-<slug>.md` before the branch exists; `brainstorm` skill | shipped |
| Specify | A spec written from the intent, reviewed by a person before code [S1], [S3] | `spec` skill: four sections, criteria are commands; approval asked before code | shipped (approval is discipline, not a gate) |
| Build | Short CLAUDE.md, skills for policy, hooks for guarantees, worktrees and subagents [S1], [S5] | Rules delivered by hooks at the moment of action; one worktree per intent; per-job subagent models | shipped |
| Review | Review in a fresh context; the agent that wrote the code cannot approve it [S1], [S3] | `before-ready` rule; review model from config; the author never merges its own PR; the person merges, or the main session of `local-parallel` through a guarded merge | shipped (review is discipline, not a gate) |
| Test | Give the agent a check it can run; show evidence; evals for the agent's configuration [S1], [S3] | Spec criteria are commands; `open-pr.sh` refuses a PR without run evidence | shipped; evals are a gap |
| Release | Hooks as approval gates; the agent acts up to the production gate [S1] | BatonRun for every privileged write; change files and a release script | shipped |
| Operate | Deterministic detection; findings return as a new intent; least-privilege agent identities [S1], [S2] | Writes to a live system go through BatonRun | gap: no monitoring loop, no agent identity |
| All stages | Manage context; keep state in files; sandbox and permissions [S3], [S18], [S16] | `kb/` as the repository's memory; the brain plugin; baton permission rules | shipped |

## Plan

### What Anthropic recommends

- Capture the idea once, as a file. The playbook's Plan stage: “Intent is captured once, in the originator's own words, as a
  version-controlled artifact the next stage can act on.” [S1]
- Keep that file next to the code. For a single product, the playbook suggests an `intent/` folder in the product repository,
  and says the product owner reviews and accepts the intent before it moves on [S1].
- Brainstorm with Claude until the idea is concrete: scope, users, constraints and what success looks like [S1].
- People decide what to do; Claude decides how. In an analysis of about 400,000 Claude Code sessions, “people make most of the
  planning decisions (what to do) and Claude makes most of the execution decisions (how to do it).” [S28]
- Plan only when it helps: “If you could describe the diff in one sentence, skip the plan.” [S3] The Claude Code team itself
  moved much planning into pull requests and prototypes, which it calls just-in-time planning [S26].

### What the kit does

- The skill [`intake`](../plugins/vibemaestro-sdlc/skills/intake/SKILL.md) records the request **verbatim** in
  `kb/intent/<date>-<slug>.md`, then creates the branch `intent/<date>-<slug>` and a tracking issue through
  [`intent-branch.sh`](../plugins/vibemaestro-sdlc/scripts/intent-branch.sh). The core refuses to create the branch when the
  intent file does not exist (exit code 3, [`intent_branch.py`](../plugins/vibemaestro-sdlc/scripts/intent_branch.py)).
- The skill [`brainstorm`](../plugins/vibemaestro-sdlc/skills/brainstorm/SKILL.md) clarifies a vague request and writes the
  result into the intent file, under its own heading.
- The skill [`plan`](../plugins/vibemaestro-sdlc/skills/plan/SKILL.md) is for a topic that needs two or more pull requests: one
  plan file, one row per pull request, with the owner's decisions quoted. `kb.py plan status` reads each row's live state
  ([`kb.py`](../plugins/vibemaestro-sdlc/scripts/kb.py)).
- The rule [`git-process`](../plugins/vibemaestro-sdlc/rules/git-process.instructions.md): one intent, one branch, one draft
  pull request.

### Where the kit differs

- **Differs:** the playbook lets Claude write the intent and the originator correct it [S1]. The kit keeps the requester's own
  words unchanged, and puts Claude's clarification in a separate section. The reason: a later reader can tell what was asked
  from what was interpreted.
- **Further:** the order "intent before branch" is enforced by a script, not only described.
- **Differs:** the playbook's `plan.md` is a per-change implementation plan [S1]. In the kit, that content lives in the spec
  (next stage); a kit plan is the multi-PR level above it.
- **Gap:** no machine records that a person *accepted* the intent. Acceptance shows only as the person's reply in the session.

## Specify

### What Anthropic recommends

- Turn the accepted intent into a requirements and design spec, guided by the organisation's skills, with areas of concern
  flagged; a person reviews it and it is committed next to the intent [S1].
- Let Claude interview you, then write a spec and start a fresh session to execute it [S3]. “The most useful specs are
  self-contained” [S3]: they name the files and interfaces involved and what is out of scope.
- Agree on what "done" means before code is written; Anthropic's long-running harness work calls this a sprint contract [S22].
- Keep a planner at the level of product context and high-level design, because an error in a detailed spec cascades into the
  build [S22].
- For long tasks, list the features in a file, all marked failing at first, and forbid the agent to remove or edit tests [S21].

### What the kit does

- The skill [`spec`](../plugins/vibemaestro-sdlc/skills/spec/SKILL.md) writes `kb/specs/<date>-<slug>.md` in four sections
  (context, goal, out of scope, acceptance criteria). Each acceptance criterion is **one command and its expected result**. The
  last criterion always asks for a run-evidence section in the pull request.
- `kb.py check spec` checks the shape: sections present and in order, no unfilled blank, a command in every criterion
  ([`kb.py`](../plugins/vibemaestro-sdlc/scripts/kb.py)).
- The skill asks the person to approve the spec before any code is edited. A subagent of `local-parallel` ends its turn with
  the spec path instead, and the main session relays the spec to the person.

### Where the kit differs

- **Further:** criteria as commands make the sprint contract [S22] executable. The same commands become the evidence at the
  Test stage.
- **Gap:** spec approval is discipline, not a gate. The shape check does not know whether a person approved. The playbook
  notes that plan mode enforces its own gate: “Plan mode enforces this itself, since Claude cannot edit files until the engineer
  accepts the plan.” [S1] The kit has no hook that blocks edits before approval.
- **Gap:** the kit has no skills that encode an organisation's brand, security or UX policy for the spec pass, as the
  playbook describes [S1]. A repository can add its own rules (see Build).

## Build

### What Anthropic recommends

- Keep CLAUDE.md short and in git: “Keep CLAUDE.md under 200 lines.” [S5] Check it in so the team can contribute [S3].
- Turn a repeated correction into a file change: “A repeated mistake or a recurring review comment is a CLAUDE.md edit, not a
  one-off correction in chat.” [S5]
- Use skills for knowledge that must be applied consistently, and hooks for what must always hold: “A skill is an advisory
  control while a hook is the deterministic layer behind it.” [S1] “Put guardrails in hooks.” [S5]
- CLAUDE.md and memory files are context, not enforcement: “Claude treats them as context, not enforced configuration.” [S10]
- Run parallel sessions, each in its own git worktree [S1], [S4]: “Two or three sessions is a sensible starting point.” [S1]
  Coding tasks parallelise less than research does [S19].
- Use subagents for scoped jobs: “Each subagent runs in its own context window with a custom system prompt, specific tool
  access, and independent permissions.” [S6]
- Package skills, hooks, subagents and MCP servers as a plugin, which Claude Code installs and loads as one unit [S9]; skills
  follow the open Agent Skills standard [S8], [S20].
- Install skills only from trusted sources, and audit them [S20].

### What the kit does

- The kit is two Claude Code plugins in one marketplace (`.claude-plugin/marketplace.json`). Each is plain skills, hooks,
  rules and scripts.
- **Rules at the moment of action.** The sdlc plugin's hooks ([`hooks.json`](../plugins/vibemaestro-sdlc/hooks/hooks.json))
  read the file Claude is about to edit or the command it is about to run, and deliver only the matching rule:
  `applyTo` globs for edits ([`pre-edit.py`](../plugins/vibemaestro-sdlc/scripts/pre-edit.py)), `applyWhen` patterns for
  commands ([`pre-bash.py`](../plugins/vibemaestro-sdlc/scripts/pre-bash.py)). A rule at `level: block` denies the command
  ([`rules.py`](../plugins/vibemaestro-sdlc/scripts/rules.py)). Session start delivers only the working method and the rule
  catalogue ([`session-start.py`](../plugins/vibemaestro-sdlc/scripts/session-start.py)).
- **Rules shipped.** The rules in [`plugins/vibemaestro-sdlc/rules/`](../plugins/vibemaestro-sdlc/rules/) (commit unit,
  git process, PR body, leaks, measurement, version policy and others). A repository adds its own rule directory in
  `.vibemaestro/sdlc.json` ([`sdlc_config.py`](../plugins/vibemaestro-sdlc/scripts/sdlc_config.py)).
- **Worktrees.** The rule [`git-process`](../plugins/vibemaestro-sdlc/rules/git-process.instructions.md) asks for a worktree
  of its own inside the repository; `open-pr.sh` refuses to open a pull request from the main tree (exit code 5,
  [`open_pr.py`](../plugins/vibemaestro-sdlc/scripts/open_pr.py)).
- **Subagents on the right model.** Three config keys give each subagent job its model: `agents.review_model` (default
  `opus`), `agents.search_model` (`haiku`) and `agents.worker_model` (`sonnet`).
- **Several tasks at once.** The skill [`local-parallel`](../plugins/vibemaestro-sdlc/skills/local-parallel/SKILL.md): the
  main session splits the work and starts one subagent per task on `agents.worker_model`, each in its own worktree from intake
  to a draft pull request. It keeps the queue, relays each spec to the person, post-checks each pull request and merges it.

### Where the kit differs

- **Further:** instead of one CLAUDE.md that grows, the kit loads a rule only when its file or command matches. This keeps
  the start-of-session context small, which matters because “Claude's context window fills up fast, and performance degrades as
  it fills.” [S3]
- **Differs:** most kit hooks remind; only a `level: block` rule denies. The hooks fail open: an error exits 0 and lets the tool
  call run, so a broken plugin never blocks work. This trades [S5]'s "guardrails in hooks" for work that a broken plugin never stops.
- **Further:** the main session treats a subagent's report as a claim and re-runs the acceptance command before believing it
  ([`workflow-core`](../plugins/vibemaestro-sdlc/rules/workflow-core.instructions.md)). The playbook's limit, adding sessions only
  while review keeps up [S1], becomes a written procedure.

## Review

### What Anthropic recommends

- Review in a fresh context: “A fresh context improves code review since Claude won't be biased toward code it just wrote.”
  [S3]
- Keep separation of duties: “Separation of duties is preserved, because the agent that wrote the code has no way to approve
  it.” [S1] Approval comes from a person through branch protection [S1].
- Run the same review passes on every pull request, with findings ranked by severity [S1]; Anthropic's managed Code Review
  ranks bugs by severity and “It won't approve PRs” [S24].
- Put human attention where it matters. Anthropic reserves human review for regulated or critical code and samples the rest
  by risk [S2]; the Claude Code team calls this “human review where it matters” [S26].
- Run a security review before opening a pull request [S2]; `/security-review` and `/code-review` exist for this [S31].
- In GitHub Actions, grant the workflow only the permissions it needs, and have a person review Claude's changes before
  merging [S12].

### What the kit does

- The rule [`before-ready`](../plugins/vibemaestro-sdlc/rules/before-ready.instructions.md) is delivered when a session runs
  `gh pr ready`. It asks for a fresh-context review of the final diff (another agent or a person; the author rereading does not
  count), run on `agents.review_model`, with the strongest tier allowed for high-risk changes. It also says a session does not
  merge its own pull request.
- The rule [`pr-body-shape`](../plugins/vibemaestro-sdlc/rules/pr-body-shape.instructions.md) keeps the PR body as the
  current state; round history goes into comments.
- One task: the person merges the pull request. Several tasks with `local-parallel`: the main session merges a subagent's
  pull request through the kit run `kit:merge-pr` ([`merge-pr.sh`](../plugins/vibemaestro-sdlc/batons/merge-pr.sh),
  [`merge_guard.py`](../plugins/vibemaestro-sdlc/gates/merge_guard.py)): a dry run first, then one merge pinned to the reviewed
  head, refused when a guard fails (head moved, checks red, conflicts, files outside the brief).

### Where the kit differs

- **Further:** the merge is pinned to the head that was reviewed, so a push after the review cannot slip in.
- **Gap:** the fresh-context review is discipline, not a gate: nothing blocks `gh pr ready` without one.
- **Gap:** no shared review policy file with fixed passes and severity ranking, as the playbook's REVIEW.md [S1].
- **Gap:** no step runs `/security-review` before a pull request opens. The sensitive-information gate (Release) covers
  secrets in PR text, not vulnerabilities in code.

## Test

### What Anthropic recommends

- “Always give Claude a way to verify its own work, whether tests, a build, or a screenshot diff.” [S1]
- Ask for evidence: “Have Claude show evidence rather than asserting success” [S3]. “If you can't verify it, don't ship it.” [S3]
- For a bug, “write a failing test that reproduces the issue, then fix it” [S3]; the playbook adds a hook that stops the agent
  editing the test during the fix [S1].
- Let a different agent judge the work: “Separating the agent doing the work from the agent judging it proves to be a strong
  lever” [S22].
- Test the agent's configuration too: “Evals are the AI-native equivalent of stage-gate QA.” [S1] The playbook runs them in CI
  whenever CLAUDE.md, skills or hooks change [S1].
- Run the same checks locally and in CI, so “the same checks you run locally fire on every push or PR” [S25].
- Plan for CI load: at Anthropic, “Our CI job volume increased 25x over 6 months.” [S29] It answered with test impact
  analysis; “Claude prefers smaller, more granular PRs” [S29].

### What the kit does

- Spec criteria are commands with expected results (Specify), so the test plan exists before code.
- The skill [`ship`](../plugins/vibemaestro-sdlc/skills/ship/SKILL.md) runs the acceptance commands and writes their real
  output to an evidence file. `open-pr.sh` refuses to open a pull request when that file is missing or empty (exit code 3,
  [`open_pr.py`](../plugins/vibemaestro-sdlc/scripts/open_pr.py)); a run that could not happen must say why in its first line.
- The rule [`before-ready`](../plugins/vibemaestro-sdlc/rules/before-ready.instructions.md) asks which command ran on the
  **last pushed head**, and which criterion still has no command.
- The rule [`measurement-commands`](../plugins/vibemaestro-sdlc/rules/measurement-commands.instructions.md): before quoting a
  number, run a sure-positive control, because an empty result may come from a broken instrument.
- The kit's own CI runs only the suites a change affects (`tests/run-all.sh --changed`, in `.github/workflows/test.yml`) and the
  full suite twice a week (`.github/workflows/test-full.yml`). The kit's tests break a copy of the code on purpose and require
  red ("planted breaks").

### Where the kit differs

- **Further:** a pull request without run evidence cannot be opened through the kit; the evidence is checked for presence, not
  for meaning.
- **Same idea as [S29]:** run only the affected suites per pull request, and the full suite on a schedule.
- **Gap:** no eval suite runs the kit's skills and rules against a model. The tests prove that the scripts work and that hooks
  deliver the rules; whether a real session follows them is not measured. This is the playbook's continuous-evals play [S1],
  and the kit does not have it.
- **Gap:** no hook blocks edits to test files during a fix.

## Release

### What Anthropic recommends

- Use hooks as approval gates. A hook can pause an action until a named person approves, which is what release gating
  needs [S1].
- “The governing principle is that the agent may act up to the production gate and cannot pass it.” [S1]
- Prepare the rollback before you need it: “rehearse the rollback paths before the agent ever needs them” [S1].
- Run Claude non-interactively in pipelines with `claude -p` [S11], for judgment steps such as triaging a failed build or
  drafting the changelog [S1]. In locked-down CI, use a permission mode that denies anything not pre-approved [S3], [S15].
- Keep secrets out of the repository and out of the agent's reach [S12], [S16].
- Keep an audit trail: “The chain of commits is also the audit trail” [S1].

### What the kit does

- **BatonRun.** Every write outside the session (a merge, a GitHub API write, a registry push, a deletion, a change to the
  user's Claude Code settings) is one run of one baton script: checked, rehearsed against its `Expect` lines, sealed, signed,
  run, post-checked against the expected after-state, undone on a mismatch, and logged
  ([`batonrun` skill](../plugins/vibemaestro-sdlc/skills/batonrun/SKILL.md),
  [`baton.py`](../plugins/vibemaestro-sdlc/scripts/baton.py), [standard](../plugins/vibemaestro-sdlc/docs/batonrun.md)). The signature is bound to the hash of
  the script and its arguments. In manual mode the owner signs each run; in auto mode the session signs a normal run and asks
  the owner only for a run on the stop list.
- **Permissions.** `baton.py permissions --print` prints the Claude Code permission rules a machine needs, and `--check`
  reports missing or unsafe ones.
- **Versions.** A pull request that changes a plugin adds a change file under `.changes/` and edits no version (rule
  [`version-policy`](../plugins/vibemaestro-sdlc/rules/version-policy.instructions.md)). A release pull request, cut by the
  [`release`](../plugins/vibemaestro-sdlc/skills/release/SKILL.md) skill with
  [`release.py`](../plugins/vibemaestro-sdlc/scripts/release.py) (`check`, `plan`, `cut`), turns the change files into each
  plugin's `CHANGELOG.md`, whose first heading is the released version. After it merges, a baton script the owner signs moves
  the branch `release` to it. The kit's own public release writes each version into its `plugin.json` and tags it
  `<plugin>--v<version>`.
- **Contract.** [`CONTRACT.md`](../plugins/vibemaestro-sdlc/CONTRACT.md) lists what an automated consumer may rely on; a test
  fails when that surface changes without a change file of the right level.
- **Gates.** The skill [`install-gates`](../plugins/vibemaestro-sdlc/skills/install-gates/SKILL.md) installs six GitHub
  workflow templates ([`gates/workflows/`](../plugins/vibemaestro-sdlc/gates/workflows/)): commit discipline, sensitive values
  in PR text, PR title, PR body, review evidence and dead branches. Each pull-request job checks out the **base** (or default) branch, never the
  PR head, so a pull request cannot change the script or config that judges it. The workflow file itself still comes from the
  pull request, so a change under `.github/` needs review.

### Where the kit differs

- **Further:** the playbook's release gate is a hook that asks before a command [S1]. A baton approval covers a whole series of
  writes, with its plan and its undo shown first, and is void if the script changes. One approval per run, not per command,
  is the kit's answer to approval fatigue [S16].
- **Further:** change files mean parallel pull requests never edit the same version line, so the parallel sessions of [S1] do
  not collide on releases.
- **Further:** the kit's public release is scanned for a list of terms and for secrets before it is published (`scripts/export-gate.sh`).
- **Gap:** the kit does not use Claude in CI for judgment steps such as build triage or changelog drafts; the changelog is
  assembled from the change files by a script.

## Operate

### What Anthropic recommends

- Close the loop: a trigger invokes Claude without a person, and what it finds returns as a new intent [S1].
- Keep detection deterministic: “detection stays entirely deterministic, with no model involved” [S1].
- “Give every agent a single-purpose identity with the minimum permissions for its job.” [S2]
- Start incident agents read-only: Anthropic describes “a read-only Claude in your incident channel that diagnoses,
  escalates, and learns” [S30], with its own service account [S30].
- For scheduled tasks, say what success looks like and what to do with the results [S4].

### What the kit does

- Nothing in the kit watches a running system. A write to a live system is a baton script like any other privileged action
  (Release); a change to a live cluster outside an approved lane carries the stop word `cluster-lane`, so the owner signs it
  ([BatonRun](../plugins/vibemaestro-sdlc/docs/batonrun.md#6-approval-the-modes-the-stop-list-the-owners-signature)).

### Where the kit differs

- **Partly the same as [S2]:** every write goes through a signed run; the kit sets up no agent identity of its own.
- **Gap:** no monitoring loop. Nothing in the kit watches production, detects a breach or writes a finding back as an intent.
- **Gap:** no incident agent and no metrics export.

## Across all stages: context, memory and permissions

### What Anthropic recommends

- Context is the main constraint: “Claude's context window fills up fast, and performance degrades as it fills.” [S3] Clear
  context between unrelated tasks, and tell Claude what to keep when compacting [S3].
- Keep state outside the context window: “Structured note-taking, or agentic memory, is a technique where the agent regularly
  writes notes persisted to memory outside of the context window.” [S18]
- For long work, keep a progress file and git history; a new session should “Read the git logs and progress files to get up to
  speed on what was recently worked on.” [S21]
- Compaction alone is not always enough: “compaction isn't sufficient” [S21]. The advice depends on the model: later work
  dropped context resets because “The resets had become dead weight.” [S23], [S22]
- A SessionStart hook with the `compact` matcher can re-inject critical context after every compaction [S7]; a project-root
  CLAUDE.md survives compaction [S10].
- Every harness component “encodes an assumption about what the model can't do on its own” [S22]; re-examine it when models
  change [S23]. Start with the simplest thing that works [S17].
- Least privilege and isolation: sandboxing needs both filesystem and network isolation [S14], [S16]; it “reduces risk but is not a
  complete isolation boundary” [S14]. Anthropic reports that “sandboxing safely reduces permission prompts by 84%” [S16].
  Bypass mode is for isolated containers and VMs only [S15]. A person stays responsible for approving commands [S13].
- People stay accountable: “Humans remain accountable for every decision that requires judgment.” [S1] Anthropic's own study
  warns of a “paradox of supervision”: overseeing Claude needs the coding skills that heavy use may erode [S27].

### What the kit does

- **The repository is the memory.** `kb/` holds intents, specs, plans and decisions. `kb/current-state.md` says how the
  repository is now: it is overwritten, never appended, and has a size cap that `kb.py check current-state` checks (rule
  [`current-state-shape`](../plugins/vibemaestro-sdlc/rules/current-state-shape.instructions.md)). `kb.py find`, `list` and
  `outline` find one section without reading whole files ([`kb.py`](../plugins/vibemaestro-sdlc/scripts/kb.py)).
- **State that must survive a compaction** lives in the PR body and `kb/`, not only in the conversation
  ([`workflow-core`](../plugins/vibemaestro-sdlc/rules/workflow-core.instructions.md)).
- **The brain plugin** ([README](../plugins/vibemaestro-brain/README.md)) keeps a small hot memory for a long-running session:
  owner decisions, delegation windows, now, next and traps, at most 6,000 characters. Its `SessionStart` hook re-injects it at
  every start, compactions included; `PreCompact` and `PostCompact` log each compaction and a loss score, the share of the
  live items' anchors that the summary dropped ([`hooks.json`](../plugins/vibemaestro-brain/hooks/hooks.json)). The log is hash-chained, and owner items are written
  only after Claude Code's permission dialog. A `# Compact instructions` block for CLAUDE.md is in
  [`compact-instructions.md`](../plugins/vibemaestro-brain/templates/compact-instructions.md).
- **Permissions:** BatonRun's permission rules (Release).

### Where the kit differs

- **Further:** the brain measures what compaction loses instead of assuming it; the findings are in
  [the brain research summary](research/brain.md).
- **Further:** the current-state file is overwritten, not appended, so a new session reads the present, not a log to replay.
- **Further:** the sdlc plugin's SessionStart hook can inject the repository's current-state index, at start and after a
  compaction (`current_state.inject`, off by default).

## Where the kit goes further, and why

### BatonRun for privileged writes

Anthropic's guidance puts approvals in hooks [S1] and warns about approval fatigue [S16]. The kit makes a privileged action a
**run**: one script, rehearsed, signed against its hash, run by the session, post-checked and logged. The owner never types
commands from a model's instructions, and one signature covers one fixed series. Details: [BatonRun](../plugins/vibemaestro-sdlc/docs/batonrun.md) and
[the BatonRun research summary](research/batonrun.md).

### Change files instead of version edits

Parallel sessions are a core practice in [S1]. When each pull request bumps a version, parallel pull requests conflict. The kit
gives each pull request its own change file and lets one release pull request set the versions.

### The brain for compaction

Anthropic's own posts disagree over time on compaction versus context resets, and say the answer depends on the model [S21],
[S22], [S23]. The kit keeps a small, checked hot memory that is re-injected after every compaction, and logs a loss score, so
the question can be measured for each session.

### The repository as memory

The playbook commits an artifact at each stage [S1], and long-running harnesses keep progress files [S21]. The kit does both
with a checked lifecycle: intents, specs and plans have a fixed shape, links between them are checked (`kb.py check links`),
and the current-state file has a size cap.

### Gates that judge from the base branch

The playbook uses managed settings so that no engineer or project file can widen the rules [S1]. The kit's CI gates apply the
same idea to pull requests: each gate reads its script and config from the base branch, so a pull request cannot change the
script or config of its own judge. The workflow file still comes from the pull request, so a change under `.github/` needs
review.

## Known gaps

| Gap | Anthropic's guidance | Where it would go |
|---|---|---|
| Spec approval is not a gate | Plan mode blocks edits until the plan is accepted [S1] | a hook in `vibemaestro-sdlc` |
| Fresh-context review is not a gate | Separation of duties [S1] | a hook on `gh pr ready` |
| No shared review passes with severity | REVIEW.md passes [S1]; Code Review ranks by severity [S24] | a review skill |
| No security review step | `/security-review` before a PR [S2], [S31] | the `ship` skill |
| No evals of skills and rules against a model | Continuous evals on configuration changes [S1] | the kit's CI |
| No test-file guard during fixes | A hook that blocks test edits [S1] | a hook |
| No monitoring loop or incident agent | Deterministic detection; findings as intent [S1]; read-only on-call [S30] | outside the kit |
| Hooks fail open | Hooks as guarantees [S3], [S5] | none: hooks fail open by design |

## Glossary

- **applyTo**: frontmatter of a rule: a list of file globs. When a session is about to edit a matching file, the hook delivers the rule.
- **applyWhen**: frontmatter of a rule: a regular expression on the Bash command about to run. When it matches, the hook delivers the rule; with `level: block` it denies the command.
- **baton script**: in BatonRun, the script that carries one run, with a header (purpose, targets, blast radius, undo, preconditions, stops, expect), a rehearse path that prints the plan, and an undo. The signature is bound to the hash of the script and its arguments. See [BatonRun](../plugins/vibemaestro-sdlc/docs/batonrun.md#2-vocabulary).
- **BatonRun**: the kit's method for privileged actions: a repeated workflow runs as one gated run (write, check, rehearse, seal, sign, run, post-check, log). The image is the conductor's baton: only the session that runs the action holds it. The standard is [BatonRun](../plugins/vibemaestro-sdlc/docs/batonrun.md).
- **brief**: the contract the main session gives a subagent in `local-parallel`: what must be true, the acceptance commands and the scope. Anything outside it, the subagent stops and asks. Its report is a claim, not evidence.
- **consumer contract**: [`CONTRACT.md`](../plugins/vibemaestro-sdlc/CONTRACT.md), the list of what an automated consumer may rely on for a major version, checked by the kit's contract test.
- **current-state ledger**: `kb/current-state.md`: how the repository is now, overwritten and never appended, with a size cap and a list of refused history signs.
- **fail open**: a hook that, when it errors, exits 0 and lets the tool call run, so a broken plugin cannot block work.
- **fresh-context review**: a review by an agent or person that did not write the change and has not seen the author's reasoning, on the pinned final diff. The author re-reading their own work does not count.
- **gate**: a check that counts and goes red, as opposed to a rule, which only reminds.
- **guarded merge**: the merge command that merges only when the guards pass (head SHA, latest checks, conflicts, a deny list, the brief's scope) and is a dry run by default.
- **intent**: `kb/intent/<date>-<slug>.md`, the requester's own words, recorded before the branch exists. One intent is one branch is one draft pull request.
- **kb**: the `kb/` directory of a repository: intents, specs, plans, decisions and the current-state file.
- **main session**: in `local-parallel`, the session the person talks to: it splits the work, briefs one subagent per task, relays spec approvals, post-checks and merges. It edits no file of a task.
- **planted break**: a test that copies code, breaks the copy in one place on purpose, and requires the suite to go red.
- **spec**: `kb/specs/<date>-<slug>.md`: four sections in order, with criteria that are commands, approved by a person before code.
- **worker**: a subagent that builds one task against a brief, from intake to a draft pull request. Its result is a claim; the main session re-runs the acceptance command before believing it.

## Sources

| Id | Title | URL |
|---|---|---|
| S1 | The AI-native SDLC playbook | https://claude.com/resources/articles/the-ai-native-sdlc-playbook |
| S2 | How Anthropic secures its AI-native software development lifecycle | https://claude.com/resources/articles/how-anthropic-secures-its-ai-native-software-development-lifecycle |
| S3 | Best practices for Claude Code | https://code.claude.com/docs/en/best-practices |
| S4 | Common workflows | https://code.claude.com/docs/en/common-workflows |
| S5 | Extend Claude Code | https://code.claude.com/docs/en/features-overview |
| S6 | Create custom subagents | https://code.claude.com/docs/en/sub-agents |
| S7 | Automate actions with hooks | https://code.claude.com/docs/en/hooks-guide |
| S8 | Extend Claude with skills | https://code.claude.com/docs/en/skills |
| S9 | Plugins overview | https://code.claude.com/docs/en/plugins/overview |
| S10 | How Claude remembers your project | https://code.claude.com/docs/en/memory |
| S11 | Run Claude Code programmatically | https://code.claude.com/docs/en/headless |
| S12 | Claude Code GitHub Actions | https://code.claude.com/docs/en/github-actions |
| S13 | Security | https://code.claude.com/docs/en/security |
| S14 | Configure the sandboxed Bash tool | https://code.claude.com/docs/en/sandboxing |
| S15 | Choose a permission mode | https://code.claude.com/docs/en/permission-modes |
| S16 | Beyond permission prompts: making Claude Code more secure and autonomous | https://www.anthropic.com/engineering/claude-code-sandboxing |
| S17 | Building effective agents | https://www.anthropic.com/engineering/building-effective-agents |
| S18 | Effective context engineering for AI agents | https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents |
| S19 | How we built our multi-agent research system | https://www.anthropic.com/engineering/multi-agent-research-system |
| S20 | Equipping agents for the real world with Agent Skills | https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills |
| S21 | Effective harnesses for long-running agents | https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents |
| S22 | Harness design for long-running application development | https://www.anthropic.com/engineering/harness-design-long-running-apps |
| S23 | Scaling Managed Agents: Decoupling the brain from the hands | https://www.anthropic.com/engineering/managed-agents |
| S24 | Code Review for Claude Code | https://claude.com/resources/articles/code-review |
| S25 | Building verification loops in Claude Code with skills | https://claude.com/resources/articles/building-verification-loops-in-claude-code-with-skills |
| S26 | Running an AI-native engineering org | https://claude.com/resources/articles/running-an-ai-native-engineering-org |
| S27 | How AI is transforming work at Anthropic | https://www.anthropic.com/research/how-ai-is-transforming-work-at-anthropic |
| S28 | Agentic coding and persistent returns to expertise | https://www.anthropic.com/research/claude-code-expertise |
| S29 | Agentic coding is straining CI. Here's how we scaled test impact analysis at Anthropic | https://claude.com/resources/articles/agentic-coding-is-straining-ci-heres-how-we-scaled-test-impact-analysis-at-anthropic |
| S30 | How Claude Tag serves as Anthropic's first responder for CI/CD failures | https://claude.com/resources/articles/ai-ci-cd-on-call |
| S31 | Commands | https://code.claude.com/docs/en/commands |
