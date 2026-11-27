English | [Tiếng Việt](README.vi.md)

# vibemaestro-sdlc

A Claude Code plugin that gives a session in an application repository one process: **intent → spec → plan → ship**. It records what the person asked for, gets an approved spec before any code, splits large work into tasks, and opens a pull request with run evidence. The process, the rules, the hooks and the scripts all live inside the plugin directory. At run time the plugin reads no other repository.

Version: see `.claude-plugin/plugin.json`. Release notes: [CHANGELOG.md](CHANGELOG.md). Frozen interface for automated consumers: [CONTRACT.md](CONTRACT.md).

## What it does

In a session opened in an application repository the plugin does five things.

1. **At session start** it hands the session the working core ([workflow-core](rules/workflow-core.instructions.md)), the catalogue of rules, a reminder of the skill chain, and a reminder of the repository's own `kb/`. In everyday mode (below) the session gets the [everyday core](templates/everyday-core.md) instead, with a line naming the mode for Claude only: the person sees no line in a fixed language, and Claude says the mode in the person's own language when it matters. A developer's folder that is not a git work tree (the key or `VIBEMAESTRO_PROFILE` set to `developer`) gets the core and the catalogue, but not the reminder of the app-repo flow and not the advice to scaffold `kb/`. This takes two `SessionStart` hooks, because Claude Code caps the text of each hook at 10,000 characters.
2. **Before a file edit** (`Edit`, `Write`, `NotebookEdit`) it reminds the session of every rule whose `applyTo` matches the file, and of every `kb/decisions/*.md` file of the repository whose `applyTo` matches.
3. **Before a shell command** (`Bash`) it reminds the session of every rule whose `applyWhen` matches the command. A rule with `level: block` denies the command instead. None of the plugin's own rules uses `block`; a repository rule may.
4. **In a worker session** (the environment variable `VIBEMAESTRO_ROLE` set to `worker`, as a tool that starts sessions for you may set it; a session you open yourself has none. Both `INTENT_SLUG` and `SEAT` set and not empty still mark a worker session too, with a deprecation line: that signal leaves in the next release) it adds one more reminder: record the intent word for word, write the spec, ask the person to approve, and only then edit code. This is a reminder, not a gate.
5. **When a subagent starts** (`SubagentStart`) it gives the subagent a short core of at most 3,000 characters ([subagent-core](templates/subagent-core.md)): the brief as the contract, evidence, root cause before a fix, the class sweep, and the test rules. A subagent gets none of the session-start text. The read-only built-in agents (`Explore`, `Plan`, `claude-code-guide`, `statusline-setup`) are skipped.

Properties of the hooks:

- A hook never fails the tool. Every hook command exits 0, also on input that is not JSON.
- A broken plugin (missing `rules/`, missing core) warns loudly at the top of the session. It does not pretend that rules were delivered.
- A matching rule is shown once per session, again after a compaction (which drops it from the context), and once inside each subagent, which keeps a set of its own. A `level: block` denial is raised every time.
- The hooks also warn when the checkout is behind its upstream branch, add size and ledger-page notes when you edit a ledger file, and add one line at session start when the BatonRun permission check finds something missing.
- The hooks are silent when `.vibemaestro/sdlc.json` sets `"hooks": "off"`. Any such file from the session's folder up to the top of its git history (or of the kit's save history) counts, whatever a nearer file says: a subfolder that sets it is off even when a parent folder holds the history, and a quiet save made from anywhere in that history leaves that subfolder out (saves made before it was turned off keep what they held). A repository that keeps its own rule hooks in `.claude/settings.json` must set `"hooks": "off"` or remove them: the two sets add up and are not de-duplicated.
- Rules of other installed plugins that declare a dependency on this one are served by the same hooks.

