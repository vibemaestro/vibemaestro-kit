# batonrun reference: writing the act

Read this when the act runs a remote program (`ssh`, `kubectl exec`), when undo must restore something the act moves, when a
plugin script runs inside the baton, or when `go` refused a file as stale. The rules every baton needs are in the core
(`SKILL.md`, step 3); this file holds the rest. Also printed by `<launcher> help act`.

## The script

Fill the header (Purpose, Targets, Blast, Undo, Pre, Stops, one Expect per write, a glob matched in order) and the act: every change through
`write "<plan line>" <command…>`, every read outside it. Reads run in every phase, so rehearse exercises them: GET reads for
`gh`, a local build before a push, the before-state of a config. Put resolved values (full SHA, tag, absolute path, the target
repository or host) in the plan lines: the plan is signed. The script is self-contained: no `source`, no local helper script;
a file it reads goes into a plan line with its sha256. `new <name> [--from <kind>] --dir <dir>` writes the template or a kind
to a file instead, when you would rather edit one.

## A stale file

`go` runs a session baton only from a file written in the last 120 s (the age of the bytes it read, through a link too); the
same holds for the `--spec` file of `kit:gh-write` and the rules file of `kind:settings-merge` (not for `install-file`'s
source, often an existing file). A Write that did not land (refused, denied, a path it could not write) leaves the older bytes
there, and `go` ends rc 1 with nothing run: it prints the file's sha256 and Purpose and the exact `go --reuse …` command. Write
a fresh path. Run the `--reuse` command only after reading that sha256 and Purpose, when you mean those very bytes (a re-run, a
`--recover`). What `go` cannot tell: whether a file written in the last 120 s holds what you meant (an Edit that did not
apply, or a second `go` on the same path, runs the older bytes: write a fixed baton whole to a new path), and anything about a
file the script reads itself. Only `go` looks at the age: the separate commands do not.

## A baton is a file, not stdin

Write the baton to a fresh path and `go <path> <args>` in the same response. `go -` (the script on stdin, stored once under
`<state-dir>/stdin/`, run as that file) exists, but it is not how a session sends a baton: the only way to feed it is a heredoc on
the command, and Claude Code blocks a heredoc that holds the skeleton. Measured, not assumed: `limits.md`. Do not rewrite the skeleton
to get past that check.

The signature binds the script bytes, its arguments, the directory, the variables that steer the tools and the plan. A rerun
needs a new signature (one signature, one run). An edit, other arguments, another directory, or a world that changed
the plan since signing: `run` refuses with rc 3 and nothing runs. Run `go` again. A failed post-check is read again after 1, 2,
4 and 8 s.

Read the output whole; each run's full output is under `runs/` anyway. Both the launcher and the `python3 … baton.py` form
run in bash and fish alike. The separate commands remain (`check`, `rehearse`, `sign`, `run`, `log --tail 5`); `run`, like
`go`, prints one line when it holds (`run: ok — <n> writes — <run log>`) and everything otherwise. On any
exit but 0, `go` prints the failing step's whole output, then `go: stopped at <step> (exit N): <reason>`; on exit 8 it prints
the facts for the decision card, the path of the check and rehearse output, and the two commands to run on the owner's go.

## A plugin script inside a baton

A plugin script may run inside a baton, only as the command of a write, exactly
`write "… sha256 <hex> …" bash "$BATON_PLUGIN_ROOT/scripts/<file>.sh" <args>` (or `python3 -I -B` for a `.py`), the file's
sha256 (`sha256sum`, read before) written in that plan line; the name appears nowhere else in the script. The runner sets
the variable to the plugin root it runs from, in the run and undo phases only; the signature binds that root, every file
under its `scripts/` (a `scripts/` changed during a phase is detected after it, rc 70, not prevented) and, for every baton,
the `PYTHON*` variables (set them alike at sign and run). So `open-pr.sh` or `intent-branch.sh` runs inside a baton instead
of a bare `gh`; `baton.py` is not one. These are lints over the text: an indirection that hides a run is forgery.

## Remote programs (`ssh`, `kubectl exec`)

- Send the program and its data through stdin into `bash -s`, as a quoted heredoc inside the script (`ssh <host> bash -s
  <<'EOF'`, `kubectl exec -i <pod> -- bash -s <<'EOF'`), so the signature covers it. Computed values go first on the same stdin,
  read by the remote bash, not by its login shell: `{ printf 'V=%q\n' "$v"; cat <<'EOF' … EOF } | ssh <host> bash -s`.
  Arguments through `su -c` broke, and the remote login shell may be fish.
- Print a remote read first, decide later: `OUT=$(remote … 2>&1 || true)`, print `$OUT`, then test it. A bare `CHK=$(remote …)`
  under `set -e` ends the phase when the remote exits non-zero and loses what it printed. A read-only remote program ends
  with `true`, so a last `grep` with no match does not fail the phase.

## Undo and plan lines

- Undo compares every target with its before-state (a release's revision and status, a template, each object the act made),
  or the header `Undo:` names what it leaves. An undo that read only the headline state ("unsealed") reported the state back
  while a Helm release sat at `failed`, half applied.
- A plan line carries identities and inputs read before the act (uid, sha, revision), never a value the act itself moves:
  the DO line would differ from the signed plan and the run would stop half-way.
- A write waits for its own slow signal. When the after-state shows later than the post-check's retries (1, 2, 4, 8 s), the
  write itself reads until it appears (a log line, a status), with a time limit, so the post-check is not a race.
- When undo cannot recompute a name from a read (a backup named after a sha the act changes), the run writes a record through
  `write()` (a file in the state directory, its path in the plan line), and undo restores only while the target still matches
  it (else exit 5). Without one, an undo reported ok and restored nothing (a settings backup named after the settings sha).
  A record outlives a run that held, so it names its run: the sha256 of the signed plan, the file `BATON_PLAN` that baton
  hands the run and its undo; undo acts only on its own run's record (the kinds `settings-merge` and `ci-rerun-failed` do).

## A GitHub object that may not exist

`gh api <path>` on a missing object exits 1 and still prints the 404 reply's JSON body on stdout, so "it printed something"
is not "it exists": a baton that takes that body for an existing object is refused at rehearse.
The skeleton's `gh_state` reads the status line of `gh api --include` together with the exit code: `exists` on exit 0 with
`HTTP/… 200`, `absent` on a non-zero exit with `HTTP/… 404`, and it stops the script (exit 75) on anything else, such as a
500, a redirect, a network error, or output without a status line. Call it as a statement and then test `GH_STATE`: inside
`$(…)`, backticks, a pipe, a subshell or the background (`&`) its answer and its `exit` stay in the subshell, and an earlier
call's `GH_STATE` would decide. `check` refuses those forms, also a `{ … }`, `if`, loop or `case` block holding the call
that is piped or sent to the background as a whole. It reads text, so these are not seen: a `$(` opened on an earlier line, a
heredoc body, `coproc`, a `case` inside `$( … )`, and a function that wraps `gh_state` and is then called in one of those forms.

Two answers are right about the path and wrong about the object, so pick the path that names exactly one object:
- `repos/<o>/<r>/git/refs/heads/<name>` (plural) answers 200 with the list of branches that start with `<name>`, even
  when no branch has that exact name; read `repos/<o>/<r>/git/ref/heads/<name>` (singular) instead.
- A token that cannot see a private repository gets 404 for everything in it, so "absent" there means "not visible":
  read the repository itself first when the token may lack access.
URL-encode a name in the path (`jq -rn --arg v "$name" '$v|@uri'`): an unencoded `#`, `?` or space reads another path.
