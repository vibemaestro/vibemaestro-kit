---
name: history
description: "Use when: in the kit's everyday mode the person asks what was saved or wants an earlier state of their work, in any words: \"what versions do I have\", \"I want the report as it was this morning\", \"I lost a file\", \"undo what you did to the report\". Lists the quiet saves the kit made after each turn and writes the chosen one as a copy into ban-cu/ inside the folder; it never overwrites the work folder. The person takes the files they need; a copy is removed only on their word. Never change the saves with git commands of your own."
---

# history — the quiet saves of an everyday folder

In everyday mode the kit saves the person's folder after each turn, locally, in a hidden git history it created in that folder
(never one that was there before, never pushed anywhere; files with common secret names, such as keys, `.env` files and
credentials, are not saved). This skill is how the person sees those saves and gets an earlier state back: the chosen save is
written as a copy into `ban-cu/` inside the folder, and the work folder itself is never overwritten. Speak the person's language,
in plain words: say "save", "old copy" and "take a file back", not commit, branch or restore.

## List the saves

```bash
/bin/sh "${CLAUDE_PLUGIN_ROOT}/scripts/pyrun.sh" "scripts/quiet_save.py" list --dir "<the person's folder>"
```

Each line is one save, newest first: its number, its time to the second, the files that changed (added, changed, removed), and
its id in brackets. `list 50` shows more. Run it from the folder or any folder inside it. "this folder has no saves yet" means
the kit has not saved here (a new folder, or a folder whose history belongs to the person or to the developer flow): say so.

Tell the person the saves that matter for what they asked, in their words: "This morning at 10:02 the report had the summary
table; at 11:40 the table was removed."

## Make a copy of a save

Name the save by its id (in brackets on its line), never by its number: a save that lands in between shifts the numbers.

```bash
/bin/sh "${CLAUDE_PLUGIN_ROOT}/scripts/pyrun.sh" "scripts/quiet_save.py" copy <id> --dir "<the person's folder>"
```

It writes every saved file of that save into a new folder `ban-cu/<time of the save>/` and names it in its answer; when the name
`ban-cu` is the person's, it uses `ban-cu-2/` (and so on) and its answer says why, in one line. Nothing in the work folder changes
(only `.ignore` gains a line naming the folder used, so Claude Code's search skips the old copies), and the hidden history is not
touched. Tell the person where the copy is, so they can open it in VS Code's file list.

## Take a file back

The person picks what they need from the copy. Copy a file from the copy's folder into the work folder only when they say so,
one file at a time, naming the file and what it replaces; the next quiet save keeps the change. Never take a whole folder back
in one go, and never take anything back on your own.

## The old copies are not the current work

The kit's folder of old copies (`ban-cu/`, or `ban-cu-2/` and so on) holds only old copies: its marker file `DAY-LA-BAN-CU.txt`
says so, and the kit's copies are not saved. Never read, search or edit inside it unless the person asks about an old copy, and
never take its content for the current work. A folder named `ban-cu` without that marker (at the top, or inside, such as
`bao-cao/ban-cu/`) is the person's own: it is saved like any other, and the kit never writes into it or removes it.

## Remove a copy

When the person has taken what they need, offer once to remove that copy. Remove it only when they say yes:

```bash
/bin/sh "${CLAUDE_PLUGIN_ROOT}/scripts/pyrun.sh" "scripts/quiet_save.py" drop-copy <folder/copy, as copy's answer named it> --dir "<the person's folder>"
```

For example `drop-copy ban-cu/2026-11-14-100200`. It removes only a copy the kit made (the kit keeps a list of them in the hidden history); anything
else is refused. Never remove a copy, or anything in a folder of old copies, with your own commands.

## Answers

"Nothing changed: ..." means nothing was written; say why in plain words. Files whose names look like secrets were never saved, so
no copy holds them; say so when the person asks about such a file. Nothing printed at all means Python is missing on this
machine: the session-start line says what to install.

## Known limits

- A `.gitignore` of the person's own that re-includes a secret name (`!.env`) wins over the save's list: that file is saved.
- On Linux secret names are matched with their exact letter case: `.ENV` or `ID_RSA` is saved.
- Only the English Desktop, Documents and Downloads folders are never turned into a history; their names in another language are not.
- A first save stopped in the instant between creating the history and marking it leaves an unmarked history: that folder is then
  in developer mode, and this skill says it has its own Git history.
