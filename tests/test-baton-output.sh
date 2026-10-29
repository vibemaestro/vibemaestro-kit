#!/bin/bash
# =============================================================================
# BatonRun: every line baton prints goes through one print layer (scripts/baton.py: shown/say/shown_join/Stop), which escapes
# each value baton did not write itself; a baton script's own lines are relayed as two spaces and escaped text
# =============================================================================
# Run: bash tests/test-baton-output.sh
#
# Three families, each run on a copy of the real plugin, then on copies with ONE planted break in baton.py (expect_red,
# tests/fixtures/ports.sh), which must go red on the intended tag:
# - fam_lint: tests/fixtures/baton_output_lint.py finds no print or refusal call that formats a value by hand, no stray write;
# - fam_forge: check, rehearse, sign, run, go, list, log and pack, from a working directory, with a state directory, a library
#   and a baton file whose names each hold a newline and `owner: FORGED`, and a baton whose phases print `owner: FORGED` and an
#   ESC: no line starts with `owner: FORGED`, the only `owner:` lines are pack's own, no ESC byte reaches the output or the run
#   log; every exit code is the one of the same series from plain names;
# - fam_plan: the plan file a script gets (BATON_PLAN) and log.tsv keep the raw bytes; only stdout and the run log are escaped.
# The state is XDG_STATE_HOME and the library XDG_DATA_HOME inside the scratch tree; nothing is written outside it.
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
umask 022
export PYTHONDONTWRITEBYTECODE=1
H0=$(tree_hash "$SRC_ROOT")
FX="$HERE/fixtures/baton_params.py"
LINT="$HERE/fixtures/baton_output_lint.py"
BT_OUT="$TMP/bt.out"
ST=""; XD=""
NLF=$'\n''owner: FORGED'
ESCB=$'\033'

