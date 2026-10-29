#!/bin/bash
# =============================================================================
# The update reminder at session start: scripts/update_check.py of vibemaestro-sdlc, run by sdlc and by brain
# =============================================================================
# Run: bash tests/test-update-check.sh
#
# The hook is run as Claude Code runs it: the `command` of the plugin's hooks/hooks.json SessionStart entry (lib.sh's rule), with
# CLAUDE_PLUGIN_ROOT and CLAUDE_PLUGIN_DATA set. Each plugin is a copy of the real one whose manifest is given the export's form
# (`version` and `repository`), or not. The public repository is a fake GitHub API on 127.0.0.1 (VIBEMAESTRO_UPDATE_CHECK_API is
# honoured only for a loopback URL): it answers the one read from a file the suite writes, logs every request with its headers,
# and can delay, fail or redirect. No real network.
#   [N] newer, equal, older: the line only for a newer version, exactly one `systemMessage`, nothing for Claude's context
#   [C] the 24 h cache: one read and one line per 24 h; the line at the next session after the background read
#   [S] every silent case: no version, no or a bad repository, a pod, each opt-out, no data directory, the server down, an error,
#       a redirect, a body that is not the expected JSON or too big
#   [T] the timeout: a server that hangs ends the read within about 2 s; the hook returns at once while a read is due
#   [H] hostile tags and a hostile cache never reach the message
#   [P] privacy: the request carries no token, no cookie, nothing about the user; the API override is honoured only on loopback
#   [B] brain: the same reminder through sdlc's code, naming brain; silent without sdlc and under BRAIN_OFF
#   [X] planted breaks: each guard goes red on a copy with it removed
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
# shellcheck source=fixtures/ports.sh
. "$HERE/fixtures/ports.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
BRAIN="$SRC_ROOT/plugins/vibemaestro-brain"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
SRV_PID=""
trap '[ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null; rm -rf "$TMP"' EXIT
clean_env "$TMP"
export PYTHONDONTWRITEBYTECODE=1
unset VIBEMAESTRO_NO_UPDATE_CHECK CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC VIBEMAESTRO_UPDATE_CHECK_API CLAUDE_PLUGIN_DATA BRAIN_OFF \
      http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
REPO_URL="https://github.com/acme/kit"
DAY=86400

# ── the fake public repository ─────────────────────────────────────────────────────────────────────────────────────────
FAKE="$TMP/fake"; mkdir -p "$FAKE"
cat > "$FAKE/server.py" <<'PY'
import http.server, json, os, sys, time
d = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass
    def do_GET(self):
        with open(os.path.join(d, "log"), "a") as f:
            f.write(json.dumps({"path": self.path, "headers": dict(self.headers.items())}) + "\n")
        try:
            c = json.load(open(os.path.join(d, "conf.json")))
        except (OSError, ValueError):
            c = {"status": 404, "body": ""}
        time.sleep(c.get("delay", 0))
        body = c.get("body", "")
        if body.startswith("@"):                   # a body too long for an argument: read from that file
            body = open(body[1:]).read()
        body = (body if isinstance(body, str) else json.dumps(body)).encode() * c.get("repeat", 1)
        self.send_response(c.get("status", 200))
        if c.get("location"):
            self.send_header("Location", c["location"])
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            if c.get("drip"):                  # the body one byte at a time: no socket timeout ever fires, only a deadline
                for i in range(len(body)):
                    self.wfile.write(body[i:i + 1]); self.wfile.flush(); time.sleep(c["drip"])
            else:
                self.wfile.write(body)
        except OSError:
            pass
s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
s.daemon_threads = True
open(os.path.join(d, "port.tmp"), "w").write(str(s.server_address[1]))
os.rename(os.path.join(d, "port.tmp"), os.path.join(d, "port"))
s.serve_forever()
PY
python3 "$FAKE/server.py" "$FAKE" >/dev/null 2>&1 & SRV_PID=$!
for _ in $(seq 1 100); do [ -s "$FAKE/port" ] && break; sleep 0.05; done
PORT=$(cat "$FAKE/port" 2>/dev/null)
API="http://127.0.0.1:$PORT"
# a port nothing listens on: bound once and closed, so it is free
DEAD=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')

