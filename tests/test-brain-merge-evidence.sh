#!/bin/bash
# =============================================================================
# vibemaestro-brain: evidence from merged PRs — `brain op merge-evidence` and the prompt hook's background run of it
# =============================================================================
# Run: bash tests/test-brain-merge-evidence.sh
#
# Offline: a stub `gh` first on PATH answers `gh api repos/<o>/<r>/pulls/<n> … --jq F` by running the real jq with F over the file
# $STUB/pulls/<o>_<r>_<n>.json (a PR's JSON with its body), and `…/issues/<n>` from $STUB/answers; it logs every argv and can fail
# or hang. The merge guard's log is written by hand, one JSON line per run, as merge_guard.py writes it.
#   [a] a first run starts at the log's end; a PR merged after it gets one held per live code of its `Rules applied:` line (a
#       decision, a trap, a fact, a SOUL code an owner step promoted), pointing to the PR, counted under the PR as its session;
#       `Traps met:` gives a hit, and a trap on both lines only the hit
#   [b] read again (the offset reset, two runs at once): no second held; the ledger counts each code once per PR
#   [r] a PR of a repository this brain does not name (not its origin, in no item's anchors): not read, named
#   [c] only `merged` lines of mode merge are read: a dry run, merge-pending, merged-unconfirmed, merge-failed, a broken line and a
#       line cut at the end are not looked up; a cut line is read once it is whole
#   [d] the body is worker text: a line in a fence, a quote, an indented line, a label given twice, a line over 300 characters or 12
#       codes, a look-alike bracket, S014, a SOUL code no owner step promoted, a Next item, an unknown or superseded id, a decision
#       under `Traps met:`, a label inside a longer fence or after an info-string line: nothing written for them, each named in
#       the run's output; the plain codes beside them are written
#   [e] a session item whose `closes` names the PR: the held counts under that session
#   [f] not the writer: refused (3), no lookup, the offset unchanged; no state: refused
#   [g] gh failing or hanging: the PR waits and is read by the next run, or is dropped and named after 5 failed reads; an answer
#       cut at 4096 bytes right after `Rules applied: D1` (of D12) is never read as a whole one; the run ends at its deadline;
#       a damaged waiting entry is left out alone, the offset kept
#   [t] a take-over while the run waits on gh: the new writer's refusal puts the PR back to wait, the new writer reads it; a
#       write refused at the fifth try: the PR is dropped and named; a state file with no offset: said so, the waiting PRs kept
#   [s] the SOUL codes that count: promoted by an owner step (its pointer, its own or an extension's code), less a demotion
#   [i] an export and import keep the PR sessions of merge-evidence apart
#   [h] the prompt hook: rc 0 and silent at once, the run in the background logs one `merge-evidence` episode line; not again
#       within 10 minutes; another session, a worker, no gh, no merge log: nothing started
# =============================================================================
set -uo pipefail
if [ -z "${BRAIN_SUITE_REEXEC:-}" ]; then
  export PYTHONUSERBASE="${PYTHONUSERBASE:-$(python3 -m site --user-base 2>/dev/null)}"
  # Every PR number is spelled ¤5 so that the public-tree scan does not read test data as a reference; the copy this run executes
  # has a real hash sign (same name, so the suite's result file keeps its name).
  SRC_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
  TEXT_DIR=$(mktemp -d) && sed 's/¤/#/g' "$0" > "$TEXT_DIR/$(basename -- "$0")" || exit 2
  exec env -u CLAUDE_CONFIG_DIR -u CLAUDE_CODE_SESSION_ID BRAIN_SUITE_REEXEC=1 BRAIN_SUITE_SRC_DIR="$SRC_DIR" \
       BRAIN_SUITE_TEXT_DIR="$TEXT_DIR" HOME=/nonexistent bash "$TEXT_DIR/$(basename -- "$0")" "$@"
