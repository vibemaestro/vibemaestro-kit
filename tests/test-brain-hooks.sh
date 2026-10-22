#!/bin/bash
# =============================================================================
# vibemaestro-brain: the hooks (brain_hook.py) — re-injection, the Episode Log, guard-bash, guard-edit
# =============================================================================
# Run: bash tests/test-brain-hooks.sh
#
# Fabricated hook JSON piped to a copy of the plugin, as Claude Code runs it (a fresh python3, the input on stdin).
# guard-owner's cases are in tests/test-brain-owner.sh.
#   [S] session-start for each of the five sources with every section at its count cap and maximum-length lines: the
#       hot-memory render is ≤ 6,000 characters, the hard cut does not fire, and with the full Shelf index the block is ≤ 7,500
#   [F] the Shelf index from project, user and plugin skill directories holding more skills than fit: ≤ 1,000 characters,
#       project and user skills one line each (cut at 100), plugin skills as names per plugin, the dropped count named, a skill
#       planted in each of the three places listed; a user-only skill and a disabled plugin left out
#   [P] pre-compact logs the context size from the transcript's tail; post-compact saves the summary (0600, never injected),
#       keeps the newest 200, and logs loss 0.25 for a summary missing 1 of 4 anchors, where a longer number does not match its own prefix
#   [B] guard-bash denies `brain op` with agent_id, allows it without, and is silent on another command
#   [E] guard-edit denies a path under the state root (absolute, relative, through a symlink, a notebook) and allows others
#   [N] session-end finishes within 1.5 seconds on a 10,000-line log and deletes this session's records only
#   [O] BRAIN_OFF=1, a project with no state, and a sandbox worker each inject nothing; BRAIN_OFF=0 does inject
#   [C] fail-open: a corrupt hot.jsonl injects a one-line warning with rc 0; an internal error is one stderr line, rc 0
#   [R] the hook's import-free state root (its fast path) equals brain_store.state_root()
#   [K] the hard cut at 8,000 cuts at a line and names what it cut
#   [Z] tests/live/brain-owner-dialog.sh parses, and its --plan mode lists the runs and starts nothing
#   [P2] its key choice (--pick-key) on recorded menus: the trust dialog with No first or Yes first, a permission prompt
#        (the plain Yes, never "don't ask again"), a numbered menu, no match; a break pressing Enter on any option goes red
#   [X] planted breaks: each case goes red on a copy with one break
# Note: [S]'s break is the line cap, not a raised text cap: the render cuts every line at 200 characters whatever the text cap,
# so the line cap is the lever that can push the worst case past 6,000.
# =============================================================================
set -uo pipefail
# owner_ok runs the answerer check, which reads ancestors' CLAUDE_CONFIG_DIR and HOME from their initial environment: start
# again without the launcher's (as tests/test-brain-owner.sh does)
if [ -z "${BRAIN_SUITE_REEXEC:-}" ]; then
  export PYTHONUSERBASE="${PYTHONUSERBASE:-$(python3 -m site --user-base 2>/dev/null)}"
  exec env -u CLAUDE_CONFIG_DIR BRAIN_SUITE_REEXEC=1 HOME=/nonexistent bash "$0" "$@"
fi
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
# shellcheck source=fixtures/brain.sh
. "$HERE/fixtures/brain.sh"
brain_kit "$SRC_ROOT"
SOURCES="startup resume clear compact fork"

ctx() { hfield additionalContext; }
start() { hk session-start "$(hin session_id="$SID" cwd="$P" hook_event_name=SessionStart source="${1:-startup}" "${@:2}")"; }
rep() { python3 -c 'import sys; print(sys.argv[1] * int(sys.argv[2]))' "$@"; }   # rep <text> <n>
lastep() { tail -n 1 "$(sdir)/episodes.jsonl"; }
epfield() { lastep | python3 -c 'import json, sys; v = json.loads(sys.stdin.read()).get(sys.argv[1]); print("null" if v is None else v)' "$1"; }