# srv <body (JSON text)> [status] [delay s] [location] [repeat] [drip s] — what the next request gets; the request log is emptied
srv() {
  python3 - "$FAKE/conf.json" "$1" "${2:-200}" "${3:-0}" "${4:-}" "${5:-1}" "${6:-0}" <<'PY'
import json, sys
p, body, status, delay, loc, rep, drip = sys.argv[1:8]
json.dump({"body": body, "status": int(status), "delay": float(delay), "location": loc, "repeat": int(rep), "drip": float(drip)},
          open(p, "w"))
PY
  : > "$FAKE/log"
}
# tags <plugin> <version>… — a matching-refs answer holding refs/tags/<plugin>--v<version> for each (the text after the plugin as is)
tags() {
  python3 - "$@" <<'PY'
import json, sys
p = sys.argv[1]
print(json.dumps([{"ref": "refs/tags/%s--v%s" % (p, v), "object": {"sha": "0" * 40, "type": "tag"}} for v in sys.argv[2:]]))
PY
}
nreq() { if [ -s "$FAKE/log" ]; then wc -l < "$FAKE/log" | tr -d ' '; else echo 0; fi; }
# wait_req <n> — until the server logged n requests (5 s at most)
wait_req() { local i; for i in $(seq 1 100); do [ "$(nreq)" -ge "$1" ] && return 0; sleep 0.05; done; return 1; }
# wait_latest <data> <version> — until the cache holds that latest (5 s at most)
wait_latest() { local i; for i in $(seq 1 100); do [ "$(cget "$1" latest)" = "$2" ] && return 0; sleep 0.05; done; return 1; }
cget() { python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1] + "/update-check.json")).get(sys.argv[2]))
except Exception: print("-")' "$1" "$2"; }
# age <data> <field> <seconds> — the cache's checked or shown set that many seconds in the past
age() { python3 - "$1/update-check.json" "$2" "$3" <<'PY'
import json, sys, time
p, k, s = sys.argv[1:4]
d = json.load(open(p)); d[k] = int(time.time()) - int(s); json.dump(d, open(p, "w"))
PY
}
# seed <data> <latest> [plugin] — a cache of <plugin> (default sdlc) and REPO_URL read just now that says <latest> (raw JSON
# value), never shown
seed() { mkdir -p "$1"; printf '{"v": 1, "checked": %s, "latest": %s, "shown": 0, "repo": "%s", "plugin": "%s"}\n' \
           "$(date +%s)" "$2" "$REPO_URL" "${3:-vibemaestro-sdlc}" > "$1/update-check.json"; }

