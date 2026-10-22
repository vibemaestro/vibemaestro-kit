English | [Tiếng Việt](batonrun.vi.md)

# BatonRun

BatonRun is the method vibemaestro uses for every action that writes outside the session: a GitHub write, a registry push, a change to the user's Claude Code settings, a deletion, a change on a live system. This document is the **standard**: the single source for what BatonRun is, how a run works, and where its limits are. Everything else points here:

- the skill `batonrun` ([`plugins/vibemaestro-sdlc/skills/batonrun/`](../skills/batonrun/SKILL.md)) holds the **operating instructions**: the commands, the script skeleton, what `check` refuses, the exit codes, and keeping or changing a run. This document ships in the installed plugin (`docs/batonrun.md` in the plugin root), but the skill keeps every instruction a session needs, the stop list included, so a session does not have to read it;
- the rule `batonrun` (`plugins/vibemaestro-sdlc/rules/batonrun.instructions.md`) is a **reminder** when a privileged command is typed directly;
- the runner [`plugins/vibemaestro-sdlc/scripts/baton.py`](../scripts/baton.py) is the **machine**: when the code and this text disagree, the code is what runs, and the disagreement is a bug in one of them.

The measurements and lessons behind the design are in [`docs/research/batonrun.md`](../../../docs/research/batonrun.md). For the whole kit, start at the [README](../../../README.md).

## 1. What BatonRun is

### Definition

The owner is the person who owns the repository and signs the risky runs: working alone, that is you. A **run** is one action run of a repeated workflow: many commands or scripts in a fixed series, executed as one gated block. The session writes or picks the run, the machine checks and rehearses it, it is signed once, the session runs it, the machine post-checks it, undoes it on failure, and logs it. The owner is never handed command lines to type.

- **One run, one gate.** The series is shown, signed and run as a whole: the signature covers every step of it, so nothing in the series runs unsigned and nothing outside it runs signed.
- **The smallest run is a single privileged write** (one comment, one merge, one push). A single write still goes through a run: it costs no more per write than the direct way (section 7).
- **A run is carried by one baton script.** The script holds the series; the commands and plugin scripts it calls are its steps (`kit:merge-pr` runs the merge guard; a session baton may run `open-pr.sh` as one of its writes). The script is the unit of checking and signing; the run is the unit of work and of the log.
- **Repeated is the point.** A workflow that recurs with the same commands becomes a named run, kept and reused (section 4), so the next time it is one command, not a script written again.

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
| session baton | a baton script the session writes for the task in hand, at a fresh path |
| kind | a ready baton script the plugin ships for a repeated shape, run as `kind:<name> <args>`; `new --from <kind>` writes it to a file to change it |
| kit run | a baton script the plugin ships and reviews, run as `kit:<name> …`; only a kit run may run one of the plugin's gates |
| library run | a run kept on one machine for a workflow done twice, run again by name (section 4) |
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
| write | the session writes the baton script (or picks a kind or kit run): header (Purpose, Targets, Blast, Undo, Pre, Stops, Expect), the act with every change through `write()`, a post-check, an undo | the act stated before it runs |
| check | static checks of the text: header fields, the exact `write()` gate and phase dispatch, `set -euo pipefail`, no write outside `write()`, no local script or `source`, no unguarded `diff`/`grep`/`cmp` in a pipeline, stop patterns against `Stops`, `bash -n`, `shellcheck -S error` where installed | syntax and shape errors, a write that would skip the gate, an undeclared stop act |
| rehearse | the script runs in phase `rehearse`: every read runs, every write only prints its plan line; the plan is compared with Expect line by line | logic errors, a wrong target, a missing precondition, a plan that is not what was meant |
| seal | the hash over script bytes, arguments, directory, the variables that steer the tools, and the plan | any change after this point |
| sign | the seal is approved, by the session (`coordinator-auto`, only mode `auto` and `Stops: none`) or by the owner in a dialog | an approval of something other than what was shown |
| run | rehearse again, then phase `run`: each write's DO line must be the signed plan; the signature is used up | a world that moved since signing, a second run |
| post-check with undo | phase `postcheck` (read again after 1, 2, 4 and 8 s); on failure phase `undo`, which compares every target with its before-state | a write that did not hold; a half-done state left behind |
| log | one line per event in `log.tsv` (time, event, name, script hash, binding, arguments, directory, signer, mode, result, undone, output path); the full output under `runs/` | an unaudited act |

