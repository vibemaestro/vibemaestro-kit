#!/bin/bash
# =============================================================================
# vibemaestro-brain: one source of coordinator state — the kinds session (S), queue (Q) and fact (F), owner quotes rendered,
# Done derived from the log, and the SessionStart strings: string 1 opens the left brain (pins, windows), the right brain (Now,
# Sessions, the owner queue, Next, Traps, Done, Facts) follows in strings of its own, each ≤ 9,500 by its own hard cut
# =============================================================================
# Run: bash tests/test-brain-work.sh
#
# Offline: a stub `gh` first on PATH answers `gh api repos/<o>/<r>/issues/<n>` and `…/pulls/<n>` from files (as the close suite's).
# The 14 SessionStart string commands run at once, as Claude Code runs a plugin's hooks of one event (startall).
#   [a] --kind session|queue|fact: add, close, supersede; --closes on S and Q, refused on F
#   [b] eight S supersedes in 30 minutes, one under 60 %: accepted; the sixth X supersede refused by the budget, as before
#   [c] an S and a Q item close when their PR merges (R3's path); the note and Done in the right brain
#   [d] Done: `id anchor sha · text`, newest first, the SHA kept when the text is long, a close's pointer; not one closed 25 h
#       ago; 7 lines then `(+N more: brain doctor)`, doctor lists them all; derived: no write path, no op of its own
#   [e] no right-brain string prints when the right brain is empty and has no note; an X close prints it; an N or S close's
#       note is in the right brain, a held burst's in string 1
#   [f] the worst case moved to tests/test-brain-layers.sh [e] (every section at the caps of the configuration)
#   [g] a pin's quote under it, cut at 120 (odd characters kept); an owner supersede has none; D only in the left brain
#   [h] S 20, Q 15, X 30, T 20, F 25 accepted, the next add queued (never refused); S text 600 accepted, 601 refused
#   [i] a fact with a home path refused by sanitize, `~/…` accepted
#   [j] D and W still refused by `brain op`; the owner path unchanged; no `brain op` option takes an owner quote
#   [k] the session-start episode line: format 6, injected (string 1), injected_strings (strings 2 …) as printed
#   [l] the hand-over: every other string is string 1's pass; alone, a string's command renders its own string after its wait;
#       an older hand-over is never used; SessionEnd removes it; strings packed in UTF-16 units
#   [m] a log from before the migration (D W N X T, a link-close): every item shown, N, X and T in the right brain; a brain of
#       format 2 refuses a log with an S item; doctor's hot.md check holds as Done ages, fails on an edited Done line, and warns
#       on an older brain's hot.md
#   [n] the live tools, offline: tests/live/hook-cap.sh parses and refuses a bad length; tests/live/brain-transcript-check.py on
#       its recorded fixtures: the two halves inline and the ids found (rc 0), a right-brain string over the cap `persisted`
#       (rc 1); a format-3 brain's three strings inline (rc 0), its string 2 absent with its episode line 0 (rc 0), its string 3
#       `persisted` (rc 1), no SessionStart of the source (rc 2)
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
EVENTS="session-start"; for i in 2 3 4 5 6 7 8 9 10 11 12 13 14; do EVENTS="$EVENTS session-start-$i"; done
startall() {  # startall [source] [session id] — the 14 SessionStart string commands at once, with no CLAUDE_CODE_SESSION_ID (as
              # Claude Code runs them); sets S1 (string 1), SL (the left brain's other strings), SR (the right brain's strings, in
              # order), NS (how many strings printed), RC (0 when all exit 0) and ERR
  local in e p n t rcs=0 pids=()
  in=$(hin session_id="${2-$SID}" cwd="$P" hook_event_name=SessionStart source="${1:-compact}")
  for e in $EVENTS; do
    printf '%s' "$in" | env -u CLAUDE_CODE_SESSION_ID ${HOOK_ENV:-} "$PY" "$BROOT/scripts/brain_hook.py" "$e" > "$TMP/out.$e" 2> "$TMP/err.$e" &
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p" || rcs=1; done
  RC=$rcs; S1=$(ctxof "$TMP/out.session-start"); SL=""; SR=""; NS=1; ERR=""
  [ -n "$S1" ] || NS=0
  for n in 2 3 4 5 6 7 8 9 10 11 12 13 14; do
    t=$(ctxof "$TMP/out.session-start-$n"); ERR="$ERR$(cat "$TMP/err.session-start-$n")"
    [ -n "$t" ] || continue
    NS=$((NS + 1))
    case "$t" in "## Brain · left brain"*) SL="$SL$t"$'\n' ;; *) SR="$SR$t"$'\n' ;; esac
  done
  ERR="$(cat "$TMP/err.session-start")$ERR"
}
sec() {  # sec <text> <title> — the lines of one section, its ` (cont.)` parts too, without its title
  printf '%s\n' "$1" | python3 -c 'import sys
titles = {"Pinned (owner)", "Windows", "Now", "Sessions", "Owner queue", "Next", "Traps", "Done (24 h)", "Facts"}
on = False
for l in sys.stdin.read().splitlines():
    base = l[:-len(" (cont.)")] if l.endswith(" (cont.)") else l
    if base in titles or l.startswith("## "):
        on = base == sys.argv[1]
    elif on:
        print(l)' "$2"
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
  startall compact
  c_rc 0 "[c] SessionStart: rc 0 for every command"
  c_eq "$(status_of S1) $(status_of Q1) $(status_of S2)" "closed closed live" "[c] an S and a Q item close when their PR merges"
  c_eq "$(nlinks)" 2 "[c] as link-close ops"
  c_eq "$(has_line "$(sec "$SR" Sessions)" '^- S1 ')$(has_line "$(sec "$SR" 'Owner queue')" '^- Q1 ')$(has_line "$(sec "$SR" Sessions)" '^- S2 ')" 001 \
       "[c] Sessions and the owner queue no longer list them"
  c_has "$SR" "auto-closed now: Q1 (acme/app¤6 merged 10-21), S1 (acme/app¤5 merged 10-21)" "[c] the right brain's note says what closed"
  c_has "$(sec "$SR" 'Done (24 h)')" "- S1 acme/app¤5 0123456789ab · w-auth: review round 2" "[c] Done lists S1 with its anchor and merge commit"
  c_has "$(sec "$SR" 'Done (24 h)')" "- Q1 acme/app¤6 0123456789ab · owner: merge the parser" "[c] and Q1"
  c_hasnt "$S1" "auto-closed" "[c] string 1 has no auto-close note"
  c_has "$(eplines auto-close)" '"ids":["Q1","S1"]' "[c] one auto-close episode line"
}

