#!/bin/bash
# =============================================================================
# The soft size warning of kb/current-state.md: one function, three places, no change of any return code
# =============================================================================
# Run: bash tests/test-current-state-warn.sh
#
# `current_state.size_warning` returns ONE `WARNING` line when the ledger is at
# or under its hard cap and has reached `current_state.limits.warn_ratio` of it. Three places show it, and each has its own family:
#   [S] the shape check  `kb.py check current-state`
#   [D] the diff gate    `kb.py check current-state --diff` (what CI runs)
#   [P] the PR core      `open_pr.py` (what `open-pr.sh` runs), on stderr
#   [H] the edit hook    PreToolUse Edit on the ledger, once per session per size
#   [R] the edges: the ratio and the caps it applies to (bytes, lines, `lines: null`)
#   [C] the key: default, accepted values, rejected values
#   [N] dated labels (`current_state.labels`): no date, older than N, after tomorrow, a runaway regex; no key = today
# Every place is checked at the same sizes against a cap of 1000 bytes: one byte below the share (no warning), exactly at it (one
# warning), at the cap (one warning, still a pass) and one byte over (today's failure, no warning). The return code is asserted next
# to the warning each time. Then each planted break must turn its family red: a break of the shared function turns all four places
# red, and a break of the call in ONE place turns only that place red (an unbroken copy must stay green).
# Real git on throw-away repositories, the hooks run through the command of hooks/hooks.json, no network.
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

PLX=""; PW=""; PT=""; F=""
LED=kb/current-state.md
WARN_RX='WARNING kb/current-state.md:'

# ── fixtures ─────────────────────────────────────────────────────────────
# ledger_of <bytes> [width] — exactly <bytes> bytes of lines of <width> characters (default 99) and a newline, plain letters: no history sign
ledger_of() {
  python3 - "$1" "${2:-99}" <<'PY'
import sys
n, w = int(sys.argv[1]), int(sys.argv[2])
out = ""
while len(out) < n:
    k = min(w, n - len(out) - 1)
    out += "a" * k + "\n"
sys.stdout.write(out)
PY
}
# cfg <ratio|-> [lines|null|-] [bytes] — a config whose ledger cap is <bytes> (default 1000), watching src/
cfg() {
  python3 - "$1" "${2:--}" "${3:-1000}" <<'PY'
import json, sys
r, l, b = sys.argv[1:4]
lim = {"bytes": int(b)}
if r != "-":
    lim["warn_ratio"] = json.loads(r)
if l != "-":
    lim["lines"] = json.loads(l)
print(json.dumps({"schema": 1, "current_state": {"watch": ["src/"], "limits": lim}}))
PY
}
# mk_case <config json> <ledger bytes> [width] — PT: a worktree on feat/x whose base (gbase) has the config and a short ledger, and
# whose branch changes the ledger to <bytes> bytes. The working tree holds that ledger too.
mk_case() {
  mk_pr_repo
  mkdir -p "$PT/.vibemaestro" "$PT/kb" "$PT/src"
  printf '%s' "$1" > "$PT/.vibemaestro/sdlc.json"; printf '# State\n\nShort.\n' > "$PT/$LED"
  git_ -C "$PT" add -A; git_ -C "$PT" commit -q -m "config and ledger"; git_ -C "$PT" branch -f gbase
  ledger_of "$2" "${3:-99}" > "$PT/$LED"; git_ -C "$PT" add "$LED"; git_ -C "$PT" commit -q -m "ledger"
  : > "$F/body-empty.txt"
}
kbd() { ( cd "$PT" && cenv python3 "$PLX/scripts/kb.py" "$@" ); }
# place <name> — runs the place on PT, sets OUT (what the session sees) and RC
place() {
  case "$1" in
    shape) OUT=$(kbd check current-state 2>&1); RC=$?;;
    diff)  OUT=$(kbd check current-state --diff gbase...HEAD --body-file "$F/body-empty.txt" 2>&1); RC=$?;;
    pr)    OUT=$(prd --base gbase 2>&1 >/dev/null); RC=$?;;
    hook)  local s; s=$(sid)
           OUT=$(CLAUDE_PROJECT_DIR="$PT" CLAUDE_PLUGIN_ROOT="$PLX" run_cmds "$PLX/hooks/hooks.json" PreToolUse Edit "$(p_edit "$s" "$PT/$LED")")
           RC=0; [ -z "$OUT" ] || OUT=$(ctx "$OUT");;
  esac
}
nwarn() { printf '%s\n' "$1" | grep -c -- "$WARN_RX" || true; }
# expect <place> <tag> <config> <bytes> <warnings wanted> <rc wanted> <what> — one case: the number of warning lines and the return code
expect() {
  mk_case "$3" "$4"; place "$1"
  eq "$(nwarn "$OUT")" "$5" "[$2] $1: $7: $5 warning line(s)"
  eq "$RC" "$6" "[$2] $1: $7: rc $6"
}

