#!/bin/bash
# =============================================================================
# The quiet save of the everyday mode (vibemaestro-sdlc scripts/quiet_save.py, the Stop hook) and its go-back commands.
# Run: bash tests/test-quiet-save.sh
# The Stop hook runs as Claude Code runs it (the `command` of hooks/hooks.json, synchronously here), on the real plugin, with a
# scratch HOME. The cases follow the study of the everyday mode (its runs K and O).
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
PL="$SRC_ROOT/plugins/vibemaestro-sdlc"
HOOKS="$PL/hooks/hooks.json"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
export VIBEMAESTRO_NO_UPDATE_CHECK=1 PYTHONDONTWRITEBYTECODE=1
baton_set_mode "$XDG_STATE_HOME" manual
unset VIBEMAESTRO_PROFILE GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

stop() {  # stop <dir> [env…] — the Stop hook of hooks.json for a session in <dir>; prints its stdout, then rc=<n>
  local d=$1 c out rc; shift
  c=$(hook_cmds "$HOOKS" Stop "")
  out=$(cd "$d" && printf '{"session_id":"s1","hook_event_name":"Stop","cwd":"%s"}' "$d" \
        | env "$@" CLAUDE_PLUGIN_ROOT="$PL" CLAUDE_PROJECT_DIR="$d" bash -c "$c" 2>&1); rc=$?
  printf '%s\nrc=%d' "$out" "$rc"
}
core() {  # core <dir> [env…] — Claude's context from the session-start core hook in <dir> (the save line goes there, said in the person's language)
  local d=$1 c; shift
  c=$(hook_cmds "$HOOKS" SessionStart "" | sed -n 1p)
  ctx "$(cd "$d" && p_start "$(sid)" | env "$@" CLAUDE_PLUGIN_ROOT="$PL" CLAUDE_PROJECT_DIR="$d" bash -c "$c" 2>/dev/null)"
}
coresys() {  # coresys <dir> [env…] — what the person sees: the systemMessage of the same hook
  local d=$1 c; shift
  c=$(hook_cmds "$HOOKS" SessionStart "" | sed -n 1p)
  sysm "$(cd "$d" && p_start "$(sid)" | env "$@" CLAUDE_PLUGIN_ROOT="$PL" CLAUDE_PROJECT_DIR="$d" bash -c "$c" 2>/dev/null)"
}
saves() { git -C "$1" rev-list --count HEAD 2>/dev/null || echo 0; }
tracked() { git -C "$1" ls-files | sort | tr '\n' ' '; }
gitsum() { (cd "$1/.git" 2>/dev/null && find . -type f -print0 | sort -z | xargs -0 sha1sum | sha1sum | cut -c1-12) || echo none; }

echo "== [S] a plain folder in everyday mode is saved after a turn =="
P="$TMP/report"; mkdir -p "$P/kb"; printf '<h1>Q3</h1>\n' > "$P/report.html"; printf 'viec\n' > "$P/kb/viec.md"
printf 'KEY=1\n' > "$P/.env"; printf 'k\n' > "$P/id.key"; printf 'x\n' > "$P/prod.env"; printf 'x\n' > "$P/secrets.yaml"
eq "$(stop "$P")" "$(printf '\nrc=0')" "[S1] the hook prints nothing and exits 0"
eq "$(saves "$P")" 1 "[S1] one save"
eq "$(tracked "$P")" "kb/viec.md report.html " "[S1] the report and the notebook are saved; .env, id.key, prod.env, secrets.yaml are not"
eq "$(git -C "$P" config --local --get vibemaestro.quietsave)" true "[S1] the history carries the kit's mark"
eq "$(git -C "$P" log -1 --format='%an|%ae')" "quiet-save|" "[S1] saved by quiet-save, with no e-mail"
eq "$(git -C "$P" config --get user.name)" "" "[S1] no name was written into the person's git config"
stop "$P" >/dev/null
eq "$(saves "$P")" 1 "[S2] a turn that changed nothing makes no save"
printf '<h1>Q3 v2</h1>\n' > "$P/report.html"
stop "$P" GIT_AUTHOR_NAME=someone GIT_COMMITTER_NAME=someone >/dev/null
eq "$(saves "$P")" 2 "[S2] a turn that changed a file makes one save"
eq "$(git -C "$P" log -1 --format='%an')" "quiet-save" "[S2] …still by quiet-save when the session sets a git author"
printf '[commit]\n\tgpgsign = true\n' >> "$GIT_CONFIG_GLOBAL"
printf 'more\n' >> "$P/kb/viec.md"; stop "$P" >/dev/null
eq "$(saves "$P")" 3 "[S3] a machine that signs every commit: the save is still made (signing off for the save)"
printf '' > "$GIT_CONFIG_GLOBAL"
hasnt "$(core "$P")" "the last quiet save of this folder" "[S3] after a good save the session start has no save line"   # one read: no second capture to compare, so no CR or grep difference on Windows

echo "== [N] never a save outside everyday mode, never into a history the kit did not make =="
R="$TMP/dev"; mkdir -p "$R"; printf 'a\n' > "$R/app.js"; git_ -C "$R" init -q -b main; git_ -C "$R" add -A; git_ -C "$R" commit -qm c1
git_ init -q --bare "$R.git"; git_ -C "$R" remote add origin "$R.git"; printf 'b\n' > "$R/new.js"
S0=$(gitsum "$R"); O=$(stop "$R")
eq "$O" "$(printf '\nrc=0')" "[N1] a developer repository with a remote: nothing printed, rc 0"
eq "$(gitsum "$R")" "$S0" "[N1] …and not one byte of its .git changed"
L="$TMP/devlocal"; mkdir -p "$L"; printf 'a\n' > "$L/app.js"; git_ -C "$L" init -q -b main; git_ -C "$L" add -A; git_ -C "$L" commit -qm c1
printf 'b\n' > "$L/new.js"; S0=$(gitsum "$L"); stop "$L" >/dev/null
eq "$(gitsum "$L")" "$S0" "[N2] a repository that was there before, no remote: not one byte of its .git changed"
S0=$(gitsum "$L"); stop "$L" VIBEMAESTRO_PROFILE=everyday >/dev/null
eq "$(gitsum "$L")" "$S0" "[N2] …nor with the person's everyday (the save never writes a history the kit did not make)"
eq "$(core "$L" VIBEMAESTRO_PROFILE=everyday | grep -c 'the last quiet save of this folder')" 0 "[N2] …and that is by design: no save line at session start"
F="$TMP/fkey"; mkdir -p "$F/.vibemaestro"; printf 'x\n' > "$F/a.txt"; printf '{"schema": 1, "profile": "developer"}\n' > "$F/.vibemaestro/sdlc.json"
stop "$F" >/dev/null; eq "$(test -e "$F/.git" && echo git || echo none)" none "[N3] a plain folder whose key says developer: no history made"
W="$TMP/worker"; mkdir -p "$W"; printf 'x\n' > "$W/a.txt"; stop "$W" VIBEMAESTRO_ROLE=worker >/dev/null
eq "$(test -e "$W/.git" && echo git || echo none)" none "[N3] a worker session in a plain folder: no history made"
OFF="$TMP/off"; mkdir -p "$OFF/.vibemaestro"; printf 'x\n' > "$OFF/a.txt"; printf '{"schema": 1, "hooks": "off"}\n' > "$OFF/.vibemaestro/sdlc.json"
stop "$OFF" >/dev/null; eq "$(test -e "$OFF/.git" && echo git || echo none)" none "[N3] hooks: off: no history made"

echo "== [P] places that are never turned into a history, each said at the next session start =="
place() {  # place <dir under HOME> <words the line holds>
  mkdir -p "$1"; printf 'x\n' > "$1/a.txt"; stop "$1" >/dev/null
  eq "$(test -e "$1/.git" && echo git || echo none)" none "[P] ${1#"$HOME"/}: no history made"
  has "$(core "$1")" "$2" "[P] ${1#"$HOME"/}: the session start says why"
}
place "$HOME/Desktop" "Desktop itself is not saved"
place "$HOME/documents" "documents itself is not saved"
place "$HOME/OneDrive - Firma" "OneDrive - Firma itself is not saved"
OD_WORDS="OneDrive/Documents"; [ "${OS:-}" = Windows_NT ] && OD_WORDS='OneDrive\Documents'   # the kit names it in the system's own form
place "$HOME/OneDrive/Documents" "$OD_WORDS itself is not saved"
mkdir -p "$HOME/OneDrive/Documents/Projects/app"; printf 'x\n' > "$HOME/OneDrive/Documents/Projects/app/a.txt"
stop "$HOME/OneDrive/Documents/Projects/app" >/dev/null
eq "$(saves "$HOME/OneDrive/Documents/Projects/app")" 1 "[P] control: a project deeper inside OneDrive is saved"
printf 'x\n' > "$HOME/notes.txt"; stop "$HOME" >/dev/null
eq "$(test -e "$HOME/.git" && echo git || echo none)" none "[P] the home folder itself: no history made"
has "$(core "$HOME")" "the home folder (or a folder above it) is not saved" "[P] …and the session start says why"
BIG="$TMP/big"; mkdir -p "$BIG"; (cd "$BIG" && for i in $(seq 1 2001); do : > "f$i"; done); stop "$BIG" >/dev/null
eq "$(test -e "$BIG/.git" && echo git || echo none)" none "[P] a first save of 2001 files: no history made"
has "$(core "$BIG")" "more than 2000 files" "[P] …and the session start says why"
rm -f "$BIG/f2001"; stop "$BIG" >/dev/null
eq "$(saves "$BIG")" 1 "[P] control: 2000 files are saved"

echo "== [H] a parent repository, or a git that cannot read the folder: nothing written into it, no history nested =="
PAR="$TMP/parent"; mkdir -p "$PAR/proj"; printf 'p\n' > "$PAR/top.txt"; printf 'x\n' > "$PAR/proj/a.txt"
mkdir -p "$PAR/.ssh"; printf 'secret\n' > "$PAR/.ssh/config"
git_ -C "$PAR" init -q -b main; git_ -C "$PAR" add top.txt; git_ -C "$PAR" commit -qm c1
S0=$(gitsum "$PAR"); stop "$PAR/proj" >/dev/null
eq "$(gitsum "$PAR")" "$S0" "[H1] a project inside another repository: the parent's .git unchanged (its .ssh never committed)"
eq "$(test -e "$PAR/proj/.git" && echo git || echo none)" none "[H1] …and no history nested in the project"
DUB="$TMP/dub"; mkdir -p "$DUB"; printf 'x\n' > "$DUB/a.txt"; git_ -C "$DUB" init -q -b main
git_ -C "$DUB" config --local vibemaestro.quietsave true; S0=$(gitsum "$DUB")
stop "$DUB" GIT_TEST_ASSUME_DIFFERENT_OWNER=1 >/dev/null
eq "$(gitsum "$DUB")" "$S0" "[H2] git refuses the kit's own folder (dubious ownership): nothing written"
eq "$(find "$DUB" -name .git | wc -l | tr -d ' ')" 1 "[H2] …and no history started over it"
has "$(core "$DUB" GIT_TEST_ASSUME_DIFFERENT_OWNER=1)" "the last quiet save of this folder did not happen: Git cannot read this folder" \
    "[H2] …and the next session start says so (the folder stays in everyday mode: the kit's mark is read from its config file)"

