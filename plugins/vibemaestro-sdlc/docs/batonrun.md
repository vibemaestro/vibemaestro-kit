English | [Tiếng Việt](batonrun.vi.md)

# BatonRun

BatonRun is the method vibemaestro uses for the actions that write outside the session and are more than a simple write: a flow of several writes on GitHub, a registry push, a change to the user's Claude Code settings, a deletion, a change on a live system. This document is the **standard**: the single source for what BatonRun is, how a run works, and where its limits are. Everything else points here:

- the skill `batonrun` ([`plugins/vibemaestro-sdlc/skills/batonrun/`](../skills/batonrun/SKILL.md)) holds the **operating instructions** for writing a baton: the commands, the parameters, the script skeleton, what `check` refuses, the exit codes, and keeping or changing a baton. This document ships in the installed plugin (`docs/batonrun.md` in the plugin root), but the skill keeps every instruction a session needs, the stop list included, so a session does not have to read it;
- the rule `batonrun` (`plugins/vibemaestro-sdlc/rules/batonrun.instructions.md`) is a **reminder** when a privileged command is typed directly: a simple write goes on, anything else becomes a run;
- the runner [`plugins/vibemaestro-sdlc/scripts/baton.py`](../scripts/baton.py) is the **machine**: when the code and this text disagree, the code is what runs, and the disagreement is a bug in one of them.

The measurements and lessons behind the design are in [`docs/research/batonrun.md`](../../../docs/research/batonrun.md). For the whole kit, start at the [README](../../../README.md).

## 1. What BatonRun is

### Definition

The owner is the person who owns the repository and signs the risky runs: working alone, that is you. A **run** is one action run of a repeated workflow: many commands or scripts in a fixed series, executed as one gated block. The session writes or picks the run, the machine checks and rehearses it, it is signed once, the session runs it, the machine post-checks it, undoes it on failure, and logs it. The owner is never handed command lines to type.

- **One run, one gate.** The series is shown, signed and run as a whole: the signature covers every step of it, so nothing in the series runs unsigned and nothing outside it runs signed.
- **A simple write is not a run.** A write that is one step, undone by one direct call that is not on the stop list, not on the stop list itself, and not a flow met before is a direct tool call: a comment on an issue, one new ticket. Everything else is a run: a flow of several writes, an act that cannot be undone (a merge, a push to a shared branch), an act the owner signs, and a flow met before. A flow cut into several simple writes is still a run (section 8).
- **A run is carried by one baton script.** The script holds the series; the commands and plugin scripts it calls are its steps (`kit:merge-pr` runs the merge guard; a session baton may run `open-pr.sh` as one of its writes). The script is the unit of checking and signing; the run is the unit of work and of the log.
- **Repeated is the point.** A workflow that recurs becomes a kept baton: one general script that declares its parameters, kept once with `baton pack` and called by name with new values (section 4). The next time it is one `baton go <place>:<name> key='value'…`, not a script written again.

### The name and the image

The image is the **conductor's baton**: only the session that runs the action holds it, and nothing plays until it is raised. The relay-race meaning is not intended. The method is BatonRun, the CLI is `baton`, one script is a baton script.

### Relation to CodeAct

CodeAct is an agent design from an ICML 2024 paper, also used by OpenHands' `CodeActAgent`. BatonRun keeps CodeAct's core: an action is code, not a JSON tool call, so several tools combine in one step with loops and branches, and the agent reads the output and fixes the script. The difference is where side effects may happen. OpenHands makes them harmless with a sandbox, so its loop is autonomous. A real cluster, registry, GitHub or user config cannot be sandboxed, so BatonRun has an inner loop with no consequences (write, check, rehearse, fix) and an outer gated step: one run of exactly the script that was signed.

### What BatonRun is not

- **Not a defence against a session that sets out to deceive.** It guards an honest but fallible session: a forgotten step, an edit after approval, other arguments, a world that changed, a second run. A session that writes a record by hand, runs a script with plain `bash`, copies `baton.py` elsewhere or builds a name at run time is forging; read-only tools and the owner's deny rules are what stop that (section 8).
- **Not a sandbox.** The writes are real. Rehearse shows the plan; it does not simulate the world.
- **Not a block on typed commands.** The rule reminds and the hook warns; neither refuses a command.
- **Not a place for secrets or credentials in the text.** A baton script, its plan lines and its log are plain text, so a credential does not belong in them.

## 2. Vocabulary

| Term | Meaning |
|---|---|
| owner | the person who signs the runs that need a person, and who sets the mode |
| session | the Claude Code session that talks to the owner and runs batons for them; its automatic signature is written `coordinator-auto` |
| run | one action run of a repeated workflow, executed as one gated block (section 1); one line in the log |
| baton script | the bash script that carries a run: a header, the act, a post-check, an undo, the `write()` gate, a final `case` over the phases |
| session baton | a baton script the session writes for the task in hand, at a fresh path; kept with `baton pack` the second time its flow is met |
| kind | a ready baton script the plugin ships for a repeated shape, run as `kind:<name> <args>`; `new --from <kind>` writes it to a file to change it |
| kit run | a baton script the plugin ships and reviews, run as `kit:<name> …`; only a kit run may run one of the plugin's gates |
| kept baton | a baton script kept with `baton pack` in one place, `project:` (the repository's `.vibemaestro/batons/`) or `user:` (this machine's library); it runs only with the bytes its keep record pins, and is called as `<place>:<name>` with values (section 4) |
| Params | the header field that declares a baton's values, `key=type` words; a call passes `key='value'` words, each checked against its type before anything runs (section 3) |
| Usage | the header field of a kit or callable kind: the synopsis of the flags or words it takes, which its own code checks |
| launcher | `<state-dir>/bin/baton`, the one stable command the permission rules name; it runs the newest installed `baton.py` |
| state directory | `$XDG_STATE_HOME/vibemaestro/baton`, else `~/.local/state/vibemaestro/baton`: the mode, signatures, log and run outputs; outside every repository |
| phase | `rehearse`, `run`, `postcheck` or `undo`: the runner sets `BATON_PHASE`, the script's final `case` dispatches on it |
| plan line | the text of one `write "<plan line>" <command…>` call: what one write does, with resolved values (full SHA, path, repo, host) |
| Expect | the header lines that say which plan lines the run must produce, one per write, as shell globs |
| seal | the hash that rehearse prints over the script bytes, arguments, directory, steering variables and plan; `sign` must name it |
| signature | the record that the seal was approved, by `owner` or `coordinator-auto`; one signature allows one run |
| Stops | the header field naming the stop-list categories the run touches; `none`, or any word of the stop list (section 6) |
| mode | the owner's standing decision, `manual` or `auto`, of who may sign a `Stops: none` run |
| decision card | the short summary shown to the owner right before the owner signs (section 6) |
| `go` | the one command that does the whole lifecycle (section 3) |

