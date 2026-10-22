---
applyWhen: "\bgh(?:(?:\\?\s)+(?:-R|--repo)[\s=]+\S+)?(?:\\?\s)+pr(?:(?:\\?\s)+(?:-R|--repo)[\s=]+\S+)?(?:\\?\s)+merge\b|\bgh(?:(?:\\?\s)+(?:-R|--repo)[\s=]+\S+)?(?:\\?\s)+(?:(?:repo|release)(?:\\?\s)+delete|(?:secret|variable)(?:\\?\s)+(?:set|delete|remove)|repo(?:\\?\s)+edit\b[^|;&\n]*--visibility)\b|\bgh\s+api\b(?=[^|;&\n]*\s(?:-X\s*|--method[\s=]+)[\x22\x27]?(?i:POST|PATCH|DELETE|PUT)\b)|\bgh\s+api\b(?![^|;&\n]*\sgraphql\b)(?![^|;&\n]*\s(?:-X\s*|--method[\s=]+)[\x22\x27]?(?i:GET|HEAD)\b)(?=[^|;&\n]*\s(?:-[fF]\S*|--(?:raw-)?field|--input)(?:\s|=|$))|\bgh\s+api\s+graphql\b(?=[^|;&\n]*(?i:mutation))|\bdocker(?:\s+-{1,2}(?!-)[\w-]+(?:[=\s]+(?!-)\S+)?)*\s+(?:(?:image|manifest|compose)\s+)?push\b|\bdocker(?:\s+-{1,2}(?!-)[\w-]+(?:[=\s]+(?!-)\S+)?)*\s+(?:buildx(?:\s+-{1,2}(?!-)[\w-]+(?:[=\s]+(?!-)\S+)?)*\s+)?(?:build|bake)\b[^|;&\n]*\s(?:--push\b|(?:--output|-o)[=\s]+\S*(?:type=registry|push=true))|\bdocker(?:\s+-{1,2}(?!-)[\w-]+(?:[=\s]+(?!-)\S+)?)*\s+buildx\s+imagetools\s+create\b|\bclaude(?:\s+-{1,2}(?!-)[\w-]+(?:[=\s]+(?!-)\S+)?)*\s+plugins?\s+(?:(?:install|i|uninstall|remove|update|enable|disable|prune|autoremove|configure)\b|marketplace\b(?!\s+list\b))|\bgit(?:\s+(?:-[Cc]\s+\S+|--(?:git-dir|work-tree|namespace)\s+\S+|--(?!(?:git-dir|work-tree|namespace)(?:\s|$))[\w-]+(?:=\S+)?))*(?:\\?\s)+push\b(?:[^|;&\n]|(?<=\\)\n)*?(?:\s-[A-Za-z]*f[A-Za-z]*\b|\s--force(?![-\w])|\s--mirror\b|\s[\x22\x27]?\+[^\s+])|\bBATON_PHASE=(?![\x22\x27]?rehearse\b)"
description: "A privileged command run directly (GitHub merge, delete or API write, registry push, user plugin config, force-push): make it a run, one baton script through scripts/baton.py (BatonRun)"
---

# BatonRun: a privileged command goes through a baton script

This command writes outside the session: never typed directly, never handed to the owner as lines, it is one **run**, a fixed series in
one baton script the session runs through the launcher `<state-dir>/bin/baton` (until installed: `python3 <root above rules/>/scripts/baton.py`). What a run is: the standard `docs/batonrun.md` of the plugin repo; how: skill `batonrun`.
1. `go kind:<name>`/`kit:<name>` if one covers it; else a script (header, `write()` gate): Write it to a fresh path and `go` it in the same
   response, never in a heredoc on `go -` (Claude Code blocks it): one `PLAN` line per write against `Expect`, carrying what was read before the act, never a value the act moves.
2. The session confirms a normal baton itself (mode `auto`, `Stops: none`: `sign --by coordinator-auto --seal <seal> …`). A big
   risk (a stop-list script, or mode `manual`): a decision card (seven short lines, the owner's language), the script, the rehearse
   output, then `sign --by owner --seal <seal> …` in a dialog. No dialog, or a rejected one, is not a go: pending, never retried.
3. `run <name>.sh <args>`: only signed (bytes, arguments, directory, environment, plan); post-check; undo compares every target
   with its before-state, or `Undo:` names what it leaves; `log` is the audit line. `mode` changes always ask. How: skill `batonrun`.

Run the launcher bare, one command per call: no `cd … &&`, no pipe after `sign`, `run` or `go`; set the directory first. A
compound command matches no permission rule, so the classifier decides (it denied a guarded merge three times); a pipe hid a failed
`sign`. A Kubernetes write is a baton the owner signs and the session runs. Limits: this reminder comes once per session, not a
block, on the command line only (`baton.py run` and a command behind a variable are not seen); baton guards against slips, not
forgery. Apart from it, this rule's hook warns on EVERY launcher `sign`, `run` or `go` sent with a pipe, chain or redirect.
