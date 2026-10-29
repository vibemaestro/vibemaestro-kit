#!/bin/bash
# =============================================================================
# Hook latency: the median of pre-bash.py, and of the update reminder's SessionStart entries, is held under a ceiling
# =============================================================================
# Run: bash tests/test-hook-latency.sh
#      HOOK_LATENCY_GATE=1 bash tests/test-hook-latency.sh    gate even where CI is set
#
# What it measures: the PreToolUse Bash hook of this plugin, run as Claude Code runs it (a fresh `python3`, the payload on stdin), in the
# fixed fixture of tests/hook-latency.py (an up-to-date clone with a rules directory), on the command `gh pr create --title t`: the input
# that reaches the plugin's PR rules. A new session id per run (the first hook of a session: no dedup mark, no cache).
# Every run must ANSWER (exit 0 and name the rule `pr-no-leaks`): a hook that crashed early would otherwise read as a very fast one.
# 3 warm-up runs, then 25 measured. It prints the median, the p90 and, for scale, the median of `python3 -c pass` on the same machine.
#
# The ceiling is 200 ms. Measured in the pod this suite was written in: 37 ms idle, about
# 93 ms while `bash tests/run-all.sh` runs its suites in parallel. The ceiling catches an order of magnitude (a network call, a rescan of
# the tree, a heavy import), not a drift of 10 ms: a drift is read from the printed number of each release, and `tests/hook-latency.py`
# stays the before/after tool.
#
# Gating locally, report-only in CI (GITHUB_ACTIONS or CI set): a shared runner has fewer cores than that pod and runs the suites in
# parallel (a 2.5x slowdown was measured with 24 CPUs), and no CI runner could be measured from there, so a CI gate would be a guess that
# can only flake. Gating mode takes the best median of up to 3 batches before it fails, so one noisy batch does not fail it.
#
# Controls, always run (CI included): a copy of the plugin whose pre-bash.py sleeps 0.3 s first must give a verdict red in gating mode and
# print-only in report-only mode; the real tree must give green (gating mode only); a hook that exits at once must be rc 2, never a fast
# green median. A gate that cannot fail, or a measurement that cannot see a crash, would be caught here.
# Real git on a throw-away repository, no network, no hub.
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

CEILING_MS=200
IN_CI=0; [ -n "${GITHUB_ACTIONS:-}" ] && IN_CI=1
case "${CI:-}" in ''|false|0) ;; *) IN_CI=1;; esac
if [ "$IN_CI" = 1 ] && [ "${HOOK_LATENCY_GATE:-}" != 1 ]; then MODE=report-only; else MODE=gating; fi

