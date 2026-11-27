#!/bin/bash
# =============================================================================
# vibemaestro-sdlc's baton on real Windows: what runs there, and the one plain line of what does not run there yet.
# Run: bash tests/test-baton-windows.sh   (Git for Windows' bash; .github/workflows/windows-everyday.yml runs it on a GitHub-hosted
#      Windows runner by hand). Anywhere else every family prints SKIP with its reason and the suite exits 0.
#
#   [I] `import baton` and the commands that only read: log, log --grants, mode, list (a CRLF baton by its bytes' sha256), the
#       SessionStart line (silent)
#   [R] grant revoke --focus: a charter in force ends, its line in log.tsv has no CR, and a second revoke finds none
#   [K] the log lock (msvcrt): a writer waits while another process holds it, goes on once it is released or its holder is
#       killed, and two writers at once lose no line; a lock held past the wait still revokes, through the revoke file
#   [P] each path that does not run on Windows yet: one plain line, rc 2, nothing ran, no traceback; the owner hook denies
#
# The brain's own close and supersede of a focus on Windows run in its suites (test-brain-store.sh [focus-words-not-focus],
# [jira]), which windows-everyday runs too.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
SKIPS=0
skip() { SKIPS=$((SKIPS+1)); printf '  SKIP %s: %s\n' "$1" "$2"; }

if [ "${OS:-}" != Windows_NT ]; then
  for f in I R K P; do skip "[$f]" "not Windows (OS is not Windows_NT)"; done
  echo "$SKIPS skipped"; summary; exit
fi

PL="$SRC_ROOT/plugins/vibemaestro-sdlc"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
export LC_ALL=C.UTF-8 VIBEMAESTRO_NO_UPDATE_CHECK=1 PYTHONDONTWRITEBYTECODE=1
# Git Bash's ps gives no sizes: capped would say so on stderr inside a refusal's output (its time cap holds), as in the brain parts
export PLANT_CAP_MEM_MB=0
win() { cygpath -w "$1"; }
export XDG_STATE_HOME; XDG_STATE_HOME=$(win "$HOME/.local/state")   # one spelling for Python and for this script
ST="$HOME/.local/state/vibemaestro/baton"
BT=$(win "$PL/scripts/baton.py")
W="$TMP/work"; mkdir -p "$W/.vibemaestro"
echo "machine: $(python3 --version 2>&1 | tr -d '\r')"

bt() {  # bt <args…> — baton.py from $W; prints stdout and stderr (CR removed), then rc=<n>
  local out rc
  out=$(cd "$W" && python3 "$BT" "$@" 2>&1); rc=$?
  printf '%s\nrc=%d' "$(printf '%s' "$out" | tr -d '\r')" "$rc"
}
cbt() {  # cbt <args…> — bt for a run that must refuse (capped)
  local out rc=0
  out=$(cd "$W" && capped python3 "$BT" "$@" 2>&1) || rc=$?
  printf '%s\nrc=%d' "$(printf '%s' "$out" | tr -d '\r')" "$rc"
}
charter() {  # charter <focus> <id> — a charter in force for <focus>, signed from $W: its record and its `grant signed` line, as
  # the owner's signature leaves them (the owner's dialog does not run on Windows, so the test writes what it would have)
  (cd "$W" && python3 -c 'import hashlib, json, os, sys, time
st, focus, gid = sys.argv[1:4]
d = os.path.join(st, "vibemaestro", "baton")
os.makedirs(os.path.join(d, "grants"), exist_ok=True)
until = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 86400))
g = {"v": 1, "kind": "charter", "id": gid, "focus": focus, "repos": [], "kinds": ["baton"], "max_stops": [], "expires": until,
     "dir": os.path.realpath(os.getcwd()), "dir_key": "project-0000000000000000"}
