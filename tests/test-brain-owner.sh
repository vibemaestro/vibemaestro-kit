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
#   [W] a window's scope (--lower, --exclude): the dialog shows it, the item keeps it with the session, `brain windows` and the
#       render show it, a window with none lowers no signing; a scope the runner never honours, or over 24 hours, refused before
#       the dialog; a supersede drops it, `op close` ends a window at once; a broken chain stops `brain windows`
#   [J] guard-owner run with the shell in B for a session whose project is A writes its record in A, and `brain owner`
#       typed in B then writes A's hot memory; B gets no state
#   [T] arguments read literally, the command alone, or denied: substitution, glob, redirect, two owner commands, an open
#       quote, an escaped $ in double quotes, a backslash, ~ after =, a carriage return, a leading cd; --help is one deny
#   [Q] round 1: a record serves only the call it was asked for: the session's next Bash call of any shape (an eval, a
#       plain ls) voids it, another session's does not, the approved call itself writes, session-end drops the marker; round
#       2: session-end from another directory voids the record its marker names; a marker over 10 minutes old is swept
#   [A] a programmatic answerer: deny before any dialog
#   [S] the BRAIN_TEST switch (BRAIN_TEST_ASK_MODES): asks in plan and bypassPermissions only, the record keeps the real
#       mode, and the CLI refuses it; in every mode the CLI answers the same with and without the switch
#   [F] a command that only mentions brain and owner is silent with no record: a heredoc (an apostrophe, a line
#       `brain owner …`, <<-, after a shift in arithmetic), echo, printf, grep, a commit message, a gh body
#   [B] `brain owner batch FILE`: 2 to 5 add, supersede or unpin items through one dialog, a line per item as
#       its single form shows it; the record binds the file's bytes and the dialog text, so an edit the dialog does not show,
#       a swapped file, items reordered or the brain changed since: rc 6, nothing written; 1 or 6 items, an item the single
#       form refuses, another verb, a file that is not JSON or is a symlink: refused before any dialog; the session's project
#       from another directory
#   [A1] a field before the text (where, pointer) is refused unless every character is on the allowlist: U+1CD3,
#       U+02F5 and U+0660 refused by the CLI and guard-owner, every code point the old blocklist refused still refused;
#       Vietnamese (NFC and NFD), a path, a URL and other left-to-right scripts accepted
#   [G] every real form is still guarded: bin/brain by path (quoted or not) and python3.X brain.py alone and literal
#       are asked; after `&&`, after a heredoc (two on a line, a backslash word, after a subshell), after a shift `<<` in
#       arithmetic (no closing line: nothing skipped), with a heredoc, an open quote after a quoted path: denied; bash -c, sh -c
#       and a heredoc fed to a shell: silent, no record, and the CLI they run refuses rc 6
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
# shellcheck source=fixtures/owner-hosts.sh
. "$HERE/fixtures/owner-hosts.sh"

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

case_result_text() {  # the result of an owner write carries the item as stored, so the model sees it in the turn it was signed
  newp
  owner_ok "${ADD[@]}"
  c_eq "$RC|$OUT" "0|pinned D1
id: D1
kind: decision
text: Owner merges every PR that touches clusters/
quote: PR chạm clusters/ thì anh merge" "[X] add: the line it had, then id, kind, text and the owner's words"
  owner_ok supersede D1 --text "The owner merges clusters/ PRs"
  c_eq "$RC|$OUT" "0|superseded D1 with D2
id: D2
kind: decision
text: The owner merges clusters/ PRs" "[X] supersede with a text: the new text, no quote line (the new item holds none)"
  owner_ok supersede D2 --scope global
  c_eq "$RC|$OUT" "0|superseded D2 with D3
id: D3
kind: decision
text: The owner merges clusters/ PRs" "[X] supersede with no text: the text it carries over"
  newp
  owner_ok "${ADD[@]}"; owner_ok supersede D1 --scope global
  c_eq "$RC|$OUT" "0|superseded D1 with D2
id: D2
kind: decision
text: Owner merges every PR that touches clusters/
quote: PR chạm clusters/ thì anh merge" "[X] supersede of a decision that holds the owner's words, no text given: text and quote carried over"
  newp
  local h='#'                                    # the number is joined here: a literal one reads as a reference to the public-tree scan
  owner_ok add --kind decision --text "d" --owner-quote q --where w --anchor "${h}7"
  c_eq "$RC|$OUT" "0|pinned D1
warning: ${h}7 is not checked for staleness (the item names no single repository to resolve it against); write owner/name${h}7 (a GitHub issue or PR URL also works)
id: D1
kind: decision
text: d
quote: q" "[X] a warning line of the old result stays before the new lines"
  owner_ok add --kind goal --text "ship it" --owner-quote q --where w --done "shipped" --not-doing "more" --review "$(python3 -c 'import datetime as d; print(d.date.today() + d.timedelta(days=365))')" --scope global
  c_eq "$RC|$OUT" "0|pinned G1
id: G1
kind: goal
text: ship it
quote: q" "[X] a goal: its text and the owner's words"
  owner_ok add --kind window --text "May merge docs-only PRs" --owner-quote "docs PR thì cứ merge" --where "prompt 1" --expires 2099-01-01T00:00:00Z
  c_eq "$RC|$OUT" "0|pinned W1
id: W1
kind: window
text: May merge docs-only PRs
quote: docs PR thì cứ merge
expires: 2099-01-01T00:00:00Z" "[X] a window: its text, the owner's words and its expiry"
  owner_ok unpin W1
  c_eq "$RC|$OUT" "0|unpinned W1" "[X] unpin prints what it did before: nothing new to show"
  newp
  bfile b.json '[["add", "--kind", "decision", "--text", "first pin", "--owner-quote", "anh nói", "--where", "chat 31/10"],
                 ["add", "--kind", "decision", "--text", "second pin", "--owner-quote", "q2", "--where", "chat 31/10"]]'
  gown default batch b.json; br owner batch b.json
  c_eq "$RC|$OUT" "0|pinned D1; pinned D2
id: D1
kind: decision
text: first pin
quote: anh nói
id: D2
kind: decision
text: second pin
quote: q2" "[X] a batch: its line as before, then each item's lines"
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
  printf '{"version":2,"plugins":{"answer@m":[{"scope":"user","installPath":"%s"}]}}' "$(wpath "$TMP/pl$NP")" > "$CLAUDE_CONFIG_DIR/plugins.json"
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
  c_rc 6 "[P] an ancestor started with --permission-prompt-tool: rc 6"; c_has "$OUT" "a process started with --permission-prompt-tool" "[P] … for that reason"
  # Claude Code's shapes: a program that is not Git Bash's, started with the flag, runs Git Bash's bash; a hook is its one
  # command (bash execs it), the Bash tool's call one of several (bash forks, and the fork execs: the break the walk crosses)
  local sh_; for sh_ in '"$0" owner "$@"' '"$0" owner "$@"; exit $?'; do
    rec default sA "${a[@]}"
    OUT=$(CLAUDE_CODE_SESSION_ID=sA python3 -c 'import subprocess, sys; sys.exit(subprocess.call(sys.argv[2:]))' \
          --permission-prompt-tool "$(command -v bash)" -c "$sh_" "$BROOT/bin/brain" "${a[@]}" 2>&1); RC=$?
    c_rc 6 "[P] a Python parent started with --permission-prompt-tool, its bash running the call ($sh_): rc 6"
    c_has "$OUT" "a process started with --permission-prompt-tool" "[P] … for that reason ($sh_)"
  done
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
  [ "${OS:-}" != Windows_NT ] || c_has "$OUT" "names a relative path, which the brain cannot find on Windows" "[R] Windows: refused because the parent's working directory is not read there"
  mkdir -p "$TMP/pd$NP/hooks"; printf '%s' "$PRH" > "$TMP/pd$NP/hooks/hooks.json"; rec default sA "${a[@]}"
  # (on Windows the parent is a Git Bash bash, which takes the path as typed: Claude Code there is given C:/…)
  OUT=$(CLAUDE_CODE_SESSION_ID=sA bash -c '"$2" owner "${@:3}"; exit $?' --plugin-dir "$(wpath "$TMP/pd$NP")" "$BROOT/bin/brain" "${a[@]}" 2>&1); RC=$?
  c_rc 6 "[R] a parent with --plugin-dir <a plugin with the hook>: rc 6"
  export CLAUDE_CONFIG_DIR="$cfg"; mkdir -p "$TMP/mp$NP/.claude-plugin" "$TMP/mp$NP/cfg" "$cfg/plugins"
  printf '%s' "$PRH" > "$TMP/mp$NP/cfg/h.json"; printf '{"name":"mp","hooks":"./cfg/h.json"}' > "$TMP/mp$NP/.claude-plugin/$MAN"
  printf '{"version":2,"plugins":{"mp@m":[{"scope":"user","installPath":"%s"}]}}' "$(wpath "$TMP/mp$NP")" > "$cfg/plugins/installed_plugins.json"
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
  R=$(bash -c 'python3 "$0" "$1"; exit $?' "$TMP/anc.py" "$BROOT/scripts" | tr -d '\r')   # a bash between: the case's own ancestor
  c_eq "$R" "[] [] [] True" "[Y] the ancestors a case sees: no cwd or HOME outside the scratch tree, no config dir (and at least one)"
}

