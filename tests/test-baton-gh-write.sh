#!/bin/bash
# =============================================================================
# The kit baton kit:gh-write: gates/gh_write.py and batons/gh-write.sh, through baton.py
# =============================================================================
# Run: bash tests/test-baton-gh-write.sh
#
# Offline, no real GitHub write: a fake `gh` (tests/fixtures/gh_write_gh.py) serves an in-memory REST API from a JSON world in
# the case directory, logs every call with its payload, and injects faults (a list that lags behind a create, a failed write,
# a stored body that differs, the world moving between two reads or after a write).
#   [S] spec refusals: each forbidden kind, unknown op or key, body rules, refs, one op per target; rc 64, named, no write;
#       the call allowlist refuses DELETE, PUT, a repository's settings and a repository creation
#   [P] preconditions: each rc 1, named, the only failed condition, no write (a repository that is not private among them)
#   [K] closed_ok: an issue-comment passes a closed issue or a closed PR only when the op says so, the plan line says so; no other op
#   [R] rehearse: a two-op spec prints two PLAN lines that match Each; rehearse and sign make no write call; an extra plan line
#   [M] run: exactly the planned calls, in order, with the planned bodies; every kind in one spec; the coordinator's four calls
#   [L] trap 1, a list that lags behind a create   [N] trap 2, the trailing newline   [F] trap 3, nested fences
#   [T] trap 4, write() byte-identical, Each anchored, no grep in a pipeline   [Q] trap 5, a created issue cited by a later op
#   [C] issue-close with a closing comment: one op, the comment posted before the close, the plan line binds its text; the undo
#       retracts the comment (never a deletion) and reopens, both checked before either is written
#   [W] pr-close: a full head SHA only, a PR at its pinned head and open, one PATCH; undo reopens it, not over a merge
#   [Y] pr-create, pr-ready, file-pr: pinned heads, base tip and content; refusals (branch shapes, a workflow path, a tag ref);
#       each runs with exactly its calls; undo closes or drafts again, leaves a moved head alone, never deletes the branch
#   [U] undo: an edit put back after a refused create; a create closed (its marker removed) and a comment retracted; a changed
#       state left alone (rc 5); a write whose outcome is unknown and not listed is left for the owner (rc 5)
#   [J] the run: found by the spec file's path, so an edit of the spec during the run is undone; the same bytes elsewhere do not
#       touch it; the signed plan's count and prefix; --recover undoes a run left open
#   [B] the seal: a body file edited after signing, the spec re-pinned, the world moved before a step, a repository made public
#   [I] injection: a title, a label and a body holding shell text arrive verbatim, and nothing runs
#   [X] planted breaks: each check goes red on a copy with one break
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
GHB="$TMP/ghbin"; mkdir -p "$GHB"
printf '#!/bin/sh\nexec python3 -B "%s" "$@"\n' "$HERE/fixtures/gh_write_gh.py" > "$GHB/gh"; chmod +x "$GHB/gh"
PATH="$GHB:$PATH"; export PATH
G=gates/gh_write.py

