#!/usr/bin/env bash
# =============================================================================
# kb.py focus: one place to follow a focus (scripts/kb.py, scripts/kb_plan.py)
# =============================================================================
# Offline: GitHub is the fake gh of tests/fixtures/kb_focus_gh.py on a JSON world of several repositories. Families:
#   [states]       each state of a story (an issue labelled focus:<P>): gate 1 (no intent), gate 2 (an intent: in the working tree,
#                  on an origin/intent/* ref, at another repository's default branch), in progress (a PR open; a PR merged while
#                  the issue is open, with a note), waiting for the owner (the label waiting:owner on the issue or its open PR),
#                  done (the issue closed, even with a PR open); a repository named twice (`.git` or not), or this one named by --repo, is
#                  read once; the counts line, and the counts file under the place key of this directory; nothing fetched or changed
#   [ac-coverage]  AC <delivered>/<total>: a story's plan rows that merged (a dropped row whose PR merged, a row whose PR is open:
#                  not counted); a one-PR story: every AC when its PR merged, none while it is open; a v2 story (its spec names no
#                  AC, they are the story's), its lean plan's Delivers cells
#   [offline]      no gh, gh failing, a --repo gh cannot see, a PR list at its cap: GitHub `not checked (<reason>)` or `partly
#                  checked`, the kb side listed, rc 0, the counts file not written; a state directory that cannot be written: the
#                  stories still printed, the counts not written, why named
#   [done-when]    the focus's `done when` and `not doing`, as the brain beside the installed sdlc copy answers; absent fields,
#                  no brain and a failing brain print neither, rc 0
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

FB="$TMP/fakebin"; mkdir -p "$FB"
printf '#!/bin/sh\nexec python3 "%s" "$@"\n' "$HERE/fixtures/kb_focus_gh.py" > "$FB/gh"; chmod +x "$FB/gh"
export PATH="$FB:$PATH" FAKE_LOG="$TMP/gh.log" FAKE_GH_WORLD="$TMP/world.json"
: > "$FAKE_LOG"
# a PATH with python3 and git only: no gh at all
NOGH="$TMP/nogh"; mkdir -p "$NOGH"; ln -s "$(command -v python3)" "$NOGH/python3"; ln -s "$(command -v git)" "$NOGH/git"