## 3. The lifecycle

| Step | What happens | What it catches |
|---|---|---|
| write | the session finds a kept baton, kit or kind with `baton list`, or writes the baton script: header (Purpose, Targets, Blast, Undo, Pre, Stops, Params, Expect), the act with every change through `write()`, a post-check, an undo | the act stated before it runs |
| check | static checks of the text: header fields, `Params` and how the script reads its values, the exact `write()` gate and phase dispatch, `set -euo pipefail`, no write outside `write()`, no local script or `source`, no unguarded `diff`/`grep`/`cmp` in a pipeline, stop patterns against `Stops`, `bash -n`, `shellcheck -S error` where installed | syntax and shape errors, a write that would skip the gate, an undeclared stop act |
| rehearse | the values are checked against `Params`; the script runs in phase `rehearse`: every read runs, every write only prints its plan line; the plan is compared with Expect line by line, and each plan line with the declared Targets | logic errors, a wrong target, a missing precondition, a plan that is not what was meant |
| seal | the hash over script bytes, its place, the values (and each file value's sha256), directory, the variables that steer the tools, and the plan | any change after this point |
| sign | the seal is approved, by the session (`coordinator-auto`, only mode `auto` and `Stops: none`) or by the owner in a dialog | an approval of something other than what was shown |
| run | rehearse again, then phase `run`: each write's DO line must be the signed plan; the signature is used up | a world that moved since signing, a second run |
| post-check with undo | phase `postcheck` (read again after 1, 2, 4 and 8 s); on failure phase `undo`, which compares every target with its before-state | a write that did not hold; a half-done state left behind |
| log | one line per event in `log.tsv` (time, event, name, script hash, binding, arguments, directory, signer, mode, result, undone, output path); the full output under `runs/` | an unaudited act |

**`go`** runs the steps from check to log in one command and stops at the first that fails, with that step's exit code and whole output. When every step holds it prints one line, `go: ok — <n> writes — <run log>`, which is all the session reports. A run that needs the owner (a Stops word, or mode `manual`, also when no mode was chosen yet: section 6) stops after rehearse with exit 8 and the facts for the decision card; nothing is signed and nothing runs. The separate commands (`check`, `rehearse`, `sign`, `run`, `log`) stay for the owner's signature and for diagnosis.

`go` runs a session baton (and reads an `input` value, the `--spec` file of `kit:gh-write` and the rules file of `kind:settings-merge`) only from a file written in the last 120 s, so a Write that did not land is not mistaken for the new script; `go --reuse` names an older file whose bytes are meant again. A kept baton has no such gate: it runs only with the bytes its keep record pins. A session baton is a Write to a fresh path and `go <path>` in the same response. The form `go -` also exists, but it is not the way to run a baton, because Claude Code blocks a heredoc that holds the baton skeleton and a heredoc is the only way to feed it (section 8). It reads the script from stdin, stores it once under the state directory and runs that file, so the same sha256 binding holds from check to run.

### Commands

Each command is `<launcher> <subcommand> …`. Until the launcher is installed (section 9) use `python3 <plugin root>/scripts/baton.py` instead. The runner's own options come before the script; everything after it is the script's: `key='value'` words for a baton with `Params`, the flags or words its `Usage` shows for a kit or kind. A script is a path (a session baton), `kit:<name>`, `kind:<name>`, `project:<name>` or `user:<name>`; any other prefix, or a bare name, is refused.

| Command | What it does |
|---|---|
| `new <name> [--dir D] [--from <kind>]` | writes `D/<name>.sh` from the template, or from a kind (`new --from <kind>`); never overwrites (exit 6) |
| `check <script>` | the static checks of the text; exit 0 or 1 |
| `list [<keyword>…]` | one line per baton (`kit:`, `kind:`, `project:`, `user:`) whose name, Purpose or Params hold every keyword, at most 25: who signs, its runs, `reviewed` or `not reviewed, kept by …`, the Purpose and the Params or Usage; when one baton matches, its whole entry |
| `pack <path> <project\|user>:<name>` | keeps a script that ran ok: writes `<place>/<name>.sh` and a keep record that pins its sha256; a `user:` keep prints one `owner:` line for the owner. `pack <project\|user>:<name> <other place>:<name>` moves a kept baton. In a sandbox a bare `<name>` is `project:<name>` and `user:` is refused (section 4) |
| `pack --retire <project\|user>:<name> <sha256>` | unpins one sha256; the file stays |
| `rehearse <script> [args…]` | check, then the rehearse phase; prints the plan against Expect and the seal |
| `sign --by owner\|coordinator-auto --seal <seal> <script> [args…]` | check, the mode policy, rehearse again, then the signature record; `--by` comes first, once, as two words; a seal that is not the one shown is refused (exit 3); `--by owner` also needs the record the plugin's hook wrote when it opened the owner's dialog for that very call, else exit 3 |
| `sign --by owner --queued <id>` | the owner signs a queued item, in a Claude Code session of their own: the same hook, dialog and one-use record; the signature is written into the item (section 6) |
| `run <script> [args…]` | the signed run: rehearse again, run, post-check, undo on failure; one line `run: ok — <n> writes — <run log>` when it holds |
| `run --queued <id>` | the same run for a signed queued item, from the directory it was queued in, once, before it expires; the plan must equal the sealed one |
| `go [--by coordinator-auto \| --queue] [--reuse] <script> [args…]` | check, rehearse, seal, sign, run, post-check and log in one command; the lifecycle above. With `--queue`, a baton that needs the owner is queued for them instead of stopping at exit 8: one line names the item (section 6). `<script>` is a path, `kind:<name>`, `kit:<name>`, `project:<name>` or `user:<name>`. `go -` takes the script from stdin: never use it for a baton, Claude Code blocks it |
| `log [--tail N]` | the last N lines of `log.tsv` (default 20) |
| `log --last` | the path of the newest run log; it is set before the script starts, so a run that was killed is found here |
| `log --wait-names N1,N2,… [--timeout S] [--since T]` | waits (at most 580 s) until the latest run line of each named script is ok; exit 9 at the deadline |
| `log --queue` | the queued items: pending, signed, expired, used or damaged, each with its card and the next command |
| `log --wait-queued <id> [--timeout S]` | waits (default 580 s, at most 24 h) until the item is signed (exit 0); exit 3 when it can no longer be (expired, used, damaged, absent), 9 at the deadline |
| `mode [manual\|auto]` | prints the approval mode, or sets it (section 6) |
| `mode remotes`, `mode trust\|untrust <remote>` | prints the owner's remote list, or adds or removes one remote in its canonical form `host/path` (section 4); like the mode, only on the owner's word |
| `permissions --print` | prints the user-settings block for this install (section 9) |
| `permissions --check [--settings F]…` | checks the rules in force against that block; writes nothing; exit 7 when a rule is missing, stale or unsafe |
| `permissions --install-launcher [--force]` | copies the launcher to `<state-dir>/bin/baton`; a cache copy the registry no longer lists refuses with exit 10 and writes nothing, unless `--force` |
| `help [<topic>]` | prints the command summary, or one reference file of the skill: `act`, `kinds`, `kits`, `modes`, `permissions`, `setup`, `limits` |

### Exit codes

| Code | Meaning |
|---|---|
| 0 | done |
| 1 | the script fails check or rehearse (no verdict line, plan differs from Expect or the declared Targets), or `go` found a stale file or `input` value; `pack`: the source fails check as a kept baton |
| 2 | environment: no `bash`, or the state directory cannot be written; `pack`: a lock held 30 s |
| 3 | refused, nothing ran: no signature matches, the mode does not allow the signer, the command stopped before the run phase, or a kept baton is neither pinned on this machine nor reviewed (section 4); a queued item that is not signed, expired, used, damaged, queued by the signing session, or no longer matches; `log --wait-queued`: the item can no longer be signed; `pack`: no ok run of these bytes, the bytes kept under another name, another Stops |
| 4 | the run or its post-check failed, and undo put the state back |
| 5 | the state is unknown: the run failed and undo failed too, or the run was interrupted (also an interrupted `pack`: the same command finishes it); tell the owner at once |
| 6 | `new`: the file already exists |
| 7 | `permissions --check`: a rule is missing, stale or unsafe |
| 8 | `go`: the baton needs the owner's signature; nothing was signed, nothing ran |
| 9 | `log --wait-names`: a named script has no ok run line by the deadline; `log --wait-queued`: the item is not signed by the deadline |
| 10 | `permissions --check`, or `--install-launcher` without `--force`: the session's vibemaestro-sdlc is not the installed one (it started before a plugin update); restart Claude Code; nothing written |
| 64 | bad usage: a call that does not fit the `Params` (a key missing, unknown or twice, a word with no `=`, a value that fails its type), an unknown prefix or a bare name; `pack`: no place outside a sandbox, `user:` in a sandbox, a kit, kind or copy name; `mode trust`: not a network remote; `go --queue` in a sandbox, with no session id, with `--by`, or on a baton the session may sign itself; `--queued` with a malformed id, another signer, or a word after the id |
| 66 | the script cannot be read (no such kept baton, no project root), `log --last` before any run has started, or `pack --retire` with no record of the sha |

### The header

Every baton script starts with these fields, one line each. `check` refuses a missing field, a field given twice and an empty `Expect`; `Each` is for kit scripts only and stands in for the `Expect` lines. A baton declares `Params` or, a kit or callable kind only, `Usage`; a kept baton declares `Params` with at least one key.

| Field | What it says |
|---|---|
| `Purpose` | what the run does, in one sentence; a session searches this line when it looks for a kept run |
| `Targets` | what it touches; in a baton with `Params`, patterns before ` — ` (`{dest}`, `{dir}/**`, `{repo}#{issue}`, `{ns}/{pod}`), then prose: every plan line names at least one, and each of its absolute-path, repository, URL or `refs/` words matches one (the copies of file values are exempt; a word such as `--to=/x` is not read as a path, so write a path as a word of its own). Targets that do not read as patterns are not tested, and `pack` refuses them |
| `Blast` | the most it can change |
| `Undo` | how it is put back, or what it leaves behind |
| `Pre` | what must hold before it runs |
| `Stops` | `none`, or one or more stop-list words (section 6); the owner signs when it is not `none` |
| `Params` | `none`, or `key=type` words: `int`, `sha40`, `sha256`, `name`, `repo`, `ref`, `path` (absolute), `url` (https), `file` (an existing file), `input` (a file written for this call), `under:<dir>`, `enum:<a>\|<b>`. Every key is required and given once. No value holds a space, a quote or `$`, so free text (a title, a body) is an `input` file. The script reads the values once, in a block of `P_<KEY>="$<n>"` lines in the declared order; a file value arrives as a read-only copy. A secret (a private key, a token, a cluster credential) is a `path` value, which the script feeds to a command's stdin and never prints: a `file` or `input` value is copied under the state directory (a call that never reaches its run phase removes its copy when it ends, unless another baton process holds it; the copy a run used is kept, the newest 200, until a later call of the same bytes that never runs ends), so one that looks like key material (a private-key header, a `client-key-data` field, a token of a known shape) is refused (exit 64) |
| `Usage` | kits and callable kinds only: the synopsis of their flags or words |
| `Expect` | one line per write, a shell glob over the whole plan line, in order (below) |
| `Each` | kit scripts only: one glob for every plan line, for a run whose number of writes comes from its input (`kit:gh-write`) |

**How Expect matches.** Rehearse collects one plan line per `write()` call, in the order they ran, and compares the i-th with the i-th `Expect` line as a shell glob over the whole line, case-sensitive. `*` is any run of characters (spaces and `/` too), `?` one character. It is not a prefix match, and the counts must be equal: a missing or an extra line is a FAIL row. For example the plan `create docs/a b.txt` matches `create *`; the plan `create docs/a.txt` does not match `create`.

### The skeleton

A baton script that passes `check`, and `pack` once it ran ok. Replace the header, the values block, the act, the post-check and the undo; copy `write()`, `gh_state()` and the final `case` unchanged. To ask whether a GitHub object exists, call `gh_state <api path>` as a statement, then test `$GH_STATE` (`exists` or `absent`; anything else stops the script).

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

### Try it

This runs the skeleton end to end in a scratch state directory and keeps it. Run it in bash, from the root of a checkout of this repository, in one shell session. Save the skeleton above as `demo.sh` in the scratch directory, then run `go` within 120 s of saving it and of writing the input file (or add `--reuse`).

```bash
BATON="python3 $PWD/plugins/vibemaestro-sdlc/scripts/baton.py"
export XDG_STATE_HOME="$(mktemp -d)" XDG_DATA_HOME="$(mktemp -d)"
DEMO="$(mktemp -d)"
# save the skeleton as "$DEMO/demo.sh", then:
cd "$DEMO"
printf 'hello\n' > body.txt
$BATON check demo.sh
$BATON rehearse demo.sh dest="$DEMO/out.txt" body="$DEMO/body.txt"
mkdir -p "$XDG_STATE_HOME/vibemaestro/baton" && printf 'auto\ndialog %032d\n' 0 > "$XDG_STATE_HOME/vibemaestro/baton/mode"   # the scratch state only: a real mode change is the owner's click (modes)
$BATON go demo.sh dest="$DEMO/out.txt" body="$DEMO/body.txt"
cat "$DEMO/out.txt"
$BATON pack demo.sh user:demo-put
$BATON list demo
$BATON log --tail 3
```

`XDG_STATE_HOME` and `XDG_DATA_HOME` point the mode, the signatures, the log and the library at throw-away directories, so the demo never changes your real approval mode or library. After `mode auto` the session may sign this `Stops: none` run itself, so `go` ends with one `go: ok` line and `out.txt` holds `hello`. In mode `manual` the same `go` stops after rehearse with exit 8 and the owner's decision card. `pack` keeps the script as `user:demo-put` and prints its `owner:` line; from then on `go user:demo-put dest=… body=…` runs it with other values.

## 4. When a workflow becomes a run, and where runs live

**A simple write is direct.** One step, undone by one direct call that is not on the stop list, not on the stop list itself, not a flow met before: the session makes the tool call. Anything else is a run, and the session looks for one before it writes one:

1. `baton list <keyword>`.
2. **One fits** (the same purpose, targets and risk): `baton go <place>:<name> key='value'…`, every value single-quoted, since the session's command line is a shell. Free text that came from outside (an issue title, a message) goes into an `input` file the session writes, never onto the command line.
3. **One is close:** evolve it in place (below), never a copy.
4. **None fits:** write it as a session baton with `Params`, run it, and the second time the flow is met, keep it with `baton pack`.

**Where runs live.**

| Run | Lives in | Run as |
|---|---|---|
| kit run | `plugins/vibemaestro-sdlc/batons/<name>.sh` (versioned plugin code; the gates it runs are in `gates/`) | `<launcher> go kit:<name> …` |
| kind | `plugins/vibemaestro-sdlc/templates/baton-kinds/` | `<launcher> go kind:<name> <args>` |
| dependent plugin's run | that plugin's `batons/` (a plugin of the same marketplace that depends on `vibemaestro-sdlc`) | `<launcher> go kit:<name> …` (`help kits`: how it is found and trusted) |
| project baton | `<project root>/.vibemaestro/batons/<name>.sh`, committed with the repository and reviewed in its pull request | `<launcher> go project:<name> key='value'…` |
| user baton | `$XDG_DATA_HOME/vibemaestro/batons/`, else `~/.local/share/vibemaestro/batons/`: this machine's library, outside every repository | `<launcher> go user:<name> key='value'…` |
| session baton | a fresh path the session writes (a scratch directory); never stdin (`go -` with a baton heredoc is blocked, section 8) | `<launcher> go <path> …` |

A call always names the place; there is no lookup across places, so nothing in a repository or the library can stand in for a `kit:` or `kind:` baton.

**Keeping: `baton pack`.** `pack <path> project:<name>` or `pack <path> user:<name>` keeps a session baton that ran ok. It refuses a script with no `ok` run of these exact bytes in the log, one that fails `check` as a kept baton (it needs `Params` with at least one key and `Targets` as patterns), the same bytes already kept under another name, a name already kept with another `Stops`, a `kit:` or `kind:` name and a copy name (`-v<digits>`, `-<7 or more hex>`). It writes the file and a keep record in the state directory that pins the sha256: a kept baton runs only with pinned bytes, at every step, so a file changed by hand is not callable until it is kept again. `pack` does not commit; a project baton is committed on the branch and reviewed in its pull request. A user baton is reviewed by nobody: `list`, the sign line, `go`'s success line and the decision card say `not reviewed, kept by …`, and each `user:` keep, new or evolved, prints one line starting `owner:` that the session copies into its next reply to the owner. `pack --retire <place>:<name> <sha256>` unpins one sha; `pack project:<name> user:<name>` (or the other way) moves a kept baton.

**In a sandbox.** A session in a sandbox pod (`INTENT_SLUG` and `SEAT` both set) keeps to `project:`: `pack <path> <name>` keeps `project:<name>`, and a `user:` keep or a move to `user:` is refused (exit 64), since the pod's library is lost with the pod. A pod never gets the owner's signature, so a flow that stops for the owner is handed to the coordinator:

1. The session runs `go <path> key='value'…` up to the owner's decision card (exit 8): check, rehearse and the plan against Expect and the Targets all held. In a sandbox, that stop is logged for these exact bytes when it comes from the baton's `Stops`, or from mode `manual` for a session script (a path) with `Stops: none`, and the output names the call to hand the coordinator instead of a sign line, under a name the coordinator's machine can run: no sign, `run` or `go --queue` is a next step there, and no mode command is shown. A session script without `Params` is told the one step first: add them, then `go` again. `rehearse` in a pod names no owner command either: its last line says that `go` hands the call to the coordinator.
2. `pack <path> <name>` keeps those bytes as `project:<name>` on that logged stop instead of an `ok` run; its line says `not run: stop-list, the owner signs after merge`. A `Stops: none` script keeps only on a stop logged in mode `manual`: its line, its keep record and the hand-off say it never ran, so the coordinator's `go` is its first run. Only in a sandbox and only to `project:`; everywhere else `pack` needs an `ok` run.
3. The session commits the baton on its branch, opens the pull request and tells the coordinator the call.
4. The coordinator merges it after its post-check, then runs it with the owner's signature, or, for a kept `Stops: none` script that never ran, with its own `coordinator-auto` when its mode is `auto` (its first run): as `project:<name>` from a checkout of the merged default branch when that repository's remote is on the owner's remote list (below), else from a fresh scratch copy of the merged file, which it then keeps with `pack`.

**Merging a project baton.** The default deny globs that `kb.py init` writes, and that the guarded merge adds to a repository's first pull request, deny `.vibemaestro/*` (the config), `.vibemaestro/gates/**` and `.vibemaestro/rules/**`, and leave `.vibemaestro/batons/` to the guard like other code. A repository whose `merge.deny_globs` names `.vibemaestro/**` keeps every project baton an owner merge.

**Reviewed project batons.** A `project:` baton runs without a keep record on this machine when all hold, checked at every step as the pin is: the project root is in git; `refs/remotes/origin/HEAD` names a branch of origin; origin's URL, in its canonical form (`host/path`: no scheme, userinfo or `.git`, the host in lower case), is on the owner's remote list; and its bytes, as a git blob, are the blob at its path on that branch. Its label is then `reviewed on <url> <branch>`. The list lives in the state directory, outside every repository, and is empty until the owner sets it: `mode remotes` prints it, `mode trust <remote>` and `mode untrust <remote>` change it, each with the owner's dialog as for the mode. A remote written with a user or token before `@` (git's own `git@host:path` aside) is refused (exit 64): write it without one. A file changed on a branch, a baton only on another branch, a link on origin, a retired sha, a remote not on the list (a relative path, or a URL ending in `/.git`, is never one), a project root that is not the top of its repository and a `user:` baton all need a keep record; the refusal (exit 3) says which condition failed.

