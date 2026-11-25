#!/bin/bash
# =============================================================================
# Plugin vibemaestro-sdlc — the `/init` hint (UserPromptSubmit, scripts/init-hint.py)
# =============================================================================
# Run: bash tests/test-init-hint.sh
#
# The hook is a script that reads JSON on stdin, so the suite runs the exact `command` of hooks/hooks.json. The sdlc and the brain
# are the real plugins, copied into a fake plugin cache (a registry beside it) where the hook finds the brain as `intake` does.
# Every positive case has its negative beside it in the same state: `/init` against `/initialize` in one repo, a repo with the
# brain against one without. A case that tests silence says what it is silent about, and its positive control proves the hook
# was able to speak there.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"

TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"

# ── a plugin cache: <claude>/plugins/cache/vibemaestro/<plugin>/1.0.0, and the registry that lists both ─────────────────────────
CL="$TMP/claude"; CACHE="$CL/plugins/cache/vibemaestro"
SDLC="$CACHE/vibemaestro-sdlc/1.0.0"; BRAIN="$CACHE/vibemaestro-brain/1.0.0"
mkdir -p "$SDLC" "$BRAIN"
cp -R "$SRC_ROOT/plugins/vibemaestro-sdlc/." "$SDLC/"; cp -R "$SRC_ROOT/plugins/vibemaestro-brain/." "$BRAIN/"
register() {  # register <registry file> <sdlc dir> [brain dir] — the registry the hook reads to find the brain beside it
  python3 - "$@" <<'PY'
import json, sys
e = lambda p: [{"scope": "user", "installPath": p, "version": "1.0.0", "lastUpdated": "2026-11-08T00:00:00.000Z"}]
plugins = {"vibemaestro-sdlc@vibemaestro": e(sys.argv[2])}
if len(sys.argv) > 3:
    plugins["vibemaestro-brain@vibemaestro"] = e(sys.argv[3])
json.dump({"version": 2, "plugins": plugins}, open(sys.argv[1], "w"))
PY
}
register "$CL/plugins/installed_plugins.json" "$SDLC" "$BRAIN"
cache_of() {  # cache_of <name> <brain dir|-> — another cache with a copy of the sdlc and that brain (or none); prints its sdlc dir
  local d="$TMP/cache-$1/plugins/cache/vibemaestro/vibemaestro-sdlc/1.0.0"
  mkdir -p "$d"; cp -R "$SDLC/." "$d/"
  if [ "$2" = - ]; then register "$TMP/cache-$1/plugins/installed_plugins.json" "$d"; else register "$TMP/cache-$1/plugins/installed_plugins.json" "$d" "$2"; fi
  printf '%s' "$d"
}

HOOKS="$SDLC/hooks/hooks.json"
CMD=$(hook_cmds "$HOOKS" UserPromptSubmit "")

# hint <plugin root> <cwd> <prompt> — runs the hook as Claude Code does; $OUT is its stdout, $RC its exit code
p_prompt() { python3 -c 'import json, sys; print(json.dumps({"session_id": "s1", "hook_event_name": "UserPromptSubmit", "prompt": sys.argv[1], "cwd": sys.argv[2]}))' "$1" "$2"; }
hint_raw() {  # hint_raw <plugin root> <cwd> <stdin text>
  OUT=$(cd "$2" && printf '%s' "$3" | CLAUDE_PLUGIN_ROOT="$1" bash -c "$CMD" 2>/dev/null); RC=$?
}
hint() { hint_raw "$1" "$2" "$(p_prompt "$3" "$2")"; }
say_() { hint "$SDLC" "$1" "$2"; CTX=$(ctx "$OUT"); }   # in the real cache copy

