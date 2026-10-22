---
name: batonrun
description: "Use when: an action writes outside the session (a GitHub write: a merge, an API POST, a registry push, the user's Claude Code plugin config, a force-push, a deletion, a change on a live system), or when the owner asks to package commands into one script that runs as a block. BatonRun: one run of one baton script; the owner is never handed command lines to type."
---

# batonrun: privileged actions as runs

A write outside the session is one **run**, a fixed series in one baton script the session runs; never typed
command by command, never handed to the owner as lines to type. A hand-written baton needs only this file: no
reference, no `baton.py`. Standard: `docs/batonrun.md` in the plugin root.

## Steps

Each command is `<launcher> <subcommand> …` (`<state-dir>/bin/baton`; until installed `python3
${CLAUDE_PLUGIN_ROOT}/scripts/baton.py`); baton's options before the script path, its arguments after. Run each bare, as its
own call: no `cd <dir> &&` (set the directory in an earlier call), no pipe, `| tail` or `| grep` after `sign`, `run` or `go`:
no permission rule matches a compound command. `go` and `run` print one line when they hold;
read any other output whole.

1. **A kind or a kit covers it: no script.** `go kind:install-file <source> <dir>`, `kind:settings-merge <settings.json>
   <rules.json>`, `kind:ci-rerun-failed <owner/name> <run id>`. `go kit:gh-write --spec <file>` covers issue-create,
   issue-comment, comment-edit, issue-edit, pr-body-edit, issue-reopen, issue-close, pr-close, pr-ready, pr-create,
   file-pr; never by hand. Merge: `kit:merge-pr`. Labels, tags, releases, a push: hand-written.
2. **Otherwise** Write the baton (from the skeleton) to a fresh path and `go <that path> <args>` in the same response.
   Never the baton in a heredoc on `go -`: Claude Code blocks it (`limits.md`). Independent batons of one task go in the same response.
3. **The act:**
   - every change through `write "<plan line>" <command…>`; reads outside it run in every phase, rehearse too;
   - resolved values in plan lines (full SHA, tag, absolute path, target repo or host), never a value the act moves;
   - one `Expect` line per write (below);
   - self-contained: no `source`, no local helper script; a file it reads goes into a plan line with its sha256;
   - undo compares every target with its before-state, or `Undo:` names what it leaves; an undo that cannot delete names
     what it leaves behind and exits non-zero; a late after-state: the write waits for it.
4. **`go`** runs check, rehearse (plan against Expect), seal, sign as `coordinator-auto`, run, post-check and log. A file
   written over 120 s ago is rc 1, nothing ran: write a fresh path (a kept run, or a baton written twice: `kits.md`). One signature, one run: `go` again.

**Owner-only acts** (`modes.md`): `mode manual|auto` changes only on the owner's word; `sign --by owner` is the owner's click
in a dialog, after a decision card; no dialog, or a rejected one, is not a yes: record it as pending, never retry `sign`.

### How Expect matches the plan

<!-- expect-match -->
Rehearse collects one plan line per `write()` call, in the order they ran, and compares the i-th with the i-th `Expect`
line as a shell glob over the whole line, case-sensitive: `*` is any run of characters (spaces and `/` too), `?` one
character, `[…]` a set. It is not a prefix match. The counts must be equal: a missing or an extra line is a FAIL row with
`(none)`. Each row prints `ok` or `FAIL <plan>  ~  <Expect>`, and `go` ends `go: stopped at plan-vs-Expect (exit 1)`.
- plan `create docs/a b.txt`, Expect `create *` → ok
- plan `create docs/a.txt`, Expect `create` → FAIL

Four writes, four `Expect` lines (`*` is a SHA):
```
# Expect: label create docs
# Expect: milestone create v2
# Expect: ref create refs/tags/v2 *
# Expect: release create v2
```
<!-- /expect-match -->

### Exit codes

- 0: `go: ok — <n> writes — <run log>` (`run` alike), the only line; report it.
- 1: fails check or rehearse, or a stale file: write the fixed baton whole to a new path (a kept run: `kits.md`); a widening fix needs the owner.
- 3: refused, nothing ran. 4: failed, undone. 5: the state is unknown: tell the owner at once.
- 8: owner signs (Stops; mode `manual`, `not chosen yet`: ask once); none ran: `modes.md`.
- 9: `log --wait-names` not met. 64: bad usage. 66: the script cannot be read.

### Several batons

In place by default, any number. Delegate 3 or more batons only when the main context is over ~400k tokens.
Then ONE worker subagent (model `agents.worker_model`), one Agent call with the whole job and the exact script names
`<prefix>-<act>.sh`, a prefix of its own; a worker never delegates. Then ONE call `<launcher> log --wait-names
<prefix>-a.sh,… --timeout 580`: rc 0 once each name's latest run line since the wait's start − 300 s is ok (a fixed re-run
counts), else rc 9 at the deadline. Once the wait passed, the worker's later hand-back needs no tool call: end the turn.

### The skeleton

It passes `check` as written. Replace the header, act, post-check and undo; copy `write()`, `gh_state()` and the final `case`
unchanged. Does a GitHub object exist: `gh_state <api path>` as a statement, then test `$GH_STATE` (`exists` or `absent`;
anything else stops the script).

