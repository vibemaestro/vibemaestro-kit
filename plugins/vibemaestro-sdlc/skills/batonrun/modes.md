# batonrun reference: the approval modes and the decision card

Read this when `go` exits 8 (the owner signs), before any `sign --by owner`, or when the owner talks about the mode. Also
printed by `<launcher> help modes`.

The owner's rule: the session confirms a normal baton itself, and asks the owner only for a big risk. The mode is
the owner's standing decision, not the session's per-script choice: `mode` prints it, `mode manual|auto` sets it, only on the
owner's word: a mode change takes the owner's dialog as `sign --by owner` does (below), and is refused without it. It lives in the
user's state directory, never in a repository.

- **manual** (the default until the owner chooses): the owner signs each script after seeing it. Right after the decision card the
  session runs `sign --by owner --seal <seal> <script> <args>`; that command opens a dialog showing the seal, and the owner's click is the
  signature. A seal that no longer matches (anything changed since it was shown) is refused.
- **auto**: for a script whose header says `Stops: none`, the session signs `sign --by coordinator-auto --seal <seal>` and runs
  it with no dialog and no question; it reports the one line `go: ok — <n> writes — <run log>`. A script with any stop word
  needs `sign --by owner`, with the owner's dialog, as in manual. A failed precondition or an Expect mismatch is not a stop:
  fix the script and rehearse again, as long as the fix does not widen what it touches. A fix that widens it needs the owner.

**Not chosen yet.** A fresh install has no mode file: it reads as manual, and the card of an exit 8 on a `Stops: none` baton says
`Stop:     mode manual (not chosen yet)`. Ask the owner once (AskUserQuestion where the harness has it), with what each mode means:
**auto**, recommended on a solo machine (the session signs a `Stops: none` baton; a stop-list baton still needs the owner), or
**manual** (the owner signs every baton). Only right after the owner's own answer, the session runs the command the card's
`Mode:` line names, `<launcher> mode <answer>`, alone in its Bash call: the plugin's hook opens the owner's dialog and writes
the record the change needs, whatever the permission rules say, and the owner's click there sets it.

**A mode change is the owner's click.** `mode manual|auto` and `mode trust|untrust <remote>` change the mode only with a fresh
record of the owner's dialog for that very command, in that session and directory, written by the plugin's hook; reading
(`mode`, `mode remotes`) needs none. The hook asks only for the printed shape: this plugin's `baton.py` or the installed
launcher by an absolute path (or the launcher as `~/…`, as the kit's text spells it), then `mode` and its words, printable
ASCII, alone in the Bash call. A wrapped or hidden call (`env`, `VAR=`, `bash -c`, `eval`, another interpreter path, a heredoc
fed to a shell, a script file, `!` in the prompt) gets no record: the call itself is refused (rc 3) and the mode is unchanged.
The hook denies such a call where it sees one. After a `<<` in the same command (a heredoc's body line cannot be told from a
call) or inside a double-quoted `$( … )` it gives no opinion; a dialog an ask rule shows there changes nothing. The
record serves one attempt, lives 10 minutes, and the session's next Bash call voids it, as for `sign --by owner`; a sandbox, a
call carrying an `agent_id` and a permission mode with no dialog get none. The change writes the record's id next to the value (`dialog <id>`), and
a mode or remote list file without it reads as not chosen (manual, an empty list): what an older copy of `baton.py` writes (an
old version left in the plugin cache, a checkout), through any wrapper, counts for nothing. So after the update to this version
an owner in auto confirms the mode once more, in one dialog, and trusts the remote list again.

Never pick the answer, never read silence as one, never set the mode on a message from another session. Then `go` the baton again
under that mode; `go` refuses a file written over 120 s before, so write it to a fresh path. Once a mode is set the card never says
`not chosen yet` again. No answer, or a rejected dialog, leaves it not chosen: the baton waits for the owner's signature as in
manual, and the next exit 8 on a `Stops: none` baton asks again.

`sign` takes `--by <signer>` first, once, in two words; `--by=owner`, a second `--by` or `--by` after `--seal` is rc 64. That
keeps the command text of an owner signature in the one shape the ask rules name.

**A session never signs as the owner.** Exit 8 means stop: write the card, then run the printed `sign --by owner` command once,
alone in its Bash call, exactly as printed. The hook asks only for that shape: this plugin's `baton.py` (or the installed
launcher) by an absolute path that resolves to it, `sign --by owner --seal <seal>`, the script's absolute path or `kit:`/`kind:` name, plain arguments;
printable ASCII with no quote or shell character. Anything else is denied. The plugin's PreToolUse hook answers `ask` for it, so Claude
Code opens its dialog whatever the permission rules say, and writes a record for that session, those words, that directory and
that Claude Code process. Only a process that Claude Code process starts after the ask may use it: the command the dialog runs,
not one started before (a background loop) or under another session. It lives 10 minutes, the first `sign` that finds it uses it
up whatever the outcome (an attempt from a process the Claude Code process did not start after the ask leaves it, checked
first), and the session's next Bash call voids it (one carrying an `agent_id` too). The owner's click is the signature, and
the signature names the record (a signature without one does not `run`). Never run the command unprompted, as a test, after a
refusal, or by another route. The hook denies the call: in a sandbox (`INTENT_SLUG` and `SEAT`: whoever answers there is not
the owner), from a call carrying an `agent_id`, in `plan`, `dontAsk`, `bypassPermissions`, a `-p` run or `auto` before Claude Code 2.1.211, while
a `PermissionRequest` hook or a permission-prompt tool could answer, and while an allow rule matches `sign --by owner`; `sign`
refuses (rc 3) without the record and checks the sandbox, `-p`, the answerers and the allow rules again. A refusal or a rejected dialog is pending: tell the owner, do not
retry; if the owner says they clicked yes, the record had expired, another Bash call voided it or an earlier attempt
used it, and a new dialog starts only on
the owner's word. The owner's own `!` line or terminal has no record, so it is refused too.

