#!/bin/bash
# =============================================================================
# BatonRun: the owner's delegation window, a W item of the brain with a scope, lowers signing while it is in force
# =============================================================================
# Run: bash tests/test-baton-window.sh
#
# A window is a W item the owner pinned in the brain with --lower (and --exclude) through the brain's owner dialog; the runner
# reads it (`brain windows --json` of the brain installed beside the sdlc copy) at each coordinator-auto signature and run. A world
# is an installed sdlc copy, a copy of the real brain and a dependent plugin of kit batons beside it in a registry, a git project W
# and mode auto; the brain's dialog record is written as its guard writes it, then the owner's command runs.
#   [replay]    a day's work under W1 (lowers owner-acts and security-boundary): kit:plugin-export and kit:owner-merge (a fake GitHub) are
#               signed coordinator-auto under W1, `go: ok … — window W1`; a secret entry (kit:vault-put-text, Stops secrets) stops
#               for the owner, exit 8
#   [trace]     the spent record names W1, the sign and run lines of log.tsv name the signer coordinator-auto@W1, log --digest
#               lists the runs under window W1 and counts them as coordinator-auto
#   [session]   the session that pinned W1 again (a resume, --continue or a compaction keeps the id; from another directory):
#               lowered; after /clear, after --fork-session (a new id), with no id: exit 8
#   [floor]     Stops mixing owner-acts and secrets; kit:plugin-install (it changes the machine's permissions); a session baton
#               declaring security-boundary whose argument names a Claude Code settings file; a kit the window excludes; a category
#               it does not lower: exit 8, the card's window line names why
#   [floor-merge] an owner merge of a PR that changes a WINDOW_FLOOR_PATHS file (a rename's old name too; one of two PRs; files
#               that cannot be read): exit 8 naming it; a PR that only adds a baton: merged under the window
#   [named]     a window naming kit:owner-merge alone lowers that baton and no other
#   [ended]     closed by the session, unpinned by the owner, expired, mode manual, a worker session, a broken brain chain: exit 8;
#               closed between sign and run: the run refused, nothing ran, the signature kept
#   [clock]     a clock behind the newest log line reads no window; a window from the future, over 24 hours, imported, of another
#               session or with no scope covers nothing
#   [same]      a window with no scope, or none: go's exit-8 output is the one with no brain installed at all
#   [forge]     hot.json rewritten with its digest to give a window a scope: brain windows and the runner read the log, exit 8
#   [lists]     the brain's copy of the never-lowered lists and the 24-hour cap is the runner's; every stop word is lowerable or never
# No network: the fake gh answers kit:owner-merge; nothing outside the scratch tree.
# =============================================================================
set -uo pipefail
# the brain's owner dialog reads ancestors' CLAUDE_CONFIG_DIR and HOME from their initial environment, which forked subshells
# share: start again without the launcher's (clean_env then points HOME into the scratch tree; the user base is pinned first)
if [ -z "${WINDOW_SUITE_REEXEC:-}" ]; then
  export PYTHONUSERBASE="${PYTHONUSERBASE:-$(python3 -m site --user-base 2>/dev/null)}"
  exec env -u CLAUDE_CONFIG_DIR WINDOW_SUITE_REEXEC=1 HOME=/nonexistent bash "$0" "$@"
fi
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
# shellcheck source=fixtures/ports.sh
. "$HERE/fixtures/ports.sh"
# shellcheck source=fixtures/baton-owner.sh
. "$HERE/fixtures/baton-owner.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
KD_FIX="$HERE/fixtures/dependent-plugin"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
clean_env "$TMP"
# shellcheck source=fixtures/brain.sh
. "$HERE/fixtures/brain.sh"
export PYTHONDONTWRITEBYTECODE=1
H0=$(tree_hash "$SRC_ROOT")
brain_kit "$SRC_ROOT"                                 # KIT, BROOT: a copy of the real brain, isolated from the machine
GHB="$TMP/ghbin"; mkdir -p "$GHB"
printf '#!/bin/sh\nexec python3 -I -B "%s" "%s" "%s" "$@"\n' "$HERE/fixtures/owner_merge_gh.py" "$TMP/world.json" "$TMP/merges.log" > "$GHB/gh"
chmod +x "$GHB/gh"; PATH="$GHB:$PATH"; export PATH
H1=1111111111111111111111111111111111111111
BT_OUT="$TMP/bt.out"; SID=s-coord; C=""; S=""; D=""; W=""; ST=""; RC=""; BT_ENV=(MERGE_GUARD_RETRY_WAIT_S=0); N=0