**Everyday mode**, for a person doing ordinary work rather than software, is described in [Everyday mode](#everyday-mode).

The process, by skill:

```
intake → brainstorm (only if the request is vague) → spec → plan (only if the work must be split) → ship
```

Every request for a change starts with `intake`. The owner approves the story; the spec is approved before code (by the coordinator, or by a solo person together with the story). A privileged action (a merge, a push to a registry, a deletion) goes through `batonrun`.

## Everyday mode

**Everyday mode** is for a person doing ordinary work with Claude (a report, a small agent, a demo, research) rather than software. Its session gets a plain-language core about keeping a notebook in `kb/`, no app-repo flow, no rule catalogue, and no reminder of the plugin's own rules at an edit or a command; the settings and signature guards, a repository's own rules and decisions, and the rule packs of dependent plugins run as in developer mode. A worker or coordinated session is always developer. The mode is chosen in this order: the folder's `profile` key; a folder with a git remote is developer; the person's `VIBEMAESTRO_PROFILE` (`everyday` or `developer`, in the `env` block of their Claude Code settings), for a folder with no remote; otherwise a folder that is not a git repository, or one the kit created, is everyday, and a repository that was there before (also one where git fails) is developer.

**The quiet save.** In everyday mode a `Stop` hook (asynchronous) saves the folder after each turn, locally, in a git history the kit creates there and marks; it never writes a history that was there before and never pushes. It does not save the root, the home folder or a parent of it, `Desktop`, `Documents`, `Downloads` or a `OneDrive` folder itself, a folder inside another repository or one git cannot read, a first save of more than 2,000 files, a folder with a remote, or during a merge or a detached HEAD; files with common secret names (keys, `.env` files, credentials, tokens, passwords) and bulky generated folders are never saved (a private exclude list of common names: review the history before sharing it). A save that did not keep the work, or never finished, is told to Claude at the next session start, and Claude tells the person in their own language. The skill `history` lists the saves and writes the one the person picks as a copy into `ban-cu/<time>/` inside the folder; it never overwrites the work folder. The kit's `ban-cu/` (`ban-cu-2/` and so on when the person has a `ban-cu` of their own) holds only those old copies: it carries a marker file saying so, is listed in `.ignore` so Claude Code's search skips it, and is not saved; a folder of the person's own named `ban-cu`, without the marker, is saved like any other and never written into. In developer mode the hook prints nothing and writes nothing.

Known limits of the quiet save:

- A `.gitignore` of your own that re-includes a secret name (for example `!.env`) wins over the save's list, and that file is saved.
- On Linux the secret names are matched with their exact letter case: `.ENV` or `ID_RSA` is saved.
- Only the English names Desktop, Documents and Downloads are protected; the same folders under another language's name are not.
- A first save stopped in the instant between creating the history and marking it leaves an unmarked history, and that folder is then in developer mode.

**The notebook.** Asked to start the notebook, the skill `init-kb` sets up `kb/` in place: when the folder has no history yet it has the kit save it once, then it runs `kb.py init --everyday`, which makes only `kb/current-state.md` and `kb/preferences.md` (no config, rules or other folders), for Claude to write in the person's language; `kb/preferences.md` holds only what the person said. No worktree, branch, commit of its own, push, gates, or question about merge or CI; the next quiet save keeps the notebook. A folder with no file of the person's yet gets one plain line: the notebook comes with the first file.

At the end of each task the session overwrites `kb/current-state.md` with where the work stands now (the present state only, short, no diary). When a turn changed files and the map did not change, a second `Stop` hook (`notebook_nudge.py`) asks the session once to do it; it never repeats, and developer mode and coordinated sessions get nothing.

**Moving to developer.** When the work should go to GitHub:

1. Create an empty repository on GitHub.
2. Ask Claude to review the whole history for secrets before you push: the quiet save leaves out common secret names but does not read what files contain, and every save goes up with the push.
3. Ask Claude to move the folder to developer: it sets `"profile": "developer"` in `.vibemaestro/sdlc.json`, connects the folder to the repository and pushes. The everyday core forbids pushing otherwise; this request is the one that allows it.

From the next session the folder is in developer mode (a folder with a remote is developer, unless its `.vibemaestro/sdlc.json` sets `"profile": "everyday"`, which step 3 replaces), the quiet save stops, and `kb/` carries on as the notebook of the developer flow. The kit's folder of old copies stays out of what is pushed: it is left out by the history's own local exclude list, which is never pushed.

## One task or several

The plugin is made for one person on one machine, with `vibemaestro-brain` beside it.

- **One task** runs in the session you open, from `intake` to a draft pull request. You approve the story and the spec in one ask, and you merge the pull request.
- **Several tasks at once:** the skill `local-parallel`. The main session starts one subagent per task, each in its own git worktree, from `intake` to a draft pull request, relays each story and spec to you, keeps the queue, post-checks each pull request and merges it with `kit:merge-pr`.

The plugin needs no other plugin and reads no other repository.

## Requirements

| Need | For | Notes |
|---|---|---|
| Claude Code CLI (`claude`) | everything | tested with 2.1.290 |
| `python3` 3.8 or newer | the hooks, `kb.py`, the cores, the gates | standard library only; the hooks run through `scripts/pyrun.sh`, which also finds `python` or `py -3` on Windows, and without Python exits 0 with one line for the session |
| `git` | everything | the process works in worktrees inside the repository |
| `bash` | the `.sh` adapters | tested on Linux and macOS |
| `gh` (GitHub CLI), logged in | `intake` (tracking issue), `ship` (open PR), `install-gates` (runner check), `batonrun` | the process is written for GitHub |

On Windows (Git for Windows' `bash`, Windows' own Python) the hooks and everyday mode run, and so do the baton's `log`, `list`, `mode` and `grant revoke`: the brain's close or supersede of a focus revokes the focus's charters there. Writing and running a baton (`new`, `check`, `go`, `run`, `rehearse`, `sign`, `pack`, a mode change, `permissions --print` and `--install-launcher`) and the owner's dialog do not run on Windows yet: each says so in one line and nothing runs; they run on Linux and macOS. `permissions --check` says in one line that there is nothing to check there.

## Install and update

The plugin ships in the marketplace `vibemaestro`, plugin id `vibemaestro-sdlc@vibemaestro`.

```bash
claude plugin marketplace add vibemaestro/vibemaestro-kit
claude plugin install vibemaestro-sdlc@vibemaestro
```

To use a local copy or a fork, give its directory to `claude plugin marketplace add` instead. Open a new session in your application repository after you install. Check with `claude plugin list`: the `Version:` line is the installed version.

To update:

```bash
claude plugin marketplace update vibemaestro
claude plugin update vibemaestro-sdlc@vibemaestro
```

Then open a new session. The installed copy is cached, and `claude plugin update` reports `nothing to update` until a release changes the `version` (see [Version policy](#version-policy)).

`vibemaestro-brain` declares a dependency on `vibemaestro-sdlc`. Installing it installs this plugin too.

## Quick start

Open a session in your application repository and ask Claude to run the skill `init-kb`. It writes `kb/` (`intent/`, `specs/`, `plans/`, `decisions/`, a `README.md`, `current-state.md`), `.vibemaestro/sdlc.json` and a rules directory with one example rule, commits them on the branch `chore/kb-init` and pushes it. It overwrites nothing and is safe to run again. Merge that branch first for a clean start; until it is merged, `intake` cuts the first intent branch from `chore/kb-init`, and that pull request carries the scaffold commit. Then describe a change; the session-start reminder points Claude to `vibemaestro-sdlc:intake`.

Typing the built-in `/init` in a git repository that has no `kb/`, or whose project has no brain (when `vibemaestro-brain` is installed), also makes Claude run `init-kb` and open the brain with `brain claim` once it has written `CLAUDE.md`; a repository that has both, and any other prompt, is left alone.

The scripts behind the skills also run by hand. The commands use `$SDLC` for the plugin directory: the installed copy, `~/.claude/plugins/cache/vibemaestro/vibemaestro-sdlc/<version>/`, or `plugins/vibemaestro-sdlc` of a checkout. Inside a session the skills use `${CLAUDE_PLUGIN_ROOT}` for the same directory.

```bash
export SDLC=<plugin directory>
cd <your application repository>
python3 "$SDLC/scripts/kb.py" init --lang en --dry-run
python3 "$SDLC/scripts/install_gates.py" --dry-run
```

`kb.py init --dry-run` prints what `init-kb` would write, without writing. Once the config exists, `python3 "$SDLC/scripts/kb.py" config check` validates it. `install_gates.py --dry-run` lists the gate files it would write.

## Skills

Skills are called by name, `vibemaestro-sdlc:<name>`. They write into the `kb/` of the repository you stand in.

| Skill | What it does | Triggers when |
|---|---|---|
| `init-kb` | Scaffolds a self-contained `kb/` and the per-repo config (`.vibemaestro/sdlc.json`, a rules directory). Safe to re-run; `--adopt` for a repository that already has process files. | the repository has no `kb/`, lacks one of its directories, or adopts the plugin |
| `intake` | Records the request in the person's own words as `kb/intent/<date>-<slug>.md` (for a story, the story the owner approves, in the repository's language), creates the branch `intent/<date>-<slug>` and the tracking issue. | the person gives a new piece of work |
| `brainstorm` | Clarifies a vague request. For a story it ends with the story itself in the intent (at most 3 questions, each with a recommendation); otherwise it writes a `Brainstorm result` section. No separate spec file. | the request is vague or needs a direction chosen |
| `spec` | Writes `kb/specs/<date>-<slug>.md`, derived from the intent, in five sections (goal, constraints, behaviour-level criteria pointing to the story's AC, risks to cover, open points) with no implementation, and asks for approval before any code. | the intent is recorded and no spec is approved yet |
| `plan` | Writes `kb/plans/<date>-<slug>.md`, one row per PR (how, the AC it delivers, what it depends on, what needs a signature), a living plan; links intents to rows; reads the live state with `kb.py plan status`. | a topic needs two or more PRs, or someone asks for its state |
| `ship` | Overwrites `kb/current-state.md`, runs the acceptance commands, records the evidence, and opens a draft PR with `scripts/open-pr.sh`. | the work of an intent is done |
| `release` | Cuts a release PR or a hotfix PR of a plugin marketplace repository with `scripts/release.py`; publishing the merged release is the repository's own step. | a plan's release row is due, or an installed plugin needs a hotfix |
| `install-gates` | Installs the six process gates as GitHub workflows plus their scripts. Asks which gates and which runner. Never overwrites a file the repository owns; `--update` upgrades the plugin's own copies. | a repository wants the gates behind the rules |
| `batonrun` | Runs an action that writes outside the session as one baton script: checked, rehearsed, signed, run, post-checked, logged. | a merge, a registry push, a deletion, a force-push, a change to the user's plugin config |
| `bootstrap` | Sets up a machine for BatonRun in one owner-signed run: the launcher and the permission block. `coordinator-bootstrap` is its old name, which leaves in the next release. | a new machine, or the session-start permission check fails |
| `local-parallel` | Runs several tasks at once on one machine: one subagent per task (its own worktree, `intake` to a draft PR, model `agents.worker_model`); the main session keeps the queue, relays spec approvals, post-checks each PR and merges it with `kit:merge-pr`. | the person wants several tasks done in parallel |
| `owner-sign` | For the owner only (`/vibemaestro-sdlc:owner-sign`, "ký các mục đang chờ"): lists the baton runs a session queued for the owner's signature (`go --queue`) and opens one owner dialog per item picked, in the session that queued it or another: a `claude` session in a terminal, Claude Code's VS Code extension or the Claude desktop app. | runs wait in the queue for the owner |
| `history` | In everyday mode: lists the quiet saves of the folder in plain words and writes the chosen one as a copy into `ban-cu/`, never over the work folder; the person takes the files they need, and a copy is removed only on their word. | the person asks what was saved or wants an earlier state of a file |

Useful reads of `kb/` that do not load whole files: `kb.py find <words>`, `kb.py list [--type T] [--status S]`, `kb.py outline <file>`. All three are read-only.

## Gates

A gate is a script that turns a rule into a pass or a fail. Gates exit 0 on pass, 1 on red, 2 when they could not conclude (never green), 64 on bad usage, 65 on an invalid config. In CI the workflows read the config from the **base** branch of the pull request, so a pull request cannot relax its own gate by editing `.vibemaestro/sdlc.json`.

`install-gates` (or `scripts/install_gates.py`) installs these six as workflows in `.github/workflows/` and scripts in `.vibemaestro/gates/`:

| Gate | Goes red when |
|---|---|
| `commit-discipline` | the PR has more than `commits.max_per_pr` commits; one file is touched by more than `commits.max_touches` commits; a side branch was merged in with a merge commit; a subject starts with `wip`, `fixup!`, `squash!` or `amend!`; or one review round is spread over several commits. A line `COMMIT EXCEPTION: <reason>` in the PR body excuses the first two only. Rule: `commit-unit`. |
| `pr-sensitive` | the PR body, a PR comment or a commit message holds a secret, a public IP, an account ID, an e-mail, a phone number or a personal home-directory path. Output shows only masked values. Rule: `pr-no-leaks`. |
| `pr-title` | the title breaks `pr.title.pattern` or `pr.title.max_len`; a branch outside `branch.intent_prefix` breaks `branch.pattern`; or, with `pr.title.intent_form: reject`, a ready PR that carries code still has an intent-file title. Every check is off by default. |
| `pr-body` | the body is over `pr.body.max_chars`, its summary over `pr.body.summary_max_lines` lines, or its evidence over `pr.body.evidence_max_lines` lines. Rule: `pr-body-shape`. |
| `pr-evidence` | no AI-review comment pins the PR's current head (a round comment by the owner, a member, a collaborator or the repository's own App named in `evidence.trusted_app`, whose first line is `tokens.round_comment_prefix`, the full head SHA, the word review and a round number); or the PR changes a path of `evidence.ui_paths` and no comment pinned to the head has `E2E pass` or `E2E không chạy: <reason of 15+ characters>` (`E2E not run:` too). Evidence pinned to an older head counts only when the head adds clean merges of the base and nothing else (no conflict resolved by hand, the same patch-id), and the gate says it carried it. A comment by the owner, a member, a collaborator, or the App the repository variable `PR_EVIDENCE_APP` names, on a ready PR re-runs a red evidence check on the head. Rule: `pr-body-shape`. |
| `dead-branches` | more than `dead_branches.max_merged_on_remote` remote branches are already inside the main line. It only reports and prints a cleanup command; it never deletes. |

When they run:
- Not on a draft: going ready (`ready_for_review`) starts the round. So the related tests run locally, and the fresh-context review happens, before you mark a PR ready; CI is the ready-time gate. In a public repository `pr-sensitive` also scans drafts, because a public draft is already exposed.
- An edit of the PR runs again only the gates that read what changed: `pr-body` and `pr-sensitive` on a body change, `pr-title` on a title change, and `commit-discipline` when the old or the new body holds the exemption token.
- A new commit cancels the runs of the head it replaces. No other event cancels a run, and none takes the place of a pending one.
- A skipped run tested nothing: the merge guard keeps the verdict of the last real run on the head, and a required check with no real run is red.

`install_gates.py` never overwrites a file: an existing file is kept, and `kept (differs)` marks one that is not what the plugin would write. With `--update` it replaces the plugin's own copies under `.vibemaestro/gates/` (a workflow, the allowlist and the signing-rules list are the repository's and stay kept), and `--only` also installs the opt-in `signing-rules` gate or the gate a dependent plugin declares in its `gates/install.json`. It does not write `.vibemaestro/sdlc.json`; it prints which keys each gate reads. With `gh` it then checks, read-only, that the repository variable named by `ci.runner_var` is set, and prints one warning when it is not.

`kb-check` is opt-in: `install_gates.py --only kb-check` writes `.github/workflows/kb-check.yml` and copies `kb.py`, the modules it imports and `kb-check.pin` to `.vibemaestro/gates/`. The workflow runs on every ready PR, from the base branch's copy and on the PR's tree: `kb.py check`, then `kb.py check links`. Run both: a bare `check` judges only the life of the documents, and a story plan row with no `Title`, an empty one, one over 80 characters or one with a backtick is red only in `check links`. The pin file holds the kit commit when the plugin is a git checkout (`-` for an installed copy, which has no `.git`) and the sha256 of the copied set (over `<name>\0<bytes>\0` of the files in name order). The copies are never overwritten (`--update` replaces them), and a base with no `kb.py` yet, the PR that adopts the gate, gets a warning and a pass. A repository onboarded earlier gets the gate the same way: a session runs `install_gates.py --only kb-check` and opens a PR, and a person merges it, because `.github/**` is a trust layer.

Two more checks run inside the scripts you already call, not as workflows:

- `scripts/open-pr.sh` runs the `pr-body` limits and the current-state gate (`current_state.gate`) before it opens a PR.
- `kb.py check current-state` checks the shape of `kb/current-state.md`: no history signs, and the size caps in `current_state.limits`.

The merge guard (`gates/merge_guard.py`), the GitHub write runner (`gates/gh_write.py`) and the machine-setup engine (`gates/bootstrap.py`) are not installed into a repository. They are the engines of the kit batons `kit:merge-pr`, `kit:gh-write` and `kit:bootstrap`, which a session runs through BatonRun. The guard merges one PR only when every condition holds (green checks, head is the reported SHA, no denied path, not behind the base) and reads its rules from `merge.*`.

## Rules and how hooks deliver them

A rule is a Markdown file in `rules/` with a front matter that says when it applies. The hooks match the file you are about to edit against `applyTo` (globs) and the command you are about to run against `applyWhen` (a regular expression). A matching rule is shown to the session just before the tool call, once per session. `workflow-core` has neither field and is delivered whole when the session opens.

| Rule file | Arrives when |
|---|---|
| `workflow-core.instructions.md` | the session opens |
| `coordinated-work.instructions.md` | deprecated, leaves in the next release. The session opens, only in a coordinated session: a worker session, or one where an enabled plugin of the same marketplace that depends on this one ships the file `sdlc-coordinated` at its root; elsewhere it is only a catalogue row |
| `git-process.instructions.md` | `git worktree add`, `intent-branch.sh worker-branch`, `git rebase`, `git merge`, `git commit --amend`, `git push --force` |
| `commit-unit.instructions.md` | `git commit`, `git rebase`, `git reset --soft`, `gh pr ready` |
| `pr-body-shape.instructions.md` | `gh pr create`, `gh pr edit`, `gh pr comment`, `open-pr.sh` |
| `pr-no-leaks.instructions.md` | `gh pr create/edit/comment/review/merge/close/reopen`, `gh issue create/edit/comment/close/reopen`, `gh api` writes to comments, pulls or issues, `open-pr.sh`, `git commit` |
| `before-ready.instructions.md` | `gh pr ready` |
| `measurement-commands.instructions.md` | `gh pr/issue/run/release/workflow/label/repo list`, `grep -c`, `git log A..B` |
| `test-quality.instructions.md` | editing a test file of any stack: under `tests/`, `test/`, `__tests__/` or `spec/`, or named `test_*`, `*_test.*`, `*.test.*`, `*_spec.*`, `*.spec.*`, `*Test.*`, `*Tests.*` |
| `document-precedence.instructions.md` | editing a file under `kb/`, `docs/` or a configured rules directory |
| `public-tree.instructions.md` | editing a file outside `kb/` and `public.private`, in a repository that sets `public.private` |
| `current-state-shape.instructions.md` | editing `kb/current-state.md` |
| `version-policy.instructions.md` | editing `**/.claude-plugin/plugin.json`, `**/.claude-plugin/marketplace.json` or `.changes/**` |
| `docs-final.instructions.md` | editing a root `README*`, `DEVELOPMENT*`, `CONTRIBUTING*`, `SECURITY*` or `CODE_OF_CONDUCT*` file, any `README.md` or `README.*.md`, or a file under `docs/` |
| `batonrun.instructions.md` | a privileged command run directly, among others `gh pr merge`, `gh repo delete`, `gh release delete`, `gh secret set`, a `gh api` write, `docker push` (also `buildx --push`), `claude plugin install/uninstall/update/marketplace`, `git push --force` or `--mirror`, a typed `BATON_PHASE=` |

What each rule says in one line:

- `git-process`: a worktree of your own inside the repository; one intent is one branch is one draft PR; one task is one commit; no push to main, no force push; reviewed commits are immutable.
- `commit-unit`: a commit is one task or one fix round, not one typing session; fold fix rounds before ready.
- `pr-body-shape`: the body is the current state, overwritten each round, and short; round history goes in comments.
- `pr-no-leaks`: no secret, public IP, account ID, e-mail or personal path in a PR body, comment or commit message.
- `before-ready`: before ready, evidence run on the final version, a correct current state, a fresh-context review (briefed with [`skills/ship/reviewer-brief.md`](skills/ship/reviewer-brief.md)): one round, a second only after a correctness defect, reading the changed functions whole, a third only for security or passphrase-holder work; a class sweep for each defect fixed, a stop after the second fix of one class, and no self-merge.
- `measurement-commands`: run a sure-positive control before you quote a count.
- `test-quality`: each test names the break it catches, with literal expected values and a refusal case per rule; red on main and green after; a test per risk the spec lists; no source-text, spec-wording or mock-only assertion; never revert the fix to see red; root cause before a fix.
- `document-precedence`: when two documents disagree, an explicit supersession wins, then the binding level, then the date.
- `public-tree`: in a repository that publishes its tree, every file outside `kb/` and `public.private` is public: nothing private, no pointer into `kb/`, no private issue number, and tests that run from that tree alone.
- `current-state-shape`: the file holds only the present state, overwritten, with a size cap.
- `coordinated-work` (deprecated, leaves in the next release): only when a coordinating session briefs one execution session per pull request: the roles, the brief as the contract, the coordinator's post-check.
- `docs-final`: READMEs and `docs/` are the final public description of what exists now: no dates, history, decisions, `kb/` pointers or private names; `kb/` keeps those.
- `version-policy`: see [Version policy](#version-policy).
- `batonrun`: see [BatonRun](#batonrun).

A repository adds its own rules in the directories listed in `rules.dirs` (`kb.py init` creates `.vibemaestro/rules`). A repository rule with the same name replaces the plugin's. `rules.disable` turns a rule off by name; `workflow-core` cannot be disabled. To run a command that a `level: block` rule denies, put the prefix `RULES_GATE=off` inside the command itself.

## Configuration

The config is one optional file at the repository root: `.vibemaestro/sdlc.json`. With no file, every default below holds. The file is merged over the defaults, so it only lists what differs.

```json
{
  "schema": 1,
  "language": "en",
  "commits": { "max_per_pr": 10 },
  "agents": { "review_model": "fable" }
}
```

Rules of the format:

- An unknown key at any depth is a warning, not a problem: the plugin ignores it, because a newer plugin may know it. A known key with a wrong value is a problem. A key that starts with `_` is ignored silently, so you can leave a `_comment`.
- Compatibility (rule `config-compat`):
  - a new key is optional and has a default;
  - a renamed or removed key is still read for a deprecation window, and the warning names its replacement;
  - a breaking change raises `schema`, and `python3 "$SDLC/scripts/kb.py" config migrate [--write]` carries a config up.
  - Set a new key in a repository only once every plugin that reads it (on every machine and CI runner) is at least the floor version; until then the default applies.
- A problem is handled by the caller. Hooks warn once per session and carry on with the defaults. `kb.py` and the gates exit 65 and name the key. The branch and PR cores exit 64.
- Read one effective value: `python3 "$SDLC/scripts/sdlc_config.py" get <dotted.key>`. Read the plugin default of a key whatever the file says: add `--default`.
- Validate the file, and list warnings (for example a rules directory that does not exist): `python3 "$SDLC/scripts/kb.py" config check`.
- `"language"` is `vi` or `en`. It is the language of the kb content (story, spec, plan, decisions), which every session, sandbox workers included, writes in it, and it sets the story card's labels, the section names of a spec, the PR-body headings and the flow lines. The default is `vi`; set `en` for English. A key you set in `tokens` wins over the language.

A subagent runs on the model of its job. A skill reads `agents.<key>` and passes it as the `model` of the Agent tool. The value is one of the aliases `fable`, `opus`, `sonnet`, `haiku`.

All keys of schema 1, with the plugin default. Where the default depends on `language`, the English value is in brackets.

| Key | Default | Meaning |
|---|---|---|
| `schema` | `1` | Config schema number, the major version of the format. The plugin refuses a number above its own and names the update to run. |
| `hooks` | `"auto"` | `"off"` silences every hook of the plugin in this folder and its subfolders, and the quiet save leaves the folder out. |
| `profile` | `"auto"` | `"everyday"` or `"developer"` fixes the kit's mode in this folder; `"auto"` chooses it (see [Everyday mode](#everyday-mode)). |
| `language` | `"vi"` | `"vi"` or `"en"`: the language of the kb content (every session writes in it) and of the story labels, spec section names, PR-body headings and flow lines. `kb.py init` records it in every new config, `"en"` unless answered, so only a config made before has the default. |
| `update_check` | `true` | `false` turns off the update reminder of a public install in this repository, for vibemaestro-sdlc and vibemaestro-brain (see the kit README, Update). |
| `branch.intent_prefix` | `"intent/"` | Prefix of an intent branch. |
| `branch.protected` | `["main", "master"]` | Branches that are never a PR head and never counted as dead. |
| `branch.pattern` | `null` | A regex that a head branch outside the intent prefix must match. Used by `pr-title`. |
| `pr.title.pattern` | `null` | A regex the PR title must match (`open-pr.sh` and `pr-title`). |
| `pr.title.max_len` | `null` | Longest allowed PR title. |
| `pr.title.intent_form` | `"allow"` | `"reject"` makes a ready PR that carries code and still has an intent-file title red. |
| `pr.body.max_chars` | `3000` | Cap on the PR body in characters. `0` turns the limit off. |
| `pr.body.summary_max_lines` | `10` | Cap on the non-empty lines of the summary. `0` turns it off. |
| `pr.body.evidence_max_lines` | `30` | Cap on the non-empty lines of the evidence. `0` turns it off. |
| `pr.draft` | `false` | `true` opens every PR as a draft. |
| `pr.flow` | four lines, the first ticked | Ignored: PR bodies have no flow checklist; the `pr-evidence` gate checks the evidence. A config that sets it gets a warning. |
| `pr.tester_exempt` | `null` | Ignored: an E2E exemption is the line `E2E không chạy: <reason>` in a comment pinned to the head (`pr-evidence`). A config that sets it gets a warning. |
| `pr.closing.keyword` | `"Closes"` | The GitHub closing keyword `open-pr.sh` writes before the issue number. One of `close`, `closes`, `closed`, `fix`, `fixes`, `fixed`, `resolve`, `resolves`, `resolved`. |
| `pr.closing.verify` | `true` | After it opens the PR, `open-pr.sh` reads back whether GitHub linked the closing issue. |
| `pr.closing.tries` | `10` | Reads of that link before it gives up. |
| `pr.closing.wait_s` | `2` | Seconds between two reads. |
| `pr.closing.deadline_s` | `30` | Total seconds for all reads. |
| `commits.max_per_pr` | `15` | Most non-merge commits in a PR (`commit-discipline`). |
| `commits.max_touches` | `4` | Most commits that may touch one file. |
| `commits.round_pattern` | `\bround\s*(\d+)\b` | Regex that finds a review round number (group 1) in a commit subject. The subject is matched lower case, without accents, with `đ` as `d`. |
| `current_state.path` | `"kb/current-state.md"` | The ledger file. |
| `current_state.template` | `"ledger"` | `"ledger"` (present state only, tight caps) or `"map"` (a map: no line cap, 28000 bytes, 400 characters a line, no history-sign check, a required five-column table). `map` also sets `table`, so it cannot be combined with `table_own_width: true`. |
| `current_state.limits.lines` | `120` | Most lines; `null` for no limit. |
| `current_state.limits.bytes` | `12000` | Most bytes. |
| `current_state.limits.line_chars` | `200` | Most characters on a line. |
| `current_state.limits.warn_ratio` | `0.85` | From this share of a cap, the checker prints a `WARNING` line (rc unchanged). |
| `current_state.forbid` | all eleven history signs | Ids of the history signs the checker rejects (dates, PR numbers, commit SHAs, past-tense words, update stamps, history headings). |
| `current_state.forbid_patterns` | `[]` | Extra signs: objects with an `id` and a `regex`. |
| `current_state.table` | `null` | `{"columns": N, "required": bool}`: every table not covered by a `tables` entry must have N columns; `required: true` also asks for at least one table. |
| `current_state.table_own_width` | `false` | `true` checks each uncovered table against its own header width. It is an alternative to `table`: set `table: null` first. |
| `current_state.tables` | `[]` | Per-table checks: column names, allowed values. |
| `current_state.no_empty_cells` | `false` | `true` rejects an empty table cell. |
| `current_state.exempt.min_reason_chars` | `0` | Shortest reason after a `tokens.no_state_change` exemption line. |
| `current_state.watch` | `[]` | Path prefixes whose change must come with a ledger edit, or with an exemption line. |
| `current_state.watch_exclude` | `[]` | Prefixes under a watched prefix that never force a ledger edit. |
| `current_state.pages` | `null` | A glob of one flat directory of ledger pages, for example `kb/state/*.md`. |
| `current_state.page_limits.lines` | `null` | Most lines of a page; `null` for no limit. |
| `current_state.page_limits.bytes` | `8000` | Most bytes of a page. |
| `current_state.page_limits.line_chars` | `400` | Most characters on a page line. |
| `current_state.page_limits.warn_ratio` | `0.85` | Warning share of a page cap. |
| `current_state.inject` | `false` | `true`: the SessionStart hook injects the current-state index at session start and after a compaction. |
| `current_state.gate` | `"builtin"` | The diff gate behind `open-pr.sh`: `"builtin"`, `"off"`, or `"external:<path>"` (a script of the repository). A missing external script blocks. |
| `current_state.labels` | `null` | `{"regex": <with a named group date>, "max_age_days": N}`: a label with no date, or an older one, gives a warning. |
| `rules.dirs` | `[]` | Repository rule directories, relative to the repository root (`kb.py init` writes `[".vibemaestro/rules"]`). |
| `rules.disable` | `[]` | Rule names to turn off, with or without `.instructions.md`. |
| `public.private` | `null` | Globs that stay private when the repository publishes its tree: it publishes every file outside `kb/` and these. `null` means it does not publish; `[]` is a valid answer. Write a directory as `dir/**`. Turns on the `public-tree` rule. |
| `evidence.ui_paths` | `null` | Globs of the repository's UI paths for the `pr-evidence` gate: a PR that changes one needs E2E evidence pinned to its head. `null` means no UI, no E2E asked. Set it only once every plugin that reads the config knows the key (rule `config-compat`). |
| `evidence.trusted_app` | `null` | The slug of the repository's own GitHub App, for the `pr-evidence` gate: a round comment that App's bot account posts (login `<slug>[bot]`, type Bot, posted through that App) counts like a member's. `null` means no App counts. `github-actions` is refused: every workflow of the repository posts as it, including one that echoes text a PR controls. Read at the base; set the repository variable `PR_EVIDENCE_APP` to the same slug so the App's comment also re-runs a red check. Set it only once every plugin that reads the config knows the key (rule `config-compat`). |
| `evidence.exempt` | `null` | `{"app": "<slug>", "paths": [globs]}`, for the `pr-evidence` gate: a PR that App's bot account opened (login `<slug>[bot]`, type Bot; if GitHub records an App on the PR, it must be that one) passes with no review or E2E comment when every changed file is changed in place under a glob of `paths` and each file's whole diff is one line that sets an image: `newTag: <tag>` or `digest: sha256:<64 hex>` (kustomize `images`), or `image: <reference>` naming the same image with another tag or digest; the same key and indent on both sides, nothing after the value. Anything else is refused: `newName`, any other key, a comment, two lines, an added, removed or renamed file. The gate judges who opened the PR, not who pushes to its branch later; the exemption is limited to one tag or digest line of the same image under the named paths. A PR that is not exempt gets a `not exempt:` line naming the failed condition, then the usual checks. No `app` or empty `paths` exempts nothing. Read at the base, so a PR that adds the key to itself is never exempt. Set it only once every plugin that reads the config knows the key (rule `config-compat`). |
| `sensitive.allowlist` | `".pr-sensitive-allow"` | File of sha256 hashes of values the `pr-sensitive` gate may let through, one per line with a `# reason`. Read from the base branch in CI. |
| `sensitive.scan` | `["pr_body", "pr_comments", "commit_messages"]` | What `pr-sensitive` scans. |
| `dead_branches.max_merged_on_remote` | `0` | Most merged-but-alive remote branches before `dead-branches` goes red. |
| `ci.runner_var` | `"CI_RUNNER"` | Name of the repository variable that picks the runner label of the installed workflows. The installed gate jobs first read the optional variable `CI_GATE_RUNNER` (a light runner for the gates) and fall back to this one. |
| `ci.runner_default` | `"ubuntu-latest"` | Runner label when that variable is unset. The value `"self-hosted only"` means no fallback: the installed workflows name no label, and a run with neither variable set fails at its start with a message naming the variable, instead of waiting for a hosted machine that never comes (for an organisation that runs only self-hosted runners). Any other value that is not a label (`[A-Za-z0-9._-]+`) warns, and install-gates refuses it. |
| `ci.backend` | `"github-actions"` | The CI backend the guarded merge reads checks from: `github-actions` (the only built-in value) or `external:<path>`. The installed workflows are GitHub Actions in either case. |
| `merge.deny_globs` | `null` | Paths the guarded merge refuses in its normal lane. `null` means unset, and the guard refuses to run, except for the PR that adds the config or changes it to add the `merge` section (the bootstrap lane); `[]` is a valid answer. `kb.py init` writes three globs. |
| `merge.admin_bypass` | `false` | `true` allows `--admin` on the guarded merge. It changes no condition. |
| `merge.required_checks` | `[]` | Check names that must be green. Empty asks for at least one green check run. |
| `merge.planner` | `null` | `{"script", "inputs"}`: the repository's test planner, which the guarded merge runs with `--behind auto` to judge a pull request behind its base. |
| `merge.touch_checks` | `[]` | Checks whose findings the guarded merge's `touches` judges: a denied path, or a red run of one of these checks, merges with no owner merge only when it is a touch the row the pull request names declares, under the owner's plan approval (`baton.py sign --by owner --approve`). Each needs a `merge.touch_inputs` entry. |
| `merge.touch_inputs` | `{}` | Per touch check, `{"workflow", "paths"}`: the workflow file that runs it and every path its result depends on (its gate, what the gate imports, its list file). A change to one is never plan-approved. |
| `merge.log` | `null` | File name of the merge log in the user state directory; `null` means `merge-log.jsonl`. |
| `merge.image_bump.enabled` | `false` | Turns on the image-bump lane of the guarded merge. |
| `merge.image_bump.tag_files` | `[]` | Files whose lines the lane may change, only to move the tag of the configured image. |
| `merge.image_bump.tree` | `null` | A directory prefix the lane also accepts changes under. |
| `merge.image_bump.revision` | `null` | `{"file", "pattern"}`: where the lane reads the revision it checks. |
| `merge.image_bump.registry` | `null` | `{"backend": "ghcr", "host", "image"}`: the registry where the lane checks that the new tag exists. |
| `rebase.identity` | `null` | `{"name", "email"}` used as the committer when `intent-branch.sh integrate` must rebase. It wins over the environment. |
| `upstream_issues` | `true` | Accepted and validated; nothing in this plugin reads it. |
| `intake.focus` | `"warn"` | An intent's `type:` (story, task, bug) and `focus:` (an open focus of the brain) at `intent-branch.sh create-intent` and in `kb.py check intent`: `"required"` refuses an intent without them (rc 9), `"warn"` prints one WARNING line and goes on, `"off"` reads neither. The next release makes `"required"` the default. |
| `issue.code` | `null` | The repository's 3-letter code (3 capital letters, like `KIT`). Set: `intent-branch.sh create-intent` opens the issue first, writes the key `<code>-<issue number>` as the intent's `key:` and names the branch `intent/<key>-<slug>`; the intent file keeps its dated name, and `kb.py plan status` links a PR by either branch name. `null`: branches stay `intent/<date>-<slug>`, with no key. |
| `infra.label` | `null` | The label an issue the kit opens for work that needs infrastructure help (runners, CI variables, a runner group, secrets, a cluster, Cloudflare, Vault) carries: `intent-branch.sh create-intent` or `retry-issue` with `--infra-blocked <what> --infra-tried <what>`, or a `kit:gh-write` `issue-create` with `"infra": true`. The issue gets the label when the repository has it; when it does not, its title starts with `[<label>] `. The label is never created. The body carries one line `Infra: blocked: <what> · tried: <what>`. `null`: nothing is added. |
| `agents.review_model` | `"opus"` | Model of the fresh-context review before ready (`ship`, `before-ready`). |
| `agents.search_model` | `"haiku"` | Model of a read-only search (`brainstorm`). |
| `agents.worker_model` | `"sonnet"` | Model of a worker that builds one task (`plan`, `batonrun`, `workflow-core`). |
| `kb.intent_max_bytes` | `16384` | Most bytes of a story (`kb/intent/*.md`): the whole file, UTF-8. `kb.py check` warns from 80 percent and is red over it, on a file the change touches (new, or its body changed; a frontmatter-only edit does not count). An over-limit file the change does not touch only warns. Over: a story keeps the request, the ACs and the questions and moves code-reading notes to the spec. |
| `kb.spec_max_bytes` | `32768` | The same for a spec (`kb/specs/*.md`). Over: split it by service or module. |
| `kb.plan_max_bytes` | `32768` | The same for a plan (`kb/plans/*.md`). Over: split it into waves. |
| `kb.spec_warn_bytes` | `40000` | Deprecated: read without error and does nothing; a warning names `kb.spec_max_bytes`. |
| `tokens.summary_heading` | `"Tóm tắt"` (`"Summary"`) | Heading of the PR-body summary. |
| `tokens.criteria_heading` | `"Tiêu chí chấp nhận"` (`"Acceptance criteria"`) | Heading of the criteria checklist. |
| `tokens.evidence_heading` | `"Bằng chứng chạy"` (`"Run evidence"`) | Heading of the evidence. |
| `tokens.flow_heading` | `"Luồng"` (`"Flow"`) | A heading `pr-body` reads as a section boundary when a PR body has it; the bodies `open-pr.sh` writes have none. |
| `tokens.fixes_line` | `"Vá cho"` (`"Patch for"`) | Line prefix for an issue the PR patches without closing it. |
| `tokens.not_run` | `"KHÔNG CHẠY:"` (`"NOT RUN:"`) | Token that opens an evidence section that could not be run. |
| `tokens.no_state_change` | `["NO STATE CHANGE:"]` | Tokens of the exemption line for a PR that changes no current state. |
| `tokens.commit_exception` | `"COMMIT EXCEPTION:"` | Token of the line that excuses a commit-count or file-touch threshold. |
| `tokens.round_comment_prefix` | `"SHA:"` | Prefix of a PR comment that records one review round. |
| `tokens.evidence_cut` | `"… (cắt {n} dòng giữa) …"` (`"… ({n} lines cut from the middle) …"`) | Marker that replaces the middle of a long evidence; `{n}` is the count cut. |
| `tokens.not_run_note` | Vietnamese text (English text) | Warning placed above an evidence that starts with `tokens.not_run`. |
| `tokens.criteria_note` | Vietnamese text (English text) | Note under the criteria checklist; `{evidence}` is the evidence heading. |
| `tokens.spec.context` | `"Bối cảnh"` (`"Context"`) | Heading of the first spec section. |
| `tokens.spec.goal` | `"Mục tiêu"` (`"Goal"`) | Heading of the second spec section. |
| `tokens.spec.out_of_scope` | `"Ngoài phạm vi"` (`"Out of scope"`) | Heading of the third spec section. |
| `tokens.spec.criteria` | `"Tiêu chí chấp nhận"` (`"Acceptance criteria"`) | Heading of the acceptance-criteria section, the last required one. |
| `tokens.spec.design` | `"Thiết kế"` (`"Design"`) | Heading of the optional design section. |
| `tokens.spec.constraints` | `"Ràng buộc"` (`"Constraints"`) | Heading of the hard constraints of a spec derived from a story. |
| `tokens.spec.risks` | `"Rủi ro cần test phủ"` (`"Risks to cover"`) | Heading of the risks the tests cover, in a spec derived from a story. |
| `tokens.spec.clarify` | `"Cần làm rõ"` (`"To clarify"`) | Heading of the open points of a spec derived from a story. |
| `tokens.spec.evidence` | `"Bằng chứng chạy"` (`"Run evidence"`) | Heading the last criterion of a spec of the earlier shape must name. |
| `tokens.spec.placeholder` | `"<ĐIỀN"` (`"<FILL"`) | Mark of a blank left in a skeleton; `kb.py check spec` rejects a spec that still has one. |

## Version policy

This section applies to a repository that publishes plugins, such as the kit itself. An application repository does not need it.

- **An ordinary pull request edits no version.** A pull request that changes `plugins/<name>/` adds one change file `.changes/<slug>.md` instead:

  ```
  ---
  plugins: vibemaestro-sdlc
  level: patch
  upgrade: Optional: what an existing user must do or will notice when they update.
  ---
  One line a user of the installed plugin understands: what changes for them.
  ```

  `level` is `patch` for a fix, `minor` for a feature, `major` for a breaking change (for this plugin, a `CONTRACT.md` row removed or renamed). A 0.x plugin may break in a minor. `upgrade` is optional; a pending change file may be edited only to add or change it. `supersedes:` and `cancels:` are optional too: the earlier change files, by their names without the leading date and `.md` (no two change files share that name), comma-separated, that this change replaces or undoes. A superseded change's line and upgrade note leave the next public release, so write this file's line as the final behaviour; a cancelled one leaves with the cancelling line, unless what it undoes was already published.
- **A release pull request** (skill `release`, started by a plan's release row) turns every pending change file into one version step per plugin, writes the `CHANGELOG.md` entries (the `upgrade` lines under `### Upgrade notes`), and sets `Frozen at` in `CONTRACT.md` when its surface moved. Each section is the final state since the plugin's previous public version: a version cut and not published joins the next cut, and a line that a `supersedes:` or `cancels:` names, or one already published, is taken out. `release.py notes <plugin> <version>` prints the body of that version's public release: its CHANGELOG section and how to update.
- **A fold** (`cut --fold --public <owner/name>`) is for a release that was cut but not published yet: the pending change files join that version's `CHANGELOG.md` sections instead of raising it. The public repository's tags `<plugin>--v<version>` tell whether it was published; when one exists, the fold is refused.
- **A hotfix pull request** branches from the branch `release`, so unreleased features never ride it. It raises one patch. A back-merge pull request from `backmerge/<sha12>` brings it to main and merges with a merge commit, never a squash.
- **After either merges**, a baton script you sign moves the branch `release` to the release commit, or, after a hotfix, pushes `backmerge/<sha12>` and opens its pull request; the repository publishes the release its own way. The kit's own public release writes each released version into its `plugin.json` and tags `<plugin>--v<version>`.
- Main stays shippable after every merge, because a release ships every pending change file.

The commands, read-only unless noted:

```bash
python3 "$SDLC/scripts/release.py" check --public <owner/name>   # is this change a valid ordinary, release, hotfix or back-merge change?
python3 "$SDLC/scripts/release.py" plan --public <owner/name>    # what a cut would do here (the public tags say what is published)
python3 "$SDLC/scripts/release.py" cut --public <owner/name>     # writes the working tree into a release
python3 "$SDLC/scripts/release.py" cut --hotfix   # the same for a hotfix
python3 "$SDLC/scripts/release.py" cut --fold --public <owner/name>   # joins the pending change files to a version cut but not published
```

`release.py check` runs in CI. It exits 0 when the change fits its kind, 1 when it is red, 3 when the check could not run locally (in CI that case is red), 64 on bad usage.

## BatonRun

A write outside the session (a GitHub write such as a merge, a registry push, a change to the user's plugin config, a force push, a deletion) is one **run**: a single baton script that is checked, rehearsed against the plan it declares, signed, run, post-checked, undone on failure, and logged. The session runs it itself with `baton.py go <script>`; the owner is never handed command lines to type. Some runs need the owner's signature. The mode (`manual` or `auto`) decides which, and only the owner changes it. A hand-written baton needs only the skill `batonrun`; the standard and the run catalogue are in [docs/batonrun.md](docs/batonrun.md).

## Troubleshooting

Run these in the repository that has the problem. `$SDLC` is the plugin directory (see [Quick start](#quick-start)). Script messages follow the repository's `language`: Vietnamese unless `.vibemaestro/sdlc.json` sets `"language": "en"`; a few are English in both.

| Symptom | Command | What it tells you |
|---|---|---|
| The plugin does not load, or you want its version | `claude plugin list` | Status and `Version:` of every installed plugin. `claude plugin install` exits 0 even when a dependency is missing, so read this. |
| The manifest looks broken | `claude plugin validate "$SDLC"` | `Validation passed`, or what is wrong. |
| No reminders appear | `python3 "$SDLC/scripts/sdlc_config.py" get hooks` | `off` means the repository silenced the hooks. |
| A warning about the config at session start, or a script exits 65 | `python3 "$SDLC/scripts/kb.py" config check` | The invalid key and the reason, plus warnings, such as a key this plugin does not know (a newer plugin may: `claude plugin update vibemaestro-sdlc@vibemaestro`). |
| A document in `kb/` is rejected | `python3 "$SDLC/scripts/kb.py" check` | Lifecycle problems in front matter, and a story, spec or plan this change touches that is over its byte limit (`kb.intent_max_bytes`, `kb.spec_max_bytes`, `kb.plan_max_bytes`). |
| A spec is rejected | `python3 "$SDLC/scripts/kb.py" check spec <date>-<slug>` | The missing, empty or misplaced section; a blank left; a criterion with no command. Exit 65. |
| `kb/current-state.md` is rejected | `python3 "$SDLC/scripts/kb.py" check current-state` | Each offending line, or the size over a cap. Exit 65. |
| A link between intent, spec and plan is broken | `python3 "$SDLC/scripts/kb.py" check links --base origin/main` | Links that fail in the files your change touches. |
| `intent-branch.sh` exits 3, 6 or 7 | read the message | 3: `kb/intent/<slug>.md` does not exist yet. 6: the branch exists. 7: run from the wrong place, for example `worker-branch` or `integrate` in the main tree instead of a linked worktree. |
| `open-pr.sh` exits 3, 4 or 5 | read the message | 3: the evidence is missing. 4: the current-state gate refused. 5: not in a linked worktree. 2: the body is over the `pr.body.*` limits. |
| The version check is red | `python3 "$SDLC/scripts/release.py" check` | Which rule of the change kind failed. |
| BatonRun says a permission is missing | `python3 "$SDLC/scripts/baton.py" permissions --check` | Exit 7 and a `fix:` line with the commands to run. `--print` shows the permission block, `--install-launcher` installs the launcher. |
| A gate is red in CI | run the same script, for example `python3 .vibemaestro/gates/commit_discipline.py origin/main HEAD` | The measure that failed. Exit 2 means it could not conclude. |
| A command is denied by a `level: block` rule | put `RULES_GATE=off` inside the command | Skips the block for that one command. |

## Related documents

- [CONTRACT.md](CONTRACT.md): the frozen interface for automated consumers, with every exit code.
- [CHANGELOG.md](CHANGELOG.md): what changed in each release.
- [docs/batonrun.md](docs/batonrun.md): the BatonRun standard.
- [docs/ai-native-sdlc.md](../../docs/ai-native-sdlc.md): the AI-native software development life cycle this plugin implements.
- [docs/README.md](../../docs/README.md): the documentation index for the whole kit.
- [README.md of the kit](../../README.md) and [vibemaestro-brain](../vibemaestro-brain/README.md): the kit and its other plugins, which depend on this one.
