#!/bin/bash
# =============================================================================
# install-gates asks the repo whether the runner variable is set, read-only, and never fails over the answer
# =============================================================================
# Run: bash tests/test-runner-var-check.sh
#
# After the install, `install_gates.py` lists the names of the repo's Actions variables
# and of the organization variables visible to the repo (`gh api -X GET --paginate`, two calls) and prints ONE line:
#   set      `runner variable <VAR>: set (repo|organization)`
#   unset    `WARNING runner variable <VAR> is not set ...` naming the fallback label and the fix
#   unknown  `install-gates: runner variable check skipped (<scope>: <why>)`: gh missing, not logged in, no access, a 403 or 404 on
#            ONE of the two lists, a timeout, an answer that is not a list of variables. A scope that cannot be read is never "unset".
# The exit code is the install's own in every case. The check cannot write or prompt. A fake `gh` answers from environment variables:
#   GH_ANS_REPO / GH_ANS_ORG   names:A,B=v (one page; `|` starts the next page; `A=` is an empty value) · fail:<http code> · garbage · empty
#                              · wrongshape · deep (nesting that overflows a JSON parser) · hang;  GH_PAGE_SEP: what follows a page (default a newline)
# and logs its argv, its working directory, whether stdin was /dev/null and the prompt switch it was given.
#
#   [V] a variable that is set        [U] a variable that is not        [E] gh cannot answer, one scope or both
#   [X] the call: read-only, no stdin, no prompt, in the repo, once per scope, nothing before the install is valid
#   [I] the init door says it once (kb.py init, app and adopt)
# Then each planted break must turn the family it belongs to red; an unbroken copy must stay green.
# Real git on throw-away repositories, the fake gh first in PATH, no network.
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
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
PLX=""

# ── the fake gh ─────────────────────────────────────────────────────────
GHB="$TMP/ghbin"; mkdir -p "$GHB"
cat > "$GHB/gh" <<'GH'
#!/bin/bash
{ printf 'CWD=%s\n' "$PWD"; printf 'ARGV:'; for a in "$@"; do printf ' [%s]' "$a"; done; echo
  printf 'PROMPT=%s\nGHREPO=%s\n' "${GH_PROMPT_DISABLED:-}" "${GH_REPO:-}"
  if [ -e /proc/self/fd/0 ]; then [ "$(readlink /proc/self/fd/0)" = /dev/null ] && echo STDIN=devnull || echo STDIN=OPEN; fi
} >> "${GH_LOG:-/dev/null}"
case "$*" in *organization-variables*) ans=${GH_ANS_ORG:-names:};; *) ans=${GH_ANS_REPO:-names:};; esac
case "$ans" in
  names:*) rest=${ans#names:}; IFS='|' read -ra pages <<<"$rest"; [ "${#pages[@]}" -gt 0 ] || pages=("")
           for pg in "${pages[@]}"; do
             js=""; IFS=',' read -ra ns <<<"$pg"
             for n in "${ns[@]}"; do
               [ -n "$n" ] || continue
               case "$n" in *=*) nm=${n%%=*}; val=${n#*=};; *) nm=$n; val=x;; esac
               js="$js${js:+,}{\"name\":\"$nm\",\"value\":\"$val\"}"
             done
             printf '{"total_count":%d,"variables":[%s]}%s' "${#ns[@]}" "$js" "${GH_PAGE_SEP-$'\n'}"
           done;;
  deep)    printf '{"variables":%s' "$(head -c 20000 /dev/zero | tr '\0' '[')";;
  fail:*)  echo "gh: Resource not accessible (HTTP ${ans#fail:})" >&2; exit 1;;
  garbage) echo "<html>not json</html>";;
  empty)   ;;
  wrongshape) echo '{"variables": [{"id": 1}]}';;
  hang)    exec sleep 6;;
esac
exit 0
GH
chmod +x "$GHB/gh"
export GH_LOG="$TMP/gh.log"

