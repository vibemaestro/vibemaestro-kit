#!/bin/bash
# =============================================================================
# The kit baton kit:plugin-update (batons/plugin-update.sh), through baton.py
# =============================================================================
# Run: bash tests/test-baton-plugin-update.sh
#
# Offline, and never on this machine's Claude Code config: each case is a scratch claude directory (CLAUDE_CONFIG_DIR, or
# HOME/.claude) with a vibemaestro marketplace clone and both plugins installed at an old commit, a fake `gh` that reports kit
# main from the case's world, and a stub `claude` (tests/fixtures/plugin_update_claude.py) that records each call and writes
# what Claude Code would. The kit repository is acme/kit; the git-subdir marketplace is acme/gitops.
#   [L] both layouts: the kit's own marketplace (version <12 hex>) and the gitops marketplace (git-subdir, <12 hex>-<8 hex>),
#       and the claude directory under HOME: go rc 0, the three calls in order, both installs at the SHA, the next setup step
#       printed (shell-quoted: a claude directory with a space), the run record kept and named, a record older than seven
#       days deleted
#   [R] refusals at rehearse, no claude call: unknown layouts (a directory source, a plugin missing, a ref not main, a pinned
#       sha, an ssh or http URL, mixed sources, an entry with hooks or strict, a known source at another ref or with a path),
#       a layout with two kit repositories or none, a cleartext known source on another host, a clone whose origin has two
#       URLs, a URL rewrite (also in the worktree config) or an include, a clone origin other than the known source's
#       repository (both layouts), a clone whose .git, git config or .claude-plugin is a symlink, an invalid .git inside
#       another repository, a clone owned by another user and not trusted (one trusted by safe.directory passes), a git
#       variable in the environment (GIT_CONFIG, GIT_DIR, GIT_CONFIG_PARAMETERS), a relative installLocation, a SHA that
#       is not kit main, a plugin not installed at user scope or twice, nothing to do, a registry file that is a symlink, a
#       SHA that is not 40 lower-case hex, a relative CLAUDE_CONFIG_DIR, a fetch URL that a rewrite in the owner's global,
#       system or XDG git config takes off the repository, each git variable that points git elsewhere (GIT_CONFIG empty
#       too); a global rewrite that stays on the repository (https to ssh) passes
#   [T] the clone's transport keys, refused at rehearse with no claude call (their cases print [R]): remote.origin.proxy,
#       http.proxy and http.<url>.proxy, http.curloptResolve (also per URL), a branch remote other than origin (a name or
#       a URL), core.gitProxy, core.sshCommand, http.sslVerify off (also per URL); a URL rewrite (insteadOf, pushInsteadOf)
#       is refused by the kit alone on a copy whose reader takes it; a fetch refspec or branch merge ref onto another ref;
#       sslVerify true or bare, branch remote origin, a single-branch refspec and a branch merging itself pass
#   [S] a run phase whose line is not in the signed plan calls nothing
#   [M] the world moves during the run: kit main moves at the plugin update (the post-check goes red, undo puts both files
#       back byte for byte and names what it leaves), at the marketplace update (no plugin update, undo), the layout changes
#       with the marketplace update (no plugin update, undo); a run stopped before the marketplace update (undo says the
#       clone is as it was); another plugin, another scope or another marketplace recorded meanwhile, or the old install
#       removed (undo leaves both files, rc 5, the record marked left)
#   [P] the post-check goes red on: a version not of the SHA, a plugin.json with a version or that is a symlink, an
#       install's .claude-plugin or scripts that is a symlink, a launcher template that is a symlink, a forged installPath
#       outside the cache, an install directory that is a file, a launcher template that refuses the directory, a launcher
#       that resolves to another install
#   [U] undo with no run record, or an earlier run's record, puts nothing back; with no signed plan it leaves the record; a
#       run whose record an earlier undo left for the owner is refused
#   [X] planted breaks: each guard goes red on a plugin copy with that guard broken in the kit or its engine
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# the machine's own Claude Code registry files, hashed before the suite isolates itself: the suite must leave them as they are
REAL_CFG=${CLAUDE_CONFIG_DIR:-${HOME:-/nonexistent}/.claude}
real_state() { cat "$REAL_CFG/plugins/installed_plugins.json" "$REAL_CFG/plugins/known_marketplaces.json" 2>/dev/null | cksum; }
R0=$(real_state)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
# shellcheck source=fixtures/ports.sh
. "$HERE/fixtures/ports.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
export PYTHONDONTWRITEBYTECODE=1
H0=$(tree_hash "$SRC_ROOT")
FB="$TMP/fakebin"; mkdir -p "$FB"
cat > "$FB/gh" <<'EOF'
#!/bin/sh
printf 'gh %s\n' "$*" >> "$FAKE_WORLD/gh.log"
if [ "$1 $2 $3" = "api --hostname github.com" ] && [ "$4" = repos/acme/kit/git/ref/heads/main ] && [ "$5 $6" = "--jq .object.sha" ] \
  && [ -f "$FAKE_WORLD/main" ]; then
  cat "$FAKE_WORLD/main"
  exit 0
fi
if [ "$1 $2 $3" = "api --hostname github.com" ] && [ "$4" = repos/acme/gitops/git/ref/heads/main ] && [ "$5 $6" = "--jq .object.sha" ] \
  && [ -f "$FAKE_WORLD/mmain" ]; then
  cat "$FAKE_WORLD/mmain"
  exit 0
fi
echo "gh: Not Found (HTTP 404)" >&2
exit 1
EOF
printf '#!/bin/sh\nexec python3 -B "%s" "$@"\n' "$HERE/fixtures/plugin_update_claude.py" > "$FB/claude"
chmod +x "$FB/gh" "$FB/claude"
PATH="$FB:$PATH"; export PATH

OLD=1111111111111111111111111111111111111111
NEW=2222222222222222222222222222222222222222
OTHER=c0ffee0000000000000000000000000000000000
OLDL=3333333333333333333333333333333333333333    # a local plugin's old commit in the registry
MEDDLE=4444444444444444444444444444444444444444  # the commit another session's update records (the stub's meddle)
K=kit:plugin-update
BT_OUT="$TMP/bt.out"
# the next setup step the kit prints, spelled apart: the capped-breaks lint [L2] reads a literal `python3 -I` as a command
NEXT_PY="python3"" -I"
D="" C="" W="" ST="" XENV=() XPRE=()   # XPRE: a command prefix for bt (env -u NAME to unset what cenv sets)
M="" MOLD="" CL=""                      # the marketplace's main (the clone's next commit), its old HEAD, the clone
LOCALS=""                               # machine's marketplace-local plugins besides sdlc and brain (space-separated)
# the case's commits: a fixed author and date, so a commit is made the same way every time
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid \
  GIT_AUTHOR_DATE=2026-01-01T00:00:00Z GIT_COMMITTER_DATE=2026-01-01T00:00:00Z

