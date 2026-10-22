#!/bin/bash
# =============================================================================
# The guarded merge's backends: registry `ghcr`, CI `github-actions`, `external:<path>` adapters
# =============================================================================
# Run: bash tests/test-backends.sh
#
# Offline: a fake `gh` (tests/fixtures/merge_gh.py) serves the GitHub API from a JSON fixture and logs every call; the backends are
# driven one function at a time by tests/fixtures/backends_drive.py on a copy of the plugin. The real endpoints are *chưa kiểm*.
#   [G] ghcr: tags across pages, tag_exists true and false, visibility private, public and anything else `unknown`, an org and a
#       user owner, a package name with a slash, a server error is "could not conclude"
#   [A] github-actions: check runs across pages with their workflow names, commit statuses, failed steps of a job, a job that
#       has not finished, a page count that does not add up
#   [E] external adapters: loaded by path, a missing function and a missing file are rc 65, the digest follows the text
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
printf '#!/bin/sh\nexec python3 -B "%s" "$@"\n' "$HERE/fixtures/merge_gh.py" > "$GHB/gh"; chmod +x "$GHB/gh"
PATH="$GHB:$PATH"; export PATH
H=0123456789abcdef0123456789abcdef01234567

# fx <json> — a fresh fixture file (printed); the log beside it starts empty
fx() { local d; d=$(fresh); printf '%s' "$1" > "$d/fx.json"; : > "$d/gh.log"; printf '%s' "$d"; }
# drive <plugin> <fixture dir> <kind> <spec> <fn> [args...] — stdout of the driver; DRC its rc
drive() {
  local pl=$1 d=$2; shift 2
  OUT=$(cd "$d" && cenv FAKE_GH_FX="$d/fx.json" FAKE_GH_LOG="$d/gh.log" python3 -B "$HERE/fixtures/backends_drive.py" "$pl/gates" "$@" --ext-root "$d" 2>"$d/err"); DRC=$?
}

GHCR_ORG='{"repo": "acme/app", "api": {
  "orgs/acme/packages/container/app-image": {"name": "app-image", "visibility": "private"},
  "orgs/acme/packages/container/app-image/versions?per_page=100": [
    {"id": 1, "metadata": {"container": {"tags": ["v1-r1"]}}},
    {"id": 2, "metadata": {"container": {"tags": []}}},
    {"id": 3, "metadata": {"container": {"tags": ["v1-r2", "latest"]}}}]}}'
GHCR_USER='{"repo": "acme/app", "api": {
  "users/someone/packages/container/tool": {"name": "tool", "visibility": "public"},
  "users/someone/packages/container/tool/versions?per_page=100": [{"id": 9, "metadata": {"container": {"tags": ["t1"]}}}]}}'
GHCR_SLASH='{"repo": "acme/app", "api": {
  "orgs/acme/packages/container/team%2Fapp": {"visibility": "internal"},
  "orgs/acme/packages/container/team%2Fapp/versions?per_page=100": [{"id": 4, "metadata": {"container": {"tags": ["x"]}}}]}}'
GHCR_FAIL='{"repo": "acme/app", "api": {}, "fail": {"orgs/acme/packages/container/app-image": "boom"}}'

