---
name: release
description: "Use when: in a repo that publishes plugins from an export (it has .changes/), a plan's release row is due (a public release of the repository: a feature group closes and its version is shipped), or a defect in the public plugin needs a hotfix before the next release — cut the release or hotfix PR with scripts/release.py (plan, cut, check), open it through ship, and after it merges move the branch release to it, then publish it your own way. Not for an ordinary PR: that one adds a .changes/ file and writes no version."
---

# release — cut a release or a hotfix of a plugin marketplace repo

A version exists only as a public release:
the source repository carries none in a manifest or the marketplace (the export writes it), and a plugin's version is the first `## X.Y.Z` heading of
its `CHANGELOG.md` (the first public release is 0.1.0). Such a heading appears in two kinds of PR only: a **release PR**, run by a
feature group's release row, ships every pending change file (`.changes/*.md`) from main; a **hotfix PR** into the branch
`release` ships one patch that users of the public plugin need before the next release. `scripts/release.py` writes both, and
its `check` (run by CI) is red for anything else, so do not write a version, a `CHANGELOG.md` heading or a `Frozen at` by hand,
and never write a version into a `plugin.json`: the public export does that.

Condition: the repo has `.changes/README.md` on main and a branch `release` on its remote (the owner creates `release` once;
until then a release can be cut and merged, but `release` cannot move).

## A release (a plan's release row)

1. **A worktree of its own from the tip of main**, on a branch for the row (`vibemaestro-sdlc:intake` gives the intent branch):
   the release ships what main holds now, every group's pending change files, finished or not (main stays shippable).
2. **See what it will do**, read-only:

   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/release.py" plan
   ```

   One line per plugin, `old -> new (level)`: each plugin named by a change file goes up one step at the highest level naming it
   (a `major` on a 0.x plugin is a minor), or `unreleased -> 0.1.0 (first release)` when it was never released; and each
   `CONTRACT.md` whose surface moved since `release`, or whose plugin is released for the first time, gets `Frozen at` = its new
   version. A version that is not what the plan row expects means a change file says another level: fix that change file in an
   ordinary PR first, never the numbers.
3. **Cut, check, commit** (cut writes the working tree only: the `CHANGELOG.md` sections, the change files removed, `Frozen at`;
   no manifest and no kb page):

   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/release.py" cut
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/release.py" check      # kind: release, rc 0
   git add -A -- plugins .changes && git commit -m "chore(release): <plugin> <version>, …"
   ```

   cut refuses (rc 1, the reason printed) a dirty tree, a detached HEAD, the branch `main` or `release`, a HEAD that lacks main's
   tip, a `release` that holds a hotfix main lacks (merge its back-merge PR first), nothing pending, or a surface change named
   below `minor`. When main moves before the PR merges, merge main and cut again: CI is red while a pending change file is not shipped.
4. **Open the PR into main** with `vibemaestro-sdlc:ship`; the PR body names the versions. It merges through `kit:merge-pr` like any PR.

## A hotfix

1. A worktree on a branch from `origin/release` (not from main: unreleased features must not ride a hotfix).
2. The fix, its test, and one change file at `level: patch` naming the plugin; commit.
3. `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/release.py" cut --hotfix`, then `release.py check --base origin/release` (kind:
   hotfix, rc 0), commit. cut --hotfix refuses a level above patch, a `CONTRACT.md` surface change (that waits for a release), a
   plugin never released, and a `release` whose manifests still carry a version (it predates the version reset: release from main).
4. Open the PR with **base `release`**; `kit:merge-pr --base release` squashes it onto `release`.

## After it merges: move `release`, then publish

With the merged commit (the squash on main for a release, the new `release` tip for a hotfix), move `release` through one baton
script (`vibemaestro-sdlc:batonrun`: a GitHub write, rehearsed, signed by the owner, since moving `release` changes what the
next public release is exported from, then post-checked):

- **A release:** fast-forward `release` to the release commit; never a force.
- **A hotfix:** `release` already holds it; push `backmerge/<sha12>` at the `release` tip and open its PR into main.

Make no tag in the source repository: a `<plugin>--v<version>` tag there would pin a dependency range to the tagged commit, so
the version tags live in the published repository only.

The back-merge PR merges through `kit:merge-pr` like any PR: the guard sees the head ref `backmerge/*` and a head on `release`,
and merges with a merge commit instead of a squash, so `release` stays an ancestor of main (the next release's check needs it).
Never squash it, never update its branch from main.

## Then publish it your own way

Nothing here exports or publishes. What the public form of a release carries: each plugin's released version written into its
exported `plugin.json`, the range `>=0.1.0` on each dependency on a released sibling, and tags `<plugin>--v<version>`, the form
Claude Code resolves a dependency range against.
