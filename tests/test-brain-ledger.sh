#!/bin/bash
# =============================================================================
# vibemaestro-brain, the evidence ledger: held, broke, a goal's progress, the thresholds (promote?, drift, dormant) as marks of
# `brain ledger`, the review card's ledger lines, the monthly record, and an existing brain's log kept (log format 5, and the
# ops and fields an older brain's direction gate and ladder wrote, read with no extension)
# =============================================================================
# Run: bash tests/test-brain-ledger.sh
#
# Offline: a stub `gh` first on PATH answers `gh api …` from files (as the layers suite's); no case looks an anchor up.
#   [a] evidence: `brain op held|broke RULE` and `brain op hit T` write one `evidence` op; a rule is a D, T or F item or a SOUL
#       code (`[S07]` or `S07`); `--session` names a session item, counted by the root of its supersede chain; every refusal
#       (no pointer, no what-differed, a goal, a work item, no such item, a superseded or closed rule, a sensitive value);
#       evidence on a decision leaves its item as it was; `brain ledger` and `brain ledger RULE`
#   [b] the thresholds, read at the time of the check: promote at 5 held from 3 sessions over 7 days with no broke in 30, and not
#       one short of any; drift at 2 broke from 2 sessions or 1 broke in 3 checks within 30 days, and not past them; dormant at
#       30 days untouched, a goal and a window never; each key of `ledger` in .vibemaestro/brain.json moves its outcome; a wrong
#       value refuses writes, an unknown key warns
#   [e] a goal's progress: `brain op progress G1` writes ledger data, the goal's item stays the owner's byte for byte; the card's
#       goal line carries the measure
#   [g] the review card: the ledger lines in order (one line per goal, dormant, the record due), ≤ 1,000 units, and no drift,
#       promotion, SOUL or gate line (those are an extension's); `brain ledger` still marks drift and promote?; doctor prints them
#   [h] the monthly record: `brain ledger --record` counts the rules, the crossings, progress, dormant items, capacity and
#       compactions of the period, and logs it; the card's due line 30 days after the last one
#   [i] an existing brain of log format 5 (every op kind, goals, focus, requests) folds to the same bytes, keeps its ids and cache,
#       its hot.md matches, a hand edit stops every write, a held works on it, and the brain of format 5 refuses the log once it
#       holds an evidence op (rc 5); full sessions carrying an older brain's goal field stay within every string's cap
#   [j] a log written by the brain of the direction gate and the ladder (a session's goal or reason, a lesson and a decision
#       promoted with a code, a queue moved up, a demotion, evidence on a code and as a hit, progress), read with no extension:
#       it verifies and folds, doctor finds no problem (its hot.md an older render), every string renders with no session tag,
#       `brain ledger` counts each event under the rule it was written for, `brain show` prints the old fields, a new write
#       chains on; the gate's and the ladder's commands are gone (usage), the owner's promote moves a goal, decision or window
#       only, and a supersede keeps a session's reason for no goal
# No planted break: each case is red on the brain before the ledger, green after.
# =============================================================================
set -uo pipefail
if [ -z "${BRAIN_SUITE_REEXEC:-}" ]; then
  export PYTHONUSERBASE="${PYTHONUSERBASE:-$(python3 -m site --user-base 2>/dev/null)}"
  # Every issue or PR number is spelled ¤5 so that the public-tree scan does not read test data as a reference; the copy this run
  # executes has a real hash sign (same name, so the suite's result file keeps its name).
  SRC_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
  TEXT_DIR=$(mktemp -d) && sed 's/¤/#/g' "$0" > "$TEXT_DIR/$(basename -- "$0")" || exit 2
  exec env -u CLAUDE_CONFIG_DIR -u CLAUDE_CODE_SESSION_ID -u BRAIN_DEFAULT_REPO -u CLAUDE_PROJECT_DIR BRAIN_SUITE_REEXEC=1 \
       BRAIN_SUITE_SRC_DIR="$SRC_DIR" BRAIN_SUITE_TEXT_DIR="$TEXT_DIR" HOME=/nonexistent bash "$TEXT_DIR/$(basename -- "$0")" "$@"
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
# the brain of log format 5: goals, focus and requests, the last commit before the ledger
MAIN_REV=c3f2765
# the brain of the direction gate and the SOUL ladder, before they left the kit
REV627=452fa22
# the owner's command word pair, built here: a command line the suite is started with never holds it
BO=$(printf 'brain %s' owner)

