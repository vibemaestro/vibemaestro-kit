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
#   [K] kubectl-exec: over the fake kubectl; the plan carries context, API server and pod uid; Stops cluster-lane (go: exit 8)
#   [G] ci-rerun-failed: over a fake gh (tests/fixtures/baton_kinds_gh.py); record, rerun, the next attempt; undo cancels it
#   [C] kind:<name>: install-file, settings-merge and ci-rerun-failed run with no script written; other names rc 64;
#       the binding names the kinds directory; a link on a predictable temp name is never written through
#   [D] the repo-wide grep for Bash that embeds Python prints 0 once `templates/baton-kinds/` is a recorded exception
#   [X] planted breaks: each family goes red on a plugin copy with one break in a kind or in baton.py
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
# shellcheck source=fixtures/ports.sh
. "$HERE/fixtures/ports.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
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
bt() { local p=$1 d=$2; shift 2; ( cd "$d" && XDG_STATE_HOME="$ST" FAKE_LOG="$d/fake.log" FAKE_GH_WORLD="$d/gh.json" python3 "$p/scripts/baton.py" "$@" ) > "$BT_OUT" 2>&1; echo $?; }
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
  eq "$(bt "$P" "$W" rehearse "$f" "$s" "$r")" 0 "[S] rehearse: rc 0"
  has "$(cat "$BT_OUT")" "PLAN backup $s sha256 $before to" "[S] …the plan backs the file up by its sha256"
  has "$(cat "$BT_OUT")" 'PLAN merge allow +1 ["Bash(cat:*)"], ask +1 ["Bash(rm:*)"], deny +0 into '"$s" "[S] …adds only the missing rules, each named in the plan"
  eq "$(sha_of "$s")" "$before" "[S] …rehearse wrote nothing"
  eq "$(sg "$P" "$W" "$f" "$s" "$r")" 0 "[S] sign (Stops security-boundary: the owner): rc 0"
  eq "$(bt "$P" "$W" run "$f" "$s" "$r")" 0 "[S] run and post-check: rc 0"
  eq "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); p=d["permissions"]; print(d["model"], p["allow"], p["ask"], p["deny"])' "$s")" \
     "x ['Bash(ls:*)', 'Bash(cat:*)'] ['Bash(rm:*)'] ['Edit(//x/**)']" "[S] …rules added, none removed, the rest kept"
  eq "$(find "$ST/vibemaestro/baton/records" -name 't-settings-merge-*.last' | wc -l | tr -d ' ')" 1 "[S] …the run record is in the state directory"
  cp "$W/settings.before" "$s"; fail_postcheck "$f"
  eq "$(sg "$P" "$W" "$f" "$s" "$r")" 0 "[S] sign a copy whose post-check fails: rc 0"
  eq "$(bt "$P" "$W" run "$f" "$s" "$r")" 4 "[S] …run: rc 4, undone"
  eq "$(sha_of "$s")" "$before" "[S] …undo restored the settings byte for byte through the run record"
  cp "$W/settings.before" "$s"
  bt "$P" "$W" new t-settings-merge-b --from settings-merge --dir "$W" >/dev/null; f="$W/t-settings-merge-b.sh"
  fail_postcheck "$f" "printf ' ' >> \"\$SETTINGS\""
  eq "$(sg "$P" "$W" "$f" "$s" "$r")" 0 "[S] sign a copy whose post-check changes the file, then fails: rc 0"
  eq "$(bt "$P" "$W" run "$f" "$s" "$r")" 5 "[S] …a file that changed since the run is left alone: rc 5"
  has "$(cat "$BT_OUT")" "LEAVE" "[S] …the output says what it left"
}

fam_kind_remote() {
  local P=$1 W f out
  ST="$(fresh)/state"; W=$(fresh); f=$(kind_in "$P" "$W" remote-exec); out="$W/remote/motd"; mkdir -p "$W/remote"
  eq "$(bt "$P" "$W" rehearse "$f" host1 "$out" 'hello there')" 0 "[R] rehearse over ssh: rc 0"
  has "$(cat "$BT_OUT")" "PLAN remote host1 ($(uname -n)) create $out sha256" "[R] …the plan carries the host and the name it reports"
  has "$(cat "$W/fake.log")" "ssh host1 bash -s" "[R] …the program went through stdin into bash -s"
  eq "$(sg "$P" "$W" "$f" host1 "$out" 'hello there')" 0 "[R] sign: rc 0"
  eq "$(bt "$P" "$W" run "$f" host1 "$out" 'hello there')" 0 "[R] run and post-check: rc 0"
  eq "$(cat "$out")" "hello there" "[R] …the file holds the text"
  eq "$(bt "$P" "$W" rehearse "$f" down "$W/remote/x" hi)" 1 "[R] a host that does not answer: rehearse rc 1"
  has "$(cat "$BT_OUT")" "Connection refused" "[R] …the remote read was printed before the decision"
  has "$(cat "$BT_OUT")" "REFUSE" "[R] …and refused by name"
}