**A kept baton is not trusted code.** Every call runs check, rehearse, the plan against Expect and the Targets, seal, sign, run, post-check and log, like a session baton. It may not run a gate, holds no secret, and its `Stops:` decides who signs; in mode `auto` the session may sign a `Stops: none` baton another session kept.

**Naming and finding.** A baton has a short kebab-case name that says what it does (`merge-pr`, `gh-write`, `ci-rerun-failed`), and its `Purpose:` header line says it in one sentence. `baton list <keyword>…` finds it: one line per baton whose name, Purpose or Params hold every keyword, at most 25, and the whole entry when one baton matches. A session that hands several runs to a subagent names them `<prefix>-<act>.sh` with a prefix of its own, so `log --wait-names` can wait for exactly those names.

**A run that was killed.** `run` and `go` print one line when they hold, so a run killed before it ends (SIGKILL, a tool timeout) prints nothing. Before the script starts, the runner writes a `run-start` line to `log.tsv` and the run log's path to `runs/LAST`; `<launcher> log --last` prints that path.

**From a kept baton to a kit.** A baton other repositories need becomes a `project:` baton of each, or a kit: open an issue in the kit's public repository that carries the script, what it does, how many runs the log shows and whether they held, and where else it is needed. A run for sdlc's own domain becomes a `kit:` run or a `kind:` in `vibemaestro-sdlc`. A run that belongs to a dependent plugin ships in that plugin's `batons/` and runs as `kit:<name>`, with every check of an sdlc kit; a name two plugins ship runs nowhere, so a kit name is unique across the plugins.