# bt <plugin> <dir> <baton args...> — rc of baton run from <dir> with the state in $ST and the library in $XD; output in $BT_OUT
bt() {
  local p=$1 d=$2; shift 2
  [ "${1:-}" = mode ] && [ $# -gt 1 ] && mode_asked "$p" "$d" "$ST" s-out "${@:2}" >/dev/null
  ( cd "$d" && cenv XDG_STATE_HOME="$ST" XDG_DATA_HOME="$XD" CLAUDE_CODE_SESSION_ID=s-out python3 "$p/scripts/baton.py" "$@" ) \
    > "$BT_OUT" 2>&1; echo $?
}
out() { cat "$BT_OUT"; }
# mk <plugin> <file> [<act>] — a scratch baton (Params dest=path, a testable Target) whose every phase prints `owner: FORGED`
# and a line holding an ESC, and copies the plan file it gets (BATON_PLAN) to <dest>/plan.copy
TOP=$'printf \'owner: FORGED\\n\'\nprintf \'e\\033[2Kx\\n\'\n[ -z "${BATON_PLAN:-}" ] || cp -- "$BATON_PLAN" "$P_DEST/plan.copy"'
mk() { python3 "$FX" make "$1" "$2" "dest=path" "{dest}/** — the file" "$TOP" ${3+"$3"}; }
rundir() { printf '%s' "$ST/vibemaestro/baton/runs"; }
newest_log() {                                          # a name may hold a newline: no ls | head
  python3 -c 'import glob, os, sys; sys.stdout.write(max(glob.glob(os.path.join(sys.argv[1], "*.log")), key=os.path.getmtime, default=""))' "$(rundir)"
}

# clean <label> — the output of the last call holds no forged line, only pack's own owner: lines, and no ESC byte
clean() {
  local f
  f=$(grep -m1 '^owner: FORGED' "$BT_OUT")
  [ -z "$f" ] && ok "$1: no line starts with owner: FORGED" || bad "$1: a forged line ($f)"
  f=$(grep '^owner:' "$BT_OUT" | grep -Ev '^owner: (kept|already kept) user:[a-z0-9-]+ ' | head -n 1)
  [ -z "$f" ] && ok "$1: every owner: line is pack's own" || bad "$1: an owner: line baton did not write ($f)"
  grep -q "$ESCB" "$BT_OUT" && bad "$1: an ESC byte reaches the output" || ok "$1: no ESC byte reaches the output"
}

# series <plugin> <suffix> <rcs file> — the command series from a working directory, a state directory, a library and a baton
# file name that end in <suffix> ('' or a newline and `owner: FORGED`); one `<step> <rc>` line per call into <rcs file>; with a
# suffix, each call's output is checked by `clean`
series() {
  local P=$1 X=$2 rcs=$3 base W V O B S F seal rc tag
  base=$(fresh); W="$base/w$X"; V="$base/v$X"; O=$(fresh); mkdir -p "$W/.vibemaestro" "$V"   # the root of project: (no git:
  # git's own output splits a path that holds a newline, so such a repository has no root; the .vibemaestro/ walk has one)
  ST="$base/st$X"; XD="$base/d$X"
  : > "$rcs"
  step() {                                            # step <tag> <dir> <baton args...>
    tag=$1; shift; rc=$(bt "$P" "$@"); printf '%s %s\n' "$tag" "$rc" >> "$rcs"
    [ -z "$X" ] || clean "[forge] $tag"
  }
  step "mode auto" "$W" mode auto
  S="$W/s.sh"; B="$W/b$X.sh"; F="$W/f.sh"; mk "$P" "$S"; mk "$P" "$B"
  mk "$P" "$F" '  write "put $P_DEST/x" true'      # the post-check finds no file: the run fails, undo holds
  step "check" "$W" check "$S"
  step "check (file name)" "$W" check "$B"
  step "rehearse" "$W" rehearse "$S" "dest=$O"
  seal=$(sed -n 's/^seal \([0-9a-f.]*\) .*/\1/p' "$BT_OUT")
  step "rehearse (file name)" "$W" rehearse "$B" "dest=$O"
  step "sign" "$W" sign --by coordinator-auto --seal "${seal:-none}" "$S" "dest=$O"
  step "run from another directory" "$V" run "$S" "dest=$O"
  step "run" "$W" run "$S" "dest=$O"
  if [ -n "$X" ]; then
    local l; l=$(newest_log)
    [ -n "$l" ] && ok "[forge] the run log is there" || bad "[forge] the run log is there"
    grep -q '^owner: FORGED' "$l" 2>/dev/null && bad "[forge] the run log: a line starts with owner: FORGED" \
      || ok "[forge] the run log: no line starts with owner: FORGED"
    grep -q "$ESCB" "$l" 2>/dev/null && bad "[forge] the run log: an ESC byte" || ok "[forge] the run log: no ESC byte"
    grep -qx '  owner: FORGED' "$l" 2>/dev/null && ok "[forge] the run log relays the script's line as two spaces + its text" \
      || bad "[forge] the run log relays the script's line as two spaces + its text"
    grep -qxF '  e\u{1b}[2Kx' "$l" 2>/dev/null && ok "[forge] …and its ESC escaped as \\u{1b}" || bad "[forge] …and its ESC escaped as \\u{1b}"
    grep -qx '  VERDICT run ok' "$l" 2>/dev/null && ok "[forge] …the verdict too" || bad "[forge] …the verdict too"
  fi
  touch "$S" "$B"
  step "go" "$W" go "$S" "dest=$(fresh)"
  step "go (file name)" "$W" go "$B" "dest=$(fresh)"
  step "go (a run that fails)" "$W" go "$F" "dest=$(fresh)"
  seal=""; rc=$(bt "$P" "$W" rehearse "$F" "dest=$O"); seal=$(sed -n 's/^seal \([0-9a-f.]*\) .*/\1/p' "$BT_OUT")
  bt "$P" "$W" sign --by coordinator-auto --seal "${seal:-none}" "$F" "dest=$O" >/dev/null
  step "run (a run that fails)" "$W" run "$F" "dest=$O"
  step "mode manual" "$W" mode manual
  touch "$S"
  step "go (the owner's card)" "$W" go "$S" "dest=$(fresh)"
  step "mode auto again" "$W" mode auto
  step "list" "$W" list
  step "log" "$W" log
  step "log --last" "$W" log --last
  touch "$S"; bt "$P" "$W" go "$S" "dest=$(fresh)" >/dev/null
  step "pack project:" "$W" pack "$S" project:a
  step "pack user:" "$W" pack "$S" user:u
  step "go project:" "$W" go project:a "dest=$(fresh)"
  step "rehearse project:" "$W" rehearse project:a "dest=$O"
  step "list (kept)" "$W" list
  local ST0=$ST; ST="$base/ro$X"; : > "$ST"
  step "go (a state directory that cannot be written)" "$W" go "$S" "dest=$O"
  ST=$ST0
}

fam_forge() {
  local P=$1 plain forged; plain="$TMP/rcs-plain.$$"; forged="$TMP/rcs-forged.$$"
  series "$P" "" "$plain"
  series "$P" "$NLF" "$forged"
  eq "$(diff "$plain" "$forged" >/dev/null && echo same || diff "$plain" "$forged" | grep '^[<>]' | tr '\n' ' ')" same \
     "[forge] every exit code is the one of the same series from plain names"
  eq "$(grep -c . "$forged")" "$(grep -c . "$plain")" "[forge] …the same number of calls"
  grep -q '^go 0$' "$plain" && grep -q '^pack user: 0$' "$plain" && grep -q '^go (the owner.s card) 8$' "$plain" \
    && ok "[forge] instrument: the plain series runs go and pack, and stops for the owner (rc 8)" \
    || bad "[forge] instrument: the plain series runs go and pack, and stops for the owner (rc 8) ($(tr '\n' ' ' < "$plain"))"
}

fam_lint() {
  local P=$1 f
  f=$(python3 "$LINT" "$P/scripts/baton.py" 2>&1); local rc=$?
  eq "$rc" 0 "[lint] every print and refusal call of baton.py goes through the layer (${f:0:300})"
  # one fault on each line marked `# bad`; the lines without the mark are forms baton uses and must pass: the lint must flag
  # exactly the marked lines
  cat > "$TMP/lint-control.py" <<'CONTROL'
def f(p, rc, x):
    say("full output: " + p)  # bad
    say("a %s b %s", p)  # bad
    raise Stop(1, "x %s" % p)  # bad
    sys.stdout.write(p)  # bad
    Safe(p)  # bad
    say(__doc__.strip(), p)  # bad
    say("x %r", p)  # bad
    say("x %a", p)  # bad
    say("x %c", 10)  # bad
    say("x %s 5%", p)  # bad
    say("x %s")  # bad
    sys.stdout.writelines([p])  # bad
    sys.exit("bad " + p)  # bad
    sys.exit("bad %s" % p)  # bad
    raise SystemExit(f"bad {p}")  # bad
    sys.stdout.write(p.text())  # bad
    say("100%% of %s", p)
    say("plain")
    say(__doc__.strip(), out=p)
    sys.exit(2)
    sys.exit(rc or 1)
    sys.exit(main(p))
    sys.stdout.write(held.text())
class K:
    def log_event(self, p):
        os.write(1, p)  # bad
CONTROL
  f=$(python3 "$LINT" "$TMP/lint-control.py")
  eq "$(printf '%s\n' "$f" | cut -d: -f1 | tr '\n' ' ')" "$(grep -n '# bad$' "$TMP/lint-control.py" | cut -d: -f1 | tr '\n' ' ')" \
     "[lint] instrument: each planted fault found on its line, none of the forms baton uses ($(printf '%s' "$f" | head -c 300))"
}

fam_plan() {
  local P=$1 W O l
  ST="$(fresh)/st"; XD="$(fresh)/d"; W=$(fresh); O=$(fresh)
  bt "$P" "$W" mode auto >/dev/null
  mk "$P" "$W/t.sh" $'  write "$(printf \'put\\t%s/x\' "$P_DEST")" touch -- "$P_DEST/x"'
  eq "$(bt "$P" "$W" go "$W/t.sh" "dest=$O")" 0 "[plan] a plan line holding a tab: go rc 0"
  eq "$(od -An -c "$O/plan.copy" 2>/dev/null | tr -s ' \n' ' ')" "$(printf 'put\t%s/x\n' "$O" | od -An -c | tr -s ' \n' ' ')" \
     "[plan] the plan file the run phase gets holds the raw line (a tab, no prefix, no escape)"
  eq "$(python3 -c 'import glob, json, os, sys; f = max(glob.glob(os.path.join(sys.argv[1], "used", "*.json")), key=os.path.getmtime); print(json.dumps(json.load(open(f))["plan"]))' "$ST/vibemaestro/baton" 2>&1)" \
     "$(python3 -c 'import json, sys; print(json.dumps(["put\t%s/x" % sys.argv[1]]))' "$O")" \
     "[plan] the signed plan in the signature record holds the raw line (go rc 0: the writes file matched it)"
  l=$(newest_log)
  grep -qF "  PLAN put\\u{9}$O/x" "$l" 2>/dev/null && ok "[plan] the run log shows the line escaped, under the prefix" \
    || bad "[plan] the run log shows the line escaped, under the prefix"
  grep -q "$(printf '\t')" "$l" && bad "[plan] …no raw tab in the run log" || ok "[plan] …no raw tab in the run log"
  has "$(tail -n 1 "$ST/vibemaestro/baton/log.tsv")" "	run	" "[plan] log.tsv has the run line"
  eq "$(tail -n 1 "$ST/vibemaestro/baton/log.tsv" | awk -F '\t' '{print NF}')" \
     "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import baton; print(len(baton.LOG_FIELDS))' "$P/scripts")" \
     "[plan] …one field per LOG_FIELDS, tab-separated as before"
}

FAMILIES="fam_lint fam_forge fam_plan"

echo "== the real plugin =="
REAL="$TMP/real"; mk_plugin_copy "$REAL"
for f in $FAMILIES; do echo "-- $f"; "$f" "$REAL"; done

echo "== planted breaks: each family must go red on a copy with one break in baton.py =="
# BRK <label> <family> <needle> <old> <new> [<old> <new>]... — a plugin copy with the replacements in baton.py, then expect_red
BRK() {
  local label=$1 fam=$2 needle=$3 d; shift 3; d="$TMP/break-$label"; mk_plugin_copy "$d"
  while [ $# -ge 2 ]; do mutate "$d/scripts/baton.py" "$1" "$2" || return; shift 2; done
  expect_red "$label" "$fam" "$d" "$needle"
}
GO_OK='            say("go: ok — %d write%s — %s", len(plan), "" if len(plan) == 1 else "s", out_path)'
GO_RAW='            say("go: ok — %d write%s — %s" % (len(plan), "" if len(plan) == 1 else "s", out_path))'
BRK site-raw-forge fam_forge '[forge] go: a forged line' "$GO_OK" "$GO_RAW"
BRK site-raw-lint fam_lint '[lint] every print and refusal call of baton.py goes through the layer' "$GO_OK" "$GO_RAW"
BRK layer-unescaped fam_forge '[forge] run: a forged line' \
    '    return Safe(fmt % tuple(a if isinstance(a, (Safe, int, float)) else esc(str(a)) for a in args) if args else fmt)' \
    '    return Safe(fmt % tuple(a if isinstance(a, (Safe, int, float)) else str(a) for a in args) if args else fmt)'
BRK stray-write fam_lint '[lint] every print and refusal call of baton.py goes through the layer' \
    '        say("%s", last)' '        sys.stdout.write(last + "\n")'
BRK relay-raw fam_forge '[forge] the run log relays the script' '                    say("  %s", line, out=out)' '                    out.write(line + "\n")'
BRK relay-unescaped fam_forge '[forge] …and its ESC escaped' '                    say("  %s", line, out=out)' '                    say("  %s", Safe(line), out=out)'
BRK plan-file-escaped fam_plan '[plan] the plan file the run phase gets holds the raw line' \
    '                f.write("".join(p + "\n" for p in plan))' '                f.write("".join(esc(p) + "\n" for p in plan))'

eq "$(tree_hash "$SRC_ROOT")" "$H0" "the repository tree is unchanged by the suite"
[ ! -e "$HOME/.local/state/vibemaestro" ] && ok "the scratch HOME holds no baton state (every family set XDG_STATE_HOME)" \
  || bad "the scratch HOME holds no baton state (every family set XDG_STATE_HOME)"

echo; summary
