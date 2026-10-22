#!/bin/bash
# =============================================================================
# Gate: commit discipline (plugins/vibemaestro-sdlc/gates/commit_discipline.py), the families of the hub's commit-discipline test
# =============================================================================
# Run: bash tests/test-gates-commit.sh
#
# Families, each run on a copy of the real plugin and then on copies with ONE planted break that must turn it red:
#   [T] thresholds: just under and just over for the commit count and for the touches of one file; counted per file, not in total
#   [X] the exemption line: its token, its length, and every place a line does not count as a statement (fences, comments,
#       quotes, indentation, placeholders); it waives only the two thresholds
#   [S] side branches: a merge that keeps the branch's commits is red, a squash or a fast-forward is green, a catch-up merge of main
#       is not counted, a stale BASE and a self-merge of the PR branch are named
#   [W] marks that mean "not folded": wip, fixup!, squash!, amend! in the places a mark counts and not where it does not
#   [R] review rounds: one round in one commit; the pattern is a config value matched without case and accents
#   [H] the red message: three files then dots, the exemption never waives the other two measures
#   [A] arguments: usage rc 64, limits from flags and from config, --json fields
#   [I] cannot conclude (rc 2): bad refs, an empty range, an internal fault is not a traceback rc 1
#   [P] the routes: a push of the PR branch to a remote and the gate run on the remote refs
#   [C] config: limits and token from .vibemaestro/sdlc.json, an invalid file is rc 65 naming the key
# Real git in throw-away repos, no gh, no network, no sleep.
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
# shellcheck source=fixtures/gates.sh
. "$HERE/fixtures/gates.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"

# cd_gate <plugin> <repo> <base> <head> [args...] — run the gate of that plugin copy
cd_gate() {
  local p=$1 r=$2 b=$3 h=$4; shift 4
  run_gate python3 "$p/gates/commit_discipline.py" --cwd "$r" "$b" "$h" "$@"
}
# a feature repo: `mk_feat <name>` prints the path, checked out on `feat`
mk_feat() { local r; r=$(mk_repo "$1"); G -C "$r" checkout -qb feat; echo "$r"; }
body() { printf '%b' "$2" > "$TMP/body-$1.md"; echo "$TMP/body-$1.md"; }

[ -f "$PLUGIN/gates/commit_discipline.py" ] && ok "the gate exists" || { bad "the gate is missing"; summary; exit 1; }

fam_thresholds() {
  local p=$1 r i
  r=$(mk_feat small); mkdir -p "$r/a"; echo 1 > "$r/a/x"; echo 2 > "$r/a/y"; echo 3 > "$r/a/z"; G -C "$r" add a; G -C "$r" commit -qm "feat(a): add a"
  cd_gate "$p" "$r" main feat; want 0 "[T] a small PR (1 task, 1 commit, 3 files) is not blocked" pass
  r=$(mk_feat n15); for i in $(seq 1 15); do cm "$r" "f$i.txt" "feat: task $i"; done
  cd_gate "$p" "$r" main feat; want 0 "[T] 15 commits pass (just at the limit)" "15 non-merge"
  cm "$r" f16.txt "feat: task 16"
  cd_gate "$p" "$r" main feat; want 1 "[T] 16 commits are red (just over)" "16 non-merge commits (limit 15)"
  r=$(mk_feat t4); for i in 1 2 3 4; do cm "$r" hot.txt "feat: pass $i"; done
  cd_gate "$p" "$r" main feat; want 0 "[T] one file in 4 commits passes"
  cm "$r" hot.txt "feat: pass 5"
  cd_gate "$p" "$r" main feat; want 1 "[T] one file in 5 commits is red" "hot.txt x5"
  r=$(mk_feat t4b); for i in 1 2 3 4 5; do cm "$r" "g$i.txt" "feat: g$i"; done
  cd_gate "$p" "$r" main feat; want 0 "[T] 5 commits on 5 different files pass (counted per file, not in total)"
  r=$(mk_feat tmerge); cm "$r" a.txt "feat: a"; cm "$r" a.txt "feat: a2"
  G -C "$r" checkout -q main; cm "$r" a2.txt "chore: main touches a2"; G -C "$r" checkout -q feat
  G -C "$r" merge -q --no-ff -m "Merge main" main
  cd_gate "$p" "$r" main feat; want 0 "[T] a catch-up merge adds nothing to the touch count"
}