# manifest <shape> [sdlc source json] [brain source json] — a marketplace.json of that shape (own or subdir) on stdout
manifest() {
  local s1 s2
  if [ "$1" = own ]; then
    s1=${2:-'"./plugins/vibemaestro-sdlc"'}; s2=${3:-'"./plugins/vibemaestro-brain"'}
  else
    s1=${2:-'{"source": "git-subdir", "url": "https://github.com/acme/kit.git", "path": "plugins/vibemaestro-sdlc", "ref": "main"}'}
    s2=${3:-'{"source": "git-subdir", "url": "https://github.com/acme/kit.git", "path": "plugins/vibemaestro-brain", "ref": "main"}'}
  fi
  local l extra=""
  for l in $LOCALS; do extra="$extra, {\"name\": \"$l\", \"source\": \"./plugins/$l\", \"description\": \"a local plugin\"}"; done
  printf '{"name": "vibemaestro", "owner": {"name": "acme"}, "plugins": [{"name": "vibemaestro-sdlc", "source": %s}, {"name": "vibemaestro-brain", "source": %s}%s]}\n' "$s1" "$s2" "$extra"
}
# machine <shape> [home] — a new case in D: a marketplace clone CL with one commit MOLD on main (the manifest, the plugin
# directories of sdlc, brain and each of LOCALS, a README each) and its next commit M on the branch next; world W (the marketplace's main M;
# kit main NEW, which in the kit's own marketplace is M), claude directory C ($D/$CNAME, default cfg), state directory ST
# ($D/$SNAME, default state), sdlc and brain at OLD, each of LOCALS at OLDL; with `home`, C is $D/home/.claude and
# CLAUDE_CONFIG_DIR stays unset
machine() {
  local shape=$1 v1 v2 src origin l
  D=$(fresh); W="$D/world"; ST="$D/${SNAME:-state}"; mkdir -p "$W" "$D/home" "$ST"
  if [ "${2:-}" = home ]; then C="$D/home/.claude"; else C="$D/${CNAME:-cfg}"; fi
  local clone="$C/plugins/marketplaces/vibemaestro"
  CL=$clone
  mkdir -p "$clone/.claude-plugin"
  printf '%s\n' "$shape" > "$W/shape"; : > "$W/claude.log"; : > "$W/gh.log"
  if [ "$shape" = own ]; then
    src='{"source": "github", "repo": "acme/kit"}'; origin=https://github.com/acme/kit.git; v1=${OLD:0:12}; v2=${OLD:0:12}
  else
    src='{"source": "git", "url": "https://github.com/acme/gitops.git"}'; origin=https://github.com/acme/gitops.git
    v1=${OLD:0:12}-be49dd83; v2=${OLD:0:12}-adc9e2e3
  fi
  git_ init -q -b main "$clone"; git_ -C "$clone" remote add origin "$origin"
  manifest "$shape" > "$clone/.claude-plugin/marketplace.json"
  for l in vibemaestro-sdlc vibemaestro-brain $LOCALS; do
    mkdir -p "$clone/plugins/$l"; printf '# %s\n' "$l" > "$clone/plugins/$l/README.md"
  done
  git_ -C "$clone" add -A; git_ -C "$clone" commit -q -m old
  git_ -C "$clone" checkout -q -b next; git_ -C "$clone" commit -q --allow-empty -m next; git_ -C "$clone" checkout -q main
  MOLD=$(git_ -C "$clone" rev-parse main); M=$(git_ -C "$clone" rev-parse next)
  [ "$shape" = own ] && NEW=$M || NEW=2222222222222222222222222222222222222222
  printf '%s\n' "$NEW" > "$W/main"; printf '%s\n' "$M" > "$W/mmain"
  printf '{"vibemaestro": {"source": %s, "installLocation": "%s", "lastUpdated": "2026-01-01T00:00:00.000Z"}}\n' "$src" "$clone" \
    > "$C/plugins/known_marketplaces.json"
  mkdir -p "$C/plugins/cache/vibemaestro/vibemaestro-sdlc/$v1" "$C/plugins/cache/vibemaestro/vibemaestro-brain/$v2"
  printf '{"version": 2, "plugins": {"vibemaestro-sdlc@vibemaestro": [{"scope": "user", "installPath": "%s", "version": "%s", "lastUpdated": "2026-01-01T00:00:00.000Z", "gitCommitSha": "%s"}], "vibemaestro-brain@vibemaestro": [{"scope": "user", "installPath": "%s", "version": "%s", "lastUpdated": "2026-01-01T00:00:00.000Z", "gitCommitSha": "%s"}]}}\n' \
    "$C/plugins/cache/vibemaestro/vibemaestro-sdlc/$v1" "$v1" "$OLD" "$C/plugins/cache/vibemaestro/vibemaestro-brain/$v2" "$v2" "$OLD" \
    > "$C/plugins/installed_plugins.json"
  for l in $LOCALS; do
    mkdir -p "$C/plugins/cache/vibemaestro/$l/${OLDL:0:12}"
    json_set "$C/plugins/installed_plugins.json" 'J["plugins"]["'"$l"'@vibemaestro"] = [{"scope": "user", "installPath": "'"$C/plugins/cache/vibemaestro/$l/${OLDL:0:12}"'", "version": "'"${OLDL:0:12}"'", "lastUpdated": "2026-01-01T00:00:00.000Z", "gitCommitSha": "'"$OLDL"'"}]'
  done
  cp -p "$C/plugins/installed_plugins.json" "$D/reg.before"; cp -p "$C/plugins/known_marketplaces.json" "$D/known.before"
}
# json_set <file> <python statement on J> — edit a JSON file of the case
json_set() { python3 - "$1" "$2" <<'PY'
import json, sys
J = json.load(open(sys.argv[1]))
exec(sys.argv[2])
json.dump(J, open(sys.argv[1], "w"))
PY
}
# man_set <python statement on J> — a change of the clone's marketplace.json, committed: the clean-tree check must not stand in
# for the layout guard a case is about
man_set() { json_set "$(MAN)" "$1"; git_ -C "$CL" commit -q -am "case"; }
REG() { printf '%s' "$C/plugins/installed_plugins.json"; }
KNOWN() { printf '%s' "$C/plugins/known_marketplaces.json"; }
MAN() { printf '%s' "$C/plugins/marketplaces/vibemaestro/.claude-plugin/marketplace.json"; }
# envs — the case's environment: the claude directory (unless under HOME), HOME, the state directory, the world, then XENV
envs() {
  local e=(HOME="$D/home" XDG_STATE_HOME="$ST" FAKE_WORLD="$W" STUB_SRC="$SRC_ROOT/plugins")
  [ "$C" = "$D/home/.claude" ] || e+=(CLAUDE_CONFIG_DIR="$C")
  e+=(${XENV[@]+"${XENV[@]}"})     # a case's extra environment (the last value of a name wins)
  printf '%s\n' "${e[@]}"
}
# bt <plugin> <baton args...> — rc of baton for the case; its output is in $BT_OUT
bt() {
  local p=$1 e=(); shift
  if [ $# -eq 2 ] && [ "$1" = mode ]; then baton_set_mode "$ST" "$2"; echo 0; return; fi
  while IFS= read -r l; do e+=("$l"); done < <(envs)
  ( cd "$D" && cenv "${e[@]}" ${XPRE[@]+"${XPRE[@]}"} python3 "$p/scripts/baton.py" "$@" ) > "$BT_OUT" 2>&1; echo $?
}
# go_ <plugin> <args...> — rc of `go` for the case; $BT_OUT then also holds the run's full output, the file go names (`go: ok — … —
# <file>`, or `full output: <file>`), where the post-check's lines are
go_() {
  local p=$1 rc f; shift
  bt "$p" mode auto > /dev/null; rc=$(bt "$p" go $K "$@")
  f=$(sed -n -e 's/^go: ok — [0-9]* writes\{0,1\} — //p' -e 's/^full output: //p' "$BT_OUT" | tail -n 1)
  if [ -n "$f" ] && [ -f "$f" ]; then cat "$f" >> "$BT_OUT"; fi
  echo "$rc"
}
# kit_phase <plugin> <phase> <signed plan file> <args...> — the kit's own phase, run directly; rc, output in $BT_OUT
kit_phase() {
  local p=$1 ph=$2 plan=$3 e=(); shift 3
  while IFS= read -r l; do e+=("$l"); done < <(envs)
  ( cd "$D" && cenv "${e[@]}" BATON_PHASE="$ph" BATON_PLAN="$plan" BATON_PLUGIN_ROOT="$p" bash "$p/batons/plugin-update.sh" "$@" ) > "$BT_OUT" 2>&1; echo $?
}
# kit_pair <plugin> <signed plan file> <args...> — the kit's run, then its undo, from one shell (one $PPID, as under the
# runner; the trailing exit keeps bash from exec-ing the undo); rc of the undo, output of both in $BT_OUT
kit_pair() {
  local p=$1 plan=$2 e=(); shift 2
  while IFS= read -r l; do e+=("$l"); done < <(envs)
  ( cd "$D" && cenv "${e[@]}" BATON_PLAN="$plan" BATON_PLUGIN_ROOT="$p" \
      bash -c 'BATON_PHASE=run bash "$@"; BATON_PHASE=undo bash "$@"; rc=$?; exit $rc' _ "$p/batons/plugin-update.sh" "$@" ) > "$BT_OUT" 2>&1; echo $?
}
# post_again <plugin> — the kit's post-check again, after a go: a shell that copies go's run record under its own PID (the kit
# names its record by its runner's PID), then runs the phase (not exec); rc, output in $BT_OUT
post_again() {
  local p=$1 e=() rec; rec=$(find "$ST/vibemaestro/baton/records" -maxdepth 1 -name 'kit-plugin-update-*' | head -n 1)
  while IFS= read -r l; do e+=("$l"); done < <(envs)
  ( cd "$D" && cenv "${e[@]}" BATON_PHASE=postcheck BATON_PLUGIN_ROOT="$p" \
      bash -c 'cp -R "$1" "$2/kit-plugin-update-$$" && bash "$3" "$4"; rc=$?; exit $rc' _ "$rec" "${rec%/*}" "$p/batons/plugin-update.sh" "$NEW" ) > "$BT_OUT" 2>&1; echo $?
}
calls() { grep -c . "$W/claude.log" || true; }
sha_of() { python3 -c 'import json,sys; print([e for e in json.load(open(sys.argv[1]))["plugins"][sys.argv[2]] if e["scope"] == "user"][0]["gitCommitSha"])' "$(REG)" "$1"; }
same() { cmp -s "$1" "$2" && echo same || echo differs; }

fam_layouts() {
  local P=$1
  machine own
  eq "$(bt "$P" rehearse $K $NEW)" 0 "[L] own marketplace: rehearse rc 0"
  has "$(cat "$BT_OUT")" "PLAN plugin-update marketplace vibemaestro (layout kit-own, repo acme/kit from $MOLD to main $NEW, kit acme/kit at main $NEW)" "[L] …the plan names the layout, the repository's old and new commit, the kit and the SHA"
  has "$(cat "$BT_OUT")" "PLAN plugin-update vibemaestro-sdlc@vibemaestro at user scope from $OLD to $NEW (kit acme/kit)" "[L] …each plugin's line names its old and new commit"
  has "$(cat "$BT_OUT")" "PLAN-COUNT 5" "[L] …five writes: the copies, the marketplace, its check, sdlc, brain"
  eq "$(calls)" 0 "[L] …rehearse calls claude for nothing"
  eq "$(go_ "$P" $NEW)" 0 "[L] own marketplace: go rc 0"
  eq "$(cat "$W/claude.log")" "plugin marketplace update vibemaestro
plugin update vibemaestro-sdlc@vibemaestro --scope user
plugin update vibemaestro-brain@vibemaestro --scope user" "[L] …the marketplace, then sdlc, then brain, at user scope, no -y"
  eq "$(sha_of vibemaestro-sdlc@vibemaestro)/$(sha_of vibemaestro-brain@vibemaestro)" "$NEW/$NEW" "[L] …both installs record the SHA (the scratch registry is the one the run changed)"
  has "$(cat "$BT_OUT")" "CHECK vibemaestro-sdlc at ${NEW:0:12} commit $NEW" "[L] …the bare 12-hex version passes"
  has "$(cat "$BT_OUT")" "NEXT   $NEXT_PY $C/plugins/cache/vibemaestro/vibemaestro-sdlc/${NEW:0:12}/scripts/baton.py permissions --install-launcher" "[L] …the next setup step names the new sdlc"
  has "$(cat "$BT_OUT")" "NEXT   $D/state/vibemaestro/baton/bin/baton permissions --check" "[L] …then the launcher's permissions --check"
  eq "$(find "$D/state" -name 'kit-plugin-update-*' | wc -l | tr -d ' ')" 1 "[L] …the post-check writes nothing: the run record stays"
  has "$(cat "$BT_OUT")" "KEPT the run record $D/state/vibemaestro/baton/records/kit-plugin-update-" "[L] …the run names its record"
  eq "$(grep -vc -- '--hostname github.com' "$W/gh.log")" 0 "[L] …every gh call names --hostname github.com"
  machine subdir
  local r="$D/state/vibemaestro/baton/records"
  mkdir -p "$r/kit-plugin-update-1" "$r/kit-plugin-update-2" "$r/kit-plugin-update-3"; : > "$r/kit-plugin-update-3/left"
  python3 -c 'import os, sys, time; t = time.time() - 9 * 86400; [os.utime(a, (t, t)) for a in sys.argv[1:]]' "$r/kit-plugin-update-1" "$r/kit-plugin-update-3"
  eq "$(bt "$P" rehearse $K $NEW)" 0 "[L] gitops marketplace (git-subdir): rehearse rc 0"
  has "$(cat "$BT_OUT")" "PLAN plugin-update marketplace vibemaestro (layout git-subdir, repo acme/gitops from $MOLD to main $M, kit acme/kit at main $NEW)" "[L] …the kit is the git-subdir URL's repository, not the gitops clone's"
  eq "$(go_ "$P" $NEW)" 0 "[L] gitops marketplace: go rc 0"
  eq "$([ -e "$r/kit-plugin-update-1" ] && echo kept || echo deleted)/$([ -e "$r/kit-plugin-update-2" ] && echo kept || echo deleted)" \
    deleted/kept "[L] …the run deletes a record older than seven days, and only that one"
  eq "$([ -e "$r/kit-plugin-update-3/left" ] && echo kept || echo deleted)" kept "[L] …a record left for the owner is never deleted"
  has "$(cat "$BT_OUT")" "CHECK vibemaestro-sdlc at ${NEW:0:12}-be49dd83 commit $NEW" "[L] …the version suffix <12 hex>-<8 hex> passes"
  has "$(cat "$BT_OUT")" "CHECK vibemaestro-brain at ${NEW:0:12}-adc9e2e3 commit $NEW" "[L] …brain too"
  has "$(cat "$BT_OUT")" "CHECK the launcher template accepts every directory and resolves to $C/plugins/cache/vibemaestro/vibemaestro-sdlc/${NEW:0:12}-be49dd83/scripts/baton.py" "[L] …the new launcher template resolves to the new sdlc"
  machine own home
  eq "$(go_ "$P" $NEW)/$(sha_of vibemaestro-sdlc@vibemaestro)" "0/$NEW" "[L] the claude directory under HOME (no CLAUDE_CONFIG_DIR): go rc 0, sdlc at the SHA"
  CNAME='my cfg' SNAME='my state' machine own
  eq "$(go_ "$P" $NEW)" 0 "[L] a claude and a state directory with a space: go rc 0"
  has "$(cat "$BT_OUT")" "NEXT   $D/my\\ state/vibemaestro/baton/bin/baton permissions --check" "[L] …the launcher's path is quoted too"
  has "$(cat "$BT_OUT")" "NEXT   $NEXT_PY $D/my\\ cfg/plugins/cache/vibemaestro/vibemaestro-sdlc/${NEW:0:12}/scripts/baton.py permissions --install-launcher" "[L] …the next setup step quotes the path"
}

# refused <label> <needle> — rehearse rc 1, the refusal by name, no claude call
refused() {
  local P=$1 label=$2 why=$3; shift 3          # not `needle`: expect_red's bad() reads that name
  eq "$(bt "$P" rehearse $K "${@:-$NEW}")/$(calls)" "1/0" "[R] $label: rehearse rc 1, no claude call"
  has "$(cat "$BT_OUT")" "$why" "[R] …$label: refused by name"
}
fam_refuse() {
  local P=$1 s
  machine own; json_set "$(KNOWN)" 'J["vibemaestro"]["source"] = {"source": "directory", "path": "/example"}'
  refused "$P" "a directory marketplace" "not a git one"
  machine subdir; manifest subdir '' '"./plugins/vibemaestro-brain"' > "$(MAN)"; git_ -C "$CL" commit -q -am case
  refused "$P" "mixed sources" "a layout this kit does not know"
  machine own; man_set 'J["plugins"] = J["plugins"][:1]'
  refused "$P" "a plugin missing from the marketplace" "lists vibemaestro-brain 0 times, not once"
  machine subdir; man_set 'J["plugins"][1]["source"]["ref"] = "release"'
  refused "$P" "a ref other than main" "a layout this kit does not know"
  machine subdir; man_set 'J["plugins"][0]["source"]["sha"] = "'$OLD'"'
  refused "$P" "a pinned sha" "a layout this kit does not know"
  machine subdir; man_set 'J["plugins"][0]["source"]["url"] = "git@github.com:acme/kit.git"'
  refused "$P" "an ssh URL in a git-subdir source" "names no kit repository"
  machine subdir; man_set 'J["plugins"][1]["source"]["url"] = "https://github.com/acme/other.git"'
  refused "$P" "two repositories in the git-subdir sources" "names more than one kit repository"
  machine own; git_ -C "$C/plugins/marketplaces/vibemaestro" remote set-url origin https://github.com/acme/fork.git
  refused "$P" "the clone's origin another repository than the known source" "is not the known source's repository"
  machine own; json_set "$(KNOWN)" 'J["vibemaestro"]["source"] = {"source": "git", "url": "https://example.invalid/kit.git"}'
  git_ -C "$C/plugins/marketplaces/vibemaestro" remote set-url origin https://example.invalid/kit.git
  refused "$P" "no github.com repository in the layout" "names no github.com repository"
  machine own; json_set "$(KNOWN)" 'J["vibemaestro"]["installLocation"] = "'"$D"'/elsewhere"'; mkdir -p "$D/elsewhere/.git"
  refused "$P" "a clone outside the marketplaces directory" "is not a git clone under"
  machine own
  refused "$P" "a SHA that is not kit main" "REFUSE kit main on github.com/acme/kit is $NEW, not $OTHER" "$OTHER"
  machine own; json_set "$(REG)" 'J["plugins"]["vibemaestro-brain@vibemaestro"][0]["scope"] = "project"'
  refused "$P" "a plugin not installed at user scope" "vibemaestro-brain@vibemaestro has 0 user-scope installs"
  machine own; json_set "$(REG)" 'for e in J["plugins"].values(): e[0]["gitCommitSha"] = "'$NEW'"'
  refused "$P" "both already at the SHA" "REFUSE nothing to do"
  machine own; mv "$(REG)" "$D/reg.real"; ln -s "$D/reg.real" "$(REG)"
  refused "$P" "a registry that is a symlink" "is not a regular file"
  machine subdir; man_set 'J["plugins"][0]["hooks"] = {"SessionStart": []}'
  refused "$P" "a marketplace entry with hooks" "vibemaestro-sdlc entry carries hooks beyond name, source, description"
  machine own; man_set 'J["plugins"][1]["strict"] = False'
  refused "$P" "a marketplace entry with strict" "vibemaestro-brain entry carries strict beyond"
  machine subdir; json_set "$(KNOWN)" 'J["vibemaestro"]["source"] = {"source": "git", "url": "http://evil.example/gitops.git"}'
  refused "$P" "a cleartext known source on another host" "names no github.com repository"
  machine own; json_set "$(KNOWN)" 'J["vibemaestro"]["source"]["ref"] = "evil-branch"'
  refused "$P" "a known source at another ref" "at most with ref main"
  machine own; json_set "$(KNOWN)" 'J["vibemaestro"]["source"]["path"] = "x"'
  refused "$P" "a known source with a path" "at most with ref main"
  machine own; git_ -C "$C/plugins/marketplaces/vibemaestro" config --add remote.origin.url https://github.com/evil/kit.git
  refused "$P" "a clone whose origin has two URLs" "origin has 2 URLs, not one"
  machine own; git_ -C "$C/plugins/marketplaces/vibemaestro" config url.https://github.com/evil/.insteadOf https://github.com/acme/
  refused "$P" "a clone whose git config rewrites the URL" "(an include or a URL rewrite)"
  machine own; git_ -C "$C/plugins/marketplaces/vibemaestro" config include.path "$D/extra"
  refused "$P" "a clone whose git config includes another file" "has include.path"
  machine own; json_set "$(KNOWN)" 'J["vibemaestro"]["installLocation"] = "cfg/plugins/marketplaces/vibemaestro"'
  refused "$P" "a relative installLocation" "has no absolute installLocation"
  machine subdir; man_set 'J["plugins"][0]["source"]["url"] = "http://github.com/acme/kit.git"'
  refused "$P" "an http URL in a git-subdir source" "names no kit repository"
  machine own; json_set "$(REG)" 'J["plugins"]["vibemaestro-sdlc@vibemaestro"].append(dict(J["plugins"]["vibemaestro-sdlc@vibemaestro"][0]))'
  refused "$P" "two user-scope installs" "vibemaestro-sdlc@vibemaestro has 2 user-scope installs"
  machine own; mv "$(KNOWN)" "$D/known.real"; ln -s "$D/known.real" "$(KNOWN)"
  refused "$P" "a known_marketplaces.json that is a symlink" "known_marketplaces.json is not a regular file"
  machine subdir; git_ -C "$C/plugins/marketplaces/vibemaestro" remote set-url origin http://evil.example/gitops.git
  refused "$P" "a git-subdir clone whose origin is elsewhere" "is not the known source's repository"
  machine own; git_ -C "$C/plugins/marketplaces/vibemaestro" config core.repositoryformatversion 1
  git_ -C "$C/plugins/marketplaces/vibemaestro" config extensions.worktreeConfig true
  git_ -C "$C/plugins/marketplaces/vibemaestro" config --worktree url.https://github.com/evil/.insteadOf https://github.com/acme/
  refused "$P" "a rewrite in the clone's worktree config" "has url.https://github.com/evil/.insteadof"
  machine own; mv "$C/plugins/marketplaces/vibemaestro/.git/config" "$D/gitconfig"; ln -s "$D/gitconfig" "$C/plugins/marketplaces/vibemaestro/.git/config"
  refused "$P" "a clone whose git config is a symlink" "the clone's git config is not a regular file"
  machine own; mv "$C/plugins/marketplaces/vibemaestro/.git" "$D/dotgit"; ln -s "$D/dotgit" "$C/plugins/marketplaces/vibemaestro/.git"
  refused "$P" "a clone whose .git is a symlink" "the clone's .git is not a directory"
  machine own; mv "$C/plugins/marketplaces/vibemaestro/.claude-plugin" "$D/cp"; ln -s "$D/cp" "$C/plugins/marketplaces/vibemaestro/.claude-plugin"
  refused "$P" "a clone whose .claude-plugin is a symlink" "the clone's .claude-plugin is not a directory"
  machine own; git_ -C "$C/plugins/marketplaces/vibemaestro" remote set-url origin https://evil.example/kit.git
  printf '[remote "origin"]\n\turl = https://github.com/acme/kit.git\n' > "$D/alt"
  XENV=(GIT_CONFIG="$D/alt"); refused "$P" "GIT_CONFIG naming another file than the clone's" "the environment sets GIT_CONFIG"; XENV=()
  machine own; git_ init -q "$D/other"; git_ -C "$D/other" remote add origin https://github.com/acme/kit.git
  git_ -C "$C/plugins/marketplaces/vibemaestro" remote set-url origin https://evil.example/kit.git
  XENV=(GIT_DIR="$D/other/.git"); refused "$P" "GIT_DIR naming another repository" "the environment sets GIT_DIR"; XENV=()
  machine own
  XENV=(GIT_CONFIG_PARAMETERS="'url.https://evil.example/.insteadof'='https://github.com/acme/'")
  refused "$P" "a URL rewrite in GIT_CONFIG_PARAMETERS" "the environment sets GIT_CONFIG_PARAMETERS"; XENV=()
  machine own; XENV=(GIT_TEST_ASSUME_DIFFERENT_OWNER=1)
  refused "$P" "a clone owned by another user, not trusted" "detected dubious ownership"; XENV=()
  machine own; printf '[safe]\n\tdirectory = *\n' > "$D/trust.gitconfig"; XENV=(GIT_TEST_ASSUME_DIFFERENT_OWNER=1 GIT_CONFIG_GLOBAL="$D/trust.gitconfig")
  eq "$(bt "$P" rehearse $K $NEW)" 0 "[R] a clone owned by another user that the owner's safe.directory trusts: rehearse rc 0"; XENV=()
  # the ssh form through %s: no address in the source (the public-tree check)
  machine own; printf '[url "git%sgithub.com:"]\n\tinsteadOf = https://github.com/\n' @ > "$D/owner.gitconfig"; XENV=(GIT_CONFIG_GLOBAL="$D/owner.gitconfig")
  eq "$(bt "$P" rehearse $K $NEW)" 0 "[R] a global rewrite that stays on the repository (https to ssh): rehearse rc 0"; XENV=()
  local v rw='[url "https://evil.example/"]\n\tinsteadOf = https://github.com/\n'
  machine own; printf "$rw" > "$D/owner.gitconfig"; XENV=(GIT_CONFIG_GLOBAL="$D/owner.gitconfig")
  refused "$P" "a rewrite off the repository in the owner's global git config" "git would fetch the clone's origin from https://evil.example/acme/kit.git"; XENV=()
  machine own; printf "$rw" > "$D/system.gitconfig"; XENV=(GIT_CONFIG_NOSYSTEM=0 GIT_CONFIG_SYSTEM="$D/system.gitconfig")
  refused "$P" "a rewrite off the repository in the system git config" "git would fetch the clone's origin from https://evil.example/acme/kit.git"; XENV=()
  machine own; mkdir -p "$D/xdg/git"; printf "$rw" > "$D/xdg/git/config"; XENV=(XDG_CONFIG_HOME="$D/xdg"); XPRE=(env -u GIT_CONFIG_GLOBAL)
  refused "$P" "a rewrite off the repository in the XDG git config" "git would fetch the clone's origin from https://evil.example/acme/kit.git"; XENV=(); XPRE=()
  for v in GIT_COMMON_DIR="$D/x" GIT_WORK_TREE="$D/x" GIT_NAMESPACE=x GIT_OBJECT_DIRECTORY="$D/x" GIT_ALTERNATE_OBJECT_DIRECTORIES="$D/x" \
      GIT_INDEX_FILE="$D/x" GIT_CONFIG=; do
    machine own; XENV=("$v"); refused "$P" "${v%%=*} set (${v#*=})" "the environment sets ${v%%=*}:"; XENV=()
  done
  machine own; XENV=(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=url.https://evil.example/.insteadof GIT_CONFIG_VALUE_0=https://github.com/)
  refused "$P" "a URL rewrite through GIT_CONFIG_COUNT" "the environment sets GIT_CONFIG_COUNT"; XENV=()
  machine own; git_ init -q "$C"; git_ -C "$C" remote add origin https://evil.example/kit.git   # what git would fetch from
  rm -rf "$C/plugins/marketplaces/vibemaestro/.git"; mkdir -p "$C/plugins/marketplaces/vibemaestro/.git"
  printf '[remote "origin"]\n\turl = https://github.com/acme/kit.git\n' > "$C/plugins/marketplaces/vibemaestro/.git/config"
  # two guards refuse this: git's discovery lands on $C/.git, and GIT_DIR pinned to an invalid .git reads no config (0 URLs);
  # the discovery names the cause, so its planted break goes red on the name
  refused "$P" "an invalid .git inside another repository" "git reads the clone's repository at $C/.git, not its .git"
  machine own home      # ~/.claude is a whole machine: a kit that fell back to it would rehearse green
  eq "$( ( cd "$D" && cenv HOME="$D/home" XDG_STATE_HOME="$ST" FAKE_WORLD="$W" STUB_SRC="$SRC_ROOT/plugins" CLAUDE_CONFIG_DIR=cfg \
      python3 "$P/scripts/baton.py" rehearse $K $NEW ) > "$BT_OUT" 2>&1; echo $?)/$(calls)" "1/0" "[R] a relative CLAUDE_CONFIG_DIR: rehearse rc 1, no claude call"
  has "$(cat "$BT_OUT")" "REFUSE CLAUDE_CONFIG_DIR is cfg, not an absolute path" "[R] …a relative CLAUDE_CONFIG_DIR: refused by name"
  machine subdir
  for s in "${NEW:0:12}" "$(printf '%s' "$NEW" | tr 2 A)" "$NEW $NEW"; do
    eq "$(bt "$P" rehearse $K $s)/$(calls)" "1/0" "[R] a SHA argument that is not 40 lower-case hex ($s): rehearse rc 1, no claude call"
    has "$(cat "$BT_OUT")" "usage: baton rehearse|run kit:plugin-update <full kit sha>" "[R] …a SHA argument that is not 40 lower-case hex ($s): the usage is named"
  done
}

# the clone's own transport keys: a proxy, a pinned address, a branch's remote, a proxy command, TLS checks off
# tk <key> <value> — a case whose clone config sets one key
tk() { machine own; git_ -C "$C/plugins/marketplaces/vibemaestro" config "$1" "$2"; }
fam_transport() {
  local P=$1
  tk remote.origin.proxy http://127.0.0.1:9; refused "$P" "remote.origin.proxy" "has remote.origin.proxy, a transport key"
  tk http.proxy http://127.0.0.1:9; refused "$P" "http.proxy" "has http.proxy, a transport key"
  tk http.https://github.com/.proxy http://127.0.0.1:9; refused "$P" "http.<url>.proxy" "has http.https://github.com/.proxy, a transport key"
  tk $'http.https://github.com/\t.proxy' http://127.0.0.1:9    # a tab in the URL: the key is matched as git wrote it
  refused "$P" "http.<url with a tab>.proxy" "has \$'http.https://github.com/\\t.proxy', a transport key"
  tk http.curloptResolve github.com:443:127.0.0.1; refused "$P" "http.curloptResolve" "has http.curloptresolve, a transport key"
  tk http.https://github.com/.curloptResolve github.com:443:127.0.0.1
  refused "$P" "http.<url>.curloptResolve" "has http.https://github.com/.curloptresolve, a transport key"
  tk branch.main.remote evil; refused "$P" "branch.main.remote another remote" "has branch.main.remote (not origin), a transport key"
  tk branch.main.remote https://evil.example/kit.git; refused "$P" "branch.main.remote a URL" "has branch.main.remote (not origin), a transport key"
  tk core.gitProxy /tmp/x; refused "$P" "core.gitProxy" "has core.gitproxy, a transport key"
  tk core.sshCommand "ssh -o ProxyCommand=x"; refused "$P" "core.sshCommand" "has core.sshcommand, a transport key"
  tk http.sslVerify false; refused "$P" "http.sslVerify false" "has http.sslverify (off), a transport key"
  tk http.https://github.com/.sslVerify 0; refused "$P" "http.<url>.sslVerify 0" "has http.https://github.com/.sslverify (off), a transport key"
  machine own; printf '[http]\n\tsslVerify\n' >> "$C/plugins/marketplaces/vibemaestro/.git/config"
  eq "$(bt "$P" rehearse $K $NEW)" 0 "[T] http.sslVerify with no value (true): rehearse rc 0"
  # another ref of the same origin (review round 1): a fetch refspec or a branch's merge ref that is not that branch
  tk remote.origin.fetch +refs/tags/v1:refs/remotes/origin/main
  refused "$P" "remote.origin.fetch from another ref" "has remote.origin.fetch (not a branch to its own name), a transport key"
  machine own; git_ -C "$C/plugins/marketplaces/vibemaestro" config --add remote.origin.fetch +refs/heads/evil:refs/remotes/origin/main
  refused "$P" "a second fetch refspec onto origin/main" "has remote.origin.fetch (not a branch to its own name), a transport key"
  tk branch.main.merge refs/heads/evil; refused "$P" "branch.main.merge another branch" "has branch.main.merge (not its own branch), a transport key"
  tk remote.origin.fetch +refs/heads/main:refs/remotes/origin/main
  eq "$(bt "$P" rehearse $K $NEW)" 0 "[T] a single-branch fetch refspec: rehearse rc 0"
  tk branch.main.merge refs/heads/main; eq "$(bt "$P" rehearse $K $NEW)" 0 "[T] branch.main.merge its own branch: rehearse rc 0"
  tk http.sslVerify true; eq "$(bt "$P" rehearse $K $NEW)" 0 "[T] http.sslVerify true: rehearse rc 0"
  tk branch.main.remote origin; eq "$(bt "$P" rehearse $K $NEW)" 0 "[T] branch.main.remote origin: rehearse rc 0"
  # a URL rewrite: the reader refuses it first; the kit names it too (fam_rewrite_kit proves the kit alone)
  tk url.https://github.com/evil/.pushInsteadOf https://github.com/acme/
  refused "$P" "url.<base>.pushInsteadOf" "has url.https://github.com/evil/.pushinsteadof"
}
# fam_rewrite_kit — the kit's own refusal of a URL rewrite, run on a copy whose reader no longer refuses one
fam_rewrite_kit() {
  local P=$1 k
  for k in insteadOf pushInsteadOf; do
    tk url.https://github.com/evil/.$k https://github.com/acme/
    refused "$P" "url.<base>.$k, the kit alone" "has url.https://github.com/evil/.$(printf '%s' "$k" | tr '[:upper:]' '[:lower:]'), a transport key"
  done
}

fam_signed() {
  local P=$1
  machine own; printf 'something else\n' > "$D/plan"
  eq "$(kit_phase "$P" run "$D/plan" $NEW)/$(calls)" "3/0" "[S] a run phase whose line is not in the signed plan: rc 3, no claude call"
  has "$(cat "$BT_OUT")" "REFUSE the line is not in the signed plan" "[S] …refused by name"
  eq "$(find "$D/state" -name 'kit-plugin-update-*' | wc -l | tr -d ' ')" 0 "[S] …and no copies kept"
}

fam_moves() {
  local P=$1
  machine subdir; : > "$W/race"
  eq "$(go_ "$P" $NEW)" 4 "[M] kit main moves at the plugin update: the post-check goes red, undo puts the state back (rc 4)"
  has "$(cat "$BT_OUT")" "FAIL vibemaestro-sdlc records gitCommitSha $OTHER, not $NEW" "[M] …the post-check names the commit it found"
  eq "$(same "$D/reg.before" "$(REG)")/$(same "$D/known.before" "$(KNOWN)")" "same/same" "[M] …undo puts both registry files back byte for byte"
  has "$(cat "$BT_OUT")" "LEFT the cache directory $C/plugins/cache/vibemaestro/vibemaestro-sdlc/${OTHER:0:12}-be49dd83" "[M] …undo names the new cache directories it leaves"
  has "$(cat "$BT_OUT")" "LEFT the marketplace clone $C/plugins/marketplaces/vibemaestro at the new marketplace head" "[M] …and the marketplace clone"
  eq "$(find "$D/state" -name 'kit-plugin-update-*' | wc -l | tr -d ' ')" 0 "[M] …and drops the run record"
  machine subdir; : > "$W/race-mkt"
  eq "$(go_ "$P" $NEW)/$(calls)" "4/1" "[M] kit main moves at the marketplace update: rc 4, no plugin update called"
  has "$(cat "$BT_OUT")" "REFUSE kit main moved to $OTHER during the run" "[M] …kit main moved at the marketplace update: refused by name"
  eq "$(same "$D/known.before" "$(KNOWN)")" same "[M] …undo puts known_marketplaces.json back byte for byte"
  machine subdir; manifest subdir '' '{"source": "git-subdir", "url": "https://github.com/acme/kit.git", "path": "plugins/vibemaestro-brain", "ref": "main", "sha": "'$OLD'"}' > "$W/mkt-next"
  eq "$(go_ "$P" $NEW)/$(calls)" "4/1" "[M] the marketplace update pins a sha: rc 4, no plugin update called"
  eq "$(same "$D/reg.before" "$(REG)")/$(same "$D/known.before" "$(KNOWN)")" "same/same" "[M] …undo puts both files back"
  machine subdir; manifest own > "$W/mkt-next"
  eq "$(go_ "$P" $NEW)/$(calls)" "4/1" "[M] the marketplace update changes the layout (git-subdir to the kit's own): rc 4, no plugin update called"
  has "$(cat "$BT_OUT")" "REFUSE after the marketplace update the layout is kit-own, kit acme/gitops, repo acme/gitops (was git-subdir acme/kit acme/gitops)" "[M] …the changed layout: refused by name"
  machine own
  kit_phase "$P" rehearse "$D/none" $NEW > /dev/null; sed -n 's/^PLAN \(plugin-update keep byte copies .*\)$/\1/p' "$BT_OUT" > "$D/plan"
  eq "$(kit_pair "$P" "$D/plan" $NEW)/$(calls)" "0/0" "[M] a run stopped before the marketplace update, then undone: undo rc 0, no claude call"
  has "$(cat "$BT_OUT")" "DO put back $C/plugins/installed_plugins.json" "[M] …undo puts the copies back"
  has "$(cat "$BT_OUT")" "the marketplace update never started: the clone is as it was" "[M] …undo says the clone is as it was"
  machine subdir; : > "$W/race"; : > "$W/other"
  eq "$(go_ "$P" $NEW)" 5 "[M] another plugin recorded during a failed run: undo leaves both files (rc 5)"
  has "$(cat "$BT_OUT")" "OTHER installed_plugins.json changed outside this run since the copy: plugins/other@elsewhere" "[M] …the other plugin's change is named"
  has "$(cat "$BT_OUT")" "LEAVE both registry files as they are" "[M] …both files left for the owner"
  eq "$(grep -c 'other@elsewhere' "$(REG)")/$(find "$D/state" -name 'kit-plugin-update-*' | wc -l | tr -d ' ')" 1/1 "[M] …the other plugin and the run record kept"
  eq "$(find "$D/state" -path '*/kit-plugin-update-*/left' | wc -l | tr -d ' ')" 1 "[M] …the record marked left"
  machine subdir; : > "$W/race"; : > "$W/other-known"
  eq "$(go_ "$P" $NEW)" 5 "[M] another marketplace recorded during a failed run: undo leaves both files (rc 5)"
  has "$(cat "$BT_OUT")" "OTHER known_marketplaces.json changed outside this run since the copy: elsewhere" "[M] …the other marketplace is named"
  machine subdir; : > "$W/race"; : > "$W/gc"
  eq "$(go_ "$P" $NEW)" 5 "[M] the update removed the old install: undo leaves both files (rc 5)"
  has "$(cat "$BT_OUT")" "GONE vibemaestro-sdlc $C/plugins/cache/vibemaestro/vibemaestro-sdlc/${OLD:0:12}-be49dd83" "[M] …the removed install is named"
  eq "$(sha_of vibemaestro-sdlc@vibemaestro)" "$OTHER" "[M] …the registry still names the install that exists"
}

fam_post() {
  local P=$1
  machine subdir; : > "$W/badversion"
  eq "$(go_ "$P" $NEW)" 4 "[P] a version not of the SHA: rc 4"
  has "$(cat "$BT_OUT")" "FAIL vibemaestro-sdlc's version '1.2.3' is not ${NEW:0:12} or ${NEW:0:12}-<8 hex>" "[P] …the version is named"
  machine subdir; : > "$W/versioned"
  eq "$(go_ "$P" $NEW)" 4 "[P] a plugin.json with a version: rc 4"
  has "$(cat "$BT_OUT")" "plugin.json carries a version ('9.9.9')" "[P] …the manifest version is named"
  machine subdir; : > "$W/elsewhere"
  eq "$(go_ "$P" $NEW)" 4 "[P] a forged installPath outside the cache: rc 4"
  has "$(cat "$BT_OUT")" "FAIL vibemaestro-sdlc's installPath '$W/forged/" "[P] …the forged installPath is named"
  machine subdir; : > "$W/old-launcher"
  eq "$(go_ "$P" $NEW)" 4 "[P] a launcher template that refuses the git-subdir directory: rc 4"
  has "$(cat "$BT_OUT")" "FAIL the launcher template refuses vibemaestro-sdlc's directory ${NEW:0:12}-be49dd83" "[P] …the launcher's refusal of the directory is named"
  machine subdir; : > "$W/shadow"
  eq "$(go_ "$P" $NEW)" 5 "[P] a launcher that resolves to another install (a project-scope entry added meanwhile): rc 5"
  has "$(cat "$BT_OUT")" "FAIL the launcher template resolves to $C/plugins/cache/vibemaestro/vibemaestro-sdlc/000000000000/scripts/baton.py, not the new sdlc" "[P] …the launcher's other install is named"
  has "$(cat "$BT_OUT")" "OTHER installed_plugins.json changed outside this run since the copy: plugins/vibemaestro-sdlc@vibemaestro (other scopes)" "[P] …undo leaves both files: the other scope's entry is named"
  eq "$(grep -c '"project"' "$(REG)")" 1 "[P] …and kept"
  local f
  machine subdir
  eq "$(go_ "$P" $NEW)" 0 "[P] a passing run, then brain's plugin.json made a symlink: go rc 0"
  f=$(find "$C/plugins/cache/vibemaestro/vibemaestro-brain/${NEW:0:12}-adc9e2e3" -name plugin.json)   # by name: plan.py reads a path tail as a fixture use
  mv "$f" "$D/brain.json"; ln -s "$D/brain.json" "$f"
  eq "$(post_again "$P")" 1 "[P] …the post-check again: rc 1"
  has "$(cat "$BT_OUT")" "FAIL vibemaestro-brain's plugin.json is not a regular file" "[P] …the symlinked plugin.json is named"
  machine subdir
  eq "$(go_ "$P" $NEW)" 0 "[P] a passing run, then sdlc's launcher template made a symlink: go rc 0"
  f=$(find "$C/plugins/cache/vibemaestro/vibemaestro-sdlc/${NEW:0:12}-be49dd83" -name baton-launcher.py)
  mv "$f" "$D/launcher.py"; ln -s "$D/launcher.py" "$f"
  eq "$(post_again "$P")" 1 "[P] …the post-check again: rc 1"
  has "$(cat "$BT_OUT")" "is not a regular file (a symlink or another kind): $f" "[P] …the symlinked launcher template is named"
  machine subdir
  eq "$(go_ "$P" $NEW)" 0 "[P] a passing run, then brain's .claude-plugin made a symlink: go rc 0"
  f=$(find "$C/plugins/cache/vibemaestro/vibemaestro-brain/${NEW:0:12}-adc9e2e3" -name plugin.json); f=${f%/*}
  mv "$f" "$D/bcp"; ln -s "$D/bcp" "$f"
  eq "$(post_again "$P")" 1 "[P] …the post-check again: rc 1"
  has "$(cat "$BT_OUT")" "FAIL vibemaestro-brain's plugin.json is not a directory (a symlink or another kind): $f" "[P] …the symlinked install .claude-plugin is named"
  machine subdir
  eq "$(go_ "$P" $NEW)" 0 "[P] a passing run, then sdlc's scripts made a symlink: go rc 0"
  f=$(find "$C/plugins/cache/vibemaestro/vibemaestro-sdlc/${NEW:0:12}-be49dd83" -name baton-launcher.py); f=${f%/*}
  mv "$f" "$D/scripts"; ln -s "$D/scripts" "$f"
  eq "$(post_again "$P")" 1 "[P] …the post-check again: rc 1"
  has "$(cat "$BT_OUT")" "is not a directory (a symlink or another kind): $f" "[P] …the symlinked install scripts is named"
  machine own
  eq "$(go_ "$P" $NEW)" 0 "[P] a passing run, then brain's install directory made a file: go rc 0"
  f="$C/plugins/cache/vibemaestro/vibemaestro-brain/${NEW:0:12}"
  rm -rf "$f"; : > "$f"
  eq "$(post_again "$P")" 1 "[P] …the post-check again: rc 1"
  has "$(cat "$BT_OUT")" "FAIL vibemaestro-brain's plugin.json cannot be read" "[P] …the install directory that is a file is named"
}

fam_undo() {
  local P=$1
  machine own; printf 'some plan\n' > "$D/plan"
  eq "$(kit_phase "$P" undo "$D/plan" $NEW)" 0 "[U] an undo with no run record: rc 0"
  has "$(cat "$BT_OUT")" "no run record" "[U] …it says so and puts nothing back"
  mkdir -p "$D/rec"; printf '%s\n' '{"stale": true}' > "$D/rec/installed_plugins.json"; cp "$D/rec/installed_plugins.json" "$D/rec/known_marketplaces.json"
  printf 'another plan id\n' > "$D/rec/plan"
  local r="$D/state/vibemaestro/baton/records"; mkdir -p "$r"
  # the kit names its record by its runner's PID: a shell that copies the record under its own PID, then runs the kit (not exec)
  eq "$( ( cd "$D" && HOME="$D/home" XDG_STATE_HOME="$D/state" CLAUDE_CONFIG_DIR="$C" FAKE_WORLD="$W" BATON_PHASE=undo BATON_PLAN="$D/plan" BATON_PLUGIN_ROOT="$P" \
      bash -c 'cp -R "$1" "$2/kit-plugin-update-$$" && bash "$3" "$4"; rc=$?; exit $rc' _ "$D/rec" "$r" "$P/batons/plugin-update.sh" $NEW ) > "$BT_OUT" 2>&1; echo $?)" 0 "[U] an earlier run's record: rc 0"
  has "$(cat "$BT_OUT")" "is an earlier run's: nothing of this run to put back" "[U] …nothing put back"
  eq "$( ( cd "$D" && HOME="$D/home" XDG_STATE_HOME="$D/state" CLAUDE_CONFIG_DIR="$C" FAKE_WORLD="$W" BATON_PHASE=undo BATON_PLAN= BATON_PLUGIN_ROOT="$P" \
      bash -c 'cp -R "$1" "$2/kit-plugin-update-$$" && bash "$3" "$4"; rc=$?; exit $rc' _ "$D/rec" "$r" "$P/batons/plugin-update.sh" $NEW ) > "$BT_OUT" 2>&1; echo $?)" 1 "[U] a run record and no signed plan: rc 1"
  has "$(cat "$BT_OUT")" "LEAVE no signed plan (BATON_PLAN)" "[U] …no signed plan: named"
  cp -R "$D/rec" "$D/rec-left"; : > "$D/rec-left/left"
  # signed: the rehearse's own plan, so only the guard stands between this run and the left copies
  kit_phase "$P" rehearse "$D/none" $NEW > /dev/null; sed -n 's/^PLAN //p' "$BT_OUT" > "$D/plan-real"
  eq "$( ( cd "$D" && HOME="$D/home" XDG_STATE_HOME="$D/state" CLAUDE_CONFIG_DIR="$C" FAKE_WORLD="$W" STUB_SRC="$SRC_ROOT/plugins" BATON_PHASE=run BATON_PLAN="$D/plan-real" BATON_PLUGIN_ROOT="$P" \
      bash -c 'cp -R "$1" "$2/kit-plugin-update-$$" && bash "$3" "$4"; rc=$?; exit $rc' _ "$D/rec-left" "$r" "$P/batons/plugin-update.sh" $NEW ) > "$BT_OUT" 2>&1; echo $?)/$(calls)" 3/0 "[U] a run whose record an earlier undo left for the owner: rc 3, no claude call"
  has "$(cat "$BT_OUT")" "holds copies an earlier undo left for the owner" "[U] …refused by name"
  eq "$(same "$D/reg.before" "$(REG)")" same "[U] …the registry is untouched"
}

# next_commit <tag> — a new empty commit on top of the clone's main, on a branch of its own (the clone stays where it is); its SHA
next_commit() {
  git_ -C "$CL" checkout -q -b "next-$1" main && git_ -C "$CL" commit -q --allow-empty -m "next $1" && git_ -C "$CL" rev-parse HEAD \
    && git_ -C "$CL" checkout -q main
}
# the marketplace-local plugins (./plugins/<name>): both layouts, skips, refusals, and the world moving
fam_local() {
  local P=$1 m2 n2 rc
  LOCALS=acme-ops machine subdir
  eq "$(bt "$P" rehearse $K $NEW)" 0 "[L] git-subdir marketplace with a local plugin: rehearse rc 0"
  has "$(cat "$BT_OUT")" "PLAN plugin-update acme-ops@vibemaestro at user scope from $OLDL to $M (marketplace acme/gitops)" "[L] …the local plugin's line: its old commit and the marketplace's main"
  has "$(cat "$BT_OUT")" "PLAN plugin-update verify the marketplace clone at main $M, clean" "[L] …the check after the marketplace update is a step of the plan"
  has "$(cat "$BT_OUT")" "PLAN-COUNT 6" "[L] …six writes"
  eq "$(go_ "$P" $NEW)" 0 "[L] git-subdir marketplace with a local plugin: go rc 0"
  eq "$(cat "$W/claude.log")" "plugin marketplace update vibemaestro
plugin update vibemaestro-sdlc@vibemaestro --scope user
plugin update vibemaestro-brain@vibemaestro --scope user
plugin update acme-ops@vibemaestro --scope user" "[L] …the marketplace, sdlc, brain, then the local plugin"
  eq "$(git_ -C "$CL" rev-parse HEAD)/$(sha_of acme-ops@vibemaestro)" "$M/$M" "[L] …the clone and the local plugin at the marketplace's main"
  has "$(cat "$BT_OUT")" "CHECK acme-ops at ${M:0:12} commit $M (was $OLDL) in $C/plugins/cache/vibemaestro/acme-ops/${M:0:12}" "[L] …the post-check names the local plugin with its old and new commit"
  has "$(cat "$BT_OUT")" "CHECK vibemaestro-sdlc at ${NEW:0:12}-be49dd83 commit $NEW (was $OLD)" "[L] …and sdlc with its old and new commit"
  # [K] skips: the marketplace moves on, the kit does not: only the local plugin
  m2=$(next_commit k1); printf '%s\n' "$m2" > "$W/mmain"; : > "$W/claude.log"
  eq "$(go_ "$P" $NEW)" 0 "[K] sdlc and brain at the SHA, the local plugin behind: go rc 0"
  eq "$(cat "$W/claude.log")" "plugin marketplace update vibemaestro
plugin update acme-ops@vibemaestro --scope user" "[K] …only the local plugin updated"
  has "$(cat "$BT_OUT")" "SKIP vibemaestro-sdlc@vibemaestro already at $NEW" "[K] …sdlc named as skipped"
  eq "$(sha_of acme-ops@vibemaestro)" "$m2" "[K] …the local plugin at the new main"
  # the kit moves on, the marketplace does not: only sdlc and brain
  n2=5555555555555555555555555555555555555555; printf '%s\n' "$n2" > "$W/main"; : > "$W/claude.log"
  eq "$(go_ "$P" $n2)" 0 "[K] the local plugin at the marketplace's main, the kit behind: go rc 0"
  eq "$(cat "$W/claude.log")" "plugin marketplace update vibemaestro
plugin update vibemaestro-sdlc@vibemaestro --scope user
plugin update vibemaestro-brain@vibemaestro --scope user" "[K] …only sdlc and brain updated"
  has "$(cat "$BT_OUT")" "SKIP acme-ops@vibemaestro already at $m2" "[K] …the local plugin named as skipped"
  eq "$(bt "$P" rehearse $K $n2)/$(calls)" "1/3" "[K] every plugin at its target: rehearse rc 1, no claude call"
  has "$(cat "$BT_OUT")" "REFUSE nothing to do: every plugin already records its target" "[K] …refused by name"
  LOCALS=acme-ops machine own
  eq "$(go_ "$P" $NEW)" 0 "[L] the kit's own marketplace with a third local plugin: go rc 0"
  has "$(cat "$BT_OUT")" "plugin-update acme-ops@vibemaestro at user scope from $OLDL to $NEW (marketplace acme/kit)" "[L] …the local plugin's target is the kit SHA"
  eq "$(sha_of vibemaestro-sdlc@vibemaestro)/$(sha_of acme-ops@vibemaestro)" "$NEW/$NEW" "[L] …sdlc and the local plugin at the SHA"
  LOCALS="acme-ops acme-docs" machine subdir; json_set "$(REG)" 'del J["plugins"]["acme-docs@vibemaestro"]'
  eq "$(go_ "$P" $NEW)" 0 "[L] a local plugin with no user install: go rc 0"
  has "$(cat "$BT_OUT")" "NOT INSTALLED acme-docs@vibemaestro has no user-scope install" "[L] …it is named"
  eq "$(grep -c acme-docs "$W/claude.log")" 0 "[L] …and not installed"
  # [R] refused at rehearse, nothing called
  local src
  for src in '"./plugins/../x"' '"./plugins/acme-ops/sub"' '"../acme-ops"' '"./plugins/acme-ops/"' '"./plugins/other"'; do
    LOCALS=acme-ops machine subdir; man_set 'J["plugins"][2]["source"] = '"$src"
    refused "$P" "a local source $src" "acme-ops\" entry has the source $src, not ./plugins/<its name>"
  done
  LOCALS=acme-ops machine subdir; mkdir -p "$CL/x/.claude-plugin"; man_set 'J["plugins"][2].update(name="../x", source="./plugins/../x")'
  refused "$P" "a local name that climbs out of plugins" "entry has the source \"./plugins/../x\""
  LOCALS=acme-ops machine subdir; man_set 'J["plugins"].append({"name": "ext", "source": {"source": "github", "repo": "acme/ext"}})'
  refused "$P" "an entry of another source kind" "\"ext\" entry has the source"
  LOCALS=acme-ops machine subdir; man_set 'J["plugins"][2]["hooks"] = {"SessionStart": []}'
  refused "$P" "a local entry with hooks" "acme-ops entry carries hooks beyond name, source, description"
  LOCALS=acme-ops machine subdir; mv "$CL/plugins/acme-ops" "$D/ops"; ln -s "$D/ops" "$CL/plugins/acme-ops"
  refused "$P" "a symlinked local plugin directory" "the clone's plugins/acme-ops is not a directory (a symlink or another kind)"
  LOCALS=acme-ops machine own; mv "$CL/plugins" "$D/plugins"; ln -s "$D/plugins" "$CL/plugins"
  refused "$P" "a symlinked plugins directory" "the clone's plugins is not a directory (a symlink or another kind)"
  LOCALS=acme-ops machine subdir; printf 'changed\n' > "$CL/plugins/acme-ops/README.md"
  refused "$P" "a changed file in a local plugin directory" "plugins/acme-ops/README.md (differs from HEAD)"
  LOCALS=acme-ops machine subdir; : > "$CL/plugins/acme-ops/extra.sh"
  refused "$P" "an untracked file in a local plugin directory" "plugins/acme-ops/extra.sh (not in HEAD)"
  LOCALS=acme-ops machine subdir; printf 'extra.sh\n' >> "$CL/.git/info/exclude"; : > "$CL/plugins/acme-ops/extra.sh"
  refused "$P" "an ignored file in a local plugin directory" "plugins/acme-ops/extra.sh (not in HEAD)"
  LOCALS=acme-ops machine subdir; git_ -C "$CL" update-index --skip-worktree plugins/acme-ops/README.md
  printf 'changed\n' > "$CL/plugins/acme-ops/README.md"
  refused "$P" "a skip-worktree file in a local plugin directory" "plugins/acme-ops/README.md (differs from HEAD)"
  if [ "$(id -u)" != 0 ]; then      # root reads a directory whatever its mode
    LOCALS=acme-ops machine subdir; mkdir -p "$CL/plugins/acme-ops/hid"; : > "$CL/plugins/acme-ops/hid/e.sh"; chmod 000 "$CL/plugins/acme-ops/hid"
    rc=$(bt "$P" rehearse $K $NEW); chmod 700 "$CL/plugins/acme-ops/hid"    # back at once: the scratch tree must stay removable
    eq "$rc/$(calls)" "1/0" "[R] a local plugin directory that cannot be listed: rehearse rc 1, no claude call"
    has "$(cat "$BT_OUT")" "the clone's plugins/acme-ops/hid cannot be read" "[R] …a local plugin directory that cannot be listed: refused by name"
  else
    ok "[R] a local plugin directory that cannot be listed: rehearse rc 1, no claude call (skipped as root)"
    ok "[R] …a local plugin directory that cannot be listed: refused by name (skipped as root)"
  fi
  LOCALS=acme-ops machine subdir; : > "$CL/plugins/acme-ops/$(printf 'na\377me')"; git_ -C "$CL" add -A; git_ -C "$CL" commit -q -m name
  eq "$(bt "$P" rehearse $K $NEW)" 0 "[R] a committed file name that is not UTF-8: rehearse rc 0 (compared byte for byte)"
  LOCALS=acme-ops machine subdir; git_ init -q -b main "$D/subrepo"; printf 's\n' > "$D/subrepo/s"; git_ -C "$D/subrepo" add s
  git_ -C "$D/subrepo" commit -q -m s; git_ -C "$CL" -c protocol.file.allow=always submodule -q add "$D/subrepo" plugins/acme-ops/subm
  git_ -C "$CL" commit -q -m subm
  refused "$P" "a populated submodule in a local plugin directory" "plugins/acme-ops/subm (mode 160000 in HEAD"
  LOCALS=acme-ops machine subdir; rm "$CL/plugins/acme-ops/README.md"
  refused "$P" "a file missing from a local plugin directory" "plugins/acme-ops/README.md (missing)"
  LOCALS=acme-ops machine subdir; printf '{"name": "x"}\n' > "$(MAN)"; git_ -C "$CL" checkout -q -- .claude-plugin
  printf 'x\n' > "$CL/.claude-plugin/extra"
  refused "$P" "an untracked file in the clone's .claude-plugin" ".claude-plugin/extra (not in HEAD)"
  LOCALS=acme-ops machine subdir; git_ -C "$CL" config filter.x.clean "touch $D/ran"
  refused "$P" "a clean filter in the clone's git config" "has filter.x.clean, a filter"
  # git state of the clone that makes its index or objects lie about the tree (review round 1): the work tree is read and hashed
  local y
  LOCALS=acme-ops machine subdir; git_ -C "$CL" checkout -q -b evil "$M"; printf 'EVIL\n' > "$CL/plugins/acme-ops/README.md"
  git_ -C "$CL" commit -q -am evil; y=$(git_ -C "$CL" rev-parse HEAD); git_ -C "$CL" checkout -q main; git_ -C "$CL" replace "$M" "$y"
  eq "$(go_ "$P" $NEW)/$(calls)" "4/1" "[M] a replace ref swaps the marketplace's main for other content: rc 4, no plugin update"
  has "$(cat "$BT_OUT")" "plugins/acme-ops/README.md (differs from HEAD)" "[M] …the swapped content: refused by name"
  LOCALS=acme-ops machine subdir; touch -d 2026-01-01T00:00:00Z "$CL/plugins/acme-ops/README.md"; git_ -C "$CL" update-index --refresh > /dev/null
  git_ -C "$CL" config core.trustctime false; printf '# EVIL-ops\n' > "$CL/plugins/acme-ops/README.md"
  touch -d 2026-01-01T00:00:00Z "$CL/plugins/acme-ops/README.md"
  refused "$P" "a same-size edit the index's stat data hides (core.trustctime false)" "plugins/acme-ops/README.md (differs from HEAD)"
  LOCALS=acme-ops machine subdir; git_ -C "$CL" config core.fileMode false; chmod +x "$CL/plugins/acme-ops/README.md"
  refused "$P" "an executable bit core.fileMode false hides" "plugins/acme-ops/README.md (differs from HEAD)"
  LOCALS=acme-ops machine subdir; git_ -C "$CL" config core.ignorecase true; printf 'x\n' > "$CL/plugins/acme-ops/readme.md"
  refused "$P" "a file core.ignorecase hides" "plugins/acme-ops/readme.md (not in HEAD)"
  LOCALS=acme-ops machine subdir; git_ init -q "$CL/plugins/acme-ops/sub"; printf 'a\n' > "$CL/plugins/acme-ops/sub/a.txt"
  refused "$P" "a repository inside a local plugin directory" "plugins/acme-ops/sub/.git/HEAD (not in HEAD)"
  LOCALS=acme-ops machine subdir; ln -s "$D" "$CL/plugins/acme-ops/hooks"; git_ -C "$CL" add -A; git_ -C "$CL" commit -q -m link
  refused "$P" "a tracked symlink in a local plugin directory" "plugins/acme-ops/hooks (mode 120000 in HEAD"
  LOCALS=acme-ops machine subdir; man_set 'J["metadata"] = {"pluginRoot": "./evil"}'
  refused "$P" "a manifest whose metadata sets pluginRoot" "the marketplace manifest's metadata sets pluginRoot"
  LOCALS=acme-ops machine subdir; man_set 'J["extra"] = 1'
  refused "$P" "a manifest with another top-level key" "the marketplace manifest carries extra beyond"
  LOCALS=acme-ops machine subdir
  json_set "$(REG)" 'J["plugins"]["acme-ops@vibemaestro"].append(dict(J["plugins"]["acme-ops@vibemaestro"][0]))'
  refused "$P" "a local plugin with two user installs" "acme-ops@vibemaestro has 2 user-scope installs"
  # [M] the marketplace's commit is not main, or moves
  LOCALS=acme-ops machine subdir; : > "$W/stale-head"
  eq "$(go_ "$P" $NEW)/$(calls)" "4/1" "[M] the marketplace update leaves the clone's HEAD off main: rc 4, no plugin update"
  has "$(cat "$BT_OUT")" "REFUSE the clone's HEAD is $MOLD, not the marketplace's main $M" "[M] …the stale HEAD: refused by name"
  eq "$(same "$D/reg.before" "$(REG)")/$(same "$D/known.before" "$(KNOWN)")" "same/same" "[M] …undo puts both files back"
  LOCALS=acme-ops machine subdir; m2=$(next_commit race); printf '%s\n' "$m2" > "$W/race-mmain"
  eq "$(go_ "$P" $NEW)/$(calls)" "4/1" "[M] the marketplace's main moves during the run: rc 4, no plugin update"
  has "$(cat "$BT_OUT")" "REFUSE the marketplace's main on github.com/acme/gitops moved to $m2 during the run" "[M] …the moved main: refused by name"
  # main moves after the rehearse: the signed line pins the old main, so the run refuses before the marketplace update
  LOCALS=acme-ops machine subdir
  kit_phase "$P" rehearse "$D/none" $NEW > /dev/null; sed -n 's/^PLAN //p' "$BT_OUT" > "$D/plan"
  m2=$(next_commit after); printf '%s\n' "$m2" > "$W/mmain"
  eq "$(kit_pair "$P" "$D/plan" $NEW)/$(calls)" "0/0" "[M] the marketplace's main moves after the rehearse: no claude call, undo rc 0"
  has "$(cat "$BT_OUT")" "REFUSE the line is not in the signed plan (the registry, the layout, kit main or the marketplace's main moved since signing): plugin-update marketplace vibemaestro (layout git-subdir, repo acme/gitops from $MOLD to main $m2," "[M] …the run's marketplace line names the newer main and is refused"
  eq "$(git_ -C "$CL" rev-parse HEAD)/$(same "$D/reg.before" "$(REG)")" "$MOLD/same" "[M] …the clone and the registry stay as they were"
  has "$(cat "$BT_OUT")" "the marketplace update never started: the clone is as it was" "[M] …undo says the marketplace update never started"
  # marketplace.json changed between the rehearse and the run: committed (the clone's HEAD moved), or not (a changed tree)
  LOCALS=acme-ops machine subdir
  kit_phase "$P" rehearse "$D/none" $NEW > /dev/null; sed -n 's/^PLAN //p' "$BT_OUT" > "$D/plan"
  man_set 'J["plugins"][2]["description"] = "changed"'
  eq "$(kit_phase "$P" run "$D/plan" $NEW)/$(calls)" "3/0" "[M] marketplace.json committed anew after the rehearse: run rc 3, no claude call"
  has "$(cat "$BT_OUT")" "REFUSE the line is not in the signed plan" "[M] …the moved HEAD: refused by name"
  LOCALS=acme-ops machine subdir
  kit_phase "$P" rehearse "$D/none" $NEW > /dev/null; sed -n 's/^PLAN //p' "$BT_OUT" > "$D/plan"
  json_set "$(MAN)" 'J["plugins"][2]["description"] = "changed"'
  eq "$(kit_phase "$P" run "$D/plan" $NEW)/$(calls)" "3/0" "[M] marketplace.json changed in the tree after the rehearse: run rc 3, no claude call"
  has "$(cat "$BT_OUT")" ".claude-plugin/marketplace.json (differs from HEAD)" "[M] …the changed manifest: refused by name"
  LOCALS=acme-ops machine subdir; LOCALS="" manifest subdir > "$W/mkt-next"
  eq "$(go_ "$P" $NEW)/$(calls)" "4/1" "[M] the marketplace update drops the local plugin: rc 4, no plugin update"
  has "$(cat "$BT_OUT")" "REFUSE after the marketplace update the local plugins are none (was acme-ops)" "[M] …the changed local plugins: refused by name"
  LOCALS=acme-ops machine subdir; : > "$W/race-local"
  eq "$(go_ "$P" $NEW)" 4 "[M] the local plugin installs another commit: the post-check goes red, undo (rc 4)"
  has "$(cat "$BT_OUT")" "FAIL acme-ops records gitCommitSha $OTHER, not $M" "[M] …the local plugin's commit is named"
  eq "$(same "$D/reg.before" "$(REG)")/$(same "$D/known.before" "$(KNOWN)")" "same/same" "[M] …undo puts both files back byte for byte"
  has "$(cat "$BT_OUT")" "LEFT the cache directory $C/plugins/cache/vibemaestro/acme-ops/${OTHER:0:12}" "[M] …undo names the local plugin's new cache directory"
  LOCALS=acme-ops machine subdir; : > "$W/fail-local"
  eq "$(go_ "$P" $NEW)" 4 "[M] the local plugin's update fails after recording its entry: undo puts the state back (rc 4)"
  eq "$(same "$D/reg.before" "$(REG)")/$(same "$D/known.before" "$(KNOWN)")" "same/same" "[M] …the run's own failed update is put back byte for byte"
  LOCALS=acme-ops machine subdir; : > "$W/eat-stdin"
  eq "$(go_ "$P" $NEW)/$(calls)" "0/4" "[M] a plugin update that reads its standard input: go rc 0, every plugin updated"
  LOCALS=acme-ops machine subdir; : > "$W/dirty-at-sdlc"
  eq "$(go_ "$P" $NEW)/$(grep -c acme-ops "$W/claude.log")" "4/0" "[M] the clone changes during the sdlc update: rc 4, the local plugin not updated"
  has "$(cat "$BT_OUT")" "plugins/acme-ops/late.sh (not in HEAD)" "[M] …the late file: refused by name"
  LOCALS=acme-ops machine subdir; : > "$W/swap-at-sdlc"
  eq "$(go_ "$P" $NEW)/$(grep -c acme-ops "$W/claude.log")" "4/0" "[M] the local plugin directory swapped for a symlink during the sdlc update: rc 4, not updated"
  has "$(cat "$BT_OUT")" "the clone's plugins/acme-ops, read again for the tree, is not a directory (a symlink or another kind)" "[M] …the swapped directory: refused by name"
  LOCALS=acme-ops machine subdir; : > "$W/meddle"
  eq "$(go_ "$P" $NEW)" 5 "[M] another hand moves sdlc during the run: undo leaves both files (rc 5)"
  has "$(cat "$BT_OUT")" "MOVED vibemaestro-sdlc records $MEDDLE, neither the copy's entry nor the one this run's update left" "[M] …the moved plugin is named"
  eq "$(sha_of vibemaestro-sdlc@vibemaestro)" "$MEDDLE" "[M] …and kept"
}

FAMILIES="fam_layouts fam_refuse fam_transport fam_signed fam_moves fam_post fam_undo fam_local"
for f in $FAMILIES; do echo "-- $f"; "$f" "$PLUGIN"; done
# the reader refuses a URL rewrite before the kit reads the clone (by the key, and by the fetch URL it gives): the kit's own
# refusal runs on a copy without either
NORW="$TMP/no-reader-rewrite"; mk_plugin_copy "$NORW"
mutate "$NORW/gates/plugin_update.py" 'or (key.startswith("url.") and key.endswith(("insteadof", "pushinsteadof"))):' ':'
mutate "$NORW/gates/plugin_update.py" '    if gh_repo(fetch) != known_repo:' '    if False:'
echo "-- fam_rewrite_kit (a copy whose reader takes a URL rewrite)"; fam_rewrite_kit "$NORW"

echo "== planted breaks: each family must go red on a plugin copy with one break in the kit =="
KBRK() {  # KBRK <label> <family> <needle> <old> <new> — a break in the kit baton
  local label=$1 fam=$2 needle=$3 d; d="$TMP/break-$label"; mk_plugin_copy "$d"
  mutate "$d/batons/plugin-update.sh" "$4" "$5" && expect_red "$label" "$fam" "$d" "$needle"
}
GBRK() {  # GBRK <label> <family> <needle> <old> <new> — a break in its engine, gates/plugin_update.py
  local label=$1 fam=$2 needle=$3 d; d="$TMP/break-$label"; mk_plugin_copy "$d"
  mutate "$d/gates/plugin_update.py" "$4" "$5" && expect_red "$label" "$fam" "$d" "$needle"
}
KBRK main-unchecked fam_refuse '[R] …a SHA that is not kit main: refused by name' '  if [ "$main" != "$SHA" ]; then
    echo "REFUSE kit main on' '  if false; then
    echo "REFUSE kit main on'
KBRK main-unchecked-after-marketplace fam_moves '[M] kit main moves at the marketplace update: rc 4, no plugin update' '  if [ "$main" != "$SHA" ]; then
    echo "REFUSE kit main moved' '  if false; then
    echo "REFUSE kit main moved'
KBRK layout-unchecked-after-marketplace fam_moves '[M] …the changed layout: refused by name' '  if [ "$LAYOUT $KIT $REPO" != "$was" ]; then' '  if false; then'
GBRK directory-taken fam_refuse '[R] …a directory marketplace' '        refuse("marketplace %s is a %r source, not a git one (github or git): a layout this kit does not know" % (MKT, kind))' '        known_repo = None'
GBRK ref-unchecked fam_refuse '[R] a ref other than main' '"path": "plugins/" + n, "ref": "main"}' '"path": "plugins/" + n, "ref": s.get("ref")}'
GBRK extra-keys-allowed fam_refuse '[R] a pinned sha' '            if s != want:' '            if {k: s.get(k) for k in want} != want:'
GBRK ssh-subdir-allowed fam_refuse '[R] …an ssh URL in a git-subdir source' '        cands = {gh_repo(srcs[n]["url"], https_only=True) for n in NAMES}' '        cands = {gh_repo(srcs[n]["url"]) for n in NAMES}'
GBRK two-repos-allowed fam_refuse 'two repositories in the git-subdir sources' '    if None in cands or len(cands) != 1:' '    cands.discard(None); cands = cands or {None}
    if None in cands:'
# The fetch-URL check (git ls-remote --get-url origin) refuses the next cases too, so these guards name the cause and their
# breaks go red on the name: origin-unread, env-unchecked, discovery-unchecked (it names an invalid .git), env-empty-allowed
# (git's own error refuses an empty GIT_CONFIG as well).
GBRK origin-unread fam_refuse '[R] …the clone'"'"'s origin another repository than the known source: refused by name' '    if gh_repo(origin) != known_repo:' '    if False:'
GBRK clone-anywhere fam_refuse '[R] …a clone outside the marketplaces directory: refused by name' '    if os.path.dirname(clone) != os.path.join(plugins, "marketplaces") or not' '    if not'
GBRK any-scope fam_refuse '[R] a plugin not installed at user scope' 'if isinstance(e, dict) and e.get("scope") == "user"]' 'if isinstance(e, dict)]'
KBRK redo-allowed fam_refuse '[R] both already at the SHA' '  if [ "$total" -eq 0 ]; then' '  if false; then'
GBRK symlink-followed fam_refuse '[R] a registry that is a symlink' '    if not stat.S_ISREG(st.st_mode):
        return "is not a regular file' '    if False:
        return "is not a regular file'
KBRK sha-loose fam_refuse '[R] …a SHA argument that is not 40 lower-case hex (222222222222): the usage is named' '! [[ "$1" =~ ^[0-9a-f]{40}$ ]]' '! [[ "$1" =~ ^[0-9a-fA-F]{12,40} ]]'
KBRK unsigned fam_signed '[S] a run phase whose line is not in the signed plan' '  if [ -z "${BATON_PLAN:-}" ] || ! grep -Fqx -- "$line" "$BATON_PLAN"; then' '  if false; then'
GBRK commit-unchecked fam_moves '[M] …the post-check names the commit it found' '        if e.get("gitCommitSha") != sha:' '        if False:'
KBRK restore-from-current fam_moves '[M] …undo puts both registry files back byte for byte' '  cp -p -- "$RECORD/$1" "$PLUGINS/$1.kit-plugin-update.$$"' '  cp -p -- "$PLUGINS/$1" "$PLUGINS/$1.kit-plugin-update.$$"'
KBRK leaves-unnamed fam_moves '[M] …and the marketplace clone' '    echo "LEFT the marketplace clone' '    : "LEFT the marketplace clone'
KBRK marker-unwritten fam_moves '[M] …and the marketplace clone' '  : > "$RECORD/$1"' '  :'
KBRK clone-left-always fam_moves '[M] …undo says the clone is as it was' '  if [ -f "$RECORD/marketplace-update" ]; then' '  if true; then'
KBRK prune-never fam_layouts '[L] …the run deletes a record older than seven days, and only that one' '-mtime +7 -exec sh -c' '-mtime +7000 -exec sh -c'
KBRK next-unquoted fam_layouts '[L] …the next setup step quotes the path' "  printf 'NEXT   $NEXT_PY %q permissions" "  printf 'NEXT   $NEXT_PY %s permissions"
KBRK relative-cfg-allowed fam_refuse '[R] …a relative CLAUDE_CONFIG_DIR: refused by name' '  "") CFG="$HOME/.claude" ;;' '  *) CFG="$HOME/.claude" ;;'
KBRK unsigned-undo fam_undo '[U] …no signed plan: named' '  if [ -z "$mine" ]; then' '  if false; then'
GBRK entry-keys-allowed fam_refuse '[R] …a marketplace entry with hooks: refused by name' '        if extra:' '        if False:'
GBRK known-ref-allowed fam_refuse '[R] …a known source at another ref: refused by name' '    if set(src) - keys or src.get("ref", "main") != "main":' '    if False:'
GBRK known-host-unchecked fam_refuse '[R] …a cleartext known source on another host: refused by name' '    if known_repo is None:' '    if False:'
GBRK origin-urls-many fam_refuse '[R] …a clone whose origin has two URLs: refused by name' '    if len(urls) != 1:' '    if not urls:'
GBRK rewrite-allowed fam_refuse '[R] …a clone whose git config rewrites the URL: refused by name' 'or (key.startswith("url.") and key.endswith(("insteadof", "pushinsteadof"))):' ':'
GBRK abs-location fam_refuse '[R] …a relative installLocation: refused by name' '    if not isinstance(loc, str) or not os.path.isabs(loc):' '    if not isinstance(loc, str):'
GBRK http-subdir-allowed fam_refuse '[R] …an http URL in a git-subdir source: refused by name' '    for pre in ("https://%s/" % HOST,) + ' '    for pre in ("https://%s/" % HOST, "http://%s/" % HOST) + '
GBRK two-user-allowed fam_refuse '[R] …two user-scope installs: refused by name' '        if len(user) != 1:' '        if len(user) < 1:'
GBRK others-unchecked fam_moves "[M] …the other plugin's change is named" '        if keys:' '        if False:'
GBRK gone-unchecked fam_moves '[M] …the removed install is named' '        if not isinstance(p, str) or not os.path.isdir(p):' '        if not isinstance(p, str):'
GBRK plugin-json-symlink fam_post '[P] …the symlinked plugin.json is named' '        why = unreal(os.path.dirname(pj)) or irregular(pj)' '        why = None'
GBRK launcher-symlink fam_post '[P] …the symlinked launcher template is named' '            why = unreal(os.path.dirname(tpl)) or irregular(tpl)' '            why = None'
GBRK git-config-symlink fam_refuse '[R] …a clone whose git config is a symlink: refused by name' '    why = irregular(os.path.join(clone, ".git", "config"))' '    why = None'
GBRK dot-git-symlink fam_refuse '[R] …a clone whose .git is a symlink: refused by name' '        why = unreal(os.path.join(clone, d))' '        why = None'
GBRK include-allowed fam_refuse '[R] …a clone whose git config includes another file: refused by name' 'if key.startswith(("include.", "includeif.")) or (' 'if ('
GBRK worktree-config-ignored fam_refuse "[R] …a rewrite in the clone's worktree config: refused by name" '    listing = git(["config", "-z", "--list"], clone_env(clone),' '    listing = git(["config", "--file", os.path.join(clone, ".git", "config"), "-z", "--list"], clone_env(clone),'
GBRK known-rest-unchecked fam_moves '[M] …the other marketplace is named' '    return {k: v for k, v in d.items() if k != MKT} if isinstance(d, dict)' '    return {} if isinstance(d, dict)'
GBRK other-scope-dropped fam_post "[P] …undo leaves both files: the other scope's entry is named" '        for k in ours & set(p):' '        for k in []:'
KBRK kept-unnamed fam_layouts '[L] …the run names its record' '  echo "KEPT the run record $RECORD"' '  :'
KBRK next-unquoted-launcher fam_layouts "[L] …the launcher's path is quoted too" "  printf 'NEXT   %q permissions --check" "  printf 'NEXT   %s permissions --check"
KBRK prune-left fam_layouts '[L] …a record left for the owner is never deleted' '[ -e "$1/left" ] || rm -rf -- "$1"' 'rm -rf -- "$1"'
KBRK left-unmarked fam_moves '[M] …the record marked left' '    write "mark the run record $RECORD as left for the owner" touch "$RECORD/left"' '    :'
KBRK left-reused fam_undo '[U] a run whose record an earlier undo left for the owner: rc 3, no claude call' '  if [ -e "$RECORD/left" ]; then' '  if false; then'
GBRK env-unchecked fam_refuse '[R] …GIT_CONFIG naming another file than the clone'"'"'s: refused by name' '    if named:' '    if False:'
GBRK discovery-unchecked fam_refuse '[R] …an invalid .git inside another repository: refused by name' '    found = git(["-C", clone, "rev-parse", "--absolute-git-dir"], os.environ, "read the clone as a repository").strip()' '    found = os.path.join(clone, ".git")'
GBRK discovery-elsewhere fam_refuse '[R] …an invalid .git inside another repository: refused by name' '    if os.path.realpath(found) != os.path.realpath(os.path.join(clone, ".git")):' '    if False:'
GBRK owner-global-read fam_refuse "[R] a global rewrite that stays on the repository (https to ssh): rehearse rc 0" 'GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,' ''
GBRK fetch-url-global fam_refuse "[R] a rewrite off the repository in the owner's global git config: rehearse rc 1" '    if gh_repo(fetch) != known_repo:' '    if False:'
GBRK fetch-url-system fam_refuse "[R] a rewrite off the repository in the system git config: rehearse rc 1" '    if gh_repo(fetch) != known_repo:' '    if False:'
GBRK fetch-url-xdg fam_refuse "[R] a rewrite off the repository in the XDG git config: rehearse rc 1" '    if gh_repo(fetch) != known_repo:' '    if False:'
GBRK env-empty-allowed fam_refuse "[R] …GIT_CONFIG set (): refused by name" '    named = [k for k in GIT_ENV if k in os.environ]' '    named = [k for k in GIT_ENV if os.environ.get(k)]'
GBRK clone-plugin-dir-symlink fam_refuse '[R] …a clone whose .claude-plugin is a symlink: refused by name' '    for d in (".git", ".claude-plugin"):' '    for d in (".git",):'
GBRK install-plugin-dir-symlink fam_post '[P] …the symlinked install .claude-plugin is named' '        why = unreal(os.path.dirname(pj)) or irregular(pj)' '        why = irregular(pj)'
GBRK install-scripts-symlink fam_post '[P] …the symlinked install scripts is named' '            why = unreal(os.path.dirname(tpl)) or irregular(tpl)' '            why = irregular(tpl)'
KBRK host-unpinned fam_layouts '[L] …every gh call names --hostname github.com' 'gh api --hostname "$HOST" "repos/$1' 'gh api "repos/$1'
GBRK version-loose fam_post '[P] …the version is named' 're.match(r"^%s(?:-[0-9a-f]{8})?\Z" % sha[:12], v)' 're.match(r".+", v)'
GBRK manifest-version-allowed fam_post '[P] …the manifest version is named' '        if not isinstance(man, dict) or "version" in man:' '        if not isinstance(man, dict):'
GBRK path-unchecked fam_post '[P] …the forged installPath is named' ' or os.path.realpath(p) != want_dir:' ':'
GBRK launcher-dir-unchecked fam_post "[P] …the launcher's refusal of the directory is named" '                if not mod.INSTALL_DIR.match(os.path.basename(d)):' '                if False:'
GBRK launcher-resolve-unchecked fam_post "[P] …the launcher's other install is named" '            if picked != os.path.join(sdlc, "scripts", "baton.py"):' '            if False:'
GBRK leftovers-unnamed fam_moves '[M] …undo names the new cache directories it leaves' '    for p in sorted(paths(reg) - paths(before)):' '    for p in []:'
KBRK undo-any-record fam_undo '[U] …nothing put back' '  if [ "$(cat "$RECORD/plan")" != "$mine" ]; then' '  if false; then'
KBRK transport-unread fam_transport '[R] …remote.origin.proxy: refused by name' '  transport_keys
}' '}'
KBRK transport-quoted-match fam_transport '[R] …http.<url with a tab>.proxy: refused by name' \
  "    key=\${rec%%\$'\\n'*} val=\"\" why=\"\"" "    key=\$(printf '%q' \"\${rec%%\$'\\n'*}\") val=\"\" why=\"\""
KBRK transport-branch-any fam_transport '[R] …branch.main.remote another remote: refused by name' \
  '[ "$val" = origin ] || why=" (not origin)"' ':'
KBRK transport-merge-any fam_transport '[R] …branch.main.merge another branch: refused by name' \
  '[ "$val" = "refs/heads/$b" ] || why=" (not its own branch)"' ':'
KBRK transport-fetch-any fam_transport '[R] …remote.origin.fetch from another ref: refused by name' \
  '|| why=" (not a branch to its own name)"' '|| :'
KBRK transport-fetch-dst-loose fam_transport '[R] …a second fetch refspec onto origin/main: refused by name' \
  '"refs/heads/${b%%:*}:refs/remotes/origin/${b%%:*}" ]' '"refs/heads/${b%%:*}:${val#*:}" ]'
KBRK transport-ssl-any fam_transport '[T] http.sslVerify true: rehearse rc 0' 'true | yes | on | 1) ;;' 'yes | on | 1) ;;'
KBRK transport-url-only fam_transport '[R] …http.<url>.proxy: refused by name' 'http.proxy | http.*.proxy |' 'http.proxy |'
# the marketplace-local plugins
GBRK local-source-any fam_local '[R] …a local source "./plugins/../x": refused by name' '        elif LOCAL.match(name) and ".." not in name and p.get("source") == "./plugins/" + name:' '        elif True:'
GBRK local-name-climbs fam_local '[R] …a local name that climbs out of plugins: refused by name' '        elif LOCAL.match(name) and ".." not in name and p.get("source")' '        elif p.get("source")'
GBRK other-kind-skipped fam_local '[R] …an entry of another source kind: refused by name' "            refuse(\"the marketplace manifest's %s entry has the source" "            continue
            refuse(\"the marketplace manifest's %s entry has the source"
GBRK local-keys-allowed fam_local '[R] …a local entry with hooks: refused by name' '        if extra:' '        if False:'
GBRK local-dir-symlink fam_local '[R] …a symlinked local plugin directory: refused by name' "            refuse(\"the clone's %s %s: claude would install what it points at\" % (sub, why))" '            pass'
GBRK plugins-dir-symlink fam_local '[R] …a symlinked plugins directory: refused by name' '    for sub in ["plugins"] + [os.path.join("plugins", n) for n in local]:' '    for sub in [os.path.join("plugins", n) for n in local]:'
GBRK tree-differs-allowed fam_local '[R] …a changed file in a local plugin directory: refused by name' '        elif found[path] != (mode, oid):' '        elif False:'
GBRK tree-extra-allowed fam_local '[R] …an untracked file in a local plugin directory: refused by name' '    bad += ["%s (not in HEAD)" % shown(path) for path in sorted(set(found) - set(tracked))]' '    pass'
GBRK tree-missing-allowed fam_local '[R] …a file missing from a local plugin directory: refused by name' '        elif path not in found:' '        elif False:'
GBRK tree-mode-allowed fam_local '[R] …a tracked symlink in a local plugin directory: refused by name' '        if mode not in ("100644", "100755"):' '        if False:'
GBRK tree-exec-ignored fam_local '[R] …an executable bit core.fileMode false hides: refused by name' '"100755" if st.st_mode & stat.S_IXUSR else "100644"' 'tracked.get(rel, ("100644",))[0]'
GBRK replace-honoured fam_local '[M] a replace ref swaps the marketplace'"'"'s main for other content: rc 4, no plugin update' '                GIT_NO_REPLACE_OBJECTS="1")' ')'
GBRK manifest-keys-allowed fam_local '[R] …a manifest with another top-level key: refused by name' '    if extra:
        refuse("the marketplace manifest carries' '    if False:
        refuse("the marketplace manifest carries'
GBRK plugin-root-allowed fam_local '[R] …a manifest whose metadata sets pluginRoot: refused by name' '    if isinstance(man.get("metadata"), dict) and "pluginRoot" in man["metadata"]:' '    if False:'
KBRK update-failure-unrecorded fam_local "[M] the local plugin's update fails after recording its entry: undo puts the state back (rc 4)" '  "$@" < /dev/null || rc=$?' '  "$@" < /dev/null'
KBRK update-stdin-open fam_local '[M] a plugin update that reads its standard input: go rc 0, every plugin updated' '  "$@" < /dev/null || rc=$?' '  "$@" || rc=$?'
KBRK local-recheck-skipped fam_local '[M] the clone changes during the sdlc update: rc 4, the local plugin not updated' '  if [ "$at" != - ]; then' '  if false; then'
GBRK tree-manifest-unread fam_local "[R] …an untracked file in the clone's .claude-plugin: refused by name" '    paths = [".claude-plugin"] + ["plugins/" + n for n in names]' '    paths = ["plugins/" + n for n in names]'
GBRK tree-top-symlink fam_local '[M] …the swapped directory: refused by name' '        if why and (sub != "plugins" or names):' '        if False:'
[ "$(id -u)" = 0 ] || GBRK tree-walk-errors-swallowed fam_local '[R] …a local plugin directory that cannot be listed: refused by name' 'os.walk(os.path.join(clone, p), onerror=unreadable)' 'os.walk(os.path.join(clone, p))'
GBRK tree-names-decoded fam_local '[R] a committed file name that is not UTF-8: rehearse rc 0' '            tracked[os.fsdecode(path)] = (mode, oid)' '            tracked[path.decode("utf-8", "replace")] = (mode, oid)'
GBRK filter-allowed fam_local "[R] …a clean filter in the clone's git config: refused by name" '        if key.startswith("filter."):' '        if False:'
GBRK local-two-allowed fam_local '[R] …a local plugin with two user installs: refused by name' '        if len(user) > 1:' '        if False:'
GBRK head-unchecked fam_local '[M] …the stale HEAD: refused by name' '    if want != "-" and have != want:' '    if False:'
KBRK mmain-moved-unchecked fam_local '[M] …the moved main: refused by name' '  if [ "$main" != "$mmain" ]; then' '  if false; then'
KBRK mmain-unpinned fam_local '[M] the marketplace'"'"'s main moves after the rehearse: no claude call, undo rc 0' 'repo $REPO from $HEAD to main $mmain, kit' 'repo $REPO from $HEAD, kit'
KBRK head-unpinned fam_local '[M] …the moved HEAD: refused by name' 'repo $REPO from $HEAD to main' 'repo $REPO to main'
KBRK tree-before-unchecked fam_local '[M] …the changed manifest: refused by name' '  clean_tree -
' ''
KBRK locals-unchecked fam_local '[M] …the changed local plugins: refused by name' '  if [ "$LOCALS" != "$o" ]; then' '  if false; then'
GBRK local-commit-unchecked fam_local "[M] …the local plugin's commit is named" '        if e.get("gitCommitSha") != sha:' '        if False:'
GBRK moved-unchecked fam_local '[M] …the moved plugin is named' '        if b != a and b != left_:' '        if False:'
KBRK after-unrecorded fam_moves '[M] kit main moves at the plugin update: the post-check goes red, undo puts the state back (rc 4)' '  reader entry "$CFG" "$n" > "$RECORD/after-$n"' '  :'
KBRK skip-never fam_local '[K] …only the local plugin updated' '    if [ "$s" = "$t" ]; then' '    if false; then'
KBRK local-target-kit fam_local "[L] …the clone and the local plugin at the marketplace's main" '*) t=$mmain ;; esac' '*) t=$SHA ;; esac'
# the kit's own refusal of a URL rewrite, on the copy whose reader takes one: dropped, the rewrite goes through
d="$TMP/break-rewrite-kit"; mk_plugin_copy "$d"
mutate "$d/gates/plugin_update.py" 'or (key.startswith("url.") and key.endswith(("insteadof", "pushinsteadof"))):' ':' \
  && mutate "$d/gates/plugin_update.py" '    if gh_repo(fetch) != known_repo:' '    if False:' \
  && mutate "$d/batons/plugin-update.sh" ' | url.*.insteadof | url.*.pushinsteadof) why=: ;;' ') why=: ;;' \
  && expect_red rewrite-kit fam_rewrite_kit "$d" '[R] …url.<base>.insteadOf, the kit alone: refused by name'
QN=0; okdef=$(declare -f ok); baddef=$(declare -f bad); sp=$PASS; sf=$FAIL
ok() { :; }; bad() { QN=$((QN+1)); }
PLC="$TMP/break-none"; mk_plugin_copy "$PLC"
for f in $FAMILIES; do "$f" "$PLC" >/dev/null 2>&1; done
eval "$okdef"; eval "$baddef"; PASS=$sp; FAIL=$sf
eq "$QN" 0 "control: an unbroken copy passes every family (no failed check)"

echo "== nothing written outside the scratch tree =="
eq "$(tree_hash "$SRC_ROOT")" "$H0" "the repository tree is unchanged by the suite"
eq "$(real_state)" "$R0" "this machine's Claude Code registry files are unchanged by the suite"

echo; summary