### How a run evolves

The rule: **a kept baton stands for a workflow, so a changed workflow updates it, never a forked copy.** The test is whether it is still the same workflow: the same purpose, targets and risk.

- A step needed every time: add it to the baton.
- A step needed sometimes, or a value that changes between runs: a parameter. The signature binds the values, so the plan shows them.
- Another purpose or other targets, or a new Stops word: a new baton with its own name.
- A step met for the first time: a session baton this once; the second time, fold it into the kept baton.

To evolve one, copy the kept file to a fresh path, change it, run it with values, then `pack` it again under the same name. For a project baton every kept sha stays callable until retired, and git keeps the old versions; for a user baton only the newest keep is callable, and the keep records and the log keep the old ones.

Guards:

- A change within the same workflow that widens what the baton touches updates its header. A new Stops word makes a new baton (above), and the owner signs it from then on.
- `pack` refuses a copy name and the same bytes under a second name, so a copy is not the cheap way through.
- A kit run changes only through a kit PR; meanwhile the extra step runs as a separate run right after it.
- The signature binds the script's sha256 and the log records it, so which version of a baton ran stays known.

## 5. The run catalogue

The kit runs and kinds, one line each; `baton list` prints the same with each one's run count. Most keep the arguments their own code checks, so they declare `Usage`; `kit:branch-delete` declares `Params`, and the column shows its call. The plugin version binds them into the signature. Project and user batons are not in this table: they are the repository's and the machine's own, and `baton list` shows them.

