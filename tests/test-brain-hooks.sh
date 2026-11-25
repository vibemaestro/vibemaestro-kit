#!/bin/bash
# =============================================================================
# vibemaestro-brain: the hooks (brain_hook.py) — re-injection, the Episode Log, guard-bash, guard-edit
# =============================================================================
# Run: bash tests/test-brain-hooks.sh
#
# Fabricated hook JSON piped to a copy of the plugin, as Claude Code runs it (a fresh python3, the input on stdin).
# guard-owner's cases are in tests/test-brain-owner.sh.
#   [S] session-start for each of the five sources with the left brain at its count caps (D 20, W 10), maximum-length lines
#       and quotes: string 1 (the head line, the left brain's first string, the Shelf index) is ≤ 9,500 UTF-16 units, the hard
#       cut does not fire, the left brain goes on in a second string, and with the full Shelf index string 1 is still ≤ 9,500
#   [F] the Shelf index from project, user and plugin skill directories holding more skills than fit: ≤ 1,000 characters,
#       project and user skills one line each (cut at 100), plugin skills as names per plugin, the dropped count named, a skill
#       planted in each of the three places listed; a user-only skill and a disabled plugin left out
#   [P] pre-compact logs the context size from the transcript's tail; post-compact saves the summary (0600, never injected),
#       keeps the newest 200, and logs loss 0.25 for a summary missing 1 of 4 anchors, where a longer number does not match its own prefix
#   [B] guard-bash denies `brain op` with agent_id, allows it without, and is silent on another command
#   [E] guard-edit denies a path under the state root (absolute, relative, through a symlink, a notebook) and allows others
#   [N] session-end finishes within 1.5 seconds on a 10,000-line log and deletes this session's records only
#   [O] BRAIN_OFF=1, a project with no state, and a worker (the switch VIBEMAESTRO_ROLE=worker alone, the pair INTENT_SLUG and SEAT
#       alone) each inject nothing; BRAIN_OFF=0, and neither the switch nor the pair, do inject
#   [C] fail-open: a corrupt hot.jsonl injects a one-line warning with rc 0; an internal error is one stderr line, rc 0
#   [R] the hook's import-free state root (its fast path) equals brain_store.state_root()
#   [CP] a guard reads its input as UTF-8 bytes whatever the system code page: an edit under a non-ASCII state root is denied
#   [W] the session's project, whatever the shell's directory: claimed in A, with cwd in B the compact hooks log A's episode
#       and SessionStart injects A's block, with CLAUDE_PROJECT_DIR or, without it, from the session's record; the CLI writes
#       A and names both; outside a session, the cwd as before; /clear's new session id still A; session-end removes the
#       record; a resume in another project says so; B never gets a state directory
#   [K] the hard cut at 9,500 cuts at a line and names what it cut
#   [PA] the installed brain first: session-start writes one line to CLAUDE_ENV_FILE that puts this brain's bin first on PATH
#       (once, again at cwd-changed, quoted for a path with a space; not under BRAIN_OFF or in a worker), so a shell that runs
#       the file finds this brain before an older one; string 1 names the brain a bare `brain` runs, and both when it is
#       another; guard-path denies a write and notes a read through a bare `brain` that resolves to another brain on the
#       hook's PATH, and is silent when the session's start put this brain first; session-end removes that mark. Round 1:
#       a `brain` with no scripts/brain.py beside it is no brain; one in a repository's tree only gets the line; a `brain`
#       word outside command position is not a call. Round 2: a shell keyword or wrapper before `brain` (`do`, `env`, `time`,
#       `if`) keeps it in command position; string 1 says a tree brain's writes go through. Windows: no line is written, and the hook still finds an older
#       brain's extensionless bin/brain and denies its write
#   [Z] tests/live/brain-owner-dialog.sh parses, and its --plan mode lists the runs and starts nothing
#   [P2] its key choice (--pick-key) on recorded menus: the trust dialog with No first or Yes first, a permission prompt
#        (the plain Yes, never "don't ask again"), a numbered menu, no match
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

fill_caps() {  # the left brain at its count caps, every line and quote at its maximum length; a few right-brain items
  local t q w links=() i
  t=$(rep t 300); q=$(rep q 600); w=$(rep w 60)
  for i in 1 2 3 4 5 6 7 8; do links+=(--link "kb/$(rep l 17)"); done   # short links fill each line up to the line cap
  for i in $(seq 1 20); do owner_ok add --kind decision --text "$t" --owner-quote "$q" --where "$w" "${links[@]}"; done
  for i in $(seq 1 10); do owner_ok add --kind window --text "$t" --owner-quote q --where w --expires 2099-01-02T22:00:00Z "${links[@]}"; done
  for i in 1 2 3; do br op add --kind now --text "$t" "${links[@]}"; done
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
    reg="$reg$sep\"$n@m\":[{\"scope\":\"user\",\"installPath\":\"$(wpath "$TMP/pl$NP/$n")\"}]"; sep=,
  done
  skill "$TMP/pl$NP/plug-a/skills" "aa-plug-planted" "Planted in a plugin."
  printf '%s}}' "$reg" > "$cfg/plugins/installed_plugins.json"
  printf '{"enabledPlugins":{"plug-a@m":true,"plug-b@m":true,"plug-c@m":true,"plug-off@m":false}}' > "$cfg/settings.json"
}

shelf() { printf '%s\n' "$1" | sed -n '/^## Shelf index/,$p'; }