fam_ghcr() {
  PL=$1; local d
  d=$(fx "$GHCR_ORG")
  drive "$PL" "$d" registry ghcr list_tags acme/app-image
  eq "$DRC:$OUT" '0:["latest", "v1-r1", "v1-r2"]' "[G] list_tags: every tag, across pages, sorted"
  drive "$PL" "$d" registry ghcr tag_exists acme/app-image v1-r2
  eq "$DRC:$OUT" "0:true" "[G] tag_exists: a tag on the last page is found"
  drive "$PL" "$d" registry ghcr tag_exists acme/app-image v1-r3
  eq "$DRC:$OUT" "0:false" "[G] tag_exists: a tag that is not there is false"
  drive "$PL" "$d" registry ghcr visibility acme/app-image
  eq "$DRC:$OUT" '0:"private"' "[G] visibility: private"
  grep -q '"--paginate"' "$d/gh.log" && ok "[G] the versions are read with --paginate" || bad "[G] the versions are read with --paginate"
  d=$(fx "$GHCR_USER")
  drive "$PL" "$d" registry ghcr tag_exists someone/tool t1
  eq "$DRC:$OUT" "0:true" "[G] a user-owned package: found after the org lookup is a 404"
  drive "$PL" "$d" registry ghcr visibility someone/tool
  eq "$DRC:$OUT" '0:"public"' "[G] visibility: public"
  d=$(fx "$GHCR_SLASH")
  drive "$PL" "$d" registry ghcr tag_exists acme/team/app x
  eq "$DRC:$OUT" "0:true" "[G] a package name with a slash is encoded as %2F"
  drive "$PL" "$d" registry ghcr visibility acme/team/app
  eq "$DRC:$OUT" '0:"unknown"' "[G] visibility other than private or public (internal) is unknown"
  d=$(fx '{"repo": "acme/app", "api": {}}')
  drive "$PL" "$d" registry ghcr tag_exists acme/none v1
  eq "$DRC:$OUT" "0:false" "[G] no package under an org or a user: the tag does not exist"
  drive "$PL" "$d" registry ghcr visibility acme/none
  eq "$DRC:$OUT" '0:"unknown"' "[G] no package: visibility unknown"
  d=$(fx "$GHCR_FAIL")
  drive "$PL" "$d" registry ghcr tag_exists acme/app-image v1
  eq "$DRC" 2 "[G] a server error: rc 2 (could not conclude), not a missing tag"
}

ACTIONS='{"repo": "acme/app", "api": {
  "repos/acme/app/actions/runs?head_sha='$H'&per_page=100": {"__pages__": [
    {"total_count": 2, "workflow_runs": [{"id": 11, "name": "test", "workflow_id": 9001, "check_suite_id": 101}]},
    {"total_count": 2, "workflow_runs": [{"id": 12, "name": "gates", "workflow_id": 9002, "check_suite_id": 102}]}]},
  "repos/acme/app/commits/'$H'/check-runs?filter=all&per_page=100": {"__pages__": [
    {"total_count": 3, "check_runs": [{"id": 201, "name": "unit", "status": "completed", "conclusion": "success",
      "started_at": "2026-10-16T10:00:00Z", "check_suite": {"id": 101}, "app": {"slug": "github-actions"}}]},
    {"total_count": 3, "check_runs": [{"id": 202, "name": "unit", "status": "completed", "conclusion": "failure",
      "started_at": "2026-10-16T11:00:00Z", "check_suite": {"id": 101}, "app": {"slug": "github-actions"}},
      {"id": 203, "name": "image tag", "status": "in_progress", "conclusion": null,
      "started_at": "2026-10-16T11:05:00Z", "check_suite": {"id": 102}, "app": {"slug": "github-actions"}}]}]},
  "repos/acme/app/commits/'$H'/statuses?per_page=100": [
    {"id": 301, "context": "ci/legacy", "state": "error", "created_at": "2026-10-16T09:00:00Z"},
    {"id": 302, "context": "ci/other", "state": "pending", "created_at": "2026-10-16T09:01:00Z"}],
  "repos/acme/app/actions/jobs/202": {"id": 202, "status": "completed", "conclusion": "failure", "steps": [
    {"name": "Set up job", "conclusion": "success"}, {"name": "Full suite before ready", "conclusion": "failure"},
    {"name": "Check image tag (r16)", "conclusion": "failure"}, {"name": "Complete job", "conclusion": "skipped"}]},
  "repos/acme/app/actions/jobs/203": {"id": 203, "status": "in_progress", "conclusion": null, "steps": []}}}'
ACTIONS_SHORT='{"repo": "acme/app", "api": {
  "repos/acme/app/actions/runs?head_sha='$H'&per_page=100": {"total_count": 0, "workflow_runs": []},
  "repos/acme/app/commits/'$H'/check-runs?filter=all&per_page=100": {"__pages__": [{"total_count": 2, "check_runs": [
    {"id": 1, "name": "a", "status": "completed", "conclusion": "success", "started_at": "2026-10-16T10:00:00Z", "check_suite": {"id": 1}}]}]},
  "repos/acme/app/commits/'$H'/statuses?per_page=100": []}}'