EXEMPT_OK='COMMIT EXCEPTION: rename the API then move callers then drop the old path, the order is load-bearing'
fam_exempt() {
  local p=$1 r i f
  r=$(mk_feat ex); for i in $(seq 1 16); do cm "$r" "f$i.txt" "feat: task $i"; done
  cd_gate "$p" "$r" main feat; want 1 "[X] 16 commits and no exemption: red"
  f=$(body ok "## Summary\nx\n$EXEMPT_OK\n"); cd_gate "$p" "$r" main feat --body-file "$f"; want 0 "[X] an exemption line with a real reason: green" "named exemption"
  f=$(body short 'COMMIT EXCEPTION: too short\n'); cd_gate "$p" "$r" main feat --body-file "$f"; want 1 "[X] a reason under 15 characters stays red"
  f=$(body 14 'COMMIT EXCEPTION: 12345678901234\n'); cd_gate "$p" "$r" main feat --body-file "$f"; want 1 "[X] exactly 14 characters: red (just over the line)"
  f=$(body 15 'COMMIT EXCEPTION: 123456789012345\n'); cd_gate "$p" "$r" main feat --body-file "$f"; want 0 "[X] exactly 15 characters: green (just under)"
  f=$(body fence '```\nCOMMIT EXCEPTION: rename the API then move callers then drop the old path\n```\n'); cd_gate "$p" "$r" main feat --body-file "$f"; want 1 "[X] inside a code fence: does not count"
  f=$(body tilde '~~~\nCOMMIT EXCEPTION: rename the API then move callers then drop the old path\n~~~\n'); cd_gate "$p" "$r" main feat --body-file "$f"; want 1 "[X] inside a tilde fence: does not count"
  f=$(body mid 'See COMMIT EXCEPTION: rename the API then move callers then drop the old path\n'); cd_gate "$p" "$r" main feat --body-file "$f"; want 1 "[X] not at the start of a line: does not count"
  f=$(body ph1 'COMMIT EXCEPTION: <reason of at least 15 characters>\n'); cd_gate "$p" "$r" main feat --body-file "$f"; want 1 "[X] the gate's own hint (a <...> placeholder): does not count"
  f=$(body ph2 'COMMIT EXCEPTION: <fill in the reason here to make it long>\n'); cd_gate "$p" "$r" main feat --body-file "$f"; want 1 "[X] a placeholder longer than 15 characters: does not count"
  f=$(body html '<!--\nCOMMIT EXCEPTION: fill in a reason longer than fifteen characters here\n-->\n'); cd_gate "$p" "$r" main feat --body-file "$f"; want 1 "[X] inside a multi-line HTML comment: does not count"
  f=$(body html1 '<!-- COMMIT EXCEPTION: fill in a reason longer than fifteen characters here -->\n'); cd_gate "$p" "$r" main feat --body-file "$f"; want 1 "[X] inside a one-line HTML comment: does not count"
  f=$(body bq '> COMMIT EXCEPTION: rename the API then move callers then drop the old path\n'); cd_gate "$p" "$r" main feat --body-file "$f"; want 1 "[X] in a blockquote: does not count"
  f=$(body ind4 '    COMMIT EXCEPTION: rename the API then move callers then drop the old path\n'); cd_gate "$p" "$r" main feat --body-file "$f"; want 1 "[X] indented by 4 spaces (a markdown code block): does not count"
  f=$(body tab '\tCOMMIT EXCEPTION: rename the API then move callers then drop the old path\n'); cd_gate "$p" "$r" main feat --body-file "$f"; want 1 "[X] indented by a tab: does not count"
  f=$(body ind3 '   COMMIT EXCEPTION: rename the API then move callers then drop the old path\n'); cd_gate "$p" "$r" main feat --body-file "$f"; want 0 "[X] indented by 3 spaces is still a paragraph: counts (positive control)"
  # the FIRST exemption line decides, as at the hub's copy; a valid line below a placeholder or short one does not count
  f=$(body ph-then-ok 'COMMIT EXCEPTION: <reason of at least 15 characters>\n'"$EXEMPT_OK"'\n'); cd_gate "$p" "$r" main feat --body-file "$f"; want 1 "[X] the gate's own hint left above a valid line: the first line decides, red"
  f=$(body short-then-ok 'COMMIT EXCEPTION: too short\n'"$EXEMPT_OK"'\n'); cd_gate "$p" "$r" main feat --body-file "$f"; want 1 "[X] a too-short line above a valid line: the first line decides, red"
  f=$(body blank-then-ok 'COMMIT EXCEPTION:   \n'"$EXEMPT_OK"'\n'); cd_gate "$p" "$r" main feat --body-file "$f"; want 1 "[X] a token and only spaces above a valid line: a blank reason, red"
  f=$(body bare-then-ok 'COMMIT EXCEPTION:\n'"$EXEMPT_OK"'\n'); cd_gate "$p" "$r" main feat --body-file "$f"; want 0 "[X] a bare token line is skipped, as at the hub: the valid line below counts" "named exemption"
  # a CRLF body: --body-file is read in text mode (universal newlines), so `\r\n` is `\n` and a bare token line is skipped as above
  f=$(body crlf-bare-then-ok 'COMMIT EXCEPTION:\r\n'"$EXEMPT_OK"'\r\n'); cd_gate "$p" "$r" main feat --body-file "$f"; want 0 "[X] a bare token line in a CRLF body file is skipped too (the file is read with universal newlines)" "named exemption"
  f=$(body crlf-ok "$EXEMPT_OK"'\r\n'); cd_gate "$p" "$r" main feat --body-file "$f"; want 0 "[X] a valid line in a CRLF body counts (positive control)" "named exemption"
  # review round 1: the red output says that the first line was rejected and why a line below does not count
  f=$(body ph-then-ok2 'COMMIT EXCEPTION: <reason of at least 15 characters>\n'"$EXEMPT_OK"'\n'); cd_gate "$p" "$r" main feat --body-file "$f"; want 1 "[X] a rejected first line: the output names it" "only the first such line counts"
  f=$(body none-at-all 'no token here\n'); cd_gate "$p" "$r" main feat --body-file "$f"
  has_q "only the first such line counts" && bad "[X] no exemption line at all, yet the note about a rejected first line" || ok "[X] no exemption line: no note about a rejected one"
  f=$(body ok-then-ph "$EXEMPT_OK"'\nCOMMIT EXCEPTION: <reason of at least 15 characters>\n'); cd_gate "$p" "$r" main feat --body-file "$f"; want 0 "[X] a valid first line with a placeholder below: green (positive control)" "named exemption"
  f=$(body fence-then-ok '```\nCOMMIT EXCEPTION: short\n```\n'"$EXEMPT_OK"'\n'); cd_gate "$p" "$r" main feat --body-file "$f"; want 0 "[X] a short line inside a fence is not the first line: the valid line counts" "named exemption"
  f=$(body short-then-short 'COMMIT EXCEPTION: too short\nCOMMIT EXCEPTION: still short\n'); cd_gate "$p" "$r" main feat --body-file "$f"; want 1 "[X] two lines, neither valid: red"
  f=$(body ph3 'COMMIT EXCEPTION: rename <API> then move callers then drop the old path\n'); cd_gate "$p" "$r" main feat --body-file "$f"; want 0 "[X] a real reason with one word in <...> still counts (not every angle bracket is a placeholder)"
  f=$(body after 'x\n```\ncode\n```\nCOMMIT EXCEPTION: rename the API then move callers then drop the old path\n'); cd_gate "$p" "$r" main feat --body-file "$f"; want 0 "[X] a line after a closed fence counts (positive control: the fence ends)"
  f=$(body after2 '<!-- note -->\nCOMMIT EXCEPTION: rename the API then move callers then drop the old path\n'); cd_gate "$p" "$r" main feat --body-file "$f"; want 0 "[X] a line after a closed comment counts (positive control)"
  f=$(body hb '<!-- hidden by GitHub --> COMMIT EXCEPTION: rename the API then move callers then drop the old path\n'); cd_gate "$p" "$r" main feat --body-file "$f"; want 1 "[X] a line that starts with a comment is an HTML block: hidden, does not count"
  f=$(body ls $'note\xe2\x80\xa8COMMIT EXCEPTION: rename the API then move callers then drop the old path\n'); cd_gate "$p" "$r" main feat --body-file "$f"; want 1 "[X] U+2028 is not a line break: a token after it is not at the start of a line"
  f=$(body cs 'a `<!--` in a code span\nCOMMIT EXCEPTION: rename the API then move callers then drop the old path\nand a closing --> later\n'); cd_gate "$p" "$r" main feat --body-file "$f"; want 0 "[X] a comment opener inside a code span hides nothing (positive control)"
  f=$(body mc 'x <!-- inline\ncomment --> y\nCOMMIT EXCEPTION: rename the API then move callers then drop the old path\n'); cd_gate "$p" "$r" main feat --body-file "$f"; want 0 "[X] a closed comment in the middle of a paragraph hides only itself"
  f=$(body ib 'x <!-- COMMIT EXCEPTION: rename the API then move callers then drop the old path -->\n'); cd_gate "$p" "$r" main feat --body-file "$f"; want 1 "[X] a token inside a mid-line comment does not count"
  cd_gate "$p" "$r" main feat --body-file "$TMP/no-such-file.md"; want 64 "[X] an unreadable --body-file is rc 64 (not skipped silently)"
  r=$(mk_feat exw); cm "$r" a.txt "wip: unfinished"
  f=$(body ok2 "$EXEMPT_OK\n"); cd_gate "$p" "$r" main feat --body-file "$f"; want 1 "[X] wip plus an exemption stays red" unfolded
}