skill() {  # skill <dir> <name> <description> [extra frontmatter line]
  mkdir -p "$1/$2"
  printf -- '---\nname: %s\ndescription: "%s"\n%s\n---\n\n# %s\n' "$2" "$3" "${4:-}" "$2" > "$1/$2/SKILL.md"
}

fill_caps() {  # every section at its count cap, every line at its maximum length
  local t links=() i
  t=$(rep t 150)
  for i in 1 2 3 4 5 6 7 8; do links+=(--link "kb/$(rep l 17)"); done   # short links fill each line up to the line cap
  for i in 1 2 3 4 5 6 7 8 9 10; do owner_ok add --kind decision --text "$t" --owner-quote q --where w "${links[@]}"; done
  for i in 1 2 3 4 5; do owner_ok add --kind window --text "$t" --owner-quote q --where w --expires 2099-01-02T22:00:00Z "${links[@]}"; done
  for i in 1 2 3; do br op add --kind now --text "$t" "${links[@]}"; done
  for i in 1 2 3 4 5; do br op add --kind next --text "$t" "${links[@]}"; done
  for i in 1 2 3 4; do br op add --kind trap --text "$t" "${links[@]}"; done
}

many_skills() {  # project, user and plugin skill directories holding more skills than the Shelf index fits
  local i cfg="$TMP/cfg$NP"
  export CLAUDE_CONFIG_DIR="$cfg"
  skill "$P/.claude/skills" "aa-proj-planted" "Planted in the project. Second sentence is dropped."
  skill "$P/.claude/skills" "ab-user-only" "Only the user can run this." "disable-model-invocation: true"
  skill "$cfg/skills" "aa-user-planted" "Planted in the user's skills."
  for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
    skill "$P/.claude/skills" "proj-$i" "Project skill $i with a long description that runs on and on well past the one hundred character cut of a line. More."
    skill "$cfg/skills" "user-$i" "User skill $i with a long description that runs on and on well past the one hundred character cut of a line. More."
  done
  mkdir -p "$cfg/plugins"
  local reg='{"version":2,"plugins":{' sep="" n
  for n in plug-a plug-b plug-c plug-off; do
    for i in 01 02 03 04 05 06 07 08 09 10; do skill "$TMP/pl$NP/$n/skills" "$n-skill-$i" "Skill $i of $n."; done
    reg="$reg$sep\"$n@m\":[{\"scope\":\"user\",\"installPath\":\"$TMP/pl$NP/$n\"}]"; sep=,
  done
  skill "$TMP/pl$NP/plug-a/skills" "aa-plug-planted" "Planted in a plugin."
  printf '%s}}' "$reg" > "$cfg/plugins/installed_plugins.json"
  printf '{"enabledPlugins":{"plug-a@m":true,"plug-b@m":true,"plug-c@m":true,"plug-off@m":false}}' > "$cfg/settings.json"
}

shelf() { printf '%s\n' "$1" | sed -n '/^## Shelf index/,$p'; }

