English | [Tiếng Việt](README.vi.md)

# vibemaestro-kit

Claude Code plugins that give your coding sessions a written process, rules that arrive when they matter, safe privileged actions and a memory that survives compaction.

## What it is

vibemaestro-kit is one Claude Code marketplace, named `vibemaestro`, with two plugins. It is made for one person who builds software with Claude Code on one machine, with one Claude seat. Together the plugins turn a Claude Code session into a repeatable way to deliver a change:

- a process from request to reviewed pull request, written into your repository so the next session starts from what is recorded;
- rules and checks that reach the session only when it edits a matching file or runs a matching command;
- one controlled way to run actions that write outside the session (a merge, a force-push, a deletion);
- a small hot memory that a long session keeps across compactions.

## The two plugins

| Plugin | Purpose | Documentation |
|---|---|---|
| `vibemaestro-sdlc` | The process: intake, spec, plan, ship. Rules by file or command, CI gates, BatonRun. Works in any application repository. | [plugins/vibemaestro-sdlc/README.md](plugins/vibemaestro-sdlc/README.md) |
| `vibemaestro-brain` | Hot memory that survives compaction: the `brain` command, an append-only log, your decisions written only through the permission dialog. Needs `vibemaestro-sdlc`. | [plugins/vibemaestro-brain/README.md](plugins/vibemaestro-brain/README.md) |

Installing `vibemaestro-brain` installs `vibemaestro-sdlc` with it.

## Requirements

| Needed | For |
|---|---|
| Claude Code (`claude` CLI); tested with 2.1.290 | everything; the brain's decision items need 2.1.211 or later in `auto` mode |
| `python3` 3.8 or later, `git`, `bash` | the hooks and scripts; tested on Linux and macOS, not on Windows; the brain needs a POSIX system |
| `gh`, signed in (`gh auth login`) | the tracking issue at intake, the pull request at ship, GitHub writes in BatonRun |
| A GitHub repository for your project | issues and pull requests; without a remote, intake records the intent and branch and skips the issue |

The plugins do not depend on any other repository at run time.

## Install

Add the marketplace, then install both plugins:

```bash
claude plugin marketplace add vibemaestro/vibemaestro-kit
claude plugin install vibemaestro-sdlc@vibemaestro
claude plugin install vibemaestro-brain@vibemaestro
```

To use a local copy or a fork instead, give its directory to `claude plugin marketplace add`. Check the install. Both plugins should show `Status: ✔ enabled`; `claude plugin install` exits 0 even when a dependency is missing, so read this list:

```bash
claude plugin list
```

To update later:

```bash
claude plugin marketplace update vibemaestro
claude plugin update vibemaestro-sdlc@vibemaestro
claude plugin update vibemaestro-brain@vibemaestro
```

Then open a new session.

## First use in your repository

Do these once. Open a new Claude Code session in your application repository.

