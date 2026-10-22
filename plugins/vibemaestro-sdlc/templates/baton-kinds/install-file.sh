#!/usr/bin/env bash
# Purpose: install one file, byte for byte, into a directory that may be read-only
# Targets: <directory>/<the source's file name>
# Blast: that one file; the directory's mode changes for the copy and is put back
# Undo: removes the file only while it holds the planned bytes; the directory's mode is put back
# Pre: the source is a readable file; the target is absent (other bytes there are refused, never overwritten); the directory is not under a .git or .claude directory, the Claude Code config directory or the vibemaestro state directory
# Stops: none
# Expect: install *
#
# A baton script of kind install-file (BatonRun): run as is with `<launcher> go kind:install-file <source> <directory>` (no script
# to write), or written by `baton new __NAME__ --from install-file` to change it. The contract (the header above, the phases, the
# write() gate, check, rehearse, sign, run) is the one `baton new` writes without --from: its comments explain each part. Run the
# launcher bare, one command per call: <launcher> go __NAME__.sh <args>
# The plan carries what was read before the act: the source's sha256 and the directory's mode. The copy is mode 0444; it goes
# through a new file mktemp makes in the directory, so no predictable name there can be a link that leads elsewhere.
# Why `Stops: none`: an ordinary directory only. Settings, hooks, the launcher and the baton state (a .git or .claude directory,
# the Claude Code config directory, the vibemaestro state directory) are a security boundary: this kind refuses them, and such a
# copy is a baton of its own with Stops: security-boundary, which the owner signs.
# bash 3.2 (macOS) runs this file: no associative arrays, no ${var,,}, no mapfile.
set -euo pipefail
PHASE=${BATON_PHASE:-rehearse}

# write <plan line> <command> [args...] — the one gate for every change. A change whose after-state shows late (a log line,
# a status) waits for it inside the command it runs, with a time limit, so the post-check is not a race.
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
if [ $# -ne 2 ]; then
  echo "usage: bash __NAME__.sh <source file> <directory>" >&2
  exit 64
fi
SRC=$1
DIR=${2%/}
case "$SRC" in /*) ;; *) SRC="$PWD/$SRC" ;; esac
case "$DIR" in /*) ;; *) DIR="$PWD/$DIR" ;; esac
case "${XDG_STATE_HOME:-}" in
  /*) STATE_BASE=$XDG_STATE_HOME ;;
  *) STATE_BASE="$HOME/.local/state" ;;
esac
case "${CLAUDE_CONFIG_DIR:-}" in
  /*) CLAUDE_DIR=$CLAUDE_CONFIG_DIR ;;
  *) CLAUDE_DIR="$HOME/.claude" ;;
esac
DEST="$DIR/$(basename "$SRC")"

sha_of() { python3 -I -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"; }
mode_of() { python3 -I -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])' "$1"; }
# real_path — links resolved, in lower case: a case-insensitive file system (macOS) reads .CLAUDE as .claude
real_path() { python3 -I -c 'import os,sys; print(os.path.realpath(sys.argv[1]).lower())' "$1"; }
# guarded — the directory (links resolved, case folded) is a security boundary this kind does not cross
guarded() {
  local d top
  d=$(real_path "$DIR")
  case "$d/" in
    */.git/* | */.claude/*) return 0 ;;
  esac
  for top in "$CLAUDE_DIR" "$STATE_BASE/vibemaestro"; do
    top=$(real_path "$top")
    case "$d/" in
      "$top"/*) return 0 ;;
    esac
  done
  return 1
}
holds_src() { [ -f "$DEST" ] && [ ! -L "$DEST" ] && [ "$(sha_of "$DEST")" = "$(sha_of "$SRC")" ]; }
# with_dir_writable <command…> — the directory writable for one command, its mode put back whatever the command did
with_dir_writable() {
  local m rc=0
  m=$(mode_of "$DIR")
  chmod u+w "$DIR"
  "$@" || rc=$?
  chmod "$m" "$DIR"
  return "$rc"
}
copy_in() {
  local tmp
  tmp=$(mktemp "$DIR/.baton-new.XXXXXX") || return 1
  if cp "$SRC" "$tmp" && chmod 0444 "$tmp"; then
    if [ -e "$DEST" ] || [ -L "$DEST" ]; then          # appeared since the act looked: a link there would lead the mv elsewhere
      echo "REFUSE $DEST appeared during the copy" >&2
    elif mv -f "$tmp" "$DEST"; then
      return 0
    fi
  fi
  rm -f -- "$tmp"
  return 1
}
put_file() { with_dir_writable copy_in; }
drop_file() { with_dir_writable rm -f -- "$DEST"; }

# ── the act: every change through write() ──
act() {
  if [ ! -f "$SRC" ] || [ ! -r "$SRC" ]; then
    echo "REFUSE $SRC is not a readable file" >&2
    return 3
  fi
  if [ ! -d "$DIR" ]; then
    echo "REFUSE $DIR is not a directory" >&2
    return 3
  fi
  if guarded; then
    echo "REFUSE $DIR is under a .git or .claude directory, the Claude Code config or the baton state: a security boundary," \
      "a baton of its own with Stops: security-boundary" >&2
    return 3
  fi
  if holds_src; then
    echo "same $DEST (nothing to do)"
    return 0
  fi
  if [ -e "$DEST" ] || [ -L "$DEST" ]; then
    echo "REFUSE $DEST exists with other bytes" >&2
    return 3
  fi
  write "install $DEST sha256 $(sha_of "$SRC") (directory mode $(mode_of "$DIR"), kept)" put_file
}

# ── post-check: the source's bytes, read-only ──
postcheck() {
  holds_src && [ "$(mode_of "$DEST")" = 444 ]
}

# ── undo: removes only the planned bytes; the directory's mode is put back by the same helper ──
undo() {
  if holds_src; then
    write "remove $DEST" drop_file
  fi
  ! holds_src
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
