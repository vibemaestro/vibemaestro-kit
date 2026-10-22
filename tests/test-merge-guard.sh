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
#   [B] behind base: refused, printed, listed with --behind-ok, overlapping, unlisted
#   [S] --behind-ok-clean: a docs file both sides changed, accepted when git merge-file and GitHub's test merge agree on a clean
#       merge (and the merged current-state passes its check); refused on a conflict, a test file, a rename, an add, a symlink,
#       other bytes, a merge over the cap; a stale test merge is could-not-conclude; a glob that is not docs-only is rc 64
#   [P] bootstrap: a base with no config and a PR that adds one; the added config's deny globs, the brief, and the refusals
#   [I] image: --require-image by tag and by full reference, missing, another image; the image-bump lane and its faults
#   [O] options: --admin without admin_bypass (64), a short head (64), deny globs unset (65), the head's config has no effect
#   [M] dry run makes no merge call; --merge makes one, pinned; a moved head; the merge log, one line per run, no title or body
#   [L] the back-merge lane: a backmerge/* PR into the default branch (whatever its name) with its head on release merges with
#       a merge commit; one whose head is not on release, or with no release, is refused; another PR whose head is on release is
#       refused; every other PR squashes
#   [A] --behind auto: a fresh test merge (re-asked when stale, a conflict at once), disjoint files or a shared docs file merged
#       clean (not code, a planner's map, a dot-directory or CLAUDE.md), and disjoint suites by the base's planner (the kit's
#       tests/plan.py --suites: the base's files --woken, with the merge base's map as --old; the PR's as CI plans them), read and
#       run from the base only (a PR's planner or map is never read), with no token, PATH or socket; no planner (or bootstrap):
#       every base file must be docs
#   [T] the kit baton through baton.py: check, rehearse = dry run, sign and run = one merge, a deny PR cannot be signed, a
#       second run is refused, a merged PR read back as open is rc 5, an escape from batons/ is refused
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
        ${GENV[@]+"${GENV[@]}"} python3 -B "$pl/gates/merge_guard.py" "$@" 2>&1); RC=$?
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
  deny=$(python3 -c 'import json,re,sys
for l in open(sys.argv[1]):
    lists = re.findall(r"`(\[.*?\])`", l) if "`merge.deny_globs`" in l else []
    if lists: print(" ".join(json.loads(lists[-1]))); break' "$SKILL")
  case " $deny " in *" .vibemaestro/** "*) ok "[F] instrument: the skill proposes .vibemaestro/** as a deny glob";;
                    *) bad "[F] instrument: the skill proposes .vibemaestro/** as a deny glob (got: $deny)";; esac
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
  alone "[P] bootstrap: gate code the PR adds under .vibemaestro/ is denied (CI runs it)" deny bootstrap file=.vibemaestro/gates/pr_sensitive.py -- "${BA[@]}"
  alone "[P] bootstrap: an added config that denies nothing still gets the init default" deny bootstrap=empty-deny file=.github/workflows/ci.yml -- "${BA[@]}" --allow '.github/**'
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
  eq "$RC" 2 "[M] gh pr merge does not answer in time: rc 2"
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
}

