#!/bin/bash
# =============================================================================
# BatonRun: the baton runner (scripts/baton.py), its template, and the reminder rule for privileged commands
# =============================================================================
# Run: bash tests/test-baton.sh
#
# Every acceptance item of the baton runner is a FAMILY
# `fam_<x> <plugin dir>` with a positive case and a planted case in the baton script (a missing undo, an edit after signing, ...).
# The suite runs every family on a copy of the real plugin, then each family again on a copy with ONE planted break in baton.py
# (expect_red, tests/fixtures/ports.sh) and requires red on the intended check, so a check that cannot fail is caught.
# The state directory is XDG_STATE_HOME inside the scratch tree, HOME is the scratch home (clean_env); nothing is written
# outside the scratch tree, which the last section checks. No network, no `sleep` (fam_wait waits on baton's own clock, a few s). Assertions read exit codes, files and the
# PLAN/VERDICT lines of the protocol; prose is asserted only in section [text]: one key phrase per owner decision.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
# shellcheck source=fixtures/ports.sh
. "$HERE/fixtures/ports.sh"
# shellcheck source=fixtures/baton-owner.sh
. "$HERE/fixtures/baton-owner.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT    # an input copy is read-only (0400 in a 0500 directory)
clean_env "$TMP"
export PYTHONDONTWRITEBYTECODE=1
H0=$(tree_hash "$SRC_ROOT")
# tree_files <dir> — one "sha1  path" line per file (the same walk as tree_hash): on a changed tree, the files that changed
tree_files() { (cd "$1" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 sha1sum); }
tree_files "$SRC_ROOT" > "$TMP/tree-before.lst"
BT_OUT="$TMP/bt.out"
ST=""

# bt <plugin> <dir> <baton args...> — rc of baton run from <dir> with the state in $ST (plus BT_ENV) as session OWNER_SID; its
# output is in $BT_OUT. A `sign --by owner` first goes through the plugin's guard hook (owner_asked), as in a session whose owner
# clicks the dialog; fam_owner_dialog tests the record itself. BT_PRE, when set, is a command baton runs under (HUP_DFL below).
BT_ENV=(); BT_PRE=(); OWNER_SID=s-owner
# HUP_DFL — runs its arguments with SIGHUP at its default. A check that stops baton with SIGHUP uses it: baton keeps a SIGHUP its parent
# ignored (nohup), so without it the check would test the parent shell, not baton.
HUP_DFL=(python3 -c 'import os, signal, sys
signal.signal(signal.SIGHUP, signal.SIG_DFL)
os.execvp(sys.argv[1], sys.argv[1:])')
bt() {
  local p=$1 d=$2; shift 2
  [ "${1:-} ${2:-} ${3:-}" = "sign --by owner" ] && owner_asked "$p" "$d" "$ST" "$OWNER_SID" "${@:2}" >/dev/null
  [ "${1:-}" = mode ] && [ $# -gt 1 ] && mode_asked "$p" "$d" "$ST" "$OWNER_SID" "${@:2}" >/dev/null
  ( cd "$d" && cenv XDG_STATE_HOME="$ST" CLAUDE_CODE_SESSION_ID="$OWNER_SID" ${BT_ENV[@]+"${BT_ENV[@]}"} ${BT_PRE[@]+"${BT_PRE[@]}"} \
      python3 "$p/scripts/baton.py" "$@" ) > "$BT_OUT" 2>&1; echo $?
}
# seal_for <plugin> <dir> <script> [args...] — the seal that rehearse prints (empty when rehearse fails)
seal_for() {
  local p=$1 d=$2; shift 2
  ( cd "$d" && cenv XDG_STATE_HOME="$ST" ${BT_ENV[@]+"${BT_ENV[@]}"} python3 "$p/scripts/baton.py" rehearse "$@" ) 2>/dev/null \
    | sed -n 's/^seal \([^ ]*\) .*/\1/p'
}
# sg <plugin> <dir> <signer> <script> [args...] — rehearse to read the seal, then sign with it; prints the rc of sign
sg() { local p=$1 d=$2 by=$3 seal; shift 3; seal=$(seal_for "$p" "$d" "$@"); bt "$p" "$d" sign --by "$by" --seal "${seal:-none}" "$@"; }
# fresh_state — a new empty state directory for this family run (families run once per plugin copy)
fresh_state() { ST="$(fresh)/state"; }
# act_in <plugin> <dir> — the template written by `baton new act` into <dir>; prints its path
# act_in <plugin> <dir> — a positional baton (no Params: <file> <text>), the shape most families exercise; the template `new`
# writes declares Params and is run in fam_new
act_in() { cp "$SRC_ROOT/tests/fixtures/baton-positional.sh" "$2/act.sh"; printf '%s' "$2/act.sh"; }
POSTCHECK_OK=$'postcheck() {\n  holds_text\n}'; POSTCHECK_NO=$'postcheck() {\n  false\n}'
# in_act <script> <line> — plant one line at the top of the act
in_act() { mutate "$1" $'act() {\n' $'act() {\n  '"$2"$'\n'; }
# within <seconds> <command...> — the command's rc, or "timeout" when it runs longer (portable: no coreutils timeout)
within() {
  python3 -c 'import subprocess, sys
try:
    print(subprocess.run(sys.argv[2:], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=float(sys.argv[1])).returncode)
except subprocess.TimeoutExpired:
    print("timeout")' "$@"
}
# `docker` is spelled through $DK (for the deleted suite-independence suite; harmless to keep)
DK='dock''er'
# baton_dir — the state directory baton uses under $ST
baton_dir() { printf '%s' "$ST/vibemaestro/baton"; }
nsig() { find "$(baton_dir)/signatures" -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
lastlog() { tail -n 1 "$(baton_dir)/log.tsv" 2>/dev/null; }
# logcol <n> — column n (1-based) of the last log line
logcol() { lastlog | cut -f "$1"; }

# ── new and the template ────────────────────────────────────────────────────────────────────────────────────────────────────────
fam_new() {
  local P=$1 W; fresh_state; W=$(fresh)
  eq "$(bt "$P" "$W" new demo --dir "$W")" 0 "[new] writes the template: rc 0"
  [ -f "$W/demo.sh" ] && ok "[new] demo.sh exists" || bad "[new] demo.sh exists"
  hasnt "$(cat "$W/demo.sh")" "__NAME__" "[new] the name is substituted"
  echo keep > "$W/keep.sh"
  eq "$(bt "$P" "$W" new keep --dir "$W")" 6 "[new] an existing file: rc 6"
  eq "$(cat "$W/keep.sh")" keep "[new] an existing file is not overwritten"
  eq "$(bt "$P" "$W" new Bad_Name --dir "$W")" 64 "[new] a name outside [a-z0-9-]: rc 64"
  eq "$(bt "$P" "$W" check "$W/demo.sh")" 0 "[new] the template passes check as generated"
  eq "$(bash -n "$W/demo.sh"; echo $?)" 0 "[new] the template is valid bash"
  printf 'hi\n' > "$W/body.txt"; bt "$P" "$W" mode auto >/dev/null
  eq "$(bt "$P" "$W" go "$W/demo.sh" dest="$W/out.txt" body="$W/body.txt")/$(cat "$W/out.txt" 2>/dev/null)" "0/hi" \
     "[new] the template runs with its Params: the file holds the input's bytes"
  eq "$(bt "$P" "$W" go "$W/demo.sh" "$W/o2.txt" hi)" 64 "[new] …a positional call does not fit its Params: rc 64"
  eq "$(bt "$P" "$W" pack "$W/demo.sh" user:demo-put)" 0 "[new] …and it can be kept as generated: pack rc 0"
}

# ── check ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
fam_check_header() {
  local P=$1 W A; fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  eq "$(bt "$P" "$W" check "$A")" 0 "[check-header] control: the template passes"
  cp "$A" "$W/b.sh"; mutate "$W/b.sh" '# Undo: ' '# Undone: '
  eq "$(bt "$P" "$W" check "$W/b.sh")" 1 "[check-header] no Undo field: rc 1"
  cp "$A" "$W/c.sh"; mutate "$W/c.sh" '# Expect: create *' '# Expect:'
  eq "$(bt "$P" "$W" check "$W/c.sh")" 1 "[check-header] an empty Expect: rc 1"
  cp "$A" "$W/d.sh"; mutate "$W/d.sh" '# Stops: none' '# Stops: dangerous'
  eq "$(bt "$P" "$W" check "$W/d.sh")" 1 "[check-header] a stop word outside the vocabulary: rc 1"
}
fam_check_rehearse_path() {
  local P=$1 W A; fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  mutate "$A" $'  rehearse)\n    act\n    echo "VERDICT rehearse ok"\n    ;;\n' ''
  eq "$(bt "$P" "$W" check "$A")" 1 "[check-rehearse-path] no rehearse branch in the dispatch: rc 1"
}
fam_check_undo() {
  local P=$1 W A; fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  mutate "$A" 'undo() {' 'undo_gone() {'
  eq "$(bash -n "$A"; echo $?)" 0 "[check-undo] instrument: the planted script is still valid bash"
  eq "$(bt "$P" "$W" check "$A")" 1 "[check-undo] no undo() function: rc 1"
}
fam_check_syntax() {
  local P=$1 W A; fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  in_act "$A" 'if [ -n "$DEST" ]; then'
  ne "$(bash -n "$A" 2>/dev/null; echo $?)" 0 "[check-syntax] instrument: the planted script is invalid bash"
  eq "$(bt "$P" "$W" check "$A")" 1 "[check-syntax] a syntax error: rc 1"
}
# pipe_case <plugin> <dir> <template> <want rc> <label> <line>
pipe_case() {
  local P=$1 W=$2 A=$3 f; f="$W/p$RANDOM$RANDOM.sh"; cp "$A" "$f"; in_act "$f" "$6"
  eq "$(bt "$P" "$W" check "$f")" "$4" "[check-pipefail] $5: rc $4"
}
fam_check_pipefail() {
  local P=$1 W A; fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  pipe_case "$P" "$W" "$A" 1 "unguarded diff | head (the original bug)" 'diff -u /dev/null /dev/null | head -1'
  pipe_case "$P" "$W" "$A" 1 "unguarded grep in an assignment" 'n=$(grep -c x /dev/null | head -1)'
  pipe_case "$P" "$W" "$A" 1 "unguarded cmp, split over two lines" $'cmp /dev/null /dev/null |\n    cat'
  pipe_case "$P" "$W" "$A" 1 "a one-line function body" 'differs() { diff -u /dev/null /dev/null | head -40; }'
  pipe_case "$P" "$W" "$A" 1 "behind env and timeout" 'env LC_ALL=C timeout 5 grep -c x /dev/null | head -1'
  pipe_case "$P" "$W" "$A" 1 "a group that is not one guarded command" '{ diff /dev/null /dev/null | head -3; echo done || true; }'
  pipe_case "$P" "$W" "$A" 0 "guarded { diff || true; } | head" '{ diff -u /dev/null /dev/null || true; } | head -1'
  pipe_case "$P" "$W" "$A" 0 "a pipeline as an if condition" 'if diff /dev/null /dev/null | grep -q x; then :; fi'
  pipe_case "$P" "$W" "$A" 0 "a pipeline ending in || true" 'diff /dev/null /dev/null | head -1 || true'
  pipe_case "$P" "$W" "$A" 0 "a pipe inside a quoted pattern" 'grep -c "a|b" /dev/null || true'
}
fam_check_fidelity() {
  local P=$1 W A f; fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  f="$W/f1.sh"; cp "$A" "$f"; in_act "$f" 'if [ "$PHASE" = run ]; then :; fi'
  eq "$(bt "$P" "$W" check "$f")" 1 "[check-fidelity] the phase tested outside write(): rc 1"
  f="$W/f2.sh"; cp "$A" "$f"; in_act "$f" 'printenv BATON_PHASE >/dev/null || true'
  eq "$(bt "$P" "$W" check "$f")" 1 "[check-fidelity] BATON_PHASE read a second time: rc 1"
  f="$W/f3.sh"; cp "$A" "$f"; mutate "$f" 'PHASE=${BATON_PHASE:-rehearse}' 'PHASE=${BATON_PHASE:-run}'
  eq "$(bt "$P" "$W" check "$f")" 1 "[check-fidelity] a default phase other than rehearse: rc 1"
  f="$W/f4.sh"; cp "$A" "$f"
  mutate "$f" $'  rehearse)\n    act\n' $'  rehearse)\n    write "create $DEST" true\n'
  eq "$(bt "$P" "$W" check "$f")" 1 "[check-fidelity] the rehearse) and run) branches differ: rc 1"
  f="$W/f5.sh"; cp "$A" "$f"; in_act "$f" 'printf "PLAN create %s\n" "$DEST"'
  eq "$(bt "$P" "$W" check "$f")" 1 "[check-fidelity] a PLAN line printed outside write(): rc 1"
}
fam_check_gate() {
  local P=$1 W A f; fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  f="$W/g1.sh"; cp "$A" "$f"; mutate "$f" $'    rehearse)\n      printf \'PLAN %s\\n\' "$plan"\n' $'    rehearse)\n      printf \'PLAN %s\\n\' "$plan"\n      "$@"\n'
  eq "$(bt "$P" "$W" check "$f")" 1 "[check-gate] a write() that also executes in rehearse: rc 1"
  f="$W/g2.sh"; cp "$A" "$f"
  mutate "$f" $'  rehearse)\n    act\n' $'  rehearse)\n    act || true\n'; mutate "$f" $'  run)\n    act\n' $'  run)\n    act || true\n'
  eq "$(bt "$P" "$W" check "$f")" 1 "[check-gate] both branches run 'act || true' (a failed write would not stop): rc 1"
  f="$W/g3.sh"; cp "$A" "$f"
  mutate "$f" '    echo "VERDICT rehearse ok"' '    printf "VERDICT rehearse ok\n"'; mutate "$f" '    echo "VERDICT run ok"' '    printf "VERDICT run ok\n"'
  eq "$(bt "$P" "$W" check "$f")" 0 "[check-gate] control: printf verdicts in both branches are the same branch: rc 0"
}
fam_check_unwrapped() {
  local P=$1 W A f; fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  f="$W/u1.sh"; cp "$A" "$f"; in_act "$f" 'gh pr merge 12 --squash'
  eq "$(bt "$P" "$W" check "$f")" 1 "[check-unwrapped] a privileged command outside write(): rc 1"
  f="$W/u2.sh"; cp "$A" "$f"; in_act "$f" 'git -C "$PWD" push origin feat/x'
  eq "$(bt "$P" "$W" check "$f")" 1 "[check-unwrapped] git -C <dir> push outside write(): rc 1"
  f="$W/u3.sh"; cp "$A" "$f"; in_act "$f" 'put_text'
  eq "$(bt "$P" "$W" check "$f")" 1 "[check-unwrapped] a helper used through write() called without it: rc 1"
  f="$W/u4.sh"; cp "$A" "$f"; in_act "$f" 'write "merge 12" gh pr merge 12 --squash'
  eq "$(bt "$P" "$W" check "$f")" 0 "[check-unwrapped] control: the same command through write(): rc 0"
  f="$W/u5.sh"; cp "$A" "$f"; in_act "$f" "echo 'gh pr merge 12 is planned'"
  eq "$(bt "$P" "$W" check "$f")" 0 "[check-unwrapped] control: the words inside a quoted string: rc 0"
  f="$W/u6.sh"; cp "$A" "$f"; in_act "$f" 'state=$(gh pr view 12 --json state -q .state); write "merge 12" gh pr merge 12 --squash'
  eq "$(bt "$P" "$W" check "$f")" 0 "[check-unwrapped] reading and writing with the same tool (gh view, write gh merge): rc 0"
  f="$W/u7.sh"; cp "$A" "$f"; in_act "$f" 'rm -f "$DEST.tmp"'
  eq "$(bt "$P" "$W" check "$f")" 0 "[check-unwrapped] a bare rm next to the template's write rm: rc 0"
  f="$W/u8.sh"; cp "$A" "$f"; in_act "$f" 'write "create at $(date -u +%Y)" put_text'
  eq "$(bt "$P" "$W" check "$f")" 0 "[check-unwrapped] a helper through write() with a \$(…) plan line: rc 0"
  f="$W/u9.sh"; cp "$A" "$f"; in_act "$f" 'git push --dry-run origin HEAD; gh pr create --dry-run --title x; kubectl auth can-i create pods; helm upgrade --install --dry-run x y; kubectl apply --dry-run=server -f a.yaml'
  eq "$(bt "$P" "$W" check "$f")" 0 "[check-unwrapped] dry runs and auth can-i are reads: rc 0"
  f="$W/u10.sh"; cp "$A" "$f"; in_act "$f" "gh api -X 'POST' repos/acme/app/issues"
  eq "$(bt "$P" "$W" check "$f")" 1 "[check-unwrapped] a quoted method outside write(): rc 1"
  f="$W/u11.sh"; cp "$A" "$f"; in_act "$f" 'gh workflow run deploy.yml'
  eq "$(bt "$P" "$W" check "$f")" 1 "[check-unwrapped] gh workflow run outside write(): rc 1"
  f="$W/u12.sh"; cp "$A" "$f"; in_act "$f" "write \"x\" $DK $(printf -- '--tlsverify=true %.0s' $(seq 1 2000))push a"
  eq "$(within 10 env XDG_STATE_HOME="$ST" python3 "$P/scripts/baton.py" check "$f")" 0 \
     "[check-unwrapped] a line with 2000 options is checked in well under 10 s"
  f="$W/u13.sh"; cp "$A" "$f"; in_act "$f" "git $(printf -- '--work-tree %.0s' $(seq 1 2000))status"
  eq "$(within 10 env XDG_STATE_HOME="$ST" python3 "$P/scripts/baton.py" check "$f")" 0 \
     "[check-unwrapped] a git line with 2000 global options is checked in well under 10 s"
}
fam_check_round3() {
  local P=$1 W A f c
  fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  r3() {  # r3 <want rc> <label> <line planted at the top of the act>
    f="$W/r3-$RANDOM$RANDOM.sh"; cp "$A" "$f"; in_act "$f" "$3"
    eq "$(bt "$P" "$W" check "$f")" "$1" "[check-round3] $2: rc $1"
  }
  r3 1 "a write inside local x=\$(…)" 'local url=$(gh pr create --title t --body b)'
  r3 1 "a write inside \"\$(…)\"" 'echo "$(gh pr merge 12)"'
  r3 1 "a write in backticks" 'x=`gh pr merge 12`'
  r3 1 "a write with a path prefix" '/usr/bin/gh pr merge 12'
  r3 1 "a write behind xargs -I %" 'echo 1 | xargs -I % gh pr merge %'
  r3 1 "a write after !" '! gh pr merge 12'
  r3 1 "a local script inside \$(…)" 'out=$(./helper)'
  r3 1 "a local script in a subshell" '(./helper)'
  r3 1 "a quoted --dry-run is not a dry run" 'gh pr create --title "add --dry-run flag" --body x'
  r3 1 "--dry-run=false is not a dry run" 'gh pr create --dry-run=false --title x'
  r3 1 "gh api -ftitle outside write()" 'gh api repos/acme/app/issues -ftitle=x'
  r3 1 "a graphql mutation outside write()" "gh api graphql -f query='mutation { x }'"
  r3 1 "gh pr update-branch outside write()" 'gh pr update-branch 12'
  r3 1 "a quoted DELETE under Stops none" "write \"del\" gh api -X 'DELETE' repos/acme/x"
  r3 0 "gh repo set-default is not a write" 'gh repo set-default acme/app'
  r3 0 "a helper whose plan line holds \$(…) with nested quotes" 'merge_it() { gh pr merge "$1" --squash; }; write "merge $(printf "%s" 12)" merge_it 12'
  f="$W/dk.sh"; cp "$A" "$f"; in_act "$f" "$DK $(printf -- '--tlsverify=true %.0s' $(seq 1 2000))ps"
  eq "$(within 10 env XDG_STATE_HOME="$ST" python3 "$P/scripts/baton.py" check "$f")" 0 \
     "[check-round3] a bare line with 2000 options (outside write) is checked in well under 10 s"
  f="$W/nl1.sh"; cp "$A" "$f"; in_act "$f" 'printf "no newline before the plan line"'
  eq "$(bt "$P" "$W" rehearse "$f" "$W/o.txt" hi)" 0 "[check-round3] output without a final newline before a write: the plan still reads"
  f="$W/nl2.sh"; cp "$A" "$f"; mutate "$f" $'  write "create $DEST" put_text\n}' $'  write "create $DEST" put_text\n  printf "no newline before the verdict"\n}'
  eq "$(bt "$P" "$W" rehearse "$f" "$W/o.txt" hi)" 0 "[check-round3] output without a final newline before the verdict: the verdict still reads"
  if c=$(printf 'caf\351'); [ -n "$c" ] && mkdir "$W/$c" 2>/dev/null; then
    eq "$(bt "$P" "$W" rehearse "$A" "$W/$c/o.txt" hi)" 0 "[check-round3] a plan line with a non-UTF-8 byte: rehearse rc 0"
  else ok "[check-round3] (this filesystem refuses a non-UTF-8 name: case not run)"; fi
}
fam_check_round4() {
  local P=$1 W A f
  fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  r4() {  # r4 <want rc> <label> <line planted at the top of the act>
    f="$W/r4-$RANDOM$RANDOM.sh"; cp "$A" "$f"; in_act "$f" "$3"
    eq "$(bt "$P" "$W" check "$f")" "$1" "[check-round4] $2: rc $1"
  }
  r4 1 "gh api with a substitution in its path, then -f" 'gh api "repos/$(echo acme/app)/issues" -f title=x'
  r4 1 "git -C \"\$(pwd)\" push" 'git -C "$(pwd)" push origin x'
  r4 1 "kubectl -n \"\$(…)\" delete" 'kubectl -n "$(echo ns)" delete pod x'
  r4 1 "a build that pushes, after a substitution" "$DK build -t \"\$(echo x)\" --push ."
  r4 0 "a dry run after a substitution (kubectl)" 'kubectl apply -f "$(mktemp)" --dry-run=server'
  r4 0 "a dry run after a substitution (git push)" 'git push origin "$(git branch --show-current)" --dry-run'
  r4 0 "a case pattern ./*) is not a local script" 'case "$DEST" in ./*) echo rel ;; *) : ;; esac'
  r4 0 "a case pattern \$HOME/*) is not a local script" 'case "$DEST" in $HOME/*) echo home ;; *) : ;; esac'
  r4 0 "array elements are not local scripts" 'files=("$DEST/a" "$DEST/b")'
  r4 0 "a word after a process substitution is not a command" 'cat <(printf x) ./notes >/dev/null || true'
  r4 1 "xargs -i keeps the command" 'echo 1 | xargs -i gh pr merge {}'
  r4 1 "xargs -l keeps the command" 'echo 1 | xargs -l gh pr merge'
  r4 1 "source after a (a) case label" 'case $1 in (a) source ./x.sh;; esac'
  r4 1 "pipefail after a (a|b) case label" 'case $1 in (a|b) grep a b | head;; esac'
  r4 1 "a write after a (a) case label" 'case $1 in (a) gh pr merge 12;; esac'
  r4 1 "a write in backticks inside double quotes" 'echo "`gh pr merge 12`"'
  r4 1 "a write in backticks inside an assignment's quotes" 'x="`gh pr merge 12`"'
  f="$W/pp.sh"; cp "$A" "$f"; in_act "$f" "$(printf 'kubectl/%.0s' $(seq 1 12000)) x"
  eq "$(within 3 env XDG_STATE_HOME="$ST" python3 "$P/scripts/baton.py" check "$f")" 0 \
     "[check-round4] a 12000-segment path prefix is checked in under 3 s (a prefix in the regex took about 8 s)"
}
fam_run_after_use() {
  local P=$1 W A
  fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  # after() <how> — run the signed act with log_event patched: <how> happens when the run's log line is about to be written
  after() {
    ( cd "$W" && cenv XDG_STATE_HOME="$ST" python3 -B -c 'import os, signal, sys
sys.path.insert(0, sys.argv[1]); import baton
orig = baton.log_event
def log_event(d, **kw):
    if kw.get("event") == "run" and kw.get("result") in ("ok", "postcheck-failed", "run-failed"):
        if sys.argv[2] == "term":
            os.kill(os.getpid(), signal.SIGTERM)
        else:
            raise KeyboardInterrupt
    return orig(d, **kw)
baton.log_event = log_event
sys.exit(baton.main(["run"] + sys.argv[3:]))' "$P/scripts" "$1" "$A" "$W/$2" hello ) >/dev/null 2>&1; echo $?
  }
  eq "$(sg "$P" "$W" owner "$A" "$W/a.txt" hello)" 0 "[run-after-use] sign: rc 0"
  eq "$(after interrupt a.txt)" 5 "[run-after-use] Ctrl-C after the signature was used: rc 5, never 'nothing ran'"
  eq "$(sg "$P" "$W" owner "$A" "$W/b.txt" hello)" 0 "[run-after-use] sign a second act: rc 0"
  eq "$(after term b.txt)/$(logcol 10)" "0/ok" "[run-after-use] SIGTERM once the phases are over is ignored: the run ends ok and is logged"
}
fam_check_set() {
  local P=$1 W A f; fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  f="$W/e1.sh"; cp "$A" "$f"; mutate "$f" $'set -euo pipefail\n' $'set -euo pipefail\nset +e +o pipefail\n'
  eq "$(bt "$P" "$W" check "$f")" 1 "[check-set] a later 'set +e +o pipefail': rc 1"
  f="$W/e2.sh"; cp "$A" "$f"; mutate "$f" $'set -euo pipefail\n' $'set -e\nset -o nounset -o pipefail\n'
  eq "$(bt "$P" "$W" check "$f")" 0 "[check-set] control: the same flags over two lines: rc 0"
}
fam_check_source() {
  local P=$1 W A f; fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  f="$W/s1.sh"; cp "$A" "$f"; in_act "$f" '. ./lib.sh'
  eq "$(bt "$P" "$W" check "$f")" 1 "[check-source] '. ./lib.sh': rc 1"
  f="$W/s2.sh"; cp "$A" "$f"; in_act "$f" 'source ./lib.sh'
  eq "$(bt "$P" "$W" check "$f")" 1 "[check-source] 'source ./lib.sh': rc 1"
  f="$W/s3.sh"; cp "$A" "$f"; in_act "$f" './helper.sh --dry-run || true'
  eq "$(bt "$P" "$W" check "$f")" 1 "[check-source] running a local ./helper.sh (not bound by the signature): rc 1"
  f="$W/s4.sh"; cp "$A" "$f"; in_act "$f" 'write "create via helper" bash "$PWD/tool.sh" "$DEST"'
  eq "$(bt "$P" "$W" check "$f")" 1 "[check-source] a local script run through write(): rc 1"
  f="$W/s6.sh"; cp "$A" "$f"; in_act "$f" 'if ./check.sh; then :; fi'
  eq "$(bt "$P" "$W" check "$f")" 1 "[check-source] a local script as an if condition: rc 1"
  f="$W/s7.sh"; cp "$A" "$f"; in_act "$f" 'ls | xargs ./x'
  eq "$(bt "$P" "$W" check "$f")" 1 "[check-source] a local script behind xargs: rc 1"
  f="$W/s8.sh"; cp "$A" "$f"; in_act "$f" 'echo "usage: a; ./b"'
  eq "$(bt "$P" "$W" check "$f")" 0 "[check-source] control: ./b inside a quoted string: rc 0"
  f="$W/s5.sh"; cp "$A" "$f"; in_act "$f" "bash -c 'echo inline'"
  eq "$(bt "$P" "$W" check "$f")" 0 "[check-source] control: inline code (bash -c) is in the signed bytes: rc 0"
}
# The stop heuristic is a backstop, not a proof: the false positives below are asserted AS false positives, so a change in what it
# flags is seen.
fam_check_stops() {
  local P=$1 W A f; fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  f="$W/t1.sh"; cp "$A" "$f"; in_act "$f" 'write "delete acme/example" gh repo delete acme/example --yes'
  eq "$(bt "$P" "$W" check "$f")" 1 "[check-stops] gh repo delete under 'Stops: none': rc 1"
  mutate "$f" '# Stops: none' '# Stops: irreversible-delete'
  eq "$(bt "$P" "$W" check "$f")" 0 "[check-stops] the same line with Stops declared: rc 0"
  f="$W/t2.sh"; cp "$A" "$f"; in_act "$f" 'write "force-push feat/x" git -C "$PWD" push --force origin feat/x'
  eq "$(bt "$P" "$W" check "$f")" 1 "[check-stops] git -C <dir> push --force under 'Stops: none': rc 1"
  f="$W/t6.sh"; cp "$A" "$f"; in_act "$f" 'write "merge 12" gh -R acme/app pr merge 12 --admin'
  eq "$(bt "$P" "$W" check "$f")" 1 "[check-stops] gh -R <repo> pr merge --admin under 'Stops: none': rc 1"
  f="$W/t7.sh"; cp "$A" "$f"; in_act "$f" 'write "mirror" git push --mirror origin'
  eq "$(bt "$P" "$W" check "$f")" 1 "[check-stops] git push --mirror under 'Stops: none': rc 1"
  f="$W/t8.sh"; cp "$A" "$f"; in_act "$f" 'write "delete" gh api -X delete repos/acme/x'
  eq "$(bt "$P" "$W" check "$f")" 1 "[check-stops] gh api -X delete (lower case) under 'Stops: none': rc 1"
  f="$W/t3.sh"; cp "$A" "$f"; in_act "$f" 'write "push feat/x" git push --force-with-lease origin feat/x'
  eq "$(bt "$P" "$W" check "$f")" 0 "[check-stops] git push --force-with-lease is not history-rewrite: rc 0"
  f="$W/t4.sh"; cp "$A" "$f"; in_act "$f" 'kubectl get secrets -o name'
  eq "$(bt "$P" "$W" check "$f")" 1 "[check-stops] known false positive: a read (kubectl get secrets) is flagged as secrets"
  f="$W/t5.sh"; cp "$A" "$f"; in_act "$f" "echo 'gh repo delete is not run here'"
  eq "$(bt "$P" "$W" check "$f")" 1 "[check-stops] known false positive: the words inside an echo are flagged"
}

# ── rehearse ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
fam_rehearse_expect() {
  local P=$1 W A; fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  eq "$(bt "$P" "$W" rehearse "$A" "$W/out.txt" hello)" 0 "[rehearse-expect] control: the template rehearses: rc 0"
  hasline "$(cat "$BT_OUT")" "  PLAN create $W/out.txt" "[rehearse-expect] control: one PLAN line with the resolved path"
  [ ! -e "$W/out.txt" ] && ok "[rehearse-expect] rehearse writes nothing" || bad "[rehearse-expect] rehearse writes nothing"
  mutate "$A" '# Expect: create *' '# Expect: delete *'
  eq "$(bt "$P" "$W" rehearse "$A" "$W/out.txt" hello)" 1 "[rehearse-expect] plan differs from Expect: rc 1"
  mutate "$A" '# Expect: delete *' $'# Expect: create *\n# Expect: create *'
  eq "$(bt "$P" "$W" rehearse "$A" "$W/out.txt" hello)" 1 "[rehearse-expect] more Expect lines than writes: rc 1"
  eq "$(bt "$P" "$W" rehearse "$A")" 1 "[rehearse-expect] the script exits non-zero (no arguments): rc 1"
}
fam_rehearse_verdict() {
  local P=$1 W A; fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  mutate "$A" $'  write "create $DEST" put_text\n}' $'  write "create $DEST" put_text\n  exit 0\n}'
  eq "$(bt "$P" "$W" check "$A")" 0 "[rehearse-verdict] instrument: the planted script passes check"
  eq "$(bt "$P" "$W" rehearse "$A" "$W/out.txt" hello)" 1 "[rehearse-verdict] rc 0 and the plan, but no verdict line: rc 1"
}

# ── sign and run ────────────────────────────────────────────────────────────────────────────────────────────────────────────────
fam_run_signed() {
  local P=$1 W A; fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  eq "$(bt "$P" "$W" run "$A" "$W/out.txt" hello)" 3 "[run-signed] unsigned: rc 3"
  [ ! -e "$W/out.txt" ] && ok "[run-signed] unsigned: nothing written" || bad "[run-signed] unsigned: nothing written"
  eq "$(sg "$P" "$W" owner "$A" "$W/out.txt" hello)" 0 "[run-signed] sign --by owner: rc 0"
  eq "$(nsig)" 1 "[run-signed] one signature record in the state directory"
  eq "$(bt "$P" "$W" run "$A" "$W/out.txt" hello)" 0 "[run-signed] the signed run: rc 0"
  eq "$(cat "$W/out.txt" 2>/dev/null)" hello "[run-signed] the signed run wrote the file"
  eq "$(logcol 2)/$(logcol 8)/$(logcol 10)" "run/owner/ok" "[run-signed] log: event run, signed by owner, result ok"
  eq "$(nsig)" 0 "[run-signed] the run consumed the signature"
  rm -f "$W/out.txt"
  eq "$(bt "$P" "$W" run "$A" "$W/out.txt" hello)" 3 "[run-single-use] the same run again: rc 3"
  [ ! -e "$W/out.txt" ] && ok "[run-single-use] the second run wrote nothing" || bad "[run-single-use] the second run wrote nothing"
}
fam_sign_seal() {
  local P=$1 W A seal; fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  seal=$(seal_for "$P" "$W" "$A" "$W/out.txt" hello)
  nonempty "$seal" "[sign-seal] instrument: rehearse prints a seal"
  printf '# an edit after the rehearse that was shown\n' >> "$A"
  eq "$(bt "$P" "$W" sign --by owner --seal "$seal" "$A" "$W/out.txt" hello)" 3 "[sign-seal] the script changed since it was shown: rc 3"
  eq "$(nsig)" 0 "[sign-seal] …nothing signed"
  eq "$(bt "$P" "$W" sign --by owner "$A" "$W/out.txt" hello)" 64 "[sign-seal] sign without --seal: rc 64"
  eq "$(sg "$P" "$W" owner "$A" "$W/out.txt" hello)" 0 "[sign-seal] control: the seal of a fresh rehearse signs"
}
# sign takes `--by <signer>` once, first, in two words: a permission rule that allows `sign --by coordinator-auto` matches the
# command text as a prefix, so any other spelling that ends up signing as the owner would skip the owner's dialog
fam_sign_by() {
  local P=$1 W A f seal; fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  f="$W/stop.sh"; cp "$A" "$f"; mutate "$f" '# Stops: none' '# Stops: publish'
  eq "$(bt "$P" "$W" mode auto)" 0 "[sign-by] instrument: mode auto (coordinator-auto may sign a Stops: none script)"
  seal=$(seal_for "$P" "$W" "$f" "$W/out.txt" hello); nonempty "$seal" "[sign-by] instrument: rehearse prints a seal"
  eq "$(bt "$P" "$W" sign --by coordinator-auto --by owner --seal "$seal" "$f" "$W/out.txt" hello)" 64 \
     "[sign-by] --by coordinator-auto --by owner on a stop-list script: rc 64"
  eq "$(bt "$P" "$W" sign --by=owner --seal "$seal" "$f" "$W/out.txt" hello)" 64 "[sign-by] --by=owner: rc 64"
  eq "$(bt "$P" "$W" sign --seal "$seal" --by owner "$f" "$W/out.txt" hello)" 64 "[sign-by] --by after --seal: rc 64"
  eq "$(bt "$P" "$W" sign --by owner --seal "$seal" --seal "$seal" "$f" "$W/out.txt" hello)" 64 "[sign-by] --seal twice: rc 64"
  eq "$(nsig)" 0 "[sign-by] …nothing signed"
  eq "$(bt "$P" "$W" sign --by owner --seal "$seal" "$f" "$W/out.txt" hello)" 0 "[sign-by] control: --by owner --seal S signs"
}

fam_run_edited() {
  local P=$1 W A; fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  eq "$(sg "$P" "$W" owner "$A" "$W/out.txt" hello)" 0 "[run-edited] sign: rc 0"
  printf '# an edit after signing\n' >> "$A"
  eq "$(bt "$P" "$W" check "$A")" 0 "[run-edited] instrument: the edited script still passes check"
  eq "$(bt "$P" "$W" run "$A" "$W/out.txt" hello)" 3 "[run-edited] edited after signing: rc 3"
  [ ! -e "$W/out.txt" ] && ok "[run-edited] nothing written" || bad "[run-edited] nothing written"
}
fam_run_args() {
  local P=$1 W A; fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  eq "$(sg "$P" "$W" owner "$A" "$W/out.txt" hello)" 0 "[run-args] sign: rc 0"
  eq "$(bt "$P" "$W" run "$A" "$W/out.txt" other)" 3 "[run-args] other arguments: rc 3"
  [ ! -e "$W/out.txt" ] && ok "[run-args] nothing written" || bad "[run-args] nothing written"
  # a seal of the printed form (rehearse prints none for a script whose usage check fails), so the guard asks and sign rehearses
  eq "$(bt "$P" "$W" sign --by owner --seal 0000000000000000.0000000000000000 "$A" "$W/b.txt" hello --by owner)" 1 \
     "[run-args] a trailing --by goes to the script (four arguments fail its usage check in rehearse): rc 1"
  eq "$(nsig)" 1 "[run-args] …and nothing more is signed"
}
fam_run_dir() {
  local P=$1 W A V; fresh_state; W=$(fresh); V=$(fresh); A=$(act_in "$P" "$W")
  eq "$(sg "$P" "$W" owner "$A" "$W/out.txt" hello)" 0 "[run-dir] sign from one directory: rc 0"
  eq "$(bt "$P" "$V" run "$A" "$W/out.txt" hello)" 3 "[run-dir] run from another directory: rc 3"
  [ ! -e "$W/out.txt" ] && ok "[run-dir] nothing written" || bad "[run-dir] nothing written"
}
fam_run_env() {
  local P=$1 W A f; fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  BT_ENV=(GH_REPO=acme/staging); eq "$(sg "$P" "$W" owner "$A" "$W/out.txt" hello)" 0 "[run-env] sign with GH_REPO=acme/staging: rc 0"
  BT_ENV=(GH_REPO=acme/production); eq "$(bt "$P" "$W" run "$A" "$W/out.txt" hello)" 3 "[run-env] run with another GH_REPO: rc 3"
  BT_ENV=()
  [ ! -e "$W/out.txt" ] && ok "[run-env] nothing written" || bad "[run-env] nothing written"
  printf 'touch "%s/bash-env-ran"\n' "$W" > "$W/env.sh"
  BT_ENV=(BASH_ENV="$W/env.sh"); bt "$P" "$W" rehearse "$A" "$W/out.txt" hello >/dev/null; BT_ENV=()
  [ ! -e "$W/bash-env-ran" ] && ok "[run-env] BASH_ENV is not run in a phase" || bad "[run-env] BASH_ENV is not run in a phase"
}
fam_run_diverged() {
  local P=$1 W A; fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  mutate "$A" $'  write "create $DEST" put_text\n}' $'  write "create $DEST" put_text\n  if [ -e "$DEST" ]; then write "a write the plan never showed" true; fi\n}'
  eq "$(sg "$P" "$W" owner "$A" "$W/out.txt" hello)" 0 "[run-diverged] sign (the rehearse plan has one write): rc 0"
  eq "$(bt "$P" "$W" run "$A" "$W/out.txt" hello)" 4 "[run-diverged] the run did other writes than the signed plan: rc 4"
  [ ! -e "$W/out.txt" ] && ok "[run-diverged] …and undo ran" || bad "[run-diverged] …and undo ran"
  eq "$(logcol 10)" run-diverged "[run-diverged] log: run-diverged"
  f="$W/glue.sh"; cp "$A" "$f"
  mutate "$f" $'  write "create $DEST" put_text\n  if [ -e "$DEST" ]; then write "a write the plan never showed" true; fi\n}' \
              $'  write "create $DEST" put_text\n  write "announce" printf "done"\n  write "second" echo "DO NOT touch the file by hand"\n}'
  mutate "$f" '# Expect: create *' $'# Expect: create *\n# Expect: announce\n# Expect: second'
  eq "$(sg "$P" "$W" owner "$f" "$W/g.txt" hello)" 0 "[run-diverged] sign a script whose writes print without a newline or 'DO …': rc 0"
  eq "$(bt "$P" "$W" run "$f" "$W/g.txt" hello)" 0 "[run-diverged] control: such output is not read as writes (the write channel is a file): rc 0"
}
fam_run_pipe() {
  local P=$1 W A rc; fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  in_act "$A" 'i=0; while [ "$i" -lt 3000 ]; do echo "progress line $i"; i=$((i + 1)); done'
  eq "$(sg "$P" "$W" owner "$A" "$W/out.txt" hello)" 0 "[run-pipe] sign a script with a lot of output: rc 0"
  rc=$( (cd "$W" && cenv XDG_STATE_HOME="$ST" python3 "$P/scripts/baton.py" run "$A" "$W/out.txt" hello 2>/dev/null | head -1 >/dev/null
         echo "${PIPESTATUS[0]}") )
  eq "$rc/$(logcol 10)" "0/ok" "[run-pipe] 'run | head': rc 0 and the log says ok (a closed stdout does not break the run)"
  # a run that fails prints its whole output (one line only when it holds): a closed stdout keeps its exit code
  mutate "$A" $'postcheck() {\n  holds_text\n}' $'postcheck() {\n  false\n}'
  eq "$(sg "$P" "$W" owner "$A" "$W/out2.txt" hello)" 0 "[run-pipe] sign the same script with a post-check that fails: rc 0"
  rc=$( (cd "$W" && cenv XDG_STATE_HOME="$ST" python3 "$P/scripts/baton.py" run "$A" "$W/out2.txt" hello 2>/dev/null | head -1 >/dev/null
         echo "${PIPESTATUS[0]}") )
  eq "$rc/$(logcol 10)" "4/postcheck-failed" "[run-pipe] 'run | head' of a failing run: rc 4 (undone), the log says postcheck-failed"
}
fam_run_plan() {
  local P=$1 W A; fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  mutate "$A" '  write "create $DEST" put_text' '  write "create $DEST from $(cat "$DEST.src")" put_text'
  echo v1 > "$W/out.txt.src"
  eq "$(sg "$P" "$W" owner "$A" "$W/out.txt" hello)" 0 "[run-plan] sign while the source says v1: rc 0"
  echo v2 > "$W/out.txt.src"
  eq "$(bt "$P" "$W" rehearse "$A" "$W/out.txt" hello)" 0 "[run-plan] instrument: the new plan still matches Expect"
  eq "$(bt "$P" "$W" run "$A" "$W/out.txt" hello)" 3 "[run-plan] the plan changed since signing: rc 3"
  [ ! -e "$W/out.txt" ] && ok "[run-plan] nothing written" || bad "[run-plan] nothing written"
}
fam_run_undo() {
  local P=$1 W A f; fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  f="$W/pc.sh"; cp "$A" "$f"; mutate "$f" $'postcheck() {\n  holds_text\n}' $'postcheck() {\n  false\n}'
  eq "$(sg "$P" "$W" owner "$f" "$W/a.txt" hello)" 0 "[run-undo] sign a script whose post-check fails: rc 0"
  eq "$(bt "$P" "$W" run "$f" "$W/a.txt" hello)" 4 "[run-undo] post-check mismatch: rc 4"
  [ ! -e "$W/a.txt" ] && ok "[run-undo] post-check mismatch: undo removed the file" || bad "[run-undo] post-check mismatch: undo removed the file"
  eq "$(logcol 10)/$(logcol 11)" "postcheck-failed/yes" "[run-undo] log: postcheck-failed, undone yes"
  f="$W/rf.sh"; cp "$A" "$f"
  mutate "$f" $'  write "create $DEST" put_text\n}' $'  write "create $DEST" put_text\n  write "fail on purpose" false\n}'
  mutate "$f" '# Expect: create *' $'# Expect: create *\n# Expect: fail on purpose'
  eq "$(sg "$P" "$W" owner "$f" "$W/b.txt" hello)" 0 "[run-undo] sign a script whose second write fails: rc 0"
  eq "$(bt "$P" "$W" run "$f" "$W/b.txt" hello)" 4 "[run-undo] a failed run: rc 4"
  [ ! -e "$W/b.txt" ] && ok "[run-undo] a failed run: undo removed the first write" || bad "[run-undo] a failed run: undo removed the first write"
  f="$W/uf.sh"; cp "$A" "$f"; mutate "$f" $'postcheck() {\n  holds_text\n}' $'postcheck() {\n  false\n}'
  mutate "$f" $'undo() {\n' $'undo() {\n  false\n'
  eq "$(sg "$P" "$W" owner "$f" "$W/c.txt" hello)" 0 "[run-undo] sign a script whose post-check and undo fail: rc 0"
  eq "$(bt "$P" "$W" run "$f" "$W/c.txt" hello)" 5 "[run-undo] undo fails too: rc 5 (state unknown)"
  eq "$(logcol 11)" failed "[run-undo] log: undone failed"
  f="$W/in.sh"; cp "$A" "$f"
  mutate "$f" $'  write "create $DEST" put_text\n}' $'  write "create $DEST" put_text\n  write "interrupt" kill -TERM "$PPID"\n}'
  mutate "$f" '# Expect: create *' $'# Expect: create *\n# Expect: interrupt'
  eq "$(sg "$P" "$W" owner "$f" "$W/d.txt" hello)" 0 "[run-undo] sign a script whose run interrupts baton: rc 0"
  eq "$(bt "$P" "$W" run "$f" "$W/d.txt" hello)" 5 "[run-undo] an interrupted run: rc 5 (state unknown), no undo"
  eq "$(logcol 10)/$(logcol 11)" "interrupted/no" "[run-undo] log: interrupted, undone no"
  f="$W/nl.sh"; cp "$A" "$f"
  # an argument with a newline is no owner-signable shape (owner_shape): the session signs it in mode auto
  bt "$P" "$W" mode auto >/dev/null
  eq "$(sg "$P" "$W" coordinator-auto "$f" "$W/e.txt" $'two lines\n')" 0 "[run-undo] sign a text that ends in a newline: rc 0"
  eq "$(bt "$P" "$W" run "$f" "$W/e.txt" $'two lines\n')" 0 "[run-undo] …its post-check compares bytes: rc 0"
  bt "$P" "$W" mode manual >/dev/null
  f="$W/nu.sh"; cp "$A" "$f"; mutate "$f" "$POSTCHECK_OK" "$POSTCHECK_NO"; mutate "$f" 'write "remove $DEST" rm -f -- "$DEST"' 'write "remove $DEST" true'
  eq "$(sg "$P" "$W" owner "$f" "$W/g.txt" hello)" 0 "[run-undo] sign a script whose undo removes nothing: rc 0"
  eq "$(bt "$P" "$W" run "$f" "$W/g.txt" hello)" 5 "[run-undo] an undo that leaves the act's bytes is not reported as undone: rc 5"
}
fam_run_interrupt() {
  local P=$1 W A f; fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  f="$W/ib.sh"; cp "$A" "$f"; in_act "$f" 'if [ -e "$DEST.stop" ]; then kill -TERM "$PPID"; fi'
  eq "$(sg "$P" "$W" owner "$f" "$W/a.txt" hello)" 0 "[run-interrupt] sign: rc 0"
  : > "$W/a.txt.stop"
  eq "$(bt "$P" "$W" run "$f" "$W/a.txt" hello)" 3 "[run-interrupt] an interrupt in the rehearse before the run: rc 3, nothing ran"
  eq "$(nsig)/$(logcol 10)" "1/interrupted-before-run" "[run-interrupt] …the signature is still unused, the log says so"
  f="$W/og.sh"; cp "$A" "$f"
  mutate "$f" $'  write "create $DEST" put_text\n}' $'  write "create $DEST" put_text\n  write "late write" bash -c \'kill -TERM "$1"; sleep 1; touch "$0.late"\' "$DEST" "$PPID"\n}'
  mutate "$f" '# Expect: create *' $'# Expect: create *\n# Expect: late write'
  eq "$(sg "$P" "$W" owner "$f" "$W/b.txt" hello)" 0 "[run-interrupt] sign a script whose child interrupts baton, then writes late: rc 0"
  eq "$(bt "$P" "$W" run "$f" "$W/b.txt" hello)" 5 "[run-interrupt] interrupted in the run phase: rc 5"
  python3 -c 'import time; time.sleep(1.5)'
  L="[run-interrupt] the phase's process group was stopped: no late write after baton logged the run"
  [ ! -e "$W/b.txt.late" ] && ok "$L" || bad "$L"
}

# a stop signal that reaches baton while it starts the phase's process (inside Popen: where a loaded runner delivered the act's own
# kill) must stop the phase's group like one a moment later; the act starts a late writer first, then the fixture signals baton.
fam_start_interrupt() {
  local P=$1 W A f sig pre
  fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  for sig in TERM HUP INT TERM+HUP INT+TERM HUP+INT+TERM; do
    f="$W/s$sig.sh"; cp "$A" "$f"
    in_act "$f" 'if [ -e "$DEST.go" ]; then bash -c '"'"'sleep 1; touch "$0.late"'"'"' "$DEST" & touch "$DEST.ready"; sleep 2; fi'
    : > "$W/$sig.txt.go"; pre=(); case "$sig" in *HUP*) pre=("${HUP_DFL[@]}");; esac
    eq "$( (cd "$W" && cenv XDG_STATE_HOME="$ST" ${pre[@]+"${pre[@]}"} python3 "$HERE/fixtures/baton_signal_in_popen.py" "SIG${sig//+/+SIG}" "$W/$sig.txt.ready" \
      "$P/scripts/baton.py" rehearse "$f" "$W/$sig.txt" hello) >/dev/null 2>&1; echo $?)" 3 "[start-interrupt] SIG$sig while the phase starts: rehearse rc 3"
    python3 -c 'import time; time.sleep(1.5)'
    [ -e "$W/$sig.txt.ready" ] && ok "[start-interrupt] …instrument: the act had started its late writer (SIG$sig)" \
      || bad "[start-interrupt] …instrument: the act had started its late writer (SIG$sig)"
    L="[start-interrupt] …the phase's group was stopped: no late write (SIG$sig)"
    [ ! -e "$W/$sig.txt.late" ] && ok "$L" || bad "$L"
  done
}

# ── approval modes ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
fam_round2_streams() {
  local P=$1 W A f v; fresh_state; W=$(fresh); A=$(act_in "$P" "$W"); export W ST
  f="$W/rt.sh"; cp "$A" "$f"
  in_act "$f" 'if [ -e "$DEST.stop" ]; then bash -c '"'"'kill -TERM "$1"; sleep 1; touch "$0.late"'"'"' "$DEST" "$PPID"; fi'
  : > "$W/r.txt.stop"
  eq "$(bt "$P" "$W" rehearse "$f" "$W/r.txt" hello)" 3 "[round2] a rehearse stopped by SIGTERM: rc 3"
  python3 -c 'import time; time.sleep(1.5)'
  L="[round2] the stopped rehearse's script did not write late"
  [ ! -e "$W/r.txt.late" ] && ok "$L" || bad "$L"
  f="$W/rh.sh"; cp "$A" "$f"
  in_act "$f" 'if [ -e "$DEST.stop" ]; then bash -c '"'"'kill -HUP "$1"; sleep 1; touch "$0.late"'"'"' "$DEST" "$PPID"; fi'
  : > "$W/h.txt.stop"
  BT_PRE=("${HUP_DFL[@]}"); eq "$(bt "$P" "$W" rehearse "$f" "$W/h.txt" hello)" 3 "[round2] a rehearse stopped by SIGHUP: rc 3"; BT_PRE=()
  python3 -c 'import time; time.sleep(1.5)'
  L="[round2] the SIGHUP-stopped rehearse's script did not write late"
  [ ! -e "$W/h.txt.late" ] && ok "$L" || bad "$L"
  f="$W/ni.sh"; cp "$A" "$f"; in_act "$f" 'if [ -e "$DEST.stop" ]; then kill -HUP "$PPID"; fi'
  : > "$W/i.txt.stop"
  eq "$( (cd "$W" && cenv XDG_STATE_HOME="$ST" python3 -c 'import os, signal, sys
signal.signal(signal.SIGHUP, signal.SIG_IGN)
os.execvp(sys.argv[1], sys.argv[1:])' python3 "$P/scripts/baton.py" rehearse "$f" "$W/i.txt" hello) >/dev/null 2>&1; echo $?)" 0 \
     "[round2] under nohup (SIGHUP ignored) a SIGHUP does not stop rehearse: rc 0"
  for v in GITHUB_TOKEN GIT_SSH_COMMAND GIT_CONFIG_COUNT; do
    rm -f "$W/v.txt"; BT_ENV=("$v=one"); sg "$P" "$W" owner "$A" "$W/v.txt" hello >/dev/null
    BT_ENV=("$v=two"); eq "$(bt "$P" "$W" run "$A" "$W/v.txt" hello)" 3 "[round2] run with another $v: rc 3"; BT_ENV=()
  done
  eq "$(python3 -c 'import os, subprocess, sys
r, w = os.pipe(); os.close(r)
print(subprocess.run(sys.argv[1:], cwd=os.environ["W"], stdout=subprocess.DEVNULL, stderr=w,
      env=dict(os.environ, XDG_STATE_HOME=os.environ["ST"])).returncode)' python3 "$P/scripts/baton.py" run "$A" "$W/u.txt" hello)" 3 \
     "[round2] run with a stderr nobody reads (EPIPE): the refusal still exits 3"
  BT_ENV=(GH_TOKEN=one); eq "$(sg "$P" "$W" owner "$A" "$W/t.txt" hello)" 0 "[round2] sign with one token: rc 0"
  BT_ENV=(GH_TOKEN=two); eq "$(bt "$P" "$W" run "$A" "$W/t.txt" hello)" 3 "[round2] run with another token: rc 3 (hashed into the binding)"
  BT_ENV=()
  eq "$( (cd "$W" && cenv XDG_STATE_HOME="$ST" python3 "$P/scripts/baton.py" run "$A" "$W/u.txt" hello >&- 2>/dev/null); echo $?)" 3 \
     "[round2] run with stdout closed: the refusal still exits 3"
  eq "$( (cd "$W" && cenv XDG_STATE_HOME="$ST" python3 "$P/scripts/baton.py" run "$A" "$W/u.txt" hello 2>&1 | head -c 1 >/dev/null
          echo "${PIPESTATUS[0]}") )" 3 "[round2] run piped with stderr into a closed reader: rc 3"
}
fam_modes() {
  local P=$1 W A f; fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  eq "$(bt "$P" "$W" mode)/$(cat "$BT_OUT")" "0/manual" "[modes] the default mode is manual"
  eq "$(sg "$P" "$W" coordinator-auto "$A" "$W/a.txt" hello)" 3 "[modes] manual: coordinator-auto cannot sign: rc 3"
  eq "$(nsig)" 0 "[modes] manual: nothing signed"
  eq "$(bt "$P" "$W" mode auto)" 0 "[modes] mode auto: rc 0"
  eq "$(head -n 1 "$(baton_dir)/mode" 2>/dev/null)" auto "[modes] the mode lives in the state directory"
  [ ! -e "$W/mode" ] && [ ! -e "$W/.vibemaestro" ] && ok "[modes] nothing written in the working directory" || bad "[modes] nothing written in the working directory"
  eq "$(sg "$P" "$W" coordinator-auto "$A" "$W/a.txt" hello)" 0 "[modes] auto + Stops none: coordinator-auto signs"
  eq "$(bt "$P" "$W" run "$A" "$W/a.txt" hello)" 0 "[modes] auto: the coordinator-auto signature runs"
  eq "$(logcol 8)/$(logcol 9)" "coordinator-auto/auto" "[modes] log: signed by coordinator-auto in mode auto"
  f="$W/stop.sh"; cp "$A" "$f"; mutate "$f" '# Stops: none' '# Stops: publish'
  eq "$(sg "$P" "$W" coordinator-auto "$f" "$W/b.txt" hello)" 3 "[modes] auto + a declared stop: coordinator-auto cannot sign: rc 3"
  eq "$(sg "$P" "$W" owner "$f" "$W/b.txt" hello)" 0 "[modes] auto + a declared stop: the owner signs"
  eq "$(sg "$P" "$W" coordinator-auto "$A" "$W/c.txt" hello)" 0 "[modes] auto: coordinator-auto signs a second act"
  eq "$(bt "$P" "$W" mode manual)" 0 "[modes] back to manual: rc 0"
  eq "$(bt "$P" "$W" run "$A" "$W/c.txt" hello)" 3 "[modes] manual again: a pending coordinator-auto signature is refused: rc 3"
  [ ! -e "$W/c.txt" ] && ok "[modes] …and nothing written" || bad "[modes] …and nothing written"
  eq "$(bt "$P" "$W" mode sometimes)" 64 "[modes] an unknown mode: rc 64"
}
# A fresh install has not chosen a mode: it reads as manual and the card says the owner is asked once; a stop-list baton needs
# the owner in every mode, the not-chosen one included
fam_mode_choice() {
  local P=$1 W A f m
  W=$(fresh); fresh_state; A=$(act_in "$P" "$W")
  f="$W/stop.sh"; cp "$A" "$f"; mutate "$f" '# Stops: none' '# Stops: publish'
  for m in none manual auto; do
    fresh_state; [ "$m" = none ] || bt "$P" "$W" mode "$m" >/dev/null
    rm -f "${W:?}/o.txt"; touch "$A" "$f"                    # go runs a file written in the last 120 s
    eq "$(bt "$P" "$W" go "$f" "$W/o.txt" hello)" 8 "[mode-choice] $m: go on a Stops: publish baton stops for the owner: rc 8"
    has "$(cat "$BT_OUT")" "  Stop:     publish (a stop-list item: only the owner signs)" "[mode-choice] $m: the card names the stop item"
    hasnt "$(cat "$BT_OUT")" "not chosen yet" "[mode-choice] $m: a stop-list card does not ask the mode (no answer unblocks it)"
    eq "$(sg "$P" "$W" coordinator-auto "$f" "$W/o.txt" hello)" 3 "[mode-choice] $m: coordinator-auto cannot sign a Stops: publish baton: rc 3"
    eq "$(nsig)" 0 "[mode-choice] $m: no signature record"
    [ ! -e "$W/o.txt" ] && ok "[mode-choice] $m: nothing written" || bad "[mode-choice] $m: nothing written"
    eq "$(bt "$P" "$W" go "$A" "$W/o.txt" hello)" "$([ "$m" = auto ] && echo 0 || echo 8)" "[mode-choice] $m: go on a Stops: none baton"
    case $m in
      none) has "$(cat "$BT_OUT")" "  Stop:     mode manual (not chosen yet): ask the owner once which mode" \
              "[mode-choice] none: the card says the mode is not chosen yet"
            has "$(cat "$BT_OUT")" "  Mode:     on the owner's answer the session runs \`python3 " \
              "[mode-choice] none, no rules: the session runs mode alone, the hook opens the owner's dialog"
            hasnt "$(cat "$BT_OUT")" "\`! " "[mode-choice] none: no \`!\` command (a mode call with no record is refused)";;
      manual) has "$(cat "$BT_OUT")" "  Stop:     mode manual: the owner signs every baton" "[mode-choice] manual: the card keeps the manual line"
              hasnt "$(cat "$BT_OUT")" "not chosen yet" "[mode-choice] manual: chosen once, never asked again";;
      auto) eq "$(cat "$W/o.txt" 2>/dev/null)" hello "[mode-choice] auto: the session signs and runs a Stops: none baton";;
    esac
  done
  fresh_state; baton_set_mode "$ST" sometimes; rm -f "${W:?}/o.txt"; touch "$A"
  eq "$(bt "$P" "$W" go "$A" "$W/o.txt" hello)" 8 "[mode-choice] a mode file with another value: manual, rc 8"
  hasnt "$(cat "$BT_OUT")" "not chosen yet" "[mode-choice] a mode file with another value: only a missing or unproven file is not chosen"
  fresh_state; mkdir -p "$(baton_dir)"; echo auto > "$(baton_dir)/mode"; rm -f "${W:?}/o.txt"; touch "$A"
  eq "$(bt "$P" "$W" go "$A" "$W/o.txt" hello)" 8 "[mode-choice] a mode file auto without the owner's dialog line (an older baton.py wrote it): manual, rc 8"
  has "$(cat "$BT_OUT")" "not chosen yet" "[mode-choice] …not chosen: the owner is asked once more"
  fresh_state; mkdir -p "$(baton_dir)/mode"; touch "$A"
  eq "$(bt "$P" "$W" go "$A" "$W/o.txt" hello)" 8 "[mode-choice] a mode path that is a directory: manual, rc 8"
  hasnt "$(cat "$BT_OUT")" "not chosen yet" "[mode-choice] a mode path that is a directory: chosen, not asked"
  fresh_state; mkdir -p "$(baton_dir)"; printf '\377auto\n' > "$(baton_dir)/mode"; touch "$A"
  eq "$(bt "$P" "$W" go "$A" "$W/o.txt" hello)" 8 "[mode-choice] a mode file that is not UTF-8: manual, rc 8"
  hasnt "$(cat "$BT_OUT")" "not chosen yet" "[mode-choice] a mode file that is not UTF-8: chosen, not asked"
  eq "$(bt "$P" "$W" mode auto)/$(head -n 1 "$(baton_dir)/mode")" "0/auto" "[mode-choice] a mode file that is not UTF-8: mode auto rewrites it"
  has "$(sed -n 2p "$(baton_dir)/mode")" "dialog " "[mode-choice] …with the owner's dialog line"
}

