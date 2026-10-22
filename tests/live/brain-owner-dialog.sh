#!/bin/bash
# =============================================================================
# LIVE (not in CI): does Claude Code show the brain's owner dialog, per permission mode, and does an approval write the item?
# =============================================================================
# Run, from this repository's checkout, on a machine where `claude` is logged in and `tmux` is installed:
#     bash tests/live/brain-owner-dialog.sh            about 13 runs, under 15 minutes
#     bash tests/live/brain-owner-dialog.sh --plan     list the runs and their expectations; starts nothing
#     bash tests/live/brain-owner-dialog.sh --only default/no-allow
#     bash tests/live/brain-owner-dialog.sh --rehearse-trust   answer the real folder-trust dialog in a scratch config (no login)
#     bash tests/live/brain-owner-dialog.sh --pick-key REGEX < screen   the key a menu needs (the suite's check of the choice)
# rc 0 PASS, 1 FAIL, 2 stopped before any session (the reason is printed), 3 INCOMPLETE (no failure, but a gating run was
# skipped: auto not offered, or bypassPermissions never accepted on this machine; the owner may accept it once and re-run with
# --only bypassPermissions).
#
# Each run is a fresh interactive session (`--model haiku`) in a 400-column tmux pane, with this checkout's
# brain loaded by --plugin-dir, told to run one literal `brain owner add …` command. The script watches the pane: on the
# brain's dialog line it chooses the plain Yes by its text (arrows, then Enter) while the owner watches; it then reads the store (was the item
# written?) and the Episode Log (what did guard-owner decide, in which mode?). One PASS/FAIL/SKIP/INFO line per run, then a
# markdown table for the PR body, then the verdict.
#
# What it touches: a scratch directory (project and XDG_STATE_HOME), removed at the end. Claude Code itself also writes, in
# the owner's own config, what any session in a new folder writes: the folder's entry in ~/.claude.json (the trust answer the
# script gives by choosing the dialog's Yes line) and the sessions' transcripts under ~/.claude/projects/. The script never accepts the
# bypassPermissions warning for the owner: a run that meets it is SKIP. Default-mode runs pass no --permission-mode (2.1.290
# lists `manual`, not `default`); every other mode is checked against `claude --help` first, and a mode not listed is SKIP.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
BRAIN="$ROOT/plugins/vibemaestro-brain"
RUN_SECS=60                     # a run with no decision by then is `timeout`
TAG=7f3a

# name | mode | allow rule | environment | expectation (ask: dialog shown, line whole, written; deny: no dialog, not
# written; print: not written; control: the brain's line never shows, not written; info: not written, dialog recorded)
RUNS="default/no-allow|default|no||ask
default/allow|default|yes||ask
acceptEdits/no-allow|acceptEdits|no||ask
acceptEdits/allow|acceptEdits|yes||ask
auto/no-allow|auto|no||ask-auto
auto/allow|auto|yes||ask-auto
dontAsk|dontAsk|no||deny
plan|plan|no||deny
bypassPermissions|bypassPermissions|no||deny
print/-p|default|no||print
control/brain-off|default|no|BRAIN_OFF=1|control
info/plan-switch|plan|no|BRAIN_TEST=1 BRAIN_TEST_ASK_MODES=plan,bypassPermissions|info
info/bypass-switch|bypassPermissions|no|BRAIN_TEST=1 BRAIN_TEST_ASK_MODES=plan,bypassPermissions|info"

