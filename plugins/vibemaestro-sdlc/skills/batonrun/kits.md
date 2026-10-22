# batonrun reference: kit batons

Read this before `go kit:merge-pr`, `go kit:gh-write` or a kit of another plugin, when one refused, or when a run is to be
kept or changed. Also printed by `<launcher> help kits`.

A kit baton is a baton script the plugin ships, named `kit:<name>` instead of a path; it is reviewed plugin code, so you do not
write it, you run it like any other (`go`, or the separate commands). Only a kit baton may run one of the plugin's gates, and its signature
binds the plugin version it was signed with. `kit:merge-pr` is the guarded merge (`gates/merge_guard.py --help` lists its
arguments):

    <launcher> go kit:merge-pr --repo <owner/name> --pr <n> --head <full sha> --brief <file> [guard options]

Rehearse is the guard's dry run: every condition with its verdict, and the plan line (`merge … head <sha> …`). The run hands
the guard the signed plan (`BATON_PLAN`), so a world that moved since signing is refused before anything merges. A PR the guard
refuses fails at rehearse and cannot be signed: fix the PR, never the guard's arguments to fit it. The header says `Stops: none`,
so in mode `auto` the session signs it. A merge is not reversible: when the run fails after
GitHub merged, `run` exits 5 and the way back is a revert PR, which the owner is told about at once. Accepted red steps
(`--accept '<check>:<step prefix>'`), base files that may stay behind (`--behind-ok <globs>`), an image that must exist
(`--require-image <tag>`) and the image-bump lane (`--image-bump`) are arguments, so the signature binds them.
`--behind-ok-clean <docs globs>` (each ends in `.md`, starts with a literal folder) also accepts a docs file main and the PR both changed, when git's 3-way merge and GitHub's test merge agree it is clean and a merged current-state still passes its check.

**A PR behind main: merge main only when the guard refuses.** Run `kit:merge-pr` with `--behind auto` (never beside
`--behind-ok` or `--behind-ok-clean`): the guard decides by itself. It accepts a behind PR when GitHub's test merge of the
base tip and the head is fresh and mergeable, every file main and the PR both changed is a docs file that merges clean, and
the suites main's files wake do not meet the suites CI ran for the PR (the repo's `merge.planner`, run from the base; with no
planner, main's files must all be docs). On `FAIL  behind` main is merged into the PR's branch and CI runs again; on
`??  behind` (a test merge still stale) rehearse again a minute later. Do not merge main into a queued PR before the guard has refused it: that
costs a full CI cycle for nothing.

`kit:gh-write` is for the small GitHub writes: open an issue, comment, edit your comment, an issue's title or body, a PR body,
reopen or close an issue, close a PR, mark a draft PR ready, open a PR from a pushed branch, propose one file as a PR. Do not
hand-write a baton for these. Write one JSON spec (`gates/gh_write.py --help` gives the format)
with the Write tool to a fresh path and, in the same response, run:

    <launcher> go kit:gh-write --spec <file>

To post one comment, put the body inline:

    {"gh-write": 1, "ops": [{"op": "issue-comment", "repo": "<owner/name>", "issue": 59,
     "body": "…\n<!-- my-marker -->", "marker": "<!-- my-marker -->"}]}

How it behaves:

- **Rehearse.** It reads every target and prints one plan line per op. Each line carries the spec's sha256, so the signature
  binds the spec and every body file pinned in it (`body_file` plus `sha256`).
- **Refusals at rehearse.** Each is named:
  - a repository that is not private, or is internal (`refuse-public`);
  - a deletion (`refuse-delete`);
  - a repository creation (`refuse-repo-create`);
  - an unknown kind or key;
  - a marker already present, so a second run of the same spec is refused;
  - a fence left open.
  - a closed issue or a closed or merged pull request, for a comment, an edit or a close; the one exception is an `issue-comment`
    with `"closed_ok": true`, which passes there and says so in its plan line.
- **Run.** A later op may target an issue created earlier in the spec (`"issue": "@<id>"`) and cite it in its body
  (`{{issue:<id>}}`). Its number comes from the create's own output, never from a list.
- **Post-check.** It reads every write back by number and compares it byte for byte. The engine handles the trailing
  newline once, so do not compare bodies yourself.
- **Undo.** It puts saved bodies back, closes created issues as not planned (and removes their marker), and retracts new
  comments by editing them. It never deletes. It leaves alone two things, and then the run ends with exit 5:
  - what someone changed after the run;
  - a write whose outcome is unknown and that a list does not show yet.
- **Recover.** A run that was interrupted, or whose undo failed, stays open, and its spec cannot be rehearsed again. Undo it
  with the same command plus `--recover` after the spec path (`go --reuse`, since the spec is older than 120 s); each undo
  step is one plan line. A step that must leave
  a state alone closes the run anyway and ends with rc 5: tell the owner what it left. When what it left is a write whose
  outcome is unknown, the spec stays refused until the owner has checked GitHub and moved that journal aside.

The pull-request ops pin what they act on:

- `pr-ready` (`pr`, `head`): the PR is open, a draft, and at that head; undo turns it back into a draft while it is still ready
  at that head.
