#!/usr/bin/env bash
# =============================================================================
# The story kb checks: intake's type and focus, the story, task and bug cards, AC traced from a story intent to its spec, quoted
# out-of-scope lines (scripts/kb.py, scripts/intent_branch.py, scripts/open_pr.py)
# =============================================================================
# Each family builds its own repository in the scratch tree: a story intent with AC1 to AC3 and the spec that names it.
#   [spec-trace]      a story spec traces its AC: an AC of the intent missing from the Goal (a dropped AC), a criterion with no
#                     `→ AC…` or naming an AC the intent does not have, an AC no criterion names: red, each named; the story is
#                     found by the spec's `Intent:` line or an intent's `spec:`, a task intent beside it does not hide it; a spec
#                     no story intent is tied to keeps today's rules; a spec already on the base only warns, red under `--strict`
#   [spec-oos-quote]  an out-of-scope line with neither a quote nor a page decision id: a WARNING, red under `--strict`;
#                     open_pr.py runs it under `--strict` on a story's branch and refuses (rc 6)
#   [plan-trace]      kb.py check plan: every row starts `Delivers AC…:` or `enabling:`, each id is an AC of the plan's spec, each AC
#                     is delivered by a row not dropped, the frontmatter has `focus:`, the check links problems pass: red for a
#                     plan whose intent says `type: story`, each finding named; any other plan only warns (rc 0); `check links`
#                     runs it on the plans changed in the change, never turning an older plan red
#   [real-run-missing] [real-run-ok]  kb.py check: a story intent `status: done` whose plan holds a `baton` or `run` touch, or whose
#                     spec says `real_run: required`, needs a record kb/records/*-real-run.md naming it (`story:` the intent path, its
#                     `key:` or `#<issue>`): red without one, red naming the intent and why; red when a record misses its story, AC
#                     ids, or a run's command, UTC time, run log id or output excerpt; an open story, a task, a story that asks no
#                     real run, a dropped row: no red. `kb.py new real-run` writes the record's template
#   [story-v2]        the story the owner approves, its parts named by a bold lead or a heading (vi or en labels): a missing part (the
#                     As / I want / so that line, context, AC, out of scope, appetite), an AC number written twice, AC with no number,
#                     more than 3 open questions: red, each named; a question with no recommendation or reason, a code block, a path,
#                     a file name, a command, a story over 3500 characters: a WARNING, rc 0; answered questions are not counted
#   [spec-v2]         a spec derived from a story (goal, constraints, criteria, risks, open points, any order): an AC no criterion
#                     names, an AC the story lacks named in the goal or a criterion, a missing or empty section, a section of the
#                     old shape: red; a criterion with no AC or not written as when … then, a code block, over 8000 characters: a
#                     WARNING, rc 0 even under --strict; a task's v2 spec is judged for shape only; an en repository's names
#   [k2-templates]    kb.py new intent --type story, new spec and new plan write the story, the five sections and the lean columns
#                     in the repository's language: an unfilled template's one problem is its blanks; en labels hold no Vietnamese
#   [k2-old-shape]    a story's spec or plan of the earlier shape: red when new, or when the spec's body or a plan's row cell changed;
#                     a WARNING (also under --strict) when unchanged or when only the frontmatter, a Link cell or the Decisions
#                     changed; the red names only the shape to take; a task's spec keeps either shape
#   [k2-first-card]   a first story card on a new intent: a WARNING, rc 0
#   [k2-ac-guard]     a story on the merge base whose AC changed, was dropped or added, or whose AC part gained text: red, naming the
#                     AC, until a NEW decision item quotes the owner; blanks, emphasis, code marks, `1)` markers and a group heading are
#                     no change; `check links` (what ship runs) runs it on the changed stories
#   [plan-v2]         a lean plan (Row, How, Delivers, Depends on, Trust touches, Link): a Delivers cell of AC ids read against the
#                     story's AC; an AC delivered by no row, an AC the story lacks, a cell that is not a list of AC: red
#   [replay-310]      a real drop replayed (tests/fixtures/replay-310/, a recast): a plan's Wanted 4 left the spec's Goal and nobody was
#                     asked: AC4 missing from the Goal (red once) and 6 unquoted out-of-scope lines (WARNING each, red under
#                     `--strict`): 7 red lines
#
# Families (the spec's Inputs rows of AC1 and AC2):
#   [intake-missing]       intake.focus required: create-intent with no `type:` or no `focus:` exits 9, names each missing
#                          field, and creates no branch and no issue
#   [intake-warn]          the default (warn): a plain intent gets one WARNING line, rc 0, its branch and its issue
#   [intake-focus-closed]  where a brain answers (a vibemaestro-brain beside the installed sdlc copy): a closed or unknown P is
#                          refused, "P9 is not an open focus of this brain"; an open P creates the branch and labels the issue
#   [intake-worker-label]  in a worker the P is read from the issue's labels: a missing `focus:` label is refused, naming it; no
#                          `issue: N`, and neither a brain nor a worker, are refused, naming both ways
#   [key]                  issue.code ACM: create-intent opens the issue first, writes `key: ACM-42` and cuts intent/ACM-42-<slug>
#                          (the file keeps its dated name); no issue (it fails, or --no-issue): rc 1 and no branch; a worker's
#                          `issue: 7` gives ACM-7 with no new issue; a key branch resolves to its intent (retry-issue, create-intent);
#                          a code that is not 3 capital letters is refused (rc 64); plan status links a PR on a key branch to its
#                          row (intent in the working tree, or only at the PR head), not one whose key differs
#   [labels]               under issue.code the issue carries intent, type:<t> and focus:<P>, and no label from the key
#   [jira]                 kb.py new intent --jira writes `jira:`; check intent shows it (and `key:`) and refuses a malformed one;
#                          plan status shows it on the row
#   [key-no-code]          issue.code null or absent: today's branch intent/<date>-<slug>, no `key:`, no warning, no refusal
#   [key-branch-pr]        on a key branch intent/ACM-7-<slug>: open_pr.py runs the story gate (rc 6 as on the stem branch) and keeps
#                          the Plan row line, open-pr.sh guesses --closes from the intent its key: names, stage-signal.sh sends
#                          the intent's stem
#   [card-story] [card-task] [card-bug]  kb.py new intent --type writes the card of its type; kb.py check intent judges it
#   [card-quote]           a story AC with no quote is red; a Not doing line with neither a quote nor a page decision id warns,
#                          and is red under --strict; the whole-kb kb.py check judges only intents new in the change
#
# The brain and gh are fakes written here (a brain answering `show <P> --json` for P1 live, P3 retired, P9 unknown; a gh that
# logs its arguments, serves the labels of GH_LABELS and the PR list of GH_PRS, and fails `issue create` under GH_ISSUE_FAIL). Real git on throw-away repositories, no network.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
. "$HERE/fixtures/lib.sh"
# shellcheck source=fixtures/ports.sh
. "$HERE/fixtures/ports.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
export PYTHONDONTWRITEBYTECODE=1
H0=$(tree_hash "$SRC_ROOT")
KBPY="$PLUGIN/scripts/kb.py"
OPENPR="$PLUGIN/scripts/open_pr.py"

GOAL3='1. **AC1: one.** ("lời một")
2. **AC2: two.** ("lời hai")
3. **AC3: three.** ("lời ba")'
CRIT3='1. `bash t.sh` → `[a] ok` → AC1
2. `bash t.sh` → `[b] ok` → AC2, AC3
3. PR có mục `## Bằng chứng chạy`'
OOS_OK='- Sprints: "Không làm sprint" (the owner).
- Jira sync: “Script đồng bộ làm sau”.
- The floor. (page decision not-doing-quotes (a))'

mk_repo() {  # mk_repo <dir> <intent type> — a repository with the intent kb/intent/2026-11-08-s.md (AC1 to AC3), a full story card
  git_ init -q -b main "$1"
  mkdir -p "$1/kb/intent" "$1/kb/specs"
  cat > "$1/kb/intent/2026-11-08-s.md" <<EOF
---
type: $2
focus: P1
spec: kb/specs/2026-11-08-s.md
description: "fixture"
---

# fixture

## Story

As a maintainer, I want the AC traced, so that none is dropped.

## Acceptance criteria

1. **AC1: one.** Given, when, then. ("lời một")
2. **AC2: two.** Given, when, then. ("lời hai")
3. **AC3: three.** Given, when, then. ("lời ba")

## Not doing

- nothing ("không làm gì")

## Measure

The spec names every AC.
EOF
}

mk_spec() {  # mk_spec <dir> <goal> <criteria> <out of scope> [<Intent: line>] — the spec kb/specs/2026-11-08-s.md
  cat > "$1/kb/specs/2026-11-08-s.md" <<EOF
---
description: "fixture"
---

# fixture

${5-Intent: kb/intent/2026-11-08-s.md}

## Bối cảnh

Why.

## Mục tiêu

$2

## Ngoài phạm vi

$4

## Inputs and failure cases

| Input or failure | Expected behaviour | Test that proves it |
|---|---|---|
| a | b | \`bash t.sh\` |

## Tiêu chí chấp nhận

$3
EOF
}

chk()  { (cd "$1" && python3 "$KBPY" check spec 2026-11-08-s "${@:2}" 2>&1); }
# a red-expected run goes through capped (fixtures/capped.sh)
chkr() { (cd "$1" && capped python3 "$KBPY" check spec 2026-11-08-s "${@:2}" 2>&1); }

fam_trace() {
  echo "== [spec-trace] a story spec traces the intent's AC =="
  local r="$TMP/trace" o rc
  mk_repo "$r" story
  mk_spec "$r" "$GOAL3" "$CRIT3" "$OOS_OK"
  o=$(chk "$r"); rc=$?
  eq "$rc" 0 "[spec-trace] control: every AC in the Goal and named: rc 0"
  has "$o" 'story: 3 AC, each in `## Mục tiêu` and each named by a criterion.' "[spec-trace] green says how many AC and that each is named"

  # a dropped AC: AC2 leaves the Goal, and no criterion names it any more
  mk_spec "$r" "$(printf '%s\n' "$GOAL3" | grep -v AC2)" "$(printf '%s\n' "$CRIT3" | sed 's/AC2, AC3/AC3/')" "$OOS_OK"
  o=$(chkr "$r"); rc=$?
  eq "$rc" 65 "[spec-trace] an AC of the intent missing from the spec: rc 65"
  has "$o" '- AC2 of the intent is missing from `## Mục tiêu` (a dropped AC' "[spec-trace] …named as a dropped AC"
  hasnt "$o" 'AC2 is named by no criterion' "[spec-trace] …reported once, not again as unnamed"
  hasnt "$o" 'story: ' "[spec-trace] …and no green story line"

  # a criterion with no arrow, one naming an AC the intent does not have, so AC1 and AC3 are named by none
  mk_spec "$r" "$GOAL3" '1. `bash t.sh` → `[a] ok`
2. `bash t.sh` → `[b] ok` → AC2, AC9
3. PR có mục `## Bằng chứng chạy`' "$OOS_OK"
  o=$(chkr "$r"); rc=$?
  eq "$rc" 65 "[spec-trace] a criterion with no AC, a bogus AC: rc 65"
  has "$o" '- criterion 1 does not end `→ AC<n>[, AC<m>]`: name the AC it proves' "[spec-trace] …the criterion with no AC named"
  has "$o" '- criterion 2 names AC9, which is not an AC of the intent' "[spec-trace] …the bogus AC9 named"
  has "$o" '- AC1 is named by no criterion' "[spec-trace] …AC1 named by none"
  has "$o" '- AC3 is named by no criterion' "[spec-trace] …AC3 named by none"
  hasnt "$o" 'AC2 is named by no criterion' "[spec-trace] …AC2 is named"

  # the last criterion (the evidence rule) needs no arrow, any other does; an arrow inside the text is not the end
  mk_spec "$r" "$GOAL3" '1. `bash t.sh` → AC1 then `[a] ok`
2. `bash t.sh` → `[b] ok` → AC1, AC2, AC3
3. PR có mục `## Bằng chứng chạy`' "$OOS_OK"
  o=$(chkr "$r"); rc=$?
  eq "$rc" 65 "[spec-trace] an arrow mid-criterion is not its end: rc 65"
  has "$o" '- criterion 1 does not end' "[spec-trace] …criterion 1 named"
  hasnt "$o" 'criterion 2' "[spec-trace] …criterion 2 passes"

  # a task intent keeps today's rules: the same untraced spec passes, with no story line
  local t="$TMP/task"
  mk_repo "$t" task
  mk_spec "$t" "Goal." '1. `bash t.sh` → `[a] ok`
2. PR có mục `## Bằng chứng chạy`' "- Sprints."
  o=$(chk "$t" --strict); rc=$?
  eq "$rc" 0 "[spec-trace] a task intent: today's rules, rc 0 even under --strict"
  hasnt "$o" 'story: ' "[spec-trace] …no story line"
  hasnt "$o" 'WARNING' "[spec-trace] …and no out-of-scope warning"

  # a dropped Intent: line does not hide the story: the intent whose spec: names the spec is read
  mk_spec "$r" "$(printf '%s\n' "$GOAL3" | grep -v AC2)" "$CRIT3" "$OOS_OK" "No intent."
  o=$(chkr "$r"); rc=$?
  eq "$rc" 65 "[spec-trace] no Intent: line, a story intent whose spec: names it, AC2 dropped: rc 65"
  has "$o" '- AC2 of the intent is missing' "[spec-trace] …the drop named"

  # a task intent tied to the same spec hides nothing: first in file order through spec:, or the one the Intent: line names
  local two="$TMP/two"
  mk_repo "$two" story
  sed -e 's/^type: story$/type: task/' "$two/kb/intent/2026-11-08-s.md" > "$two/kb/intent/2026-11-08-a.md"   # not a break: the task intent is the input
  mk_spec "$two" "$(printf '%s\n' "$GOAL3" | grep -v AC2)" "$CRIT3" "$OOS_OK" "No intent."
  o=$(chkr "$two"); rc=$?
  eq "$rc" 65 "[spec-trace] a task intent first in file order and a story intent, both naming the spec: rc 65"
  has "$o" '- AC2 of the intent is missing' "[spec-trace] …the story is traced"
  mk_spec "$two" "$(printf '%s\n' "$GOAL3" | grep -v AC2)" "$CRIT3" "$OOS_OK" "Intent: kb/intent/2026-11-08-a.md"
  o=$(chkr "$two"); rc=$?
  eq "$rc" 65 "[spec-trace] the Intent: line names the task intent, a story intent's spec: names the spec: rc 65"
  has "$o" '- AC2 of the intent is missing' "[spec-trace] …the story is traced"

  # a spec no intent names (no Intent: line, no spec: pointing at it) keeps today's rules
  sed -i '/^spec: /d' "$r/kb/intent/2026-11-08-s.md"   # not a break: an intent with no spec: line is the input of this case
  mk_spec "$r" "Goal." '1. `bash t.sh` → `[a] ok`
2. PR có mục `## Bằng chứng chạy`' "- Sprints." "No intent."
  o=$(chk "$r"); rc=$?
  eq "$rc" 0 "[spec-trace] no intent names the spec: today's rules, rc 0"
  hasnt "$o" 'story: ' "[spec-trace] …no story line"

  # an AC id shown only in a comment or a fenced block of the Goal is not in the Goal
  local z="$TMP/hidden"
  mk_repo "$z" story
  mk_spec "$z" "$(printf '%s\n' "$GOAL3" | grep -v AC2)
<!--
2. **AC2: two.**
-->
\`\`\`
2. **AC2: two.**
\`\`\`" "$CRIT3" "$OOS_OK"
  o=$(chkr "$z"); rc=$?
  eq "$rc" 65 "[spec-trace] AC2 only inside a comment and a fence: rc 65"
  has "$o" '- AC2 of the intent is missing' "[spec-trace] …named as missing"

  # an AC id only in a comment of the intent card is not an AC of the intent
  # not a break: a card ending in a commented-out AC4 is the input of this case
  sed -i '/^## Not doing$/,$d' "$z/kb/intent/2026-11-08-s.md"; printf '<!--\n4. **AC4: four.**\n-->\n' >> "$z/kb/intent/2026-11-08-s.md"
  mk_spec "$z" "$GOAL3" "$CRIT3" "$OOS_OK"
  o=$(chk "$z"); rc=$?
  eq "$rc" 0 "[spec-trace] AC4 only inside a comment of the intent card: not an AC, rc 0"
  has "$o" 'story: 3 AC, each' "[spec-trace] …3 AC counted"

  # an id named anywhere after an arrow is checked, in the last criterion too
  mk_spec "$z" "$GOAL3" '1. `bash t.sh` → AC99 and → AC1
2. `bash t.sh` → `[b] ok` → AC2, AC3
3. PR có mục `## Bằng chứng chạy` → AC98' "$OOS_OK"
  o=$(chkr "$z"); rc=$?
  eq "$rc" 65 "[spec-trace] a bogus id mid-criterion and in the last criterion: rc 65"
  has "$o" '- criterion 1 names AC99, which is not an AC of the intent' "[spec-trace] …AC99 named"
  has "$o" '- criterion 3 names AC98, which is not an AC of the intent' "[spec-trace] …AC98 named"

  # a story intent whose card yields no AC id is not a green 0 AC
  local n="$TMP/noac"
  mk_repo "$n" story
  sed -i 's/^\([0-9]\)\. \*\*AC[0-9]*: /\1. **/' "$n/kb/intent/2026-11-08-s.md"   # not a break: a card with no AC id is the input
  mk_spec "$n" "Goal." '1. `bash t.sh` → `[a] ok`
2. PR có mục `## Bằng chứng chạy`' "$OOS_OK"
  o=$(chkr "$n"); rc=$?
  eq "$rc" 65 "[spec-trace] a story intent with no AC id: rc 65"
  has "$o" '- the intent kb/intent/2026-11-08-s.md lists no AC' "[spec-trace] …saying so"

  # a spec already on the base (origin/main) only warns
  local b="$TMP/older"
  mk_repo "$b" story
  mk_spec "$b" "$(printf '%s\n' "$GOAL3" | grep -v AC2)" "$CRIT3" "$OOS_OK"
  git_ -C "$b" add -A && git_ -C "$b" commit -qm base && git_ -C "$b" update-ref refs/remotes/origin/main HEAD
  o=$(chk "$b"); rc=$?
  eq "$rc" 0 "[spec-trace] a spec already on the base with AC2 dropped: rc 0"
  has "$o" 'WARNING kb/specs/2026-11-08-s.md: AC2 of the intent is missing from `## Mục tiêu` (a dropped AC' "[spec-trace] …a WARNING naming the drop"
  o=$(chkr "$b" --strict); rc=$?
  eq "$rc" 65 "[spec-trace] …the same older spec under --strict (what open-pr.sh runs): rc 65"
  has "$o" '- AC2 of the intent is missing' "[spec-trace] …naming the drop"
}

