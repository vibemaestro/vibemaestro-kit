#!/bin/bash
# =============================================================================
# Issue links at the head of the PR body: `Closes #N` and the fixes line (open_pr.py --closes, --fixes), as they are today
# =============================================================================
# Run: bash tests/test-core-pr-links.sh
#
# Ports the families of two hub suites: the closing-link suite and the fixes suite. The
# hub fixes suite drove a function of the other channel with a fake `curl`; here the same families drive the core's own command line, with
# `--dry-run` (the payload) and with a fake gh (the body that reaches `gh pr create`, and the closing-link read).
# The reads that confirm the link after the PR exists (the poll with its retries and its deadline) are covered in
# tests/test-thu-tuc.sh and stay there; this suite only asserts that they are asked for when there is something to confirm,
# that they never change the exit code or stdout, and that they run without waiting (OPEN_PR_LINK_WAIT_S=0 in cenv).
# The words of the lines are the tokens of TOK_FIXES and `Closes`; they are the protocol a machine counts, so they are asserted.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
# shellcheck source=fixtures/flow.sh
. "$HERE/fixtures/flow.sh"
# shellcheck source=fixtures/ports.sh
. "$HERE/fixtures/ports.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
GHB="$TMP/ghbin"; mk_gh "$GHB"

PLX=""; PW=""; PT=""; F=""
# body <args> — the body the core builds, or the marker NO-BODY when the core failed (a crash must not look like "no line").
body() { local J; J=$(prd "$@" 2>/dev/null) || { printf 'NO-BODY'; return 0; }; pj "$J" body; }
# bcount <body> <grep pattern> — how many lines match; "NO-BODY" when the body is missing or lacks its summary heading.
bcount() { printf '%s\n' "$1" | grep -qFx "## $TOK_SUMMARY" || { printf 'NO-BODY'; return 0; }; printf '%s\n' "$1" | grep -c -- "$2"; }
first_lines() { printf '%s\n' "$1" | head -"$2" | tr '\n' '/'; }

fam_closes() {  # Closes #N
  PLX=$1; local B; mk_pr_repo
  B=$(body --closes 123)
  eq "$(first_lines "$B" 1)" "Closes #123/" "[L1] --closes 123: the first line of the body is 'Closes #123'"
  eq "$(printf '%s\n' "$B" | sed -n 2p)" "" "[L1] …followed by a blank line"
  eq "$(printf '%s\n' "$B" | sed -n 3p)" "## $TOK_SUMMARY" "[L1] …then the summary section"
  B=$(body); eq "$(bcount "$B" 'Closes #')" 0 "[L1] no --closes: no Closes line"
  eq "$(first_lines "$B" 1)" "## $TOK_SUMMARY/" "[L1] …and the body starts with the summary section"
  B=$(body --closes ""); eq "$(bcount "$B" 'Closes #')" 0 "[L1] an empty --closes: no Closes line"
  B=$(body --closes "abc"); eq "$(bcount "$B" 'Closes #')" 0 "[L1] a --closes with no digit: no Closes line"
  B=$(body --closes "#98"); eq "$(first_lines "$B" 1)" "Closes #98/" "[L1] '#98' is read as 98"
  B=$(body --closes "98,96"); eq "$(first_lines "$B" 2)" "Closes #98/Closes #96/" "[L1] '98,96': one line per number, in the given order"
  B=$(body --closes "98 96 98"); eq "$(printf '%s\n' "$B" | grep -c '^Closes #')" 2 "[L1] a repeated number is listed once"
  eq "$(first_lines "$B" 2)" "Closes #98/Closes #96/" "[L1] …and the order is the first appearance"
  B=$(body --closes 123 --fixes 98)
  hasline "$B" "Closes #123" "[L1] closes and fixes together: the Closes line is there"
  hasline "$B" "$TOK_FIXES #98" "[L1] …and the fixes line is there (neither overwrites the other)"
  eq "$(printf '%s\n' "$B" | grep -nFx "$TOK_FIXES #98" | cut -d: -f1)" 1 "[L1] …the fixes line comes first"
  eq "$(printf '%s\n' "$B" | grep -nFx "Closes #123" | cut -d: -f1)" 3 "[L1] …then the Closes line, both before the summary"
  for h in "## $TOK_SUMMARY" "## $TOK_EVIDENCE"; do hasline "$B" "$h" "[L1] the usual section is kept: $h"; done
}

fam_fixes() {  # the fixes line
  PLX=$1; local B; mk_pr_repo
  B=$(body --fixes 98)
  eq "$(first_lines "$B" 1)" "$TOK_FIXES #98/" "[L2] --fixes 98: the first line of the body is the fixes line"
  B=$(body --fixes "#98, 96 98")
  eq "$(first_lines "$B" 2)" "$TOK_FIXES #98/$TOK_FIXES #96/" "[L2] '#98, 96 98': one line each, in order, the repeat dropped"
  eq "$(printf '%s\n' "$B" | grep -c "^$TOK_FIXES #")" 2 "[L2] …exactly two lines"
  B=$(body); eq "$(bcount "$B" "$TOK_FIXES #")" 0 "[L2] no --fixes: no fixes line (a metric counts these lines)"
  eq "$(first_lines "$B" 1)" "## $TOK_SUMMARY/" "[L2] …the body starts with the summary section"
  B=$(body --fixes 123); eq "$(nline "$B" "$TOK_FIXES #123")" 1 "[L2] the line is exactly '$TOK_FIXES #N' (anchored at both ends)"
  B=$(body --fixes "none"); eq "$(bcount "$B" "$TOK_FIXES #")" 0 "[L2] a --fixes with no digit: no fixes line"
  B=$(body --fixes 98)
  for h in "## $TOK_SUMMARY" "## $TOK_EVIDENCE"; do hasline "$B" "$h" "[L2] the usual section is kept: $h"; done
}

