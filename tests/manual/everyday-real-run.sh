#!/bin/bash
# =============================================================================
# A real run of the everyday notebook (by hand, on a machine where `claude` is logged in): does a session that did a small task leave
# kb/current-state.md non-empty, holding the present state? The fixture suite tests/test-everyday-notebook.sh cannot show that; a past
# feature of the everyday mode passed its fixtures and broke on its first real run.
# Run: bash tests/manual/everyday-real-run.sh <40-hex commit sha>
# What it does: clones the repository at that commit into a fresh temp directory; makes a scratch everyday folder (no git remote, the
# kit's own history, kb/ as `kb.py init --everyday` leaves it); runs `claude -p` there with the clone's sdlc and brain plugins only
# (--plugin-dir) and every installed plugin switched off through a settings file of its own; then prints what happened. It reads your
# Claude settings to list the installed plugins, never writes them, and does not touch CLAUDE_CONFIG_DIR (the login lives there).
# Needs: bash, git, python3, claude (logged in), and read access to the repository (gh or git credentials). Costs one short model run.
# Env (all optional): KIT_REPO (a clone URL, or owner/name for gh; default: the origin of the checkout this script is in), CLAUDE_BIN,
# RUN_MODEL, RUN_TIMEOUT (seconds).
# =============================================================================
set -uo pipefail