# bt <plugin> <case dir> <baton args...> — baton.py from the case directory, the fake gh, mode state in <case>/state; OUT, RC
BT_SWAP=()
bt() {
  local pl=$1 d=$2; shift 2
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
  eq "$(printf '%s\n' "$OUT" | grep -c '^PLAN ')" 1 "[T] …exactly one planned write"
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
  alone "[A] intersecting suites: the base's src/core/z.py wakes app, as the PR's src/app.py does" behind planner auto behind=src/core/z.py -- "${AU[@]}"
  has "$OUT" "(c) the base's files and this PR's files wake the same suite(s): app" "[A] …the shared suite is named under (c)"
  has "$OUT" "merge the base into the branch" "[A] …and the way on is to merge the base"
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

# the stale test merge: real waits between the re-asks, so a family of its own
fam_auto_stale() {
  PL=$1; local d
  d=$(mkfx planner auto=stale behind=lib/y.py); guard "$PL" "$d" "${STD[@]}" "${AU[@]}"
  eq "$RC" 2 "[A] a stale test merge on every read: rc 2 (could not conclude)"
  has "$OUT" "??    behind:" "[A] …behind is what could not be told"
  has "$OUT" "still stale after 4 reads" "[A] …after the re-asks, named"
  eq "$(grep -c '"repos/acme/app/pulls/7"\]' "$d/gh.log")" 4 "[A] …GitHub was asked 4 times"
  d=$(mkfx planner auto=late behind=lib/y.py); guard "$PL" "$d" "${STD[@]}" "${AU[@]}"
  eq "$RC" 0 "[A] stale, then no test merge, then fresh on the third read: rc 0"
  eq "$(grep -c '"repos/acme/app/pulls/7"\]' "$d/gh.log")" 3 "[A] …three reads"
}

FAMILIES="fam_conditions fam_checks fam_files fam_behind fam_clean fam_boot fam_image fam_options fam_merge fam_baton fam_backmerge fam_auto fam_auto_stale"
PL0="$TMP/plugin-real"; mk_plugin_copy "$PL0"
for f in $FAMILIES; do echo "-- $f"; "$f" "$PL0"; done

echo "== planted breaks: each family must go red on a plugin with one break =="
BRK() {  # BRK <label> <family> <needle> <file under the plugin> <old> <new>
  local d="$TMP/break-$1"; mk_plugin_copy "$d"
  mutate "$d/$4" "$5" "$6" && expect_red "$1" "$2" "$d" "$3"
}
G=gates/merge_guard.py
BRK head-unchecked fam_conditions '[C] a head that is not the reported one: rc 1' $G '    cond("head", pr.get("headRefOid") == a.head,' '    cond("head", True,'
BRK match-head-dropped fam_merge '[M] …carrying --match-head-commit' $G '"--squash", "--match-head-commit", a.head]' '"--squash"]'
BRK empty-is-green fam_checks '[K] an empty check list: rc 1' $G '    if not required and green == 0:' '    if False:'
BRK first-run-not-latest fam_checks '[K] an older green run superseded by a newer red one: rc 1' $G '        if key not in best or rank >= best[key][0]:' '        if key not in best:'
BRK skipped-outranks fam_checks '[K] a required check green, then a late skipped duplicate of it: the green run counts (rc 0)' $G '        rank = (r.get("conclusion") != "skipped", float("inf") if t is None else t, _num(r.get("id")))' '        rank = (float("inf") if t is None else t, _num(r.get("id")))'
BRK required-floor-removed fam_checks '[K] a required check that a path filter skipped: rc 1' $G '    for name in required:' '    for name in []:'
BRK deny-unmatched fam_files '[F] a file under a deny glob: rc 1' $G '        hit = [p for p in paths if p not in scaffold and any(match_fold(g, p) for g in deny)]' '        hit = []'
BRK rename-source-ignored fam_files '[F] a rename whose source is outside the brief: rc 1' $G '        if f.get("previous_filename"):' '        if False:'
BRK symlink-unchecked fam_files '[F] a symlink inside the brief: rc 1' $G 'LINK_MODES = {"120000": "symlink", "160000": "submodule"}' 'LINK_MODES = {}'
BRK brief-folds-case fam_files '[F] the brief is case-sensitive: rc 1' $G '    outside = [p for p in paths if not any(C.glob_match(g, p) for g in allowed)]' '    outside = [p for p in paths if not any(match_fold(g, p) for g in allowed)]'
BRK prefix-not-whole-word fam_checks '[K] --accept, a step whose name only starts like the prefix: rc 1' $G '    return name == prefix or (name.startswith(prefix) and name[len(prefix)] in " (:")' '    return name.startswith(prefix)'
BRK every-step-is-any fam_checks '[K] --accept, but the job has one more failed step: rc 1' $G '    return all(any(word_prefix(s, p) for p in prefixes) for s in steps)' '    return any(any(word_prefix(s, p) for p in prefixes) for s in steps)'
BRK behind-unchecked fam_behind '[B] behind base, no --behind-ok: rc 1' $G '    if ahead == 0:' '    if True:'
BRK lane-registry-skipped fam_image '[I] the lane, fault tag-missing: rc 1' $G '            exists = registry.tag_exists(img, tag)' '            exists = True'
BRK lane-non-tag-accepted fam_image '[I] the lane, fault non-tag: rc 1' $G '            problems.append("%s: a changed line holds no old image tag: %s" % (p, x.strip()[:80]))' '            pass'
BRK admin-unchecked fam_options '[O] --admin with merge.admin_bypass false: rc 64' $G '    if a.admin and not mcfg["admin_bypass"]:' '    if False:'
BRK config-from-head fam_options '[O] …and deploy/** is still denied' $G '    return base, base_sha, B.api_raw("repos/%s/contents/%s?ref=%s" % (a.repo, C.CONFIG_REL, base_sha))' '    return base, base_sha, B.api_raw("repos/%s/contents/%s?ref=%s" % (a.repo, C.CONFIG_REL, a.head))'
BRK abbrev-allowed fam_options '[O] an abbreviation of --merge is not --merge: rc 64' $G 'allow_abbrev=False' 'allow_abbrev=True'
BRK baton-merge-arg-allowed fam_baton '[T] --merge among the baton'"'"'s arguments' batons/merge-pr.sh '    --merge | --merge=* | --status | --status=*)' '    --nothing-matches)'
BRK baton-postcheck-head-unread fam_baton '[T] merged, but the post-check reads another head' batons/merge-pr.sh '    *" head $HEAD") ;;' '    *) ;;'
BRK base-unpinned fam_conditions '[C] a PR that targets another branch than the repo'"'"'s default: rc 1' $G '    cond("base", pr.get("baseRefName") == base,' '    cond("base", True,'
BRK status-is-green fam_checks '[K] no check run, one commit status in success' $G '        elif concl == "success" and r.get("kind") != "status":' '        elif concl == "success":'
BRK workflow-by-name fam_checks '[K] two workflow files of the same name' $G '        key = (r.get("kind") or "check", r.get("app") or "", r.get("workflow_id") or r.get("workflow") or "", r.get("name") or "")' '        key = (r.get("kind") or "check", r.get("app") or "", r.get("workflow") or "", r.get("name") or "")'
BRK signed-plan-ignored fam_merge '[M] --merge with a plan other than the signed one' $G '    if a.expect_plan is not None and expected != [plan]:' '    if False:'
BRK own-inputs-unchecked fam_files '[F] the configured CI adapter changed by the PR: rc 1' $G '    mine = sorted(set(paths) & guard_inputs(cfg))' '    mine = []'
BRK tag-rename-allowed fam_image '[I] the lane, fault rename-tag: rc 1' $G '            problems.append("%s: a tag file is renamed or removed, so its content cannot be proved" % p)' '            pass'
BRK tag-line-unanchored fam_image '[I] the lane, fault sidecar: rc 1' $G '        if not anchored:' '        if False:'
BRK pending-is-open fam_merge '[M] …--status says pending' $G '    elif pending:' '    elif False:'
BRK rev-rename-allowed fam_image '[I] the lane, the revision file renamed: rc 1' $G '        problems.append("%s is renamed or removed" % rev_file)' '        pass'
BRK pending-cleared fam_merge '[M] …--status still says pending' $G '                elif d.get("result") == "merged":' '                else:'
BRK base-not-reread fam_merge '[M] the PR retargeted to another branch after the check' $G '        if now.get("baseRefName") != self.base:' '        if False:'
BRK unconfirmed-is-ok fam_merge '[M] merged, then the state cannot be read: rc 2' $G '            self.log("merged-unconfirmed")
            return INFRA' '            self.log("merged-unconfirmed")
            return OK'
BRK newline-marker-splits fam_image '[I] the lane: a tag line with no final newline' $G '        if ln.startswith("\\"):' '        if False:'
BRK accept-colon-split fam_checks "[K] --accept for a check whose name holds ':'" $G '    head = (name or "") + ":"' '    head = (name or "").split(":")[0] + ":"'
BRK time-as-text fam_checks '[K] a red run half a second after a green one' $G '    m = TIME_RE.fullmatch(s) if isinstance(s, str) else None' '    m = TIME_RE.fullmatch(s[:19] + "Z") if isinstance(s, str) else None'
BRK branch-name-ascii fam_conditions "[C] a default branch with a legal '+' in its name" $G 'BRANCH_BAD = re.compile(' 'BRANCH_BAD = re.compile(r"[+]|" + '
BRK symlinked-input-allowed fam_files '[F] the CI adapter is a symlink at the base' $G '    links = [p for p, m in sorted(modes.items()) if m is not None and m not in ("100644", "100755")]' '    links = []'
BRK merge-timeout-not-pending fam_merge '[M] …logged as merge-pending (the request may have reached GitHub)' $G '            self.log("merge-pending")
            return INFRA
        if rc != 0:' '            self.log("error")
            return INFRA
        if rc != 0:'
BRK status-guesses-open fam_merge "[M] --status when the base config cannot be read: rc 2" $G '    cfg = base_and_config(a)[2]' '    cfg = None'
BRK branch-dot-component fam_options '[O] branch_ok agrees with git' $G '|(^|/)\.|' '|'
BRK input-missing-is-ok fam_files '[F] the base tree is truncated before the adapter' $G '    if missing:' '    if False:'
# --behind-ok-clean, mergeable first, bootstrap
BRK clean-ignored fam_clean '[S] a clean shared current-state: rc 0' $G '        if overlap and a.clean_globs:' '        if False:'
BRK conflict-ignored fam_clean '[S] …the conflict is named' $G '        if rc:
            refused.append' '        if False:
            refused.append'
BRK any-shared-file fam_clean '[S] a shared test file, clean, listed in --behind-ok: rc 1' $G '    cand = [p for p in overlap if any(C.glob_match(g, p) for g in a.clean_globs)]' '    cand = list(overlap)'
BRK rename-merged fam_clean '[S] a shared doc renamed away on main: rc 1' $G 'for who, by, prev in side if p in prev or (by.get(p) or {}).get("status") != "modified"]' 'for who, by, prev in side if False]'
BRK link-merged fam_clean '[S] a shared doc that is a symlink at the base: rc 1' $G '        if modes.get(p) not in ("100644", "100755"):' '        if False:'
BRK bytes-uncompared fam_clean "[S] GitHub's test merge holds other bytes than git merge-file: rc 1" $G '        if merged != texts[3].encode("utf-8", "surrogateescape"):' '        if False:'
BRK cap-unchecked fam_clean '[S] the merged current-state over its byte cap (each side under it): rc 1' $G '            probs = CS.problems(merged, prof)' '            probs = []'
BRK stale-test-merge fam_clean "[S] GitHub's test merge is of another base: rc 2" $G '    if parents != [base_sha, a.head]:' '    if False:'
BRK any-extension fam_clean "[S] --behind-ok-clean 'kb/**' (not a docs glob): rc 64" $G '    if not segs[-1].endswith(".md"):' '    if False:'
BRK tests-root fam_clean "[S] --behind-ok-clean 'tests/a.md' (not a docs glob): rc 64" $G '    if segs[0].lower() in DOC_ROOTS_REFUSED:' '    if False:'
BRK wildcard-root fam_clean "[S] --behind-ok-clean '**/*.md' (not a docs glob): rc 64" $G '    if any(c in segs[0] for c in "*?"):' '    if False:'
BRK mergeable-late fam_conditions '[C] …before the CI runs are read' $G '        if not mergeable(a, pr, V):' '        if not mergeable(a, pr, V) and False:'
BRK bootstrap-off fam_boot '[P] bootstrap: the base has no config, the PR adds one: rc 0' $G '        boot = bootstrap_config(a, self.base) if text is None else None' '        boot = None'
BRK bootstrap-modified fam_boot '[P] the PR modifies (not adds) the config the base lacks: rc 65' $G 'f.get("filename") == C.CONFIG_REL and f.get("status") == "added" for f in files' 'f.get("filename") == C.CONFIG_REL for f in files'
BRK bootstrap-scaffold-any fam_boot '[P] bootstrap: gate code the PR adds under .vibemaestro/ is denied (CI runs it): rc 1' $G '        if p == C.CONFIG_REL or (p.endswith(".md") and any(' '        if p.startswith(".vibemaestro/") or (p.endswith(".md") and any('
BRK bootstrap-no-floor fam_boot '[P] bootstrap: an added config that denies nothing still gets the init default: rc 1' $G '                    deny = list(deny) + [g for g in C.MERGE_DENY_DEFAULT if g not in deny]' '                    deny = list(deny)'
BRK bootstrap-image fam_boot '[P] bootstrap with --require-image (the registry would be the PR'"'"'s own): rc 64' $G '            if a.require_image is not None:
                raise Usage("--require-image is refused' '            if False:
                raise Usage("--require-image is refused'
BRK ledger-path-literal fam_clean '[S] the ledger is current_state.path of the config: docs/state.md over its cap: rc 1' $G '        if p == led:' '        if p == "kb/current-state.md":'
BRK nul-merged fam_clean '[S] a shared doc whose text holds a NUL byte: rc 1' $G '        if any("\x00" in t or "\ufffd" in t for t in texts):' '        if False:'
BRK added-merged fam_clean '[S] a doc both sides added: rc 1' $G '(by.get(p) or {}).get("status") != "modified"]' '(by.get(p) or {}).get("status") not in ("modified", "added")]'
BRK clean-unplanned fam_clean '[S] …and how many shared files merged clean' $G '                + (" clean %d" % len(self.clean) if self.clean else "") + (' '                + ('
BRK bootstrap-on-error fam_boot '[P] the base config cannot be read (not a 404): rc 2' gates/backends/__init__.py '    if "HTTP 404" in err:' '    if True:'
BRK bootstrap-external fam_boot '[P] …refused as bootstrap, named' $G '    if ext:' '    if False:'
BRK bootstrap-no-deny fam_boot "[P] …named as the added config's fault" $G '    if cfg["merge"]["deny_globs"] is None:' '    if False:'
BRK bootstrap-admin fam_boot '[P] bootstrap with --admin (the added config grants admin_bypass): rc 64' $G '            if a.admin:' '            if False:'
BRK bootstrap-lane fam_boot '[P] bootstrap with --image-bump (the added config turns the lane on): rc 64' $G '            if a.image_bump:
                raise Usage("--image-bump is refused' '            if False:
                raise Usage("--image-bump is refused'
BRK bootstrap-deny-all fam_boot '[P] bootstrap: the base has no config, the PR adds one: rc 0' $G '    return out


def bootstrap_config' '    return set()


def bootstrap_config'
BRK baton-drops-args fam_baton '[T] …the baton passes --behind-ok-clean to the guard' batons/merge-pr.sh 'guard_read() { python3 -I -B "$BATON_PLUGIN_ROOT/gates/merge_guard.py" ${ARGS[@]+"${ARGS[@]}"} "$@"; }' 'guard_read() { python3 -I -B "$BATON_PLUGIN_ROOT/gates/merge_guard.py" --repo acme/app --pr 7 --head a1b2c3d4e5f60718293a4b5c6d7e8f9001122334 --brief brief.txt "$@"; }'
BRK lane-ignores-release fam_backmerge '[L2]' $G '    on = status in ("ahead", "identical")' '    on = True'
BRK lane-any-ref fam_backmerge '[L4]' $G '    named = (pr.get("headRefName") or "").startswith(BACKMERGE_PREFIX)' '    named = True'
BRK lane-squashes fam_backmerge '[L1] …merged with a merge commit' $G '"--merge" if self.merge_commit else "--squash"' '"--squash"'
BRK lane-plan-says-squash fam_backmerge '[L1] …and the plan line says merge-commit' $G '"merge-commit" if self.merge_commit else "squash"' '"squash"'
BRK lane-any-base fam_backmerge '[L7]' $G '    if base != default:' '    if False:'
BRK lane-literal-main fam_backmerge '[L8]' $G '    if base != default:' '    if base != "main":'
BRK lane-no-release-passes fam_backmerge '[L3]' $G '        if named:
            V.cond("backmerge", False, "the head ref %s is a back-merge, and there is no' '        if False:
            V.cond("backmerge", False, "the head ref %s is a back-merge, and there is no'
BRK lane-on-release-squashes fam_backmerge '[L4]' $G '    V.cond("backmerge", not on,' '    V.cond("backmerge", True,'
BRK auto-sides-joined fam_auto '[A] disjoint: the base'"'"'s lib/y.py' $G '        meet = sorted(bs & ps)' '        meet = sorted(bs | ps)'
BRK auto-meet-ignored fam_auto '[A] intersecting suites: the base'"'"'s src/core/z.py wakes app' $G '    if meet:' '    if False:'
BRK auto-woken-dropped fam_auto '[A] disjoint: the base'"'"'s lib/y.py' $G '[(base_side, ["--woken"]), (paths, [])]' '[(base_side, []), (paths, [])]'
BRK auto-pr-side-woken fam_auto '[A] the base changed an @always suite'"'"'s own file' $G '[(base_side, ["--woken"]), (paths, [])]' '[(base_side, ["--woken"]), (paths, ["--woken"])]'
BRK auto-old-dropped fam_auto '[A] main'"'"'s map moved src/new/* onto web, and the PR'"'"'s files are elsewhere: rc 0' $G '(["--old", os.path.join(d, "old")] if i == 0 and old is not None else [])' '[]'
BRK auto-shared-off-base-side fam_auto '[A] a shared docs file that merges clean, but a suite reads it' $G '    verdict, detail = suites_apart(a, base_sha, cmp_, planner, base_files, paths, notes, cfg)' '    verdict, detail = suites_apart(a, base_sha, cmp_, planner, [f for f in base_files if f not in shared], paths, notes, cfg)'
BRK auto-no-docs-class fam_auto '[A] a shared docs file that merges clean and that no suite reads' $G '    return (p.endswith(".md") and segs[0].lower()' '    return (False and segs[0].lower()'
BRK auto-planner-data-class fam_auto '[A] …refused under (b): only docs merge clean' $G 'cfg, lambda p: doc_path(p, cfg), tm)' 'cfg, lambda p: doc_path(p, cfg) or p == "tests/suites.map", tm)'
BRK auto-any-shared-file fam_auto '[A] …refused: code is not a clean class' $G 'cfg, lambda p: doc_path(p, cfg), tm)' 'cfg, lambda p: True, tm)'
BRK auto-agent-md-docs fam_auto '[A] a shared CLAUDE.md that merges clean (an agent loads it as instructions): rc 1' $G 'segs[-1].lower().split(".")[0] not in AGENT_MD and' 'True and'
BRK auto-pr-full-empty-base fam_auto '[A] a PR that edits the map, behind main by only a file the base map excludes: rc 1' $G '        meet = sorted(bs) or base_side' '        meet = sorted(bs)'
BRK auto-agent-name-short fam_auto '[A] a shared QWEN.md that merges clean (no suite reads it): rc 1' $G '"gemini", "qwen", "crush", "skill")' '"gemini")'
BRK auto-agent-name-stem fam_auto '[A] a shared AGENTS.override.md that merges clean (no suite reads it): rc 1' $G 'segs[-1].lower().split(".")[0] not in AGENT_MD' 'segs[-1].lower()[:-3] not in AGENT_MD'
BRK auto-agent-dirs fam_auto '[A] a shared skills/x.md that merges clean (no suite reads it): rc 1' $G ' and not any(s.lower() in AGENT_DIRS for s in segs[:-1])' ''
BRK auto-rules-dirs fam_auto "[A] a shared guides/x.md under the config's rules.dirs 'guides/': rc 1" $G '            and not any(d == "." or low.startswith(d + "/") for d in dirs))' '            )'
BRK auto-rules-dirs-raw fam_auto "[A] a shared guides/x.md under the config's rules.dirs './guides': rc 1" $G 'dirs = [posixpath.normpath(d).lower() for d in' 'dirs = [d.rstrip("/").lower() for d in'
BRK auto-rules-dirs-case fam_auto "[A] a shared guides/x.md under the config's rules.dirs 'Guides': rc 1" $G 'dirs = [posixpath.normpath(d).lower() for d in' 'dirs = [posixpath.normpath(d) for d in'
BRK auto-dot-dir-docs fam_auto '[A] a shared .claude/x.md that merges clean (a dot-directory): rc 1' $G ' and not any(s.startswith(".") for s in segs)' ''
BRK auto-conflict-ignored fam_auto '[A] …the conflict is named' $G '    if refused:
        notes.append("(c) not read")' '    if False:
        notes.append("(c) not read")'
BRK auto-fallback-any-file fam_auto '[A] no planner: a base file that is code: rc 1' $G '        code = [f for f in base_side if not doc_path(f, cfg)]' '        code = []'
BRK auto-conflict-is-mergeable fam_auto "[A] GitHub's fresh test merge reports a conflict: rc 1" $G '        if ok is False:' '        if False:'
BRK auto-conflict-null-waits fam_auto '[A] GitHub reports a conflict and no test merge at all' $G '        if ok is False:' '        if False:'
BRK auto-bootstrap-planner fam_auto '[A] bootstrap: the PR'"'"'s own config names a planner' $G '    planner = None if getattr(a, "boot", False) else cfg["merge"]["planner"]' '    planner = cfg["merge"]["planner"]'
BRK auto-planner-from-head fam_auto '[A] a PR that edits tests/plan.py (its head copy would print no suite): rc 1' $G '        t = raw_at(a, rel, sha)' '        t = raw_at(a, rel, a.head)'
BRK auto-map-from-head fam_auto '[A] …the head'"'"'s map was never read' $G '        t = raw_at(a, rel, sha)' '        t = raw_at(a, rel, sha if rel.endswith(".py") else a.head)'
BRK auto-planner-env fam_auto '[A] the planner runs with no token' $G '        env = {"PATH": "", "HOME": root, "LC_ALL": "C"}' '        env = dict(os.environ, HOME=root, PATH="")'
BRK auto-planner-socket fam_auto '[A] the planner runs with no token' $G '"socket.socket = socket.create_connection = socket.getaddrinfo = socket.socketpair = _refuse\n"' '"pass\n"'
BRK auto-input-link-read fam_auto '[A] a planner input that is a symlink at the base: rc 2' $G '    bad = [p for p in rels if modes.get(p) not in ("100644", "100755") and not (absent_ok and modes.get(p) is None)]' '    bad = []'
BRK auto-with-behind-ok fam_auto '[A] --behind auto with --behind-ok: rc 64' $G '    if a.auto and (a.behind_globs or a.clean_globs):' '    if False:'
BRK auto-baton-drops-args fam_auto '[A] …the baton passes --behind auto to the guard' batons/merge-pr.sh 'guard_read() { python3 -I -B "$BATON_PLUGIN_ROOT/gates/merge_guard.py" ${ARGS[@]+"${ARGS[@]}"} "$@"; }' 'guard_read() { python3 -I -B "$BATON_PLUGIN_ROOT/gates/merge_guard.py" --repo acme/app --pr 7 --head a1b2c3d4e5f60718293a4b5c6d7e8f9001122334 --brief brief.txt "$@"; }'
BRK auto-stale-accepted fam_auto_stale '[A] a stale test merge on every read: rc 2' $G '        if got != [base_sha, a.head]:' '        if False:'
BRK auto-no-reask fam_auto_stale '[A] stale, then no test merge, then fresh on the third read: rc 0' $G 'TEST_MERGE_READS, TEST_MERGE_WAIT_S = 4, 2' 'TEST_MERGE_READS, TEST_MERGE_WAIT_S = 1, 2'
PLC="$TMP/break-none"; mk_plugin_copy "$PLC"
QN=0; okdef=$(declare -f ok); baddef=$(declare -f bad); sp=$PASS; sf=$FAIL
ok() { :; }; bad() { QN=$((QN+1)); }
for f in $FAMILIES; do "$f" "$PLC" >/dev/null 2>&1; done
eval "$okdef"; eval "$baddef"; PASS=$sp; FAIL=$sf
eq "$QN" 0 "control: an unbroken copy passes every family (no failed check)"

echo; summary