# the sizes against a cap of 1000 and the default share 0.85 — the same four cases in every place; rc_over is the place's refusal code
sizes() {  # sizes <place> <letter> <rc over the cap>
  local pl=$1 L=$2 over=$3 C; C=$(cfg 0.85)
  expect "$pl" "${L}1" "$C" 849 0 0 "849 of 1000 bytes (84%, one byte below the share)"
  expect "$pl" "${L}2" "$C" 850 1 0 "850 of 1000 bytes (exactly the share)"
  expect "$pl" "${L}3" "$C" 1000 1 0 "1000 of 1000 bytes (at the cap)"
  expect "$pl" "${L}4" "$C" 1001 0 "$over" "1001 of 1000 bytes (over the cap: today's failure, no warning)"
}

fam_shape() { PLX=$1; sizes shape S 65
  mk_case "$(cfg 0.85)" 900; place shape
  has "$OUT" "900/1000" "[S5] the line names the size and the cap"
  has "$OUT" "90%" "[S6] …and the share"
  has "$OUT" "85%" "[S7] …and where the warning starts"
  has "$OUT" "passes the current-state shape" "[S8] the usual pass line is still there, with the warning after it"
  mk_case "$(cfg 0.85)" 999; place shape
  has "$OUT" "99.9%" "[S9] 999 of 1000 reads 99.9%, never 100% (the share is rounded down)"
  ledger_of 900 > "$PT/other.md"; OUT=$(kbd check current-state other.md 2>&1); RC=$?
  has "$OUT" "WARNING other.md:" "[S10] a file named on the command line is the file the warning names"
}
fam_diff() { PLX=$1; sizes diff D 65
  # a watched change with an exemption line and the ledger NOT in the diff: the ledger is read, so it warns there too
  mk_case "$(cfg 0.85)" 900; printf 'x\n' > "$PT/src/a.sh"; git_ -C "$PT" add src/a.sh; git_ -C "$PT" commit -q -m "watched"
  git_ -C "$PT" branch -f gwatch HEAD~1
  printf 'NO STATE CHANGE: only an internal value changed\n' > "$F/body-ex.txt"
  OUT=$(kbd check current-state --diff gwatch...HEAD --body-file "$F/body-ex.txt" 2>&1); RC=$?
  eq "$RC" 0 "[D5] a watched change with the exemption, the ledger near its cap but not in the diff: rc 0"
  eq "$(nwarn "$OUT")" 1 "[D6] …and the exempted pass carries the warning once"
  mk_case "$(cfg 0.85)" 100; printf 'x\n' > "$PT/src/a.sh"; git_ -C "$PT" add src/a.sh; git_ -C "$PT" commit -q -m "watched"
  git_ -C "$PT" branch -f gwatch HEAD~1
  OUT=$(kbd check current-state --diff gwatch...HEAD --body-file "$F/body-ex.txt" 2>&1); RC=$?
  eq "$(nwarn "$OUT")" 0 "[D7] the same, the ledger far below the share: no warning"
}
fam_pr() { PLX=$1; sizes pr P 4
  mk_case "$(cfg 0.85)" 900; place pr
  has "$OUT" "900/1000" "[P5] the PR core prints the size and the cap on stderr"
}
fam_hook() { PLX=$1
  local C s o pl; C=$(cfg 0.85)
  expect hook H1 "$C" 849 0 0 "849 of 1000 bytes (one byte below the share)"
  expect hook H2 "$C" 850 1 0 "850 of 1000 bytes (exactly the share)"
  expect hook H3 "$C" 1000 1 0 "1000 of 1000 bytes (at the cap)"
  expect hook H5 "$C" 1001 0 0 "1001 of 1000 bytes (over the cap: the hook never blocks and says nothing about size)"
  mk_case "$C" 900
  s=$(sid); pl=$(p_edit "$s" "$PT/$LED")
  o=$(CLAUDE_PROJECT_DIR="$PT" CLAUDE_PLUGIN_ROOT="$PLX" run_cmds "$PLX/hooks/hooks.json" PreToolUse Edit "$pl")
  eq "$(nwarn "$(ctx "$o")")" 1 "[H6] first edit of the session at 900 bytes: one warning"
  o=$(CLAUDE_PROJECT_DIR="$PT" CLAUDE_PLUGIN_ROOT="$PLX" run_cmds "$PLX/hooks/hooks.json" PreToolUse Edit "$pl")
  eq "$(nwarn "$(ctx "$o")")" 0 "[H7] a second edit at the same size in the same session: silent"
  ledger_of 920 > "$PT/$LED"
  o=$(CLAUDE_PROJECT_DIR="$PT" CLAUDE_PLUGIN_ROOT="$PLX" run_cmds "$PLX/hooks/hooks.json" PreToolUse Edit "$pl")
  eq "$(nwarn "$(ctx "$o")")" 1 "[H8] …but the size moved: the warning is said again"
  has "$(ctx "$o")" "920/1000" "[H9] …with the new size"
  ledger_of 900 > "$PT/src/a.sh"
  o=$(CLAUDE_PROJECT_DIR="$PT" CLAUDE_PLUGIN_ROOT="$PLX" run_cmds "$PLX/hooks/hooks.json" PreToolUse Edit "$(p_edit "$(sid)" "$PT/src/a.sh")")
  eq "$(nwarn "$o")" 0 "[H10] an edit of another file that is itself near the cap: no size warning"
  # the session root is the main tree and the edited ledger is the one of a linked worktree: the file being edited is measured
  # a relative path is read from the hook's own working directory, as the rule lookup does; a symlinked spelling of the same file is one file
  ledger_of 900 > "$PT/$LED"
  o=$(cd "$PT/src" && CLAUDE_PROJECT_DIR="$PT" CLAUDE_PLUGIN_ROOT="$PLX" run_cmds "$PLX/hooks/hooks.json" PreToolUse Edit "$(p_edit "$(sid)" "../kb/current-state.md")")
  eq "$(nwarn "$(ctx "$o")")" 1 "[H14] a relative file_path from another working directory: the ledger is still measured"
  LK=$(fresh); ln -s "$PT" "$LK/pt-link"; s=$(sid)
  o=$(CLAUDE_PROJECT_DIR="$PT" CLAUDE_PLUGIN_ROOT="$PLX" run_cmds "$PLX/hooks/hooks.json" PreToolUse Edit "$(p_edit "$s" "$PT/kb/current-state.md")")
  o2=$(CLAUDE_PROJECT_DIR="$PT" CLAUDE_PLUGIN_ROOT="$PLX" run_cmds "$PLX/hooks/hooks.json" PreToolUse Edit "$(p_edit "$s" "$LK/pt-link/kb/current-state.md")")
  eq "$(nwarn "$(ctx "$o")")$(nwarn "$(ctx "$o2")")" 10 "[H15] the same ledger through a symlinked spelling of the repo in one session: said once"
  mkdir -p "$PW/kb"; printf '# State\n\nShort.\n' > "$PW/$LED"; ledger_of 10300 > "$PT/$LED"
  o=$(CLAUDE_PROJECT_DIR="$PW" CLAUDE_PLUGIN_ROOT="$PLX" run_cmds "$PLX/hooks/hooks.json" PreToolUse Edit "$(p_edit "$(sid)" "$PT/$LED")")
  eq "$(nwarn "$(ctx "$o")")" 1 "[H12] the ledger edited sits in a worktree, the session root is the main tree: the worktree's file is measured"
  ledger_of 10300 > "$PW/$LED"; printf '# State\n\nShort.\n' > "$PT/$LED"
  o=$(CLAUDE_PROJECT_DIR="$PW" CLAUDE_PLUGIN_ROOT="$PLX" run_cmds "$PLX/hooks/hooks.json" PreToolUse Edit "$(p_edit "$(sid)" "$PT/$LED")")
  eq "$(nwarn "$(ctx "$o")")" 0 "[H13] …and the main tree's near-cap ledger is not mistaken for it"
  mk_case "$(python3 - <<'PY'
import json
print(json.dumps({"schema": 1, "hooks": "off", "current_state": {"limits": {"bytes": 1000}}}))
PY
)" 900
  o=$(CLAUDE_PROJECT_DIR="$PT" CLAUDE_PLUGIN_ROOT="$PLX" run_cmds "$PLX/hooks/hooks.json" PreToolUse Edit "$(p_edit "$(sid)" "$PT/$LED")")
  empty "$o" "[H11] hooks off: the hook is silent, the warning included"
}
fam_dims() { PLX=$1
  local C
  C=$(cfg 0.5); expect shape R1 "$C" 499 0 0 "ratio 0.5: 499 of 1000"
  expect shape R2 "$C" 500 1 0 "ratio 0.5: 500 of 1000"
  C=$(cfg 1.0); expect shape R3 "$C" 999 0 0 "ratio 1.0: 999 of 1000 (no warning below the cap)"
  expect shape R3b "$C" 1000 1 0 "ratio 1.0: exactly the cap"
  # the line cap is a cap too: lines of 6 bytes under a cap of 10 lines (48 bytes = 8 lines, 54 = 9, 66 = 11)
  C=$(cfg 0.85 10 100000)
  mk_case "$C" 48 5; place shape; eq "$(nwarn "$OUT")" 0 "[R4a] 8 lines of 10 (80%): no warning"; eq "$RC" 0 "[R4b] …rc 0"
  mk_case "$C" 54 5; place shape; eq "$(nwarn "$OUT")" 1 "[R4] 9 lines of 10 (90%): one warning"; has "$OUT" "9/10 lines" "[R4c] …it names the lines and the line cap"
  mk_case "$C" 66 5; place shape; eq "$RC" 65 "[R4d] 11 lines of 10: the failure is unchanged (rc 65)"; eq "$(nwarn "$OUT")" 0 "[R4e] …and says no warning"
  # both caps near: ONE line, the larger share
  C=$(cfg 0.85 10 100); mk_case "$C" 95 9; place shape
  eq "$(nwarn "$OUT")" 1 "[R5] bytes 95/100 and lines 10/10 both near: one line"
  has "$OUT" "10/10 lines" "[R5b] …the larger share names it"
  # a tie on the floored share: the real ratio decides (995 of 1000 bytes is 99.5%, 99 of 100 lines is 99%)
  C=$(cfg 0.85 100 1000); mk_case "$C" 100
  python3 -c "import sys; sys.stdout.write(('a' * 9 + chr(10)) * 98 + 'a' * 14 + chr(10))" > "$PT/$LED"; git_ -C "$PT" add "$LED"; git_ -C "$PT" commit -q -m ledger2
  place shape; has "$OUT" "995/1000 bytes" "[R9] bytes at 99.5% and lines at 99%: the larger real ratio names the line"
  # no line cap: only the bytes count
  C=$(cfg 0.85 null); mk_case "$C" 900; place shape
  eq "$(nwarn "$OUT")" 1 "[R6] lines: null, 900 of 1000 bytes: one warning"; eq "$RC" 0 "[R6b] …rc 0"
  # no config at all: the ledger preset (12000 bytes, 120 lines) and the default share
  mk_pr_repo; mkdir -p "$PT/kb"; ledger_of 10199 190 > "$PT/$LED"
  place shape; eq "$(nwarn "$OUT")" 0 "[R7] no config, 10199 of 12000 bytes (84.99%): no warning"
  ledger_of 10200 190 > "$PT/$LED"; place shape
  eq "$(nwarn "$OUT")" 1 "[R8] no config, 10200 of 12000 bytes (85%): one warning"; eq "$RC" 0 "[R8b] …rc 0"
}
fam_cfg() { PLX=$1
  local d v rc out
  d=$(fresh); git_ init -q -b main "$d"; mkdir -p "$d/.vibemaestro"
  eq "$(cd "$d" && cenv python3 "$PLX/scripts/sdlc_config.py" get current_state.limits.warn_ratio)" 0.85 "[C1] the default is 0.85"
  eq "$(cd "$d" && cenv python3 "$PLX/scripts/sdlc_config.py" get current_state.limits.bytes)" 12000 "[C1b] …next to the unchanged byte cap"
  for v in 0.5 1 1.0 0.01; do
    printf '{"schema": 1, "current_state": {"limits": {"warn_ratio": %s}}}' "$v" > "$d/.vibemaestro/sdlc.json"
    (cd "$d" && cenv python3 "$PLX/scripts/kb.py" config check >/dev/null 2>&1); eq "$?" 0 "[C2] warn_ratio $v is accepted"
  done
  for v in 0 -0.1 1.5 2 '"x"' true null '"0.85"' '[0.5]'; do
    printf '{"schema": 1, "current_state": {"limits": {"warn_ratio": %s}}}' "$v" > "$d/.vibemaestro/sdlc.json"
    out=$(cd "$d" && cenv python3 "$PLX/scripts/kb.py" config check 2>&1); rc=$?
    eq "$rc" 65 "[C3] warn_ratio $v is refused (rc 65)"
    has "$out" "current_state.limits.warn_ratio" "[C3b] warn_ratio $v: the message names the key"
  done
  printf '{"schema": 1, "current_state": {"template": "map"}}' > "$d/.vibemaestro/sdlc.json"
  eq "$(cd "$d" && cenv python3 "$PLX/scripts/sdlc_config.py" get current_state.limits.warn_ratio)" 0.85 "[C4] the map preset keeps the default share (the preset replaces only the caps it names)"
  eq "$(cd "$d" && cenv python3 "$PLX/scripts/sdlc_config.py" get current_state.limits.bytes)" 28000 "[C4b] …and its own 28000-byte cap"
}

