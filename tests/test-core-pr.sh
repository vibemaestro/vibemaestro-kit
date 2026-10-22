#!/bin/bash
# =============================================================================
# Core that opens a PR (open_pr.py), the families that describe TODAY's behaviour
# =============================================================================
# Run: bash tests/test-core-pr.sh
#
# Ports the families of the hub PR-core suite that the plugin core still has: the three
# refusals (rc 3 evidence, rc 4 ledger gate, rc 5 main tree), usage (rc 64), unreadable files (rc 66), the shape of the body,
# the payload, and the one transport, `gh`. The transport that is not `gh` (token file, API, the rc 65 "not declared" family)
# no longer exists in the core; family [P9] asserts that the environment cannot bring it back. The config knobs are asserted
# by tests/test-config.sh.
#
# Every case runs the REAL core on a real repository with a real linked worktree. `--dry-run` for everything that does not
# need the transport; the transport cases use a fake `gh` first in PATH (logging its arguments and the body it receives).
# Network: none; the shims of netguard.sh make a network call visible. Prose of messages is never asserted.
#
# The current-state gate is exercised through a SYNTHETIC repo script `scripts/check-current-state.py` exposing
# decide(paths, body), which is the contract the core calls today. The suite proves the core calls it with the changed paths
# and the final body, honours its answer (rc 4) and treats a repo without the script as "gate not applicable".
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
GHB="$TMP/ghbin"; mk_gh "$GHB"

PLX=""; PW=""; PT=""; F=""   # plugin copy under test; main tree, linked worktree and file directory of the current family

fam_tree() {  # rc 5: not a linked worktree
  PLX=$1; local out rc WTGD TOP; mk_pr_repo
  out=$(prx "$PW" --dry-run --title "feat: x" --summary-file "$F/sum.md" --evidence-file "$F/ev.txt" --head feat/x 2>&1); rc=$?
  eq "$rc" 5 "[P1] from the main tree: rc 5"
  TOP=$(git_ -C "$PW" rev-parse --show-toplevel)
  eq "$(printf '%s\n' "$out" | grep -F 'git worktree add' | grep -cF -- "$TOP/.claude/worktrees/")" 1 "[P1] …the message names a worktree path inside this clone"
  prd >/dev/null 2>&1; eq "$?" 0 "[P1] from the linked worktree: rc 0"
  prx "$(fresh)" --dry-run --title t --summary-file "$F/sum.md" --evidence-file "$F/ev.txt" --head feat/x >/dev/null 2>&1; eq "$?" 5 "[P1] outside any repository: rc 5"
  local SUB; SUB=$(mk_submodule "$PW" "$(fresh)")
  prx "$SUB" --dry-run --title t --summary-file "$F/sum.md" --evidence-file "$F/ev.txt" --head feat/x >/dev/null 2>&1; eq "$?" 5 "[P1] from a submodule: rc 5"
  # GIT_DIR must not decide the answer: git rev-parse obeys it, the core must ask what the DIRECTORY is
  WTGD=$(git_ -C "$PT" rev-parse --absolute-git-dir)
  ( cd "$PW" && cenv GIT_DIR="$WTGD" python3 "$PLX/scripts/open_pr.py" --dry-run --title t --summary-file "$F/sum.md" --evidence-file "$F/ev.txt" --head feat/x ) >/dev/null 2>&1
  eq "$?" 5 "[P1] main tree with GIT_DIR aimed at a worktree: still rc 5 (not let through)"
  ( cd "$PT" && cenv GIT_DIR="$PW/.git" python3 "$PLX/scripts/open_pr.py" --dry-run --title t --summary-file "$F/sum.md" --evidence-file "$F/ev.txt" --head feat/x ) >/dev/null 2>&1
  eq "$?" 0 "[P1] worktree with GIT_DIR aimed at the main tree: still rc 0 (not refused by mistake)"
}

