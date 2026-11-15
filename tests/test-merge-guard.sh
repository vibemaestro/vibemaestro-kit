#!/bin/bash
# =============================================================================
# The guarded merge: gates/merge_guard.py and the kit baton kit:merge-pr
# =============================================================================
# Run: bash tests/test-merge-guard.sh
#
# Offline, no real merge: a fake `gh` (tests/fixtures/merge_gh.py) serves the pull request, the API and `pr merge` from a fixture
# (tests/fixtures/merge_fx.py: an all-green PR, then one named mutation per case) and logs every call. The base config's deny globs
# are the list the init-kb skill proposes, read from the skill's text.
#   [C] each refusal alone exits 1, is named, and is the only failed condition: closed, draft, head, conflict
#   [K] checks: the latest run per check, superseded runs, pending, empty, skipped, another workflow, a status, the required
#       floor (a path-skipped required check), accepted red steps (exact check, whole-word prefix, every failed step)
#   [F] files: deny (also the config itself, so a PR cannot turn admin bypass on), brief, rename source, case, symlink,
#       submodule, a count that does not add up, a truncated tree
#   [B] behind base: refused, printed, listed with --behind-ok, overlapping, unlisted; the compare API failing with a 5xx or a
#       dropped connection is asked again (4 attempts) and, when it keeps failing, could not conclude and says transient; a 4xx is not
#   [S] --behind-ok-clean: a docs file both sides changed, accepted when git merge-file and GitHub's test merge agree on a clean
#       merge (and the merged current-state passes its check); refused on a conflict, a test file, a rename, an add, a symlink,
#       other bytes, a merge over the cap; a stale test merge is could-not-conclude; a glob that is not docs-only is rc 64
#   [P] bootstrap: a base with no config and a PR that adds one; the added config's deny globs, the brief, and the refusals
#   [U] bootstrap of a base that has a config with no merge.deny_globs: the PR that changes the config to add the section takes the
#       bootstrap lane (same checks); every other PR against that base is still rc 65; the head may only add the merge section
#   [I] image: --require-image by tag and by full reference, missing, another image; the image-bump lane and its faults
#   [O] options: --admin without admin_bypass (64), a short head (64), deny globs unset (65), the head's config has no effect
#   [M] dry run makes no merge call; --merge makes one, pinned; a moved head; the merge log, one line per run, no title or body;
#       an HTTP 502 on the merge call may have landed: merged at the head is merged; at another head, unreadable or refused on the
#       one more try at the head, rc 2 logged merge-pending; a second call's exit 0 is read again
#   [Q] the deny floor follows rules.dirs: the config init writes for a rules folder under .vibemaestro/ with another name refuses
#       its files, so does the floor of a first PR; .vibemaestro/batons still merges
#   [L] the back-merge lane: a backmerge/* PR into the default branch (whatever its name) with its head on release merges with
#       a merge commit; one whose head is not on release, or with no release, is refused; another PR whose head is on release is
#       refused; every other PR squashes; its comparison with release is asked again after a 5xx (4 attempts)
#   [A] --behind auto: a fresh test merge (re-asked when stale, a conflict at once), disjoint files or a shared docs file merged
#       clean (not code, a planner's map, a dot-directory or CLAUDE.md), and disjoint suites by the base's planner (the kit's
#       tests/plan.py --suites: the base's files --woken, with the merge base's map as --old; the PR's as CI plans them), read and
#       run from the base only (a PR's planner or map is never read), with no token, PATH or socket; no planner (or bootstrap):
#       every base file must be docs
#   [T] the kit baton through baton.py: check, rehearse = dry run, sign and run = one merge, a deny PR cannot be signed, a
#       second run is refused, a merged PR read back as open is rc 5, an escape from batons/ is refused; a 502 on a merge that
#       landed is run ok, and undo advises no revert for a merge at the signed head
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
# shellcheck source=fixtures/ports.sh
. "$HERE/fixtures/ports.sh"
# shellcheck source=fixtures/baton-owner.sh
. "$HERE/fixtures/baton-owner.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
SKILL="$PLUGIN/skills/init-kb/SKILL.md"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
GHB="$TMP/ghbin"; mkdir -p "$GHB"
printf '#!/bin/sh\nexec python3 -B "%s" "$@"\n' "$HERE/fixtures/merge_gh.py" > "$GHB/gh"; chmod +x "$GHB/gh"
PATH="$GHB:$PATH"; export PATH
H=a1b2c3d4e5f60718293a4b5c6d7e8f9001122334
H2=a1b2c3d4e5f60718293a4b5c6d7e8f9001122335

# mkfx [mutation ...] — a fresh case directory (printed): fx.json, an empty gh.log, brief.txt (src/**, docs/**) and lane.txt
mkfx() {
  local d; d=$(fresh)
  python3 -B "$HERE/fixtures/merge_fx.py" "$d/fx.json" --skill "$SKILL" "$@" || { bad "fixture: merge_fx.py $*"; }
  : > "$d/gh.log"; printf '# the brief'"'"'s scope\nsrc/**\n\ndocs/**\n' > "$d/brief.txt"
  printf 'deploy/**\nimage/**\n.github/workflows/image.yml\n' > "$d/lane.txt"
  printf '%s' "$d"
}
# guard <plugin> <case dir> [args...] — the guard from the case directory; OUT (stdout and stderr), RC
GENV=()
guard() {
  local pl=$1 d=$2; shift 2
  OUT=$(cd "$d" && cenv XDG_STATE_HOME="$d/state" FAKE_GH_FX="$d/fx.json" FAKE_GH_LOG="$d/gh.log" FAKE_GH_STATE="$d/merged.json" \
        MERGE_GUARD_RETRY_WAIT_S=0 ${GENV[@]+"${GENV[@]}"} python3 -B "$pl/gates/merge_guard.py" "$@" 2>&1); RC=$?
}
STD=(--repo acme/app --pr 7 --head "$H" --brief brief.txt)
merges() { grep -c '^\["pr", "merge"' "$1/gh.log"; }
loglines() { if [ -f "$1/state/vibemaestro/merge-log.jsonl" ]; then wc -l < "$1/state/vibemaestro/merge-log.jsonl" | tr -d ' '; else echo 0; fi; }
nfail() { printf '%s\n' "$OUT" | grep -c '^  FAIL  '; }
# alone <label> <condition> <mutations...> [-- guard args...] — exits 1, names the condition, and it is the only failed one
alone() {
  local label=$1 cond=$2 d; shift 2
  local muts=() extra=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do muts+=("$1"); shift; done
  [ "${1:-}" = -- ] && { shift; extra=("$@"); }
  d=$(mkfx "${muts[@]}")
  guard "$PL" "$d" "${STD[@]}" "${extra[@]}"
  eq "$RC" 1 "$label: rc 1"
  has "$OUT" "FAIL  $cond:" "$label: the refusal names $cond"
  eq "$(nfail)" 1 "$label: $cond is the only failed condition"
  eq "$(merges "$d")" 0 "$label: no pr merge call"
}

fam_conditions() {
  PL=$1; local d
  d=$(mkfx); guard "$PL" "$d" "${STD[@]}"
  eq "$RC" 0 "[C] the all-green PR: rc 0 in dry run"
  eq "$(nfail)" 0 "[C] …no failed condition"
  has "$OUT" "merge-plan: merge acme/app#7 head $H into main@b0b0b0b0b0b0 squash lane normal admin no" "[C] …the plan line names repo, PR, full head, base"
  eq "$(merges "$d")" 0 "[C] …and dry run makes no pr merge call"
  alone "[C] a closed PR" open closed
  alone "[C] a draft PR" not-draft draft
  d=$(mkfx); guard "$PL" "$d" --repo acme/app --pr 7 --head "$H2" --brief brief.txt
  eq "$RC" 1 "[C] a head that is not the reported one: rc 1"; has "$OUT" "FAIL  head:" "[C] …named head"
  eq "$(nfail)" 1 "[C] …the only failed condition"
  alone "[C] a conflict" mergeable conflict
  d=$(mkfx conflict); guard "$PL" "$d" "${STD[@]}"
  has "$OUT" "REFUSED early: mergeable" "[C] a conflict stops the run early, named"
  hasnt "$(cat "$d/gh.log")" "check-runs" "[C] …before the CI runs are read"
  hasnt "$(cat "$d/gh.log")" "/compare/" "[C] …and before the comparison with the base"
  eq "$(loglines "$d")" 1 "[C] …and the run is logged once"
  d=$(mkfx mergeable-late); guard "$PL" "$d" "${STD[@]}"
  eq "$RC" 0 "[C] mergeable UNKNOWN, then MERGEABLE on a re-read: rc 0"
  alone "[C] a PR that targets another branch than the repo's default" base base-other
  d=$(mkfx base-other); guard "$PL" "$d" "${STD[@]}" --admin
  eq "$RC" 64 "[C] …and the permissive config at that branch is never read: --admin is still rc 64"
  hasnt "$(cat "$d/gh.log")" "ref=c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0" "[C] …no read at the other branch's tip"
  d=$(mkfx base-other); guard "$PL" "$d" "${STD[@]}" --base scratch
  eq "$RC" 0 "[C] --base scratch, named by the caller: that branch's config is the one read"
  d=$(mkfx); guard "$PL" "$d" --repo acme/app --pr 7 --head "$H2" --brief brief.txt
  has "$OUT" "headRefOid $H, reported $H2" "[C] a head mismatch prints both full SHAs"
  d=$(mkfx default-branch=dev+main); guard "$PL" "$d" "${STD[@]}"
  eq "$RC" 0 "[C] a default branch with a legal '+' in its name: rc 0"
}

fam_checks() {
  PL=$1; local d
  alone "[K] an older green run superseded by a newer red one" checks stale-green
  d=$(mkfx rerun-green); guard "$PL" "$d" "${STD[@]}"
  eq "$RC" 0 "[K] control: an older red run superseded by a newer green one passes"
  d=$(mkfx required=unit skipped-after-green); guard "$PL" "$d" "${STD[@]}"
  eq "$RC" 0 "[K] a required check green, then a late skipped duplicate of it: the green run counts (rc 0)"
  alone "[K] green, skipped, then a newer real run red" checks red-after-skipped
  alone "[K] a red run, then a run skipped by an untouched edit on the same head: still red" checks skipped-after-red
  alone "[K] draft: a required check whose only run was skipped on the draft is red" required required=unit only-skipped
  d=$(mkfx required=unit draft-then-ready); guard "$PL" "$d" "${STD[@]}"
  eq "$RC" 0 "[K] draft: …and the ready_for_review run makes it green (rc 0)"
  alone "[K] a pending run" checks pending
  alone "[K] a rerun queued after a green run (not started: the newest)" checks queued-after-green
  alone "[K] an empty check list" checks empty-checks
  alone "[K] only skipped checks (no success at all)" checks only-skipped
  alone "[K] a red job of another workflow behind a newer green job of the same name" checks other-workflow-red
  alone "[K] a commit status in error" checks status-error
  alone "[K] a required check that a path filter skipped" required required=e2e e2e=skipped
  alone "[K] a required check that never ran" required required=e2e
  d=$(mkfx required=e2e e2e=success); guard "$PL" "$d" "${STD[@]}"
  eq "$RC" 0 "[K] control: the required check green passes"
  d=$(mkfx e2e=skipped); guard "$PL" "$d" "${STD[@]}"
  eq "$RC" 0 "[K] control: a skipped check that is not required is ignored"
  alone "[K] a red check and no --accept" checks "red-unit=Full suite before ready"
  d=$(mkfx "red-unit=Full suite before ready"); guard "$PL" "$d" "${STD[@]}" --accept 'unit:Full suite before ready'
  eq "$RC" 0 "[K] --accept: every failed step of the check starts with the accepted prefix: rc 0"
  has "$OUT" "accepted" "[K] …the accepted run is printed"
  alone "[K] --accept, but the job has one more failed step" checks "red-unit=Full suite before ready|Lint" \
    -- --accept 'unit:Full suite before ready'
  alone "[K] --accept, a step whose name only starts like the prefix" checks "red-unit=Check image tagging" \
    -- --accept 'unit:Check image tag'
  d=$(mkfx "red-unit=Check image tag (r16)"); guard "$PL" "$d" "${STD[@]}" --accept 'unit:Check image tag'
  eq "$RC" 0 "[K] control: the prefix followed by ' (' is accepted"
  alone "[K] --accept names the check in another case" checks "red-unit=Full suite before ready" \
    -- --accept 'Unit:Full suite before ready'
  alone "[K] --accept on a cancelled run" checks red-unit-cancelled -- --accept 'unit:Full suite before ready'
  alone "[K] --accept, every check red (no success left)" checks "red-only=Full suite before ready" \
    -- --accept 'unit:Full suite before ready'
  d=$(mkfx); guard "$PL" "$d" "${STD[@]}" --accept 'nocolon'
  eq "$RC" 64 "[K] an --accept without check:prefix: rc 64"
  alone "[K] no check run, one commit status in success (a status never counts as green)" checks status-only
  alone "[K] a required check satisfied only by a commit status of that name" required required=e2e status-named=e2e
  alone "[K] two workflow files of the same name: a red job behind a newer green job of the other" checks same-workflow-name
  alone "[K] a red run half a second after a green one (fractional seconds)" checks fraction-time
  alone "[K] a completed green run with no start time behind a red run" checks completed-no-start
  d=$(mkfx "colon-check=Full suite before ready"); guard "$PL" "$d" "${STD[@]}" --accept 'CI: unit:Full suite before ready '
  eq "$RC" 0 "[K] --accept for a check whose name holds ':' (and a trailing space in the prefix): rc 0"
  d=$(mkfx external-ci=exit-load); guard "$PL" "$d" "${STD[@]}"
  eq "$RC" 65 "[K] an external CI adapter that calls sys.exit(0) while loading: rc 65, never 0"
  d=$(mkfx external-ci=exit); guard "$PL" "$d" "${STD[@]}"
  eq "$RC" 2 "[K] an external CI adapter that calls sys.exit(0): rc 2, never green"
  eq "$(loglines "$d")" 1 "[K] …and the run is still logged"
}

fam_files() {
  PL=$1; local d deny
  alone "[F] a file under a deny glob" deny file=deploy/app.yaml -- --allow 'deploy/**'
  alone "[F] a deny glob matches whatever the case" deny file=src/Secret.env
  # a .claude-plugin segment at any depth and in any case is denied whatever merge.deny_globs says (the skill's list names none)
  for p in .claude-plugin/m.json plugins/p/.claude-plugin/p.json plugins/p/.Claude-Plugin/p.json "a/.claude-plugin./x.json"; do
    alone "[F] a .claude-plugin path no deny glob names ($p)" deny "file=$p" -- --allow '**'
    has "$OUT" "denied: $p" "[F] …named"
  done
  deny=$(python3 -c 'import json,re,sys
for l in open(sys.argv[1]):
    lists = re.findall(r"`(\[.*?\])`", l) if "`merge.deny_globs`" in l else []
    if lists: print(" ".join(json.loads(lists[-1]))); break' "$SKILL")
  case " $deny " in *" .vibemaestro/* "*) ok "[F] instrument: the skill proposes .vibemaestro/* as a deny glob";;
                    *) bad "[F] instrument: the skill proposes .vibemaestro/* as a deny glob (got: $deny)";; esac
  d=$(mkfx file=.vibemaestro/sdlc.json); guard "$PL" "$d" "${STD[@]}" --allow '.vibemaestro/**'
  eq "$RC:$(merges "$d")" "1:0" "[F] a PR that changes .vibemaestro/sdlc.json (to turn admin bypass on): rc 1, nothing merged"
  has "$OUT" "FAIL  deny:" "[F] …refused by the proposed deny globs"
  has "$OUT" "FAIL  own-inputs:" "[F] …and by own-inputs, whatever the deny globs say"
  alone "[F] a file outside the brief" brief file=lib/x.py
  alone "[F] the brief is case-sensitive" brief file=Src/x.py
  d=$(mkfx rename=deploy/app.yaml:src/app2.yaml); guard "$PL" "$d" "${STD[@]}"
  eq "$RC" 1 "[F] a rename out of a denied path: rc 1"; has "$OUT" "FAIL  deny:" "[F] …the rename source is named by deny"
  alone "[F] a rename whose source is outside the brief" brief rename=lib/x.py:src/x.py
  alone "[F] a removed file outside the brief" brief removed=lib/old.py
  alone "[F] a symlink inside the brief" links symlink=src/link
  alone "[F] a submodule inside the brief" links submodule=src/vendor
  alone "[F] fewer files read than the PR counts" files count-mismatch
  d=$(mkfx tree-truncated); guard "$PL" "$d" "${STD[@]}"
  eq "$RC" 2 "[F] a truncated head tree: rc 2 (could not conclude)"
  d=$(mkfx); guard "$PL" "$d" --repo acme/app --pr 7 --head "$H"
  eq "$RC" 64 "[F] no --brief and no --allow: rc 64"
  d=$(mkfx); printf 'src/[ab]/**\n' > "$d/bad.txt"; guard "$PL" "$d" --repo acme/app --pr 7 --head "$H" --brief bad.txt
  eq "$RC" 64 "[F] a bad glob in the brief: rc 64"
  d=$(mkfx); guard "$PL" "$d" "${STD[@]}" --allow 'src/**'
  eq "$RC" 0 "[F] --allow adds to --brief"
  alone "[F] the guard's own config changed, with no deny glob at all" own-inputs deny-none file=.vibemaestro/sdlc.json -- --allow '**'
  alone "[F] the configured CI adapter changed by the PR" own-inputs external-ci deny-none file=tools/ci.py -- --allow '**'
  alone "[F] the CI adapter is a symlink at the base (a PR could change its target)" own-inputs external-ci input-symlink=adapter deny-none file=lib/real.py -- --allow '**'
  alone "[F] the config is a symlink at the base" own-inputs input-symlink=config
  d=$(mkfx external-ci input-symlink=adapter base-tree-truncated deny-none file=lib/real.py); guard "$PL" "$d" "${STD[@]}" --allow '**'
  eq "$RC" 2 "[F] the base tree is truncated before the adapter's entry: rc 2 (could not conclude), never ok"
  has "$OUT" "??    own-inputs:" "[F] …own-inputs is the condition it could not judge"
}