case_win_walk() {  # the Windows walk of the parent processes, on fake process tables (every system) and on this one (Windows)
  newp
  R=$(bpy '
F = 10 ** 9                                         # ids no running process has
def info_of(times, bad=(), gone=()):
    def info(pid):
        if pid in bad:
            raise PermissionError(13, "Access is denied")
        if pid in gone:
            raise ProcessLookupError(pid)
        return times[pid], "cmd %d" % (pid - F)
    return info
def walk(start, table, info, stop=None, bridge=None):
    try:
        return [c for _, c in s.win_chain(start, table, info, stop, bridge)]
    except s.Unread as e:
        return "Unread: %s" % e
t = {F + i: F + i + 1 for i in range(4)}            # F, its parent F+1, … F+4, which is not running
times = {F + i: 100 - i for i in range(5)}
younger = dict(times); younger[F + 2] = 200
print(walk(F, t, info_of(times)))
print(walk(F, t, info_of(times, bad={F + 2})))
print(walk(F, t, info_of(times, bad={F})))
print(walk(F, t, info_of(younger)))
print(walk(F, t, info_of(times, gone={F + 2})))
print(walk(F, {F: 4, 4: 0}, info_of({F: 1, 4: 0})))
print(walk(F + 9, t, info_of(times)))
print(walk(F, {F: F + 1, F + 1: F}, info_of({F: 1, F + 1: 1})))
print(walk(F, t, info_of(times), stop=F + 2))
def git_bash(parents, bad=()):                      # what Git Bash keeps: the parent of each of its processes
    def bridge(pid, below):
        if pid in bad:
            raise OSError("ps.exe exited 1")
        return parents.get(pid)
    return bridge
g = {F: F + 1, F + 1: F + 9, F + 2: F + 8, F + 4: F + 5}   # F+1 and F+2 each exec-ed by a Git Bash process now gone
gt = {F: 10, F + 1: 9, F + 2: 5, F + 4: 3}
print(walk(F, g, info_of(gt), bridge=git_bash({F + 1: F + 2, F + 2: F + 4})))
print(walk(F, g, info_of(gt), bridge=git_bash({F + 1: F + 2}, bad={F + 2})))
print(walk(F, g, info_of(gt), bridge=git_bash({F + 1: F + 7})))
print(walk(F, g, info_of({F: 10, F + 1: 9, F + 2: 50, F + 4: 3}), bridge=git_bash({F + 1: F + 2})))
print(walk(F, g, info_of(gt), bridge=git_bash({})))
print(walk(F, g, info_of(gt), stop=F + 2, bridge=git_bash({F + 1: F + 2})))')
  c_eq "$R" "['cmd 1', 'cmd 2', 'cmd 3']
Unread: process 1000000002: Access is denied
Unread: process 1000000000: Access is denied
['cmd 1']
['cmd 1']
[]
Unread: process 1000000009 is not in the process table
Unread: the chain of parent processes does not end within 64
['cmd 1']
['cmd 1', 'cmd 2', 'cmd 4']
Unread: the Git Bash parent of process 1000000002: ps.exe exited 1
Unread: process 1000000007, Git Bash's parent of 1000000001, is not in the process table
Unread: process 1000000002, Git Bash's parent of 1000000001, started after it
['cmd 1']
['cmd 1']" "[WW] the walk: to the first parent not running; a running one it cannot read refuses; an id a younger process took, or one that ended, ends it; no end refuses; past a Git Bash exec, the parent Git Bash keeps, and one it cannot read refuses"
  R=$(bpy 'try:
    print(s.msys_table("      PID    PPID    PGID     WINPID   TTY         UID    STIME COMMAND\n"
                       "     1234       1    1234      10764  cons0     197609 12:00:01 /usr/bin/bash\n"
                       "I    2345    1234    2345      11220  cons0     197609 12:00:02 /usr/bin/sh\n"))
    s.msys_table("ps: unknown option\n")
except OSError as e:
    print("OSError:", e)')
  R2=$(bpy 'for rows in ("     1234       1    1234      10764\n", "     1234       1    1234      10764  cons0  1 12:00:01 /usr/bin/bash\n     4321    1234    4321      10999  cons0  1 12:00:03 <defunct>\n"):
    try:
        print(s.msys_table("      PID    PPID    PGID     WINPID   TTY         UID    STIME COMMAND\n" + rows))
    except OSError as e:
        print("OSError:", e)')
  c_eq "$R2" "OSError: ps printed a row this check cannot read
({10764: (1234, 1)}, {1234: 10764})" "[WW] a row cut short (ps cuts at COLUMNS) refuses; a process ended and not reaped is left out"
  c_eq "$R" "({10764: (1234, 1), 11220: (2345, 1234)}, {1234: 10764, 2345: 11220})
OSError: ps printed no process table" "[WW] Git Bash's ps read: each Windows pid with its Git Bash pid and parent; anything else is no table"
  mkdir -p "$TMP/gb$NP"; : > "$TMP/gb$NP/msys-2.0.dll"
  R=$(bpy 'import os, subprocess
gb = "'"$(wpath "$TMP/gb$NP")"'"
# bash -c (200, Git Bash pid 20) forked a child that exec-ed sh (400, Git Bash pid 30) and ended; sh exec-ed Windows Python (500)
# and waits on it, so ps shows pid 30 at Windows pid 500; the Git Bash parent of bash -c is the suite shell (10, Windows pid 100).
table = {500: 400, 400: 300, 200: 100, 100: 50}
times = {100: 0, 200: 1, 400: 3, 500: 4, 600: 3, 700: 5, 900: 2}
cmds = {100: "bash suite.sh", 200: "bash -c X --permission-prompt-tool brain", 400: "sh bin/brain owner", 500: "python brain.py",
        600: "sh shim", 700: "python brain.py", 900: "bash -c Y --permission-prompt-tool brain"}
def info(pid):
    return times[pid], cmds[pid]
s._win_image = lambda pid: os.path.join(gb, "x.exe")
def ps(rows, rc=0):
    def run(argv, **kw):                            # the ps of Git Bash: lines cut at COLUMNS; without -a, this account only
        cols = int((kw.get("env") or os.environ).get("COLUMNS") or 65536)
        lines = ["      PID    PPID    PGID     WINPID   TTY         UID    STIME COMMAND"] + rows.splitlines()
        lines = [l for l in lines if "-a" in argv[1:] or " 999999 " not in l]
        return subprocess.CompletedProcess(argv, rc, "".join(l[:cols] + "\n" for l in lines).encode(), b"")
    s.subprocess.run = run
def walk(start=500, stop=100):
    try:
        return [c for _, c in s.win_chain(start, table, info, stop, bridge=s._msys_bridge())]
    except s.Unread as e:
        return "Unread: %s" % e
os.environ["COLUMNS"] = "36"
row = lambda pid, ppid, w, name, uid=197609: "%9d %7d %7d %10d  cons0 %10d 12:00:01 %s\n" % (pid, ppid, pid, w, uid, name)
ps(row(10, 1, 100, "/usr/bin/bash", 999999) + row(20, 10, 200, "/usr/bin/bash") + row(30, 20, 500, "/usr/bin/sh"))
print(walk())                                       # the suite shell as another account: read through ps -a
ps("", rc=1)
print(walk())
ps(row(30, 20, 500, "/usr/bin/sh"))
print(walk())
ps(row(10, 1, 100, "/usr/bin/bash"))
print(walk())
# bash -c (900) started by a program that is not Git Bash (Git Bash parent 1) exec-ed sh, which exec-ed sh (that one ended),
# which exec-ed Windows Python (700): Git Bash shows pid 40 at 700, with parent 1; the waiting bash -c above is not found
table.update({700: 600, 600: 800, 900: 50})
ps(row(40, 1, 700, "/usr/bin/sh"))
print(walk(700))')
  c_eq "$R" "['sh bin/brain owner', 'bash -c X --permission-prompt-tool brain']
Unread: the Git Bash parent of process 400: ps.exe exited 1
Unread: the Git Bash parent of process 400: its Git Bash parent 20 is not in Git Bash's process table
Unread: the Git Bash parent of process 400: Git Bash's process table does not hold it
Unread: the Git Bash parent of process 600: Git Bash keeps no running parent of it, and the program above the break is not known" \
    "[WW] past a sh that exec-ed Windows' Python (ps shows its pid at the Python's), the walk reaches the bash -c above; no ps, or a parent missing from it, refuses"
  R=$(bpy '
import struct
head, base = struct.calcsize("HHP"), 5000
us = lambda n, most, at, data: struct.pack("HHP", n, most, base + at) + data
txt = "claude --permission-prompt-tool x".encode("utf-16-le")
good = us(len(txt), len(txt) + 2, head, txt)
print(s.us_text(good, base))
print(all(s.us_text(good[:k], base) is None for k in range(len(good))))
print(s.us_text(us(3, 4, head, b"ab\0\0"), base), s.us_text(us(len(txt), len(txt), head - 2, txt), base),
      s.us_text(us(len(txt), 2, head, txt), base), s.us_text(us(2, 2, len(good), txt), base))')
  c_eq "$R" "claude --permission-prompt-tool x
True
None None None None" "[WW] a command line is read from its own bytes only: every cut, an odd length, a pointer outside them or past its maximum is refused"
  R=$(bpy 'q, b = chr(34), chr(92)                    # a quote and a backslash, kept out of the shell quoting
c = (q + "C:" + b + "Program Files" + b + "c.exe" + q + " " + q + "--settings={" + b + q + "a" + b + q + ":1}" + q + " a" + b * 2
     + "b " + q + "x" + q * 2 + "y" + q + " c" + b * 3 + q + "d --plugin-dir=" + q + "C:" + b + "p d" + q)
print("|".join(s.split_cmdline(c)))')
  c_eq "$R" 'C:\Program Files\c.exe|--settings={"a":1}|a\\b|x"y|c\"d|--plugin-dir=C:\p d' \
    "[WW] a command line split as the C runtime splits it: a quoted program, escaped quotes, backslashes, \"\" inside quotes"
  mkdir -p "$TMP/profile$NP/.claude"; printf '%s' "$PRH" > "$TMP/profile$NP/.claude/$SET"   # a USERPROFILE holding the hook
  R=$(bpy '
import json, os
s.WINDOWS = True
me, F = os.getpid(), 10 ** 9
def parent(cmd, bad=False):
    s._win_table = lambda: {me: F, F: F + 1}
    def info(pid):
        if bad and pid == F:
            raise PermissionError(13, "Access is denied")
        return (2, "python brain.py") if pid == me else (1, cmd)
    s._win_info = info
    s._msys_bridge = lambda: lambda pid, below: None    # no Git Bash process in this table
    return "; ".join(s.answerers()) or "none"
hook = json.dumps({"hooks": {"PermissionRequest": [{"hooks": [{"type": "command", "command": "true"}]}]}})
print(parent("claude --permission-prompt-tool mcp__x__ok"))
print(parent("claude", bad=True).replace(str(F), "F"))
print(parent("claude --settings s.json"))
print(parent("claude \"--settings=%s\"" % hook.replace("\"", "\\\"")))
print(parent("bash -c \"brain owner add --text --permission-prompt-tool\""))
q, b = chr(34), chr(92)
print(parent(q + "C:" + b + "cl" + b + "claude.exe" + q + "--permission-prompt-tool stdio -p go"))
print(parent("claude.exe " + q * 3 + " --permission-prompt-tool x" + q + " -p go"))
print(parent("claude --settings " + b + "s.json"))
os.environ["USERPROFILE"] = "'"$(wpath "$TMP/profile$NP")"'"
print(parent("claude"))')
  c_eq "$R" "a process started with --permission-prompt-tool
a parent process whose command line the brain cannot read (process F: Access is denied)
a --settings of a parent process names a relative path, which the brain cannot find on Windows
a PermissionRequest hook in --settings of a parent process
none
a process started with --permission-prompt-tool
a process started with --permission-prompt-tool
a --settings of a parent process names a relative path, which the brain cannot find on Windows
a PermissionRequest hook in the user settings" "[WW] on Windows' process table: the flag (also as an older Bun splits it), a parent it cannot read, a relative or drive-less --settings, a hook in one and one in USERPROFILE's ~/.claude each refuse the owner's write; a flag inside a bash -c text does not"
  R=$(bpy 'q, b = chr(34), chr(92)
for c in (q + "C:" + b + "cl" + b + "claude.exe" + q + "--permission-prompt-tool stdio", "claude.exe " + q * 3 + " --settings C:/t/s.json" + q + " -p go"):
    print("|".join(s.split_cmdline(c)), "/", "|".join(s.split_cmdline_w(c)))')
  c_eq "$R" 'C:\cl\claude.exe--permission-prompt-tool|stdio / C:\cl\claude.exe|--permission-prompt-tool|stdio
claude.exe|" --settings C:/t/s.json|-p|go / claude.exe|"|--settings|C:/t/s.json -p go' \
    "[WW] the two rules a Windows program may split by differ after a quoted program and in a run of three quotes; the walk reads both"
  if [ "${OS:-}" = Windows_NT ]; then
    R=$(bpy 'import os
ch = s.win_chain(os.getpid(), s._win_table(), s._win_info, bridge=s._msys_bridge())
print(len(ch) > 1, any(os.path.basename(s.split_cmdline(c)[0]).lower() in ("bash", "bash.exe") for _, c in ch), len(s.win_ancestors()) > 0)')
    c_eq "$R" "True True True" "[WW] this process's own chain on this runner: read to its end, a bash in it, and the suite's part of it seen"
  else c_skip "[WW] this process's own chain, by Windows' own calls" "a Windows runner checks it"; fi
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
  printf '%s' '{"version":2,"plugins":{"ans\u001b[2Jwer@m":[{"scope":"user","installPath":"'"$(wpath "$TMP/pe$NP")"'"}]}}' > "$cfg/plugins/installed_plugins.json"
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
  if [ "${OS:-}" = Windows_NT ]; then c_skip "[Z3] the parent's HOME holds the hook" "the brain reads no parent's environment on Windows (README, On Windows)"; else
  rec default sA "${a[@]}"
  OUT=$(env HOME="$TMP/ph$NP" CLAUDE_CODE_SESSION_ID=sA bash -c 'HOME="$1/other" "$0" owner "${@:2}"; exit $?' "$BROOT/bin/brain" "$TMP" "${a[@]}" 2>&1); RC=$?
  c_rc 6 "[Z3] the parent's HOME holds the hook, the call runs under another HOME: rc 6"; fi
  rm "$TMP/ph$NP/.claude/$SET"; rec default sA "${a[@]}"
  OUT=$(env HOME="$TMP/ph$NP" CLAUDE_CODE_SESSION_ID=sA bash -c 'HOME="$1/other" "$0" owner "${@:2}"; exit $?' "$BROOT/bin/brain" "$TMP" "${a[@]}" 2>&1); RC=$?
  c_rc 0 "[Z3] instrument: without the hook, the same call writes"
}

case_nlname() {
  newp
  local cfg="$TMP/cfg$NP"; mkdir -p "$cfg/plugins" "$TMP/pn$NP/hooks"
  printf '%s' "$PRH" > "$TMP/pn$NP/hooks/hooks.json"
  printf '%s' '{"version":2,"plugins":{"x\nok       forged line\ny@m":[{"scope":"user","installPath":"'"$(wpath "$TMP/pn$NP")"'"}]}}' > "$cfg/plugins/installed_plugins.json"
  printf '%s' '{"enabledPlugins":{"x\nok       forged line\ny@m":true}}' > "$cfg/$SET"
  OUT=$(CLAUDE_CONFIG_DIR="$cfg" CLAUDE_CODE_SESSION_ID=sA "$BROOT/bin/brain" doctor 2>&1); RC=$?
  c_has "$OUT" 'enabled plugin x\u000aok' "[Z3] instrument: doctor names the plugin, its newline escaped"
  R=$(printf '%s\n' "$OUT" | grep -c '^ok       forged line'); c_eq "$R" 0 "[Z3] no forged doctor line"
}

# --- the guard-owner hook --------------------------------------------------------------------------------------------------------

cmdline() { wargs "$@"; MSYS_NO_PATHCONV=1 python3 -c 'import shlex, sys; print(shlex.join(sys.argv[1:]))' ${WARGS[@]+"${WARGS[@]}"}; }
u() { python3 -c 'import sys; sys.stdout.buffer.write(chr(int(sys.argv[1], 16)).encode("utf-8"))' "$1"; }   # u <hex>: one character, whatever the locale (CI's printf left \\u02ba as text)
ownin() {  # ownin <mode> <command> [key=value…] — guard-owner's input for session SID in project P (an empty mode is left out);
  # the command goes over as written (Git Bash would rewrite one that starts with /), the cwd as Claude Code sends it there
  MSYS_NO_PATHCONV=1 python3 -c 'import json, sys
d = {"session_id": sys.argv[1], "cwd": sys.argv[2], "hook_event_name": "PreToolUse", "tool_name": "Bash",
     "tool_input": {"command": sys.argv[4]}}
if sys.argv[3]:
    d["permission_mode"] = sys.argv[3]
for kv in sys.argv[5:]:
    k, _, v = kv.partition("=")
    d[k] = v
print(json.dumps(d, ensure_ascii=False))' "$SID" "$(wpath "$P")" "$@"
}
gown() { local m=$1; shift; hk guard-owner "$(ownin "$m" "$(cmdline brain owner "$@")")"; }   # gown <mode> <args after owner…>
gcmd() { hk guard-owner "$(ownin "$@")"; }                                                       # gcmd <mode> <command> [k=v…]
recmode() { bpy 'import glob, json, os
print(" ".join(sorted(json.load(open(p))["mode"] for p in glob.glob(os.path.join(s.state_dir(), "asked", "*.json")))) or "none")'; }
recid() { bpy 'import glob, os
print(" ".join(sorted(os.path.basename(p) for p in glob.glob(os.path.join(s.state_dir(), "asked", "*.json")))) or "none")'; }
fakever() {  # fakever <version line> — a fake Claude Code binary printing it; prints its path. Windows' Python starts no
  # #!/bin/sh script there, and Windows runs a .cmd file through cmd.exe
  local f; f=$(mktemp "$TMP/claude-$NP.XXXXXX")
  if [ "${OS:-}" = Windows_NT ]; then mv "$f" "$f.cmd"; f="$f.cmd"; printf '@echo %s\r\n' "$1" > "$f"
  else printf '#!/bin/sh\necho "%s"\n' "$1" > "$f"; chmod +x "$f"; fi
  echo "$f"
}
LINE1='Pin owner decision D1 (a lasting direction, never done), from "prompt 10-18 09:11": "Owner merges every PR that touches clusters/"'

case_hook_project() {  # guard-owner and the CLI agree on the session's project while the shell is in another one
  newp
  local A=$P B="$TMP/other$NP" dA dB
  mkdir -p "$B"; git_ -C "$B" init -q -b main
  dA=$(sdir); dB=$(cd "$B" && bpy 'import os; print(s.state_dir(os.getcwd()))')
  cd "$B" || return 1
  P=$B CLAUDE_PROJECT_DIR=$A gown default "${ADD[@]}"
  c_eq "$(hfield permissionDecision)" ask "[J] guard-owner with cwd in B, the session's project A: ask"
  c_eq "$(ls "$dA/asked" 2>/dev/null | wc -l | tr -d ' ')" 1 "[J] the record is in A"
  br owner "${ADD[@]}"
  c_rc 0 "[J] brain owner typed in B: written"
  c_has "$(cat "$dA/hot.jsonl" 2>/dev/null)" "Owner merges every PR" "[J] into A's hot memory"
  c_eq "$([ -e "$dB" ] && echo made || echo none)" none "[J] B has no brain state"
}

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
  mkdir -p "$TMP/nover$NP"; cp "$(fakever "no version here")" "$TMP/nover$NP/claude"   # nor a `claude` on PATH that knows one
  PATH="$TMP/nover$NP:$PATH" CLAUDE_CODE_EXECPATH=$(fakever "no version here") gown auto "${a[@]}"
  c_eq "$(hfield permissionDecision)" deny "[H] auto on an unknown version: deny"
}

# brain_host_row <mode> — under the row's HOST and HOST_ENV (owner_hosts): guard-owner's decision, then the CLI's rc after an
# ask (the CLI runs under the same host, as the Bash tool does) or the deny's reason
brain_host_row() {
  NH=$((NH+1))
  local a=(add --kind decision --text "decision under host row $NH" --owner-quote q --where w)
  OUT=$(ownin "$1" "$(cmdline brain owner "${a[@]}")" | env "${HOST_ENV[@]}" ${HOST[@]+"${HOST[@]}"} python3 "$BROOT/scripts/brain_hook.py" guard-owner 2>/dev/null)
  if [ "$(hfield permissionDecision)" = ask ]; then
    env CLAUDE_CODE_SESSION_ID="$SID" "${HOST_ENV[@]}" ${HOST[@]+"${HOST[@]}"} "$BROOT/bin/brain" owner "${a[@]}" > /dev/null 2>&1
    echo "ask/$?"
  else
    hfield permissionDecision; hfield permissionDecisionReason
  fi
}
NH=0

case_hook_hosts() {  # [HOST] the shared table: the official hosts' dialog writes, in auto too; every other answerer is refused
  newp
  owner_hosts "$TMP/hosts$NP" brain_host_row c_eq c_has
  HOST=(); HOST_ENV=(CLAUDE_PID=² PATH="$TMP/hosts$NP/auto-none/bin:$PATH")
  c_has "$(brain_host_row auto | tr '\n' ' ')" 'deny brain: permission mode auto' "[HOST] CLAUDE_PID not a plain number (²): no crash, a deny"
  c_has "$(brain_host_row auto)" '(tried: `claude` on PATH)' "[HOST] … that tried PATH only"
  owner_vline "$P" claude 2.1.290 win > /dev/null      # a project's own claude, in the hook's working directory
  HOST_ENV=(PATH=".:$TMP/hosts$NP/auto-none/bin:$PATH")
  c_has "$(brain_host_row auto | tr '\n' ' ')" 'deny brain: permission mode auto' "[HOST] a claude in the working directory (. first on PATH; Windows looks there anyway): not run, deny"
  c_has "$(brain_host_row auto)" '(tried: `claude` on PATH)' "[HOST] … no claude on PATH taken"
  rm -f "$P/claude" "$P/claude.cmd"
  if [ "${OS:-}" = Windows_NT ]; then
    c_skip "[HOST] brain doctor reads the version of the running Claude Code" "Windows Python cannot run the fake host, a Git Bash script"
  else
    OUT=$(env CLAUDE_CODE_SESSION_ID="$SID" PATH="$TMP/hosts$NP/auto-terminal/bin:$PATH" \
            bash "$TMP/hosts$NP/auto-terminal/claude" :: "$BROOT/bin/brain" doctor 2>&1)
    c_has "$OUT" "Claude Code 2.1.290" "[HOST] brain doctor reads the version of the running Claude Code, with none on PATH"
  fi
  printf '%s' "$PRH" > "$MANAGED/managed-settings.json"
  HOST_ENV=(CLAUDE_CODE_ENTRYPOINT=claude-vscode); read -r -a HOST <<< "bash $TMP/hosts$NP/vscode/claude $OWNER_SDK ::"
  c_eq "$(brain_host_row default | head -n 1)" deny "[HOST] the VS Code host with a PermissionRequest hook in the managed settings: deny"
  rm -f "$MANAGED/managed-settings.json"
}

case_hook_launchers() {  # [LAUNCH] the shared table: the macOS app's launcher of its bundle is folded into its Claude Code; nothing else is
  newp
  owner_launchers "$TMP/launch$NP" brain_host_row c_eq c_has "$BROOT/scripts/brain_host.py"
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
  c_eq "$(hfield permissionDecisionReason)" "Pin owner decision D1 (a lasting direction, never done), from \"lời anh, 10-18\": \"$vi\"" "[L] decision line: the kind in words, Vietnamese text and source byte for byte"
  br owner add --kind decision --text "$vi" --owner-quote "PR chạm clusters/ thì anh merge" --where "lời anh, 10-18"; c_rc 0 "[L] written"
  gown default add --kind window --text "$t150" --owner-quote q --where "$w60" --expires 2099-01-02T22:00:00Z
  c_eq "$(hfield permissionDecisionReason)" "Grant window W1 until 01-02 22:00Z, from \"$w60\", lowers no signing: \"$t150\"" "[L] window line, the text never cut; a window with no --lower says it lowers no signing"
  R=$(nchars "$(hfield permissionDecisionReason)"); c_eq "$([ "$R" -le 283 ] && echo within)" within "[L] the longest window line is $R ≤ 283 characters"
  gown default add --kind decision --text "next one" --owner-quote q --where w
  c_has "$(hfield permissionDecisionReason)" "decision D2 (a lasting direction, never done), from" "[L] the id of an add follows the folded state"
  gown default unpin D1; c_eq "$(hfield permissionDecisionReason)" "Unpin owner decision D1: \"$vi\"" "[L] unpin line"
  gown default supersede D1 --text "The owner merges clusters/ PRs"; c_eq "$(hfield permissionDecisionReason)" 'Replace D1 (a lasting direction, never done) with: "The owner merges clusters/ PRs"' "[L] supersede line, the kind in words"
  gown default supersede D1 --text "The owner merges clusters/ PRs" --scope global
  c_eq "$(hfield permissionDecisionReason)" 'Replace D1 (a lasting direction, never done) (scope global) with: "The owner merges clusters/ PRs"' "[L] a supersede with a scope: the kind, then the scope"
  gown default supersede D1 --scope global
  c_eq "$(hfield permissionDecisionReason)" "Set the scope of owner decision D1 (a lasting direction, never done) to global, its words unchanged: \"$vi\"" "[L] a scope-only supersede: the kind in words"
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
  for v in "merge all · from: the owner" "merge all $(u 0387) fr$(u 043e)m$(u ff1a) the owner" "a · $(u 03a4)o: b" \
           "build the review page (a lasting direction, never done)" "D9 (a lasting direction, never done), from: the owner"; do
    gown default add --kind decision --text "$v" --owner-quote q --where me
    c_eq "$(hfield permissionDecisionReason)" "Pin owner decision D2 (a lasting direction, never done), from \"me\": \"$v\"" "[L] a fake label in the text stays inside its quotes, after the real source and the kind ($v)"
  done
  # the kind comes from the item's kind, never from its text: a window's text that names it gets no phrase outside its quotes
  gown default add --kind window --text "keep it open" --owner-quote q --where w --expires 2099-01-02T22:00:00Z
  br owner add --kind window --text "keep it open" --owner-quote q --where w --expires 2099-01-02T22:00:00Z; c_rc 0 "[L] instrument: W1 granted"
  gown default supersede W1 --text "a lasting direction, never done"
  c_eq "$(hfield permissionDecisionReason)" 'Replace W1 with: "a lasting direction, never done"' "[L] a window's supersede names no decision kind, whatever its text says"
  owner_ok add --kind decision --text 'a "quoted" word' --owner-quote q --where w; c_rc 1 "[L] the CLI refuses it too (rc 1)"
  gown default add --kind decision --text "a$(python3 -c 'print(chr(0x301) * 149)')" --owner-quote q --where w
  c_eq "$(hfield permissionDecision)" deny "[L] 149 combining marks on one letter (a smeared line): deny"
  owner_ok add --kind decision --text "$(python3 -c 'import unicodedata; print(unicodedata.normalize("NFD", "Quyết định của anh"))')" --owner-quote q --where w
  c_rc 0 "[L] Vietnamese in decomposed form (2 marks on a letter) is accepted"
  owner_ok add --kind decision --text "Tibetan stack ཧྐྵྨླྦྱ" --owner-quote q --where w
  c_rc 0 "[L] a Tibetan stack (6 marks) is accepted (round 2: the cap is 8)"
  local j; j=$(ownin default "$(cmdline brain owner add --kind decision --text "Quyết định của anh" --owner-quote q --where "lời anh")")
  PYTHONIOENCODING=ascii hk guard-owner "$j"                     # the hook's stdout only: the JSON is built before
  c_eq "$(hfield permissionDecisionReason)" 'Pin owner decision D4 (a lasting direction, never done), from "lời anh": "Quyết định của anh"' "[L] an ASCII-only stdout still carries a Vietnamese line in UTF-8"
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
  gown default "${ADD[@]}"; mkdir -p "$pd/stale-dir"; touch -d '@1000000000' "$pd/stale-dir"
  if can_link; then ln -s "$TMP/nowhere" "$pd/dangling"; else c_skip "[Q] a dangling link in pending/" "ln -s copies here instead of linking"; fi
  gcmd default "ls -la"; c_eq "$(recmode)" none "[Q] a stale directory and a dangling link in pending/ do not stop the void (round 3)"
  rm -rf "$pd/stale-dir" "$pd/dangling"
  R=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import brain_hook as h, brain_store as s
print(h.SWEEP_AGE >= 2 * s.RECORD_MAX_AGE)' "$BROOT/scripts"); c_eq "$R" True "[Q] the sweep age is at least twice a record's life (round 3)"
  if [ "${OS:-}" = Windows_NT ]; then
    c_skip "[Q] a marker that cannot be written leaves no record" "Windows lets a read-only folder take new files"
  else
    chmod 500 "$pd"; gown default "${ADD[@]}"; chmod 700 "$pd"
    c_eq "$(recmode)" none "[Q] a marker that cannot be written leaves no record either: the marker comes first (round 3)"
  fi
  # Windows: a pending/ that is not this account's alone (made in an elevated session) refuses the call there, naming the folder,
  # rather than a hook error the session never sees and a CLI that reports no dialog (Windows' own check stood in by one that
  # refuses pending/)
  R=$(ownin default "$(cmdline brain owner "${ADD[@]}")" | CLAUDE_CODE_SESSION_ID="$SID" python3 -c 'import json, os, sys
sys.path.insert(0, sys.argv[1])
import brain_store as s, brain_hook as h
_root = s.state_root(); s.state_root = lambda: _root   # the Linux spelling: only the order of the checks is under test
s.WINDOWS = True
s._ancestors = lambda: []                           # the walk of Windows'"'"' processes is case_win_walk'"'"'s
def private(p):
    if os.path.basename(p) == "pending":
        raise s.Refused(1, "the brain directory pending is refused: S-1-5-32-544 owns it")
s.private = private
h.guard_owner(json.load(sys.stdin))' "$BROOT/scripts" 2>&1 | python3 -c 'import json, sys
t = sys.stdin.read()
try:
    o = json.loads(t)["hookSpecificOutput"]
    print(o["permissionDecision"], "pending is refused" in o["permissionDecisionReason"])
except (ValueError, KeyError):
    print("no decision:", t.strip().splitlines()[-1:] or "")')
  c_eq "$R" "deny True" "[Q] a pending/ that is not the account's alone: the owner call is denied, naming the folder"
  c_eq "$(recmode)" none "[Q] …and no record is written"
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
case_hook_mention() {  # [F] only the words, never a brain call: silent, no record
  newp
  local c o; o=$(cmdline brain owner "${ADD[@]}")
  for c in $'cat > note.md <<\'EOF\'\nThe brain hook refuses the owner\'s note\nEOF' \
           $'cat > note.md <<EOF\n'"$o"$'\nEOF' \
           $'cat > note.md <<-"EOF"\n\tbrain owner unpin D1 is the owner\'s\n\tEOF\necho done' \
           "echo the brain's owner rule" \
           "printf '%s\n' 'brain owner unpin D1'" \
           'grep -rn "brain owner" .' \
           $'git commit -m "$(cat <<\'EOF\'\nfix(brain): the owner hook\n\nbrain owner unpin D1 is guarded; it\'s real\nEOF\n)"' \
           $'gh issue comment 562 --body-file - <<\'EOF\'\nbrain owner unpin D1\nthe owner\'s words\nEOF' \
           "gh issue create --title t --body \"brain's owner: $o\"" \
           $'echo $((1<<2)); cat <<EOF\n'"$o"$'\nEOF'; do
    gcmd default "$c"; c_eq "$OUT" "" "[F] only mentions the words, silent: $(printf '%q' "${c:0:50}")"
  done
  c_eq "$(recmode)" none "[F] no record for any of them"
}

case_hook_forms() {  # [G] every real form is still guarded
  newp
  local f c o o2 a=(owner add --kind decision --text x --owner-quote q --where w)
  for f in /opt/x/bin/brain "'/opt/a b/bin/brain'" '"/opt/a b/bin/brain"' "python3.12 '/opt/a b/scripts/brain.py'" \
           'python3 "/opt/a b/scripts/brain.py"'; do
    gcmd default "$f $(cmdline "${a[@]}")"; c_eq "$(hfield permissionDecision)" ask "[G] alone and literal, asked: $f owner add"
  done
  o=$(cmdline brain owner "${ADD[@]}")
  for c in "true && $o" \
           $'cat > n.md <<\'EOF\'\nnote\nEOF\n'"$o" \
           $'cat > n.md <<-EOF\n\tnote\n\tEOF\n'"$o" \
           $'cat > n.md <<"E O"\nbrain owner unpin D1\nE O\n'"$o" \
           $'cat <<EOF; '"$o"$'\nbody\nEOF' \
           $'cat <<A <<\'B\'\na\nA\nb\nB\n'"$o" \
           $'cat <<\\EOF\nx\nEOF\n'"$o" \
           $'echo $((1<<2))\n'"$o" \
           $'(( x = 1 << 3 ))\n'"$o" \
           $'(( x = (1+(2)) << 2 ))\n'"$o" \
           $'echo $[1<<2] ${a[1<<0]}\n'"$o" \
           $'((echo a); echo b)\ncat <<EOF\nit\'s\nEOF\n'"$o" \
           "$o"$' <<\'EOF\'\nx\nEOF' \
           "'/opt/a b/bin/brain' owner add --kind decision --text 'open --owner-quote q --where w"; do
    gcmd default "$c"; c_eq "$(hfield permissionDecision)" deny "[G] a real form not alone or not literal, denied: $(printf '%q' "${c:0:60}")"
  done
  c_eq "$(recmode)" none "[G] no record for any of them"
  # the shell runs below: a sure-positive control first (the hook asked for this very call, so the same run writes)
  sh_run() { OUT=$(cd "$P" && PATH="$BROOT/bin:$PATH" CLAUDE_CODE_SESSION_ID="$SID" bash -c "$1" 2>&1); RC=$?; }
  gcmd default "$o"; sh_run "$o"; c_rc 0 "[G] instrument: an asked call run through the shell writes"
  o2=$(cmdline brain owner add --kind decision --text "fed to a shell" --owner-quote q --where w)
  for c in "bash -c $(cmdline "$o2")" "sh -c $(cmdline "$o2")" \
           $'cat <<EOF | bash\n'"$o2"$'\nEOF' $'bash <<EOF\n'"$o2"$'\nEOF' $'sh <<-EOF\n\t'"$o2"$'\n\tEOF'; do
    gcmd default "$o2"; c_eq "$(hfield permissionDecision)" ask "[G] instrument: the bare call is asked (a fresh record)"
    gcmd default "$c"; c_eq "$OUT" "" "[G] silent: $(printf '%q' "${c:0:40}")"
    c_eq "$(recmode)" none "[G] no record, and the fresh one is void"
    sh_run "$c"; c_rc 6 "[G] the CLI it runs refuses rc 6: $(printf '%q' "${c:0:40}")"
    c_has "$OUT" "$SENTENCE" "[G] with the refusal sentence"
  done
}

case_allowlist() {  # a field shown before the text takes only characters on an allowlist
  newp
  owner_ok add --kind decision --text 'the pin to promote' --owner-quote q --where w; c_rc 0 "[A1] instrument: D1 pinned"
  local qv
  for qv in 1cd3 02f5 0660; do
    gown default add --kind decision --text 'Merge freely' --owner-quote q --where "the PR merged$(u $qv): $(u $qv)ship now"
    c_eq "$(hfield permissionDecision)" deny "[A1] U+${qv^^} in --where: guard-owner denies before it asks"
    owner_ok add --kind decision --text 'Merge freely' --owner-quote q --where "the PR merged$(u $qv): $(u $qv)ship now"
    c_rc 1 "[A1] U+${qv^^} in --where: the CLI refuses it (rc 1)"; c_has "$OUT" "U+${qv^^}" "[A1] naming the character"
    gown default promote D1 "kb/x$(u $qv).md"; c_eq "$(hfield permissionDecision)" deny "[A1] U+${qv^^} in the pointer: deny"
  done
  local w
  for w in "lời anh trong chat 31/10, khoảng 18Z" "$(python3 -c 'import unicodedata; print(unicodedata.normalize("NFD", "lời anh, Quyết định"))')" \
           "kb/decisions/2026-11-01-x_y.md" "https://example.com/o/r/a?x=1&y=2#c-3" "Tibetan ཧྐྵ, 中文 来源, ไทย"; do
    owner_ok add --kind decision --text "keep $w" --owner-quote q --where "$w"; c_rc 0 "[A1] accepted in --where: $w"
  done
  # round 1: two apostrophe-like characters pass for a `"`, and so do clicks, saltillos and vertical-line marks
  for w in "prompt 10-18$(u a78c)$(u a78c): $(u a78c)$(u a78c)Merge" "a '' b" 'a `` b' "a $(u 01c1) b" "a $(u 01c0)$(u 01c0) b" \
           "a $(u a78b) b" "a $(u 0131)$(u 030e) b" "a $(u 0237)$(u 0301) b" "a '$(u 0301)' b" \
           "a i$(u 030e) b" "a j$(u 030b) b" "a $(u 0456)$(u 030f) b"; do
    gown default add --kind decision --text 'Merge freely' --owner-quote q --where "$w"
    c_eq "$(hfield permissionDecision)" deny "[A1] round 1: '$w' in --where: deny"
  done
  owner_ok add --kind decision --text "keep the owner's" --owner-quote q --where "the owner's chat, ' and \` once"; c_rc 0 "[A1] round 1: one apostrophe or backtick at a time: accepted"
  for w in "$(u 2d49)$(u 2d4f)$(u 2d4f)$(u 2d30)" "$(python3 -c 'import unicodedata; print(unicodedata.normalize("NFD", "ἀρχή καὶ ὁ λόγος"))')" \
           "Hrvatski $(u 0201) i $(u 0061)$(u 030f)" "Pe$(u 030d)h-$(u 014d)e-j$(u 012b) chi$(u 030d)t" \
           "$(python3 -c 'import unicodedata; print(unicodedata.normalize("NFD", "Nghĩ kỹ, ìí, ỉ, ị"))')"; do
    owner_ok add --kind decision --text "keep $w" --owner-quote q --where "$w"; c_rc 0 "[A1] round 2: a script's own letters and marks accepted: $w"
  done
  # the sweep: every code point the old blocklist refused (Pi, Pf, bidi R or AL, a quote-like name) is refused now
  c_eq "$(bpy 'import sys, unicodedata
names = ("QUOTATION", "PRIME", "GERSHAYIM", "DITTO", "DOUBLE APOSTROPHE", "DOUBLE ACUTE")
old = lambda c: (unicodedata.category(c) in ("Pi", "Pf") or unicodedata.bidirectional(c) in ("R", "AL")
                 or any(n in unicodedata.name(c, "") for n in names))
miss = [hex(o) for o in range(0x110000) if not 0xD800 <= o <= 0xDFFF and old(chr(o)) and s.quote_like("a" + chr(o)) is None]
print(len(miss), miss[:5])')" "0 []" "[A1] every code point the old blocklist refused is still refused"
}

bfile() {  # bfile <path> <python expression of the list> — a batch file, as the session writes one (JSON, UTF-8)
  python3 -c 'import json, sys; open(sys.argv[1], "w", encoding="utf-8", newline="").write(json.dumps(eval(sys.argv[2]), ensure_ascii=False))' "$1" "$2"
}
bitems() {  # bitems — the ids and texts of the live owner items, in id order
  bpy 'st = s.load(s.state_dir())[1]
print(" ".join("%s=%s" % (i, it["text"]) for i, it in sorted(st["items"].items()) if it["status"] == "live" and i[0] in "GDW"))'
}
keeprec() {  # keeprec <args after owner…> — a fresh record for SID that leaves the session's other records alone (an input: the
             # brain changing between a batch's dialog and its run, which a second dialog would otherwise void)
  CLAUDE_CODE_SESSION_ID="$SID" python3 -c 'import json, os, secrets, sys, time; sys.path.insert(0, sys.argv[1]); import brain_store as s
d = s.state_dir(); rid = secrets.token_hex(16)
s._write_file(os.path.join(d, "asked", rid + ".json"), json.dumps({"id": rid, "session": sys.argv[2], "mode": "default",
              "args": sys.argv[3:], "t": time.time()}) + "\n")' "$BROOT/scripts" "$SID" "$@"
}
case_batch() {  # several owner items through one dialog, bound to the file's bytes and to the state
  newp
  bfile b.json '[["add", "--kind", "decision", "--text", "first pin", "--owner-quote", "anh nói", "--where", "chat 31/10"],
                 ["add", "--kind", "decision", "--text", "second pin", "--owner-quote", "q2", "--where", "chat 31/10", "--anchor", "run-41"]]'
  br owner batch b.json; c_rc 6 "[B] no dialog: rc 6"
  OUT=$(VIBEMAESTRO_ROLE=worker CLAUDE_CODE_SESSION_ID="$SID" "$BROOT/bin/brain" owner batch missing.json 2>&1); RC=$?
  c_rc 4 "[B] a worker: rc 4 before the file is read (a missing file is not named)"; c_hasnt "$OUT" "missing.json" "[B] the file is not named"
  gown default batch b.json
  c_eq "$(hfield permissionDecision)" ask "[B] guard-owner asks once for the whole file"
  c_eq "$(hfield permissionDecisionReason)" 'Owner batch of 2, one approval for all:
1. Pin owner decision D1 (a lasting direction, never done), from "chat 31/10": "first pin"
2. Pin owner decision D2 (a lasting direction, never done), from "chat 31/10": "second pin"' "[B] a line per item, each its single form's line, the ids as the earlier items leave them"
  br owner batch b.json; c_rc 0 "[B] the CLI writes both"
  c_has "$OUT" "pinned D1; pinned D2" "[B] and says so"
  c_eq "$(bitems)" "D1=first pin D2=second pin" "[B] both live"
  c_eq "$(grep -c '"record"' "$(sdir)/hot.jsonl")" 2 "[B] each op carries the one record"
  c_eq "$(bpy 'st = s.load(s.state_dir())[1]; print(st["items"]["D2"]["anchors"], st["items"]["D1"]["source"]["quote"])')" \
    "['run-41'] anh nói" "[B] every field as the file wrote it"
  br owner batch b.json; c_rc 6 "[B] the same run again: rc 6 (the record is spent)"
  # the file changed between the dialog and the run: edited where the dialog does not show it, swapped, items reordered
  local three='[["add", "--kind", "decision", "--text", "third pin", "--owner-quote", "q", "--where", "w"],
                ["unpin", "D1"], ["supersede", "D2", "--text", "second pin, reworded"]]'
  bfile c.json "$three"; gown default batch c.json; c_eq "$(hfield permissionDecision)" ask "[B] instrument: asked for c.json"
  bfile c.json "$(printf '%s' "$three" | sed 's/"q"/"another quote"/')"
  br owner batch c.json; c_rc 6 "[B] the owner's quote edited after the dialog (not on its line): rc 6"
  c_has "$OUT" "changed since the owner's dialog" "[B] saying the file or the brain changed"
  bfile c.json "$three"; gown default batch c.json; mv c.json c.old; bfile c.json '[["unpin", "D1"], ["unpin", "D2"]]'
  br owner batch c.json; c_rc 6 "[B] the file swapped for another after the dialog: rc 6"
  bfile c.json "$three"; gown default batch c.json
  bfile c.json '[["unpin", "D1"], ["add", "--kind", "decision", "--text", "third pin", "--owner-quote", "q", "--where", "w"],
                 ["supersede", "D2", "--text", "second pin, reworded"]]'
  br owner batch c.json; c_rc 6 "[B] the items reordered after the dialog: rc 6"
  c_eq "$(bitems)" "D1=first pin D2=second pin" "[B] nothing was written by any of the three"
  # the brain changed between the dialog and the run: the id the dialog showed is no longer the one that would be written
  bfile c.json "$three"; gown default batch c.json
  c_has "$(hfield permissionDecisionReason)" "1. Pin owner decision D3" "[B] instrument: the dialog names D3"
  keeprec add --kind decision --text "a pin in between" --owner-quote q --where w
  br owner add --kind decision --text "a pin in between" --owner-quote q --where w; c_rc 0 "[B] instrument: D3 pinned in between"
  br owner batch c.json; c_rc 6 "[B] the brain changed after the dialog (D3 taken): rc 6"
  gown default batch c.json; br owner batch c.json; c_rc 0 "[B] asked again: written"
  c_eq "$(bitems)" "D3=a pin in between D4=third pin D5=second pin, reworded" "[B] in order: D4 added, D1 unpinned, D2 superseded by D5"
  # all or none: a write that fails after the first item writes nothing, and the record stays usable
  local big; big=$(python3 -c 'print("x" * 290)')
  bfile w.json "[[\"add\", \"--kind\", \"decision\", \"--text\", \"$big %d\" % i, \"--owner-quote\", \"q\" * 590, \"--where\", \"w\"] for i in range(3)]"
  if [ "${OS:-}" = Windows_NT ]; then c_skip "[B] round 1: a log that can take one item, not three" "Git Bash cannot limit a file's size (ulimit -f)"; else
  gown default batch w.json; c_eq "$(hfield permissionDecision)" ask "[B] round 1: instrument: asked for three big items"
  local size lim; size=$(wc -c < "$(sdir)/hot.jsonl"); lim=$(( (size + 1500) / 1024 + 1 ))
  OUT=$( (trap '' XFSZ; ulimit -f "$lim"; CLAUDE_CODE_SESSION_ID="$SID" "$BROOT/bin/brain" owner batch w.json) 2>&1 ); RC=$?
  c_rc 1 "[B] round 1: the log can take one item, not three: rc 1"
  c_has "$OUT" "nothing was written" "[B] round 1: saying nothing was written"
  c_hasnt "$OUT" "run brain doctor" "[B] round 2: and not that the log may be left past its head"
  c_eq "$(bitems)" "D3=a pin in between D4=third pin D5=second pin, reworded" "[B] round 1: none of the three is live"
  br doctor; c_hasnt "$OUT" "problem" "[B] round 1: the chain and caches hold"
  br owner batch w.json; c_rc 0 "[B] round 1: the same record writes them once there is room"
  bfile u.json '[["unpin", "D6"], ["unpin", "D7"], ["unpin", "D8"]]'; gown default batch u.json; br owner batch u.json
  c_eq "$(bitems)" "D3=a pin in between D4=third pin D5=second pin, reworded" "[B] round 1: instrument: the three unpinned again"; fi
  # sizes and refusals before any dialog
  bfile one.json '[["unpin", "D3"]]'
  gown default batch one.json; c_eq "$(hfield permissionDecision)" deny "[B] a 1-item file: deny (a single item has its own form)"
  c_has "$(hfield permissionDecisionReason)" "2 to 5 owner items, not 1" "[B] saying why"
  br owner batch one.json; c_rc 1 "[B] and the CLI refuses it"
  bfile six.json '[["add", "--kind", "decision", "--text", "p%d" % i, "--owner-quote", "q", "--where", "w"] for i in range(6)]'
  gown default batch six.json; c_eq "$(hfield permissionDecision)" deny "[B] a 6-item file: deny"
  c_has "$(hfield permissionDecisionReason)" "2 to 5" "[B] naming the size"
  bfile bad.json '[["unpin", "D3"], ["add", "--kind", "decision", "--text", "x", "--owner-quote", "q", "--where", "merged᳓: ᳓ship"]]'
  gown default batch bad.json; c_eq "$(hfield permissionDecision)" deny "[B] an item the single form refuses (U+1CD3 in --where): deny"
  c_has "$(hfield permissionDecisionReason)" "item 2" "[B] naming the item"
  br owner batch bad.json; c_rc 1 "[B] and the CLI refuses it"
  bfile seq.json '[["supersede", "D3", "--text", "x"], ["unpin", "D3"]]'
  gown default batch seq.json; c_eq "$(hfield permissionDecision)" deny "[B] unpin of an item an earlier one superseded: deny (the state the earlier items leave)"
  c_has "$(hfield permissionDecisionReason)" "item 2: " "[B] naming the second item"
  local v
  for v in promote demote import backup batch; do
    bfile v.json "[[\"$v\", \"D3\", \"x\"], [\"unpin\", \"D4\"]]"
    gown default batch v.json; c_eq "$(hfield permissionDecision)" deny "[B] a $v item: deny (add, supersede and unpin only)"
    c_has "$(hfield permissionDecisionReason)" "item 1: a batch takes add, supersede and unpin" "[B] $v: saying why"
  done
  printf '[["unpin", "D3"], ["unpin", "D4"]' > broken.json
  gown default batch broken.json; c_eq "$(hfield permissionDecision)" deny "[B] a file that is not JSON: deny"
  c_has "$(hfield permissionDecisionReason)" "not JSON" "[B] saying why"
  bfile real.json '[["unpin", "D3"], ["unpin", "D4"]]'
  if can_link; then
    ln -s real.json link.json
    gown default batch link.json; c_eq "$(hfield permissionDecision)" deny "[B] FILE a symlink: deny"
    c_has "$(hfield permissionDecisionReason)" "is a symlink" "[B] saying why"
    gown default batch real.json; c_eq "$(hfield permissionDecision)" ask "[B] instrument: the regular file is asked"
    mv real.json target.json; ln -s target.json real.json
    br owner batch real.json; c_rc 1 "[B] FILE turned into a symlink after the dialog: refused"
  else c_skip "[B] FILE a symlink, before and after the dialog" "ln -s copies here instead of linking"; fi
  c_eq "$(bitems)" "D3=a pin in between D4=third pin D5=second pin, reworded" "[B] nothing written by the refusals"
  # the session's project A while the shell is in B, the file in B
  local A=$P B="$TMP/other$NP" dB
  mkdir -p "$B"; git_ -C "$B" init -q -b main; dB=$(cd "$B" && bpy 'import os; print(s.state_dir(os.getcwd()))')
  cd "$B" || return 1
  bfile b2.json '[["unpin", "D3"], ["unpin", "D4"]]'
  P=$B CLAUDE_PROJECT_DIR=$A gown default batch b2.json
  c_eq "$(hfield permissionDecision)" ask "[B] guard-owner with the shell in B for a session of A: ask"
  c_has "$(hfield permissionDecisionReason)" "Unpin owner decision D3" "[B] the dialog reads A's items"
  br owner batch b2.json; c_rc 0 "[B] the CLI in B writes A"
  c_eq "$([ -e "$dB" ] && echo made || echo none)" none "[B] B has no brain state"
  cd "$A" || return 1
  c_eq "$(bitems)" "D5=second pin, reworded" "[B] D3 and D4 unpinned in A"
}

case_batch_fresh() {  # round 2: a fresh brain's claim goes in the batch's one write, so a refused batch leaves the log empty
  newp
  if [ "${OS:-}" = Windows_NT ]; then c_skip "[B] round 2: a write that fails at once" "Git Bash cannot limit a file's size (ulimit -f)"; return; fi
  local big; big=$(python3 -c 'print("x" * 290)')
  bfile w.json "[[\"add\", \"--kind\", \"decision\", \"--text\", \"$big %d\" % i, \"--owner-quote\", \"q\" * 590, \"--where\", \"w\"] for i in range(3)]"
  gown default batch w.json; c_eq "$(hfield permissionDecision)" ask "[B] round 2: instrument: asked on a brain with no log yet"
  OUT=$( (trap '' XFSZ; ulimit -f 1; CLAUDE_CODE_SESSION_ID="$SID" "$BROOT/bin/brain" owner batch w.json) 2>&1 ); RC=$?
  c_rc 1 "[B] round 2: the write fails: rc 1"
  c_eq "$(cat "$(sdir)/hot.jsonl" 2>/dev/null | wc -l | tr -d ' ')" 0 "[B] round 2: not even the claim line was written"
  br owner batch w.json; c_rc 0 "[B] round 2: the record still writes the batch, its claim first"
  c_eq "$(head -n 1 "$(sdir)/hot.jsonl" | python3 -c 'import json, sys; print(json.loads(sys.stdin.read())["op"])')" claim "[B] round 2: the claim line opens the log"
}

case_window() {  # [W] a window's scope: what the baton runner may sign for the session that pinned it
  newp
  local exp until w9 R
  exp=$(python3 -c 'import time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 3600)))')
  until=$(python3 -c 'import sys; v = sys.argv[1]; print(v[5:10] + " " + v[11:16] + "Z")' "$exp")
  local scope=(--expires "$exp" --lower owner-acts --lower security-boundary --exclude kit:plugin-export)
  gown default add --kind window --text "Cửa sổ cho việc trong ngày" --owner-quote "việc trong ngày khỏi ký" --where "chat" "${scope[@]}"
  c_eq "$(hfield permissionDecisionReason)" "Grant window W1 until $until, from \"chat\", lowers signing for this session only: owner-acts, security-boundary; never: secrets, cluster-lane, irreversible-delete, history-rewrite, money-org, a change to the machine's permissions or to who signs; excluded: kit:plugin-export: \"Cửa sổ cho việc trong ngày\"" \
    "[W] the dialog shows what the window lowers, for this session only, what it never lowers and what the owner excludes"
  br owner add --kind window --text "Cửa sổ cho việc trong ngày" --owner-quote "việc trong ngày khỏi ký" --where "chat" "${scope[@]}"
  c_rc 0 "[W] the owner's click writes W1"
  c_eq "$(bpy 'it = s.load(s.state_dir())[1]["items"]["W1"]; print(it["lowers"], it["excludes"], it["session"])')" \
    "['owner-acts', 'security-boundary'] ['kit:plugin-export'] sA" "[W] W1 keeps its scope and the session that pinned it"
  owner_ok add --kind window --text "docs only" --owner-quote q --where w --expires "$exp"; c_rc 0 "[W] a window with no --lower: written as before"
  c_eq "$(bpy 'it = s.load(s.state_dir())[1]["items"]["W2"]; print(sorted(k for k in ("lowers", "excludes", "session") if k in it))')" "[]" \
    "[W] …with no scope and no session"
  br windows --json; c_rc 0 "[W] brain windows --json: rc 0"
  c_eq "$(printf '%s' "$OUT" | python3 -c 'import json, sys
d = json.loads(sys.stdin.read())
print([(w["id"], w.get("lowers"), w.get("session")) for w in d["windows"]], d["last_t"] is not None)')" \
    "[('W1', ['owner-acts', 'security-boundary'], 'sA'), ('W2', None, None)] True" "[W] …the live windows with their scope, and the time of the log's last op"
  br render; c_rc 0 "[W] instrument: render"
  R=$(cat "$(sdir)/hot.md")
  c_has "$R" "- W1 Cửa sổ cho việc trong ngày · lowers owner-acts, security-boundary; excludes kit:plugin-export · until $until (" "[W] the left brain shows W1's scope"
  c_has "$R" "- W2 docs only · lowers no signing · until $until (" "[W] …and that W2 lowers no signing"
  br doctor; c_has "$OUT" "hot.md matches a fresh render" "[W] doctor: the render matches"
  # what the runner would never honour: refused before the dialog, nothing written
  for r in "1|a window never lowers|--lower secrets" "1|a window never lowers|--lower money-org" "1|a window never lowers|--lower kit:bootstrap" "1|a window never lowers|--lower kit:coordinator-bootstrap" \
           "1|a window never lowers|--lower kind:settings-merge" "1|a window names a stop category|--lower fun" \
           "1|a window names a stop category|--lower kit:a/b" "1|a window names a stop category|--lower Owner-acts" \
           "1|a window names a stop category|--lower kit:" "1|names a word twice|--lower publish --lower publish" \
           "64|a window with no --lower lowers nothing|--exclude publish" "1|a window names a stop category|--lower publish --exclude fun"; do
    IFS='|' read -r rc why words <<<"$r"
    # shellcheck disable=SC2086  # the words are the case's options, split on purpose
    br owner add --kind window --text t --owner-quote q --where w --expires "$exp" $words; c_rc "$rc" "[W] $words: rc $rc"
    c_has "$OUT" "$why" "[W] …$why"
  done
  w9=(); for k in a b c d e f g h i; do w9+=(--lower "kit:k$k"); done
  br owner add --kind window --text t --owner-quote q --where w --expires "$exp" "${w9[@]}"; c_rc 1 "[W] nine --lower words: rc 1"
  br owner add --kind decision --text t --owner-quote q --where w --lower owner-acts; c_rc 64 "[W] --lower on a decision: rc 64"
  br owner add --kind window --text t --owner-quote q --where w --lower owner-acts \
     --expires "$(python3 -c 'import time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + 25 * 3600)))')"
  c_rc 1 "[W] a scoped window over 24 hours: rc 1"; c_has "$OUT" "lasts at most 24 hours" "[W] …named"
  gown default add --kind window --text t --owner-quote q --where w --expires "$exp" --lower secrets
  c_eq "$(hfield permissionDecision)" deny "[W] guard-owner denies the same, before any dialog"
  c_eq "$(bpy 'print(sorted(i for i in s.load(s.state_dir())[1]["items"] if i[0] == "W"))')" "['W1', 'W2']" "[W] …nothing else was written"
  # a supersede shows only the new text, so the scope does not go over; a close ends the window at once
  owner_ok supersede W1 --text "Cửa sổ cho việc trong ngày, trừ hạ tầng"; c_rc 0 "[W] the owner supersedes W1"
  c_eq "$(bpy 'it = s.load(s.state_dir())[1]["items"]["W3"]; print(it.get("lowers"), it.get("session"))')" "None None" "[W] …W3 has no scope: it lowers nothing"
  for k in 1 2 3 4 5; do br op add --kind now --text "done $k"; br op close "N$k" --reason "done $k"; done
  br op add --kind now --text "one more"; br op close N6 --reason x
  c_has "$OUT" "retirement budget" "[W] instrument: the session's retirement budget is spent"
  br op close W2 --reason "the owner said stop"; c_rc 0 "[W] op close W2: ends it at once, no dialog, with the budget spent"
  c_eq "$(bpy 'st = s.load(s.state_dir())[1]; print(len([r for r in st["retirements"] if r["session"] == "sA"]))')" 5 \
    "[W] …and spends none of it"
  br windows --json
  c_eq "$(printf '%s' "$OUT" | python3 -c 'import json, sys; print([w["id"] for w in json.loads(sys.stdin.read())["windows"]])')" "['W3']" \
    "[W] …brain windows lists W3 only"
  local later
  later=$(bpy 'import time
t = s.now_iso(time.time() + 7200)
with s.locked(s.state_dir()):
    s.append(s.state_dir(), s.verify(s.state_dir())[0], {"op": "claim", "t": t, "by": s.by(), "takeover": False})
print(t)')   # an op from a clock two hours ahead, chained as a write chains it: the test's input, not a break
  br op add --kind now --text "at the clock behind"; c_rc 0 "[W] instrument: a later op at the clock behind"
  br windows --json
  c_eq "$(printf '%s' "$OUT" | python3 -c 'import json, sys; print(json.loads(sys.stdin.read())["last_t"])')" "$later" \
    "[W] brain windows: last_t is the newest op time, not the last op's"
  printf '{"seq": 99}\n' >> "$(sdir)/hot.jsonl"   # a line appended by hand: the test's input, not a break
  OUT=$(CLAUDE_CODE_SESSION_ID="$SID" capped "$BROOT/bin/brain" windows --json 2>&1); RC=$?
  c_rc 5 "[W] a broken chain: brain windows refuses, rc 5"
}

for c in case_window case_batch_fresh case_batch case_allowlist case_hook_mention case_hook_forms case_hook_project case_hook_ask case_hook_hosts case_hook_launchers case_hook_deny case_hook_next case_hook_void case_hook_line case_hook_literal case_hook_answerer case_hook_switch case_parenthome case_nlname case_isolation case_win_walk case_homes case_rawname case_grammar2 case_answerer2 case_grammar case_norecord case_mismatch case_used case_void case_fresh case_verbs case_result_text case_owner_budget case_chars case_answerer case_worker; do
  run_case $c; done
cd "$TMP" || exit 1

summary
