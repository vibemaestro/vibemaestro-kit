#!/bin/bash
# =============================================================================
# BatonRun: the machine mode policy only root can set (scripts/baton.py machine_policy, mode_source)
# =============================================================================
# Run: bash tests/test-baton-mode-policy.sh
#
# A sandbox image sets its sessions' mode as root at build time, in one file at a fixed path; a session cannot write it. Each
# family runs on a copy of the real plugin.
# No case reads an environment variable for the policy: the in-process cases call machine_policy with a scratch tree as `top`
# and their own uid as `root_uid` (the seam); the end-to-end cases run a copy whose constants name that tree and uid, as
# baton_isolate rewrites MANAGED_SETTINGS. Offline; nothing outside the scratch tree.
#   [U] in process: no file; a user-owned file or parent; another user namespace (its uid_map not the identity map, or not on
#       procfs); a group-writable file; a group- or other-writable parent; a symlinked file or parent; a FIFO; content that is not
#       exactly auto or manual; a valid auto and manual
#   [E] end to end: in a pod with policy auto, a Stops: none baton runs signed coordinator-auto, a stop-list baton keeps the
#       hand-off, the mode change stays refused naming the policy (baton and the guard), reading the mode and permissions --check
#       name the source; an ignored file is a NOTE and reads manual; the owner's choice wins over the policy; no file: the default
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
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
clean_env "$TMP"          # unsets SEAT and INTENT_SLUG: a case sets them itself, through BT_ENV
export PYTHONDONTWRITEBYTECODE=1
H0=$(tree_hash "$SRC_ROOT")
BT_OUT="$TMP/bt.out"; BT_ERR="$TMP/bt.err"; ST=""; BT_ENV=()
POD=(SEAT=pod-seat INTENT_SLUG=pod-intent)
ME=$(id -u)
M=mo; M="${M}de"           # the mode command's word, built at run time

# bt <plugin> <dir> <baton args...> — rc of baton from <dir>, state in $ST, plus BT_ENV; stdout in $BT_OUT, stderr in $BT_ERR
bt() {
  local p=$1 d=$2; shift 2
  ( cd "$d" && cenv XDG_STATE_HOME="$ST" CLAUDE_CODE_SESSION_ID=s-pol ${BT_ENV[@]+"${BT_ENV[@]}"} python3 "$p/scripts/baton.py" "$@" ) \
    > "$BT_OUT" 2> "$BT_ERR"
  echo $?
}
both() { cat "$BT_OUT" "$BT_ERR"; }