# ── log, environment, usage ─────────────────────────────────────────────────────────────────────────────────────────────────────
fam_log_env() {
  local P=$1 W A T; fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  sg "$P" "$W" owner "$A" "$W/a.txt" hello >/dev/null; bt "$P" "$W" run "$A" "$W/a.txt" hello >/dev/null
  eq "$(bt "$P" "$W" log --tail 1)/$(wc -l < "$BT_OUT" | tr -d ' ')" "0/1" "[log] --tail 1 prints one line"
  eq "$(cut -f2 "$BT_OUT")" run "[log] the last event is the run"
  eq "$(awk -F'\t' '{print NF}' "$(baton_dir)/log.tsv" | sort -u)" 13 "[log] every line has 13 tab-separated fields (the last: baton)"
  ls "$(baton_dir)/runs/"*-act-*.log >/dev/null 2>&1 && ok "[log] the full output of the run is kept under runs/" || bad "[log] the full output of the run is kept under runs/"
  eq "$(bt "$P" "$W" log --tail 0)" 64 "[log] --tail 0: rc 64"
  rm -f "$W/a.txt"; sg "$P" "$W" owner "$A" "$W/a.txt" $'x\rFAKE\tsign\x0bline' >/dev/null
  eq "$(bt "$P" "$W" log --tail 1)/$(wc -l < "$BT_OUT" | tr -d ' ')/$(tr -d -c '\r\v' < "$BT_OUT" | wc -c | tr -d ' ')" "0/1/0" \
     "[log] control characters in an argument stay inside one escaped log line"
  if mkdir "$W/caf"$'\xe9' 2>/dev/null; then
    eq "$(sg "$P" "$W/caf"$'\xe9' owner "$A" "$W/u.txt" hello)/$(bt "$P" "$W/caf"$'\xe9' run "$A" "$W/u.txt" hello)" "0/0" \
       "[log] a directory name that is not UTF-8: sign and run rc 0"
  else ok "[log] (this filesystem refuses a non-UTF-8 directory name: case not run)"; fi
  eq "$(stat -c %a "$(baton_dir)" 2>/dev/null || stat -f %Lp "$(baton_dir)")" 700 "[state] the state directory is private (0700)"
  T=$(fresh); mk_tools "$T/py" python3
  eq "$( (cd "$W" && cenv PATH="$T/py" XDG_STATE_HOME="$ST" python3 "$P/scripts/baton.py" check "$A") >/dev/null 2>&1; echo $?)" 2 "[env] no bash on PATH: rc 2"
  echo file > "$T/a-file"
  eq "$( (cd "$W" && cenv XDG_STATE_HOME="$T/a-file" python3 "$P/scripts/baton.py" mode auto) >/dev/null 2>&1; echo $?)" 2 "[env] the state directory cannot be written: rc 2"
  eq "$(bt "$P" "$W" check "$W/none.sh")" 66 "[usage] a script that cannot be read: rc 66"
  eq "$(bt "$P" "$W" frobnicate)" 64 "[usage] an unknown command: rc 64"
  eq "$(bt "$P" "$W" sign --by root "$A")" 64 "[usage] an unknown signer: rc 64"
  eq "$(bt "$P" "$W" sign --seal "$(seal_for "$P" "$W" "$A" "$W/z.txt" hello)" "$A" "$W/z.txt" hello)" 64 \
     "[usage] sign without --by: rc 64 (who approves is never a default)"
  fresh_state; rm -f "$W/a.txt"; sg "$P" "$W" owner "$A" "$W/a.txt" hello >/dev/null; bt "$P" "$W" run "$A" "$W/a.txt" hello >/dev/null
  rm -f "$W/a.txt"; sg "$P" "$W" owner "$A" "$W/a.txt" hello >/dev/null; bt "$P" "$W" run "$A" "$W/a.txt" hello >/dev/null
  eq "$(ls "$(baton_dir)/used" | wc -l | tr -d ' ')/$(ls "$(baton_dir)/runs" | grep -c '\.log$')" "2/2" \
     "[log] two runs of the same binding keep two used records and two outputs (pid in the names; a same-second clash is not forced, so no planted break)"
}
fam_state_place() {
  local P=$1 W A H; fresh_state; W=$(fresh); A=$(act_in "$P" "$W"); H=$(fresh)
  ( cd "$W" && cenv HOME="$H" python3 "$P/scripts/baton.py" permissions --install-launcher ) >/dev/null 2>&1
  [ -f "$H/.local/state/vibemaestro/baton/bin/baton" ] && ok "[state] without XDG_STATE_HOME: ~/.local/state/vibemaestro/baton" \
    || bad "[state] without XDG_STATE_HOME: ~/.local/state/vibemaestro/baton"
  rm -f "$H/.local/state/vibemaestro/baton/bin/baton"
  ( cd "$W" && cenv HOME="$H" XDG_STATE_HOME=relative python3 "$P/scripts/baton.py" permissions --install-launcher ) >/dev/null 2>&1
  [ -f "$H/.local/state/vibemaestro/baton/bin/baton" ] && ok "[state] a relative XDG_STATE_HOME is ignored" || bad "[state] a relative XDG_STATE_HOME is ignored"
  [ ! -e "$W/relative" ] && ok "[state] …and nothing is written under the working directory" || bad "[state] …and nothing is written under the working directory"
}

# ── the rule: privileged commands run directly ─────────────────────────────────────────────────────────────────────────────────
# rule_ctx <plugin> <command> — what the plugin's PreToolUse Bash hook (the command of hooks.json, as Claude Code runs it) adds before
# that command in the app repo; a fresh session id per call, so the once-per-session dedup never hides a case. Commands carry no
# double quote (p_bash puts them in a JSON string). The same form as tests/test-hook.sh section C6, kept here so that suite is not
# touched.
RAPP="$TMP/app"; mk_app "$RAPP"
rule_ctx() { ctx "$(CLAUDE_PROJECT_DIR="$RAPP" CLAUDE_PLUGIN_ROOT="$1" run_cmds "$1/hooks/hooks.json" PreToolUse Bash "$(p_bash "$(sid)" "$2")")"; }
fam_rule() {
  local P=$1 c
  fires()  { has "$(rule_ctx "$P" "$1")" batonrun.instructions.md "[rule] '$1' reminds batonrun"; }
  silent() { hasnt "$(rule_ctx "$P" "$1")" batonrun.instructions.md "[rule] '$1' does not remind batonrun"; }
  fires 'gh pr merge 12 --squash'
  fires 'gh -R acme/app pr merge 12'
  fires 'gh api repos/acme/app/pulls/12/merge -X PUT'
  fires 'gh api --method DELETE repos/acme/app/git/refs/heads/x'
  fires 'gh api -XPOST repos/acme/app/issues'
  fires 'gh api repos/acme/app/issues -f title=x'
  fires "gh api graphql -f query='mutation { x }'"
  fires "$DK push ghcr.io/acme/app:1"
  fires "$DK image push acme/app:1"
  fires "$DK buildx build . --push -t acme/app:1"
  fires 'claude plugin install x@y'
  fires 'claude plugin uninstall x@y'
  fires 'claude plugin update x@y'
  fires 'claude plugin marketplace add acme/plugins'
  fires 'claude plugin marketplace remove y'
  fires 'git push --force origin feat/x'
  fires 'git push -f origin feat/x'
  fires 'git push origin +feat/x'
  fires 'git -C /w push --force'
  fires 'BATON_PHASE=run bash act.sh a b'
  fires 'gh pr \\\n merge 12'
  fires 'gh repo delete acme/x --yes'
  fires 'gh release delete v1'
  fires 'gh secret set TOKEN'
  fires 'gh repo edit acme/x --visibility public'
  fires "gh api -X 'POST' repos/acme/app/issues"
  fires 'gh api --method=PUT repos/acme/app/pulls/1/merge'
  fires 'gh api repos/acme/app/issues -ftitle=x'
  fires "$DK --context prod push acme/app:1"
  fires "$DK buildx --builder ci build --push ."
  fires "$DK buildx build --output type=registry ."
  fires "$DK compose push"
  fires "$DK buildx imagetools create -t a b"
  fires 'claude plugin i x@y'
  fires 'claude plugin remove x@y'
  fires 'claude plugin prune'
  fires 'git push --mirror origin'
  fires "git push origin '+main'"
  fires 'git --work-tree /w push -f'
  # a ref delete, by push or straight in the repository's directory: the reminder is the only guard of a bare one
  fires 'git push origin --delete feat/x'
  fires 'git push origin :feat/x'
  fires "git push --force-with-lease='refs/heads/x:abc' origin ':refs/heads/x'"
  fires 'git -C /lab/remote.git update-ref -d refs/heads/feature/old'
  fires 'cd /lab/remote.git && git update-ref refs/heads/x 0000000000000000000000000000000000000000'
  fires "printf 'delete refs/heads/x\\n' | git -C /lab/remote.git update-ref --stdin"
  fires 'git branch -D feat/x'
  fires 'git -C /lab/remote.git tag -d v1'
  fires 'git -P -C /lab/remote update-ref -d refs/heads/x'
  silent 'git push origin HEAD:refs/heads/feat/x'
  silent 'git branch -d feat/x'
  silent 'git update-ref refs/heads/x 0123456789abcdef0123456789abcdef01234567'
  silent 'git update-ref refs/heads/x 0123456789abcdef0123456789abcdef01234567 0000000000000000000000000000000000000000'
  silent "git commit -m 'docs: delete refs/ note; update-ref'"
  silent 'git tag -a v1 -m v1'
  silent 'gh repo view acme/x'
  silent 'gh secret list'
  silent "$DK compose up -d"
  silent 'claude plugin details x'
  fires 'export BATON_PHASE=undo'
  # Kubernetes writes are not this rule's: kit decision D2 keeps this plugin free of cluster access; a plugin for cluster work
  # carries kubectl, flux and helm in its own rules. Asserted, so the choice is visible and a change of it is seen.
  silent 'kubectl apply -f deploy.yaml'
  silent 'kubectl delete pod x'
  silent 'gh pr view 12'
  silent 'gh pr checks 12'
  silent 'gh api repos/acme/app/pulls/12'
  silent 'gh api repos/acme/app/pulls -X GET -f per_page=100'
  silent "gh api graphql -f query='query { viewer { login } }'"
  silent "$DK build -t acme/app:1 ."
  silent "$DK pull acme/app:1"
  silent 'claude plugin list'
  silent 'claude plugin marketplace list'
  silent 'claude plugin validate .'
  silent 'git push --force-with-lease origin feat/x'
  silent 'git push -u origin feat/x'
  silent 'git push origin feat/fix'
  silent 'BATON_PHASE=rehearse bash act.sh a b'
  silent 'bash act.sh a b'
  silent 'ls -la'
  # a privileged command inside a baton script: the hook sees `baton.py run …`, never the script body
  printf 'gh pr merge 12 --squash\ngit push --force origin feat/x\n' > "$RAPP/deploy.sh"
  for c in run 'sign --by owner' rehearse check; do silent "python3 $P/scripts/baton.py $c deploy.sh 12 abc123"; done
  eq "$(within 5 python3 -c 'import re, sys
sys.path.insert(0, sys.argv[1]); import rules
rx = rules.front(open(sys.argv[2]).read(), "applyWhen")
for w, o in (("claude", "--verbose"), ("dock" "er", "--verbose"), ("git", "--verbose"), ("git", "--work-tree"), ("git", "-P")):
    re.search(rx, w + " " + " ".join([o] * 3000) + " x")
re.search(rx, "delete refs/heads/x\n" * 20000)' "$P/scripts" "$P/rules/batonrun.instructions.md")" 0 \
     "[rule] the applyWhen regex stays linear: 3000 options, or 20000 heredoc delete lines, in under 5 s (it runs before every Bash command)"
  fires 'git push --force origin feat/x'
}

# BATON_PLAN: the run phase gets a file holding the signed plan (a script can refuse to do anything else, before an act that
# cannot be undone); no other phase gets it
fam_plan_env() {
  local P=$1 W A f
  fresh_state; W=$(fresh); A=$(act_in "$P" "$W"); f="$W/p.sh"; cp "$A" "$f"
  in_act "$f" 'if [ -n "${BATON_PLAN:-}" ]; then cp "$BATON_PLAN" "$DEST.plan"; fi'
  in_act "$f" 'echo "plan-env=${BATON_PLAN:+set}"'
  eq "$(bt "$P" "$W" rehearse "$f" "$W/x.txt" hi)" 0 "[plan-env] rehearse: rc 0"
  has "$(cat "$BT_OUT")" "plan-env=" "[plan-env] instrument: the probe line is printed"
  hasnt "$(cat "$BT_OUT")" "plan-env=set" "[plan-env] rehearse: no BATON_PLAN"
  bt "$P" "$W" mode auto >/dev/null
  eq "$(sg "$P" "$W" coordinator-auto "$f" "$W/x.txt" hi)" 0 "[plan-env] sign: rc 0"
  BT_ENV=(BATON_PLAN=/planted); eq "$(bt "$P" "$W" run "$f" "$W/x.txt" hi)" 0 "[plan-env] run: rc 0"; BT_ENV=()
  eq "$(cat "$W/x.txt.plan" 2>/dev/null)" "create $W/x.txt" "[plan-env] run: BATON_PLAN holds the signed plan (not the caller's value)"
  cp "$f" "$W/plan"
  eq "$(sg "$P" "$W" coordinator-auto "$W/plan" "$W/y.txt" hi)" 0 "[plan-env] sign a script named plan: rc 0"
  eq "$(bt "$P" "$W" run "$W/plan" "$W/y.txt" hi)" 0 "[plan-env] run a script named plan: rc 0 (the plan file does not overwrite it)"
}

