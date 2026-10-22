#!/bin/bash
# =============================================================================
# Plugin vibemaestro-sdlc — repo rules and decisions from origin/<default> when the tree is behind
# =============================================================================
# Run: bash tests/test-rules-origin.sh
#
# Offline: a bare remote in the scratch tree, and the clone's `origin` URL points at an ssh host that does not exist, so a hook
# that tried the network would call the ssh shim of the network guard (the log is checked at the end). The clone fetches from
# the bare remote by its path only. The hooks are run by the `command` strings of hooks/hooks.json (lib.sh).
#   [B] behind: a changed, a new, a deleted rule, a changed and a new decision, a `level: block` rule added upstream, a local
#       edit the remote did not touch, the command in the mark shows the fresh text, the session warning once per session
#   [S] the refs are older than the remote: nothing to say; after a fetch: marked; an old FETCH_HEAD is named in the warning
#   [Q] quiet and rc 0: up to date, ahead only, detached HEAD, no remote, no default ref, git too slow (the deadline)
#   [D] the default ref: origin/HEAD wins over main; a linked worktree as the project directory
#   [C] the cache: a hook after the first one in a session reads the cached answer
#   [P] planted breaks: the mark, the overlay, the warning, the catalogue mark, each turns its check red
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"

PL="$TMP/plugin"; mk_plugin "$PL"
HOOKS="$PL/hooks/hooks.json"
NOWHERE='ssh://git@example.invalid/acme/app.git'

# ── hooks ─────────────────────────────────────────────────────────────────────
# h_edit <plugin> <project dir> <sid> <file> / h_bash <plugin> <project dir> <sid> <command> / h_start <plugin> <project dir> <sid>
h_edit()  { CLAUDE_PROJECT_DIR="$2" CLAUDE_PLUGIN_ROOT="$1" run_cmds "$1/hooks/hooks.json" PreToolUse Edit "$(p_edit "$3" "$2/$4")"; }
h_bash()  { CLAUDE_PROJECT_DIR="$2" CLAUDE_PLUGIN_ROOT="$1" run_cmds "$1/hooks/hooks.json" PreToolUse Bash "$(p_bash "$3" "$4")"; }
h_start() {
  local c; c=$(hook_cmds "$1/hooks/hooks.json" SessionStart "" | sed -n 2p)
  printf '%s' "$(p_start "$3")" | CLAUDE_PROJECT_DIR="$2" CLAUDE_PLUGIN_ROOT="$1" bash -c "$c" 2>/dev/null
}

# ── fixture ───────────────────────────────────────────────────────────────────
rrule() {  # rrule <repo> <file under policy/> <applyTo|-> <applyWhen|-> <level|-> <description>
  mkdir -p "$1/policy"
  { printf -- '---\n'
    [ "$3" != - ] && printf 'applyTo: "%s"\n' "$3"
    [ "$4" != - ] && printf 'applyWhen: "%s"\n' "$4"
    [ "$5" != - ] && printf 'level: %s\n' "$5"
    printf 'description: "%s"\n---\n\n# %s\n\nBODY-%s\n' "$6" "$6" "$6"; } > "$1/policy/$2"
}
push_seed() { git_ -C "$SEED" add -A && git_ -C "$SEED" commit -qm "$1" && git_ -C "$SEED" push -q origin HEAD:main 2>/dev/null; }
fetch_from() { git_ -C "$1" fetch -q "$REMOTE" '+refs/heads/*:refs/remotes/origin/*'; }   # by path: never the NOWHERE url
clone_app() {  # clone_app <dir> — a clone of the remote whose origin url then points nowhere
  git_ clone -q "$REMOTE" "$1" 2>/dev/null; git_ -C "$1" remote set-url origin "$NOWHERE"
}

REMOTE="$TMP/remote.git"; git_ init -q --bare -b main "$REMOTE"
SEED="$TMP/seed"; git_ clone -q "$REMOTE" "$SEED" 2>/dev/null; git_ -C "$SEED" checkout -q -b main 2>/dev/null
mkdir -p "$SEED/.vibemaestro" "$SEED/src" "$SEED/kb"
printf '{"schema": 1, "rules": {"dirs": ["policy"]}}' > "$SEED/.vibemaestro/sdlc.json"
: > "$SEED/src/main.ts"
rrule "$SEED" old.instructions.md 'src/**' - - 'OLD-V1'
rrule "$SEED" gone.instructions.md 'src/**' - - 'GONE-RULE'
rrule "$SEED" local.instructions.md 'src/**' - - 'LOCAL-V1'
dec_ "$SEED" d-old.md 'src/**' 'DEC-V1'
push_seed c1
C1=$(git_ -C "$SEED" rev-parse HEAD)
APP="$TMP/app"; clone_app "$APP"
# the remote moves on: a changed, a deleted, a new and a blocking rule, a changed and a new decision
rrule "$SEED" old.instructions.md 'src/**' - - 'OLD-V2'
rm "$SEED/policy/gone.instructions.md"
rrule "$SEED" new.instructions.md 'src/**' - - 'NEW-RULE'
rrule "$SEED" block.instructions.md - 'acme-ship' block 'BLOCK-UP'
dec_ "$SEED" d-old.md 'src/**' 'DEC-V2'
dec_ "$SEED" d-new.md 'src/**' 'DEC-NEW'
# a rule whose file name is shell syntax: the command in its mark must print it, not run it
rrule "$SEED" 'odd$(touch PWNED);x.instructions.md' 'src/**' - - 'ODD-NAME'
push_seed c2
# a local edit the remote never touched
rrule "$APP" local.instructions.md 'src/**' - - 'LOCAL-EDIT'

