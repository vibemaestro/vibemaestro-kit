---
applyTo: "**/.claude-plugin/plugin.json,**/.claude-plugin/marketplace.json,.changes/**,plugins/*/CHANGELOG.md"
description: "Only in a repo that publishes plugins from an export: no version in its manifests; a PR adds a .changes/ file; only a release writes one, as a CHANGELOG heading the export puts in the manifest"
---

1. No `version` key in a `plugin.json` or a marketplace entry, and a sibling dependency is the bare name: Claude Code then keys an install by the commit, so every change reaches it with no bump.
2. A PR that changes `plugins/<name>/` adds one `.changes/<slug>.md` (plugins, level patch|minor|major, one line) and writes no version anywhere: not a manifest, not a kb page.
3. A plugin's version is its last public release, the first `## X.Y.Z` heading of its `CHANGELOG.md`; the first public release is 0.1.0 for each plugin.
4. Only two PRs add such a heading: a release PR (skill `release`; it ships every pending change file) and a hotfix PR into `release` (patch); `release.py cut` writes either, and nothing else moves.
5. Level: patch a fix, minor a feature, major a breaking change (a `CONTRACT.md` row removed or renamed); a 0.x plugin may break in a minor.
6. After either merges, an owner-signed baton moves `release` to it; then publish it your own way. The export writes each released version into its `plugin.json` and `>=0.1.0` on sibling dependencies; the tags `<plugin>--v<version>` live in the published repo only (never in the source repo: a dependency range would install the tagged commit instead of main).
7. A hotfix's back-merge PR comes from `backmerge/<sha12>` and merges with a merge commit (the merge guard's lane): never squash it or update its branch.