case_caps() {
  newp
  fill_caps
  R=$(bpy 'st = s.fold(s.verify(s.state_dir())[1]); r = s.render(st)
print(len(r), sum(1 for l in r.splitlines() if l.startswith("- ")), max(len(l) for l in r.splitlines()))')
  set -- $R
  c_eq "$2" 27 "[S] instrument: 27 live items, every section at its cap"
  c_eq "$([ "$3" -ge 190 ] && [ "$3" -le 200 ] && echo full)" full "[S] instrument: lines are filled to the 200-character line cap (longest $3)"
  c_eq "$([ "$1" -le 6000 ] && echo within)" within "[S] the hot-memory render at the caps is $1 ≤ 6,000 characters"
  local src c
  for src in $SOURCES; do
    start "$src"; c=$(ctx)
    c_has "$c" "re-injected at SessionStart:$src" "[S] $src: the block is injected"
    c_has "$c" "## Brain · hot memory v" "[S] $src: it carries hot memory"
    c_hasnt "$c" "[brain: cut" "[S] $src: the hard cut does not fire"
    c_eq "$(epfield source)" "$src" "[S] $src: the episode line names the source"
  done
  many_skills
  start startup; c=$(ctx)
  R=$(nchars "$c"); c_eq "$([ "$R" -le 7500 ] && echo within)" within "[S] hot memory at its caps plus the full Shelf index: $R ≤ 7,500"
  c_eq "$(epfield injected)" "$R" "[S] the episode line counts the injected characters (B1.3's counter)"
  start resume context_tokens=612340 prompt_cache_likely_expired=true
  c_eq "$(epfield context_tokens)" 612340 "[S] resume: the S6 fields are logged"
  unset CLAUDE_CONFIG_DIR
}

case_shelf() {
  newp
  br op add --kind now --text "one item"
  many_skills
  start startup
  local sh; sh=$(shelf "$(ctx)")
  R=$(nchars "$sh"); c_eq "$([ "$R" -le 1000 ] && echo within)" within "[F] the Shelf index is $R ≤ 1,000 characters"
  c_has "$sh" "- aa-proj-planted — Planted in the project." "[F] a project skill: name and first sentence"
  c_hasnt "$sh" "Second sentence" "[F] only the first sentence"
  c_has "$sh" "- aa-user-planted — Planted in the user's skills." "[F] a user skill, one line"
  c_has "$sh" "- plug-a: aa-plug-planted, plug-a-skill-01" "[F] plugin skills as names grouped by plugin"
  R=$(printf '%s\n' "$sh" | python3 -c 'import sys; print(max([len(l) for l in sys.stdin.read().splitlines() if l.startswith(("- proj-", "- user-"))] or [0]))')
  c_eq "$([ "$R" -le 100 ] && [ "$R" -gt 90 ] && echo cut)" cut "[F] a long line is cut at 100 (longest $R)"
  c_has "$sh" "more skills not listed)" "[F] the dropped count is named"
  c_hasnt "$sh" "ab-user-only" "[F] a skill with disable-model-invocation is left out (it sorts early: it would fit)"
  c_hasnt "$sh" "plug-off" "[F] a disabled plugin is left out"
  unset CLAUDE_CONFIG_DIR
}

case_compact() {
  newp
  br op add --kind now --text "anchors" --anchor "#12" --anchor abc1234 --anchor clusters/ --anchor Alpha
  local tr="$TMP/tr$NP.jsonl" sd
  { echo '{"type":"user","message":{"content":"x"}}'
    echo '{"type":"assistant","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":5,"output_tokens":7}}}'
    echo '{"type":"assistant","message":{"usage":{"input_tokens":3,"cache_read_input_tokens":200000,"cache_creation_input_tokens":40,"output_tokens":9}}}'
    echo '{"type":"system","content":"compacting"}'; } > "$tr"
  hk pre-compact "$(hin session_id="$SID" cwd="$P" hook_event_name=PreCompact trigger=auto transcript_path="$tr")"
  c_rc 0 "[P] pre-compact rc 0"; c_eq "$OUT" "" "[P] pre-compact prints nothing (never blocks)"
  c_eq "$(epfield context_before)" 200043 "[P] pre-compact logs the last usage: input + cache read + cache write"
  sd="$(sdir)/summaries"; mkdir -p "$sd"
  for i in $(seq -w 1 205); do : > "$sd/20000101T000${i}Z-auto.md"; done
  hk post-compact "$(hin session_id="$SID" cwd="$P" hook_event_name=PostCompact trigger=auto compact_summary="Kept PR #123, abc1234, CLUSTERS/apps and alpha. SUMMARY-MARKER")"
  c_rc 0 "[P] post-compact rc 0"
  c_eq "$(epfield loss)" 0.25 "[P] 1 of 4 anchors missing: loss 0.25 (#123 does not match #12; case and word boundaries)"
  c_eq "$(epfield context_before)" 200043 "[P] the compact line carries the context size from pre-compact"
  c_eq "$(epfield trigger)" auto "[P] and the trigger"
  local f; f="$(sdir)/$(epfield summary)"
  c_has "$(cat "$f" 2>/dev/null)" "SUMMARY-MARKER" "[P] the summary is saved"
  c_eq "$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")" 600 "[P] 0600"
  c_eq "$(find "$sd" -name '*.md' | wc -l | tr -d ' ')" 200 "[P] the newest 200 summaries are kept"
  c_eq "$(epfield hot_version)" "$(bpy 'print(s.read_head(s.state_dir())["seq"])')" "[P] the hot memory version is the head's seq"
  start compact; c_hasnt "$(ctx)" "SUMMARY-MARKER" "[P] the summary is never injected"
}

