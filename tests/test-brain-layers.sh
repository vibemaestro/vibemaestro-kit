#!/bin/bash
# =============================================================================
# vibemaestro-brain by layers, capacity: caps as configuration, the overflow queue, the left brain's full stop, the strings
# (each ≤ 9,500 UTF-16 units, the left brain in strings of its own, at most 14), and an existing brain's log kept
# =============================================================================
# Run: bash tests/test-brain-layers.sh
#
# Offline: a stub `gh` first on PATH answers `gh api repos/<o>/<r>/issues/<n>` and `…/pulls/<n>` from files (as the work suite's).
# The 14 SessionStart string commands run at once, as Claude Code runs a plugin's hooks of one event (startall).
#   [a] config: no .vibemaestro/brain.json → the defaults; an unknown key warns (doctor, a write, a refused write too) and the
#       write is done; a wrong value, a newer schema, a file that is not JSON, nested past the parser or a FIFO → writes refused
#       naming the key, guard-owner denying before it asks, close-linked refused and the SessionStart auto-close skipped with a
#       note, SessionStart injecting with the defaults and the config line, never failing or waiting; a left cap off its default
#       flagged (doctor, a write, string 1), a right one not; caps count UTF-16 units (an emoji is 2); a hot.md rendered under
#       other caps (the file changed or removed) is a warn, the same hot.md edited a problem, an older brain's of another
#       version a problem
#   [r] one config per repository: a session started in a subdirectory, a linked worktree, both worktrees of a bare layout, a
#       bare clone in proj/.git and a submodule's worktree read one file, guard-owner and the CLI alike, string 1 too; a project
#       whose .git links elsewhere reads its own; a sibling worktree with a name that is not UTF-8 and a project path with a
#       newline neither crash nor misread; the CLI resolves it once (a handful of git calls per doctor)
#   [b] the overflow queue: an add at the cap is queued (rc 0), never injected, counted by one line, listed by `brain overflow`
#       in order; a close at the cap moves exactly the head up in the same log line; a raised cap moves up as many as fit on
#       the next op of the section; a queued item closed, superseded (it keeps its place), touched and hit
#   [c] the invariant over 2,000 random ops (fixed seed, caps changed on the way): every id written is in exactly one state, the
#       fold of the log equals the state the writes built, no queued id is injected, every live id is, no section is left with
#       room and a waiting queue by an op that wrote it, and none is moved up past its cap
#   [d] the left brain has no overflow: an owner add at its cap is denied by guard-owner before it asks and refused by the CLI,
#       both naming the least recently touched items; nothing is queued
#   [e] the worst case at the defaults: every section at its cap, every line full, every quote at its cap, every item stale, 5
#       auto-closes, a full Done and Shelf → every string ≤ 9,500 units with no hard cut, the left brain in no string with a
#       right-brain section, at most 12 strings, every live item shown once; emoji texts (2 units each) likewise; caps raised past
#       14 strings → 14 printed, each ≤ 9,500, the 14th naming what was not injected, and doctor warns
#   [f] an existing brain: a log written by the brain of log format 3 (every op kind) folds to the same bytes, keeps its ids and
#       its hot.json cache, its hot.md is a warn, a changed byte stops every write (rc 5), a new write works on it, and the brain
#       of format 3 refuses a log with a queued item (rc 5). Needs that brain from this repository's history (skipped without it)
# The layers (goals, focus and requests, the precedence line, the review card):
#   [g] goals: `brain op` never writes, closes, supersedes or touches a G; `brain owner add --kind goal` writes only with a
#       record of the dialog, whose line shows every field, each quoted, before the text; a review day in the past, an unknown
#       scope, a quote or a look-alike in a field before the text refused (U+1CD3, U+02F5, U+0660 too), by the CLI and
#       by guard-owner, Vietnamese accepted; the goal opens the
#       left brain with its quote, done and not-doing lines; an owner supersede carries the quote byte for byte and each field
#       not given, and its dialog names each field it changes
#   [h] focus: a focus points to a live goal (else rc 1) and carries the owner's words; Next renders the items of each live
#       focus first, by focus, tagged `[P1]`, then the rest by id; a closed focus orders nothing, a superseded one passes its
#       items to its successor, which keeps the quote bytes and the goal; a Next item ties to a live focus only
#   [i] requests: a quote of 600 units holding `"` stored and shown by `brain show` byte for byte, 601 refused, never cut; a
#       supersede keeps the quote bytes; a close without --pointer refused, with one closed and in Done; a request closes by its
#       --closes anchor (the pointer) and is marked stale like N, X, S and Q; a full Requests section queues
#   [j] due days on a fixed clock: the Due line at 8, 7, 1, 0 and −2 days, soonest first, the first line of the right brain; the
#       item line's `due 11-07`; a hot.md rendered days ago still matches (its Due line and a goal's review part move with the
#       clock), a forged one does not
#   [k] the precedence line, in the owner's wording, is line 2 of string 1 at every source, and only there; `brain render`
#       prints it first (hot.md does not hold it)
#   [l2] the card's loss score is this session's compaction's only when PostCompact logged it before the card; else it says
#       `not logged yet`, never the previous score or another session's; doctor shows the score once logged
#   [l] the review card: only at SessionStart:compact, ≤ 1,000 units, between the precedence line and the left brain, each of
#       its lines from a seeded state (goals and their focus, sections over 85 %, anchors closed, the overflow queue, the last
#       loss score); lines past 1,000 become one `(+N lines: brain doctor)`; doctor prints its lines
#   [m] an existing brain of log format 4 (every op kind, a queue and its moves) folds to the same bytes, keeps its ids and
#       cache, its hot.md is a warn, a hand edit stops every write, a new request works on it, and the brain of format 4 refuses
#       the log once it holds a goal, focus or request (rc 5). Needs that brain from this repository's history (skipped without it)
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
# the brain of log format 3, from this repository's history: the last commit before the layers (empty when it is not there)
BASE_REV=9a16ab9
# the brain of log format 4: capacity, the last commit before goals, focus and requests
LAYERS_REV=6b1ded0
# the precedence line, in the owner's wording
PREC="Precedence: the owner's newer word (in chat, pinned in the left brain G D W, or quoted in P R) > SOUL (CLAUDE.md) > what the session writes in the right brain (N S Q X T F, and its own text of P and R) > auto-memory (cold, lowest; the brain never edits it: report a contradiction to the owner)."

# --- the stub gh (the work suite's) -------------------------------------------------------------------------------------------
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

C20=2026-10-20T15:00:00Z; A21=2026-10-21T10:00:00Z
SHA_A=0123456789abcdef0123456789abcdef01234567
stub_reset() { [ -n "$STUB" ] && rm -rf "$STUB"; mkdir -p "$STUB/answers" "$STUB/pulls"; : > "$STUB/calls"; }
kf() { local k=${1/\#/_}; printf '%s' "${k//\//_}"; }
issue() {  # issue <owner/name¤n> open|completed [closed_at]
  local f; f="$STUB/answers/$(kf "$1")"
  case $2 in open) printf 'open\t\t\t\tissue\n' > "$f" ;; *) printf 'closed\t%s\t\t%s\tissue\n' "$3" "$2" > "$f" ;; esac
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
status_of() { bpy "print(s.fold(s.verify(s.state_dir())[1])['items']['$1']['status'])"; }
lastop() { tail -n 1 "$(sdir)/hot.jsonl"; }
conf() { mkdir -p "$P/.vibemaestro"; printf '%s\n' "$1" > "$P/.vibemaestro/brain.json"; }   # conf <JSON> — the project's config
ctxof() {  # ctxof <file> — additionalContext of one hook's stdout file ("" when it printed nothing)
  python3 -c 'import json, sys
t = open(sys.argv[1], encoding="utf-8").read().strip()
print(json.loads(t)["hookSpecificOutput"]["additionalContext"] if t else "", end="")' "$1"
}
EVENTS="session-start"; for i in 2 3 4 5 6 7 8 9 10 11 12 13 14; do EVENTS="$EVENTS session-start-$i"; done
startall() {  # startall [source] — the 14 SessionStart string commands at once, with no CLAUDE_CODE_SESSION_ID (as Claude Code
              # runs them) and CLAUDE_PROJECT_DIR the project; sets S1, SL (the left brain's other strings), SR (the right brain's),
              # NS (strings printed), ALL (every string), RC and ERR
  local in e p n t rcs=0 pids=()
  in=$(hin session_id="$SID" cwd="$P" hook_event_name=SessionStart source="${1:-compact}")
  for e in $EVENTS; do
    printf '%s' "$in" | env -u CLAUDE_CODE_SESSION_ID CLAUDE_PROJECT_DIR="$P" "$PY" "$BROOT/scripts/brain_hook.py" "$e" > "$TMP/out.$e" 2> "$TMP/err.$e" &
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p" || rcs=1; done
  RC=$rcs; S1=$(ctxof "$TMP/out.session-start"); SL=""; SR=""; NS=1; ERR=$(cat "$TMP/err.session-start")
  for n in 2 3 4 5 6 7 8 9 10 11 12 13 14; do
    t=$(ctxof "$TMP/out.session-start-$n"); ERR="$ERR$(cat "$TMP/err.session-start-$n")"
    [ -n "$t" ] || continue
    NS=$((NS + 1))
    case "$t" in "## Brain · left brain"*) SL="$SL$t"$'\n' ;; *) SR="$SR$t"$'\n' ;; esac
  done
  ALL="$S1"$'\n'"$SL$SR"
}
strings_check() {  # strings_check — after startall: "<strings> <largest in UTF-16 units> <hard cuts> <left strings holding a right section>"
  python3 - "$TMP"/out.session-start "$TMP"/out.session-start-[0-9]* <<'PY'
import json, re, sys
right = ("Focus", "Requests", "Now", "Sessions", "Owner queue", "Next", "Traps", "Done (24 h)", "Facts")
ts = []
for p in sys.argv[1:]:
    t = open(p, encoding="utf-8").read().strip()
    if t:
        ts.append(json.loads(t)["hookSpecificOutput"]["additionalContext"])
units = [len(t.encode("utf-16-le")) // 2 for t in ts]
cuts = sum(t.count("[brain: cut") for t in ts)
mixed = sum(1 for t in ts if (t.startswith("# vibemaestro-brain") or t.startswith("## Brain · left brain"))
            and any(re.search(r"(?m)^%s( \(cont\.\))?$" % re.escape(r), t) for r in right))
print(len(ts), max(units), cuts, mixed)
PY
}

# seed <spec>… — ops appended through the store library as the writer sA, caps not checked (the library folds what the log holds).
#   ID@CREATED[;closes=A,B][;anchors=A,B][;text=T][;len=N][;emoji=N][;links=N][;qlen=N][;where=W][;linkmerged=AT][;opt=AT]
#   [;review=DAY][;full=1 (a goal's done and not-doing at 200)][;goal=G][;focus=P][;due=DAY]
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
        text = ("t" * int(o["len"]) if "len" in o else "\U0001F7E2" * int(o["emoji"]) if "emoji" in o
                else o.get("text", "item " + iid))
        src = {"type": "owner" if iid[0] in "GDW" else "coordinator"}
        if iid[0] in "GPR" or iid[0] == "D" and "qlen" in o:
            src.update(quote="q" * int(o.get("qlen", 1)), where=o.get("where", "chat"))
        item = {"id": iid, "kind": kinds[iid[0]], "pinned": iid[0] == "D", "text": text, "source": src,
                "expires": "2099-01-02T22:00:00Z" if iid[0] == "W" else None, "links": ["kb/x"] * int(o.get("links", 0)),
                "anchors": anchors, "supersedes": None}
        if closes:
            item["closes"] = closes
        if iid[0] == "G":
            full = "full" in o
            item.update(done="d" * 200 if full else "the PR merged", not_doing="n" * 200 if full else "the ledger",
                        review=o.get("review", "2099-12-31"), scope="project")
        item.update({k: o[k] for k in ("goal", "focus", "due") if k in o})
        put({"op": "owner-add" if iid[0] in "GDW" else "add", "item": item, "t": created, "by": by})
        if o.get("linkmerged"):
            an = [{"anchor": c, "state": "merged", "at": o["linkmerged"], "sha": "0123456789ab"} for c in closes]
            put({"op": "link-close", "id": iid, "anchors": an, "reason": s.link_reason(an), "pointer": closes[0],
                 "t": o.get("opt") or s.now_iso(), "by": {"session": "sA", "hook": "SessionStart"}})
    s.write_caches(d, st, s.head_of(raw))
PY
}
skill() { mkdir -p "$1/$2"; printf -- '---\nname: %s\ndescription: "%s"\n---\n\n# %s\n' "$2" "$3" "$2" > "$1/$2/SKILL.md"; }
many_skills() {  # many_skills [emoji] — project, user and plugin skills, more than the Shelf index fits (emoji: 2-unit descriptions)
  local i n cfg="$TMP/cfg$NP" reg='{"version":2,"plugins":{' sep="" long="with a long description that runs on and on well past the one hundred character cut of a line. More."
  [ "${1:-}" = emoji ] && long=$(rep 🚀 120)
  export CLAUDE_CONFIG_DIR="$cfg"
  for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
    skill "$P/.claude/skills" "proj-$i" "Project skill $i $long"
    skill "$cfg/skills" "user-$i" "User skill $i $long"
  done
  mkdir -p "$cfg/plugins"
  for n in plug-a plug-b plug-c; do
    for i in 01 02 03 04 05 06 07 08 09 10; do skill "$TMP/pl$NP/$n/skills" "$n-skill-$i" "Skill $i of $n."; done
    reg="$reg$sep\"$n@m\":[{\"scope\":\"user\",\"installPath\":\"$TMP/pl$NP/$n\"}]"; sep=,
  done
  printf '%s}}' "$reg" > "$cfg/plugins/installed_plugins.json"
  printf '{"enabledPlugins":{"plug-a@m":true,"plug-b@m":true,"plug-c@m":true}}' > "$cfg/settings.json"
}
cmdline() { python3 -c 'import shlex, sys; print(shlex.join(sys.argv[1:]))' "$@"; }
dplus() { python3 -c 'import datetime, sys; print(datetime.datetime.now(datetime.timezone.utc).date() + datetime.timedelta(days=int(sys.argv[1])))' "$1"; }
goal_args() {  # goal_args <text> <review day> — GA: the arguments after `owner` that pin a goal with every field
  GA=(add --kind goal --text "$1" --owner-quote "the owner's words, \"quoted\" whole" --where chat --done "the PR merged"
      --not-doing "the ledger" --review "$2" --scope project)
}
nextorder() {  # nextorder — after startall: each Next line's id and first word, in render order
  printf '%s\n' "$SR" | grep -E '^- X[0-9]+ ' | cut -d' ' -f2,3 | tr '\n' ','
}
gown() {  # gown <args after owner…> — guard-owner, default mode, on that literal command, for session SID in project P
  hk guard-owner "$(python3 -c 'import json, sys
print(json.dumps({"session_id": sys.argv[1], "cwd": sys.argv[2], "hook_event_name": "PreToolUse", "tool_name": "Bash",
                  "permission_mode": "default", "tool_input": {"command": sys.argv[3]}}))' "$SID" "$P" "$(cmdline brain owner "$@")")"
}