fam_oos() {
  echo "== [spec-oos-quote] an out-of-scope line needs a quote or a page decision id =="
  local r="$TMP/oos" o rc
  mk_repo "$r" story
  mk_spec "$r" "$GOAL3" "$CRIT3" "$OOS_OK"
  o=$(chk "$r" --strict); rc=$?
  eq "$rc" 0 '[spec-oos-quote] control: "…", “…” and (page decision <id> (<key>)) lines: rc 0 under --strict'
  hasnt "$o" 'out-of-scope line' "[spec-oos-quote] …no out-of-scope warning"
  has "$o" 'WARNING kb/specs/2026-11-08-s.md: the earlier spec shape: a WARNING while its body is unchanged' "[spec-oos-quote] …a story spec of the earlier shape, not changed (no base): a WARNING"

  local bare="$OOS_OK
- Sprints, with no quote.
- Short: \"ab\".
- An id with no key (page decision not-doing-quotes).
- Blank: \"   \"."
  mk_spec "$r" "$GOAL3" "$CRIT3" "$bare"
  o=$(chk "$r"); rc=$?
  eq "$rc" 0 "[spec-oos-quote] default: a line with neither is not red (rc 0)"
  has "$o" 'WARNING kb/specs/2026-11-08-s.md: out-of-scope line `- Sprints, with no quote.` holds neither the owner'"'"'s quote (`"…"`) nor a page decision id (`(page decision <id> (<key>))`) (red under --strict)' "[spec-oos-quote] …a WARNING naming the line"
  has "$o" 'out-of-scope line `- Short: "ab".`' "[spec-oos-quote] …a quote under three characters is no quote"
  has "$o" 'out-of-scope line `- An id with no key (page decision not-doing-quotes).`' "[spec-oos-quote] …an id with no key is no page decision id"
  has "$o" 'out-of-scope line `- Blank: " ".`' "[spec-oos-quote] …a quote of blanks is no quote (the line shown with its blanks folded)"
  eq "$(printf '%s\n' "$o" | grep -c '^WARNING.*out-of-scope line')" 4 "[spec-oos-quote] …four out-of-scope warnings, the quoted lines none"
  has "$o" 'story: 3 AC' "[spec-oos-quote] …and the AC still traced"

  o=$(chkr "$r" --strict); rc=$?
  eq "$rc" 65 "[spec-oos-quote] --strict: rc 65"
  has "$o" '- out-of-scope line `- Sprints, with no quote.` holds neither' "[spec-oos-quote] …naming the line"
  hasnt "$o" 'red under --strict' "[spec-oos-quote] …as a problem, not a warning"

  mk_spec "$r" "$GOAL3" "$CRIT3" "none"
  o=$(chk "$r" --strict); rc=$?
  eq "$rc" 0 "[spec-oos-quote] the section is the one line none: rc 0 under --strict"
  mk_spec "$r" "$GOAL3" "$CRIT3" "- None."
  o=$(chk "$r" --strict); rc=$?
  eq "$rc" 0 "[spec-oos-quote] …or the one item - None.: rc 0 under --strict"

  # open_pr.py runs it with --strict on the story's own branch, before the PR exists (--dry-run: no gh call is reached)
  local w="$TMP/oos-wt"
  mk_spec "$r" "$GOAL3" "$CRIT3" "$bare"
  git_ -C "$r" add -A && git_ -C "$r" commit -qm base && git_ -C "$r" worktree add -q -b intent/2026-11-08-s "$w"
  printf 'the summary\n' > "$TMP/sum.md"; printf 'ok\n' > "$TMP/ev.txt"
  op() { (cd "$w" && python3 "$OPENPR" --title "feat(x): s" --summary-file "$TMP/sum.md" --evidence-file "$TMP/ev.txt" --dry-run 2>&1); }
  o=$(capped op); rc=$?
  eq "$rc" 6 "[spec-oos-quote] open_pr.py on the story's branch, an unquoted line: rc 6, no PR"
  has "$o" "a story's kb check refuses (--strict): the PR is NOT opened." "[spec-oos-quote] …saying why"
  has "$o" '- out-of-scope line `- Sprints, with no quote.` holds neither' "[spec-oos-quote] …naming the line"
  mk_spec "$w" "$GOAL3" "$CRIT3" "$OOS_OK"
  o=$(op); rc=$?
  eq "$rc" 0 "[spec-oos-quote] open_pr.py once every line is quoted: rc 0"
  cp "$w/kb/intent/2026-11-08-s.md" "$TMP/full-card.md"
  sed -i '/^## Measure$/,$d' "$w/kb/intent/2026-11-08-s.md"   # not a break: a story card with no Measure is the input of this case
  o=$(capped op); rc=$?
  eq "$rc" 6 "[spec-oos-quote] open_pr.py reaches kb.py check intent --strict: a story card with no ## Measure, rc 6"
  has "$o" '- section `## Measure` is missing (a story card' "[spec-oos-quote] …naming the card's missing section"
  cp "$TMP/full-card.md" "$w/kb/intent/2026-11-08-s.md"
  sed -i 's/^type: story$/type: task/' "$w/kb/intent/2026-11-08-s.md"   # not a break: a task intent is the input of this case
  mk_spec "$w" "$GOAL3" "$CRIT3" "$bare"
  o=$(op); rc=$?
  eq "$rc" 0 "[spec-oos-quote] open_pr.py on a task's branch: not checked, rc 0"
}

mk_plan() {  # mk_plan <dir> <frontmatter line> <row lines…> — the plan kb/plans/2026-11-08-s.md of the spec above (rows from line 14)
  local d=$1 fm=$2; shift 2
  mkdir -p "$d/kb/plans"
  { printf -- '---\ndescription: "fixture"\n%s\n---\n\n# Plan\n\nIntent: kb/intent/2026-11-08-s.md · Spec: kb/specs/2026-11-08-s.md\n\n## Rows\n\n' "$fm"
    printf '| Row | Must be true | Link |\n|---|---|---|\n'; printf '%s\n' "$@"; } > "$d/kb/plans/2026-11-08-s.md"
}
ROW_A='| A | Delivers AC1, AC2: one and two | — |'
ROW_B='| B | Delivers AC3: three | — |'
pchk()  { (cd "$1" && python3 "$KBPY" check plan "${@:2}" 2>&1); }
pchkr() { (cd "$1" && capped python3 "$KBPY" check plan "${@:2}" 2>&1); }   # a red-expected run
lchk()  { (cd "$1" && python3 "$KBPY" check links 2>&1); }
lchkr() { (cd "$1" && capped python3 "$KBPY" check links 2>&1); }

fam_plan() {
  echo "== [plan-trace] a story plan traces its AC: every row Delivers or is enabling, every AC delivered =="
  local r="$TMP/plan" o rc
  mk_repo "$r" story
  mk_spec "$r" "$GOAL3" "$CRIT3" "$OOS_OK"
  mk_plan "$r" 'focus: P1' "$ROW_A" "$ROW_B"
  o=$(pchk "$r" kb/plans/2026-11-08-s.md); rc=$?
  eq "$rc" 0 "[plan-trace] control: AC1 to AC3 each delivered, a focus: rc 0"
  has "$o" 'plan: 3 AC (AC1 to AC3), each delivered by a row that is not dropped.' "[plan-trace] green says how many AC and that each is delivered"
  o=$(pchk "$r" 2026-11-08-s); rc=$?
  eq "$rc" 0 "[plan-trace] the stem of the plan is read the same: rc 0"

  mk_plan "$r" 'focus: P1' "$ROW_A" '| E | enabling: the shared fixture | — |' "$ROW_B"
  o=$(pchk "$r" kb/plans/2026-11-08-s.md); rc=$?
  eq "$rc" 0 "[plan-trace] a row that says enabling: <reason> needs no AC: rc 0"

  mk_plan "$r" 'focus: P1' "$ROW_A" '| B | the plan of the rest | — |' '| C | Delivers AC3: three | — |'
  o=$(pchkr "$r" kb/plans/2026-11-08-s.md); rc=$?
  eq "$rc" 65 "[plan-trace] a row with neither Delivers nor enabling: rc 65"
  has "$o" 'line 15: row B: Must be true starts neither `Delivers AC<n>[, AC<m>]:` nor `enabling: <reason>`' "[plan-trace] …it names the row and its line"
  hasnt "$o" 'row A' "[plan-trace] …and not the row that is right"

  mk_plan "$r" 'focus: P1' "$ROW_A" '| B | Delivers AC3, ac9: three | — |'
  o=$(pchkr "$r" kb/plans/2026-11-08-s.md); rc=$?
  eq "$rc" 65 "[plan-trace] a lowercase ac9, which the spec does not have: rc 65"
  has "$o" 'row B: Delivers AC9, which is not an AC of kb/specs/2026-11-08-s.md' "[plan-trace] …named as AC9"

  mk_plan "$r" 'focus: P1' "$ROW_A" "$ROW_B" '| E | enabling: - | — |'
  o=$(pchkr "$r" kb/plans/2026-11-08-s.md); rc=$?
  eq "$rc" 65 "[plan-trace] an enabling row with no reason (a dash): rc 65"
  has "$o" 'row E: Must be true starts neither' "[plan-trace] …it names the row"

  mk_plan "$r" 'focus: P1' "$ROW_A" '| B | Delivers AC3, AC9: three | — |'
  o=$(pchkr "$r" kb/plans/2026-11-08-s.md); rc=$?
  eq "$rc" 65 "[plan-trace] a row naming an AC the spec does not have: rc 65"
  has "$o" 'row B: Delivers AC9, which is not an AC of kb/specs/2026-11-08-s.md' "[plan-trace] …it names the row and the AC"

  mk_plan "$r" 'focus: P1' "$ROW_A" '| B | Delivers AC3: three | dropped: no longer needed |'
  o=$(pchkr "$r" kb/plans/2026-11-08-s.md); rc=$?
  eq "$rc" 65 "[plan-trace] an AC delivered only by a dropped row: rc 65"
  has "$o" 'AC3 is delivered by no row that is not dropped (only by dropped row B)' "[plan-trace] …it names the AC and the dropped row"

  mk_plan "$r" 'focus: P1' "$ROW_A"
  o=$(pchkr "$r" kb/plans/2026-11-08-s.md); rc=$?
  eq "$rc" 65 "[plan-trace] an AC no row names: rc 65"
  has "$o" 'AC3 is delivered by no row that is not dropped' "[plan-trace] …it names the AC"
  hasnt "$o" 'only by dropped' "[plan-trace] …and does not blame a dropped row"

  mk_plan "$r" 'issue: 5' "$ROW_A" "$ROW_B"
  o=$(pchkr "$r" kb/plans/2026-11-08-s.md); rc=$?
  eq "$rc" 65 "[plan-trace] a story plan with no focus: in its frontmatter: rc 65"
  has "$o" 'the frontmatter has no `focus: P<n>`' "[plan-trace] …it says so"

  mk_plan "$r" 'focus: P1' "$ROW_A" '| B | Delivers AC3: three | later |'
  o=$(pchkr "$r" kb/plans/2026-11-08-s.md); rc=$?
  eq "$rc" 65 "[plan-trace] a row whose Link cell names no PR, a check links problem: rc 65"
  has "$o" 'links: row B: its Link cell names no PR' "[plan-trace] …check plan carries the check links problem"

  # a plan whose intent is a task, or has no type: today's result (rc 0) and the findings as WARNING lines, never red
  mk_plan "$r" 'issue: 5' "$ROW_A" '| B | the plan of the rest | — |'
  sed -i 's/^type: story$/type: task/' "$r/kb/intent/2026-11-08-s.md"   # not a break: a task intent is the input of this case
  o=$(pchk "$r" kb/plans/2026-11-08-s.md); rc=$?
  eq "$rc" 0 "[plan-trace] the same bad plan under a task intent: rc 0"
  has "$o" 'WARNING kb/plans/2026-11-08-s.md:15: row B: Must be true starts neither' "[plan-trace] …the row as a WARNING"
  has "$o" 'WARNING kb/plans/2026-11-08-s.md:1: AC3 is delivered by no row that is not dropped' "[plan-trace] …the AC as a WARNING"
  has "$o" 'WARNING kb/plans/2026-11-08-s.md:1: the frontmatter has no `focus: P<n>`' "[plan-trace] …the focus as a WARNING"
  sed -i '/^type: task$/d' "$r/kb/intent/2026-11-08-s.md"   # not a break: an intent with no type is the input of this case
  o=$(pchk "$r" kb/plans/2026-11-08-s.md); rc=$?
  eq "$rc" 0 "[plan-trace] under an intent with no type: rc 0"
  has "$o" 'WARNING kb/plans/2026-11-08-s.md:15: row B: Must be true starts neither' "[plan-trace] …the row as a WARNING"
  o=$(pchk "$r" kb/plans/2026-11-08-nope.md); rc=$?
  eq "$rc" 66 "[plan-trace] a plan that does not exist: rc 66"

  # check links runs the trace on the plans changed in this change: red for a story plan, a WARNING for any other
  r="$TMP/plan-links"
  mk_repo "$r" story
  mk_spec "$r" "$GOAL3" "$CRIT3" "$OOS_OK"
  mk_plan "$r" 'issue: 5' "$ROW_A" '| B | the plan of the rest | — |'
  git_ -C "$r" add -A; git_ -C "$r" commit -q -m base; git_ -C "$r" update-ref refs/remotes/origin/main HEAD
  o=$(lchk "$r"); rc=$?
  eq "$rc" 0 "[plan-trace] check links: a bad story plan already on the base is not judged: rc 0"
  hasnt "$o" 'plan trace' "[plan-trace] …it prints nothing of the trace"
  printf '\n' >> "$r/kb/plans/2026-11-08-s.md"
  o=$(lchkr "$r"); rc=$?
  eq "$rc" 65 "[plan-trace] check links: the same story plan changed: rc 65"
  has "$o" 'FAIL kb/plans/2026-11-08-s.md:15: plan trace: row B: Must be true starts neither' "[plan-trace] …it names the row"
  has "$o" 'FAIL kb/plans/2026-11-08-s.md:1: plan trace: the frontmatter has no `focus: P<n>`' "[plan-trace] …and the focus"
  hasnt "$o" 'takes the lean columns' "[plan-trace] …a blank line is no change to a row cell: the earlier columns stay a warning"
  has "$o" 'links: 3 failing' "[plan-trace] …3 failing: the row, the AC and the focus"
  sed -i 's/^type: story$/type: task/' "$r/kb/intent/2026-11-08-s.md"   # not a break: a task intent is the input of this case
  o=$(lchk "$r"); rc=$?
  eq "$rc" 0 "[plan-trace] check links: the same plan under a task intent: rc 0, an older plan never turns red"
  has "$o" 'WARNING kb/plans/2026-11-08-s.md:1: plan trace: 3 finding(s), the first: the frontmatter has no `focus: P<n>`' "[plan-trace] …one WARNING for the plan"
  has "$o" 'links: 0 failing' "[plan-trace] …none failing"
  mk_plan "$r" 'focus: P1' "$ROW_A" "$ROW_B"
  o=$(lchk "$r"); rc=$?
  eq "$rc" 0 "[plan-trace] check links: a changed plan that traces: rc 0"
  hasnt "$o" 'plan trace' "[plan-trace] …no trace line"
}

