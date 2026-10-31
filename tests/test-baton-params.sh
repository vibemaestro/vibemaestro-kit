#!/bin/bash
# =============================================================================
# BatonRun: a kept flow called by name with checked values — Params, the project: and user: places, the pin, the Targets
# test, the parameter checks of check, baton list, the owner's signature on a kept baton, and a project baton that runs without a
# pin because its bytes are origin's default branch and its remote is on the owner's list (scripts/baton.py)
# =============================================================================
# Run: bash tests/test-baton-params.sh
#
# Each area is a FAMILY `fam_<x> <plugin dir>`: allowed forms green, every refused form red with its own tag. The suite runs
# every family on a copy of the real plugin, then families again on copies with ONE planted break in baton.py (expect_red,
# tests/fixtures/ports.sh), which must go red on the intended tag. The long tables (types, grammar, the shell reader, the owner's
# command shape) live in tests/fixtures/baton_params.py and run in one process against the copy's own baton.py.
# The state is XDG_STATE_HOME and the library XDG_DATA_HOME inside the scratch tree, HOME is the scratch home; keep records are
# written by the suite (baton pack writes them later); nothing is written outside the scratch tree, which the last section checks.
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
umask 022                                               # a project root writable by its group is refused: the suite's are not
export PYTHONDONTWRITEBYTECODE=1
H0=$(tree_hash "$SRC_ROOT")
FX="$HERE/fixtures/baton_params.py"
BT_OUT="$TMP/bt.out"
ST=""; XD=""; BT_ENV=(); OWNER_SID=s-owner

