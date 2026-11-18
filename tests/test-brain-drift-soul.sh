#!/bin/bash
# =============================================================================
# vibemaestro-brain: drift not handled yet (`brain ledger --drift`), SOUL codes that go dormant, the SOUL file checked against
# the brain (the project's `soul_file`)
# =============================================================================
# Run: bash tests/test-brain-drift-soul.sh
#
# Offline. Items and ops are written through the store library as the writer sA, at times in the past.
#   [d] --drift: a decision in drift with no owner-queue item naming it is listed with what to do, rc 8; a Q item added to the
#       log before the last broke (also in the same second), or naming D12 or drift_D1, does not handle D1; one added after it
#       does (rc 0, "no drift left to handle"), also once closed (the owner chose); a new broke opens it again; a trap or fact in
#       drift is listed until it is superseded or closed; a SOUL code in drift until a Q item names it, a code used by hand and
#       never promoted too; a demoted code never, a code promoted again after its demotion again; another session or a config
#       that refuses writes: the same lines, rc 0; --drift with a RULE or --record: usage (64)
#   [s] a SOUL code promoted 31 days ago with no event since is dormant in `brain ledger`, the card and the record; one with an
#       event 29 days ago or promoted today is not; a demoted code is not; `brain ledger` lists a promoted code with no evidence
#   [f] soul_file: a code promoted with no line and a line with no promotion are named on the card; a file that agrees, or no
#       key, adds no line; a file that cannot be read, a FIFO (never waited on) or one over 1 MiB says so; a wrong value
#       refuses writes
# =============================================================================
set -uo pipefail
if [ -z "${BRAIN_SUITE_REEXEC:-}" ]; then
  export PYTHONUSERBASE="${PYTHONUSERBASE:-$(python3 -m site --user-base 2>/dev/null)}"
  exec env -u CLAUDE_CONFIG_DIR -u CLAUDE_CODE_SESSION_ID BRAIN_SUITE_REEXEC=1 HOME=/nonexistent bash "$0" "$@"
fi
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap '[ -n "$TMP" ] && rm -rf "$TMP"' EXIT
clean_env "$TMP"
# shellcheck source=fixtures/brain.sh
. "$HERE/fixtures/brain.sh"
brain_kit "$SRC_ROOT"

np() { newp; }
conf() { mkdir -p "$P/.vibemaestro"; printf '%s\n' "$1" > "$P/.vibemaestro/brain.json"; }   # conf <JSON> — the project's config

# seed <ID@DAYS-AGO[;text=T]>… — items as the writer sA, created that many days ago (D as the owner's, Q, T, F as the session's)
seed() {
  CLAUDE_CODE_SESSION_ID="$SID" python3 - "$BROOT/scripts" "$@" <<'PY'
import json, sys, time
sys.path.insert(0, sys.argv[1])
import brain_store as s
d = s.state_dir()
kinds = {v: k for k, v in s.KINDS.items()}
by = {"session": "sA", "agent": None}
with s.locked(d):
    raw, ops = s.verify(d)
    st = s.fold(ops)
    def put(op):
        global raw
        raw = s.append(d, raw, op)
        s.apply(st, json.loads(raw[-1].decode("utf-8")))
    if st["writer"] is None:
        put({"op": "claim", "t": "2025-01-01T00:00:00Z", "by": by, "takeover": False})
    for spec in sys.argv[2:]:
        head, *opts = spec.split(";")
        iid, _, days = head.partition("@")
        o = dict(x.split("=", 1) for x in opts)
        src = {"type": "owner" if iid[0] == "D" else "coordinator"}
        if iid[0] == "D":
            src.update(quote="q", where="chat")
        item = {"id": iid, "kind": kinds[iid[0]], "pinned": iid[0] == "D", "text": o.get("text", "item " + iid), "source": src,
                "expires": None, "links": [], "anchors": [], "supersedes": None}
        if "demoted_from" in o:
            item["ext"] = {"coordinator": {"demoted_from": o["demoted_from"]}}
        put({"op": "owner-add" if iid[0] == "D" else "add", "item": item, "t": s.now_iso(time.time() - float(days) * 86400),
             "by": by})
    s.write_caches(d, st, s.head_of(raw))
PY
  [ $? = 0 ] || bad "seed: the seeding failed ($*)"
}

