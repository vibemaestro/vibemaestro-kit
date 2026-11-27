#!/bin/bash
# =============================================================================
# Committed merge-conflict markers: tests/fixtures/conflict_markers.py and its allow list tests/conflict-marker-allow.txt;
# file size and the decision layer under plugins/: tests/fixtures/size_lint.py and its list tests/fixtures/oversize-list.txt
# =============================================================================
# Run: bash tests/test-conflict-markers.sh   (in every plan: @always in tests/suites.map, a marker or a grown file can arrive through any path)
#
#   1. the real tree: no tracked file holds a marker; the allow list has no stale entry; the scan read the real tree (not a vacuous green);
#   2. planted breaks on a scratch git repository, each its own case: a full marker block is red and named path:line; a lone start
#      and a lone end are red; CRLF markers are red; a marker file under tests/ is red; a Markdown setext heading and a lone
#      "=======" stay green; the same file listed in the allow list is green; an entry with no reason, an untracked path or a clean
#      file is red; a binary file and a symlink are skipped.
#   3. size_lint.py on the real tree and on a scratch repository: a file over 1000 lines not
#      listed, a listed file off its number, a bad or stale list line, a list that grows against origin/main (raised number, new
#      line, renamed file), a base it cannot read in CI, input/output in a domain/ file, and a root it cannot read are red.
# Real git on a throw-away repository under the suite's scratch tree; no network. The marker lines are built here with printf
# from pieces, so no tracked file of this repository carries a marker line (this suite is scanned by itself).
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
export PYTHONDONTWRITEBYTECODE=1
CHECK="$HERE/fixtures/conflict_markers.py"

L=$(printf '<%.0s' 1 2 3 4 5 6 7); R=$(printf '>%.0s' 1 2 3 4 5 6 7); M=$(printf '=%.0s' 1 2 3 4 5 6 7)
block() { printf 'before\n%s HEAD\nours\n%s\ntheirs\n%s origin/main\nafter\n' "$L" "$M" "$R"; }

echo "== the real tree =="
O=$(python3 "$CHECK" 2>"$TMP/err"); rc=$?
eq "$rc" 0 "the tracked tree holds no conflict marker (rc $rc)"
[ "$rc" = 0 ] || printf '%s\n' "$O" | head -20
N=$(grep -oE '[0-9]+ tracked files read' "$TMP/err" | grep -oE '^[0-9]+')
[ "${N:-0}" -gt 300 ] && ok "instrument: the scan read the real tree (${N:-0} files)" || bad "instrument: the scan read only ${N:-0} files"
HEAD_N=$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$SRC_ROOT" ls-files | grep -c .)
[ "${N:-0}" -ge $((HEAD_N - 20)) ] && ok "instrument: it read nearly every tracked file ($N of $HEAD_N; the rest are links and submodules)" || bad "instrument: read $N of $HEAD_N tracked files"

echo "== planted breaks, on a scratch repository =="
R_="$TMP/repo"; mkdir -p "$R_/docs" "$R_/tests"
git_ init -q -b main "$R_"
printf 'Title\n%s\n\nbody\n' "$M" > "$R_/docs/setext.md"
printf 'a line\n%s\nanother\n' "$M" > "$R_/docs/lone-mid.txt"
printf 'plain\n' > "$R_/docs/clean.txt"
cm() { git_ -C "$R_" add -A && git_ -C "$R_" -c user.name=t -c user.email=t@t.invalid commit -qm "$1"; }
cm base
run() { python3 "$CHECK" --root "$R_" "$@" 2>/dev/null; }   # prints the problems; rc is the check's
O=$(run); rc=$?
eq "$rc" 0 "control: a setext heading and a lone mid line are green (rc $rc)"
empty "$O" "control: and report nothing"

block > "$R_/docs/broken.md"; cm broken
O=$(capped run); rc=$?
eq "$rc" 1 "planted: a full marker block is red (rc $rc)"
has "$O" "docs/broken.md:2:" "planted: the start line is named, path:line"
has "$O" "docs/broken.md:4:" "planted: the mid line between the two is named"
has "$O" "docs/broken.md:6:" "planted: the end line is named"
hasnt "$O" "setext.md" "the setext heading is not named next to it"
hasnt "$O" "lone-mid.txt" "the lone mid line is not named next to it"