fam_kind_kubectl() {
  local P=$1 W f out
  ST="$(fresh)/state"; W=$(fresh); f=$(kind_in "$P" "$W" kubectl-exec); out="$W/pod/conf"; mkdir -p "$W/pod"
  eq "$(bt "$P" "$W" rehearse "$f" ctx1 ns1 web-0 "$out" 'a=1')" 0 "[K] rehearse over kubectl exec: rc 0"
  has "$(cat "$BT_OUT")" "PLAN pod ns1/web-0 (uid uid-web-0-0001) on https://api.fake.test:6443 (context ctx1) create $out sha256" \
      "[K] …the plan carries the pod uid, the API server and the context"
  has "$(cat "$W/fake.log")" "exec -i web-0 -- bash -s" "[K] …the program went through stdin into bash -s"
  eq "$(bt "$P" "$W" go "$f" ctx1 ns1 web-0 "$out" 'a=1')" 8 "[K] go: exit 8 (Stops cluster-lane: the owner signs)"
  eq "$(sg "$P" "$W" "$f" ctx1 ns1 web-0 "$out" 'a=1')" 0 "[K] sign as owner: rc 0"
  eq "$(bt "$P" "$W" run "$f" ctx1 ns1 web-0 "$out" 'a=1')" 0 "[K] run and post-check: rc 0"
  eq "$(cat "$out")" "a=1" "[K] …the file holds the text"
  eq "$(bt "$P" "$W" rehearse "$f" ctx1 ns1 gone "$W/pod/x" hi)" 1 "[K] a pod that is gone: rehearse rc 1"
  has "$(cat "$BT_OUT")" "NotFound" "[K] …the read was printed before the decision"
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
  eq "$( (cd "$W" && XDG_STATE_HOME="$ST" bash -c "$cmd") >/dev/null 2>&1; echo $?)" 0 "[C] …the printed owner command signs kind:settings-merge"
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
  done
  has "$(cat "$BT_OUT")" "install-file, settings-merge, ci-rerun-failed" "[C] …the message lists the callable kinds"
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

FAMILIES="fam_d5 fam_kinds_new fam_kind_install fam_kind_settings fam_kind_remote fam_kind_kubectl fam_kind_ci fam_kind_callable fam_kind_review"
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
KBRK kind-any-name fam_kind_callable '[C] go kind:remote-exec: rc 64' scripts/baton.py \
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
KBRK settings-restore-cp fam_kind_review '[V] …undo restored it byte for byte, read-only' templates/baton-kinds/settings-merge.sh \
    '    write "restore $SETTINGS from $BACKUP" restore' '    write "restore $SETTINGS from $BACKUP" cp "$BACKUP" "$SETTINGS"'
KBRK undo-without-plan fam_kind_review '[V] …undo still restored it (the record names the run by its signed plan)' scripts/baton.py \
    '                rc, lines, _w = run_phase(s, args, "undo", sinks, plan=rec.get("plan") or [])' '                rc, lines, _w = run_phase(s, args, "undo", sinks)'
KBRK ci-run-unnamed fam_kind_ci "[G] the undo of a later run that wrote nothing does not cancel the earlier run's attempt" templates/baton-kinds/ci-rerun-failed.sh \
    '  if [ "${runid:-}" != "$mine" ]; then' '  if false; then'
KBRK install-guard-case fam_kind_review '[V] install-file into .CLAUDE' templates/baton-kinds/install-file.sh \
    'print(os.path.realpath(sys.argv[1]).lower())' 'print(os.path.realpath(sys.argv[1]))'

echo "== nothing written outside the scratch tree =="
eq "$(tree_hash "$SRC_ROOT")" "$H0" "the repository tree is unchanged by the suite"

echo; summary
