#!/usr/bin/env bash
# Purpose: add permission rules (and attribution keys that are absent) to a Claude Code settings file; remove none
# Targets: the settings file named by the first argument; a backup and a run record under the baton state directory
# Blast: that one file; its other keys and rules are kept (it is rewritten as JSON with two-space indent)
# Undo: restores the backup the run record names, only when the record is this run's (it holds the sha256 of the signed plan baton hands undo) and the file still has the merged sha256; else it stops, exit 5
# Pre: both files are JSON: the settings an object, the rules an object of allow, ask and deny string lists and an optional attribution object; the settings path is not a symbolic link
# Stops: security-boundary
# Usage: <settings.json> <rules.json>
# Expect: backup *
# Expect: record *
# Expect: merge *
#
# A baton script of kind settings-merge (BatonRun): run as is with `<launcher> go kind:settings-merge <settings.json> <rules.json>`
# (no script to write; Stops security-boundary, so go stops for the owner, exit 8), or written by `baton new __NAME__ --from
# settings-merge` to change it. The contract (the header above, the phases, the write() gate, check, rehearse, sign, run) is the
# one `baton new` writes without --from: its comments explain each part. Run the launcher bare, one command per call:
# <launcher> go __NAME__.sh <args>
# A rule in `allow` widens what a session may do: keep Stops: security-boundary then; `none` fits ask and deny rules only.
# An `attribution` object in the rules file is add-only (the kit's setup turns attribution off): with no
# `attribution` key in the settings it is added whole; an object there gains only the keys it lacks; any other explicit value
# (`false`, a value of a key already there) is never changed.
# The merge changes the file's sha256, so undo cannot find the backup from a read: the run writes a record (backup path and
# the merged sha256 and the sha256 of the signed plan, BATON_PLAN) under the baton state directory, named after the settings
# path's sha256 (two settings files, two records). A record stays after a run that held, so undo works from it only when its
# plan sha256 is this run's, and only while the file still has the merged sha256. The restore, like the merge, goes through a
# mktemp file next to the settings file, so a read-only settings file is put back too.
# The backup is a whole copy of the settings file (an `env` block too), named after the path and the bytes before, so it is
# kept only for the undo: the run lists it in BATON_UNDO_ONLY, and baton removes it once the run ended ok or its undo put the
# file back. Only an unknown state keeps it, for the owner. The record (paths and sha256, no settings bytes) stays.
# `kind:settings-merge` keeps its positional arguments (`# Usage:`). A copy meant to be kept with `baton pack` declares
# `# Params:` instead, reads its values in a block of `P_<KEY>="$<n>"` lines and declares Targets as `{key}` patterns.
# bash 3.2 (macOS) runs this file: no associative arrays, no ${var,,}, no mapfile.
set -euo pipefail
PHASE=${BATON_PHASE:-rehearse}

# write <plan line> <command> [args...] — the one gate for every change. A change whose after-state shows late (a log line,
# a status) waits for it inside the command it runs, with a time limit, so the post-check is not a race.
write() {
  local plan=$1
  shift
  case "$PHASE" in
    rehearse)
      printf 'PLAN %s\n' "$plan"
      printf '%s\n' "$plan" >> "${BATON_WRITES:-/dev/null}"
      ;;
    run | undo)
      printf 'DO %s\n' "$plan"
      printf '%s\n' "$plan" >> "${BATON_WRITES:-/dev/null}"
      "$@"
      ;;
    *)
      printf 'write called in phase %s: %s\n' "$PHASE" "$plan" >&2
      return 70
      ;;
  esac
}