- `pr-create` (`base`, `branch`, `head`, `title`, `draft`, a body): the branch is already pushed to the same repository and is at
  `head`, and no open PR from it into `base` exists. `draft` is required, so the plan line says `draft` or `ready`. Undo closes
  the PR while it is open, not merged and still at `head`.
- `file-pr` (`base`, `branch`, `path`, `content_file` with `content_sha256`, `title`, `draft`, a body): one file proposed
  without a clone, added, or replacing the regular file at that path on the base (it keeps that file's mode). The branch must
  not exist. The plan line names the base tip, what the path holds there (`replaces blob <sha> mode <mode>`, or `replaces
  none`) and the commit's author (the viewer's GitHub noreply address), so a base or file that moved after signing is
  refused. A directory, a link, a submodule, a path under a file, content equal to the file, and a path under
  `.github/workflows/` or `.github/actions/` (this op writes no workflow definition) are refused. The run makes one commit on
  that tip, then the branch, then the PR. Undo closes the PR. The branch stays, because this baton never deletes, so the undo
  names the branch and the run ends with exit 5; once the owner has deleted the branch, `--recover` closes the run.

Deletions, public repositories and anything outside these kinds stay hand-written batons, signed by the owner.

`kit:coordinator-bootstrap` sets up BatonRun on a machine (the launcher, the permission block, attribution off where a key is
absent) in one run the owner signs (`Stops: security-boundary`); it takes no argument. Follow the skill `coordinator-bootstrap`:
on a new machine there is no launcher yet, so it runs through the plugin's `baton.py`, and the owner types the signature.

## A kit from a dependent plugin

`kit:<name>` also runs a kit that another plugin ships in its `batons/`: a plugin of the same marketplace built on
vibemaestro-sdlc. How it is found:

1. sdlc's own `batons/<name>.sh` comes first.
2. Otherwise baton looks in the `batons/<name>.sh` of every other plugin in Claude Code's plugin registry. It reads the registry
   that sits beside the sdlc copy that runs (`<claude dir>/plugins/installed_plugins.json`, where the copy is
   `plugins/cache/<marketplace>/vibemaestro-sdlc/<version>`). It never reads `CLAUDE_CONFIG_DIR` or `HOME`, which a session can
   set. A `baton.py` run from a checkout finds only sdlc's kits.

Such a kit runs only when all of these hold:

- the plugin's registry id is `<plugin>@<marketplace>`, with sdlc's own marketplace;
- its newest install entry has a real path of exactly `plugins/cache/<marketplace>/<plugin>/<version>`, the version named as the
  launcher accepts one;
- its `.claude-plugin/plugin.json`, reached through no symlink, lists `vibemaestro-sdlc` (or `vibemaestro-sdlc@<marketplace>`)
  in `dependencies`;
- the kit file lies in that plugin's own `batons/`.

It then gets every check an sdlc kit gets: `Each:`, a gate only in the trusted form, and rehearse before sign and run. Two things
point at that plugin rather than sdlc: `BATON_PLUGIN_ROOT` is its root, and the signature binds its `batons/` directory and the
kit's bytes. So an edit after signing, or another version of the plugin, has no signature. The rehearse header ends with
`from <plugin>@<marketplace>`, and the owner's decision card says `(a kit of <plugin>@<marketplace>)`.

Refused before anything runs (rc 64), with the reason:

- a name that sdlc and a dependent plugin both ship, or that two dependent plugins ship: kit names must be unique;
- a plugin from another marketplace;
- a plugin that does not declare the dependency;
- a plugin installed outside the cache shape;
- a kit file or `batons/` that leads outside the plugin's own `batons/`, or a manifest reached through a symlink.

A plugin that may not run a kit never shadows an sdlc kit of the same name. A name nobody ships is rc 66; the message also says
when the registry could not be used.

## Keeping a run, and changing one

The rule of two: a series written a second time is kept as a **library run**, one file per run in `<library>`, that is
`$XDG_DATA_HOME/vibemaestro/batons/`, else `~/.local/share/vibemaestro/batons/` (Write it there: the state directory is closed
to the write tools). Run it with `go --reuse <library>/<name>.sh <args>`, only after a plain `go` on it printed its sha256 and
Purpose and you mean those bytes. It is checked, rehearsed and signed like any session baton, may not run a gate, and holds no
secret. Find one: `grep '^# Purpose:' <library>/*.sh`. Needed across sessions or repos: open a kit issue (`kit:gh-write`) with
the script, its log lines and where else it is needed.

A run stands for a workflow: a changed workflow updates its run, never a forked copy. The test: is it still the same workflow
(purpose, targets, risk)?
- a step needed every time: add it to the run;
- a step needed sometimes: an argument of the run (the signature binds arguments, so the plan shows it);
- other purpose or targets, or a new Stops word: a new run with its own name;
- a step met for the first time: a session baton this once; the second time, fold it into the run.

A change within the same workflow that widens what the run touches updates its header. A new Stops word makes a new run (above),
and the owner signs that run from then on. A kit run changes only through a kit PR; meanwhile the extra step runs as a separate run right after it. The signature binds the
script's sha256 and the log records it, so which version ran stays known.
