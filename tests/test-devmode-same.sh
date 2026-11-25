#!/bin/bash
# =============================================================================
# Developer mode stays as on main: each hook command of vibemaestro-sdlc, and the brain's SessionStart, PreCompact, PostCompact,
# prompt and guard hooks, run as Claude Code runs them (the `command` strings of hooks/hooks.json, through `bash -c`), in a
# developer repo with a remote and in one with git and no remote, prints byte for byte what it printed on main, with the same
# exit code.
# Run: bash tests/test-devmode-same.sh            compare with tests/fixtures/devmode-same/expected.txt
#      bash tests/test-devmode-same.sh --record   write that file (its first line names the commit it was recorded on)
# The expected file was recorded on main 1d0eab3, before the everyday mode (KIT-870). A change meant to alter developer-mode
# output records it again on its own branch, and its PR says why. Machine paths, session ids and times are normalized.
# =============================================================================
set -uo pipefail
if [ -z "${BRAIN_SUITE_REEXEC:-}" ]; then
  export PYTHONUSERBASE="${PYTHONUSERBASE:-$(python3 -m site --user-base 2>/dev/null)}"
  exec env -u CLAUDE_CONFIG_DIR BRAIN_SUITE_REEXEC=1 HOME=/nonexistent bash "$0" "$@"
fi
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
EXPECTED="$HERE/fixtures/devmode-same/expected.txt"
RECORD=0; [ "${1:-}" = --record ] && RECORD=1

TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
export VIBEMAESTRO_NO_UPDATE_CHECK=1
baton_set_mode "$XDG_STATE_HOME" manual        # the owner's mode wins over a machine policy file: the record is the same on any machine
# shellcheck source=fixtures/brain.sh
. "$HERE/fixtures/brain.sh"
brain_kit "$SRC_ROOT"                          # the brain and sdlc, isolated from this machine's account and managed settings
PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
SPL="$TMP/sdlc"; mk_plugin "$SPL"              # the real sdlc with stand-in rules: a rule's wording is not developer-mode behaviour

# A repo the way a developer has it: kb/, a decision, a commit, and (for `remote`) an origin it is pushed to.
mk_dev() {  # mk_dev <dir> <remote|local>
  mk_app "$1"
  if [ "$2" = remote ]; then
    git_ init -q --bare "$1.git"
    git_ -C "$1" remote add origin "$1.git"
    git_ -C "$1" push -q -u origin main
    git_ -C "$1" fetch -q origin
  fi
}

N=0
# run_all <label> <hooks.json> <plugin root> <repo> <event> <tool> <payload> — each command's exit code and stdout, in order
run_all() {
  local label=$1 hooks=$2 root=$3 repo=$4 ev=$5 tool=$6 in=$7 c i=0 out rc
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    i=$((i+1))
    out=$(cd "$repo" && printf '%s' "$in" | CLAUDE_PLUGIN_ROOT="$root" CLAUDE_PROJECT_DIR="$repo" CLAUDE_CODE_SESSION_ID=sDEV \
          bash -c "$c" 2>/dev/null); rc=$?
    printf '## %s cmd %d rc=%d\n%s\n' "$label" "$i" "$rc" "$out"
  done < <(hook_cmds "$hooks" "$ev" "$tool")
}

