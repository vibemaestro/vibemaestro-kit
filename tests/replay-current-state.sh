#!/bin/bash
# =============================================================================
# Differential: replay the last N versions of a ledger through an old gate and through the builtin profile
# =============================================================================
# Run: bash tests/replay-current-state.sh <clone> --profile <config.json> --adapter <old-gate.py> [--last N] [--bare]
#
# Not a test-*.sh file on purpose: it needs a clone of another repository, so `tests/run-all.sh` never runs it. It is the parity
# evidence of the current-state gate, and the hub repeats it on its own tree.
#
#   <clone>      a git clone holding the old gate and the ledger history. It is only READ: the script checks `git status
#                --porcelain` is empty before and after, writes nothing inside it, and takes the old gate's source from a
#                scratch `git archive` copy (REPLAY_OLD_ROOT in the adapter's environment points at that copy).
#   --profile    a `.vibemaestro/sdlc.json` with the `current_state` (and `tokens`) of the profile under test. It names the
#                ledger path (`current_state.path`).
#   --adapter    a Python file that exposes `violations(raw)` (and optionally `decide(paths, body, raw)`) of the OLD gate,
#                see tests/fixtures/replay_gates.py. The old gate's names and messages live there, not in this repository.
#   --last N     number of ledger versions, newest N commits that touched the ledger (default 50)
#   --bare       replay with the bare `template` preset (the profile's template, nothing else) as well as the given profile
# Output: the aggregate only (rc equal, set equality, categories of difference). The ledger text is never printed.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
CLONE=""; PROFILE=""; ADAPTER=""; LAST=50; BARE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE=$2; shift 2;;
    --adapter) ADAPTER=$2; shift 2;;
    --last) LAST=$2; shift 2;;
    --bare) BARE=1; shift;;
    -*) echo "unknown option $1" >&2; exit 64;;
    *) CLONE=$1; shift;;
  esac
done
[ -d "$CLONE/.git" ] || [ -f "$CLONE/.git" ] || { echo "usage: replay-current-state.sh <clone> --profile <config.json> --adapter <old-gate.py> [--last N] [--bare]" >&2; exit 64; }
[ -f "$PROFILE" ] && [ -f "$ADAPTER" ] || { echo "--profile and --adapter must be files" >&2; exit 64; }
case "$LAST" in ''|*[!0-9]*) echo "--last wants a number" >&2; exit 64;; esac
CLONE=$(CDPATH= cd -- "$CLONE" && pwd -P)
before=$(git -C "$CLONE" status --porcelain | sha1sum | cut -d' ' -f1)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
mkdir -p "$W/old" "$W/versions" "$W/prof/.vibemaestro"
git -C "$CLONE" archive HEAD | tar -x -C "$W/old"
cp "$PROFILE" "$W/prof/.vibemaestro/sdlc.json"
LEDGER=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("current_state", {}).get("path", "kb/current-state.md"))' "$PROFILE")
i=0
for sha in $(git -C "$CLONE" log --format=%H -n "$LAST" -- "$LEDGER" | sed '1!G;h;$!d'); do   # oldest first
  i=$((i+1)); git -C "$CLONE" show "$sha:$LEDGER" > "$W/versions/$(printf '%03d' "$i")" 2>/dev/null || : > "$W/versions/$(printf '%03d' "$i")"
done
echo "== profile as given: $i ledger versions"
REPLAY_OLD_ROOT="$W/old" python3 "$HERE/fixtures/replay_gates.py" --scripts "$PLUGIN/scripts" --profile-root "$W/prof" --adapter "$ADAPTER" --versions "$W/versions"
if [ "$BARE" = 1 ]; then
  mkdir -p "$W/bare/.vibemaestro"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); t=d.get("current_state", {}).get("template", "ledger"); json.dump({"schema": 1, "current_state": {"template": t, "path": d.get("current_state", {}).get("path", "kb/current-state.md")}}, open(sys.argv[2], "w"))' "$PROFILE" "$W/bare/.vibemaestro/sdlc.json"
  echo "== bare template preset only"
  REPLAY_OLD_ROOT="$W/old" python3 "$HERE/fixtures/replay_gates.py" --scripts "$PLUGIN/scripts" --profile-root "$W/bare" --adapter "$ADAPTER" --versions "$W/versions"
fi
after=$(git -C "$CLONE" status --porcelain | sha1sum | cut -d' ' -f1)
[ "$before" = "$after" ] && echo "clone untouched: git status --porcelain is the same before and after" || { echo "ERROR: the clone changed" >&2; exit 1; }