fam_behind() {
  PL=$1; local d
  alone "[B] behind base, no --behind-ok" behind behind=docs/other.md,ops/notes.txt
  has "$OUT" "docs/other.md" "[B] …the base files it saw are printed"; has "$OUT" "ops/notes.txt" "[B] …all of them"
  d=$(mkfx behind=ops/a.yaml,ops/b.yaml); guard "$PL" "$d" "${STD[@]}" --behind-ok 'ops/**'
  eq "$RC" 0 "[B] behind only by base files matching --behind-ok: rc 0"
  has "$OUT" "ops/a.yaml" "[B] …the base files are printed when accepted too"
  alone "[B] a base file not listed in --behind-ok" behind behind=ops/a.yaml,lib/y.py -- --behind-ok 'ops/**'
  alone "[B] a base file that is also a file of the PR" behind behind=ops/a.yaml,src/app.py -- --behind-ok 'ops/**,src/**'
  # a transient fault of the compare API: asked again; a 4xx is not. MERGE_GUARD_RETRY_WAIT_S=0 (guard) makes the waits 0.
  ncmp() { grep -c '/compare/' "$1/gh.log"; }
  d=$(mkfx compare-seq=500,ok); guard "$PL" "$d" "${STD[@]}" --behind-ok 'docs/**'
  eq "$RC:$(ncmp "$d")" "0:2" "[B] the comparison fails once with HTTP 500, then answers: it is asked twice and the check concludes (rc 0)"
  has "$OUT" "  ok    behind: behind the base by 2 commit(s)" "[B] …and behind is concluded, not unknown"
  d=$(mkfx compare-seq=502,drop,ok); guard "$PL" "$d" "${STD[@]}" --behind-ok 'docs/**'
  eq "$RC:$(ncmp "$d")" "0:3" "[B] an HTTP 502 then a dropped connection, then it answers: asked three times, rc 0"
  d=$(mkfx compare-seq=500); guard "$PL" "$d" "${STD[@]}" --behind-ok 'docs/**' --merge
  eq "$RC:$(ncmp "$d"):$(merges "$d")" "2:4:0" "[B] the comparison fails with HTTP 500 every time: asked 4 times, could not conclude (rc 2), no pr merge call"
  has "$OUT" "??    behind: the comparison with the base cannot be read: gh api repos/acme/app/compare/" "[B] …behind is the condition it could not judge"
  has "$OUT" "[transient: HTTP 500 on all 4 attempts; run it again later]" "[B] …and the line says it is transient: the status, the attempts, run again"
  d=$(mkfx compare-seq=drop); guard "$PL" "$d" "${STD[@]}" --behind-ok 'docs/**'
  eq "$RC:$(ncmp "$d")" "2:4" "[B] a dropped connection every time: asked 4 times, rc 2"
  has "$OUT" "[transient: connection error on all 4 attempts; run it again later]" "[B] …the line says connection error"
  d=$(mkfx compare-seq=eof,ok); guard "$PL" "$d" "${STD[@]}" --behind-ok 'docs/**'
  eq "$RC:$(ncmp "$d")" "0:2" "[B] a connection that ends with a bare EOF, then it answers: asked twice, rc 0"
  d=$(mkfx compare-seq=422-body5xx,ok); guard "$PL" "$d" "${STD[@]}" --behind-ok 'docs/**'
  eq "$RC:$(ncmp "$d")" "2:1" "[B] HTTP 422 whose body quotes HTTP 500: a 4xx, asked once, rc 2"
  hasnt "$OUT" "transient" "[B] …and it is not called transient"
  d=$(mkfx compare-seq=404,ok); guard "$PL" "$d" "${STD[@]}" --behind-ok 'docs/**'
  eq "$RC:$(ncmp "$d")" "2:1" "[B] the comparison answers HTTP 404: asked once, could not conclude (rc 2)"
  hasnt "$OUT" "transient" "[B] …and it is not called transient"
  d=$(mkfx compare-seq=403,ok); guard "$PL" "$d" "${STD[@]}" --behind-ok 'docs/**'
  eq "$RC:$(ncmp "$d")" "2:1" "[B] the comparison answers HTTP 403: asked once, rc 2"
}

LED=kb/current-state.md
CL=(--allow 'kb/**,tests/**' --behind-ok-clean 'kb/**/*.md')
fam_clean() {
  PL=$1; local d g
  d=$(mkfx shared=$LED); guard "$PL" "$d" "${STD[@]}" "${CL[@]}"
  eq "$RC" 0 "[S] a clean shared current-state: rc 0"
  has "$OUT" "accepted clean: $LED (git merge-file clean, the same bytes as GitHub's test merge e0e0e0e0e0e0" "[S] …the accepted file is printed"
  has "$(printf '%s\n' "$OUT" | grep '^merge-plan: ')" " behind 1 " "[S] …the plan line counts the commits behind"
  has "$(printf '%s\n' "$OUT" | grep '^merge-plan: ')" " clean 1" "[S] …and how many shared files merged clean, so the signer sees it"
  has "$OUT" "the merged current-state passes its check" "[S] …with the current-state check on the merged text"
  has "$(tail -n 1 "$d/state/vibemaestro/merge-log.jsonl")" "\"clean\": [\"$LED\"]" "[S] …and logged"
  has "$(cat "$d/gh.log")" "contents/$LED?ref=e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0" "[S] …GitHub's test merge was read"
  alone "[S] control: the same PR with --behind-ok instead of --behind-ok-clean" behind shared=$LED -- --allow 'kb/**' --behind-ok 'kb/**'
  alone "[S] a shared current-state that conflicts" behind shared=$LED:conflict -- "${CL[@]}"
  has "$OUT" "1 conflict(s)" "[S] …the conflict is named"
  alone "[S] a shared test file, clean, listed in --behind-ok" behind shared=tests/t.sh -- "${CL[@]}" --behind-ok 'tests/**'
  alone "[S] a shared doc renamed away on main" behind shared=$LED:renamed -- "${CL[@]}"
  has "$OUT" "a rename's source in the base" "[S] …the rename is named"
  alone "[S] a doc both sides added" behind shared=$LED:added -- "${CL[@]}"
  alone "[S] a shared doc that is a symlink at the base" behind shared=$LED:link -- "${CL[@]}"
  alone "[S] GitHub's test merge holds other bytes than git merge-file" behind shared=$LED:differs -- "${CL[@]}"
  alone "[S] the merged current-state over its byte cap (each side under it)" behind shared=$LED:over-cap -- "${CL[@]}"
  has "$OUT" "fails the current-state check" "[S] …the check is named"
  alone "[S] the ledger is current_state.path of the config: docs/state.md over its cap" behind ledger=docs/state.md shared=docs/state.md:over-cap -- --behind-ok-clean 'docs/**/*.md'
  d=$(mkfx ledger=docs/state.md shared=$LED:over-cap); guard "$PL" "$d" "${STD[@]}" "${CL[@]}"
  eq "$RC" 0 "[S] control: with the ledger elsewhere, kb/current-state.md is a plain doc (no cap check): rc 0"
  alone "[S] a shared doc whose text holds a NUL byte" behind shared=$LED:nul -- "${CL[@]}"
  has "$OUT" "not UTF-8 text" "[S] …refused as not text"
  d=$(mkfx shared=$LED:stale); guard "$PL" "$d" "${STD[@]}" "${CL[@]}"
  eq "$RC" 2 "[S] GitHub's test merge is of another base: rc 2 (could not conclude)"
  has "$OUT" "??    behind:" "[S] …behind is what could not be told"
  d=$(mkfx shared=docs/guide.md); guard "$PL" "$d" "${STD[@]}" --behind-ok-clean 'docs/**/*.md'
  eq "$RC" 0 "[S] a clean shared doc that is not the current-state: rc 0"
  hasnt "$OUT" "current-state passes" "[S] …and no current-state check on it"
  for g in '**/*.md' '*.md' 'tests/**' 'kb/**' 'docs/*' 'tests/a.md' 'Tests/a.md' 'plugins/x/*.md' '.github/*.md' \
           '.vibemaestro/rules/*.md' 'kb/plugin.json' 'kb/package-lock.json' 'kb/*.md.py' '?b/*.md'; do
    d=$(mkfx); guard "$PL" "$d" "${STD[@]}" --behind-ok-clean "$g"
    eq "$RC" 64 "[S] --behind-ok-clean '$g' (not a docs glob): rc 64"
  done
  for g in 'kb/**/*.md' 'kb/current-state.md' 'docs/**/*.md' 'README.md'; do
    d=$(mkfx); guard "$PL" "$d" "${STD[@]}" --behind-ok-clean "$g"
    eq "$RC" 0 "[S] control: --behind-ok-clean '$g' is a docs glob: rc 0"
  done
}

BA=(--allow '.vibemaestro/**,kb/**')
fam_boot() {
  PL=$1; local d
  d=$(mkfx bootstrap); guard "$PL" "$d" "${STD[@]}" "${BA[@]}"
  eq "$RC" 0 "[P] bootstrap: the base has no config, the PR adds one: rc 0"
  has "$OUT" "bootstrap: it has no .vibemaestro/sdlc.json" "[P] …the run says bootstrap"
  has "$OUT" "bootstrap: the init default is added, and the 2 file(s) this PR adds as its config and its rules' Markdown are its scaffold" "[P] …deny skips the scaffold it adds"
  has "$(printf '%s\n' "$OUT" | grep '^merge-plan: ')" " bootstrap " "[P] …the plan line carries bootstrap"
  hasnt "$(tail -n 1 "$d/state/vibemaestro/merge-log.jsonl")" '"bootstrap": null' "[P] …and the log line too"
  has "$(cat "$d/gh.log")" "sdlc.json?ref=$H" "[P] …the config was read at the head"
  alone "[P] bootstrap: the added deny globs still refuse a workflow" deny bootstrap=workflow -- "${BA[@]}" --allow '.github/**'
  alone "[P] bootstrap: the brief still applies" brief bootstrap
  alone "[P] bootstrap: a nested .claude-plugin path the added deny globs and the init default omit" deny bootstrap file=plugins/p/.claude-plugin/p.json -- "${BA[@]}" --allow 'plugins/**'
  alone "[P] bootstrap: a .claude-plugin path is never a scaffold path (rules directory .vibemaestro/.claude-plugin)" deny bootstrap=plugin-rules -- "${BA[@]}"
  has "$OUT" "denied: .vibemaestro/.claude-plugin/README.md" "[P] …named"
  alone "[P] bootstrap: gate code the PR adds under .vibemaestro/ is denied (CI runs it)" deny bootstrap file=.vibemaestro/gates/pr_sensitive.py -- "${BA[@]}"
  alone "[P] bootstrap: an added config that denies nothing still gets the init default" deny bootstrap=empty-deny file=.github/workflows/ci.yml -- "${BA[@]}" --allow '.github/**'
  d=$(mkfx bootstrap=empty-deny file=.vibemaestro/batons/x.sh); guard "$PL" "$d" "${STD[@]}" "${BA[@]}"
  eq "$RC" 0 "[P] bootstrap: the init default leaves a project baton (.vibemaestro/batons/x.sh) to the guard: rc 0"
  alone "[P] bootstrap: …while it still denies the rules directory" deny bootstrap=empty-deny file=.vibemaestro/rules/x.sh -- "${BA[@]}"
  d=$(mkfx bootstrap); guard "$PL" "$d" "${STD[@]}" "${BA[@]}" --require-image cc1-node22-r16
  eq "$RC" 64 "[P] bootstrap with --require-image (the registry would be the PR's own): rc 64"
  d=$(mkfx bootstrap=modified); guard "$PL" "$d" "${STD[@]}" "${BA[@]}"
  eq "$RC" 65 "[P] the PR modifies (not adds) the config the base lacks: rc 65, no bootstrap"
  d=$(mkfx bootstrap config-unreadable); guard "$PL" "$d" "${STD[@]}" "${BA[@]}"
  eq "$RC" 2 "[P] the base config cannot be read (not a 404): rc 2, no bootstrap"
  hasnt "$(cat "$d/gh.log")" "sdlc.json?ref=$H" "[P] …and the head's config is never read"
  d=$(mkfx bootstrap=external); guard "$PL" "$d" "${STD[@]}" "${BA[@]}"
  eq "$RC" 65 "[P] bootstrap with an external adapter in the added config: rc 65"
  has "$OUT" "cannot bring the code that judges it" "[P] …refused as bootstrap, named"
  d=$(mkfx bootstrap=no-deny); guard "$PL" "$d" "${STD[@]}" "${BA[@]}"
  eq "$RC" 65 "[P] bootstrap with no merge.deny_globs in the added config: rc 65"
  has "$OUT" "the config this PR adds" "[P] …named as the added config's fault"
  d=$(mkfx bootstrap); guard "$PL" "$d" "${STD[@]}" "${BA[@]}" --admin
  eq "$RC" 64 "[P] bootstrap with --admin (the added config grants admin_bypass): rc 64"
  d=$(mkfx bootstrap); guard "$PL" "$d" "${STD[@]}" "${BA[@]}" --image-bump
  eq "$RC" 64 "[P] bootstrap with --image-bump (the added config turns the lane on): rc 64"
}

fam_image() {
  PL=$1; local d n
  d=$(mkfx); guard "$PL" "$d" "${STD[@]}" --require-image cc1-node22-r16
  eq "$RC" 0 "[I] --require-image with a tag that exists: rc 0"
  has "$OUT" "ghcr.io/acme/app-image:cc1-node22-r16" "[I] …the full reference is derived from the config"
  d=$(mkfx); guard "$PL" "$d" "${STD[@]}" --require-image ghcr.io/acme/app-image:cc1-node22-r16
  eq "$RC" 0 "[I] --require-image with a full reference: rc 0"
  n=$(grep -c 'versions' "$d/gh.log"); eq "$n" 1 "[I] …one registry lookup"
  alone "[I] --require-image with a tag that is not in the registry" image -- --require-image cc1-node22-r17
  d=$(mkfx); guard "$PL" "$d" "${STD[@]}" --require-image ghcr.io/other/img:v1
  eq "$RC" 64 "[I] --require-image naming another image: rc 64"; has "$OUT" "ghcr.io/acme/app-image" "[I] …the configured one is printed"
  d=$(mkfx registry-none); guard "$PL" "$d" "${STD[@]}" --require-image v1
  eq "$RC" 64 "[I] --require-image without a registry in the config: rc 64"
  d=$(mkfx lane); guard "$PL" "$d" --repo acme/app --pr 7 --head "$H" --brief lane.txt --image-bump
  eq "$RC" 0 "[I] the lane: a bump PR (tag lines, the image tree, the revision line): rc 0"
  has "$OUT" "lane image-bump" "[I] …the plan line names the lane"
  d=$(mkfx lane); guard "$PL" "$d" --repo acme/app --pr 7 --head "$H" --brief lane.txt
  eq "$RC" 1 "[I] control: the same PR in the normal lane is refused by deny"
  for c in "non-tag lane-tag-only" "two-tags lane-one-tag" "tag-missing image" "pin lane-deny" "outside lane-files" \
           "revision-other lane-revision"; do
    set -- $c
    d=$(mkfx lane="$1"); guard "$PL" "$d" --repo acme/app --pr 7 --head "$H" --brief lane.txt --allow 'src/**' --image-bump
    eq "$RC" 1 "[I] the lane, fault $1: rc 1"; has "$OUT" "FAIL  $2:" "[I] …named $2"
    eq "$(nfail)" 1 "[I] …the only failed condition"
  done
  d=$(mkfx lane file=image/.claude-plugin/p.json); guard "$PL" "$d" --repo acme/app --pr 7 --head "$H" --brief lane.txt --image-bump
  eq "$RC/$(nfail)" "1/1" "[I] the lane, a .claude-plugin path under the image tree (image/** covers it, the root glob does not): rc 1, one failed condition"
  has "$OUT" "FAIL  lane-deny: " "[I] …named lane-deny"; has "$OUT" "image/.claude-plugin/p.json (a .claude-plugin path)" "[I] …and the path"
  for c in "rename-tag lane-tag-only" "sidecar lane-tag-only" "args lane-tag-only"; do
    set -- $c
    d=$(mkfx lane="$1"); guard "$PL" "$d" --repo acme/app --pr 7 --head "$H" --brief lane.txt --image-bump
    eq "$RC" 1 "[I] the lane, fault $1: rc 1"; has "$OUT" "FAIL  $2:" "[I] …named $2"
  done
  d=$(mkfx lane=rev-rename); guard "$PL" "$d" --repo acme/app --pr 7 --head "$H" --brief lane.txt --image-bump
  eq "$RC" 1 "[I] the lane, the revision file renamed: rc 1"; has "$OUT" "FAIL  lane-revision:" "[I] …named lane-revision"
  eq "$(nfail)" 1 "[I] …the only failed condition"
  d=$(mkfx lane=no-newline); guard "$PL" "$d" --repo acme/app --pr 7 --head "$H" --brief lane.txt --image-bump
  eq "$RC" 0 "[I] the lane: a tag line with no final newline (the diff marker does not split the pair): rc 0"
  d=$(mkfx lane lane-off); guard "$PL" "$d" --repo acme/app --pr 7 --head "$H" --brief lane.txt --image-bump
  eq "$RC" 64 "[I] --image-bump with the lane off: rc 64"
}

fam_options() {
  PL=$1; local d
  d=$(mkfx); guard "$PL" "$d" "${STD[@]}" --admin
  eq "$RC" 64 "[O] --admin with merge.admin_bypass false: rc 64"
  has "$OUT" "merge.admin_bypass" "[O] …the message names the key"
  d=$(mkfx admin-on); guard "$PL" "$d" "${STD[@]}" --admin
  eq "$RC" 0 "[O] --admin with merge.admin_bypass true: rc 0"; has "$OUT" "admin yes" "[O] …the plan line says admin yes"
  d=$(mkfx); guard "$PL" "$d" --repo acme/app --pr 7 --head "${H:0:12}" --brief brief.txt
  eq "$RC" 64 "[O] a short head SHA: rc 64"
  d=$(mkfx config-no-merge); guard "$PL" "$d" "${STD[@]}"
  eq "$RC" 65 "[O] merge.deny_globs unset in the base config: rc 65"; has "$OUT" "merge.deny_globs" "[O] …the key is named"
  d=$(mkfx no-config); guard "$PL" "$d" "${STD[@]}"
  eq "$RC" 65 "[O] no config at the base: rc 65 (deny globs unset)"
  d=$(mkfx bad-config); guard "$PL" "$d" "${STD[@]}"
  eq "$RC" 65 "[O] an invalid config at the base: rc 65"
  d=$(mkfx file=deploy/app.yaml); guard "$PL" "$d" "${STD[@]}" --allow 'deploy/**' --admin
  eq "$RC" 64 "[O] the head's config (no deny glob, admin bypass on) has no effect: --admin is still rc 64"
  d=$(mkfx file=deploy/app.yaml); guard "$PL" "$d" "${STD[@]}" --allow 'deploy/**'
  eq "$RC" 1 "[O] …and deploy/** is still denied"
  has "$(cat "$d/gh.log")" "ref=b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0" "[O] …the config is read at the base SHA"
  hasnt "$(cat "$d/gh.log")" "sdlc.json?ref=$H" "[O] …and never at the head"
  d=$(mkfx pr-view-fail); guard "$PL" "$d" "${STD[@]}"
  eq "$RC" 2 "[O] gh pr view fails: rc 2"
  d=$(mkfx); guard "$PL" "$d" --help
  eq "$RC" 0 "[O] --help alone: rc 0"
  d=$(mkfx); guard "$PL" "$d" "${STD[@]}" --merge --help
  eq "$RC:$(merges "$d")" "64:0" "[O] --help with other arguments: rc 64, nothing merged (rc 0 means every condition holds)"
  d=$(mkfx); guard "$PL" "$d" --repo acme/app --pr 7 --head "$H"$'\n' --brief brief.txt
  eq "$RC" 64 "[O] a head with a trailing newline: rc 64"
  d=$(mkfx); printf 'src/**\n\377\376\n' > "$d/bad8.txt"; guard "$PL" "$d" --repo acme/app --pr 7 --head "$H" --brief bad8.txt
  eq "$RC" 64 "[O] a brief file that is not UTF-8: rc 64"
  d=$(mkfx); printf '\377\376\n' > "$d/bad8.txt"; guard "$PL" "$d" "${STD[@]}" --merge --expect-plan bad8.txt
  eq "$RC:$(merges "$d")" "64:0" "[O] a signed-plan file that is not UTF-8: rc 64, nothing merged"
  d=$(mkfx); guard "$PL" "$d" "${STD[@]}" --base $'\377'
  eq "$RC" 64 "[O] a --base that is not UTF-8: rc 64"
  out=$(python3 - "$PL/gates" <<'PY'
import subprocess, sys
sys.path.insert(0, sys.argv[1])
sys.dont_write_bytecode = True
import merge_guard as M
names = ["main", "dev+main", "release/1.2", "f\u00e9", "a#b", "a/b@c", "a..b", "a/.b", "a/./b", ".a", "a.", "a/", "/a", "a//b", "a.lock",
         "a.lock/b", "a/b.lock/c", "a@{b", "a b", "a~b", "a^b", "a:b", "a?b", "a*b", "a[b", "a\\b", "a\x7fb"]
# the syntax of refs/heads/<name> (no repository read; --branch would expand @ and read HEAD)
bad = [n for n in names if M.branch_ok(n) != (subprocess.run(["git", "check-ref-format", "refs/heads/" + n], capture_output=True).returncode == 0)]
print("differ: %s" % bad if bad else "same")
print("dash: %s at: %s" % (M.branch_ok("-x"), M.branch_ok("@")))
PY
)
  has "$out" "same" "[O] branch_ok agrees with git check-ref-format --branch on every case"
  has "$out" "dash: False at: False" "[O] …and refuses '-x' and '@', legal ref names that git branch refuses or reads as HEAD"
  d=$(mkfx); guard "$PL" "$d" "${STD[@]}" --mer
  eq "$RC" 64 "[O] an abbreviation of --merge is not --merge: rc 64"
  eq "$(merges "$d")" 0 "[O] …and nothing merged"
}

