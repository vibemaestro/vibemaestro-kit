#!/bin/bash
# =============================================================================
# Review quality: the spec's Inputs and failure cases section, the SubagentStart core, per-subagent and post-compaction reminders
# =============================================================================
# Run: bash tests/test-review-quality.sh
#
# Families (each names the row of the spec's `## Inputs and failure cases` it proves):
#   [spec-shapes]       how the none line and the table are read (no rendering): around the table nothing is judged; one table,
#                       three columns, three filled cells; the stated limits pass
#   [spec-missing]      a spec new in the change (not on the merge base of origin) without the section is refused, rc 65, naming it;
#                       so are an empty section, a header with no row, a row with an empty cell, a cell split by an unescaped `|`,
#                       and the section placed after the criteria; a full table and an escaped `\|` pass
#   [spec-none]         `none, because <reason>` and `không có, vì <reason>` pass; bare `none`, `none, because`, `none, because …` do not
#   [spec-fenced]       the heading, or the table, only inside a ``` fence does not count
#   [spec-old-warns]    a spec already on the merge base without the section, or with a broken table, passes (rc 0) with a WARNING line
#   [spec-date]         no origin to read: dated before 2026-11-02 warns (rc 0), dated on or after it is refused, no date warns
#   [spec-language]     `kb.py new spec` writes the same `## Inputs and failure cases` between out-of-scope and criteria under vi and
#                       en; the template is refused while its blanks are there, and passes once they are filled
#   [sub-bad-payload]   SubagentStart with empty stdin, text that is not JSON, a JSON list: rc 0, no output
#   [sub-readonly]      Explore, Plan, claude-code-guide, statusline-setup get nothing; general-purpose, a missing type and a plugin
#                       agent get the core (hookEventName SubagentStart, at most 3000 characters, the precedence and test rules in it)
#   [sub-matcher]       the hooks.json matcher skips exactly the four read-only types, whole names only, read anchored or not
#   [sub-config]        `hooks: off` is silent; an invalid config gives the config warning and the core
#   [sub-cap]           a core file over the cap is cut at 3000 characters with a pointer; a missing one is a warning, rc 0
#   [marker-agent]      a rule the parent saw reaches a subagent once; the subagent does not hide it from the parent; two
#                       subagents keep separate sets; a hostile agent_id keeps every marker directory under TMPDIR
#   [core-room]         the coordinated core is whole, with the precedence sentence, when its printed path is 160 characters
#   [compact-reset]     after SessionStart source=compact the same edit shows its rule again; startup and resume do not reset;
#                       the config warning keeps its mark; a missing marker directory or a non-string session id is rc 0
#
# Real plugin scripts on a scratch copy, real git on throw-away repositories, no network, no model.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
# shellcheck source=fixtures/ports.sh
. "$HERE/fixtures/ports.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
PL="$TMP/plugin"; mk_plugin_copy "$PL"

kb() { local d=$1; shift; (cd "$d" && cenv python3 -B "$PL/scripts/kb.py" "$@" 2>&1); }
kbrc() { local d=$1; shift; (cd "$d" && cenv python3 -B "$PL/scripts/kb.py" "$@" >/dev/null 2>&1); echo $?; }
# refused <repo> <spec> → rc and output of a check that must go red (a functional negative case: capped)
refused() { (cd "$1" && capped cenv python3 -B "$PL/scripts/kb.py" check spec "$2" 2>&1); }

# spec <file> <inputs body | -> [placement: before|after] — a filled spec; `-` leaves the section out
spec() {
  local body=$2 where=${3:-before}
  { printf -- '---\ndescription: "A spec"\n---\n\n# Example\n\nIntent: kb/intent/x.md\n\n'
    printf '## Bối cảnh\n\nWhy.\n\n## Mục tiêu\n\nWhat.\n\n## Ngoài phạm vi\n\nNone.\n\n'
    [ "$body" != - ] && [ "$where" = before ] && printf '## Inputs and failure cases\n\n%s\n\n' "$body"
    printf '## Tiêu chí chấp nhận\n\n1. `make test` → 0 fail\n2. PR có mục `## Bằng chứng chạy` ghi output thật.\n'
    [ "$body" != - ] && [ "$where" = after ] && printf '\n## Inputs and failure cases\n\n%s\n' "$body"
  } > "$1"
}
TABLE='| Input or failure | Expected | Test |
|---|---|---|
| an empty file | refused, rc 65 | `bash t.sh empty` |
| a path outside the tree | refused, rc 64 | `bash t.sh outside` |'