# Menu options are chosen by their text and the cursor, never by position: Claude Code 2.1.290 and 2.1.302 list `❯ No, exit`
# first in the folder-trust dialog
TRUST_RE='^Yes, (I trust this folder|proceed)'
YES_RE='^Yes$'                          # the plain Yes: never "Yes, and don't ask again", which would write an allow rule
TRUST_SCREEN='trust (the files in )?this folder|Do you trust'
CLAUDE_BIN=$(command -v claude 2>/dev/null || true)   # a tmux pane gets the tmux server's PATH, not this one: run this binary
case "$CLAUDE_BIN" in /*|"") ;; *) CLAUDE_BIN="$(cd "$(dirname "$CLAUDE_BIN")" && pwd -P)/$(basename "$CLAUDE_BIN")" ;; esac
CLAUDE_Q=$(printf '%q' "$CLAUDE_BIN")                 # safe in a generated script, whatever the path holds
RT=""                                                 # the rehearsal's scratch directory, removed by the trap
trap 'tmux kill-session -t brain-trust 2>/dev/null; [ -n "$RT" ] && rm -rf "$RT"' EXIT

pick_key() {  # pick_key REGEX < screen → Enter | Down | Up | <digit> | none
  python3 -c '
import re, sys
want = re.compile(sys.argv[1])
lines = sys.stdin.read().splitlines()
CUR = re.compile(r"^\s*([❯›>])\s+(.*)$")
NUM = re.compile(r"^\s*(?:[❯›>]\s+)?(\d+)\.\s")
def text(l):
    m = CUR.match(l)
    t = m.group(2) if m else l.strip()
    return re.sub(r"^\d+\.\s+", "", t).strip()
match = [i for i, l in enumerate(lines) if want.search(text(l))]
strong = [i for i, l in enumerate(lines) if CUR.match(l) and CUR.match(l).group(1) in "❯›"]
weak = [i for i, l in enumerate(lines) if CUR.match(l) and CUR.match(l).group(1) == ">"]
num = [NUM.match(lines[t]) for t in match if NUM.match(lines[t])]
def nearest(cur):
    # the menu cursor is the one nearest a matching option (an empty input line elsewhere is not)
    pairs = sorted((abs(t - c), -c, t, c) for c in cur for t in match if abs(t - c) <= 8)
    return pairs[0][2:] if pairs else None
# a `>` line is the cursor only when nothing better exists: it is also how a quoted prompt line looks
pick = nearest(strong) or (None if num else nearest(weak))
if pick:
    t, c = pick
    print("Enter" if t == c else "Down" if t > c else "Up")
else:
    print(num[0].group(1) if num else "none")
' "$1"
}

choose() {  # choose SESSION REGEX → 0 when the option was confirmed; at most 8 keys
  local k i j before after
  for i in 1 2 3 4 5 6 7 8; do
    before=$(tmux capture-pane -p -t "$1" 2>/dev/null)
    k=$(printf '%s\n' "$before" | pick_key "$2")
    case "$k" in
      Up|Down)
        tmux send-keys -t "$1" "$k"
        for j in $(seq 1 20); do                      # wait for the redraw: a stale screen would send a second arrow,
          sleep 0.1                                   # and the menu wraps
          after=$(tmux capture-pane -p -t "$1" 2>/dev/null)
          [ "$after" != "$before" ] && break
        done ;;
      Enter|[0-9]) tmux send-keys -t "$1" "$k"; return 0 ;;
      *) return 1 ;;                                  # none, or nothing at all (python failed): never a blind key
    esac
  done
  return 1
}

screen_summary() {  # screen_summary < capture → its non-blank lines but the footer, joined, cut at 300 characters
  grep -v '^ *$' | grep -v 'Enter to confirm' | grep -v '^[─━ ]*$' | tail -n 8 | sed 's/^ *//' | tr '\n' '|' | cut -c1-300
}