# kit batons: `kit:<name>` is the plugin's own batons/<name>.sh; only such a baton may run a plugin gate, in one form
TRUSTED_LINE='python3 -I -B "$BATON_PLUGIN_ROOT/gates/merge_guard.py" --help >/dev/null'
fam_kit() {
  local P=$1 W A f P2 n
  fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  f="$P/batons/t-kit.sh"; cp "$A" "$f"; mutate "$f" '# Stops: none' $'# Stops: none\n# Usage: <file> <text>'; in_act "$f" "$TRUSTED_LINE"; in_act "$f" 'echo "root=${BATON_PLUGIN_ROOT:-unset}"'
  eq "$(bt "$P" "$W" check kit:t-kit)" 0 "[kit] check kit:t-kit (a plugin gate run as python3 -I -B \"\$BATON_PLUGIN_ROOT/gates/x.py\"): rc 0"
  cp "$f" "$W/session.sh"
  eq "$(bt "$P" "$W" check "$W/session.sh")" 1 "[kit] the same line in a session baton: check rc 1"
  has "$(cat "$BT_OUT")" "local script" "[kit] …a local script, as before"
  for bad_line in 'python3 -I -B "$BATON_PLUGIN_ROOT/gates/../scripts/x.py"' 'python3 "$BATON_PLUGIN_ROOT/gates/merge_guard.py" --help' \
                  'bash "$BATON_PLUGIN_ROOT/gates/dead_branches.sh"' 'python3 -I -B "$BATON_PLUGIN_ROOT/scripts/kb.py" --help'; do
    cp "$A" "$P/batons/t-bad.sh"; mutate "$P/batons/t-bad.sh" '# Stops: none' $'# Stops: none\n# Usage: <file> <text>'; in_act "$P/batons/t-bad.sh" "$bad_line"
    eq "$(bt "$P" "$W" check kit:t-bad)" 1 "[kit] a kit baton with another form ($bad_line): check rc 1"
  done
  eq "$(bt "$P" "$W" rehearse kit:t-kit "$W/a.txt" hi)" 0 "[kit] rehearse kit:t-kit: rc 0"
  has "$(cat "$BT_OUT")" "root=$(cd "$P" && pwd -P)" "[kit] …BATON_PLUGIN_ROOT is the plugin root"
  cp "$A" "$W/plain.sh"; in_act "$W/plain.sh" 'echo "root=${BATON_PLUGIN_ROOT:-unset}"'
  eq "$(bt "$P" "$W" check "$W/plain.sh")" 1 "[kit] a session baton that reads BATON_PLUGIN_ROOT outside the plugin-script word: check rc 1"
  cp "$A" "$W/plain.sh"   # the name is spelled in two parts: the probe reads the environment, it does not name the variable
  in_act "$W/plain.sh" 'python3 -c '"'"'import os; print("root=" + os.environ.get("BATON_PLUGIN" + "_ROOT", "unset"))'"'"''
  BT_ENV=(BATON_PLUGIN_ROOT=/planted); bt "$P" "$W" rehearse "$W/plain.sh" "$W/b.txt" hi >/dev/null; BT_ENV=()
  has "$(cat "$BT_OUT")" "root=unset" "[kit] a session baton never gets BATON_PLUGIN_ROOT, not even from the caller"
  printf '#!/usr/bin/env bash\ntouch "%s/ran"\n' "$W" > "$W/outside.sh"; ln -sf "$W/outside.sh" "$P/batons/t-link.sh"
  for name in '../x' 'a/b' 'a.b' '' 'Demo' 't-link' '-x'; do
    n=$(bt "$P" "$W" rehearse "kit:$name" "$W/c.txt" hi)
    eq "$n" 64 "[kit] kit:$name: rc 64, refused before anything runs"
  done
  eq "$(bt "$P" "$W" check kit:none)" 66 "[kit] kit:none (no such baton): rc 66"
  [ ! -e "$W/ran" ] && ok "[kit] …the link's target never ran" || bad "[kit] …the link's target never ran"
  rm -f "$P/batons/t-link.sh" "$P/batons/t-bad.sh"
  bt "$P" "$W" mode auto >/dev/null
  P2="$(fresh)/p2"; cp -r "$P" "$P2"
  eq "$(sg "$P" "$W" coordinator-auto kit:t-kit "$W/d.txt" hi)" 0 "[kit] sign kit:t-kit (mode auto): rc 0"
  eq "$(bt "$P2" "$W" run kit:t-kit "$W/d.txt" hi)" 3 "[kit] a signature from another plugin copy (same bytes): run refused, rc 3"
  eq "$(bt "$P" "$W" run kit:t-kit "$W/d.txt" hi)" 0 "[kit] …and the copy it was signed with runs it: rc 0"
  rm -f "$P/batons/t-kit.sh"
}

# a dependent plugin's kit (repo split S8): `kit:<name>` also finds batons/<name>.sh of an installed plugin of sdlc's own
# marketplace that declares the dependency, read from the registry beside the running sdlc copy (never from CLAUDE_CONFIG_DIR or
# HOME). The fake Claude Code directory holds a copy of the plugin and the fixture tests/fixtures/dependent-plugin in Claude
# Code's cache shape, as on the laptop after S4: dependent-fixture@vibemaestro next to vibemaestro-sdlc@vibemaestro.
KD_FIX="$SRC_ROOT/tests/fixtures/dependent-plugin"
# kd_reg <registry> <id>=<installPath>... — a version-2 registry, one entry per argument, later arguments updated later
kd_reg() {
  python3 - "$@" <<'PY'
import json, sys
reg = {"version": 2, "plugins": {}}
for i, a in enumerate(sys.argv[2:]):
    pid, path = a.split("=", 1)
    reg["plugins"].setdefault(pid, []).append({"scope": "user", "installPath": path, "version": "1.0.0",
                                               "installedAt": "2026-10-21T00:00:00.000Z", "lastUpdated": "2026-10-21T00:00:%02d.000Z" % i})
open(sys.argv[1], "w").write(json.dumps(reg))
PY
}
# kd_plugin <dir> [<dependencies JSON>] — a fresh copy of the fixture at <dir>, its manifest's dependencies replaced when given
kd_plugin() {
  rm -rf "$1"; mkdir -p "$(dirname "$1")"; cp -r "$KD_FIX" "$1"
  [ $# -lt 2 ] || python3 - "$1/.claude-plugin/plugin.json" "$2" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
m["dependencies"] = json.loads(sys.argv[2])
if m["dependencies"] is None:
    del m["dependencies"]
json.dump(m, open(sys.argv[1], "w"))
PY
}
fam_kit_dep() {
  local P=$1 W C R S D M sid did
  fresh_state; W=$(fresh); C="$(fresh)/claude"; R="$C/plugins/installed_plugins.json"; M="$C/plugins/cache"
  S="$M/vibemaestro/vibemaestro-sdlc/1.0.0"; D="$M/vibemaestro/dependent-fixture/1.0.0"
  sid="vibemaestro-sdlc@vibemaestro=$S"; did="dependent-fixture@vibemaestro=$D"
  mkdir -p "$(dirname "$S")"; cp -r "$P" "$S"; kd_plugin "$D"; kd_reg "$R" "$sid" "$did"
  eq "$(bt "$S" "$W" check kit:fixture-kit)" 0 "[kit-dep] check kit:fixture-kit (the fixture's batons/, Each: create *): rc 0"
  eq "$(bt "$S" "$W" rehearse kit:fixture-kit "$W/a.txt" hi)" 0 "[kit-dep] rehearse kit:fixture-kit: rc 0"
  has "$(cat "$BT_OUT")" "root=$D" "[kit-dep] …BATON_PLUGIN_ROOT is the dependent plugin's root"
  has "$(cat "$BT_OUT")" "from dependent-fixture@vibemaestro" "[kit-dep] …the header names the plugin it came from"
  eq "$(bt "$S" "$W" go kit:fixture-kit "$W/g.txt" hi)" 8 "[kit-dep] go in mode manual: the owner's card, rc 8"
  has "$(head -n 1 "$BT_OUT")" "fixture-kit.sh (a kit of dependent-fixture@vibemaestro) needs the owner's signature" \
    "[kit-dep] …the card's first line names the plugin the kit comes from"
  bt "$S" "$W" mode auto >/dev/null
  eq "$(sg "$S" "$W" coordinator-auto kit:fixture-kit "$W/a.txt" hi)" 0 "[kit-dep] sign kit:fixture-kit: rc 0"
  eq "$(bt "$S" "$W" run kit:fixture-kit "$W/a.txt" hi)" 0 "[kit-dep] run kit:fixture-kit: rc 0"
  eq "$(cat "$W/a.txt" 2>/dev/null)" "hi" "[kit-dep] …it wrote its file"
  # the signature binds the bytes and that plugin's batons/: an edit after signing, or another install of the same bytes, has none
  eq "$(sg "$S" "$W" coordinator-auto kit:fixture-kit "$W/b.txt" hi)" 0 "[kit-dep] sign again: rc 0"
  cp "$D/batons/fixture-kit.sh" "$W/kit.bak"; printf '# changed after signing\n' >> "$D/batons/fixture-kit.sh"
  eq "$(bt "$S" "$W" run kit:fixture-kit "$W/b.txt" hi)" 3 "[kit-dep] the kit's bytes changed after signing: run refused, rc 3"
  [ ! -e "$W/b.txt" ] && ok "[kit-dep] …nothing written" || bad "[kit-dep] …nothing written"
  cp "$W/kit.bak" "$D/batons/fixture-kit.sh"
  kd_plugin "$M/vibemaestro/dependent-fixture/1.0.1"; kd_reg "$R" "$sid" "dependent-fixture@vibemaestro=$M/vibemaestro/dependent-fixture/1.0.1"
  eq "$(bt "$S" "$W" run kit:fixture-kit "$W/b.txt" hi)" 3 "[kit-dep] a signature from another install of the same bytes: run refused, rc 3"
  kd_reg "$R" "$sid" "$did"
  eq "$(bt "$S" "$W" run kit:fixture-kit "$W/b.txt" hi)" 0 "[kit-dep] …and the install it was signed with runs it: rc 0"
  # an sdlc kit still runs beside the registry, and a kit nobody ships is rc 66
  cp "$KD_FIX/batons/fixture-kit.sh" "$S/batons/t-own.sh"
  eq "$(bt "$S" "$W" rehearse kit:t-own "$W/c.txt" hi)" 0 "[kit-dep] an sdlc kit beside the registry: rehearse rc 0"
  has "$(cat "$BT_OUT")" "root=$S" "[kit-dep] …from the sdlc root"
  # a plugin that may not run a kit never blocks or shadows an sdlc kit of the same name
  kd_plugin "$M/elsewhere/foreign/1.0.0"; kd_plugin "$M/vibemaestro/no-dep/1.0.0" null
  cp "$KD_FIX/batons/fixture-kit.sh" "$M/elsewhere/foreign/1.0.0/batons/t-own.sh"; cp "$KD_FIX/batons/fixture-kit.sh" "$M/vibemaestro/no-dep/1.0.0/batons/t-own.sh"
  kd_reg "$R" "$sid" "$did" "foreign@elsewhere=$M/elsewhere/foreign/1.0.0" "no-dep@vibemaestro=$M/vibemaestro/no-dep/1.0.0"
  eq "$(bt "$S" "$W" rehearse kit:t-own "$W/c.txt" hi)" 0 "[kit-dep] an sdlc kit that ineligible plugins also ship: still sdlc's, rc 0"
  has "$(cat "$BT_OUT")" "root=$S" "[kit-dep] …from the sdlc root, not theirs"
  # a malformed entry of sdlc itself (a NUL in its installPath) costs nothing: sdlc's kits and the lookup still work
  python3 - "$R" "$S" "$D" <<'PY2'
import json, sys
json.dump({"version": 2, "plugins": {"vibemaestro-sdlc@vibemaestro": [{"installPath": "/x\u0000y"}, {"installPath": "/\ud800"},
           {"installPath": sys.argv[2]}], "dependent-fixture@vibemaestro": [{"installPath": sys.argv[3]}]}}, open(sys.argv[1], "w"))
PY2
  eq "$(bt "$S" "$W" rehearse kit:t-own "$W/c.txt" hi)" 0 "[kit-dep] a NUL or a lone surrogate in an sdlc installPath: sdlc's kit runs, rc 0"
  eq "$(bt "$S" "$W" rehearse kit:fixture-kit "$W/c.txt" hi)" 0 "[kit-dep] …and the dependent kit is still found, rc 0"
  # …and an unusable installPath of a dependent plugin is skipped: it never counts as a plugin that ships a kit (rc 66, not 64)
  python3 - "$R" "$S" <<'PY2'
import json, sys
json.dump({"version": 2, "plugins": {"vibemaestro-sdlc@vibemaestro": [{"installPath": sys.argv[2]}],
           "odd@vibemaestro": [{"installPath": "/\ud800"}], "nul@vibemaestro": [{"installPath": "/x\u0000y"}]}}, open(sys.argv[1], "w"))
PY2
  eq "$(bt "$S" "$W" rehearse kit:nobody "$W/c.txt" hi)" 66 "[kit-dep] a dependent entry with a NUL or a lone surrogate: skipped, kit:nobody rc 66"
  kd_reg "$R" "$sid" "$did"
  rm -f "$S/batons/t-own.sh"
  eq "$(bt "$S" "$W" rehearse kit:nobody "$W/c.txt" hi)" 66 "[kit-dep] kit:nobody: rc 66"
  # the planted breaks: each refused before anything runs (rc 64, the reason named, the kit never printed its root)
  kd_dep_refused() {  # <label> <stderr phrase>
    local n; n=$(bt "$S" "$W" rehearse kit:fixture-kit "$W/c.txt" hi)
    eq "$n" 64 "[kit-dep] $1: refused, rc 64"
    has "$(cat "$BT_OUT")" "$2" "[kit-dep] …$1: named"
    hasnt "$(cat "$BT_OUT")" "root=" "[kit-dep] …$1: the kit never ran"
  }
  kd_plugin "$M/vibemaestro/no-dep/1.0.0" null; kd_reg "$R" "$sid" "no-dep@vibemaestro=$M/vibemaestro/no-dep/1.0.0"
  kd_dep_refused "a plugin without the dependency" "does not declare a dependency on vibemaestro-sdlc"
  kd_plugin "$M/vibemaestro/other-dep/1.0.0" '["vibemaestro-brain", "vibemaestro-sdlc@elsewhere"]'
  kd_reg "$R" "$sid" "other-dep@vibemaestro=$M/vibemaestro/other-dep/1.0.0"
  kd_dep_refused "a dependency on another marketplace's vibemaestro-sdlc" "does not declare a dependency on vibemaestro-sdlc"
  kd_plugin "$M/vibemaestro/dependent-fixture/1.0.2" null
  kd_reg "$R" "$sid" "$did" "dependent-fixture@vibemaestro=$M/vibemaestro/dependent-fixture/1.0.2"
  kd_dep_refused "the newer entry of the same plugin without the dependency" "does not declare a dependency on vibemaestro-sdlc"
  kd_plugin "$M/elsewhere/dependent-fixture/1.0.0"; kd_reg "$R" "$sid" "dependent-fixture@elsewhere=$M/elsewhere/dependent-fixture/1.0.0"
  kd_dep_refused "a plugin from another marketplace" "comes from marketplace elsewhere, not vibemaestro"
  kd_reg "$R" "$sid" "dependent-fixture@vibemaestro=$M/elsewhere/dependent-fixture/1.0.0"
  kd_dep_refused "an id of our marketplace installed under another" "not under $M/vibemaestro/dependent-fixture/"
  kd_plugin "$W/loose/dependent-fixture"; kd_reg "$R" "$sid" "dependent-fixture@vibemaestro=$W/loose/dependent-fixture"
  kd_dep_refused "an installPath outside the plugin cache" "not under $M/vibemaestro/dependent-fixture/"
  kd_plugin "$M/vibemaestro/dependent-fixture/.tmp-x"; kd_reg "$R" "$sid" "dependent-fixture@vibemaestro=$M/vibemaestro/dependent-fixture/.tmp-x"
  kd_dep_refused "a version directory the launcher would not accept" "not under $M/vibemaestro/dependent-fixture/<version>"
  kd_plugin "$M/vibemaestro/dependent-fixture/latest"; kd_reg "$R" "$sid" "dependent-fixture@vibemaestro=$M/vibemaestro/dependent-fixture/latest"
  kd_dep_refused "a version directory named latest" "not under $M/vibemaestro/dependent-fixture/<version>"
  kd_plugin "$M/vibemaestro/man-link/1.0.0"; mv "$M/vibemaestro/man-link/1.0.0/.claude-plugin/plugin.json" "$W/man-link.json"
  ln -s "$W/man-link.json" "$M/vibemaestro/man-link/1.0.0/.claude-plugin/plugin.json"; kd_reg "$R" "$sid" "man-link@vibemaestro=$M/vibemaestro/man-link/1.0.0"
  kd_dep_refused "a plugin.json that is a symlink" "reached through a symlink"
  kd_plugin "$M/vibemaestro/dir-link/1.0.0"; mv "$M/vibemaestro/dir-link/1.0.0/.claude-plugin" "$W/dir-link-cp"
  ln -s "$W/dir-link-cp" "$M/vibemaestro/dir-link/1.0.0/.claude-plugin"; kd_reg "$R" "$sid" "dir-link@vibemaestro=$M/vibemaestro/dir-link/1.0.0"
  kd_dep_refused "a .claude-plugin/ that is a symlink" "reached through a symlink"
  ln -s "$D" "$M/vibemaestro/dependent-fixture/9.9.9"; kd_reg "$R" "$sid" "dependent-fixture@vibemaestro=$M/vibemaestro/dependent-fixture/9.9.9"
  eq "$(bt "$S" "$W" rehearse kit:fixture-kit "$W/c.txt" hi)" 0 "[kit-dep] an installPath through a link to the same install: its real path decides, rc 0"
  rm -f "$M/vibemaestro/dependent-fixture/9.9.9"
  # a git-subdir plugin source (measured 22/10): Claude Code names the install directory <12 hex>-<8 hex>
  kd_plugin "$M/vibemaestro/dependent-fixture/3d15f5b67818-adc9e2e3"
  kd_reg "$R" "$sid" "dependent-fixture@vibemaestro=$M/vibemaestro/dependent-fixture/3d15f5b67818-adc9e2e3"
  eq "$(bt "$S" "$W" rehearse kit:fixture-kit "$W/c.txt" hi)" 0 "[kit-dep] a dependent plugin at a git-subdir directory <12 hex>-<8 hex>: its kit runs, rc 0"
  has "$(cat "$BT_OUT")" "root=$M/vibemaestro/dependent-fixture/3d15f5b67818-adc9e2e3" "[kit-dep] …from that install"
  kd_plugin "$M/vibemaestro/dependent-fixture/3d15f5b67818-adc9e2e"
  kd_reg "$R" "$sid" "dependent-fixture@vibemaestro=$M/vibemaestro/dependent-fixture/3d15f5b67818-adc9e2e"
  kd_dep_refused "a git-subdir directory with 7 hex after the dash" "not under $M/vibemaestro/dependent-fixture/<version>"
  kd_reg "$R" "$sid" "$did"
  cp "$KD_FIX/batons/fixture-kit.sh" "$S/batons/fixture-kit.sh"
  kd_dep_refused "a kit name sdlc also ships" "both vibemaestro-sdlc and dependent-fixture@vibemaestro ship batons/fixture-kit.sh"
  rm -f "$S/batons/fixture-kit.sh"
  kd_plugin "$M/vibemaestro/dep-two/1.0.0"; kd_reg "$R" "$sid" "$did" "dep-two@vibemaestro=$M/vibemaestro/dep-two/1.0.0"
  kd_dep_refused "two dependent plugins ship the name" "dep-two@vibemaestro and dependent-fixture@vibemaestro both ship"
  cp "$KD_FIX/batons/fixture-kit.sh" "$S/batons/fixture-kit.sh"
  kd_dep_refused "sdlc and two dependent plugins ship the name" \
    "both vibemaestro-sdlc and dep-two@vibemaestro and dependent-fixture@vibemaestro ship batons/fixture-kit.sh"
  rm -f "$S/batons/fixture-kit.sh"
  kd_plugin "$M/vibemaestro/linked/1.0.0"; rm -rf "$M/vibemaestro/linked/1.0.0/batons"; ln -s "$D/batons" "$M/vibemaestro/linked/1.0.0/batons"
  kd_reg "$R" "$sid" "linked@vibemaestro=$M/vibemaestro/linked/1.0.0"
  kd_dep_refused "a batons/ that is a symlink" "leads outside"
  kd_plugin "$M/vibemaestro/kit-link/1.0.0"; ln -sf "$D/batons/fixture-kit.sh" "$M/vibemaestro/kit-link/1.0.0/batons/fixture-kit.sh"
  kd_reg "$R" "$sid" "kit-link@vibemaestro=$M/vibemaestro/kit-link/1.0.0"
  kd_dep_refused "a kit file that is a symlink out of its batons/" "leads outside"
  kd_plugin "$M/vibemaestro/deep/1.0.0"; python3 -c 'import sys; open(sys.argv[1], "w").write("[" * 60000 + "]" * 60000)' \
    "$M/vibemaestro/deep/1.0.0/.claude-plugin/plugin.json"
  kd_reg "$R" "$sid" "deep@vibemaestro=$M/vibemaestro/deep/1.0.0"
  kd_dep_refused "a manifest nested too deep to parse" "deep@vibemaestro ships batons/fixture-kit.sh but its manifest cannot be read"
  # where the registry is read from: beside the running copy (a link there is followed, as the launcher does), never from the
  # environment
  kd_reg "$W/reg.json" "$sid" "$did"; rm -f "$R"; ln -s "$W/reg.json" "$R"
  eq "$(bt "$S" "$W" rehearse kit:fixture-kit "$W/c.txt" hi)" 0 "[kit-dep] a registry that is a link: followed, rc 0"
  rm -f "$R"
  kd_reg "$R" "vibemaestro-sdlc@vibemaestro=$M/vibemaestro/vibemaestro-sdlc/0.9.0" "$did"
  eq "$(bt "$S" "$W" rehearse kit:fixture-kit "$W/c.txt" hi)" 66 "[kit-dep] a registry that does not list this sdlc copy: rc 66"
  has "$(cat "$BT_OUT")" "does not list vibemaestro-sdlc@vibemaestro at $S" "[kit-dep] …named"
  kd_reg "$R" "$sid" "$did"; python3 -c 'import json, sys; d = json.load(open(sys.argv[1])); d["version"] = 1; json.dump(d, open(sys.argv[1], "w"))' "$R"
  eq "$(bt "$S" "$W" rehearse kit:fixture-kit "$W/c.txt" hi)" 66 "[kit-dep] a registry of another version (the same plugins): rc 66"
  has "$(cat "$BT_OUT")" "is not a version-2 registry" "[kit-dep] …a registry of another version: named"
  kd_reg "$R" "$sid" "$did"
  eq "$(bt "$P" "$W" rehearse kit:fixture-kit "$W/c.txt" hi)" 66 "[kit-dep] a baton.py outside the plugin cache: rc 66"
  has "$(cat "$BT_OUT")" "is not an installed copy" "[kit-dep] …named"
  BT_ENV=(CLAUDE_CONFIG_DIR="$C" HOME="$(dirname "$C")")
  eq "$(bt "$P" "$W" rehearse kit:fixture-kit "$W/c.txt" hi)" 66 "[kit-dep] …even with CLAUDE_CONFIG_DIR and HOME pointing at the registry: rc 66"
  BT_ENV=()
  [ ! -e "$W/c.txt" ] && ok "[kit-dep] no refused case wrote anything" || bad "[kit-dep] no refused case wrote anything"
}

# plugin scripts in a session baton: "$BATON_PLUGIN_ROOT/scripts/<file>" only as the command a write() runs, as
# bash (.sh) or python3 -I -B (.py), its sha256 written in the plan line; the binding covers the plugin root, every file under
# its scripts/ and the PYTHON* variables; scripts/ is hashed again when the phase ends
ps_sha() { python3 -B -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"; }
# ps_baton <template> <out> <sha> [<extra line in the act>] — the template plus one write that runs scripts/t-tool.sh
ps_baton() {
  cp "$1" "$2"
  mutate "$2" 'write "create $DEST" put_text' \
    'write "create $DEST" put_text
  write "run t-tool.sh sha256 '"$3"' on $DEST" bash "$BATON_PLUGIN_ROOT/scripts/t-tool.sh" "$DEST"'
  mutate "$2" '# Expect: create *' $'# Expect: create *\n# Expect: run t-tool.sh *'
  [ -z "${4:-}" ] || in_act "$2" "$4"
}
fam_plugin_script() {
  local P=$1 W A f P2 line real sha
  fresh_state; W=$(fresh); A=$(act_in "$P" "$W"); real=$(cd "$P" && pwd -P)
  printf '#!/usr/bin/env bash\necho "tool ran root=$BATON_PLUGIN_ROOT pyc=${PYTHONPYCACHEPREFIX:-unset}"\ntouch "$1.tool"\n' > "$P/scripts/t-tool.sh"
  printf '#!/usr/bin/env bash\necho sibling\n' > "$P/scripts/t-sibling.sh"
  sha=$(ps_sha "$P/scripts/t-tool.sh")
  f="$W/ps.sh"; ps_baton "$A" "$f" "$sha"
  eq "$(bt "$P" "$W" check "$f")" 0 "[plugin-script] write \"…\" bash \"\$BATON_PLUGIN_ROOT/scripts/t-tool.sh\": check rc 0"
  eq "$(bt "$P" "$W" rehearse "$f" "$W/a.txt" hi)" 0 "[plugin-script] …rehearse with its sha256 in the plan: rc 0"
  [ ! -e "$W/a.txt.tool" ] && ok "[plugin-script] …rehearse did not run the plugin script" || bad "[plugin-script] …rehearse did not run the plugin script"
  eq "$(sg "$P" "$W" owner "$f" "$W/a.txt" hi)" 0 "[plugin-script] sign: rc 0"
  BT_ENV=(BATON_PLUGIN_ROOT=/planted)
  eq "$(bt "$P" "$W" run "$f" "$W/a.txt" hi)" 0 "[plugin-script] …run (a caller sets BATON_PLUGIN_ROOT=/planted): rc 0"
  BT_ENV=()
  has "$(runout)" "tool ran root=$real pyc=" "[plugin-script] …the run ran it with the real plugin root, whatever the caller set"
  hasnt "$(runout)" "pyc=unset" "[plugin-script] …and with a bytecode directory of its own"
  [ -e "$W/a.txt.tool" ] && ok "[plugin-script] …the plugin script ran in the run phase" || bad "[plugin-script] …the plugin script ran in the run phase"
  # the root is there only where write() runs: an indirection in rehearse finds nothing to run
  f="$W/ps-ind.sh"; ps_baton "$A" "$f" "$sha" 'p=BATON_PLUGIN_; p+=ROOT; echo "seen=${!p}"'
  eq "$(bt "$P" "$W" rehearse "$f" "$W/i.txt" hi)" 0 "[plugin-script] a baton that reads the root through an indirection: rehearse rc 0"
  has "$(cat "$BT_OUT")" "/no-plugin-root-in-rehearse" "[plugin-script] …the rehearse phase gets no real plugin root"
  # the plan must carry the sha of the bytes the runner reads, as a whole word
  f="$W/ps-other.sh"; ps_baton "$A" "$f" "$(ps_sha "$P/scripts/t-sibling.sh")"
  eq "$(bt "$P" "$W" rehearse "$f" "$W/b.txt" hi)" 1 "[plugin-script] a plan line with the sha of another file: rehearse rc 1"
  has "$(cat "$BT_OUT")" "is in no plan line" "[plugin-script] …the reason names the missing sha"
  f="$W/ps-sub.sh"; ps_baton "$A" "$f" "0${sha}"
  eq "$(bt "$P" "$W" rehearse "$f" "$W/b.txt" hi)" 1 "[plugin-script] the sha only inside a longer hex word: rehearse rc 1"
  f="$W/ps.sh"; cp "$P/scripts/t-tool.sh" "$W/tool.keep"; printf 'echo edited\n' >> "$P/scripts/t-tool.sh"
  eq "$(bt "$P" "$W" rehearse "$f" "$W/b.txt" hi)" 1 "[plugin-script] a plugin script whose bytes differ from the sha in the plan: rehearse rc 1"
  cp "$W/tool.keep" "$P/scripts/t-tool.sh"
  # edited after signing: the tool, or a sibling under scripts/ (open-pr.sh calls open_pr.py); another plugin copy; PYTHONPATH
  eq "$(sg "$P" "$W" owner "$f" "$W/c.txt" hi)" 0 "[plugin-script] sign again: rc 0"
  printf 'echo edited\n' >> "$P/scripts/t-tool.sh"
  eq "$(bt "$P" "$W" run "$f" "$W/c.txt" hi)" 3 "[plugin-script] the plugin script edited after signing: run rc 3, nothing ran"
  cp "$W/tool.keep" "$P/scripts/t-tool.sh"
  eq "$(sg "$P" "$W" owner "$f" "$W/d.txt" hi)" 0 "[plugin-script] sign once more: rc 0"
  printf 'echo edited\n' >> "$P/scripts/t-sibling.sh"
  eq "$(bt "$P" "$W" run "$f" "$W/d.txt" hi)" 3 "[plugin-script] a sibling under scripts/ edited after signing: run rc 3"
  P2="$(fresh)/p2"; cp -r "$P" "$P2"
  eq "$(sg "$P" "$W" owner "$f" "$W/e.txt" hi)" 0 "[plugin-script] sign with one plugin copy: rc 0"
  eq "$(bt "$P2" "$W" run "$f" "$W/e.txt" hi)" 3 "[plugin-script] the same baton under a second plugin copy (same bytes): run rc 3"
  [ ! -e "$W/e.txt" ] && ok "[plugin-script] …nothing ran" || bad "[plugin-script] …nothing ran"
  eq "$(sg "$P" "$W" owner "$f" "$W/g.txt" hi)" 0 "[plugin-script] sign without PYTHONPATH: rc 0"
  BT_ENV=(PYTHONPATH="$W/evil")
  eq "$(bt "$P" "$W" run "$f" "$W/g.txt" hi)" 3 "[plugin-script] the run with a PYTHONPATH the signature did not see: rc 3"
  BT_ENV=()
  # scripts/ changed by the baton itself during the run: the runner sees it when the phase ends
  printf '#!/usr/bin/env bash\necho swapped\n' > "$W/evil.sh"
  f="$W/ps-swap.sh"; ps_baton "$A" "$f" "$sha"
  mutate "$f" 'write "create $DEST" put_text' "write \"create \$DEST\" put_text
  write \"copy over the tool\" cp \"$W/evil.sh\" \"$real/scripts/t-tool.sh\""
  mutate "$f" '# Expect: create *' $'# Expect: create *\n# Expect: copy over the tool'
  eq "$(sg "$P" "$W" owner "$f" "$W/h.txt" hi)" 0 "[plugin-script] sign a baton that copies over the tool before it runs it: rc 0"
  ne "$(bt "$P" "$W" run "$f" "$W/h.txt" hi)" 0 "[plugin-script] …its run does not end ok"
  has "$(cat "$BT_OUT")" "changed during the phase" "[plugin-script] …the runner names scripts/ that changed during the phase"
  cp "$W/tool.keep" "$P/scripts/t-tool.sh"
  # refused at check: any other form, place, mention or file
  printf '#!/usr/bin/env bash\ntouch "%s/ran"\n' "$W" > "$W/outside.sh"
  for line in 'bash "$W/outside.sh"' 'bash "$BATON_PLUGIN_ROOT/scripts/../batons/merge-pr.sh"' \
              'bash "$BATON_PLUGIN_ROOT/scripts/t-tool.sh" "$DEST"' 'cp "$W/outside.sh" "$BATON_PLUGIN_ROOT/scripts/t-tool.sh"' \
              'R=$(dirname "$BATON_PLUGIN_ROOT/scripts/t-tool.sh")' 'sh "$BATON_PLUGIN_ROOT/scripts/t-tool.sh"' \
              '"$BATON_PLUGIN_ROOT/scripts/t-tool.sh"' 'bash "${BATON_PLUGIN_ROOT}/scripts/t-tool.sh"' \
              'BATON_PLUGIN_ROOT=/tmp' 'export BATON_PLUGIN_ROOT' 'echo "${BATON_PLUGIN_ROOT:-/x}"' \
              $'echo "R=$BATON_PLUGIN_\\\nROOT"' $'R="\n#$BATON_PLUGIN_ROOT"' 'true # "$BATON_PLUGIN_ROOT/scripts/t-tool.sh"'; do
    cp "$W/ps.sh" "$W/bad.sh"; in_act "$W/bad.sh" "$line"
    eq "$(bt "$P" "$W" check "$W/bad.sh")" 1 "[plugin-script] refused at check: $line"
  done
  cp "$P/scripts/baton.py" "$P/scripts/Baton.py"; ln "$P/scripts/baton.py" "$P/scripts/t-hard.py"
  for name in Baton.py baton.py t-hard.py t-none.sh ../batons/merge-pr.sh t-link.sh; do
    [ "$name" != t-link.sh ] || ln -sf "$W/outside.sh" "$P/scripts/t-link.sh"     # the one link, for its own case only
    cp "$A" "$W/bad.sh"
    mutate "$W/bad.sh" 'write "create $DEST" put_text' \
      'write "create $DEST" put_text
  write "run '"$name"' sha256 '"$sha"'" bash "$BATON_PLUGIN_ROOT/scripts/'"$name"'"'
    mutate "$W/bad.sh" '# Expect: create *' $'# Expect: create *\n# Expect: run *'
    [ "${name##*.}" = py ] && mutate "$W/bad.sh" 'bash "$BATON_PLUGIN_ROOT' 'python3 -I -B "$BATON_PLUGIN_ROOT'
    eq "$(bt "$P" "$W" check "$W/bad.sh")" 1 "[plugin-script] refused at check: the file scripts/$name"
  done
  rm -f "$P/scripts/t-link.sh" "$P/scripts/Baton.py" "$P/scripts/t-hard.py"
  mkdir -p "$W/ext"; ln -s "$W/ext" "$P/scripts/t-dir"
  eq "$(bt "$P" "$W" check "$W/ps.sh")" 1 "[plugin-script] refused at check: a link under scripts/ (a linked directory)"
  rm -f "$P/scripts/t-dir"
  [ ! -e "$W/ran" ] && ok "[plugin-script] …no refused target ever ran" || bad "[plugin-script] …no refused target ever ran"
  rm -f "$P/scripts/t-tool.sh" "$P/scripts/t-sibling.sh"
}

# `Each: <glob>` instead of Expect lines (the coordinator's conditions): kit batons only, a literal first character, the
# glob matched whole, no empty plan line, and exactly one PLAN-COUNT line whose number the plan has
fam_each() {
  local P=$1 W A f
  fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  f="$P/batons/t-each.sh"; cp "$A" "$f"; mutate "$f" '# Expect: create *' '# Each: create *'; mutate "$f" '# Stops: none' $'# Stops: none\n# Usage: <file> <text>'; in_act "$f" 'echo "PLAN-COUNT 1"'
  eq "$(bt "$P" "$W" check kit:t-each)" 0 "[each] check kit:t-each (Each: create *): rc 0"
  eq "$(bt "$P" "$W" rehearse kit:t-each "$W/a.txt" hi)" 0 "[each] rehearse: one plan line, PLAN-COUNT 1: rc 0"
  has "$(cat "$BT_OUT")" "  ok   create $W/a.txt  ~  create *" "[each] …the table matches the line against the Each glob"
  cp "$f" "$W/session.sh"
  eq "$(bt "$P" "$W" check "$W/session.sh")" 1 "[each] Each in a session baton: check rc 1"
  has "$(cat "$BT_OUT")" "Each is for kit batons" "[each] …named"
  cp "$f" "$P/batons/t-e2.sh"; mutate "$P/batons/t-e2.sh" '# Each: create *' $'# Each: create *\n# Expect: create *'
  eq "$(bt "$P" "$W" check kit:t-e2)" 1 "[each] Each beside an Expect line: check rc 1"
  cp "$f" "$P/batons/t-e2.sh"; mutate "$P/batons/t-e2.sh" '# Each: create *' $'# Each: create *\n# Each: create *'
  eq "$(bt "$P" "$W" check kit:t-e2)" 1 "[each] two Each lines: check rc 1"
  cp "$f" "$P/batons/t-e2.sh"; mutate "$P/batons/t-e2.sh" '# Each: create *' '# Each: *'
  eq "$(bt "$P" "$W" check kit:t-e2)" 1 "[each] an Each glob that starts with *: check rc 1"
  cp "$f" "$P/batons/t-e2.sh"; mutate "$P/batons/t-e2.sh" '# Each: create *' '# Each: create'
  eq "$(bt "$P" "$W" rehearse kit:t-e2 "$W/b.txt" hi)" 1 "[each] the glob is anchored: 'create' does not match 'create <path>', rc 1"
  cp "$f" "$P/batons/t-e2.sh"; mutate "$P/batons/t-e2.sh" '  echo "PLAN-COUNT 1"' '  :'
  eq "$(bt "$P" "$W" rehearse kit:t-e2 "$W/b.txt" hi)" 1 "[each] no PLAN-COUNT line: rehearse rc 1"
  cp "$f" "$P/batons/t-e2.sh"; in_act "$P/batons/t-e2.sh" 'echo "PLAN-COUNT 1"'
  eq "$(bt "$P" "$W" rehearse kit:t-e2 "$W/b.txt" hi)" 1 "[each] two PLAN-COUNT lines: rehearse rc 1"
  cp "$f" "$P/batons/t-e2.sh"; mutate "$P/batons/t-e2.sh" '  echo "PLAN-COUNT 1"' '  echo "PLAN-COUNT 2"'
  eq "$(bt "$P" "$W" rehearse kit:t-e2 "$W/b.txt" hi)" 1 "[each] PLAN-COUNT 2 for one plan line: rehearse rc 1"
  cp "$f" "$P/batons/t-e2.sh"; in_act "$P/batons/t-e2.sh" 'write "create extra" true'
  eq "$(bt "$P" "$W" rehearse kit:t-e2 "$W/b.txt" hi)" 1 "[each] a planted extra plan line (it matches the glob): rehearse rc 1"
  has "$(cat "$BT_OUT")" "PLAN-COUNT says 1" "[each] …the count names it"
  cp "$f" "$P/batons/t-e2.sh"; mutate "$P/batons/t-e2.sh" '  echo "PLAN-COUNT 1"' '  echo "PLAN-COUNT 2"'; in_act "$P/batons/t-e2.sh" 'write "" true'
  eq "$(bt "$P" "$W" rehearse kit:t-e2 "$W/b.txt" hi)" 1 "[each] an empty plan line: rehearse rc 1"
  bt "$P" "$W" mode auto >/dev/null
  eq "$(sg "$P" "$W" coordinator-auto kit:t-each "$W/c.txt" hi)" 0 "[each] sign kit:t-each: rc 0"
  eq "$(bt "$P" "$W" run kit:t-each "$W/c.txt" hi)" 0 "[each] …and run it: rc 0"
  rm -f "$P/batons/t-each.sh" "$P/batons/t-e2.sh"
}

# ── go: one command from check to log (one line holds the whole run) ────────────────────────────────────────
# go_fixture <template> <kind> — a copy of the template with one planted outcome; prints its path
go_fixture() {
  local f; f="$(dirname "$1")/go-$2.sh"; cp "$1" "$f"
  case "$2" in
    good) ;;
    check) mutate "$f" '# Undo: ' '# Undone: ' ;;
    verdict) mutate "$f" $'  write "create $DEST" put_text\n}' $'  write "create $DEST" put_text\n  exit 0\n}' ;;
    expect) mutate "$f" '# Expect: create *' '# Expect: delete *' ;;
    runfail) mutate "$f" $'  write "create $DEST" put_text\n}' $'  write "create $DEST" put_text\n  write "fail on purpose" false\n}'
             mutate "$f" '# Expect: create *' $'# Expect: create *\n# Expect: fail on purpose' ;;
    pcfail) mutate "$f" "$POSTCHECK_OK" "$POSTCHECK_NO" ;;
    undofail) mutate "$f" "$POSTCHECK_OK" "$POSTCHECK_NO"; mutate "$f" $'undo() {\n' $'undo() {\n  false\n' ;;
  esac
  printf '%s' "$f"
}
# verdicts <file> — the verdict lines both paths print: check, rehearse, sign and the run's end
verdicts() { grep -E '^(check: |rehearse FAILED|sign: |== run )' "$1"; }
# normlog — the log lines without time and run-output path (fields 2 to 11)
normlog() { cut -f2-11 "$(baton_dir)/log.tsv" 2>/dev/null; }
# sep_path <plugin> <dir> <script> [args...] — rehearse, sign --by coordinator-auto with its seal, run: each only after the one
# before passed. Prints the rc, the verdict lines and the log lines
sep_path() {
  local P=$1 W=$2 rc seal o; shift 2; o="$TMP/sep.out"; : > "$o"
  rc=$(bt "$P" "$W" rehearse "$@"); cat "$BT_OUT" >> "$o"
  if [ "$rc" = 0 ]; then
    seal=$(sed -n 's/^seal \([^ ]*\) .*/\1/p' "$BT_OUT")
    rc=$(bt "$P" "$W" sign --by coordinator-auto --seal "$seal" "$@"); cat "$BT_OUT" >> "$o"
  fi
  if [ "$rc" = 0 ]; then rc=$(bt "$P" "$W" run "$@"); runout >> "$o"; fi
  printf 'rc %s\n' "$rc"; verdicts "$o"; normlog
}
# runout — the whole output of the last `run`: the run log its one line names (`run: ok — … — <log>`), else what it printed
runout() { local l; l=$(sed -n 's/^run: ok — [0-9]* writes\{0,1\} — //p' "$BT_OUT"); cat "${l:-$BT_OUT}"; }
# golog — the run log a go output names (`go: ok — … — <log>` or `full output: <log>`), empty when it names none
golog() { sed -n -e 's/^go: ok — [0-9]* writes\{0,1\} — //p' -e 's/^full output: //p' "$BT_OUT" | tail -n 1; }
# go_path <plugin> <dir> <script> [args...] — the same through go; its output stays in $BT_OUT. The verdict lines come from the
# run log when go names one (it holds every step), else from what go printed
go_path() {
  local P=$1 W=$2 rc l; shift 2; rc=$(bt "$P" "$W" go "$@"); l=$(golog)
  printf 'rc %s\n' "$rc"; if [ -n "$l" ]; then verdicts "$l"; else verdicts "$BT_OUT"; fi; normlog
}