MARK1="[from origin/main: this tree is behind it by 1 commit; read it with: git -C $APP show origin/main:"

echo "== [S] the refs are older than the remote (not fetched): the hook cannot know, says nothing, and never fetches =="
S=$(sid); O=$(ctx "$(h_edit "$PL" "$APP" "$S" src/main.ts)")
has "$O" "$APP/policy/old.instructions.md" "[S] the tree's rule is reminded by its path"
hasnt "$O" '[from origin/' "[S] no mark: as last fetched, the tree is not behind"
hasnt "$O" 'new.instructions.md' "[S] the rule only the remote has is not known yet"
SO=$(h_start "$PL" "$APP" "$(sid)")
hasnt "$(ctx "$SO")" 'WARNING: this tree' "[S] SessionStart: no behind warning"
eq "$(git_ -C "$APP" rev-parse origin/main)" "$(git_ -C "$APP" rev-parse HEAD)" "[S] the hooks did not move origin/main (no fetch)"

fetch_from "$APP"
echo "== [B] behind by one commit, after a fetch =="
S=$(sid); EO=$(h_edit "$PL" "$APP" "$S" src/main.ts); O=$(ctx "$EO")
isjson "$EO" && ok "[B] the edit hook prints valid JSON" || bad "[B] the edit hook prints no JSON: ${EO:0:120}"
has "$O" "- origin/main:policy/old.instructions.md ${MARK1}policy/old.instructions.md]" "[B] a rule the remote changed: <ref>:<path> and its mark, in one line"
hasnt "$O" "$APP/policy/old.instructions.md" "[B] …and not the stale path of the tree"
has "$O" "- origin/main:policy/new.instructions.md ${MARK1}policy/new.instructions.md]" "[B] a rule only the remote has is delivered, marked"
has "$O" "- $APP/policy/gone.instructions.md [origin/main does not have it and this tree is behind it by 1 commit: deleted there, or added here; check: git -C $APP log --oneline -1 origin/main -- policy/gone.instructions.md]" "[B] a rule the remote deleted: the tree's text, marked, never gone without a word"
has "$O" "- $APP/policy/local.instructions.md" "[B] a rule only the tree changed is the tree's"
hasnt "$(printf '%s\n' "$O" | grep -F local.instructions.md)" '[from' "[B] …unmarked"
has "$O" "- origin/main:kb/decisions/d-old.md ${MARK1}kb/decisions/d-old.md]" "[B] a decision the remote changed: marked"
has "$O" "- origin/main:kb/decisions/d-new.md ${MARK1}kb/decisions/d-new.md]" "[B] a decision only the remote has: marked"
hasnt "$O" "$APP/kb/decisions/d-old.md" "[B] …and not the stale decision of the tree"
# the command in the mark shows the fresh text (run as printed)
CMD=$(printf '%s\n' "$O" | grep -F 'policy/old.instructions.md' | sed -n 's/.*read it with: \(.*\)\]$/\1/p' | head -1)
has "$(bash -c "$CMD" 2>&1)" 'OLD-V2' "[B] the command in the mark prints the fresh rule (OLD-V2)"
has "$(cat "$APP/policy/old.instructions.md")" 'OLD-V1' "[B] control: the tree still has OLD-V1"
CMD=$(printf '%s\n' "$O" | grep -F 'odd$(touch' | sed -n 's/.*read it with: \(.*\)\]$/\1/p' | head -1)
nonempty "$CMD" "[B] a rule with shell syntax in its name is delivered with a mark"
has "$( cd "$TMP" && bash -c "$CMD" 2>&1)" 'ODD-NAME' "[B] …the command in its mark prints it"
[ ! -e "$TMP/PWNED" ] && [ ! -e "$APP/PWNED" ] && ok "[B] …and runs nothing of the name (no PWNED file)" || bad "[B] the mark's command ran part of the file name"
# a blocking rule added upstream blocks, and its reason carries the mark
BO=$(h_bash "$PL" "$APP" "$(sid)" 'acme-ship --now')
eq "$(dec "$BO")" deny "[B] a level: block rule only the remote has blocks its command"
has "$(why "$BO")" "${MARK1}policy/block.instructions.md]" "[B] …and the reason carries the mark"
empty "$(h_bash "$PL" "$APP" "$(sid)" 'ls -la')" "[B] control: a command no rule matches stays silent"
# SessionStart: the warning, once per session, and the catalogue
S=$(sid); SO=$(h_start "$PL" "$APP" "$S"); SC=$(ctx "$SO")
isjson "$SO" && ok "[B] SessionStart prints valid JSON" || bad "[B] SessionStart prints no JSON: ${SO:0:120}"
has "$SC" "WARNING: this tree ($APP) is behind origin/main by 1 commit." "[B] SessionStart warns that the tree is behind, by how much"
has "$SC" 'The plugin never fetches' "[B] …says it never fetches"
has "$SC" 'as last fetched (last fetch: under a minute ago)' "[B] …and how old the refs are"
has "$SC" 'with the command that shows its text: 6 files now; 1 file origin/main does not have, delivered as the tree has them and marked.' "[B] …counts what is served from the ref (4 rules, 2 decisions) and what it lacks"
has "$SC" 'fetch origin`, then `git pull --ff-only`.' "[B] …and says how to update the tree (on the default branch: a pull)"
has "$(sysm "$SO")" 'is behind origin/main by 1 commit(s)' "[B] the person sees it too (systemMessage)"
has "$(printf '%s\n' "$SC" | grep -F -- '- new.instructions.md')" 'from origin/main: this tree is behind it' "[B] the catalogue lists the new rule, marked"
has "$(printf '%s\n' "$SC" | grep -F -- '- gone.instructions.md')" '[origin/main does not have it' "[B] the catalogue marks the rule the remote deleted"
has "$(printf '%s\n' "$SC" | grep -F -- '- new.instructions.md')" "read it with: git -C $APP show origin/main:policy/new.instructions.md]" "[B] the catalogue row carries the command that shows the ref's text"
hasnt "$(printf '%s\n' "$SC" | grep -F -- '- local.instructions.md')" 'from origin' "[B] the catalogue: the tree's own rule is not marked"
hasnt "$(ctx "$(h_start "$PL" "$APP" "$S")")" 'WARNING: this tree' "[B] SessionStart again in the same session: no second warning"
has "$(ctx "$(h_start "$PL" "$APP" "$(sid)")")" 'WARNING: this tree' "[B] control: a new session is warned again"

