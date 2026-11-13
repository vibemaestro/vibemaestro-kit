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
its `check` (run by CI) is red for anything else, so do not write a version, a `CHANGELOG.md` heading, a `Released together:`
line or a `Frozen at` by hand (check is red when a PR changes the `Released together:` line of a section already on the base),
and never write a version into a `plugin.json`: the public export does that.

Condition: the repo has `.changes/README.md` on main and a branch `release` on its remote (the owner creates `release` once;
until then a release can be cut and merged, but `release` cannot move).

## A release (a plan's release row)

1. **A worktree of its own from the tip of main**, on a branch for the row (`vibemaestro-sdlc:intake` gives the intent branch):
   the release ships what main holds now, every group's pending change files, finished or not (main stays shippable).
2. **See what it will do**, read-only (`REPO` is the public repository, its `owner/name` on GitHub or a git URL: its tags
   `<plugin>--v<version>` say what is published):

   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/release.py" plan --public REPO
   ```

   One line per plugin, `old -> new (level)`: each plugin named by a change file goes up one step at the highest level naming it
   (a `major` on a 0.x plugin is a minor), or `unreleased -> 0.1.0 (first release)` when it was never released; and each
   `CONTRACT.md` whose surface moved since `release`, or whose plugin is released for the first time, gets `Frozen at` = its new
   version. When the marketplace has two or more plugins released after the cut, it also prints `released together: <name>
   <version>, …` (every one of them, raised or not) and, per raised plugin that depends on such a sibling, `needs <sibling>
   >=<version> (was >=<version>)`: the floor the export will write on that dependency. A version that is not what the plan row expects means a change file says another level: fix that change file in an
   ordinary PR first, never the numbers.
   A release's notes are the final state since each plugin's previous **public** version: a section cut and not published
   joins the new one (`joins its unpublished ## X.Y.Z section`), and a line a change file's `supersedes:` or `cancels:` names,
   or a line already published, is taken out (`takes out (<why>): <line>`). Read the result as a user of the previous public
   version would: a line that a later line contradicts and no change file marked (an add then a removal, a behaviour replaced)
   is fixed in an ordinary PR first, with a change file that names it in `supersedes:` or `cancels:`, never by editing the
   CHANGELOG by hand; the machine only checks what was marked. A plugin name or an internal name that must not be public is
   reworded the same way.
3. **Cut, check, commit** (cut writes the working tree only: the `CHANGELOG.md` sections, each starting with that
   `Released together:` line when two or more plugins are released, with the change files' `upgrade:` lines under `### Upgrade notes`, the change files removed, `Frozen at`; no manifest and no kb page):

   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/release.py" cut --public REPO
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/release.py" check --public REPO      # kind: release, rc 0
   git add -A -- plugins .changes && git commit -m "chore(release): <plugin> <version>, …"
   ```

   cut refuses (rc 1, the reason printed) a dirty tree, a detached HEAD, the branch `main` or `release`, a HEAD that lacks main's
   tip, a `release` that holds a hotfix main lacks (merge its back-merge PR first), nothing pending, no `--public` or a tag list
   it cannot read, a named line it cannot find as written, or a surface change named below `minor`. check is red when a section
   below the new one is still cut and not published, or a line taken out is still there. When main moves before the PR merges, merge main and cut again: CI is red while a pending change file is not shipped.
4. **Open the PR into main** with `vibemaestro-sdlc:ship`; the PR body names the versions. It merges through `kit:merge-pr` like any PR.

## A fold (the top version is cut but not published)

When a release was cut and merged but never published, and the changes merged since must ship under that same version, fold
them into it instead of cutting the next one (a plain cut joins it into the next version instead). A section cut and not
published below the top one (left by a cut from before this rule) joins the top one too, which keeps its version. Whether a version is published is read from the public repository's tags
`<plugin>--v<version>` (`REPO` is its `owner/name` on GitHub, or a git URL): the branch `release` cannot tell it, because it moves
before anything is published.

1. A worktree of its own from the tip of main, as for a release.
2. `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/release.py" plan --fold --public REPO`: each plugin a change file names reads
   `X.Y.Z -> X.Y.Z (fold, <level>)`.
3. `release.py cut --fold --public REPO`, then `release.py check --public REPO` (kind: fold, rc 0), then commit as for a release.
   The cut rewrites the plugin's top section as its next public section: the lines of the unpublished sections it joins (oldest
   first), then each change file's line, and the upgrade lines under `### Upgrade notes`, less what is taken out (as for a
   release). A line the section already holds is not written again, and no `Released together:` line is written: the section
   keeps the one its cut wrote. It refuses when a version's tag already exists
   (published: cut the next version without `--fold`), when the tags cannot be read, when a plugin was never released, and when
   the folded levels ask another version than the section carries (a minor into a patch section). In those cases a plain cut is
   the way.
4. A line the section already held may be reworded in the same PR (one fix commit after the cut), since the version is not
   published: it keeps its `- <level>:`, and the section keeps its count of entries and notes. `check --public REPO` then says
   how many lines it rewords. A published section and every older section stay frozen.
5. Open the PR and, after it merges, move `release` to it, as for a release. The check in CI needs `--public REPO` to pass a release or a fold.

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
exported `plugin.json`; on each dependency on a released sibling, the floor `>=` the sibling's version on the `Released
together:` line of the plugin's own released section, the sibling it was released with (`>=0.1.0` for a section with no line), so a
plugin whose version does not move keeps its manifest bytes; and tags `<plugin>--v<version>`, the form Claude Code resolves a
dependency range against. The body of a public release (a GitHub Release on each new tag) is what
`release.py notes <plugin> <version> [--repo DIR]` prints: that version's CHANGELOG section, the final state since the previous
public version, so the plugins released together come first, then `### Updating`, which starts by telling the user to update a sibling too when the plugin's floor on it moved
since its previous release (rc 1 when the CHANGELOG has no such section).