# --- the stub gh (the layers suite's) -----------------------------------------------------------------------------------------
export STUB="$TMP/stub"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'SH'
#!/bin/sh
echo "$*" >> "$STUB/calls"
[ "$1" = api ] || exit 2
case "$2" in
  repos/*/issues/*) dir=answers ;;
  repos/*/pulls/*) dir=pulls ;;
  *) exit 2 ;;
esac
f="$STUB/$dir/$(printf '%s' "$2" | sed -e 's#^repos/##' -e 's#/issues/#_#' -e 's#/pulls/#_#' -e 's#/#_#')"
[ -f "$f" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
cat "$f"
SH
chmod +x "$TMP/bin/gh"
PY=$(command -v python3)
export PATH="$TMP/bin:$PATH"

C20=2026-10-20T15:00:00Z
stub_reset() { [ -n "$STUB" ] && rm -rf "$STUB"; mkdir -p "$STUB/answers" "$STUB/pulls"; : > "$STUB/calls"; }
np() { newp; stub_reset; }
rep() { python3 -c 'import sys; print(sys.argv[1] * int(sys.argv[2]))' "$@"; }
tok() { printf 'g%sp_%sa1B2c3' h "$(rep a1B2c3D4e5 3)"; }   # a token's shape, built here so no file holds one
status_of() { bpy "print(s.fold(s.verify(s.state_dir())[1])['items']['$1']['status'])"; }
lastop() { tail -n 1 "$(sdir)/hot.jsonl"; }
conf() { mkdir -p "$P/.vibemaestro"; printf '%s\n' "$1" > "$P/.vibemaestro/brain.json"; }   # conf <JSON> — the project's config
ago() { python3 -c 'import sys, time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - float(sys.argv[1]) * 86400)))' "$1"; }
dplus() { python3 -c 'import datetime, sys; print(datetime.datetime.now(datetime.timezone.utc).date() + datetime.timedelta(days=int(sys.argv[1])))' "$1"; }
ctxof() {  # ctxof <file> — additionalContext of one hook's stdout file ("" when it printed nothing)
  python3 -c 'import json, sys
t = open(sys.argv[1], encoding="utf-8").read().strip()
print(json.loads(t)["hookSpecificOutput"]["additionalContext"] if t else "", end="")' "$1"
}
EVENTS="session-start"; for i in 2 3 4 5 6 7 8 9 10 11 12 13 14; do EVENTS="$EVENTS session-start-$i"; done
startall() {  # startall [source] — the 14 SessionStart string commands at once, as Claude Code runs them; sets S1 (string 1), ALL
  local in e p n t rcs=0 pids=()
  in=$(hin session_id="$SID" cwd="$P" hook_event_name=SessionStart source="${1:-compact}")
  for e in $EVENTS; do
    printf '%s' "$in" | env -u CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR="$P" "$PY" "$BROOT/scripts/brain_hook.py" "$e" > "$TMP/out.$e" 2> "$TMP/err.$e" &
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p" || rcs=1; done
  RC=$rcs; S1=$(ctxof "$TMP/out.session-start"); ALL="$S1"$'\n'
  for n in 2 3 4 5 6 7 8 9 10 11 12 13 14; do
    t=$(ctxof "$TMP/out.session-start-$n"); [ -n "$t" ] && ALL="$ALL$t"$'\n'
  done
}
strings_check() {  # strings_check — after startall: "<strings> <largest in UTF-16 units> <hard cuts>"
  python3 - "$TMP"/out.session-start "$TMP"/out.session-start-[0-9]* <<'PY'
import json, sys
ts = []
for p in sys.argv[1:]:
    t = open(p, encoding="utf-8").read().strip()
    if t:
        ts.append(json.loads(t)["hookSpecificOutput"]["additionalContext"])
print(len(ts), max(len(t.encode("utf-16-le")) // 2 for t in ts), sum(t.count("[brain: cut") for t in ts))
PY
}
card_of() { printf '%s\n' "$S1" | sed -n '/^Review card/,/^## Brain/p' | sed '$d'; }   # card_of — after startall: the review card

# seed <spec>… — items appended through the store library as the writer sA (the layers suite's seed, plus no_goal):
#   ID@CREATED[;text=T][;len=N][;links=N][;qlen=N][;review=DAY][;goal=G][;focus=P][;no_goal=REASON]
seed() {
  CLAUDE_CODE_SESSION_ID="$SID" python3 - "$BROOT/scripts" "$@" <<'PY'
import json, sys
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
        iid, _, created = head.partition("@")
        o = dict(x.split("=", 1) for x in opts)
        text = "t" * int(o["len"]) if "len" in o else o.get("text", "item " + iid)
        src = {"type": "owner" if iid[0] in "GDW" else "coordinator"}
        if iid[0] in "GPR" or iid[0] == "D" and "qlen" in o:
            src.update(quote="q" * int(o.get("qlen", 1)), where="chat")
        item = {"id": iid, "kind": kinds[iid[0]], "pinned": iid[0] == "D", "text": text, "source": src,
                "expires": "2099-01-02T22:00:00Z" if iid[0] == "W" else None, "links": ["kb/x"] * int(o.get("links", 0)),
                "anchors": [], "supersedes": None}
        if iid[0] == "G":
            item.update(done="the PR merged", not_doing="the ledger", review=o.get("review", "2099-12-31"), scope="project")
        item.update({k: o[k] for k in ("goal", "focus", "no_goal") if k in o})
        put({"op": "owner-add" if iid[0] in "GDW" else "add", "item": item, "t": created, "by": by})
    s.write_caches(d, st, s.head_of(raw))
PY
  [ $? = 0 ] || bad "seed: the seeding failed ($*)"
}

# ops <spec>… — ops appended through the store library as the writer sA, each at a time N days ago:
#   held:RULE:N[:SESSION] · broke:RULE:N[:SESSION] (RULE an item id or [S07]) · progress:G1:N:MEASURE · a JSON op whose "t" is N
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
    if st["writer"] is None:
        put({"op": "claim", "t": "2025-01-01T00:00:00Z", "by": by, "takeover": False})
    for a in sys.argv[2:]:
        if a.startswith("{"):
            op = json.loads(a)
            op["t"] = s.now_iso(now - float(op.get("t", 0)) * 86400)
            op.setdefault("by", by)
        else:
            kind, rule, days, *rest = a.split(":", 3)
            if kind == "progress":
                op = {"op": "progress", "id": rule, "measure": rest[0], "pointer": "kb/progress.md"}
            else:
                op = {"op": "evidence", "result": kind, "pointer": "kb/evidence.md"}
                op.update({"soul": rule[1:-1]} if rule.startswith("[") else {"id": rule})
                if kind == "broke":
                    op["differed"] = "it went another way"
                if rest:
                    op["session"] = rest[0]
            op.update(t=s.now_iso(now - float(days) * 86400), by=by)
        put(op)
    s.write_caches(d, st, s.head_of(raw))
PY
  [ $? = 0 ] || bad "ops: the seeding failed ($*)"
}
episode_at() {  # episode_at <kind> <days ago> [key=json]… — an Episode Log line at that time
  CLAUDE_CODE_SESSION_ID="$SID" python3 - "$BROOT/scripts" "$@" <<'PY'
import json, os, sys, time
sys.path.insert(0, sys.argv[1])
import brain_store as s
d = s.state_dir()
line = {"kind": sys.argv[2], "t": s.now_iso(time.time() - float(sys.argv[3]) * 86400), "session": "sA"}
line.update({k: json.loads(v) for k, v in (x.split("=", 1) for x in sys.argv[4:])})
with open(os.path.join(d, "episodes.jsonl"), "a", encoding="utf-8") as f:
    f.write(s.dumps(line) + "\n")
PY
}
record_at() {  # record_at <days ago> — the last full record's time, as `brain ledger --record` leaves it (ledger-record.json)
  CLAUDE_CODE_SESSION_ID="$SID" python3 - "$BROOT/scripts" "$1" <<'PY'
import os, sys, time
sys.path.insert(0, sys.argv[1])
import brain_store as s, brain_ledger as L
d = s.state_dir()
s._write_file(os.path.join(d, L.RECORD_FILE), s.dumps({"t": time.time() - float(sys.argv[2]) * 86400, "days": 30}) + "\n")
PY
}
cmdline() { python3 -c 'import shlex, sys; print(shlex.join(sys.argv[1:]))' "$@"; }
goal_args() {  # goal_args <text> <review day> — GA: the arguments after `owner` that pin a goal with every field
  GA=(add --kind goal --text "$1" --owner-quote "the owner's words, \"quoted\" whole" --where chat --done "the PR merged"
      --not-doing "the ledger" --review "$2" --scope project)
}
gown() {  # gown <args after owner…> — guard-owner, default mode, on that literal command, for session SID in project P
  hk guard-owner "$(python3 -c 'import json, sys
print(json.dumps({"session_id": sys.argv[1], "cwd": sys.argv[2], "hook_event_name": "PreToolUse", "tool_name": "Bash",
                  "permission_mode": "default", "tool_input": {"command": sys.argv[3]}}))' "$SID" "$P" "$(cmdline $BO "$@")")"
}
cand() {  # cand — the rules and items the thresholds name now: "promote … | drift … | dormant …"
  bpy 'import time, brain_ledger as L
st, ops, led = L.snapshot(s.state_dir()); now, t = time.time(), L.th()
keys = sorted(led, key=L.order)
tags = {k: L.standing(st, led, k, now, t) for k in keys}
print("promote", " ".join(k for k in keys if "promote?" in tags[k]), "| drift", " ".join(k for k in keys if "drift" in tags[k]),
      "| dormant", " ".join(L.dormant(st, ops, led, now, t)))'
}
old_brain() {  # old_brain <rev> <dir> — the brain and sdlc of rev under $TMP/<dir>, isolated as brain_kit isolates the copy;
               # sets OLD; rc 1 without it
  OLD="$TMP/$2"
  [ -d "$OLD/plugins/vibemaestro-brain" ] && return 0
  env -u GIT_DIR -u GIT_WORK_TREE git -C "$SRC_ROOT" cat-file -e "$1^{commit}" 2>/dev/null || return 1
  mkdir -p "$OLD" && env -u GIT_DIR -u GIT_WORK_TREE git -C "$SRC_ROOT" archive "$1" plugins/vibemaestro-brain plugins/vibemaestro-sdlc \
    | tar -x -C "$OLD" || return 1
  python3 - "$OLD/plugins/vibemaestro-brain/scripts/brain_store.py" "$MANAGED" "$ACCOUNT" "$$" <<'PY'
import re, sys
p, m, a, pid = sys.argv[1:5]
s = open(p, encoding="utf-8").read()
for pat, new in ((r"(?m)^MANAGED_SETTINGS = \(.*\)$", 'MANAGED_SETTINGS = ("%s/managed-settings.json",)\nSUITE_PID = %s' % (m, pid)),
                 (r"(?m)^        return pwd\.getpwuid\(os\.getuid\(\)\)\.pw_dir$", '        return "%s"' % a),
                 (r"(?m)^        if pid <= 1:$", "        if pid <= 1 or pid == SUITE_PID:")):
    s, n = re.subn(pat, lambda _: new, s)
    assert n == 1, pat
open(p, "w", encoding="utf-8").write(s)
PY
}

# --- [a] -----------------------------------------------------------------------------------------------------------------------
case_evidence() {
  np
  seed "T1@$C20;text=never edit the log by hand" "F1@$C20;text=the kit CLI is on PATH" "D1@$C20;qlen=5" "S1@$C20" "X1@$C20" \
       "W1@$C20" "G1@$C20" "R1@$C20" "P1@$C20;goal=G1" "N1@$C20" "Q1@$C20"
  local before k
  before=$(bpy 'print(s.dumps(s.load(s.state_dir())[1]["items"]["D1"]))')
  br op held D1 --pointer acme/app¤1; c_rc 0 "[a] held D1: rc 0"
  c_has "$OUT" "held D1: held 1 from 1 session, broke 0" "[a] it counts held, the sessions and broke"
  c_has "$(lastop)" '"op":"evidence"' "[a] one evidence op in the log"
  c_has "$(lastop)" '"result":"held"' "[a] with its result"
  c_eq "$(bpy 'print(s.dumps(s.load(s.state_dir())[1]["items"]["D1"]))')" "$before" "[a] the decision's item is as it was: the left brain is the owner's"
  br op held "[S07]" --pointer CLAUDE.md; c_rc 0 "[a] a SOUL code in brackets: rc 0"
  c_has "$OUT" "held [S07]: held 1 from 1 session" "[a] shown as [S07]"
  br op held S07 --pointer CLAUDE.md; c_has "$OUT" "held [S07]: held 2 from 1 session" "[a] the same code without brackets"
  c_has "$(lastop)" '"soul":"S07"' "[a] stored as its code"
  br op broke T1 --pointer acme/app¤2 --differed "a script rewrote the log"; c_rc 0 "[a] broke T1: rc 0"
  c_has "$OUT" "broke T1: held 0 from 0 sessions, broke 1" "[a] it counts broke"
  br op hit T1; c_rc 0 "[a] hit T1: rc 0"; c_has "$OUT" "hit T1: held 1 from 1 session, broke 1" "[a] a trap hit is a held"
  c_has "$(lastop)" '"via":"hit"' "[a] marked as a hit"
  c_eq "$(bpy 'print(s.load(s.state_dir())[1]["items"]["T1"]["hits"])')" 1 "[a] and the trap's hits still count"
  br op held F1 --pointer kb/x.md --session S1; c_rc 0 "[a] --session names a session item"
  br op supersede S1 --text "S1: the next step" --reason status; c_has "$OUT" "superseded S1 with S2" "[a] instrument: S1 continues as S2"
  br op held F1 --pointer kb/y.md --session S2; c_has "$OUT" "held F1: held 2 from 1 session" "[a] a session is counted by the root of its chain"
  c_has "$(lastop)" '"session":"S1"' "[a] stored as that root"
  br op held F1 --pointer kb/z.md; c_has "$OUT" "held F1: held 3 from 2 sessions" "[a] without --session: the writing session"
  br op held D1; c_rc 64 "[a] held without --pointer: usage (64)"
  br op broke D1 --pointer kb/x.md; c_rc 64 "[a] broke without --differed: usage (64)"
  br op held G1 --pointer kb/x.md; c_rc 1 "[a] a goal: refused"; c_has "$OUT" "a goal carries a progress measure" "[a] it says why"
  for k in W1 X1 N1 Q1 R1 P1 S2; do
    br op held $k --pointer kb/x.md; c_rc 1 "[a] $k: refused"; c_has "$OUT" "not a rule" "[a] $k: not a rule"
  done
  br op held D9 --pointer kb/x.md; c_rc 1 "[a] an id with no item: refused"
  br op held D01 --pointer kb/x.md; c_rc 64 "[a] a malformed rule: usage (64)"
  br op held D1 --pointer kb/x.md --session X1; c_rc 1 "[a] --session that is not a session item: refused"
  br op held D1 --pointer kb/x.md --session S9; c_rc 1 "[a] --session with no such item: refused"
  br op supersede T1 --text "never edit the log by hand, nor by a script" --reason wider
  br op held T1 --pointer kb/x.md; c_rc 1 "[a] a superseded rule: refused"
  c_has "$OUT" "T1 is superseded by T2: record against T2" "[a] naming its successor"
  br op close F1 --reason done --pointer kb/x.md
  br op held F1 --pointer kb/x.md; c_rc 1 "[a] a closed rule: refused"; c_has "$OUT" "F1 is not live" "[a] it says so"
  br op broke D1 --pointer kb/x.md --differed "$(tok)"; c_rc 1 "[a] a sensitive value in what differed: refused"
  br op broke D1 --pointer kb/x.md --differed "$(rep d 151)"; c_rc 1 "[a] what differed over 150: refused"
  br op hit D1; c_rc 1 "[a] hit on a decision: refused"; c_has "$OUT" "hit counts traps only" "[a] hit counts traps only"
  br op hit S07; c_rc 64 "[a] hit on a SOUL code: usage (64)"; c_has "$OUT" "hit names a trap, like T5" "[a] it says what hit takes"
  br op held S014 --pointer kb/x.md; c_rc 64 "[a] a three-digit code with a leading zero: usage (64), so S14 has one spelling"
  br op held S120 --pointer kb/x.md; c_rc 0 "[a] a three-digit code: accepted"
  br ledger; c_rc 0 "[a] brain ledger: rc 0"
  c_has "$OUT" "D1 · decision · held 1 from 1 session · broke 0 · last " "[a] brain ledger: one line per rule"
  c_has "$OUT" "[S07] · SOUL · held 2 from 1 session" "[a] a SOUL code's line"
  c_has "$OUT" "T1 · lesson · held 1 from 1 session · broke 1" "[a] a trap with a held is a lesson"
  c_has "$OUT" "superseded by T2" "[a] a retired rule says so"
  br ledger D1; c_rc 0 "[a] brain ledger D1: rc 0"; c_has "$OUT" " held " "[a] its events"; c_has "$OUT" "acme/app¤1" "[a] with their pointers"
  br ledger X1; c_rc 1 "[a] brain ledger of an item that is not a rule: refused"
  np; conf '{"caps": {"T": 1, "F": 1}}'
  br op add --kind trap --text "the first trap"; br op add --kind trap --text "a trap that waits"
  br op add --kind fact --text "the first fact"; br op add --kind fact --text "a fact that waits"
  c_eq "$(status_of T2) $(status_of F2)" "queued queued" "[a] instrument: T2 and F2 wait in the queue"
  br op held T2 --pointer kb/x.md; c_rc 1 "[a] held on a queued trap: refused"
  c_has "$OUT" "T2 waits in the overflow queue" "[a] it says the item waits"
  br op broke F2 --pointer kb/x.md --differed d; c_rc 1 "[a] broke on a queued fact: refused"
  br op hit T2; c_rc 0 "[a] a queued trap may still be hit"
  conf '{}'
}

# --- [b] -----------------------------------------------------------------------------------------------------------------------
case_thresholds() {
  np
  local specs=() k
  for k in D1 D2 D3 D4 D5 D6 T1 T2 T3 T4 T5 F1 F2; do specs+=("$k@$(ago 40)"); done
  seed "${specs[@]}" "X1@$(ago 30)" "X2@$(ago 29)" "G1@$(ago 90)" "W1@$(ago 90)"
  ops held:D1:10:S1 held:D1:8:S2 held:D1:6:S3 held:D1:4:S1 held:D1:3:S2 broke:D1:30:S1 \
      held:D2:10:S1 held:D2:8:S2 held:D2:6:S3 held:D2:3:S1 \
      held:D3:10:S1 held:D3:8:S2 held:D3:6:S1 held:D3:4:S2 held:D3:3:S1 \
      held:D4:9:S1 held:D4:8:S2 held:D4:6:S3 held:D4:4:S1 held:D4:3:S2 \
      held:D5:10:S1 held:D5:8:S2 held:D5:6:S3 held:D5:4:S1 held:D5:3:S2 broke:D5:29:S1 \
      held:D6:2:S1 \
      broke:T1:5:S1 broke:T1:4:S2 \
      held:T2:9:S1 held:T2:8:S1 held:T2:7:S1 held:T2:6:S1 held:T2:5:S1 broke:T2:4:S1 broke:T2:3:S1 \
      held:T3:5:S1 held:T3:4:S2 broke:T3:3:S3 \
      held:T4:6:S1 held:T4:5:S1 held:T4:4:S2 broke:T4:3:S3 \
      '{"op": "touch", "id": "T5", "t": 1}' \
      broke:F1:31:S1 broke:F1:5:S2 \
      broke:F2:29:S1 broke:F2:28:S2
  c_eq "$(cand)" "promote D1 | drift T1 T3 F2 | dormant X1" \
       "[b] the defaults: promote at 5 held, 3 sessions, 7 days, a broke 30 days old; drift at 2 broke from 2 sessions, 1 of 3 checks, a broke 29 days old; dormant at 30 days, goals and windows never"
  conf '{"ledger": {"promote_held": 4}}'; c_has "$(cand)" "promote D1 D2 |" "[b] promote_held 4: 4 held is enough"
  conf '{"ledger": {"promote_sessions": 2}}'; c_has "$(cand)" "promote D1 D3 |" "[b] promote_sessions 2: 2 sessions are enough"
  conf '{"ledger": {"promote_days": 6}}'; c_has "$(cand)" "promote D1 D4 |" "[b] promote_days 6: 6 days are enough"
  conf '{"ledger": {"promote_clean_days": 29}}'; c_has "$(cand)" "promote D1 D5 |" "[b] promote_clean_days 29: a broke 29 days old no longer stops it"
  conf '{"ledger": {"drift_broke": 3}}'; c_has "$(cand)" "| drift T3 |" "[b] drift_broke 3: 2 broke are not enough (T1 and F2 hold 2 checks, too few for the other test)"
  conf '{"ledger": {"drift_sessions": 1}}'; c_has "$(cand)" "| drift T1 T2 T3 F2 |" "[b] drift_sessions 1: 2 broke from one session drift"
  conf '{"ledger": {"drift_checks": 4}}'; c_has "$(cand)" "| drift T1 F2 |" "[b] drift_checks 4: 1 of 3 checks is too few checks"
  conf '{"ledger": {"drift_one_in": 4}}'; c_has "$(cand)" "| drift T1 T2 T3 T4 F2 |" "[b] drift_one_in 4: 1 broke in 4 checks drifts"
  conf '{"ledger": {"drift_days": 32}}'; c_has "$(cand)" "| drift T1 T3 F1 F2 |" "[b] drift_days 32: a broke 31 days old counts"
  conf '{"ledger": {"dormant_days": 29}}'; c_has "$(cand)" "| dormant X1 X2" "[b] dormant_days 29: 29 days untouched is dormant"
  conf '{"ledger": {"promote_held": 0}}'
  br op held D6 --pointer kb/x.md; c_rc 1 "[b] a wrong value refuses writes"
  c_has "$OUT" "ledger.promote_held must be an integer from 1 to 100" "[b] naming the key and its range"
  c_eq "$(cand)" "promote D1 | drift T1 T3 F2 | dormant X1" "[b] a read uses the default"
  conf '{"ledger": 5}'; br op held D6 --pointer kb/x.md; c_rc 1 "[b] ledger that is not an object: refused"
  c_has "$OUT" "ledger must be an object" "[b] it says so"
  conf '{"ledger": {"promote_hold": 4}}'; br doctor; c_has "$OUT" 'unknown key ledger."promote_hold" (ignored)' "[b] an unknown key inside ledger warns"
  br op held D6 --pointer kb/x.md; c_rc 0 "[b] and the write is done"
  conf '{"ledger": {"promote_held": 4}}'; br doctor; c_has "$OUT" "ledger.promote_held 4" "[b] doctor prints a value off its default"
  conf '{}'
}

# --- [e] -----------------------------------------------------------------------------------------------------------------------
case_progress() {
  np
  local before
  goal_args "ship the ledger" "$(dplus 30)"; owner_ok "${GA[@]}"
  before=$(bpy 'print(s.dumps(s.load(s.state_dir())[1]["items"]["G1"]))')
  br ledger; c_has "$OUT" "G1 · goal · no progress yet" "[e] brain ledger lists a live goal with no progress yet"
  br op progress G1 --measure 'x" · the owner retired this goal: "y' --pointer kb/x.md; c_rc 1 "[e] a measure holding a quote: refused"
  c_has "$OUT" "measure holds U+0022" "[e] it says why"
  br op progress G1 --measure "x” · the owner retired this goal" --pointer kb/x.md; c_rc 1 "[e] a measure holding a look-alike quote: refused"
  br op progress G1 --measure "2 of 4 rows merged" --pointer acme/app¤610; c_rc 0 "[e] progress G1: rc 0"
  c_has "$OUT" 'progress G1: "2 of 4 rows merged"' "[e] it says what it recorded"
  c_has "$(lastop)" '"op":"progress"' "[e] one progress op in the log"
  c_eq "$(bpy 'print(s.dumps(s.load(s.state_dir())[1]["items"]["G1"]))')" "$before" "[e] the goal's item is the owner's, byte for byte"
  br ledger; c_has "$OUT" 'G1 · goal · progress "2 of 4 rows merged" (' "[e] brain ledger shows the measure"
  startall compact
  c_has "$(card_of)" "- G1 review in 30 d · no focus · progress \"2 of 4 rows merged\" (" "[e] the card's line of the goal carries the measure"
  br op progress G1 --measure "$(rep m 81)" --pointer kb/x.md; c_rc 1 "[e] a measure over 80: refused"
  br op progress G1 --pointer kb/x.md; c_rc 64 "[e] no measure: usage (64)"
  br op progress G1 --measure "3 of 4"; c_rc 64 "[e] no pointer: usage (64)"
  br op close G1 --reason done; c_rc 1 "[e] brain op still never closes a goal"
  owner_ok unpin G1
  br op progress G1 --measure "3 of 4" --pointer kb/x.md; c_rc 1 "[e] a goal no longer live: refused"
}

# --- [g] -----------------------------------------------------------------------------------------------------------------------
case_card() {
  np
  local card
  goal_args "ship the ledger" "$(dplus 12)"; owner_ok "${GA[@]}"
  seed "G2@$C20;review=$(dplus 40);text=keep the fleet in step"
  br op add --kind focus --text "the gate first" --owner-quote q --where chat --goal G1
  br op progress G1 --measure "2 of 4 rows merged" --pointer acme/app¤610
  br op add --kind session --text "w-a"
  seed "T1@$(ago 40)" "D1@$(ago 40);qlen=5" "X1@$(ago 35)"
  ops broke:T1:3:S1 broke:T1:2:S2 held:D1:20:S1 held:D1:15:S2 held:D1:12:S3 held:D1:10:S1 held:D1:5:S2 \
      'broke:[S07]:60:S1' 'held:[S07]:5:S2'
  startall compact; card=$(card_of)
  c_eq "$(printf '%s\n' "$card" | sed -n '2,6p' | sed -E 's/^- (G[0-9]|dormant|ledger) .*/\1/')" \
       "G1