# ── fixtures ─────────────────────────────────────────────────────────────
mk_repo() { local d; d=$(fresh); git_ init -q -b main "$d"; echo seed > "$d/README.md"; git_ -C "$d" add -A; git_ -C "$d" commit -q -m seed; printf '%s' "$d"; }
# ig <repo> <repo answer> <org answer> [install_gates args...] — run the installer with the fake gh; sets OUT (stdout+stderr), RC, and leaves the gh log in $GH_LOG
ig() {
  local d=$1 ar=$2 ao=$3; shift 3; : > "$GH_LOG"
  : > "$TMP/stdin-file"
  OUT=$(cenv PATH="$GHB:$PATH" GH_ANS_REPO="$ar" GH_ANS_ORG="$ao" INSTALL_GATES_GH_TIMEOUT_S="${TIMEOUT:-1}" GH_REPO="${CALLER_GH_REPO:-}" GH_PAGE_SEP="${PAGE_SEP-$'\n'}" \
        python3 "$PLX/scripts/install_gates.py" --root "$d" "$@" 2>&1 < "$TMP/stdin-file"); RC=$?
}
n_of() { printf '%s\n' "$OUT" | grep -c -- "$1" || true; }
# one_report <tag> <what> — exactly one line about the runner variable, whichever kind
one_report() { eq "$(n_of 'runner variable')" 1 "[$1] $2: exactly one line about the runner variable"; eq "$RC" 0 "[$1] $2: rc 0"; }

fam_set() { PLX=$1; local d
  d=$(mk_repo); ig "$d" "names:OTHER,CI_RUNNER" "names:"
  one_report V1 "the variable is in the repo list"
  has "$OUT" "runner variable CI_RUNNER: set (repo)" "[V1b] …and it says where"
  eq "$(n_of WARNING)" 0 "[V1c] …no WARNING"; eq "$(n_of skipped)" 0 "[V1d] …no skip line"
  [ -f "$d/.github/workflows/pr-title.yml" ] && ok "[V1e] …the install itself happened" || bad "[V1e] the workflows were not written"
  d=$(mk_repo); ig "$d" "names:A" "names:B,CI_RUNNER"
  one_report V2 "the variable is only in the organization list"; has "$OUT" "set (organization)" "[V2b] …said as organization"
  eq "$(n_of WARNING)" 0 "[V2c] …no WARNING"
  d=$(mk_repo); ig "$d" "names:ci_runner" "names:"
  has "$OUT" "CI_RUNNER: set" "[V3] a different case of the name counts as set"; eq "$(n_of WARNING)" 0 "[V3b] …no WARNING"
  d=$(mk_repo); ig "$d" "names:A,B|C,CI_RUNNER" "names:"
  has "$OUT" "CI_RUNNER: set" "[V4] the name on the second page counts as set"
  d=$(mk_repo); ig "$d" "fail:403" "names:CI_RUNNER"
  eq "$(n_of 'set (')" 0 "[V5] the repo list unreadable but the organization list holds the name: not said to be set (a repo value would override it)"
  eq "$(n_of WARNING)" 0 "[V5b] …no WARNING"; eq "$(n_of skipped)" 1 "[V5c] …one skip line"
  d=$(mk_repo); ig "$d" "names:MY_RUNNER" "names:" --runner-var MY_RUNNER --runner-default team-runners
  has "$OUT" "runner variable MY_RUNNER: set" "[V6] --runner-var names the variable asked about"
  d=$(mk_repo); ig "$d" "names:A" "names:ci_runner"
  has "$OUT" "CI_RUNNER: set (organization)" "[V8] a different case of the name in the organization list counts as set"
  d=$(mk_repo); ig "$d" "names:A" "names:B|C,CI_RUNNER"
  has "$OUT" "CI_RUNNER: set (organization)" "[V9] the name on the second page of the organization list counts as set"
  d=$(mk_repo); PAGE_SEP="" ig "$d" "names:A|CI_RUNNER" "names:"
  has "$OUT" "CI_RUNNER: set (repo)" "[V10] pages printed back to back with no separator (}{) are all read"
  d=$(mk_repo); mkdir -p "$d/.vibemaestro"; printf '{"schema": 1, "ci": {"runner_var": "FROM_CONFIG", "runner_default": "acme-runner"}}' > "$d/.vibemaestro/sdlc.json"
  ig "$d" "names:FROM_CONFIG" "names:"
  has "$OUT" "runner variable FROM_CONFIG: set" "[V7] ci.runner_var of the repo config names the variable asked about"
}