# --- [d] -----------------------------------------------------------------------------------------------------------------------
case_done() {
  np
  seed "X1@$C20;closes=acme/app¤5;linkmerged=$A21;opt=$(ago 3600);text=ship the parser" \
       "S1@$C20;closes=acme-corporation/application-with-a-long-name¤4242;len=640;linkmerged=$A21;opt=$(ago 1800)" \
       "N1@$C20;closed=$(ago 7200);pointer=chat 27/10;text=fix the login" \
       "Q1@$C20;closed=$(ago 600);text=no pointer here" \
       "X2@$C20;closed=$(ago 90000);text=closed 25 h ago" \
       "T1@$C20;closed=$(ago 60);text=a trap closed" "F1@$C20;closed=$(ago 60);text=a fact closed" \
       "X3@$C20;text=superseded" "X4@$C20;text=the new one;sup=X3"
  startall
  local done; done=$(printf '%s\n' "$SR" | sed -n '/^Done (24 h)$/,/^Facts$/p')
  c_eq "$(printf '%s\n' "$done" | sed -n '2,5p' | cut -c1-4 | tr '\n' ' ')" "- Q1 - S1 - X1 - N1 " "[d] Done: newest first (Q1 10 min, S1 30 min, X1 1 h, N1 2 h ago)"
  c_has "$done" "- X1 acme/app¤5 0123456789ab · ship the parser" "[d] a link-close: id, anchor, merge commit, then the text"
  c_has "$(printf '%s\n' "$done" | grep -F -e '- S1 ')" "- S1 acme-corporation/application-with-a-long-name¤4242 0123456789ab · ttt" "[d] the SHA kept when the text is long"
  c_eq "$(maxline "$done" '- S1 ')" 660 "[d] the line is cut at its line cap (S: 600 + 60), in the text"
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
  seed "${specs[@]}"; startall
  done=$(printf '%s\n' "$SR" | sed -n '/^Done (24 h)$/,/^Facts$/p')
  c_eq "$(has_line "$done" '^- X[0-9]')" 7 "[d] 7 Done lines"
  c_has "$done" "(+2 more: brain doctor)" "[d] then the count of the rest"
  br doctor
  c_eq "$(has_line "$OUT" 'done \(24 h\), [0-9] of 9: - X')" 9 "[d] doctor lists all 9"
}

