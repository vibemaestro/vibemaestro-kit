#!/bin/bash
# =============================================================================
# BatonRun permissions after a plugin update: the session's vibemaestro-sdlc and the registry's, and a launcher copy that cannot
# run the installed sdlc
# =============================================================================
# Run: bash tests/test-baton-launcher-registry.sh
#
# A session keeps the plugin it started with; `claude plugin update` moves the registry (installed_plugins.json) to a new cache
# directory. Every family builds that world in a scratch HOME: the installed copies are copies of the plugin under
# <claude dir>/plugins/cache/vibemaestro/vibemaestro-sdlc/<version>, the registry a fake with one vibemaestro-sdlc entry per
# copy. Four families:
#   fam_registry     two cache versions, the registry's entry moved to the newer one (the session's older directory stays in the
#                    cache, unlisted): permissions --check,
#                    the SessionStart line, --print and --install-launcher from the session's copy, and the bootstrap gate's
#                    in-process call;
#   fam_unchanged    no registry entry for the running copy (a copy outside the cache: a pod or a clone; no registry; no entry;
#                    the registry's latest entry without baton.py), or the running copy still listed by an older entry (a
#                    restart would load it again), or a launcher every version refuses: today's behaviour;
#   fam_unresolvable a launcher copy whose install-directory rule knows only X.Y.Z, against a SHA-named install: the check names
#                    it first, and following the printed fix leaves a working launcher;
#   fam_setup        `baton help setup` states when an upgrade needs --install-launcher.
# The suite runs them on a copy of the real plugin, then each planted break on its own copy (expect_red). HOME, XDG_STATE_HOME
# and CLAUDE_PROJECT_DIR are scratch directories; nothing outside the scratch tree is written, which the last section checks.
# Assertions read exit codes, finding kinds, files and the commands a line names.
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
export PYTHONDONTWRITEBYTECODE=1
H0=$(tree_hash "$SRC_ROOT")
PB_OUT="$TMP/pb.out"; PB_ERR="$TMP/pb.err"
H=""; ST=""; PJ=""; L=""; C=""; V=""
OLD=4dc7de6c9e01; NEW=3dd2665ed242-be49dd83