mk_sub() {  # mk_sub <name> <n> — on intent/x, side branch wt/p1 with n commits
  local r; r=$(mk_repo "$1"); G -C "$r" checkout -qb intent/x; cm "$r" intent.txt "docs(kb): intent"
  G -C "$r" checkout -qb wt/p1
  for i in $(seq 1 "$2"); do cm "$r" "p$i.txt" "feat(p): step $i"; done
  G -C "$r" checkout -q intent/x; echo "$r"
}
fam_side() {
  local p=$1 r r4 r2 i f
  r=$(mk_sub subm 3); G -C "$r" merge -q --no-ff -m "Merge wt/p1" wt/p1
  cd_gate "$p" "$r" main intent/x; want 1 "[S] merge --no-ff that keeps 3 side commits: red" side-merge
  has_q ', ...' && bad "[S] one side merge printed dots" || ok "[S] one side merge: no dots"
  r4=$(mk_sub subm4 1); for i in 2 3 4; do G -C "$r4" checkout -q -b "wt/q$i" main; cm "$r4" "q$i.txt" "feat(q): item $i"; G -C "$r4" checkout -q intent/x; done
  G -C "$r4" merge -q --no-ff -m "Merge wt/p1" wt/p1; for i in 2 3 4; do G -C "$r4" merge -q --no-ff -m "Merge wt/q$i" "wt/q$i"; done
  cd_gate "$p" "$r4" main intent/x; want 1 "[S] four side merges: red" "4 side-branch merges"
  has_q ', ...' && ok "[S] four side merges: three shas then dots" || bad "[S] four side merges without dots: $OUT"
  f=$(body ok3 "$EXEMPT_OK\n"); cd_gate "$p" "$r" main intent/x --body-file "$f"; want 1 "[S] side merge plus exemption stays red (the exemption waives two thresholds only)" side-merge
  r=$(mk_sub subs 3); G -C "$r" merge -q --squash wt/p1 >/dev/null; G -C "$r" commit -qm "feat(p): item p"
  cd_gate "$p" "$r" main intent/x; want 0 "[S] merge --squash into one commit: green" "2 non-merge"
  r=$(mk_sub sub1 1); G -C "$r" merge -q --no-ff -m "Merge wt/p1" wt/p1
  cd_gate "$p" "$r" main intent/x; want 1 "[S] a one-commit side branch merged with a merge commit: still red" side-merge
  r=$(mk_sub subf 1); G -C "$r" merge -q --ff-only wt/p1
  cd_gate "$p" "$r" main intent/x; want 0 "[S] fast-forward of one commit: green"
  r=$(mk_feat cu); cm "$r" feat.txt "feat: my work"
  G -C "$r" checkout -q main; for i in 1 2 3 4 5 6 7 8; do cm "$r" "m$i.txt" "chore: main $i"; done
  G -C "$r" checkout -q feat; G -C "$r" merge -q --no-ff -m "Merge branch 'main' into feat" main
  cd_gate "$p" "$r" main feat --json
  if [ "$RC" -eq 0 ] && [ "$(jfield '[d["commits"], d["merges_total"], len(d["side_merges"])]')" = "[1, 1, 0]" ]; then ok "[S] catch-up merge of main: 1 own commit, 1 merge, 0 side merges"; else bad "[S] catch-up counted wrong (rc $RC): $OUT"; fi
  G -C "$r" checkout -q main; cm "$r" m9.txt "chore: main 9"; G -C "$r" checkout -q feat
  cd_gate "$p" "$r" main feat; want 0 "[S] main moved on after the catch-up: still green (judged against the current tip)"
  r2=$(mk_feat stale); cm "$r2" a.txt "feat: a"
  G -C "$r2" checkout -q main; cm "$r2" m1.txt "chore: m1"; G -C "$r2" branch stale main~1; G -C "$r2" checkout -q feat; G -C "$r2" merge -q --no-ff -m "Merge main" main
  cd_gate "$p" "$r2" stale feat; want 1 "[S] BASE older than main plus a catch-up merge: red (the known behaviour)" side-merge
  has_q 'older than main' && has_q 'fetch' && has_q 'origin/main' && ok "[S] …the message names the stale BASE and the fix (fetch, origin/main)" || bad "[S] the stale-BASE hint is missing: $OUT"
  cd_gate "$p" "$r2" main feat; want 0 "[S] the same branch with BASE = current main: green"
  r2=$(mk_feat pull); cm "$r2" a.txt "feat: a"; G -C "$r2" branch other feat
  G -C "$r2" checkout -q other; cm "$r2" b.txt "feat: b"; G -C "$r2" checkout -q feat; cm "$r2" c.txt "feat: c"; G -C "$r2" merge -q --no-ff -m "Merge branch 'other'" other
  cd_gate "$p" "$r2" main feat; want 1 "[S] git pull merging the PR branch into itself: red" side-merge
  has_q 'git pull' && has_q 'rebase' && ok "[S] …the message names git pull and rebase" || bad "[S] the git pull hint is missing: $OUT"
  G -C "$r" checkout -qb other main~1; cm "$r" other.txt "feat: stray branch"; G -C "$r" checkout -q feat; G -C "$r" merge -q --no-ff -m "Merge other" other
  cd_gate "$p" "$r" main feat; want 1 "[S] a merge of a branch that is not in main: red (not every merge is forgiven)" side-merge
}

