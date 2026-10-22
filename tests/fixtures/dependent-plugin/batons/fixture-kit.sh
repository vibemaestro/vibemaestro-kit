#!/usr/bin/env bash
# Purpose: test fixture, a dependent plugin's kit (kit:fixture-kit): create one file holding the given text
# Targets: the file named by the first argument
# Blast: that one file; nothing else is read or written
# Undo: removes the file, only while it holds exactly the text this act writes
# Pre: the file is absent (an existing file with other content is refused, never overwritten)
# Stops: none
# Each: create *
#
# Shaped like the gitops kits (publish-public, release-promote): it runs only through the baton runner of vibemaestro-sdlc,
# as `kit:fixture-kit`, found in batons/ of this plugin because its manifest declares the dependency (tests/test-baton.sh
# fam_kit_dep). It prints the plugin root it runs from, so the suite can see which one it got.
set -euo pipefail
PHASE=${BATON_PHASE:-rehearse}

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
  echo "kit:fixture-kit runs only through the baton runner (baton rehearse|sign|run kit:fixture-kit …)" >&2
  exit 64
fi
echo "root=$BATON_PLUGIN_ROOT"
if [ $# -ne 2 ]; then
  echo "usage: baton rehearse|run kit:fixture-kit <file> <text>" >&2
  exit 64
fi
DEST=$1
TEXT=$2
case "$DEST" in
  /*) ;;
  *) DEST="$PWD/$DEST" ;;
esac

holds_text() { [ -f "$DEST" ] && cmp -s "$DEST" <(printf '%s\n' "$TEXT"); }
put_text() { printf '%s\n' "$TEXT" > "$DEST"; }

act() {
  if holds_text; then
    echo "same $DEST (nothing to do)"
    echo "PLAN-COUNT 0"
    return 0
  fi
  if [ -e "$DEST" ]; then
    echo "REFUSE $DEST exists with other content" >&2
    return 3
  fi
  echo "PLAN-COUNT 1"
  write "create $DEST" put_text
}

postcheck() {
  holds_text
}

undo() {
  if holds_text; then
    write "remove $DEST" rm -f -- "$DEST"
  fi
  ! holds_text
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
