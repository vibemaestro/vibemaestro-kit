#!/bin/bash
# =============================================================================
# Gate workflow templates (plugins/vibemaestro-sdlc/gates/workflows/*.yml), rendered by scripts/install_gates.py and then run
# =============================================================================
# Run: bash tests/test-gates-workflows.sh
#
# The gate scripts have their own suites; this file checks the WIRING that they cannot see. A wiring fault leaves every script right and the
# gate useless. The families of the hub's commit-discipline and sensitive-info workflow tests, for all five templates:
#   1. trigger: the types that make the gate run again (a body edit for the exemption line, a new comment for a leak, ready_for_review
#      for a draft that becomes ready) are present
#   2. source: the PR is read through gh at run time, never from the event payload; the head is only fetched as data
#   3. trust: the job checks out the BASE (or the default branch), never the PR head, so config, allowlist and script are the old ones
#   4. log: no xtrace, no `${{ }}` inside `run:`, only masked values printed
#   5. exit code: the step's own shell block is RUN against scratch repos and a fake gh: a planted fault is red, a clean case is green,
#      gh failing is not green, a PR that relaxes its own limit and neutralises its own gate is still judged by the base
#   6. pins: every `uses:` is pinned by a full commit SHA (or local), and only actions/checkout is used
#   7. runner: `runs-on: ${{ vars.CI_GATE_RUNNER || vars.<ci.runner_var> || '<ci.runner_default>' }}`, from flags, from config, or the defaults;
#      with ci.runner_default `self-hosted only` the last operand is a failing fromJSON instead of a label, in every job, and a kept old file is warned about
#   8. the kit's OWN workflows (not the templates): each job's `runs-on` is evaluated, and in a private repository with the runner variables
#      unset it fails instead of answering a hosted label (tests/fixtures/runs_on_check.py)
# Then each fault above is planted in a copy of the rendered template and the checker must go red (a checker that cannot go red proves
# nothing). The checker is tests/fixtures/workflow_check.py; it reads YAML with a parser, not grep. No network, no sleep.
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
# shellcheck source=fixtures/gates.sh
. "$HERE/fixtures/gates.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
CHECK="$HERE/fixtures/workflow_check.py"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
export PYTHONDONTWRITEBYTECODE=1
python3 -c 'import yaml' 2>/dev/null || { bad "PyYAML is missing: the workflows cannot be read"; summary; exit 1; }
TPL="$PLUGIN/gates/workflows"
KINDS="commit-discipline pr-title pr-body pr-sensitive dead-branches"

echo "== templates and pins =="
for k in $KINDS; do [ -f "$TPL/$k.yml" ] && ok "template $k.yml exists" || bad "template $k.yml is missing"; done
for k in $KINDS; do
  n=$(grep -c -F '@@RUNNER_VAR@@' "$TPL/$k.yml"); m=$(grep -c -F '@@RUNNER_DEFAULT@@' "$TPL/$k.yml")
  [ "$n" = 1 ] && [ "$m" = 1 ] && ok "$k.yml carries the two runner markers once" || bad "$k.yml markers: var $n, default $m"
done
UNPINNED=$(cd "$SRC_ROOT" && grep -r -n 'uses:' plugins/vibemaestro-sdlc/gates | grep -v -E -e 'uses: \./' -e '@[0-9a-f]{40}' || true)
empty "$UNPINNED" "every 'uses:' under gates/ is local or pinned by a full 40-character SHA (the kit's rule)"
mkdir -p "$TMP/ctl"; sed 's/@[0-9a-f]\{40\} # v4.2.2/@v4/' "$TPL/commit-discipline.yml" > "$TMP/ctl/c.yml"
CTL=$(grep -n 'uses:' "$TMP/ctl/c.yml" | grep -v -E -e 'uses: \./' -e '@[0-9a-f]{40}' || true)
nonempty "$CTL" "control: the same grep flags a template whose pin was replaced by a tag"
[ "$(grep -c -E 'uses: actions/checkout@[0-9a-f]{40} # v' "$TPL"/*.yml | awk -F: '{s+=$2} END{print s}')" = 6 ] && ok "each of the six templates has one pinned checkout with its tag in a comment" || bad "checkout pins are not one per template"

echo "== rendering (install_gates.py) =="
R="$TMP/repo"; mkdir -p "$R"; git_ -C "$R" init -q -b main
O=$(cenv python3 "$PLUGIN/scripts/install_gates.py" --root "$R" 2>&1); eq "$?" 0 "the installer renders the templates into a repo"
for k in $KINDS; do
  f="$R/.github/workflows/$k.yml"
  grep -q '@@' "$f" && bad "$k.yml still has a marker" || ok "$k.yml has no marker left"
  grep -qxF "    runs-on: \${{ vars.CI_GATE_RUNNER || vars.CI_RUNNER || 'ubuntu-latest' }}" "$f" && ok "$k.yml: runs-on is the runner variable with its fallback (defaults)" || bad "$k.yml: runs-on is not the default expression"
done
R2="$TMP/repo2"; mkdir -p "$R2"; git_ -C "$R2" init -q -b main
cenv python3 "$PLUGIN/scripts/install_gates.py" --root "$R2" --runner-var MY_RUNNER --runner-default team-runners >/dev/null 2>&1
grep -qxF "    runs-on: \${{ vars.CI_GATE_RUNNER || vars.MY_RUNNER || 'team-runners' }}" "$R2/.github/workflows/pr-title.yml" && ok "flags: runs-on takes the given variable and label" || bad "flags did not reach runs-on"
R3="$TMP/repo3"; mkdir -p "$R3"; git_ -C "$R3" init -q -b main; put_cfg "$R3" '{"ci": {"runner_var": "CFG_RUNNER", "runner_default": "cfg-label"}}'
cenv python3 "$PLUGIN/scripts/install_gates.py" --root "$R3" >/dev/null 2>&1
grep -qxF "    runs-on: \${{ vars.CI_GATE_RUNNER || vars.CFG_RUNNER || 'cfg-label' }}" "$R3/.github/workflows/dead-branches.yml" && ok "config: ci.runner_var and ci.runner_default reach runs-on" || bad "the config did not reach runs-on"