SHA=${1:-}
case "$SHA" in *[!0-9a-f]*|"") echo "usage: bash tests/manual/everyday-real-run.sh <40-hex commit sha>" >&2; exit 64;; esac
[ ${#SHA} -eq 40 ] || { echo "usage: bash tests/manual/everyday-real-run.sh <40-hex commit sha>" >&2; exit 64; }
REPO=${KIT_REPO:-$(git -C "$(dirname "$0")" remote get-url origin 2>/dev/null)}      # run from a checkout of the repository: its own origin
[ -n "$REPO" ] || { echo "run it from a checkout of the repository, or set KIT_REPO (a clone URL, or owner/name for gh)" >&2; exit 64; }
CLAUDE=${CLAUDE_BIN:-claude}
MODEL=${RUN_MODEL:-claude-sonnet-5-5}
LIMIT=${RUN_TIMEOUT:-600}
TASK='Make a file called packing-list.md in this folder with a short packing list (about six lines) for a weekend hike. Reply with one sentence when it is done.'

W=$(mktemp -d) || exit 1
echo "== work directory (left in place): $W"

echo "== clone at $SHA"
if command -v gh >/dev/null 2>&1 && gh repo clone "$REPO" "$W/kit" -- -q >/dev/null 2>&1; then :
elif git clone -q "$REPO" "$W/kit" 2>/dev/null; then :
else echo "cannot clone the repository (set KIT_REPO to a clone URL you can read)" >&2; exit 2; fi
git -C "$W/kit" checkout -q "$SHA" 2>&1 || { echo "cannot check out $SHA" >&2; exit 2; }
echo "checked out: $(git -C "$W/kit" rev-parse HEAD)"
SDLC="$W/kit/plugins/vibemaestro-sdlc"; BRAIN="$W/kit/plugins/vibemaestro-brain"
[ -f "$SDLC/scripts/notebook_nudge.py" ] || { echo "this commit has no scripts/notebook_nudge.py: wrong commit" >&2; exit 2; }

# What makes a session count as coordinated or developer, and where the kit keeps its state, is set for the whole run
unset INTENT_SLUG SEAT VIBEMAESTRO_ROLE VIBEMAESTRO_PROFILE VIBEMAESTRO_HUB CLAUDE_PLUGIN_ROOT CLAUDE_PROJECT_DIR CLAUDE_ENV_FILE
export XDG_STATE_HOME="$W/state" VIBEMAESTRO_NO_UPDATE_CHECK=1
mkdir -p "$XDG_STATE_HOME"

echo "== scratch everyday folder"
F="$W/folder"; mkdir -p "$F"
printf 'Notes for my trips.\n' > "$F/trips.txt"
payload() { printf '{"session_id":"setup","hook_event_name":"%s","cwd":"%s","source":"startup"}' "$1" "$F"; }
save() { (cd "$F" && payload Stop | CLAUDE_PLUGIN_ROOT="$SDLC" CLAUDE_PROJECT_DIR="$F" /bin/sh "$SDLC/scripts/pyrun.sh" scripts/quiet_save.py save >/dev/null 2>&1); }
save                                                    # the first save: the kit makes the folder's own history, with its mark
(cd "$F" && python3 "$SDLC/scripts/kb.py" init --everyday >/dev/null 2>&1) || echo "kb.py init --everyday failed" >&2
save
echo "git remotes: [$(git -C "$F" remote 2>&1)]  kit mark: $(git -C "$F" config --local --get vibemaestro.quietsave 2>&1)  saves: $(git -C "$F" rev-list --count HEAD 2>&1)"
echo "kb/ before: $(cd "$F" && find kb -type f -printf '%p (%s bytes)  ' 2>/dev/null)"

echo "== the mode the session-start hook sees in that folder"
(cd "$F" && payload SessionStart | CLAUDE_PLUGIN_ROOT="$SDLC" CLAUDE_PROJECT_DIR="$F" /bin/sh "$SDLC/scripts/pyrun.sh" --say scripts/session-start.py core 2>&1) \
  | python3 -c '
import json, re, sys
t = sys.stdin.read()
try:
    ctx = json.loads(t)["hookSpecificOutput"]["additionalContext"]
except Exception:
    print("hook output not read:", t[:200].replace("\n", " ")); sys.exit(0)
m = re.search(r"everyday mode, because[^;]*", ctx)
print(m.group(0) if m else ("NOT everyday: " + ctx[:100].replace("\n", " ")))'

echo "== settings of this run: every installed plugin off (your settings files are only read)"
python3 - "$W/settings.json" <<'PY'
import json, os, sys
base = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
names = set()
for path, pick in ((os.path.join(base, "settings.json"), lambda d: d.get("enabledPlugins", {})),
                   (os.path.join(base, "plugins", "installed_plugins.json"), lambda d: d.get("plugins", {}))):
    try:
        with open(path, encoding="utf-8") as f:
            names |= set(pick(json.load(f)))
    except (OSError, ValueError, AttributeError):
        pass
json.dump({"enabledPlugins": {n: False for n in sorted(names)}}, open(sys.argv[1], "w"))
print("switched off:", ", ".join(sorted(names)) or "(none found)")
PY

FLAGS=(--plugin-dir "$SDLC" --plugin-dir "$BRAIN" --settings "$W/settings.json" --model "$MODEL" --permission-mode acceptEdits
       --output-format stream-json --verbose --include-hook-events)
"$CLAUDE" --help 2>&1 | grep -qF -- --max-turns && FLAGS+=(--max-turns 12)
"$CLAUDE" --help 2>&1 | grep -qF -- --max-budget-usd && FLAGS+=(--max-budget-usd 2)

echo "== claude -p (model $MODEL, at most $LIMIT s)"
touch "$W/marker"; sleep 1
(cd "$F" && timeout "$LIMIT" "$CLAUDE" -p "$TASK" "${FLAGS[@]}" > "$W/run.jsonl" 2> "$W/run.err")
RC=$?
echo "claude exit code: $RC"
[ -s "$W/run.err" ] && echo "claude stderr (first lines): $(head -c 400 "$W/run.err" | tr '\n' ' ')"

echo "== what the run shows (raw stream kept in $W/run.jsonl)"
python3 - "$W/run.jsonl" <<'PY'
import json, sys
init = result = None
hooks = []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    try:
        d = json.loads(line)
    except ValueError:
        continue
    if d.get("type") == "system" and d.get("subtype") == "init" and init is None:
        init = d
    if d.get("type") == "result":
        result = d
    s = json.dumps(d, ensure_ascii=False)
    if "notebook_nudge" in s or "kb/current-state.md chưa được cập nhật" in s or "kb/current-state.md was not updated" in s:
        hooks.append(d)
if init:
    print("plugins loaded:", ", ".join(str(p.get("name", p)) if isinstance(p, dict) else str(p) for p in init.get("plugins", [])) or "(none listed)")
    print("model:", init.get("model"), " cwd:", init.get("cwd"))
else:
    print("no init event in the stream")
print("result:", (result or {}).get("subtype"), " turns:", (result or {}).get("num_turns"), " is_error:", (result or {}).get("is_error"))
fired = [h for h in hooks if "kb/current-state.md" in json.dumps(h, ensure_ascii=False) and ("block" in json.dumps(h) or "chưa được cập nhật" in json.dumps(h, ensure_ascii=False) or "was not updated" in json.dumps(h))]
print("nudge events in the stream (the hook ran:", len(hooks), "; its block reached the session:", len(fired), ")")
for h in fired[:2]:
    print("  ", json.dumps(h, ensure_ascii=False)[:300])
PY
SLUG=$(printf '%s' "$F" | sed 's/[^A-Za-z0-9]/-/g')
BASE=${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects
N=$(grep -rlF 'kb/current-state.md' "$BASE/$SLUG" 2>/dev/null | wc -l | tr -d ' ')
M=$(grep -rhoE 'kb/current-state.md (chưa được cập nhật|was not updated)' "$BASE/$SLUG" 2>/dev/null | wc -l | tr -d ' ')
echo "transcript check (read only): $N transcript file(s) name kb/current-state.md; the nudge sentence appears $M time(s) (the transcript also holds the hook's own command line, so 0 here with hook events above is possible)"

echo "== files changed by the run (outside .git)"
(cd "$F" && find . -path ./.git -prune -o -type f -newer "$W/marker" -printf '%p (%s bytes)\n' | sort)
echo "saves in the kit's history now: $(git -C "$F" rev-list --count HEAD 2>&1)"

echo "== kb/current-state.md after the run"
CS="$F/kb/current-state.md"
if [ -s "$CS" ]; then echo "(non-empty, $(wc -c < "$CS" | tr -d ' ') bytes, $(wc -l < "$CS" | tr -d ' ') lines)"; cat "$CS"; else echo "EMPTY OR MISSING"; fi
echo "== other notebook files"
(cd "$F" && find kb -type f -newer "$W/marker" ! -name current-state.md -printf '%p (%s bytes)\n' 2>/dev/null | sort)

echo "== done: claude exit $RC; work directory $W"
