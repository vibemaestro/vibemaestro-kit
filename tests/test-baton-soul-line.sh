#!/bin/bash
# =============================================================================
# kit:soul-line: one SOUL line added to or removed from a file, only as an owner step of the project's brain names it, on fake
# machines
# =============================================================================
# Run: bash tests/test-baton-soul-line.sh
#
# A machine is a scratch HOME with its own Claude Code directory, state directory (XDG_STATE_HOME) and a git project, the plugin
# under test in its plugin cache with a registry entry, the launcher installed and the baton mode auto. The brain's log is
# written by hand at the place vibemaestro-brain keeps it for the project (brain_store.state_dir), one owner op per step, as the
# brain writes it after the owner's dialog. Families:
#   [A] add: go (Stops none, mode auto) writes `- [S14] text` after the last SOUL line, every other byte kept, the file's mode
#       kept, a CRLF file gets a CRLF line; the step is spent: the same call again is refused, nothing written
#   [R] refused at rehearse, nothing written: no step; a step for another code, another action, another text, another file; a
#       step with no owner dialog; the file through a link; add when the code has a line; remove when the line's text differs;
#       a text that holds a second code; the engine called with a log path never reached (it reads the project's own)
#   [D] remove: exactly that line goes, every other byte kept
#   [W] the file changed between the plan and the write: refused, nothing written, the step still unused
#   [U] undo after the write: the bytes back, the step free again (a new run uses it)
#   [P] the engine finds the brain's log where vibemaestro-brain keeps it, from the project and from a linked worktree of it
#   [X] attacks: an older step after a newer one for the code (its marker deleted by hand): refused; remove of a line that holds
#       the code but is not `- [S14] text`: refused; a line holding U+2028 is never split; a FIFO in the file's place: refused
#       at once; a newer demote of the code with no SOUL line kills the older add step; a FIFO at the lock path does not
#       hold the run; the file gone between the plan and the write: refused, the step not spent
# Assertions read exit codes, files and sha256; of the output only REFUSE lines and the plan line.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
# shellcheck source=fixtures/ports.sh
. "$HERE/fixtures/ports.sh"
# shellcheck source=fixtures/baton-owner.sh
. "$HERE/fixtures/baton-owner.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
BRAIN="$SRC_ROOT/plugins/vibemaestro-brain/scripts"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
export PYTHONDONTWRITEBYTECODE=1
H0=$(tree_hash "$SRC_ROOT")
K=kit:soul-line