fm() {  # fm <file> <frontmatter lines…> — an intent with that frontmatter and a short body
  local f=$1; shift; mkdir -p "$(dirname "$f")"
  { echo '---'; printf '%s\n' "$@"; echo 'description: "fixture"'; echo '---'; echo; echo '# fixture'; } > "$f"
}
spec() {  # spec <file> <number of AC> — a spec whose Goal lists AC1 to AC<n>
  mkdir -p "$(dirname "$1")"
  { printf -- '---\ndescription: "fixture"\n---\n\n# fixture\n\n## Mục tiêu\n\n'
    for i in $(seq 1 "$2"); do printf '%d. **AC%d: thing %d.** ("lời %d")\n' "$i" "$i" "$i" "$i"; done
    printf '\n## Tiêu chí chấp nhận\n\n1. `true` → AC1\n'; } > "$1"
}
repo() {  # repo <dir> <owner/name> — a repository whose origin names owner/name on GitHub (never fetched)
  git_ init -q -b main "$1"; git_ -C "$1" remote add origin "https://github.com/$2.git"
}
commit() { git_ -C "$1" add -A && git_ -C "$1" commit -qm "$2"; }
# states <json> — one `key state` line per story of `kb.py focus --json`
states() { printf '%s' "$1" | python3 -c 'import json, sys
for r in json.load(sys.stdin)["repos"]:
    for s in r["stories"]:
        print(s["key"], s["state"], "AC %d/%d" % (s["ac"]["delivered"], s["ac"]["total"]) if s["ac"] else "AC -")'; }
# focus <dir> <args…> — kb.py focus in <dir>; stdout+stderr to $OUT, rc to $RC
focus() { local d=$1; shift; OUT=$(cd "$d" && python3 "$KBPY" focus "$@" 2>&1); RC=$?; }
hasline() { printf '%s\n' "$1" | grep -qFx -- "$2" && ok "$3" || bad "$3 (no line '$2')"; }
L() { printf '[{"name": "%s"}' "focus:$1"; shift; for x in "$@"; do printf ', {"name": "%s"}' "$x"; done; printf ']'; }

# ── [states] ─────────────────────────────────────────────────────────────────────────────────────────────────────────────
echo "-- [states]"
A="$TMP/app"; repo "$A" acme/app
fm "$A/kb/intent/2026-11-01-two.md" "issue: 2" "type: story" "focus: P1"
fm "$A/kb/intent/2026-11-01-four.md" "issue: 4" "type: task" "focus: P1"
fm "$A/kb/intent/2026-11-01-five.md" "issue: 5" "type: task" "focus: P1"
fm "$A/kb/intent/2026-11-01-six.md" "issue: 6" "type: task" "focus: P1"
fm "$A/kb/intent/2026-11-01-seven.md" "issue: 7" "type: task" "focus: P1"
commit "$A" m1
git_ -C "$A" checkout -q -b intent/2026-11-01-nine
fm "$A/kb/intent/2026-11-01-nine.md" "issue: 9" "type: bug" "focus: P1"
commit "$A" nine
git_ -C "$A" update-ref refs/remotes/origin/intent/2026-11-01-nine HEAD     # as the last fetch left it
git_ -C "$A" checkout -q main; git_ -C "$A" branch -q -D intent/2026-11-01-nine
OPS_INTENT=$(printf -- '---\nissue: 1\ntype: story\nfocus: P1\ndescription: "ops"\n---\n\n# ops\n')
THREE=$(printf -- '---\nissue: 3\ntype: task\nfocus: P1\ndescription: "three"\n---\n\n# three\n')
python3 - "$FAKE_GH_WORLD" "$OPS_INTENT" "$THREE" <<PY
import json, sys
I = lambda n, st, labels, title="story %d": {"number": n, "state": st, "title": title % n if "%d" in title else title, "labels": labels}
P = lambda n, st, br, labels=[]: {"number": n, "state": st, "headRefName": br, "headRefOid": "%040x" % n, "isDraft": False,
                                  "mergeCommit": {"oid": "%040x" % (n + 1000)} if st == "MERGED" else None, "title": "pr %d" % n,
                                  "url": "https://github.com/acme/app/pull/%d" % n, "labels": labels}
app = {"issues": [I(1, "OPEN", $(L P1 type:story)), I(2, "OPEN", $(L P1 type:story)), I(3, "OPEN", $(L P1)),
                  I(4, "OPEN", $(L P1 type:task)), I(5, "CLOSED", $(L P1)), I(6, "OPEN", $(L P1)), I(7, "CLOSED", $(L P1)),
                  I(8, "OPEN", $(L P1 waiting:owner)), I(9, "OPEN", $(L P1)), I(20, "OPEN", $(L P2))],
       "prs": [P(33, "OPEN", "intent/2026-11-01-three"), P(44, "OPEN", "intent/2026-11-01-four", [{"name": "waiting:owner"}]),
               P(55, "MERGED", "intent/2026-11-01-five"), P(66, "MERGED", "intent/2026-11-01-six"),
               P(77, "OPEN", "intent/2026-11-01-seven")],
       "files": {"%040x:kb/intent/2026-11-01-three.md" % 33: sys.argv[3]}}
ops = {"issues": [I(1, "OPEN", $(L P1)), I(2, "CLOSED", $(L P1))], "prs": [],
       "files": {"HEAD:kb/intent/2026-11-02-ops.md": sys.argv[2]}}
json.dump({"acme/app": app, "acme/ops": ops}, open(sys.argv[1], "w"))
PY
export FAKE_GH_HERE=acme/app
REFS0=$(git_ -C "$A" for-each-ref | sha1sum)
focus "$A" P1 --repo acme/ops --json --repo acme/ops --repo ACME/app
eq "$RC" 0 "[states] rc 0"
eq "$(states "$OUT")" "#1 gate 1 AC -
#2 gate 2 AC -
#3 in progress AC -
#4 waiting for the owner AC -
#5 done AC -
#6 in progress AC -
#7 done AC -
#8 waiting for the owner AC -
#9 gate 2 AC -
acme/ops#1 gate 2 AC -
acme/ops#2 done AC -" "[states] each story once, with its state (an intent in the tree, on origin/intent/*, at a PR head, at ops' default branch)"
focus "$A" P1 --repo acme/ops
eq "$RC" 0 "[states] text: rc 0"
hasline "$OUT" "P1: gate 1 1 · gate 2 3 · in progress 2 · waiting for the owner 2 · done 3" "[states] the counts line"
has "$OUT" "note: PR #66 merged, the issue is open" "[states] a merged PR with its issue open is not done, and says why"
has "$OUT" "note: PR #77 is still open" "[states] a closed issue is done though its PR is open, and says so"
hasline "$OUT" "acme/app: GitHub checked (9 issue(s))" "[states] this repository is named, read in full"
hasline "$OUT" "acme/ops: GitHub checked (2 issue(s))" "[states] the --repo repository, read in full"
hasnt "$OUT" "#20" "[states] an issue of another focus is not listed"
KEY="project-$(printf '%s' "$(cd "$A/.git" && pwd -P)" | sha256sum | cut -c1-16)"
CF="$XDG_STATE_HOME/vibemaestro/focus/$KEY/P1.json"
hasline "$OUT" "counts written: focus/$KEY/P1.json" "[states] the counts file is named by the place key of this directory"
eq "$(cd "$A" && python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import baton; print(baton.project_root()[1])' "$PLUGIN/scripts")" \
   "$KEY" "[states] …the key baton gives this directory"
eq "$(python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); print(d["focus"], "|", d["line"])' "$CF" 2>&1)" \
   "P1 | P1: gate 1 1 · gate 2 3 · in progress 2 · waiting for the owner 2 · done 3" "[states] the counts file holds the same line"
has "$(python3 -c 'import json, sys, re; print(bool(re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", json.load(open(sys.argv[1]))["time"])))' "$CF" 2>&1)" \
    "True" "[states] the counts file holds the time"