# a setext heading before and after a real block, in the same file: only the block's own mid line is a marker
printf 'Top\n%s\n\n' "$M" > "$R_/docs/mixed.md"; block >> "$R_/docs/mixed.md"; printf '\nBottom\n%s\n' "$M" >> "$R_/docs/mixed.md"; cm mixed
O=$(capped run | grep 'docs/mixed.md' | cut -d: -f2 | tr '\n' ' ')
eq "$O" "5 7 9 " "planted: in a file with setext headings around a real block only the block's three lines are named (not the setext ones)"
git_ -C "$R_" rm -q docs/mixed.md; cm rm-mixed

# the allow list: a fixture that needs markers, with a reason
printf 'docs/broken.md a fixture that needs a marker block\n' > "$TMP/allow.txt"
O=$(run --allow "$TMP/allow.txt"); rc=$?
eq "$rc" 0 "the same file in the allow list is green (rc $rc)"
printf 'docs/broken.md\n' > "$TMP/allow-noreason.txt"
O=$(capped run --allow "$TMP/allow-noreason.txt"); rc=$?
eq "$rc" 1 "an allow entry with no reason is red (rc $rc)"; has "$O" "has no reason" "...and says why"
printf 'docs/broken.md a fixture\ndocs/clean.txt used to need markers\n' > "$TMP/allow-stale.txt"
O=$(capped run --allow "$TMP/allow-stale.txt"); rc=$?
eq "$rc" 1 "an allow entry for a clean file is red (rc $rc)"; has "$O" "docs/clean.txt': the file has no marker" "...and names it"
printf 'docs/broken.md a fixture\ndocs/gone.md was deleted\n' > "$TMP/allow-gone.txt"
O=$(capped run --allow "$TMP/allow-gone.txt"); rc=$?
eq "$rc" 1 "an allow entry for a path git does not track is red (rc $rc)"; has "$O" "docs/gone.md': not a tracked path" "...and names it"
printf '# a comment\n\ndocs/broken.md a fixture\n' > "$TMP/allow-comment.txt"
run --allow "$TMP/allow-comment.txt" >/dev/null; eq "$?" 0 "comment and blank lines in the allow list are ignored"
git_ -C "$R_" rm -q docs/broken.md; cm rm-broken

printf '%s HEAD\nonly a start\n' "$L" > "$R_/docs/lone-start.md"; cm start
O=$(capped run); eq "$?" 1 "planted: a lone start line is red"; has "$O" "docs/lone-start.md:1:" "...and named"
git_ -C "$R_" rm -q docs/lone-start.md; cm rm-start
printf 'only an end\n%s origin/main\n' "$R" > "$R_/docs/lone-end.md"; cm end
O=$(capped run); eq "$?" 1 "planted: a lone end line is red"; has "$O" "docs/lone-end.md:2:" "...and named"
git_ -C "$R_" rm -q docs/lone-end.md; cm rm-end

printf '\357\273\277%s HEAD\nx\n%s\ny\n%s o\n' "$L" "$M" "$R" > "$R_/docs/bom.md"; cm bom
O=$(capped run); eq "$?" 1 "planted: a BOM before the start marker of line 1 is red"; has "$O" "docs/bom.md:1:" "...the start line is named, its BOM ignored"
has "$O" "docs/bom.md:3:" "...and the mid line after it too (a start line the BOM hid would drop it)"
git_ -C "$R_" rm -q docs/bom.md; cm rm-bom
{ printf '\357\273\277%s HEAD\nonly a start\n' "$L"; } > "$R_/docs/bom-start.md"; cm bom-start
O=$(capped run); eq "$?" 1 "planted: a BOM and a lone start marker is red"; has "$O" "docs/bom-start.md:1:" "...and named"
git_ -C "$R_" rm -q docs/bom-start.md; cm rm-bom-start
mkdir -p "$R_/sub dir/deep"; { printf 'caf\351\n%s HEAD\nx\n%s\ny\n%s o' "$L" "$M" "$R"; } > "$R_/sub dir/deep/odd name.md"; cm odd
O=$(capped run); eq "$?" 1 "planted: a marker block in a subdirectory with spaces, non-UTF-8 text and no final newline is red"
has "$O" "sub dir/deep/odd name.md:6:" "...the last line, with no newline after it, is named"
git_ -C "$R_" rm -q "sub dir/deep/odd name.md"; cm rm-odd