fam_marks() {
  local p=$1 r
  r=$(mk_feat w1); cm "$r" a.txt "wip: unfinished"; cd_gate "$p" "$r" main feat; want 1 "[W] subject 'wip: ...': red" unfolded
  r=$(mk_feat w2); cm "$r" a.txt "fixup! feat: a"; cd_gate "$p" "$r" main feat; want 1 "[W] 'fixup!': red"
  r=$(mk_feat w3); cm "$r" a.txt "squash! feat: a"; cd_gate "$p" "$r" main feat; want 1 "[W] 'squash!': red"
  r=$(mk_feat w4); cm "$r" a.txt "feat: wipe the old cache"; cm "$r" b.txt "docs: swipe gesture"; cd_gate "$p" "$r" main feat; want 0 "[W] 'wipe' and 'swipe' are not 'wip' (false-positive control)"
  wipcase() { local x; x=$(mk_feat wip); cm "$x" a.txt "$2"; cd_gate "$p" "$x" main feat; want "$1" "[W] subject «$2»"; }
  wipcase 0 "test(commit-discipline): add a case about wip with an exemption"
  wipcase 0 "feat(wip): a"
  wipcase 0 "docs: explain the WIP mark in the rule"
  wipcase 1 "wip in progress"
  wipcase 1 "WIP: in progress"
  wipcase 1 "[WIP] feat: a"
  wipcase 1 "(wip) feat: a"
  wipcase 1 "feat: [wip] a"
  wipcase 1 "feat(a): wip in progress"
  wipcase 1 "amend! feat: a"
  wipcase 1 "fixup! feat: a"
}

fam_rounds() {
  local p=$1 r
  r=$(mk_feat w5); cm "$r" a.txt "feat: a"; cm "$r" a.txt "fix: address review round 1"; cm "$r" b.txt "fix: address review round 2"
  cd_gate "$p" "$r" main feat; want 0 "[R] one commit per round (round 1, round 2): green"
  cm "$r" c.txt "docs: patch round 2 too"
  cd_gate "$p" "$r" main feat; want 1 "[R] round 2 split over two commits: red" "round 2 x2"
  local f; f=$(body ok4 "$EXEMPT_OK\n"); cd_gate "$p" "$r" main feat --body-file "$f"; want 1 "[R] a split round plus an exemption stays red" "round 2 x2"
  roundcase() {  # roundcase <rc> <label> <first subject> <second subject> [text]
    local x; x=$(mk_feat rd); cm "$x" a.txt "feat: a"; cm "$x" a.txt "$3"; cm "$x" b.txt "$4"
    cd_gate "$p" "$x" main feat; want "$1" "[R] $2" "${5:-}"
  }
  roundcase 1 "ROUND 1 in upper case, split" "fix: ROUND 1 a" "fix: ROUND 1 b" "round 1 x2"
  roundcase 1 "round1 with no space, split" "fix: round1 a" "fix: round1 b" "round 1 x2"
  roundcase 0 "a round-2 commit that mentions round 1 is not counted in round 1" "fix: address review round 1" "fix: address round 2 and repeat the round 1 error"
  roundcase 0 "one round number repeated in the same subject is not counted twice" "fix: round 1, repeat round 1" "fix: round 2 done"
  roundcase 0 "the word 'around' is not a round" "fix: around 1 corner" "fix: around 1 more"
  # a repo that writes the word in another language and with accents sets the pattern; the subject is lower-cased and stripped of accents first
  local x; x=$(mk_feat rdcfg); put_cfg "$x" '{"commits": {"round_pattern": "\\bvong\\s*(\\d+)\\b"}}'
  cm "$x" a.txt "feat: a"; cm "$x" a.txt "fix: v$(printf '\303\262')ng 1 first"; cm "$x" b.txt "fix: V$(printf '\303\222')NG 1 second"
  cd_gate "$p" "$x" main feat; want 1 "[R] a configured pattern: the word with accents and in upper case is one round, split: red" "round 1 x2"
  x=$(mk_feat rdnfd); put_cfg "$x" '{"commits": {"round_pattern": "\\bvong\\s*(\\d+)\\b"}}'
  cm "$x" a.txt "feat: a"; cm "$x" a.txt "fix: vo$(printf '\314\200')ng 2 first"; cm "$x" b.txt "fix: vong 2 second"
  cd_gate "$p" "$x" main feat; want 1 "[R] the same word decomposed (o plus a loose accent) matches the unaccented one: red" "round 2 x2"
  x=$(mk_feat rdoff); put_cfg "$x" '{"commits": {"round_pattern": "\\bvong\\s*(\\d+)\\b"}}'
  cm "$x" a.txt "feat: a"; cm "$x" a.txt "fix: round 1 first"; cm "$x" b.txt "fix: round 1 second"
  cd_gate "$p" "$x" main feat; want 0 "[R] with the pattern set to another word the English 'round 1' is not a round: green"
  # NFD does not decompose the Vietnamese d with stroke, so the accent-free `dot` never matched "Dot 2" written with it
  x=$(mk_feat rddj); put_cfg "$x" '{"commits": {"round_pattern": "\\bdot\\s*(\\d+)\\b"}}'
  cm "$x" a.txt "feat: a"; cm "$x" a.txt "fix: $(printf '\304\220\341\273\243')t 2 first"; cm "$x" b.txt "fix: $(printf '\304\221\341\273\243')t 2 second"
  cd_gate "$p" "$x" main feat; want 1 "[R] the d with stroke, upper and lower case, is d: one round split, red" "round 2 x2"
}