# a repository with an origin: specs committed and pushed are "on the merge base", files added after are new
R=$(fresh); O=$(fresh)
git_ init -q --bare -b main "$O"; git_ init -q -b main "$R"; git_ -C "$R" remote add origin "$O"
mkdir -p "$R/kb/specs" "$R/kb/intent"
spec "$R/kb/specs/2026-10-01-old.md" -
spec "$R/kb/specs/2026-10-02-oldbroken.md" '| a | b | c |
|---|---|---|
| only one cell |'
git_ -C "$R" add -A; git_ -C "$R" commit -qm base; git_ -C "$R" push -q origin main 2>/dev/null; git_ -C "$R" fetch -q origin
eq "$(git_ -C "$R" rev-parse --verify --quiet origin/main >/dev/null && echo yes)" yes "instrument: origin/main resolves in the scratch repository"

echo "-- [spec-missing]"
S="$R/kb/specs/2026-10-03-new.md"
spec "$S" -;                O=$(refused "$R" "$S"); rc=$?
eq "$rc" 65 "[spec-missing] a new spec without the section is refused (rc 65), even dated before 2026-11-02"
has "$O" "## Inputs and failure cases" "[spec-missing] …and the refusal names the section"
spec "$S" "$TABLE";         eq "$(kbrc "$R" check spec "$S")" 0 "[spec-missing] control: the same spec with a full table passes (rc 0)"
hasnt "$(kb "$R" check spec "$S")" WARNING "[spec-missing] …with no WARNING line"
spec "$S" '';               O=$(refused "$R" "$S"); eq "$?" 65 "[spec-missing] an empty section is refused (rc 65)"
has "$O" "section \`## Inputs and failure cases\` is empty" "[spec-missing] …naming the section as empty"
spec "$S" '| a | b | c |
|---|---|---|';               O=$(refused "$R" "$S"); eq "$?" 65 "[spec-missing] a header with no row is refused (rc 65)"
has "$O" "has a header but no row" "[spec-missing] …as a header with no row"
spec "$S" '| a | b | c |
|---|---|---|
| empty file | refused |  |'; O=$(refused "$R" "$S"); rc=$?
eq "$rc" 65 "[spec-missing] a row with an empty test cell is refused (rc 65)"
eq "$(printf '%s\n' "$O" | grep -cE 'row [1]: needs three filled cells')" 1 "[spec-missing] …and the refusal names the first row"
spec "$S" '| a | b | c |
|---|---|---|
| a `x | y` pipe | refused | `t` |'; O=$(refused "$R" "$S"); eq "$?" 65 "[spec-missing] an unescaped | inside a code span splits the row (GitHub renders four cells): rc 65"
eq "$(printf '%s\n' "$O" | grep -cE 'row [1]: needs three filled cells')" 1 "[spec-missing] …naming the first row"
spec "$S" '| a | b | c |
|---|---|---|
| a `x \| y` pipe | refused | `t` |'; eq "$(kbrc "$R" check spec "$S")" 0 "[spec-missing] control: the escaped \\| keeps three cells (rc 0)"
spec "$S" '| a | b | c |
|---|---|---|
| the ``` run in a cell | kept | `t` |'; eq "$(kbrc "$R" check spec "$S")" 0 "[spec-missing] a backtick run in a cell does not swallow the row's pipes (rc 0)"
spec "$S" "$TABLE" after;   O=$(refused "$R" "$S"); rc=$?
eq "$rc" 65 "[spec-missing] the section after the criteria is refused (rc 65)"
has "$O" "out of place" "[spec-missing] …as out of place"
spec "$S" "no table here, just prose"; O=$(refused "$R" "$S"); eq "$?" 65 "[spec-missing] prose with no table and no none line is refused (rc 65)"

echo "-- [spec-none]"
spec "$S" 'none, because the change only fixes a typo in a comment'; eq "$(kbrc "$R" check spec "$S")" 0 "[spec-none] none, because <reason> passes (rc 0)"
spec "$S" 'không có, vì chỉ sửa chính tả';                          eq "$(kbrc "$R" check spec "$S")" 0 "[spec-none] không có, vì <lý do> passes (rc 0)"
spec "$S" 'None, because the change is a rename'; eq "$(kbrc "$R" check spec "$S")" 0 "[spec-none] the case of None does not matter (rc 0)"
for bare in 'none' 'none, because' 'none, because …' 'không có, vì'; do
  spec "$S" "$bare"; O=$(refused "$R" "$S"); eq "$?" 65 "[spec-none] '$bare' with no reason is refused (rc 65)"
done

echo "-- [spec-shapes]"
for none in '`none, because only a typo`' '- none, because only a typo' 'None because only a typo' "$(printf 'kho\xcc\x82ng co\xcc\x81, vi\xcc\x80 chi\xcc\x89 su\xcc\x9b\xcc\x89a chu\xcc\x9b\xcc\x83')"; do
  spec "$S" "$none"; eq "$(kbrc "$R" check spec "$S")" 0 "[spec-shapes] the none line written as '$none' passes (rc 0)"
done
spec "$S" 'a | b | c
---|---|---
x | y | `t`';               eq "$(kbrc "$R" check spec "$S")" 0 "[spec-shapes] a table without outer pipes, as GitHub reads it, passes (rc 0)"
spec "$S" '| a | b | c |
|-|:-:|-|
| x | y | `t` |';            eq "$(kbrc "$R" check spec "$S")" 0 "[spec-shapes] a delimiter row of one-dash cells passes (rc 0)"
spec "$S" '| a | b |
|---|---|
| x | y | `t` |';            O=$(refused "$R" "$S"); rc=$?
eq "$rc" 65 "[spec-shapes] a two-column header (GitHub drops the third cell) is refused (rc 65)"
has "$O" "header has 2 column(s)" "[spec-shapes] …naming the header"
spec "$S" "$TABLE

$TABLE";                      O=$(refused "$R" "$S"); rc=$?
eq "$rc" 65 "[spec-shapes] two tables in the section are refused (rc 65)"
has "$O" "holds 2 tables" "[spec-shapes] …as two tables"
spec "$S" "$TABLE

A note under the table, about \`cmd | tee log\`."; eq "$(kbrc "$R" check spec "$S")" 0 "[spec-shapes] a blank line ends the table: prose with a | after it passes (rc 0)"
spec "$S" "$TABLE
A note right under the rows."; eq "$(kbrc "$R" check spec "$S")" 0 "[spec-shapes] stated limit: prose glued under the rows, a line without a |, ends the table (rc 0; the check does not render)"
for around in "### Cases|above" "These are the cases:|above" "- a note|below" "> a note|below" "### More|below" "***|below"; do
  line=${around%|*}; where=${around##*|}
  if [ "$where" = above ]; then spec "$S" "$line
$TABLE"; else spec "$S" "$TABLE
$line"; fi
  eq "$(kbrc "$R" check spec "$S")" 0 "[spec-shapes] '$line' right $where the table is not judged (rc 0)"
done
spec "$S" '| a | b | c |
    |---|---|---|
| x | y | z |';              eq "$(kbrc "$R" check spec "$S")" 0 "[spec-shapes] stated limit: a delimiter row indented four spaces passes (rc 0)"
spec "$S" "<!--

$TABLE

-->";                         eq "$(kbrc "$R" check spec "$S")" 0 "[spec-shapes] stated limit: a table inside an HTML comment passes (rc 0)"
spec "$S" "$TABLE
| - | - | - |";               eq "$(kbrc "$R" check spec "$S")" 0 "[spec-shapes] a data row of dashes (n/a) is a row, not a second table (rc 0)"
spec "$S" '| a | b | c |

|---|---|---|
| x | y | z |';              O=$(refused "$R" "$S"); eq "$?" 65 "[spec-shapes] a blank line between header and delimiter: no table on GitHub, refused (rc 65)"
has "$O" "has no table" "[spec-shapes] …as no table"
spec "$S" '    | a | b | c |
    |---|---|---|
    | x | y | z |';          O=$(refused "$R" "$S"); eq "$?" 65 "[spec-shapes] a table indented four spaces is a code block: refused (rc 65)"
has "$O" "has no table" "[spec-shapes] …as no table"
spec "$S" '| a | b | c |
|---|---|
| x | y | z |';              O=$(refused "$R" "$S"); eq "$?" 65 "[spec-shapes] a delimiter row of two columns under a three-column header is refused (rc 65)"
has "$O" "delimiter row has 2 column(s)" "[spec-shapes] …naming the delimiter row"
spec "$S" '|---|---|---|
|---|---|---|
| x | y | z |';              O=$(refused "$R" "$S"); eq "$?" 65 "[spec-shapes] a delimiter row is never a header: two delimiter rows and a row are no table (rc 65)"
has "$O" "has no table" "[spec-shapes] …as no table"
spec "$S" "$TABLE"'
```
code
```
| two | cells |'; eq "$(kbrc "$R" check spec "$S")" 0 "[spec-shapes] a fenced block ends the table: a | line after it is not a row (rc 0)"
spec "$S" '| a | b | c |
```
code
```
|---|---|---|
| x | y | z |';              O=$(refused "$R" "$S"); eq "$?" 65 "[spec-shapes] a fenced block between header and delimiter: no table (rc 65)"
has "$O" "has no table" "[spec-shapes] …as no table"
spec "$S" "$TABLE

$TABLE
$TABLE"; O=$(refused "$R" "$S"); eq "$?" 65 "[spec-shapes] a table, then two glued ones: refused (rc 65)"
has "$O" "holds 2 tables" "[spec-shapes] …counted as two tables (the glued pair is one run)"
spec "$S" "$TABLE"; python3 - "$S" <<'PY'  # the heading written in another case: the checker's input, not a break
import sys
p = sys.argv[1]; t = open(p, encoding="utf-8").read().replace("## Inputs and failure cases", "## Inputs and Failure Cases")
open(p, "w", encoding="utf-8").write(t)
PY
O=$(refused "$R" "$S"); rc=$?
eq "$rc" 65 "[spec-shapes] '## Inputs and Failure Cases' on a new spec is refused (rc 65)"
has "$O" "must be written exactly" "[spec-shapes] …as the section written wrong"
spec "$S" "$TABLE"; python3 - "$S" <<'PY'  # the heading with GitHub's optional closing hashes: the checker's input, not a break
import sys
p = sys.argv[1]; t = open(p, encoding="utf-8").read().replace("## Inputs and failure cases", "## Inputs and failure cases ##")
open(p, "w", encoding="utf-8").write(t)
PY
eq "$(kbrc "$R" check spec "$S")" 0 "[spec-shapes] '## Inputs and failure cases ##' (closing hashes, the same heading on GitHub) passes (rc 0)"
spec "$S" "$TABLE"; python3 - "$S" <<'PY'  # the heading with a colon: the checker's input, not a break
import sys
p = sys.argv[1]; t = open(p, encoding="utf-8").read().replace("## Inputs and failure cases", "## Inputs and failure cases:")
open(p, "w", encoding="utf-8").write(t)
PY
O=$(refused "$R" "$S"); rc=$?
eq "$rc" 65 "[spec-shapes] '## Inputs and failure cases:' on a new spec is refused (rc 65)"
has "$O" "must be written exactly" "[spec-shapes] …as the section written wrong, not as an unknown section"
hasnt "$O" "unknown section" "[spec-shapes] …and not as an unknown section"
spec "$S" -
A1=$(cd "$R" && cenv python3 -B "$PL/scripts/kb.py" check spec 2026-10-01-old 2>&1)
A2=$(cd "$R" && cenv PYTHONUNBUFFERED=1 python3 -B "$PL/scripts/kb.py" check spec 2026-10-01-old 2>&1)
spec "$R/kb/specs/2026-10-01-old.md" -; printf '\n## Extra\n\nx\n' >> "$R/kb/specs/2026-10-01-old.md"
B1=$(cd "$R" && capped cenv python3 -B "$PL/scripts/kb.py" check spec 2026-10-01-old 2>&1)
B2=$(cd "$R" && capped cenv PYTHONUNBUFFERED=1 python3 -B "$PL/scripts/kb.py" check spec 2026-10-01-old 2>&1)
git_ -C "$R" checkout -q -- kb/specs/2026-10-01-old.md
eq "$B1" "$B2" "[spec-shapes] a refusal with a WARNING prints in one order, buffered or not"
eq "$(printf '%s\n' "$B1" | head -1 | cut -c1-7)" WARNING "[spec-shapes] …the WARNING first"
eq "$A1" "$A2" "[spec-shapes] control: a pass with a WARNING is the same buffered or not"

echo "-- [spec-fenced]"
{ printf -- '---\ndescription: "x"\n---\n\n# X\n\n## Bối cảnh\n\nWhy.\n\n## Mục tiêu\n\nWhat.\n\n## Ngoài phạm vi\n\nNone.\n\n'
  printf '```\n## Inputs and failure cases\n\n%s\n```\n\n' "$TABLE"
  printf '## Tiêu chí chấp nhận\n\n1. `make test` → 0 fail\n2. PR có mục `## Bằng chứng chạy`.\n'; } > "$S"
