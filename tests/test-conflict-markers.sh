#!/bin/bash
# =============================================================================
# Committed merge-conflict markers: tests/fixtures/conflict_markers.py and its allow list tests/conflict-marker-allow.txt
# =============================================================================
# Run: bash tests/test-conflict-markers.sh   (in every plan: @always in tests/suites.map, a marker can arrive through any path)
#
#   1. the real tree: no tracked file holds a marker; the allow list has no stale entry; the scan read the real tree (not a vacuous green);
#   2. planted breaks on a scratch git repository, each its own case: a full marker block is red and named path:line; a lone start
#      and a lone end are red; CRLF markers are red; a marker file under tests/ is red; a Markdown setext heading and a lone
#      "=======" stay green; the same file listed in the allow list is green; an entry with no reason, an untracked path or a clean
#      file is red; a binary file and a symlink are skipped.
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

summary