# mkkit <plugin dir> <name> <Stops> — the fixture kit (kit:fixture-kit) under that name and Stops: new bytes, an input, not a break
mkkit() {
  python3 - "$KD_FIX/batons/fixture-kit.sh" "$1/batons/$2.sh" "$2" "$3" <<'PY'
import sys
src, dst, name, stops = sys.argv[1:5]
t = open(src).read()
for old, new in (("kit:fixture-kit", "kit:" + name), ("\n# Stops: none\n", "\n# Stops: %s\n" % stops)):
    if old not in t:
        sys.exit("mkkit: %r is not in the fixture" % old)
    t = t.replace(old, new)
open(dst, "w").write(t)
PY
}
# reg [brain dir] — the plugin registry: the sdlc copy S, the kits plugin D and, given one, the brain
reg() {
  python3 - "$C/plugins/installed_plugins.json" "$S" "$D" "${1:-}" <<'PY'
import json, sys
e = lambda p: [{"scope": "user", "installPath": p, "version": "1.0.0", "lastUpdated": "2026-11-17T00:00:00.000Z"}]
ids = {"vibemaestro-sdlc@vibemaestro": e(sys.argv[2]), "dependent-fixture@vibemaestro": e(sys.argv[3])}
if sys.argv[4]:
    ids["vibemaestro-brain@vibemaestro"] = e(sys.argv[4])
json.dump({"version": 2, "plugins": ids}, open(sys.argv[1], "w"))
PY
}
# bt <dir> <baton args...> — rc of the installed copy's baton from <dir> as session SID (plus BT_ENV); output in $BT_OUT
bt() {
  local d=$1; shift
  ( cd "$d" && cenv XDG_STATE_HOME="$ST" CLAUDE_CODE_SESSION_ID="$SID" ${BT_ENV[@]+"${BT_ENV[@]}"} python3 "$S/scripts/baton.py" "$@" ) \
    > "$BT_OUT" 2>&1; echo $?
}
# btc — bt for a call that must stop or be refused: through capped (tests/fixtures/capped.sh), as a negative case runs
btc() { capped bt "$@"; }
out() { cat "$BT_OUT"; }
bdir() { printf '%s' "$ST/vibemaestro/baton"; }
# bw <brain args...> — the brain of BROOT from W as session SID, in the world's state; OUT and RC
bw() { OUT=$(cd "$W" && cenv XDG_STATE_HOME="$ST" CLAUDE_CODE_SESSION_ID="$SID" "$BROOT/bin/brain" "$@" 2>&1); RC=$?; }
# bpy_w <python on s> — code with the brain's store imported as s, from W as session SID
bpy_w() { (cd "$W" && cenv XDG_STATE_HOME="$ST" CLAUDE_CODE_SESSION_ID="$SID" python3 -c "import sys; sys.path.insert(0, sys.argv[1]); import brain_store as s
$1" "$BROOT/scripts" "${@:2}"); }
# pin <args after owner…> — the owner's act: the dialog record guard-owner writes, then the owner's command; OUT and RC
pin() { bpy_w 's.record_asked(s.state_dir(), sys.argv[2], "default", sys.argv[3:])' "$SID" "$@"; bw owner "$@"; }
at() { python3 -c 'import sys, time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + int(sys.argv[1]))))' "$1"; }
# window <args after the expiry…> — W<n> pinned by the owner for session SID, until a day ahead less a minute
window() { pin add --kind window --text "the day's work, no infrastructure or secret entry" --owner-quote "q" --where "chat" \
             --expires "$(at 86340)" "$@"; }
owner_mode() { mode_asked "$S" "$W" "$ST" "$SID" "$@" >/dev/null; bt "$W" mode "$@" >/dev/null; }
# wset <python statement over w> — change the fake GitHub's world (the test's input, not a break)
wset() { python3 -c 'import json, sys; p = sys.argv[1]; w = json.load(open(p)); exec(sys.argv[2]); json.dump(w, open(p, "w"))' "$TMP/world.json" "$@" \
            || bad "wset: the world was not changed: $1"; }
# nf — F: a fresh file path under W for a fixture kit to create (no subshell: the count goes on)
nf() { N=$((N+1)); F="$W/out/f$N"; }
created() { [ -f "$1" ] && echo created || echo absent; }
wline() { sed -n 's/^window: not lowered: //p' "$BT_OUT"; }
# world — a fresh world: the installed sdlc copy S beside the kits plugin D and the brain in a registry; the project W (a git
# repository); mode auto; the fake GitHub's world: PR o/r#1 open at H1, mergeable, two green checks, adding one baton
world() {
  C="$(fresh)/claude"; S="$C/plugins/cache/vibemaestro/vibemaestro-sdlc/1.0.0"; D="$C/plugins/cache/vibemaestro/dependent-fixture/1.0.0"
  mkdir -p "$(dirname "$S")" "$D/batons"; mk_plugin_copy "$S"; cp -r "$KD_FIX/.claude-plugin" "$D/"
  mkkit "$D" plugin-export owner-acts; mkkit "$D" vault-put-text secrets; mkkit "$D" plugin-install "owner-acts, security-boundary"
  mkkit "$D" mixed-entry "owner-acts, secrets"; mkkit "$D" note-publish publish; mkkit "$D" plain-note none
  reg "$BROOT"
  ST="$(fresh)/state"; W=$(fresh); W=$(cd "$W" && pwd -P); SID=s-coord
  git_ init -q -b main "$W"; mkdir -p "$W/out"
  owner_mode auto
  python3 - "$TMP/world.json" "$H1" <<'PY'
import json, sys
w = {"prs": {"o/r#1": {"state": "OPEN", "isDraft": False, "head": sys.argv[2], "mergeable": "MERGEABLE", "base": "main",
                         "files": ["plugins/vibemaestro-sdlc/batons/new-kit.sh"], "added": ["plugins/vibemaestro-sdlc/batons/new-kit.sh"]}},
     "checks": {"o/r@" + sys.argv[2]: [["bash tests/run-all.sh", "2026-11-17T01:00:00Z", "completed", "success"],
                                       ["signing-rules", "2026-11-17T01:00:00Z", "completed", "success"]]}}
json.dump(w, open(sys.argv[1], "w"))
PY
  : > "$TMP/merges.log"
}

fam_replay() {  # [replay] a day's work under W1: the export and the owner merge sign under it, the secret entry waits
  local T=replay f
  world; window --lower owner-acts --lower security-boundary; eq "$RC" 0 "[$T] the owner pins W1 (lowers owner-acts, security-boundary)"
  nf; f=$F; eq "$(bt "$W" go kit:plugin-export "$f" "the day's export")" 0 "[$T] go kit:plugin-export (Stops owner-acts): rc 0, no owner dialog"
  has "$(out)" "go: ok — 1 write — " "[$T] …one ok line"; has "$(out)" " — window W1" "[$T] …naming the window"
  eq "$(created "$f")" created "[$T] …the export ran"
  eq "$(bt "$W" go kit:owner-merge o/r 1 "$H1")" 0 "[$T] go kit:owner-merge, the owner merge of the day (Stops security-boundary, owner-acts): rc 0"
  has "$(out)" " — window W1" "[$T] …under W1"
  eq "$(cat "$TMP/merges.log")" "merge o/r#1 match $H1 admin no" "[$T] …one squash merge, pinned to the head"
  nf; f=$F; eq "$(btc "$W" go kit:vault-put-text "$f" "a secret")" 8 "[$T] go kit:vault-put-text (Stops secrets): exit 8, the owner signs"
  eq "$(wline)" "a window never lowers secrets" "[$T] …the card says the window never lowers secrets"
  eq "$(created "$f")" absent "[$T] …nothing ran"
}

fam_trace() {  # [trace] the record, the log and the digest name the window
  local T=trace rec
  world; window --lower owner-acts
  nf; bt "$W" go kit:plugin-export "$F" one >/dev/null; nf; bt "$W" go kit:plugin-export "$F" two >/dev/null
  rec=$(ls -t "$(bdir)/used/"*.json | head -n 1)
  eq "$(python3 -c 'import json, sys; r = json.load(open(sys.argv[1])); print(r["signed_by"], r["window"]["id"], r["window"]["lowers"], r["stops"])' "$rec")" \
     "coordinator-auto W1 ['owner-acts'] ['owner-acts']" "[$T] the spent record: signed_by coordinator-auto, window W1 with its scope"
  eq "$(awk -F'\t' '$8 == "coordinator-auto@W1" {print $2 "/" $10}' "$(bdir)/log.tsv" | sort | uniq -c | tr -s ' ' | sed 's/^ //' | tr '\n' ';')" \
     "2 run-start/-;2 run/ok;2 sign/signed;" "[$T] log.tsv: each sign, run-start and run line names the signer coordinator-auto@W1"
  bt "$W" log --tail 3 >/dev/null; has "$(out)" "coordinator-auto@W1" "[$T] baton log shows it"
  bt "$W" log --digest >/dev/null
  has "$(out)" "window W1 of the brain: 2 act(s) signed coordinator-auto under it" "[$T] log --digest: the runs under window W1"
  has "$(out)" "signers: coordinator-auto 2" "[$T] …counted as coordinator-auto"
}

fam_session() {  # [session] only the session that pinned the window
  local T=session X f
  world; window --lower owner-acts
  X=$(fresh); bpy_w 's.record_session(sys.argv[2], sys.argv[3], s.state_dir())' "$SID" "$W"   # what SessionStart records on a resume: an input, not a break
  nf; f=$F; eq "$(bt "$X" go kit:plugin-export "$f" again)" 0 "[$T] a resume, --continue or a compaction (same id), the shell elsewhere: rc 0"
  has "$(out)" " — window W1" "[$T] …lowered under W1"
  SID=s-after-clear; nf; f=$F; eq "$(btc "$W" go kit:plugin-export "$f" x)" 8 "[$T] after /clear (a new session id): exit 8"
  eq "$(wline)" "W1 was pinned by another session" "[$T] …the card names why"; eq "$(created "$f")" absent "[$T] …nothing ran"
  SID=s-fork; bpy_w 's.record_session(sys.argv[2], sys.argv[3], s.state_dir())' "$SID" "$W"   # what SessionStart records for the fork: an input, not a break
  nf; f=$F; eq "$(btc "$W" go kit:plugin-export "$f" x)" 8 "[$T] a --fork-session (a new id, the same project): exit 8"
  eq "$(wline)" "W1 was pinned by another session" "[$T] …named"
  SID=""; nf; f=$F; eq "$(btc "$W" go kit:plugin-export "$f" x)" 8 "[$T] no session id: exit 8"
  eq "$(wline)" "" "[$T] …no window read"
}

fam_floor() {  # [floor] never lowered, whatever the window says
  local T=floor f
  world; window --lower owner-acts --lower security-boundary --lower publish --exclude kit:note-publish
  nf; f=$F; eq "$(btc "$W" go kit:mixed-entry "$f" x)" 8 "[$T] Stops owner-acts, secrets: exit 8"
  eq "$(wline)" "a window never lowers secrets" "[$T] …named"
  nf; f=$F; eq "$(btc "$W" go kit:plugin-install "$f" x)" 8 "[$T] kit:plugin-install (owner-acts, security-boundary): exit 8"
  eq "$(wline)" "a window never lowers kit:plugin-install" "[$T] …it changes the machine's permissions"
  mkdir -p "$W/.claude"   # a session baton written just now (the params fixture), its declared Stops an input, not a break
  python3 "$HERE/fixtures/baton_params.py" make "$S" "$W/session-entry.sh" "dest=path" "{dest}/** — the file"
  sed -i 's/^# Stops: none$/# Stops: security-boundary/' "$W/session-entry.sh"   # its declared Stops: an input, not a break
  eq "$(btc "$W" go "$W/session-entry.sh" "dest=$W/.claude")" 8 \
     "[$T] a session baton declaring security-boundary, its value the Claude Code settings directory: exit 8"
  eq "$(wline)" "a window never lowers a call naming a Claude Code settings file" "[$T] …named"
  eq "$(created "$W/.claude/x")" absent "[$T] …nothing written"
  mkdir -p "$W/plain"; python3 "$HERE/fixtures/baton_params.py" make "$S" "$W/sb-entry.sh" "dest=path" "{dest}/** — the file"
  sed -i 's/^# Stops: none$/# Stops: security-boundary/' "$W/sb-entry.sh"   # its declared Stops: an input, not a break
  eq "$(btc "$W" go "$W/sb-entry.sh" "dest=$W/plain")" 8 \
     "[$T] a session baton declaring security-boundary, its value harmless (its body could write the settings): exit 8"
  eq "$(wline)" "a window never lowers security-boundary of a baton that is not a kit: (it may change the machine's permissions)" "[$T] …named"
  eq "$(created "$W/plain/x")" absent "[$T] …nothing written"
  nf; f=$F; eq "$(btc "$W" go kit:note-publish "$f" x)" 8 "[$T] a kit the window excludes: exit 8"
  eq "$(wline)" "W1 excludes kit:note-publish" "[$T] …named"
  world; window --lower owner-acts
  nf; f=$F; eq "$(btc "$W" go kit:note-publish "$f" x)" 8 "[$T] a category the window does not lower (publish): exit 8"
  eq "$(wline)" "W1 does not lower publish" "[$T] …named"
}

fam_floor_merge() {  # [floor-merge] an owner merge of a PR that changes the signing floor is never lowered; any other still is
  local T=floor-merge H2=2222222222222222222222222222222222222222 f seal
  world; window --lower owner-acts --lower security-boundary
  wset 'w["prs"]["o/r#1"]["files"] = ["plugins/vibemaestro-sdlc/scripts/baton.py"]'
  eq "$(btc "$W" go kit:owner-merge o/r 1 "$H1")" 8 "[$T] a PR that changes the runner, under W1: exit 8, the owner merges"
  eq "$(wline)" "a window never lowers an owner merge of o/r#1: it changes plugins/vibemaestro-sdlc/scripts/baton.py, which decides who signs" \
     "[$T] …the card says why"
  eq "$(cat "$TMP/merges.log")" "" "[$T] …nothing merged"
  wset 'w["prs"]["o/r#1"]["files"] = ["plugins/vibemaestro-sdlc/batons/new-kit.sh", ".github/workflows/signing-rules.yml"]'
  eq "$(btc "$W" go kit:owner-merge o/r 1 "$H1")" 8 "[$T] a PR that adds a baton and changes the signing-rules job: exit 8"
  eq "$(wline)" "a window never lowers an owner merge of o/r#1: it changes .github/workflows/signing-rules.yml, which decides who signs" "[$T] …named"
  wset 'w["prs"]["o/r#1"]["files"] = ["plugins/vibemaestro-sdlc/scripts/runner.py"]; w["prs"]["o/r#1"]["renamed"] = {"plugins/vibemaestro-sdlc/scripts/runner.py": "plugins/vibemaestro-sdlc/scripts/baton-guard.py"}'
  eq "$(btc "$W" go kit:owner-merge o/r 1 "$H1")" 8 "[$T] a PR that renames the owner's dialog guard away: exit 8"
  eq "$(wline)" "a window never lowers an owner merge of o/r#1: it changes plugins/vibemaestro-sdlc/scripts/baton-guard.py, which decides who signs" \
     "[$T] …named by its old name"
  wset 'w["prs"]["o/r#1"]["files"] = ["plugins/vibemaestro-sdlc/batons/new-kit.sh"]; w["prs"]["o/r#1"].pop("renamed"); w["prs"]["o/r#1"]["files_fail"] = True'
  eq "$(btc "$W" go kit:owner-merge o/r 1 "$H1")" 8 "[$T] the PR's files cannot be read: exit 8"
  has "$(wline)" "the changed files of o/r#1 cannot be read" "[$T] …named"
  wset 'w["prs"]["o/r#1"].pop("files_fail"); w["prs"]["o/q#2"] = dict(w["prs"]["o/r#1"], head="'"$H2"'", files=[".vibemaestro/sdlc.json"]); w["checks"]["o/q@'"$H2"'"] = w["checks"]["o/r@'"$H1"'"]'
  eq "$(btc "$W" go kit:owner-merge o/r 1 "$H1" o/q 2 "$H2")" 8 "[$T] two PRs in one call, the second changes the merge config: exit 8"
  eq "$(wline)" "a window never lowers an owner merge of o/q#2: it changes .vibemaestro/sdlc.json, which decides who signs" "[$T] …named"
  eq "$(cat "$TMP/merges.log")" "" "[$T] …nothing merged by any of these"
  for f in plugins/vibemaestro-brain/scripts/pyrun.sh plugins/vibemaestro-brain/scripts/brain_host.py plugins/vibemaestro-sdlc/gates/baton.py; do
    wset 'w["prs"]["o/r#1"]["files"] = ["'"$f"'"]'
    eq "$(btc "$W" go kit:owner-merge o/r 1 "$H1")" 8 "[$T] a PR that changes $f: exit 8"
    eq "$(wline)" "a window never lowers an owner merge of o/r#1: it changes $f, which decides who signs" "[$T] …named"
  done
  for c in 'edited|"plugins/vibemaestro-sdlc/batons/merge-pr.sh"|plugins/vibemaestro-sdlc/batons/merge-pr.sh' \
           'removed|"plugins/vibemaestro-sdlc/batons/old-kit.sh"], "removed": ["plugins/vibemaestro-sdlc/batons/old-kit.sh"|plugins/vibemaestro-sdlc/batons/old-kit.sh' \
           'renamed|"plugins/vibemaestro-sdlc/templates/baton-kinds/kind-b.sh"], "renamed": {"plugins/vibemaestro-sdlc/templates/baton-kinds/kind-b.sh": "plugins/vibemaestro-sdlc/templates/baton-kinds/kind-a.sh"}, "x": [|plugins/vibemaestro-sdlc/templates/baton-kinds/kind-a.sh, plugins/vibemaestro-sdlc/templates/baton-kinds/kind-b.sh' \
           'vendored-gate|".vibemaestro/gates/signing_rules.py"|.vibemaestro/gates/signing_rules.py' \
           'repo-config|".vibemaestro/values.yaml"|.vibemaestro/values.yaml'; do
    IFS='|' read -r what files named <<<"$c"
    wset 'q = w["prs"]["o/r#1"]; [q.pop(k, None) for k in ("renamed", "removed", "x")]; q.update(json.loads("{\"files\": [" + sys.argv[3] + "]}"))' "$files"
    eq "$(btc "$W" go kit:owner-merge o/r 1 "$H1")" 8 "[$T] a PR with a $what file: exit 8"
    eq "$(wline)" "a window never lowers an owner merge of o/r#1: it changes $named, which decides who signs" "[$T] …named"
  done
  wset 'q = w["prs"]["o/r#1"]; [q.pop(k, None) for k in ("renamed", "removed", "x")]'
  wset 'w["prs"]["o/r#1"]["files"] = ["plugins/vibemaestro-sdlc/batons/new-kit.sh", "plugins/vibemaestro-sdlc/scripts/baton.py"]; w["prs"]["o/r#1"]["pages"] = 2'
  eq "$(btc "$W" go kit:owner-merge o/r 1 "$H1")" 8 "[$T] the floor file on the second page of the file list: exit 8"
  has "$(wline)" "it changes plugins/vibemaestro-sdlc/scripts/baton.py" "[$T] …named"
  wset 'w["prs"]["o/r#1"]["files"] = ["plugins/vibemaestro-sdlc/batons/new-kit.sh"]; w["prs"]["o/r#1"]["page_junk"] = "{}"'
  eq "$(btc "$W" go kit:owner-merge o/r 1 "$H1")" 8 "[$T] a page that is not a list of files after a good one: exit 8"
  has "$(wline)" "the changed files of o/r#1 cannot be read" "[$T] …named"
  wset 'w["prs"]["o/r#1"]["page_junk"] = "[{\"status\": \"added\"}]"'
  eq "$(btc "$W" go kit:owner-merge o/r 1 "$H1")" 8 "[$T] a page holding a file with no name: exit 8"
  has "$(wline)" "the changed files of o/r#1 cannot be read" "[$T] …named"
  wset 'w["prs"]["o/r#1"].pop("page_junk"); w["prs"]["o/r#1"].pop("pages"); w["prs"]["o/r#1"]["files"] = ["docs/f%d.md" % k for k in range(3000)]'
  eq "$(btc "$W" go kit:owner-merge o/r 1 "$H1")" 8 "[$T] 3000 files, where GitHub stops listing: exit 8, the list may be cut"
  has "$(wline)" "GitHub's cap: the list may be cut" "[$T] …named"
  wset 'w["prs"]["o/r#1"]["files"] = ["plugins/vibemaestro-sdlc/batons/new-kit.sh"]'
  bt "$W" rehearse kit:owner-merge o/r 1 "$H1" >/dev/null; seal=$(sed -n 's/^seal \([^ ]*\) .*/\1/p' "$BT_OUT")
  eq "$(bt "$W" sign --by coordinator-auto --seal "${seal:-none}" kit:owner-merge o/r 1 "$H1")" 0 "[$T] sign --by coordinator-auto, the PR adding a baton only: rc 0"
  wset 'w["prs"]["o/r#1"]["files"] = ["plugins/vibemaestro-sdlc/batons/new-kit.sh", ".vibemaestro/sdlc.json"]'
  eq "$(btc "$W" run kit:owner-merge o/r 1 "$H1")" 3 "[$T] the PR then changes the merge config: run refused, rc 3"
  has "$(out)" "window W1, which it was signed under, does not cover it now: a window never lowers an owner merge of o/r#1: it changes .vibemaestro/sdlc.json" "[$T] …named"
  eq "$(cat "$TMP/merges.log")" "" "[$T] …nothing merged"
  wset 'w["prs"]["o/r#1"]["files"] = ["plugins/vibemaestro-sdlc/batons/new-kit.sh"]'
  wset 'w["checks"]["o/r@'"$H1"'"][1][3] = "failure"'   # signing-rules red on the PR: a new baton is an owner merge
  eq "$(bt "$W" go kit:owner-merge o/r 1 "$H1" --accept-red signing-rules)" 0 \
     "[$T] a PR that only adds a baton, signing-rules red and accepted: rc 0, under the window"
  has "$(out)" " — window W1" "[$T] …signed coordinator-auto@W1"
  eq "$(cat "$TMP/merges.log")" "merge o/r#1 match $H1 admin no" "[$T] …merged"
}

fam_named() {  # [named] a kit baton by name
  local T=named f
  world; window --lower kit:owner-merge
  eq "$(bt "$W" go kit:owner-merge o/r 1 "$H1")" 0 "[$T] a window naming kit:owner-merge: go kit:owner-merge rc 0"
  has "$(out)" " — window W1" "[$T] …under W1"
  nf; f=$F; eq "$(btc "$W" go kit:plugin-export "$f" x)" 8 "[$T] …and no other baton: kit:plugin-export exit 8"
  eq "$(wline)" "W1 does not lower owner-acts" "[$T] …named"
}

fam_ended() {  # [ended] a window that ended, or a call it never reaches, signs as with no window
  local T=ended f seal
  world; window --lower owner-acts
  bw op close W1 --reason "the owner said stop"; eq "$RC" 0 "[$T] the coordinator closes W1 (no dialog)"
  nf; f=$F; eq "$(btc "$W" go kit:plugin-export "$f" x)" 8 "[$T] …go: exit 8"; eq "$(wline)" "" "[$T] …no live window to read"
  window --lower owner-acts; pin unpin W2; eq "$RC" 0 "[$T] the owner unpins W2"
  nf; f=$F; eq "$(btc "$W" go kit:plugin-export "$f" x)" 8 "[$T] …go: exit 8"
  pin add --kind window --text "short" --owner-quote q --where w --expires "$(at 3)" --lower owner-acts; sleep 4
  nf; f=$F; eq "$(btc "$W" go kit:plugin-export "$f" x)" 8 "[$T] a window past its expiry: exit 8"
  has "$(wline)" "W3 is not in force now (pinned " "[$T] …named"
  world; window --lower owner-acts; owner_mode manual
  nf; f=$F; eq "$(btc "$W" go kit:plugin-export "$f" x)" 8 "[$T] mode manual: exit 8"; eq "$(wline)" "" "[$T] …no window read"
  owner_mode auto; BT_ENV+=(VIBEMAESTRO_ROLE=worker)
  nf; f=$F; eq "$(btc "$W" go kit:plugin-export "$f" x)" 8 "[$T] a worker session: exit 8"; eq "$(wline)" "" "[$T] …no window read"
  BT_ENV=(MERGE_GUARD_RETRY_WAIT_S=0)
  # closed between the signature and the run
  nf; f=$F; bt "$W" rehearse kit:plugin-export "$f" x >/dev/null; seal=$(sed -n 's/^seal \([^ ]*\) .*/\1/p' "$BT_OUT")
  eq "$(bt "$W" sign --by coordinator-auto --seal "${seal:-none}" kit:plugin-export "$f" x)" 0 "[$T] sign --by coordinator-auto under W1: rc 0"
  has "$(out)" "by coordinator-auto@W1 (mode auto)" "[$T] …the sign line names the window"
  bw op close W1 --reason stop
  eq "$(btc "$W" run kit:plugin-export "$f" x)" 3 "[$T] W1 closed before the run: run refused, rc 3"
  has "$(out)" "window W1, which it was signed under, does not cover it now" "[$T] …named"
  eq "$(created "$f")/$(ls "$(bdir)/signatures" | grep -c .)" "absent/1" "[$T] …nothing ran, the signature kept unused"
  # a broken brain chain
  world; window --lower owner-acts
  printf '{"seq": 99}\n' >> "$(bpy_w 'print(s.state_dir())')/hot.jsonl"   # a line appended by hand: the test's input, not a break
  nf; f=$F; eq "$(btc "$W" go kit:plugin-export "$f" x)" 8 "[$T] the brain's chain broken: exit 8"; eq "$(wline)" "" "[$T] …no window read"
}

fam_clock() {  # [clock] what the window's times allow
  local T=clock f
  world; window --lower owner-acts
  printf '%s\tnote\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\t-\n' "$(at 7200)" >> "$(bdir)/log.tsv"   # a line from a later clock: an input, not a break
  nf; f=$F; eq "$(btc "$W" go kit:plugin-export "$f" x)" 8 "[$T] the clock is behind the newest log line: exit 8"
  eq "$(wline)" "this clock is behind the newest line the brain or baton wrote: no window is read" "[$T] …named"
  nf; eq "$(bt "$W" go kit:plain-note "$F" x)" 0 "[$T] an ordinary Stops: none run writes later lines at the clock behind"
  nf; f=$F; eq "$(btc "$W" go kit:plugin-export "$f" x)" 8 "[$T] …the newest line still counts, not the last one: exit 8"
  eq "$(wline)" "this clock is behind the newest line the brain or baton wrote: no window is read" "[$T] …named"
  eq "$( (cd "$W" && cenv XDG_STATE_HOME="$ST" python3 -c 'import sys, time; sys.path.insert(0, sys.argv[1]); import baton as b
t = lambda n: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + n))
w = lambda **k: dict({"id": "W1", "status": "live", "lowers": ["owner-acts"], "session": "s", "created": t(-60), "expires": t(3600)}, **k)
for x in (w(), w(created=t(600), expires=t(3600)), w(created=t(-60), expires=t(86400)), w(import_={}), w(session="s2"), w(lowers=[]),
          w(expires=t(-1)), w(excludes=["owner-acts"]), w(lowers=["kit:x"])):
    x = {("import" if k == "import_" else k): v for k, v in x.items()}
    print(b.window_miss(x, "s", "kit:plugin-export", ["owner-acts"], time.time()))' "$S/scripts") | sed 's/(pinned .*)/(pinned …)/')" \
"None
W1 is not in force now (pinned …)
W1 has no readable time, or lasts more than 24 hours
W1 is not a live window pinned here
W1 was pinned by another session
W1 lowers no signing (it has no scope)
W1 is not in force now (pinned …)
W1 excludes owner-acts
W1 does not lower owner-acts" \
     "[$T] window_miss: covers; from the future, over 24 hours, imported, another session, no scope, expired, excluded, not lowered: each named"
}