O=$(refused "$R" "$S"); eq "$?" 65 "[spec-fenced] the heading only inside a fence does not count (rc 65)"
has "$O" "section \`## Inputs and failure cases\` is missing" "[spec-fenced] …the section is missing"
spec "$S" "$(printf '```\n%s\n```' "$TABLE")"; O=$(refused "$R" "$S"); eq "$?" 65 "[spec-fenced] the table only inside a fence does not count (rc 65)"
has "$O" "has no table" "[spec-fenced] …as no table"

echo "-- [spec-old-warns]"
O=$(kb "$R" check spec 2026-10-01-old); rc=$?
eq "$(kbrc "$R" check spec 2026-10-01-old)" 0 "[spec-old-warns] a spec on the merge base without the section passes (rc 0)"
has "$O" "WARNING" "[spec-old-warns] …with a WARNING line"
has "$O" "Inputs and failure cases" "[spec-old-warns] …that names the section"
eq "$(kbrc "$R" check spec 2026-10-02-oldbroken)" 0 "[spec-old-warns] a spec on the merge base with a broken table passes (rc 0)"
eq "$(kb "$R" check spec 2026-10-02-oldbroken | grep -cE 'row [1]: needs three filled cells')" 1 "[spec-old-warns] …and the warning names the first row"
spec "$R/kb/specs/2026-10-01-old.md" - ; printf '\n## Extra\n\nx\n' >> "$R/kb/specs/2026-10-01-old.md"
O=$(refused "$R" 2026-10-01-old); eq "$?" 65 "[spec-old-warns] an old spec still fails on any other shape problem (an unknown section: rc 65)"
git_ -C "$R" checkout -q -- kb/specs/2026-10-01-old.md