echo "== self-hosted only (ci.runner_default: \"self-hosted only\"): no hosted fallback, an unset variable fails the run =="
# The form is opt-in: the generated runs-on has no label at all, so a repo whose organisation has no hosted runners never queues a job for ever.
SH="self-hosted only"; ALL6="$KINDS pr-evidence"
RS1="$TMP/repo-sho1"; mkdir -p "$RS1"; git_ -C "$RS1" init -q -b main; put_cfg "$RS1" '{"ci": {"runner_var": "TEAM_RUNNER", "runner_default": "self-hosted only"}}'
O=$(cenv python3 "$PLUGIN/scripts/install_gates.py" --root "$RS1" 2>&1); eq "$?" 0 "the form in the config: the installer accepts it"
RS2="$TMP/repo-sho2"; mkdir -p "$RS2"; git_ -C "$RS2" init -q -b main
O5=$(cenv python3 "$PLUGIN/scripts/install_gates.py" --root "$RS2" --runner-default "$SH" 2>&1); eq "$?" 0 "the form on the command line: the installer accepts it"
MSG="TEAM_RUNNER is not set and this repo runs on self-hosted runners only; set the repository variable TEAM_RUNNER to the label of one"
for k in $ALL6; do
  f="$RS1/.github/workflows/$k.yml"
  [ "$(grep -c -F 'runs-on:' "$f")" = "$([ "$k" = pr-evidence ] && echo 2 || echo 1)" ] && ok "$k.yml: its runs-on lines are all there" || bad "$k.yml: unexpected number of runs-on lines"
  [ -z "$(grep -F 'runs-on:' "$f" | grep -v -F "runs-on: \${{ vars.CI_GATE_RUNNER || vars.TEAM_RUNNER || fromJSON('$MSG') }}")" ] && ok "$k.yml: every runs-on is the two variables, then the failing guard (config)" || bad "$k.yml: a runs-on is not the self-hosted-only expression"
  grep -i -E "ubuntu|windows|macos|hosted-label" "$f" >/dev/null && bad "$k.yml names a hosted runner" || ok "$k.yml: no hosted runner is named anywhere"
  grep -q '@@' "$f" && bad "$k.yml still has a marker (self-hosted only)" || ok "$k.yml: no marker left (self-hosted only)"
done
grep -qxF "    runs-on: \${{ vars.CI_GATE_RUNNER || vars.CI_RUNNER || fromJSON('CI_RUNNER is not set and this repo runs on self-hosted runners only; set the repository variable CI_RUNNER to the label of one') }}" "$RS2/.github/workflows/pr-title.yml" && ok "flag: --runner-default \"self-hosted only\" writes the guard with the default variable" || bad "the flag did not write the guard"
# an earlier install keeps its hosted fallback (install-gates never overwrites): switching to the form must say so, once per kept file
RS3="$TMP/repo-sho3"; mkdir -p "$RS3"; git_ -C "$RS3" init -q -b main
cenv python3 "$PLUGIN/scripts/install_gates.py" --root "$RS3" >/dev/null 2>&1
O3=$(cenv python3 "$PLUGIN/scripts/install_gates.py" --root "$RS3" --runner-default "$SH" 2>&1); eq "$?" 0 "…the warnings do not change the exit code"
eq "$(printf '%s\n' "$O3" | grep -c '^WARNING .github/workflows/.*is kept, and its runs-on still has a fallback')" 6 "a repo installed with the hosted default, then asked for self-hosted only: one WARNING per kept workflow (6)"
printf '%s\n' "$O3" | grep -F "WARNING .github/workflows/pr-title.yml" | grep -q "ubuntu-latest" && ok "…the warning names the fallback it found" || bad "…the warning does not name the fallback"
eq "$(printf '%s\n' "$O" | grep -c 'is kept, and its runs-on still has a fallback')" 0 "control: a fresh self-hosted-only install warns about no kept file"
O3=$(cenv python3 "$PLUGIN/scripts/install_gates.py" --root "$RS3" 2>&1)
eq "$(printf '%s\n' "$O3" | grep -c 'still has a fallback')" 0 "control: the hosted default asked again (files kept as they are) prints no such warning"
# what counts as a kept fallback: any runs-on key that is not the guard, whatever its spelling; a kept file that cannot be read is said, not a crash
RS4="$TMP/repo-sho4"; mkdir -p "$RS4"; git_ -C "$RS4" init -q -b main; cenv python3 "$PLUGIN/scripts/install_gates.py" --root "$RS4" --only pr-title >/dev/null 2>&1
GOOD="runs-on: \${{ vars.CI_GATE_RUNNER || vars.CI_RUNNER || fromJSON('CI_RUNNER is not set and this repo runs on self-hosted runners only; set the repository variable CI_RUNNER to the label of one') }}"
kept_case() {  # kept_case <label> <want warnings> <the runs-on text, one or more lines>
  printf 'name: x\njobs:\n  a:\n%s\n' "$3" > "$RS4/.github/workflows/pr-title.yml"
  local o rc; o=$(cenv python3 "$PLUGIN/scripts/install_gates.py" --root "$RS4" --only pr-title --runner-default "$SH" 2>&1); rc=$?
  eq "$(printf '%s\n' "$o" | grep -c '^WARNING .github/workflows/pr-title.yml')" "$2" "kept file, $1: $2 warning(s)"; eq "$rc" 0 "…rc 0"
}
kept_case "the guard on every runs-on line" 0 "    $GOOD"
kept_case "a hosted label" 1 "    runs-on: \${{ vars.CI_GATE_RUNNER || vars.CI_RUNNER || 'ubuntu-latest' }}"
kept_case "a guard in one job and a label in another" 1 "    $GOOD
  b:
    runs-on: ubuntu-latest"