fam_go_equiv() {
  local P=$1 W A f kind want sep gone step
  W=$(fresh); fresh_state; A=$(act_in "$P" "$W")
  for kind in good check verdict expect runfail pcfail undofail; do
    f=$(go_fixture "$A" "$kind")
    case "$kind" in good) want=0;; check|verdict|expect) want=1;; runfail|pcfail) want=4;; undofail) want=5;; esac
    case "$kind" in check) step=check;; verdict) step=rehearse;; expect) step=plan-vs-Expect;; runfail) step=run;; *) step=post-check;; esac
    fresh_state; bt "$P" "$W" mode auto >/dev/null; rm -f "${W:?}/${kind:?}.txt"
    sep=$(sep_path "$P" "$W" "$f" "$W/$kind.txt" hello)
    fresh_state; bt "$P" "$W" mode auto >/dev/null; rm -f "${W:?}/${kind:?}.txt"
    gone=$(go_path "$P" "$W" "$f" "$W/$kind.txt" hello)
    eq "$(printf '%s\n' "$gone" | sed -n 1p)" "rc $want" "[go-equiv] $kind: go exits $want"
    eq "$gone" "$sep" "[go-equiv] $kind: go gives the separate commands' exit code, verdict lines and log lines"
    if [ "$kind" = good ]; then
      eq "$(cat "$W/$kind.txt" 2>/dev/null)" hello "[go-equiv] good: go wrote the file"
      eq "$(wc -l < "$BT_OUT" | tr -d ' ')" 1 "[go-ok] good: one line, stdout and stderr together"
      grep -q "^go: ok — 1 write — $(baton_dir)/runs/[^/]*\.log\$" "$BT_OUT" && ok "[go-ok] good: the line is 'go: ok — 1 write — <run log>'" \
        || bad "[go-ok] good: the line is 'go: ok — 1 write — <run log>' ($(head -c 300 "$BT_OUT"))"
      eq "$(golog)" "$(logcol 12)" "[go-ok] good: the line names this run's log"
      for step in "go: check ok" "== rehearse" "go: rehearse ok" "go: plan-vs-Expect ok (1 of 1 line)" "go: sign ok" "== run" "  DO create " "== postcheck" "  VERDICT postcheck ok"; do
        grep -q "^$step" "$(golog)" && ok "[go-steps] good: the run log holds '$step'" || bad "[go-steps] good: the run log holds '$step'"
      done
      grep -q '^go: seal [0-9a-f]\{16\}\.[0-9a-f]\{16\}$' "$(golog)" && ok "[go-steps] good: the seal is in the run log" || bad "[go-steps] good: the seal is in the run log"
    else
      grep -q "^go: stopped at $step " "$BT_OUT" && ok "[go-steps] $kind: stopped at $step" || bad "[go-steps] $kind: stopped at $step"
      hasnt "$(cat "$BT_OUT")" "go: ok" "[go-ok] $kind: no 'go: ok'"
      case "$kind" in
        check) w="FAIL ";; verdict) w="== rehearse";; expect) w="== plan against Expect";; runfail) w="== undo";; *) w="== postcheck";;
      esac
      grep -q "^$w" "$BT_OUT" && ok "[go-fail] $kind: the step's output is printed ('$w')" || bad "[go-fail] $kind: the step's output is printed ('$w')"
      case "$kind" in runfail|pcfail|undofail)
        grep -q '^  DO create ' "$BT_OUT" && ok "[go-fail] $kind: the run step's output is printed (its DO line)" \
          || bad "[go-fail] $kind: the run step's output is printed (its DO line)"
        [ -f "$(golog)" ] && ok "[go-fail] $kind: 'full output:' names the run log" || bad "[go-fail] $kind: 'full output:' names the run log";;
      esac
    fi
  done
  hasnt "$(normlog | cut -f9)" "ok" "[go-equiv] a post-check that fails and an undo that fails never log ok"
}

# card_line <text> — the number of the first output line that starts with <text> (0 when there is none)
card_line() { local n; n=$(grep -n -m1 -F -- "$1" "$BT_OUT" | cut -d: -f1); printf '%s' "${n:-0}"; }
fam_go_owner() {
  local P=$1 W A f S cmd field n detail last kase
  fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  f="$W/stop.sh"; cp "$A" "$f"; mutate "$f" '# Stops: none' '# Stops: publish, secrets'
  for kase in auto-stops manual-none; do
    fresh_state
    if [ "$kase" = auto-stops ]; then bt "$P" "$W" mode auto >/dev/null; S="$f"; else S="$A"; fi
    rm -f "${W:?}/o.txt"
    eq "$(bt "$P" "$W" go "$S" "$W/o.txt" hello)" 8 "[go-owner] $kase: exit 8 after rehearse"
    eq "$(nsig)" 0 "[go-owner] $kase: nothing signed"
    eq "$(cut -f2 "$(baton_dir)/log.tsv" 2>/dev/null | grep -c -E '^(sign|run)$')" 0 "[go-owner] $kase: no sign or run line in the log"
    [ ! -e "$W/o.txt" ] && ok "[go-owner] $kase: nothing written" || bad "[go-owner] $kase: nothing written"
    case "$(head -n 1 "$BT_OUT")" in "== OWNER DECISION: "*) ok "[go-card] $kase: the output starts with the card";;
      *) bad "[go-card] $kase: the output starts with the card";; esac
    detail=$(card_line "detail: "); last=0
    for field in "== OWNER DECISION: " "  What:     1 write to the file named by the first argument" "              1. create $W/o.txt" \
                 "  Why:      example act, replace it" "  Blast:    that one file" "  Undo:     removes the file" \
                 "  Checked:  check ok; rehearse ok; plan matches Expect (1 of 1 line); 1 write"; do
      n=$(card_line "$field")
      [ "$n" -gt "$last" ] && [ "$n" -lt "$detail" ] && ok "[go-card] $kase: '$field' on the card, in order" \
        || bad "[go-card] $kase: '$field' on the card, in order (line $n, after $last, detail at $detail)"
      last=$n
    done
    if [ "$kase" = auto-stops ]; then field="  Stop:     publish, secrets"; else field="  Stop:     mode manual"; fi
    n=$(card_line "$field")
    [ "$n" -gt 0 ] && [ "$n" -lt "$detail" ] && ok "[go-card] $kase: the stop item is on the card" || bad "[go-card] $kase: the stop item is on the card"
    for field in "on the owner's go: " "then: "; do
      n=$(card_line "$field")
      [ "$n" -gt "$detail" ] && ok "[go-card] $kase: '$field' comes after the card" || bad "[go-card] $kase: '$field' comes after the card"
    done
    f2=$(sed -n 's/^detail: \(.*\) (check and rehearse output)$/\1/p' "$BT_OUT")
    for field in "== rehearse" "seal "; do
      eq "$(grep -c "^$field" "$BT_OUT")/$(grep -c "^$field" "$f2" 2>/dev/null)" "0/1" "[go-card] $kase: '$field' is in the detail file, not printed"
    done
    cmd=$(sed -n "s/^on the owner's go: //p" "$BT_OUT"); guard_cmd "$P" "$W" "$ST" "$OWNER_SID" "$cmd" >/dev/null
    eq "$( (cd "$W" && cenv XDG_STATE_HOME="$ST" CLAUDE_CODE_SESSION_ID="$OWNER_SID" bash -c "$cmd") >/dev/null 2>&1; echo $?)" 0 "[go-owner] $kase: the printed owner command signs"
    cmd=$(sed -n 's/^then: *//p' "$BT_OUT")
    eq "$( (cd "$W" && cenv XDG_STATE_HOME="$ST" bash -c "$cmd") >/dev/null 2>&1; echo $?)/$(cat "$W/o.txt" 2>/dev/null)" "0/hello" \
       "[go-owner] $kase: the printed run command runs it"
  done
  fresh_state; bt "$P" "$W" mode auto >/dev/null
  eq "$(bt "$P" "$W" go "$(go_fixture "$f" expect)" "$W/p.txt" hello)" 1 "[go-owner] a stop-list baton whose plan differs from Expect: exit 1, not 8"
  S="$W/esc.sh"; cp "$f" "$S"; mutate "$S" '# Undo: removes' $'# Undo: \e[1A\e[2Kremoves'
  eq "$(bt "$P" "$W" go "$S" "$W/q.txt" hello)" 8 "[go-card] instrument: a header with control characters passes check"
  n=$(card_line "detail: ")
  if head -n "$n" "$BT_OUT" | grep -qF '\u{1b}[1A\u{1b}[2Kremoves' && ! head -n "$n" "$BT_OUT" | grep -q $'\e'; then
    ok "[go-card] auto-stops: control characters on the card are escaped"
  else bad "[go-card] auto-stops: control characters on the card are escaped"; fi
  ! grep -q $'\e' "$BT_OUT" && ok "[go-card] …and nowhere in what go printed (nothing can redraw the card)" \
    || bad "[go-card] …and nowhere in what go printed (nothing can redraw the card)"
  cp "$f" "$W/-s.sh"
  eq "$(bt "$P" "$W" go -- -s.sh "$W/r.txt" hello)" 8 "[go-owner] a script path that starts with '-': exit 8"
  cmd=$(sed -n "s/^on the owner's go: //p" "$BT_OUT"); guard_cmd "$P" "$W" "$ST" "$OWNER_SID" "$cmd" >/dev/null
  eq "$( (cd "$W" && cenv XDG_STATE_HOME="$ST" CLAUDE_CODE_SESSION_ID="$OWNER_SID" bash -c "$cmd") >/dev/null 2>&1; echo $?)" 0 "[go-owner] …its printed owner command puts -- before the path and signs"
}