fam_keypr() {
  echo "== [key-branch-pr] a key branch finds its intent at PR time: the story gate, the Plan row line, --closes, the stage stem =="
  local r="$TMP/kpr" wk="$TMP/kpr-key" ws="$TMP/kpr-stem" o rc
  mk_repo "$r" story
  sed -i 's/^type: story$/type: story\nissue: 7\nkey: ACM-7\nplan: kb\/plans\/2026-11-08-s.md#R/' "$r/kb/intent/2026-11-08-s.md"   # not a break: the intent create-intent leaves under issue.code
  local bare="$OOS_OK
- Sprints, with no quote."
  mk_spec "$r" "$GOAL3" "$CRIT3" "$bare"
  git_ -C "$r" add -A && git_ -C "$r" commit -qm base
  git_ -C "$r" worktree add -q -b intent/ACM-7-s "$wk"; git_ -C "$r" worktree add -q -b intent/2026-11-08-s "$ws"
  printf 'the summary\n' > "$TMP/ksum.md"; printf 'ok\n' > "$TMP/kev.txt"
  kop() { (cd "$1" && python3 "$OPENPR" --title "feat(x): s" --summary-file "$TMP/ksum.md" --evidence-file "$TMP/kev.txt" --dry-run 2>&1); }
  o=$(capped kop "$ws"); rc=$?
  eq "$rc" 6 "[key-branch-pr] control: open_pr.py on the stem branch intent/2026-11-08-s, an unquoted out-of-scope line: rc 6"
  o=$(capped kop "$wk"); rc=$?
  eq "$rc" 6 "[key-branch-pr] the same story on the key branch intent/ACM-7-s: rc 6, the story gate runs"
  has "$o" '- out-of-scope line `- Sprints, with no quote.` holds neither' "[key-branch-pr] …naming the line"
  mk_spec "$wk" "$GOAL3" "$CRIT3" "$OOS_OK"
  o=$(kop "$wk"); rc=$?
  eq "$rc" 0 "[key-branch-pr] every line quoted: rc 0 on the key branch"
  has "$o" 'Plan row: `R` of `kb/plans/2026-11-08-s.md`' "[key-branch-pr] …the Plan row line is kept"
  # a json.py at the repository root must not shadow the standard library of the helpers' python (python3 -I): the guess still works
  printf 'raise SystemExit("a repository json.py ran")\n' > "$wk/json.py"
  o=$( (cd "$wk" && cenv PATH="$PATH" bash "$PLUGIN/scripts/open-pr.sh" --title "feat(x): s" --summary "$TMP/ksum.md" --evidence "$TMP/kev.txt" --base main --dry-run 2>&1) ); rc=$?
  eq "$rc" 0 "[key-branch-pr] open-pr.sh --dry-run on the key branch: rc 0"
  has "$o" "open-pr: --closes 7 read from $wk/kb/intent/2026-11-08-s.md (branch intent/ACM-7-s)" "[key-branch-pr] …--closes 7 guessed from the intent its key: names"
  has "$o" 'Closes #7' "[key-branch-pr] …and the body closes #7"
  local snb="$TMP/kpr-sn"; mkdir -p "$snb"
  printf '#!/bin/sh\n[ "$1" = --help ] && { echo "usage: session-notify [--intent <stem> --stage <s>]"; exit 0; }\nprintf "%%s\\n" "$*" >> "$SN_LOG"\n' > "$snb/session-notify"; chmod +x "$snb/session-notify"
  : > "$TMP/kpr-sn.log"
  (cd "$wk" && cenv PATH="$snb:$PATH" SN_LOG="$TMP/kpr-sn.log" bash "$PLUGIN/scripts/stage-signal.sh" review)
  eq "$(cat "$TMP/kpr-sn.log")" "--intent 2026-11-08-s --stage review 2026-11-08-s: review round started" "[key-branch-pr] stage-signal.sh on the key branch sends the intent's stem 2026-11-08-s"
}

# rr_repo <dir> <intent type> <status> <Trust touches cell> <spec frontmatter line> [<intent extra line>] — a repository: the intent
# kb/intent/2026-11-08-s.md, its spec and its plan (one row A with that Trust touches cell), no record
rr_repo() {
  local d=$1
  rm -rf "$d"; git_ init -q -b main "$d"; mkdir -p "$d/kb/intent" "$d/kb/specs" "$d/kb/plans" "$d/kb/records"
  printf -- '---\ntype: %s\nstatus: %s\nfocus: P1\nspec: kb/specs/2026-11-08-s.md\nplan: kb/plans/2026-11-08-s.md\n%s\ndescription: "fixture"\n---\n\n# fixture\n' \
    "$2" "$3" "${6-}" > "$d/kb/intent/2026-11-08-s.md"
  printf -- '---\ndescription: "fixture"\n%s\n---\n\n# fixture spec\n' "$5" > "$d/kb/specs/2026-11-08-s.md"
  printf -- '---\ndescription: "fixture"\nfocus: P1\n---\n\n# Plan\n\nIntent: kb/intent/2026-11-08-s.md · Spec: kb/specs/2026-11-08-s.md\n\n## Rows\n\n| Row | Must be true | Trust touches | Link |\n|---|---|---|---|\n| A | Delivers AC1: one | %s | — |\n' \
    "$4" > "$d/kb/plans/2026-11-08-s.md"
}
# rr_rec <file> <story> <ac> <command> <utc> <log id> <output> — a record; an empty argument leaves that field out
rr_rec() {
  { printf -- '---\ndescription: "fixture"\n'
    [ -n "$2" ] && printf 'story: %s\n' "$2"; [ -n "$3" ] && printf 'ac: %s\n' "$3"
    printf -- '---\n\n# Real run\n\n## Run 1\n\n'
    [ -n "$4" ] && printf 'Command: `%s`\n' "$4"; [ -n "$5" ] && printf 'UTC: %s\n' "$5"; [ -n "$6" ] && printf 'Run log id: %s\n' "$6"
    [ -n "$7" ] && printf '\n```text\n%s\n```\n' "$7"; return 0; } > "$1"
}
HASH='#'   # the issue marker, kept out of the file as one literal (the public-tree scan reads `#<n>` as a reference)
RR_BATON='baton batons/x.sh Stops: none'
RR_FILE=kb/records/2026-11-09-s-real-run.md
rchk()  { (cd "$1" && python3 "$KBPY" check 2>&1); }
rchkr() { (cd "$1" && capped python3 "$KBPY" check 2>&1); }   # a red-expected run

fam_real_run() {
  echo "== [real-run-missing] [real-run-ok] a story that asks a real run closes with its record =="
  local r="$TMP/rr" o rc
  rr_repo "$r" story done "$RR_BATON" ""
  o=$(rchkr "$r"); rc=$?
  eq "$rc" 65 "[real-run-missing] a done story whose plan holds a baton touch, no record: rc 65"
  has "$o" '- kb/intent/2026-11-08-s.md: status is done, but no kb/records/<date>-<slug>-real-run.md names this story (its plan kb/plans/2026-11-08-s.md row A holds a baton touch); write one (kb.py new real-run <slug>) with `story: kb/intent/2026-11-08-s.md`' "[real-run-missing] …it names the intent and what is missing"
  rr_repo "$r" story done 'run kit:deploy Stops: secrets' ""
  o=$(rchkr "$r"); rc=$?
  eq "$rc" 65 "[real-run-missing] a run touch asks one too: rc 65"
  has "$o" 'row A holds a run touch' "[real-run-missing] …named as a run touch"
  rr_repo "$r" story done 'Baton batons/x.sh Stops: none' ""
  o=$(rchkr "$r"); rc=$?
  eq "$rc" 65 "[real-run-missing] a Baton touch, spelled with a capital: rc 65"
  rr_repo "$r" story done 'none' 'real_run: "Required"  '
  o=$(rchkr "$r"); rc=$?
  eq "$rc" 65 "[real-run-missing] real_run: \"Required\" with quotes and trailing spaces: rc 65"
  rr_repo "$r" story done 'none' "real_run: required"
  o=$(rchkr "$r"); rc=$?
  eq "$rc" 65 "[real-run-missing] a spec that says real_run: required, a plan with no such touch: rc 65"
  has "$o" 'its spec kb/specs/2026-11-08-s.md says `real_run: required`' "[real-run-missing] …naming the spec"
  rr_repo "$r" story done "script plugins/x/y.sh; $RR_BATON" ""
  o=$(rchkr "$r"); rc=$?
  eq "$rc" 65 "[real-run-missing] a baton touch after another touch in the cell: rc 65"
  rr_repo "$r" story done "$RR_BATON" ""
  rr_rec "$r/$RR_FILE" kb/intent/2026-11-08-other.md AC1 'baton go kit:x' 2026-11-09T10:30:00Z run-7f3a ok
  o=$(rchkr "$r"); rc=$?
  eq "$rc" 65 "[real-run-missing] a complete record of another story does not count: rc 65"
  has "$o" 'no kb/records/<date>-<slug>-real-run.md names this story' "[real-run-missing] …the story still has none"
  hasnt "$o" "$RR_FILE:" "[real-run-missing] …and the record itself is not red"

  # a record that misses a field: red, naming it
  local f=kb/intent/2026-11-08-s.md
  rr_rec "$r/$RR_FILE" '' AC1 'baton go kit:x' 2026-11-09T10:30:00Z run-7f3a ok
  o=$(rchkr "$r"); rc=$?
  eq "$rc" 65 "[real-run-missing] a record with no story: rc 65"
  has "$o" "- $RR_FILE: the frontmatter has no \`story:\`" "[real-run-missing] …naming story:"
  rr_rec "$r/$RR_FILE" $f '' 'baton go kit:x' 2026-11-09T10:30:00Z run-7f3a ok
  o=$(rchkr "$r"); rc=$?
  eq "$rc" 65 "[real-run-missing] a record with no AC ids: rc 65"
  has "$o" "- $RR_FILE: the frontmatter has no \`ac:\`" "[real-run-missing] …naming ac:"
  rr_rec "$r/$RR_FILE" $f AC1 '' 2026-11-09T10:30:00Z run-7f3a ok
  o=$(rchkr "$r"); rc=$?
  eq "$rc" 65 "[real-run-missing] a run with no command: rc 65"
  has "$o" "- $RR_FILE: \`## Run 1\` has no \`Command:\` line" "[real-run-missing] …naming Command:"
  rr_rec "$r/$RR_FILE" $f AC1 'baton go kit:x' '' run-7f3a ok
  o=$(rchkr "$r"); rc=$?
  eq "$rc" 65 "[real-run-missing] a run with no UTC time: rc 65"
  has "$o" "- $RR_FILE: \`## Run 1\` has no \`UTC:\` line" "[real-run-missing] …naming UTC:"
  rr_rec "$r/$RR_FILE" $f AC1 'baton go kit:x' 'yesterday' run-7f3a ok
  o=$(rchkr "$r"); rc=$?
  eq "$rc" 65 "[real-run-missing] a UTC time that is not one: rc 65"
  has "$o" '`UTC:` is not a UTC time (YYYY-MM-DDTHH:MM:SSZ)' "[real-run-missing] …saying so"
  rr_rec "$r/$RR_FILE" $f AC1 'baton go kit:x' 2026-11-09T10:30:00Z '' ok
  o=$(rchkr "$r"); rc=$?
  eq "$rc" 65 "[real-run-missing] a run with no run log id: rc 65"
  has "$o" "- $RR_FILE: \`## Run 1\` has no \`Run log id:\` line" "[real-run-missing] …naming Run log id:"
  rr_rec "$r/$RR_FILE" $f AC1 'baton go kit:x' 2026-11-09T10:30:00Z run-7f3a ''
  o=$(rchkr "$r"); rc=$?
  eq "$rc" 65 "[real-run-missing] a run with no output excerpt: rc 65"
  has "$o" "- $RR_FILE: \`## Run 1\` has no output excerpt (a fenced block)" "[real-run-missing] …naming the excerpt"
  rr_rec "$r/$RR_FILE" $f AC1 'baton go kit:x' 2026-11-09T10:30:00Z run-7f3a ok
  printf '\n## Run 2\n\nCommand: `kb.py focus P1`\nUTC: 2026-11-09T10:40:00Z\n\n```text\nP1\n```\n' >> "$r/$RR_FILE"
  o=$(rchkr "$r"); rc=$?
  eq "$rc" 65 "[real-run-missing] a second run with no run log id: rc 65"
  has "$o" "- $RR_FILE: \`## Run 2\` has no \`Run log id:\` line" "[real-run-missing] …it names the second run"
  hasnt "$o" 'Run 1' "[real-run-missing] …and not the first"

  rr_repo "$r" story done "$RR_BATON" ""
  rr_rec "$r/$RR_FILE" '#' AC1 'baton go kit:x' 2026-11-09T10:30:00Z run-7f3a ok
  o=$(rchkr "$r"); rc=$?
  eq "$rc" 65 "[real-run-missing] a story with no issue: is not named by a record saying story: #: rc 65"
  has "$o" 'no kb/records/<date>-<slug>-real-run.md names this story' "[real-run-missing] …the story has no record"

  # the record in its shape: no red
  rr_rec "$r/$RR_FILE" $f 'AC1, AC2' 'baton go kit:x' 2026-11-09T10:30:00Z run-7f3a ok
  o=$(rchk "$r"); rc=$?
  eq "$rc" 0 "[real-run-ok] the record names the story by its path: rc 0"
  has "$o" "real-run: kb/intent/2026-11-08-s.md has its record $RR_FILE" "[real-run-ok] …the check says which record it found"
  rr_rec "$r/$RR_FILE" $f AC1 'baton go kit:x' 2026-11-09T10:30:00Z run-7f3a ok
  printf '\n## Runtime notes\n\nSlow, 40 s.\n' >> "$r/$RR_FILE"
  o=$(rchk "$r"); rc=$?
  eq "$rc" 0 "[real-run-ok] a free-text section named Runtime notes is not a run: rc 0"
  rr_rec "$r/$RR_FILE" $f AC1 'baton go kit:x' 2026-11-09T10:30:00Z run-7f3a ok
  printf '\n## Run2\n\nno fields here\n' >> "$r/$RR_FILE"
  o=$(rchkr "$r"); rc=$?
  eq "$rc" 65 "[real-run-missing] a section ## Run2 (no space) is a run too: rc 65"
  has "$o" '`## Run2` has no `Command:` line' "[real-run-missing] …it is judged and named"
  rr_repo "$r" story done "$RR_BATON" "" 'issue: 12'
  rr_rec "$r/$RR_FILE" "${HASH}12" AC1 'baton go kit:x' 2026-11-09T10:30:00Z run-7f3a ok
  o=$(rchk "$r"); rc=$?
  eq "$rc" 0 "[real-run-ok] a record naming the story by #<issue>: rc 0"
  has "$o" "has its record $RR_FILE" "[real-run-ok] …found"
  rr_repo "$r" story done "$RR_BATON" "" 'key: KIT-12'
  rr_rec "$r/$RR_FILE" KIT-12 AC1 'baton go kit:x' 2026-11-09T10:30:00Z run-7f3a ok
  o=$(rchk "$r"); rc=$?
  eq "$rc" 0 "[real-run-ok] a record naming the story by its key: rc 0"
  has "$o" "has its record $RR_FILE" "[real-run-ok] …found"

  # no new red: what asks no real run, or is not a done story
  rr_repo "$r" story live "$RR_BATON" ""
  o=$(rchk "$r"); rc=$?
  eq "$rc" 0 "[real-run-ok] a story still open, no record: rc 0"
  rr_repo "$r" task done "$RR_BATON" "real_run: required"
  o=$(rchk "$r"); rc=$?
  eq "$rc" 0 "[real-run-ok] a done task intent, no record: rc 0"
  rr_repo "$r" bug done "$RR_BATON" ""
  o=$(rchk "$r"); rc=$?
  eq "$rc" 0 "[real-run-ok] a done bug intent, no record: rc 0"
  rr_repo "$r" story done 'none' "real_run: optional"
  o=$(rchk "$r"); rc=$?
  eq "$rc" 0 "[real-run-ok] a done story whose plan and spec ask no real run: rc 0"
  hasnt "$o" 'real-run' "[real-run-ok] …and the check says nothing of one"
  rr_repo "$r" story done 'script plugins/x/y.sh; config .vibemaestro/sdlc.json (signs again)' ""
  o=$(rchk "$r"); rc=$?
  eq "$rc" 0 "[real-run-ok] script and config touches ask no real run: rc 0"
  rr_repo "$r" story done "$RR_BATON" ""
  sed -i 's/| — |$/| dropped: not needed |/' "$r/kb/plans/2026-11-08-s.md"   # not a break: a dropped row is the input of this case
  o=$(rchk "$r"); rc=$?
  eq "$rc" 0 "[real-run-ok] a baton touch in a dropped row asks no real run: rc 0"

  # the template: the intent of the same <date>-<slug> is prefilled
  local tpl=kb/records/2026-11-08-s-real-run.md
  rr_repo "$r" story done "$RR_BATON" ""
  o=$(cd "$r" && python3 "$KBPY" new real-run s --date 2026-11-08 2>&1); rc=$?
  eq "$rc" 0 "[real-run-ok] kb.py new real-run s: rc 0"
  has "$o" 'created kb/records/2026-11-08-s-real-run.md' "[real-run-ok] …it writes kb/records/<date>-<slug>-real-run.md"
  has "$(cat "$r/$tpl")" 'story: kb/intent/2026-11-08-s.md' "[real-run-ok] …naming the intent of that slug"
  o=$(rchkr "$r"); rc=$?
  eq "$rc" 65 "[real-run-missing] the template as written, nothing filled: rc 65"
  has "$o" "- $tpl: the frontmatter has no \`ac:\`" "[real-run-missing] …the AC ids are still to fill"
  has "$o" "- $tpl: \`## Run 1\` has no \`Run log id:\` line" "[real-run-missing] …and the run log id"
  o=$(cd "$r" && capped python3 "$KBPY" new real-run s --date 2026-11-08 2>&1); rc=$?
  eq "$rc" 6 "[real-run-ok] a second kb.py new real-run s the same day is not written over: rc 6"
}

