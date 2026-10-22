#!/bin/bash
# =============================================================================
# vibemaestro-brain: `brain owner` writes only with a fresh, matching, unused "asked" record (CLI cases, hook cases)
# =============================================================================
# Run: bash tests/test-brain-owner.sh
#
# The CLI cases write records through the store library, as guard-owner does; the hook cases run guard-owner itself
# (scripts/brain_hook.py) with fabricated hook JSON.
#   [N] no record: rc 6 with the sentence
#   [M] a record that does not match: other arguments, older than 10 minutes or from the future, another session's, a
#       non-dialog mode: rc 6
#   [U] a used record: the same call again is rc 6, and a spent record file put back is still rc 6 (the log knows its id)
#   [V] a newer record voids the session's earlier unused ones
#   [O] a fresh matching record: written and pinned, the log line carries confirm {asked, mode, record}, the record is spent;
#       acceptEdits and auto are dialog modes
#   [K] unpin, supersede (anchors carried over, no length rule) and promote (archived with its pointer); a window needs a
#       future --expires; owner retirements count in the budget and are never refused by it
#   [C] control characters in the text, the quote or --where: refused
#   [P] a PermissionRequest hook in settings or an enabled plugin, or an ancestor started with --permission-prompt-tool:
#       refused, and doctor names it
#   [W] a sandbox worker: rc 4; a session that is not the writer: rc 3
#   [R] round 1: the answerer check reads every worktree of the repo, the default and the overridden config directory, and a
#       parent's --settings (both forms, relative paths), --plugin-dir and a manifest's hooks path; the owner argv grammar is
#       strict (no abbreviation, no --opt=value, no repeated single option), so the dialog and the item cannot differ
#   [Y] round 2: the suite sees only the processes its cases start (no ancestor outside the scratch tree, no inherited config
#       dir); the answerer check reads ~/.claude of the account (password database) when HOME is emptied or moved, and a
#       relative CLAUDE_CONFIG_DIR; doctor shows a plugin name with an escape escaped; the grammar alone refuses an
#       abbreviation; an owner value may start with `-`
#   [Z3] round 3: an ancestor's HOME is read (a call under another HOME sees the parent's ~/.claude); a newline in a plugin
#       name cannot forge a doctor line
#   [H] guard-owner asks in default, acceptEdits and auto (2.1.211 or later, read from the running binary) with the dialog
#       line and a record of its mode, in a project with no brain state too, and the CLI then writes; auto below
#       2.1.211 or on an unknown version is denied
#   [D] dontAsk, plan, bypassPermissions and a missing mode: deny with the sentence, no record, logged with the mode;
#       a subagent: deny; a command that is not owner-shaped, BRAIN_OFF, a sandbox worker: silent
#   [V] a second owner-shaped call voids the earlier record: a direct brain.py call is asked again, and a call the hook
#       cannot read literally leaves no record a denied dialog could have left
#   [L] the dialog lines of add (decision, window), unpin, supersede and promote; Vietnamese byte for byte; ≤ 283
#   [T] arguments read literally, the command alone, or denied: substitution, glob, redirect, two owner commands, an open
#       quote, an escaped $ in double quotes, a backslash, ~ after =, a carriage return, a leading cd; --help is one deny
#   [Q] round 1: a record serves only the call it was asked for: the session's next Bash call of any shape (an eval, a
#       plain ls) voids it, another session's does not, the approved call itself writes, session-end drops the marker; round
#       2: session-end from another directory voids the record its marker names; a marker over 10 minutes old is swept
#   [A] a programmatic answerer: deny before any dialog
#   [S] the BRAIN_TEST switch (BRAIN_TEST_ASK_MODES): asks in plan and bypassPermissions only, the record keeps the real
#       mode, and the CLI refuses it; in every mode the CLI answers the same with and without the switch
#   [X] planted breaks: each case goes red on a copy with one break
# =============================================================================
set -uo pipefail
# the answerer check reads ancestors' CLAUDE_CONFIG_DIR and HOME from their initial environment, which forked subshells share:
# start again without the launcher's (clean_env then points HOME into the scratch tree; the user base is pinned first)
if [ -z "${BRAIN_SUITE_REEXEC:-}" ]; then
  export PYTHONUSERBASE="${PYTHONUSERBASE:-$(python3 -m site --user-base 2>/dev/null)}"
  exec env -u CLAUDE_CONFIG_DIR BRAIN_SUITE_REEXEC=1 HOME=/nonexistent bash "$0" "$@"
fi
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
# shellcheck source=fixtures/brain.sh
. "$HERE/fixtures/brain.sh"
brain_kit "$SRC_ROOT"

ADD=(add --kind decision --text "Owner merges every PR that touches clusters/" --owner-quote "PR chạm clusters/ thì anh merge" --where "prompt 10-18 09:11" --anchor "clusters/")
SENTENCE="permission dialog"
PRH='{"hooks":{"PermissionRequest":[{"hooks":[{"type":"command","command":"true"}]}]}}'
# config file names, kept out of path-shaped text: tests/plan.py reads a manifest path written out as every plugin's manifest
SET=settings.json; MAN=plugin.json

rec_at() {  # rec_at <seconds from now> <mode> <session> <args…> — a record with a chosen time
  local dt=$1 mode=$2 ses=$3; shift 3
  CLAUDE_CODE_SESSION_ID="$SID" python3 -c 'import sys, time; sys.path.insert(0, sys.argv[1]); import brain_store as s
s.record_asked(s.state_dir(), sys.argv[3], sys.argv[2], sys.argv[5:], t=time.time() + float(sys.argv[4]))' "$BROOT/scripts" "$mode" "$ses" "$dt" "$@"
}
nrec() { local d; d="$(sdir)/asked"; [ -d "$d" ] && find "$d" -name '*.json' | wc -l | tr -d ' ' || echo 0; }
items() { bpy 'st = s.fold(s.verify(s.state_dir())[1])["items"]; print(" ".join("%s:%s" % (k, v["status"]) for k, v in sorted(st.items())) or "none")'; }

case_norecord() {
  newp
  br owner "${ADD[@]}"; c_rc 6 "[N] no record: rc 6"
  c_has "$OUT" "$SENTENCE" "[N] the refusal says why"
  br claim; R=$(items); c_eq "$R" "none" "[N] nothing was written"
}

case_mismatch() {
  newp
  rec default sA add --kind decision --text "another decision" --owner-quote q --where w
  br owner "${ADD[@]}"; c_rc 6 "[M] a record for other arguments: rc 6"
  rec default sA "${ADD[@]}" --anchor extra
  br owner "${ADD[@]}"; c_rc 6 "[M] a record with one more argument: rc 6"
  rec_at -601 default sA "${ADD[@]}"
  br owner "${ADD[@]}"; c_rc 6 "[M] a record 601 seconds old: rc 6"
  rec_at 120 default sA "${ADD[@]}"
  br owner "${ADD[@]}"; c_rc 6 "[M] a record dated 2 minutes ahead: rc 6"
  rec default sB "${ADD[@]}"
  br owner "${ADD[@]}"; c_rc 6 "[M] another session's record: rc 6"
  for m in dontAsk bypassPermissions plan nonsense; do
    rec $m sA "${ADD[@]}"; br owner "${ADD[@]}"; c_rc 6 "[M] a record of mode $m: rc 6"; done
  rec_at -590 default sA "${ADD[@]}"
  br owner "${ADD[@]}"; c_rc 0 "[M] instrument: the same record 590 seconds old is accepted"
}