fam_evidence() {  # rc 3, rc 2, rc 66 and the not-run exemption
  PLX=$1; local out rc J; mk_pr_repo
  prd --evidence-file "$F/ev-empty.txt" >/dev/null 2>&1; eq "$?" 3 "[P2] empty evidence file: rc 3"
  printf '  \n\n' > "$F/ev-blank.txt"; prd --evidence-file "$F/ev-blank.txt" >/dev/null 2>&1; eq "$?" 3 "[P2] evidence of blank lines only: rc 3"
  prd --evidence-file "$F/none.txt" >/dev/null 2>&1; eq "$?" 3 "[P2] evidence file that does not exist: rc 3"
  out=$(prd --evidence-file "$F/ev-empty.txt" 2>&1 >/dev/null); has "$out" "$TOK_NOT_RUN" "[P2] …the refusal names the exemption token"
  printf '%s the sandbox has no database\n' "$TOK_NOT_RUN" > "$F/ev-notrun.txt"
  J=$(prd --evidence-file "$F/ev-notrun.txt" 2>/dev/null); rc=$?
  eq "$rc" 0 "[P2] evidence that starts with the not-run token: rc 0"
  hasline "$(pj "$J" body)" "$TOK_NOT_RUN the sandbox has no database" "[P2] …and the line is in the body"
  has "$(pj "$J" body)" "⚠" "[P2] …under a warning marker that tells the reviewer the run was declared impossible"
  printf 'ran the tests\n%s but only part of them\n' "$TOK_NOT_RUN" > "$F/ev-mid.txt"
  J=$(prd --evidence-file "$F/ev-mid.txt" 2>/dev/null)
  hasnt "$(pj "$J" body)" "⚠" "[P2] the token in the middle of the evidence is not an exemption: no warning marker"
  printf '' > "$F/sum-empty.md"; prd --summary-file "$F/sum-empty.md" >/dev/null 2>&1; eq "$?" 2 "[P2] empty summary: rc 2"
  printf '## %s\n' "$TOK_SUMMARY" > "$F/sum-head.md"; prd --summary-file "$F/sum-head.md" >/dev/null 2>&1; eq "$?" 2 "[P2] a summary that is only its heading: rc 2"
  printf '###%s  ' "$TOK_SUMMARY" > "$F/sum-head2.md"; prd --summary-file "$F/sum-head2.md" >/dev/null 2>&1; eq "$?" 2 "[P2] …also without a newline and with another heading level: rc 2"
  prd --summary-file "$F/none.md" >/dev/null 2>&1; eq "$?" 66 "[P2] summary file that does not exist: rc 66"
  prd --summary-file "$F/sum-empty.md" --evidence-file "$F/ev-empty.txt" >/dev/null 2>&1; eq "$?" 2 "[P2] summary is judged before evidence (both empty: rc 2)"
  prd --crit-file "$F/none.txt" >/dev/null 2>&1; eq "$?" 0 "[P2] an unreadable criteria file is ignored: rc 0"
  prd --payload-out "$F/no-such-dir/p.json" >/dev/null 2>&1; eq "$?" 66 "[P2] --payload-out that cannot be written: rc 66"
}

fam_args() {  # rc 64 and the head
  PLX=$1; local J; mk_pr_repo
  prx "$PT" --dry-run --title "  " --summary-file "$F/sum.md" --evidence-file "$F/ev.txt" --head feat/x >/dev/null 2>&1; eq "$?" 64 "[P3] a blank title: rc 64"
  prx "$PT" --dry-run --title t --evidence-file "$F/ev.txt" --head feat/x >/dev/null 2>&1; eq "$?" 64 "[P3] a missing required argument: rc 64"
  prd --no-such-flag >/dev/null 2>&1; eq "$?" 64 "[P3] an unknown flag: rc 64"
  prx "$PT" --dry-run --title t --summary-file "$F/sum.md" --evidence-file "$F/ev.txt" --head main >/dev/null 2>&1; eq "$?" 64 "[P3] --head main: rc 64"
  prx "$PT" --dry-run --title t --summary-file "$F/sum.md" --evidence-file "$F/ev.txt" --head master >/dev/null 2>&1; eq "$?" 64 "[P3] --head master: rc 64"
  J=$(prx "$PT" --dry-run --title t --summary-file "$F/sum.md" --evidence-file "$F/ev.txt" 2>/dev/null)
  eq "$(pj "$J" head)" feat/x "[P3] no --head: the checked-out branch is the head"
  git_ -C "$PT" checkout -q --detach
  prx "$PT" --dry-run --title t --summary-file "$F/sum.md" --evidence-file "$F/ev.txt" >/dev/null 2>&1; eq "$?" 64 "[P3] detached HEAD and no --head: rc 64"
  J=$(prx "$PT" --dry-run --title t --summary-file "$F/sum.md" --evidence-file "$F/ev.txt" --head other 2>/dev/null)
  eq "$(pj "$J" head)" other "[P3] an explicit --head is used as given"
  eq "$(pj "$J" base)" main "[P3] the base defaults to main"
  J=$(prx "$PT" --dry-run --title t --summary-file "$F/sum.md" --evidence-file "$F/ev.txt" --head other --base release 2>/dev/null)
  eq "$(pj "$J" base)" release "[P3] --base is used as given"
}

mk_gate_script() {  # mk_gate_script <repo main tree> — a synthetic scripts/check-current-state.py with the contract decide(paths, body)
  mkdir -p "$1/scripts"
  cat > "$1/scripts/check-current-state.py" <<PY
import json, os
HERE = os.path.dirname(os.path.abspath(__file__))
TOKEN = "$TOK_NO_STATE_CHANGE"

def decide(paths, body):
    with open(os.path.join(HERE, "decide.args"), "w", encoding="utf-8") as f:
        json.dump({"paths": paths, "body": body}, f, ensure_ascii=False)
    if not any(p.startswith("watched/") for p in paths):
        return 0, "no watched path changed"
    if "kb/current-state.md" in paths:
        return 0, "ledger changed"
    for line in body.splitlines():
        if line.startswith(TOKEN) and len(line) - len(TOKEN) >= 15:
            return 0, "exempt"
    return 1, "ledger not changed; add a body line: " + TOKEN + " <reason>"
PY
  git_ -C "$1" add scripts/check-current-state.py; git_ -C "$1" commit -q -m "gate"; git_ -C "$1" push -q origin main
}

