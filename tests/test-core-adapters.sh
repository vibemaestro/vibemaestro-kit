#!/bin/bash
# =============================================================================
# The two adapters, intent-branch.sh and open-pr.sh, as they are today
# =============================================================================
# Run: bash tests/test-core-adapters.sh
#
# Ports the one hub test that drove an adapter (the intent-branch adapter: rc 8 "one task one commit" and `--load-bearing`),
# and covers what the hub did not test but the plugin adapters do: the option forms the commit count reads, `--no-issue`
# (tested with the issue suite), `open-pr.sh` reading `issue: N` of the intent record, `--crit`, `--fixes`, `--draft`,
# `--dry-run` needing no gh, and the exit codes of the adapters themselves (2 for a missing gh, python3 or core, 64 for bad
# arguments). Real adapters and real cores on throw-away repositories; a fake gh; no network.
# What the adapter passes to the core as repository is asserted with a stand-in core that records its arguments: `--repo <slug>`, never `--gh`.
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
# ib <cwd for the process> <args...> — intent-branch.sh with no --cwd of its own. Run from a directory that is NOT a repository
# on purpose: whatever the adapter reads, it must read from the options, not from where the process stands.
ib() { local d=$1; shift; ( cd "$d" && cenv PATH="$GHB:$PATH" bash "$PLX/scripts/intent-branch.sh" "$@" ); }
# op <cwd> <args...> — open-pr.sh from <cwd>, fake gh first in PATH.
op() { local d=$1; shift; ( cd "$d" && cenv PATH="$GHB:$PATH" ${OPENV[@]+"${OPENV[@]}"} bash "$PLX/scripts/open-pr.sh" "$@" ); }
OPENV=()
OUTSIDE=""

fam_count() {  # rc 8: one task, one commit, counted from the cut point
  PLX=$1; local W S wt wt2 wt3 wt1 wtc out rc REM0 HEAD0 N; W=$(mk_origin); S=2026-03-01-count; OUTSIDE=$(fresh)
  new_intent "$W" "$S"
  wt1=$(task_wt "$W" feat/mot "$S" 1); wt2=$(task_wt "$W" feat/hai "$S" 2); wt3=$(task_wt "$W" feat/ba "$S" 3); wtc=$(task_wt "$W" feat/co "$S" 3)
  bump_origin "$W" "$S" other.txt; git_ -C "$W" fetch -q origin   # another worker lands after the cut: the tip moved
  REM0=$(git_ -C "$W" ls-remote origin "refs/heads/intent/$S" | cut -f1)
  for N in 2 3; do
    wt=$([ "$N" = 2 ] && echo "$wt2" || echo "$wt3"); HEAD0=$(git_ -C "$wt" rev-parse HEAD)
    out=$(ib "$OUTSIDE" --cwd "$wt" integrate --intent "$S" --branch "feat/$([ "$N" = 2 ] && echo hai || echo ba)" --to origin 2>&1); rc=$?
    eq "$rc" 8 "[A1] a task branch with $N commits over the cut point: rc 8"
    eq "$(git_ -C "$wt" rev-parse HEAD)" "$HEAD0" "[A1] …the branch with $N commits is left as it was (no automatic squash)"
  done
  has "$out" "reset --soft" "[A1] …the message names the squash command (reset --soft)"; has "$out" "merge-base" "[A1] …and the point to squash to (merge-base)"
  eq "$(git_ -C "$W" ls-remote origin "refs/heads/intent/$S" | cut -f1)" "$REM0" "[A1] …origin/intent did not move"
  out=$(ib "$OUTSIDE" --cwd "$wt1" integrate --intent "$S" --branch feat/mot --to origin 2>&1); rc=$?
  eq "$rc" 0 "[A1] a 1-commit branch whose intent tip moved since the cut: rc 0 (the other worker's commit is not counted)"
  out=$(ib "$OUTSIDE" --cwd "$wtc" integrate --intent "$S" --branch feat/co --to origin --load-bearing 2>&1); rc=$?
  eq "$rc" 0 "[A1] 3 commits with --load-bearing: rc 0 (the adapter consumed the flag, the core never saw it)"
  git_ -C "$W" fetch -q origin
  has "$(git_ -C "$W" ls-tree -r --name-only "origin/intent/$S")" feat-co-3.txt "[A1] …and the work of all three commits landed"
  out=$(ib "$OUTSIDE" --cwd "$W" worker-branch --intent "$S" --name feat/lb --no-checkout --load-bearing 2>&1); rc=$?
  eq "$rc" 2 "[A1] --load-bearing on worker-branch is not consumed: the core rejects it (rc 2)"
  ib "$OUTSIDE" --cwd "$W" create-intent --slug 2026-03-01-x --no-issue --load-bearing >/dev/null 2>&1; eq "$?" 2 "[A1] …nor on create-intent (rc 2)"
  out=$(ib "$OUTSIDE" --cwd "$wt2" integrate --branch feat/hai --to origin 2>&1); rc=$?
  eq "$rc" 2 "[A1] no --intent: the adapter does not count and the core rejects the call (rc 2)"
  out=$(ib "$OUTSIDE" --cwd "$wt2" integrate --intent "$S" --to origin 2>&1); rc=$?
  eq "$rc" 8 "[A1] no --branch: the checked-out branch is counted: rc 8"
}