G2
dormant
ledger" "[g] the ledger lines in order: one line per goal, dormant, the record due, and nothing else"
  c_has "$card" "- G1 review in 12 d · focus P1 · progress \"2 of 4 rows merged\" (" "[g] a goal's line: its review, focus and progress"
  c_has "$card" "- G2 review in 40 d · no focus · no progress yet" "[g] a goal with none of them"
  c_hasnt "$card" "sessions" "[g] no sessions part: counting a goal's sessions is an extension's"
  c_hasnt "$card" "drift" "[g] no drift line, though T1 drifts: reporting a drift is an extension's"
  c_hasnt "$card" "promote?" "[g] no promotion line, though D1 is a candidate"
  c_hasnt "$card" "SOUL to review" "[g] no SOUL line, though [S07] broke within three months"
  c_hasnt "$card" "work with no goal" "[g] no direction-gate line"
  c_has "$card" "- dormant (30 d): X1" "[g] dormant items"
  c_has "$card" "- ledger record due: 60 d since " "[g] the record is due"
  c_eq "$(python3 -c 'import sys; print(len(sys.argv[1].encode("utf-16-le")) // 2 <= 1000)' "$card")" True "[g] ≤ 1,000 units"
  br ledger; c_has "$OUT" "T1 · observation · held 0 from 0 sessions · broke 2 · last " "[g] instrument: T1's line in brain ledger"
  c_has "$OUT" "· drift" "[g] brain ledger still marks a rule in drift"
  c_has "$OUT" "D1 · decision · held 5 from 3 sessions · broke 0 · last " "[g] instrument: D1's line"
  c_has "$OUT" "· promote?" "[g] and a promotion candidate"
  br doctor; c_has "$OUT" "info     review card: G1 review in 12 d · focus P1" "[g] doctor prints the card's lines"
  c_has "$OUT" "info     review card: ledger record due: " "[g] each of them"
  startall startup; c_hasnt "$S1" "Review card" "[g] at startup, no card"
}