fam_gate() {  # rc 4: the ledger gate of the repo, called with the changed paths and the final body
  PLX=$1; local J rc out ARGS
  PW=$(mk_origin); mk_gate_script "$PW"; git_ -C "$PW" worktree add -q -b feat/x "$PW/../wt" main; PT=$(cd "$PW/../wt" && pwd -P)
  F=$(fresh); printf 'A real summary line.\n' > "$F/sum.md"; printf '$ echo ok\nok\n' > "$F/ev.txt"
  mkdir -p "$PT/other"; commit_in "$PT" other/a.txt a "change outside the watched directory"
  J=$(prd --base main 2>/dev/null); rc=$?
  eq "$rc" 0 "[P4] a change outside the watched directory: rc 0"
  ARGS=$(cat "$PT/scripts/decide.args" 2>/dev/null)
  eq "$(python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["paths"]))' <<<"${ARGS:-{\}}" 2>/dev/null)" '["other/a.txt"]' "[P4] decide() got exactly the paths changed against the base"
  eq "$(pj "${ARGS:-{\}}" body 2>/dev/null)" "$(pj "$J" body)" "[P4] …and exactly the body that goes into the payload"
  mkdir -p "$PT/watched"; commit_in "$PT" watched/k.yaml k "change in the watched directory"
  out=$(prd --base main 2>&1 >/dev/null); rc=$?
  eq "$rc" 4 "[P4] a watched change with no ledger change and no exemption: rc 4"
  has "$out" "$TOK_NO_STATE_CHANGE" "[P4] …the refusal carries the gate's own message (the exemption token to add)"
  printf 'Adds a manifest.\n\n%s only an internal value changed, architecture is the same\n' "$TOK_NO_STATE_CHANGE" > "$F/sum-ex.md"
  J=$(prd --base main --summary-file "$F/sum-ex.md" 2>/dev/null); rc=$?
  eq "$rc" 0 "[P4] the exemption line in the summary: rc 0"
  hasline "$(pj "$J" body)" "$TOK_NO_STATE_CHANGE only an internal value changed, architecture is the same" "[P4] …the exemption line travels into the body verbatim"
  ARGS=$(cat "$PT/scripts/decide.args")
  eq "$(pj "$ARGS" body)" "$(pj "$J" body)" "[P4] …and decide() saw that same body"
  printf 'Adds a manifest.\n\n%s too short\n' "$TOK_NO_STATE_CHANGE" > "$F/sum-short.md"
  prd --base main --summary-file "$F/sum-short.md" >/dev/null 2>&1; eq "$?" 4 "[P4] the gate's own rule on the exemption is honoured (a too-short reason: rc 4)"
  prd --base no-such-base >/dev/null 2>&1; eq "$?" 4 "[P4] a base the core cannot resolve, with a gate present: rc 4 (it does not conclude)"
  mkdir -p "$PT/kb"; commit_in "$PT" kb/current-state.md ledger "ledger updated"
  prd --base main >/dev/null 2>&1; eq "$?" 0 "[P4] the ledger changed in the same branch: rc 0"
  # a repo without the script: the gate does not apply, whatever changed
  local R2 W2 T2; R2=$(mk_origin); git_ -C "$R2" worktree add -q -b feat/y "$R2/../wt" main; T2=$(cd "$R2/../wt" && pwd -P)
  mkdir -p "$T2/watched"; commit_in "$T2" watched/k.yaml k "change"
  prx "$T2" --dry-run --title t --summary-file "$F/sum.md" --evidence-file "$F/ev.txt" --head feat/y --base main >/dev/null 2>&1
  eq "$?" 0 "[P4] a repo with no scripts/check-current-state.py: the gate does not apply, rc 0"
}