fam_unset() { PLX=$1; local d
  d=$(mk_repo); ig "$d" "names:OTHER" "names:ALSO_OTHER"
  one_report U1 "the variable is in neither list"
  eq "$(n_of '^WARNING runner variable CI_RUNNER is not set')" 1 "[U1b] …one WARNING that names the variable"
  has "$OUT" "'ubuntu-latest'" "[U1c] …names the fallback label"
  has "$OUT" "gh variable set CI_RUNNER" "[U1d] …says what to set"
  has "$OUT" "minutes are locked" "[U1e] …says why it matters"
  eq "$(n_of skipped)" 0 "[U1f] …it is not a skip"
  [ -f "$d/.github/workflows/pr-title.yml" ] && ok "[U1g] …the install itself happened" || bad "[U1g] the workflows were not written"
  d=$(mk_repo); ig "$d" "names:" "names:"
  eq "$(n_of '^WARNING')" 1 "[U2] two empty lists: a WARNING"; eq "$RC" 0 "[U2b] …rc 0"
  d=$(mk_repo); ig "$d" "names:X" "names:" --runner-default "self-hosted only"
  eq "$(n_of '^WARNING runner variable CI_RUNNER is not set')" 1 "[U12] self-hosted only, variable unset: one WARNING naming the variable"; eq "$RC" 0 "[U12b] …rc 0"
  has "$OUT" "no fallback runner" "[U12c] …says there is no fallback runner"
  has "$OUT" "fails at its start" "[U12d] …says the run fails at its start"
  hasnt "$OUT" "fall back to runs-on" "[U12e] …and does not talk of a fallback label"
  has "$OUT" "no fallback label (a run with neither variable set fails at its start)" "[U12f] …the runs-on summary line says there is no fallback label"
  has "$OUT" "unless CI_GATE_RUNNER is set" "[U12h] …and that the gate variable, when set, still runs the jobs"
  hasnt "$OUT" "'ubuntu-latest'" "[U12g] …and names no hosted label"
  d=$(mk_repo); ig "$d" "names:X" "names:" --runner-var MY_RUNNER --runner-default team-runners
  has "$OUT" "WARNING runner variable MY_RUNNER is not set" "[U3] --runner-var: the warning names that variable"
  has "$OUT" "'team-runners'" "[U3b] …and that fallback label"
  d=$(mk_repo); ig "$d" "names:CI_RUNNER_OLD,XCI_RUNNER" "names:"
  eq "$(n_of '^WARNING')" 1 "[U4] a name that only contains the variable's name does not count"
  d=$(mk_repo); ig "$d" "names:X" "names:XCI_RUNNER,CI_RUNNER_OLD"
  eq "$(n_of '^WARNING')" 1 "[U7] names in the organization list that only contain the variable's name do not count"
  d=$(mk_repo); ig "$d" "names:CI_RUNNER=" "names:"
  eq "$(n_of '^WARNING runner variable CI_RUNNER is set but empty on the repo')" 1 "[U8] the variable is listed with an empty value: a WARNING, the fallback label is what runs"
  eq "$(n_of 'set (')" 0 "[U8b] …and it is not reported as set"; eq "$RC" 0 "[U8c] …rc 0"
  d=$(mk_repo); ig "$d" "names:CI_RUNNER=" "names:CI_RUNNER=acme-runner"
  eq "$(n_of '^WARNING runner variable CI_RUNNER is set but empty on the repo')" 1 "[U9] an empty repo value wins over the organization's value, as in the workflow"
  d=$(mk_repo); ig "$d" "names:X" "names:CI_RUNNER="
  eq "$(n_of '^WARNING runner variable CI_RUNNER is set but empty on the organization')" 1 "[U10] an empty organization value is a WARNING too"
  d=$(mk_repo); ig "$d" "names:CI_RUNNER=   " "names:"
  eq "$(n_of '^WARNING')" 1 "[U11] a value of spaces is empty"
  d=$(mk_repo); ig "$d" "names:X" "names:" --dry-run
  eq "$(n_of '^WARNING')" 1 "[U5] --dry-run runs the check too"; [ ! -e "$d/.github" ] && ok "[U5b] …and writes nothing" || bad "[U5b] --dry-run wrote files"
  d=$(mk_repo); ig "$d" "names:X" "names:"; ig "$d" "names:X" "names:"
  eq "$(n_of '^WARNING')" 1 "[U6] a second run (nothing to do) warns again, once"; eq "$RC" 0 "[U6b] …rc 0"
}