mkrepo() {  # mkrepo <dir> <kb 0|1> <brain 0|1> — a git work tree; with brain 1 its brain holds a first write, as `brain claim` leaves it
  mkdir -p "$1"; git_ init -q -b main "$1"; : > "$1/f"
  if [ "$2" = 1 ]; then mkdir -p "$1/kb/intent"; echo x > "$1/kb/intent/a.md"; fi
  git_ -C "$1" add -A; git_ -C "$1" commit -qm c1
  if [ "$3" = 1 ]; then (cd "$1" && CLAUDE_CODE_SESSION_ID=s1 python3 "$BRAIN/scripts/brain.py" claim >/dev/null); fi
}
VN='[ăâđêôơưáàảãạấầẩẫậắằẳẵặéèẻẽẹếềểễệíìỉĩịóòỏõọốồổỗộớờởỡợúùủũụứừửữựýỳỷỹỵ]'
vncount() { printf '%s' "$1" | python3 -c 'import re, sys; rx = re.compile(sys.argv[1], re.I); print(sum(1 for l in sys.stdin.buffer.read().decode("utf-8", "replace").split("\n") if rx.search(l)))' "$VN"; }
snap() {  # snap <dir> — path, size, mtime and content hash of everything under <dir>; one line each
  python3 - "$1" <<'PY'
import hashlib, os, sys
for d, ds, fs in sorted(os.walk(sys.argv[1])):
    ds.sort()
    for n in sorted(ds + fs):
        p = os.path.join(d, n); st = os.lstat(p)
        h = hashlib.sha1(open(p, "rb").read()).hexdigest() if os.path.isfile(p) else "-"
        print(p, st.st_size, st.st_mtime_ns, h)
PY
}

echo "== wiring: hooks.json declares one UserPromptSubmit command, init-hint.py =="
eq "$(printf '%s\n' "$CMD" | grep -c .)" 1 "[AC1] UserPromptSubmit: one command"
has "$CMD" 'scripts/init-hint.py' "[AC1] …and it is init-hint.py"
eq "$(hook_cmds "$HOOKS" UserPromptSubmit "" | grep -c pyrun.sh)" 1 "[AC4] it goes through pyrun.sh like every hook of the plugin"

echo "== AC1: /init in a git work tree with no kb/ =="
mkrepo "$TMP/nokb" 0 1
for p in "/init" "/init some arguments" "  /init" $'/init\nmore text'; do
  say_ "$TMP/nokb" "$p"
  eq "$RC" 0 "[AC1] '$(printf '%s' "$p" | head -c 20 | tr '\n' ' ')': exit 0"
  has "$CTX" 'CLAUDE.md' "[AC1] '$(printf '%s' "$p" | head -c 20 | tr '\n' ' ')': finish CLAUDE.md first"
  has "$CTX" 'vibemaestro-sdlc:init-kb' "[AC1] …then the skill init-kb"
  hasnt "$CTX" 'brain claim' "[AC1] …and no brain step when the brain exists (same repo, brain claimed)"
done
say_ "$TMP/nokb" "/init"
eq "$(printf '%s' "$OUT" | python3 -c 'import json, sys; print(json.load(sys.stdin)["hookSpecificOutput"]["hookEventName"])')" UserPromptSubmit "[AC1] the output names its event"
cpos=$(python3 -c 'import sys; print(sys.argv[1].find("CLAUDE.md"))' "$CTX"); spos=$(python3 -c 'import sys; print(sys.argv[1].find("init-kb"))' "$CTX")
[ "$cpos" -ge 0 ] && [ "$spos" -gt "$cpos" ] && ok "[AC1] CLAUDE.md (at $cpos) comes before the setup step (at $spos)" || bad "[AC1] CLAUDE.md comes before the setup step (CLAUDE.md $cpos, init-kb $spos)"

echo "== AC2: the brain =="
mkrepo "$TMP/nobrain" 1 0
say_ "$TMP/nobrain" "/init"
has "$CTX" 'vibemaestro-brain:brain' "[AC2] no brain: the skill is named"
has "$CTX" 'brain claim' "[AC2] …and its Quick start's first command"
hasnt "$CTX" 'init-kb' "[AC2] …and no kb step when kb/ exists (same hook, same prompt)"
mkrepo "$TMP/both" 0 0
say_ "$TMP/both" "/init"
eq "$(printf '%s' "$OUT" | python3 -c 'import json, sys; json.load(sys.stdin); print(1)')" 1 "[AC2] neither: one JSON object, one block"
kbpos=$(python3 -c 'import sys; print(sys.argv[1].find("init-kb"))' "$CTX"); brpos=$(python3 -c 'import sys; print(sys.argv[1].find("brain claim"))' "$CTX")
[ "$kbpos" -gt 0 ] && [ "$brpos" -gt "$kbpos" ] && ok "[AC2] neither: kb first (at $kbpos), brain after (at $brpos)" || bad "[AC2] neither: kb first, brain after (kb $kbpos, brain $brpos)"
has "$CTX" '1. ' "[AC2] neither: numbered steps"
# the brain step only when vibemaestro-brain is installed
NOBR=$(cache_of nobr -)
hint "$NOBR" "$TMP/both" "/init"
has "$(ctx "$OUT")" 'init-kb' "[AC2] brain not installed: the kb step stays (control)"
hasnt "$(ctx "$OUT")" 'brain claim' "[AC2] brain not installed: no brain step"
# the brain is read through the brain of this project: another project's brain does not count
mkrepo "$TMP/other" 1 1
say_ "$TMP/nobrain" "/init"; has "$CTX" 'brain claim' "[AC2] control: one project's brain does not stand for another's"

