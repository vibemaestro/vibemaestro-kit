#!/bin/bash
# =============================================================================
# LIVE (not in CI): how long a SessionStart hook string may be and still reach the model whole. Claude Code passes one hook
# command's string inline up to a cap and replaces a longer one whole by a short `<persisted-output>` preview; the brain holds
# each of its strings under the cap by construction (8,000 and 9,500), never by that replacement.
# =============================================================================
# Run, from this repository's checkout, on a machine with `claude` on PATH:
#     bash tests/live/hook-cap.sh                  the lengths 9500 10000 10001
#     bash tests/live/hook-cap.sh 9000 12000       other lengths
#     bash tests/live/hook-cap.sh --astral 10000 10001   strings of 😀 (U+1F600): the length is in UTF-16 units, 2 per emoji
# rc 0 every length behaved as the 10,000-character cap says (≤ 10,000 inline, more replaced), 1 one did not, 2 skipped (the reason
# is printed: no `claude`, or no transcript was written).
#
# A throwaway plugin, loaded with --plugin-dir, has one SessionStart command per length; each prints a marked string of exactly
# that many characters as `additionalContext`. A nested `claude -p` runs in a scratch config, HOME and project with no
# credentials: Claude Code runs the hooks and writes the transcript, then refuses the API call (not logged in), so no model is
# asked and nothing is spent. The transcript's `hook_additional_context` attachment shows what reached the model. One line per
# length: `<length> inline` or `<length> replaced`, then the Claude Code version. A length is in UTF-16 code units, the unit
# Claude Code counts: with --astral the string is mostly emoji, so its length in characters is about half.
# =============================================================================
set -uo pipefail
CLAUDE_BIN=$(command -v claude 2>/dev/null || true)
[ -n "$CLAUDE_BIN" ] || { echo "skip: claude is not on PATH"; exit 2; }
ASTRAL=0; [ "${1:-}" = --astral ] && { ASTRAL=1; shift; }
[ $# -gt 0 ] && LENGTHS=("$@") || LENGTHS=(9500 10000 10001)
for n in "${LENGTHS[@]}"; do
  case $n in ''|*[!0-9]*) echo "usage: bash tests/live/hook-cap.sh [--astral] [length…]  (whole numbers)"; exit 2 ;; esac
done
T=$(mktemp -d); T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/plugin/.claude-plugin" "$T/plugin/hooks" "$T/config" "$T/home" "$T/project" "$T/tmp"
printf '{"name": "hook-cap-probe", "version": "0.0.1", "description": "prints SessionStart strings of known lengths"}\n' \
  > "$T/plugin/.claude-plugin/plugin.json"
cat > "$T/plugin/emit.py" <<'PY'
import json, sys
n, astral = int(sys.argv[1]), sys.argv[2:] == ["astral"]
head = "HOOKCAP%d:" % n
fill = n - len(head)
body = ("x" * (fill % 2) + "\U0001F600" * (fill // 2)) if astral else "x" * fill
print(json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": head + body}}))
PY
python3 - "$T" "$ASTRAL" "${LENGTHS[@]}" <<'PY'
import json, sys
t, astral, lengths = sys.argv[1], sys.argv[2] == "1", sys.argv[3:]
hooks = [{"type": "command", "command": "python3 %s/plugin/emit.py %s%s" % (t, n, " astral" if astral else ""), "timeout": 30}
         for n in lengths]
json.dump({"hooks": {"SessionStart": [{"hooks": hooks}]}}, open(t + "/plugin/hooks/hooks.json", "w"))
PY
VERSION=$("$CLAUDE_BIN" --version 2>/dev/null | head -n 1)
(cd "$T/project" && env -i HOME="$T/home" PATH="$(dirname "$CLAUDE_BIN"):/usr/local/bin:/usr/bin:/bin" CLAUDE_CONFIG_DIR="$T/config" \
   TMPDIR="$T/tmp" timeout 120 "$CLAUDE_BIN" -p "hi" --plugin-dir "$T/plugin" < /dev/null > "$T/claude.out" 2>&1)
TRANSCRIPT=$(find "$T/config/projects" -name '*.jsonl' 2>/dev/null | head -n 1)
if [ -z "$TRANSCRIPT" ]; then
  echo "skip: the nested claude wrote no transcript ($(head -c 200 "$T/claude.out" | tr '\n' ' '))"; exit 2
fi
python3 - "$TRANSCRIPT" "$ASTRAL" "${LENGTHS[@]}" <<'PY'
import json, sys
path, astral, lengths = sys.argv[1], sys.argv[2] == "1", [int(x) for x in sys.argv[3:]]
seen = {}
for line in open(path, encoding="utf-8"):
    try:
        o = json.loads(line)
    except ValueError:
        continue
    a = o.get("attachment") if isinstance(o, dict) else None
    if not (isinstance(a, dict) and a.get("type") == "hook_additional_context"):
        continue
    for c in a.get("content") or []:
        if not isinstance(c, str):
            continue
        for n in lengths:
            head = "HOOKCAP%d:" % n
            if c.startswith(head) and len(c.encode("utf-16-le")) // 2 == n:
                seen[n] = "inline"
            elif c.startswith("<persisted-output>") and head in c:
                seen[n] = "replaced"
bad = 0
for n in lengths:
    verdict = seen.get(n, "missing")
    want = "inline" if n <= 10000 else "replaced"
    bad += verdict != want
    print("%d %s%s" % (n, verdict, "" if verdict == want else "   (the 10,000 cap says %s)" % want))
if astral:
    print("(UTF-16 units; each string mostly U+1F600, about half as many characters)")
sys.exit(1 if bad else 0)
PY
RC=$?
echo "claude: $VERSION"
exit $RC
