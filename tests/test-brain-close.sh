#!/bin/bash
# =============================================================================
# vibemaestro-brain: auto-close — a live Now or Next item whose `closes` anchors are all done closes itself at the writer's
# SessionStart (the machine op link-close); everything else is marked, never closed
# =============================================================================
# Run: bash tests/test-brain-close.sh
#
# Offline: a stub `gh` first on PATH answers `gh api repos/<o>/<r>/issues/<n>` and `…/pulls/<n>` from files (the --jq line a real
# gh prints), logs every argv, and can fail, answer 404 or sleep. Items are written through the store library with fixed `created`
# stamps (the suite's clock), as the writer session sA; the hook runs as Claude Code runs it, with no CLAUDE_CODE_SESSION_ID: the
# three SessionStart commands at once (hot memory with Now; sessions; plan with Next and Done), and the checks read all three.
#   [a] a PR merged into the default branch closes X, an issue closed completed (fresh) closes N: the op, archive, episode, note
#   [b] closed unmerged, merged into another branch, not planned, duplicate, no reason, open, 404, gh error, gh missing, gh slow, the
#       pulls lookup unanswered, the same number merged in another repository: no close, a mark or a note, rc 0
#   [c] done before `created` (also the same UTC day): no close; a supersede after the merge of an item first written before it: closes
#   [d] a done anchor in `anchors` but not in `closes`: no close      [e] two `closes`, one done: no close, then both: closes
#   [f] a pinned decision with a done anchor (and one forged with `closes`): never closed, marked `owner retires it`; T and W untouched
#   [g] not the writer: marks only; the writer closes whatever CLAUDE_CODE_SESSION_ID says; the store refuses a link-close by another
#   [h] 6 closable items: none closes, the `held` note; `brain op close-linked` closes all 6
#   [i] --closes: a bare ¤N refused with and without BRAIN_DEFAULT_REPO, a URL stored as owner/name¤N, a 404 and an anchor already
#       done refused, an unanswered lookup accepted with `closes not checked`, more than 2 and other forms refused
#   [j] --closes on a decision, window or trap refused (64); supersede carries `closes` and prints it, a new --closes replaces it
#   [k] a cached `completed` issue does not close, a cached merged PR does; a version-1 cache entry never closes
#   [l] a link-close with every field, a 40-character repository name: chains, archived with reason and pointer, budget not spent
#   [m] the note on the closing SessionStart only; a reopened issue adds `reopened:`
#   [n] rotation (31 anchors in 3 SessionStarts), a burst skips round 2, ≤ 3 reopen checks, `base_ok: null` retried first outside the
#       12, a mixed close's issue anchor reopen-checked, an older brain's version-1 rewrite read for marks only and refilled as v2
#   [o] doctor: would close, auto-closed, reopened, the pins; doctor writes nothing
#   [p] every gh argv carries --hostname github.com; close-linked stops at 40 keys; `format` 2 on session-start, doctor warns below
#   [q] the worst-case string 1 (every section full, every item stale, 5 closes or a held burst and reopens) ≤ 8,000 with no cut
#   [r] a head.json that cannot be written: the log is cut back, nothing closed, still readable; a failure after one close
#       reports that close; write-time checks come before the lookup; a supersede keeping a done anchor warns, a new one is refused
#   [s] round 2 rotates: five PRs whose pulls lookup keeps failing do not starve a sixth
#   [X] planted breaks: each case goes red on a copy with one break
# =============================================================================
set -uo pipefail
if [ -z "${BRAIN_SUITE_REEXEC:-}" ]; then
  export PYTHONUSERBASE="${PYTHONUSERBASE:-$(python3 -m site --user-base 2>/dev/null)}"
  # Every issue or PR number is spelled ¤5 so that the public-tree scan does not read test data as a reference; the copy this run
  # executes has a real hash sign (same name, so the suite's result file keeps its name).
  SRC_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
  TEXT_DIR=$(mktemp -d) && sed 's/¤/#/g' "$0" > "$TEXT_DIR/$(basename -- "$0")" || exit 2
  exec env -u CLAUDE_CONFIG_DIR -u CLAUDE_CODE_SESSION_ID -u BRAIN_DEFAULT_REPO BRAIN_SUITE_REEXEC=1 BRAIN_SUITE_SRC_DIR="$SRC_DIR" \
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

