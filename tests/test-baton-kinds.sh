#!/bin/bash
# =============================================================================
# `baton new <name> --from <kind>`: the four ready kinds of templates/baton-kinds/, through baton.py
# =============================================================================
# Run: bash tests/test-baton-kinds.sh
#
# Offline, no real host, cluster or settings file: a fake `ssh` and a fake `kubectl` on PATH run the program they are given
# locally (`bash -s` on their stdin) and answer the reads a kind makes (the API server, a pod's uid); the settings file and the
# directories are in the scratch tree.
#   [N] new --from: each kind is written, passes check as generated and is valid bash; an unknown kind, a missing value: rc 64
#   [I] install-file: into a read-only directory, the plan carries the sha and the mode; run, post-check; a failed post-check
#       is undone (the file gone, the mode back); a target with other bytes is refused
#   [S] settings-merge: adds rules, removes none; backup and run record; undo restores byte for byte through the record, and
#       leaves a file that changed since (exit 5)
#   [R] remote-exec: over the fake ssh; the plan carries the host's own name; a host that does not answer is printed first
#   [K] kubectl-exec: over the fake kubectl; the plan carries context, API server and pod uid; Stops cluster-lane (go: exit 8);
#       a server other than the one the context names is refused
#   [G] ci-rerun-failed: over a fake gh (tests/fixtures/baton_kinds_gh.py); record, rerun, the next attempt; undo cancels it
#   [C] kind:<name>: install-file, settings-merge and ci-rerun-failed run with no script written; other names rc 64;
#       the binding names the kinds directory; a link on a predictable temp name is never written through
#   [A] a value naming a Claude Code settings file (an argument or a Param, any spelling) makes a Stops: none call the owner's;
#       look-alikes stay none; a pending coordinator-auto signature is refused at run; kind:settings-merge reads as before
#   [D] the repo-wide grep for Bash that embeds Python prints 0 once `templates/baton-kinds/` is a recorded exception
#   [X] planted breaks: each family goes red on a plugin copy with one break in a kind or in baton.py
# =============================================================================
set -uo pipefail
# the owner's-dialog check of baton.py reads the HOME of every ancestor from its initial environment, which forked subshells share:
# start again without the launcher's (clean_env then points HOME into the scratch tree; the user base is pinned first)
if [ -z "${ACCOUNT_HOME_REEXEC:-}" ]; then
  export PYTHONUSERBASE="${PYTHONUSERBASE:-$(python3 -m site --user-base 2>/dev/null)}"
  exec env -u CLAUDE_CONFIG_DIR ACCOUNT_HOME_REEXEC=1 HOME=/nonexistent bash "$0" "$@"
fi
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
# shellcheck source=fixtures/ports.sh
. "$HERE/fixtures/ports.sh"
# shellcheck source=fixtures/baton-owner.sh
. "$HERE/fixtures/baton-owner.sh"
# shellcheck source=fixtures/account-home.sh
. "$HERE/fixtures/account-home.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT    # an input copy is read-only (0400 in a 0500 directory)
clean_env "$TMP"
export PYTHONDONTWRITEBYTECODE=1
export BATON_POSTCHECK_WAITS="0 0 0 0"   # a failed post-check is undone at once
H0=$(tree_hash "$SRC_ROOT")
KINDS="install-file settings-merge remote-exec kubectl-exec ci-rerun-failed"

# the fakes: ssh <options> <host> <command…> runs the command here; host `down` does not answer. kubectl answers
# `config view` with an API server URL, `get pod <p>` with a uid (pod `gone`: NotFound), and runs what follows `exec … --`.
FB="$TMP/fakebin"; mkdir -p "$FB"
cat > "$FB/ssh" <<'EOF'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do
  case "$1" in
    -o|-p|-i|-l|-F) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
host=$1; shift
printf 'ssh %s %s\n' "$host" "$*" >> "$FAKE_LOG"
if [ "$host" = down ]; then echo "ssh: connect to host down port 22: Connection refused" >&2; exit 255; fi
exec bash -c "$*"
EOF
cat > "$FB/kubectl" <<'EOF'
#!/usr/bin/env bash
printf 'kubectl %s\n' "$*" >> "$FAKE_LOG"
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --context|-n|--namespace) shift 2 ;;
    --context=*|--namespace=*) shift ;;
    --) shift; exec "$@" ;;
    *) args+=("$1"); shift ;;
  esac
done
case "${args[0]:-} ${args[1]:-}" in
  "config view") printf 'https://api.fake.test:6443' ;;
  "get pod")
    if [ "${args[2]:-}" = gone ]; then echo "Error from server (NotFound): pods \"gone\" not found" >&2; exit 1; fi
    printf 'uid-%s-0001' "${args[2]}" ;;
  *) echo "fake kubectl: unexpected $*" >&2; exit 2 ;;
esac
EOF
printf '#!/bin/sh\nexec python3 -B "%s" "$@"\n' "$HERE/fixtures/baton_kinds_gh.py" > "$FB/gh"
chmod +x "$FB/ssh" "$FB/kubectl" "$FB/gh"
PATH="$FB:$PATH"; export PATH

BT_OUT="$TMP/bt.out"; ST=""
# bt <plugin> <dir> <baton args...> — rc of baton run from <dir> with the state in $ST; its output is in $BT_OUT
# a `sign --by owner` first goes through the plugin's guard hook (owner_asked), as in a session whose owner clicks the dialog
bt() {
  local p=$1 d=$2; shift 2
  [ "${1:-} ${2:-} ${3:-}" = "sign --by owner" ] && owner_asked "$p" "$d" "$ST" s-owner "${@:2}" >/dev/null
  [ "${1:-}" = mode ] && [ $# -gt 1 ] && mode_asked "$p" "$d" "$ST" s-owner "${@:2}" >/dev/null
  ( cd "$d" && XDG_STATE_HOME="$ST" CLAUDE_CODE_SESSION_ID=s-owner FAKE_LOG="$d/fake.log" FAKE_GH_WORLD="$d/gh.json" python3 "$p/scripts/baton.py" "$@" ) > "$BT_OUT" 2>&1; echo $?
}
# sg <plugin> <dir> <script> [args...] — rehearse to read the seal, sign it as owner; the rc of sign
sg() {
  local p=$1 d=$2 seal; shift 2
  seal=$( ( cd "$d" && XDG_STATE_HOME="$ST" FAKE_LOG="$d/fake.log" FAKE_GH_WORLD="$d/gh.json" python3 "$p/scripts/baton.py" rehearse "$@" ) 2>/dev/null \
          | sed -n 's/^seal \([^ ]*\) .*/\1/p')
  bt "$p" "$d" sign --by owner --seal "${seal:-none}" "$@"
}
# kind_in <plugin> <dir> <kind> — `baton new t-<kind> --from <kind>` into <dir>; prints the script's path
kind_in() { bt "$1" "$2" new "t-$3" --from "$3" --dir "$2" >/dev/null; printf '%s' "$2/t-$3.sh"; }
sha_of() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"; }
mode_of() { python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])' "$1"; }
# fail_postcheck <script> — the post-check fails after doing what <line> says, so run must undo
fail_postcheck() { python3 - "$1" "${2:-}" <<'PY'
import re, sys
p, extra = sys.argv[1], sys.argv[2]
t = open(p).read()
t, n = re.subn(r"\npostcheck\(\) \{\n", "\npostcheck() {\n  %s\n  return 1\n" % (extra or "true"), t, count=1)
assert n == 1, "no postcheck() in " + p
open(p, "w").write(t)
PY
}