fam_merge() {
  PL=$1; local d
  d=$(mkfx); guard "$PL" "$d" "${STD[@]}" --merge
  eq "$RC" 0 "[M] --merge on the all-green PR: rc 0"
  eq "$(merges "$d")" 1 "[M] …exactly one pr merge call"
  has "$(grep '^\["pr", "merge"' "$d/gh.log")" "\"--match-head-commit\", \"$H\"" "[M] …carrying --match-head-commit and the full head"
  has "$(grep '^\["pr", "merge"' "$d/gh.log")" '"--squash"' "[M] …as a squash merge"
  hasnt "$(grep '^\["pr", "merge"' "$d/gh.log")" '"--admin"' "[M] …without --admin"
  has "$OUT" "MERGED" "[M] …and the merge is reported"
  d=$(mkfx admin-on); guard "$PL" "$d" "${STD[@]}" --merge --admin
  has "$(grep '^\["pr", "merge"' "$d/gh.log")" '"--admin"' "[M] --admin with admin bypass on reaches gh pr merge"
  d=$(mkfx moved-head); guard "$PL" "$d" "${STD[@]}" --merge
  eq "$RC" 2 "[M] the head moved after the check: GitHub refuses the pinned merge, rc 2"
  eq "$(merges "$d")" 1 "[M] …one attempt"; [ ! -f "$d/merged.json" ] && ok "[M] …and nothing merged" || bad "[M] …and nothing merged"
  d=$(mkfx file=lib/x.py); guard "$PL" "$d" "${STD[@]}" --merge
  eq "$RC:$(merges "$d")" "1:0" "[M] --merge with a failed condition: rc 1, no pr merge call"
  d=$(mkfx)
  guard "$PL" "$d" "${STD[@]}"; guard "$PL" "$d" "${STD[@]}" --accept 'x:y'; guard "$PL" "$d" "${STD[@]}" --admin
  eq "$(loglines "$d")" 3 "[M] three runs (pass, pass, usage): three merge-log lines"
  guard "$PL" "$d" "${STD[@]}" --merge
  eq "$(loglines "$d")" 4 "[M] a merge run: one more line"
  has "$(tail -n 1 "$d/state/vibemaestro/merge-log.jsonl")" '"result": "merged"' "[M] …its result is merged"
  hasnt "$(cat "$d/state/vibemaestro/merge-log.jsonl")" "MUST-NOT-BE-LOGGED" "[M] no merge-log line holds the PR's title or body"
  python3 -c 'import json,sys
for l in open(sys.argv[1]): d = json.loads(l); assert {"time", "repo", "pr", "head", "lane", "admin", "conditions", "result"} <= set(d)' \
    "$d/state/vibemaestro/merge-log.jsonl" && ok "[M] every line is JSON with the spec's fields" || bad "[M] every line is JSON with the spec's fields"
  [ "$(stat -c %a "$d/state/vibemaestro/merge-log.jsonl" 2>/dev/null || stat -f %Lp "$d/state/vibemaestro/merge-log.jsonl")" = 600 ] \
    && ok "[M] the merge log is mode 600" || bad "[M] the merge log is mode 600"
  d=$(mkfx); mkdir -p "$d/state"; printf 'x' > "$d/state/vibemaestro"
  guard "$PL" "$d" "${STD[@]}" --merge
  eq "$RC:$(merges "$d")" "2:0" "[M] a merge log that cannot be written: rc 2 before any merge"
  d=$(mkfx); guard "$PL" "$d" "${STD[@]}"; printf '%s\n' "$OUT" | sed -n 's/^merge-plan: //p' > "$d/plan.txt"
  printf 'merge something else\n' > "$d/other.txt"
  guard "$PL" "$d" "${STD[@]}" --merge --expect-plan other.txt
  eq "$RC:$(merges "$d")" "1:0" "[M] --merge with a plan other than the signed one: rc 1, no pr merge call"
  has "$OUT" "FAIL  signed-plan:" "[M] …named signed-plan"
  guard "$PL" "$d" "${STD[@]}" --merge --expect-plan plan.txt
  eq "$RC:$(merges "$d")" "0:1" "[M] --merge with the plan it computes itself: merged"
  d=$(mkfx merge-mode=queue); guard "$PL" "$d" "${STD[@]}" --merge
  eq "$RC" 2 "[M] gh pr merge exits 0 but the PR stays open (a merge queue): rc 2"
  has "$(tail -n 1 "$d/state/vibemaestro/merge-log.jsonl")" '"result": "merge-pending"' "[M] …logged as merge-pending"
  guard "$PL" "$d" --repo acme/app --pr 7 --head "$H" --status
  eq "$OUT" "pending head $H" "[M] …--status says pending (the merge may still happen), not open"
  d=$(mkfx merge-mode=queue); guard "$PL" "$d" "${STD[@]}" --merge; guard "$PL" "$d" "${STD[@]}" --merge --require-image cc1-node22-r17
  eq "$RC" 1 "[M] a later merge run of the same head, refused: rc 1"
  guard "$PL" "$d" --repo acme/app --pr 7 --head "$H" --status
  eq "$OUT" "pending head $H" "[M] …--status still says pending (a later refused run does not clear it)"
  d=$(mkfx); python3 -B "$HERE/fixtures/merge_fx.py" "$d/fx2.json" --skill "$SKILL" base-other
  OUT=$(cd "$d" && cenv XDG_STATE_HOME="$d/state" FAKE_GH_FX="$d/fx.json" FAKE_GH_FX2="$d/fx2.json" FAKE_GH_SWAP_AT=1 \
        FAKE_GH_LOG="$d/gh.log" FAKE_GH_STATE="$d/merged.json" python3 -B "$PL/gates/merge_guard.py" "${STD[@]}" --merge 2>&1); RC=$?
  eq "$RC:$(merges "$d")" "1:0" "[M] the PR retargeted to another branch after the check: rc 1, no pr merge call"
  has "$OUT" "FAIL  base:" "[M] …named base"
  d=$(mkfx merge-mode=auto); guard "$PL" "$d" "${STD[@]}" --merge; guard "$PL" "$d" --repo acme/app --pr 7 --head "$H" --status
  eq "$OUT" "queued head $H" "[M] an auto-merge request: --status says queued"
  d=$(mkfx merge-hang=5); GENV=(MERGE_GUARD_GH_TIMEOUT_S=1); guard "$PL" "$d" "${STD[@]}" --merge; GENV=()
  eq "$RC:$(merges "$d")" "2:2" "[M] gh pr merge does not answer in time: read back (open at the head), one more try, rc 2"
  has "$OUT" "gh pr merge failed (no answer: gh pr merge timed out after 1s) and the PR, read again after 0s, is still open at head $H: one more try" \
      "[M] …a call gh did not answer may have landed: read back like a 5xx"
  has "$(tail -n 1 "$d/state/vibemaestro/merge-log.jsonl")" '"result": "merge-pending"' "[M] …logged as merge-pending (the request may have reached GitHub)"
  guard "$PL" "$d" --repo acme/app --pr 7 --head "$H" --status
  eq "$OUT" "pending head $H" "[M] …--status says pending"
  d=$(mkfx merge-mode=queue); guard "$PL" "$d" "${STD[@]}" --merge
  python3 - "$d/fx.json" <<'PY'
import json, sys
fx = json.load(open(sys.argv[1])); fx.setdefault("fail", {})["repos/acme/app/git/ref/heads/main"] = "boom"; json.dump(fx, open(sys.argv[1], "w"))
PY
  guard "$PL" "$d" --repo acme/app --pr 7 --head "$H" --status
  eq "$RC" 2 "[M] --status when the base config cannot be read: rc 2 (could not conclude), never 'open'"
  hasnt "$OUT" "open head" "[M] …and it does not print open"
  d=$(mkfx); mkdir -p "$d/state/vibemaestro/merge-log.jsonl"; guard "$PL" "$d" --repo acme/app --pr 7 --head "$H" --status
  eq "$RC" 2 "[M] --status when the merge log cannot be read: rc 2"
  d=$(mkfx view-fails-after-merge); guard "$PL" "$d" "${STD[@]}" --merge
  eq "$RC:$(merges "$d")" "2:1" "[M] merged, then the state cannot be read: rc 2"
  has "$(tail -n 1 "$d/state/vibemaestro/merge-log.jsonl")" '"result": "merged-unconfirmed"' "[M] …logged as merged-unconfirmed"
  eq "$(loglines "$d")" 1 "[M] …in one line"
  d=$(mkfx); guard "$PL" "$d" --repo acme/app --pr 7 --head "$H" --status
  eq "$RC:$OUT" "0:open head $H" "[M] --status of an open PR"
  guard "$PL" "$d" "${STD[@]}" --merge; guard "$PL" "$d" --repo acme/app --pr 7 --head "$H" --status
  eq "$OUT" "merged ffffffffffffffffffffffffffffffffffffffff head $H" "[M] --status of a merged PR"
  eq "$(loglines "$d")" 1 "[M] --status writes no merge-log line"
  d=$(mkfx merge-5xx=landed); guard "$PL" "$d" "${STD[@]}" --merge
  eq "$RC:$(merges "$d")" "0:1" "[M] gh pr merge answers HTTP 502, but the merge landed at the head: rc 0, one pr merge call"
  has "$OUT" "gh pr merge failed (HTTP 502), but the PR reads MERGED at head $H: the merge landed" "[M] …it names the 502 and the read-back"
  has "$(tail -n 1 "$d/state/vibemaestro/merge-log.jsonl")" '"result": "merged"' "[M] …logged as merged"
  d=$(mkfx merge-5xx=landed after-merge-head); guard "$PL" "$d" "${STD[@]}" --merge
  eq "$RC:$(merges "$d")" "2:1" "[M] HTTP 502, and the PR reads merged at another head: rc 2, not tried again"
  has "$OUT" "gh pr merge failed (HTTP 502) and the PR reads MERGED at head $H2 into main: not merged at the head and base; the state is unknown, tell the owner" \
      "[M] …it names what it read, the state unknown"
  d=$(mkfx merge-5xx=landed view-fails-after-merge); guard "$PL" "$d" "${STD[@]}" --merge
  eq "$RC:$(merges "$d")" "2:1" "[M] HTTP 502, and the PR cannot be read back (asked 3 times): rc 2"
  has "$OUT" "gh pr merge failed (HTTP 502) and the PR cannot be read back: it may have merged; the state is unknown, tell the owner" \
      "[M] …it says it may have merged, not refused"
  has "$(tail -n 1 "$d/state/vibemaestro/merge-log.jsonl")" '"result": "merge-pending"' "[M] …logged as merge-pending"
  d=$(mkfx merge-5xx=lost,raced after-merge-head); guard "$PL" "$d" "${STD[@]}" --merge
  eq "$RC:$(merges "$d")" "2:2" "[M] HTTP 502, then another hand merges another head and the retry exits 0 (already merged): rc 2"
  has "$OUT" "gh pr merge exited 0 on the second try and the PR reads MERGED at head $H2 into main" "[M] …the retry's exit 0 is read again"
  d=$(mkfx merge-5xx=lost,lost); guard "$PL" "$d" "${STD[@]}" --merge
  eq "$RC:$(merges "$d")" "2:2" "[M] HTTP 502 twice, the PR still open at the head: one more try, then rc 2"
  has "$OUT" "gh pr merge failed (HTTP 502) and the PR, read again after 0s, is still open at head $H: one more try" "[M] …it names the retry"
  has "$OUT" "an earlier call may still land: tell the owner" "[M] …the refused stop says an earlier call may still land"
  has "$(tail -n 1 "$d/state/vibemaestro/merge-log.jsonl")" '"result": "merge-pending"' "[M] …logged as merge-pending (N1a: it may still land)"
  guard "$PL" "$d" --repo acme/app --pr 7 --head "$H" --status
  eq "$OUT" "pending head $H" "[M] …--status says pending, never open"
  d=$(mkfx merge-5xx=dropped); guard "$PL" "$d" "${STD[@]}" --merge
  eq "$RC:$(merges "$d")" "0:1" "[M] the merge lands, then gh loses the connection (http2: client connection lost): rc 0 (B1)"
  has "$OUT" "gh pr merge failed (an error that is not GitHub's refusal), but the PR reads MERGED at head $H: the merge landed" \
      "[M] …any error but GitHub's refusal may have landed"
  d=$(mkfx merge-5xx=lost merge-mode=queue queue-head); guard "$PL" "$d" "${STD[@]}" --merge
  eq "$RC:$(merges "$d")" "2:2" "[M] HTTP 502, the second call queues it, then its head moves: rc 2 (D1)"
  has "$OUT" "gh pr merge exited 0 on the second try and the PR reads OPEN at head $H2 into main: not merged at the head and base; the state is unknown" \
      "[M] …the state unknown, not a queued merge"
  has "$(tail -n 1 "$d/state/vibemaestro/merge-log.jsonl")" '"result": "merge-pending"' "[M] …logged as merge-pending"
  d=$(mkfx merge-5xx=lost merge-mode=queue); guard "$PL" "$d" "${STD[@]}" --merge
  eq "$RC:$(merges "$d")" "2:2" "[M] HTTP 502, then the second call only queues it: rc 2"
  has "$(tail -n 1 "$d/state/vibemaestro/merge-log.jsonl")" '"result": "merge-pending"' "[M] …logged as merge-pending, as a first call that queues"
  guard "$PL" "$d" --repo acme/app --pr 7 --head "$H" --status
  eq "$OUT" "pending head $H" "[M] …--status says pending"
  d=$(mkfx after-merge-base=release); guard "$PL" "$d" "${STD[@]}" --merge
  eq "$RC:$(merges "$d")" "2:1" "[M] gh pr merge exits 0, but the PR reads merged into another base: rc 2"
  has "$OUT" "gh pr merge exited 0, but the PR reads merged at head $H into release, not $H into main: tell the owner" "[M] …naming the base"
  d=$(mkfx merge-5xx=lost); guard "$PL" "$d" "${STD[@]}" --merge
  eq "$RC:$(merges "$d")" "0:2" "[M] HTTP 502 once, the PR still open: the second try merges, rc 0"
}