echo "== [S] an old FETCH_HEAD is named in the warning =="
python3 -c 'import os, sys, time; t = time.time() - 3 * 86400 - 60; os.utime(sys.argv[1], (t, t))' "$APP/.git/FETCH_HEAD"
has "$(ctx "$(h_start "$PL" "$APP" "$(sid)")")" '(last fetch: 3 days ago)' "[S] FETCH_HEAD three days old: the warning says so"
mv "$APP/.git/FETCH_HEAD" "$TMP/fh"
has "$(ctx "$(h_start "$PL" "$APP" "$(sid)")")" '(last fetch: unknown (no FETCH_HEAD))' "[S] no FETCH_HEAD: the age is unknown, said so"
mv "$TMP/fh" "$APP/.git/FETCH_HEAD"

echo "== [C] the cache: a hook after the first one in a session reads the cached answer =="
S=$(sid); h_bash "$PL" "$APP" "$S" 'acme-ship a' >/dev/null
CF=$(ls "$TMPDIR/vsdlc-$S"/upstream-*.json 2>/dev/null | head -1)
nonempty "$CF" "[C] the first hook of the session wrote the cache"
python3 -c 'import sys; p = sys.argv[1]; s = open(p).read(); open(p, "w").write(s.replace("BLOCK-UP", "CACHED-BLOCK"))' "$CF"
has "$(why "$(h_bash "$PL" "$APP" "$S" 'acme-ship b')")" 'CACHED-BLOCK' "[C] the second hook read the cache (a planted value in it shows)"
hasnt "$(why "$(h_bash "$PL" "$APP" "$(sid)" 'acme-ship c')")" 'CACHED-BLOCK' "[C] control: another session computes its own"
eq "$(python3 -c 'import os, sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777))' "$CF")" 0o600 "[C] the cache file is readable by its owner only"
chmod 666 "$CF"
hasnt "$(why "$(h_bash "$PL" "$APP" "$S" 'acme-ship d')")" 'CACHED-BLOCK' "[C] a cache file others can write is not trusted (computed again)"

