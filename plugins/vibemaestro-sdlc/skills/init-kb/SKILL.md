---
name: init-kb
description: "Use when: a repo app has no kb/ or lacks one of its directories, or a repo adopts the plugin and needs its per-repo config — scaffolds kb/ (intent/specs/plans/decisions, a self-contained README, current-state.md in the current-state-only shape) and per-repo config (.vibemaestro/sdlc.json, a rules directory with an example rule); safe to re-run, overwrites nothing; --adopt for a repo that already has process files."
---

# init-kb — scaffold `kb/` and per-repo config

`kb/` lives in the repo that a change describes. An app repo without `kb/` has nowhere to write an intent, plan or spec, and
a repo without `.vibemaestro/sdlc.json` runs the plugin on its defaults only. This skill is the one door for both: it scaffolds `kb/`
and writes the per-repo config.

The scaffold is **self-contained**: `kb/README.md` carries the directory table, the file-name convention, the four-section spec shape
and the shape of `current-state.md`; it points to no other repo. Read the repo's own `kb/README.md` for the shapes.

## Questions (seven, five more for the guarded merge, then the script does the rest)

Skill asks, script writes (kit principle). Ask the person these and only these, one at a time, skipping any that the repo
already answers; a question the person leaves open takes the default shown. Write the answers into a JSON file (a scratch file
outside the repo, shape of `.vibemaestro/sdlc.json`, only the keys answered) and pass it with `--answers`:

| # | Ask | Key | Default |
|---|---|---|---|
| 1 | current-state template: `ledger` (short, one-line facts, no history) or `map` (tables, a larger size cap) | `current_state.template` | `ledger` |
| 2 | directory of this repo's own rule files | `rules.dirs` (a list with one path) | `.vibemaestro/rules` |
| 3 | PR title pattern (a regular expression), or none | `pr.title.pattern` | none |
| 4 | verify that a PR carries its closing link (`Closes #N`) after opening it? | `pr.closing.verify` | yes |
| 5 | file of approved literals for the sensitive-information gate | `sensitive.allowlist` | `.pr-sensitive-allow` |
| 6 | name of the repo variable that picks the CI runner (`kb.py init` says once that `install-gates` later checks it is set, read-only) | `ci.runner_var` | `CI_RUNNER` |
| 7 | language of the repo's `kb/` documents and PR bodies: `en` or `vi`; recommend `en`, or `vi` when the person writes to you in Vietnamese | `language`, passed as `--lang <en\|vi>` | `en` (a new config always records it) |

Then ask whether pull requests of this repo will be merged through the guarded merge (`gates/merge_guard.py`, run as the kit
baton `kit:merge-pr`). Only on a yes, ask these too; the guard reads them from the PR's base branch, so a PR cannot widen them:

| # | Ask | Key | Default |
|---|---|---|---|
| 8 | changed paths the guarded merge refuses in its normal lane (globs; `[]` is a valid answer, unset makes the guard refuse to run) | `merge.deny_globs` | `[".github/workflows/**", ".vibemaestro/*", ".vibemaestro/gates/**", ".vibemaestro/rules/**", "**/*secret*"]` |
| 9 | checks that must be green on every merge (check names, or `<workflow>/<name>`; a skipped run counts as missing, a commit status never counts) | `merge.required_checks` | none: at least one green check |
| 10 | may the guard pass `--admin` to GitHub (bypass branch rules as an admin)? | `merge.admin_bypass` | no |
| 11 | an image-bump lane: files holding the image tag, the image build tree, the revision file and pattern, the registry (`ghcr` or `external:<path>`, host, image) | `merge.image_bump` | off |
| 12 | which CI reports the checks: `github-actions` (also any CI that reports to GitHub) or `external:<path>` | `ci.backend` | `github-actions` |

`kb.py init` writes `merge.deny_globs` into a new config even when these questions are skipped: the answer, else the default
of question 8 (the report names it), so the guarded merge never refuses a repo's PRs for a missing list. A repo's first PR, the one
adding the config, merges through the guard's bootstrap: the guard reads the added config at that PR's head for that one merge.

Keep `.vibemaestro/*` in the deny globs: it is what stops a PR from turning `merge.admin_bypass` on, or emptying the deny list,
for itself. The default leaves `.vibemaestro/batons/` out, so a project baton merges through the guard like other code; deny
`.vibemaestro/**` instead to make every project baton an owner merge.

A person who already has a full config may hand over a file that spells out every key; it is written as it is.
Every other value (limits, tokens, thresholds, watched paths, UI paths) is written by hand into `.vibemaestro/sdlc.json` afterwards.

## Do

All changes are made in a worktree of their own (rule `git-process`), **inside** the repo:

```bash
git fetch origin
git worktree add -b chore/kb-init .claude/worktrees/kb-init origin/<default branch>
cd .claude/worktrees/kb-init
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/kb.py" init --answers <answers.json>      # no answers: plain `init`
git add kb .vibemaestro <every other path the report lists as created> && git commit -m "docs(kb): scaffold kb/ and per-repo config"
git push -u origin chore/kb-init
```