case_guards() {
  newp
  hk guard-bash "$(hin session_id=sA cwd="$P" agent_id=sub1 tool_name=Bash tool_input='{"command":"brain op add --kind now --text x"}')"
  c_eq "$(hfield permissionDecision)" deny "[B] brain op from a subagent: deny"
  hk guard-bash "$(hin session_id=sA cwd="$P" agent_id=sub1 tool_name=Bash tool_input='{"command":"cd /x && /opt/p/bin/brain op close N1 --reason r"}')"
  c_eq "$(hfield permissionDecision)" deny "[B] a path-named brain op inside a compound command: deny"
  hk guard-bash "$(hin session_id=sA cwd="$P" tool_name=Bash tool_input='{"command":"brain op add --kind now --text x"}')"
  c_eq "$OUT" "" "[B] brain op from the main session: silent"
  hk guard-bash "$(hin session_id=sA cwd="$P" tool_name=Bash tool_input='{"command":"brain op add --kind now --text agent_id"}')"
  c_eq "$OUT" "" "[B] the word agent_id in the command, no agent_id field: silent (past the raw fast path)"
  hk guard-bash "$(hin session_id=sA cwd="$P" agent_id=sub1 tool_name=Bash tool_input='{"command":"git status"}')"
  c_eq "$OUT" "" "[B] another command from a subagent: silent"
  local root="$XDG_STATE_HOME/vibemaestro/brain"
  mkdir -p "$root/x"
  hk guard-edit "$(hin session_id=sA cwd="$P" tool_name=Edit tool_input="{\"file_path\":\"$root/x/hot.jsonl\"}")"
  c_eq "$(hfield permissionDecision)" deny "[E] an edit under the state root: deny"
  hk guard-edit "$(hin session_id=sA cwd="$root/x" tool_name=Write tool_input='{"file_path":"head.json"}')"
  c_eq "$(hfield permissionDecision)" deny "[E] a relative path that resolves under it: deny"
  ln -s "$root/x" "$P/link"
  hk guard-edit "$(hin session_id=sA cwd="$P" tool_name=Write tool_input="{\"file_path\":\"$P/link/new.json\"}")"
  c_eq "$(hfield permissionDecision)" deny "[E] through a symlink: deny"
  hk guard-edit "$(hin session_id=sA cwd="$P" tool_name=NotebookEdit tool_input="{\"notebook_path\":\"$root/x/n.ipynb\"}")"
  c_eq "$(hfield permissionDecision)" deny "[E] a notebook under it: deny"
  hk guard-edit "$(hin session_id=sA cwd="$P" tool_name=Edit tool_input="{\"file_path\":\"$P/src/main.py\"}")"
  c_eq "$OUT" "" "[E] a project file: silent"
  hk guard-edit "$(hin session_id=sA cwd="$P" tool_name=Edit tool_input="{\"file_path\":\"${root}x/a\"}")"
  c_eq "$OUT" "" "[E] a sibling whose name only starts like the root: silent"
}