fam_kinds_new() {
  local P=$1 W k f
  ST="$(fresh)/state"; W=$(fresh)
  for k in $KINDS; do
    eq "$(bt "$P" "$W" new "t-$k" --from "$k" --dir "$W")" 0 "[N] new t-$k --from $k: rc 0"
    f="$W/t-$k.sh"
    eq "$(bt "$P" "$W" check "$f")" 0 "[N] $k passes check as generated"
    eq "$(bash -n "$f"; echo $?)" 0 "[N] $k is valid bash"
    hasnt "$(cat "$f")" "__NAME__" "[N] $k: the name is filled in"
  done
  eq "$(bt "$P" "$W" new t-x --from no-such-kind --dir "$W")" 64 "[N] an unknown kind: rc 64"
  has "$(cat "$BT_OUT")" "install-file" "[N] …the message lists the kinds"
  eq "$(bt "$P" "$W" new t-y --from ../baton-script --dir "$W")" 64 "[N] a kind with a path: rc 64"
  eq "$(bt "$P" "$W" new t-z --from --dir "$W")" 64 "[N] --from without a kind: rc 64"
  [ ! -e "$W/t-x.sh" ] && [ ! -e "$W/t-y.sh" ] && ok "[N] …nothing written" || bad "[N] …nothing written"
  eq "$(bt "$P" "$W" new t-install-file --from install-file --dir "$W")" 6 "[N] an existing file: rc 6"
}

fam_kind_install() {
  local P=$1 W f src dir dm
  ST="$(fresh)/state"; W=$(fresh); f=$(kind_in "$P" "$W" install-file)
  src="$W/tool.sh"; printf '#!/bin/sh\necho tool\n' > "$src"; dir="$W/ro"; mkdir -p "$dir"; chmod 555 "$dir"
  dm=$(mode_of "$dir")   # 555, or 2555 where new directories inherit setgid (a CI runner): the mode read before is the reference
  eq "$(bt "$P" "$W" rehearse "$f" "$src" "$dir")" 0 "[I] rehearse into a read-only directory: rc 0"
  has "$(cat "$BT_OUT")" "PLAN install $dir/tool.sh sha256 $(sha_of "$src")" "[I] …the plan carries the target and the source sha256"
  has "$(cat "$BT_OUT")" "directory mode $dm" "[I] …and the directory's mode read before"
  [ ! -e "$dir/tool.sh" ] && ok "[I] …rehearse wrote nothing" || bad "[I] …rehearse wrote nothing"
  eq "$(sg "$P" "$W" "$f" "$src" "$dir")" 0 "[I] sign: rc 0"
  eq "$(bt "$P" "$W" run "$f" "$src" "$dir")" 0 "[I] run and post-check: rc 0"
  eq "$(sha_of "$dir/tool.sh")" "$(sha_of "$src")" "[I] …the bytes are the source's"
  eq "$(mode_of "$dir/tool.sh")/$(mode_of "$dir")" "444/$dm" "[I] …the file is read-only, the directory's mode is back"
  chmod 755 "$dir"; rm -f "$dir/tool.sh"; chmod 555 "$dir"
  fail_postcheck "$f"
  eq "$(sg "$P" "$W" "$f" "$src" "$dir")" 0 "[I] sign a copy whose post-check fails: rc 0"
  eq "$(bt "$P" "$W" run "$f" "$src" "$dir")" 4 "[I] …run: rc 4, undone"
  [ ! -e "$dir/tool.sh" ] && ok "[I] …undo removed the file" || bad "[I] …undo removed the file"
  eq "$(mode_of "$dir")" "$dm" "[I] …and put the directory's mode back"
  chmod 755 "$dir"; printf 'other\n' > "$dir/tool.sh"; chmod 555 "$dir"
  eq "$(bt "$P" "$W" rehearse "$f" "$src" "$dir")" 1 "[I] a target with other bytes: rehearse rc 1"
  has "$(cat "$BT_OUT")" "REFUSE" "[I] …refused, never overwritten"
  eq "$(cat "$dir/tool.sh")" "other" "[I] …the other bytes are still there"
  chmod 755 "$dir"
}

fam_kind_settings() {
  local P=$1 W f s r before
  ST="$(fresh)/state"; W=$(fresh); f=$(kind_in "$P" "$W" settings-merge)
  s="$W/settings.json"; r="$W/rules.json"
  printf '{\n  "model": "x",\n  "permissions": {\n    "allow": ["Bash(ls:*)"],\n    "deny": ["Edit(//x/**)"]\n  }\n}\n' > "$s"
  printf '{"allow": ["Bash(ls:*)", "Bash(cat:*)"], "ask": ["Bash(rm:*)"]}\n' > "$r"
  before=$(sha_of "$s"); cp "$s" "$W/settings.before"
  # a backup already there for this path and these bytes (kept for the owner, who then put the file back), read-only
  mkdir -p "$ST/vibemaestro/baton/records"; cp "$s" "$ST/vibemaestro/baton/records/t-settings-merge-$(pk "$s")-$before.json"
  chmod 444 "$ST/vibemaestro/baton/records/t-settings-merge-$(pk "$s")-$before.json"
  eq "$(bt "$P" "$W" rehearse "$f" "$s" "$r")" 0 "[S] rehearse: rc 0"
  has "$(cat "$BT_OUT")" "PLAN backup $s sha256 $before to" "[S] …the plan backs the file up by its sha256"
  has "$(cat "$BT_OUT")" 'PLAN merge allow +1 ["Bash(cat:*)"], ask +1 ["Bash(rm:*)"], deny +0 into '"$s" "[S] …adds only the missing rules, each named in the plan"
  eq "$(sha_of "$s")" "$before" "[S] …rehearse wrote nothing"
  eq "$(sg "$P" "$W" "$f" "$s" "$r")" 0 "[S] sign (Stops security-boundary: the owner): rc 0"
  eq "$(bt "$P" "$W" run "$f" "$s" "$r")" 0 "[S] run and post-check: rc 0"
  eq "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); p=d["permissions"]; print(d["model"], p["allow"], p["ask"], p["deny"])' "$s")" \
     "x ['Bash(ls:*)', 'Bash(cat:*)'] ['Bash(rm:*)'] ['Edit(//x/**)']" "[S] …rules added, none removed, the rest kept"
  eq "$(find "$ST/vibemaestro/baton/records" -name 't-settings-merge-*.last' | wc -l | tr -d ' ')" 1 "[S] …the run record is in the state directory"
  has "$(cat "$ST"/vibemaestro/baton/runs/*-t-settings-merge-*.log)" "DO backup $s sha256 $before to" "[S] control: the run wrote the backup"
  eq "$(nbackups t-settings-merge)" 0 "[S] …the backup is gone once the run held (only its undo needs it)"
  [ ! -e "$ST/vibemaestro/baton/records/t-settings-merge-$(pk "$s")-$before.json" ] && ok "[S] …the one already there for this path and bytes, read-only, was taken over and went too" \
    || bad "[S] …the one already there for this path and bytes, read-only, was taken over and went too"
  cp "$W/settings.before" "$s"; fail_postcheck "$f"
  eq "$(sg "$P" "$W" "$f" "$s" "$r")" 0 "[S] sign a copy whose post-check fails: rc 0"
  eq "$(bt "$P" "$W" run "$f" "$s" "$r")" 4 "[S] …run: rc 4, undone"
  eq "$(sha_of "$s")" "$before" "[S] …undo restored the settings byte for byte through the run record"
  eq "$(nbackups t-settings-merge)" 0 "[S] …and the backup is gone once undo put the file back"
  cp "$W/settings.before" "$s"
  bt "$P" "$W" new t-settings-merge-b --from settings-merge --dir "$W" >/dev/null; f="$W/t-settings-merge-b.sh"
  fail_postcheck "$f" "printf ' ' >> \"\$SETTINGS\""
  eq "$(sg "$P" "$W" "$f" "$s" "$r")" 0 "[S] sign a copy whose post-check changes the file, then fails: rc 0"
  eq "$(bt "$P" "$W" run "$f" "$s" "$r")" 5 "[S] …a file that changed since the run is left alone: rc 5"
  has "$(cat "$BT_OUT")" "LEAVE" "[S] …the output says what it left"
  eq "$(nbackups t-settings-merge-b)" 1 "[S] …the backup stays for the owner (the state is unknown)"
  has "$(cat "$BT_OUT")" "kept for putting the state back by hand: $ST/vibemaestro/baton/records/t-settings-merge-b-$(pk "$s")-$before.json" "[S] …and the run names it"
  cmp -s "$ST/vibemaestro/baton/records/t-settings-merge-b-$(pk "$s")-$before.json" "$W/settings.before" && ok "[S] …it holds the bytes before the run" \
    || bad "[S] …it holds the bytes before the run"
  # a path the script lists that is not a regular file directly in <state>/records is never removed
  cp "$W/settings.before" "$s"; printf 'keep\n' > "$W/outside"; mkdir -p "$ST/vibemaestro/baton/records"    # written again by the run
  ln -sf "$W/outside" "$ST/vibemaestro/baton/records/link"; printf 'old\n' > "$ST/vibemaestro/baton/records/old.json"; sleep 3
  bt "$P" "$W" new t-settings-merge-c --from settings-merge --dir "$W" >/dev/null; f="$W/t-settings-merge-c.sh"
  python3 - "$f" "$W/outside" "$ST/vibemaestro/baton/records/link $ST/vibemaestro/baton/records/old.json" <<'PY'
import sys
p, a, b = sys.argv[1:4]
t = open(p).read()
old = 'printf \'%s\\n\' "$1" >> "${BATON_UNDO_ONLY:-/dev/null}"'
assert t.count(old) == 1
open(p, "w").write(t.replace(old, old + " && printf 'keep\\n' > " + a + " && printf '%s\\n' " + a + " " + b + " >> \"$BATON_UNDO_ONLY\""))
PY
  eq "$(sg "$P" "$W" "$f" "$s" "$r")/$(bt "$P" "$W" run "$f" "$s" "$r")" "0/0" "[S] a run that lists a path outside <state>/records and a link in it: rc 0"
  eq "$(cat "$W/outside" 2>/dev/null)/$([ -L "$ST/vibemaestro/baton/records/link" ] && echo link)/$(nbackups t-settings-merge-c)" "keep/link/0" \
     "[S] …a listed path outside <state>/records stays, a listed link stays, the backup goes"
  eq "$(cat "$ST/vibemaestro/baton/records/old.json" 2>/dev/null)" old "[S] …a listed file the run did not write stays"
  # two settings files with the same bytes: the backup kept for the owner of one is not the other's to remove
  printf '{"permissions": {}}\n' > "$W/a.json"; cp "$W/a.json" "$W/b.json"; b=$(sha_of "$W/a.json")
  bt "$P" "$W" new t-settings-merge-d --from settings-merge --dir "$W" >/dev/null; f="$W/t-settings-merge-d.sh"
  fail_postcheck "$f" 'case "$SETTINGS" in */a.json) printf " " >> "$SETTINGS";; esac'
  eq "$(sg "$P" "$W" "$f" "$W/a.json" "$r")/$(bt "$P" "$W" run "$f" "$W/a.json" "$r")" "0/5" "[S] run 1 on a.json is left (the file changed): rc 5"
  eq "$(sg "$P" "$W" "$f" "$W/b.json" "$r")/$(bt "$P" "$W" run "$f" "$W/b.json" "$r")/$(sha_of "$W/b.json")" "0/4/$b" \
     "[S] …run 2 on b.json, the same bytes, is undone byte for byte: rc 4"
  [ -f "$ST/vibemaestro/baton/records/t-settings-merge-d-$(pk "$W/a.json")-$b.json" ] && ok "[S] …a backup kept for another settings file with the same bytes stays" \
    || bad "[S] …a backup kept for another settings file with the same bytes stays"
  eq "$(nbackups t-settings-merge-d)" 1 "[S] …and run 2's own backup goes"
}
# pk <path> — the path key the kind names a settings file's backup and record after
pk() { printf '%s' "$1" | python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:16])'; }
# nbackups <name> — the backups of the settings-merge copy <name> under the state's records
nbackups() { find "$ST/vibemaestro/baton/records" -name "$1-*.json" 2>/dev/null | wc -l | tr -d ' '; }