fam_forms() {  # the option forms the commit count reads
  PLX=$1; local W S wt2 wt1 wt1b wt1c out rc; W=$(mk_origin); S=2026-03-02-forms; OUTSIDE=$(fresh)
  new_intent "$W" "$S"
  wt2=$(task_wt "$W" feat/hai "$S" 2); wt1=$(task_wt "$W" feat/mot "$S" 1); wt1b=$(task_wt "$W" feat/mot2 "$S" 1); wt1c=$(task_wt "$W" feat/mot3 "$S" 1)
  ib "$OUTSIDE" "--cwd=$wt2" integrate "--intent=$S" "--branch=feat/hai" --to origin >/dev/null 2>&1
  eq "$?" 8 "[A2] --cwd=PATH --intent=SLUG --branch=BR (equals forms): rc 8"
  ib "$OUTSIDE" --cwd "$wt2" integrate --intent "$S" --branch feat/hai --to origin >/dev/null 2>&1
  eq "$?" 8 "[A2] the same with separate values: rc 8"
  ib "$OUTSIDE" --cwd "$W" integrate "--intent=$S" "--branch=feat/hai" --to origin >/dev/null 2>&1
  eq "$?" 8 "[A2] the count follows --branch, not the HEAD of --cwd (main tree on main): rc 8"
  ib "$OUTSIDE" --cwd "$wt1" integrate --intent "$S" --branch feat/mot --to local --intent-ref main >/dev/null 2>&1
  eq "$?" 8 "[A2] --intent-ref main moves the cut point: one task commit plus the intent commit is 2: rc 8"
  ib "$OUTSIDE" --cwd "$wt1" integrate --intent "$S" --branch feat/mot --to local "--intent-ref=main" >/dev/null 2>&1
  eq "$?" 8 "[A2] --intent-ref=main (equals form): rc 8"
  ib "$OUTSIDE" --cwd "$wt1" integrate "--intent=intent/$S" --branch feat/mot --to local >/dev/null 2>&1
  eq "$?" 0 "[A2] control: the same branch with the default cut point and --intent=intent/<slug>: rc 0"
  ib "$OUTSIDE" "--cwd=$wt1b" integrate "--intent=$S" "--branch=feat/mot2" --to origin >/dev/null 2>&1
  eq "$?" 0 "[A2] control: a 1-commit branch with the equals forms: rc 0"
}

fam_usage() {  # exit codes of intent-branch.sh itself
  PLX=$1; local W out rc; W=$(mk_origin); OUTSIDE=$(fresh)
  ib "$OUTSIDE" >/dev/null 2>&1; eq "$?" 64 "[A3] no subcommand: rc 64"
  local D; D=$(fresh); cp -r "$PLX" "$D/p"; rm -f "$D/p/scripts/intent_branch.py"
  ( cd "$OUTSIDE" && cenv PATH="$GHB:$PATH" bash "$D/p/scripts/intent-branch.sh" integrate --intent x --to origin ) >/dev/null 2>&1
  eq "$?" 2 "[A3] the core is missing next to the adapter: rc 2"
  ( cd "$OUTSIDE" && cenv PATH="$(bare_path nogh-nopy)" bash "$PLX/scripts/intent-branch.sh" integrate --intent x --to origin ) >/dev/null 2>&1
  eq "$?" 2 "[A3] python3 is not installed: rc 2"
}