# bt <plugin> <case dir> <baton args...> — baton.py from the case directory, the fake gh, mode state in <case>/state; OUT, RC
BT_SWAP=()
bt() {
  local pl=$1 d=$2; shift 2
  if [ $# -eq 2 ] && [ "$1" = mode ]; then baton_set_mode "$d/state" "$2"; OUT=""; RC=0; return; fi
  OUT=$(cd "$d" && cenv XDG_STATE_HOME="$d/state" FAKE_GH_FX="$d/fx.json" FAKE_GH_LOG="$d/gh.log" FAKE_GH_STATE="$d/merged.json" \
        ${BT_SWAP[@]+"${BT_SWAP[@]}"} python3 -B "$pl/scripts/baton.py" "$@" 2>&1); RC=$?
}
seal_of() { printf '%s\n' "$OUT" | sed -n 's/^seal \([^ ]*\) .*/\1/p'; }
nsig() { find "$1/state/vibemaestro/baton/signatures" -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }

fam_baton() {
  PL=$1; local d seal KA
  KA=(kit:merge-pr --repo acme/app --pr 7 --head "$H" --brief brief.txt)
  d=$(mkfx); bt "$PL" "$d" check kit:merge-pr
  eq "$RC" 0 "[T] baton check kit:merge-pr: rc 0"
  bt "$PL" "$d" rehearse "${KA[@]}"
  eq "$RC" 0 "[T] rehearse kit:merge-pr: rc 0"
  has "$OUT" "  ok    head: headRefOid" "[T] …the rehearse is the guard's dry run (its condition lines)"
  has "$OUT" "PLAN merge acme/app#7 head $H into main@b0b0b0b0b0b0" "[T] …one PLAN line, the guard's merge-plan"
  eq "$(printf '%s\n' "$OUT" | grep -c '^  PLAN ')" 1 "[T] …exactly one planned write"
  eq "$(merges "$d")" 0 "[T] …and rehearse makes no pr merge call"
  seal=$(seal_of); bt "$PL" "$d" mode auto
  bt "$PL" "$d" sign --by coordinator-auto --seal "${seal:-none}" "${KA[@]}"
  eq "$RC" 0 "[T] mode auto: sign --by coordinator-auto (Stops: none): rc 0"
  bt "$PL" "$d" run "${KA[@]}"
  eq "$RC" 0 "[T] run kit:merge-pr: rc 0"
  eq "$(merges "$d")" 1 "[T] …exactly one pr merge call"
  has "$(grep '^\["pr", "merge"' "$d/gh.log")" "\"--match-head-commit\", \"$H\"" "[T] …pinned to the head"
  # `run` prints one line when it holds: the post-check verdict is in the run log that line names
  has "$(cat "$(printf '%s\n' "$OUT" | sed -n 's/^run: ok — [0-9]* writes\{0,1\} — //p')" 2>/dev/null)" "VERDICT postcheck ok" "[T] …and the post-check read the merged state"
  bt "$PL" "$d" run "${KA[@]}"
  eq "$RC:$(merges "$d")" "3:1" "[T] a second run: refused (rc 3), still one merge call"
  d=$(mkfx file=deploy/app.yaml); bt "$PL" "$d" mode auto; bt "$PL" "$d" rehearse "${KA[@]}" --allow 'deploy/**'
  eq "$RC" 1 "[T] a PR touching a deny glob: rehearse fails (rc 1)"
  has "$OUT" "FAIL  deny:" "[T] …the guard names deny"
  bt "$PL" "$d" sign --by coordinator-auto --seal 0123456789abcdef.0123456789abcdef "${KA[@]}" --allow 'deploy/**'
  eq "$RC:$(nsig "$d")" "1:0" "[T] …it cannot be signed: refused, not escalated (no signature)"
  d=$(mkfx); bt "$PL" "$d" rehearse "${KA[@]}" --merge
  eq "$RC:$(merges "$d")" "1:0" "[T] --merge among the baton's arguments: refused at rehearse, nothing merged"
  d=$(mkfx after-merge-head); bt "$PL" "$d" mode auto; bt "$PL" "$d" rehearse "${KA[@]}"; seal=$(seal_of)
  bt "$PL" "$d" sign --by coordinator-auto --seal "${seal:-none}" "${KA[@]}"; bt "$PL" "$d" run "${KA[@]}"
  eq "$RC" 5 "[T] merged, but the post-check reads another head: rc 5 (undo cannot un-merge: tell the owner)"
  has "$OUT" "revert" "[T] …undo says the way back is a revert PR"
  d=$(mkfx merge-5xx=landed); bt "$PL" "$d" mode auto; bt "$PL" "$d" rehearse "${KA[@]}"; seal=$(seal_of)
  bt "$PL" "$d" sign --by coordinator-auto --seal "${seal:-none}" "${KA[@]}"; bt "$PL" "$d" run "${KA[@]}"
  eq "$RC:$(merges "$d")" "0:1" "[T] gh pr merge answers HTTP 502, but the merge landed at the head: run rc 0, one merge call"
  has "$OUT" "run: ok" "[T] …run: ok"
  # undo of a run that failed after its merge landed at the signed head: the phase alone, on that merged state
  OUT=$(cd "$d" && cenv XDG_STATE_HOME="$d/state" FAKE_GH_FX="$d/fx.json" FAKE_GH_LOG="$d/gh.log" FAKE_GH_STATE="$d/merged.json" \
        BATON_PHASE=undo BATON_PLUGIN_ROOT="$PL" bash "$PL/batons/merge-pr.sh" "${KA[@]:1}" 2>&1); RC=$?
  eq "$RC" 1 "[T] undo, the PR merged at the signed head: rc 1 (tell the owner)"
  has "$OUT" "merged at the signed head $H, by this run or another hand (the base is not read here): the run did not confirm it; tell the owner, who decides whether it stays (no revert before that)" "[T] …it leaves the decision to the owner"
  hasnt "$OUT" "open a revert PR" "[T] …and advises no revert"
  d=$(mkfx moved-head); bt "$PL" "$d" mode auto; bt "$PL" "$d" rehearse "${KA[@]}"; seal=$(seal_of)
  bt "$PL" "$d" sign --by coordinator-auto --seal "${seal:-none}" "${KA[@]}"; bt "$PL" "$d" run "${KA[@]}"
  eq "$RC" 4 "[T] the head moved before the run's merge: GitHub refuses, nothing merged, undo confirms it (rc 4)"
  d=$(mkfx behind=ops/notes.txt); python3 -B "$HERE/fixtures/merge_fx.py" "$d/fx2.json" --skill "$SKILL" behind=ops/notes.txt base-moved
  bt "$PL" "$d" mode auto; bt "$PL" "$d" rehearse "${KA[@]}" --behind-ok 'ops/**'; seal=$(seal_of)
  bt "$PL" "$d" sign --by coordinator-auto --seal "${seal:-none}" "${KA[@]}" --behind-ok 'ops/**'
  n=$(cat "$d/gh.log.swap"); BT_SWAP=(FAKE_GH_FX2="$d/fx2.json" FAKE_GH_SWAP_AT=$((n + 2)))
  bt "$PL" "$d" run "${KA[@]}" --behind-ok 'ops/**'; BT_SWAP=()
  eq "$(merges "$d")" 0 "[T] the base moves between the run's own rehearse and its merge: no pr merge call (the signed plan is checked first)"
  eq "$RC" 4 "[T] …the run fails and undo confirms nothing merged (rc 4)"
  d=$(mkfx merge-mode=queue); bt "$PL" "$d" mode auto; bt "$PL" "$d" rehearse "${KA[@]}"; seal=$(seal_of)
  bt "$PL" "$d" sign --by coordinator-auto --seal "${seal:-none}" "${KA[@]}"; bt "$PL" "$d" run "${KA[@]}"
  eq "$RC" 5 "[T] a merge that a queue may still do: rc 5 (undo cannot say nothing merged)"
  d=$(mkfx); bt "$PL" "$d" mode auto; bt "$PL" "$d" go "${KA[@]}"
  eq "$RC:$(merges "$d")" "0:1" "[T] go kit:merge-pr: rc 0, one merge"
  eq "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" 1 "[T] …go prints one line"
  has "$OUT" "go: ok — 1 write — $d/state/vibemaestro/baton/runs/" "[T] …'go: ok — 1 write — <run log>'"
  d=$(mkfx file=deploy/app.yaml); bt "$PL" "$d" mode auto; bt "$PL" "$d" go "${KA[@]}" --allow 'deploy/**'
  eq "$RC:$(merges "$d")" "1:0" "[T] go on a PR touching a deny glob: rc 1, nothing merged"
  has "$OUT" "FAIL  deny:" "[T] …go prints the failing rehearse whole (the guard names deny)"
  d=$(mkfx shared=$LED); bt "$PL" "$d" rehearse "${KA[@]}" "${CL[@]}"
  eq "$RC" 0 "[T] rehearse kit:merge-pr --behind-ok-clean: rc 0"
  has "$OUT" "accepted clean: $LED" "[T] …the baton passes --behind-ok-clean to the guard"
  d=$(mkfx); OUT=$(cd "$d" && cenv FAKE_GH_FX="$d/fx.json" FAKE_GH_LOG="$d/gh.log" bash "$PL/batons/merge-pr.sh" "${KA[@]:1}" 2>&1); RC=$?
  ne "$RC" 0 "[T] the kit baton run with plain bash (no baton): refused"
  eq "$(merges "$d")" 0 "[T] …nothing merged"
}

# the back-merge lane: a backmerge/* PR into the default branch whose head is on release merges with a merge commit; nothing else does
mlog() { grep '^\["pr", "merge"' "$1/gh.log"; }
fam_backmerge() {
  PL=$1; local d
  d=$(mkfx backmerge=on); guard "$PL" "$d" "${STD[@]}" --merge
  eq "$RC" 0 "[L1] a backmerge/* PR into the default branch, its head on release: rc 0"
  has "$(mlog "$d")" '"--merge"' "[L1] …merged with a merge commit (--merge)"
  hasnt "$(mlog "$d")" '"--squash"' "[L1] …not squashed"
  has "$(mlog "$d")" "\"--match-head-commit\", \"$H\"" "[L1] …still pinned to the head"
  has "$OUT" "into main@b0b0b0b0b0b0 merge-commit lane normal" "[L1] …and the plan line says merge-commit (so the signature binds it)"
  d=$(mkfx backmerge=identical); guard "$PL" "$d" "${STD[@]}" --merge
  eq "$RC:$(mlog "$d" | grep -c '"--merge"')" "0:1" "[L1b] a back-merge whose head is the release tip: rc 0, a merge commit"
  alone "[L2] a backmerge/* PR whose head is not on release" backmerge backmerge=off
  alone "[L3] a backmerge/* PR and no branch release" backmerge backmerge=none
  has "$OUT" "follow-up creates it" "[L3] …and the refusal names the follow-up that creates release"
  alone "[L4] a PR into the default branch whose head is on release, from a branch that is not backmerge/*" backmerge on-release=on
  d=$(mkfx backmerge=on release-flaky=1); guard "$PL" "$d" "${STD[@]}" --merge
  eq "$RC:$(grep '/compare/' "$d/gh.log" | grep -vc "$B0")" "0:2" "[L9] the head's comparison with release fails once with HTTP 500, then answers: rc 0, asked twice"
  has "$(mlog "$d")" '"--merge"' "[L9] …and the back-merge lane still merges with a merge commit"
  d=$(mkfx backmerge=on release-flaky=9); guard "$PL" "$d" "${STD[@]}" --merge
  eq "$RC:$(grep '/compare/' "$d/gh.log" | grep -vc "$B0"):$(merges "$d")" "2:4:0" "[L9] …HTTP 500 every time: asked 4 times, rc 2, no pr merge call"
  has "$OUT" "[transient: HTTP 500 on all 4 attempts; run it again later]" "[L9] …and backmerge says it is transient"
  d=$(mkfx on-release=off); guard "$PL" "$d" "${STD[@]}" --merge
  eq "$RC" 0 "[L5] a PR whose head is not on release, release present: rc 0"
  has "$(mlog "$d")" '"--squash"' "[L5] …squashed"
  has "$OUT" "squash lane normal" "[L5] …and the plan line says squash"
  d=$(mkfx base-other backmerge=on); guard "$PL" "$d" "${STD[@]}" --base scratch --merge
  eq "$RC" 0 "[L7] a backmerge/* PR into a branch that is not the default: rc 0"
  has "$(mlog "$d")" '"--squash"' "[L7] …squashed (the lane is for the default branch only)"
  d=$(mkfx default-branch=trunk backmerge=on); guard "$PL" "$d" "${STD[@]}" --merge
  eq "$RC" 0 "[L8] a back-merge into a default branch named trunk, not main: rc 0"
  has "$(mlog "$d")" '"--merge"' "[L8] …a merge commit: the default branch, whatever its name"
}

# ── [A] --behind auto: (a) a fresh test merge, (b) disjoint files or a shared docs file merged clean, (c) disjoint suites ──
# The planner is the kit's real tests/plan.py with a small map (tests/fixtures/merge_fx.py MAP): the PR's src/app.py wakes app,
# its docs/x.md docs-check, and CI plans @always plan for it; lib/* wakes lib; src/core/* app; ops/*, kb/* and .vibemaestro/*
# are excluded; tests/plan.py is @full. The base's side is asked with --woken, the PR's as CI plans it.
AU=(--behind auto)
AT=(--allow 'tests/**,kb/**')
B0=b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0
plan_of() { printf '%s\n' "$OUT" | grep '^merge-plan: '; }
fam_auto() {
  PL=$1; local d mk
  d=$(mkfx planner auto behind=lib/y.py,ops/a.yaml); guard "$PL" "$d" "${STD[@]}" "${AU[@]}"
  eq "$RC" 0 "[A] disjoint: the base's lib/y.py (lib) and ops/a.yaml (excluded) against the PR's app, docs-check, plan: rc 0"
  has "$(plan_of)" " behind 2 auto " "[A] …the plan line says behind 2 auto, so the signer sees the mode"
  has "$OUT" "(c) the base's files wake: lib" "[A] …the base's side is printed"
  has "$OUT" "(c) this PR's files wake: app docs-check plan" "[A] …and the PR's, the @always set included (its CI ran it)"
  has "$(tail -n 1 "$d/state/vibemaestro/merge-log.jsonl")" '"behind_auto": true' "[A] …logged as --behind auto"
  has "$(tail -n 1 "$d/state/vibemaestro/merge-log.jsonl")" '"suites": {"base": ["lib"], "pr": ["app", "docs-check", "plan"]}' "[A] …with both sides' suites"
  has "$(cat "$d/gh.log")" "contents/tests/plan.py?ref=$B0" "[A] …the planner was read at the base tip"
  hasnt "$(cat "$d/gh.log")" "?ref=$H\"" "[A] …and nothing at the head"
  # this repository's own merge.planner (a published export has no config): without one, main's lib/y.py is code and blocks
  if [ -f "$SRC_ROOT/.vibemaestro/sdlc.json" ]; then
    d=$(mkfx planner=repo auto behind=lib/y.py); guard "$PL" "$d" "${STD[@]}" "${AU[@]}"
    eq "$RC" 0 "[A] this repository's merge.planner: the base's lib/y.py (lib) against the PR's app, docs-check, plan: rc 0"
    has "$OUT" "(c) the base's files and this PR's files wake no suite in common (planner tests/plan.py, read at the base)" "[A] …(c) asked the planner"
    alone "[A] this repository's merge.planner: the base's src/core/z.py wakes app, as the PR's src/app.py does" behind planner=repo auto behind=src/core/z.py -- "${AU[@]}"
    has "$OUT" "(c) the base's files and this PR's files wake the same suite(s): app" "[A] …refused for the shared suite"
  fi
  alone "[A] intersecting suites: the base's src/core/z.py wakes app, as the PR's src/app.py does" behind planner auto behind=src/core/z.py -- "${AU[@]}"
  has "$OUT" "(c) the base's files and this PR's files wake the same suite(s): app" "[A] …the shared suite is named under (c)"
  has "$OUT" "merge the base into the branch" "[A] …and the way on is to merge the base"
  alone "[A] the PR changed an @always suite's check (tests/plan-input.txt): it never read the base's lib/y.py" behind planner auto behind=lib/y.py file=tests/plan-input.txt -- "${AT[@]}" "${AU[@]}"
  has "$OUT" "this PR's files need every suite (\`tests/plan-input.txt\` changes @always suite plan, which reads every tracked file), and the base's files wake lib" "[A] …named under (c)"
  alone "[A] the base changed an @always suite's own file (tests/test-plan.sh): the PR's CI ran the old one" behind planner auto behind=tests/test-plan.sh -- "${AU[@]}"
  has "$OUT" "wake the same suite(s): plan" "[A] …named under (c)"
  alone "[A] main's map moved src/new/* onto web, and the PR changes src/new/x.py: web never ran on it" behind planner base-map file=src/new/x.py auto -- "${AU[@]}"
  has "$OUT" "wake the same suite(s): api web" "[A] …the changed line's suite (and its @with) is on the base's side (--old: the merge base's map)"
  d=$(mkfx planner base-map auto); guard "$PL" "$d" "${STD[@]}" "${AU[@]}"
  eq "$RC" 0 "[A] main's map moved src/new/* onto web, and the PR's files are elsewhere: rc 0 (only the changed line counts)"
  has "$OUT" "(c) the base's files wake: api web" "[A] …the base's side is the changed line (and its @with)"
  has "$(cat "$d/gh.log")" "contents/tests/suites.map?ref=d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0" "[A] …the map before the change was read at the merge base"
  alone "[A] a PR that edits the map, behind main by only a file the base map excludes" behind planner auto behind=ops/a.yaml head-map -- "${AT[@]}" "${AU[@]}"
  has "$OUT" "the base's files are ops/a.yaml" "[A] …refused: the PR's own map may read it"
  d=$(mkfx planner auto); guard "$PL" "$d" "${STD[@]}" "${AU[@]}"
  eq "$RC" 0 "[A] not behind: rc 0, unchanged"
  hasnt "$(cat "$d/gh.log")" "pulls/7\"" "[A] …and no test merge read"
  d=$(mkfx planner shared=$LED auto); guard "$PL" "$d" "${STD[@]}" "${AT[@]}" "${AU[@]}"
  eq "$RC" 0 "[A] a shared docs file that merges clean and that no suite reads (kb/current-state.md, excluded): rc 0"
  has "$OUT" "(b) accepted clean: $LED" "[A] …accepted clean under (b)"
  has "$OUT" "the merged current-state passes its check" "[A] …after the current-state check on the merged text"
  has "$(plan_of)" " clean 1" "[A] …counted in the plan line"
  alone "[A] a shared docs file that merges clean, but a suite reads it that the PR's files wake too" behind planner shared=docs/guide.md auto -- "${AU[@]}"
  has "$OUT" "(b) accepted clean: docs/guide.md" "[A] …clean under (b)"; has "$OUT" "wake the same suite(s): docs-check" "[A] …refused under (c): its merged text is new to docs-check"
  alone "[A] a shared planner map that merges clean (the merged map may not parse)" behind planner shared-map auto base-also=lib/y.py -- "${AT[@]}" "${AU[@]}"
  has "$OUT" "tests/suites.map (not docs" "[A] …refused under (b): only docs merge clean"
  alone "[A] a shared docs file that conflicts" behind planner shared=docs/guide.md:conflict auto -- "${AU[@]}"
  has "$OUT" "(b)" "[A] …refused under (b)"; has "$OUT" "1 conflict(s)" "[A] …the conflict is named"
  alone "[A] a shared code file that merges clean" behind planner shared=src/lib.py auto -- "${AU[@]}"
  has "$OUT" "src/lib.py (not docs" "[A] …refused: code is not a clean class"
  alone "[A] a shared CLAUDE.md that merges clean (an agent loads it as instructions)" behind planner shared=CLAUDE.md auto -- --allow 'CLAUDE.md' "${AU[@]}"
  has "$OUT" "CLAUDE.md (not docs" "[A] …refused under (b): not in the docs class"
  alone "[A] a shared .claude/x.md that merges clean (a dot-directory)" behind planner shared=.claude/x.md auto -- --allow '.claude/**' "${AU[@]}"
  has "$OUT" ".claude/x.md (not docs" "[A] …refused under (b): a dot-directory is not docs"
  for n in AGENT.md AGENTS.md AGENTS.override.md CLAUDE.local.md GEMINI.md QWEN.md CRUSH.md SKILL.md; do
    alone "[A] a shared $n that merges clean (no suite reads it)" behind planner shared=$n auto -- --allow "$n" "${AU[@]}"
    has "$OUT" "$n (not docs" "[A] …refused under (b): an agent's instruction file by name ($n)"
  done
  for g in skills agents commands rules prompts hooks; do
    alone "[A] a shared $g/x.md that merges clean (no suite reads it)" behind planner shared=$g/x.md auto -- --allow "$g/**" "${AU[@]}"
    has "$OUT" "$g/x.md (not docs" "[A] …refused under (b): a directory of agent instructions ($g/)"
  done
  for rd in guides/ ./guides guides/. Guides .; do
    alone "[A] a shared guides/x.md under the config's rules.dirs '$rd'" behind planner rules-dirs=$rd shared=guides/x.md auto -- --allow 'guides/**' "${AU[@]}"
    has "$OUT" "guides/x.md (not docs" "[A] …refused under (b): a rules directory of the config ('$rd')"
  done
  alone "[A] a shared docs file with no planner, merges clean, but main changed code too" behind shared=docs/guide.md auto base-also=lib/y.py -- "${AU[@]}"
  alone "[A] GitHub's fresh test merge reports a conflict" behind planner auto=conflict behind=lib/y.py -- "${AU[@]}"
  has "$OUT" "(a)" "[A] …refused under (a)"
  d=$(mkfx planner auto=conflict-null behind=lib/y.py); guard "$PL" "$d" "${STD[@]}" "${AU[@]}"
  eq "$RC" 1 "[A] GitHub reports a conflict and no test merge at all: rc 1 (FAIL, not could-not-conclude)"
  eq "$(grep -c '"repos/acme/app/pulls/7"\]' "$d/gh.log")" 1 "[A] …at the first read, with no wait"
  mk="$TMP/head-planner-ran"; rm -f "$mk"
  d=$(mkfx planner auto behind=lib/y.py head-planner="$mk"); guard "$PL" "$d" "${STD[@]}" "${AT[@]}" "${AU[@]}"
  eq "$RC" 1 "[A] a PR that edits tests/plan.py (its head copy would print no suite): rc 1"
  has "$OUT" "this PR's files need every suite" "[A] …the base's planner decides: tests/plan.py is @full there"
  [ -e "$mk" ] && bad "[A] …the head's planner ran (marker written)" || ok "[A] …the head's planner never ran (no marker)"
  hasnt "$(cat "$d/gh.log")" "contents/tests/plan.py?ref=$H" "[A] …and was never read"
  d=$(mkfx planner auto behind=src/core/z.py head-map); guard "$PL" "$d" "${STD[@]}" "${AT[@]}" "${AU[@]}"
  eq "$RC" 1 "[A] a PR that edits tests/suites.map (its head map would move src/core/* off app): rc 1"
  has "$OUT" "this PR's files need every suite" "[A] …its map is never read, so a changed map counts as every suite"
  hasnt "$(cat "$d/gh.log")" "contents/tests/suites.map?ref=$H" "[A] …the head's map was never read"
  d=$(mkfx auto behind=docs/other.md,kb/notes.md); guard "$PL" "$d" "${STD[@]}" "${AU[@]}"
  eq "$RC" 0 "[A] no planner: base files that are all docs: rc 0"
  has "$OUT" "(c) no planner (merge.planner): every base file is docs" "[A] …the fallback is named"
  alone "[A] no planner: a base file that is code" behind auto behind=docs/other.md,lib/y.py -- "${AU[@]}"
  has "$OUT" "no planner (merge.planner): base file(s) that are not docs may change what this PR's tests see: lib/y.py" "[A] …named"
  alone "[A] bootstrap: the PR's own config names a planner, which is not used (no-planner rule)" behind planner bootstrap auto behind=lib/y.py -- "${BA[@]}" "${AU[@]}"
  has "$OUT" "(c) bootstrap: merge.planner is in the config this PR adds, so it is not used" "[A] …named"
  GENV=(GH_TOKEN=probe-secret GITHUB_TOKEN=probe-secret)
  d=$(mkfx planner=probe auto behind=lib/y.py); guard "$PL" "$d" "${STD[@]}" "${AU[@]}"; GENV=()
  eq "$RC" 0 "[A] the planner runs with no token, no PATH, HOME its own directory and no socket (a probe planner): rc 0"
  d=$(mkfx planner=link auto behind=lib/y.py); guard "$PL" "$d" "${STD[@]}" "${AU[@]}"
  eq "$RC" 2 "[A] a planner input that is a symlink at the base: rc 2 (could not conclude)"
  has "$OUT" "not regular files at the base" "[A] …named"
  d=$(mkfx planner=missing auto behind=lib/y.py); guard "$PL" "$d" "${STD[@]}" "${AU[@]}"
  eq "$RC" 2 "[A] a planner input missing at the base: rc 2"
  d=$(mkfx planner auto behind=lib/y.py); guard "$PL" "$d" "${STD[@]}" "${AU[@]}" --behind-ok 'lib/**'
  eq "$RC" 64 "[A] --behind auto with --behind-ok: rc 64"
  guard "$PL" "$d" "${STD[@]}" "${AU[@]}" --behind-ok-clean 'docs/**/*.md'
  eq "$RC" 64 "[A] --behind auto with --behind-ok-clean: rc 64"
  guard "$PL" "$d" "${STD[@]}" --behind maybe
  eq "$RC" 64 "[A] --behind with another value than auto: rc 64"
  d=$(mkfx planner auto behind=lib/y.py); bt "$PL" "$d" rehearse kit:merge-pr --repo acme/app --pr 7 --head "$H" --brief brief.txt "${AU[@]}"
  eq "$RC" 0 "[A] kit:merge-pr rehearse with --behind auto: rc 0"
  has "$OUT" " behind 2 auto " "[A] …the baton passes --behind auto to the guard (its PLAN line)"
}

# the stale test merge: GitHub does not always rebuild it after main moves, so the compare API decides and a stale one alone
# never refuses; only a file both sides changed waits for it (real waits between the re-asks, so a family of its own)
fam_auto_stale() {
  PL=$1; local d
  d=$(mkfx auto=stale behind=docs/other.md,kb/notes.md); guard "$PL" "$d" "${STD[@]}" "${AU[@]}"
  eq "$RC" 0 "[A] a stale test merge, main changed docs only: rc 0 (behind ok)"
  has "$OUT" "(a) test merge not fresh: not needed" "[A] …the stale test merge is named and not needed"
  eq "$(grep -c '"repos/acme/app/pulls/7"\]' "$d/gh.log")" 1 "[A] …GitHub was asked once, with no wait"
  d=$(mkfx planner auto=stale behind=lib/y.py); guard "$PL" "$d" "${STD[@]}" "${AU[@]}"
  eq "$RC" 0 "[A] a stale test merge, the planner finds disjoint suites: rc 0 (was rc 2: the removed behaviour)"
  alone "[A] a stale test merge, main changed a code file (no planner)" behind auto=stale behind=docs/other.md,lib/y.py -- "${AU[@]}"
  has "$OUT" "base file(s) that are not docs may change what this PR's tests see: lib/y.py" "[A] …refused under (c), as with a fresh one"
  alone "[A] a stale test merge, main changed a file that wakes the PR's suite" behind planner auto=stale behind=src/core/z.py -- "${AU[@]}"
  has "$OUT" "wake the same suite(s): app" "[A] …refused under (c)"
  alone "[A] a stale test merge, a code file both sides changed" behind planner shared=src/lib.py auto=stale -- "${AU[@]}"
  has "$OUT" "src/lib.py (not docs" "[A] …refused under (b): code is not a clean class"
  d=$(mkfx planner shared=$LED auto=stale); guard "$PL" "$d" "${STD[@]}" "${AT[@]}" "${AU[@]}"
  eq "$RC" 2 "[A] a stale test merge, a docs file both sides changed: rc 2 (the second opinion is missing)"
  has "$OUT" "$LED: cannot cross-check git's merge with GitHub's test merge" "[A] …the file is named"
  has "$OUT" "still stale after 4 read(s)" "[A] …after the re-asks"
  eq "$(grep -c '"repos/acme/app/pulls/7"\]' "$d/gh.log")" 4 "[A] …GitHub was asked 4 times"
  d=$(mkfx planner shared=$LED auto=late); guard "$PL" "$d" "${STD[@]}" "${AT[@]}" "${AU[@]}"
  eq "$RC" 0 "[A] stale, then no test merge, then fresh on the third read, a docs file both sides changed: rc 0"
  eq "$(grep -c '"repos/acme/app/pulls/7"\]' "$d/gh.log")" 3 "[A] …three reads"
  alone "[A] a stale test merge that says mergeable false" behind planner auto=stale-conflict behind=lib/y.py -- "${AU[@]}"
  has "$OUT" "(a) GitHub reports this PR does not merge with its base" "[A] …is still a conflict: a refusal only asks for the base to be merged"
  # names the compare lists cannot show as a conflict: a file where the other side has a directory, names that differ in case
  for st in auto auto=stale; do
    alone "[A] ($st) the base adds docs/x.md/sub.md, a directory where this PR adds the file docs/x.md" behind planner $st behind=docs/x.md/sub.md -- "${AU[@]}"
    has "$OUT" "this PR's file docs/x.md is a directory in the base (docs/x.md/sub.md)" "[A] ($st) …the clash is named: a file of the PR, a directory in the base"
    alone "[A] ($st) the base adds a file named docs, where this PR has the directory docs/" behind planner $st behind=docs -- "${AU[@]}"
    has "$OUT" "the base's file docs is a directory in this PR (docs/x.md)" "[A] ($st) …the clash is named: a file of the base, a directory in the PR"
    alone "[A] ($st) the base adds docs/X.md, this PR adds docs/x.md" behind planner $st behind=docs/X.md -- "${AU[@]}"
    has "$OUT" "docs/X.md and docs/x.md differ only in case or Unicode form" "[A] ($st) …the clash is named: case only"
  done
  # a directory rename: a file moved out of a directory on one side, a path in that directory on the other
  for st in auto auto=stale; do
    alone "[A] ($st) the base moves docs/y.md to archive/y.md, this PR adds docs/x.md" behind planner $st base-rename=docs/y.md\>archive/y.md -- "${AU[@]}"
    has "$OUT" "the base moved docs/y.md to archive/y.md, a directory rename git may apply to this PR's" "[A] ($st) …the base's move is named"
    alone "[A] ($st) this PR moves docs/a/p.md to docs/b/p.md, the base changed docs/a/q.md" behind planner $st rename=docs/a/p.md:docs/b/p.md behind=docs/a/q.md -- "${AU[@]}"
    has "$OUT" "this PR moved docs/a/p.md to docs/b/p.md, a directory rename git may apply to the base's docs/a/q.md" "[A] ($st) …the PR's move is named"
  done
  alone "[A] the base moves docs/a/b/c/f.md to docs/x/y/c/f.md, this PR adds docs/a/b/other.md (git: file location conflict)" behind auto=stale base-rename=docs/a/b/c/f.md\>docs/x/y/c/f.md file=docs/a/b/other.md -- "${AU[@]}"
  has "$OUT" "the base moved docs/a/b/c/f.md to docs/x/y/c/f.md, a directory rename git may apply to this PR's docs/a/b/other.md" "[A] …the PR's file in an ancestor of the source directory is found"
  alone "[A] this PR moves docs/a/b/c/f.md to docs/x/y/c/f.md, the base changed docs/a/b/other.md" behind auto=stale rename=docs/a/b/c/f.md:docs/x/y/c/f.md behind=docs/a/b/other.md -- "${AU[@]}"
  has "$OUT" "this PR moved docs/a/b/c/f.md to docs/x/y/c/f.md, a directory rename git may apply to the base's docs/a/b/other.md" "[A] …and the same the other way round"
  # a directory renamed to another case or Unicode form is a rename for git (a file-location conflict), whatever a checkout folds
  alone "[A] the base renames docs/a/ to docs/A/, this PR adds docs/a/new.md" behind auto=stale base-rename=docs/a/f.md\>docs/A/f.md file=docs/a/new.md -- "${AU[@]}"
  has "$OUT" "the base moved docs/a/f.md to docs/A/f.md, a directory rename git may apply to this PR's docs/a/new.md" "[A] …a case-only directory rename is found"
  alone "[A] the base renames docs/café/ (NFC) to docs/café/ (NFD), this PR adds a file in the NFC one" behind auto=stale base-rename=$'docs/caf\xc3\xa9/f.md'\>$'docs/cafe\xcc\x81/f.md' file=$'docs/caf\xc3\xa9/new.md' -- "${AU[@]}"
  has "$OUT" "a directory rename git may apply to this PR's" "[A] …a Unicode-form-only directory rename is found"
  alone "[A] the base moves docs/a/b/f.md to docs/A/x/b/f.md, this PR adds docs/a/other.md" behind auto=stale base-rename=docs/a/b/f.md\>docs/A/x/b/f.md file=docs/a/other.md -- "${AU[@]}"
  has "$OUT" "the base moved docs/a/b/f.md to docs/A/x/b/f.md, a directory rename git may apply to this PR's docs/a/other.md" "[A] …the ancestor reached only through a case difference is found"
  d=$(mkfx auto=stale base-rename=docs/y.md\>docs/sub/y.md); guard "$PL" "$d" "${STD[@]}" "${AU[@]}"
  eq "$RC" 0 "[A] the base moves docs/y.md down into docs/sub: no directory leaves, rc 0"
  d=$(mkfx auto=stale base-rename=docs/y.md\>archive/y.md:copied); guard "$PL" "$d" "${STD[@]}" "${AU[@]}"
  eq "$RC" 0 "[A] the base copies docs/y.md to archive/y.md: a copy is no move, rc 0"
  d=$(mkfx auto=stale base-rename=docs/y.md\>docs/z.md); guard "$PL" "$d" "${STD[@]}" "${AU[@]}"
  eq "$RC" 0 "[A] the base renames docs/y.md inside its directory: no directory rename, rc 0"
  d=$(mkfx auto=stale base-rename=kb/a.md\>kb/b/a.md); guard "$PL" "$d" "${STD[@]}" "${AU[@]}"
  eq "$RC" 0 "[A] the base moves a file out of a directory this PR does not touch: rc 0"
  alone "[A] the base's é.md (NFD) and this PR's é.md (NFC)" behind auto=stale file=$'docs/\xc3\xa9.md' behind=$'docs/e\xcc\x81.md' -- "${AU[@]}"
  has "$OUT" "differ only in case or Unicode form" "[A] …the clash is named: Unicode form"
  alone "[A] the base lists docs/X.md and docs/x.md, this PR docs/x.md" behind auto=stale behind=docs/X.md,docs/x.md -- "${AU[@]}"
  has "$OUT" "docs/X.md and docs/x.md differ only in case or Unicode form" "[A] …the case-only pair is named although docs/x.md is also an exact match"
  d=$(mkfx auto behind=docs/xy.md,docs/x-y/z.md); guard "$PL" "$d" "${STD[@]}" "${AU[@]}"
  eq "$RC" 0 "[A] names that only start alike (docs/xy.md, docs/x-y/z.md beside docs/x.md): no clash, rc 0"
}

# ── [Q] the deny floor follows rules.dirs: a rules folder under .vibemaestro/ with another name, batons still merge ─────────────────
# init_cfg <plugin> <rules.dirs json> — the config `kb.py init` writes for those rules folders, in a file (its path is printed)
init_cfg() {
  local pl=$1 r f; r=$(fresh); f=$(fresh)/ans.json
  git_ init -q -b main "$r"; echo x > "$r/a.txt"; git_ -C "$r" add -A; git_ -C "$r" commit -qm c
  printf '{"rules": {"dirs": %s}}' "$2" > "$f"
  (cd "$r" && cenv python3 "$pl/scripts/kb.py" init --answers "$f" >/dev/null 2>&1) || { bad "fixture: kb.py init --answers"; return 1; }
  printf '%s' "$r/.vibemaestro/sdlc.json"
}
fam_floor() {
  PL=$1; local d cfg dflt
  dflt=$(init_cfg "$PL" '[]') || return
  cfg=$(init_cfg "$PL" '[".vibemaestro/policies"]') || return
  d=$(mkfx config-file="$dflt" file=.vibemaestro/rules/a.instructions.md); guard "$PL" "$d" "${STD[@]}" --allow '.vibemaestro/**'
  eq "$RC" 1 "[Q] instrument: the config init wrote with no rules folder refuses an edit under .vibemaestro/rules: rc 1"
  has "$OUT" "FAIL  deny:" "[Q] …named deny"
  alone "[Q] the config init wrote for rules.dirs .vibemaestro/policies refuses an edit of a policy file" deny config-file="$cfg" file=.vibemaestro/policies/a.instructions.md -- --allow '.vibemaestro/**'
  d=$(mkfx config-file="$cfg" file=.vibemaestro/batons/x.sh); guard "$PL" "$d" "${STD[@]}" --allow '.vibemaestro/**'
  eq "$RC" 0 "[Q] …and still merges a project baton under .vibemaestro/batons: rc 0"
  cfg=$(init_cfg "$PL" '[".vibemaestro/p[1]"]') || return
  alone "[Q] a rules folder whose name holds a class character is denied too (fail closed)" deny config-file="$cfg" file='.vibemaestro/p[1]/a.instructions.md' -- --allow '.vibemaestro/**'
  d=$(mkfx bootstrap=policies); guard "$PL" "$d" "${STD[@]}" "${BA[@]}"
  eq "$RC" 0 "[Q] bootstrap with rules.dirs .vibemaestro/policies: its README is the scaffold: rc 0"
  alone "[Q] bootstrap: …a policy file the PR adds below the folder's top is denied" deny bootstrap=policies file=.vibemaestro/policies/sub/p.md -- "${BA[@]}"
  alone "[Q] bootstrap: …and so is a script the PR adds in the folder" deny bootstrap=policies file=.vibemaestro/policies/run.sh -- "${BA[@]}"
  d=$(mkfx bootstrap=policies file=.vibemaestro/batons/x.sh); guard "$PL" "$d" "${STD[@]}" "${BA[@]}"
  eq "$RC" 0 "[Q] bootstrap: …while a project baton under .vibemaestro/batons still merges: rc 0"
}

# a base whose config sets no merge.deny_globs, and a PR that modifies the config to add the merge section
fam_amend() {
  PL=$1; local d
  d=$(mkfx amend); guard "$PL" "$d" "${STD[@]}" "${BA[@]}"
  eq "$RC" 0 "[U] the base config has no merge section, the PR adds it: rc 0"
  has "$OUT" "bootstrap: the base's .vibemaestro/sdlc.json sets no merge.deny_globs" "[U] …the run says bootstrap, and why"
  has "$OUT" "the config this PR changes is its scaffold" "[U] …deny skips the config it changes, and only that"
  has "$(printf '%s\n' "$OUT" | grep '^merge-plan: ')" " bootstrap " "[U] …the plan line carries bootstrap"
  hasnt "$(tail -n 1 "$d/state/vibemaestro/merge-log.jsonl")" '"bootstrap": null' "[U] …and the log line too"
  d=$(mkfx amend=partial); guard "$PL" "$d" "${STD[@]}" "${BA[@]}"
  eq "$RC" 0 "[U] a base merge section without deny_globs (required_checks kept), the PR adds deny_globs: rc 0"
  d=$(mkfx amend=log); guard "$PL" "$d" "${STD[@]}" "${BA[@]}"
  eq "$RC" 0 "[U] a base merge.log, kept by the head: rc 0"
  eq "$([ -f "$d/state/vibemaestro/amend-log.jsonl" ] && echo base-log)" "base-log" "[U] …the run logs to the base's merge.log"
  eq "$([ -f "$d/state/vibemaestro/merge-log.jsonl" ] && echo default-log)" "" "[U] …not to the default log"
  d=$(mkfx amend=untouched); guard "$PL" "$d" "${STD[@]}" "${BA[@]}"
  eq "$RC" 65 "[U] the same base, a PR that does not change the config: rc 65"
  has "$OUT" "merge.deny_globs is not set" "[U] …the key is named"
  hasnt "$OUT" "bootstrap" "[U] …no bootstrap"
  alone "[U] the PR adds the section and a workflow: refused as the no-config bootstrap refuses it" deny amend=workflow -- "${BA[@]}" --allow '.github/**'
  alone "[U] the PR adds the section and a file outside the brief" brief amend=outside -- "${BA[@]}"
  alone "[U] the PR adds the section and a Markdown file under the rules directory (not a scaffold here)" deny amend=rules-md -- "${BA[@]}"
  alone "[U] a head that denies nothing still gets the init default (a workflow it adds is refused)" deny amend=empty-deny -- "${BA[@]}" --allow '.github/**'
  d=$(mkfx amend=external); guard "$PL" "$d" "${STD[@]}" "${BA[@]}"
  eq "$RC" 65 "[U] the head config names an external adapter: rc 65"
  has "$OUT" "cannot bring the code that judges it" "[U] …named"
  d=$(mkfx amend=no-deny); guard "$PL" "$d" "${STD[@]}" "${BA[@]}"
  eq "$RC" 65 "[U] the head config sets no merge.deny_globs: rc 65"
  has "$OUT" "the config this PR changes" "[U] …named as the changed config's fault"
  d=$(mkfx amend=null-deny); guard "$PL" "$d" "${STD[@]}" "${BA[@]}"
  eq "$RC" 0 "[U] a base merge section with deny_globs: null (unset), the PR sets it: rc 0"
  d=$(mkfx amend=renamed); guard "$PL" "$d" "${STD[@]}" "${BA[@]}"
  eq "$RC" 65 "[U] the config arrives by a rename, not a modification: rc 65, no bootstrap"
  hasnt "$OUT" "bootstrap" "[U] …the run is not bootstrap"
  d=$(mkfx amend=log-lost); guard "$PL" "$d" "${STD[@]}" "${BA[@]}"
  eq "$RC" 65 "[U] the head changes the base's merge.log: rc 65"
  has "$OUT" "alters merge.log" "[U] …the key is named"
  eq "$([ -f "$d/state/vibemaestro/amend-log.jsonl" ] && echo base-log)" "base-log" "[U] …a refusal inside the lane is logged to the base's merge.log"
  eq "$([ -f "$d/state/vibemaestro/merge-log.jsonl" ] && echo default-log)" "" "[U] …not to the default log"
  for a in drop-key edit-key other-key extra-key nested-key; do
    d=$(mkfx amend=$a); guard "$PL" "$d" "${STD[@]}" "${BA[@]}"
    eq "$RC" 65 "[U] the head changes more than the merge section ($a): rc 65"
    has "$OUT" "may only add the merge section" "[U] …($a) named"
  done
  d=$(mkfx amend=nested-key); guard "$PL" "$d" "${STD[@]}" "${BA[@]}"
  has "$OUT" "alters merge.image_bump" "[U] …a key added inside a kept merge key is named (the comparison is deep)"
  d=$(mkfx amend=deny-set); guard "$PL" "$d" "${STD[@]}" "${BA[@]}"
  eq "$RC" 1 "[U] the base sets deny_globs, the PR edits its config: rc 1, no bootstrap"
  has "$OUT" "FAIL  own-inputs:" "[U] …own-inputs refuses it"
  hasnt "$OUT" "bootstrap" "[U] …and the run is not bootstrap"
  d=$(mkfx amend); guard "$PL" "$d" "${STD[@]}" "${BA[@]}" --admin
  eq "$RC" 64 "[U] --admin in this lane: rc 64"
  d=$(mkfx amend); guard "$PL" "$d" "${STD[@]}" "${BA[@]}" --image-bump
  eq "$RC" 64 "[U] --image-bump in this lane: rc 64"
  d=$(mkfx amend); guard "$PL" "$d" "${STD[@]}" "${BA[@]}" --require-image cc1-node22-r16
  eq "$RC" 64 "[U] --require-image in this lane: rc 64"
}

# ── [T6] touches: plan-approved merges ────────────────────────────────────────────────────────────────────────────────────────────
# A scratch repository W (acme/app, and acme/plans, to the fake gh) holds the plan; approvals are signed through the owner's
# dialog (the plugin's guard hook, then sign --by owner --approve) into the state TS; the guard runs from W with that state.
SID=s-owner
# tplan — W with kb/plans/p.md (the rows a spec lists) and kb/plans/q.md (signed whole), their intent and spec, committed on main (C1)
tplan() {
  W=$(fresh); git_ init -q -b main "$W"; mkdir -p "$W/kb/plans" "$W/kb/intent" "$W/kb/specs"
  printf '# Intent\n\nThe owner, verbatim: guard the plan.\n' > "$W/kb/intent/i.md"
  printf '# Spec\n\n## Acceptance criteria\n\n1. `bash tests/t.sh` gives 0 fail.\n2. The guard covers what a row declares.\n' > "$W/kb/specs/s.md"
  cat > "$W/kb/plans/p.md" <<'EOF'
# Plan

Intent: kb/intent/i.md · Spec: kb/specs/s.md

## Rows

| Row | Must be true | Trust touches | Link |
|---|---|---|---|
| A | a | workflow .github/workflows/x.yml; baton batons/b.sh Stops: secrets; rbac deploy/r.yaml Role/app/reader | — |
| B | b | workflow .github/workflows/y.yml | — |
| C | c | workflow .github/workflows/c.yml | — |
| E | e | workflow .github/workflows/signing-rules.yml | — |
| F | f | workflow .github/workflows/f.yml | — |
| G | g | workflow .github/workflows/g.yml | — |
| H | h | workflow .github/workflows/h.yml | approved by the owner |
| K | k | workflow acme/app:.github/workflows/k.yml | — |
| M | m | workflow .github/workflows/m.yml | — |
| R | r | workflow .github/workflows/r.yml | — |
| X | x | workflow .github/workflows/xx.yml | — |
EOF
  cat > "$W/kb/plans/q.md" <<'EOF'
# Plan Q

Intent: kb/intent/i.md · Spec: kb/specs/s.md · Issue: #1

## Rows

| Row | Must be true | Trust touches | Link |
|---|---|---|---|
| N | n | workflow .github/workflows/n.yml; PRs: 2 | — |
| O | o | other src/secret-notes.txt; other src/data.txt; other clusters/prod apps/Deployment shop/web; rbac clusters/prod Role/shop/maker; workflow .github/workflows/w.yml | — |
| T | t | test tests/fixtures/; test src/tests/one.pin | — |
| Q | q | baton batons/q.sh Stops: none; baton ops/runbooks/x.sh Stops: none | — |
| S | s | other plugins/p/.claude-plugin/p.json (signs again); config .vibemaestro/sdlc.json (signs again); workflow .github/workflows/s.yml (signs again) | — |
| U | u | other plugins/x/baton.py GRANT_NEVER | — |
| L | l | workflow .github/workflows/l.yml | — |
| W | w | workflow .github/workflows/dup.yml (signs again); workflow .github/workflows/dup.yml; test tests/m/; test tests/m/migrate.pin (signs again) | — |
| D | d | workflow .github/workflows/d.yml | dropped: not needed |

## Decisions

- none yet
EOF
  git_ -C "$W" add -A; git_ -C "$W" commit -q -m plan; C1=$(git_ -C "$W" rev-parse HEAD)
}
# tapprove <dir> <rows> [expires in s] [plan repo] [commit] [plan path] — an approval of those rows (`*`: every row, a spec with no
# rows) of W's plan kb/plans/p.md (or <plan path>) at C1 (or <commit>), signed through the owner's dialog from <dir> into TS; its id in TA
tapprove() {
  local dir=$1 rows=$2 sec=${3:-86400} repo=${4:-acme/app} commit=${5:-$C1} path=${6:-kb/plans/p.md} out
  python3 - "$dir/a.json" "$commit" "$rows" "$sec" "$repo" "$path" <<'PY'
import json, sys, time
p, commit, rows, sec, repo, path = sys.argv[1], sys.argv[2], sys.argv[3].split(), int(sys.argv[4]), sys.argv[5], sys.argv[6]
plan = {"repo": repo, "path": path, "commit": commit}
spec = {"plan": [plan], "expires": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + sec))}
if rows != ["*"]:
    spec["rows"] = [{"plan": plan, "row": r} for r in rows]