fam_kind_remote() {
  local P=$1 W f out seal
  # a text with a space, from an input file, through printf %q into the remote bash -s; the kind is Stops: none, so the
  # session signs it in mode auto
  ST="$(fresh)/state"; W=$(fresh); f=$(kind_in "$P" "$W" remote-exec); out="$W/remote/motd"; mkdir -p "$W/remote"
  printf 'hello there\n' > "$W/body.txt"; printf 'hi\n' > "$W/hi.txt"
  local V=(host=host1 rpath="$out" body="$W/body.txt")
  eq "$(bt "$P" "$W" rehearse "$f" "${V[@]}")" 0 "[R] rehearse over ssh: rc 0"
  has "$(cat "$BT_OUT")" "PLAN remote host1 ($(uname -n)) create $out sha256" "[R] …the plan carries the host and the name it reports"
  has "$(cat "$W/fake.log")" "ssh host1 bash -s" "[R] …the program went through stdin into bash -s"
  bt "$P" "$W" mode auto >/dev/null
  seal=$( (cd "$W" && XDG_STATE_HOME="$ST" FAKE_LOG="$W/fake.log" FAKE_GH_WORLD="$W/gh.json" python3 "$P/scripts/baton.py" rehearse "$f" "${V[@]}") 2>/dev/null \
          | sed -n 's/^seal \([^ ]*\) .*/\1/p')
  eq "$(bt "$P" "$W" sign --by coordinator-auto --seal "${seal:-none}" "$f" "${V[@]}")" 0 "[R] sign: rc 0"
  eq "$(bt "$P" "$W" run "$f" "${V[@]}")" 0 "[R] run and post-check: rc 0"
  eq "$(cat "$out")" "hello there" "[R] …the file holds the text"
  eq "$(bt "$P" "$W" rehearse "$f" host=down rpath="$W/remote/x" body="$W/hi.txt")" 1 "[R] a host that does not answer: rehearse rc 1"
  has "$(cat "$BT_OUT")" "Connection refused" "[R] …the remote read was printed before the decision"
  has "$(cat "$BT_OUT")" "REFUSE" "[R] …and refused by name"
}