# ── the story the owner approves (v2), the spec derived from it, the lean plan ───────────────────────────────────────────
# mk_story <dir> — the story intent kb/intent/2026-11-12-v.md in the vi labels, AC1 to AC3 numbered across two groups. Each part
# comes from a variable when it is set (SV_LINE, SV_CTX, SV_AC, SV_ND, SV_APP, SV_Q; empty drops the part): each case writes the
# input it needs, nothing is edited.
mk_story() {
  mkdir -p "$1/kb/intent" "$1/kb/specs"
  cat > "$1/kb/intent/2026-11-12-v.md" <<EOF
---
type: story
focus: P1
spec: kb/specs/2026-11-12-v.md
description: "fixture"
---

# fixture

*Ghi lại bằng lời người đặt — 2026-11-12.*

### Story: anh duyệt một story ngắn
*Loại: story · Trọng tâm: P1*

${SV_LINE-**Là** chủ của đội, **tôi muốn** duyệt bằng một story ngắn, **để** tôi duyệt nhanh.}

${SV_CTX-**Bối cảnh.** Spec dài 20 KB, review "2–3" vòng, tốn \$85.}

${SV_AC-**Tiêu chí chấp nhận (AC)**

*Story (anh đọc)*
1. Khi có việc, anh nhận **một story** ngắn.
2. Nội dung \`kb/\` mới viết tiếng Việt.

*Spec*
3. Mỗi AC có tiêu chí trỏ về nó.}

${SV_ND-**Không làm**
- Không dịch kb cũ.}

${SV_APP-**Khẩu phần.** Khoảng 1 ngày.}

${SV_Q-}
EOF
}
# mk_spec2 <dir> <criteria> — the v2 spec kb/specs/2026-11-12-v.md of that story; SP_GOAL, SP_RISKS and SP_EXTRA (a section
# after the others) from variables when set
mk_spec2() {
  cat > "$1/kb/specs/2026-11-12-v.md" <<EOF
---
description: "fixture"
---

# fixture

Intent: kb/intent/2026-11-12-v.md

## Mục tiêu

${SP_GOAL-1. Anh duyệt nhanh một story ngắn. → AC1, AC2, AC3}

## Ràng buộc

- Không thêm phụ thuộc.

## Tiêu chí chấp nhận

$2

## Rủi ro cần test phủ

${SP_RISKS-1. Story bị đỏ nhầm.}

## Cần làm rõ

Không có.
${SP_EXTRA-}
EOF
}
CRIT_V2='1. Khi có việc, thì anh nhận một story ngắn. → AC1
2. Khi máy kiểm đọc story, thì nó đọc AC theo số anh viết. → AC2, AC3'
ichk()  { (cd "$1" && python3 "$KBPY" check intent 2026-11-12-v "${@:2}" 2>&1); }
ichkr() { (cd "$1" && capped python3 "$KBPY" check intent 2026-11-12-v "${@:2}" 2>&1); }   # a red-expected run
schk()  { (cd "$1" && python3 "$KBPY" check spec 2026-11-12-v "${@:2}" 2>&1); }
schkr() { (cd "$1" && capped python3 "$KBPY" check spec 2026-11-12-v "${@:2}" 2>&1); }

fam_story_v2() {
  echo "== [story-v2] the story the owner approves: its parts are red when missing; code, paths, length and questions warn =="
  local r="$TMP/sv2" o rc
  git_ init -q -b main "$r"; mk_story "$r"
  o=$(ichk "$r"); rc=$?
  eq "$rc" 0 "[story-v2] control: a v2 story with a bare kb/, a quote, an en dash and AC numbered across groups: rc 0"
  has "$o" 'passes its story: 3 AC (AC1, AC2, AC3).' "[story-v2] …its AC are the numbers the owner wrote"
  hasnt "$o" 'WARNING' "[story-v2] …and nothing warns (a bare directory is not a file name)"

  local part want
  for part in "SV_LINE|the story has no As … I want … so that … line" "SV_CTX|the story has no Context part" \
              "SV_AC|the story has no Acceptance criteria part" "SV_ND|the story has no Out of scope part" \
              "SV_APP|the story has no Appetite part"; do
    want=${part#*|}; part=${part%%|*}
    o=$(env "$part=" bash -c "$(declare -f mk_story); mk_story '$r'"; ichkr "$r"); rc=$?
    eq "$rc" 65 "[story-v2] $part dropped: rc 65"
    has "$o" "- $want" "[story-v2] …it names the missing part"
  done
  SV_CTX='**Bối cảnh.**' mk_story "$r"; o=$(ichkr "$r"); rc=$?
  eq "$rc" 65 "[story-v2] a context label with nothing after it: rc 65"
  has "$o" '- the story'"'"'s Context part is empty' "[story-v2] …named empty"

  SV_AC=$'**Tiêu chí chấp nhận (AC)**\n1. một\n2. hai\n2. ba' mk_story "$r"; o=$(ichkr "$r"); rc=$?
  eq "$rc" 65 "[story-v2] an AC number written twice: rc 65"
  has "$o" '- AC2 appears twice: number the AC once across the groups' "[story-v2] …it names the AC"
  SV_AC=$'**Tiêu chí chấp nhận (AC)**\n- một\n- hai' mk_story "$r"; o=$(ichkr "$r"); rc=$?
  eq "$rc" 65 "[story-v2] AC written as bullets with no number: rc 65"
  has "$o" "- the story's AC are not numbered" "[story-v2] …named"

  SV_Q=$'**Câu hỏi**\n1. Ai viết? Đề xuất: (a), lý do: nhanh.\n2. Ở đâu? Đề xuất: (a), vì gọn.\n3. Mấy vòng? Đề xuất: 1, lý do: rẻ.' mk_story "$r"
  o=$(ichk "$r"); rc=$?
  eq "$rc" 0 "[story-v2] three questions, each with a recommendation and a reason: rc 0"
  hasnt "$o" 'WARNING' "[story-v2] …no warning"
  SV_Q=$'**Câu hỏi**\n1. a? Đề xuất: x, vì y.\n2. b? Đề xuất: x, vì y.\n3. c? Đề xuất: x, vì y.\n4. d? Đề xuất: x, vì y.' mk_story "$r"
  o=$(ichkr "$r"); rc=$?
  eq "$rc" 65 "[story-v2] four open questions: rc 65"
  has "$o" '- the story asks 4 questions: at most 3' "[story-v2] …named"
  SV_Q=$'**Câu hỏi**\n1. Ai viết story?' mk_story "$r"; o=$(ichk "$r"); rc=$?
  eq "$rc" 0 "[story-v2] a question with no recommendation and no reason only warns: rc 0"
  has "$o" 'question 1 has no recommendation and no reason' "[story-v2] …the warning names the question"
  SV_Q=$'**Quyết định của anh**\n1. a\n2. b\n3. c\n4. d' mk_story "$r"; o=$(ichk "$r"); rc=$?
  eq "$rc" 0 "[story-v2] four answered questions under the decisions: rc 0 (not counted)"
  SV_Q=$'## Câu hỏi\n\n1. Ai viết?\n   - Đề xuất: (a)\n   - Lý do: nhanh\n2. Ở đâu?\n   - Đề xuất: (a)\n   - Lý do: gọn\n3. Mấy vòng?\n   - Đề xuất: 1\n   - Lý do: rẻ' mk_story "$r"
  o=$(ichk "$r"); rc=$?
  eq "$rc" 0 "[story-v2] three questions under a heading, each with nested recommendation and reason bullets: rc 0 (3, not 9)"
  hasnt "$o" 'WARNING' "[story-v2] …the nested bullets are each question's recommendation and reason"
  local nfd; nfd=$(python3 -c 'import unicodedata; print(unicodedata.normalize("NFD", "**Bối cảnh.** Spec dài."))')
  SV_CTX="$nfd" mk_story "$r"; o=$(ichk "$r"); rc=$?
  eq "$rc" 0 "[story-v2] a label typed in decomposed Unicode (NFD) is the same label: rc 0"

  SV_CTX=$'**Bối cảnh.** Chạy:\n\n```\ngit push origin main\n```\n\nVà sửa `scripts/kb.py`, `git push origin`, tệp README.md.' mk_story "$r"
  o=$(ichk "$r"); rc=$?
  eq "$rc" 0 "[story-v2] code, a command, a path and a file name the owner wrote: rc 0, warnings only"
  has "$o" 'a code block in the story: the owner reads no code' "[story-v2] …the code block warns"
  has "$o" 'scripts/kb.py looks like a file name or a command' "[story-v2] …the path warns"
  has "$o" '`git push origin` looks like a file name or a command' "[story-v2] …the command warns"
  has "$o" 'README.md looks like a file name or a command' "[story-v2] …the bare file name warns"
  hasnt "$o" 'git push origin main looks like' "[story-v2] …a line inside the code block is not judged again"

  SV_CTX="**Bối cảnh.** $(printf 'chữ %.0s' $(seq 1 900))" mk_story "$r"; o=$(ichk "$r"); rc=$?
  eq "$rc" 0 "[story-v2] a story over 3500 characters only warns: rc 0"
  has "$o" 'over 3500 (about one phone screen)' "[story-v2] …the warning says the limit"

  SV_CTX=$'**Bối cảnh.** Sửa `kb/specs/x.md`.' SV_Q=$'**Câu hỏi**\n1. Ai viết?' mk_story "$r"
  o=$(ichk "$r" --strict); rc=$?
  eq "$rc" 0 "[story-v2] --strict (what open-pr runs) keeps a path and a bare question as warnings: rc 0"
  has "$o" 'kb/specs/x.md looks like a file name' "[story-v2] …the path still warns"

  SV_AC=$'**Tiêu chí chấp nhận (AC)**\n1. **AC1** một\n2. **AC2** hai\n\n*Spec*\n1. **AC3** ba' mk_story "$r"; o=$(ichk "$r"); rc=$?
  eq "$rc" 0 "[story-v2] a group restarting at 1 whose items carry **AC<n>: the ids are the AC ids, rc 0"
  has "$o" '3 AC (AC1, AC2, AC3)' "[story-v2] …three AC"
  SV_AC=$'**Tiêu chí chấp nhận (AC)**\n1. **AC1** một\n2. **AC1** hai' mk_story "$r"; o=$(ichkr "$r"); rc=$?
  eq "$rc" 65 "[story-v2] **AC1** written on two items: rc 65"
  has "$o" '- AC1 appears twice' "[story-v2] …named"
  SV_AC=$'**Tiêu chí chấp nhận (AC)**\n- **AC1:** một\n- **AC2:** hai' mk_story "$r"; o=$(ichk "$r"); rc=$?
  eq "$rc" 0 "[story-v2] AC as bullets that carry **AC<n>:** ids: rc 0"
  SV_AC=$'**Tiêu chí chấp nhận (AC)**\n1. một\n**Không làm** gì thêm thì AC sau vẫn là AC.\n2. hai\n3. ba' mk_story "$r"; o=$(ichk "$r"); rc=$?
  eq "$rc" 0 "[story-v2] a sentence that opens with a bold label word inside the AC is text: rc 0"
  has "$o" '3 AC (AC1, AC2, AC3)' "[story-v2] …the AC after it are kept"
  SV_ND=$'**Ngoài phạm vi**\n- Không dịch kb cũ.' mk_story "$r"; o=$(ichk "$r"); rc=$?
  eq "$rc" 0 "[story-v2] the out-of-scope part labelled with the vi preset's own term: rc 0"
  SV_CTX='**Bối cảnh** — spec dài.' SV_APP='**Khẩu phần** 1 ngày' mk_story "$r"; o=$(ichk "$r"); rc=$?
  eq "$rc" 0 "[story-v2] run-in labels with no . or : that open their paragraph: rc 0"
  SV_AC=$'**Tiêu chí chấp nhận (AC)**\n1. một\n   **Không làm:** thêm gì, vẫn là AC1.\n2. hai\n3. ba' mk_story "$r"; o=$(ichk "$r"); rc=$?
  eq "$rc" 0 "[story-v2] a bold label word on an item's indented continuation line is text: rc 0"
  has "$o" '3 AC (AC1, AC2, AC3)' "[story-v2] …the AC after it are kept"
  printf -- '---\ntype: story\nfocus: P1\ndescription: "fixture"\n---\n\n# f\n\n## Story\n\nAs a maintainer, I want x, so that y.\n\n## Acceptance criteria\n\n1. **AC1: one.** Given, when, then. ("lời một")\n\n## Not doing\n\n- nothing ("không làm gì")\n\n## Measure\n\n**Appetite:** about one day; the spec names every AC.\n' > "$r/kb/intent/2026-11-12-v.md"
  o=$(ichk "$r"); rc=$?
  eq "$rc" 0 "[story-v2] a first card whose Measure opens with an appetite run-in lead stays the first card: rc 0"
  has "$o" 'passes its card' "[story-v2] …judged as the first card"
  printf -- '---\ntype: story\nfocus: P1\ndescription: "fixture"\n---\n\n# f\n\nAs the owner, I want a short story, so that I approve fast.\n\n## Context\n\nc\n\n## Acceptance criteria\n\n1. One short story.\n\n## Out of scope\n\n- Old kb.\n' > "$r/kb/intent/2026-11-12-v.md"
  o=$(ichkr "$r"); rc=$?
  eq "$rc" 65 "[story-v2] an en heading story with no appetite: rc 65"
  has "$o" '- the story has no Appetite part' "[story-v2] …named as the story's missing part, not as the first card's"
  printf -- '---\ntype: story\nfocus: P1\ndescription: "fixture"\n---\n\n# f\n\nAs the owner, I want a short story, so that I approve fast.\n\n## Context\n\nc\n\n## Acceptance criteria\n\n1. One short story.\n\n## Not doing\n\n- Old kb.\n\n## Appetite\n\nOne day.\n' > "$r/kb/intent/2026-11-12-v.md"
  o=$(ichk "$r"); rc=$?
  eq "$rc" 0 "[story-v2] an en heading story whose out-of-scope heading is ## Not doing: the story the owner approves, rc 0"
  has "$o" 'passes its story: 1 AC (AC1).' "[story-v2] …not read as the first card"
  printf -- '---\ntype: story\nfocus: P1\ndescription: "fixture"\n---\n\n# f\n\nAs the owner, I want a short story, so that I approve fast.\n\n## Context\n\nc\n\n## Acceptance criteria\n\n1. One short story.\n\n## Out of scope\n\n- Old kb.\n\n## Appetite\n\nOne day.\n\n## Measure\n\nThe owner approves in minutes.\n' > "$r/kb/intent/2026-11-12-v.md"
  o=$(ichk "$r"); rc=$?
  eq "$rc" 0 "[story-v2] the story the owner approves with a ## Measure section added: still that story, rc 0"
  has "$o" 'passes its story: 1 AC (AC1).' "[story-v2] …its appetite outside Measure decides"
  printf -- '---\ntype: story\nfocus: P1\ndescription: "fixture"\n---\n\n# f\n\n**As** the owner, **I want** x, **so that** y.\n\n```\n## Measure\n```\n\n**Context.** c\n\n**Acceptance criteria**\n1. one\n\n**Out of scope.** none\n\n**Appetite.** a day\n' > "$r/kb/intent/2026-11-12-v.md"
  o=$(ichk "$r"); rc=$?
  eq "$rc" 0 "[story-v2] a ## Measure line inside a code block is not a section: the story, rc 0"
  printf -- '---\ntype: story\nfocus: P1\ndescription: "fixture"\n---\n\n# f\n\n## Story\n\nAs a maintainer, I want x, so that y.\n\n**Appetite:** a day.\n\n## Acceptance criteria\n\n1. **AC1: one.** Given, when, then. ("lời một")\n\n## Not doing\n\n- nothing ("không làm gì")\n\n## Measure\n\nm\n\n```\n## Appetite\n```\n' > "$r/kb/intent/2026-11-12-v.md"
  o=$(ichk "$r"); rc=$?
  eq "$rc" 0 "[story-v2] a first card with an appetite run-in in its Story and a fenced ## Appetite in its Measure: the first card, rc 0"
  has "$o" 'passes its card' "[story-v2] …judged as the first card"

  printf -- '---\ntype: story\nfocus: P1\ndescription: "fixture"\n---\n\n## Story\n\n**Là** chủ của đội, **tôi muốn** duyệt nhanh, **để** đỡ tốn.\n\n## Bối cảnh\n\nSpec dài.\n\n## Tiêu chí chấp nhận\n\n### Story (anh đọc)\n1. Anh nhận story ngắn.\n\n### Spec\n2. Mỗi AC có tiêu chí.\n\n## Không làm\n\n- Không dịch kb cũ.\n\n## Khẩu phần\n\nMột ngày.\n' > "$r/kb/intent/2026-11-12-v.md"
  o=$(ichk "$r"); rc=$?
  eq "$rc" 0 "[story-v2] parts as headings beside a ## Story heading, an AC group as a ### Story heading: rc 0"
  has "$o" '2 AC (AC1, AC2)' "[story-v2] …its AC read under the headings"
  printf -- '---\ntype: story\nfocus: P1\ndescription: "fixture"\n---\n\n# fixture\n\nAs the owner, I want a short story, so that I approve fast.\n\n## Context\n\nThe spec was 20 KB.\n\n## Acceptance criteria\n\n1. The owner gets one short story.\n\n## Out of scope\n\n- Old kb.\n\n## Appetite\n\nOne day.\n' > "$r/kb/intent/2026-11-12-v.md"
  o=$(ichk "$r"); rc=$?
  eq "$rc" 0 "[story-v2] an en story written with ## headings, ## Acceptance criteria among them: the v2 story, rc 0"
  has "$o" 'passes its story: 1 AC (AC1).' "[story-v2] …not read as the first card"
  printf -- '---\ntype: story\nfocus: P1\ndescription: "fixture"\n---\n\n# f\n\n## Story\n\nAs a maintainer, I want x, so that y.\n\n## Not doing\n\n- nothing ("không làm gì")\n\n## Measure\n\nm\n' > "$r/kb/intent/2026-11-12-v.md"
  o=$(ichkr "$r"); rc=$?
  eq "$rc" 65 "[story-v2] a first card with no ## Acceptance criteria: rc 65"
  has "$o" '- section `## Acceptance criteria` is missing (a story card' "[story-v2] …judged as the first card, its message"

  cat > "$r/kb/intent/2026-11-12-v.md" <<'EOF'
---
type: story
focus: P1
description: "fixture"
---

# fixture

**As** the owner, **I want** a short story, **so that** I approve fast.

**Context.** The spec was 20 KB.

**Acceptance criteria**
1. The owner gets one short story.
2. Each AC has a criterion.

**Out of scope**
- Old kb.

**Appetite.** One day.

**Questions**
1. Who writes it? Recommend (a), because it is faster.
EOF
  o=$(ichk "$r"); rc=$?
  eq "$rc" 0 "[story-v2] the en labels: rc 0"
  has "$o" 'passes its story: 2 AC (AC1, AC2).' "[story-v2] …its AC read"
  hasnt "$o" 'WARNING' "[story-v2] …the question has a recommendation and a reason"
}

fam_spec_v2() {
  echo "== [spec-v2] a spec derived from a story: five sections, each AC named by a criterion; style only warns =="
  local r="$TMP/spv2" o rc
  git_ init -q -b main "$r"; mk_story "$r"; mk_spec2 "$r" "$CRIT_V2"
  o=$(schk "$r"); rc=$?
  eq "$rc" 0 "[spec-v2] control: five sections, AC1 to AC3 each named, no command: rc 0"
  has "$o" 'passes the spec shape (the five sections of a spec derived from a story)' "[spec-v2] …the v2 shape"
  has "$o" 'story: 3 AC, each named by a criterion.' "[spec-v2] …the AC read from the story"
  hasnt "$o" 'WARNING' "[spec-v2] …no warning"
  o=$(schk "$r" --strict); rc=$?
  eq "$rc" 0 "[spec-v2] …and under --strict (open-pr): rc 0"

  mk_spec2 "$r" '1. Khi có việc, thì anh nhận một story ngắn. → AC1
2. Khi máy kiểm đọc story, thì nó đọc số. → AC2'
  o=$(schkr "$r"); rc=$?
  eq "$rc" 65 "[spec-v2] AC3 named by no criterion: rc 65"
  has "$o" '- AC3 of the story is named by no criterion (`→ AC3`)' "[spec-v2] …it names AC3"
  SP_GOAL='1. Anh duyệt nhanh. → AC1, AC2, AC3, AC9' mk_spec2 "$r" "$CRIT_V2$(printf '\n3. Khi x, thì y. → AC9')"
  o=$(schkr "$r"); rc=$?
  eq "$rc" 65 "[spec-v2] AC9 named in the goal and a criterion, the story has no AC9: rc 65"
  has "$o" '- `## Mục tiêu` names AC9, which is not an AC of the story' "[spec-v2] …the goal's AC9 named"
  has "$o" '- criterion 3 names AC9, which is not an AC of the story' "[spec-v2] …the criterion's AC9 named"

  mk_spec2 "$r" '1. Khi có việc, thì anh nhận story. -> AC1
2. Khi đọc, thì đọc số. -> AC2, AC3'
  o=$(schk "$r"); rc=$?
  eq "$rc" 0 "[spec-v2] an ASCII arrow -> names the AC too: rc 0"
  hasnt "$o" 'names no AC' "[spec-v2] …no criterion warned as naming none"
  mk_spec2 "$r" "$CRIT_V2$(printf '\n3. Khi x, thì y.\n4. The owner reads it. → AC1')"
  o=$(schk "$r" --strict); rc=$?
  eq "$rc" 0 "[spec-v2] a criterion naming no AC and one not written as when … then: warnings, rc 0 even under --strict"
  has "$o" 'criterion 3 names no AC (`→ AC<n>`)' "[spec-v2] …the criterion with no AC warns"
  has "$o" 'criterion 4 is not written as when … then' "[spec-v2] …the one with no when … then warns"

  SP_RISKS='' mk_spec2 "$r" "$CRIT_V2"; o=$(schkr "$r"); rc=$?
  eq "$rc" 65 "[spec-v2] an empty risks section: rc 65"
  has "$o" '- section `## Rủi ro cần test phủ` is empty' "[spec-v2] …named"
  SP_EXTRA=$'\n## Bối cảnh\n\nWhy.' mk_spec2 "$r" "$CRIT_V2"; o=$(schkr "$r"); rc=$?
  eq "$rc" 65 "[spec-v2] an old section in a v2 spec: rc 65"
  has "$o" '- section `## Bối cảnh` is not one of the five' "[spec-v2] …named, the shapes are not mixed"
  printf -- '---\ndescription: "fixture"\n---\n\n# fixture\n\nIntent: kb/intent/2026-11-12-v.md\n\n## Mục tiêu\n\n1. x → AC1\n\n## Rủi ro cần test phủ\n\n1. r\n\n## Tiêu chí chấp nhận\n\n%s\n' "$CRIT_V2" > "$r/kb/specs/2026-11-12-v.md"
  o=$(schkr "$r"); rc=$?
  eq "$rc" 65 "[spec-v2] a v2 spec with no constraints and no open points: rc 65"
  has "$o" '- section `## Ràng buộc` is missing' "[spec-v2] …the constraints named"
  has "$o" '- section `## Cần làm rõ` is missing' "[spec-v2] …the open points named"

  SP_RISKS=$'1. r\n\n```\nkb.py check spec\n```' mk_spec2 "$r" "$CRIT_V2"; o=$(schk "$r"); rc=$?
  eq "$rc" 0 "[spec-v2] a code block in the risks only warns: rc 0"
  has "$o" 'the spec holds a code block: the spec says what, the plan says how' "[spec-v2] …the warning says why"
  SP_RISKS="1. $(printf 'rủi ro %.0s' $(seq 1 1400))" mk_spec2 "$r" "$CRIT_V2"; o=$(schk "$r"); rc=$?
  eq "$rc" 0 "[spec-v2] a spec over 8000 characters only warns: rc 0"
  has "$o" 'over 8000 (about two pages)' "[spec-v2] …the warning says the limit"

  local t="$TMP/spv2task"
  git_ init -q -b main "$t"; mkdir -p "$t/kb/intent" "$t/kb/specs"
  printf -- '---\ntype: task\nfocus: P1\nspec: kb/specs/2026-11-12-v.md\ndescription: "fixture"\n---\n\n# t\n\n## What\n\nx\n\n## Why\n\ny\n\n## Check\n\nz\n' > "$t/kb/intent/2026-11-12-v.md"
  mk_spec2 "$t" '1. Khi x, thì y.'
  o=$(schk "$t" --strict); rc=$?
  eq "$rc" 0 "[spec-v2] a task's spec in the v2 shape: the shape only, no AC to trace: rc 0"
  hasnt "$o" 'story: ' "[spec-v2] …no story line"

  local c="$TMP/spv2cfg"
  git_ init -q -b main "$c"; mkdir -p "$c/.vibemaestro" "$c/kb/specs"
  printf '{"schema": 1, "tokens": {"spec": {"design": "Ràng buộc"}}}\n' > "$c/.vibemaestro/sdlc.json"
  printf -- '---\ndescription: "fixture"\n---\n\n# s\n\n## Bối cảnh\n\nb\n\n## Mục tiêu\n\ng\n\n## Ngoài phạm vi\n\nkhông có\n\n## Inputs and failure cases\n\nnone, because a fixture\n\n## Tiêu chí chấp nhận\n\n1. `true` → ok\n2. PR có mục `## Bằng chứng chạy`\n\n## Ràng buộc\n\nd\n' > "$c/kb/specs/2026-11-12-v.md"
  o=$(schk "$c"); rc=$?
  eq "$rc" 0 "[spec-v2] a repo whose design section is named Ràng buộc: its first-shape spec stays first shape, rc 0"
  hasnt "$o" 'five sections' "[spec-v2] …not read as v2"

  local e="$TMP/spv2en"
  git_ init -q -b main "$e"; mkdir -p "$e/.vibemaestro" "$e/kb/specs"
  printf '{"schema": 1, "language": "en"}\n' > "$e/.vibemaestro/sdlc.json"
  printf -- '---\ndescription: "fixture"\n---\n\n# s\n\n## Goal\n\ng\n\n## Constraints\n\nc\n\n## Acceptance criteria\n\n1. When x, then y.\n\n## Risks to cover\n\n1. r\n\n## To clarify\n\nnone\n' > "$e/kb/specs/2026-11-12-v.md"
  o=$(schk "$e"); rc=$?
  eq "$rc" 0 "[spec-v2] an en repository: the English names of the five sections, rc 0"
  hasnt "$o" 'WARNING' "[spec-v2] …when … then needs no warning"
}

fam_plan_v2() {
  echo "== [plan-v2] a lean plan: the Delivers cell names the story's AC =="
  local r="$TMP/plv2" o rc
  git_ init -q -b main "$r"; mk_story "$r"; mk_spec2 "$r" "$CRIT_V2"
  mkplan2() {  # the plan kb/plans/2026-11-12-v.md with the lean columns, rows from line 13
    mkdir -p "$r/kb/plans"
    { printf -- '---\ndescription: "fixture"\nfocus: P1\n---\n\n# Plan\n\nIntent: kb/intent/2026-11-12-v.md · Spec: kb/specs/2026-11-12-v.md\n\n'
      printf '| Row | How | Delivers | Depends on | Trust touches | Link |\n|---|---|---|---|---|---|\n'; printf '%s\n' "$@"; } > "$r/kb/plans/2026-11-12-v.md"
  }
  mkplan2 '| A | the checks | AC1, AC2 (tiêu chí 1–2) | — | none | — |' '| B | the rest | AC3 | A | none | — |'
  o=$(pchk "$r" 2026-11-12-v); rc=$?
  eq "$rc" 0 "[plan-v2] control: a Delivers cell of AC ids, AC read from the story: rc 0"
  has "$o" 'plan: 3 AC (AC1 to AC3), each delivered by a row that is not dropped.' "[plan-v2] …each AC delivered"
  mkplan2 '| A | the checks | AC1, AC2 | — | none | — |'
  o=$(pchkr "$r" 2026-11-12-v); rc=$?
  eq "$rc" 65 "[plan-v2] AC3 delivered by no row: rc 65"
  has "$o" 'AC3 is delivered by no row that is not dropped' "[plan-v2] …named"
  mkplan2 '| A | the checks | AC1, AC2, AC9 | — | none | — |' '| B | the rest | AC3 is late | — | none | — |'
  o=$(pchkr "$r" 2026-11-12-v); rc=$?
  eq "$rc" 65 "[plan-v2] an AC the story lacks, and a cell that is not a list of AC: rc 65"
  has "$o" 'row A: Delivers AC9, which is not an AC of kb/intent/2026-11-12-v.md' "[plan-v2] …AC9 named against the story"
  has "$o" 'row B: Must be true starts neither' "[plan-v2] …row B named"

  local q="$TMP/plv2old"
  mk_repo "$q" story; mk_spec "$q" "$GOAL3" "$CRIT3" "$OOS_OK"
  mk_plan "$q" 'focus: P1' '| A | AC1, AC2: one and two | — |' "$ROW_B"
  o=$(pchkr "$q" kb/plans/2026-11-08-s.md); rc=$?
  eq "$rc" 65 "[plan-v2] a first-shape plan keeps its rule: AC1, AC2: with no Delivers is still red"
  has "$o" 'row A: Must be true starts neither `Delivers AC<n>[, AC<m>]:` nor `enabling: <reason>`' "[plan-v2] …with the message it had"
}


fam_k2() {
  echo "== [k2-templates] kb.py new writes the story, spec and plan shape the checks read =="
  local r="$TMP/k2t" o rc e="$TMP/k2t-en"
  git_ init -q -b main "$r"; mkdir -p "$r/kb/intent" "$r/kb/specs" "$r/kb/plans"
  (cd "$r" && python3 "$KBPY" new intent t --type story --focus P1 --date 2026-11-12 >/dev/null && python3 "$KBPY" new spec t --date 2026-11-12 >/dev/null && python3 "$KBPY" new plan t --date 2026-11-12 >/dev/null)
  o=$(cd "$r" && capped python3 "$KBPY" check intent 2026-11-12-t 2>&1); rc=$?
  eq "$rc" 65 "[k2-templates] the unfilled story template: rc 65"
  eq "$(printf '%s\n' "$o" | grep -c '^- ')" 1 "[k2-templates] …its one problem is the blanks to fill: the template has every part the check asks for"
  has "$o" 'blank(s) still to fill' "[k2-templates] …named"
  hasnt "$(sed -n '/^\*Ghi lại/,$p' "$r/kb/intent/2026-11-12-t.md")" 'yêu cầu gốc' "[k2-templates] …the story replaces the request paragraph"
  o=$(cd "$r" && capped python3 "$KBPY" check spec 2026-11-12-t 2>&1); rc=$?
  eq "$rc" 65 "[k2-templates] the unfilled spec template: rc 65"
  hasnt "$o" 'section `##' "[k2-templates] …no section problem: the five sections are there"
  eq "$(grep '^| Row' "$r/kb/plans/2026-11-12-t.md")" '| Row | How | Delivers | Depends on | Trust touches | Link |' "[k2-templates] the plan template has the lean columns"
  git_ init -q -b main "$e"; mkdir -p "$e/.vibemaestro" "$e/kb/intent"; printf '{"schema": 1, "language": "en"}\n' > "$e/.vibemaestro/sdlc.json"
  (cd "$e" && python3 "$KBPY" new intent t --type story --focus P1 --date 2026-11-12 >/dev/null)
  has "$(cat "$e/kb/intent/2026-11-12-t.md")" '**As** <FILL: who>, **I want** <FILL: what>, **so that** <FILL: why>.' "[k2-templates] an en repository: the story's English labels"
  # counted in Python on decoded text: a byte-wise grep (a C locale in CI) matches a byte an em dash shares with a Vietnamese letter
  eq "$(python3 -c 'import re, sys; print(len(re.findall("[àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđ]", open(sys.argv[1], encoding="utf-8").read().lower())))' "$e/kb/intent/2026-11-12-t.md")" 0 "[k2-templates] …and no Vietnamese letter"

  echo "== [k2-old-shape] a story's spec or plan of the earlier shape: red when new or changed, a WARNING when not =="
  local w; w=$(mk_origin)
  mkdir -p "$w/kb/specs" "$w/kb/plans"
  mk_repo "$TMP/k2src" story; cp "$TMP/k2src/kb/intent/2026-11-08-s.md" "$w/kb/intent/"
  mk_spec "$w" "$GOAL3" "$CRIT3" "$OOS_OK"
  mk_plan "$w" 'focus: P1' "$ROW_A" "$ROW_B"
  o=$(cd "$w" && capped python3 "$KBPY" check spec 2026-11-08-s 2>&1); rc=$?
  eq "$rc" 65 "[k2-old-shape] a story's spec of the earlier shape, new in the change: rc 65"
  has "$o" "- a story's spec new or changed in this change takes the five sections" "[k2-old-shape] …named"
  git_ -C "$w" add -A; git_ -C "$w" commit -q -m base; git_ -C "$w" push -q origin main
  o=$(cd "$w" && python3 "$KBPY" check spec 2026-11-08-s 2>&1); rc=$?
  eq "$rc" 0 "[k2-old-shape] the same spec on the base, not changed: rc 0"
  has "$o" 'the earlier spec shape: a WARNING while its body is unchanged' "[k2-old-shape] …a WARNING"
  o=$(cd "$w" && python3 "$KBPY" check spec 2026-11-08-s --strict 2>&1); rc=$?
  eq "$rc" 0 "[k2-old-shape] …--strict keeps it a WARNING: rc 0"
  o=$(cd "$w" && python3 "$KBPY" check plan 2026-11-08-s 2>&1); rc=$?
  eq "$rc" 0 "[k2-old-shape] a story's plan of the earlier columns on the base, not changed: rc 0"
  has "$o" 'the earlier plan columns: a WARNING while its row cells are unchanged' "[k2-old-shape] …a WARNING"
  printf -- '---\ndescription: "fixture"\nstatus: done\n---\n' > "$TMP/k2fm"; sed '1,/^---$/d' "$w/kb/specs/2026-11-08-s.md" >> "$TMP/k2fm"
  cp "$TMP/k2fm" "$w/kb/specs/2026-11-08-s.md"   # not a break: a frontmatter-only edit is the input of this case
  mk_plan "$w" 'focus: P1' "$ROW_A" '| B | Delivers AC3: three | intent/s-b |'; printf '\n## Decisions\n\n- "ok" — [x](https://example.com)\n' >> "$w/kb/plans/2026-11-08-s.md"
  o=$(cd "$w" && python3 "$KBPY" check spec 2026-11-08-s 2>&1); rc=$?
  eq "$rc" 0 "[k2-old-shape] the spec's frontmatter alone changed (status: done): rc 0, still a WARNING"
  o=$(cd "$w" && python3 "$KBPY" check plan 2026-11-08-s 2>&1); rc=$?
  eq "$rc" 0 "[k2-old-shape] the plan's Link cell and Decisions alone changed: rc 0, still a WARNING"
  mk_spec "$w" "$GOAL3" "$CRIT3" "$OOS_OK"; printf '\nA new sentence.\n' >> "$w/kb/specs/2026-11-08-s.md"
  mk_plan "$w" 'focus: P1' "$ROW_A" '| B | Delivers AC3: three, reworded | — |'
  o=$(cd "$w" && capped python3 "$KBPY" check spec 2026-11-08-s 2>&1); rc=$?
  eq "$rc" 65 "[k2-old-shape] the spec's body changed: rc 65"
  eq "$(printf '%s\n' "$o" | grep -c '^- ')" 1 "[k2-old-shape] …one problem: the shape to take, not the earlier shape's own sections"
  o=$(cd "$w" && capped python3 "$KBPY" check plan 2026-11-08-s 2>&1); rc=$?
  eq "$rc" 65 "[k2-old-shape] a row cell of the plan changed: rc 65"
  has "$o" "a story's plan new in this change, or whose row cells changed, takes the lean columns" "[k2-old-shape] …named"
  local v; v=$(mk_origin); mk_story "$v"; mk_spec2 "$v" "$CRIT_V2"; mkdir -p "$v/kb/plans"
  { printf -- '---\ndescription: "fixture"\nfocus: P1\n---\n\n# Plan\n\nIntent: kb/intent/2026-11-12-v.md · Spec: kb/specs/2026-11-12-v.md\n\n'
    printf '| Row | How | Delivers (AC) | Depends on | Trust touches | Link |\n|---|---|---|---|---|---|\n| A | x | AC1, AC2, AC3 | — | none | — |\n'; } > "$v/kb/plans/2026-11-12-v.md"
  git_ -C "$v" add -A; git_ -C "$v" commit -q -m base; git_ -C "$v" push -q origin main
  { printf -- '---\ndescription: "fixture"\nfocus: P1\n---\n\n# Plan\n\nIntent: kb/intent/2026-11-12-v.md · Spec: kb/specs/2026-11-12-v.md\n\n'
    printf '| Row | How | Delivers (AC) | Depends on | Trust touches | Link |\n|---|---|---|---|---|---|\n| A | x, reworded | AC1, AC2, AC3 | — | none | — |\n'; } > "$v/kb/plans/2026-11-12-v.md"
  o=$(cd "$v" && python3 "$KBPY" check plan 2026-11-12-v 2>&1); rc=$?
  eq "$rc" 0 "[k2-old-shape] a lean plan whose header is Delivers (AC), a row reworded: rc 0 (the lean columns)"
  hasnt "$o" 'lean columns' "[k2-old-shape] …not read as the earlier columns"
  sed -i 's/^type: story$/type: task/' "$w/kb/intent/2026-11-08-s.md"   # not a break: a task intent is the input of this case
  o=$(cd "$w" && python3 "$KBPY" check spec 2026-11-08-s 2>&1); rc=$?
  eq "$rc" 0 "[k2-old-shape] a task's spec of the earlier shape, changed: rc 0 (only a story's spec takes the new shape)"
  hasnt "$o" 'earlier spec shape' "[k2-old-shape] …and no shape warning"

  echo "== [k2-first-card] a first story card on a new intent warns =="
  r="$TMP/k2fc"; mk_repo "$r" story
  o=$(cd "$r" && python3 "$KBPY" check intent 2026-11-08-s 2>&1); rc=$?
  eq "$rc" 0 "[k2-first-card] a filled first card, new: rc 0"
  has "$o" 'the first story card: a new story takes the story the owner approves' "[k2-first-card] …a WARNING"

  echo "== [k2-ac-guard] an AC of a story on the base changes only with a new quoted decision of the owner =="
  w=$(mk_origin); mk_story "$w"; mk_spec2 "$w" "$CRIT_V2"
  git_ -C "$w" add -A; git_ -C "$w" commit -q -m base; git_ -C "$w" push -q origin main
  o=$(ichk "$w"); rc=$?
  eq "$rc" 0 "[k2-ac-guard] control: the story on the base, unchanged: rc 0"
  SV_AC=$'**Tiêu chí chấp nhận (AC)**\n\n*Story (anh đọc)*\n1. Khi có việc, anh nhận **một story**   ngắn.\n2. Nội dung `kb/` mới viết tiếng Việt.\n\n*Spec*\n3. Mỗi AC có tiêu chí trỏ về nó.' mk_story "$w"
  o=$(ichk "$w"); rc=$?
  eq "$rc" 0 "[k2-ac-guard] blanks moved inside an AC: not a change, rc 0"
  SV_AC=$'**Tiêu chí chấp nhận (AC)**\n1. Khi có việc, anh nhận một story dài.\n2. Nội dung `kb/` mới viết tiếng Việt.\n3. Mỗi AC có tiêu chí trỏ về nó.' mk_story "$w"
  o=$(ichkr "$w"); rc=$?
  eq "$rc" 65 "[k2-ac-guard] AC1 reworded, the group titles dropped, no new decision: rc 65"
  hasnt "$o" 'AC2' "[k2-ac-guard] …a group title is not part of the AC above it: AC2 is unchanged"
  has "$o" '- AC1 changed since the merge base and no new decision of the story holds the owner'"'"'s quote' "[k2-ac-guard] …it names AC1"
  SV_AC=$'**Tiêu chí chấp nhận (AC)**\n1. Khi có việc, anh nhận **một story** ngắn.\n2. Nội dung `kb/` mới viết tiếng Việt.' mk_story "$w"
  o=$(ichkr "$w"); rc=$?
  eq "$rc" 65 "[k2-ac-guard] AC3 dropped: rc 65"
  has "$o" '- AC3 changed since the merge base' "[k2-ac-guard] …it names AC3"
  SV_AC=$'**Tiêu chí chấp nhận (AC)**\n1. Khi có việc, anh nhận **một story** ngắn.\n2. Nội dung `kb/` mới viết tiếng Việt.\n3. Mỗi AC có tiêu chí trỏ về nó.\n4. Một AC mới.' mk_story "$w"
  o=$(ichkr "$w"); rc=$?
  eq "$rc" 65 "[k2-ac-guard] AC4 added: rc 65"
  SV_Q=$'**Quyết định của anh**\n1. AC4 thêm vào.' SV_AC=$'**Tiêu chí chấp nhận (AC)**\n1. Khi có việc, anh nhận **một story** ngắn.\n2. Nội dung `kb/` mới viết tiếng Việt.\n3. Mỗi AC có tiêu chí trỏ về nó.\n4. Một AC mới.' mk_story "$w"
  o=$(ichkr "$w"); rc=$?
  eq "$rc" 65 "[k2-ac-guard] a new decision with no quote: still rc 65"
  SV_Q=$'**Quyết định của anh**\n1. AC4 thêm vào: "thêm AC4 đi".' SV_AC=$'**Tiêu chí chấp nhận (AC)**\n1. Khi có việc, anh nhận **một story** ngắn.\n2. Nội dung `kb/` mới viết tiếng Việt.\n3. Mỗi AC có tiêu chí trỏ về nó.\n4. Một AC mới.' mk_story "$w"
  o=$(ichk "$w"); rc=$?
  eq "$rc" 0 "[k2-ac-guard] the same change with a new decision quoting the owner: rc 0"
  o=$(ichk "$w" --strict); rc=$?
  eq "$rc" 0 "[k2-ac-guard] …and under --strict: rc 0"
  SV_AC=$'**Tiêu chí chấp nhận (AC)**\n\n*Story (anh đọc)*\n1) Khi có việc, anh nhận một story ngắn.\n2) Nội dung kb/ mới viết tiếng Việt.\n\n#### Spec\n3) Mỗi AC có tiêu chí trỏ về nó.' mk_story "$w"
  o=$(ichk "$w"); rc=$?
  eq "$rc" 0 "[k2-ac-guard] bold and code marks dropped, 1) markers, a heading for a group: a reformatting, rc 0"
  SV_AC=$'**Tiêu chí chấp nhận (AC)**\n\n*Story (anh đọc)*\n1. Khi có việc, anh nhận **một story** ngắn.\n2. Nội dung `kb/` mới viết tiếng Việt.\n\n*Spec*\n3. Mỗi AC có tiêu chí trỏ về nó.\n\nAC3 chỉ áp cho story lớn.' mk_story "$w"
  o=$(ichkr "$w"); rc=$?
  eq "$rc" 65 "[k2-ac-guard] a paragraph added to the AC part, outside the items: rc 65"
  has "$o" "the AC part's text changed since the merge base" "[k2-ac-guard] …named as the AC part"
  SV_Q=$'**Quyết định của anh**\n1. "cũ".' mk_story "$w"; git_ -C "$w" add -A; git_ -C "$w" commit -q -m base2; git_ -C "$w" push -q origin main
  SV_Q=$'**Quyết định của anh**\n1. "cũ" và "giờ có ngoặc".' SV_AC=$'**Tiêu chí chấp nhận (AC)**\n1. Khi có việc, anh nhận một story.\n2. Nội dung `kb/` mới viết tiếng Việt.\n3. Mỗi AC có tiêu chí trỏ về nó.' mk_story "$w"
  o=$(ichkr "$w"); rc=$?
  eq "$rc" 65 "[k2-ac-guard] AC1 changed and only an old decision edited to carry a quote: rc 65 (a NEW decision item is needed)"
  o=$(cd "$w" && capped python3 "$KBPY" check links 2>&1); rc=$?
  eq "$rc" 65 "[k2-ac-guard] check links (what ship runs) runs the guard on the changed story: rc 65"
  has "$o" 'FAIL kb/intent/2026-11-12-v.md:1: AC1 changed since the merge base' "[k2-ac-guard] …a FAIL line naming the story"
  SV_Q=$'**Quyết định của anh**\n1. "cũ".\n2. Đổi AC1: "được, đổi đi".' SV_AC=$'**Tiêu chí chấp nhận (AC)**\n1. Khi có việc, anh nhận một story.\n2. Nội dung `kb/` mới viết tiếng Việt.\n3. Mỗi AC có tiêu chí trỏ về nó.' mk_story "$w"
  o=$(cd "$w" && python3 "$KBPY" check links 2>&1); rc=$?
  eq "$rc" 0 "[k2-ac-guard] …with a new decision quoting the owner, check links: rc 0"

  # review round 2: group titles, a wrapped `#tag`, an old decision edited to carry a quote
  w=$(mk_origin)
  SV_AC=$'**Tiêu chí chấp nhận (AC)**\n1. Khi có việc, anh nhận một story.\n2. Nội dung mới viết tiếng Việt.\n3. Mỗi AC có tiêu chí, như #tag.' SV_Q=$'**Quyết định của anh**\n1. Ghi lại, không trích.' mk_story "$w"; mk_spec2 "$w" "$CRIT_V2"
  git_ -C "$w" add -A; git_ -C "$w" commit -q -m base; git_ -C "$w" push -q origin main
  SV_AC=$'**Tiêu chí chấp nhận (AC)**\n\n*Story (anh đọc)*\n1. Khi có việc, anh nhận một story.\n2. Nội dung mới viết tiếng Việt.\n\n#### Spec\n3. Mỗi AC có tiêu chí, như\n#tag.' SV_Q=$'**Quyết định của anh**\n1. Ghi lại, không trích.' mk_story "$w"
  o=$(ichk "$w"); rc=$?
  eq "$rc" 0 "[k2-ac-guard] group titles added (an emphasis line, a heading) and AC3 rewrapped so a line opens with #tag: no AC change, rc 0"
  o=$(cd "$w" && python3 "$KBPY" check links 2>&1); rc=$?
  eq "$rc" 0 "[k2-ac-guard] …check links: rc 0"
  SV_AC=$'**Tiêu chí chấp nhận (AC)**\n1. Khi có việc, anh nhận một story.\n2. Nội dung mới viết tiếng Việt.\n3. Mỗi AC có tiêu chí.' SV_Q=$'**Quyết định của anh**\n1. Ghi lại, giờ có "lời trích".' mk_story "$w"
  o=$(ichkr "$w"); rc=$?
  eq "$rc" 65 "[k2-ac-guard] AC3 changed and an old decision edited to carry a quote (no new item): rc 65"
  has "$o" '- AC3 changed since the merge base' "[k2-ac-guard] …it names AC3"
}

fam_trace; fam_oos; fam_plan; fam_real_run; fam_keypr; fam_story_v2; fam_spec_v2; fam_plan_v2; fam_k2

# [replay-310] a real drop, replayed: a plan's Wanted 4 (one passphrase for one plan) left the spec's Goal and nobody was asked.
# tests/fixtures/replay-310/ holds a recast of it (the public tree names no private repository or issue): the card (Wanted 1 to 5
# as AC1 to AC5) and the spec (the Goal lists all but AC4; 7 out-of-scope lines in the original's shape, one of them quoted). The
# original lines sit beside the recast in the record under kb/records/. The page half is a case of the coordinator plugin's suite.
fam_replay310() {
  echo "== [replay-310] the dropped Wanted 4 under the new checks =="
  local r="$TMP/r310" o rc n="2026-11-06-batch-approval" F="$HERE/fixtures/replay-310"
  git_ init -q -b main "$r"
  mkdir -p "$r/kb/intent" "$r/kb/specs"
  cp "$F/intent.md" "$r/kb/intent/$n.md"; cp "$F/spec.md" "$r/kb/specs/$n.md"
  o=$(cd "$r" && python3 "$KBPY" check intent "$n" --strict 2>&1); rc=$?
  eq "$rc" 0 "[replay-310] the card is clean, even under --strict: rc 0"
  o=$(cd "$r" && capped python3 "$KBPY" check spec "$n" 2>&1); rc=$?
  eq "$rc" 65 "[replay-310] the spec: rc 65"
  has "$o" '(1 problem(s))' "[replay-310] …one problem"
  has "$o" '- AC4 of the intent is missing from `## Mục tiêu`' "[replay-310] …it is AC4, missing from the Goal"
  eq "$(printf '%s\n' "$o" | grep -c '^WARNING.*out-of-scope line')" 6 "[replay-310] …and six WARNING lines, one per unquoted out-of-scope line"
  hasnt "$o" 'không bám code' "[replay-310] …none of them the quoted line"
  o=$(cd "$r" && capped python3 "$KBPY" check spec "$n" --strict 2>&1); rc=$?
  eq "$rc" 65 "[replay-310] under --strict: rc 65"
  has "$o" '(7 problem(s))' "[replay-310] …seven problems: AC4 once and the six lines"
  eq "$(printf '%s\n' "$o" | grep -c '^- out-of-scope line')" 6 "[replay-310] …six of them out-of-scope lines"
  # the control: AC4 back in the Goal leaves the six lines and no missing-AC problem (no criterion names it: one more, not asserted) (input built from the fixture, not a break)
  sed -i 's/^4\. \*\*AC5:/4. **AC4: One passphrase per plan.** The plan'"'"'s sitting keeps the GPG passphrase for the plan'"'"'s life.\n5. **AC5:/' "$r/kb/specs/$n.md"   # not a break: the spec with AC4 restored is the control input
  o=$(cd "$r" && capped python3 "$KBPY" check spec "$n" --strict 2>&1); rc=$?
  eq "$rc" 65 "[replay-310] control, AC4 in the Goal: still rc 65 for the six lines"
  eq "$(printf '%s\n' "$o" | grep -c '^- out-of-scope line')" 6 "[replay-310] …the six out-of-scope lines"
  hasnt "$o" 'AC4 of the intent is missing' "[replay-310] …and AC4 is not one of them"
}
fam_replay310

# ── the installed copy, its brain, the fake gh ───────────────────────────────────────────────────────────────────────
C="$TMP/claude"; S="$C/plugins/cache/vibemaestro/vibemaestro-sdlc/1.0.0"; B="$C/plugins/cache/vibemaestro/vibemaestro-brain/1.0.0"
mkdir -p "$(dirname "$S")" "$B/scripts"; mk_plugin_copy "$S"
cat > "$B/scripts/brain.py" <<'PY'
import json, sys
items = {"P1": {"kind": "focus", "status": "live", "text": "ship the story process"},
         "P3": {"kind": "focus", "status": "retired", "text": "an old focus"}}
if sys.argv[1:2] != ["show"] or sys.argv[3:] != ["--json"]:
    sys.exit(64)
it = items.get(sys.argv[2])
if it is None:
    sys.stderr.write("brain: %s is not an item of this brain\n" % sys.argv[2])
    sys.exit(1)
print(json.dumps(dict(it, id=sys.argv[2])))
PY
python3 - "$C/plugins/installed_plugins.json" "$S" "$B" <<'PY'
import json, sys
e = lambda p: [{"scope": "user", "installPath": p, "version": "1.0.0", "lastUpdated": "2026-11-08T00:00:00.000Z"}]
json.dump({"version": 2, "plugins": {"vibemaestro-sdlc@vibemaestro": e(sys.argv[2]), "vibemaestro-brain@vibemaestro": e(sys.argv[3])}},
          open(sys.argv[1], "w"))
PY
GHB="$TMP/ghbin"; mkdir -p "$GHB"
cat > "$GHB/gh" <<'GH'
#!/bin/sh
printf '%s\n' "$*" >> "${GH_LOG:-/dev/null}"
case "$1 $2" in
  "label create") exit 0;;
  "issue create") [ -n "${GH_ISSUE_FAIL:-}" ] && { echo "HTTP 403: Resource not accessible by integration" >&2; exit 1; }
                  echo "https://github.com/acme/app/issues/42";;
  "pr list") printf '%s\n' "${GH_PRS:-[]}";;
  "issue view") printf '{"labels": [%s]}\n' "$GH_LABELS";;