# gate_at <gate> <file> <n> — hold go inside its Nth rehearse (the act reads <gate>, a fifo), append a line to <file>, release it.
# The fixture runs in the background (its pid in GATE_PID); this returns once its first gate exists, so go is started after it: a go
# started first could pass its first rehearse before the gate was made (seen on CI under load, `0/run/ok`).
gate_at() {
  local ready="$TMP/gate-ready"; rm -f "$ready"; mkfifo "$ready"
  python3 "$HERE/fixtures/baton_gate.py" "$@" > "$ready" & GATE_PID=$!
  read -r _ < "$ready"; rm -f "$ready"
}
fam_go_attack() {
  local P=$1 W A f nth pid w
  fresh_state; W=$(fresh); A=$(act_in "$P" "$W"); bt "$P" "$W" mode auto >/dev/null
  eq "$(bt "$P" "$W" go --by owner "$A" "$W/a.txt" hello)" 64 "[go-attack] go --by owner: 64"
  eq "$(bt "$P" "$W" go --by=owner "$A" "$W/a.txt" hello)" 64 "[go-attack] go --by=owner: 64"
  eq "$(bt "$P" "$W" go --by coordinator-auto --by owner "$A" "$W/a.txt" hello)" 64 "[go-attack] go --by coordinator-auto --by owner: 64"
  eq "$(bt "$P" "$W" go --seal 0123456789abcdef.0123456789abcdef "$A" "$W/a.txt" hello)" 64 "[go-attack] go --seal: 64"
  eq "$(nsig)/$(find "$W" -name a.txt | wc -l | tr -d ' ')" "0/0" "[go-attack] …nothing signed, nothing written"
  eq "$(bt "$P" "$W" go --by coordinator-auto "$A" "$W/a.txt" hello)" 0 "[go-attack] control: go --by coordinator-auto runs"
  f="$W/gate.sh"
  for nth in 1 2; do
    cp "$A" "$f"; in_act "$f" 'if [ -p "$DEST.gate" ]; then cat "$DEST.gate" >/dev/null; fi'
    eq "$(bt "$P" "$W" check "$f")" 0 "[go-attack] instrument: the gated script passes check"
    gate_at "$W/e$nth.txt.gate" "$f" "$nth"
    ( bt "$P" "$W" go "$f" "$W/e$nth.txt" hello > "$TMP/go-rc" ) & pid=$!
    wait "$GATE_PID"; wait "$pid"
    eq "$(cat "$TMP/go-rc")" 3 "[go-attack] the script edited inside rehearse $nth of go (1: before its sign, 2: between sign and run): exit 3"
    [ ! -e "$W/e$nth.txt" ] && ok "[go-attack] …nothing ran ($nth)" || bad "[go-attack] …nothing ran ($nth)"
    if [ "$nth" = 1 ]; then w="go: stopped at sign (exit 3): sign refused: the seal now is"; else w="go: stopped at run (exit 3): run refused, nothing ran: the script changed"; fi
    grep -qF "$w" "$BT_OUT" && ok "[go-attack] …the stop line gives the reason ($nth)" || bad "[go-attack] …the stop line gives the reason ($nth)"
    if [ "$nth" = 1 ]; then
      grep -q '^== rehearse$' "$BT_OUT" && ok "[go-fail] sign: the sign step's output is printed" || bad "[go-fail] sign: the sign step's output is printed"
    fi
    if [ "$nth" = 2 ]; then
      eq "$(nsig)/$(logcol 2)/$(logcol 10)" "0/sign/withdrawn" "[go-attack] …the signature go made was withdrawn (2)"
    fi
  done
  # an interrupt between go's signature and the run's own guard: the signature go made is withdrawn, one another signer replaced is not
  eq "$( (cd "$W" && cenv XDG_STATE_HOME="$ST" python3 "$HERE/fixtures/baton_go_interrupt.py" "$P/scripts" keep go "$A" "$W/i.txt" hello) 2>/dev/null | tail -n 1)" \
     "rc 3; signatures 0; last sign withdrawn" "[go-attack] an interrupt between sign and run: exit 3, the signature withdrawn"
  eq "$( (cd "$W" && cenv XDG_STATE_HOME="$ST" python3 "$HERE/fixtures/baton_go_interrupt.py" "$P/scripts" replace go "$A" "$W/j.txt" hello) 2>/dev/null | tail -n 1)" \
     "rc 3; signatures 1; last sign signed" "[go-attack] …a signature file another signer rewrote meanwhile stays"
  rm -f "${ST:?}"/vibemaestro/baton/signatures/*.json
  f="$W/world.sh"; cp "$A" "$f"; mutate "$f" '  write "create $DEST" put_text' '  write "create $DEST from $(cat "$DEST.src")" put_text'
  in_act "$f" 'if [ -p "$DEST.gate" ]; then cat "$DEST.gate" >/dev/null; fi'
  echo v1 > "$W/w.txt.src"
  gate_at "$W/w.txt.gate" "$W/w.txt.src" 3
  ( bt "$P" "$W" go "$f" "$W/w.txt" hello > "$TMP/go-rc" ) & pid=$!
  wait "$GATE_PID"; wait "$pid"
  eq "$(cat "$TMP/go-rc")/$(find "$W" -name w.txt | wc -l | tr -d ' ')" "3/0" "[go-attack] the plan changed after go signed it (inside the run's own rehearse): exit 3, nothing ran"
}

# waits_of <plugin> [NAME=value] — the post-check schedule baton.py reads in that environment
waits_of() { local P=$1; shift; env -u BATON_POSTCHECK_WAITS "$@" python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import baton; print(baton.postcheck_waits())' "$P/scripts" 2>/dev/null; }
# the bounded post-check retry (spec Mục tiêu 12): the late act's post-check holds from its second reading on
fam_go_retry() {
  local P=$1 W A f v
  fresh_state; W=$(fresh); A=$(act_in "$P" "$W"); bt "$P" "$W" mode auto >/dev/null
  f="$W/late.sh"; cp "$A" "$f"
  mutate "$f" "$POSTCHECK_OK" $'postcheck() {\n  n=$(cat "$DEST.reads" 2>/dev/null || echo 0)\n  echo $((n + 1)) > "$DEST.reads"\n  [ "$n" -ge 1 ] && holds_text\n}'
  eq "$(bt "$P" "$W" check "$f")" 0 "[go-retry] instrument: the late script passes check"
  BT_ENV=(BATON_POSTCHECK_WAITS="0 0")
  eq "$(bt "$P" "$W" go "$f" "$W/l.txt" hello)" 0 "[go-retry] a post-check that holds on its second reading: exit 0"
  eq "$(grep -c '^== post-check attempt' "$(golog)")/$(grep -c '^== run$' "$(golog)")/$(cat "$W/l.txt.reads" 2>/dev/null)" "1/1/2" \
     "[go-retry] …one failed-attempt line, the run phase ran once, the post-check read twice"
  eq "$(logcol 10)" ok "[go-retry] …logged ok"
  BT_ENV=(BATON_POSTCHECK_WAITS=99)
  eq "$(bt "$P" "$W" go "$A" "$W/v.txt" hello)/$(wc -l < "$BT_OUT" | tr -d ' ')" "0/1" "[go-retry] a BATON_POSTCHECK_WAITS that is ignored: go still prints one line"
  grep -q "^baton: BATON_POSTCHECK_WAITS='99' may only shorten" "$(golog)" && ok "[go-retry] …the warning is in the run log" \
    || bad "[go-retry] …the warning is in the run log"
  BT_ENV=(BATON_POSTCHECK_WAITS="0 0")
  eq "$(bt "$P" "$W" go "$(go_fixture "$A" pcfail)" "$W/n.txt" hello)" 4 "[go-retry] a post-check that never holds: exit 4"
  eq "$(grep -c '^== postcheck$' "$BT_OUT")/$(logcol 10)/$(logcol 11)" "3/postcheck-failed/yes" \
     "[go-retry] …exactly 3 readings for two waits, then postcheck-failed and undo"
  BT_ENV=()
  rm -f "${W:?}/t.txt"
  v=$( (cd "$W" && cenv XDG_STATE_HOME="$ST" BATON_POSTCHECK_WAITS="1 1" python3 "$HERE/fixtures/baton_term_at.py" --log-dir "$(baton_dir)/runs" "== post-check attempt 1" \
        python3 "$P/scripts/baton.py" go "$(go_fixture "$A" pcfail)" "$W/t.txt" hello) 2>/dev/null | tail -n 1)
  eq "$v/$(logcol 10)/$(logcol 11)/$(find "$W" -name t.txt | wc -l | tr -d ' ')" "rc 4/postcheck-failed/yes/0" \
     "[go-retry] SIGTERM while waiting to read again: exit 4, undone"
  ST="$(fresh)/st"$'\xff'; bt "$P" "$W" mode auto >/dev/null
  eq "$(bt "$P" "$W" go "$A" "$W/u.txt" hello)/$(grep -c '^go: ok — 1 write — ' "$BT_OUT")/$(logcol 10)" "0/1/ok" \
     "[go-retry] a state directory whose path is not UTF-8: go exits 0, prints its line and logs ok"
  eq "$(cenv python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import baton; print(baton.postcheck_waits())' "$P/scripts" 2>/dev/null)" \
     "()" "[go-retry] instrument: cenv's empty BATON_POSTCHECK_WAITS reads once"
  eq "$(waits_of "$P")" "(1, 2, 4, 8)" "[go-retry] the default schedule: 1 2 4 8 seconds"
  eq "$(waits_of "$P" BATON_POSTCHECK_WAITS="0.5 1")" "(0.5, 1.0)" "[go-retry] a shorter schedule is taken"
  eq "$(waits_of "$P" BATON_POSTCHECK_WAITS=9)" "(1, 2, 4, 8)" "[go-retry] a longer wait is ignored"
  eq "$(waits_of "$P" BATON_POSTCHECK_WAITS="1 1 1 1 1")" "(1, 2, 4, 8)" "[go-retry] more waits are ignored"
  eq "$(waits_of "$P" BATON_POSTCHECK_WAITS=x)" "(1, 2, 4, 8)" "[go-retry] a word that is not a number is ignored"
}

# ── what the skill says `check` refuses: the refusals no other family proves ─────────────────────────────────────────
fam_check_refuses() {
  local P=$1 W A f; fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  f="$W/r1.sh"; cp "$A" "$f"; mutate "$f" '# Stops: none' $'# Stops: none\n# Pre: given twice'
  eq "$(bt "$P" "$W" check "$f")" 1 "[check-refuses] a header field given twice: rc 1"
  f="$W/r2.sh"; cp "$A" "$f"; mutate "$f" $'# Expect: create *\n' ''
  eq "$(bt "$P" "$W" check "$f")" 1 "[check-refuses] no Expect line: rc 1"
  f="$W/r3.sh"; cp "$A" "$f"; mutate "$f" '# ── arguments and reads: every phase runs them ──' $'write() { :; }\n# ── arguments and reads'
  eq "$(bt "$P" "$W" check "$f")" 1 "[check-refuses] write() defined twice: rc 1"
  f="$W/r4.sh"; cp "$A" "$f"; mutate "$f" 'postcheck() {' 'postcheck_gone() {'
  eq "$(bt "$P" "$W" check "$f")" 1 "[check-refuses] no postcheck() function: rc 1"
  f="$W/r5.sh"; cp "$A" "$f"; mutate "$f" $'set -euo pipefail\n' ''
  eq "$(bt "$P" "$W" check "$f")" 1 "[check-refuses] no set -euo pipefail at all: rc 1"
}

# ── the skill's skeleton: a session writes a baton from it with no `new` and no template read ───────────────────
fam_skill_skeleton() {
  local P=$1 W f
  fresh_state; W=$(fresh); f="$W/skeleton.sh"; bt "$P" "$W" mode auto >/dev/null
  python3 - "$P/skills/batonrun/SKILL.md" "$f" <<'PY'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
a, b = "<!-- baton-skeleton -->\n```bash\n", "```\n<!-- /baton-skeleton -->"
open(sys.argv[2], "w").write(t[t.index(a) + len(a):t.index(b)] if a in t and b in t else "")
PY
  ne "$(grep -c . "$f")" 0 "[skeleton] instrument: the skill holds the skeleton between its markers"
  eq "$(bt "$P" "$W" check "$f")" 0 "[skeleton] it passes check as written"
  printf 'hi\n' > "$W/body.txt"
  eq "$(bt "$P" "$W" rehearse "$f" dest="$W/k.txt" body="$W/body.txt")" 0 "[skeleton] it rehearses with its values"
  eq "$(bt "$P" "$W" go "$f" dest="$W/k.txt" body="$W/body.txt")/$(cat "$W/k.txt" 2>/dev/null)" "0/hi" "[skeleton] go runs it: the file is written"
  eq "$(bt "$P" "$W" pack "$f" user:skeleton-put)" 0 "[skeleton] …and pack keeps it as written"
}

# ── go and a stale file: a session baton from a file written before this call is refused, unless --reuse ──────────────
# age <file> <seconds> — the file's mtime set that many seconds back (negative: into the future)
age() { python3 -c 'import os, sys, time; t = time.time() - float(sys.argv[2]); os.utime(sys.argv[1], (t, t))' "$1" "$2"; }
fam_go_fresh() {
  local P=$1 W A f cmd
  fresh_state; W=$(fresh); A=$(act_in "$P" "$W"); bt "$P" "$W" mode auto >/dev/null
  f="$W/old.sh"; cp "$A" "$f"; age "$f" 600
  eq "$(bt "$P" "$W" go "$f" "$W/s1.txt" hello)" 1 "[go-fresh] a script last written 600 s ago: rc 1"
  eq "$(nsig)/$(find "$W" -name s1.txt | wc -l | tr -d ' ')/$(cut -f2 "$(baton_dir)/log.tsv" 2>/dev/null | grep -c -E '^(sign|run)$')" "0/0/0" \
     "[go-fresh] …nothing signed, nothing written, no sign or run line"
  has "$(cat "$BT_OUT")" "sha256 $(sha256sum "$f" | cut -c1-64); Purpose: example act, replace it" "[go-fresh] …it prints the file's sha256 and Purpose"
  cmd=$(sed -n 's/^  To run these very bytes again, after reading the sha256 and Purpose above: //p' "$BT_OUT")
  has "$cmd" " go --reuse " "[go-fresh] …and the exact command with --reuse"
  eq "$( (cd "$W" && cenv XDG_STATE_HOME="$ST" bash -c "$cmd") >/dev/null 2>&1; echo $?)/$(cat "$W/s1.txt" 2>/dev/null)" "0/hello" \
     "[go-fresh] the printed --reuse command runs those bytes"
  eq "$(grep -v "$(printf '\trun-start\t')" "$(baton_dir)/log.tsv" | tail -n 3 | cut -f2,10 | tr '\t\n' ': ')" "go:reuse sign:signed run:ok " "[go-fresh] …logged as a go reuse line, then sign and run"
  cp "$A" "$W/new.sh"
  eq "$(bt "$P" "$W" go "$W/new.sh" "$W/s2.txt" hello)" 0 "[go-fresh] control: a file written just now runs"
  ln -s "$f" "$W/link.sh"
  eq "$(bt "$P" "$W" go "$W/link.sh" "$W/s3.txt" hello)" 1 "[go-fresh] a fresh symlink to an old file: rc 1"
  ln "$f" "$W/hard.sh"
  eq "$(bt "$P" "$W" go "$W/hard.sh" "$W/s4.txt" hello)" 1 "[go-fresh] a fresh hard link to an old file: rc 1"
  cp "$A" "$W/future.sh"; age "$W/future.sh" -600
  eq "$(bt "$P" "$W" go "$W/future.sh" "$W/s5.txt" hello)" 1 "[go-fresh] a file dated 600 s in the future: rc 1"
  cp "$A" "$W/edge.sh"; age "$W/edge.sh" 100
  eq "$(bt "$P" "$W" go "$W/edge.sh" "$W/s6.txt" hello)" 0 "[go-fresh] a file written 100 s ago (inside 120 s): runs"
  eq "$(bt "$P" "$W" go --reuse --by coordinator-auto "$f" "$W/s7.txt" hello)" 64 "[go-fresh] --reuse before --by: 64"
  eq "$(bt "$P" "$W" go --by coordinator-auto --reuse --reuse "$f" "$W/s7.txt" hello)" 64 "[go-fresh] --reuse twice: 64"
  eq "$(bt "$P" "$W" go --by coordinator-auto "$f" "$W/s7.txt" hello)" 1 "[go-fresh] with --by: still rc 1"
  has "$(cat "$BT_OUT")" "go --by coordinator-auto --reuse " "[go-fresh] …the printed command keeps --by"
  eq "$(bt "$P" "$W" rehearse "$f" "$W/s8.txt" hello)" 0 "[go-fresh] the separate commands do not look at the age (rehearse: rc 0)"
}

# ── check names the stop pattern it matched, and the skill lists the same patterns ─────────────────────────────────
fam_stop_hint() {
  local P=$1 W A f out
  fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  f="$W/h1.sh"; cp "$A" "$f"; in_act "$f" 'write "set TOKEN" gh secret set TOKEN --body x'
  eq "$(bt "$P" "$W" check "$f")" 1 "[stop-hint] gh secret set under 'Stops: none': check rc 1"
  out=$(cat "$BT_OUT")
  has "$out" 'looks like stop category `secrets`' "[stop-hint] the FAIL line names the category"
  has "$out" 'matched `gh secret` (`gh secret`)' "[stop-hint] …the pattern's label and the text it matched"
  has "$out" '`# Stops: secrets`' "[stop-hint] …and how to declare it"
  f="$W/h2.sh"; cp "$A" "$f"; in_act "$f" 'write "drain" kubectl --context prod drain node-1'
  eq "$(bt "$P" "$W" check "$f")" 1 "[stop-hint] kubectl drain: check rc 1"
  has "$(cat "$BT_OUT")" 'matched `kubectl … drain|cordon` (`kubectl --context prod drain`)' "[stop-hint] …names kubectl … drain|cordon"
  # a ref deleted without a push: a remote's directory is as writable as the clone
  local Z=0000000000000000000000000000000000000000 n=0 line lab
  refdel() {   # refdel <label> <line>: check rc 1 under Stops: none, the FAIL line names irreversible-delete and the label
    n=$((n + 1)); f="$W/rd$n.sh"; cp "$A" "$f"; in_act "$f" "$2"
    eq "$(bt "$P" "$W" check "$f")" 1 "[stop-hint] ${2%%$'\n'*}: flagged (check rc 1)"
    has "$(cat "$BT_OUT")" "looks like stop category \`irreversible-delete\`: matched \`$1\`" "[stop-hint] …as \`$1\`"
  }
  refok() {    # refok <line>: ordinary ref work in the session's own clone, check rc 0
    n=$((n + 1)); f="$W/ro$n.sh"; cp "$A" "$f"; in_act "$f" "$1"
    eq "$(bt "$P" "$W" check "$f")" 0 "[stop-hint] ${1%%$'\n'*}: not flagged (check rc 0)"
  }
  # two deletes a `Stops: none` baton once passed check with: update-ref -d in the remote's directory, a quoted :<ref> push
  refdel 'git update-ref -d|--delete' 'write "delete b" git --git-dir=$DEST update-ref -d refs/heads/feature/old 6a0252a'
  lab='git push --delete|-d|:<ref>'
  refdel "$lab" 'write "delete b" git push --force-with-lease="refs/heads/old:$DEST" origin ":refs/heads/old"'
  refdel "$lab" 'write "delete b" git push --force origin ":$DEST"'
  refdel "$lab" 'write "delete b" git push origin ":$DEST"'
  refdel "$lab" "write \"delete b\" git push origin ':\$DEST'"
  refdel "$lab" "write \"delete b\" git push origin ':refs/heads/old'"
  refdel "$lab" "write \"delete b\" git push origin '+:refs/heads/old'"
  refok 'write "push b" git push --force-with-lease="refs/heads/old:" origin "$DEST:refs/heads/old"'
  # a flagged branch delete names the kit for a merged GitHub branch; a tag delete does not
  n=$((n + 1)); f="$W/kh$n.sh"; cp "$A" "$f"; in_act "$f" 'write "delete b" git push origin --delete feat/x'
  eq "$(bt "$P" "$W" check "$f")" 1 "[stop-hint] git push --delete under Stops: none: check rc 1"
  has "$(cat "$BT_OUT")" 'deletes it with no owner signature' "[stop-hint] …the FAIL line names kit:branch-delete for a merged branch"
  # the kit proves the merge against the default branch only: the hint promises no protected base
  eq "$(grep -c 'merged into its default branch at a pinned head' "$BT_OUT")/$(grep -c 'protected' "$BT_OUT")" "1/0" \
    "[stop-hint] …the kit's reach is the default branch at a pinned head, no protected base"
  n=$((n + 1)); f="$W/kh$n.sh"; cp "$A" "$f"; in_act "$f" 'write "drop v1" git tag -d v1'
  eq "$(bt "$P" "$W" check "$f")/$(grep -c 'kit:branch-delete' "$BT_OUT")" "1/0" "[stop-hint] git tag -d: check rc 1, and no kit named (a tag needs the owner)"
  eq "$(python3 -c 'import importlib.util, sys
s = importlib.util.spec_from_file_location("b", sys.argv[1]); b = importlib.util.module_from_spec(s); s.loader.exec_module(b)
labels = {l for _c, l, _r in b.STOP_HINTS}
print(" ".join(l for l in b.BRANCH_DELETE_LABELS if l not in labels) or "none")' "$P/scripts/baton.py")" none "[stop-hint] every label the kit hint names is a stop pattern's label"
  lab='git update-ref -d|--delete'
  refdel "$lab" 'write "delete feature/old" git -C /lab/remote.git update-ref -d refs/heads/feature/old'
  refdel "$lab" 'write "delete v1" git --git-dir=/lab/remote.git update-ref --delete refs/tags/v1'
  refdel 'git update-ref <ref> 0{40}' "write \"delete x\" git update-ref -m 'drop it' refs/heads/x $Z"
  lab='update-ref --stdin: delete <ref>|update <ref> 0{40}|<heredoc or file>'
  refdel "$lab" "printf 'delete refs/heads/x\\n' | git -C /lab/remote.git update-ref --stdin"
  refdel "$lab" $'git -C /lab/remote.git update-ref --stdin <<\'OPS\'\ndelete refs/heads/x\nOPS'
  refdel "$lab" "echo \"update refs/heads/x $Z\" > \"\$DEST.ops\""
  refdel "$lab" "printf 'delete %s\\n' \"\$DEST\" | git update-ref --stdin -z"
  refdel "$lab" $'git -C "$DEST" update-ref --stdin <<OPS\ndelete $DEST\nOPS'
  refdel "$lab" 'git -C /lab/remote.git update-ref --stdin < "$DEST.ops"'
  refdel "$lab" 'cat "$DEST.ops" | git -C /lab/remote.git update-ref --stdin'
  refdel "$lab" 'for r in $DEST; do echo "delete $r"; done | git -C /lab/remote.git update-ref --stdin'
  refdel "$lab" '/bin/cat "$DEST.ops" | git -C /lab/remote.git update-ref --stdin'
  refdel "$lab" 'if true; then cat "$DEST.ops" | git -C /lab/remote.git update-ref --stdin; fi'
  refdel "$lab" 'sudo cat "$DEST.ops" | git -C /lab/remote.git update-ref --stdin'
  refdel "$lab" 'printf x | (cat) | git -C /lab/remote.git update-ref --stdin'
  lab='git branch -D|-d -f|--delete --force'
  refdel "$lab" 'write "drop x" git branch -D feat/x'
  refdel "$lab" 'write "drop x" git -C /lab/remote.git branch --delete --force feat/x'
  refdel "$lab" 'write "drop x" git branch -Dq feat/x'
  refdel "$lab" 'write "drop x" git branch -df feat/x'
  refdel "$lab" 'write "drop x" git branch -d -fq feat/x'
  lab='git -C|--git-dir|--work-tree|GIT_DIR=<dir> branch -d|-f|-M|-C|--delete|--force'
  refdel "$lab" 'write "drop x" git -C /lab/remote.git branch -d feature/old'
  refdel "$lab" 'write "drop x" env GIT_DIR=/lab/remote.git git branch --delete feature/old'
  refdel "$lab" 'write "overwrite x" git -C /lab/remote.git branch -M scratch feature/old'
  refdel "$lab" 'write "drop x" git -C /lab/remote.git branch -dr origin/feature/old'
  refdel 'git update-ref -d|--delete' 'write "delete x" git -P -C /lab/remote update-ref -d refs/heads/x'
  refdel 'git tag -d|--delete' 'write "drop v1" git tag -d v1'
  lab='rm|unlink|mv|truncate|shred|find -delete|-exec rm|> … refs/'
  refdel "$lab" 'write "drop x" rm -f /lab/remote.git/refs/heads/feature/old'
  refdel "$lab" 'write "drop all" find "$DEST/refs/heads" -name old -delete'
  refdel "$lab" 'write "drop all" find /lab/remote.git/refs/heads -name old -exec rm {} +'
  refdel "$lab" ': > /lab/remote.git/refs/heads/old'
  refdel "$lab" ': > "$DEST"/refs/heads/old'
  refdel "$lab" 'write "drop all" rm -rf "$DEST"/refs/*'
  refdel "$lab" 'write "drop all" rm -rf /lab/remote.git/refs/'
  refdel "$lab" 'write "drop all" find "$DEST/refs/" -type f -delete'
  refdel "$lab" 'write "drop backup" rm -rf "$DEST/refs/original"'
  refdel "$lab" 'write "drop all" find /lab/remote.git/refs/heads -exec /bin/rm {} +'
  lab='packed-refs written: >|tee|sed -i|perl -i|dd of=|rm|mv|truncate|cp onto'
  refdel "$lab" "write \"drop x\" sed -i '/feature/d' /lab/remote.git/packed-refs"
  refdel "$lab" 'grep -v feature "$DEST.bak" > /lab/remote.git/packed-refs'
  refdel "$lab" 'write "restore" cp "$DEST.bak" /lab/remote.git/packed-refs'
  refok 'write "move x" git update-ref refs/heads/x 0123456789abcdef0123456789abcdef01234567'
  refok "write \"create x\" git update-ref refs/heads/x 0123456789abcdef0123456789abcdef01234567 $Z"
  refok 'write "pin" git -C "$DEST" update-ref refs/trial/pin1 0123456789abcdef0123456789abcdef01234567'
  refok "printf 'create refs/heads/x %s\\n' \"\$DEST\" | git update-ref --stdin"
  refok 'write "drop merged x" git branch -d feat/x'
  refok 'write "tag v1" git tag -a v1 -m "release v1"'
  refok 'cp /lab/remote.git/packed-refs "$DEST.bak"'
  refok 'rm -f "$DEST.packed-refs.bak"'
  refok "write \"edit\" sed -i 's/a/b/' docs/packed-refs.md"
  refok 'docker run --rm -v "$DEST:/w" img cat /w/refs/x'
  refok 'write "drop doc" git rm docs/refs/old.md'
  refok 'write "rename" mv "$DEST/refs/a.md" "$DEST/refs/b.md"'
  refok 'write "delete $DEST" rm -f -- "$DEST"'
  refok 'write "rename main" git branch -M main'
  refok 'git -C "$DEST" branch --sort -refname'
  refok "cat \"\$DEST.ver\"; printf 'create refs/heads/x %s\\n' \"\$DEST\" | git update-ref --stdin"
  refok "printf 'create refs/heads/cat %s\\n' \"\$DEST\" | git update-ref --stdin"
  refok '/opt/cat-tools/gen "$DEST" | git update-ref --stdin'
  refok 'cat.sh "$DEST" | git update-ref --stdin'
  refok 'echo x > "$DEST/refs.txt"'
  # the lint runs per body line: a long line of repeated stdin feeds stays far from cubic
  eq "$(within 5 python3 -c 'import importlib.util, re, sys
s = importlib.util.spec_from_file_location("b", sys.argv[1]); b = importlib.util.module_from_spec(s); s.loader.exec_module(b)
for line in ("git update-ref --stdin " * 1000, "cat <<x | " * 1000, "delete refs/heads/x " * 1000, "rm refs/ " * 1000,
             "cp settings.json " * 1000, "rm .claude/settings " * 1000, "x=.claude/settings " * 1000,
             "cp " * 3000 + "settings.json", "curl -o " * 1000, "${a:=" * 1000, "S=\"a " * 1000, "a=" * 5000, "S=\"" * 3000):
    [re.search(rx, line) for _c, _l, rx in b.STOP_HINTS]' "$P/scripts/baton.py")" 0 \
     "[stop-hint] the stop patterns on a 1000-fold line (update-ref --stdin, heredoc pipe, delete, rm refs/, settings): under 5 s"
  refok 'git -C /lab/remote.git rev-parse --verify -q refs/heads/feature/old'
  f="$W/rd-declared.sh"; cp "$A" "$f"; in_act "$f" 'write "delete x" git -C /lab/remote.git update-ref -d refs/heads/x'
  mutate "$f" '# Stops: none' '# Stops: irreversible-delete'
  eq "$(bt "$P" "$W" check "$f")" 0 "[stop-hint] the same delete declared (Stops: irreversible-delete): check rc 0"
  # a Claude Code settings file: the guard denies a plain-tool write that widens one, a baton's writes run where no hook sees
  # them; the plugin's own settings writers declare security-boundary and check clean
  local k
  for k in kind:settings-merge kit:coordinator-bootstrap kit:permissions-upgrade; do
    eq "$(bt "$P" "$W" check "$k")" 0 "[stop-hint] check $k (Stops: security-boundary): rc 0"
  done
  f="$W/allow.sh"; cp "$A" "$f"
  in_act "$f" "write \"allow Bash(*)\" python3 -I -c 'import json, sys; p = sys.argv[1]; s = json.load(open(p)); s.setdefault(\"permissions\", {}).setdefault(\"allow\", []).append(\"Bash(*)\"); json.dump(s, open(p, \"w\"))' \"\$HOME/.claude/settings.json\""
  eq "$(bt "$P" "$W" check "$f")" 1 "[stop-hint] a Stops: none baton that adds an allow rule to \$HOME/.claude/settings.json: check rc 1"
  has "$(cat "$BT_OUT")" 'looks like stop category `security-boundary`: matched `settings*.json under .claude|$CLAUDE_CONFIG_DIR written' \
    "[stop-hint] …as security-boundary, a settings write"
  mutate "$f" '# Stops: none' '# Stops: security-boundary'
  eq "$(bt "$P" "$W" check "$f")" 0 "[stop-hint] the same baton declared (Stops: security-boundary): check rc 0"
  local SW='settings*.json under .claude|$CLAUDE_CONFIG_DIR written: >|tee|rm|mv|ln|cp|install|rsync|sd|dd|curl|wget -o|sed|perl|ruby|yq|awk -i|git checkout|code|a write() or interpreter argument'
  local SH='settings*.json or its .claude|$CLAUDE_CONFIG_DIR directory held in a name: X=|x = |${X:=}|for x in'
  setw() {     # setw <label> <line>: check rc 1 under Stops: none, the FAIL line names security-boundary and the label
    n=$((n + 1)); f="$W/sw$n.sh"; cp "$A" "$f"; in_act "$f" "$2"
    eq "$(bt "$P" "$W" check "$f")" 1 "[stop-hint] ${2%%$'\n'*}: flagged (check rc 1)"
    has "$(cat "$BT_OUT")" "looks like stop category \`security-boundary\`: matched \`$1\`" "[stop-hint] …as \`${1%%:*}\`"
  }
  setw "$SW" 'jq ".permissions.allow += [\"Bash\"]" "$DEST" > "$HOME/.claude/settings.json"'
  setw "$SW" 'printf x >> "${CLAUDE_CONFIG_DIR}/settings.local.json"'
  setw "$SW" 'printf x | tee "$HOME/.claude/settings.json" >/dev/null'
  setw "$SW" 'write "add" cp "$DEST" "$HOME/.claude/settings.json"'
  setw "$SW" 'write "add" cp "$DEST/settings.json" ~/.claude/'
  setw "$SW" 'write "add" install -m 600 "$DEST" .claude/settings.local.json'
  setw "$SW" 'write "add" mv -f "$DEST" ~/.claude/settings.json'
  setw "$SW" 'write "add" ln -sf "$DEST" "$HOME/.claude/settings.json"'
  setw "$SW" 'write "drop" rm -f -- "$HOME/.claude/settings.local.json"'
  setw "$SW" "write \"add\" sed -i 's/\"deny\"/\"x\"/' \"\$HOME/.claude/settings.json\""
  setw "$SW" "write \"add\" perl -pi -e 's/a/b/' ~/.claude/settings.json"
  setw "$SW" "write \"add\" yq -i '.permissions.allow += [\"Bash\"]' \"\$HOME\"/.claude/settings.json"
  setw "$SW" 'write "add" dd if="$DEST" of="$HOME/.claude/settings.json"'
  setw "$SW" 'write "put back" git checkout -- .claude/settings.json'
  setw "$SW" 'write "add" cp "$DEST" /etc/claude-code/managed-settings.json'
  setw "$SW" $'python3 -I - "$DEST" <<\'PY\'\nimport json, os\nwith open(os.path.expanduser("~/.claude/settings.json"), "w") as f:\n    f.write("{}")\nPY'
  setw "$SW" $'python3 -I - <<\'PY\'\nfrom pathlib import Path\n(Path.home() / ".claude" / "settings.json").write_text("{}")\nPY'
  # review round 1: a redirection or comment after the copy, `$(…)` in the word, CLAUDE_CONFIG_DIR read in code, the macOS
  # managed path (a space in it), a directory copied whole into .claude
  setw "$SW" 'write "add" cp "$DEST" "$HOME/.claude/settings.json" 2>/dev/null'
  setw "$SW" 'write "add" cp "$DEST" "$HOME/.claude/settings.json"  # put it back'
  setw "$SW" 'echo "$DEST" > "$(git rev-parse --show-toplevel)/.claude/settings.json"'
  setw "$SW" 'printf x | tee "$(pwd)/.claude/settings.json"'
  setw "$SW" $'python3 -I - <<\'PY\'\nimport os\nwith open(os.path.join(os.environ["CLAUDE_CONFIG_DIR"], "settings.json"), "w") as f:\n    f.write("{}")\nPY'
  setw "$SW" 'echo "$DEST" > "/Library/Application Support/ClaudeCode/managed-settings.json"'
  setw "$SW" 'write "sync" rsync -a "$DEST/" ~/.claude/'
  # the path as an argument of write() (a helper that writes it) or of an interpreter whose program is a heredoc, a variable
  # named for the directory, flags with a digit or the long yq spelling, a download, pathlib's .open("w")
  setw "$SW" 'write "merge" merge_rules "$HOME/.claude/settings.json" "$DEST"'
  setw "$SW" $'write "add" python3 -I - "$HOME/.claude/settings.json" <<\'PY\'\nimport sys\nprint(sys.argv[1])\nPY'
  setw "$SW" 'cp "$DEST" "$CLAUDE_DIR/settings.json" 2>&1'
  setw "$SW" "perl -0pi -e 's/a/b/' \"\$HOME/.claude/settings.json\""
  setw "$SW" "yq eval --inplace '.a = 1' \"\$HOME/.claude/settings.json\""
  setw "$SW" 'curl -fsSL -o "$HOME/.claude/settings.json" "$DEST"'
  setw "$SW" $'python3 -I - <<\'PY\'\nfrom pathlib import Path\nwith (Path.home() / ".claude" / "settings.json").open("w") as f:\n    f.write("{}")\nPY'
  setw "$SH" 'S=$(git rev-parse --show-toplevel)/.claude/settings.json'
  setw "$SH" 'S="$HOME/.claude/settings.json"'
  setw "$SH" 'S="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"'
  setw "$SH" $'python3 -I - <<\'PY\'\nimport os\np = os.path.join(os.path.expanduser("~"), ".claude", "settings.json")\nPY'
  setw "$SH" 'for s in "$HOME"/.claude/settings*.json; do echo "$s"; done'
  setw "$SH" ': "${S:=$HOME/.claude/settings.json}"'
  # review round 2: quoted pieces inside the word, the path held through an operator, an f-string or a list
  setw "$SW" 'echo x > "$HOME/".claude/settings.json'
  setw "$SW" "echo x > ~/'.claude'/settings.json"
  setw "$SW" 'echo x > `pwd`/.claude/settings.json'
  setw "$SH" $'python3 -I - <<\'PY\'\nfrom pathlib import Path\np = Path.home() / ".claude" / "settings.json"\nq = f"{Path.home()}/.claude/settings.json"\nPY'
  setw "$SH" $'python3 -I - <<\'PY\'\npaths = ["~/.claude/settings.json"]\nPY'
  # review round 3: a curl with headers before -o, `+ "/settings.json"`, a quoted .claude or a spaced redirection after a copy
  setw "$SW" 'curl -fsSL --retry 3 --connect-timeout 10 -H "Authorization: Bearer $DEST" -H "Accept: application/vnd.github.raw+json" -H "X-GitHub-Api-Version: 2022-11-28" "https://api.github.com/repos/o/some-long-repository-name/contents/a/b/c/settings.json?ref=refs/heads/main" --output "$HOME/.claude/settings.json"'
  setw "$SH" $'python3 -I - <<\'PY\'\nimport os\np = os.environ["CLAUDE_CONFIG_DIR"] + "/settings.json"\nPY'
  setw "$SW" "write \"sync\" cp -r \"\$DEST\" ~/'.claude'"
  setw "$SW" 'write "sync" cp -r "$DEST/" "$HOME/.claude/" > /dev/null'
  # the natural two-line write: the path in a name, then a write through it; the FAIL line says what to do
  n=$((n + 1)); f="$W/sw$n.sh"; cp "$A" "$f"; in_act "$f" $'S="$HOME/.claude/settings.json"\n  write "add" mv -f "$DEST" "$S"'
  eq "$(bt "$P" "$W" check "$f")" 1 "[stop-hint] the path in a name, then mv onto \"\$S\": check rc 1"
  has "$(cat "$BT_OUT")" 'declare it all the same, or name the path written out in the command that reads it' "[stop-hint] …the FAIL line says how a read-only baton passes"
  setok() {    # setok <line>: a read of the settings file, or a file that is not one: check rc 0
    n=$((n + 1)); f="$W/so$n.sh"; cp "$A" "$f"; in_act "$f" "$1"
    eq "$(bt "$P" "$W" check "$f")" 0 "[stop-hint] ${1%%$'\n'*}: not flagged (check rc 0)"
  }
  setok 'cp "$HOME/.claude/settings.json" "$DEST.bak"'
  setok 'jq . "$HOME/.claude/settings.json"'
  setok 'grep -c allow "$HOME/.claude/settings.json" > "$DEST.count"'
  setok 'write "copy" cp "$DEST" "$HOME/.claude/settings.json.bak"'
  setok 'echo x > "$DEST/docs/settings.json"'
  setok 'echo x > "$DEST/.claude/settings.md"'
  setok 'docker run --rm -v "$HOME/.claude/settings.json:/s.json:ro" img cat /s.json'
  setok 'S=$1'
  setok 'echo "see settings-merge.sh" > "$DEST"'
  # the read the FAIL line recommends, kept in a name, and other reads that hold no path
  setok 'RULES="$(jq .permissions "$HOME/.claude/settings.json")"; echo "$RULES" > "$DEST"'
  setok 'x=1 jq . ~/.claude/settings.json'
  setok 'cp "$HOME/.claude/settings.json" "$DEST.bak" 2>/dev/null'
  setok 'SUM=$(sha256sum "$HOME/.claude/settings.json" | cut -c1-64); echo "$SUM" > "$DEST"'
  setok 'LC_ALL=C grep -c allow "$HOME/.claude/settings.json" > "$DEST.count"'
  setok "python3 -I -c 'import json, sys; json.dump(json.load(open(sys.argv[1])), sys.stdout)' \"\$HOME/.claude/settings.json\""
  setok "perl -Mstrict -ne 'print if /allow/' \"\$HOME/.claude/settings.json\""
  setok 'cp "$DEST" "$DEST/foo.claude/settings.json"'
  setok 'echo x > "$CFG/settings.json"'
  setok 'echo x > "$CLAUDE_PLUGIN_ROOT/settings.json"'
  setok 'ln -sr "$DEST" ~/.claude'
  setok 'mv -r "$DEST" ~/.claude'
  setok 'LOG=tmp/x jq . ~/.claude/settings.json'
  setok 'curl -fsSL "https://x/y?ref=refs/heads/main" | jq . ~/.claude/settings.json'
  setok 'X=`cat "$HOME/.claude/settings.json"`; echo "$X" > "$DEST"'
  setok $'python3 -I - <<\'PY\'\nimg = Image.open("a.png"); q = 1 if img else os.path.exists(".claude/settings.json")\nPY'
  setok $'python3 -I - <<\'PY\'\nimport os\nok = os.path.exists(os.path.expanduser("~/.claude/settings.json"))\nPY'
  setok $'python3 -I - <<\'PY\'\nimport json, os\ndata = json.load(open(file=os.path.expanduser("~/.claude/settings.json")))\nPY'
  setok '# write "add" cp "$DEST" "$HOME/.claude/settings.json"'
  out=$(python3 - "$P/skills/batonrun/limits.md" "$P/scripts/baton.py" <<'PY'
import importlib.util, re, sys
t = open(sys.argv[1], encoding="utf-8").read()
a, b = "<!-- stop-patterns -->\n", "<!-- /stop-patterns -->"
skill = set()
for ln in (t[t.index(a) + len(a):t.index(b)] if a in t and b in t else "").splitlines():
    m = re.match(r"^- `([a-z-]+)`: (.*)$", ln)
    if not m:
        print("unparsed line: " + ln); continue
    for lab in m.group(2).split("; "):
        skill.add((m.group(1), lab.strip().strip("`")))
s = importlib.util.spec_from_file_location("baton_under_test", sys.argv[2]); mod = importlib.util.module_from_spec(s)
s.loader.exec_module(mod)
code = {(c, l) for c, l, _r in mod.STOP_HINTS}
print("pairs %d" % len(code))
for x in sorted(code - skill): print("in code only: %s %s" % x)
for x in sorted(skill - code): print("in the skill only: %s %s" % x)
PY
)
  has "$out" "pairs 33" "[stop-hint] instrument: the code holds the 33 labelled patterns"
  eq "$(printf '%s\n' "$out" | grep -c -E '^(in |unparsed)')" 0 "[stop-hint] the pattern list (limits.md) equals STOP_HINTS' labels ($(printf '%s' "$out" | grep -E '^(in |unparsed)' | head -2 | tr '\n' ' '))"
}

# ── the skeleton's gh_state against a fake gh — exists, absent, and every other answer stops the script ────────────
# gh_fake <dir> — a gh that answers `gh api --include <path>` by GH_FAKE: 200, 200cr, 404, 500, net, bare404, 404rc0, 200rc1, junk404
gh_fake() {
  mkdir -p "$1"; cat > "$1/gh" <<'SH'
#!/bin/bash
[ "$1 $2" = "api --include" ] && [ $# -eq 3 ] || { echo "fake gh: unexpected arguments: $*" >&2; exit 99; }
case "$GH_FAKE" in
  200)    printf 'HTTP/2.0 200 OK\nContent-Type: application/json\n\n{"name":"x"}\n'; exit 0;;
  200cr)  printf 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{"name":"x"}\n'; exit 0;;
  404)    printf 'HTTP/2.0 404 Not Found\nContent-Type: application/json\n\n{"message":"Not Found","status":"404"}\n'
          echo 'gh: Not Found (HTTP 404)' >&2; exit 1;;
  500)    printf 'HTTP/2.0 500 Internal Server Error\n\n{"message":"Server Error"}\n'; echo 'gh: Server Error (HTTP 500)' >&2; exit 1;;
  net)    echo 'error connecting to api.github.com' >&2; exit 1;;
  bare404) printf '{"message":"Not Found","status":"404"}\n'; echo 'gh: Not Found (HTTP 404)' >&2; exit 1;;
  404rc0) printf 'HTTP/2.0 404 Not Found\n\n{"message":"Not Found"}\n'; exit 0;;
  200rc1) printf 'HTTP/2.0 200 OK\n\n{"name":"x"}\n'; exit 1;;
  junk404) printf 'Status: 404 Not Found\n\n{}\n'; exit 1;;
esac
SH
  chmod +x "$1/gh"
}
# ghs <dir> <case> <body> — the skeleton's gh_state in a set -euo pipefail bash, then <body>; prints "rc|stdout"
ghs() {
  local o rc
  o=$(cd "$1" && GH_FAKE=$2 PATH="$1/bin:$PATH" bash -c 'set -euo pipefail; eval "$(cat gh_state.fn)"; '"$3" 2>/dev/null); rc=$?
  printf '%s|%s' "$rc" "$o"
}
fam_gh_state() {
  local P=$1 W
  W=$(fresh); gh_fake "$W/bin"
  python3 - "$P/skills/batonrun/SKILL.md" "$W/gh_state.fn" <<'PY'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
a, b = "<!-- baton-skeleton -->\n```bash\n", "```\n<!-- /baton-skeleton -->"
sk = t[t.index(a) + len(a):t.index(b)] if a in t and b in t else ""
i = sk.find("gh_state() {\n"); j = sk.find("\n}\n", i)
open(sys.argv[2], "w").write(sk[i:j + 3] if i >= 0 and j > i else "")
PY
  ne "$(grep -c . "$W/gh_state.fn")" 0 "[gh-state] instrument: the skeleton holds gh_state()"
  eq "$(ghs "$W" 200 'gh_state repos/a/b/labels/x; echo "$GH_STATE"')" "0|exists" "[gh-state] 200 with exit 0: exists"
  eq "$(ghs "$W" 200cr 'gh_state repos/a/b/labels/x; echo "$GH_STATE"')" "0|exists" "[gh-state] 200 with CRLF headers: exists"
  eq "$(ghs "$W" 404 'gh_state repos/a/b/labels/x; echo "$GH_STATE"')" "0|absent" "[gh-state] 404 with a JSON body: absent"
  eq "$(ghs "$W" 500 'gh_state repos/a/b/labels/x; echo "after $GH_STATE"')" "75|" "[gh-state] 500: the script stops, exit 75"
  eq "$(ghs "$W" net 'gh_state repos/a/b/labels/x; echo "after $GH_STATE"')" "75|" "[gh-state] a network error (no status line): exit 75"
  eq "$(ghs "$W" bare404 'gh_state repos/a/b/labels/x; echo "after $GH_STATE"')" "75|" "[gh-state] a 404 JSON body without headers: exit 75, never exists"
  eq "$(ghs "$W" 500 'if gh_state repos/a/b/labels/x; then echo yes; fi; echo after')" "75|" "[gh-state] the 500 inside an if: still stops"
  eq "$(ghs "$W" 200 'S=$(gh_state repos/a/b/labels/x); echo "after $GH_STATE"' | cut -d'|' -f2)" "" \
     "[gh-state] misused inside \$(…): GH_STATE stays unset and set -u stops the script"
  eq "$(ghs "$W" 404rc0 'gh_state repos/a/b/labels/x; echo "after $GH_STATE"')" "75|" "[gh-state] a 404 with exit 0: exit 75, never absent"
  eq "$(ghs "$W" 200rc1 'gh_state repos/a/b/labels/x; echo "after $GH_STATE"')" "75|" "[gh-state] a 200 with a non-zero exit: exit 75, never exists"
  eq "$(ghs "$W" junk404 'gh_state repos/a/b/labels/x; echo "after $GH_STATE"')" "75|" "[gh-state] a first line that is not HTTP/: exit 75"
  local A f c
  fresh_state; A=$(act_in "$P" "$W")
  for c in 'S=$(gh_state repos/a/b/labels/x)' 'local s=$(gh_state "repos/$R/labels/$L")' 'gh_state repos/a/b/labels/x | cat' \
           '( gh_state repos/a/b/labels/x )' 'S=`gh_state repos/a/b/labels/x`' 'if echo | gh_state x; then :; fi' \
           'gh_state y 2>&1 | tee /dev/null' 'gh_state y &' 'x=$(cd /; gh_state y)' '{ gh_state y; } | cat' 'x="$(gh_state y)"' \
           '( cd "$(dirname "$0")"; gh_state y )' '{ gh_state x; } 2>&1 | cat' '{ gh_state x; } &' 'if gh_state x; then :; fi | cat' \
           'cat f | while read -r l; do gh_state "$l"; done' 'while true; do if a; then :; fi; gh_state x; done | cat' \
           'while a; do if a; then if b; then :; fi; fi; gh_state x; done | cat' '{ time { :; }; gh_state x; } | cat' 'cat |& gh_state x' 'while read l; do gh_state x; done < <(cat) | cat' \
           'time -p { gh_state x; } | cat' '{ v=${V:-$(c)}; w=${W:-$(c)}; gh_state x; } | cat' 'case $s in if) gh_state x;; esac | cat'; do
    f="$W/m.sh"; cp "$A" "$f"; in_act "$f" "$c"
    eq "$(bt "$P" "$W" check "$f")" 1 "[gh-state] check refuses '$c' (an earlier GH_STATE would decide)"
  done
  for c in 'gh_state repos/a/b/labels/x' 'if gh_state x; then :; fi' 'gh_state x || exit 75' '[ -n "$DEST" ] || gh_state x' \
           'gh_state "a|b"' 'echo "x (gh_state)"' 'gh_state x 2>&1 >/dev/null' 'true && gh_state x' 'echo a | cat || gh_state x' \
           'gh_state x && sort f | head' 'gh_state "r/$(printf %s "$L" | jq -sRr @uri)"' 'x=`date`; gh_state y' \
           'if gh_state x; then echo a | cat; fi' '{ gh_state x; } 2>/dev/null' 'if gh_state x; then { echo a; } | cat; fi' \
           'if gh_state x; then if y; then :; fi | cat; fi' 'while read l; do gh_state x; done < <(cat)' \
           'v=${V:-$(date)}; gh_state x' 'case $s in done) gh_state x;; esac'; do
    f="$W/s.sh"; cp "$A" "$f"; in_act "$f" "$c"
    eq "$(bt "$P" "$W" check "$f")" 0 "[gh-state] control: check accepts '$c'"
  done
}

# ── log --wait-names, the main session's one wait for the scripts a worker runs ─────────────────────────────────────
# logrow <time> <name> <result> — one run line of the log, in the field order of LOG_FIELDS
logrow() { mkdir -p "$(baton_dir)"; printf '%s\trun\t%s\tabc123\tdef456\t[]\t/w\tcoordinator-auto\tauto\t%s\t-\t/runs/x.log\n' "$1" "$2" "$3" >> "$(baton_dir)/log.tsv"; }
utc() { python3 -c 'import sys, time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + float(sys.argv[1]))))' "$1"; }
fam_wait() {
  local P=$1 W now old t0 t1
  W=$(fresh); now=$(utc 0); old=$(utc -7200)
  fresh_state; logrow "$now" w-a.sh ok; logrow "$now" w-b.sh ok; logrow "$now" other.sh run-failed
  eq "$(bt "$P" "$W" log --wait-names w-a.sh,w-b.sh --timeout 5)" 0 "[wait] all named scripts ok: rc 0"
  eq "$(awk -F'\t' '$2 == "run" && ($3 == "w-a.sh" || $3 == "w-b.sh") && $10 == "ok"' "$BT_OUT" | wc -l | tr -d ' ')" 2 "[wait] …both ok lines are printed"
  hasnt "$(cat "$BT_OUT")" other.sh "[wait] a name not in the list is ignored (its failed line neither counts nor prints)"
  t0=$(date +%s); eq "$(bt "$P" "$W" log --wait-names w-a.sh,w-c.sh --timeout 2)" 9 "[wait] one name never runs: rc 9 at the deadline"
  t1=$(date +%s); [ $((t1 - t0)) -ge 2 ] && ok "[wait] …it waited the whole timeout" || bad "[wait] …it waited the whole timeout ($((t1 - t0)) s)"
  has "$(cat "$BT_OUT")" "wait: w-c.sh: no run line since" "[wait] …and names the missing one"
  fresh_state; logrow "$now" w-m.sh postcheck-failed; logrow "$now" w-m.sh ok
  eq "$(bt "$P" "$W" log --wait-names w-m.sh --timeout 5)" 0 "[wait] postcheck-failed, then ok after a fix: rc 0"
  fresh_state; logrow "$now" w-p.sh postcheck-failed
  eq "$(bt "$P" "$W" log --wait-names w-p.sh --timeout 1)" 9 "[wait] only a postcheck-failed line: rc 9"
  has "$(cat "$BT_OUT")" "wait: w-p.sh: last run postcheck-failed" "[wait] …naming its last result"
  fresh_state; logrow "$now" w-r.sh ok; logrow "$now" w-r.sh run-failed
  eq "$(bt "$P" "$W" log --wait-names w-r.sh --timeout 1)" 9 "[wait] ok, then a failed re-run: the latest line decides, rc 9"
  fresh_state; logrow "$old" lib-update.sh ok
  eq "$(bt "$P" "$W" log --wait-names lib-update.sh --timeout 1)" 9 "[wait] a name with only an old ok line (2 h ago): rc 9"
  has "$(cat "$BT_OUT")" "1 run line before --since ignored" "[wait] …the old line is ignored and counted"
  logrow "$now" lib-update.sh ok
  eq "$(bt "$P" "$W" log --wait-names lib-update.sh --timeout 5)" 0 "[wait] a reused name with an old ok and a new ok: rc 0"
  fresh_state; logrow "$old" w-s.sh ok
  eq "$(bt "$P" "$W" log --wait-names w-s.sh --since "$(utc -7300)" --timeout 1)" 0 "[wait] --since before the old line: it counts, rc 0"
  fresh_state; mkdir -p "$(baton_dir)"
  ( python3 -c 'import time; time.sleep(1.5)'; logrow "$(utc 0)" w-late.sh ok ) &
  t0=$(date +%s); eq "$(bt "$P" "$W" log --wait-names w-late.sh --timeout 20)" 0 "[wait] a line written during the wait ends it: rc 0"
  t1=$(date +%s); wait; [ $((t1 - t0)) -lt 15 ] && ok "[wait] …well before the timeout" || bad "[wait] …well before the timeout ($((t1 - t0)) s)"
  for a in "--timeout 0" "--timeout 581" "--timeout x" "--since yesterday" "--since" "--timeout 1 --timeout 2"; do
    # shellcheck disable=SC2086
    eq "$(bt "$P" "$W" log --wait-names w-a.sh $a)" 64 "[wait] bad usage '--wait-names w-a.sh $a': rc 64"
  done
  eq "$(bt "$P" "$W" log --wait-names ',w-a.sh' --timeout 1)" 64 "[wait] an empty name: rc 64"
}

# ── the short core and its reference files ───────────────────────────────────────────────────────────────────────────
fam_skill_refs() {
  local P=$1 W n t
  W=$(fresh); fresh_state
  n=$(wc -c < "$P/skills/batonrun/SKILL.md" | tr -d ' ')
  [ "$n" -le 10000 ] && ok "[skill-refs] the core is at most 10000 bytes ($n)" || bad "[skill-refs] the core is at most 10000 bytes ($n)"
  for t in act kinds kits modes permissions setup limits; do
    has "$(cat "$P/skills/batonrun/SKILL.md")" "- \`$t.md\`: " "[skill-refs] the core names $t.md with when to read it"
    eq "$(bt "$P" "$W" help "$t")" 0 "[skill-refs] help $t: rc 0"
    cmp -s "$BT_OUT" "$P/skills/batonrun/$t.md" && ok "[skill-refs] help $t prints $t.md byte for byte" || bad "[skill-refs] help $t prints $t.md byte for byte"
  done
  eq "$(ls "$P/skills/batonrun" | grep -c -v -x -E 'SKILL\.md|(act|kinds|kits|modes|permissions|setup|limits)\.md')" 0 "[skill-refs] no other file next to the skill"
  eq "$(bt "$P" "$W" help nope)" 64 "[skill-refs] help with an unknown topic: rc 64"
  has "$(cat "$BT_OUT")" "act, kinds, kits, modes, permissions, setup, limits" "[skill-refs] …listing the topics"
  eq "$(bt "$P" "$W" help)" 0 "[skill-refs] help alone: rc 0"
  has "$(cat "$BT_OUT")" "Topics (baton.py help <topic>" "[skill-refs] …ends with the topic list"
}

# ── how Expect matches a plan line, as the core states it (4 of 15 ab5 runs grepped baton.py for it) ─────────────
# exp_baton <plugin> <file> <plan lines> <Expect lines> — the core's skeleton whose act writes each plan line (newline-separated)
# and whose header holds each Expect line, in that order
exp_baton() {
  python3 - "$1/skills/batonrun/SKILL.md" "$2" "$3" "$4" <<'PY'
import re, shlex, sys
t = open(sys.argv[1], encoding="utf-8").read()
a, b = "<!-- baton-skeleton -->\n```bash\n", "```\n<!-- /baton-skeleton -->"
sk = t[t.index(a) + len(a):t.index(b)]
plans, expects = [x for x in sys.argv[3].split("\n") if x], [x for x in sys.argv[4].split("\n") if x]
sk = sk.replace("# Expect: create *\n", "".join("# Expect: %s\n" % e for e in expects))
sk = re.sub(r"(?m)^# Targets: .*$", "# Targets: the plan lines below", sk)   # prose: no Targets test of these plan lines
act = "act() {\n" + "".join("  write %s true\n" % shlex.quote(p) for p in plans) + "  :\n}\n"
sk, n = re.subn(r"(?ms)^act\(\) \{\n.*?^\}\n", lambda m: act, sk, count=1)
assert n == 1
open(sys.argv[2], "w", encoding="utf-8").write(sk)
PY
}
# exp_try <plugin> <dir> <plan lines> <Expect lines> — rehearse such a baton; prints its rc, the output in $BT_OUT
exp_try() { local f; f="$2/e$RANDOM$RANDOM.sh"; exp_baton "$1" "$f" "$3" "$4"; printf 'hi\n' > "$2/b.txt"; bt "$1" "$2" rehearse "$f" dest="$2/x.txt" body="$2/b.txt"; }
fam_expect_doc() {
  local P=$1 W f n ex verdict plan expect
  fresh_state; W=$(fresh)
  ex=$(python3 - "$P/skills/batonrun/SKILL.md" <<'PY'
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
a, b = "<!-- expect-match -->\n", "<!-- /expect-match -->"
sec = t[t.index(a) + len(a):t.index(b)] if a in t and b in t else ""
for m in re.finditer(r"^- plan `([^`]*)`, Expect `([^`]*)` → (ok|FAIL)$", sec, re.M):
    print("%s\t%s\t%s" % (m.group(3), m.group(1), m.group(2)))
PY
)
  eq "$(printf '%s\n' "$ex" | grep -c '^ok'):$(printf '%s\n' "$ex" | grep -c '^FAIL')" "1:1" "[expect-doc] instrument: the core holds one matching and one failing example"
  while IFS=$'\t' read -r verdict plan expect; do
    [ -n "$verdict" ] || continue
    if [ "$verdict" = ok ]; then
      eq "$(exp_try "$P" "$W" "$plan" "$expect")" 0 "[expect-doc] the core's ok example: plan '$plan' matches Expect '$expect' (rc 0)"
      has "$(cat "$BT_OUT")" "  ok   $plan  ~  $expect" "[expect-doc] …its row reads 'ok'"
    else
      eq "$(exp_try "$P" "$W" "$plan" "$expect")" 1 "[expect-doc] the core's FAIL example: plan '$plan' does not match Expect '$expect' (rc 1)"
      has "$(cat "$BT_OUT")" "  FAIL $plan  ~  $expect" "[expect-doc] …its row reads 'FAIL <plan>  ~  <Expect>'"
    fi
  done <<< "$ex"
  # each claim of the core's paragraph, pinned as text next to the check that holds it true against the code
  local core; core=$(tr -s ' \n' '  ' < "$P/skills/batonrun/SKILL.md")
  has "$core" 'compares the i-th with the i-th `Expect` line as a shell glob over the whole line, case-sensitive' "[expect-doc] the core states order, whole line and case"
  has "$core" 'one plan line per `write()` call, in the order they ran' "[expect-doc] the core states the order"
  has "$core" '`*` is any run of characters (spaces and `/` too), `?` one character, `[…]` a set' "[expect-doc] the core states the glob"
  has "$core" 'It is not a prefix match.' "[expect-doc] the core states it is not a prefix match"
  has "$core" 'The counts must be equal: a missing or an extra line is a FAIL row with `(none)`.' "[expect-doc] the core states the count"
  has "$core" 'Each row prints `ok` or `FAIL <plan> ~ <Expect>`' "[expect-doc] the core states the row format"
  eq "$(exp_try "$P" "$W" 'create docs/a.txt' 'create docs')" 1 "[expect-doc] not a prefix, with a space in Expect: 'create docs' against 'create docs/a.txt': rc 1"
  eq "$(exp_try "$P" "$W" 're-create a' 'create *')" 1 "[expect-doc] the whole line from its start: 'create *' against 're-create a': rc 1"
  eq "$(exp_try "$P" "$W" 'tag v1 ' 'tag v1')" 1 "[expect-doc] the whole line to its end: 'tag v1' against 'tag v1 ' (a trailing space): rc 1"
  eq "$(exp_try "$P" "$W" 'copy a/b/c d' 'copy *')" 0 "[expect-doc] '*' spans '/' and spaces: rc 0"
  eq "$(exp_try "$P" "$W" $'make a x\nmake b y' $'make a *\nmake b *')" 0 "[expect-doc] order: two writes in Expect order: rc 0"
  eq "$(exp_try "$P" "$W" $'make a x\nmake b y' $'make b *\nmake a *')" 1 "[expect-doc] order: the same Expect lines swapped: rc 1"
  eq "$(exp_try "$P" "$W" $'make a x\nmake b y' 'make *')" 1 "[expect-doc] count: two writes, one Expect line: rc 1"
  has "$(cat "$BT_OUT")" "  FAIL make b y  ~  (none)" "[expect-doc] count: the extra plan line is a FAIL row with (none)"
  eq "$(exp_try "$P" "$W" 'make a x' $'make a *\nmake b *')" 1 "[expect-doc] count: one write, two Expect lines: rc 1"
  has "$(cat "$BT_OUT")" "  FAIL (none)  ~  make b *" "[expect-doc] count: the missing plan line is a FAIL row with (none)"
  eq "$(exp_try "$P" "$W" 'create X' 'create x')" 1 "[expect-doc] case-sensitive: 'create X' against 'create x': rc 1"
  eq "$(exp_try "$P" "$W" 'tag v1' 'tag v?')" 0 "[expect-doc] '?' is one character: rc 0"
  eq "$(exp_try "$P" "$W" 'tag v12' 'tag v?')" 1 "[expect-doc] '?' is not two characters: rc 1"
  eq "$(exp_try "$P" "$W" 'tag v1' 'tag v[0-9]')" 0 "[expect-doc] '[…]' is a set: rc 0"
  eq "$(exp_try "$P" "$W" 'tag v1' 'tag v[a-z]')" 1 "[expect-doc] '[…]' outside the set: rc 1"
  # what go prints on a mismatch, as the core quotes it
  f="$W/eg.sh"; exp_baton "$P" "$f" 'create docs/a.txt' 'create'; bt "$P" "$W" mode auto >/dev/null
  printf 'hi\n' > "$W/b.txt"
  eq "$(bt "$P" "$W" go "$f" dest="$W/x.txt" body="$W/b.txt")" 1 "[expect-doc] go on the FAIL example: rc 1"
  has "$(cat "$BT_OUT")" 'go: stopped at plan-vs-Expect (exit 1)' "[expect-doc] …go prints 'go: stopped at plan-vs-Expect (exit 1)'"
  has "$(tr -s ' \n' '  ' < "$P/skills/batonrun/SKILL.md")" '`go` ends `go: stopped at plan-vs-Expect (exit 1)`' "[expect-doc] …and the core quotes that line"
}

# ── the core's header with four Expect lines, and the ops it says kit:gh-write covers ─────────────────────────────
# The four-line header example is read out of the core and rehearsed: the plan lines are its own Expect lines with `*` filled by a
# SHA, so it matches in order and fails when two lines swap (a break in the matching, not in the text, turns the swap row green).
fam_expect_header() {
  local P=$1 W ex plans swapped sha n
  fresh_state; W=$(fresh); sha=$(printf 'b%.0s' $(seq 40))
  ex=$(python3 - "$P/skills/batonrun/SKILL.md" <<'PY'
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
a, b = "<!-- expect-match -->\n", "<!-- /expect-match -->"
sec = t[t.index(a) + len(a):t.index(b)] if a in t and b in t else ""
m = re.search(r"^```\n((?:# Expect: .*\n)+)```$", sec, re.M)
print("\n".join(l[len("# Expect: "):] for l in m.group(1).splitlines()) if m else "")
PY
)
  n=$(printf '%s\n' "$ex" | grep -c .)
  eq "$n" 4 "[expect-header] instrument: the core holds one header example of four Expect lines"
  eq "$(printf '%s\n' "$ex" | grep -c -F '*')" 1 "[expect-header] …exactly one of them uses '*' (for a SHA)"
  plans=${ex//\*/$sha}
  eq "$(exp_try "$P" "$W" "$plans" "$ex")" 0 "[expect-header] the core's four-line header, rehearsed against four writes in order: rc 0"
  eq "$(grep -c '^  ok   ' "$BT_OUT")" 4 "[expect-header] …four 'ok' rows"
  has "$(cat "$BT_OUT")" "  ok   ref create refs/tags/v2 $sha  ~  ref create refs/tags/v2 *" "[expect-header] …the '*' stands for the SHA"
  swapped=$(printf '%s\n' "$ex" | awk 'NR==2{a=$0; next} NR==3{print; print a; next} {print}')
  [ "$swapped" != "$ex" ] && ok "[expect-header] instrument: the swapped header differs from the core's" || bad "[expect-header] instrument: the swapped header differs from the core's"
  eq "$(exp_try "$P" "$W" "$plans" "$swapped")" 1 "[expect-header] the same header with two Expect lines swapped: rc 1"
  eq "$(grep -c '^  FAIL ' "$BT_OUT")" 2 "[expect-header] …two FAIL rows (the swapped lines)"
}