OUT="$TMP/out"; M=""; MP=""; SEQ=0
sha_of() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"; }
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
# machine — a new fake machine in $M: the plugin in its cache ($MP), the launcher, mode auto, a git project with a SOUL file
machine() {
  local base
  M="$(fresh)/m"; base="$M/home/.claude/plugins/cache/vibemaestro"; SEQ=0
  mkdir -p "$M/state" "$M/proj" "$base/vibemaestro-sdlc"
  MP="$base/vibemaestro-sdlc/0.3.1"; cp -R "$PLUGIN" "$MP"
  grep -q '^LINEAGE = False ' "$MP/scripts/baton.py" || baton_isolate "$MP"
  printf '{"version": 2, "plugins": {"vibemaestro-sdlc@vibemaestro": [{"installPath": "%s"}]}}\n' "$MP" > "$M/home/.claude/plugins/installed_plugins.json"
  b permissions --install-launcher >/dev/null
  baton_set_mode "$M/state" auto
  git_ -C "$M/proj" init -q -b main
  F="$M/proj/CLAUDE.md"
  printf '# Shared rules\n\nIntro text.\n\n- [S07] one review round\n- [S08] no self-merge\n\n## Notes\nThe end.\n' > "$F"
}
# b <baton args...> — rc of the machine's own baton.py, run from its project (or $2 of `at`); the output is in $OUT
b() {
  ( cd "${WD:-$M/proj}" && cenv HOME="$M/home" CLAUDE_CONFIG_DIR="$M/home/.claude" XDG_STATE_HOME="$M/state" CLAUDE_PROJECT_DIR="$M/proj" \
      CLAUDE_CODE_SESSION_ID=s-coord python3 "$MP/scripts/baton.py" "$@" ) > "$OUT" 2>&1
  echo $?
}
# gate <args...> — rc of the machine's own engine, called directly as a session could; the output is in $OUT
gate() {
  ( cd "${WD:-$M/proj}" && cenv HOME="$M/home" XDG_STATE_HOME="$M/state" python3 -I -B "$MP/gates/soul_line.py" "$@" ) > "$OUT" 2>&1
  echo $?
}
# logdir [dir] — where vibemaestro-brain keeps the log of the project `dir` stands in (its own code answers)
logdir() {
  ( cd "${1:-$M/proj}" && cenv HOME="$M/home" XDG_STATE_HOME="$M/state" python3 -c 'import sys, os; sys.path.insert(0, sys.argv[1])
import brain_store as s; print(s.state_dir(os.getcwd()))' "$BRAIN" )
}
# step <action> <code> <text> [file] [asked: true|false] — one owner op carrying soul_line, appended to the brain's log
step() {
  local d; d=$(logdir); mkdir -p "$d"; SEQ=$((SEQ + 1))
  python3 - "$d/hot.jsonl" "$SEQ" "$1" "$2" "$3" "${4:-$F}" "${5:-true}" <<'PY'
import hashlib, json, sys
log, seq, action, code, text, path, asked = sys.argv[1:8]
op = {"op": "owner-promote" if action == "add" else "owner-add", "seq": int(seq), "t": "2026-11-14T00:00:%02dZ" % int(seq),
      "confirm": {"asked": asked == "true", "mode": "default", "record": "r%s" % seq},
      "soul_line": {"code": code, "action": action, "text": text, "file": path, "sha": hashlib.sha256(text.encode()).hexdigest()}}
op.update({"id": "D%s" % seq, "pointer": "CLAUDE.md [%s]" % code} if action == "add" else {"item": {"id": "D%s" % seq}})
open(log, "a").write(json.dumps(op) + "\n")
PY
}
go_() { b go "$K" --file "${4:-$F}" --code "$1" --action "$2" --text "$3"; }   # go_ <code> <action> <text> [file]

fam_add() {
  local s m
  machine; chmod 640 "$F"; step add S14 "one owner, one signature"
  s=$(sha_of "$F")
  eq "$(go_ S14 add "one owner, one signature")" 0 "[A] go: rc 0 (Stops none, mode auto: the session signs)"
  eq "$(cat "$F")" "$(printf '# Shared rules\n\nIntro text.\n\n- [S07] one review round\n- [S08] no self-merge\n- [S14] one owner, one signature\n\n## Notes\nThe end.')" \
     "[A] the line sits after the last SOUL line, every other line kept"
  eq "$(mode_of "$F")" 640 "[A] …the file's mode kept"
  s=$(sha_of "$F")
  eq "$(go_ S14 add "one owner, one signature")" 1 "[A] the same call again: refused (rc 1)"
  has "$(cat "$OUT")" "REFUSE" "[A] …with a REFUSE line"
  eq "$(sha_of "$F")" "$s" "[A] …nothing written"
  step add S15 "a second rule"; eq "$(go_ S15 add "a second rule")" 0 "[A] a second step: rc 0"
  eq "$(sed -n '8p' "$F")" "- [S15] a second rule" "[A] …after the line written before"
  machine; printf '# Rules\r\n- [S07] one review round\r\n' > "$F"; step add S14 "crlf"
  eq "$(go_ S14 add crlf)" 0 "[A] a CRLF file: rc 0"
  eq "$(od -c "$F" | tr -s ' ' | tr -d '\n')" "$(printf '# Rules\r\n- [S07] one review round\r\n- [S14] crlf\r\n' | od -c | tr -s ' ' | tr -d '\n')" \
     "[A] …the new line ends in CRLF, every byte else kept"
  machine; printf 'no newline at the end' > "$F"; step add S14 "appended"
  eq "$(go_ S14 add appended)/$(cat "$F")" "0/$(printf 'no newline at the end\n- [S14] appended')" "[A] no SOUL line yet, no final newline: appended on a line of its own"
}

fam_refused() {
  local s
  machine; s=$(sha_of "$F")
  eq "$(go_ S14 add "one owner")" 1 "[R] no owner step: refused"; has "$(cat "$OUT")" "no brain log for this project" "[R] …says so (no brain log at all)"
  step add S14 "one owner"
  eq "$(go_ S15 add "one owner")" 1 "[R] a step for another code: refused"
  has "$(cat "$OUT")" "no owner step of this project's brain names add [S15]" "[R] …says which step is missing"
  eq "$(go_ S14 remove "one owner")" 1 "[R] another action: refused"
  eq "$(go_ S14 add "one owner, changed")" 1 "[R] another text: refused"
  printf 'x\n' > "$M/proj/OTHER.md"
  eq "$(go_ S14 add "one owner" "$M/proj/OTHER.md")" 1 "[R] another file: refused"
  ln -s "$F" "$M/proj/link.md"
  eq "$(go_ S14 add "one owner" "$M/proj/link.md")" 1 "[R] the file through a link: refused"
  eq "$(sha_of "$F")/$(cat "$M/proj/OTHER.md")" "$s/x" "[R] …nothing written to either file"
  step add S16 "no dialog" "$F" false
  eq "$(go_ S16 add "no dialog")" 1 "[R] a step with no owner dialog behind it: refused"
  step add S07 "one review round"
  eq "$(go_ S07 add "one review round")" 1 "[R] add for a code that has a line: refused"
  step remove S08 "self-merge allowed"
  eq "$(go_ S08 remove "self-merge allowed")" 1 "[R] remove when the line's text differs: refused"
  has "$(cat "$OUT")" "is not the line the owner saw" "[R] …says so"
  step add S17 "see [S07] too"
  eq "$(go_ S17 add "see [S07] too")" 1 "[R] a text naming a second code: refused"
  eq "$(sha_of "$F")" "$s" "[R] the file unchanged through every refusal"
  # the engine reads the project's own log: a log elsewhere is never reached
  mkdir -p "$M/elsewhere"; ( cd "$M/elsewhere" && git_ init -q )
  eq "$(WD=$M/elsewhere gate plan --file "$F" --code S14 --action add --text "one owner")" 3 "[R] from another project: no step (rc 3)"
}

fam_remove() {
  machine; step remove S07 "one review round"
  eq "$(go_ S07 remove "one review round")" 0 "[D] remove: rc 0"
  eq "$(cat "$F")" "$(printf '# Shared rules\n\nIntro text.\n\n- [S08] no self-merge\n\n## Notes\nThe end.')" "[D] exactly that line is gone"
}

fam_moved() {
  local seal s
  machine; step add S14 "one owner"
  eq "$(b rehearse "$K" --file "$F" --code S14 --action add --text "one owner")" 0 "[W] rehearse: rc 0"
  seal=$(sed -n 's/^seal \([^ ]*\) .*/\1/p' "$OUT")
  eq "$(b sign --by coordinator-auto --seal "${seal:-none}" "$K" --file "$F" --code S14 --action add --text "one owner")" 0 "[W] signed"
  printf 'a line the owner added by hand\n' >> "$F"; s=$(sha_of "$F")
  b run "$K" --file "$F" --code S14 --action add --text "one owner" >/dev/null
  eq "$(sha_of "$F")" "$s" "[W] the file changed after the plan: the run writes nothing"
  eq "$(ls "$M/state/vibemaestro/baton/records" 2>/dev/null | grep -c '\.used$')" 0 "[W] …and the step is still unused"
  eq "$(go_ S14 add "one owner")" 0 "[W] a new go uses the step on the file as it is now"
}

fam_undo() {
  local s plan
  machine; step add S14 "one owner"; s=$(sha_of "$F")
  eq "$(gate plan --file "$F" --code S14 --action add --text "one owner")" 0 "[U] the engine plans the add"
  plan="$TMP/plan.undo"
  printf '%s, engine sha256 %s\n' "$(cat "$OUT")" "$(sha_of "$MP/gates/soul_line.py")" > "$plan"
  eq "$(gate do --expect-plan "$plan" --file "$F" --code S14 --action add --text "one owner")" 0 "[U] the write, under that plan"
  eq "$(gate postcheck --file "$F" --code S14 --action add --text "one owner")" 0 "[U] post-check: rc 0"
  eq "$(gate plan --file "$F" --code S14 --action add --text "one owner")" 3 "[U] the step is spent: no new plan"
  eq "$(gate undo --expect-plan "$plan" --file "$F" --code S14 --action add --text "one owner")" 0 "[U] undo: rc 0"
  eq "$(sha_of "$F")" "$s" "[U] …the bytes back"
  eq "$(gate postcheck --file "$F" --code S14 --action add --text "one owner")" 1 "[U] post-check now: rc 1"
  eq "$(go_ S14 add "one owner")" 0 "[U] the step is free again: a new run uses it"
  printf '%s, engine sha256 %s\n' "another plan" "x" > "$plan.other"
  eq "$(gate do --expect-plan "$plan.other" --file "$F" --code S15 --action add --text "x")" 3 "[U] a write under a plan that is not this one: refused"
}

fam_path() {
  machine
  eq "$(cd "$M/proj" && cenv HOME="$M/home" XDG_STATE_HOME="$M/state" python3 -c 'import sys, os; sys.path.insert(0, sys.argv[1]); import soul_line as g; print(g.brain_dir(os.getcwd()))' "$MP/gates")" \
     "$(logdir)" "[P] the engine's log place is the brain's, from the project"
  git_ -C "$M/proj" add -A; git_ -C "$M/proj" commit -q -m init; git_ -C "$M/proj" worktree add -q "$M/wt"
  eq "$(cd "$M/wt" && cenv HOME="$M/home" XDG_STATE_HOME="$M/state" python3 -c 'import sys, os; sys.path.insert(0, sys.argv[1]); import soul_line as g; print(g.brain_dir(os.getcwd()))' "$MP/gates")" \
     "$(logdir "$M/wt")" "[P] …and from a linked worktree, the same as the brain's"
  eq "$(logdir "$M/wt")" "$(logdir)" "[P] …which is the project's one brain"
}

fam_attack() {
  local s
  machine; step add S14 "one owner"; eq "$(go_ S14 add "one owner")" 0 "[X] the owner's add: rc 0"
  step remove S14 "one owner"; eq "$(go_ S14 remove "one owner")" 0 "[X] the owner's remove: rc 0"
  rm -f "$M/state/vibemaestro/baton/records/"soul-line-step-*.used; s=$(sha_of "$F")
  eq "$(go_ S14 add "one owner")" 1 "[X] the add again after every marker is deleted: refused"
  has "$(cat "$OUT")" "the owner's newest step for [S14] is remove" "[X] …only the newest step counts"
  eq "$(sha_of "$F")" "$s" "[X] …the removed line stays removed"
  machine; printf '# Rules\nNever push to main without the owner. Also [S14] be kind\n' > "$F"; s=$(sha_of "$F")
  step remove S14 "be kind"; eq "$(go_ S14 remove "be kind")" 1 "[X] remove of a line that is not \`- [S14] text\`: refused"
  eq "$(sha_of "$F")" "$s" "[X] …the owner's other words stay"
  machine; printf -- '- [S13] a\xe2\x80\xa8tail\n' > "$F"; step add S14 "after"
  eq "$(go_ S14 add after)" 0 "[X] add after a line holding U+2028: rc 0"
  eq "$(od -c "$F" | tr -s ' ' | tr -d '\n')" "$(printf -- '- [S13] a\xe2\x80\xa8tail\n- [S14] after\n' | od -c | tr -s ' ' | tr -d '\n')" \
     "[X] …that line kept whole, the new line after it"
  machine; rm -f "$F"; mkfifo "$F"; step add S14 "fifo"
  eq "$(PLANT_CAP_SECS=30 capped gate plan --file "$F" --code S14 --action add --text fifo)" 3 "[X] a FIFO in the file's place: refused at once (rc 3)"
  # a newer owner step about S14 with no SOUL line (the code demoted) kills the older add
  machine; step add S14 "keep it"
  python3 - "$(logdir)/hot.jsonl" <<'PY'
import json, sys
open(sys.argv[1], "a").write(json.dumps({"op": "owner-add", "seq": 99, "t": "2026-11-14T01:00:00Z", "confirm": {"asked": True},
                                         "item": {"id": "D9", "ext": {"x": {"demoted_from": "S14"}}}}) + "\n")
PY
  eq "$(go_ S14 add "keep it")" 1 "[X] a newer demote of S14 with no SOUL line: the older add is refused"
  has "$(cat "$OUT")" "the owner's newest step for [S14] carries no SOUL line" "[X] …says why"
  # a FIFO at the lock path: the run does not hang
  machine; step add S14 "locked"; mkdir -p "$M/state/vibemaestro/baton/records"
  mkfifo "$M/state/vibemaestro/baton/records/soul-line-$(python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:16])' "$F").last.lock"
  s=$(sha_of "$F")
  eq "$(PLANT_CAP_SECS=60 capped go_ S14 add locked)" 4 "[X] a FIFO at the lock path: the run fails at once and is undone (rc 4), no hang"
  eq "$(sha_of "$F")" "$s" "[X] …nothing written"
  # the file gone between the plan and the write: the step is not spent
  machine; step add S14 "gone"
  gate plan --file "$F" --code S14 --action add --text gone >/dev/null
  printf '%s, engine sha256 %s\n' "$(cat "$OUT")" "$(sha_of "$MP/gates/soul_line.py")" > "$TMP/plan.gone"
  cp "$F" "$TMP/keep.md"; rm "$F"
  eq "$(gate do --expect-plan "$TMP/plan.gone" --file "$F" --code S14 --action add --text gone)" 3 "[X] the file gone at the write: refused (rc 3)"
  cp "$TMP/keep.md" "$F"
  eq "$(gate plan --file "$F" --code S14 --action add --text gone)" 0 "[X] …and the step still plans: it was not spent"
}

echo "== kit:soul-line =="
fam_add; fam_refused; fam_remove; fam_moved; fam_undo; fam_path; fam_attack
eq "$(tree_hash "$SRC_ROOT")" "$H0" "the repository tree is unchanged by the suite"
summary
