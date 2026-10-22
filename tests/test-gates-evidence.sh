#!/bin/bash
# =============================================================================
# Gate pr-evidence (plugins/vibemaestro-sdlc/gates/pr_evidence.py and its workflow template gates/workflows/pr-evidence.yml)
# =============================================================================
# Run: bash tests/test-gates-evidence.sh
#
# An AI review pinned to the PR's current head, and E2E evidence when the PR changes `evidence.ui_paths`: what counts, what is stale,
# what carries over a pure merge of the base (patch-id, on real git), and the workflow's fences (the re-run job: the commenter's
# association first, no checkout, actions: write on that job only). The cases are tests/fixtures/evidence_cases.py; each family
# runs on the real plugin, then on a copy with one planted break that must turn it red. No network.
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

echo "== planted breaks: each family must go red on a plugin with one break =="
BRK() {  # BRK <label> <family> <needle> <file under the plugin> <old> <new>
  local d="$TMP/break-$1"; mk_plugin_copy "$d"
  mutate "$d/$4" "$5" "$6" && expect_red "$1" "$2" "$d" "$3"
}
BRK review-missing-passes fam_decide '[D] no comment at all' gates/pr_evidence.py \
  '            red = True
            lines.append("✗ %s: %s" % (kind, missing))' '            lines.append("✗ %s: %s" % (kind, missing))'
BRK stale-review-passes fam_decide '[D] a review pinned to an older head' gates/pr_evidence.py \
  '        if sha == head:' '        if sha:'
BRK short-sha-counts fam_decide '[D] a short SHA' gates/pr_evidence.py \
  '    m = re.match(r"([0-9a-fA-F]{40})\b", rest)' '    m = re.match(r"([0-9a-fA-F]{7,40})\b", rest)'
BRK outsider-counts fam_decide '[D] a review by an outside commenter' gates/pr_evidence.py \
  '        if c.get("association") not in TRUSTED:' '        if False:'
BRK fence-counts fam_decide '[D] E2E pass inside a fence does not count' gates/pr_evidence.py \
  '    return gc.strip_fences(SCRIPT.sub(lambda m: "\n" * m.group(0).count("\n"), text))' '    return SCRIPT.sub(lambda m: "\n" * m.group(0).count("\n"), text)'
BRK ui-change-no-e2e-passes fam_decide '[D] a UI change without E2E evidence' gates/pr_evidence.py \
  '            if p and any(gc.sdlc_config.glob_match(g, p) for g in globs):' '            if False:'
BRK rename-old-path-ignored fam_decide '[D] a rename out of a UI path' gates/pr_evidence.py \
  '        for p in (f.get("filename"), f.get("previous_filename")):' '        for p in (f.get("filename"),):'
BRK e2e-reason-unchecked fam_decide '[D] E2E không chạy with no reason' gates/pr_evidence.py \
  '            if kind == "skip" and reason_len(reason) < MIN_REASON:' '            if False:'
BRK e2e-stale-passes fam_decide '[D] an E2E line pinned to an older head' gates/pr_evidence.py \
  '        if sha == head:' '        if sha == head or kind == "e2e":'
BRK oldest-wins fam_decide '[D] the newest review decides' gates/pr_evidence.py \
  '        c, sha, short = cands[-1]' '        c, sha, short = cands[0]'
BRK own-commits-carry fam_carry "[C] commits of the PR's own after the evidence" gates/pr_evidence.py \
  '            if rc != 0 or own.strip():' '            if rc != 0:'
BRK stranger-carries fam_carry '[C] evidence on a SHA that is not an ancestor' gates/pr_evidence.py \
  '        if gc.git(["merge-base", "--is-ancestor", sha, head], cwd)[0] != 0:' '        if False:'
BRK crlf-hides fam_decide '[D] a review typed with CRLF' gates/pr_evidence.py \
  '    text = unicodedata.normalize("NFC", (body or "").replace("\r\n", "\n").replace("\r", "\n"))' '    text = unicodedata.normalize("NFC", body or "")'
BRK zero-width-reason fam_decide '[D] a reason of zero-width spaces' gates/pr_evidence.py \
  '            if kind == "skip" and reason_len(reason) < MIN_REASON:' '            if kind == "skip" and len(reason) < MIN_REASON:'
BRK script-visible fam_decide '[D] E2E pass inside a script element' gates/pr_evidence.py \
  '    return gc.strip_fences(SCRIPT.sub(lambda m: "\n" * m.group(0).count("\n"), text))' '    return gc.strip_fences(text)'
BRK unclean-merge-carries fam_carry '[C] a merge that moves the reviewed change' gates/pr_evidence.py \
  '            elif dirty:' '            elif False:'
BRK base-move-ignored fam_decide '[D] the base moved since the run' gates/pr_evidence.py \
  '    if facts.get("base_moved"):' '    if False:'
BRK rerun-picks-skipped fam_workflow '[W] rerun: it picks the newest run whose evidence job' gates/workflows/pr-evidence.yml \
  'select(.name == "evidence")' 'select(.name != "x")'
BRK rerun-any-commenter fam_workflow '[W] rerun: a comment by NONE re-runs nothing' gates/workflows/pr-evidence.yml \
  "    if: (github.event.comment.author_association == 'OWNER' || github.event.comment.author_association == 'MEMBER' || github.event.comment.author_association == 'COLLABORATOR') && " "    if: "
BRK rerun-checks-out fam_workflow '[W] rerun: no action at all' gates/workflows/pr-evidence.yml \
  "      - name: re-run the evidence check" "      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
      - name: re-run the evidence check"
BRK rerun-runs-repo-file fam_workflow '[W] rerun: its script runs no repository file' gates/workflows/pr-evidence.yml \
  "          wf=\${WORKFLOW_REF%%@*}" "          python3 .vibemaestro/gates/pr_evidence.py --help || true
          wf=\${WORKFLOW_REF%%@*}"
BRK write-on-evidence fam_workflow '[W] only rerun can write' gates/workflows/pr-evidence.yml \
  "      contents: read
      pull-requests: read
      issues: read" "      contents: write
      pull-requests: read
      issues: read"
BRK evidence-on-draft fam_workflow '[W] …not on a draft' gates/workflows/pr-evidence.yml \
  "github.event_name == 'pull_request' && github.event.pull_request.draft == false &&" "github.event_name == 'pull_request' &&"
BRK rerun-on-draft fam_workflow '[W] rerun: a payload without the draft field counts as a draft' gates/workflows/pr-evidence.yml \
  "toJSON(github.event.issue.draft) == 'false'" "github.event.issue.draft == false"
BRK no-ready-type fam_workflow '[W] ready_for_review starts the round' gates/workflows/pr-evidence.yml \
  "types: [opened, edited, synchronize, reopened, ready_for_review]" "types: [opened, edited, synchronize, reopened]"
PLC="$TMP/break-none"; mk_plugin_copy "$PLC"
QN=0; okdef=$(declare -f ok); baddef=$(declare -f bad); sp=$PASS; sf=$FAIL
ok() { :; }; bad() { QN=$((QN+1)); }
for f in $FAMILIES; do "$f" "$PLC" >/dev/null 2>&1; done
eval "$okdef"; eval "$baddef"; PASS=$sp; FAIL=$sf
eq "$QN" 0 "control: an unbroken copy passes every family (no failed check)"

echo; summary