echo "== [M] a half-done merge, a refused commit, a save that never finished =="
MG="$TMP/merge"; mkdir -p "$MG"; printf 'base\n' > "$MG/f.txt"; stop "$MG" >/dev/null
git -C "$MG" checkout -q -b other; printf 'other\n' > "$MG/f.txt"; git -C "$MG" -c user.name=t -c user.email=t@t commit -qam o
git -C "$MG" checkout -q main 2>/dev/null || git -C "$MG" checkout -q master; printf 'mine\n' > "$MG/f.txt"
git -C "$MG" -c user.name=t -c user.email=t@t commit -qam m; git -C "$MG" -c user.name=t -c user.email=t@t merge -q other >/dev/null 2>&1
eq "$(test -e "$MG/.git/MERGE_HEAD" && echo merging)" merging "instrument: a merge with a conflict is half done"
N0=$(saves "$MG"); stop "$MG" >/dev/null
eq "$(saves "$MG")" "$N0" "[M1] during a half-done merge: no save"
eq "$(test -e "$MG/.git/MERGE_HEAD" && echo merging)" merging "[M1] …and the merge state is left as it was"
has "$(core "$MG")" "a merge or a similar Git operation is half done" "[M1] …and the session start says why"
eq "$(coresys "$MG")" "" "[M1] …to Claude only: the person sees no fixed-language line"
RF="$TMP/refused"; mkdir -p "$RF"; printf 'x\n' > "$RF/a.txt"; stop "$RF" >/dev/null
printf '#!/bin/sh\necho "secret found" >&2\nexit 1\n' > "$RF/.git/hooks/pre-commit"; chmod +x "$RF/.git/hooks/pre-commit"
printf 'y\n' >> "$RF/a.txt"; stop "$RF" >/dev/null
eq "$(saves "$RF")" 1 "[M2] the person's commit hook refuses: no save (the hook is not skipped)"
has "$(core "$RF")" "the last quiet save of this folder did not happen: the save was refused (secret found)" "[M2] …and the next session start says so"
rm -f "$RF/.git/hooks/pre-commit"; stop "$RF" >/dev/null
eq "$(core "$RF" | grep -c 'the last quiet save of this folder')" 0 "[M2] the next good save clears the line"
python3 -c 'import json, sys, time; sys.path.insert(0, sys.argv[1]); import everyday
p = everyday.trace_path(sys.argv[2]); json.dump({"state": "started", "why": "", "at": time.time() - 900}, open(p, "w"))' "$PL/scripts" "$RF"
has "$(core "$RF")" "the last quiet save of this folder did not finish (it was stopped or timed out)" "[M3] a save that started and never wrote its result is said at session start"
python3 -c 'import json, sys, time; sys.path.insert(0, sys.argv[1]); import everyday
p = everyday.trace_path(sys.argv[2]); json.dump({"state": "started", "why": "", "at": time.time() - 5}, open(p, "w"))' "$PL/scripts" "$RF"
eq "$(core "$RF" | grep -c 'the last quiet save of this folder')" 0 "[M3] refusal: a save that started a few seconds ago is still running, no line"
# a run killed while holding the lock: its "started" marker (15 minutes old) and its lock (5 minutes old, not yet stale); then a
# run that meets the lock must leave the marker alone, so the next session start still says that save did not finish
python3 -c 'import json, sys, time; sys.path.insert(0, sys.argv[1]); import everyday
p = everyday.trace_path(sys.argv[2]); json.dump({"state": "started", "why": "", "at": time.time() - 900}, open(p, "w"))' "$PL/scripts" "$RF"
: > "$RF/.git/quiet-save.lock"; touch -d '5 minutes ago' "$RF/.git/quiet-save.lock"
T0=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import everyday; print(open(everyday.trace_path(sys.argv[2])).read())' "$PL/scripts" "$RF")
printf 'z\n' >> "$RF/a.txt"; N0=$(saves "$RF"); stop "$RF" >/dev/null
eq "$(saves "$RF")" "$N0" "[M4] a run that meets the lock of a killed run makes no save"
eq "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import everyday; print(open(everyday.trace_path(sys.argv[2])).read())' "$PL/scripts" "$RF")" "$T0" \
   "[M4] …and leaves the killed run's started marker as it was"
has "$(core "$RF")" "the last quiet save of this folder did not finish (it was stopped or timed out)" "[M4] …so the next session start still tells the person"
rm -f "$RF/.git/quiet-save.lock"

echo "== [C] two saves at once =="
CC="$TMP/conc"; mkdir -p "$CC"; printf 'x\n' > "$CC/a.txt"; stop "$CC" >/dev/null
for i in $(seq 1 20); do printf '%s\n' "$i" > "$CC/f$i.txt"; done
stop "$CC" > "$TMP/c1.out" & stop "$CC" > "$TMP/c2.out" & wait
eq "$(tail -c 4 "$TMP/c1.out")$(tail -c 4 "$TMP/c2.out")" "rc=0rc=0" "[C1] both hooks exit 0"
eq "$(git -C "$CC" fsck --no-progress 2>&1 | grep -ciE 'error|missing|broken')" 0 "[C1] the history is sound"
eq "$(git -C "$CC" status --porcelain | wc -l | tr -d ' ')" 0 "[C1] every file is in a save"
eq "$(test -e "$CC/.git/index.lock" -o -e "$CC/.git/quiet-save.lock" && echo lock || echo none)" none "[C1] no lock left behind"

echo "== [R] review round 1: the cases each finding named =="
E="$TMP/empty"; mkdir -p "$E"; stop "$E" >/dev/null
eq "$(test -e "$E/.git" && echo git || echo none)" none "[R1] an empty folder gets no history (git clone <url> . still works there)"
printf 'x\n' > "$E/a.txt"; stop "$E" >/dev/null; eq "$(saves "$E")" 1 "[R1] control: once it holds a file, it is saved"
NM="$TMP/web"; mkdir -p "$NM/node_modules/pkg"; printf '<p>hi</p>\n' > "$NM/index.html"
(cd "$NM/node_modules/pkg" && for i in $(seq 1 2500); do : > "f$i"; done); stop "$NM" >/dev/null
eq "$(tracked "$NM")" "index.html " "[R2] 2500 files in node_modules do not stop the first save, and are not saved"
SEC="$TMP/secrets"; mkdir -p "$SEC/.docker" "$SEC/.kube"; printf 'ok\n' > "$SEC/notes.md"
for f in id_ecdsa id_dsa putty.ppk token.json .envrc .htpasswd release.keystore app.jks vpn.ovpn .docker/config.json .kube/config \
         passwords.txt .npmrc .git-credentials; do printf 's\n' > "$SEC/$f"; done
stop "$SEC" >/dev/null
eq "$(tracked "$SEC")" "notes.md " "[R3] 14 more common secret names are not saved (keys, tokens, keystores, VPN, docker, kube, passwords)"
CS="$TMP/claudesettings"; mkdir -p "$CS/.claude"; printf 'x\n' > "$CS/a.txt"; printf '{"env": {"API_KEY": "k"}}\n' > "$CS/.claude/settings.local.json"
stop "$CS" >/dev/null
eq "$(tracked "$CS")" "a.txt " "[R3] Claude Code's .claude/settings.local.json (it can hold keys in its env block) is not saved"
mkdir -p "$TMP/data/Desktop"; printf 'x\n' > "$TMP/data/Desktop/a.txt"; ln -s "$TMP/data/Desktop" "$HOME/Desktop2"
rm -rf "$HOME/Desktop"; ln -s "$TMP/data/Desktop" "$HOME/Desktop"; stop "$HOME/Desktop" >/dev/null
eq "$(test -e "$TMP/data/Desktop/.git" && echo git || echo none)" none "[R4] a Desktop that is a link to another place: no history made"
place "$HOME/Downloads" "Downloads itself is not saved"
CL="$TMP/clone"; mkdir -p "$CL/tool"; printf 'x\n' > "$CL/notes.md"; git_ -C "$CL/tool" init -q -b main
printf 'v1\n' > "$CL/tool/main.py"; git_ -C "$CL/tool" add -A; git_ -C "$CL/tool" commit -qm t; stop "$CL" >/dev/null
has "$(core "$CL")" "kept the folder but not the inside of tool, which has a Git history of its own" "[R6] a repository cloned inside: the session start says its inside is not saved"
rm -rf "$CL/tool/.git"; printf 'v2\n' > "$CL/tool/main.py"; stop "$CL" >/dev/null
eq "$(tracked "$CL")" "notes.md tool/main.py " "[R6] once that inner .git is deleted, its files are in the next save as plain files"
eq "$(git -C "$CL" show HEAD:tool/main.py)" "v2" "[R6] …with their content"
eq "$(core "$CL" | grep -c 'inside of tool')" 0 "[R6] …and the session start no longer names it"
VN="$TMP/vn"; mkdir -p "$VN/chương 1"; printf 'x\n' > "$VN/Tiếng Việt.txt"; printf 'y\n' > "$VN/chương 1/bài.md"; stop "$VN" >/dev/null
eq "$(git -c core.quotePath=false -C "$VN" ls-files | sort | tr '\n' ' ')" "Tiếng Việt.txt chương 1/bài.md " "[R7] Vietnamese names, in a folder and a file, are saved as they are"
DH="$TMP/detached"; mkdir -p "$DH"; printf 'a\n' > "$DH/a.txt"; stop "$DH" >/dev/null; git -C "$DH" checkout -q --detach
printf 'b\n' >> "$DH/a.txt"; stop "$DH" >/dev/null
eq "$(git -C "$DH" rev-list --count --all)" 1 "[R9] a detached HEAD: no save"
has "$(core "$DH")" "not on a branch (detached)" "[R9] …and the session start says why"
RB="$TMP/rebase"; mkdir -p "$RB"; printf 'a\n' > "$RB/a.txt"; stop "$RB" >/dev/null; mkdir -p "$RB/.git/rebase-merge"
printf 'b\n' >> "$RB/a.txt"; stop "$RB" >/dev/null; eq "$(saves "$RB")" 1 "[R9] a rebase half done: no save"
LK="$TMP/locks"; mkdir -p "$LK"; printf 'a\n' > "$LK/a.txt"; stop "$LK" >/dev/null
: > "$LK/.git/index.lock"; touch -d '20 minutes ago' "$LK/.git/index.lock"; printf 'b\n' >> "$LK/a.txt"; stop "$LK" >/dev/null
eq "$(saves "$LK")" 2 "[R10] git's index.lock left 20 minutes ago (a killed git): cleared, the save is made"
: > "$LK/.git/quiet-save.lock"; touch -d '20 minutes ago' "$LK/.git/quiet-save.lock"; printf 'c\n' >> "$LK/a.txt"; stop "$LK" >/dev/null
eq "$(saves "$LK")" 3 "[R10] the save's own lock left 20 minutes ago: taken over, the save is made"
: > "$LK/.git/quiet-save.lock"; printf 'd\n' >> "$LK/a.txt"; stop "$LK" >/dev/null
eq "$(saves "$LK")" 3 "[R10] refusal: a lock just taken (another save running): no second save at once"
rm -f "$LK/.git/quiet-save.lock"