echo "== AC3: nothing to add =="
mkrepo "$TMP/full" 1 1
say_ "$TMP/full" "/init"; eq "$RC" 0 "[AC3] kb/ and brain: exit 0"; empty "$OUT" "[AC3] kb/ and brain: nothing added"
for p in "/initialize" "/init-foo" "please run /init" "hello /init now" "init" "/Init"; do
  say_ "$TMP/both" "$p"; eq "$RC" 0 "[AC3] '$p': exit 0"; empty "$OUT" "[AC3] '$p' in a repo that lacks both: nothing added (the same repo speaks for /init above)"
done
mkdir -p "$TMP/plain"
say_ "$TMP/plain" "/init"; eq "$RC" 0 "[AC3] outside a git work tree: exit 0"; empty "$OUT" "[AC3] outside a git work tree: nothing added"
git_ init -q -b main "$TMP/plain"; say_ "$TMP/plain" "/init"; has "$CTX" 'init-kb' "[AC3] control: the same folder, once it is a work tree, gets the hint"
git_ init -q --bare "$TMP/bare.git"; say_ "$TMP/bare.git" "/init"; empty "$OUT" "[AC3] a bare repository: nothing added"
mkdir -p "$TMP/nokb/sub"; say_ "$TMP/nokb/sub" "/init"; has "$CTX" 'init-kb' "[AC3] control: a sub-folder of a work tree speaks for the work tree"
# kb/ is on the scaffold branch, not merged: do not say to scaffold it twice
mkrepo "$TMP/scaf" 0 1; git_ -C "$TMP/scaf" checkout -q -b chore/kb-init; mkdir -p "$TMP/scaf/kb/intent"; echo x > "$TMP/scaf/kb/intent/a.md"
git_ -C "$TMP/scaf" add -A; git_ -C "$TMP/scaf" commit -qm kb; git_ -C "$TMP/scaf" checkout -q main
say_ "$TMP/scaf" "/init"
has "$CTX" 'chore/kb-init' "[AC1] kb/ on the unmerged scaffold branch: the hint names the branch"
hasnt "$CTX" 'init-kb' "[AC1] …and does not send the model to init-kb again (a string both languages share)"

# kb/ is already on the upstream of this branch, which is only behind it: pull, do not scaffold
git_ init -q --bare -b main "$TMP/up.git"; mkrepo "$TMP/upa" 0 1; git_ -C "$TMP/upa" remote add origin "$TMP/up.git"; git_ -C "$TMP/upa" push -q -u origin main
git_ clone -q "$TMP/up.git" "$TMP/upb"; mkdir -p "$TMP/upb/kb/intent"; echo x > "$TMP/upb/kb/intent/a.md"
git_ -C "$TMP/upb" add -A; git_ -C "$TMP/upb" commit -qm kb; git_ -C "$TMP/upb" push -q origin main; git_ -C "$TMP/upa" fetch -q origin
say_ "$TMP/upa" "/init"
has "$CTX" 'git pull --ff-only' "[AC1] kb/ on the upstream: the hint says to pull"
hasnt "$CTX" 'init-kb' "[AC1] …and does not send the model to init-kb (the same repo before the fetch would: control below)"
git_ init -q --bare -b main "$TMP/up2.git"; mkrepo "$TMP/upc" 0 1; git_ -C "$TMP/upc" remote add origin "$TMP/up2.git"; git_ -C "$TMP/upc" push -q -u origin main
say_ "$TMP/upc" "/init"; has "$CTX" 'init-kb' "[AC1] control: a tracked branch whose upstream has no kb/ still gets init-kb"

