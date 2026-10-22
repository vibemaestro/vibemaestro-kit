#!/bin/bash
# =============================================================================
# Tracking issue of an intent (intent_branch.py --issue, retry-issue) and its adapter default, as they are today
# =============================================================================
# Run: bash tests/test-core-issue.sh
#
# Ports the families of the hub issue suite and adds the two the hub suite lacks and
# the plugin does have: the label created before the issue, and the loud message after a refused issue.
# The `gh` is a FAKE first in PATH (one script, a mode variable, a log of its arguments); nothing reaches GitHub.
# The assertions read exit codes, files (the `issue: N` line), refs and the fake's log; stderr is read only for TOKENS the
# core prints to be acted on (a command to run, the line to write by hand), never for prose.
#
# gh modes (GH_MODE): ok (an issue URL ending in a number) · 403 (issue create refused) · nonum (a URL with no number).
# GH_LABEL=exists makes `label create` fail, as on a repository that already has the label.
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

GHB="$TMP/ghbin"; mkdir -p "$GHB"
cat > "$GHB/gh" <<'GH'
#!/bin/sh
printf '%s\n' "$*" >> "${GH_LOG:-/dev/null}"
case "$1 $2" in
  "label create") [ "${GH_LABEL:-}" = exists ] && { echo "label already exists" >&2; exit 1; }; exit 0;;
  "issue create")
    case "${GH_MODE:-ok}" in
      ok)    echo "https://github.com/acme/app-demo/issues/42";;
      403)   echo "HTTP 403: Resource not accessible by integration" >&2; exit 1;;
      nonum) echo "https://github.com/acme/app-demo/issues/";;
    esac;;
esac
exit 0
GH
chmod +x "$GHB/gh"

VNRX='[ăâđêôơưáàảãạấầẩẫậắằẳẵặéèẻẽẹếềểễệíìỉĩịóòỏõọốồổỗộớờởỡợúùủũụứừửữựýỳỷỹỵ]'
# vncount <text> — lines holding a Vietnamese letter (python3: a byte-oriented grep would count the bytes of "—")
vncount() { printf '%s' "$1" | python3 -c 'import re, sys; rx = re.compile(sys.argv[1], re.I); print(sum(1 for l in sys.stdin.buffer.read().decode("utf-8", "replace").split("\n") if rx.search(l)))' "$VNRX"; }
PLX=""
GHL=""   # the gh log of the current case
# gh_core <tree> <GH_MODE> <args...> — the core with the fake gh on PATH. gh_adapter — the adapter, same environment.
gh_core()    { local w=$1 m=$2; shift 2; cenv PATH="$GHB:$PATH" GH_LOG="$GHL" GH_MODE="$m" python3 "$PLX/scripts/intent_branch.py" --cwd "$w" "$@"; }
gh_adapter() { local w=$1 m=$2; shift 2; cenv PATH="$GHB:$PATH" GH_LOG="$GHL" GH_MODE="$m" bash "$PLX/scripts/intent-branch.sh" --cwd "$w" "$@"; }
# no_gh_core — the core with a PATH that has no gh at all.
no_gh_core() { local w=$1; shift; cenv PATH="$(bare_path nogh)" python3 "$PLX/scripts/intent_branch.py" --cwd "$w" "$@"; }
rec() { printf -- '---\ndescription: "example record"\n---\n\nintent text\n' > "$1/kb/intent/$2.md"; }
issue_lines() { grep -c '^issue:' "$1" || true; }
gh_calls() { [ -s "$GHL" ] && wc -l < "$GHL" | tr -d ' ' || echo 0; }

