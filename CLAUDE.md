# Working in this repository

## Tests

- No planted breaks: a test never copies or edits the code under test, or the repository's own files, to make a check go red.
  The evidence for a new or changed test is that it is red on main before the change and green after it.
- A functional negative case stays: a checker given a bad input it must report is an ordinary test. It builds its input and runs
  the checker through `capped` (`tests/fixtures/capped.sh`); code that rewrites a file only to build such an input says
  `not a break` on that line or in its helper.
- `tests/test-capped-breaks.sh` ([L3] to [L5], `tests/fixtures/planted_lint.py`) refuses a planted break in any suite or fixture
  not listed in `tests/fixtures/planted-baseline.txt`, the files that still held breaks when the rule changed. It runs when a
  suite or this file changes; a helper in a fixture is caught through the suite that calls it, and by the full run.
- Run what a change reaches: `bash tests/run-all.sh --changed origin/main`.