# mk_intent_wt <main tree> <slug> <issue number or ""> — a linked worktree on branch intent/<slug> holding the record
mk_intent_wt() {
  local w; git_ -C "$1" worktree add -q -b "intent/$2" "$1/../iw-$2" main; w=$(cd "$1/../iw-$2" && pwd -P)
  mkdir -p "$w/kb/intent"
  { printf -- '---\n'; [ -n "$3" ] && printf 'issue: %s\n' "$3"; printf 'description: "example"\n---\n\ntext\n'; } > "$w/kb/intent/$2.md"
  printf '%s' "$w"
}
opd() {  # opd <cwd> <args...> — open-pr.sh --dry-run with the usual files
  local d=$1; shift; op "$d" --title "feat: x" --summary "$F/sum.md" --evidence "$F/ev.txt" --dry-run "$@" 2>/dev/null
}

fam_op() {  # open-pr.sh: --closes from the intent record, --crit, --fixes, --draft, --dry-run
  PLX=$1; local W IW B J; mk_pr_repo; OPENV=(); OUTSIDE=$(fresh)
  IW=$(mk_intent_wt "$PW" 2026-03-03-op 17)
  J=$(opd "$IW"); B=$(pj "$J" body)
  eq "$(printf '%s\n' "$B" | head -1)" "Closes #17" "[A4] on branch intent/<slug>, --closes is read from 'issue: 17' of the record"
  J=$(opd "$IW" --closes 99); B=$(pj "$J" body)
  eq "$(printf '%s\n' "$B" | head -1)" "Closes #99" "[A4] an explicit --closes wins"
  eq "$(printf '%s\n' "$B" | grep -c 'Closes #17')" 0 "[A4] …and the record's number is not added"
  J=$(opd "$PT"); B=$(pj "$J" body)
  eq "$(printf '%s\n' "$B" | grep -c 'Closes #')" 0 "[A4] on a branch that is not intent/*, nothing is read: no Closes line"
  local IW2; IW2=$(mk_intent_wt "$PW" 2026-03-03-noissue "")
  J=$(opd "$IW2"); B=$(pj "$J" body)
  eq "$(printf '%s\n' "$B" | grep -c 'Closes #')" 0 "[A4] a record with no issue: line: no Closes line"
  printf 'one\ntwo\n' > "$F/crit.txt"
  J=$(opd "$PT" --crit "$F/crit.txt" --fixes "98 96"); B=$(pj "$J" body)
  hasline "$B" "- [ ] one" "[A4] --crit: the criteria become open checkboxes"
  hasline "$B" "$TOK_FIXES #98" "[A4] --fixes reaches the body (first number)"; hasline "$B" "$TOK_FIXES #96" "[A4] …and the second"
  J=$(opd "$PT" --draft); eq "$(pj "$J" draft)" true "[A4] --draft reaches the payload"
  eq "$(pj "$J" head)" feat/x "[A4] the head is the checked-out branch"
  eq "$(pj "$J" title)" "feat: x" "[A4] --title reaches the payload"
  eq "$(pj "$J" base)" main "[A4] the base defaults to main"
  J=$(opd "$PT" --head other --base release)
  eq "$(pj "$J" head)" other "[A4] --head reaches the payload"; eq "$(pj "$J" base)" release "[A4] --base reaches the payload"
  J=$( cd "$PT" && cenv PATH="$(bare_path nogh)" bash "$PLX/scripts/open-pr.sh" --title t --summary "$F/sum.md" --evidence "$F/ev.txt" --dry-run 2>/dev/null ); rc=$?
  eq "$rc" 0 "[A4] --dry-run with no gh on PATH: rc 0"; eq "$(pkeys "$J")" "base body head title" "[A4] …it prints the payload"
}

