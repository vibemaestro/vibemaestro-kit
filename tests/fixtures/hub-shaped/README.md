# hub-shaped fixture (synthetic)

A small tree shaped like a repository that already has its own process files: an instruction directory with `applyTo`
rules, a settings file carrying both hook-script markers, a map-style current-state ledger, an allowlist file and the
worked-example config. Every name and value is made up (`example`, `acme`); nothing here comes from a real repository.

It is a plain tree, not a git repository. A test copies it to a scratch directory and runs `git init` there when it
needs one. Suites that need an un-adopted tree delete `.vibemaestro/sdlc.json` from their copy.

| Path | What it stands for |
|---|---|
| `.github/instructions/*.instructions.md` | repo rules with `applyTo` (and one `applyWhen`) in the plugin's frontmatter |
| `.claude/settings.json` | the legacy hook markers (both script names) |
| `kb/current-state.md` | a map-style ledger: numbered sections, a five-column table in section 2 with a closed Status column, a three-column table in section 8, longer lines than the plugin's default; it is the good ledger of `tests/test-gate-current-state.sh` |
| `.pr-sensitive-allow` | allowlist of hashes (never values) |
| `.vibemaestro/sdlc.json` | the worked example of the consumer-contract spec, synthetic values; its `current_state` is the profile that `tests/test-gate-current-state.sh` runs the `map` cases with (watched paths `systems/` and `deploy/`, `table_own_width` on, a synthetic `*unchecked*` label as a `decorations` entry of the Status column) |