fam_cannot() { PLX=$1; local d code
  for code in 403 404 500; do
    d=$(mk_repo); ig "$d" "fail:$code" "fail:$code"
    one_report E1 "gh refuses everything with $code"; eq "$(n_of '^install-gates: runner variable check skipped')" 1 "[E1b] …one skip line ($code)"
    eq "$(n_of WARNING)" 0 "[E1c] …no WARNING ($code)"
  done
  d=$(mk_repo); ig "$d" "names:X" "fail:403"
  one_report E2 "the repo list holds no name and the organization list is 403"
  eq "$(n_of WARNING)" 0 "[E2b] …no WARNING: an unreadable organization scope is not an unset variable"
  has "$OUT" "organization variables" "[E2c] …the skip line names the scope that could not be read"
  d=$(mk_repo); ig "$d" "names:X" "fail:404"
  eq "$(n_of WARNING)" 0 "[E3] …the same with a 404 on the organization list"; eq "$(n_of skipped)" 1 "[E3b] …one skip line"
  d=$(mk_repo); ig "$d" "fail:404" "names:X"
  eq "$(n_of WARNING)" 0 "[E4] the repo list is 404 and the organization list holds no name: no WARNING"
  has "$OUT" "repo variables" "[E4b] …the skip line names the repo scope"
  for a in garbage empty wrongshape; do
    d=$(mk_repo); ig "$d" "$a" "names:"
    one_report E5 "the repo answer is $a"; eq "$(n_of WARNING)" 0 "[E5b] …no WARNING ($a)"; eq "$(n_of skipped)" 1 "[E5c] …a skip line ($a)"
    eq "$(n_of 'internal error')" 0 "[E5d] …not through the catch-all ($a)"
    d=$(mk_repo); ig "$d" "names:X" "$a"
    eq "$(n_of WARNING)" 0 "[E6] the organization answer is $a: no WARNING"; eq "$(n_of skipped)" 1 "[E6b] …a skip line ($a)"
  done
  d=$(mk_repo); ig "$d" "deep" "names:"
  one_report E9 "gh answers with JSON nested far deeper than a parser can follow"; has "$OUT" "not JSON" "[E9b] …said as not JSON, not as a crash"
  eq "$(n_of WARNING)" 0 "[E9c] …no WARNING"; [ -f "$d/.github/workflows/pr-title.yml" ] && ok "[E9d] …the install itself happened" || bad "[E9d] the workflows were not written"
  # a `gh` that is a file of the repo is never run, whatever PATH holds
  d=$(mk_repo); printf '#!/bin/sh\n: > planted\necho "{\\"variables\\": [{\\"name\\": \\"CI_RUNNER\\", \\"value\\": \\"x\\"}]}"\n' > "$d/gh"; chmod +x "$d/gh"
  OUT=$(cd "$TMP" && cenv PATH=":$(bare_path nogh)" python3 "$PLX/scripts/install_gates.py" --root "$d" 2>&1 < "$TMP/stdin-file"); RC=$?
  [ ! -e "$d/planted" ] && ok "[E10] an empty PATH entry and a gh in the repo root: the repo's file did not run" || bad "[E10] the gh of the repo ran"
  one_report E10b "an empty PATH entry"; eq "$(n_of WARNING)" 0 "[E10c] …no WARNING"
  OUT=$(cd "$d" && cenv PATH=".:$(bare_path nogh)" python3 "$PLX/scripts/install_gates.py" --root "$d" 2>&1 < "$TMP/stdin-file"); RC=$?
  [ ! -e "$d/planted" ] && ok "[E11] '.' in PATH from inside the repo: the repo's file did not run" || bad "[E11] the gh of the repo ran"
  has "$OUT" "file of this repo" "[E11b] …and the skip line says why"; eq "$(n_of WARNING)" 0 "[E11c] …no WARNING"
  d=$(mk_repo); ig "$d" "fail:403" "names:CI_RUNNER="
  eq "$(n_of WARNING)" 0 "[E12] the repo list unreadable and the organization lists the name with an empty value: no WARNING"
  eq "$(n_of skipped)" 1 "[E12b] …one skip line"
  eq "$(grep -c '^ARGV:' "$GH_LOG")" 1 "[E12c] …and the organization list is not asked"
  # a symlink in the repo that leads to an interpreter would run the repo's own files as arguments
  d=$(mk_repo); ln -s "$(command -v sh)" "$d/gh"; printf ': > planted\n' > "$d/api"
  OUT=$(cd "$d" && cenv PATH=".:$(bare_path nogh)" python3 "$PLX/scripts/install_gates.py" --root "$d" 2>&1 < "$TMP/stdin-file"); RC=$?
  [ ! -e "$d/planted" ] && ok "[E13] a gh that is a symlink to sh inside the repo: nothing of the repo ran" || bad "[E13] the repo's file ran through a symlinked gh"
  one_report E13b "a symlinked gh in the repo"; eq "$(n_of WARNING)" 0 "[E13c] …no WARNING"
  d=$(mk_repo); SECONDS=0; TIMEOUT=1 ig "$d" "hang" "names:X"
  [ "$SECONDS" -lt 5 ] && ok "[E7] a gh that hangs is cut after the timeout (${SECONDS}s)" || bad "[E7] a hanging gh held the install for ${SECONDS}s"
  one_report E7b "gh hangs"; eq "$(n_of WARNING)" 0 "[E7c] …no WARNING"
  # gh missing from PATH altogether
  d=$(mk_repo); : > "$GH_LOG"
  OUT=$(cenv PATH="$(bare_path nogh)" python3 "$PLX/scripts/install_gates.py" --root "$d" 2>&1 < "$TMP/stdin-file"); RC=$?
  one_report E8 "gh is not on PATH"; eq "$(n_of '^install-gates: runner variable check skipped')" 1 "[E8b] …one skip line"
  has "$OUT" "gh is not installed" "[E8c] …that says gh is missing"; eq "$(n_of WARNING)" 0 "[E8d] …no WARNING"
  [ -f "$d/.github/workflows/pr-title.yml" ] && ok "[E8e] …the install itself happened" || bad "[E8e] the workflows were not written"
}