eq "$(grep -c 'issue list -R acme/ops --label focus:P1' "$FAKE_LOG")" 2 "[states] acme/ops read once per run, though named twice"
eq "$(grep -c 'issue list -R acme/app' "$FAKE_LOG")" 0 "[states] this repository named by --repo is not read a second time"
eq "$(grep -vcE '^gh (issue list|pr list|issue view|api repos/[^ ]+/contents/[^ ]+ -H|api graphql) ' "$FAKE_LOG")" 0 "[states] gh is only read"
: > "$FAKE_LOG"; focus "$A" P1 --repo acme/ops.git --repo acme/ops --repo acme/app.git
eq "$(grep -c '^gh issue list' "$FAKE_LOG")" 2 "[states] a name ending .git is the same repository: acme/app and acme/ops read once each"
eq "$(git_ -C "$A" for-each-ref | sha1sum)" "$REFS0" "[states] no ref changed: nothing fetched"
eq "$(git_ -C "$A" status --porcelain)" "" "[states] the working tree is unchanged"

# ── [ac-coverage] ────────────────────────────────────────────────────────────────────────────────────────────────────────
echo "-- [ac-coverage]"
V="$TMP/cov"; repo "$V" acme/cov
fm "$V/kb/intent/2026-11-03-big.md" "issue: 10" "type: story" "focus: P3" "spec: kb/specs/2026-11-03-big.md"
fm "$V/kb/intent/2026-11-03-one.md" "issue: 11" "type: story" "focus: P3" "spec: kb/specs/2026-11-03-one.md"
fm "$V/kb/intent/2026-11-03-wip.md" "issue: 12" "type: story" "focus: P3" "spec: kb/specs/2026-11-03-wip.md"
spec "$V/kb/specs/2026-11-03-big.md" 4; spec "$V/kb/specs/2026-11-03-one.md" 3; spec "$V/kb/specs/2026-11-03-wip.md" 2
mkdir -p "$V/kb/plans"; cat > "$V/kb/plans/2026-11-03-big.md" <<'EOF'
---
description: "fixture plan"
focus: P3
---

# Plan — big

Intent: kb/intent/2026-11-03-big.md · Spec: kb/specs/2026-11-03-big.md