fam_ok() {  # --issue with a working gh
  PLX=$1; local W S out rc ERR L N; W=$(mk_origin); S=2026-02-01-ok; rec "$W" "$S"; GHL=$(fresh)/gh.log; : > "$GHL"
  out=$(gh_core "$W" ok create-intent --slug "$S" --issue 2>"$TMP/err"); rc=$?; ERR=$(cat "$TMP/err")
  eq "$rc" 0 "[I1] --issue with a working gh: rc 0"
  eq "$out" "intent/$S" "[I1] stdout is exactly the branch name (no issue talk mixed in)"
  eq "$(grep -cx 'issue: 42' "$W/kb/intent/$S.md")" 1 "[I1] the record carries exactly one 'issue: 42' line"
  eq "$(issue_lines "$W/kb/intent/$S.md")" 1 "[I1] …and no other issue: line"
  eq "$(head -1 "$W/kb/intent/$S.md")" "---" "[I1] …the frontmatter still opens the file"
  L=$(grep -n '^label create intent --' "$GHL" | head -1 | cut -d: -f1); N=$(grep -n '^issue create' "$GHL" | head -1 | cut -d: -f1)
  nonempty "$L" "[I1] gh was asked to create the label"; nonempty "$N" "[I1] gh was asked to create the issue"
  [ -n "$L" ] && [ -n "$N" ] && [ "$L" -lt "$N" ] && ok "[I1] the label is created BEFORE the issue" || bad "[I1] the label is created before the issue (label line '$L', issue line '$N')"
  eq "$(sed -n "${N},\$p" "$GHL" | grep -c -- ' --label intent$')" 1 "[I1] the issue carries exactly the label intent"
  eq "$(grep -c '^label create intent --' "$GHL")" 1 "[I1] …and the label created is exactly intent"
  has "$(sed -n "${N}p" "$GHL")" "intent: $S" "[I1] the issue title names the slug"
  : > "$GHL"; S=2026-02-01-label-exists; rec "$W" "$S"
  out=$(cenv PATH="$GHB:$PATH" GH_LOG="$GHL" GH_MODE=ok GH_LABEL=exists python3 "$PLX/scripts/intent_branch.py" --cwd "$W" create-intent --slug "$S" --issue 2>/dev/null); rc=$?
  eq "$rc" 0 "[I1] a label that already exists (label create fails): rc 0"
  eq "$(grep -cx 'issue: 42' "$W/kb/intent/$S.md")" 1 "[I1] …and the issue is still recorded"
  # an issue number already in the record is replaced, never doubled
  S=2026-02-01-replace; printf -- '---\nissue: 3\ndescription: "x"\n---\n\nx\n' > "$W/kb/intent/$S.md"
  gh_core "$W" ok create-intent --slug "$S" --issue >/dev/null 2>&1
  eq "$(issue_lines "$W/kb/intent/$S.md")" 1 "[I1] an existing issue: line is replaced, not doubled"
  eq "$(grep -c '^issue: 42$' "$W/kb/intent/$S.md")" 1 "[I1] …by the new number"
}

fam_refused() {  # a refused issue never blocks the branch and never invents a number
  PLX=$1; local W S out rc ERR H0; W=$(mk_origin); S=2026-02-02-refused; rec "$W" "$S"; GHL=$(fresh)/gh.log; : > "$GHL"
  H0=$(sha1sum < "$W/kb/intent/$S.md")
  out=$(gh_core "$W" 403 create-intent --slug "$S" --issue 2>"$TMP/err"); rc=$?; ERR=$(cat "$TMP/err")
  eq "$rc" 0 "[I2] gh answers 403 on the issue: create-intent still exits 0"
  eq "$out" "intent/$S" "[I2] …stdout is the branch name"
  ref_exists "$W" "intent/$S" && ok "[I2] …the branch EXISTS" || bad "[I2] …the branch was not created"
  eq "$(git_ -C "$W" symbolic-ref --short HEAD)" "intent/$S" "[I2] …and it is checked out"
  eq "$(issue_lines "$W/kb/intent/$S.md")" 0 "[I2] …the record has NO issue: line (no number invented)"
  eq "$(sha1sum < "$W/kb/intent/$S.md")" "$H0" "[I2] …and the record is byte-identical"
  nonempty "$ERR" "[I2] …the core says something on stderr (it does not stay silent)"
  has "$ERR" "retry-issue --slug $S" "[I2] …and names the command to retry"
  has "$ERR" "gh issue list --label intent" "[I2] …and the command that checks whether an issue was made after all"
  has "$ERR" "could not create the tracking issue" "[I2] …in English"
  eq "$(vncount "$ERR")" 0 "[I2] …no line of it holds a Vietnamese letter"
  git_ -C "$W" checkout -q main
  S=2026-02-02-nonum; rec "$W" "$S"
  out=$(gh_core "$W" nonum create-intent --slug "$S" --issue 2>/dev/null); rc=$?
  eq "$rc" 0 "[I2] a URL with no number: rc 0"
  eq "$(issue_lines "$W/kb/intent/$S.md")" 0 "[I2] …and no issue: line is written"
  ref_exists "$W" "intent/$S" && ok "[I2] …and the branch exists" || bad "[I2] …the branch is missing"
  git_ -C "$W" checkout -q main
  S=2026-02-02-nogh; rec "$W" "$S"
  out=$(no_gh_core "$W" create-intent --slug "$S" --issue 2>"$TMP/err"); rc=$?; ERR=$(cat "$TMP/err")
  eq "$rc" 0 "[I2] gh is not installed: rc 0"
  ref_exists "$W" "intent/$S" && ok "[I2] …the branch exists" || bad "[I2] …the branch is missing"
  eq "$(issue_lines "$W/kb/intent/$S.md")" 0 "[I2] …no issue: line"
  has "$ERR" "retry-issue --slug $S" "[I2] …the retry command is named"
}