# ops <spec>… — ops as the writer sA: broke:RULE:DAYS:SESSION or held:RULE:DAYS:SESSION (RULE an id or [S07]), or a JSON op
# whose "t" is days ago
ops() {
  CLAUDE_CODE_SESSION_ID="$SID" python3 - "$BROOT/scripts" "$@" <<'PY'
import json, sys, time
sys.path.insert(0, sys.argv[1])
import brain_store as s
d = s.state_dir()
now = time.time()
by = {"session": "sA", "agent": None}
with s.locked(d):
    raw, ops = s.verify(d)
    st = s.fold(ops)
    def put(op):
        global raw
        raw = s.append(d, raw, op)
        s.apply(st, json.loads(raw[-1].decode("utf-8")))
    for a in sys.argv[2:]:
        if a.startswith("{"):
            op = json.loads(a)
            op["t"] = s.now_iso(now - float(op.get("t", 0)) * 86400)
            op.setdefault("by", by)
        else:
            kind, rule, days, session = a.split(":", 3)
            op = {"op": "evidence", "result": kind, "pointer": "kb/evidence.md", "session": session}
            op.update({"soul": rule[1:-1]} if rule.startswith("[") else {"id": rule})
            if kind == "broke":
                op["differed"] = "it went another way"
            op.update(t=s.now_iso(now - float(days) * 86400), by=by)
        put(op)
    s.write_caches(d, st, s.head_of(raw))
PY
  [ $? = 0 ] || bad "ops: the seeding failed ($*)"
}
promote() { ops "{\"op\": \"owner-promote\", \"id\": \"$1\", \"pointer\": \"CLAUDE.md [$2]\", \"t\": ${3:-0}}"; }   # promote ID CODE [DAYS]
drift() { br ledger --drift; }
card() { bpy 'import time, brain_ledger as L
st, ops, led = L.snapshot(s.state_dir()); print("\n".join(s.card_lines(st, time.time(), ops=ops, d=s.state_dir())))'; }

case_drift() {
  np; seed D1@40 D12@40 T1@40 F1@40
  drift; c_eq "$RC|$OUT" "0|no drift left to handle" "[d] no drift: rc 0, says so"
  ops broke:D1:3:S1; seed "Q1@2.5;text=drift D1: narrow it to security PRs"; ops broke:D1:2:S2
  drift; c_rc 8 "[d] a decision in drift, not handled: rc 8 (the Q item came before the last broke)"
  c_eq "$OUT" "D1 · drift: broke 2 of 2 checks in 30 d, 2 sessions · to do: an owner-queue item naming D1, with the evidence and one proposal (fix, narrow or drop)" \
    "[d] the line names the rule, its drift and what to do"
  seed "Q2@1;text=drift D12: narrow it" "Q5@1;text=see drift_D1 later"
  drift; c_rc 8 "[d] a Q item naming D12 or drift_D1 does not handle D1"
  SID=sB br ledger --drift; c_eq "$RC|$(printf '%s\n' "$OUT" | tail -n 1)" "0|(rc 0: this session does not write this brain; brain claim --take-over makes it the writer)" "[d] another session: the same lines, rc 0"
  c_has "$OUT" "D1 · drift" "[d] and it still lists D1"
  conf '{"ledger": {"drift_days": "x"}}'; drift
  c_eq "$RC|$(printf '%s\n' "$OUT" | tail -n 1)" "0|(rc 0: writes are refused until .vibemaestro/brain.json is fixed)" "[d] writes refused: rc 0, says why"
  rm -f "$P/.vibemaestro/brain.json"
  seed "Q3@1;text=owner: drift D1, propose narrowing it to security PRs"
  drift; c_eq "$RC|$OUT" "0|no drift left to handle" "[d] a Q item naming D1 after its last broke handles it"
  br op close Q3 --reason "the owner kept D1" --pointer chat; c_rc 0 "[d] instrument: the owner chose, the Q item closes"
  drift; c_rc 0 "[d] a closed Q item still counts: the owner decided"
  ops broke:D1:0:S3
  drift; c_rc 8 "[d] a new broke after the handling opens it again"
  br op supersede Q1 --text "drift D1, broke again: narrow it to security PRs" --reason "new evidence"
  drift; c_eq "$RC|$OUT" "0|no drift left to handle" "[d] a Q item superseded after the new broke (a new id) handles it"
  ops broke:D1:0:S4
  # a trap or a fact: the session's to handle
  ops broke:T1:3:S1 broke:T1:2:S2 broke:F1:3:S1 broke:F1:2:S2
  drift; c_has "$OUT" "T1 · drift: broke 2 of 2 checks in 30 d, 2 sessions · to do: fix, narrow or drop it with the evidence (brain op supersede T1, or brain op close T1)" \
    "[d] a trap in drift: fix, narrow or drop"
  c_has "$OUT" "F1 · drift" "[d] a fact in drift is listed"
  seed "Q4@0;text=drift T1 and F1"
  drift; c_has "$OUT" "T1 · drift" "[d] a Q item does not handle a trap: the session changes it"
  br op supersede T1 --text "the trap, narrowed" --reason "broke twice, see kb/evidence.md"; br op close F1 --reason "no longer true" --pointer kb/evidence.md
  drift; c_hasnt "$OUT" "T1 ·" "[d] a superseded trap is handled"; c_hasnt "$OUT" "F1 ·" "[d] a closed fact is handled"
  # a SOUL code
  np; seed D2@40; promote D2 S07 40; ops "broke:[S07]:3:S1" "broke:[S07]:2:S2"
  drift; c_rc 8 "[d] a SOUL code in drift: rc 8"; c_has "$OUT" "[S07] · drift" "[d] it is listed"
  seed "Q1@0;text=drift [S07]: propose dropping it"
  drift; c_rc 0 "[d] a Q item naming [S07] handles it"
  np; seed D2@40; promote D2 S08 40; seed "D3@10;demoted_from=S08"; ops "broke:[S08]:3:S1" "broke:[S08]:2:S2"
  drift; c_rc 0 "[d] a demoted SOUL code is never listed"
  seed D4@5; promote D4 S08 1; ops "broke:[S08]:0:S4"
  drift; c_rc 8 "[d] the same code promoted again after its demotion is listed again"
  np; seed D1@40; ops "broke:[S20]:3:S1" "broke:[S20]:2:S2"
  drift; c_has "$OUT" "[S20] · drift" "[d] a code used by hand, never promoted: listed"
  seed "Q1@0;text=drift S20: drop it"; drift; c_rc 0 "[d] and a Q item naming S20 handles it"
  # a Q item and a broke written in the same second, the Q item first in the log
  ops broke:D1:3:S1 '{"op": "add", "t": 0, "item": {"id": "Q2", "kind": "queue", "pinned": false, "text": "drift D1: narrow it", "source": {"type": "coordinator"}, "expires": null, "links": [], "anchors": [], "supersedes": null}}' broke:D1:0:S2
  c_eq "$(bpy 'import json; ops = [json.loads(l) for l in open(s.state_dir() + "/hot.jsonl")]; print(ops[-2]["t"] == ops[-1]["t"])')" True \
    "[d] instrument: the Q item and the broke share one second"
  drift; c_rc 8 "[d] the Q item came first in the log: D1 is not handled"
  br ledger --drift D1; c_rc 64 "[d] --drift with a RULE: usage"
  br ledger --drift --record; c_rc 64 "[d] --drift with --record: usage"
}

case_soul_dormant() {
  np; seed D2@60 D3@60 D4@60; promote D2 S07 31; promote D3 S09 31; promote D4 S10 0; ops "held:[S09]:29:S1"
  br ledger; c_has "$OUT" "[S07] · SOUL · no evidence yet · dormant" "[s] a code promoted 31 days ago with no event: dormant in brain ledger"
  c_eq "$(printf '%s\n' "$OUT" | grep -F '[S09]' | grep -c dormant)" 0 "[s] an event 29 days ago: not dormant"
  c_eq "$(printf '%s\n' "$OUT" | grep -F '[S10]' | grep -c dormant)" 0 "[s] promoted today: not dormant"
  c_has "$OUT" "[S10] · SOUL · no evidence yet" "[s] brain ledger lists a promoted code with no evidence"
  c_has "$(card)" "dormant (30 d): [S07]" "[s] the card names it"
  br ledger --record; c_has "$OUT" "SOUL: [S07]" "[s] the record's dormant section names it"
  np; seed D2@60; promote D2 S07 40; seed "D3@35;demoted_from=S07"
  br ledger; c_eq "$(printf '%s\n' "$OUT" | grep -c dormant)" 0 "[s] a demoted code is not dormant"
}

case_soul_file() {
  np; seed D2@60 D3@60; promote D2 S07 1; promote D3 S09 1
  c_hasnt "$(card)" "SOUL file" "[f] no soul_file key: no line"
  printf '# Shared rules\n- [S07] one review round\n- [S11] a line nobody promoted\n' > "$TMP/CLAUDE-$NP.md"
  conf "{\"soul_file\": \"$(wpath "$TMP/CLAUDE-$NP.md")\"}"
  c_has "$(card)" "differs: [S09] no line · [S11] not promoted" "[f] a promoted code with no line and a line with no promotion are named"
  printf -- '- [S07] one\n- [S09] two\n' > "$TMP/CLAUDE-$NP.md"
  c_hasnt "$(card)" "SOUL file" "[f] a file that agrees: no line"
  printf -- '- [S07] one\r\n\032\r\n- [S09] two\r\n' > "$TMP/CLAUDE-$NP.md"
  c_hasnt "$(card)" "SOUL file" "[f] CRLF and a Ctrl-Z byte before a line: still read whole (Windows text mode ends a read at Ctrl-Z)"
  mkdir -p "$P/up"; printf -- '- [S07] one\n- [S09] two\n' > "$P/up/rules.md"; conf '{"soul_file": "up/rules.md"}'
  c_hasnt "$(card)" "SOUL file" "[f] a relative path is read from the work tree's top"
  conf '{"soul_file": "missing.md"}'
  c_has "$(card)" "SOUL file missing.md cannot be read (FileNotFoundError)" "[f] a file that cannot be read says so"
  if [ "${OS:-}" = Windows_NT ]; then
    c_skip "[f] a FIFO with no writer" "Windows has no FIFO in the file system; its console device stands in"
    conf '{"soul_file": "\\\\.\\CON"}'                 # \\.\CON: the device on every Windows (a bare CON in a full path is a file since Windows 11)
    OUT=$(PLANT_CAP_SECS=20 capped card 2>&1); RC=$?
    c_eq "$RC" 0 "[f] the console device as the SOUL file: the card returns (within the cap)"
    c_has "$OUT" "CON cannot be read" "[f] and says so"
  else
    mkfifo "$P/fifo"; conf '{"soul_file": "fifo"}'
    OUT=$(PLANT_CAP_SECS=20 capped card 2>&1); RC=$?
    c_eq "$RC" 0 "[f] a FIFO with no writer: the card returns (within the cap)"
    c_has "$OUT" "SOUL file fifo cannot be read (not a regular file)" "[f] and says so"
  fi
  python3 -c 'import sys; open(sys.argv[1], "w", newline="").write("[S07] " + "x" * (1024 * 1024))' "$P/big.md"; conf '{"soul_file": "big.md"}'
  c_has "$(card)" "SOUL file big.md cannot be read (over 1 MiB)" "[f] a file over 1 MiB says so"
  mkdir -p "$P/adir"; conf '{"soul_file": "adir"}'
  c_has "$(card)" "SOUL file adir cannot be read ($([ "${OS:-}" = Windows_NT ] && echo PermissionError || echo "not a regular file"))" \
    "[f] a directory: not a regular file (Windows refuses to open a directory as a file: PermissionError)"
  conf '{"soul_file": "\ud800.md"}'
  c_has "$(card)" "cannot be read ($([ "${OS:-}" = Windows_NT ] && echo FileNotFoundError || echo UnicodeEncodeError))" \
    "[f] a path the file system cannot encode: says so, the card stays (Windows paths are UTF-16: no such file)"
  conf '{"soul_file": 7}'
  br op add --kind trap --text "a trap"; c_rc 1 "[f] a wrong value refuses writes"
  c_has "$OUT" "soul_file must be a path of 1 to 1024 characters" "[f] and names the key"
  conf '{"soul_file": ""}'; br op add --kind trap --text "a trap"; c_rc 1 "[f] an empty path refuses writes"
}

echo "== cases =="
for c in case_drift case_soul_dormant case_soul_file; do run_case $c; done
cd "$TMP" || exit 1

summary