kept_case "a label with a trailing comment that mentions fromJSON(" 1 "    runs-on: ubuntu-latest # fromJSON(x)"
kept_case "a quoted key" 1 "    \"runs-on\": ubuntu-latest"
kept_case "a list item" 1 "  - runs-on: ubuntu-latest"
kept_case "a space before the colon" 1 "    runs-on : ubuntu-latest"
kept_case "a fromJSON that is not the guard" 1 "    runs-on: \${{ vars.A || fromJSON('\"ubuntu-latest\"') }}"
rm -f "$RS4/.github/workflows/pr-title.yml"; ln -s /nonexistent-target "$RS4/.github/workflows/pr-title.yml"
O4=$(cenv python3 "$PLUGIN/scripts/install_gates.py" --root "$RS4" --only pr-title --runner-default "$SH" 2>&1); eq "$?" 0 "kept file that is a dangling link: rc 0, no crash"
has "$O4" "pr-title.yml is kept and could not be read" "…the warning says it could not be read"
rm -f "$RS4/.github/workflows/pr-title.yml"; mkdir "$RS4/.github/workflows/pr-title.yml"
O4=$(cenv python3 "$PLUGIN/scripts/install_gates.py" --root "$RS4" --only pr-title --runner-default "$SH" 2>&1); eq "$?" 0 "kept file that is a directory: rc 0, no crash"
has "$O4" "pr-title.yml is kept and could not be read" "…the warning says it could not be read"
rmdir "$RS4/.github/workflows/pr-title.yml"
# the hosted default and a label are not changed by the existence of the form
for k in $ALL6; do grep -F 'runs-on:' "$R/.github/workflows/$k.yml" | grep -q -F "fromJSON" && bad "$k.yml (hosted default) carries the guard" || ok "$k.yml (hosted default) has no guard: the default form is as before"; done
# evaluate every generated runs-on, as Actions does: neither variable set (or empty) fails; the first one set answers
cat > "$TMP/ron_eval.py" <<'PYEOF'
import sys, yaml
sys.path.insert(0, sys.argv[1])
import gh_expr
bad = []
for path in sys.argv[3:]:
    for job, spec in yaml.safe_load(open(path))["jobs"].items():
        ro = spec["runs-on"]
        for vars_, want in (({}, None), ({"TEAM_RUNNER": ""}, None), ({"TEAM_RUNNER": "", "CI_GATE_RUNNER": ""}, None),
                            ({"TEAM_RUNNER": "ours"}, "ours"), ({"CI_GATE_RUNNER": "gate"}, "gate"), ({"TEAM_RUNNER": "ours", "CI_GATE_RUNNER": "gate"}, "gate")):
            for vis in ("public", "private", "internal"):
                try:
                    got = gh_expr.evaluate(ro, {"vars": vars_, "github": {"repository_visibility": vis}})
                except gh_expr.EvalError as e:
                    got = None
                if got != want:
                    bad.append("%s %s %s %s: wanted %r, got %r" % (path.split("/")[-1], job, vars_, vis, want, got))
print("jobs evaluated; wrong answers: %d" % len(bad))
for b in bad:
    print("FAIL " + b)
sys.exit(1 if bad else 0)
PYEOF
O=$(python3 "$TMP/ron_eval.py" "$HERE/fixtures" x $(for k in $ALL6; do echo "$RS1/.github/workflows/$k.yml"; done) 2>&1); rc=$?
eq "$rc" 0 "self-hosted only: with both variables unset or empty the evaluation fails (no label, public or private), a set variable answers its own label ${O:+($(printf '%s' "$O" | head -3))}"
O=$(python3 "$TMP/ron_eval.py" "$HERE/fixtures" x $(for k in $ALL6; do echo "$R/.github/workflows/$k.yml"; done) 2>&1); rc=$?
[ "$rc" = 1 ] && ok "control: the same evaluation is red on the hosted-default workflows (they answer ubuntu-latest when nothing is set)" || bad "control: the hosted default passed the self-hosted-only evaluation"

echo "== build the scratch repos, then check the real rendered workflows =="
W="$TMP/work"; mkdir -p "$W"
O=$(python3 "$CHECK" build "$W" "$PLUGIN" 2>&1); eq "$?" 0 "the scratch repos and fixtures are built ($O)"
for k in $KINDS; do
  O=$(python3 "$CHECK" check "$W" "$PLUGIN" "$k" "$R/.github/workflows/$k.yml" 2>&1); eq "$?" 0 "$k: structure and run pass on the real rendered template ${O:+($O)}"
done