g["body_sha256"] = hashlib.sha256(json.dumps(g, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
g["signature"] = {"by": "owner", "dialog": "0" * 32, "time": until, "body_sha256": g["body_sha256"]}
with open(os.path.join(d, "grants", gid + ".json"), "w") as f:
    json.dump(g, f)
with open(os.path.join(d, "log.tsv"), "ab") as f:
    f.write(("\t".join(["2026-11-18T00:00:00Z", "grant", "-", "-", "-", "-", "-", "owner", "-", "signed", "-",
                        gid + " " + g["body_sha256"], "-"]) + "\n").encode())' "$XDG_STATE_HOME" "$1" "$2")
}
holder() {  # holder <ready file> <release file> — holds the log lock as baton takes it (msvcrt, byte 0 of log.lock) until the
  # release file exists; writes its Windows pid into the ready file once it holds it. exec: `holder … &` is that Python itself
  exec python3 -c 'import msvcrt, os, sys, time
fd = os.open(os.path.join(sys.argv[1], "log.lock"), os.O_RDWR | os.O_CREAT | os.O_BINARY, 0o600)
msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)
with open(sys.argv[2] + ".tmp", "w") as f:
    f.write(str(os.getpid()))
os.replace(sys.argv[2] + ".tmp", sys.argv[2])
while not os.path.exists(sys.argv[3]):
    time.sleep(0.05)
msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)' "$(win "$ST")" "$(win "$1")" "$(win "$2")"
}
await() { local i; for i in $(seq 200); do [ -e "$1" ] && return 0; sleep 0.05; done; return 1; }
lines() { local n; n=$(grep -c -F -- "$1" "$ST/log.tsv" 2>/dev/null); echo "${n:-0}"; }   # grep -c prints 0 itself, with rc 1
ONE_LINE="does not run on Windows yet: a signed run needs the owner's dialog, which does not run there (signed runs and the owner's dialog run on Linux and macOS, inside a \`claude\` session in a terminal, Claude Code's VS Code extension or the Claude desktop app); nothing ran"

echo "== [I] import, and the commands that only read =="
eq "$(cd "$W" && python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import baton; print("imported")' "$(win "$PL/scripts")" 2>&1 | tr -d '\r')" \
  imported "[I1] import baton: no fcntl at import (the field trial's 'No module named fcntl')"
eq "$(bt log)" "$(printf '\nrc=0')" "[I2] log with no log yet: nothing, rc 0"
eq "$(bt log --grants)" "$(printf 'grants: none\nrc=0')" "[I3] log --grants: none, rc 0"
eq "$(bt mode)" "$(printf 'manual\nbaton: mode manual from the default\nrc=0')" "[I4] mode: manual from the default, rc 0"
O=$(bt list soul-line); has "$O" "kit:soul-line" "[I5] list soul-line names the kit"; eq "${O##*rc=}" 0 "[I5] …rc 0"
eq "$(cd "$W" && python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import baton; print(baton.session_warning())' "$(win "$PL/scripts")" 2>&1 | tr -d '\r')" \
  None "[I6] the SessionStart line is silent on Windows: the permission rules serve signed runs, which do not run there"
mkdir -p "$HOME/data/vibemaestro/batons"
printf '#!/usr/bin/env bash\r\n# Purpose: a CRLF baton for the Windows list case\r\nset -eu\r\n' > "$HOME/data/vibemaestro/batons/crlf-case.sh"
O=$(XDG_DATA_HOME=$(win "$HOME/data") bt list crlf-case)
has "$O" "sha256 5a4ba065c0a78ec58b208b89f59ced9c232d4278f4a6f41fe42246f44fcc280b" \
  "[I7] list names a user baton with CRLF lines by the sha256 of its bytes (a text-mode read hashes them with LF)"

echo "== [R] grant revoke --focus =="
charter P8 0000000000000a08
has "$(bt log --grants)" "0000000000000a08" "[R1] instrument: the test's charter is listed"
eq "$(bt grant revoke --focus P8)" "$(printf 'grant 0000000000000a08 revoked: the charter for P8 ended\nrc=0')" \
  "[R1] grant revoke --focus P8: the charter ends, rc 0 (what the brain's op close runs)"