- `--lang en` writes `kb/README.md` and the current-state skeleton in English and records `"language": "en"` in a new config;
  that key also switches the spec sections `kb.py check spec` requires (`## Context`, `## Goal`, `## Out of scope`,
  `## Acceptance criteria`, optional `## Design`), the templates of `kb.py new` and the fixed lines of the PR body to English.
  The scaffold always speaks the language of the config in force: with an existing config, `--lang` must match its `language`
  (absent: `vi`, the default of a config made before `kb.py init` recorded it), else rc 64 and nothing is written; set the key in the config first. A repo with installed gates refreshes
  `.vibemaestro/gates/` before it sets `language` (skill `install-gates`: the vendored loader knows only the keys of the
  version that installed it, and the gates print in the language of the message table vendored with them). One heading can still be renamed under `tokens` (`tokens.spec.*` for specs) and wins
  over the language.
- `<default branch>`: run `git remote set-head origin --auto`, then `git symbolic-ref --short refs/remotes/origin/HEAD` prints `origin/main` (or `origin/master`...).
  Only a clone sets `origin/HEAD` by itself: in a repo made with `git init` + `git remote add origin …` + `git push -u origin main` the second
  command alone fails with rc 128 (`ref refs/remotes/origin/HEAD is not a symbolic ref`). `set-head --auto` asks the remote and sets it; in a clone it only refreshes it.
- If `.claude/worktrees/` is not ignored (`git check-ignore -q .claude/worktrees`), add it to the repo's `.git/info/exclude`: a local
  file, nothing that is committed changes.
- `kb.py init` creates `kb/intent/ specs/ plans/ decisions/` (a `.gitkeep` in each so git keeps it), `kb/README.md` and
  `kb/current-state.md`; then `.vibemaestro/sdlc.json` (`schema` and the chosen keys only, not a copy of the defaults) and, in an
  app repo, `<rules dir>/README.md` and `example.instructions.md` (`status: example`, never delivered). Each file is written
  **only if absent**; the report says `created` or `kept` per file and ends with `kb.py config check` on the config in force.
  **Safe to re-run**: what exists keeps every byte. An existing config is never rewritten: the command prints `would add <key>` and
  `differs <key>` for the values the answers would add or change, and exits 0.
- Answers are validated before anything is written: a bad regex, an unknown key, a `schema` above the plugin's, or a rules directory
  or ledger path that cannot be written (a parent that is a file, a link out of the repo) is rc 65 and nothing is written; an answers
  file that cannot be read is rc 66. A rules directory or ledger path that the answers moved is outside `kb .vibemaestro`: add it to the commit. `--dry-run` validates and prints the report without writing.
- Plain `init` is not refused anywhere: in a repo that already has process files it writes the app config, so use `--adopt`
  there (a config, once written, is never rewritten). Outside a git repo, rc 2.
- Per machine, not per repo: a new machine sets up the BatonRun permission rules once, by the section "Setup on a new machine"
  of the skill `vibemaestro-sdlc:batonrun` (`baton.py permissions --print`, applied by the owner through Claude Code's
  settings). The same block turns Claude Code's attribution off (`"attribution": {"commit": "", "pr": "", "sessionUrl": false}`),
  and `permissions --check` warns when it is on. This skill and the plugin never edit settings.

## A repo that already has process files: `--adopt`

A repo with a rules directory, a ledger, an allowlist or project hooks of its own uses `--adopt`. It writes **no rule file and edits no
existing file**; it writes `.vibemaestro/sdlc.json` (and the missing parts of `kb/`) and prints what a person does by hand (remove the old
hook entries from `.claude/settings.json`, delete the rules that moved into the plugin) and what the plugin does after that.

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/kb.py" init --adopt --detect --dry-run        # see what is detected, write nothing
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/kb.py" init --adopt --detect --answers <answers.json>
```

`--detect` only **proposes**: the directories with `*.instructions.md` files that carry `applyTo`, the path and the table width of the
ledger, the allowlist file if it exists, and the runner label from the `runs-on` of the workflows. A repo that keeps rule hooks of its
own in `.claude/settings.json` gets the plugin's reminders as well: tell the person to remove them or set `hooks` to `off`. Show the person what it found, ask the six questions above with those values as the defaults, and write the
answers file; what is written is the answers file, never the proposal. Title and branch patterns, watched paths, limits and `tokens`
are not detectable: the person writes them into the answers file by hand.

Then open the PR with the skill `vibemaestro-sdlc:ship` (this PR needs no `--closes`).

**Right after this, `intake` works even if the kb PR is not merged.** The branch is pushed so that `intake` can cut from it:
`kb.py base` (see the `intake` skill) prints `origin/<default branch>` once `kb/` is merged there, and
`origin/chore/kb-init` before that. In the second case the intent PR carries this scaffold commit; say so in its body.

## Writing `kb/current-state.md` — the shape of the present state

The first job after the scaffold: fill `kb/current-state.md` so that it matches the repo's real present state. This file is the
**only** file in `kb/` that must always be right, and it is what a session reads **first** — so every surplus line is context loaded for nothing.

- **Only the present state:** each line is a statement that is true right now ("X runs in Y", "Z is handled by W").
- **Overwrite, do not append:** when the system changes, correct the old line; do not add a line "changed from A to B".
- **No history** (measurement dates, PR/issue numbers, "previously…", a log) and **no how-to or experiment numbers**: history is in
  `git log` and the PRs; detail, reasons and measurements live in `kb/specs/` and `kb/decisions/` — current-state only points to them by
  path.
- **There is a size cap** (≤ 120 lines, ≤ 12,000 bytes, ≤ 200 characters per line). Going over the cap means detail is in the wrong place:
  push it to a spec/decision, do not raise the cap. From 85% of the cap the machine prints an extra `WARNING` line (rc stays 0): overwrite, do not append.

Check by machine: `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/kb.py" check current-state` (rc 65, and it names each violating line).
