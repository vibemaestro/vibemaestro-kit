---
name: coordinator-bootstrap
description: "Use when: a session starts on a new or moved machine, there is no baton launcher yet, or SessionStart says the baton permission check failed. One owner-signed kit run (kit:coordinator-bootstrap) installs the launcher and adds the permission block (with attribution off where a key is absent) to the user settings, after a machine report; then the session post-checks and does the follow-up steps the report's plugins name."
---

# coordinator-bootstrap: set up BatonRun on a machine in one run

The setup is one kit run, `kit:coordinator-bootstrap`. Its rules (check, rehearse, sign, run, post-check, undo, the decision
card, the modes) are BatonRun's: the standard is `docs/batonrun.md` in the plugin root, the operating instructions are the
skill `batonrun`. This file adds only what is particular to the bootstrap.

## What the run does

- **Report.** `CHECK` lines: the sdlc version running and installed, the launcher, the rules in force, the mode,
  attribution, `gh auth status`. Each installed plugin that depends on this one and ships `scripts/bootstrap_report.py` adds
  its own lines: what that plugin needs on this machine, and where its follow-up steps are written.
- **At most two writes.** It installs the launcher, then merges the printed block into the user settings through the kind
  `settings-merge`. The kind adds rules and absent attribution keys, and removes and flips nothing; a missing settings file
  is created as `{}` first.
- **Header.** `Stops: security-boundary`: it adds allow rules, so the owner signs, in every mode.
- **Undo.** It puts each file back byte for byte while it is what the run left.
- **Refusals.** It refuses at rehearse (the run's own exit 3) when there is nothing to do, or when adding rules cannot reach
  `permissions --check` rc 0 (an unsafe rule the owner must remove by hand; the refusal names it). The old broad ask rules
  (from before the anchored block) are set aside: it never removes a rule, and `kit:permissions-upgrade` swaps them after it.

## Steps

1. Rehearse with the plugin's baton.py (there is no launcher to call yet):

       python3 "${CLAUDE_PLUGIN_ROOT}/scripts/baton.py" rehearse kit:coordinator-bootstrap

   `REFUSE nothing to do here: … kit:permissions-upgrade swaps`: only the old broad ask rules are left; run
   `kit:permissions-upgrade` the same way (skill `batonrun`: card, the owner's sign, run), then step 4. Any other
   `REFUSE nothing to do` with `the rehearse phase exited 3`: the machine is set up. Skip to step 4. Any other REFUSE: tell
   the owner what it names and stop.
2. Write the decision card (skill `batonrun`). Then run the `sign --by owner …` command that rehearse printed, once, alone in
   its Bash call: the plugin's hook opens the dialog even before this run installs the ask rule, and the owner's click is the
   signature. A refusal or a rejected dialog: tell the owner and stop. A `!` line has no dialog record and is refused.
3. After the owner signed, the session runs `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/baton.py" run kit:coordinator-bootstrap`.
   If Claude Code's Self-Modification guard denies it (it writes the user settings), hand that same command as one `!` line.
   `run: ok` means the run's own post-check held.
4. The session's post-check, no writes:
   - `<launcher> permissions --check` must be rc 0. The launcher is `$XDG_STATE_HOME/vibemaestro/baton/bin/baton`, else
     `~/.local/state/vibemaestro/baton/bin/baton`. When rc 7 names only old broad ask rules (`kit:permissions-upgrade
     replaces it`), run that kit as in step 1, then check again.
   - Then the follow-up steps a dependent plugin's report lines point to, as that plugin's own text says.
5. Hand over what the report shows missing, each as its own short `!` line, never two commands joined. A wrapped paste of
   two joined commands breaks.
   - `! gh auth login`
   - a login or a file a dependent plugin's line names, as that plugin's text says
   - Claude Code's own install of a plugin the machine lacks (`! claude plugin install <plugin>@vibemaestro`, or `/plugin`):
     the Self-Modification guard denies a session that. An update of the plugins the `vibemaestro` marketplace already has
     installed is no `!` line: the session runs `<launcher> go kit:plugin-update <full kit sha>`, a `Stops: none` run.

The mode stays `manual` on a new machine. `auto` is the owner's word only: neither the run nor this skill runs `mode`.
