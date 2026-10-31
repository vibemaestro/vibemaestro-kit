---
name: install-gates
description: "Use when: a repo wants the process gates behind the plugin's rules - commit discipline, sensitive-info scan of PR text, PR title and branch, dead branches - as GitHub workflows. Asks which gates and which runner, then runs scripts/install_gates.py, which writes the files and never overwrites."
---

# install-gates - put the SDLC gates into a repo

The rules (`commit-unit`, `pr-no-leaks`, `git-process`) only remind. These five gates count, so a PR that ignores a rule goes red:

| Gate | What it checks | Config keys it reads (`.vibemaestro/sdlc.json`) |
|---|---|---|
| `commit-discipline` | commits per PR, touches per file, side-branch merges, wip/fixup marks, one commit per review round; the exemption is one body line | `commits.*`, `tokens.commit_exception` |
| `pr-sensitive` | secrets, e-mail, phone, public IP, account ids in the PR body, comments and commit messages; a hash-only allowlist | `sensitive.scan`, `sensitive.allowlist` |
| `pr-title` | title pattern and length, branch pattern, no intent-file title on a ready PR that carries code | `pr.title.*`, `branch.pattern` |
| `pr-body` | the PR body over its cap: characters in all, summary lines, evidence lines (on by default; the live body is read, so `gh pr edit` is checked) | `pr.body.*`, `tokens.summary_heading`, `tokens.evidence_heading` |
| `dead-branches` | remote branches already inside the main line (reports; deletes nothing) | `dead_branches.*`, `branch.protected` |

Skills ask, scripts do: this skill collects the answers; `scripts/install_gates.py` writes the files with no model in between.

## Ask (at most three questions)

1. **Which gates?** Default: all five. (`--only commit-discipline,pr-title` for a subset.)
2. **Which runner?** The GitHub variable that names the runner and the fallback label, for `runs-on: ${{ vars.<variable> || '<label>' }}`. Default `CI_RUNNER` and `ubuntu-latest`; a repo with a self-hosted runner gives its own pair. An organisation that runs only self-hosted runners (no GitHub-hosted minutes) asks for no fallback: `ci.runner_default` (or `--runner-default`) is `self-hosted only`, the workflows then carry no label and a run with neither variable set fails at its start naming the variable, instead of waiting for a hosted machine. Do not offer it to a public user by default. The installed gates also read the optional repo variable `CI_GATE_RUNNER` first (a light runner for gate jobs); unset, they use that pair. If the repo's `.vibemaestro/sdlc.json` already has `ci.runner_var` / `ci.runner_default`, take those and do not ask.
3. **Do the thresholds need changing?** The defaults are 15 commits per PR, 4 touches per file, 0 merged branches left on the remote. Anything else is a value in `.vibemaestro/sdlc.json`, not a code change (`kb.py config check` validates it).

## Do

Work in a worktree inside the repo (rule `git-process`), then:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/install_gates.py" --dry-run          # what would be written
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/install_gates.py" [--only <gates>] [--runner-var <VAR>] [--runner-default <label>]
```

- Workflows go to `.github/workflows/`, the gate scripts and the config loader to `.vibemaestro/gates/`, and an allowlist containing only its header to the path of `sensitive.allowlist`.
- **Nothing is overwritten.** Each file is reported `wrote`, `kept` (identical to what would be written) or `kept (differs)`; a second run is a no-op. Under `self-hosted only`, a kept workflow whose `runs-on` still has a fallback label gets a `WARNING` (the installer never rewrites it: delete the file and install again, with the person's go). If a file is `kept (differs)`, show the person the difference and let them decide; do not delete it for them.
- The script prints the config keys the gates read. It does not create `.vibemaestro/sdlc.json`; with none, every key has its default.
- Commit the files and open the PR with `vibemaestro-sdlc:ship`. Say in the PR body that the workflows change what runs with the repo's token, so `.github/` is reviewed like code.

## What to tell the person

- **A gate judges a PR by the scripts and the config of its BASE branch.** The templates check out the base and only fetch the PR's commits as data, so a PR cannot relax its own gate. The PR that installs the gates has no scripts on its base yet: each workflow says so in a warning and passes, once. From the next PR the gates apply.
- **The vendored gates know only the plugin version that installed them.** Everything in `.vibemaestro/gates/` (the gate scripts, the config loader `sdlc_config.py`, the message table `messages.py` the gates print from) is a copy, and a re-run keeps it (`kept (differs)`). With `language: en` the installer writes English-only copies (no Vietnamese letter in any file of the plugin's own; a token the repo sets itself, such as `tokens.commit_exception`, lands in a workflow as written); a kept older copy that still holds Vietnamese text gets a WARNING, and the way to a clean copy is the same: delete the file and run again. Before the repo's `.vibemaestro/sdlc.json` takes a key a newer plugin added (for example `agents.*`, or `language` when the gates should print in it), delete `.vibemaestro/gates/` and re-run this skill in the same PR or an earlier one: the re-run writes every file again, all from one plugin version. The gates read the config of the base branch, so a PR that adds the key without the refresh passes its own gates, then turns every later PR (and the scheduled dead-branches run) red on `unknown key`.
- **What no template can stop:** the workflow file itself comes from the PR, so a PR can still edit it. Reviewing changes under `.github/` is the guard.
- **Sessions that post through a GitHub App (`pr-evidence`):** their round comments have the association `NONE`, so the gate ignores them and the PR stays red. To count them, set two things to the App's slug (its bot is `<slug>[bot]`): `evidence.trusted_app` in `.vibemaestro/sdlc.json`, merged to the base (the gate reads the base), and the repository variable `PR_EVIDENCE_APP` (`gh variable set PR_EVIDENCE_APP --body <slug>`), which lets that App's comment re-run a red check. A repo that installed `pr-evidence` before the gate knew the key deletes `.vibemaestro/gates/` and `.github/workflows/pr-evidence.yml` and runs this skill again (the script never overwrites), so that the gate and the workflow's re-run fence know the App. With only the key, the evidence counts on the next push, but a comment does not re-run the check. With only the variable, the App's comment re-runs a check that still ignores it. Name only an App that the repository's owner controls and that never posts text a PR author wrote. `github-actions` is refused, because every workflow of the repo posts as it, including one that echoes text a PR controls.
- **Allowlist:** a false positive of `pr-sensitive` is exempted by the sha256 of exactly that value (the scanner prints it on a local run, never in CI), never by loosening a rule. The value itself is never written to the file. A new line takes effect for PRs after it has merged.
- **The runner variable is checked, read-only.** After installing, the script lists the repo's Actions variables and the organization's with `gh api -X GET` and prints one line: `set`, a `WARNING` that names the fallback label (or, under `self-hosted only`, says every gate run fails at its start) and `gh variable set <VAR> --body <label>` (unset, or set to an empty value, which falls back too: on a hosted runner whose minutes are locked the gates never start and read as failed; under `self-hosted only` there is no fallback and each gate run fails at its start instead), or `check skipped` when `gh` is missing, not logged in, or cannot read one of the two lists (the organization list can need more permission than the repo's, so a 403 or 404 on either list is a skip, never a warning). The exit code never changes. Pass the warning on to the person; setting the variable is theirs (or the org admin's).
- **Runner needs:** `python3` 3.8 or newer, `git`, and `gh` (present on GitHub-hosted runners). A red run is a signal on the PR; making it a required check is the repo's ruleset.
- Third-party actions: the templates use only `actions/checkout`, pinned by a full commit SHA. Keep it that way.