# policy_copy <dir> — a plugin copy whose machine policy lives at <dir>.policy/etc/vibemaestro/baton-mode, the tree's top
# <dir>.policy, and "root" is this suite's uid: the copy's constants, never a variable
policy_copy() {
  mk_plugin_copy "$1"
  python3 - "$1/scripts/baton.py" "$1.policy" "$ME" <<'PY' || { bad "policy_copy: a constant was not found in $1"; return 1; }
import re, sys
p, top, uid = sys.argv[1:4]
s = open(p, encoding="utf-8").read()
for pat, new in ((r'(?m)^MODE_POLICY = ".*"$', 'MODE_POLICY = "%s/etc/vibemaestro/baton-mode"' % top),
                 (r"(?m)^POLICY_ROOT_UID = 0$", "POLICY_ROOT_UID = %s" % uid),
                 (r'(?m)^POLICY_TOP = "/"$', 'POLICY_TOP = "%s"' % top)):
    s, n = re.subn(pat, lambda _: new, s)
    if n != 1:
        sys.exit(1)
open(p, "w", encoding="utf-8").write(s)
PY
}
# tree <top> [mode] — a fresh policy tree under <top>: the directories exactly 0755, the file 0644 holding <mode> and a newline.
# A directory made under a setgid parent (a CI runner's temp) inherits setgid, and a numeric chmod keeps it: g-s clears it,
# so the modes the cases name are the modes they get.
tree() {
  chmod -R u+w "$1" 2>/dev/null; rm -rf "$1"; mkdir -p "$1/etc/vibemaestro"
  chmod 755 "$1" "$1/etc" "$1/etc/vibemaestro"; chmod g-s "$1" "$1/etc" "$1/etc/vibemaestro"
  if [ $# -gt 1 ]; then printf '%s\n' "$2" > "$1/etc/vibemaestro/baton-mode"; chmod 644 "$1/etc/vibemaestro/baton-mode"; fi
}
# pol <plugin> <top> <root uid> [<file uid> [<namespace answer>]] — machine_policy(<top>/etc/vibemaestro/baton-mode, <root uid>,
# <top>) in process: "mode|why". The seams, in that process only: <file uid> is the owner fstat reports for the open file (a
# file of another user, as a non-root suite cannot chown), <namespace answer> what initial_userns returns.
pol() {
  timeout 20 python3 - "$1/scripts/baton.py" "$2" "$3" "${4:-}" "${5:-}" <<'PY'
import importlib.util, os, sys
s = importlib.util.spec_from_file_location("baton_under_test", sys.argv[1]); b = importlib.util.module_from_spec(s)
s.loader.exec_module(b)
if sys.argv[4]:
    real = os.fstat
    def fstat(fd, _uid=int(sys.argv[4])):
        st = list(real(fd))
        st[4] = _uid
        return os.stat_result(st)
    b.os = type(os)("os_seam"); b.os.__dict__.update(os.__dict__); b.os.fstat = fstat
if sys.argv[5]:
    b.initial_userns = lambda: sys.argv[5]
m, why = b.machine_policy(sys.argv[2] + "/etc/vibemaestro/baton-mode", int(sys.argv[3]), sys.argv[2])
print("%s|%s" % (m, why))
PY
}

# uns <plugin> <file> [fstatfs-fails] — initial_userns() in process, with /proc/self/uid_map opened as <file>; with
# fstatfs-fails, the ctypes the function imports has an fstatfs that fails
uns() {
  timeout 20 python3 - "$1/scripts/baton.py" "$2" "${3:-}" <<'PY'
import ctypes, importlib.util, os, sys
s = importlib.util.spec_from_file_location("baton_under_test", sys.argv[1]); b = importlib.util.module_from_spec(s)
s.loader.exec_module(b)
real = os.open
b.os = type(os)("os_seam"); b.os.__dict__.update(os.__dict__)
b.os.open = lambda p, *a, **k: real(sys.argv[2] if p == "/proc/self/uid_map" else p, *a, **k)
if sys.argv[3] == "fstatfs-fails":
    class Libc:
        def __init__(self, *a, **k): pass
        def fstatfs(self, fd, buf): return -1
    fake = type(ctypes)("ctypes"); fake.__dict__.update(ctypes.__dict__); fake.CDLL = Libc
    sys.modules["ctypes"] = fake
print(b.initial_userns())
PY
}

fam_unit() {
  local P=$1 T r F
  T="$(fresh)/top"; F="$T/etc/vibemaestro/baton-mode"
  tree "$T"
  eq "$(pol "$P" "$T" "$ME")" "None|None" "[U] no file: no mode and no note"
  tree "$T" auto
  eq "$(pol "$P" "$T" "$ME")" "auto|None" "[U] a valid file auto: counts"
  tree "$T" manual
  eq "$(pol "$P" "$T" "$ME")" "manual|None" "[U] a valid file manual: counts"
  tree "$T"; printf 'auto' > "$F"; chmod 644 "$F"
  eq "$(pol "$P" "$T" "$ME")" "auto|None" "[U] auto without a newline: counts"
  # a user-owned file under root's directories: the directories are the suite's (its uid is root here), the file another
  # user's, through the fstat seam
  tree "$T" auto
  eq "$(pol "$P" "$T" "$ME" $((ME + 1)))" "None|$F is owned by uid $((ME + 1)), not root" "[U] user-owned file: ignored, as not root's"
  # a user-owned parent: root is uid 0, the tree the suite's (as root, the top is handed to uid 65534)
  tree "$T" auto; U=$ME
  if [ "$ME" = 0 ]; then chown 65534 "$T"; U=65534; fi
  eq "$(pol "$P" "$T" 0)" "None|its directory $T is owned by uid $U, not root" "[U] user-owned parent: ignored, as not root's"
  # the user-namespace answer is honoured: a valid tree, with initial_userns saying no through its seam
  tree "$T" auto
  eq "$(pol "$P" "$T" "$ME" "" "a fake namespace")" "None|a fake namespace" "[U] another user namespace: the policy is ignored"
  tree "$T" auto; chmod 664 "$F"
  eq "$(pol "$P" "$T" "$ME")" "None|$F is writable by group or other (mode 0664)" "[U] group-writable file: ignored"
  tree "$T" auto; chmod 646 "$F"
  eq "$(pol "$P" "$T" "$ME")" "None|$F is writable by group or other (mode 0646)" "[U] other-writable file: ignored"
  tree "$T" auto; chmod 775 "$T/etc/vibemaestro"
  eq "$(pol "$P" "$T" "$ME")" "None|its directory $T/etc/vibemaestro is writable by group or other (mode 0775)" "[U] group-writable parent: ignored"
  tree "$T" auto; chmod 1777 "$T/etc"
  eq "$(pol "$P" "$T" "$ME")" "None|its directory $T/etc is writable by group or other (mode 1777)" "[U] a sticky world-writable parent, as /tmp: ignored"
  tree "$T" auto; chmod 775 "$T"
  eq "$(pol "$P" "$T" "$ME")" "None|its directory $T is writable by group or other (mode 0775)" "[U] the top itself group-writable: ignored"
  # a symlinked file: the link points at a valid file of the same tree
  tree "$T" auto; mv "$F" "$T/etc/real"; ln -s "$T/etc/real" "$F"
  eq "$(pol "$P" "$T" "$ME")" "None|$F is a symlink" "[U] symlink file to a valid one: ignored"
  # a symlinked parent: etc/vibemaestro points at a valid directory
  tree "$T" auto; mv "$T/etc/vibemaestro" "$T/etc/other"; ln -s "$T/etc/other" "$T/etc/vibemaestro"
  eq "$(pol "$P" "$T" "$ME")" "None|its directory $T/etc/vibemaestro is a symlink" "[U] symlinked parent to a valid one: ignored"
  tree "$T"; mkfifo "$F"; chmod 644 "$F"
  eq "$(pol "$P" "$T" "$ME")" "None|$F is not a regular file" "[U] a FIFO: ignored, and no hang"
  tree "$T"; mkdir "$F"; chmod 755 "$F"
  eq "$(pol "$P" "$T" "$ME")" "None|$F is not a regular file" "[U] a directory at the path: ignored"
  local c
  for c in 'auto ' 'Auto' $'auto\n' 'auto manual' '' ; do
    tree "$T"; printf '%s\n' "$c" > "$F"; chmod 644 "$F"
    case "$(pol "$P" "$T" "$ME")" in "None|$F holds "*", not exactly auto or manual") ok "[U] content $(printf '%q' "$c"): ignored";;
      *) bad "[U] content $(printf '%q' "$c"): ignored";; esac
  done
  tree "$T"; head -c 5000 /dev/zero | tr '\0' a > "$F"; chmod 644 "$F"
  eq "$(pol "$P" "$T" "$ME")" "None|$F is larger than 64 bytes" "[U] a long file: ignored"
  # the user namespace: this machine's own answer, matched against its uid_map (a CI runner and our pods are the initial one)
  r=$(python3 - "$P/scripts/baton.py" <<'PY'
import importlib.util, sys
s = importlib.util.spec_from_file_location("baton_under_test", sys.argv[1]); b = importlib.util.module_from_spec(s)
s.loader.exec_module(b)
print(b.initial_userns())
PY
)
  if [ "$(tr -s ' \n' ' ' < /proc/self/uid_map 2>/dev/null)" = " 0 0 4294967295 " ]; then
    eq "$r" None "[U] the initial user namespace: the policy may count"
  else
    nonempty "${r#None}" "[U] outside the initial user namespace: the policy never counts"
  fi
  # initial_userns itself, with /proc/self/uid_map opened as another file (an in-process seam on os.open): a plain file holding
  # the identity map is not procfs; a procfs file that is not the identity map is another user namespace
  if [ "$(uname -s)" = Linux ]; then
    printf '0 0 4294967295\n' > "$T.map"
    eq "$(uns "$P" "$T.map")" "/proc/self/uid_map is not on procfs" "[U] uid_map not on procfs: not the initial user namespace"
    has "$(uns "$P" /proc/self/stat)" "this process runs in a user namespace" "[U] uid_map not the identity map: not the initial user namespace"
    has "$(uns "$P" "$T.none")" "/proc/self/uid_map cannot be read" "[U] uid_map that cannot be opened: not the initial user namespace"
    eq "$(uns "$P" /proc/self/uid_map fstatfs-fails)" "/proc/self/uid_map: fstatfs failed" "[U] uid_map whose fstatfs fails: not the initial user namespace"
    has "$(uns "$P" /proc/sys)" "/proc/self/uid_map cannot be checked" "[U] uid_map that cannot be read (a procfs directory): not the initial user namespace"
  fi
}

