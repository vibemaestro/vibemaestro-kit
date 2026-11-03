#!/bin/bash
# =============================================================================
# Gate pr-evidence (plugins/vibemaestro-sdlc/gates/pr_evidence.py and its workflow template gates/workflows/pr-evidence.yml)
# =============================================================================
# Run: bash tests/test-gates-evidence.sh
#
# An AI review pinned to the PR's current head, and E2E evidence when the PR changes `evidence.ui_paths`: what counts, what is stale,
# what carries over a pure merge of the base (patch-id, on real git), and the workflow's fences (the re-run job: the commenter's
# association, or the repo's own App, first; no checkout, actions: write on that job only). The cases are tests/fixtures/evidence_cases.py; each family
# runs on the real plugin. No network.
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
CASES="$HERE/fixtures/evidence_cases.py"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
python3 -c 'import yaml' 2>/dev/null || { bad "PyYAML is missing: the workflow cannot be read"; summary; exit 1; }

cases() {  # cases <family> <plugin dir> — the checker's lines as ok/bad
  local out line rc d; d=$(fresh)
  out=$(cenv python3 "$CASES" "$1" "$2" "$d" 2>&1); rc=$?
  [ "$rc" = 0 ] || bad "[$1] the cases exit $rc: ${out:0:300}"
  while IFS= read -r line; do
    case "$line" in
      ok$'\t'*) ok "${line#ok$'\t'}";;
      FAIL$'\t'*) bad "${line#FAIL$'\t'}";;
    esac
  done <<<"$out"
}
fam_decide()   { cases decide "$1"; }
fam_carry()    { cases carry "$1"; }
fam_workflow() { cases workflow "$1"; }

# the command line: --facts, the exit codes, the messages on stdout
fam_cli() {
  local P=$1 d out rc; d=$(fresh)
  printf '{"head": "%s", "files": [], "capped": false, "comments": []}' "$(printf 'a%.0s' $(seq 40))" > "$d/f.json"
  out=$(cd "$d" && cenv python3 "$P/gates/pr_evidence.py" --facts "$d/f.json" 2>&1); rc=$?
  eq "$rc" 1 "[L] no review on the head: rc 1"; has "$out" "pr-evidence: ✗ review: no AI-review comment pins the head" "[L] …the message"
  printf '{"head": "", "comments": []}' > "$d/g.json"
  out=$(cd "$d" && cenv python3 "$P/gates/pr_evidence.py" --facts "$d/g.json" 2>&1); rc=$?
  eq "$rc" 2 "[L] no head SHA: could not conclude (rc 2), never green"
  (cd "$d" && cenv python3 "$P/gates/pr_evidence.py" --pr 1 >/dev/null 2>&1); eq "$?" 64 "[L] --pr without --repo and --base: rc 64"
}

FAMILIES="fam_decide fam_carry fam_workflow fam_cli"
echo "== the real plugin =="
PL0="$TMP/plugin-real"; mk_plugin_copy "$PL0"
for f in $FAMILIES; do echo "-- $f"; "$f" "$PL0"; done

echo; summary