| Row | Must be true | Acceptance | Depends on | Version | Model | Link |
|---|---|---|---|---|---|---|
| R1 | Delivers AC1, AC2: one and two | `true` | — | — | — | #101 |
| R2 | Delivers AC3: three | `true` | — | — | — | dropped: not needed · #102 |
| R3 | Delivers AC4: four | `true` | — | — | — | #103 |
EOF
commit "$V" m1
python3 - "$TMP/world-cov.json" <<'PY'
import json, sys
I = lambda n, st: {"number": n, "state": st, "title": "story %d" % n, "labels": [{"name": "focus:P3"}, {"name": "type:story"}]}
P = lambda n, st, br: {"number": n, "state": st, "headRefName": br, "headRefOid": "%040x" % n, "isDraft": False,
                       "mergeCommit": {"oid": "%040x" % (n + 1000)} if st == "MERGED" else None, "title": "pr %d" % n,
                       "url": "https://github.com/acme/cov/pull/%d" % n, "labels": []}
json.dump({"acme/cov": {"issues": [I(10, "OPEN"), I(11, "CLOSED"), I(12, "OPEN")],
                        "prs": [P(101, "MERGED", "intent/2026-11-03-big-r1"), P(102, "MERGED", "intent/2026-11-03-big-r2"),
                                P(103, "OPEN", "intent/2026-11-03-big-r3"), P(111, "MERGED", "intent/2026-11-03-one"),
                                P(112, "OPEN", "intent/2026-11-03-wip")]}}, open(sys.argv[1], "w"))
PY
FAKE_GH_WORLD="$TMP/world-cov.json" FAKE_GH_HERE=acme/cov focus "$V" P3 --json
eq "$RC" 0 "[ac-coverage] rc 0"
eq "$(states "$OUT")" "#10 in progress AC 2/4
#11 done AC 3/3
#12 in progress AC 0/2" "[ac-coverage] merged rows only (a dropped row's merged PR and an open row's PR do not count); a one-PR story by its PR"
FAKE_GH_WORLD="$TMP/world-cov.json" FAKE_GH_HERE=acme/cov focus "$V" P3
has "$OUT" "AC 2/4" "[ac-coverage] the text line shows AC <delivered>/<total>"
# a story the owner approves (v2): its AC are the numbers under the story's AC label, its spec names none; a lean plan's Delivers cell
W="$TMP/cov2"; repo "$W" acme/cov2; mkdir -p "$W/kb/intent" "$W/kb/specs" "$W/kb/plans"
printf -- '---\nissue: 20\ntype: story\nfocus: P3\nspec: kb/specs/2026-11-12-v.md\ndescription: "fixture"\n---\n\n# v\n\n**As** the owner, **I want** x, **so that** y.\n\n**Context.** c\n\n**Acceptance criteria**\n1. one\n2. two\n3. three\n\n**Out of scope**\n- none\n\n**Appetite.** a day\n' > "$W/kb/intent/2026-11-12-v.md"
printf -- '---\ndescription: "fixture"\n---\n\n# v\n\nIntent: kb/intent/2026-11-12-v.md\n\n## Mục tiêu\n\n1. g → AC1, AC2, AC3\n\n## Ràng buộc\n\nc\n\n## Tiêu chí chấp nhận\n\n1. Khi x, thì y. → AC1, AC2, AC3\n\n## Rủi ro cần test phủ\n\n1. r\n\n## Cần làm rõ\n\nKhông có.\n' > "$W/kb/specs/2026-11-12-v.md"
printf -- '---\ndescription: "fixture plan"\nfocus: P3\n---\n\n# Plan\n\nIntent: kb/intent/2026-11-12-v.md · Spec: kb/specs/2026-11-12-v.md\n\n| Row | How | Delivers | Depends on | Trust touches | Link |\n|---|---|---|---|---|---|\n| R1 | x | AC1, AC2 (criteria 1–2) | — | none | intent/2026-11-12-v-r1 |\n| R2 | y | AC3 | R1 | none | intent/2026-11-12-v-r2 |\n' > "$W/kb/plans/2026-11-12-v.md"
commit "$W" m1
python3 - "$TMP/world-cov2.json" <<'PY'
import json, sys
P = lambda n, st, br: {"number": n, "state": st, "headRefName": br, "headRefOid": "%040x" % n, "isDraft": False,
                       "mergeCommit": {"oid": "%040x" % (n + 1000)} if st == "MERGED" else None, "title": "pr %d" % n,
                       "url": "https://github.com/acme/cov2/pull/%d" % n, "labels": []}
