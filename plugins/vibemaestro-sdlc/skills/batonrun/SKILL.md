---
name: batonrun
description: "Use when: writing or editing a baton script, for a write outside the session (GitHub, a registry, the user's plugin config, a deletion, a live system) that is not simple and that no baton list entry fits; keeping one with baton pack; or the owner asks to package commands to run as one block."
---

# batonrun: write, keep and change a baton

A write flow is one **run** of one baton script. A hand-written baton needs only this file.
Standard: the plugin's `docs/batonrun.md`.

## Steps

Each command is `<launcher> <subcommand> …` (`~/.local/state/vibemaestro/baton/bin/baton`; until installed `python3
${CLAUDE_PLUGIN_ROOT}/scripts/baton.py`); baton's options before the script, its values after. Run each bare, as its
own call: no `cd <dir> &&`, no pipe, `| tail` or `| grep` after `sign`, `run` or `go`.

0. **A simple write is direct** (one comment, one ticket): one step, undone by one direct call, neither on the stop list
   (below), not a flow met before. Never split a flow into such writes.
1. **`list <keyword>` first.** One fits (purpose, targets, risk): `go <prefix>:<name> key='value'…`, values single-quoted;
   a kit or kind takes its `Usage`. `go kit:gh-write --spec <file>` covers issue-create, issue-comment, comment-edit,
   issue-edit, pr-body-edit, issue-reopen, issue-close, pr-close, pr-ready, pr-create, file-pr; never by hand (a lone comment or ticket: step 0). Merge:
   `kit:merge-pr`; a merged branch: `kit:branch-delete`. Labels, tags, releases, a push: hand-written.
2. **One is close: evolve it in place**: a fresh copy, changed, `go` it, `pack` it under the same name, never as a copy.
   Other purpose or targets, a new `Stops` word, or a kit or kind: a new name (`new --from <kind>`).
3. **None:** Write the baton (from the skeleton) to a fresh path and `go <that path> <args>` in the same response, args
   `key='value'`. Never the baton in a heredoc on `go -`: Claude Code blocks it (`limits.md`). Independent batons of one
   task go in the same response.
