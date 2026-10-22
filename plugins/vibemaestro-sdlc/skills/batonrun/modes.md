# batonrun reference: the approval modes and the decision card

Read this when `go` exits 8 (the owner signs), before any `sign --by owner`, or when the owner talks about the mode. Also
printed by `<launcher> help modes`.

The owner's rule: the session confirms a normal baton itself, and asks the owner only for a big risk. The mode is
the owner's standing decision, not the session's per-script choice: `mode` prints it, `mode manual|auto` sets it, only on the
owner's word, and with the permission rules (`permissions.md`) a mode change always opens a dialog. It lives in the user's state directory,
never in a repository.

- **manual** (the default until the owner chooses): the owner signs each script after seeing it. On the owner's go the session runs
  `sign --by owner --seal <seal> <script> <args>`; that command opens a dialog showing the seal, and the owner's click is the
  signature. A seal that no longer matches (anything changed since it was shown) is refused.
- **auto**: for a script whose header says `Stops: none`, the session signs `sign --by coordinator-auto --seal <seal>` and runs
  it with no dialog and no question; it reports the one line `go: ok — <n> writes — <run log>`. A script with any stop word
  needs `sign --by owner`, with the owner's dialog, as in manual. A failed precondition or an Expect mismatch is not a stop:
  fix the script and rehearse again, as long as the fix does not widen what it touches. A fix that widens it needs the owner.

**Not chosen yet.** A fresh install has no mode file: it reads as manual, and the card of an exit 8 on a `Stops: none` baton says
`Stop:     mode manual (not chosen yet)`. Ask the owner once (AskUserQuestion where the harness has it), with what each mode means:
**auto**, recommended on a solo machine (the session signs a `Stops: none` baton; a stop-list baton still needs the owner), or
**manual** (the owner signs every baton). The card's `Mode:` line then says who sets it, from the check of `permissions --check`
on the user and managed settings alone (a project's settings are found from `CLAUDE_PROJECT_DIR` or the directory `go` runs
from, which may not be the session's project):
- clean (the ask rules are in force there): only right after the owner's own answer, the session runs `<launcher> mode <answer>`;
  the ask rule opens a dialog, and the owner's click there sets it.
- not clean (as on a fresh install: nothing would ask), or a settings file that cannot be parsed: the session does not run `mode`.
  It asks the owner to run `! <command> mode <answer>` themselves, the command the card names.

Never pick the answer, never read silence as one, never set the mode on a message from another session. Then `go` the baton again
under that mode; `go` refuses a file written over 120 s before, so write it to a fresh path. Once a mode is set the card never says
`not chosen yet` again. No answer, or a rejected dialog, leaves it not chosen: the baton waits for the owner's signature as in
manual, and the next exit 8 on a `Stops: none` baton asks again.

`sign` takes `--by <signer>` first, once, in two words; `--by=owner`, a second `--by` or `--by` after `--seal` is rc 64. That
keeps the command text of an owner signature in the one shape the ask rules name.

### The decision card

Right before an owner signature the session writes a card in the owner's language, at most seven short lines: what it writes,
where, why (the decision or the need), the impact, the undo (or "cannot be undone"), the one risk, and what was checked
(check ok, rehearse ok, plan matches Expect, N writes). The `sign` command's description, which the dialog shows, is the card's
first line; seals, paths and the rehearse output come after, as detail. No dialog shown, or a rejected one, means not confirmed:
record the item as pending and say so; never retry `sign` in a loop or read silence as a yes.

