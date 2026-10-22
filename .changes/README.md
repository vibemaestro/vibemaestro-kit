# Change files

One file per pull request that changes `plugins/<name>/`, named after the PR's intent slug (`.changes/2026-10-20-my-slug.md`), so
parallel pull requests never edit the same line:

```
---
plugins: vibemaestro-sdlc, vibemaestro-brain
level: minor
---
One line a user of the installed plugin understands: what changes for them.
```

- A regular file, not a symlink. `plugins:` one or more plugin names of `.claude-plugin/marketplace.json`; `level:` `patch` (a fix), `minor` (a feature) or `major`
  (a breaking change; for `vibemaestro-sdlc`, a `CONTRACT.md` item, fact, exit code or key removed or renamed). A 0.x plugin may
  break in a minor.
- The pull request writes no version anywhere (the private repo carries none: no `version` in a `plugin.json` or
  `marketplace.json`, none in a kb page), edits no change file already on main, and never deletes this README. The files here
  collect the notes of the next public release: its release pull request consumes every one into a `## <version>` section of each
  named plugin's `CHANGELOG.md`, which the public export writes into the exported manifest.
- Checked by `python3 plugins/vibemaestro-sdlc/scripts/release.py check`.