# The ops the core says kit:gh-write covers are the ops gh_write.py accepts, and the core says what is left to a hand-written baton.
fam_core_ops() {
  local P=$1 doc code core
  doc=$(python3 - "$P/skills/batonrun/SKILL.md" <<'PY'
import re, sys
t = " ".join(open(sys.argv[1], encoding="utf-8").read().split())
m = re.search(r"`go kit:gh-write --spec <file>` covers ([a-z, -]+?);", t)
print("\n".join(sorted(x.strip() for x in m.group(1).split(","))) if m else "")
PY
)
  code=$(python3 -I -B - "$P/gates" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import gh_write
print("\n".join(sorted(gh_write.KINDS)))
PY
)
  eq "$(printf '%s\n' "$code" | grep -c .)" 11 "[core-ops] instrument: gh_write.py accepts eleven ops"
  eq "$doc" "$code" "[core-ops] the op list in the core equals the ops gh_write.py accepts"
  core=$(tr -s ' \n' '  ' < "$P/skills/batonrun/SKILL.md")
  has "$core" 'Labels, tags, releases, a push: hand-written.' "[core-ops] the core names what needs a hand-written baton"
  has "$core" 'file-pr; never by hand (' "[core-ops] the core says the kit's ops are never hand-written"
  has "$core" 'an undo that cannot delete names what it leaves behind and exits non-zero' "[core-ops] the core says what an undo that cannot delete does"
}

# ── the bare-launcher trap; the hook warns on every launcher sign/run/go inside a compound command ──────────────────
# trap_ctx <plugin> <app> <session id> <command> — the context the real PreToolUse Bash hook of the rules (pre-bash.py, not the
# guard of the owner's signature, which answers an owner sign with a decision of its own) gives that command in that app repo
trap_ctx() {
  local pl; pl=$(python3 -c 'import json, sys; print(json.dumps({"session_id": sys.argv[1], "hook_event_name": "PreToolUse",
    "tool_name": "Bash", "tool_input": {"command": sys.argv[2]}}))' "$3" "$4")
  ctx "$(printf '%s' "$pl" | CLAUDE_PROJECT_DIR="$2" CLAUDE_PLUGIN_ROOT="$1" bash -c "$(hook_cmds "$1/hooks/hooks.json" PreToolUse Bash | grep pre-bash)" 2>/dev/null)"
}
fam_pipe_trap() {
  local P=$1 L=/state/vibemaestro/baton/bin/baton S A o
  S=$(sid); A=$(mktemp -d "$TMP/app-trap.XXXXXX"); mk_app "$A"      # an app of its own: the family writes its config
  warns()  { has "$(trap_ctx "$P" "$A" "$S" "$1")" "BatonRun: this launcher" "[pipe-trap] warns${2:-}: $1"; }
  quiet()  { hasnt "$(trap_ctx "$P" "$A" "$S" "$1")" "BatonRun: this launcher" "[pipe-trap] no warning${2:-}: $1"; }
  warns "$L run x.sh | grep ok"
  warns "$L go x.sh && echo done"
  warns "$L sign --by owner --seal s x.sh; echo rc=\$?"
  warns "$L run x.sh > out.txt"
  # the same command again in the same session: warned again (not once per session)
  o=$(trap_ctx "$P" "$A" "$S" "$L run x.sh | grep ok")
  has "$o" "BatonRun: this launcher \`run\` command is not bare (\`|\`, outside quotes)" "[pipe-trap] the same piped run, second time in one session: warned again, naming the pipe"
  has "$o" "will not match" "[pipe-trap] …says the allow rule will not match"
  has "$o" "classifier decides" "[pipe-trap] …says the classifier decides"
  has "$o" "Send the launcher bare" "[pipe-trap] …says to send the launcher bare"
  warns "cd /tmp && $L go x.sh"
  warns "python3 /p/scripts/baton.py go x.sh | tail -3"
  warns "\"$L\" run x.sh | cat"
  warns "$L go x.sh 2>&1"
  warns "$L run x.sh >> out.txt"
  warns "$L go x.sh || true"
  warns "$L go x.sh &"
  warns "$L run x.sh |& tee o"
  warns "$L run x.sh \"\$(cat a)\""
  warns "$L go x.sh"$'\n'"echo next"
  warns "$L go x.sh # note"
  warns "bash -c '$L go x.sh'"
  warns "bash -lc '$L go x.sh | tail -1'"
  warns "sh -ec '$L go x.sh'"
  warns "bash -c -- '$L go x.sh'"
  warns "eval '$L go x.sh | tail -1'"
  warns "$L run x.sh \$'\\'' | grep ok"
  warns "$L run x.sh \$'a\\'b' && echo rc=\$?"
  warns "time $L go x.sh"
  warns "env FOO=1 $L go x.sh"
  warns "timeout 600 $L go x.sh"
  warns "! $L go x.sh"
  warns "FOO=1 $L go x.sh"
  warns "/state/vibemaestro/baton/bin/bat\\"$'\n'"on go x.sh | tail -1"
  warns "for f in a b; do $L go \$f; done"
  warns "if $L run x.sh; then echo; fi"
  warns "{ $L go x.sh; } | tail"
  warns "sudo -u root $L go x.sh | tail"
  warns "env -u FOO $L go x.sh | tail"
  warns "timeout -s KILL 5 $L go x.sh | tail"
  warns "env bash -c '$L go x.sh'"
  warns "FOO=1 bash -c '$L go x.sh'"
  warns "time bash -lc '$L go x.sh'"
  warns "eval $L go x.sh | tail"
  warns "xargs $L go | tail"
  warns "python3 -X dev /p/scripts/baton.py go x.sh | tail"
  warns "cat <<-EOF"$'\n\t'"foo"$'\n\t'"EOF"$'\n'"$L go x.sh | tail"
  warns "bash <<'EOF'"$'\n'"$L go x.sh"$'\n'"EOF"
  warns "x=\$((1<<2))"$'\n'"$L go x.sh | tail"
  warns "bash 2>&1 <<EOF"$'\n'"$L go x.sh"$'\n'"EOF"
  warns "bash <<A <<B"$'\n'"x"$'\n'"A"$'\n'"$L go x.sh"$'\n'"B"
  warns "cat <<A | bash"$'\n'"$L go x.sh"$'\n'"A"
  warns ". /dev/stdin <<EOF"$'\n'"$L go x.sh"$'\n'"EOF"
  warns "echo \$((1<<2))"$'\n'"$L go x.sh | cat"$'\n'"2"
  warns "bash -c \"bash -c '$L go x.sh'\""
  # a heredoc body is read as command lines (whether a shell runs it is not decidable): a launcher line in data warns too
  warns "cat <<'EOF'"$'\n'"$L go x.sh"$'\n'"EOF" " (a heredoc body, read as commands)"
  warns "git commit -F - <<'EOF'"$'\n'"fix: don't warn"$'\n'"EOF"$'\n'"$L go x.sh" " (an apostrophe in a heredoc body before it)"
  warns "cat <<EOF > notes.txt"$'\n'"say \"hi"$'\n'"EOF"$'\n'"$L go x.sh | tail" " (an open double quote in a heredoc body before it)"
  quiet "$L go x.sh a b"
  quiet "$L go x.sh 'a|b' \"c;d\""
  quiet "$L run x.sh \"x && y; z > w\""
  quiet "$L go x.sh a\\|b"
  quiet "$L log --tail 5 | tail -1"
  quiet "$L rehearse x.sh | head"
  quiet "echo go | cat"
  quiet "echo baton; go x"
  quiet "grep -n 'baton run' notes.txt | head"
  quiet "git status && echo baton run"
  quiet "grep -rn baton run | head"
  quiet "$L go x.sh \$'a b' \$'c|d'"
  quiet "$L go a\\"$'\n'" b"
  quiet "python3 -I -B /p/scripts/baton.py go x.sh a"
  quiet "bash -c 'echo hi | cat'"
  # The one-call baton, a quoted heredoc on `go -`, is silent; every other heredoc on `go -` is named
  local doc body ctl
  # the core no longer recommends this form (a baton heredoc on `go -` is blocked by Claude Code, fam_go_dash_guidance); the hook's
  # silent shape stays a fixed command here
  doc="<launcher> go - <args> <<'BATON_EOF'"
  body=$(python3 - "$P/skills/batonrun/SKILL.md" <<'PY'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
a, b = "<!-- baton-skeleton -->\n```bash\n", "```\n<!-- /baton-skeleton -->"
print(t[t.index(a) + len(a):t.index(b)].replace("act() {\n", "act() {\n  gh pr merge 12 --squash # don't\n", 1), end="")
print("x")
PY
)
  body=${body%x}                                   # the x keeps the skeleton's last newline through $(…)
  doc=${doc//<launcher>/$L}; doc=${doc//<args>/x.txt \'a b\'}
  quiet "$doc"$'\n'"$body"'BATON_EOF' " (the one-call form, the core's skeleton as its body)"
  quiet "$L go --by coordinator-auto - a <<\"E\""$'\n'"$body"'E'$'\n\n' " (a double-quoted delimiter, --by, blank lines after)"
  quiet "python3 /p/scripts/baton.py go - a <<'E'"$'\n'"$body"'E' " (baton.py before the launcher is installed)"
  warns "$L go - a <<BATON_EOF"$'\n'"$body"'BATON_EOF' " (an unquoted delimiter)"
  has "$(trap_ctx "$P" "$A" "$S" "$L go - a <<BATON_EOF"$'\n'"$body"'BATON_EOF')" "an unquoted delimiter" "[pipe-trap] …naming the unquoted delimiter"
  warns "$L go - a <<'E'"$'\n'"$body"'E'$'\n'"touch pwned.txt" " (a command after the closing line)"
  warns "$L go - a <<'E'"$'\n'"x"$'\n'"E"$'\n'"touch pwned.txt"$'\n'"E" " (a body line equal to the delimiter ends it early)"
  warns "$L go - a <<'E' | tail -1"$'\n'"$body"'E' " (a pipe on the first line)"
  warns "cd sub && $L go - a <<'E'"$'\n'"$body"'E' " (a chain before it)"
  warns "$L go - a <<-'E'"$'\n'"$body"'E' " (<<-)"
  warns "$L go - a <<'E'"$'\n'"$body" " (never closed)"
  # round 1: to bash a CR is a character (the delimiter becomes E\r), and only spaces and tabs are blank
  warns "$L go - a <<'E'"$'\r\n'"$body"$'E\r\ntouch pwned.txt\nE\n' " (a CR after the delimiter: bash ends the body at E\\r)"
  warns "$L go - a <<'E'"$'\n'"$body"$'E\r' " (a CR on the closing line)"
  warns "$L go - a <<'E'"$'\n'"echo a"$'\r'"b"$'\n'"$body"'E' " (a CR inside the body: only the CR check names it)"
  warns "$L go - a <<'E'"$'\n'"$body"$'E\n\x1c' " (a control character after the closing line, a command word to bash)"
  warns "$L go - a <<'E'"$'\n'"$body"$'E\n\xc2\xa0' " (a no-break space after the closing line)"
  warns "$L run x.sh <<'E'"$'\n'"$body"'E' " (a heredoc on run)"
  warns "$L go x.sh <<'E'"$'\n'"$body"'E' " (a heredoc on a file go)"
  # its body is stdin data: the rules read the first line only (the body's `gh pr merge` reminds nobody), and only for that shape
  hasnt "$(trap_ctx "$P" "$A" "$(sid)" "$doc"$'\n'"$body"'BATON_EOF')" "batonrun.instructions.md" "[pipe-trap] the one-call form: the body's gh pr merge does not trigger the batonrun rule"
  has "$(trap_ctx "$P" "$A" "$(sid)" "$doc"$'\n'"$body"'BATON_EOF'$'\n'"echo")" "batonrun.instructions.md" "[pipe-trap] control: the same body with a line after the closing one triggers it"
  # the printed `go` allow rule matches the documented call, by baton.py's own model of Claude Code's matcher (the real matcher is
  # not measurable offline: the coordinator measures it live after merge)
  ctl=$(python3 - "$P/scripts/baton.py" "$doc"$'\n'"$body"'BATON_EOF' "$L" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("baton_model", sys.argv[1]); m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
print("%s/%s" % (m.bash_matches(sys.argv[3] + " go:*", sys.argv[2]), m.bash_matches(sys.argv[3] + " go:*", sys.argv[3] + " run x.sh")))
PY
)
  eq "$ctl" "True/False" "[pipe-trap] the rule '<launcher> go:*' matches the documented call (baton.py's model; control: not a run)"
  eq "$(within 5 python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import vsdlc
for c in ("x=$((1<<2))\n" * 20000, "".join("cat <<d%d\n" % i for i in range(20000)), "bash " * 20000, "a\n" * 200000,
          "bash x <<EOF\n" + "y\n" * 30000 + "EOF"): vsdlc.launcher_trap(c)' "$P/scripts")" 0 \
     "[pipe-trap] 20000 shells, heredocs or unclosed '<<': the scan stays linear (under 5 s; it runs before every Bash command)"
  o=$(printf '%s' '{"session_id": "s1", "hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": ["x | y"]}}' \
      | CLAUDE_PROJECT_DIR="$A" CLAUDE_PLUGIN_ROOT="$P" python3 "$P/scripts/pre-bash.py" 2>&1)
  hasnt "$o" "internal error" "[pipe-trap] a command that is not a string: no internal error"
  # silent when the config turns the hooks off, and when the rule is disabled
  mkdir -p "$A/.vibemaestro"
  printf '{"hooks": "off"}\n' > "$A/.vibemaestro/sdlc.json"
  quiet "$L run x.sh | grep ok" " (hooks off)"
  printf '{"rules": {"disable": ["batonrun"]}}\n' > "$A/.vibemaestro/sdlc.json"
  quiet "$L run x.sh | grep ok" " (the batonrun rule disabled)"
  printf '{}\n' > "$A/.vibemaestro/sdlc.json"
  warns "$L run x.sh | grep ok" " (control: an empty config)"
}

# ── `go -` with a baton skeleton is blocked by Claude Code (measured, default mode); the guidance says only forms that run ──
# The measured verdicts live in tests/fixtures/go-dash-verdict.txt. While any mode says blocked: no guidance file holds BATON_EOF, and
# every mention of `go -` (also `go --by x -`, `go [..] -`) sits in a sentence that says never, block or measured; in the core skill and
# the rule the unit is the clause (cut at , ; : .), so a "never" elsewhere in the sentence does not cover it. The two messages a model
# reads at run time (the hook's warning for a heredoc on `go -`, the `go -` line of `baton.py help`) are held to the same.
# Prose cannot be proven by a regex: this catches the regressions a careless edit makes, not a deliberate rewording.
fam_go_dash_guidance() {
  local P=$1 V="$SRC_ROOT/tests/fixtures/go-dash-verdict.txt" r
  r=$(python3 - "$V" "$P" <<'PY'
import glob, os, re, subprocess, sys
v, plugin = sys.argv[1:3]
verdicts = {}
for line in open(v, encoding="utf-8"):
    if line.strip() and not line.startswith("#"):
        w = line.split()
        verdicts[w[0]] = w[1]
bad_fixture = [m for m, x in verdicts.items() if x not in ("blocked", "runs", "not-measured")]
out = ["fixture=%s" % ("bad" if bad_fixture or "default" not in verdicts else "ok"), "default=%s" % verdicts.get("default", "missing")]
blocked = "blocked" in verdicts.values()
GO = re.compile(r"go\s+(?:\[[^\]]*\]\s+|--\S+(?:\s+\S+)?\s+)*-(?=[\s`]|$)")
SAYS = re.compile(r"[Nn]ever|block|[Mm]easured")
core = [plugin + "/skills/batonrun/SKILL.md", plugin + "/rules/batonrun.instructions.md"]
refs = sorted(set(glob.glob(plugin + "/skills/batonrun/*.md")) - set(core)) + [plugin + "/templates/baton-script.sh"]


def units(text, clause):
    """Sentences (or clauses) of a text: prose lines joined, table rows and list lines apart."""
    cut = r"(?<=[.;:,])\s+" if clause else r"(?<=[.;])\s+"
    for para in re.split(r"\n\s*\n", text):
        lines = para.split("\n")
        if any(l.lstrip().startswith("|") for l in lines):
            yield from lines
        else:
            yield from re.split(cut, " ".join(l.strip() for l in lines))


def bad_mentions(f, clause):
    text = open(f, encoding="utf-8").read()
    res = ["%s: BATON_EOF" % os.path.basename(f)] if "BATON_EOF" in text else []
    for u in units(text, clause):
        if GO.search(u) and not SAYS.search(u):
            res.append("%s: %s" % (os.path.basename(f), u.strip()[:60]))
    return res


core_bad, ref_bad, msg_bad = [], [], []
if blocked:
    for f in core:
        core_bad += bad_mentions(f, True)
    for f in refs:
        ref_bad += bad_mentions(f, False)
    sys.path.insert(0, plugin + "/scripts")
    import vsdlc
    warn = vsdlc.launcher_trap("/state/vibemaestro/baton/bin/baton go - a <<EOF\nbody\nEOF\n")      # an unquoted delimiter: a warning that names the shape
    if "BATON_EOF" in warn or not SAYS.search(warn) or "Write" not in warn:
        msg_bad.append("hook warning: %s" % warn[:80])
    helptext = subprocess.run([sys.executable, "-I", plugin + "/scripts/baton.py", "help"], capture_output=True, text=True).stdout
    m = re.search(r"baton\.py go \[--by coordinator-auto\] - \[args\.\.\.\](.{0,400})", helptext, re.S)
    if not m or not SAYS.search(m.group(1)):
        msg_bad.append("baton.py help: the go - line")
out += ["blocked=%s" % blocked, "core=%d" % len(core_bad), "refs=%d" % len(ref_bad), "msgs=%d" % len(msg_bad)]
print("\n".join(out)); print("\n".join(core_bad + ref_bad + msg_bad), file=sys.stderr)
PY
)
  has "$r" "fixture=ok" "[go-dash] instrument: the verdict fixture is well formed and has a default line"
  has "$r" "default=blocked" "[go-dash] the measured default-mode verdict is blocked (2.1.303)"
  has "$r" "blocked=True" "[go-dash] instrument: a blocked verdict is on record, so the checks below bind"
  has "$r" "core=0" "[go-dash] the core and the rule do not recommend go - or a BATON_EOF heredoc while the fixture says blocked"
  has "$r" "refs=0" "[go-dash] every other mention of go - (reference files, template) says blocked or measured"
  has "$r" "msgs=0" "[go-dash] the hook's warning and the help line of go - do not teach the blocked form"
}

# ── `run` prints one line when it holds, like go; everything when it does not ─────────────────────────────────────
fam_run_line() {
  local P=$1 W A f l
  fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  eq "$(sg "$P" "$W" owner "$A" "$W/a.txt" hello)" 0 "[run-line] sign: rc 0"
  eq "$(bt "$P" "$W" run "$A" "$W/a.txt" hello)" 0 "[run-line] run: rc 0"
  eq "$(wc -l < "$BT_OUT" | tr -d ' ')" 1 "[run-line] a run that holds prints one line, stdout and stderr together"
  grep -q "^run: ok — 1 write — $(baton_dir)/runs/[^/]*\.log\$" "$BT_OUT" && ok "[run-line] the line is 'run: ok — 1 write — <run log>'" \
    || bad "[run-line] the line is 'run: ok — 1 write — <run log>' ($(head -c 300 "$BT_OUT"))"
  l=$(sed -n 's/^run: ok — [0-9]* writes\{0,1\} — //p' "$BT_OUT")
  eq "$l" "$(logcol 12)" "[run-line] the line names this run's log"
  grep -q '^  DO create ' "$l" 2>/dev/null && ok "[run-line] the run log keeps the whole output (its DO line)" || bad "[run-line] the run log keeps the whole output (its DO line)"
  f="$W/pc.sh"; cp "$A" "$f"; mutate "$f" $'postcheck() {\n  holds_text\n}' $'postcheck() {\n  false\n}'
  eq "$(sg "$P" "$W" owner "$f" "$W/b.txt" hello)" 0 "[run-line] sign a script whose post-check fails: rc 0"
  eq "$(bt "$P" "$W" run "$f" "$W/b.txt" hello)" 4 "[run-line] a failed run: rc 4"
  grep -q '^  DO create ' "$BT_OUT" && ok "[run-line] a failed run prints its whole output (its DO line)" || bad "[run-line] a failed run prints its whole output (its DO line)"
  has "$(cat "$BT_OUT")" "== run FAILED (postcheck-failed); undo put the state back" "[run-line] …and the run's end line"
  grep -q "^full output: $(baton_dir)/runs/" "$BT_OUT" && ok "[run-line] …and 'full output: <run log>'" || bad "[run-line] …and 'full output: <run log>'"
  hasnt "$(cat "$BT_OUT")" "run: ok" "[run-line] …and no 'run: ok'"
}

# ── a run that is killed shows where to look: runs/LAST and a `run-start` line before the script runs, `log --last` ─────
fam_run_last() {
  local P=$1 W A f l rc
  fresh_state; W=$(fresh); A=$(act_in "$P" "$W")
  eq "$(bt "$P" "$W" log --last)" 66 "[last] before any run: log --last exits 66"
  eq "$(sg "$P" "$W" owner "$A" "$W/a.txt" hello)" 0 "[last] sign: rc 0"
  eq "$(bt "$P" "$W" run "$A" "$W/a.txt" hello)" 0 "[last] a good run: rc 0"
  eq "$(wc -l < "$BT_OUT" | tr -d ' ')" 1 "[last] …still one line"
  l=$(sed -n 's/^run: ok — [0-9]* writes\{0,1\} — //p' "$BT_OUT")
  eq "$(bt "$P" "$W" log --last)" 0 "[last] log --last: rc 0"
  eq "$(cat "$BT_OUT")" "$l" "[last] …prints the path of the run the one line named"
  eq "$(grep -c "$(printf '\trun-start\t')" "$(baton_dir)/log.tsv")" 1 "[last] …and log.tsv has one run-start line"
  # a run killed (SIGKILL on baton itself) inside the script: it prints nothing, the pointer and the start line are already there
  f="$W/kill.sh"; cp "$A" "$f"; mutate "$f" $'act() {\n' $'killer() { kill -KILL "$PPID"; }\nact() {\n'
  mutate "$f" $'  write "create $DEST" put_text\n}' $'  write "create $DEST" killer\n}'
  eq "$(sg "$P" "$W" owner "$f" "$W/k.txt" hello)" 0 "[last] sign a script that kills its runner in the run phase: rc 0"
  rc=$(bt "$P" "$W" run "$f" "$W/k.txt" hello)
  eq "$rc" 137 "[last] the run is killed: rc 137"
  hasnt "$(cat "$BT_OUT")" "$(baton_dir)/runs/" "[last] …and printed no log path (that is the case this pointer is for)"
  eq "$(lastlog | cut -f2)" run-start "[last] the last log line is the run-start line (no run line: the run never finished)"
  l=$(lastlog | cut -f12)
  [ -f "$l" ] && ok "[last] …it names a run log that exists" || bad "[last] …it names a run log that exists ($l)"
  eq "$(bt "$P" "$W" log --last)" 0 "[last] log --last after the kill: rc 0"
  eq "$(cat "$BT_OUT")" "$l" "[last] …prints that run log's path"
  eq "$(bt "$P" "$W" log --last --tail 1)" 64 "[last] log --last with another option: usage, rc 64"
}

# ── go - reads the baton from stdin, stores it once under <state>/stdin and runs that file as go <file> ──
# bts <plugin> <dir> <stdin file> <baton args...> — bt with stdin read from a file
bts() {
  local p=$1 d=$2 i=$3; shift 3
  ( cd "$d" && cenv XDG_STATE_HOME="$ST" ${BT_ENV[@]+"${BT_ENV[@]}"} python3 "$p/scripts/baton.py" "$@" ) < "$i" > "$BT_OUT" 2>&1; echo $?
}
# swap_at <script> <dir> <n> — plant an act line that, on the act's n-th call (0-based: go's rehearse, sign's rehearse, …), appends a
# comment to the file baton runs ($BATON_SCRIPT, the stored stdin file): a byte changed between two phases
swap_at() {
  in_act "$1" "n=\$(cat '$2/count' 2>/dev/null || echo 0); echo \$((n + 1)) > '$2/count'; if [ \"\$n\" = $3 ]; then chmod u+w \"\$BATON_SCRIPT\"; printf '#x\\n' >> \"\$BATON_SCRIPT\"; fi"
}
fam_go_stdin() {
  local P=$1 W A f sd n k
  fresh_state; W=$(fresh); A=$(act_in "$P" "$W"); bt "$P" "$W" mode auto >/dev/null; sd="$(baton_dir)/stdin"
  age "$A" 600                                     # an old file on stdin: the bytes sent now are what runs, no age check
  eq "$(bts "$P" "$W" "$A" go - "$W/s1.txt" hello)" 0 "[go-stdin] a baton on stdin: rc 0"
  grep -q "^go: ok — 1 write — $(baton_dir)/runs/[^/]*\.log\$" "$BT_OUT" && [ "$(wc -l < "$BT_OUT" | tr -d ' ')" = 1 ] \
    && ok "[go-stdin] …one line 'go: ok — 1 write — <run log>'" || bad "[go-stdin] …one line 'go: ok — 1 write — <run log>' ($(head -c 300 "$BT_OUT"))"
  eq "$(cat "$W/s1.txt" 2>/dev/null)" hello "[go-stdin] …the target written"
  f=$(find "$sd" -name '*.sh' 2>/dev/null | head -n 1)
  eq "$(find "$sd" -name '*.sh' 2>/dev/null | wc -l | tr -d ' ')" 1 "[go-stdin] …one stored script under <state>/stdin"
  eq "$(sha256sum < "${f:-/dev/null}" | cut -c1-64)" "$(sha256sum < "$A" | cut -c1-64)" "[go-stdin] …its sha256 is the input's"
  eq "$(python3 -c 'import os, stat, sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "${f:-/dev/null}")" 0o400 "[go-stdin] …read-only (0400)"
  case "$(basename "${f:-x}")" in [0-9]*T[0-9]*Z-[0-9]*-"$(sha256sum < "$A" | cut -c1-12)".sh) ok "[go-stdin] …named <stamp>-<sha12>.sh";;
    *) bad "[go-stdin] …named <stamp>-<sha12>.sh ($(basename "${f:-x}"))";; esac
  eq "$(grep -vF "$(printf '\trun-start\t')" "$(baton_dir)/log.tsv" | tail -n 2 | cut -f2,3,10 | tr '\t\n' ':;')" "sign:$(basename "${f:-x}"):signed;run:$(basename "${f:-x}"):ok;" \
     "[go-stdin] …the sign and run lines name the stored file"
  eq "$(bts "$P" "$W" "$A" go --by coordinator-auto - "$W/s2.txt" hello)" 0 "[go-stdin] the same bytes again (with --by): rc 0"
  eq "$(find "$sd" -name '*.sh' | wc -l | tr -d ' ')" 2 "[go-stdin] …a second stored file, the first not overwritten"
  # a byte changed in the stored file between two phases: refused, nothing written
  for k in 0 1; do
    fresh_state; bt "$P" "$W" mode auto >/dev/null; rm -f "$W/count"
    f="$W/swap$k.sh"; cp "$A" "$f"; swap_at "$f" "$W" "$k"
    eq "$(bts "$P" "$W" "$f" go - "$W/w$k.txt" hello)" 3 "[go-stdin] a byte changed during $( [ "$k" = 0 ] && echo "go's rehearse (before sign)" || echo "sign's rehearse (before run)"): rc 3"
    [ ! -e "$W/w$k.txt" ] && ok "[go-stdin] …nothing written ($k)" || bad "[go-stdin] …nothing written ($k)"
    eq "$(nsig)" 0 "[go-stdin] …no signature left ($k)"
  done
  # usage: nothing to read, too much, a terminal, --reuse; nothing stored
  fresh_state; bt "$P" "$W" mode auto >/dev/null; sd="$(baton_dir)/stdin"
  eq "$(bts "$P" "$W" /dev/null go - "$W/u.txt" hello)" 64 "[go-stdin] empty stdin: rc 64"
  : > "$W/blank.sh"; printf '\n \n' > "$W/blank.sh"
  eq "$(bts "$P" "$W" "$W/blank.sh" go - "$W/u.txt" hello)" 64 "[go-stdin] blank stdin: rc 64"
  python3 -c 'import sys; sys.stdout.write("#" * (256 * 1024 + 1))' > "$W/big.sh"
  eq "$(bts "$P" "$W" "$W/big.sh" go - "$W/u.txt" hello)" 64 "[go-stdin] more than 256 KiB on stdin: rc 64"
  python3 -c 'import sys; sys.stdout.write("#" * (256 * 1024))' > "$W/cap.sh"
  eq "$(bts "$P" "$W" "$W/cap.sh" go - "$W/u.txt" hello)" 1 "[go-stdin] control: exactly 256 KiB is read (then check fails it: rc 1)"
  rm -rf "$sd"
  eq "$(bts "$P" "$W" "$A" go --reuse - "$W/u.txt" hello)" 64 "[go-stdin] --reuse -: rc 64"
  eq "$(bts "$P" "$W" "$A" go --by coordinator-auto --reuse - "$W/u.txt" hello)" 64 "[go-stdin] --by … --reuse -: rc 64"
  n=$( (cd "$W" && cenv XDG_STATE_HOME="$ST" python3 - "$P/scripts/baton.py" <<'PY'
import os, pty, subprocess, sys
m, s = pty.openpty()
try:
    print(subprocess.run([sys.executable, sys.argv[1], "go", "-", "x"], stdin=s, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         timeout=10).returncode)
except subprocess.TimeoutExpired:
    print("timeout")
PY
) )
  eq "$n" 64 "[go-stdin] stdin a terminal: rc 64, no wait for input"
  [ ! -e "$sd" ] || [ -z "$(ls -A "$sd")" ] && ok "[go-stdin] …nothing stored by a refused input" || bad "[go-stdin] …nothing stored by a refused input ($(ls "$sd"))"
  # a baton the session may not sign: exit 8, the owner's commands name the stored file, which stays
  fresh_state; bt "$P" "$W" mode auto >/dev/null; sd="$(baton_dir)/stdin"
  f="$W/stop.sh"; cp "$A" "$f"; mutate "$f" '# Stops: none' '# Stops: publish'
  eq "$(bts "$P" "$W" "$f" go - "$W/o.txt" hello)" 8 "[go-stdin] a Stops baton on stdin: exit 8"
  n=$(find "$sd" -name '*.sh' | head -n 1)
  has "$(cat "$BT_OUT")" "on the owner's go: " "[go-stdin] …the owner's sign command"
  has "$(grep "^on the owner's go: \|^then: " "$BT_OUT")" "$n" "[go-stdin] …naming the stored file"
  [ -n "$n" ] && cmp -s "$n" "$f" && ok "[go-stdin] …which holds the bytes sent" || bad "[go-stdin] …which holds the bytes sent"
  [ ! -e "$W/o.txt" ] && ok "[go-stdin] …nothing written" || bad "[go-stdin] …nothing written"
  # the prune keeps the newest 200, and every stored script younger than 7 days (an exit-8 card names it): 210 old ones and one
  # pending from yesterday sort before the exit-8 baton above and the new one: 213, so 13 candidates, 12 removed, the pending kept
  python3 - "$sd" <<'PY'