json.dump(spec, open(p, "w"))
PY
  printf '{"repo": "acme/app", "git": {"acme/app": "%s", "acme/plans": "%s"}, "api": {}}\n' "$W" "$W" > "$dir/a.fx.json"
  : > "$dir/a.gh.log"; BT_ENV=(FAKE_GH_FX="$dir/a.fx.json" FAKE_GH_LOG="$dir/a.gh.log")
  [ "$(owner_asked "$PL" "$dir" "$TS" "$SID" --by owner --approve "$dir/a.json")" = ask ] || bad "[T6] fixture: the approval dialog did not ask ($rows)"
  out=$(cd "$dir" && cenv XDG_STATE_HOME="$TS" CLAUDE_CODE_SESSION_ID="$SID" "${BT_ENV[@]}" python3 "$PL/scripts/baton.py" sign --by owner --approve "$dir/a.json" 2>&1)
  BT_ENV=(); TA=$(printf '%s\n' "$out" | sed -n 's/^signed approval \([0-9a-f]\{16\}\) by owner: .*/\1/p')
  [ -n "$TA" ] || bad "[T6] fixture: no approval signed ($rows): $out"
}
# tg <case dir> [guard args...] — the guard from W with the state TS (whatever the case dir's own state); OUT, RC
tg() {
  local d=$1; shift
  OUT=$(cd "$W" && cenv XDG_STATE_HOME="${TG_STATE:-$TS}" FAKE_GH_FX="$d/fx.json" FAKE_GH_LOG="$d/gh.log" FAKE_GH_STATE="$d/merged.json" \
        python3 -B "$PL/gates/merge_guard.py" --repo acme/app --pr 7 --head "$H" --brief "$d/brief.txt" --allow '**' "$@" 2>&1); RC=$?
}
pl() { printf 'body=plan: %s' "$1"; }
# trefused <label> <reason> <mutations...> — refused: rc 1, FAIL touches with the reason, no merge call
trefused() {
  local label=$1 why=$2 d; shift 2
  d=$(mkfx touch="$W" "$@"); tg "$d"
  eq "$RC" 1 "[T6] $label: rc 1"
  has "$OUT" "  FAIL  touches: " "[T6] …FAIL touches"
  has "$OUT" "$why" "[T6] …the reason named: $why"
  eq "$(merges "$d")" 0 "[T6] …no pr merge call"
}
fam_touches() {
  PL=$1; local d d2 A1 W2 EX
  TS=$(fresh)/state; tplan
  tapprove "$W" "A B C E M"; A1=$TA
  tapprove "$W" "R"; eq "$(cd "$W" && cenv XDG_STATE_HOME="$TS" python3 "$PL/scripts/baton.py" grant revoke "$TA" >/dev/null 2>&1; echo $?)" 0 "[T6] fixture: approval of R revoked"
  tapprove "$W" "X" 4; EX=$(( $(date +%s) + 4 ))
  W2=$(fresh); git_ init -q -b main "$W2"; W2=$(cd "$W2" && pwd -P); tapprove "$W2" "F"
  tapprove "$W" "G"
  python3 - "$TS/vibemaestro/baton/grants/$TA.json" <<'PY'
import json, sys
p = sys.argv[1]; g = json.load(open(p)); g["rows"][0]["touches"][0]["path"] = ".github/workflows/z.yml"; open(p, "w").write(json.dumps(g))
PY
  tapprove "$W" "K" 86400 acme/plans
  # the declared change merges with no owner merge
  d=$(mkfx touch="$W" file=.github/workflows/x.yml "$(pl kb/plans/p.md#A)"); tg "$d"
  eq "$RC" 0 "[T6] a PR changing the denied .github/workflows/x.yml its approved row A declares: rc 0"
  has "$OUT" "  ok    touches: 1 trust-layer change(s), each a touch of row A, approval $A1 at ${C1:0:12}" "[T6] …ok touches names the row and the approval"
  has "$OUT" "  ok    deny: " "[T6] …deny passes the covered path"
  has "$OUT" "denied: .github/workflows/x.yml: judged by touches" "[T6] …named as judged by touches"
  has "$(printf '%s\n' "$OUT" | grep '^merge-plan: ')" " touches:$A1/A" "[T6] …the plan line says touches:<id>/<row>"
  eq "$(merges "$d")" 0 "[T6] …and the dry run merges nothing"
  d=$(mkfx touch="$W" file=.github/workflows/k.yml "$(pl acme/plans:kb/plans/p.md#K)"); tg "$d"
  eq "$RC" 0 "[T6] a plan held in another repository (acme/plans:kb/plans/p.md#K), its touch naming acme/app: rc 0"
  d=$(mkfx touch="$W" baton-head=batons/b.sh:secrets "$(pl kb/plans/p.md#A)"); tg "$d"
  eq "$RC" 0 "[T6] a denied baton whose Stops at the head are the declared ones: rc 0"
  d=$(mkfx touch="$W" file=.github/workflows/x.yml sr-red=rbac:deploy/r.yaml:Role/app/reader:- "$(pl kb/plans/p.md#A)"); tg "$d"
  eq "$RC" 0 "[T6] a red touch check whose one finding is the declared rbac object: rc 0"
  has "$OUT" "red and judged by touches: signing-rules" "[T6] …required leaves the red touch check to touches"
  d=$(mkfx touch="$W" "$(pl kb/plans/p.md#A)"); tg "$d"
  eq "$RC" 0 "[T6] no trust-layer change: rc 0"
  has "$OUT" "  ok    touches: no trust-layer change" "[T6] …ok touches says so"
  # refused: each change that is not a touch of the row, and each record that does not hold
  trefused "an undeclared path" "workflow acme/app:.github/workflows/z.yml (a denied path): not a touch of row A at ${C1:0:12}" \
    file=.github/workflows/z.yml "$(pl kb/plans/p.md#A)"
  trefused "a path only another row declares" "workflow acme/app:.github/workflows/y.yml (a denied path): not a touch of row A" \
    file=.github/workflows/y.yml "$(pl kb/plans/p.md#A)"
  trefused "a rename whose source is undeclared" "workflow acme/app:.github/workflows/old.yml (a denied path): not a touch of row A" \
    rename=.github/workflows/old.yml:.github/workflows/x.yml "$(pl kb/plans/p.md#A)"
  trefused "a case variant of a declared path" "acme/app:.github/workflows/X.yml" file=.github/workflows/X.yml "$(pl kb/plans/p.md#A)"
  trefused "another object of a declared rbac path" "rbac acme/app:deploy/r.yaml Role/app/writer (a finding of signing-rules): not a touch" \
    sr-red=rbac:deploy/r.yaml:Role/app/writer:- "$(pl kb/plans/p.md#A)"
  trefused "a baton touch with other Stops at the head" "baton acme/app:batons/b.sh Stops: publish (a denied path): not a touch of row A" \
    baton-head=batons/b.sh:publish "$(pl kb/plans/p.md#A)"
  trefused "no plan: line" "the body has 0 plan-row line(s)" file=.github/workflows/x.yml
  trefused "two plan: lines" "the body has 2 plan-row line(s)" file=.github/workflows/x.yml "body=plan: kb/plans/p.md#A|plan: kb/plans/p.md#B"
  # [plan-line-planner] the CI planner's `plan: N/M suites` line is no plan line; two plan-row lines are still not one
  d=$(mkfx touch="$W" file=.github/workflows/x.yml "body=plan: kb/plans/p.md#A|plan: 8/45 suites — 15 changed paths"); tg "$d"
  eq "$RC" 0 "[plan-line-planner] a body with the row line and the planner's line 'plan: 8/45 suites': rc 0"
  has "$OUT" "  ok    touches: 1 trust-layer change(s), each a touch of row A, approval $A1 at ${C1:0:12}" "[plan-line-planner] …the row is the one named"
  trefused "two row lines and the planner's line [plan-line-planner]" "the body has 2 plan-row line(s)" file=.github/workflows/x.yml \
    "body=plan: kb/plans/p.md#A|plan: 8/45 suites — 15 changed paths|plan: kb/plans/p.md#B"
  trefused "only the planner's line [plan-line-planner]" "the body has 0 plan-row line(s)" file=.github/workflows/x.yml "body=plan: 8/45 suites — 15 changed paths"
  trefused "an approved line in the plan and the body, and no approval" "no approval in force signed from this directory lists row H" \
    file=.github/workflows/h.yml "body=approved by the owner|plan: kb/plans/p.md#H"
  trefused "an approval signed from another directory" "was signed from $W2, not from $W" file=.github/workflows/f.yml "$(pl kb/plans/p.md#F)"
  trefused "a revoked approval" "was revoked" file=.github/workflows/r.yml "$(pl kb/plans/p.md#R)"
  trefused "an altered approval file" "is damaged" file=.github/workflows/z.yml "$(pl kb/plans/p.md#G)"
  trefused "a finding of kind other" "other acme/app:plugins/x/baton.py GRANT_NEVER (a finding of signing-rules): a signing-rules finding of kind other changes who signs: the floor, never covered" \
    file=.github/workflows/x.yml sr-red=other:plugins/x/baton.py:GRANT_NEVER:- "$(pl kb/plans/p.md#A)"
  trefused "a red touch check with no artifact" "red, and it has no single unexpired artifact trust-touches" sr-block=none "$(pl kb/plans/p.md#A)"
  trefused "two artifacts of one run" "(2 found)" sr-block=two "$(pl kb/plans/p.md#A)"
  trefused "a block with no end line" "no \`end\` line" sr-block=noend "$(pl kb/plans/p.md#A)"
  trefused "a block whose end counts 2 lines over 1" "its block ends \`end 2\` over 1 finding line(s)" sr-block=count "$(pl kb/plans/p.md#A)"
  trefused "a red run with end 0" "its block ends \`end 0\` over 0 finding line(s)" sr-block=end0 "$(pl kb/plans/p.md#A)"
  trefused "a check run rewritten to success over a red workflow run" "baton acme/app:batons/q.sh Stops: none (a finding of signing-rules)" \
    file=.github/workflows/x.yml sr-block=flip "$(pl kb/plans/p.md#A)"
  for r in "completed:cancelled|cancelled" "in_progress:|pending"; do
    d=$(mkfx touch="$W" file=.github/workflows/x.yml sr-run="${r%%|*}" "$(pl kb/plans/p.md#A)"); tg "$d"
    eq "$RC/$(merges "$d")" "1/0" "[T6] a check run that says success over a workflow run ${r%%|*}: rc 1, no merge"
    has "$OUT" "signing-rules (its check run says success, its workflow run ${r#*|})" "[T6] …FAIL required: the workflow run is read, not the check run"
    has "$OUT" "signing-rules/signing-rules=success, but its workflow run is ${r#*|}" "[T6] …and FAIL checks"
  done
  trefused "a second same-name run from another workflow" "(a run of signing-rules that .github/workflows/signing-rules.yml did not make)" \
    file=.github/workflows/x.yml sr-foreign "$(pl kb/plans/p.md#A)"
  trefused "a declared change to a touch_inputs path" "workflow acme/app:.github/workflows/signing-rules.yml (a denied path): it judges a later PR: the floor, never covered" \
    file=.github/workflows/signing-rules.yml "$(pl kb/plans/p.md#E)"
  trefused "an own-inputs path" "config acme/app:.vibemaestro/sdlc.json (a denied path): it judges a later PR: the floor, never covered" \
    file=.vibemaestro/sdlc.json "$(pl kb/plans/p.md#A)"
  d=$(mkfx touch="$W" file=.github/workflows/x.yml red-unit="Run tests" "$(pl kb/plans/p.md#A)"); tg "$d"
  eq "$RC" 1 "[T6] a red required check outside touch_checks: rc 1"
  has "$OUT" "  FAIL  checks: " "[T6] …FAIL checks, as today" ; has "$OUT" "test/unit=failure" "[T6] …naming it"
  has "$OUT" "  ok    touches: " "[T6] …touches does not cover it"
  d=$(mkfx touch="$W" file=.github/workflows/x.yml sr-skipped "$(pl kb/plans/p.md#A)"); tg "$d"
  eq "$RC" 1 "[T6] a skipped touch check: rc 1"; has "$OUT" "  FAIL  required: 1 required check(s); not green: signing-rules (skipped)" "[T6] …FAIL required"
  d=$(mkfx touch="$W" file=.github/workflows/x.yml sr-missing "$(pl kb/plans/p.md#A)"); tg "$d"
  eq "$RC" 1 "[T6] a missing touch check run: rc 1"; has "$OUT" "signing-rules (no check run)" "[T6] …FAIL required names it"
  d=$(mkfx touch="$W" file=.github/workflows/x.yml touch-no-inputs "$(pl kb/plans/p.md#A)"); tg "$d"
  eq "$RC" 65 "[T6] merge.touch_checks names a check merge.touch_inputs lacks: rc 65"
  has "$OUT" "merge.touch_checks: names signing-rules, which merge.touch_inputs does not" "[T6] …named"
  d=$(mkfx file=.github/workflows/x.yml "$(pl kb/plans/p.md#A)"); tg "$d"
  eq "$RC" 1 "[T6] a repository with no touch_checks: the declared path is refused as today (rc 1)"
  has "$OUT" "  FAIL  deny: " "[T6] …FAIL deny"; hasnt "$OUT" "touches:" "[T6] …and no touches condition"
  d=$(mkfx touch="$W" file=.github/workflows/x.yml "$(pl kb/plans/p.md#A)"); TG_STATE=$(fresh) tg "$d"
  eq "$RC" 1 "[T6] the guard run outside baton's state (no approval there): rc 1"; has "$OUT" "no approval in force" "[T6] …named"
  # the plan moves after the approval: read at the approved commit, and at the default branch's tip for dropped
  python3 - "$W/kb/plans/p.md" <<'PY'
import sys
p = sys.argv[1]; t = open(p).read()
t = t.replace("| workflow .github/workflows/y.yml |", "| workflow .github/workflows/y.yml; workflow .github/workflows/late.yml |")
t = t.replace("| c | workflow .github/workflows/c.yml | — |", "| c | workflow .github/workflows/c.yml | dropped: not needed |")
open(p, "w").write(t)
PY
  git_ -C "$W" commit -q -am "a touch added to B, C dropped"
  trefused "a touch added to the plan on main after the approved commit" "workflow acme/app:.github/workflows/late.yml (a denied path): not a touch of row B at ${C1:0:12}" \
    file=.github/workflows/late.yml "$(pl kb/plans/p.md#B)"
  trefused "a touch added in the PR's own plan" "not a touch of row B at ${C1:0:12}" file=.github/workflows/late.yml file=kb/plans/p.md "$(pl kb/plans/p.md#B)"
  trefused "a row dropped on main after the approval" "row C is dropped at the default branch's tip (not needed)" \
    file=.github/workflows/c.yml "$(pl kb/plans/p.md#C)"
  # the one use of a row: --merge takes it, keyed by the plan and the row
  d=$(mkfx touch="$W" file=.github/workflows/x.yml "$(pl kb/plans/p.md#A)"); tg "$d" --merge
  eq "$RC/$(merges "$d")" "0/1" "[T6] --merge of the declared change: rc 0, one pr merge call"
  eq "$(grep "	touches	" "$TS/vibemaestro/baton/log.tsv" | cut -f8,10,12)" "$(printf 'approval:%s\tused\tacme/app:kb/plans/p.md@%s#a' "$A1" "$C1")" \
     "[T6] …a touches used line in baton's log.tsv, keyed by the plan's repo, path, commit and the row"
  has "$(tail -n 1 "$TS/vibemaestro/merge-log.jsonl")" "\"touches\": {\"approval\": \"$A1\"" "[T6] …the merge log line names the approval"
  has "$(tail -n 1 "$TS/vibemaestro/merge-log.jsonl")" "[\"workflow\", \"acme/app\", \".github/workflows/x.yml\", null, null]" "[T6] …and the covered change"
  has "$(cd "$W" && cenv XDG_STATE_HOME="$TS" python3 "$PL/scripts/baton.py" log --digest 2>&1)" "kit:merge-pr	approval:$A1	touches acme/app:kb/plans/p.md@$C1#a	-" \
      "[T6] …log --digest lists the merge under the approval, with the row it used"
  trefused "a second PR for a used row" "an earlier merge used row A of acme/app kb/plans/p.md @ ${C1:0:12} (1 of its PRs: 1)" \
    file=.github/workflows/x.yml "$(pl kb/plans/p.md#A)"
  tapprove "$W" "A"
  trefused "a used row under an approval signed again at the same commit" "an earlier merge used row A" file=.github/workflows/x.yml "$(pl kb/plans/p.md#A)"
  tapprove "$W" "A" 86400 acme/app "$(git_ -C "$W" rev-parse HEAD)"
  trefused "a used row under an approval at a later commit of the plan" "an earlier merge used row A" file=.github/workflows/x.yml "$(pl kb/plans/p.md#A)"
  rm -rf "$TS/vibemaestro/baton/touches"                               # a use marker deleted: an input, not a break
  trefused "the use marker deleted (the log line still counts)" "an earlier merge used row A" file=.github/workflows/x.yml "$(pl kb/plans/p.md#A)"
  # two merges of one row at once: one merges
  d=$(mkfx touch="$W" file=.github/workflows/m.yml "$(pl kb/plans/p.md#M)"); d2=$(mkfx touch="$W" file=.github/workflows/m.yml "$(pl kb/plans/p.md#M)")
  ( tg "$d" --merge ) & ( tg "$d2" --merge ) & wait
  eq "$(( $(merges "$d") + $(merges "$d2") ))" 1 "[T6] two merges of one row at once: exactly one pr merge call"
  while [ "$(date +%s)" -le "$EX" ]; do sleep 1; done
  trefused "an expired approval" "expired at" file=.github/workflows/xx.yml "$(pl kb/plans/p.md#X)"
  fam_touches_plan
}