# mkp <dir> <source plugin> <name> <version|-> <repository|-> — a copy of the plugin; its manifest in the export's form
mkp() {
  rm -rf "$1"; mkdir -p "$(dirname "$1")"; cp -R "$2" "$1"; find "$1" -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null
  python3 - "$1/.claude-plugin/plugin.json" "$3" "$4" "$5" <<'PY'
import json, sys
p, name, v, repo = sys.argv[1:5]
m = json.load(open(p)); m["name"] = name
m.pop("version", None); m.pop("repository", None)
if v != "-":
    m["version"] = v
if repo != "-":
    m["repository"] = repo
json.dump(m, open(p, "w"), indent=2)
PY
}
# hookcmd <plugin root> — the update-check command of its hooks.json SessionStart entries
hookcmd() { hook_cmds "$1/hooks/hooks.json" SessionStart "" | grep -F 'update' ; }
# us <plugin root> <data|-> [env assignments…] — one session start: OUT stdout, ERR stderr, RC, MS its wall time (the payload is a
# here-string, not a pipe: a hook that exits without reading stdin would turn a pipe's SIGPIPE into rc 141 under pipefail)
us() {
  local root=$1 data=$2 c t0; shift 2
  c=$(hookcmd "$root")
  APP="$TMP/app"; mkdir -p "$APP"
  t0=$(python3 -c 'import time; print(int(time.time()*1000))')
  if [ "$data" = - ]; then
    OUT=$(env -u CLAUDE_PLUGIN_DATA CLAUDE_PLUGIN_ROOT="$root" CLAUDE_PROJECT_DIR="$APP" \
          VIBEMAESTRO_UPDATE_CHECK_API="$API" "$@" bash -c "$c" 2>"$TMP/err" <<<"$(p_start "$(sid)")"); RC=$?
  else
    mkdir -p "$data"
    OUT=$(env CLAUDE_PLUGIN_ROOT="$root" CLAUDE_PLUGIN_DATA="$data" CLAUDE_PROJECT_DIR="$APP" \
          VIBEMAESTRO_UPDATE_CHECK_API="$API" "$@" bash -c "$c" 2>"$TMP/err" <<<"$(p_start "$(sid)")"); RC=$?
  fi
  MS=$(( $(python3 -c 'import time; print(int(time.time()*1000))') - t0 ))
  ERR=$(cat "$TMP/err")
}
# keys <json> — the top-level keys, sorted, comma-separated
keys() { printf '%s' "$1" | python3 -c 'import json,sys; print(",".join(sorted(json.loads(sys.stdin.read()))))' 2>/dev/null; }
# printable <text> — "yes" when every character is printable ASCII
printable() { printf '%s' "$1" | python3 -c 'import sys; t = sys.stdin.read(); print("yes" if all(32 <= ord(c) < 127 for c in t) else "no")'; }
# refresh <sdlc plugin root> <plugin root> <data> — the background read, run in the foreground: RC, MS
refresh() {
  local t0; t0=$(python3 -c 'import time; print(int(time.time()*1000))')
  env VIBEMAESTRO_UPDATE_CHECK_API="$API" python3 "$1/scripts/update_check.py" refresh --root "$2" --data "$3" >/dev/null 2>&1; RC=$?
  MS=$(( $(python3 -c 'import time; print(int(time.time()*1000))') - t0 ))
}
# quiet <label> <plugin root> <data|-> [env…] — a session start that must print nothing, exit 0 and read nothing
quiet() {
  local label=$1 before; shift
  before=$(cat "$2/update-check.json" 2>/dev/null | cksum)
  : > "$FAKE/log"; us "$@"; sleep 0.3
  eq "$RC:$OUT" "0:" "$label: rc 0, nothing printed"
  eq "$(nreq)" 0 "$label: no request"
  [ "$2" = - ] || eq "$(cat "$2/update-check.json" 2>/dev/null | cksum)" "$before" "$label: the cache untouched (no read was started)"
}