echo "-- [spec-date]"
N=$(fresh); git_ init -q -b main "$N"; mkdir -p "$N/kb/specs"
spec "$N/kb/specs/2026-11-01-before.md" -; spec "$N/kb/specs/2026-11-02-on.md" -; spec "$N/kb/specs/undated.md" -
eq "$(kbrc "$N" check spec 2026-11-01-before)" 0 "[spec-date] no origin, dated 2026-11-01: rc 0"
has "$(kb "$N" check spec 2026-11-01-before)" "WARNING" "[spec-date] …with a WARNING line"
O=$(refused "$N" 2026-11-02-on); eq "$?" 65 "[spec-date] no origin, dated 2026-11-02: refused (rc 65)"
eq "$(kbrc "$N" check spec undated)" 0 "[spec-date] no origin and no date in the name: rc 0 with a warning (a doubt never turns a spec red)"
P=$(fresh); mkdir -p "$P"; spec "$P/2026-12-01-loose.md" -
O=$(refused "$N" "$P/2026-12-01-loose.md"); eq "$?" 65 "[spec-date] a path outside any git tree, dated after: refused (rc 65)"

echo "-- [spec-language]"
for L in vi en; do
  W=$(fresh); git_ init -q -b main "$W"; mkdir -p "$W/kb/specs" "$W/.vibemaestro"
  printf '{"schema": 1, "language": "%s"}\n' "$L" > "$W/.vibemaestro/sdlc.json"
  kb "$W" new spec lang --date 2026-11-10 >/dev/null
  F="$W/kb/specs/2026-11-10-lang.md"
  H=$(grep -E '^## ' "$F" | sed -n 3,5p | tr '\n' '|')
  case $L in
    vi) eq "$H" "## Ngoài phạm vi|## Inputs and failure cases|## Tiêu chí chấp nhận|" "[spec-language] vi: the template has the section between out-of-scope and criteria" ;;
    en) eq "$H" "## Out of scope|## Inputs and failure cases|## Acceptance criteria|" "[spec-language] en: the template has the same heading between out-of-scope and criteria" ;;
  esac
  O=$(refused "$W" 2026-11-10-lang); eq "$?" 65 "[spec-language] $L: the fresh template is refused while its blanks are there"
  python3 - "$F" <<'PY'  # fills the template kb.py new wrote: the checker's input, not a break