case_end() {
  newp
  br op add --kind now --text "x"
  local d; d=$(sdir)
  python3 -c 'import sys
with open(sys.argv[1], "a") as f:
    for i in range(10000):
        f.write("{\"seq\": %d, \"filler\": \"%s\"}\n" % (i, "x" * 200))' "$d/hot.jsonl"
  rec default sA add --kind decision --text a --owner-quote q --where w
  rec default sB add --kind decision --text b --owner-quote q --where w
  R=$(python3 -c 'import subprocess, sys, time
t = time.time()
subprocess.run([sys.executable, sys.argv[1], "session-end"], input=sys.argv[2], text=True, capture_output=True)
print("%.0f" % ((time.time() - t) * 1000))' "$BROOT/scripts/brain_hook.py" "$(hin session_id=sA cwd="$P" hook_event_name=SessionEnd reason=exit)")
  c_eq "$([ "$R" -lt 1500 ] && echo within)" within "[N] session-end on a 10,000-line log: ${R} ms < 1,500"
  c_eq "$(recmode)" default "[N] the other session's record is kept, this session's deleted"
  c_eq "$(bpy 'import glob, json, os; print(json.load(open(glob.glob(os.path.join(s.state_dir(), "asked", "*.json"))[0]))["session"])')" sB "[N] the one left is sB's"
  c_eq "$(epfield kind)" session-end "[N] the episode is closed"
}

recmode() { bpy 'import glob, json, os
print(" ".join(sorted(json.load(open(p))["mode"] for p in glob.glob(os.path.join(s.state_dir(), "asked", "*.json")))) or "none")'; }

case_off() {
  newp
  start startup; c_eq "$OUT" "" "[O] a project with no state: nothing injected"
  c_eq "$([ -e "$(sdir)" ] && echo exists || echo none)" none "[O] and no state directory is made"
  br op add --kind now --text "x"
  BRAIN_OFF=1 start startup; c_eq "$OUT" "" "[O] BRAIN_OFF=1: nothing injected"
  INTENT_SLUG=x SEAT=y start startup; c_eq "$OUT" "" "[O] a sandbox worker: nothing injected"
  BRAIN_OFF=0 start startup; c_has "$(ctx)" "hot memory" "[O] instrument: BRAIN_OFF=0 injects"
}

case_corrupt() {
  newp
  br op add --kind now --text "x"
  echo 'not json' >> "$(sdir)/hot.jsonl"
  start startup
  c_rc 0 "[C] a corrupt hot.jsonl: rc 0"
  c_has "$(ctx)" "hot memory was not injected" "[C] a one-line warning is injected"
  c_eq "$(ctx | wc -l | tr -d ' ')" 1 "[C] one line"
  newp
  br op add --kind now --text "x"
  mkdir "$(sdir)/episodes.jsonl"
  hk pre-compact "$(hin session_id=sA cwd="$P" trigger=manual)"
  c_rc 0 "[C] an internal error (the log is a directory): rc 0"
  c_has "$ERR" "brain hook pre-compact: IsADirectoryError" "[C] one stderr line names it"
  hk session-start 'not json'; c_rc 0 "[C] input that is not JSON: rc 0"
}

case_cut() {
  newp
  R=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import brain_hook as h
b = "# frame\n" + "".join("- line %04d %s\n" % (i, "x" * 80) for i in range(90)) + "## Shelf index (skills)\n" + "- s\n" * 400
out, gone = h.cut(b)
print(len(out) <= 8000, out.splitlines()[-1].startswith("[brain: cut"), "Shelf index" in out.splitlines()[-1], gone > 0)' "$BROOT/scripts")
  c_eq "$R" "True True True True" "[K] an oversize block is cut to ≤ 8,000 at a line, the last line names what was cut"
}

pick_checks() {  # pick_checks <live script> — the key choice on recorded Claude Code menus (B1.2a)
  local s=$1 T='^Yes, (I trust this folder|proceed)' Y='^Yes$'
  c_eq "$(printf ' Security guide\n ❯ No, exit\n   Yes, I trust this folder\n Enter to confirm · Esc to cancel\n' | bash "$s" --pick-key "$T")" Down "[P2] trust dialog of 2.1.290/2.1.302, cursor on No first: Down"
  c_eq "$(printf ' Security guide\n   No, exit\n ❯ Yes, I trust this folder\n' | bash "$s" --pick-key "$T")" Enter "[P2] then, the cursor on Yes: Enter"
  c_eq "$(printf ' Do you trust the files in this folder?\n ❯ 1. Yes, proceed\n   2. No, exit\n' | bash "$s" --pick-key "$T")" Enter "[P2] an older dialog with Yes first: Enter"
  c_eq "$(printf '> Run exactly this one Bash command\n Do you want to proceed?\n ❯ 1. Yes\n   2. Yes, and don'"'"'t ask again for brain commands\n   3. No\n' | bash "$s" --pick-key "$Y")" Enter "[P2] permission prompt: the plain Yes (a quoted > line beside a ❯ menu is not the cursor)"
  c_eq "$(printf ' Do you want to proceed?\n   1. Yes\n ❯ 2. Yes, and don'"'"'t ask again\n   3. No\n' | bash "$s" --pick-key "$Y")" Up "[P2] the cursor on \"don't ask again\": Up to the plain Yes, never Enter there"
  c_eq "$(printf ' Do you want to proceed?\n 1. Yes\n 2. No\n' | bash "$s" --pick-key "$Y")" 1 "[P2] a numbered menu with no cursor: its number"
  c_eq "$(printf ' something else\n ❯ No, exit\n' | bash "$s" --pick-key "$T")" none "[P2] no matching option: no key"
  c_eq "$(printf '> quoted prompt\n 1. Yes\n 2. No\n' | bash "$s" --pick-key "$Y")" 1 "[P2] a quoted > line and a numbered menu with no cursor: the number, not Down"
  c_eq "$(printf ' Do you want to proceed?\n ❯ 1. Yes\n   2. No\n\n ❯ \n' | bash "$s" --pick-key "$Y")" Enter "[P2] an empty input line under the menu is not its cursor"
  c_eq "$(printf ' Yes\n Menu\n 1. Yes\n 2. No\n' | bash "$s" --pick-key "$Y")" 1 "[P2] a stray Yes line above a numbered menu: the numbered one"
  printf 'x\n' | bash "$s" --pick-key '(' >/dev/null 2>&1; c_eq "$?" 1 "[P2] a choice that cannot be made (bad pattern): rc 1, no key"
}

case_pick() {
  newp
  local s="$SRC_ROOT/tests/live/brain-owner-dialog.sh" b="$TMP/pick-break.sh"
  pick_checks "$s"
  python3 - "$s" "$b" <<'PYB' || { bad "[X] pick-first-option: the break does not apply"; return; }
import sys
t = open(sys.argv[1], encoding="utf-8").read()
a = 'print("Enter" if t == c else "Down" if t > c else "Up")'
if t.count(a) != 1:
    sys.exit(1)
open(sys.argv[2], "w", encoding="utf-8").write(t.replace(a, 'print("Enter")'))
PYB
  Q=1; CASE_FAIL=0; pick_checks "$b"; Q=0
  [ "$CASE_FAIL" = 1 ] && ok "[X] pick-first-option (Enter on whatever the cursor is on) turns the key choice red" || bad "[X] pick-first-option: the key choice stays green"
  CASE_FAIL=0
}

case_live() {
  newp
  local s="$SRC_ROOT/tests/live/brain-owner-dialog.sh"
  bash -n "$s"; c_eq "$?" 0 "[Z] the live script parses"
  OUT=$(PATH="/usr/bin:/bin" bash "$s" --plan 2>&1); RC=$?
  c_rc 0 "[Z] --plan rc 0 with a minimal PATH (it starts nothing)"
  c_has "$OUT" "default/no-allow" "[Z] --plan lists the gating runs"
  c_has "$OUT" "control/brain-off" "[Z] and the sure-negative control"
}

case_root() {
  newp
  local v
  for v in "XDG_STATE_HOME=$TMP/abs" "XDG_STATE_HOME=rel/state" "XDG_STATE_HOME=" "HOME=" ; do
    R=$(env "$v" python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import brain_hook as h, brain_store as s
print(h.state_root() == s.state_root())' "$BROOT/scripts")
    c_eq "$R" True "[R] the hook's import-free state root equals the store's ($v)"
  done
}

echo "== cases =="
for c in case_root case_caps case_shelf case_compact case_guards case_end case_off case_corrupt case_cut case_live case_pick; do run_case $c; done
cd "$TMP" || exit 1

echo "== planted breaks =="
ST=scripts/brain_store.py; HK=scripts/brain_hook.py
plant line-cap-240 case_caps $ST 'LINE_MAX = 200' 'LINE_MAX = 240'
plant user-skills-not-read case_shelf $HK '    user = [one(*k) for k in skills(os.path.join(s.config_dir(), "skills"))]' '    user = []'
plant user-only-skills-listed case_shelf $HK '        if str(fm.get("disable-model-invocation", "")).lower() == "true":' '        if False:'
plant shelf-not-round-robin case_shelf $HK '                if used + len(l[r]) + 1 + reserve <= SHELF_MAX:' '                if used + len(l[r]) + 1 + reserve <= SHELF_MAX and k != "user":'
plant word-boundary-dropped case_compact $HK '    pat = ("(?<!\\w)" if re.match(r"\w", anchor) else "") + a + ("(?!\\w)" if re.search(r"\w$", anchor) else "")' '    pat = a'
plant summary-injected case_compact $HK '    block, gone = cut(head_line + hot + "\n" + shelf_index(s, project))' '    block, gone = cut(head_line + hot + "\n" + shelf_index(s, project) + "".join(open(p).read() for p in glob.glob(os.path.join(d, "summaries", "*.md"))))'
plant summaries-not-pruned case_compact $HK '        for old in sorted(glob.glob(os.path.join(sd, "*.md")))[:-SUMMARIES_KEPT]:' '        for old in []:'
plant guard-bash-ignores-agent case_guards $HK '    if not inp.get("agent_id"):
        return
    cmd = command_of(inp)' '    cmd = command_of(inp)'
plant guard-edit-no-realpath case_guards $HK '    full = os.path.realpath(os.path.join(cwd_of(inp), os.path.expanduser(p)))' '    full = os.path.join(cwd_of(inp), os.path.expanduser(p))'
plant guard-edit-prefix-only case_guards $HK '        if full == root or full.startswith(root.rstrip(os.sep) + os.sep):' '        if full.startswith(root):'
plant end-voids-all case_end $HK '    if sid:
        s.void_records(d, sid)
    episode(d, inp, "session-end"' '    for p in glob.glob(os.path.join(d, "asked", "*.json")):
        os.unlink(p)
    episode(d, inp, "session-end"'
plant brain-off-ignored case_off $HK '    return (os.environ.get("BRAIN_OFF", "") not in ("", "0")' '    return (False'
plant state-check-removed case_off $HK '    if not has_state(d):
        return
    source =' '    source ='
plant warning-dropped case_corrupt $HK '    except s.Refused as e:
        warn =' '    except KeyError as e:
        warn ='
plant not-fail-open case_corrupt $HK '        sys.stderr.write("brain hook %s: %s: %s\n" % (event, e.__class__.__name__, str(e)[:200]))' '        raise'
plant no-hard-cut case_cut $HK '    if len(block) <= BLOCK_MAX:
        return block, 0' '    if True:
        return block, 0'

plant root-relative-xdg case_root $HK '    if not os.path.isabs(x):
        h = os.environ.get("HOME", "")' '    if not x:
        h = os.environ.get("HOME", "")'

summary