# ── [N] dated labels: `current_state.labels` warns on a label with no date or older than N days, never blocks ─────────
LBL='\\*chưa kiểm(?: từ (?P<date>[^*]*))?\\*'
# lcfg [regex] [max_age_days] — a config watching src/ whose labels are on (the default regex above, N = 7)
lcfg() { printf '{"schema": 1, "current_state": {"watch": ["src/"], "labels": {"regex": "%s", "max_age_days": %s}}}' "${1:-$LBL}" "${2:-7}"; }
day() { python3 -c "import datetime, sys; print(datetime.date.today() + datetime.timedelta(days=int(sys.argv[1])))" "$1"; }
# lcase <config> <ledger text> — mk_case, then the branch's ledger is <ledger text>
lcase() { mk_case "$1" 100; printf '%s' "$2" > "$PT/$LED"; git_ -C "$PT" add "$LED"; git_ -C "$PT" commit -q -m labels; }
nlab() { printf '%s\n' "$1" | grep -cE -- 'WARNING kb/current-state.md:[0-9]+: label' || true; }
fam_labels() { PLX=$1
  local C t0 secs o1 o2
  C=$(lcfg)
  lcase "$C" "$(printf '# State\n\nA runs *chưa kiểm*.\n')"; place shape
  eq "$(nlab "$OUT")" 1 "[N1] a label with no date: one WARNING"; eq "$RC" 0 "[N1b] …rc 0"; has "$OUT" "kb/current-state.md:3: label" "[N1c] …it names the line"
  place diff; eq "$(nlab "$OUT")" 1 "[N1d] the diff gate: the same WARNING"; eq "$RC" 0 "[N1e] …and it passes (warning only)"
  lcase "$C" "$(printf '# State\n\nA runs *chưa kiểm từ %s*.\n' "$(day -8)")"; place shape
  eq "$(nlab "$OUT")" 1 "[N2] a label 8 days old, N = 7: one WARNING"; eq "$RC" 0 "[N2b] …rc 0"; has "$OUT" "8 days old (over 7)" "[N2c] …it names the age and N"
  place diff; eq "$(nlab "$OUT")$RC" 10 "[N2d] the diff gate: the WARNING and rc 0"
  lcase "$C" "$(printf '# State\n\nA runs *chưa kiểm từ %s*.\nB runs *chưa kiểm từ %s*.\n' "$(day -7)" "$(day 0)")"; place shape
  eq "$(nlab "$OUT")" 0 "[N3] labels 7 days old and from today, N = 7: no WARNING"; eq "$RC" 0 "[N3b] …rc 0"
  lcase "$C" "$(printf '# State\n\nA runs *chưa kiểm từ %s*.\n' "$(day 2)")"; place shape
  eq "$(nlab "$OUT")" 1 "[N4] a label dated the day after tomorrow: one WARNING"; has "$OUT" "after tomorrow" "[N4c] …saying so"
  lcase "$C" "$(printf '# State\n\nA runs *chưa kiểm từ %s*.\n' "$(day 1)")"; place shape
  eq "$(nlab "$OUT")" 0 "[N4b] a label dated tomorrow (time zones): no WARNING"
  lcase "$C" "$(printf '# State\n\nA runs *chưa kiểm từ 2026-02-30*.\nB *chưa kiểm từ 2026-10- 5*.\n')"; place shape
  eq "$(nlab "$OUT")" 2 "[N5] 2026-02-30 and 2026-10- 5 are no date: two WARNINGs"; eq "$RC" 0 "[N5b] …rc 0 (the shape-only date is not history)"
  has "$OUT" ":3: label '*chưa kiểm từ 2026-02-30*' has no valid date" "[N5c] …February 30 is not a day"
  has "$OUT" ":4: label '*chưa kiểm từ 2026-10- 5*' has no valid date" "[N5d] …and a day with a blank is not YYYY-MM-DD (int() would read it)"
  lcase "$(lcfg "$LBL" 3)" "$(printf '# State\n\nA runs *chưa kiểm từ %s*.\n' "$(day -4)")"; place shape
  eq "$(nlab "$OUT")" 1 "[N8] max_age_days 3: a label 4 days old warns"
  lcase "$C" "$(printf '# State\n\nA *chưa kiểm* and B *chưa kiểm từ %s*.\n' "$(day -30)")"; place shape
  eq "$(nlab "$OUT")" 2 "[N9] two labels on one line: two WARNINGs"
  # a catastrophic regex (nested quantifiers, no `y` on the line): the timer cuts it, the check still passes
  lcase "$(lcfg '(x+x+)+y(?P<date>[0-9-]*)')" "$(printf '# State\n\n%s runs.\n' "$(python3 -c "print('x' * 40)")")"
  t0=$(date +%s); place shape; secs=$(( $(date +%s) - t0 ))
  [ "$secs" -lt 10 ] && ok "[N6] a runaway regex: the check returns in ${secs}s (under 10)" || bad "[N6] a runaway regex: the check took ${secs}s"
  eq "$RC" 0 "[N6b] …rc 0"; has "$OUT" "current_state.labels regex ran over 2 s" "[N6c] …and says the labels were not checked"
  lcase "$(lcfg '(?<=\\s)(?P<date>)')" "$(printf '# State\n\nA b c d e f.\n')"; place shape
  eq "$(nlab "$OUT")$RC" 00 "[N10] an empty match at every blank is no label: no WARNING flood, rc 0"
  # no labels: exactly today's output
  lcase "$(printf '{"schema": 1, "current_state": {"watch": ["src/"]}}')" "$(printf '# State\n\nA runs *chưa kiểm*.\n')"; place shape; o1=$OUT
  eq "$(nlab "$OUT")$RC" 00 "[N7] no labels key: no label WARNING, rc 0"
  lcase "$(printf '{"schema": 1, "current_state": {"watch": ["src/"], "labels": null}}')" "$(printf '# State\n\nA runs *chưa kiểm*.\n')"; place shape; o2=$OUT
  eq "$o1" "$o2" "[N7b] …and the output is the output of labels: null"
}

