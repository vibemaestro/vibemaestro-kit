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
fam_exempt()   { cases exempt "$1"; }

# evidence.exempt is read at the BASE: a PR that adds the key to its own config is not exempt
ev_base() { (cd "$1" && cenv python3 "$2/gates/pr_evidence.py" --facts "$1/../facts.json" --config-ref base 2>&1); }
fam_exempt_base() {
  local P=$1 d r out rc ex; d=$(fresh); r="$d/repo"; mkdir -p "$r/.vibemaestro"
  ex='{"evidence": {"exempt": {"app": "acme-gate", "paths": ["clusters/*/products/*/dev/kustomization.yaml"]}}}'
  python3 -I -B - "$d/facts.json" <<'PY'
import json, sys
old = "    digest: sha256:dca30c0eaf8f0ba4f76b5c5e67c5ce55274c9118e6a07cf72d65c4c1fdea671f"
new = "    digest: sha256:b37c8dd5fc3b4d5d53fd996448d618755e010abd8d49409cae8ce55b5334051c"
json.dump({"head": "a" * 40, "comments": [], "capped": False, "author": "acme-gate[bot]", "author_type": "Bot",
           "files": [{"filename": "clusters/x/products/p/dev/kustomization.yaml", "status": "modified",
                      "patch": "@@ -4,3 +4,3 @@\n   - name: ghcr.io/acme/p\n-%s\n+%s" % (old, new)}]}, open(sys.argv[1], "w"))
PY
  git -C "$r" init -q -b main && echo '{}' > "$r/.vibemaestro/sdlc.json" && git -C "$r" add -A \
    && git -C "$r" -c user.name=t -c user.email=t@t commit -qm base && git -C "$r" branch base
  printf '%s' "$ex" > "$r/.vibemaestro/sdlc.json"; git -C "$r" -c user.name=t -c user.email=t@t commit -qam "the PR adds the key"
  out=$(capped ev_base "$r" "$P"); rc=$?
  cap_red "$rc" "[XB] a PR that adds evidence.exempt to its own config" \
    || { eq "$rc" 1 "[XB] a PR that adds evidence.exempt to its own config is not exempt: the base has no key (rc 1)"
         case "$out" in *exempt*) bad "[XB] …and no exempt line: $out";; *) ok "[XB] …and no exempt line";; esac; }
  git -C "$r" branch -f base HEAD
  out=$(ev_base "$r" "$P"); rc=$?
  eq "$rc" 0 "[XB] the same PR once the base holds the key: exempt (rc 0)"; has "$out" "pr-evidence: exempt: opened by acme-gate[bot]" "[XB] …its line"
}

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

FAMILIES="fam_decide fam_carry fam_workflow fam_cli fam_exempt fam_exempt_base"
echo "== the real plugin =="
PL0="$TMP/plugin-real"; mk_plugin_copy "$PL0"
for f in $FAMILIES; do echo "-- $f"; "$f" "$PL0"; done

echo; summary