| Run | What it does | Usage | Stops |
|---|---|---|---|
| `kit:merge-pr` | the guarded merge: rehearse is the guard's dry run (head pinned, CI, conflict, deny globs, the brief's globs, …), the run merges pinned to the signed head; a merge is not reversible, the way back is a revert PR | `--repo <owner/name> --pr <n> --head <sha40> --brief <file> [--behind auto] [guard options]` | none |
| `kit:gh-write` | small GitHub writes from one JSON spec: issue-create, issue-comment, comment-edit, issue-edit, pr-body-edit, issue-reopen, issue-close, pr-close and pr-ready (pinned to the head), pr-create (from a pushed branch at a pinned head), file-pr (one file added or replaced on a new branch from the base tip, the replaced blob pinned, then its PR); refuses public repos, deletions, repo creation and a workflow path; undo never deletes, and names a branch it leaves | `--spec <file> [--recover]` | none |
| `kit:branch-push` | pushes one local branch of the clone it runs in as a new branch of its private GitHub repository, at the pinned tip, never forced; pushes from a scratch repository no clone config or hook reaches; refuses a public or internal repository, a remote other than github.com/`--repo`, a branch the remote has, a new commit that changes a workflow, and names git resolves as another ref; undo names a branch it cannot delete (exit 5) | `--branch <name> --head <sha40> --repo <owner/name> [--remote <name>]` | none |
| `kit:branch-delete` | deletes one branch of a private GitHub repository at a pinned head merged into its default branch, run from a clone of it: rehearse refuses a branch whose tip is not the pinned head, proves from GitHub that the head is an ancestor of the default branch's tip, or that a merged PR of this repository's branch at that head into the default branch has its merge commit on that branch and `refs/pull/<n>/head` at the head (a squash or rebase merge), and pins both SHAs and the proof in the plan line; the delete is the plugin's gate run inside `write()`, which checks the signed plan line and pushes with a lease on the head; the post-check proves it again; refuses an unmerged, default or protected branch, one a ruleset forbids to delete, a name that is also a tag, an open pull request from or into it, and a public or internal repository; undo recreates the branch at the pinned SHA when this run deleted it | `repo=<owner/name> branch=<name> head=<sha40>` | none |
| `kit:plugin-update` | updates every plugin of the machine's `vibemaestro` marketplace (user scope) through `claude plugin marketplace update` and `claude plugin update`, never `-y`: `vibemaestro-sdlc` and `vibemaestro-brain` to kit main at one full SHA, and each marketplace-local plugin (`./plugins/<name>`) to the marketplace's main, read from GitHub and pinned in the plan line; a plugin already at its target is skipped. Rehearse reads the marketplace layout (the kit's own marketplace, or both plugins as `git-subdir` sources of one https github.com repository at ref `main`; every other entry a local plugin) and refuses any other, one that names no kit repository or more than one, an entry with keys beyond name, source and description, a symlinked plugin directory, a clone tree that differs from its HEAD, or a rewritten origin, and refuses a SHA that is not kit main; the run keeps byte copies of `installed_plugins.json` and `known_marketplaces.json`, then, after the marketplace update, wants the same layout and local plugins, kit main and the marketplace's main unmoved, and the clone at that main; the post-check wants each install's `gitCommitSha` its target, a version of its 12 hex (alone or with `-<8 hex>`), the cache path, a `plugin.json` with no version and the new launcher template accepting it, then prints the next setup step; undo puts both files back byte for byte, unless anything else in them changed, a plugin of the run moved since, or the copy names an install that is gone, and names the cache directories and the clone it leaves | `<full kit sha>` | none |
| `kit:workflow-dispatch` | dispatches one `workflow_dispatch` run in a private repository, pinned to the branch head and the workflow file's blob, with a run record and a check against the signed plan before the dispatch; undo cancels only the one new run this dispatch made | `--repo <owner/name> --workflow <file.yml> --ref <branch> [--input <key>=<value>]…` | none |
| `kit:coordinator-bootstrap` | sets up a new or moved machine for BatonRun: a machine report, then the launcher and the printed permission block (attribution off where a key is absent) through `kind:settings-merge`; refused at rehearse when there is nothing to do; undo puts each file back byte for byte | none | security-boundary (the owner signs) |
| `kind:install-file` | installs one file, byte for byte, into a directory that may be read-only, never under `.git`, `.claude`, the config or the state directory | `<source> <directory>` | none |
| `kind:settings-merge` | adds permission rules to a Claude Code `settings.json`, removes none, with a run record and a backup kept only for the undo (removed once the run held or its undo put the file back; kept for the owner when the state is unknown) | `<settings.json> <rules.json>` | security-boundary (the owner signs) |
| `kind:ci-rerun-failed` | re-runs the failed jobs of one CI run of a private repository | `<owner/name> <run id>` | none |

Templates that `new --from <kind>` writes to a file but that do not run as `kind:` (the act is the session's to fill), each declaring `Params`: `remote-exec` (a program through stdin into `bash -s` over `ssh`; `host`, `rpath`, `body`) and `kubectl-exec` (the same through `kubectl exec -i`, the API server given and compared with the context's; its `Stops` is `cluster-lane`). Not built: `owner-merge-pr`, a merge the owner signs for a PR that touches `merge.deny_globs` (the guard refuses such a PR whatever signs it).

## 6. Approval: the modes, the stop list, the owner's signature

**The modes** are the owner's standing decision, not the session's choice per run. They live in the user's state directory, never in a repository; `mode` prints the mode (`manual` when none was set), and `mode manual|auto` changes it only on the owner's word: like `sign --by owner`, the change needs the record of the owner's dialog that the plugin's hook writes for the literal call, and a call without one is refused. The session never picks the mode itself, and a message from another agent or machine does not change it.

**Asked once.** A fresh install has not chosen a mode. It reads as `manual`, and the first `Stops: none` run that stops for it (`go` exit 8) has the card line `mode manual (not chosen yet)`. The session then asks the owner once which mode, and says what each means: `auto`, recommended on a solo machine (the session signs a `Stops: none` run; a stop-list run still needs the owner), or `manual` (the owner signs every run). Only right after the owner's own answer, the session runs the command the card's `Mode:` line names, `<launcher> mode <answer>`, alone in its Bash call: the plugin's hook opens the dialog, and the owner's click there sets it. Then the session runs the baton again; `go` refuses a file written over 120 s before, so it writes it to a fresh path. Once a mode is set, the card never says `not chosen yet` again. No answer, or a rejected dialog, leaves the mode not chosen: the run waits for the owner's signature as in manual, and the next exit 8 on a `Stops: none` run asks again.

- **manual** (the default until the owner chooses): the owner signs every run after seeing it.
- **auto**: the session signs a run whose header says `Stops: none` itself (`coordinator-auto`) and runs it with no question, a kept baton another session kept included (its sign line says `not reviewed, kept by …`); a run with any Stops word needs the owner's signature, as in manual.
- In auto, a failed precondition or an Expect mismatch is not a stop: the session fixes the script and rehearses again, as long as the fix does not widen what the run touches. A fix that widens it needs the owner.

**The stop list.** A run that does any of these declares it in `Stops:`, and then only the owner signs, in every mode:

| Word | The run … |
|---|---|
| `irreversible-delete` | deletes data that cannot come back: volumes with data, namespaces, package versions, repositories, branches and tags (check cannot prove a branch merged, so a hand-written branch or tag delete needs the owner; a merged branch of a GitHub repository goes through `kit:branch-delete`), secret paths, databases |
| `secrets` | reads, prints, writes or rotates a secret |
| `security-boundary` | widens a boundary: RBAC, admission or network policy, making something public, an admin bypass outside an existing owner rule |
| `cluster-lane` | changes a live cluster outside an approved lane: suspending reconciliation, draining nodes |
| `history-rewrite` | force-pushes or rewrites history on a shared branch |
| `money-org` | touches billing, plans or organisation admin (create or rename a repository, members) |
| `publish` | posts outside: public places, other people's repositories |
| `no-way-back` | can be neither rehearsed nor undone |
| `owner-acts` | is an act an earlier owner decision names the owner as the one who does |

A call whose argument or Param value names a Claude Code settings file (a `settings*.json` right in a `.claude` directory, the managed settings directory or `$CLAUDE_CONFIG_DIR`), or such a directory itself, or another name of one (a hard link, the file or directory a settings link points to, unless that is a device or, behind a file name, a directory), is `security-boundary` whatever its `Stops:` says. `go`, `rehearse`, `sign` and `run` decide on the bound value, not the text: `~`, `$VAR`, `..`, a relative path, a link and a glob are resolved, and the part after an `=` is read too. Only the owner signs it: `go` stops with exit 8, `sign --by coordinator-auto` and the `run` of such a signature are refused, each naming the argument in one line. A value is read as one path, never searched for a path among other words, and a subdirectory of `.claude` is not one. A regular file with other hard links that baton cannot place counts too: its other name may be a settings file in a `.claude` no search reaches, so the owner signs.

`check` flags a body line that looks like a stop act, naming the category, the word and the header to add; that lint is a backstop, not a proof: a run declares what it does, not what the lint finds. The lint knows only some cluster acts (`flux suspend`, `kubectl … drain|cordon`).

**A settings change outside a baton is denied.** Adding a permission rule is `security-boundary`, and a session could make it with a plain tool, outside any baton. The plugin's hook `settings-guard.py` runs before every Edit, Write, MultiEdit, NotebookEdit and Bash call, in every mode, on the owner's laptop as in a pod, whatever the repository's `hooks` setting says. It looks at a Claude Code settings file: a `settings*.json` in a `.claude` directory or in `$CLAUDE_CONFIG_DIR`, the name's case ignored, through a symbolic or a hard link too, and the file a settings link points to.

- **Edit, Write, MultiEdit** are judged on the exact file after the call. Denied: an allow rule or an additional directory added; an ask or deny rule removed; `defaultMode` moved up the order `plan`, `dontAsk`, `default`, `acceptEdits`, `auto`, `bypassPermissions` (an unknown value counts as the top); `disableBypassPermissionsMode: "disable"` dropped; any other `permissions` key changed; a file left that is not a JSON object; any top-level key changed except `$schema`, `model`, `outputStyle`, `attribution`, `includeCoAuthoredBy`, `cleanupPeriodDays`, `language`, `alwaysThinkingEnabled`, `spinnerTipsEnabled` and `theme`. So `hooks`, `env`, `statusLine`, `apiKeyHelper`, the MCP keys, `enabledPlugins`, `sandbox`, `disableAllHooks` and every key Claude Code adds later are denied. A narrowing passes: an allow rule or an additional directory removed, an ask or deny rule added, `defaultMode` moved down. An Edit that does not match the file exactly is denied too (Claude Code's Edit matches more loosely, so the result cannot be known).
- **NotebookEdit** on a settings file is denied.
- **Bash** is judged on the command text, so every write the hook finds onto a settings name is denied, a narrowing included: a redirection, `tee`, `sponge`, `cp`, `install` or `rsync` onto it, a copy, move or link of a settings-named file into a `.claude` directory (`-t` too), `mv`, `ln`, `rm`, `truncate`, `dd of=`, `patch`, an in-place `sed`, `perl`, `awk` or `yq`, an editor, `git checkout|restore|rm|mv|stash` naming it, `curl -o`, `wget -O`, `find -delete` or `-exec` of a writer, `xargs` of a writer, inline interpreter code (`python -c`, a heredoc, `node -e`) that names it and writes. The hook splits words as the shell does, so a quoted sentence (a commit message) is one word and names nothing. The first word is the command; after a runner (`sudo`, `timeout`, `env`, `xargs`, `find -exec` and the like) any later writer word counts too. A string a shell runs (`bash -c`, `eval`, `su -c`, `$(…)`, backticks, a heredoc fed to a shell, a string literal in inline interpreter code) is read again as commands; any other heredoc body is data. Only a file whose own directory is `.claude` counts (a `.claude/worktrees/…` checkout above it does not). Reads pass.

The one way is `<launcher> go kind:settings-merge <settings.json> <rules.json>`: it adds allow, ask and deny rules and stops for the owner (exit 8). On the owner's laptop too, a settings change goes through the kind, so the owner signs it. A change the kind does not make (`defaultMode`, removing an ask or deny rule, another key) waits for the owner. In a pod the owner never signs: after exit 8 the session hands the coordinator the call the output names, and the deny message says so. A baton's writes run inside its own process, which no hook sees, so `kind:settings-merge` and `kit:coordinator-bootstrap` are not stopped. What the hook cannot see is in section 8.

**The owner's signature** is the owner's click in a dialog: right after the decision card the session runs `sign --by owner --seal <seal> …` alone in its Bash call, the plugin's hook makes that command ask whatever the permission rules say, and the dialog shows it. The hook writes a one-use record for that call, and `sign` refuses without it. The hook denies the call where no owner answers the dialog: in a sandbox, from a subagent, in a mode or a `-p` run with no dialog, while a hook or a permission-prompt tool could answer. A session never runs the command on its own, as a test, or after a refusal. When `go` stops with exit 8 it prints the facts for the owner (what the writes do, why, the blast, the undo, the stop reason, what was checked) and the two commands to run on the owner's go; in a sandbox pod it prints the hand-off instead (pack as `project:`, open the PR, hand the coordinator the call: name, args, seal) and no `sign` or `go --queue` is run; `rehearse` there prints no sign command. A seal that no longer matches what was shown is refused. **No dialog shown, or a rejected one, means not confirmed**: the session records the run as pending and says so; it never retries `sign` in a loop and never reads silence as a yes.

**The owner's queue.** An open dialog holds the session that asked until the owner clicks, and its record lives 10 minutes. When the owner is away, the session runs `go --queue <script> [args…]` instead of `go`: the same check, rehearse and seal, then an item in `<state-dir>/queue/<id>.json` (private) that holds the seal, the arguments as given and as bound, the directory, the script's sha256, the plan, the decision card, the session and the Claude Code process that queued it, the time and an expiry 24 hours later, and a sha256 over all of it. It prints one line naming the item and the session goes on working; `log --wait-queued <id>`, run in the background, ends when the item is signed. The owner signs from a Claude Code session of their own, at the time they choose: `/vibemaestro-sdlc:owner-sign` lists the pending items (`log --queue`) and runs `sign --by owner --queued <id>` once per item they pick, alone in its Bash call; the hook opens the dialog, which shows the item's card, and writes the record as for `--seal`. The signature goes into the item and names its sha256. The session that queued an item cannot sign it: the hook denies the call, with no dialog, from that session id or from its Claude Code process under a new session id (after `/clear`), and `sign` refuses it again. `run --queued <id>` runs a signed item once, from the directory it was queued in, before it expires: its rehearse must give the sealed plan (a moved head, base or file is a refusal), then run, post-check and log as `run`. An item whose bytes changed after the dialog opened or after signing, an expired one, an unsigned one and a used one are refused. Like the signature records, an item guards against slips, not against a process of the same user that rewrites both the item and its signature. Mode `manual` and `auto`, the stop list and a pod are as above: a pod queues nothing and never signs as the owner.

**The decision card.** Right before the owner's dialog the session writes, in the owner's language, at most seven short lines: what it writes, where, why (the decision or the need), the impact, the undo (or "cannot be undone"), the one risk, and what was checked (check ok, rehearse ok, plan matches Expect, N writes). The `sign` command's description, which the dialog shows, is the card's first line; seals, paths and the rehearse output come after, as detail.

## 7. Cost

**What was measured.** Sending every write through a run costs more than the direct way: over an 18-task session, a session that sends every write through BatonRun costs 3.05 to 3.67 times a session with no plugin per correct write, with no break-even within the 18 tasks, and doing a kind of write a second time gains no more with BatonRun than without, because most batons were written anew each time. The per-task part dominates: the session writes about 4.4 to 4.9 times the output tokens. Correctness was the same in both arms. The method and the numbers are in [`docs/research/batonrun.md`](../../../docs/research/batonrun.md).

**What follows from it.** A simple write is a direct call, not a run, so it costs what the direct way costs. A flow met before is not written again: `baton list` finds the kept baton and one `go` with new values runs it, with no skill read and no script written. The checks are machine checks and cost almost nothing; the cost is model turns and output kept in context, which is why `go` exists, why it prints one line, and why the skill is read only to write or change a baton. What keep-and-call saves over writing anew is not measured yet.

**Running several runs.** In place by default, any number. Hand three or more to one worker subagent only to keep a large main context small (over about 400k tokens): delegation is cheaper only for a session's first multi-run task. The main session then waits on the log for the exact script names (`log --wait-names`), and trusts the log line, which is machine evidence, not the worker's report.

## 8. Limits

What baton does not guard:

- **Honest, not hostile.** BatonRun guards a fallible session, not a deceiving one (section 1). `check` reads the text; it does not run it, so an indirection that hides a run (`eval`, a name built at run time, a launcher behind a variable) is forgery, not a gap to work around.
- **The rule and its launcher warning advise; they do not block.** The rule reminds once per session when a privileged command is typed directly, on the command line only. The hook warns on every launcher `sign`, `run` or `go` that is not bare (a pipe, a chain, a redirect, a substitution, a prefix or a shell wrapper), because the allow rules then do not match and Claude Code's auto-mode classifier decides.
- **Permission rules match the command text,** not what the shell makes of it, and Edit rules cover the write tools and the file commands Claude Code recognises, not any process. `permissions --check` reads the rules only: not `defaultMode`, a skip-permissions launch, or the classifier's settings.
- **A plugin script is trusted from the plugin root `baton.py` runs from,** only as the command of a write with its sha256 in the plan line; a `scripts/` changed during a phase is detected after it, not prevented.
- **What `go` cannot tell:** whether a fresh file holds what was meant (an Edit that did not apply), and anything about a file the script reads itself unless its sha256 is in a plan line.
- **A mode comes from the owner, not from a message.** A session cannot tell another agent or machine to change its approval mode, or its remote list.
- **"Reviewed" trusts the local view of origin.** A reviewed project baton is checked against `refs/remotes/origin/HEAD`, a local ref, at the baton's path from the repository's top, and against the URL git fetches origin from (`git remote get-url origin`, after `insteadOf`); that git runs without the caller's `GIT_*` variables. Moving the ref by hand (`git update-ref`, a fetch from another URL than the one checked) is forgery, as editing the state directory is.
- **`go -` with a baton is blocked by Claude Code.** In the default permission mode (tested with Claude Code 2.1.303, `-p --permission-mode default`, allow rule `Bash(<launcher> go:*)`) the allow rule matches a short `go -` heredoc, but a heredoc holding the baton skeleton is blocked before any rule applies, by the tool's own check ("Contains brace with quote character (expansion obfuscation)"), which fires on every `{ … }` function body that holds a quote (`write()`, `gh_state()`). Auto mode is not tested. Default is a supported mode, so the standard does not depend on auto: a session baton is a Write to a fresh path and `go <path>`. The check is the tool's safety check; the skeleton is not reshaped to dodge it. The hook stays silent on a quoted `go -` heredoc, though that is blocked for a baton, and names every other shape (an unquoted delimiter lets the shell expand the body before baton reads a byte; a line after the closing one is a command of its own).
- **A value is safe in the shell, not in every tool.** A `Params` value reaches the script as one argv word of a checked type: it cannot end a shell word, start an option or add a plan line. A tool that reads its own code or files from it can still misread it; `check` refuses a value in `eval`, a heredoc body, a command name, `gh -F` and `curl -d`, and the skill's `limits.md` names the safe forms for the rest (`jq --arg`, `gh -f`, `--` before operands, no value inside a `sed`, `awk` or `find -name` program). Free text from outside goes through an `input` file, never the command line. A secret goes through a `path` value, never a `file` or `input` value, which is copied and kept: one that looks like key material is refused (exit 64). A `path`, `under:`, `file` or `input` value is refused (exit 64) when the last segment of its path, the basename, starts with `-`, `+` or `@`; a middle segment may.
- **A flow split into simple writes is not seen.** Nothing tells a flow cut into single writes from honest single writes; the rule and the skill name the cut as the thing not to do.
- **The settings guard finds; it does not prove.** It reads Bash as text. It does not see a name built at run time (a variable, `$(…)`, string glue, a glob without `settings` in it), a script file run, a baton the session wrote (`check` flags its writes onto a settings path as `security-boundary`, and a call whose argument names a settings file stops for the owner, section 6), `git apply`, `git am`, an archive unpacked, a checkout or merge that does not name the file, a directory copied whole over `.claude`, a write through a link made earlier under another name, an MCP tool that writes files, a write on another host (`ssh host '…'`), or the app state file `~/.claude.json`. It also denies a `python -c` that reads the settings and writes another file, a `.claude/settings*.json` that Claude Code does not read (a backup, an example, a test fixture), and a writer word after a runner that is only an argument (`sudo grep rm .claude/settings.json`). A settings file with comments counts as not JSON.
- **A merge, a publish and the like cannot be undone.** The run says so in `Undo:`; when it fails after the world changed it ends with exit 5 and the owner is told at once.

## 9. Permission setup

Once per machine, the session runs three commands and the owner applies the result; the plugin never writes settings:

1. `permissions --install-launcher` copies the launcher to `<state-dir>/bin/baton`. It runs the newest installed vibemaestro-sdlc from the plugin cache and refuses any other `baton.py`. Run it from the installed vibemaestro-sdlc, the one the registry (`installed_plugins.json`) lists: a cache copy the registry no longer lists (a session started before a plugin update) refuses with exit 10 and writes nothing.
2. `permissions --print` prints the user-settings block; the owner adds it through Claude Code's settings.
3. `permissions --check` says whether the rules in force hold the split (exit 0) or names each rule that is missing, stale or unsafe (exit 7). A session whose vibemaestro-sdlc is not the installed one gets one line instead, naming both versions: restart Claude Code (exit 10).

The kit run `kit:coordinator-bootstrap` can do steps 1 and 2 in one run the owner signs (skill `coordinator-bootstrap`).

**After a plugin upgrade.** An upgrade needs nothing while the installed launcher copy can run the new version: it picks the registry's latest entry. When it cannot (a copy installed before the version directories named after a git commit refuses them all), every baton is refused until step 1 runs again from the installed vibemaestro-sdlc, then step 3. The check names that case first, and so does SessionStart, before the first baton fails; `kit:plugin-update` prints both steps itself after it updates the plugins. A session started before the update still runs the older plugin: its check says restart Claude Code, and never offers that plugin's launcher.

**The split.** Allow the launcher's `new`, `check`, `rehearse`, `run`, `go`, `list`, `pack`, `log` and `sign --by coordinator-auto`. Ask for `sign --by owner` and `mode`, in every spelling of the command. Deny Claude Code's write tools on the whole plugins directory of the Claude Code config (the cache and `installed_plugins.json` the launcher trusts) and on the state directory. The same block turns Claude Code's attribution off (no co-author trailer, no PR line, no session URL).

**Why it is safe.** `run` is gated by the signature. `coordinator-auto` is refused by `baton.py` itself outside mode `auto` and for any run whose `Stops` is not `none`, so the session can sign only what the owner's standing rule already allows. The owner's signature and the mode always open a dialog. An allow rule on a command is only as safe as what it runs is unwritable, which the deny rules keep. The rules name the launcher because a permission rule cannot match "any version" in the middle of a path. SessionStart says in one line when the check fails.