<!-- baton-skeleton -->
```bash
#!/usr/bin/env bash
# Purpose: create one file holding a text
# Targets: the file named by the first argument
# Blast: that one file
# Undo: removes the file while it holds that text
# Pre: the file is absent
# Stops: none
# Expect: create *
set -euo pipefail
PHASE=${BATON_PHASE:-rehearse}
write() {
  local plan=$1
  shift
  case "$PHASE" in
    rehearse)
      printf 'PLAN %s\n' "$plan"
      printf '%s\n' "$plan" >> "${BATON_WRITES:-/dev/null}"
      ;;
    run | undo)
      printf 'DO %s\n' "$plan"
      printf '%s\n' "$plan" >> "${BATON_WRITES:-/dev/null}"
      "$@"
      ;;
    *)
      printf 'write called in phase %s: %s\n' "$PHASE" "$plan" >&2
      return 70
      ;;
  esac
}
gh_state() {
  local out rc=0 proto code
  out=$(gh api --include "$1") || rc=$?
  read -r proto code _ <<< "${out%%$'\n'*}"
  case "$rc $proto ${code%$'\r'}" in
    "0 HTTP/"*" 200") GH_STATE=exists ;;
    [1-9]*" HTTP/"*" 404") GH_STATE=absent ;;
    *)
      echo "gh_state $1: exit $rc: $proto $code" >&2
      exit 75
      ;;
  esac
}
DEST=$1
TEXT=$2
holds() { [ -f "$DEST" ] && cmp -s "$DEST" <(printf '%s\n' "$TEXT"); }
put() { printf '%s\n' "$TEXT" > "$DEST"; }
act() {
  if [ -e "$DEST" ]; then
    echo "REFUSE $DEST exists" >&2
    return 3
  fi
  write "create $DEST" put
}
postcheck() { holds; }
undo() {
  if holds; then
    write "remove $DEST" rm -f -- "$DEST"
  fi
  ! holds
}
case "$PHASE" in
  rehearse)
    act
    echo "VERDICT rehearse ok"
    ;;
  run)
    act
    echo "VERDICT run ok"
    ;;
  postcheck)
    postcheck
    echo "VERDICT postcheck ok"
    ;;
  undo)
    undo
    echo "VERDICT undo ok"
    ;;
  *)
    echo "unknown phase: $PHASE" >&2
    exit 64
    ;;
esac
```
<!-- /baton-skeleton -->

### What `check` refuses

- A header without Purpose, Targets, Blast, Undo, Pre or Stops, a field given twice, no or an empty Expect, a Stops word
  off the list below, `Each` outside a kit baton. No `set -euo pipefail` in force (a later `set +e`, `+u`, `+o pipefail`).
- `write()` and `PHASE=${BATON_PHASE:-rehearse}` not exactly once, as the skeleton's; `$PHASE` read outside `write()` and
  the final `case`.
- A final `case "$PHASE" in` without `rehearse)`, `run)`, `postcheck)` and `undo)`, each printing `VERDICT <phase> ok`;
  `rehearse)` and `run)` that differ; a branch that masks a failure (`||`, `&&`, `if`, `!`); no `postcheck()` or `undo()`.
- A `PLAN` line printed, or a write run (`gh` writes, `gh api` with a write method or fields, `git push`, `docker push`, `kubectl apply`, `helm install|upgrade`,
  `flux`, `claude plugin install`…), outside `write()`, or a function `write()` runs, called without it.
- A local script run (`bash x.sh`, `python3 x.py`) or `source`/`.` of a file (a plugin script: `act.md`).
- `diff`, `grep` or `cmp` in a pipeline: wrap it `{ diff … || true; } | head`.
- A stop pattern of a category Stops lacks (below); `gh_state` in `$(…)`, backticks, a pipe, a subshell or `&`.
- A `bash -n` error; a `shellcheck -S error` finding where installed.

## Stop list (the `Stops:` header; any of them means only the owner signs)

- `irreversible-delete`: deletes data that cannot come back: volumes with data, namespaces, package versions, repositories, unmerged branches, tags, secret paths, databases
- `secrets`: reads, prints, writes or rotates a secret
- `security-boundary`: widens a boundary: RBAC, admission or network policy, making something public, an admin bypass outside an existing owner rule
- `cluster-lane`: changes a live cluster outside an approved lane: suspending reconciliation, draining nodes
- `history-rewrite`: force-pushes or rewrites history on a shared branch
- `money-org`: billing, plans, organisation admin (create or rename a repository, members)
- `publish`: posts outside: public places, other people's repositories
- `no-way-back`: can be neither rehearsed nor undone
- `owner-acts`: an earlier owner decision names the owner as the one who acts

`check` flags a body line that looks like a stop act (patterns: `limits.md`); declare what the act does, not what the lint finds.

## Reference files (`baton help <topic>`)

- `act.md`: a remote program (`ssh`, `kubectl exec`), how undo restores what the act moves, a run record, a plugin script, `gh_state` paths.
- `kinds.md`: running a kind.
- `kits.md`: running a kit (also another plugin's), or a kit's refusal; keeping or changing a run.
- `modes.md`: exit 8, `sign --by owner`, the decision card, the mode.
- `permissions.md`: `permissions --check` fails.
- `setup.md`: no launcher, or SessionStart says the check fails.
- `limits.md`: what baton does not guard; the stop patterns.
