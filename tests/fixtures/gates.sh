# shellcheck shell=bash
# =============================================================================
# Helpers of the test-gates*.sh suites (sourced AFTER lib.sh and ports.sh; defines functions only)
# =============================================================================
# The gates (plugins/vibemaestro-sdlc/gates) are tested the way the core suites test the cores: every suite is a list of FAMILY
# functions `fam_xxx <plugin dir>` that run the gate of the copy they are given, then one family runs on a copy with ONE planted
# break (BRK) and must go red on the check it is about. Real git on throw-away repositories, a fake `gh`, the network shims of
# netguard.sh, no `sleep`. Assertions read exit codes, JSON fields, files, refs and masked tokens; prose is never asserted.
# Fixture names are synthetic (acme, example).
# =============================================================================

# G <git args> — git with a fixed identity and no signing (lib.sh git_ already does; kept as the short name the families use)
G() { git_ "$@"; }

# mk_repo <name> — a repo with one commit `seed` on `main`; prints its path and NOTHING else (callers capture it with $(...)).
# The directory is made by mktemp -d, so two calls never share one: a name built from $RANDOM could repeat, `git init` would then re-init
# the old repository, `commit` would have nothing to commit and its status text (stdout even with -q) would become part of the "path".
mk_repo() {
  local d; d=$(mktemp -d "$TMP/r-$1.XXXXXX") || return 1
  { G init -q -b main "$d" && echo seed > "$d/seed.txt" && G -C "$d" add seed.txt && G -C "$d" commit -qm seed; } >/dev/null || return 1
  echo "$d"
}
# cm <repo> <file> <subject> — append a line to the file and commit exactly that file. A repo argument that is not an existing directory
# fails before anything is created (a relative one would make the directory in the current tree).
cm() {
  [ -d "$1" ] || { echo "cm: '$1' is not a directory" >&2; return 1; }
  mkdir -p "$(dirname "$1/$2")"
  echo "$3 $RANDOM" >> "$1/$2"   # the number is file content only: it makes the commits differ
  G -C "$1" add "$2"; G -C "$1" commit -qm "$3"
}
# mk_origin <name> — a bare origin and a clone on main with a seed commit; prints the clone path
mk_origin() {
  local d; d=$(mktemp -d "$TMP/o-$1.XXXXXX") || return 1
  { G init -q --bare -b main "$d/origin.git" && G clone -q "$d/origin.git" "$d/w" 2>/dev/null
    echo seed > "$d/w/seed.txt" && G -C "$d/w" add -A && G -C "$d/w" commit -qm seed &&
    G -C "$d/w" branch -M main && G -C "$d/w" push -q -u origin main; } >/dev/null || return 1
  echo "$d/w"
}
# put_cfg <repo> <json> — write .vibemaestro/sdlc.json (not committed)
put_cfg() { mkdir -p "$1/.vibemaestro"; printf '%s' "$2" > "$1/.vibemaestro/sdlc.json"; }
# commit_cfg <repo> <json> <message> — write and commit the config
commit_cfg() {  # the repo must already exist: a relative or polluted argument must not make a directory in the current tree
  [ -d "$1" ] || { echo "commit_cfg: '$1' is not a directory" >&2; return 1; }
  put_cfg "$1" "$2"; G -C "$1" add .vibemaestro/sdlc.json; G -C "$1" commit -qm "$3"
}

# run_gate <command...> — run in a minimal environment; OUT and RC. Stderr is part of OUT.
run_gate() {
  RC=0; OUT=$(cenv "$@" 2>&1) || RC=$?
}
want() {  # want <rc> <label> [text the output must carry]
  if [ "$RC" -eq "$1" ]; then
    if [ -n "${3:-}" ] && ! has_q "$3"; then bad "$2: rc ok but the output lacks «$3»: ${OUT:0:300}"; else ok "$2 (rc $RC)"; fi
  else bad "$2: rc $RC, wanted $1: ${OUT:0:300}"; fi
}
has_q() { printf '%s' "$OUT" | grep -qF -- "$1"; }
# jfield <python expression on d> — print a JSON field of $OUT
jfield() { printf '%s' "$OUT" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(eval(sys.argv[1]), ensure_ascii=False))' "$1"; }

# BRKG <label> <family> <needle> <file under gates/> <old> <new> — one planted break of a gate script (copy of the plugin)
BRKG() {
  local d="$TMP/break-$1"; mk_plugin_copy "$d"
  mutate "$d/gates/$4" "$5" "$6" && expect_red "$1" "$2" "$d" "$3"
}

# install_gate_gh <dir> — a `gh` shim in <dir> that runs tests/fixtures/gate_gh.py; prints <dir>. Run the gate with
# `cenv PATH=<dir>:$PATH FAKE_GH_LOG=<log> FAKE_GH_FX=<fixture.json> ...`.
install_gate_gh() {
  mkdir -p "$1"
  printf '#!/bin/sh\nexec python3 "%s/fixtures/gate_gh.py" "$@"\n' "$HERE" > "$1/gh"; chmod +x "$1/gh"
  echo "$1"
}

# BRKS <label> <family> <needle> <file under scripts/> <old> <new> — the same for a script of the plugin (install_gates.py)
BRKS() {
  local d="$TMP/break-$1"; mk_plugin_copy "$d"
  mutate "$d/scripts/$4" "$5" "$6" && expect_red "$1" "$2" "$d" "$3"
}