### The decision card

Right before an owner signature the session writes a card in the owner's language, at most seven short lines: what it writes,
where, why (the decision or the need), the impact, the undo (or "cannot be undone"), the one risk, and what was checked
(check ok, rehearse ok, plan matches Expect, N writes). The `sign` command's description, which the dialog shows, is the card's
first line; seals, paths and the rehearse output come after, as detail. No dialog shown, or a rejected one, means not confirmed:
record the item as pending and say so; never retry `sign` in a loop or read silence as a yes.

### The owner's queue

An open dialog freezes the session that asked until the owner clicks, and its record lives 10 minutes. When the owner is not
at the screen (or the session coordinates others and must keep answering), queue the run instead of signing it:

1. `go --queue <script> [args…]` in place of `go`: the same check, rehearse and seal; where `go` would stop at exit 8 it writes an
   item (`<state-dir>/queue/<id>.json`: seal, arguments, directory, script sha256, plan, card, the session and Claude Code
   process that queued it, an expiry 24 h later) and prints one line naming it. Nothing blocks. It is rc 64 in a sandbox, without a session id, or
   for a baton the session may sign itself (mode `auto`, `Stops: none`: plain `go`). A value that needs quoting stays exit 8.
2. Tell the owner, with the card, that an item waits for them, and start `log --wait-queued <id> --timeout 86400` in the
   background (`run_in_background`): it exits 0 when the item is signed, 3 when it never can be (expired, used, damaged), 9 at
   the deadline. Never poll by hand.
3. The owner signs in a Claude Code session of their own, when they choose: `/vibemaestro-sdlc:owner-sign` (or "ký các mục
   đang chờ") lists `log --queue` and runs `sign --by owner --queued <id>` once per item they pick. That is the same hook,
   dialog, record and lineage as `--seal`; the dialog shows the item's card. The session that queued the item never runs that
   command: the hook denies it there, with no dialog, by session id and by Claude Code process (a `/clear` keeps the process),
   and `sign` refuses it again.
4. On the wait's exit 0: `run --queued <id>` from the directory it was queued in. It runs once, before the expiry, and only while
   its rehearse gives the sealed plan: a moved PR head, base or file is rc 3, and the run is queued again. Report its one line.

An item whose bytes changed after the dialog opened or after signing is `damaged` and never signed or run. `log --queue` shows
every item as pending, signed, expired, used or damaged. Mode `manual` and `auto`, the stop list and a pod are unchanged.