FAMILIES="fam_shape fam_diff fam_pr fam_hook fam_dims fam_cfg fam_labels"
for f in $FAMILIES; do echo "-- $f"; "$f" "$PLUGIN"; done

# ── each planted break must turn its family red ─────────────────────────────────────────────────
BRK() {  # BRK <label> <family> <needle> <file under scripts/> <old> <new>
  local d="$TMP/break-$1"; mk_plugin_copy "$d"
  mutate "$d/scripts/$4" "$5" "$6" && expect_red "$1" "$2" "$d" "$3"
}
echo "-- control: the warning code removed"
# the shared function: removing it turns every place red
FN_OLD='    if not near:
        return None
'
FN_NEW='    return None
'
BRK function-removed-shape fam_shape '[S2]' current_state.py "$FN_OLD" "$FN_NEW"
BRK function-removed-diff fam_diff '[D2]' current_state.py "$FN_OLD" "$FN_NEW"
BRK function-removed-pr fam_pr '[P2]' current_state.py "$FN_OLD" "$FN_NEW"
BRK function-removed-hook fam_hook '[H2]' current_state.py "$FN_OLD" "$FN_NEW"
# the call in ONE place
BRK call-removed-shape fam_shape '[S2]' kb.py '    warn = current_state.size_warning(raw, profile, rel)' '    warn = None'
BRK call-removed-diff fam_diff '[D2]' current_state.py '    warns = ledger_warnings(root, p, ledger)' '    warns = []'
BRK call-removed-pr fam_pr '[P2]' current_state.py '    warns = ledger_warnings(root, p, ledger)' '    warns = []'
BRK call-removed-hook fam_hook '[H2]' vsdlc.py '        note = _size_note(troot, cfg, rel, sid, os.path.abspath(ti.get("file_path") or ti.get("notebook_path") or ""))' '        note = None'
# the other places stay green when ONE call goes: the break above must not hide behind a broken fixture of the others
echo "-- control: a break of one call leaves the other places green"
CALL_BREAK="$TMP/break-only-hook"; mk_plugin_copy "$CALL_BREAK"
mutate "$CALL_BREAK/scripts/vsdlc.py" '        note = _size_note(troot, cfg, rel, sid, os.path.abspath(ti.get("file_path") or ti.get("notebook_path") or ""))' '        note = None' || true
sp=$PASS; sf=$FAIL; QN=0
okdef=$(declare -f ok); baddef=$(declare -f bad)
ok() { :; }; bad() { QN=$((QN+1)); }
for f in fam_shape fam_diff fam_pr; do "$f" "$CALL_BREAK" >/dev/null 2>&1; done
eval "$okdef"; eval "$baddef"; PASS=$sp; FAIL=$sf
eq "$QN" 0 "the hook call removed: the shape check, the diff gate and the PR core still pass their families"
# the edges and the key
BRK edge-exclusive fam_shape '[S2]' current_state.py '    near = [(n / cap, what, n, cap) for what, n, cap in dims if n / cap >= ratio]' '    near = [(n / cap, what, n, cap) for what, n, cap in dims if n / cap > ratio]'
BRK tie-by-floor fam_dims '[R9]' current_state.py '    near = [(n / cap, what, n, cap) for what, n, cap in dims if n / cap >= ratio]' '    near = [(n * 100 // cap, what, n, cap) for what, n, cap in dims if n / cap >= ratio]'
BRK explicit-name-lost fam_shape '[S10]' kb.py '    warn = current_state.size_warning(raw, profile, rel)' '    warn = current_state.size_warning(raw, profile)'
BRK hook-guard-removed fam_hook '[H10]' vsdlc.py '        elif rel == profile["path"]:
            name = None
        else:
            return None