rehearse_trust() {  # answer the real trust dialog of `claude` in a scratch config; prints one line; rc 0 when it held
  local s i dead trusted
  RT=$(mktemp -d); RT=$(cd "$RT" && pwd -P); mkdir -p "$RT/cfg" "$RT/folder"
  printf '{"hasCompletedOnboarding": true, "theme": "dark"}\n' > "$RT/cfg/.claude.json"
  printf "sleep 1\ncd %q || exit 1\nexport CLAUDE_CONFIG_DIR=%q\nexec %s --model haiku\n" "$RT/folder" "$RT/cfg" "$CLAUDE_Q" > "$RT/run.sh"
  tmux kill-session -t brain-trust 2>/dev/null
  tmux new-session -d -s brain-trust -x 200 -y 50 "bash '$RT/run.sh'"
  tmux set-option -t brain-trust remain-on-exit on >/dev/null 2>&1
  s=""
  for i in $(seq 1 30); do
    sleep 1; s=$(tmux capture-pane -p -t brain-trust 2>/dev/null)
    printf '%s' "$s" | grep -qiE "$TRUST_SCREEN" && break
  done
  if ! printf '%s' "$s" | grep -qiE "$TRUST_SCREEN"; then
    echo "trust rehearsal: no trust dialog within 30 s; the screen: $(printf '%s\n' "$s" | screen_summary)"
    return 1
  fi
  if ! choose brain-trust "$TRUST_RE"; then
    echo "trust rehearsal: no Yes line this script understands; the screen: $(printf '%s\n' "$s" | screen_summary)"
    return 1
  fi
  sleep 3
  dead=$(tmux display-message -p -t brain-trust '#{pane_dead}' 2>/dev/null)
  [ -n "$dead" ] || dead=1                            # no pane any more: it died
  trusted=$(python3 -c 'import json, os, sys
d = json.load(open(sys.argv[1])).get("projects") or {}
print("yes" if any(os.path.realpath(k) == os.path.realpath(sys.argv[2]) and v.get("hasTrustDialogAccepted") for k, v in d.items()) else "no")' "$RT/cfg/.claude.json" "$RT/folder" 2>/dev/null)
  if [ "$dead" != 1 ] && [ "$trusted" = yes ]; then echo "trust rehearsal: ok (claude still running, the folder recorded as trusted)"; return 0; fi
  echo "trust rehearsal: FAILED (claude exited: $([ "$dead" = 1 ] && echo yes || echo no), trust recorded: ${trusted:-no})"; return 1
}

PLAN=0; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --plan) PLAN=1 ;;
    --only) ONLY=${2:-}; shift ;;
    --pick-key) K=$(pick_key "${2:-}"); [ -n "$K" ] || exit 1; echo "$K"; exit 0 ;;
    --rehearse-trust)
      command -v claude >/dev/null && command -v tmux >/dev/null || { echo "trust rehearsal: needs claude and tmux" >&2; exit 2; }
      rehearse_trust; exit $? ;;
    *) echo "usage: bash tests/live/brain-owner-dialog.sh [--plan] [--only RUN] [--rehearse-trust] [--pick-key REGEX]" >&2; exit 2 ;;
  esac
  shift
done

if [ "$PLAN" = 1 ]; then
  echo "runs (name | mode | allow rule | environment | expectation):"
  printf '%s\n' "$RUNS" | sed 's/^/  /'
  echo "ask: hook asks, the dialog line shows whole on one row, its plain Yes is chosen, the item is written"
  echo "ask-auto: as ask on Claude Code 2.1.211 or later, else as deny; SKIP when auto mode is not offered"
  echo "deny: no brain dialog, nothing written; print: nothing written; control: the brain's line never shows, nothing written"
  echo "info: nothing written (gating, owner condition), dialog shown or not recorded"
  exit 0
fi

stop() { echo "STOPPED: $*" >&2; exit 2; }