# measure.py <plugin> <runs> <batches> <ceiling ms> <gating|report-only>
# prints one line: `pre-bash median X ms, p90 Y ms (n=N, batches B), python3 -c pass Z ms, ceiling C ms, mode M, verdict V`
# rc 1 only when the mode is gating and the best median is above the ceiling; rc 2 when the hook did not answer.
cat > "$TMP/measure.py" <<'PY'
import importlib.util, json, os, statistics, subprocess, sys, tempfile, shutil, time, uuid
plugin, runs, batches, ceiling, mode = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4]), sys.argv[5]
spec = importlib.util.spec_from_file_location("hook_latency", os.path.join(os.environ["LATENCY_TOOL_DIR"], "hook-latency.py"))
hl = importlib.util.module_from_spec(spec); spec.loader.exec_module(hl)
tmp = tempfile.mkdtemp(prefix="hook-latency-suite-")
try:
    gcfg = os.path.join(tmp, "gitconfig")
    open(gcfg, "w").write("[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n")
    env = dict(os.environ, GIT_CONFIG_GLOBAL=gcfg, GIT_CONFIG_NOSYSTEM="1", HOME=tmp, TMPDIR=os.path.join(tmp, "t"), PYTHONDONTWRITEBYTECODE="1")
    env.pop("CLAUDE_CONFIG_DIR", None)
    os.makedirs(env["TMPDIR"])
    os.environ.update(GIT_CONFIG_GLOBAL=gcfg, GIT_CONFIG_NOSYSTEM="1")
    repo = hl.build(tmp)["up to date"]
    CMD = "gh pr create --title t"
    def run(sid):
        e = dict(env, CLAUDE_PLUGIN_ROOT=plugin, CLAUDE_PROJECT_DIR=repo)
        data = json.dumps({"session_id": sid, "hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": CMD}})
        t = time.perf_counter()
        r = subprocess.run((sys.executable, os.path.join(plugin, "scripts", "pre-bash.py")), input=data, text=True, env=e, capture_output=True, timeout=30)
        ms = (time.perf_counter() - t) * 1000
        if r.returncode != 0 or "pr-no-leaks" not in r.stdout:
            print("the hook did not answer (rc %d, %d characters of output, no pr-no-leaks rule): its time is not a measurement" % (r.returncode, len(r.stdout)))
            sys.exit(2)
        return ms
    for _ in range(3):                                   # warm-up: the page cache and the first import are not the hook's cost
        run("lat-" + uuid.uuid4().hex)
    best = None
    for b in range(1, batches + 1):
        ts = [run("lat-" + uuid.uuid4().hex) for _ in range(runs)]
        med, p90 = statistics.median(ts), sorted(ts)[min(int(len(ts) * 0.9), len(ts) - 1)]
        if best is None or med < best[0]:
            best = (med, p90)
        if med <= ceiling or mode != "gating":
            break
    noop = []
    for _ in range(runs):
        t = time.perf_counter(); subprocess.run([sys.executable, "-c", "pass"]); noop.append((time.perf_counter() - t) * 1000)
    red = mode == "gating" and best[0] > ceiling
    print("pre-bash median %.1f ms, p90 %.1f ms (n=%d, batches %d), python3 -c pass %.1f ms, ceiling %d ms, mode %s, verdict %s" % (
        best[0], best[1], runs, b, statistics.median(noop), ceiling, mode, "red" if red else "green"))
    sys.exit(1 if red else 0)
finally:
    shutil.rmtree(tmp, ignore_errors=True)
PY
M() { LATENCY_TOOL_DIR="$HERE" python3 "$TMP/measure.py" "$@"; }

echo "== the real hook: median of 25 runs, ceiling ${CEILING_MS} ms, mode $MODE =="
RC=0; OUT=$(M "$PLUGIN" 25 3 "$CEILING_MS" "$MODE" 2>&1) || RC=$?
printf '  %s\n' "$OUT"
case "$OUT" in "pre-bash median "*" (n=25, "*) ok "the measurement ran: one median line over 25 runs";; *) bad "no median line over 25 runs: ${OUT:0:200}";; esac
if [ "$MODE" = gating ]; then
  [ "$RC" -eq 0 ] && ok "pre-bash.py is under the ${CEILING_MS} ms ceiling" || bad "pre-bash.py is above the ${CEILING_MS} ms ceiling (rc $RC)"
else
  [ "$RC" -eq 0 ] && ok "report-only (CI): the number is printed, the verdict is not enforced" || bad "report-only run failed (rc $RC)"
fi