esac
exit 0
GH
chmod +x "$GHB/gh"
GHL="$TMP/gh.log"

# ib <plugin> <repo> [NAME=value…] -- <args…> — the adapter of <plugin> (it adds --issue to create-intent) with the fake gh first in
# PATH; stdout to $TMP/out, stderr to $TMP/err, prints the rc
ib() {
  local p=$1 w=$2 e=(); shift 2; while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
  ( cd "$w" && cenv PATH="$GHB:$PATH" GH_LOG="$GHL" ${e[@]+"${e[@]}"} bash "$p/scripts/intent-branch.sh" --cwd "$w" "$@" ) \
    > "$TMP/out" 2> "$TMP/err"; echo $?
}
# intent <repo> <slug> <frontmatter lines…> — kb/intent/<slug>.md with a description and the given lines
intent() { local w=$1 s=$2; shift 2; { echo ---; echo 'description: "a demo intent"'; printf '%s\n' "$@"; printf -- '---\n\n# Demo\n\nWords.\n'; } > "$w/kb/intent/$s.md"; }
required() { mkdir -p "$1/.vibemaestro"; printf '{"schema": 1, "intake": {"focus": "required"}}\n' > "$1/.vibemaestro/sdlc.json"; }
issues() { grep -c '^issue create' "$GHL" 2>/dev/null || true; }
kb() { local w=$1; shift; ( cd "$w" && cenv python3 "$PLUGIN/scripts/kb.py" "$@" ) > "$TMP/out" 2> "$TMP/err"; echo $?; }
kbx() { local w=$1; shift; capped kb "$w" "$@"; }

