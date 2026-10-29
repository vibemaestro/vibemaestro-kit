#!/usr/bin/env bash
# =============================================================================
# kb.py plan status, kb.py check links and the PR body's plan-row line (scripts/kb_plan.py, kb.py, open_pr.py)
# =============================================================================
# Offline: GitHub is the fake gh of tests/fixtures/kb_plan_gh.py on a JSON world. Families:
#   [S] plan status: every state, the links that count and the ones that must not (a mention in a title or body, a closed PR),
#       drift (version at the merge commit, local and through gh api; dependency; two PRs; dropped and merged), --json
#   [N] no gh, or gh failing as a network error does: the rows as the file says, GitHub `not checked`, rc 0
#   [L] check links: each broken kind fails in a changed file and is OLD in an unchanged one; a deleted row an unchanged intent
#       still names; --all; no base
#   [P] open_pr.py --dry-run: one `Plan row:` line for an intent with plan:, none without
#   [B] planted breaks on a copy of the plugin: each turns its named case red
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
. "$HERE/fixtures/lib.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
export PYTHONDONTWRITEBYTECODE=1
H0=$(tree_hash "$SRC_ROOT")
KBPY="$PLUGIN/scripts/kb.py"
OPENPR="$PLUGIN/scripts/open_pr.py"

FB="$TMP/fakebin"; mkdir -p "$FB"
printf '#!/bin/sh\nexec python3 "%s" "$@"\n' "$HERE/fixtures/kb_plan_gh.py" > "$FB/gh"; chmod +x "$FB/gh"
export PATH="$FB:$PATH" FAKE_LOG="$TMP/gh.log" FAKE_GH_WORLD="$TMP/world.json"
: > "$FAKE_LOG"
# a PATH with python3 and git only: no gh at all
NOGH="$TMP/nogh"; mkdir -p "$NOGH"; ln -s "$(command -v python3)" "$NOGH/python3"; ln -s "$(command -v git)" "$NOGH/git"

PLAN=kb/plans/2026-01-01-p.md
fm() {  # fm <file> <frontmatter lines…> — an intent or spec with that frontmatter and a short body
  local f=$1; shift; mkdir -p "$(dirname "$f")"
  { echo '---'; printf '%s\n' "$@"; echo 'description: "fixture"'; echo '---'; echo; echo '# fixture'; } > "$f"
}