fam_default_off() {  # the core never touches gh unless asked; the adapter asks by default and --no-issue stops it
  PLX=$1; local W S out rc ERR; W=$(mk_origin); GHL=$(fresh)/gh.log; : > "$GHL"
  S=2026-02-03-core; rec "$W" "$S"
  out=$(gh_core "$W" ok create-intent --slug "$S" 2>"$TMP/err"); rc=$?; ERR=$(cat "$TMP/err")
  eq "$rc" 0 "[I3] the core without --issue: rc 0"; eq "$out" "intent/$S" "[I3] …stdout is the branch name"
  eq "$(gh_calls)" 0 "[I3] …gh was NOT called (a direct core call never reaches the network)"
  empty "$ERR" "[I3] …stderr is empty"
  eq "$(issue_lines "$W/kb/intent/$S.md")" 0 "[I3] …no issue: line"
  git_ -C "$W" checkout -q main
  S=2026-02-03-adapter; rec "$W" "$S"
  out=$(gh_adapter "$W" ok create-intent --slug "$S" 2>/dev/null); rc=$?
  eq "$rc" 0 "[I3] the adapter by default: rc 0"; eq "$out" "intent/$S" "[I3] …stdout is the branch name"
  eq "$(grep -cx 'issue: 42' "$W/kb/intent/$S.md")" 1 "[I3] …the adapter injected --issue: the record has issue: 42"
  git_ -C "$W" checkout -q main
  : > "$GHL"; S=2026-02-03-noissue; rec "$W" "$S"
  out=$(gh_adapter "$W" ok create-intent --slug "$S" --no-issue 2>"$TMP/err"); rc=$?; ERR=$(cat "$TMP/err")
  eq "$rc" 0 "[I3] the adapter with --no-issue: rc 0"; eq "$out" "intent/$S" "[I3] …stdout is the branch name"
  eq "$(gh_calls)" 0 "[I3] …gh was NOT called"
  empty "$ERR" "[I3] …stderr is empty (the flag did not reach the core as an unknown argument)"
  eq "$(issue_lines "$W/kb/intent/$S.md")" 0 "[I3] …no issue: line"
  git_ -C "$W" checkout -q main
  gh_adapter "$W" ok worker-branch --intent "$S" --name feat/x --no-checkout --no-issue >/dev/null 2>&1
  eq "$?" 2 "[I3] --no-issue is consumed only for create-intent: on worker-branch the core rejects it (rc 2)"
}