import re, sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
s = re.sub(r"<(?:FILL|ĐIỀN)[^>]*>", "filled", s)
open(p, "w", encoding="utf-8").write(s)
PY
  eq "$(kbrc "$W" check spec 2026-11-10-lang)" 0 "[spec-language] $L: the template, filled, passes"
done

# ── hooks ────────────────────────────────────────────────────────────────────────────────────────
A=$(fresh); mk_app "$A"
sub() { (cd "$A" && printf '%s' "$1" | cenv python3 -B "$PL/scripts/session-start.py" subagent 2>/dev/null); }
p_sub() { printf '{"session_id":"%s","hook_event_name":"SubagentStart","agent_id":"%s","agent_type":"%s","cwd":"%s"}' "$1" "$2" "$3" "$A"; }
evname() { printf '%s' "$1" | python3 -c 'import json,sys; print((json.loads(sys.stdin.read()).get("hookSpecificOutput") or {}).get("hookEventName",""))' 2>/dev/null; }

echo "-- [sub-bad-payload]"
for p in '' 'not json' '[1, 2]'; do
  O=$(sub "$p"); rc=$?
  eq "$rc" 0 "[sub-bad-payload] payload '${p:-<empty>}': rc 0"; empty "$O" "[sub-bad-payload] payload '${p:-<empty>}': no output"
done

echo "-- [sub-readonly]"
for t in Explore Plan claude-code-guide statusline-setup; do
  empty "$(sub "$(p_sub s1 a1 "$t")")" "[sub-readonly] $t gets nothing"
done
for t in general-purpose my-plugin:worker; do
  O=$(sub "$(p_sub s1 "a-$t" "$t")"); C=$(ctx "$O")
  eq "$(evname "$O")" SubagentStart "[sub-readonly] $t: one JSON for SubagentStart"
  has "$C" "the brief and sdlc win" "[sub-readonly] $t: the core carries the precedence sentence"
  has "$C" "Inputs and failure cases" "[sub-readonly] $t: …and the test rules"
  [ "$(nchars "$C")" -le 3001 ] && ok "[sub-readonly] $t: the core is at most 3000 characters ($(nchars "$C"))" || bad "[sub-readonly] $t: core of $(nchars "$C") characters"
done
O=$(sub '{"session_id":"s1","hook_event_name":"SubagentStart","agent_id":"a9"}')
has "$(ctx "$O")" "the brief and sdlc win" "[sub-readonly] a missing agent_type gets the core (a doubt injects)"

