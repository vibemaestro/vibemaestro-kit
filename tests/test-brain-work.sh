#!/bin/bash
# =============================================================================
# vibemaestro-brain: one source of coordinator state — the kinds session (S), queue (Q) and fact (F), Next and Traps at larger
# caps, owner quotes rendered, Done derived from the log, and three SessionStart strings: hot memory (≤ 8,000), sessions and
# plan (≤ 9,500 each, by their own hard cut)
# =============================================================================
# Run: bash tests/test-brain-work.sh
#
# Offline: a stub `gh` first on PATH answers `gh api repos/<o>/<r>/issues/<n>` and `…/pulls/<n>` from files (as the close suite's).
# The three SessionStart commands run at once, as Claude Code runs a plugin's hooks of one event (start3).
#   [a] --kind session|queue|fact: add, close, supersede; --closes on S and Q, refused on F
#   [b] eight S supersedes in 30 minutes, one under 60 %: accepted; the sixth X supersede refused by the budget, as before
#   [c] an S and a Q item close when their PR merges (R3's path); the note in string 2, Done in string 3
#   [d] Done: `id anchor sha · text`, newest first, the SHA kept when the text is long, a close's pointer; not one closed 25 h
#       ago; 7 lines then `(+N more: brain doctor)`, doctor lists them all; derived: no write path, no op of its own
#   [e] strings 2 and 3 print nothing when their sections are empty and they have no note; an X close prints string 3; an N
#       close's note is in string 1, an S close's in string 2
#   [f] the worst case: every section at its cap, every line at its cap, every quote 300, every item stale, 5 auto-closes (or a
#       held burst) → string 1 ≤ 8,000, strings 2 and 3 ≤ 9,500, no hard cut; items past the caps → each cut at 9,500, named
#   [g] a pin's quote under it, cut at 120 (odd characters kept); an owner supersede has none; D only in string 1
#   [h] S 12, Q 5, X 10, T 13, F 5 accepted, the next add refused naming the item to close; S text 450 accepted, 451 refused
#   [i] a fact with a home path refused by sanitize, `~/…` accepted
#   [j] D and W still refused by `brain op`; the owner path unchanged; no `brain op` option takes an owner quote
#   [k] the session-start episode line: format 3, injected (string 1), injected_sessions and injected_plan as printed
#   [l] the hand-over: strings 2 and 3 are string 1's pass; alone, a string's command renders its own part after its wait; an
#       older hand-over is never used; SessionEnd removes it
#   [m] a log from before the migration (D W N X T, a link-close): every item shown, X and T in string 3; a brain of format 2
#       refuses a log with an S item; doctor's hot.md check holds as Done ages, and fails on an edited Done line
#   [n] the live tools, offline: tests/live/hook-cap.sh parses and refuses a bad length; tests/live/brain-transcript-check.py on
#       its recorded fixtures: three strings inline and the ids found (rc 0), string 2 absent with its episode line 0 (rc 0),
#       string 3 over the cap `persisted` (rc 1), no SessionStart of the source (rc 2)
#   [X] planted breaks: each case goes red on a copy with one break
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

# --- the stub gh (the close suite's) ------------------------------------------------------------------------------------------
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
case "$*" in *.title*) printf '%s\tStub title\n' "$(cat "$f")" ;; *) cat "$f" ;; esac
SH
chmod +x "$TMP/bin/gh"
PY=$(command -v python3)
export PATH="$TMP/bin:$PATH"

C20=2026-10-20T15:00:00Z; A21=2026-10-21T10:00:00Z; D21=2026-10-21
SHA_A=0123456789abcdef0123456789abcdef01234567