fam_report() {
  local p=$1 r i f
  r=$(mk_feat hl); for i in 1 2 3 4 5; do for f in x y z; do cm "$r" "$f.txt" "feat: $f pass $i"; done; done
  cd_gate "$p" "$r" main feat --max-commits 99; want 1 "[H] three files at x5" "x.txt x5, y.txt x5, z.txt x5"
  has_q ', ...' && bad "[H] exactly three files printed dots" || ok "[H] exactly three files: no dots"
  for i in 1 2 3 4 5; do cm "$r" w.txt "feat: w pass $i"; done
  cd_gate "$p" "$r" main feat --max-commits 99; want 1 "[H] four hot files: dots added" ", ..."
}

fam_args() {
  local p=$1 r i f
  r=$(mk_feat pr); for i in 1 2 3; do cm "$r" h.txt "feat: pass $i"; done
  cd_gate "$p" "$r" main feat --bogus; want 64 "[A] an unknown flag is rc 64 (not mixed with 2, could not conclude)"
  cd_gate "$p" "$r" main feat --max-commits 2; want 1 "[A] --max-commits 2 with 3 commits: red" "3 non-merge commits (limit 2)"
  cd_gate "$p" "$r" main feat --max-commits 3; want 0 "[A] --max-commits 3 with 3 commits: green"
  cd_gate "$p" "$r" main feat --max-touches 2; want 1 "[A] --max-touches 2 with a file x3: red" "h.txt x3"
  cd_gate "$p" "$r" main feat --max-touches 3; want 0 "[A] --max-touches 3 with a file x3: green"
  r=$(mk_feat js); for i in 1 2 3 4 5; do cm "$r" hot.txt "feat: pass $i"; done; for i in 1 2 3; do cm "$r" "cold$i.txt" "feat: cold $i"; done
  cd_gate "$p" "$r" main feat --json
  [ "$(jfield 'd["file_touch"]')" = '{"hot.txt": 5}' ] && ok "[A] --json: file_touch holds only files over the limit" || bad "[A] --json file_touch: $(jfield 'd["file_touch"]')"
  [ "$(jfield 'd["exempt"]')" = 'null' ] && ok "[A] --json: exempt is null with no exemption line" || bad "[A] --json exempt: $(jfield 'd["exempt"]')"
  r=$(mk_feat js3); cm "$r" a.txt "feat: a"; f=$(body ok5 "$EXEMPT_OK\n")
  cd_gate "$p" "$r" main feat --json --body-file "$f"; [ "$(jfield 'd["exempt"]')" = 'null' ] && ok "[A] --json: an exemption line that nothing needs leaves exempt null" || bad "[A] --json exempt unused: $(jfield 'd["exempt"]')"
  r=$(mk_feat js2); for i in $(seq 1 16); do cm "$r" "f$i.txt" "feat: task $i"; done
  cd_gate "$p" "$r" main feat --json --body-file "$f"
  printf '%s' "$(jfield 'd["exempt"]')" | grep -qF 'load-bearing' && ok "[A] --json: exempt carries the reason when it was used" || bad "[A] --json exempt used: $(jfield 'd["exempt"]')"
  [ "$(jfield 'd["rc"]')" = 0 ] && ok "[A] --json: rc 0 when waived" || bad "[A] --json rc: $(jfield 'd["rc"]')"
  cd_gate "$p" "$r" main feat --json
  if printf '%s' "$OUT" | python3 -c '
import json,sys
d=json.load(sys.stdin)
need={"commits","merges_total","side_merges","max_touch","markers","round_split","rc","found","file_touch","exempt"}
sys.exit(0 if need <= set(d) and d["rc"]==1 and d["commits"]==16 else 1)'; then ok "[A] --json has every field for another machine to read"; else bad "[A] --json misses fields: $OUT"; fi
}

fam_infra() {
  local p=$1 r R2 i
  r=$(mk_feat e1); cm "$r" a.txt "feat: a"
  cd_gate "$p" "$r" main no-such-ref; want 2 "[I] a head that does not read: rc 2"
  cd_gate "$p" "$r" feat feat; want 2 "[I] an empty range (a merged branch, or a wrong ref): rc 2, not green"
  cd_gate "$p" "$r" no-such-ref feat; want 2 "[I] a base that does not read: rc 2"
  R2=$(mk_feat e2); for i in $(seq 1 16); do cm "$R2" "f$i.txt" "feat: task é $i"; done
  local f; f=$(body ok6 "COMMIT EXCEPTION: caf$(printf '\303\251') rename then move then drop, order is load-bearing\n")
  RC=0; OUT=$(cenv PYTHONIOENCODING=ascii python3 "$p/gates/commit_discipline.py" --cwd "$R2" --body-file "$f" main feat 2>&1) || RC=$?
  want 2 "[I] a fault of the gate itself (stdout forced to ASCII while the line has an accent): rc 2, never rc 1 read as red" "could not conclude"
  has_q 'Traceback' && bad "[I] an internal fault printed a traceback" || ok "[I] an internal fault prints no traceback"
  has_q 'load-bearing' && bad "[I] the fault message repeats the input (the PR text)" || ok "[I] …and the message names only the type of the fault, never the input"
}