echo "-- [sub-matcher]"
M=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["hooks"]["SubagentStart"][0]["matcher"])' "$PL/hooks/hooks.json")
for t in Explore Plan claude-code-guide statusline-setup; do
  eq "$(python3 -c 'import re,sys; print(bool(re.fullmatch(sys.argv[1], sys.argv[2])), bool(re.search(sys.argv[1], sys.argv[2])))' "$M" "$t")" "False False" "[sub-matcher] $t is skipped, anchored or not"
done
for t in general-purpose Explorer claude my-plugin:worker ''; do
  eq "$(python3 -c 'import re,sys; print(bool(re.fullmatch(sys.argv[1], sys.argv[2])), bool(re.search(sys.argv[1], sys.argv[2])))' "$M" "$t")" "True True" "[sub-matcher] '${t}' runs the hook, anchored or not"
done
has "$(hook_cmds "$PL/hooks/hooks.json" SubagentStart general-purpose)" "session-start.py\" subagent" "[sub-matcher] the hook command is session-start.py subagent"
eq "$(cenv python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import vsdlc; print(sorted(vsdlc.READ_ONLY_AGENTS))' "$PL/scripts")" \
   "$(python3 -c 'import re,sys; print(sorted(t for t in sys.argv[2:] if not re.fullmatch(sys.argv[1], t)))' "$M" Explore Plan claude-code-guide statusline-setup general-purpose claude Explorer Planner my-plugin:worker statusline)" \
   "[sub-matcher] the matcher skips exactly the script's READ_ONLY_AGENTS among known and near names"

echo "-- [sub-config]"
B=$(fresh); mk_app "$B"; mkdir -p "$B/.vibemaestro"
printf '{"schema": 1, "hooks": "off"}\n' > "$B/.vibemaestro/sdlc.json"
empty "$(cd "$B" && printf '{"session_id":"s2","agent_id":"a","agent_type":"general-purpose","cwd":"%s"}' "$B" | cenv python3 -B "$PL/scripts/session-start.py" subagent)" "[sub-config] hooks: off is silent"
printf '{"schema": 1, "hooks": 7}\n' > "$B/.vibemaestro/sdlc.json"
O=$(cd "$B" && printf '{"session_id":"s2","agent_id":"a","agent_type":"general-purpose","cwd":"%s"}' "$B" | cenv python3 -B "$PL/scripts/session-start.py" subagent)
has "$(ctx "$O")" ".vibemaestro/sdlc.json is invalid" "[sub-config] an invalid config gives the config warning"
has "$(ctx "$O")" "the brief and sdlc win" "[sub-config] …and the core"