# mkw [python statements on W] — a fresh case directory (printed) with the world: viewer bot; acme/app private with label kit,
# issues numbered 59 (open, body "old body"), 60 (closed, completed), 61 (open, title "Sixty-one", body "sixty-one"), 62 (open), the
# PR numbered 7 (open, body "pr body"), comments 900 (bot, on 59) and 901 (someone, on 59); acme/pub public; acme/int internal
mkw() {
  local d; d=$(fresh)
  python3 - "$d/world.json" "${1:-}" <<'PY'
import json, sys
W = {"viewer": "bot", "next_issue": 100, "next_comment": 5000, "faults": {},
     "repos": {"acme/app": {"private": True, "visibility": "private", "labels": ["kit", "a`b;c"],
                            "issues": {"59": {"title": "BatonRun", "body": "old body", "state": "open", "user": "bot"},
                                       "60": {"title": "Done", "body": "done", "state": "closed", "state_reason": "completed", "user": "bot"},
                                       "61": {"title": "Sixty-one", "body": "sixty-one", "state": "open", "user": "bot"},
                                       "62": {"title": "Sixty-two", "body": "sixty-two", "state": "open", "user": "bot"},
                                       "7": {"title": "A PR", "body": "pr body", "state": "open", "user": "bot", "pr": True}},
                            "comments": {"900": {"issue": 59, "body": "my comment", "user": "bot"},
                                         "901": {"issue": 59, "body": "theirs", "user": "someone"}}},
               "acme/pub": {"private": False, "visibility": "public", "labels": [], "issues": {"1": {"title": "x", "body": "x", "state": "open", "user": "bot"}}, "comments": {}},
               "acme/int": {"private": True, "visibility": "internal", "labels": [], "issues": {"1": {"title": "x", "body": "x", "state": "open", "user": "bot"}}, "comments": {}}}}
exec(sys.argv[2])
json.dump(W, open(sys.argv[1], "w"))
PY
  : > "$d/gh.log"; printf '%s' "$d"
}
# spec <dir> <ops JSON list> — spec.json in the case directory
spec() { printf '{"gh-write": 1, "ops": %s}\n' "$2" > "$1/spec.json"; }
# wq <dir> <python expression on W> — a value of the world now
wq() { python3 - "$1/world.json" "$2" <<'PY'
import json, sys
W = json.load(open(sys.argv[1]))
R = W["repos"]["acme/app"]
print(eval(sys.argv[2]))
PY
}
# eng <plugin> <dir> [args...] — the engine from the case directory; OUT, RC
eng() {
  local pl=$1 d=$2; shift 2
  OUT=$(cd "$d" && cenv XDG_STATE_HOME="$d/state" FAKE_GH_STATE="$d/world.json" FAKE_GH_LOG="$d/gh.log" \
        python3 -B "$pl/$G" "$@" 2>&1); RC=$?
}
# bt <plugin> <dir> <baton args...> — baton.py from the case directory; OUT, RC
bt() {
  local pl=$1 d=$2; shift 2
  if [ $# -eq 2 ] && [ "$1" = mode ]; then baton_set_mode "$d/state" "$2"; OUT=""; RC=0; return; fi
  OUT=$(cd "$d" && cenv XDG_STATE_HOME="$d/state" FAKE_GH_STATE="$d/world.json" FAKE_GH_LOG="$d/gh.log" \
        python3 -B "$pl/scripts/baton.py" "$@" 2>&1); RC=$?
}
seal_of() { printf '%s\n' "$OUT" | sed -n 's/^seal \([^ ]*\) .*/\1/p'; }
# full <plugin> <dir> — mode auto, rehearse, sign --by coordinator-auto, run kit:gh-write --spec spec.json; OUT and RC of run
full() {
  local pl=$1 d=$2 seal
  bt "$pl" "$d" mode auto; bt "$pl" "$d" rehearse kit:gh-write --spec spec.json; seal=$(seal_of)
  bt "$pl" "$d" sign --by coordinator-auto --seal "${seal:-none}" kit:gh-write --spec spec.json
  bt "$pl" "$d" run kit:gh-write --spec spec.json
}
# writes <dir> — the write calls the fake saw, one "METHOD path" per line; nwrites, ndeletes count them
writes() { python3 - "$1/gh.log" <<'PY'
import json, sys
for ln in open(sys.argv[1]):
    c = json.loads(ln)
    if c["method"] != "GET" and not (c["path"] == "graphql" and "mutation" not in json.dumps(c["payload"])):  # viewer reads
        print("%s %s" % (c["method"], c["path"]))
PY
}
nwrites() { writes "$1" | grep -c . ; }
ndeletes() { grep -c -E '"method": "(DELETE|PUT)"' "$1/gh.log"; }
# sha <file> — its sha256 (no sha256sum on macOS)
sha() { python3 - "$1" <<'PY'
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
PY
}
nplan() { printf '%s\n' "$OUT" | grep -c '^  PLAN gh-write '; }   # baton relays a script's line under two spaces
nfail() { printf '%s\n' "$OUT" | grep -c '^  FAIL  '; }
# refuse <label> <name> <ops JSON> — the engine refuses the spec: rc 64, named, no write call
refuse() {
  local d; d=$(mkw); spec "$d" "$3"; eng "$PL" "$d" --spec spec.json
  eq "$RC" 64 "$1: rc 64"
  has "$OUT" "REFUSE $2:" "$1: named $2"
  eq "$(nwrites "$d")" 0 "$1: no write call"
}
# alone <label> <condition> <world statements> <ops JSON> — the plan fails on that condition only: rc 1, named, no write call
alone() {
  local d; d=$(mkw "$3"); spec "$d" "$4"; eng "$PL" "$d" --spec spec.json
  eq "$RC" 1 "$1: rc 1"
  has "$OUT" "FAIL  $2:" "$1: named $2"
  eq "$(nfail)" 1 "$1: $2 is the only failed condition"
  eq "$(nwrites "$d")" 0 "$1: no write call"
}
CMT='{"op": "issue-comment", "repo": "acme/app", "issue": 59, "body": "hello <!-- m-c -->", "marker": "<!-- m-c -->"}'
NEW='{"op": "issue-create", "id": "new", "repo": "acme/app", "title": "A new issue", "labels": ["kit"], "body": "Body\n<!-- m-n -->\n", "marker": "<!-- m-n -->"}'
CITE='{"op": "issue-comment", "repo": "acme/app", "issue": 59, "body": "Opened {{issue:new}} for this.\n<!-- m-l -->", "marker": "<!-- m-l -->"}'
TWO="[$NEW, $CITE]"
HD=$(printf 'ab%.0s' $(seq 20)); HD2=$(printf 'cd%.0s' $(seq 20))
PRC='{"op": "pr-close", "repo": "acme/app", "pr": 7, "head": "'"$HD"'"}'

fam_spec() {
  PL=$1; local k d
  for k in issue-delete comment-delete remove-label delete; do
    refuse "[S] an op of kind $k" refuse-delete '[{"op": "'"$k"'", "repo": "acme/app", "issue": 59}]'
  done
  for k in repo-create repository-create create-repo; do
    refuse "[S] an op of kind $k" refuse-repo-create '[{"op": "'"$k"'", "repo": "acme/app"}]'
  done
  refuse "[S] an unknown kind (issue-lock)" refuse-unknown-op '[{"op": "issue-lock", "repo": "acme/app", "issue": 59}]'
  refuse "[S] a deletion slipped in as a key" refuse-unknown-key \
    '[{"op": "issue-comment", "repo": "acme/app", "issue": 59, "body": "x <!-- m -->", "marker": "<!-- m -->", "method": "DELETE"}]'
  refuse "[S] both body and body_file" refuse-body \
    '[{"op": "pr-body-edit", "repo": "acme/app", "pr": 7, "body": "x", "body_file": "b.md", "sha256": "'"$(printf '%064d' 0)"'"}]'
  refuse "[S] a comment without a body" refuse-body '[{"op": "issue-comment", "repo": "acme/app", "issue": 59, "marker": "<!-- m -->"}]'
  refuse "[S] a body_file pinned by a sha that is not 64 hex" refuse-body '[{"op": "pr-body-edit", "repo": "acme/app", "pr": 7, "body_file": "b.md", "sha256": "abc"}]'
  refuse "[S] a body_file outside the spec's directory" refuse-body '[{"op": "pr-body-edit", "repo": "acme/app", "pr": 7, "body_file": "../b.md", "sha256": "'"$(printf '%064d' 0)"'"}]'
  refuse "[S] a CR in a body" refuse-body '[{"op": "pr-body-edit", "repo": "acme/app", "pr": 7, "body": "a\r\nb"}]'
  refuse "[S] two ops on one issue" refuse-same-target \
    '[{"op": "issue-close", "repo": "acme/app", "issue": 61, "reason": "completed"}, {"op": "issue-edit", "repo": "acme/app", "issue": 61, "title": "t"}]'
  refuse "[S] a forward @ref" refuse-ref "[{\"op\": \"issue-comment\", \"repo\": \"acme/app\", \"issue\": \"@new\", \"body\": \"x <!-- m -->\", \"marker\": \"<!-- m -->\"}, $NEW]"
  refuse "[S] an unknown {{issue:…}}" refuse-ref '[{"op": "pr-body-edit", "repo": "acme/app", "pr": 7, "body": "see {{issue:nope}}"}]'
  refuse "[S] an id with a trailing newline" refuse-spec "[{\"op\": \"issue-create\", \"id\": \"new\\n\", \"repo\": \"acme/app\", \"title\": \"t\", \"body\": \"x <!-- m -->\", \"marker\": \"<!-- m -->\"}]"
  refuse "[S] a repo with a trailing newline" refuse-spec '[{"op": "issue-reopen", "repo": "acme/app\n", "issue": 60}]'
  refuse "[S] one op's marker in another op's body" refuse-spec "[{\"op\": \"issue-create\", \"repo\": \"acme/app\", \"title\": \"t\", \"body\": \"quotes <!-- m-c --> and <!-- m-1 -->\", \"marker\": \"<!-- m-1 -->\"}, $CMT]"
  d=$(mkw); mkdir -p "$d/outside"; printf 'a secret\n' > "$d/outside/s.txt"; mkdir -p "$d/in"; ln -s ../outside/s.txt "$d/in/b.md"
  printf '{"gh-write": 1, "ops": [{"op": "pr-body-edit", "repo": "acme/app", "pr": 7, "body_file": "b.md", "sha256": "%s"}]}\n' "$(sha "$d/outside/s.txt")" > "$d/in/spec.json"
  eng "$PL" "$d" --spec in/spec.json
  eq "$RC" 64 "[S] a body_file that is a link leading outside the spec's directory: rc 64"
  has "$OUT" "REFUSE refuse-body:" "[S] …named refuse-body"
  refuse "[S] a key given twice" refuse-spec '[{"op": "issue-reopen", "repo": "acme/app", "issue": 60, "issue": 61}]'
  refuse "[S] an empty ops list" refuse-spec '[]'
  d=$(mkw); printf '{"gh-write": 1, "ops": [%s], "extra": 1}\n' "$CMT" > "$d/spec.json"; eng "$PL" "$d" --spec spec.json
  eq "$RC" 64 "[S] a spec with an extra top-level key: rc 64"
  local v
  v=$(python3 - "$PL/gates" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import gh_write as g
cases = [("DELETE", "repos/acme/app/issues/comments/900", None), ("PUT", "repos/acme/app/issues/59/lock", {"lock_reason": "x"}),
         ("PATCH", "repos/acme/app", {"visibility": "public"}), ("POST", "user/repos", {"name": "x"}),
         ("POST", "orgs/acme/repos", {"name": "x"}), ("PATCH", "repos/acme/app/issues/59", {"title": "t", "locked": True}),
         ("PATCH", "repos/acme/app/issues/59/../../../app2", {"title": "t"}), ("GET", "repos/acme/app/issues/59", {"x": 1})]
good = [("GET", "repos/acme/app/issues/59", None), ("POST", "repos/acme/app/issues", {"title": "t", "body": "b"}),
        ("PATCH", "repos/acme/app/pulls/7", {"body": "b"})]
print(" ".join("refused" if not g.allowed(*c) else "ALLOWED" for c in cases), "|", " ".join("allowed" if g.allowed(*c) else "REFUSED" for c in good))
PY
)
  eq "$v" "refused refused refused refused refused refused refused refused | allowed allowed allowed" \
     "[S] the call allowlist refuses DELETE, PUT, a repository's settings, a repository creation, an extra field, a climbing path"
}

fam_conditions() {
  PL=$1; local d
  alone "[P] a public repository" private '' '[{"op": "issue-comment", "repo": "acme/pub", "issue": 1, "body": "x <!-- m -->", "marker": "<!-- m -->"}]'
  has "$OUT" "refuse-public" "[P] …the refusal is refuse-public"
  alone "[P] an internal repository (the whole enterprise reads it)" private '' '[{"op": "issue-comment", "repo": "acme/int", "issue": 1, "body": "x <!-- m -->", "marker": "<!-- m -->"}]'
  d=$(mkw 'del W["repos"]["acme/app"]["visibility"]'); spec "$d" "[$CMT]"
  eng "$PL" "$d" --spec spec.json; eq "$RC" 0 "[P] control: private true and no visibility field (older servers) passes"
  alone "[P] an issue-close of a pull request" not-pr '' '[{"op": "issue-close", "repo": "acme/app", "issue": 7, "reason": "completed"}]'
  d=$(mkw); spec "$d" '[{"op": "issue-comment", "repo": "acme/app", "issue": 7, "body": "on the PR <!-- m -->", "marker": "<!-- m -->"}]'
  eng "$PL" "$d" --spec spec.json; eq "$RC" 0 "[P] control: a comment on a pull request passes"
  alone "[P] a repository whose visibility reads public while private reads true" private 'W["repos"]["acme/app"]["visibility"] = "public"' "[$CMT]"
  alone "[P] a missing issue" exists '' '[{"op": "issue-close", "repo": "acme/app", "issue": 404, "reason": "completed"}]'
  alone "[P] a comment on a closed issue" open '' '[{"op": "issue-comment", "repo": "acme/app", "issue": 60, "body": "x <!-- m -->", "marker": "<!-- m -->"}]'
  alone "[P] a reopen of an open issue" closed '' '[{"op": "issue-reopen", "repo": "acme/app", "issue": 61}]'
  alone "[P] a close of a closed issue" open '' '[{"op": "issue-close", "repo": "acme/app", "issue": 60, "reason": "completed"}]'
  alone "[P] a comment whose marker a comment on the target already holds" marker-absent \
    'W["repos"]["acme/app"]["comments"]["900"]["body"] = "earlier <!-- m-c -->"' "[$CMT]"
  alone "[P] a create whose marker an issue of the viewer already holds" marker-absent \
    'W["repos"]["acme/app"]["issues"]["62"]["body"] = "x <!-- m-n -->"' "[$NEW]"
  alone "[P] a marker the body does not hold" marker-in-body '' '[{"op": "issue-comment", "repo": "acme/app", "issue": 59, "body": "x", "marker": "<!-- m -->"}]'
  alone "[P] a label the repository does not have" labels '' '[{"op": "issue-create", "repo": "acme/app", "title": "t", "labels": ["nope"], "body": "x <!-- m -->", "marker": "<!-- m -->"}]'
  alone "[P] an edit of another author's comment" author '' '[{"op": "comment-edit", "repo": "acme/app", "comment": 901, "body": "mine now"}]'
  alone "[P] an edit that changes nothing" changes '' '[{"op": "issue-edit", "repo": "acme/app", "issue": 61, "body": "sixty-one\n"}]'
  alone "[P] a missing comment" exists '' '[{"op": "comment-edit", "repo": "acme/app", "comment": 999, "body": "x"}]'
  alone "[P] a PR body edit of an issue that is not a PR" exists '' '[{"op": "pr-body-edit", "repo": "acme/app", "pr": 59, "body": "x"}]'
  d=$(mkw); printf 'the body\n' > "$d/b.md"
  spec "$d" '[{"op": "pr-body-edit", "repo": "acme/app", "pr": 7, "body_file": "b.md", "sha256": "'"$(printf '%064d' 0)"'"}]'
  eng "$PL" "$d" --spec spec.json; eq "$RC/$(nfail)" "1/1" "[P] a body_file that does not match its pin: rc 1, one failed condition"
  has "$OUT" "FAIL  pinned:" "[P] …named pinned"
  d=$(mkw); spec "$d" "[$CMT]"; mkdir -p "$d/state/vibemaestro/gh-write"
  printf '{"spec": "%s", "paths": ["/elsewhere/spec.json"], "state": "open", "run": "0", "entries": {}}' "$(sha "$d/spec.json")" > "$d/state/vibemaestro/gh-write/$(sha "$d/spec.json").json"
  eng "$PL" "$d" --spec spec.json; eq "$RC/$(nfail)" "1/1" "[P] an unfinished run of the same spec (journal open): rc 1, one failed condition"
  has "$OUT" "FAIL  journal:" "[P] …named journal"
}

# [K] a closed target takes an issue-comment only with "closed_ok": true; every other op still refuses it
fam_closed_ok() {
  PL=$1; local d c60 c7 CLOSE_PR
  CLOSE_PR='W["repos"]["acme/app"]["issues"]["7"]["state"] = "closed"; W["repos"]["acme/app"]["issues"]["7"]["state_reason"] = "completed"'
  c60='{"op": "issue-comment", "repo": "acme/app", "issue": 60, "body": "measured <!-- m-k -->", "marker": "<!-- m-k -->", "closed_ok": true}'
  c7='{"op": "issue-comment", "repo": "acme/app", "issue": 7, "body": "measured <!-- m-k -->", "marker": "<!-- m-k -->", "closed_ok": true}'
  d=$(mkw); spec "$d" "[$c60]"; eng "$PL" "$d" --spec spec.json
  eq "$RC" 0 "[K1] a comment with closed_ok on a closed issue: rehearse rc 0"
  has "$OUT" "on a closed target (closed_ok)" "[K2] …the plan line says it was posted on a closed target"
  has "$OUT" "is closed (closed_ok)" "[K3] …and the open condition names closed_ok"
  d=$(mkw "$CLOSE_PR"); spec "$d" "[$c7]"; eng "$PL" "$d" --spec spec.json
  eq "$RC" 0 "[K4] …on a closed pull request (merged or closed): rc 0"
  has "$OUT" "on a closed target (closed_ok)" "[K4b] …the plan line says so"
  alone "[K5] the same comment without closed_ok on the closed issue" open '' \
    '[{"op": "issue-comment", "repo": "acme/app", "issue": 60, "body": "x <!-- m -->", "marker": "<!-- m -->"}]'
  alone "[K6] …and with closed_ok false" open '' \
    '[{"op": "issue-comment", "repo": "acme/app", "issue": 60, "body": "x <!-- m -->", "marker": "<!-- m -->", "closed_ok": false}]'
  alone "[K7] …and on a closed pull request without it" open "$CLOSE_PR" \
    '[{"op": "issue-comment", "repo": "acme/app", "issue": 7, "body": "x <!-- m -->", "marker": "<!-- m -->"}]'
  refuse "[K8] closed_ok on an issue-edit" refuse-unknown-key '[{"op": "issue-edit", "repo": "acme/app", "issue": 60, "body": "x", "closed_ok": true}]'
  refuse "[K9] closed_ok on an issue-reopen" refuse-unknown-key '[{"op": "issue-reopen", "repo": "acme/app", "issue": 60, "closed_ok": true}]'
  refuse "[K10] closed_ok on a comment-edit" refuse-unknown-key '[{"op": "comment-edit", "repo": "acme/app", "comment": 900, "body": "x", "closed_ok": true}]'
  refuse "[K11] closed_ok that is not a boolean" refuse-spec \
    '[{"op": "issue-comment", "repo": "acme/app", "issue": 60, "body": "x <!-- m -->", "marker": "<!-- m -->", "closed_ok": "yes"}]'
  d=$(mkw); spec "$d" '[{"op": "issue-comment", "repo": "acme/app", "issue": 59, "body": "x <!-- m -->", "marker": "<!-- m -->", "closed_ok": true}]'
  eng "$PL" "$d" --spec spec.json
  hasnt "$OUT" "closed target" "[K12] closed_ok on an open issue: it passes and the plan line says nothing of a closed target"
  d=$(mkw); spec "$d" "[$c60]"; full "$PL" "$d"
  eq "$RC" 0 "[K13] run: the comment lands on the closed issue (rc 0)"
  eq "$(writes "$d" | tr '\n' ';')" "POST repos/acme/app/issues/60/comments;" "[K14] …one write call, the planned comment"
  eq "$(wq "$d" 'R["comments"]["5000"]["body"]')" "measured <!-- m-k -->" "[K15] …and the body on the closed issue is the posted one"
  eq "$(wq "$d" 'R["issues"]["60"]["state"]')" closed "[K16] …and the issue stays closed"
}

fam_rehearse() {
  PL=$1; local d seal
  d=$(mkw); spec "$d" "$TWO"; bt "$PL" "$d" rehearse kit:gh-write --spec spec.json
  eq "$RC" 0 "[R] rehearse a two-op spec (create, then a comment citing it): rc 0"
  eq "$(nplan)" 2 "[R] …two PLAN lines"
  eq "$(printf '%s\n' "$OUT" | grep -c '^  ok   gh-write .*  ~  gh-write \*$')" 2 "[R] …each matches Each in the plan-against-Expect table"
  has "$OUT" "PLAN gh-write 1/2 spec $(sha "$d/spec.json") issue-create acme/app title \"A new issue\"" \
      "[R] …the plan line carries the spec's full sha256"
  seal=$(seal_of); bt "$PL" "$d" mode auto; bt "$PL" "$d" sign --by coordinator-auto --seal "${seal:-none}" kit:gh-write --spec spec.json
  eq "$RC" 0 "[R] sign --by coordinator-auto (Stops: none, mode auto): rc 0"
  eq "$(nwrites "$d")" 0 "[R] rehearse and sign made no write call (the fake's log has only GET)"
  d=$(mkw); spec "$d" '[{"op": "issue-comment", "repo": "acme/pub", "issue": 1, "body": "x <!-- m -->", "marker": "<!-- m -->"}]'
  bt "$PL" "$d" mode auto; bt "$PL" "$d" rehearse kit:gh-write --spec spec.json
  eq "$RC" 1 "[R] a public repository: rehearse rc 1"
  bt "$PL" "$d" sign --by coordinator-auto --seal 0123456789abcdef.0123456789abcdef kit:gh-write --spec spec.json
  ne "$RC" 0 "[R] …it cannot be signed (refused, not escalated)"
  bt "$PL" "$d" rehearse kit:gh-write --spec spec.json --spec other.json
  eq "$RC" 1 "[R] other arguments than --spec <file>: rehearse rc 1"
  d=$(mkw); spec "$d" "[$CMT]"
  OUT=$(cd "$d" && cenv FAKE_GH_STATE="$d/world.json" FAKE_GH_LOG="$d/gh.log" bash "$PL/batons/gh-write.sh" --spec spec.json 2>&1); RC=$?
  eq "$RC/$(nwrites "$d")" "64/0" "[R] the kit baton run with plain bash (no baton): refused, rc 64, no write"
}

fam_run() {
  PL=$1; local d
  d=$(mkw); spec "$d" "$TWO"; full "$PL" "$d"
  eq "$RC" 0 "[M] run the two-op spec: rc 0"
  eq "$(writes "$d" | tr '\n' ';')" "POST repos/acme/app/issues;POST repos/acme/app/issues/59/comments;" "[M] …exactly the planned write calls, in order"
  eq "$(wq "$d" 'R["issues"]["100"]["body"]')" "Body
<!-- m-n -->" "[M] …the created issue holds the posted body"
  eq "$(wq "$d" 'R["comments"]["5000"]["body"]')" "Opened acme/app#100 for this.
<!-- m-l -->" "[M] …the comment cites the created issue by its number"
  # `run` prints one line when it holds: the post-check verdict is in the run log that line names
  has "$(cat "$(printf '%s\n' "$OUT" | sed -n 's/^run: ok — [0-9]* writes\{0,1\} — //p')" 2>/dev/null)" "VERDICT postcheck ok" "[M] …the post-check held"
  bt "$PL" "$d" rehearse kit:gh-write --spec spec.json
  eq "$RC" 1 "[M] a second rehearse of the same spec: refused (rc 1)"
  has "$OUT" "FAIL  marker-absent:" "[M] …the markers are already there"
  d=$(mkw); spec "$d" "[$NEW,
    {\"op\": \"issue-comment\", \"repo\": \"acme/app\", \"issue\": \"@new\", \"body\": \"first <!-- m-1 -->\", \"marker\": \"<!-- m-1 -->\"},
    {\"op\": \"comment-edit\", \"repo\": \"acme/app\", \"comment\": 900, \"body\": \"my comment, edited\"},
    {\"op\": \"issue-edit\", \"repo\": \"acme/app\", \"issue\": 61, \"title\": \"Sixty-one, renamed\", \"body\": \"new 61\"},
    {\"op\": \"pr-body-edit\", \"repo\": \"acme/app\", \"pr\": 7, \"body\": \"new pr body\"},
    {\"op\": \"issue-reopen\", \"repo\": \"acme/app\", \"issue\": 60},
    {\"op\": \"issue-close\", \"repo\": \"acme/app\", \"issue\": 62, \"reason\": \"not_planned\"}]"
  full "$PL" "$d"
  eq "$RC" 0 "[M] every kind in one spec: rc 0"
  eq "$(writes "$d" | tr '\n' ';')" "POST repos/acme/app/issues;POST repos/acme/app/issues/100/comments;PATCH repos/acme/app/issues/comments/900;PATCH repos/acme/app/issues/61;PATCH repos/acme/app/pulls/7;PATCH repos/acme/app/issues/60;PATCH repos/acme/app/issues/62;" \
     "[M] …seven write calls, in the spec's order"
  eq "$(wq "$d" '(R["issues"]["61"]["title"], R["issues"]["61"]["body"], R["issues"]["7"]["body"], R["issues"]["60"]["state"], R["issues"]["62"]["state_reason"])')" \
     "('Sixty-one, renamed', 'new 61', 'new pr body', 'open', 'not_planned')" "[M] …each target reads what the op wrote"
  d=$(mkw 'W["faults"].update(swap_after_write=1, swap=[["acme/app", "comments", "5000", {"issue": 61}]])'); spec "$d" "[$CMT]"; full "$PL" "$d"
  eq "$RC" 4 "[M] a comment the post-check reads on another issue: red, undo retracts it (rc 4)"
  d=$(mkw); spec "$d" '[{"op": "issue-comment", "repo": "ACME/App", "issue": 59, "body": "hello <!-- m-c -->", "marker": "<!-- m-c -->"}]'; full "$PL" "$d"
  eq "$RC" 0 "[M] a spec that spells the repository in another case: the post-check holds (rc 0)"
  # the coordinator's commands for one comment, from a spec file to a logged run: the transcript the PR shows
  d=$(mkw); local steps=0 seal
  bt "$PL" "$d" mode auto
  spec "$d" "[$CMT]"; steps=$((steps + 1))                                                  # 1 Write spec.json
  bt "$PL" "$d" rehearse kit:gh-write --spec spec.json; seal=$(seal_of); steps=$((steps + 1)) # 2 rehearse
  bt "$PL" "$d" sign --by coordinator-auto --seal "${seal:-none}" kit:gh-write --spec spec.json; steps=$((steps + 1))   # 3 sign
  bt "$PL" "$d" run kit:gh-write --spec spec.json; steps=$((steps + 1))                     # 4 run
  eq "$RC" 0 "[M] one comment, the coordinator's commands: the run is rc 0"
  echo "  tool calls: $steps"
  eq "$steps" 4 "[M] one comment, the coordinator's commands: tool calls: 4 (Write, rehearse, sign, run)"
  bt "$PL" "$d" log --tail 1
  has "$OUT" "gh-write.sh" "[M] …and the run is in the log"
}

# pr-close closes a component PR, pinned to its head; its undo reopens it unless it was merged since
# [C] issue-close with its closing comment: one op, the comment posted before the close, the undo retracts it and reopens
CC='{"op": "issue-close", "repo": "acme/app", "issue": 62, "reason": "completed", "comment": "Done in the PR.\n<!-- m-cc -->", "marker": "<!-- m-cc -->"}'
CCN='{"op": "issue-close", "repo": "acme/app", "issue": 62, "reason": "completed"'
fam_closec() {
  PL=$1; local d v
  refuse "[C] a comment without its marker" refuse-spec "[$CCN, \"comment\": \"Done.\"}]"
  refuse "[C] a marker without a comment" refuse-spec "[$CCN, \"marker\": \"<!-- m-cc -->\"}]"
  refuse "[C] a comment and a comment_file" refuse-body "[$CCN, \"comment\": \"x <!-- m-cc -->\", \"comment_file\": \"c.md\", \"sha256\": \"$(printf '%064d' 0)\", \"marker\": \"<!-- m-cc -->\"}]"
  refuse "[C] a comment_file pinned by a sha that is not 64 hex" refuse-body "[$CCN, \"comment_file\": \"c.md\", \"sha256\": \"abc\", \"marker\": \"<!-- m-cc -->\"}]"
  refuse "[C] a body on an issue-close (the key is comment)" refuse-unknown-key "[$CCN, \"body\": \"x <!-- m-cc -->\", \"marker\": \"<!-- m-cc -->\"}]"
  refuse "[C] a CR in the comment" refuse-body "[$CCN, \"comment\": \"a\\r\\nb <!-- m-cc -->\", \"marker\": \"<!-- m-cc -->\"}]"
  refuse "[C] the same issue closed with a comment and commented by another op" refuse-same-target \
    "[$CC, {\"op\": \"issue-comment\", \"repo\": \"acme/app\", \"issue\": 62, \"body\": \"x <!-- m-2 -->\", \"marker\": \"<!-- m-2 -->\"}]"
  refuse "[C] a comment on a close, then an edit of the same issue" refuse-same-target \
    "[$CC, {\"op\": \"issue-edit\", \"repo\": \"acme/app\", \"issue\": 62, \"title\": \"t\"}]"
  refuse "[C] the marker of the close is in another op's body" refuse-spec \
    "[$CC, {\"op\": \"issue-edit\", \"repo\": \"acme/app\", \"issue\": 61, \"body\": \"quotes <!-- m-cc -->\"}]"
  alone "[C] a marker already on a comment of the target" marker-absent \
    'W["repos"]["acme/app"]["comments"]["902"] = {"issue": 62, "body": "earlier <!-- m-cc -->", "user": "bot"}' "[$CC]"
  alone "[C] a close with a comment of a closed issue" open '' '[{"op": "issue-close", "repo": "acme/app", "issue": 60, "reason": "completed", "comment": "x <!-- m-cc -->", "marker": "<!-- m-cc -->"}]'
  # the plan line carries the comment's digest, so the signature binds its text
  d=$(mkw); spec "$d" "[$CC]"; eng "$PL" "$d" --spec spec.json
  eq "$RC" 0 "[C] the plan of a close with a comment: rc 0"
  has "$OUT" " reason completed comment body " "[C] …the plan line names the comment's digest"
  eq "$(nwrites "$d")" 0 "[C] …and it makes no write call"
  d=$(mkw); spec "$d" "[{\"op\": \"issue-close\", \"repo\": \"acme/app\", \"issue\": 62, \"reason\": \"completed\"}]"; eng "$PL" "$d" --spec spec.json
  hasnt "$OUT" " comment " "[C] a close without a comment keeps its plan line"
  # the run: the comment first, then the close, and the post-check holds
  d=$(mkw); spec "$d" "[$CC]"; full "$PL" "$d"
  eq "$RC" 0 "[C] run a close with a comment: rc 0"
  eq "$(writes "$d" | tr '\n' ';')" "POST repos/acme/app/issues/62/comments;PATCH repos/acme/app/issues/62;" "[C] …the comment is posted before the close, two write calls"
  eq "$(wq "$d" 'R["issues"]["62"]["state"], R["issues"]["62"]["state_reason"]')" "('closed', 'completed')" "[C] …the issue is closed as completed"
  eq "$(wq "$d" 'R["comments"]["5000"]["issue"], R["comments"]["5000"]["body"]')" "(62, 'Done in the PR.\n<!-- m-cc -->')" "[C] …the comment is on that issue with the posted body"
  has "$(cat "$(printf '%s\n' "$OUT" | sed -n 's/^run: ok — [0-9]* writes\{0,1\} — //p')" 2>/dev/null)" "VERDICT postcheck ok" "[C] …the post-check held"
  # the undo: a later op is refused by GitHub; the comment is retracted by an edit (never deleted) and the issue reopened
  d=$(mkw 'W["faults"]["fail_write"] = 3'); spec "$d" "[$CC, $NEW]"; full "$PL" "$d"
  eq "$RC" 4 "[C] a run that fails after a close with a comment: undo, rc 4"
  eq "$(wq "$d" 'R["issues"]["62"]["state"]')" open "[C] …the issue is open again"
  has "$(wq "$d" 'R["comments"]["5000"]["body"]')" "Retracted" "[C] …the comment is retracted by an edit"
  eq "$(wq "$d" 'len(R["comments"])')" 3 "[C] …and no comment is gone"
  eq "$(ndeletes "$d")" 0 "[C] …no DELETE or PUT call"
  bt "$PL" "$d" rehearse kit:gh-write --spec spec.json
  eq "$RC" 0 "[C] …after that undo the same spec rehearses again (the marker left the retracted comment)"
  d=$(mkw 'W["faults"]["fail_write"] = 2'); spec "$d" "[$CC]"; full "$PL" "$d"
  eq "$RC" 4 "[C] a close GitHub refuses after the comment landed: undo, rc 4"
  has "$(wq "$d" 'R["comments"]["5000"]["body"]')" "Retracted" "[C] …the comment that landed is retracted"
  eq "$(wq "$d" 'R["issues"]["62"]["state"]')" open "[C] …the issue was never closed"
  # both are checked before either is written: one that changed since the run leaves both alone (rc 5)
  d=$(mkw 'W["faults"].update(fail_write=3, swap_after_write=2, swap=[["acme/app", "issues", "62", {"state_reason": "not_planned"}]])')
  spec "$d" "[$CC, $NEW]"; full "$PL" "$d"
  eq "$RC" 5 "[C] an issue closed again for another reason: rc 5"
  eq "$(wq "$d" 'R["issues"]["62"]["state"], R["comments"]["5000"]["body"]')" "('closed', 'Done in the PR.\n<!-- m-cc -->')" "[C] …the issue is not reopened and the comment is not retracted"
  d=$(mkw 'W["faults"].update(fail_write=3, swap_after_write=2, swap=[["acme/app", "comments", "5000", {"body": "edited by a person"}]])')
  spec "$d" "[$CC, $NEW]"; full "$PL" "$d"
  eq "$RC" 5 "[C] a comment someone edited after the run: rc 5"
  eq "$(wq "$d" 'R["issues"]["62"]["state"], R["comments"]["5000"]["body"]')" "('closed', 'edited by a person')" "[C] …their text stays and the issue is not reopened"
  d=$(mkw 'W["faults"].update(fail_write=3, swap_after_write=2, swap=[["acme/app", "issues", "62", {"state": "open"}]])')
  spec "$d" "[$CC, $NEW]"; full "$PL" "$d"
  eq "$RC" 4 "[C] an issue someone reopened already: the comment is still retracted, rc 4"
  has "$(wq "$d" 'R["comments"]["5000"]["body"]')" "Retracted" "[C] …the comment is retracted"
  # an undo cut short (the reopen landed, its answer was lost) is finished by the recovery
  d=$(mkw 'W["faults"].update(fail_write=3, land_then_fail=5)'); spec "$d" "[$CC, $NEW]"; full "$PL" "$d"
  v=$(wq "$d" 'R["issues"]["62"]["state"], R["comments"]["5000"]["body"][:9]')
  eq "$v" "('open', 'Retracted')" "[C] an undo whose last write's answer was lost: both parts are back"
  bt "$PL" "$d" rehearse kit:gh-write --spec spec.json --recover; local seal; seal=$(seal_of)
  bt "$PL" "$d" sign --by coordinator-auto --seal "${seal:-none}" kit:gh-write --spec spec.json --recover
  bt "$PL" "$d" run kit:gh-write --spec spec.json --recover
  eq "$RC" 0 "[C] …and its recovery finishes: rc 0, nothing left to do"
  # a close the run never sent is not the run's to undo: the comment landed, its answer was lost, a person closed the issue meanwhile
  d=$(mkw 'W["faults"].update(land_then_fail=1, swap_after_write=1, swap=[["acme/app", "issues", "62", {"state": "closed", "state_reason": "completed"}]])')
  spec "$d" "[$CC]"; full "$PL" "$d"
  eq "$(wq "$d" 'R["issues"]["62"]["state"]')" closed "[C] a comment landed, its answer lost, a person closed the issue: the undo does not reopen it"
  has "$(wq "$d" 'R["comments"]["5000"]["body"]')" "Retracted" "[C] …and the comment is retracted"
  # a close GitHub refused is not the run's either: the comment landed, the close was refused, a person closed the issue in between
  d=$(mkw 'W["faults"].update(fail_write=2, swap_after_write=1, swap=[["acme/app", "issues", "62", {"state": "closed", "state_reason": "completed"}]])')
  spec "$d" "[$CC]"; full "$PL" "$d"
  eq "$(wq "$d" 'R["issues"]["62"]["state"]')" closed "[C] a close GitHub refused, then a person's close: the undo does not reopen it"
  has "$(wq "$d" 'R["comments"]["5000"]["body"]')" "Retracted" "[C] …and the comment is retracted"
  # the post-check reads the comment too: GitHub storing it with one newline more fails the run
  d=$(mkw 'W["faults"]["store"] = "add-nl"'); spec "$d" "[$CC]"; full "$PL" "$d"
  has "$OUT" "comment body differs" "[C] a comment GitHub stores with one newline more: the post-check names it"
  [ "$RC" != 0 ] && ok "[C] …and the run does not end green" || bad "[C] …and the run does not end green"
}

fam_prclose() {
  PL=$1; local d
  refuse "[W] a pr-close without a full head SHA" refuse-spec '[{"op": "pr-close", "repo": "acme/app", "pr": 7, "head": "abc"}]'
  refuse "[W] a pr-close with a body" refuse-unknown-key '[{"op": "pr-close", "repo": "acme/app", "pr": 7, "head": "'"$HD"'", "body": "x"}]'
  alone "[W] a pr-close of an issue that is not a pull request" exists '' '[{"op": "pr-close", "repo": "acme/app", "pr": 59, "head": "'"$HD"'"}]'
  alone "[W] a pr-close whose head moved" head 'W["repos"]["acme/app"]["issues"]["7"]["head"] = "'"$HD2"'"' "[$PRC]"
  alone "[W] a pr-close of a merged pull request" open 'W["repos"]["acme/app"]["issues"]["7"].update(state="closed", merged=True)' "[$PRC]"
  d=$(mkw); spec "$d" "[$PRC]"; eng "$PL" "$d" --spec spec.json
  eq "$RC" 0 "[W] control: a pr-close of an open pull request at its head plans (rc 0)"
  has "$OUT" "pr-close acme/app#7 head $HD" "[W] …its plan line names the pinned head"
  d=$(mkw); spec "$d" "[$PRC]"; full "$PL" "$d"
  eq "$RC" 0 "[W] a pr-close run: rc 0"
  eq "$(writes "$d" | tr '\n' ';')" "PATCH repos/acme/app/pulls/7;" "[W] …one PATCH of the pull request"
  eq "$(wq "$d" 'R["issues"]["7"]["state"]')" closed "[W] …the pull request is closed"
  d=$(mkw 'W["faults"]["fail_write"] = 2'); spec "$d" "[$PRC, $NEW]"; full "$PL" "$d"
  eq "$RC" 4 "[W] a create that fails after a pr-close: undo reopens the pull request (rc 4)"
  eq "$(wq "$d" 'R["issues"]["7"]["state"]')" open "[W] …the pull request is open again"
  d=$(mkw 'W["faults"].update(fail_write=2, swap_after_write=1, swap=[["acme/app", "issues", "7", {"merged": True}]])')
  spec "$d" "[$PRC, $NEW]"; full "$PL" "$d"
  eq "$RC" 5 "[W] a pull request merged after the run closed it: not reopened, rc 5"
  eq "$(wq "$d" 'R["issues"]["7"]["state"]')" closed "[W] …it stays as it is"
  d=$(mkw 'W["faults"].update(fail_write=2, swap_after_write=1, swap=[["acme/app", "issues", "7", {"closed_by": "someone"}]])')
  spec "$d" "[$PRC, $NEW]"; full "$PL" "$d"
  eq "$RC" 5 "[W] a pull request someone else closed after the run: not reopened, rc 5"
  eq "$(wq "$d" 'R["issues"]["7"]["state"]')" closed "[W] …their close stays"
}

fam_lag() {
  PL=$1; local d
  d=$(mkw 'W["faults"]["lag"] = True'); spec "$d" "[$NEW, {\"op\": \"issue-comment\", \"repo\": \"acme/app\", \"issue\": \"@new\", \"body\": \"on the new one <!-- m-q -->\", \"marker\": \"<!-- m-q -->\"}]"
  full "$PL" "$d"
  eq "$RC" 0 "[L] trap 1: a list that lags behind the create: the run still succeeds (rc 0)"
  eq "$(writes "$d" | sed -n 2p)" "POST repos/acme/app/issues/100/comments" "[L] …the comment went to the created issue, number from the create's own output"
}

fam_newline() {
  PL=$1; local d
  d=$(mkw); printf 'Body from a file\n<!-- m-f -->\n' > "$d/b.md"
  spec "$d" '[{"op": "issue-create", "repo": "acme/app", "title": "From a file", "body_file": "b.md", "sha256": "'"$(sha "$d/b.md")"'", "marker": "<!-- m-f -->"}]'
  full "$PL" "$d"
  eq "$RC" 0 "[N] trap 2: a body file ending in a newline: the post-check holds (rc 0)"
  eq "$(wq "$d" 'repr(R["issues"]["100"]["body"])')" "'Body from a file\\n<!-- m-f -->'" "[N] …posted with its one final newline removed"
  d=$(mkw 'W["faults"]["store"] = "add-nl"'); spec "$d" "[$NEW]"; full "$PL" "$d"
  eq "$RC" 4 "[N] GitHub stores one newline more: the post-check fails, undo closes the issue (rc 4)"
  has "$OUT" "body differs: live 18B, posted 17B, first difference at byte 17" "[N] …the post-check names the byte difference"
  eq "$(wq "$d" 'R["issues"]["100"]["state_reason"]')" not_planned "[N] …and the issue is closed as not planned"
  d=$(mkw 'W["faults"]["store"] = "strip-nl"'); spec "$d" '[{"op": "issue-create", "repo": "acme/app", "title": "t", "body": "x <!-- m -->\n\n", "marker": "<!-- m -->"}]'
  full "$PL" "$d"
  eq "$RC" 4 "[N] GitHub stores one newline less: the post-check fails (rc 4)"
  d=$(mkw 'W["faults"]["store"] = "flip"'); spec "$d" "[$NEW]"; full "$PL" "$d"
  eq "$RC" 4 "[N] a live body that differs in its last byte: the post-check fails (rc 4)"
}

fam_fence() {
  PL=$1; local d body
  body='## Evidence\n```\n$ bash t.sh\n```bash\nnested\n```\n## Context\n```\n'
  d=$(mkw); spec "$d" "[{\"op\": \"pr-body-edit\", \"repo\": \"acme/app\", \"pr\": 7, \"body\": \"$body\"}]"
  bt "$PL" "$d" mode auto; bt "$PL" "$d" rehearse kit:gh-write --spec spec.json
  eq "$RC" 1 "[F] trap 3: a body whose inner fence closes the outer one: rehearse rc 1"
  has "$OUT" "FAIL  fences:" "[F] …named fences"
  d=$(mkw); spec "$d" '[{"op": "pr-body-edit", "repo": "acme/app", "pr": 7, "body": "````\n```bash\nnested\n```\n````\n"}]'
  eng "$PL" "$d" --spec spec.json; eq "$RC" 0 "[F] control: an outer fence longer than the inner one passes"
}

fam_trap4() {
  PL=$1; local d v
  d=$(mkw); bt "$PL" "$d" check kit:gh-write
  eq "$RC" 0 "[T] trap 4: baton check kit:gh-write: rc 0"
  v=$(python3 - "$PL" <<'PY'
import sys
sys.path.insert(0, sys.argv[1] + "/scripts")
import baton
t = baton.gate_body(open(sys.argv[1] + "/templates/baton-script.sh").read())
k = baton.gate_body(open(sys.argv[1] + "/batons/gh-write.sh").read())
print("same" if t == k and t else "differs")
PY
)
  eq "$v" same "[T] …its write() is byte-identical to the template's"
  eq "$(grep -c 'grep' "$PL/batons/gh-write.sh")" 0 "[T] …it uses no grep (none under pipefail)"
  eq "$(grep -c '^# Each: gh-write \*$' "$PL/batons/gh-write.sh")" 1 "[T] …its plan lines are matched whole by one Each glob"
}

fam_ref() {
  PL=$1; local d
  d=$(mkw); spec "$d" "[$NEW, {\"op\": \"issue-comment\", \"repo\": \"acme/app\", \"issue\": \"@new\", \"body\": \"Self {{issue:new}} <!-- m-r -->\", \"marker\": \"<!-- m-r -->\"}]"
  bt "$PL" "$d" rehearse kit:gh-write --spec spec.json
  has "$OUT" "PLAN gh-write 2/2 spec $(sha "$d/spec.json") issue-comment acme/app@new body template " \
      "[Q] trap 5: the plan line names the created issue as @new (known only after the create)"
  full "$PL" "$d"
  eq "$RC" 0 "[Q] …the run resolves it inside write(): rc 0"
  eq "$(wq "$d" 'R["comments"]["5000"]["issue"], R["comments"]["5000"]["body"]')" "(100, 'Self acme/app#100 <!-- m-r -->')" \
     "[Q] …the comment is on #100 and cites it"
}

fam_undo() {
  PL=$1; local d
  d=$(mkw 'W["faults"]["fail_write"] = 2'); spec "$d" "[{\"op\": \"issue-edit\", \"repo\": \"acme/app\", \"issue\": 61, \"body\": \"edited 61\"}, $NEW]"
  full "$PL" "$d"
  eq "$RC" 4 "[U] a create that fails after an edit: undo puts the edit back (rc 4)"
  eq "$(wq "$d" 'R["issues"]["61"]["body"]')" "sixty-one" "[U] …the live body is the saved one"
  eq "$(writes "$d" | tail -n 1)" "PATCH repos/acme/app/issues/61" "[U] …by one PATCH of the edited issue"
  eq "$(ndeletes "$d")" 0 "[U] …and no DELETE or PUT call"
  d=$(mkw 'W["faults"]["fail_write"] = 3'); spec "$d" "[$NEW, {\"op\": \"issue-comment\", \"repo\": \"acme/app\", \"issue\": \"@new\", \"body\": \"c <!-- m-u -->\", \"marker\": \"<!-- m-u -->\"},
    {\"op\": \"issue-edit\", \"repo\": \"acme/app\", \"issue\": 61, \"title\": \"never\"}]"
  full "$PL" "$d"
  eq "$RC" 4 "[U] a run that fails after a create and a comment: rc 4"
  eq "$(wq "$d" 'R["issues"]["100"]["state"], R["issues"]["100"]["state_reason"]')" "('closed', 'not_planned')" "[U] …the created issue is closed as not planned"
  has "$(wq "$d" 'R["comments"]["5000"]["body"]')" "Retracted" "[U] …the new comment is retracted by an edit"
  eq "$(wq "$d" 'R["issues"]["61"]["title"]')" "Sixty-one" "[U] …the op that never landed is left as it was"
  eq "$(ndeletes "$d")" 0 "[U] …no DELETE or PUT call"
  bt "$PL" "$d" rehearse kit:gh-write --spec spec.json
  eq "$RC" 0 "[U] …after that undo the same spec rehearses again (the closed issue no longer holds the marker)"
  d=$(mkw 'W["faults"].update(fail_write=2, swap_after_write=1, swap=[["acme/app", "issues", "61", {"body": "someone else"}]])')
  spec "$d" "[{\"op\": \"issue-edit\", \"repo\": \"acme/app\", \"issue\": 61, \"body\": \"edited 61\"}, $NEW]"
  full "$PL" "$d"
  eq "$RC" 5 "[U] a body someone changed after the run: undo leaves it alone, rc 5 (tell the owner)"
  eq "$(wq "$d" 'R["issues"]["61"]["body"]')" "someone else" "[U] …their body is still there"
  d=$(mkw 'W["faults"].update(land_then_fail=1, lag=True)'); spec "$d" "[$NEW]"; full "$PL" "$d"
  eq "$RC" 5 "[U] a create that landed, an answer lost, a list that lags: undo cannot find it, rc 5 (not a false 'put back')"
  eq "$(wq "$d" 'R["issues"]["100"]["state"]')" open "[U] …the issue is there, for the owner to see"
  local seal; bt "$PL" "$d" rehearse kit:gh-write --spec spec.json --recover; seal=$(seal_of)
  bt "$PL" "$d" sign --by coordinator-auto --seal "${seal:-none}" kit:gh-write --spec spec.json --recover
  bt "$PL" "$d" run kit:gh-write --spec spec.json --recover
  eq "$RC" 5 "[U] …its recovery cannot find it either: rc 5"
  bt "$PL" "$d" rehearse kit:gh-write --spec spec.json
  eq "$RC" 1 "[U] …and a rerun of the spec is refused until the owner has looked (no second issue)"
  has "$OUT" "outcome is unknown" "[U] …named: a write whose outcome is unknown"
  d=$(mkw 'W["faults"].update(land_then_fail=1)'); spec "$d" "[$NEW]"; full "$PL" "$d"
  eq "$RC" 4 "[U] a create that landed, an answer lost, the list shows it: undo finds it by its marker and closes it, rc 4"
  eq "$(wq "$d" 'R["issues"]["100"]["state_reason"]')" not_planned "[U] …closed as not planned"
  d=$(mkw 'W["faults"].update(land_then_fail=1, swap_after_write=1, swap=[["acme/app", "issues", "63", {"title": "x", "body": "copy <!-- m-n -->", "state": "open", "user": "bot"}]])')
  spec "$d" "[$NEW]"; full "$PL" "$d"
  eq "$RC" 5 "[U] …and when two issues hold the marker: left alone, rc 5"
  d=$(mkw 'W["faults"].update(fail_write=2, swap_after_write=1, swap=[["acme/app", "issues", "62", {"state_reason": "completed"}]])')
  spec "$d" "[{\"op\": \"issue-close\", \"repo\": \"acme/app\", \"issue\": 62, \"reason\": \"not_planned\"}, $NEW]"; full "$PL" "$d"
  eq "$RC" 5 "[U] an issue closed by the run, then closed again for another reason: not reopened, rc 5"
  d=$(mkw 'W["faults"]["fail_write"] = 1'); spec "$d" "[$CMT]"; full "$PL" "$d"
  eq "$RC" 4 "[U] a single write GitHub refused (4xx): nothing to undo, rc 4"
  bt "$PL" "$d" rehearse kit:gh-write --spec spec.json
  eq "$RC" 0 "[U] …and the run is closed: the spec rehearses again"
  d=$(mkw 'W["faults"].update(fail_write=2, swap_after_write=1, swap=[["acme/app", "comments", "5000", {"body": "edited by a person"}]])')
  spec "$d" "[$CMT, {\"op\": \"issue-close\", \"repo\": \"acme/app\", \"issue\": 62, \"reason\": \"completed\"}]"
  full "$PL" "$d"
  eq "$RC" 5 "[U] a new comment someone edited after the run: not retracted, rc 5"
  eq "$(wq "$d" 'R["comments"]["5000"]["body"]')" "edited by a person" "[U] …their text is still there"
}

fam_seal() {
  PL=$1; local d seal
  d=$(mkw); printf 'the reviewed body\n' > "$d/b.md"
  spec "$d" '[{"op": "pr-body-edit", "repo": "acme/app", "pr": 7, "body_file": "b.md", "sha256": "'"$(sha "$d/b.md")"'"}]'
  bt "$PL" "$d" mode auto; bt "$PL" "$d" rehearse kit:gh-write --spec spec.json; seal=$(seal_of)
  bt "$PL" "$d" sign --by coordinator-auto --seal "${seal:-none}" kit:gh-write --spec spec.json
  printf 'another body\n' > "$d/b.md"; bt "$PL" "$d" run kit:gh-write --spec spec.json
  eq "$RC/$(nwrites "$d")" "3/0" "[B] the body file edited after signing (old pin): run refused, rc 3, nothing written"
  spec "$d" '[{"op": "pr-body-edit", "repo": "acme/app", "pr": 7, "body_file": "b.md", "sha256": "'"$(sha "$d/b.md")"'"}]'
  bt "$PL" "$d" run kit:gh-write --spec spec.json
  eq "$RC/$(nwrites "$d")" "3/0" "[B] …and re-pinned in the spec: the plan differs from the signed one, rc 3, nothing written"
  d=$(mkw 'W["faults"].update(swap_at_read=["repos/acme/app/issues/61", 5], swap=[["acme/app", "issues", "61", {"body": "moved"}]])')
  spec "$d" '[{"op": "issue-edit", "repo": "acme/app", "issue": 61, "body": "mine"}]'
  full "$PL" "$d"
  eq "$RC/$(nwrites "$d")" "4/0" "[B] the target changed between the run's own rehearse and its step: the step refuses, rc 4, nothing written"
  eq "$(wq "$d" 'R["issues"]["61"]["body"]')" moved "[B] …the other writer's body stays"
  d=$(mkw); spec "$d" '[{"op": "issue-edit", "repo": "acme/app", "issue": 61, "body": "mine"}]'; eng "$PL" "$d" --spec spec.json; plan_to "$d" plan.txt
  python3 - "$d/world.json" <<'PY'
import json, sys
W = json.load(open(sys.argv[1])); W["repos"]["acme/app"]["issues"]["61"]["body"] = "moved"; json.dump(W, open(sys.argv[1], "w"))
PY
  eng "$PL" "$d" --spec spec.json --do 1 --expect-plan plan.txt; eq "$RC" 1 "[B] op 1 alone (no runner), the world moved: refused (rc 1)"
  eng "$PL" "$d" --spec spec.json
  hasnt "$OUT" "FAIL  journal:" "[B] …and no run is left open by the refused op 1"
  d=$(mkw 'W["faults"].update(swap_at_read=["repos/acme/app", 5], swap=[["acme/app", "repo", {"private": False, "visibility": "public"}]])')
  spec "$d" "[$CMT]"; full "$PL" "$d"
  eq "$RC/$(nwrites "$d")" "4/0" "[B] the repository made public before the step: refused inside the step, rc 4, nothing written"
  has "$OUT" "refuse-public" "[B] …named refuse-public"
}

fam_inject() {
  PL=$1; local d
  d=$(mkw); spec "$d" '[{"op": "issue-create", "repo": "acme/app", "title": "t $(touch pwned1) `touch pwned2`; touch pwned3", "labels": ["a`b;c"],
    "body": "$(touch pwned4) \"; touch pwned5 <!-- m-i -->", "marker": "<!-- m-i -->"}]'
  full "$PL" "$d"
  eq "$RC" 0 "[I] a title, a label and a body holding shell text: rc 0"
  eq "$(find "$d" "$TMP" -name 'pwned*' 2>/dev/null | wc -l | tr -d ' ')" 0 "[I] …nothing ran (no pwned file anywhere)"
  eq "$(wq "$d" 'R["issues"]["100"]["title"], R["issues"]["100"]["labels"]')" "('t \$(touch pwned1) \`touch pwned2\`; touch pwned3', ['a\`b;c'])" \
     "[I] …the title and the label arrived verbatim"
  eq "$(wq "$d" 'R["issues"]["100"]["body"]')" '$(touch pwned4) "; touch pwned5 <!-- m-i -->' "[I] …the body arrived verbatim"
}

# plan_to <dir> <file> — the op-plan lines of the engine's plan, as a signed plan file
plan_to() { printf '%s\n' "$OUT" | sed -n 's/^op-plan: //p' > "$1/$2"; }
fam_journal() {
  PL=$1; local d
  d=$(mkw); spec "$d" "[$CMT, {\"op\": \"issue-close\", \"repo\": \"acme/app\", \"issue\": 62, \"reason\": \"completed\"}]"
  python3 - "$d/world.json" "$d/spec.json" <<'PY'
import json, sys
W = json.load(open(sys.argv[1])); W["faults"]["append_after_write"] = [1, sys.argv[2]]; json.dump(W, open(sys.argv[1], "w"))
PY
  full "$PL" "$d"
  eq "$RC" 4 "[J] the spec edited after op 1: op 2 refuses, undo finds the run by the spec's path and retracts op 1 (rc 4)"
  has "$(wq "$d" 'R["comments"]["5000"]["body"]')" "Retracted" "[J] …the comment op 1 posted is retracted"
  eq "$(wq "$d" 'R["issues"]["62"]["state"]')" open "[J] …op 2 never wrote"
  d=$(mkw); spec "$d" "[$CMT]"
  python3 - "$d/world.json" "$d/spec.json" <<'PY'
import json, sys
W = json.load(open(sys.argv[1])); W["faults"]["append_after_write"] = [1, sys.argv[2]]; json.dump(W, open(sys.argv[1], "w"))
PY
  full "$PL" "$d"
  eq "$RC" 4 "[J] the spec edited after its last op: the post-check refuses to confirm, undo retracts (rc 4)"
  has "$(wq "$d" 'R["comments"]["5000"]["body"]')" "Retracted" "[J] …retracted"
  d=$(mkw); A="$d/a"; mkdir -p "$A" "$d/b"; mv "$d/world.json" "$A/world.json"; : > "$A/gh.log"; spec "$A" "[$CMT]"; cp "$A/spec.json" "$d/b/spec.json"
  # gwa <dir> <args...> — the engine from <dir>, on A's world and A's state home (one user, two copies of a spec)
  gwa() { local w=$1; shift; OUT=$(cd "$w" && cenv XDG_STATE_HOME="$A/state" FAKE_GH_STATE="$A/world.json" FAKE_GH_LOG="$A/gh.log" python3 -B "$PL/$G" "$@" 2>&1); RC=$?; }
  gwa "$A" --spec spec.json; plan_to "$A" plan.txt
  gwa "$A" --spec spec.json --do 1 --expect-plan plan.txt
  eq "$RC" 0 "[J] op 1 of run A (left open, as by an interrupt)"
  gwa "$d/b" --spec spec.json
  eq "$RC" 1 "[J] the same bytes at another path while A is open: rehearse refused (journal)"
  gwa "$d/b" --spec spec.json --undo-step 1
  eq "$(wq "$A" 'R["comments"]["5000"]["body"]')" "hello <!-- m-c -->" "[J] …and its undo does not touch A's comment"
  local P2; P2=$(mkw); spec "$P2" "[$CMT, {\"op\": \"issue-close\", \"repo\": \"acme/app\", \"issue\": 62, \"reason\": \"completed\"}]"
  eng "$PL" "$P2" --spec spec.json; plan_to "$P2" plan.txt
  { cat "$P2/plan.txt"; echo "gh-write 3/2 spec $(sha "$P2/spec.json") issue-close acme/app#61 reason completed"; } > "$P2/three.txt"
  eng "$PL" "$P2" --spec spec.json --do 1 --expect-plan three.txt
  eq "$RC" 1 "[J] a signed plan with more lines than the spec has ops: the step refuses (rc 1)"
  has "$OUT" "refuse-plan" "[J] …named refuse-plan"
  { sed -n 1p "$P2/plan.txt"; sed -n 2p "$P2/plan.txt" | sed "s/ spec [0-9a-f]* / spec $(printf '%064d' 0) /"; } > "$P2/other.txt"
  eng "$PL" "$P2" --spec spec.json --do 1 --expect-plan other.txt
  eq "$RC" 1 "[J] a signed plan whose other line names another spec's sha256: the step refuses (rc 1)"
  eq "$(nwrites "$P2")" 0 "[J] …those refused steps wrote nothing"
  bt "$PL" "$A" rehearse kit:gh-write --spec spec.json
  eq "$RC" 1 "[J] run A left open: a rehearse of its spec is refused (journal)"
  bt "$PL" "$A" mode auto; bt "$PL" "$A" rehearse kit:gh-write --spec spec.json --recover; local seal; seal=$(seal_of)
  eq "$RC" 0 "[J] --recover rehearses the undo of the open run: rc 0"
  has "$OUT" "PLAN gh-write recover 1/1 run " "[J] …one plan line per undo step"
  bt "$PL" "$A" sign --by coordinator-auto --seal "${seal:-none}" kit:gh-write --spec spec.json --recover
  bt "$PL" "$A" run kit:gh-write --spec spec.json --recover
  eq "$RC" 0 "[J] --recover runs it: rc 0"
  has "$(wq "$A" 'R["comments"]["5000"]["body"]')" "Retracted" "[J] …A's comment is retracted"
  bt "$PL" "$A" rehearse kit:gh-write --spec spec.json
  eq "$RC" 0 "[J] …and the spec rehearses again"
  bt "$PL" "$A" rehearse kit:gh-write --spec spec.json --recover
  eq "$RC" 1 "[J] --recover with no open run: rc 1, nothing to recover"
  # a run of three ops left open: one recovery undoes all three, under one signature
  local R3; R3=$(mkw); spec "$R3" "[$CMT, {\"op\": \"issue-edit\", \"repo\": \"acme/app\", \"issue\": 61, \"title\": \"T61\"}, {\"op\": \"issue-close\", \"repo\": \"acme/app\", \"issue\": 62, \"reason\": \"completed\"}]"
  eng "$PL" "$R3" --spec spec.json; plan_to "$R3" plan.txt
  for k in 1 2 3; do eng "$PL" "$R3" --spec spec.json --do "$k" --expect-plan plan.txt; done
  eq "$RC/$(nwrites "$R3")" "0/3" "[J] three ops of a run that is then left open (no post-check)"
  bt "$PL" "$R3" mode auto; bt "$PL" "$R3" rehearse kit:gh-write --spec spec.json --recover; seal=$(seal_of)
  eq "$(nplan)" 3 "[J] --recover of three ops: three plan lines"
  bt "$PL" "$R3" sign --by coordinator-auto --seal "${seal:-none}" kit:gh-write --spec spec.json --recover
  bt "$PL" "$R3" run kit:gh-write --spec spec.json --recover
  eq "$RC" 0 "[J] --recover of three ops runs every step under one signature: rc 0"
  eq "$(wq "$R3" '(R["issues"]["61"]["title"], R["issues"]["62"]["state"], R["comments"]["5000"]["body"][:9])')" "('Sixty-one', 'open', 'Retracted')" \
     "[J] …the title is back, the issue reopened, the comment retracted"
  # a recovery that must leave a state alone: it closes the run and tells the owner (rc 5); the spec is not blocked for good
  local RL; RL=$(mkw); spec "$RL" '[{"op": "issue-edit", "repo": "acme/app", "issue": 61, "body": "mine"}]'
  eng "$PL" "$RL" --spec spec.json; plan_to "$RL" plan.txt; eng "$PL" "$RL" --spec spec.json --do 1 --expect-plan plan.txt
  python3 - "$RL/world.json" <<'PY'
import json, sys
W = json.load(open(sys.argv[1])); W["repos"]["acme/app"]["issues"]["61"]["body"] = "a person's edit"; json.dump(W, open(sys.argv[1], "w"))
PY
  bt "$PL" "$RL" mode auto; bt "$PL" "$RL" rehearse kit:gh-write --spec spec.json --recover; seal=$(seal_of)
  bt "$PL" "$RL" sign --by coordinator-auto --seal "${seal:-none}" kit:gh-write --spec spec.json --recover
  bt "$PL" "$RL" run kit:gh-write --spec spec.json --recover
  eq "$RC" 5 "[J] a recovery that leaves a changed body alone: rc 5 (tell the owner)"
  eq "$(wq "$RL" 'R["issues"]["61"]["body"]')" "a person's edit" "[J] …the person's edit stays"
  eng "$PL" "$RL" --spec spec.json
  hasnt "$OUT" "FAIL  journal:" "[J] …and the run is closed: the spec is not blocked for good"
  # op 2 before op 1 finished (its write's outcome unknown): refused
  local RU; RU=$(mkw 'W["faults"]["land_then_fail"] = 1'); spec "$RU" "[$CMT, {\"op\": \"issue-close\", \"repo\": \"acme/app\", \"issue\": 62, \"reason\": \"completed\"}]"
  eng "$PL" "$RU" --spec spec.json; plan_to "$RU" plan.txt
  eng "$PL" "$RU" --spec spec.json --do 1 --expect-plan plan.txt; eng "$PL" "$RU" --spec spec.json --do 2 --expect-plan plan.txt
  eq "$RC/$(nwrites "$RU")" "1/1" "[J] op 2 while op 1's outcome is unknown: refused (rc 1), nothing more written"
  # the open journal's name is taken: op 1 refuses instead of writing over it
  local RX; RX=$(mkw); spec "$RX" "[$CMT]"; eng "$PL" "$RX" --spec spec.json; plan_to "$RX" plan.txt
  mkdir -p "$RX/state/vibemaestro/gh-write"
  printf '{"spec": "x", "paths": ["/elsewhere"], "state": "open", "run": "0", "entries": {}}' > "$RX/state/vibemaestro/gh-write/$(sha "$RX/spec.json").json"
  eng "$PL" "$RX" --spec spec.json --do 1 --expect-plan plan.txt
  eq "$RC/$(nwrites "$RX")" "1/0" "[J] the journal's name is held by another run: op 1 refuses (rc 1), nothing written"
  printf '{"spec": "x", "paths": ["/elsewhere"], "state": "done", "run": "old", "entries": {}}' > "$RX/state/vibemaestro/gh-write/$(sha "$RX/spec.json").json"
  eng "$PL" "$RX" --spec spec.json --do 1 --expect-plan plan.txt
  eq "$RC/$(nwrites "$RX")" "0/1" "[J] a closed run that never moved aside (a crash while closing): op 1 moves it aside and runs"
  [ -f "$RX/state/vibemaestro/gh-write/$(sha "$RX/spec.json").old.json" ] && ok "[J] …the closed run is kept under its archive name" \
    || bad "[J] …the closed run is kept under its archive name"
  # a process holding a journal while another one closed it and a new run took the name: it never writes over the new run
  local v; v=$(cenv XDG_STATE_HOME="$(fresh)" python3 - "$PL/gates" <<'PY'
import json, os, sys
sys.path.insert(0, sys.argv[1])
import gh_write as g
os.makedirs(g.journal_dir())
p = g.journal_file("a" * 64)
json.dump({"spec": "a" * 64, "paths": ["/x"], "state": "open", "run": "one", "entries": {}}, open(p, "w"))
j = [x for x in g.journals() if x["run"] == "one"][0]
json.dump({"spec": "a" * 64, "paths": ["/x"], "state": "open", "run": "two", "entries": {}}, open(p, "w"))
out = []
for f in (g.save_journal, lambda j: g.close_journal(j, "done")):
    try:
        f(j)
        out.append("WROTE")
    except g.Stop:
        out.append("refused")
print(" ".join(out), json.load(open(p))["run"])
PY
)
  eq "$v" "refused refused two" "[J] a journal whose file now holds another run: save and close both refuse, the new run's journal stays"
  # pruning keeps the newest closed runs, and never a run that is open under its archive name or left a state for the owner
  v=$(cenv XDG_STATE_HOME="$(fresh)" python3 - "$PL/gates" <<'PY'
import json, os, sys, time
sys.path.insert(0, sys.argv[1])
import gh_write as g
d = g.journal_dir()
os.makedirs(d)
def put(name, state, entries, age):
    p = os.path.join(d, name)
    json.dump({"spec": "b" * 64, "paths": ["/y"], "state": state, "run": name, "entries": entries}, open(p, "w"))
    os.utime(p, (time.time() - age, time.time() - age))
put("b.lost.json", "left", {"1": {"status": "left", "left": g.LOST}}, 9999)
put("b.stranded.json", "open", {}, 9999)
for k in range(g.ARCHIVED_KEPT + 5):
    put("b.done%03d.json" % k, "done", {}, k)
g.prune_archived()
names = os.listdir(d)
print(sum(n.startswith("b.done") for n in names), "b.lost.json" in names, "b.stranded.json" in names)
PY
)
  eq "$v" "100 True True" "[J] pruning keeps 100 closed runs and never a run left for the owner or open under its archive name"
}

# ── go prints one line; a spec written before this call is refused; a token that GET user refuses ─────────────
# age <file> <seconds> — the file's mtime set that many seconds back
age() { python3 -c 'import os, sys, time; t = time.time() - float(sys.argv[2]); os.utime(sys.argv[1], (t, t))' "$1" "$2"; }
# The world of [Y]: main at C0 (README.md), feature at HD (its draft pull request into main is number 8 of the world), topic at HD3 (none)
C0=$(printf '11%.0s' $(seq 20)); HD3=$(printf 'ef%.0s' $(seq 20)); T0=$(printf '70%.0s' $(seq 20))
# the base tree: README.md ("hi"), run.sh (executable), docs/a.md, a link and a submodule
PRW='R = W["repos"]["acme/app"]
R["trees"] = {"'"$T0"'": {"README.md": "aGk=", "run.sh": {"content": "ZWNobwo=", "mode": "100755"}, "docs/a.md": "YQo=",
                          "link": {"content": "UkVBRE1FLm1k", "mode": "120000"}, "sub": {"content": "", "mode": "160000"}}}
R["commits"] = {"'"$C0"'": {"tree": "'"$T0"'", "parents": []}, "'"$HD"'": {"tree": "'"$T0"'", "parents": ["'"$C0"'"]}, "'"$HD3"'": {"tree": "'"$T0"'", "parents": ["'"$C0"'"]}}
R["branches"] = {"main": "'"$C0"'", "feature": "'"$HD"'", "topic": "'"$HD3"'"}
R["issues"]["8"] = {"title": "Draft PR", "body": "draft", "state": "open", "user": "bot", "pr": True, "head": "'"$HD"'", "head_ref": "feature", "base_ref": "main", "draft": True}'
PRCR='{"op": "pr-create", "repo": "acme/app", "base": "main", "branch": "topic", "head": "'"$HD3"'", "title": "Topic", "draft": false, "body": "The topic.\n"}'
PRRD='{"op": "pr-ready", "repo": "acme/app", "pr": 8, "head": "'"$HD"'"}'
# fpr <dir> [content sha] — new.md in the case directory and the file-pr op that proposes it as docs/new.md
fpr() {
  printf 'hello\n' > "$1/new.md"
  FPR='{"op": "file-pr", "repo": "acme/app", "base": "main", "branch": "add-new", "path": "docs/new.md", "content_file": "new.md", "content_sha256": "'"${2:-$(sha "$1/new.md")}"'", "title": "Add docs/new.md", "draft": false, "body": "Adds one file."}'
}
# gitblob <file> — git's blob id of its bytes
gitblob() { python3 - "$1" <<'PY'
import hashlib, sys
d = open(sys.argv[1], "rb").read()
print(hashlib.sha1(b"blob %d\0" % len(d) + d).hexdigest())
PY
}
wset() { python3 - "$1/world.json" "$2" <<'PY'
import json, sys
W = json.load(open(sys.argv[1]))
R = W["repos"]["acme/app"]
exec(sys.argv[2])
json.dump(W, open(sys.argv[1], "w"))
PY
}

fam_prs() {
  PL=$1; local d seal
  refuse "[Y] a pr-create without a full head SHA" refuse-spec '[{"op": "pr-create", "repo": "acme/app", "base": "main", "branch": "topic", "head": "abc", "title": "t", "draft": false, "body": "b"}]'
  refuse "[Y] a pr-create from a branch with '..'" refuse-spec '[{"op": "pr-create", "repo": "acme/app", "base": "main", "branch": "a..b", "head": "'"$HD3"'", "title": "t", "draft": false, "body": "b"}]'
  refuse "[Y] a pr-create from a branch that starts with '.'" refuse-spec '[{"op": "pr-create", "repo": "acme/app", "base": "main", "branch": ".hidden", "head": "'"$HD3"'", "title": "t", "draft": false, "body": "b"}]'
  refuse "[Y] a pr-create from a branch with a component that starts with '.'" refuse-spec '[{"op": "pr-create", "repo": "acme/app", "base": "main", "branch": "a/.hidden", "head": "'"$HD3"'", "title": "t", "draft": false, "body": "b"}]'
  refuse "[Y] a pr-create from a branch into itself" refuse-spec '[{"op": "pr-create", "repo": "acme/app", "base": "topic", "branch": "topic", "head": "'"$HD3"'", "title": "t", "draft": false, "body": "b"}]'
  refuse "[Y] a pr-create whose draft is not a boolean" refuse-spec '[{"op": "pr-create", "repo": "acme/app", "base": "main", "branch": "topic", "head": "'"$HD3"'", "title": "t", "draft": "no", "body": "b"}]'
  refuse "[Y] a pr-create from another owner's fork (owner:branch)" refuse-spec '[{"op": "pr-create", "repo": "acme/app", "base": "main", "branch": "evil:topic", "head": "'"$HD3"'", "title": "t", "draft": false, "body": "b"}]'
  for b in HEAD FETCH_HEAD AUTO_MERGE refs/heads/main heads/main tags/v1 remotes/origin/x "$HD" "$(printf 'A%.0s' $(seq 40))"; do
    refuse "[Y] a pr-create from a branch named $b, which git reads as something else" refuse-spec '[{"op": "pr-create", "repo": "acme/app", "base": "main", "branch": "'"$b"'", "head": "'"$HD3"'", "title": "t", "draft": false, "body": "b"}]'
  done
  OUT=$(cd "$PL/gates" && python3 -B -c 'import gh_write as g
class W:
    def read(self, path, pages=False):
        return None
try:
    g.tree_drift(W(), "a/b", "ab" * 20, "cd" * 20, "x.md"); print("no error")
except g.G.Infra:
    print("infra")
print(g.branch_ok("OVERHEAD"), g.branch_ok("AHEAD"))' 2>&1)
  eq "$OUT" "infra
True True" "[Y] tree_drift fails closed on a commit it cannot read; OVERHEAD and AHEAD are ordinary branch names"
  refuse "[Y] a pr-ready with a body" refuse-unknown-key '[{"op": "pr-ready", "repo": "acme/app", "pr": 8, "head": "'"$HD"'", "body": "x"}]'
  d=$(mkw "$PRW"); fpr "$d"; spec "$d" "[${FPR/docs\/new.md/.github/workflows/ci.yml}]"; eng "$PL" "$d" --spec spec.json
  eq "$RC:$(nwrites "$d")" "64:0" "[Y] a file-pr of a workflow file: rc 64, no write call"
  has "$OUT" "REFUSE refuse-workflow:" "[Y] …named refuse-workflow"
  d=$(mkw "$PRW"); fpr "$d"; spec "$d" "[${FPR/docs\/new.md/docs\/..\/x.md}]"; eng "$PL" "$d" --spec spec.json
  eq "$RC:$(nwrites "$d")" "64:0" "[Y] a file-pr path with a '..' segment: rc 64, no write call"
  d=$(mkw "$PRW"); fpr "$d"; spec "$d" "[${FPR/\"new.md\"/\"..\/world.json\"}]"; eng "$PL" "$d" --spec spec.json
  eq "$RC:$(nwrites "$d")" "64:0" "[Y] a file-pr content_file outside the spec's directory: rc 64, no write call"
  alone "[Y] a pr-create whose branch moved" head "$PRW"'
R["branches"]["topic"] = "'"$HD2"'"' "[$PRCR]"
  alone "[Y] a pr-create from a branch that is not there" head "$PRW"'
del R["branches"]["topic"]' "[$PRCR]"
  alone "[Y] a pr-create while topic -> main is open" pr-absent "$PRW"'
R["issues"]["9"] = {"title": "x", "body": "x", "state": "open", "user": "bot", "pr": True, "head": "'"$HD3"'", "head_ref": "topic", "base_ref": "main"}' "[$PRCR]"
  alone "[Y] a pr-ready whose head moved" head "$PRW"'
R["issues"]["8"]["head"] = "'"$HD2"'"' "[$PRRD]"
  alone "[Y] a pr-ready of a pull request that is not a draft" draft "$PRW"'
R["issues"]["8"]["draft"] = False' "[$PRRD]"
  alone "[Y] a pr-ready of a closed pull request" open "$PRW"'
R["issues"]["8"]["state"] = "closed"' "[$PRRD]"
  d=$(mkw "$PRW"'
R["branches"]["add-new"] = "'"$C0"'"'); fpr "$d"; spec "$d" "[$FPR]"; eng "$PL" "$d" --spec spec.json
  eq "$RC:$(nfail):$(nwrites "$d")" "1:1:0" "[Y] a file-pr onto a branch that exists: rc 1, one failed condition, no write"
  has "$OUT" "FAIL  branch-absent:" "[Y] …named branch-absent"
  for k in "docs:a directory" "link:a link" "sub:a submodule" "README.md/x:a path under a file"; do
    d=$(mkw "$PRW"); fpr "$d"; spec "$d" "[${FPR/docs\/new.md/${k%%:*}}]"; eng "$PL" "$d" --spec spec.json
    eq "$RC:$(nfail):$(nwrites "$d")" "1:1:0" "[Y] a file-pr onto ${k#*:}: rc 1, one failed condition, no write"
    has "$OUT" "FAIL  path:" "[Y] …named path (${k#*:})"
  done
  d=$(mkw "$PRW"); printf 'hi' > "$d/same"; spec "$d" "[${FPR/docs\/new.md/README.md}]"
  python3 - "$d/spec.json" "$(sha "$d/same")" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); s["ops"][0].update(content_file="same", content_sha256=sys.argv[2]); json.dump(s, open(sys.argv[1], "w"))
PY
  eng "$PL" "$d" --spec spec.json
  eq "$RC:$(nfail)" "1:1" "[Y] a file-pr whose content equals the file it would replace: rc 1, one failed condition"
  has "$OUT" "FAIL  changes:" "[Y] …named changes"
  refuse "[Y] a file-pr onto a branch with a component ending in .lock" refuse-spec '[{"op": "file-pr", "repo": "acme/app", "base": "main", "branch": "fix.lock/x", "path": "a.md", "content_file": "a", "content_sha256": "'"$(printf '0%.0s' $(seq 64))"'", "title": "t", "draft": false, "body": "b"}]'
  d=$(mkw "$PRW"); fpr "$d"; spec "$d" "[${FPR/docs\/new.md/README.md}]"; eng "$PL" "$d" --spec spec.json
  printf 'hi' > "$d/hi"
  has "$OUT" "path \"README.md\" replaces blob $(gitblob "$d/hi") mode 100644" "[Y] a file-pr of a file the base holds plans a replace that names the blob it replaces"
  d=$(mkw "$PRW"); fpr "$d" "$(printf '0%.0s' $(seq 64))"; spec "$d" "[$FPR]"; eng "$PL" "$d" --spec spec.json
  eq "$RC:$(nfail)" "1:1" "[Y] a file-pr whose content does not match its pin: rc 1, one failed condition"
  has "$OUT" "FAIL  pinned:" "[Y] …named pinned"
  d=$(mkw "$PRW"'
W["repos"]["acme/pub"].update(branches={"main": "'"$C0"'", "topic": "'"$HD3"'"}, commits=R["commits"], trees=R["trees"])')
  spec "$d" "[${PRCR/acme\/app/acme/pub}]"; eng "$PL" "$d" --spec spec.json
  eq "$RC:$(nwrites "$d")" "1:0" "[Y] a pr-create in a public repository: rc 1, no write call"
  has "$OUT" "FAIL  private: refuse-public" "[Y] …named refuse-public"
  OUT=$(cd "$PL/gates" && python3 -B -c 'import gh_write as g
print(g.allowed("POST", "repos/a/b/git/refs", {"ref": "refs/tags/v1", "sha": "x"}), g.allowed("POST", "repos/a/b/git/refs", {"ref": "refs/heads/x", "sha": "x"}),
      g.allowed("PATCH", "repos/a/b/git/refs/heads/x", {"sha": "x", "force": True}), g.allowed("PUT", "repos/a/b/contents/x", {"content": "x"}),
      g.allowed("POST", "graphql", {"query": "mutation($id:ID!){mergePullRequest(input:{pullRequestId:$id}){clientMutationId}}", "variables": {"id": "x"}}),
      g.allowed("POST", "graphql", {"query": g.READY_MUTATION, "variables": {"id": "x"}}))' 2>&1)
  eq "$OUT" "False True False False False True" "[Y] the call allowlist: a tag ref, a ref move, a PUT and another mutation refused; a branch ref and the ready mutation allowed"
  OUT=$(cd "$PL/gates" && python3 -B -c 'import gh_write as g
nr = "1+bot@" + g.NOREPLY_HOST
one = lambda **k: {"tree": [dict({"path": "a.md", "mode": "100644", "type": "blob", "sha": "ab" * 20}, **k)], "base_tree": "cd" * 20}
print(g.allowed("POST", "repos/a/b/pulls", {"title": "t", "body": "b", "head": "evil:topic", "base": "main"}),
      g.allowed("POST", "repos/a/b/git/refs", {"ref": "refs/heads/../tags/v1", "sha": "x"}),
      g.allowed("POST", "repos/a/b/git/trees", one(path=".github/workflows/x.yml")),
      g.allowed("POST", "repos/a/b/git/trees", one(mode="120000")),
      g.allowed("POST", "repos/a/b/git/commits", {"message": "m", "tree": "t", "parents": ["p"], "author": {"name": "n", "email": "n"}, "committer": {"name": "n", "email": nr}}),
      g.allowed("POST", "repos/a/b/git/trees", one()),
      g.allowed("POST", "repos/a/b/git/commits", {"message": "m", "tree": "t", "parents": ["p"], "author": {"name": "n", "email": nr}, "committer": {"name": "n", "email": nr}}))' 2>&1)
  eq "$OUT" "False False False False False True True" "[Y] the call allowlist checks values too: a fork head, a ref with '..', a workflow path, a link mode, an author who is not a noreply address refused; one regular file and a noreply commit allowed"
  OUT=$(cd "$PL/gates" && python3 -B -c 'import gh_write as g
e = {"path": "a.md", "mode": "100644", "type": "blob", "sha": "ab" * 20}
print(g.allowed("POST", "repos/a/b/git/trees", {"tree": [e]}),
      g.allowed("POST", "repos/a/b/git/trees", {"base_tree": "cd" * 20, "tree": [dict(e, sha=None)]}),
      g.allowed("POST", "repos/a/b/git/trees", {"base_tree": "cd" * 20, "tree": [{"path": "a.md", "mode": "100644", "type": "blob", "content": "x"}]}),
      g.allowed("POST", "repos/a/b/git/trees", {"base_tree": "cd" * 20, "tree": [e]}))' 2>&1)
  eq "$OUT" "False False False True" "[Y] the call allowlist refuses a tree without base_tree, an entry that deletes (sha null) and an inline one; a base tree and one blob pass"
  d=$(mkw "$PRW"); spec "$d" "[$PRCR]"; eng "$PL" "$d" --spec spec.json
  has "$OUT" "pr-create acme/app base main branch topic at $HD3 ready title \"Topic\"" "[Y] the pr-create plan line names base, branch, head and ready"
  d=$(mkw "$PRW"); spec "$d" "[$PRCR]"; full "$PL" "$d"
  eq "$RC" 0 "[Y] a pr-create run: rc 0"
  eq "$(writes "$d" | tr '\n' ';')" "POST repos/acme/app/pulls;" "[Y] …one POST of the pull request"
  eq "$(wq "$d" 'R["issues"]["100"]["head"] + " " + str(R["issues"]["100"]["draft"]) + " " + R["issues"]["100"]["body"]')" "$HD3 False The topic." "[Y] …at the pinned head, ready, its body with one final newline removed"
  d=$(mkw "$PRW"); spec "$d" "[$PRRD]"; full "$PL" "$d"
  eq "$RC" 0 "[Y] a pr-ready run: rc 0"
  eq "$(writes "$d" | tr '\n' ';')" "POST graphql;" "[Y] …one GraphQL mutation"
  eq "$(wq "$d" 'R["issues"]["8"]["draft"]')" False "[Y] …the pull request is ready"
  d=$(mkw "$PRW"); fpr "$d"; spec "$d" "[$FPR]"; full "$PL" "$d"; NR=users.noreply.github.com
  eq "$RC" 0 "[Y] a file-pr run: rc 0"
  eq "$(writes "$d" | tr '\n' ';')" "POST repos/acme/app/git/blobs;POST repos/acme/app/git/trees;POST repos/acme/app/git/commits;POST repos/acme/app/git/refs;POST repos/acme/app/pulls;" "[Y] …blob, tree, commit, the branch ref, the pull request"
  eq "$(wq "$d" 'R["commits"][R["branches"]["add-new"]]["parents"] == ["'"$C0"'"] and R["issues"]["100"]["head"] == R["branches"]["add-new"]')" True "[Y] …one commit on the base tip, the pull request at it"
  eq "$(wq "$d" 'R["commits"][R["branches"]["add-new"]]["author"]["email"] + " " + R["commits"][R["branches"]["add-new"]]["committer"]["email"]')" "4242+bot@$NR 4242+bot@$NR" "[Y] …author and committer the viewer's noreply address"
  eq "$(wq "$d" 'R["trees"][R["commits"][R["branches"]["add-new"]]["tree"]]["docs/new.md"]')" "aGVsbG8K" "[Y] …the file holds the pinned bytes"
  d=$(mkw "$PRW"); fpr "$d"; spec "$d" "[${FPR/docs\/new.md/run.sh}]"; full "$PL" "$d"
  eq "$RC" 0 "[Y] a file-pr that replaces an executable file: rc 0"
  eq "$(wq "$d" 'R["trees"][R["commits"][R["branches"]["add-new"]]["tree"]]["run.sh"]')" "{'content': 'aGVsbG8K', 'mode': '100755'}" "[Y] …the new bytes, and the file keeps mode 100755"
  eq "$(wq "$d" 'sorted(R["trees"][R["commits"][R["branches"]["add-new"]]["tree"]])')" "['README.md', 'docs/a.md', 'link', 'run.sh', 'sub']" "[Y] …and every other path of the base stays"
  d=$(mkw "$PRW"'
W["faults"]["drop_base_tree"] = True'); fpr "$d"; spec "$d" "[$FPR]"; full "$PL" "$d"
  eq "$RC" 5 "[Y] a commit whose tree lost the rest of the base: the post-check fails, undo closes the PR and names the branch (rc 5)"
  has "$OUT" "the commit also changes" "[Y] …the post-check names what else the commit changes"
  d=$(mkw "$PRW"'
W["faults"]["bad_blob"] = True'); fpr "$d"; spec "$d" "[$FPR]"; full "$PL" "$d"
  eq "$RC" 4 "[Y] a blob GitHub answers with another id than git's id of the pinned bytes: the run fails, undone (rc 4)"
  eq "$(wq "$d" '"add-new" in R["branches"]'):$(writes "$d" | grep -c 'git/refs\|pulls')" "False:0" "[Y] …no branch, no pull request"
  d=$(mkw "$PRW"'
W["faults"].update(land_then_fail=1, lag=1)'); spec "$d" "[$PRCR]"; full "$PL" "$d"
  eq "$RC:$(wq "$d" 'R["issues"]["100"]["state"]')" "4:closed" "[Y] a lost pr-create answer while the list lags once: the undo reads it again and closes the PR (rc 4)"
  d=$(mkw "$PRW"'
W["faults"].update(land_then_fail=5, lag=True)'); fpr "$d"; spec "$d" "[$FPR]"; full "$PL" "$d"
  eq "$RC" 5 "[Y] a lost file-pr PR answer while the list lags: rc 5"
  has "$OUT" "left for the owner" "[Y] …left for the owner, not reported as a PR never opened"
  d=$(mkw "$PRW"'
W["faults"]["land_then_fail"] = 4'); fpr "$d"; spec "$d" "[$FPR]"; full "$PL" "$d"
  eq "$RC" 5 "[Y] a file-pr whose branch-ref answer was lost: rc 5 for the branch it leaves"
  has "$OUT" "no pull request was opened; branch add-new of acme/app stays" "[Y] …it says no pull request was opened (the PR POST was never sent)"
  d=$(mkw "$PRW"'
W["faults"]["fail_write"] = 5'); fpr "$d"; spec "$d" "[$FPR]"; full "$PL" "$d"
  eq "$RC" 5 "[Y] a file-pr whose PR GitHub refused: rc 5 for the branch it leaves"
  has "$OUT" "no pull request was opened; branch add-new of acme/app stays" "[Y] …and it says no pull request was opened"
  d=$(mkw "$PRW"'
R["issues"]["9"] = {"title": "old", "body": "old", "state": "closed", "merged": True, "user": "bot", "pr": True, "head": "'"$HD2"'", "head_ref": "topic", "base_ref": "main"}
W["faults"].update(land_then_fail=1)'); spec "$d" "[$PRCR]"; full "$PL" "$d"
  eq "$RC" 4 "[Y] a pr-create whose answer was lost, beside an older merged PR from the same branch: undone (rc 4)"
  eq "$(wq "$d" 'R["issues"]["100"]["state"] + " " + R["issues"]["9"]["state"]')" "closed closed" "[Y] …the run's own PR is closed, found by its head; the old one is left as it was"
  d=$(mkw "$PRW"); fpr "$d"; spec "$d" "[$FPR]"
  bt "$PL" "$d" mode auto; bt "$PL" "$d" rehearse kit:gh-write --spec spec.json; seal=$(seal_of)
  bt "$PL" "$d" sign --by coordinator-auto --seal "${seal:-none}" kit:gh-write --spec spec.json
  wset "$d" 'R["commits"]["'"$HD2"'"] = {"tree": "'"$T0"'", "parents": ["'"$C0"'"]}; R["branches"]["main"] = "'"$HD2"'"'
  bt "$PL" "$d" run kit:gh-write --spec spec.json
  ne "$RC" 0 "[Y] a file-pr whose base moved after signing: the run fails"
  eq "$(wq "$d" '"add-new" in R["branches"]'):$(nwrites "$d")" "False:0" "[Y] …no branch, no write call (same file)"
  d=$(mkw "$PRW"); fpr "$d"; spec "$d" "[${FPR/docs\/new.md/README.md}]"
  bt "$PL" "$d" mode auto; bt "$PL" "$d" rehearse kit:gh-write --spec spec.json; seal=$(seal_of)
  bt "$PL" "$d" sign --by coordinator-auto --seal "${seal:-none}" kit:gh-write --spec spec.json
  T1=$(printf '71%.0s' $(seq 20))
  wset "$d" 'R["trees"]["'"$T1"'"] = dict(R["trees"]["'"$T0"'"], **{"README.md": "Ynll"}); R["commits"]["'"$C0"'"]["tree"] = "'"$T1"'"'
  bt "$PL" "$d" run kit:gh-write --spec spec.json
  eq "$RC:$(nwrites "$d")" "3:0" "[Y] a replace whose file changed under the same base tip (only the blob pin differs): refused, no write"
  eq "$(wq "$d" '"add-new" in R["branches"]'):$(nwrites "$d")" "False:0" "[Y] …no branch, no write call"
  d=$(mkw "$PRW"'
W["faults"]["fail_write"] = 2'); spec "$d" "[$PRCR, $NEW]"; full "$PL" "$d"
  eq "$RC" 4 "[Y] a create that fails after a pr-create: undo closes the pull request (rc 4)"
  eq "$(wq "$d" 'R["issues"]["100"]["state"]')" closed "[Y] …the pull request is closed"
  d=$(mkw "$PRW"'
W["faults"].update(fail_write=2, swap_after_write=1, swap=[["acme/app", "issues", "100", {"head": "'"$HD2"'"}]])'); spec "$d" "[$PRCR, $NEW]"; full "$PL" "$d"
  eq "$RC" 5 "[Y] a pull request someone pushed to after the run opened it: not closed, rc 5"
  eq "$(wq "$d" 'R["issues"]["100"]["state"]')" open "[Y] …it stays open"
  d=$(mkw "$PRW"'
W["faults"].update(swap_after_write=1, swap=[["acme/app", "issues", "8", {"head": "'"$HD2"'"}]])'); spec "$d" "[$PRRD]"; full "$PL" "$d"
  eq "$RC" 5 "[Y] a pull request that moved right after pr-ready marked it: post-check fails, undo leaves it alone (rc 5)"
  eq "$(wq "$d" 'R["issues"]["8"]["draft"]')" False "[Y] …it is not turned back into a draft under the new head"
  d=$(mkw "$PRW"'
W["faults"]["fail_write"] = 2'); spec "$d" "[$PRRD, $NEW]"; full "$PL" "$d"
  eq "$RC" 4 "[Y] a create that fails after a pr-ready: undo makes it a draft again (rc 4)"
  eq "$(wq "$d" 'R["issues"]["8"]["draft"]')" True "[Y] …the pull request is a draft again"
  d=$(mkw "$PRW"'
W["faults"]["fail_write"] = 6'); fpr "$d"; spec "$d" "[$FPR, $NEW]"; full "$PL" "$d"
  eq "$RC" 5 "[Y] a create that fails after a file-pr: undo closes its pull request, the branch it cannot delete makes it rc 5"
  eq "$(wq "$d" 'R["issues"]["100"]["state"] + " " + str("add-new" in R["branches"])')" "closed True" "[Y] …the pull request is closed, the branch stays"
  has "$OUT" "branch add-new of acme/app stays" "[Y] …and the undo names the branch it leaves"
  eq "$(grep -c '"method": "DELETE"' "$d/gh.log")" 0 "[Y] …no DELETE call"
  wset "$d" 'del R["branches"]["add-new"]'; bt "$PL" "$d" rehearse kit:gh-write --spec spec.json --recover
  has "$OUT" "close pull request acme/app#100" "[Y] …once the owner deleted the branch, --recover plans the step again"
  seal=$(seal_of); bt "$PL" "$d" sign --by coordinator-auto --seal "${seal:-none}" kit:gh-write --spec spec.json --recover
  bt "$PL" "$d" run kit:gh-write --spec spec.json --recover
  eq "$RC" 0 "[Y] …and the recovery holds (rc 0)"
}

fam_cost() {
  PL=$1; local d cmd
  d=$(mkw)
  OUT=$(cd "$d" && FAKE_GH_STATE="$d/world.json" FAKE_GH_LOG="$d/gh.log" "$GHB/gh" api user 2>&1); RC=$?
  eq "$RC" 1 "[C6] control: the fake answers GET user with an error"; has "$OUT" "HTTP 403" "[C6] …HTTP 403, as for an app installation token"
  : > "$d/gh.log"; spec "$d" "[$CMT]"; bt "$PL" "$d" mode auto; bt "$PL" "$d" go kit:gh-write --spec spec.json
  eq "$RC" 0 "[C6] go kit:gh-write with that token: rc 0"
  eq "$(wq "$d" 'R["comments"]["5000"]["body"]')" "hello <!-- m-c -->" "[C6] …the comment landed"
  eq "$(grep -c '"path": "user"' "$d/gh.log")" 0 "[C6] …GET user is never called"
  ne "$(grep -c '"path": "graphql"' "$d/gh.log")" 0 "[C6] …the login comes from the GraphQL read"
  eq "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" 1 "[C1] …go prints one line"
  case "$OUT" in "go: ok — 1 write — $d/state/vibemaestro/baton/runs/"*.log) ok "[C1] …'go: ok — 1 write — <run log>'";;
    *) bad "[C1] …'go: ok — 1 write — <run log>' ($OUT)";; esac
  d=$(mkw); spec "$d" "[$CMT]"; age "$d/spec.json" 600; bt "$PL" "$d" mode auto; bt "$PL" "$d" go kit:gh-write --spec spec.json
  eq "$RC:$(nwrites "$d")" "1:0" "[C2] a spec last written 600 s ago: rc 1, no write call"
  has "$OUT" "the --spec file spec.json was last written" "[C2] …it names the spec file"
  cmd=$(printf '%s\n' "$OUT" | sed -n 's/^  To run these very bytes again, after reading the sha256 and Purpose above: //p')
  has "$cmd" "go --reuse kit:gh-write --spec spec.json" "[C2] …and prints the --reuse command"
  bt "$PL" "$d" go --reuse kit:gh-write --spec spec.json
  eq "$RC:$(nwrites "$d")" "0:1" "[C2] go --reuse runs it: one write"
  d=$(mkw); spec "$d" "[$CMT]"; age "$d/spec.json" 600; bt "$PL" "$d" mode auto; bt "$PL" "$d" rehearse kit:gh-write --spec spec.json
  eq "$RC" 0 "[C2] the separate commands do not look at the spec's age (rehearse: rc 0)"
}

FAMILIES="fam_journal fam_spec fam_conditions fam_closed_ok fam_rehearse fam_run fam_closec fam_prclose fam_prs fam_lag fam_newline fam_fence fam_trap4 fam_ref fam_undo fam_seal fam_inject fam_cost"
PL0="$TMP/plugin-real"; mk_plugin_copy "$PL0"
for f in $FAMILIES; do echo "-- $f"; "$f" "$PL0"; done

echo "== planted breaks: each family must go red on a plugin copy with one break =="
BRK() {  # BRK <label> <family> <needle> <file under the plugin> <old> <new>
  local d="$TMP/break-$1"; mk_plugin_copy "$d"
  mutate "$d/$4" "$5" "$6" && expect_red "$1" "$2" "$d" "$3"
}
B=batons/gh-write.sh
BRK viewer-from-user fam_cost '[C6] go kit:gh-write with that token: rc 0' $G '            u = api("POST", "graphql", {"query": VIEWER_QUERY})' '            u = {"data": {"viewer": get("user")}}'
BRK spec-age-unchecked fam_cost '[C2] a spec last written 600 s ago: rc 1, no write call' scripts/baton.py 'KIT_INPUTS = {"gh-write": "--spec"}' 'KIT_INPUTS = {}'
BRK id-from-list fam_lag '[L] …the comment went to the created issue' $G \
    '        num = res.get("number") if isinstance(res, dict) else None' \
    '        num = max([x["number"] for x in get("repos/%s/issues?state=all&per_page=100" % op.repo, pages=True)] or [0])'
BRK compare-stripped fam_newline '[N] GitHub stores one newline more' $G \
    '    a, b = live.encode("utf-8"), want.encode("utf-8")' '    a, b = live.rstrip("\n").encode("utf-8"), want.rstrip("\n").encode("utf-8")'
BRK newline-kept fam_newline '[N] …posted with its one final newline removed' $G \
    '    return text[:-1] if text.endswith("\n") else text' '    return text'
BRK allowlist-open fam_spec '[S] the call allowlist refuses' $G '            return isinstance(payload, dict) and bool(payload) and set(payload) <= keys and values_ok(path, payload)
    return False' '            return isinstance(payload, dict) and bool(payload) and set(payload) <= keys and values_ok(path, payload)
    return True'
BRK public-allowed fam_conditions '[P] a public repository: rc 1' $G \
    '            self.cond("private", is_private(r),' '            self.cond("private", True,'
BRK public-unchecked-at-run fam_seal '[B] the repository made public before the step' $G \
    '        for repo in sorted(set(op.repo for op in sp.ops if self.only is None or op.i == self.only)):' \
    '        for repo in sorted(set(op.repo for op in sp.ops if self.only is None)):'
BRK pin-unchecked fam_conditions '[P] a body_file that does not match its pin' $G '            self.cond("pinned", pin == actual,' '            self.cond("pinned", True,'
BRK prclose-head-unchecked fam_prclose '[W] a pr-close whose head moved: rc 1' $G '            self.cond("head", live == op.head,' '            self.cond("head", True,'
BRK prclose-undo-over-other-close fam_prclose '[W] a pull request someone else closed after the run' $G '        if who != w.viewer():' '        if False:'
BRK prclose-undo-over-merge fam_prclose '[W] a pull request merged after the run closed it' $G '        if obj.get("merged"):' '        if False:'
BRK signed-plan-ignored fam_seal '[B] the target changed between' $G '    if p.lines[i] != lines[i - 1]:' '    if False:'
BRK undo-ownership-unchecked fam_undo '[U] a body someone changed after the run' $G '        if not mine:' '        if False:'
BRK retract-unchecked fam_undo '[U] a new comment someone edited after the run' $G '        if live != e["posted"]:
            return "comment %d changed since the run: left alone" % cid' '        if False:
            return ""'
BRK delete-kind-allowed fam_spec '[S] an op of kind issue-delete: named refuse-delete' $G '        if "delete" in low or "remove" in low:' '        if False:'
BRK repo-create-allowed fam_spec '[S] an op of kind repo-create: named refuse-repo-create' $G '        if re.search(r"repo", low) and "create" in low:' '        if False:'
BRK unknown-key-allowed fam_spec '[S] a deletion slipped in as a key: rc 64' $G '        if extra:' '        if False:'
BRK fences-unchecked fam_fence '[F] trap 3' $G '    return fence is not None' '    return False'
BRK journal-unchecked fam_conditions '[P] an unfinished run of the same spec' $G \
    '            self.cond("journal", not runs and not lost,' '            self.cond("journal", True,'
BRK close-comment-edited-unchecked fam_closec '[C] a comment someone edited after the run: rc 5' $G '    if live not in (None, RETRACTED, e["comment_posted"]):' '    if False:'
BRK close-reason-unchecked fam_closec '[C] an issue closed again for another reason: rc 5' $G '    if sent and obj.get("state") == "closed" and obj.get("state_reason") != e["reason"]:' '    if False:'
BRK close-comment-not-posted fam_closec '[C] …the comment is posted before the close, two write calls' $G '    if op.kind == "issue-close" and text is not None:' '    if False:'
BRK close-marker-unchecked fam_closec '[C] a marker already on a comment of the target: rc 1' $G '            if op.template is not None:
                self.marker_absent(op, tag, num)' '            if False:
                self.marker_absent(op, tag, num)'
BRK close-rejected-forgets-comment fam_closec '[C] …the comment that landed is retracted' $G '        if commented:' '        if False:'
BRK close-digest-dropped fam_closec "[C] …the plan line names the comment's digest" $G '" comment %s" % digest if digest else ""' '""'
BRK close-reopens-unsent fam_closec '[C] a comment landed, its answer lost, a person closed the issue: the undo does not reopen it' $G '    if sent and obj.get("state") == "closed":' '    if obj.get("state") == "closed":'
BRK close-refused-still-sent fam_closec "[C] a close GitHub refused, then a person's close: the undo does not reopen it" $G 'e["close_sent"] = False' 'pass'
BRK close-comment-unread fam_closec '[C] a comment GitHub stores with one newline more: the post-check names it' $G '                        problems.extend(close_comment_problems(w, e))' '                        pass'
BRK close-undo-reopens-only fam_closec '[C] …the comment is retracted by an edit' $G '    if live == e["comment_posted"]:
        api("PATCH", "repos/%s/issues/comments/%d" % (repo, cid), {"body": RETRACTED})' '    if False:
        pass'
BRK marker-unchecked fam_conditions '[P] a comment whose marker a comment on the target already holds: rc 1' $G \
    '        hit = [x.get("id") for x in (cs or []) if op.marker in body_of(x)]' '        hit = []'
BRK author-unchecked fam_conditions "[P] an edit of another author's comment: rc 1" $G '            self.cond("author", login == viewer,' '            self.cond("author", True,'
BRK closed-always-ok fam_closed_ok '[K5] the same comment without closed_ok' $G \
    'self.cond("open", state == "open" or closed_ok,' 'self.cond("open", True,'
BRK closed-ok-line-silent fam_closed_ok '[K2] …the plan line says' $G '"on a closed target (closed_ok) " if closed_ok else ""' '""'
BRK closed-ok-any-op fam_closed_ok '[K8] closed_ok on an issue-edit' $G \
    'allowed_keys = {"op", "repo"} | req | opt |' 'allowed_keys = {"op", "repo", "closed_ok"} | req | opt |'
BRK closed-ok-any-type fam_closed_ok '[K11] closed_ok that is not a boolean' $G 'if not isinstance(self.closed_ok, bool):' 'if False:'
BRK extra-plan-line fam_rehearse '[R] rehearse a two-op spec' $B '  if [ "$i" -eq 0 ]; then' '  write "gh-write extra" true
  if [ "$i" -eq 0 ]; then'
BRK postcheck-body-skipped fam_newline '[N] GitHub stores one newline more' $G \
    '                    if "posted" in e:' '                    if False:'
BRK plan-count-unchecked fam_journal '[J] a signed plan with more lines' $G '    if len(lines) != n:' '    if False:'
BRK plan-prefix-unchecked fam_journal "[J] a signed plan whose other line names another spec's sha256" $G '        if not ln.startswith(prefix(k)):' '        if False:'
BRK spec-change-unseen fam_journal '[J] the spec edited after its last op' $G '    if spec_sha_now(spec_path) != j["spec"]:' '    if False:'
BRK run-by-current-bytes fam_journal '[J] …the comment op 1 posted is retracted' $G '    runs = open_runs(path=path)' '    runs = open_runs(sha=spec_sha_now(path))'
BRK comment-issue-unchecked fam_run '[M] a comment the post-check reads on another issue' $G \
    '                    if k == "issue-comment" and not same_repo(on, "%s/issues/%d" % (repo, e["number"])):' '                    if False:'
BRK repo-case-sensitive fam_run '[M] a spec that spells the repository in another case' $G '    return a.lower() == b.lower()' '    return a == b'
BRK close-reason-unchecked fam_undo '[U] an issue closed by the run, then closed again' $G '    if obj.get("state_reason") != e["reason"]:' '    if False:'
BRK marker-twice-unchecked fam_undo '[U] …and when two issues hold the marker' $G '            if len(hits) > 1:
                return "%d issues hold the marker: left alone" % len(hits)' '            if False:
                return ""'
BRK lost-is-untouched fam_undo "[U] a create that landed, an answer lost, a list that lags" $G '            if not hits:
                return LOST
            num' '            if not hits:
                return "untouched"
            num'
BRK not-pr-unchecked fam_conditions '[P] an issue-close of a pull request: rc 1' $G '            pr = obj.get("pull_request") is not None' '            pr = False'
BRK internal-allowed fam_conditions '[P] an internal repository' $G 'r.get("visibility") not in ("public", "internal")' 'r.get("visibility") not in ("public",)'
BRK link-escape fam_spec "[S] a body_file that is a link leading outside" $G '        if os.path.commonpath([real, root]) != root:' '        if False:'
BRK foreign-marker fam_spec "[S] one op's marker in another op's body" $G \
    '                if other is not op and op.marker is not None and other.template is not None and op.marker in other.template:' '                if False:'
BRK marker-kept-on-undo fam_undo '[U] …after that undo the same spec rehearses again' $G '            payload["body"] = e["posted"].replace(e["marker"], "")' '            pass  #'
BRK rejected-run-left-open fam_undo '[U] …and the run is closed: the spec rehearses again' $G '    if not pending_undo(j):  ' '    if False:  '
BRK id-dollar-anchor fam_spec '[S] an id with a trailing newline' $G 'ID_RE.fullmatch(self.id)' 're.match(r"^[a-z][a-z0-9-]{0,31}$", self.id)'
BRK unfinished-unchecked fam_journal "[J] op 2 while op 1's outcome is unknown" $G '        if unfinished:' '        if False:'
BRK journal-overwritten fam_journal "[J] the journal's name is held by another run" $G '        os.link(tmp, p)' '        shutil.copyfile(tmp, p)'
BRK recover-steps-unfrozen fam_journal '[J] --recover of three ops runs every step' $G '    frozen = j.get("recover") if isinstance(j.get("recover"), dict) and j["recover"].get("plan") == psha else None' '    frozen = None if k == 1 else {"steps": pending_undo(j) or [0]}'
BRK recover-left-blocks fam_journal '[J] …and the run is closed: the spec is not blocked for good' $G '        if not recovering:' '        if True:'
BRK journal-before-checks fam_seal '[B] …and no run is left open by the refused op 1' $G '        j = None                                        # op 1 cites nothing; its journal opens once its checks hold
        if open_runs(sha=spec.sha, path=spec.given):
            raise Stop("journal: an unfinished run of this spec is open: recover it (--recover) or tell the owner")' '        j = open_journal(spec, spec.given)'
BRK lost-left-unblocked fam_undo '[U] …and a rerun of the spec is refused until the owner has looked' $G '            self.cond("journal", not runs and not lost,' '            self.cond("journal", not runs,'
BRK stuck-closed-blocks fam_journal '[J] a closed run that never moved aside' $G '                if attempt == 2 or held is None or held.get("state") == "open":' '                if True:'
BRK foreign-run-saved fam_journal '[J] a journal whose file now holds another run' $G '    if not isinstance(now, dict) or now.get("run") != j["run"]:
        raise Stop' '    if False:
        raise Stop'
BRK prune-ignores-state fam_journal '[J] pruning keeps 100 closed runs' $G '            if not held or held.get("state") not in ("done", "undone"):
                continue' '            if False:
                continue'
BRK ref-namespace-open fam_prs '[Y] the call allowlist: a tag ref' $G '            if path.endswith("/git/refs") and not' '            if False and not'
BRK workflow-fence-off fam_prs '[Y] a file-pr of a workflow file: rc 64' $G '        if any(path.lower().startswith(f) for f in FENCED_DIRS):' '        if False:'
BRK fork-branch-allowed fam_prs "[Y] a pr-create from another owner's fork" $G 'BRANCH_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9._/-]{0,199}")' 'BRANCH_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9._/:-]{0,199}")'
BRK dot-component-allowed fam_prs "[Y] a pr-create from a branch with a component that starts with '.'" $G '            and all(c and not c.startswith(".") and not c.endswith((".lock", ".")) for c in name.split("/"))' '            and all(c and not c.endswith((".lock", ".")) for c in name.split("/"))'
BRK create-head-unchecked fam_prs '[Y] a pr-create whose branch moved' $G '        self.cond("head", live == op.head, "%s: branch' '        self.cond("head", live is not None, "%s: branch'
BRK pr-absent-unchecked fam_prs '[Y] a pr-create while topic -> main is open' $G '        self.cond("pr-absent", not prs,' '        self.cond("pr-absent", True,'
BRK ready-draft-unchecked fam_prs '[Y] a pr-ready of a pull request that is not a draft' $G '                self.cond("draft", obj.get("draft") is True,' '                self.cond("draft", True,'
BRK branch-absent-unchecked fam_prs '[Y] a file-pr onto a branch that exists' $G '        self.cond("branch-absent", live is None,' '        self.cond("branch-absent", True,'
BRK path-kind-unchecked fam_prs '[Y] a file-pr onto a directory' $G '            self.cond("path", kind in (None, "file"),' '            self.cond("path", True,'
BRK same-content-unchecked fam_prs '[Y] a file-pr whose content equals the file it would replace' $G '                self.cond("changes", entry.get("sha") != git_blob_sha(op.content),' '                self.cond("changes", True,'
BRK mode-not-kept fam_prs '[Y] …the new bytes, and the file keeps mode 100755' $G '                replaces, mode = "blob %s mode %s" % (entry.get("sha"), entry.get("mode")), entry.get("mode")' '                replaces = "blob %s mode %s" % (entry.get("sha"), entry.get("mode"))'
BRK blob-unchecked fam_prs '[Y] a blob GitHub answers with another id' $G '    if blob != blob_want:' '    if False:'
BRK lost-pr-any-head fam_prs "[Y] …the run's own PR is closed, found by its head" $G '                and (x.get("base") or {}).get("ref") == e["base"] and (x.get("head") or {}).get("sha") == want' '                and (x.get("base") or {}).get("ref") == e["base"]'
BRK lock-component-allowed fam_prs '[Y] a file-pr onto a branch with a component ending in .lock' $G '            and all(c and not c.startswith(".") and not c.endswith((".lock", ".")) for c in name.split("/"))' '            and not name.endswith((".lock", ".")) and not name.startswith(".")'
BRK content-pin-unchecked fam_prs '[Y] a file-pr whose content does not match its pin' $G '        self.cond("pinned", pin == actual, "%s: content_file' '        self.cond("pinned", True, "%s: content_file'
BRK base-tip-unpinned fam_prs '[Y] a file-pr whose base moved after signing: the run fails' $G '            head, op.repo, op.base, base_tip, op.branch,' '            head, op.repo, op.base, "tip", op.branch,'
BRK noreply-off fam_prs "[Y] …author and committer the viewer's noreply address" $G '        self.files[op.i] = (base_tip, root, mode, replaces, noreply(login, did), login)' '        self.files[op.i] = (base_tip, root, mode, replaces, login, login)'
BRK undo-over-new-head fam_prs '[Y] a pull request someone pushed to after the run opened it' $G '    if (obj.get("head") or {}).get("sha") != want:' '    if False:'
BRK branch-left-silent fam_prs '[Y] a create that fails after a file-pr: undo closes its pull request, the branch it cannot delete makes it rc 5' $G '    if r != "undone" or e["kind"] != "file-pr" or not e.get("ref"):' '    if True:'
BRK values-unchecked fam_prs '[Y] the call allowlist checks values too' $G '            return isinstance(payload, dict) and bool(payload) and set(payload) <= keys and values_ok(path, payload)' '            return isinstance(payload, dict) and bool(payload) and set(payload) <= keys'
BRK git-reserved-names fam_prs '[Y] a pr-create from a branch named HEAD' $G '            and not GIT_NAMES.fullmatch(name) and name.split("/")[0] not in ("refs", "heads", "tags", "remotes")' '            and name.split("/")[0] not in ("refs", "heads", "tags", "remotes")'
BRK git-namespace-names fam_prs '[Y] a pr-create from a branch named heads/main' $G '            and not GIT_NAMES.fullmatch(name) and name.split("/")[0] not in ("refs", "heads", "tags", "remotes")' '            and not GIT_NAMES.fullmatch(name)'
BRK tree-base-optional fam_prs '[Y] the call allowlist refuses a tree without base_tree' $G '        return (HEAD_RE.fullmatch(str(payload.get("base_tree", ""))) is not None and isinstance(tree, list) and len(tree) == 1' '        return (isinstance(tree, list) and len(tree) == 1'
BRK drift-unchecked fam_prs '[Y] a commit whose tree lost the rest of the base' $G '        out.extend(tree_drift(w, repo, e["base_tip"], e["commit"], e["path"]))' '        pass'
BRK no-retry fam_prs '[Y] a lost pr-create answer while the list lags once' $G 'def run_prs(w, e, want, tries=2):' 'def run_prs(w, e, want, tries=1):'
BRK lost-pr-said-unopened fam_prs '[Y] …left for the owner, not reported as a PR never opened' $G '            if e["kind"] == "file-pr" and (e.get("pr") == "rejected" or pr_unsent):' '            if e["kind"] == "file-pr":'
BRK ready-undo-over-new-head fam_prs '[Y] …it is not turned back into a draft under the new head' $G '        if (obj.get("head") or {}).get("sha") != e["head"]:
            return "%s#%d has a new head since the run: left alone" % (repo, e["number"])' '        if False:
            return ""'
BRK lost-ref-said-lost fam_prs '[Y] …it says no pull request was opened (the PR POST was never sent)' $G '    pr_unsent = e["kind"] == "file-pr" and not e.get("ref")' '    pr_unsent = False'
BRK replaces-unpinned fam_prs '[Y] a replace whose file changed under the same base tip' $G '            head, op.repo, op.base, base_tip, op.branch, json.dumps(op.path), replaces, actual[:16], len(op.content),' '            head, op.repo, op.base, base_tip, op.branch, json.dumps(op.path), "x", actual[:16], len(op.content),'
BRK drift-open-on-404 fam_prs '[Y] tree_drift fails closed' $G '    if not old or not new:
        raise G.Infra' '    if False:
        raise G.Infra'
BRK ready-undo-missing fam_prs '[Y] …the pull request is a draft again' $G '        res = api("POST", "graphql", {"query": DRAFT_MUTATION, "variables": {"id": e["node"]}})' '        res = {"data": {"convertPullRequestToDraft": {"pullRequest": {"isDraft": True}}}}'
PLC="$TMP/break-none"; mk_plugin_copy "$PLC"
QN=0; okdef=$(declare -f ok); baddef=$(declare -f bad); sp=$PASS; sf=$FAIL
ok() { :; }; bad() { QN=$((QN+1)); }
for f in $FAMILIES; do "$f" "$PLC" >/dev/null 2>&1; done
eval "$okdef"; eval "$baddef"; PASS=$sp; FAIL=$sf
eq "$QN" 0 "control: an unbroken copy passes every family (no failed check)"

echo; summary