fam_actions() {
  PL=$1; local d n
  d=$(fx "$ACTIONS")
  drive "$PL" "$d" ci github-actions runs acme/app "$H"
  eq "$DRC" 0 "[A] runs: rc 0"
  n=$(printf '%s' "$OUT" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
  eq "$n" 5 "[A] runs: three check runs across pages and two statuses"
  has "$OUT" '"workflow": "gates", "workflow_id": 9002' "[A] runs: a check run on page 2 carries its workflow name and id from page 2 of the workflow runs"
  has "$OUT" '"conclusion": "failure", "id": 202' "[A] runs: the newer red run of unit is listed"
  has "$OUT" '"conclusion": "success", "id": 201' "[A] runs: …and the older green one (the guard picks the latest)"
  has "$OUT" '"name": "ci/legacy", "started_at": "2026-10-16T09:00:00Z", "status": "completed"' "[A] runs: a status context is listed"
  has "$OUT" '"conclusion": "failure", "id": 301' "[A] runs: a status in error reads as failure"
  has "$OUT" '"conclusion": null, "id": 302' "[A] runs: a pending status has no conclusion"
  drive "$PL" "$d" ci github-actions failed_steps acme/app '{"id": 202, "kind": "check", "app": "github-actions"}'
  eq "$DRC:$OUT" '0:["Full suite before ready", "Check image tag (r16)"]' "[A] failed_steps: every step that is not success, skipped or neutral"
  drive "$PL" "$d" ci github-actions failed_steps acme/app '{"id": 203, "kind": "check", "app": "github-actions"}'
  eq "$DRC:$OUT" "0:null" "[A] failed_steps: a job that has not finished has none to judge (null)"
  drive "$PL" "$d" ci github-actions failed_steps acme/app '{"id": 301, "kind": "status", "app": "status"}'
  eq "$DRC:$OUT" "0:null" "[A] failed_steps: a status context has no steps (null)"
  d=$(fx "$ACTIONS_SHORT")
  drive "$PL" "$d" ci github-actions runs acme/app "$H"
  eq "$DRC" 2 "[A] check runs read fewer than total_count: rc 2 (could not conclude)"
}

ADAPTER='import json
CALLS = []
def runs(repo, sha):
    return [{"name": "external-ci", "status": "completed", "conclusion": "success", "started_at": "2026-10-16T10:00:00Z"}]
'
REG_ADAPTER='def list_tags(image):
    return ["a", "b"]
def tag_exists(image, tag):
    return tag in list_tags(image)
def visibility(image):
    return "private"
'
fam_external() {
  PL=$1; local d d2
  d=$(fresh); mkdir -p "$d/tools"; printf '%s' "$ADAPTER" > "$d/tools/ci.py"; printf '%s' "$REG_ADAPTER" > "$d/tools/reg.py"
  printf '{"repo": "acme/app", "api": {}}' > "$d/fx.json"; : > "$d/gh.log"
  drive "$PL" "$d" ci external:tools/ci.py runs acme/app "$H"
  eq "$DRC" 0 "[E] an external CI adapter loaded by path: rc 0"
  has "$OUT" '"name": "external-ci"' "[E] …its runs are returned"
  empty "$(cat "$d/gh.log")" "[E] …and gh is never called"
  drive "$PL" "$d" registry external:tools/reg.py tag_exists acme/app b
  eq "$DRC:$OUT" "0:true" "[E] an external registry adapter: tag_exists"
  drive "$PL" "$d" ci external:tools/ci.py digest
  d1=$OUT; printf '\n# one more line\n' >> "$d/tools/ci.py"
  drive "$PL" "$d" ci external:tools/ci.py digest
  ne "$OUT" "$d1" "[E] the digest follows the adapter's text"
  drive "$PL" "$d" registry external:tools/ci.py tag_exists acme/app b
  eq "$DRC" 65 "[E] an adapter missing a function of its kind: rc 65"
  has "$(cat "$d/err")" "list_tags" "[E] …the message names the missing function"
  drive "$PL" "$d" ci external:tools/none.py runs acme/app "$H"
  eq "$DRC" 65 "[E] an adapter file that is not there: rc 65"
  d2=$(fresh); mkdir -p "$d2/tools"; printf 'raise RuntimeError("x")\n' > "$d2/tools/ci.py"; printf '{"repo": "acme/app", "api": {}}' > "$d2/fx.json"; : > "$d2/gh.log"
  drive "$PL" "$d2" ci external:tools/ci.py runs acme/app "$H"
  eq "$DRC" 65 "[E] an adapter that fails on import: rc 65"
  printf 'import sys\nsys.exit(0)\n' > "$d2/tools/ci.py"
  drive "$PL" "$d2" ci external:tools/ci.py runs acme/app "$H"
  eq "$DRC" 65 "[E] an adapter that calls sys.exit(0) on import: rc 65, not 0"
  drive "$PL" "$d" ci jenkins runs acme/app "$H"
  eq "$DRC" 65 "[E] an unknown built-in backend: rc 65"
}

FAMILIES="fam_ghcr fam_actions fam_external"
PL0="$TMP/plugin-real"; mk_plugin_copy "$PL0"
for f in $FAMILIES; do echo "-- $f"; "$f" "$PL0"; done

echo "== planted breaks: each family must go red on a plugin with one break =="
BRK() {  # BRK <label> <family> <needle> <file under gates/> <old> <new>
  local d="$TMP/break-$1"; mk_plugin_copy "$d"
  mutate "$d/gates/$4" "$5" "$6" && expect_red "$1" "$2" "$d" "$3"
}
BRK pagination-dropped fam_ghcr '[G] tag_exists: a tag on the last page is found' backends/__init__.py '    args = ["api", path, "--paginate"]' '    args = ["api", path]'
BRK user-owner-dropped fam_ghcr '[G] a user-owned package' backends/ghcr.py 'OWNER_KINDS = ("orgs", "users")' 'OWNER_KINDS = ("orgs",)'
BRK slash-unencoded fam_ghcr '[G] a package name with a slash' backends/ghcr.py 'urllib.parse.quote(name, safe="")' 'name'
BRK internal-is-private fam_ghcr '[G] visibility other than private or public' backends/ghcr.py 'return v if v in ("private", "public") else "unknown"' 'return "private" if v == "internal" else v'
BRK server-error-is-absent fam_ghcr '[G] a server error' backends/__init__.py '    if "HTTP 404" in err:' '    if True:'
BRK workflow-names-dropped fam_actions '[A] runs: a check run on page 2 carries its workflow name' backends/github_actions.py '        suites[r["check_suite_id"]] = (r.get("name") or "", r.get("workflow_id"))' '        pass'
BRK adapter-exit-escapes fam_external '[E] an adapter that calls sys.exit(0) on import' backends/__init__.py '            except (Exception, SystemExit) as e:                  # SystemExit too: an adapter cannot end the guard with its own code' '            except Exception as e:'
BRK statuses-dropped fam_actions '[A] runs: three check runs across pages and two statuses' backends/github_actions.py '    for s in api_list("repos/%s/commits/%s/statuses?per_page=100" % (repo, sha)):' '    for s in []:'
BRK failed-steps-only-failure fam_actions '[A] failed_steps: every step that is not success' backends/github_actions.py 'if s.get("conclusion") not in OK_STEPS]' 'if s.get("conclusion") == "failure" and "(" not in s["name"]]'
BRK total-count-unchecked fam_actions '[A] check runs read fewer than total_count' backends/github_actions.py '    if len(out) != total:' '    if False:'
BRK missing-function-unchecked fam_external '[E] an adapter missing a function of its kind: rc 65' backends/__init__.py '    missing = [f for f in FUNCS[kind] if not callable(getattr(mod, f, None))]' '    missing = []'
PLC="$TMP/break-none"; mk_plugin_copy "$PLC"
QN=0; okdef=$(declare -f ok); baddef=$(declare -f bad); sp=$PASS; sf=$FAIL
ok() { :; }; bad() { QN=$((QN+1)); }
for f in $FAMILIES; do "$f" "$PLC" >/dev/null 2>&1; done
eval "$okdef"; eval "$baddef"; PASS=$sp; FAIL=$sf
eq "$QN" 0 "control: an unbroken copy passes every family (no failed check)"

echo; summary