echo "== [T] review round 2: the cases each finding named =="
OW="$TMP/ordinary"; mkdir -p "$OW/pages"; printf 'x\n' > "$OW/index.html"
for f in pages/forgot-password.html pages/reset_password.py change-password.tsx secretary-schedule.csv design-tokens.json \
         credentials_form.md "Q3 report.key"; do printf 'x\n' > "$OW/$f"; done
stop "$OW" >/dev/null
eq "$(tracked "$OW")" "change-password.tsx credentials_form.md design-tokens.json index.html pages/forgot-password.html pages/reset_password.py secretary-schedule.csv " \
   "[T1] ordinary files whose names hold password, token, secret or credentials are saved"
eq "$(git -C "$OW" log --all --name-only --format= | grep -c 'report.key')" 0 "[T1] a file with a secret-looking name (a Keynote deck is *.key) is in no save"
EI="$TMP/emptyinner"; mkdir -p "$EI/new"; printf 'x\n' > "$EI/notes.md"; printf 'y\n' > "$EI/new/a.py"; git_ -C "$EI/new" init -q -b main
stop "$EI" >/dev/null
eq "$(test -e "$EI/.git" && saves "$EI" || echo 0)" 0 "[T2] a repository inside with no commit yet: the save stops safely (nothing recorded)"
has "$(core "$EI")" "the folder new has a Git history of its own with nothing in it yet, so the save stopped" "[T2] …and the session start names the folder"
has "$(core "$EI")" "delete its hidden .git folder if that history is not needed" "[T2] …and says what to do"
CLD="$TMP/claudeonly"; mkdir -p "$CLD/.claude"; printf '{}\n' > "$CLD/.claude/settings.local.json"; stop "$CLD" >/dev/null
eq "$(test -e "$CLD/.git" && echo git || echo none)" none "[T3] a folder holding only Claude Code's .claude/ counts as empty: no history"
VE="$TMP/venv"; mkdir -p "$VE/venv/lib"; printf 'x\n' > "$VE/main.py"; printf 'y\n' > "$VE/venv/lib/x.py"; stop "$VE" >/dev/null
eq "$(tracked "$VE")" "main.py " "[T4] a venv/ folder (no dot) is not saved"
KM="$TMP/kitmade"; mkdir -p "$KM/.git"; printf '[vibemaestro]\n\tquietsave = true\n[remote.origin]\n\turl = x\n' > "$KM/.git/config"
eq "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import everyday; print(everyday.kit_made(sys.argv[2]))' "$PL/scripts" "$KM")" False \
   "[T6] a kit mark with a remote in the [remote.origin] form is not taken for the kit's own history"
printf '[vibemaestro]\n\tquietsave = true\n' > "$KM/.git/config"
eq "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import everyday; print(everyday.kit_made(sys.argv[2]))' "$PL/scripts" "$KM")" True \
   "[T6] control: the mark with no remote is"

echo "== [U] review round 3, after the coordinator's (b): one case per defect =="
DR="$TMP/drafts"; mkdir -p "$DR/Draft [2]" "$DR/Draft 2"; printf 'k\n' > "$DR/Draft 2/keep.md"; printf 'a\n' > "$DR/Draft [2]/a.py"
git_ -C "$DR/Draft [2]" init -q -b main; stop "$DR" >/dev/null
# Git for Windows does not take an inner folder with an empty history for a repository: the save keeps its files as plain
# files (no work lost, the inner history untouched), so there is no inner repository to stop at (a known limit, README)
if [ "${OS:-}" = Windows_NT ]; then
  eq "$(saves "$DR")|$(tracked "$DR")" "1|Draft 2/keep.md Draft [2]/a.py " "[U1] Windows: next to Draft [2] with an empty history the save is made and holds its files as plain files (known limit)"
else
  has "$(core "$DR")" "the folder Draft [2] has a Git history of its own with nothing in it yet" "[U1] next to a repository named Draft [2] with no commit: the save stops with the line"
fi
rm -rf "$DR/Draft [2]/.git"; stop "$DR" >/dev/null
eq "$(tracked "$DR")" "Draft 2/keep.md Draft [2]/a.py " "[U1] once that history is gone, Draft [2] and Draft 2 are both saved (no pattern left behind)"
eq "$(core "$DR" | grep -c 'the last quiet save of this folder')" 0 "[U1] …and the line is gone"
GI="$TMP/gitignored"; mkdir -p "$GI/dist"; printf 'dist/\n*.log\n' > "$GI/.gitignore"; printf 'x\n' > "$GI/index.html"
printf 'b\n' > "$GI/dist/app.js"; printf 'l\n' > "$GI/debug.log"; printf 'K=1\n' > "$GI/.env"; stop "$GI" >/dev/null
eq "$(git -C "$GI" log --all --name-only --format= | grep -c -e '^\.env$' -e 'debug.log' -e '^dist/')" 0 "[U3] the .env, and what the person's .gitignore leaves out, are in no save"
QT="$TMP/quote"; mkdir -p "$QT/John's notes"; printf 'x\n' > "$QT/a.md"; printf 'y\n' > "$QT/John's notes/n.md"
git_ -C "$QT/John's notes" init -q -b main; stop "$QT" >/dev/null
# Git for Windows does not take an inner folder with an empty history for a repository: the save keeps its files as plain
# files (no work lost, the inner history untouched), so there is no inner repository to stop at (a known limit, README)
if [ "${OS:-}" = Windows_NT ]; then
  eq "$(saves "$QT")|$(tracked "$QT")" "1|John's notes/n.md a.md " "[U4] Windows: with John's notes holding an empty history the save is made and holds its files as plain files (known limit)"
else
  has "$(core "$QT")" "the folder John's notes has a Git history of its own with nothing in it yet" "[U4] a repository with a quote in its name and no commit: the plain line, not a broken save"
fi

echo "== [V] the coordinator's last points =="
eq "$(git -C "$P" log --all --name-only --format= | grep -c -e '\.env$' -e 'id\.key' -e 'prod\.env' -e 'secrets\.yaml')" 0 "[V1] the secret-named files of the first folder are in no save, whatever was saved since"
OB="$TMP/orphan"; mkdir -p "$OB/inner"; printf 'x\n' > "$OB/a.md"; printf 'y\n' > "$OB/inner/b.md"; git_ -C "$OB/inner" init -q -b main
git_ -C "$OB/inner" add -A; git_ -C "$OB/inner" commit -qm c1; git -C "$OB/inner" checkout -q --orphan fresh; stop "$OB" >/dev/null
has "$(core "$OB")" "the folder inner is a Git repository whose current branch has nothing in it yet, so the save stopped" "[V2] an inner repository with commits on other branches only: the line says its current branch is empty"