session() {  # session <repo> <kind> — one developer session's hooks, in the order Claude Code meets them
  local r=$1 k=$2 S="s${2}0000000001" B="$KIT/plugins/vibemaestro-brain" SH="$SPL/hooks/hooks.json" BH="$KIT/plugins/vibemaestro-brain/hooks/hooks.json"
  run_all "$k sdlc SessionStart startup" "$SH" "$SPL" "$r" SessionStart "" "{\"session_id\":\"$S\",\"cwd\":\"$r\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}"
  run_all "$k brain SessionStart startup" "$BH" "$B" "$r" SessionStart "" "{\"session_id\":\"$S\",\"cwd\":\"$r\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}"
  run_all "$k brain UserPromptSubmit" "$BH" "$B" "$r" UserPromptSubmit "" "{\"session_id\":\"$S\",\"cwd\":\"$r\",\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"fix the build\"}"
  run_all "$k sdlc SubagentStart" "$SH" "$SPL" "$r" SubagentStart general-purpose "{\"session_id\":\"$S\",\"cwd\":\"$r\",\"hook_event_name\":\"SubagentStart\",\"agent_type\":\"general-purpose\"}"
  run_all "$k sdlc SubagentStart Explore" "$SH" "$SPL" "$r" SubagentStart Explore "{\"session_id\":\"$S\",\"cwd\":\"$r\",\"hook_event_name\":\"SubagentStart\",\"agent_type\":\"Explore\"}"
  run_all "$k sdlc SessionStart not-json" "$SH" "$SPL" "$r" SessionStart "" "not json at all"
  run_all "$k brain SessionStart not-json" "$BH" "$B" "$r" SessionStart "" "not json at all"
  local f t in widen='{"permissions":{"allow":["Bash(curl:*)"]}}'
  # an edit of a source file, of the settings files (the sdlc guard) and of the brain's own store (the brain guard)
  for f in "$r/src/main.ts" "$r/clusters/x.yaml" "$r/docs/y.md" "$r/.claude/settings.json" "$HOME/.claude/settings.json" \
           "$XDG_STATE_HOME/vibemaestro/brain/x"; do
    for t in Edit Write NotebookEdit; do
      in=$(hin session_id="$S" cwd="$r" hook_event_name=PreToolUse tool_name="$t" \
           tool_input="$(hin file_path="$(wpath "$f")" notebook_path="$(wpath "$f")" old_string=a new_string=b content="$widen")")
      run_all "$k sdlc $t $f" "$SH" "$SPL" "$r" PreToolUse "$t" "$in"
      run_all "$k brain $t $f" "$BH" "$B" "$r" PreToolUse "$t" "$in"
    done
  done
  local cmd a
  for cmd in 'git status' 'git push origin main' 'lenh-bay now' 'nguy-hiem now' 'brain op add --kind now --text x' \
             'brain owner pin --text x' 'cd /tmp && brain owner pin --text x' 'brain import f.json'; do
    for a in "" ag1; do   # the main session, then a subagent (agent_id)
      in=$(hin session_id="$S" ${a:+agent_id=$a} cwd="$r" hook_event_name=PreToolUse tool_name=Bash tool_input="$(hin command="$cmd")")
      run_all "$k sdlc Bash $cmd ${a:+(agent)}" "$SH" "$SPL" "$r" PreToolUse Bash "$in"
      run_all "$k brain Bash $cmd ${a:+(agent)}" "$BH" "$B" "$r" PreToolUse Bash "$in"
    done
  done
  run_all "$k brain PreCompact" "$BH" "$B" "$r" PreCompact "" "{\"session_id\":\"$S\",\"cwd\":\"$r\",\"hook_event_name\":\"PreCompact\",\"trigger\":\"auto\"}"
  run_all "$k brain PostCompact" "$BH" "$B" "$r" PostCompact "" "{\"session_id\":\"$S\",\"cwd\":\"$r\",\"hook_event_name\":\"PostCompact\",\"trigger\":\"auto\"}"
  run_all "$k sdlc SessionStart compact" "$SH" "$SPL" "$r" SessionStart "" "{\"session_id\":\"$S\",\"cwd\":\"$r\",\"hook_event_name\":\"SessionStart\",\"source\":\"compact\"}"
  run_all "$k brain SessionStart compact" "$BH" "$B" "$r" SessionStart "" "{\"session_id\":\"$S\",\"cwd\":\"$r\",\"hook_event_name\":\"SessionStart\",\"source\":\"compact\"}"
  local src
  for src in resume clear; do
    run_all "$k sdlc SessionStart $src" "$SH" "$SPL" "$r" SessionStart "" "{\"session_id\":\"$S\",\"cwd\":\"$r\",\"hook_event_name\":\"SessionStart\",\"source\":\"$src\"}"
    run_all "$k brain SessionStart $src" "$BH" "$B" "$r" SessionStart "" "{\"session_id\":\"$S\",\"cwd\":\"$r\",\"hook_event_name\":\"SessionStart\",\"source\":\"$src\"}"
  done
  run_all "$k brain SessionEnd" "$BH" "$B" "$r" SessionEnd "" "{\"session_id\":\"$S\",\"cwd\":\"$r\",\"hook_event_name\":\"SessionEnd\",\"reason\":\"exit\"}"
}

# The brain holds one item in each repo, so its hooks have something to say.
seed() { (cd "$1" && CLAUDE_CODE_SESSION_ID=sDEV "$KIT/plugins/vibemaestro-brain/bin/brain" op add --kind now --text "ship the release notes" >/dev/null 2>&1); }

# normalize: the scratch root, then times (ISO stamps, clock times, ages) that differ from run to run
norm() {
  python3 -c 'import re, sys
t = sys.stdin.read().replace(sys.argv[1], "<T>")
t = re.sub(r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:?\d{2})?", "<TIME>", t)
t = re.sub(r"\b\d{4}-\d{2}-\d{2}\b", "<DATE>", t)
t = re.sub(r"\bsince \d{2}-\d{2}\b", "since <MM-DD>", t)                     # the short stamps of the brain, only these two:
t = re.sub(r"\(\d{2}-\d{2} \d{2}:\d{2}\)", "(<MM-DD HH:MM>)", t)             # "since 11-14", "(11-14 14:39)"
sys.stdout.write(t)' "$TMP"
}