# --- preflight ------------------------------------------------------------------------------------------------------------------
command -v claude >/dev/null || stop "\`claude\` is not on PATH"
command -v tmux >/dev/null || stop "\`tmux\` is not installed (the runs need a terminal pane to watch)"
[ -n "${BRAIN_OFF:-}" ] && stop "BRAIN_OFF is set in this shell"
TR=$(rehearse_trust) || stop "$TR (the runs would die at Claude Code's folder-trust dialog)"
echo "$TR"
VER=$(claude --version 2>/dev/null | head -n 1)
MODES=$(claude --help 2>/dev/null | tr -d '\n' | sed -n 's/.*--permission-mode[^(]*(choices: \([^)]*\)).*/\1/p' | tr -d ' "')
echo "permission modes offered: ${MODES:-unknown}"
echo "Claude Code: ${VER:-unknown}"
NEW=$(python3 -c 'import re, sys
m = re.search(r"(\d+)\.(\d+)\.(\d+)", sys.argv[1])
print("yes" if m and tuple(map(int, m.groups())) >= (2, 1, 211) else "no")' "$VER")
W=$(mktemp -d); W=$(cd "$W" && pwd -P)
trap 'tmux kill-session -t brain-live 2>/dev/null; tmux kill-session -t brain-trust 2>/dev/null; rm -rf "$W"; [ -n "$RT" ] && rm -rf "$RT"' EXIT
P="$W/proj"; mkdir -p "$P"; git -C "$P" init -q
python3 - <<'PY' || stop "an installed, enabled vibemaestro-brain with hooks is in the Claude Code config: its guard would void this run's records; disable it for the run"
import json, os, sys
cfg = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
def load(p):
    try:
        return json.load(open(p))
    except (OSError, ValueError):
        return {}
enabled = load(os.path.join(cfg, "settings.json")).get("enabledPlugins") or {}
for key, entries in (load(os.path.join(cfg, "plugins", "installed_plugins.json")).get("plugins") or {}).items():
    if key.split("@")[0] == "vibemaestro-brain" and enabled.get(key) is True:
        if any(os.path.isfile(os.path.join(e.get("installPath", ""), "hooks", "hooks.json")) for e in entries or []):
            sys.exit(1)
PY
DOC=$(cd "$P" && XDG_STATE_HOME="$W/doctor" "$BRAIN/bin/brain" doctor 2>&1)
ANS=$(printf '%s\n' "$DOC" | grep -E 'PermissionRequest|permission-prompt-tool' || true)
[ -n "$ANS" ] && stop "something can answer the permission prompt in place of a human, so owner items are refused here: $ANS"
echo "logged-in check (one short -p call)…"
OK=$(cd "$P" && timeout 90 claude -p --model haiku "Reply with the single word ready." 2>&1 | tr -d '\r')
case "$OK" in *ready*|*Ready*) ;; *) stop "\`claude -p\` did not answer (not logged in?): ${OK:0:200}" ;; esac

# --- one run --------------------------------------------------------------------------------------------------------------------
pane() { tmux capture-pane -p -t brain-live 2>/dev/null; }
store_written() {  # store_written <state home> → yes|no
  python3 - "$1" <<'PY'
import glob, json, os, sys
for p in glob.glob(os.path.join(sys.argv[1], "vibemaestro", "brain", "*", "hot.jsonl")):
    for l in open(p):
        if json.loads(l).get("op") == "owner-add":
            print("yes"); sys.exit()
print("no")
PY
}
hook_seen() {  # hook_seen <state home> → "<decision> <mode>" of the last owner-call line, or "none -"
  python3 - "$1" <<'PY'
import glob, json, os, sys
last = None
for p in glob.glob(os.path.join(sys.argv[1], "vibemaestro", "brain", "*", "episodes.jsonl")):
    for l in open(p):
        o = json.loads(l)
        if o.get("kind") == "owner-call":
            last = o
print("%s %s" % (last["decision"], last.get("mode")) if last else "none -")
PY
}