has "$(bt log --grants)" "revoked" "[R2] log --grants: it is revoked"
eq "$(lines "$(printf 'revoked\t-\t0000000000000a08')")" 1 "[R2] one revoke line in log.tsv"
eq "$(python3 -c 'import sys; print(open(sys.argv[1], "rb").read().count(b"\r"))' "$(win "$ST/log.tsv")" | tr -d '\r')" 0 "[R3] no CR in log.tsv (binary writes: a CR would end each line's last field)"
O=$(bt grant revoke --focus P8); has "$O" "no charter in force for P8 from " "[R4] again: no charter in force"; eq "${O##*rc=}" 0 "[R4] …rc 0"
O=$(cbt grant revoke --focus 8); eq "${O##*rc=}" 64 "[R5] a malformed focus: usage, rc 64"; hasnt "$O" "Traceback" "[R5] …no traceback"

echo "== [K] the log lock =="
charter P9 0000000000000a09
R="$TMP/k1"; mkdir -p "$R"
holder "$R/ready" "$R/release" & HP=$!
if ! await "$R/ready"; then
  bad "[K1] instrument: the test's holder never took the lock"
else
  (cd "$W" && python3 "$BT" grant revoke --focus P9 > "$R/out" 2>&1; echo $? > "$R/rc") & WP=$!
  sleep 2
  eq "$(test -e "$R/rc" && echo ended || echo waiting)/$(lines "$(printf 'revoked\t-\t0000000000000a09')")" "waiting/0" \
    "[K1] while another process holds the lock, the writer waits and has written no line"
  : > "$R/release"; wait "$HP"; wait "$WP"
  eq "$(cat "$R/rc")/$(tr -d '\r' < "$R/out")" "0/grant 0000000000000a09 revoked: the charter for P9 ended" "[K1] released: the writer goes on, rc 0"
  eq "$(lines "$(printf 'revoked\t-\t0000000000000a09')")" 1 "[K1] …and its line is in the log once"
fi
charter P10 0000000000000a10
R="$TMP/k2"; mkdir -p "$R"
holder "$R/ready" "$R/never" & HP=$!
if ! await "$R/ready"; then
  bad "[K2] instrument: the test's holder never took the lock"
else
  if MSYS_NO_PATHCONV=1 taskkill /F /PID "$(cat "$R/ready")" >/dev/null 2>&1; then wait "$HP" 2>/dev/null   # ended at once, as a crash
  else bad "[K2] instrument: taskkill did not end the test's holder (pid $(cat "$R/ready"))"; : > "$R/never"; wait "$HP"; fi
  eq "$(bt grant revoke --focus P10)" "$(printf 'grant 0000000000000a10 revoked: the charter for P10 ended\nrc=0')" \
    "[K2] a holder killed while it holds the lock: Windows releases it, the next writer goes on"
  eq "$(lines "$(printf 'revoked\t-\t0000000000000a10')")" 1 "[K2] …and its line is in the log once"
