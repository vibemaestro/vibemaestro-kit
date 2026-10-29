#!/usr/bin/env bash
# Purpose: update every plugin of this machine's vibemaestro marketplace (user scope) through Claude Code's own plugin commands: vibemaestro-sdlc and vibemaestro-brain to kit main at one full SHA, and each marketplace-local plugin (./plugins/<name>) to the marketplace's main, for the kit's own marketplace or a git-subdir marketplace
# Targets: <claude-dir>/plugins: known_marketplaces.json, installed_plugins.json, the vibemaestro marketplace clone, new cache directories of the plugins it updates; a run record with byte copies of both JSON files and the run's targets under the baton state directory, kept seven days, or until the owner moves it when undo left it
# Blast: the vibemaestro marketplace's clone and the user-scope installs of its plugins: vibemaestro-sdlc, vibemaestro-brain and its marketplace-local plugins; no other scope or marketplace, no settings file
# Undo: from this run's record only: installed_plugins.json and known_marketplaces.json put back byte for byte from the copies made before the act, unless either changed outside the run's plugins and the marketplace since, a plugin of the run is no longer what the run left (another hand updated it), or the copy names an install that is gone (both files then stay, with the copies, for the owner); it names what it leaves: the new cache directories and the marketplace clone at the new marketplace head
# Pre: the SHA is 40 lower-case hex; CLAUDE_CONFIG_DIR is unset or absolute; the vibemaestro marketplace is a known github.com source at most at ref main, whose clone lies under <claude-dir>/plugins/marketplaces, is a repository git trusts, and has one origin URL, the known source's repository, with no URL rewrite, include or transport key (a proxy, a pinned address, a branch remote other than origin, an ssh command, TLS checks off) in its config, and git's real fetch URL (every config level) names that repository too; none of the git variables that point git at another repository or config file (GIT_DIR, GIT_CONFIG, …) is set; each marketplace entry carries only name, source and description; its layout is the kit's own marketplace or the git-subdir marketplace (sdlc and brain git-subdir of one https github.com repository at ref main), and names exactly one kit repository; every other entry is a marketplace-local plugin, source exactly ./plugins/<its name>; the clone's plugins directory and each local plugin's directory are real directories, and nothing under .claude-plugin or a local plugin's directory differs from the clone's HEAD; kit main is that SHA on GitHub, and the marketplace's main M is read from GitHub (in the kit's own layout M is the SHA); sdlc and brain have a user-scope install, a local plugin at most one; not every plugin at its target already; at each write, its plan line is in the signed plan; after the marketplace update, the layout, kit and local plugins are the same, kit main is still the SHA, the marketplace's main is still M, and the clone is at M, clean
# Stops: none
#   Why none (the owner's standing rule): updating the machine's own merged plugins is routine. The kit takes only kit main at a SHA
#   the session names, and the marketplace's own main at the commit the plan line pins, from the marketplace the machine already
#   has; the post-check proves each install is its commit (kit main can move between the check and the update: a git-subdir
#   source at ref main fetches the newest main), and undo puts both registry files back byte for byte. Another marketplace,
#   layout, ref or scope is refused at rehearse.
# Usage: <full kit sha>
# Each: plugin-update *
#
# The kit baton kit:plugin-update. Run it only through the baton runner:
#   <launcher> go kit:plugin-update <full kit sha>
# The claude directory is CLAUDE_CONFIG_DIR when set, else ~/.claude; a relative CLAUDE_CONFIG_DIR is refused. The layout
# is read from the marketplace clone, never assumed: (1) the kit's own marketplace (the two plugins at ./plugins/<name>; the kit
# is the github.com repository the known source and the clone's origin both name), (2) the git-subdir marketplace (the two plugins
# {"source": "git-subdir", "url": "https://github.com/<owner>/<name>(.git)", "path": "plugins/<name>", "ref": "main"}, one URL;
# the kit is that repository). In both, every other entry is a marketplace-local plugin, {"name": <name>, "source":
# "./plugins/<name>", "description"}, which claude installs from the clone's work tree; any other entry is refused. An entry
# with keys beyond name, source and description, a known source with other keys or another ref, a clone whose origin is not
# the known source's repository or that git does not trust, a clone whose git config has more than one origin URL, a URL
# rewrite or an include, a fetch URL that a rewrite in the owner's global, XDG or system git config takes off that
# repository, a git variable that points git at another repository or config file (GIT_DIR, GIT_CONFIG, …), any other layout,
# or one that names no kit repository or more than one, is refused. So is a transport key in the clone's own config
# (transport_keys: a proxy, a pinned address, a branch remote other than origin, an ssh command, TLS checks off); the owner's
# global and system config and the proxy variables stay the owner's own setup. A local plugin's directory, or the clone's
# plugins directory, that is a symlink is refused, and so is a file under .claude-plugin or a local plugin's directory that is
# not the clone's HEAD, read and hashed against `git ls-tree` with no replace ref (changed, missing, a file HEAD lacks, a
# symlink or submodule in HEAD), a filter in the clone's config, and a manifest key beyond the known ones or a pluginRoot.
# The clone is checked again before each local plugin's update.
# Kit main and the marketplace's main M are read from GitHub (`gh api --hostname github.com`), never from the clone. The plan
# lines carry the layout, the kit, the SHA, the marketplace repository with its old HEAD and M, each plugin with its old and
# new commit, and the sha256 of both registry files, so a world that moved since signing (M too) gives other lines and nothing
# runs. Each write checks its own line against the signed plan (BATON_PLAN) first. The marketplace update replaces the clone
# before any check can stop it: the run reads the layout, kit main and M again after it, and wants the clone at M with a clean
# tree; it refuses the plugin updates when any moved. A plugin already at its target is skipped; when all are, the kit
# refuses `nothing to do`. `claude plugin update` runs without -y: a marketplace-declared command fails the run instead of
# being accepted unseen.
# The post-check reads the registry: each plugin of the run's record (its targets) has one user entry that records
# gitCommitSha its target, a version of its first 12 hex (alone or with a dash and 8 hex), an installPath whose real path is
# <claude-dir>/plugins/cache/vibemaestro/<plugin>/<version>, a plugin.json with no version; the new sdlc's launcher template
# accepts every directory and resolves to the new sdlc. It then prints the setup step the session runs next, its paths
# shell-quoted. It writes nothing: the run record stays, and the next run of this kit deletes records older than seven days,
# except one undo marked left for the owner.
# The engine is gates/plugin_update.py (reads only; --help lists its modes); undo asks it whether the copies may go back, then
# puts them back itself with cp and mv.
# This script is plugin code: baton lets a kit baton, and nothing else, run a plugin gate as python3 -I -B "$BATON_PLUGIN_ROOT/gates/…".
# bash 3.2 (macOS) runs this file: no associative arrays, no ${var,,}, no mapfile.
set -euo pipefail
PHASE=${BATON_PHASE:-rehearse}