**`go`** runs the steps from check to log in one command and stops at the first that fails, with that step's exit code and whole output. When every step holds it prints one line, `go: ok — <n> writes — <run log>`, which is all the session reports. A run that needs the owner (a Stops word, or mode `manual`, also when no mode was chosen yet: section 6) stops after rehearse with exit 8 and the facts for the decision card; nothing is signed and nothing runs. The separate commands (`check`, `rehearse`, `sign`, `run`, `log`) stay for the owner's signature and for diagnosis.

`go` runs a session baton (and reads the `--spec` file of `kit:gh-write` and the rules file of `kind:settings-merge`) only from a file written in the last 120 s, so a Write that did not land is not mistaken for the new script; `go --reuse` names an older file whose bytes are meant again. A session baton is a Write to a fresh path and `go <path>` in the same response. The form `go -` also exists, but it is not the way to run a baton, because Claude Code blocks a heredoc that holds the baton skeleton and a heredoc is the only way to feed it (section 8). It reads the script from stdin, stores it once under the state directory and runs that file, so the same sha256 binding holds from check to run.

### Commands

Each command is `<launcher> <subcommand> …`. Until the launcher is installed (section 9) use `python3 <plugin root>/scripts/baton.py` instead. The runner's own options come before the script path; everything after the path is the script's own arguments.

| Command | What it does |
|---|---|
| `new <name> [--dir D] [--from <kind>]` | writes `D/<name>.sh` from the template, or from a kind (`new --from <kind>`); never overwrites (exit 6) |
| `check <script>` | the static checks of the text; exit 0 or 1 |
| `rehearse <script> [args…]` | check, then the rehearse phase; prints the plan against Expect and the seal |
| `sign --by owner\|coordinator-auto --seal <seal> <script> [args…]` | check, the mode policy, rehearse again, then the signature record; `--by` comes first, once, as two words; a seal that is not the one shown is refused (exit 3) |
| `run <script> [args…]` | the signed run: rehearse again, run, post-check, undo on failure; one line `run: ok — <n> writes — <run log>` when it holds |
| `go [--by coordinator-auto] [--reuse] <script> [args…]` | check, rehearse, seal, sign, run, post-check and log in one command; the lifecycle above. `<script>` is a path, `kind:<name>` or `kit:<name>`. `go -` takes the script from stdin: never use it for a baton, Claude Code blocks it |
| `log [--tail N]` | the last N lines of `log.tsv` (default 20) |
| `log --last` | the path of the newest run log; it is set before the script starts, so a run that was killed is found here |
| `log --wait-names N1,N2,… [--timeout S] [--since T]` | waits (at most 580 s) until the latest run line of each named script is ok; exit 9 at the deadline |
| `mode [manual\|auto]` | prints the approval mode, or sets it (section 6) |
| `permissions --print` | prints the user-settings block for this install (section 9) |
| `permissions --check [--settings F]…` | checks the rules in force against that block; writes nothing; exit 7 when a rule is missing, stale or unsafe |
| `permissions --install-launcher` | copies the launcher to `<state-dir>/bin/baton` |
| `help [<topic>]` | prints the command summary, or one reference file of the skill: `act`, `kinds`, `kits`, `modes`, `permissions`, `setup`, `limits` |

### Exit codes

| Code | Meaning |
|---|---|
| 0 | done |
| 1 | the script fails check or rehearse (no verdict line, plan differs from Expect), or `go` found a stale file |
| 2 | environment: no `bash`, or the state directory cannot be written |
| 3 | refused, nothing ran: no signature matches, the mode does not allow the signer, or the command stopped before the run phase |
| 4 | the run or its post-check failed, and undo put the state back |
| 5 | the state is unknown: the run failed and undo failed too, or the run was interrupted; tell the owner at once |
| 6 | `new`: the file already exists |
| 7 | `permissions --check`: a rule is missing, stale or unsafe |
| 8 | `go`: the baton needs the owner's signature; nothing was signed, nothing ran |
| 9 | `log --wait-names`: a named script has no ok run line by the deadline |
| 64 | bad usage |
| 66 | the script cannot be read, or `log --last` before any run has started |

### The header

Every baton script starts with these fields, one line each. `check` refuses a missing field, a field given twice and an empty `Expect`; `Each` is for kit scripts only and stands in for the `Expect` lines.