case_used() {
  newp
  local d keep
  rec default sA "${ADD[@]}"
  d="$(sdir)/asked"; keep="$TMP/kept$NP"; mkdir -p "$keep"; cp "$d"/*.json "$keep/"
  br owner "${ADD[@]}"; c_rc 0 "[U] instrument: the first call writes"
  c_eq "$(nrec)" 0 "[U] the record is spent (its file is gone)"
  br owner "${ADD[@]}"; c_rc 6 "[U] the same call again: rc 6"
  cp "$keep"/*.json "$d/"
  br owner "${ADD[@]}"; c_rc 6 "[U] the spent record file put back: rc 6 (the log holds its id)"
  R=$(items); c_eq "$R" "D1:live" "[U] one decision only"
}

case_void() {
  newp
  local other=(add --kind decision --text "Another decision" --owner-quote q --where w)
  rec default sA "${ADD[@]}"
  rec default sA "${other[@]}"
  c_eq "$(nrec)" 1 "[V] a second record voids the first"
  br owner "${ADD[@]}"; c_rc 6 "[V] the voided record cannot serve its call"
  br owner "${other[@]}"; c_rc 0 "[V] the newer record serves its own call"
  rec default sB "${ADD[@]}"; rec default sA "${ADD[@]}"
  c_eq "$(nrec)" 2 "[V] voiding stays within the session"
}

case_fresh() {
  newp
  rec default sA "${ADD[@]}"
  br owner "${ADD[@]}"; c_rc 0 "[O] a fresh matching record: rc 0"
  c_has "$OUT" "D1" "[O] it prints the new id"
  R=$(bpy 'import json, os
l = json.loads(open(os.path.join(s.state_dir(), "hot.jsonl")).read().splitlines()[-1])
i = l["item"]; c = l["confirm"]
print(l["op"], i["id"], i["pinned"], i["source"]["type"], i["source"]["quote"], c["asked"], c["mode"], len(c["record"]))')
  c_eq "$R" "owner-add D1 True owner PR chạm clusters/ thì anh merge True default 32" "[O] the log line: owner-add, pinned, the quote verbatim, confirm with mode and record id"
  br render
  c_has "$(printf '%s\n' "$OUT" | sed -n '/^Pinned/,/^Windows/p')" "D1 Owner merges every PR that touches clusters/" "[O] the render shows D1 under Pinned"
  for m in acceptEdits auto; do
    local a=(add --kind decision --text "decision in $m" --owner-quote q --where w)
    rec $m sA "${a[@]}"; br owner "${a[@]}"; c_rc 0 "[O] mode $m is a dialog mode"; done
}

case_verbs() {
  newp
  owner_ok "${ADD[@]}"
  owner_ok supersede D1 --text "The owner merges clusters/ PRs"; c_rc 0 "[K] owner supersede rc 0, shorter than 60% too"
  R=$(bpy 'st = s.fold(s.verify(s.state_dir())[1])["items"]; print(st["D1"]["status"], st["D2"]["status"], st["D2"]["pinned"], ",".join(st["D2"]["anchors"]), st["D2"]["supersedes"])')
  c_eq "$R" "superseded live True clusters/ D1" "[K] D2 replaces D1, pinned, the anchor carried over"
  owner_ok promote D2 "kb/decisions/2026-10-18-clusters-merge.md"; c_rc 0 "[K] owner promote rc 0"
  R=$(bpy 'st = s.fold(s.verify(s.state_dir())[1])["items"]["D2"]; print(st["status"], st["pointer"])')
  c_eq "$R" "archived kb/decisions/2026-10-18-clusters-merge.md" "[K] the promoted item is archived with its pointer"
  owner_ok add --kind window --text "May merge docs-only PRs" --owner-quote "docs PR thì cứ merge" --where "prompt 1"
  c_rc 1 "[K] a window without --expires: refused"
  owner_ok add --kind window --text "May merge docs-only PRs" --owner-quote q --where w --expires 2001-01-01T00:00:00Z
  c_rc 1 "[K] a window that has already expired: refused"
  owner_ok add --kind window --text "May merge docs-only PRs" --owner-quote q --where w --expires 2099-01-01T00:00:00Z
  c_rc 0 "[K] a window with a future --expires: rc 0"
  owner_ok unpin W1; c_rc 0 "[K] owner unpin W1 rc 0"
  R=$(items); c_has "$R" "W1:closed" "[K] the unpinned window is closed"
  br op add --kind now --text "n"; owner_ok unpin N1; c_rc 1 "[K] owner unpin of a Now item: refused"
  owner_ok unpin D9; c_rc 1 "[K] owner unpin of an unknown id: refused"
}

case_owner_budget() {
  newp
  local k id
  owner_ok "${ADD[@]}"
  for k in now now now next next; do br op add --kind $k --text "item $k"; done
  for id in N1 N2 N3 X1; do br op close $id --reason done; done
  owner_ok supersede D1 --text "Owner merges clusters/ PRs, always"; c_rc 0 "[K] the fifth retirement (an owner supersede): rc 0"
  owner_ok unpin D2; c_rc 0 "[K] the sixth retirement (an owner unpin): never refused by the budget"
  br op close X2 --reason done; c_rc 1 "[K] the owner retirements counted: the next op close is refused"
}

case_chars() {
  newp
  local esc; esc=$(printf 'x\033[2Jy')
  owner_ok add --kind decision --text "bad $esc" --owner-quote q --where w; c_rc 1 "[C] an ESC in the text: refused"
  owner_ok add --kind decision --text "good" --owner-quote q --where "$esc"; c_rc 1 "[C] an ESC in --where: refused"
  owner_ok add --kind decision --text "good" --owner-quote "$(printf 'a\342\200\256b')" --where w; c_rc 1 "[C] a bidi override in the quote: refused"
  owner_ok add --kind decision --text "good" --owner-quote q --where "$(python3 -c 'print("w" * 61)')"; c_rc 1 "[C] --where over 60 characters: refused"
  R=$(items 2>/dev/null); c_eq "$R" "none" "[C] nothing was written"
}

case_answerer() {
  newp
  export CLAUDE_CONFIG_DIR="$TMP/cfg$NP"; mkdir -p "$CLAUDE_CONFIG_DIR"
  printf '{"hooks":{"PermissionRequest":[{"hooks":[{"type":"command","command":"true"}]}]}}' > "$CLAUDE_CONFIG_DIR/settings.json"
  owner_ok "${ADD[@]}"; c_rc 6 "[P] a PermissionRequest hook in the user settings: rc 6"
  c_has "$OUT" "PermissionRequest" "[P] the refusal names the hook"
  br doctor; c_rc 1 "[P] doctor rc 1"; c_has "$OUT" "PermissionRequest" "[P] doctor names it"
  rm "$CLAUDE_CONFIG_DIR/settings.json"
  mkdir -p .claude; printf '{"hooks":{"PermissionRequest":[]}}' > .claude/settings.local.json
  owner_ok "${ADD[@]}"; c_rc 0 "[P] an empty PermissionRequest list: not an answerer"
  printf '{"hooks":{"PermissionRequest":[{"hooks":[{"type":"command","command":"true"}]}]}}' > .claude/settings.local.json
  owner_ok add --kind decision --text "second" --owner-quote q --where w; c_rc 6 "[P] one in the project's local settings: rc 6"
  rm .claude/settings.local.json
  printf '{"hooks":{"PermissionRequest":[{"hooks":[{"type":"command","command":"true"}]}]}}' > "$MANAGED/managed-settings.json"
  owner_ok add --kind decision --text "second" --owner-quote q --where w; c_rc 6 "[P] one in the managed settings: rc 6"
  rm "$MANAGED/managed-settings.json"
  mkdir -p "$TMP/pl$NP/hooks"; printf '{"hooks":{"PermissionRequest":[{"hooks":[{"type":"command","command":"true"}]}]}}' > "$TMP/pl$NP/hooks/hooks.json"
  printf '{"version":2,"plugins":{"answer@m":[{"scope":"user","installPath":"%s"}]}}' "$TMP/pl$NP" > "$CLAUDE_CONFIG_DIR/plugins.json"
  mkdir -p "$CLAUDE_CONFIG_DIR/plugins"; mv "$CLAUDE_CONFIG_DIR/plugins.json" "$CLAUDE_CONFIG_DIR/plugins/installed_plugins.json"
  printf '{"enabledPlugins":{"answer@m":true}}' > "$CLAUDE_CONFIG_DIR/settings.json"
  owner_ok add --kind decision --text "third" --owner-quote q --where w; c_rc 6 "[P] an enabled plugin with a PermissionRequest hook: rc 6"
  printf '{"enabledPlugins":{"answer@m":false}}' > "$CLAUDE_CONFIG_DIR/settings.json"
  owner_ok add --kind decision --text "third" --owner-quote q --where w; c_rc 0 "[P] the same plugin disabled: rc 0"
  local a=(add --kind decision --text "fourth" --owner-quote q --where w)
  rec default sA "${a[@]}"
  OUT=$(CLAUDE_CODE_SESSION_ID=sA bash -c '"$0" owner "$@"; exit $?' "$BROOT/bin/brain" "${a[@]}" 2>&1); RC=$?
  c_rc 0 "[P] instrument: through a bash parent, the call writes"
  rec default sA "${a[@]}"
  OUT=$(CLAUDE_CODE_SESSION_ID=sA bash -c '"$1" owner "${@:2}"; exit $?' --permission-prompt-tool "$BROOT/bin/brain" "${a[@]}" 2>&1); RC=$?
  c_rc 6 "[P] an ancestor started with --permission-prompt-tool: rc 6"
  rec default sA "${a[@]}"
  OUT=$(CLAUDE_CODE_SESSION_ID=sA bash -c '"$1" owner "${@:2}"; exit $?' "note: --permission-prompt-tool in a prompt" "$BROOT/bin/brain" "${a[@]}" 2>&1); RC=$?
  c_rc 0 "[P] the flag inside a longer argument is not an answerer"
  unset CLAUDE_CONFIG_DIR
}

case_worker() {
  newp
  owner_ok "${ADD[@]}"
  local a=(add --kind decision --text "second" --owner-quote q --where w)
  rec default sA "${a[@]}"
  OUT=$(INTENT_SLUG=x SEAT=y CLAUDE_CODE_SESSION_ID=sA "$BROOT/bin/brain" owner "${a[@]}" 2>&1); RC=$?
  c_rc 4 "[W] a sandbox worker: rc 4"
  SID=sB; rec default sB "${a[@]}"; br owner "${a[@]}"; c_rc 3 "[W] a session that is not the writer: rc 3"
}

case_answerer2() {
  newp
  local wt="$TMP/wt$NP" cfg="$TMP/cfg$NP" a=(add --kind decision --text "from elsewhere" --owner-quote q --where w)
  git_ -C "$P" commit -q --allow-empty -m c1; git_ -C "$P" worktree add -q --detach "$wt"
  mkdir -p .claude; printf '%s' "$PRH" > .claude/settings.local.json
  rec default sA "${a[@]}"; br owner "${a[@]}"; c_rc 6 "[R] instrument: the hook in the main checkout's local settings: rc 6"
  mkdir -p "$TMP/else$NP"; cd "$TMP/else$NP" || return   # no ancestor stands in the main checkout for the next two
  (cd "$wt" && rec default sA "${a[@]}" && br owner "${a[@]}" && echo "$RC" > "$TMP/r$NP"); c_eq "$(cat "$TMP/r$NP")" 6 "[R] the same call from a worktree of the repo: rc 6"
  (export GIT_DIR="$P/.git" && rec default sA "${a[@]}" && br owner "${a[@]}" && echo "$RC" > "$TMP/r$NP"); c_eq "$(cat "$TMP/r$NP")" 6 "[R] with GIT_DIR from another directory: rc 6"
  cd "$P" || return
  rm .claude/settings.local.json
  mkdir -p "$HOME/.claude"; printf '%s' "$PRH" > "$HOME/.claude/$SET"
  mkdir -p "$cfg"; export CLAUDE_CONFIG_DIR="$cfg"
  rec default sA "${a[@]}"; br owner "${a[@]}"; c_rc 6 "[R] the hook in ~/.claude while CLAUDE_CONFIG_DIR points elsewhere: rc 6"
  unset CLAUDE_CONFIG_DIR; rm "$HOME/.claude/$SET"
  rec default sA "${a[@]}"
  OUT=$(CLAUDE_CODE_SESSION_ID=sA bash -c '"$2" owner "${@:3}"; exit $?' "--settings=$PRH" x "$BROOT/bin/brain" "${a[@]}" 2>&1); RC=$?
  c_rc 6 "[R] a parent with --settings=<json>: rc 6"
  mkdir -p "$TMP/par$NP"; printf '%s' "$PRH" > "$TMP/par$NP/s.json"; rec default sA "${a[@]}"
  OUT=$(cd "$TMP/par$NP" && CLAUDE_CODE_SESSION_ID=sA bash -c '(cd "$2" && "$3" owner "${@:4}"); exit $?' --settings s.json "$P" "$BROOT/bin/brain" "${a[@]}" 2>&1); RC=$?
  c_rc 6 "[R] a parent with --settings <relative path from its own cwd>: rc 6"
  mkdir -p "$TMP/pd$NP/hooks"; printf '%s' "$PRH" > "$TMP/pd$NP/hooks/hooks.json"; rec default sA "${a[@]}"
  OUT=$(CLAUDE_CODE_SESSION_ID=sA bash -c '"$2" owner "${@:3}"; exit $?' --plugin-dir "$TMP/pd$NP" "$BROOT/bin/brain" "${a[@]}" 2>&1); RC=$?
  c_rc 6 "[R] a parent with --plugin-dir <a plugin with the hook>: rc 6"
  export CLAUDE_CONFIG_DIR="$cfg"; mkdir -p "$TMP/mp$NP/.claude-plugin" "$TMP/mp$NP/cfg" "$cfg/plugins"
  printf '%s' "$PRH" > "$TMP/mp$NP/cfg/h.json"; printf '{"name":"mp","hooks":"./cfg/h.json"}' > "$TMP/mp$NP/.claude-plugin/$MAN"
  printf '{"version":2,"plugins":{"mp@m":[{"scope":"user","installPath":"%s"}]}}' "$TMP/mp$NP" > "$cfg/plugins/installed_plugins.json"
  printf '{"enabledPlugins":{"mp@m":true}}' > "$cfg/settings.json"
  rec default sA "${a[@]}"; br owner "${a[@]}"; c_rc 6 "[R] an enabled plugin whose manifest names a hooks file: rc 6"
  unset CLAUDE_CONFIG_DIR
  rec default sA "${a[@]}"; br owner "${a[@]}"; c_rc 0 "[R] instrument: with none of them, the call writes"
}

case_grammar() {
  newp
  local d=(add --kind decision --text "Shown first" --owner-quote q --where w --text "Actually written")
  rec default sA "${d[@]}"; br owner "${d[@]}"; c_rc 64 "[R] a repeated --text: rc 64"
  local ab=(add --k decision --te "abbrev" --own q --wh w)
  rec default sA "${ab[@]}"; br owner "${ab[@]}"; c_rc 64 "[R] abbreviated options: rc 64"
  local eqf=(add --kind=decision --text=eqform --owner-quote=q --where=w)
  rec default sA "${eqf[@]}"; br owner "${eqf[@]}"; c_rc 64 "[R] --opt=value: rc 64"
  local an=(add --kind decision --text "two anchors" --owner-quote q --where w --anchor a1 --anchor a2)
  rec default sA "${an[@]}"; br owner "${an[@]}"; c_rc 0 "[R] instrument: a repeated --anchor is allowed"
  R=$(items); c_eq "$R" "D1:live" "[R] only the well-formed call wrote"
}

case_isolation() {
  newp
  cat > "$TMP/anc.py" <<'PY'
import os, sys
sys.path.insert(0, sys.argv[1])
import brain_store as s
a = s._ancestors()
scratch = os.environ["FIXTURE_SCRATCH"]
print([c for _, c, _, _ in a if c and not c.startswith(scratch)], [g for _, _, g, _ in a if g],
      [h for *_, h in a if h and not h.startswith(scratch) and h != "/nonexistent"], len(a) > 0)
PY
  R=$(bash -c 'python3 "$0" "$1"; exit $?' "$TMP/anc.py" "$BROOT/scripts")   # a bash between: the case's own ancestor
  c_eq "$R" "[] [] [] True" "[Y] the ancestors a case sees: no cwd or HOME outside the scratch tree, no config dir (and at least one)"
}

case_homes() {
  newp
  local a=(add --kind decision --text "home" --owner-quote q --where w)
  mkdir -p "$ACCOUNT/.claude"; printf '%s' "$PRH" > "$ACCOUNT/.claude/$SET"
  rec default sA "${a[@]}"
  OUT=$(HOME="" CLAUDE_CODE_SESSION_ID=sA "$BROOT/bin/brain" owner "${a[@]}" 2>&1); RC=$?
  c_rc 6 "[Y] the hook in the account's ~/.claude with HOME emptied: rc 6"
  rec default sA "${a[@]}"
  OUT=$(HOME="$TMP/elsewhere" CLAUDE_CODE_SESSION_ID=sA "$BROOT/bin/brain" owner "${a[@]}" 2>&1); RC=$?
  c_rc 6 "[Y] the same with HOME pointed elsewhere: rc 6"
  rm "$ACCOUNT/.claude/$SET"
  mkdir -p rel; printf '%s' "$PRH" > "rel/$SET"
  rec default sA "${a[@]}"
  OUT=$(CLAUDE_CONFIG_DIR=rel CLAUDE_CODE_SESSION_ID=sA "$BROOT/bin/brain" owner "${a[@]}" 2>&1); RC=$?
  c_rc 6 "[Y] the hook under a relative CLAUDE_CONFIG_DIR: rc 6"
  rm "rel/$SET"
  rec default sA "${a[@]}"
  OUT=$(CLAUDE_CONFIG_DIR=rel HOME="" CLAUDE_CODE_SESSION_ID=sA "$BROOT/bin/brain" owner "${a[@]}" 2>&1); RC=$?
  c_rc 0 "[Y] instrument: with neither, the same call writes"
}

case_rawname() {
  newp
  local cfg="$TMP/cfg$NP"; mkdir -p "$cfg/plugins" "$TMP/pe$NP/hooks"
  printf '%s' "$PRH" > "$TMP/pe$NP/hooks/hooks.json"
  printf '%s' '{"version":2,"plugins":{"ans\u001b[2Jwer@m":[{"scope":"user","installPath":"'"$TMP/pe$NP"'"}]}}' > "$cfg/plugins/installed_plugins.json"
  printf '%s' '{"enabledPlugins":{"ans\u001b[2Jwer@m":true}}' > "$cfg/$SET"
  OUT=$(CLAUDE_CONFIG_DIR="$cfg" CLAUDE_CODE_SESSION_ID=sA "$BROOT/bin/brain" doctor 2>&1); RC=$?
  c_has "$OUT" 'enabled plugin ans\u001b[2Jwer' "[Y] doctor names the plugin, its escape shown escaped"
  c_hasnt "$OUT" "$(printf '\033')" "[Y] no raw escape reaches the terminal"
}

case_grammar2() {
  newp
  R=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import brain as b, brain_store as s
try:
    b.owner_grammar(["add", "--k", "decision", "--te", "x"]); print("passed")
except s.Refused as e:
    print(e.rc)' "$BROOT/scripts")
  c_eq "$R" 64 "[Y] the owner grammar alone refuses an abbreviation (argparse refuses it too: two layers)"
  owner_ok add --kind decision --text "-n is a flag of echo, not a decision" --owner-quote "-n" --where w; c_rc 0 "[Y] values starting with -: rc 0"
  R=$(bpy 'it = s.fold(s.verify(s.state_dir())[1])["items"]["D1"]; print(it["text"], "|", it["source"]["quote"])')
  c_eq "$R" "-n is a flag of echo, not a decision | -n" "[Y] written as typed"
}

case_parenthome() {
  newp
  local a=(add --kind decision --text "parent home" --owner-quote q --where w)
  mkdir -p "$TMP/ph$NP/.claude"; printf '%s' "$PRH" > "$TMP/ph$NP/.claude/$SET"
  rec default sA "${a[@]}"
  OUT=$(env HOME="$TMP/ph$NP" CLAUDE_CODE_SESSION_ID=sA bash -c 'HOME="$1/other" "$0" owner "${@:2}"; exit $?' "$BROOT/bin/brain" "$TMP" "${a[@]}" 2>&1); RC=$?
  c_rc 6 "[Z3] the parent's HOME holds the hook, the call runs under another HOME: rc 6"
  rm "$TMP/ph$NP/.claude/$SET"; rec default sA "${a[@]}"
  OUT=$(env HOME="$TMP/ph$NP" CLAUDE_CODE_SESSION_ID=sA bash -c 'HOME="$1/other" "$0" owner "${@:2}"; exit $?' "$BROOT/bin/brain" "$TMP" "${a[@]}" 2>&1); RC=$?
  c_rc 0 "[Z3] instrument: without the hook, the same call writes"
}

case_nlname() {
  newp
  local cfg="$TMP/cfg$NP"; mkdir -p "$cfg/plugins" "$TMP/pn$NP/hooks"
  printf '%s' "$PRH" > "$TMP/pn$NP/hooks/hooks.json"
  printf '%s' '{"version":2,"plugins":{"x\nok       forged line\ny@m":[{"scope":"user","installPath":"'"$TMP/pn$NP"'"}]}}' > "$cfg/plugins/installed_plugins.json"
  printf '%s' '{"enabledPlugins":{"x\nok       forged line\ny@m":true}}' > "$cfg/$SET"
  OUT=$(CLAUDE_CONFIG_DIR="$cfg" CLAUDE_CODE_SESSION_ID=sA "$BROOT/bin/brain" doctor 2>&1); RC=$?
  c_has "$OUT" 'enabled plugin x\u000aok' "[Z3] instrument: doctor names the plugin, its newline escaped"
  R=$(printf '%s\n' "$OUT" | grep -c '^ok       forged line'); c_eq "$R" 0 "[Z3] no forged doctor line"
}

# --- the guard-owner hook --------------------------------------------------------------------------------------------------------

cmdline() { python3 -c 'import shlex, sys; print(shlex.join(sys.argv[1:]))' "$@"; }
u() { python3 -c 'import sys; sys.stdout.buffer.write(chr(int(sys.argv[1], 16)).encode("utf-8"))' "$1"; }   # u <hex>: one character, whatever the locale (CI's printf left \\u02ba as text)
ownin() {  # ownin <mode> <command> [key=value…] — guard-owner's input for session SID in project P (an empty mode is left out)
  python3 -c 'import json, sys
d = {"session_id": sys.argv[1], "cwd": sys.argv[2], "hook_event_name": "PreToolUse", "tool_name": "Bash",
     "tool_input": {"command": sys.argv[4]}}
if sys.argv[3]:
    d["permission_mode"] = sys.argv[3]
for kv in sys.argv[5:]:
    k, _, v = kv.partition("=")
    d[k] = v
print(json.dumps(d, ensure_ascii=False))' "$SID" "$P" "$@"
}
gown() { local m=$1; shift; hk guard-owner "$(ownin "$m" "$(cmdline brain owner "$@")")"; }   # gown <mode> <args after owner…>
gcmd() { hk guard-owner "$(ownin "$@")"; }                                                       # gcmd <mode> <command> [k=v…]
recmode() { bpy 'import glob, json, os
print(" ".join(sorted(json.load(open(p))["mode"] for p in glob.glob(os.path.join(s.state_dir(), "asked", "*.json")))) or "none")'; }
recid() { bpy 'import glob, os
print(" ".join(sorted(os.path.basename(p) for p in glob.glob(os.path.join(s.state_dir(), "asked", "*.json")))) or "none")'; }
fakever() {  # fakever <version line> — a fake Claude Code binary printing it; prints its path
  local f; f=$(mktemp "$TMP/claude-$NP.XXXXXX"); printf '#!/bin/sh\necho "%s"\n' "$1" > "$f"; chmod +x "$f"; echo "$f"
}
LINE1='Pin owner decision D1, from "prompt 10-18 09:11": "Owner merges every PR that touches clusters/"'

case_hook_ask() {
  newp
  gown default "${ADD[@]}"
  c_eq "$(hfield permissionDecision)" ask "[H] default mode, a project with no brain state: ask (R1)"
  c_eq "$(hfield permissionDecisionReason)" "$LINE1" "[H] the dialog line, Vietnamese source kept byte for byte"
  c_eq "$(recmode)" default "[H] one record, with its mode"
  br owner "${ADD[@]}"; c_rc 0 "[H] the hook's record lets the CLI write: hook and CLI agree end to end"
  local a=(add --kind decision --text "decision in acceptEdits" --owner-quote q --where w)
  gown acceptEdits "${a[@]}"; c_eq "$(hfield permissionDecision)" ask "[H] acceptEdits: ask"
  c_eq "$(recmode)" acceptEdits "[H] the record keeps acceptEdits"
  br owner "${a[@]}"; c_rc 0 "[H] acceptEdits: written"
  a=(add --kind decision --text "decision in auto" --owner-quote q --where w)
  CLAUDE_CODE_EXECPATH=$(fakever "2.1.211 (Claude Code)") gown auto "${a[@]}"
  c_eq "$(hfield permissionDecision)" ask "[H] auto on 2.1.211 (the running binary, CLAUDE_CODE_EXECPATH): ask"
  br owner "${a[@]}"; c_rc 0 "[H] auto on 2.1.211: written"
  CLAUDE_CODE_EXECPATH=$(fakever "2.1.210 (Claude Code)") gown auto "${a[@]}"
  c_eq "$(hfield permissionDecision)" deny "[H] auto on 2.1.210: deny (R4)"
  c_has "$(hfield permissionDecisionReason)" "$SENTENCE" "[H] with the refusal sentence"
  c_eq "$(recmode)" none "[H] and no record"
  CLAUDE_CODE_EXECPATH=$(fakever "no version here") gown auto "${a[@]}"
  c_eq "$(hfield permissionDecision)" deny "[H] auto on an unknown version: deny"
}

case_hook_deny() {
  newp
  local m
  for m in dontAsk plan bypassPermissions ""; do
    gown "$m" "${ADD[@]}"
    c_eq "$(hfield permissionDecision)" deny "[D] mode '${m:-missing}': deny"
    c_has "$(hfield permissionDecisionReason)" "$SENTENCE" "[D] mode '${m:-missing}': the refusal sentence reaches Claude (R3)"
    c_eq "$(recmode)" none "[D] mode '${m:-missing}': no record"
  done
  R=$(grep -c '"decision":"deny","kind":"owner-call","mode":"dontAsk"' "$(sdir)/episodes.jsonl"); c_eq "$R" 1 "[D] the refused call is in the Episode Log with its mode (R5)"
  gcmd default "$(cmdline brain owner "${ADD[@]}")" agent_id=sub1
  c_eq "$(hfield permissionDecision)" deny "[D] a subagent (agent_id): deny"
  c_eq "$(recmode)" none "[D] a subagent: no record"
  gcmd default "git status"; c_eq "$OUT" "" "[D] a Bash command that is not owner-shaped: silent"
  gcmd default "brain op add --kind now --text owner"; c_eq "$OUT" "" "[D] brain op with the word owner as a value: silent"
  gcmd default "brain op add --kind now --text owner add"; c_eq "$OUT" "" "[D] brain op … --text owner add: silent (owner counts only right after brain)"
  local w
  for w in "echo brain owner $(cmdline "${ADD[@]}")" "CLAUDE_CODE_SESSION_ID=zz brain owner $(cmdline "${ADD[@]}")"; do
    gcmd default "$w"; c_eq "$OUT" "" "[D] a leading word before brain (${w:0:30}…): not owner-shaped, no dialog for a command that writes nothing (round 2)"
  done
  gcmd default "python3 /opt/x/bin/brain owner $(cmdline "${ADD[@]}")"; c_eq "$OUT" "" "[D] python3 running the sh wrapper bin/brain: silent (round 3)"
  c_eq "$(recmode)" none "[D] and no record"
  BRAIN_OFF=1 gown default "${ADD[@]}"; c_eq "$OUT" "" "[D] BRAIN_OFF: silent"
  INTENT_SLUG=x SEAT=y gown default "${ADD[@]}"; c_eq "$OUT" "" "[D] a sandbox worker: silent"
}

case_hook_void() {
  newp
  gown default "${ADD[@]}"; local first; first=$(recid)
  gcmd default "python3 /opt/x/scripts/brain.py owner $(cmdline "${ADD[@]}")"
  c_eq "$(hfield permissionDecision)" ask "[V] after a denied ask, a direct brain.py call is asked again"
  c_eq "$(recmode)" default "[V] one record only"
  c_hasnt "$(recid)" "$first" "[V] the earlier record is void"
  local a=(add --kind decision --text "second decision" --owner-quote q --where w)
  gcmd default "true"                                            # clears the pending marker the last ask left
  rec default sA "${a[@]}"                                       # a record with no pending marker: only this voiding reaches it
  gcmd default 'brain owner add --kind decision --text "$X" --owner-quote q --where w'
  c_eq "$(hfield permissionDecision)" deny "[V] a call the hook cannot read literally: deny"
  c_eq "$(recmode)" none "[V] and it voids the session's earlier record"
  br owner "${a[@]}"; c_rc 6 "[V] so that record cannot serve its call (risk 5 narrowed)"
}

case_hook_line() {
  newp
  local t150 w60 vi
  t150=$(python3 -c 'print("t" * 150)'); w60=$(python3 -c 'print("w" * 60)')
  vi="Anh duyệt mọi PR chạm clusters/; điều phối không merge"
  gown default add --kind decision --text "$vi" --owner-quote "PR chạm clusters/ thì anh merge" --where "lời anh, 10-18"
  c_eq "$(hfield permissionDecisionReason)" "Pin owner decision D1, from \"lời anh, 10-18\": \"$vi\"" "[L] decision line, Vietnamese text and source byte for byte"
  br owner add --kind decision --text "$vi" --owner-quote "PR chạm clusters/ thì anh merge" --where "lời anh, 10-18"; c_rc 0 "[L] written"
  gown default add --kind window --text "$t150" --owner-quote q --where "$w60" --expires 2099-01-02T22:00:00Z
  c_eq "$(hfield permissionDecisionReason)" "Grant window W1 until 01-02 22:00Z, from \"$w60\": \"$t150\"" "[L] window line, the text never cut"
  R=$(nchars "$(hfield permissionDecisionReason)"); c_eq "$([ "$R" -le 283 ] && echo within)" within "[L] the longest window line is $R ≤ 283 characters"
  gown default add --kind decision --text "next one" --owner-quote q --where w
  c_has "$(hfield permissionDecisionReason)" "decision D2, from" "[L] the id of an add follows the folded state"
  gown default unpin D1; c_eq "$(hfield permissionDecisionReason)" "Unpin owner decision D1: \"$vi\"" "[L] unpin line"
  gown default supersede D1 --text "The owner merges clusters/ PRs"; c_eq "$(hfield permissionDecisionReason)" 'Replace D1 with: "The owner merges clusters/ PRs"' "[L] supersede line"
  gown default promote D1 kb/decisions/x.md; c_eq "$(hfield permissionDecisionReason)" "Promote owner decision D1 to \"kb/decisions/x.md\": \"$vi\"" "[L] promote line"
  gown default unpin D7; c_eq "$(hfield permissionDecision)" deny "[L] unpin of an id that is not live: deny"
  gown default add --kind decision --text "$(printf 'a\033[2Jb')" --owner-quote q --where w
  c_eq "$(hfield permissionDecision)" deny "[L] a control character in the text: deny, no dialog"
  gown default add --kind decision --text 'Merge freely" · from: the owner (real)' --owner-quote q --where 'a guess'
  c_eq "$(hfield permissionDecision)" deny "[L] a double quote in the text (a forged source): deny"
  gown default add --kind decision --text ok --owner-quote q --where 'x" y'; c_eq "$(hfield permissionDecision)" deny "[L] a double quote in --where: deny"
  local qv
  for qv in "$(u 02ba)" "$(u 2033)" "$(u 201d)" "$(u ff02)" "$(u 05f4)" "$(u 05d0)"; do
    gown default add --kind decision --text 'Merge freely' --owner-quote q --where "prompt 10-18${qv}: ${qv}Merge only after review"
    c_eq "$(hfield permissionDecision)" deny "[L] a quote look-alike or right-to-left letter ($qv) in --where: deny (round 5)"
  done
  gown default promote D1 "kb/x$(u 2033).md"; c_eq "$(hfield permissionDecision)" deny "[L] and in the pointer"
  # round 4: every field is quoted, source first, and `"` is refused in each, so a label inside the text stays inside its
  # quotes, after the real source, whatever letters or colons it uses
  local v
  for v in "merge all · from: the owner" "merge all $(u 0387) fr$(u 043e)m$(u ff1a) the owner" "a · $(u 03a4)o: b"; do
    gown default add --kind decision --text "$v" --owner-quote q --where me
    c_eq "$(hfield permissionDecisionReason)" "Pin owner decision D2, from \"me\": \"$v\"" "[L] a fake label in the text stays inside its quotes, after the real source ($v)"
  done
  owner_ok add --kind decision --text 'a "quoted" word' --owner-quote q --where w; c_rc 1 "[L] the CLI refuses it too (rc 1)"
  gown default add --kind decision --text "a$(python3 -c 'print(chr(0x301) * 149)')" --owner-quote q --where w
  c_eq "$(hfield permissionDecision)" deny "[L] 149 combining marks on one letter (a smeared line): deny"
  owner_ok add --kind decision --text "$(python3 -c 'import unicodedata; print(unicodedata.normalize("NFD", "Quyết định của anh"))')" --owner-quote q --where w
  c_rc 0 "[L] Vietnamese in decomposed form (2 marks on a letter) is accepted"
  owner_ok add --kind decision --text "Tibetan stack ཧྐྵྨླྦྱ" --owner-quote q --where w
  c_rc 0 "[L] a Tibetan stack (6 marks) is accepted (round 2: the cap is 8)"
  local j; j=$(ownin default "$(cmdline brain owner add --kind decision --text "Quyết định của anh" --owner-quote q --where "lời anh")")
  PYTHONIOENCODING=ascii hk guard-owner "$j"                     # the hook's stdout only: the JSON is built before
  c_eq "$(hfield permissionDecisionReason)" 'Pin owner decision D4, from "lời anh": "Quyết định của anh"' "[L] an ASCII-only stdout still carries a Vietnamese line in UTF-8"
  gown default add --kind decision --text x; c_eq "$(hfield permissionDecision)" deny "[L] a usage error (missing options): deny"
  c_has "$(hfield permissionDecisionReason)" "required" "[L] with the CLI's own message"
}

case_hook_literal() {
  newp
  local c
  for c in 'brain owner add --kind decision --text $(date) --owner-quote q --where w' \
           'brain owner add --kind decision --text x* --owner-quote q --where w' \
           'brain owner add --kind decision --text x --owner-quote q --where w > /dev/null' \
           'brain owner unpin D1; brain owner unpin D2' \
           "brain owner add --kind decision --text 'open --owner-quote q --where w" \
           'brain owner add --kind decision --text "costs \$5 today" --owner-quote q --where w' \
           'brain owner add --kind decision --text costs\ 5 --owner-quote q --where w' \
           'brain owner promote D1 x=~' \
           "$(printf 'brain owner add --kind decision --text cr\r--owner-quote q --where w')" \
           "cd /tmp && brain owner add --kind decision --text 'x' --owner-quote q --where w"; do
    gcmd default "$c"; c_eq "$(hfield permissionDecision)" deny "[T] not literal or not alone, denied: $(printf '%q' "${c:0:60}")"
  done
  c_eq "$(recmode)" none "[T] no record for any of them"
  gcmd default "brain owner add --kind decision --text 'costs \$5, *not* a glob' --owner-quote q --where w"
  c_eq "$(hfield permissionDecision)" ask "[T] single-quoted \$ and *: literal, asked"
  br owner add --kind decision --text 'costs $5, *not* a glob' --owner-quote q --where w; c_rc 0 "[T] and the record serves the call as the shell passes it"
  gcmd default "brain owner --help"
  c_eq "$(hfield permissionDecision)" deny "[T] brain owner --help: one clean deny (argparse's help printed to stdout is kept out)"
}

case_hook_next() {
  newp
  gown default "${ADD[@]}"; c_eq "$(recmode)" default "[Q] instrument: the ask left a record"
  gcmd default "eval \"$(cmdline brain owner "${ADD[@]}")\""
  c_eq "$OUT" "" "[Q] eval of the same command after a refused dialog: not recognised (silent)"
  c_eq "$(recmode)" none "[Q] but it voids the record the refused dialog left"
  br owner "${ADD[@]}"; c_rc 6 "[Q] so the eval'd CLI is refused (rc 6): no write without a dialog"
  gown default "${ADD[@]}"
  gcmd default "ls -la"; c_eq "$(recmode)" none "[Q] any Bash call of the session, even with no brain word, voids it"
  br owner "${ADD[@]}"; c_rc 6 "[Q] and the CLI is refused"
  gown default "${ADD[@]}"
  SID=sB gcmd default "ls -la"; c_eq "$(recmode)" default "[Q] another session's call does not void it"
  br owner "${ADD[@]}"; c_rc 0 "[Q] the approved call itself (no Bash call between): written"
  hk session-end "$(hin session_id="$SID" cwd="$P" hook_event_name=SessionEnd)"
  R=$(find "$XDG_STATE_HOME/vibemaestro/brain/pending" -type f | wc -l | tr -d ' '); c_eq "$R" 0 "[Q] session-end removes the session's pending marker"
  gown default "${ADD[@]}"; mkdir -p "$TMP/elsewhere$NP"
  hk session-end "$(hin session_id="$SID" cwd="$TMP/elsewhere$NP" hook_event_name=SessionEnd)"
  c_eq "$(recmode)" none "[Q] session-end from another directory still voids the record its marker names (round 2)"
  br owner "${ADD[@]}"; c_rc 6 "[Q] so a resumed session cannot use it"
  local pd="$XDG_STATE_HOME/vibemaestro/brain/pending"; mkdir -p "$pd"; : > "$pd/stale"; touch -d '@1000000000' "$pd/stale"
  gcmd default "ls"; c_eq "$([ -e "$pd/stale" ] && echo kept || echo swept)" swept "[Q] a crashed session's marker older than 20 minutes is swept"
  : > "$pd/future"; touch -d '@4000000000' "$pd/future"
  gcmd default "ls"; c_eq "$([ -e "$pd/future" ] && echo kept || echo swept)" swept "[Q] a marker dated far ahead is swept too (round 3)"
  gown default "${ADD[@]}"; mkdir -p "$pd/stale-dir"; touch -d '@1000000000' "$pd/stale-dir"; ln -s "$TMP/nowhere" "$pd/dangling"
  gcmd default "ls -la"; c_eq "$(recmode)" none "[Q] a stale directory and a dangling link in pending/ do not stop the void (round 3)"
  rm -rf "$pd/stale-dir" "$pd/dangling"
  R=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import brain_hook as h, brain_store as s
print(h.SWEEP_AGE >= 2 * s.RECORD_MAX_AGE)' "$BROOT/scripts"); c_eq "$R" True "[Q] the sweep age is at least twice a record's life (round 3)"
  chmod 500 "$pd"; gown default "${ADD[@]}"; chmod 700 "$pd"
  c_eq "$(recmode)" none "[Q] a marker that cannot be written leaves no record either: the marker comes first (round 3)"
}

case_hook_answerer() {
  newp
  printf '%s' "$PRH" > "$MANAGED/managed-settings.json"
  gown default "${ADD[@]}"
  c_eq "$(hfield permissionDecision)" deny "[A] a PermissionRequest hook in the managed settings: deny before any dialog"
  c_has "$(hfield permissionDecisionReason)" "PermissionRequest" "[A] it is named"
  c_eq "$(recmode)" none "[A] no record"
  rm "$MANAGED/managed-settings.json"
}

case_hook_switch() {
  newp
  local m a want got
  export BRAIN_TEST=1 BRAIN_TEST_ASK_MODES=plan,bypassPermissions,dontAsk,default
  for m in bypassPermissions plan; do
    a=(add --kind decision --text "switch in $m" --owner-quote q --where w)
    gown "$m" "${a[@]}"; c_eq "$(hfield permissionDecision)" ask "[S] BRAIN_TEST switch, $m: the dialog is asked (the live test's measurement)"
    c_eq "$(recmode)" "$m" "[S] the record keeps the real mode $m"
    br owner "${a[@]}"; c_rc 6 "[S] switch set + $m: the CLI refuses the record (rc 6)"
  done
  gown dontAsk "${ADD[@]}"; c_eq "$(hfield permissionDecision)" deny "[S] a mode outside plan and bypassPermissions in the switch: ignored, deny"
  R=$(items 2>/dev/null); c_eq "$R" none "[S] nothing was written under the switch"
  # the switch never changes what is accepted: every mode gives the same CLI result with and without it
  for m in default acceptEdits plan bypassPermissions dontAsk; do
    a=(add --kind decision --text "same in $m" --owner-quote q --where w)
    gown "$m" "${a[@]}"; br owner "${a[@]}"; want=$RC
    (unset BRAIN_TEST BRAIN_TEST_ASK_MODES; gown "$m" "${a[@]}"; br owner "${a[@]}"; echo "$RC" > "$TMP/sw$NP")
    got=$(cat "$TMP/sw$NP")
    c_eq "$want" "$got" "[S] $m: the CLI answers the same with and without the switch (rc $got)"
  done
  BRAIN_TEST_ASK_MODES=auto CLAUDE_CODE_EXECPATH=$(fakever "2.1.100 (Claude Code)") gown auto "${ADD[@]}"
  c_eq "$(hfield permissionDecision)" deny "[S] the switch naming auto, below 2.1.211: still deny (a record of mode auto would be accepted)"
  R=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import brain_hook as h, brain_store as s
print(sorted(set(h.TEST_ASK_MODES) & set(s.DIALOG_MODES)))' "$BROOT/scripts"); c_eq "$R" "[]" "[S] the test-only modes and the store's dialog modes share no mode"
  unset BRAIN_TEST
  gown bypassPermissions "${ADD[@]}"; c_eq "$(hfield permissionDecision)" deny "[S] BRAIN_TEST_ASK_MODES without BRAIN_TEST=1: ignored, deny"
  unset BRAIN_TEST_ASK_MODES
}

echo "== cases =="
for c in case_hook_ask case_hook_deny case_hook_next case_hook_void case_hook_line case_hook_literal case_hook_answerer case_hook_switch case_parenthome case_nlname case_isolation case_homes case_rawname case_grammar2 case_answerer2 case_grammar case_norecord case_mismatch case_used case_void case_fresh case_verbs case_owner_budget case_chars case_answerer case_worker; do
  run_case $c; done
cd "$TMP" || exit 1

echo "== planted breaks =="
ST=scripts/brain_store.py
plant record-not-required case_norecord $ST '        if rec is None:
            raise Refused(6, NO_DIALOG' '        if rec is None:
            rec, path = {"mode": "default", "id": "0" * 32}, ""
        if False:
            raise Refused(6, NO_DIALOG'
plant args-not-compared case_mismatch $ST 'r.get("args") == list(args)' 'True'
plant age-cap-6000 case_mismatch $ST 'RECORD_MAX_AGE = 600 ' 'RECORD_MAX_AGE = 6000 '
plant future-record-accepted case_mismatch $ST '0 <= age <= RECORD_MAX_AGE' 'age <= RECORD_MAX_AGE'
plant session-not-compared case_mismatch $ST 'if (r.get("session") == session_id() and' 'if (True and'
plant mode-not-checked case_mismatch $ST 'r.get("mode") in DIALOG_MODES' 'True'
plant spent-ids-ignored case_used $ST 'r.get("id") not in st["spent"]' 'True'
plant record-not-spent case_used $ST '        after = lambda: os.path.exists(path) and os.unlink(path)' '        after = None'
plant earlier-records-kept case_void $ST '        void_records(d, session)
        rid' '        rid'
plant confirm-without-mode case_fresh $ST '        confirm = {"asked": True, "mode": rec["mode"], "record": rec["id"]}' '        confirm = {"asked": True, "record": rec["id"]}'
plant owner-supersede-drops-anchors case_verbs $ST '"expires": old.get("expires"), "links": old.get("links", []), "anchors": old.get("anchors", []),
                "supersedes": ns.id}' '"expires": old.get("expires"), "links": old.get("links", []), "anchors": [],
                "supersedes": ns.id}'
plant owner-refused-by-budget case_owner_budget $ST '        old = get_live(st, ns.id, OWNER_LETTERS)' '        old = get_live(st, ns.id, OWNER_LETTERS)
        if budget_used(st, session_id(), time.time()) >= BUDGET_N:
            raise Refused(1, "budget")'
plant owner-retirements-not-counted case_owner_budget $ST '               if r["session"] == session and' '               if r["session"] == session and not r["op"].startswith("owner") and'
plant control-chars-allowed case_chars $ST '    bad = [c for c in value if is_bad(c)]' '    bad = []'
plant where-cap-600 case_chars $ST '"where": 60,' '"where": 600,'
plant answerers-ignored case_answerer $ST '        ans = answerers()' '        ans = []'
plant prompt-tool-flag-missed case_answerer $ST '        if any(a == "--permission-prompt-tool" or a.startswith("--permission-prompt-tool=") for a in argv):' '        if False:'
plant prompt-tool-substring case_answerer $ST '        if any(a == "--permission-prompt-tool" or a.startswith("--permission-prompt-tool=") for a in argv):' '        if any("--permission-prompt-tool" in a for a in argv):'
plant worktrees-not-read case_answerer2 $ST '    roots = [project or project_root()] + _worktrees() + [a[1] for a in anc if a[1]]' '    roots = [project or project_root()] + [a[1] for a in anc if a[1]]'
plant home-config-dropped case_answerer2 $ST '(os.environ.get("HOME", ""), account_home())' '(account_home(),)'
plant account-home-dropped case_homes $ST '(os.environ.get("HOME", ""), account_home())' '(os.environ.get("HOME", ""),)'
plant relative-config-ignored case_homes $ST '    return os.path.join(cwd or os.getcwd(), c) if c else os.path.join(home(), ".claude")' '    return c if os.path.isabs(c) else os.path.join(home(), ".claude")'
plant parent-home-not-read case_parenthome $ST '    cfgs += [os.path.join(rel(h, cwd), ".claude") for _, cwd, _, h in anc if h]' ''
plant newline-kept case_nlname $ST '    return "".join(c if not is_bad(c) else' '    return "".join(c if c == "\n" or not is_bad(c) else'
plant ancestors-not-bounded case_isolation $ST '        if pid <= 1 or pid == SUITE_PID:' '        if pid <= 1:'
plant doctor-output-raw case_rawname scripts/brain.py '        sys.stdout.write("%-8s %s\n" % (level, s.printable(text)))' '        sys.stdout.write("%-8s %s\n" % (level, text))'
plant dash-value-refused case_grammar2 scripts/brain.py '        ns = parser().parse_args(argv[:1] + owner_argv(argv[1:]))' '        ns = parser().parse_args(argv)'
plant settings-eq-form-missed case_answerer2 $ST '        elif a.startswith(flag + "="):' '        elif False:'
plant settings-relative-to-own-cwd case_answerer2 $ST '                s = _json_file(v if os.path.isabs(v) or not cwd else os.path.join(cwd, v))' '                s = _json_file(v)'
plant plugin-dir-not-read case_answerer2 $ST '        for v in _flag_values(argv, "--plugin-dir"):' '        for v in []:'
plant manifest-hooks-path-not-read case_answerer2 $ST '        if isinstance(h, str) and _has_permission_request(_json_file(os.path.join(root, h))):' '        if False:'
plant grammar-not-checked case_grammar scripts/brain.py '    if not args or args[0] not in OWNER_OPTIONS:
        return' '    return'
plant abbrev-allowed case_grammar2 scripts/brain.py '            if a not in single | multi:' '            if not any(o.startswith(a) for o in single | multi):'
plant disabled-plugin-read case_answerer $ST '        if enabled.get(key) is not True:' '        if False:'
plant worker-check-removed case_worker $ST '    if os.environ.get("INTENT_SLUG") and os.environ.get("SEAT"):' '    if False:'
plant writer-check-removed case_worker $ST '        check_writer(st)
        test_pause()' '        test_pause()'
HK=scripts/brain_hook.py
plant hook-mode-not-checked case_hook_deny $HK 'dialog = mode in ("default", "acceptEdits") or (mode == "auto" and version_ok()) or mode in ask_modes()' 'dialog = True'
plant hook-version-floor-ignored case_hook_ask $HK '(mode == "auto" and version_ok())' '(mode == "auto")'
plant hook-subagent-allowed case_hook_deny $HK '    if inp.get("agent_id"):
        return deny("owner items' '    if False:
        return deny("owner items'
plant hook-record-not-written case_hook_ask $HK '    rid = s.record_asked(d, sid, mode, args)' '    rid = "x"'
plant hook-void-removed case_hook_void $HK '        s.void_records(d, sid)                 # every' '        pass                 # every'
plant hook-literal-not-checked case_hook_literal $HK 'if len(found) > 1 or len(segs) > 1 or found[0][0] is None or found[0][1]:' 'if found[0][0] is None:'
plant hook-text-cut case_hook_line $HK "'Pin owner decision %s, from \"%s\": \"%s\"' % (iid, ns.where, ns.text)" "'Pin owner decision %s, from \"%s\": \"%s\"' % (iid, ns.where, ns.text[:40])"
plant quote-lookalike-allowed case_hook_line $ST '        if value and field != "text":' '        if False:'
plant source-after-text case_hook_line $HK "'Pin owner decision %s, from \"%s\": \"%s\"' % (iid, ns.where, ns.text)" "'Pin owner decision %s: \"%s\" · from: %s' % (iid, ns.text, ns.where)"
plant hook-answerers-ignored case_hook_answerer $HK '    ans = s.answerers()' '    ans = []'
plant switch-records-default case_hook_switch $HK '    rid = s.record_asked(d, sid, mode, args)' '    rid = s.record_asked(d, sid, "default" if mode in ask_modes() else mode, args)'
plant switch-without-brain-test case_hook_switch $HK '    if os.environ.get("BRAIN_TEST") != "1":
        return []' '    if False:
        return []'
plant switch-any-mode case_hook_switch $HK 'if m in TEST_ASK_MODES and m not in dialog]' 'if m]'
plant store-accepts-test-modes case_hook_switch $ST 'DIALOG_MODES = ("default", "acceptEdits", "auto")' 'DIALOG_MODES = ("default", "acceptEdits", "auto", "plan", "bypassPermissions")'

plant hook-pending-not-cleared case_hook_next $HK '    if sid:
        clear_pending(store(), sid)' '    if False:
        clear_pending(store(), sid)'
plant hook-fast-path-ignores-pending case_hook_next $HK '                        waiting = True' '                        waiting = False'
plant hook-marker-not-written case_hook_next $HK '    mark_pending(s, sid, d)                         # first' '    pass                         # first'
plant end-clears-marker-only case_hook_next $HK '        clear_pending(s, sid)                       # the record' '        os.unlink(pending_marker(sid)) if os.path.exists(pending_marker(sid)) else None   # the record'
plant stale-markers-kept case_hook_next $HK '                    else:
                        os.unlink(_p)' '                    else:
                        pass'
plant marker-after-record case_hook_next $HK '    mark_pending(s, sid, d)                         # first: a marker with no record is harmless, a record with none is not
    rid = s.record_asked(d, sid, mode, args)' '    rid = s.record_asked(d, sid, mode, args)
    mark_pending(s, sid, d)'
plant sweep-age-600 case_hook_next $HK 'SWEEP_AGE = 1200 ' 'SWEEP_AGE = 600 '
plant future-markers-kept case_hook_next $HK '                    if -SWEEP_AGE < _age < SWEEP_AGE:' '                    if _age < SWEEP_AGE:'
plant python-runs-wrapper case_hook_deny $HK '    if i and os.path.basename(ws[1] if ws[1:] else "") != "brain.py":' '    if False:'
plant hook-alone-not-required case_hook_literal $HK 'if len(found) > 1 or len(segs) > 1 or found[0][0] is None' 'if len(found) > 1 or found[0][0] is None'
# no plant for the `escape` flag: every input it denies is also denied by the `$`/backtick flag, the open-quote flag or the
# store's control-character check (a newline), so it is defence in depth that no single break can show red
plant hook-help-on-stdout case_hook_literal $HK 'with contextlib.redirect_stderr(err), contextlib.redirect_stdout(err):' 'with contextlib.redirect_stderr(err):'
plant hook-owner-anywhere case_hook_deny $HK '    if ws[i:i + 1] and is_brain(ws[i]) and ws[i + 1:i + 2] == ["owner"]:
        return ws[i + 2:]' '    for i in range(len(ws)):
        if is_brain(ws[i]) and ws[i + 1:i + 2] == ["owner"]:
            return ws[i + 2:]'
plant switch-may-name-auto case_hook_switch $HK 'TEST_ASK_MODES = ("plan", "bypassPermissions")' 'TEST_ASK_MODES = ("plan", "bypassPermissions", "auto")'
plant quote-allowed case_hook_line $ST "        if value and '\"' in value:" "        if False:"
plant marks-unbounded case_hook_line $ST '    if _marks_run(value) > MARKS_RUN_MAX:' '    if False:'
plant stdout-locale case_hook_line $HK '    sys.stdout.buffer.write(out.encode("utf-8"))' '    sys.stdout.write(out)'

summary