R1="$TMP/dev-remote"; mk_dev "$R1" remote; seed "$R1"
R2="$TMP/dev-local"; mk_dev "$R2" local; seed "$R2"
GOT=$({ session "$R1" remote; session "$R2" local; } | norm)

if [ "$RECORD" = 1 ]; then
  mkdir -p "$(dirname "$EXPECTED")"
  { printf 'recorded on %s\n' "$(git -C "$SRC_ROOT" rev-parse --short HEAD)"; printf '%s\n' "$GOT"; } > "$EXPECTED"
  echo "recorded $(printf '%s\n' "$GOT" | grep -c '^## ') hook runs into $EXPECTED"
  exit 0
fi

echo "== developer mode: every hook run is byte for byte the recorded main =="
[ -f "$EXPECTED" ] || { bad "no expected file $EXPECTED"; summary; exit 1; }
WANT=$(tail -n +2 "$EXPECTED")
eq "$(printf '%s\n' "$GOT" | grep -c '^## ')" "$(printf '%s\n' "$WANT" | grep -c '^## ')" "the same number of hook runs as recorded"
nonempty "$(printf '%s\n' "$WANT" | grep -A1 '^## remote sdlc SessionStart startup cmd 1 ' | tail -n 1)" "instrument: the record holds the core hook's output"
nonempty "$(printf '%s\n' "$WANT" | grep -A1 '^## remote brain SessionStart startup cmd 1 ' | tail -n 1)" "instrument: the record holds the brain's injected block"
eq "$(printf '%s\n' "$WANT" | grep -A1 '^## remote sdlc ' | grep -c '"permissionDecision": "deny"')" 8 \
   "instrument: the record holds 8 refusals of the sdlc guards (settings files, the block rule)"
eq "$(printf '%s\n' "$WANT" | grep -A1 '^## remote brain ' | grep -c '"permissionDecision": "deny"')" 11 \
   "instrument: the record holds 11 refusals of the brain guards (its store, owner and import commands)"
if [ "${OS:-}" = Windows_NT ]; then   # the record is Linux output: Windows prints its paths with backslashes
  echo "  SKIP byte for byte: the record is Linux output and Windows writes its paths with backslashes; what developer mode delivers is checked instead"
  eq "$(printf '%s\n' "$GOT" | grep -A1 '^## remote sdlc ' | grep -c '"permissionDecision": "deny"')" 8 "[W] the 8 refusals of the sdlc guards are given on Windows too"
  eq "$(printf '%s\n' "$GOT" | grep -A1 '^## remote brain ' | grep -c '"permissionDecision": "deny"')" 11 "[W] …and the 11 of the brain guards"
  has "$(printf '%s\n' "$GOT" | grep -A1 '^## remote sdlc SessionStart startup cmd 1 ' | tail -n 1)" "The general way of working" "[W] the core hook delivers the process core"
elif [ "$GOT" = "$WANT" ]; then
  ok "every hook run prints what main printed, with the same exit code"
else
  bad "a hook run differs from main: $(diff <(printf '%s\n' "$WANT") <(printf '%s\n' "$GOT") | cut -c1-240 | head -n 40)"
fi

# The Stop hooks (the everyday mode's quiet save, KIT-870, and its notebook nudge) have no run on main to compare with: in a developer repository each must
# print nothing, exit 0 and change not one byte, with an unsaved change present that a save would have committed.
echo "== developer mode: the Stop hook says nothing and writes nothing =="
gitsum() { (cd "$1/.git" && find . -type f -print0 | sort -z | xargs -0 sha1sum | sha1sum | cut -c1-12); }
ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
eq "$(hook_cmds "$SPL/hooks/hooks.json" Stop "" | grep -c .)" 2 "instrument: hooks.json declares two Stop commands (the save, the notebook nudge)"
for r in "$R1" "$R2"; do
  k=${r##*/}; printf 'unsaved\n' > "$r/stop-probe.txt"
  g0=$(gitsum "$r"); t0=$(tree_hash "$r"); c0=$(cksum < "$GIT_CONFIG_GLOBAL")
  t=$(ms); O=$(run_all "$k Stop" "$SPL/hooks/hooks.json" "$SPL" "$r" Stop "" "{\"session_id\":\"sSTOP\",\"cwd\":\"$r\",\"hook_event_name\":\"Stop\"}"); t=$(( $(ms) - t ))
  eq "$O" "$(printf '## %s Stop cmd 1 rc=0\n\n## %s Stop cmd 2 rc=0' "$k" "$k")" "[stop] $k: both commands rc 0 and no output"
  eq "$(gitsum "$r")" "$g0" "[stop] $k: not one byte of .git changed"
  eq "$(tree_hash "$r")$(cksum < "$GIT_CONFIG_GLOBAL")" "$t0$c0" "[stop] $k: the work tree and the git config unchanged"
  echo "  note: the Stop hook took $t ms in $k"
done
summary