N=0; FAILS=0; SKIPS=0; TABLE="| Run | Hook (mode seen) | Dialog shown | Line whole | Written | Verdict | Note |
|---|---|---|---|---|---|---|"
one() {  # one <name> <mode> <allow> <env> <expect>
  local name=$1 mode=$2 allow=$3 envs=$4 expect=$5 st="$W/state-$N" text line cmd prompt seen dialog=no whole=- written note="" t
  N=$((N+1))
  text="Live dialog check $name $TAG"
  line="Pin owner decision D1, from \"live test\": \"$text\""
  cmd="brain owner add --kind decision --text '$text' --owner-quote 'live test quote' --where 'live test'"
  prompt="Run exactly this one Bash command, unchanged, and nothing else. Then stop. Command: $cmd"
  mkdir -p "$st"; rm -rf "$P/.claude"
  printf '%s' "$prompt" > "$W/prompt"
  local flag="--permission-mode $mode"
  [ "$mode" = default ] && flag=""
  if [ "$mode" != default ] && [ -n "$MODES" ] && ! printf ',%s,' "$MODES" | grep -qF ",$mode,"; then
    printf '%-5s %-22s mode %s is not offered by this claude\n' SKIP "$name" "$mode"
    TABLE="$TABLE
| $name | - | - | - | - | SKIP | mode not offered |"; [ "$expect" = info ] || SKIPS=$((SKIPS+1)); return
  fi
  if [ "$allow" = yes ]; then mkdir -p "$P/.claude"; printf '{"permissions":{"allow":["Bash(brain owner add *)"]}}\n' > "$P/.claude/settings.json"; fi
  {
    echo "sleep 1"                          # lets remain-on-exit land before a claude that exits at once
    echo "cd '$P' || exit 1"
    echo "export XDG_STATE_HOME='$st' PATH='$BRAIN/bin':\"\$PATH\""
    for e in $envs; do echo "export $e"; done
  } > "$W/run.sh"
  if [ "$expect" = print ]; then
    echo "exec $CLAUDE_Q -p --model haiku $flag --plugin-dir '$BRAIN' \"\$(cat '$W/prompt')\"" >> "$W/run.sh"
    t=$(timeout 150 bash "$W/run.sh" 2>&1 | tr -d '\r' | tr '\n' ' ')
    case "$t" in *"permission dialog"*) note="Claude read the refusal sentence" ;; *"Pin owner decision"*) note="Claude read the dialog line" ;; *) note="Claude read: ${t:0:80}" ;; esac
  else
    echo "exec $CLAUDE_Q --model haiku $flag --plugin-dir '$BRAIN' \"\$(cat '$W/prompt')\"" >> "$W/run.sh"
    tmux kill-session -t brain-live 2>/dev/null
    tmux new-session -d -s brain-live -x 400 -y 60 "bash '$W/run.sh'"   # one quoted path: any login shell runs it
    tmux set-option -t brain-live remain-on-exit on >/dev/null 2>&1   # a session that exits (a refused mode) stays readable
    local end=$((SECONDS + RUN_SECS)) after=0 trusted=0 s
    while [ $SECONDS -lt $end ]; do
      sleep 1
      s=$(pane)
      if [ "$(tmux display-message -p -t brain-live '#{pane_dead}' 2>/dev/null)" = 1 ] && [ "$dialog" = no ] && [ $after = 0 ]; then
        note="claude exited: $(printf '%s' "$s" | grep -v '^ *$' | tail -n 1 | cut -c1-80)"; dialog=exited; break
      fi
      case "$s" in *"Bypass Permissions mode"*"accept"*) note="bypassPermissions needs a one-time acceptance on this machine; not accepted"; dialog=skip; break ;; esac
      if [ $trusted = 0 ] && printf '%s' "$s" | grep -qiE "$TRUST_SCREEN"; then
        choose brain-live "$TRUST_RE" || note="the trust dialog had no Yes line this script understands"; trusted=1; continue
      fi
      if [ "$dialog" = no ] && printf '%s' "$s" | grep -qF "\": \"$text\""; then
        dialog=yes
        printf '%s\n' "$s" | grep -qF -- "$line" && whole=yes || whole=no
        sleep 1; choose brain-live "$YES_RE" || note="no plain Yes in the brain dialog"; after=$((SECONDS + 20)); continue
      fi
      if [ "$dialog" = no ] && printf '%s' "$s" | grep -q 'Do you want to proceed'; then
        choose brain-live "$YES_RE" || note="no plain Yes in the permission prompt"; [ $after = 0 ] && after=$((SECONDS + 15)); continue
      fi
      if [ "$(store_written "$st")" = yes ]; then break; fi
      case "$s" in *"pinned D1"*|*"brain: owner items"*|*"brain: write one"*) [ $after = 0 ] && after=$((SECONDS + 3)) ;; esac
      seen=$(hook_seen "$st")
      if [ "${seen%% *}" = deny ] && [ $after = 0 ]; then after=$((SECONDS + 8)); fi
      if [ $after -gt 0 ] && [ $SECONDS -ge $after ]; then break; fi
    done
    tmux kill-session -t brain-live 2>/dev/null
  fi
  written=$(store_written "$st"); seen=$(hook_seen "$st")
  local verdict=PASS want=$expect
  if [ "$expect" = ask-auto ]; then
    if [ "${seen#* }" != auto ] && [ "${seen%% *}" != none ]; then verdict=SKIP; note="auto mode not offered (the hook saw ${seen#* })"; fi
    [ "$NEW" = yes ] && want=ask || want=deny
  fi
  if [ "$dialog" = exited ]; then dialog=no; [ "$expect" = ask-auto ] && verdict=SKIP || verdict=FAIL
  elif [ "$dialog" = skip ]; then verdict=SKIP; dialog=no
  elif [ "$verdict" != SKIP ]; then
    case "$want" in
      ask) [ "${seen%% *}" = ask ] && [ "$dialog" = yes ] && [ "$whole" = yes ] && [ "$written" = yes ] || verdict=FAIL ;;
      # a deny row does not require the hook's deny: in plan mode Claude may never run the command. A dead hook still cannot
      # pass the whole run, since every ask row requires the hook's ask.
      deny) [ "$dialog" = no ] && [ "$written" = no ] || verdict=FAIL
            [ "${seen%% *}" = none ] && note="the hook saw no owner call (Claude did not run it, or the mode stopped it first) $note" ;;
      print) [ "$written" = no ] || verdict=FAIL ;;
      control) [ "$dialog" = no ] && [ "$written" = no ] && [ "${seen%% *}" = none ] || verdict=FAIL ;;
      info) [ "$written" = no ] && verdict=INFO || verdict=FAIL ;;
    esac
    [ "$verdict" = FAIL ] && [ "${seen%% *}" = none ] && [ "$want" = ask ] && [ $SECONDS -ge "${end:-0}" ] && note="timeout: the hook saw no owner call ${note}"
  fi
  [ "$verdict" = FAIL ] && FAILS=$((FAILS+1))
  [ "$verdict" = SKIP ] && [ "$expect" != info ] && SKIPS=$((SKIPS+1))
  printf '%-5s %-22s hook=%-6s mode=%-17s dialog=%-3s whole=%-3s written=%-3s %s\n' "$verdict" "$name" "${seen%% *}" "${seen#* }" "$dialog" "$whole" "$written" "$note"
  TABLE="$TABLE
| $name | ${seen%% *} (${seen#* }) | $dialog | $whole | $written | $verdict | $note |"
}

echo "runs (each under ${RUN_SECS} s; watch with: tmux attach -r -t brain-live):"
while IFS='|' read -r name mode allow envs expect; do
  [ -n "$ONLY" ] && [ "$ONLY" != "$name" ] && continue
  one "$name" "$mode" "$allow" "$envs" "$expect"
done <<<"$RUNS"
[ "$N" -gt 0 ] || stop "no run named '$ONLY'"
echo
echo "$TABLE"
echo
if [ "$FAILS" -eq 0 ] && [ "$SKIPS" -eq 0 ]; then echo "PASS ($N runs, Claude Code ${VER:-unknown})"; exit 0; fi
if [ "$FAILS" -eq 0 ]; then echo "INCOMPLETE ($SKIPS of $N runs skipped, none failed, Claude Code ${VER:-unknown})"; exit 3; fi
echo "FAIL ($FAILS of $N runs failed, Claude Code ${VER:-unknown})"; exit 1