echo "== AC4: never fails the prompt, adds nothing on an error =="
mkdir -p "$TMP/notgit"
for raw in "" "not json" "[]" '"/init"' '{"prompt": 5}' '{"prompt": null}' '{"cwd": "/nonexistent-x"}' '{"prompt": "/init", "cwd": 7}' '{"prompt": "/init", "cwd": "/nonexistent-x"}'; do
  hint_raw "$SDLC" "$TMP/notgit" "$raw"
  eq "$RC" 0 "[AC4] stdin '${raw:0:30}': exit 0"; empty "$OUT" "[AC4] stdin '${raw:0:30}': nothing added"
done
# a payload cwd that is not usable falls back to the folder the hook runs in, as every hook does: here a work tree with no kb/ speaks
hint_raw "$SDLC" "$TMP/nokb" '{"prompt": "/init", "cwd": 7}'; has "$(ctx "$OUT")" 'init-kb' "[AC4] control: an unusable cwd falls back to the process folder, so the silence above is the folder's (not a git tree), not the cwd's"
hint_raw "$SDLC" "$TMP/both" $'{"prompt": "/init", "cwd": "'"$TMP/both"$'"}\xff'; eq "$RC" 0 "[AC4] bytes that are not UTF-8: exit 0"
hint_raw "$SDLC" "$TMP/both" "$(p_prompt "/init" "$TMP/both")"; has "$(ctx "$OUT")" 'init-kb' "[AC4] control: the same repo with a good payload speaks"
# a plugin installed without one of its skills
NOSK=$(cache_of nosk "$BRAIN"); rm -rf "$NOSK/skills/init-kb"   # not a break: a plugin installed without that skill, the input of this case
hint "$NOSK" "$TMP/nobrain" "/init"; eq "$RC" 0 "[AC4] init-kb missing from the plugin: exit 0"; hasnt "$(ctx "$OUT")" 'init-kb' "[AC4] init-kb missing: no step that names it"
hint "$NOSK" "$TMP/both" "/init"; has "$(ctx "$OUT")" 'brain claim' "[AC4] control: the brain step stays when only init-kb is missing"
# a config the hook cannot read, and one that turns the kit off
mkdir -p "$TMP/both/.vibemaestro"
printf '{bad' > "$TMP/both/.vibemaestro/sdlc.json"; say_ "$TMP/both" "/init"
eq "$RC" 0 "[AC4] an unreadable config: exit 0"; empty "$OUT" "[AC4] an unreadable config: nothing added"
rm "$TMP/both/.vibemaestro/sdlc.json"; mkdir "$TMP/both/.vibemaestro/sdlc.json"; say_ "$TMP/both" "/init"
eq "$RC" 0 "[AC4] a config that is a directory: exit 0"; empty "$OUT" "[AC4] a config that is a directory: nothing added"
rmdir "$TMP/both/.vibemaestro/sdlc.json"; printf '{"schema": 1, "hooks": "off"}' > "$TMP/both/.vibemaestro/sdlc.json"; say_ "$TMP/both" "/init"
empty "$OUT" "[AC4] hooks: off: nothing added"
printf '{"schema": 1, "hooks": "auto"}' > "$TMP/both/.vibemaestro/sdlc.json"; say_ "$TMP/both" "/init"
has "$CTX" 'init-kb' "[AC4] control: hooks: auto, the same repo speaks"