echo "-- [sub-cap]"
FR=$(fresh); mkdir -p "$FR/templates" "$FR/rules"
python3 -c 'import sys; open(sys.argv[1], "w").write("\n\n".join("paragraph %d " % i + "x" * 200 for i in range(60)))' "$FR/templates/subagent-core.md"
O=$(cenv python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import vsdlc; c, s = vsdlc.subagent_core(sys.argv[2]); print(len(c)); print(c[-120:])' "$PL/scripts" "$FR")
[ "$(printf '%s' "$O" | head -1)" -le 3000 ] && ok "[sub-cap] a 12k core is cut to at most 3000 characters ($(printf '%s' "$O" | head -1))" || bad "[sub-cap] cut core is $(printf '%s' "$O" | head -1) characters"
has "$O" "read it all at $FR/templates/subagent-core.md" "[sub-cap] …with a pointer to the file"
rm -f "$FR/templates/subagent-core.md"
O=$(cenv python3 -B -c 'import sys; sys.path.insert(0, sys.argv[1]); import vsdlc; c, s = vsdlc.subagent_core(sys.argv[2]); print(s)' "$PL/scripts" "$FR"); rc=$?
eq "$rc" 0 "[sub-cap] a missing core file raises nothing"
has "$O" "cannot read the subagent core" "[sub-cap] …and says so"

echo "-- [marker-agent]"
edit() { (cd "$A" && printf '%s' "$1" | cenv python3 -B "$PL/scripts/pre-edit.py" 2>/dev/null) | python3 -c 'import json,sys
try: print("SHOWN" if "current-state-shape" in json.loads(sys.stdin.read())["hookSpecificOutput"]["additionalContext"] else "")
except Exception: print("")'; }
pe() { printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"%s/kb/current-state.md"}%s}' "$1" "$A" "${2:+,\"agent_id\":\"$2\",\"agent_type\":\"general-purpose\"}"; }
S1=$(sid)
eq "$(edit "$(pe "$S1")")" SHOWN "[marker-agent] the parent sees the rule the first time"
eq "$(edit "$(pe "$S1")")" "" "[marker-agent] control: …and not the second time"
eq "$(edit "$(pe "$S1" agentA)")" SHOWN "[marker-agent] a subagent sees the rule the parent already saw"
eq "$(edit "$(pe "$S1" agentA)")" "" "[marker-agent] …once"
eq "$(edit "$(pe "$S1" agentB)")" SHOWN "[marker-agent] a second subagent keeps its own set"
S2=$(sid)
eq "$(edit "$(pe "$S2" agentC)")" SHOWN "[marker-agent] a subagent sees a rule first"
eq "$(edit "$(pe "$S2")")" SHOWN "[marker-agent] …and the parent still sees it after"
S3=$(sid); LONG=$(python3 -c 'print("z" * 500)')
eq "$(edit "$(pe "$S3" "../../escape")")" SHOWN "[marker-agent] a hostile agent_id ../../escape: the rule is shown"
eq "$(edit "$(pe "$S3" "$LONG")")" SHOWN "[marker-agent] a 500-character agent_id: the rule is shown"
eq "$(edit "$(pe "$S3" "$LONG")")" "" "[marker-agent] …once"
OUT=$(find "$TMP" -path "$TMPDIR" -prune -o -name 'rule_current-state*' -print)
empty "$OUT" "[marker-agent] no marker is written outside TMPDIR"
eq "$(find "$TMPDIR" -maxdepth 1 -name 'vsdlc-*' -type d | grep -cv '/vsdlc-[A-Za-z0-9_-]*$')" 0 "[marker-agent] every marker directory name is sanitised"

echo "-- [marker-scope]"
# what a context has SEEN is per subagent; what the machine COMPUTED (the upstream cache) stays with the session
U=$(fresh); UO=$(fresh); UB=$(fresh)
git_ init -q --bare -b main "$UO"; mk_app "$U"; git_ -C "$U" remote add origin "$UO"; git_ -C "$U" push -q origin main 2>/dev/null
git_ clone -q "$UO" "$UB"; echo y > "$UB/later.txt"; git_ -C "$UB" add -A; git_ -C "$UB" commit -qm later; git_ -C "$UB" push -q origin main 2>/dev/null
git_ -C "$U" fetch -q origin
eq "$(git_ -C "$U" rev-list --count HEAD..origin/main)" 1 "instrument: the checkout is one commit behind origin/main"
S6=$(sid)
(cd "$U" && printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"%s/src/main.ts"},"agent_id":"agentU","agent_type":"general-purpose"}' "$S6" "$U" | cenv python3 -B "$PL/scripts/pre-edit.py" >/dev/null 2>&1)
eq "$(find "$TMPDIR/vsdlc-$S6" -maxdepth 1 -name 'upstream-*.json' | wc -l | tr -d ' ')" 1 "[marker-scope] a subagent's upstream check is cached with the session"
eq "$(find "$TMPDIR" -maxdepth 2 -path "*vsdlc-$S6-agent-*" -name 'upstream-*.json' | wc -l | tr -d ' ')" 0 "[marker-scope] …not in the subagent's own directory"
[ "$(find "$TMPDIR" -maxdepth 3 -path "*vsdlc-$S6-agent-*/reminders/*" -type f | wc -l)" -ge 1 ] && ok "[marker-scope] the subagent's reminder marks are its own" || bad "[marker-scope] no reminder mark in the subagent's directory"

echo "-- [payload-types]"
for p in '{"session_id":5,"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"x"}}' \
         '{"session_id":"s","cwd":5,"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"x"}}' \
         '{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":["x"]}' \
         '{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":7}}' \
         '{"session_id":"s","cwd":"bad\u0000cwd","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"x"}}' \
         '{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"a\u0000b"}}'; do
  O=$(cd "$A" && printf '%s' "$p" | cenv python3 -B "$PL/scripts/pre-edit.py" 2>&1); rc=$?
  eq "$rc" 0 "[payload-types] pre-edit, payload $p: rc 0"; hasnt "$O" "internal error" "[payload-types] …and no internal error"
done
for p in '{"session_id":5,"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git commit"}}' \
         '{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":["git","commit"]}}' \
         '{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":"git commit"}'; do
  O=$(cd "$A" && printf '%s' "$p" | cenv python3 -B "$PL/scripts/pre-bash.py" 2>&1); rc=$?
  eq "$rc" 0 "[payload-types] pre-bash, payload $p: rc 0"; hasnt "$O" "internal error" "[payload-types] …and no internal error"
done
O=$(cd "$A" && printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"%s/kb/current-state.md"}}' "$(sid)" "$A" | TMPDIR="$TMP/no-such-dir/x" cenv python3 -B "$PL/scripts/pre-edit.py" 2>&1); rc=$?
eq "$rc" 0 "[payload-types] an unwritable marker directory: rc 0"
has "$O" "current-state-shape" "[payload-types] …and the reminder is still said (no mark, say it)"

echo "-- [compact-reset]"
ss() { (cd "$A" && printf '{"session_id":"%s","hook_event_name":"SessionStart","source":"%s","cwd":"%s"}' "$1" "$2" "$A" | cenv python3 -B "$PL/scripts/session-start.py" "$3" 2>/dev/null); }
S4=$(sid)
eq "$(edit "$(pe "$S4")")" SHOWN "[compact-reset] shown before the compaction"
ss "$S4" startup context >/dev/null; eq "$(edit "$(pe "$S4")")" "" "[compact-reset] control: SessionStart startup does not reset"
ss "$S4" resume context >/dev/null;  eq "$(edit "$(pe "$S4")")" "" "[compact-reset] control: SessionStart resume does not reset"
ss "$S4" compact core >/dev/null;    eq "$(edit "$(pe "$S4")")" "" "[compact-reset] the core command alone does not reset (only context does)"
ss "$S4" compact context >/dev/null; eq "$(edit "$(pe "$S4")")" SHOWN "[compact-reset] SessionStart compact: the same edit shows its rule again"
eq "$(edit "$(pe "$S4")")" "" "[compact-reset] …once"
pd() { (cd "$A" && printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"%s/src/main.ts"}}' "$1" "$A" | cenv python3 -B "$PL/scripts/pre-edit.py" 2>/dev/null) | grep -c 'APP-QD-SRC\|d-app.md'; }
S7=$(sid)
eq "$(pd "$S7")" 1 "[compact-reset] a decision reminder is said the first time"
eq "$(pd "$S7")" 0 "[compact-reset] control: …not the second"
ss "$S7" compact context >/dev/null; eq "$(pd "$S7")" 1 "[compact-reset] a decision reminder (a kind with no list) is said again after a compaction"
C=$(fresh); mk_app "$C"; mkdir -p "$C/.vibemaestro"; printf '{"schema": 1, "hooks": 7}\n' > "$C/.vibemaestro/sdlc.json"
S5=$(sid); cs() { (cd "$C" && printf '{"session_id":"%s","hook_event_name":"SessionStart","source":"%s","cwd":"%s"}' "$S5" "$1" "$C" | cenv python3 -B "$PL/scripts/session-start.py" "$2" 2>/dev/null); }
W1=$( { cs startup core; cs startup context; } | grep -o 'is invalid, so this session' | wc -l)
eq "$W1" 1 "instrument: at startup the config warning is said once across core and context"
W2=$( { cs compact core; cs compact context; } | grep -o 'is invalid, so this session' | wc -l)
eq "$W2" 0 "[compact-reset] at compact the config warning keeps its mark: not said again, never twice"
O=$(cd "$A" && printf '{"session_id":"%s","hook_event_name":"SessionStart","source":"compact","cwd":"%s"}' "$(sid)" "$A" | TMPDIR="$TMP/no-such-dir" cenv python3 -B "$PL/scripts/session-start.py" context); rc=$?
eq "$rc" 0 "[compact-reset] a missing marker directory: rc 0"
hasnt "$O" "internal error" "[compact-reset] …and no internal error"
O=$(cd "$A" && printf '{"session_id":5,"hook_event_name":"SessionStart","source":"compact","cwd":"%s"}' "$A" | cenv python3 -B "$PL/scripts/session-start.py" context); rc=$?
eq "$rc" 0 "[compact-reset] a session id that is not a string: rc 0"
hasnt "$O" "internal error" "[compact-reset] …and no internal error"

echo "-- [core-room]"
# The coordinated core (workflow-core + coordinated-work, one SessionStart string) must stay whole with room to spare: the hook's
# header line carries the core's absolute path, so the copy sits where that path is 160 characters, longer than a real install.
DEEP="$TMP/$(python3 -c 'import sys; print("d" * (160 - len(sys.argv[1]) - len("/plugin/rules/workflow-core.instructions.md") - 1))' "$TMP")"
mkdir -p "$DEEP"; cp -r "$PL" "$DEEP/plugin"
CORE_PATH="$DEEP/plugin/rules/workflow-core.instructions.md"
eq "${#CORE_PATH}" 160 "instrument: the core's path is 160 characters"
LAST=$(grep -v '^[[:space:]]*$' "$PL/rules/coordinated-work.instructions.md" | tail -1)
O=$(cd "$A" && printf '{"session_id":"%s","hook_event_name":"SessionStart","source":"startup","cwd":"%s"}' "$(sid)" "$A" \
    | cenv VIBEMAESTRO_ROLE=worker python3 -B "$DEEP/plugin/scripts/session-start.py" core 2>/dev/null)
C=$(ctx "$O")
has "$C" "$CORE_PATH" "[core-room] the header names the core at its 160-character path"
has "$C" "Coordinated work" "[core-room] a worker session gets the coordinated part"
has "$C" "$LAST" "[core-room] …whole: its last line is delivered"
hasnt "$C" "cut at the hook" "[core-room] …and nothing is cut"
has "$C" "the brief and sdlc win" "[core-room] the precedence sentence is in the core"
[ "$(nchars "$C")" -le 9000 ] && ok "[core-room] the core string is within the hook budget ($(nchars "$C") of 9000)" || bad "[core-room] core string of $(nchars "$C") characters"

echo
summary