echo "-- [intake-missing]"
W=$(mk_origin); required "$W"; : > "$GHL"
intent "$W" 2026-11-08-bare
rc=$(capped ib "$S" "$W" -- create-intent --slug 2026-11-08-bare --base main)
eq "$rc" 9 "[intake-missing] no type and no focus under required: rc 9"
hasline "$(cat "$TMP/err")" 'intent_branch: refused, no branch or issue created: kb/intent/2026-11-08-bare.md has no `type:` (story, task or bug) and no `focus:` (an open focus of the brain, like P1) in its frontmatter: kb.py new intent <slug> --type <t> --focus <P> writes both' "[intake-missing] …it names both fields"
ref_exists "$W" intent/2026-11-08-bare && bad "[intake-missing] …a branch was created" || ok "[intake-missing] …no branch"
eq "$(issues)" 0 "[intake-missing] …no issue"
intent "$W" 2026-11-08-notype "focus: P1"
rc=$(capped ib "$S" "$W" -- create-intent --slug 2026-11-08-notype --base main)
eq "$rc" 9 "[intake-missing] focus but no type: rc 9"
has "$(cat "$TMP/err")" 'has no `type:` (story, task or bug) in its frontmatter' "[intake-missing] …it names type alone"
intent "$W" 2026-11-08-nofocus "type: bug"
rc=$(capped ib "$S" "$W" -- create-intent --slug 2026-11-08-nofocus --base main)
eq "$rc" 9 "[intake-missing] type but no focus: rc 9"
has "$(cat "$TMP/err")" 'has no `focus:` (an open focus of the brain, like P1) in its frontmatter' "[intake-missing] …it names focus alone"
eq "$(issues)" 0 "[intake-missing] …still no issue"