' '        else:
            name = None
'
BRK hook-relative-path-from-root fam_hook '[H14]' vsdlc.py 'os.path.abspath(ti.get("file_path") or ti.get("notebook_path") or "")' 'os.path.abspath(os.path.join(troot, ti.get("file_path") or ""))'
BRK hook-once-per-spelling fam_hook '[H15]' vsdlc.py 'once("size:%s:%d" % (os.path.realpath(path), len(raw)), sid)' 'once("size:%s:%d" % (path, len(raw)), sid)'
BRK hook-reads-session-root fam_hook '[H12]' vsdlc.py '        with open(path, "rb") as f:' '        with open(os.path.join(troot, *rel.split("/")), "rb") as f:'
BRK ratio-hardcoded fam_dims '[R2]' current_state.py 'if n / cap >= ratio]' 'if n / cap >= 0.85]'
BRK over-cap-warns fam_hook '[H5]' current_state.py '    if ratio is None or any(n > cap for _name, n, cap in dims):' '    if ratio is None:'
BRK lines-cap-dropped fam_dims '[R4]' current_state.py '    if lim["lines"] is not None:
        dims.append(' '    if False:
        dims.append('
BRK lines-null-crashes fam_dims '[R6]' current_state.py '    if lim["lines"] is not None:
        dims.append(("lines", len(lines), lim["lines"]))' '    dims.append(("lines", len(lines), lim["lines"] or 0))'
BRK two-lines-printed fam_dims '[R5b]' current_state.py '    _share, what, n, cap = max(near)' '    _share, what, n, cap = near[0]'
BRK ratio-not-validated fam_cfg '[C3]' sdlc_config.py '        if not _is_num(v) or not 0 < v <= 1:' '        if False:'
BRK ratio-above-one-accepted fam_cfg '[C3]' sdlc_config.py 'or not 0 < v <= 1:' 'or not 0 < v:'
BRK default-moved fam_cfg '[C1]' sdlc_config.py '"line_chars": 200, "warn_ratio": 0.85}' '"line_chars": 200, "warn_ratio": 0.5}'

# the dated labels: each break turns its [N] case red
BRK label-no-date-silent fam_labels '[N1]' current_state.py '        if day is None:' '        if False:'
BRK label-shape-call-dropped fam_labels '[N1]' kb.py '    for w in current_state.label_warnings(raw, profile, rel):' '    for w in []:'
BRK label-diff-call-dropped fam_labels '[N1d]' current_state.py '    return ([w] if w else []) + label_warnings(text, profile, name, today)' '    return [w] if w else []'
BRK label-age-ignored fam_labels '[N2]' current_state.py '        elif age > n:' '        elif False:'
BRK label-age-off-by-one fam_labels '[N3]' current_state.py '        elif age > n:' '        elif age >= n:'
BRK label-future-silent fam_labels '[N4]' current_state.py '        elif age < -1:' '        elif False:'
BRK label-future-no-slack fam_labels '[N4b]' current_state.py '        elif age < -1:' '        elif age < 0:'
BRK label-bad-day-read fam_labels '[N5c]' current_state.py '    except ValueError:
        return None' '    except ValueError:
        return datetime.date(2000, 1, 1)'
BRK label-shape-unchecked fam_labels '[N5d]' current_state.py '    if s is None or not _ISO_SHAPE.fullmatch(s):' '    if s is None:'
BRK label-max-age-hardcoded fam_labels '[N8]' current_state.py '    n = p["labels"]["max_age_days"]' '    n = 7'
BRK label-one-per-line fam_labels '[N9]' current_state.py '            for m in rx.finditer(ln):' '            for m in filter(None, [rx.search(ln)]):'
BRK label-timer-too-long fam_labels '[N6]' current_state.py 'LABEL_SECONDS = 2' 'LABEL_SECONDS = 11'
BRK label-empty-match-is-label fam_labels '[N10]' current_state.py '                if any(c.isalpha() for c in ln[m.start():s] + ln[e:m.end()]):' '                if True:'
BRK labels-on-by-default fam_labels '[N7]' sdlc_config.py '        "labels": None,' '        "labels": {"regex": "\\*chưa kiểm(?: từ (?P<date>[^*]*))?\\*", "max_age_days": 7},'

PLC="$TMP/break-none"; mk_plugin_copy "$PLC"
QN=0; okdef=$(declare -f ok); baddef=$(declare -f bad); sp=$PASS; sf=$FAIL
ok() { :; }; bad() { QN=$((QN+1)); }
for f in $FAMILIES; do "$f" "$PLC" >/dev/null 2>&1; done
eval "$okdef"; eval "$baddef"; PASS=$sp; FAIL=$sf
eq "$QN" 0 "control: an unbroken copy passes every family (no failed check)"

echo; summary