echo "== brain check: read-only, and bounded =="
mkrepo "$TMP/ro" 1 0
STATE="$XDG_STATE_HOME"; rm -rf "$STATE/vibemaestro"
B0=$(snap "$STATE"); say_ "$TMP/ro" "/init"; B1=$(snap "$STATE")
has "$CTX" 'brain claim' "[AC2] control: the hook spoke about the brain, so it asked the brain"
eq "$B1" "$B0" "[AC2] no brain state yet: the check created no directory and no file"
[ ! -e "$STATE/vibemaestro/brain" ] && ok "[AC2] …no brain state directory exists after the hint" || bad "[AC2] a brain state directory was created by the hint"
mkrepo "$TMP/ro2" 1 1
C0=$(snap "$STATE"); say_ "$TMP/ro2" "/init"; C1=$(snap "$STATE")
nonempty "$C0" "[AC2] control: a brain store exists under the state home"
eq "$C1" "$C0" "[AC2] a brain that exists: no file under the state home changed (size, time, content)"
# a brain that hangs, one that fails, one that answers nonsense
stub_brain() {  # stub_brain <name> <python body of brain.py> → a cache whose brain is that stub; prints its sdlc dir
  mkdir -p "$TMP/stub-$1/scripts"; printf '%s\n' "$2" > "$TMP/stub-$1/scripts/brain.py"; cache_of "stub-$1" "$TMP/stub-$1"
}
HANG=$(stub_brain hang 'import time; time.sleep(120)')
T0=$(date +%s); hint "$HANG" "$TMP/both" "/init"; T1=$(date +%s)
eq "$RC" 0 "[AC4] a brain that hangs: exit 0"
[ $((T1 - T0)) -le 8 ] && ok "[AC4] a brain that hangs: the prompt waited $((T1 - T0)) s, not the stub's 120" || bad "[AC4] a brain that hangs: the prompt waited $((T1 - T0)) s"
[ $((T1 - T0)) -ge 4 ] && ok "[AC4] …the cap was really reached (a stub that does not hang would show a fast answer)" || bad "[AC4] the stub did not hang for the cap ($((T1 - T0)) s): the instrument is not the case it names"
has "$(ctx "$OUT")" 'init-kb' "[AC4] a brain that hangs: the kb step stays"
hasnt "$(ctx "$OUT")" 'brain claim' "[AC4] a brain that hangs: no brain step"
FAIL_B=$(stub_brain fail 'import sys; sys.stderr.write("boom\n"); sys.exit(1)')
hint "$FAIL_B" "$TMP/both" "/init"; eq "$RC" 0 "[AC4] a brain that fails: exit 0"; hasnt "$(ctx "$OUT")" 'brain claim' "[AC4] a brain that fails: no brain step"
JUNK_B=$(stub_brain junk 'print("not a path")')
hint "$JUNK_B" "$TMP/both" "/init"; hasnt "$(ctx "$OUT")" 'brain claim' "[AC4] a brain that answers a non-path: no brain step"
SAY_B=$(stub_brain says "import os; print(os.environ['TMPDIR'] + '/no-such-state')")
hint "$SAY_B" "$TMP/both" "/init"; has "$(ctx "$OUT")" 'brain claim' "[AC4] control: a brain that names a state directory with no store: the brain step is there"

echo "== AC5: language =="
mkrepo "$TMP/lang" 0 0; mkdir -p "$TMP/lang/.vibemaestro"
say_ "$TMP/lang" "/init"
[ "$(vncount "$CTX")" -gt 0 ] && ok "[AC5] language unset: Vietnamese, as the kit's default" || bad "[AC5] language unset: Vietnamese (got: ${CTX:0:80})"
printf '{"schema": 1, "language": "vi"}' > "$TMP/lang/.vibemaestro/sdlc.json"; say_ "$TMP/lang" "/init"
[ "$(vncount "$CTX")" -gt 0 ] && ok "[AC5] language vi: Vietnamese" || bad "[AC5] language vi: Vietnamese"
has "$CTX" 'vibemaestro-sdlc:init-kb' "[AC5] …it still names the skill, not a translation of it"
has "$CTX" 'brain claim' "[AC5] …and the command"
printf '{"schema": 1, "language": "en"}' > "$TMP/lang/.vibemaestro/sdlc.json"; say_ "$TMP/lang" "/init"
eq "$(vncount "$CTX")" 0 "[AC5] language en: no Vietnamese letter"
has "$CTX" 'Finish CLAUDE.md first' "[AC5] language en: English, CLAUDE.md first"
has "$CTX" 'brain claim' "[AC5] language en: the brain step too"

echo "== AC6: a prompt that is not /init returns before the plugin's library loads =="
imports() {  # imports <prompt> — the modules the hook script imports for that prompt, read from Python's own import log
  p_prompt "$1" "$TMP/both" | (cd "$TMP/both" && CLAUDE_PLUGIN_ROOT="$SDLC" python3 -X importtime "$SDLC/scripts/init-hint.py" 2>&1 >/dev/null)
}
for p in "/initialize" "hello" "text with /init inside" ""; do
  hasnt "$(imports "$p")" 'vsdlc' "[AC6] '$p': the plugin's library was not imported"
done
has "$(imports "/init")" 'vsdlc' "[AC6] control: /init does import it (the import log sees vsdlc)"

summary