echo "== [Q] quiet and rc 0 =="
quiet() {  # quiet <label> <project dir> — no mark and no warning from the three hooks, rc 0 each
  local o rc
  o=$(h_edit "$PL" "$2" "$(sid)" src/main.ts); rc=$?
  hasnt "$o" '[from origin/' "[Q] $1: the edit hook has no mark"; eq "$rc" 0 "[Q] $1: the edit hook rc 0"
  o=$(h_bash "$PL" "$2" "$(sid)" 'git status'); rc=$?
  hasnt "$o" '[from origin/' "[Q] $1: the command hook has no mark"; eq "$rc" 0 "[Q] $1: the command hook rc 0"
  o=$(h_start "$PL" "$2" "$(sid)"); rc=$?
  hasnt "$o" 'WARNING: this tree' "[Q] $1: SessionStart does not warn"; hasnt "$o" 'from origin/' "[Q] $1: the catalogue has no mark"; eq "$rc" 0 "[Q] $1: SessionStart rc 0"
}
# detached HEAD while behind
DET="$TMP/app-detached"; clone_app "$DET"; git_ -C "$DET" reset -q --hard HEAD~1; fetch_from "$DET"
git_ -C "$DET" checkout -q --detach HEAD
quiet "detached HEAD, one commit behind" "$DET"
# up to date
UP="$TMP/app-up"; clone_app "$UP"; fetch_from "$UP"
eq "$(git_ -C "$UP" rev-parse HEAD)" "$(git_ -C "$UP" rev-parse origin/main)" "[Q] control: the up-to-date clone is at origin/main"
quiet "up to date" "$UP"
has "$(ctx "$(h_edit "$PL" "$UP" "$(sid)" src/main.ts)")" "$UP/policy/new.instructions.md" "[Q] up to date: the tree's rules are delivered by their path"
# the behind clone, brought up to date by a merge
git_ -C "$APP" merge -q --ff-only origin/main
quiet "behind, then merged" "$APP"
has "$(ctx "$(h_edit "$PL" "$APP" "$(sid)" src/main.ts)")" "$APP/policy/local.instructions.md" "[Q] merged: the local edit is still delivered"
# ahead only
git_ -C "$UP" commit -q --allow-empty -m ahead
quiet "ahead of origin/main, not behind" "$UP"
# no remote
NR="$TMP/app-noremote"; mkdir -p "$NR/src"; : > "$NR/src/main.ts"; git_ init -q -b main "$NR"; git_ -C "$NR" add -A; git_ -C "$NR" commit -qm c1
quiet "no remote" "$NR"
# a remote with no default ref (only `dev` fetched)
ND="$TMP/app-nodefault"; mkdir -p "$ND/src"; : > "$ND/src/main.ts"; git_ init -q -b main "$ND"; git_ -C "$ND" add -A; git_ -C "$ND" commit -qm c1
git_ -C "$ND" remote add origin "$NOWHERE"; git_ -C "$ND" fetch -q "$REMOTE" '+refs/heads/main:refs/remotes/origin/dev'
quiet "no origin/HEAD, main or master" "$ND"
# not a git repository
NG="$TMP/not-git"; mkdir -p "$NG/src"; : > "$NG/src/main.ts"
quiet "not a git repository" "$NG"
# git hangs: the deadline holds well below the hook timeout of 10 s
SLOW="$TMP/slowgit"; mkdir -p "$SLOW"; REALGIT=$(command -v git)
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = for-each-ref ] && exec sleep 8; done\nexec "%s" "$@"\n' "$REALGIT" > "$SLOW/git"; chmod +x "$SLOW/git"
BEH="$TMP/app-behind2"; clone_app "$BEH"; git_ -C "$BEH" reset -q --hard HEAD~1; fetch_from "$BEH"
T0=$(python3 -c 'import time; print(time.time())')
O=$(PATH="$SLOW:$PATH" h_edit "$PL" "$BEH" "$(sid)" src/main.ts); rc=$?
T1=$(python3 -c 'import time; print(time.time())')
eq "$rc" 0 "[Q] git hangs: the edit hook rc 0"
hasnt "$O" '[from origin/' "[Q] git hangs: no mark (it could not tell)"
has "$O" "$BEH/policy/old.instructions.md" "[Q] git hangs: the tree's rules are still delivered"
python3 -c 'import sys; sys.exit(0 if float(sys.argv[2]) - float(sys.argv[1]) < 5 else 1)' "$T0" "$T1" \
  && ok "[Q] git hangs: the hook returned within 5 s (deadline 2 s, hook timeout 10 s)" || bad "[Q] git hangs: the hook took $(python3 -c "print(round($T1 - $T0, 1))") s"
has "$(ctx "$(h_edit "$PL" "$BEH" "$(sid)" src/main.ts)")" "${MARK1/$APP/$BEH}policy/old.instructions.md]" "[Q] control: the same clone with a working git is marked"