fam_gh_links() {  # the same lines reach gh pr create, and the closing-link read is asked for only when there is something to confirm
  PLX=$1; local out rc GL; mk_pr_repo; GL="$F/gh.log"; : > "$GL"
  out=$(prg GH_LOG="$GL" GH_STDIN="$F/stdin.md" GH_CLOSING_JSON='[5]' -- --closes 5 --fixes 98 2>/dev/null); rc=$?
  eq "$rc" 0 "[L3] --closes and --fixes through gh: rc 0"; eq "$out" 7 "[L3] …stdout is the PR number only"
  eq "$(first_lines "$(cat "$F/stdin.md")" 1)" "$TOK_FIXES #98/" "[L3] the body on gh's stdin starts with the fixes line"
  hasline "$(cat "$F/stdin.md")" "Closes #5" "[L3] …and carries the Closes line"
  has "$(cat "$GL")" "[pr] [view]" "[L3] with --closes, gh pr view is asked whether GitHub linked the issue"
  has "$(cat "$GL")" "closingIssuesReferences" "[L3] …for closingIssuesReferences"
  : > "$GL"
  out=$(prg GH_LOG="$GL" GH_STDIN="$F/stdin.md" -- 2>/dev/null)
  hasnt "$(cat "$GL")" "[pr] [view]" "[L3] without --closes there is nothing to confirm: no gh pr view"
  : > "$GL"; rm -f "$GL.cnt"
  out=$(prg GH_LOG="$GL" GH_CLOSING_JSON='[]' -- --closes 5 2>/dev/null); rc=$?
  eq "$rc" 0 "[L3] a link GitHub never reports: rc 0 (the PR exists; a retry would open a duplicate)"
  eq "$out" 7 "[L3] …stdout is still the PR number only"
  eq "$(grep -c '^ARGV: \[pr\] \[view\]' "$GL")" 10 "[L3] …the read was tried 10 times, with no wait (OPEN_PR_LINK_WAIT_S=0)"
  : > "$GL"; rm -f "$GL.cnt"
  out=$(prg GH_LOG="$GL" GH_PRVIEW_FAIL=1 -- --closes 5 2>/dev/null); rc=$?
  eq "$rc" 0 "[L3] a closing-link read that fails: rc 0"; eq "$out" 7 "[L3] …stdout is still the PR number only"
}

FAMILIES="fam_closes fam_fixes fam_gh_links"

echo "== the real core =="
PL0="$TMP/plugin-real"; mk_plugin_copy "$PL0"
[ -f "$PL0/scripts/open_pr.py" ] && ok "instrument: the plugin copy has the core" || bad "instrument: the core is missing from the copy"
for f in $FAMILIES; do echo "-- $f"; "$f" "$PL0"; done

echo "== planted breaks: each family must go red on a core with one break =="
BRK() {  # BRK <label> <family> <needle> <old> <new>
  local d="$TMP/break-$1"; mk_plugin_copy "$d"
  mutate "$d/scripts/open_pr.py" "$4" "$5" && expect_red "$1" "$2" "$d" "$3"
}
BRK crash-without-digits fam_fixes '[L2] a --fixes with no digit' '    fix_block = "".join("%s #%s\n" % (tk["fixes_line"], n) for n in fix_nums)' '    if fixes and not fix_nums:
        raise ValueError("no digit")
    fix_block = "".join("%s #%s\n" % (tk["fixes_line"], n) for n in fix_nums)'
BRK closes-word-changed fam_closes "[L1] --closes 123: the first line" '(cfg["pr"]["closing"]["keyword"], n)' '("Close", n)'
BRK closes-not-deduplicated fam_closes "[L1] a repeated number is listed once" '        if n not in seen_c:
            seen_c.add(n)
' '        if True:
'
BRK fixes-word-changed fam_fixes "[L2] --fixes 98: the first line" '(tk["fixes_line"], n)' '("Va cho", n)'
BRK fixes-not-deduplicated fam_fixes "[L2] …exactly two lines" '        if n not in seen:
            seen.add(n)
' '        if True:
'
BRK links-swapped fam_closes "[L1] …the fixes line comes first" '% (fix_block, close_block, tk["summary_heading"],' '% (close_block, fix_block, tk["summary_heading"],'
BRK closing-read-skipped fam_gh_links "[L3] with --closes, gh pr view is asked" '    if m and closes and (closing or {}).get("verify", True):' '    if False:'
PLC="$TMP/break-none"; mk_plugin_copy "$PLC"
QN=0; okdef=$(declare -f ok); baddef=$(declare -f bad); sp=$PASS; sf=$FAIL
ok() { :; }; bad() { QN=$((QN+1)); }
for f in $FAMILIES; do "$f" "$PLC" >/dev/null 2>&1; done
eval "$okdef"; eval "$baddef"; PASS=$sp; FAIL=$sf
eq "$QN" 0 "control: an unbroken copy passes every family (no failed check)"

echo; summary