fam_kind_kubectl() {
  local P=$1 W f out
  ST="$(fresh)/state"; W=$(fresh); f=$(kind_in "$P" "$W" kubectl-exec); out="$W/pod/conf"; mkdir -p "$W/pod"
  printf 'a=1\n' > "$W/body.txt"; printf 'hi\n' > "$W/hi.txt"
  local V=(ctx=ctx1 ns=ns1 pod=web-0 server=https://api.fake.test:6443 rpath="$out" body="$W/body.txt")
  eq "$(bt "$P" "$W" rehearse "$f" "${V[@]}")" 0 "[K] rehearse over kubectl exec: rc 0"
  has "$(cat "$BT_OUT")" "PLAN pod ns1/web-0 (uid uid-web-0-0001) on https://api.fake.test:6443 (context ctx1) create $out sha256" \
      "[K] …the plan carries the pod uid, the API server and the context"
  has "$(cat "$W/fake.log")" "exec -i web-0 -- bash -s" "[K] …the program went through stdin into bash -s"
  eq "$(bt "$P" "$W" go "$f" "${V[@]}")" 8 "[K] go: exit 8 (Stops cluster-lane: the owner signs)"
  eq "$(sg "$P" "$W" "$f" "${V[@]}")" 0 "[K] sign as owner: rc 0"
  eq "$(bt "$P" "$W" run "$f" "${V[@]}")" 0 "[K] run and post-check: rc 0"
  eq "$(cat "$out")" "a=1" "[K] …the file holds the text"
  eq "$(bt "$P" "$W" rehearse "$f" ctx=ctx1 ns=ns1 pod=gone server=https://api.fake.test:6443 rpath="$W/pod/x" body="$W/hi.txt")" 1 "[K] a pod that is gone: rehearse rc 1"
  has "$(cat "$BT_OUT")" "NotFound" "[K] …the read was printed before the decision"
  eq "$(bt "$P" "$W" rehearse "$f" ctx=ctx1 ns=ns1 pod=web-0 server=https://other.fake.test rpath="$W/pod/y" body="$W/hi.txt")" 1 \
     "[K] a server the context does not name: rehearse rc 1"
  has "$(cat "$BT_OUT")" "REFUSE context ctx1 names the API server https://api.fake.test:6443, not https://other.fake.test" "[K] …a server mismatch is refused by name"
}

# gh_world <dir> [python statements on W] — the fake gh's world: acme/app private, acme/pub public; run 77 of acme/app failed at attempt 1
gh_world() {
  python3 - "$1/gh.json" "${2:-}" <<'PY'
import json, sys
W = {"repos": {"acme/app": {"private": True, "visibility": "private"}, "acme/pub": {"private": False, "visibility": "public"}},
     "runs": {"77": {"status": "completed", "conclusion": "failure", "run_attempt": 1, "head_sha": "c0ffee" * 6 + "c0ff", "name": "CI tests"}}}
exec(sys.argv[2])
json.dump(W, open(sys.argv[1], "w"))
PY
}
attempt() { python3 -c 'import json,sys; r=json.load(open(sys.argv[1]))["runs"]["77"]; print(r["run_attempt"], r["status"], r["conclusion"])' "$1/gh.json"; }

fam_kind_ci() {
  local P=$1 W f
  ST="$(fresh)/state"; W=$(fresh); f=$(kind_in "$P" "$W" ci-rerun-failed); gh_world "$W"
  eq "$(bt "$P" "$W" rehearse "$f" acme/app 77)" 0 "[G] rehearse: rc 0"
  has "$(cat "$BT_OUT")" "PLAN rerun-failed acme/app run 77 attempt 1 head c0ffee" "[G] …the plan carries the run, its attempt and head"
  has "$(cat "$BT_OUT")" "workflow CI tests" "[G] …and its workflow"
  hasnt "$(cat "$W/fake.log")" "gh run" "[G] …rehearse made no rerun call"
  eq "$(sg "$P" "$W" "$f" acme/app 77)" 0 "[G] sign: rc 0"
  eq "$(bt "$P" "$W" run "$f" acme/app 77)" 0 "[G] run and post-check: rc 0"
  eq "$(attempt "$W")" "2 queued None" "[G] …the run is at attempt 2, queued"
  eq "$(grep -c '^gh run rerun 77 --failed -R acme/app$' "$W/fake.log")" 1 "[G] …one rerun call, failed jobs only"
  gh_world "$W"; fail_postcheck "$f"
  eq "$(sg "$P" "$W" "$f" acme/app 77)" 0 "[G] sign a copy whose post-check fails: rc 0"
  eq "$(bt "$P" "$W" run "$f" acme/app 77)" 4 "[G] …run: rc 4, undone"
  eq "$(attempt "$W")" "2 completed cancelled" "[G] …undo cancelled the attempt the rerun made"
  bt "$P" "$W" new t-ci-b --from ci-rerun-failed --dir "$W" >/dev/null; gh_world "$W" 'W["jump"] = 2'
  eq "$(sg "$P" "$W" "$W/t-ci-b.sh" acme/app 77)" 0 "[G] sign, then another rerun lands in between (attempt 3, not 2): rc 0"
  eq "$(bt "$P" "$W" run "$W/t-ci-b.sh" acme/app 77)" 5 "[G] …the post-check fails and undo leaves the other attempt: rc 5"
  has "$(cat "$BT_OUT")" "LEAVE" "[G] …the output says what it left"
  gh_world "$W"
  eq "$(bt "$P" "$W" rehearse "$f" acme/pub 77)" 1 "[G] a public repository: rehearse rc 1"
  has "$(cat "$BT_OUT")" "REFUSE acme/pub is not private" "[G] …refused by name"
  gh_world "$W" 'W["runs"]["77"]["conclusion"] = "success"'
  eq "$(bt "$P" "$W" rehearse "$f" acme/app 77)" 1 "[G] a run that succeeded: rehearse rc 1"
  gh_world "$W" 'W["runs"]["77"]["status"] = "in_progress"'
  eq "$(bt "$P" "$W" rehearse "$f" acme/app 77)" 1 "[G] a run still in progress: rehearse rc 1"
  eq "$(bt "$P" "$W" rehearse "$f" 'acme/app;x' 77)" 1 "[G] a repository name outside [A-Za-z0-9_.-]: rehearse rc 1"
  ST="$(fresh)/state"; gh_world "$W"; bt "$P" "$W" new t-ci-c --from ci-rerun-failed --dir "$W" >/dev/null; f="$W/t-ci-c.sh"
  eq "$(sg "$P" "$W" "$f" acme/app 77)/$(bt "$P" "$W" run "$f" acme/app 77)" "0/0" "[G] a rerun that held: attempt 2 queued, its record stays"
  printf 'another signed plan\n' > "$W/plan2"
  ( cd "$W" && XDG_STATE_HOME="$ST" FAKE_LOG="$W/fake.log" FAKE_GH_WORLD="$W/gh.json" BATON_PHASE=undo BATON_PLAN="$W/plan2" bash "$f" acme/app 77 ) > "$BT_OUT" 2>&1
  eq "$?/$(attempt "$W")" "0/2 queued None" "[G] the undo of a later run that wrote nothing does not cancel the earlier run's attempt"
  has "$(cat "$BT_OUT")" "an earlier run's" "[G] …and says the record is an earlier run's"
}

# go kind:<name>: no script written; the same checks as a session baton
fam_kind_callable() {
  local P=$1 W src dir s r k cmd outside CP
  ST="$(fresh)/state"; W=$(fresh); bt "$P" "$W" mode auto >/dev/null
  src="$W/tool.sh"; printf '#!/bin/sh\necho tool\n' > "$src"; dir="$W/bin"; mkdir -p "$dir"
  for k in install-file settings-merge ci-rerun-failed; do
    eq "$(bt "$P" "$W" check "kind:$k")" 0 "[C] check kind:$k: rc 0"
  done
  eq "$(bt "$P" "$W" go kind:install-file "$src" "$dir")" 0 "[C] go kind:install-file: rc 0"
  eq "$(wc -l < "$BT_OUT" | tr -d ' ')/$(sha_of "$dir/tool.sh")" "1/$(sha_of "$src")" "[C] …one line, the file installed"
  has "$(cat "$BT_OUT")" "go: ok — 1 write — " "[C] …go: ok"
  gh_world "$W"
  eq "$(bt "$P" "$W" go kind:ci-rerun-failed acme/app 77)/$(attempt "$W")" "0/2 queued None" "[C] go kind:ci-rerun-failed: rc 0, attempt 2"
  has "$(cat "$BT_OUT")" "go: ok — 2 writes — " "[C] …go: ok — 2 writes"
  s="$W/settings.json"; r="$W/rules.json"
  printf '{"permissions": {"allow": []}}\n' > "$s"; printf '{"ask": ["Bash(rm:*)"]}\n' > "$r"
  eq "$(bt "$P" "$W" go kind:settings-merge "$s" "$r")" 8 "[C] go kind:settings-merge: exit 8 (Stops security-boundary)"
  cmd=$(sed -n "s/^on the owner's go: //p" "$BT_OUT")
  guard_cmd "$P" "$W" "$ST" s-owner "$cmd" >/dev/null                      # the session runs it; the guard opens the dialog
  eq "$( (cd "$W" && XDG_STATE_HOME="$ST" CLAUDE_CODE_SESSION_ID=s-owner bash -c "$cmd") >/dev/null 2>&1; echo $?)" 0 "[C] …the printed owner command signs kind:settings-merge"
  cmd=$(sed -n 's/^then: *//p' "$BT_OUT")
  eq "$( (cd "$W" && XDG_STATE_HOME="$ST" bash -c "$cmd") >/dev/null 2>&1; echo $?)" 0 "[C] …the printed run command runs it"
  eq "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["permissions"]["ask"])' "$s")" "['Bash(rm:*)']" "[C] …the rule is merged"
  eq "$(find "$ST/vibemaestro/baton/records" -name 'settings-merge-*.last' | wc -l | tr -d ' ')" 1 "[C] …its run record is named after the kind and the path"
  printf '{"permissions": {}}\n' > "$W/other.json"
  eq "$(sg "$P" "$W" kind:settings-merge "$W/other.json" "$r")/$(bt "$P" "$W" run kind:settings-merge "$W/other.json" "$r")" "0/0" "[C] a second settings file merges too"
  eq "$(find "$ST/vibemaestro/baton/records" -name 'settings-merge-*.last' | wc -l | tr -d ' ')" 2 "[C] …with a run record of its own"
  printf '{"permissions": {}}\n' > "$W/target.json"; ln -s "$W/target.json" "$W/link.json"
  eq "$(bt "$P" "$W" rehearse kind:settings-merge "$W/target.json" "$r")" 0 "[C] control: the file behind the link needs the merge (rehearse rc 0)"
  eq "$(bt "$P" "$W" rehearse kind:settings-merge "$W/link.json" "$r")" 1 "[C] a settings path that is a symbolic link: rc 1"
  has "$(cat "$BT_OUT")" "REFUSE $W/link.json is a symbolic link" "[C] …refused by name"
  for k in remote-exec kubectl-exec 'x/../y' '../baton-script' ''; do
    eq "$(bt "$P" "$W" go "kind:$k" a b)" 64 "[C] go kind:$k: rc 64"
    has "$(cat "$BT_OUT")" "install-file, settings-merge, ci-rerun-failed" "[C] …go kind:$k: the message lists the callable kinds"
  done
  mkdir -p "$W/bin2"; outside="$W/outside.txt"; printf 'keep\n' > "$outside"
  ln -s "$outside" "$W/bin2/tool.sh.baton-new"
  eq "$(bt "$P" "$W" go kind:install-file "$src" "$W/bin2")" 0 "[C] install-file with a link on the old temp name: rc 0"
  eq "$(cat "$outside")" "keep" "[C] …the link is not written through"
  printf 'x\n' > "$W/src2.txt"
  eq "$(sg "$P" "$W" kind:install-file "$W/src2.txt" "$dir")" 0 "[C] sign kind:install-file as owner: rc 0"
  CP="$P.copy"; [ -d "$CP" ] || cp -R "$P" "$CP"
  eq "$(bt "$CP" "$W" run kind:install-file "$W/src2.txt" "$dir")" 3 "[C] …the same kind run from another plugin copy: rc 3 (the binding names the kinds directory)"
}

# review findings on the kinds: guarded targets, an earlier run's record, a read-only settings file, a
# stale rules file
fam_kind_review() {
  local P=$1 W f s r b d
  ST="$(fresh)/state"; W=$(fresh); bt "$P" "$W" mode auto >/dev/null
  printf 'x\n' > "$W/hook"
  for d in "$W/proj/.claude" "$W/repo/.git/hooks" "$ST/vibemaestro/baton/bin" "$HOME/.claude/plugins"; do
    mkdir -p "$d"
    eq "$(bt "$P" "$W" go kind:install-file "$W/hook" "$d")" 1 "[V] install-file into ${d#"$W"/}: rc 1 (a security boundary)"
    [ ! -e "$d/hook" ] && ok "[V] …nothing written into ${d#"$W"/}" || bad "[V] …nothing written into ${d#"$W"/}"
  done
  mkdir -p "$W/plain"
  eq "$(bt "$P" "$W" go kind:install-file "$W/hook" "$W/plain")" 0 "[V] control: install-file into an ordinary directory: rc 0"
  f=$(kind_in "$P" "$W" settings-merge); s="$W/s.json"
  printf '{"permissions": {"allow": ["Read"]}}\n' > "$s"; printf '{"deny": ["Bash(rm -rf:*)"]}\n' > "$W/a.json"
  eq "$(sg "$P" "$W" "$f" "$s" "$W/a.json")/$(bt "$P" "$W" run "$f" "$s" "$W/a.json")" "0/0" "[V] run 1 merges a deny rule"
  b=$(sha_of "$s"); printf '{"ask": ["Bash(git push:*)"]}\n' > "$W/b.json"; printf 'another signed plan\n' > "$W/plan2"
  ( cd "$W" && XDG_STATE_HOME="$ST" BATON_PHASE=undo BATON_PLAN="$W/plan2" bash "$f" "$s" "$W/b.json" ) > "$BT_OUT" 2>&1
  eq "$?/$(sha_of "$s")" "0/$b" "[V] the undo of a run 2 that wrote nothing leaves run 1's merge (the record is run 1's)"
  has "$(cat "$BT_OUT")" "an earlier run's" "[V] …and says the record is an earlier run's"
  ( cd "$W" && XDG_STATE_HOME="$ST" BATON_PHASE=undo BATON_PLAN="$W/plan2" bash "$f" "$s" "$W/a.json" ) > "$BT_OUT" 2>&1
  eq "$?/$(sha_of "$s")" "0/$b" "[V] …the same with run 1's own rules (run 2 a no-op): still left"
  ( cd "$W" && XDG_STATE_HOME="$ST" BATON_PHASE=undo bash "$f" "$s" "$W/a.json" ) > "$BT_OUT" 2>&1
  eq "$?/$(sha_of "$s")" "1/$b" "[V] an undo with no signed plan cannot tell the run: it leaves the file (exit 1)"
  printf '{"permissions": {}}\n' > "$W/ro.json"; chmod 444 "$W/ro.json"
  eq "$(sg "$P" "$W" "$f" "$W/ro.json" "$W/a.json")/$(bt "$P" "$W" run "$f" "$W/ro.json" "$W/a.json")" "0/0" "[V] a read-only settings file merges"
  eq "$(mode_of "$W/ro.json")/$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["permissions"]["deny"])' "$W/ro.json")" \
     "444/['Bash(rm -rf:*)']" "[V] …and keeps its mode"
  bt "$P" "$W" new t-sm-pc --from settings-merge --dir "$W" >/dev/null; fail_postcheck "$W/t-sm-pc.sh"
  printf '{"permissions": {}}\n' > "$W/ro2.json"; chmod 444 "$W/ro2.json"; b=$(sha_of "$W/ro2.json")
  eq "$(sg "$P" "$W" "$W/t-sm-pc.sh" "$W/ro2.json" "$W/a.json")/$(bt "$P" "$W" run "$W/t-sm-pc.sh" "$W/ro2.json" "$W/a.json")" "0/4" \
     "[V] a read-only settings file whose post-check fails: rc 4"
  eq "$(sha_of "$W/ro2.json")/$(mode_of "$W/ro2.json")" "$b/444" "[V] …undo restored it byte for byte, read-only"
  bt "$P" "$W" new t-sm-rules --from settings-merge --dir "$W" >/dev/null; fail_postcheck "$W/t-sm-rules.sh" "printf ' ' >> \"\$RULES\""
  printf '{"permissions": {}}\n' > "$W/s3.json"; cp "$W/a.json" "$W/a3.json"; b=$(sha_of "$W/s3.json")
  eq "$(sg "$P" "$W" "$W/t-sm-rules.sh" "$W/s3.json" "$W/a3.json")/$(bt "$P" "$W" run "$W/t-sm-rules.sh" "$W/s3.json" "$W/a3.json")" "0/4" \
     "[V] a run whose rules file is edited before its undo: rc 4"
  eq "$(sha_of "$W/s3.json")" "$b" "[V] …undo still restored it (the record names the run by its signed plan)"
  mkdir -p "$W/p/.CLAUDE"
  eq "$(bt "$P" "$W" go kind:install-file "$W/hook" "$W/p/.CLAUDE")" 1 "[V] install-file into .CLAUDE (a case-insensitive file system reads .claude): rc 1"
  r="$W/old-rules.json"; printf '{"ask": ["Bash(rm:*)"]}\n' > "$r"
  python3 -c 'import os, sys, time; t = time.time() - 600; os.utime(sys.argv[1], (t, t))' "$r"
  printf '{"permissions": {}}\n' > "$W/t.json"
  eq "$(bt "$P" "$W" go kind:settings-merge "$W/t.json" "$r")" 1 "[V] go kind:settings-merge with a rules file written 600 s ago: rc 1"
  has "$(cat "$BT_OUT")" "the input file $r was last written" "[V] …it names the rules file"
}

# probe <plugin> <dir> <script> <args…> — sign --by coordinator-auto with a seal that never matches: a call whose value names a
# settings file is refused before the rehearse, with the value's line; any other call goes on to the rehearse
probe() { local p=$1 d=$2; shift 2; bt "$p" "$d" sign --by coordinator-auto --seal 0000000000000000.0000000000000000 "$@"; }
SNAMES="names a Claude Code settings"

fam_kind_value() {
  local P=$1 W f s r b rem old seal v
  ST="$(fresh)/state"; W=$(fresh); bt "$P" "$W" mode auto >/dev/null
  bt "$P" "$W" new t-mn --from settings-merge --dir "$W" >/dev/null; f="$W/t-mn.sh"
  sed 's/^# Stops: .*$/# Stops: none/' "$f" > "$f.new" && mv "$f.new" "$f"
  eq "$(bt "$P" "$W" check "$f")/$(grep -c '^# Stops: none$' "$f")" 0/1 "[A] a settings-merge copy with Stops: none passes check (its text names no settings path)"
  mkdir -p "$HOME/.claude"; s="$HOME/.claude/settings.json"; r="$W/rules.json"
  printf '{"permissions": {"allow": []}}\n' > "$s"; printf '{"allow": ["Bash(rm:*)"]}\n' > "$r"; b=$(sha_of "$s")
  eq "$(bt "$P" "$W" go "$f" "$s" "$r")" 8 "[A] go, mode auto, the settings path as argument 1: exit 8 (the owner signs)"
  has "$(tail -n 1 "$BT_OUT")" "argument 1 $s $SNAMES file: the call is security-boundary whatever Stops: says" "[A] …the last line names the argument and the reason"
  has "$(cat "$BT_OUT")" "  Stop:     security-boundary (a stop-list item" "[A] …the card's Stop line says security-boundary"
  eq "$(sha_of "$s")" "$b" "[A] …the settings file is unchanged"
  seal=$( (cd "$W" && XDG_STATE_HOME="$ST" python3 "$P/scripts/baton.py" rehearse "$f" "$s" "$r") 2>/dev/null | sed -n 's/^seal \([^ ]*\) .*/\1/p')
  eq "$(bt "$P" "$W" sign --by coordinator-auto --seal "${seal:-none}" "$f" "$s" "$r")" 3 "[A] sign --by coordinator-auto with the right seal: refused (rc 3)"
  has "$(cat "$BT_OUT")" "sign refused: argument 1 $s $SNAMES file" "[A] …in one line naming the argument"
  # a coordinator-auto signature written before this change: its signer is the plugin without the value check
  old="$TMP/old-signer-$(basename "$W")"; mk_plugin_copy "$old"
  mutate "$old/scripts/baton.py" 'if self.value_stop is None or "security-boundary"' 'if True or "security-boundary"' \
    && eq "$(bt "$old" "$W" sign --by coordinator-auto --seal "${seal:-none}" "$f" "$s" "$r")" 0 "[A] control: the signer before this change signs it as coordinator-auto"
  eq "$(bt "$P" "$W" run "$f" "$s" "$r")" 3 "[A] …that pending signature: run refused (rc 3), nothing ran"
  has "$(cat "$BT_OUT")" "run refused, nothing ran: signed by coordinator-auto, but argument 1 $s $SNAMES file" "[A] …naming the argument"
  eq "$(sha_of "$s")" "$b" "[A] …the settings file is unchanged"
  rm -rf "$old"
  eq "$(sg "$P" "$W" "$f" "$s" "$r")/$(bt "$P" "$W" run "$f" "$s" "$r")" "0/0" "[A] the owner signs the same call, run: rc 0"
  has "$(cat "$s")" "Bash(rm:*)" "[A] …the rule landed (the owner's path is unchanged)"
  # every spelling of the path: refused before the rehearse
  mkdir -p "$W/conf" "$HOME/.claude/plans" "$HOME/x"; ln -s "$s" "$W/link.json"; ln -s "$HOME/.claude" "$W/cfg"
  ln "$s" "$W/hard.json"; printf '{"permissions": {}}\n' > "$W/conf/settings.json"
  for v in "~/.claude/settings.json" "$HOME/x/../.claude/settings.json" "$W/link.json" "$W/cfg/settings.json" "--out=$s" "'$s'" \
           " $s " "$HOME/.claude/s*.json" "$HOME/.claude/settings.local.json" "$HOME/.claude" "$HOME/.CLAUDE/Settings.json" "file://$s" \
           "$W/hard.json" '$HOME/.claude/settings.json' '${CLAUDE_CONFIG_DIR}/settings.json'; do
    eq "$(probe "$P" "$W" "$f" "$v" "$r")" 3 "[A] argument $v: refused (rc 3)"
    has "$(cat "$BT_OUT")" "argument 1 " "[A] …naming argument 1 as a settings value"
    has "$(cat "$BT_OUT")" "$SNAMES" "[A] …as a settings value"
  done
  eq "$(CLAUDE_CONFIG_DIR="$W/conf" probe "$P" "$W" "$f" "$W/conf/settings.json" "$r")" 3 "[A] \$CLAUDE_CONFIG_DIR/settings.json (a directory of another name): rc 3"
  has "$(cat "$BT_OUT")" "$SNAMES" "[A] …as a settings value"
  probe "$P" "$W" "$f" "$W/conf/settings.json" "$r" >/dev/null
  has "$(cat "$BT_OUT")" "the seal now is" "[A] control: the same file without that CLAUDE_CONFIG_DIR goes on to the rehearse"
  hasnt "$(cat "$BT_OUT")" "$SNAMES" "[A] …with no settings line"
  probe "$P" "$W" "$f" "$HOME/.claude/plans" "$r" >/dev/null
  hasnt "$(cat "$BT_OUT")" "$SNAMES" "[A] a subdirectory of .claude as the value is not one"
  for v in "anthropics/claude-code" "$W/ClaudeCode/settings.json"; do
    probe "$P" "$W" "$f" "$v" "$r" >/dev/null
    hasnt "$(cat "$BT_OUT")" "$SNAMES" "[A] $v (a directory named claude-code that is not the managed one) is not one"
  done
  eq "$(probe "$P" "$W" "$f" '${CLAUDE_CONFIG_DIR:-/nowhere}/settings.json' "$r")" 3 "[A] \${CLAUDE_CONFIG_DIR:-…}/settings.json: rc 3"
  has "$(cat "$BT_OUT")" "$SNAMES" "[A] …as a settings value"
  # another name of a settings file or directory: the file a settings link points to, the directory .claude links to
  mkdir -p "$W/dot" "$W/conf2" "$W/dotdir"; printf '{"permissions": {}}\n' > "$W/dot/cs.json"; ln -s "$W/dot/cs.json" "$W/conf2/settings.json"
  eq "$(CLAUDE_CONFIG_DIR="$W/conf2" probe "$P" "$W" "$f" "$W/dot/cs.json" "$r")" 3 "[A] the file a settings link points to (dotfiles): rc 3"
  has "$(cat "$BT_OUT")" "argument 1 $W/dot/cs.json $SNAMES file ($W/conf2/settings.json)" "[A] …naming the settings file it is"
  ln -s "$W/dotdir" "$W/.claude"
  eq "$(probe "$P" "$W" "$f" "$W/dotdir" "$r")" 3 "[A] the directory the project's .claude links to: rc 3"
  has "$(cat "$BT_OUT")" "$SNAMES directory" "[A] …as a settings directory"
  rm "$W/.claude"
  # a hard link: decoys that sort first never hide the settings file; one baton cannot place is counted all the same
  for v in $(seq -w 0 79); do printf '{}\n' > "$HOME/.claude/settings-$v.json"; done
  eq "$(probe "$P" "$W" "$f" "$W/hard.json" "$r")" 3 "[A] a hard link to the settings file behind 80 decoy names: rc 3"
  has "$(cat "$BT_OUT")" "argument 1 $W/hard.json $SNAMES file ($s)" "[A] …naming the settings file"
  rm -f "$HOME"/.claude/settings-*.json
  mkdir -p "$W/conf4"; ln -s /dev/null "$W/conf4/settings.json"
  CLAUDE_CONFIG_DIR="$W/conf4" probe "$P" "$W" "$f" /dev/null "$r" >/dev/null
  hasnt "$(cat "$BT_OUT")" "$SNAMES" "[A] /dev/null, which a settings link points to, is not a settings file (a device)"
  mkfifo "$W/fifo"; ln -s "$W/fifo" "$W/conf4/settings.local.json"
  eq "$(CLAUDE_CONFIG_DIR="$W/conf4" probe "$P" "$W" "$f" "$W/fifo" "$r")" 3 "[A] a FIFO a settings link points to: rc 3 (a write to it is a settings write)"
  has "$(cat "$BT_OUT")" "$SNAMES file" "[A] …as a settings file"
  v=$(fresh); mkdir -p "$v/sib/.claude"; printf '{"permissions": {}}\n' > "$v/sib/.claude/settings.json"; ln "$v/sib/.claude/settings.json" "$W/data.json"
  eq "$(probe "$P" "$W" "$f" "$W/data.json" "$r")" 3 "[A] a hard link to a settings file in a .claude no search reaches: rc 3"
  has "$(cat "$BT_OUT")" "argument 1 $W/data.json names a file with other hard links, which may be a Claude Code settings file ($W/data.json, 2 hard links)" \
      "[A] …as a file with other hard links"
  # in a pod a value-only stop of a session file says how to hand it on: declare the stop (pack keeps only a declared one)
  touch "$f"; printf '{"allow": ["Bash(pod:*)"]}\n' > "$r"     # a rule not merged yet: the plan has a write
  eq "$(INTENT_SLUG=t SEAT=t bt "$P" "$W" go "$f" "$s" "$r")" 8 "[A] in a pod: go exit 8"
  has "$(cat "$BT_OUT")" 'declare `# Stops: security-boundary` and a `# Params:` header (only such a script can be kept) in '"$f" \
      "[A] …the hand-off says to declare the stop (and Params: the copy has none)"
  hasnt "$(cat "$BT_OUT")" "tell the coordinator the call" "[A] …not a call of a pod file the coordinator cannot run"
  # look-alikes stay Stops: none: go signs and runs them in mode auto
  for v in "$W/foo.claude/settings.json" "$HOME/.claude/plans/settings.json" "$HOME/.claude/settings.json.bak" "$W/claude/settings.json"; do
    mkdir -p "$(dirname "$v")"; printf '{"permissions": {}}\n' > "$v"; printf '{"allow": ["Bash(rm:*)"]}\n' > "$r"; touch "$f"
    eq "$(bt "$P" "$W" go "$f" "$v" "$r")" 0 "[A] look-alike ${v#"$TMP"/}: go ok (mode auto signs it)"
    hasnt "$(cat "$BT_OUT")" "$SNAMES" "[A] …no settings line"
  done
  # through a Param: remote-exec declares Stops: none; its rpath goes to the owner when it names a settings file
  bt "$P" "$W" new t-rx --from remote-exec --dir "$W" >/dev/null; rem="$W/t-rx.sh"; printf 'x\n' > "$W/body.txt"
  eq "$(bt "$P" "$W" go "$rem" host=host1 rpath="$HOME/.claude/settings.local.json" body="$W/body.txt")" 8 "[A] Param rpath=<home>/.claude/settings.local.json: go exit 8"
  has "$(tail -n 1 "$BT_OUT")" "rpath $HOME/.claude/settings.local.json $SNAMES file" "[A] …the last line names the key"
  has "$(cat "$BT_OUT")" "  Stop:     rpath $HOME/.claude/settings.local.json $SNAMES" "[A] …and so does the card"
  [ ! -e "$HOME/.claude/settings.local.json" ] && ok "[A] …nothing written" || bad "[A] …nothing written"
  printf 'x\n' > "$W/body.txt"; touch "$rem"
  eq "$(bt "$P" "$W" go "$rem" host=host1 rpath="$HOME/.claude/plans/notes.json" body="$W/body.txt")" 0 "[A] control: rpath in .claude/plans: go ok"
  # a baton that declares security-boundary reads as before
  printf '{"allow": ["Bash(cat:*)"]}\n' > "$r"
  eq "$(bt "$P" "$W" go kind:settings-merge "$s" "$r")" 8 "[A] go kind:settings-merge onto the settings file: exit 8"
  has "$(tail -n 1 "$BT_OUT")" "the script declares stop categories (security-boundary): only the owner signs it" "[A] …with the declared reason"
  hasnt "$(cat "$BT_OUT")" "$SNAMES" "[A] …and no value line"
}

# No Bash file embeds Python, except the recorded exceptions.
# d5_count <ls-files pathspec…> — how many tracked files under the pathspecs embed Python, in the repository $D5_REPO
d5_count() { ( cd "$D5_REPO" && git ls-files "$@" | xargs grep -l -E 'python3? +-c|<<.?PY' 2>/dev/null | wc -l | tr -d ' ' ); }
fam_d5() {
  local d
  D5_REPO="$SRC_ROOT"
  eq "$(d5_count 'plugins/*.sh' ':(exclude)plugins/*/templates/baton-kinds/*')" 0 "[D1] every plugin Bash file but the baton kinds is free of embedded Python"
  eq "$(d5_count 'plugins/*/templates/baton-kinds/*.sh')" 1 "[D2] control: the baton kinds hold the one file that embeds Python (settings-merge.sh), so the exclusion is what makes [D1] zero"
  d=$(fresh); git_ init -q "$d"; mkdir -p "$d/plugins/p/sub" "$d/plugins/p/templates/baton-kinds"
  printf '#!/bin/bash\npython3 -c x\n' > "$d/plugins/p/sub/planted.sh"; printf '#!/bin/bash\npython3 -c x\n' > "$d/plugins/p/templates/baton-kinds/k.sh"
  git_ -C "$d" add -A; D5_REPO="$d"
  eq "$(d5_count 'plugins/*.sh' ':(exclude)plugins/*/templates/baton-kinds/*')" 1 "[D4] control: a planted python3 -c in another plugin file is counted, the baton-kind file next to it is not"
  D5_REPO="$SRC_ROOT"
}

# [Y] the machine's own ~/.claude is not read: the answerer check of baton.py reads the HOME of every ancestor from /proc, and a subshell
# of this suite shows the HOME this shell was started with
fam_y() {
  local P=$1
  eq "$(grep -c '^SUITE_PID = ' "$P/scripts/baton.py")" 1 "[Y1] the plugin copy is isolated from the machine (baton_isolate): its ancestor walk stops at the suite's shell"
  eq "$(home_leaks "$P/scripts" baton ancestors)" "True []" "[Y2] the ancestors the copy sees from below the suite: at least one, none with a HOME outside the scratch tree"
  has "$(HOME=/ctl-real home_leaks "$P/scripts" baton ancestors)" "'/ctl-real'" "[Y3] control: a bash above the call that was started with another HOME is named, so [Y2] can see a leak"
}

FAMILIES="fam_y fam_d5 fam_kinds_new fam_kind_install fam_kind_settings fam_kind_remote fam_kind_kubectl fam_kind_ci fam_kind_callable fam_kind_review fam_kind_value"
echo "== the real plugin =="
REAL="$TMP/real"; mk_plugin_copy "$REAL"
for fam in $FAMILIES; do echo "-- $fam"; "$fam" "$REAL"; done

echo "== planted breaks: each family must go red on a plugin copy with one break =="
# KBRK <label> <family> <needle> <file under the plugin> <old> <new>
KBRK() {
  local label=$1 fam=$2 needle=$3 d; d="$TMP/break-$label"; mk_plugin_copy "$d"
  mutate "$d/$4" "$5" "$6" && expect_red "$label" "$fam" "$d" "$needle"
}
KBRK kind-write-differs fam_kinds_new '[N] install-file passes check as generated' templates/baton-kinds/install-file.sh \
    "      printf 'PLAN %s\\n' \"\$plan\"" "      printf 'PLAN: %s\\n' \"\$plan\""
KBRK kind-unknown-accepted fam_kinds_new '[N] an unknown kind: rc 64' scripts/baton.py \
    'if not KIND_RE.match(kind) or not os.path.isfile(path):' 'if False:'
KBRK remote-read-swallowed fam_kind_remote '[R] …the remote read was printed before the decision' templates/baton-kinds/remote-exec.sh \
    $'  OUT=$(remote_state 2>&1 || true)\n  printf \'%s\\n\' "$OUT"\n  RHOST' $'  OUT=$(remote_state 2>&1)\n  printf \'%s\\n\' "$OUT"\n  RHOST'
KBRK settings-undo-blind fam_kind_settings '[S] …a file that changed since the run is left alone: rc 5' templates/baton-kinds/settings-merge.sh \
    '  if [ "$NOW" = "$AFTER" ]; then' '  if true; then'
KBRK kubectl-uid-dropped fam_kind_kubectl '[K] …the plan carries the pod uid' templates/baton-kinds/kubectl-exec.sh \
    '(uid $PUID)' '(uid -)'
KBRK kubectl-server-unchecked fam_kind_kubectl '[K] …a server mismatch is refused by name' templates/baton-kinds/kubectl-exec.sh \
    'if [ "$SERVER" != "$P_SERVER" ]; then' 'if false; then'
KBRK kind-any-name fam_kind_callable '[C] …go kind:remote-exec: the message lists the callable kinds' scripts/baton.py \
    '    if name not in CALLABLE_KINDS:' '    if not KIND_RE.match(name):'
KBRK kind-unbound fam_kind_callable '[C] …the same kind run from another plugin copy' scripts/baton.py \
    '            self.bind_sha = sha256(self.sha + "\0kind:" + KINDS_REAL)' '            self.bind_sha = self.sha'
KBRK install-temp-predictable fam_kind_callable '[C] …the link is not written through' templates/baton-kinds/install-file.sh \
    '  tmp=$(mktemp "$DIR/.baton-new.XXXXXX") || return 1' '  tmp="$DEST.baton-new"'
KBRK settings-link-allowed fam_kind_callable '[C] a settings path that is a symbolic link: rc 1' templates/baton-kinds/settings-merge.sh \
    '  if [ -L "$SETTINGS" ]; then' '  if false; then'
KBRK settings-one-record fam_kind_callable '[C] …with a run record of its own' templates/baton-kinds/settings-merge.sh \
    'RECORD="$RECORDS/__NAME__-$(path_key).last"' 'RECORD="$RECORDS/__NAME__-x.last"'
KBRK ci-public-allowed fam_kind_ci '[G] a public repository: rehearse rc 1' templates/baton-kinds/ci-rerun-failed.sh \
    '  if [ "$priv" != true ] || [ "$vis" = public ] || [ "$vis" = internal ]; then' '  if false; then'
KBRK ci-attempt-unchecked fam_kind_ci '[G] …the post-check fails and undo leaves the other attempt' templates/baton-kinds/ci-rerun-failed.sh \
    '  [ "$now" = "$((n + 1))" ]' '  true'
KBRK ci-undo-cancels-any fam_kind_ci '[G] …the output says what it left' templates/baton-kinds/ci-rerun-failed.sh \
    '  elif [ "$now" = "$((n + 1))" ]; then' '  elif true; then'
KBRK install-guard-off fam_kind_review '[V] install-file into proj/.claude: rc 1' templates/baton-kinds/install-file.sh \
    '  if guarded; then' '  if false; then'
KBRK install-claude-dir-open fam_kind_review '[V] …nothing written into' templates/baton-kinds/install-file.sh \
    '  for top in "$CLAUDE_DIR" "$STATE_BASE/vibemaestro"; do' '  for top in /nonexistent-x; do'
KBRK settings-mode-first fam_kind_review '[V] a read-only settings file merges' templates/baton-kinds/settings-merge.sh \
    '  if merged "$SETTINGS" "$RULES" > "$tmp" && chmod "$(mode_of "$SETTINGS")" "$tmp" && mv -f "$tmp" "$SETTINGS"; then' \
    '  if chmod "$(mode_of "$SETTINGS")" "$tmp" && merged "$SETTINGS" "$RULES" > "$tmp" && mv -f "$tmp" "$SETTINGS"; then'
KBRK kind-input-unchecked fam_kind_review '[V] go kind:settings-merge with a rules file written 600 s ago: rc 1' scripts/baton.py \
    'KIND_INPUTS = {"settings-merge": 1}' 'KIND_INPUTS = {}'
KBRK settings-run-unnamed fam_kind_review "[V] …the same with run 1's own rules (run 2 a no-op): still left" templates/baton-kinds/settings-merge.sh \
    '  if [ "${RUNID:-}" != "$MINE" ]; then' '  if false; then'
KBRK settings-backup-kept fam_kind_settings '[S] …the backup is gone once the run held (only its undo needs it)' templates/baton-kinds/settings-merge.sh \
    'then printf '"'"'%s\n'"'"' "$1" >> "${BATON_UNDO_ONLY:-/dev/null}"; fi' 'then :; fi'
KBRK settings-backup-not-taken fam_kind_settings '[S] …the one already there for this path and bytes, read-only, was taken over and went too' templates/baton-kinds/settings-merge.sh \
    '  mkdir -p "$RECORDS" && cp -f "$SETTINGS" "$1" || return 1' '  mkdir -p "$RECORDS" && { cmp -s "$SETTINGS" "$1" && return 0; cp -f "$SETTINGS" "$1"; } || return 1'
KBRK settings-backup-shared fam_kind_settings '[S] …a backup kept for another settings file with the same bytes stays' templates/baton-kinds/settings-merge.sh \
    'backup="$RECORDS/__NAME__-$(path_key)-$before.json"' 'backup="$RECORDS/__NAME__-$before.json"'
KBRK undo-only-unwritten fam_kind_settings '[S] …a listed file the run did not write stays' scripts/baton.py \
    'and stat.S_ISREG(st.st_mode) and st.st_ctime >= started)' 'and stat.S_ISREG(st.st_mode))'
KBRK undo-only-never fam_kind_settings '[S] …and the backup is gone once undo put the file back' scripts/baton.py \
    '            drop_undo_only(undo_only, result == "ok" or undone == "yes", sinks, started)' '            drop_undo_only(undo_only, result == "ok", sinks, started)'
KBRK undo-only-always fam_kind_settings '[S] …the backup stays for the owner (the state is unknown)' scripts/baton.py \
    '            drop_undo_only(undo_only, result == "ok" or undone == "yes", sinks, started)' '            drop_undo_only(undo_only, True, sinks, started)'
KBRK undo-only-anywhere fam_kind_settings '[S] …a listed path outside <state>/records stays, a listed link stays, the backup goes' scripts/baton.py \
    '            mine = (os.path.isabs(p) and os.path.realpath(os.path.dirname(p)) == records' '            mine = (os.path.isabs(p) and True'
KBRK settings-restore-cp fam_kind_review '[V] …undo restored it byte for byte, read-only' templates/baton-kinds/settings-merge.sh \
    '    write "restore $SETTINGS from $BACKUP" restore' '    write "restore $SETTINGS from $BACKUP" cp "$BACKUP" "$SETTINGS"'
KBRK undo-without-plan fam_kind_review '[V] …undo still restored it (the record names the run by its signed plan)' scripts/baton.py \
    '                rc, lines, _w = run_phase(s, args, "undo", sinks, plan=rec.get("plan") or [], undo_only=undo_only)' '                rc, lines, _w = run_phase(s, args, "undo", sinks, undo_only=undo_only)'
KBRK ci-run-unnamed fam_kind_ci "[G] the undo of a later run that wrote nothing does not cancel the earlier run's attempt" templates/baton-kinds/ci-rerun-failed.sh \
    '  if [ "${runid:-}" != "$mine" ]; then' '  if false; then'
KBRK install-guard-case fam_kind_review '[V] install-file into .CLAUDE' templates/baton-kinds/install-file.sh \
    'print(os.path.realpath(sys.argv[1]).lower())' 'print(os.path.realpath(sys.argv[1]))'

echo "== nothing written outside the scratch tree =="
eq "$(tree_hash "$SRC_ROOT")" "$H0" "the repository tree is unchanged by the suite"

echo; summary