echo "== [R] round 1 of the review: edits on both sides, a feature branch, a fetch in the session, compaction, odd names =="
# a rule both the tree (uncommitted) and the ref changed: the tree's text, marked that the ref changed it too
BOTH="$TMP/app-both"; clone_app "$BOTH"; git_ -C "$BOTH" reset -q --hard HEAD~1; fetch_from "$BOTH"
rrule "$BOTH" old.instructions.md 'src/**' - - 'OLD-MINE'
O=$(ctx "$(h_edit "$PL" "$BOTH" "$(sid)" src/main.ts)")
has "$O" "- $BOTH/policy/old.instructions.md [origin/main changed it too and this tree is behind it by 1 commit: this is the tree's own edit; the ref's text: git -C $BOTH show origin/main:policy/old.instructions.md]" "[R] a rule both sides changed: the tree's path, marked, with the ref's text one command away"
hasnt "$O" 'origin/main:policy/old.instructions.md [from' "[R] …not served as the ref's"
# …committed on a branch instead of uncommitted: the same
git_ -C "$BOTH" checkout -q -b feature; git_ -C "$BOTH" commit -qam mine
has "$(ctx "$(h_edit "$PL" "$BOTH" "$(sid)" src/main.ts)")" "- $BOTH/policy/old.instructions.md [origin/main changed it too" "[R] …and when the edit is committed on a branch"
# the catalogue says the same
has "$(ctx "$(h_start "$PL" "$BOTH" "$(sid)")" | grep -F -- '- old.instructions.md')" "[origin/main changed it too and this tree is behind it by 1 commit: this is the tree's own edit" "[R] the catalogue marks the tree's own edit"
# a feature branch behind origin/main: the advice is a merge of origin/main, not a pull
SB=$(ctx "$(h_start "$PL" "$BOTH" "$(sid)")")
has "$SB" 'then bring the branch up to date with origin/main (`git merge origin/main`' "[R] on a feature branch the warning says to merge origin/main"
hasnt "$SB" 'git pull --ff-only' "[R] …and not to pull"
has "$SB" '1 file the tree changed too, delivered as the tree has them and marked' "[R] …and counts the kept edit"
# a fetch in the middle of a session: a rule reminded from the tree is reminded again, marked
MID="$TMP/app-mid"; clone_app "$MID"; git_ -C "$MID" reset -q --hard HEAD~1; git_ -C "$MID" update-ref refs/remotes/origin/main HEAD
S=$(sid)
has "$(ctx "$(h_edit "$PL" "$MID" "$S" src/main.ts)")" "$MID/policy/old.instructions.md" "[R] before the fetch: the tree's rule, unmarked"
fetch_from "$MID"
has "$(ctx "$(h_edit "$PL" "$MID" "$S" src/main.ts)")" "- origin/main:policy/old.instructions.md [from origin/main" "[R] after a fetch in the same session: reminded again, from the ref, marked"
has "$(ctx "$(h_start "$PL" "$MID" "$S")")" 'WARNING: this tree' "[R] …and SessionStart warns in that session (the tip moved)"
# compaction keeps the session id: the warning comes back with the catalogue
S=$(sid); h_start "$PL" "$MID" "$S" >/dev/null
CP=$(hook_cmds "$PL/hooks/hooks.json" SessionStart "" | sed -n 2p)
CO=$(printf '{"session_id":"%s","hook_event_name":"SessionStart","source":"compact"}' "$S" | CLAUDE_PROJECT_DIR="$MID" CLAUDE_PLUGIN_ROOT="$PL" bash -c "$CP" 2>/dev/null)
has "$(ctx "$CO")" 'WARNING: this tree' "[R] SessionStart after a compaction in the same session warns again"
hasnt "$(ctx "$(h_start "$PL" "$MID" "$S")")" 'WARNING: this tree' "[R] control: a plain second start in that session does not"
# a linked worktree that fetched: FETCH_HEAD is in its own git dir
WF="$TMP/wt-fetch"; git_ -C "$MID" worktree add -q -b wtf "$WF" HEAD~0 2>/dev/null
git_ -C "$WF" reset -q --hard "$(git_ -C "$MID" rev-parse HEAD)"
python3 -c 'import os, sys, time; t = time.time() - 5 * 86400; os.utime(sys.argv[1], (t, t))' "$MID/.git/FETCH_HEAD"
fetch_from "$WF"
has "$(ctx "$(h_start "$PL" "$WF" "$(sid)")")" '(last fetch: under a minute ago)' "[R] a worktree that just fetched: its own FETCH_HEAD, not the main tree's (5 days old)"
# the tree's text equals the ref's (the change was cherry-picked): nothing is stale, no mark
SAME="$TMP/app-same"; clone_app "$SAME"; git_ -C "$SAME" reset -q --hard HEAD~1; fetch_from "$SAME"
git_ -C "$SAME" show origin/main:policy/old.instructions.md > "$SAME/policy/old.instructions.md"
O=$(ctx "$(h_edit "$PL" "$SAME" "$(sid)" src/main.ts)")
has "$O" "- $SAME/policy/old.instructions.md" "[R] the tree has the ref's text already: the tree's path"
hasnt "$(printf '%s\n' "$O" | grep -F old.instructions.md)" '[' "[R] …unmarked"
# a slow git is not paid on every hook: the "could not tell" is remembered for a while in the session
SLOW2="$TMP/slowgit2"; mkdir -p "$SLOW2"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = rev-list ] && exec sleep 8; done\nexec "%s" "$@"\n' "$(command -v git)" > "$SLOW2/git"; chmod +x "$SLOW2/git"
SL="$TMP/app-slow"; clone_app "$SL"; git_ -C "$SL" reset -q --hard HEAD~1; fetch_from "$SL"
S=$(sid); PATH="$SLOW2:$PATH" h_edit "$PL" "$SL" "$S" src/main.ts >/dev/null
T0=$(python3 -c 'import time; print(time.time())'); PATH="$SLOW2:$PATH" h_edit "$PL" "$SL" "$S" src/x.ts >/dev/null
T1=$(python3 -c 'import time; print(time.time())')
python3 -c 'import sys; sys.exit(0 if float(sys.argv[2]) - float(sys.argv[1]) < 1.0 else 1)' "$T0" "$T1" \
  && ok "[R] git timed out once: the next hook of the session does not wait for it again (under 1 s)" || bad "[R] the next hook waited for git again ($(python3 -c "print(round($T1 - $T0, 2))") s)"
echo "== [D] the default ref and a linked worktree =="
# origin/HEAD names the default branch: trunk wins over main
TR="$TMP/app-trunk"; clone_app "$TR"; git_ -C "$TR" reset -q --hard HEAD~1; fetch_from "$TR"
git_ -C "$TR" update-ref refs/remotes/origin/trunk "$(git_ -C "$TR" rev-parse origin/main)"
git_ -C "$TR" update-ref refs/remotes/origin/main "$(git_ -C "$TR" rev-parse HEAD)"
git_ -C "$TR" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
has "$(ctx "$(h_edit "$PL" "$TR" "$(sid)" src/main.ts)")" "- origin/trunk:policy/old.instructions.md [from origin/trunk: this tree is behind it by 1 commit" "[D] origin/HEAD -> trunk: served from origin/trunk"
git_ -C "$TR" symbolic-ref -d refs/remotes/origin/HEAD
hasnt "$(ctx "$(h_edit "$PL" "$TR" "$(sid)" src/main.ts)")" '[from origin/' "[D] control: no origin/HEAD, origin/main is the default and the tree is at it"
# a linked worktree, one commit behind, as the project directory
WT="$TMP/wt"; git_ -C "$BEH" worktree add -q -b feature "$WT" HEAD 2>/dev/null
has "$(ctx "$(h_edit "$PL" "$WT" "$(sid)" src/main.ts)")" "${MARK1/$APP/$WT}policy/old.instructions.md]" "[D] a linked worktree behind origin/main: marked"