fam_body() {  # the shape of the body
  PLX=$1; local J B i s; mk_pr_repo
  J=$(prd 2>/dev/null); B=$(pj "$J" body)
  hasline "$B" "## $TOK_SUMMARY" "[P5] section: summary"; hasline "$B" "## $TOK_EVIDENCE" "[P5] section: run evidence"
  eq "$(printf '%s\n' "$B" | grep -nFx -e "## $TOK_SUMMARY" -e "## $TOK_EVIDENCE" | cut -d: -f2 | tr '\n' ',')" "## $TOK_SUMMARY,## $TOK_EVIDENCE," "[P5] …in that order"
  eq "$(nline "$B" "## $TOK_CRITERIA")" 0 "[P5] no criteria section when no criteria file is given"
  eq "$(nline "$B" "## $TOK_FLOW")" 0 "[P5] no flow section: the pr-evidence gate checks the evidence the ticks only claimed"
  eq "$(printf '%s\n' "$B" | grep -c -E '^- \[[ x]\] ')" 0 "[P5] …and no tick line at all"
  # a summary that repeats the section heading must not double it
  for s in "## $TOK_SUMMARY" "### $TOK_SUMMARY  " "#$TOK_SUMMARY"; do
    printf '%s\nThe real text.\n' "$s" > "$F/sum-dup.md"
    B=$(pj "$(prd --summary-file "$F/sum-dup.md" 2>/dev/null)" body)
    eq "$(printf '%s\n' "$B" | grep -c -E "^#{1,6}[ ]*$TOK_SUMMARY[ ]*$")" 1 "[P5] a summary starting with '$s': one summary heading in the body"
  done
  # evidence longer than 80 lines is cut to its first 10 and last 70 lines (with the cap on pr.body.* off: [P12] covers the cap)
  mkdir -p "$PT/.vibemaestro"; printf '{"pr": {"body": {"max_chars": 0, "summary_max_lines": 0, "evidence_max_lines": 0}}}' > "$PT/.vibemaestro/sdlc.json"
  for i in $(seq 1 200); do printf 'L%03d\n' "$i"; done > "$F/ev-long.txt"
  B=$(pj "$(prd --evidence-file "$F/ev-long.txt" 2>/dev/null)" body)
  hasline "$B" L001 "[P5] 200 evidence lines: the first line is kept"; hasline "$B" L010 "[P5] …the tenth line is kept"
  eq "$(nline "$B" L011)" 0 "[P5] …the eleventh is cut"; eq "$(nline "$B" L130)" 0 "[P5] …line 130 is cut"
  hasline "$B" L131 "[P5] …line 131 (the first of the last 70) is kept"; hasline "$B" L200 "[P5] …the last line is kept"
  eq "$(printf '%s\n' "$B" | awk '/^```$/{n++; next} n==1{c++} END{print c}')" 81 "[P5] …the fenced block holds 10 + a cut marker + 70 lines"
  eq "$(printf '%s\n' "$B" | grep -c '120')" 1 "[P5] …and the marker states the 120 cut lines"
  for i in $(seq 1 80); do printf 'M%03d\n' "$i"; done > "$F/ev-80.txt"
  B=$(pj "$(prd --evidence-file "$F/ev-80.txt" 2>/dev/null)" body)
  eq "$(printf '%s\n' "$B" | awk '/^```$/{n++; next} n==1{c++} END{print c}')" 80 "[P5] exactly 80 evidence lines are not cut"
  rm -f "$PT/.vibemaestro/sdlc.json"
  # criteria: every line becomes an open checkbox with its text kept; bullets and ticks the agent wrote are stripped
  printf -- '- first\n* [x] second\n1. third\n  - [ ] fourth\n\n' > "$F/crit.txt"
  B=$(pj "$(prd --crit-file "$F/crit.txt" 2>/dev/null)" body)
  hasline "$B" "## $TOK_CRITERIA" "[P5] criteria: the section is present"
  for s in first second third fourth; do hasline "$B" "- [ ] $s" "[P5] criteria: '$s' is an open checkbox"; done
  eq "$(printf '%s\n' "$B" | grep -c -F -e '- [x]' | tr -d ' ')" 0 "[P5] criteria: no ticked checkbox"
}

fam_tester() {  # `pr.flow` and `pr.tester_exempt` are deprecated: a config that sets them changes no body, and is warned about
  PLX=$1; local DEC B B0 OUT; mk_pr_repo
  DEC="kb/decisions/example-no-e2e.md"
  B0=$(pj "$(prd 2>/dev/null)" body)
  mkdir -p "$PT/.vibemaestro" "$PT/kb/decisions"; : > "$PT/$DEC"
  printf '{"pr": {"tester_exempt": {"decision": "%s"}, "flow": ["a", "b"]}}' "$DEC" > "$PT/.vibemaestro/sdlc.json"
  B=$(pj "$(prd 2>/dev/null)" body)
  eq "$B" "$B0" "[P6] pr.flow and pr.tester_exempt set (a decision file on the tree): the body is the same as without them"
  OUT=$(prd 2>&1 >/dev/null)
  has "$OUT" "pr.flow: deprecated since" "[P6] …and open-pr warns that pr.flow is deprecated"
  has "$OUT" "pr.tester_exempt: deprecated since" "[P6] …and pr.tester_exempt"
  rm -f "$PT/.vibemaestro/sdlc.json"
}

fam_payload() {  # the payload, --payload-out, --draft, --dry-run
  PLX=$1; local J J2 B; mk_pr_repo
  J=$(prd --payload-out "$F/p.json" 2>/dev/null)
  eq "$(pkeys "$J")" "base body head title" "[P7] the payload has exactly title, head, base and body"
  eq "$(pj "$J" title)" "feat: x" "[P7] title is as given"
  eq "$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), sort_keys=True))' "$F/p.json")" "$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1]), sort_keys=True))' "$J")" "[P7] --payload-out holds the same payload that --dry-run prints"
  J=$(prd --draft 2>/dev/null)
  eq "$(pj "$J" draft)" true "[P7] --draft adds draft: true"
  eq "$(pkeys "$J")" "base body draft head title" "[P7] …and only that key"
  # --dry-run needs no gh and no network: a PATH without gh
  J=$( cd "$PT" && cenv PATH="$(bare_path nogh)" python3 "$PLX/scripts/open_pr.py" --dry-run --title t --summary-file "$F/sum.md" --evidence-file "$F/ev.txt" --head feat/x 2>/dev/null ); rc=$?
  eq "$rc" 0 "[P7] --dry-run with no gh on PATH: rc 0"
  eq "$(pkeys "$J")" "base body head title" "[P7] …and it prints the payload"
}