# bt <plugin> <dir> <baton args...> — rc of baton run from <dir> with the state in $ST and the library in $XD (plus BT_ENV); the
# output is in $BT_OUT. A `sign --by owner` first goes through the plugin's guard hook, as when the owner clicks the dialog.
bt() {
  local p=$1 d=$2; shift 2
  [ "${1:-} ${2:-} ${3:-}" = "sign --by owner" ] && owner_asked "$p" "$d" "$ST" "$OWNER_SID" "${@:2}" >/dev/null
  [ "${1:-}" = mode ] && [ $# -gt 1 ] && mode_asked "$p" "$d" "$ST" "$OWNER_SID" "${@:2}" >/dev/null
  ( cd "$d" && cenv XDG_STATE_HOME="$ST" XDG_DATA_HOME="$XD" CLAUDE_CODE_SESSION_ID="$OWNER_SID" ${BT_ENV[@]+"${BT_ENV[@]}"} \
      python3 "$p/scripts/baton.py" "$@" ) > "$BT_OUT" 2>&1; echo $?
}
out() { cat "$BT_OUT"; }
# seal_for <plugin> <dir> <script> [args...] — the seal rehearse prints
seal_for() {
  ( cd "$2" && cenv XDG_STATE_HOME="$ST" XDG_DATA_HOME="$XD" ${BT_ENV[@]+"${BT_ENV[@]}"} python3 "$1/scripts/baton.py" rehearse "${@:3}" ) 2>/dev/null \
    | sed -n 's/^seal \([^ ]*\) .*/\1/p'
}
sg() { local p=$1 d=$2 by=$3 seal; shift 3; seal=$(seal_for "$p" "$d" "$@"); bt "$p" "$d" sign --by "$by" --seal "${seal:-none}" "$@"; }
# setup <plugin> — a fresh state (mode auto), library and working directory W holding f.txt; prints nothing
setup() { ST="$(fresh)/state"; XD="$(fresh)/data"; W=$(fresh); BT_ENV=(); echo hello > "$W/f.txt"; bt "$1" "$W" mode auto >/dev/null; }
bdir() { printf '%s' "$ST/vibemaestro/baton"; }
nsig() { find "$(bdir)/signatures" -name '*.json' 2>/dev/null | wc -l | tr -d ' '; }
# mkb <plugin> <out> <params> <targets> [<top lines> [<act body>]] — a test baton (fixtures/baton_params.py)
mkb() { python3 "$FX" make "$@"; }
shaf() { python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"; }
# pkey <dir> [walk] — the place key of the project root of <dir>: of git's common directory, or (walk) of the root itself
pkey() { ( cd "$1" && python3 -c 'import hashlib, os, subprocess, sys
r = subprocess.run(["git", "rev-parse", "--git-common-dir"], capture_output=True, text=True) if len(sys.argv) < 2 else None
p = os.path.realpath(r.stdout.strip()) if r and r.returncode == 0 else os.path.realpath(".")
print("project-" + hashlib.sha256(p.encode()).hexdigest()[:16])' ${2:+walk} ); }
# rec <key> <name> <seq> keep|retire <sha256> — a keep or retire record, as baton pack writes it
rec() {
  local d; d="$(bdir)/kept/$1/$2"; mkdir -p "$d"
  if [ "$4" = keep ]; then
    printf '{"sha256": "%s", "place": "x", "name": "%s", "kept_by": {"session": "abcdef0123456789", "seat": "seat-1", "intent": "2026-10-24-x"}, "kept_at": "2026-10-24T08:00:00Z"}\n' "$5" "$2"
  else
    printf '{"retired": "%s", "kept_by": "local", "kept_at": "2026-10-24T09:00:00Z"}\n' "$5"
  fi > "$d/$3.json"
}
LABEL='not reviewed, kept by abcdef01 seat-1 2026-10-24-x 2026-10-24'
# repo <dir> — a git repository with an empty .vibemaestro/batons
repo() { git_ init -q -b main "$1"; mkdir -p "$1/.vibemaestro/batons"; }
# pyfam <plugin> <table> <tag> — one ok/bad per case of a fixture table, tagged "[<tag>] <case label>"
pyfam() {
  local line r label why n=0
  while IFS= read -r line; do
    r=${line%%$'\t'*}; label=${line#*$'\t'}; why=${label#*$'\t'}; label=${label%%$'\t'*}; n=$((n+1))
    [ "$r" = PASS ] && ok "[$3] $label" || bad "[$3] $label ($why)"
  done < <(cenv XDG_STATE_HOME="$ST" python3 "$FX" table "$1" "$2" 2>&1)
  [ "$n" -gt 0 ] || bad "[$3] the table printed no case"
}
D() { printf '%s' "dest=$1"; }                          # the dest=<path> word
modeof() { python3 -c 'import os, stat, sys; print("%o" % stat.S_IMODE(os.stat(sys.argv[1]).st_mode))' "$1" 2>/dev/null; }
within() {  # within <seconds> <command...> — the command's rc, or "timeout" when it runs longer
  python3 -c 'import subprocess, sys
try:
    print(subprocess.run(sys.argv[2:], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=float(sys.argv[1])).returncode)
except subprocess.TimeoutExpired:
    print("timeout")' "$@"
}
age() { python3 -c 'import os, sys, time; t = time.time() - float(sys.argv[2]); os.utime(sys.argv[1], (t, t))' "$1" "$2"; }

# ── the declaration: the Params grammar, Usage and what a kept baton must declare ─────────────────────────────────────────────
fam_grammar() {
  local P=$1 R; setup "$P"
  pyfam "$P" grammar grammar
  R=$(fresh); repo "$R"
  mkb "$P" "$R/.vibemaestro/batons/fixed.sh" "none" "/x — the file" "" '  write "put /x" true'
  eq "$(bt "$P" "$R" check project:fixed)" 1 "[grammar] a project: baton with Params: none: check rc 1"
  has "$(out)" "declares Params with at least one key" "[grammar] …it declares Params with at least one key"
  mkb "$P" "$R/.vibemaestro/batons/use.sh" "dest=path n=name" "{dest}/** — the file"
  sed -i 's/^# Expect:/# Usage: --x <y>\n# Expect:/' "$R/.vibemaestro/batons/use.sh"
  eq "$(bt "$P" "$R" check project:use)" 1 "[grammar] Usage in a project: baton: check rc 1"
  has "$(out)" "Usage documents a kit's or kind's flags" "[grammar] …named"
  cp "$R/.vibemaestro/batons/use.sh" "$W/both.sh"
  eq "$(bt "$P" "$W" check both.sh)" 1 "[grammar] Params and Usage together: check rc 1"
  has "$(out)" "Params and Usage together" "[grammar] …named"
  mkb "$P" "$W/none.sh" "none" "/x — the file" "" '  write "put /x" true'
  eq "$(bt "$P" "$W" check none.sh)" 0 "[grammar] a scratch baton with Params: none passes check"
  cp -r "$P" "$W/plug"; sed -i '/^# Usage:/d' "$W/plug/batons/merge-pr.sh"
  eq "$(bt "$W/plug" "$W" check kit:merge-pr)" 1 "[grammar] a kit with neither Usage nor Params: check rc 1"
  has "$(out)" "declares Usage (its flags) or Params" "[grammar] …named"
  local k; for k in merge-pr gh-write branch-push workflow-dispatch coordinator-bootstrap; do
    eq "$(bt "$P" "$W" check "kit:$k")" 0 "[grammar] kit:$k declares Usage and passes check"
  done
  eq "$(bt "$P" "$W" check kit:branch-delete)/$(grep -c '^# Params: ' "$P/batons/branch-delete.sh")" "0/1" "[grammar] kit:branch-delete declares Params and passes check"
  for k in install-file settings-merge ci-rerun-failed; do eq "$(bt "$P" "$W" check "kind:$k")" 0 "[grammar] kind:$k declares Usage and passes check"; done
}

# ── the values: types, the call form, totals ─────────────────────────────────────────────────────────────────────────────────
fam_values() {
  local P=$1 big; setup "$P"
  pyfam "$P" values types
  mkb "$P" "$W/v.sh" "src=file dest=path" "{dest}/** — the file" "" '  write "put $P_DEST/x" cp -- "$P_SRC" "$P_DEST/x"'
  mkdir -p "$W/d"; ln -s "$W/f.txt" "$W/link.txt"
  eq "$(bt "$P" "$W" go v.sh "src=$W/nope" "$(D "$W/x")")" 64 "[types] a file value that does not exist: rc 64"
  eq "$(bt "$P" "$W" go v.sh "src=$W/d" "$(D "$W/x")")" 64 "[types] a file value that is a directory: rc 64"
  eq "$(bt "$P" "$W" go v.sh "src=$W/link.txt" "$(D "$W/x")")" 64 "[types] a file value that is a link: rc 64"
  has "$(out)" "a link is never followed" "[types] …named"
  python3 -c 'import sys; open(sys.argv[1], "wb").write(b"x" * (1024 * 1024 + 1))' "$W/big.bin"
  eq "$(bt "$P" "$W" go v.sh "src=$W/big.bin" "$(D "$W/x")")" 64 "[types] a file value over 1 MiB: rc 64"
  big="$W/$(printf 'a%.0s' $(seq 1 191))"; : > "$big" 2>/dev/null || big=""
  [ -n "$big" ] && { eq "$(bt "$P" "$W" go v.sh "src=$big" "$(D "$W/x")")" 64 "[types] a file name over 190 bytes: rc 64"; }
  eq "$(bt "$P" "$W" go v.sh "src=$W/f.txt" "$(D "$ST/vibemaestro/baton/mode")")" 64 "[types] a path into the state directory: rc 64"
  has "$(out)" "names the baton state directory" "[types] …named"
  # a scratchpad-shaped path: a segment in the middle starts with - (Claude Code's scratchpad), the last segment never does
  local SP="$W/tmp/claude-1000/-home-u-proj/sess/scratchpad"; mkdir -p "$SP/out" "$W/lnk"; echo body > "$SP/body.txt"
  mkb "$P" "$W/sp.sh" "dest=path body=input" "{dest}/** — the file" "" '  write "put $P_DEST/x" cp -- "$P_BODY" "$P_DEST/x"'
  eq "$(bt "$P" "$W" go sp.sh "$(D "$SP/out")" "body=$SP/body.txt")" 0 "[types] path and input under a -home-… segment: rc 0"
  has "$(out)" "ok" "[types] …ran"
  [ "$(cat "$SP/out/x" 2>/dev/null)" = body ] && ok "[types] …the input reached the script" || bad "[types] …the input reached the script"
  mkb "$P" "$W/su.sh" "dest=under:$SP body=input" "{dest}/** — the file" "" '  write "put $P_DEST/x" cp -- "$P_BODY" "$P_DEST/x"'
  rm -f "$SP/out/x"
  eq "$(bt "$P" "$W" go su.sh "$(D "$SP/out")" "body=$SP/body.txt")" 0 "[types] under: a base with a -home-… segment: rc 0"
  eq "$(bt "$P" "$W" go su.sh "$(D "$W/out")" "body=$SP/body.txt")" 64 "[types] …a value outside that base: rc 64"
  has "$(out)" "is neither" "[types] …named"
  eq "$(bt "$P" "$W" go sp.sh "$(D "$SP/-out")" "body=$SP/body.txt")" 64 "[types] a last segment starting with -: rc 64"
  has "$(out)" "starts with -" "[types] …named"
  eq "$(bt "$P" "$W" go sp.sh "$(D "-$SP/out")" "body=$SP/body.txt")" 64 "[types] a value starting with -: rc 64"
  eq "$(bt "$P" "$W" go sp.sh "$(D "$SP/../scratchpad/out")" "body=$SP/body.txt")" 64 "[types] a .. segment beside a -home-… segment: rc 64"
  has "$(out)" "has a . or .. segment" "[types] …named"
  ln -s "$SP/body.txt" "$SP/link.txt"
  eq "$(bt "$P" "$W" go sp.sh "$(D "$SP/out")" "body=$SP/link.txt")" 64 "[types] an input that is a link under a -home-… segment: rc 64"
  has "$(out)" "a link is never followed" "[types] …named"
  mkb "$P" "$W/h.sh" "dest=under:~" "{dest}/** — the file"
  BT_ENV=(HOME=rel/home); eq "$(bt "$P" "$W" go h.sh "dest=/x")" 64 "[types] under:~ with a relative HOME: rc 64"; BT_ENV=()
  mkb "$P" "$W/t.sh" "dest=path a=path b=path c=path d=path e=path" "{dest}/** — x" "" '  write "put $P_DEST/x" touch -- "$P_DEST/x"'
  local w=() l; for l in a b c d e; do w+=("$l=/$(printf 'x%.0s' $(seq 1 999))"); done
  eq "$(bt "$P" "$W" go t.sh "$(D "$W/x")" "${w[@]}")" 64 "[types] values over 4096 bytes in total: rc 64"
  has "$(out)" "over 4096" "[types] …named"
}

fam_call() {
  local P=$1; setup "$P"
  mkb "$P" "$W/c.sh" "dest=path n=name" "{dest}/** — the file" "" '  write "put $P_DEST/x — $P_N" touch -- "$P_DEST/x"'
  sed -i 's/ — \$P_N//' "$W/c.sh"
  eq "$(bt "$P" "$W" go c.sh "$(D "$W/o")")" 64 "[call] a key missing: rc 64"
  has "$(out)" "n: missing" "[call] …named"
  has "$(out)" "# Params: dest=path n=name" "[call] …and the declared Params line is printed"
  eq "$(bt "$P" "$W" go c.sh "$(D "$W/o")" n=a other=b)" 64 "[call] an unknown key: rc 64"
  has "$(out)" "other: no such key" "[call] …named"
  eq "$(bt "$P" "$W" go c.sh "$(D "$W/o")" n=a n=b)" 64 "[call] a key given twice: rc 64"
  has "$(out)" "n: given twice" "[call] …named"
  eq "$(bt "$P" "$W" go c.sh "$(D "$W/o")" n=a stray)" 64 "[call] a word with no '=': rc 64"
  has "$(out)" "no '='" "[call] …named"
  eq "$(bt "$P" "$W" go c.sh "$(D "$W/o")" n=A)" 64 "[call] a value that fails its type: rc 64"
  has "$(out)" "n=A: is not a name value" "[call] …named"
  eq "$(bt "$P" "$W" go c.sh "$(D "$W/o")" "n=a b")" 64 "[call] a value with a space in a word type: rc 64"
  has "$(out)" "n='a b'" "[call] …named, shell-quoted"
  eq "$(bt "$P" "$W" go c.sh "$(D "$W/o")" n=+x)" 64 "[call] a value starting with +: rc 64"
  eq "$(bt "$P" "$W" go c.sh "$(D "$W/o")" n=:x)" 64 "[call] a value starting with :: rc 64"
  eq "$(bt "$P" "$W" go c.sh "$(D "$W/o")" n=@x)" 64 "[call] a value starting with @: rc 64"
  [ ! -e "$W/o/x" ] && [ "$(nsig)" = 0 ] && ok "[call] …nothing ran, nothing signed" || bad "[call] …nothing ran, nothing signed"
  mkdir -p "$W/o"
  eq "$(bt "$P" "$W" go c.sh n=a "$(D "$W/o")")" 0 "[call] the words in any order: rc 0"
  mkb "$P" "$W/z.sh" "none" "/x — the file" "" '  write "put /x" true'
  eq "$(bt "$P" "$W" rehearse z.sh a=1)" 64 "[call] Params: none takes no word: rc 64"
}

# ── delivery: argv in declared order, P_ names only from the values block, file values as read-only copies ────────────────────
fam_delivery() {
  local P=$1 c n; setup "$P"; mkdir -p "$W/o"
  mkb "$P" "$W/d.sh" "dest=path n=name m=name" "{dest}/** — the file" 'NENV=$(env | { grep -c "^P_" || true; })' \
    '  echo "VALS $P_N $P_M INH ${P_INHERIT:-unset} ENVP $NENV"
  write "put $P_DEST/x" touch -- "$P_DEST/x"'
  BT_ENV=(P_INHERIT=evil P_N=evil P_DEST=/evil)
  eq "$(bt "$P" "$W" rehearse d.sh m=second n=first "$(D "$W/o")")" 0 "[delivery] rehearse rc 0"
  has "$(out)" "VALS first second" "[delivery] the values reach the script in the declared order"
  has "$(out)" "INH unset" "[delivery] a P_ variable the caller set is not inherited"
  has "$(out)" "ENVP 0" "[delivery] the values are not exported to children"
  BT_ENV=()
  mkb "$P" "$W/f.sh" "src=file dest=path" "{dest}/** — the file" "" '  echo "SRC $P_SRC"
  write "put $P_DEST/x" cp -- "$P_SRC" "$P_DEST/x"'
  eq "$(bt "$P" "$W" go f.sh "src=$W/f.txt" "$(D "$W/o")")" 0 "[delivery] go with a file value: rc 0"
  c="$(bdir)/inputs/$(shaf "$W/f.txt").f.txt/f.txt"
  [ -f "$c" ] && ok "[delivery] the copy is <state>/inputs/<sha256>.<name>/<name>" || bad "[delivery] the copy is <state>/inputs/<sha256>.<name>/<name>"
  eq "$(modeof "$c")" 400 "[delivery] …mode 400"
  eq "$(modeof "$(dirname "$c")")" 500 "[delivery] …in a directory of mode 500"
  has "$(cat "$(bdir)"/runs/*.log)" "SRC $c" "[delivery] the script reads the copy, not the original"
  chmod 700 "$(dirname "$c")"; chmod 600 "$c"; echo tampered > "$c"; chmod 400 "$c"; chmod 500 "$(dirname "$c")"; rm -f "$W/o/x"
  eq "$(bt "$P" "$W" go f.sh "src=$W/f.txt" "$(D "$W/o")")" 3 "[delivery] a copy that changed: rc 3"
  has "$(out)" "it was removed" "[delivery] …it is removed"
  eq "$(ninputs)" 0 "[delivery] …and the refused call leaves nothing under <state>/inputs, not even set aside"
  eq "$(bt "$P" "$W" go f.sh "src=$W/f.txt" "$(D "$W/o")")" 0 "[delivery] …and the next call works"
  eq "$(cat "$c")" hello "[delivery] …its copy holds the bytes again"
  chmod 700 "$(dirname "$c")"; rm -rf "$(dirname "$c")"; ln -s "$W" "$(dirname "$c")"; rm -f "$W/o/x"
  eq "$(bt "$P" "$W" go f.sh "src=$W/f.txt" "$(D "$W/o")")" 3 "[delivery] a copy directory that is a link: rc 3"
  [ ! -L "$(dirname "$c")" ] && [ -d "$W" ] && ok "[delivery] …the link is removed, what it named untouched" || bad "[delivery] …the link is removed, what it named untouched"
  rm -f "$W/o/x"
  eq "$(bt "$P" "$W" go f.sh "src=$W/f.txt" "$(D "$W/o")")" 0 "[delivery] …the next call runs"
  [ -d "$(dirname "$c")" ] && [ ! -L "$(dirname "$c")" ] && ok "[delivery] …a real copy replaces it" || bad "[delivery] …a real copy replaces it"
  local sp; sp="$(fresh)/st ate"; mkdir -p "$sp"
  eq "$( ( cd "$W" && cenv XDG_STATE_HOME="$sp" python3 "$P/scripts/baton.py" go f.sh "src=$W/f.txt" "$(D "$W/o")" ) > "$BT_OUT" 2>&1; echo $?)" 64 \
    "[delivery] a state directory whose path fails the path type: rc 64"
  n=$(cenv XDG_STATE_HOME="$ST" python3 -c 'import os, sys, time
sys.path.insert(0, sys.argv[1] + "/scripts"); import baton
top = os.path.join(baton.state_dir(), "inputs-prune"); os.makedirs(top)
for i in range(205):
    d = os.path.join(top, "%064x.f" % i); os.makedirs(d); os.chmod(d, 0o500); os.utime(d, (1000 + i, 1000 + i))
baton.prune_inputs(top); left = sorted(os.listdir(top)); print(len(left), left[0][:64] == "%064x" % 5)' "$P")
  eq "$n" "200 True" "[delivery] the newest 200 copies are kept"
  n=$(cenv XDG_STATE_HOME="$ST" python3 -c 'import os, sys, time
sys.path.insert(0, sys.argv[1] + "/scripts"); import baton
top = os.path.join(baton.state_dir(), "inputs-aside"); os.makedirs(top)
for i in range(25):
    d = os.path.join(top, ".mismatch-%03d" % i); os.makedirs(d); os.chmod(d, 0o500); os.utime(d, (1000 + i, 1000 + i))
for name, age in ((".tmp-old", 7200), (".tmp-new", 10)):
    d = os.path.join(top, name); os.makedirs(d); os.chmod(d, 0o500); os.utime(d, (time.time() - age, time.time() - age))
baton.prune_inputs(top); left = sorted(os.listdir(top))
print(sum(1 for x in left if x.startswith(".mismatch-")), ".tmp-old" in left, ".tmp-new" in left)' "$P")
  eq "$n" "20 False True" "[delivery] the newest 20 set-aside copies are kept, and a temporary directory older than an hour goes"
  n=$(cenv XDG_STATE_HOME="$ST" python3 -c 'import os, stat, sys
sys.path.insert(0, sys.argv[1] + "/scripts"); import baton
top = os.path.join(baton.state_dir(), "inputs-link"); os.makedirs(top); out = os.path.join(baton.state_dir(), "outside")
os.makedirs(os.path.join(out, "sub")); os.chmod(out, 0o755); os.chmod(os.path.join(out, "sub"), 0o755)
os.symlink(out, os.path.join(top, ".mismatch-000")); os.utime(os.path.join(top, ".mismatch-000"), (1, 1), follow_symlinks=False)
for i in range(1, 21):
    d = os.path.join(top, ".mismatch-%03d" % i); os.makedirs(d); os.utime(d, (100 + i, 100 + i))
baton.prune_inputs(top)
print(os.path.lexists(os.path.join(top, ".mismatch-000")), "%o" % stat.S_IMODE(os.stat(out).st_mode),
      "%o" % stat.S_IMODE(os.stat(os.path.join(out, "sub")).st_mode))' "$P")
  eq "$n" "False 755 755" "[delivery] a set-aside entry that is a link is removed, and what it points to is never touched"
}

# ── copies: a call that never reaches its run phase removes the copies it bound, unless another process holds one; a run's stay ─
fam_copies() {
  local P=$1 c cmd rc pid n; setup "$P"; mkdir -p "$W/o"
  mkb "$P" "$W/f.sh" "src=file dest=path" "{dest}/** — the file" "" '  write "put $P_DEST/x" cp -- "$P_SRC" "$P_DEST/x"'
  c="$(bdir)/inputs/$(shaf "$W/f.txt").f.txt"
  eq "$(bt "$P" "$W" rehearse f.sh "src=$W/f.txt" "$(D "$W/o")")/$(ninputs)" "0/0" "[copies] rehearse with a file value: rc 0, no copy left"
  bt "$P" "$W" mode manual >/dev/null
  eq "$(bt "$P" "$W" go f.sh "src=$W/f.txt" "$(D "$W/o")")" 8 "[copies] go that stops for the owner: rc 8"
  has "$(out)" "copy $c/f.txt" "[copies] …the card names the copy"
  eq "$(ninputs)" 0 "[copies] …and leaves no copy of the file value"
  eq "$(bt "$P" "$W" run f.sh "src=$W/f.txt" "$(D "$W/o")")/$(ninputs)" "3/0" "[copies] run with no signature: rc 3, no copy left"
  eq "$(bt "$P" "$W" go --queue f.sh "src=$W/f.txt" "$(D "$W/o")")/$(ninputs)" "0/0" "[copies] go --queue: rc 0, the queued item leaves no copy"
  cmd=$(sed -n "s/^on the owner's go: //p" "$BT_OUT")
  [ -z "$cmd" ] && { bt "$P" "$W" go f.sh "src=$W/f.txt" "$(D "$W/o")" >/dev/null; cmd=$(sed -n "s/^on the owner's go: //p" "$BT_OUT"); }
  guard_cmd "$P" "$W" "$ST" "$OWNER_SID" "$cmd" >/dev/null
  rc=$( ( cd "$W" && eval "cenv XDG_STATE_HOME='$ST' XDG_DATA_HOME='$XD' CLAUDE_CODE_SESSION_ID='$OWNER_SID' ${cmd}" ) > "$BT_OUT" 2>&1; echo $?)
  eq "$rc/$(ninputs)" "0/0" "[copies] the owner signs: rc 0, and the signing leaves no copy either"
  eq "$(bt "$P" "$W" run f.sh "src=$W/f.txt" "$(D "$W/o")")" 0 "[copies] the signed run: rc 0"
  eq "$(cat "$W/o/x" 2>/dev/null)" hello "[copies] …it read the bytes the owner signed"
  [ -d "$c" ] && ok "[copies] a run's copy stays" || bad "[copies] a run's copy stays"
  python3 -c 'import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDONLY); fcntl.flock(fd, fcntl.LOCK_SH); open(sys.argv[2], "w").close(); time.sleep(120)' "$c" "$W/held" &
  pid=$!; n=0; while [ ! -e "$W/held" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n+1)); done
  eq "$(bt "$P" "$W" rehearse f.sh "src=$W/f.txt" "$(D "$W/o")")" 0 "[copies] a rehearse while another process holds the copy: rc 0"
  [ -d "$c" ] && ok "[copies] …the copy another process holds stays" || bad "[copies] …the copy another process holds stays"
  # a copy that fails its check while another process holds it is left to that process, and the call is refused
  chmod 700 "$c"; chmod 600 "$c/f.txt"; echo tampered > "$c/f.txt"; chmod 400 "$c/f.txt"; chmod 500 "$c"
  eq "$(bt "$P" "$W" rehearse f.sh "src=$W/f.txt" "$(D "$W/o")")" 3 "[copies] a copy that changed while another process holds it: rc 3"
  has "$(out)" "another baton process holds it" "[copies] …it says another process holds it"
  [ -d "$c" ] && ok "[copies] …and leaves the held copy to it" || bad "[copies] …and leaves the held copy to it"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  eq "$(bt "$P" "$W" rehearse f.sh "src=$W/f.txt" "$(D "$W/o")")/$(ninputs)" "3/0" "[copies] …once nobody holds it, the next call removes it: rc 3, nothing left"
  eq "$(bt "$P" "$W" rehearse f.sh "src=$W/f.txt" "$(D "$W/o")")/$(ninputs)" "0/0" "[copies] …and the call after it works and leaves nothing"
  n=$(cenv XDG_STATE_HOME="$ST" python3 -c 'import fcntl, os, sys
sys.path.insert(0, sys.argv[1] + "/scripts"); import baton
top = os.path.join(baton.state_dir(), "inputs-held"); os.makedirs(top)
for i in range(203):
    d = os.path.join(top, "%064x.f" % i); os.makedirs(d); os.chmod(d, 0o500); os.utime(d, (1000 + i, 1000 + i))
ready, done = os.pipe(), os.pipe()
pid = os.fork()
if pid == 0:                                            # another process holds the oldest copy until the prune is over
    fd = os.open(os.path.join(top, "%064x.f" % 0), os.O_RDONLY); fcntl.flock(fd, fcntl.LOCK_SH)
    os.write(ready[1], b"x"); os.read(done[0], 1); os._exit(0)
os.read(ready[0], 1)
baton.prune_inputs(top); left = set(os.listdir(top)); os.write(done[1], b"x"); os.waitpid(pid, 0)
print(len(left), ("%064x.f" % 0) in left, ("%064x.f" % 1) in left)' "$P")
  eq "$n" "201 True False" "[copies] prune keeps a copy another process holds, and removes the next oldest"
  n=$(cenv XDG_STATE_HOME="$ST" python3 -c 'import os, sys
sys.path.insert(0, sys.argv[1] + "/scripts"); import baton
top = os.path.join(baton.state_dir(), "inputs-closed"); os.makedirs(top)
for i in range(201):
    d = os.path.join(top, "%064x.f" % i); os.makedirs(d); open(os.path.join(d, "f"), "w").close(); os.chmod(d, 0o500); os.utime(d, (1000 + i, 1000 + i))
os.chmod(os.path.join(top, "%064x.f" % 0), 0)
baton.prune_inputs(top); left = os.listdir(top); print(len(left), ("%064x.f" % 0) in left)
for n in left:
    os.chmod(os.path.join(top, n), 0o700)' "$P")
  eq "$n" "200 False" "[copies] prune removes a copy directory it cannot open (nobody can hold one)"
}

# ── secrets: a file or input value that looks like key material is refused before any copy; a path value is never copied ────
# nostate <marker> — 0 when no file under the state directory holds the marker (the inputs copies, the run logs, log.tsv)
nostate() { ! grep -rqF -- "$1" "$ST" 2>/dev/null; }
ninputs() { find "$(bdir)/inputs" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' '; }
fam_secret() {
  local P=$1 S kind f m n=0 big; setup "$P"; S=$(fresh); mkdir -p "$W/o"
  mkb "$P" "$W/sf.sh" "src=file dest=path" "{dest}/** — the file" "" '  write "put $P_DEST/x" cp -- "$P_SRC" "$P_DEST/x"'
  mkb "$P" "$W/si.sh" "body=input dest=path" "{dest}/** — the file" "" '  write "put $P_DEST/x" cp -- "$P_BODY" "$P_DEST/x"'
  mkb "$P" "$W/sp.sh" "src=path dest=path" "{dest}/** — the file" "" '  write "put $P_DEST/x" cp -- "$P_SRC" "$P_DEST/x"'
  while IFS=$'\t' read -r kind f m; do
    n=$((n+1)); rm -f "$W/o/x"
    eq "$(bt "$P" "$W" go sf.sh "src=$f" "$(D "$W/o")")" 64 "[secret] a $kind as a file value ($(basename "$f")): rc 64"
    has "$(out)" "looks like a secret ($kind)" "[secret] …the kind is named ($(basename "$f"))"
    has "$(out)" "path Param" "[secret] …the safe way, a path Param, is named ($(basename "$f"))"
    case "$(out)" in *"$m"*) bad "[secret] …the output holds the secret ($(basename "$f"))";; *) ok "[secret] …the output holds no byte of it ($(basename "$f"))";; esac
    eq "$(bt "$P" "$W" go si.sh "body=$f" "$(D "$W/o")")" 64 "[secret] a $kind as an input value ($(basename "$f")): rc 64"
    eq "$(ninputs)/$([ -e "$W/o/x" ] && echo ran || echo none)" "0/none" "[secret] …no copy under <state>/inputs, nothing ran ($(basename "$f"))"
    nostate "$m" && ok "[secret] …no state file holds it ($(basename "$f"))" || bad "[secret] …no state file holds it ($(basename "$f"))"
  done < <(python3 "$FX" secrets "$S")
  [ "$n" -ge 33 ] && ok "[secret] the fixture planted every kind" || bad "[secret] the fixture planted every kind ($n)"
  f="$S/id_ed25519"; m=$(python3 "$FX" secrets "$(fresh)" | sed -n 1p | cut -f3)
  eq "$(bt "$P" "$W" rehearse sf.sh "src=$f" "$(D "$W/o")")" 64 "[secret] rehearse refuses it too: rc 64"
  has "$(out)" "under a key that names no secret (key_file, not token)" "[secret] …and names the key-name screen the path Param still meets"
  eq "$(bt "$P" "$W" go sp.sh "src=$f" "$(D "$W/o")")" 0 "[secret] the same key as a path value: rc 0"
  has "$(cat "$W/o/x" 2>/dev/null)" "$m" "[secret] …the script read it where it is"
  eq "$(ninputs)" 0 "[secret] …and nothing was copied under <state>/inputs"
  nostate "$m" && ok "[secret] …no state file holds it" || bad "[secret] …no state file holds it"
  # the header at the very end of a file of exactly the 1 MiB cap is still found
  big="$W/big.pem"; python3 -c 'import sys
tail = open(sys.argv[2], "rb").read()[:80]
open(sys.argv[1], "wb").write(b"x" * (1024 * 1024 - len(tail)) + tail)' "$big" "$f"
  eq "$(bt "$P" "$W" go sf.sh "src=$big" "$(D "$W/o")")" 64 "[secret] a 1 MiB file with the key header at its end: rc 64"
  has "$(out)" "looks like a secret (private-key)" "[secret] …named"
  ln -s "$f" "$W/key-link"
  eq "$(bt "$P" "$W" go sf.sh "src=$W/key-link" "$(D "$W/o")")" 64 "[secret] a link to the key: rc 64, never followed"
  eq "$(ninputs)" 0 "[secret] …and still no copy"
  # prose about secrets is not a secret: an input that names them in words runs
  printf 'Rotate the GitHub token and the SSH private key.\nA token starts with ghp_ and a key file with BEGIN.\nBranch: sk-1234-fix-login-redirect-loop-on-safari\ntask-proj-migrate-the-whole-thing disk-ant-colony-optimization-algorithm\naws_session_token = sessionTokenFromEnvironmentVar\n' > "$W/prose.md"
  # placeholders in a doc are not secrets: fewer than 4 distinct characters at the end of the match
  printf 'GH_TOKEN=gh%s\nANTHROPIC_KEY=sk%s\n    client-key%s: %s\n' "p_$(printf 'X%.0s' $(seq 1 36))" "-ant-$(printf 'x%.0s' $(seq 1 24))" -data \
    "$(printf 'A%.0s' $(seq 1 40))" >> "$W/prose.md"
  rm -f "$W/o/x"
  eq "$(bt "$P" "$W" go si.sh "body=$W/prose.md" "$(D "$W/o")")" 0 "[secret] an input that only talks about secrets: rc 0"
  # no pattern scans a hostile 1 MiB value for long: each match has few starts
  n=$(python3 -c 'import sys, time
sys.path.insert(0, sys.argv[1] + "/scripts"); import baton
worst = 0
for pat in (b"eyJ", b"eyJabcdefghij-", b"eyJ.", b"ghp_", b"sk-", b"sk-a", b"glpat-", b"AIza", b"AKIA", b"-----BEGIN ", b"client-key-data: ",
            b"aws_secret_access_key ", b"sessiontoken=", b"secretaccesskey=", b"=sessiontoken=", b"%3D", b"\\n"):
    d = (pat * ((1 << 20) // len(pat) + 1))[:1 << 20]; baton.SECRET_SEEN.clear(); t = time.time(); baton.secret_problem(d)
    worst = max(worst, time.time() - t)
d = b"sessiontoken" + b" " * ((1 << 20) - 12); baton.SECRET_SEEN.clear(); t = time.time(); baton.secret_problem(d)
worst = max(worst, time.time() - t)
print("slow" if worst > 5 else "fast")' "$P")
  eq "$n" fast "[secret] a hostile 1 MiB value is scanned in under 5 s per pattern set"
}

fam_binding() {
  local P=$1 r; setup "$P"; mkdir -p "$W/o"
  mkb "$P" "$W/b.sh" "src=file dest=path" "{dest}/** — the file" "" '  write "put $P_DEST/x" cp -- "$P_SRC" "$P_DEST/x"'
  eq "$(sg "$P" "$W" coordinator-auto b.sh "$(D "$W/o")" "src=$W/f.txt")" 0 "[binding] sign: rc 0"
  r=$(cat "$(bdir)"/signatures/*.json)
  has "$r" "\"$(shaf "$W/f.txt")\"" "[binding] the signature binds the file value's sha256 (inputs)"
  has "$(printf '%s' "$r" | tr -d ' \n')" "\"args\":[\"src=$W/f.txt\",\"dest=$W/o\"]" "[binding] …and the call words, key=value in the declared order"
  echo changed > "$W/f.txt"
  eq "$(bt "$P" "$W" run b.sh "src=$W/f.txt" "$(D "$W/o")")" 3 "[binding] the file changed after signing: run rc 3"
  has "$(out)" "a file value changed" "[binding] …named"
  [ ! -e "$W/o/x" ] && ok "[binding] …nothing ran" || bad "[binding] …nothing ran"
}

# ── display: one uncut, escaped line per value; the log cuts at 120; the baton field ──────────────────────────────────────────
fam_display() {
  local P=$1 long; setup "$P"; mkdir -p "$W/o"
  long="/$(python3 -c 'print("y" * 198 + "Z")')"                 # a path value of 200 characters
  mkb "$P" "$W/s.sh" "dest=path n=name" "{dest}/** — the file"
  python3 - "$W/s.sh" <<'PY'
import sys
p = sys.argv[1]; t = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(t.replace("# Purpose: a test baton", "# Purpose: a test baton \x1b[2K‮hidden"))
PY
  bt "$P" "$W" mode manual >/dev/null
  eq "$(bt "$P" "$W" go s.sh "$(D "$long")" n=first)" 8 "[display] mode manual: the owner's card, rc 8"
  has "$(out)" "  param dest = $long" "[display] the card shows a 200-character value whole, on its own line"
  has "$(out)" "  param n = first" "[display] …one line per value"
  has "$(out)" 'a test baton \u{1b}[2K\u{202e}hidden' "[display] control and format characters of a header are escaped on the card"
  bt "$P" "$W" mode auto >/dev/null
  eq "$(bt "$P" "$W" go s.sh "$(D "$W/o")" n=second)" 0 "[display] go: rc 0"
  has "$(cat "$(bdir)"/runs/*.log)" "param n = second" "[display] the run log shows each value"
  eq "$(tail -n 1 "$(bdir)/log.tsv" | awk -F'\t' '{print NF}')" 13 "[display] a log line has 13 fields"
  eq "$(tail -n 1 "$(bdir)/log.tsv" | cut -f13)" "scratch@$(shaf "$W/s.sh")" "[display] …the last, baton, is scratch@<sha256> for a path"
  eq "$(sg "$P" "$W" coordinator-auto s.sh "$(D "$long")" n=third)" 0 "[display] sign with a 200-character value: rc 0"
  has "$(tail -n 1 "$(bdir)/log.tsv" | cut -f6)" "dest=/$(printf 'y%.0s' $(seq 1 113))\\u2026" "[display] log.tsv cuts a value at 120 characters"
  hasnt "$(tail -n 1 "$(bdir)/log.tsv" | cut -f6)" "$long" "[display] …the whole value is not logged"
}

# ── places: prefixes, the project root, files and names ───────────────────────────────────────────────────────────────────────
fam_places() {
  local P=$1 R H D2 s; setup "$P"; mkdir -p "$W/o"
  for s in lib:x site:x Kit:merge-pr KIND:install-file; do
    eq "$(bt "$P" "$W" go "$s")" 64 "[places] $s: rc 64"
  done
  has "$(out)" "is not a place" "[places] …named"
  mkdir -p "$XD/vibemaestro/batons"; mkb "$P" "$XD/vibemaestro/batons/act.sh" "dest=path" "{dest}/** — the file"
  eq "$(bt "$P" "$W" go act)" 64 "[places] a bare name: rc 64"
  has "$(out)" "call user:act" "[places] …the refusal names the place that holds it"
  mkb "$P" "$W/lib:x" "dest=path" "{dest}/** — the file"
  eq "$(bt "$P" "$W" go ./lib:x "$(D "$W/o")")" 0 "[places] a file whose name looks like a prefix runs as ./<file>"
  R=$(fresh); repo "$R"; mkdir -p "$R/sub/deeper"
  mkb "$P" "$R/.vibemaestro/batons/b.sh" "dest=path" "{dest}/** — the file"; rec "$(pkey "$R")" b 000001 keep "$(shaf "$R/.vibemaestro/batons/b.sh")"
  eq "$(bt "$P" "$R/sub/deeper" go project:b "$(D "$W/o")")" 0 "[places] project:<name> from a subdirectory of the git top level: rc 0"
  for s in project:a.b project:Ab "project:$(printf 'a%.0s' $(seq 1 65))"; do
    eq "$(bt "$P" "$R" go "$s")" 64 "[places] ${s:0:20}…: a kept name is [a-z0-9-], at most 64: rc 64"
  done
  eq "$(bt "$P" "$R" go project:nope)" 66 "[places] no such name in the place: rc 66"
  python3 -c 'import sys; open(sys.argv[1], "w").write("#" * (256 * 1024 + 1))' "$R/.vibemaestro/batons/huge.sh"
  eq "$(bt "$P" "$R" go project:huge)" 66 "[places] a baton over 256 KiB: rc 66"
  ln -s "$R/.vibemaestro/batons/b.sh" "$R/.vibemaestro/batons/ln.sh"
  eq "$(bt "$P" "$R" go project:ln "$(D "$W/o")")" 64 "[places] a kept baton that is a link: rc 64"
  chmod g+w "$R"; eq "$(bt "$P" "$R" go project:b "$(D "$W/o")")" 3 "[places] a project root its group can write: rc 3"; chmod g-w "$R"
  has "$(out)" "is owned by uid $(id -u), mode " "[places] …the refusal names its owner and its mode"
  chmod o+w "$R/.vibemaestro/batons"; eq "$(bt "$P" "$R" go project:b "$(D "$W/o")")" 3 "[places] a .vibemaestro/batons others can write: rc 3"
  chmod o-w "$R/.vibemaestro/batons"
  D2=$(fresh); repo "$D2"; mkdir -p "$D2/real"; rmdir "$D2/.vibemaestro/batons"; ln -s "$D2/real" "$D2/.vibemaestro/batons"
  cp "$R/.vibemaestro/batons/b.sh" "$D2/real/b.sh"; rec "$(pkey "$D2")" b 000001 keep "$(shaf "$D2/real/b.sh")"
  eq "$(bt "$P" "$D2" go project:b "$(D "$W/o")")" 64 "[places] a .vibemaestro/batons that is a link: rc 64"
  H=$(fresh); repo "$H"; mkdir -p "$H/sub"; cp "$R/.vibemaestro/batons/b.sh" "$H/.vibemaestro/batons/"
  BT_ENV=(HOME="$H"); eq "$(bt "$P" "$H/sub" go project:b "$(D "$W/o")")" 66 "[places] a git top level that is HOME is no project root: rc 66"
  H=$(fresh); mkdir -p "$H/.vibemaestro/batons" "$H/x"; cp "$R/.vibemaestro/batons/b.sh" "$H/.vibemaestro/batons/"
  BT_ENV=(HOME="$H"); eq "$(bt "$P" "$H/x" go project:b "$(D "$W/o")")" 66 "[places] the walk outside git stops before HOME: rc 66"; BT_ENV=()
  D2=$(fresh); mkdir -p "$D2/.vibemaestro/batons" "$D2/a/b"; cp "$R/.vibemaestro/batons/b.sh" "$D2/.vibemaestro/batons/"
  rec "$(pkey "$D2" walk)" b 000001 keep "$(shaf "$D2/.vibemaestro/batons/b.sh")"; rm -f "$W/o/x"
  eq "$(bt "$P" "$D2/a/b" go project:b "$(D "$W/o")")" 0 "[places] outside git, the nearest directory holding .vibemaestro/ is the root: rc 0"
  eq "$(bt "$P" "$(fresh)" go project:b)" 66 "[places] no project root: rc 66"
  mkb "$P" "$R/.vibemaestro/batons/merge-pr.sh" "dest=path" "{dest}/** — the file"
  eq "$(bt "$P" "$R" check kit:merge-pr)" 0 "[places] kit:merge-pr beside a project baton of that name: check rc 0"
  has "$(out)" "$P/batons/merge-pr.sh" "[places] …it is the plugin's kit: no place shadows a kit"
  local X2; X2="$(fresh)/data2"; mkdir -p "$X2/vibemaestro/batons"; cp "$R/.vibemaestro/batons/b.sh" "$X2/vibemaestro/batons/u.sh"
  rec user u 000001 keep "$(shaf "$X2/vibemaestro/batons/u.sh")"; rm -f "$W/o/x"
  XD=$X2; eq "$(bt "$P" "$W" go user:u "$(D "$W/o")")" 0 "[places] user:<name> is \$XDG_DATA_HOME/vibemaestro/batons/<name>.sh: rc 0"
  XD=rel/data; eq "$(bt "$P" "$W" go user:u "$(D "$W/o")")" 66 "[places] a relative XDG_DATA_HOME is ignored: rc 66"
}

# ── the pin: only a keep record makes a kept baton callable, at every step ────────────────────────────────────────────────────
fam_pin() {
  local P=$1 R K A B F L; setup "$P"; mkdir -p "$W/o"
  R=$(fresh); repo "$R"; K=$(pkey "$R"); F="$R/.vibemaestro/batons/p.sh"
  mkb "$P" "$F" "dest=path" "{dest}/** — the file"; A=$(shaf "$F")
  eq "$(bt "$P" "$R" go project:p "$(D "$W/o")")" 3 "[pin] no keep record: rc 3"
  has "$(out)" "sha256 $A" "[pin] …the refusal names the file's sha256"
  has "$(out)" "Read it; keep it only if you have read it and mean these bytes" "[pin] …and what to do"
  eq "$(bt "$P" "$R" check project:p)" 0 "[pin] check reads an unpinned baton: rc 0"
  has "$(out)" "not pinned on this machine" "[pin] …and says it cannot be called"
  rec "$K" p 000001 keep "$A"
  eq "$(bt "$P" "$R" go project:p "$(D "$W/o")")" 0 "[pin] a keep record pins it: rc 0"
  has "$(out)" "project:p $LABEL" "[pin] go's one line carries 'not reviewed, kept by'"
  eq "$(tail -n 1 "$(bdir)/log.tsv" | cut -f13)" "project:p@$A" "[pin] the log's baton field is project:p@<sha256>"
  rec "$K" p 000002 retire "$A"; rm -f "$W/o/x"
  eq "$(bt "$P" "$R" go project:p "$(D "$W/o")")" 3 "[pin] a retired sha: rc 3"
  has "$(out)" "these bytes were retired" "[pin] …named"
  rec "$K" p 000003 keep "$A"
  eq "$(bt "$P" "$R" go project:p "$(D "$W/o")")" 0 "[pin] a later keep of a retired sha pins it again: rc 0"
  echo '# v2' >> "$F"; B=$(shaf "$F"); rec "$K" p 000004 keep "$B"; rm -f "$W/o/x"
  eq "$(bt "$P" "$R" go project:p "$(D "$W/o")")" 0 "[pin] project: the newer sha runs"
  sed -i '$d' "$F"; rm -f "$W/o/x"
  eq "$(bt "$P" "$R" go project:p "$(D "$W/o")")" 0 "[pin] project: an older sha stays pinned until retired (another branch's version)"
  echo '# not kept' >> "$F"
  eq "$(bt "$P" "$R" go project:p "$(D "$W/o")")" 3 "[pin] an edited file: rc 3"
  has "$(out)" "was kept with sha256 $B, kept by" "[pin] …the refusal names the newest kept sha and who kept it"
  echo "{\"sha256\": \"$(shaf "$F")\"}" > "$(bdir)/kept/$K/p/9.json"; echo junk > "$(bdir)/kept/$K/p/000010.json"
  eq "$(bt "$P" "$R" go project:p "$(D "$W/o")")" 3 "[pin] a file not named <6 digits>.json, or not JSON, is no record: still rc 3"
  sed -i '$d' "$F"; age "$F" 600; rm -f "$W/o/x"
  eq "$(bt "$P" "$R" go project:p "$(D "$W/o")")" 0 "[pin] a kept baton has no 120 s gate"
  L="$XD/vibemaestro/batons"; mkdir -p "$L"; mkb "$P" "$L/u.sh" "dest=path" "{dest}/** — the file"; A=$(shaf "$L/u.sh")
  rec user u 000001 keep "$A"; echo '# v2' >> "$L/u.sh"; B=$(shaf "$L/u.sh"); rec user u 000002 keep "$B"; rm -f "$W/o/x"
  eq "$(bt "$P" "$W" go user:u "$(D "$W/o")")" 0 "[pin] user: the newest keep runs"
  sed -i '$d' "$L/u.sh"
  eq "$(bt "$P" "$W" go user:u "$(D "$W/o")")" 3 "[pin] user: a library file written back to an older version: rc 3"
  echo '# v2' >> "$L/u.sh"; rec user u 000003 retire "$B"
  eq "$(bt "$P" "$W" go user:u "$(D "$W/o")")" 3 "[pin] user: the newest keep retired: rc 3"
  sed -i '$d' "$L/u.sh"
  eq "$(bt "$P" "$W" go user:u "$(D "$W/o")")" 3 "[pin] user: …and no older keep comes back"
  R=$(fresh); repo "$R"; mkb "$P" "$R/.vibemaestro/batons/q.sh" "dest=path" "{dest}/** — the file"
  rec "$K" q 000001 keep "$(shaf "$R/.vibemaestro/batons/q.sh")"
  eq "$(bt "$P" "$R" go project:q "$(D "$W/o")")" 3 "[pin] another repository's keep record does not pin it: rc 3"
  K=$(pkey "$R"); A=$(shaf "$R/.vibemaestro/batons/q.sh"); rec "$K" q 000002 keep "$A"; rm -f "$W/o/x"
  eq "$(sg "$P" "$R" coordinator-auto project:q "$(D "$W/o")")" 0 "[pin] sign a pinned baton: rc 0"
  has "$(out)" "project:q $R/.vibemaestro/batons/q.sh sha256 $A, $LABEL" "[pin] the sign line names the file, its sha256 and the label"
  rec "$K" q 000003 retire "$A"
  eq "$(bt "$P" "$R" run project:q "$(D "$W/o")")" 3 "[pin] the pin moved after signing: run rc 3"
  [ ! -e "$W/o/x" ] && ok "[pin] …nothing ran" || bad "[pin] …nothing ran"
  rec "$K" q 000004 keep "$A"
  eq "$(sg "$P" "$R" coordinator-auto project:q "$(D "$W/o")")" 0 "[pin] sign again: rc 0"
  echo '# edited after signing' >> "$R/.vibemaestro/batons/q.sh"; rec "$K" q 000005 keep "$(shaf "$R/.vibemaestro/batons/q.sh")"
  eq "$(bt "$P" "$R" run project:q "$(D "$W/o")")" 3 "[pin] the file edited (and kept) after signing: run rc 3"
  [ ! -e "$W/o/x" ] && ok "[pin] …nothing ran" || bad "[pin] …nothing ran"
}

fam_worktrees() {
  local P=$1 R K A B; setup "$P"; mkdir -p "$W/o"
  R=$(fresh); repo "$R"; mkb "$P" "$R/.vibemaestro/batons/w.sh" "dest=path" "{dest}/** — the file"
  git_ -C "$R" add -A; git_ -C "$R" -c user.name=t -c user.email=t@t commit -qm one
  git_ -C "$R" worktree add -q "$R/wt" -b other 2>/dev/null
  echo '# the other branch' >> "$R/wt/.vibemaestro/batons/w.sh"
  K=$(pkey "$R"); eq "$(pkey "$R/wt")" "$K" "[worktrees] the place key is git's common directory: one in every worktree"
  A=$(shaf "$R/.vibemaestro/batons/w.sh"); B=$(shaf "$R/wt/.vibemaestro/batons/w.sh"); rec "$K" w 000001 keep "$A"; rec "$K" w 000002 keep "$B"
  eq "$(bt "$P" "$R" go project:w "$(D "$W/o")")" 0 "[worktrees] the main worktree runs its version"
  has "$(tail -n 1 "$(bdir)/log.tsv" | cut -f13)" "@$A" "[worktrees] …the bytes it holds"
  rm -f "$W/o/x"
  eq "$(bt "$P" "$R/wt" go project:w "$(D "$W/o")")" 0 "[worktrees] the other worktree runs its own version"
  has "$(tail -n 1 "$(bdir)/log.tsv" | cut -f13)" "@$B" "[worktrees] …the bytes it holds"
}

# ── the Targets of a baton with Params ────────────────────────────────────────────────────────────────────────────────────────
fam_targets() {
  local P=$1 R t; setup "$P"; mkdir -p "$W/o"
  R=$(fresh); repo "$R"
  for t in "the file named by dest" "{nope}/** — x" "{inp}/x — x" "{src}/x — x" "{dest}* — x" "/** — x" "https://** — x"; do
    mkb "$P" "$R/.vibemaestro/batons/t.sh" "dest=path inp=input src=file" "$t"
    eq "$(bt "$P" "$R" check project:t)" 1 "[targets] a kept baton whose Targets are '${t%% — *}': check rc 1"
    has "$(out)" "patterns the runner tests" "[targets] …'${t%% — *}' named"
  done
  mkb "$P" "$W/prose.sh" "dest=path" "the file named by dest" "" '  write "put /elsewhere/x" touch -- "$P_DEST/x"'
  eq "$(bt "$P" "$W" go prose.sh "$(D "$W/o")")" 0 "[targets] a scratch baton whose Targets do not parse is not tested: rc 0"
  t='  write "put $P_DEST/x" touch -- "$P_DEST/x"'
  mkb "$P" "$W/out.sh" "dest=path" "{dest}/** — the file" "" "$t"$'\n''  write "put /elsewhere/y" true' $'put *\nput *'
  eq "$(bt "$P" "$W" go out.sh "$(D "$W/o")")" 1 "[targets] a plan line outside the declared Targets: go rc 1"
  has "$(out)" "go: stopped at plan-vs-Targets" "[targets] …go stops at plan-vs-Targets"
  has "$(out)" "/elsewhere/y is not a declared target" "[targets] …the word is named"
  eq "$(nsig)" 0 "[targets] …nothing signed"
  mkb "$P" "$W/dd.sh" "dest=path" "{dest}/** — the file" "" '  write "put $P_DEST/../x" true'
  eq "$(bt "$P" "$W" go dd.sh "$(D "$W/o")")" 1 "[targets] a word with a .. segment under a declared /** pattern: rc 1"
  has "$(out)" "has a .. segment" "[targets] …named"
  mkb "$P" "$W/rel.sh" "dest=path" "{dest}/** — the file" "" '  write "put $P_DEST/x from ../up/y" touch -- "$P_DEST/x"'
  eq "$(bt "$P" "$W" go rel.sh "$(D "$W/o")")" 1 "[targets] a relative word with a .. segment beside a declared target: rc 1"
  has "$(out)" "../up/y has a .. segment" "[targets] …named"
  mkb "$P" "$W/key.sh" "dest=path" "{dest}/** — the file" "" '  write "put $P_DEST/x from=../up/y" touch -- "$P_DEST/x"'
  eq "$(bt "$P" "$W" go key.sh "$(D "$W/o")")" 1 "[targets] a key=../x word beside a declared target: rc 1"
  mkb "$P" "$W/cp.sh" "src=file dest=path" "{dest}/** — the file" "" '  write "put $P_DEST/x from $P_SRC" cp -- "$P_SRC" "$P_DEST/x"'
  eq "$(bt "$P" "$W" go cp.sh "src=$W/f.txt" "$(D "$W/o")")" 0 "[targets] the copy of a file value (under <state>/inputs) is exempt"
  t='R="${XDG_STATE_HOME:-$HOME/.local/state}/vibemaestro/baton"'
  mkb "$P" "$W/rc.sh" "dest=path" "{dest}/** — the file" "$t" '  write "record $P_DEST/x $R/records/r1" touch -- "$P_DEST/x"'
  eq "$(bt "$P" "$W" go rc.sh "$(D "$W/o")")" 0 "[targets] a run record under <state>/records is exempt"
  mkb "$P" "$W/kr.sh" "dest=path" "{dest}/** — the file" "$t" '  write "pin $P_DEST/x $R/kept/x/y/000001.json" true'
  eq "$(bt "$P" "$W" go kr.sh "$(D "$W/o")")" 1 "[targets] a plan line naming the keep records: rc 1"
  mkb "$P" "$W/em.sh" "dest=path" "{dest}/** — the file" "" '  write "put $P_DEST/x — see /etc/hosts and o/r#1" touch -- "$P_DEST/x"'
  eq "$(bt "$P" "$W" go em.sh "$(D "$W/o")")" 0 "[targets] words after ' — ' are not tested"
  for t in "o/r#1" "host-1:/etc/x" "https://example.invalid/x" "refs/heads/x" "/etc/passwd"; do
    mkb "$P" "$W/tl.sh" "dest=path" "{dest}/** — the file" "" "  write \"put \$P_DEST/x $t\" true"
    eq "$(bt "$P" "$W" go tl.sh "$(D "$W/o")")" 1 "[targets] an undeclared target-looking word $t: rc 1"
  done
  mkb "$P" "$W/bh.sh" "dest=path" "{dest}/** — the file" "" '  write "put $P_DEST/x on pod-1" touch -- "$P_DEST/x"'
  eq "$(bt "$P" "$W" go bh.sh "$(D "$W/o")")" 0 "[targets] a bare host or pod name is not target-looking (the stated limit)"
  mkb "$P" "$W/nt.sh" "dest=path" "{dest}/** — the file" "" '  write "note something" true'
  eq "$(bt "$P" "$W" go nt.sh "$(D "$W/o")")" 1 "[targets] a plan line that names no declared target: rc 1"
  has "$(out)" "names no declared target" "[targets] …named"
  mkb "$P" "$W/rp.sh" "repo=repo issue=int dest=path" "{repo}#{issue} {dest}/** — the comment" "" '  write "comment $P_REPO#$P_ISSUE" touch -- "$P_DEST/x"'
  eq "$(bt "$P" "$W" go rp.sh repo=o/r issue=7 "$(D "$W/o")")" 0 "[targets] {repo}#{issue} matches o/r#7"
}

# ── the parameter checks of check (the shell reader) ──────────────────────────────────────────────────────────────────────────
fam_reader() {
  local P=$1; setup "$P"
  pyfam "$P" reader reader
  mkb "$P" "$W/nop.sh" "none" "/x — the file" 'X="$1"' '  write "put /x" true'
  sed -i '/^# Params: none$/d' "$W/nop.sh"
  eq "$(bt "$P" "$W" check nop.sh)" 0 "[reader] a baton without Params (today's library) is not read for parameters"
  mkb "$P" "$W/tx.sh" "dest=path t=text" "{dest}/** — the file"
  eq "$(bt "$P" "$W" check tx.sh)" 1 "[reader] a baton declaring a text parameter: check rc 1 (free text goes through an input file)"
  has "$(out)" "the type is one of" "[reader] …named"
}

# ── baton list ────────────────────────────────────────────────────────────────────────────────────────────────────────────────
fam_list() {
  local P=$1 R K L k n o t0 t1 len; setup "$P"; mkdir -p "$W/o"
  R=$(fresh); repo "$R"; K=$(pkey "$R"); L="$XD/vibemaestro/batons"; mkdir -p "$L"
  mkb "$P" "$R/.vibemaestro/batons/put-file.sh" "dest=path" "{dest}/** — the file"
  python3 - "$R/.vibemaestro/batons/put-file.sh" <<'PY'
import sys
p = sys.argv[1]; t = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(t.replace("# Purpose: a test baton", "# Purpose: put a file \x1b[2Kthere"))
PY
  rec "$K" put-file 000001 keep "$(shaf "$R/.vibemaestro/batons/put-file.sh")"
  cp "$R/.vibemaestro/batons/put-file.sh" "$R/.vibemaestro/batons/merge-pr.sh"
  mkb "$P" "$R/.vibemaestro/batons/loose.sh" "dest=path" "{dest}/** — the file"; echo '# x' >> "$R/.vibemaestro/batons/loose.sh"
  mkb "$P" "$R/.vibemaestro/batons/old.sh" "dest=path" "{dest}/** — the file"; echo '# o' >> "$R/.vibemaestro/batons/old.sh"
  rec "$K" old 000001 keep "$(shaf "$R/.vibemaestro/batons/old.sh")"; echo '# o2' >> "$R/.vibemaestro/batons/old.sh"
  rec "$K" old 000002 keep "$(shaf "$R/.vibemaestro/batons/old.sh")"; sed -i '$d' "$R/.vibemaestro/batons/old.sh"
  mkb "$P" "$R/.vibemaestro/batons/gone.sh" "dest=path" "{dest}/** — the file"; echo '# g' >> "$R/.vibemaestro/batons/gone.sh"
  rec "$K" gone 000001 keep "$(shaf "$R/.vibemaestro/batons/gone.sh")"; rec "$K" gone 000002 retire "$(shaf "$R/.vibemaestro/batons/gone.sh")"
  mkb "$P" "$R/.vibemaestro/batons/chg.sh" "dest=path" "{dest}/** — the file"; echo '# c' >> "$R/.vibemaestro/batons/chg.sh"
  rec "$K" chg 000001 keep "$(shaf "$R/.vibemaestro/batons/chg.sh")"; echo '# c2' >> "$R/.vibemaestro/batons/chg.sh"
  python3 -c 'import sys; open(sys.argv[1], "w").write("#!/usr/bin/env bash\n# Purpose: big\n" + "#" * (256 * 1024))' "$R/.vibemaestro/batons/big.sh"
  printf '#!/usr/bin/env bash\n# Purpose: would leave a mark if it ran\ntouch "%s/ran"\n' "$W" > "$R/.vibemaestro/batons/mark.sh"
  eq "$(bt "$P" "$R" go project:put-file "$(D "$W/o")")" 0 "[list] instrument: one ok run of project:put-file"
  rm -f "$W/o/x"; bt "$P" "$R" go project:put-file "$(D "$W/o")" >/dev/null
  local before; before=$(find "$ST" -type f -exec sha1sum {} + | sort | sha1sum)
  eq "$(bt "$P" "$R" list)" 0 "[list] list: rc 0"; o=$(out)
  has "$o" "kit:merge-pr  auto  runs 0  reviewed  merge one pull request" "[list] a kit line: prefix:name, auto, runs, reviewed, Purpose"
  has "$o" "— --repo <owner/name> --pr <n>" "[list] …then its Usage"
  has "$o" "project:put-file  auto  runs 2" "[list] runs: the ok runs of these bytes under this name"
  has "$o" "$LABEL  put a file \u{1b}[2Kthere" "[list] the label, then the Purpose, escaped"
  has "$o" "project:merge-pr  auto  runs 0  unpinned, kit:merge-pr exists: retire, copy of project:put-file  not kept on this machine" \
    "[list] marks: unpinned, kit exists, copy of; the label of an unpinned file"
  has "$o" "project:loose  auto  runs 0  unpinned  not kept on this machine" "[list] a file never kept: unpinned"
  has "$o" "project:old  auto  runs 0  older version  $LABEL" "[list] a pinned sha that is not the newest: older version"
  has "$o" "project:gone  auto  runs 0  unpinned, retired" "[list] a retired sha: unpinned, retired"
  has "$o" "project:chg  auto  runs 0  unpinned, changed since kept" "[list] an edited file: changed since kept"
  has "$o" "project:big  owner  runs 0  too large" "[list] a file over 256 KiB: too large"
  [ ! -e "$W/ran" ] && ok "[list] list never runs a baton" || bad "[list] list never runs a baton"
  eq "$(find "$ST" -type f -exec sha1sum {} + | sort | sha1sum)" "$before" "[list] list writes nothing"
  eq "$(bt "$P" "$R" list MERGE guard)" 0 "[list] keywords: rc 0"
  has "$(out)" "  Purpose: merge one pull request" "[list] keywords match regardless of case, all of them: the one match prints its whole entry"
  eq "$(bt "$P" "$R" list merge nothing-like-this)" 0 "[list] no match: rc 0"
  eq "$(out)" "no baton matches merge nothing-like-this" "[list] …it says so"
  bt "$P" "$R" list dest >/dev/null; has "$(out)" "project:put-file" "[list] a keyword matches a parameter key"
  for k in kit:merge-pr kit:gh-write kit:branch-push kit:branch-delete kit:workflow-dispatch kit:coordinator-bootstrap kind:install-file kind:settings-merge kind:ci-rerun-failed; do
    bt "$P" "$W" list "$k" >/dev/null; len=$(wc -c < "$BT_OUT")
    [ "$len" -le 1537 ] && ok "[list] the entry of $k is at most 1536 bytes ($len)" || bad "[list] the entry of $k is at most 1536 bytes ($len)"
    hasnt "$(out)" "…" "[list] …uncut"
    case "$k" in
      kit:branch-delete) has "$(out)" "  Params:  repo=repo branch=ref head=sha40" "[list] …with its Params" ;;
      *) has "$(out)" "  Usage:" "[list] …with its Usage" ;;
    esac
  done
  local deep; deep="$(fresh)"; for n in 1 2 3 4 5 6 7; do deep="$deep/$(printf 'd%.0s' $(seq 1 200))"; done
  mkdir -p "$deep/vibemaestro/batons"; mkb "$P" "$deep/vibemaestro/batons/deep-one.sh" "dest=path" "{dest}/** — the file"
  eq "$(cd "$W" && within 20 env -i PATH="$PATH" HOME="$HOME" XDG_STATE_HOME="$ST" XDG_DATA_HOME="$deep" python3 "$P/scripts/baton.py" list deep-one)" 0 \
    "[list] the one entry of a baton under a 1,400-character path: rc 0, it ends"
  ( cd "$W" && cenv XDG_STATE_HOME="$ST" XDG_DATA_HOME="$deep" python3 "$P/scripts/baton.py" list deep-one ) > "$BT_OUT" 2>&1
  len=$(wc -c < "$BT_OUT")
  [ "$len" -le 1537 ] && ok "[list] …cut at 1,536 bytes ($len)" || bad "[list] …cut at 1,536 bytes ($len)"
  has "$(out)" "/deep-one.sh sha256 $(shaf "$deep/vibemaestro/batons/deep-one.sh")" "[list] …keeping the file name and the sha256"
  eq "$(within 20 python3 -c 'import sys; sys.path.insert(0, sys.argv[1] + "/scripts"); import baton
e = {"prefix": "user", "name": "x", "path": "/x/" + "n" * 1600 + ".sh", "marks": [], "label": "l", "signer": "auto", "runs": 0,
     "sha": "a" * 64, "fields": dict((k, (0, "short")) for k in ("Purpose", "Targets", "Blast", "Undo", "Stops", "Params"))}
sys.exit(0 if len(baton.list_entry(e).encode("utf-8")) <= baton.ENTRY_MAX else 1)' "$P")" 0 \
    "[list] an entry no field or path cut can shorten ends, cut at its byte bound"
  for n in $(seq 1 500); do printf '#!/usr/bin/env bash\n# Purpose: fixture baton number %s, a flow kept to measure the catalogue at scale\n# Stops: none\n# Params: dest=path note=input\n' "$n" > "$L/fx-$n.sh"; done
  t0=$(python3 -c 'import time; print(time.time())')
  bt "$P" "$W" list >/dev/null
  t1=$(python3 -c 'import time; print(time.time())')
  len=$(wc -c < "$BT_OUT"); n=$(wc -l < "$BT_OUT")
  [ "$len" -le 8000 ] && ok "[list] 500 batons more: at most 8,000 bytes ($len)" || bad "[list] 500 batons more: at most 8,000 bytes ($len)"
  python3 -c 'import sys; sys.exit(0 if float(sys.argv[2]) - float(sys.argv[1]) < 1.0 else 1)' "$t0" "$t1" \
    && ok "[list] …in under 1 s" || bad "[list] …in under 1 s ($(python3 -c 'import sys; print(round(float(sys.argv[2]) - float(sys.argv[1]), 3))' "$t0" "$t1") s)"
  eq "$n" 26 "[list] …25 lines and one more"
  has "$(tail -n 1 "$BT_OUT")" "more: add a keyword" "[list] …the last says how many more"
  eq "$(awk 'length > 260' "$BT_OUT" | wc -l | tr -d ' ')" 0 "[list] …no line over 260 characters"
  printf 'list over 500 fixture batons: %s bytes, %s lines, %s s\n' "$len" "$n" "$(python3 -c 'import sys; print(round(float(sys.argv[2]) - float(sys.argv[1]), 3))' "$t0" "$t1")" >> "$TMP/measure.txt"
}

fam_origin() {
  local P=$1 R O; setup "$P"; mkdir -p "$W/o"
  O=$(fresh)/origin.git; git_ init -q --bare -b main "$O"; R=$(fresh); repo "$R"
  mkb "$P" "$R/.vibemaestro/batons/o.sh" "dest=path" "{dest}/** — the file"
  git_ -C "$R" add -A; git_ -C "$R" -c user.name=t -c user.email=t@t commit -qm one; git_ -C "$R" remote add origin "$O"
  git_ -C "$R" push -q origin main 2>/dev/null; git_ -C "$R" fetch -q origin; git_ -C "$R" remote set-head origin main >/dev/null
  git_ -C "$R" remote set-url origin "https://tok3n@example.invalid/o/r.git"
  bt "$P" "$R" list project >/dev/null
  has "$(out)" "not kept on this machine (matches origin https://example.invalid/o/r.git main)" "[origin] matches origin is shown beside the label, never instead of it"
  hasnt "$(out)" "tok3n" "[origin] …the URL without its userinfo"
  eq "$(bt "$P" "$R" go project:o "$(D "$W/o")")" 3 "[origin] a match with origin does not make a baton callable: rc 3"
  echo '# local' >> "$R/.vibemaestro/batons/o.sh"; bt "$P" "$R" list project >/dev/null
  hasnt "$(out)" "matches origin" "[origin] other bytes do not match"
}

# ── Q2b: a project baton whose bytes are the blob on origin's default branch runs without a pin, only for a remote on the owner's
# list (empty by default), checked at every step ───────────────────────────────────────────────────────────────────────────────
commit() { git_ -C "$1" add -A; git_ -C "$1" -c user.name=t -c user.email=t@t commit -qm "${2:-c}"; }
fam_reviewed() {
  local P=$1 R O R3 R5 R6 o seal; setup "$P"; o="$W/o"; mkdir -p "$o"
  O=$(fresh)/origin.git; git_ init -q --bare -b main "$O"; R=$(fresh); repo "$R"
  mkb "$P" "$R/.vibemaestro/batons/o.sh" "dest=path" "{dest}/** — the file"
  mkb "$P" "$R/.vibemaestro/batons/s.sh" "dest=path" "{dest}/** — the file"; sed -i 's/^# Stops: none$/# Stops: publish/' "$R/.vibemaestro/batons/s.sh"
  commit "$R" one; git_ -C "$R" remote add origin "$O"
  git_ -C "$R" push -q origin main 2>/dev/null; git_ -C "$R" fetch -q origin; git_ -C "$R" remote set-head origin main >/dev/null
  git_ -C "$R" remote set-url origin "https://tok3n@Example.invalid/o/r.git/"
  eq "$(bt "$P" "$R" mode remotes)" 0 "[reviewed] mode remotes on a fresh state: rc 0"
  has "$(out)" "(none)" "[reviewed] …the list is empty by default"
  eq "$(bt "$P" "$R" go project:o "$(D "$o")")" 3 "[reviewed] the empty default list: a matching project baton with no pin: rc 3"
  has "$(out)" "example.invalid/o/r is not on the owner's remote list" "[reviewed] …the refusal says why the match does not count"
  eq "$(bt "$P" "$R" mode trust "git@example.invalid:o/other.git")" 0 "[reviewed] mode trust another remote: rc 0"
  eq "$(bt "$P" "$R" go project:o "$(D "$o")")" 3 "[reviewed] a remote not on the list: rc 3"
  eq "$(bt "$P" "$R" mode trust "https://u:p@EXAMPLE.invalid/o/r.git")" 64 "[reviewed] mode trust a remote written with userinfo: rc 64"
  hasnt "$(out)" "u:p" "[reviewed] …the userinfo never printed"
  eq "$(bt "$P" "$R" mode trust "https://EXAMPLE.invalid/o/r.git")" 0 "[reviewed] mode trust the repository's remote: rc 0"
  has "$(out)" "trusted example.invalid/o/r" "[reviewed] …in its canonical form (no scheme or .git, the host lower-cased)"
  eq "$(grep -c "	mode	.*	trust example.invalid/o/r	" "$(bdir)/log.tsv")" 1 "[reviewed] …and logged as a mode event"
  bt "$P" "$R" mode remotes >/dev/null
  eq "$(out)" "$(printf 'example.invalid/o/other\nexample.invalid/o/r')" "[reviewed] mode remotes prints the list, one per line"
  eq "$(bt "$P" "$R" mode)" 0 "[reviewed] mode alone: rc 0"; eq "$(out)" auto "[reviewed] …still prints the mode alone"
  eq "$(bt "$P" "$R" go project:o "$(D "$o")")" 0 "[reviewed] a listed remote and the default branch's bytes: runs without a pin, rc 0"
  has "$(out)" "reviewed on https://Example.invalid/o/r.git/ main" "[reviewed] …go's line labels it reviewed, with the URL and branch"
  hasnt "$(out)" "tok3n" "[reviewed] …the URL without its userinfo"
  bt "$P" "$R" list project >/dev/null
  has "$(out)" "reviewed on https://Example.invalid/o/r.git/ main" "[reviewed] list labels it reviewed"
  hasnt "$(out | grep 'project:o ')" "unpinned" "[reviewed] …and does not mark it unpinned"
  o="$W/o2"; mkdir -p "$o"
  eq "$(bt "$P" "$R" go project:s "$(D "$o")")" 8 "[reviewed] a reviewed stop-list baton still stops for the owner: rc 8"
  # checked at every step: signed while the remote was listed, run after it left the list
  o="$W/o3"; mkdir -p "$o"; bt "$P" "$R" mode manual >/dev/null
  eq "$(sg "$P" "$R" owner project:o "$(D "$o")")" 0 "[reviewed] the owner signs the reviewed baton: rc 0"
  eq "$(bt "$P" "$R" mode untrust example.invalid/o/r)" 0 "[reviewed] mode untrust: rc 0"
  eq "$(bt "$P" "$R" run project:o "$(D "$o")")" 3 "[reviewed] run after the remote left the list: rc 3"
  [ -z "$(ls -A "$o")" ] && ok "[reviewed] …nothing ran" || bad "[reviewed] …nothing ran"
  eq "$(bt "$P" "$R" mode untrust example.invalid/o/r)" 0 "[reviewed] untrust of a remote not listed: rc 0"; has "$(out)" "not on the list" "[reviewed] …says so"
  bt "$P" "$R" mode auto >/dev/null; bt "$P" "$R" mode trust example.invalid/o/r >/dev/null
  # the file changed on the branch, a baton only on another branch, origin/HEAD naming a local branch
  o="$W/o4"; mkdir -p "$o"; echo '# changed on the branch' >> "$R/.vibemaestro/batons/o.sh"
  eq "$(bt "$P" "$R" go project:o "$(D "$o")")" 3 "[reviewed] the file changed after merge: rc 3"
  has "$(out)" "not the blob at .vibemaestro/batons/o.sh on origin main" "[reviewed] …the refusal says the bytes differ from origin"
  git_ -C "$R" checkout -q -- .vibemaestro/batons/o.sh
  git_ -C "$R" checkout -q -b feat; mkb "$P" "$R/.vibemaestro/batons/n.sh" "dest=path" "{dest}/** — the file"; commit "$R" feat
  git_ -C "$R" remote set-url origin "$O"; git_ -C "$R" push -q origin feat 2>/dev/null; git_ -C "$R" fetch -q origin
  git_ -C "$R" remote set-url origin "https://example.invalid/o/r"
  eq "$(bt "$P" "$R" go project:n "$(D "$o")")" 3 "[reviewed] a baton only on a non-default branch (pushed there): rc 3"
  eq "$(bt "$P" "$R" go project:o "$(D "$o")")" 0 "[reviewed] …while the default branch's baton runs on that branch: rc 0"
  git_ -C "$R" symbolic-ref refs/remotes/origin/HEAD refs/heads/feat
  eq "$(bt "$P" "$R" go project:n "$(D "$o")")" 3 "[reviewed] origin/HEAD naming a local branch: rc 3"
  git_ -C "$R" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/feat
  eq "$(bt "$P" "$R" go project:n "$(D "$o")")" 0 "[reviewed] instrument: origin/HEAD naming origin/feat makes it origin's default: rc 0"
  git_ -C "$R" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  # GIT_DIR from the caller does not lead the origin check to another repository
  R3=$(fresh); repo "$R3"; cp "$R/.vibemaestro/batons/o.sh" "$R3/.vibemaestro/batons/o.sh"
  BT_ENV=(GIT_DIR="$R/.git")
  eq "$(bt "$P" "$R3" go project:o "$(D "$o")")" 3 "[reviewed] GIT_DIR pointing at a repository whose origin matches: rc 3"
  BT_ENV=()
  # review round 1: a nested baton through GIT_DIR, a relative-path origin, the URL git fetches from, a retired sha, a link on
  # origin, a root outside git
  local O2 R4 K4 A4 h
  O2=$(fresh)/o2.git; git_ init -q --bare -b main "$O2"; R4=$(fresh); repo "$R4"; K4=$(pkey "$R4")
  mkb "$P" "$R4/.vibemaestro/batons/o.sh" "dest=path" "{dest}/** — the file"; A4=$(shaf "$R4/.vibemaestro/batons/o.sh")
  mkdir -p "$R4/sub/.vibemaestro/batons"; cp "$R4/.vibemaestro/batons/o.sh" "$R4/sub/.vibemaestro/batons/o.sh"
  echo '# nested' >> "$R4/sub/.vibemaestro/batons/o.sh"
  h=$(git_ -C "$R4" hash-object -w .vibemaestro/batons/o.sh)
  git_ -C "$R4" add -A; git_ -C "$R4" update-index --add --cacheinfo "120000,$h,.vibemaestro/batons/l.sh"
  git_ -C "$R4" -c user.name=t -c user.email=t@t commit -qm one; cp "$R4/.vibemaestro/batons/o.sh" "$R4/.vibemaestro/batons/l.sh"
  git_ -C "$R4" remote add origin "$O2"; git_ -C "$R4" push -q origin main 2>/dev/null; git_ -C "$R4" fetch -q origin
  git_ -C "$R4" remote set-head origin main >/dev/null; git_ -C "$R4" remote set-url origin "https://example.invalid/o/r"
  eq "$(bt "$P" "$R4" go project:o "$(D "$(fresh)")")" 0 "[reviewed] instrument: the second repository's baton runs as reviewed"
  BT_ENV=(GIT_DIR="$R4/.git")
  eq "$(bt "$P" "$R4/sub" go project:o "$(D "$(fresh)")")" 3 "[reviewed] GIT_DIR from a subdirectory: a nested baton on origin is not the reviewed path: rc 3"
  mkdir -p "$R4/sub2/.vibemaestro/batons"; cp "$R4/.vibemaestro/batons/o.sh" "$R4/sub2/.vibemaestro/batons/o.sh"
  eq "$(bt "$P" "$R4/sub2" go project:o "$(D "$(fresh)")")" 3 "[reviewed] GIT_DIR from a subdirectory holding an identical copy: rc 3"
  has "$(out)" "is not the top of its repository" "[reviewed] …the refusal names the condition"
  BT_ENV=()
  eq "$(bt "$P" "$R4" go project:l "$(D "$(fresh)")")" 3 "[reviewed] a symlink on origin holding the bytes: rc 3"
  git_ clone -q --bare "$O2" "$R4/example.invalid/o/r"; git_ -C "$R4" remote set-url origin example.invalid/o/r
  git_ -C "$R4" fetch -q origin
  eq "$(bt "$P" "$R4" go project:o "$(D "$(fresh)")")" 3 "[reviewed] a relative-path origin spelled like a listed remote: rc 3"
  git_ -C "$R4" remote set-url origin "$O2"; git_ -C "$R4" config --add remote.origin.url "https://example.invalid/o/r"
  eq "$(bt "$P" "$R4" go project:o "$(D "$(fresh)")")" 3 "[reviewed] a listed URL after the URL git fetches from: rc 3"
  git_ -C "$R4" config --unset-all remote.origin.url; git_ -C "$R4" config remote.origin.url "https://example.invalid/o/r"
  git_ -C "$R4" config "url.$O2.insteadOf" "https://example.invalid/o/r"
  eq "$(bt "$P" "$R4" go project:o "$(D "$(fresh)")")" 3 "[reviewed] a listed URL that insteadOf sends to another repository: rc 3"
  git_ -C "$R4" config --unset "url.$O2.insteadOf"
  eq "$(bt "$P" "$R4" go project:o "$(D "$(fresh)")")" 0 "[reviewed] instrument: …the listed URL alone runs again: rc 0"
  rec "$K4" o 000001 keep "$A4"; rec "$K4" o 000002 retire "$A4"
  eq "$(bt "$P" "$R4" go project:o "$(D "$(fresh)")")" 3 "[reviewed] a retired sha stays refused though it is reviewed: rc 3"
  has "$(out)" "these bytes were retired" "[reviewed] …the refusal says it was retired"
  bt "$P" "$R4" check project:o >/dev/null
  has "$(out)" "it cannot be called" "[reviewed] …check of the retired sha says it cannot be called"
  has "$(out)" "retired" "[reviewed] …and that it was retired"
  bt "$P" "$R4" list project >/dev/null
  hasnt "$(out | grep 'project:o ')" "reviewed on" "[reviewed] …and list does not label it reviewed"
  # review round 3: a top-level path ending in a space is the top; a URL ending in /.git is no network remote; untrust gets no hint
  R6="$(fresh)/xsp ace "; git_ clone -q "$O2" "$R6"; git_ -C "$R6" remote set-url origin "https://example.invalid/o/r"
  eq "$(bt "$P" "$R6" go project:o "$(D "$(fresh)")")" 0 "[reviewed] a repository whose path ends in a space runs as reviewed: rc 0"
  git_ -C "$R6" remote set-url origin "https://example.invalid/o/r/.git"
  eq "$(bt "$P" "$R6" go project:o "$(D "$(fresh)")")" 3 "[reviewed] an origin URL ending in /.git: rc 3"
  has "$(out)" "is not a network remote" "[reviewed] …the refusal says it is no network remote"
  BT_ENV=(GIT_DIR="$R4/.git"); bt "$P" "$R4/sub2" list project >/dev/null; BT_ENV=()
  hasnt "$(out | grep 'project:o ')" "matches origin" "[reviewed] list of a nested copy under GIT_DIR shows no matches-origin note"
  eq "$(bt "$P" "$R4" mode untrust https://example.invalid/o/r/.git)" 64 "[reviewed] mode untrust a URL ending in /.git: rc 64"
  hasnt "$(out)" "set origin to the plain URL" "[reviewed] …with no hint about setting origin"
  R5=$(fresh); mkdir -p "$R5/.vibemaestro/batons"; cp "$R4/.vibemaestro/batons/o.sh" "$R5/.vibemaestro/batons/o.sh"
  eq "$(bt "$P" "$R5" go project:o "$(D "$(fresh)")")" 3 "[reviewed] a project root outside git: rc 3"
  has "$(out)" "the project root is not in git" "[reviewed] …the refusal names the condition"
  # user: is never reviewed
  mkdir -p "$XD/vibemaestro/batons"; cp "$R/.vibemaestro/batons/o.sh" "$XD/vibemaestro/batons/o.sh"
  eq "$(bt "$P" "$R" go user:o "$(D "$o")")" 3 "[reviewed] a user: baton with the same bytes: rc 3"
  # the list's refusals
  eq "$(bt "$P" "$R" mode trust /srv/git/r.git)" 64 "[reviewed] mode trust a local path: rc 64"
  eq "$(bt "$P" "$R" mode trust file:///srv/git/r.git)" 64 "[reviewed] mode trust a file: URL: rc 64"
  eq "$(bt "$P" "$R" mode trust)" 64 "[reviewed] mode trust with no remote: rc 64"
  eq "$(bt "$P" "$R" mode trust 'example.invalid/o/r x')" 64 "[reviewed] mode trust a word with a space: rc 64"
  eq "$(bt "$P" "$R" mode trust $'example.invalid/o/r\nowner: x')" 64 "[reviewed] mode trust a word with a newline: rc 64"
  eq "$(bt "$P" "$R" mode trust example.invalid)" 64 "[reviewed] mode trust a host with no path: rc 64"
  eq "$(bt "$P" "$R" mode trust https://example.invalid/o/r/.git)" 64 "[reviewed] mode trust a URL ending in /.git: rc 64"
  has "$(out)" "a URL ending in /.git is never on the list" "[reviewed] …the refusal says why"
  eq "$(bt "$P" "$R" mode remotes x)" 64 "[reviewed] mode remotes with an argument: rc 64"
  bt "$P" "$R" mode remotes >/dev/null
  eq "$(out)" "$(printf 'example.invalid/o/other\nexample.invalid/o/r')" "[reviewed] …none of them changed the list"
}

# ── the owner's signature on a kept baton (the guard binds the resolved file) and values that need quoting ──────────────────
fam_owner() {
  local P=$1 R K A cmd rc; setup "$P"; mkdir -p "$W/o"
  pyfam "$P" owner owner
  R=$(fresh); repo "$R"; K=$(pkey "$R")
  mkb "$P" "$R/.vibemaestro/batons/s.sh" "dest=path n=name" "{dest}/** — the file"; A=$(shaf "$R/.vibemaestro/batons/s.sh")
  bt "$P" "$W" mode manual >/dev/null
  eq "$(guard_cmd "$P" "$R" "$ST" "$OWNER_SID" "python3 $P/scripts/baton.py sign --by owner --seal 0123456789abcdef.0123456789abcdef project:s dest=$W/o n=x")" deny \
    "[owner] the guard denies a kept name that is not pinned"
  rec "$K" s 000001 keep "$A"
  eq "$(bt "$P" "$R" go project:s "$(D "$W/o")" n=plain)" 8 "[owner] mode manual: go stops with the card, rc 8"
  has "$(out)" "  Kept:     project:s is $R/.vibemaestro/batons/s.sh, sha256 $A; $LABEL" "[owner] the card shows the resolved file, its sha256 and the label"
  has "$(out)" "  Root:     $R; origin (none)" "[owner] …and the project root and origin"
  cmd=$(sed -n "s/^on the owner's go: //p" "$BT_OUT")
  has "$cmd" " sign --by owner --seal " "[owner] the owner's command names the kept baton"
  eq "$(guard_cmd "$P" "$R" "$ST" "$OWNER_SID" "$cmd")" ask "[owner] the guard asks for project:<name>"
  has "$(cat "$(bdir)"/asked/*.json)" "\"script_sha256\": \"$A\"" "[owner] …its record binds the pinned file's sha256"
  rc=$( ( cd "$R" && eval "cenv XDG_STATE_HOME='$ST' XDG_DATA_HOME='$XD' CLAUDE_CODE_SESSION_ID='$OWNER_SID' ${cmd}" ) > "$BT_OUT" 2>&1; echo $?)
  eq "$rc" 0 "[owner] the owner signs a kept baton: rc 0"
  rec "$K" s 000002 retire "$A"
  eq "$(bt "$P" "$R" run project:s "$(D "$W/o")" n=plain)" 3 "[owner] the pin moved after the owner signed: run rc 3"
  rec "$K" s 000003 keep "$A"
  eq "$(bt "$P" "$R" go project:s "$(D "$W/o")" n=plain)" 8 "[owner] again: the card, rc 8"
  cmd=$(sed -n "s/^on the owner's go: //p" "$BT_OUT"); guard_cmd "$P" "$R" "$ST" "$OWNER_SID" "$cmd" >/dev/null
  rc=$( ( cd "$R" && eval "cenv XDG_STATE_HOME='$ST' XDG_DATA_HOME='$XD' CLAUDE_CODE_SESSION_ID='$OWNER_SID' ${cmd}" ) > "$BT_OUT" 2>&1; echo $?)
  eq "$rc" 0 "[owner] the owner signs again: rc 0"
  echo '# edited after the owner signed' >> "$R/.vibemaestro/batons/s.sh"; rec "$K" s 000004 keep "$(shaf "$R/.vibemaestro/batons/s.sh")"
  eq "$(bt "$P" "$R" run project:s "$(D "$W/o")" n=plain)" 3 "[owner] the file edited (and kept) after the owner signed: run rc 3"
  [ ! -e "$W/o/x" ] && ok "[owner] …nothing ran" || bad "[owner] …nothing ran"
  eq "$(bt "$P" "$R" run project:s "$(D "$W/o")" n=plain)" 3 "[owner] …and the signature is not used by a later call either"
  mkb "$P" "$W/q.sh" "dest=path n=name" "{dest}/** — the file"
  r=$(cenv XDG_STATE_HOME="$ST" python3 -c 'import sys; sys.path.insert(0, sys.argv[1] + "/scripts"); import baton
s = baton.Script(sys.argv[2], pin=False)
w = baton.needs_quoting(s, ["dest=/srv/x", "n=two words"])
print("%s | %s | %s" % (w, baton.quoting_note(w) if w else "-", baton.needs_quoting(s, ["dest=/srv/x", "n=plain"])))' "$P" "$W/q.sh")
  has "$r" "n=two words |" "[owner] a value that needs quoting gets no owner command (no word type needs one today)"
  has "$r" "pass that text through an input file" "[owner] …the note points to an input file"
  has "$r" "| None" "[owner] …a plain value needs none"
}

FAMILIES="fam_grammar fam_values fam_call fam_delivery fam_copies fam_secret fam_binding fam_display fam_places fam_pin fam_worktrees fam_targets fam_reader fam_list
fam_origin fam_reviewed fam_owner"

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
BRK reviewed-any-remote fam_reviewed '[reviewed] a remote not on the list: rc 3' '    if canon not in read_remotes():' '    if False:'
BRK reviewed-any-ref fam_reviewed '[reviewed] origin/HEAD naming a local branch: rc 3' '        if not ref or not ref.startswith("refs/remotes/origin/"):' '        if not ref:'
BRK reviewed-git-env fam_reviewed '[reviewed] GIT_DIR pointing at a repository whose origin matches: rc 3' \
  '        r = subprocess.run(["git"] + list(a), cwd=root, capture_output=True, text=True, timeout=10, env=git_env())' \
  '        r = subprocess.run(["git"] + list(a), cwd=root, capture_output=True, text=True, timeout=10)'
BRK reviewed-host-case fam_reviewed '[reviewed] …in its canonical form' '    return host.lower() + "/" + path' '    return host + "/" + path'
BRK reviewed-link fam_reviewed '[reviewed] a symlink on origin holding the bytes: rc 3' '        m = re.match(r"100(?:644|755) blob ([0-9a-f]+)' '        m = re.match(r"[0-9]+ blob ([0-9a-f]+)'
BRK reviewed-relative fam_reviewed '[reviewed] a relative-path origin spelled like a listed remote: rc 3' '    canon = remote_canon(got[0], strict=True)' '    canon = remote_canon(got[0])'
BRK reviewed-config-url fam_reviewed '[reviewed] a listed URL after the URL git fetches from: rc 3' '        url = git("remote", "get-url", "origin") or "(no url)"' '        url = git("config", "--get", "remote.origin.url") or "(no url)"'
BRK reviewed-retired fam_reviewed '[reviewed] a retired sha stays refused though it is reviewed: rc 3' \
  '        if self.kept is not None and not self.kept.pin(self.sha) and pin and (self.kept.retired or not self.kept.reviewed(self.data)):' \
  '        if self.kept is not None and not self.kept.pin(self.sha) and pin and not self.kept.reviewed(self.data):'
BRK reviewed-nested-copy fam_reviewed '[reviewed] GIT_DIR from a subdirectory holding an identical copy: rc 3' '    if got[4] != os.path.realpath(root):' '    if False:'
BRK reviewed-retired-check fam_reviewed '[reviewed] …check of the retired sha says it cannot be called' '    if s.kept is not None and not s.kept.pinned and not s.kept.retired:' '    if s.kept is not None and not s.kept.pinned:'
BRK reviewed-retired-list fam_reviewed '[reviewed] …and list does not label it reviewed' '            if not pinned and not retired and prefix == "project" and e["sha"]:' '            if not pinned and prefix == "project" and e["sha"]:'
BRK reviewed-top-stripped fam_reviewed '[reviewed] a repository whose path ends in a space runs as reviewed: rc 0' '        top = top_of(root)' '        top = git("rev-parse", "--show-toplevel")'
BRK reviewed-nested-note fam_reviewed '[reviewed] list of a nested copy under GIT_DIR shows no matches-origin note' '    if not got or got[2].get(name) != blob_id(data, got[3]) or got[4] != os.path.realpath(root):' '    if not got or got[2].get(name) != blob_id(data, got[3]):'
BRK lead-allowed fam_values '[types] refused: a value starting with +' '    if v[0] in LEAD_REFUSED:' '    if False:'
BRK dotdot-allowed fam_values '[types] refused: path with ..' '        if seg in (".", ".."):' '        if False:'
BRK segment-per-segment fam_values '[types] allowed: path with a -b segment in the middle' '    if segs[-1][0] in "-+@":' '    if any(x[0] in "-+@" for x in segs):'
BRK segment-input-per-segment fam_values '[types] path and input under a -home-… segment: rc 0' '    if segs[-1][0] in "-+@":' '    if any(x[0] in "-+@" for x in segs):'
BRK segment-last-allowed fam_values '[types] a last segment starting with -: rc 64' '    if segs[-1][0] in "-+@":' '    if False:'
BRK format-allowed fam_values '[types] refused: a value with U+202E (Cf)' '        if unicodedata.category(c) in ("Cf", "Zl", "Zp"):' '        if False:'
BRK under-prefix fam_values '[types] refused: under: a sibling with the base as prefix' '        if v != base and not v.startswith(base + "/"):' '        if not v.startswith(base):'
BRK state-path fam_values '[types] a path into the state directory: rc 64' '    if in_state(v):' '    if False:'
BRK total-unbounded fam_values '[types] values over 4096 bytes in total: rc 64' '    if total > VALUES_MAX:' '    if False:'
BRK file-link-followed fam_values '[types] a file value that is a link: rc 64' \
    '        data, st = read_capped(v, FILE_MAX)' '        data, st = read_capped(v, FILE_MAX, nofollow=False)'
BRK secret-key fam_grammar '[grammar] refused: a key naming a token' '        if SECRET_KEY.search(key):' '        if False:'
BRK params-usage fam_grammar '[grammar] Params and Usage together: check rc 1' '    if pl and ul:' '    if False:'
BRK kept-fixed fam_grammar '[grammar] a project: baton with Params: none: check rc 1' '        if not s.params:' '        if False:'
BRK kit-no-usage fam_grammar '[grammar] a kit with neither Usage nor Params: check rc 1' '    elif (s.kit or s.kind is not None) and not pl and not ul:' '    elif False:'
BRK unknown-key fam_call '[call] an unknown key: rc 64' '        elif key not in declared:' '        elif False:'
BRK missing-key fam_call '[call] a key missing: rc 64' '    probs += ["%s: missing" % k for k, _t, _a in s.params if k not in vals]' '    probs += []'
BRK twice-key fam_call '[call] a key given twice: rc 64' '        elif key in vals:' '        elif False:'
BRK argv-words fam_delivery '[delivery] the values reach the script in the declared order' \
    '        argv = list(s.argv if s.argv is not None else args)' '        argv = list(args)'
BRK p-inherited fam_delivery '[delivery] a P_ variable the caller set is not inherited' \
    '        env = {k: v for k, v in env.items() if not k.startswith("P_")}' '        env = dict(env)'
BRK copy-writable fam_delivery '[delivery] …mode 400' '        os.chmod(os.path.join(tmp, base), 0o400)' '        os.chmod(os.path.join(tmp, base), 0o600)' \
    '    if not stat.S_ISREG(st.st_mode) or st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) != 0o400:' '    if not stat.S_ISREG(st.st_mode):'
BRK secret-start fam_secret '[secret] an input that only talks about secrets: rc 0' 'TOKEN_START = rb"(?:(?<![A-Za-z0-9_\-])' 'TOKEN_START = rb"(?:(?<=)|(?<![A-Za-z0-9_\-])'
BRK secret-placeholder fam_secret '[secret] an input that only talks about secrets: rc 0' '                                 if len(set(next((g for g in m.groups() if g), m.group()))) >= 4), None)' '                                 if True), None)'
BRK secret-copied fam_secret '[secret] a private-key as a file value (id_ed25519): rc 64' '                p = secret_problem(files[k][0])' '                p = None'
BRK copies-kept fam_copies '[copies] …and leaves no copy of the file value' '        if not RUN["consumed"]:' '        if False:'
BRK copies-run-dropped fam_copies "[copies] a run's copy stays" '        if not RUN["consumed"]:' '        if True:'
BRK copies-held-removed fam_copies '[copies] …the copy another process holds stays' \
    $'        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)\n        if not os.path.samestat(os.fstat(fd), os.lstat(path)):' \
    $'        if not os.path.samestat(os.fstat(fd), os.lstat(path)):'
BRK copies-held-mismatch fam_copies '[copies] …and leaves the held copy to it' \
    $'            if not remove_if_free(final):\n                raise Stop(REFUSED' $'            if not remove_tree(final):\n                raise Stop(REFUSED'
BRK copies-closed-kept fam_copies '[copies] prune removes a copy directory it cannot open (nobody can hold one)' \
    '        remove_tree(path)                               # a link, a file, a directory of mode 0: never held' '        return False'
BRK copy-unchecked fam_delivery '[delivery] a copy that changed: rc 3' '        why = copy_problem(final, base, sha)' '        why = None'
BRK inputs-unbound fam_binding '[binding] the file changed after signing: run rc 3' \
    '                                  "inputs": inputs}, sort_keys=True, separators=(",", ":")))' '                                  "inputs": {}}, sort_keys=True, separators=(",", ":")))'
BRK card-cut fam_display '[display] the card shows a 200-character value whole' \
    '    lines[-1:-1] = ["  %s" % log_value(ln) for ln in s.param_lines]' '    lines[-1:-1] = ["  %s" % log_value(ln)[:80] for ln in s.param_lines]'
BRK format-shown fam_display '[display] control and format characters of a header are escaped on the card' \
    'unicodedata.category(c) in ("Cf", "Zl", "Zp")
                   else c for c in v)' 'False
                   else c for c in v)'
BRK log-uncut fam_display '[display] log.tsv cuts a value at 120 characters' '            v = [cut(a, CUT) if isinstance(a, str) else a for a in v]' '            v = list(v)'
BRK baton-field fam_display '[display] …the last, baton, is scratch@<sha256> for a path' '        return "scratch@%s" % self.sha' '        return "scratch"'
BRK any-prefix fam_places '[places] lib:x: rc 64' '        if m.group(1) in PLACES:' '        if True:'
BRK bare-name fam_places '[places] a bare name: rc 64' '    if KIT_RE.match(word):
        held = places_holding(word)' '    if False:
        held = places_holding(word)'
BRK loose-root fam_places '[places] a project root its group can write: rc 3' '    if st.st_uid != os.getuid() or st.st_mode & 0o022:' '    if False:'
BRK place-link fam_places '[places] a .vibemaestro/batons that is a link: rc 64' \
    '        if os.path.lexists(self.dir) and os.path.realpath(self.dir) != want:' '        if False:'
BRK kept-link fam_places '[places] a kept baton that is a link: rc 64' \
    '            data, st = read_capped(self.path, KEPT_MAX)' '            data, st = read_capped(self.path, KEPT_MAX, nofollow=False)'
BRK home-root fam_places '[places] a git top level that is HOME is no project root: rc 66' '    if top and top != home:' '    if top:'
BRK walk-home fam_places '[places] the walk outside git stops before HOME: rc 66' '    while d not in ("/", home):' '    while d != "/":'
BRK unpinned-runs fam_pin '[pin] no keep record: rc 3' '        if self.kept is not None and not self.kept.pin(self.sha) and pin and (self.kept.retired or not self.kept.reviewed(self.data)):' '        if False:'
BRK retire-ignored fam_pin '[pin] a retired sha: rc 3' '        by = naming[-1][1] if naming and not retired else None' '        by = naming[-1][1] if naming else None'
BRK user-any-keep fam_pin '[pin] user: a library file written back to an older version: rc 3' \
    '        by = newest[1] if newest and newest[1]["sha256"] == sha and not any(' '        by = newest[1] if newest and not any('
BRK user-retire-falls-back fam_pin '[pin] user: the newest keep retired: rc 3' \
    '            q > newest[0] and is_retire(r) and r["retired"] == sha for q, r in recs) else None' '            False for q, r in recs) else None'
BRK common-dir-key fam_worktrees '[worktrees] the other worktree runs its own version' \
    '        return top, "project-" + sha256(common)[:16], True' '        return top, "project-" + sha256(top)[:16], True'
BRK targets-off fam_targets '[targets] a plan line outside the declared Targets: go rc 1' '    ttable, treasons = targets_table(s, plan)' '    ttable, treasons = [], []'
BRK dotdot-after fam_targets '[targets] a word with a .. segment under a declared /** pattern: rc 1' \
    '            if ".." in re.split(r"[/=:]", w):' '            if False:'
BRK dotdot-relative fam_targets '[targets] a relative word with a .. segment beside a declared target: rc 1' \
    '            if ".." in re.split(r"[/=:]", w):' '            if target_looking(w) and ".." in re.split(r"[/=:]", w):'
BRK dotdot-key fam_targets '[targets] a key=../x word beside a declared target: rc 1' \
    '            if ".." in re.split(r"[/=:]", w):' '            if ".." in w.split("/"):'
BRK exempt-state fam_targets '[targets] a plan line naming the keep records: rc 1' \
    '    exempt = tuple(os.path.join(b, sub) + "/" for b in st for sub in ("inputs", "records"))' '    exempt = tuple(b + "/" for b in st)'
BRK targets-unparsed fam_targets "[targets] a kept baton whose Targets are 'the file named by dest': check rc 1" \
    '                      for p in target_patterns(s)[1]]' '                      for p in []]'
BRK positional-ok fam_reader '[reader] refused: a top-level "$1"' \
    '            if ((name.isdigit() and name != "0") or name in ("@", "*")) and form != "bare" and k not in in_fn and k not in block:' '            if False:'
BRK unquoted-ok fam_reader '[reader] refused: $P_N unquoted' '            elif ctx == "c":
                bad(n, "$%s is unquoted' '            elif False:
                bad(n, "$%s is unquoted'
BRK eval-ok fam_reader '[reader] refused: P_N in eval' '        if word in ("eval", "trap") or' '        if word in () or'
BRK heredoc-ok fam_reader '[reader] refused: P_N in a quoted here-document' '    for ln, lines, _closed in bodies:' '    for ln, lines, _closed in []:'
BRK heredoc-letters fam_reader '[reader] refused: P_N in a <<1 here-document' \
    '    return (k, "".join(out), tabs) if k > begin else None' '    return (k, "".join(out), tabs) if k > begin and line[begin].isalpha() else None'
BRK heredoc-quotes-kept fam_reader '[reader] allowed: here-documents with quoted, backslashed and numeric delimiters' \
    '            out.append(body)' '            out.append(line[k:e + 1])'
BRK inner-heredoc fam_reader '[reader] refused: code after a << inside' \
    '            elif line.startswith("${", j) or line.startswith("$[", j):' '            elif False:'
BRK unclosed-ok fam_reader '[reader] refused: a here-document that no line closes' \
    '              for ln, _lines, closed in heredoc_bodies if closed is False]' '              for ln, _lines, closed in heredoc_bodies if False]'
BRK undecided-ok fam_reader '[reader] refused: a here-document delimiter after a line continuation' \
    'for ln, _lines, closed in heredoc_bodies if closed is None]' 'for ln, _lines, closed in heredoc_bodies if False]'
# a segment derived from a value: basename, a carrier's trim, the ./ and -- ways out, and the dependency on LEAD_REFUSED
BRK segment-basename-blind fam_reader '[reader] refused: basename of the dirname of a value' \
  '        if word != "basename":' '        if True:'
BRK segment-copy-blind fam_reader '[reader] refused: basename of a copy of a copy' \
  '            reads_any(outer, held) or any(' '            False or any('
BRK segment-any-output fam_reader '[reader] allowed: the output of a command that reads a value, cut' \
  'SEGMENT_CMD.search(x) and reads_any(x, held) for x in inner' 'reads_any(x, held) for x in inner'
BRK segment-wrapper-blind fam_reader '[reader] refused: a command -p dirname copy cut with ##*/' 'SEGMENT_CMD.search(x) and' 'SEGMENT_CMD.match(x) and'
BRK segment-operands-ok fam_reader '[reader] refused: basename with three operands' '    return operands > 2' '    return False'
BRK segment-abbrev-ok fam_reader '[reader] refused: ./ before basename --mul (an abbreviation of --multiple)' \
  '            if w not in ("-z", "--zero"):' '            if w in ("-a", "-s", "--multiple", "--suffix") or w.startswith("--suffix="):'
BRK segment-printf-blind fam_reader '[reader] refused: a printf -v copy cut with ##*/' \
  'r"(?:^|[;&|(\s])printf\s+-v' 'r"(?!)printf\s+-v'
BRK segment-assign-dashdash fam_reader "[reader] refused: local -- x=\$(basename …): local's own --" \
  '    if assign:                                          # `local -- x=$(…)`' '    if False:                                           # `local -- x=$(…)`'
BRK segment-multiple-ok fam_reader '[reader] refused: ./ before basename -a (two words)' \
  '        if s is None or basename_many(text, masked[s:s + len(text)]) or not basename_exempt(code, masked, s):' \
  '        if s is None or not basename_exempt(code, masked, s):'
BRK segment-nested-blind fam_reader '[reader] refused: basename of the dirname of a value' \
  '        text = code[s:subst_end(masked, s)] if s is not None else code[i:end]' '        text = code[i:end]'
BRK segment-trim-blind fam_reader '[reader] refused: a copy trimmed with ##*/' \
  '            if code.startswith("}", e) or SEGMENT_SAFE_OPS.match(code, e):' '            if True:'
BRK segment-prefix-ok fam_reader '[reader] refused: a copy trimmed with ##*/' 'SEGMENT_SAFE_OPS = re.compile(r":?[-=?+]|%")' 'SEGMENT_SAFE_OPS = re.compile(r":?[-=?+]|%|#")'
BRK segment-dot-anywhere fam_reader '[reader] refused: basename of a value in backticks' \
  '    if word.startswith("./"):' '    if True:'
BRK segment-own-dashdash fam_reader "[reader] refused: basename of a value after a -- that is basename's own" \
  '    return "--" in masked[c:j].split()' '    return "--" in masked[c:].split()'
BRK segment-array-blind fam_reader '[reader] refused: an array copy cut with ##*/' \
  '        elif code[k] == "(":' '        elif False:'
BRK segment-for-blind fam_reader '[reader] refused: a for variable over a value cut with ##*/' \
  '[;&|(\s])for\s+' '[;&|(\s])(?!)for\s+'
BRK segment-quote-blind-cut fam_reader '[reader] refused: printf -v with a quoted | in the format, cut' \
  '            stop = re.compile(r"[;&|\n]").search(masked, m.end())' '            stop = re.compile(r"[;&|\n]").search(code, m.end())'
BRK segment-redirect-operand fam_reader '[reader] allowed: ./ before basename with 2>&1, || true, | head and 2> /dev/null' \
  '    for m in reversed(list(re.finditer(' '    for m in [] and reversed(list(re.finditer('
BRK segment-pipe-operand fam_reader '[reader] allowed: ./ before basename with 2>&1, || true, | head and 2> /dev/null' \
  '    stop = re.search(r"[;|]|(?<![<>])&(?!>)", minner)' '    stop = None'
BRK lead-dash-allowed fam_values '[types] refused: a repo value starting with -' \
  '    if v[0] in LEAD_REFUSED:' '    if v[0] in LEAD_REFUSED.replace("-", ""):'
BRK heredoc-tabs fam_reader '[reader] allowed: a <<"E-F" and a <<-EOF here-document, then code' \
    '(lines[n].lstrip("\t") if tabs else lines[n]) != word' 'lines[n] != word'
BRK heredoc-ansi fam_reader "[reader] allowed: a <<\$'E\\eF' here-document, then code" '                body = ansi_c(body)' '                body = body'
BRK heredoc-group fam_reader '[reader] allowed: a <<$(x y) here-document, then code' \
    '        elif c == "`" or (c == "$" and line[k + 1:k + 2] in ("(", "{")):' '        elif False:'
BRK heredoc-pid fam_reader '[reader] refused: P_N in a here-document after $${' '            elif line.startswith("$$", j):' '            elif False:'
BRK heredoc-subst fam_reader '[reader] refused: P_N in a here-document inside $( ) inside ${…}' \
    '                ctx.append([top, "arith" if width == 3 else "subst", top[1], 0])' '                ctx.append([top, "arith", top[1], 0])'
BRK comment-in-brace fam_reader '[reader] refused: P_N in a here-document after a # inside ${…}' \
    'and not (cur and cur[1] in ("brace", "bracket", "arith")):' ':'
BRK nul-ok fam_reader '[reader] refused: a NUL byte that would hide a << from the checks' '    if b"\0" in s.data:' '    if False:'
BRK subscript-heredoc fam_reader '[reader] refused: code after an assignment subscript' \
    '            elif ch == "[" and assignment_subscript(line, j):' '            elif False:'
BRK list-path-keep fam_list '[list] …keeping the file name and the sha256' \
    '    if over > 0 and len(path) > len(base) + 40:' '    if False:'
BRK remove-link fam_delivery '[delivery] a set-aside entry that is a link is removed' \
    '        if os.path.islink(path) or not os.path.isdir(path):' '        if not os.path.exists(path):'
BRK entry-loop fam_list '[list] an entry no field or path cut can shorten ends' \
    '        if len(vals[k]) <= 20:
            break' '        if False:
            break'
BRK prune-aside fam_delivery '[delivery] the newest 20 set-aside copies are kept' \
    '    for pattern, keep in ((r"[0-9a-f]{64}\.", INPUTS_KEPT), (r"\.mismatch-", 20)):' '    for pattern, keep in ((r"[0-9a-f]{64}\.", INPUTS_KEPT),):'
BRK herestring-heredoc fam_reader '[reader] allowed: a here-string of a word value' '            elif line.startswith("<<<", j):' '            elif False:'
BRK heredoc-in-arith fam_reader '[reader] allowed: << as a shift' \
    '            elif line.startswith("<<", j) and not (cur and cur[1] != "subst"):' '            elif line.startswith("<<", j):'
BRK data-opt-ok fam_reader '[reader] refused: P_N as the value of gh -F' '            if opt and any(' '            if False and any('
BRK block-ok fam_reader '[reader] refused: no values block' \
    '        if first is None or run[-1] >= len(entries) or any(k in in_fn or not want[j].match(entries[k][1]) for j, k in enumerate(run)):' '        if False:'
BRK reassign-ok fam_reader '[reader] refused: a P_ name assigned again' \
    '            if form == "bare" and name.startswith("P_") and (code[b:b + 1] in ("=", "[") or code[b:b + 2] == "+=") and k not in block:' '            if False:'
BRK list-unbounded fam_list '[list] 500 batons more: at most 8,000 bytes' 'LIST_LINES, LIST_WIDTH, ENTRY_MAX, CUT = 25, 260, 1536, 120' 'LIST_LINES, LIST_WIDTH, ENTRY_MAX, CUT = 2500, 2600, 1536, 120'
BRK list-runs fam_list '[list] runs: the ok runs of these bytes under this name' \
    '                if len(v) == len(LOG_FIELDS) and v[1] == "run" and v[9] == "ok":' '                if False:'
BRK list-unpinned-label fam_list '[list] a file never kept: unpinned' \
    '            e["label"] = kept_label(by) if pinned else "not kept on this machine"' '            e["label"] = kept_label(by or {})'
BRK list-copy fam_list '[list] marks: unpinned, kit exists, copy of' '                by_sha.setdefault(e["sha"], []).append(e)' '                pass'
BRK list-raw fam_list '[list] the label, then the Purpose, escaped' \
    'cut(esc(f.get("Purpose", (0, "(no Purpose)"))[1]), 80)' 'cut(f.get("Purpose", (0, "(no Purpose)"))[1], 80)' \
    '        say("%s", list_line(e))' '        say(list_line(e))'
BRK origin-userinfo fam_origin '[origin] …the URL without its userinfo' '    return re.sub(r"^(?:([A-Za-z][A-Za-z0-9+.-]*://)[^/@]*@|[^/@:]+@(?=[^/:]+:))", lambda m: m.group(1) or "", url)' '    return url'
BRK owner-no-kept fam_owner '[owner] accepted: project:<name>' \
    're.fullmatch(r"(?:kit|kind|project|user):[a-z0-9][a-z0-9-]*", rest[5])' 're.fullmatch(r"(?:kit|kind):[a-z0-9][a-z0-9-]*", rest[5])'
BRK owner-record-unbound fam_owner '[owner] …its record binds the pinned file' '        rec["script_path"], rec["script_sha256"] = kept' '        pass'
BRK owner-quoted fam_owner '[owner] a value that needs quoting gets no owner command' \
    '    return next((a for a in args if not (re.match(r"[\x20-\x7e]+\Z", a) and SAFE_WORD.match(a))), None)' '    return None'
BRK owner-pin-unchecked fam_owner '[owner] the pin moved after the owner signed: run rc 3' \
    '        if self.kept is not None and not self.kept.pin(self.sha) and pin and (self.kept.retired or not self.kept.reviewed(self.data)):' '        if False:'

if [ -s "$TMP/measure.txt" ]; then echo "== measurements =="; cat "$TMP/measure.txt"; fi

echo "== nothing written outside the scratch tree =="
eq "$(tree_hash "$SRC_ROOT")" "$H0" "the repository tree is unchanged by the suite"
[ ! -e "$HOME/.local/state/vibemaestro" ] && ok "the scratch HOME holds no baton state (every family set XDG_STATE_HOME)" \
  || bad "the scratch HOME holds no baton state (every family set XDG_STATE_HOME)"

echo; summary