block | sed 's/$/\r/' > "$R_/docs/crlf.md"; cm crlf
O=$(capped run); eq "$?" 1 "planted: CRLF markers are red"; has "$O" "docs/crlf.md:4:" "...the mid line too, its CR ignored"
git_ -C "$R_" rm -q docs/crlf.md; cm rm-crlf

block > "$R_/tests/fixture.txt"; cm under-tests
O=$(capped run); eq "$?" 1 "planted: a marker file under tests/ is red (this scan does not skip tests/)"; has "$O" "tests/fixture.txt:2:" "...and named"
git_ -C "$R_" rm -q tests/fixture.txt; cm rm-tests

printf 'a %s b\nc %s\n' "$L" "$R" > "$R_/docs/inline.md"; cm inline
run >/dev/null; eq "$?" 0 "control: marker characters that do not start a line are green"
git_ -C "$R_" rm -q docs/inline.md; cm rm-inline

{ block; printf '\0\1\2'; } > "$R_/docs/blob.bin"; cm binary
run >/dev/null; eq "$?" 0 "a file with a NUL byte is skipped (binary)"
block > "$R_/docs/target.md"; ln -s target.md "$R_/docs/link.md"; cm symlink
printf 'docs/target.md the target of the symlink under test\n' > "$TMP/allow-target.txt"
run --allow "$TMP/allow-target.txt" >/dev/null; eq "$?" 0 "a symlink to a marker file is skipped, not followed (its target is allow-listed: only the mode check keeps the link green)"

echo "== the checker itself =="
capped python3 "$CHECK" --root "$TMP/nowhere" >/dev/null 2>&1; eq "$?" 2 "a root that is not a git work tree is rc 2, not green"
mkdir -p "$TMP/empty" && git_ init -q -b main "$TMP/empty"
capped python3 "$CHECK" --root "$TMP/empty" >/dev/null 2>&1; eq "$?" 2 "a repository with no tracked file is rc 2, not green"
O=$(python3 "$CHECK" 2>&1 >/dev/null); has "$O" "tracked files read" "the summary line is printed"
eq "$(grep -cE "^($L |$R )" "$CHECK" "$0" | tr '\n' ' ')" "$CHECK:0 $0:0 " "neither the checker nor this suite holds a marker line (their quotes of the marker are not at a line start)"

echo "== size_lint.py: the real tree =="
SLINT="$HERE/fixtures/size_lint.py"
if [ "$(tree_shape "$SRC_ROOT")" = export ]; then   # the full run's export job: one commit of its own, no origin, CI set
  O=$(env -u CI python3 "$SLINT" 2>"$TMP/serr"); rc=$?; echo "  (the public export: a missing origin/main skips the comparison with the base, CI or not)"
else
  O=$(python3 "$SLINT" 2>"$TMP/serr"); rc=$?   # CI as the run has it: in CI an unreadable base is red here
fi
eq "$rc" 0 "no file under plugins/ is over 1000 lines beyond the oversize list, and no domain file does input/output (rc $rc)"
[ "$rc" = 0 ] || printf '%s\n' "$O" | head -20
SN=$(grep -oE '^size_lint: [0-9]+ files under plugins/ read' "$TMP/serr" | grep -oE '[0-9]+')
[ "${SN:-0}" -gt 60 ] && ok "instrument: the lint read the real plugin files (${SN:-0})" || bad "instrument: the lint read only ${SN:-0} files"

