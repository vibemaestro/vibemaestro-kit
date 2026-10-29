#!/usr/bin/env bash
# Purpose: create one file in a running pod over kubectl exec, holding the text of an input file
# Targets: {ns}/{pod} {server} {rpath} — the file at that absolute path in that pod, on the cluster whose API server the context names
# Blast: that one file in that pod; it lasts until the pod is replaced
# Undo: removes the file, only while it holds exactly the text this act writes
# Pre: the context names the API server given; the pod exists and runs bash; the file is absent (other content is refused)
# Stops: cluster-lane
# Params: ctx=name ns=name pod=name server=url rpath=path body=input
# Expect: pod * create *
#
# A baton script of kind kubectl-exec (BatonRun), written by `baton new __NAME__ --from kubectl-exec`. The contract (the header above,
# the phases, the write() gate, check, rehearse, sign, run) is the one `baton new` writes without --from: its comments
# explain each part. Run the launcher bare, one command per call: <launcher> go __NAME__.sh ctx='<context>' ns='<namespace>'
# pod='<pod>' server='<https API server>' rpath='<absolute path in the pod>' body='<file holding the text>'. The context is a
# `name` value; the server must be the one the context names, so the call says which cluster it means.
# A write in a live cluster: the owner signs it, the session runs it (Stops: cluster-lane, never none). The program goes through
# stdin into `bash -s` in the pod; every read is printed first and decided on after. The plan carries the context, the API
# server and the pod's uid read before the act, so a signature does not run against another cluster or a replaced pod.
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
P_CTX="$1"
P_NS="$2"
P_POD="$3"
P_SERVER="$4"
P_RPATH="$5"
P_BODY="$6"
TEXT=$(cat -- "$P_BODY")
TSHA=$(printf '%s\n' "$TEXT" | python3 -I -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')

# in_pod — the program on stdin (a quoted heredoc) through stdin into bash -s in the pod; the values go first, quoted
in_pod() {
  { printf 'RPATH=%q\nTEXT=%q\n' "$P_RPATH" "$TEXT"; cat; } | kubectl --context "$P_CTX" -n "$P_NS" exec -i "$P_POD" -- bash -s
}
# a read: the file's state in the pod (same, other, absent); it ends with `true`, a miss is not a failure
pod_state() {
  in_pod <<'EOF'
if [ -f "$RPATH" ] && cmp -s "$RPATH" <(printf '%s\n' "$TEXT"); then echo state=same
elif [ -e "$RPATH" ]; then echo state=other
else echo state=absent; fi
true
EOF
}
pod_put() {
  in_pod <<'EOF'
printf '%s\n' "$TEXT" > "$RPATH.baton-new" && mv -f "$RPATH.baton-new" "$RPATH"
EOF
}
pod_rm() {
  in_pod <<'EOF'
rm -f -- "$RPATH"
EOF
}
# value <key> <output> — the value of a key=value line of a read's output
value() { printf '%s\n' "$2" | sed -n "s/^$1=//p" | tail -n 1; }

# ── the act: every change through write() ──
# The plan names the cluster by what was read before the act: the context, the API server it points at, the pod's uid. A
# signature for one cluster or one pod incarnation does not run against another.
act() {
  local SERVER PUID OUT
  SERVER=$(kubectl --context "$P_CTX" config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>&1 || true)
  PUID=$(kubectl --context "$P_CTX" -n "$P_NS" get pod "$P_POD" -o jsonpath='{.metadata.uid}' 2>&1 || true)
  printf 'server=%s\nuid=%s\n' "$SERVER" "$PUID"
  if [ "$SERVER" != "$P_SERVER" ]; then
    echo "REFUSE context $P_CTX names the API server $SERVER, not $P_SERVER (the read is above)" >&2
    return 3
  fi
  case "$PUID" in
    "" | *" "*) echo "REFUSE pod $P_NS/$P_POD: no uid (the read is above)" >&2; return 3 ;;
  esac
  OUT=$(pod_state 2>&1 || true)
  printf '%s\n' "$OUT"
  case "$(value state "$OUT")" in
    same) echo "same $P_RPATH in $P_NS/$P_POD (nothing to do)"; return 0 ;;
    absent) ;;
    *) echo "REFUSE $P_RPATH in $P_NS/$P_POD exists with other content, or the pod did not answer" >&2; return 3 ;;
  esac
  write "pod $P_NS/$P_POD (uid $PUID) on $SERVER (context $P_CTX) create $P_RPATH sha256 $TSHA" pod_put
}

# ── post-check: the file in the pod holds the text ──
postcheck() {
  local OUT
  OUT=$(pod_state 2>&1 || true)
  printf '%s\n' "$OUT"
  [ "$(value state "$OUT")" = same ]
}

# ── undo: removes the file only while it holds the text ──
undo() {
  local OUT
  OUT=$(pod_state 2>&1 || true)
  printf '%s\n' "$OUT"
  case "$(value state "$OUT")" in
    same) write "pod $P_NS/$P_POD remove $P_RPATH" pod_rm ;;
    absent) return 0 ;;
    *) echo "LEAVE $P_RPATH in $P_NS/$P_POD: not the planned text, or the pod did not answer" >&2; return 1 ;;
  esac
  OUT=$(pod_state 2>&1 || true)
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