echo "-- [intake-warn]"
W=$(mk_origin); : > "$GHL"; intent "$W" 2026-11-08-plain
rc=$(ib "$S" "$W" -- create-intent --slug 2026-11-08-plain --base main)
eq "$rc" 0 "[intake-warn] a plain intent under the default: rc 0"
hasline "$(cat "$TMP/err")" 'intent_branch: WARNING (intake.focus: warn): kb/intent/2026-11-08-plain.md has no `type:` (story, task or bug) and no `focus:` (an open focus of the brain, like P1) in its frontmatter: kb.py new intent <slug> --type <t> --focus <P> writes both' "[intake-warn] …one WARNING line naming both fields"
eq "$(grep -c WARNING "$TMP/err")" 1 "[intake-warn] …exactly one WARNING line"
ref_exists "$W" intent/2026-11-08-plain && ok "[intake-warn] …the branch is created" || bad "[intake-warn] …no branch"
eq "$(grep -cx 'issue: 42' "$W/kb/intent/2026-11-08-plain.md")" 1 "[intake-warn] …the issue is created and recorded"
git_ -C "$W" checkout -q main; : > "$GHL"; intent "$W" 2026-11-08-epic "type: epic" "focus: P1x"
rc=$(ib "$S" "$W" -- create-intent --slug 2026-11-08-epic --base main)
eq "$rc" 0 "[intake-warn] type: epic, focus: P1x under the default: rc 0"
eq "$(grep -c -- ' --label intent$' "$GHL") $(grep -c 'label create type:\|label create focus:' "$GHL")" "1 0" "[intake-warn] …the issue gets only the intent label: no label from a type or focus that is not one"
W=$(mk_origin); mkdir -p "$W/.vibemaestro"; printf '{"schema": 1, "intake": {"focus": "off"}}\n' > "$W/.vibemaestro/sdlc.json"
intent "$W" 2026-11-08-off
rc=$(ib "$S" "$W" -- create-intent --slug 2026-11-08-off --base main --no-issue)
eq "$rc" 0 "[intake-warn] intake.focus off: rc 0"
eq "$(grep -c WARNING "$TMP/err")" 0 "[intake-warn] …and no WARNING"

echo "-- [intake-focus-closed]"
W=$(mk_origin); required "$W"; : > "$GHL"
intent "$W" 2026-11-08-p9 "type: story" "focus: P9"
rc=$(capped ib "$S" "$W" -- create-intent --slug 2026-11-08-p9 --base main)
eq "$rc" 9 "[intake-focus-closed] focus P9, unknown to the brain: rc 9"
has "$(cat "$TMP/err")" "P9 is not an open focus of this brain" "[intake-focus-closed] …\"P9 is not an open focus of this brain\""
ref_exists "$W" intent/2026-11-08-p9 && bad "[intake-focus-closed] …a branch was created" || ok "[intake-focus-closed] …no branch"
eq "$(issues)" 0 "[intake-focus-closed] …no issue"
intent "$W" 2026-11-08-p3 "type: story" "focus: P3"
rc=$(capped ib "$S" "$W" -- create-intent --slug 2026-11-08-p3 --base main)
eq "$rc" 9 "[intake-focus-closed] focus P3, retired in the brain: rc 9"
has "$(cat "$TMP/err")" "P3 is not an open focus of this brain (it is a focus item, retired)" "[intake-focus-closed] …it says why"
intent "$W" 2026-11-08-p1 "type: story" "focus: P1"
rc=$(ib "$S" "$W" -- create-intent --slug 2026-11-08-p1 --base main)
eq "$rc" 0 "[intake-focus-closed] control: focus P1, live in the brain: rc 0"
ref_exists "$W" intent/2026-11-08-p1 && ok "[intake-focus-closed] …the branch is created" || bad "[intake-focus-closed] …no branch"
eq "$(grep -c -- ' --label intent --label type:story --label focus:P1$' "$GHL") $(issues)" "1 1" "[intake-focus-closed] …one issue, carrying intent, type:story and focus:P1"
eq "$(grep -c '^label create type:story ' "$GHL") $(grep -c '^label create focus:P1 ' "$GHL")" "1 1" "[intake-focus-closed] …both labels are created first"

echo "-- [intake-worker-label]"
W=$(mk_origin); required "$W"; : > "$GHL"
intent "$W" 2026-11-08-wk "type: task" "focus: P2" "issue: 7"
rc=$(capped ib "$S" "$W" VIBEMAESTRO_ROLE=worker 'GH_LABELS={"name": "intent"}, {"name": "type:task"}' -- create-intent --slug 2026-11-08-wk --base main --no-issue)
eq "$rc" 9 "[intake-worker-label] a worker, its issue with no focus: label: rc 9"
hasline "$(cat "$TMP/err")" "intent_branch: refused, no branch or issue created: issue #7 has no label focus:P2: the gate-1 session, where the brain answers, sets type:task and focus:P2 on it" "[intake-worker-label] …it names the label the gate-1 session must set"
eq "$(grep -cx 'issue view 7 --json labels' "$GHL")" 1 "[intake-worker-label] …it read the labels of its issue"
ref_exists "$W" intent/2026-11-08-wk && bad "[intake-worker-label] …a branch was created" || ok "[intake-worker-label] …no branch"
rc=$(ib "$S" "$W" VIBEMAESTRO_ROLE=worker 'GH_LABELS={"name": "type:task"}, {"name": "focus:P2"}' -- create-intent --slug 2026-11-08-wk --base main)
eq "$rc" 0 "[intake-worker-label] control: both labels on its issue: rc 0 (the brain is not asked in a worker)"
eq "$(issues)" 0 "[intake-worker-label] …the adapter's --issue opens no second issue in a worker"
eq "$(grep -c '^issue:' "$W/kb/intent/2026-11-08-wk.md") $(grep -cx 'issue: 7' "$W/kb/intent/2026-11-08-wk.md")" "1 1" "[intake-worker-label] …the intent keeps issue: 7"
git_ -C "$W" checkout -q main
intent "$W" 2026-11-08-wk2 "type: task" "focus: P2"
rc=$(capped ib "$S" "$W" VIBEMAESTRO_ROLE=worker -- create-intent --slug 2026-11-08-wk2 --base main --no-issue)
eq "$rc" 9 "[intake-worker-label] a worker, no issue: N in the intent: rc 9"
has "$(cat "$TMP/err")" "a worker reads the focus from the labels type:task and focus:P2 of the intent's issue" "[intake-worker-label] …it names the labels"
W=$(mk_origin); required "$W"; intent "$W" 2026-11-08-none "type: task" "focus: P1"
rc=$(capped ib "$PLUGIN" "$W" -- create-intent --slug 2026-11-08-none --base main --no-issue)
eq "$rc" 9 "[intake-worker-label] neither a brain (a copy outside a plugin cache) nor a worker: rc 9"
has "$(cat "$TMP/err")" "no brain answers here" "[intake-worker-label] …it names the brain way"
has "$(cat "$TMP/err")" "a worker reading the issue's type:/focus: labels" "[intake-worker-label] …and the worker way"

# code <repo> <JSON value> — .vibemaestro/sdlc.json with issue.code set to the value
code() { mkdir -p "$1/.vibemaestro"; printf '{"schema": 1, "issue": {"code": %s}}\n' "$2" > "$1/.vibemaestro/sdlc.json"; }
branches() { git_ -C "$1" for-each-ref --format='%(refname:short)' refs/heads/intent/ | tr '\n' ' '; }
# pstatus <repo> <GH_PRS> <plan> — one line per row of plan status --json: <id> <state> <pr or -> <jira or ->
pstatus() {
  ( cd "$1" && cenv PATH="$GHB:$PATH" GH_PRS="$2" python3 "$KBPY" plan status "$3" --json ) \
    | python3 -c 'import json,sys; [print(r["id"], r["state"].replace(" ", "-"), r.get("pr") or "-", r.get("jira") or "-") for r in json.load(sys.stdin)["rows"]]'
}

echo "-- [key]"
W=$(mk_origin); code "$W" '"ACM"'; : > "$GHL"; intent "$W" 2026-11-09-demo "type: task" "focus: P1"
rc=$(ib "$S" "$W" -- create-intent --slug 2026-11-09-demo --base main)
eq "$rc" 0 "[key] issue.code ACM: create-intent rc 0"
eq "$(cat "$TMP/out")" "intent/ACM-42-demo" "[key] …it prints the branch intent/ACM-42-demo"
eq "$(branches "$W")" "intent/ACM-42-demo " "[key] …the one intent branch is intent/<KEY>-<slug>, no dated one"
eq "$(sed -n 2,3p "$W/kb/intent/2026-11-09-demo.md")" $'key: ACM-42\nissue: 42' "[key] …the intent keeps kb/intent/2026-11-09-demo.md and records issue: 42, key: ACM-42"
hasline "$(cat "$TMP/err")" "intent_branch: key ACM-42 recorded in kb/intent/2026-11-09-demo.md" "[key] …it says so"
rc=$(capped ib "$S" "$W" -- create-intent --slug ACM-42-demo --base main)
eq "$rc" 6 "[key] create-intent --slug ACM-42-demo resolves the intent through key: and finds its branch: rc 6"
rc=$(ib "$S" "$W" -- retry-issue --slug intent/ACM-42-demo)
eq "$rc" 0 "[key] retry-issue on the key branch: rc 0"
has "$(cat "$TMP/err")" "(idempotent): kb/intent/2026-11-09-demo.md" "[key] …it resolves kb/intent/2026-11-09-demo.md, which has its issue"
git_ -C "$W" checkout -q main; : > "$GHL"; intent "$W" 2026-11-09-fail "type: task" "focus: P1"
rc=$(capped ib "$S" "$W" GH_ISSUE_FAIL=1 -- create-intent --slug 2026-11-09-fail --base main)
eq "$rc" 1 "[key] the issue cannot be opened: rc 1"
has "$(cat "$TMP/err")" "issue.code is ACM, so the branch needs its number: NO BRANCH WAS CREATED" "[key] …it says no branch was created"
eq "$(branches "$W") $(grep -c '^key:\|^issue:' "$W/kb/intent/2026-11-09-fail.md")" "intent/ACM-42-demo  0" "[key] …no branch, no key, no issue line"
eq "$(grep -c '^issue create' "$GHL")" 1 "[key] …gh was asked for the issue once"
rc=$(capped ib "$S" "$W" -- create-intent --slug 2026-11-09-fail --base main --no-issue)
eq "$rc" 1 "[key] --no-issue and no issue: N under issue.code: rc 1"
has "$(cat "$TMP/err")" "has no \`issue: N\` and --no-issue opens none; nothing was created" "[key] …it names why"
eq "$(branches "$W")" "intent/ACM-42-demo " "[key] …still no branch"
: > "$GHL"; intent "$W" 2026-11-09-wk "type: task" "focus: P2" "issue: 7"
rc=$(ib "$S" "$W" VIBEMAESTRO_ROLE=worker 'GH_LABELS={"name": "type:task"}, {"name": "focus:P2"}' -- create-intent --slug 2026-11-09-wk --base main)
eq "$rc $(cat "$TMP/out")" "0 intent/ACM-7-wk" "[key] a worker's intent with issue: 7: rc 0, branch intent/ACM-7-wk"
eq "$(issues) $(grep -cx 'key: ACM-7' "$W/kb/intent/2026-11-09-wk.md")" "0 1" "[key] …no new issue, key: ACM-7 recorded"
intent "$W" 2026-11-09-zero "type: task" "focus: P1" "issue: 0"
rc=$(capped ib "$S" "$W" -- create-intent --slug 2026-11-09-zero --base main --no-issue)
eq "$rc $(grep -c '^key:' "$W/kb/intent/2026-11-09-zero.md")" "1 0" "[key] issue: 0 is not an issue number: rc 1, no key written"
has "$(cat "$TMP/err")" "\`issue: 0\` in kb/intent/2026-11-09-zero.md is not an issue number; nothing was created" "[key] …it names the line"
printf 'issue: 5\n\n# No frontmatter\n' > "$W/kb/intent/2026-11-09-nf.md"
rc=$(capped ib "$S" "$W" -- create-intent --slug 2026-11-09-nf --base main --no-issue)
eq "$rc $(grep -c '^key:' "$W/kb/intent/2026-11-09-nf.md")" "1 0" "[key] an intent with no frontmatter (issue: 5 in its body): rc 1, no key written"
has "$(cat "$TMP/err")" "kb/intent/2026-11-09-nf.md has none (a \`---\` block at its top)" "[key] …it says the key needs a frontmatter"
eq "$(branches "$W")" "intent/ACM-42-demo intent/ACM-7-wk " "[key] …neither left a branch"
printf -- '---\ndescription: "body"\ntype: task\nfocus: P1\n---\n\n# Body\n\nAn example line:\nissue: 5\n' > "$W/kb/intent/2026-11-09-body.md"
: > "$GHL"; rc=$(ib "$S" "$W" -- create-intent --slug 2026-11-09-body --base main)
eq "$rc $(cat "$TMP/out") $(issues)" "0 intent/ACM-42-body 1" "[key] an \`issue: 5\` line in the body is not the intent's issue: one issue opened, branch intent/ACM-42-body"
eq "$(sed -n '2,3p;$p' "$W/kb/intent/2026-11-09-body.md")" $'key: ACM-42\nissue: 42\nissue: 5' "[key] …issue: 42 and key: ACM-42 go into the frontmatter, the body line stays"
git_ -C "$W" checkout -q main
kbx "$W" check intent 2026-11-09-wk > /dev/null   # this intent has no card: red for its sections, and only for them
hasnt "$(cat "$TMP/err")" 'frontmatter `key:' "[key] check intent: key: ACM-7 with issue: 7 under issue.code ACM is not a problem"
sed -i 's/^key: ACM-7$/key: ACM-8/' "$W/kb/intent/2026-11-09-wk.md"   # not a break: a key that is not <code>-<issue>, check intent must report
eq "$(kbx "$W" check intent 2026-11-09-wk)" 65 "[key] key: ACM-8 with issue: 7: rc 65"
eq "$(grep -c '^- ' "$TMP/err")" 4 "[key] …one problem more than the three missing sections"
has "$(cat "$TMP/err")" '- frontmatter `key: ACM-8` is not `ACM-<issue>` with this intent'"'"'s `issue: 7` (issue.code is ACM)' "[key] …it names both"
for bad_code in '"acm"' '"ACME"' '"A1C"' '12'; do
  W2=$(mk_origin); code "$W2" "$bad_code"; intent "$W2" 2026-11-09-x "type: task" "focus: P1"
  rc=$(capped ib "$S" "$W2" -- create-intent --slug 2026-11-09-x --base main)
  eq "$rc" 64 "[key] issue.code $bad_code is refused: rc 64"
  has "$(cat "$TMP/err")" "issue.code: must be null or the repository's code: 3 capital letters A-Z, like KIT" "[key] …naming issue.code and its shape"
  eq "$(branches "$W2")" "" "[key] …and no branch"
done
# plan status: K1 back-links an intent in the working tree, K2 one only at its PR head, K3 is linked by its key branch in the
# Link cell, K4 back-links an intent whose key (ACM-8) is not its PR branch's (ACM-9)
P=$(mk_origin); mkdir -p "$P/kb/plans"
{ printf -- '---\ndescription: "k"\n---\n\n# Plan\n\n## Rows\n\n| Row | Must be true | Link |\n|---|---|---|\n'
  printf '| K1 | a | — |\n| K2 | b | — |\n| K3 | c | intent/ACM-7-c |\n| K4 | d | — |\n'; } > "$P/kb/plans/2026-11-09-k.md"