fam_gh() {  # the gh transport: arguments, body on stdin, failures, rc 67
  PLX=$1; local out rc DRY; mk_pr_repo
  GL="$F/gh.log"; : > "$GL"
  out=$(prg GH_LOG="$GL" GH_STDIN="$F/stdin.md" -- 2>/dev/null); rc=$?
  eq "$rc" 0 "[P8] with a working gh: rc 0"; eq "$out" 7 "[P8] stdout is the PR number"
  has "$(cat "$GL")" "[pr] [create]" "[P8] gh pr create was called"
  has "$(cat "$GL")" "[--title] [feat: x]" "[P8] …with the title"; has "$(cat "$GL")" "[--base] [main]" "[P8] …with the base"
  has "$(cat "$GL")" "[--head] [feat/x]" "[P8] …with the head"; has "$(cat "$GL")" "[--body-file] [-]" "[P8] …and the body on stdin"
  hasnt "$(cat "$GL")" "[--draft]" "[P8] …no --draft when the flag is absent"
  DRY=$(pj "$(prd 2>/dev/null)" body)
  eq "$(cat "$F/stdin.md")" "$DRY" "[P8] the body gh receives is the body --dry-run builds"
  : > "$GL"; prg GH_LOG="$GL" -- --draft >/dev/null 2>&1
  has "$(cat "$GL")" "[--draft]" "[P8] --draft is passed to gh pr create"
  # failures of gh: a non-zero exit, and a gh that cannot even be started, are rc 1 with nothing on stdout
  mkdir -p "$F/failbin"; printf '#!/bin/sh\nexit 1\n' > "$F/failbin/gh"; chmod +x "$F/failbin/gh"
  out=$( cd "$PT" && cenv PATH="$F/failbin:$PATH" python3 "$PLX/scripts/open_pr.py" --title t --summary-file "$F/sum.md" --evidence-file "$F/ev.txt" --head feat/x 2>/dev/null ); rc=$?
  eq "$rc" 1 "[P8] gh pr create exits non-zero: rc 1"; empty "$out" "[P8] …and nothing is printed on stdout"
  mkdir -p "$F/brokenbin"; printf '#!/nonexistent/interpreter\n' > "$F/brokenbin/gh"; chmod +x "$F/brokenbin/gh"
  out=$( cd "$PT" && cenv PATH="$F/brokenbin:$PATH" python3 "$PLX/scripts/open_pr.py" --title t --summary-file "$F/sum.md" --evidence-file "$F/ev.txt" --head feat/x 2>/dev/null ); rc=$?
  eq "$rc" 1 "[P8] gh cannot be started: rc 1"
  # gh is not installed: rc 67
  out=$( cd "$PT" && cenv PATH="$(bare_path nogh)" python3 "$PLX/scripts/open_pr.py" --title t --summary-file "$F/sum.md" --evidence-file "$F/ev.txt" --head feat/x 2>/dev/null ); rc=$?
  eq "$rc" 67 "[P8] no gh on PATH: rc 67"
  empty "$out" "[P8] …nothing on stdout"
  # the refusals come before the transport: evidence missing is rc 3 even with no gh
  ( cd "$PT" && cenv PATH="$(bare_path nogh)" python3 "$PLX/scripts/open_pr.py" --title t --summary-file "$F/sum.md" --evidence-file "$F/ev-empty.txt" --head feat/x ) >/dev/null 2>&1
  eq "$?" 3 "[P8] the refusals run before the transport: empty evidence with no gh is rc 3, not 67"
}