| Field | What it says |
|---|---|
| `Purpose` | what the run does, in one sentence; a session searches this line when it looks for a kept run |
| `Targets` | what it touches |
| `Blast` | the most it can change |
| `Undo` | how it is put back, or what it leaves behind |
| `Pre` | what must hold before it runs |
| `Stops` | `none`, or one or more stop-list words (section 6); the owner signs when it is not `none` |
| `Expect` | one line per write, a shell glob over the whole plan line, in order (below) |
| `Each` | kit scripts only: one glob for every plan line, for a run whose number of writes comes from its input (`kit:gh-write`) |

**How Expect matches.** Rehearse collects one plan line per `write()` call, in the order they ran, and compares the i-th with the i-th `Expect` line as a shell glob over the whole line, case-sensitive. `*` is any run of characters (spaces and `/` too), `?` one character. It is not a prefix match, and the counts must be equal: a missing or an extra line is a FAIL row. For example the plan `create docs/a b.txt` matches `create *`; the plan `create docs/a.txt` does not match `create`.

### The skeleton

A baton script that passes `check`. Replace the header, the act, the post-check and the undo; copy `write()`, `gh_state()` and the final `case` unchanged. To ask whether a GitHub object exists, call `gh_state <api path>` as a statement, then test `$GH_STATE` (`exists` or `absent`; anything else stops the script).

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

### Try it

This runs the skeleton end to end in a scratch state directory. Run it in bash, from the root of a checkout of this repository, in one shell session. Save the skeleton above as `demo.sh` in the scratch directory, then run `go` within 120 s of saving it (or add `--reuse`).

```bash
BATON="python3 $PWD/plugins/vibemaestro-sdlc/scripts/baton.py"
export XDG_STATE_HOME="$(mktemp -d)"
DEMO="$(mktemp -d)"
# save the skeleton as "$DEMO/demo.sh", then:
cd "$DEMO"
$BATON check demo.sh
$BATON rehearse demo.sh "$DEMO/out.txt" hello
$BATON mode auto
$BATON go demo.sh "$DEMO/out.txt" hello
cat "$DEMO/out.txt"
$BATON log --tail 3
```

`XDG_STATE_HOME` points the mode, the signatures and the log at a throw-away directory, so the demo never changes your real approval mode. After `mode auto` the session may sign this `Stops: none` run itself, so `go` ends with one `go: ok` line and `out.txt` holds `hello`. In mode `manual` the same `go` stops after rehearse with exit 8 and the owner's decision card.

## 4. When a workflow becomes a run, and where runs live

**Every write outside the session is a run**, from the first time: there is no threshold below which a privileged write is typed directly. What the rule of two decides is whether the run is **kept**:

- **Done twice → a library run.** The second time a session writes the same series, it keeps the script as a library run on that machine and runs it by name from then on.
- **Used across sessions or repos → a kit run.** A library run that other sessions or other repos need proposes itself for the kit (below) and becomes a kit run or a kind, reviewed plugin code.
- A one-off series stays a session baton: written at a fresh path, run, logged, not kept.

**Where runs live.**

| Run | Lives in | Run as |
|---|---|---|
| kit run | `plugins/vibemaestro-sdlc/batons/<name>.sh` (versioned plugin code; the gates it runs are in `gates/`) | `<launcher> go kit:<name> …` |
| kind | `plugins/vibemaestro-sdlc/templates/baton-kinds/` | `<launcher> go kind:<name> <args>` |
| dependent plugin's run | that plugin's `batons/` (a plugin of the same marketplace that depends on `vibemaestro-sdlc`) | `<launcher> go kit:<name> …` (`help kits`: how it is found and trusted) |
| library run | `<library>` = `$XDG_DATA_HOME/vibemaestro/batons/`, else `~/.local/share/vibemaestro/batons/`: per machine, outside every repository | `<launcher> go --reuse <library>/<name>.sh …` |
| session baton | a fresh path the session writes (a scratch directory); never stdin (`go -` with a baton heredoc is blocked, section 8) | `<launcher> go <path> …` |

**The library** is a convention, not a command: the session keeps a run there with the Write tool (the state directory is closed to the write tools, the library is not) and runs it with `go --reuse`, because the file is older than the 120 s `go` wants of a fresh one. `--reuse` comes only after reading the file's sha256 and `Purpose:` line (a plain `go` on the old file prints both, with the exact `--reuse` command, and runs nothing), when those very bytes are meant. A library run is not reviewed code: every run of it is checked, rehearsed and signed like a session baton, it may not run a gate, and its `Stops:` decides who signs. Its arguments carry what changes between runs; it holds no secret and no value of one repository that its arguments could carry instead. A launcher name `lib:<name>` for it is not built.