git_ -C "$P" add -A; git_ -C "$P" commit -qm plan
git_ -C "$P" checkout -q -b intent/ACM-6-b; intent "$P" 2026-11-09-b "plan: kb/plans/2026-11-09-k.md#K2" "key: ACM-6"
git_ -C "$P" add -A; git_ -C "$P" commit -qm b; HB=$(git_ -C "$P" rev-parse HEAD); git_ -C "$P" checkout -q main; mkdir -p "$P/kb/intent"
intent "$P" 2026-11-09-a "plan: kb/plans/2026-11-09-k.md#K1" "key: ACM-5"
intent "$P" 2026-11-08-c "key: ACM-7"
intent "$P" 2026-11-09-d "plan: kb/plans/2026-11-09-k.md#K4" "key: ACM-8"
PRS=$(python3 -c 'import json,sys
pr = lambda n, b, h="a" * 40: {"number": n, "state": "OPEN", "headRefName": b, "headRefOid": h, "isDraft": True, "mergeCommit": None,
                               "url": "https://example.invalid/o/r/pull/%d" % n, "title": "t"}
print(json.dumps([pr(51, "intent/ACM-5-a"), pr(52, "intent/ACM-6-b", sys.argv[1]), pr(53, "intent/ACM-7-c"), pr(54, "intent/ACM-9-d")]))' "$HB")
eq "$(pstatus "$P" "$PRS" kb/plans/2026-11-09-k.md)" $'K1 PR-open 51 -\nK2 PR-open 52 -\nK3 PR-open 53 -\nK4 intent-open - -' \
  "[key] plan status links K1 (working tree), K2 (PR head only) and K3 (Link cell) by their key branches; K4's other key does not link"

echo "-- [labels]"
W=$(mk_origin); code "$W" '"ACM"'; : > "$GHL"; intent "$W" 2026-11-09-lb "type: bug" "focus: P1"
rc=$(ib "$S" "$W" -- create-intent --slug 2026-11-09-lb --base main)
eq "$rc $(cat "$TMP/out")" "0 intent/ACM-42-lb" "[labels] issue.code ACM, a bug in P1: rc 0, branch intent/ACM-42-lb"
eq "$(grep -- ' --label intent' "$GHL" | sed 's/.* --label intent/--label intent/')" "--label intent --label type:bug --label focus:P1" \
  "[labels] …the issue carries exactly intent, type:bug and focus:P1"
eq "$(grep -c '^label create' "$GHL") $(grep -c 'ACM' "$GHL")" "3 0" "[labels] …three labels created, none from the key"

echo "-- [jira]"
W=$(mk_origin)
eq "$(kb "$W" new intent jr --type task --focus P1 --jira ABC-12 --date 2026-11-09)" 0 "[jira] kb.py new intent --jira ABC-12: rc 0"
eq "$(grep -cx 'jira: ABC-12' "$W/kb/intent/2026-11-09-jr.md")" 1 "[jira] …it stores jira: ABC-12 in the frontmatter"
eq "$(kbx "$W" new intent jr2 --type task --focus P1 --jira 'abc 12')" 64 "[jira] --jira 'abc 12': rc 64"
hasline "$(cat "$TMP/err")" "kb: --jira must be a Jira issue key like ABC-12" "[jira] …it names the shape"
eq "$(kbx "$W" new plan jr3 --jira ABC-12)" 64 "[jira] --jira on a plan: rc 64"
F="$W/kb/intent/2026-11-09-jr.md"
python3 -c 'import re,sys; p=sys.argv[1]; t=re.sub(r"<ĐIỀN:[^>]*>", "filled", open(p).read()); open(p, "w").write(t.replace("---\n", "---\nkey: ACM-42\n", 1))' "$F"   # not a break: fills the card's blanks, adds key: ACM-42
eq "$(kb "$W" check intent 2026-11-09-jr)" 0 "[jira] check intent with key: ACM-42 and jira: ABC-12: rc 0"
has "$(cat "$TMP/out")" "kb/intent/2026-11-09-jr.md passes its card (key: ACM-42 jira: ABC-12; jira is never synced)." "[jira] …it shows both"
sed -i 's/^jira: ABC-12$/jira: not-a-key/' "$F"   # not a break: the malformed input check intent must report
eq "$(kbx "$W" check intent 2026-11-09-jr)" 65 "[jira] jira: not-a-key: rc 65"
has "$(cat "$TMP/err")" '- frontmatter `jira: not-a-key` is not a Jira issue key, like ABC-12' "[jira] …it names the line"
sed -i 's/^jira: not-a-key$/jira: ABC-12/; s/^key: ACM-42$/key: ACM42/' "$F"   # not a break: a malformed key, same check
eq "$(kbx "$W" check intent 2026-11-09-jr)" 65 "[jira] key: ACM42: rc 65"
has "$(cat "$TMP/err")" '- frontmatter `key: ACM42` is not `<issue.code>-<issue number>`, like KIT-12' "[jira] …it names the line"
sed -i 's/^key: ACM42$/key: ACM-42/' "$F"
mkdir -p "$W/kb/plans"; printf -- '---\ndescription: "j"\n---\n\n# Plan\n\n## Rows\n\n| Row | Must be true | Link |\n|---|---|---|\n| J | a | kb/intent/2026-11-09-jr.md |\n' > "$W/kb/plans/2026-11-09-j.md"
eq "$(pstatus "$W" '[]' kb/plans/2026-11-09-j.md)" "J intent-open - ABC-12" "[jira] plan status shows the row's jira: ABC-12"
has "$( (cd "$W" && cenv PATH="$GHB:$PATH" python3 "$KBPY" plan status kb/plans/2026-11-09-j.md) )" "kb/intent/2026-11-09-jr.md · jira ABC-12" "[jira] …in the text view too"

echo "-- [key-no-code]"
for cfg in null absent; do
  W=$(mk_origin); [ "$cfg" = null ] && code "$W" null; : > "$GHL"; intent "$W" 2026-11-09-plain "type: task" "focus: P1"
  rc=$(ib "$S" "$W" -- create-intent --slug 2026-11-09-plain --base main)
  eq "$rc $(cat "$TMP/out")" "0 intent/2026-11-09-plain" "[key-no-code] issue.code $cfg: rc 0, today's branch intent/2026-11-09-plain"
  eq "$(grep -c '^key:' "$W/kb/intent/2026-11-09-plain.md") $(grep -cx 'issue: 42' "$W/kb/intent/2026-11-09-plain.md")" "0 1" "[key-no-code] …no key:, the issue as today"
  eq "$(grep -c 'WARNING\|unknown key\|issue.code' "$TMP/err")" 0 "[key-no-code] …no warning about issue.code"
done

# ── the cards ─────────────────────────────────────────────────────────────────────────────────────────────────────────
K=$(fresh); git_ init -q -b main "$K"; mkdir -p "$K/kb/intent"
heads() { grep '^## ' "$1" | tr '\n' '|'; }
front() { sed -n '2,/^---$/p' "$1" | grep -E '^(type|focus):' | tr '\n' '|'; }
# card <file> <type> <focus> <body> — an intent of that type and focus, filled
card() { printf -- '---\ndescription: "demo"\ntype: %s\nfocus: %s\n---\n\n# Demo\n\nWords.\n\n%s\n' "$2" "$3" "$4" > "$1"; }
STORY='## Story

As a maintainer, I want intake to ask for a focus, so that no story drifts.

## Acceptance criteria

1. **AC1: type and focus.** Given an intake, when type is missing, then it refuses. ("ko quên các mục tiêu, trọng tâm")
2. **AC2: a card.** Given a story, when checked, then each AC has a quote. (page decision mot-tep (a))

## Not doing

- A Jira sync script. ("Script đồng bộ làm sau")

## Measure

The dropped Wanted line is caught.'

echo "-- [card-story]"
eq "$(kb "$K" new intent st --type story --focus P2 --date 2026-11-08)" 0 "[card-story] new intent --type story --focus P2: rc 0"
F="$K/kb/intent/2026-11-08-st.md"
eq "$(front "$F")" "type: story|focus: P2|" "[card-story] …frontmatter type: story, focus: P2"
eq "$(grep -cE '^\*\*(Là|Bối cảnh\.|Tiêu chí chấp nhận \(AC\)|Không làm|Khẩu phần\.|Câu hỏi)\*\*' "$F")" 6 "[card-story] …the story the owner approves, its six labelled parts in the vi preset"
eq "$(heads "$F")" "" "[card-story] …and no first-card section"
eq "$(grep -cx 'Type: story · Focus: P2' "$F")" 1 "[card-story] …the Type · Focus line"
eq "$(kbx "$K" check intent 2026-11-08-st)" 65 "[card-story] the unfilled card: rc 65"
has "$(cat "$TMP/err")" "blank(s) still to fill" "[card-story] …its blanks are named"
card "$F" story P2 "$STORY"
eq "$(kb "$K" check intent 2026-11-08-st)" 0 "[card-story] a filled story: rc 0"
card "$F" story P2 "${STORY%%## Measure*}"
eq "$(kbx "$K" check intent 2026-11-08-st)" 65 "[card-story] no ## Measure: rc 65"
has "$(cat "$TMP/err")" '- section `## Measure` is missing (a story card: ## Story, ## Acceptance criteria, ## Not doing, ## Measure)' "[card-story] …it names Measure"
card "$F" story P2 "${STORY/, so that no story drifts/}"
eq "$(kbx "$K" check intent 2026-11-08-st)" 65 "[card-story] no 'so that': rc 65"
has "$(cat "$TMP/err")" '- `## Story` needs As a / I want / so that: no `so that`' "[card-story] …it names so that"

echo "-- [card-task]"
eq "$(kb "$K" new intent tk --type task --focus P1 --date 2026-11-08)" 0 "[card-task] new intent --type task: rc 0"
F="$K/kb/intent/2026-11-08-tk.md"
eq "$(front "$F")" "type: task|focus: P1|" "[card-task] …frontmatter type: task, focus: P1"
eq "$(heads "$F")" "## What|## Why|## Check|" "[card-task] …What, Why, Check"
card "$F" task P1 $'## What\n\nAdd the card.\n\n## Why\n\nAC2.\n\n## Check\n\n`bash tests/test-kb-story.sh`'
eq "$(kb "$K" check intent 2026-11-08-tk)" 0 "[card-task] a filled task: rc 0"
card "$F" task P1 $'## What\n\nAdd the card.\n\n## Why\n\nAC2.'
eq "$(kbx "$K" check intent 2026-11-08-tk)" 65 "[card-task] no ## Check: rc 65"
has "$(cat "$TMP/err")" '- section `## Check` is missing (a task card: ## What, ## Why, ## Check)' "[card-task] …it names Check"
printf -- '---\ndescription: "demo"\n---\n\n# Demo\n\n## What\n\nx\n\n## Why\n\ny\n\n## Check\n\nz\n' > "$F"
eq "$(kb "$K" check intent 2026-11-08-tk)" 0 "[card-task] no type, no focus, default warn: rc 0"
has "$(cat "$TMP/out")" 'WARNING kb/intent/2026-11-08-tk.md: frontmatter `type:` must be story, task or bug, and there is none' "[card-task] …a WARNING names type"
required "$K"
eq "$(kbx "$K" check intent 2026-11-08-tk)" 65 "[card-task] the same under required: rc 65"
has "$(cat "$TMP/err")" '- frontmatter `focus:` is missing: an open focus of the brain, like P1' "[card-task] …it names focus"
rm -rf "$K/.vibemaestro"

echo "-- [card-bug]"
eq "$(kb "$K" new intent bg --type bug --focus P1 --date 2026-11-08)" 0 "[card-bug] new intent --type bug: rc 0"
F="$K/kb/intent/2026-11-08-bg.md"
eq "$(heads "$F")" "## Reproduce|## Expected|## Test|" "[card-bug] …Reproduce, Expected, Test"
card "$F" bug P1 $'## Reproduce\n\nRun intake with no type.\n\n## Expected\n\nRefused.\n\n## Test\n\n[intake-missing]'
eq "$(kb "$K" check intent 2026-11-08-bg)" 0 "[card-bug] a filled bug: rc 0"
card "$F" bug P1 $'## Reproduce\n\nRun intake with no type.\n\n## Expected\n\n\n## Test\n\n[intake-missing]'
eq "$(kbx "$K" check intent 2026-11-08-bg)" 65 "[card-bug] an empty ## Expected: rc 65"
has "$(cat "$TMP/err")" '- section `## Expected` is empty' "[card-bug] …it names Expected"
card "$F" chore P1 $'## Reproduce\n\nx'
eq "$(kbx "$K" check intent 2026-11-08-bg)" 0 "[card-bug] type: chore under the default warn: rc 0"
has "$(cat "$TMP/out")" 'frontmatter `type:` must be story, task or bug (it is `chore`)' "[card-bug] …a WARNING names the type"
eq "$(kb "$K" new intent bx --type chore)" 64 "[card-bug] new intent --type chore: rc 64"

echo "-- [card-quote]"
F="$K/kb/intent/2026-11-08-st.md"
card "$F" story P2 "${STORY/ (page decision mot-tep (a))/}"
eq "$(kbx "$K" check intent 2026-11-08-st)" 65 "[card-quote] AC2 with no quote: rc 65"
hasline "$(cat "$TMP/err")" '- AC2 has no quote: the owner'"'"'s words in "…", or (page decision <id> (<option>))' "[card-quote] …it names AC2"
hasnt "$(cat "$TMP/err")" "AC1 has no quote" "[card-quote] …and not AC1, which has one"
card "$F" story P2 "${STORY/ (\"Script đồng bộ làm sau\")/}"
eq "$(kb "$K" check intent 2026-11-08-st)" 0 "[card-quote] a Not doing line with neither: rc 0"
hasline "$(cat "$TMP/out")" "WARNING kb/intent/2026-11-08-st.md: Not doing line 1 has neither the owner's quote nor a page decision id: gate 2 makes it a mandatory decision (red under --strict)" "[card-quote] …a WARNING names the line"
eq "$(kbx "$K" check intent 2026-11-08-st --strict)" 65 "[card-quote] …red under --strict"
card "$F" story P2 "${STORY/(\"Script đồng bộ làm sau\")/(page decision not-doing-quotes (a))}"
eq "$(kb "$K" check intent 2026-11-08-st --strict)" 0 "[card-quote] the line with a page decision id: rc 0 under --strict"
card "$F" story P2 "${STORY/(page decision mot-tep (a))/(\`\"a code span\"\`)}"
eq "$(kbx "$K" check intent 2026-11-08-st)" 65 "[card-quote] AC2 quoted only inside a code span: rc 65"
has "$(cat "$TMP/err")" "AC2 has no quote" "[card-quote] …it names AC2"
card "$F" story P2 "${STORY/ (page decision mot-tep (a))/ (\"   \")}"
eq "$(kbx "$K" check intent 2026-11-08-st)" 65 "[card-quote] AC2 quoting three spaces: rc 65"
card "$F" story P2 "${STORY/ (page decision mot-tep (a))/$'\n\nA closing paragraph with \"the owner\'s words\".'}"
eq "$(kbx "$K" check intent 2026-11-08-st)" 65 "[card-quote] AC2 unquoted, a quoted paragraph after the list: rc 65"
has "$(cat "$TMP/err")" "AC2 has no quote" "[card-quote] …the paragraph is not AC2's quote"
card "$F" story P2 "${STORY/2. \*\*AC2: a card.\*\*/2. **A card, see AC1.**}"
eq "$(kbx "$K" check intent 2026-11-08-st)" 65 "[card-quote] an item that only mentions AC1: rc 65"
has "$(cat "$TMP/err")" '- AC item 2 has no `AC<n>` id' "[card-quote] …it has no id of its own"
card "$F" story P2 "${STORY/ (page decision mot-tep (a))/}"$'\n\n## Acceptance criteria\n\n1. **AC9: x.** ("an owner quote")'
eq "$(kbx "$K" check intent 2026-11-08-st)" 65 "[card-quote] a second ## Acceptance criteria: rc 65"
has "$(cat "$TMP/err")" '- section `## Acceptance criteria` appears 2 times' "[card-quote] …it names the section"
card "$F" story P2 "${STORY/- A Jira sync script. (\"Script đồng bộ làm sau\")/A Jira sync script, in prose.}"
eq "$(kb "$K" check intent 2026-11-08-st --strict)" 65 "[card-quote] a Not doing written as prose with no quote: rc 65 under --strict"
eq "$(kb "$K" check intent --strict 2026-11-08-st)" 65 "[card-quote] …--strict before the intent is read the same"
card "$F" story P2 "${STORY/- A Jira sync script. (\"Script đồng bộ làm sau\")/none}"
eq "$(kb "$K" check intent 2026-11-08-st --strict)" 0 "[card-quote] a Not doing that is the one line none: rc 0 under --strict"
card "$F" story P2 "${STORY/ (page decision mot-tep (a))/$'\n   - nested under AC2: (\"the owner\'s words\")'}"
eq "$(kb "$K" check intent 2026-11-08-st)" 0 "[card-quote] AC2's quote in a bullet nested 3 spaces under it: rc 0 (one item, not two)"
card "$F" story P2 "${STORY/2. \*\*AC2: a card.\*\* Given a story, when checked, then each AC has a quote. (page decision mot-tep (a))/ 2. **AC2: a card.** No quote here.}"
eq "$(kbx "$K" check intent 2026-11-08-st)" 65 "[card-quote] an unquoted AC2 indented one space after a quoted AC1: rc 65"
hasline "$(cat "$TMP/err")" '- AC2 has no quote: the owner'"'"'s words in "…", or (page decision <id> (<option>))' "[card-quote] …it is an AC of its own, named"
card "$F" story P2 "${STORY/1. \*\*AC1/1.$'\t'**AC1}"; F2=$(sed 's/^2\. \*\*AC2: a card\.\*\* .*/   2. **AC2: a card.** No quote here./' "$F"); printf '%s\n' "$F2" > "$F"
eq "$(kbx "$K" check intent 2026-11-08-st)" 65 "[card-quote] AC1 with a tab after its marker, an unquoted AC2 three spaces in: rc 65 (the tab reaches column 4)"
has "$(cat "$TMP/err")" "AC2 has no quote" "[card-quote] …AC2 is named"
# the whole-kb check: an unquoted story AC already on main only warns there; the same one new in the change is red
W=$(mk_origin); card "$W/kb/intent/2026-11-08-old.md" story P2 "${STORY/ (page decision mot-tep (a))/}"
git_ -C "$W" add -A; git_ -C "$W" commit -q -m old; git_ -C "$W" push -q origin main
eq "$(kb "$W" check)" 0 "[card-quote] kb.py check: an intent on the merge base is not judged: rc 0"
eq "$(kb "$W" check intent 2026-11-08-old)" 0 "[card-quote] …check intent on it only warns: rc 0"
has "$(cat "$TMP/out")" "WARNING kb/intent/2026-11-08-old.md: AC2 has no quote" "[card-quote] …the warning names AC2"
cp "$W/kb/intent/2026-11-08-old.md" "$W/kb/intent/2026-11-08-new.md"
eq "$(kbx "$W" check)" 65 "[card-quote] kb.py check: the same intent new in the change: rc 65"
has "$(cat "$TMP/err")" "kb/intent/2026-11-08-new.md does not pass its card" "[card-quote] …it names the new intent"
hasnt "$(cat "$TMP/err")" "2026-11-08-old.md" "[card-quote] …and not the old one"


echo "== nothing written outside the scratch tree =="
eq "$(tree_hash "$SRC_ROOT")" "$H0" "the repository tree is unchanged by the suite"
echo; summary