fam_routes() {
  local p=$1 W
  W=$(mk_origin sbx); G -C "$W" checkout -qb intent/y; cm "$W" kb-intent.txt "docs(kb): intent"
  G -C "$W" checkout -qb wt/p1; cm "$W" p1.txt "feat(p): step 1"; cm "$W" p2.txt "feat(p): step 2"
  G -C "$W" checkout -q intent/y; G -C "$W" merge -q --no-ff -m "Merge wt/p1" wt/p1; G -C "$W" push -q origin intent/y; G -C "$W" fetch -q origin
  cd_gate "$p" "$W" origin/main origin/intent/y; want 1 "[P] a session that pushes straight after merge --no-ff: red on the remote refs" side-merge
  W=$(mk_origin sbx2); G -C "$W" checkout -qb intent/y; cm "$W" kb-intent.txt "docs(kb): intent"
  G -C "$W" checkout -qb wt/p1; cm "$W" p1.txt "feat(p): step 1"; cm "$W" p2.txt "feat(p): step 2"
  G -C "$W" checkout -q intent/y; G -C "$W" merge -q --squash wt/p1 >/dev/null; G -C "$W" commit -qm "feat(p): item p"; G -C "$W" push -q origin intent/y; G -C "$W" fetch -q origin
  cd_gate "$p" "$W" origin/main origin/intent/y; want 0 "[P] the same after merge --squash: green" "2 non-merge"
  W=$(mk_origin five); G -C "$W" checkout -qb intent/z; for i in 1 2 3 4 5; do cm "$W" spec.md "docs(kb): spec pass $i"; done; G -C "$W" push -q origin intent/z; G -C "$W" fetch -q origin
  cd_gate "$p" "$W" origin/main origin/intent/z; want 1 "[P] five commits on one file pushed to the remote: red" "spec.md x5"
}

fam_config() {
  local p=$1 r i f
  r=$(mk_feat c1); for i in $(seq 1 4); do cm "$r" "f$i.txt" "feat: task $i"; done
  put_cfg "$r" '{"commits": {"max_per_pr": 3}}'
  cd_gate "$p" "$r" main feat; want 1 "[C] commits.max_per_pr 3 from the config with 4 commits: red" "(limit 3)"
  cd_gate "$p" "$r" main feat --max-commits 4; want 0 "[C] a flag overrides the config: green"
  put_cfg "$r" '{"commits": {"max_per_pr": 3, "max_touches": 1}}'; cm "$r" f1.txt "feat: again"
  cd_gate "$p" "$r" main feat --max-commits 9; want 1 "[C] commits.max_touches 1 from the config: red" "f1.txt x2"
  r=$(mk_feat c2); for i in $(seq 1 16); do cm "$r" "f$i.txt" "feat: task $i"; done
  put_cfg "$r" '{"tokens": {"commit_exception": "NGOAI LE:"}}'
  f=$(body tok1 "COMMIT EXCEPTION: rename the API then move callers then drop the old path\n"); cd_gate "$p" "$r" main feat --body-file "$f"; want 1 "[C] the configured token replaces the default: the old literal no longer waives"
  f=$(body tok2 "NGOAI LE: rename the API then move callers then drop the old path\n"); cd_gate "$p" "$r" main feat --body-file "$f"; want 0 "[C] …and the configured one does"
  put_cfg "$r" '{"commits": {"max_per_pr": 0}}'; cd_gate "$p" "$r" main feat; want 65 "[C] an invalid config is rc 65" commits.max_per_pr
  put_cfg "$r" '{"commits": {"round_pattern": "round"}}'; cd_gate "$p" "$r" main feat; want 65 "[C] a round pattern without a group is rc 65" commits.round_pattern
  # a pattern that can never match the normalised subject (upper case, an accent, the d with stroke) is warned about; the
  # gate still runs (schema 1 accepted the pattern, so it is not rc 65)
  put_cfg "$r" '{"commits": {"round_pattern": "\\bRound\\s*(\\d+)", "max_per_pr": 99}}'; cd_gate "$p" "$r" main feat; want 0 "[C] a round pattern in upper case: a warning, the gate still runs" "WARNING commits.round_pattern can never match"
  put_cfg "$r" "{\"commits\": {\"round_pattern\": \"\\\\b$(printf '\304\221\341\273\243')t\\\\s*(\\\\d+)\", \"max_per_pr\": 99}}"; cd_gate "$p" "$r" main feat; want 0 "[C] a round pattern with accents: a warning, the gate still runs" "can never match"
  put_cfg "$r" '{"commits": {"round_pattern": "(?i)\\bRound\\s*(\\d+)", "max_per_pr": 99}}'; cd_gate "$p" "$r" main feat; want 0 "[C] …control: upper case under (?i) can match: no warning"; has_q "can never match" && bad "[C] …a warning for a pattern that can match" || ok "[C] …and no warning"
  put_cfg "$r" '{"pr": {"draft": 1}}'; cd_gate "$p" "$r" main feat; want 65 "[C] a wrong-typed key is rc 65" pr.draft
  # the base-ref rule: the PR's own commit raises the limit; judged by the base it stays red
  r=$(mk_repo trust); commit_cfg "$r" '{"commits": {"max_per_pr": 3, "max_touches": 2}}' "base: config"; G -C "$r" branch base
  G -C "$r" checkout -qb pr; for i in 1 2 3 4; do cm "$r" "f$i.txt" "feat: task $i"; done
  commit_cfg "$r" '{"commits": {"max_per_pr": 50, "max_touches": 50}}' "feat: relax the gate in the same PR"
  cd_gate "$p" "$r" base pr --config-ref base; want 1 "[C] a PR that raises commits.max_per_pr in its own config is still red under --config-ref base" "(limit 3)"
  cd_gate "$p" "$r" base pr; want 0 "[C] …control: without the ref the PR's own config applies: green"
  r2=$(mk_repo trust2); commit_cfg "$r2" '{"commits": {"max_touches": 2}}' "base: config"; G -C "$r2" branch base
  G -C "$r2" checkout -qb pr; for i in 1 2 3; do cm "$r2" hot.txt "feat: pass $i"; done
  commit_cfg "$r2" '{"commits": {"max_touches": 9}}' "feat: relax max_touches"
  cd_gate "$p" "$r2" base pr --config-ref base; want 1 "[C] …the same for commits.max_touches" "hot.txt x3"
  r2=$(mk_repo trust3); G -C "$r2" branch base; G -C "$r2" checkout -qb pr; for i in 1 2 3 4 5 6; do cm "$r2" "f$i.txt" "feat: task $i"; done
  put_cfg "$r2" '{"commits": {"max_per_pr": 3}}'
  cd_gate "$p" "$r2" base pr --config-ref base; want 0 "[C] a base with no config file means the defaults (15): green"
  cd_gate "$p" "$r2" base pr --config-ref no-such-ref; want 2 "[C] a base ref that does not read: rc 2, never green"
  r2=$(mk_repo trust4); commit_cfg "$r2" '{"commits": {"max_per_pr": 0}}' "base: invalid"; G -C "$r2" branch base; cm "$r2" a.txt "feat: a"
  cd_gate "$p" "$r2" base HEAD --config-ref base; want 65 "[C] an invalid config AT THE BASE REF is rc 65 and names the key" commits.max_per_pr
  python3 - "$p/gates/commit_discipline.py" <<'PY' && ok "[C] the gate parses as Python 3.8 and imports only the standard library" || bad "[C] the gate is not Python 3.8 or imports something else"
import ast, sys
src = open(sys.argv[1], encoding="utf-8").read()
tree = ast.parse(src, feature_version=(3, 8))
allowed = {"argparse", "json", "re", "sys", "unicodedata", "gate_common"}
imports = set()
for n in ast.walk(tree):
    if isinstance(n, ast.Import):
        imports |= {a.name.split(".")[0] for a in n.names}
    elif isinstance(n, ast.ImportFrom):
        imports.add((n.module or "").split(".")[0])
sys.exit(1 if imports - allowed else 0)
PY
}