echo "== concurrency: only a new commit on a PR cancels (tests/fixtures/concurrency_check.py) =="
CONC="$HERE/fixtures/concurrency_check.py"
# the kit's own PR workflows hold the block and the draft rule: no known gap is left; a gap listed here that already passes is red,
# so the list cannot outlive the fix
KNOWN_GAP=""
for g in $KNOWN_GAP; do [ -f "$SRC_ROOT/$g" ] || bad "concurrency: KNOWN_GAP names $g, which does not exist: take it off"; done
for f in "$TPL"/*.yml "$R"/.github/workflows/*.yml "$SRC_ROOT"/.github/workflows/*.yml; do
  rel=${f#"$SRC_ROOT/"}; rel=${rel#"$TMP/"}
  O=$(python3 "$CONC" "$f" 2>&1); rc=$?
  case " $KNOWN_GAP " in
    *" $rel "*) [ "$rc" = 1 ] && has "$O" "no workflow-level concurrency block" "concurrency: $rel is a known gap (the kit's own workflows, signed by the owner)" \
                 || bad "concurrency: $rel passes now: take it off KNOWN_GAP";;
    *) eq "$rc" 0 "concurrency: $rel cancels only on a new commit$( [ "$rc" = 0 ] || printf ' (%s)' "$(printf '%s' "$O" | head -2)")";;
  esac
done
# planted: each must be red; the needle is the reason the checker must give
conc_break() {  # conc_break <label> <needle> <old> <new> [<gate>]   on a copy of the rendered gate (default pr-sensitive: comment and review events)
  python3 - "$R/.github/workflows/${5:-pr-sensitive}.yml" "$TMP/conc.yml" "$3" "$4" <<'PY' || { bad "concurrency break $1: the anchor is gone"; return; }
import sys
src, out, old, new = sys.argv[1:5]
t = open(src, encoding="utf-8").read()
if t.count(old) != 1:
    sys.exit(3)
open(out, "w", encoding="utf-8").write(t.replace(old, new))
PY
  O=$(python3 "$CONC" "$TMP/conc.yml" 2>&1); rc=$?
  [ "$rc" = 1 ] && has "$O" "$2" "concurrency break $1: red ($2)" || bad "concurrency break $1: the checker stays green, the probe is blind"
}
conc_break cancels-on-edited "pull_request/edited: cancels a run in progress" \
  "cancel-in-progress: \${{ github.event.action == 'synchronize' }}" "cancel-in-progress: \${{ github.event.action == 'synchronize' || github.event.action == 'edited' }}"
conc_break comments-share-a-group "issue_comment/created: two runs share the group" "|| github.run_id }}" "|| 'events' }}"
conc_break cancels-always "issue_comment/created: cancels a run in progress" "cancel-in-progress: \${{ github.event.action == 'synchronize' }}" "cancel-in-progress: true"
conc_break commit-not-cancelled "a new commit does not cancel" "cancel-in-progress: \${{ github.event.action == 'synchronize' }}" "cancel-in-progress: false"
conc_break commit-group-per-run "two commits of one PR land in two groups" "&& 'commit' ||" "&& github.run_id ||"
conc_break no-pr-number "two PRs share the group" "github.event.pull_request.number || github.event.issue.number || github.ref" "github.base_ref"
conc_break no-workflow-name "does not name the workflow" "group: \${{ github.workflow }}-" "group: gate-"
conc_break edits-join-commits "pull_request/edited: lands in the commit group" "github.event.action == 'synchronize' && 'commit'" "(github.event.action == 'synchronize' || github.event.action == 'edited') && 'commit'"
conc_break no-block "no workflow-level concurrency block" "concurrency:
  group:" "x-concurrency:
  group:"
conc_break not-binds-tight "pull_request/edited: cancels a run in progress" "cancel-in-progress: \${{ github.event.action == 'synchronize' }}" "cancel-in-progress: \${{ !github.event.action != 'synchronize' }}"
conc_break job-level-block "has a concurrency block of its own" "    runs-on: " "    concurrency:
      group: gate
      cancel-in-progress: true
    runs-on: "
conc_break unreadable "cannot judge the expression" "cancel-in-progress: \${{ github.event.action == 'synchronize' }}" "cancel-in-progress: \${{ fromJSON('x') }}"

echo "== drafts and edits: what each rendered gate runs on (job if, evaluated) =="
ifv() { python3 "$CONC" --eval-if "$1" "$2" 2>&1 | awk '{print $2}' | sort -u | tr '\n' ' ' | sed 's/ $//'; }
# ifmat <workflow file> <label> <scenario=want>...
ifmat() {
  local f=$1 lab=$2 kv; shift 2
  for kv in "$@"; do eq "$(ifv "$f" "${kv%%=*}")" "${kv#*=}" "$lab on ${kv%%=*}: runs=${kv#*=}"; done
}
RW="$R/.github/workflows"
ifmat "$RW/pr-body.yml" pr-body edit-title=false edit-body=true edit-base=true draft-private=false draft-public=false ready=true
ifmat "$RW/pr-title.yml" pr-title edit-title=true edit-body=false edit-base=true draft-private=false ready=true
ifmat "$RW/commit-discipline.yml" commit-discipline edit-title=false edit-title-token=false edit-body=false edit-base=true \
  edit-body-token-before=true edit-body-token-after=true draft-private=false ready=true
ifmat "$RW/pr-sensitive.yml" pr-sensitive edit-title=false edit-body=true edit-base=true draft-private=false draft-public=true \
  comment-draft-private=false comment-draft-public=true comment-ready=true comment-edited-ready=true comment-nodraft-private=false ready=true
R4="$TMP/repo4"; mkdir -p "$R4"; git_ -C "$R4" init -q -b main; put_cfg "$R4" '{"tokens": {"commit_exception": "SKIP'"'"'S \"RULE\":"}}'
cenv python3 "$PLUGIN/scripts/install_gates.py" --root "$R4" >/dev/null 2>&1
python3 - "$R4/.github/workflows/commit-discipline.yml" <<'PY' && ok "commit-discipline: a token with quotes and a backslash renders to valid YAML and a valid expression" || bad "commit-discipline: the rendered token breaks the workflow"
import sys, yaml
sys.path.insert(0, sys.argv[0].rsplit("/", 1)[0])
d = yaml.safe_load(open(sys.argv[1]))
assert "SKIP''S \"RULE\":" in d["jobs"]["commit-discipline"]["if"], d["jobs"]["commit-discipline"]["if"]
PY
R5="$TMP/repo5"; mkdir -p "$R5"; git_ -C "$R5" init -q -b main; put_cfg "$R5" '{"tokens": {"commit_exception": "SKIP ${{ x }}:"}}'
O=$(cenv python3 "$PLUGIN/scripts/install_gates.py" --root "$R5" 2>&1); eq "$?" 65 "a token holding \${{ is refused at install (it cannot sit in an expression)"
[ -e "$R5/.github/workflows/commit-discipline.yml" ] && bad "…and nothing is written" || ok "…and nothing is written"
put_cfg "$R4" '{"tokens": {"commit_exception": "NEW EXEMPTION:"}}'
O=$(cenv python3 "$PLUGIN/scripts/install_gates.py" --root "$R4" 2>&1)
has "$O" "has another job condition than this plugin writes" "a kept commit-discipline workflow with an old token: install warns, naming the fix"
put_cfg "$R4" '{"tokens": {"commit_exception": "NEW"}}'
O=$(cenv python3 "$PLUGIN/scripts/install_gates.py" --root "$R4" 2>&1)
has "$O" "has another job condition than this plugin writes" "…also when the kept token merely contains the new one"
O=$(cenv python3 "$PLUGIN/scripts/install_gates.py" --root "$R5" --only pr-title --dry-run 2>&1); eq "$?" 0 "a token holding \${{ does not stop installing a gate that does not use it"
# if_break <label> <kind> <scenario> <wrong value> <old> <new> — a planted fault in a copy of the rendered gate; the scenario must flip
if_break() {
  python3 - "$RW/$2.yml" "$TMP/ifb.yml" "$5" "$6" <<'PY' || { bad "if break $1: the anchor is gone"; return; }
import sys
src, out, old, new = sys.argv[1:5]
t = open(src, encoding="utf-8").read()
if t.count(old) != 1:
    sys.exit(3)
open(out, "w", encoding="utf-8").write(t.replace(old, new))
PY
  local v; v=$(ifv "$TMP/ifb.yml" "$3")
  [ "$v" = "$4" ] && ok "if break $1: caught ($3 now runs=$v)" || bad "if break $1: $3 gives runs=$v, the probe is blind"
  O=$(python3 "$CONC" "$TMP/ifb.yml" 2>&1)
}
if_break no-draft-check pr-body draft-private true "github.event.pull_request.draft == false && (github.event.action" "(github.event.action"
if_break body-gate-on-title-edit pr-body edit-title true "(github.event.action != 'edited' || github.event.changes.body || github.event.changes.base)" "true"
if_break base-ignored-by-body pr-body edit-base false " || github.event.changes.base)" ")"
if_break title-gate-on-body-edit pr-title edit-body true "(github.event.action != 'edited' || github.event.changes.title || github.event.changes.base)" "true"
if_break token-removal-skipped commit-discipline edit-body-token-before false "contains(github.event.changes.body.from, 'COMMIT EXCEPTION:') || " ""
if_break comment-on-private-draft pr-sensitive comment-draft-private true \
  "(github.event_name == 'issue_comment' && toJSON(github.event.issue.draft) == 'false') || (github.event_name != 'issue_comment' && github.event.pull_request.draft == false)" \
  "github.event.pull_request.draft == false"
if_break base-change-skipped commit-discipline edit-base false "github.event.changes.base || github.event.changes.body" "github.event.changes.body"
if_break comment-nodraft-runs pr-sensitive comment-nodraft-private true "toJSON(github.event.issue.draft) == 'false'" "github.event.issue.draft == false"
if_break public-draft-unscanned pr-sensitive draft-public false "github.event.repository.private == false || " ""
# the draft rule in the checker itself: a job that runs on a draft, and types without ready_for_review, are findings
conc_break draft-runs "runs on a draft" "(github.event_name == 'issue_comment' && toJSON(github.event.issue.draft) == 'false') || (github.event_name != 'issue_comment' && github.event.pull_request.draft == false)" "github.event.pull_request.draft == false"
conc_break no-job-on-commit "no job runs on a new commit of a ready PR" "    if: (github.event_name != 'issue_comment'" "    if: github.event_name == 'issue_comment' && (github.event_name != 'issue_comment'"
# a comment-only job (pr-evidence's rerun) skips a commit; the workflow's other job must still check it
conc_break evidence-job-off-commit "no job runs on a new commit of a ready PR (jobs: evidence, rerun)" \
  "    if: github.event_name == 'pull_request' && github.event.pull_request.draft == false" "    if: github.event_name == 'pull_request' && github.event.action != 'synchronize' && github.event.pull_request.draft == false" pr-evidence
# the exemption is read from the text: only a top-level `github.event_name == '<other event>'` makes a job comment-only
conc_break rerun-not-explicit "job rerun does not run on a new commit of a ready PR" \
  "&& github.event_name == 'issue_comment' &&" "&& github.event_name != 'pull_request' &&" pr-evidence
# a trivial job on the commit does not excuse a gate that skips it
python3 - "$R/.github/workflows/pr-evidence.yml" "$TMP/conc.yml" <<'PY' || bad "concurrency break noop-covers-gate: the anchor is gone"
import sys
src, out = sys.argv[1:3]
t = open(src, encoding="utf-8").read()
old = "    if: github.event_name == 'pull_request' && github.event.pull_request.draft == false"
if t.count(old) != 1 or t.count("\njobs:\n") != 1:
    sys.exit(3)
t = t.replace(old, "    if: github.event_name == 'pull_request' && github.event.action != 'synchronize' && github.event.pull_request.draft == false")
t = t.replace("\njobs:\n", "\njobs:\n  noop:\n    if: github.event_name == 'pull_request' && github.event.pull_request.draft == false\n    runs-on: x\n    steps:\n      - run: true\n")
open(out, "w", encoding="utf-8").write(t)
PY
O=$(python3 "$CONC" "$TMP/conc.yml" 2>&1); rc=$?
[ "$rc" = 1 ] && has "$O" "job evidence does not run on a new commit of a ready PR" "concurrency break noop-covers-gate: red (a noop job on the commit, the gate off it)" \
  || bad "concurrency break noop-covers-gate: the checker stays green, the probe is blind"
# small workflows: a pull_request_target gate and an edit-only job are judged on the commit too; a commit job passes
mini() {  # mini <label> <trigger> <job if> <expect: red|green>
  cat > "$TMP/mini.yml" <<EOT
name: mini
on:
  $2:
    types: [opened, edited, synchronize, ready_for_review]
concurrency:
  group: \${{ github.workflow }}-\${{ github.event.pull_request.number || github.ref }}-\${{ github.event.action == 'synchronize' && 'commit' || github.run_id }}
  cancel-in-progress: \${{ github.event.action == 'synchronize' }}
jobs:
  gate:
    if: $3
    runs-on: x
    steps:
      - run: true
  check:
    if: github.event.pull_request.draft == false
    runs-on: x
    steps:
      - run: true
EOT
  O=$(python3 "$CONC" "$TMP/mini.yml" 2>&1); rc=$?
  if [ "$4" = red ]; then
    [ "$rc" = 1 ] && has "$O" "job gate does not run on a new commit of a ready PR" "concurrency mini $1: red" || bad "concurrency mini $1: the checker stays green ($O)"
  else
    [ "$rc" = 0 ] && ok "concurrency mini $1: green" || bad "concurrency mini $1: red on a job that checks the commit ($O)"
  fi
}
mini target-opened-only pull_request_target "github.event.pull_request.draft == false && github.event.action == 'opened'" red
mini edit-only pull_request "github.event.pull_request.draft == false && github.event.action == 'edited' && github.event.changes.body" red
mini base-ref-gate pull_request "github.event.pull_request.draft == false && github.event.pull_request.base.ref == 'main' && github.event.action != 'synchronize'" red
mini name-in-parens pull_request "github.event.pull_request.draft == false && (github.event_name == 'issue_comment' || github.event.action == 'opened')" red
mini or-after-event pull_request "github.event_name == 'issue_comment' && github.event.issue.draft == false || github.event.pull_request.draft == false && github.event.action == 'opened'" red
mini or-before-event pull_request "github.event.pull_request.draft == false && github.event.action == 'opened' || github.event.issue.draft == false && github.event_name == 'issue_comment'" red
# the exemption parser itself: text it cannot read as one expression is no exemption
O=$(python3 -c '
import sys; sys.path.insert(0, sys.argv[1]); import concurrency_check as c
E = "github.event_name == '"'"'issue_comment'"'"'"
for t, want in ((E + " && x", True), ("${{ " + E + " && x }}", True), (E + " && ${{ x }}", False),
                (E + " && x) || (true", False), (E + " && (x || y", False), (E + " && '"'"'a", False)):
    if c._not_pr_job({"if": t}) != want:
        print("wrong:", t)
' "$(dirname "$CONC")" 2>&1)
[ -z "$O" ] && ok "exemption parser: partial \${{ }}, unbalanced parentheses and quotes are no exemption" || bad "exemption parser: $O"
mini target-on-commit pull_request_target "github.event.pull_request.draft == false" green
conc_break no-ready-type "lack ready_for_review" "types: [opened, edited, synchronize, reopened, ready_for_review]" "types: [opened, edited, synchronize, reopened]"

echo "== planted faults in a copy of the rendered template: the checker must go red =="
break_rows() {   # kind^name^old^new   (\n in a field is a newline)
  cat <<'EOT'
commit-discipline^head-checkout^          ref: ${{ github.event.pull_request.base.ref }}^          ref: ${{ github.event.pull_request.head.sha }}
commit-discipline^tag-pin^actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2^actions/checkout@v4
commit-discipline^shallow-clone^fetch-depth: 0^fetch-depth: 1
commit-discipline^runs-on-drafts^if: "github.event.pull_request.draft == false &&^if: "github.event.pull_request.draft == true &&
commit-discipline^swallowed-exit^--config-ref "origin/$BASE_REF"^--config-ref "origin/$BASE_REF" || true
commit-discipline^no-config-ref^ --config-ref "origin/$BASE_REF"^
commit-discipline^body-not-read^            --body-file "$RUNNER_TEMP/pr-body.md" --config-ref^            --config-ref
commit-discipline^body-from-event^gh pr view "$PR_NUMBER" --json body -q .body > "$RUNNER_TEMP/pr-body.md"^printf '%s' "$GITHUB_EVENT_PATH" > "$RUNNER_TEMP/pr-body.md"
commit-discipline^head-not-fetched^git fetch --no-tags origin "+refs/pull/$PR_NUMBER/head:refs/remotes/origin/pr-head"^true
commit-discipline^interpolated-run^"+refs/pull/$PR_NUMBER/head^"+refs/pull/${{ github.event.pull_request.number }}/head
commit-discipline^xtrace^set -euo pipefail^set -euxo pipefail
commit-discipline^continue-on-error^      - name: count commits^      - continue-on-error: true\n        name: count commits
commit-discipline^edited-dropped^types: [opened, edited, synchronize, reopened, ready_for_review]^types: [opened, synchronize, reopened, ready_for_review]
commit-discipline^ready-dropped^types: [opened, edited, synchronize, reopened, ready_for_review]^types: [opened, edited, synchronize, reopened]
commit-discipline^nogates-branch-gone^if [ ! -f .vibemaestro/gates/commit_discipline.py ]; then^if false; then
commit-discipline^write-permission^  contents: read^  contents: write
commit-discipline^literal-runner^runs-on: ${{ vars.CI_GATE_RUNNER || vars.CI_RUNNER || 'ubuntu-latest' }}^runs-on: ubuntu-latest
commit-discipline^third-party-action^      - name: count commits^      - uses: some-org/some-action@v1\n      - name: count commits
pr-sensitive^cancel-in-progress^cancel-in-progress: ${{ github.event.action == 'synchronize' }}^cancel-in-progress: true
commit-discipline^checkout-other-repo^fetch-depth: 0^fetch-depth: 0\n          repository: someone/else
pr-sensitive^job-if-false^    if: (github.event_name != 'issue_comment'^    if: false && (github.event_name != 'issue_comment'
pr-sensitive^head-checkout^          ref: ${{ github.event.repository.default_branch }}^          ref: ${{ github.event.pull_request.head.sha }}
pr-sensitive^xtrace^set -euo pipefail^set -euxo pipefail
pr-sensitive^swallowed-exit^--repo "$REPO"^--repo "$REPO" || true
pr-sensitive^issue-comment-dropped^  issue_comment:\n    types: [created, edited]\n^
pr-sensitive^review-dropped^  pull_request_review:\n    types: [submitted, edited]\n^
pr-sensitive^edited-dropped^types: [opened, edited, synchronize, reopened, ready_for_review]^types: [opened, synchronize, reopened, ready_for_review]
pr-sensitive^payload-snapshot^--pr "$PR" --repo "$REPO"^--payload "$GITHUB_EVENT_PATH"
pr-sensitive^body-expression^PR: ${{ github.event.pull_request.number || github.event.issue.number }}^PR: ${{ github.event.pull_request.body }}
pr-sensitive^nogates-branch-gone^if [ ! -f .vibemaestro/gates/pr_sensitive.py ]; then^if false; then
pr-sensitive^write-permission^  issues: read^  issues: write
pr-sensitive^repo-not-passed^--pr "$PR" --repo "$REPO"^--pr "$PR"
pr-sensitive^literal-runner^runs-on: ${{ vars.CI_GATE_RUNNER || vars.CI_RUNNER || 'ubuntu-latest' }}^runs-on: ubuntu-latest
pr-title^head-checkout^          ref: ${{ github.event.pull_request.base.ref }}^          ref: ${{ github.event.pull_request.head.sha }}
pr-title^swallowed-exit^--config-ref "origin/$BASE_REF"^--config-ref "origin/$BASE_REF" || true
pr-title^no-config-ref^ --config-ref "origin/$BASE_REF"^
pr-title^edited-dropped^types: [opened, edited, synchronize, reopened, ready_for_review]^types: [opened, synchronize, reopened, ready_for_review]
pr-title^nogates-branch-gone^if [ ! -f .vibemaestro/gates/pr_title.py ]; then^if false; then
pr-title^tag-pin^actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2^actions/checkout@v4
pr-title^repo-not-passed^--pr "$PR_NUMBER" --repo "$REPO"^--pr "$PR_NUMBER"
pr-body^head-checkout^          ref: ${{ github.event.pull_request.base.ref }}^          ref: ${{ github.event.pull_request.head.sha }}
pr-body^swallowed-exit^--config-ref "origin/$BASE_REF"^--config-ref "origin/$BASE_REF" || true
pr-body^no-config-ref^ --config-ref "origin/$BASE_REF"^
pr-body^edited-dropped^types: [opened, edited, synchronize, reopened, ready_for_review]^types: [opened, synchronize, reopened, ready_for_review]
pr-body^ready-dropped^types: [opened, edited, synchronize, reopened, ready_for_review]^types: [opened, edited, synchronize, reopened]
pr-body^nogates-branch-gone^if [ ! -f .vibemaestro/gates/pr_body.py ]; then^if false; then
pr-body^tag-pin^actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2^actions/checkout@v4
pr-body^repo-not-passed^--pr "$PR_NUMBER" --repo "$REPO"^--pr "$PR_NUMBER"
pr-body^write-permission^  pull-requests: read^  pull-requests: write
pr-body^pull-request-target^  pull_request:\n^  pull_request_target:\n
pr-body^payload-snapshot^--pr "$PR_NUMBER" --repo "$REPO"^--body-file "$GITHUB_EVENT_PATH"
pr-body^xtrace^set -euo pipefail^set -euxo pipefail
dead-branches^swallowed-exit^bash .vibemaestro/gates/dead_branches.sh^bash .vibemaestro/gates/dead_branches.sh || true
dead-branches^shallow-clone^fetch-depth: 0^fetch-depth: 1
dead-branches^schedule-dropped^  schedule:\n    - cron: '17 5 * * 1'\n^
dead-branches^nogates-branch-gone^if [ ! -f .vibemaestro/gates/dead_branches.sh ]; then^if false; then
dead-branches^tag-pin^actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2^actions/checkout@v4
EOT
}
N=0
while IFS='^' read -r kind name old new; do
  [ -n "$kind" ] || continue
  N=$((N+1))
  python3 - "$R/.github/workflows/$kind.yml" "$TMP/mut.yml" "$old" "$new" <<'PY'
import sys
src, out, old, new = sys.argv[1:5]
dec = lambda s: s.replace("\\n", "\n")
old, new = dec(old), dec(new)
t = open(src, encoding="utf-8").read()
if t.count(old) < 1:
    sys.exit(3)
open(out, "w", encoding="utf-8").write(t.replace(old, new, 1))
PY
  rc=$?
  if [ "$rc" -eq 3 ]; then bad "planted fault '$kind/$name': the anchor is not in the template any more, update the list"; continue; fi
  O=$(capped python3 "$CHECK" check "$W" "$PLUGIN" "$kind" "$TMP/mut.yml" 2>&1); crc=$?   # capped: memory and time caps (fixtures/capped.sh)
  if cap_red "$crc" "planted fault '$kind/$name'"; then :
  elif [ "$crc" = 0 ]; then bad "planted fault '$kind/$name': the checker stays GREEN, the probe is blind"
  else ok "planted fault '$kind/$name': red ($(printf '%s' "$O" | head -1 | sed 's/^ *FAIL //' | cut -c1-90))"; fi
done < <(break_rows)
[ "$N" -ge 40 ] && ok "instrument: $N faults were planted" || bad "instrument: only $N faults were planted"

echo "== the kit's own workflows: no job can land on a hosted runner of a private repository (tests/fixtures/runs_on_check.py) =="
# The owner rule: every job of a private repo runs on our runners; a missing CI_RUNNER fails the run, it never falls back to a paid hosted one.
# The public repo (no runner of ours) falls back to ubuntu-latest. The templates install-gates writes into consumer repos are another matter (above).
RON="$HERE/fixtures/runs_on_check.py"
O=$(python3 "$RON" "$SRC_ROOT/.github/workflows" 2>&1); rc=$?
eq "$rc" 0 "runs-on: every job of .github/workflows answers a runner of ours, or fails, in a private repository ($(printf '%s' "$O" | grep -c '^FAIL') jobs red)"
has "$O" "jobs=7" "runs-on: the checker saw all 7 jobs (an empty glob cannot pass)"
mkdir -p "$TMP/ron"
ron_break() {  # ron_break <label> <file> <old> <new> <needle>: the checker must go red on a copy with one runs-on changed
  rm -rf "$TMP/ron/wf"; cp -R "$SRC_ROOT/.github/workflows" "$TMP/ron/wf"
  python3 - "$TMP/ron/wf/$2" "$3" "$4" <<'PY' || { bad "runs-on break $1: the anchor is gone, update the row"; return; }
import sys
f, old, new = sys.argv[1:4]
t = open(f, encoding="utf-8").read()
if t.count(old) != 1:
    sys.exit(3)
open(f, "w", encoding="utf-8").write(t.replace(old, new))
PY
  O=$(python3 "$RON" "$TMP/ron/wf" 2>&1); rc=$?
  [ "$rc" = 1 ] && has "$O" "$5" "runs-on break $1: red ($5)" || bad "runs-on break $1: the checker stays green, the probe is blind"
}
GUARD="(github.repository_visibility == 'public' && 'ubuntu-latest' || fromJSON('CI_RUNNER is not set in a private repository'))"
ron_break literal-label test-full.yml "runs-on: \${{ vars.CI_RUNNER || $GUARD }}
    # The suite took" "runs-on: ubuntu-latest
    # The suite took" "a literal label"
ron_break old-fallback test.yml "runs-on: \${{ vars.CI_RUNNER || $GUARD }}" "runs-on: \${{ vars.CI_RUNNER || 'ubuntu-latest' }}" "answers 'ubuntu-latest' (wanted '<the evaluation fails>')"
ron_break old-gate-fallback pr-body.yml "vars.CI_RUNNER || $GUARD }}" "vars.CI_RUNNER || 'ubuntu-latest' }}" "answers 'ubuntu-latest' (wanted '<the evaluation fails>')"
ron_break private-label export-gate.yml "fromJSON('CI_RUNNER is not set in a private repository')" "'our-runner'" "answers 'our-runner' (wanted '<the evaluation fails>')"
ron_break ci-runner-ignored public-tree.yml "vars.CI_GATE_RUNNER || vars.CI_RUNNER || $GUARD" "vars.CI_GATE_RUNNER || $GUARD" "(wanted 'our-runner')"
ron_break event-shortcut test-full.yml "runs-on: \${{ vars.CI_RUNNER || $GUARD }}
    # The suite took" "runs-on: \${{ github.event_name == 'workflow_dispatch' && 'ubuntu-latest' || vars.CI_RUNNER || $GUARD }}
    # The suite took" "not spelled as the kit's expression"
ron_break internal-is-hosted test.yml "runs-on: \${{ vars.CI_RUNNER || (github.repository_visibility == 'public' && 'ubuntu-latest' || fromJSON('CI_RUNNER is not set in a private repository')) }}" "runs-on: \${{ vars.CI_RUNNER || (github.repository_visibility != 'private' && 'ubuntu-latest' || fromJSON('x y')) }}" "unset in a internal repository"
ron_break null-is-not-a-failure pr-body.yml "fromJSON('CI_RUNNER is not set in a private repository')" "fromJSON('null')" "answers None (wanted '<the evaluation fails>')"
# a workflow file named *.yaml is run by Actions too: the checker must read it, and must see its jobs
rm -rf "$TMP/ron/wf"; cp -R "$SRC_ROOT/.github/workflows" "$TMP/ron/wf"; printf 'on: push\njobs:\n  x:\n    runs-on: ubuntu-latest\n    steps: []\n' > "$TMP/ron/wf/zz.yaml"
O=$(python3 "$RON" "$TMP/ron/wf" 2>&1); rc=$?
[ "$rc" = 1 ] && has "$O" "FAIL zz.yaml x" "runs-on break yaml-extension: red (a job of a *.yaml file is judged)" || bad "runs-on break yaml-extension: the checker does not read *.yaml, the probe is blind"
has "$O" "jobs=8" "runs-on break yaml-extension: …and it counted the extra job"
ron_break public-loses-fallback pr-body.yml "(github.repository_visibility == 'public' && 'ubuntu-latest' || fromJSON('CI_RUNNER is not set in a private repository'))" "fromJSON('CI_RUNNER is not set in a private repository')" "(wanted 'ubuntu-latest')"

echo; summary