fam_op_run() {  # open-pr.sh without --dry-run, and its own exit codes
  PLX=$1; local out rc GL; mk_pr_repo; OUTSIDE=$(fresh); GL="$F/gh.log"; : > "$GL"
  OPENV=(GH_LOG="$GL" GH_STDIN="$F/stdin.md")
  out=$(op "$PT" --title "feat: x" --summary "$F/sum.md" --evidence "$F/ev.txt" 2>/dev/null); rc=$?
  eq "$rc" 0 "[A5] a real run with a working gh: rc 0"; eq "$out" 7 "[A5] …stdout is the PR number"
  has "$(cat "$GL")" "[pr] [create]" "[A5] …gh pr create was called"; hasnt "$(cat "$GL")" "[--draft]" "[A5] …without --draft"
  has "$(cat "$GL")" "[--repo] [acme/app-demo]" "[A5] …on the repository the adapter read from gh (adapter and real core together)"
  has "$(cat "$GL")" "[--title] [feat: x]" "[A5] …with the title"; has "$(cat "$GL")" "[--base] [main]" "[A5] …with the base"; has "$(cat "$GL")" "[--head] [feat/x]" "[A5] …with the head"
  : > "$GL"; op "$PT" --title "feat: y" --summary "$F/sum.md" --evidence "$F/ev.txt" --head other --base release >/dev/null 2>&1
  has "$(cat "$GL")" "[--title] [feat: y]" "[A5] an explicit --title reaches gh"; has "$(cat "$GL")" "[--base] [release]" "[A5] an explicit --base reaches gh"; has "$(cat "$GL")" "[--head] [other]" "[A5] an explicit --head reaches gh"
  : > "$GL"; op "$PT" --title "feat: x" --summary "$F/sum.md" --evidence "$F/ev.txt" --draft >/dev/null 2>&1
  has "$(cat "$GL")" "[--draft]" "[A5] --draft is passed to gh pr create"
  : > "$GL"; printf 'one\ntwo\n' > "$F/crit.txt"
  op "$PT" --title "feat: x" --summary "$F/sum.md" --evidence "$F/ev.txt" --crit "$F/crit.txt" --fixes 98 --closes 5 >/dev/null 2>&1
  hasline "$(cat "$F/stdin.md")" "- [ ] one" "[A5] --crit reaches the body gh receives"
  hasline "$(cat "$F/stdin.md")" "$TOK_FIXES #98" "[A5] --fixes reaches the body gh receives"; hasline "$(cat "$F/stdin.md")" "Closes #5" "[A5] --closes reaches the body gh receives"
  OPENV=()
  op "$PT" --title t --summary "$F/sum.md" --evidence "$F/ev-empty.txt" >/dev/null 2>&1; eq "$?" 3 "[A5] empty evidence: the core's rc 3 comes through"
  op "$PT" --title t --summary "$F/none.md" --evidence "$F/ev.txt" >/dev/null 2>&1; eq "$?" 66 "[A5] a summary file that does not exist: rc 66 comes through"
  op "$PW" --title t --summary "$F/sum.md" --evidence "$F/ev.txt" >/dev/null 2>&1; eq "$?" 5 "[A5] from the main tree: rc 5 comes through"
  op "$PT" --summary "$F/sum.md" --evidence "$F/ev.txt" >/dev/null 2>&1; eq "$?" 64 "[A5] no --title: rc 64"
  op "$PT" --title t --evidence "$F/ev.txt" >/dev/null 2>&1; eq "$?" 64 "[A5] no --summary: rc 64"
  op "$PT" --title t --summary "$F/sum.md" >/dev/null 2>&1; eq "$?" 64 "[A5] no --evidence: rc 64"
  op "$PT" --title t --summary "$F/sum.md" --evidence "$F/ev.txt" --no-such-flag >/dev/null 2>&1; eq "$?" 64 "[A5] an unknown argument: rc 64"
  ( cd "$PT" && cenv PATH="$(bare_path nogh)" bash "$PLX/scripts/open-pr.sh" --title t --summary "$F/sum.md" --evidence "$F/ev.txt" ) >/dev/null 2>&1
  eq "$?" 2 "[A5] gh is not installed (no --dry-run): rc 2"
  ( cd "$PT" && cenv PATH="$GHB:$(bare_path nogh-nopy)" bash "$PLX/scripts/open-pr.sh" --title t --summary "$F/sum.md" --evidence "$F/ev.txt" ) >/dev/null 2>&1
  eq "$?" 2 "[A5] python3 is not installed: rc 2"
  local D; D=$(fresh); cp -r "$PLX" "$D/p"; rm -f "$D/p/scripts/open_pr.py"
  ( cd "$PT" && cenv PATH="$GHB:$PATH" bash "$D/p/scripts/open-pr.sh" --title t --summary "$F/sum.md" --evidence "$F/ev.txt" ) >/dev/null 2>&1
  eq "$?" 2 "[A5] the core is missing next to the adapter: rc 2"
  # what the adapter hands to the core: the slug it read from gh as --repo, and nothing of the old transport
  cp -r "$PLX" "$D/spy"; printf 'import sys\nopen(sys.argv[0] + ".argv", "w").write("\\n".join(sys.argv[1:]))\n' > "$D/spy/scripts/open_pr.py"
  ( cd "$PT" && cenv PATH="$GHB:$PATH" bash "$D/spy/scripts/open-pr.sh" --title t --summary "$F/sum.md" --evidence "$F/ev.txt" ) >/dev/null 2>&1
  hasline "$(cat "$D/spy/scripts/open_pr.py.argv")" "--repo" "[A6] the adapter passes --repo to the core…"; hasline "$(cat "$D/spy/scripts/open_pr.py.argv")" "acme/app-demo" "[A6] …with the slug it read from gh"
  hasnt "$(cat "$D/spy/scripts/open_pr.py.argv")" "--gh" "[A6] …and never --gh"
}

