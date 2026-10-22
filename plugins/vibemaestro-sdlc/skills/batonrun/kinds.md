# batonrun reference: kind batons

Read this when a kind may cover the act (no script to write). Also printed by `<launcher> help kinds`.

Three kinds run as they are, with their arguments, checked like a session baton (`new --from <kind>` writes any kind to a
file instead, to change it); the signature binds the plugin version, as for a kit baton:

    <launcher> go kind:install-file <source> <directory>        copy one file in, read-only (never under .git, .claude, the config or state dir)
    <launcher> go kind:settings-merge <settings.json> <rules.json>   add permission rules (Stops security-boundary: exit 8)
    <launcher> go kind:ci-rerun-failed <owner/name> <run id>      re-run the failed jobs of one run of a private repository

Next, not built: `owner-merge-pr`, a merge the owner signs for a PR that touches `merge.deny_globs`; the guard refuses such a
PR whatever signs it, so it waits for a guard change.