4. **Met a second time: `pack <path> project:<name>`** (the repo's `.vibemaestro/batons/`, reviewed in its PR) or
   **`user:<name>`** (this machine; a sandbox: `kits.md`); it needs an `ok` run of those bytes: write it keepable (`Params`, `Targets` patterns) at once.
   Relay its `owner:` line in your next reply to the owner.
5. **The act:**
   - every change through `write "<plan line>" <command…>`; reads outside it run in every phase, rehearse too;
   - resolved values in plan lines (full SHA, tag, absolute path, target repo or host), never a value the act moves;
   - one `Expect` line per write (below); no `source` or local helper; a file it reads is a `file` value, or its sha256 in a plan line;
   - undo compares every target with its before-state, or `Undo:` names what it leaves; an undo that cannot delete names
     what it leaves behind and exits non-zero; a late after-state: the write waits for it.
6. **`go`** runs check, rehearse (plan vs Expect, Targets), seal, sign, run, post-check, log. A session baton or `input`
   over 120 s old is rc 1: write a fresh path. A kept baton runs only at its pinned bytes.

### Params

`# Params: key=type …`: each key required, once, checked before anything runs. Types: `int`, `sha40`, `sha256`, `name`,
`repo`, `ref`, `path` (absolute), `url` (https), `file`, `input` (written for this call), `under:<dir>`, `enum:<a>|<b>`.
No value holds a space, quote or `$`: free text from outside (a title, a body) goes into an `input` file you Write. A path
whose last segment starts with `-`, `+` or `@` is refused (exit 64); a middle segment may. After
the gates, one line per key, in order: `P_DEST="$1"`; read only as `"$P_DEST"` (other tools: `limits.md`). `Targets`:
patterns before ` — ` (`{dest} {dir}/** {repo}#{issue} — …`). Each plan line names one, and its absolute-path, repo, URL
or `refs/` words all match one (file copies exempt). Targets not patterns: untested, and `pack` refuses them.

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
- 1: fails check or rehearse, or stale: write the fixed baton to a new path; a widening fix needs the owner.
- 3: refused, nothing ran (a kept baton not pinned or reviewed here). 4: failed, undone. 5: state unknown: tell the owner at once.
- 8: the owner signs (Stops; mode `manual`; `not chosen yet`: ask once), none ran: the card, then the printed `sign --by
  owner` once, alone (pod: hand off, no `sign`); no dialog, or a rejected one, is not a yes. Owner away, not in a pod: `go --queue`.
- 9: a `log` wait not met. 64: bad usage, a call off `Params`. 66: script unreadable.

### The skeleton

It passes `check` and `pack` as written. Replace the header, values, act, post-check and undo; copy `write()`, `gh_state()` and
the final `case` unchanged. `gh_state`: `act.md`.

<!-- baton-skeleton -->
```bash
#!/usr/bin/env bash
# Purpose: create one file holding the bytes of an input file
# Targets: {dest} — the file dest names
# Blast: that one file
# Undo: removes the file while it holds those bytes
# Pre: the file is absent
# Stops: none
# Params: dest=path body=input
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
P_DEST="$1"
P_BODY="$2"
holds() { [ -f "$P_DEST" ] && cmp -s "$P_DEST" "$P_BODY"; }
put() { cat -- "$P_BODY" > "$P_DEST"; }
act() {
  [ ! -e "$P_DEST" ] || { echo "REFUSE $P_DEST exists" >&2; return 3; }
  write "create $P_DEST" put
}
postcheck() { holds; }
undo() {
  if holds; then
    write "remove $P_DEST" rm -f -- "$P_DEST"
  fi
  ! holds
}
case "$PHASE" in
  rehearse) act; echo "VERDICT rehearse ok" ;;
  run) act; echo "VERDICT run ok" ;;
  postcheck) postcheck; echo "VERDICT postcheck ok" ;;
  undo) undo; echo "VERDICT undo ok" ;;
  *) echo "unknown phase: $PHASE" >&2; exit 64 ;;
esac
```
<!-- /baton-skeleton -->

### What `check` refuses

- A header field missing or twice, no Expect, a Stops word off the list, `Each` outside a kit; no `set -euo pipefail`.
- `write()` or the `PHASE=` line not as the skeleton's; `$PHASE` read elsewhere; a final `case` unlike the skeleton's.
- A `PLAN` line or a write (`gh`, `git push`, `kubectl apply`…) outside `write()`, or a function `write()` runs called without it.
- A local script or `source` (`act.md`); `diff`, `grep` or `cmp` in a pipeline unwrapped (`{ … || true; } | head`).
- A stop pattern Stops lacks (below); `gh_state` in `$(…)`, backticks, a pipe, a subshell or `&`.
- `Params` off the grammar; no values block; a `P_` name set elsewhere, unquoted, in `eval`, a heredoc or `gh -F`.
- A kept baton without a `Params` key or pattern `Targets`, or with `Usage`; a `bash -n` or `shellcheck -S error` finding.

## Stop list (the `Stops:` header; any of them means only the owner signs)

- `irreversible-delete`: deletes what cannot come back: data volumes, namespaces, package versions, repositories, branches (a merged one: `kit:branch-delete`), tags, secret paths, databases
- `secrets`: reads, prints, writes or rotates a secret
- `security-boundary`: widens a boundary: RBAC, admission or network policy, making something public, an admin bypass
- `cluster-lane`: changes a live cluster outside an approved lane: suspending reconciliation, draining nodes
- `history-rewrite`: force-pushes or rewrites history on a shared branch
- `money-org`: billing, plans, organisation admin (create or rename a repository, members)
- `publish`: posts outside: public places, other people's repositories
- `no-way-back`: can be neither rehearsed nor undone
- `owner-acts`: an owner decision names the owner as the one who acts

`check` flags a body line that looks like a stop act (`limits.md`): declare what the act does, not what the lint finds.
A refused or owner-held act (exit 8) is never done by another route (command, ref or file edit, script, tool); a
passing check is not a yes. Report and wait.

## Reference files

- `act.md`: remote programs, undo, run records, plugin scripts, `gh_state` paths, several batons.
- `kinds.md`: running a kind.
- `kits.md`: a kit's refusals; places, `pack`, a sandbox, reviewed batons.
- `modes.md`: exit 8, the owner's signature, queue, card, mode.
- `permissions.md`: `permissions --check` fails.
- `setup.md`: no launcher, or SessionStart's check fails.
- `limits.md`: what baton does not guard; non-shell values; stop patterns.