FAMILIES="fam_count fam_forms fam_usage fam_op fam_op_run"

echo "== the real adapters =="
PL0="$TMP/plugin-real"; mk_plugin_copy "$PL0"
[ -f "$PL0/scripts/intent-branch.sh" ] && [ -f "$PL0/scripts/open-pr.sh" ] && ok "instrument: the plugin copy has both adapters" || bad "instrument: an adapter is missing from the copy"
for f in $FAMILIES; do echo "-- $f"; "$f" "$PL0"; done

echo "== planted breaks: each family must go red on a copy with one break =="
BRK() {  # BRK <label> <family> <needle> <script> <old> <new>
  local d="$TMP/break-$1"; mk_plugin_copy "$d"
  mutate "$d/scripts/$4" "$5" "$6" && expect_red "$1" "$2" "$d" "$3"
}
BRK count-threshold fam_count '[A1] a task branch with 2 commits' intent-branch.sh '[ "$N" -gt 1 ]' '[ "$N" -gt 5 ]'
BRK load-bearing-ignored fam_count '[A1] 3 commits with --load-bearing' intent-branch.sh '{ LB=1; continue; }' '{ LB=0; continue; }'
BRK load-bearing-passed-down fam_count '[A1] 3 commits with --load-bearing' intent-branch.sh '{ LB=1; continue; }' '{ LB=1; }'
BRK load-bearing-everywhere fam_count '[A1] --load-bearing on worker-branch is not consumed' intent-branch.sh '--load-bearing) [ "$SUB" = integrate ] && { LB=1; continue; } ;;' '--load-bearing) { LB=1; continue; } ;;'
BRK cwd-equals-ignored fam_forms '[A2] --cwd=PATH --intent=SLUG' intent-branch.sh '--cwd=*) CWD="${a#*=}" ;;' '--cwd=*) ;;'
BRK intent-equals-ignored fam_forms '[A2] --cwd=PATH --intent=SLUG' intent-branch.sh '--intent=*) INTENT="${a#*=}" ;;' '--intent=*) ;;'
BRK branch-equals-ignored fam_forms '[A2] the count follows --branch' intent-branch.sh '--branch=*) BRANCH="${a#*=}" ;;' '--branch=*) ;;'
BRK intent-ref-equals-ignored fam_forms '[A2] --intent-ref=main (equals form)' intent-branch.sh '--intent-ref=*) IREF="${a#*=}" ;;' '--intent-ref=*) ;;'
BRK intent-ref-ignored fam_forms '[A2] --intent-ref main moves the cut point' intent-branch.sh '--intent-ref) ARGS+=("$a"); IREF="${1:-}"; a="${1:-}"; shift || true ;;' '--intent-ref) ARGS+=("$a"); a="${1:-}"; shift || true ;;'
BRK title-fixed-dry fam_op '[A4] --title reaches the payload' open-pr.sh 'exec python3 "$CORE" --title "$TITLE" --summary-file "$SUM"' 'exec python3 "$CORE" --title x --summary-file "$SUM"'
BRK head-dropped-dry fam_op '[A4] --head reaches the payload' open-pr.sh '${HEAD_BR:+--head "$HEAD_BR"} ${FIXES:+--fixes "$FIXES"}' '${FIXES:+--fixes "$FIXES"}'
BRK base-fixed-dry fam_op '[A4] --base reaches the payload' open-pr.sh '--evidence-file "$EV" --base "$BASE" \' '--evidence-file "$EV" --base main \'
BRK head-dropped-run fam_op_run '[A5] an explicit --head reaches gh' open-pr.sh '[ -n "$HEAD_BR" ] && ARGS+=(--head "$HEAD_BR")' ':'
BRK missing-core-rc fam_usage '[A3] the core is missing' intent-branch.sh 'else die "thiếu lõi $f" 2; fi' 'else die "thiếu lõi $f" 3; fi'
BRK no-subcommand-rc fam_usage '[A3] no subcommand' intent-branch.sh '[ $# -gt 0 ] || die "$(say ib.sh.no_subcommand)" 64' '[ $# -gt 0 ] || die "$(say ib.sh.no_subcommand)" 2'
BRK closes-not-read fam_op '[A4] on branch intent/<slug>' open-pr.sh '        "$PFX"?*)' '        intent-x/*)'
BRK explicit-closes-overwritten fam_op '[A4] an explicit --closes wins' open-pr.sh 'if [ -z "$CLOSES" ]; then' 'if true; then'
BRK crit-dropped fam_op_run '[A5] --crit reaches the body gh' open-pr.sh '[ -n "$CRIT" ]    && ARGS+=(--crit-file "$CRIT")' ':'
BRK crit-dropped-dry fam_op '[A4] --crit' open-pr.sh '${CRIT:+--crit-file "$CRIT"} ${DRAFT:+--draft} --dry-run' '${DRAFT:+--draft} --dry-run'
BRK draft-dropped fam_op_run '[A5] --draft is passed' open-pr.sh '[ -n "$DRAFT" ]   && ARGS+=(--draft)' ':'
BRK unknown-arg-rc fam_op_run '[A5] an unknown argument' open-pr.sh '*) die "$(say op.sh.unknown_arg "$1")" 64 ;;' '*) die "$(say op.sh.unknown_arg "$1")" 2 ;;'
BRK missing-gh-rc fam_op_run '[A5] gh is not installed' open-pr.sh 'command -v gh >/dev/null 2>&1 || die "$(say op.sh.no_gh)" 2' 'command -v gh >/dev/null 2>&1 || die "$(say op.sh.no_gh)" 1'
BRK missing-summary-allowed fam_op_run '[A5] no --summary' open-pr.sh '[ -n "$SUM" ]   || die "$(say op.sh.no_summary)" 64' ':'
BRK missing-evidence-allowed fam_op_run '[A5] no --evidence' open-pr.sh '[ -n "$EV" ]    || die "$(say op.sh.no_evidence)" 64' ':'
BRK missing-core-rc-op fam_op_run '[A5] the core is missing' open-pr.sh 'else die "thiếu lõi $f" 2; fi' 'else die "thiếu lõi $f" 3; fi'
BRK repo-not-passed fam_op_run '[A6] the adapter passes --repo' open-pr.sh '[ -n "$SLUG" ] && ARGS+=(--repo "$SLUG")' ':'
BRK old-flag-passed fam_op_run '[A6] …and never --gh' open-pr.sh 'exec python3 "$CORE" "${ARGS[@]}"' 'exec python3 "$CORE" "${ARGS[@]}" --gh'
PLC="$TMP/break-none"; mk_plugin_copy "$PLC"
QN=0; okdef=$(declare -f ok); baddef=$(declare -f bad); sp=$PASS; sf=$FAIL
ok() { :; }; bad() { QN=$((QN+1)); }
for f in $FAMILIES; do "$f" "$PLC" >/dev/null 2>&1; done
eval "$okdef"; eval "$baddef"; PASS=$sp; FAIL=$sf
eq "$QN" 0 "control: an unbroken copy passes every family (no failed check)"

echo; summary
