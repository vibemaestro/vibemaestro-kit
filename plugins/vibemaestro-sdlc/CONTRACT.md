# Consumer contract of vibemaestro-sdlc

This file is the surface an automated consumer of this plugin may rely on. Such a consumer pins one SHA of this repository
(the rule `pin-automated-consumers`: one pin place per consumer, moved only by a pull request that runs the consumer's contract test).
Everything listed between the two `surface` markers below is frozen for the major version named on the `Frozen at` line.
Everything else may change in any release: rule text, skill text, hook reminders, message wording, the order of output lines,
the Python cores behind the two adapters (`intent_branch.py`, `open_pr.py`) beyond the calls listed under Dependent calls, file names not listed here, and new keys, codes or
entry points that are not listed yet.

Each item is proved against the real tree by `bash tests/test-contract.sh <id>` from a checkout of this repository; without an
id the suite proves every item. Every exit-code row is proved by one trigger per reason its meaning lists. The suite also fails
when this list and the suite disagree (a row with no check, a check or trigger with no row), when a config key of the schema
has no row, and when the surface changes without the change file below. It cannot see an exit code a script gains without a
row: whoever adds an exit code adds its row and its trigger in the same pull request. For config keys it checks that each
key exists, reads, and accepts its default value and the values of the worked example; it cannot see a narrower set of
accepted values that still holds those (for example `null` no longer accepted where the default is a number), which is a
breaking change all the same.

Change rule, for every pull request that touches this plugin:

- `tests/test-contract.sh` stays green. A pull request that changes the surface edits this file in the same pull request.
- Removing or renaming an item, a fact, an exit code or a config key, giving an exit code another meaning, or raising the config
  schema is a breaking change: the major version goes up.
- Adding a fact, an exit code, an entry point or a config key, or rewording a row, is a minor change.
- A config key also follows the rule `config-compat`: a new key is optional with a default, an older reader warns about it and
  ignores it, and a rename, removal or type change keeps the old form readable for a deprecation window (`DEPRECATED` in
  `scripts/sdlc_config.py`), proved by `bash tests/test-config-compat.sh` against the floor reader.
- A dependent call (the section Dependent calls) removed, renamed, or changed in what it holds (a flag, an exit code, an output,
  a name it defines) is a breaking change, and the change file's one line also names the old call in backticks, as the row
  writes it: that line is what the dependent reads when it moves its pin.
- Either way the pull request adds a change file `.changes/<slug>.md` naming `vibemaestro-sdlc` at that level (`minor`, or
  `major` for a breaking change) and leaves the version and `Frozen at` alone; the release that ships it raises the version (the
  `## <version>` heading of `CHANGELOG.md`, which the public export writes into the manifest: the private repository carries no
  version) and sets `Frozen at` to it; the first public release, 0.1.0, freezes the surface anew.
  The suite checks the change file against the
  base branch (`origin/main`) wherever that branch can be read, CI included: any change of the surface needs at least `minor`, and
  a removed or renamed item, fact, exit code or key needs `major`. Whether a reworded meaning is a new meaning (major) is the
  reviewer's call; the suite treats it as a rewording. Before the base has `.changes/`, the older rule holds: the manifest version
  goes up in the same pull request and `Frozen at` becomes it.

Keeping Dependent calls current: when a repository that pins this one starts calling a file, function, subcommand, flag,
output or variable of it that no row lists, it adds the row and its probe (`DEP_CALLS` in `tests/test-contract.sh`) in a pull
request here, merged before its own pin moves. Where each call is used is recorded in this repository's private records.

Frozen at: 0.2.0

<!-- surface:begin -->
## Items

| id | frozen | proof |
|---|---|---|
| `marketplace` | the marketplace name and the plugin id | `bash tests/test-contract.sh marketplace` |
| `layout` | the marketplace file at the repository root and the `source` form of the plugin | `bash tests/test-contract.sh layout` |
| `fetch-action` | the composite action that copies this repository at a SHA, and its one input `dest` | `bash tests/test-contract.sh fetch-action` |
| `sandbox-env` | a session is a sandbox session exactly when both variables are set and not empty | `bash tests/test-contract.sh sandbox-env` |
| `seedable` | the plugin directory, copied alone out of a cloned marketplace by its `source`, runs its hooks and every entry point | `bash tests/test-contract.sh seedable` |
| `cli` | the entry points below and their exit codes | `bash tests/test-contract.sh cli` |
| `config-schema` | config schema 1: its file, its number and its keys | `bash tests/test-contract.sh config-schema` |
| `rule-packs` | the rules of an installed plugin that declares a dependency on this one are served by its hooks: where they are found, and how they rank | `bash tests/test-contract.sh rule-packs` |
| `dependents` | the calls that repositories pinning this one make into it, listed under Dependent calls, each doing what its row holds | `bash tests/test-contract.sh dependents` |

## Facts

| id | fact | value |
|---|---|---|
| `marketplace` | marketplace name | `vibemaestro` |
| `marketplace` | plugin id | `vibemaestro-sdlc@vibemaestro` |
| `layout` | marketplace file | `.claude-plugin/marketplace.json` |
| `layout` | plugin source | `./plugins/vibemaestro-sdlc` |
| `layout` | plugin manifest | `plugins/vibemaestro-sdlc/.claude-plugin/plugin.json` |
| `fetch-action` | action file | `.github/actions/fetch-plugin/action.yml` |
| `fetch-action` | runs | `composite` |
| `fetch-action` | inputs | `dest` |
| `fetch-action` | required inputs | `dest` |
| `fetch-action` | copies | the repository tree without `.git` into `dest` |
| `sandbox-env` | variables | `INTENT_SLUG SEAT` |
| `seedable` | copied directory | the `source` of the plugin, alone |
| `config-schema` | config file | `.vibemaestro/sdlc.json` |
| `config-schema` | schema | `1` |
| `rule-packs` | registry | `$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json` |
| `rule-packs` | registry without CLAUDE_CONFIG_DIR | `~/.claude/plugins/installed_plugins.json` |
| `rule-packs` | manifest under installPath | `.claude-plugin/plugin.json` |
| `rule-packs` | dependency named in dependencies | `vibemaestro-sdlc` |
| `rule-packs` | rules directory under installPath | `rules` |
| `rule-packs` | rule files | `*.instructions.md` |
| `rule-packs` | precedence | a pack rule never takes the name of a rule of this plugin; a repo `rules.dirs` rule replaces it; between packs, the first plugin id in sort order |
| `rule-packs` | project scope | an entry with a `projectPath` counts only when it is the session's project directory |
| `rule-packs` | enabled | served only when `enabledPlugins` says true in the last of the user, project, local and managed settings that names the plugin |

## Exit codes

Paths are relative to the plugin directory. An entry point is called by its path; the hooks are the commands of `hooks/hooks.json`.

| entry point | rc | meaning |
|---|---|---|
| `scripts/intent-branch.sh` | 0 | done |
| `scripts/intent-branch.sh` | 1 | `retry-issue` could not create the issue (best effort) |
| `scripts/intent-branch.sh` | 2 | environment: not a git repository, no `python3` or core, an argument the core rejects |
| `scripts/intent-branch.sh` | 3 | `kb/intent/<slug>.md` is missing |
| `scripts/intent-branch.sh` | 4 | the branch cannot be integrated (BLOCK) |
| `scripts/intent-branch.sh` | 5 | the base, the target intent or the branch to integrate cannot be used |
| `scripts/intent-branch.sh` | 6 | the branch already exists |
| `scripts/intent-branch.sh` | 7 | run from the wrong place (main tree without `--no-checkout`, submodule, `GIT_DIR`) |
| `scripts/intent-branch.sh` | 8 | the task branch has more than one commit over its cut point |
| `scripts/intent-branch.sh` | 64 | bad arguments |
| `scripts/open-pr.sh` | 0 | done; stdout is the PR number (with `--dry-run`: the payload) |
| `scripts/open-pr.sh` | 1 | `gh` refused |
| `scripts/open-pr.sh` | 2 | environment (no `gh`, `python3` or core), or the body cannot be built (an empty summary, or a body over the `pr.body.*` limits) |
| `scripts/open-pr.sh` | 3 | the evidence is missing |
| `scripts/open-pr.sh` | 4 | the current-state gate refused |
| `scripts/open-pr.sh` | 5 | not in a linked worktree |
| `scripts/open-pr.sh` | 64 | bad arguments, a title outside the config, an invalid config |
| `scripts/open-pr.sh` | 66 | a file argument cannot be read |
| `scripts/kb.py` | 0 | done |
| `scripts/kb.py` | 2 | not a git repository, or `kb/` not set up |
| `scripts/kb.py` | 6 | the file already exists |
| `scripts/kb.py` | 64 | bad arguments |
| `scripts/kb.py` | 65 | a spec or the current state does not pass its check, or the config is invalid |
| `scripts/kb.py` | 66 | no file to check |
| `scripts/sdlc_config.py` | 0 | `get`: the value is printed |
| `scripts/sdlc_config.py` | 64 | bad usage, an unknown key, an invalid config |
| `scripts/install_gates.py` | 0 | done, or nothing to do; the runner-variable check (a WARNING or a skipped line) never changes it |
| `scripts/install_gates.py` | 64 | bad usage (unknown gate, bad runner label, not a git repository) |
| `scripts/install_gates.py` | 65 | invalid config |
| `scripts/baton.py` | 0 | done |
| `scripts/baton.py` | 1 | the script fails `check` (its Params, its parameter checks, a kept baton's Targets), or its rehearse fails (a plan line outside Expect, or outside the declared Targets of a baton with Params); `go` refuses an `input` value older than 120 s; `pack`'s source fails `check` as a kept baton of the target place |
| `scripts/baton.py` | 2 | environment: no `bash`, or the state directory cannot be written; `pack` finds a place's lock still held after 30 s |
| `scripts/baton.py` | 3 | refused, nothing ran: no signature matches, a seal differs from the one shown, the mode does not allow the signer, `sign --by owner` has no record of the owner's dialog for that call (for a `project:` or `user:` baton, of the file it resolves to), or it stopped before the run phase; a queued item (`sign --by owner --queued`, `run --queued`) that is absent, not signed, expired, used, damaged (its bytes changed after the dialog opened or after signing), signed from the session or Claude Code process that queued it, run from another directory, or whose rehearse no longer gives the sealed plan; `log --wait-queued`: the item can no longer be signed; a `project:` or `user:` baton whose bytes no keep record pins on this machine, or that were retired, unless a `project:` baton's bytes are the blob at its path on `refs/remotes/origin/HEAD` (a branch of origin) and origin's canonical URL is on the owner's remote list (`mode remotes`); a project root or its `.vibemaestro/batons` that another user owns or others can write; an input copy that no longer holds its bytes (made again: the next call works); `pack` finds no `ok` run of these bytes in this machine's `log.tsv` (in a sandbox, a `project:` keep of a baton whose Stops is not none also takes a `go` that stopped for the owner on these bytes), the same bytes kept under another name in that place, or the name kept with another `Stops`, or is asked to move a source that is not pinned |
| `scripts/baton.py` | 4 | the run or its post-check failed, and undo put the state back |
| `scripts/baton.py` | 5 | the state is unknown: undo failed too, or the run was interrupted; `pack` was interrupted (the same command finishes it) |
| `scripts/baton.py` | 6 | `new`: the file already exists |
| `scripts/baton.py` | 7 | `permissions --check`: a permission rule is missing, stale or unsafe |
| `scripts/baton.py` | 8 | `go`: the baton needs the owner's signature (a Stops item, or mode manual); nothing was signed, nothing ran. A value that needs quoting gets no owner command (the owner's dialog shows only a literal command): its text goes through an input file |
| `scripts/baton.py` | 9 | `log --wait-names`: at the deadline a named script's latest run line since `--since` is not ok, or it has none; `log --wait-queued`: at the deadline the item is not signed |
| `scripts/baton.py` | 10 | `permissions --check`, or `permissions --install-launcher` without `--force`: this `baton.py` is an installed copy that no `vibemaestro-sdlc@vibemaestro` entry of the registry lists any more, and the entry the launcher would run is another version directory (the session started before a plugin update); one line names both versions and says restart Claude Code; nothing written |
| `scripts/baton.py` | 64 | bad usage: a call that does not fit the baton's Params (a key missing, unknown or given twice, a word with no `=`, a value that fails its type), a prefix other than `kit:`, `kind:`, `project:` or `user:`, a bare name, a kept baton or place reached through a link, a relative HOME for `under:~`, a state directory whose path is not a plain path for a file value; a `pack` target with no place outside a sandbox (in a sandbox a bare name is `project:<name>`), `user:` in a sandbox, or a place other than `project:` or `user:`; `mode trust` or `mode untrust` with a remote that is not a network remote; a name a kit or callable kind ships, a copy name (`-v<digits>`, `-<7 or more hex>`), a move inside one place; `go --queue` in a sandbox, with no session id, with `--by`, or on a baton the session may sign itself; `--queued` with a malformed id, with a signer other than the owner, or with a word after the id |
| `scripts/baton.py` | 66 | the script cannot be read: no such name in the place named, no project root, a kept baton over 256 KiB; `pack`'s source cannot be read (absent, not a regular file, over 256 KiB); `pack --retire` of a sha no keep record of that name names |
| `gates/commit_discipline.py` | 0 | pass |
| `gates/commit_discipline.py` | 1 | red |
| `gates/commit_discipline.py` | 2 | could not conclude |
| `gates/commit_discipline.py` | 64 | bad usage |
| `gates/commit_discipline.py` | 65 | invalid config |
| `gates/pr_sensitive.py` | 0 | clean |
| `gates/pr_sensitive.py` | 1 | a sensitive value |
| `gates/pr_sensitive.py` | 2 | could not conclude |
| `gates/pr_sensitive.py` | 64 | bad usage |
| `gates/pr_sensitive.py` | 65 | invalid config |
| `gates/pr_title.py` | 0 | pass, or not applicable |
| `gates/pr_title.py` | 1 | red: the title breaks the config, or the payload cannot be read |
| `gates/pr_title.py` | 2 | could not conclude |
| `gates/pr_title.py` | 64 | bad usage |
| `gates/pr_title.py` | 65 | invalid config |
| `gates/merge_guard.py` | 0 | every condition holds (dry run), or the pull request merged |
| `gates/merge_guard.py` | 1 | a condition fails (each failed condition is named) |
| `gates/merge_guard.py` | 2 | could not conclude: a `gh` call failed, a GitHub read was incomplete, GitHub refused the merge pinned to the head or left it pending, an `external:` adapter exited, or the merge log cannot be written |
| `gates/merge_guard.py` | 64 | bad usage: bad arguments (a short head SHA, a `--behind-ok-clean` glob that is not docs-only, `--behind` with another value than `auto` or beside `--behind-ok` or `--behind-ok-clean` among them), `--admin` without `merge.admin_bypass` or in bootstrap, `--image-bump` with the lane off or in bootstrap, `--require-image` without a registry, naming another image or in bootstrap |
| `gates/merge_guard.py` | 65 | the config at the pull request's base is invalid, or `merge.deny_globs` is not set there; in bootstrap, the config the pull request adds is invalid, sets no `merge.deny_globs` or names an `external:` adapter |
| `gates/gh_write.py` | 0 | every condition of the spec holds (plan mode), or the step did what it said (a run step, the post-check, an undo step, a recovery step) |
| `gates/gh_write.py` | 1 | a condition fails (each failed condition is named; a repository that is not private, or is internal, is `refuse-public`), a run step refuses (the signed plan differs, the world moved, the journal), the post-check finds a live state other than the posted one, or an undo step leaves a state alone (changed since the run, or a write that may have landed and cannot be found) |
| `gates/gh_write.py` | 2 | could not conclude: a `gh` call failed or printed something that is not JSON |
| `gates/gh_write.py` | 64 | bad usage: bad arguments, or the spec breaks a rule (a deletion, a repository creation, an unknown kind or key; each refusal is named) |
| `gates/dead_branches.sh` | 0 | at or under the threshold |
| `gates/dead_branches.sh` | 1 | over the threshold |
| `gates/dead_branches.sh` | 2 | could not conclude |
| `gates/dead_branches.sh` | 64 | bad usage |
| `gates/dead_branches.sh` | 65 | invalid config |
| `hooks/hooks.json` | 0 | every hook command, always: also on a payload that is not JSON |

## Config keys of schema 1

A key is a dotted path into `.vibemaestro/sdlc.json`; `scripts/sdlc_config.py get <key>` reads it.

| key |
|---|
| `schema` |
| `hooks` |
| `language` |
| `update_check` |
| `branch.intent_prefix` |
| `branch.protected` |
| `branch.pattern` |
| `pr.title.pattern` |
| `pr.title.max_len` |
| `pr.title.intent_form` |
| `pr.body.max_chars` |
| `pr.body.summary_max_lines` |
| `pr.body.evidence_max_lines` |
| `pr.draft` |
| `pr.flow` |
| `pr.tester_exempt` |
| `pr.closing.keyword` |
| `pr.closing.verify` |
| `pr.closing.tries` |
| `pr.closing.wait_s` |
| `pr.closing.deadline_s` |
| `commits.max_per_pr` |
| `commits.max_touches` |
| `commits.round_pattern` |
| `current_state.path` |
| `current_state.template` |
| `current_state.limits.lines` |
| `current_state.limits.bytes` |
| `current_state.limits.line_chars` |
| `current_state.limits.warn_ratio` |
| `current_state.forbid` |
| `current_state.forbid_patterns` |
| `current_state.table` |
| `current_state.table_own_width` |
| `current_state.tables` |
| `current_state.no_empty_cells` |
| `current_state.exempt.min_reason_chars` |
| `current_state.inject` |
| `current_state.watch` |
| `current_state.watch_exclude` |
| `current_state.pages` |
| `current_state.page_limits.lines` |
| `current_state.page_limits.bytes` |
| `current_state.page_limits.line_chars` |
| `current_state.page_limits.warn_ratio` |
| `current_state.gate` |
| `current_state.labels` |
| `rules.dirs` |
| `rules.disable` |
| `public.private` |
| `evidence.ui_paths` |
| `sensitive.allowlist` |
| `sensitive.scan` |
| `dead_branches.max_merged_on_remote` |
| `ci.runner_var` |
| `ci.runner_default` |
| `ci.backend` |
| `merge.deny_globs` |
| `merge.admin_bypass` |
| `merge.required_checks` |
| `merge.log` |
| `merge.planner` |
| `merge.image_bump.enabled` |
| `merge.image_bump.tag_files` |
| `merge.image_bump.tree` |
| `merge.image_bump.revision` |
| `merge.image_bump.registry` |
| `rebase.identity` |
| `upstream_issues` |
| `agents.review_model` |
| `agents.search_model` |
| `agents.worker_model` |
| `kb.spec_warn_bytes` |
| `tokens.summary_heading` |
| `tokens.criteria_heading` |
| `tokens.evidence_heading` |
| `tokens.flow_heading` |
| `tokens.fixes_line` |
| `tokens.not_run` |
| `tokens.no_state_change` |
| `tokens.commit_exception` |
| `tokens.round_comment_prefix` |
| `tokens.evidence_cut` |
| `tokens.not_run_note` |
| `tokens.criteria_note` |
| `tokens.spec.context` |
| `tokens.spec.goal` |
| `tokens.spec.out_of_scope` |
| `tokens.spec.criteria` |
| `tokens.spec.design` |
| `tokens.spec.evidence` |
| `tokens.spec.placeholder` |
## Dependent calls

Calls that repositories pinning this one make into it, measured in those repositories. Paths are relative to the repository
root; `<…>` is a value the caller gives; `kit:<name>` is a kit baton `plugins/vibemaestro-sdlc/batons/<name>.sh`. The probe of
a row reads its values from the row: each `rc N` in order, and each name in backticks.

A baton of a dependent's own that the kit loads and checks as `kit:<name>` is listed too, as a row named `kit:<name>`: the suite
runs `baton.py check` on a pinned copy of it kept in a private folder of this repository, so a new `check` rule that fails it needs
its row edited and a change file whose line names the dependent that runs it. Where that folder is absent (the public
export), the suite says the probe was not run; where it is present and a copy differs from its recorded blob id, the suite is red.

| call | holds |
|---|---|
| `tests/fixtures/baton-owner.sh` | sourced by bash, it defines the functions `baton_isolate`, `guard_cmd` and `owner_asked` |
| `owner_asked <plugin> <dir> <state dir> <session id> <sign arguments>` | prints `ask`: the plugin's guard hook asked the owner, and recorded the dialog that `sign --by owner` with those arguments needs |
| `CLAUDE_CODE_SESSION_ID` | the session of a baton call: a `sign --by owner` after `owner_asked` for another session id is rc 3 |
| `XDG_STATE_HOME` | the baton calls keep their state, run logs included, under `$XDG_STATE_HOME/vibemaestro/baton` |
| `plugins/vibemaestro-sdlc/scripts/baton.py check kit:<name>` | rc 0 for a kit baton whose header holds `Purpose`, `Targets`, `Blast`, `Undo`, `Pre`, `Stops`, `Usage` and `Each` |
| `plugins/vibemaestro-sdlc/scripts/baton.py check <script path>` | rc 0 for a baton file whose header holds `Purpose`, `Targets`, `Blast`, `Undo`, `Pre`, `Stops` and `Expect` |
| `kit:release-promote` | on the pinned copy of a dependent's baton, `plugins/vibemaestro-sdlc/scripts/baton.py check kit:release-promote` is rc 0, and its header holds `Purpose`, `Targets`, `Blast`, `Undo`, `Pre`, `Stops`, `Usage` and `Each` |
| `kit:publish-public` | on the pinned copy of a dependent's baton, `plugins/vibemaestro-sdlc/scripts/baton.py check kit:publish-public` is rc 0, and its header holds `Purpose`, `Targets`, `Blast`, `Undo`, `Pre`, `Stops`, `Usage` and `Each` |
| `plugins/vibemaestro-sdlc/scripts/baton.py rehearse kit:<name> <args>` | rc 0, and a stdout line `seal <seal> …` |
| `plugins/vibemaestro-sdlc/scripts/baton.py mode auto` | rc 0; stdout is the one line `mode auto (was manual)` on a first call and `mode auto (was auto)` on the next, each call right after mode_asked for it; rc 3 without it, the mode unchanged |
| `plugins/vibemaestro-sdlc/scripts/baton.py sign --by coordinator-auto --seal <seal> kit:<name> <args>` | rc 3 for a baton whose Stops is not none |
| `plugins/vibemaestro-sdlc/scripts/baton.py sign --by owner --seal <seal> kit:<name> <args>` | rc 0 right after `owner_asked` for that very call; rc 3 without it |
| `plugins/vibemaestro-sdlc/scripts/baton.py run kit:<name> <args>` | rc 0, and a stdout line `run: ok — <n> write(s) — <run log>` whose run log holds `VERDICT postcheck ok` |
| `plugins/vibemaestro-sdlc/scripts/baton.py go --reuse <script path> <args>` | rc 0 in mode auto for a baton file with Stops none written an hour ago; rc 1 without `--reuse` |
| `BATON_PHASE BATON_PLAN BATON_WRITES BATON_PLUGIN_ROOT` | of these, the rehearse phase of a kit baton gets `BATON_PHASE`, `BATON_PLUGIN_ROOT` and `BATON_WRITES`; the run phase gets `BATON_PHASE`, `BATON_PLAN`, `BATON_PLUGIN_ROOT` and `BATON_WRITES` |
| `scripts/scan-internal-terms.sh --terms <file> --tree` | from inside a git repository: rc 1 when a term is in a tracked file, whose path the output names; rc 0 when none is, with the last line `control: found 1/1; hits: 0` |
| `scripts/export-public.sh <rev> <outdir>` | run as `bash -s -- <rev> <outdir>` with the script on stdin, inside the repository: rc 0; stdout is the tree id that `git write-tree` gives for `<outdir>`, which holds `LICENSE` and `NOTICE` at its root and in each `plugins/<name>/` |
| `plugins/vibemaestro-sdlc/gates/gate_common.py` | importable from `gates/`; defines `load_config_text`, `load_config`, `read_at`, `ConfigError` and `Infra` |
| `plugins/vibemaestro-sdlc/gates/backends` | a package importable from `gates/`; defines `load` |
| `plugins/vibemaestro-sdlc/scripts/sdlc_config.py` | importable from `scripts/`; defines `check`, `effective` and `glob_match` |
| `plugins/vibemaestro-sdlc/scripts/sdlc_config.py get <key> --root <dir>` | rc 0 and JSON on stdout for `merge.deny_globs` and `merge.image_bump` |
| `plugins/vibemaestro-sdlc/scripts/rule_packs.py` | importable from `scripts/`; defines `load` and `MANAGED_SETTINGS` |
| `plugins/vibemaestro-sdlc/scripts/vsdlc.py` | importable from `scripts/`; defines `CORE_NAME` |
| `plugins/vibemaestro-sdlc/scripts/kb.py init --lang en` | rc 0 in a git repository; it writes `.vibemaestro/sdlc.json`, whose `language` is `en` |
| `plugins/vibemaestro-sdlc/scripts/kb.py config check` | rc 0 on the config that `kb.py init` wrote |
| `plugins/vibemaestro-sdlc/scripts/kb.py new <kind> <slug> --date <date>` | rc 0 for each kind `intent`, `spec` and `plan`, writing `kb/intent/<date>-<slug>.md`, `kb/specs/<date>-<slug>.md` and `kb/plans/<date>-<slug>.md` |
| `plugins/vibemaestro-sdlc/scripts/kb.py check spec <date>-<slug>` | rc 0 on the spec that `kb.py new spec` wrote once its blanks are filled; rc 65 while they are not |
| `plugins/vibemaestro-sdlc/scripts/kb.py check current-state` | rc 0 on the `kb/current-state.md` that `kb.py init` wrote |
| `plugins/vibemaestro-sdlc/scripts/kb.py check current-state <file>` | called with an absolute path from another repository that holds only a config: rc 0 on the `kb/current-state.md` that `kb.py init` wrote; rc 65 on a file over the line cap |
| `plugins/vibemaestro-sdlc/scripts/kb.py check current-state --diff <base>...<head> --body-file <file> --config-ref <ref>` | rc 0 when no watched path changed; rc 65 when a watched path changed and the ledger did not; rc 65 when the config ref does not resolve |
| `plugins/vibemaestro-sdlc/gates/commit_discipline.py <base> <head> --body-file <file> --config-ref <ref>` | rc 0 on one plain commit; rc 1 when one file is touched in more commits than `commits.max_touches`; rc 2 when the config ref does not read |
| `plugins/vibemaestro-sdlc/gates/commit_discipline.py <base> <head> --body-file <file> --cwd <dir>` | rc 0 on one plain commit, called from another directory |
| `plugins/vibemaestro-sdlc/gates/pr_sensitive.py --pr <n> --repo <owner/name> --config-ref <ref>` | rc 2 when gh cannot read the pull request |
| `plugins/vibemaestro-sdlc/gates/pr_sensitive.py --payload <file> --cwd <dir>` | rc 0 for a payload whose title and body hold no sensitive value; rc 1 when the body holds an e-mail address |
| `plugins/vibemaestro-sdlc/gates/pr_title.py --pr <n> --repo <owner/name> --config-ref <ref>` | rc 2 when gh cannot read the pull request |
| `plugins/vibemaestro-sdlc/gates/pr_title.py --cwd <dir>` | the event JSON on stdin: rc 0 for a title that `pr.title.pattern` allows; rc 1 for one it does not |
| `plugins/vibemaestro-sdlc/gates/pr_body.py --pr <n> --repo <owner/name> --config-ref <ref>` | rc 2 when gh cannot read the pull request |
| `plugins/vibemaestro-sdlc/scripts/intent-branch.sh create-intent --slug <slug>` | rc 0 in a repository holding `kb/intent/<slug>.md`, the tracking issue being best effort |
| `plugins/vibemaestro-sdlc/scripts/intent-branch.sh create-intent --slug <slug> --base <ref>` | rc 0 in a repository holding `kb/intent/<slug>.md`; the branch is cut from that ref, not from the checked-out commit |
| `plugins/vibemaestro-sdlc/scripts/intent-branch.sh worker-branch --intent <slug> --name <branch> --no-checkout` | rc 0 after `create-intent` |
| `plugins/vibemaestro-sdlc/scripts/intent-branch.sh integrate --intent <slug> --to origin` | rc 7 from the main tree: the arguments are taken, and it runs only from a linked worktree |
| `plugins/vibemaestro-sdlc/scripts/open-pr.sh --title <title> --summary <file> --evidence <file> --draft` | rc 5 from the main tree: the arguments are taken, and it runs only from a linked worktree |
| `plugins/vibemaestro-sdlc/scripts/open-pr.sh --title <title> --summary <file> --evidence <file> --dry-run --fixes <n>` | rc 0 in a linked worktree; stdout ends with the payload, a JSON object whose `body` string names `#<n>` |
| `plugins/vibemaestro-sdlc/scripts/open_pr.py --title <title> --summary-file <file> --evidence-file <file> --dry-run --payload-out <file>` | rc 0 in a linked worktree; the payload file is a JSON object with a `body` string |
| `plugins/vibemaestro-sdlc/rules/batonrun.instructions.md` | a regular file (a dependent's rule cites the rule `batonrun`) |
| `plugins/vibemaestro-sdlc/hooks/hooks.json` | a regular file |
| `plugins/vibemaestro-sdlc/scripts/session-start.py` | a regular file |
| `plugins/vibemaestro-sdlc/skills/intake/SKILL.md` | a regular file |
<!-- surface:end -->