fam_nofrontmatter() {  # a record without frontmatter is left alone and the core says to write the line by hand
  PLX=$1; local W S out rc ERR H0; W=$(mk_origin); S=2026-02-04-plain; GHL=$(fresh)/gh.log; : > "$GHL"
  printf 'no frontmatter anywhere\n' > "$W/kb/intent/$S.md"; H0=$(sha1sum < "$W/kb/intent/$S.md")
  out=$(gh_core "$W" ok create-intent --slug "$S" --issue 2>"$TMP/err"); rc=$?; ERR=$(cat "$TMP/err")
  eq "$rc" 0 "[I4] a record without frontmatter: rc 0 (the branch is not blocked)"
  eq "$(sha1sum < "$W/kb/intent/$S.md")" "$H0" "[I4] …the record is byte-identical"
  eq "$(issue_lines "$W/kb/intent/$S.md")" 0 "[I4] …no issue: line was added"
  has "$ERR" "issue: 42" "[I4] …stderr carries the line to write by hand (issue: 42), not a claim that it was written"
  git_ -C "$W" checkout -q main
  S=2026-02-04-plain-retry; printf 'no frontmatter anywhere\n' > "$W/kb/intent/$S.md"; H0=$(sha1sum < "$W/kb/intent/$S.md")
  out=$(gh_core "$W" ok retry-issue --slug "$S" 2>"$TMP/err"); rc=$?; ERR=$(cat "$TMP/err")
  eq "$rc" 0 "[I4] retry-issue on a record without frontmatter: rc 0"
  eq "$(sha1sum < "$W/kb/intent/$S.md")" "$H0" "[I4] …the record is byte-identical"
  has "$ERR" "issue: 42" "[I4] …stderr carries the line to write by hand"
}

fam_retry() {  # retry-issue: creates, is idempotent, fails with rc 1, needs a record
  PLX=$1; local W S out rc ERR H0 N0; W=$(mk_origin); S=2026-02-05-retry; rec "$W" "$S"; GHL=$(fresh)/gh.log; : > "$GHL"
  out=$(gh_core "$W" ok retry-issue --slug "$S" 2>/dev/null); rc=$?
  eq "$rc" 0 "[I5] retry-issue on a record with no issue: rc 0"
  eq "$(grep -cx 'issue: 42' "$W/kb/intent/$S.md")" 1 "[I5] …the record has issue: 42"
  ref_exists "$W" "intent/$S" && bad "[I5] …a branch was created (retry-issue must only track the record)" || ok "[I5] …no branch was created"
  H0=$(sha1sum < "$W/kb/intent/$S.md"); N0=$(gh_calls)
  out=$(gh_core "$W" ok retry-issue --slug "$S" 2>/dev/null); rc=$?
  eq "$rc" 0 "[I5] a second retry-issue: rc 0 (idempotent)"
  eq "$(gh_calls)" "$N0" "[I5] …gh was not called again"
  eq "$(sha1sum < "$W/kb/intent/$S.md")" "$H0" "[I5] …the record is byte-identical"
  S=2026-02-05-retry-403; rec "$W" "$S"; H0=$(sha1sum < "$W/kb/intent/$S.md")
  out=$(gh_core "$W" 403 retry-issue --slug "$S" 2>"$TMP/err"); rc=$?
  eq "$rc" 1 "[I5] gh refuses: retry-issue exits 1 (not 0, not another code)"
  eq "$(issue_lines "$W/kb/intent/$S.md")" 0 "[I5] …no issue: line (no number invented)"
  eq "$(sha1sum < "$W/kb/intent/$S.md")" "$H0" "[I5] …the record is byte-identical"
  S=2026-02-05-retry-nonum; rec "$W" "$S"
  gh_core "$W" nonum retry-issue --slug "$S" >/dev/null 2>&1; eq "$?" 1 "[I5] a URL with no number: rc 1"
  S=2026-02-05-retry-nogh; rec "$W" "$S"
  no_gh_core "$W" retry-issue --slug "$S" >/dev/null 2>&1; eq "$?" 1 "[I5] gh is not installed: rc 1"
  gh_core "$W" ok retry-issue --slug 2026-02-05-none >/dev/null 2>&1; eq "$?" 3 "[I5] no record for the slug: rc 3"
  gh_core "$W" ok retry-issue >/dev/null 2>&1; eq "$?" 2 "[I5] --slug is required: rc 2 (argparse)"
  gh_core "$(fresh)" ok retry-issue --slug "$S" >/dev/null 2>&1; eq "$?" 2 "[I5] not a git repository: rc 2"
  S=2026-02-05-adapter; rec "$W" "$S"
  gh_adapter "$W" ok retry-issue --slug "$S" >/dev/null 2>&1; eq "$?" 0 "[I5] retry-issue through the adapter: rc 0"
  eq "$(grep -cx 'issue: 42' "$W/kb/intent/$S.md")" 1 "[I5] …the record has issue: 42"
}