fam_uc() { local S=$1 P D V
  P="$TMP/p/vibemaestro-sdlc"
  # ── [N] newer, equal, older ──
  mkp "$P" "$S" vibemaestro-sdlc 0.2.0 "$REPO_URL"; D=$(fresh)/data
  srv "$(tags vibemaestro-sdlc 0.1.0 0.2.0 0.10.0 0.9.9)"
  us "$P" "$D"
  eq "$RC:$OUT" "0:" "[N1] first session: rc 0, nothing printed yet (the read runs in the background)"
  wait_req 1 && ok "[N1] …the background read reached the server" || bad "[N1] …no request reached the server"
  wait_latest "$D" 0.10.0 && ok "[N1] …the cache holds latest 0.10.0 (numbers, not text: 0.10.0 > 0.9.9)" || bad "[N1] …the cache latest is $(cget "$D" latest)"
  us "$P" "$D"
  eq "$RC" 0 "[N2] next session: rc 0"
  eq "$(keys "$OUT")" "systemMessage" "[N2] …exactly one JSON object whose only key is systemMessage (nothing for Claude's context)"
  eq "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" 1 "[N2] …one line of output"
  V=$(sysm "$OUT")
  eq "$V" "vibemaestro-sdlc 0.10.0 is available (installed 0.2.0): run /plugin, update it from Marketplaces, then /reload-plugins. Release notes: $REPO_URL/releases/tag/vibemaestro-sdlc--v0.10.0" \
    "[N2] …the line names the plugin, both versions, /plugin, /reload-plugins and the release notes"
  sleep 0.5; eq "$(nreq)" 1 "[N2] …and no second read within 24 h"
  us "$P" "$D"
  eq "$RC:$OUT" "0:" "[C1] a third session within 24 h: nothing (one line per 24 h)"
  eq "$(nreq)" 1 "[C1] …and still one read"
  age "$D" shown $((DAY + 60))
  us "$P" "$D"
  nonempty "$(sysm "$OUT")" "[C2] shown 24 h ago, checked recently: the line again"
  eq "$(nreq)" 1 "[C2] …from the cache, no read"
  age "$D" checked $((DAY + 60)); srv "$(tags vibemaestro-sdlc 0.11.0)"
  us "$P" "$D"
  eq "$OUT" "" "[C3] checked 24 h ago, shown recently: nothing printed"
  wait_req 1 && ok "[C3] …and a new read" || bad "[C3] …no new read after 24 h"
  wait_latest "$D" 0.11.0 && ok "[C3] …the cache moves to 0.11.0" || bad "[C3] …the cache latest is $(cget "$D" latest)"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["checked"] += 10 * 86400; json.dump(d, open(sys.argv[1], "w"))' "$D/update-check.json"
  srv "$(tags vibemaestro-sdlc 0.11.0)"; us "$P" "$D"
  wait_req 1 && ok "[C4] a check time in the future counts as due (a clock moved back)" || bad "[C4] a future check time stopped the reads"
  mkp "$P" "$S" vibemaestro-sdlc 0.2.0 "$REPO_URL"; D=$(fresh)/data
  srv "$(tags vibemaestro-sdlc 0.1.0 0.2.0)"; us "$P" "$D"; wait_latest "$D" 0.2.0 || bad "[N3] the read did not land"
  us "$P" "$D"; eq "$RC:$OUT" "0:" "[N3] the installed version is the latest: nothing"
  mkp "$P" "$S" vibemaestro-sdlc 0.3.0 "$REPO_URL"; us "$P" "$D"; eq "$RC:$OUT" "0:" "[N4] the installed version is newer than the latest: nothing"
  echo '{"v": 1, "checked": 0, "latest": null, "shown": 0, "junk": [' > "$D/update-check.json"
  srv "$(tags vibemaestro-sdlc 0.4.0)"; us "$P" "$D"
  eq "$RC:$OUT" "0:" "[N5] a broken cache file: rc 0, nothing printed"
  wait_latest "$D" 0.4.0 && ok "[N5] …it is rewritten by the next read" || bad "[N5] …the broken cache stayed"

  D=$(fresh)/data; seed "$D" '"0.3.0"'; age "$D" checked $((DAY + 60)); srv '[]'; us "$P" "$D"
  wait_req 1 || bad "[N6] no read"; sleep 0.5
  eq "$(cget "$D" latest)" "None" "[N6] a read whose answer holds no tag of the plugin clears the cached latest (a deleted tag is not shown)"
  D=$(fresh)/data; mkdir -p "$D"; srv "$(tags vibemaestro-sdlc 0.3.0)" 200 1
  local pids=() i; for i in 1 2 3 4 5 6; do us "$P" "$D" & pids+=($!); done; wait "${pids[@]}"; sleep 1.5
  eq "$(nreq)" 1 "[C5] smoke: six sessions starting at once, one read (the lock itself is [C6] and [C8])"
  D=$(fresh)/data; mkdir -p "$D"; : > "$D/update-check.lock"; srv "$(tags vibemaestro-sdlc 0.3.0)"; us "$P" "$D"; sleep 0.5
  eq "$RC:$OUT:$(nreq)" "0::0" "[C6] a read due while another session's read holds the lock: no second read"
  seed "$D" '"9.9.9"'; age "$D" checked $((DAY + 60)); before=$(cksum < "$D/update-check.json"); : > "$D/update-check.lock"; us "$P" "$D"; sleep 0.5
  eq "$RC:$OUT:$(nreq)" "0::0" "[C8] another session holds the lock, the cache says newer and due: nothing printed, no read"
  eq "$(cksum < "$D/update-check.json")" "$before" "[C8] …and the cache untouched (a session that loses the lock writes nothing)"
  rm -f "$D/update-check.json"
  touch -d '-120 seconds' "$D/update-check.lock"; us "$P" "$D"
  wait_req 1 && ok "[C7] a lock left by a read that died (2 min old) is taken over: the read runs" || bad "[C7] a stale lock stopped the reads"
  wait_latest "$D" 0.3.0 && [ ! -e "$D/update-check.lock" ] && ok "[C7] …and the read releases the lock when it ends" || bad "[C7] …the lock stayed or the read did not land"
  # ── [S] silent cases: each with a cache that says 9.9.9 (nothing may show it) and with no cache (nothing may read) ──
  srv "$(tags vibemaestro-sdlc 9.9.9)"
  mkp "$P" "$S" vibemaestro-sdlc - "$REPO_URL"
  D=$(fresh)/data; seed "$D" '"9.9.9"'; quiet "[S1] no version in the manifest (a private install), cache says newer" "$P" "$D"
  D=$(fresh)/data; quiet "[S1] …no cache" "$P" "$D"
  for R in - "http://github.com/acme/kit" "https://example.com/acme/kit" "https://github.com/acme/kit/extra" "https://github.com/acme/.." \
           "https://github.com/acme/kit?x=1" "https://github.com/-acme/kit" "https://github.com/ac me/kit"; do
    mkp "$P" "$S" vibemaestro-sdlc 0.2.0 "$R"
    D=$(fresh)/data; seed "$D" '"9.9.9"'; quiet "[S2] repository '$R'" "$P" "$D"
  done
  mkp "$P" "$S" vibemaestro-sdlc 0.2.0 "$REPO_URL"
  D=$(fresh)/data; seed "$D" '"9.9.9"'; quiet "[S3] a sandbox pod (INTENT_SLUG and SEAT)" "$P" "$D" INTENT_SLUG=x SEAT=y
  D=$(fresh)/data; quiet "[S3] …no cache" "$P" "$D" INTENT_SLUG=x SEAT=y
  D=$(fresh)/data; seed "$D" '"9.9.9"'; quiet "[S4] VIBEMAESTRO_NO_UPDATE_CHECK=1" "$P" "$D" VIBEMAESTRO_NO_UPDATE_CHECK=1
  D=$(fresh)/data; quiet "[S4] …no cache" "$P" "$D" VIBEMAESTRO_NO_UPDATE_CHECK=1
  D=$(fresh)/data; seed "$D" '"9.9.9"'; quiet "[S5] CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1" "$P" "$D" CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
  D=$(fresh)/data; quiet "[S5] …no cache" "$P" "$D" CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
  mkdir -p "$TMP/app/.vibemaestro"
  for c in '{"schema": 1, "update_check": false}' '{"schema": 1, "hooks": "off"}'; do
    printf '%s\n' "$c" > "$TMP/app/.vibemaestro/sdlc.json"
    D=$(fresh)/data; seed "$D" '"9.9.9"'; quiet "[S6] config $c" "$P" "$D"
    D=$(fresh)/data; quiet "[S6] …no cache" "$P" "$D"
  done
  for c in '{"schema": 1, "update_check": false}' '{"schema": 1, "hooks": "off"}'; do
    printf '%s\n' "$c" > "$TMP/app/.vibemaestro/sdlc.json"; mkdir -p "$TMP/app/sub/deeper"
    D=$(fresh)/data; seed "$D" '"9.9.9"'; quiet "[S11] config $c, the session started in a subdirectory" "$P" "$D" CLAUDE_PROJECT_DIR="$TMP/app/sub/deeper"
    D=$(fresh)/data; quiet "[S11] …no cache" "$P" "$D" CLAUDE_PROJECT_DIR="$TMP/app/sub/deeper"
  done
  rm -rf "$TMP/app/.vibemaestro" "$TMP/app/sub"
  quiet "[S7] no CLAUDE_PLUGIN_DATA" "$P" -
  D=$(fresh)/data; seed "$D" '"9.9.9"'; us "$P" "$D"
  has "$(sysm "$OUT")" "9.9.9 is available" "[S0] control: the seeded cache, with nothing turning it off, shows the line"
  D=$(fresh)/data; seed "$D" '"9.9.9"'; us "$P" "$D" VIBEMAESTRO_NO_UPDATE_CHECK=0
  nonempty "$(sysm "$OUT")" "[S8] control: VIBEMAESTRO_NO_UPDATE_CHECK=0 does not turn it off"
  D=$(fresh)/data; seed "$D" '"9.9.9"'; age "$D" checked $((DAY + 60)); printf 'x' > "$D/update-check.json.lock" 2>/dev/null
  chmod 0500 "$D"; us "$P" "$D"; chmod 0700 "$D"
  eq "$RC" 0 "[S9] a data directory it cannot write: rc 0 (the session never fails)"
  # the read fails in every way: the cache keeps latest null, nothing printed later, the refresh exits 0
  for c in "dead" "500" "notjson" "object" "redirect" "big"; do
    D=$(fresh)/data; mkdir -p "$D"
    case $c in
      dead) API_SAVE=$API; API="http://127.0.0.1:$DEAD";;
      500) srv "$(tags vibemaestro-sdlc 9.9.9)" 500;;
      notjson) srv '[{"ref": "refs/tags/vibemaestro-sdlc--v9.9.9"';;
      object) srv '{"ref": "refs/tags/vibemaestro-sdlc--v9.9.9"}';;
      redirect) srv "$(tags vibemaestro-sdlc 9.9.9)" 302 0 "/elsewhere";;
      big) python3 -c 'import json; print(json.dumps([{"ref": "refs/tags/vibemaestro-sdlc--v9.9.9"}] * 6000))' > "$FAKE/big.json"
           srv "@$FAKE/big.json";;
    esac
    refresh "$S" "$P" "$D"
    eq "$RC" 0 "[S10] read fails ($c): the refresh exits 0"
    eq "$(cget "$D" latest)" "-" "[S10] …($c) no latest written"
    us "$P" "$D"; eq "$RC:$OUT" "0:" "[S10] …($c) and the next session prints nothing"
    [ "$c" = redirect ] && eq "$(grep -c elsewhere "$FAKE/log")" 0 "[S10] …(redirect) not followed"
    [ "$c" = dead ] && API=$API_SAVE
  done

  # ── [T] the timeout ──
  D=$(fresh)/data; mkdir -p "$D"; srv "$(tags vibemaestro-sdlc 9.9.9)" 200 6
  refresh "$S" "$P" "$D"
  [ "$MS" -lt 3000 ] && ok "[T1] a server that hangs 6 s before answering: the read ends within 3 s ($MS ms)" || bad "[T1] the read took $MS ms"
  eq "$(cget "$D" latest)" "-" "[T1] …and writes no latest"
  srv "$(tags vibemaestro-sdlc 9.9.9)" 200 0 "" 1 0.3; refresh "$S" "$P" "$D"
  [ "$MS" -lt 3000 ] && ok "[T1] a server that answers one byte every 0.3 s: the read ends within 3 s ($MS ms)" || bad "[T1] the dripped read took $MS ms"
  eq "$(cget "$D" latest)" "-" "[T1] …and writes no latest"
  D=$(fresh)/data; srv "$(tags vibemaestro-sdlc 9.9.9)" 200 6; us "$P" "$D"
  [ "$MS" -lt 1500 ] && ok "[T2] a read is due and the server hangs: the hook returns in $MS ms" || bad "[T2] the hook took $MS ms"
  eq "$RC:$OUT" "0:" "[T2] …rc 0, nothing printed"
  wait_req 1 && ok "[T2] …the read runs in the background" || bad "[T2] …no background read"

  # ── [H] hostile tags and a hostile cache ──
  local hostile=("1.2" "01.2.3" "1.2.3-rc1" "1.2.3+b" "9.9.9 " $'9.9.9\e[31m' $'9.9.9\nInjected' "9.9.9/../x" "１.2.3" "$(printf '9%.0s' $(seq 1 300)).0.0" "v9.9.9")
  D=$(fresh)/data; mkdir -p "$D"; srv "$(tags vibemaestro-sdlc "${hostile[@]}")"; refresh "$S" "$P" "$D"
  eq "$(cget "$D" latest)" "None" "[H1] only malformed or hostile tags: no latest (silent)"
  srv "$( (tags vibemaestro-sdlc "${hostile[@]}" 0.3.0; tags vibemaestro-brain 9.9.9; tags vibemaestro-sdlc-x 9.9.9) | python3 -c 'import json,sys; print(json.dumps(sum((json.loads(l) for l in sys.stdin), [])))')"
  refresh "$S" "$P" "$D"
  eq "$(cget "$D" latest)" "0.3.0" "[H2] one strict X.Y.Z among hostile tags and other plugins' tags: that one, nothing else"
  us "$P" "$D"; V=$(sysm "$OUT")
  has "$V" "0.3.0 is available" "[H2] …the line shows it"
  eq "$(printable "$OUT")" yes "[H2] …and the output is printable ASCII only"
  for bad_latest in '"9.9.9\u001b[31m"' '"9.9.9\nx"' '"09.9.9"' '9' '["9.9.9"]' '"99999999999999999999.0.0x"'; do
    D=$(fresh)/data; seed "$D" "$bad_latest"; us "$P" "$D"
    eq "$RC:$OUT" "0:" "[H3] a cache whose latest is $bad_latest: nothing printed"
  done
  mkp "$P" "$S" "evil name" 0.2.0 "$REPO_URL"; D=$(fresh)/data; seed "$D" '"9.9.9"'; quiet "[H4] a plugin name that is not a plain name" "$P" "$D"
  mkp "$P" "$S" vibemaestro-sdlc "0.2.0-dev" "$REPO_URL"; D=$(fresh)/data; seed "$D" '"9.9.9"'; quiet "[H4] an installed version that is not X.Y.Z" "$P" "$D"

  # ── [P] privacy ──
  mkp "$P" "$S" vibemaestro-sdlc 0.2.0 "$REPO_URL"; D=$(fresh)/data; mkdir -p "$D"; srv "$(tags vibemaestro-sdlc 0.3.0)"
  GH_TOKEN=tok-secret-1 GITHUB_TOKEN=tok-secret-2 refresh "$S" "$P" "$D"
  python3 - "$FAKE/log" > "$TMP/req" <<'PY'