json.dump({"acme/cov2": {"issues": [{"number": 20, "state": "OPEN", "title": "story 20", "labels": [{"name": "focus:P3"}, {"name": "type:story"}]}],
                         "prs": [P(201, "MERGED", "intent/2026-11-12-v-r1"), P(202, "OPEN", "intent/2026-11-12-v-r2")]}}, open(sys.argv[1], "w"))
PY
FAKE_GH_WORLD="$TMP/world-cov2.json" FAKE_GH_HERE=acme/cov2 focus "$W" P3 --json
eq "$(states "$OUT")" "#20 in progress AC 2/3" "[ac-coverage] a v2 story: AC read from the story, a lean row's Delivers cell counted when its PR merged"

# ── [offline] ────────────────────────────────────────────────────────────────────────────────────────────────────────────
echo "-- [offline]"
C0=$(sha1sum < "$CF")
OUT=$(cd "$A" && PATH="$NOGH" python3 "$KBPY" focus P1 --repo acme/ops 2>&1); RC=$?
eq "$RC" 0 "[offline] no gh: rc 0"
hasline "$OUT" "acme/app: GitHub not checked (no gh on PATH)" "[offline] no gh: this repository is not checked, with the reason"
hasline "$OUT" "acme/ops: GitHub not checked (no gh on PATH)" "[offline] no gh: the --repo repository is not checked, with the reason"
for f in two four five six seven nine; do
  hasline "$OUT" "  kb/intent/2026-11-01-$f.md  (kb side: focus P1, state not checked)" "[offline] no gh: the kb side lists $f"
done
hasline "$OUT" "P1: not counted (GitHub not checked for acme/app, acme/ops)" "[offline] no gh: no counts, the repositories named"
hasline "$OUT" "counts not written: not every repository was read" "[offline] no gh: the counts file is not written"
eq "$(sha1sum < "$CF")" "$C0" "[offline] no gh: the last counts stay as they were"
FAKE_GH_FAIL=1 focus "$A" P1
eq "$RC" 0 "[offline] gh failing: rc 0"
hasline "$OUT" "acme/app: GitHub not checked (gh issue list: error connecting to api.github.com)" "[offline] gh failing: the reason"
focus "$A" P1 --repo acme/hidden
eq "$RC" 0 "[offline] a --repo gh cannot see: rc 0"
has "$OUT" "acme/hidden: GitHub not checked (gh issue list: GraphQL: Could not resolve to a Repository with the name 'acme/hidden'. (repository))" \
    "[offline] a --repo gh cannot see: not checked, with gh's reason"
hasline "$OUT" "P1: not counted (GitHub not checked for acme/hidden)" "[offline] one repository unread: no counts"
eq "$(sha1sum < "$CF")" "$C0" "[offline] one repository unread: the counts file is not written"
: > "$TMP/not-a-dir"
OUT=$(cd "$A" && XDG_STATE_HOME="$TMP/not-a-dir" python3 "$KBPY" focus P1 2>&1); RC=$?
eq "$RC" 0 "[offline] a state directory that cannot be written: rc 0"
hasline "$OUT" "P1: gate 1 1 · gate 2 2 · in progress 2 · waiting for the owner 2 · done 2" "[offline] …the stories are still counted"
hasline "$OUT" "counts not written: the state directory cannot be written: Not a directory" "[offline] …and the counts not written, why named"
python3 - "$TMP/world-cap.json" <<'PY2'
import json, sys
P = lambda n: {"number": n, "state": "MERGED", "headRefName": "b%d" % n, "headRefOid": "%040x" % n, "isDraft": False,
               "mergeCommit": {"oid": "%040x" % (n + 5000)}, "title": "pr", "url": "https://github.com/acme/big/pull/%d" % n, "labels": []}