echo "== size_lint.py: what it refuses, on a scratch repository =="
S_="$TMP/srepo"; mkdir -p "$S_/plugins/a" "$S_/tests/fixtures"
git_ init -q -b main "$S_"
scm() { git_ -C "$S_" add -A && git_ -C "$S_" -c user.name=t -c user.email=t@t.invalid commit -qm "$1"; }
slint() { env -u CI python3 "$SLINT" --root "$S_" 2>"$TMP/serr2"; }   # prints the problems; rc is the lint's; CI unset
lines() { seq "$1" | sed 's/^/x = /'; }                                   # lines <n> — a Python file of n lines
SL="$S_/tests/fixtures/oversize-list.txt"
lines 1200 > "$S_/plugins/a/big.py"; lines 10 > "$S_/plugins/a/small.py"; lines 1000 > "$S_/plugins/a/edge.py"
printf '# a comment\n\n1200 plugins/a/big.py\n' > "$SL"
scm base; git_ -C "$S_" update-ref refs/remotes/origin/main HEAD
O=$(slint); eq "$?" 0 "control: a listed file at its number and a file of exactly 1000 lines are green"; empty "$O" "control: …and nothing is named"
has "$(cat "$TMP/serr2")" "3 files under plugins/ read, 1 in the oversize list, base " "control: …it read the three files and compared with the base"

lines 1001 > "$S_/plugins/a/new.py"; scm new
O=$(capped slint); eq "$?" 1 "a new file of 1001 lines not in the list is red"; has "$O" "plugins/a/new.py: 1001 lines, over the limit of 1000" "…named with its lines"
{ lines 1000; printf 'y = 1'; } > "$S_/plugins/a/new.py"; scm no-eol
O=$(capped slint); eq "$?" 1 "1000 newlines and a last line with no newline count 1001: red"; has "$O" "plugins/a/new.py: 1001 lines" "…named"
git_ -C "$S_" mv plugins/a/new.py plugins/a/new.sh; scm sh
O=$(capped slint); eq "$?" 1 "a .sh file over the limit is red too"; has "$O" "plugins/a/new.sh: 1001 lines" "…named"
git_ -C "$S_" rm -q plugins/a/new.sh; scm rm-sh
mkdir -p "$S_/docs"; lines 1500 > "$S_/plugins/a/notes.md"; lines 1500 > "$S_/docs/x.py"
ln -s big.py "$S_/plugins/a/link.py"; scm outside
{ lines 1000; printf 'z = "\377\376"\n'; } > "$S_/plugins/a/latin 1.py"; : > "$S_/plugins/a/empty.py"; scm odd
O=$(capped slint); eq "$?" 1 "a 1001-line file with non-UTF-8 bytes and a space in its name is red, an empty file is not"; has "$O" "plugins/a/latin 1.py: 1001 lines" "…named"; hasnt "$O" "empty.py" "…the empty file is not named"
git_ -C "$S_" rm -q "plugins/a/latin 1.py" plugins/a/empty.py; scm rm-odd
O=$(slint); eq "$?" 0 "control: a .md file, a file outside plugins/ and a symlink are not counted"; empty "$O" "…nothing is named"
git_ -C "$S_" rm -q -r plugins/a/notes.md docs plugins/a/link.py; scm rm-outside

lines 1201 > "$S_/plugins/a/big.py"
O=$(capped slint); eq "$?" 1 "a listed file that grows one line is red"; has "$O" "plugins/a/big.py: 1201 lines, 1 over its number 1200" "…with the excess"
lines 1150 > "$S_/plugins/a/big.py"
O=$(capped slint); eq "$?" 1 "a listed file under its number is red until the number is lowered"; has "$O" "lower the number to 1150" "…with the number to write"
lines 1000 > "$S_/plugins/a/big.py"
O=$(capped slint); eq "$?" 1 "a listed file at 1000 lines is red: its line must go"; has "$O" "plugins/a/big.py: 1000 lines, at or under 1000: remove its line" "…and says so"
git_ -C "$S_" checkout -q -- plugins/a/big.py
printf '1200 plugins/a/big.py\n1100 plugins/a/gone.py\n' > "$SL"
O=$(capped slint); eq "$?" 1 "an entry for a path git does not track is red"; has "$O" "'plugins/a/gone.py' is not a tracked .py or .sh file the rule reads: remove its line" "…named"
printf '1200 plugins/a/big.py\nmany plugins/a/x.py\n1200 plugins/a/big.py\n' > "$SL"
O=$(capped slint); eq "$?" 1 "a bad line and a path twice in the list are red"; has "$O" "'many plugins/a/x.py' is not '<lines> <path>'" "…the bad line named"; has "$O" "lists 'plugins/a/big.py' twice" "…and the double"
git_ -C "$S_" checkout -q -- tests/fixtures/oversize-list.txt