fam_transport() {  # [P9] one transport: no environment selects a network path, --repo replaces SLUGPATH, --gh is accepted and ignored
  PLX=$1; local out rc GL CL SB BP; mk_pr_repo
  GL="$F/gh.log"; CL="$F/curl.log"; : > "$GL"; : > "$CL"
  # a `curl` that records every call, first in PATH. Its own log, not NET_LOG: a core that reaches for it must make THIS family
  # red, not the closing network check of the suite (a planted break would otherwise taint the run that reports it).
  SB="$F/shimbin"; mkdir -p "$SB"; printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nexit 97\n' "$CL" > "$SB/curl"; chmod +x "$SB/curl"
  printf 'not-a-real-token\n' > "$F/token"
  # the environment of a sandbox session and of the old API channel: a token file, a slug variable. Neither selects anything.
  out=$(prg PATH="$SB:$GHB:$PATH" GH_LOG="$GL" GH_TOKEN_FILE="$F/token" SLUGPATH=acme/app-demo -- 2>/dev/null); rc=$?
  eq "$rc" 0 "[P9] a token file and a slug in the environment, no flag: rc 0"; eq "$out" 7 "[P9] …the PR number comes from gh"
  has "$(cat "$GL")" "[pr] [create]" "[P9] …gh pr create was called"
  eq "$(wc -l < "$CL" | tr -d ' ')" 0 "[P9] …and a curl on PATH recorded 0 calls"
  hasnt "$(cat "$GL")" "[--repo]" "[P9] …the slug variable of the old channel is not a --repo"
  out=$(prg PATH="$SB:$GHB:$PATH" GH_LOG="$GL" -- 2>/dev/null); rc=$?
  eq "$rc" 0 "[P9] no environment and no flag: rc 0 (the retired rc 65 does not exist)"
  # gh missing: rc 67 whatever the environment holds, and still no curl
  out=$( cd "$PT" && cenv PATH="$SB:$(bare_path nogh)" GH_TOKEN_FILE="$F/token" SLUGPATH=acme/app-demo python3 "$PLX/scripts/open_pr.py" --title t --summary-file "$F/sum.md" --evidence-file "$F/ev.txt" --head feat/x 2>/dev/null ); rc=$?
  eq "$rc" 67 "[P9] no gh and a token file in the environment: rc 67, not a fallback"; empty "$out" "[P9] …nothing on stdout"
  eq "$(wc -l < "$CL" | tr -d ' ')" 0 "[P9] …and the curl recorded 0 calls"
  # --repo reaches gh pr create; --gh is accepted and ignored (one minor of deprecation)
  : > "$GL"; prg GH_LOG="$GL" -- --repo acme/app-demo >/dev/null 2>&1
  has "$(cat "$GL")" "[--repo] [acme/app-demo]" "[P9] --repo is passed to gh pr create"
  : > "$GL"; prg GH_LOG="$GL" -- >/dev/null 2>&1; hasnt "$(cat "$GL")" "[--repo]" "[P9] no --repo: gh chooses the repository itself"
  : > "$GL"; prg GH_LOG="$GL" -- --repo "" >/dev/null 2>&1; hasnt "$(cat "$GL")" "[--repo]" "[P9] an empty --repo is no --repo"
  : > "$GL"; prg GH_LOG="$GL" -- --repo "   " >/dev/null 2>&1; hasnt "$(cat "$GL")" "[--repo]" "[P9] a blank --repo is no --repo"
  : > "$GL"; out=$(prg GH_LOG="$GL" -- --gh 2>/dev/null); rc=$?
  eq "$rc" 0 "[P9] --gh is accepted: rc 0, not 64"; eq "$out" 7 "[P9] …and the PR is opened as without it"
  has "$(cat "$GL")" "[pr] [create]" "[P9] …through gh"
  out=$( cd "$PT" && cenv PATH="$(bare_path nogh)" python3 "$PLX/scripts/open_pr.py" --gh --title t --summary-file "$F/sum.md" --evidence-file "$F/ev.txt" --head feat/x 2>/dev/null ); rc=$?
  eq "$rc" 67 "[P9] --gh with no gh on PATH: still rc 67"
  # a title that violates pr.title is rc 64 on the posting path, before gh is called
  mkdir -p "$PT/.vibemaestro"; printf '{"pr": {"title": {"pattern": "^(feat|fix): .+$"}}}' > "$PT/.vibemaestro/sdlc.json"
  : > "$GL"; prg GH_LOG="$GL" -- --title "no type prefix" >/dev/null 2>&1; rc=$?
  eq "$rc" 64 "[P9] a title that violates pr.title: rc 64"; eq "$(grep -c '\[pr\] \[create\]' "$GL")" 0 "[P9] …and gh was not called"
}

fam_bodycap() {  # the cap on the body: pr.body.max_chars, summary_max_lines, evidence_max_lines (gates/pr_body.py), rc 2
  PLX=$1; local out rc L GL; mk_pr_repo; GL="$F/gh.log"
  lines() { local i; for i in $(seq 1 "$2"); do printf '%s %03d\n' "$1" "$i"; done; }
  lines s 10 > "$F/sum10.md"; lines s 11 > "$F/sum11.md"; lines e 30 > "$F/ev30.txt"; lines e 31 > "$F/ev31.txt"
  prd --summary-file "$F/sum10.md" --evidence-file "$F/ev30.txt" >/dev/null 2>&1; eq "$?" 0 "[P12] a summary of 10 lines and an evidence of 30: rc 0"
  out=$(prd --summary-file "$F/sum11.md" 2>"$F/err.txt"); rc=$?
  eq "$rc" 2 "[P12] a summary of 11 lines: rc 2"; empty "$out" "[P12] …nothing on stdout (no payload, also under --dry-run)"
  has "$(cat "$F/err.txt")" "pr.body.summary_max_lines (10)" "[P12] …the refusal names the key and the limit"
  has "$(cat "$F/err.txt")" "11 non-empty lines" "[P12] …and the number"
  has "$(cat "$F/err.txt")" "the summary file has 11 non-empty lines" "[P12] …and the size of the file given"
  out=$(prd --evidence-file "$F/ev31.txt" 2>"$F/err.txt"); rc=$?
  eq "$rc" 2 "[P12] an evidence of 31 lines: rc 2"; has "$(cat "$F/err.txt")" "pr.body.evidence_max_lines (30)" "[P12] …names the key and the limit"
  has "$(cat "$F/err.txt")" "the evidence file 31" "[P12] …and the size of the evidence file"
  printf '%s no database\n' "$TOK_NOT_RUN" > "$F/ev-nr.txt"; lines e 29 >> "$F/ev-nr.txt"
  prd --evidence-file "$F/ev-nr.txt" >/dev/null 2>&1; eq "$?" 0 "[P12] an evidence of 30 lines that starts with the not-run token: rc 0 (the kit's note above the block is not counted)"
  lines e 30 >> "$F/ev-nr.txt"
  prd --evidence-file "$F/ev-nr.txt" >/dev/null 2>&1; eq "$?" 2 "[P12] …and of 59 lines: rc 2"
  python3 -c 'print("word " * 700)' > "$F/sum-long.md"
  prd --summary-file "$F/sum-long.md" >/dev/null 2>"$F/err.txt"; eq "$?" 2 "[P12] a one-line summary of 3500 characters: rc 2"
  has "$(cat "$F/err.txt")" "pr.body.max_chars (3000)" "[P12] …names the key"
  # the boundary on a real built body: the limit set to its exact length passes, one less is refused
  L=$(pj "$(prd 2>/dev/null)" body | python3 -c 'import sys; print(len(sys.stdin.read().strip()))')
  mkdir -p "$PT/.vibemaestro"; printf '{"pr": {"body": {"max_chars": %s}}}' "$L" > "$PT/.vibemaestro/sdlc.json"
  prd >/dev/null 2>&1; eq "$?" 0 "[P12] max_chars equal to the built body ($L characters): rc 0"
  printf '{"pr": {"body": {"max_chars": %s}}}' "$((L - 1))" > "$PT/.vibemaestro/sdlc.json"
  prd >/dev/null 2>&1; eq "$?" 2 "[P12] max_chars one less: rc 2"
  printf '{"pr": {"body": {"max_chars": 0, "summary_max_lines": 0, "evidence_max_lines": 0}}}' > "$PT/.vibemaestro/sdlc.json"
  prd --summary-file "$F/sum-long.md" --evidence-file "$F/ev31.txt" >/dev/null 2>&1; eq "$?" 0 "[P12] the three limits at 0: a long body opens"
  rm -f "$PT/.vibemaestro/sdlc.json"
  : > "$GL"; prg GH_LOG="$GL" -- --summary-file "$F/sum11.md" >/dev/null 2>&1; rc=$?
  eq "$rc" 2 "[P12] on the posting path too: rc 2"; eq "$(grep -c '\[pr\] \[create\]' "$GL")" 0 "[P12] …and gh was not called"
  mkdir -p "$PT/.vibemaestro"; printf '{"pr": {"body": {"max_chars": "x"}}}' > "$PT/.vibemaestro/sdlc.json"
  prd >/dev/null 2>&1; eq "$?" 64 "[P12] an invalid pr.body value: rc 64 (the config is checked first)"
}