fam_call() { PLX=$1; local d
  d=$(mk_repo); ig "$d" "names:X" "names:"
  eq "$(grep -c '^ARGV:' "$GH_LOG")" 2 "[X1] two gh calls: the repo list and the organization list"
  eq "$(grep -c -- '^ARGV: \[api\] \[-X\] \[GET\] \[--paginate\] \[repos/{owner}/{repo}/actions/variables?per_page=100\]$' "$GH_LOG")" 1 "[X2] the repo call is a GET, paginated, read-only"
  eq "$(grep -c -- '^ARGV: \[api\] \[-X\] \[GET\] \[--paginate\] \[repos/{owner}/{repo}/actions/organization-variables?per_page=100\]$' "$GH_LOG")" 1 "[X3] the organization call is a GET, paginated, read-only"
  eq "$(grep -Ec -- '\[(-f|-F|--field|--raw-field|--input|POST|PUT|PATCH|DELETE)\]' "$GH_LOG")" 0 "[X4] no body flag and no write method on any call"
  eq "$(grep -c '^CWD=' "$GH_LOG")" 2 "[X5] each call ran from a directory"
  [ "$(grep '^CWD=' "$GH_LOG" | sort -u | wc -l | tr -d ' ')" = 1 ] && [ "$(grep -m1 '^CWD=' "$GH_LOG")" = "CWD=$(cd "$d" && pwd -P)" ] \
    && ok "[X6] …the repo being installed into (gh finds {owner}/{repo} there)" || bad "[X6] gh ran from $(grep -m1 '^CWD=' "$GH_LOG")"
  eq "$(grep -c '^PROMPT=1$' "$GH_LOG")" 2 "[X7] GH_PROMPT_DISABLED=1 on both calls"
  if [ -e /proc/self/fd/0 ]; then eq "$(grep -c '^STDIN=devnull$' "$GH_LOG")" 2 "[X8] stdin is closed (/dev/null) on both calls, although the caller's stdin is a file"
  else ok "[X8] (no /proc here: the stdin check is skipped)"; fi
  d=$(mk_repo); CALLER_GH_REPO=other/thing ig "$d" "names:X" "names:"
  eq "$(grep -c '^GHREPO=$' "$GH_LOG")" 2 "[X15] GH_REPO of the caller is not passed on: {owner}/{repo} is the repo being installed into"
  d=$(mk_repo); ig "$d" "names:CI_RUNNER" "names:"
  eq "$(grep -c '^ARGV:' "$GH_LOG")" 1 "[X9] the variable found in the repo list: the organization list is not asked"
  d=$(mk_repo); ig "$d" "names:X" "names:" --only no-such-gate
  eq "$RC" 64 "[X10] an unknown gate: rc 64"; eq "$(grep -c '^ARGV:' "$GH_LOG")" 0 "[X10b] …no gh call"
  d=$(mk_repo); ig "$d" "names:X" "names:" --runner-var 'bad var'
  eq "$RC" 64 "[X11] a bad runner variable: rc 64"; eq "$(grep -c '^ARGV:' "$GH_LOG")" 0 "[X11b] …no gh call"
  d=$(mk_repo); mkdir -p "$d/.vibemaestro"; printf '{"schema": 1, "hooks": 1}' > "$d/.vibemaestro/sdlc.json"
  ig "$d" "names:X" "names:"
  eq "$RC" 65 "[X12] an invalid config: rc 65"; eq "$(grep -c '^ARGV:' "$GH_LOG")" 0 "[X12b] …no gh call"
  d=$(mk_repo); ig "$d" "names:X" "names:" --root "$TMP/not-a-repo-$$"
  eq "$RC" 64 "[X13] not a git repo: rc 64"; eq "$(grep -c '^ARGV:' "$GH_LOG")" 0 "[X13b] …no gh call"
  # the same install with and without the check: the files are the same
  d=$(mk_repo); ig "$d" "names:CI_RUNNER" "names:"; d2=$(mk_repo); ig "$d2" "fail:403" "fail:403"
  diff -r "$d/.github" "$d2/.github" >/dev/null 2>&1 && diff -r "$d/.vibemaestro" "$d2/.vibemaestro" >/dev/null 2>&1 \
    && ok "[X14] what is written does not depend on the answer" || bad "[X14] the files differ between a set and an unreadable variable"
}