import json, sys
r = [json.loads(l) for l in open(sys.argv[1])]
print(len(r)); print(r[0]["path"]); print(",".join(sorted(k.lower() for k in r[0]["headers"]))); print(r[0]["headers"].get("User-Agent"))
PY
  eq "$(sed -n 1p "$TMP/req")" 1 "[P1] one request"
  eq "$(sed -n 2p "$TMP/req")" "/repos/acme/kit/git/matching-refs/tags/vibemaestro-sdlc--v" "[P1] …the plugin's tag prefix in the repository the manifest names, no query"
  eq "$(sed -n 3p "$TMP/req")" "accept,accept-encoding,connection,host,user-agent" "[P1] …no Authorization, no Cookie, no other header"
  eq "$(sed -n 4p "$TMP/req")" "vibemaestro-update-check" "[P1] …a fixed User-Agent (no version, user or machine)"
  hasnt "$(cat "$FAKE/log")" "secret" "[P1] …no token from the environment"
  D=$(fresh)/data; mkdir -p "$D"; srv "$(tags vibemaestro-sdlc 0.3.0)"
  http_proxy="http://127.0.0.1:$DEAD" HTTP_PROXY="http://127.0.0.1:$DEAD" refresh "$S" "$P" "$D"
  eq "$(cget "$D" latest)" "0.3.0" "[P3] a proxy in the environment is not used for the loopback override"
  for a in "http://example.com:1" "https://127.0.0.1:1" "http://127.0.0.1:1/x" "http://localhost:1" "http://127.0.0.2:1" "http://127.0.0.1:1@example.com"; do
    eq "$(VIBEMAESTRO_UPDATE_CHECK_API="$a" python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import update_check; print(update_check.api_base())' "$S/scripts")" \
      "https://api.github.com" "[P2] VIBEMAESTRO_UPDATE_CHECK_API=$a is ignored (only http://127.0.0.1:<port>)"
  done
  eq "$(VIBEMAESTRO_UPDATE_CHECK_API="http://127.0.0.1:8080" python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import update_check; print(update_check.api_base())' "$S/scripts")" \
    "http://127.0.0.1:8080" "[P2] control: a loopback override is honoured"
}