# [T7] one owner signature for every row of a plan (kb/plans/q.md, a spec with no rows): PRs: <n>, other, test, the floor, the
# plan as signed at the default branch's tip and at the PR's head
qok() {   # qok <label> <mutations...> — covered: rc 0, ok touches, no merge call (dry run)
  local label=$1 d; shift
  d=$(mkfx touch="$W" "$@"); tg "$d"
  eq "$RC/$(merges "$d")" "0/0" "[T7] $label: rc 0 in dry run"; has "$OUT" "  ok    touches: " "[T7] …ok touches"
}
qno() {   # qno <label> <reason> <mutations...> — refused: rc 1, FAIL touches with the reason
  local label=$1 why=$2 d; shift 2
  d=$(mkfx touch="$W" "$@"); tg "$d"
  eq "$RC/$(merges "$d")" "1/0" "[T7] $label: rc 1, no merge call"
  has "$OUT" "  FAIL  touches: " "[T7] …FAIL touches"; has "$OUT" "$why" "[T7] …named: $why"
}
q() { printf 'body=plan: kb/plans/q.md#%s' "$1"; }
# oldshape <grants dir> <approval id> — a copy of that approval as a record of the old shape (v 1: no intent, spec or cells) with
# its digest and signature computed again, and its `grant signed` line: state from before plan signing, built as an input
oldshape() {
  local sha
  sha=$(python3 - "$1" "$2" <<'PY'
import hashlib, json, os, sys
g = json.load(open(os.path.join(sys.argv[1], sys.argv[2] + ".json")))
g.pop("plans"); g["v"] = 1; g["id"] = "00000000000000aa"
for r in g["rows"]:
    r.pop("cells")
body = {k: v for k, v in g.items() if k not in ("body_sha256", "signature")}
g["body_sha256"] = hashlib.sha256(json.dumps(body, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
g["signature"]["body_sha256"] = g["body_sha256"]
open(os.path.join(sys.argv[1], g["id"] + ".json"), "w").write(json.dumps(g))
print(g["body_sha256"])
PY
)
  printf '2026-11-07T00:00:00Z\tgrant\t-\t-\t-\t-\t-\towner\t-\tsigned\t-\t00000000000000aa %s\t-\n' "$sha" >> "$TS/vibemaestro/baton/log.tsv"
}
fam_touches_plan() {
  local d d2 AQ CQ=$C1 G="$TS/vibemaestro/baton/grants"
  # a spec that still lists rows covers those rows only; one with no rows covers every row that is not dropped
  tapprove "$W" "N" 86400 acme/app "$CQ" kb/plans/q.md
  qok "a row a listing spec names (q.md#N)" file=.github/workflows/n.yml "$(q N)"
  qno "a row the listing spec leaves out (q.md#L)" "no approval in force signed from this directory lists row L" file=.github/workflows/l.yml "$(q L)"
  # an approval of the old shape listing the row (the signed one revoked): never in force for a merge
  oldshape "$G" "$TA"
  eq "$(cd "$W" && cenv XDG_STATE_HOME="$TS" python3 "$PL/scripts/baton.py" grant revoke "$TA" >/dev/null 2>&1; echo $?)" 0 "[T7] fixture: the approval of N revoked"
  qno "an approval of the old shape (v 1, no intent, spec or cells)" "approval 00000000000000aa binds no intent, spec or row cells" file=.github/workflows/l.yml "$(q N)"
  tapprove "$W" "*" 86400 acme/app "$CQ" kb/plans/q.md; AQ=$TA
  eq "$(python3 -c 'import json, sys; g = json.load(open(sys.argv[1])); print(g["v"], [r["row"] for r in g["rows"]], g["plans"][0]["intent"]["path"], g["plans"][0]["criteria"], g["rows"][0]["cells"])' "$G/$AQ.json")" \
     "2 ['N', 'O', 'T', 'Q', 'S', 'U', 'L', 'W'] kb/intent/i.md ['\`bash tests/t.sh\` gives 0 fail.', 'The guard covers what a row declares.'] [['Row', 'N'], ['Must be true', 'n'], ['Trust touches', 'workflow .github/workflows/n.yml; PRs: 2']]" \
     "[T7] one signature for every row not dropped: the record binds the intent, the spec's criteria, each row's cells but Link"
  qok "a row of the plan the one signature covers (q.md#L)" file=.github/workflows/l.yml "$(q L)"
  qno "the dropped row" "no approval in force signed from this directory lists row D" file=.github/workflows/d.yml "$(q D)"
  # PRs: 2 — two uses, one of two racing merges takes the last, a third is an owner merge
  d=$(mkfx touch="$W" file=.github/workflows/n.yml "$(q N)"); tg "$d" --merge
  eq "$RC/$(merges "$d")" "0/1" "[T7] PRs: 2, the first PR: merged"
  d=$(mkfx touch="$W" file=.github/workflows/n.yml "$(q N)"); d2=$(mkfx touch="$W" file=.github/workflows/n.yml "$(q N)")
  ( tg "$d" --merge ) & ( tg "$d2" --merge ) & wait
  eq "$(( $(merges "$d") + $(merges "$d2") ))" 1 "[T7] PRs: 2, two merges at once for the last use: exactly one pr merge call"
  has "$(grep "	touches	" "$TS/vibemaestro/baton/log.tsv" | cut -f12)" "acme/app:kb/plans/q.md@$CQ#n/2" "[T7] …the second use logged as #n/2"
  qno "PRs: 2, a third PR" "an earlier merge used row N of acme/app kb/plans/q.md @ ${CQ:0:12} (2 of its PRs: 2)" file=.github/workflows/n.yml "$(q N)"
  # other: one exact path (and object), from a denied path or a trust-touches v2 finding; never v1, owner-merge, - or an unknown kind
  qok "other by path: a denied path (src/secret-notes.txt)" file=src/secret-notes.txt "$(q O)"
  qok "other, rbac and workflow findings of a v2 block" touch-name=risk-tier \
    "sr-red2=other:src/data.txt:-:-;other:clusters/prod:apps/Deployment shop/web:-;rbac:clusters/prod:Role/shop/maker:-;workflow:.github/workflows/w.yml:-:-" "$(q O)"
  qno "the same other in a v1 block" "other acme/app:src/data.txt (a finding of risk-tier): kind other of a trust-touches v1 block" \
    touch-name=risk-tier sr-red=other:src/data.txt:-:- "$(q O)"
  qno "an owner-merge finding of a declared path" "owner-merge acme/app:src/data.txt (a finding of risk-tier): the check could not judge it" \
    touch-name=risk-tier sr-red2=owner-merge:src/data.txt:-:- "$(q O)"
  qno "an other finding of path -" "a finding of no path, never covered" touch-name=risk-tier "sr-red2=other:-:-:-" "$(q O)"
  qno "a finding of an unknown kind" "magic acme/app:src/data.txt (a finding of risk-tier): of no kind a row declares" \
    touch-name=risk-tier sr-red2=magic:src/data.txt:-:- "$(q O)"
  qno "another object of a declared other path" "not a touch of row O" touch-name=risk-tier "sr-red2=other:clusters/prod:apps/Deployment shop/api:-" "$(q O)"
  # test <dir>/: every test-data file under it
  qok "test tests/fixtures/ and test src/tests/one.pin" file=tests/fixtures/a.pin file=tests/fixtures/sub/b.pin file=src/tests/one.pin "$(q T)"
  qno "test data outside the declared directory" "test acme/app:tests/fixtures-x/c.pin (a denied path): not a touch of row T" file=tests/fixtures-x/c.pin "$(q T)"
  # the floor: never covered, marked or not
  qno "a judge path the row marks (signs again)" "config acme/app:.vibemaestro/sdlc.json (a denied path): it judges a later PR: the floor" file=.vibemaestro/sdlc.json "$(q S)"
  qno "a nested .claude-plugin path the row marks (signs again)" "other acme/app:plugins/p/.claude-plugin/p.json (a denied path): a .claude-plugin path: the floor" \
    file=plugins/p/.claude-plugin/p.json "$(q S)"
  qno "a .claude-plugin path in another case, under no deny glob" "PLUGINS/P/.CLAUDE-PLUGIN/p.json (a denied path): a .claude-plugin path: the floor" \
    file=PLUGINS/P/.CLAUDE-PLUGIN/p.json "$(q L)"
  qno "a touch the row marks (signs again)" "workflow acme/app:.github/workflows/s.yml (a denied path): row S marks it (signs again)" file=.github/workflows/s.yml "$(q S)"
  qno "a signing-rules finding of kind other, declared, in a v2 block" "a signing-rules finding of kind other changes who signs: the floor" \
    sr-red2=other:plugins/x/baton.py:GRANT_NEVER:- "$(q U)"
  qno "a baton whose head drops a SIGN_AGAIN_STOPS word its base holds" "baton acme/app:batons/q.sh Stops: none (a denied path): its head drops irreversible-delete, which its base's Stops (irreversible-delete) hold: the floor" \
    baton-head=batons/q.sh:none baton-base=batons/q.sh:irreversible-delete "$(q Q)"
  qno "…and the same in a v2 baton finding" "its head drops no-way-back" touch-name=risk-tier sr-red2=baton:batons/q.sh:-:none baton-base=batons/q.sh:no-way-back "$(q Q)"
  qok "control: a base Stops word off the floor (publish) dropped" baton-head=batons/q.sh:none baton-base=batons/q.sh:publish "$(q Q)"
  qno "a baton finding outside the path table's baton directories (a list's own baton_dirs) that drops a floor word" \
    "baton acme/app:ops/runbooks/x.sh Stops: none (a finding of risk-tier): its head drops security-boundary" \
    touch-name=risk-tier sr-red2=baton:ops/runbooks/x.sh:-:none baton-base=ops/runbooks/x.sh:security-boundary "$(q Q)"
  qok "control: that finding over a base Stops off the floor" touch-name=risk-tier sr-red2=baton:ops/runbooks/x.sh:-:none \
    baton-base=ops/runbooks/x.sh:publish "$(q Q)"
  # a mark holds whatever other touch of the row also names the change
  qno "an unmarked duplicate of a touch the row marks (signs again)" "workflow acme/app:.github/workflows/dup.yml (a denied path): row W marks it (signs again)" \
    file=.github/workflows/dup.yml "$(q W)"
  qno "a marked test file under a test directory the row declares" "test acme/app:tests/m/migrate.pin (a denied path): row W marks it (signs again)" \
    file=tests/m/migrate.pin "$(q W)"
  qok "control: another file of that directory" file=tests/m/other.pin "$(q W)"
  qno "a foreign run of the touch check" "the check cannot be believed, never covered" file=.github/workflows/l.yml sr-foreign "$(q L)"
  qno "a red touch check with no block" "red, and it has no single unexpired artifact" sr-block=none "$(q L)"
  # the plan as signed: the intent, the spec and the row's cells at the default branch's tip, and at the PR's head
  qok "control: the plan as signed" file=.github/workflows/l.yml "$(q L)"
  for f in "kb/intent/i.md|its intent kb/intent/i.md" "kb/specs/s.md|its spec kb/specs/s.md"; do
    printf '\nOne more line.\n' >> "$W/${f%%|*}"; git_ -C "$W" commit -q -am "edit ${f%%|*}"
    qno "${f%%|*} changed at the default branch's tip" "the plan changed since the owner signed it (${f#*|}, at the default branch's tip): sign it again" file=.github/workflows/l.yml "$(q L)"
    git_ -C "$W" revert --no-edit HEAD >/dev/null
  done
  sed -i 's/^| L | l |/| L | l, and more |/' "$W/kb/plans/q.md"; git_ -C "$W" commit -q -am "edit row L"
  qno "a cell of the row changed at the tip" "the plan changed since the owner signed it (row L's cells, at the default branch's tip)" file=.github/workflows/l.yml "$(q L)"
  git_ -C "$W" revert --no-edit HEAD >/dev/null
  qok "control: the plan reverted to what was signed" file=.github/workflows/l.yml "$(q L)"
  sed -i -e 's/^| L | l | workflow .github\/workflows\/l.yml | — |/| L | l | workflow .github\/workflows\/l.yml | intent\/l-branch |/' \
         -e 's/^- none yet$/- none yet\n- one more line/' -e 's/^| D | d |\(.*\)$/| D | d |\1\n| Z | z | none | — |/' "$W/kb/plans/q.md"
  git_ -C "$W" commit -q -am "a Link cell, a Decisions line, a new row"
  has "$(git_ -C "$W" show HEAD:kb/plans/q.md)" "| L | l | workflow .github/workflows/l.yml | intent/l-branch |" "[T7] fixture: L's Link cell at the tip"
  has "$(git_ -C "$W" show HEAD:kb/plans/q.md)" "| D | d | workflow .github/workflows/d.yml | dropped: not needed |
| Z | z | none | — |" "[T7] fixture: a new row Z at the tip"
  has "$(git_ -C "$W" show HEAD:kb/plans/q.md)" "- one more line" "[T7] fixture: a Decisions line at the tip"
  qok "a new row, a Link cell and a Decisions line change nothing signed" file=.github/workflows/l.yml "$(q L)"
  git_ -C "$W" checkout -q -b h1; printf '\nA head-only line.\n' >> "$W/kb/specs/s.md"; git_ -C "$W" commit -q -am "spec at the head"
  git_ -C "$W" checkout -q -b h2 main; sed -i 's/^| L | l |/| L | l at the head |/' "$W/kb/plans/q.md"; git_ -C "$W" commit -q -am "row L at the head"
  git_ -C "$W" checkout -q main
  qno "the spec changed at the PR's head (the plan's repository)" "the plan changed since the owner signed it (its spec kb/specs/s.md, at the PR's head)" \
    touch-head=h1 file=.github/workflows/l.yml "$(q L)"
  qno "a cell of the row changed at the PR's head" "the plan changed since the owner signed it (row L's cells, at the PR's head)" \
    touch-head=h2 file=.github/workflows/l.yml "$(q L)"
}

# ── [charter-*] touches under a focus charter, read after the approvals ────────────────────────────────────────────────────────
# The owner signs a charter (sign --by owner --charter, through the plugin's guard hook) from a copy of the plugin in a plugin
# cache whose registry names a brain beside it: a fake built from scratch that answers `show <P> --json` for P8 and P9, live
# focuses with their done when, as the dialog reads a focus. W's plans c.md (focus: P8), c9.md (focus: P9) and c7.md (focus: P7)
# are committed on main (C2); the guard runs from that copy, from W, with the state TS.
cbrain() {  # cbrain <claude dir> <sdlc copy> — the fake brain beside the copy, and the registry naming both
  mkdir -p "$1/brain/scripts"   # its file written from inside the directory: a fake, not a path the planner reads as the brain plugin's
  ( cd "$1/brain/scripts" && cat > brain.py ) <<'PY'
import json, sys
src = {"type": "session", "quote": "q", "where": "chat"}
items = {p: {"kind": "focus", "status": "live", "text": "focus " + p, "goal": "G1", "source": src, "done": "it shipped"} for p in ("P8", "P9")}
if sys.argv[1:2] != ["show"] or sys.argv[3:] != ["--json"] or sys.argv[2] not in items:
    sys.exit("brain: no such item")
print(json.dumps(dict(items[sys.argv[2]], id=sys.argv[2])))
PY
  python3 - "$1/plugins/installed_plugins.json" "$2" "$1/brain" <<'PY'
import json, sys
e = lambda p: [{"scope": "user", "installPath": p, "version": "1.0.0", "lastUpdated": "2026-11-09T00:00:00.000Z"}]
json.dump({"version": 2, "plugins": {"vibemaestro-sdlc@vibemaestro": e(sys.argv[2]), "vibemaestro-brain@vibemaestro": e(sys.argv[3])}},
          open(sys.argv[1], "w"))
PY
}
# tcharter <dir> <focus> <repos> <kinds> <max_stops> — the owner's charter (each list space-separated, `-` for none, a day ahead)
# signed from <dir> into TS through the dialog; its id in TC
tcharter() {
  python3 - "$1/c.json" "$2" "$3" "$4" "$5" <<'PY'
import json, sys, time
p, focus, repos, kinds, stops = sys.argv[1:6]
w = lambda s: [] if s == "-" else s.split()
json.dump({"focus": focus, "repos": w(repos), "kinds": w(kinds), "max_stops": w(stops),
           "expires": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 86400))}, open(p, "w"))
PY
  [ "$(owner_asked "$PL" "$1" "$TS" "$SID" --by owner --charter "$1/c.json")" = ask ] || bad "[charter] fixture: the charter dialog did not ask ($2)"
  TC=$(cd "$1" && cenv XDG_STATE_HOME="$TS" CLAUDE_CODE_SESSION_ID="$SID" python3 "$PL/scripts/baton.py" sign --by owner --charter "$1/c.json" 2>&1 \
       | sed -n 's/^signed charter \([0-9a-f]\{16\}\) by owner: .*/\1/p')
  [ -n "$TC" ] || bad "[charter] fixture: no charter signed ($2)"
}
# cplans — c.md, c9.md and c7.md on W's main (C2), and the PR heads m1 (row M widened), m2 (focus P9), m3 (a row N2 added),
# m4 (row M's Link cell), m5 (p.md given focus: P8), m6 (row M dropped) and m7 (row M deleted), each a branch of W from C2
cplans() {  # W's plans and the PR heads built as inputs: not a break
  local f
  for f in "c P8" "c9 P9" "c7 P7"; do
    printf -- '---\nfocus: %s\n---\n\n# Plan %s\n\nIntent: kb/intent/i.md · Spec: kb/specs/s.md\n\n## Rows\n\n| Row | Must be true | Trust touches | Link |\n|---|---|---|---|\n' \
      "${f#* }" "${f%% *}" > "$W/kb/plans/${f%% *}.md"
  done
  cat >> "$W/kb/plans/c.md" <<'EOF'
| A | a | workflow .github/workflows/ca.yml; baton batons/cb.sh Stops: secrets; test tests/fixtures/; PRs: 2 | — |
| A2 | a2 | workflow acme/app:.github/workflows/ca2.yml | — |
| B | b | workflow .github/workflows/cbb.yml | — |
| O | o | rbac deploy/r.yaml Role/app/reader | — |
| X | x | rbac deploy/r.yaml Role/app/reader; baton batons/cp.sh Stops: publish | — |
| F | f | workflow .github/workflows/signing-rules.yml; other plugins/p/.claude-plugin/p.json (signs again); workflow .github/workflows/fs.yml (signs again); baton batons/fq.sh Stops: none; baton batons/cw.sh Stops: irreversible-delete; other plugins/x/baton.py GRANT_NEVER | — |
| M | m | workflow .github/workflows/cm.yml | — |
| D | d | workflow .github/workflows/cd.yml | dropped: not needed |
EOF
  printf '| K | k | workflow acme/app:.github/workflows/k9.yml | — |\n' >> "$W/kb/plans/c9.md"
  printf '| A | a | workflow .github/workflows/c7.yml | — |\n' >> "$W/kb/plans/c7.md"
  git_ -C "$W" add -A; git_ -C "$W" commit -q -m "plans of a focus"; C2=$(git_ -C "$W" rev-parse HEAD)
  for f in 'm1|s#^| M | m | workflow .github/workflows/cm.yml |#| M | m | workflow .github/workflows/cm.yml; workflow .github/workflows/cm2.yml |#' \
           'm2|s#^focus: P8$#focus: P9#' 'm3|$a\| N2 | n2 | workflow .github/workflows/cn2.yml | — |' \
           'm4|s#^\(| M | m | workflow .github/workflows/cm.yml | \)— |#\1intent/m-branch |#' \
           'm6|s#^\(| M | m | workflow .github/workflows/cm.yml | \)— |#\1dropped: not needed |#' 'm7|/^| M | m |/d'; do
    git_ -C "$W" checkout -q -b "${f%%|*}" "$C2"; sed -i "${f#*|}" "$W/kb/plans/c.md"; git_ -C "$W" commit -q -am "${f%%|*}"
  done
  git_ -C "$W" checkout -q -b m5 "$C2"; sed -i '1i ---\nfocus: P8\n---\n' "$W/kb/plans/p.md"; git_ -C "$W" commit -q -am m5
  git_ -C "$W" checkout -q main
}
tagged() { [ "$FAIL" = "$2" ] && echo "[$1] ok" || echo "[$1] FAIL"; }   # tagged <tag> <FAIL before its checks>
cok() {   # cok <tag> <label> <mutations...> — covered: rc 0 in dry run, ok touches
  local tag=$1 label=$2 d; shift 2
  d=$(mkfx touch="$W" "$@"); tg "$d"
  eq "$RC/$(merges "$d")" "0/0" "[$tag] $label: rc 0 in dry run"; has "$OUT" "  ok    touches: " "[$tag] …ok touches"
}
cno() {   # cno <tag> <label> <reason> <mutations...> — refused: rc 1, FAIL touches with the reason, no merge call
  local tag=$1 label=$2 why=$3 d; shift 3
  d=$(mkfx touch="$W" "$@"); tg "$d"
  eq "$RC/$(merges "$d")" "1/0" "[$tag] $label: rc 1, no merge call"
  has "$OUT" "  FAIL  touches: " "[$tag] …FAIL touches"; has "$OUT" "$why" "[$tag] …named: $why"
}
c() { printf 'body=plan: %skb/plans/%s' "${2:+$2:}" "$1"; }   # c <file#row> [<owner/repo>] — the PR body's plan line