fam_door() { PLX=$1; local d out
  : > "$GH_LOG"
  d=$(fresh); git_ init -q -b main "$d"; echo seed > "$d/README.md"; git_ -C "$d" add -A; git_ -C "$d" commit -q -m seed
  out=$(cd "$d" && cenv python3 "$PLX/scripts/kb.py" init 2>&1); eq "$?" 0 "[I1] kb.py init: rc 0"
  eq "$(printf '%s\n' "$out" | grep -c 'install-gates.*CI_RUNNER')" 1 "[I2] …one line names the install-gates runner check"
  has "$out" "a fallback runner label" "[I2b] …the note states the fallback-label form"
  has "$out" '"self-hosted only" (no fallback' "[I2c] …and the self-hosted-only form, which has no fallback"
  out=$(cd "$d" && cenv python3 "$PLX/scripts/kb.py" init 2>&1)
  eq "$(printf '%s\n' "$out" | grep -c 'install-gates.*CI_RUNNER')" 1 "[I3] a rerun that creates nothing says it once too"
  out=$(cd "$d" && cenv python3 "$PLX/scripts/kb.py" init --dry-run 2>&1)
  eq "$(printf '%s\n' "$out" | grep -c 'install-gates.*CI_RUNNER')" 1 "[I4] --dry-run says it once"
  d=$(fresh); git_ init -q -b main "$d"; echo seed > "$d/README.md"; git_ -C "$d" add -A; git_ -C "$d" commit -q -m seed
  mkdir -p "$d/.vibemaestro"; printf '{"schema": 1, "ci": {"runner_var": "TEAM_RUNNER"}}' > "$d/.vibemaestro/sdlc.json"
  out=$(cd "$d" && cenv python3 "$PLX/scripts/kb.py" init --adopt 2>&1)
  eq "$(printf '%s\n' "$out" | grep -c 'install-gates.*TEAM_RUNNER')" 1 "[I5] --adopt says it once, naming the variable of the repo's config"
  [ ! -s "$GH_LOG" ] && ok "[I6] the init door calls no gh" || bad "[I6] kb.py init called gh"
}

