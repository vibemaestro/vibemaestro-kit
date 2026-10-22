# batonrun reference: the permission snippet

Read this when `permissions --check` fails or the owner asks why the rules are safe. Also printed by `<launcher> help permissions`.

`<launcher> permissions --print` prints it for this machine, with the real paths; its shape:

```json
{
  "permissions": {
    "allow": ["Bash(<launcher> new:*)", "Bash(<launcher> check:*)", "Bash(<launcher> rehearse:*)", "Bash(<launcher> run:*)",
              "Bash(<launcher> go:*)", "Bash(<launcher> log:*)", "Bash(<launcher> sign --by coordinator-auto:*)"],
    "ask":   ["Bash(<launcher> sign --by owner:*)", "Bash(<launcher> mode:*)", "Bash(*baton* sign --by owner*)",
              "Bash(baton mode:*)",
              "Bash(*baton.py mode *)", "Bash(*baton.py\" mode *)", "Bash(*baton.py' mode *)",
              "Bash(*/baton mode *)", "Bash(*/baton\" mode *)", "Bash(*/baton' mode *)"],
    "deny":  ["Edit(//<claude-dir>/plugins/**)", "Edit(//<state-dir>/**)"]
  },
  "attribution": {"commit": "", "pr": "", "sessionUrl": false}
}
```

When the state directory lies under your home, `--print` also allows each allowed command spelled `~/…/bin/baton`: the rules match
the command text, and a call through `~` matches no rule.
`<launcher>` is `<state-dir>/bin/baton` (shell-quoted when the path holds a space); `<state-dir>` is `$XDG_STATE_HOME/vibemaestro/baton`, else
`~/.local/state/vibemaestro/baton`; `<claude-dir>` is `$CLAUDE_CONFIG_DIR`, else `~/.claude`.

Why the split is safe. `run` may be allowed because the signature gates it. `sign --by coordinator-auto` and `go` (which signs only
as that) may be allowed because
baton.py itself refuses that signer outside mode `auto` and for any script whose `Stops` is not `none`: the session can sign
only what the owner's standing rule already allows. `sign --by owner` and `mode` ask, so the owner's click is the approval; the
wildcard asks also catch another spelling of the same command (the real `baton.py` path, a relative path, a quoted path),
and the `mode` ones name the program right before `mode`, so a commit message or a `run … mode fast` argument stays out. The deny rules keep
the launcher, the plugin cache, `installed_plugins.json` (which the launcher trusts), the signatures and the mode out of
reach of Claude Code's write tools (an allow rule on a command is only as safe as what it runs is unwritable).

What this rests on, checked against Claude Code 2.1.290 (its permission documentation and its matcher):
- Rules are tried deny, then ask, then allow, across every settings scope combined; the first match wins, whatever the
  specificity. An ask rule still prompts in auto mode: rules come before the auto-mode classifier. Without rules, the classifier
  blocked baton scripts that run a remote shell; with only an ask on every `sign`, the owner got a dialog for normal batons.
- A rule ending in `:*` is a literal prefix: a `*` inside it is not expanded, so a rule cannot pick "any version" in the
  middle of `…/vibemaestro-sdlc/<version>/scripts/baton.py`. In other rules `*` is any text, `/`, `..` and spaces included,
  too wide for an allow. Hence the launcher: a path no upgrade moves.
- Path rules: `Edit(path)` covers every write tool; `Write(path)` rules are not matched; an absolute path needs `//`. They
  cover Bash file commands Claude Code recognises, not any process (see `limits.md`).