**Naming and finding.** A run has a short kebab-case name that says what it does (`merge-pr`, `gh-write`, `ci-rerun-failed`), and its `Purpose:` header line says it in one sentence; that line is what a session searches when it looks for a run (`grep '^# Purpose:' <library>/*.sh`). The kit runs and kinds are listed in section 5. There is no command that lists them: `<launcher> help kits` and `<launcher> help kinds` print the skill's reference files for running them. A session that hands several runs to a subagent names them `<prefix>-<act>.sh` with a prefix of its own, so `log --wait-names` can wait for exactly those names.

**A run that was killed.** `run` and `go` print one line when they hold, so a run killed before it ends (SIGKILL, a tool timeout) prints nothing. Before the script starts, the runner writes a `run-start` line to `log.tsv` and the run log's path to `runs/LAST`; `<launcher> log --last` prints that path.

**How a library run proposes itself for the kit.** Open an issue in the kit's public repository that carries the script, what it does, how many runs the log shows and whether they held, and where else it is needed. A run for sdlc's own domain becomes a `kit:` run or a `kind:` in `vibemaestro-sdlc`. A run that belongs to a dependent plugin ships in that plugin's `batons/` and runs as `kit:<name>`, with every check of an sdlc kit; a name two plugins ship runs nowhere, so a kit name is unique across the plugins.

### How a run evolves

The rule: **a run stands for a workflow, so a changed workflow updates its run, never a forked copy.** The test is whether it is still the same workflow: the same purpose, targets and risk.

- A step needed every time: add it to the run.
- A step needed sometimes: an argument of the run. The signature binds the arguments, so the plan shows it.
- Another purpose or other targets, or a new Stops word: a new run with its own name.
- A step met for the first time: a session baton this once; the second time, fold it into the run (the rule of two applies to the change too).

Guards:

- A change within the same workflow that widens what the run touches updates its header. A new Stops word makes a new run (above), and the owner signs that run from then on.
- A kit run changes only through a kit PR; meanwhile the extra step runs as a separate run right after it.
- The signature binds the script's sha256 and the log records it, so which version of a run ran stays known.

## 5. The run catalogue

The kit runs and kinds, one line each. The skill names how to call them; the plugin version binds them into the signature.

| Run | What it does | Stops |
|---|---|---|
| `kit:merge-pr` | the guarded merge: rehearse is the guard's dry run (head pinned, CI, conflict, deny globs, the brief's globs, …), the run merges pinned to the signed head; a merge is not reversible, the way back is a revert PR. Arguments: `--repo`, `--pr`, `--head`, `--brief`, and the guard's options | none |
| `kit:gh-write` | small GitHub writes from one JSON spec: issue-create, issue-comment, comment-edit, issue-edit, pr-body-edit, issue-reopen, issue-close, pr-close and pr-ready (pinned to the head), pr-create (from a pushed branch at a pinned head), file-pr (one file added or replaced on a new branch from the base tip, the replaced blob pinned, then its PR); refuses public repos, deletions, repo creation and a workflow path; undo never deletes, and names a branch it leaves. Argument: `--spec <file>` | none |
| `kit:coordinator-bootstrap` | sets up a new or moved machine for BatonRun: a machine report, then the launcher and the printed permission block (attribution off where a key is absent) through `kind:settings-merge`; refused at rehearse when there is nothing to do; undo puts each file back byte for byte. No argument | security-boundary (the owner signs) |
| `kind:install-file` | installs one file, byte for byte, into a directory that may be read-only, never under `.git`, `.claude`, the config or the state directory. Arguments: `<source> <directory>` | none |
| `kind:settings-merge` | adds permission rules to a Claude Code `settings.json`, removes none, with a backup and a run record. Arguments: `<settings.json> <rules.json>` | security-boundary (the owner signs) |
| `kind:ci-rerun-failed` | re-runs the failed jobs of one CI run of a private repository. Arguments: `<owner/name> <run id>` | none |