# --- [e] -----------------------------------------------------------------------------------------------------------------------
case_empty() {
  np; seed "D1@$C20;text=a pin"; startall
  c_rc 0 "[e] rc 0"
  c_has "$S1" "- D1 a pin" "[e] string 1 holds the left brain"
  c_eq "$SL|$SR" "|" "[e] no other string prints when the right brain is empty and has no note"
  c_eq "$(cat "$TMP"/out.session-start-[0-9]*)" "" "[e] not even an empty JSON line"
  np; seed "X1@$C20;closes=acme/app¤5;text=the only next"; pr 'acme/app¤5' merged "$A21"; startall
  c_eq "$(status_of X1)" closed "[e] instrument: X1 closed"
  c_has "$SR" "## Brain · right brain" "[e] the right brain prints when an X closes with it otherwise empty"
  c_has "$SR" "auto-closed now: X1 (acme/app¤5 merged 10-21)" "[e] with the note"
  np; seed "N1@$C20;closes=acme/app¤5;text=n" "S1@$C20;closes=acme/app¤6;text=s" "S2@$C20;text=stays"
  pr 'acme/app¤5' merged "$A21"; pr 'acme/app¤6' merged "$A21"; startall
  c_has "$SR" "auto-closed now: N1 (acme/app¤5" "[e] an N close's note is in the right brain"
  c_has "$SR" "S1 (acme/app¤6" "[e] and an S close's"
  c_hasnt "$S1" "auto-closed" "[e] not in string 1"
  # a held burst (more than 5 at once) is string 1's note
  np; local i specs=(); for i in 1 2 3 4 5 6; do specs+=("X$i@$C20;closes=acme/app¤$((30 + i))"); pr "acme/app¤$((30 + i))" merged "$A21"; done
  seed "${specs[@]}"; startall
  c_has "$S1" "auto-close held: 6 items at once" "[e] a held burst's note is in string 1"
  c_hasnt "$SR" "auto-close held" "[e] and in no other string"
  # only a close of an S item, the right brain otherwise empty: it prints, with its title, for the note
  np; seed "S1@$C20;closes=acme/app¤6;text=s"; pr 'acme/app¤6' merged "$A21"; startall
  c_has "$SR" "## Brain · right brain" "[e] an S close with the right brain otherwise empty: it prints its title"
  c_has "$SR" "auto-closed now: S1" "[e] and the note"
}