1. **Set up `kb/`.** Ask Claude to run the skill `vibemaestro-sdlc:init-kb`. It asks a few questions, then writes a `kb` folder (intents, specs, plans, decisions and a current-state file) and a small config file `.vibemaestro/sdlc.json`, and overwrites nothing. One question is the language of the `kb` documents and pull request bodies: the skill recommends English (`en`), or Vietnamese (`vi`) if you write to it in Vietnamese, and records the answer in the config. The skill commits the result on the branch `chore/kb-init` and pushes it: open its pull request and merge it. Some error messages of the scripts are still in Vietnamese whatever you choose.
2. **Set up BatonRun on this machine (recommended).** A privileged write outside the session (a merge, a GitHub comment, a force-push) runs as one baton script; a normal branch push and opening a pull request do not. Without this setup every baton command asks you; `local-parallel` merges through batons. Ask Claude to set up BatonRun on this machine (skill `vibemaestro-sdlc:batonrun`, its setup reference). It installs a small launcher and prints a block of permission rules; you add that block to your Claude Code user settings (`/permissions`, or `~/.claude/settings.json`). The plugin never writes your settings. The skill `vibemaestro-sdlc:coordinator-bootstrap` does the same setup in one run you sign. With the block, the routine baton commands run without a prompt, while your signature and a change of mode always ask you. Details: [BatonRun, permission setup](plugins/vibemaestro-sdlc/docs/batonrun.md#9-permission-setup).
3. **Add a CI check (optional).** The guarded merge needs at least one green check on a pull request. The skill `vibemaestro-sdlc:install-gates` adds the process gates as GitHub workflows; it asks which gates and which runner, and never overwrites a file.

## The flow

Describe a change in plain words. The session-start reminder points Claude to `vibemaestro-sdlc:intake`, and Claude asks you only where a person must decide:

1. **Intake.** Claude records your request word for word as `kb/intent/<date>-<slug>.md`, creates the branch `intent/<date>-<slug>` in a git worktree of its own, and opens a tracking issue.
2. **Brainstorm**, only when the request is vague. Claude asks the questions that pick a direction and writes the answers into the intent.
3. **Spec.** Claude writes `kb/specs/<date>-<slug>.md` in four sections: context, goal, out of scope, acceptance criteria, where each criterion is a command and its expected result. **You approve it before any code is edited**, or say what to change.
4. **Plan**, only when the work needs several pull requests: one plan file, one row per pull request.
5. **Ship.** Claude does the work, updates `kb/current-state.md`, runs the acceptance commands and opens a draft pull request with their real output as evidence.
6. **Review.** Before the pull request leaves draft, a subagent with a fresh context reviews the final diff; the session fixes what it finds, then marks the pull request ready (`gh pr ready`) and tells you. Going ready starts the CI gates, if you installed them.
7. **Merge.** The session that wrote a change does not merge it. **You merge the ready pull request** on GitHub, after reading it.

For several tasks at once, ask for the skill `vibemaestro-sdlc:local-parallel`. The main session splits the work, starts one subagent per task (each in its own worktree, intake to draft pull request), relays each spec to you for approval, checks each pull request again and merges it through the guarded merge `kit:merge-pr`, which needs a green CI check (step 3 of first use). In mode `manual`, the default, each of those merges asks for your signature.

Spec approval and review are rules the session follows, not gates that block. Hooks fail open: an error never blocks your work. The CI gates, if you install them, cover commit form, sensitive text, titles, pull request bodies, review evidence and dead branches. The full picture, stage by stage and compared with Anthropic's guidance: [docs/ai-native-sdlc.md](docs/ai-native-sdlc.md).

## Brain

A session that runs for hours or days is compacted when its context fills up, and the summary can drop a decision you stated once or a mistake the session already made. The brain keeps a few short items outside the repository (your pinned decisions, permission windows, the task in hand, next steps and traps, at most 6,000 characters) and puts them back into the context after every compaction.

You rarely type a brain command: Claude runs them, guided by the skill `vibemaestro-brain:brain`. A decision or a window of yours is written only after you approve a one-line Claude Code permission dialog, so the model alone cannot invent one. `/matrix` shows what the brain holds and what it injected. Whether it is needed at a given session size is an open question: see [Evidence](#evidence). Details: [plugins/vibemaestro-brain/README.md](plugins/vibemaestro-brain/README.md).

## Safety model

BatonRun is how a session performs an action that writes outside itself (full standard: [plugins/vibemaestro-sdlc/docs/batonrun.md](plugins/vibemaestro-sdlc/docs/batonrun.md)).

- One baton script holds the whole series of commands. It is checked, rehearsed to show every write, and signed. The signature is bound to the script's hash, so any later edit voids it.
- The run is then post-checked, undone when the result is wrong, and logged. You are never handed command lines to type.
- You pick the mode: `manual`, the default (you sign every run), or `auto` (the session signs a normal run; a run on the stop list, such as an irreversible delete, always asks you).

## Documentation

The index is [docs/README.md](docs/README.md). It lists the two plugins, the AI-native SDLC, BatonRun and the research behind them.

## Evidence

The research notes state what is known about BatonRun's token cost and about the brain's benefit, including what the tests did not show: the brain was not shown necessary at the size tested. They are in [docs/research/](docs/research/).

## Releases

Each plugin has its own version. A release is tagged `<plugin>--v<version>` in the public repository `vibemaestro/vibemaestro-kit`, and its notes are the plugin's `CHANGELOG.md`. The kit is not listed in the Anthropic plugin directory.

## Contributing

Pull requests are not accepted. Open an issue in [Issues of `vibemaestro/vibemaestro-kit`](https://github.com/vibemaestro/vibemaestro-kit/issues) for a question, a bug report or a proposal; the maintainers triage them by hand. To run the plugins from a checkout or a fork, or to run the tests, read [DEVELOPMENT.md](DEVELOPMENT.md).

## Security reporting

If you find a vulnerability or a leaked secret, report it privately: open the repository's Security tab and choose **Report a vulnerability**, or go straight to [https://github.com/vibemaestro/vibemaestro-kit/security/advisories/new](https://github.com/vibemaestro/vibemaestro-kit/security/advisories/new). Never report it in a public issue.

## Licence

Apache License 2.0: see the `LICENSE` and `NOTICE` files at the repository root. Each plugin directory carries a copy of both files.