FAMILIES="fam_set fam_unset fam_cannot fam_call fam_door"
: > "$GH_LOG"
for f in $FAMILIES; do echo "-- $f"; "$f" "$PLUGIN"; done

# ── each planted break must turn its family red ─────────────────────────────────────────────────
BRK() {  # BRK <label> <family> <needle> <file under scripts/> <old> <new>
  local d="$TMP/break-$1"; mk_plugin_copy "$d"
  mutate "$d/scripts/$4" "$5" "$6" && expect_red "$1" "$2" "$d" "$3"
}
echo "-- control: the check removed, and each way of weakening it"
BRK check-removed fam_unset '[U1]' install_gates.py '    print(runner_var_report(root, var, default))' '    pass'
BRK check-removed-set fam_set '[V1b]' install_gates.py '    print(runner_var_report(root, var, default))' '    pass'
BRK check-removed-skip fam_cannot '[E1b]' install_gates.py '    print(runner_var_report(root, var, default))' '    pass'
BRK unreadable-org-is-unset fam_cannot '[E2b]' install_gates.py '            if org is None:
                return "install-gates: runner variable check skipped (organization variables: %s)" % why_org' '            if org is None:
                org = []'
BRK unreadable-repo-is-unset fam_cannot '[E4]' install_gates.py '        if repo is None:
            return "install-gates: runner variable check skipped (repo variables: %s)" % why_repo' '        if repo is None:
            repo = []'
BRK unreadable-repo-lets-org-decide fam_cannot '[E12b]' install_gates.py '        if repo is None:
            return "install-gates: runner variable check skipped (repo variables: %s)" % why_repo' '        if repo is None:
            repo = []'
BRK symlink-guard-realpath-only fam_cannot '[E13]' install_gates.py '        for where in (gh, os.path.realpath(gh)):' '        for where in (os.path.realpath(gh),):'
BRK garbage-is-empty fam_cannot '[E5b]' install_gates.py '            return None, "gh answered with something that is not JSON"' '            break'
BRK wrong-shape-crashes fam_cannot '[E5d]' install_gates.py '        if not isinstance(rows, list) or not all(isinstance(x, dict) and isinstance(x.get("name"), str)
                                                 and isinstance(x.get("value", ""), str) for x in rows):' '        if not isinstance(rows, list):
            rows = []
        if False:'
BRK silence-is-empty fam_cannot '[E5b]' install_gates.py '    if not text.strip():
        return None, "gh answered with nothing"' '    if False:
        pass'