fam_charter() {
  local C="$TMP/claude" CP CP9 f0
  PL="$C/plugins/cache/vibemaestro/vibemaestro-sdlc/1.0.0"; mkdir -p "$(dirname "$PL")"; mk_plugin_copy "$PL"; cbrain "$C" "$PL"
  TS=$(fresh)/state; tplan; cplans
  tcharter "$W" P8 "acme/app acme/ops" "baton workflow script test" secrets; CP=$TC
  tcharter "$W" P9 "acme/plans" workflow -; CP9=$TC
  f0=$FAIL; charter_inside; tagged charter-inside "$f0"
  f0=$FAIL; charter_floor; tagged charter-floor "$f0"
  f0=$FAIL; charter_row_moved; tagged charter-row-moved "$f0"
  f0=$FAIL; charter_plan_repo; tagged charter-plan-repo-outside "$f0"
  f0=$FAIL; charter_approval_first; tagged approval-first "$f0"
  f0=$FAIL; charter_outside; tagged charter-outside "$f0"
}

charter_inside() {  # [charter-inside] every change a touch of the row inside the envelope: covered, the plan line, the uses
  local T=charter-inside d
  d=$(mkfx touch="$W" file=.github/workflows/ca.yml "$(c c.md#A)"); tg "$d"
  eq "$RC/$(merges "$d")" "0/0" "[$T] a declared workflow of row A of a plan whose focus P8 a charter holds, no approval: rc 0 in dry run"
  has "$OUT" "  ok    touches: 1 trust-layer change(s), each a touch of row A inside charter $CP for P8" "[$T] …ok touches names the row and the charter"
  has "$(printf '%s\n' "$OUT" | grep '^merge-plan: ')" " touches:charter-$CP/A" "[$T] …the plan line says touches:charter-<id>/<row>"
  d=$(mkfx touch="$W" file=.github/workflows/ca.yml baton-head=batons/cb.sh:secrets file=tests/fixtures/a.pin file=tests/fixtures/sub/b.pin "$(c c.md#A)"); tg "$d"
  eq "$RC" 0 "[$T] a workflow, a baton with Stops secrets (within max_stops) and two files of a declared test directory: rc 0"
  has "$OUT" "  ok    touches: 4 trust-layer change(s), each a touch of row A inside charter $CP for P8" "[$T] …all four covered"
  d=$(mkfx touch="$W" file=.github/workflows/ca.yml "$(c c.md#A)"); tg "$d" --merge
  eq "$RC/$(merges "$d")" "0/1" "[$T] --merge: rc 0, one pr merge call"
  eq "$(grep "	touches	" "$TS/vibemaestro/baton/log.tsv" | cut -f8,10,12)" "$(printf 'charter:%s\tused\tacme/app:kb/plans/c.md#a' "$CP")" \
     "[$T] …a touches used line signed charter:<id>, keyed by the plan's repo, path and the row (no commit)"
  has "$(tail -n 1 "$TS/vibemaestro/merge-log.jsonl")" "\"touches\": {\"charter\": \"$CP\"" "[$T] …the merge log line names the charter"
  d=$(mkfx touch="$W" file=.github/workflows/ca.yml "$(c c.md#A)"); tg "$d" --merge
  eq "$RC/$(merges "$d")" "0/1" "[$T] PRs: 2, the second PR: merged"
  has "$(grep "	touches	" "$TS/vibemaestro/baton/log.tsv" | cut -f12)" "acme/app:kb/plans/c.md#a/2" "[$T] …logged as use 2"
  cno "$T" "PRs: 2, a third PR" "charter $CP for P8: an earlier merge used row A of acme/app kb/plans/c.md (2 of its PRs: 2)" \
    file=.github/workflows/ca.yml "$(c c.md#A)"
  has "$OUT" "1 trust-layer change(s), and no approval in force signed from this directory lists row A of acme/app kb/plans/c.md, nor does a charter for P8 cover it: an owner merge" \
    "[$T] …an owner merge, the approvals and the charter named"
  cno "$T" "a fourth PR naming the plan kb/plans/./c.md (GitHub serves the same file; another use key)" \
    "charter $CP for P8: the plan's path kb/plans/./c.md is not written plainly (kb/plans/c.md)" file=.github/workflows/ca.yml "$(c ./c.md#A)"
  cno "$T" "…or kb/plans/x/../c.md" "charter $CP for P8: the plan's path kb/plans/x/../c.md is not written plainly (kb/plans/c.md)" \
    file=.github/workflows/ca.yml "$(c x/../c.md#A)"
  d=$(mkfx touch="$W" file=.github/workflows/ca2.yml fail-path=repos/acme/app/contents/kb/plans/c.md "$(c c.md#A2)"); tg "$d"
  eq "$RC/$(merges "$d")" "2/0" "[$T] the plan cannot be read (HTTP 500) under a charter: rc 2, could not conclude, never an owner merge"
  has "$OUT" "merge_guard: could not conclude: " "[$T] …said so"
}