fam_brain() { local S=$1 B="$TMP/b/plugins/vibemaestro-brain" Q="$TMP/b/plugins/vibemaestro-sdlc" D
  rm -rf "$TMP/b"; mkp "$Q" "$S" vibemaestro-sdlc 0.2.0 "$REPO_URL"; mkp "$B" "$BRAIN" vibemaestro-brain 0.2.0 "$REPO_URL"
  D=$(fresh)/data; srv "$(tags vibemaestro-brain 0.5.0)"
  us "$B" "$D"
  eq "$RC:$OUT" "0:" "[B1] brain, first session: nothing printed"
  wait_latest "$D" 0.5.0 && ok "[B1] …brain's own read lands in brain's data directory" || bad "[B1] …brain's cache latest is $(cget "$D" latest)"
  has "$(cat "$FAKE/log")" "/tags/vibemaestro-brain--v" "[B1] …asking for brain's tags"
  us "$B" "$D"
  eq "$(sysm "$OUT")" "vibemaestro-brain 0.5.0 is available (installed 0.2.0): run /plugin, update it from Marketplaces, then /reload-plugins. Release notes: $REPO_URL/releases/tag/vibemaestro-brain--v0.5.0" \
    "[B2] brain's line names brain"
  eq "$(keys "$OUT")" "systemMessage" "[B2] …and only systemMessage"
  D=$(fresh)/data; seed "$D" '"9.9.9"' vibemaestro-brain; us "$B" "$D"
  has "$(sysm "$OUT")" "vibemaestro-brain 9.9.9 is available" "[B0] control: brain's seeded cache shows the line"
  D=$(fresh)/data; seed "$D" '"9.9.9"' vibemaestro-brain; srv "$(tags vibemaestro-brain 9.9.9)"; quiet "[B3] BRAIN_OFF" "$B" "$D" BRAIN_OFF=1
  D=$(fresh)/data; seed "$D" '"9.9.9"' vibemaestro-brain; quiet "[B3] a pod" "$B" "$D" INTENT_SLUG=x SEAT=y
  mkp "$TMP/b/plugins/vibemaestro-brain" "$BRAIN" vibemaestro-brain - "$REPO_URL"
  D=$(fresh)/data; seed "$D" '"9.9.9"' vibemaestro-brain; quiet "[B3] brain with no version" "$B" "$D"
  rm -rf "$TMP/solo"; mkp "$TMP/solo/vibemaestro-brain" "$BRAIN" vibemaestro-brain 0.2.0 "$REPO_URL"
  D=$(fresh)/data; seed "$D" '"9.9.9"' vibemaestro-brain; quiet "[B4] brain without sdlc anywhere" "$TMP/solo/vibemaestro-brain" "$D"
  eq "$ERR" "" "[B4] …and nothing on stderr"
}