echo "== [P] planted breaks: each mark has a check that sees it go =="
breakit() {  # breakit <name> <file under scripts/> <old> <new> — a copy of the plugin with one replacement; prints its dir
  local d="$TMP/break-$1"; cp -r "$PL" "$d"
  python3 - "$d/scripts/$2" "$3" "$4" <<'PY' || { echo "anchor-missing"; return; }
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if s.count(old) != 1:
    sys.exit(1)
open(p, "w").write(s.replace(old, new))
PY
  printf '%s' "$d"
}
BEH3="$TMP/app-behind3"; clone_app "$BEH3"; git_ -C "$BEH3" reset -q --hard HEAD~1; fetch_from "$BEH3"
M3="${MARK1/$APP/$BEH3}"
c_mark()  { case "$(ctx "$(h_edit "$1" "$BEH3" "$(sid)" src/main.ts)")" in *"${M3}policy/old.instructions.md]"*) return 0;; esac; return 1; }
c_fresh() { case "$(ctx "$(h_edit "$1" "$BEH3" "$(sid)" src/main.ts)")" in *new.instructions.md*) return 0;; esac; return 1; }
c_warn()  { case "$(ctx "$(h_start "$1" "$BEH3" "$(sid)")")" in *"is behind origin/main by 1 commit."*) return 0;; esac; return 1; }
c_cat()   { case "$(ctx "$(h_start "$1" "$BEH3" "$(sid)")" | grep -F -- '- new.instructions.md')" in *"from origin/main"*) return 0;; esac; return 1; }
c_quote() {  # the command in the mark of the shell-syntax name runs nothing of it
  local cmd; rm -f "$TMP/qdir/PWNED"; mkdir -p "$TMP/qdir"
  cmd=$(ctx "$(h_edit "$1" "$BEH3" "$(sid)" src/main.ts)" | grep -F 'odd$(touch' | sed -n 's/.*read it with: \(.*\)\]$/\1/p' | head -1)
  [ -n "$cmd" ] || return 1
  (cd "$TMP/qdir" && bash -c "$cmd" >/dev/null 2>&1); [ ! -e "$TMP/qdir/PWNED" ]
}
for c in c_mark c_fresh c_warn c_cat c_quote; do $c "$PL" && ok "[P] $c is green on the plugin" || bad "[P] $c is red on the plugin"; done
planted() {  # planted <check> <name> <file> <old> <new>
  local d; d=$(breakit "$2" "$3" "$4" "$5")
  [ "$d" != anchor-missing ] || { bad "[P] $2: the anchor is gone from $3 (update this planted break)"; return; }
  local crc; capped "$1" "$d"; crc=$?   # capped: memory and time caps (fixtures/capped.sh)
  if cap_red "$crc" "[P] $2: $1"; then :; elif [ "$crc" = 0 ]; then bad "[P] $2: $1 stays green"; else ok "[P] $2: $1 goes red"; fi
}
planted c_mark no-mark vsdlc.py 'return "%s %s" % (R.shq("%s:%s" % (up["ref"], rel)), R.upstream_mark(up, rel, troot))' 'return "%s:%s" % (up["ref"], rel)'
planted c_fresh no-overlay vsdlc.py '    return up if up.get("behind") else None' '    return None'
planted c_warn no-warning vsdlc.py '    behind, sysmsg = behind_warning(up, troot, notes, R.repo_dirs(cfg["rules"])) if warn_now else ("", "")' '    behind, sysmsg = ("", "")'
planted c_cat no-catalogue-mark vsdlc.py '        f["from"] = R.upstream_mark(up, stale[name][0], troot, stale[name][1]) if up and name in stale else ""' '        f["from"] = ""'
planted c_quote no-quoting rules.py '    return p if re.match(' '    return p
    return p if re.match('
planted c_mark no-fork-point-diff rules.py '    if not out["behind"]:
        return out' '    if True:
        return out'

echo "== [R] a rule name with a space and a byte that is not UTF-8 (pushed last: the fixtures above are cut from c2) =="
# a rule name with a space and a byte that is not UTF-8, changed upstream: the hook does not fall over
ODD=$'odd name\xff.instructions.md'
rrule "$SEED" "$ODD" 'src/**' - - 'ODD-BYTES'; push_seed c3
OB="$TMP/app-oddbytes"; clone_app "$OB"; git_ -C "$OB" reset -q --hard "$C1"; fetch_from "$OB"
OO=$(h_edit "$PL" "$OB" "$(sid)" src/main.ts); rc=$?
eq "$rc" 0 "[R] a name with a space and a non-UTF-8 byte: rc 0"
hasnt "$OO" 'lỗi nội bộ' "[R] …no internal error"
has "$(ctx "$OO")" 'origin/main:policy/old.instructions.md [from origin/main: this tree is behind it by 2 commits' "[R] …and the other rules are still served from the ref, marked"

echo "== [R] a shallow and a partial clone (cut from the remote as it is now) =="
# a shallow clone (no fork point): a rule only the tree has is kept, marked, never dropped
SH="$TMP/app-shallow"; git_ clone -q --no-local --depth 1 "$REMOTE" "$SH" 2>/dev/null; git_ -C "$SH" remote set-url origin "$NOWHERE"
git_ -C "$SH" reset -q --soft HEAD 2>/dev/null; rrule "$SH" mine.instructions.md 'src/**' - - 'MINE-SHALLOW'
git_ -C "$SH" add -A; git_ -C "$SH" commit -qm mine
git_ -C "$SEED" commit -q --allow-empty -m bump; git_ -C "$SEED" push -q origin HEAD:main 2>/dev/null
git_ -C "$SH" fetch -q --depth 1 "$REMOTE" '+refs/heads/main:refs/remotes/origin/main' 2>/dev/null
git_ -C "$SH" merge-base HEAD origin/main >/dev/null 2>&1; eq "$?" 1 "[R] control: the shallow clone has no fork point with origin/main"
O=$(ctx "$(h_edit "$PL" "$SH" "$(sid)" src/main.ts)")
has "$O" "- $SH/policy/mine.instructions.md [origin/main does not have it" "[R] shallow: the tree's own rule is delivered, marked"
# a partial clone without the ref's blobs: the tree's text, marked that the ref's text is not here, and no fetch
git_ -C "$REMOTE" config uploadpack.allowFilter true
PC="$TMP/app-partial"; git_ clone -q --no-local --filter=blob:none --no-checkout "$REMOTE" "$PC" 2>/dev/null
git_ -C "$PC" checkout -q -B main "$C1" 2>/dev/null; NPC=$(git_ -C "$PC" rev-list --count HEAD..origin/main); git_ -C "$PC" remote set-url origin "$NOWHERE"
MISS0=$(git_ -C "$PC" rev-list --objects --missing=print --all 2>/dev/null | grep -c '^?')
O=$(ctx "$(h_edit "$PL" "$PC" "$(sid)" src/main.ts)")
has "$O" "- $PC/policy/old.instructions.md [origin/main changed it and this tree is behind it by $NPC commits, but its text is not in this clone" "[R] partial clone: the tree's text, marked that the ref's text is missing"
eq "$(git_ -C "$PC" rev-list --objects --missing=print --all 2>/dev/null | grep -c '^?')" "$MISS0" "[R] partial clone: the hook fetched no object (missing objects: $MISS0 before and after)"
[ "${MISS0:-0}" -gt 0 ] && ok "[R] control: the partial clone does lack objects ($MISS0)" || bad "[R] control: the partial clone lacks no object (the case proves nothing)"

echo "== [R2] review round 2: CRLF, a new rule in a partial clone, deleted there and changed here, a long catalogue =="
# a rule committed with CRLF that only the ref changed: the ref's text, not "the tree's own edit"
CR="$TMP/seed-crlf"; git_ clone -q "$REMOTE" "$CR" 2>/dev/null
printf -- '---\r\napplyTo: "src/**"\r\ndescription: "CRLF-V1"\r\n---\r\n\r\nBODY\r\n' > "$CR/policy/crlf.instructions.md"
git_ -C "$CR" add -A; git_ -C "$CR" commit -qm crlf1; git_ -C "$CR" push -q origin HEAD:main 2>/dev/null
CRA="$TMP/app-crlf"; clone_app "$CRA"
printf -- '---\r\napplyTo: "src/**"\r\ndescription: "CRLF-V2"\r\n---\r\n\r\nBODY\r\n' > "$CR/policy/crlf.instructions.md"
git_ -C "$CR" commit -qam crlf2; git_ -C "$CR" push -q origin HEAD:main 2>/dev/null; fetch_from "$CRA"
O=$(ctx "$(h_edit "$PL" "$CRA" "$(sid)" src/main.ts)")
has "$O" "- origin/main:policy/crlf.instructions.md [from origin/main: this tree is behind it by 1 commit" "[R2] a CRLF rule only the ref changed: the ref's text, marked as such"
hasnt "$O" 'crlf.instructions.md [origin/main changed it too' "[R2] …not taken for the tree's own edit"
# a rule the ref deleted and the tree changed: `gone` (a git show of it would fail), not `both`
git_ -C "$CRA" merge -q --ff-only origin/main
rrule "$CRA" old.instructions.md 'src/**' - - 'OLD-EDITED-HERE'
git_ -C "$CR" pull -q "$REMOTE" main 2>/dev/null; git_ -C "$CR" rm -q policy/old.instructions.md; git_ -C "$CR" commit -qm del-old
git_ -C "$CR" push -q origin HEAD:main 2>/dev/null; fetch_from "$CRA"
O=$(ctx "$(h_edit "$PL" "$CRA" "$(sid)" src/main.ts)")
has "$O" "- $CRA/policy/old.instructions.md [origin/main does not have it" "[R2] deleted there, changed here: marked as the ref lacking it"
hasnt "$O" "show origin/main:policy/old.instructions.md" "[R2] …with no git show of a file the ref does not have"
# a partial clone where the ref ADDED a rule whose blob is missing: the warning counts and names it
rrule "$CR" partial-new.instructions.md 'src/**' - - 'PARTIAL-NEW'; git_ -C "$CR" add -A; git_ -C "$CR" commit -qm pnew
git_ -C "$CR" push -q origin HEAD:main 2>/dev/null
PN="$TMP/app-partial-new"; git_ clone -q --no-local --filter=blob:none --no-checkout "$REMOTE" "$PN" 2>/dev/null
git_ -C "$PN" checkout -q -B main origin/main~1 2>/dev/null; git_ -C "$PN" remote set-url origin "$NOWHERE"
[ ! -e "$PN/policy/partial-new.instructions.md" ] && ok "[R2] control: the partial clone's tree lacks the new rule" || bad "[R2] control: the new rule is in the tree"
has "$(ctx "$(h_start "$PL" "$PN" "$(sid)")")" '1 file whose text this clone lacks (policy/partial-new.instructions.md)' "[R2] partial clone, a rule only the ref has: the warning counts and names it"
# a long catalogue: the rows lose their command before the context passes the hook cap, and the warning stays
LONG="$TMP/app-long"; clone_app "$LONG"; fetch_from "$LONG"; git_ -C "$LONG" merge -q --ff-only origin/main
for i in $(seq 1 40); do rrule "$CR" "many-$i.instructions.md" 'src/**' - - "MANY-$i"; done
git_ -C "$CR" add -A; git_ -C "$CR" commit -qm many; git_ -C "$CR" push -q origin HEAD:main 2>/dev/null; fetch_from "$LONG"
LC=$(ctx "$(h_start "$PL" "$LONG" "$(sid)")")
[ "$(nchars "$LC")" -le 10000 ] && ok "[R2] 40 rules from the ref: the catalogue context is $(nchars "$LC") characters (cap 10000)" || bad "[R2] the catalogue context is $(nchars "$LC") characters, above the hook cap"
has "$LC" 'WARNING: this tree' "[R2] …and keeps the behind warning"
has "$(printf '%s\n' "$LC" | grep -F -- '- many-1.instructions.md')" '[from origin/main' "[R2] …and each row still carries its mark"

echo "== [R3] review round 3: a CRLF checkout of LF blobs (core.autocrlf), a catalogue of 120 rules =="
AC="$TMP/app-autocrlf"; git_ clone -q -c core.autocrlf=true "$REMOTE" "$AC" 2>/dev/null; git_ -C "$AC" remote set-url origin "$NOWHERE"
git_ -C "$AC" reset -q --hard HEAD~1
grep -q $'\r' "$AC/policy/local.instructions.md" && ok "[R3] control: the autocrlf checkout has CRLF files" || bad "[R3] control: no CRLF in the autocrlf checkout"
empty "$(git_ -C "$AC" status --porcelain)" "[R3] control: …and git sees a clean tree"
rrule "$CR" local.instructions.md 'src/**' - - 'LOCAL-V2'; git_ -C "$CR" commit -qam local2; git_ -C "$CR" push -q origin HEAD:main 2>/dev/null
fetch_from "$AC"
O=$(ctx "$(h_edit "$PL" "$AC" "$(sid)" src/main.ts)")
has "$O" "- origin/main:policy/local.instructions.md [from origin/main" "[R3] autocrlf: a rule only the ref changed is the ref's text"
hasnt "$O" 'local.instructions.md [origin/main changed it too' "[R3] …not taken for the tree's own edit"
# 120 long-named rules from the ref: the context stays under the hook cap, with the warning and a line for what is left out
for i in $(seq 1 120); do rrule "$CR" "a-fairly-long-rule-name-number-$i.instructions.md" 'src/**' - - "LONG-$i"; done
git_ -C "$CR" add -A; git_ -C "$CR" commit -qm long; git_ -C "$CR" push -q origin HEAD:main 2>/dev/null
LG="$TMP/app-120"; clone_app "$LG"; git_ -C "$LG" reset -q --hard HEAD~1; fetch_from "$LG"
c_cap() { local c; c=$(ctx "$(h_start "$1" "$LG" "$(sid)")"); [ "$(nchars "$c")" -le 10000 ] && case "$c" in *'WARNING: this tree'*'more rule(s) not listed here'*) return 0;; esac; return 1; }
c_cap "$PL" && ok "[R3] 120 rules from the ref: under 10000 characters, the warning kept, the left-out rows counted" || bad "[R3] 120 rules: over the cap, or the warning or the count line is missing"
D=$(breakit no-row-cut vsdlc.py '    while len(body) > BUDGET and rows_out:' '    while False:')
[ "$D" != anchor-missing ] && ok "[R3] planted break anchor found" || bad "[R3] a planted break lost its anchor (update it)"
capped c_cap "$D"; crc=$?   # capped: memory and time caps (fixtures/capped.sh)
if cap_red "$crc" "[R3] planted break: without the row cut"; then :; elif [ "$crc" = 0 ]; then bad "[R3] planted break: without the row cut the check stays green"; else ok "[R3] planted break: without the row cut the check goes red"; fi
D=$(breakit no-crlf-normalise rules.py '    return None if t is None else t.replace("\r\n", "\n")' '    return t')
[ "$D" != anchor-missing ] && ok "[R3] planted break anchor found" || bad "[R3] a planted break lost its anchor (update it)"
o=$(capped h_edit "$D" "$AC" "$(sid)" src/main.ts); crc=$?   # capped: memory and time caps (fixtures/capped.sh)
cap_red "$crc" "[R3] planted break: without CRLF normalising" || case "$(ctx "$o")" in *"origin/main:policy/local.instructions.md [from origin/main"*) bad "[R3] planted break: without CRLF normalising the autocrlf case stays green";; *) ok "[R3] planted break: without CRLF normalising the autocrlf case goes red";; esac

echo "== [R] the remote moves the rules directory and its config: the tree's rules stay, marked =="
MV="$TMP/app-moved"; clone_app "$MV"; fetch_from "$MV"; git_ -C "$MV" merge -q --ff-only origin/main
git_ -C "$SEED" pull -q "$REMOTE" main 2>/dev/null; git_ -C "$SEED" mv policy rules2; printf '{"schema": 1, "rules": {"dirs": ["rules2"]}}' > "$SEED/.vibemaestro/sdlc.json"; push_seed moved
fetch_from "$MV"
O=$(ctx "$(h_edit "$PL" "$MV" "$(sid)" src/main.ts)")
eq "$(git_ -C "$MV" ls-tree --name-only origin/main | grep -c '^policy$')" 0 "[R] control: origin/main has no policy/ any more"
has "$O" "- $MV/policy/local.instructions.md [origin/main does not have it" "[R] moved upstream: the tree's rule is still delivered, marked"

summary