echo "== [G] list the saves and copy one out into ban-cu/, never over the work folder (row D) =="
QS="$PL/scripts/quiet_save.py"
qs() { python3 "$QS" "$@" | tr -d '\r'; }   # Python on Windows ends a printed line with CR LF; the rc is python's (pipefail)
idof() { qs list --dir "$1" | sed -n "${2}p" | sed -nE 's/.*\[([0-9a-f]{8})\]$/\1/p'; }   # idof <dir> <line> — the id of a save
histsum() { (cd "$1/.git" && find . -type f ! -path ./quiet-save-copies -print0 | sort -z | xargs -0 sha1sum | sha1sum | cut -c1-12); }   # the history but the kit's list of copies
outside() { (cd "$1" && find . -path ./.git -prune -o -path ./ban-cu -prune -o -name .ignore -prune -o -type f -print0 | sort -z | xargs -0 sha1sum | sha1sum | cut -c1-12); }
G="$TMP/goback"; mkdir -p "$G/kb" "$G/chương 1"; printf '<h1>v1</h1>\n' > "$G/report.html"; printf 'viec\n' > "$G/kb/viec.md"
printf 'K=1\n' > "$G/.env"; printf 'n\n' > "$G/chương 1/bài.md"; stop "$G" >/dev/null
printf '<h1>v2</h1>\n' > "$G/report.html"; stop "$G" >/dev/null
LST=$(qs list --dir "$G")
eq "$(printf '%s\n' "$LST" | grep -cE '^[12]\. [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}  .*  \[[0-9a-f]{8}\]$')" 2 "[G1] the list: number, time to the second, files, id in brackets, newest first"
has "$(printf '%s\n' "$LST" | sed -n 1p)" "report.html (changed)" "[G1] …the newest save changed the report"
has "$(printf '%s\n' "$LST" | sed -n 2p)" "chương 1/bài.md (added)" "[G1] …a Vietnamese name is listed as it is"
eq "$(qs list --dir "$G/chương 1" | grep -c '^[12]\. ')" 2 "[G1] the list from a sub-folder reads the folder's history"
V1=$(idof "$G" 2); WHEN=$(git -C "$G" log -1 --date=format:%Y-%m-%d-%H%M%S --format=%ad "$V1")
O0=$(outside "$G"); S0=$(histsum "$G"); printf 'broken\n' > "$G/report.html"; O0=$(outside "$G")
OUT=$(qs copy "$V1" --dir "$G"); rc=$?
eq "$rc" 0 "[G2] copying the first save out: rc 0"
has "$OUT" "is copied into ban-cu/$WHEN. Nothing in the work folder was changed" "[G2] …the answer names the copy's folder"
eq "$(cat "$G/ban-cu/$WHEN/report.html") $(cat "$G/ban-cu/$WHEN/kb/viec.md") $(cat "$G/ban-cu/$WHEN/chương 1/bài.md")" "<h1>v1</h1> viec n" "[G2] the copy holds every file of that save"
eq "$(cd "$G/ban-cu/$WHEN" && find . -type f | sort | tr '\n' ' ')" "./chương 1/bài.md ./kb/viec.md ./report.html " "[G2] …and nothing but the save's files (nothing of the kit's)"
eq "$(test -e "$G/ban-cu/$WHEN/.env" && echo there || echo absent)" absent "[G2] …and no file the save never kept (.env)"
eq "$(outside "$G") $(cat "$G/report.html")" "$O0 broken" "[G2] every file outside ban-cu/ and .ignore is byte for byte as it was (the broken report stays)"
eq "$(histsum "$G")" "$S0" "[G2] the hidden history (objects, index, HEAD) is not changed by one byte; only the kit's list of copies is new"
OUT=$(qs copy "$V1" --dir "$G")
has "$OUT" "is copied into ban-cu/$WHEN-2." "[G3] the same save copied again goes to a new folder"
eq "$(cat "$G/ban-cu/$WHEN/report.html")" "<h1>v1</h1>" "[G3] …and the first copy is not overwritten"
BF="$TMP/banfile"; mkdir -p "$BF"; printf 'x\n' > "$BF/a.txt"; stop "$BF" >/dev/null; printf 'mine\n' > "$BF/ban-cu"
WB=$(git -C "$BF" log -1 --date=format:%Y-%m-%d-%H%M%S --format=%ad)
eq "$(qs copy "$(idof "$BF" 1)" --dir "$BF")" "The save of $(git -C "$BF" log -1 --date=format:'%Y-%m-%d %H:%M:%S' --format=%ad) is copied into ban-cu-2/$WB (ban-cu-2/ is used because ban-cu/ is yours). Nothing in the work folder was changed; take the files you need from the copy." "[G4] a file named ban-cu: the copy goes to ban-cu-2/, the answer says why in one line"
eq "$(cat "$BF/ban-cu") $(cat "$BF/ban-cu-2/$WB/a.txt") $(cat "$BF/.ignore")" "mine x /ban-cu-2/" "[G4] …the file untouched, .ignore names the folder used"
BD="$TMP/bandir"; mkdir -p "$BD/ban-cu"; printf 'x\n' > "$BD/a.txt"; printf 'my plan\n' > "$BD/ban-cu/plan.md"; stop "$BD" >/dev/null
has "$(qs copy "$(idof "$BD" 1)" --dir "$BD")" "is copied into ban-cu-2/" "[G4] a folder of the person's named ban-cu (no kit marker): the copy goes to ban-cu-2/"
eq "$(ls "$BD/ban-cu" | tr '\n' ' ') $(cat "$BD"/ban-cu-2/2*/a.txt)" "plan.md  x" "[G4] …nothing is written into the person's ban-cu/"
printf 'my plan v2\n' > "$BD/ban-cu/plan.md"; stop "$BD" >/dev/null
eq "$(git -C "$BD" show HEAD:ban-cu/plan.md) $(git -C "$BD" log --all --name-only --format= | grep -c '^ban-cu-2/')" "my plan v2 0" "[G4] …the person's ban-cu/ is still saved, the kit's ban-cu-2/ is not"
has "$(qs copy "$(idof "$BD" 1)" --dir "$BD")" "is copied into ban-cu-2/" "[G4] a later copy goes to the same kit folder ban-cu-2/"
eq "$(qs drop-copy ban-cu/plan.md --dir "$BD")$(cat "$BD/ban-cu/plan.md")" "Nothing changed: ban-cu/plan.md is not one of the kit's old copies.my plan v2" "[G4] drop-copy inside the person's ban-cu/: refused"
has "$(cat "$G/ban-cu/DAY-LA-BAN-CU.txt")" "ĐÂY LÀ BẢN CŨ" "[G5] ban-cu/ carries the plain-words marker in Vietnamese…"
has "$(cat "$G/ban-cu/DAY-LA-BAN-CU.txt")" "THESE ARE OLD COPIES" "[G5] …and in English"
eq "$(cat "$G/.ignore")" "/ban-cu/" "[G5] .ignore holds /ban-cu/ (made when missing), once after two copies"
IGN="$TMP/ignoreuser"; mkdir -p "$IGN"; printf 'x\n' > "$IGN/a.txt"; printf 'node_modules/\n*.log' > "$IGN/.ignore"; stop "$IGN" >/dev/null
qs copy "$(idof "$IGN" 1)" --dir "$IGN" >/dev/null
eq "$(cat "$IGN/.ignore" | tr '\n' '|')" "node_modules/|*.log|/ban-cu/|" "[G5] an existing .ignore keeps every line of the person's, the kit's line added once"
RG=$(command -v rg || true)
if [ -n "$RG" ]; then
  eq "$(cd "$G" && rg --files | grep -c -e '^ban-cu/' -e '^\.git/')" 0 "[G5][G8] ripgrep (Claude Code's search) lists nothing in ban-cu/ or the hidden history"
  eq "$(cd "$G" && rg --files --hidden --no-ignore | grep -c -e '^ban-cu/' -e '^\.git/' | awk '{print ($1 > 0)}')" 1 "[G5][G8] control: with --hidden --no-ignore ripgrep does see them"
else
  echo "  note: rg not found on PATH: the ripgrep check of ban-cu/ and the hidden history did not run (.ignore and the marker are checked above)"
fi
has "$(cd "$G" && p_start "$(sid)" | CLAUDE_PLUGIN_ROOT="$PL" CLAUDE_PROJECT_DIR="$G" bash -c "$(hook_cmds "$HOOKS" SessionStart '' | sed -n 1p)" 2>/dev/null | python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["hookSpecificOutput"]["additionalContext"])')" \
    "holds old copies, not the current work.** Never read, search or edit inside it unless the person asks about an old copy" "[G6] the everyday prompt says never to read or edit inside the kit's ban-cu/ unless asked"
has "$(tr -s ' \n' '  ' < "$PL/templates/everyday-core.md")" "A folder named \`ban-cu\` without that marker (at the top, or inside, such as \`bao-cao/ban-cu/\`) is the person's own folder, part of the work." "[G6] …and that a ban-cu/ without the marker is the person's work"
stop "$G" >/dev/null
eq "$(git -C "$G" log --all --name-only --format= | grep -c '^ban-cu/')" 0 "[G7] the quiet save never saves ban-cu/ (no save holds a path under it)"
eq "$(git -C "$G" show HEAD:report.html)" "broken" "[G7] …while the work folder's change is saved"
mkdir -p "$TMP/outsidedir"; printf 'keep\n' > "$TMP/outsidedir/k.txt"; ln -s "$TMP/outsidedir" "$G/ban-cu/link"
for bad in ../report.html "$G/report.html" "" . .. ban-cu ban-cu/ ban-cu/. ban-cu/.. ban-cu/link "ban-cu/$WHEN/kb" "$WHEN" "/ban-cu/$WHEN" "ban-cu-2/$WHEN"; do
  eq "$(qs drop-copy "$bad" --dir "$G" | head -c 15)" "Nothing changed" "[G9] drop-copy '$bad': refused"
done
eq "$(cat "$G/report.html") $(cat "$TMP/outsidedir/k.txt") $(test -d "$G/ban-cu/$WHEN/kb" && echo kb)" "broken keep kb" "[G9] …nothing outside the named copy, behind a link, or inside a copy was removed"
mkdir -p "$G/ban-cu/my-thesis"; printf 'chapter\n' > "$G/ban-cu/my-thesis/t.md"
OUT=$(qs drop-copy ban-cu/my-thesis --dir "$G"); rc=$?
eq "$rc|$OUT" "1|Nothing changed: ban-cu/my-thesis is not one of the kit's old copies." "[G9] a person's folder inside ban-cu/ (no copy marker): refused, rc 1, one plain line"
eq "$(cat "$G/ban-cu/my-thesis/t.md")" "chapter" "[G9] …and it survives"
eq "$(qs drop-copy "ban-cu/$WHEN-2" --dir "$G")" "The old copy ban-cu/$WHEN-2 is removed." "[G9] drop-copy of one copy, named as copy's answer gave it: removed"
eq "$(test -d "$G/ban-cu/$WHEN-2" && echo there || echo gone) $(test -d "$G/ban-cu/$WHEN" && echo other)" "gone other" "[G9] …only that copy"
ASCII=(LC_ALL=C LANG=C PYTHONUTF8=0 PYTHONCOERCECLOCALE=0)
VF="$TMP/Bài tập"; mkdir -p "$VF"; printf 'one\n' > "$VF/ghi chú.txt"; stop "$VF" "${ASCII[@]}" >/dev/null
printf 'two\n' > "$VF/ghi chú.txt"; stop "$VF" "${ASCII[@]}" >/dev/null
eq "$(saves "$VF")" 2 "[G10] a folder with a Vietnamese name under an ASCII locale: the second quiet save is made too"
has "$(env "${ASCII[@]}" python3 "$QS" list --dir "$VF")" "ghi chú.txt (added)" "[G10] …its list shows the names"
VID=$(qs list --dir "$VF" | sed -n 2p | sed -nE 's/.*\[([0-9a-f]{8})\]$/\1/p'); env "${ASCII[@]}" python3 "$QS" copy "$VID" --dir "$VF" >/dev/null
eq "$(cat "$VF"/ban-cu/*/"ghi chú.txt")" "one" "[G10] …and the copy is made, with the name as it is"
S1=$(gitsum "$L"); eq "$(qs copy 1 --dir "$L")" "Nothing changed: this folder has its own Git history, which the save never writes." "[G11] a developer's repository: copy refuses, saying why"
eq "$(gitsum "$L") $(test -e "$L/ban-cu" && echo ban || echo noban)" "$S1 noban" "[G11] …and writes nothing"
eq "$(qs copy 99 --dir "$G"; echo "rc=$?")" "$(printf 'Nothing changed: there is no save number 99; see the list.\nrc=1')" "[G11] a number with no save: nothing copied, rc 1"
ORPH=$(git -C "$G" commit-tree "$(git -C "$G" rev-parse 'HEAD^{tree}')" -m orphan)
eq "$(qs copy "$ORPH" --dir "$G" | head -c 15)" "Nothing changed" "[G11] a commit that is not one of the folder's saves: refused"
eq "$(qs copy --all --dir "$G" | head -c 15)" "Nothing changed" "[G11] an id that looks like an option: refused"
eq "$(qs copy ² --dir "$G" | head -c 15)" "Nothing changed" "[G11] a non-ASCII digit: refused, no crash"
eq "$(qs list 0 --dir "$G" 2>/dev/null; echo "rc=$?")" "rc=64" "[G11] list 0: a usage error, not 'no saves yet'"
SG="$TMP/stray"; mkdir -p "$SG/.git" "$SG/proj"; printf 'x\n' > "$SG/proj/a.txt"
eq "$(qs list --dir "$SG/proj")" "Nothing changed: this folder has no saves yet." "[G11] under a stray empty .git folder: no saves yet"