FAMILIES="fam_thresholds fam_exempt fam_side fam_marks fam_rounds fam_report fam_args fam_infra fam_routes fam_config"
for f in $FAMILIES; do "$f" "$PLUGIN"; done

echo "== planted breaks: each turns its family red =="
CDG=commit_discipline.py
BRKG count-off-by-one fam_thresholds '[T] 16 commits are red' $CDG '    if m["commits"] > max_commits:' '    if m["commits"] > max_commits + 1:'
BRKG touch-off-by-one fam_thresholds '[T] one file in 5 commits is red' $CDG 'for f, n in m["file_touch"].items() if n > max_touches)' 'for f, n in m["file_touch"].items() if n > max_touches + 1)'
BRKG touch-counted-in-total fam_thresholds '[T] 5 commits on 5 different files pass' $CDG '        for f in set(c["files"]):
            touch[f] = touch.get(f, 0) + 1' '        for f in set(c["files"]):
            touch["all"] = touch.get("all", 0) + 1'
BRKG exemption-always fam_exempt '[X] a reason under 15 characters stays red' $CDG '    if why is None or len(PLACEHOLDER_RX.sub("", why).strip()) < MIN_REASON:' '    if why is None:'
BRKG exemption-fences-kept fam_exempt '[X] inside a code fence: does not count' $CDG 'gc.strip_fences(body or ""), re.M)' 'body or "", re.M)'
# restores 1.1.0, the first VALID line
BRKG exemption-first-valid-line fam_exempt "[X] the gate's own hint left above a valid line" $CDG '    why = first_line(body, token)
    if why is None or len(PLACEHOLDER_RX.sub("", why).strip()) < MIN_REASON:
        return None
    return why' '    for m in re.finditer(r"^ {0,3}" + re.escape(token) + r"[ \t]*(.+?)[ \t]*$", gc.strip_fences(body or ""), re.M):
        if len(PLACEHOLDER_RX.sub("", m.group(1)).strip()) >= MIN_REASON:
            return m.group(1)
    return None'
BRKG rejected-line-silent fam_exempt '[X] a rejected first line: the output names it' $CDG '            if any(w for _, _, w in found) and first_line(' '            if False and first_line('
BRKG exemption-bare-token-counted fam_exempt '[X] a bare token line is skipped' $CDG 'r"[ \t]*(.+?)[ \t]*$", gc.strip_fences(body or ""), re.M)' 'r"[ \t]*(.*?)[ \t]*$", gc.strip_fences(body or ""), re.M)'
BRKG exemption-indent fam_exempt '[X] indented by 4 spaces' $CDG '"^ {0,3}" + re.escape' '"^ *" + re.escape'
BRKG exemption-anywhere fam_exempt '[X] not at the start of a line' $CDG '"^ {0,3}" + re.escape' '"" + re.escape'
BRKG exemption-waives-all fam_exempt '[X] wip plus an exemption stays red' $CDG '"%d commits carry a wip/fixup/squash mark (%s)"
                      % (len(m["markers"]), _list([c["sha"][:7] for c in m["markers"]])), False))' '"%d commits carry a wip/fixup/squash mark (%s)"
                      % (len(m["markers"]), _list([c["sha"][:7] for c in m["markers"]])), True))'
BRKG side-merge-ignored fam_side '[S] merge --no-ff that keeps 3 side commits: red' $CDG '            if rc == 1:
                foreign.append(par)' '            if rc == 99:
                foreign.append(par)'