# fresh_env — a new scratch HOME (with an empty ~/.claude/plugins), state directory and project for one family run
fresh_env() {
  H="$(fresh)/home"; ST="$(fresh)/state"; PJ="$(fresh)/proj"
  mkdir -p "$H/.claude/plugins" "$PJ"; L="$ST/vibemaestro/baton/bin/baton"
  C="$H/.claude/plugins"; V="$C/cache/vibemaestro/vibemaestro-sdlc"
}
# pb <plugin> <baton args...> — rc of baton.py run from the project; stdout in $PB_OUT, stderr in $PB_ERR
pb() {
  local p=$1; shift
  ( cd "$PJ" && cenv HOME="$H" XDG_STATE_HOME="$ST" CLAUDE_PROJECT_DIR="$PJ" python3 "$p/scripts/baton.py" "$@" ) >"$PB_OUT" 2>"$PB_ERR"
  echo $?
}
# both — stdout and stderr of the last pb
both() { cat "$PB_OUT" "$PB_ERR"; }
# kinds — the sorted unique finding kinds of the last `permissions --check` output
kinds() { awk '$1 ~ /^(MISSING|STALE|UNSAFE|UNREADABLE)$/ {print $1}' "$PB_OUT" | sort -u | tr '\n' ' ' | sed 's/ $//'; }
# first_finding — the first finding line of the last `permissions --check` output
first_finding() { awk '$1 ~ /^(MISSING|STALE|UNSAFE|UNREADABLE)$/ {print; exit}' "$PB_OUT"; }
# inst <version> [<from plugin>] — an installed copy of the plugin at $V/<version>; its launcher carries a mark line, so two
# versions' launchers differ in bytes as two real versions' may
inst() {
  mkdir -p "$V"; cp -r "${2:-$PLUGIN}" "$V/$1"; find "$V/$1" -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null
  printf '# version %s\n' "$1" >> "$V/$1/scripts/baton-launcher.py"
}
# reg <path>... — installed_plugins.json of the scratch HOME, one vibemaestro-sdlc entry per path, each updated after the one
# before (lastUpdated rises with the position); no path: no vibemaestro-sdlc entry
reg() {
  python3 - "$C/installed_plugins.json" "$@" <<'PY'
import json, sys
ents = [{"scope": "user", "installPath": p, "lastUpdated": "2026-10-24T03:%02d:00.000Z" % i} for i, p in enumerate(sys.argv[2:])]
json.dump({"version": 2, "plugins": {"vibemaestro-sdlc@vibemaestro": ents} if ents else {}}, open(sys.argv[1], "w"))
PY
}
# lr — rc of the installed launcher run with --help; stdout in $PB_OUT, stderr in $PB_ERR
lr() { ( cd "$PJ" && cenv HOME="$H" XDG_STATE_HOME="$ST" "$L" --help ) >"$PB_OUT" 2>"$PB_ERR"; echo $?; }
# rules <plugin> — the printed rules of that copy as the user settings (the launcher is not touched)
rules() { pb "$1" permissions --print >/dev/null; cp "$PB_OUT" "$H/.claude/settings.json"; }
# ss <plugin> — the SessionStart hook's JSON, run as Claude Code runs it, from the project with a new session id
ss() {
  ( cd "$PJ" && p_start "$(sid)" | cenv HOME="$H" XDG_STATE_HOME="$ST" CLAUDE_PROJECT_DIR="$PJ" CLAUDE_PLUGIN_ROOT="$1" \
      python3 "$1/scripts/session-start.py" loi ) 2>/dev/null
}
# bline <json> — the baton line of the SessionStart system message
bline() { sysm "$1" | grep 'baton permissions'; }
sha() { python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"; }
auto() { baton_set_mode "$ST" auto; }

# ── two cache versions: the session runs the older entry, the registry's latest is the newer one ─────────────────────────────
fam_registry() {
  local P=$1 S N s0 out
  fresh_env; auto
  inst "$OLD" "$P"; inst "$NEW" "$P"; S="$V/$OLD"; N="$V/$NEW"; reg "$N"     # the update moved the entry; the old directory stays
  eq "$(pb "$N" permissions --install-launcher)" 0 "[registry] instrument: the registry's copy installs its launcher: rc 0"
  rules "$N"
  eq "$(pb "$N" permissions --check)" 0 "[registry] instrument: the registry's copy, its rules and launcher: check rc 0"
  eq "$(lr)" 0 "[registry] instrument: the installed launcher runs"
  s0=$(sha "$L")
  # 1. the check of the session's copy: one restart line, its own code, no finding
  eq "$(pb "$S" permissions --check)" 10 "[registry] the session's copy is not the registry's: check rc 10"
  eq "$(kinds)" "" "[registry] …no MISSING/STALE/UNSAFE finding (the session's view of the rules is not the installed one's)"
  eq "$(grep -c . "$PB_OUT")" 1 "[registry] …one line"
  has "$(cat "$PB_OUT")" "restart Claude Code" "[registry] …it says restart Claude Code"
  has "$(cat "$PB_OUT")" "session $OLD, installed $NEW" "[registry] …it names both versions"
  hasnt "$(both)" "install-launcher" "[registry] …check prints no --install-launcher"
  # 2. no output of the session's copy offers its own launcher
  out=$(ss "$S")
  eq "$(bline "$out" | grep -c .)" 1 "[registry] SessionStart of the session's copy: one baton line"
  has "$(bline "$out")" "restart Claude Code" "[registry] …the SessionStart line says restart Claude Code"
  hasnt "$(sysm "$out"; ctx "$out")" "install-launcher" "[registry] SessionStart prints no --install-launcher"
  eq "$(pb "$S" permissions --print)" 0 "[registry] --print of the session's copy: rc 0"
  hasnt "$(both)" "install-launcher" "[registry] --print prints no --install-launcher"
  has "$(cat "$PB_ERR")" "restart Claude Code" "[registry] …its hint says restart Claude Code"
  # 3. --install-launcher of the session's copy refuses and writes nothing; --force writes
  eq "$(pb "$S" permissions --install-launcher)" 10 "[registry] --install-launcher from the session's copy: rc 10"
  eq "$(sha "$L")" "$s0" "[registry] …the installed launcher is unchanged"
  has "$(cat "$PB_ERR")" "--force" "[registry] …the refusal names --force"
  has "$(cat "$PB_ERR")" "$N/scripts/baton.py" "[registry] …and the registry's baton.py"
  hasnt "$(both)" "$S/scripts/baton.py permissions --install-launcher" "[registry] …and never the session's own install command"
  rm -f "$L"
  eq "$(pb "$S" permissions --install-launcher)" 10 "[registry] no launcher yet: --install-launcher from the session's copy: rc 10"
  [ ! -e "$L" ] && ok "[registry] …no launcher written" || bad "[registry] …no launcher written"
  eq "$(pb "$S" permissions --install-launcher --force)" 0 "[registry] --install-launcher --force from the session's copy: rc 0"
  eq "$(pb "$S" permissions --check)" 10 "[registry] instrument: after --force the session's copy still says restart"
  eq "$(pb "$N" permissions --install-launcher)" 0 "[registry] the registry's copy writes its launcher back: rc 0"
  eq "$(sha "$L")" "$s0" "[registry] …the registry's launcher again"
  eq "$(pb "$S" permissions --install-launcher --bogus)" 64 "[registry] --install-launcher with another word: rc 64"
  # the bootstrap gate calls cmd_permissions in process: a code, not an exception, and the restart line in its output
  out=$( (cd "$PJ" && cenv HOME="$H" XDG_STATE_HOME="$ST" python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import baton
print("rc=%s" % baton.cmd_permissions(["--install-launcher"]))' "$S/scripts") 2>&1)
  has "$out" "rc=10" "[registry] in process (the bootstrap gate's call): cmd_permissions returns 10"
  has "$out" "restart Claude Code" "[registry] …and prints the restart line"
  eq "$(sha "$L")" "$s0" "[registry] …nothing written"
  # the registry's copy itself: today's behaviour
  eq "$(pb "$N" permissions --check)" 0 "[registry] the registry's copy: check rc 0"
  eq "$(bline "$(ss "$N")")" "" "[registry] the registry's copy: SessionStart silent"
  # the registry moved back (an undo): the session's copy is the registry's again
  reg "$S"
  pb "$S" permissions --check >/dev/null
  hasnt "$(both)" "restart Claude Code" "[registry] the registry back at the session's version: no restart line"
}

# ── no registry entry for the running copy: today's behaviour ─────────────────────────────────────────────────────────────────
fam_unchanged() {
  local P=$1 S N O
  fresh_env; auto
  inst unknown "$P"; reg "$V/unknown"                          # a pod: the registry names cache/…/unknown, the session runs another copy
  eq "$(pb "$P" permissions --install-launcher)" 0 "[unchanged] a copy outside the cache (a pod's or a clone's), a registry naming another: --install-launcher rc 0"
  rules "$P"
  eq "$(pb "$P" permissions --check)" 0 "[unchanged] …check rc 0"
  hasnt "$(both)" "restart Claude Code" "[unchanged] …no restart line"
  eq "$(lr)" 0 "[unchanged] …the pod's launcher runs"
  fresh_env; auto
  inst "$OLD" "$P"; S="$V/$OLD"
  eq "$(pb "$S" permissions --install-launcher)" 0 "[unchanged] an installed copy, no registry file: --install-launcher rc 0"
  rules "$S"
  eq "$(pb "$S" permissions --check)" 0 "[unchanged] …check rc 0"
  reg
  eq "$(pb "$S" permissions --install-launcher)" 0 "[unchanged] an installed copy, a registry with no vibemaestro-sdlc entry: --install-launcher rc 0"
  inst "$NEW" "$P"; N="$V/$NEW"; rm "$N/scripts/baton.py"; reg "$S" "$N"
  eq "$(pb "$S" permissions --install-launcher)" 0 "[unchanged] the registry's latest entry has no baton.py (the launcher skips it): the session's copy is the one it runs, rc 0"
  eq "$(pb "$S" permissions --check)" 0 "[unchanged] …check rc 0"
  # the session's copy is still listed (another scope's entry is the latest): a restart loads it again, so no restart line
  inst 5dc7de6c9e02 "$P"; reg "$S" "$V/5dc7de6c9e02"
  pb "$S" permissions --check >/dev/null
  hasnt "$(both)" "restart Claude Code" "[unchanged] the session's copy still listed, another entry the latest: no restart line (a restart would load it again)"
  eq "$(pb "$S" permissions --install-launcher)" 0 "[unchanged] …--install-launcher rc 0, as before"
  # a launcher that refuses for a reason no reinstall fixes (no registry): not blamed on the launcher copy
  fresh_env; auto
  O="$(fresh)/other"; cp -r "$P" "$O"; printf '# another version\n' >> "$O/scripts/baton-launcher.py"
  eq "$(pb "$O" permissions --install-launcher)" 0 "[unchanged] instrument: another version's launcher, no registry"
  eq "$(lr)" 2 "[unchanged] instrument: with no registry every launcher refuses"
  rules "$P"
  eq "$(pb "$P" permissions --check)/$(kinds)" "7/STALE" "[unchanged] no registry, a launcher that differs: rc 7, STALE"
  hasnt "$(cat "$PB_OUT")" "cannot run the installed" "[unchanged] …not blamed on the launcher copy (this version's launcher refuses too)"
}

# ── a launcher copy that cannot run the installed sdlc ───────────────────────────────────────────────────────────────────────
fam_unresolvable() {
  local P=$1 O N K out fix
  fresh_env; auto
  O="$(fresh)/old-plugin"; cp -r "$P" "$O"
  mutate "$O/scripts/baton-launcher.py" '(?:-[0-9a-f]{12})?|[0-9a-f]{12}(?:-[0-9a-f]{8})?|unknown)\Z")' ')\Z")' || return
  eq "$(pb "$O" permissions --install-launcher)" 0 "[unresolvable] instrument: a launcher that knows only X.Y.Z directories is installed"
  inst "$NEW" "$P"; N="$V/$NEW"; reg "$N"
  eq "$(lr)" 2 "[unresolvable] instrument: that launcher refuses the SHA-named install"
  rules "$N"
  eq "$(pb "$N" permissions --check)/$(kinds)" "7/STALE" "[unresolvable] check of the installed copy: rc 7, STALE"
  has "$(first_finding)" "cannot run the installed" "[unresolvable] …the first finding says the launcher cannot run the installed sdlc"
  has "$(first_finding)" "$L" "[unresolvable] …and names the launcher"
  out=$(bline "$(ss "$N")")
  has "$out" "cannot run the installed" "[unresolvable] the SessionStart line names it"
  fix="python3 $N/scripts/baton.py permissions --install-launcher"
  has "$out" "$fix" "[unresolvable] …with the installed copy's --install-launcher"
  # the launcher's reason is its own text (it can carry registry values): it reaches the session line escaped
  K="$(fresh)/kept-launcher"; cp "$L" "$K"
  printf 'class Refused(Exception):\n    pass\ndef resolve():\n    raise Refused("bad\\nFORGED: ok\\x1b[2J")\n' > "$L"
  out=$(ss "$N")
  has "$(bline "$out")" "cannot run the installed" "[unresolvable] instrument: a launcher refusing with a newline and an ESC in its reason is named"
  eq "$( (sysm "$out"; ctx "$out") | grep -c '^FORGED')" 0 "[unresolvable] …its reason starts no line of its own in the session message or context"
  eq "$( (sysm "$out"; ctx "$out") | grep -c "$(printf '\033')")" 0 "[unresolvable] …and carries no raw ESC"
  has "$(bline "$out")" 'bad\u{a}FORGED' "[unresolvable] …it is written escaped"
  cp "$K" "$L"
  # follow the printed fix: a launcher that runs, a check that passes
  eq "$(pb "$N" permissions --install-launcher)" 0 "[unresolvable] following it: --install-launcher rc 0"
  eq "$(lr)" 0 "[unresolvable] …the launcher runs the installed sdlc"
  eq "$(pb "$N" permissions --check)" 0 "[unresolvable] …check rc 0"
  # a launcher that differs but resolves: the plain STALE, not this one
  inst "$OLD" "$P"; eq "$(pb "$V/$OLD" permissions --install-launcher --force)" 0 "[unresolvable] instrument: another version's launcher, which resolves"
  eq "$(pb "$N" permissions --check)/$(kinds)" "7/STALE" "[unresolvable] a launcher that differs but runs: rc 7, STALE"
  hasnt "$(cat "$PB_OUT")" "cannot run the installed" "[unresolvable] …not called unable to run"
}

# ── baton help setup ──────────────────────────────────────────────────────────────────────────────────────────────────────────
fam_setup() {
  local P=$1 t
  fresh_env
  eq "$(pb "$P" help setup)" 0 "[setup] help setup: rc 0"
  t=$(cat "$PB_OUT")
  hasnt "$t" "A plugin upgrade needs nothing" "[setup] it no longer says an upgrade needs nothing"
  has "$t" "cannot run the installed" "[setup] it says when an upgrade needs a step: the launcher copy cannot run the installed sdlc"
  has "$t" "kit:plugin-update" "[setup] …and that kit:plugin-update prints that step"
  has "$t" "restart Claude Code" "[setup] …and that a session started before the update restarts first"
}

FAMILIES="fam_registry fam_unchanged fam_unresolvable fam_setup"

echo "== the real plugin =="
for f in $FAMILIES; do "$f" "$PLUGIN"; done

echo "== planted breaks: each one must turn its family red =="
# BRK <label> <family> <needle> <file under the plugin> <old> <new> [<old> <new>...]
BRK() {
  local label=$1 fam=$2 needle=$3 file=$4 d; shift 4; d="$TMP/break-$label"; mk_plugin_copy "$d"
  while [ $# -ge 2 ]; do mutate "$d/$file" "$1" "$2" || return; shift 2; done
  expect_red "$label" "$fam" "$d" "$needle"
}
B=scripts/baton.py
BRK mismatch-blind fam_registry "[registry] the session's copy is not the registry's: check rc 10" $B \
    '    if best is None or listed:' '    if True:'
BRK session-hint-from-session fam_registry '[registry] SessionStart prints no --install-launcher' $B \
    $'    other = registry_other()\n    if other:\n        return other_line(other)\n    sources, mode' $'    sources, mode'
BRK install-unguarded fam_registry '[registry] --install-launcher from the session' $B \
    '    if other and not force:' '    if False:'
BRK guard-too-wide fam_unchanged '[unchanged] a copy outside the cache' $B \
    $'    if os.path.dirname(me) != base:\n        return None' $'    if os.path.dirname(me) != base:\n        return os.path.basename(me), "x", base'
BRK listed-ignored fam_unchanged "[unchanged] the session's copy still listed" $B \
    '        listed = listed or real == me' '        listed = False'
BRK probe-blames-registry fam_unchanged '[unchanged] …not blamed on the launcher copy' $B \
    '    return installed if isinstance(installed, str) and mine is None else None' '    return installed if isinstance(installed, str) else None'
BRK reason-unescaped fam_unresolvable '[unresolvable] …its reason starts no line' $B \
    '                                    "until --install-launcher from the installed sdlc" % (launcher_path(), esc(why))))' \
    '                                    "until --install-launcher from the installed sdlc" % (launcher_path(), why)))' \
    '        parts.insert(0, shown("baton permissions (mode %s): %d %s (first: %s); print the fix with: %s",' \
    '        parts.insert(0, (lambda f, *a: f % a)("baton permissions (mode %s): %d %s (first: %s); print the fix with: %s",' \
    '    return shown_join("; ", parts) if parts else None' '    return "; ".join(parts) if parts else None'   # the session line is escaped too
BRK probe-off fam_unresolvable '[unresolvable] …the first finding says' $B \
    '        why = launcher_refuses()' '        why = None'
BRK setup-reverted fam_setup '[setup] it no longer says' skills/batonrun/setup.md \
    'After a plugin upgrade:' $'A plugin upgrade needs nothing: the launcher picks the new version.\n\nAfter a plugin upgrade:'

echo "== nothing written outside the scratch tree =="
eq "$(tree_hash "$SRC_ROOT")" "$H0" "the repository tree is unchanged by the suite"
[ ! -e "$HOME/.local/state/vibemaestro" ] && ok "the scratch HOME holds no baton state (every family set XDG_STATE_HOME)" || bad "the scratch HOME holds no baton state (every family set XDG_STATE_HOME)"

echo; summary