echo "== controls: a hook made slow on purpose =="
SLOW="$TMP/slow-plugin"; mk_plugin_copy "$SLOW"
python3 - "$SLOW/scripts/pre-bash.py" <<'PY'
import sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read().split("\n")
i = next(k for k, l in enumerate(t) if l.startswith("import ") or l.startswith("from "))
t.insert(i, "import time; time.sleep(0.3)")
open(p, "w", encoding="utf-8").write("\n".join(t))
PY
grep -qF 'time.sleep(0.3)' "$SLOW/scripts/pre-bash.py" && ok "the slow copy carries its planted sleep" || bad "the planted sleep is not in the copy"
# the runs on the planted copies (slow, crashing) are capped (fixtures/capped.sh: memory and time caps); the runs on the real hook are not
RC=0; OUT=$(capped M "$SLOW" 5 1 "$CEILING_MS" gating 2>&1) || RC=$?
printf '  %s\n' "$OUT"
cap_red "$RC" "gating: the slow hook" || { [ "$RC" -eq 1 ] && has "$OUT" "verdict red" "gating: the slow hook is red (rc 1)" || bad "gating: the slow hook was not red (rc $RC): ${OUT:0:200}"; }
RC=0; OUT=$(capped M "$SLOW" 5 1 "$CEILING_MS" report-only 2>&1) || RC=$?
printf '  %s\n' "$OUT"
[ "$RC" -eq 0 ] && has "$OUT" "verdict green" "report-only: the slow hook is printed, not failed (rc 0)" || bad "report-only failed the run (rc $RC)"
if [ "$MODE" = gating ]; then   # on a loaded shared runner this check could flake, so report-only mode never makes it
  RC=0; OUT=$(M "$PLUGIN" 5 3 "$CEILING_MS" gating 2>&1) || RC=$?   # the best of 3 batches, as the main measurement
  if [ "$RC" -eq 0 ]; then has "$OUT" "verdict green" "gating: the real hook, same runs, is green"; else bad "gating: the real hook was red in the control (rc $RC): ${OUT:0:200}"; fi
fi
RC=0; OUT=$(M "$PLUGIN" 5 1 1 gating 2>&1) || RC=$?
[ "$RC" -eq 1 ] && ok "gating: a ceiling of 1 ms turns the real hook red (the ceiling is read, not ignored)" || bad "a ceiling of 1 ms did not turn the run red (rc $RC)"

echo "== the update reminder's SessionStart entries (sdlc and brain), on their slowest path =="
# Each run is the plugin's own hooks.json command, in a copy whose manifest has the export's form (version, repository), with a
# cache seeded before each run (not timed), once the previous run's read has released its lock, so the run does all it can do:
# take the lock, print the line and start the background read. The read
# goes to a loopback port nothing listens on (VIBEMAESTRO_UPDATE_CHECK_API), so no network. A run must print the line: one
# that printed nothing did not take the path, and its time is not a measurement (rc 2).
cat > "$TMP/measure-ss.py" <<'PY2'
import json, os, socket, statistics, subprocess, sys, tempfile, time
root, cmd, runs, ceiling, mode, label = sys.argv[1], sys.argv[2], int(sys.argv[3]), float(sys.argv[4]), sys.argv[5], sys.argv[6]
data = tempfile.mkdtemp(prefix="latency-data-")
s = socket.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
name = json.load(open(os.path.join(root, ".claude-plugin", "plugin.json")))["name"]
env = dict(os.environ, CLAUDE_PLUGIN_ROOT=root, CLAUDE_PLUGIN_DATA=data, CLAUDE_PROJECT_DIR=data,
           VIBEMAESTRO_UPDATE_CHECK_API="http://127.0.0.1:%d" % port)
def run():
    lock = os.path.join(data, "update-check.lock")
    for _ in range(300):                   # the previous run's background read holds the lock until it ends (not timed)
        if not os.path.exists(lock):
            break
        time.sleep(0.01)
    else:
        print("%s: the lock of the previous run's read stayed 3 s" % label)
        sys.exit(2)
    json.dump({"v": 1, "checked": 0, "latest": "9.9.9", "shown": 0, "repo": "https://github.com/acme/kit", "plugin": name},
              open(os.path.join(data, "update-check.json"), "w"))
    t = time.perf_counter()
    r = subprocess.run(["bash", "-c", cmd], input='{"hook_event_name": "SessionStart", "source": "startup"}', text=True, env=env,
                       capture_output=True, timeout=30)
    ms = (time.perf_counter() - t) * 1000
    if r.returncode != 0 or "systemMessage" not in r.stdout:
        print("%s: the hook did not answer (rc %d, %d characters of output): its time is not a measurement" % (label, r.returncode, len(r.stdout)))
        sys.exit(2)
    return ms
for _ in range(3):
    run()