BRKG all-merges-red fam_side '[S] catch-up counted wrong' $CDG '            rc = gc.git(["merge-base", "--is-ancestor", par, base], cwd)[0]' '            rc = 1'
BRKG stale-base-hint-gone fam_side '[S] the stale-BASE hint is missing' $CDG 'BASE is "
                      "older than main' 'the base is "
                      "behind'
BRKG wip-anywhere fam_marks '[W] subject «feat(wip): a»' $CDG 'WIP_RX = re.compile(r"(?i)^\s*(?:[a-z][\w-]*(?:\([^)]*\))?!?:\s*)?[\[(]?\s*wip\b|' 'WIP_RX = re.compile(r"(?i)\bwip|'
BRKG fixup-dropped fam_marks "[W] 'fixup!': red" $CDG '(?:fixup|squash|amend)!' '(?:squash|amend)!'
BRKG round-case-sensitive fam_rounds '[R] ROUND 1 in upper case' $CDG '    m = rx.search(gc.sdlc_config.round_plain(subject))' '    m = rx.search(subject)'
BRKS round-accent-kept fam_rounds '[R] the same word decomposed' sdlc_config.py 'if not unicodedata.combining(ch))' 'if True)'
BRKS round-dj-kept fam_rounds '[R] the d with stroke' sdlc_config.py '.replace("\u0111", "d")' ''
BRKG round-warning-off fam_config '[C] a round pattern in upper case' $CDG '    if gc.sdlc_config.round_never_matches(cfg["commits"]["round_pattern"]):' '    if False:'
BRKG round-pattern-ignored fam_rounds '[R] a configured pattern' $CDG '    rx = re.compile(cfg["commits"]["round_pattern"])' '    rx = re.compile(r"\bround\s*(\d+)\b")'
BRKG round-last-match fam_rounds '[R] a round-2 commit that mentions round 1' $CDG '    m = rx.search(gc.sdlc_config.round_plain(subject))' '    ms = list(rx.finditer(gc.sdlc_config.round_plain(subject))); m = ms[-1] if ms else None'
BRKG dots-gone fam_report '[H] four hot files: dots added' $CDG '    return ", ".join(items[:n]) + (", ..." if len(items) > n else "")' '    return ", ".join(items[:n])'
BRKG flag-ignored fam_args '[A] --max-commits 2 with 3 commits: red' $CDG 'a.max_commits if a.max_commits is not None else cfg["commits"]["max_per_pr"]' 'cfg["commits"]["max_per_pr"]'
BRKG json-exempt-always fam_args '[A] --json exempt unused' $CDG '    m["exempt"] = why if why and any(f[2] for f in found) else None' '    m["exempt"] = why'
BRKG usage-is-two fam_args '[A] an unknown flag is rc 64' $CDG '        return gc.USAGE if e.code else 0' '        return 2 if e.code else 0'
BRKG html-block-ignored fam_exempt '[X] a line that starts with a comment' gate_common.py '        if _HTML_BLOCK.match(ln):' '        if False:'
BRKG splitlines-instead-of-newline fam_exempt '[X] U+2028 is not a line break' gate_common.py '    for ln in (body or "").split("\n"):' '    for ln in (body or "").splitlines():'
BRKG code-span-not-masked fam_exempt '[X] a comment opener inside a code span' gate_common.py '            masked = _CODE_SPAN.sub(lambda c: "".join("\n" if ch == "\n" else "\0" for ch in c.group(0)), text)' '            masked = text'
BRKG error-repr-printed fam_infra '[I] the fault message repeats the input' gate_common.py '"%s: could not conclude: internal error (%s)\n" % (name, type(e).__name__)' '"%s: could not conclude: internal error %r\n" % (name, e)'
BRKG empty-range-green fam_infra '[I] an empty range' $CDG '    if not facts["n_all"]:' '    if False:'
BRKG internal-fault-red fam_infra '[I] a fault of the gate itself' gate_common.py '        sys.stderr.write("%s: could not conclude: internal error (%s)\n" % (name, type(e).__name__))
        return INFRA' '        sys.stderr.write("%s: could not conclude: internal error (%s)\n" % (name, type(e).__name__))
        return RED'
BRKG config-limit-ignored fam_config '[C] commits.max_per_pr 3 from the config' $CDG 'cfg["commits"]["max_per_pr"],' '15,'
BRKG token-ignored fam_config '[C] the configured token replaces the default' $CDG 'cfg["tokens"]["commit_exception"], rx)' '"COMMIT EXCEPTION:", rx)'
BRKG config-error-swallowed fam_config '[C] an invalid config is rc 65' gate_common.py '        if probs:
            raise ConfigError(sdlc_config.render_problems(probs))
        return cfg' '        return cfg'
BRKG ref-config-error-swallowed fam_config '[C] an invalid config AT THE BASE' gate_common.py '    if probs:
        raise ConfigError(sdlc_config.render_problems(probs) + where)' '    if False:
        raise ConfigError(sdlc_config.render_problems(probs) + where)'
BRKG config-from-head fam_config '[C] a PR that raises commits.max_per_pr' $CDG '    cfg = gc.load_config(a.cwd, a.config_ref)' '    cfg = gc.load_config(a.cwd, None)'
BRKG bad-ref-green fam_config '[C] a base ref that does not read' gate_common.py '        raise Infra("ref `%s` does not read" % ref)
    if git(["cat-file"' '        return None
    if git(["cat-file"'

PLC="$TMP/break-none"; mk_plugin_copy "$PLC"
QN=0; okdef=$(declare -f ok); baddef=$(declare -f bad); sp=$PASS; sf=$FAIL
ok() { :; }; bad() { QN=$((QN+1)); }
for f in $FAMILIES; do "$f" "$PLC" >/dev/null 2>&1; done
eval "$okdef"; eval "$baddef"; PASS=$sp; FAIL=$sf
eq "$QN" 0 "control: an unbroken copy passes every family"

echo; summary