echo "== size_lint.py: the list against the base =="
git_ -C "$S_" checkout -q -b work
lines 1201 > "$S_/plugins/a/big.py"; printf '1201 plugins/a/big.py\n' > "$SL"; scm raise
O=$(capped slint); eq "$?" 1 "a number raised above the base's is red, the file matching it"; has "$O" "'plugins/a/big.py' raised from 1200 at the base" "…named with both numbers"
lines 1200 > "$S_/plugins/a/big.py"; printf '1200 plugins/a/big.py\n' > "$SL"; lines 1100 > "$S_/plugins/a/other.py"; printf '1100 plugins/a/other.py\n' >> "$SL"; scm add-line
O=$(capped slint); eq "$?" 1 "a new line in the list is red"; has "$O" "'plugins/a/other.py' is not listed at the base" "…named"
git_ -C "$S_" rm -q plugins/a/other.py; git_ -C "$S_" mv plugins/a/big.py plugins/a/bigger.py; printf '1200 plugins/a/bigger.py\n' > "$SL"; scm rename
O=$(capped slint); eq "$?" 1 "a listed file renamed with its size kept is red (a new line)"; has "$O" "'plugins/a/bigger.py' is not listed at the base" "…named"
git_ -C "$S_" checkout -q main; git_ -C "$S_" branch -q -D work

echo "== size_lint.py: a base it cannot read =="
git_ -C "$S_" update-ref -d refs/remotes/origin/main
O=$(capped env CI=true python3 "$SLINT" --root "$S_" 2>/dev/null); eq "$?" 1 "no origin/main in CI is red, not a silent pass"; has "$O" "the comparison with the base cannot run in CI" "…and says so"
O=$(slint); eq "$?" 0 "no origin/main on a machine: the other rules still run green"; has "$(cat "$TMP/serr2")" "comparison with the base skipped" "…and one line says the comparison was skipped"
lines 1001 > "$S_/plugins/a/new.py"; scm new-again
O=$(capped slint); eq "$?" 1 "…and with no base a new file over the limit is still red"
git_ -C "$S_" rm -q plugins/a/new.py; scm rm-new
git_ -C "$S_" rm -q tests/fixtures/oversize-list.txt; scm no-list; git_ -C "$S_" update-ref refs/remotes/origin/main HEAD
mkdir -p "$S_/tests/fixtures"; printf '1200 plugins/a/big.py\n' > "$SL"
O=$(CI=true python3 "$SLINT" --root "$S_" 2>"$TMP/serr2"); eq "$?" 0 "a base with no list yet (before the lint merged) is green in CI"; has "$(cat "$TMP/serr2")" "has no tests/fixtures/oversize-list.txt yet" "…and one line says so"
scm list-back; git_ -C "$S_" update-ref refs/remotes/origin/main HEAD

echo "== size_lint.py: the pure decision layer =="
D_="$S_/plugins/a/pkg/domain"; mkdir -p "$D_/sub" "$S_/plugins/a/pkg/app"
printf '%s\n' 'import re, json' 'from collections import Counter' 'from datetime import timedelta' 'from . import rules' 'from .rules import f' \
  'from ..domain.rules import g' 'from .. import domain' 'from re import compile' 'P = compile("a+")' 'from pkg.domain import rules as r' 'def plan(x):' '    return re.sub("a", "b", x).replace("b", "c")' > "$D_/plan.py"