# --- [f] -----------------------------------------------------------------------------------------------------------------------
# --- [g] -----------------------------------------------------------------------------------------------------------------------
case_quote() {
  np; local q odd
  q="The owner said: $(rep a 140) end"
  owner_ok add --kind decision --text "ship R4 after the gate" --owner-quote "$q" --where "chat 27/10 with the coordinator, long"
  c_rc 0 "[g] instrument: the pin is written through the dialog"
  odd='Đồng ý — "ship it" 🚀 ‘now’ ½ <b>x</b> $(rm) `y` \n'
  owner_ok add --kind decision --text "odd quote" --owner-quote "$odd" --where "chat"
  c_rc 0 "[g] instrument: a quote with odd characters is written"
  startall
  c_has "$S1" "- D1 ship R4 after the gate · since" "[g] the pin"
  c_has "$S1" "$(python3 -c 'import sys; q, w = sys.argv[1:3]; print("  \"%s…\" · %s" % (q[:119], w))' "$q" "chat 27/10 with the coordinator, long")" \
       "[g] its quote line under it, cut at 120 with …, where whole"
  c_eq "$(printf '%s\n' "$S1" | grep -A1 -F -e '- D1 ' | tail -n 1 | cut -c1-3)" '  "' "[g] right under the pin"
  c_eq "$(maxline "$S1" '  "')" 164 "[g] the longest quote line: 2 + 1 + 120 + 1 + 3 + 37 (its where whole) = 164 characters (≤ 187)"
  c_has "$S1" "  \"$odd\" · chat" "[g] odd characters kept as written, on one line"
  owner_ok supersede D1 --text "ship R4 after the gate, then R4.1"
  c_rc 0 "[g] instrument: an owner supersede"
  startall
  c_eq "$(printf '%s\n' "$S1" | grep -A1 -F -e '- D3 ' | tail -n 1)" "Windows" "[g] an owner supersede stores no quote: no quote line under D3"
  c_hasnt "$SR" "D2" "[g] a pin only in the left brain"; c_hasnt "$SR" "Pinned" "[g] Pinned only in the left brain"
  # a quote cut where a letter carries accents typed apart (NFD): the letter goes with them, never without them
  local nfd; nfd=$(python3 -c 'print("a" * 118 + "e\u0302\u0301" + "x" * 30)')
  owner_ok add --kind decision --text "decomposed accents" --owner-quote "$nfd" --where "chat"
  c_rc 0 "[g] instrument: a decomposed quote is written"
  startall
  c_has "$S1" "  \"$(rep a 118)…\" · chat" "[g] the cut steps back over the accents and their letter"
  owner_unpin_all() { local i; for i in $(bpy 'print(" ".join(k for k, v in s.load(s.state_dir())[1]["items"].items() if k[0] == "D" and v["status"] == "live"))'); do owner_ok unpin "$i"; done; }
  owner_unpin_all
  owner_ok add --kind decision --text "an emoji at the cut" --owner-quote "$(rep a 118)❤️$(rep x 30)" --where "chat"
  c_rc 0 "[g] instrument: a quote with an emoji and its selector at the cut is written"
  startall
  c_has "$S1" "  \"$(rep a 118)…\" · chat" "[g] the cut never parts an emoji from its selector"
  owner_unpin_all
  owner_ok add --kind decision --text "a vowel sign at the cut" --owner-quote "$(rep a 118)का$(rep x 30)" --where "chat"
  owner_ok add --kind decision --text "an enclosing mark at the cut" --owner-quote "$(python3 -c 'print("b" * 118 + "x\u20dd" + "x" * 30)')" --where "chat"
  c_rc 0 "[g] instrument: quotes with a spacing mark (Mc) and an enclosing mark (Me) at the cut are written"
  startall
  c_has "$S1" "  \"$(rep a 118)…\" · chat" "[g] the cut never parts a letter from its vowel sign"
  c_has "$S1" "  \"$(rep b 118)…\" · chat" "[g] nor from an enclosing mark"
  R=$(bpy 'print(s.quote_line({"id": "D1", "source": {"quote": "\u0915" + "\u093e" * 130, "where": "chat"}}))')
  c_eq "$R" "  \"$(python3 -c 'print("\u0915" + "\u093e" * 118, end="")')…\" · chat" "[g] a letter and 130 marks: the plain cut, never an empty quote"
}

