#!/bin/bash
# =============================================================================
# vibemaestro-brain: brain matrix, brain cost, the cost episode lines, and the probe's logic against a fake claude
# =============================================================================
# Run: bash tests/test-brain-matrix.sh
#
#   [M] brain matrix: seven rows, each ≤ 300 bytes at its widest; the header names the axes; --json has the same rows
#   [L] the code intelligence (external) row lists exactly the enabled `*-lsp`, `.lsp.json`/`lspServers` and `serena` plugins;
#       a disabled one is not listed; CLAUDE_CODE_REMOTE=true says "not started"
#   [H] the Know·hot row names the repo index (shared, sdlc, planned); skill matrix is user-only; brain's manifest carries no version
#   [D] "this session": hook lines, injected characters, compactions and loss of this session only
#   [C] brain cost on a fabricated transcript reproduces a hand-computed split: one call per message.id (the largest value of a
#       field), sidechain and <synthetic> records skipped, a non-JSON line and a cut last line skipped, the 5-minute and 1-hour
#       write weights, a write with no TTL split at 2x; the gap over 1 h with its re-write; rc 2 on a missing file
#   [G] --merge-log: merged PRs in the transcript's span, each PR once, then units per merged PR
#   [U] pre-compact running sums from byte offsets (a cut mid-line, a cut between two records of one message) equal one full
#       parse; a shorter file restarts at 0; session-end appends the cost line in under 1.5 s without reading the transcript
#   The probe (tests/live/brain-probe.sh), against tests/fixtures/brain-probe/fake_claude.py, never a live claude:
#   [Q] the pass path: method 1 (auto); H 10/10, C K/10 (the fake's summary keeps K of 10); injected from the brain's own
#       counter, ≤ 8,000; the store seeded with the 10 decisions; a shrunk filler is labelled "not an exit run"; the plant
#       holds 10 decisions and 10 floated drafts (a near miss each, never an anchor) in the fixed order
#   [F] method 1 not compacting falls back to method 2 on a fresh fork; method 2's ask runs with the brain off in both arms
#   [N] no method compacts: stopped before any score (rc 2)
#   [A] the grader: a hedge with a near miss, or another item's anchor on the line, is wrong; markdown and case are not
#   [W] auto memory written during the run voids it (rc 2)
#   [P] preflight: not logged in, two brains loaded, a missing CLI flag each stop it (rc 2)
#   [D2] the brain's manifest depends on vibemaestro-sdlc, which Claude Code does not enable under --setting-sources project,local:
#       the probe loads this checkout's sdlc by --plugin-dir in every session; without it the preflight stops before anything
#       is spent, naming the dependency; a version outside the range stops; the fake refuses a plugin whose dependency is not
#       loaded (its hooks do not run), which the old probe met as "0 brains loaded"
#   [S] the sdlc runs silent in the probe (`hooks: off` in the scratch project): no transcript holds its SessionStart text, and the
#       preflight stops, saying so, when it does
#   [T] the control at 10/10: rc 3, "not shown necessary at this size"
#   [Z] --plan prints the protocol, the cost and the command, and starts nothing; the script parses
#   [I] H is isolated: its block arrives only at SessionStart:compact (BRAIN_TEST_SOURCES), so a summary that would copy an
#       earlier block has none to copy, and a model that ignores the block scores what the summary kept (FAIL)
#   [J] void, not scored: H's transcript lacks the SessionStart:compact block; the shared history was compacted before the fork
#   [R] a crash is rc 2, never rc 1 (FAIL); a second run in the same --work works
#   [K] the brain hook's BRAIN_TEST_SOURCES: honoured only with BRAIN_TEST=1, it limits injection to the named sources
#   [X] planted breaks: each case goes red on a copy with one break
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
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
# shellcheck source=fixtures/brain.sh
. "$HERE/fixtures/brain.sh"
brain_kit "$SRC_ROOT"
unset CLAUDE_CODE_REMOTE CLAUDE_CODE_SESSION_ID

