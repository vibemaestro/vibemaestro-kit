# batonrun reference: the permission snippet

Read this when `permissions --check` fails or the owner asks why the rules are safe. Also printed by `<launcher> help permissions`.

`<launcher> permissions --print` prints it for this machine, with the real paths; its shape:

```json
{
  "permissions": {
    "allow": ["Bash(<launcher> new:*)", "Bash(<launcher> check:*)", "Bash(<launcher> rehearse:*)", "Bash(<launcher> run:*)",
              "Bash(<launcher> go:*)", "Bash(<launcher> log:*)", "Bash(<launcher> sign --by coordinator-auto:*)"],
    "ask":   ["Bash(<launcher> sign --by owner:*)", "Bash(\"<launcher>\" sign --by owner:*)", "Bash('<launcher>' sign --by owner:*)",
              "Bash(~/<rel> sign --by owner:*)", "Bash($HOME/<rel> sign --by owner:*)", "Bash(\"$HOME/<rel>\" sign --by owner:*)",
              "Bash(baton sign --by owner:*)",
              "Bash(<claude-dir>/plugins/*/scripts/baton.py sign --by owner *)", "… the same in \"…\" and '…', from ~/ and $HOME/",
              "Bash(python3 <claude-dir>/plugins/*/scripts/baton.py sign --by owner *)", "… each spelling after python3",
              "… then every one of these again with `mode` in place of `sign --by owner`"],
    "deny":  ["Edit(//<claude-dir>/plugins/**)", "Edit(//<state-dir>/**)"]
  },
  "attribution": {"commit": "", "pr": "", "sessionUrl": false}
}
```

When the state directory lies under your home, `--print` also allows each allowed command spelled `~/…/bin/baton`: the rules match
the command text, and a call through `~` matches no rule. `<rel>` is the launcher's path below your home; the `~/` and
`$HOME/` ask rules are printed only when it lies there (the `<claude-dir>` ones likewise). Run from a checkout outside
`<claude-dir>/plugins`, `--print` also names that checkout's own `baton.py` (bare, quoted, after `python3`).
`<launcher>` is `<state-dir>/bin/baton` (shell-quoted when the path holds a space); `<state-dir>` is `$XDG_STATE_HOME/vibemaestro/baton`, else
`~/.local/state/vibemaestro/baton`; `<claude-dir>` is `$CLAUDE_CONFIG_DIR`, else `~/.claude`.

Why the split is safe. `run` may be allowed because the signature gates it. `sign --by coordinator-auto` and `go` (which signs only
as that) may be allowed because
baton.py itself refuses that signer outside mode `auto` and for any script whose `Stops` is not `none`: the session can sign
only what the owner's standing rule already allows. `sign --by owner` and a mode change (`mode manual|auto`, `mode trust|untrust
<remote>`) need the owner's click: the plugin's hook asks for the literal call and writes the record the call needs, and the call
refuses without one, so a wrapped or hidden call fails closed whatever the rules match. The ask rules show the same dialog for
every spelling the kit prints or a session types (the launcher bare, quoted, from `~/` or `$HOME/`; a bare `baton`; `baton.py`
under `<claude-dir>/plugins` bare, quoted and after `python3`). Each starts with that program word, never with `*`: a rule with
a leading `*` matched a command that only mentioned the words (a printf, a heredoc, a commit message), and a dialog that asks for
something other than the call teaches the owner to click through. The one `*` inside a rule is the version directory, after
the literal `<claude-dir>/plugins`: in the matcher `*` is any text, `/` and spaces included, so a `*` right after a bare `/` would
match any program run by its path. That version `*` still spans spaces: a command that starts with another program under
`<claude-dir>/plugins` (or `python3` and one) and later quotes `…/scripts/baton.py mode auto` or a `sign --by owner` call by
that path matches, and shows one dialog for a mention; the rules cannot say "one directory" (the launcher's rules, with no
`*`, never do). The `mode` rules name the subcommand right after the program, so a `run … mode fast`
argument stays out. The deny rules keep
the launcher, the plugin cache, `installed_plugins.json` (which the launcher trusts), the signatures and the mode out of
reach of Claude Code's write tools (an allow rule on a command is only as safe as what it runs is unwritable).

What this rests on, checked against Claude Code 2.1.290 (its permission documentation and its matcher):
- `baton.py`'s own matcher (`bash_matches`, which `permissions --check` uses) follows that documentation; it is not Claude
  Code's code, and it was not measured against a live Claude Code again for the anchored rules. A mismatch fails closed for
  `sign --by owner` and a mode change (the record is the guard): at worst a dialog the rules meant to show is missing, or one
  shows that they did not mean.
- Rules are tried deny, then ask, then allow, across every settings scope combined; the first match wins, whatever the
  specificity. An ask rule still prompts in auto mode: rules come before the auto-mode classifier. Without rules, the classifier
  blocked baton scripts that run a remote shell; with only an ask on every `sign`, the owner got a dialog for normal batons.
- A rule ending in `:*` is a literal prefix: a `*` inside it is not expanded, so a rule cannot pick "any version" in the
  middle of `…/vibemaestro-sdlc/<version>/scripts/baton.py`. In other rules `*` is any text, `/`, `..` and spaces included,
  too wide for an allow. Hence the launcher: a path no upgrade moves.
- Path rules: `Edit(path)` covers every write tool; `Write(path)` rules are not matched; an absolute path needs `//`. They
  cover Bash file commands Claude Code recognises, not any process (see `limits.md`).

**The block before the anchored rules.** Its ask rules started with `*` (`Bash(*baton* sign --by owner*)` and six `mode` ones:
`*baton.py mode *`, `*/baton mode *`, each also with `"` or `'` after the program). `permissions --check` names each one it
finds as STALE. `<launcher> go kit:permissions-upgrade` swaps them in the user settings: it removes exactly those patterns,
adds the anchored rules that are absent and changes nothing else (`Stops: security-boundary`, so the owner signs; undo puts the
file back byte for byte). An old pattern in another scope (managed, a project's) is named and left to the owner.