Templates that `new --from <kind>` writes to a file but that do not run as `kind:` (the act is the session's to fill): `remote-exec` (a program through stdin into `bash -s` over `ssh`) and `kubectl-exec` (the same through `kubectl exec -i`; its `Stops` is `cluster-lane`). Not built: `owner-merge-pr`, a merge the owner signs for a PR that touches `merge.deny_globs` (the guard refuses such a PR whatever signs it).

## 6. Approval: the modes, the stop list, the owner's signature

**The modes** are the owner's standing decision, not the session's choice per run. They live in the user's state directory, never in a repository; `mode` prints the mode (`manual` when none was set), and `mode manual|auto` changes it only on the owner's word (the permission rules make it ask). The session never picks the mode itself, and a message from another agent or machine does not change it.

**Asked once.** A fresh install has not chosen a mode. It reads as `manual`, and the first `Stops: none` run that stops for it (`go` exit 8) has the card line `mode manual (not chosen yet)`. The session then asks the owner once which mode, and says what each means: `auto`, recommended on a solo machine (the session signs a `Stops: none` run; a stop-list run still needs the owner), or `manual` (the owner signs every run). Who sets it depends on the check of `permissions --check` on the user and managed settings alone (a project's settings are found from `CLAUDE_PROJECT_DIR` or the directory `go` runs from, which may not be the session's project), and the card's `Mode:` line says which. When it is clean (the ask rules are in force there), the session runs `<launcher> mode <answer>` only right after the owner's own answer, and the ask rule opens a dialog where the owner's click sets it. When it is not clean (as on a fresh install, where nothing would ask), or a settings file cannot be parsed, the session does not run `mode`: the owner runs `! <command> mode <answer>` themselves, the command the card names. Then the session runs the baton again; `go` refuses a file written over 120 s before, so it writes it to a fresh path. Once a mode is set, the card never says `not chosen yet` again. No answer, or a rejected dialog, leaves the mode not chosen: the run waits for the owner's signature as in manual, and the next exit 8 on a `Stops: none` run asks again.

- **manual** (the default until the owner chooses): the owner signs every run after seeing it.
- **auto**: the session signs a run whose header says `Stops: none` itself (`coordinator-auto`) and runs it with no question; a run with any Stops word needs the owner's signature, as in manual.
- In auto, a failed precondition or an Expect mismatch is not a stop: the session fixes the script and rehearses again, as long as the fix does not widen what the run touches. A fix that widens it needs the owner.

**The stop list.** A run that does any of these declares it in `Stops:`, and then only the owner signs, in every mode:

| Word | The run … |
|---|---|
| `irreversible-delete` | deletes data that cannot come back: volumes with data, namespaces, package versions, repositories, unmerged branches, tags, secret paths, databases |
| `secrets` | reads, prints, writes or rotates a secret |
| `security-boundary` | widens a boundary: RBAC, admission or network policy, making something public, an admin bypass outside an existing owner rule |
| `cluster-lane` | changes a live cluster outside an approved lane: suspending reconciliation, draining nodes |
| `history-rewrite` | force-pushes or rewrites history on a shared branch |
| `money-org` | touches billing, plans or organisation admin (create or rename a repository, members) |
| `publish` | posts outside: public places, other people's repositories |
| `no-way-back` | can be neither rehearsed nor undone |
| `owner-acts` | is an act an earlier owner decision names the owner as the one who does |

`check` flags a body line that looks like a stop act, naming the category, the word and the header to add; that lint is a backstop, not a proof: a run declares what it does, not what the lint finds. The lint knows only some cluster acts (`flux suspend`, `kubectl … drain|cordon`).

**The owner's signature** is the owner's click in a dialog: the session runs `sign --by owner --seal <seal> …`, the permission rules make that command ask, and the dialog shows it. When `go` stops with exit 8 it prints the facts for the owner (what the writes do, why, the blast, the undo, the stop reason, what was checked) and the two commands to run on the owner's go. A seal that no longer matches what was shown is refused. **No dialog shown, or a rejected one, means not confirmed**: the session records the run as pending and says so; it never retries `sign` in a loop and never reads silence as a yes.

**The decision card.** Right before the owner's dialog the session writes, in the owner's language, at most seven short lines: what it writes, where, why (the decision or the need), the impact, the undo (or "cannot be undone"), the one risk, and what was checked (check ok, rehearse ok, plan matches Expect, N writes). The `sign` command's description, which the dialog shows, is the card's first line; seals, paths and the rehearse output come after, as detail.

## 7. Cost

**The goal**: a run must cost no more than the direct way (tool calls, or a script the model writes and runs), with safety unchanged. On a success print only success; on a failure print the detail.

**Per write, a run is at parity with the direct way.** What remains is once per session: reading the skill takes 2 to 3 turns. The checks are machine checks and cost almost nothing; the cost is model turns and output kept in context, which is why `go` exists, why it prints one line, and why the skill's core is enough for a plain run. The comparisons behind this use small samples (2 to 3 per arm and task) run as subagents, and the direct arm's own turns vary by ±1 or more: read "parity", not "saving". The method and the numbers are in [`docs/research/batonrun.md`](../../../docs/research/batonrun.md).

**Running several runs.** In place by default, any number. Hand three or more to one worker subagent only to keep a large main context small (over about 400k tokens): delegation is cheaper only for a session's first multi-run task. The main session then waits on the log for the exact script names (`log --wait-names`), and trusts the log line, which is machine evidence, not the worker's report.

## 8. Limits

What baton does not guard:

- **Honest, not hostile.** BatonRun guards a fallible session, not a deceiving one (section 1). `check` reads the text; it does not run it, so an indirection that hides a run (`eval`, a name built at run time, a launcher behind a variable) is forgery, not a gap to work around.
- **The rule and the hook advise; they do not block.** The rule reminds once per session when a privileged command is typed directly, on the command line only. The hook warns on every launcher `sign`, `run` or `go` that is not bare (a pipe, a chain, a redirect, a substitution, a prefix or a shell wrapper), because the allow rules then do not match and Claude Code's auto-mode classifier decides.
- **Permission rules match the command text,** not what the shell makes of it, and Edit rules cover the write tools and the file commands Claude Code recognises, not any process. `permissions --check` reads the rules only: not `defaultMode`, a skip-permissions launch, or the classifier's settings.
- **A plugin script is trusted from the plugin root `baton.py` runs from,** only as the command of a write with its sha256 in the plan line; a `scripts/` changed during a phase is detected after it, not prevented.
- **What `go` cannot tell:** whether a fresh file holds what was meant (an Edit that did not apply), and anything about a file the script reads itself unless its sha256 is in a plan line.
- **A mode comes from the owner, not from a message.** A session cannot tell another agent or machine to change its approval mode.
- **`go -` with a baton is blocked by Claude Code.** In the default permission mode (tested with Claude Code 2.1.303, `-p --permission-mode default`, allow rule `Bash(<launcher> go:*)`) the allow rule matches a short `go -` heredoc, but a heredoc holding the baton skeleton is blocked before any rule applies, by the tool's own check ("Contains brace with quote character (expansion obfuscation)"), which fires on every `{ … }` function body that holds a quote (`write()`, `gh_state()`). Auto mode is not tested. Default is a supported mode, so the standard does not depend on auto: a session baton is a Write to a fresh path and `go <path>`. The check is the tool's safety check; the skeleton is not reshaped to dodge it. The hook stays silent on a quoted `go -` heredoc, though that is blocked for a baton, and names every other shape (an unquoted delimiter lets the shell expand the body before baton reads a byte; a line after the closing one is a command of its own).
- **A merge, a publish and the like cannot be undone.** The run says so in `Undo:`; when it fails after the world changed it ends with exit 5 and the owner is told at once.

## 9. Permission setup

Once per machine, the session runs three commands and the owner applies the result; the plugin never writes settings:

1. `permissions --install-launcher` copies the launcher to `<state-dir>/bin/baton`. It runs the newest installed vibemaestro-sdlc from the plugin cache and refuses any other `baton.py`.
2. `permissions --print` prints the user-settings block; the owner adds it through Claude Code's settings.
3. `permissions --check` says whether the rules in force hold the split (exit 0) or names each rule that is missing, stale or unsafe (exit 7).

The kit run `kit:coordinator-bootstrap` can do steps 1 and 2 in one run the owner signs (skill `coordinator-bootstrap`).

**The split.** Allow the launcher's `new`, `check`, `rehearse`, `run`, `go`, `log` and `sign --by coordinator-auto`. Ask for `sign --by owner` and `mode`, in every spelling of the command. Deny Claude Code's write tools on the whole plugins directory of the Claude Code config (the cache and `installed_plugins.json` the launcher trusts) and on the state directory. The same block turns Claude Code's attribution off (no co-author trailer, no PR line, no session URL).

**Why it is safe.** `run` is gated by the signature. `coordinator-auto` is refused by `baton.py` itself outside mode `auto` and for any run whose `Stops` is not `none`, so the session can sign only what the owner's standing rule already allows. The owner's signature and the mode always open a dialog. An allow rule on a command is only as safe as what it runs is unwritable, which the deny rules keep. The rules name the launcher because a permission rule cannot match "any version" in the middle of a path. A plugin upgrade needs nothing; SessionStart says in one line when the check fails.

