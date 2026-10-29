#!/usr/bin/env bash
# Purpose: set up a coordinator machine for BatonRun: install the baton launcher and add the printed permission block (and attribution off where a key is absent) to the user settings, after a machine report
# Targets: <state-dir>/bin/baton; <claude-dir>/settings.json (created as {} when absent); backups and run records under <state-dir>/records
# Blast: those two files only; no rule or key the settings already hold is removed or changed; the mode is never written
# Undo: newest first, only what this signed run wrote and only while it is what the run left: the settings put back byte for byte by the kind settings-merge's undo (a file created as {} removed again), the old launcher put back or the new one removed; a target that changed since is left alone (LEAVE, exit 5)
# Pre: vibemaestro-sdlc is installed in the plugin cache and this session runs the installed version (a session left on an older copy is refused at rehearse, rc 3: restart Claude Code); the settings are JSON and not a symbolic link; adding rules reaches permissions --check rc 0 but for the old broad ask rules, which kit:permissions-upgrade swaps after it (else refused); something to do (else refused, rc 3)
# Stops: security-boundary
#   Why: it adds allow rules, which widen what a session may do, so the owner signs, in every mode.
# Usage: no arguments (every value is this machine's; a new machine runs it through the plugin's scripts/baton.py)
# Each: bootstrap *
#
# The kit baton kit:coordinator-bootstrap. On a new machine there is no launcher yet, so the session calls baton.py of
# the plugin itself: python3 <plugin>/scripts/baton.py rehearse kit:coordinator-bootstrap, then the owner's sign, then run
# (the skill coordinator-bootstrap says who types which line, and why). It takes no argument: every value is this machine's.
# The engine is gates/coordinator_bootstrap.py: the report, the plan (one line per write, at most two), each write checked
# against the signed plan (BATON_PLAN), the post-check and the undo. A machine that is already set up is refused at rehearse
# with `REFUSE nothing to do` and exit 3: nothing to sign, nothing written.
# A kit signature binds this file only, and on a new machine the deny rule that keeps the plugin cache unwritable is what this
# run installs: so this file hashes the code that writes (the engine, the kind settings-merge, baton.py, the launcher template)
# and puts that sha256 into every plan line. A change to any of them after signing changes the run's plan: baton refuses it.
# Each write hashes the same files again and refuses a line whose sha256 is not the one it computes. A dependent plugin's
# report hook is not among them, so the engine leaves it out in the run phase: the owner saw its lines at rehearse.
# This script is plugin code: baton lets a kit baton, and nothing else, run a plugin gate as python3 -I -B "$BATON_PLUGIN_ROOT/gates/…".
# bash 3.2 (macOS) runs this file: no associative arrays, no ${var,,}, no mapfile.
set -euo pipefail
PHASE=${BATON_PHASE:-rehearse}

# write <plan line> <command> [args...] — the one gate for every change
write() {
  local plan=$1
  shift
  case "$PHASE" in
    rehearse)
      printf 'PLAN %s\n' "$plan"
      printf '%s\n' "$plan" >> "${BATON_WRITES:-/dev/null}"
      ;;
    run | undo)
      printf 'DO %s\n' "$plan"
      printf '%s\n' "$plan" >> "${BATON_WRITES:-/dev/null}"
      "$@"
      ;;
    *)
      printf 'write called in phase %s: %s\n' "$PHASE" "$plan" >&2
      return 70
      ;;
  esac
}

# ── arguments and reads: every phase runs them ──
if [ -z "${BATON_PLUGIN_ROOT:-}" ]; then
  echo "kit:coordinator-bootstrap runs only through the baton runner (baton.py rehearse|sign|run kit:coordinator-bootstrap)" >&2
  exit 64
fi
if [ $# -ne 0 ]; then
  echo "usage: baton.py rehearse|run kit:coordinator-bootstrap (no argument: every value is this machine's)" >&2
  exit 64
fi

# engine_sha — one sha256 over the code the writes run, read here so the signature binds it (each write checks it again)
engine_sha() {
  python3 -I -c 'import hashlib, sys
h = hashlib.sha256()
for name in sys.argv[1:]:
    h.update(hashlib.sha256(open(name, "rb").read()).hexdigest().encode() + b"\n")
print(h.hexdigest())' "$BATON_PLUGIN_ROOT/gates/coordinator_bootstrap.py" "$BATON_PLUGIN_ROOT/templates/baton-kinds/settings-merge.sh" \
    "$BATON_PLUGIN_ROOT/scripts/baton.py" "$BATON_PLUGIN_ROOT/scripts/baton-launcher.py"
}
engine() { python3 -I -B "$BATON_PLUGIN_ROOT/gates/coordinator_bootstrap.py" "$@" < /dev/null; }
engine_do() { python3 -I -B "$BATON_PLUGIN_ROOT/gates/coordinator_bootstrap.py" do "$1" --expect-plan "${BATON_PLAN:?no signed plan}" < /dev/null; }

# ── the act: the report, then every change through write() ──
act() {
  local plan line code n=0
  engine report
  plan=$(engine plan)
  code=$(engine_sha)
  while IFS= read -r line; do
    [ -n "$line" ] && n=$((n + 1))
  done <<EOF
$plan
EOF
  printf 'PLAN-COUNT %s\n' "$n"
  while IFS= read -r line; do
    case "$line" in
      "bootstrap launcher "*) write "$line, engine sha256 $code" engine_do launcher ;;
      "bootstrap settings "*) write "$line, engine sha256 $code" engine_do settings ;;
      "") ;;
      *)
        echo "REFUSE the engine planned an unknown step: $line" >&2
        return 3
        ;;
    esac
  done <<EOF
$plan
EOF
}

# ── post-check: the launcher is current and permissions --check finds nothing ──
postcheck() {
  engine postcheck
}

# ── undo: what this signed run wrote, newest first, while it is still what the run left ──
undo() {
  python3 -I -B "$BATON_PLUGIN_ROOT/gates/coordinator_bootstrap.py" undo --expect-plan "${BATON_PLAN:-}" < /dev/null
}

case "$PHASE" in
  rehearse)
    act
    echo "VERDICT rehearse ok"
    ;;
  run)
    act
    echo "VERDICT run ok"
    ;;
  postcheck)
    postcheck
    echo "VERDICT postcheck ok"
    ;;
  undo)
    undo
    echo "VERDICT undo ok"
    ;;
  *)
    echo "unknown phase: $PHASE" >&2
    exit 64
    ;;
esac