echo "== [E] names as git writes them (UTF-8), whatever the locale or the console's code page =="
if [ "${OS:-}" = Windows_NT ]; then echo "  SKIP instrument: Windows takes a pipe's encoding from its code page, not from LANG (the cases below still run)"
else eq "$(env "${ASCII[@]}" python3 -c 'import locale; print(locale.getpreferredencoding(False))')" "ANSI_X3.4-1968" "instrument: under that locale Python decodes pipes as ASCII"; fi
EN="$TMP/encoding"; mkdir -p "$EN"; printf 'x\n' > "$EN/Tiếng Việt.txt"; printf 'old note\n' > "$EN/ghi chú.txt"; stop "$EN" "${ASCII[@]}" >/dev/null
eq "$(git -c core.quotePath=false -C "$EN" ls-files | sort | tr '\n' '|')" "Tiếng Việt.txt|ghi chú.txt|" "[E1] the quiet save under an ASCII locale saves Vietnamese names"
has "$(env "${ASCII[@]}" python3 "$QS" list --dir "$EN")" "Tiếng Việt.txt (added)" "[E2] the list under an ASCII locale shows the names as they are"
has "$(env PYTHONIOENCODING=cp1258 python3 "$QS" list --dir "$EN")" "ghi chú.txt (added)" "[E2] …and under a cp1258 console"

