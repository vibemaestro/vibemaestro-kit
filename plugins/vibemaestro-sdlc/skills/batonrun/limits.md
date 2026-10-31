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

**Never another route.** An act that check refused, or that waits for the owner (exit 8), is never done by another
route: another command, a direct file or ref edit (the remote's own directory, `packed-refs`), a second script, a
different tool. A check that passes is not a yes either: `Stops:` declares what the act does, whatever the lint finds (a
`Stops: none` baton the lint does not flag can still delete). No pattern sees every route, and the rule's reminder
names only some bare ref deletes (`push --delete|:<ref>`, `update-ref -d|--stdin` or a zero value,
`branch -D`, `tag -d`) once per session; the session reports the refusal and waits for the owner.

**A settings file is guarded outside a baton.** The plugin's hook `settings-guard.py` denies a plain-tool write that widens a
Claude Code settings file (`settings*.json` in a `.claude` directory or `$CLAUDE_CONFIG_DIR`, any case, through a link too),
in every mode, on the owner's laptop as in a pod, whatever the repository's `hooks` setting says; also the file a settings
link points to. The one way is
`kind:settings-merge`; a change the kind does not make waits for the owner.
- Edit, Write, MultiEdit, judged on the exact after-state. Denied: an allow rule or additional directory added, an ask or deny
  rule removed, `defaultMode` moved up (`plan` < `dontAsk` < `default` < `acceptEdits` < `auto` < `bypassPermissions`, unknown
  is the top), `disableBypassPermissionsMode: "disable"` dropped, another `permissions` key changed, a file that is not a JSON
  object, a top-level key changed other than `$schema`, `model`, `outputStyle`, `attribution`, `includeCoAuthoredBy`,
  `cleanupPeriodDays`, `language`, `alwaysThinkingEnabled`, `spinnerTipsEnabled`, `theme`, an Edit that does not match the
  file exactly (Claude Code matches more loosely). Passes: the narrowings.
- NotebookEdit on a settings file: denied.
- Bash, by text, every write found onto a settings name, a narrowing included: `>`, `tee`, `sponge`, `cp|install|rsync` onto
  it, `cp|mv|ln|install|rsync` of a settings-named file into `.claude/` (`-t` too), `mv`, `ln`, `rm`, `truncate`, `dd of=`, `patch`, in-place `sed|perl|awk|yq`, an editor,
  `git checkout|restore|rm|mv|stash`, `curl -o`, `wget -O`, `find -delete|-exec <writer>`, `xargs <writer>`, inline
  interpreter code that names it and writes. Words split as the shell splits them (a quoted sentence is one word); the
  first word is the command, and after a runner (`sudo`, `timeout`, `env`, `xargs`, `find -exec` …) any later writer word;
  `bash -c`, `eval`, `su -c`, `$(…)`, backticks, a heredoc fed to a shell and a string literal in inline code are read again, any other heredoc body is data;
  only a file whose own directory is `.claude` counts (not a `.claude/worktrees/…` checkout). Reads pass; so do `go kind:settings-merge` and `kit:coordinator-bootstrap`
  (their writes run inside the baton process).
- Not seen: a name built at run time (a variable, `$(…)`, glue, a glob without `settings`), a script file run, a baton the
  session wrote (`check` has no settings pattern), `git apply|am`, an archive, a checkout or merge that does not name the
  file, a directory copied whole, a write through a link made earlier, an MCP tool, a write on another host (`ssh`),
  `~/.claude.json`. A Bash text that names a settings file and cannot be read (an error) is denied. Also denied though
  harmless: a `python -c` that reads the settings and writes elsewhere; a `.claude/settings*.json` backup, example or fixture;
  a writer word after a runner that is only an argument (`sudo grep rm .claude/settings.json`).

**The ask rules show the dialog; the records guard.** The permission block's ask rules start with a real program word
(`permissions.md`), so a command that only mentions a sign or a mode call asks nothing, and a wrapped call (`env`, `bash -c`, a
script) matches no ask rule. Such a call still gets no record of the owner's dialog, so `sign --by owner` and a mode change refuse
it (rc 3): the rules decide when a dialog shows, never whether the call runs. An older copy of `baton.py` checks no record,
but the mode and remote list it writes carry no `dialog <id>` line, so this version reads them as not chosen (`modes.md`).

**A sandbox cannot get the owner's signature.** In a pod `sign --by owner` is refused, so a stop-list flow never runs there:
`go` it to the card, `pack` it as `project:`, open the PR and hand the call to the coordinator (`kits.md`). There, exit 8
prints that call to hand over, not a sign line: no sign, `run` or `go --queue` is a next step in a pod; `rehearse` there
prints no sign line either, only that `go` hands the call over. A `Stops: none` script held by the pod's mode manual is
handed over the same way, marked as never run.

**"Reviewed" trusts the local view of origin.** A `project:` baton runs without a keep record when its bytes are the blob at its
path on `refs/remotes/origin/HEAD` and origin's fetch URL is on the owner's list (`kits.md`). The ref is local: moving it by hand
(`git update-ref`, a fetch from a URL other than the one checked) is forgery, as editing the state directory is.

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

**The owner's dialog** (`modes.md`) proves that Claude Code showed a dialog for that very `sign --by owner` call in a mode where a
human answers. It does not cover: a session that writes the record or the signature file with a shell command, or runs an older `baton.py`
for both `sign` and `run` (the deny `Edit` rule on the state directory covers the write tools only); something that answers the
dialog that no settings file or process shows (an SDK host's permission callback, a mod); a human who clicks without reading;
another call the same Claude Code process starts after the ask and before the session's next Bash call or the record's expiry,
a rejected dialog included (one in the same response as the asked one, or a tool that runs a shell outside the Bash tool, which
no Bash hook sees); on a system
without `/proc`, a process started within the same second as the ask; a wrong version read for `auto` (the `(Claude Code)`
line of `$CLAUDE_CODE_EXECPATH --version`, else of `claude --version`; unknown counts as too old). Where no Claude Code process
can be found above the hook (no `CLAUDE_PID`, an unrecognised program name), the hook denies, so the owner cannot sign there;
nor can a baton whose arguments, script path or launcher path need quoting (a space in the home or state directory), or one
signed through a `baton.py` other than the installed plugin's. Same-user changes the guard does not see: a file or link on the
checked path swapped between the hook and the run, the launcher's content, `python3` found through `PATH`, `PYTHON*` variables.

**Values in tools that are not shells.** A `Params` value is checked against its type and reaches the script as one argv
word: it cannot end a shell word or start an option there. The tool it is handed to may still read it as code or as a
file. `check` refuses a `P_` name in `eval`, `trap`, `bash -c`, a heredoc body, as a command name, and after `gh -F|--field`
or `curl -d|--data…|--json|-F` (both read `@<file>`). It does not see the other sinks; use the safe form:
- `jq`: `--arg k "$P_X"`, never the value inside the filter text;
- `gh api`: `-f key="$P_X"` (a string), not `-F`;
- `--` before operands (`rm -- "$P_X"`, `git … -- "$P_X"`), even though a value cannot start with `-`;
- a segment of a value (a middle one may start with `-`): `check` refuses `basename` of a value or its copy unless the
  result reads `./<name>` or follows the reading command's `--`, and a prefix trim, substring or replacement of a copy;
- `sed`, `awk`, `find -name`, `grep -e` and other program or pattern text: no value inside it; compare in the shell, or pass
  it as data (`awk -v` reads escapes: avoid it too).
Free text from outside (a title, a message, a body) never goes on the command line: it is an `input` file the session writes,
and the script reads the file.
A secret (a private key, a token, a cluster credential) is a `path` value, under a key that names no secret (`key_file`,
not `token`): the script feeds it to a command's stdin and never prints it. A `file` or `input` value is copied under the state directory and kept, so one whose bytes look like key
material (a private-key header, a `client-key-data` field, a token of a known shape, not a placeholder such as `ghp_XXXX…`)
is refused (exit 64) before any copy, naming the kind, never the bytes. That screen is a backstop, not the rule: a binary or re-encoded key passes it.

**A flow split into simple writes.** A simple write (one step, undone by one direct call, neither on the stop list, not a flow
met before) is done directly. Nothing can tell a flow cut into such writes from honest single writes, so the cut is not made:
a flow of several writes is one run.

## The stop patterns

The patterns `check` flags: a backstop, not a proof (an `echo` of the words counts; a stop act may match none). Declare what
the act does, not what the lint finds.

<!-- stop-patterns -->
- `irreversible-delete`: `gh repo|release delete`; `kubectl … delete ns|pvc|pv`; `git push --delete|-d|:<ref>`; `gh api -X DELETE`; `git push --mirror`; `git update-ref -d|--delete`; `git update-ref <ref> 0{40}`; `update-ref --stdin: delete <ref>|update <ref> 0{40}|<heredoc or file>`; `git branch -D|-d -f|--delete --force`; `git -C|--git-dir|--work-tree|GIT_DIR=<dir> branch -d|-f|-M|-C|--delete|--force`; `git tag -d|--delete`; `rm|unlink|mv|truncate|shred|find -delete|-exec rm|> … refs/`; `packed-refs written: >|tee|sed -i|perl -i|dd of=|rm|mv|truncate|cp onto`
- `secrets`: `gh secret`; `kubectl … secret`; `vault kv|read|write|delete`
- `security-boundary`: `kind: Role|RoleBinding|ClusterRole…|NetworkPolicy|ValidatingAdmissionPolicy`; `gh pr merge --admin`; `private=false|visibility=public`; `--visibility public`; `settings*.json under .claude|$CLAUDE_CONFIG_DIR written: >|tee|rm|mv|ln|cp|install|rsync|sd|dd|curl|wget -o|sed|perl|ruby|yq|awk -i|git checkout|code|a write() or interpreter argument`; `settings*.json or its .claude|$CLAUDE_CONFIG_DIR directory held in a name: X=|x = |${X:=}|for x in`
- `cluster-lane`: `flux suspend`; `kubectl … drain|cordon`
- `history-rewrite`: `git push --force|-f|+<ref>`; `git filter-branch|filter-repo`; `git push --mirror`
- `money-org`: `gh repo create|rename|transfer|archive`; `gh api /orgs/<org>/members|memberships|teams|billing|settings`
- `publish`: `--visibility public`; `npm publish`; `gh gist create --public|-p`; `private=false|visibility=public`
<!-- /stop-patterns -->

A ref deletion is flagged in any repository, the session's own clone too (`branch -D`, `tag -d`, `update-ref -d`): the stop
list counts a branch and a tag as gone for good wherever they live, since check cannot prove a branch merged. The lint
leaves a merged-only `git branch -d` in the session's own clone unflagged (git refuses it on an unmerged branch), but the
act is still declared; it flags `-d`, and a forced `branch -f|-M|-C`, when pointed at another repository (`-C <dir>` counts,
even the session's own worktree). Also flagged though harmless: an `update-ref --stdin` fed by a heredoc, a file or `cat`
(the lint cannot read the lines), an argument word `cat` (or ending in `/cat`) right before that pipe, a directory named
`refs` removed. Not seen: a ref of another repository moved backward with `update-ref` (`git -C <dir> update-ref <ref>
<older sha>`, which reads like a ref moved in the session's own clone), a zero value or a `delete` behind a variable
(`printf 'update %s %s' "$REF" "$ZERO" | …`), a `cat` or `<` that ends before a `;` in a group piped into `update-ref
--stdin` (`{ cat ops; } | …`), `cd <dir>/refs` then a relative `rm`, `xargs rm`, a disguised `git` or `cat` (quoted, glued
to `''` or `$IFS`, behind a variable).

A Claude Code settings file (`settings*.json` or `managed-settings.json` right under `.claude`, `$CLAUDE_CONFIG_DIR`, the
managed directory or a variable whose name holds `claude` other than `CLAUDE_PLUGIN_*` and `CLAUDE_PROJECT_DIR`, also as path
parts in code) is the settings guard's ground, and a baton's writes run where no hook sees them. A write onto it is
`security-boundary`: the guard's shapes (`tee|sponge|truncate|rm|unlink|shred|mv|ln|patch|sd`, a copy onto it or into
`.claude`, a directory copied whole into `.claude` by `cp` or `rsync`, `dd of=`, `curl -o`, `wget -O`, an in-place
`sed|perl|ruby|yq|awk`, code that names it and writes), the path as an argument of `write` or of an interpreter whose
program is a heredoc, and the path held in a name (a later write through `"$S"` is not seen, so the name counts as one).
Also flagged though harmless: a backup or link made from it through `write`, a heredoc program that only reads it, an
option with an `i` read as in-place (`perl -Ilib`, `ruby -ruri`), a read through such a name, a `for` loop over it, a
comparison with the path, a message or comment that quotes a write onto it. A baton that only reads declares it all the
same, or names the path written out in the reading command (`OUT=$(jq . "$HOME/.claude/settings.json")`). The path as
an argument of the baton or a Param is not in the text: `go`, `rehearse`, `sign` and `run` read the bound value, and one that
names a settings file or such a directory itself, or another name of one (a hard link, a settings link's target unless a device or a directory), makes the call `security-boundary` whatever `Stops:` says, exit 8 or a
refusal naming the argument (`~`, `$VAR`, `..`, a relative path, links and globs resolved, the part after an `=` read too;
a value is read as one path, never searched for one among other words, and a subdirectory of `.claude` is not one; a
regular file with other hard links baton cannot place counts too, since its other name may be a settings file). Not seen: a directory held in a name that does not
hold `claude` (`CFG="$HOME/.claude"`, then `"$CFG/settings.json"`), a `${…:-…}` default of a name that does not hold
`claude`, a path in code joined with no space after `=` (`p=home/".claude"/…`) or behind `or`, a path built from pieces or
read from a file, a quote nested in `$(…)`, a command with more than 600 characters before the path (300 inside one word),
`cd .claude` then a bare `settings.json`, `git -C ~/.claude checkout`, `cp -t <dir>`, `tar` or `unzip` into it, an editor.