fi
HERE=$(CDPATH= cd -- "$BRAIN_SUITE_SRC_DIR" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap '[ -n "$TMP" ] && rm -rf "$TMP"; [ -n "${BRAIN_SUITE_TEXT_DIR:-}" ] && rm -rf "$BRAIN_SUITE_TEXT_DIR"' EXIT
clean_env "$TMP"
# shellcheck source=fixtures/brain.sh
. "$HERE/fixtures/brain.sh"
brain_kit "$SRC_ROOT"
if [ "${OS:-}" = Windows_NT ]; then   # Windows' own Python runs gh.exe only: the stub gh script every case answers through is never run
  echo "  SKIP [all]: every case answers gh through a stub script, which Windows' own Python cannot run (the tree kill is store [WK], the harvest store [WH])"
  summary; exit
fi
command -v jq >/dev/null || { bad "jq is needed by the stub gh (it runs the body filter as gh would)"; summary; exit 1; }

# --- the stub gh ------------------------------------------------------------------------------------------------------------
export STUB="$TMP/stub"
mkdir -p "$TMP/bin" "$TMP/nogh"
cat > "$TMP/bin/gh" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$STUB/calls"
[ "$1" = api ] || exit 2
eval "jqf=\${$#}"
k=$(printf '%s' "$2" | sed -e 's#^repos/##' -e 's#/pulls/#_#' -e 's#/issues/#_#' -e 's#/#_#')
case "$2" in
  repos/*/pulls/*) f="$STUB/pulls/$k.json" ;;
  repos/*/issues/*) f="$STUB/answers/$k"; [ -f "$f" ] && { cat "$f"; exit 0; } ;;
  *) exit 2 ;;
esac
[ -f "$f" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
[ -f "$STUB/delay" ] && { : > "$STUB/started"; sleep "$(cat "$STUB/delay")"; }
case $(head -c 4 "$f") in
  SLOW) sleep 30 & echo $! >> "$STUB/pids"; wait; exit 0 ;;
  FAIL) echo "gh: Server Error (HTTP 500)" >&2; exit 1 ;;
esac
jq -r "$jqf" < "$f"
SH
chmod +x "$TMP/bin/gh"
for b in python3 git sh sed cat dirname; do ln -s "$(command -v "$b")" "$TMP/nogh/$b"; done   # a PATH with no gh in it
export PATH="$TMP/bin:$PATH"

stub_reset() { [ -n "$STUB" ] && rm -rf "$STUB"; mkdir -p "$STUB/pulls" "$STUB/answers"; : > "$STUB/calls"; : > "$STUB/pids"; }
np() { newp; stub_reset; git_ -C "$P" remote add origin https://github.com/acme/app.git; }
kf() { local k=${1/\#/_}; printf '%s' "${k//\//_}"; }                      # acme/app¤5 → acme_app_5
body() { python3 -c 'import json, sys; print(json.dumps({"body": sys.argv[1]}))' "$2" > "$STUB/pulls/$(kf "$1").json"; }
mlog() {  # mlog <owner/name> <pr> [result] [mode] — one merge guard line
  mkdir -p "$XDG_STATE_HOME/vibemaestro"
  printf '{"mode": "%s", "pr": %s, "repo": "%s", "result": "%s", "time": "2026-11-14T00:00:00Z"}\n' "${4:-merge}" "$2" "$1" \
    "${3:-merged}" >> "$XDG_STATE_HOME/vibemaestro/merge-log.jsonl"
}
ncalls() { wc -l < "$STUB/calls" | tr -d ' '; }
me() { br op merge-evidence; }
ev() {  # ev <key> — the evidence ops of one rule: result/via/pointer/session, one per line
  python3 - "$(sdir)/hot.jsonl" "$1" <<'PY'
import json, sys
for l in open(sys.argv[1], encoding="utf-8"):
    o = json.loads(l)
    if o.get("op") == "evidence" and (o.get("id") or "[%s]" % o.get("soul")) == sys.argv[2]:
        print("%s/%s/%s/%s" % (o["result"], o.get("via") or "-", o.get("pointer"), o.get("session") or "-"))
PY
}
nev() { grep -c '"op":"evidence"' "$(sdir)/hot.jsonl" || true; }
eplines() { grep -F "\"kind\":\"$1\"" "$(sdir)/episodes.jsonl" 2>/dev/null || true; }
cursor() { python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["offset"])' "$(sdir)/merge-evidence.json"; }
rules() {  # D1 decision, T1 trap, F1 fact, X1 Next item (not a rule), D2 promoted to the SOUL code S07, as the writer sA
  owner_ok add --kind decision --text "one review round" --owner-quote q --where w
  br op add --kind trap --text "a trap"; br op add --kind fact --text "a fact"; br op add --kind next --text "a next item"
  owner_ok add --kind decision --text "a rule that matured" --owner-quote q --where w
  owner_ok promote D2 "CLAUDE.md [S07]"
}
capped_me() { OUT=$(CLAUDE_CODE_SESSION_ID="$SID" capped "$BROOT/bin/brain" op merge-evidence 2>&1); RC=$?; }

case_basic() {
  np; rules; mlog acme/app 3
  me; c_rc 0 "[a] the first run: rc 0"; c_has "$OUT" "started at the end of the merge log" "[a] it starts at the log's end"
  c_eq "$(ncalls)" 0 "[a] and looks nothing up: a PR merged before it is not read"
  body 'acme/app¤5' $'Summary.\r\nRules applied: D1, T1, F1, [S07]\r\nTraps met: T1\r\n'; mlog acme/app 5
  me; c_rc 0 "[a] a run after a merge: rc 0"
  c_eq "$(ev D1)" "held/-/acme/app¤5/pr:acme/app¤5" "[a] a decision: one held, pointing to the PR, counted under the PR"
  c_eq "$(ev F1)" "held/-/acme/app¤5/pr:acme/app¤5" "[a] a fact: one held"
  c_eq "$(ev '[S07]')" "held/-/acme/app¤5/pr:acme/app¤5" "[a] a SOUL code: one held"
  c_eq "$(ev T1)" "held/hit/acme/app¤5/pr:acme/app¤5" "[a] a trap applied and met: the hit alone, never a second held"
  c_eq "$(grep -c 'repos/acme/app/pulls/5 ' "$STUB/calls")" 1 "[a] one body lookup for the PR"
  br ledger D1; c_has "$OUT" "held 1 from 1 session" "[a] brain ledger counts it"
  me; c_eq "$(nev)" 4 "[a] a run with nothing new writes nothing"; c_has "$OUT" "no PR merged since the last run" "[a] and says so"
  # three PRs are three sessions
  body 'acme/app¤6' 'Rules applied: D1'; body 'acme/app¤7' 'Rules applied: D1'; mlog acme/app 6; mlog acme/app 7
  me; br ledger D1; c_has "$OUT" "held 3 from 3 sessions" "[a] three PRs count as three sessions"
}

case_twice() {
  np; rules; me
  body 'acme/app¤5' 'Rules applied: D1, T1'; mlog acme/app 5; me
  bpy 's._write_file(s.state_dir() + "/merge-evidence.json", "{\"offset\": 0, \"wait\": [[\"acme/app¤5\", 0]]}\n")'
  me; c_rc 0 "[b] the same PR read again: rc 0"
  c_eq "$(ev D1 | wc -l | tr -d ' ')" 1 "[b] no second held for D1"
  c_has "$OUT" "D1 has a held from acme/app¤5 already" "[b] the run says why it skipped"
  body 'acme/app¤8' 'Rules applied: F1'; mlog acme/app 8
  local a b
  CLAUDE_CODE_SESSION_ID=sA "$BROOT/bin/brain" op merge-evidence >/dev/null 2>&1 & a=$!
  CLAUDE_CODE_SESSION_ID=sA "$BROOT/bin/brain" op merge-evidence >/dev/null 2>&1 & b=$!
  wait "$a"; wait "$b"
  c_eq "$(ev F1)" "held/-/acme/app¤8/pr:acme/app¤8" "[b] two runs at once: one held"
}

case_lines() {
  np; rules; me
  body 'acme/app¤9' 'Rules applied: F1'
  for r in "pass dry-run" "merge-pending merge" "merged-unconfirmed merge" "merge-failed merge" "refused merge"; do
    set -- $r; mlog acme/app 9 "$1" "$2"
  done
  printf 'not json\n' >> "$XDG_STATE_HOME/vibemaestro/merge-log.jsonl"
  me; c_eq "$(ncalls)|$(nev)" "0|0" "[c] a dry run, pending, unconfirmed, failed, refused and a broken line: nothing looked up"
  printf '{"mode": "merge", "pr": 9, "repo": "acme/app", "result": "merged"' >> "$XDG_STATE_HOME/vibemaestro/merge-log.jsonl"
  me; c_eq "$(ncalls)" 0 "[c] a line cut at the end is not read yet"
  printf '}\n' >> "$XDG_STATE_HOME/vibemaestro/merge-log.jsonl"
  me; c_eq "$(ev F1)" "held/-/acme/app¤9/pr:acme/app¤9" "[c] once whole, it is read"
  mlog '../x' 4; mlog 'acme/app' '"4"'; me; c_eq "$(ncalls)" 1 "[c] a repository that climbs out or a PR number that is a string: not looked up"
}

case_hostile() {
  np; rules; br op add --kind trap --text "old trap"; br op supersede T2 --text "new trap" --reason narrower; me
  local long; long="Rules applied: D1$(printf ', T1%.0s' $(seq 1 12))"
  body 'acme/app¤5' "$(printf '%s\n' 'Rules applied: D1, X1, D99, T2, S014, S09, ［S07］, F1, none' '````' '```' 'Traps met: T1' '```' '````' \
    '```python' 'Traps met: T1' '```python' 'Traps met: T1' '```' \
    '> Rules applied: T1' '    Traps met: T1' 'Traps met: D1')"
  mlog acme/app 5; capped_me
  c_rc 0 "[d] a hostile body: rc 0"
  c_eq "$(ev D1)|$(ev F1)" "held/-/acme/app¤5/pr:acme/app¤5|held/-/acme/app¤5/pr:acme/app¤5" "[d] the plain codes are written"
  c_eq "$(nev)" 2 "[d] and nothing else: not X1, D99, T2 (superseded), S014, S09, a full-width bracket, none, nor T1 in a fence (a longer one, one an info line does not close), a quote or an indent"
  c_has "$OUT" "skipped X1 acme/app¤5: X1 is a Next item, not a rule" "[d] a Next item is named"
  c_has "$OUT" "skipped D99 acme/app¤5: D99 is not an item of this brain" "[d] an unknown id is named"
  c_has "$OUT" "skipped T2 acme/app¤5: T2 is superseded by T3" "[d] a superseded trap is named"
  c_has "$OUT" "skipped S014 acme/app¤5" "[d] a malformed SOUL code is named"
  c_has "$OUT" "skipped S09 acme/app¤5: [S09] is not a SOUL code an owner step promoted" "[d] a SOUL code nobody promoted is named"
  c_has "$OUT" "skipped D1 acme/app¤5: hit counts traps only" "[d] a decision under Traps met is named, not written"
  body 'acme/app¤6' "$(printf '%s\n' 'Rules applied: D1' 'Rules applied: F1' "$long" "Traps met: T1, $(printf 'x%.0s' $(seq 1 300))")"
  mlog acme/app 6; capped_me
  c_eq "$(nev)" 2 "[d] a label given twice, a line over 12 codes or 300 characters: nothing written"
  c_has "$OUT" "acme/app¤6: Rules applied: given 3 times: not read" "[d] a repeated label is named"
  c_has "$OUT" "acme/app¤6: Traps met: over 300 characters or 12 codes: not read" "[d] an oversized line is named"
}

case_session() {
  np; rules; printf 'open\t\t\t\tpr\n' > "$STUB/answers/$(kf 'acme/app¤5')"
  br op add --kind session --text "a worker session" --closes 'acme/app¤5'; c_rc 0 "[e] instrument: a session item closing the PR"
  me; body 'acme/app¤5' 'Rules applied: D1'; mlog acme/app 5; me
  c_eq "$(ev D1)" "held/-/acme/app¤5/S1" "[e] the held counts under the session that made the PR"
}

case_writer() {
  np; br op merge-evidence; c_rc 1 "[f] no state yet: refused"
  rules; me; body 'acme/app¤5' 'Rules applied: D1'; mlog acme/app 5
  local before; before=$(cursor)
  SID=sB br op merge-evidence; c_rc 3 "[f] another session: refused (3)"
  c_eq "$(ncalls)|$(cursor)|$(nev)" "0|$before|0" "[f] no lookup, the offset unchanged, nothing written"
}

case_gh() {
  np; rules; me; printf 'FAIL\n' > "$STUB/pulls/$(kf 'acme/app¤5').json"; mlog acme/app 5
  me; c_has "$OUT" "waiting acme/app¤5: its body was not read (gh rc 1)" "[g] gh failing: the PR waits"
  c_eq "$(nev)" 0 "[g] nothing written"
  body 'acme/app¤5' 'Rules applied: D1'; me
  c_eq "$(ev D1)" "held/-/acme/app¤5/pr:acme/app¤5" "[g] the next run reads it"
  printf 'SLOW\n' > "$STUB/pulls/$(kf 'acme/app¤6').json"; mlog acme/app 6
  local t0 t1; t0=$(date +%s); capped_me; t1=$(date +%s)
  c_has "$OUT" "waiting acme/app¤6: its body was not read (no answer)" "[g] gh hanging: the PR waits"
  c_eq "$([ $((t1 - t0)) -le 25 ] && echo bounded)" bounded "[g] the run ends at its deadline"
  for p in $(cat "$STUB/pids"); do kill "$p" 2>/dev/null; done
  # five failed reads: dropped and named
  printf 'FAIL\n' > "$STUB/pulls/$(kf 'acme/app¤7').json"; mlog acme/app 7
  rm -f "$STUB/pulls/$(kf 'acme/app¤6').json"; for i in 1 2 3 4; do me; done
  c_has "$OUT" "waiting acme/app¤7: its body was not read (gh rc 1)" "[g] four failed reads: still waiting"
  me; c_has "$OUT" "dropped acme/app¤7: its body was not read in 5 tries (gh rc 1)" "[g] the fifth: dropped and named"
  me; c_hasnt "$OUT" "acme/app¤7" "[g] and not read again"
  # an answer of more than 4096 bytes whose first 4096 end in `Rules applied: D1` (the line names D12, no item)
  body 'acme/app¤8' "$(printf '```\n'; for i in 1 2 3 4 5; do printf '~~~%s\n' "$(python3 -c 'print("é" * 397)')"; done
    printf '~~~%s\n```\nRules applied: D12\n' "$(python3 -c 'print("x" * 77)')")"
  c_eq "$(jq -r "$(bpy 'import brain_stale as b; print(b.BODY_JQ)')" < "$STUB/pulls/$(kf 'acme/app¤8').json" | head -c 4096 | tail -c 17)" \
    "Rules applied: D1" "[g] instrument: the first 4096 bytes of the answer end in 'Rules applied: D1'"
  mlog acme/app 8; me
  c_has "$OUT" "waiting acme/app¤8: its body was not read (an answer cut short)" "[g] an answer cut short is not read"
  c_eq "$(ev D1)" "held/-/acme/app¤5/pr:acme/app¤5" "[g] and writes no held of D1 for it"
  # a damaged waiting entry: the others and the offset stay
  body 'acme/app¤8' 'Rules applied: F1'
  bpy 'import json; p = s.state_dir() + "/merge-evidence.json"; m = json.load(open(p)); m["wait"] = [["bad"], 7, ["acme/app¤8", 1]]; s._write_file(p, json.dumps(m))'
  me; c_eq "$(ev F1)" "held/-/acme/app¤8/pr:acme/app¤8" "[g] a damaged waiting entry is left out, the PR beside it read"
  c_hasnt "$OUT" "started at the end" "[g] and the offset kept (not a first run)"
}

case_takeover() {
  np; rules; me; body 'acme/app¤5' 'Rules applied: D1'; mlog acme/app 5
  echo 2 > "$STUB/delay"
  local o="$TMP/takeover.out" pid
  takeover_mid_run() {  # the run of sA waits on gh; sB takes the brain over meanwhile
    local i
    rm -f "$STUB/started"; echo 2 > "$STUB/delay"
    (CLAUDE_CODE_SESSION_ID=$1 "$BROOT/bin/brain" op merge-evidence > "$o" 2>&1) & pid=$!
    for i in $(seq 1 100); do [ -e "$STUB/started" ] && break; python3 -c 'import time; time.sleep(0.05)'; done
    SID=$2 br claim --take-over
    wait "$pid"; rm -f "$STUB/delay"
  }
  takeover_mid_run sA sB; c_rc 0 "[t] instrument: sB takes the brain over while the run waits on gh"
  c_has "$(cat "$o")" "waiting acme/app¤5: D1 held was refused" "[t] the old writer's write is refused: the PR waits"
  c_eq "$(ev D1)" "" "[t] nothing written by the old writer"
  SID=sB br op merge-evidence; c_eq "$(ev D1)" "held/-/acme/app¤5/pr:acme/app¤5" "[t] the new writer reads the PR"
  # the fifth refused write: dropped and named
  body 'acme/app¤6' 'Rules applied: F1'; mlog acme/app 6; SID=sB br op merge-evidence
  bpy 'import json; p = s.state_dir() + "/merge-evidence.json"; m = json.load(open(p)); m["wait"] = [["acme/app¤7", 4]]; s._write_file(p, json.dumps(m))'
  body 'acme/app¤7' 'Rules applied: D1'
  takeover_mid_run sB sA
  c_has "$(cat "$o")" "dropped acme/app¤7: a write was refused in 5 tries" "[t] a write refused at the fifth try: dropped and named"
  SID=sA br op merge-evidence; c_hasnt "$OUT" "acme/app¤7" "[t] and not read again"
  # a state file with no offset: said so, the waiting PRs kept
  bpy 's._write_file(s.state_dir() + "/merge-evidence.json", "{\"wait\": [[\"acme/app¤8\", 0]]}\n")'
  body 'acme/app¤8' 'Rules applied: F1'
  SID=sA br op merge-evidence; c_has "$OUT" "merge-evidence.json held no offset: started at the end of the merge log" "[t] a file with no offset: said so"
  c_has "$OUT" "1 waiting kept" "[t] its waiting PR kept"
  SID=sA br op merge-evidence; c_eq "$(ev F1 | grep -c 'app¤8')" 1 "[t] and read at the next run"
}

case_soul() {
  np
  c_eq "$(bpy 'import brain_ledger as L
ops = [{"op": "owner-promote", "id": "D1", "pointer": "CLAUDE.md [S07]"},
       {"op": "owner-promote", "id": "D2", "pointer": "CLAUDE.md [S08] and [S09]"},
       {"op": "owner-promote", "id": "T1", "pointer": "elsewhere", "ext": {"coordinator": {"soul": "S10"}}},
       {"op": "owner-promote", "id": "F1", "pointer": "x", "soul": "S11"},
       {"op": "owner-promote", "id": "D3", "pointer": "CLAUDE.md [S12]"},
       {"op": "owner-add", "item": {"id": "D4", "ext": {"coordinator": {"demoted_from": "S12"}}}},
       {"op": "owner-demote", "soul": "S11", "item": {"id": "D5"}}]
print(" ".join(sorted(L.soul_live(ops))))')" "S07 S10" \
    "[s] promoted by pointer (one code) or an extension's code count; two codes in a pointer, a demotion by either form do not"
}

case_repos() {
  np; rules; br op add --kind fact --text "the lib lives elsewhere" --anchor 'other/lib¤1'; me
  body 'stranger/repo¤5' 'Rules applied: D1'; body 'other/lib¤2' 'Rules applied: F1'
  mlog stranger/repo 5; mlog other/lib 2; me
  c_has "$OUT" "skipped stranger/repo¤5: not a repository this brain names" "[r] a stranger's PR: skipped and named"
  c_eq "$(ev D1)|$(grep -c 'stranger/repo' "$STUB/calls")" "|0" "[r] not looked up, nothing written"
  c_eq "$(ev F1)" "held/-/other/lib¤2/pr:other/lib¤2" "[r] a repository an item anchors: read"
}

case_import_label() {
  np
  c_eq "$(bpy 'import brain_transfer as t; a = t.imported_label("pr:acme/app¤5", "0123456789ab"); b = t.imported_label("pr:acme/app¤6", "0123456789ab")
print(a != b and t.IMPORTED_LABEL.fullmatch(a) is not None and t.IMPORTED_LABEL.fullmatch(b) is not None)')" True \
    "[i] two PR sessions import as two labels of the imported shape"
}

case_prompt() {
  local pin i
  pin() { hin session_id="${1:-$SID}" cwd="$P" hook_event_name=UserPromptSubmit prompt=next; }
  runs() { eplines merge-evidence | grep -c '"hook":"UserPromptSubmit"' || true; }
  waitrun() { for i in $(seq 1 300); do [ "$(runs)" -ge "$1" ] && return 0; python3 -c 'import time; time.sleep(0.1)'; done; return 1; }
  np; rules; mlog acme/app 3
  hk prompt "$(pin)"; c_eq "$RC|$OUT|$ERR" "0||" "[h] the prompt hook: rc 0, prints nothing"
  waitrun 1; c_has "$(eplines merge-evidence)" "started at the end of the merge log" "[h] the background run logs its outcome"
  hk prompt "$(pin)"; c_eq "$(runs)" 1 "[h] not started again within 10 minutes"
  body 'acme/app¤5' 'Rules applied: D1'; mlog acme/app 5
  printf '{"t": %s, "session": "sA"}\n' "$(python3 -c 'import time; print(time.time() - 601)')" > "$(sdir)/merge-evidence-bg.json"
  hk prompt "$(pin)"; waitrun 2; c_eq "$(ev D1)" "held/-/acme/app¤5/pr:acme/app¤5" "[h] after 10 minutes the next prompt records the merge"
  np; rules; mlog acme/app 3
  hk prompt "$(pin sB)"; c_eq "$RC|$OUT|$([ -e "$(sdir)/merge-evidence-bg.json" ] && echo stamp)" "0||" "[h] another session: nothing, not even the stamp"
  VIBEMAESTRO_ROLE=worker hk prompt "$(pin)"; c_eq "$RC|$OUT|$([ -e "$(sdir)/merge-evidence-bg.json" ] && echo stamp)" "0||" "[h] a worker: silent"
  OUT=$(pin | PATH="$TMP/nogh" hookpy "$BROOT/scripts/brain_hook.py" prompt 2>&1); RC=$?
  python3 -c 'import time; time.sleep(1)'
  c_eq "$RC|$OUT|$(runs)" "0||0" "[h] no gh: rc 0, nothing started"
  np; rules
  hk prompt "$(pin)"; waitrun 1
  c_eq "$RC|$(cursor)" "0|0" "[h] no merge log yet: the first run starts at offset 0"
  body 'acme/app¤5' 'Rules applied: D1'; mlog acme/app 5
  printf '{"t": %s, "session": "sA"}\n' "$(python3 -c 'import time; print(time.time() - 601)')" > "$(sdir)/merge-evidence-bg.json"
  hk prompt "$(pin)"; waitrun 2
  c_eq "$(ev D1)" "held/-/acme/app¤5/pr:acme/app¤5" "[h] so the machine's first merge is read"
}

echo "== cases =="
for c in case_basic case_twice case_lines case_hostile case_session case_writer case_gh case_takeover case_soul case_repos case_import_label case_prompt; do run_case $c; done
cd "$TMP" || exit 1

summary