# ── the status repository: a plan of rows A..N, intents, two commits that carry a plugin manifest ──────────────────────────────────
mk_status_repo() {  # mk_status_repo <dir> — prints nothing; writes world.json for that repo
  local r=$1
  git_ init -q -b main "$r"
  mkdir -p "$r/kb/plans" "$r/kb/intent" "$r/plugins/vibemaestro-x/.claude-plugin"
  printf '{"name": "vibemaestro-x", "version": "1.1.0"}\n' > "$r/plugins/vibemaestro-x/.claude-plugin/plugin.json"
  git_ -C "$r" add -A && git_ -C "$r" commit -qm m1
  M1=$(git_ -C "$r" rev-parse HEAD)
  cat > "$r/$PLAN" <<'EOF'
---
description: "fixture plan"
---

# Plan — fixture

| Level | Opens with | PRs |
|---|---|---|
| one | a prose table, not a row table | A |

## Rows

| Row | Must be true | Acceptance | Depends on | Version | Model | Link |
|---|---|---|---|---|---|---|
| A | merged by explicit PR, version matches | `true` → 0 | — | x 1.1.0 | Sonnet high | #11 |
| B | merged at a commit not fetched, version differs | `true` | A | x 1.3.0 | — | #12 |
| C | back-linked intent in the working tree, PR open, CI green | `true` | A | — | — | — |
| D | back-linked intent only at the PR head, CI red | `true` | B | — | — | — |
| E | intent open, its dependency planned | `true` | F | — | — | — |
| F | planned | `true` | — | — | — | — |
| G | dropped | `true` | — | — | — | dropped: folded into C |
| H | only mentioned by an unrelated PR | `true` | — | — | — | — |
| I | its only PR closed unmerged | `true` | — | — | — | #16 |
| J | two PRs open for one row | `true` | — | — | — | — |
| K | merged, and another PR still open | `true` | — | y 0.1.0 | — | #19 |
| L | dropped, but a PR merged | `true` | — | — | — | dropped: not needed · #21 |
| N1 | an intent names N10, not this row | `true` | — | — | — | — |
| P | CI pending on an open PR named by its branch | `true` | — | — | — | intent/2026-01-03-p |
| Q | a longer branch is not its prefix | `true` | — | — | — | intent/2026-01-03-p-v2/w1 |
| R | a PR URL of another repository | `true` | — | — | — | https://github.com/other/repo/pull/11 |
| S | a PR URL of this repository | `true` | — | — | — | https://example.invalid/o/r/pull/13 |
| T | a relative link to the intent | `true` | — | — | — | [intent](../intent/2026-01-01-t.md) |
| U | unlinked, an open PR's title names it | `true` | — | — | — | — |
| V | unlinked, a merged PR's title names it | `true` | — | — | — | — |
| W | unlinked, only a closed PR's title names it | `true` | — | — | — | — |
| X1 | unlinked, a PR title names X10 | `true` | — | — | — | — |

## Decisions

- 2026-01-01 10:00 — "fixture" — [here](https://example.invalid/x)
EOF
  fm "$r/kb/intent/2026-01-01-c.md" "plan: $PLAN#C"
  fm "$r/kb/intent/2026-01-01-e.md" "plan: $PLAN#E" "issue: 31"
  fm "$r/kb/intent/2026-01-01-j1.md" "plan: $PLAN#J"
  fm "$r/kb/intent/2026-01-01-j2.md" "plan: $PLAN#J"
  fm "$r/kb/intent/2026-01-01-k2.md" "plan: $PLAN#K"
  fm "$r/kb/intent/2026-01-01-n.md" "plan: $PLAN#N10"
  fm "$r/kb/intent/2026-01-01-unrelated.md" "plan: $PLAN#A2"
  # a plugin with no manifest version (the private kit): its released version is its CHANGELOG's first heading
  mkdir -p "$r/plugins/vibemaestro-y/.claude-plugin"; printf '{"name": "vibemaestro-y"}\n' > "$r/plugins/vibemaestro-y/.claude-plugin/plugin.json"
  printf '# Changelog of vibemaestro-y\n\n## 0.1.0\n\n- minor: first\n' > "$r/plugins/vibemaestro-y/CHANGELOG.md"
  git_ -C "$r" add -A && git_ -C "$r" commit -qm m2
  M2=$(git_ -C "$r" rev-parse HEAD)
  local D_HEAD=dddddddddddddddddddddddddddddddddddddddd MISSING=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
  python3 - "$TMP/world.json" "$M1" "$M2" "$D_HEAD" "$MISSING" "$PLAN" <<'EOF'
import json, sys
out, m1, m2, dh, miss, plan = sys.argv[1:]
def pr(n, state, branch, head="a" * 40, merge=None, title="t", body="b", draft=False):
    return {"number": n, "state": state, "headRefName": branch, "headRefOid": head, "isDraft": draft,
            "mergeCommit": {"oid": merge} if merge else None, "url": "https://example.invalid/o/r/pull/%d" % n, "title": title, "body": body}
prs = [pr(11, "MERGED", "intent/2026-01-01-a", merge=m1),
       pr(12, "MERGED", "intent/2026-01-01-b", merge=miss),
       pr(13, "OPEN", "intent/2026-01-01-c", head="c" * 40),
       pr(14, "OPEN", "intent/2026-01-02-d", head=dh, draft=True),
       pr(15, "MERGED", "intent/2026-01-01-unrelated", merge=m2, title="fix row H (#H) of the plan",
          body="Plan row: `H` of `%s`\nkb/plans/2026-01-01-p.md#H\n%s#H" % (plan, plan)),
       pr(16, "CLOSED", "intent/2026-01-01-i"),
       pr(17, "OPEN", "intent/2026-01-01-j1"), pr(18, "OPEN", "intent/2026-01-01-j2"),
       pr(19, "MERGED", "intent/2026-01-01-k", merge=m2), pr(20, "OPEN", "intent/2026-01-01-k2"),
       pr(21, "MERGED", "intent/2026-01-01-l", merge=m2),
       pr(22, "OPEN", "intent/2026-01-03-p", head="f" * 40),
       pr(23, "CLOSED", "intent/2026-01-01-c", title="an earlier try at C"),
       pr(24, "OPEN", "intent/2026-01-01-t"),
       pr(25, "OPEN", "feature/u", title="feat(x): do u (Row U)"),
       pr(26, "MERGED", "feature/v", merge=m2, title="feat(x): do v (row V) (#26)"),
       pr(27, "CLOSED", "feature/w", title="try again (row W)"),
       pr(28, "OPEN", "feature/x10", title="feat(x): x ten (row X10)")]
checks = {"13": [{"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "SUCCESS", "name": "t"}],
          "14": [{"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "SUCCESS", "name": "a"},
                 {"__typename": "CheckRun", "status": "COMPLETED", "conclusion": "FAILURE", "name": "b"}],
          "22": [{"__typename": "StatusContext", "state": "PENDING", "context": "ci"}]}
files = {"%s:kb/intent/2026-01-02-d.md" % dh: '---\nplan: %s#D\n---\n' % plan,
         "%s:plugins/vibemaestro-x/.claude-plugin/plugin.json" % miss: '{"name": "vibemaestro-x", "version": "1.2.0"}'}
json.dump({"prs": prs, "checks": checks, "issues": {"31": "OPEN"}, "files": files}, open(out, "w"))
EOF
}

row() { printf '%s\n' "$1" | awk -v id="$2" '$1 == id {print; exit}'; }   # row <status output> <id> → its line

fam_status() {
  echo "== [S] plan status =="
  local r o rc j; r=$(mktemp -d "$TMP/s.XXXXXX")
  mk_status_repo "$r"
  o=$(cd "$r" && python3 "$KBPY" plan status "$PLAN" 2>&1); rc=$?
  eq "$rc" 0 "[S] plan status: rc 0"
  has "$o" "22 rows · GitHub: checked" "[S] the header counts the rows of the row table only (the prose table is not one)"
  has "$(row "$o" A)" "merged       #11 " "[S] A: merged through its explicit #N"
  has "$(row "$o" A)" "x 1.1.0" "[S] A: the version read at the merge commit (local object)"
  has "$(row "$o" B)" "merged       #12" "[S] B: merged"
  has "$o" "B: planned x 1.3.0, merged x 1.2.0 (#12)" "[S] B: version drift, the manifest read through gh api (commit not fetched)"
  hasnt "$o" "y version at the merge commit not checked" "[S] K: a manifest with no version: the released version read from its CHANGELOG"
  hasnt "$o" "K: planned y" "[S] K: …and it matches the plan (no drift)"
  has "$(row "$o" C)" "PR open      #13 head ccccccc · ready · CI pass" "[S] C: PR open through the back-linked intent in the working tree"
  hasnt "$(row "$o" C)" "#23" "[S] C: the closed earlier PR on the same branch is not shown as its PR state"
  has "$(row "$o" D)" "PR open      #14 head ddddddd · draft · CI fail" "[S] D: PR open through the intent read at the PR head (gh api)"
  has "$(row "$o" E)" "intent open  kb/intent/2026-01-01-e.md · issue #31 open" "[S] E: intent open with its issue"
  has "$o" "E is intent open but its dependency F is planned" "[S] E: dependency drift"
  hasnt "$o" "C is PR open but its dependency A" "[S] C: a merged dependency is no drift"
  case "$o" in *"D is PR open but its dependency B"*) bad "[S] D: a merged dependency (B) is no drift";; *) ok "[S] D: a merged dependency (B) is no drift";; esac
  has "$(row "$o" F)" "planned" "[S] F: planned"
  has "$(row "$o" G)" "dropped      folded into C" "[S] G: dropped with its reason"
  has "$(row "$o" H)" "H    planned" "[S] H: a PR that only mentions the row (title, body) is not linked"
  has "$(row "$o" I)" "planned" "[S] I: a closed unmerged PR sets no state"
  has "$o" "note: PR #16 closed unmerged" "[S] I: …and is a note"
  has "$o" "J: 2 PRs open for one row (#17, #18)" "[S] J: two PRs for one row is drift"
  has "$o" "K: merged as #19, and PR #20 is still open for it" "[S] K: merged and another PR open is drift"
  has "$o" "L: dropped (not needed · #21) but PR #21 merged" "[S] L: a dropped row with a merged PR is drift"
  has "$(row "$o" N1)" "planned" "[S] N1: an intent naming row N10 does not link N1 (ids match whole)"
  has "$(row "$o" P)" "PR open      #22 head fffffff · ready · CI pending" "[S] P: an explicit branch finds its PR; a pending status is pending"
  has "$(row "$o" Q)" "Q    planned" "[S] Q: a branch link is read whole, not as the prefix intent/2026-01-03-p (#22)"
  has "$(row "$o" R)" "R    planned" "[S] R: a PR URL of another repository does not link this repository's #11"
  has "$o" "note: a PR URL of another repository is not this row's PR: other/repo/pull/11" "[S] R: …and is a note"
  has "$(row "$o" S)" "PR open      #13" "[S] S: a PR URL of this repository links its PR"
  has "$(row "$o" T)" "PR open      #24" "[S] T: a relative markdown link to the intent finds its PR"
  has "$(row "$o" U)" "U    planned" "[S] U: a row an open PR's title names (row U) stays planned (the hint is not a link)"
  has "$o" "note: PR #25 (open) has a title that names this row, but the row does not link it" "[S] U: …with a note naming the PR (the case of the id does not matter)"
  has "$(row "$o" V)" "V    planned" "[S] V: …a merged PR too: still planned"
  has "$o" "note: PR #26 (merged) has a title that names this row, but the row does not link it" "[S] V: …with a note"
  hasnt "$o" "PR #27 (closed)" "[S] W: a closed PR's title gives no note"
  hasnt "$o" "PR #28 (open)" "[S] X1: (row X10) is not row X1 (the id matches whole)"
  hasnt "$(row "$o" H)" "title that names" "[S] H: 'fix row H (#H)' is not the (row H) form: no note"
  eq "$(printf '%s\n' "$o" | grep -c 'title that names this row')" 2 "[S] exactly the two PRs above give a note"
  j=$(cd "$r" && python3 "$KBPY" plan status "$PLAN" --json 2>&1)
  has "$j" "PR #25 (open) has a title that names this row" "[S] --json: the same note in the row's notes"
  eq "$(printf '%s' "$j" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(",".join(r["id"]+"="+r["state"] for r in d["rows"][:5]), len(d["drift"]))' 2>&1)" \
     "A=merged,B=merged,C=PR open,D=PR open,E=intent open 5" "[S] --json: the same states, and the drift list"
  eq "$(cd "$r" && python3 "$KBPY" plan status kb/plans/none.md >/dev/null 2>&1; echo $?)" 66 "[S] a missing plan file: rc 66"
  printf -- '---\ndescription: "x"\n---\n\n| A | B |\n|---|---|\n| 1 | 2 |\n' > "$r/kb/plans/2026-01-02-norows.md"
  eq "$(cd "$r" && python3 "$KBPY" plan status kb/plans/2026-01-02-norows.md >/dev/null 2>&1; echo $?)" 66 "[S] a plan with no row table: rc 66"
  eq "$(cd "$r" && python3 "$KBPY" plan status >/dev/null 2>&1; echo $?)" 64 "[S] no plan named: rc 64"
  eq "$(git_ -C "$r" status --porcelain | grep -v norows)" "" "[S] read-only: the repository is unchanged"
}

fam_nogh() {
  echo "== [N] no gh, or gh down =="
  local r o rc; r=$(mktemp -d "$TMP/n.XXXXXX")
  mk_status_repo "$r"
  o=$(cd "$r" && PATH="$NOGH" python3 "$KBPY" plan status "$PLAN" 2>&1); rc=$?
  eq "$rc" 0 "[N] no gh: rc 0"
  has "$o" "GitHub: not checked (no gh on PATH)" "[N] no gh: GitHub is labelled not checked"
  has "$(row "$o" A)" "not checked  #11" "[N] no gh: a row shows what the file says"
  has "$(row "$o" G)" "dropped" "[N] no gh: dropped is read from the file"
  has "$(row "$o" S)" "not checked  #13" "[N] no gh: a row linked by a PR URL still shows that PR, unverified"
  hasnt "$o" "merged       #" "[N] no gh: nothing is called merged"
  o=$(cd "$r" && FAKE_GH_FAIL=1 python3 "$KBPY" plan status "$PLAN" 2>&1); rc=$?
  eq "$rc" 0 "[N] gh failing (network): rc 0"
  has "$o" "not checked (gh pr list: error connecting to api.github.com)" "[N] gh failing: the reason is named"
  : > "$FAKE_LOG"
  o=$(cd "$r" && FAKE_GH_FAIL_AFTER=1 python3 "$KBPY" plan status "$PLAN" 2>&1); rc=$?
  eq "$rc" 0 "[N] gh failing after the PR list: rc 0"
  has "$o" "GitHub: partly checked" "[N] gh failing after the PR list: the header says partly checked"
  eq "$(printf '%s\n' "$o" | grep -cx 'drift: none')" 0 "[N] gh failing after the PR list: never 'drift: none'"
  has "$(row "$o" C)" "CI not checked" "[N] gh failing after the PR list: CI that was not read is 'not checked', not 'none'"
  has "$o" "not checked: gh api kb/intent/2026-01-02-d.md" "[N] gh failing after the PR list: the intent not read at a PR head is named"
  : > "$FAKE_LOG"
  o=$(cd "$r" && FAKE_GH_NO_ISSUES=1 python3 "$KBPY" plan status "$PLAN" 2>&1)
  has "$o" "B: planned x 1.3.0, merged x 1.2.0 (#12)" "[N] an issue gh cannot read does not turn off the later calls (B's drift still read)"
  has "$o" "GitHub: partly checked" "[N] …and the header says partly checked"
}

# ── check links: a repository with origin/main, then a branch that changes files ───────────────────────────────────────────────────
mk_links_repo() {  # mk_links_repo <dir> — a clean kb on main (origin/main points at it), checked out on branch work
  local r=$1
  git_ init -q -b main "$r"
  mkdir -p "$r/kb/plans"
  cat > "$r/$PLAN" <<'EOF'
---
description: "links fixture"
---

# Plan

| Row | Must be true | Acceptance | Depends on | Version | Model | Link |
|---|---|---|---|---|---|---|
| A | one, spec kb/specs/2026-01-01-a.md | `true` | — | — | — | kb/intent/2026-01-01-a.md |
| B | two | `true` | A | — | — | — |

## Decisions

- 2026-01-01 — "words" — kb/specs/2026-01-01-a.md
EOF
  fm "$r/kb/intent/2026-01-01-a.md" "plan: $PLAN#A" "spec: kb/specs/2026-01-01-a.md"
  fm "$r/kb/specs/2026-01-01-a.md" "plan: $PLAN#A"; printf 'Intent: kb/intent/2026-01-01-a.md\n' >> "$r/kb/specs/2026-01-01-a.md"
  fm "$r/kb/intent/2026-01-01-b.md" "plan: $PLAN#B" "spec: kb/specs/2026-01-01-b.md"
  fm "$r/kb/specs/2026-01-01-b.md"; printf 'Intent: kb/intent/2026-01-01-b.md\n' >> "$r/kb/specs/2026-01-01-b.md"
  # an old pair that does not name each other: OLD, never failing, while it is unchanged
  fm "$r/kb/intent/2026-01-01-old.md"
  fm "$r/kb/specs/2026-01-01-old.md"; printf 'Intent: kb/intent/2026-01-01-old.md\n' >> "$r/kb/specs/2026-01-01-old.md"
  git_ -C "$r" add -A && git_ -C "$r" commit -qm base
  git_ -C "$r" update-ref refs/remotes/origin/main HEAD
  git_ -C "$r" checkout -q -b work
}

links_case() {  # links_case <label> <expected rc> <expected text> <shell edit run in the repo>
  local label=$1 want=$2 text=$3 edit=$4 r o rc; r=$(mktemp -d "$TMP/l.XXXXXX")
  mk_links_repo "$r"
  (cd "$r" && eval "$edit")
  o=$(cd "$r" && python3 "$KBPY" check links 2>&1); rc=$?
  eq "$rc" "$want" "[L] $label: rc $want"
  has "$o" "$text" "[L] $label: names it"
}

fam_links() {
  echo "== [L] check links =="
  links_case "a clean branch" 0 "links: 0 failing, 1 in unchanged files · base: origin/main" ":"
  links_case "an old unchanged pair" 0 "OLD  kb/specs/2026-01-01-old.md:7: Intent: kb/intent/2026-01-01-old.md does not name this spec" ":"
  links_case "the old pair, changed" 65 "FAIL kb/specs/2026-01-01-old.md:7" "echo more >> kb/specs/2026-01-01-old.md"
  links_case "plan: names a missing file" 65 "plan: kb/plans/2026-01-09-gone.md does not exist" \
    "sed -i 's|^plan: .*|plan: kb/plans/2026-01-09-gone.md#A|' kb/intent/2026-01-01-b.md"
  links_case "plan: names a missing row" 65 "plan: $PLAN has no row 'Z'" "sed -i 's|^plan: .*|plan: $PLAN#Z|' kb/intent/2026-01-01-b.md"
  links_case "plan: is not a plan reference" 65 "is not kb/plans/<file>.md#<row id>" "sed -i 's|^plan: .*|plan: row B|' kb/intent/2026-01-01-b.md"
  links_case "an intent does not name its spec" 65 "Intent: kb/intent/2026-01-01-b.md does not name this spec" \
    "sed -i '/^spec:/d' kb/intent/2026-01-01-b.md"
  links_case "spec: names a missing spec" 65 "spec: kb/specs/2026-01-09-x.md does not exist" \
    "sed -i 's|^spec: .*|spec: kb/specs/2026-01-09-x.md|' kb/intent/2026-01-01-b.md"
  links_case "an intent and its spec disagree on plan:" 65 "but its intent kb/intent/2026-01-01-a.md says" \
    "sed -i 's|^plan: .*|plan: $PLAN#B|' kb/specs/2026-01-01-a.md"
  links_case "an unknown dependency" 65 "row B depends on 'Q', which is not a row of this plan" "sed -i 's/| two | \`true\` | A |/| two | \`true\` | Q |/' $PLAN"
  links_case "a missing kb path in a row" 65 "kb/specs/2026-01-09-none.md does not exist" "sed -i 's|one, spec kb/specs/2026-01-01-a.md|one, spec kb/specs/2026-01-09-none.md|' $PLAN"
  links_case "a missing kb path in Decisions" 65 "$PLAN:14: kb/specs/2026-01-09-dec.md does not exist" "sed -i 's|\"words\" — kb/specs/2026-01-01-a.md|\"words\" — kb/specs/2026-01-09-dec.md|' $PLAN"
  links_case "a row id used twice" 65 "row id 'B' is used twice" "sed -i '/^| B | two/p' $PLAN"
  links_case "a Link intent naming another row" 65 "row A links kb/intent/2026-01-01-a.md, whose plan: is" \
    "sed -i 's|^plan: .*|plan: $PLAN#B|' kb/intent/2026-01-01-a.md kb/specs/2026-01-01-a.md"
  links_case "a ./ path in a row" 65 "kb/specs/2026-01-09-gone.md does not exist" "sed -i 's|one, spec kb/specs/2026-01-01-a.md|one, spec ./kb/specs/2026-01-09-gone.md|' $PLAN"
  links_case "a ../kb/ path in a row is not a root path" 65 "kb/kb/specs/2026-01-01-a.md does not exist" "sed -i 's|one, spec kb/specs/2026-01-01-a.md|one, spec ../kb/specs/2026-01-01-a.md|' $PLAN"
  links_case "a relative markdown link in a row" 65 "kb/specs/2026-01-09-gone.md does not exist" "sed -i 's|one, spec kb/specs/2026-01-01-a.md|one, [spec](../specs/2026-01-09-gone.md)|' $PLAN"
  links_case "a second Intent: line, in bold" 65 "Intent: kb/intent/2026-01-09-gone.md does not exist" "printf '**Intent:** kb/intent/2026-01-09-gone.md\n' >> kb/specs/2026-01-01-b.md"
  links_case "plan: in the spec only" 65 "plan: is in the spec but not in its intent kb/intent/2026-01-01-b.md" \
    "sed -i '/^plan:/d' kb/intent/2026-01-01-b.md; sed -i 's|^description:|plan: $PLAN#B\ndescription:|' kb/specs/2026-01-01-b.md"
  links_case "a Link cell nothing reads" 65 "row B: its Link cell names no PR" "sed -i 's/^\(| B | two .*\)| — |$/\1| see the notes |/' $PLAN"
  links_case "a missing path under Owner decisions" 65 "kb/specs/2026-01-09-dec.md does not exist" \
    "sed -i 's|^## Decisions|## Owner decisions|; s|\"words\" — kb/specs/2026-01-01-a.md|\"words\" — kb/specs/2026-01-09-dec.md|' $PLAN"
  links_case "a duplicate row inside an HTML comment" 0 "links: 0 failing" "printf '<!--\n| Row | Link |\n|---|---|\n| B | — |\n-->\n' >> $PLAN"
  links_case "a missing intent in the plan's own header" 65 "kb/intent/2026-01-09-top.md does not exist" "sed -i 's|^# Plan$|# Plan\n\nIntent: kb/intent/2026-01-09-top.md|' $PLAN"
  links_case "an upper-case Plan: key" 65 "frontmatter key 'Plan' must be written 'plan'" "sed -i 's|^plan:|Plan:|' kb/intent/2026-01-01-b.md"
  links_case "a longer path is not the spec's path" 65 "Intent: kb/intent/2026-01-01-b.md does not name this spec" \
    "sed -i 's|^spec: .*|see: kb/specs/2026-01-01-b.md.old|' kb/intent/2026-01-01-b.md"
  links_case "a deleted row an unchanged intent still names" 65 "FAIL kb/intent/2026-01-01-b.md:2: plan: $PLAN has no row 'B'" \
    "sed -i '/^| B | two/d' $PLAN"
  links_case "a deleted plan an unchanged intent still names" 65 "FAIL kb/intent/2026-01-01-a.md:2: plan: $PLAN does not exist" "git rm -q $PLAN"
  local r o; r=$(mktemp -d "$TMP/l.XXXXXX")
  mk_links_repo "$r"
  eq "$(cd "$r" && python3 "$KBPY" check links --all >/dev/null 2>&1; echo $?)" 65 "[L] --all: the old pair fails too (rc 65)"
  eq "$(cd "$r" && python3 "$KBPY" check links --base main >/dev/null 2>&1; echo $?)" 0 "[L] --base main: rc 0"
  eq "$(cd "$r" && python3 "$KBPY" check links --base nope >/dev/null 2>&1; echo $?)" 65 "[L] --base that does not resolve: every problem fails"
  has "$(cd "$r" && python3 "$KBPY" check links --base nope 2>&1)" "base: no base (nope does not resolve)" "[L] …and says so"
  eq "$(cd "$r" && python3 "$KBPY" check links --all --base main >/dev/null 2>&1; echo $?)" 64 "[L] --all with --base: rc 64"
  echo x > "$r/kb/specs/2026-01-03-new.md"; printf -- '---\nplan: %s#Z\n---\n' "$PLAN" > "$r/kb/intent/2026-01-03-new.md"
  o=$(cd "$r" && python3 "$KBPY" check links 2>&1)
  has "$o" "FAIL kb/intent/2026-01-03-new.md:2: plan: $PLAN has no row 'Z'" "[L] an untracked new intent counts as changed"
}

# ── recon columns: Current state @SHA and Shared files, on an old plan (no such columns) and a new one ─────────────────────────────
mk_recon_plan() {  # mk_recon_plan <repo> — a new-shape plan on main: A..E share files, each pair ordered, marked merge main or dropped
  local r=$1
  mkdir -p "$r/kb/records"
  fm "$r/kb/records/2026-01-01-recon.md"
  cat > "$r/$PLAN" <<'EOF'
---
description: "recon fixture"
---

# Plan

| Row | Must be true | Current state @SHA | Shared files | Acceptance | Depends on | Version | Model | Link |
|---|---|---|---|---|---|---|---|---|
| A | one | absent; seam `read_plan` @abc1234 | `scripts/a.py` | `true` | — | — | — | — |
| B | two | in part @abc1234def, kb/records/2026-01-01-recon.md | scripts/a.py, scripts/b.py | `true` | A | — | — | — |
| C | three | — | scripts/b.py (merge main) | `true` | — | — | — | — |
| D | four | absent @abc1234def0 | scripts/a.py | `true` | B | — | — | — |
| E | five | absent @abc1234 | scripts/a.py | `true` | — | — | — | dropped: folded into A |
EOF
}

recon_case() {  # recon_case <label> <expected rc> <expected text> <shell edit run in the repo>
  local label=$1 want=$2 text=$3 edit=$4 r o rc; r=$(mktemp -d "$TMP/r.XXXXXX")
  mk_links_repo "$r"
  (cd "$r" && eval "$edit")
  o=$(cd "$r" && python3 "$KBPY" check links 2>&1); rc=$?
  eq "$rc" "$want" "[R] $label: rc $want"
  has "$o" "$text" "[R] $label: names it"
}

fam_recon() {
  echo "== [R] recon columns (Current state @SHA, Shared files) =="
  local r o j
  printf '{"prs": []}\n' > "$TMP/world-empty.json"
  # an old plan: no recon column, so no recon check, and the status carries empty recon fields
  recon_case "an old plan, changed" 0 "links: 0 failing" "echo >> $PLAN"
  r=$(mktemp -d "$TMP/r.XXXXXX"); mk_links_repo "$r"
  j=$(cd "$r" && FAKE_GH_WORLD="$TMP/world-empty.json" python3 "$KBPY" plan status "$PLAN" --json 2>&1)
  eq "$(printf '%s' "$j" | python3 -c 'import json,sys; r=json.load(sys.stdin)["rows"][0]; print(r["current"], r["shared"], r["merge_main"])' 2>&1)" \
     "None [] False" "[R] old plan --json: current None, shared [], merge_main False"
  o=$(cd "$r" && FAKE_GH_WORLD="$TMP/world-empty.json" python3 "$KBPY" plan status "$PLAN" 2>&1)
  hasnt "$o" "@" "[R] old plan: the printed status shows no recon SHA"
  # a new plan: the columns are read, and two new FAILs apply
  recon_case "a new plan, valid" 0 "links: 0 failing" "mk_recon_plan ."
  recon_case "a Current state cell with no SHA" 65 "row A: its Current state cell is not pinned to a SHA (@<sha>" \
    "mk_recon_plan .; sed -i 's/absent; seam \`read_plan\` @abc1234/absent; seam read_plan/' $PLAN"
  recon_case "a SHA too short" 65 "row A: its Current state cell is not pinned to a SHA" \
    "mk_recon_plan .; sed -i 's/seam \`read_plan\` @abc1234/seam @abc12/' $PLAN"
  recon_case "two rows share a file with no order" 65 "rows A and B share scripts/a.py" \
    "mk_recon_plan .; sed -i 's/^\(| B | .*\)| A | — | — | — |$/\1| — | — | — | — |/' $PLAN"
  recon_case "a shared file with no order, marked merge main" 0 "links: 0 failing" \
    "mk_recon_plan .; sed -i 's/^\(| B | .*\)| A | — | — | — |$/\1| — | — | — | — |/; s/^| A | one | \(.*\) | \`scripts\/a.py\` |/| A | one | \1 | scripts\/a.py (merge main) |/' $PLAN"
  recon_case "a missing recon note" 65 "kb/records/2026-01-01-recon.md does not exist" "mk_recon_plan .; rm kb/records/2026-01-01-recon.md"
  recon_case "Vietnamese headers" 65 "row A: its Current state cell is not pinned to a SHA" \
    "mk_recon_plan .; sed -i 's/| Current state @SHA | Shared files |/| Hiện trạng @SHA | File chung |/; s/seam \`read_plan\` @abc1234/seam/' $PLAN"
  recon_case "an old plan's Hiện trạng column with no @ in its header is not the recon column" 0 "links: 0 failing" \
    "mk_recon_plan .; sed -i 's/| Current state @SHA |/| Hiện trạng |/; s/seam \`read_plan\` @abc1234/đang chạy/' $PLAN"
  recon_case "an upper-case SHA" 0 "links: 0 failing" "mk_recon_plan .; sed -i 's/seam \`read_plan\` @abc1234/seam @ABC1234/' $PLAN"
  recon_case "a dropped row with no SHA" 0 "links: 0 failing" "mk_recon_plan .; sed -i 's/^| E | five | absent @abc1234 |/| E | five | absent |/' $PLAN"
  recon_case "shared files split on ;" 65 "rows C and D share scripts/b.py" \
    "mk_recon_plan .; sed -i 's/^| D | four | \(.*\) | scripts\/a.py |/| D | four | \1 | scripts\/a.py; scripts\/b.py |/; s/scripts\/b.py (merge main)/scripts\/b.py/; s/^\(| C | .*\)| — | — | — | — |$/\1| B | — | — | — |/' $PLAN"
  r=$(mktemp -d "$TMP/r.XXXXXX"); mk_links_repo "$r"; (cd "$r" && mk_recon_plan .)
  j=$(cd "$r" && FAKE_GH_WORLD="$TMP/world-empty.json" python3 "$KBPY" plan status "$PLAN" --json 2>&1)
  eq "$(printf '%s' "$j" | python3 -c 'import json,sys
for r in json.load(sys.stdin)["rows"][:3]: print(r["id"], (r["current"] or {}).get("sha"), ",".join(r["shared"]), r["merge_main"])' 2>&1)" \
     "A abc1234 scripts/a.py False
B abc1234def scripts/a.py,scripts/b.py False
C None scripts/b.py True" "[R] new plan --json: the SHA, the shared files without marks, merge main"
  o=$(cd "$r" && FAKE_GH_WORLD="$TMP/world-empty.json" python3 "$KBPY" plan status "$PLAN" 2>&1)
  has "$(row "$o" D)" "planned      depends on B · @abc1234  — four" "[R] new plan: a planned row shows its recon SHA after its dependencies, cut to 7"
  hasnt "$(row "$o" C)" "@" "[R] new plan: a row with no recon SHA shows none"
}

fam_pr() {
  echo "== [P] the plan-row line of the PR body =="
  local r w o; r=$(mktemp -d "$TMP/p.XXXXXX")
  git_ init -q -b main "$r"; mkdir -p "$r/kb/intent"
  fm "$r/kb/intent/2026-01-01-c.md" "plan: $PLAN#C"
  fm "$r/kb/intent/2026-01-01-none.md"
  git_ -C "$r" add -A && git_ -C "$r" commit -qm base
  printf 'the summary\n' > "$TMP/sum.md"; printf 'ok\n' > "$TMP/ev.txt"
  w="$r/.claude/worktrees/c"; git_ -C "$r" worktree add -q -b intent/2026-01-01-c "$w"
  o=$(cd "$w" && python3 "$OPENPR" --title "feat(x): c" --summary-file "$TMP/sum.md" --evidence-file "$TMP/ev.txt" --dry-run --repo o/r 2>/dev/null)
  eq "$(printf '%s' "$o" | python3 -c 'import json,sys; b=json.load(sys.stdin)["body"]; print([l for l in b.split("\n") if l.startswith("Plan row:")])')" \
     "['Plan row: [C of $PLAN](https://github.com/o/r/blob/intent/2026-01-01-c/$PLAN)']" "[P] an intent with plan: gets one Plan row line, linked"
  o=$(cd "$w" && python3 "$OPENPR" --title "feat(x): c" --summary-file "$TMP/sum.md" --evidence-file "$TMP/ev.txt" --dry-run 2>/dev/null)
  has "$o" "Plan row: \`C\` of \`$PLAN\`" "[P] without --repo: the row and the file as text"
  w="$r/.claude/worktrees/n"; git_ -C "$r" worktree add -q -b intent/2026-01-01-none "$w"
  o=$(cd "$w" && python3 "$OPENPR" --title "feat(x): n" --summary-file "$TMP/sum.md" --evidence-file "$TMP/ev.txt" --dry-run --repo o/r 2>/dev/null)
  hasnt "$o" "Plan row:" "[P] an intent without plan: gets no line"
}

fam_status; fam_nogh; fam_links; fam_recon; fam_pr

# ── [B] planted breaks: each on a copy of the plugin, each must turn its case red ───────────────────────────────────────────────────
expect_red() {  # expect_red <label> <family> <plugin copy> <the case that must go red>
  local label=$1 fam=$2 d=$3 needle=$4 out crc
  out=$(PASS=0; FAIL=0; KBPY="$d/scripts/kb.py"; OPENPR="$d/scripts/open_pr.py"; capped "$fam" 2>&1); crc=$?   # capped: memory and time caps (fixtures/capped.sh)
  cap_red "$crc" "[B] $label" && return 0
  case "$out" in *"FAIL $needle"*) ok "[B] $label: '$needle' goes red";; *) bad "[B] $label: '$needle' stayed green";; esac
}
BRK() {  # BRK <label> <family> <case> <file under the plugin> <old text> <new text>
  local d="$TMP/brk-$1"; cp -R "$PLUGIN" "$d"
  python3 - "$d/$4" "$5" "$6" <<'EOF' || { bad "[B] $1: the text to break was not found"; return; }
import sys
p, old, new = sys.argv[1:]
s = open(p).read()
if s.count(old) != 1:
    sys.exit(1)
open(p, "w").write(s.replace(old, new))
EOF
  expect_red "$1" "$2" "$d" "$3"
}
BRK mention-links fam_status "[S] H: a PR that only mentions the row (title, body) is not linked" scripts/kb_plan.py \
  '        merged = sorted(' '        cands.update({p["number"]: p for p in prs if "#" + r["id"] in (p.get("title") or "")})
        merged = sorted('
BRK title-hint-dropped fam_status "[S] U: …with a note naming the PR" scripts/kb_plan.py \
  '                if p["state"] in ("OPEN", "MERGED") and title_rx.search(p.get("title") or ""):' '                if False:'
BRK title-hint-closed fam_status "[S] W: a closed PR's title gives no note" scripts/kb_plan.py \
  '                if p["state"] in ("OPEN", "MERGED") and title_rx.search' '                if title_rx.search'
BRK title-hint-prefix fam_status "[S] X1: (row X10) is not row X1" scripts/kb_plan.py \
  'r"\(row %s\)" % re.escape(r["id"])' 'r"\(row %s" % re.escape(r["id"])'
BRK title-hint-state fam_status "[S] U: a row an open PR's title names" scripts/kb_plan.py \
  '            row["state"] = "planned"
            if linked:' '            row["state"] = "planned"
            if linked or re.search(r"\(row %s\)" % re.escape(r["id"]), " ".join(p.get("title") or "" for p in prs), re.I):
                row["state"] = "PR open"
            if linked:'
BRK closed-as-merged fam_status "[S] I: a closed unmerged PR sets no state" scripts/kb_plan.py \
  'p for p in cands.values() if p["state"] == "MERGED"' 'p for p in cands.values() if p["state"] in ("MERGED", "CLOSED")'
BRK prefix-ids fam_status "[S] N1: an intent naming row N10 does not link N1 (ids match whole)" scripts/kb_plan.py \
  '        if ref and ref[0] == rel:
            back.setdefault(ref[1], []).append(p)' '        if ref and ref[0] == rel:
            back.setdefault(ref[1][:2], []).append(p)'
BRK no-version-check fam_status "[S] B: version drift, the manifest read through gh api (commit not fetched)" scripts/kb_plan.py \
  '                elif have != want_v:' '                elif False:'
BRK no-changelog-version fam_status "[S] K: a manifest with no version" scripts/kb_plan.py \
  '    return released if found else None' '    return None'
BRK no-dep-drift fam_status "[S] E: dependency drift" scripts/kb_plan.py '                    elif st[d] != "merged":' '                    elif False:'
BRK gh-down-merged fam_nogh "[N] no gh: nothing is called merged" scripts/kb_plan.py \
  '            row["state"] = "dropped" if link["dropped"] else "not checked"' \
  '            row.update(pr=(link["prs"] or [0])[0], merge="0" * 40); row["state"] = "dropped" if link["dropped"] else "merged"'
BRK skip-intent-naming fam_links "[L] an intent does not name its spec: rc 65" scripts/kb_plan.py \
  '                if not names(ip, s):' '                if False:'
BRK spec-only-plan fam_links "[L] plan: in the spec only: rc 65" scripts/kb_plan.py '                elif b and not a:' '                elif False:'
BRK branch-prefix fam_status "[S] Q: a branch link is read whole, not as the prefix intent/2026-01-03-p (#22)" scripts/kb_plan.py \
  'BRANCH_RX = re.compile(r"(?<![\w/.-])(intent/[A-Za-z0-9._/-]+)")' 'BRANCH_RX = re.compile(r"(?<![\w/.-])(intent/[A-Za-z0-9._-]+)(?![\w/]|\.md)")'
BRK any-pull-url fam_status "[S] R: a PR URL of another repository does not link this repository's #11" scripts/kb_plan.py \
  '            if slug and o == slug:' '            if True:'
BRK partial-hidden fam_nogh "[N] gh failing after the PR list: the header says partly checked" scripts/kb_plan.py \
  '"checked (%d PRs read)" % len(prs) if not gh.errors' '"checked (%d PRs read)" % len(prs) if True'
BRK deleted-row-old fam_links "[L] a deleted row an unchanged intent still names: rc 65" scripts/kb_plan.py \
  '        hard = changed is None or src in changed or any(t in changed for t in targets)' '        hard = changed is None or src in changed'
BRK recon-sha-unchecked fam_recon "[R] a Current state cell with no SHA: rc 65" scripts/kb_plan.py \
  '            if ("current" in r["cols"] and r["current"] is None and _plain(r["current_cell"]).lower() not in NONE_CELL' \
  '            if (False'
BRK recon-shared-unordered fam_recon "[R] two rows share a file with no order: rc 65" scripts/kb_plan.py \
  '                    if not (reach(a["id"], b["id"]) or reach(b["id"], a["id"])):' '                    if False:'
BRK no-plan-line fam_pr "[P] an intent with plan: gets one Plan row line, linked" scripts/open_pr.py \
  '    if plan:                                 # the plan row' '    if False:                                # the plan row'

echo "== nothing written outside the scratch tree =="
eq "$(tree_hash "$SRC_ROOT")" "$H0" "the repository tree is unchanged by the suite"
echo; summary