# --- [h] -----------------------------------------------------------------------------------------------------------------------
case_record() {
  np
  seed "G1@$(ago 50)" "D1@$(ago 50);qlen=5" "T1@$(ago 50)" "T3@$(ago 50)" "X1@$(ago 45)" "S1@$(ago 20);goal=G1" \
       "S2@$(ago 10);goal=G1" "S3@$(ago 8);no_goal=the owner: a one-off"
  ops held:D1:12:S1 held:D1:6:S2 broke:T1:12:S1 broke:T1:11:S2 held:T3:9:S1 \
      'progress:G1:9:1 of 4' 'progress:G1:2:2 of 4' \
      '{"op": "owner-promote", "id": "T3", "pointer": "[S14]", "soul": "S14", "t": 5}' \
      '{"op": "owner-demote", "soul": "S07", "item": {"id": "D2", "kind": "decision", "pinned": true, "text": "no auto seat", "source": {"type": "owner", "quote": "q", "where": "chat"}, "expires": null, "links": [], "anchors": [], "supersedes": null, "demoted_from": "S07"}, "t": 4}' \
      '{"op": "close", "id": "T1", "reason": "dropped after its drift", "pointer": "chat", "bulk": false, "t": 3}'
  episode_at compact 7 loss=0.42
  br ledger --record; c_rc 0 "[h] brain ledger --record: rc 0"
  c_has "$OUT" "# brain ledger record: proj" "[h] its title names the project"
  c_has "$OUT" "Thresholds: promote 5 held from 3 sessions over 7 d, no broke in 30 d" "[h] the thresholds in force"
  c_has "$OUT" "## Rules" "[h] the rules"; c_has "$OUT" "- D1 · decision · held 2 / 2 from 2 sessions · broke 0 / 0" "[h] each rule's counts, period and all"
  c_has "$OUT" "## Crossings" "[h] what crossed"
  c_has "$OUT" "- drift: T1 on $(ago 11 | cut -c1-10)" "[h] the day a rule entered drift"
  c_has "$OUT" "- moved out by the owner: T3 to [S14] on $(ago 5 | cut -c1-10)" "[h] an item the owner moved out to a pointer"
  c_hasnt "$OUT" "demoted" "[h] an older brain's demotion is no crossing of the ledger here (an extension's record may say it)"
  c_has "$OUT" "- way back: T1 closed on $(ago 3 | cut -c1-10), after its drift" "[h] the way back after a drift"
  c_hasnt "$OUT" "## Direction gate" "[h] no direction-gate section: counting sessions per goal is an extension's"
  c_has "$OUT" "## Goals' progress" "[h] progress"; c_has "$OUT" '- G1: ' "[h] per goal"; c_has "$OUT" '"2 of 4"' "[h] each measure"
  c_has "$OUT" "## Dormant at the end" "[h] dormant items"; c_has "$OUT" "- Next: X1" "[h] per section"
  c_has "$OUT" "## Capacity at the end" "[h] capacity"; c_has "$OUT" "Next 1/30" "[h] live against the cap"
  c_has "$OUT" "## Compactions" "[h] compactions"; c_has "$OUT" "- 1 in the period; loss scores: 0.42" "[h] and their loss scores"
  c_eq "$(tail -n 1 "$(sdir)/episodes.jsonl" | python3 -c 'import json, sys; print(json.loads(sys.stdin.read())["kind"])')" ledger-record "[h] it logs the record"
  c_eq "$(bpy 'import json, os, time, brain_ledger as L; r = json.load(open(os.path.join(s.state_dir(), L.RECORD_FILE))); print(r["days"], abs(time.time() - r["t"]) < 600)')" \
       "30 True" "[h] a 30-day record keeps its time for the card's due line"
  # crossings that come with time, and a candidate promoted within the period
  np; seed "D1@$(ago 60);qlen=5" "T5@$(ago 60)"
  ops held:D1:50:S1 held:D1:48:S2 held:D1:46:S3 held:D1:43:S1 held:D1:40:S2 broke:D1:35:S1 \
      held:T5:20:S1 held:T5:18:S2 held:T5:15:S3 held:T5:12:S1 held:T5:10:S2 \
      '{"op": "owner-promote", "id": "T5", "pointer": "[S15]", "soul": "S15", "t": 5}'
  br ledger --record
  c_has "$OUT" "- promote candidate: D1 on $(ago 5 | cut -c1-10)" "[h] a candidate that appears as a broke leaves the clean days"
  c_has "$OUT" "- promote candidate: T5 on $(ago 10 | cut -c1-10)" "[h] a candidate moved out within the period"
  c_has "$OUT" "- moved out by the owner: T5 to [S15] on $(ago 5 | cut -c1-10)" "[h] and the day it was moved out"
  # no crossing after a rule ends
  np; seed "T1@$(ago 70)"
  ops held:T1:60:S1 held:T1:58:S2 held:T1:56:S3 held:T1:53:S1 held:T1:50:S2 broke:T1:45:S1 \
      '{"op": "close", "id": "T1", "reason": "dropped", "pointer": "chat", "bulk": false, "t": 44}'
  br ledger --record --days 60
  c_eq "$(printf '%s\n' "$OUT" | grep -c -- '- promote candidate: T1 on')" 1 "[h] the candidate while T1 was live, and none after its close"
  c_hasnt "$OUT" "- drift: T1" "[h] no drift after its close either"
  np; seed "T2@$(ago 10)"
  ops broke:T2:3:S1 broke:T2:3:S2 '{"op": "close", "id": "T2", "reason": "dropped", "pointer": "chat", "bulk": false, "t": 3}'
  br ledger --record
  c_has "$OUT" "- drift: T2 on $(ago 3 | cut -c1-10)" "[h] a drift entered in the second of the close still counts"
  c_has "$OUT" "- way back: T2 closed on $(ago 3 | cut -c1-10), after its drift" "[h] and so does its way back"
  # the card's due line
  np; seed "T1@$(ago 40)"; ops held:T1:31:S1
  startall compact; c_has "$(card_of)" "- ledger record due: 31 d since " "[h] due 31 days after the first evidence, no record yet"
  record_at 29
  startall compact; c_hasnt "$(card_of)" "ledger record due" "[h] not due 29 days after the last record"
  local junk
  for junk in '{"t": NaN, "days": 30}' '{"t": Infinity, "days": 30}' "{\"t\": $(python3 -c 'import time; print(time.time() + 86400 * 9)'), \"days\": 30}"; do
    printf '%s\n' "$junk" > "$(sdir)/ledger-record.json"
    startall compact; c_has "$(card_of)" "- ledger record due: 31 d since " "[h] a record time that is not a finite past time is not used (${junk:0:16})"
  done
  printf '{"t": 1%s, "days": 30}\n' "$(rep 0 400)" > "$(sdir)/ledger-record.json"
  br doctor; c_has "$OUT" "info     review card: ledger record due: 31 d since " "[h] an integer past a float's range: doctor runs and the due line falls back"
  startall compact; c_has "$(card_of)" "- ledger record due: 31 d since " "[h] and the card keeps its lines"
  record_at 31; br ledger --record --days 7; c_rc 0 "[h] instrument: a 7-day look"
  c_eq "$(tail -n 1 "$(sdir)/episodes.jsonl" | python3 -c 'import json, sys; o = json.loads(sys.stdin.read()); print(o["kind"], o["days"])')" \
       "ledger-record 7" "[h] a shorter record is logged"
  startall compact; c_has "$(card_of)" "- ledger record due: 31 d since " "[h] and leaves the monthly clock alone"
  record_at 30
  startall compact; c_has "$(card_of)" "- ledger record due: 30 d since " "[h] due 30 days after the last record"
  br ledger --record; episode_at compact 0
  bpy 'import os
for i in range(1200):
    s.episode_line(s.state_dir(), "sA", "session-start", source="startup", pad="p" * 200)'
  startall compact; c_hasnt "$(card_of)" "ledger record due" "[h] a record stays seen after 1,200 more Episode Log lines"
}