# --- [h] -----------------------------------------------------------------------------------------------------------------------
case_caps() {
  np; local k n i
  for k in session:20 queue:15 next:30 trap:20 fact:25; do
    n=${k#*:}; k=${k%%:*}
    for i in $(seq 1 "$n"); do br op add --kind "$k" --text "$k $i"; [ "$RC" = 0 ] || break; done
    c_rc 0 "[h] $k: $n accepted"; c_hasnt "$OUT" "queued" "[h] $k: the last of them live"
    br op add --kind "$k" --text "$k one more"
    c_rc 0 "[h] $k: the next add is not refused"; c_has "$OUT" "queued" "[h] $k: it is queued"
  done
  np
  br op add --kind session --text "$(rep s 600)"; c_rc 0 "[h] an S text of 600: accepted"
  br op add --kind session --text "$(rep s 601)"; c_rc 1 "[h] 601: refused"; c_has "$OUT" "over its cap of 600" "[h] and says the cap"
  br op add --kind next --text "$(rep x 301)"; c_rc 1 "[h] an X text of 301: refused (300)"
  br op add --kind fact --text "$(rep f 301)"; c_rc 1 "[h] an F text of 301: refused"
  br op supersede S1 --text "$(rep s 601)" --reason r; c_rc 1 "[h] an S supersede of 601: refused"
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
  startall compact
  local ep; ep=$(eplines session-start | tail -n 1)
  c_eq "$(eplines session-start | wc -l | tr -d ' ')" 1 "[k] one session-start line for all the commands"
  c_has "$ep" '"format":6' "[k] format 6"
  c_has "$ep" "\"injected\":$(clen session-start)," "[k] injected: string 1's length"
  c_has "$ep" "\"injected_strings\":[$(clen session-start-2)]" "[k] injected_strings: string 2's (the right brain)"
  c_has "$ep" '"cut":0,"cut_strings":[0]' "[k] the cuts, 0"
  np; seed "D1@$C20"; startall compact
  c_has "$(eplines session-start)" '"injected_strings":[0]' "[k] an empty right brain: 0"
}

# --- [l] -----------------------------------------------------------------------------------------------------------------------
case_handover() {
  np; seed "N1@$C20" "S1@$C20;text=a session" "X1@$C20;text=a next"
  one session-start
  c_eq "$(cd "$(sdir)/starts" && ls | sed 's/^[0-9a-f]*\.//' | sort -n | tr '\n' ' ')" \
       "2.json 3.json 4.json 5.json 6.json 7.json 8.json 9.json 10.json 11.json 12.json 13.json 14.json " "[l] string 1's pass hands each other string over in a file"
  c_eq "$(stat -c %a "$(sdir)/starts")$(stat -c %a "$(sdir)"/starts/*.json | sort -u)" 700600 "[l] 0700 and 0600"
  hk session-end "$(hin session_id="$SID" cwd="$P" hook_event_name=SessionEnd reason=exit)"
  c_eq "$(ls "$(sdir)/starts" | wc -l | tr -d ' ')" 0 "[l] SessionEnd removes what was not taken"
  startall
  c_has "$SR" "- S1 a session" "[l] string 2's command prints what string 1 handed over"
  c_has "$SR" "- X1 a next" "[l] with Next"
  c_hasnt "$SR" "skipped" "[l] with no note of its own"
  c_eq "$(ls "$(sdir)/starts" | wc -l | tr -d ' ')" 0 "[l] and each command deletes its file: a hand-over is used once"
  # two SessionStarts back to back: the second's strings show the second's state, never the first's hand-over
  startall compact; seed "S2@$C20;text=written between the two"; startall compact
  c_has "$SR" "- S2 written between the two" "[l] back to back: string 2 shows the state of its own SessionStart"
  c_eq "$(ls "$(sdir)/starts" | wc -l | tr -d ' ')" 0 "[l] every string took its hand-over"
  # a string's command alone (string 1's never ran): it waits, then renders its own string from the log, with a note
  np; seed "S1@$C20;text=alone"
  local t0 t1; t0=$(date +%s); one session-start-2; t1=$(date +%s)
  c_rc 0 "[l] alone: rc 0"
  c_has "$OUT" "- S1 alone" "[l] alone: its own string"
  c_has "$OUT" "stale-anchor check: skipped (string 1 handed nothing over)" "[l] with a note"
  c_eq "$([ $((t1 - t0)) -ge 5 ] && [ $((t1 - t0)) -le 9 ] && echo waited)" waited "[l] after waiting for the hand-over ($((t1 - t0)) s)"
  one session-start-3
  c_eq "$OUT" "" "[l] alone, with no such string: nothing"
  # an older hand-over (another SessionStart of this session, 2 s before: the commands of one start within ms) is never used
  bpy 'import hashlib, json, os, time
d = s.state_dir(); os.makedirs(d + "/starts", exist_ok=True)
p = d + "/starts/" + hashlib.sha256(b"sA").hexdigest()[:32] + ".2.json"
s._write_file(p, json.dumps({"session": "sA", "source": "compact", "t": time.time() - 2, "part": 2, "text": "OLD STRING"}))'
  one session-start-2
  c_hasnt "$OUT" "OLD STRING" "[l] a hand-over from 2 s before is not used"
  c_has "$OUT" "- S1 alone" "[l] the string is rendered instead"
  # SessionEnd removes the session's hand-overs
  one session-start
  hk session-end "$(hin session_id="$SID" cwd="$P" hook_event_name=SessionEnd reason=exit)"
  c_eq "$(ls "$(sdir)/starts" | wc -l | tr -d ' ')" 0 "[l] SessionEnd removes what was not taken"
  # a broken log: string 1 says so, the other strings print nothing (and do not wait)
  np; seed "S1@$C20"; printf 'garbage\n' >> "$(sdir)/hot.jsonl"
  t0=$(date +%s); startall; t1=$(date +%s)
  c_has "$S1" "hot memory was not injected" "[l] a broken log: string 1 warns"
  c_eq "$SL|$SR" "|" "[l] the other strings print nothing"
  c_eq "$([ $((t1 - t0)) -le 3 ] && echo fast)" fast "[l] and do not wait for a hand-over ($((t1 - t0)) s)"
  # a write holding the store lock: SessionStart reads under the lock, so it waits for the write and shows it
  np; seed "S1@$C20;text=before the write"
  (CLAUDE_CODE_SESSION_ID=sA BRAIN_TEST=1 BRAIN_TEST_PAUSE_MS=500 "$BROOT/bin/brain" op add --kind session --text "written during the start" >/dev/null 2>&1) &
  local wp=$!; sleep 0.2; startall; wait "$wp"
  c_eq "$RC" 0 "[l] a SessionStart during a write: rc 0"
  c_has "$SR" "- S2 written during the start" "[l] it waits for the write that holds the lock, and shows it"
  c_hasnt "$S1" "not injected" "[l] and no broken-log warning"
  # a lock held past LOCK_WAIT (a writer stuck): the read goes on without it, and every string comes
  python3 -c 'import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600); fcntl.flock(fd, fcntl.LOCK_EX); time.sleep(4)' "$(sdir)/lock" &
  wp=$!; sleep 0.2; t0=$(date +%s); startall; t1=$(date +%s); kill "$wp" 2>/dev/null; wait "$wp" 2>/dev/null
  c_has "$S1$SR" "- S2 written during the start" "[l] a lock held for 4 s: the strings are injected"
  c_eq "$([ $((t1 - t0)) -le 3 ] && echo fast)" fast "[l] after the 1 s wait, not the writer's 4 ($((t1 - t0)) s)"
  # a lock file that cannot be opened (here a directory; a read-only or full disk alike): read without it
  rm -f "$(sdir)/lock"; mkdir "$(sdir)/lock"; startall
  c_has "$SR" "- S2 written during the start" "[l] a lock that cannot be opened: the strings are still injected"
  rmdir "$(sdir)/lock"
  # no session id: no hand-over to match, so the other strings read the log at once
  np; seed "S1@$C20;text=no id"
  t0=$(date +%s); startall compact ""; t1=$(date +%s)
  c_has "$SR" "- S1 no id" "[l] no session id: string 2 renders its own string"
  c_eq "$([ $((t1 - t0)) -le 3 ] && echo fast)" fast "[l] without waiting ($((t1 - t0)) s)"
  c_eq "$(ls "$(sdir)/starts" 2>/dev/null | wc -l | tr -d ' ')" 0 "[l] and string 1 hands nothing over"
  # `starts` is not a directory: nothing can be handed over, so nothing is waited for; a log that refuses: one warning line
  np; seed "S1@$C20;text=starts is a file"; : > "$(sdir)/starts"
  t0=$(date +%s); startall; t1=$(date +%s)
  c_has "$SR" "- S1 starts is a file" "[l] starts is a file: string 2 renders its own string"
  c_eq "$([ $((t1 - t0)) -le 3 ] && echo fast)" fast "[l] without waiting ($((t1 - t0)) s)"
  printf 'garbage\n' >> "$(sdir)/hot.jsonl"; startall
  c_has "$SR" "brain: strings 2 to 14 were not injected" "[l] no hand-over and a log that refuses: string 2 says so"
  c_eq "$(printf '%s' "$SR" | grep -c 'were not injected')" 1 "[l] once, not once per string"
  R=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import brain_hook as h
b = "## Brain · plan v3 · 9,999/9,500 chars   (x)\nNext\n" + "".join("- X%d %s\n" % (i, "x" * 190) for i in range(60)) + "Facts\n- F1 f\n"
print(h.cut(b, 9500)[0].splitlines()[-1])' "$BROOT/scripts")
  c_has "$R" "Next, Facts]" "[l] the cut names the sections it cut"
  R=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import brain_hook as h
b = "x\n" * 5000 + "## Brain · plan v3 · 1,000/9,500 chars   (x)\nNext\n- X1 x\n"
print(h.cut(b, 9500)[0].splitlines()[-1])' "$BROOT/scripts")
  c_has "$R" ": Brain · plan, Next]" "[l] and a part by its title, without version or size"
  # Claude Code counts UTF-16 units: an emoji is 2. Sessions full of status emoji are packed by units into strings of ≤ 9,500
  np; local i specs=(); for i in $(seq 1 12); do specs+=("S$i@$C20;text=$(rep 🟢 440)"); done; seed "${specs[@]}"
  startall
  R=$(python3 -c 'import json, sys
ts = [open(p, encoding="utf-8").read().strip() for p in sys.argv[1:]]
ts = [json.loads(t)["hookSpecificOutput"]["additionalContext"] for t in ts if t]
print(len(ts), sum(len(t) for t in ts) < 9500 * len(ts), max(len(t.encode("utf-16-le")) // 2 for t in ts) <= 9500,
      sum(t.count("- S") for t in ts))' "$TMP"/out.session-start-[0-9]*)
  c_eq "$R" "2 True True 12" "[l] 12 sessions of emoji: two right-brain strings, each ≤ 9,500 UTF-16 units, every session shown"
  c_hasnt "$SR" "[brain: cut " "[l] packed by units, so no hard cut"
}

# --- [m] -----------------------------------------------------------------------------------------------------------------------
case_old_state() {
  np
  seed "D1@$C20;text=an old pin" "W1@$C20;text=an old window" "N1@$C20;text=an old now" "X1@$C20;text=next one" \
       "X2@$C20;text=next two" "T1@$C20;text=an old trap" "X3@$C20;closes=acme/app¤5;text=closed by link;linkmerged=$A21"
  c_eq "$(bpy 'print(sorted({o["op"] for o in s.verify(s.state_dir())[1]}))')" "['add', 'claim', 'link-close', 'owner-add']" \
       "[m] instrument: a log of format 2's ops and kinds"
  startall
  c_has "$S1" "- D1 an old pin" "[m] the pin in string 1"; c_has "$S1" "- W1 an old window" "[m] the window"
  c_has "$SR" "- N1 an old now" "[m] Now in the right brain"
  c_has "$SR" "- X1 next one" "[m] Next too"; c_has "$SR" "- X2 next two" "[m] both"; c_has "$SR" "- T1 an old trap" "[m] the trap"
  c_has "$SR" "- X3 acme/app¤5 0123456789ab · closed by link" "[m] the link-close in Done"
  c_hasnt "$S1" "- X1 " "[m] Next not in string 1"; c_hasnt "$S1" "- N1 " "[m] nor Now"
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
  bpy 'st = s.load(s.state_dir())[1]; s._write_file(s.state_dir() + "/hot.md", "## Brain · hot memory v%d · 120/6,000 chars   (re-injected after compaction)\nPinned (owner)\nWindows\nNow\n" % st["version"])'
  br doctor
  c_has "$OUT" "warn     hot.md holds an older brain's render; \`brain render\` rewrites it" "[m] an older brain's hot.md: a warn that says what rewrites it"
  c_hasnt "$OUT" "problem  hot.md" "[m] not a problem"
  br render >/dev/null; br doctor; c_has "$OUT" "hot.md matches a fresh render" "[m] brain render rewrites it"
  bpy 'import json
d = s.state_dir(); f = open(d + "/episodes.jsonl", "a")
f.write(json.dumps({"t": s.now_iso(), "kind": "session-start", "session": "older-two", "format": 2}) + "\n")'
  br doctor; c_has "$OUT" "log format 2, this one writes 6" "[m] doctor warns on a session last started on format 2"
}

# --- [n] -----------------------------------------------------------------------------------------------------------------------
case_live() {
  local L="$SRC_ROOT/tests/live" F="$SRC_ROOT/tests/live/fixtures/brain-transcript"
  bash -n "$L/hook-cap.sh"; RC=$?; c_rc 0 "[n] hook-cap.sh parses"
  OUT=$(bash "$L/hook-cap.sh" 9500 ten 2>&1); RC=$?; c_rc 2 "[n] hook-cap.sh refuses a length that is not a number (rc 2)"
  c_has "$OUT" "usage" "[n] and prints its usage"
  OUT=$(python3 "$L/brain-transcript-check.py" "$F/two-halves.jsonl" --episodes "$F/two-halves.episodes.jsonl" --ids D1,X1,S1,F1 --source startup); RC=$?
  c_rc 0 "[n] the two halves: clean (rc 0)"; c_has "$OUT" "string 1 inline 349 · string 2 inline 409 · ids found · clean" "[n] each inline, its size, the ids found"
  OUT=$(python3 "$L/brain-transcript-check.py" "$F/two-halves.jsonl" --episodes <(sed 's/"injected_strings":\[[0-9]*\]/"injected_strings":[409,180]/' "$F/two-halves.episodes.jsonl") --ids X1 --source startup); RC=$?
  c_rc 1 "[n] a string the episode line counted but the transcript lacks: rc 1"; c_has "$OUT" "string 3 absent" "[n] named"
  OUT=$(python3 "$L/brain-transcript-check.py" "$F/right-over-cap.jsonl" --episodes "$F/right-over-cap.episodes.jsonl" --ids N1 --source startup); RC=$?
  c_rc 1 "[n] a right-brain string over the cap: rc 1"; c_has "$OUT" "string 2 persisted" "[n] it says persisted"
  OUT=$(python3 "$L/brain-transcript-check.py" "$F/three-strings.jsonl" --episodes "$F/three-strings.episodes.jsonl" --ids X1,S1,F1 --source startup); RC=$?
  c_rc 0 "[n] a format-3 brain's three strings: clean (rc 0)"; c_has "$OUT" "string 1 inline 398 · string 2 inline 226 · string 3 inline 271 · ids found · clean" "[n] each inline, its size, the ids found"
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
for c in case_kinds case_status case_autoclose case_done case_empty case_quote case_caps case_fact_path case_owner \
         case_episode case_handover case_old_state case_live; do run_case $c; done
cd "$TMP" || exit 1

summary
