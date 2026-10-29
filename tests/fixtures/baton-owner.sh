# shellcheck shell=bash
# =============================================================================
# The owner's dialog in the baton suites: a `sign --by owner` signs only with the record the plugin's guard hook writes
# (sourced AFTER lib.sh and ports.sh by the suites that sign as the owner; defines functions only)
# =============================================================================

# baton_isolate <plugin copy> — the owner's-dialog checks of baton.py read the machine around them: the managed settings (a
# sandbox pod holds a PermissionRequest hook there), the account's home from the password database, and every ancestor
# process. A suite must not depend on the machine it runs on, so the copy reads <copy>.isolate/managed-settings.json and the
# account home <copy>.isolate/account, and stops its ancestor walks at the suite's shell: only what a case starts is an ancestor.
# It also turns LINEAGE off (a case has no Claude Code process to bind a record to); fam_owner_lineage turns it back on.
baton_isolate() {
  local iso="${1%/}.isolate"; mkdir -p "$iso/account"
  python3 - "$1/scripts/baton.py" "$iso" "$$" <<'PY' || { bad "baton_isolate: a line to isolate was not found in $1"; return 1; }
import re, sys
p, iso, pid = sys.argv[1:4]
s = open(p, encoding="utf-8").read()
subs = ((r"(?m)^MANAGED_SETTINGS = \(.*\)$", 'MANAGED_SETTINGS = ("%s/managed-settings.json",)\nSUITE_PID = %s' % (iso, pid)),
        (r"(?m)^        return pwd\.getpwuid\(os\.getuid\(\)\)\.pw_dir$", '        return "%s/account"' % iso),
        (r"(?m)^        if pid <= 1:$", "        if pid <= 1 or pid == SUITE_PID:"),
        (r"(?m)^        if pid < 2:$", "        if pid < 2 or pid == SUITE_PID:"),
        (r"(?m)^LINEAGE = True ", "LINEAGE = False "))
for pat, new in subs:
    s, n = re.subn(pat, lambda _: new, s)
    if n != 1:
        sys.exit(1)
open(p, "w", encoding="utf-8").write(s)
PY
}

# guard_cmd <plugin> <dir> <state> <session> <command> — the plugin's guard hook (hooks.json's baton-guard.py) run as Claude Code
# runs it for the Bash call <command> from <dir>, mode BATON_ASK_MODE (default), plus BT_ENV: in a mode with a dialog it writes the
# record `sign --by owner` needs. Prints the hook's decision (ask, deny, or nothing).
guard_cmd() {
  local p=$1 d=$2 st=$3 ses=$4 pl
  pl=$(python3 -c 'import json, sys
d, ses, mode, cmd = sys.argv[1:5]
print(json.dumps({"session_id": ses, "permission_mode": mode, "cwd": d, "hook_event_name": "PreToolUse", "tool_name": "Bash",
                  "tool_input": {"command": cmd}}))' "$d" "$ses" "${BATON_ASK_MODE:-default}" "$5")
  printf '%s' "$pl" | ( cd "$d" && cenv XDG_STATE_HOME="$st" ${BT_ENV[@]+"${BT_ENV[@]}"} python3 "$p/scripts/baton-guard.py" ) 2>/dev/null \
    | python3 -c 'import json, sys
t = sys.stdin.read().strip()
print(json.loads(t)["hookSpecificOutput"]["permissionDecision"] if t else "")'
}
# owner_asked <plugin> <dir> <state> <session> <args after `sign`...> — guard_cmd for `python3 <plugin>/scripts/baton.py sign <args>`
owner_asked() {
  local p=$1 d=$2 st=$3 ses=$4; shift 4
  guard_cmd "$p" "$d" "$st" "$ses" "$(python3 -c 'import shlex, sys; print(shlex.join(["python3", sys.argv[1] + "/scripts/baton.py", "sign"] + sys.argv[2:]))' "$p" "$@")"
}
# mode_asked <plugin> <dir> <state> <session> <args after `mode`...> — guard_cmd for `python3 <plugin>/scripts/baton.py mode <args>`:
# the record a mode change needs, as the owner's click on the hook's dialog leaves it
mode_asked() {
  local p=$1 d=$2 st=$3 ses=$4; shift 4
  guard_cmd "$p" "$d" "$st" "$ses" "$(python3 -c 'import shlex, sys; print(shlex.join(["python3", sys.argv[1] + "/scripts/baton.py", "mode"] + sys.argv[2:]))' "$p" "$@")"
}