# --- [i] -----------------------------------------------------------------------------------------------------------------------
case_compat5() {
  np
  if ! old_brain "$MAIN_REV" old5; then ok "[i] skip: the brain of log format 5 ($MAIN_REV) is not in this clone's history"; return; fi
  local NEW=$BROOT d old_fold R i specs=() n a b
  BROOT="$OLD/plugins/vibemaestro-brain"           # every write below by the brain of log format 5
  c_eq "$(bpy 'print(s.FORMAT)')" 5 "[i] instrument: the old brain writes log format 5"
  conf '{"caps": {"X": 1}}'
  br op add --kind now --text "fix the parser" --anchor acme/app¤11
  br op add --kind next --text "the first next step"; br op add --kind next --text "queued one"; br op add --kind next --text "queued two"
  br op add --kind trap --text "never edit the log by hand"; br op hit T1
  br op add --kind session --text "w-auth: review round 2" --link kb/x.md
  br op add --kind queue --text "owner: approve the budget"; br op add --kind fact --text "kit CLI: on PATH"
  goal_args "ship the layers" "$(dplus 30)"; owner_ok "${GA[@]}"
  br op add --kind focus --text "capacity first" --owner-quote q --where chat --goal G1
  br op add --kind request --text "a request" --owner-quote "the owner's \"words\"" --where chat --due "$(dplus 3)"
  br op supersede X2 --text "queued one, reworded" --reason clearer
  br op close R1 --reason answered --pointer acme/app¤12
  br op touch N1
  owner_ok add --kind decision --text "ship after the gate" --owner-quote "chờ gate rồi hãy ship" --where chat
  owner_ok supersede D1 --text "ship after the gate and the record"
  owner_ok add --kind decision --text "no auto seat" --owner-quote q --where chat
  owner_ok add --kind window --text "merge docs-only" --owner-quote q --where w --expires 2099-01-01T00:00:00Z
  owner_ok promote W1 CLAUDE.md
  owner_ok unpin D3
  br render >/dev/null
  c_eq "$(python3 -c 'import json, sys; print(sorted({json.loads(l)["op"] for l in open(sys.argv[1])}))' "$(sdir)/hot.jsonl")" \
       "['add', 'claim', 'close', 'hit', 'overflow-add', 'owner-add', 'owner-promote', 'owner-supersede', 'owner-unpin', 'supersede', 'touch']" \
       "[i] instrument: the old log holds every op kind"
  old_fold=$(bpy 'print(s.dumps(s.fold(s.verify(s.state_dir())[1])))')
  BROOT=$NEW                                       # the brain of this tree from here on
  c_eq "$(bpy 'print(s.dumps(s.fold(s.verify(s.state_dir())[1])))')" "$old_fold" "[i] the new store folds the format-5 log to the same bytes"
  c_eq "$(bpy 'd = s.state_dir(); print(s.cache_state(d, s.head_of(s.verify(d)[0])) is not None)')" True "[i] its hot.json cache is used as it is"
  c_eq "$(bpy 'print(" ".join(sorted(s.load(s.state_dir())[1]["items"])))')" "D1 D2 D3 F1 G1 N1 P1 Q1 R1 S1 T1 W1 X1 X2 X3 X4" "[i] every item keeps its id"
  br doctor; c_has "$OUT" "ok       hot.md matches a fresh render" "[i] its hot.md matches a fresh render"
  c_has "$(bpy 'print(s.render_all(s.load(s.state_dir())[1]))')" "- S1 w-auth: review round 2 · since " "[i] its session line has no goal tag"
  br ledger; c_eq "$OUT" "G1 · goal · no progress yet" "[i] its ledger holds no evidence: only its live goal's line"
  c_eq "$(bpy 'print(s.load(s.state_dir())[1]["items"]["T1"]["hits"])')" 1 "[i] a trap's hits from before stay"
  br op held T1 --pointer kb/a.md; c_rc 0 "[i] a held works on it"
  br op add --kind session --text "w-b: the brief"; c_rc 0 "[i] a session add works on it"
  d=$(sdir); cp "$d/hot.jsonl" "$TMP/compat5.jsonl"
  python3 - "$d/hot.jsonl" <<'PY'
import sys
p = sys.argv[1]; b = open(p, "rb").read()
assert b.count(b"fix the parser") == 1
open(p, "wb").write(b.replace(b"fix the parser", b"fox the parser"))
PY
  br op held T1 --pointer kb/b.md; c_rc 5 "[i] a changed byte in the log stops every write (rc 5)"
  cp "$TMP/compat5.jsonl" "$d/hot.jsonl"
  BROOT="$OLD/plugins/vibemaestro-brain"
  R=$(bpy 'try:
    s.fold(s.verify(s.state_dir())[1]); print("folded")
except s.Refused as e:
    print(e.rc)')
  BROOT=$NEW
  c_eq "$R" 5 "[i] the brain of log format 5 refuses a log with an evidence op (rc 5)"
  conf '{}'
  # full sessions, each carrying the goal field an older brain wrote, and the card full: every string within its cap
  np
  for i in $(seq 1 20); do specs+=("S$i@$C20;len=600;links=8;goal=G999999"); done
  seed "${specs[@]}"
  startall compact; read -r n a b <<<"$(strings_check)"
  c_eq "$([ "$a" -le 9500 ] && echo within) $b" "within 0" "[i] twenty full sessions with an older brain's goal field: every string ≤ 9,500 units, no hard cut ($a)"
  c_hasnt "$ALL" "· goal G999999" "[i] the session lines show no goal tag"
  R=$(printf '%s\n' "$ALL" | python3 -c 'import re, sys
ls = [l for l in sys.stdin.read().splitlines() if re.match(r"- S[0-9]+ ", l)]
print(len(ls), max(len(re.sub(r" · stale: .*", "", l).encode("utf-16-le")) // 2 for l in ls) <= 660)')
  c_eq "$R" "20 True" "[i] each session line within its cap of 660 units"
  c_eq "$(bpy 'n, top = s.worst_case(); print(n <= 12, top <= s.STRING_MAX)')" "True True" "[i] the worst case at the defaults: at most 12 strings"
}

# --- [j] -----------------------------------------------------------------------------------------------------------------------
case_compat627() {
  np
  if ! old_brain "$REV627" old627; then ok "[j] skip: the brain of the gate and the ladder ($REV627) is not in this clone's history"; return; fi
  local R NEW=$BROOT
  BROOT="$OLD/plugins/vibemaestro-brain"           # the log below is written by that brain's own commands
  c_eq "$(bpy 'print(s.FORMAT, hasattr(s, "PROMOTED"))')" "6 True" "[j] instrument: the old brain writes log format 6, with the ladder"
  goal_args "ship the ledger" "$(dplus 30)"; owner_ok "${GA[@]}"
  conf '{"caps": {"T": 2}}'
  br op add --kind trap --text "never edit the log by hand"; br op add --kind trap --text "check the base before a rebase"
  br op add --kind trap --text "a lesson that waits"
  c_eq "$(status_of T3)" queued "[j] instrument: T3 waits in the queue"
  owner_ok add --kind decision --text "ship after the gate" --owner-quote "the owner's words" --where chat
  owner_ok add --kind decision --text "no auto seat" --owner-quote "the owner's words" --where chat
  br op add --kind session --text "w-a: the brief" --goal G1; br op add --kind session --text "w-b: a one-off fix" --no-goal "the owner: a one-off"
  br op supersede S1 --text "w-a: review round 1" --reason status
  br op add --kind session --text "$(rep w 585)" --no-goal "the owner: a long one" --link "$(rep a 20)" --link "$(rep b 20)"
  br op held T1 --pointer kb/a.md --session S1; br op held T1 --pointer kb/b.md --session S2; br op hit T1
  br op held S07 --pointer CLAUDE.md --session S1; br op progress G1 --measure "2 of 4" --pointer kb/p.md
  owner_ok promote T1 "[S14]"; c_rc 0 "[j] instrument: the old brain promotes a lesson to a code"
  owner_ok promote D2 "CLAUDE.md [S15]"
  owner_ok demote S07 --text "no auto seat, narrowed" --owner-quote "the owner's words" --where chat; c_rc 0 "[j] instrument: and demotes a code"
  br op held S14 --pointer kb/evidence.md --session S3
  br render >/dev/null
  conf '{}'
  c_eq "$(python3 -c 'import json, sys; print(sorted({json.loads(l)["op"] for l in open(sys.argv[1])} & {"evidence", "progress", "owner-demote", "owner-promote"}))' "$(sdir)/hot.jsonl")" \
       "['evidence', 'owner-demote', 'owner-promote', 'progress']" "[j] instrument: the old log holds the gate's and the ladder's ops"
  c_has "$(cat "$(sdir)/hot.md")" "· goal G1 · since " "[j] instrument: its hot.md tags a session with its goal"
  BROOT=$NEW                                       # this tree's brain from here on, with no extension
  R=$(bpy 'st = s.fold(s.verify(s.state_dir())[1]); i = st["items"]
print(i["T1"]["status"], i["T1"]["soul"], i["T3"]["status"], i["D2"]["status"], i["D3"]["status"], i["D3"]["demoted_from"], i["S3"]["goal"], i["S2"]["no_goal"], i["T1"]["hits"])')
  c_eq "$R" "archived S14 live archived live S07 G1 the owner: a one-off 1" \
       "[j] the log verifies and folds: a lesson and a decision promoted with a code, the queue moved up, the demotion's decision, the sessions' fields, a hit"
  br doctor; c_rc 0 "[j] brain doctor: rc 0"; c_hasnt "$OUT" "problem" "[j] and no problem"
  c_has "$OUT" "ok       hot.jsonl: " "[j] the chain and head.json agree"
  c_has "$OUT" "warn     hot.md holds an older brain's render" "[j] its hot.md, with the older session tags, is an older render, not an edit (a line near its cap, with links, included)"
  br render --check; c_rc 0 "[j] every string fits its cap"
  startall compact
  c_has "$ALL" "- S3 w-a: review round 1 · since " "[j] a session with a goal renders, with no tag"
  c_has "$ALL" "- S2 w-b: a one-off fix · since " "[j] a session with the owner's reason for none, with no tag"
  c_hasnt "$ALL" "goal G1 ·" "[j] no session line names a goal"; c_hasnt "$ALL" "no goal ·" "[j] nor its absence"
  c_has "$ALL" "- D3 no auto seat, narrowed · since " "[j] the demotion's decision renders in the left brain"
  c_has "$ALL" "- T3 a lesson that waits" "[j] the lesson the queue moved up is live"
  c_has "$(card_of)" "- G1 review in 30 d · no focus · progress \"2 of 4\" (" "[j] the card reads the goal's progress"
  c_hasnt "$(card_of)" "SOUL" "[j] the card names no SOUL code"
  br ledger; c_rc 0 "[j] brain ledger: rc 0"
  c_has "$OUT" "T1 · lesson · held 3 from 3 sessions · broke 0 · last " "[j] the promoted lesson keeps its own events (the hit counts for the writing session)"
  c_has "$OUT" " · archived" "[j] and says it is archived"
  c_has "$OUT" "[S14] · SOUL · held 1 from 1 session · broke 0" "[j] a code counts the events written for it, no more"
  c_has "$OUT" "[S07] · SOUL · held 1 from 1 session" "[j] a code an older brain demoted still reads"
  br ledger S14; c_rc 0 "[j] brain ledger S14: rc 0"; c_has "$OUT" "kb/evidence.md" "[j] with its event"
  br show T1; c_has "$OUT" "soul: S14" "[j] brain show prints the code an older brain stored"
  br show D3; c_has "$OUT" "demoted_from: S07" "[j] and where a demoted decision came from"
  br show S3; c_has "$OUT" "goal: G1" "[j] and a session's goal field"; c_has "$OUT" "source: session" "[j] the session's source, in the solo word"
  br op add --kind session --text "w-c: the next brief"; c_rc 0 "[j] a new write chains on"
  br op held D1 --pointer kb/z.md --session S3; c_rc 0 "[j] and a held counts the session by its chain"
  br doctor; c_hasnt "$OUT" "problem" "[j] the chain still agrees"
  br op add --kind session --text "w-d" --no-goal "why"; c_rc 64 "[j] --no-goal is gone with the gate (usage)"
  br op add --kind session --text "w-d" --goal G1; c_rc 64 "[j] --goal names a focus's goal only (usage)"
  br op supersede S3 --text "w-a: review round 2" --reason status --goal G1; c_rc 64 "[j] --goal on a supersede is gone (usage)"
  br owner demote S14 --text "never edit the log by hand" --owner-quote q --where chat; c_rc 64 "[j] brain owner demote is gone (usage)"
  gown demote S14 --text "never edit the log by hand" --owner-quote q --where chat
  c_eq "$(hfield permissionDecision)" deny "[j] guard-owner denies it before asking"
  br ledger T2 --card; c_rc 64 "[j] the 7-line card is gone (usage)"
  owner_ok promote T2 "[S16]"; c_rc 1 "[j] the owner's promote takes a goal, decision or window, not a lesson"
  c_has "$OUT" "T2 is not an owner item" "[j] it says why"
  owner_ok promote D1 "CLAUDE.md [S16]"; c_rc 0 "[j] a decision moved out to a pointer, as in the first public release"
  c_hasnt "$(lastop)" '"soul"' "[j] its pointer is only a pointer: no code is read from it"
  br op supersede S2 --text "w-b: the next one-off fix" --reason status; c_rc 0 "[j] a session with the owner's reason for no goal superseded"
  c_has "$(lastop)" '"no_goal":"the owner: a one-off"' "[j] keeps that reason, for a plugin that reads it"
}

echo "== cases =="
for c in case_evidence case_thresholds case_progress case_card case_record case_compat5 case_compat627; do run_case $c; done
cd "$TMP" || exit 1
summary