json.dump({"acme/big": {"issues": [{"number": 1, "state": "OPEN", "title": "s", "labels": [{"name": "focus:P1"}]}],
                        "prs": [P(n) for n in range(1, 1001)]}}, open(sys.argv[1], "w"))
PY2
FAKE_GH_WORLD="$TMP/world-cap.json" FAKE_GH_HERE=acme/big focus "$A" P1
eq "$RC" 0 "[offline] a PR list at the 1000 cap: rc 0"
hasline "$OUT" "acme/app: GitHub partly checked (1 call(s) failed: the PR list is capped at 1000: older ones were not read)" \
        "[offline] …partly checked, the cap named"
hasline "$OUT" "P1: not counted (GitHub not checked for acme/app)" "[offline] …no counts from a capped list"
focus "$A" P1 --repo not-a-repo
eq "$RC" 64 "[offline] a --repo that is not owner/name: usage, rc 64"
focus "$A" 8
eq "$RC" 64 "[offline] a focus that is not P<n>: usage, rc 64"

# ── [done-when] ──────────────────────────────────────────────────────────────────────────────────────────────────────────
echo "-- [done-when]"
CL="$TMP/claude"; S="$CL/plugins/cache/vibemaestro/vibemaestro-sdlc/1.0.0"; B="$CL/plugins/cache/vibemaestro/vibemaestro-brain/1.0.0"
mkdir -p "$(dirname "$S")" "$B/scripts"; cp -r "$PLUGIN" "$S"
cat > "$B/scripts/brain.py" <<'PY'
import json, sys
items = {"P1": {"kind": "focus", "status": "live", "done": "all five stories merged, \"one\" line", "not_doing": "the ledger rewrite"},
         "P2": {"kind": "focus", "status": "live", "done": "the digest relays it"}}
if sys.argv[1:2] != ["show"] or sys.argv[3:] != ["--json"]:
    sys.exit(64)
it = items.get(sys.argv[2])
if it is None:
    sys.stderr.write("brain: %s is not an item of this brain\n" % sys.argv[2])
    sys.exit(1)
print(json.dumps(dict(it, id=sys.argv[2])))
PY
python3 - "$CL/plugins/installed_plugins.json" "$S" "$B" <<'PY'
import json, sys
e = lambda p: [{"scope": "user", "installPath": p, "version": "1.0.0", "lastUpdated": "2026-11-08T00:00:00.000Z"}]
json.dump({"version": 2, "plugins": {"vibemaestro-sdlc@vibemaestro": e(sys.argv[2]), "vibemaestro-brain@vibemaestro": e(sys.argv[3])}},
          open(sys.argv[1], "w"))
PY
printf '{"acme/empty": {}}\n' > "$TMP/world-empty.json"; export FAKE_GH_WORLD="$TMP/world-empty.json" FAKE_GH_HERE=acme/empty
D="$TMP/dw"; repo "$D" acme/empty; fm "$D/kb/intent/2026-11-04-x.md" "type: task" "focus: P1"; commit "$D" m1
kbc() { OUT=$(cd "$D" && python3 "$S/scripts/kb.py" focus "$@" 2>&1); RC=$?; }
kbc P1
eq "$RC" 0 "[done-when] the brain answers: rc 0"
hasline "$OUT" 'P1: done when: all five stories merged, "one" line' "[done-when] done when, the owner's words whole"
hasline "$OUT" "P1: not doing: the ledger rewrite" "[done-when] not doing"
kbc P2
hasline "$OUT" "P2: done when: the digest relays it" "[done-when] a focus with done when alone: printed"
hasnt "$OUT" "not doing" "[done-when] …and no not doing line"
kbc P4
eq "$RC" 0 "[done-when] the brain does not know the focus: rc 0"
hasnt "$OUT" "done when" "[done-when] …and neither line"
focus "$D" P1
eq "$RC" 0 "[done-when] no brain beside the copy: rc 0"
hasnt "$OUT" "done when" "[done-when] no brain: no done when line"
hasline "$OUT" "P1: gate 1 0 · gate 2 0 · in progress 0 · waiting for the owner 0 · done 0" "[done-when] no brain: the rest is printed"

eq "$(tree_hash "$SRC_ROOT")" "$H0" "the repository tree is unchanged by the suite"
summary