# ── arguments and reads: every phase runs them ──
if [ $# -ne 2 ]; then
  echo "usage: bash __NAME__.sh <settings.json> <rules.json>" >&2
  exit 64
fi
SETTINGS=$1
RULES=$2
case "$SETTINGS" in /*) ;; *) SETTINGS="$PWD/$SETTINGS" ;; esac
case "$RULES" in /*) ;; *) RULES="$PWD/$RULES" ;; esac
# the baton state directory, as baton computes it; the backup and the run record live under it
case "${XDG_STATE_HOME:-}" in
  /*) STATE_BASE=$XDG_STATE_HOME ;;
  *) STATE_BASE="$HOME/.local/state" ;;
esac
RECORDS="$STATE_BASE/vibemaestro/baton/records"
path_key() { printf '%s' "$SETTINGS" | python3 -I -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:16])'; }
RECORD="$RECORDS/__NAME__-$(path_key).last"

sha_of() { python3 -I -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"; }
mode_of() { python3 -I -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])' "$1"; }
# merged <settings> <rules> [counts|total] — the merged settings on stdout (rules added in order, none removed), or with `counts`
# the line "allow +N [the rules], ask +N, deny +N[, attribution +N [the keys]]", so the plan line (and the owner's card) names
# each rule, or with `total` the number of rules and keys added; exit 3 on a file that is not the expected JSON
merged() {
  python3 -I - "$1" "$2" "${3:-}" <<'PY'
import json, sys
path, rules_path, mode = sys.argv[1:4]
try:
    s = json.load(open(path))
    r = json.load(open(rules_path))
except (OSError, ValueError) as e:
    sys.stderr.write("REFUSE cannot read the JSON: %s\n" % e)
    sys.exit(3)
keys = ("allow", "ask", "deny")
attr = r.pop("attribution", None) if isinstance(r, dict) else None
if not isinstance(s, dict) or not isinstance(s.get("permissions", {}), dict) or not isinstance(r, dict) or set(r) - set(keys) \
        or any(not isinstance(r[k], list) or any(not isinstance(x, str) for x in r[k]) for k in r) \
        or (attr is not None and (not isinstance(attr, dict) or any(not isinstance(v, (str, bool)) for v in attr.values()))):
    sys.stderr.write("REFUSE the settings must be a JSON object, the rules an object of allow/ask/deny string lists and an "
                     "optional attribution object of strings and booleans\n")
    sys.exit(3)
perms = s.get("permissions", {})
added = {}
names = {}
for k in keys:
    have = perms.get(k, [])
    if not isinstance(have, list):
        sys.stderr.write("REFUSE permissions.%s is not a list\n" % k)
        sys.exit(3)
    new = [x for i, x in enumerate(r.get(k, [])) if x not in have and x not in r[k][:i]]
    added[k] = len(new)
    names[k] = " " + json.dumps(new) if new else ""
    if new:
        perms[k] = have + new
        s["permissions"] = perms                    # a settings file without one gains it only with a rule added
parts = ["%s +%d%s" % (k, added[k], names[k]) for k in keys]
if attr is not None:
    have = s.get("attribution")
    if "attribution" not in s:
        new = list(attr)
        s["attribution"] = dict(attr)
    elif isinstance(have, dict):
        new = [k for k in attr if k not in have]
        have.update((k, attr[k]) for k in new)
    else:
        new = []                                    # an explicit value that is not an object: never flipped
    added["attribution"] = len(new)
    parts.append("attribution +%d%s" % (len(new), " " + json.dumps(new) if new else ""))
if mode == "counts":
    print(", ".join(parts))
elif mode == "total":
    print(sum(added.values()))
else:
    sys.stdout.write(json.dumps(s, indent=2) + "\n")
PY
}
after_sha() { merged "$SETTINGS" "$RULES" | python3 -I -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'; }
# backup_to <path> — the backup is written afresh and listed for removal once the run's state is known (a signed run only: the
# merge a kit simulates has no plan). One already there for this path holds these very bytes, which the file holds now: the
# run takes it over.
backup_to() {
  mkdir -p "$RECORDS" && cp -f "$SETTINGS" "$1" || return 1    # -f: a read-only one (a read-only file's backup) too
  if [ -n "${BATON_PLAN:-}" ]; then printf '%s\n' "$1" >> "${BATON_UNDO_ONLY:-/dev/null}"; fi
}
# plan_id — the sha256 of the signed plan baton hands the run and its undo (BATON_PLAN): which run a record belongs to
plan_id() { if [ -n "${BATON_PLAN:-}" ] && [ -f "$BATON_PLAN" ]; then sha_of "$BATON_PLAN"; fi; }
record() { mkdir -p "$RECORDS" && printf '%s %s %s\n' "$1" "$2" "$(plan_id)" > "$RECORD"; }
restore() {
  local tmp
  tmp=$(mktemp "$SETTINGS.baton-new.XXXXXX") || return 1
  if cp "$BACKUP" "$tmp" && chmod "$(mode_of "$SETTINGS")" "$tmp" && mv -f "$tmp" "$SETTINGS"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}
# the merged file goes through a new file mktemp makes next to it (no predictable name a link could sit on), with the file's mode
merge_in() {
  local tmp
  tmp=$(mktemp "$SETTINGS.baton-new.XXXXXX") || return 1
  if merged "$SETTINGS" "$RULES" > "$tmp" && chmod "$(mode_of "$SETTINGS")" "$tmp" && mv -f "$tmp" "$SETTINGS"; then
    return 0
  fi
  rm -f -- "$tmp"
  return 1
}

# ── the act: every change through write() ──
act() {
  if [ ! -f "$SETTINGS" ] || [ ! -f "$RULES" ]; then
    echo "REFUSE $SETTINGS and $RULES must both be files" >&2
    return 3
  fi
  if [ -L "$SETTINGS" ]; then
    echo "REFUSE $SETTINGS is a symbolic link: name the file it leads to" >&2
    return 3
  fi
  local counts before after backup
  counts=$(merged "$SETTINGS" "$RULES" counts)
  if [ "$(merged "$SETTINGS" "$RULES" total)" = 0 ]; then
    echo "same $SETTINGS (every rule is there; nothing to do)"
    return 0
  fi
  before=$(sha_of "$SETTINGS")
  after=$(after_sha)
  backup="$RECORDS/__NAME__-$(path_key)-$before.json"
  write "backup $SETTINGS sha256 $before to $backup" backup_to "$backup"
  write "record $RECORD: the backup, and sha256 $after once merged" record "$backup" "$after"
  write "merge $counts into $SETTINGS (rules sha256 $(sha_of "$RULES"))" merge_in
}

# ── post-check: the file is what the merge makes, as the run record says ──
postcheck() {
  local backup after
  [ -f "$RECORD" ] || return 1
  read -r backup after _run < "$RECORD"
  [ -f "$backup" ] && [ "$(sha_of "$SETTINGS")" = "$after" ]
}

# ── undo: the record says which backup and which after-state; a file that moved since is left alone (exit 5) ──
# The merge changes the file's sha, so undo cannot recompute the backup's name from a read: the run record names it.
undo() {
  local BACKUP AFTER NOW RUNID MINE
  if [ ! -f "$RECORD" ]; then
    echo "no run record: the merge never ran, nothing to put back"
    return 0
  fi
  read -r BACKUP AFTER RUNID < "$RECORD"
  # the record stays after a run that held, so it may be an earlier run's: the signed plan's sha256 names the run
  MINE=$(plan_id)
  if [ -z "$MINE" ]; then
    echo "LEAVE no signed plan (BATON_PLAN): cannot tell whether $RECORD is this run's" >&2
    return 1
  fi
  if [ "${RUNID:-}" != "$MINE" ]; then
    echo "the run record $RECORD is an earlier run's: nothing of this run to put back"
    return 0
  fi
  NOW=$(sha_of "$SETTINGS")
  if [ "$NOW" = "$AFTER" ]; then
    write "restore $SETTINGS from $BACKUP" restore
  elif [ "$NOW" = "$(sha_of "$BACKUP")" ]; then
    echo "same $SETTINGS as its backup: the merge never landed"
  else
    echo "LEAVE $SETTINGS changed since the run (sha256 $NOW): compare it with $BACKUP by hand" >&2
    return 1
  fi
  write "drop the run record $RECORD" rm -f -- "$RECORD"
  [ "$(sha_of "$SETTINGS")" = "$(sha_of "$BACKUP")" ]
}

case "$PHASE" in
  rehearse)
    act
    echo "VERDICT rehearse ok"
    ;;
  run)
    act
    echo "VERDICT run ok"
    ;;
  postcheck)
    postcheck
    echo "VERDICT postcheck ok"
    ;;
  undo)
    undo
    echo "VERDICT undo ok"
    ;;
  *)
    echo "unknown phase: $PHASE" >&2
    exit 64
    ;;
esac
