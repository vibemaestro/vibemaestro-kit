# batonrun reference: setup on a new machine, and after an upgrade

Read this when there is no launcher yet, or SessionStart says the permission check failed. Also printed by
`<launcher> help setup`.

Once per machine (the session runs these; the owner applies the result). The kit run
`kit:coordinator-bootstrap` can do steps 1 and 2 in one run the owner signs, on any machine: follow the skill `coordinator-bootstrap`.

1. `python3 ${CLAUDE_PLUGIN_ROOT}/scripts/baton.py permissions --install-launcher`: copies the launcher to
   `<state-dir>/bin/baton`.
   It runs the newest installed vibemaestro-sdlc from 2.1.0 on and nothing else: it refuses, with the reason, a `baton.py`
   outside `<claude-dir>/plugins/cache/vibemaestro/vibemaestro-sdlc/<version>/scripts/`. The two paths are written into it
   at install, so a variable cannot redirect it; it runs as `python3 -I` (needs an `env` with `-S`, as on Linux and macOS).
2. `<launcher> permissions --print`: the user-settings block. The owner adds it through Claude Code's settings
   (`/permissions`, or the user `settings.json`); the plugin never writes settings. Besides the rules it turns Claude Code's
   attribution off: no Co-Authored-By trailer, no PR line, no session URL; the object form,
   because old Claude Code versions reject `"attribution": false`.
3. `<launcher> permissions --check`: rc 0 when the rules in force (managed, user and project settings) hold the split;
   rc 7 lists each rule that is MISSING, STALE (another version, a broad `sign:*` ask, a `Write` rule, an old launcher) or
   UNSAFE (an allow that matches `sign --by owner` or `mode`). Attribution that is on (or unset, Claude Code's default) is a
   WARNING line that does not change the exit code. Each attribution key comes from the first scope that sets it: managed,
   then the project's local file, the project's, the user's (among `--settings <file>`, which replaces them, the last one).

A plugin upgrade needs nothing: the launcher picks the new version. SessionStart prints one line when the check fails, with
the command that prints the fix; in mode `manual` with no baton rule at all it stays silent, because there a dialog on every
baton command is the intended behaviour.