FAMILIES="fam_tree fam_evidence fam_args fam_gate fam_body fam_tester fam_payload fam_gh fam_transport fam_bodycap"

echo "== the real core =="
PL0="$TMP/plugin-real"; mk_plugin_copy "$PL0"
[ -f "$PL0/scripts/open_pr.py" ] && ok "instrument: the plugin copy has the core" || bad "instrument: the core is missing from the copy"
[ -x "$GHB/gh" ] && ok "instrument: the fake gh is executable" || bad "instrument: the fake gh is not executable"
for f in $FAMILIES; do echo "-- $f"; "$f" "$PL0"; done

echo "== planted breaks: each family must go red on a core with one break =="
BRK() {  # BRK <label> <family> <needle> <old> <new>
  local d="$TMP/break-$1"; mk_plugin_copy "$d"
  mutate "$d/scripts/open_pr.py" "$4" "$5" && expect_red "$1" "$2" "$d" "$3"
}
BRKC() {  # BRKC <label> <family> <needle> <old> <new> — the same on the config loader, which owns the default flow text
  local d="$TMP/break-$1"; mk_plugin_copy "$d"
  mutate "$d/scripts/sdlc_config.py" "$4" "$5" && expect_red "$1" "$2" "$d" "$3"
}
BRK main-tree-allowed fam_tree '[P1] from the main tree: rc 5' '    if not wt:
        err(M("op.main_tree",' '    if False:
        err(M("op.main_tree",'
BRK git-env-not-stripped fam_tree '[P1] main tree with GIT_DIR' '_GIT_ENV_STRIP = ("GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE")' '_GIT_ENV_STRIP = ()'
BRK empty-evidence-allowed fam_evidence '[P2] empty evidence file: rc 3' 'if evidence is None or not evidence.strip():' 'if evidence is None:'
BRK heading-only-summary-allowed fam_evidence '[P2] a summary that is only its heading' 'r"[ \t]*(\r?\n+|\Z)", "", summary.strip()' 'r"[ \t]*(\r?\n+)", "", summary.strip()'
BRK payload-out-error-swallowed fam_evidence '[P2] --payload-out that cannot be written' '            err(M("op.payload_out", e))
            return 66' '            err(M("op.payload_out", e))
            return 0'
BRK blank-title-allowed fam_args '[P3] a blank title' '    if not a.title.strip():' '    if False:'
BRK main-head-allowed fam_args '[P3] --head main' '    if head in cfg["branch"]["protected"]:' '    if False:'
BRK ledger-gate-ignored fam_gate '[P4] a watched change with no ledger change' '        err("the current-state gate refuses: the PR is NOT opened.\n" + cs_msg)
        return 4' '        err("the current-state gate refuses: the PR is NOT opened.\n" + cs_msg)
        return 0'
BRK unresolved-base-passes fam_gate '[P4] a base the core cannot resolve' '        return 1, ("cannot resolve base' '        return 0, ("cannot resolve base'
BRK exemption-anywhere fam_evidence '[P2] the token in the middle' 'exempt = ev.lstrip().startswith(tk["not_run"])' 'exempt = tk["not_run"] in ev'
BRK exemption-marker-dropped fam_evidence '[P2] …under a warning marker' '    head_note = tk["not_run_note"] + "\n\n" if exempt else ""' '    head_note = tk["not_run_note"].replace("⚠ ", "") + "\n\n" if exempt else ""'
BRK evidence-never-cut fam_body '[P5] …the eleventh is cut' 'MAX_EV_LINES = 80 ' 'MAX_EV_LINES = 8000 '
BRK evidence-keeps-wrong-ends fam_body '[P5] …line 131' 'KEEP_HEAD, KEEP_TAIL = 10, 70' 'KEEP_HEAD, KEEP_TAIL = 70, 10'
BRK duplicate-heading-kept fam_body '[P5] a summary starting with' 're.escape(tk["summary_heading"])' 're.escape(tk["summary_heading"]) + "X"'
BRK ticks-kept-in-criteria fam_body "[P5] criteria: 'second'" 'r"^\s*(?:[-*]|\d+\.)\s*(?:\[[ xX]\]\s*)?"' 'r"^\s*(?:[-*]|\d+\.)\s*"'
BRK flow-back fam_body '[P5] no flow section' '            % (fix_block, close_block, tk["summary_heading"], summ, crit_block, tk["evidence_heading"], head_note, fence, ev, fence))' '            % (fix_block, close_block, tk["summary_heading"], summ, crit_block, tk["evidence_heading"], head_note, fence, ev, fence)
            + "\n## %s\n\n- [x] Worker\n" % tk["flow_heading"])'
BRKC tester-not-deprecated fam_tester '[P6] …and pr.tester_exempt' '    "pr.tester_exempt": {"since": "2026-10-20", "use": None,' '    "pr.tester_exempt_x": {"since": "2026-10-20", "use": None,'
BRK draft-always fam_payload '[P7] the payload has exactly' '    if a.draft or cfg["pr"]["draft"]:' '    if True:'
BRK draft-not-passed-to-gh fam_gh '[P8] --draft is passed to gh' '    if payload.get("draft"):' '    if False:'
BRK gh-failure-swallowed fam_gh '[P8] gh pr create exits non-zero' '        print("gh pr create rc=%s: %s" % (r.returncode, r.stderr[:400]), file=sys.stderr)
        return 1' '        print("gh pr create rc=%s: %s" % (r.returncode, r.stderr[:400]), file=sys.stderr)
        return 0'
BRK missing-gh-is-rc-1 fam_gh '[P8] no gh on PATH' '        err("no `gh` on this machine")
        return 67' '        err("no `gh` on this machine")
        return 1'
BRK env-selects-curl fam_transport '[P9] …and a curl on PATH recorded 0 calls' '    gh = shutil.which("gh")
    if not gh:' '    if os.environ.get("GH_TOKEN_FILE"):
        subprocess.run(["curl", "-X", "POST", "https://example.invalid/pulls"], capture_output=True)
        return 0
    gh = shutil.which("gh")
    if not gh:'
BRK env-slug-becomes-repo fam_transport '[P9] …the slug variable of the old channel' '    if slug:
        cmd += ["--repo", slug]
    try:
        r = subprocess.run(cmd, input=payload["body"],' '    slug = slug or os.environ.get("SLUGPATH")
    if slug:
        cmd += ["--repo", slug]
    try:
        r = subprocess.run(cmd, input=payload["body"],'
BRK repo-not-passed fam_transport '[P9] --repo is passed to gh pr create' '        cmd.append("--draft")
    if slug:
        cmd += ["--repo", slug]' '        cmd.append("--draft")'
BRK gh-flag-rejected fam_transport '[P9] --gh is accepted' '    ap.add_argument("--gh", action="store_true")' ''
BRK title-rule-ignored-on-post fam_transport '[P9] a title that violates pr.title' '    if tcfg["pattern"] and not re.search(tcfg["pattern"], a.title):' '    if False:'
BRK cap-skipped fam_bodycap '[P12] a summary of 11 lines: rc 2' '    over = pr_body.check_body(body, cfg)
    if over:' '    over = []
    if over:'
BRK cap-exit-code fam_bodycap '[P12] a summary of 11 lines: rc 2' '               sum(1 for ln in evidence.splitlines() if ln.strip())))
        return 2' '               sum(1 for ln in evidence.splitlines() if ln.strip())))
        return 3'
BRK cap-after-gh fam_bodycap '[P12] …and gh was not called' '    over = pr_body.check_body(body, cfg)
    if over:' '    over = pr_body.check_body(body, cfg) if a.dry_run else []
    if over:'
PLC="$TMP/break-none"; mk_plugin_copy "$PLC"
QN=0; okdef=$(declare -f ok); baddef=$(declare -f bad); sp=$PASS; sf=$FAIL
ok() { :; }; bad() { QN=$((QN+1)); }
for f in $FAMILIES; do "$f" "$PLC" >/dev/null 2>&1; done
eval "$okdef"; eval "$baddef"; PASS=$sp; FAIL=$sf
eq "$QN" 0 "control: an unbroken copy passes every family (no failed check)"

echo; summary