echo "== [K] copy: odd names and links, an inner repository, the lock, a half-done merge (spec risks 1-7) =="
# NTFS holds no name with a trailing space or a newline, and Git Bash's ln -s copies: those parts are POSIX only
POSIX=1; [ "${OS:-}" = Windows_NT ] && POSIX=
OD="$TMP/oddnames"; mkdir -p "$OD/x[1]"; printf 'a\n' > "$OD/x[1]/it's.txt"
[ -n "$POSIX" ] && { printf 'b\n' > "$OD/trail "; printf 'c\n' > "$OD/a
b.txt"; }
can_link && ln -s /etc/hostname "$OD/link"; stop "$OD" >/dev/null
OUT=$(qs copy "$(git -C "$OD" rev-parse --short=8 HEAD)" --dir "$OD"); C=$(ls -d "$OD"/ban-cu/2*/ | head -1)
eq "$(cat "$C/x[1]/it's.txt")" "a" "[K1] a name with brackets and a quote is copied"
if [ -n "$POSIX" ]; then
  eq "$(cat "$C/trail ") $(cat "$C/a
b.txt" | tr '\n' ' ')" "b c " "[K1] names with a trailing space and a newline are copied"
else echo "  SKIP [K1] names with a trailing space or a newline: NTFS cannot hold them"; fi
if can_link; then eq "$(test -L "$C/link" && echo link)" link "[K1] a saved link is copied as a link (nothing written through it)"
else echo "  SKIP [K1] a saved link: ln -s makes no link here (Git Bash copies)"; fi
NR="$TMP/nestedcopy"; mkdir -p "$NR/inner"; printf 'v1\n' > "$NR/a.txt"; printf 'own\n' > "$NR/inner/own.txt"
git_ -C "$NR/inner" init -q -b main; git_ -C "$NR/inner" add -A; git_ -C "$NR/inner" commit -qm i; stop "$NR" >/dev/null
OUT=$(qs copy "$(idof "$NR" 1)" --dir "$NR"); rc=$?
eq "$rc $(cat "$NR"/ban-cu/2*/a.txt) $(cat "$NR/inner/own.txt")" "0 v1 own" "[K2] a save with an inner repository: copied, the inner repository untouched"
LKC="$TMP/lockcopy"; mkdir -p "$LKC"; printf 'a\n' > "$LKC/a.txt"; stop "$LKC" >/dev/null; : > "$LKC/.git/quiet-save.lock"
eq "$(qs copy "$(idof "$LKC" 1)" --dir "$LKC")$(test -e "$LKC/ban-cu" && echo ban)" "Nothing changed: another save of this folder is running." "[K3] copying while a save runs: refused, nothing written"
rm -f "$LKC/.git/quiet-save.lock"
MG2="$TMP/mergecopy"; mkdir -p "$MG2"; printf 'base\n' > "$MG2/f.txt"; stop "$MG2" >/dev/null; BASE=$(idof "$MG2" 1)
git -C "$MG2" checkout -q -b other; printf 'other\n' > "$MG2/f.txt"; git -C "$MG2" -c user.name=t -c user.email=t@t commit -qam o
git -C "$MG2" checkout -q main 2>/dev/null || git -C "$MG2" checkout -q master; printf 'mine\n' > "$MG2/f.txt"
git -C "$MG2" -c user.name=t -c user.email=t@t commit -qam m; git -C "$MG2" -c user.name=t -c user.email=t@t merge -q other >/dev/null 2>&1
qs copy "$BASE" --dir "$MG2" >/dev/null
eq "$(cat "$MG2"/ban-cu/2*/f.txt) $(test -e "$MG2/.git/MERGE_HEAD" && echo merging)" "base merging" "[K4] during a half-done merge the copy only reads: made, the merge state left as it was"

DT="$TMP/detachcopy"; mkdir -p "$DT"; printf 'one\n' > "$DT/f.txt"; stop "$DT" >/dev/null; FIRST=$(idof "$DT" 1)
printf 'two\n' > "$DT/f.txt"; stop "$DT" >/dev/null; git -C "$DT" checkout -q --detach HEAD; S1=$(histsum "$DT")
qs copy "$FIRST" --dir "$DT" >/dev/null
eq "$(cat "$DT"/ban-cu/2*/f.txt) $(histsum "$DT")" "one $S1" "[K5] on a detached HEAD the copy only reads: made, the history not changed"
if can_link; then   # the cases below need a real link
BL="$TMP/banlink"; mkdir -p "$BL" "$TMP/banlink-target"; printf 'x\n' > "$BL/a.txt"; stop "$BL" >/dev/null
printf '%s\n' "$(sed -n 1p "$G/ban-cu/DAY-LA-BAN-CU.txt")" > "$TMP/banlink-target/DAY-LA-BAN-CU.txt"; ln -s "$TMP/banlink-target" "$BL/ban-cu"
mkdir -p "$TMP/banlink-target/x"; cp "$TMP/banlink-target/DAY-LA-BAN-CU.txt" "$TMP/banlink-target/x/"
has "$(qs copy "$(idof "$BL" 1)" --dir "$BL")" "is copied into ban-cu-2/" "[K6] ban-cu as a link (even to a marked folder): passed over, the copy goes to ban-cu-2/"
eq "$(qs drop-copy ban-cu/x --dir "$BL")" "Nothing changed: ban-cu/x is not one of the kit's old copies." "[K6] …and drop-copy through the link refused"
eq "$(ls "$TMP/banlink-target" | tr '\n' ' ')$(cat "$BL/.ignore")" "DAY-LA-BAN-CU.txt x /ban-cu-2/" "[K6] …nothing written or removed through the link"
IL="$TMP/ignorelink"; mkdir -p "$IL"; printf 'x\n' > "$IL/a.txt"; stop "$IL" >/dev/null; printf 'theirs\n' > "$TMP/ignore-target"; ln -s "$TMP/ignore-target" "$IL/.ignore"
eq "$(qs copy "$(idof "$IL" 1)" --dir "$IL")" "Nothing changed: .ignore here is not a plain file, so the old copies could not be kept out of Claude's search." "[K6] .ignore as a link: copy refused"
eq "$(cat "$TMP/ignore-target")$(ls -d "$IL"/ban-cu* 2>/dev/null)" "theirs" "[K6] …the linked file unchanged, no ban-cu folder made"
else echo "  SKIP [K6] ban-cu and .ignore as links: ln -s makes no link here (Git Bash copies the target)"; fi
UM="$TMP/unmarkeddrop"; mkdir -p "$UM/ban-cu/old"; printf 'x\n' > "$UM/a.txt"; printf 'y\n' > "$UM/ban-cu/old/y.txt"; stop "$UM" >/dev/null
eq "$(qs drop-copy ban-cu/old --dir "$UM")$(cat "$UM/ban-cu/old/y.txt")" "Nothing changed: ban-cu/old is not one of the kit's old copies.y" "[K6] drop-copy in a ban-cu/ without the kit's marker: refused, nothing removed"
LK2="$TMP/indexlock"; mkdir -p "$LK2"; printf 'a\n' > "$LK2/a.txt"; stop "$LK2" >/dev/null; : > "$LK2/.git/quiet-save-copy.index.lock"
OUT=$(qs copy "$(idof "$LK2" 1)" --dir "$LK2"); rc=$?
eq "$rc|$OUT" "1|Nothing changed: Git could not write the copy, so no copy was made." "[K7] a fresh lock on the copy's index (a copy still running): refused"
eq "$(test -e "$LK2/ban-cu" && echo ban || echo noban) $(test -e "$LK2/.ignore" && echo ign || echo noign)" "noban noign" "[K7] …no half copy left: the ban-cu/ and the .ignore this run made are gone"
CR="$TMP/crlfignore"; mkdir -p "$CR"; printf 'a\n' > "$CR/a.txt"; stop "$CR" >/dev/null; printf 'node_modules/\r\n*.log\r\n' > "$CR/.ignore"; cp "$CR/.ignore" "$TMP/crlf-before"
: > "$CR/.git/quiet-save-copy.index.lock"; qs copy "$(idof "$CR" 1)" --dir "$CR" >/dev/null
eq "$(cmp -s "$CR/.ignore" "$TMP/crlf-before" && echo same || echo changed)" same "[K7] a failed copy takes back its line from a CRLF .ignore: byte for byte as it was"
rm -f "$CR/.git/quiet-save-copy.index.lock"; printf 'x\r\n/ban-cu/\r\n' > "$CR/.ignore"; cp "$CR/.ignore" "$TMP/crlf-before2"
qs copy "$(idof "$CR" 1)" --dir "$CR" >/dev/null
eq "$(cmp -s "$CR/.ignore" "$TMP/crlf-before2" && echo same || echo changed) $(ls "$CR/ban-cu" | grep -c '^2')" "same 1" "[K7] a CRLF .ignore that already names /ban-cu/ gets no second line"
LK4="$TMP/indexlock4"; mkdir -p "$LK4"; printf 'a\n' > "$LK4/a.txt"; stop "$LK4" >/dev/null; printf 'node_modules/' > "$LK4/.ignore"; : > "$LK4/.git/quiet-save-copy.index.lock"
qs copy "$(idof "$LK4" 1)" --dir "$LK4" >/dev/null
eq "$(od -An -c "$LK4/.ignore" | tr -s ' ')" " n o d e _ m o d u l e s /" "[K7] a failed copy takes back the .ignore line it added: the person's .ignore is byte for byte as it was"
touch -d '2 minutes ago' "$LK2/.git/quiet-save-copy.index.lock"
has "$(qs copy "$(idof "$LK2" 1)" --dir "$LK2")" "is copied into ban-cu/" "[K7] a lock older than the git timeout (a killed copy) is taken over: the copy is made"
eq "$(cat "$LK2"/ban-cu/2*/a.txt) $(test -e "$LK2/.git/quiet-save-copy.index.lock" && echo lock || echo nolock)" "a nolock" "[K7] …with the save's files, the stale lock gone"
LK3="$TMP/indexlock2"; mkdir -p "$LK3"; printf 'a\n' > "$LK3/a.txt"; stop "$LK3" >/dev/null; qs copy "$(idof "$LK3" 1)" --dir "$LK3" >/dev/null
: > "$LK3/.git/quiet-save-copy.index.lock"; qs copy "$(idof "$LK3" 1)" --dir "$LK3" >/dev/null
eq "$(ls "$LK3/ban-cu" | grep -c '^2')$(test -f "$LK3/ban-cu/DAY-LA-BAN-CU.txt" && echo marker)" "1marker" "[K7] a failed copy into an existing ban-cu/ removes only its own folder, never ban-cu/ or another copy"
if [ "$(id -u)" != 0 ]; then
  RO="$TMP/readonlyignore"; mkdir -p "$RO"; printf 'x\n' > "$RO/a.txt"; stop "$RO" >/dev/null; printf 'mine\n' > "$RO/.ignore"; chmod 444 "$RO/.ignore"
  OUT=$(qs copy "$(idof "$RO" 1)" --dir "$RO" 2>&1); rc=$?
  eq "$rc|$OUT" "1|Nothing changed: the copy could not be written (Permission denied), so no copy was made." "[K8] a read-only .ignore: one plain line, no traceback"
  eq "$(test -e "$RO/ban-cu" && echo ban || echo noban) $(cat "$RO/.ignore")" "noban mine" "[K8] …and no old file landed where search could see it"
  chmod 644 "$RO/.ignore"
else
  echo "  note: running as root, so a read-only .ignore cannot be made: [K8] did not run"
fi
MK="$TMP/markedsave"; mkdir -p "$MK"; printf 'x\n' > "$MK/a.txt"; stop "$MK" >/dev/null; qs copy "$(idof "$MK" 1)" --dir "$MK" >/dev/null
printf 'y\n' > "$MK/a.txt"; stop "$MK" >/dev/null
eq "$(git -C "$MK" log --all --name-only --format= | grep -c '^ban-cu/') $(git -C "$MK" show HEAD:.ignore)" "0 /ban-cu/" "[K9] the kit's marked ban-cu/ is not saved (the .ignore line is)"
rm "$MK/ban-cu/DAY-LA-BAN-CU.txt"; stop "$MK" >/dev/null   # not a break: the person removes the kit's marker
has "$(git -C "$MK" ls-files)" "ban-cu/" "[K9] control: once the kit's marker is gone, ban-cu/ is the person's and is saved"
LC="$TMP/listcopy"; mkdir -p "$LC"; printf 'a\n' > "$LC/a.txt"; stop "$LC" >/dev/null; qs copy "$(idof "$LC" 1)" --dir "$LC" >/dev/null
mkdir "$LC/ban-cu/2026-01-01-000000"; printf 'mine\n' > "$LC/ban-cu/2026-01-01-000000/m.txt"
eq "$(qs drop-copy ban-cu/2026-01-01-000000 --dir "$LC")$(cat "$LC/ban-cu/2026-01-01-000000/m.txt")" "Nothing changed: ban-cu/2026-01-01-000000 is not one of the kit's old copies.mine" "[K11] a folder shaped like a copy but not on the kit's list: drop-copy refuses, nothing removed"
C1=$(ls "$LC/ban-cu" | grep -v -e DAY -e 2026-01-01 | head -1)
eq "$(qs drop-copy "ban-cu/$C1" --dir "$LC")" "The old copy ban-cu/$C1 is removed." "[K11] the kit's own copy, on its list: removed"
eq "$(qs drop-copy "ban-cu/$C1" --dir "$LC")" "Nothing changed: ban-cu/$C1 is not one of the kit's old copies." "[K11] …and a second drop of it finds nothing"
qs copy "$(idof "$LC" 1)" --dir "$LC" >/dev/null; C2=$(ls "$LC/ban-cu" | grep -v -e DAY -e 2026-01-01 | head -1)
: > "$LC/.git/quiet-save.lock"
eq "$(qs drop-copy "ban-cu/$C2" --dir "$LC")$(test -d "$LC/ban-cu/$C2" && echo kept)" "Nothing changed: another save of this folder is running.kept" "[K11] drop-copy while a save runs: refused, the copy kept"
rm -f "$LC/.git/quiet-save.lock"; rm -r "$LC/ban-cu/$C2"   # not a break: the person deletes the copy by hand
eq "$(qs drop-copy "ban-cu/$C2" --dir "$LC"; echo "rc=$?")" "$(printf 'The old copy ban-cu/%s is already gone (removed by hand); the kit no longer lists it.\nrc=0' "$C2")" "[K11] drop-copy of a copy the person already deleted: said plainly, rc 0"
eq "$(qs drop-copy "ban-cu/$C2" --dir "$LC")" "Nothing changed: ban-cu/$C2 is not one of the kit's old copies." "[K11] …and its stale entry is cleared"
if can_link; then   # the cases below need a real link
mkdir -p "$TMP/mk-other"; printf 'victim\n' > "$TMP/mk-other/victim.txt"
ML="$TMP/markerlink"; mkdir -p "$ML"; printf 'a\n' > "$ML/a.txt"; ln -s "$TMP/mk-other/victim.txt" "$ML/DAY-LA-BAN-CU.txt"; stop "$ML" >/dev/null
OUT=$(qs copy "$(idof "$ML" 1)" --dir "$ML"); rc=$?; C=$(ls -d "$ML"/ban-cu/2*/ | head -1)
eq "$rc $(readlink "$C/DAY-LA-BAN-CU.txt") $(cat "$TMP/mk-other/victim.txt")" "0 $TMP/mk-other/victim.txt victim" "[K12] a save holding a top-level link named like the marker copies out whole: the link stays a link, its target untouched"
else echo "  SKIP [K12] a top-level link named like the marker: ln -s makes no link here (Git Bash copies the target)"; fi
MF="$TMP/markerfolder"; mkdir -p "$MF/DAY-LA-BAN-CU.txt"; printf 'n\n' > "$MF/DAY-LA-BAN-CU.txt/note.md"; printf 'a\n' > "$MF/a.txt"; stop "$MF" >/dev/null
OUT=$(qs copy "$(idof "$MF" 1)" --dir "$MF"); rc=$?
eq "$rc $(cat "$MF"/ban-cu/2*/DAY-LA-BAN-CU.txt/note.md)" "0 n" "[K12] a save holding a top-level folder named like the marker copies out whole"
XL="$TMP/excludelines"; mkdir -p "$XL"; printf 'a\n' > "$XL/a.txt"; stop "$XL" >/dev/null
printf 'my-notes/\n/ban-cu-7/\nform\fline\n' >> "$XL/.git/info/exclude"; qs copy "$(idof "$XL" 1)" --dir "$XL" >/dev/null; printf 'b\n' > "$XL/a.txt"; stop "$XL" >/dev/null
XT=$(tr -d '\r' < "$XL/.git/info/exclude")   # the kit writes it in text mode: CR LF on Windows, which git reads alike
has "$XT" "$(printf 'my-notes/\n/ban-cu-7/\nform\fline\n')" "[K13] the person's own lines in the hidden exclude list stay as written (a form feed inside a line is not a line break)"
eq "$(printf '%s\n' "$XT" | tail -2 | tr '\n' '|')" "# folders of old copies the kit made (the kit rewrites the lines below)|/ban-cu/|" "[K13] …the kit's folder line sits in its own block, last"
eq "$(saves "$XL") $(git -C "$XL" ls-files | tr '\n' ' ')" "2 .ignore a.txt " "[K13] …and the saves go on, the kit's ban-cu/ left out"
printf '/ban-cu-5/\nmine-after\n' >> "$XL/.git/info/exclude"; mkdir -p "$XL/ban-cu-5"; printf 'p\n' > "$XL/ban-cu-5/p.txt"; printf 'c\n' > "$XL/a.txt"; stop "$XL" >/dev/null
eq "$(grep -cxF -e '/ban-cu-5/' -e 'mine-after' "$XL/.git/info/exclude") $(git -C "$XL" ls-files | grep -c '^ban-cu-5/')" "2 0" "[K13] a person's lines written after the kit's block stay, and their ban-cu-5/ stays out of the saves"

UD="$TMP/undoname"; mkdir -p "$UD"; printf 'r\n' > "$UD/report.txt"; stop "$UD" >/dev/null; qs copy "$(idof "$UD" 1)" --dir "$UD" >/dev/null; stop "$UD" >/dev/null
rm -r "$UD/ban-cu"   # not a break: the person deletes the kit's folder by hand
: > "$UD/.git/quiet-save-copy.index.lock"; qs copy "$(idof "$UD" 1)" --dir "$UD" >/dev/null; rm -f "$UD/.git/quiet-save-copy.index.lock"; stop "$UD" >/dev/null
mkdir "$UD/ban-cu"; printf 'mine\n' > "$UD/ban-cu/notes.txt"; stop "$UD" >/dev/null
eq "$(git -C "$UD" show HEAD:ban-cu/notes.txt)" "mine" "[K14] kit folder deleted by hand, then a failed copy: a ban-cu/ the person makes later is still saved"
if can_link; then   # the cases below need a real link
JL="$TMP/junctionlike"; mkdir -p "$JL"; printf 'r\n' > "$JL/report.txt"; stop "$JL" >/dev/null; qs copy "$(idof "$JL" 1)" --dir "$JL" >/dev/null
mv "$JL/ban-cu" "$TMP/moved-ban-cu"; ln -s "$TMP/moved-ban-cu" "$JL/ban-cu"   # a link stands in for a Windows junction
has "$(qs copy "$(idof "$JL" 1)" --dir "$JL")" "is copied into ban-cu-2/" "[K15] a listed, marked ban-cu that is a link resolving outside the folder: passed over, the copy goes to ban-cu-2/ (the Windows junction case is reasoned, not run)"
eq "$(ls "$TMP/moved-ban-cu" | grep -c '^2')" 1 "[K15] …nothing written outside the work folder"
else echo "  SKIP [K15] a listed ban-cu that is a link (tests/test-windows-everyday.sh [J1] runs a real junction): ln -s makes no link here (Git Bash copies the target)"; fi

NB="$TMP/nestedban"; mkdir -p "$NB/bao-cao/ban-cu"; printf 'x\n' > "$NB/a.txt"; printf 'draft\n' > "$NB/bao-cao/ban-cu/nhap.docx"; stop "$NB" >/dev/null
has "$(qs copy "$(idof "$NB" 1)" --dir "$NB")" "is copied into ban-cu/" "[K10] a person's bao-cao/ban-cu/ (owner's question): the copy goes to the top ban-cu/"
printf 'draft 2\n' > "$NB/bao-cao/ban-cu/nhap.docx"; stop "$NB" >/dev/null
eq "$(git -C "$NB" show HEAD:bao-cao/ban-cu/nhap.docx) $(cat "$NB"/ban-cu/2*/bao-cao/ban-cu/nhap.docx)" "draft 2 draft" "[K10] …bao-cao/ban-cu/ is saved like any folder; the copy holds its old state"
eq "$(qs drop-copy bao-cao/ban-cu --dir "$NB")$(cat "$NB/bao-cao/ban-cu/nhap.docx")" "Nothing changed: bao-cao/ban-cu is not one of the kit's old copies.draft 2" "[K10] …and drop-copy refuses it"
if [ -n "$RG" ]; then
  eq "$(cd "$NB" && rg --files | grep -c '^bao-cao/ban-cu/nhap.docx$') $(cd "$NB" && rg --files | grep -c '^ban-cu/')" "1 0" "[K10] ripgrep searches the person's bao-cao/ban-cu/, not the kit's ban-cu/"
  eq "$(cd "$BD" && rg --files | grep -c '^ban-cu/plan.md$') $(cd "$BD" && rg --files | grep -c '^ban-cu-2/')" "1 0" "[K10] ripgrep honours /ban-cu-2/ in .ignore: it searches the person's ban-cu/, not the kit's ban-cu-2/"
fi

echo "== [K16] drop-copy of a copy holding read-only files and folders (Windows refuses to delete them as they are) =="
if [ "$(id -u)" = 0 ]; then
  echo "  SKIP [K16]: root ignores file permissions, so no file here is read-only to it"
elif ! can_link; then
  echo "  SKIP [K16]: ln -s makes no link here and modes are not POSIX (tests/test-windows-everyday.sh [J4] [J5] run the Windows case)"
else
  RO="$TMP/readonly"; mkdir -p "$RO/inner"; printf 'x\n' > "$RO/inner/x.txt"; printf 'v\n' > "$TMP/ro-victim.txt"; chmod 400 "$TMP/ro-victim.txt"
  ln -s "$TMP/ro-victim.txt" "$RO/inner/out"; stop "$RO" >/dev/null; qs copy "$(idof "$RO" 1)" --dir "$RO" >/dev/null
  N=$(ls "$RO/ban-cu" | grep -v DAY | head -1); chmod 444 "$RO/ban-cu/$N/inner/x.txt"; chmod 555 "$RO/ban-cu/$N/inner"
  eq "$(qs drop-copy "ban-cu/$N" --dir "$RO"; echo "rc=$?")" "$(printf 'The old copy ban-cu/%s is removed.\nrc=0' "$N")" "[K16] a copy with a read-only file in a read-only folder is removed and said so (main: a traceback, the copy half there)"
  eq "${N:+named} $(test -e "$RO/ban-cu/$N" && echo there || echo gone) $(stat -c %a "$TMP/ro-victim.txt") $(cat "$TMP/ro-victim.txt")" "named gone 400 v" \
     "[K16] …the copy is gone, and the file its saved link points to keeps its mode and text (no chmod through a link)"
  qs copy "$(idof "$RO" 1)" --dir "$RO" >/dev/null; N=$(ls "$RO/ban-cu" | grep -v DAY | head -1); chmod 000 "$RO/ban-cu/$N/inner"
  O=$(qs drop-copy "ban-cu/$N" --dir "$RO" 2>&1; echo "rc=$?")   # stderr too: a traceback goes there
  has "$O" "The old copy ban-cu/$N could not be removed whole (" "[K16] a copy holding a folder nobody may read: one plain line, not a traceback (a retry of the failed read raised TypeError)"
  eq "${O##*rc=}|$(printf '%s' "$O" | grep -c Traceback)|$(grep -cxF "ban-cu/$N" "$RO/.git/quiet-save-copies")" "1|0|1" "[K16] …rc 1, and the copy is still on the kit's list"
  chmod 755 "$RO/ban-cu/$N/inner"
  eq "$(qs drop-copy "ban-cu/$N" --dir "$RO")" "The old copy ban-cu/$N is removed." "[K16] …so asking again once the folder can be read removes the rest"
fi

echo "== [I] the notebook in everyday mode: kb.py init in place in the kit's history (row E) =="
KBI="$PL/scripts/kb.py"
NI="$TMP/notebook"; mkdir -p "$NI"; printf 'bai\n' > "$NI/bai.md"; stop "$NI" >/dev/null
H0=$(git -C "$NI" rev-parse HEAD); B0=$(git -C "$NI" branch --format='%(refname)' | tr '\n' ' ')
OUT=$(cd "$NI" && python3 "$KBI" init --everyday 2>&1 | tr -d '\r'); rc=$?
eq "$rc" 0 "[I1] kb.py init --everyday in a kit-made history with no remote: rc 0"
eq "$(cd "$NI" && find . -mindepth 1 -path ./.git -prune -o -newer bai.md -print | sort | tr '\n' ' ')" "./kb ./kb/current-state.md ./kb/preferences.md " "[I1] …only the notebook the everyday core names: no config, no rules, no other kb/ folder or README"
eq "$(wc -c < "$NI/kb/current-state.md" | tr -d ' ') $(wc -c < "$NI/kb/preferences.md" | tr -d ' ')" "0 0" "[I1] …both empty: no text in a fixed language (Claude writes them in the person's)"
eq "$(git -C "$NI" rev-parse HEAD) $(git -C "$NI" branch --format='%(refname)' | tr '\n' ' ')$(git -C "$NI" remote)" "$H0 $B0" "[I1] …no new commit, branch or remote"
eq "$(printf '%s\n' "$OUT" | grep -ciE 'merge|(^|[^a-z])ci([^a-z]|$)|gate')" 0 "[I2] with --everyday the report says nothing of merge, CI or gates"
NJ="$TMP/notebook-plain"; mkdir -p "$NJ"; printf 'bai\n' > "$NJ/bai.md"; stop "$NJ" >/dev/null
PLAIN=$(cd "$NJ" && python3 "$KBI" init 2>&1 | tr -d '\r'); rc=$?
eq "$rc $(printf '%s\n' "$PLAIN" | grep -c -e '^merge.deny_globs = ' -e '^CI runner: ')" "0 2" "[I2] without the flag the two notes are there, as before"
eq "$(printf '%s\n' "$PLAIN" | grep -ciE 'merge|(^|[^a-z])ci([^a-z]|$)|gate' | awk '{print ($1 > 0)}')" 1 "[I2] control: the same word check finds them in the plain report"
eq "$OUT" "$(printf 'kb.py init (everyday)\ncreated kb/current-state.md\ncreated kb/preferences.md')" "[I2] the everyday report names only the two files"
test -f "$NJ/kb/README.md" && test -f "$NJ/.vibemaestro/rules/example.instructions.md" && ok "[I2] control: without the flag the developer scaffold is written, as before" || bad "[I2] control: the plain init wrote no developer scaffold"
NA="$TMP/notebook-adopt"; mkdir -p "$NA"; printf 'bai\n' > "$NA/bai.md"; stop "$NA" >/dev/null
eq "$(cd "$NA" && python3 "$KBI" init --everyday --adopt >/dev/null 2>&1; echo "rc=$?") $(test -e "$NA/kb" && echo kb || echo nokb)" "rc=64 nokb" "[I2] --everyday with --adopt: a usage error, nothing written"
printf 'where the work stands\n' > "$NI/kb/current-state.md"
OUT2=$(cd "$NI" && python3 "$KBI" init --everyday 2>&1); rc=$?
eq "$rc $(cat "$NI/kb/current-state.md") $(printf '%s\n' "$OUT2" | grep -c '^created ') $(printf '%s\n' "$OUT2" | grep -c '^kept ')" "0 where the work stands 0 2" "[I3] set up twice: rc 0, nothing overwritten, nothing created again"
stop "$NI" >/dev/null
eq "$(git -C "$NI" show HEAD:kb/current-state.md)" "where the work stands" "[I4] the next quiet save keeps the notebook (the folder is still in everyday mode)"
SF="$TMP/notebook-sub"; mkdir -p "$SF/sub"; printf 'bai\n' > "$SF/bai.md"; printf 'p\n' > "$SF/sub/p.md"
( cd "$SF/sub" && cd "$SF" && printf '{}' | env -u CLAUDE_PROJECT_DIR CLAUDE_PLUGIN_ROOT="$PL" /bin/sh "$PL/scripts/pyrun.sh" "scripts/quiet_save.py" save )
( cd "$SF/sub" && cd "$SF" && env -u CLAUDE_PROJECT_DIR /bin/sh "$PL/scripts/pyrun.sh" "scripts/kb.py" init --everyday >/dev/null 2>&1 ); rc=$?
eq "$(git -C "$SF" config --local --get vibemaestro.quietsave) $(test -e "$SF/sub/.git" && echo sub-git || echo no-sub-git) $rc $(test -f "$SF/kb/current-state.md" && echo kb)" "true no-sub-git 0 kb" "[I6] the skill's two commands from a shell standing in a sub-folder: the history and the notebook are the person's folder's, none in the sub-folder"
SC="$TMP/notebook-sub-control"; mkdir -p "$SC/sub"; printf 'bai\n' > "$SC/bai.md"; printf 'p\n' > "$SC/sub/p.md"
( cd "$SC/sub" && printf '{}' | env -u CLAUDE_PROJECT_DIR CLAUDE_PLUGIN_ROOT="$PL" /bin/sh "$PL/scripts/pyrun.sh" "scripts/quiet_save.py" save )
eq "$(test -e "$SC/sub/.git" && echo sub-git)" "sub-git" "[I6] control: the same save without naming the folder makes its history in the sub-folder"
NR="$TMP/notebook-remote"; mkdir -p "$NR"; printf 'bai\n' > "$NR/bai.md"; stop "$NR" >/dev/null; git -C "$NR" remote add origin "$TMP/nowhere.git"
H1=$(git -C "$NR" rev-parse HEAD); printf 'x\n' >> "$NR/bai.md"; stop "$NR" >/dev/null
eq "$(git -C "$NR" rev-parse HEAD)" "$H1" "[I5] once the folder has a remote, the next turn saves nothing (the developer flow keeps it)"

echo "== [Q] a subfolder that turns the kit off, under a history root (KIT-968) =="
offcfg() { mkdir -p "$1/.vibemaestro"; printf '%s\n' "${2:-{\"schema\": 1, \"hooks\": \"off\"\}}" > "$1/.vibemaestro/sdlc.json"; }
subst() {  # subst <dir> — Claude's context from the SubagentStart hook in <dir>
  local c; c=$(hook_cmds "$HOOKS" SubagentStart general-purpose | head -n 1)
  ctx "$(cd "$1" && printf '{"session_id":"%s","hook_event_name":"SubagentStart","agent_type":"general-purpose"}' "$(sid)" \
         | CLAUDE_PLUGIN_ROOT="$PL" CLAUDE_PROJECT_DIR="$1" bash -c "$c" 2>/dev/null)"
}
edit() {  # edit <dir> — the joined output of the PreToolUse Edit hooks for a file in <dir>
  local c; while IFS= read -r c; do [ -n "$c" ] || continue
    (cd "$1" && p_edit "$(sid)" "$1/a.txt" | CLAUDE_PLUGIN_ROOT="$PL" CLAUDE_PROJECT_DIR="$1" bash -c "$c" 2>/dev/null)
  done < <(hook_cmds "$HOOKS" PreToolUse Edit)
}
T="$TMP/thu-nghiem"; mkdir -p "$T/chua-cai" "$T/da-cai" "$T/ban[1]" "$T/ban1"
printf 'a\n' > "$T/chua-cai/a.txt"; printf 'b\n' > "$T/da-cai/b.txt"; printf 'c\n' > "$T/ban[1]/c.txt"; printf 'd\n' > "$T/ban1/d.txt"
stop "$T" >/dev/null
eq "$(tracked "$T")" "ban1/d.txt ban[1]/c.txt chua-cai/a.txt da-cai/b.txt " "[Q0] a turn in the parent itself makes it the history root of every subfolder (how the field case began)"
offcfg "$T/chua-cai"; offcfg "$T/ban[1]"; printf 'a2\n' > "$T/chua-cai/a.txt"
N0=$(saves "$T")
eq "$(core "$T/chua-cai")" "" "[Q1] a session in the off subfolder: the core hook says nothing"
eq "$(subst "$T/chua-cai")" "" "[Q1] …nor the SubagentStart hook"
has "$(subst "$T/da-cai")" 'Keep a notebook in' "[Q1] control: in the on sibling the SubagentStart hook gives the everyday core"
stop "$T/chua-cai" >/dev/null
eq "$(saves "$T")" "$N0" "[Q1] a turn ending in the off subfolder makes no save"
printf 'b2\n' > "$T/da-cai/b.txt"; stop "$T/da-cai" >/dev/null
eq "$(saves "$T")" "$((N0 + 1))" "[Q2] a turn in the on sibling saves"
eq "$(tracked "$T")" "ban1/d.txt da-cai/b.txt " "[Q2] …without the off subfolders, though an earlier save held them; ban1 (which ban[1] matches as a pattern) is kept"
eq "$(cat "$T/chua-cai/a.txt")" "a2" "[Q2] …and the off subfolder's files stay on disk as they were"
N0=$(saves "$T"); printf 'a3\n' > "$T/chua-cai/a.txt"; stop "$T" >/dev/null
eq "$(saves "$T")|$(tracked "$T")" "$N0|ban1/d.txt da-cai/b.txt " "[Q2] a turn in the root itself does not take the off subfolder either (nothing else changed: no save)"
C3=$(core "$T/da-cai")
eq "$(printf %s "$C3" | grep -o 'thu-nghiem above it' | wc -l | tr -d ' ')" 1 "[Q3] the on sibling's session start names the folder that holds its history, once"
has "$C3" "the quiet saves of this folder go into the history of the folder" "[Q3] …in the line for Claude"
hasnt "$(coresys "$T/da-cai")" "thu-nghiem" "[Q3] …and the person sees no fixed-language line"
hasnt "$(core "$T")" "go into the history of the folder" "[Q4] a session in the history root itself: no such line"
NP="$TMP/no-parent-history"; mkdir -p "$NP/sub"; printf 'x\n' > "$NP/sub/x.txt"
C4=$(core "$NP/sub")
has "$C4" "everyday mode, because" "[Q4] control: a subfolder of a folder with no history is in everyday mode"
hasnt "$C4" "go into the history of the folder" "[Q4] …and gets no history line (its saves are its own)"
mkdir -p "$T/chua-cai/inner"; offcfg "$T/chua-cai/inner" '{"schema": 1, "language": "en"}'; printf 'i\n' > "$T/chua-cai/inner/i.txt"
N0=$(saves "$T")
eq "$(core "$T/chua-cai/inner")" "" "[Q5] a nearer config without the hooks key, inside the off folder: the kit stays off"
stop "$T/chua-cai/inner" >/dev/null
eq "$(saves "$T")" "$N0" "[Q5] …and no save"
RO="$TMP/root-off"; mkdir -p "$RO/sub"; printf 'x\n' > "$RO/sub/x.txt"; stop "$RO" >/dev/null; offcfg "$RO"
N0=$(saves "$RO"); printf 'y\n' >> "$RO/sub/x.txt"
eq "$(core "$RO/sub")" "" "[Q6] the root's own hooks: off still turns off a subfolder with no config (unchanged)"
stop "$RO/sub" >/dev/null
eq "$(saves "$RO")" "$N0" "[Q6] …and no save"
W2="$TMP/root-note"; mkdir -p "$W2/on" "$W2/off"; printf 'x\n' > "$W2/on/a.txt"; printf 'x\n' > "$W2/off/a.txt"; stop "$W2" >/dev/null
offcfg "$W2" '{"schema": 1, "later_key": true}'; offcfg "$W2/off"
has "$(edit "$W2/on")" "later_key" "[Q7] control: the root's config note reaches the PreToolUse hook of an on subfolder"
eq "$(edit "$W2/off")" "" "[Q7] the PreToolUse hook says nothing in the off subfolder"
OO="$TMP/only-off"; mkdir -p "$OO/chua-cai"; offcfg "$OO/chua-cai"; printf 'a\n' > "$OO/chua-cai/a.txt"
stop "$OO" >/dev/null
eq "$(test -e "$OO/.git" && echo git || echo none)" none "[Q8] a folder holding only an off subfolder is empty to the save: no history made"

echo "== [Q9] review round 1 (KIT-968): an off folder git ignores, a copy that holds one, an off folder that is an empty repository =="
IG="$TMP/ignored-off"; mkdir -p "$IG/ign" "$IG/keep"; printf 'k\n' > "$IG/keep/k.txt"; printf 'i\n' > "$IG/ign/i.txt"; printf '/ign/\n' > "$IG/.gitignore"
offcfg "$IG/ign"; stop "$IG" >/dev/null; N0=$(saves "$IG"); printf 'k2\n' >> "$IG/keep/k.txt"; stop "$IG" >/dev/null
eq "$(saves "$IG")|$(tracked "$IG")" "$((N0 + 1))|.gitignore keep/k.txt " "[Q9] an off folder that .gitignore also names: the rest is still saved"
hasnt "$(core "$IG")" "the last quiet save of this folder" "[Q9] …and no failed-save line at the next session start"
BC="$TMP/copy-holds-off"; mkdir -p "$BC/chua-cai/.vibemaestro" "$BC/da-cai"; printf 'b\n' > "$BC/da-cai/b.txt"; printf 'a\n' > "$BC/chua-cai/a.txt"
printf '{"schema": 1, "hooks": "auto"}\n' > "$BC/chua-cai/.vibemaestro/sdlc.json"; stop "$BC" >/dev/null
printf '{"schema": 1, "hooks": "off"}\n' > "$BC/chua-cai/.vibemaestro/sdlc.json"; printf 'a2\n' > "$BC/chua-cai/a.txt"
qs copy 1 --dir "$BC" >/dev/null; offcfg "$BC/ban-cu"/*/chua-cai   # not a break: the copy an older save (made before the fix) would hold
N0=$(saves "$BC"); printf 'b2\n' >> "$BC/da-cai/b.txt"; stop "$BC" >/dev/null
eq "$(saves "$BC")|$(tracked "$BC")" "$((N0 + 1))|.ignore da-cai/b.txt " "[Q9] a kit copy in ban-cu/ that holds an off folder: the next turn still saves the rest"
ER="$TMP/off-empty-repo"; mkdir -p "$ER/inr" "$ER/keep"; printf 'k\n' > "$ER/keep/k.txt"; git_ -C "$ER/inr" init -q; offcfg "$ER/inr"
stop "$ER" >/dev/null
eq "$(saves "$ER")|$(tracked "$ER")" "1|keep/k.txt " "[Q10] an off folder that is a repository with no commit is left out whole; the rest is saved"

echo "== [Q11] review round 2 (KIT-968): an ignored off folder whose name starts with ':', a staged file the save cannot simply unstage =="
CO="$TMP/colon-off"; mkdir -p "$CO/keep"; printf 'k\n' > "$CO/keep/k.txt"
if mkdir "$CO/:colon" 2>/dev/null; then
  offcfg "$CO/:colon"; printf '/:colon/\n' > "$CO/.gitignore"; stop "$CO" >/dev/null
  eq "$(saves "$CO")|$(tracked "$CO")" "1|.gitignore keep/k.txt " "[Q11] an ignored off folder named ':colon' (git reads a leading ':' as pathspec magic): the rest is saved"
else echo "  SKIP [Q11] ':colon': this file system refuses ':' in a name (Windows)"; fi
RF="$TMP/rm-refused"; mkdir -p "$RF/ign" "$RF/oth" "$RF/keep"; printf 'i\n' > "$RF/ign/i.txt"; printf 'o\n' > "$RF/oth/o.txt"; printf 'k\n' > "$RF/keep/k.txt"
stop "$RF" >/dev/null
printf '#!/bin/sh\nexit 1\n' > "$RF/.git/hooks/pre-commit"; chmod +x "$RF/.git/hooks/pre-commit"
printf 'i2\n' > "$RF/ign/i.txt"; stop "$RF" >/dev/null                   # the person's hook refuses: ign/i.txt stays staged
rm "$RF/.git/hooks/pre-commit"; printf 'i3\n' > "$RF/ign/i.txt"          # staged content now differs from both HEAD and the file
offcfg "$RF/ign"; offcfg "$RF/oth"; printf '/ign/\n' > "$RF/.gitignore"; printf 'k2\n' > "$RF/keep/k.txt"; stop "$RF" >/dev/null
eq "$(saves "$RF")|$(tracked "$RF")" "2|.gitignore keep/k.txt " "[Q11] an off folder with a staged file that differs from both the save and the disk: both off folders leave, the rest is saved"
eq "$(cat "$RF/ign/i.txt")" "i3" "[Q11] …and the off folder's file stays on disk as the person left it"

echo "== [O] connected to a remote: the developer flow takes over, the save stops =="
git_ init -q --bare "$TMP/hub.git"; git -C "$P" remote add origin "$TMP/hub.git"; git -C "$P" push -q origin HEAD 2>/dev/null
N0=$(saves "$P"); printf 'after\n' > "$P/after.txt"; stop "$P" >/dev/null
eq "$(saves "$P")" "$N0" "[O1] after a remote is added the next turn makes no save"
eq "$(git -C "$TMP/hub.git" rev-list --count HEAD)" "$N0" "[O1] …and every save is on the remote, pushed by the person"
eq "$(core "$P" | grep -c 'everyday mode')" 0 "[O1] the session start is the developer one"
eq "$(qs copy "$(git -C "$P" rev-parse --short=8 HEAD~1)" --dir "$P")$(test -e "$P/ban-cu" && echo ban)" "Nothing changed: the folder is connected to a remote: the developer flow keeps it now." "[O1] copying a save is refused once the folder has a remote, nothing written"
summary