fam_same() {  # [same] with no scope, or no brain, go's card is the one with no window at all
  local T=same f a b
  world; pin add --kind window --text "docs only" --owner-quote q --where w --expires "$(at 3600)"; eq "$RC" 0 "[$T] a window with no scope"
  nf; f=$F; eq "$(btc "$W" go kit:plugin-export "$f" x)" 8 "[$T] …go: exit 8"; a=$(sed '/^detail: /d' "$BT_OUT")
  reg; eq "$(btc "$W" go kit:plugin-export "$f" x)" 8 "[$T] no brain installed: exit 8"; b=$(sed '/^detail: /d' "$BT_OUT")
  eq "$a" "$b" "[$T] …the two exit-8 outputs are the same, word for word (the detail path aside)"
  hasnt "$a" "window" "[$T] …and neither mentions a window"
}

fam_forge() {  # [forge] a cache the brain keeps beside its log is no window: the runner's read folds the verified log
  local T=forge f
  world; pin add --kind window --text "docs only" --owner-quote q --where w --expires "$(at 3600)"; eq "$RC" 0 "[$T] a window with no scope"
  bpy_w 'import json, os
p = os.path.join(s.state_dir(), "hot.json"); c = json.load(open(p))
c["state"]["items"]["W1"].update(lowers=["owner-acts"], session=sys.argv[2]); c["digest"] = s.digest(s.dumps(c["state"]))
json.dump(c, open(p, "w"))' "$SID"   # hot.json rewritten with its digest: the test's input, not a break
  bw windows --json; eq "$(printf '%s' "$OUT" | python3 -c 'import json, sys; print([w.get("lowers") for w in json.loads(sys.stdin.read())["windows"]])')" \
     "[None]" "[$T] brain windows reads W1 from the log: no scope"
  nf; f=$F; eq "$(btc "$W" go kit:plugin-export "$f" x)" 8 "[$T] go: exit 8, nothing lowered"; eq "$(created "$f")" absent "[$T] …nothing ran"
}