case_caps() {
  newp
  fill_caps
  R=$(bpy 'st = s.fold(s.verify(s.state_dir())[1]); ss = [t for h, t in s.render_strings(st) if h == "left"]; r = "".join(ss)
print(len(ss), sum(1 for l in r.splitlines() if l.startswith("- ")), max(len(l) for l in r.splitlines()),
      sum(1 for l in r.splitlines() if l.startswith("  \"") and len(l) >= 155))')
  set -- $R
  c_eq "$2" 30 "[S] instrument: 30 live items in the left brain, D and W at their caps"
  c_eq "$4" 20 "[S] instrument: 20 quote lines at their length (quote 600 cut at 120, where 60 whole)"
  c_eq "$([ "$3" -ge 350 ] && [ "$3" -le 360 ] && echo full)" full "[S] instrument: lines are filled to the 360-character line cap (longest $3)"
  c_eq "$1" 3 "[S] the left brain at its caps takes three strings"
  local src c
  for src in $SOURCES; do
    start "$src"; c=$(ctx)
    c_has "$c" "re-injected at SessionStart:$src" "[S] $src: the block is injected"
    c_has "$c" "## Brain · left brain, 1 of 3 v" "[S] $src: it opens the left brain"
    c_hasnt "$c" "[brain: cut" "[S] $src: the hard cut does not fire"
    c_hasnt "$c" "- N1 " "[S] $src: the right brain is not in string 1"
    c_eq "$(epfield source)" "$src" "[S] $src: the episode line names the source"
  done
  many_skills
  start startup; c=$(ctx)
  R=$(python3 -c 'import sys; print(len(sys.argv[1].encode("utf-16-le")) // 2)' "$c")
  c_eq "$([ "$R" -le 9500 ] && echo within)" within "[S] string 1 at the left caps plus the full Shelf index: $R ≤ 9,500"
  c_has "$c" "more skills not listed)" "[S] instrument: the Shelf index is full (it drops skills)"
  c_hasnt "$c" "[brain: cut" "[S] and the hard cut does not fire"
  R=$(nchars "$c")
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
  if [ "${OS:-}" = Windows_NT ]; then c_skip "[P] 0600" "Windows has no mode bits (the store's access rules: store [WA])"
  else c_eq "$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")" 600 "[P] 0600"; fi
  c_eq "$(find "$sd" -name '*.md' | wc -l | tr -d ' ')" 200 "[P] the newest 200 summaries are kept"
  c_eq "$(epfield hot_version)" "$(bpy 'print(s.read_head(s.state_dir())["seq"])')" "[P] the hot memory version is the head's seq"
  start compact; c_hasnt "$(ctx)" "SUMMARY-MARKER" "[P] the summary is never injected"
  local real='{"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":3,"cache_read_input_tokens":90000,"cache_creation_input_tokens":7}}}'
  { echo "$real"
    echo '{"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}'; } > "$tr"
  hk pre-compact "$(hin session_id="$SID" cwd="$P" hook_event_name=PreCompact trigger=auto transcript_path="$tr")"
  c_eq "$(epfield context_before)" 90010 "[P] a <synthetic> zero line after a real one: the real line's size"
  { echo "${real/90000/40000}"
    echo '{"type":"assistant","isSidechain":true,"message":{"model":"claude-haiku-4-5","usage":{"input_tokens":1,"cache_read_input_tokens":5000,"cache_creation_input_tokens":2}}}'; } > "$tr"
  hk pre-compact "$(hin session_id="$SID" cwd="$P" hook_event_name=PreCompact trigger=auto transcript_path="$tr")"
  c_eq "$(epfield context_before)" 40010 "[P] a sidechain line after a main one: the main line's size"
  echo "${real/90000/1000}" > "$tr"
  hk pre-compact "$(hin session_id="$SID" cwd="$P" hook_event_name=PreCompact trigger=auto transcript_path="$tr")"
  c_eq "$(epfield context_before)" 1010 "[P] a main-only transcript: unchanged"
  echo '{"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}' > "$tr"
  hk pre-compact "$(hin session_id="$SID" cwd="$P" hook_event_name=PreCompact trigger=auto transcript_path="$tr")"
  c_eq "$(epfield context_before)" null "[P] a transcript of only skipped lines: no size (null), not 0"
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
  if can_link; then
    ln -s "$root/x" "$P/link"
    hk guard-edit "$(hin session_id=sA cwd="$P" tool_name=Write tool_input="{\"file_path\":\"$P/link/new.json\"}")"
    c_eq "$(hfield permissionDecision)" deny "[E] through a symlink: deny"
  else c_skip "[E] through a symlink" "ln -s copies here instead of linking"; fi
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

epf() { tail -n 1 "$1/episodes.jsonl" 2>/dev/null | python3 -c 'import json, sys
t = sys.stdin.read().strip(); v = json.loads(t).get(sys.argv[1]) if t else "no-episode"; print("null" if v is None else v)' "$2"; }   # epf <state dir> <field>
mrow() { printf '%s' "$OUT" | python3 -c 'import json, sys
t = sys.stdin.read(); j = json.loads(t[t.index("{"):])
print([r["line"] for r in j["rows"] if r["line"].startswith("Know")][0])'; }   # mrow — the Know·hot row of `brain matrix --json` in OUT
nlines() { wc -l < "$1" 2>/dev/null | tr -d ' ' || echo 0; }

case_session() {  # the session's project, whatever the shell's directory: claim in A, hooks and CLI with cwd in B
  newp
  local A=$P B="$TMP/other$NP" dA dB n tr="$TMP/tr$NP.jsonl" wA wB
  mkdir -p "$B"; git_ -C "$B" init -q -b main
  wA=$(wpath "$A"); wB=$(wcwd "$B")   # Windows: the project as CLAUDE_PROJECT_DIR reaches Python (C:/…), the shell as getcwd gives it
  owner_ok add --kind decision --text "A-MARKER" --owner-quote "a project marker" --where chat   # string 1 holds the left brain
  dA=$(sdir); dB=$(cd "$B" && bpy 'import os; print(s.state_dir(os.getcwd()))')
  printf '%s\n' '{"type":"assistant","message":{"usage":{"input_tokens":1,"cache_read_input_tokens":500,"cache_creation_input_tokens":0,"output_tokens":1}}}' > "$tr"
  CLAUDE_PROJECT_DIR="$A" start startup
  c_has "$(ctx)" "A-MARKER" "[W] startup in A: A's block"
  local f sd old ma; f=$(bpy 'print(s.session_file("sA"))'); sd=$(dirname "$f")
  if [ "${OS:-}" = Windows_NT ]; then c_skip "[W] 0600 in a 0700 sessions/ directory" "Windows has no mode bits (store [WA])"
  else
    c_eq "$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f")" 600 "[W] the session's project record is written, 0600"
    c_eq "$(stat -c %a "$sd" 2>/dev/null || stat -f %Lp "$sd")" 700 "[W] in a 0700 sessions/ directory"
  fi
  bpy "s.record_session('sOld', '$A', s.state_dir('$A'))"; old=$(bpy 'print(s.session_file("sOld"))')
  python3 -c 'import os, sys, time; t = time.time() - 40 * 86400; os.utime(sys.argv[1], (t, t))' "$old"
  SID=sN CLAUDE_PROJECT_DIR="$A" start startup; SID=sA
  c_eq "$([ -e "$old" ] && echo kept || echo swept)" swept "[W] a record older than 30 days is swept when a new one is written"
  c_eq "$([ -e "$f" ] && echo kept || echo swept)" kept "[W] a live one is kept"
  cd "$B" || return 1
  CLAUDE_PROJECT_DIR="$A" hk pre-compact "$(hin session_id=sA cwd="$B" hook_event_name=PreCompact trigger=auto transcript_path="$tr")"
  c_eq "$(epf "$dA" kind)" pre-compact "[W] pre-compact with cwd in B: A's episode"
  c_eq "$(epf "$dA" context_before)" 501 "[W] with the context size"
  CLAUDE_PROJECT_DIR="$A" hk post-compact "$(hin session_id=sA cwd="$B" hook_event_name=PostCompact trigger=auto compact_summary="S")"
  c_eq "$(epf "$dA" kind)" compact "[W] post-compact with cwd in B: A's episode"
  CLAUDE_PROJECT_DIR="$A" hk session-start "$(hin session_id=sA cwd="$B" hook_event_name=SessionStart source=compact)"
  c_has "$(ctx)" "A-MARKER" "[W] SessionStart:compact with cwd in B: A's block is injected"
  c_eq "$(epf "$dA" source)" compact "[W] and A's episode logs it"
  n=$(nlines "$dA/episodes.jsonl")
  hk pre-compact "$(hin session_id=sA cwd="$B" hook_event_name=PreCompact trigger=auto transcript_path="$tr")"
  c_eq "$(nlines "$dA/episodes.jsonl")" "$((n+1))" "[W] a hook without CLAUDE_PROJECT_DIR: the session's record, A's episode"
  hk session-start "$(hin session_id=sA cwd="$B" hook_event_name=SessionStart source=compact)"
  c_has "$(ctx)" "A-MARKER" "[W] SessionStart:compact without CLAUDE_PROJECT_DIR: A's block"
  br op add --kind next --text "WRITTEN-FROM-B"
  c_rc 0 "[W] brain op in B: rc 0"
  c_has "$OUT" "this session's project is $wA; the shell is in $wB; using $wA" "[W] the CLI names both projects"
  c_has "$(cat "$dA/hot.jsonl")" "WRITTEN-FROM-B" "[W] and writes A's hot memory"
  br doctor --path; c_has "$OUT" "$dA" "[W] doctor --path in B names A's state directory"
  cd "$A" || return 1; br matrix --json; ma=$(mrow); cd "$B" || return 1
  br matrix --json; c_eq "$(mrow)" "$ma" "[W] brain matrix in B shows A's hot memory row"
  cp "$f" "$TMP/rec$NP"; printf '{bad' > "$f"; n=$(nlines "$dA/episodes.jsonl")
  hk pre-compact "$(hin session_id=sA cwd="$B" hook_event_name=PreCompact trigger=auto transcript_path="$tr")"
  c_has "$ERR" "cannot be read" "[W] a damaged record and no CLAUDE_PROJECT_DIR: the hook says so"
  c_eq "$(nlines "$dA/episodes.jsonl")" "$n" "[W] and logs nothing (B is checked at the end)"
  cp "$TMP/rec$NP" "$f"
  mv "$sd" "$sd.away"; : > "$sd"
  CLAUDE_PROJECT_DIR="$A" hk session-start "$(hin session_id=sA cwd="$B" hook_event_name=SessionStart source=compact)"
  c_has "$(ctx)" "A-MARKER" "[W] the record cannot be written: the hook still injects A's block"
  c_has "$ERR" "record was not written" "[W] and says the record was not written"
  rm -f "$sd"; mv "$sd.away" "$sd"
  OUT=$(cd "$B" && env -u CLAUDE_CODE_SESSION_ID "$BROOT/bin/brain" doctor --path 2>&1)
  c_eq "$OUT" "$dB" "[W] outside a Claude Code session: the cwd's project, as before"
  CLAUDE_PROJECT_DIR="$A" hk session-start "$(hin session_id=sC cwd="$B" hook_event_name=SessionStart source=clear)"
  c_has "$(ctx)" "A-MARKER" "[W] /clear (a new session id) with cwd in B: A's block"
  CLAUDE_PROJECT_DIR="$A" hk session-end "$(hin session_id=sC cwd="$B" hook_event_name=SessionEnd reason=clear)"
  c_eq "$(epf "$dA" kind)" session-end "[W] session-end with cwd in B: A's episode"
  SID=sC; br doctor --path
  c_has "$OUT" "$dA" "[W] /clear keeps the ended id's record: a Bash call still carrying it stays in A"
  CLAUDE_PROJECT_DIR="$A" hk session-end "$(hin session_id=sC cwd="$B" hook_event_name=SessionEnd reason=resume)"
  br doctor --path
  c_has "$OUT" "$dA" "[W] a switch to another session (reason resume) keeps it too"
  CLAUDE_PROJECT_DIR="$A" hk session-end "$(hin session_id=sC cwd="$B" hook_event_name=SessionEnd reason=exit)"
  br doctor --path
  c_eq "$OUT" "$dB" "[W] any other session-end removes the record: the ended id falls back to the cwd"
  SID=sA
  local C="$TMP/third$NP" dC
  mkdir -p "$C"; git_ -C "$C" init -q -b main
  (cd "$C" && SID=sD owner_ok add --kind decision --text "C-MARKER" --owner-quote "a project marker" --where chat)
  dC=$(cd "$C" && SID=sD bpy 'import os; print(s.state_dir(os.getcwd()))')
  if [ "${OS:-}" = Windows_NT ]; then
    c_skip "[W] a resume in C whose record cannot be written" "Windows lets a read-only folder take new files"
  elif [ "$(id -u)" != 0 ]; then              # root writes into a 0500 directory anyway
    chmod 500 "$sd"
    CLAUDE_PROJECT_DIR="$C" hk session-start "$(hin session_id=sA cwd="$B" hook_event_name=SessionStart source=resume)"
    chmod 700 "$sd"
    c_has "$(ctx)" "C-MARKER" "[W] a resume in C whose record cannot be written: C's block"
    c_has "$ERR" "it still names $wA, which \`brain\` run from Bash would use" "[W] and names the project the old record keeps"
  fi
  CLAUDE_PROJECT_DIR="$C" hk session-start "$(hin session_id=sA cwd="$B" hook_event_name=SessionStart source=resume)"
  c_has "$ERR" "this session's project was $wA; it is now $(wpath "$C")" "[W] a resume in another project says it moves the record"
  c_has "$(ctx)" "C-MARKER" "[W] and injects that project's block"
  c_eq "$(epf "$dC" rebound_from)" "$wA" "[W] its episode names the project it left"
  nowrite "$TMP/fault$NP"
  mkdir -p "$C/sub"; bpy "s.record_session('sA', '$(wpath "$C/sub")', s.state_dir('$(wpath "$C/sub")'))"
  PYTHONPATH="$TMP/fault$NP" CLAUDE_PROJECT_DIR="$C" hk session-start "$(hin session_id=sA cwd="$B" hook_event_name=SessionStart source=compact)"
  c_has "$ERR" "record was not written: OSError" "[W] instrument: the fault makes the record write fail"
  c_eq "$(bpy 'print(s.read_session("sA")["project"])')" "$(wpath "$C/sub")" "[W] a failed write keeps a record naming the same brain (a sibling worktree)"
  PYTHONPATH="$TMP/fault$NP" CLAUDE_PROJECT_DIR="$A" hk session-start "$(hin session_id=sA cwd="$B" hook_event_name=SessionStart source=resume)"
  c_has "$(ctx)" "A-MARKER" "[W] a failed write on a resume into A: A's block"
  c_eq "$(bpy 'print(s.read_session("sA"))')" None "[W] the record naming C is removed, so the CLI cannot write C"
  c_has "$ERR" "follows the shell's directory until a hook writes it" "[W] and the line says what the CLI does now"
  c_eq "$([ -e "$dB" ] && echo made || echo none)" none "[W] B never got a brain state directory"
}

nowrite() {  # nowrite <dir> — a sitecustomize there makes brain_store's writes into sessions/ fail (no space), unlink still works
  mkdir -p "$1"
  cat > "$1/sitecustomize.py" <<PY
import errno, os, sys
sys.path.insert(0, "$(wpath "$BROOT/scripts")")
import brain_store
_w = brain_store._write_file
def _fail(path, data):
    if os.path.basename(os.path.dirname(path)) == "sessions":
        raise OSError(errno.ENOSPC, "No space left on device")
    return _w(path, data)
brain_store._write_file = _fail
PY
}

recmode() { bpy 'import glob, json, os
print(" ".join(sorted(json.load(open(p))["mode"] for p in glob.glob(os.path.join(s.state_dir(), "asked", "*.json")))) or "none")'; }

case_off() {
  newp
  start startup; c_eq "$OUT" "" "[O] a project with no state: nothing injected"
  c_eq "$([ -e "$(sdir)" ] && echo exists || echo none)" none "[O] and no state directory is made"
  br op add --kind now --text "x"
  BRAIN_OFF=1 start startup; c_eq "$OUT" "" "[O] BRAIN_OFF=1: nothing injected"
  INTENT_SLUG=x SEAT=y start startup; c_eq "$OUT" "" "[O] the pair alone (INTENT_SLUG and SEAT): nothing injected"
  VIBEMAESTRO_ROLE=worker start startup; c_eq "$OUT" "" "[O] the switch alone (VIBEMAESTRO_ROLE=worker): nothing injected"
  VIBEMAESTRO_ROLE=worker hk guard-bash "$(hin session_id=sA cwd="$P" tool_name=Bash tool_input='{"command": "brain op touch N1"}' agent_id=a1)"
  c_eq "$OUT" "" "[O] the switch alone: the guards are silent too"
  start startup; c_has "$(ctx)" "## Brain · left brain" "[O] neither the switch nor the pair: injected"
  BRAIN_OFF=0 start startup; c_has "$(ctx)" "## Brain · left brain" "[O] instrument: BRAIN_OFF=0 injects"
}

case_hooks_off() {  # the sdlc config's `hooks: off` silences every event of the brain; without it the same inputs do what they did
  newp
  fill_caps                                      # string 2 exists
  local e="$TMP/env$NP" old="$TMP/old$NP/plugins/vibemaestro-brain" tr="$TMP/tr$NP.jsonl" gh="$TMP/gh$NP" root="$XDG_STATE_HOME/vibemaestro/brain" r sub="$P/sub" off='{"hooks": "off"}'
  mkdir -p "$old/bin" "$old/scripts" "$gh" "$sub"; : > "$old/scripts/brain.py"; : > "$tr"
  printf '#!/bin/sh\necho "stand-in brain ran"\n' > "$old/bin/brain"; chmod +x "$old/bin/brain"
  printf '#!/bin/sh\nexit 1\n' > "$gh/gh"; chmod +x "$gh/gh"
  bpy "import json; f = open(s.state_dir() + '/episodes.jsonl', 'a')
f.write(json.dumps({'t': s.now_iso(), 'kind': 'session-start', 'session': 'sOld', 'format': 3}) + '\n')
f.write(json.dumps({'t': s.now_iso(), 'kind': 'session-start', 'session': 'sOld2', 'format': 3}) + '\n')"
  eps() { python3 -c 'import json, sys
print(sum(1 for l in open(sys.argv[1] + "/episodes.jsonl") if json.loads(l).get("kind") == sys.argv[2]))' "$(sdir)" "$1"; }
  hookin() { hin session_id="${2:-sA}" cwd="$P" hook_event_name="$1" "${@:3}"; }
  round() {  # round <prefix> <note-format session> — every event once; ${prefix}_<event> holds what it did
    local pre=$1 c ev
    hk session-start "$(hookin SessionStart source=startup)"; c=$(ctx); printf -v "${pre}_start" %s "${c:0:8}"
    hk session-start-2 "$(hookin SessionStart source=startup)"; c=$(ctx); printf -v "${pre}_start2" %s "${c:0:8}"
    ev=$(eps pre-compact); hk pre-compact "$(hookin PreCompact trigger=auto transcript_path="$tr")"
    printf -v "${pre}_precompact" %s "$(( $(eps pre-compact) - ev ))"
    hk post-compact "$(hookin PostCompact trigger=auto compact_summary="SUMMARY-MARKER")"
    printf -v "${pre}_postcompact" %s "$(ls "$(sdir)/summaries" 2>/dev/null | wc -l | tr -d ' ')"
    : > "$e"; CLAUDE_ENV_FILE="$e" hk cwd-changed "$(hookin CwdChanged)"
    printf -v "${pre}_cwdchanged" %s "$(grep -c PATH= "$e")"
    hk guard-bash "$(hookin PreToolUse sA agent_id=sub1 tool_name=Bash tool_input='{"command":"brain op add --kind now --text x"}')"
    printf -v "${pre}_guardbash" %s "$(hfield permissionDecision)"
    hk guard-edit "$(hookin PreToolUse sA tool_name=Edit tool_input="{\"file_path\":\"$root/x/hot.jsonl\"}")"
    printf -v "${pre}_guardedit" %s "$(hfield permissionDecision)"
    hk guard-owner "$(hookin PreToolUse sA tool_name=Bash permission_mode=default tool_input='{"command":"brain owner backup off"}')"
    printf -v "${pre}_guardowner" %s "$(hfield permissionDecision)"
    PATH="$old/bin:$PATH" hk guard-path "$(hookin PreToolUse sB tool_name=Bash tool_input='{"command": "brain op add --kind now --text y"}')"
    printf -v "${pre}_guardpath" %s "$(hfield permissionDecision)"
    ev=$(eps session-format); hk note-format "$(hookin PreToolUse "$2" tool_name=Bash permission_mode=default tool_input='{"command":"brain doctor"}')"
    printf -v "${pre}_noteformat" %s "$(( $(eps session-format) - ev ))"
    rm -f "$(sdir)/merge-evidence-bg.json" "$(sdir)/close-linked-bg.json"
    PATH="$gh:$PATH" hk prompt "$(hookin UserPromptSubmit sA prompt=next)"
    printf -v "${pre}_prompt" %s "$([ -e "$(sdir)/merge-evidence-bg.json" ] && echo started || echo none)"
    ev=$(eps session-end); hk session-end "$(hookin SessionEnd sA reason=other)"
    printf -v "${pre}_sessionend" %s "$(( $(eps session-end) - ev ))"
  }
  mkdir -p "$P/.vibemaestro"; printf '%s' "$off" > "$P/.vibemaestro/sdlc.json"
  round X sOld
  rm -f "$P/.vibemaestro/sdlc.json"
  round Y sOld2
  c_eq "$X_start|$Y_start" "|# vibema" "[HF] session-start: nothing under hooks: off, the strings without it"
  c_eq "$X_start2|$Y_start2" "|## Brain" "[HF] session-start-2: nothing under hooks: off, string 2 without it"
  c_eq "$X_precompact|$Y_precompact" "0|1" "[HF] pre-compact: no episode line under hooks: off, one without it"
  c_eq "$X_postcompact|$Y_postcompact" "0|1" "[HF] post-compact: no summary saved under hooks: off, one without it"
  c_eq "$X_cwdchanged|$Y_cwdchanged" "0|1" "[HF] cwd-changed: no PATH line under hooks: off, one without it"
  c_eq "$X_guardbash|$Y_guardbash" "|deny" "[HF] guard-bash: no decision under hooks: off, deny without it"
  c_eq "$X_guardedit|$Y_guardedit" "|deny" "[HF] guard-edit: no decision under hooks: off, deny without it"
  c_eq "$X_guardowner|$Y_guardowner" "|deny" "[HF] guard-owner: no decision under hooks: off, deny without it"
  c_eq "$X_guardpath|$Y_guardpath" "|deny" "[HF] guard-path: no decision under hooks: off, deny without it"
  c_eq "$X_noteformat|$Y_noteformat" "0|1" "[HF] note-format: no session-format line under hooks: off, one without it"
  c_eq "$X_prompt|$Y_prompt" "none|started" "[HF] prompt: no background job under hooks: off, one without it"
  c_eq "$X_sessionend|$Y_sessionend" "0|1" "[HF] session-end: no episode line under hooks: off, one without it"
  # where the file sits and what it holds: the reader is sdlc's, so the answers are sdlc's
  local lone="$TMP/lone$NP" errf="$TMP/err$NP"
  sstart() {  # sstart <cwd> [brain root] — the first characters of string 1 for a new session in <cwd>, `none` when silent
    local b=${2:-$BROOT}
    OUT=$(hin session_id=sV cwd="$1" hook_event_name=SessionStart source=startup | hookpy "$b/scripts/brain_hook.py" session-start 2>"$errf"); RC=$?
    local c; c=$(ctx); if [ -n "$c" ]; then echo "${c:0:8}"; else echo none; fi
  }
  mkdir -p "$lone/plugins"; cp -R "$BROOT" "$lone/plugins/"
  printf '%s' "$off" > "$P/.vibemaestro/sdlc.json"
  c_eq "$(sstart "$sub")" none "[HF] the file at the top of the history, the session in a subfolder: silent"
  c_eq "$(sstart "$P" "$lone/plugins/vibemaestro-brain")|$RC|$(cat "$errf")" "# vibema|0|" "[HF] no sdlc beside the brain: it runs, nothing on stderr"
  rm -f "$P/.vibemaestro/sdlc.json"; mkdir -p "$sub/.vibemaestro"; printf '%s' "$off" > "$sub/.vibemaestro/sdlc.json"
  c_eq "$(sstart "$sub")|$(sstart "$P")" "none|# vibema" "[HF] the file in a subfolder: silent there, the folder above still runs"
  rm -f "$sub/.vibemaestro/sdlc.json"; mkdir -p "$P/.vibemaestro"
  printf '{"hooks": "off", "schema": 9}' > "$P/.vibemaestro/sdlc.json"
  c_eq "$(sstart "$P")" none "[HF] hooks: off beside a key that makes the file invalid: still silent (sdlc_config.hooks_off_at reads it raw)"
  printf 'not json' > "$P/.vibemaestro/sdlc.json"
  c_eq "$(sstart "$P")|$RC|$(cat "$errf")" "# vibema|0|" "[HF] a file that is not JSON: the brain runs"
  printf '{"hooks": "auto"}' > "$P/.vibemaestro/sdlc.json"
  c_eq "$(sstart "$P")" "# vibema" "[HF] hooks: auto: the brain runs"
  rm -f "$P/.vibemaestro/sdlc.json"; mkdir "$P/.vibemaestro/sdlc.json"
  c_eq "$(sstart "$P")|$RC|$(cat "$errf")" "# vibema|0|" "[HF] a directory at the config path: the brain runs"
  rmdir "$P/.vibemaestro/sdlc.json"; printf '%s' "$off" > "$P/.vibemaestro/sdlc.json"
  c_eq "$(CLAUDE_PROJECT_DIR="$P" sstart "$TMP")" none "[HF] CLAUDE_PROJECT_DIR names the folder, whatever the input's cwd: silent"
  # a declined dialog's record dies at the session's next Bash call, with hooks off too (the file can appear mid-session)
  asked() { rec default sA backup off; bpy 'import hashlib, os
d = os.path.join(os.environ["XDG_STATE_HOME"], "vibemaestro", "brain", "pending"); os.makedirs(d, exist_ok=True)
open(os.path.join(d, hashlib.sha256(b"sA").hexdigest()[:32]), "w").write(s.state_dir())'; }
  local nrec; nrec() { find "$(sdir)/asked" -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
  asked; c_eq "$(nrec)" 1 "[HF] instrument: an asked record and its pending marker exist"
  hk guard-owner "$(hookin PreToolUse sA tool_name=Bash permission_mode=default tool_input='{"command":"ls"}')"
  c_eq "$(nrec)|$OUT" "0|" "[HF] hooks: off: the next Bash call still voids the declined dialog's record"
  asked; hk session-end "$(hookin SessionEnd sA reason=clear)"
  c_eq "$(nrec)|$OUT" "0|" "[HF] hooks: off: /clear (session-end) voids the declined dialog's record too"
  rm -f "$P/.vibemaestro/sdlc.json"; asked
  hk guard-owner "$(hookin PreToolUse sA tool_name=Bash permission_mode=default tool_input='{"command":"ls"}')"
  c_eq "$(nrec)|$OUT" "0|" "[HF] without it: the same call voids it too"
  asked; hk session-end "$(hookin SessionEnd sA reason=clear)"
  c_eq "$(nrec)" 0 "[HF] without it: session-end voids it too"
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
  c_has "$ERR" "brain hook pre-compact: $([ "${OS:-}" = Windows_NT ] && echo PermissionError || echo IsADirectoryError)" "[C] one stderr line names it (Windows names a directory opened as a file PermissionError)"
  hk session-start 'not json'; c_rc 0 "[C] input that is not JSON: rc 0"
}

case_cut() {
  newp
  R=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import brain_hook as h
b = "# frame\n" + "".join("- line %04d %s\n" % (i, "x" * 80) for i in range(90)) + "## Shelf index (skills)\n" + "- s\n" * 400
b += "- more %s\n" % ("y" * 90) * 20
out, gone = h.cut(b, 9500)
print(len(b) > 9500, len(out) <= 9500, out.splitlines()[-1].startswith("[brain: cut"), "Shelf index" in out.splitlines()[-1], gone > 0)' "$BROOT/scripts")
  c_eq "$R" "True True True True True" "[K] an oversize block is cut to ≤ 9,500 at a line, the last line names what was cut"
}

pick_checks() {  # pick_checks <live script> — the key choice on recorded Claude Code menus (B1.2a)
  local s=$1 T='^Yes, (I trust this folder|proceed)' Y='^Yes$'
  # the key alone (Python on Windows ends its line with CR LF); the script's own Python reads the screen as UTF-8 (a helper)
  pk() { PYTHONUTF8=1 bash "$s" --pick-key "$1" | tr -d '\r'; }
  c_eq "$(printf ' Security guide\n ❯ No, exit\n   Yes, I trust this folder\n Enter to confirm · Esc to cancel\n' | pk "$T")" Down "[P2] trust dialog of 2.1.290/2.1.302, cursor on No first: Down"
  c_eq "$(printf ' Security guide\n   No, exit\n ❯ Yes, I trust this folder\n' | pk "$T")" Enter "[P2] then, the cursor on Yes: Enter"
  c_eq "$(printf ' Do you trust the files in this folder?\n ❯ 1. Yes, proceed\n   2. No, exit\n' | pk "$T")" Enter "[P2] an older dialog with Yes first: Enter"
  c_eq "$(printf '> Run exactly this one Bash command\n Do you want to proceed?\n ❯ 1. Yes\n   2. Yes, and don'"'"'t ask again for brain commands\n   3. No\n' | pk "$Y")" Enter "[P2] permission prompt: the plain Yes (a quoted > line beside a ❯ menu is not the cursor)"
  c_eq "$(printf ' Do you want to proceed?\n   1. Yes\n ❯ 2. Yes, and don'"'"'t ask again\n   3. No\n' | pk "$Y")" Up "[P2] the cursor on \"don't ask again\": Up to the plain Yes, never Enter there"
  c_eq "$(printf ' Do you want to proceed?\n 1. Yes\n 2. No\n' | pk "$Y")" 1 "[P2] a numbered menu with no cursor: its number"
  c_eq "$(printf ' something else\n ❯ No, exit\n' | pk "$T")" none "[P2] no matching option: no key"
  c_eq "$(printf '> quoted prompt\n 1. Yes\n 2. No\n' | pk "$Y")" 1 "[P2] a quoted > line and a numbered menu with no cursor: the number, not Down"
  c_eq "$(printf ' Do you want to proceed?\n ❯ 1. Yes\n   2. No\n\n ❯ \n' | pk "$Y")" Enter "[P2] an empty input line under the menu is not its cursor"
  c_eq "$(printf ' Yes\n Menu\n 1. Yes\n 2. No\n' | pk "$Y")" 1 "[P2] a stray Yes line above a numbered menu: the numbered one"
  printf 'x\n' | bash "$s" --pick-key '(' >/dev/null 2>&1; c_eq "$?" 1 "[P2] a choice that cannot be made (bad pattern): rc 1, no key"
}

case_pick() {
  newp
  local s="$SRC_ROOT/tests/live/brain-owner-dialog.sh"
  pick_checks "$s"
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

case_codepage() {  # a hook's input read in the system code page (Windows' pipes): a guard must still see a path that is not ASCII
  newp
  export XDG_STATE_HOME="$TMP/trạng thái $NP"
  br op add --kind now --text "a store under a Vietnamese name"
  PYTHONIOENCODING=cp1252 hk guard-edit "$(hin session_id=sA cwd="$P" tool_name=Edit tool_input="{\"file_path\":\"$XDG_STATE_HOME/vibemaestro/brain/x/hot.jsonl\"}")"
  c_eq "$(hfield permissionDecision)" deny "[CP] an edit under a state root named in Vietnamese is denied with the hook's streams in the code page (main: read as cp1252, let through)"
}

card() { ctx | grep -F 'bare `brain`'; }

case_path() {
  newp
  br op add --kind now --text "x"
  local e="$TMP/env$NP" old="$TMP/old$NP/plugins/vibemaestro-brain" G
  mkdir -p "$old/bin" "$old/scripts"; : > "$old/scripts/brain.py"
  printf '#!/bin/sh\necho "stand-in brain ran"\n' > "$old/bin/brain"; chmod +x "$old/bin/brain"
  : > "$e"
  if [ "${OS:-}" = Windows_NT ]; then
    CLAUDE_ENV_FILE="$e" PATH="$old/bin:$PATH" start startup
    c_eq "$(cat "$e")" "" "[PA] Windows: no PATH line (it would keep every hook's variables from PowerShell commands)"
    PATH="$old/bin:$PATH" hk guard-path "$(hin session_id=sW cwd="$P" tool_name=Bash tool_input='{"command": "brain op add --kind now --text y"}')"
    c_eq "$(hfield permissionDecision)" deny "[PA] Windows: the hook finds the older brain's bin/brain, which has no extension, and denies its write (e2cf850: shutil.which found none)"
    c_skip "[PA] the PATH line and the path-literal checks" "POSIX only: no line on Windows, and its paths are spelled C:/…"
    return
  fi
  CLAUDE_ENV_FILE="$e" PATH="$old/bin:$PATH" start startup
  c_eq "$(cat "$e")" "export PATH=$BROOT/bin:\"\$PATH\"" "[PA] session-start puts this brain's bin first on PATH in CLAUDE_ENV_FILE (main: the file stays empty)"
  c_eq "$(card)" "brain: a bare \`brain\` runs $BROOT" "[PA] string 1 names the brain a bare \`brain\` runs (main: no line)"
  c_eq "$(PATH="$old/bin:$PATH" bash -c '. "$1"; command -v brain' _ "$e")" "$BROOT/bin/brain" "[PA] a shell that runs the file finds this brain before the older one first on its PATH"
  CLAUDE_ENV_FILE="$e" start resume
  c_eq "$(grep -c PATH= "$e")" 1 "[PA] a second start leaves one line"
  : > "$e"
  CLAUDE_ENV_FILE="$e" hk cwd-changed "$(hin session_id="$SID" cwd="$P" hook_event_name=CwdChanged)"
  c_eq "$(cat "$e")" "export PATH=$BROOT/bin:\"\$PATH\"" "[PA] cwd-changed writes it again after Claude Code cleared the file"
  G="$(hin session_id="$SID" cwd="$P" tool_name=Bash tool_input='{"command": "brain op add --kind now --text y"}')"
  PATH="$old/bin:$PATH" hk guard-path "$G"
  c_eq "$OUT" "" "[PA] guard-path is silent when the session's start put this brain first, whatever older one the hook's PATH holds"
  SID=sB
  G="$(hin session_id=sB cwd="$P" tool_name=Bash tool_input='{"command": "cd /tmp && brain op add --kind now --text y"}')"
  PATH="$old/bin:$PATH" hk guard-path "$G"
  c_eq "$(hfield permissionDecision)" deny "[PA] another session, no PATH line: a write through a bare \`brain\` that is another brain is denied (main: no such hook)"
  c_eq "$(hfield permissionDecisionReason)" "brain: a bare \`brain\` here runs $TMP/old$NP/plugins/vibemaestro-brain, not the installed brain $BROOT, so its writes are refused: run $BROOT/bin/brain with the same arguments" "[PA] …naming both and the command to run"
  PATH="$old/bin:$PATH" hk guard-path "$(hin session_id=sB cwd="$P" tool_name=Bash tool_input='{"command": "brain show N1"}')"
  c_eq "$(hfield permissionDecision)|$(hfield additionalContext)" "|brain: a bare \`brain\` here runs $TMP/old$NP/plugins/vibemaestro-brain, not the installed brain $BROOT; its answer comes from that code" "[PA] a read runs, with one line for Claude"
  PATH="$BROOT/bin:$old/bin:$PATH" hk guard-path "$G"
  c_eq "$OUT" "" "[PA] control: this brain first on the hook's PATH, nothing said"
  local unrel="$TMP/unrel$NP" tree="$TMP/tree$NP/plugins/vibemaestro-brain"
  mkdir -p "$unrel/bin"; printf '#!/bin/sh\n' > "$unrel/bin/brain"; chmod +x "$unrel/bin/brain"
  PATH="$unrel/bin:$PATH" hk guard-path "$G"
  c_eq "$OUT" "" "[PA] a \`brain\` with no scripts/brain.py beside it is not a brain: nothing said (e2cf850: denied, naming it)"
  mkdir -p "$TMP/tree$NP/.git" "$tree/bin" "$tree/scripts"; : > "$tree/scripts/brain.py"
  cp "$old/bin/brain" "$tree/bin/brain"
  PATH="$tree/bin:$PATH" hk guard-path "$G"
  c_eq "$(hfield permissionDecision)|$(hfield additionalContext)" "|brain: a bare \`brain\` here runs $tree, not the installed brain $BROOT; it runs from a repository's tree, so its writes are let through" "[PA] a brain in a repository's tree: its write goes on with one line, as its own check only warns (e2cf850: denied)"
  PATH="$old/bin:$PATH" hk guard-path "$(hin session_id=sB cwd="$P" tool_name=Bash tool_input='{"command": "brain show N1 | grep -c brain; echo brain op"}')"
  c_eq "$(hfield permissionDecision)" "" "[PA] a \`brain\` word outside command position is not a write (e2cf850: denied)"
  PATH="$old/bin:$PATH" hk guard-path "$(hin session_id=sB cwd="$P" tool_name=Bash tool_input='{"command": "BRAIN_X=1 brain op touch N1"}')"
  c_eq "$(hfield permissionDecision)" deny "[PA] …a \`VAR=value\` before it still leaves it in command position"
  local cmd
  for cmd in 'for id in N1 N2; do brain op touch "$id"; done' 'env brain op touch N1' 'time brain op touch N1' 'if brain op touch N1; then :; fi'; do
    PATH="$old/bin:$PATH" hk guard-path "$(hin session_id=sB cwd="$P" tool_name=Bash tool_input="$(hin command="$cmd")")"
    c_eq "$(hfield permissionDecision)" deny "[PA] round 2: a write after a shell keyword or wrapper is still denied: $cmd (814a198: let through)"
  done
  PATH="$tree/bin:$PATH" start startup
  c_eq "$(card)" "brain: a bare \`brain\` runs $tree, not the installed brain $BROOT; it runs from a repository's tree, so its writes are let through" "[PA] round 2: string 1 says a tree brain's writes go through, as both checks let them (814a198: said refused)"
  PATH="$old/bin:$PATH" start startup
  c_eq "$(card)" "brain: a bare \`brain\` runs $TMP/old$NP/plugins/vibemaestro-brain, not the installed brain $BROOT: its writes are refused (brain doctor)" "[PA] no PATH line, an older brain first: string 1 names both"
  PATH="/usr/bin:/bin" start startup
  c_eq "$(card)" "brain: the installed brain is $BROOT; which brain a bare \`brain\` runs is not known here (brain doctor)" "[PA] no PATH line and no brain on the hook's PATH: said so"
  : > "$e"
  CLAUDE_ENV_FILE="$e" BRAIN_OFF=1 start startup; CLAUDE_ENV_FILE="$e" VIBEMAESTRO_ROLE=worker start startup
  c_eq "$(cat "$e")" "" "[PA] BRAIN_OFF and a worker write no line"
  SID=sA
  local mark; mark=$(bpy 'print(s.session_file("sA") + ".env")')
  c_eq "$(cat "$mark")" "$BROOT/bin" "[PA] the session's mark names the bin put first"
  hk session-end "$(hin session_id=sA cwd="$P" hook_event_name=SessionEnd reason=other)"
  c_eq "$([ -e "$mark" ] && echo kept || echo gone)" gone "[PA] session-end removes the mark"
  local sp="$TMP/with space $NP"
  mkdir -p "$sp/plugins"; cp -R "$BROOT" "$sp/plugins/"; : > "$e"
  OUT=$(printf '%s' "$(hin session_id=sC cwd="$P" hook_event_name=SessionStart source=startup)" | CLAUDE_ENV_FILE="$e" hookpy "$sp/plugins/vibemaestro-brain/scripts/brain_hook.py" session-start 2>&1)
  c_eq "$(PATH="$old/bin:$PATH" bash -c '. "$1"; command -v brain' _ "$e")" "$sp/plugins/vibemaestro-brain/bin/brain" "[PA] a bin whose path holds a space is quoted in the line"
}

echo "== cases =="
for c in case_path case_root case_caps case_shelf case_compact case_guards case_session case_end case_off case_hooks_off case_corrupt case_cut case_live case_pick case_codepage; do run_case $c; done

echo "== [NW] the store cannot load (Windows: no fcntl, no pwd): Claude is told, the person sees no fixed line, the guards refuse =="
# A sitecustomize on PYTHONPATH takes fcntl and pwd out of the module table: what Windows Python lacks
NW="$TMP/nowin"; mkdir -p "$NW"; printf 'import sys\nsys.modules["fcntl"] = None\nsys.modules["pwd"] = None\n' > "$NW/sitecustomize.py"
# on Windows the store takes ctypes and msvcrt instead: without ctypes it cannot load there either
[ "${OS:-}" != Windows_NT ] || printf 'sys.modules["ctypes"] = None\n' >> "$NW/sitecustomize.py"
nw() { PYTHONPATH="$NW" hk "$@"; }
eq "$(PYTHONPATH="$NW" python3 -c 'import fcntl' >/dev/null 2>&1; echo $?)" 1 "instrument: under the stand-in, fcntl cannot be imported"
NWP="$TMP/nowin-proj"; mkdir -p "$NWP"; git_ -C "$NWP" init -q
nw session-start "$(hin session_id=sNW cwd="$NWP" hook_event_name=SessionStart source=startup)"
has "$(ctx)" "vibemaestro-brain cannot run on this machine yet" "[NW] the session start tells Claude, in its context, that the brain cannot run here (main: nothing, the hook died on import)"
has "$(ctx)" "tell them in their own language" "[NW] …and to tell the person in their own language only when it matters"
eq "$(printf '%s' "$OUT" | python3 -c 'import json, sys; print("systemMessage" in json.loads(sys.stdin.read() or "{}"))')|$RC" "False|0" "[NW] …with no line shown to the person, rc 0"
nw guard-owner "$(hin session_id=sNW cwd="$NWP" hook_event_name=PreToolUse tool_name=Bash tool_input="$(hin command='brain owner pin --text x')")"
eq "$(hfield permissionDecision)" deny "[NW] an owner call is refused when the store cannot load (main: let through)"
nw guard-owner "$(hin session_id=sNW cwd="$NWP" hook_event_name=PreToolUse tool_name=Bash tool_input="$(hin command='git log --grep "brain owner"')")"
eq "$(hfield permissionDecision)" "" "[NW] …a command that only mentions it is not"
nw guard-edit "$(hin session_id=sNW cwd="$NWP" hook_event_name=PreToolUse tool_name=Edit tool_input="$(hin file_path="$XDG_STATE_HOME/vibemaestro/brain/x/hot.jsonl")")"
eq "$(hfield permissionDecision)" deny "[NW] an edit inside the brain's state folder is refused when the store cannot load (main: let through)"
nw guard-edit "$(hin session_id=sNW cwd="$NWP" hook_event_name=PreToolUse tool_name=Edit tool_input="$(hin file_path="$NWP/notes.md")")"
eq "$(hfield permissionDecision)" "" "[NW] …an edit of the person's own file is not"
nw guard-bash "$(hin session_id=sNW agent_id=a1 cwd="$NWP" hook_event_name=PreToolUse tool_name=Bash tool_input="$(hin command='brain op add --kind now --text x')")"
eq "$(hfield permissionDecision)" deny "[NW] a subagent's brain op is still refused (that guard never needed the store)"
NF="$TMP/nofcntl"; mkdir -p "$NF"; printf 'import sys\nsys.modules["fcntl"] = None\n' > "$NF/sitecustomize.py"   # no fcntl, pwd still there (a broken POSIX install)
if [ "${OS:-}" = Windows_NT ]; then
  echo "  SKIP [NW] with HOME empty, the folder under the account's home: no pwd on Windows, the account's home is the token's profile (store [WP])"
else
AH=$(python3 -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')
OUT=$(printf '%s' "$(hin session_id=sNW cwd="$NWP" hook_event_name=PreToolUse tool_name=Edit tool_input="$(hin file_path="$AH/.local/state/vibemaestro/brain/x/hot.jsonl")")" \
      | env -u XDG_STATE_HOME HOME= PYTHONPATH="$NF" python3 "$BROOT/scripts/brain_hook.py" guard-edit 2>/dev/null)
eq "$(hfield permissionDecision)" deny "[NW] with HOME empty, the store's folder under the account's home is refused too, as the store places it (expanduser gave /)"
fi

cd "$TMP" || exit 1

summary