# write <plan line> <command> [args...] — the one gate for every change
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
if [ -z "${BATON_PLUGIN_ROOT:-}" ]; then
  echo "kit:plugin-update runs only through the baton runner (baton go kit:plugin-update <full kit sha>)" >&2
  exit 64
fi
usage() { echo "usage: baton rehearse|run kit:plugin-update <full kit sha>" >&2; }
if [ $# -ne 1 ] || ! [[ "$1" =~ ^[0-9a-f]{40}$ ]]; then
  usage
  exit 64
fi
SHA=$1
case "${CLAUDE_CONFIG_DIR:-}" in
  /*) CFG=$CLAUDE_CONFIG_DIR ;;
  "") CFG="$HOME/.claude" ;;
  *)
    echo "REFUSE CLAUDE_CONFIG_DIR is $CLAUDE_CONFIG_DIR, not an absolute path: claude and this kit could read different directories" >&2
    exit 3
    ;;
esac
PLUGINS="$CFG/plugins"
REG="$PLUGINS/installed_plugins.json"
KNOWN="$PLUGINS/known_marketplaces.json"
MKT=vibemaestro
NAMES="vibemaestro-sdlc vibemaestro-brain"
HOST=github.com

# the baton state directory, as baton computes it; the run record lives under it
case "${XDG_STATE_HOME:-}" in
  /*) STATE_BASE=$XDG_STATE_HOME ;;
  *) STATE_BASE="$HOME/.local/state" ;;
esac
RECORDS="$STATE_BASE/vibemaestro/baton/records"
# one record per runner process ($PPID: the runner that runs this run's phases, run, post-check and undo)
RECORD="$RECORDS/kit-plugin-update-$PPID"
LAUNCHER="$STATE_BASE/vibemaestro/baton/bin/baton"
sha256_file() {
  if command -v sha256sum > /dev/null 2>&1; then
    sha256sum < "$1" | cut -d' ' -f1
  else
    shasum -a 256 < "$1" | cut -d' ' -f1
  fi
}
sha256_text() {
  if command -v sha256sum > /dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
  else
    printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
  fi
}
# plan_id — the sha256 of the signed plan baton hands the run and its undo (BATON_PLAN): which run a record belongs to
plan_id() {
  if [ -n "${BATON_PLAN:-}" ] && [ -f "$BATON_PLAN" ]; then
    sha256_text "$(cat "$BATON_PLAN")"
  fi
}

# reader <mode> [args...] — the engine, gates/plugin_update.py of this plugin (--help lists its modes): it reads the two registry
# files and the clone, and never writes
reader() { python3 -I -B "$BATON_PLUGIN_ROOT/gates/plugin_update.py" "$@" < /dev/null; }

CLONE="" LAYOUT="" KIT="" REPO="" HEAD="" LOCALS="" OURS=""
# read_layout — sets CLONE, LAYOUT, KIT, REPO (the marketplace's repository), HEAD (the clone's commit), LOCALS (every
# marketplace-local plugin, space-separated, in manifest order) and OURS (those that are not sdlc or brain); rc 3 with the
# reader's REFUSE line on stderr
read_layout() {
  local o rc=0 k v
  o=$(reader layout "$CFG") || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "${o:-REFUSE the layout cannot be read}" >&2
    return 3
  fi
  LOCALS="" OURS=""
  while read -r k v; do
    case "$k" in
      CLONE) CLONE=$v ;;
      LAYOUT) LAYOUT=$v ;;
      KIT) KIT=$v ;;
      REPO) REPO=$v ;;
      HEAD) HEAD=$v ;;
      LOCAL)
        LOCALS="${LOCALS:+$LOCALS }$v"
        case " $NAMES " in *" $v "*) ;; *) OURS="${OURS:+$OURS }$v" ;; esac
        ;;
    esac
  done <<< "$o"
  transport_keys
}
# clean_tree <commit or -> — rc 3 with the reader's REFUSE line unless the clone is at that commit (- for any) and nothing under
# .claude-plugin or a local plugin's directory differs from its HEAD
clean_tree() {
  local o rc=0
  # shellcheck disable=SC2086 # LOCALS is a list of plugin names (no blanks: the reader's name pattern)
  o=$(reader tree "$CFG" "$1" $LOCALS) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "${o:-REFUSE the work tree of the clone cannot be read}" >&2
    return 3
  fi
}
# transport_keys — rc 3 with a REFUSE line when the clone's own git config (every file of the clone, as the reader reads it; not
# the owner's global or system config) sets a key that steers or weakens claude's fetch without changing the origin URL: a
# proxy (remote.origin.proxy, http.proxy, http.<url>.proxy, core.gitProxy), a pinned address (http[.<url>].curloptResolve), a
# branch remote other than origin (a bare fetch or pull reads it), a fetch refspec or a branch's merge ref onto another ref of
# origin, an ssh command, TLS checks off (http[.<url>].sslVerify), or a URL rewrite (url.<base>.insteadOf or pushInsteadOf,
# which the reader refuses too)
transport_keys() {
  local rec key val why b
  while IFS= read -r -d '' rec; do
    key=${rec%%$'\n'*} val="" why=""
    case "$rec" in *$'\n'*) val=${rec#*$'\n'} ;; esac
    case "$key" in
      remote.origin.proxy | http.proxy | http.*.proxy | core.gitproxy | http.curloptresolve | http.*.curloptresolve | \
        core.sshcommand | url.*.insteadof | url.*.pushinsteadof) why=: ;;
      branch.*.remote) [ "$val" = origin ] || why=" (not origin)" ;;
      branch.*.merge)                                                 # a bare pull merges this ref
        b=${key#branch.} && b=${b%.merge}
        [ "$val" = "refs/heads/$b" ] || why=" (not its own branch)"
        ;;
      remote.origin.fetch)                                            # what lands in origin's remote-tracking branches
        b=${val#+} && b=${b#refs/heads/}
        case "${val#+}" in refs/heads/*:*) ;; *) b="" ;; esac
        [ -n "$b" ] && [ "${val#+}" = "refs/heads/${b%%:*}:refs/remotes/origin/${b%%:*}" ] || why=" (not a branch to its own name)"
        ;;
      http.sslverify | http.*.sslverify)
        case "$rec" in *$'\n'*) ;; *) continue ;; esac            # a key with no value is true
        case "$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')" in true | yes | on | 1) ;; *) why=" (off)" ;; esac
        ;;
    esac
    if [ -n "$why" ]; then                                           # the key matched as git wrote it, shown quoted
      printf "REFUSE the marketplace clone's git config has %q%s, a transport key: it steers or weakens claude's fetch past the origin URL; remove it from %q\n" \
        "$key" "${why#:}" "$CLONE/.git" >&2
      return 3
    fi
  done < <(GIT_DIR="$CLONE/.git" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null git config -z --list 2> /dev/null)
}
# main_of <owner/name> — that repository's main as GitHub reports it now, or nothing
main_of() { gh api --hostname "$HOST" "repos/$1/git/ref/heads/main" --jq '.object.sha' 2> /dev/null || true; }
kit_main() { main_of "$KIT"; }
# signed <plan line> <command> [args...] — the command, only when the line is in the signed plan (write() runs it in the run
# phase only)
signed() {
  local line=$1
  shift
  if [ -z "${BATON_PLAN:-}" ] || ! grep -Fqx -- "$line" "$BATON_PLAN"; then
    echo "REFUSE the line is not in the signed plan (the registry, the layout, kit main or the marketplace's main moved since signing): $line" >&2
    return 3
  fi
  "$@"
}
# keep — the byte copies, then the signed plan's id: a record without the id is never read by undo
keep() {
  echo "KEPT the run record $RECORD"
  # a record undo left for the owner (marked `left`) is never deleted here
  find "$RECORDS" -maxdepth 1 -name 'kit-plugin-update-*' -mtime +7 -exec sh -c '[ -e "$1/left" ] || rm -rf -- "$1"' _ {} \; 2> /dev/null || true
  rm -rf -- "$RECORD"
  mkdir -p -- "$RECORD"
  cp -p -- "$REG" "$RECORD/installed_plugins.json"
  cp -p -- "$KNOWN" "$RECORD/known_marketplaces.json"
  printf '%s\n' "$TARGETS" > "$RECORD/targets"
  plan_id > "$RECORD/plan"
}
# started <mark> <command> [args...] — the command, with the mark in the run record first: undo reads that it began
started() {
  : > "$RECORD/$1"
  shift
  "$@"
}

# after_marketplace <M> — the checks the marketplace update makes necessary, its own step of the plan (it reads only): the update
# replaces the clone before any check can stop it, so the layout, kit and local plugins must be the same after it, kit main
# still the SHA, the marketplace's main still M, and the clone at M with a clean tree; rc 3 with a REFUSE line otherwise,
# before any plugin update
after_marketplace() {
  local mmain=$1 was main o
  was="$LAYOUT $KIT $REPO"
  o=$LOCALS
  read_layout
  if [ "$LAYOUT $KIT $REPO" != "$was" ]; then
    echo "REFUSE after the marketplace update the layout is $LAYOUT, kit $KIT, repo $REPO (was $was): no plugin updated" >&2
    return 3
  fi
  if [ "$LOCALS" != "$o" ]; then
    echo "REFUSE after the marketplace update the local plugins are ${LOCALS:-none} (was ${o:-none}): no plugin updated; run the kit again" >&2
    return 3
  fi
  main=$(kit_main)
  if [ "$main" != "$SHA" ]; then
    echo "REFUSE kit main moved to ${main:-unreadable} during the run: no plugin updated" >&2
    return 3
  fi
  main=$(main_of "$REPO")
  if [ "$main" != "$mmain" ]; then
    echo "REFUSE the marketplace's main on github.com/$REPO moved to ${main:-unreadable} during the run: no plugin updated" >&2
    return 3
  fi
  clean_tree "$mmain"
}

# updated <plugin> <commit or -> <command> [args...] — the plugin's update; for a local plugin (a commit) the clone is checked
# again first, at that commit and clean, since anything may have moved it during the updates before; then its user entry as
# the update left it goes into the run record, even when the update failed: undo puts the plugin back only while it is still
# that (or still the copy's)
updated() {
  local n=$1 at=$2 rc=0
  shift 2
  if [ "$at" != - ]; then
    clean_tree "$at"
  fi
  "$@" < /dev/null || rc=$?                                         # not the loop's targets as its input
  reader entry "$CFG" "$n" > "$RECORD/after-$n"
  if [ "$rc" -ne 0 ]; then
    echo "FAIL the update of $n@$MKT exited $rc: the entry it left is in the run record, for undo" >&2
  fi
  return "$rc"
}

# ── the act: every change through write() ──
TARGETS=""
act() {
  local main mmain o rc=0 k n s t at todo="" total=0 regsum knownsum line
  if [ -e "$RECORD/left" ]; then
    echo "REFUSE the run record $RECORD holds copies an earlier undo left for the owner: move it away first" >&2
    return 3
  fi
  read_layout
  main=$(kit_main)
  if [ "$main" != "$SHA" ]; then
    echo "REFUSE kit main on github.com/$KIT is ${main:-unreadable}, not $SHA: this kit installs only kit main" >&2
    return 3
  fi
  # the marketplace's main M: the local plugins' target, pinned in the marketplace plan line; the kit's own marketplace is the
  # kit, whose main was just read
  if [ "$LAYOUT" = kit-own ]; then
    mmain=$SHA
  else
    mmain=$(main_of "$REPO")
  fi
  if ! [[ "$mmain" =~ ^[0-9a-f]{40}$ ]]; then
    echo "REFUSE the marketplace's main on github.com/$REPO is ${mmain:-unreadable}, not a commit" >&2
    return 3
  fi
  clean_tree -
  # shellcheck disable=SC2086 # OURS is a list of plugin names
  o=$(reader installed "$CFG" $OURS) || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "${o:-REFUSE the installs cannot be read}" >&2
    return 3
  fi
  TARGETS=""
  while read -r k n s; do
    case "$k" in
      NONE)
        echo "NOT INSTALLED $n@$MKT has no user-scope install: not installed by this kit"
        continue
        ;;
    esac
    t=$SHA
    case " $NAMES " in *" $n "*) ;; *) t=$mmain ;; esac
    TARGETS="${TARGETS:+$TARGETS
}$n $s $t"
    echo "INSTALLED $n@$MKT (user) at commit $s"
    if [ "$s" = "$t" ]; then
      echo "SKIP $n@$MKT already at $t"
    else
      todo="${todo:+$todo }$n"
      total=$((total + 1))
    fi
  done <<< "$o"
  if [ "$total" -eq 0 ]; then
    echo "REFUSE nothing to do: every plugin already records its target (sdlc and brain $SHA, local plugins $mmain)" >&2
    return 3
  fi
  printf 'PLAN-COUNT %s\n' "$((total + 3))"
  regsum=$(sha256_file "$REG")
  knownsum=$(sha256_file "$KNOWN")
  line="plugin-update keep byte copies of installed_plugins.json (sha256 $regsum) and known_marketplaces.json (sha256 $knownsum) under $RECORDS"
  write "$line" signed "$line" keep
  line="plugin-update marketplace $MKT (layout $LAYOUT, repo $REPO from $HEAD to main $mmain, kit $KIT at main $SHA)"
  write "$line" signed "$line" started marketplace-update claude plugin marketplace update "$MKT"
  line="plugin-update verify the marketplace clone at main $mmain, clean, with the same layout, kit and local plugins, before any plugin update"
  write "$line" signed "$line" after_marketplace "$mmain"
  while read -r n s t; do
    case " $todo " in *" $n "*) ;; *) continue ;; esac
    case " $NAMES " in *" $n "*) k="kit $KIT" ;; *) k="marketplace $REPO" ;; esac
    case " $LOCALS " in *" $n "*) at=$mmain ;; *) at=- ;; esac
    line="plugin-update $n@$MKT at user scope from $s to $t ($k)"
    write "$line" signed "$line" updated "$n" "$at" claude plugin update "$n@$MKT" --scope user
  done <<< "$TARGETS"
}

# ── post-check: each install of the run's record is its target, in the shape the launcher accepts; then the next setup step ──
postcheck() {
  local o rc=0 sdlc
  o=$(reader check "$CFG" "$STATE_BASE" "$RECORD") || rc=$?
  printf '%s\n' "$o" | grep -v '^SDLC ' || true
  if [ "$rc" -ne 0 ]; then
    return 1
  fi
  sdlc=$(printf '%s\n' "$o" | sed -n 's/^SDLC //p')
  echo "NEXT the session runs, in this order:"
  printf 'NEXT   python3 -I %q permissions --install-launcher\n' "$sdlc/scripts/baton.py"
  printf 'NEXT   %q permissions --check\n' "$LAUNCHER"
}

# restore <name> — one registry file back from its byte copy, through a temporary file beside it, then compared
restore() {
  cp -p -- "$RECORD/$1" "$PLUGINS/$1.kit-plugin-update.$$"
  mv -f -- "$PLUGINS/$1.kit-plugin-update.$$" "$PLUGINS/$1"
  [ "$(sha256_file "$PLUGINS/$1")" = "$(sha256_file "$RECORD/$1")" ]
}

# ── undo: from this run's record only; both files back byte for byte unless that would undo more; what stays is named ──
undo() {
  local mine f o rc=0
  if [ ! -f "$RECORD/plan" ]; then
    echo "no run record: this run kept no copies, nothing to put back"
    return 0
  fi
  mine=$(plan_id)
  if [ -z "$mine" ]; then
    echo "LEAVE no signed plan (BATON_PLAN): cannot tell whether $RECORD is this run's" >&2
    return 1
  fi
  if [ "$(cat "$RECORD/plan")" != "$mine" ]; then
    echo "the run record $RECORD is an earlier run's: nothing of this run to put back"
    return 0
  fi
  # the copies go back only when nothing else in either file changed since, each plugin of the run is what the run left, and
  # the copy's installs are still there
  o=$(reader others "$CFG" "$RECORD") || rc=$?
  if [ "$rc" -eq 0 ]; then
    o=$(reader gone "$RECORD") || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "${o:-REFUSE the registry files cannot be compared with the copies}"
    write "mark the run record $RECORD as left for the owner" touch "$RECORD/left"
    echo "LEAVE both registry files as they are: the copies stay in $RECORD for the owner (no run of this kit deletes a record marked left)" >&2
    return 1
  fi
  reader left "$CFG" "$RECORD" 2> /dev/null || true
  for f in installed_plugins.json known_marketplaces.json; do
    write "put back $PLUGINS/$f from the byte copy (sha256 $(sha256_file "$RECORD/$f"))" restore "$f"
  done
  if [ -f "$RECORD/marketplace-update" ]; then
    read_layout 2> /dev/null || true
    echo "LEFT the marketplace clone ${CLONE:-of $MKT} at the new marketplace head (the marketplace update replaced it before any check)"
  else
    echo "the marketplace update never started: the clone is as it was"
  fi
  write "drop the run record $RECORD" rm -rf -- "$RECORD"
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
