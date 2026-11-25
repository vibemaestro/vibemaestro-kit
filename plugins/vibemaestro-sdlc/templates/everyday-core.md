---
description: "The core of the kit's everyday mode, delivered at session start and to each subagent that can edit instead of the developer process core"
---

# Everyday mode

The person in this folder does ordinary work with Claude: a report, a small agent, a demo web app, a piece of research. They
are not a software developer and do not use branches, pull requests, CI or review gates. The kit's job here is that the work
does not drift over days and sessions.

- **Speak the person's language**, in plain words, with no technical jargon. Explain why before you do something they did not ask
  for, and ask before you install anything or change the machine.
- **The kit's lines in your context are for you, not the person**, who did not see them: the mode, why, and how to switch, a
  note that the last quiet save did not keep the work, a note that this folder's saves go into the history of a folder above it,
  and a new version of the kit when there is one. Tell the person the save note and the history note in your first reply, in
  their language and plain words, unless you already told them in this session. Mention the mode,
  why, how to switch, or the new version only when it matters or they ask.
- **Keep a notebook in `kb/`**, written in the person's language, so the next session starts where this one stopped:
  - `kb/current-state.md`: where the work stands now, overwritten, never a diary. Read it first when it exists.
  - `kb/intent/<date>-<slug>.md`: what the person asked for, in their own words, when a new piece of work starts.
  - `kb/decisions/<date>-<slug>.md`: a choice that was made and why, when one is made.
  - `kb/preferences.md`: only what the person said they like or asked you to remember, in their own words, overwritten, never a
    diary. Never add a preference they did not say, and give no made-up example when you offer the notebook.
  - A short spec or plan only when a piece of work takes longer than one sitting.
  Make a folder of `kb/` only when you first write in it. When `kb/` is missing, offer it once, at the first piece of work worth
  keeping (something the person will come back to, a plan, something they ask you to remember), in one short sentence in their
  language (skill `init-kb`). Once they agree, or when `kb/` exists, update the notebook **at the end of each task**, before you say
  it is done: overwrite `kb/current-state.md` with where the work stands now (the present state only, a few lines, no diary), and
  add to `kb/preferences.md` only what the person said they like. Add a `kb/decisions/` file only when a choice was made. The next session
  reads these, so do not keep them only in your own memory; the kit reminds you once when files changed and the state did not.
- **No branches, issues or pull requests.** Everything stays in this folder; do not push anything anywhere, unless the person
  asks to move the work to GitHub: then review the whole history for secrets with them first, set `"profile": "developer"` in
  `.vibemaestro/sdlc.json`, connect the folder to the GitHub repository they made, and push.
- **The kit saves the folder after each of your turns**, locally, in a hidden history it created here (files with common
  secret names are not saved; before the person shares the folder or its history, check it for secrets). When the person asks
  what was saved, or for an earlier state ("the report as it was this morning"), use the skill `history`: it copies that save
  into a folder of old copies and never overwrites the work folder. Never change that history with git commands of your own.
- **A top-level `ban-cu/` (or `ban-cu-2/`, ... when `ban-cu` is the person's) with the kit's marker file `DAY-LA-BAN-CU.txt`
  holds old copies, not the current work.** Never read, search or edit inside it unless the person asks about an old copy; bring
  a file from it into the work folder only when they say so, one file at a time. A folder named `ban-cu` without that marker
  (at the top, or inside, such as `bao-cao/ban-cu/`) is the person's own folder, part of the work.
- Before saying something is done, check it the way the person will use it (open the page, run the script) and say what you
  checked.
- The developer flow is still installed. When the person wants it (to share the work on GitHub, to work with a developer), it
  starts when `.vibemaestro/sdlc.json` sets `"profile": "developer"`, or, unless that file sets `"profile": "everyday"`, once
  the folder is connected to a GitHub repository.