FAMILIES="fam_ok fam_refused fam_default_off fam_nofrontmatter fam_retry"

echo "== the real core =="
PL0="$TMP/plugin-real"; mk_plugin_copy "$PL0"
[ -f "$PL0/scripts/intent_branch.py" ] && ok "instrument: the plugin copy has the core and the adapter" || bad "instrument: the core is missing from the copy"
[ -x "$GHB/gh" ] && ok "instrument: the fake gh is executable" || bad "instrument: the fake gh is not executable"
for f in $FAMILIES; do echo "-- $f"; "$f" "$PL0"; done

echo "== planted breaks: each family must go red on a copy with one break =="
BRK() {  # BRK <label> <family> <needle> <file under scripts/> <old> <new>
  local d="$TMP/break-$1"; mk_plugin_copy "$d"
  mutate "$d/scripts/$4" "$5" "$6" && expect_red "$1" "$2" "$d" "$3"
}
BRK issue-failure-vi fam_refused '[I2] …no line of it holds a Vietnamese letter' intent_branch.py '"       branch %s is created; add `issue: N` to %s by hand if needed.\n"' '"       branch %s đã tạo xong; ghi tay `issue: N` vào %s nếu cần.\n"'
BRK issue-by-default fam_default_off '[I3] …gh was NOT called (a direct' intent_branch.py 'if getattr(a, "issue", False):' 'if True:'
BRK label-not-created fam_ok '[I1] gh was asked to create the label' intent_branch.py '[gh, "label", "create", ISSUE_LABEL,' '[gh, "label", "list", ISSUE_LABEL,'
BRK number-invented fam_refused '[I2] …the record has NO issue' intent_branch.py '        return None, (r.stdout + r.stderr).strip()[:400]' '        return 999, None'
BRK frontmatterless-claims-write fam_nofrontmatter '[I4] …stderr carries the line to write by hand (issue: 42), not' intent_branch.py '    else:
        return False
    with open(doc_path' '    else:
        new = text
    with open(doc_path'
BRK label-renamed fam_ok '[I1] …and the label created is exactly intent' intent_branch.py 'ISSUE_LABEL = "intent"' 'ISSUE_LABEL = "intents"'
BRK retry-not-idempotent fam_retry '[I5] …gh was not called again' intent_branch.py '    if FRONTMATTER_ISSUE_RX.search(open(doc, encoding="utf-8").read()):' '    if False:'
BRK retry-failure-exits-0 fam_retry '[I5] gh refuses: retry-issue exits 1' intent_branch.py '        return 1
    report_issue_created' '        return 0
    report_issue_created'
BRK adapter-no-injection fam_default_off '[I3] …the adapter injected --issue' intent-branch.sh '    ARGS+=(--issue)' '    :'
BRK no-issue-not-consumed fam_default_off '[I3] …stderr is empty (the flag did not reach' intent-branch.sh '{ NOISSUE=1; continue; }' '{ NOISSUE=1; }'
BRK no-issue-consumed-everywhere fam_default_off '[I3] --no-issue is consumed only for create-intent' intent-branch.sh '--no-issue) [ "$SUB" = create-intent ] && { NOISSUE=1; continue; } ;;' '--no-issue) { NOISSUE=1; continue; } ;;'
PLC="$TMP/break-none"; mk_plugin_copy "$PLC"
QN=0; okdef=$(declare -f ok); baddef=$(declare -f bad); sp=$PASS; sf=$FAIL
ok() { :; }; bad() { QN=$((QN+1)); }
for f in $FAMILIES; do "$f" "$PLC" >/dev/null 2>&1; done
eval "$okdef"; eval "$baddef"; PASS=$sp; FAIL=$sf
eq "$QN" 0 "control: an unbroken copy passes every family (no failed check)"

echo; summary
