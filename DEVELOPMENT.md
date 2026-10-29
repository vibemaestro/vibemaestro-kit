English | [Tiếng Việt](DEVELOPMENT.vi.md)

# Development

How to work on the kit itself, in a checkout or a fork: the layout of the repository, installing from a checkout, the tests, the
consumer contract, releases and fetching the repository at a SHA. To use the kit, start at the [README](README.md); the
documentation index is [`docs/README.md`](docs/README.md). The kit takes no pull requests: questions, bug reports and proposals go
to the issues of the public repository (see [Contributing](README.md#contributing)).

## Layout

```
.claude-plugin/marketplace.json            the marketplace "vibemaestro"
plugins/vibemaestro-sdlc/                  the process plugin: hooks, rules, skills, scripts, gates, batons, CONTRACT.md
plugins/vibemaestro-brain/                 the memory plugin: the brain command, hooks, skills
docs/                                      the concepts, the BatonRun standard, the research findings
.changes/                                  one change file per pull request that changes a plugin
.github/actions/fetch-plugin/action.yml    copies the repository at a SHA into a directory
.github/workflows/                         CI: the tests, the export gate, the PR body check
tests/                                     run-all.sh, the suites, fixtures
scripts/                                   the public export, its scan gate and the term scanner
```

Inside `plugins/vibemaestro-sdlc/`:

```
hooks/hooks.json            SessionStart and PreToolUse (Edit, Write, NotebookEdit, Bash) commands
scripts/vsdlc.py            the hook core; session-start.py, pre-edit.py and pre-bash.py are its entry points
scripts/hookout.py          hook output: warnings and once-per-session de-duplication
scripts/rules.py            the rule lookup (applyTo, applyWhen, level: block); rule_packs.py the rules of dependent plugins
scripts/sdlc_config.py      the config reader and validator
scripts/kb.py               the kb command; kb_index.py (find, list, outline, check), kb_plan.py (plan status), init_setup.py (init)
scripts/current_state.py    the current-state checks and the diff gate
scripts/intent_branch.py    the branch core, behind intent-branch.sh; open_pr.py the PR core, behind open-pr.sh
scripts/install_gates.py    installs the gates into a repository
scripts/release.py          check, plan and cut of a release
scripts/baton.py            the BatonRun runner; baton-launcher.py the stable launcher
gates/                      the gate scripts, gate_common.py, and workflows/ (SHA-pinned workflow templates)
batons/                     the kit batons (kit:merge-pr, kit:gh-write, …)
templates/                  the baton skeleton and the baton kinds
```

Everything a plugin needs at run time lives in its own directory: Claude Code's install copies only that directory and drops
symlinks that point out of it, so a plugin has no symlink and no `../..` path that reaches outside it.

## Install from a checkout

```bash
claude plugin marketplace add <path to a checkout>
claude plugin install vibemaestro-sdlc@vibemaestro
```

Then open a new session in an application repository and check `claude plugin list`. `tests/test-install.sh` proves the install
from a local directory. What counts as an update depends on the plugin's `plugin.json`:

- **with a `version`** (a released tree carries each plugin's released version): the install is keyed by that version, and
  `claude plugin update` finds nothing new until it changes; to try an edit, raise the `version` in that plugin's `plugin.json`;
- **without a `version`**, Claude Code computes one from git and every new commit is an update: a marketplace added from a git
  repository or URL takes the commit SHA of the marketplace repository; one added from a local directory that is a git checkout
  takes the checkout's HEAD SHA (pull the checkout first); a local directory without `.git` is `unknown`, and `plugin update`
  answers `refreshed from source`, so it follows whatever the directory holds.

To update:

```bash
claude plugin marketplace update vibemaestro
claude plugin update vibemaestro-sdlc@vibemaestro
```

Without versions, a sibling dependency is named bare, with no range: a range against a version that Claude Code computes from a commit fails to
load ("installed version unknown"). A release writes each released version into the plugin's manifest and a version range on
each sibling dependency.

## Run the tests

```bash
bash tests/run-all.sh
```

The suites need no secret, no other repository and no location setting. Prerequisites: `python3` with PyYAML
(`pip3 install --user pyyaml`), `git` and `bash`; they run on macOS (BSD userland) and on Linux (GNU userland).

- One suite: `bash tests/run-all.sh hook` (matched by name). Only the suites a change touches:
  `bash tests/run-all.sh --changed origin/main`; the planner `tests/plan.py` reads `tests/suites.map`.
- Without the `claude` CLI, the parts that need it (validate, install from a directory, hooks run from the installed copy)
  print a `SKIP` line. `PLUGIN_REQUIRE_CLAUDE=1 bash tests/run-all.sh` makes them required.
- The tests check code, not documents: a path in `tests/map-exclusions.txt` (the READMEs, `docs/`, release notes) wakes
  no suite, so a documentation-only change runs only the `@always` suites.
- Check the manifests with `claude plugin validate plugins/<name>` and the marketplace with `claude plugin validate .`.

CI: `.github/workflows/test.yml` runs the plan of the changed suites on every ready pull request; a push to `main` runs no test
suite, only the scans (`scan-terms`, `public-tree`). It runs on the runner named by the repository variable `CI_RUNNER`.
Unset or empty, a private repository's run fails at once (it never falls back to a
GitHub-hosted runner) and the public repository uses a GitHub-hosted one. The gate jobs (`export-gate`, `pr-body`, `public-tree`,
`scan-terms`) run on the optional repository variable `CI_GATE_RUNNER` (a light runner), falling back to `CI_RUNNER`.
`.github/workflows/test-full.yml` runs the full suite twice a week (Sunday and Wednesday, 19:00 UTC); a red run opens one issue
labelled `full-run-red`.

## The consumer contract

The sdlc plugin has a written consumer contract, [`plugins/vibemaestro-sdlc/CONTRACT.md`](plugins/vibemaestro-sdlc/CONTRACT.md),
shipped inside the plugin. For every release of the major version on its `Frozen at` line it freezes the items it
lists, among them: the marketplace name and the plugin id; the layout; the action `.github/actions/fetch-plugin` and its one
input `dest`; recognising a worker session by `INTENT_SLUG` and `SEAT` together; that the plugin directory works when it is copied alone
out of a cloned marketplace; the entry points and gate scripts with every exit code; config schema 1 with its keys; and how the
rules of a dependent plugin are found. Everything else (rule and skill text, messages, the Python cores behind the two adapters)
may change in a minor release.

- `bash tests/test-contract.sh` proves each item against the tree and goes red when the list and the tree disagree;
  `bash tests/test-contract.sh <id>` proves one item.
- Every pull request that touches `plugins/` keeps it green. A change of the surface edits `CONTRACT.md` in the same pull request
  and adds a change file naming `vibemaestro-sdlc` at `major` (something removed, renamed or given another meaning) or `minor`
  (added or reworded); the release that ships it sets `Frozen at`. The suite checks this against `main`, in CI too.
- An automated consumer (a CI job, a build that copies the plugin) pins one full SHA of this repository in one place and moves it only by
  a pull request that runs its own contract test. A laptop does not pin: it installs from the marketplace and updates.

## Releases

A pull request that changes `plugins/<name>/` adds one change file under `.changes/` and writes no version anywhere; the format
is in [`.changes/README.md`](.changes/README.md). A release pull request turns every pending change file into a `## <version>`
section of each named plugin's `CHANGELOG.md`; the version policy and the commands are in the sdlc README,
[Version policy](plugins/vibemaestro-sdlc/README.md#version-policy).

## Fetch the repository at a SHA

The composite action `.github/actions/fetch-plugin` copies the whole repository at the SHA it is called with (no `.git`) into a
directory, for a build context or to take the plugin at a pinned SHA. It needs no secret and makes no network call.

```yaml
- uses: <owner>/<repo>/.github/actions/fetch-plugin@<full SHA>
  with:
    dest: plugin-ctx          # the one input, required
```

`tests/test-fetch-plugin.sh` runs the action's `run` step on a checkout. A workflow of another repository can call the action only when
this repository's Actions are shared with it. Another repository that uses the
branch and PR cores (`intent_branch.py`, `open_pr.py` and their `.sh` adapters) takes them pinned at a SHA of this repository:
the cores read the repository they run in, not the place the plugin lives.