printf '%s\n' 'from .. import plan' 'def f(): return 1' > "$D_/sub/rules.py"
printf '%s\n' 'import subprocess' 'def run(): print(open("x").read())' > "$S_/plugins/a/pkg/app/run.py"; scm domain-ok
O=$(slint); eq "$?" 0 "control: pure standard modules, domain imports (relative and absolute), str.replace, and input/output outside domain/ are green"; empty "$O" "…nothing is named"
dom() {  # dom <label> <expected text> <line>… — a domain file with these lines is red, named path:line
  local label=$1 want=$2; shift 2
  printf '%s\n' "$@" > "$D_/bad.py"; scm "dom $label"
  O=$(capped slint); eq "$?" 1 "a domain file that $label is red"; has "$O" "$want" "…named ($want)"
  git_ -C "$S_" rm -q plugins/a/pkg/domain/bad.py; scm "rm $label"
}
dom "imports subprocess" "plugins/a/pkg/domain/bad.py:2: imports 'subprocess'" 'import re' 'import subprocess'
dom "imports os.path inside a function" "plugins/a/pkg/domain/bad.py:3: imports 'os.path'" 'def f():' '    x = 1' '    from os.path import join'
dom "imports an app module, relatively" "plugins/a/pkg/domain/bad.py:1: imports '..app'" 'from ..app import run'
dom "imports time" "plugins/a/pkg/domain/bad.py:1: imports 'time'" 'import time'
dom "calls open" "plugins/a/pkg/domain/bad.py:2: uses 'open'" 'def f(p):' '    return open(p).read()'
dom "calls print" "plugins/a/pkg/domain/bad.py:1: uses 'print'" 'print(1)'
dom "calls input" "plugins/a/pkg/domain/bad.py:1: uses 'input'" 'x = input()'
dom "reads the clock through datetime" "plugins/a/pkg/domain/bad.py:2: uses 'datetime.datetime.now'" 'from datetime import datetime' 'def f(): return datetime.now()'
dom "reads the clock under another name" "plugins/a/pkg/domain/bad.py:2: uses 'datetime.datetime.now'" 'from datetime import datetime as dt' 'def f(): return dt.now()'
dom "reads the clock through a module alias" "plugins/a/pkg/domain/bad.py:2: uses 'datetime.date.today'" 'import datetime as d' 'x = d.date.today()'
dom "takes the clock call without calling it" "plugins/a/pkg/domain/bad.py:2: uses 'datetime.datetime.today'" 'import datetime' 'clock = datetime.datetime.today'
dom "takes open under another name" "plugins/a/pkg/domain/bad.py:1: uses 'open'" 'o = open' 'def f(p): return o(p)'
dom "reaches open through the builtins" "plugins/a/pkg/domain/bad.py:1: uses '__builtins__'" 'def f(p): return __builtins__["open"](p)'
dom "imports dynamically" "plugins/a/pkg/domain/bad.py:1: uses '__import__'" 'm = __import__("subprocess")'
dom "evaluates text" "plugins/a/pkg/domain/bad.py:1: uses 'eval'" 'x = eval("1")'
dom "reads the clock after a star import" "plugins/a/pkg/domain/bad.py:2: uses 'datetime.today'" 'from datetime import *' 'x = datetime.today()'
dom "imports through exec" "plugins/a/pkg/domain/bad.py:1: uses 'exec'" 'exec("import subprocess")'
dom "imports the app package from its parent" "plugins/a/pkg/domain/bad.py:1: imports '..app'" 'from .. import app'
dom "does not parse" "plugins/a/pkg/domain/bad.py:1: does not parse" 'def f(:'
printf 'import subprocess\n' > "$D_/sub/deep.py"; scm deep
O=$(capped slint); eq "$?" 1 "a file in a directory under domain/ is read too"; has "$O" "plugins/a/pkg/domain/sub/deep.py:1: imports 'subprocess'" "…named"
git_ -C "$S_" rm -q plugins/a/pkg/domain/sub/deep.py; scm rm-deep

echo "== size_lint.py: it could not run =="
O=$(capped python3 "$SLINT" --root "$TMP/nowhere" 2>&1); eq "$?" 2 "a root that is not a git work tree is rc 2, not green"; has "$O" "size_lint: cannot list the tracked files" "…and says so"
mkdir -p "$TMP/sempty/docs" && git_ init -q -b main "$TMP/sempty" && printf 'x\n' > "$TMP/sempty/docs/a.py" && git_ -C "$TMP/sempty" add -A
O=$(capped python3 "$SLINT" --root "$TMP/sempty" 2>&1); eq "$?" 2 "a repository with no .py or .sh file under plugins/ is rc 2, not green"; has "$O" "size_lint: no .py or .sh file under plugins/ read" "…and says so"

summary