import os, sys, time
for i in range(210):
    p = os.path.join(sys.argv[1], "20000101T000000Z-1-%03d.sh" % i); open(p, "w").close(); os.utime(p, (time.time() - 8 * 86400,) * 2)
p = os.path.join(sys.argv[1], "20000101T000000Z-0-pending.sh"); open(p, "w").close(); os.utime(p, (time.time() - 86400,) * 2)
PY
  eq "$(bts "$P" "$W" "$A" go - "$W/p.txt" hello)" 0 "[go-stdin] a go - with 212 stored scripts: rc 0"
  [ -e "$sd/20000101T000000Z-0-pending.sh" ] && ok "[go-stdin] …the prune keeps a stored script younger than 7 days" \
    || bad "[go-stdin] …the prune keeps a stored script younger than 7 days"
  eq "$(find "$sd" -name '20000101T000000Z-1-*.sh' | wc -l | tr -d ' ')" 198 "[go-stdin] …and removes the old ones beyond the newest 200"
  # a burst of 1000 young ones (1 day): 201 + 1000 + the new one = 1202, the 202 first names go whatever their age
  python3 - "$sd" <<'PY'
import os, sys, time
for i in range(1000):
    p = os.path.join(sys.argv[1], "20000101T000001Z-2-%04d.sh" % i); open(p, "w").close(); os.utime(p, (time.time() - 86400,) * 2)
PY
  eq "$(bts "$P" "$W" "$A" go - "$W/q.txt" hello)" 0 "[go-stdin] a go - with 1202 stored scripts: rc 0"
  eq "$(find "$sd" -name '*.sh' | wc -l | tr -d ' ')" 1000 "[go-stdin] …a burst of young ones is still cut to the newest 1000"
}

FAMILIES="fam_new fam_check_header fam_check_rehearse_path fam_check_undo fam_check_syntax fam_check_pipefail fam_check_fidelity
fam_check_source fam_check_gate fam_check_unwrapped fam_check_round3 fam_check_round4 fam_check_set fam_check_stops fam_rehearse_expect fam_rehearse_verdict fam_run_signed fam_sign_seal fam_sign_by fam_run_edited fam_run_args fam_run_dir
fam_run_env fam_run_diverged fam_run_pipe fam_run_plan fam_run_undo fam_run_interrupt fam_start_interrupt fam_run_after_use fam_round2_streams fam_modes fam_mode_choice fam_log_env fam_state_place fam_rule fam_kit fam_kit_dep fam_plugin_script fam_plan_env fam_each
fam_go_equiv fam_go_owner fam_go_attack fam_go_retry fam_go_fresh fam_check_refuses fam_skill_skeleton
fam_stop_hint fam_gh_state fam_wait fam_skill_refs fam_expect_doc fam_expect_header fam_core_ops fam_pipe_trap fam_run_line fam_run_last fam_go_stdin fam_go_dash_guidance"

echo "== the real plugin =="
REAL="$TMP/real"; mk_plugin_copy "$REAL"
for f in $FAMILIES; do echo "-- $f"; "$f" "$REAL"; done

