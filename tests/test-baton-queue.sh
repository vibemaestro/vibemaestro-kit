#!/bin/bash
# =============================================================================
# BatonRun: the owner's queue (baton.py go --queue, log --queue, sign --by owner --queued, run --queued, log --wait-queued)
# =============================================================================
# Run: bash tests/test-baton-queue.sh
#
# A session queues a sealed run that needs the owner and goes on working; the owner signs it later in their own session, through
# the same guard and dialog as `sign --by owner --seal`; the session runs it once, within 24 h, if the plan still matches. Each
# family runs on a copy of the real plugin (its baton isolated from the machine: baton_isolate), then again on copies with one
# planted break, and must go red on the intended check. No network, nothing outside the scratch tree.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
# shellcheck source=fixtures/ports.sh
. "$HERE/fixtures/ports.sh"
# shellcheck source=fixtures/baton-owner.sh
. "$HERE/fixtures/baton-owner.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
export PYTHONDONTWRITEBYTECODE=1
H0=$(tree_hash "$SRC_ROOT")
BT_OUT="$TMP/bt.out"; ST=""; BT_ENV=(); ID=""

# bt <plugin> <dir> <session> <baton args...> — rc of baton from <dir> as <session> (plus BT_ENV); output in $BT_OUT. No guard.
bt() {
  local p=$1 d=$2 ses=$3; shift 3
  [ "${1:-}" = mode ] && [ $# -gt 1 ] && mode_asked "$p" "$d" "$ST" "$ses" "${@:2}" >/dev/null
  ( cd "$d" && cenv XDG_STATE_HOME="$ST" CLAUDE_CODE_SESSION_ID="$ses" ${BT_ENV[@]+"${BT_ENV[@]}"} python3 "$p/scripts/baton.py" "$@" ) \
    > "$BT_OUT" 2>&1; echo $?
}
# setup — a fresh state and directory W holding act.sh (a positional baton, Stops none: in mode manual it needs the owner)
setup() { ST="$(fresh)/state"; W=$(fresh); BT_ENV=(); cp "$SRC_ROOT/tests/fixtures/baton-positional.sh" "$W/act.sh"; }
QDIR() { printf '%s' "$ST/vibemaestro/baton/queue"; }
item() { printf '%s' "$(QDIR)/$ID.json"; }
items_n() { find "$(QDIR)" -maxdepth 1 -name '*.json' 2>/dev/null | grep -c .; }
asked_n() { find "$ST/vibemaestro/baton/asked" -name '*.json' 2>/dev/null | grep -c .; }
# queue <plugin> [session] — go --queue act.sh out.txt hello as the coordinating session: its rc in QRC, ID the item the line names
queue() {
  QRC=$(bt "$1" "$W" "${2-s-coord}" go --queue act.sh "$W/out.txt" hello)
  ID=$(sed -n 's/^go: queued \([0-9a-f]\{16\}\) .*/\1/p' "$BT_OUT")
}
owner_cmd() { printf 'python3 %s/scripts/baton.py sign --by owner --queued %s' "$1" "$ID"; }
# ask <plugin> [session] [extra JSON] — the guard on the owner's literal command, as Claude Code runs it; prints the decision
ask() {
  local pl
  pl=$(python3 -c 'import json, sys
d = {"session_id": sys.argv[1], "permission_mode": "default", "cwd": sys.argv[2], "hook_event_name": "PreToolUse",
     "tool_name": "Bash", "tool_input": {"command": sys.argv[3]}}
d.update(json.loads(sys.argv[4]))
print(json.dumps(d))' "${2:-s-owner}" "$OWD" "${ASKCMD:-$(owner_cmd "$1")}" "${3:-{\}}")
  printf '%s' "$pl" | ( cd "$OWD" && cenv XDG_STATE_HOME="$ST" ${BT_ENV[@]+"${BT_ENV[@]}"} python3 "$1/scripts/baton-guard.py" ) 2>"$TMP/guard.err" \
    | python3 -c 'import json, sys
t = sys.stdin.read().strip()
o = json.loads(t)["hookSpecificOutput"] if t else {}
open(sys.argv[1], "w").write(o.get("permissionDecisionReason", ""))
print(o.get("permissionDecision", "none"))' "$TMP/guard.reason"
}
# osign <plugin> [session] — the owner's sign, from the owner's own directory OWD
osign() { bt "$1" "$OWD" "${2:-s-owner}" sign --by owner --queued "$ID"; }
qrun() { bt "$1" "$W" s-coord run --queued "$ID"; }
# age <file> <seconds> [resign] — time passing for an item: created and expires moved back, its body hash computed again as
# baton computes it (and, with resign, the signature's copy too): the item stays intact, only older
age() {
  python3 - "$@" <<'PY'
import calendar, hashlib, json, sys, time
p, sec = sys.argv[1], int(sys.argv[2])
it = json.load(open(p))
f = lambda v: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(calendar.timegm(time.strptime(v, "%Y-%m-%dT%H:%M:%SZ")) - sec))
it["created"], it["expires"] = f(it["created"]), f(it["expires"])
body = {k: v for k, v in it.items() if k not in ("body_sha256", "signature")}
it["body_sha256"] = hashlib.sha256(json.dumps(body, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
if len(sys.argv) > 3 and "signature" in it:
    it["signature"]["body_sha256"] = it["body_sha256"]
open(p, "w").write(json.dumps(it))
PY
}
# expire_in <file> <seconds> — the item expires that many seconds from now, its hashes (body, signature) computed again: an item
# signed near the end of its 24 h
expire_in() {
  python3 - "$@" <<'PY'
import hashlib, json, sys, time
p, sec = sys.argv[1], int(sys.argv[2])
it = json.load(open(p))
it["expires"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + sec))
body = {k: v for k, v in it.items() if k not in ("body_sha256", "signature")}
it["body_sha256"] = hashlib.sha256(json.dumps(body, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
if "signature" in it:
    it["signature"]["body_sha256"] = it["body_sha256"]
open(p, "w").write(json.dumps(it))
PY
}
# poke <file> <python expr on it> [rehash] — change an item's bytes (a forgery); with rehash the body hash is computed again
poke() {
  python3 - "$@" <<'PY'
import hashlib, json, sys
p, expr = sys.argv[1], sys.argv[2]
it = json.load(open(p))
exec(expr)
if len(sys.argv) > 3:
    body = {k: v for k, v in it.items() if k not in ("body_sha256", "signature")}
    it["body_sha256"] = hashlib.sha256(json.dumps(body, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
open(p, "w").write(json.dumps(it))
PY
}
# plant_record <plugin> <session> [claude JSON] — an asked record for the owner's command as if a guard had written it (the guard
# refuses to, for the session that queued): proves the sign's own check, not only the guard's
plant_record() {
  ( cd "$OWD" && cenv XDG_STATE_HOME="$ST" python3 -c 'import json, os, sys
sys.path.insert(0, sys.argv[1] + "/scripts")
import baton
it = json.load(open(sys.argv[3]))
baton.record_asked(sys.argv[2], "default", ["--by", "owner", "--queued", it["id"]], os.path.realpath(os.getcwd()),
                   json.loads(sys.argv[4]), None, queued=[it["id"], it["body_sha256"]])' "$1" "$2" "$(item)" "${3:-null}" )
}

fam_queue_flow() {  # [Q] queue, list, the owner's dialog and sign in their own session, wait, run once
  local P=$1 keys out
  setup; OWD=$(fresh)
  queue "$P"
  eq "$QRC/$(wc -l < "$BT_OUT" | tr -d ' ')" "0/1" "[Q] go --queue on a baton that needs the owner: rc 0, one line"
  nonempty "$ID" "[Q] …the line names the item id"
  has "$(cat "$BT_OUT")" "run --queued $ID" "[Q] …and the run that follows the signature"
  eq "$([ -e "$W/out.txt" ] && echo ran || echo none)" none "[Q] …nothing ran"
  eq "$(stat -c %a "$(item)" 2>/dev/null)/$(stat -c %a "$(QDIR)" 2>/dev/null)" "600/700" "[Q] the item is private (0600 in 0700)"
  keys=$(pkeys "$(cat "$(item)" 2>/dev/null || echo '{}')")
  for k in args binding body_sha256 card claude created cwd env expires id plan plan_sha256 script_path script_sha256 seal session stops; do
    has " $keys " " $k " "[Q] the item holds $k"
  done
  eq "$(python3 -c 'import calendar, json, sys, time
it = json.load(open(sys.argv[1])); t = lambda v: calendar.timegm(time.strptime(v, "%Y-%m-%dT%H:%M:%SZ"))
print(t(it["expires"]) - t(it["created"]))' "$(item)" 2>/dev/null)" 86400 "[Q] it expires 24 h after it was queued"
  out=$(python3 -c 'import json, sys; print("\n".join(json.load(open(sys.argv[1]))["card"]))' "$(item)" 2>/dev/null)
  for k in What Why Blast Undo Stop Checked; do has "$out" "  $k:" "[Q] the card holds $k"; done
  eq "$(bt "$P" "$W" s-coord log --queue)" 0 "[Q] log --queue rc 0"
  out=$(cat "$BT_OUT")
  has "$out" "$ID  pending" "[Q] …the item is pending"
  has "$out" "Why:      example act" "[Q] …with its card"
  has "$out" "sign --by owner --queued $ID" "[Q] …and the owner's command"
  has "$out" "Args:     $W/out.txt hello" "[Q] log --queue: …the words the script runs with"
  has "$out" "Dir:      $W" "[Q] log --queue: …the directory"
  has "$out" "detail: $ST/vibemaestro/baton/runs/" "[Q] log --queue: …the check and rehearse output"
  eq "$(osign "$P")" 3 "[Q] the owner's session without the dialog's record: sign rc 3"
  eq "$(ask "$P")/$(asked_n)" "ask/1" "[Q] the owner's command in the owner's session: the guard asks, one record"
  has "$(cat "$TMP/guard.reason")" "Why:      example act" "[Q] …the dialog shows the card"
  has "$(cat "$TMP/guard.reason")" "Args:     $W/out.txt hello" "[Q] …and the words the script runs with"
  has "$(cat "$TMP/guard.reason")" "Dir:      $W" "[Q] …and the directory"
  hasnt "$(cat "$TMP/guard.reason")" "nothing ran" "[Q] …not the card's heading"
  eq "$(osign "$P")/$(asked_n)" "0/0" "[Q] the owner clicked: sign rc 0, the record used up"
  has "$(cat "$BT_OUT")" "signed queued $ID" "[Q] …one line names the item"
  eq "$(python3 -c 'import json, sys; s = json.load(open(sys.argv[1]))["signature"]; print(s["by"], bool(s["dialog"]))' "$(item)" 2>/dev/null)" "owner True" \
     "[Q] the signature is in the item, with the dialog's id"
  bt "$P" "$W" s-coord log --queue >/dev/null
  has "$(cat "$BT_OUT")" "$ID  signed" "[Q] log --queue: signed"
  has "$(cat "$ST/vibemaestro/baton/log.tsv")" "	queue	act.sh	" "[Q] log.tsv holds queue lines"
  has "$(grep -F "	queue	" "$ST/vibemaestro/baton/log.tsv")" "	signed	" "[Q] …one of them says signed"
  eq "$(bt "$P" "$W" s-coord log --wait-queued "$ID" --timeout 1)" 0 "[Q] log --wait-queued on a signed item: rc 0"
  eq "$(qrun "$P")/$(cat "$W/out.txt" 2>/dev/null)" "0/hello" "[Q] run --queued: rc 0, the act done"
  eq "$(items_n)/$(find "$(QDIR)/used" -name "$ID.json" | grep -c .)" "0/1" "[Q] the item moved to used/"
  eq "$(qrun "$P")" 3 "[Q] run --queued a second time: rc 3"
  has "$(cat "$BT_OUT")" "was used already" "[Q] …it says the item was used"
  bt "$P" "$W" s-coord log --queue >/dev/null
  has "$(cat "$BT_OUT")" "$ID  used" "[Q] log --queue: used"
  eq "$(bt "$P" "$W" s-coord log --wait-queued "$ID" --timeout 1)" 3 "[Q] log --wait-queued on a used item: rc 3"
}

fam_queue_refusals() {  # [R] unsigned, expired, a changed plan or script, another directory: refused, nothing ran
  local P=$1 W2
  setup; OWD=$(fresh)
  queue "$P"
  eq "$(qrun "$P")/$([ -e "$W/out.txt" ] && echo ran || echo none)" "3/none" "[R] an unsigned item: run --queued rc 3, nothing ran"
  has "$(cat "$BT_OUT")" "not signed" "[R] …it says not signed"
  eq "$(bt "$P" "$W" s-coord log --wait-queued "$ID" --timeout 1)" 9 "[R] log --wait-queued on an unsigned item: rc 9 at the deadline"
  eq "$(bt "$P" "$W" s-coord log --wait-queued 0123456789abcdef --timeout 1)" 3 "[R] log --wait-queued on no such item: rc 3"
  age "$(item)" 86401
  eq "$(ask "$P")/$(asked_n)" "deny/0" "[R] an expired item: the guard denies, no record"
  bt "$P" "$W" s-coord log --queue >/dev/null
  has "$(cat "$BT_OUT")" "$ID  expired" "[R] log --queue: expired"
  eq "$(bt "$P" "$W" s-coord log --wait-queued "$ID" --timeout 1)" 3 "[R] log --wait-queued on an expired item: rc 3"
  plant_record "$P" s-owner
  eq "$(osign "$P")/$(python3 -c 'import json, sys; print("signature" in json.load(open(sys.argv[1])))' "$(item)")" "3/False" \
     "[R] an expired item with a dialog record: sign rc 3, unsigned"
  setup; OWD=$(fresh); queue "$P"; ask "$P" >/dev/null; osign "$P" >/dev/null
  age "$(item)" 86401 resign
  eq "$(qrun "$P")/$([ -e "$W/out.txt" ] && echo ran || echo none)" "3/none" "[R] a signed item past its 24 h: run --queued rc 3, nothing ran"
  has "$(cat "$BT_OUT")" "expired" "[R] …it says expired"
  setup; OWD=$(fresh)
  mutate "$W/act.sh" $'act() {\n  if holds_text' $'act() {\n  if [ -e "$PWD/slow" ]; then sleep 4; fi\n  if holds_text' || return
  queue "$P"; ask "$P" >/dev/null; osign "$P" >/dev/null
  : > "$W/slow"; expire_in "$(item)" 2
  eq "$(qrun "$P")/$([ -e "$W/out.txt" ] && echo ran || echo none)" "3/none" "[R] an item that expires during the run's own rehearse: rc 3, nothing ran"
  has "$(cat "$BT_OUT")" "expired" "[R] …it says expired"
  setup; OWD=$(fresh); queue "$P"; ask "$P" >/dev/null; osign "$P" >/dev/null
  printf 'hello\n' > "$W/out.txt"
  eq "$(qrun "$P")" 3 "[R] the world moved after signing (its rehearse now fails): run --queued rc 3"
  has "$(cat "$BT_OUT")" "rehearse before the run failed" "[R] …it says the rehearse failed"
  eq "$(items_n)" 1 "[R] …and the item is still unused"
  # a plan line that carries a value read from the world (the act's source text): the same script, arguments and directory,
  # another plan
  setup; OWD=$(fresh); printf 'v1\n' > "$W/src"
  mutate "$W/act.sh" '  write "create $DEST" put_text' '  write "create $DEST from $(cat "$PWD/src")" put_text' || return
  queue "$P"; ask "$P" >/dev/null; osign "$P" >/dev/null
  printf 'v2\n' > "$W/src"
  eq "$(qrun "$P")/$([ -e "$W/out.txt" ] && echo ran || echo none)" "3/none" "[R] the plan changed after signing: run --queued rc 3, nothing ran"
  has "$(cat "$BT_OUT")" "plan changed" "[R] …it says the plan changed"
  eq "$(items_n)" 1 "[R] …and the item is still unused"
  setup; OWD=$(fresh); queue "$P"; ask "$P" >/dev/null; osign "$P" >/dev/null
  printf '# one more line\n' >> "$W/act.sh"
  eq "$(qrun "$P")/$([ -e "$W/out.txt" ] && echo ran || echo none)" "3/none" "[R] the script changed after signing: run --queued rc 3, nothing ran"
  setup; OWD=$(fresh); queue "$P"; ask "$P" >/dev/null; osign "$P" >/dev/null
  W2=$(fresh)
  eq "$(bt "$P" "$W2" s-coord run --queued "$ID")/$([ -e "$W/out.txt" ] && echo ran || echo none)" "3/none" "[R] run --queued from another directory: rc 3"
  has "$(cat "$BT_OUT")" "was queued in $W" "[R] …it says where it was queued"
  eq "$(bt "$P" "$W" s-coord run --queued nothex)" 64 "[R] run --queued with a malformed id: rc 64"
}

fam_queue_coordinator() {  # [C] the session that queued never signs: no record, its own record, after /clear
  local P=$1 L pl
  setup; OWD=$(fresh)
  queue "$P"
  eq "$(osign "$P" s-coord)" 3 "[C] the coordinator's own session signs without a dialog record: rc 3"
  has "$(cat "$BT_OUT")" "no fresh record of the owner's dialog" "[C] …the refusal names the missing dialog"
  eq "$(ask "$P" s-coord)/$(asked_n)" "deny/0" "[C] the coordinator's own session asks: the guard denies, no dialog, no record"
  has "$(cat "$TMP/guard.reason")" "queued" "[C] …the guard names the session that queued it"
  plant_record "$P" s-coord
  eq "$(osign "$P" s-coord)/$(python3 -c 'import json, sys; print("signature" in json.load(open(sys.argv[1])))' "$(item)")" "3/False" \
     "[C] a dialog record in the coordinator's own session: sign rc 3, the item unsigned"
  has "$(cat "$BT_OUT")" "queued" "[C] …the sign names the session that queued it"
  eq "$(bt "$P" "$W" s-coord sign --by coordinator-auto --queued "$ID")" 64 "[C] sign --by coordinator-auto --queued: rc 64"
  # /clear: a new session id in the same Claude Code process. A stand-in whose pid is the CLAUDE_PID its children read, as Claude
  # Code's is, queues as session s-A and asks and signs as s-B.
  L="$P.lineage"; rm -rf "$L"; cp -r "$P" "$L"; mutate "$L/scripts/baton.py" 'LINEAGE = False ' 'LINEAGE = True ' || return
  setup; OWD=$W
  cat > "$W/claude-standin.sh" <<'SH'
q() { CLAUDE_PID=$$ CLAUDE_CODE_SESSION_ID=s-A python3 "$L/scripts/baton.py" go --queue act.sh "$W/out.txt" hello; }
id() { grep -L '/d2"' "$XDG_STATE_HOME"/vibemaestro/baton/queue/*.json | sed -n 's|.*/\([0-9a-f]*\)\.json$|\1|p' | head -1; }   # not the setsid one
ask() { printf '{"session_id":"s-B","permission_mode":"default","cwd":"%s","tool_name":"Bash","tool_input":{"command":"python3 %s/scripts/baton.py sign --by owner --queued %s"}}' "$W" "$L" "$(id)" \
        | CLAUDE_PID=$$ python3 "$L/scripts/baton-guard.py" | python3 -c 'import json,sys; t=sys.stdin.read().strip(); print(json.loads(t)["hookSpecificOutput"]["permissionDecision"] if t else "none")'; }
plant() { python3 -c 'import json, os, sys
sys.path.insert(0, sys.argv[1] + "/scripts")
import baton
lin = baton.lineage(); ci = baton.claude_index(lin, sys.argv[3])
it = json.load(open(sys.argv[2]))
baton.record_asked("s-B", "default", ["--by", "owner", "--queued", it["id"]], os.path.realpath(os.getcwd()),
                   [lin[ci][0], lin[ci][2]], lin[0][2] - 5, queued=[it["id"], it["body_sha256"]])' "$L" "$XDG_STATE_HOME/vibemaestro/baton/queue/$(id).json" $$; }
sign() { CLAUDE_PID=$$ CLAUDE_CODE_SESSION_ID=s-B python3 "$L/scripts/baton.py" sign --by owner --queued "$(id)"; echo "rc=$?"; }
q >/dev/null 2>&1
echo "items=$(ls "$XDG_STATE_HOME/vibemaestro/baton/queue" | grep -c '\.json$')"
mkdir "$W/d2"; cp act.sh "$W/d2/act.sh"
( cd "$W/d2" && CLAUDE_PID=$$ CLAUDE_CODE_SESSION_ID=s-A setsid -f python3 "$L/scripts/baton.py" go --queue act.sh "$W/d2/out.txt" hello >/dev/null 2>&1 )
for _ in $(seq 100); do [ "$(ls "$XDG_STATE_HOME/vibemaestro/baton/queue" | grep -c '\.json$')" -ge 2 ] && break; sleep 0.1; done
echo "setsid-claude=$(cat "$XDG_STATE_HOME"/vibemaestro/baton/queue/*.json | python3 -c 'import json, sys
d = json.JSONDecoder(); t = sys.stdin.read(); i = 0; out = []
while i < len(t):
    t2 = t[i:].lstrip()
    if not t2: break
    o, n = d.raw_decode(t2); i = len(t) - len(t2) + n; out.append(o)
print(",".join(sorted(str((o.get("claude") or [None])[0]) for o in out if o.get("cwd", "").endswith("/d2"))))')"
echo "standin=$$"
echo "ask=$(ask)"
echo "asked=$(ls "$XDG_STATE_HOME/vibemaestro/baton/asked" 2>/dev/null | grep -c .)"
plant; sign
SH
  # one stand-in process for the three steps: queue as s-A, then ask and sign as s-B
  out=$(cd "$W" && cenv XDG_STATE_HOME="$ST" W="$W" L="$L" bash "$W/claude-standin.sh" 2>&1)
  has "$out" "items=1" "[C] /clear: the stand-in queued one item as session s-A"
  eq "$(printf '%s\n' "$out" | sed -n 's/^setsid-claude=//p')" "$(printf '%s\n' "$out" | sed -n 's/^standin=//p')" \
     "[C] go --queue under setsid (not a descendant of Claude Code): the item names the CLAUDE_PID process"
  has "$out" "ask=deny" "[C] /clear: the same Claude Code process as session s-B asks: the guard denies"
  has "$out" "asked=0" "[C] /clear: …and writes no record"
  has "$out" "rc=3" "[C] /clear: a record for s-B in the same Claude Code process: sign rc 3"
  has "$out" "Claude Code process that queued" "[C] /clear: …the refusal names the process that queued it"
  rm -rf "$L"
}

fam_queue_forgery() {  # [F] bytes changed after signing, or between the dialog and the click
  local P=$1
  setup; OWD=$(fresh); queue "$P"; ask "$P" >/dev/null; osign "$P" >/dev/null
  poke "$(item)" 'it["expires"] = "2099-01-01T00:00:00Z"'
  eq "$(qrun "$P")/$([ -e "$W/out.txt" ] && echo ran || echo none)" "3/none" "[F] the expiry changed after signing: run --queued rc 3, nothing ran"
  has "$(cat "$BT_OUT")" "damaged" "[F] …it says the item is damaged"
  bt "$P" "$W" s-coord log --queue >/dev/null
  has "$(cat "$BT_OUT")" "$ID  damaged" "[F] log --queue: damaged"
  setup; OWD=$(fresh); queue "$P"; ask "$P" >/dev/null; osign "$P" >/dev/null
  age "$(item)" -172800
  eq "$(qrun "$P")/$([ -e "$W/out.txt" ] && echo ran || echo none)" "3/none" \
     "[F] the expiry pushed later after signing, the body hash computed again: run --queued rc 3 (the signature names the old body)"
  setup; OWD=$(fresh); queue "$P"; ask "$P" >/dev/null; osign "$P" >/dev/null
  poke "$(item)" 'it["args"] = [it["args"][0], "other"]; it["call"] = [it["call"][0], "other"]' rehash
  eq "$(qrun "$P")/$([ -e "$W/out.txt" ] && echo ran || echo none)" "3/none" \
     "[F] the arguments changed after signing, the body hash computed again: run --queued rc 3 (the signature names the old body)"
  setup; OWD=$(fresh); queue "$P"
  eq "$(ask "$P")" ask "[F] the owner's dialog opens"
  poke "$(item)" 'it["args"] = [it["args"][0], "other"]; it["call"] = [it["call"][0], "other"]' rehash
  eq "$(osign "$P")/$(python3 -c 'import json, sys; print("signature" in json.load(open(sys.argv[1])))' "$(item)")" "3/False" \
     "[F] the item changed between the dialog and the click: sign rc 3, unsigned"
  has "$(cat "$BT_OUT")" "changed since the dialog" "[F] …it says the item changed since the dialog"
  setup; OWD=$(fresh); queue "$P"
  poke "$(item)" 'it["plan"] = []'
  eq "$(ask "$P")/$(asked_n)" "deny/0" "[F] a damaged pending item: the guard denies"
}

fam_queue_scope() {  # [S] who may queue, and the owner's command shape
  local P=$1
  setup; OWD=$(fresh)
  BT_ENV=(INTENT_SLUG=s SEAT=1)
  queue "$P"
  eq "$QRC/$(items_n)" "64/0" "[S] go --queue in a sandbox: rc 64, nothing queued"
  BT_ENV=()
  queue "$P" ""
  eq "$QRC/$(items_n)" "64/0" "[S] go --queue with no session id: rc 64, nothing queued"
  bt "$P" "$W" s-coord mode auto >/dev/null
  queue "$P"
  eq "$QRC/$(items_n)/$([ -e "$W/out.txt" ] && echo ran || echo none)" "64/0/none" \
     "[S] go --queue on a baton the session may sign itself (mode auto, Stops none): rc 64, nothing queued, nothing ran"
  bt "$P" "$W" s-coord mode manual >/dev/null
  eq "$(bt "$P" "$W" s-coord go --by coordinator-auto --queue act.sh "$W/out.txt" hello)/$(items_n)" "64/0" "[S] go --by coordinator-auto --queue: rc 64"
  eq "$(bt "$P" "$W" s-coord go act.sh "$W/out.txt" hello)/$(items_n)" "8/0" "[S] go without --queue: exit 8 as today, nothing queued"
  queue "$P"
  eq "$(ASKCMD="$(owner_cmd "$P") extra" ask "$P")/$(asked_n)" "deny/0" "[S] the owner's command with a word after the id: denied"
  eq "$(ASKCMD="python3 $P/scripts/baton.py sign --by owner --queued XYZ" ask "$P")/$(asked_n)" "deny/0" "[S] a malformed id: denied"
  eq "$(ask "$P" s-owner '{"agent_id": "a1"}')/$(asked_n)" "deny/0" "[S] a subagent: denied"
  BT_ENV=(INTENT_SLUG=s SEAT=1)
  eq "$(ask "$P")/$(asked_n)" "deny/0" "[S] a sandbox session: denied"
  BT_ENV=()
  eq "$(ask "$P")" ask "[S] the owner's own session: ask"
  eq "$(BT_ENV=(INTENT_SLUG=s SEAT=1); osign "$P")" 3 "[S] …the sign in a sandbox: rc 3"
}

FAMILIES="fam_queue_flow fam_queue_refusals fam_queue_coordinator fam_queue_forgery fam_queue_scope"
echo "== the real plugin =="
REAL="$TMP/real"; mk_plugin_copy "$REAL"
for f in $FAMILIES; do echo "-- $f"; "$f" "$REAL"; done

echo "== planted breaks: each family must go red on a plugin copy with one break in baton.py =="
# BRK <label> <family> <needle> <old> <new> [<old> <new>]... — a plugin copy with the replacements in baton.py, then expect_red
BRK() {
  local label=$1 fam=$2 needle=$3 d; shift 3; d="$TMP/break-$label"; mk_plugin_copy "$d"
  while [ $# -ge 2 ]; do mutate "$d/scripts/baton.py" "$1" "$2" || return; shift 2; done
  expect_red "$label" "$fam" "$d" "$needle"
}
# no dialog record: the sign's binding to the item the dialog showed refuses too, so the break takes both
BRK no-dialog fam_queue_flow "[Q] the owner's session without the dialog's record" \
    '        return signed_queued(rest[3], owner_signs(asked))' '        return signed_queued(rest[3], "planted")' \
    '    if RUN.get("asked_queued") != [qid, it["body_sha256"]]:' '    if False:'
BRK guard-queuer-ignored fam_queue_coordinator "[C] the coordinator's own session asks: the guard denies" \
    '        why = queue_why(argv[3], state, it) if state != "pending" else queuer(' '        why = queue_why(argv[3], state, it) if state != "pending" else None and queuer('
BRK sign-queuer-ignored fam_queue_coordinator "[C] a dialog record in the coordinator's own session" \
    '    why = queuer(it, session_id(), [this_claude(), RUN.get("asked_claude")])' '    why = None'
BRK process-unbound fam_queue_coordinator "[C] /clear: the same Claude Code process as session s-B asks" \
    '    if any(same_claude(it.get("claude"), c) for c in claudes):' '    if False:'
BRK expiry-unchecked fam_queue_refusals "[R] an expired item: the guard denies" '        if now > exp:' '        if False:'
BRK sign-state-unchecked fam_queue_refusals "[R] an expired item with a dialog record" \
    $'    if state != "pending":\n        refuse(queue_why(qid, state, it))' $'    if state not in ("pending", "expired"):\n        refuse(queue_why(qid, state, it))'
BRK cwd-unchecked fam_queue_refusals "[R] …it says where it was queued" '    elif cwd != it["cwd"]:' '    elif False:'
BRK dialog-unbound fam_queue_forgery "[F] the item changed between the dialog and the click" \
    '    if RUN.get("asked_queued") != [qid, it["body_sha256"]]:' '    if False:'
BRK body-unchecked fam_queue_forgery "[F] the expiry changed after signing" ' or it.get("body_sha256") != item_digest(it)' ''
BRK signature-unbound fam_queue_forgery "[F] the expiry pushed later after signing" \
    $'\n                                             and sig.get("body_sha256") == it["body_sha256"]' ''
BRK used-unmarked fam_queue_flow "[Q] …it says the item was used" '            return path, it, "used"' '            return path, it, "signed"'
BRK sandbox-queues fam_queue_scope "[S] go --queue in a sandbox" \
    $'        if in_sandbox():\n            raise Stop(USAGE, "go --queue in a sandbox' $'        if False:\n            raise Stop(USAGE, "go --queue in a sandbox'
BRK queue-without-owner fam_queue_scope "[S] go --queue on a baton the session may sign itself" '        if queue and not why:' '        if False:'
BRK shape-open fam_queue_scope "[S] the owner's command with a word after the id" \
    '        return rest[1:] if len(rest) == 5 and QUEUE_ID.match(rest[4]) else None' '        return rest[1:]'
BRK expiry-at-use-unchecked fam_queue_refusals "[R] an item that expires during the run's own rehearse" \
    '                if state != "signed" or again != item:' '                if again != item:'
BRK sessionless-queue fam_queue_scope "[S] go --queue with no session id" \
    $'        if not session_id():\n            raise Stop(USAGE, "go --queue needs' $'        if False:\n            raise Stop(USAGE, "go --queue needs'
BRK setsid-process-lost fam_queue_coordinator "[C] go --queue under setsid" \
    '    return [int(hint), start] if start is not None else None' '    return None'
BRK dialog-hides-args fam_queue_flow "[Q] …and the words the script runs with" \
    '"  Args:     %s" % (" ".join(quoted(str(a)) for a in it.get("call") or []) or "(none)")] + card' '] + card'
BRK list-hides-args fam_queue_flow "[Q] log --queue: …the words the script runs with" \
    $'        for ln in item_lines(it):\n            say("  %s", ln)' $'        for ln in it.get("card") or []:\n            say("  %s", ln)'
BRK list-hides-detail fam_queue_flow "[Q] log --queue: …the check and rehearse output" \
    '            say("  detail: %s (check and rehearse output)", it["detail"])' '            pass'
BRK auto-signs-queued fam_queue_coordinator "[C] sign --by coordinator-auto --queued" \
    '        if rest[1] != "owner" or len(rest) != 4' '        if len(rest) != 4'

echo "== nothing written outside the scratch tree =="
eq "$(tree_hash "$SRC_ROOT")" "$H0" "the repository tree is unchanged by the suite"
echo; summary
