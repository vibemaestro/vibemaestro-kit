# batonrun reference: limits

Read this when you need to know what baton does not guard, or which patterns the stop lint flags. Also printed by `<launcher> help limits`.

baton guards an honest but fallible session: a forgotten step, an edit after approval, other arguments, a changed world, a
second run. It does not stop a session that sets out to deceive (it could write a record by hand, or run a script with plain
`bash`): that is the job of read-only tools and the owner's deny rules. The rule `batonrun` reminds before a privileged command
run directly, once per session; it does not block. Separately, its hook warns on EVERY launcher command (`sign`, `run` or
`go`) that is not bare: a pipe, a chain (`&&`, `||`, `;`, `&`, a newline), a redirect, a command substitution or a comment
outside quotes, a prefix (`VAR=…`, `time`, `env`, `timeout`, `!` …) or a shell wrapper (`bash -c`, `eval`): the allow rules
then do not match and the classifier decides. A warning, not a block; a launcher behind a variable is not seen. It leaves silent a
heredoc on `go -` with a quoted delimiter and nothing after the closing line, though a baton on it is blocked (below), and names any
other (an unquoted delimiter lets the shell expand the body before baton reads a byte; a line after the closing one is a command of its own).

**`go -` with a baton is blocked** (tested with Claude Code 2.1.303, `-p --permission-mode default`, allow rule
`Bash(<launcher> go:*)`): the allow rule matches a short `go -` heredoc, but a heredoc that
holds the baton skeleton is denied before any rule applies, by a built-in check of Claude Code ("Contains brace with quote
character (expansion obfuscation)"), which fires on every `{ … }` function body that holds a quote, `write()` and `gh_state()`
among them. Auto mode is not tested. Default mode is a supported mode, so a baton is never sent on `go -`: Write it to a fresh
path and `go <path>` in the same response. The check is a safety check of the tool, not a flaw to route around: do not reshape
the skeleton to dodge it. The measured verdicts are pinned in `tests/fixtures/go-dash-verdict.txt`, and `fam_go_dash_guidance` fails when the
core or the rule recommends `go -` while the fixture says blocked.

A plugin script is trusted from the plugin root `baton.py` runs from. The permission rules allow only the launcher, which runs
the versioned install under the Edit-denied plugin cache; a copied `baton.py` run by hand from elsewhere is forgery, and so is a
script that builds the name of `BATON_PLUGIN_ROOT` at run time (`eval`, `declare -n`): `check` reads the text, it does not
run it.

The permission rules match the command text, not what the shell makes of it: a quoted `'--by'`, a wrapper the matcher does not
see through, or a write by an arbitrary process (Edit rules cover the write tools and the file commands Claude Code
recognises) can pass them. They hold the honest path; a session that games them is forging. `permissions --check` reads the
permission rules only: not `defaultMode`, a `--dangerously-skip-permissions` launch, or the classifier's own settings.

## The stop patterns

The patterns `check` flags: a backstop, not a proof (an `echo` of the words counts; a stop act may match none). Declare what
the act does, not what the lint finds.

<!-- stop-patterns -->
- `irreversible-delete`: `gh repo|release delete`; `kubectl … delete ns|pvc|pv`; `git push --delete|-d|:<ref>`; `gh api -X DELETE`; `git push --mirror`
- `secrets`: `gh secret`; `kubectl … secret`; `vault kv|read|write|delete`
- `security-boundary`: `kind: Role|RoleBinding|ClusterRole…|NetworkPolicy|ValidatingAdmissionPolicy`; `gh pr merge --admin`; `private=false|visibility=public`; `--visibility public`
- `cluster-lane`: `flux suspend`; `kubectl … drain|cordon`
- `history-rewrite`: `git push --force|-f|+<ref>`; `git filter-branch|filter-repo`; `git push --mirror`
- `money-org`: `gh repo create|rename|transfer|archive`; `gh api /orgs/<org>/members|memberships|teams|billing|settings`
- `publish`: `--visibility public`; `npm publish`; `gh gist create --public|-p`; `private=false|visibility=public`
<!-- /stop-patterns -->