fam_lists() {  # [lists] the brain's copy of the window's lists: it refuses before its dialog what baton never lowers
  eq "$(python3 -c 'import sys; sys.path[:0] = [sys.argv[1] + "/scripts", sys.argv[2] + "/scripts"]
import brain_store as s, baton as b
print(s.WINDOW_NEVER == b.WINDOW_NEVER, s.WINDOW_NEVER_BATONS == b.WINDOW_NEVER_BATONS, s.WINDOW_LIFE_MAX == b.WINDOW_LIFE_MAX,
      set(s.WINDOW_LOWERS) | set(s.WINDOW_NEVER) == set(b.STOP_WORDS), not set(s.WINDOW_LOWERS) & set(s.WINDOW_NEVER),
      all("kit:" + o in b.WINDOW_NEVER_BATONS for o, n in b.KIT_ALIASES.items() if "kit:" + n in b.WINDOW_NEVER_BATONS))' "$BROOT" "$PLUGIN")" \
    "True True True True True True" "[lists] the brain's window lists are the runner's, every stop word is lowerable or never, an old kit name too"
}

for f in fam_lists fam_forge fam_replay fam_trace fam_session fam_floor fam_floor_merge fam_named fam_ended fam_clock fam_same; do echo "== $f"; "$f"; done
eq "$(tree_hash "$SRC_ROOT")" "$H0" "the checkout is untouched"
echo; summary