charter_floor() {  # [charter-floor] the floor and a marked touch, never covered by a charter, declared or not
  local T=charter-floor
  cno "$T" "a touch_inputs path the row declares" "charter $CP for P8: workflow acme/app:.github/workflows/signing-rules.yml (a denied path): it judges a later PR: the floor, never covered by a charter" \
    file=.github/workflows/signing-rules.yml "$(c c.md#F)"
  cno "$T" "a .claude-plugin path the row marks" "charter $CP for P8: other acme/app:plugins/p/.claude-plugin/p.json (a denied path): a .claude-plugin path: the floor, never covered by a charter" \
    file=plugins/p/.claude-plugin/p.json "$(c c.md#F)"
  cno "$T" "a touch the row marks (signs again)" "charter $CP for P8: workflow acme/app:.github/workflows/fs.yml (a denied path): row F marks it (signs again): the owner merges it" \
    file=.github/workflows/fs.yml "$(c c.md#F)"
  cno "$T" "a baton whose head drops a SIGN_AGAIN_STOPS word its base holds" \
    "charter $CP for P8: baton acme/app:batons/fq.sh Stops: none (a denied path): its head drops irreversible-delete, which its base's Stops (irreversible-delete) hold: the floor, never covered by a charter" \
    baton-head=batons/fq.sh:none baton-base=batons/fq.sh:irreversible-delete "$(c c.md#F)"
  cok "$T" "control: the same baton over a base Stops off the floor (publish)" baton-head=batons/fq.sh:none baton-base=batons/fq.sh:publish "$(c c.md#F)"
  has "$OUT" "each a touch of row F inside charter $CP for P8" "[$T] …covered by the charter"
  cno "$T" "a declared baton whose Stops hold a SIGN_AGAIN_STOPS word" \
    "charter $CP for P8: baton acme/app:batons/cw.sh Stops: irreversible-delete (a denied path): Stops irreversible-delete go beyond charter $CP's max_stops (secrets)" \
    baton-head=batons/cw.sh:irreversible-delete "$(c c.md#F)"
  cno "$T" "a declared signing-rules finding of kind other" \
    "charter $CP for P8: other acme/app:plugins/x/baton.py GRANT_NEVER (a finding of signing-rules): a signing-rules finding of kind other changes who signs: the floor, never covered by a charter" \
    sr-red2=other:plugins/x/baton.py:GRANT_NEVER:- "$(c c.md#F)"
}

charter_row_moved() {  # [charter-row-moved] the plan read at the tip and at the PR's head: a PR cannot widen its own row
  local T=charter-row-moved
  cok "$T" "control: the PR's head changes row M's Link cell only" touch-head=m4 file=.github/workflows/cm.yml "$(c c.md#M)"
  cno "$T" "a touch added to row M at the PR's head, and the change it adds" \
    "charter $CP for P8: row M's cells at the PR's head are not those at the default branch's tip: row moved in this PR" \
    touch-head=m1 file=.github/workflows/cm2.yml "$(c c.md#M)"
  cno "$T" "…and a change the row declared before" "row moved in this PR" touch-head=m1 file=.github/workflows/cm.yml "$(c c.md#M)"
  cno "$T" "the plan's focus changed at the PR's head" "charter $CP for P8: the plan says focus P9 at the PR's head, not P8: row moved in this PR" \
    touch-head=m2 file=.github/workflows/cm.yml "$(c c.md#M)"
  cno "$T" "a row the PR's head adds" "charter $CP for P8: row N2 is not one row of the plan at the default branch's tip" \
    touch-head=m3 file=.github/workflows/cn2.yml "$(c c.md#N2)"
  cno "$T" "row M dropped at the PR's head" "charter $CP for P8: row M is dropped at the PR's head (not needed): row moved in this PR" \
    touch-head=m6 file=.github/workflows/cm.yml "$(c c.md#M)"
  cno "$T" "row M deleted at the PR's head" "charter $CP for P8: row M is not one row of the plan at the PR's head: row moved in this PR" \
    touch-head=m7 file=.github/workflows/cm.yml "$(c c.md#M)"
  cno "$T" "a plan with no focus at the tip, given focus P8 at the PR's head: read as today" \
    "1 trust-layer change(s), and no approval in force signed from this directory lists row B of acme/app kb/plans/p.md: an owner merge" \
    touch-head=m5 file=.github/workflows/y.yml "$(c p.md#B)"
}

charter_plan_repo() {  # [charter-plan-repo-outside] the plan's own repository in the charter's repos (decision 09/11)
  local T=charter-plan-repo-outside
  cok "$T" "control: row A2 of the plan in acme/app, its touch on acme/app" file=.github/workflows/ca2.yml "$(c c.md#A2)"
  has "$OUT" "each a touch of row A2 inside charter $CP for P8" "[$T] …covered by the charter"
  cno "$T" "the same plan and row read in acme/plans, a repository the charter does not list" \
    "charter $CP for P8: the plan's repository acme/plans is outside its repos (acme/app, acme/ops)" \
    file=.github/workflows/ca2.yml "$(c c.md#A2 acme/plans)"
}

charter_approval_first() {  # [approval-first] an approval in force that holds the row covers first; the uses are the row's
  local T=approval-first d AB
  tapprove "$W" "B O" 86400 acme/app "$C2" kb/plans/c.md; AB=$TA
  d=$(mkfx touch="$W" file=.github/workflows/cbb.yml "$(c c.md#B)"); tg "$d"
  eq "$RC" 0 "[$T] row B, held by an approval and inside the charter: rc 0"
  has "$OUT" "  ok    touches: 1 trust-layer change(s), each a touch of row B, approval $AB at ${C2:0:12}" "[$T] …the approval covers it"
  has "$(printf '%s\n' "$OUT" | grep '^merge-plan: ')" " touches:$AB/B" "[$T] …the plan line says touches:<approval>/<row>"
  cok "$T" "row O's rbac object, a kind no charter holds, under the approval" sr-red=rbac:deploy/r.yaml:Role/app/reader:- "$(c c.md#O)"
  has "$OUT" "approval $AB at ${C2:0:12}" "[$T] …the approval covers it"
  eq "$(cd "$W" && cenv XDG_STATE_HOME="$TS" python3 "$PL/scripts/baton.py" grant revoke "$AB" >/dev/null 2>&1; echo $?)" 0 "[$T] the approval revoked"
  d=$(mkfx touch="$W" file=.github/workflows/cbb.yml "$(c c.md#B)"); tg "$d"
  eq "$RC" 0 "[$T] …row B: rc 0"
  has "$OUT" "each a touch of row B inside charter $CP for P8" "[$T] …the charter covers it now"
  has "$(printf '%s\n' "$OUT" | grep '^merge-plan: ')" " touches:charter-$CP/B" "[$T] …the plan line says touches:charter-<id>/<row>"
  cno "$T" "…row O's rbac object" "charter $CP for P8: rbac acme/app:deploy/r.yaml Role/app/reader (a finding of signing-rules): kind rbac is outside charter $CP's kinds (baton, workflow, script, test)" \
    sr-red=rbac:deploy/r.yaml:Role/app/reader:- "$(c c.md#O)"
  d=$(mkfx touch="$W" file=.github/workflows/cbb.yml "$(c c.md#B)"); tg "$d" --merge
  eq "$RC/$(merges "$d")" "0/1" "[$T] --merge of row B under the charter: merged"
  tapprove "$W" "B" 86400 acme/app "$C2" kb/plans/c.md
  cno "$T" "an approval of row B signed again: the use the charter took counts" \
    "an earlier merge used row B of acme/app kb/plans/c.md @ ${C2:0:12} (1 of its PRs: 1)" file=.github/workflows/cbb.yml "$(c c.md#B)"
  has "$OUT" "1 trust-layer change(s) not covered by approval $TA of row B, nor does a charter for P8 cover it: an owner merge" "[$T] …neither covers it"
  has "$OUT" "charter $CP for P8: an earlier merge used row B of acme/app kb/plans/c.md (1 of its PRs: 1)" "[$T] …nor the charter, its use taken"
}

charter_outside() {  # [charter-outside] a touch outside the envelope, or no charter in force for the focus here: an owner merge
  local T=charter-outside WT d
  cno "$T" "a declared rbac object: a kind outside the charter's" "charter $CP for P8: rbac acme/app:deploy/r.yaml Role/app/reader (a finding of signing-rules): kind rbac is outside charter $CP's kinds (baton, workflow, script, test)" \
    sr-red=rbac:deploy/r.yaml:Role/app/reader:- "$(c c.md#X)"
  cno "$T" "a declared baton whose Stops (publish) go beyond max_stops" "charter $CP for P8: baton acme/app:batons/cp.sh Stops: publish (a denied path): Stops publish go beyond charter $CP's max_stops (secrets)" \
    baton-head=batons/cp.sh:publish "$(c c.md#X)"
  cno "$T" "a declared change in a repository the charter does not list" "charter $CP9 for P9: workflow acme/app:.github/workflows/k9.yml (a denied path): its repository acme/app is outside charter $CP9's repos (acme/plans)" \
    file=.github/workflows/k9.yml "$(c c9.md#K acme/plans)"
  cno "$T" "a change the row does not declare" "charter $CP for P8: workflow acme/app:.github/workflows/zz.yml (a denied path): not a touch of row X at the default branch's tip" \
    file=.github/workflows/zz.yml "$(c c.md#X)"
  cno "$T" "a row dropped at the tip" "charter $CP for P8: row D is dropped at the default branch's tip (not needed)" file=.github/workflows/cd.yml "$(c c.md#D)"
  cno "$T" "a plan whose focus (P7) no charter holds, while P8's and P9's are in force" \
    "1 trust-layer change(s), and no approval in force signed from this directory lists row A of acme/app kb/plans/c7.md, nor does a charter for P7 cover it: an owner merge" \
    file=.github/workflows/c7.yml "$(c c7.md#A)"
  has "$OUT" "no charter in force for P7 signed from this directory" "[$T] …named"
  WT=$(fresh)/wt; git_ -C "$W" worktree add -q --detach "$WT" main; WT=$(cd "$WT" && pwd -P)
  d=$(mkfx touch="$W" file=.github/workflows/ca2.yml "$(c c.md#A2)"); ( W=$WT; tg "$d"; printf '%s\n%s' "$RC" "$OUT" ) > "$TMP/wt.out"
  eq "$(head -n 1 "$TMP/wt.out")" 1 "[$T] the guard run from another worktree of the project: rc 1"
  has "$(cat "$TMP/wt.out")" "no charter in force for P8 signed from this directory; charter $CP was signed from $W, not from $WT" "[$T] …named"
  eq "$(cd "$W" && cenv XDG_STATE_HOME="$TS" python3 "$PL/scripts/baton.py" grant revoke "$CP" >/dev/null 2>&1; echo $?)" 0 "[$T] the charter revoked"
  cno "$T" "a revoked charter" "no charter in force for P8 signed from this directory; grant $CP was revoked" file=.github/workflows/ca2.yml "$(c c.md#A2)"
}

FAMILIES="fam_conditions fam_checks fam_files fam_behind fam_clean fam_boot fam_amend fam_floor fam_image fam_options fam_merge fam_baton fam_backmerge fam_auto fam_auto_stale fam_touches fam_charter"
PL0="$TMP/plugin-real"; mk_plugin_copy "$PL0"
for f in ${ONLY:-$FAMILIES}; do echo "-- $f"; "$f" "$PL0"; done

echo; summary