echo "== sdlc =="; fam_uc "$PLUGIN"
echo "== brain =="; fam_brain "$PLUGIN"

echo "== [X] planted breaks =="
BRK() {  # BRK <label> <family> <needle> <file under scripts/> <old> <new> — a copy of sdlc with one break
  local d="$TMP/break-$1/vibemaestro-sdlc"; mkdir -p "$(dirname "$d")"; cp -R "$PLUGIN" "$d"
  mutate "$d/scripts/$4" "$5" "$6" && expect_red "$1" "$2" "$d" "$3"
}
BRK no-semver fam_uc "[H2]" update_check.py 'SEMVER = re.compile(r"(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})", re.ASCII)' 'SEMVER = re.compile(r"(.+)\.(.+)\.(.+)", re.S)'
BRK no-pod fam_uc "[S3]" update_check.py 'if os.environ.get("INTENT_SLUG") and os.environ.get("SEAT"):' 'if False:'
BRK no-optout fam_uc "[S4]" update_check.py 'if optout("VIBEMAESTRO_NO_UPDATE_CHECK")' 'if False'
BRK no-cache fam_uc "[N2] …and no second read" update_check.py '    return not 0 <= now - cache["checked"] < DAY' '    return True'
BRK no-claim fam_uc "[C8]" update_check.py '    if not claim(data, now):' '    if False:'
BRK keeps-stale-latest fam_uc "[N6]" update_check.py 'if t.is_alive() or not got.get("answer"):' 'if t.is_alive() or not got.get("latest"):'
BRK loopback-proxy fam_uc "[P3]" update_check.py 'handlers.insert(0, urllib.request.ProxyHandler({}))' 'handlers.insert(0, urllib.request.ProxyHandler())'
BRK no-walk-up fam_uc "[S11]" update_check.py '    root = project_root()' '    root = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()'
BRK no-deadline fam_uc "[T1]" update_check.py 't.join(DEADLINE)' 't.join()'
BRK follows-redirect fam_uc "[S10] …(redirect)" update_check.py '        raise urllib.error.HTTPError(req.full_url, code, "redirect refused", headers, fp)' '        return urllib.request.HTTPRedirectHandler.redirect_request(self, req, fp, code, msg, headers, newurl)'
BRK any-api fam_uc "[P2]" update_check.py 'if LOOPBACK.fullmatch(v):' 'if v:'
BRK no-version-gate fam_uc "[S1]" update_check.py 'if not SEMVER.fullmatch(installed or ""):' 'if False:'

echo; summary