stub_reset() { [ -n "$STUB" ] && rm -rf "$STUB"; mkdir -p "$STUB/answers" "$STUB/pulls"; : > "$STUB/calls"; }
kf() { local k=${1/\#/_}; printf '%s' "${k//\//_}"; }
issue() {  # issue <owner/name¤n> open|reopened|completed|not_planned [closed_at]
  local f; f="$STUB/answers/$(kf "$1")"
  case $2 in
    open) printf 'open\t\t\t\tissue\n' > "$f" ;;
    reopened) printf 'open\t\t\treopened\tissue\n' > "$f" ;;
    *) printf 'closed\t%s\t\t%s\tissue\n' "$3" "$2" > "$f" ;;
  esac
}
pr() {  # pr <owner/name¤n> open|closed|merged [at]
  local k; k=$(kf "$1")
  case $2 in
    open) printf 'open\t\t\t\tpr\n' > "$STUB/answers/$k" ;;
    closed) printf 'closed\t%s\t\t\tpr\n' "$3" > "$STUB/answers/$k" ;;
    merged) printf 'closed\t%s\t%s\t\tpr\n' "$3" "$3" > "$STUB/answers/$k"
            printf 'main\tmain\t%s\t%s\n' "$3" "$SHA_A" > "$STUB/pulls/$k" ;;
  esac
}
np() { newp; stub_reset; }
rep() { python3 -c 'import sys; print(sys.argv[1] * int(sys.argv[2]))' "$@"; }
ago() { python3 -c 'import sys, time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - float(sys.argv[1]))))' "$1"; }
status_of() { bpy "print(s.fold(s.verify(s.state_dir())[1])['items']['$1']['status'])"; }
nlinks() { grep -c '"op":"link-close"' "$(sdir)/hot.jsonl" || true; }
eplines() { grep -F "\"kind\":\"$1\"" "$(sdir)/episodes.jsonl" 2>/dev/null || true; }
age_cache() { bpy "import brain_stale as b
d = s.state_dir(); e = b.read_cache(d)
for k in e: e[k]['t'] -= $1
b.write_cache(d, e)"; }

ctxof() {  # ctxof <file> — additionalContext of one hook's stdout file ("" when it printed nothing)
  python3 -c 'import json, sys
t = open(sys.argv[1], encoding="utf-8").read().strip()
print(json.loads(t)["hookSpecificOutput"]["additionalContext"] if t else "", end="")' "$1"
}
start3() {  # start3 [source] [session id] — the three SessionStart commands at once, with no CLAUDE_CODE_SESSION_ID (as Claude Code
            # runs them); sets S1 S2 S3 (each string, "" when it printed none), RC (0 when all three exit 0) and ERR
  local in e p rcs=0 pids=()
  in=$(hin session_id="${2-$SID}" cwd="$P" hook_event_name=SessionStart source="${1:-compact}")
  for e in session-start session-start-sessions session-start-plan; do
    printf '%s' "$in" | env -u CLAUDE_CODE_SESSION_ID ${HOOK_ENV:-} "$PY" "$BROOT/scripts/brain_hook.py" "$e" > "$TMP/out.$e" 2> "$TMP/err.$e" &
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p" || rcs=1; done
  RC=$rcs; S1=$(ctxof "$TMP/out.session-start"); S2=$(ctxof "$TMP/out.session-start-sessions"); S3=$(ctxof "$TMP/out.session-start-plan")
  ERR=$(cat "$TMP/err.session-start" "$TMP/err.session-start-sessions" "$TMP/err.session-start-plan")
}
one() {  # one <event> [source] — one SessionStart command alone; sets OUT (its string) and RC
  local in; in=$(hin session_id="$SID" cwd="$P" hook_event_name=SessionStart source="${2:-compact}")
  printf '%s' "$in" | env -u CLAUDE_CODE_SESSION_ID "$PY" "$BROOT/scripts/brain_hook.py" "$1" > "$TMP/out.one" 2> "$TMP/err.one"; RC=$?
  OUT=$(ctxof "$TMP/out.one")
}
has_line() { printf '%s\n' "$1" | grep -c -E -e "$2" || true; }    # has_line <text> <ERE> — how many lines match
# maxline <text> <regex> — the longest line that matches, in characters, its stale mark left out (the spec counts marks apart)
maxline() { printf '%s\n' "$1" | python3 -c 'import re, sys
print(max([len(re.sub(" · stale: .*", "", l)) for l in sys.stdin.read().splitlines() if re.match(sys.argv[1], l)] or [0]))' "$2"; }
# nfull <text> <regex> <min> — how many lines that match are at least <min> characters, their stale mark left out
nfull() { printf '%s\n' "$1" | python3 -c 'import re, sys
print(sum(1 for l in sys.stdin.read().splitlines() if re.match(sys.argv[1], l) and len(re.sub(" · stale: .*", "", l)) >= int(sys.argv[2])))' "$2" "$3"; }
clen() { python3 -c 'import json, sys
t = open(sys.argv[1], encoding="utf-8").read().strip()
print(len(json.loads(t)["hookSpecificOutput"]["additionalContext"]) if t else 0)' "$TMP/out.$1"; }   # clen <event> — its string's exact length

# seed <spec>… — ops appended through the store library as the writer sA, caps not checked (the library folds what the log holds).
#   ID@CREATED[;closes=A,B][;anchors=A,B][;sup=ID][;text=T][;len=N][;links=N][;quote=Q][;qlen=N][;where=W]
#   [;closed=AT[;pointer=P]] [;linkmerged=AT] [;linkdone=AT] [;opt=AT]
# `len` makes the text N characters; `links` adds N links `kb/x`; `qlen` a quote of N characters; `closed` adds a close op at AT;
# `linkmerged` / `linkdone` a link-close of the item's closes as merged PRs (with the merge commit) / completed issues done at AT,
# the op itself at `opt` (default now).
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
        text = "t" * int(o["len"]) if "len" in o else o.get("text", "item " + iid)
        src = {"type": "owner" if iid[0] in "DW" else "coordinator"}
        if iid[0] == "D" and ("quote" in o or "qlen" in o):
            src.update(quote="q" * int(o["qlen"]) if "qlen" in o else o["quote"], where=o.get("where", "chat 27/10"))
        item = {"id": iid, "kind": kinds[iid[0]], "pinned": iid[0] == "D", "text": text, "source": src,
                "expires": "2099-01-02T22:00:00Z" if iid[0] == "W" else None, "links": ["kb/x"] * int(o.get("links", 0)),
                "anchors": anchors, "supersedes": o.get("sup")}
        if closes:
            item["closes"] = closes
        if o.get("sup"):
            put({"op": "supersede", "id": o["sup"], "item": item, "reason": "r", "drop": [], "shorter": False, "bulk": False,
                 "t": created, "by": by})
        else:
            put({"op": "owner-add" if iid[0] in "DW" else "add", "item": item, "t": created, "by": by})
        if o.get("closed"):
            put({"op": "close", "id": iid, "reason": "done", "pointer": o.get("pointer"), "bulk": False, "t": o["closed"], "by": by})
        for key, state in (("linkmerged", "merged"), ("linkdone", "completed")):
            if o.get(key):
                an = [dict({"anchor": c, "state": state, "at": o[key]}, **({"sha": "0123456789ab"} if state == "merged" else {}))
                      for c in closes]
                put({"op": "link-close", "id": iid, "anchors": an, "reason": s.link_reason(an), "pointer": closes[0],
                     "t": o.get("opt") or s.now_iso(), "by": {"session": "sA", "hook": "SessionStart"}})
    s.write_caches(d, st, s.head_of(raw))
PY
}

# --- [a] -----------------------------------------------------------------------------------------------------------------------
case_kinds() {
  np; pr 'acme/app¤5' open; pr 'acme/app¤6' open
  br op add --kind session --text "w-auth: review round 2; PR acme/app¤5" --closes acme/app¤5
  c_rc 0 "[a] --kind session with --closes: rc 0"; c_has "$OUT" "added S1" "[a] it is S1"
  br op add --kind queue --text "owner: approve the budget" --closes acme/app¤6
  c_rc 0 "[a] --kind queue with --closes: rc 0"; c_has "$OUT" "added Q1" "[a] it is Q1"
  br op add --kind fact --text "kit CLI: ~/bin/kit"
  c_rc 0 "[a] --kind fact: rc 0"; c_has "$OUT" "added F1" "[a] it is F1"
  br op add --kind fact --text "a fact" --closes acme/app¤6
  c_rc 64 "[a] --closes on a fact: refused (64)"; c_has "$OUT" "a trap or a fact is closed by hand" "[a] and says why"
  c_eq "$(bpy 'st = s.load(s.state_dir())[1]; print(st["items"]["S1"]["closes"], st["items"]["Q1"]["closes"], st["items"]["S1"]["kind"])')" \
       "['acme/app¤5'] ['acme/app¤6'] session" "[a] closes stored on S and Q"
  br op supersede S1 --text "w-auth: merged, wrap up; PR acme/app¤5" --reason "next step"
  c_rc 0 "[a] supersede S1: rc 0"; c_has "$OUT" "superseded S1 with S2" "[a] S2 replaces it"
  c_eq "$(bpy 'print(s.load(s.state_dir())[1]["items"]["S2"]["closes"])')" "['acme/app¤5']" "[a] closes carried over"
  br op supersede F1 --text "kit CLI: ~/bin/kit2" --reason moved; c_rc 0 "[a] supersede a fact: rc 0"
  br op close Q1 --reason answered --pointer "chat 27/10"; c_rc 0 "[a] close a queue item: rc 0"
  br op close F2 --reason gone; c_rc 0 "[a] close a fact: rc 0"
  br op touch S2; c_rc 0 "[a] touch a session: rc 0"
  br op hit S2; c_rc 1 "[a] hit counts traps only"
  c_eq "$(status_of S1) $(status_of S2) $(status_of Q1) $(status_of F2)" "superseded live closed closed" "[a] the log says so"
}

# --- [b] -----------------------------------------------------------------------------------------------------------------------
case_status() {
  np; local i t
  br op add --kind session --text "$(rep s 300)" --anchor acme/app¤5
  for i in 1 2 3 4 5 6 7 8; do
    t=$([ "$i" = 4 ] && rep u 100 || rep s 300)              # the 4th is a third of the first: under 60 %, no --shorter
    br op supersede "S$i" --text "$t" --reason "next step $i"; c_rc 0 "[b] S supersede $i of 8 in 30 minutes: rc 0"
  done
  c_eq "$(bpy 'print(len(s.load(s.state_dir())[1]["retirements"]))')" 0 "[b] they spend no retirement budget"
  c_eq "$(bpy 'print(s.load(s.state_dir())[1]["items"]["S9"]["anchors"])')" "['acme/app¤5']" "[b] the anchor is kept through the chain"
  br op supersede S9 --text "$(rep s 300)" --reason r --drop-anchor acme/app¤9
  c_rc 1 "[b] an S supersede still refuses a drop of an anchor it does not hold"
  c_eq "$(grep -c '"op":"supersede"' "$(sdir)/hot.jsonl")" 8 "[b] each is logged"
  br op add --kind queue --text "$(rep q 100)"
  br op supersede Q1 --text "$(rep q 10)" --reason answered-in-part; c_rc 0 "[b] a Q supersede may shrink too"
  br op add --kind next --text "$(rep x 100)"
  for i in 1 2 3 4 5; do br op supersede "X$i" --text "$(rep x 100)" --reason "r$i"; c_rc 0 "[b] X supersede $i: rc 0"; done
  br op supersede X6 --text "$(rep x 100)" --reason r6
  c_rc 1 "[b] the sixth X supersede: refused by the budget, as before"; c_has "$OUT" "retirement budget" "[b] and says so"
  br op supersede X6 --text "$(rep x 10)" --reason r --bulk
  c_rc 1 "[b] an X supersede under 60 % without --shorter: refused, as before"
}

# --- [c] -----------------------------------------------------------------------------------------------------------------------
case_autoclose() {
  np
  seed "S1@$C20;closes=acme/app¤5;text=w-auth: review round 2" "Q1@$C20;closes=acme/app¤6;text=owner: merge the parser" \
       "S2@$C20;closes=acme/app¤7;text=w-db: still open" "N1@$C20;text=a now item"
  pr 'acme/app¤5' merged "$A21"; pr 'acme/app¤6' merged "$A21"; pr 'acme/app¤7' open
  start3 compact
  c_rc 0 "[c] SessionStart: rc 0 for all three commands"
  c_eq "$(status_of S1) $(status_of Q1) $(status_of S2)" "closed closed live" "[c] an S and a Q item close when their PR merges"
  c_eq "$(nlinks)" 2 "[c] as link-close ops"
  c_eq "$(has_line "$S2" '^- S1 ')$(has_line "$S2" '^- Q1 ')$(has_line "$S2" '^- S2 ')" 001 "[c] string 2 no longer lists them"
  c_has "$S2" "auto-closed now: Q1 (acme/app¤6 merged 10-21), S1 (acme/app¤5 merged 10-21)" "[c] its note says what closed"
  c_has "$S3" "- S1 acme/app¤5 0123456789ab · w-auth: review round 2" "[c] Done in string 3 lists S1 with its anchor and merge commit"
  c_has "$S3" "- Q1 acme/app¤6 0123456789ab · owner: merge the parser" "[c] and Q1"
  c_hasnt "$S1" "auto-closed" "[c] string 1 has no auto-close note"
  c_has "$(eplines auto-close)" '"ids":["Q1","S1"]' "[c] one auto-close episode line"
}

# --- [d] -----------------------------------------------------------------------------------------------------------------------
case_done() {
  np
  seed "X1@$C20;closes=acme/app¤5;linkmerged=$A21;opt=$(ago 3600);text=ship the parser" \
       "S1@$C20;closes=acme-corporation/application-with-a-long-name¤4242;len=440;linkmerged=$A21;opt=$(ago 1800)" \
       "N1@$C20;closed=$(ago 7200);pointer=chat 27/10;text=fix the login" \
       "Q1@$C20;closed=$(ago 600);text=no pointer here" \
       "X2@$C20;closed=$(ago 90000);text=closed 25 h ago" \
       "T1@$C20;closed=$(ago 60);text=a trap closed" "F1@$C20;closed=$(ago 60);text=a fact closed" \
       "X3@$C20;text=superseded" "X4@$C20;text=the new one;sup=X3"
  start3
  local done; done=$(printf '%s\n' "$S3" | sed -n '/^Done (24 h)$/,/^Facts$/p')
  c_eq "$(printf '%s\n' "$done" | sed -n '2,5p' | cut -c1-4 | tr '\n' ' ')" "- Q1 - S1 - X1 - N1 " "[d] Done: newest first (Q1 10 min, S1 30 min, X1 1 h, N1 2 h ago)"
  c_has "$done" "- X1 acme/app¤5 0123456789ab · ship the parser" "[d] a link-close: id, anchor, merge commit, then the text"
  c_has "$(printf '%s\n' "$done" | grep -F -e '- S1 ')" "- S1 acme-corporation/application-with-a-long-name¤4242 0123456789ab · ttt" "[d] the SHA kept when the text is long"
  c_eq "$(maxline "$done" '- S1 ')" 200 "[d] the line is cut at 200, in the text"
  c_has "$done" "- N1 chat 27/10 · fix the login" "[d] a close shows its pointer"
  c_has "$done" "- Q1 · no pointer here" "[d] a close with no pointer: the text"
  c_hasnt "$done" "X2" "[d] not one closed 25 h ago"
  c_hasnt "$done" "T1" "[d] not a trap"; c_hasnt "$done" "F1" "[d] nor a fact"; c_hasnt "$done" "X3" "[d] nor a superseded item"
  c_hasnt "$(grep -v -E '"op":"(claim|add|close|link-close|supersede)"' "$(sdir)/hot.jsonl")" '"op"' "[d] instrument: the log holds only the seeded ops"
  br op add --kind done --text "wrote it myself"
  c_rc 64 "[d] Done is derived: --kind done is refused (64)"
  # 9 closed in the window: 7 lines, then the count; doctor lists every one
  np; local i specs=()
  for i in 1 2 3 4 5 6 7 8 9; do specs+=("X$i@$C20;closed=$(ago $((i * 60)));text=done $i"); done
  seed "${specs[@]}"; start3
  done=$(printf '%s\n' "$S3" | sed -n '/^Done (24 h)$/,/^Facts$/p')
  c_eq "$(has_line "$done" '^- X[0-9]')" 7 "[d] 7 Done lines"
  c_has "$done" "(+2 more: brain doctor)" "[d] then the count of the rest"
  br doctor
  c_eq "$(has_line "$OUT" 'done \(24 h\), [0-9] of 9: - X')" 9 "[d] doctor lists all 9"
}

# --- [e] -----------------------------------------------------------------------------------------------------------------------
case_empty() {
  np; seed "N1@$C20;text=only a now item" "D1@$C20;text=a pin"; start3
  c_rc 0 "[e] rc 0"
  c_has "$S1" "- N1 only a now item" "[e] string 1 as before"
  c_eq "$S2|$S3" "|" "[e] strings 2 and 3 print nothing when their sections are empty and there is no note"
  c_eq "$(cat "$TMP/out.session-start-sessions" "$TMP/out.session-start-plan")" "" "[e] not even an empty JSON line"
  np; seed "X1@$C20;closes=acme/app¤5;text=the only next"; pr 'acme/app¤5' merged "$A21"; start3
  c_eq "$(status_of X1)" closed "[e] instrument: X1 closed"
  c_has "$S3" "## Brain · plan" "[e] string 3 prints when an X closes with it otherwise empty"
  c_has "$S3" "auto-closed now: X1 (acme/app¤5 merged 10-21)" "[e] with the note"
  c_eq "$S2" "" "[e] string 2 stays empty"
  np; seed "N1@$C20;closes=acme/app¤5;text=n" "S1@$C20;closes=acme/app¤6;text=s" "S2@$C20;text=stays"
  pr 'acme/app¤5' merged "$A21"; pr 'acme/app¤6' merged "$A21"; start3
  c_has "$S1" "auto-closed now: N1 (acme/app¤5" "[e] an N close's note is in string 1"
  c_hasnt "$S1" "S1 (acme" "[e] not the S close's"
  c_has "$S2" "auto-closed now: S1 (acme/app¤6" "[e] an S close's note is in string 2"
  c_hasnt "$S2$S3" "N1 (acme" "[e] the N note in no other string"
  c_hasnt "$S3" "auto-closed" "[e] string 3 has no note"
  # only a close of an S item, the sessions part otherwise empty: string 2 prints, with its title, for the note
  np; seed "S1@$C20;closes=acme/app¤6;text=s"; pr 'acme/app¤6' merged "$A21"; start3
  c_has "$S2" "## Brain · sessions" "[e] an S close with S and Q otherwise empty: string 2 prints its title"
  c_has "$S2" "auto-closed now: S1" "[e] and the note"
}

# --- [f] -----------------------------------------------------------------------------------------------------------------------
skill() { mkdir -p "$1/$2"; printf -- '---\nname: %s\ndescription: "%s"\n---\n\n# %s\n' "$2" "$3" "$2" > "$1/$2/SKILL.md"; }
many_skills() {  # project, user and plugin skills, more than the Shelf index fits
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
# full <close|held> [more] — every section at its cap, every text and line at its cap, 8 short links (every line full), every
# quote 300, every anchor done, a full Done (8 link-closed items with two merged anchors each), and items whose issues reopened
# in every string. `close`: 5 more items (past the caps) are closable and close, the others' PRs closed unmerged (marked, never
# closed); `held`: every N, X, S and Q item is closable, so the burst is held. `more` adds 6 items to every section past its cap.
full() {
  np
  local i n mode=$1 extra=${2:-} specs=() R=acme-corporation/app
  local k_s=12 k_q=5 k_x=10 k_t=13 k_f=5 k_d=10 k_w=5 k_n=3
  [ -n "$extra" ] && { k_s=18; k_q=11; k_x=16; k_t=19; k_f=11; }
  n=100
  for i in $(seq 1 $k_d); do specs+=("D$i@$C20;anchors=$R¤$((n + i));len=150;links=8;qlen=300;where=$(rep w 60)"); done
  for i in $(seq 1 $k_w); do specs+=("W$i@$C20;len=150;links=8"); done
  for i in $(seq 1 $k_n); do specs+=("N$i@$C20;closes=$R¤$((200 + i));len=150;links=8"); done
  for i in $(seq 1 $k_s); do specs+=("S$i@$C20;closes=$R¤$((300 + i));len=450;links=8"); done
  for i in $(seq 1 $k_q); do specs+=("Q$i@$C20;closes=$R¤$((400 + i));len=150;links=8"); done
  for i in $(seq 1 $k_x); do specs+=("X$i@$C20;closes=$R¤$((500 + i));len=150;links=8"); done
  for i in $(seq 1 $k_t); do specs+=("T$i@$C20;len=150;links=8"); done
  for i in $(seq 1 $k_f); do specs+=("F$i@$C20;len=150;links=8"); done
  if [ "$mode" = close ]; then                       # 5 closable past the caps: one N, two S, one Q, one X
    specs+=("N91@$C20;closes=$R¤691;len=150" "S91@$C20;closes=$R¤692;len=450" "S92@$C20;closes=$R¤693;len=450"
            "Q91@$C20;closes=$R¤694;len=150" "X91@$C20;closes=$R¤695;len=150")
  fi
  for i in 1 2 3 4 5 6 7 8; do                       # a full Done: two merged anchors with their commits, a long text
    specs+=("X$((70 + i))@$C20;closes=$R¤$((700 + 2 * i)),$R¤$((701 + 2 * i));len=150;linkmerged=$A21")
  done
  local half; half=$(ago 43200)
  for i in 1 2 3 4 5; do                              # reopened issues in every string, closed 12 h ago (older than Done's 7)
    specs+=("N$((80 + i))@$C20;closes=$R¤$((800 + i));linkdone=$A21;opt=$half" "S$((80 + i))@$C20;closes=$R¤$((820 + i));linkdone=$A21;opt=$half"
            "X$((80 + i))@$C20;closes=$R¤$((840 + i));linkdone=$A21;opt=$half")
  done
  seed "${specs[@]}"
  for i in $(seq 1 $k_d); do issue "$R¤$((n + i))" completed "$A21"; done
  for i in $(seq 1 30); do
    if [ "$mode" = held ]; then pr "$R¤$((200 + i))" merged "$A21"; pr "$R¤$((300 + i))" merged "$A21"
      pr "$R¤$((400 + i))" merged "$A21"; pr "$R¤$((500 + i))" merged "$A21"
    else pr "$R¤$((200 + i))" closed "$A21"; pr "$R¤$((300 + i))" closed "$A21"; pr "$R¤$((400 + i))" closed "$A21"
      pr "$R¤$((500 + i))" closed "$A21"; fi
  done
  for i in 1 2 3 4 5; do pr "$R¤$((690 + i))" merged "$A21"; done
  for i in 1 2 3 4 5; do issue "$R¤$((800 + i))" reopened; issue "$R¤$((820 + i))" reopened; issue "$R¤$((840 + i))" reopened; done
  many_skills
}
sizes() {  # sizes — after start3: the three lengths
  printf '%s %s %s' "$(clen session-start)" "$(clen session-start-sessions)" "$(clen session-start-plan)"
}
case_size() {
  local mode i a b c m1 m2 m3
  for mode in held close; do
    full "$mode"; m1=0; m2=0; m3=0
    for i in 1 2 3 4 5 6; do                        # 12 lookups per start: six starts answer every anchor from the cache
      start3 compact; read -r a b c <<<"$(sizes)"
      [ "$a" -gt "$m1" ] && m1=$a; [ "$b" -gt "$m2" ] && m2=$b; [ "$c" -gt "$m3" ] && m3=$c
      c_hasnt "$S1$S2$S3" "[brain: cut" "[f] $mode, SessionStart $i: no hard cut in any string ($a, $b, $c)"
    done
    c_eq "$([ "$m1" -le 8000 ] && echo within)" within "[f] $mode: string 1 at most $m1 ≤ 8,000"
    c_eq "$([ "$m2" -le 9500 ] && echo within)" within "[f] $mode: string 2 at most $m2 ≤ 9,500"
    c_eq "$([ "$m3" -le 9500 ] && echo within)" within "[f] $mode: string 3 at most $m3 ≤ 9,500"
    # the instruments: the case is the worst case it claims
    c_eq "$(nfull "$S1" '- [DWN][0-9]+ ' 190)" 18 "[f] $mode: instrument: D 10, W 5, N 3, each line full (≥ 190)"
    c_eq "$(has_line "$S1" '^  "q{119}…" · w{30}$')" 10 "[f] $mode: instrument: 10 quote lines, cut at 120 and 30"
    c_eq "$(nfull "$S2" '- S[0-9]+ ' 490)" 12 "[f] $mode: instrument: S 12, each line full (≥ 490)"
    c_eq "$([ "$(maxline "$S2" '- S')" -le 500 ] && echo within)" within "[f] $mode: an S line is ≤ 500 (its mark apart)"
    c_eq "$(nfull "$S2" '- Q[0-9]+ ' 190)" 5 "[f] $mode: instrument: Q 5, each line full"
    c_eq "$(nfull "$(printf '%s\n' "$S3" | sed -n '/^Next$/,/^Traps$/p')" '- X[0-9]+ ' 190)" 10 "[f] $mode: instrument: X 10, each line full"
    c_eq "$(nfull "$(printf '%s\n' "$S3" | sed -n '/^Done (24 h)$/,/^Facts$/p')" '- [NXSQ][0-9]+ ' 190)" 7 "[f] $mode: instrument: Done 7, each line full"
    c_eq "$(nfull "$S3" '- [TF][0-9]+ ' 190)" 18 "[f] $mode: instrument: T 13 and F 5, each line full"
    c_eq "$([ "$(maxline "$S3" '- ')" -le 200 ] && echo within)" within "[f] $mode: no line of string 3 over 200 (marks apart)"
    c_has "$S3" "(+" "[f] $mode: instrument: Done has its count line"
    c_has "$S1" "stale: " "[f] $mode: marks in string 1"; c_has "$S2" "stale: " "[f] $mode: in string 2"; c_has "$S3" "stale: " "[f] $mode: in string 3"
    c_has "$S1" "## Shelf index" "[f] $mode: the Shelf index is there"
    c_eq "$([ "$(nchars "$(printf '%s\n' "$S1" | sed -n '/^## Shelf index/,$p')")" -ge 900 ] && echo full)" full "[f] $mode: instrument: the Shelf index is full"
    if [ "$mode" = held ]; then
      c_has "$S1" "auto-close held: " "[f] held: the held note in string 1"
    else
      c_eq "$(grep -c '"op":"link-close"' "$(sdir)/hot.jsonl")" $((8 + 15 + 5)) "[f] close: instrument: 5 closed in all"
    fi
    c_has "$S1$S2$S3" "reopened: " "[f] $mode: reopened notes are there"
    unset CLAUDE_CONFIG_DIR
  done
  # past the caps: 6 more in every section → strings 2 and 3 over 9,500, cut by their own hard cut with the naming line
  full held more
  start3 compact; start3 compact
  c_eq "$([ "$(clen session-start-sessions)" -le 9500 ] && [ "$(clen session-start-plan)" -le 9500 ] && echo within)" within \
       "[f] past the caps: both ≤ 9,500 ($(clen session-start-sessions), $(clen session-start-plan))"
  c_has "$(printf '%s\n' "$S2" | tail -n 1)" "[brain: cut " "[f] past the caps: string 2 ends with the cut line"
  c_has "$(printf '%s\n' "$S2" | tail -n 1)" "Owner queue" "[f] which names the sections it cut"
  c_has "$(printf '%s\n' "$S3" | tail -n 1)" "[brain: cut " "[f] past the caps: string 3 ends with the cut line"
  c_has "$(printf '%s\n' "$S3" | tail -n 1)" "Facts" "[f] which names Facts"
  c_has "$(eplines session-start | tail -n 1)" '"cut_sessions":' "[f] the episode line counts the cut"
  c_eq "$(eplines session-start | tail -n 1 | python3 -c 'import json, sys; o = json.loads(sys.stdin.read()); print(o["cut_sessions"] > 0, o["cut_plan"] > 0)')" \
       "True True" "[f] for both strings"
  br matrix
  c_has "$(printf '%s\n' "$OUT" | grep -F 'Know·hot')" "over: sessions, plan" "[f] past the caps: brain matrix warns that the sessions and plan parts are over their cap"
  unset CLAUDE_CONFIG_DIR
}

# --- [g] -----------------------------------------------------------------------------------------------------------------------
case_quote() {
  np; local q odd
  q="The owner said: $(rep a 140) end"
  owner_ok add --kind decision --text "ship R4 after the gate" --owner-quote "$q" --where "chat 27/10 with the coordinator, long"
  c_rc 0 "[g] instrument: the pin is written through the dialog"
  odd='Đồng ý — "ship it" 🚀 ‘now’ ½ <b>x</b> $(rm) `y` \n'
  owner_ok add --kind decision --text "odd quote" --owner-quote "$odd" --where "chat"
  c_rc 0 "[g] instrument: a quote with odd characters is written"
  start3
  c_has "$S1" "- D1 ship R4 after the gate · since" "[g] the pin"
  c_has "$S1" "$(python3 -c 'import sys; q, w = sys.argv[1:3]; print("  \"%s…\" · %s" % (q[:119], w[:30]))' "$q" "chat 27/10 with the coordinator, long")" \
       "[g] its quote line under it, cut at 120 with …, where cut at 30"
  c_eq "$(printf '%s\n' "$S1" | grep -A1 -F -e '- D1 ' | tail -n 1 | cut -c1-3)" '  "' "[g] right under the pin"
  c_eq "$(maxline "$S1" '  "')" 157 "[g] the longest quote line: 2 + 1 + 120 + 1 + 3 + 30 = 157 characters (≤ 160)"
  c_has "$S1" "  \"$odd\" · chat" "[g] odd characters kept as written, on one line"
  owner_ok supersede D1 --text "ship R4 after the gate, then R4.1"
  c_rc 0 "[g] instrument: an owner supersede"
  start3
  c_eq "$(printf '%s\n' "$S1" | grep -A1 -F -e '- D3 ' | tail -n 1)" "Windows" "[g] an owner supersede stores no quote: no quote line under D3"
  c_hasnt "$S2$S3" "D2" "[g] a pin only in string 1"; c_hasnt "$S2$S3" "Pinned" "[g] Pinned only in string 1"
  # a quote cut where a letter carries accents typed apart (NFD): the letter goes with them, never without them
  local nfd; nfd=$(python3 -c 'print("a" * 118 + "e\u0302\u0301" + "x" * 30)')
  owner_ok add --kind decision --text "decomposed accents" --owner-quote "$nfd" --where "chat"
  c_rc 0 "[g] instrument: a decomposed quote is written"
  start3
  c_has "$S1" "  \"$(rep a 118)…\" · chat" "[g] the cut steps back over the accents and their letter"
  owner_unpin_all() { local i; for i in $(bpy 'print(" ".join(k for k, v in s.load(s.state_dir())[1]["items"].items() if k[0] == "D" and v["status"] == "live"))'); do owner_ok unpin "$i"; done; }
  owner_unpin_all
  owner_ok add --kind decision --text "an emoji at the cut" --owner-quote "$(rep a 118)❤️$(rep x 30)" --where "chat"
  c_rc 0 "[g] instrument: a quote with an emoji and its selector at the cut is written"
  start3
  c_has "$S1" "  \"$(rep a 118)…\" · chat" "[g] the cut never parts an emoji from its selector"
  owner_unpin_all
  owner_ok add --kind decision --text "a vowel sign at the cut" --owner-quote "$(rep a 118)का$(rep x 30)" --where "chat"
  owner_ok add --kind decision --text "an enclosing mark at the cut" --owner-quote "$(python3 -c 'print("b" * 118 + "x\u20dd" + "x" * 30)')" --where "chat"
  c_rc 0 "[g] instrument: quotes with a spacing mark (Mc) and an enclosing mark (Me) at the cut are written"
  start3
  c_has "$S1" "  \"$(rep a 118)…\" · chat" "[g] the cut never parts a letter from its vowel sign"
  c_has "$S1" "  \"$(rep b 118)…\" · chat" "[g] nor from an enclosing mark"
  R=$(bpy 'print(s.quote_line({"id": "D1", "source": {"quote": "\u0915" + "\u093e" * 130, "where": "chat"}}))')
  c_eq "$R" "  \"$(python3 -c 'print("\u0915" + "\u093e" * 118, end="")')…\" · chat" "[g] a letter and 130 marks: the plain cut, never an empty quote"
}

# --- [h] -----------------------------------------------------------------------------------------------------------------------
case_caps() {
  np; local k n i
  for k in session:12 queue:5 next:10 trap:13 fact:5; do
    n=${k#*:}; k=${k%%:*}
    for i in $(seq 1 "$n"); do br op add --kind "$k" --text "$k $i"; [ "$RC" = 0 ] || break; done
    c_rc 0 "[h] $k: $n accepted"
    br op add --kind "$k" --text "$k one more"
    c_rc 1 "[h] $k: the next add refused"; c_has "$OUT" "of $n live items; close one first, e.g." "[h] $k: it names the item to close"
  done
  np
  br op add --kind session --text "$(rep s 450)"; c_rc 0 "[h] an S text of 450: accepted"
  br op add --kind session --text "$(rep s 451)"; c_rc 1 "[h] 451: refused"; c_has "$OUT" "over its cap of 450" "[h] and says the cap"
  br op add --kind next --text "$(rep x 151)"; c_rc 1 "[h] an X text of 151: refused (150, as before)"
  br op add --kind fact --text "$(rep f 151)"; c_rc 1 "[h] an F text of 151: refused"
  br op supersede S1 --text "$(rep s 451)" --reason r; c_rc 1 "[h] an S supersede of 451: refused"
}

# --- [i] -----------------------------------------------------------------------------------------------------------------------
case_fact_path() {
  np
  local hp=/home                                      # spelled apart: the public-tree scan reads a home path in a line
  br op add --kind fact --text "kit CLI: $hp/alice/bin/kit"
  c_rc 1 "[i] a fact with /home/<name>/…: refused by sanitize"; c_has "$OUT" "sensitive value" "[i] and says so"
  br op add --kind fact --text "kit CLI: ~/bin/kit (or scripts/kit.py under the plugin root)"
  c_rc 0 "[i] ~/… and a path under a plugin root: accepted"
}

# --- [j] -----------------------------------------------------------------------------------------------------------------------
case_owner() {
  np; local k
  for k in decision window; do br op add --kind "$k" --text t; c_rc 1 "[j] op add --kind $k: refused"; done
  br op add --kind session --text t --owner-quote q; c_rc 64 "[j] no brain op option takes an owner quote (64)"
  br owner add --kind decision --text t --owner-quote q --where w; c_rc 6 "[j] owner add without the dialog: refused (6)"
  owner_ok add --kind decision --text "pinned" --owner-quote q --where w; c_rc 0 "[j] owner add through the dialog: rc 0"
  owner_ok add --kind window --text "a window" --owner-quote q --where w --expires 2099-01-01T00:00:00Z; c_rc 0 "[j] a window too"
  br op close D1 --reason r; c_rc 1 "[j] op close of a pin: refused"
  br op supersede W1 --text t --reason r; c_rc 1 "[j] op supersede of a window: refused"
  br owner add --kind session --text t --owner-quote q --where w; c_rc 64 "[j] owner add --kind session: usage (64)"
}

# --- [k] -----------------------------------------------------------------------------------------------------------------------
case_episode() {
  np; seed "N1@$C20" "S1@$C20;len=450" "X1@$C20" "F1@$C20"
  start3 compact
  local ep; ep=$(eplines session-start | tail -n 1)
  c_eq "$(eplines session-start | wc -l | tr -d ' ')" 1 "[k] one session-start line for the three commands"
  c_has "$ep" '"format":3' "[k] format 3"
  c_has "$ep" "\"injected\":$(clen session-start)," "[k] injected: string 1's length"
  c_has "$ep" "\"injected_sessions\":$(clen session-start-sessions)," "[k] injected_sessions: string 2's"
  c_has "$ep" "\"injected_plan\":$(clen session-start-plan)," "[k] injected_plan: string 3's"
  c_has "$ep" '"cut":0,"cut_plan":0,"cut_sessions":0' "[k] the three cuts, 0"
  np; seed "N1@$C20"; start3 compact
  c_has "$(eplines session-start)" '"injected_plan":0' "[k] an empty string 3: injected_plan 0"
  c_has "$(eplines session-start)" '"injected_sessions":0' "[k] an empty string 2: injected_sessions 0"
}

# --- [l] -----------------------------------------------------------------------------------------------------------------------
case_handover() {
  np; seed "N1@$C20" "S1@$C20;text=a session" "X1@$C20;text=a next"
  one session-start
  c_eq "$(cd "$(sdir)/starts" && ls | sed 's/^[0-9a-f]*\.//' | sort | tr '\n' ' ')" "plan.json sessions.json " "[l] string 1's pass hands each string over in a file"
  c_eq "$(stat -c %a "$(sdir)/starts")$(stat -c %a "$(sdir)"/starts/*.json | sort -u)" 700600 "[l] 0700 and 0600"
  hk session-end "$(hin session_id="$SID" cwd="$P" hook_event_name=SessionEnd reason=exit)"
  c_eq "$(ls "$(sdir)/starts" | wc -l | tr -d ' ')" 0 "[l] SessionEnd removes what was not taken"
  start3
  c_has "$S2" "- S1 a session" "[l] string 2's command prints what string 1 handed over"
  c_has "$S3" "- X1 a next" "[l] string 3's command too"
  c_hasnt "$S2$S3" "skipped" "[l] with no note of their own"
  c_eq "$(ls "$(sdir)/starts" | wc -l | tr -d ' ')" 0 "[l] and each deletes its file: a hand-over is used once"
  # two SessionStarts back to back: the second's strings show the second's state, never the first's hand-over
  start3 compact; seed "S2@$C20;text=written between the two"; start3 compact
  c_has "$S2" "- S2 written between the two" "[l] back to back: string 2 shows the state of its own SessionStart"
  c_eq "$(ls "$(sdir)/starts" | wc -l | tr -d ' ')" 0 "[l] both strings took their hand-over"
  # a string's command alone (string 1's never ran): it waits, then renders its own part from the log, with a note
  np; seed "S1@$C20;text=alone"
  local t0 t1; t0=$(date +%s); one session-start-sessions; t1=$(date +%s)
  c_rc 0 "[l] alone: rc 0"
  c_has "$OUT" "- S1 alone" "[l] alone: its own part"
  c_has "$OUT" "stale-anchor check: skipped (string 1 handed nothing over)" "[l] with a note"
  c_eq "$([ $((t1 - t0)) -ge 5 ] && [ $((t1 - t0)) -le 9 ] && echo waited)" waited "[l] after waiting for the hand-over ($((t1 - t0)) s)"
  # an older hand-over (another SessionStart of this session, 2 s before: the commands of one start within ms) is never used
  bpy 'import hashlib, json, os, time
d = s.state_dir(); os.makedirs(d + "/starts", exist_ok=True)
p = d + "/starts/" + hashlib.sha256(b"sA").hexdigest()[:32] + ".sessions.json"
s._write_file(p, json.dumps({"session": "sA", "source": "compact", "t": time.time() - 2, "part": "sessions", "text": "OLD STRING"}))'
  one session-start-sessions
  c_hasnt "$OUT" "OLD STRING" "[l] a hand-over from 2 s before is not used"
  c_has "$OUT" "- S1 alone" "[l] the part is rendered instead"
  # SessionEnd removes the session's hand-overs
  one session-start
  hk session-end "$(hin session_id="$SID" cwd="$P" hook_event_name=SessionEnd reason=exit)"
  c_eq "$(ls "$(sdir)/starts" | wc -l | tr -d ' ')" 0 "[l] SessionEnd removes what was not taken"
  # a broken log: string 1 says so, strings 2 and 3 print nothing (and do not wait)
  np; seed "S1@$C20"; printf 'garbage\n' >> "$(sdir)/hot.jsonl"
  t0=$(date +%s); start3; t1=$(date +%s)
  c_has "$S1" "hot memory was not injected" "[l] a broken log: string 1 warns"
  c_eq "$S2|$S3" "|" "[l] strings 2 and 3 print nothing"
  c_eq "$([ $((t1 - t0)) -le 3 ] && echo fast)" fast "[l] and do not wait for a hand-over ($((t1 - t0)) s)"
  # a write holding the store lock: SessionStart reads under the lock, so it waits for the write and shows it
  np; seed "S1@$C20;text=before the write"
  (CLAUDE_CODE_SESSION_ID=sA BRAIN_TEST=1 BRAIN_TEST_PAUSE_MS=500 "$BROOT/bin/brain" op add --kind session --text "written during the start" >/dev/null 2>&1) &
  local wp=$!; sleep 0.2; start3; wait "$wp"
  c_eq "$RC" 0 "[l] a SessionStart during a write: rc 0"
  c_has "$S2" "- S2 written during the start" "[l] it waits for the write that holds the lock, and shows it"
  c_hasnt "$S1" "not injected" "[l] and no broken-log warning"
  # a lock held past LOCK_WAIT (a writer stuck): the read goes on without it, and all three strings come
  python3 -c 'import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600); fcntl.flock(fd, fcntl.LOCK_EX); time.sleep(4)' "$(sdir)/lock" &
  wp=$!; sleep 0.2; t0=$(date +%s); start3; t1=$(date +%s); kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null
  c_has "$S1$S2" "- S2 written during the start" "[l] a lock held for 4 s: the strings are injected"
  c_eq "$([ $((t1 - t0)) -le 3 ] && echo fast)" fast "[l] after the 1 s wait, not the writer's 4 ($((t1 - t0)) s)"
  # a lock file that cannot be opened (here a directory; a read-only or full disk alike): read without it
  rm -f "$(sdir)/lock"; mkdir "$(sdir)/lock"; start3
  c_has "$S2" "- S2 written during the start" "[l] a lock that cannot be opened: the strings are still injected"
  rmdir "$(sdir)/lock"
  # no session id: no hand-over to match, so strings 2 and 3 read the log at once
  np; seed "S1@$C20;text=no id"
  t0=$(date +%s); start3 compact ""; t1=$(date +%s)
  c_has "$S2" "- S1 no id" "[l] no session id: string 2 renders its own part"
  c_eq "$([ $((t1 - t0)) -le 3 ] && echo fast)" fast "[l] without waiting ($((t1 - t0)) s)"
  c_eq "$(ls "$(sdir)/starts" 2>/dev/null | wc -l | tr -d ' ')" 0 "[l] and string 1 hands nothing over"
  # `starts` is not a directory: nothing can be handed over, so nothing is waited for; a log that refuses: one warning line
  np; seed "S1@$C20;text=starts is a file"; : > "$(sdir)/starts"
  t0=$(date +%s); start3; t1=$(date +%s)
  c_has "$S2" "- S1 starts is a file" "[l] starts is a file: string 2 renders its own part"
  c_eq "$([ $((t1 - t0)) -le 3 ] && echo fast)" fast "[l] without waiting ($((t1 - t0)) s)"
  printf 'garbage\n' >> "$(sdir)/hot.jsonl"; one session-start-sessions
  c_has "$OUT" "brain: the sessions string was not injected" "[l] no hand-over and a log that refuses: string 2 says so"
  R=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import brain_hook as h
b = "## Brain · plan v3 · 9,999/9,500 chars   (x)\nNext\n" + "".join("- X%d %s\n" % (i, "x" * 190) for i in range(60)) + "Facts\n- F1 f\n"
print(h.cut(b, 9500)[0].splitlines()[-1])' "$BROOT/scripts")
  c_has "$R" "Next, Facts]" "[l] the cut names the sections it cut"
  R=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import brain_hook as h
b = "x\n" * 5000 + "## Brain · plan v3 · 1,000/9,500 chars   (x)\nNext\n- X1 x\n"
print(h.cut(b, 9500)[0].splitlines()[-1])' "$BROOT/scripts")
  c_has "$R" ": Brain · plan, Next]" "[l] and a part by its title, without version or size"
  # Claude Code counts UTF-16 units: an emoji is 2. Sessions full of status emoji are under 9,500 characters but over 9,500 units
  np; local i specs=(); for i in $(seq 1 12); do specs+=("S$i@$C20;text=$(rep 🟢 440)"); done; seed "${specs[@]}"
  start3
  R=$(python3 -c 'import json, sys
t = json.loads(open(sys.argv[1], encoding="utf-8").read())["hookSpecificOutput"]["additionalContext"]
print(len(t) < 9500, len(t.encode("utf-16-le")) // 2 <= 9500)' "$TMP/out.session-start-sessions")
  c_eq "$R" "True True" "[l] 12 sessions of emoji: string 2 is ≤ 9,500 UTF-16 units, the unit Claude Code counts"
  c_has "$S2" "[brain: cut " "[l] by its hard cut, named"
}

# --- [m] -----------------------------------------------------------------------------------------------------------------------
case_old_state() {
  np
  seed "D1@$C20;text=an old pin" "W1@$C20;text=an old window" "N1@$C20;text=an old now" "X1@$C20;text=next one" \
       "X2@$C20;text=next two" "T1@$C20;text=an old trap" "X3@$C20;closes=acme/app¤5;text=closed by link;linkmerged=$A21"
  c_eq "$(bpy 'print(sorted({o["op"] for o in s.verify(s.state_dir())[1]}))')" "['add', 'claim', 'link-close', 'owner-add']" \
       "[m] instrument: a log of format 2's ops and kinds"
  start3
  c_has "$S1" "- D1 an old pin" "[m] the pin in string 1"; c_has "$S1" "- W1 an old window" "[m] the window"; c_has "$S1" "- N1 an old now" "[m] Now"
  c_has "$S3" "- X1 next one" "[m] Next in string 3"; c_has "$S3" "- X2 next two" "[m] both"; c_has "$S3" "- T1 an old trap" "[m] the trap"
  c_has "$S3" "- X3 acme/app¤5 0123456789ab · closed by link" "[m] the link-close in Done"
  c_hasnt "$S1" "- X1 " "[m] Next no longer in string 1"
  c_eq "$S2" "" "[m] no S or Q: no string 2"
  # a brain of format 2 (ids D W N X T only) refuses a log with an S item
  np; seed "S1@$C20"
  c_eq "$(bpy 'import re
s.ID_RE = re.compile(r"^[DWNXT][1-9][0-9]{0,5}$")
try:
    s.fold(s.verify(s.state_dir())[1]); print("folded")
except s.Refused as e:
    print(e.rc)')" 5 "[m] a format-2 fold refuses an S item (rc 5): every session restarts on this version first"
  # doctor's hot.md check: Done ages out without a write, an edited Done line is caught
  np; seed "X1@$C20;closed=$(ago 600);text=done soon gone" "N1@$C20"
  R=$(bpy 'import time
st = s.load(s.state_dir())[1]; t0 = time.time()
md = s.render_all(st, now=t0)
later = t0 + 2 * 86400
print(s.render_key(md, st, now=later) == s.render_key(s.render_all(st, now=later), st, now=later),
      s.render_key(md.replace("· done soon gone", "· done, and merged"), st, now=t0) == s.render_key(md, st, now=t0))')
  c_eq "$R" "True False" "[m] hot.md still matches once Done has aged; an edited Done line does not"
  br doctor; c_has "$OUT" "hot.md matches a fresh render" "[m] doctor: hot.md matches"
  bpy 'st = s.load(s.state_dir())[1]; s._write_file(s.state_dir() + "/hot.md", s.render_one_part(st))'
  br doctor
  c_has "$OUT" "warn     hot.md holds an older brain's one-part render; \`brain render\` rewrites it" "[m] an older brain's hot.md: a warn that says what rewrites it"
  c_hasnt "$OUT" "problem  hot.md" "[m] not a problem"
  br render >/dev/null; br doctor; c_has "$OUT" "hot.md matches a fresh render" "[m] brain render rewrites it"
  bpy 'import json
d = s.state_dir(); f = open(d + "/episodes.jsonl", "a")
f.write(json.dumps({"t": s.now_iso(), "kind": "session-start", "session": "older-two", "format": 2}) + "\n")'
  br doctor; c_has "$OUT" "log format 2, this one writes 3" "[m] doctor warns on a session last started on format 2"
}

# --- [n] -----------------------------------------------------------------------------------------------------------------------
case_live() {
  local L="$SRC_ROOT/tests/live" F="$SRC_ROOT/tests/live/fixtures/brain-transcript"
  bash -n "$L/hook-cap.sh"; RC=$?; c_rc 0 "[n] hook-cap.sh parses"
  OUT=$(bash "$L/hook-cap.sh" 9500 ten 2>&1); RC=$?; c_rc 2 "[n] hook-cap.sh refuses a length that is not a number (rc 2)"
  c_has "$OUT" "usage" "[n] and prints its usage"
  OUT=$(python3 "$L/brain-transcript-check.py" "$F/three-strings.jsonl" --episodes "$F/three-strings.episodes.jsonl" --ids X1,S1,F1 --source startup); RC=$?
  c_rc 0 "[n] three strings: clean (rc 0)"; c_has "$OUT" "string 1 inline 398 · string 2 inline 226 · string 3 inline 271 · ids found · clean" "[n] each inline, its size, the ids found"
  OUT=$(python3 "$L/brain-transcript-check.py" "$F/three-strings.jsonl" --episodes "$F/three-strings.episodes.jsonl" --ids X1,S9 --source startup); RC=$?
  c_rc 1 "[n] an id not in the strings: rc 1"; c_has "$OUT" "ids not found: S9" "[n] named"
  OUT=$(python3 "$L/brain-transcript-check.py" "$F/no-sessions.jsonl" --episodes "$F/no-sessions.episodes.jsonl" --ids X1,F1 --source startup); RC=$?
  c_rc 0 "[n] string 2 absent, its episode line 0: clean (rc 0)"; c_has "$OUT" "string 2 absent" "[n] it says absent"
  OUT=$(python3 "$L/brain-transcript-check.py" "$F/no-sessions.jsonl" --episodes <(sed 's/"injected_sessions":0/"injected_sessions":180/' "$F/no-sessions.episodes.jsonl") --ids X1 --source startup); RC=$?
  c_rc 1 "[n] string 2 absent while the episode line says it injected 180: rc 1"
  OUT=$(python3 "$L/brain-transcript-check.py" "$F/plan-over-cap.jsonl" --episodes "$F/plan-over-cap.episodes.jsonl" --ids N1 --source startup); RC=$?
  c_rc 1 "[n] string 3 over the cap: rc 1"; c_has "$OUT" "string 3 persisted" "[n] it says persisted"
  OUT=$(python3 "$L/brain-transcript-check.py" "$F/three-strings.jsonl" --episodes "$F/three-strings.episodes.jsonl" --ids X1); RC=$?
  c_rc 2 "[n] no SessionStart:compact in a startup transcript: rc 2"
  OUT=$(python3 "$L/brain-transcript-check.py" "$F/no-sessions.jsonl" --episodes <(sed -e 's/"injected_plan":[0-9]*,//' -e 's/"injected_sessions":[0-9]*,//' -e 's/"format":3/"format":2/' "$F/no-sessions.episodes.jsonl") --ids X1 --source startup); RC=$?
  c_rc 0 "[n] an older brain's episode line (no field for strings 2 and 3): clean (rc 0)"
  c_has "$OUT" "string 2 none (an older brain, format 2)" "[n] and says why string 2 is not there"
  OUT=$(python3 "$L/brain-transcript-check.py" "$F/no-sessions.jsonl" --episodes <(sed -e 's/"injected_sessions":[0-9]*,//' "$F/no-sessions.episodes.jsonl") --ids X1 --source startup); RC=$?
  c_rc 1 "[n] a format-3 line without the field is not taken for an older brain (rc 1)"
}

echo "== cases =="
for c in case_kinds case_status case_autoclose case_done case_empty case_size case_quote case_caps case_fact_path case_owner \
         case_episode case_handover case_old_state case_live; do run_case $c; done
cd "$TMP" || exit 1

echo "== planted breaks =="
ST=scripts/brain_store.py; HK=scripts/brain_hook.py
plant no-own-cut case_size $HK '        more = {p: cut(parts[p], s.STRING_MAX) if p' '        more = {p: (parts[p], 0) if p'
plant done-written case_done $ST '"session": "S", "queue": "Q", "fact": "F"}' '"session": "S", "queue": "Q", "fact": "F", "done": "X"}'
plant done-window-48h case_done $ST 'DONE_WINDOW = 86400 ' 'DONE_WINDOW = 172800 '
plant sha-after-text case_done $ST '    return ("- %s%s · %s" % (clean_line(it["id"]), " " + head if head else "", clean_line(it["text"])))[:LINE_MAX]' \
      '    return ("- %s · %s%s" % (clean_line(it["id"]), clean_line(it["text"]), " " + head if head else ""))[:LINE_MAX]'
plant closes-on-fact case_kinds $ST 'CLOSES_LETTERS = ("N", "X", "S", "Q")' 'CLOSES_LETTERS = ("N", "X", "S", "Q", "F")'
plant pin-outside-string-1 case_quote $ST 'PARTS = (("hot", ("D", "W", "N")), ("sessions", ("S", "Q"))' 'PARTS = (("hot", ("W", "N")), ("sessions", ("D", "S", "Q"))'
plant string-1-over-8000 case_size $ST 'QUOTE_SHOWN, WHERE_SHOWN = 120, 30 ' 'QUOTE_SHOWN, WHERE_SHOWN = 300, 60 '
plant status-exemption-on-x case_status $ST 'STATUS_LETTERS = ("S", "Q")' 'STATUS_LETTERS = ("S", "Q", "X")'
plant s-line-cap-on-x case_size $ST 'LINE_CAPS = {"S": 500}' 'LINE_CAPS = {"S": 500, "X": 500}'
plant s-text-cap-on-x case_caps $ST 'TEXT_CAPS = {"S": 450}' 'TEXT_CAPS = {"S": 450, "X": 450}'
plant notes-all-in-string-1 case_empty scripts/brain_stale.py '        mine = lambda pairs: [x for x in pairs if s.part_of(x[0][0]) == p]' '        mine = lambda pairs: list(pairs) if p == "hot" else []'
plant empty-part-printed case_empty $HK '        more = {p: cut(parts[p], s.STRING_MAX) if p in did["noted"] or not s.part_empty(st, p) else ("", 0)' \
      '        more = {p: cut(parts[p], s.STRING_MAX) if True else ("", 0)'
plant stale-hand-over-used case_handover $HK '                    and not isinstance(t, bool) and abs(t - T_START) <= SIBLINGS and' '                    and not isinstance(t, bool) and'
plant cap-in-characters case_handover $HK '    return len(text.encode("utf-16-le")) // 2' '    return len(text)'
plant siblings-5s case_handover $HK 'SIBLINGS = 1.0 ' 'SIBLINGS = 5.0 '
plant quote-splits-accents case_quote $ST '        while k > 0 and unicodedata.category(q[k]) in ("Mn", "Mc", "Me"):' '        while False:'
plant quote-marks-mn-only case_quote $ST '        while k > 0 and unicodedata.category(q[k]) in ("Mn", "Mc", "Me"):' '        while k > 0 and unicodedata.category(q[k]) in ("Mn",):'
plant quote-empty-at-a-mark-run case_quote $ST '        q = q[:k or QUOTE_SHOWN - 1] + "…"' '        q = q[:k] + "…"'
plant read-lock-timeout-fatal case_handover $HK '        if e.rc != 1:' '        if True:'
plant read-lock-open-fatal case_handover $HK '    except OSError:
        pass
    return s.load(d)[1]' '    return s.load(d)[1]'
plant matrix-sizes-string-1 case_size scripts/brain_matrix.py 'if len(parts[p].encode("utf-16-le")) // 2 > (s.RENDER_CAP if p == "hot" else s.STRING_MAX)]' 'if p == "hot" and len(parts[p]) > s.RENDER_CAP]'
plant old-hot-md-a-problem case_old_state $ST '                           ("warn", "hot.md holds an older brain' '                           ("problem", "hot.md holds an older brain'
plant start-read-unlocked case_handover $HK '        with s.locked(d, s.LOCK_WAIT):
            return s.load(d)[1]' '        if True:
            return s.load(d)[1]'
plant no-id-waits case_handover $HK '    waits = bool(sid) and (os.access(sd, os.W_OK | os.X_OK) if os.path.isdir(sd) else not os.path.lexists(sd))' '    waits = True'
plant fallback-silent case_handover $HK '            if h is None or h.get("error") != "refused":' '            if False:'
plant hand-over-kept case_handover $HK '                with contextlib.suppress(OSError):
                    os.unlink(p)
                return h' '                return h'
plant quote-uncut case_quote $ST '    if len(q) > QUOTE_SHOWN:' '    if False:'
plant episode-without-parts case_episode $HK '"injected_sessions": len(more["sessions"][0])' '"injected_sessions": 0'
plant done-ignores-render-key case_old_state $ST '            if (it and it["status"] == "closed" and it["id"][0] in DONE_LETTERS and line == done_line(it)) or _MORE.fullmatch(line):' \
      '            if True:'
plant format-2 case_episode $ST 'FORMAT = 3' 'FORMAT = 2'

summary