BRK deep-json-uncaught fam_cannot '[E9b]' install_gates.py '        except (ValueError, RecursionError):' '        except ValueError:'
BRK case-sensitive fam_set '[V3]' install_gates.py '        if name.upper() == want:' '        if name == want:'
BRK org-not-asked fam_set '[V2b]' install_gates.py '            org, why_org = _gh_names(root, "repos/{owner}/{repo}/actions/organization-variables")' '            org, why_org = [], None'
BRK second-page-dropped fam_set '[V4]' install_gates.py '        rows_all.extend((x["name"], x.get("value")) for x in rows)' '        rows_all.extend((x["name"], x.get("value")) for x in rows) if not rows_all else None'
BRK substring-match fam_unset '[U4]' install_gates.py '        if name.upper() == want:' '        if want in name.upper():'
BRK empty-is-set fam_unset '[U8]' install_gates.py '            return "x" if value is None else value.strip()' '            return "x"'
BRK blank-is-set fam_unset '[U11]' install_gates.py '            return "x" if value is None else value.strip()' '            return "x" if value is None else value'
BRK empty-repo-falls-to-org fam_unset '[U9]' install_gates.py '        if got is None:
            org, why_org' '        if not got:
            org, why_org'
BRK write-method fam_call '[X2]' install_gates.py '[gh, "api", "-X", "GET", "--paginate", path + "?per_page=100"]' '[gh, "api", "-X", "POST", "--paginate", path + "?per_page=100"]'
BRK body-flag fam_call '[X4]' install_gates.py '[gh, "api", "-X", "GET", "--paginate", path + "?per_page=100"]' '[gh, "api", "-X", "GET", "-f", "x=1", "--paginate", path + "?per_page=100"]'
BRK stdin-open fam_call '[X8]' install_gates.py 'stdin=subprocess.DEVNULL, ' ''
BRK prompt-allowed fam_call '[X7]' install_gates.py 'GH_PROMPT_DISABLED="1", ' ''
BRK run-from-elsewhere fam_call '[X6]' install_gates.py 'cwd=root, env=env' 'cwd=None, env=env'
BRK caller-repo-passed-on fam_call '[X15]' install_gates.py '    env = {k: v for k, v in os.environ.items() if k != "GH_REPO"}' '    env = dict(os.environ)'
BRK gh-found-by-bare-name fam_cannot '[E10]' install_gates.py '    gh = shutil.which("gh")
    if not gh:
        return None, "gh is not installed"
    gh = os.path.abspath(gh)' '    gh = "gh"'
BRK repo-file-allowed fam_cannot '[E11]' install_gates.py '            if inside:' '            if False:'
BRK always-asks-org fam_call '[X9]' install_gates.py '        if got is None:
            org, why_org' '        if True:
            org, why_org'
BRK no-timeout fam_cannot '[E7]' install_gates.py 'stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=_timeout())' 'stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)'
BRK check-before-validation fam_call '[X12b]' install_gates.py '    cfg, probs, _present = sdlc_config.load(root)' '    print(runner_var_report(root, "CI_RUNNER", "x"))
    cfg, probs, _present = sdlc_config.load(root)'
BRK door-silent fam_door '[I2]' init_setup.py 'out(RUNNER_NOTE' 'out(""); (RUNNER_NOTE'
BRK door-form-missing fam_door '[I2c]' init_setup.py '(no fallback: every gate run ' '(every gate run '
BRK self-hosted-warning-as-label fam_unset '[U12c]' install_gates.py '        if self_hosted_only(default):
            return ("WARNING' '        if False:
            return ("WARNING'
BRK door-twice fam_door '[I3]' init_setup.py 'out(RUNNER_NOTE' 'out(RUNNER_NOTE % "CI_RUNNER" + "\n"); out(RUNNER_NOTE'

PLC="$TMP/break-none"; mk_plugin_copy "$PLC"
QN=0; okdef=$(declare -f ok); baddef=$(declare -f bad); sp=$PASS; sf=$FAIL
ok() { :; }; bad() { QN=$((QN+1)); }
for f in $FAMILIES; do "$f" "$PLC" >/dev/null 2>&1; done
eval "$okdef"; eval "$baddef"; PASS=$sp; FAIL=$sf
eq "$QN" 0 "control: an unbroken copy passes every family (no failed check)"

echo; summary