rows() { printf '%s\n' "$1" | grep -E '^(Know|Do)·(hot|warm|cold) \|'; }
row() { rows "$1" | grep -F -- "$2" | head -n 1; }
lastep() { tail -n 1 "$(sdir)/episodes.jsonl"; }
jget() { python3 -c 'import json, sys
v = json.loads(sys.stdin.read())
for k in sys.argv[1].split("."):
    v = v[int(k)] if isinstance(v, list) else v.get(k)
print(json.dumps(v, sort_keys=True) if isinstance(v, (dict, list)) else v)' "$1"; }

# A transcript in Claude Code's recorded shape: one line per record, two records per API response (same message.id).
# tr_write <file> — the fixed fabric of [C] and [U]; the hand computation is in case_cost.
tr_write() {
  python3 - "$1" <<'PY'
import json, sys
def a(mid, ts, inp, read, w1h, w5m, out, other=None, side=False, model="claude-opus-5-5", block="text"):
    u = {"input_tokens": inp, "cache_read_input_tokens": read, "output_tokens": out}
    if other is None:
        u["cache_creation_input_tokens"] = w1h + w5m
        u["cache_creation"] = {"ephemeral_1h_input_tokens": w1h, "ephemeral_5m_input_tokens": w5m}
    else:
        u["cache_creation_input_tokens"] = other
    return {"type": "assistant", "timestamp": ts, "isSidechain": side, "requestId": "req_" + mid,
            "message": {"id": mid, "model": model, "role": "assistant", "content": [{"type": block}], "usage": u}}
L = [
    {"type": "user", "timestamp": "2026-10-19T10:00:00.000Z", "message": {"role": "user", "content": "the word usage in a prompt"}},
    a("m1", "2026-10-19T10:00:05.000Z", 10, 0, 1000, 0, 100, block="thinking"),
    a("m1", "2026-10-19T10:00:06.000Z", 10, 0, 1000, 0, 100),
    a("m2", "2026-10-19T10:01:00.000Z", 5, 1000, 200, 0, 1, block="thinking"),
    a("m2", "2026-10-19T10:01:02.000Z", 5, 1000, 200, 0, 50),
    a("m3", "2026-10-19T10:02:00.000Z", 9, 99999, 9999, 0, 999, side=True),
    a("m4", "2026-10-19T10:03:00.000Z", 0, 0, 0, 0, 0, model="<synthetic>"),
    "not json at all \"usage\" \"assistant\"",
    a("m5", "2026-10-19T12:01:02.000Z", 0, 1200, 0, 1200, 20),
    a("m5", "2026-10-19T12:01:03.000Z", 0, 1200, 0, 1200, 20),
    a("m6", "2026-10-19T12:05:00.000Z", 0, 2400, 0, 0, 10, other=400),
]
with open(sys.argv[1], "w", encoding="utf-8") as f:
    for r in L:
        f.write((r if isinstance(r, str) else json.dumps(r)) + "\n")
    f.write(json.dumps(a("m7", "2026-10-19T12:06:00.000Z", 1, 1, 1, 1, 1))[:60])   # a record cut mid-write: no newline
PY
}

case_cost() {
  newp
  local tr="$TMP/cost$NP.jsonl"
  tr_write "$tr"
  # By hand: m1 in 10, write 1h 1000, out 100 (ctx 1010); m2 in 5, read 1000, write 1h 200, out 50, the larger of its two
  # records (ctx 1205); m5 read 1200, write 5m 1200, out 20 (ctx 2400), 2 h after m2; m6 read 2400, write 400 with no TTL
  # split, out 10 (ctx 2800). m3 (sidechain), m4 (<synthetic>), the non-JSON line and the cut m7 are skipped.
  # Units: input 15; read 4,600 x 0.05 = 230 (0.03935 less a hair of the total: 0.0393); write 1,200 x 2 + 1,200 x 1.25 + 400 x 2 = 4,700; output 180 x 5 = 900; total 5,845.
  br cost "$tr" --json; c_rc 0 "[C] brain cost --json rc 0"
  local J=$OUT
  c_eq "$(printf '%s' "$J" | jget calls)" 4 "[C] four calls: one per message.id, sidechain and <synthetic> skipped"
  c_eq "$(printf '%s' "$J" | jget tokens)" '{"input": 15, "output": 180, "read": 4600, "write_1h": 1200, "write_5m": 1200, "write_other": 400}' "[C] token sums, the largest value of each field per message.id"
  c_eq "$(printf '%s' "$J" | jget units.total)" 5845.0 "[C] units at A's weights: 5,845"
  c_eq "$(printf '%s' "$J" | jget split)" '{"input": 0.0026, "output": 0.154, "read": 0.0393, "write": 0.8041}' "[C] the split"
  c_eq "$(printf '%s' "$J" | jget context_mean)" 1853.75 "[C] mean context per call"
  c_eq "$(printf '%s' "$J" | jget context_max)" 2800 "[C] max context per call"
  c_eq "$(printf '%s' "$J" | jget skipped)" '{"sidechain": 1, "synthetic": 1, "unreadable": 2}' "[C] what was skipped is counted"
  c_eq "$(printf '%s' "$J" | jget gaps.0.rewrite)" 1200 "[C] the gap over 1 h and the re-write after it"
  c_eq "$(printf '%s' "$J" | jget gaps.0.seconds)" 7202 "[C] the gap's length"
  br cost "$tr"; c_rc 0 "[C] brain cost (text) rc 0"
  c_has "$OUT" "read 3.9% · write 80.4% · output 15.4% · input 0.3%" "[C] the text names the split"
  c_has "$OUT" "4 calls" "[C] and the call count"
  c_has "$OUT" "mean 1,854 · max 2,800" "[C] and the context per call"
  c_has "$OUT" "re-write 1,200" "[C] and the gap's re-write"
  br cost "$TMP/missing.jsonl"; c_rc 2 "[C] a file that cannot be read: rc 2"
}

case_merge() {
  newp
  local tr="$TMP/merge$NP.jsonl" ml="$TMP/merge$NP.log"
  tr_write "$tr"
  { echo '{"time":"2026-10-19T09:00:00Z","repo":"o/r","pr":1,"result":"merged"}'
    echo '{"time":"2026-10-19T10:30:00Z","repo":"o/r","pr":2,"result":"merged"}'
    echo '{"time":"2026-10-19T10:31:00Z","repo":"o/r","pr":2,"result":"merged"}'
    echo '{"time":"2026-10-19T11:00:00Z","repo":"o/r","pr":3,"result":"refused"}'
    echo 'not json'
    echo '{"time":"2026-10-19T12:04:00Z","repo":"o/s","pr":2,"result":"merged"}'
    echo '{"time":"2026-10-20T00:00:00Z","repo":"o/r","pr":4,"result":"merged"}'; } > "$ml"
  br cost "$tr" --merge-log "$ml" --json; c_rc 0 "[G] --merge-log rc 0"
  c_eq "$(printf '%s' "$OUT" | jget merged)" 2 "[G] two PRs merged in the span (one logged twice; one before, one after, one refused)"
  c_eq "$(printf '%s' "$OUT" | jget units_per_merged_pr)" 2922.5 "[G] units per merged PR"
  br cost "$tr" --merge-log "$ml"; c_has "$OUT" "merged PRs in the span: 2 · units per merged PR 2,922" "[G] the text line"
}

case_sums() {
  newp
  br op add --kind now --text "state for the hooks"
  local tr="$TMP/sums$NP.jsonl" full="$TMP/full$NP.jsonl" n cut1 cut2 J E
  tr_write "$full"
  # cut 1: in the middle of m2's first record; cut 2: between m2's two records (one message across two reads)
  cut1=$(python3 -c 'import sys; d = open(sys.argv[1], "rb").read(); i = d.index(b"\"m2\""); print(i)' "$full")
  cut2=$(python3 -c 'import sys; d = open(sys.argv[1], "rb").read(); i = d.index(b"\"m2\""); print(d.index(b"\n", i) + 1)' "$full")
  for n in "$cut1" "$cut2" full; do
    if [ "$n" = full ]; then cp "$full" "$tr"; else head -c "$n" "$full" > "$tr"; fi
    hk pre-compact "$(hin session_id="$SID" cwd="$P" hook_event_name=PreCompact trigger=auto transcript_path="$tr")"
  done
  c_eq "$OUT$ERR" "" "[U] pre-compact prints nothing"
  local t0 t1
  t0=$(python3 -c 'import time; print(time.time())')
  rm -f "$tr"                     # session-end must not need the transcript
  hk session-end "$(hin session_id="$SID" cwd="$P" hook_event_name=SessionEnd reason=other transcript_path="$tr")"
  t1=$(python3 -c 'import time; print(time.time())')
  c_eq "$(python3 -c 'import sys; print(float(sys.argv[2]) - float(sys.argv[1]) < 1.5)' "$t0" "$t1")" True "[U] session-end within 1.5 s"
  E=$(grep '"kind":"cost"' "$(sdir)/episodes.jsonl" | tail -n 1)
  c_eq "$(printf '%s' "$E" | jget kind)" cost "[U] session-end appends a cost line"
  br cost "$full" --json; J=$OUT
  c_eq "$(printf '%s' "$E" | jget tokens)" "$(printf '%s' "$J" | jget tokens)" "[U] sums from three offsets equal one full parse (tokens)"
  c_eq "$(printf '%s' "$E" | jget calls)" "$(printf '%s' "$J" | jget calls)" "[U] and the call count"
  c_eq "$(printf '%s' "$E" | jget units.total)" "$(printf '%s' "$J" | jget units.total)" "[U] and the units"
  c_eq "$(printf '%s' "$E" | jget through)" "2026-10-19T12:05:00.000Z" "[U] through: the time of the last counted call"
  # a shorter file (another transcript at the same path) restarts at 0
  head -c "$cut2" "$full" > "$tr"
  hk pre-compact "$(hin session_id="$SID" cwd="$P" hook_event_name=PreCompact trigger=auto transcript_path="$tr")"
  hk session-end "$(hin session_id="$SID" cwd="$P" hook_event_name=SessionEnd reason=other)"
  E=$(grep '"kind":"cost"' "$(sdir)/episodes.jsonl" | tail -n 1)
  c_eq "$(printf '%s' "$E" | jget calls)" 2 "[U] a shorter file restarts at 0 (m1 and m2 only)"
  hk session-end "$(hin session_id="$SID" cwd="$P" hook_event_name=SessionEnd reason=other)"
  c_eq "$(grep -c '"kind":"cost"' "$(sdir)/episodes.jsonl")" 2 "[U] a second session-end with no new compaction appends no second copy"
  # a session that never compacted gets no cost line
  SID=sZ; hk session-end "$(hin session_id=sZ cwd="$P" hook_event_name=SessionEnd reason=other)"
  c_eq "$(lastep | jget kind)" session-end "[U] no pre-compact, no cost line"
  SID=sA
}

lsp_registry() {  # lsp_registry — plugins of every kind in a fabricated registry and settings; CLAUDE_CONFIG_DIR points at them
  local cfg="$TMP/cfg$NP" n
  export CLAUDE_CONFIG_DIR="$cfg"
  mkdir -p "$cfg/plugins"
  local reg='{"version":2,"plugins":{' sep=""
  for n in pyright-lsp gopls-lsp serena lsp-json lsp-servers zz-nolang "$@"; do
    mkdir -p "$TMP/pl$NP/$n/.claude-plugin"
    printf '{"name":"%s"}' "$n" > "$TMP/pl$NP/$n/.claude-plugin/plugin.json"
    reg="$reg$sep\"$n@m\":[{\"scope\":\"user\",\"installPath\":\"$TMP/pl$NP/$n\"}]"; sep=,
  done
  printf '{"python":{"command":"pyright"}}' > "$TMP/pl$NP/lsp-json/.lsp.json"
  printf '{"name":"lsp-servers","lspServers":{"go":{"command":"gopls"}}}' > "$TMP/pl$NP/lsp-servers/.claude-plugin/plugin.json"
  printf '%s}}' "$reg" > "$cfg/plugins/installed_plugins.json"
  local en='{"enabledPlugins":{"pyright-lsp@m":true,"gopls-lsp@m":false,"serena@m":true,"lsp-json@m":true,"lsp-servers@m":true,"zz-nolang@m":true'
  for n in "$@"; do en="$en,\"$n@m\":true"; done
  printf '%s}}' "$en" > "$cfg/settings.json"
}

case_rows() {
  newp
  local t i links=()
  t=$(python3 -c 'print("t" * 150)')
  for i in 1 2 3 4 5 6 7 8; do links+=(--link "kb/$(python3 -c 'print("l" * 17)')"); done
  for i in 1 2 3 4 5 6 7 8 9; do owner_ok add --kind decision --text "$t" --owner-quote q --where w "${links[@]}"; done
  for i in 1 2 3; do br op add --kind now --text "$t" "${links[@]}"; done
  local many=()
  for i in $(seq -w 1 30); do many+=("very-long-language-server-name-number-$i-lsp"); done
  lsp_registry "${many[@]}"
  mkdir -p "$P/kb/decisions" "$P/kb/specs"; echo d > "$P/kb/decisions/a.md"; echo s > "$P/kb/specs/b.md"
  br matrix; c_rc 0 "[M] brain matrix rc 0"
  local R; R=$(rows "$OUT")
  c_eq "$(printf '%s\n' "$R" | grep -c .)" 7 "[M] seven rows"
  c_eq "$(printf '%s\n' "$R" | cut -d'|' -f1 | tr -d ' ' | tr '\n' ' ')" "Know·hot Do·hot Know·warm Do·warm Do·warm Know·cold Do·cold " "[M] one per cell, Do·warm twice"
  c_eq "$(printf '%s\n' "$R" | LC_ALL=C awk '{ if (length($0) > m) m = length($0) } END { print (m <= 300) ? "within" : "over " m }')" within "[M] every row ≤ 300 bytes, with 30 code-intelligence plugins and hot memory at Pinned 9/10"
  c_has "$(row "$OUT" "code intelligence")" "+" "[M] instrument: the code-intelligence list is cut with +N (the row was at its widest)"
  c_has "$OUT" "Know (left)" "[M] the header names the axes"
  c_has "$(row "$OUT" "Hot Memory")" "Pinned 9/10" "[M] the Know·hot warning at 0.85 of a cap"
  br matrix --json; c_rc 0 "[M] --json rc 0"
  c_eq "$(printf '%s' "$OUT" | python3 -c 'import json, sys; print(len(json.load(sys.stdin)["rows"]))')" 7 "[M] --json: seven rows"
  unset CLAUDE_CONFIG_DIR
}

case_lsp() {
  newp
  br op add --kind now --text "state"
  lsp_registry
  br matrix; local r; r=$(row "$OUT" "code intelligence")
  c_has "$r" "pyright-lsp" "[L] an enabled *-lsp plugin is listed"
  c_has "$r" "serena" "[L] serena is listed"
  c_has "$r" "lsp-json" "[L] a plugin with .lsp.json is listed"
  c_has "$r" "lsp-servers" "[L] a plugin with lspServers is listed"
  c_hasnt "$r" "gopls-lsp" "[L] a disabled *-lsp plugin is not listed"
  c_hasnt "$r" "zz-nolang" "[L] a plugin without a language server is not listed"
  OUT=$(CLAUDE_CODE_REMOTE=true CLAUDE_CODE_SESSION_ID="$SID" "$BROOT/bin/brain" matrix 2>&1)
  c_has "$(row "$OUT" "code intelligence")" "not started" "[L] CLAUDE_CODE_REMOTE=true: not started"
  unset CLAUDE_CONFIG_DIR
}

case_hot() {
  newp
  br op add --kind now --text "state"
  br matrix; local r; r=$(row "$OUT" "Hot Memory")
  c_has "$r" "repo index" "[H] the Know·hot row names the repo index"
  c_has "$r" "shared" "[H] as shared"
  c_has "$r" "B1.7" "[H] and planned in B1.7"
  c_has "$(row "$OUT" "Artifact Index")" "not built" "[H] the Artifact Index is not built (B2.1)"
  local sk="$BROOT/skills/matrix/SKILL.md"
  c_has "$(cat "$sk" 2>/dev/null)" "disable-model-invocation: true" "[H] skill matrix is user-only"
  c_has "$(cat "$sk" 2>/dev/null)" "brain matrix" "[H] it runs brain matrix"
  local wv; wv=$(want_version "$SRC_ROOT" "$BROOT")
  c_eq "$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("version", "none"))' "$BROOT/.claude-plugin/plugin.json")" "${wv:-none}" \
    "[H] brain's manifest on the $(tree_shape "$SRC_ROOT") tree carries the version ${wv:-none} (private: none; export: the CHANGELOG's released version)"
}

case_did() {
  newp
  br op add --kind now --text "anchored" --anchor KESTREL-41 --anchor a3f9c2e
  local tr="$TMP/did$NP.jsonl"; tr_write "$tr"
  hk session-start "$(hin session_id=sA cwd="$P" hook_event_name=SessionStart source=startup transcript_path="$tr")"
  hk session-start "$(hin session_id=sB cwd="$P" hook_event_name=SessionStart source=startup)"
  hk session-start "$(hin session_id=sB cwd="$P" hook_event_name=SessionStart source=startup)"
  hk pre-compact "$(hin session_id=sA cwd="$P" hook_event_name=PreCompact trigger=manual transcript_path="$tr")"
  hk post-compact "$(hin session_id=sA cwd="$P" hook_event_name=PostCompact trigger=manual compact_summary="kept KESTREL-41 only")"
  hk session-start "$(hin session_id=sA cwd="$P" hook_event_name=SessionStart source=compact transcript_path="$tr")"
  local inj; inj=$(grep '"source":"compact"' "$(sdir)/episodes.jsonl" | tail -n 1 | jget injected)
  OUT=$(CLAUDE_CODE_SESSION_ID=sA "$BROOT/bin/brain" matrix 2>&1)
  c_has "$OUT" "this session" "[D] the section names its scope"
  c_has "$OUT" "session-start 2" "[D] this session's session-start lines only (sB's two are not counted)"
  c_has "$OUT" "compactions 1 (last manual" "[D] compactions: count and last trigger"
  c_has "$OUT" "injected last $(python3 -c 'import sys; print("{:,}".format(int(sys.argv[1])))' "$inj")" "[D] characters injected, last"
  c_has "$OUT" "loss 0.5" "[D] the last loss score"
  OUT=$(env -u CLAUDE_CODE_SESSION_ID "$BROOT/bin/brain" matrix 2>&1)
  c_has "$OUT" "all sessions" "[D] without a session id: all sessions"
  c_has "$OUT" "session-start 4" "[D] and every session's lines"
}

# --- the probe against the fake claude -----------------------------------------------------------------------------------------
# A probe root in the scratch tree: the brain and sdlc of the kit copy (symlinked), the probe files copied; PROOT is what a case
# runs, plant_probe swaps in a copy with one break. The fake is run through a wrapper named claude.
probe_root() {  # probe_root <dir> — a probe tree at <dir>
  mkdir -p "$1/tests/fixtures" "$1/tests/live"
  ln -s "$KIT/plugins" "$1/plugins"
  cp -R "$SRC_ROOT/tests/fixtures/brain-probe" "$1/tests/fixtures/"
  cp "$SRC_ROOT/tests/live/brain-probe.sh" "$1/tests/live/"
}
mkdir -p "$TMP/fakebin"
printf '#!/bin/sh\nexec python3 "$PROOT/tests/fixtures/brain-probe/fake_claude.py" "$@"\n' > "$TMP/fakebin/claude"
chmod +x "$TMP/fakebin/claude"
probe_root "$TMP/proot"; export PROOT="$TMP/proot"

probe() {  # probe [VAR=value…] [-- probe args…] — one fake run of the probe; sets OUT, RC and W (its kept work directory)
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  NP=$((NP+1)); W="$TMP/pw$NP"
  OUT=$(env FAKE_HOME="$TMP/fakehome$NP" FAKE_BASE_TOKENS=90000 "${envs[@]}" \
        bash "$PROOT/tests/live/brain-probe.sh" --claude "$TMP/fakebin/claude" --runs 1 --seed 7 --filler-turns 2 --filler-kb 4 \
        --model fake-model --preflight-model fake-model --keep --work "$W" "$@" 2>&1); RC=$?
}
pline() { printf '%s\n' "$OUT" | grep -E "^$1" | head -n 1; }

case_probe_pass() {
  probe
  c_rc 0 "[Q] rc 0 (PASS)"
  c_has "$OUT" "method 1 (auto)" "[Q] method 1 compacted (the fake auto-compacts past the window)"
  c_has "$(pline 'run 1 H:')" "10/10" "[Q] H answers 10/10"
  c_has "$(pline 'run 1 C:')" "6/10" "[Q] C answers what the summary kept: 6/10"
  c_has "$(pline 'exit:')" "PASS" "[Q] the exit line says PASS"
  c_has "$OUT" "not an exit run" "[Q] a shrunk filler is labelled: not an exit run"
  local inj epi
  inj=$(pline 'run 1 H:' | sed -n 's/.*injected \([0-9,]*\).*/\1/p' | tr -d ,)
  epi=$(cat "$W"/run1/state/vibemaestro/brain/*/episodes.jsonl 2>/dev/null | grep '"source":"compact"' | head -n 1 | jget injected)
  c_eq "$inj" "$epi" "[Q] injected is the brain's own counter at SessionStart:compact"
  c_eq "$([ "${inj:-99999}" -le 8000 ] && echo within)" within "[Q] the block is ≤ 8,000 characters ($inj)"
  c_eq "$(cat "$W"/run1/state/vibemaestro/brain/*/hot.jsonl 2>/dev/null | grep -c '"op":"owner-add"')" 10 "[Q] the store holds the 10 seeded decisions"
  c_has "$(cat "$W"/run1/state/vibemaestro/brain/*/hot.jsonl 2>/dev/null)" '"mode":"probe-seed"' "[Q] marked as seeded by the probe"
  c_has "$OUT" "run 1 cost:" "[Q] the run's cost line"
  c_has "$(pline 'run 1 H:')" "cut 0" "[Q] the hard cut did not fire"
  # the plant (fixed before the first run): each decision and one floated draft naming a near miss, never an anchor; the
  # decision first for odd items, the draft first for even ones
  R=$(python3 - "$W" <<'PY'
import glob, json, re, sys
w = sys.argv[1]
log = [json.loads(l) for l in open(w + "/run1/log.jsonl")]
tr = next(l["transcript_path"] for l in log if l.get("event") == "SessionStart" and l.get("source") == "startup")
anchors = set()
for l in open(glob.glob(w + "/run1/state/vibemaestro/brain/*/hot.jsonl")[0]):
    o = json.loads(l)
    if o.get("op") == "owner-add":
        anchors |= {a.lower() for a in o["item"]["anchors"]}
tok = re.compile(r"\b[A-Za-z]+-\d+\b|\b[0-9A-Fa-f]{7}\b")
kinds, bad = [], 0
for l in open(tr):
    r = json.loads(l)
    c = (r.get("message") or {}).get("content") if r.get("type") == "user" else None
    if not isinstance(c, str):
        continue
    if "not decided" in c:
        kinds.append("F")
        bad += bool({t.lower() for t in tok.findall(c)} & anchors)
    elif "Owner decision" in c:
        kinds.append("D")
print(kinds.count("D"), kinds.count("F"), bad, "".join(kinds[:4]), len(anchors))
PY
)
  c_eq "$R" "10 10 0 DFFD 10" "[Q] the plant: 10 decisions, 10 floated drafts with no anchor in them, in the fixed order"
  probe FAKE_SUMMARY_LISTS_PROMPTS=1
  c_rc 0 "[Q] a summary that lists the user's prompts (2.1.290's compaction prompt) is not a fork asked twice"
  probe FAKE_SESSIONSTART_FIRST=1
  c_rc 0 "[Q] SessionStart:compact before PostCompact (2.1.290's usual order, read in the binary): still PASS"
  c_has "$(pline 'run 1 H:')" "10/10" "[Q] and H is scored"
}

case_probe_fallback() {
  probe FAKE_NO_AUTO=1
  c_rc 0 "[F] rc 0 with method 2"
  c_has "$OUT" "method 2 (manual)" "[F] method 1 did not compact: method 2 is used and named"
  c_has "$(pline 'run 1 H:')" "10/10" "[F] H 10/10 from the block SessionStart:compact left in its transcript"
  c_has "$(pline 'run 1 C:')" "6/10" "[F] C 6/10"
}

case_probe_nocompact() {
  probe FAKE_NO_AUTO=1 FAKE_NO_SLASH=1
  c_rc 2 "[N] no method compacts: rc 2"
  c_has "$OUT" "no method compacted" "[N] it says so"
  c_eq "$(pline 'run 1 H:')" "" "[N] nothing is scored"
}

case_probe_grader() {
  probe FAKE_HEDGE=1
  c_rc 1 "[A] H misses: rc 1 (FAIL)"
  c_has "$(pline 'run 1 H:')" "8/10 (wrong P1 P4)" "[A] a hedge with a near miss (P1) and another item's anchor (P4) are wrong; markdown (P2) and case (P3) are not"
  c_has "$(pline 'exit:')" "FAIL" "[A] the exit line says FAIL"
}

case_probe_memory() {
  probe FAKE_WRITE_MEMORY=1
  c_rc 2 "[W] auto memory written: rc 2"
  c_has "$OUT" "auto memory" "[W] the void names auto memory"
}

case_probe_preflight() {
  probe FAKE_NOT_LOGGED_IN=1
  c_rc 2 "[P] not logged in: rc 2"; c_has "$OUT" "Not logged in" "[P] the session's own message is shown"
  probe FAKE_TWO_BRAINS=1
  c_rc 2 "[P] two brains loaded: rc 2"; c_has "$OUT" "2 brains loaded" "[P] it says how many"
  probe FAKE_HELP_DROP=--setting-sources
  c_rc 2 "[P] a missing flag: rc 2"; c_has "$OUT" "--setting-sources" "[P] it names the flag"
  probe FAKE_IGNORE_BLOCK=1
  c_rc 2 "[P] the block SessionStart:compact left is not used after --resume: rc 2 before any run"
  c_has "$OUT" "not used after --resume" "[P] it says so"
}

case_probe_isolated() {
  probe FAKE_SUMMARY_COPIES_BLOCK=1 FAKE_IGNORE_BLOCK_AFTER_PREFLIGHT=1
  c_rc 1 "[I] a model that ignores the block, with a summary that copies any earlier one: FAIL (rc 1)"
  c_has "$(pline 'run 1 H:')" "6/10" "[I] H scores what the summary kept: no block reached it before the compaction"
}

case_probe_void() {
  probe FAKE_NO_COMPACT_INJECT_AFTER_PREFLIGHT=1
  c_rc 2 "[J] no SessionStart:compact block in H: void (rc 2)"
  c_has "$OUT" "lacks the brain's block from SessionStart:compact" "[J] it says why"
  probe FAKE_COMPACT_IN_FILLER=1
  c_rc 2 "[J] the shared history compacted before the fork: void (rc 2)"
  c_has "$OUT" "shared history was compacted" "[J] it says why"
  probe FAKE_FORK_SOURCE=compact
  c_rc 2 "[J] H got a block before its compaction: void (rc 2)"
  c_has "$OUT" "before the compaction" "[J] it says why"
}

case_probe_crash() {
  probe -- --work "$TMP/samework"
  probe -- --work "$TMP/samework"
  c_rc 0 "[R] a second run in the same --work: rc 0"
  probe FAKE_ODD_RESULT=1
  c_rc 2 "[R] an internal error: rc 2, not 1"
  c_has "$OUT" "internal error" "[R] named"
}

case_knob() {
  newp
  br op add --kind now --text "knob"
  start() { hk session-start "$(hin session_id="$SID" cwd="$P" hook_event_name=SessionStart source="$1")"; }
  BRAIN_TEST=1 BRAIN_TEST_SOURCES=compact start fork
  c_eq "$OUT" "" "[K] BRAIN_TEST_SOURCES=compact: nothing at SessionStart:fork"
  BRAIN_TEST=1 BRAIN_TEST_SOURCES=compact start compact
  c_has "$OUT" "re-injected at SessionStart:compact" "[K] the block at SessionStart:compact"
  BRAIN_TEST_SOURCES=compact start fork
  c_has "$OUT" "re-injected at SessionStart:fork" "[K] without BRAIN_TEST=1 the knob is ignored"
}

case_probe_control10() {
  probe FAKE_SUMMARY_KEEP=10
  c_rc 3 "[T] the control at 10/10: rc 3"
  c_has "$(pline 'exit:')" "not shown necessary at this size" "[T] reported as is"
}

dep_probe() {  # dep_probe <name> [<old> <new>]… — one fake run of a copy of the probe tree under test with exact-text breaks in probe.py
  local name=$1 d="$TMP/dep-$1" saved=$PROOT f
  shift
  mkdir -p "$d/tests/fixtures" "$d/tests/live"
  ln -s "$KIT/plugins" "$d/plugins"
  cp -R "$PROOT/tests/fixtures/brain-probe" "$d/tests/fixtures/"
  cp "$PROOT/tests/live/brain-probe.sh" "$d/tests/live/"
  f="$d/tests/fixtures/brain-probe/probe.py"
  while [ $# -ge 2 ]; do
    python3 -c 'import sys
p, old, new = sys.argv[1:4]
s = open(p, encoding="utf-8").read()
if s.count(old) != 1:
    sys.exit(1)
open(p, "w", encoding="utf-8").write(s.replace(old, new))' "$f" "$1" "$2" || { c_eq "the break does not apply" "ok" "[D2] dep_probe $name: '${1:0:50}' not found exactly once"; return 1; }
    shift 2
  done
  export PROOT="$d"; probe; export PROOT="$saved"
}
sdlc_in_transcripts() {  # sdlc_in_transcripts — how many transcripts of the last probe run (FAKE_HOME of NP) hold the sdlc's SessionStart text
  find "$TMP/fakehome$NP" -name '*.jsonl' -exec grep -lF "The general way of working (read from the plugin" {} + 2>/dev/null | wc -l | tr -d ' '
}

case_probe_dep() {
  local drop=(    'PLUGIN_DIRS = [BRAIN, SDLC]' 'PLUGIN_DIRS = [BRAIN]')
  local nocheck=( '    check_dependencies()' '    pass')
  dep_probe nosdlc "${drop[@]}"
  c_rc 2 "[D2] no sdlc --plugin-dir: rc 2"
  c_has "$OUT" "vibemaestro-brain depends on vibemaestro-sdlc" "[D2] the reason names the plugin and its dependency"
  c_hasnt "$OUT" "brains loaded" "[D2] it stops on the manifest, not on the old '0 brains loaded'"
  c_eq "$([ -e "$W/preflight" ] && echo started || echo nothing)" nothing "[D2] before the first session: nothing was spent"
  dep_probe nosdlc-nocheck "${drop[@]}" "${nocheck[@]}"
  c_rc 2 "[D2] no sdlc and no manifest check: the fake refuses the brain, rc 2"
  c_has "$OUT" "0 brains loaded" "[D2] the old stop: the brain's hooks never ran"
  local R
  R=$(python3 -I -B - "$PROOT/tests/fixtures/brain-probe" "$TMP/depver" <<'PY'
import json, os, sys
sys.path.insert(0, sys.argv[1])
import probe
root = sys.argv[2]
def plug(name, version, deps=None):
    d = os.path.join(root, name + "-" + version)
    os.makedirs(os.path.join(d, ".claude-plugin"), exist_ok=True)
    m = {"name": name, "version": version}
    if deps:
        m["dependencies"] = deps
    json.dump(m, open(os.path.join(d, ".claude-plugin", "plugin.json"), "w"))
    return d
def stop(dirs):
    try:
        probe.check_dependencies(dirs)
    except probe.Stop as e:
        return "stop"
    return "ok"
def brain(rng):
    return plug("brain", "0.2.0", [{"name": "sdlc", "version": rng}]) if rng else plug("brain", "0.2.0", ["sdlc"])
out = []
out.append(stop(probe.PLUGIN_DIRS))                                  # this checkout's own two manifests: satisfied
out.append(stop([brain(">=2.8.0"), plug("sdlc", "2.8.0")]))          # the bound itself
out.append(stop([brain(">=2.8.0"), plug("sdlc", "2.7.9")]))          # below it
out.append(stop([brain(">=2.8.0 <3.0.0"), plug("sdlc", "3.0.0")]))   # above the upper bound
out.append(stop([brain(">=2.8.0 <3.0.0"), plug("sdlc", "2.28.0")]))  # inside both
out.append(stop([brain("^2.8.0"), plug("sdlc", "2.28.0")]))          # a range form it cannot read stops
out.append(stop([brain(None), plug("sdlc", "1.0.0")]))               # a dependency with no range: given is enough
out.append(stop([brain(">=2.8.0")]))                                 # not given at all
print(" ".join(out))
PY
)
  c_eq "$R" "ok ok stop stop ok stop ok stop" "[D2] the dependency check: given and in range ok; absent, below, above, unreadable range stop"
}

case_probe_silent() {
  probe
  c_rc 0 "[S] the silent sdlc: rc 0"
  c_eq "$(sdlc_in_transcripts)" 0 "[S] no transcript holds the sdlc's SessionStart text"
  dep_probe loud '            json.dump(SDLC_OFF, f)' '            json.dump({"hooks": "auto"}, f)'
  c_rc 2 "[S] an sdlc that speaks: the preflight stops, rc 2"
  c_has "$OUT" "SessionStart text is in the preflight transcript" "[S] it says why"
  c_eq "$(sdlc_in_transcripts)" 1 "[S] control: the preflight transcript does hold the text (the check looks at a real positive)"
  dep_probe loud-unchecked '            json.dump(SDLC_OFF, f)' '            json.dump({"hooks": "auto"}, f)' '    if loud:' '    if False:'
  c_has "$(pline 'preflight:')" "one brain loaded" "[S] without the check the run goes on, with the sdlc's text in every session"
}

case_probe_plan() {
  local s="$PROOT/tests/live/brain-probe.sh"
  bash -n "$s"; c_eq "$?" 0 "[Z] the live script parses"
  OUT=$(PATH="/usr/bin:/bin" bash "$s" --plan 2>&1); RC=$?
  c_rc 0 "[Z] --plan rc 0 with a minimal PATH (it starts nothing)"
  c_has "$OUT" "bash tests/live/brain-probe.sh --runs 3" "[Z] it names the exit command"
  c_has "$OUT" "2.5M tokens" "[Z] the cost of one run"
  c_has "$OUT" "--setting-sources project,local" "[Z] the hermetic sessions"
  c_has "$OUT" "--plugin-dir <this checkout's sdlc>" "[Z] the sdlc is loaded next to the brain, the brain depends on it"
  c_has "$OUT" ".vibemaestro/sdlc.json" "[Z] and runs silent in the scratch project"
}

plant_probe() {  # plant_probe <name> <case function> <file under the probe tree> <old text> <new text>
  local name=$1 fn=$2 file=$3 old=$4 new=$5 d="$TMP/pbrk-$1" saved=$PROOT
  probe_root "$d"
  if ! python3 -c 'import sys
p, old, new = sys.argv[1:4]
s = open(p, encoding="utf-8").read()
if s.count(old) != 1:
    sys.exit(1)
open(p, "w", encoding="utf-8").write(s.replace(old, new))' "$d/$file" "$old" "$new"
  then bad "[X] $name: the break does not apply (the text is not found exactly once in $file)"; return; fi
  local crc rf="$d.case"; rm -f "$rf"
  Q=1; CASE_FAIL=0; export PROOT="$d"
  capped _plant_case "$fn" "$rf"; crc=$?
  Q=0; export PROOT="$saved"
  if cap_red "$crc" "[X] $name ($fn)"; then NP=$((NP+1)); return; fi
  read -r CASE_FAIL NP < "$rf" 2>/dev/null || { CASE_FAIL=0; NP=$((NP+1)); }
  [ "$CASE_FAIL" = 1 ] && ok "[X] $name turns $fn red" || bad "[X] $name: $fn stays green with the break"
}

echo "== cases =="
for c in case_cost case_merge case_sums case_rows case_lsp case_hot case_did case_knob case_probe_pass case_probe_fallback \
         case_probe_nocompact case_probe_grader case_probe_memory case_probe_preflight case_probe_control10 case_probe_plan \
         case_probe_isolated case_probe_void case_probe_crash case_probe_dep case_probe_silent; do
  run_case $c
done
cd "$TMP" || exit 1

echo "== planted breaks =="
CO=scripts/brain_cost.py; MX=scripts/brain_matrix.py; HK=scripts/brain_hook.py
plant no-dedupe-by-id case_cost $CO '        prev = self.recent.get(key)' '        prev = None'
plant sidechain-counted case_cost $CO '        if rec.get("isSidechain") is True:' '        if False:'
plant five-minute-at-2x case_cost $CO 'W_5M = 1.25' 'W_5M = 2.0'
plant gap-not-seen case_cost $CO 'GAP = 3600' 'GAP = 9999'
plant merge-no-span case_merge $CO '        if not (lo <= t <= hi):' '        if False:'
plant merge-counted-twice case_merge $CO '        prs.add((o.get("repo"), o.get("pr")))' '        prs.add((o.get("repo"), o.get("pr"), o.get("time")))'
plant offset-not-saved case_sums $CO '    state["offset"] = offset' '    state["offset"] = 0'
plant straddle-counted-twice case_sums $CO '    state["recent"] = sums.recent_list()' '    state["recent"] = []'
plant end-no-cost-line case_sums $HK '    cost_line(s, d, inp)' '    pass'
plant row-cap-raised case_rows $MX 'ROW_MAX = 300' 'ROW_MAX = 600'
plant disabled-lsp-listed case_lsp $HK '        if enabled.get(key) is not True:' '        if False:'
plant lsp-json-ignored case_lsp $MX '        if name.endswith("-lsp") or name == "serena" or os.path.isfile(os.path.join(path, ".lsp.json")):' '        if name.endswith("-lsp") or name == "serena":'
plant repo-index-dropped case_hot $MX '"; repo index (shared, injected by sdlc; planned B1.7)"' '""'
plant other-sessions-counted case_did $MX '    mine = [e for e in eps if sid is None or e.get("session") == sid]' '    mine = eps'
PR=tests/fixtures/brain-probe/probe.py
plant_probe control-brain-on case_probe_pass $PR '    arm_env = {"BRAIN_OFF": "1"} if arm == "C" else dict(H_ENV)' '    arm_env = dict(H_ENV)'
plant_probe plant-brain-on case_probe_pass $PR 'PLANT_ENV = {"BRAIN_OFF": "1"}' 'PLANT_ENV = {}'
plant_probe block-limit-ignored case_probe_pass $PR 'BLOCK_LIMIT = 8000' 'BLOCK_LIMIT = 100'
plant_probe h-not-isolated case_probe_pass $PR 'H_ENV = {"BRAIN_TEST": "1", "BRAIN_TEST_SOURCES": "compact"}' 'H_ENV = {}'
plant_probe h-not-isolated-unchecked case_probe_isolated $PR 'H_ENV = {"BRAIN_TEST": "1", "BRAIN_TEST_SOURCES": "compact"}' 'H_ENV = {}'
plant_probe compact-block-unchecked case_probe_void $PR '    if not any(brain_blocks(p, FRAME_COMPACT) for p in h["transcripts"]):' '    if False:'
plant_probe shared-compaction-unchecked case_probe_void $PR '    if any(l.get("event") == "PostCompact" and l.get("session_id") in run.shared_ids for l in run.logs()):' '    if False:'
plant_probe replay-unchecked case_probe_preflight $PR '        if not ok:' '        if False:'
plant_probe work-not-cleared case_probe_crash $PR '        shutil.rmtree(self.dir, ignore_errors=True)' '        pass'
plant_probe crash-not-caught case_probe_crash $PR '    except Exception as e:  # noqa: BLE001 — a crash is not a FAIL' '    except Stop as e:'
plant end-cost-repeated case_sums $HK '    if r is None or not fresh:' '    if r is None:'
plant_probe draft-names-anchor case_probe_pass $PR '        it["draft_prompt"] = draft.replace("{T}", it["topic"]).replace("{N}", near[0])' '        it["draft_prompt"] = draft.replace("{T}", it["topic"]).replace("{N}", a)'
plant_probe drafts-not-sent case_probe_pass $PR '        turns = [it["owner_prompt"], it["draft_prompt"]] if i % 2 else [it["draft_prompt"], it["owner_prompt"]]' '        turns = [it["owner_prompt"]]'
plant_probe order-bound case_probe_pass $PR '        if e.get("kind") in ("pre-compact", "compact"):' '        if e.get("kind") == "compact":'
plant_probe early-block-unchecked case_probe_void $PR '        elif e.get("kind") == "session-start" and not (seen and e.get("source") == "compact"):' '        elif False:'
plant_probe summary-counted-as-ask case_probe_pass $PR '        if r.get("isCompactSummary"):
            continue' '        if False:
            continue'
plant knob-without-brain-test case_knob $HK '    if os.environ.get("BRAIN_TEST") != "1":
        return True' '    if False:
        return True'
plant_probe failed-fork-reused case_probe_fallback $PR '            out = arm_run(ctx, run, arm, 2, shared, project)' '            out = arm_run(ctx, run, arm, 2, failed or shared, project)'
plant_probe no-compaction-check case_probe_nocompact $PR '    if not compacted:
        return None' '    if False:
        return None'
plant_probe substring-grader case_probe_grader $PR '        good = toks == {it["anchor"].lower()}' '        good = it["anchor"].lower() in line.lower()'
plant_probe memory-unchecked case_probe_memory $PR '    for m in memory_files(ctx, run):' '    for m in []:'
plant_probe sdlc-plugin-dir-dropped case_probe_pass $PR 'PLUGIN_DIRS = [BRAIN, SDLC]' 'PLUGIN_DIRS = [BRAIN]'
plant_probe dependency-missing-unchecked case_probe_dep $PR '            if name not in given:' '            if False:'
plant_probe dependency-version-unchecked case_probe_dep $PR '            if rng and name in given and not version_ok(str(given[name]), rng):' '            if False:'
plant_probe fake-dependencies-unmodelled case_probe_dep tests/fixtures/brain-probe/fake_claude.py '        for pd in loaded_plugin_dirs(self.a["plugin_dirs"]):' '        for pd in self.a["plugin_dirs"]:'
plant_probe sdlc-not-silenced case_probe_silent $PR '            json.dump(SDLC_OFF, f)' '            json.dump({"hooks": "auto"}, f)'
plant_probe sdlc-speaks-unchecked case_probe_silent $PR '    if loud:' '    if False:'
plant_probe one-brain-unchecked case_probe_preflight $PR '    if len(starts) != 1:' '    if not starts:'
plant_probe control-ignored case_probe_control10 $PR '    elif any(r["C"]["score"] == 10 for r in results):' '    elif False:'
plant_probe plan-runs case_probe_plan $PR '        sys.stdout.write(plan_text())
        return 0' '        sys.stdout.write(plan_text())'

summary