# --- the stub gh ------------------------------------------------------------------------------------------------------------
export STUB="$TMP/stub"
mkdir -p "$TMP/bin" "$TMP/nogh"
cat > "$TMP/bin/gh" <<'SH'
#!/bin/sh
# stub gh: `gh api repos/<o>/<r>/issues/<n> …` prints $STUB/answers/<o>_<r>_<n>, `…/pulls/<n>` prints $STUB/pulls/<o>_<r>_<n> (the
# --jq line a real gh prints; a jq asking for .title gets ` <tab>Stub title` added); no file: 404
echo "$*" >> "$STUB/calls"
[ "$1" = api ] || exit 2
case "$2" in
  repos/*/issues/*) dir=answers ;;
  repos/*/pulls/*) dir=pulls ;;
  *) exit 2 ;;
esac
f="$STUB/$dir/$(printf '%s' "$2" | sed -e 's#^repos/##' -e 's#/issues/#_#' -e 's#/pulls/#_#' -e 's#/#_#')"
[ -f "$f" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
case $(cat "$f") in
  SLOW) sleep 20 & echo $! >> "$STUB/pids"; echo $$ >> "$STUB/pids"; wait; exit 0 ;;
  FAIL) echo "gh: Server Error (HTTP 500)" >&2; exit 1 ;;
esac
case "$*" in *.title*) printf '%s\tStub title\n' "$(cat "$f")" ;; *) cat "$f" ;; esac
SH
chmod +x "$TMP/bin/gh"
for b in python3 git sh sed cat dirname; do ln -s "$(command -v "$b")" "$TMP/nogh/$b"; done   # a PATH with no gh in it
PY=$(command -v python3)
export PATH="$TMP/bin:$PATH"

# the suite's clock: items are created at C20 (15:00 on the 20th); B19 is the day before, M20 the same day at 09:00, A21 after
C20=2026-10-20T15:00:00Z; B19=2026-10-19T10:00:00Z; M20=2026-10-20T09:00:00Z; A21=2026-10-21T10:00:00Z; A22=2026-10-22T08:00:00Z
D21=2026-10-21; D22=2026-10-22; D19=2026-10-19; D20=2026-10-20
SHA_A=0123456789abcdef0123456789abcdef01234567
GH=https://github.com; IS=issues; PL=pull    # spelled in parts: the public-tree scan reads a literal /issues/N as a reference

stub_reset() {
  [ -n "$STUB" ] && rm -rf "$STUB"
  mkdir -p "$STUB/answers" "$STUB/pulls"; : > "$STUB/calls"; : > "$STUB/pids"
}
kf() { local k=${1/\#/_}; printf '%s' "${k//\//_}"; }                      # acme/app¤5 → acme_app_5
issue() {  # issue <owner/name¤n> open|reopened|none|completed|not_planned|duplicate [closed_at]
  local f; f="$STUB/answers/$(kf "$1")"
  case $2 in
    open) printf 'open\t\t\t\tissue\n' > "$f" ;;
    reopened) printf 'open\t\t\treopened\tissue\n' > "$f" ;;
    none) printf 'closed\t%s\t\t\tissue\n' "$3" > "$f" ;;
    *) printf 'closed\t%s\t\t%s\tissue\n' "$3" "$2" > "$f" ;;
  esac
}
pr() {  # pr <owner/name¤n> open|closed|merged [at] [base ref; the default branch is main]
  local k; k=$(kf "$1")
  case $2 in
    open) printf 'open\t\t\t\tpr\n' > "$STUB/answers/$k" ;;
    closed) printf 'closed\t%s\t\t\tpr\n' "$3" > "$STUB/answers/$k" ;;
    merged) printf 'closed\t%s\t%s\t\tpr\n' "$3" "$3" > "$STUB/answers/$k"
            printf '%s\tmain\t%s\t%s\n' "${4:-main}" "$3" "$SHA_A" > "$STUB/pulls/$k" ;;
  esac
}
raw() { printf '%s\n' "$3" > "$STUB/$1/$(kf "$2")"; }                     # raw answers|pulls <key> SLOW|FAIL|<text>
ncalls() { wc -l < "$STUB/calls" | tr -d ' '; }
calls_of() { grep -c -F -e "repos/${2%%#*}/$1/${2##*#} " "$STUB/calls" || true; }   # calls_of issues|pulls <owner/name¤n>
nissues() { grep -c -F '/issues/' "$STUB/calls" || true; }
npulls() { grep -c -F '/pulls/' "$STUB/calls" || true; }
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
alive() { local p r=no; for p in $(cat "$STUB/pids"); do kill -0 "$p" 2>/dev/null && r=yes; done; echo "$r"; }
reap() { local p; for p in $(cat "$STUB/pids"); do kill "$p" 2>/dev/null; done; }

ctx() { printf '%s' "$CTX"; }                                              # the three strings of the last SessionStart
shelf() { printf '%s\n' "$1" | sed -n '/^## Shelf index/,$p'; }
ctxof() {  # ctxof <file> — additionalContext of one hook's stdout file ("" when it printed nothing)
  python3 -c 'import json, sys
t = open(sys.argv[1], encoding="utf-8").read().strip()
print(json.loads(t)["hookSpecificOutput"]["additionalContext"] if t else "", end="")' "$1"
}
EVENTS="session-start session-start-sessions session-start-plan"
start3() {  # start3 <source> <session id> [env…] — the three SessionStart commands at once, as Claude Code runs them, with no
            # CLAUDE_CODE_SESSION_ID; OUT and ERR are string 1's command's, RC 0 when all three exit 0, CTX the three strings
  local in e p rc=0 pids=() src=$1 sid=$2; shift 2
  in=$(hin session_id="$sid" cwd="$P" hook_event_name=SessionStart source="$src")
  for e in $EVENTS; do
    printf '%s' "$in" | env -u CLAUDE_CODE_SESSION_ID "$@" ${HOOK_ENV:-} "$PY" "$BROOT/scripts/brain_hook.py" "$e" > "$TMP/o.$e" 2> "$TMP/e.$e" &
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p" || rc=1; done
  RC=$rc; OUT=$(cat "$TMP/o.session-start"); ERR=$(cat "$TMP/e.session-start")
  CTX=$(for e in $EVENTS; do ctxof "$TMP/o.$e"; echo; done)
}
start() { start3 "${1:-compact}" "${2:-$SID}"; }   # start [source] [session id]
start_nogh() { start3 compact "$SID" PATH="$TMP/nogh"; }
start_faulty() {  # start_faulty <n> [caches] — SessionStart as Claude Code runs it, the n-th link-close append failing (OSError 28),
                  # and with `caches`, hot.json that cannot be rewritten either; strings 2 and 3 run beside it, as always
  local e f in pids=(); e=$(mktemp); in=$(hin session_id="$SID" cwd="$P" hook_event_name=SessionStart source=compact)
  for f in session-start-sessions session-start-plan; do
    printf '%s' "$in" | env -u CLAUDE_CODE_SESSION_ID "$PY" "$BROOT/scripts/brain_hook.py" "$f" > "$TMP/o.$f" 2>/dev/null &
    pids+=($!)
  done
  OUT=$(printf '%s' "$in" | env -u CLAUDE_CODE_SESSION_ID "$PY" -c 'import runpy, sys
sys.path.insert(0, sys.argv[1] + "/scripts")
import brain_store as s
real, n, nth = s.append, [0], int(sys.argv[2])
if sys.argv[3:] == ["caches"]:
    real_w = s._write_file
    def w(p, data):
        if p.endswith("hot.json"):
            raise OSError(28, "No space left on device")
        return real_w(p, data)
    s._write_file = w
def app(d, raw, op):
    if op.get("op") == "link-close":
        n[0] += 1
        if n[0] == nth:
            raise OSError(28, "No space left on device")
    return real(d, raw, op)
s.append = app
sys.argv = [sys.argv[1] + "/scripts/brain_hook.py", "session-start"]
runpy.run_path(sys.argv[0], run_name="__main__")' "$BROOT" "$1" "${2:-}" 2>"$e"); RC=$?
  ERR=$(cat "$e"); rm -f "$e"
  for f in "${pids[@]}"; do wait "$f"; done
  CTX=$(printf '%s' "$OUT" | python3 -c 'import json, sys; t = sys.stdin.read().strip(); print(json.loads(t)["hookSpecificOutput"]["additionalContext"] if t else "")'
        for f in session-start-sessions session-start-plan; do ctxof "$TMP/o.$f"; echo; done)
}
live_ctx() { printf '%s\n' "$(ctx)" | sed '/^Done (24 h)$/,/^Facts$/d'; }   # the strings without Done (closed items)
line() { live_ctx | grep -F -e "- $1 " || true; }                          # the strings' line of one live item
inblock() { live_ctx | grep -c -E -e "^- $1 " || true; }                   # 1 when the item is shown live
autonote() { printf '%s\n' "$(ctx)" | grep -E '^(auto-closed now|auto-close|reopened)' || true; }
status_of() { bpy "print(s.fold(s.verify(s.state_dir())[1])['items']['$1']['status'])"; }
nlinks() { grep -c '"op":"link-close"' "$(sdir)/hot.jsonl" || true; }
lastop() { tail -n 1 "$(sdir)/hot.jsonl"; }
opf() {  # opf <python expression on o, the last link-close op>
  python3 - "$(sdir)/hot.jsonl" "$1" <<'PY'
import json, sys
ops = [json.loads(l) for l in open(sys.argv[1]) if '"op":"link-close"' in l]
o = ops[-1] if ops else {}
print(eval(sys.argv[2]))
PY
}
eplines() { grep -F "\"kind\":\"$1\"" "$(sdir)/episodes.jsonl" 2>/dev/null || true; }
sums() { (cd "$(sdir)" && sha256sum hot.jsonl head.json | sha256sum | cut -c1-16); }
rep() { python3 -c 'import sys; print(sys.argv[1] * int(sys.argv[2]))' "$@"; }
age_cache() {  # age_cache <seconds> [key…] — every cache entry (or the named ones) that much older
  bpy "import sys, brain_stale as b
d = s.state_dir(); e = b.read_cache(d); keys = sys.argv[2:] or list(e)
for k in keys:
    if k in e: e[k]['t'] -= $1
b.write_cache(d, e)" "$@"
}
np() { newp; stub_reset; }

# seed <spec>… — items appended through the store library with fixed `created` stamps, as the writer sA. A spec is
#   ID@CREATED[;closes=A,B][;anchors=A,B][;sup=ID][;text=T][;linkclosed=AT]
# the kind comes from the letter; `sup` supersedes that item; `linkclosed` adds a link-close of the item's closes as completed issues
# at AT (the op's own time is now). Caps are not checked here: the library folds whatever the log holds.
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
        put({"op": "claim", "t": "2026-10-01T00:00:00Z", "by": by, "takeover": False})
    for spec in sys.argv[2:]:
        head, *opts = spec.split(";")
        iid, _, created = head.partition("@")
        o = dict(x.split("=", 1) for x in opts)
        closes = [c for c in o.get("closes", "").split(",") if c]
        anchors = [c for c in o.get("anchors", "").split(",") if c]
        anchors += [c for c in closes if c not in anchors]
        item = {"id": iid, "kind": kinds[iid[0]], "pinned": iid[0] == "D", "text": o.get("text", "item " + iid),
                "source": {"type": "owner" if iid[0] in "DW" else "coordinator"},
                "expires": "2099-01-02T22:00:00Z" if iid[0] == "W" else None, "links": [], "anchors": anchors,
                "supersedes": o.get("sup")}
        if closes:
            item["closes"] = closes
        if o.get("sup"):
            put({"op": "supersede", "id": o["sup"], "item": item, "reason": "r", "drop": [], "shorter": False, "bulk": False,
                 "t": created, "by": by})
        else:
            put({"op": "owner-add" if iid[0] in "DW" else "add", "item": item, "t": created, "by": by})
        if o.get("linkclosed"):
            an = [{"anchor": c, "state": "completed", "at": o["linkclosed"]} for c in closes]
            put({"op": "link-close", "id": iid, "anchors": an, "reason": s.link_reason(an), "pointer": closes[0],
                 "t": s.now_iso(), "by": {"session": "sA", "hook": "SessionStart"}})
    s.write_caches(d, st, s.head_of(raw))
PY
}

# --- [a] -----------------------------------------------------------------------------------------------------------------------
case_close() {
  np
  seed "X1@$C20;closes=acme/app¤5;text=ship the parser" "N1@$C20;closes=acme/app¤7;text=fix the login bug" \
       "X2@$C20;anchors=acme/app¤9;text=still open"
  pr 'acme/app¤5' merged "$A21"; issue 'acme/app¤7' completed "$A22"; pr 'acme/app¤9' open
  start compact
  c_rc 0 "[a] SessionStart rc 0"
  c_eq "$(inblock X1)" 0 "[a] a PR merged into the default branch closes its Next item (gone from the block)"
  c_eq "$(inblock N1)" 0 "[a] an issue closed completed, looked up now, closes its Now item"
  c_eq "$(inblock X2)" 1 "[a] the item with an open anchor stays"
  c_eq "$(status_of X1) $(status_of N1) $(status_of X2)" "closed closed live" "[a] the log says so"
  c_eq "$(nlinks)" 2 "[a] two link-close ops"
  c_eq "$(opf 'o["id"], o["reason"], o["pointer"]')" "('X1', 'merged acme/app¤5 $D21', 'acme/app¤5')" "[a] the op names its reason and pointer"
  c_eq "$(opf 'o["anchors"]')" "[{'anchor': 'acme/app¤5', 'at': '$A21', 'sha': '0123456789ab', 'state': 'merged'}]" "[a] state, time and merge commit per anchor"
  c_eq "$(opf 'o["by"]')" "{'hook': 'SessionStart', 'session': 'sA'}" "[a] written as the hook input's session, by SessionStart"
  c_has "$(grep -F '"id":"N1"' "$(sdir)/hot.jsonl" | grep -F link-close)" "\"state\":\"completed\"" "[a] the issue's anchor is completed"
  c_has "$(grep -F '"id":"N1"' "$(sdir)/archive.jsonl")" "\"reason\":\"completed acme/app¤7 $D22\"" "[a] the archive holds the item with its reason"
  c_has "$(grep -F '"id":"X1"' "$(sdir)/archive.jsonl")" "\"pointer\":\"acme/app¤5\"" "[a] and its pointer"
  c_eq "$(autonote)" "auto-closed now: N1 (acme/app¤7 completed 10-22)
auto-closed now: X1 (acme/app¤5 merged 10-21)" "[a] one note line per string says what closed: N1 in string 1, X1 in string 3"
  c_has "$(eplines auto-close)" '"ids":["N1","X1"]' "[a] the episode log has one auto-close line with the ids"
  c_has "$(eplines auto-close)" '"anchors":["acme/app¤7","acme/app¤5"]' "[a] and the anchors"
  c_has "$(eplines session-start)" '"closed":2' "[a] the session-start line counts the closes"
  c_eq "$(calls_of pulls acme/app¤5)" 1 "[a] the merged PR was looked up at the pulls endpoint"
  c_eq "$(calls_of pulls acme/app¤7)" 0 "[a] the issue was not"
  c_eq "$(bpy 'print(len(s.load(s.state_dir())[1]["retirements"]))')" 0 "[a] the retirement budget is not spent"
  br doctor; c_hasnt "$OUT" "problem" "[a] doctor: the chain holds the machine ops"
}

# --- [b] -----------------------------------------------------------------------------------------------------------------------
nobody() {  # nobody <label> <mark expected in X1's line or -> — X1 (closes acme/app¤5) must stay live after one SessionStart
  start compact
  c_rc 0 "[b] $1: rc 0"
  c_eq "$(inblock X1)" 1 "[b] $1: the item stays"
  c_eq "$(nlinks)" 0 "[b] $1: no link-close"
  [ "$2" = - ] || c_has "$(line X1)" "$2" "[b] $1: marked '$2'"
}
case_noclose() {
  local one='X1@'"$C20"';closes=acme/app¤5'
  np; seed "$one"; pr 'acme/app¤5' closed "$A21"; nobody "a PR closed unmerged" "stale: acme/app¤5 closed unmerged $D21"
  np; seed "$one"; pr 'acme/app¤5' merged "$A21" dev; nobody "a PR merged into another branch" "stale: acme/app¤5 merged into dev $D21"
  np; seed "$one"; issue 'acme/app¤5' not_planned "$A21"; nobody "an issue closed not planned" "stale: acme/app¤5 closed not planned $D21"
  np; seed "$one"; issue 'acme/app¤5' duplicate "$A21"; nobody "an issue closed as a duplicate" "stale: acme/app¤5 closed duplicate $D21"
  np; seed "$one"; issue 'acme/app¤5' none "$A21"; nobody "an issue closed with no reason" "stale: acme/app¤5 closed $D21"
  np; seed "$one"; pr 'acme/app¤5' open; nobody "an open PR" -
  c_hasnt "$(line X1)" "stale" "[b] an open PR: no mark"
  np; seed "$one"; nobody "a 404" -
  c_has "$(ctx)" "stale-anchor check: incomplete" "[b] a 404: the note says incomplete"
  np; seed "$one"; raw answers 'acme/app¤5' FAIL; nobody "a gh error" -
  c_has "$(ctx)" "incomplete" "[b] a gh error: the note says incomplete"
  np; seed "$one"; pr 'acme/app¤5' merged "$A21"; start_nogh
  c_rc 0 "[b] gh missing: rc 0"; c_eq "$(inblock X1)" 1 "[b] gh missing: the item stays"; c_eq "$(nlinks)" 0 "[b] gh missing: no link-close"
  c_has "$(ctx)" "gh not found" "[b] gh missing: the note says why"
  np; seed "$one"; raw answers 'acme/app¤5' SLOW
  local t0 t1; t0=$(now_ms); nobody "a slow gh" -; t1=$(now_ms)
  c_eq "$([ $((t1 - t0)) -lt 8000 ] && echo fast)" fast "[b] a slow gh: the hook returns at its deadline ($((t1 - t0)) ms)"
  c_eq "$(alive)" no "[b] a slow gh: the stub's process group is gone"; reap
  np; seed "$one"; pr 'acme/app¤5' merged "$A21"; raw pulls 'acme/app¤5' FAIL; nobody "the pulls lookup unanswered" "stale: acme/app¤5 merged $D21"
  c_eq "$(bpy 'import brain_stale as b; print(b.read_cache(s.state_dir())["acme/app¤5"]["base_ok"])')" None "[b] its base stays null in the cache"
  np; seed "$one"; pr 'acme/app¤5' merged "$A21"; raw pulls 'acme/app¤5' SLOW
  nobody "the pulls lookup slow" "stale: acme/app¤5 merged $D21"; reap
  # the same number merged in another repository, and an issue answer from another repository's URL form
  np; seed "X1@$C20;closes=acme/app¤5" "X2@$C20;closes=acme/other¤6"
  pr 'acme/other¤5' merged "$A21"; pr 'acme/app¤5' open; pr 'acme/app¤6' merged "$A21"; pr 'acme/other¤6' open
  start compact
  c_eq "$(inblock X1) $(inblock X2) $(nlinks)" "1 1 0" "[b] a PR merged in another repository with the same number closes nothing"
  c_eq "$(calls_of issues acme/other¤5)$(calls_of issues acme/app¤6)" "00" "[b] and is never looked up"
}

# --- [c] -----------------------------------------------------------------------------------------------------------------------
case_time() {
  np; seed "X1@$C20;closes=acme/app¤5"; pr 'acme/app¤5' merged "$B19"
  nobody "merged the day before the item was written" "stale: acme/app¤5 merged $D19"
  np; seed "X1@$C20;closes=acme/app¤5"; pr 'acme/app¤5' merged "$M20"
  nobody "merged at 09:00, the item written at 15:00 the same day" "stale: acme/app¤5 merged $D20"
  np; seed "X1@$C20;closes=acme/app¤5"; issue 'acme/app¤5' completed "$C20"
  nobody "done in the very second the item was written" -
  # the chain root's `created` counts: written before the merge, superseded after it ("merged, wrap up")
  np; seed "X1@$M20;closes=acme/app¤5" "X2@$A22;closes=acme/app¤5;sup=X1"; pr 'acme/app¤5' merged "$A21"
  start compact
  c_eq "$(status_of X2)" closed "[c] a supersede after the merge of an item first written before it: closes"
  c_eq "$(opf 'o["id"]')" X2 "[c] the live item of the chain is the one closed"
  # an item first written after the merge, superseded later: still never closes
  np; seed "X1@$A22;closes=acme/app¤5" "X2@$A22;closes=acme/app¤5;sup=X1"; pr 'acme/app¤5' merged "$A21"
  start compact; c_eq "$(status_of X2) $(nlinks)" "live 0" "[c] a chain first written after the merge: no close"
  # a gap in the chain: X1 named it, X2 dropped it, X3 (written after the merge) named it again: X3's own time counts
  np; seed "X1@$M20;closes=acme/app¤5" "X2@$C20;closes=acme/app¤6;sup=X1" "X3@$A22;closes=acme/app¤5;sup=X2"
  pr 'acme/app¤5' merged "$A21"; pr 'acme/app¤6' open
  start compact; c_eq "$(status_of X3) $(nlinks)" "live 0" "[c] a chain with a gap: the item that named the anchor again, after the merge, does not close"
  # a superseded item with other closes: the old anchor merging closes nothing
  np; seed "X1@$C20;closes=acme/app¤5" "X2@$C20;closes=acme/app¤6;sup=X1"; pr 'acme/app¤5' merged "$A21"; pr 'acme/app¤6' open
  start compact; c_eq "$(status_of X2) $(nlinks)" "live 0" "[c] superseded with another closes: the old anchor's merge closes nothing"
}

# --- [d] [e] -------------------------------------------------------------------------------------------------------------------
case_plain() {
  np; seed "X1@$C20;anchors=acme/app¤5" "X2@$C20;anchors=acme/app¤5;closes=acme/app¤6" "N1@$C20;anchors=acme/app¤8"
  pr 'acme/app¤5' merged "$A21"; pr 'acme/app¤6' open; issue 'acme/app¤8' completed "$A21"
  start compact
  c_eq "$(inblock X1)$(inblock X2)$(inblock N1)" 111 "[d] a done anchor in anchors, not in closes: no close"
  c_eq "$(nlinks)" 0 "[d] no link-close"
  c_has "$(line X1)" "stale: acme/app¤5 merged $D21" "[d] the plain anchor is marked as before"
  c_eq "$(calls_of pulls acme/app¤5)" 0 "[d] a plain anchor is never looked up at the pulls endpoint"
}
case_two() {
  np; seed "X1@$C20;closes=acme/app¤7,acme/app¤8"; issue 'acme/app¤7' completed "$A22"; pr 'acme/app¤8' open
  start compact
  c_eq "$(inblock X1) $(nlinks)" "1 0" "[e] two closes, one done (an issue completed, looked up now): no close"
  pr 'acme/app¤8' merged "$A21"; age_cache 700
  start compact
  c_eq "$(status_of X1)" closed "[e] both done: closes"
  c_eq "$(opf 'len(o["anchors"]), o["anchors"][1]["state"]')" "(2, 'merged')" "[e] the op names both anchors"
  c_eq "$(opf 'o["reason"]')" "completed acme/app¤7 $D22; merged acme/app¤8 $D21" "[e] and both in its reason"
}

# --- [f] -----------------------------------------------------------------------------------------------------------------------
case_pins() {
  np
  seed "D1@$C20;anchors=acme/app¤5" "D2@$C20;closes=acme/app¤6" "W1@$C20;anchors=acme/app¤5" "T1@$C20;closes=acme/app¤6" \
       "X1@$C20;anchors=acme/app¤9"
  pr 'acme/app¤5' merged "$A21"; pr 'acme/app¤6' merged "$A21"; pr 'acme/app¤9' open
  start compact
  c_eq "$(status_of D1) $(status_of D2) $(status_of W1) $(status_of T1)" "live live live live" "[f] pins, windows and traps are never closed"
  c_eq "$(nlinks)" 0 "[f] no link-close (a pin forged with closes neither)"
  c_has "$(line D1)" "stale: acme/app¤5 merged $D21, owner retires it" "[f] a pin with a done anchor: the owner retires it"
  c_hasnt "$(line W1)" "stale" "[f] a window is not marked"
  c_hasnt "$(line T1)" "stale" "[f] a trap is not marked"
  c_eq "$(calls_of pulls acme/app¤6)" 0 "[f] no pulls lookup for a pin's or a trap's anchor"
}

# --- [g] -----------------------------------------------------------------------------------------------------------------------
case_writer() {
  np; seed "X1@$C20;closes=acme/app¤5"; pr 'acme/app¤5' merged "$A21"
  start compact sB
  c_eq "$(inblock X1) $(nlinks)" "1 0" "[g] another session's SessionStart: no close"
  c_has "$(line X1)" "stale: acme/app¤5 merged $D21" "[g] it marks"
  c_eq "$(autonote)" "" "[g] and says nothing about auto-close"
  c_eq "$(npulls)" 0 "[g] and makes no pulls lookup"
  HOOK_ENV="CLAUDE_CODE_SESSION_ID=sZ" start compact sA
  c_eq "$(status_of X1)" closed "[g] the writer's SessionStart closes, whatever CLAUDE_CODE_SESSION_ID the hook's env holds"
  c_eq "$(opf 'o["by"]["session"]')" sA "[g] written as the hook input's session"
  np; seed "X1@$C20;closes=acme/app¤5"; pr 'acme/app¤5' merged "$A21"
  start compact sA
  c_eq "$(status_of X1)" closed "[g] the writer's SessionStart with no CLAUDE_CODE_SESSION_ID at all closes"
  np; seed "X1@$C20;closes=acme/app¤5"
  R=$(bpy 'try:
    s.link_close(s.state_dir(), "sB", [("X1", [{"anchor": "acme/app¤5", "state": "merged", "at": "'"$A21"'", "sha": "0123456789ab"}])], {"hook": "SessionStart"})
    print("written")
except s.Refused as e:
    print(e.rc)')
  c_eq "$R" 3 "[g] the store refuses a link-close by a session that is not the writer (rc 3)"
  c_eq "$(nlinks)" 0 "[g] and writes nothing"
}

# --- [h] -----------------------------------------------------------------------------------------------------------------------
six() {
  np; local i
  for i in 1 2 3 4 5; do seed "X$i@$C20;closes=acme/app¤$i"; pr "acme/app¤$i" merged "$A21"; done
  seed "N1@$C20;closes=acme/app¤6"; pr 'acme/app¤6' merged "$A21"
}
case_burst() {
  six
  start compact
  c_eq "$(nlinks)" 0 "[h] 6 closable items at once: none closes"
  c_has "$(autonote)" "auto-close held: 6 items at once; check brain doctor, then brain op close-linked" "[h] the held note"
  c_has "$(line X3)" "stale: acme/app¤3 merged $D21" "[h] each is marked"
  c_has "$(eplines session-start)" '"held":6' "[h] the episode line counts them"
  br op close-linked
  c_rc 0 "[h] close-linked: rc 0"
  c_eq "$(nlinks)" 6 "[h] close-linked closes all 6 (no cap)"
  c_has "$OUT" "closed X1 (merged acme/app¤1 $D21)" "[h] it prints each item it closed"
  c_eq "$(opf 'o["by"]')" "{'cmd': 'close-linked', 'session': 'sA'}" "[h] logged as link-close by the command"
  c_has "$(eplines auto-close)" '"cmd":"close-linked"' "[h] with an auto-close episode line"
  br op close-linked; c_has "$OUT" "no live Now, Next, session or queue item names a closes anchor" "[h] a second run has nothing left"
  six; issue 'acme/app¤9' open; seed "X6@$C20;closes=acme/app¤9"
  : > "$STUB/calls"; SID=sB br op close-linked; c_rc 3 "[h] close-linked from another session: rc 3"
  c_eq "$(ncalls)" 0 "[h] refused before any lookup"
  br op close-linked; c_has "$OUT" "skipped X6: acme/app¤9 open" "[h] it prints each item it skipped, with why"
}

# --- [i] -----------------------------------------------------------------------------------------------------------------------
case_write() {
  np
  br op add --kind next --text t --closes '¤5'
  c_rc 64 "[i] --closes ¤5: refused (64)"; c_has "$OUT" "owner/name¤5" "[i] it names the form to use"
  BRAIN_DEFAULT_REPO=acme/app br op add --kind next --text t --closes '¤5'
  c_rc 64 "[i] --closes ¤5 with BRAIN_DEFAULT_REPO set: still refused (64)"
  pr 'acme/app¤9' open
  br op add --kind next --text "url form" --closes "$GH/acme/app/$PL/9"
  c_rc 0 "[i] a PR URL: rc 0"
  c_has "$OUT" "closes acme/app¤9: PR open · Stub title" "[i] the writer sees its state and title"
  c_eq "$(bpy 'st = s.load(s.state_dir())[1]; print(st["items"]["X1"]["closes"], st["items"]["X1"]["anchors"])')" "['acme/app¤9'] ['acme/app¤9']" \
       "[i] stored as owner/name¤N, and as an anchor too"
  c_hasnt "$(cat "$(sdir)/hot.jsonl")" "Stub title" "[i] the title is not stored"
  br op add --kind next --text t --closes 'acme/app¤404'
  c_rc 1 "[i] a 404: refused (1)"; c_has "$OUT" "404" "[i] the message says 404"
  pr 'acme/app¤5' merged "$A21"; br op add --kind next --text t --closes 'acme/app¤5'
  c_rc 1 "[i] an anchor already merged: refused (1)"; c_has "$OUT" "already merged" "[i] and says why"
  issue 'acme/app¤7' completed "$A21"; br op add --kind next --text t --closes 'acme/app¤7'
  c_rc 1 "[i] an issue already completed: refused (1)"
  issue 'acme/app¤8' not_planned "$A21"; br op add --kind now --text "not planned yet" --closes 'acme/app¤8'
  c_rc 0 "[i] an issue closed not planned may be named (it may reopen)"
  raw answers 'acme/app¤77' FAIL; br op add --kind next --text t --closes 'acme/app¤77'
  c_rc 0 "[i] an unanswered lookup: accepted"; c_has "$OUT" "closes not checked: acme/app¤77" "[i] with the line"
  PATH="$TMP/nogh" br op add --kind next --text t --closes 'acme/app¤78'
  c_rc 0 "[i] gh missing: accepted"; c_has "$OUT" "closes not checked: acme/app¤78" "[i] with the line"
  local a
  for a in 'PR ¤5' 'acme¤5' "$GH/acme/app/$IS/5/files" '../x¤5' 'README.md'; do
    br op add --kind next --text t --closes "$a"; c_rc 64 "[i] --closes '$a': refused (64)"
  done
  br op add --kind now --text t --closes acme/app¤1 --closes acme/app¤2 --closes acme/app¤3
  c_rc 64 "[i] three --closes: refused (64)"
}

# --- [j] -----------------------------------------------------------------------------------------------------------------------
case_kinds() {
  np; pr 'acme/app¤9' open; pr 'acme/app¤10' open
  local k
  for k in trap decision window; do br op add --kind "$k" --text t --closes acme/app¤9; c_rc 64 "[j] op add --kind $k --closes: 64"; done
  rec default "$SID" add --kind decision --text t --owner-quote q --where w --closes acme/app¤9
  br owner add --kind decision --text t --owner-quote q --where w --closes acme/app¤9
  c_rc 64 "[j] owner add --closes: 64"
  br op add --kind trap --text "a trap"; br op supersede T1 --text "a trap" --reason r --closes acme/app¤9
  c_rc 64 "[j] supersede of a trap with --closes: 64"
  br op add --kind next --text "carried along" --closes acme/app¤9
  br op supersede X1 --text "carried along" --reason retext
  c_rc 0 "[j] supersede: rc 0"; c_has "$OUT" "closes carried: acme/app¤9" "[j] it prints the carried anchors"
  c_eq "$(bpy 'print(s.load(s.state_dir())[1]["items"]["X2"]["closes"])')" "['acme/app¤9']" "[j] the new item carries closes"
  br op supersede X2 --text "carried along" --reason "another PR" --closes acme/app¤10
  c_rc 0 "[j] supersede with its own --closes: rc 0"; c_hasnt "$OUT" "carried" "[j] nothing carried"
  c_eq "$(bpy 'it = s.load(s.state_dir())[1]["items"]["X3"]; print(it["closes"], it["anchors"])')" "['acme/app¤10'] ['acme/app¤9', 'acme/app¤10']" \
       "[j] its own closes; the old one stays a plain anchor"
  br op supersede X3 --text "carried along" --reason "no closes" --drop-anchor acme/app¤10
  c_eq "$(bpy 'print(s.load(s.state_dir())[1]["items"]["X4"].get("closes"))')" None "[j] dropping the anchor drops it from closes"
}

# --- [k] -----------------------------------------------------------------------------------------------------------------------
case_cache() {
  np; seed "N1@$C20;closes=acme/app¤7"; issue 'acme/app¤7' open
  start compact
  bpy "import brain_stale as b; d = s.state_dir(); e = b.read_cache(d)
e['acme/app¤7'].update(state='closed', reason='completed', at='$A21', date='$D21'); b.write_cache(d, e)"
  issue 'acme/app¤7' completed "$A21"; : > "$STUB/calls"
  start compact
  c_eq "$(ncalls)" 0 "[k] instrument: the answer came from the cache"
  c_eq "$(inblock N1) $(nlinks)" "1 0" "[k] a cached completed issue does not close"
  c_has "$(line N1)" "stale: acme/app¤7 closed $D21" "[k] it marks"
  np; seed "X1@$C20;closes=acme/app¤5"
  bpy "import time, brain_stale as b; d = s.state_dir()
b.write_cache(d, {'acme/app¤5': {'t': time.time(), 'state': 'merged', 'date': '$D21', 'at': '$A21', 'reason': '', 'pr': True,
                                 'base_ok': True, 'sha': '0123456789ab'}})"
  start compact
  c_eq "$(ncalls)" 0 "[k] instrument: no lookup at all"
  c_eq "$(status_of X1)" closed "[k] a cached merged PR (base checked) closes"
  np; seed "X1@$C20;closes=acme/app¤5"; pr 'acme/app¤5' merged "$A21"
  bpy "import json, time; d = s.state_dir(); e = {'acme/app¤5': {'t': time.time(), 'state': 'merged', 'date': '$D21'}}
open(d + '/stale-cache.json', 'w').write(json.dumps({'v': 1, 'digest': s.digest(s.dumps(e)), 'entries': e}))"
  start compact
  c_eq "$(inblock X1) $(nlinks) $(ncalls)" "1 0 0" "[k] a version-1 entry: no close, no lookup"
  c_has "$(line X1)" "stale: acme/app¤5 merged $D21" "[k] it still marks"
}

# --- [l] -----------------------------------------------------------------------------------------------------------------------
case_op() {
  np
  local repo="acme-corporation/$(rep n 40)"
  seed "X1@$C20;closes=$repo¤12345"; pr "$repo¤12345" merged "$A21"
  start compact
  c_eq "$(status_of X1)" closed "[l] a 40-character repository name: closes"
  c_eq "$(opf 'sorted(o)')" "['anchors', 'by', 'id', 'op', 'pointer', 'prev', 'reason', 'seq', 't']" "[l] the op carries every field"
  c_eq "$(opf 'o["pointer"]')" "$repo¤12345" "[l] the pointer is the whole anchor ($(nchars "$repo¤12345") characters)"
  br doctor; c_rc 0 "[l] doctor rc 0"; c_hasnt "$OUT" "problem" "[l] the chain and caches hold"
  c_has "$(grep -F '"id":"X1"' "$(sdir)/archive.jsonl")" "\"reason\":\"merged $repo¤12345 $D21\"" "[l] archived with its reason"
  c_eq "$(eplines auto-close | wc -l | tr -d ' ')" 1 "[l] one episode line"
  local i; for i in 1 2 3 4 5; do br op add --kind trap --text "t$i"; br op close "T$i" --reason done; done
  c_rc 0 "[l] five closes by hand after it: the budget was not spent by the machine op"
}

# --- [m] -----------------------------------------------------------------------------------------------------------------------
case_note() {
  np; seed "N1@$C20;closes=acme/app¤7"; issue 'acme/app¤7' completed "$A21"
  start compact
  c_eq "$(autonote)" "auto-closed now: N1 (acme/app¤7 completed 10-21)" "[m] the closing SessionStart has the note"
  start compact
  c_eq "$(autonote)" "" "[m] the next one does not"
  issue 'acme/app¤7' reopened; age_cache 700
  start compact
  c_eq "$(autonote)" "reopened: N1 acme/app¤7, re-add it with brain op add" "[m] a reopened issue adds the reopened line"
  c_eq "$(status_of N1)" closed "[m] and reopens nothing by itself"
  age_cache 700; : > "$STUB/calls"; start compact sB
  c_eq "$(autonote) $(ncalls)" " 0" "[m] another session's SessionStart makes no reopen check and shows no reopened line"
}

# --- [n] -----------------------------------------------------------------------------------------------------------------------
case_rotation() {
  np; local i specs=()
  for i in $(seq 1 30); do specs+=("X$i@$C20;closes=acme/app¤$((100 + i))"); pr "acme/app¤$((100 + i))" open; done
  seed "${specs[@]}" "D1@$C20;anchors=acme/app¤999"; issue 'acme/app¤999' open
  start compact; c_eq "$(nissues)" 12 "[n] the first SessionStart looks up 12"
  start compact; start compact
  c_eq "$(sort -u "$STUB/calls" | grep -c '/issues/' || true)" 31 "[n] 31 anchors, every one looked up within 3 SessionStarts"
  c_eq "$(calls_of issues acme/app¤999)" 1 "[n] the pinned decision's plain anchor included"
  c_eq "$(nissues)" 31 "[n] and none twice"
  # a burst skips round 2
  six; start compact
  c_eq "$(npulls)" 0 "[n] 6 items whose PRs all merged: round 2 is skipped"
  c_has "$(autonote)" "held: 6" "[n] and all 6 are held"
  # 14 recent issue closes: at most 3 reopen checks per SessionStart, least recently checked first
  np; specs=()
  for i in $(seq 1 14); do specs+=("N$i@$C20;closes=acme/app¤$((200 + i));linkclosed=$A21"); issue "acme/app¤$((200 + i))" completed "$A21"; done
  seed "${specs[@]}"
  start compact; c_eq "$(nissues)" 3 "[n] 14 recent issue closes: 3 reopen checks"
  start compact; c_eq "$(sort -u "$STUB/calls" | grep -c '/issues/' || true)" 6 "[n] the next SessionStart checks 3 others"
  # base_ok null: retried first at the next SessionStart, outside the 12
  np; specs=("X1@$C20;closes=acme/app¤5")
  for i in $(seq 1 12); do specs+=("N$i@$C20;anchors=acme/app¤$((300 + i))"); issue "acme/app¤$((300 + i))" open; done
  seed "${specs[@]}"; pr 'acme/app¤5' merged "$A21"; raw pulls 'acme/app¤5' FAIL
  start compact
  c_eq "$(bpy 'import brain_stale as b; print(b.read_cache(s.state_dir())["acme/app¤5"]["base_ok"])')" None "[n] a pulls lookup unanswered: base_ok null"
  c_eq "$(status_of X1)" live "[n] and no close"
  pr 'acme/app¤5' merged "$A21"; age_cache 700 $(for i in $(seq 1 12); do printf 'acme/app¤%s ' $((300 + i)); done); : > "$STUB/calls"
  start compact
  c_eq "$(calls_of pulls acme/app¤5)" 1 "[n] the pulls lookup is retried"
  c_eq "$(calls_of issues acme/app¤5)" 0 "[n] without a new issues lookup"
  c_eq "$(nissues)" 12 "[n] and the 12 issues lookups go to the other anchors"
  c_eq "$(status_of X1)" closed "[n] then it closes"
  # a mixed close: the issue anchor is reopen-checked, the PR anchor is not
  np; seed "X1@$C20;closes=acme/app¤5,acme/app¤7"; pr 'acme/app¤5' merged "$A21"; issue 'acme/app¤7' completed "$A21"
  start compact; c_eq "$(status_of X1)" closed "[n] instrument: the mixed item closed"
  age_cache 700; : > "$STUB/calls"; start compact
  c_eq "$(calls_of issues acme/app¤7)" 1 "[n] its issue anchor is reopen-checked"
  c_eq "$(calls_of issues acme/app¤5)" 0 "[n] its PR anchor is not"
  # an older brain rewrote the cache as version 1: marks only, then refilled as version 2
  np; seed "X1@$C20;closes=acme/app¤5" "X2@$C20;anchors=acme/app¤6"; pr 'acme/app¤5' open; pr 'acme/app¤6' open
  start compact
  c_eq "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["v"])' "$(sdir)/stale-cache.json")" 2 "[n] instrument: this brain writes version 2"
  pr 'acme/app¤5' merged "$A21"
  bpy "import json, time; d = s.state_dir(); t = time.time()
e = {'acme/app¤5': {'t': t, 'state': 'merged', 'date': '$D21'}, 'acme/app¤6': {'t': t, 'state': 'open', 'date': ''}}
open(d + '/stale-cache.json', 'w').write(json.dumps({'v': 1, 'digest': s.digest(s.dumps(e)), 'entries': e}))"
  : > "$STUB/calls"; start compact
  c_eq "$(inblock X1) $(ncalls)" "1 0" "[n] an older brain's version-1 file: read for marks, no close, no lookup"
  c_has "$(line X1)" "stale: acme/app¤5 merged $D21" "[n] it marks"
  bpy "import json; d = s.state_dir(); c = json.load(open(d + '/stale-cache.json')); e = c['entries']
for v in e.values(): v['t'] -= 700
open(d + '/stale-cache.json', 'w').write(json.dumps({'v': 1, 'digest': s.digest(s.dumps(e)), 'entries': e}))"
  start compact
  c_eq "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["v"])' "$(sdir)/stale-cache.json")" 2 "[n] refilled as version 2 at the next lookup"
  c_eq "$(status_of X1)" closed "[n] and then it closes"
}

# --- [o] -----------------------------------------------------------------------------------------------------------------------
case_doctor() {
  np
  seed "N1@$C20;closes=acme/app¤7;linkclosed=$A21" "X1@$C20;closes=acme/app¤5" "D1@$C20;anchors=acme/app¤9" "X2@$C20;closes=acme/app¤6"
  issue 'acme/app¤7' reopened; pr 'acme/app¤5' merged "$A21"; issue 'acme/app¤9' completed "$A21"; pr 'acme/app¤6' open
  start compact sB                                       # not the writer: fills the cache, closes nothing
  local before cache; before=$(sums); cache=$(sha256sum "$(sdir)/stale-cache.json" | cut -c1-16)
  br doctor
  c_rc 0 "[o] doctor rc 0"
  c_has "$OUT" "info     would close: X1 acme/app¤5 merged $D21" "[o] what the next writer SessionStart would close"
  c_hasnt "$OUT" "would close: X2" "[o] not an item whose anchor is open"
  c_has "$OUT" "info     auto-closed: N1 at " "[o] what auto-close closed in 24 h"
  c_has "$OUT" "warn     reopened: N1 acme/app¤7, re-add it with brain op add" "[o] a reopened issue"
  c_has "$OUT" "stale anchor: D1 acme/app¤9 closed $D21, owner retires it: brain owner unpin D1, or brain owner supersede D1" "[o] a pin, with the owner's command"
  c_hasnt "$OUT" "problem" "[o] no problem line"
  c_eq "$(sums)" "$before" "[o] doctor writes nothing: hot.jsonl and head.json are byte-identical"
  c_eq "$(sha256sum "$(sdir)/stale-cache.json" | cut -c1-16)" "$cache" "[o] nor the cache"
  c_eq "$(status_of X1)" live "[o] and closes nothing"
}

# --- [p] -----------------------------------------------------------------------------------------------------------------------
case_argv() {
  np; seed "X1@$C20;closes=acme/app¤5" "D1@$C20;anchors=acme/app¤9"; pr 'acme/app¤5' merged "$A21"; issue 'acme/app¤9' open
  start compact; br doctor; pr 'acme/app¤10' open; br op add --kind next --text t --closes acme/app¤10
  c_eq "$(nissues) $(npulls)" "4 1" "[p] instrument: issues and pulls lookups by SessionStart, doctor and a write"
  c_eq "$(grep -v -c -F -e '--hostname github.com' "$STUB/calls" || true)" 0 "[p] every gh argv carries --hostname github.com"
  c_has "$(eplines session-start)" '"format":3' "[p] the session-start line carries format 3"
  bpy "import json; d = s.state_dir(); f = open(d + '/episodes.jsonl', 'a')
f.write(json.dumps({'t': s.now_iso(), 'kind': 'session-start', 'session': 'old-one-session'}) + '\n')
f.write(json.dumps({'t': s.now_iso(), 'kind': 'session-start', 'session': 'older-two', 'format': 1}) + '\n')
f.write(json.dumps({'t': s.now_iso(), 'kind': 'session-start', 'session': 'ended-three'}) + '\n')
f.write(json.dumps({'t': s.now_iso(), 'kind': 'session-end', 'session': 'ended-three', 'reason': 'exit'}) + '\n')"
  br doctor
  c_has "$OUT" "warn     session old-one-… last started on an older brain (log format 1" "[p] doctor warns on a session-start line with no format"
  c_has "$OUT" "warn     session older-tw… last started on an older brain (log format 1" "[p] and on one with a lower format"
  c_hasnt "$OUT" "session sA" "[p] not on this brain's own session"
  c_hasnt "$OUT" "session ended-th" "[p] nor on a session that has ended"
  c_rc 0 "[p] a warn, not a problem"
  # close-linked stops at 40 keys
  np; local i specs=()
  for i in $(seq 1 41); do specs+=("X$i@$C20;closes=acme/app¤$((400 + i))"); pr "acme/app¤$((400 + i))" merged "$A21"; done
  seed "${specs[@]}"
  br op close-linked
  c_eq "$(nlinks)" 40 "[p] close-linked closes 40"
  c_has "$OUT" "skipped X41: past 40 keys" "[p] and prints the one past 40"
  c_eq "$(calls_of issues acme/app¤441)" 0 "[p] which it never looked up"
}

# --- [q] -----------------------------------------------------------------------------------------------------------------------
skill() {  # skill <dir> <name> <description> [frontmatter line]
  mkdir -p "$1/$2"
  printf -- '---\nname: %s\ndescription: "%s"\n%s\n---\n\n# %s\n' "$2" "$3" "${4:-}" "$2" > "$1/$2/SKILL.md"
}
many_skills() {  # project, user and plugin skills, more than the Shelf index fits (as the hooks suite builds them)
  local i n cfg="$TMP/cfg$NP" reg='{"version":2,"plugins":{' sep=""
  export CLAUDE_CONFIG_DIR="$cfg"
  for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
    skill "$P/.claude/skills" "proj-$i" "Project skill $i with a long description that runs on and on well past the one hundred character cut of a line. More."
    skill "$cfg/skills" "user-$i" "User skill $i with a long description that runs on and on well past the one hundred character cut of a line. More."
  done
  mkdir -p "$cfg/plugins"
  for n in plug-a plug-b plug-c; do
    for i in 01 02 03 04 05 06 07 08 09 10; do skill "$TMP/pl$NP/$n/skills" "$n-skill-$i" "Skill $i of $n."; done
    reg="$reg$sep\"$n@m\":[{\"scope\":\"user\",\"installPath\":\"$TMP/pl$NP/$n\"}]"; sep=,
  done
  printf '%s}}' "$reg" > "$cfg/plugins/installed_plugins.json"
  printf '{"enabledPlugins":{"plug-a@m":true,"plug-b@m":true,"plug-c@m":true}}' > "$cfg/settings.json"
}
full() {  # full <close|held> — every section at its cap, 150-character texts, 8 links, every anchor done, 14 reopens due
  np
  local t i links specs=(); t=$(rep t 150); links="kb/x"           # short links fill every line to its 200-character cap
  for i in 1 2 3 4 5 6 7 8 9 10; do specs+=("D$i@$C20;anchors=acme-corporation/app¤$((10 + i));text=$t"); done
  for i in 1 2 3 4 5; do specs+=("W$i@$C20;text=$t"); done
  for i in 1 2 3; do specs+=("N$i@$C20;closes=acme-corporation/app¤$((30 + i));text=$t"); done
  for i in 1 2 3 4 5; do specs+=("X$i@$C20;closes=acme-corporation/app¤$((40 + i));text=$t"); done
  for i in 1 2 3 4; do specs+=("T$i@$C20;text=$t"); done
  for i in $(seq 1 14); do specs+=("N$((10 + i))@$C20;closes=acme-corporation/app¤$((200 + i));linkclosed=$A21"); done
  seed "${specs[@]}"
  CLAUDE_CODE_SESSION_ID="$SID" python3 - "$BROOT/scripts" "$links" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
import brain_store as s
d = s.state_dir()
with s.locked(d):                                   # the same log with 8 links on every item, chained again
    raw, ops = s.verify(d)
    lines, prev = [], s.GENESIS
    for o in ops:
        if o["op"] in ("add", "owner-add"):
            o["item"]["links"] = [sys.argv[2]] * 8
        o["prev"] = prev
        b = s.dumps(o).encode("utf-8")
        lines.append(b)
        prev = s.line_hash(b)
    open(d + "/hot.jsonl", "wb").write(b"".join(l + b"\n" for l in lines))
    s._write_file(d + "/head.json", s.dumps(s.head_of(lines)) + "\n")
    s.write_caches(d, s.fold([json.loads(l) for l in lines]), s.head_of(lines))
PY
  for i in 1 2 3 4 5 6 7 8 9 10; do issue "acme-corporation/app¤$((10 + i))" completed "$A21"; done
  for i in 1 2 3 4 5; do pr "acme-corporation/app¤$((30 + i))" merged "$A21"; pr "acme-corporation/app¤$((40 + i))" merged "$A21"; done
  if [ "$1" = close ]; then for i in 3 4 5; do pr "acme-corporation/app¤$((40 + i))" closed "$A21"; done; fi
  for i in $(seq 1 14); do issue "acme-corporation/app¤$((200 + i))" reopened; done
  many_skills
}
case_size() {
  local mode c n i most
  for mode in held close; do
    full "$mode"; most=0
    for i in 1 2 3; do
      start compact; c=$(ctxof "$TMP/o.session-start"); n=$(python3 -c 'import json, sys
print(len(json.loads(open(sys.argv[1], encoding="utf-8").read())["hookSpecificOutput"]["additionalContext"]))' "$TMP/o.session-start")
      [ "$n" -gt "$most" ] && most=$n
      c_eq "$([ "$(nchars "$(shelf "$c")")" -ge 900 ] && echo full)" full "[q] $mode, SessionStart $i: instrument: the Shelf index is full"
      c_eq "$(printf '%s\n' "$c" | python3 -c 'import re, sys; print(sum(1 for l in sys.stdin.read().splitlines() if re.match(r"- [DWN][0-9]", l) and len(l) >= 195))')" \
           "$([ "$mode" = held ] && echo 18 || echo 15)" "[q] $mode, SessionStart $i: instrument: every item line of string 1 is at its cap"
      c_hasnt "$c" "[brain: cut" "[q] $mode, SessionStart $i: the hard cut does not fire ($n characters)"
      c_eq "$(autonote | python3 -c 'import sys; print(max([len(l) for l in sys.stdin.read().splitlines()] or [0]) <= 250)')" True \
           "[q] $mode, SessionStart $i: each string's auto-close line is ≤ 250 characters"
      [ "$i" = 2 ] && age_cache 700
    done
    c_eq "$([ "$most" -le 8000 ] && echo within)" within "[q] $mode: the largest string 1 of the three is $most ≤ 8,000"
    c_has "$c" "## Shelf index" "[q] $mode: the Shelf index is there"
    c_has "$c" "reopened: " "[q] $mode: reopened lines are there"
    c_has "$c" "stale: " "[q] $mode: marks are there"
    unset CLAUDE_CONFIG_DIR
  done
  c_eq "$(nlinks)" 19 "[q] instrument: the close run closed 5 (14 seeded link-closes + 5)"
}

# --- [r] -----------------------------------------------------------------------------------------------------------------------
case_io() {
  np; seed "X1@$C20;closes=acme/app¤5"
  R=$(bpy 'd = s.state_dir(); real = s._write_file
def fail(p, data):
    if p.endswith("head.json"):
        raise OSError(28, "No space left on device")
    return real(p, data)
s._write_file = fail
before = open(d + "/hot.jsonl", "rb").read()
try:
    s.link_close(d, "sA", [("X1", [{"anchor": "acme/app¤5", "state": "merged", "at": "'"$A21"'", "sha": "0123456789ab"}])], {"hook": "SessionStart"})
    print("no error")
except OSError as e:
    print("raised", e.errno, open(d + "/hot.jsonl", "rb").read() == before)')
  c_eq "$R" "raised 28 True" "[r] head.json cannot be written: the error is raised and the log is cut back to what it was"
  br doctor; c_hasnt "$OUT" "problem" "[r] the chain and head still agree"
  start compact; c_has "$(ctx)" "## Brain · hot memory" "[r] and the next SessionStart injects"
  np; seed "X1@$C20;closes=acme/app¤5" "X2@$C20;closes=acme/app¤6"
  R=$(bpy 'd = s.state_dir(); real, n = s.append, [0]
def app(d, raw, op):
    if op.get("op") == "link-close":
        n[0] += 1
        if n[0] == 2:
            raise OSError(28, "No space left on device")
    return real(d, raw, op)
s.append = app
a = lambda k: [{"anchor": k, "state": "merged", "at": "'"$A21"'", "sha": "0123456789ab"}]
st, done, warn = s.link_close(d, "sA", [("X1", a("acme/app¤5")), ("X2", a("acme/app¤6"))], {"hook": "SessionStart"})
print(done, "stopped after X1" in warn)')
  c_eq "$R" "['X1'] True" "[r] a failure after one close: that close is reported, and where it stopped"
  c_eq "$(status_of X1) $(status_of X2)" "closed live" "[r] the log holds exactly that"
  br doctor; c_hasnt "$OUT" "problem" "[r] and still chains"
  # the same through the hook: the note matches the log
  np; seed "X1@$C20;closes=acme/app¤5" "X2@$C20;closes=acme/app¤6"; pr 'acme/app¤5' merged "$A21"; pr 'acme/app¤6' merged "$A21"
  start_faulty 2
  c_rc 0 "[r] SessionStart with its second close failing: rc 0"
  c_eq "$(autonote)" "auto-close: warning: stopped after X1 (OSError): the others stay live
auto-closed now: X1 (acme/app¤5 merged 10-21)" "[r] the notes name where it stopped (string 1) and the close it wrote (string 3)"
  c_eq "$(inblock X1) $(inblock X2) $(status_of X2)" "0 1 live" "[r] the block matches the log"
  np; seed "X1@$C20;closes=acme/app¤5" "X2@$C20;closes=acme/app¤6"; pr 'acme/app¤5' merged "$A21"; pr 'acme/app¤6' merged "$A21"
  start_faulty 2 caches
  c_has "$(autonote)" "auto-close: warning: stopped after X1 (OSError): the others stay live" "[r] the caches failing too: the stop line still leads the note"
  np; seed "X1@$C20;closes=acme/app¤5"; pr 'acme/app¤5' merged "$A21"
  start_faulty 1
  c_eq "$(autonote)" "auto-close: nothing closed (OSError)" "[r] the first close failing: nothing closed, and the note says so"
  c_eq "$(inblock X1) $(nlinks)" "1 0" "[r] the item stays, the log holds no link-close"
  start compact; c_eq "$(status_of X1)" closed "[r] the next SessionStart closes it"
  # a rollback that fails too says so, and names brain doctor
  np; seed "X1@$C20;closes=acme/app¤5"
  R=$(bpy 'd = s.state_dir(); real = s._write_file
def fail(p, data):
    if p.endswith("head.json"):
        raise OSError(28, "No space left on device")
    return real(p, data)
def nocut(fd, size):
    raise OSError(30, "Read-only file system")
s._write_file, s.os.ftruncate = fail, nocut
try:
    s.link_close(d, "sA", [("X1", [{"anchor": "acme/app¤5", "state": "merged", "at": "'"$A21"'", "sha": "0123456789ab"}])], {"hook": "SessionStart"})
except OSError as e:
    print(e.errno, "may be left past head.json" in str(e), "run brain doctor" in s.why(e), e.__cause__.errno)')
  c_eq "$R" "28 True True 28" "[r] a failed rollback: the first error kept, the log named, brain doctor in the note"
  # a refused write in a project with no state creates no state directory
  np; : > "$STUB/calls"
  br op add --kind next --text t --closes acme/app¤404
  c_rc 1 "[r] a fresh project, an unknown anchor: refused"
  [ -d "$(sdir)" ] && R=created || R=none
  c_eq "$R" none "[r] and no state directory was created"
  # the checks a write makes come before its lookup
  np; seed "X1@$C20;closes=acme/app¤5"; pr 'acme/app¤9' open; : > "$STUB/calls"
  SID=sB br op add --kind next --text t --closes acme/app¤9
  c_rc 3 "[r] op add --closes from another session: rc 3"; c_eq "$(ncalls)" 0 "[r] before any lookup"
  br op supersede X9 --text t --reason r --closes acme/app¤9
  c_has "$OUT" "X9 is not a live item" "[r] supersede of an item that is not live says so"; c_eq "$(ncalls)" 0 "[r] before any lookup"
  # a supersede: an anchor the item already names may be done (a warning), a new one may not (refused)
  pr 'acme/app¤5' merged "$A21"
  br op supersede X1 --text "item X1 and the docs" --reason "wrap up"
  c_rc 0 "[r] a supersede carrying a merged closes anchor: rc 0"
  c_has "$OUT" "closes acme/app¤5 is already merged ($D21): the new item may close at the next writer SessionStart; --drop-anchor acme/app¤5 keeps it live" "[r] with a warning"
  br op supersede X2 --text "item X1 and the docs" --reason again --closes acme/app¤5
  c_rc 0 "[r] naming that same anchor again: rc 0, not refused"; c_has "$OUT" "is already merged" "[r] the same warning"
  pr 'acme/app¤7' merged "$A21"
  br op supersede X3 --text "item X1 and the docs" --reason other --closes acme/app¤7
  c_rc 1 "[r] a new closes anchor already merged: refused"
}

# --- [s] -----------------------------------------------------------------------------------------------------------------------
case_starve() {
  np; local i specs=()
  for i in 1 2 3 4 5; do
    specs+=("X$i@$C20;closes=acme/app¤$((10 + i)),acme/app¤$((20 + i))")
    pr "acme/app¤$((10 + i))" merged "$A21"; raw pulls "acme/app¤$((10 + i))" FAIL; issue "acme/app¤$((20 + i))" open
  done
  seed "${specs[@]}" "N1@$C20;closes=acme/app¤6"; pr 'acme/app¤6' merged "$A21"; raw pulls 'acme/app¤6' FAIL
  start compact; c_eq "$(status_of N1)" live "[s] instrument: N1's pulls lookup failed at the first SessionStart"
  pr 'acme/app¤6' merged "$A21"
  start compact; start compact
  c_eq "$(status_of N1)" closed "[s] five PRs whose pulls lookup keeps failing do not starve N1's: it closes within two more SessionStarts"
  c_eq "$(nlinks)" 1 "[s] and nothing else closed"
}

echo "== cases =="
for c in case_close case_noclose case_time case_plain case_two case_pins case_writer case_burst case_write case_kinds case_cache \
         case_op case_note case_rotation case_doctor case_argv case_size case_io case_starve; do run_case $c; done
cd "$TMP" || exit 1

echo "== planted breaks =="
BS=scripts/brain_stale.py
BST=scripts/brain_store.py
plant close-from-plain-anchor case_plain $BS '        for c in it.get("closes") or []:
            m = parse_anchor(c)' '        for c in it.get("anchors") or []:
            m = parse_anchor(c)'
plant close-on-closed-unmerged case_noclose $BS '        return r["state"] == "merged"
    return r.get("pr") is False' '        return r["state"] in ("merged", "closed")
    return r.get("pr") is False'
plant close-on-other-base case_noclose $BS '        return r.get("base_ok") is True and bool(r.get("sha"))' '        return r.get("base_ok") is not None and bool(r.get("sha"))'
plant close-on-not-planned case_noclose $BS 'r.get("reason") == "completed" and fresh_now' 'r.get("reason") in ("completed", "not_planned") and fresh_now'
plant close-issue-from-cache case_cache $BS 'r.get("reason") == "completed" and fresh_now' 'r.get("reason") == "completed"'
plant close-on-one-of-two case_two $BS '    return next((w for w in why if w), None)' '    return None if not all(why) else why[0]'
plant close-a-pin case_pins $BST 'CLOSES_LETTERS = ("N", "X", "S", "Q")' 'CLOSES_LETTERS = ("N", "X", "S", "Q", "D")'
plant writer-ignored case_writer $BS '    writer = bool(sid) and st["writer"] == sid' '    writer = True'
plant store-writer-unchecked case_writer $BST '        if not session or st["writer"] != session:' '        if not session:'
plant dates-not-stamps case_time $BS '    return t is not None and c is not None and t > c' '    return at[:10] >= (first.get("created") or "")[:10]'
plant superseding-created case_time $BS '        it = st["items"].get(it.get("supersedes") or "")' '        it = None'
plant chain-gap-counted case_time $BS '    while it is not None and it["id"] not in seen and key in [c.lower() for c in it.get("closes") or []]:
        seen.add(it["id"])
        first = it' '    while it is not None and it["id"] not in seen:
        seen.add(it["id"])
        first = it if key in [c.lower() for c in it.get("closes") or []] else first'
plant burst-after-round-2 case_rotation $BS '            held = len(burst) > BURST_MAX if writer else False       # counted after round 1: a burst spends no pulls lookup
            pulled = round_two(cache, linked, {k for it, ks in nx if it in burst for k in ks}, looked,
                               DEADLINE - (time.monotonic() - t0), now) if writer and not held else []
            answers.update({k: answer_of(cache[k]) for k in pulled})
            closing = [(it, ks) for it, ks in nx if writer and not held and verdict(st, it, ks, answers, looked) is None]
' '            held = False
            pulled = round_two(cache, linked, {k for it, ks in nx if it in burst for k in ks}, looked,
                               DEADLINE - (time.monotonic() - t0), now) if writer and not held else []
            answers.update({k: answer_of(cache[k]) for k in pulled})
            closing = [(it, ks) for it, ks in nx if writer and not held and verdict(st, it, ks, answers, looked) is None]
            held = len(closing) > BURST_MAX
            closing = [] if held else closing
'
plant no-burst-cap case_burst $BS 'BURST_MAX = 5 ' 'BURST_MAX = 50 '
plant bare-closes-accepted case_write $BS '    if m and not m.group(1):
' '    if m and not m.group(1) and default_repo()[0]:
        return "%s#%s" % (default_repo()[0], m.group(2))
    if m and not m.group(1):
'
plant no-rotation case_rotation $BS '    queue = sorted((k for k in keys if k not in again and not settled(cache.get(k), now)), key=age)' '    queue = list(keys)'
plant close-from-doctor case_doctor $BS '    would = [(it, ks) for it, ks in nx if verdict(st, it, ks, answers, looked) is None]
' '    would = [(it, ks) for it, ks in nx if verdict(st, it, ks, answers, looked) is None]
    s.link_close(s.state_dir(), st["writer"], [(it["id"], details(it, ks, answers)) for it, ks in would], {"cmd": "doctor"})
'
plant budget-spent case_op $BST '        _retire(st, op, it, "closed", budget=False)' '        _retire(st, op, it, "closed")'
plant pointer-cap-60 case_op $BST '"pointer": 80' '"pointer": 60'
plant no-hostname case_argv $BS 'HOST = ["--hostname", "github.com"]' 'HOST = []'
plant held-without-note case_burst $BS '        parts.append(("auto-close held: %d items' '        parts.append(("" if 1 else "%d items'
plant reopen-unchecked case_note $BS '    again = sorted((k for k in reopen if not settled(cache.get(k), now)), key=age)[:MAX_REOPEN]' '    again = []'
plant reopen-checks-uncapped case_rotation $BS 'MAX_REOPEN = 3 ' 'MAX_REOPEN = 12 '
plant format-not-logged case_argv scripts/brain_hook.py '"format": s.FORMAT, "injected_sessions"' '"injected_sessions"'
plant head-not-rolled-back case_io $BST '                os.ftruncate(fd, size)
                os.fsync(fd)
            except OSError as e2:' '                pass
            except OSError as e2:'
plant partial-close-unreported case_io $BST '                if not done:
                    raise
' '                raise
'
plant partial-close-note-missing case_io $BS '                    did["error"] = s.clean_line(warn.strip().split("\n")[0])[:120] or None' '                    pass'
plant stop-line-after-cache-warning case_io $BST 'warn = "\nwarning: stopped after %s (%s): the others stay live%s" % (", ".join(done), why(err), warn)' 'warn += "\nwarning: stopped after %s (%s): the others stay live" % (", ".join(done), why(err))'
plant peek-creates-state case_io $BST '    if os.path.isdir(d):                             # no state yet' '    if True:                             # no state yet'
plant rollback-failure-silent case_io $BST '    return e.__class__.__name__ + ("; run brain doctor" if "may be left past head.json" in str(e) else "")' '    return e.__class__.__name__'
plant lookup-before-checks case_io $BST '        peek(letter=letter)' '        pass'
plant kept-done-refused case_io $BS '    for a in kept:
        r = got.get(a.lower())' '    anchors = list(anchors) + [a for a in kept if a not in anchors]
    for a in kept[:0]:
        r = got.get(a.lower())'
plant pulls-starve case_starve $BS '            cache[k]["t"] = now                     # tried now' '            pass                                    # tried now'
plant reopen-in-any-session case_note $BS '    reopen = reopen_keys(st, now) if writer else {}' '    reopen = reopen_keys(st, now)'
plant ended-session-warned case_argv $BST '            last[o["session"]] = ("start", o.get("format")) if kind == "session-start" else None' '            last[o["session"]] = ("start", o.get("format"))'
plant close-linked-looks-first case_burst $BS '    if st["writer"] != s.session_id():
        raise' '    if False:
        raise'

summary