fi
R="$TMP/k3"; mkdir -p "$R"
before=$(grep -c '' "$ST/log.tsv")
for n in a b; do
  (cd "$W" && python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import baton
d = baton.ensure_state()
for i in range(100):
    baton.log_event(d, event="grant", result="revoked", output="writer-%s-%03d" % (sys.argv[2], i))' "$(win "$PL/scripts")" "$n" > "$R/$n" 2>&1) &
done
wait
eq "$(cat "$R/a" "$R/b")" "" "[K3] instrument: both writers ran without an error"
eq "$(( $(grep -c '' "$ST/log.tsv") - before ))/$(grep -c -E $'\trevoked\t-\twriter-[ab]-[0-9]{3}\t-$' "$ST/log.tsv")" "200/200" \
  "[K3] two writers at once, 100 lines each: all 200 lines are in the log, each whole"
charter P11 0000000000000a11
R="$TMP/k4"; mkdir -p "$R"
holder "$R/ready" "$R/release" & HP=$!
if ! await "$R/ready"; then
  bad "[K4] instrument: the test's holder never took the lock"
else
  O=$(bt grant revoke --focus P11); : > "$R/release"; wait "$HP"
  has "$O" "grant 0000000000000a11: the revoke line cannot be written to the log (" "[K4] the lock held past the wait: the log line is not written, and it says so"
  has "$O" "grant 0000000000000a11 revoked: the charter for P11 ended" "[K4] …the charter still ends, through its revoke file"
  eq "${O##*rc=}" 0 "[K4] …rc 0"
  has "$(bt log --grants)" "0000000000000a11" "[K4] instrument: log --grants still lists it"
  has "$(bt grant revoke --focus P11)" "no charter in force for P11 from " "[K4] …and it is no longer in force"
fi

echo "== [P] what does not run on Windows yet: one plain line =="
SEAL=0123456789abcdef.0123456789abcdef
printf '#!/usr/bin/env bash\n' > "$W/act.sh"
for c in "go kit:soul-line --file $(win "$W/SOUL.md") --code S1 --action add --text t" "go --queue kit:soul-line" "run $(win "$W/act.sh")" \
         "rehearse $(win "$W/act.sh")" "check $(win "$W/act.sh")" "new act --dir $(win "$W")" "pack $(win "$W/act.sh") project:act" \
         "sign --by coordinator-auto --seal $SEAL $(win "$W/act.sh")" "sign --by owner --seal $SEAL kit:soul-line"; do
  # shellcheck disable=SC2086
  eq "$(cbt $c)" "$(printf 'baton: %s %s\nrc=2' "${c%% *}" "$ONE_LINE")" "[P1] ${c%% *} ($c): one plain line, rc 2"
done
for c in "mode auto|mode auto" "mode manual|mode manual" "mode trust github.com/a/b|mode trust" "permissions --print|permissions --print" \
         "permissions --install-launcher|permissions --install-launcher"; do
  # shellcheck disable=SC2086
  eq "$(cbt ${c%|*})" "$(printf 'baton: %s %s\nrc=2' "${c#*|}" "$ONE_LINE")" "[P2] ${c%|*}: one plain line, rc 2"
done
eq "$(test -e "$ST/mode" && echo mode-file || echo none)/$(test -e "$ST/bin/baton" && echo launcher || echo none)" "none/none" \
  "[P2] …no mode file and no launcher written"
eq "$(cbt permissions --check)" "$(printf 'baton permissions: the permission rules serve signed runs, which do not run on Windows yet: nothing to check\nrc=0')" \
  "[P3] permissions --check: one line, rc 0"
guard() {  # guard <command> — the owner hook (hooks.json's baton-guard.py through pyrun.sh) on a Bash call of <command>
  (cd "$W" && python3 -c 'import json, sys
print(json.dumps({"session_id": "s1", "hook_event_name": "PreToolUse", "tool_name": "Bash", "permission_mode": "default",
                  "cwd": sys.argv[1], "tool_input": {"command": sys.argv[2]}}))' "$(win "$W")" "$1" \
    | CLAUDE_PLUGIN_ROOT="$PL" capped /bin/sh "$PL/scripts/pyrun.sh" scripts/baton-guard.py 2>&1 | tr -d '\r')
}
DENY="the owner's dialog does not run on Windows yet (signed runs and the owner's dialog run on Linux and macOS, inside a \`claude\` session in a terminal, Claude Code's VS Code extension or the Claude desktop app)"
O=$(guard "python3 $(cygpath -m "$PL/scripts/baton.py") sign --by owner --seal $SEAL kit:soul-line")
eq "$(dec "$O")|$(why "$O")" "deny|baton: sign --by owner refused: $DENY" "[P4] the owner hook on sign --by owner: deny, one plain line"
O=$(guard "python3 $(cygpath -m "$PL/scripts/baton.py") mode auto")
eq "$(dec "$O")|$(why "$O")" "deny|baton: mode refused: $DENY" "[P4] the owner hook on a mode change: deny, one plain line"
eq "$(ls "$ST/asked" 2>/dev/null | wc -l | tr -d ' ')" 0 "[P4] …and no owner record is written"
summary