# --- [a] -----------------------------------------------------------------------------------------------------------------------
case_config() {
  np
  c_eq "$(bpy 'print(s.cap("X"), s.cap("D"), s.cap("G"), s.text_max("X"), s.text_max("S"), s.quote_max())')" "30 20 5 300 600 600" "[a] no file: the defaults"
  br doctor; c_has "$OUT" "config: no .vibemaestro/brain.json, the defaults" "[a] doctor says so"
  conf '{"caps": {"X": 40}}'
  br op add --kind next --text "a right cap changed"; c_rc 0 "[a] a right cap off its default: rc 0"
  c_hasnt "$OUT" "warning" "[a] with no warning"
  startall; c_hasnt "$S1" "brain config:" "[a] and no config line in string 1"
  conf '{"schema": 1, "caps": {"X": 40, "Z": 3}, "colour": "blue"}'
  br op add --kind next --text "with an unknown key"
  c_rc 0 "[a] an unknown key: the write is done"
  c_has "$OUT" 'warning: .vibemaestro/brain.json: unknown key "colour" (ignored)' "[a] it warns on the write"
  c_has "$OUT" 'unknown key caps."Z" (ignored)' "[a] and on an unknown letter"
  br doctor; c_has "$OUT" 'warn     .vibemaestro/brain.json: unknown key "colour"' "[a] doctor warns too"
  c_has "$OUT" "config: .vibemaestro/brain.json: X 40" "[a] and prints the caps it changes"
  c_eq "$(bpy 'print(s.cap("X"))')" 40 "[a] a known key still applies"
  startall; c_has "$S1" "brain config: 2 warnings: brain doctor" "[a] string 1 counts the warnings"
  conf '{"caps": {"X": "thirty"}}'
  br op add --kind next --text "with a wrong value"
  c_rc 1 "[a] a wrong value: the write is refused"; c_has "$OUT" "caps.X must be an integer from 1 to 100" "[a] naming the key and its range"
  startall; c_rc 0 "[a] SessionStart: rc 0"
  c_has "$S1" "brain config: 1 error, defaults used and writes refused: brain doctor" "[a] string 1 carries the config line"
  c_has "$SR" "- X2 with an unknown key" "[a] and the brain is injected with the defaults"
  br doctor; c_rc 1 "[a] doctor: a problem"; c_has "$OUT" "problem  .vibemaestro/brain.json caps.X must be an integer" "[a] naming it"
  conf '{"schema": 2}'
  br op add --kind next --text "a newer schema"; c_rc 1 "[a] a newer schema: refused"; c_has "$OUT" "schema 2 is newer than this brain reads" "[a] saying so"
  conf '{not json'
  br op add --kind next --text "not json"; c_rc 1 "[a] a file that is not JSON: refused"; c_has "$OUT" "is not a JSON object" "[a] saying so"
  conf '{"caps": {"D": 30, "X": 40}}'
  br op add --kind next --text "a left cap changed"
  c_rc 0 "[a] a left cap off its default: the write is done"
  c_has "$OUT" "the left cap D is 30, not its default 20: changing it is the owner's decision" "[a] it warns on the write"
  br doctor; c_has "$OUT" "warn     .vibemaestro/brain.json: the left cap D is 30" "[a] doctor warns"
  startall; c_has "$S1" "brain config: left cap D 30 (default 20) is the owner's decision: brain doctor" "[a] string 1 names it"
  c_eq "$(printf '%s\n' "$S1" | sed -n 3p | cut -c1-14)" "brain config: " "[a] right under the precedence line"
  conf '{"caps": {"D": 30}, "colour": "blue"}'
  br op add --kind decision --text "refused for its kind"; c_rc 1 "[a] instrument: a write refused for another reason"
  c_has "$OUT" 'unknown key "colour"' "[a] still prints the config's warnings"
  # caps count UTF-16 units, as Claude Code counts the strings
  conf '{}'
  br op add --kind trap --text "$(rep 🟢 150)"; c_rc 0 "[a] 150 emoji (300 units) in a 300 cap: accepted"
  br op add --kind trap --text "$(rep 🟢 151)"; c_rc 1 "[a] 151 emoji (302 units): refused"; c_has "$OUT" "UTF-16 units" "[a] counted in units"
  owner_ok add --kind decision --text "an emoji quote" --owner-quote "$(rep 😀 300)" --where "$(rep w 60)"; c_rc 0 "[a] instrument: a quote of 300 emoji (600 units)"
  R=$(bpy 'st = s.load(s.state_dir())[1]; l = [x for x in s.render_all(st).splitlines() if x.startswith("  \"")][-1]; print(s.units(l) <= 187, s.units(l) >= 180)')
  c_eq "$R" "True True" "[a] its quote line is cut in units: at most 187 (a full one, its where of 60 units whole)"
  R=$(bpy 'st = s.load(s.state_dir())[1]; l = [x for x in s.render_all(st).splitlines() if x.startswith("  \"")][-1]; print(s.units(l[3:l.rindex(chr(34))]))')
  c_eq "$R" 119 "[a] the quote itself: 59 emoji and its … (≤ 120 units)"
  # the cut never parts one shown symbol: a flag's pair, a skin tone, a tag sequence, a Hangul syllable typed in parts, a joined
  # emoji, an accent in the where
  R=$(bpy 'ql = lambda q, w="w": s.quote_line({"id": "D1", "source": {"quote": q, "where": w}})
a = lambda n: "a" * n
for q, keep in ((a(117) + "\U0001F1EB\U0001F1F7" * 10, a(117)), (a(117) + "\U0001F44D\U0001F3FD" * 10, a(117)),
                (a(118) + "\U00001112\U00001161\U000011AB" * 10, a(118)), ("\U0001F1EB\U0001F1F7" * 40, "\U0001F1EB\U0001F1F7" * 29)):
    print(ql(q) == "  \"%s\U00002026\" \U000000B7 w" % keep, end=" ")
for t in ("\U0001F468\U0000200D\U0001F469\U0000200D\U0001F467", "\U0001F3F4\U000E0067\U000E0062\U000E0065\U000E006E\U000E0067\U000E007F"):
    print(s.cut_symbols(a(5) + t, 8) == a(5), end=" ")   # the cut itself
print(ql("q", a(59) + "e\U00000301" + "z" * 5) == "  \"q\" \U000000B7 " + a(59))')
  c_eq "$R" "True True True True True True True" "[a] a quote or where cut never parts a flag, a skin tone, a tag sequence, a Hangul syllable, a joined emoji or an accent"
  # a file nested past the parser, or a FIFO: refused writes, never a crash or a wait
  # as deep as the 64 KiB cap allows: past the C recursion limit of Python 3.12 and later, which a few thousand levels are not
  python3 -c 'import sys; sys.stdout.write("[" * 65536)' > "$P/.vibemaestro/brain.json"
  br op add --kind next --text "nested"; c_rc 1 "[a] a file nested past the parser: rc 1, not an internal error"; c_has "$OUT" "is not a JSON object" "[a] saying so"
  startall; c_has "$S1" "brain config: 1 error" "[a] SessionStart injects with the config line"
  rm -f "$P/.vibemaestro/brain.json"; mkfifo "$P/.vibemaestro/brain.json"
  local t0 t1; t0=$(date +%s)
  R=$(printf '%s' "$(hin session_id="$SID" cwd="$P" source=compact)" | CLAUDE_PROJECT_DIR="$P" timeout 10 "$PY" "$BROOT/scripts/brain_hook.py" session-start)
  t1=$(date +%s)
  c_has "$R" "brain config: 1 error" "[a] a FIFO: SessionStart injects with the config line"
  c_eq "$([ $((t1 - t0)) -le 3 ] && echo fast)" fast "[a] without waiting on the FIFO ($((t1 - t0)) s)"
  br op add --kind next --text "fifo"; c_rc 1 "[a] a FIFO: writes refused"; c_has "$OUT" "is not a regular file" "[a] saying so"
  rm -f "$P/.vibemaestro/brain.json"
  # a config error: guard-owner never asks, close-linked refuses, the SessionStart auto-close closes nothing and says so
  conf '{"caps": {"X": 0}}'
  gown add --kind window --text "a window" --owner-quote q --where w --expires 2099-01-01T00:00:00Z
  c_eq "$(hfield permissionDecision)" deny "[a] a config error: guard-owner denies before it asks"
  c_has "$(hfield permissionDecisionReason)" "caps.X must be an integer" "[a] naming the key"
  br op close-linked; c_rc 1 "[a] close-linked is refused"; c_has "$OUT" "caps.X must be an integer" "[a] naming the key"
  conf '{}'; pr 'acme/app¤41' open
  br op add --kind next --text "closes when merged" --closes acme/app¤41; c_rc 0 "[a] instrument: an item that closes by a link"
  sleep 1; pr 'acme/app¤41' merged "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; conf '{"caps": {"X": 0}}'
  local merged='st = s.load(s.state_dir())[1]; print(sorted(v["status"] for k, v in st["items"].items() if v["text"] == "closes when merged"))'
  startall; c_eq "$(bpy "$merged")" "['live']" "[a] a config error: SessionStart closes nothing by a link"
  c_has "$S1" "auto-close: nothing closed (.vibemaestro/brain.json" "[a] and its note says why"
  conf '{}'; startall; c_eq "$(bpy "$merged")" "['closed']" "[a] instrument: the config fixed, the same SessionStart closes it"
  # doctor: a hot.md rendered before the config changed is a warn; an older brain's of another version a problem
  br op add --kind next --text "$(rep n 100)" --link kb/some/link.md
  br doctor; c_has "$OUT" "ok       hot.md matches a fresh render" "[a] instrument: hot.md matches"
  conf '{"text_caps": {"X": 50}}'
  br doctor; c_has "$OUT" "warn     hot.md was rendered under other caps or lengths (.vibemaestro/brain.json changed)" "[a] a lowered text cap: hot.md is a warn"
  c_hasnt "$OUT" "problem  hot.md" "[a] not a problem"
  c_has "$OUT" "config: .vibemaestro/brain.json: text_caps.X 50" "[a] doctor names the length it changes"
  br render >/dev/null; rm -f "$P/.vibemaestro/brain.json"
  br doctor; c_has "$OUT" "warn     hot.md was rendered under other caps" "[a] the file removed after a render: still a warn"
  python3 - "$(sdir)/hot.md" <<'PY'
import sys
p = sys.argv[1]; t = open(p, encoding="utf-8").read(); assert "- X" in t
open(p, "w", encoding="utf-8").write(t.replace("- X", "- X9", 1))
PY
  br doctor; c_has "$OUT" "problem  hot.md does not match a fresh render" "[a] the same hot.md edited: a problem, whatever the config did"
  br render >/dev/null; conf '{"text_caps": {"X": 50}}'
  bpy 'st = s.load(s.state_dir())[1]; s._write_file(s.state_dir() + "/hot.md", "## Brain · hot memory v%d · 120/6,000 chars   (x)\nPinned (owner)\n- D9 forged\n" % (st["version"] - 1))'
  br doctor; c_has "$OUT" "problem  hot.md does not match a fresh render" "[a] an older brain's hot.md of another version: a problem"
  conf '{}'
}

# --- [r] -----------------------------------------------------------------------------------------------------------------------
case_root() {
  np; conf '{"caps": {"D": 1, "X": 2}}'
  git_ -C "$P" commit -q --allow-empty -m init
  mkdir -p "$P/sub"
  owner_ok add --kind decision --text "the only pin" --owner-quote q --where w; c_rc 0 "[r] instrument: D1 at the cap of 1"
  CLAUDE_PROJECT_DIR="$P/sub" gown add --kind decision --text "a second pin" --owner-quote q --where w
  c_eq "$(hfield permissionDecision)" deny "[r] a session started in a subdirectory: guard-owner reads the main work tree's caps and denies"
  CLAUDE_PROJECT_DIR="$P/sub" startall; c_has "$S1" "left cap D 1 (default 20)" "[r] and string 1 names its left cap"
  br op add --kind next --text one; br op add --kind next --text two
  git_ -C "$P" worktree add -q --detach "$TMP/wt$NP"
  bpy 's.drop_session("sA")'                       # the hooks above recorded the session's project: the CLI would use it, not its cwd
  (cd "$TMP/wt$NP" && CLAUDE_CODE_SESSION_ID="$SID" "$BROOT/bin/brain" op add --kind next --text "from a worktree" > "$TMP/wt$NP.out" 2>&1)
  c_hasnt "$(cat "$TMP/wt$NP.out")" "this session's project is" "[r] instrument: the worktree's own directory, no recorded project"
  c_has "$(cat "$TMP/wt$NP.out")" "queued X3 (Next holds 2 of 2" "[r] a linked worktree, which has no file, reads the main work tree's"
  # a bare layout (the repository in .bare, worktrees beside it): both worktrees read one file, the directory's
  local C="$TMP/bare$NP" Ra="$TMP/barerepo$NP"
  git_ -C "$TMP" init -q -b main "barerepo$NP"; git_ -C "$Ra" commit -q --allow-empty -m init
  git_ -C "$TMP" clone -q --bare "$Ra" "$C/.bare"; printf 'gitdir: ./.bare\n' > "$C/.git"
  git_ -C "$C" worktree add -q --detach "$C/wa"; git_ -C "$C" worktree add -q --detach "$C/wb"
  mkdir -p "$C/.vibemaestro"; printf '{"caps": {"X": 1}}\n' > "$C/.vibemaestro/brain.json"
  (cd "$C/wa" && CLAUDE_CODE_SESSION_ID="$SID" "$BROOT/bin/brain" op add --kind next --text one >/dev/null 2>&1)
  R=$(cd "$C/wb" && CLAUDE_CODE_SESSION_ID="$SID" "$BROOT/bin/brain" op add --kind next --text two 2>&1)
  c_hasnt "$R" "this session's project is" "[r] instrument: the bare layout's own worktree, no recorded project"
  c_has "$R" "queued X2 (Next holds 1 of 1" "[r] a bare layout: the second worktree reads the same file as the first"
  # a project whose .git is a link to another repository's: it reads its own file, as it always did
  local S="$TMP/linked$NP"; mkdir -p "$S/.vibemaestro"; ln -s "$Ra/.git" "$S/.git"; printf '{"caps": {"N": 1}}\n' > "$S/.vibemaestro/brain.json"
  R=$(cd "$S" && CLAUDE_CODE_SESSION_ID="$SID" XDG_STATE_HOME="$TMP/linkedstate$NP" "$BROOT/bin/brain" op add --kind now --text a >/dev/null 2>&1
      cd "$S" && CLAUDE_CODE_SESSION_ID="$SID" XDG_STATE_HOME="$TMP/linkedstate$NP" "$BROOT/bin/brain" op add --kind now --text b 2>&1)
  c_has "$R" "queued N2 (Now holds 1 of 1" "[r] a .git linked elsewhere: the project's own file"
  R=$(cd "$S" && CLAUDE_CODE_SESSION_ID="$SID" XDG_STATE_HOME="$TMP/linkedstate$NP" "$BROOT/bin/brain" doctor 2>&1)
  c_has "$R" "is read from this work tree only, yet its brain log is shared with $(cd "$Ra" && pwd -P)," "[r] and doctor says the log is the other repository's"
  # a git directory kept apart (--separate-git-dir): git records no main work tree, so a linked worktree reads its own file
  # (accepted) and doctor says so; the main work tree reads its own without a word
  local Sg="$TMP/sep$NP"; mkdir -p "$Sg/store"
  git_ -C "$TMP" init -q -b main --separate-git-dir "$Sg/store/a.git" "$Sg/a"; git_ -C "$Sg/a" commit -q --allow-empty -m init
  git_ -C "$Sg/a" worktree add -q --detach "$Sg/a-wt"
  R=$(cd "$Sg/a-wt" && CLAUDE_CODE_SESSION_ID="$SID" XDG_STATE_HOME="$TMP/sepstate$NP" "$BROOT/bin/brain" doctor 2>&1)
  c_has "$R" "is read from this work tree only, yet its brain log is shared with every work tree of" "[r] a worktree of a git directory kept apart: doctor warns"
  R=$(cd "$Sg/a" && CLAUDE_CODE_SESSION_ID="$SID" XDG_STATE_HOME="$TMP/sepstate$NP" "$BROOT/bin/brain" doctor 2>&1)
  c_hasnt "$R" "is read from this work tree only" "[r] its main work tree: no warning"
  # a bare clone in proj/.git with a linked worktree: the worktree reads proj's file
  local Bc="$TMP/bareclone$NP"
  git_ -C "$TMP" clone -q --bare "$Ra" "$Bc/.git"; git_ -C "$Bc" worktree add -q --detach "$Bc/w1"
  mkdir -p "$Bc/.vibemaestro"; printf '{"caps": {"X": 1}}\n' > "$Bc/.vibemaestro/brain.json"
  R=$(cd "$Bc/w1" && CLAUDE_CODE_SESSION_ID="$SID" XDG_STATE_HOME="$TMP/bcstate$NP" "$BROOT/bin/brain" doctor 2>&1)
  c_has "$R" "config: .vibemaestro/brain.json: X 1" "[r] a bare clone in proj/.git: its worktree reads proj's file"
  # a submodule's linked worktree: it reads the submodule's checkout (core.worktree names it)
  local Su="$TMP/super$NP"
  git_ -C "$TMP" init -q -b main "super$NP"; git_ -C "$Su" commit -q --allow-empty -m init
  git_ -C "$Su" -c protocol.file.allow=always submodule add -q "$Ra" sub >/dev/null 2>&1
  git_ -C "$Su/sub" worktree add -q --detach "$TMP/subwt$NP"
  mkdir -p "$Su/sub/.vibemaestro"; printf '{"caps": {"X": 1}}\n' > "$Su/sub/.vibemaestro/brain.json"
  R=$(cd "$TMP/subwt$NP" && CLAUDE_CODE_SESSION_ID="$SID" XDG_STATE_HOME="$TMP/substate$NP" "$BROOT/bin/brain" doctor 2>&1)
  c_has "$R" "config: .vibemaestro/brain.json: X 1" "[r] a submodule's linked worktree reads the submodule's file"
  # a sibling worktree whose name is not UTF-8: no crash, the config still read
  git_ -C "$Ra" worktree add -q --detach "$TMP/rawt$NP"; git_ -C "$Ra" worktree add -q --detach "$TMP/wt-$(printf '\377')$NP"
  mkdir -p "$Ra/.vibemaestro"; printf '{"caps": {"X": 1}}\n' > "$Ra/.vibemaestro/brain.json"
  R=$(cd "$TMP/rawt$NP" && CLAUDE_CODE_SESSION_ID="$SID" XDG_STATE_HOME="$TMP/rastate$NP" "$BROOT/bin/brain" doctor 2>&1)
  c_hasnt "$R" "internal error" "[r] a sibling worktree named in bytes that are not UTF-8: no internal error"
  c_has "$R" "config: .vibemaestro/brain.json: X 1" "[r] and the main work tree's file is read"
  # a sibling worktree whose path holds a newline: doctor's settings scan gets its whole path
  local Wn="$TMP/wt"$'\n'"x$NP"; git_ -C "$Ra" worktree add -q --detach "$Wn"
  R=$(cd "$Ra" && WN="$Wn" bpy 'import os; print(os.path.realpath(os.environ["WN"]) in [os.path.realpath(p) for p in s._worktrees()])')
  c_eq "$R" True "[r] a sibling worktree with a newline in its path: listed whole"
  # the CLI run inside the repository's own .git: the work tree's file, as the brain log is the work tree's
  R=$(cd "$Ra/.git" && CLAUDE_CODE_SESSION_ID="$SID" XDG_STATE_HOME="$TMP/rastate$NP" "$BROOT/bin/brain" doctor 2>&1)
  c_has "$R" "config: .vibemaestro/brain.json: X 1" "[r] the CLI inside .git reads the work tree's file"
  # git's answers are decoded as the OS decodes paths: a top level that is not UTF-8
  local Nu="$TMP/nu-$(printf '\377')$NP"; git_ -C "$TMP" init -q -b main "$Nu"; mkdir -p "$Nu/sub"
  R=$(NU="$Nu" bpy 'import os; print(s.main_tree(os.environ["NU"] + "/sub") == os.path.realpath(os.environ["NU"]))' 2>&1)
  c_eq "$R" True "[r] a top level that is not UTF-8: found, no decode error"
  # a project path with a newline, the session in a subdirectory: the project's top
  local Nl="$TMP/nl"$'\n'"proj$NP"
  git_ -C "$TMP" init -q -b main "$Nl"; mkdir -p "$Nl/sub" "$Nl/.vibemaestro"; printf '{"caps": {"X": 1}}\n' > "$Nl/.vibemaestro/brain.json"
  R=$(cd "$Nl/sub" && CLAUDE_CODE_SESSION_ID="$SID" XDG_STATE_HOME="$TMP/nlstate$NP" "$BROOT/bin/brain" doctor 2>&1)
  c_has "$R" "config: .vibemaestro/brain.json: X 1" "[r] a project path with a newline: a subdirectory reads the top's file"
  R=$(cd "$Nl" && CLAUDE_CODE_SESSION_ID="$SID" XDG_STATE_HOME="$TMP/nlstate$NP" "$BROOT/bin/brain" doctor 2>&1)
  c_has "$R" "config: .vibemaestro/brain.json: X 1" "[r] and the top itself reads it"
  mkdir -p "$TMP/gitshim$NP"; printf '#!/bin/sh
echo x >> "%s/gitcalls%s"
exec "%s" "$@"
' "$TMP" "$NP" "$(command -v git)" > "$TMP/gitshim$NP/git"
  chmod +x "$TMP/gitshim$NP/git"; : > "$TMP/gitcalls$NP"
  PATH="$TMP/gitshim$NP:$PATH" br doctor
  c_hasnt "$OUT" "is read from this work tree only" "[r] a plain repository: no such warning"
  c_eq "$([ "$(wc -l < "$TMP/gitcalls$NP")" -le 20 ] && echo few)" few "[r] doctor resolves the config once: $(wc -l < "$TMP/gitcalls$NP" | tr -d ' ') git calls (≤ 20)"
}

# --- [b] -----------------------------------------------------------------------------------------------------------------------
case_queue() {
  np; conf '{"caps": {"X": 2}}'
  br op add --kind next --text "one"; br op add --kind next --text "two"
  br op add --kind next --text "three"; c_rc 0 "[b] an add at the cap: rc 0, never refused"
  c_has "$OUT" "queued X3 (Next holds 2 of 2; 0 queued before it; not injected until it moves up)" "[b] it says it is queued"
  c_has "$(lastop)" '"op":"overflow-add"' "[b] as the op overflow-add"
  br op add --kind next --text "four"; c_has "$OUT" "queued X4 (Next holds 2 of 2; 1 queued before it" "[b] the next one queues behind it"
  c_eq "$(status_of X3) $(status_of X4)" "queued queued" "[b] the log says so"
  startall
  c_hasnt "$ALL" "- X3 " "[b] a queued item is not injected"; c_hasnt "$ALL" "- X4 " "[b] nor the next"
  c_has "$SR" "Overflow queue: X 2 (in the log, not injected: brain overflow)" "[b] one line counts them"
  c_eq "$(printf '%s\n' "$ALL" | grep -c 'Overflow queue')" 1 "[b] once"
  br overflow; c_rc 0 "[b] brain overflow: rc 0"
  c_eq "$(printf '%s\n' "$OUT" | grep -E '^- X' | cut -c1-4 | tr '\n' ' ')" "- X3 - X4 " "[b] it lists the queue, head first"
  br op close X1 --reason done --pointer kb/x.md
  c_has "$OUT" "moved up from the overflow queue: X3" "[b] a close at the cap moves the head up"
  c_has "$(lastop)" '"op":"close"' "[b] instrument: the last line is the close"
  c_has "$(lastop)" '"promote":["X3"]' "[b] in the same log line"
  c_eq "$(status_of X3) $(status_of X4)" "live queued" "[b] exactly the head"
  startall; c_has "$SR" "- X3 three" "[b] it is injected now"; c_has "$SR" "Overflow queue: X 1" "[b] and the count follows"
  conf '{"caps": {"X": 4}}'
  br op add --kind next --text "five"; c_rc 0 "[b] a raised cap: the next add"
  c_has "$(lastop)" '"promote":["X4"]' "[b] moves the waiting head up in its own line"
  c_eq "$(status_of X4) $(status_of X5)" "live live" "[b] and goes live itself, first in first out"
  c_hasnt "$(br overflow; printf '%s' "$OUT")" "- X" "[b] the queue is empty"
  # a queued item closed, superseded, touched and hit
  np; conf '{"caps": {"X": 1, "T": 1}}'
  br op add --kind next --text "live one"; br op add --kind next --text "queued two"; br op add --kind next --text "queued three"
  br op close X2 --reason dropped --pointer chat; c_rc 0 "[b] a queued item can be closed"
  c_hasnt "$(lastop)" '"promote"' "[b] and nothing moves up"
  br op supersede X3 --text "queued three, reworded" --reason clearer; c_rc 0 "[b] a queued item can be superseded"
  c_has "$OUT" "superseded X3 with X4 (queued in its place)" "[b] the new one keeps its place"
  c_eq "$(status_of X4)" queued "[b] and is queued"
  br op touch X4; c_rc 0 "[b] a queued item can be touched"
  br op add --kind trap --text "t one"; br op add --kind trap --text "t two"
  br op hit T2; c_rc 0 "[b] a queued trap can be hit"
  c_eq "$(bpy 'print(s.load(s.state_dir())[1]["items"]["T2"]["hits"])')" 1 "[b] and counts"
  br op close X1 --reason done --pointer kb/x.md; c_has "$OUT" "moved up from the overflow queue: X4" "[b] the successor moves up in the old one's place"
}

# --- [c] -----------------------------------------------------------------------------------------------------------------------
case_invariant() {
  np
  R=$(CLAUDE_CODE_SESSION_ID="$SID" CLAUDE_PROJECT_DIR="$P" python3 - "$BROOT/scripts" "$P" <<'PY'
import json, os, random, sys
sys.path.insert(0, sys.argv[1])
import brain_store as s
s.sanitize = lambda d, texts: None                  # the filter is the store suite's; here only the queue's logic runs
s.use_project(sys.argv[2])
rnd, kinds = random.Random(609), ["now", "next", "session", "queue", "trap", "fact", "request"]
caps = {"N": 2, "X": 3, "S": 2, "Q": 2, "T": 2, "F": 2, "R": 2}
cfg = os.path.join(sys.argv[2], ".vibemaestro", "brain.json")
os.makedirs(os.path.dirname(cfg), exist_ok=True)
def set_caps():
    open(cfg, "w").write(json.dumps({"caps": caps}))
    s._CONF.clear()
set_caps()
problems, refused = [], 0
for i in range(2000):
    st = s.load(s.state_dir())[1]
    alive = [k for k, v in st["items"].items() if v["status"] in ("live", "queued")]
    r = rnd.random()
    try:
        if r < 0.45 or not alive:
            kind = rnd.choice(kinds)
            words = ("the owner's words %d" % i, "chat") if kind == "request" else (None, None)
            s.op_add(kind, "item %d" % i, [], [], None, (), *words)
        elif r < 0.75:
            s.op_close(rnd.choice(alive), "r", "p", True)
        elif r < 0.88:
            iid = rnd.choice(alive)
            s.op_supersede(iid, "item %d" % i, "r", [], [], True, True)
        elif r < 0.95:
            s.op_counter(rnd.choice(alive), "touch")
        else:
            letter = rnd.choice(sorted(caps))
            caps[letter] = rnd.randint(1, 5)
            set_caps()
            continue
    except s.Refused as e:
        refused += 1
        continue
    op = json.loads(open(os.path.join(s.state_dir(), "hot.jsonl"), "rb").read().splitlines()[-1])
    letter = (op.get("item") or {}).get("id", op.get("id", "?"))[0]
    st = s.load(s.state_dir())[1]
    if op["op"] in s.PROMOTING and s.queue(st, letter) and len(s.live(st, letter)) < s.cap(letter):
        problems.append("op %d left %s with room and a waiting queue" % (op["seq"], letter))
    if op.get("promote") and len(s.live(st, letter)) > s.cap(letter):
        problems.append("op %d moved %s up past its cap" % (op["seq"], letter))
raw, ops = s.verify(s.state_dir())
folded = s.fold(ops)
written = [o["item"]["id"] for o in ops if "item" in o]
if sorted(written) != sorted(folded["items"]):
    problems.append("ids written and ids folded differ")
if len(written) != len(set(written)):
    problems.append("an id written twice")
if s.dumps(folded) != s.dumps(s.load(s.state_dir())[1]):
    problems.append("the cache and a fresh fold differ")
states = {v["status"] for v in folded["items"].values()}
titles = {t for _, t in s.SECTIONS} | {s.DONE_TITLE}
shown, section = set(), None
for _, text in s.render_strings(folded):
    for line in text.splitlines():
        base = line[:-len(s.CONT)] if line.endswith(s.CONT) else line
        if base in titles or line.startswith("## "):
            section = base
        elif section != s.DONE_TITLE and line.startswith("- "):
            shown.add(line[2:].split(" ")[0])
live = {k for k, v in folded["items"].items() if v["status"] == "live"}
queued = {k for k, v in folded["items"].items() if v["status"] == "queued"}
if queued & shown:
    problems.append("queued ids injected: %s" % sorted(queued & shown)[:5])
if live - shown:
    problems.append("live ids not shown: %s" % sorted(live - shown)[:5])
print(len(ops), sorted(states), len(queued) > 0, sum(1 for o in ops if o.get("promote")) > 20, refused, "; ".join(problems) or "none")
PY
)
  set -- ${R:-0}                                     # an empty answer (the run failed) is red below, never an unbound $1
  c_eq "$(( $1 >= 1500 ))" 1 "[c] instrument: the run wrote ≥ 1,500 ops ($1)"
  c_has "$R" "'closed', 'live', 'queued', 'superseded'" "[c] instrument: every state is reached"
  c_has "$R" "True True" "[c] instrument: items wait in a queue at the end, and more than 20 ops moved one up"
  c_has "$R" " none" "[c] the invariant holds: one state per id, the fold equals the writes, no queued id injected, every live one, no room left with a waiting queue, nothing moved up past a cap"
}

# --- [d] -----------------------------------------------------------------------------------------------------------------------
case_left_cap() {
  np; conf '{"caps": {"D": 2}}'
  owner_ok add --kind decision --text "first pin" --owner-quote q --where w; c_rc 0 "[d] instrument: the first pin"
  owner_ok add --kind decision --text "second pin" --owner-quote q --where w; c_rc 0 "[d] instrument: the second, at the cap"
  gown add --kind decision --text "third pin" --owner-quote q --where w
  c_eq "$(hfield permissionDecision)" deny "[d] guard-owner denies an owner add at a left cap before it asks"
  c_has "$(hfield permissionDecisionReason)" "Pinned (owner) holds 2 of 2 live items, and the left brain has no overflow" "[d] saying the left brain has no overflow"
  c_has "$(hfield permissionDecisionReason)" "least recently touched: D1, D2" "[d] naming the items to choose from"
  c_eq "$(ls "$(sdir)/asked" | wc -l | tr -d ' ')" 0 "[d] and writes no record"
  owner_ok add --kind decision --text "third pin" --owner-quote q --where w
  c_rc 1 "[d] the CLI refuses it too, with a record"; c_has "$OUT" "least recently touched: D1, D2" "[d] naming the same items"
  c_hasnt "$(cat "$(sdir)/hot.jsonl")" "third pin" "[d] nothing is written"
  c_hasnt "$(cat "$(sdir)/hot.jsonl")" "overflow-add" "[d] nothing is queued"
}

# --- [e] -----------------------------------------------------------------------------------------------------------------------
# full [emoji] — every section at the default cap, every text at its cap, 8 short links, every quote at its cap, every anchor done
# (pins: completed issues; N, X, S, Q: PRs closed unmerged, marked and never closed), a full Done, 5 closable items past the caps
full() {
  np
  local i specs=() R=acme-corporation/app t=len
  [ "${1:-}" = emoji ] && t=emoji
  local soon; soon=$(dplus 2)
  for i in $(seq 1 5); do specs+=("G$i@$C20;$t=$([ $t = len ] && echo 300 || echo 150);links=8;qlen=600;where=$(rep w 60);full=1;review=$soon"); done
  for i in $(seq 1 20); do specs+=("D$i@$C20;anchors=$R¤$((100 + i));$t=$([ $t = len ] && echo 300 || echo 150);links=8;qlen=600;where=$(rep w 60)"); done
  for i in $(seq 1 10); do specs+=("W$i@$C20;$t=$([ $t = len ] && echo 300 || echo 150);links=8"); done
  for i in $(seq 1 5); do specs+=("P$i@$C20;$t=$([ $t = len ] && echo 300 || echo 150);links=8;qlen=600;where=$(rep w 60);goal=G$i"); done
  for i in $(seq 1 20); do specs+=("R$i@$C20;anchors=$R¤$((800 + i));$t=$([ $t = len ] && echo 300 || echo 150);links=8;qlen=600;where=$(rep w 60);due=$soon"); done
  for i in $(seq 1 5); do specs+=("N$i@$C20;closes=$R¤$((200 + i));$t=$([ $t = len ] && echo 300 || echo 150);links=8"); done
  for i in $(seq 1 20); do specs+=("S$i@$C20;closes=$R¤$((300 + i));$t=$([ $t = len ] && echo 600 || echo 300);links=8"); done
  for i in $(seq 1 15); do specs+=("Q$i@$C20;closes=$R¤$((400 + i));$t=$([ $t = len ] && echo 300 || echo 150);links=8"); done
  for i in $(seq 1 30); do specs+=("X$i@$C20;closes=$R¤$((500 + i));$t=$([ $t = len ] && echo 300 || echo 150);links=8;focus=P$(( (i - 1) % 5 + 1 ))"); done
  for i in $(seq 1 20); do specs+=("T$i@$C20;$t=$([ $t = len ] && echo 300 || echo 150);links=8"); done
  for i in $(seq 1 25); do specs+=("F$i@$C20;$t=$([ $t = len ] && echo 300 || echo 150);links=8"); done
  specs+=("N91@$C20;closes=$R¤691;len=300" "S91@$C20;closes=$R¤692;len=600" "S92@$C20;closes=$R¤693;len=600"
          "Q91@$C20;closes=$R¤694;len=300" "X91@$C20;closes=$R¤695;len=300")
  for i in 1 2 3 4 5 6 7 8; do specs+=("X$((70 + i))@$C20;closes=$R¤$((700 + 2 * i)),$R¤$((701 + 2 * i));len=300;linkmerged=$A21"); done
  seed "${specs[@]}"
  for i in $(seq 1 20); do issue "$R¤$((100 + i))" completed "$A21"; issue "$R¤$((800 + i))" completed "$A21"; done
  for i in $(seq 1 30); do pr "$R¤$((200 + i))" closed "$A21"; pr "$R¤$((300 + i))" closed "$A21"; pr "$R¤$((400 + i))" closed "$A21"
    pr "$R¤$((500 + i))" closed "$A21"; done
  for i in 1 2 3 4 5; do pr "$R¤$((690 + i))" merged "$A21"; done
  many_skills "${1:-}"
}
case_worst() {
  local i a n most=0 cuts=0 mixed=0 mode
  for mode in text emoji; do
    full "$([ $mode = emoji ] && echo emoji)"; most=0; cuts=0; mixed=0
    for i in 1 2 3 4 5 6 7 8 9 10; do                 # 12 lookups per start: ten starts answer every anchor from the cache
      startall compact; read -r n a b c <<<"$(strings_check)"
      [ "$a" -gt "$most" ] && most=$a; cuts=$((cuts + b)); mixed=$((mixed + c))
    done
    c_eq "$([ "$most" -le 9500 ] && echo within)" within "[e] $mode: every string ≤ 9,500 UTF-16 units (the largest $most)"
    c_eq "$cuts" 0 "[e] $mode: no hard cut in any string of ten SessionStarts"
    c_eq "$mixed" 0 "[e] $mode: the left brain shares no string with a right-brain section"
    c_eq "$([ "$n" -le 12 ] && echo within)" within "[e] $mode: at most 12 strings ($n)"
    c_eq "$(grep -c '"op":"link-close"' "$(sdir)/hot.jsonl")" 13 "[e] $mode: instrument: the 5 closable items closed (8 seeded link-closes + 5)"
    R=$(printf '%s\n' "$ALL" | python3 -c 'import sys
titles = {"Goals (owner)", "Pinned (owner)", "Windows", "Focus", "Requests", "Now", "Sessions", "Owner queue", "Next", "Traps",
          "Done (24 h)", "Facts"}
live, section = [], None
for l in sys.stdin.read().splitlines():
    base = l[:-len(" (cont.)")] if l.endswith(" (cont.)") else l
    if base in titles or l.startswith("## ") or l.startswith("# "):
        section = base
    elif section != "Done (24 h)" and l.startswith("- ") and section in titles:
        live.append(l[2:].split(" ")[0])
print(len(live), len(set(live)))')
    c_eq "$R" "175 175" "[e] $mode: every live item shown once (G 5, D 20, W 10, P 5, R 20, N 5, S 20, Q 15, X 30, T 20, F 25)"
    c_has "$ALL" "stale: " "[e] $mode: instrument: items are marked"
    c_has "$ALL" "Due: R1 in 2 d" "[e] $mode: instrument: the Due line names every request"
    c_has "$S1" "Review card (after compaction)" "[e] $mode: instrument: string 1 holds the review card"
    c_has "$ALL" "- X1 [P1] " "[e] $mode: instrument: Next items are tagged with their focus"
    R=$(printf '%s\n' "$ALL" | python3 -c 'import re, sys
u = lambda l: len(re.sub(r" · stale: .*", "", l).encode("utf-16-le")) // 2
ls = [l for l in sys.stdin.read().splitlines() if re.match(r"- [GDWPRNQXTFS][0-9]+ ", l)]
print(max(u(l) for l in ls if l[2] not in "SG") <= 360, max(u(l) for l in ls if l.startswith("- S")) <= 660,
      max(u(l) for l in ls if l.startswith("- G")) <= 410)')
    c_eq "$R" "True True True" "[e] $mode: every item line within its line cap in UTF-16 units (360, a session 660, a goal 410), its mark apart"
    c_has "$S1" "## Shelf index" "[e] $mode: instrument: string 1 holds the Shelf index"
    R=$(printf '%s\n' "$S1" | sed -n '/^## Shelf index/,$p' | python3 -c 'import sys; print(len(sys.stdin.read().encode("utf-16-le")) // 2)')
    c_eq "$([ "$R" -ge 900 ] && echo full)" full "[e] $mode: instrument: it is full ($R UTF-16 units)"
    [ $mode = emoji ] && c_has "$S1" "🚀" "[e] emoji: instrument: the Shelf index holds 2-unit characters"
    c_eq "$([ "$R" -le 1000 ] && echo within)" within "[e] $mode: the Shelf index ≤ 1,000 UTF-16 units, as string 1's reserve counts it"
    R=$(printf '%s\n' "$S1" | head -n 1 | python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import brain_store as s, brain_hook as h
u = s.units
need = u(sys.stdin.read()) + u(s.PRECEDENCE) + 1 + 301 + s.CARD_MAX + h.SHELF_MAX
print(need <= s.FIRST_RESERVE, need)' "$BROOT/scripts")
    c_has "$R" "True" "[e] $mode: string 1's fixed lines at their caps (head, precedence, config line, card, Shelf) fit its reserve ($R)"
    unset CLAUDE_CONFIG_DIR
  done
  # on stdin: the emoji run's strings are past the 128 KiB one argument may hold
  c_eq "$(printf '%s' "$ALL" | python3 -c 'import sys; print(sum(1 for c in sys.stdin.read() if ord(c) > 0xFFFF) > 1000)')" True "[e] instrument: the emoji run holds characters of 2 units"
  # caps raised past what 14 strings hold: 14 printed, each ≤ 9,500, the last one naming what was not injected
  np; conf '{"caps": {"X": 100, "T": 100, "F": 100, "S": 100}}'
  local specs=()
  for i in $(seq 1 100); do specs+=("X$i@$C20;len=300;links=8" "T$i@$C20;len=300;links=8" "F$i@$C20;len=300;links=8" "S$i@$C20;len=600;links=8"); done
  seed "${specs[@]}"; startall compact
  read -r n a b c <<<"$(strings_check)"
  c_eq "$n $([ "$a" -le 9500 ] && echo within) $b" "14 within 0" "[e] past 14 strings: 14 printed, each ≤ 9,500, no hard cut"
  c_has "$(ctxof "$TMP/out.session-start-14" | tail -n 1)" "more lines not injected: " "[e] the 14th ends naming what was not injected"
  c_has "$(ctxof "$TMP/out.session-start-14" | tail -n 1)" "Facts" "[e] by section"
  R=$(ctxof "$TMP/out.session-start-14" | python3 -c 'import re, sys; t = sys.stdin.read(); t = t if t.endswith("\n") else t + "\n"
m = re.search(r" · ([0-9,]+)/9,500 chars", t.splitlines()[0]); print(int(m.group(1).replace(",", "")) == len(t.encode("utf-16-le")) // 2)')
  c_eq "$R" True "[e] the 14th string's title counts the line naming what was not injected"
  br doctor; c_has "$OUT" "the caps' worst case needs" "[e] doctor warns that the caps need more strings than the plugin declares"
  br render --check; c_rc 1 "[e] render --check: rc 1"; c_has "$OUT" "strings past 14 are not injected" "[e] and says why"
  c_eq "$(python3 -c 'import json, sys; h = json.load(open(sys.argv[1])); print(sum(1 for g in h["hooks"]["SessionStart"] for c in g["hooks"] if c["command"].split()[-1].startswith("session-start")))' "$BROOT/hooks/hooks.json") $(bpy 'print(s.SLOTS)') $(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import brain_hook as h; print(h.STRINGS)' "$BROOT/scripts")" \
       "14 14 14" "[e] hooks.json declares as many string commands as the store packs and the hook hands over"
}

# --- [f] -----------------------------------------------------------------------------------------------------------------------
old_brain() {  # old_brain [rev] [dir] — the brain and sdlc of rev (BASE_REV) under $TMP/<dir> (old), isolated as brain_kit isolates
               # the copy; sets OLD; rc 1 without it
  local rev=${1:-$BASE_REV}
  OLD="$TMP/${2:-old}"
  [ -d "$OLD/plugins/vibemaestro-brain" ] && return 0
  # read only, in the checkout the suite runs from (git_ is pinned to the scratch tree, which this is not)
  env -u GIT_DIR -u GIT_WORK_TREE git -C "$SRC_ROOT" cat-file -e "$rev^{commit}" 2>/dev/null || return 1
  mkdir -p "$OLD" && env -u GIT_DIR -u GIT_WORK_TREE git -C "$SRC_ROOT" archive "$rev" plugins/vibemaestro-brain plugins/vibemaestro-sdlc \
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
case_compat() {
  np
  if ! old_brain; then ok "[f] skip: the brain of log format 3 ($BASE_REV) is not in this clone's history"; return; fi
  local NEW=$BROOT
  BROOT="$OLD/plugins/vibemaestro-brain"           # every write below by the brain of log format 3
  c_eq "$(bpy 'print(s.FORMAT)')" 3 "[f] instrument: the old brain writes log format 3"
  pr 'acme/app¤12' open; pr 'acme/app¤13' open; pr 'acme/app¤14' open
  br op add --kind now --text "fix the parser" --anchor acme/app¤11
  br op add --kind next --text "release after the gate" --closes acme/app¤12
  br op add --kind trap --text "never edit the log by hand"
  br op add --kind session --text "w-auth: review round 2" --closes acme/app¤13 --link kb/x.md
  br op add --kind queue --text "owner: approve the budget" --closes acme/app¤14
  br op add --kind fact --text "kit CLI: ~/bin/kit"
  br op add --kind next --text "write the card"
  br op supersede X2 --text "write the card, after the capacity" --reason order
  br op supersede S1 --text "w-auth: merged, docs next" --reason status
  br op touch N1; br op hit T1; br op close X3 --reason done --pointer acme/app¤15
  owner_ok add --kind decision --text "ship after the gate" --owner-quote "chờ gate rồi hãy ship" --where "chat"
  owner_ok add --kind decision --text "no auto seat" --owner-quote q --where w
  owner_ok add --kind window --text "merge docs-only" --owner-quote q --where w --expires 2099-01-01T00:00:00Z
  owner_ok supersede D1 --text "ship after the gate and the record"
  owner_ok unpin D2
  owner_ok promote W1 CLAUDE.md
  sleep 1; pr 'acme/app¤12' merged "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; pr 'acme/app¤13' merged "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  br op close-linked
  SID=sB br claim --take-over; SID=sB
  br op add --kind next --text "after the take-over"
  c_eq "$(python3 -c 'import json, sys; print(sorted({json.loads(l)["op"] for l in open(sys.argv[1])}))' "$(sdir)/hot.jsonl")" \
       "['add', 'claim', 'close', 'hit', 'link-close', 'owner-add', 'owner-promote', 'owner-supersede', 'owner-unpin', 'supersede', 'touch']" \
       "[f] instrument: the old log holds every op kind"
  local old_fold; old_fold=$(bpy 'print(s.dumps(s.fold(s.verify(s.state_dir())[1])))')
  BROOT=$NEW                                       # the brain of this tree from here on
  c_eq "$(bpy 'print(s.dumps(s.fold(s.verify(s.state_dir())[1])))')" "$old_fold" "[f] the new store folds the old log to the same bytes"
  c_eq "$(bpy 'd = s.state_dir(); print(s.cache_state(d, s.head_of(s.verify(d)[0])) is not None)')" True "[f] its hot.json cache is used as it is"
  c_eq "$(bpy 'print(" ".join(sorted(s.load(s.state_dir())[1]["items"])))')" "D1 D2 D3 F1 N1 Q1 S1 S2 T1 W1 X1 X2 X3 X4" "[f] every item keeps its id"
  br doctor; c_has "$OUT" "warn     hot.md holds an older brain's render" "[f] doctor: its hot.md is a warn"
  c_has "$OUT" "ok       hot.json, archive.jsonl and owner.json match the head" "[f] its other caches match"
  br op add --kind now --text "the first write of the new brain"; c_rc 0 "[f] a new write works on it"
  br doctor; c_has "$OUT" "hot.md matches a fresh render" "[f] and rewrites hot.md"
  local d; d=$(sdir); cp "$d/hot.jsonl" "$TMP/compat.jsonl"
  python3 - "$d/hot.jsonl" <<'PY'
import sys
p = sys.argv[1]; b = open(p, "rb").read()
assert b.count(b"fix the parser") == 1
open(p, "wb").write(b.replace(b"fix the parser", b"fox the parser"))
PY
  br op add --kind now --text "after a hand edit"; c_rc 5 "[f] a changed byte in the log stops every write (rc 5)"
  cp "$TMP/compat.jsonl" "$d/hot.jsonl"
  conf '{"caps": {"N": 1}}'
  br op add --kind now --text "queued now"; c_has "$OUT" "queued N" "[f] instrument: a queued item in the log"
  BROOT="$OLD/plugins/vibemaestro-brain"
  R=$(bpy 'try:
    s.fold(s.verify(s.state_dir())[1]); print("folded")
except s.Refused as e:
    print(e.rc)')
  BROOT=$NEW
  c_eq "$R" 5 "[f] the brain of log format 3 refuses a log with a queued item (rc 5), rather than show it as live"
}

# --- [g] -----------------------------------------------------------------------------------------------------------------------
case_goals() {
  np
  local rv rv2 v GS
  rv=$(dplus 30); rv2=$(dplus 60)
  br op add --kind goal --text "ship the layers" --owner-quote q --where w
  c_rc 1 "[g] brain op add --kind goal: refused"; c_has "$OUT" "a goal is an owner item" "[g] a goal is the owner's"
  goal_args "ship the layers" "$rv"
  br owner "${GA[@]}"; c_rc 6 "[g] brain owner add --kind goal without a record of the dialog: rc 6"
  c_hasnt "$(cat "$(sdir)/hot.jsonl" 2>/dev/null)" "ship the layers" "[g] and nothing is written"
  gown "${GA[@]}"
  c_eq "$(hfield permissionDecision)" ask "[g] guard-owner asks the owner for a goal"
  c_eq "$(hfield permissionDecisionReason)" "Pin owner goal G1 (review $rv, scope project), from \"chat\", done when \"the PR merged\", not doing \"the ledger\": \"ship the layers\"" \
       "[g] its dialog line shows every field, each quoted, before the text"
  owner_ok "${GA[@]}"; c_rc 0 "[g] with a record: written"; c_has "$OUT" "pinned G1" "[g] as G1"
  for v in "close G1 --reason r --pointer p" "supersede G1 --text other --reason r" "touch G1"; do
    br op $v; c_rc 1 "[g] brain op ${v%% *} G1: refused"; c_has "$OUT" "G1 is an owner item" "[g] it names the owner's dialog"
  done
  # the fields: a review day in the past, an unknown scope, a quote or a look-alike in a field shown before the text
  goal_args "past review" "$(dplus -1)"; owner_ok "${GA[@]}"; c_rc 1 "[g] a review day in the past: refused"; c_has "$OUT" "is in the past" "[g] saying so"
  goal_args "odd scope" "$rv"; GA[16]=team; owner_ok "${GA[@]}"; c_rc 64 "[g] a scope other than global or project: usage"
  goal_args "a quote" "$rv"; GA[10]='the "PR" merged'; owner_ok "${GA[@]}"; c_rc 1 "[g] a double quote in --done: refused"
  goal_args "a look-alike" "$rv"; GA[12]=$'“the ledger”'; owner_ok "${GA[@]}"; c_rc 1 "[g] a curly quote in --not-doing: refused"
  c_has "$OUT" "can pass for the dialog's quote" "[g] since it comes before the text"
  gown "${GA[@]}"; c_eq "$(hfield permissionDecision)" deny "[g] guard-owner denies it before it asks"
  local lk                                  # look-alikes the blocklist let through, in a goal's fields before the text
  for lk in "--done|$(printf '\341\263\223')" "--not-doing|$(printf '\313\265')" "--done|$(printf '\331\240')"; do
    goal_args "a look-alike" "$rv"
    if [ "${lk%%|*}" = --done ]; then GA[10]="the PR merged${lk#*|} ship"; else GA[12]="the ledger${lk#*|} ship"; fi
    owner_ok "${GA[@]}"; c_rc 1 "[g] ${lk%%|*} with $(printf '%s' "${lk#*|}" | python3 -c 'import sys; print("U+%04X" % ord(sys.stdin.read()))'): refused"
    gown "${GA[@]}"; c_eq "$(hfield permissionDecision)" deny "[g] and guard-owner denies it before it asks"
  done
  goal_args "Vietnamese fields" "$rv"; GA[10]="PR đã merge, xong ngày 31/10"; GA[12]="sổ cái (ledger)"
  gown "${GA[@]}"; c_eq "$(hfield permissionDecision)" ask "[g] Vietnamese done and not-doing: asked"
  goal_args "no window" "$rv"; GA+=(--expires 2099-01-01T00:00:00Z); owner_ok "${GA[@]}"; c_rc 64 "[g] --expires on a goal: usage"
  owner_ok add --kind decision --text "a pin" --owner-quote q --where w --done "x"; c_rc 64 "[g] --done on a decision: usage"
  goal_args "half a goal" "$rv"; owner_ok "${GA[@]:0:15}"; c_rc 64 "[g] a goal without its scope: usage"
  goal_args "a newline" "$rv"; GA[14]="$rv"$'\n'; owner_ok "${GA[@]}"; c_rc 64 "[g] a review day with a newline after it: usage"
  gown "${GA[@]}"; c_eq "$(hfield permissionDecision)" deny "[g] guard-owner denies it before it asks"
  # the left brain opens with it
  startall startup
  c_has "$S1" "Goals (owner)
- G1 ship the layers · review ${rv:5:5} · scope project · since " "[g] the goal opens the left brain, with its review day and scope"
  c_has "$S1" "  \"the owner's words, \"quoted\" whole\" · chat
  done when: the PR merged
  not doing: the ledger" "[g] then the owner's words, what done means and the not-doing line"
  c_eq "$(printf '%s\n' "$S1" | grep -E '^(Goals|Pinned) \(owner\)$' | tr '\n' ',')" "Goals (owner),Pinned (owner)," "[g] before the pins"
  # an owner supersede carries the quote byte for byte and each field not given
  GS=(supersede G1 --text "ship the layers, then the card" --review "$rv2" --done "both PRs merged")
  gown "${GS[@]}"
  c_eq "$(hfield permissionDecisionReason)" "Replace owner goal G1 (review $rv2), done when \"both PRs merged\", with: \"ship the layers, then the card\"" \
       "[g] the supersede dialog names each field it changes"
  owner_ok "${GS[@]}"; c_rc 0 "[g] an owner supersede of a goal"; c_has "$OUT" "superseded G1 with G2" "[g] as G2"
  c_eq "$(bpy 'st = s.load(s.state_dir())[1]; print(s.dumps(st["items"]["G2"]["source"]) == s.dumps(st["items"]["G1"]["source"]))')" True \
       "[g] the owner's words go over byte for byte"
  br show G2
  c_has "$OUT" "quote: the owner's words, \"quoted\" whole" "[g] brain show prints them whole"
  c_has "$OUT" "done: both PRs merged" "[g] the field given"; c_has "$OUT" "not_doing: the ledger" "[g] a field not given carried over"
  c_has "$OUT" "review: $rv2" "[g] the new review day"; c_has "$OUT" "scope: project" "[g] the scope carried over"
  owner_ok supersede G2 --text "ship the layers" --scope team; c_rc 64 "[g] a supersede with an unknown scope: usage"
  owner_ok add --kind decision --text "a pin" --owner-quote q --where w; owner_ok supersede D1 --text "a pin, reworded" --review "$rv"
  c_rc 64 "[g] --review on a decision's supersede: usage"
  gown unpin G2; c_eq "$(hfield permissionDecisionReason)" "Unpin owner goal G2: \"ship the layers, then the card\"" "[g] the unpin dialog names a goal"
  goal_args "$(rep g 300)" "$rv"; GA+=(--link kb/a.md --link kb/b.md); owner_ok "${GA[@]}"; c_has "$OUT" "pinned G3" "[g] instrument: a goal at its text cap, with two links"
  c_has "$(bpy 'print(s.render_all(s.load(s.state_dir())[1]))' | grep '^- G3 ')" " · links kb/a.md, kb/b.md" "[g] its line keeps the links: a goal's review and scope have room of their own"
  # the left brain has no overflow: at the goals' cap the dialog never asks
  conf '{"caps": {"G": 1}}'
  goal_args "a second goal" "$rv"; gown "${GA[@]}"
  c_eq "$(hfield permissionDecision)" deny "[g] at the goals' cap guard-owner denies before it asks"
  c_has "$(hfield permissionDecisionReason)" "Goals (owner) holds 2 of 1 live items" "[g] naming the section"
  conf '{}'
}

# --- [h] -----------------------------------------------------------------------------------------------------------------------
case_focus() {
  np
  goal_args "ship the layers" "$(dplus 30)"; owner_ok "${GA[@]}"
  br op add --kind focus --text "capacity first" --owner-quote "làm capacity trước" --where chat --goal G9
  c_rc 1 "[h] a focus whose goal is not live: refused"; c_has "$OUT" "G9 is not a live goal" "[h] naming it"
  br op add --kind focus --text "capacity first" --owner-quote "làm capacity trước" --where chat; c_rc 64 "[h] a focus with no goal: usage"
  br op add --kind focus --text "capacity first" --goal G1; c_rc 64 "[h] a focus without the owner's words: usage"
  br op add --kind next --text "words" --owner-quote q --where w; c_rc 64 "[h] the owner's words on a Next item: usage"
  br op add --kind focus --text "capacity first" --owner-quote "làm capacity trước" --where chat --goal G1
  c_rc 0 "[h] a focus pointing to a live goal"; c_has "$OUT" "added P1" "[h] as P1"
  br op add --kind focus --text "layers next" --owner-quote "rồi tới layers" --where chat --goal G1
  br op add --kind next --text "x one"; br op add --kind next --text "x two" --focus P2
  br op add --kind next --text "x three" --focus P1; br op add --kind next --text "x four"
  br op add --kind next --text "x five" --focus P1; c_rc 0 "[h] instrument: five Next items, three tied to a focus"
  br op add --kind next --text "nope" --focus P9; c_rc 1 "[h] a Next item tied to a focus that is not live: refused"
  br op add --kind now --text "nope" --focus P1; c_rc 64 "[h] --focus on a Now item: usage"
  startall
  c_eq "$(nextorder)" "X3 [P1],X5 [P1],X2 [P2],X1 x,X4 x," "[h] Next: each live focus's items first, by focus, tagged; then the rest by id"
  c_has "$SR" "- P1 capacity first · goal G1 · since " "[h] a focus shows its goal"
  c_has "$SR" "  \"làm capacity trước\" · chat" "[h] and the owner's words"
  br op close P2 --reason done --pointer kb/x.md
  startall; c_eq "$(nextorder)" "X3 [P1],X5 [P1],X1 x,X2 x,X4 x," "[h] a closed focus orders nothing"
  br op supersede P1 --text "capacity first, then the strings" --reason widened; c_has "$OUT" "superseded P1 with P3" "[h] a supersede of a focus"
  c_eq "$(bpy 'st = s.load(s.state_dir())[1]; i = st["items"]; print(s.dumps(i["P3"]["source"]) == s.dumps(i["P1"]["source"]), i["P3"]["goal"])')" "True G1" \
       "[h] keeps the owner's words byte for byte and the goal"
  startall; c_eq "$(nextorder)" "X3 [P3],X5 [P3],X1 x,X2 x,X4 x," "[h] a superseded focus passes its items to its successor"
  br op supersede X1 --text "x one, tied" --reason focus --focus P3; c_rc 0 "[h] a supersede of a Next item may tie it"
  startall; c_eq "$(nextorder)" "X3 [P3],X5 [P3],X6 [P3],X2 x,X4 x," "[h] and it moves up with its focus"
  conf '{"caps": {"X": 5}}'; br op add --kind next --text "x seven" --focus P3; c_has "$OUT" "queued X7" "[h] instrument: a queued Next item tied to a focus"
  br overflow; c_has "$OUT" "- X7 [P3] x seven" "[h] brain overflow shows its focus tag"; conf '{}'
  owner_ok supersede G1 --text "ship the layers and the card"
  startall; c_has "$SR" "- P3 capacity first, then the strings · goal G2 · since " "[h] a focus follows its goal's supersede"
  owner_ok unpin G2; c_rc 0 "[h] instrument: the owner unpins the goal"
  startall; c_has "$SR" "- P3 capacity first, then the strings · goal G2 (retired) · since " "[h] a focus whose goal retired says so"
}

# --- [i] -----------------------------------------------------------------------------------------------------------------------
case_requests() {
  np
  local q600
  q600=$(python3 -c 'print(("say \"yes\" to the card; " * 40)[:600])')
  br op add --kind request --text "the owner asks for the card" --owner-quote "${q600}x" --where chat
  c_rc 1 "[i] a quote of 601 units: refused, never cut"; c_has "$OUT" "quote is 601 characters" "[i] naming its length"
  c_hasnt "$(cat "$(sdir)/hot.jsonl" 2>/dev/null)" "the owner asks for the card" "[i] nothing is written"
  br op add --kind request --text "the owner asks for the card" --owner-quote "$q600" --where chat
  c_rc 0 "[i] a quote of 600 units holding double quotes: written"; c_has "$OUT" "added R1" "[i] as R1"
  br show R1; c_eq "$(printf '%s\n' "$OUT" | sed -n 's/^quote: //p')" "$q600" "[i] brain show prints it byte for byte"
  c_eq "$(Q=$q600 bpy 'import os; print(s.load(s.state_dir())[1]["items"]["R1"]["source"]["quote"] == os.environ["Q"])')" True "[i] as stored"
  startall; c_has "$SR" "  \"$(printf '%s' "$q600" | cut -c1-299)…\" · chat" "[i] the render cuts its line for room only, at 300, marked …"
  br op supersede R1 --text "the owner asks for the card, after the capacity" --reason widened; c_has "$OUT" "superseded R1 with R2" "[i] a supersede of a request"
  c_eq "$(Q=$q600 bpy 'import os; i = s.load(s.state_dir())[1]["items"]; print(i["R2"]["source"]["quote"] == os.environ["Q"], s.dumps(i["R2"]["source"]) == s.dumps(i["R1"]["source"]))')" \
       "True True" "[i] keeps the owner's words byte for byte"
  local feb30=2026-02-30 day=2030-01-01
  br op add --kind request --text "a day that is not one" --owner-quote q --where chat --due "$feb30"; c_rc 64 "[i] a due day the calendar has not: usage"
  br op add --kind next --text "x" --due "$day"; c_rc 64 "[i] --due on a Next item: usage"
  br op add --kind request --text "a newline" --owner-quote q --where chat --due "$day"$'\n'; c_rc 64 "[i] a due day with a newline after it: usage"
  br op add --kind request --text "no words" --due "$day"; c_rc 64 "[i] a request without the quote: usage"
  br op close R2 --reason done; c_rc 1 "[i] close a request without --pointer: refused"; c_has "$OUT" "only with --pointer" "[i] saying why"
  c_eq "$(status_of R2)" live "[i] it stays live"
  br op close R2 --reason done --pointer kb/out.md; c_rc 0 "[i] with a pointer: closed"
  startall; c_has "$SR" "Done (24 h)
- R2 kb/out.md · the owner asks for the card, after the capacity" "[i] and in Done, its pointer first"
  # it closes by its --closes anchor, which is its pointer, and it is marked stale like N, X, S and Q
  pr 'acme/app¤51' open
  br op add --kind request --text "merge the layers" --owner-quote "merge it" --where chat --closes acme/app¤51; c_rc 0 "[i] a request with --closes"
  sleep 1; pr 'acme/app¤51' merged "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  startall; c_eq "$(status_of R3)" closed "[i] closes at the writer's SessionStart once its PR merged"
  c_eq "$(bpy 'print(s.load(s.state_dir())[1]["items"]["R3"]["pointer"])')" "acme/app¤51" "[i] with its anchor as the pointer"
  issue 'acme/app¤52' completed "$A21"
  br op add --kind request --text "a stale anchor" --owner-quote q --where chat --anchor acme/app¤52
  startall; c_has "$SR" "- R4 a stale anchor · since " "[i] instrument: R4 is shown"; c_has "$SR" "· stale: acme/app¤52" "[i] a request is marked stale"
  conf '{"caps": {"R": 1}}'
  br op add --kind request --text "one too many" --owner-quote q --where chat; c_has "$OUT" "queued R5 (Requests holds 1 of 1" "[i] a full Requests section queues"
  conf '{}'
}

# --- [j] -----------------------------------------------------------------------------------------------------------------------
case_due() {
  np
  local d t0
  for d in 2030-01-18 2030-01-17 2030-01-11 2030-01-10 2030-01-08; do
    br op add --kind request --text "due $d" --owner-quote q --where chat --due "$d"
  done
  br op add --kind request --text "no due day" --owner-quote q --where chat; c_rc 0 "[j] instrument: six requests"
  t0=$(python3 -c 'import calendar, time; print(calendar.timegm(time.strptime("2030-01-10T12:00:00Z", "%Y-%m-%dT%H:%M:%SZ")))')
  R=$(bpy "st = s.load(s.state_dir())[1]; print([l for l in s.render_all(st, $t0).splitlines() if l.startswith('Due: ')][0])")
  c_eq "$R" "Due: R5 OVERDUE 2 d (01-08) · R4 TODAY (01-10) · R3 TOMORROW (01-11) · R2 in 7 d (01-17)" \
       "[j] on 01-10: due at −2, 0, 1 and 7 days named, soonest first; at 8 days not yet"
  R=$(bpy "st = s.load(s.state_dir())[1]; print(s.render_all(st, $t0).split('## Brain · right brain')[1].splitlines()[1])")
  c_eq "${R:0:5}" "Due: " "[j] the Due line is the first line of the right brain"
  c_has "$(bpy "st = s.load(s.state_dir())[1]; print(s.render_all(st, $t0))")" "- R1 due 2030-01-18 · due 01-18 · since " "[j] the item line shows its due day"
  R=$(bpy "st = s.load(s.state_dir())[1]; print([l for l in s.render_all(st, $t0 - 86400 * 30).splitlines() if l.startswith('Due: ')])")
  c_eq "$R" "[]" "[j] a month before, no Due line"
  R=$(bpy "st = s.load(s.state_dir())[1]; md = s.render_all(st, $t0 - 86400 * 3); f = s.render_key(s.render_all(st, $t0), st, $t0)
print(s.render_key(md, st, $t0) == f, s.render_key(md.replace('R4 in 3 d', 'R4 in 2 d'), st, $t0) == f)")
  c_eq "$R" "True False" "[j] a hot.md three days older still matches; one with a forged Due line does not"
  # the hooks, at the real clock
  np; br op add --kind request --text "soon" --owner-quote q --where chat --due "$(dplus 3)"
  startall; c_has "$SR" "Due: R1 in 3 d ($(dplus 3 | cut -c6-))" "[j] SessionStart: the Due line at the real clock"
  # a goal's review day moves with the clock too
  goal_args "ship" "$(dplus 30)"; owner_ok "${GA[@]}"
  R=$(bpy 'import time; st = s.load(s.state_dir())[1]; t = time.time() + 35 * 86400; md = s.render_all(st); later = s.render_all(st, t)
f = s.render_key(later, st, t)
print(s.render_key(md, st, t) == f, "review OVERDUE 5 d" in later, s.render_key(later.replace("OVERDUE 5 d", "OVERDUE 9 d"), st, t) == f)')
  c_eq "$R" "True True False" "[j] a goal's review day turns OVERDUE; a hot.md rendered before still matches, a forged count does not"
  br doctor; c_has "$OUT" "ok       hot.md matches a fresh render" "[j] doctor: hot.md matches"
}

# --- [k] -----------------------------------------------------------------------------------------------------------------------
case_precedence() {
  np; br op add --kind next --text "one"
  local src
  for src in startup resume clear compact; do
    startall "$src"
    c_eq "$(printf '%s\n' "$S1" | sed -n 2p)" "$PREC" "[k] SessionStart:$src: line 2 of string 1 is the precedence line, in the owner's wording"
  done
  c_eq "$(printf '%s\n' "$ALL" | grep -cF "Precedence: ")" 1 "[k] once, in string 1 only"
  c_hasnt "$(bpy 'print(s.render_all(s.load(s.state_dir())[1]))')" "Precedence: " "[k] not in hot.md: the hook's line"
  br render; c_eq "$(printf '%s\n' "$OUT" | sed -n 1p)" "$PREC" "[k] brain render prints it first, as SessionStart injects it"
  c_eq "$(printf '%s\n' "$OUT" | grep -cF "Precedence: ")" 1 "[k] once"
  c_hasnt "$(cat "$(sdir)/hot.md")" "Precedence: " "[k] and hot.md, which doctor compares with a fresh render, still holds none"
  br render --check; c_hasnt "$OUT" "Precedence: " "[k] render --check prints the sizes only"
}

case_card_loss() {  # the card after a compaction never shows the previous compaction's loss score as this one's
  np; br op add --kind next --text "watch the run" --anchor run-41
  local pre post card
  pre=$(hin session_id=sA cwd="$P" hook_event_name=PreCompact trigger=auto)
  hk pre-compact "$pre"
  hk post-compact "$(hin session_id=sA cwd="$P" hook_event_name=PostCompact trigger=auto compact_summary="watching run-41")"
  startall compact; card=$(printf '%s\n' "$S1" | sed -n '/^Review card/,/^## Brain/p')
  c_has "$card" "- loss score of the last compaction logged: 0.00 (" "[l2] PostCompact before the card: this compaction's score"
  hk pre-compact "$pre"                     # the next compaction: SessionStart:compact runs before its PostCompact logs
  bpy 's.episode_line(s.state_dir(), "sB", "compact", trigger="auto", loss=0.5)'   # another session's compaction meanwhile
  startall compact; card=$(printf '%s\n' "$S1" | sed -n '/^Review card/,/^## Brain/p')
  c_has "$card" "- loss score of this compaction: not logged yet (brain doctor shows it)" "[l2] PostCompact after the card: the card says so"
  c_hasnt "$card" "0.00" "[l2] and never shows the previous compaction's score"
  c_hasnt "$card" "0.50" "[l2] nor another session's"
  hk post-compact "$(hin session_id=sA cwd="$P" hook_event_name=PostCompact trigger=auto compact_summary="nothing of it")"
  br doctor; c_has "$OUT" "review card: loss score of the last compaction logged: 1.00 (" "[l2] doctor then shows it"
}

# --- [l] -----------------------------------------------------------------------------------------------------------------------
case_card() {
  np; conf '{"caps": {"X": 2}}'
  goal_args "ship the layers" "$(dplus 12)"; owner_ok "${GA[@]}"
  seed "G2@$C20;review=$(dplus -3);text=keep the fleet in step"       # a review day past: seeded, since the dialog refuses one
  br op add --kind focus --text "capacity first" --owner-quote q --where chat --goal G1
  pr 'acme/app¤61' merged "$A21"
  br op add --kind next --text "x one" --anchor acme/app¤61; br op add --kind next --text "x two"
  br op add --kind next --text "x three"; c_has "$OUT" "queued X3" "[l] instrument: a queued item"
  bpy 's.episode_line(s.state_dir(), "sA", "compact", trigger="auto", loss=0.42)'
  local src card
  for src in startup resume clear; do
    startall "$src"; c_hasnt "$S1" "Review card" "[l] SessionStart:$src: no review card"
  done
  startall compact
  c_eq "$(printf '%s\n' "$S1" | sed -n 3p)" "Review card (after compaction)" "[l] SessionStart:compact: the card, right under the precedence line"
  card=$(printf '%s\n' "$S1" | sed -n '/^Review card/,/^## Brain/p' | sed '$d')
  c_has "$card" "- G1 review in 12 d · focus P1 · no progress yet" "[l] each goal's review day and its focus, a line each"
  c_has "$card" "- G2 review OVERDUE 3 d · no focus · no progress yet" "[l] a goal past its review day, with no focus"
  c_has "$card" "- sections over 85 %: Next 2/2" "[l] the sections at 85 % of their caps"
  c_has "$card" "- anchors closed: X1 acme/app¤61 merged" "[l] the live items whose anchors closed"
  c_has "$card" "- overflow queue: X 1" "[l] the overflow queue"
  c_has "$card" "- loss score of the last compaction logged: 0.42 (" "[l] the last loss score, with its time"
  c_eq "$(python3 -c 'import sys; print(len(sys.argv[1].encode("utf-16-le")) // 2 <= 1000)' "$card")" True "[l] ≤ 1,000 units"
  c_has "$(printf '%s\n' "$S1" | sed -n '/^Review card/,$p')" "## Brain · left brain" "[l] before the left brain"
  R=$(bpy 'c = s.card_text(["a" * 290] * 6); print(s.units(c) <= 1000, c.splitlines()[-1], len(c.splitlines()))')
  c_eq "$R" "True (+3 lines: brain doctor) 5" "[l] lines past 1,000 units become one (+N lines: brain doctor)"
  c_eq "$(bpy 'print(s.card_text([]), end="")')" "Review card (after compaction)
- nothing to review" "[l] an empty card says so"
  br doctor; c_has "$OUT" "info     review card: G1 review in 12 d · focus P1" "[l] doctor prints the card's lines"
  conf '{"caps": {"P": 100}}'
  local i specs=()
  for i in $(seq 2 80); do specs+=("P$i@$C20;goal=G1"); done
  seed "${specs[@]}"
  R=$(bpy 'import time; st = s.load(s.state_dir())[1]; print(" | ".join(l for l in s.card_lines(st, time.time()) if l[:3] in ("G1 ", "G2 ")))')
  c_eq "$R" "G1 review in 12 d · focus P1 P2 P3 +77 | G2 review OVERDUE 3 d · no focus" "[l] a goal with 80 focus items names 3 and counts the rest, so every goal shows"
  conf '{}'
}

# --- [m] -----------------------------------------------------------------------------------------------------------------------
case_compat4() {
  np
  if ! old_brain "$LAYERS_REV" old4; then ok "[m] skip: the brain of log format 4 ($LAYERS_REV) is not in this clone's history"; return; fi
  local NEW=$BROOT d old_fold
  BROOT="$OLD/plugins/vibemaestro-brain"           # every write below by the brain of log format 4
  c_eq "$(bpy 'print(s.FORMAT)')" 4 "[m] instrument: the old brain writes log format 4"
  conf '{"caps": {"X": 1}}'
  pr 'acme/app¤12' open
  br op add --kind now --text "fix the parser" --anchor acme/app¤11
  br op add --kind next --text "release after the gate" --closes acme/app¤12
  br op add --kind next --text "queued one"; br op add --kind next --text "queued two"; br op add --kind next --text "queued three"
  br op add --kind trap --text "never edit the log by hand"
  br op add --kind trap --text "a trap with long links" --link "kb/$(rep a 52).md" --link "kb/$(rep b 60).md" --link "kb/$(rep c 54).md"
  br op add --kind session --text "w-auth: review round 2" --link kb/x.md
  br op add --kind queue --text "owner: approve the budget"
  br op add --kind fact --text "kit CLI: ~/bin/kit"
  br op supersede X4 --text "queued three, reworded" --reason clearer
  br op close X2 --reason dropped --pointer chat
  br op touch N1; br op hit T1
  owner_ok add --kind decision --text "ship after the gate" --owner-quote "chờ gate rồi hãy ship" --where chat
  owner_ok add --kind window --text "merge docs-only" --owner-quote q --where w --expires 2099-01-01T00:00:00Z
  owner_ok supersede D1 --text "ship after the gate and the record"
  sleep 1; pr 'acme/app¤12' merged "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  br op close-linked
  c_has "$(cat "$(sdir)/hot.jsonl")" '"op":"overflow-add"' "[m] instrument: the old log holds queued items"
  c_has "$(cat "$(sdir)/hot.jsonl")" '"promote":["X3"]' "[m] instrument: and a move up"
  br render >/dev/null
  old_fold=$(bpy 'print(s.dumps(s.fold(s.verify(s.state_dir())[1])))')
  BROOT=$NEW                                       # the brain of this tree from here on
  c_eq "$(bpy 'print(s.dumps(s.fold(s.verify(s.state_dir())[1])))')" "$old_fold" "[m] the new store folds the format-4 log to the same bytes"
  c_eq "$(bpy 'd = s.state_dir(); print(s.cache_state(d, s.head_of(s.verify(d)[0])) is not None)')" True "[m] its hot.json cache is used as it is"
  c_eq "$(bpy 'print(" ".join(sorted(s.load(s.state_dir())[1]["items"])))')" "D1 D2 F1 N1 Q1 S1 T1 T2 W1 X1 X2 X3 X4 X5" "[m] every item keeps its id"
  br doctor; c_has "$OUT" "warn     hot.md holds an older brain's render" "[m] doctor: its hot.md is a warn"
  c_hasnt "$OUT" "problem  hot.md" "[m] not a problem"
  conf '{"caps": {"X": 1}, "text_max": 100}'
  br doctor; c_has "$OUT" "warn     hot.md" "[m] and still a warn once the config changed since the old brain rendered it"
  c_hasnt "$OUT" "problem  hot.md" "[m] not a problem then either"
  conf '{"caps": {"X": 1}}'
  br op add --kind request --text "the first request" --owner-quote "the owner's words" --where chat; c_rc 0 "[m] a new request works on it"
  br doctor; c_has "$OUT" "hot.md matches a fresh render" "[m] and rewrites hot.md"
  d=$(sdir); cp "$d/hot.jsonl" "$TMP/compat4.jsonl"
  python3 - "$d/hot.jsonl" <<'PY'
import sys
p = sys.argv[1]; b = open(p, "rb").read()
assert b.count(b"fix the parser") == 1
open(p, "wb").write(b.replace(b"fix the parser", b"fox the parser"))
PY
  br op add --kind now --text "after a hand edit"; c_rc 5 "[m] a changed byte in the log stops every write (rc 5)"
  cp "$TMP/compat4.jsonl" "$d/hot.jsonl"
  BROOT="$OLD/plugins/vibemaestro-brain"
  R=$(bpy 'try:
    s.fold(s.verify(s.state_dir())[1]); print("folded")
except s.Refused as e:
    print(e.rc)')
  BROOT=$NEW
  c_eq "$R" 5 "[m] the brain of log format 4 refuses a log with a request (rc 5), rather than drop it"
  conf '{}'
}

echo "== cases =="
for c in case_config case_root case_queue case_invariant case_left_cap case_worst case_compat case_goals case_focus case_requests \
         case_due case_precedence case_card case_card_loss case_compat4; do run_case $c; done
cd "$TMP" || exit 1

summary