ts = [run() for _ in range(runs)]
med, p90 = statistics.median(ts), sorted(ts)[min(int(len(ts) * 0.9), len(ts) - 1)]
red = mode == "gating" and med > ceiling
print("%s median %.1f ms, p90 %.1f ms (n=%d), ceiling %d ms, mode %s, verdict %s" % (label, med, p90, runs, ceiling, mode, "red" if red else "green"))
sys.exit(1 if red else 0)
PY2
UC="$TMP/uc/plugins"; mkdir -p "$UC"
for n in vibemaestro-sdlc vibemaestro-brain; do
  cp -R "$SRC_ROOT/plugins/$n" "$UC/$n"; find "$UC/$n" -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null
  python3 -c 'import json,sys; p=sys.argv[1]; m=json.load(open(p)); m.update(version="0.2.0", repository="https://github.com/acme/kit"); json.dump(m, open(p, "w"))' "$UC/$n/.claude-plugin/plugin.json"
done
for n in vibemaestro-sdlc vibemaestro-brain; do
  C=$(hook_cmds "$UC/$n/hooks/hooks.json" SessionStart '' | grep -F update)
  nonempty "$C" "[U] $n: hooks.json has the update reminder's SessionStart entry"
  RC=0; OUT=$(python3 "$TMP/measure-ss.py" "$UC/$n" "$C" 15 "$CEILING_MS" "$MODE" "$n update reminder" 2>&1) || RC=$?
  printf '  %s\n' "$OUT"
  case "$OUT" in *" median "*" (n=15)"*) ok "[U] $n: one median line over 15 runs";; *) bad "[U] $n: no median line: ${OUT:0:200}";; esac
  if [ "$MODE" = gating ]; then
    [ "$RC" -eq 0 ] && ok "[U] $n: the update reminder entry is under the ${CEILING_MS} ms ceiling" || bad "[U] $n: above the ${CEILING_MS} ms ceiling (rc $RC)"
  else
    [ "$RC" -eq 0 ] && ok "[U] $n: report-only (CI): printed, not enforced" || bad "[U] $n: report-only run failed (rc $RC)"
  fi
done
RC=0; OUT=$(python3 "$TMP/measure-ss.py" "$UC/vibemaestro-sdlc" "exit 0" 3 "$CEILING_MS" gating control 2>&1) || RC=$?
[ "$RC" -eq 2 ] && ok "[U] control: an entry that prints nothing is rc 2, not a fast green median" || bad "[U] control: a silent entry read as a measurement (rc $RC)"
RC=0; OUT=$(python3 "$TMP/measure-ss.py" "$UC/vibemaestro-sdlc" "sleep 0.3; $(hook_cmds "$UC/vibemaestro-sdlc/hooks/hooks.json" SessionStart '' | grep -F update)" 3 "$CEILING_MS" gating slow 2>&1) || RC=$?
[ "$RC" -eq 1 ] && ok "[U] control: the entry made 0.3 s slower is red in gating mode" || bad "[U] control: a slow entry was not red (rc $RC): ${OUT:0:200}"

CRASH="$TMP/crash-plugin"; mk_plugin_copy "$CRASH"
printf 'raise SystemExit(3)\n' > "$CRASH/scripts/pre-bash.py"
RC=0; OUT=$(capped M "$CRASH" 5 1 "$CEILING_MS" gating 2>&1) || RC=$?
cap_red "$RC" "a hook that exits at once" || { [ "$RC" -eq 2 ] && has "$OUT" "did not answer" "a hook that exits at once is rc 2, not a fast green median" || bad "a crashed hook read as a measurement (rc $RC): ${OUT:0:200}"; }
RC=0; OUT=$(capped M "$CRASH" 5 1 "$CEILING_MS" report-only 2>&1) || RC=$?
cap_red "$RC" "…also in report-only mode" || { [ "$RC" -eq 2 ] && ok "…also in report-only mode" || bad "report-only let a crashed hook through (rc $RC)"; }

echo; summary
