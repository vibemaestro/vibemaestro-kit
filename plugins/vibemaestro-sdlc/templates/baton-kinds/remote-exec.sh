#!/usr/bin/env bash
# Purpose: create one file on a host over ssh, holding the given text
# Targets: the file at the given absolute path on the given host
# Blast: that one file on that host; nothing else is read or written there
# Undo: removes the file, only while it holds exactly the text this act writes
# Pre: the host answers over ssh without a prompt; the file is absent (other content is refused, never overwritten)
# Stops: none
# Expect: remote * create *
#
# A baton script of kind remote-exec (BatonRun), written by `baton new __NAME__ --from remote-exec`. The contract (the header above,
# the phases, the write() gate, check, rehearse, sign, run) is the one `baton new` writes without --from: its comments
# explain each part. Run the launcher bare, one command per call: <launcher> go __NAME__.sh <args>
# The program and its values go through stdin into `bash -s` on the host (never as arguments: the login shell may be fish);
# a remote read is printed first and decided on after (`OUT=$(remote_state 2>&1 || true)`). The plan carries the host as given
# and the name the host reports, read before the act.
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
if [ $# -ne 3 ]; then
  echo "usage: bash __NAME__.sh <host> <absolute path on the host> <text>" >&2
  exit 64
fi
HOST=$1
RPATH=$2
TEXT=$3
case "$RPATH" in
  /*) ;;
  *) echo "usage: the path on the host is absolute: $RPATH" >&2; exit 64 ;;
esac
TSHA=$(printf '%s\n' "$TEXT" | python3 -I -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')

# on_host — the program on stdin (a quoted heredoc) through stdin into bash -s on the host; the values go first, quoted for the
# remote bash, so the host's login shell (it may be fish) parses only `bash -s`
on_host() {
  { printf 'RPATH=%q\nTEXT=%q\n' "$RPATH" "$TEXT"; cat; } | ssh -o BatchMode=yes "$HOST" bash -s
}
# a read: the host's own name and the file's state (same, other, absent); it ends with `true`, a miss is not a failure
remote_state() {
  on_host <<'EOF'
printf 'host=%s\n' "$(uname -n)"
if [ -f "$RPATH" ] && cmp -s "$RPATH" <(printf '%s\n' "$TEXT"); then echo state=same
elif [ -e "$RPATH" ]; then echo state=other
else echo state=absent; fi
true
EOF
}
remote_put() {
  on_host <<'EOF'
printf '%s\n' "$TEXT" > "$RPATH.baton-new" && mv -f "$RPATH.baton-new" "$RPATH"
EOF
}
remote_rm() {
  on_host <<'EOF'
rm -f -- "$RPATH"
EOF
}
# value <key> <output> — the value of a key=value line of a read's output
value() { printf '%s\n' "$2" | sed -n "s/^$1=//p" | tail -n 1; }

# ── the act: every change through write() ──
act() {
  local OUT RHOST
  OUT=$(remote_state 2>&1 || true)
  printf '%s\n' "$OUT"
  RHOST=$(value host "$OUT")
  if [ -z "$RHOST" ]; then
    echo "REFUSE $HOST did not answer (its output is above)" >&2
    return 3
  fi
  case "$(value state "$OUT")" in
    same) echo "same $RPATH on $HOST (nothing to do)"; return 0 ;;
    absent) ;;
    *) echo "REFUSE $RPATH on $HOST exists with other content" >&2; return 3 ;;
  esac
  write "remote $HOST ($RHOST) create $RPATH sha256 $TSHA" remote_put
}

# ── post-check: the file on the host holds the text ──
postcheck() {
  local OUT
  OUT=$(remote_state 2>&1 || true)
  printf '%s\n' "$OUT"
  [ "$(value state "$OUT")" = same ]
}

# ── undo: removes the file only while it holds the text ──
undo() {
  local OUT
  OUT=$(remote_state 2>&1 || true)
  printf '%s\n' "$OUT"
  case "$(value state "$OUT")" in
    same) write "remote $HOST remove $RPATH" remote_rm ;;
    absent) return 0 ;;
    *) echo "LEAVE $RPATH on $HOST: not the planned text, or the host did not answer" >&2; return 1 ;;
  esac
  OUT=$(remote_state 2>&1 || true)
  [ "$(value state "$OUT")" = absent ]
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