# the batons: a Stops: none one (the positional fixture) and a stop-list one with Params (what the hand-off names)
mk_cases() {
  W=$(fresh); ST="$W/state"; git init -q "$W"
  cp "$SRC_ROOT/tests/fixtures/baton-positional.sh" "$W/plain.sh"
  python3 "$HERE/fixtures/baton_params.py" make "$1" "$W/pp.sh" "dest=path" "{dest}/** — the file"
  sed -i 's/^# Stops: none$/# Stops: publish/' "$W/pp.sh"
}
# guard_reason <plugin> <dir> <command> — the guard hook's decision and reason for the Bash call <command>, from <dir>, plus BT_ENV
guard_reason() {
  local pl
  pl=$(python3 -c 'import json, sys
print(json.dumps({"session_id": "s-pol", "permission_mode": "default", "cwd": sys.argv[1], "hook_event_name": "PreToolUse",
                  "tool_name": "Bash", "tool_input": {"command": sys.argv[2]}}))' "$2" "$3")
  printf '%s' "$pl" | ( cd "$2" && cenv XDG_STATE_HOME="$ST" ${BT_ENV[@]+"${BT_ENV[@]}"} python3 "$1/scripts/baton-guard.py" ) 2>/dev/null \
    | python3 -c 'import json, sys
t = sys.stdin.read().strip()
o = json.loads(t)["hookSpecificOutput"] if t else {}
print("%s|%s" % (o.get("permissionDecision", ""), o.get("permissionDecisionReason", "")))'
}

fam_e2e() {
  local P=$1 T="$1.policy" F="$1.policy/etc/vibemaestro/baton-mode" W rc r
  local SRC="the machine policy $F"
  # [E] a pod, policy auto
  tree "$T" auto; mk_cases "$P"; BT_ENV=("${POD[@]}")
  eq "$(bt "$P" "$W" go "$W/plain.sh" "$W/o.txt" hello)" 0 "[E] pod, policy auto: a Stops: none baton runs (rc 0)"
  has "$(cat "$BT_OUT")" "go: ok" "[E] pod, policy auto: …go: ok"
  eq "$(cat "$W/o.txt" 2>/dev/null)" hello "[E] pod, policy auto: …and wrote its file"
  has "$(grep -P '\tsign\t' "$ST/vibemaestro/baton/log.tsv" 2>/dev/null)" "coordinator-auto" "[E] pod, policy auto: …signed coordinator-auto"
  rc=$(bt "$P" "$W" go "$W/pp.sh" dest="$W/dst")
  eq "$rc" 8 "[E] pod, policy auto: a stop-list baton still stops (exit 8)"
  has "$(both)" "hand the call to the coordinator" "[E] pod, policy auto: …with the hand-off"
  hasnt "$(both)" "sign --by owner" "[E] pod, policy auto: …and no owner sign line"
  eq "$(bt "$P" "$W" "$M" auto)" 3 "[E] pod, policy auto: the $M change stays refused (rc 3)"
  has "$(both)" "the $M here is auto from $SRC, which only root sets" "[E] pod, policy auto: …its refusal names the policy"
  has "$(guard_reason "$P" "$W" "python3 $P/scripts/baton.py $M manual")" \
      "deny|baton: $M refused: a sandbox session: whoever answers its dialog is not the owner; the $M here is auto from $SRC, which only root sets" \
      "[E] pod, policy auto: the guard denies the $M change, naming the policy"
  eq "$(bt "$P" "$W" "$M" trust https://example.com/o/r)" 3 "[E] pod, policy auto: a remote-list change stays refused (rc 3)"
  hasnt "$(both)" "the $M here is" "[E] pod, policy auto: …and its refusal does not name the policy"
  r=$(guard_reason "$P" "$W" "python3 $P/scripts/baton.py $M trust https://example.com/o/r")
  has "$r" "deny|baton: $M refused: a sandbox session: whoever answers its dialog is not the owner" "[E] pod, policy auto: the guard denies a remote-list change"
  hasnt "$r" "the $M here is" "[E] pod, policy auto: …and its deny does not name the policy"
  eq "$(bt "$P" "$W" "$M")" 0 "[E] pod, policy auto: reading the $M: rc 0"
  eq "$(cat "$BT_OUT")" auto "[E] pod, policy auto: …stdout is the word alone"
  eq "$(cat "$BT_ERR")" "baton: $M auto from $SRC" "[E] pod, policy auto: …stderr names the source"
  bt "$P" "$W" permissions --check >/dev/null
  has "$(head -n 1 "$BT_OUT")" "baton permissions: $M auto (from $SRC); settings read:" "[E] pod, policy auto: permissions --check names the source"
  hasnt "$(cat "$BT_OUT")" "NOTE" "[E] pod, policy auto: …and no note"
  # [E] an ignored file: a NOTE, and the default
  chmod 666 "$F"
  eq "$(bt "$P" "$W" "$M")/$(cat "$BT_OUT")/$(cat "$BT_ERR")" "0/manual/baton: $M manual from the default" "[E] pod, a group-writable policy: reads the default"
  bt "$P" "$W" permissions --check >/dev/null
  has "$(head -n 1 "$BT_OUT")" "$M manual (from the default)" "[E] pod, a group-writable policy: permissions --check reads the default"
  has "$(cat "$BT_OUT")" "NOTE       the machine policy is ignored: $F is writable by group or other (mode 0666) (it does not change the exit code)" \
      "[E] pod, a group-writable policy: …with the note naming why"
  eq "$(bt "$P" "$W" go "$W/plain.sh" "$W/o2.txt" hello)" 8 "[E] pod, a group-writable policy: a Stops: none baton stops (exit 8)"
  # [E] the owner's choice wins; the policy counts outside a pod too; a policy manual asks no question
  tree "$T" auto; mk_cases "$P"; BT_ENV=(); baton_set_mode "$ST" manual
  eq "$(bt "$P" "$W" "$M")/$(cat "$BT_OUT")/$(cat "$BT_ERR")" "0/manual/baton: $M manual from the owner's choice" "[E] owner wins: the owner's manual over the policy auto"
  eq "$(bt "$P" "$W" go "$W/plain.sh" "$W/o.txt" hello)" 8 "[E] owner wins: …a Stops: none baton stops (exit 8)"
  mk_cases "$P"; BT_ENV=()
  eq "$(bt "$P" "$W" go "$W/plain.sh" "$W/o.txt" hello)" 0 "[E] no pod, no owner choice, policy auto: the baton runs"
  tree "$T" manual; mk_cases "$P"
  eq "$(bt "$P" "$W" go "$W/plain.sh" "$W/o.txt" hello)" 8 "[E] policy manual: a Stops: none baton stops (exit 8)"
  hasnt "$(both)" "not chosen yet" "[E] policy manual: …and the card asks no $M question"
  # [E] no file: the default, no note
  tree "$T"; mk_cases "$P"
  eq "$(bt "$P" "$W" "$M")/$(cat "$BT_OUT")/$(cat "$BT_ERR")" "0/manual/baton: $M manual from the default" "[E] no file: the default"
  bt "$P" "$W" permissions --check >/dev/null
  has "$(head -n 1 "$BT_OUT")" "$M manual (from the default)" "[E] no file: permissions --check names the default"
  hasnt "$(cat "$BT_OUT")" "NOTE" "[E] no file: …and no note"
  eq "$(bt "$P" "$W" go "$W/plain.sh" "$W/o.txt" hello)" 8 "[E] no file: a Stops: none baton stops as before (exit 8)"
  has "$(both)" "not chosen yet" "[E] no file: …and asks the $M question as before"
}

echo "== the real plugin =="
REAL="$TMP/real"; policy_copy "$REAL"
echo "-- fam_unit"; fam_unit "$REAL"
echo "-- fam_e2e"; fam_e2e "$REAL"
eq "$(cd "$TMP" && cenv XDG_STATE_HOME="$TMP/st0" python3 -c 'import importlib.util, sys
s = importlib.util.spec_from_file_location("b", sys.argv[1]); b = importlib.util.module_from_spec(s); s.loader.exec_module(b)
print(b.MODE_POLICY, b.POLICY_ROOT_UID, b.POLICY_TOP)' "$PLUGIN/scripts/baton.py")" "/etc/vibemaestro/baton-mode 0 /" \
   "the real plugin: the policy at /etc/vibemaestro/baton-mode, root uid 0, checked from /"

echo "== nothing written outside the scratch tree =="
eq "$(tree_hash "$SRC_ROOT")" "$H0" "the repository tree is unchanged by the suite"
echo; summary