echo "== planted breaks: each family must go red on a plugin copy with one break in baton.py or the rule =="
B=plugins/vibemaestro-sdlc/scripts/baton.py
# BRK <label> <family> <needle> <old> <new> [<old> <new>]... — a plugin copy with the replacements in baton.py, then expect_red
BRK() {
  local label=$1 fam=$2 needle=$3 d; shift 3; d="$TMP/break-$label"; mk_plugin_copy "$d"
  while [ $# -ge 2 ]; do mutate "$d/scripts/baton.py" "$1" "$2" || return; shift 2; done
  expect_red "$label" "$fam" "$d" "$needle"
}
BRK each-count-unchecked fam_each '[each] a planted extra plan line' '        elif counts[0] < 1 or counts[0] != len(plan):' '        elif False:'
BRK each-in-session-baton fam_each '[each] Each in a session baton: check rc 1' '                if not s.kit:' '                if False:'
BRK each-empty-line fam_each '[each] an empty plan line' '        good = p is not None and e is not None and fnmatch.fnmatchcase(p, e) and (each is None or p != "")' '        good = p is not None and e is not None and (fnmatch.fnmatchcase(p, e) or p == "")'
BRK new-overwrites fam_new '[new] an existing file: rc 6' 'os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644' 'os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o644'
BRK header-undo-dropped fam_check_header '[check-header] no Undo field' '"Blast", "Undo", "Pre"' '"Blast", "Pre"'
BRK rehearse-path-unchecked fam_check_rehearse_path '[check-rehearse-path] no rehearse branch' \
    $'    for ph in PHASES:\n        what =' $'    for ph in [x for x in PHASES if x != "rehearse"]:\n        what ='
BRK undo-unchecked fam_check_undo '[check-undo] no undo() function' 'if ph in ("postcheck", "undo") and not defs.get(ph):' 'if ph in ("postcheck",) and not defs.get(ph):'
BRK bash-n-skipped fam_check_syntax '[check-syntax] a syntax error' 'subprocess.run([shutil.which("bash"), "-n"], input=s.data' 'subprocess.run([shutil.which("true")], input=s.data'
BRK pipefail-lint-off fam_check_pipefail '[check-pipefail] unguarded diff' '        for w in unguarded_pipes(masked):' '        for w in []:'
BRK fidelity-lint-off fam_check_fidelity '[check-fidelity] the phase tested outside write()' 'if k not in inside and not PHASE_LINE.match(code)' 'if False and k not in inside and not PHASE_LINE.match(code)'
BRK phase-reread-allowed fam_check_fidelity '[check-fidelity] BATON_PHASE read a second time' 'for n in phase_reads[1:]]' 'for n in phase_reads[9:]]'
BRK source-lint-off fam_check_source "[check-source] '. ./lib.sh'" '        if sources_file(masked):' '        if False:'
BRK stop-lint-off fam_check_stops '[check-stops] gh repo delete' 'm = None if cat in declared else re.search(rx, joined)' 'm = None'
BRK expect-not-compared fam_rehearse_expect '[rehearse-expect] plan differs from Expect' 'good = p is not None and e is not None and fnmatch.fnmatchcase(p, e)' 'good = True'
BRK verdict-not-required fam_rehearse_verdict '[rehearse-verdict] rc 0 and the plan, but no verdict' '    if not verdict_ok(lines, "rehearse"):' '    if False:'
# run without a signature: a missing record is written on the fly (the bypass the signature exists to stop)
BRK unsigned-runs fam_run_signed '[run-signed] unsigned: rc 3' \
    $'    rec = load_json(sig) if os.path.exists(sig) else None\n' \
    $'    if not os.path.exists(sig):\n        _g, _p, _r = rehearse(s, args, [])\n        write_private(sig, json.dumps({"binding": binding, "script_sha256": s.sha, "args": args, "cwd": cwd, "env": env, "signed_by": "owner", "v": 2, "dialog": "planted", "plan_sha256": plan_sha(_p)}))\n    rec = load_json(sig) if os.path.exists(sig) else None\n'
BRK signature-reused fam_run_signed '[run-single-use] the same run again: rc 3' 'os.rename(sig, os.path.join(d, "used", "%s-%s.json" % (stamp, binding)) if queued is None' 'os.path.exists(sig) or (sig, os.path.join(d, "used", "%s-%s.json" % (stamp, binding)) if queued is None'
# the binding and the record check both ignore the script bytes / the arguments / the directory (two defences, so two edits)
BRK bytes-unbound fam_run_edited '[run-edited] edited after signing: rc 3' \
    '{"v": 1, "script_sha256": script_sha, "args"' '{"v": 1, "script_sha256": "", "args"' \
    '(rec.get("binding"), rec.get("script_sha256"), rec.get("args"), rec.get("cwd"),' '(rec.get("binding"), s.sha, rec.get("args"), rec.get("cwd"),'
BRK args-unbound fam_run_args '[run-args] other arguments: rc 3' \
    '"args": list(args), "cwd": cwd, "env": env}' '"args": [], "cwd": cwd, "env": env}' \
    'rec.get("args"), rec.get("cwd"),' 'args, rec.get("cwd"),'
BRK dir-unbound fam_run_dir '[run-dir] run from another directory: rc 3' \
    '"args": list(args), "cwd": cwd, "env": env}' '"args": list(args), "cwd": "", "env": env}' \
    'rec.get("args"), rec.get("cwd"),' 'rec.get("args"), cwd,'
BRK plan-unbound fam_run_plan '[run-plan] the plan changed since signing: rc 3' '            if plan_sha(plan) != rec.get("plan_sha256"):' '            if False:'
BRK undo-not-called fam_run_undo '[run-undo] post-check mismatch: rc 4' $'            if result != "ok":\n                rc, lines, _w = run_phase(s, args, "undo", sinks, plan=rec.get("plan") or [], undo_only=undo_only)' $'            if False:\n                rc, lines, _w = run_phase(s, args, "undo", sinks, plan=rec.get("plan") or [], undo_only=undo_only)'
BRK auto-ignores-stops fam_modes '[modes] auto + a declared stop: coordinator-auto cannot sign' $'    if stops:\n        return "the script declares stop' $'    if False:\n        return "the script declares stop'
# the rule: one alternative removed, and a pattern that would read baton itself
BRKF() {
  local label=$1 fam=$2 needle=$3 d; d="$TMP/break-$label"; mk_plugin_copy "$d"
  mutate "$d/$4" "$5" "$6" && expect_red "$label" "$fam" "$d" "$needle"
}
BRKF rule-misses-merge fam_rule "[rule] 'gh pr merge 12 --squash' reminds" rules/batonrun.instructions.md 'merge\b|' 'merge-never\b|'
BRKF rule-exponential fam_rule '[rule] the applyWhen regex stays linear' rules/batonrun.instructions.md '\bclaude(?:\s+-{1,2}(?!-)' '\bclaude(?:\s+-{1,2}'
BRKF rule-misses-ref-delete fam_rule "[rule] 'git -C /lab/remote.git update-ref -d" rules/batonrun.instructions.md \
  'update-ref\b(?:[^|;&\n]*\s(?:-d\b|' 'update-ref\b(?:[^|;&\n]*\s(?:-never\b|'
BRKF rule-reads-baton fam_rule "[rule] 'python3" rules/batonrun.instructions.md 'applyWhen: "' 'applyWhen: "baton\.py\s+run\b|'
BRK unwrapped-lint-off fam_check_unwrapped '[check-unwrapped] a privileged command outside write()' 'unwrapped_writes(entries, TRUSTED_RUN, True) if s.kit else unwrapped_writes(entries, PLUGIN_SCRIPT_RUN, False)' '[]'
BRK set-off-ignored fam_check_set "[check-set] a later 'set +e" '        flags = (flags | on) - off' '        flags = flags | on'
BRK branches-unchecked fam_check_fidelity '[check-fidelity] the rehearse) and run) branches differ' 'bodies["rehearse"] != bodies["run"]:' 'False:'
BRK plan-echo-allowed fam_check_fidelity '[check-fidelity] a PLAN line printed outside write()' 'if k not in gate and re.search(' 'if False and re.search('
BRK by-defaults-owner fam_log_env '[usage] sign without --by' \
    '    if len(rest) < 2 or rest[0] != "--by" or rest[1] not in SIGNERS:' '    if rest[:1] == ["--by"] and rest[1:2] and rest[1] not in SIGNERS:' \
    '    by, rest = rest[1], rest[2:]' '    by, rest = (rest[1], rest[2:]) if rest[:1] == ["--by"] else ("owner", rest)'
BRK last-by-wins fam_sign_by '[sign-by] --by coordinator-auto --by owner' \
    '        if rest[0] == "--seal" and len(rest) > 1 and seal is None:' $'        if rest[0] == "--by" and len(rest) > 1:\n            by, rest = rest[1], rest[2:]\n        elif rest[0] == "--seal" and len(rest) > 1 and seal is None:'
BRK interrupt-before-run-unknown fam_run_interrupt '[run-interrupt] an interrupt in the rehearse before the run' '            if not consumed:' '            if False:'
BRK group-not-stopped fam_run_interrupt "[run-interrupt] the phase's process group was stopped" 'stderr=subprocess.STDOUT, env=env, start_new_session=True,' 'stderr=subprocess.STDOUT, env=env, start_new_session=False,'
BRK start-unmasked fam_start_interrupt "[start-interrupt] …the phase's group was stopped" '            signal.pthread_sigmask(signal.SIG_BLOCK, stops)' '            signal.pthread_sigmask(signal.SIG_BLOCK, set())'
BRK start-int-unmasked fam_start_interrupt "[start-interrupt] …the phase's group was stopped: no late write (SIGINT)" 'stops = {signal.SIGTERM, signal.SIGHUP, signal.SIGINT}' 'stops = {signal.SIGTERM, signal.SIGHUP}'
BRK start-cleanup-once fam_start_interrupt "[start-interrupt] …the phase's group was stopped: no late write (SIGTERM+HUP)" \
    $'            try:\n                _stop_phase(proc, stops)\n            except BaseException:\n                try:' \
    $'            if True:\n                _stop_phase(proc, stops)\n            if False:\n                try:'
BRK gate-unchecked fam_check_gate '[check-gate] a write() that also executes' 'gate_body(s.text) != want:' 'False:'
BRK branch-mask-allowed fam_check_gate "[check-gate] both branches run 'act || true'" 'if any(re.search(r"\|\||&&", st) or re.match(r"^(?:if|!)\s", st) for st in stmts):' 'if False:'
BRK local-run-allowed fam_check_source '[check-source] running a local ./helper.sh' '        if LOCAL_RUN.match(raw) and not (trusted and trusted_outside and trusted.match(raw)):' '        if False:'
BRK seal-unchecked fam_sign_seal '[sign-seal] the script changed since it was shown' '    if seal_of(binding, plan) != seal:' '    if False:'
BRK env-unbound fam_run_env '[run-env] run with another GH_REPO' \
    '"cwd": cwd, "env": env}, sort_keys=True' '"cwd": cwd, "env": {}}, sort_keys=True' \
    'rec.get("env")) != (binding, s.sha, args, cwd, env):' 'env) != (binding, s.sha, args, cwd, env):'
BRK bash-env-kept fam_run_env '[run-env] BASH_ENV is not run' 'if k not in SHELL_HOOKS and not k.startswith("BASH_FUNC_")}' 'if True}'
BRK do-lines-unchecked fam_run_diverged '[run-diverged] the run did other writes' '            elif done != plan:' '            elif False:'
BRK do-lines-from-stdout fam_run_diverged '[run-diverged] control: such output is not read as writes' '            elif done != plan:' '            elif [x[3:] for x in lines if x.startswith("DO ")] != plan:'
BRK tools-as-wrapped fam_check_unwrapped '[check-unwrapped] reading and writing with the same tool' 'wrapped = set(name for name in target.values() if name in spans)' 'wrapped = set(target.values())'
BRK dry-push-flagged fam_check_unwrapped '[check-unwrapped] dry runs and auth can-i are reads' '    return bool(DRY_RUN.search(masked) or' '    return False and bool(DRY_RUN.search(masked) or'
BRK git-options-ambiguous fam_check_unwrapped '[check-unwrapped] a git line with 2000 global options' '|--(?!(?:git-dir|work-tree|namespace)(?:\s|$))[\w-]+' '|--[\w-]+'
BRK verdict-echo-only fam_check_gate '[check-gate] control: printf verdicts' 'if not re.search(r"VERDICT\s+\w+\s+ok", st)]' 'if not re.match(r"^echo\s+VERDICT", st)]'
BRK signals-unhandled fam_round2_streams "[round2] the stopped rehearse's script did not write late" '            signal.signal(sig, _on_term)' '            pass'
BRK closed-stdout fam_round2_streams '[round2] run with stdout closed' 'stream = getattr(sys, name) or open(os.devnull, "w")' 'stream = getattr(sys, name)'
BRK stdout-breaks fam_run_pipe "[run-pipe] 'run | head' of a failing run" '        setattr(sys, name, SafeOut(stream))' '        setattr(sys, name, stream)'
BRK manual-run-unchecked fam_modes '[modes] manual again: a pending coordinator-auto signature is refused' '    why = allowed(signer, mode, stops, s.value_why())' '    why = None'
BRK substitutions-unsplit fam_check_round3 '[check-round3] a write inside local x=' 'SEPARATORS = re.compile(r"\|\||&&|;;|(?<![<>&])&(?![&>])|[;|\n`()]|\$\(\(?|[<>]\(")' 'SEPARATORS = re.compile(r"\|\||&&|;;|(?<![<>&])&(?![&>])|[;|\n]")'
BRK path-prefix-missed fam_check_round3 '[check-round3] a write with a path prefix' 'prefix = re.match(r"\S*/", whole)' 'prefix = None'
BRK xargs-arg-missed fam_check_round3 '[check-round3] a write behind xargs -I %' '"xargs": "ILnPdEsa", ' '"xargs": "", '
BRK bang-not-stripped fam_check_round3 '[check-round3] a write after !' 'HEAD = re.compile(r"\s*(?:\{|\(|\"?\$\(|!|' 'HEAD = re.compile(r"\s*(?:\{|\(|\"?\$\(|'
BRK dry-on-raw fam_check_round3 '[check-round3] a quoted --dry-run' 'not is_dry(word, whole_masked)' 'not is_dry(word, whole)'
BRK dry-false-is-dry fam_check_round3 '[check-round3] --dry-run=false' 'DRY_RUN = re.compile(r"\s--dry-run(?:=(?:server|client|true))?(?![\w=-])")' 'DRY_RUN = re.compile(r"\s--dry-run")'
BRK attached-field-missed fam_check_round3 '[check-round3] gh api -ftitle' '(?=[^|;&\n]*\s(?:-[fF]\S*|--(?:raw-)?field|--input)(?:\s|=|$))' '(?=[^|;&\n]*\s(?:-[fF]|--(?:raw-)?field|--input)(?:\s|=|$))'
BRK mutation-missed fam_check_round3 '[check-round3] a graphql mutation' '    r"gh\s+api\s+graphql\b(?=[^|;&\n]*(?i:mutation))",' ''
BRK update-branch-missed fam_check_round3 '[check-round3] gh pr update-branch' '|rerun|cancel|run|update-branch)(?![\w-])' '|rerun|cancel|run)(?![\w-])'
BRK quoted-delete-missed fam_check_round3 '[check-round3] a quoted DELETE' $'(?:-X\\s*|--method[\\s=]+)[\\"\']?(?i:DELETE)\\b"),' $'(?:-X\\s*|--method[\\s=]+)(?i:DELETE)\\b"),'
BRK verb-word-boundary fam_check_round3 '[check-round3] gh repo set-default' '|rerun|cancel|run|update-branch)(?![\w-])' '|rerun|cancel|run|update-branch)\b'
BRK plan-end-naive fam_check_round3 '[check-round3] a helper whose plan line holds' '    c = word_end(code, j)' '    c = j + len(re.match(r"\S*", code[j:]).group(0))'
BRK push-options-ambiguous fam_check_round3 '[check-round3] a bare line with 2000 options' '    r"dock''er(?:\s+-{1,2}(?!-)[\w-]+' '    r"dock''er(?:\s+-{1,2}[\w-]+'
BRK plan-from-stdout fam_check_round3 '[check-round3] output without a final newline before a write' '    rc, lines, plan = run_phase(s, args, "rehearse", sinks)' '    rc, lines, plan = run_phase(s, args, "rehearse", sinks); plan = [x[5:] for x in lines if x.startswith("PLAN ")]'
BRK verdict-exact fam_check_round3 '[check-round3] output without a final newline before the verdict' 'tail[-1].endswith("VERDICT %s ok" % phase)' 'tail[-1] == "VERDICT %s ok" % phase'
BRK writes-strict fam_check_round3 '[check-round3] a plan line with a non-UTF-8 byte' 'w.decode("utf-8", "backslashreplace")' 'w.decode("utf-8", "surrogateescape")' 'data.encode("utf-8", "surrogateescape")).hexdigest()' 'data.encode("utf-8")).hexdigest()'
BRK sighup-unhandled fam_round2_streams "[round2] the SIGHUP-stopped rehearse's script" '    for sig in (signal.SIGTERM, signal.SIGHUP):
        if signal.getsignal' '    for sig in (signal.SIGTERM,):
        if signal.getsignal'
BRK nohup-overridden fam_round2_streams '[round2] under nohup' 'if signal.getsignal(sig) is not signal.SIG_IGN:' 'if True:'
BRK git-config-unbound fam_round2_streams '[round2] run with another GIT_CONFIG_COUNT' ' | set(k for k in os.environ if k.startswith(("GIT_CONFIG", "PYTHON")))' ''
BRK stderr-unwrapped fam_round2_streams '[round2] run with a stderr nobody reads' '        setattr(sys, name, SafeOut(stream))' '        setattr(sys, name, SafeOut(stream) if name == "stdout" else stream)'
BRK whole-command-unread fam_check_round4 '[check-round4] git -C' '            whole, whole_masked = command_text(code, masked, i)' '            whole, whole_masked = code[i:end], masked[i:end]'
BRK labels-as-commands fam_check_round4 '[check-round4] a case pattern ./*)' 'if masked[pos:end].strip() and not (label or inert or after_group):' 'if masked[pos:end].strip():'
BRK xargs-i-swallows fam_check_round4 '[check-round4] xargs -i keeps the command' '"xargs": "ILnPdEsa", ' '"xargs": "IiLlnPdEsa", '
BRK paren-label-blind fam_check_round4 '[check-round4] source after a (a) case label' '|^\s*\(?[^\s()|;&]+(?:\s*\|' '|^\s*[^\s()|;&]+(?:\s*\|'
BRK dq-backtick-masked fam_check_round4 '[check-round4] a write in backticks inside double quotes' $'                elif ch == "`":\n                    stack.append(["c", 0, True, "`"])' $'                elif False:\n                    stack.append(["c", 0, True, "`"])'
BRK consumed-ignored fam_run_after_use "[run-after-use] Ctrl-C after the signature was used" '        if RUN["consumed"]:' '        if False:'
BRK term-after-run fam_run_after_use '[run-after-use] SIGTERM once the phases are over' $'                signal.signal(sig, signal.SIG_IGN)' $'                pass'
BRK auto-in-manual fam_modes '[modes] manual: coordinator-auto cannot sign' '    if mode != "auto":' '    if False:'

BRK kit-name-loose fam_kit '[kit] kit:a.b: rc 64' 'KIT_RE = re.compile(r"^[a-z0-9][a-z0-9-]*\Z")' 'KIT_RE = re.compile(r"^[A-Za-z0-9./-]*\Z")'
BRK kit-link-followed fam_kit '[kit] kit:t-link: rc 64' '    if os.path.dirname(os.path.realpath(path)) != root:' '    if False:'
BRK kit-root-unbound fam_kit '[kit] a signature from another plugin copy' '            self.bind_sha = sha256(self.sha + "\0kit:" + self.from_kit.batons)' '            self.bind_sha = self.sha'
BRK kit-dep-dependency-unread fam_kit_dep '[kit-dep] a plugin without the dependency: refused' '            elif not depends_on_sdlc(' '            elif False and not depends_on_sdlc('
BRK kit-dep-dependency-any-market fam_kit_dep "[kit-dep] a dependency on another marketplace's" '        if n in (SDLC, "%s@%s" % (SDLC, market)):' '        if isinstance(n, str) and n.startswith(SDLC):'
BRK kit-dep-market-unchecked fam_kit_dep '[kit-dep] …a plugin from another marketplace: named' '            if m != market:' '            if False:'
BRK kit-dep-path-unchecked fam_kit_dep '[kit-dep] an id of our marketplace installed under another: refused' '            elif os.path.dirname(real) != home or not' '            elif not'
BRK kit-dep-both-run fam_kit_dep '[kit-dep] a kit name sdlc also ships: refused' $'        if found:\n            raise Stop(USAGE, "%s: both' $'        if False:\n            raise Stop(USAGE, "%s: both'
BRK kit-dep-ineligible-blocks fam_kit_dep '[kit-dep] an sdlc kit that ineligible plugins also ship' $'        if found:\n            raise Stop(USAGE, "%s: both' $'        if found or refused:\n            raise Stop(USAGE, "%s: both'
BRK kit-dep-sdlc-entry-raises fam_kit_dep '[kit-dep] a NUL or a lone surrogate in an sdlc installPath' \
    '    if not any(isinstance(e, dict) and usable_path(e.get("installPath")) and' '    if not any(isinstance(e, dict) and isinstance(e.get("installPath"), str) and'
BRK kit-dep-dep-entry-raises fam_kit_dep '[kit-dep] a dependent entry with a NUL or a lone surrogate' \
    $'        if not usable_path(inst):\n            continue' $'        if not isinstance(inst, str) or not os.path.isabs(inst) or "\\0" in inst:\n            continue'
BRK kit-dep-version-dir-loose fam_kit_dep '[kit-dep] a version directory named latest: refused' \
    'or not INSTALL_DIR.match(os.path.basename(real)):' 'or os.path.basename(real).startswith("."):'
BRK kit-dep-version-dir-any fam_kit_dep '[kit-dep] a version directory the launcher would not accept: refused' \
    '            elif os.path.dirname(real) != home or not INSTALL_DIR.match(os.path.basename(real)):' '            elif os.path.dirname(real) != home:'
BRK kit-dep-subdir-refused fam_kit_dep '[kit-dep] a dependent plugin at a git-subdir directory' \
    '(?:-[0-9a-f]{8})?|unknown)\Z")' '|unknown)\Z")'
BRK kit-dep-subdir-loose fam_kit_dep '[kit-dep] a git-subdir directory with 7 hex after the dash: refused' \
    '(?:-[0-9a-f]{8})?|unknown)\Z")' '(?:-[0-9a-f]{7,8})?|unknown)\Z")'
BRK kit-dep-manifest-link fam_kit_dep '[kit-dep] a .claude-plugin/ that is a symlink: refused' '            elif os.path.realpath(manifest) != manifest:' '            elif False:'
BRK kit-dep-registry-any-version fam_kit_dep '[kit-dep] a registry of another version' \
    '    ids = data.get("plugins") if isinstance(data, dict) and data.get("version") == REGISTRY_VERSION else None' '    ids = data.get("plugins") if isinstance(data, dict) else None'
BRK kit-dep-card-unnamed fam_kit_dep "[kit-dep] …the card's first line names the plugin" \
    '" (a kit of %s)" % log_value(s.from_kit.pid) if s.kit and s.from_kit.pid else ""' '""'
BRK kit-dep-two-run fam_kit_dep '[kit-dep] two dependent plugins ship the name: refused' '    if len(found) > 1:' '    if False:'
BRK kit-dep-link-followed fam_kit_dep '[kit-dep] a kit file that is a symlink out of its batons/: refused' '            elif os.path.dirname(os.path.realpath(path)) != batons:' '            elif False:'
BRK kit-dep-bound-to-sdlc fam_kit_dep '[kit-dep] a signature from another install' '            self.bind_sha = sha256(self.sha + "\0kit:" + self.from_kit.batons)' '            self.bind_sha = sha256(self.sha + "\0kit:" + KIT_ROOT)'
BRK kit-dep-sdlc-root fam_kit_dep "[kit-dep] …BATON_PLUGIN_ROOT is the dependent plugin's root" '            env["BATON_PLUGIN_ROOT"] = s.from_kit.root' '            env["BATON_PLUGIN_ROOT"] = plugin_real()'
BRK kit-dep-self-unlisted fam_kit_dep '[kit-dep] a registry that does not list this sdlc copy' ' and os.path.realpath(e["installPath"]) == me' ''
BRK kit-dep-registry-from-env fam_kit_dep '[kit-dep] …even with CLAUDE_CONFIG_DIR' \
    '    if os.path.basename(parent) != SDLC or os.path.basename(cache) != "cache":' '    if False:' \
    '    plugins, market = os.path.dirname(cache), os.path.basename(mdir)' '    plugins, market = os.path.join(claude_config_dir(), "plugins"), "vibemaestro"' \
    ' and os.path.realpath(e["installPath"]) == me' ''
# two defences keep a gate out of a session baton: the trusted form is the kit's only, and the variable's one word is scripts/
BRK trusted-anywhere fam_kit '[kit] the same line in a session baton: check rc 1' \
    'unwrapped_writes(entries, PLUGIN_SCRIPT_RUN, False)' 'unwrapped_writes(entries, TRUSTED_RUN, True)' \
    '    if names != runs:' '    if False:'
BRK trusted-loose fam_kit '[kit] a kit baton with another form (python3 -I -B "$BATON_PLUGIN_ROOT/gates/../scripts/x.py")' 'TRUSTED_GATE = r"gates/[A-Za-z0-9_]+\.py"' 'TRUSTED_GATE = r"[^\"]*"'
# plugin scripts in a session baton: each defence on its own (two edits where two defences cover one case)
BRK ps-count-unchecked fam_plugin_script '[plugin-script] refused at check: R=$(dirname' '    if names != runs:' '    if False:'
BRK ps-run-outside-write fam_plugin_script '[plugin-script] refused at check: bash "$BATON_PLUGIN_ROOT/scripts/t-tool.sh" "$DEST"' \
    'unwrapped_writes(entries, PLUGIN_SCRIPT_RUN, False)' 'unwrapped_writes(entries, PLUGIN_SCRIPT_RUN, True)' '    if names != runs:' '    if False:'
BRK ps-sha-not-in-plan fam_plugin_script '[plugin-script] a plan line with the sha of another file' \
    '        if not sha or not any(re.search(r"(?<![0-9a-fA-F])%s(?![0-9a-fA-F])" % sha, p) for p in plan):' '        if False:'
BRK ps-sha-substring fam_plugin_script '[plugin-script] the sha only inside a longer hex word' \
    're.search(r"(?<![0-9a-fA-F])%s(?![0-9a-fA-F])" % sha, p)' 'sha in p'
BRK ps-tree-unbound fam_plugin_script '[plugin-script] a sibling under scripts/ edited after signing' \
    '"\0" + self.tree_sha)' '"\0")'
BRK ps-root-unbound fam_plugin_script '[plugin-script] the same baton under a second plugin copy' \
    '"\0plugin:" + plugin_real() + "\0"' '"\0plugin:" + "\0"'
BRK ps-python-unbound fam_plugin_script '[plugin-script] the run with a PYTHONPATH the signature did not see' \
    'k.startswith(("GIT_CONFIG", "PYTHON"))' 'k.startswith("GIT_CONFIG")'
BRK ps-caller-root fam_plugin_script '[plugin-script] …run (a caller sets BATON_PLUGIN_ROOT=/planted)' \
    '            env["BATON_PLUGIN_ROOT"] = plugin_real()' '            env.setdefault("BATON_PLUGIN_ROOT", plugin_real())'
BRK ps-pycache-shared fam_plugin_script '[plugin-script] …and with a bytecode directory of its own' \
    '            env["PYTHONPYCACHEPREFIX"] = os.path.join(tmpd, "pycache")' '            pass'
BRK ps-no-rehash fam_plugin_script '[plugin-script] …the runner names scripts/ that changed during the phase' \
    '        if s.plugin_scripts and scripts_tree_sha() != s.tree_sha:' '        if False:'
BRK ps-link-followed fam_plugin_script '[plugin-script] refused at check: the file scripts/t-link.sh' \
    'os.path.islink(path) or os.path.dirname(os.path.realpath(path)) != d' 'False' '    if links:' '    if False:'
BRK ps-links-allowed fam_plugin_script '[plugin-script] refused at check: a link under scripts/' '    if links:' '    if False:'
BRK ps-baton-case fam_plugin_script '[plugin-script] refused at check: the file scripts/Baton.py' \
    'if name.lower() in PLUGIN_SCRIPTS_REFUSED or ' 'if '
BRK ps-baton-allowed fam_plugin_script '[plugin-script] refused at check: the file scripts/baton.py' \
    'if name.lower() in PLUGIN_SCRIPTS_REFUSED or ' 'if ' \
    ' or any(same_file(path, os.path.join(d, x)) for x in PLUGIN_SCRIPTS_REFUSED)' ''
BRK ps-hardlink fam_plugin_script '[plugin-script] refused at check: the file scripts/t-hard.py' \
    ' or any(same_file(path, os.path.join(d, x)) for x in PLUGIN_SCRIPTS_REFUSED)' ''
BRK ps-root-in-rehearse fam_plugin_script '[plugin-script] …the rehearse phase gets no real plugin root' \
    '        elif s.plugin_scripts and phase in ("run", "undo"):' '        elif s.plugin_scripts:'
BRK ps-dotdot fam_plugin_script '[plugin-script] refused at check: the file scripts/../batons/merge-pr.sh' \
    'bash "\$BATON_PLUGIN_ROOT/scripts/([A-Za-z0-9_-]+\.sh)"' 'bash "\$BATON_PLUGIN_ROOT/scripts/([^"]+\.sh)"' \
    'os.path.islink(path) or os.path.dirname(os.path.realpath(path)) != d' 'os.path.islink(path)'
BRK plan-unexported fam_plan_env '[plan-env] run: BATON_PLAN holds the signed plan' '            env["BATON_PLAN"] = planf' '            pass'
BRK plan-name-fixed fam_plan_env '[plan-env] run a script named plan' '            pfd, planf = tempfile.mkstemp(prefix="signed-plan-", dir=tmpd)' '            planf = os.path.join(tmpd, "plan"); pfd = os.open(planf, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)'
BRK root-inherited fam_kit '[kit] a session baton never gets BATON_PLUGIN_ROOT' '        env.pop("BATON_PLUGIN_ROOT", None)' '        pass'
# go: each step it calls, removed or bent in go alone; the equivalence, step, card, attack or retry test goes red
BRK go-check-skipped fam_go_equiv '[go-steps] check: stopped at check' '        probs = check_script(s)' '        probs = []'
BRK go-rehearse-ignored fam_go_equiv '[go-equiv] verdict: go gives the separate commands' $'        if seal is None:\n            sys.stdout.write(held.text())' $'        if False:\n            sys.stdout.write(held.text())'
BRK go-expect-ignored fam_go_equiv '[go-equiv] expect: go gives the separate commands' $'        if seal is None:\n            sys.stdout.write(held.text())' $'        if seal is None and not all(r.startswith("plan line") for r in reasons):\n            sys.stdout.write(held.text())'
BRK go-seal-at-sign fam_go_attack '[go-attack] the script edited inside rehearse 1' '            rc = signed("coordinator-auto", seal, path, args, sheld)' '            rc = signed("coordinator-auto", rehearsed(checked(path), args, Held())[2], path, args, sheld)'
BRK go-sign-skipped fam_go_equiv '[go-equiv] good: go exits 0' '            rc = signed("coordinator-auto", seal, path, args, sheld)' '            rc = OK'
BRK go-run-skipped fam_go_equiv '[go-equiv] good: go wrote the file' '            rc, result, _line, out_path = signed_run(path, args, quiet=rheld, preamble=held)' '            rc, result, _line, out_path = OK, "ok", "", ""'
BRK go-postcheck-misnamed fam_go_equiv '[go-steps] pcfail: stopped at post-check' '"post-check" if at_check else "run"' '"run"'
BRK go-ok-noisy fam_go_equiv '[go-ok] good: one line, stdout and stderr together' 'signed_run(path, args, quiet=rheld, preamble=held)' 'signed_run(path, args, preamble=held)'
BRK go-ok-on-pcfail fam_go_equiv "[go-ok] pcfail: no 'go: ok'" '        if rc != OK or result != "ok":' '        if result in ("run-failed", "run-diverged"):'
BRK go-run-output-hidden fam_go_equiv "[go-fail] runfail: the run step's output is printed (its DO line)" $'            sys.stdout.write(rheld.text())\n            say("full output: %s", out_path)' $'            say("full output: %s", out_path)'
BRK go-rehearse-output-hidden fam_go_equiv "[go-fail] verdict: the step's output is printed" $'        if seal is None:\n            sys.stdout.write(held.text())' $'        if seal is None:\n            pass'
BRK go-sign-output-hidden fam_go_attack "[go-fail] sign: the sign step's output is printed" $'        except BaseException:\n            sys.stdout.write(sheld.text())' $'        except BaseException:\n            pass'
BRK go-log-unnamed fam_go_equiv "[go-ok] good: the line names this run's log" '        say("go: ok — %d write%s — %s", len(plan), "" if len(plan) == 1 else "s", out_path)' '        say("go: ok — %d write%s — %s", len(plan), "" if len(plan) == 1 else "s", d)'
BRK header-twice-allowed fam_check_refuses '[check-refuses] a header field given twice' \
    '            problems.append((i + 1, "header field %s is given twice" % key))' '            pass'
BRK no-expect-allowed fam_check_refuses '[check-refuses] no Expect line' \
    '            probs.append((0, "header: no Expect line (one per planned write)"))' '            pass'
BRK write-twice-allowed fam_check_refuses '[check-refuses] write() defined twice' '    if len(defs.get("write", [])) != 1:' '    if not defs.get("write"):'
BRK postcheck-unchecked fam_check_refuses '[check-refuses] no postcheck() function' \
    'if ph in ("postcheck", "undo") and not defs.get(ph):' 'if ph in ("undo",) and not defs.get(ph):'
BRK set-missing-allowed fam_check_refuses '[check-refuses] no set -euo pipefail at all' '    if not {"e", "u", "pipefail"} <= flags:' '    if False:'
BRKF skeleton-unchecked fam_skill_skeleton '[skeleton] it passes check as written' skills/batonrun/SKILL.md \
    $'set -euo pipefail\nPHASE=${BATON_PHASE:-rehearse}\nwrite() {' $'PHASE=${BATON_PHASE:-rehearse}\nwrite() {'
BRK waits-warning-on-stderr fam_go_retry '[go-retry] a BATON_POSTCHECK_WAITS that is ignored: go still prints one line' \
    '        for out in sinks or [sys.stderr]:' '        for out in [sys.stderr]:'
BRK go-fresh-unchecked fam_go_fresh '[go-fresh] a script last written 600 s ago: rc 1' '        stale = None if reuse else stale_input(s, args)' '        stale = None'
BRK go-fresh-by-path fam_go_fresh '[go-fresh] a fresh symlink to an old file: rc 1' '                self.mtime = os.fstat(f.fileno()).st_mtime' '                self.mtime = os.lstat(path).st_mtime'
BRK go-fresh-future fam_go_fresh '[go-fresh] a file dated 600 s in the future: rc 1' '    if age < -FUTURE_SLACK:' '    if False:'
BRK go-reuse-dropped fam_go_fresh '[go-fresh] …and the exact command with --reuse' '"%s go %s--reuse %s"' '"%s go %s%s"'
BRK go-signs-stop-list fam_go_owner '[go-owner] auto-stops: exit 8' '        why = allowed("coordinator-auto", mode, stops, s.value_why())' '        why = None'
BRK go-by-owner-accepted fam_go_attack '[go-attack] go --by owner: 64' 'if rest[0] != "--by" or len(rest) < 2 or rest[1] != "coordinator-auto":' 'if rest[0] != "--by" or len(rest) < 2 or rest[1] not in SIGNERS:'
BRK go-card-after-detail fam_go_owner "[go-card] auto-stops: '== OWNER DECISION: ' on the card, in order" \
    $'            for ln in card:\n                say("%s", ln)\n            say("detail: %s (check and rehearse output)", detail)' \
    $'            say("detail: %s (check and rehearse output)", detail)\n            for ln in card:\n                say("%s", ln)'
BRK go-card-no-blast fam_go_owner "[go-card] auto-stops: '  Blast:    that one file' on the card" '"  Blast:    %s" % f("Blast"), ' ''
BRK retry-absent fam_go_retry '[go-retry] a post-check that holds on its second reading' '    for k in range(len(waits) + 1):' '    for k in range(1):'
BRK retry-reruns-run fam_go_retry '[go-retry] …one failed-attempt line, the run phase ran once' \
    $'        rc, lines, _w = run_phase(s, args, "postcheck", sinks)\n        if rc == 0 and verdict_ok(lines, "postcheck"):' \
    $'        if k:\n            run_phase(s, args, "run", sinks)\n        rc, lines, _w = run_phase(s, args, "postcheck", sinks)\n        if rc == 0 and verdict_ok(lines, "postcheck"):'
BRK retry-fail-logs-ok fam_go_retry '[go-retry] a post-check that never holds: exit 4' $'                return False\n    return False\n' $'                return False\n    return True\n'
BRK go-card-not-first fam_go_owner '[go-card] auto-stops: the output starts with the card' '        say("go: check ok", out=held)' '        say("go: check ok")'
BRK go-signature-left fam_go_attack '[go-attack] …the signature go made was withdrawn (2)' $'        except Stop:\n            sys.stdout.write(rheld.text())\n            withdraw()\n            raise' $'        except Stop:\n            raise'
BRK go-card-raw fam_go_owner '[go-card] auto-stops: control characters on the card are escaped' '    n, f = len(plan), lambda key: log_value(s.field(key))' '    n, f = len(plan), lambda key: s.field(key)' \
    $'            for ln in card:\n                say("%s", ln)' $'            for ln in card:\n                sys.stdout.write(ln + "\\n")'
BRK go-reason-dropped fam_go_attack '[go-attack] …the stop line gives the reason (1)' '        say("go: stopped at %s (exit %d): %s", step, e.rc, e.text)' '        say("go: stopped at %s (exit %d)", step, e.rc)'
BRK retry-wait-interrupt-unknown fam_go_retry '[go-retry] SIGTERM while waiting to read again: exit 4, undone' $'            except (KeyboardInterrupt, Interrupted):           # the failure is known' $'            except ():           # the failure is known'
BRK go-interrupt-keeps-signature fam_go_attack '[go-attack] an interrupt between sign and run' $'        if step in ("sign", "run"):                     # an interrupt' $'        if False:                     # an interrupt'
BRK go-withdraws-any fam_go_attack '[go-attack] …a signature file another signer rewrote' '            if f.read() != text:' '            if False:'
BRK go-detail-printed fam_go_owner "[go-card] auto-stops: '== rehearse' is in the detail file, not printed" '            say("detail: %s (check and rehearse output)", detail)' '            say("detail: %s (check and rehearse output)", detail); sys.stdout.write(held.text())'
BRK retry-longer-taken fam_go_retry '[go-retry] a longer wait is ignored' 'any(not 0 <= w <= d for w, d in' 'any(not 0 <= w for w, d in'
BRK stop-hint-unnamed fam_stop_hint "[stop-hint] …the pattern's label" '"looks like stop category `%s`: matched `%s` (`%s`) in: %s; if the act does that, "' '"looks like stop category `%s`: %.0s%.0s in: %s; if the act does that, "'
BRK stop-misses-update-ref-d fam_stop_hint '[stop-hint] write "delete feature/old" git -C /lab/remote.git update-ref -d' \
  '(?:-d|--delete)\b"),' '(?:-never)\b"),'
BRK stop-misses-quoted-refspec fam_stop_hint '[stop-hint] write "delete b" git push --force-with-lease=' \
  '|\s[\"'"'"']?\+?:[^\s:\"'"'"']+)"),' '|\s:[^\s:]+)"),'
BRK stop-misses-git-p fam_stop_hint '[stop-hint] write "delete x" git -P -C /lab/remote update-ref -d' '|-[pP](?!\S)|' '|'
BRK stop-misses-stdin-file fam_stop_hint '[stop-hint] git -C /lab/remote.git update-ref --stdin < "$DEST.ops"' \
  '(?=[^|;&\n]*?\s--stdin\b)[^|;&\n<]*<"),' '(?=[^|;&\n]*?\s--stdin\b)[^|;&\n<]*<<<never"),'
BRK stop-misses-refs-dir fam_stop_hint '[stop-hint] write "drop all" rm -rf "$DEST"/refs/*' '|refs/?\*?' '|refs'
BRK stop-misses-combined-flags fam_stop_hint '[stop-hint] write "drop x" git branch -Dq' \
  'BR_FLAGS = r"[acCdDfilmMqrtuv]"' 'BR_FLAGS = r"[A-Z]"'
BRK stop-kit-hint-dropped fam_stop_hint '[stop-hint] …the FAIL line names kit:branch-delete' \
  '+ (BRANCH_KIT_HINT if label in BRANCH_DELETE_LABELS else "")' '+ ""'
BRK stop-misses-settings fam_stop_hint '[stop-hint] a Stops: none baton that adds an allow rule' \
    'SETTINGS_PATH = (SETTINGS_DIR + ' 'SETTINGS_PATH = (r"(?!)" + SETTINGS_DIR + '
BRK stop-settings-hint-dropped fam_stop_hint '[stop-hint] …the FAIL line says how a read-only baton passes' \
    '(SETTINGS_HELD_HINT if label == SETTINGS_HELD_LABEL else "")' '""'
BRK stop-label-drift fam_stop_hint "[stop-hint] the pattern list (limits.md) equals" '("secrets", "gh secret", ' '("secrets", "gh secrets", '
BRKF stop-label-doc-only fam_stop_hint "[stop-hint] the pattern list (limits.md) equals" skills/batonrun/limits.md '; `vault kv|read|write|delete`' ''
BRKF gh-state-any-output fam_gh_state '[gh-state] a 404 JSON body without headers' skills/batonrun/SKILL.md '    "0 HTTP/"*" 200") GH_STATE=exists ;;' '    *) GH_STATE=exists ;;'
BRKF gh-state-rc-uncoupled fam_gh_state '[gh-state] a 200 with a non-zero exit' skills/batonrun/SKILL.md '    "0 HTTP/"*" 200") GH_STATE=exists ;;' '    *" HTTP/"*" 200") GH_STATE=exists ;;'
BRKF gh-state-no-http fam_gh_state '[gh-state] a first line that is not HTTP/' skills/batonrun/SKILL.md '    [1-9]*" HTTP/"*" 404") GH_STATE=absent ;;' '    [1-9]*" "*" 404") GH_STATE=absent ;;'
BRK gh-state-lint-off fam_gh_state "[gh-state] check refuses 'S=\$(gh_state" '    for n in sorted(set(gh_state_in_subshell(entries))):' '    for n in []:'
BRK gh-state-lint-on-code fam_gh_state "[gh-state] control: check accepts 'gh_state \"a|b\"'" $'    for n, _code, masked in entries:\n        masked = FUNC_HEAD.sub' $'    for n, masked, _m in entries:\n        masked = FUNC_HEAD.sub'
BRK gh-state-nested-unseen fam_gh_state "[gh-state] check refuses 'x=\$(cd /; gh_state y)'" '                    if "(" in groups or "`" in groups or prev == "|"' '                    if prev == "|"'
BRK gh-state-block-unseen fam_gh_state "[gh-state] check refuses '{ gh_state y; } | cat'" $'                    if blocks and blocks.pop()[1]:\n                        pending = len(groups)' $'                    if blocks:\n                        blocks.pop()'
BRK gh-state-first-keyword-only fam_gh_state "[gh-state] check refuses 'while a; do if a; then if b; then :; fi; fi; gh_state x; done | cat'" '                    if kw.group(1) in BLOCK_OPENERS:' '                    if kw.group(1) in BLOCK_OPENERS and k == 0:'
BRK gh-state-brace-after-paren fam_gh_state "[gh-state] check refuses '{ v=\${V:-\$(c)}; w=\${W:-\$(c)}; gh_state x; } | cat'" '                while prev != ")":                      # `${V:-$(cmd)}`: a `}` right after `)` closes no block' '                while True:'
BRK gh-state-pipe-amp fam_gh_state "[gh-state] check refuses 'cat |& gh_state x'" '            if not (sep == "&" and prev == "|" and not seg.strip()):   # `|&` is a pipe: keep prev at `|`' '            if True:'
BRKF gh-state-failure-absent fam_gh_state '[gh-state] a 404 JSON body without headers' skills/batonrun/SKILL.md '  case "$rc $proto ${code%$'"'"'\r'"'"'}" in' '  [ "$rc" = 0 ] || { proto=HTTP/2; code=404; }; case "$rc $proto ${code%$'"'"'\r'"'"'}" in'
BRK wait-since-dropped fam_wait '[wait] a name with only an old ok line' '                if t is None or t < since:' '                if t is None:'
BRK wait-failed-counts fam_wait '[wait] only a postcheck-failed line: rc 9' '                if v[9] == "ok":' '                if v[9] in ("ok", "postcheck-failed"):'
BRK wait-first-ok-wins fam_wait '[wait] ok, then a failed re-run' $'                else:\n                    oks.pop(v[2], None)\n' ''
BRK wait-reads-once fam_wait '[wait] a line written during the wait ends it' '            if len(oks) == len(set(names)) or time.time() >= deadline:' '            if True:'
BRK help-other-file fam_skill_refs '[skill-refs] help kits prints kits.md' '        with open(os.path.join(HELP_DIR, rest[0] + ".md"), encoding="utf-8") as f:' '        with open(os.path.join(HELP_DIR, "SKILL.md"), encoding="utf-8") as f:'

# PR E: the Expect paragraph of the core against the matcher, and the core's examples against the code
BRK expect-prefix fam_expect_doc "[expect-doc] the core's FAIL example" 'fnmatch.fnmatchcase(p, e) and (each is None' '(fnmatch.fnmatchcase(p, e) or p.startswith(e)) and (each is None'
BRK expect-casefold fam_expect_doc '[expect-doc] case-sensitive' 'fnmatch.fnmatchcase(p, e) and (each is None' 'fnmatch.fnmatchcase(p.lower(), e.lower()) and (each is None'
BRK expect-order-free fam_expect_doc '[expect-doc] order: the same Expect lines swapped' '    for i in range(max(len(plan), len(expect))):' $'    plan, expect = sorted(plan), sorted(expect)\n    for i in range(max(len(plan), len(expect))):'
BRK expect-count-free fam_expect_doc '[expect-doc] count: two writes, one Expect line' 'for i in range(max(len(plan), len(expect))):' 'for i in range(min(len(plan), len(expect))):'
BRKF expect-doc-flipped fam_expect_doc "[expect-doc] the core's ok example" skills/batonrun/SKILL.md \
    $'Expect `create *` → ok\n- plan `create docs/a.txt`, Expect `create` → FAIL' $'Expect `create *` → FAIL\n- plan `create docs/a.txt`, Expect `create` → ok'
BRK expect-space-prefix fam_expect_doc "[expect-doc] not a prefix, with a space" 'fnmatch.fnmatchcase(p, e) and (each is None' '(fnmatch.fnmatchcase(p, e) or (" " in e and p.startswith(e))) and (each is None'
BRK expect-suffix fam_expect_doc '[expect-doc] the whole line from its start' 'fnmatch.fnmatchcase(p, e) and (each is None' 're.search(fnmatch.translate(e), p) and (each is None'
BRK expect-strip fam_expect_doc '[expect-doc] the whole line to its end' 'fnmatch.fnmatchcase(p, e) and (each is None' 'fnmatch.fnmatchcase(p.strip(), e.strip()) and (each is None'
BRKF expect-text-prefix fam_expect_doc '[expect-doc] the core states it is not a prefix match' skills/batonrun/SKILL.md 'It is not a prefix match.' 'It is a prefix match.'
BRKF expect-text-slash fam_expect_doc '[expect-doc] the core states the glob' skills/batonrun/SKILL.md '(spaces and `/` too)' '(spaces, not `/`)'
BRKF expect-text-count fam_expect_doc '[expect-doc] the core states the count' skills/batonrun/SKILL.md 'The counts must be equal:' 'Extra plan lines are ignored:'
# PR E: the launcher warning of the hook
BRKF trap-once fam_pipe_trap '[pipe-trap] the same piped run, second time in one session' scripts/vsdlc.py \
    '    trap = launcher_trap(cmd) if any(n == BATON_RULE for n, _t in rules) else ""' '    trap = launcher_trap(cmd) if any(n == BATON_RULE for n, _t in rules) and once("trap", sid) else ""'
BRKF trap-quotes-ignored fam_pipe_trap "[pipe-trap] no warning: /state/vibemaestro/baton/bin/baton go x.sh 'a|b'" scripts/vsdlc.py '        elif c == "'"'"'":' '        elif False:'
BRKF trap-semicolon-dropped fam_pipe_trap '[pipe-trap] warns: /state/vibemaestro/baton/bin/baton sign --by owner' scripts/vsdlc.py 'SHELL_OP_CHARS = "|&;<>()"' 'SHELL_OP_CHARS = "|&<>()"'
BRKF trap-rule-ignored fam_pipe_trap '[pipe-trap] no warning (the batonrun rule disabled)' scripts/vsdlc.py '    trap = launcher_trap(cmd) if any(n == BATON_RULE for n, _t in rules) else ""' '    trap = launcher_trap(cmd)'
BRKF trap-ansi-c-plain fam_pipe_trap "[pipe-trap] warns: /state/vibemaestro/baton/bin/baton run x.sh \$'" scripts/vsdlc.py '        elif c == "$" and cmd.startswith("$'"'"'", i):' '        elif False:'
BRKF trap-wrapper-c-only fam_pipe_trap "[pipe-trap] warns: bash -lc" scripts/vsdlc.py '        args = [a for a in seg[j + 1:] if not a.startswith("-")]' '        args = seg[j + 2:j + 3] if seg[j + 1:j + 2] == ["-c"] else []'
BRKF trap-prefix-unseen fam_pipe_trap '[pipe-trap] warns: time ' scripts/vsdlc.py '    found = [prefix] if prefix else []' '    found = []'
BRKF trap-anywhere fam_pipe_trap '[pipe-trap] no warning: git status && echo baton run' scripts/vsdlc.py \
    $'    for seg in _segments(words).values():\n        i, prefix = 0, ""' $'    for seg in _segments(words).values():\n        if _call_in(seg):\n            return _call_in(seg), ""\n        i, prefix = 0, ""'
BRKF trap-not-string fam_pipe_trap '[pipe-trap] a command that is not a string' scripts/vsdlc.py $'    if not isinstance(cmd, str):\n        return ""\n' ''
BRKF trap-keywords-unseen fam_pipe_trap '[pipe-trap] warns: for f in a b; do' scripts/vsdlc.py '        while i < len(seg) and (ASSIGNMENT.match(seg[i]) or seg[i] in KEYWORDS):' '        while i < len(seg) and ASSIGNMENT.match(seg[i]):'
BRKF trap-wrapper-args fam_pipe_trap '[pipe-trap] warns: sudo -u root' scripts/vsdlc.py '            sub = _call_in(seg[i + 1:])' '            sub = _call_in([w for w in seg[i + 1:] if not w.startswith("-")][:2])'
BRKF trap-shell-first-only fam_pipe_trap '[pipe-trap] warns: env bash -c' scripts/vsdlc.py '        j = next((j for j, w in enumerate(seg) if os.path.basename(w) in SHELLS), None)' '        j = 0 if os.path.basename(seg[0]) in SHELLS else None'
BRKF trap-nested-unseen fam_pipe_trap '[pipe-trap] warns: bash -c "bash -c' scripts/vsdlc.py '            sub = _launcher_call(inner)[0] or _wrapped_call(inner, depth + 1)' '            sub = _launcher_call(inner)[0]'
# a generator, not a list: the planted break is slow, never memory-hungry (a 2 GB list starved the CI runner)
BRKF trap-wrapped-quadratic fam_pipe_trap '[pipe-trap] 20000 shells' scripts/vsdlc.py \
    $'        for t in ([" ".join(args)] if os.path.basename(seg[j]) == "eval" else args):' $'        for t in (" ".join(seg[k + 1:]) for k in range(j, len(seg))):'
BRKF trap-open-quote-hides fam_pipe_trap '[pipe-trap] warns (an apostrophe in a heredoc body before it)' scripts/vsdlc.py '    if sub is None and "\n" in cmd:' '    if False:'
# PR E: run prints one line when it holds
BRK run-streams fam_run_line '[run-line] a run that holds prints one line' '        rc, result, _line, out_path = signed_run(path, args, quiet=held, queued=queued)' '        rc, result, _line, out_path = signed_run(path, args, queued=queued)'
BRK run-fail-hidden fam_run_line '[run-line] a failed run prints its whole output' $'    sys.stdout.write(held.text())\n    say("full output: %s", out_path)\n    return rc' $'    say("full output: %s", out_path)\n    return rc'
BRK last-pointer-unwritten fam_run_last '[last] the last log line is the run-start line' '        mark_started(d, out_path, signed_by=signer, **common)
' ''
BRK last-start-is-run fam_run_last '[last] the last log line is the run-start line' 'log_event(d, event="run-start", output=out_path, **common)' 'log_event(d, event="run", output=out_path, **common)'
BRK last-not-replaced fam_run_last '[last] …prints that run log' 'os.replace(tmp, os.path.join(d, "runs", "LAST"))' 'pass'

# PR F: the core's four-line header and its op list
BRK expect-header-order-free fam_expect_header '[expect-header] the same header with two Expect lines swapped' '    for i in range(max(len(plan), len(expect))):' $'    plan, expect = sorted(plan), sorted(expect)\n    for i in range(max(len(plan), len(expect))):'
BRKF expect-header-no-star fam_expect_header '[expect-header] …exactly one of them uses' skills/batonrun/SKILL.md '# Expect: ref create refs/tags/v2 *' '# Expect: ref create refs/tags/v2'
BRKF expect-header-three-lines fam_expect_header '[expect-header] instrument: the core holds one header example' skills/batonrun/SKILL.md $'# Expect: release create v2\n```' '```'
BRKF core-ops-extra-in-core fam_core_ops '[core-ops] the op list in the core equals' skills/batonrun/SKILL.md 'file-pr; never by hand (' 'file-pr, label-create; never by hand ('
BRKF core-ops-missing-in-core fam_core_ops '[core-ops] the op list in the core equals' skills/batonrun/SKILL.md 'pr-body-edit, issue-reopen' 'pr-body-edit'
BRKF core-ops-extra-in-code fam_core_ops '[core-ops] the op list in the core equals' gates/gh_write.py '    "pr-ready": ({"pr", "head"}, set(), False),' $'    "pr-ready": ({"pr", "head"}, set(), False),\n    "label-create": ({"name"}, set(), False),'
BRKF core-ops-undo-text fam_core_ops '[core-ops] the core says what an undo that cannot delete does' skills/batonrun/SKILL.md 'and exits non-zero' 'and exits zero'
BRKF core-ops-never-by-hand fam_core_ops "[core-ops] the core says the kit's ops are never hand-written" skills/batonrun/SKILL.md 'file-pr; never by hand (' 'file-pr ('
BRKF core-ops-handwritten-text fam_core_ops '[core-ops] the core names what needs a hand-written baton' skills/batonrun/SKILL.md 'Labels, tags, releases, a push: hand-written.' 'A push: hand-written.'

# go - and the hook's one-call shape
BRK stdin-not-read fam_go_stdin '[go-stdin] a baton on stdin: rc 0' $'        if path == "-":\n            path = stdin_script()\n' ''
BRK stdin-writable fam_go_stdin '[go-stdin] …read-only (0400)' 'getattr(os, "O_NOFOLLOW", 0), 0o400)' 'getattr(os, "O_NOFOLLOW", 0), 0o600)'
BRK stdin-overwrites fam_go_stdin '[go-stdin] …a second stored file' \
    'path = os.path.join(d, "%s-%s.sh" % (stamp, sha256(data)[:12]))' 'path = os.path.join(d, "%s-%s.sh" % ("0", sha256(data)[:12]))' \
    'os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o400)' 'os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)'
BRK stdin-cap-off fam_go_stdin '[go-stdin] more than 256 KiB on stdin: rc 64' '    if len(data) > STDIN_MAX:' '    if False:'
BRK stdin-empty-ok fam_go_stdin '[go-stdin] empty stdin: rc 64' '    if not data.strip():' '    if False:'
BRK stdin-tty-read fam_go_stdin '[go-stdin] stdin a terminal: rc 64' '    if stream is None or sys.stdin.isatty():' '    if stream is None:'
BRK stdin-reuse-ok fam_go_stdin '[go-stdin] --reuse -: rc 64' '    if path == "-" and reuse:' '    if False:'
BRK stdin-seal-unchecked fam_go_stdin "[go-stdin] a byte changed during go's rehearse (before sign): rc 3" '    if seal_of(binding, plan) != seal:' '    if False:'
BRK stdin-bytes-unbound fam_go_stdin "[go-stdin] a byte changed during sign's rehearse (before run): rc 3" \
    '{"v": 1, "script_sha256": script_sha, "args"' '{"v": 1, "script_sha256": "", "args"' \
    '(rec.get("binding"), rec.get("script_sha256"), rec.get("args"), rec.get("cwd"),' '(rec.get("binding"), s.sha, rec.get("args"), rec.get("cwd"),'
# BRKFM <label> <family> <needle> <file> <old> <new> [<old> <new>]... — BRKF with several replacements in one file
BRKFM() {
  local label=$1 fam=$2 needle=$3 file=$4 d; shift 4; d="$TMP/break-$label"; mk_plugin_copy "$d"
  while [ $# -ge 2 ]; do mutate "$d/$file" "$1" "$2" || return; shift 2; done
  expect_red "$label" "$fam" "$d" "$needle"
}
BRKF trap-stdin-shape-unknown fam_pipe_trap "[pipe-trap] no warning (the one-call form" scripts/vsdlc.py $'    if why == "":\n        return ""\n    if why:' $'    if why:'
BRKF trap-stdin-unquoted-ok fam_pipe_trap '[pipe-trap] warns (an unquoted delimiter)' scripts/vsdlc.py \
    '    m = QUOTED_DELIM.search(first)' '    m = QUOTED_DELIM.search(first) or re.search(r"<<[ \t]*()([A-Za-z_][A-Za-z0-9_]*)[ \t]*$", first)'
BRKF trap-stdin-tail-ok fam_pipe_trap '[pipe-trap] warns (a command after the closing line)' scripts/vsdlc.py \
    '    if any(x.strip(" \t") for x in lines[lines.index(delim) + 1:]):' '    if False:'
BRKF trap-stdin-last-delim fam_pipe_trap '[pipe-trap] warns (a body line equal to the delimiter ends it early)' scripts/vsdlc.py \
    '    if any(x.strip(" \t") for x in lines[lines.index(delim) + 1:]):' '    if any(x.strip(" \t") for x in lines[len(lines) - lines[::-1].index(delim):]):'
BRKFM trap-stdin-pipe-ok fam_pipe_trap '[pipe-trap] warns (a pipe on the first line)' scripts/vsdlc.py \
    '    if other or ops.count("<<") != 1:' '    if False:' \
    '    if [n for _w, n in words[:-1]] != [0] * (len(words) - 1) or words[-1][1] != 1:' '    if False:' \
    'QUOTED_DELIM = re.compile(r"<<[ \t]*(?:'"'"'([A-Za-z_][A-Za-z0-9_]*)'"'"'|\"([A-Za-z_][A-Za-z0-9_]*)\")[ \t]*$")' 'QUOTED_DELIM = re.compile(r"<<[ \t]*(?:'"'"'([A-Za-z_][A-Za-z0-9_]*)'"'"'|\"([A-Za-z_][A-Za-z0-9_]*)\")")'
BRKFM trap-stdin-chain-ok fam_pipe_trap '[pipe-trap] warns (a chain before it)' scripts/vsdlc.py \
    '    if other or ops.count("<<") != 1:' '    if False:' \
    '    if [n for _w, n in words[:-1]] != [0] * (len(words) - 1) or words[-1][1] != 1:' '    if False:' \
    '    if sub != "go" or prefix:' '    if False:'
BRKFM trap-stdin-dash-ok fam_pipe_trap '[pipe-trap] warns (<<-)' scripts/vsdlc.py \
    '    if "<<-" in first:' '    if False:' \
    'QUOTED_DELIM = re.compile(r"<<[ \t]*' 'QUOTED_DELIM = re.compile(r"<<-?[ \t]*'
BRKF trap-stdin-unclosed-ok fam_pipe_trap '[pipe-trap] warns (never closed)' scripts/vsdlc.py \
    $'    if delim not in lines:\n        return "no line `%s` closes the heredoc" % delim, None\n' $'    if delim not in lines:\n        return "", first\n'
BRKF trap-stdin-rules-on-body fam_pipe_trap "[pipe-trap] the one-call form: the body's gh pr merge" scripts/vsdlc.py \
    '    rcmd = first if why == "" else cmd' '    rcmd = cmd'
BRKF trap-stdin-rules-first-always fam_pipe_trap '[pipe-trap] control: the same body with a line after' scripts/vsdlc.py \
    '    rcmd = first if why == "" else cmd' '    rcmd = cmd.split("\n", 1)[0] if why is not None else cmd'
BRKF trap-stdin-cr-ok fam_pipe_trap '[pipe-trap] warns (a CR inside the body' scripts/vsdlc.py '    if "\r" in cmd:' '    if False:'
BRKF trap-stdin-unicode-blank fam_pipe_trap '[pipe-trap] warns (a control character after the closing line' scripts/vsdlc.py \
    '    if any(x.strip(" \t") for x in lines[lines.index(delim) + 1:]):' '    if any(x.strip() for x in lines[lines.index(delim) + 1:]):'
BRK stdin-prune-young fam_go_stdin '[go-stdin] …the prune keeps a stored script younger than 7 days' \
    '            if i < hard or time.time() - os.lstat(os.path.join(d, n)).st_mtime > STDIN_KEEP_DAYS * 86400:' '            if True:'
BRK stdin-hard-cap-off fam_go_stdin '[go-stdin] …a burst of young ones is still cut to the newest 1000' \
    '            if i < hard or time.time()' '            if time.time()'
# the guidance on `go -` is pinned against the measured verdicts (tests/fixtures/go-dash-verdict.txt)
BRKF go-dash-core-recommends fam_go_dash_guidance '[go-dash] the core and the rule' skills/batonrun/SKILL.md \
    'Never the baton in a heredoc on `go -`: Claude Code blocks it (`limits.md`).' "One call: \`<launcher> go - <args> <<'BATON_EOF'\`, the baton, a last line \`BATON_EOF\`."
BRKF go-dash-rule-recommends fam_go_dash_guidance '[go-dash] the core and the rule' rules/batonrun.instructions.md \
    'never in a heredoc on `go -` (Claude Code blocks it)' "or in a heredoc on \`go -\`"
BRKF go-dash-act-recommends fam_go_dash_guidance '[go-dash] every other mention' skills/batonrun/act.md \
    $'exists, but it is not how a session sends a baton: the only way to feed it is a heredoc on\nthe command, and Claude Code blocks a heredoc that holds the skeleton. Measured, not assumed: `limits.md`. Do not rewrite the skeleton\nto get past that check.' \
    $'is one call a session sends as a heredoc on the command.'
BRKF go-dash-act-same-paragraph fam_go_dash_guidance '[go-dash] every other mention' skills/batonrun/act.md \
    'Do not rewrite the skeleton' $'A one-call alternative is `go - <args>` with the script after it. Do not rewrite the skeleton'
BRKF go-dash-hook-teaches fam_go_dash_guidance "[go-dash] the hook's warning" scripts/vsdlc.py \
    'and Claude Code blocks a heredoc that holds a baton skeleton in any shape. Write' "and \`<launcher> go - <args> <<'BATON_EOF'\` is the one bare call. Write"
BRKF go-dash-help-teaches fam_go_dash_guidance "[go-dash] the hook's warning" scripts/baton.py \
    'not for a baton: Claude Code blocks a' 'for a baton too: Claude Code takes a'

echo "== [text] the decisions the skill, the rule and the template carry =="
# The one place this suite reads prose: one key phrase per decision, whitespace folded, so a lesson cannot drop out unnoticed.
flat() { tr -s ' \n' '  ' < "$1"; }
carries() { has "$(flat "$PLUGIN/$1")" "$2" "[text] $1: $3"; }   # carries <file under the plugin> <exact text> <label>
SK=skills/batonrun/SKILL.md RU=rules/batonrun.instructions.md TP=templates/baton-script.sh
AC=skills/batonrun/act.md MO=skills/batonrun/modes.md KI=skills/batonrun/kinds.md
carries "$AC" 'through stdin into `bash -s`' "A1 a remote program goes through stdin"
carries "$TP" 'through stdin into `bash -s`' "A1 a remote program goes through stdin"
carries "$AC" 'Print a remote read first, decide later' "A1 a remote read is printed before it decides"
carries "$RU" 'Run the launcher bare' "A2 the launcher runs bare"
carries "$SK" 'no pipe, `| tail` or `| grep` after `sign`, `run` or `go`' "A2 no pipe after sign, run or go"
carries "$TP" 'Each one bare, as its own call' "A2 the launcher runs bare"
carries "$RU" 'never unprompted, as a test, after a refusal or a rejected dialog, or another way' "A3 no dialog is not a go: a session never signs as the owner"
carries "$MO" 'No dialog shown, or a rejected one, means not confirmed' "A3 no dialog is not confirmed"
carries "$MO" 'at most seven short lines' "A3 the decision card"
carries "$MO" "which the dialog shows, is the card's first line" "A3 the command's description heads the card"
for f in "$SK" "$AC" "$MO" "$KI"; do hasnt "$(flat "$PLUGIN/$f")" 'small-context subagent' "[text] $f: C5 P3 (a baton's go in a subagent) is gone"; done
carries "$AC" 'ONE worker subagent (model `agents.worker_model`), one Agent call' "PR D a delegated task goes to one worker"
carries "$AC" 'In place by default, any number. Delegate 3 or more batons only when the main context is over ~400k tokens' "PR E in place by default, delegation only for a large main context"
carries "$AC" 'a worker never delegates' "PR E a worker does not delegate again"
carries "$SK" 'A hand-written baton needs only this file' "PR E the core is enough for a plain baton"
carries "$RU" "hook warns on EVERY launcher \`sign\`, \`run\` or \`go\` sent with a pipe, chain or redirect" "PR E the launcher warning comes every time"
carries "$AC" '`run`, like `go`, prints one line when it holds' "PR E run prints one line"
carries "$AC" 'needs no tool call: end the turn' "PR D a late hand-back after the wait needs no tool call"
carries "$SK" 'no dialog, or a rejected one, is not a yes' "A3 no dialog is not a yes (the core)"
carries "$SK" 'Write the baton (from the skeleton) to a fresh path and `go <that path> <args>` in the same response' "C2 write and go in one response"
carries "$SK" 'Never the baton in a heredoc on `go -`: Claude Code blocks it' "C2 a baton is not sent on go -"
carries "$AC" 'Run the `--reuse` command only after reading that sha256 and Purpose' "C2 --reuse only after reading what go printed"
carries "$SK" 'Independent batons of one task go in the same response' "C7 independent batons in one response"
carries "$MO" 'it reports the one line `go: ok' "C1 the auto-mode report is the one line"
carries "$KI" 'go kind:ci-rerun-failed <owner/name> <run id>' "C3 the callable kinds"
carries skills/batonrun/kits.md 'It never reads `CLAUDE_CONFIG_DIR` or `HOME`, which a session can set' "S8 a dependent plugin's kit: the registry beside the running copy"
carries skills/batonrun/kits.md "a name that sdlc and a dependent plugin both ship, or that two dependent plugins ship" "S8 a kit name is unique"
carries "$RU" 'and `go` it in the same response' "C2 write and go in one response"
n=$(awk '/^### What `check` refuses/{on=1; next} on && /^#/{exit} on && NF{c++} END{print c+0}' "$PLUGIN/$SK")
[ "$n" -ge 5 ] && [ "$n" -le 15 ] && ok "[text] $SK: C4 'What check refuses' is at most 15 lines ($n)" \
  || bad "[text] $SK: C4 'What check refuses' is at most 15 lines ($n)"
carries "$RU" 'A Kubernetes write is a baton the owner signs and the session runs' "A3 cluster writes"
carries "$AC" 'Undo compares every target with its before-state' "A4 undo compares every target"
carries "$RU" 'undo compares every target with its before-state' "A4 undo compares every target"
carries "$RU" 'never a value the act moves' "A4 plan lines"
carries "$AC" 'never a value the act itself moves' "A4 plan lines"
carries "$TP" 'never a value the act moves' "A4 plan lines"
carries "$AC" 'A write waits for its own slow signal' "A4 the slow signal"
carries "$AC" 'the run writes a record' "A4 the run record"
printf 'Run the\n   launcher bare: one\n' > "$TMP/wrapped.md"
has "$(flat "$TMP/wrapped.md")" 'Run the launcher bare' "[text] control: a phrase wrapped over two lines is still read"
sed 's/Run the launcher bare/Run the launcher/' "$PLUGIN/$RU" > "$TMP/no-bare.md"
hasnt "$(flat "$TMP/no-bare.md")" 'Run the launcher bare' "[text] control: a rule copy without the A2 phrase does not carry it"

echo "== nothing written outside the scratch tree =="
eq "$(tree_hash "$SRC_ROOT")" "$H0" "the repository tree is unchanged by the suite"
[ "$(tree_hash "$SRC_ROOT")" = "$H0" ] || { echo "  the files that changed (< before, > after):"; tree_files "$SRC_ROOT" | diff "$TMP/tree-before.lst" - | grep '^[<>]' | head -20; }
[ ! -e "$HOME/.local/state/vibemaestro" ] && ok "the scratch HOME holds no baton state (every family set XDG_STATE_HOME)" || bad "the scratch HOME holds no baton state (every family set XDG_STATE_HOME)"

echo; summary
