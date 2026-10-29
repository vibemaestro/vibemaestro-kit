#!/bin/bash
# =============================================================================
# Versions of the plugins: plugins/vibemaestro-sdlc/scripts/release.py check, the kinds of a change it tells apart
# =============================================================================
# Run: bash tests/test-plugin-version.sh
#
# Mapped in tests/suites.map to every path under plugins/, .changes/ and the
# marketplace, so CI runs it on any such change with no workflow of its own (CI checks out the full history).
#   [R] the real tree against the real origin/main
#   [S] the bootstrap kind (a base whose history never held .changes/README.md): red at an equal or lower version, green when raised, numbers not strings
#       (2.9.0 vs 2.10.0), a new plugin, two plugins, a change outside plugins/, a main that moved on, uncommitted and untracked
#       changes, a broken manifest, a removed plugin, a missing base (rc 3 locally, red under GITHUB_ACTIONS)
#   [O] the ordinary kind (a base whose history held .changes/README.md, even after it is gone): a plugin change needs an added
#       change file naming a marketplace entry, no released version (the CHANGELOG's first heading) moves, no manifest or
#       marketplace entry carries a version (except the PR that retires them from a base that still has them), change files well
#       formed and regular, pending ones and the README untouched, the marketplace's sources unchanged, no symlink or submodule
#       under plugins/, GITHUB_BASE_REF picks the base (the [R] run keeps the CI environment)
#   [X] the ordinary kind, a plugin removed whole: its marketplace entry may go once plugins/<name>/ holds no file; a pending change
#       file naming only it may be deleted; one that also names others may lose exactly its name, keep its level and reword its
#       body, which then names no removed plugin (the name or the part after its first -, any case); every other pending note stays
#   [R] [H] [B] the release, hotfix and back-merge kinds: the released version is the CHANGELOG's; a plugin never released goes to
#       0.1.0; the cut writes no manifest and no kb page
# Then each planted break of release.py must turn its family red and an unbroken copy must stay green. Real git on throw-away
# repositories, no network.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
# shellcheck source=fixtures/flow.sh
. "$HERE/fixtures/flow.sh"
# shellcheck source=fixtures/ports.sh
. "$HERE/fixtures/ports.sh"

PV_REAL="$SRC_ROOT/plugins/vibemaestro-sdlc/scripts/release.py"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"

PV=""; W=""; O=""
OUT=""; RC=0

# ── fixtures ─────────────────────────────────────────────────────────────
gw() { ( cd "$W" && git_ "$@" ); }
# setv <plugin> <version> — write the manifest of a plugin in W
setv() { mkdir -p "$W/plugins/$1/.claude-plugin"; printf '{"name": "%s", "version": %s}\n' "$1" "$2" > "$W/plugins/$1/.claude-plugin/plugin.json"; }
# setm <plugin> [json members] — a manifest with no version (the private form), e.g. setm alpha ', "description": "d"'
setm() { mkdir -p "$W/plugins/$1/.claude-plugin"; printf '{"name": "%s"%s}\n' "$1" "${2:-}" > "$W/plugins/$1/.claude-plugin/plugin.json"; }
# setcl <plugin> <version|-> — a CHANGELOG whose first heading is ## <version> (released), or the private-history heading (-)
setcl() {
  local h="## $2"; [ "$2" = - ] && h="## Private history"
  printf '# Changelog of %s\n\nNewest first.\n\n%s\n\n- patch: earlier\n' "$1" "$h" > "$W/plugins/$1/CHANGELOG.md"
}
cm() { gw add -A; gw commit -q -m "$1"; }
# new_repo [alpha version] — W: a clone of a bare origin whose main holds plugins alpha (default 2.9.0) and beta (1.0.0), on branch feat
new_repo() {
  local d; d=$(fresh); O="$d/origin.git"
  git_ init -q --bare -b main "$O"; git_ clone -q "$O" "$d/w" 2>/dev/null; W="$d/w"
  setv alpha "\"${1:-2.9.0}\""; setv beta '"1.0.0"'
  echo a > "$W/plugins/alpha/a.txt"; echo b > "$W/plugins/beta/b.txt"; echo r > "$W/README.md"
  gw add -A; gw commit -q -m base; gw branch -M main; gw push -q -u origin main; gw checkout -q -b feat
}
pv() { OUT=$(cd "$W" && env -u GITHUB_ACTIONS -u GITHUB_BASE_REF python3 "$PV" check --repo "$W" "$@" 2>&1); RC=$?; }
# expect <tag> <rc> <what> — the last pv run
expect() { eq "$RC" "$2" "[$1] $3: rc $2"; }

fam_real() { PV=$1
  # the public export has one commit of its own, no origin, and carries released versions: a private-repo change has no meaning there
  if [ "$(tree_shape "$SRC_ROOT")" = export ]; then echo "  (not counted: the public export has no base to compare, [R1] judges a change of the private repo)"; return; fi
  # the CI environment is kept: GITHUB_BASE_REF picks the PR's base, and GITHUB_ACTIONS makes a check that cannot run red;
  # --public is the repository the export publishes to (export-public.sh's default): only a fold reads its tags
  local pub; pub=$(sed -n 's/^REPOSITORY=\([^ ]*\).*/\1/p' "$SRC_ROOT/scripts/export-public.sh")
  OUT=$(cd "$SRC_ROOT" && python3 "$PV" check --repo "$SRC_ROOT" --public "${pub:?export-public.sh names no REPOSITORY}" 2>&1); RC=$?
  printf '%s\n' "$OUT" | sed 's/^/  /'
  case "$RC" in
    0) ok "[R1] the real change passes the version check of its kind";;
    # a safety net: release.py already turns "not run" into rc 1 under GITHUB_ACTIONS
    3) if [ -n "${GITHUB_ACTIONS:-}" ]; then bad "[R1] the version check did not run in CI"; else echo "  (not counted: no base here)"; fi;;
    *) bad "[R1] the real change fails the version check (rc $RC; the reason is printed above)";;
  esac
}

fam_scratch() { PV=$1
  new_repo; pv
  has "$OUT" "kind: bootstrap" "[S0] a base with no .changes/ is the bootstrap kind"
  expect S1 0 "no change"
  echo a2 >> "$W/plugins/alpha/a.txt"; cm "alpha changes"; pv
  expect S2 1 "alpha changed, version unchanged"
  has "$OUT" "plugin alpha changed but its version 2.9.0 is not above 2.9.0" "[S2b] …the message names the plugin and both versions"
  hasnt "$OUT" "plugin beta" "[S2c] …and not the plugin that did not change"
  setv alpha '"2.9.1"'; cm "bump"; pv
  expect S3 0 "alpha changed, patch raised"
  setv alpha '"2.10.0"'; cm "bump more"; pv
  expect S4 0 "2.9.0 -> 2.10.0 (a number, not a string: '2.10.0' sorts below '2.9.0' as text)"
  new_repo 2.10.0; setv alpha '"2.9.0"'; echo a2 >> "$W/plugins/alpha/a.txt"; cm "lower"; pv
  expect S5 1 "2.10.0 -> 2.9.0 (lower as a number, higher as a string)"
  new_repo; setv alpha '"2.8.0"'; echo a2 >> "$W/plugins/alpha/a.txt"; cm "lower"; pv
  expect S6 1 "2.9.0 -> 2.8.0"
  new_repo; setv alpha '"2.9.0", "description": "only a description"'; cm "manifest only"; pv
  expect S7 1 "only the manifest changed and the version stayed"
  new_repo; setv gamma '"0.1.0"'; echo g > "$W/plugins/gamma/g.txt"; cm "a new plugin"; pv
  expect S8 0 "a plugin that is not on origin/main"
  has "$OUT" "plugin gamma: new on origin/main" "[S8b] …and it says so"
  new_repo; setv alpha '"2.9.1"'; echo a2 >> "$W/plugins/alpha/a.txt"; echo b2 >> "$W/plugins/beta/b.txt"; cm "two plugins"; pv
  expect S9 1 "alpha raised, beta changed and not raised"
  has "$OUT" "plugin beta changed but its version 1.0.0" "[S9b] …only beta is named"
  hasnt "$OUT" "red: plugin alpha" "[S9c] …alpha is not"
  new_repo; echo r2 >> "$W/README.md"; mkdir -p "$W/kb"; echo k > "$W/kb/k.md"; echo p > "$W/plugins/README.md"; cm "outside"; pv
  expect S10 0 "a change outside plugins/<name>/ (and a file directly under plugins/)"
  new_repo; echo a2 >> "$W/plugins/alpha/a.txt"; setv alpha '"2.9.1"'; cm "the branch bumps"
  # main moves on to the number the branch took
  ( d=$(fresh); git_ clone -q "$O" "$d/m" 2>/dev/null; cd "$d/m" && printf '{"name": "alpha", "version": "2.9.1"}\n' > plugins/alpha/.claude-plugin/plugin.json \
    && echo m >> plugins/alpha/a.txt && git_ add -A && git_ commit -q -m "main takes 2.9.1" && git_ push -q origin HEAD:main ); gw fetch -q origin; pv
  expect S11 1 "main reached the number the branch took (compared with the tip, not the merge-base)"
  new_repo; echo a2 >> "$W/plugins/alpha/a.txt"; pv
  expect S12 1 "an uncommitted edit in a plugin"
  new_repo; echo n > "$W/plugins/alpha/new.txt"; pv
  expect S13 1 "an untracked file in a plugin"
  new_repo; echo a2 >> "$W/plugins/alpha/a.txt"; gw add -A; pv
  expect S14 1 "a staged edit in a plugin"
  new_repo; echo "n" > "$W/plugins/alpha/with space and
newline.txt"; cm "odd name"; pv
  expect S15 1 "a file name with a space and a newline"
  local v
  for v in '"abc"' '"2.9"' '"2.9.1-rc1"' '"02.9.1"' '"2.9.1\n"' '3' 'null' '["2.9.1"]' '"٣.9.1"'; do
    new_repo; echo a2 >> "$W/plugins/alpha/a.txt"; setv alpha "$v"; cm "odd version"; pv
    expect S16 1 "alpha version $v is not X.Y.Z"
  done
  new_repo; echo a2 >> "$W/plugins/alpha/a.txt"; printf '{"name": "alpha"}\n' > "$W/plugins/alpha/.claude-plugin/plugin.json"; cm "no version"; pv
  expect S17 1 "a manifest with no version"
  new_repo; echo a2 >> "$W/plugins/alpha/a.txt"; printf 'not json' > "$W/plugins/alpha/.claude-plugin/plugin.json"; cm "broken"; pv
  expect S18 1 "a manifest that is not JSON"
  new_repo; echo a2 >> "$W/plugins/alpha/a.txt"; mkdir -p "$W/plugins/beta/.claude-plugin"; printf '{"name": "beta", "version": "9.9.9"}\n' > "$W/plugins/beta/.claude-plugin/plugin.json"
  rm "$W/plugins/alpha/.claude-plugin/plugin.json"; ln -s ../../beta/.claude-plugin/plugin.json "$W/plugins/alpha/.claude-plugin/plugin.json"; cm "alpha borrows beta's version"; pv
  expect S19 1 "the manifest is a symlink to another plugin's higher version"
  new_repo; gw rm -q -r plugins/beta; gw commit -q -m "remove beta"; pv
  expect S20 0 "a plugin removed whole"
  new_repo; gw rm -q plugins/beta/.claude-plugin/plugin.json; echo b2 >> "$W/plugins/beta/b.txt"; cm "beta loses its manifest"; pv
  expect S21 1 "a manifest removed while the plugin keeps files"
  # the base: not there, shares no history, named and unknown
  new_repo; echo a2 >> "$W/plugins/alpha/a.txt"; cm "change"; gw remote remove origin; pv
  expect S22 3 "no origin/main: the check did not run (rc 3, not green)"
  has "$OUT" "version check not run" "[S22b] …and it says so"
  OUT=$(cd "$W" && GITHUB_ACTIONS=true python3 "$PV" check --repo "$W" 2>&1); RC=$?
  expect S23 1 "the same under GITHUB_ACTIONS: a check that did not run must not pass a PR"
  new_repo; echo a2 >> "$W/plugins/alpha/a.txt"; cm "change"; pv --base no-such-ref
  expect S24 1 "a named base ref that does not resolve"
  new_repo; echo a2 >> "$W/plugins/alpha/a.txt"; cm "change"; gw checkout -q --orphan lone; cm "unrelated history"; pv
  expect S25 3 "HEAD shares no history with origin/main (a shallow clone)"
  new_repo; echo a2 >> "$W/plugins/alpha/a.txt"; cm "change"; gw branch -f base1 main; pv --base base1
  expect S26 1 "a base ref given on the command line is the one compared with"
  # a submodule bump the repository's own .gitmodules says to ignore is still a change under the plugin
  local sub; new_repo; sub=$(fresh)/sub; git_ init -q -b main "$sub"
  ( cd "$sub" && echo 1 > f && git_ add f && git_ commit -q -m one && echo 2 >> f && git_ commit -q -a -m two )
  gw -c protocol.file.allow=always submodule add -q "$sub" plugins/alpha/vendor >/dev/null 2>&1
  ( cd "$W/plugins/alpha/vendor" && git_ checkout -q HEAD~1 ); cm "a submodule inside alpha"; gw push -q origin feat:main; gw fetch -q origin
  gw config -f .gitmodules submodule.plugins/alpha/vendor.ignore all; cm "ignore = all"
  ( cd "$W/plugins/alpha/vendor" && git_ checkout -q main ); gw add plugins/alpha/vendor; gw commit -q -m "bump the submodule only"; pv
  expect S28 1 "only a submodule pointer under the plugin moved, .gitmodules says ignore = all"
  # a plugin directory whose name is not UTF-8 is named, and checked
  new_repo; local nm; nm=$(printf 'g\377g')
  mkdir -p "$W/plugins/$nm/.claude-plugin"; printf '{"name": "g", "version": "1.0.0"}\n' > "$W/plugins/$nm/.claude-plugin/plugin.json"; echo x > "$W/plugins/$nm/x.txt"
  gw add -A; gw commit -q -m "odd plugin"; gw push -q origin feat:main; gw fetch -q origin; echo y >> "$W/plugins/$nm/x.txt"; cm "edit it"; pv
  expect S29 1 "a plugin directory with a non-UTF-8 name changed, version unchanged"
  eq "$(cd "$W" && python3 "$PV" 2>/dev/null; echo $?)" 64 "[S27] no subcommand: usage, rc 64"
  eq "$(cd "$W" && python3 "$PV" check --bogus 2>/dev/null; echo $?)" 64 "[S27b] an unknown option: usage, rc 64"
}

# ── the ordinary kind ──────────────────────────────────────────────────────────────────────────────────────
# new_repo_o — new_repo plus what a base after the bootstrap and the version reset has: manifests with no version, CHANGELOGs
# (alpha released 2.9.0, beta 1.0.0), .changes/README.md, a marketplace, a current-state whose old version lines nothing reads
new_repo_o() {
  new_repo
  gw checkout -q main
  setm alpha; setm beta; setcl alpha 2.9.0; setcl beta 1.0.0
  mkdir -p "$W/.changes" "$W/.claude-plugin" "$W/kb"; echo "# change files" > "$W/.changes/README.md"
  printf '{"name": "m", "plugins": [{"name": "alpha", "source": "./plugins/alpha"}, {"name": "beta", "source": "./plugins/beta"}]}\n' > "$W/.claude-plugin/marketplace.json"
  printf '# state\n\n- `plugins/alpha/` needs `beta >=1.0.0`, version 2.9.0; skills.\n- Plugin at `plugins/beta/`, version 1.0.0.\n' > "$W/kb/current-state.md"
  cfw pend.md beta patch "a pending fix of beta"
  gw add -A; gw commit -q -m "after the bootstrap"; gw push -q origin main; gw checkout -q feat; gw merge -q --ff-only main
}
# cfw <file> <plugins> <level> <line> — write .changes/<file>
cfw() { mkdir -p "$W/.changes"; printf -- '---\nplugins: %s\nlevel: %s\n---\n%s\n' "$2" "$3" "$4" > "$W/.changes/$1"; }
# cfwu <file> <plugins> <level> <line> <upgrade> — the same with the optional upgrade line
cfwu() { mkdir -p "$W/.changes"; printf -- '---\nplugins: %s\nlevel: %s\nupgrade: %s\n---\n%s\n' "$2" "$3" "$5" "$4" > "$W/.changes/$1"; }

fam_ordinary() { PV=$1
  new_repo_o; pv
  expect O1 0 "an ordinary base, no change"
  has "$OUT" "kind: ordinary" "[O1b] …the kind is ordinary"
  echo a2 >> "$W/plugins/alpha/a.txt"; cm "alpha changes"; pv
  expect O2 1 "alpha changed and no change file"
  has "$OUT" "plugin alpha changed and no change file added by this change names it" "[O2b] …the message names alpha"
  cfw a.md alpha minor "alpha does more"; cm "change file"; pv
  expect O3 0 "alpha changed with an added change file naming it"
  has "$OUT" "change file .changes/a.md: alpha, minor: alpha does more" "[O3b] …and prints what it read"
  new_repo_o; echo a2 >> "$W/plugins/alpha/a.txt"; cfw a.md beta minor "names beta only"; cm "wrong plugin"; pv
  expect O4 1 "alpha changed, the change file names beta only"
  new_repo_o; echo a2 >> "$W/plugins/alpha/a.txt"; echo b2 >> "$W/plugins/beta/b.txt"; cfw a.md "alpha, beta" patch "both"; cm "two"; pv
  expect O5 0 "two plugins changed, one change file naming both"
  new_repo_o; echo a2 >> "$W/plugins/alpha/a.txt"; cfw a.md alpha minor "x"; rel_bump alpha 2.9.0 2.10.0; cm "a bump"; pv
  expect O6 1 "a released version raised in an ordinary PR, even with a change file"
  has "$OUT" "kind: release" "[O6b] …it is read as a release, which it is not: it ships no pending change file"
  local spec
  for spec in 'nofront|plugins: alpha' 'level|---\nplugins: alpha\nlevel: huge\n---\nx' 'unknown|---\nplugins: alpha, zeta\nlevel: patch\n---\nx' \
              'twolines|---\nplugins: alpha\nlevel: patch\n---\nx\ny' 'nobody|---\nplugins: alpha\nlevel: patch\n---\n' \
              'extrakey|---\nplugins: alpha\nlevel: patch\nnote: n\n---\nx' 'nolevel|---\nplugins: alpha\n---\nx' \
              'emptyname|---\nplugins: alpha,\nlevel: patch\n---\nx' 'unclosed|---\nplugins: alpha\nlevel: patch\nx'; do
    new_repo_o; echo a2 >> "$W/plugins/alpha/a.txt"; printf -- "${spec#*|}\n" > "$W/.changes/a.md"; cm "malformed"; pv
    expect "O7 ${spec%%|*}" 1 "a malformed change file (${spec%%|*})"
  done
  new_repo_o; echo a2 >> "$W/plugins/alpha/a.txt"; mkdir -p "$W/.changes/sub"; printf -- '---\nplugins: alpha\nlevel: patch\n---\nx\n' > "$W/.changes/sub/a.md"; cm "subdir"; pv
  expect "O7 subdir" 1 "a change file in a subdirectory of .changes/"
  new_repo_o; echo a2 >> "$W/plugins/alpha/a.txt"; cfw Upper.md alpha patch x; cm "name"; pv
  expect "O7 name" 1 "a change file name outside a-z0-9 . _ -"
  new_repo_o; echo a2 >> "$W/plugins/alpha/a.txt"; cfw a.md alpha patch x; cfw pend.md beta minor "rewritten"; cm "edit pending"; pv
  expect O8a 1 "a pending change file of the base edited"
  new_repo_o; echo a2 >> "$W/plugins/alpha/a.txt"; cfw a.md alpha patch x; gw rm -q .changes/pend.md; cm "drop pending"; pv
  expect O8b 1 "a pending change file of the base deleted"
  new_repo_o; echo a2 >> "$W/plugins/alpha/a.txt"; cfw a.md alpha patch x; cfwu pend.md beta patch "a pending fix of beta" "Run beta once."; cm "upgrade line"; pv
  expect O8c 0 "a pending change file of the base gains only an upgrade line"
  has "$OUT" "its upgrade line now: Run beta once." "[O8c] …and check names it"
  new_repo_o; echo a2 >> "$W/plugins/alpha/a.txt"; cfw a.md alpha patch x; cfwu pend.md beta patch "a pending fix, reworded" "Run beta once."; cm "upgrade and body"; pv
  expect O8d 1 "an upgrade line added with a changed body"
  new_repo_o; echo a2 >> "$W/plugins/alpha/a.txt"; cfw a.md alpha patch x; cfwu pend.md beta minor "a pending fix of beta" "Run beta once."; cm "upgrade and level"; pv
  expect O8e 1 "an upgrade line added with a changed level"
  new_repo_o; echo a2 >> "$W/plugins/alpha/a.txt"; cfwu a.md alpha patch x "Restart once."; cm "new file with upgrade"; pv
  expect O8f 0 "a new change file with an upgrade line"
  new_repo_o; echo a2 >> "$W/plugins/alpha/a.txt"; cfwu a.md alpha patch x ""; cm "empty upgrade"; pv
  expect O8g 1 "an empty upgrade line"
  new_repo_o; echo a2 >> "$W/plugins/alpha/a.txt"; mkdir -p "$W/.changes"; printf -- '---\nplugins: alpha\nlevel: patch\nnote: y\n---\nx\n' > "$W/.changes/a.md"; cm "unknown key"; pv
  expect O8h 1 "another unknown frontmatter key"
  new_repo_o; echo a2 >> "$W/plugins/alpha/a.txt"; cfw a.md alpha patch x; setm alpha ', "version": "2.9.0"'; cm "a version key"; pv
  expect O9 1 "a manifest that carries a version, with a change file"
  has "$OUT" "plugins/alpha/.claude-plugin/plugin.json carries a version" "[O9b] …names the manifest"
  new_repo_o; setm beta ', "version": "1.0.0"'; cfw b.md beta patch x; cm "a version key on beta"; pv
  expect O9c 1 "a version key added to the manifest of a plugin with no other change"
  new_repo_o; setm beta ', "dependencies": [{"name": "alpha", "version": ">=2.8.0"}]'; cfw b.md beta patch x; cm "a dependency range"; pv
  expect O9f 1 "a dependency range in a manifest (it fails to load against a commit-keyed version)"
  new_repo_o; setcl alpha -; cfw a.md alpha patch x; cm "unrelease"; pv
  expect O9d 1 "an ordinary PR that drops the released version (the CHANGELOG's first heading)"
  has "$OUT" "only a release PR moves the first" "[O9e] …and says only a release moves it"
  # the reset: a base whose manifests still carry a version; the PR retires them and the CHANGELOGs lose their released version
  new_repo_o; gw checkout -q main; setv alpha '"2.9.0"'; setv beta '"1.0.0"'; cm "pre-reset base"; gw push -q origin main
  gw checkout -q feat; gw merge -q --ff-only main
  setm alpha; setm beta; setcl alpha -; setcl beta -; cfw r.md "alpha, beta" minor "no version in private"; cm "the reset"; pv
  expect O10 0 "the PR that retires the versions of a pre-reset base and resets the CHANGELOGs"
  has "$OUT" "this PR retires them" "[O10b] …says so"
  new_repo_o; gw checkout -q main; setv alpha '"2.9.0"'; setv beta '"1.0.0"'; cm "pre-reset base"; gw push -q origin main
  gw checkout -q feat; gw merge -q --ff-only main; setm alpha; setcl alpha -; setcl beta -; cfw r.md "alpha, beta" minor "x"; cm "half reset"; pv
  expect O10c 1 "a reset that leaves a version in one manifest"
  new_repo_o; setm gamma; cfw g.md gamma minor "a new plugin"; mp_py 'd["plugins"].append({"name": "gamma", "source": "./plugins/gamma", "version": "0.1.0"})'
  cm "marketplace version"; pv
  expect O11 1 "a version key in an appended marketplace entry (only the version-key check sees it)"
  new_repo_o; python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["description"]="d"; json.dump(d,open(p,"w"))' "$W/.claude-plugin/marketplace.json"; cm "marketplace text"; pv
  expect O11b 0 "a marketplace edit that moves no version"
  new_repo_o; echo r2 >> "$W/README.md"; echo more >> "$W/.changes/README.md"; cm "outside"; pv
  expect O12 0 "a change outside plugins/ (and .changes/README.md) needs no change file"
  new_repo_o; echo a2 >> "$W/plugins/alpha/a.txt"; cfw a.md alpha patch x; pv
  expect O14 0 "an uncommitted edit and an untracked change file naming it"
  new_repo_o; setm gamma; setcl gamma 0.4.0; echo g > "$W/plugins/gamma/g.txt"; mp_add gamma ./plugins/gamma; cfw g.md gamma minor "x"; cm "gamma"; pv
  expect O16c 1 "a new plugin that arrives with a released version (a release heading in its CHANGELOG)"
  hasnt "$OUT" "kind: release" "[O16d] …is not read as a release"
  new_repo_o; setm gamma; echo g > "$W/plugins/gamma/g.txt"; mp_add gamma ./plugins/gamma; cm "gamma"; pv
  expect O16a 1 "a new plugin without a change file"
  cfw g.md gamma minor "a new plugin"; cm "gamma change"; pv
  expect O16b 0 "a new plugin with a change file naming it (a plugins/<name>/ with a manifest is a plugin)"
  new_repo_o; echo a2 >> "$W/plugins/alpha/a.txt"; cfw a.md alpha patch x; rm "$W/plugins/alpha/.claude-plugin/plugin.json"
  ln -s ../../beta/.claude-plugin/plugin.json "$W/plugins/alpha/.claude-plugin/plugin.json"; cm "symlink"; pv
  expect O17 1 "a manifest that is a symlink"
  # GITHUB_BASE_REF names the base: a branch `rel` without .changes/ makes it the bootstrap kind
  new_repo_o; gw push -q origin "$(gw rev-list --max-parents=0 HEAD):refs/heads/rel"; gw fetch -q origin
  OUT=$(cd "$W" && env -u GITHUB_ACTIONS GITHUB_BASE_REF=rel python3 "$PV" check --repo "$W" 2>&1); RC=$?
  has "$OUT" "kind: bootstrap (the history of origin/rel never held .changes/README.md)" "[O15] GITHUB_BASE_REF=rel compares with origin/rel"
  # the bootstrap does not come back: README deleted by a PR is red, and a base that lost it is still the ordinary kind
  new_repo_o; gw rm -q .changes/README.md; cm "drop the README"; pv
  expect O18 1 "an ordinary PR deletes .changes/README.md"
  new_repo_o; gw checkout -q main; gw rm -q -r .changes; cm ".changes/ gone on main"; gw push -q origin main; gw checkout -q feat; gw merge -q main
  rel_bump alpha 2.9.0 2.10.0; cm "bump"; pv
  expect O19 1 "a base whose history held .changes/README.md stays the ordinary kind after .changes/ is gone"
  hasnt "$OUT" "kind: bootstrap" "[O19b] …and is not the bootstrap kind"
  # the marketplace may not ship another directory under an existing name
  new_repo_o; mp_set_source alpha ./plugins/beta; cm "redirect"; pv
  expect O20a 1 "a marketplace entry's source moved to another plugin's directory (no file under plugins/ changes)"
  new_repo_o; python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["plugins"]=d["plugins"][:1]; json.dump(d,open(p,"w"))' "$W/.claude-plugin/marketplace.json"; cm "drop beta"; pv
  expect O20b 1 "a marketplace entry removed"
  # nothing under plugins/ is a symlink or a submodule
  new_repo_o; mkdir -p "$W/vendor"; gw mv plugins/alpha vendor/alpha; ln -s ../vendor/alpha "$W/plugins/alpha"; cfw a.md alpha patch x; cm "symlinked plugin"; pv
  expect O21a 1 "a plugin directory that is a symlink"
  local sub; new_repo_o; sub=$(fresh)/sub; git_ init -q -b main "$sub"; ( cd "$sub" && echo 1 > f && git_ add f && git_ commit -q -m one )
  gw -c protocol.file.allow=always submodule add -q "$sub" plugins/gamma >/dev/null 2>&1; cfw a.md alpha patch x; cm "a submodule plugin"; pv
  expect O21b 1 "a submodule under plugins/"
  # a change file is a regular file
  new_repo_o; echo a2 >> "$W/plugins/alpha/a.txt"; mkdir -p "$W/notes"; printf -- '---\nplugins: alpha\nlevel: major\n---\nx\n' > "$W/notes/n.txt"
  ln -s ../notes/n.txt "$W/.changes/a.md"; cm "symlinked change file"; pv
  expect O22 1 "a change file that is a symlink"
  # kb pages hold no version any more: a number on a current-state line is not read
  new_repo_o; sed -i.bak 's/version 2.9.0/version 7.0.0/' "$W/kb/current-state.md"; rm -f "$W/kb/current-state.md.bak"; cm "state"; pv
  expect O23 0 "a version number on a kb/current-state.md line is not compared (the kb holds no version)"
  # change files name marketplace entries when there is a marketplace
  new_repo_o; cp -R "$W/plugins/alpha" "$W/plugins/alpha-next"; rm "$W/plugins/alpha-next/CHANGELOG.md"; setm alpha-next; echo a2 >> "$W/plugins/alpha/a.txt"; cfw a.md "alpha, alpha-next" patch x; cm "not listed"; pv
  expect O24 1 "a change file naming a plugin directory the marketplace does not list"
  # the marketplace: only descriptions and appended entries change in an ordinary PR
  new_repo_o; mp_py 'd["plugins"].append({"name": "beta", "source": "./plugins/alpha"})'; cm "duplicate appended"; pv
  expect O25 1 "a duplicate entry name appended (the merge-base's entries untouched)"
  new_repo_o; mp_py 'd["plugins"].insert(0, {"name": "beta", "source": "./plugins/alpha"})'; cm "duplicate first"; pv
  expect O25b 1 "an entry inserted before the merge-base's entries"
  new_repo_o; mp_py 'd["metadata"] = {"pluginRoot": "./evil"}'; cm "metadata"; pv
  expect O26 1 "a top-level marketplace key other than plugins and description"
  new_repo_o; mp_py 'd["description"] = "new words"; d["plugins"][0]["description"] = "alpha in new words"'; cm "words"; pv
  expect O27 0 "descriptions reworded, top level and entry"
  new_repo_o; mp_py 'd["plugins"].reverse()'; cm "reorder"; pv
  expect O28 1 "the entries reordered"
  new_repo_o; mp_py 'd["plugins"][0]["source"] = {"source": "./plugins/alpha", "ref": "x"}'; cm "ref"; pv
  expect O29 1 "an entry's source gains a ref"
  new_repo_o; gw rm -q .changes/README.md; ln -s ../README.md "$W/.changes/README.md"; cm "README symlink"; pv
  expect O30 1 ".changes/README.md replaced by a symlink"
  new_repo_o; mp_py 'd["plugins"][0]["hooks"] = {"description": "x"}'; gw add -A; gw commit -q -m "base hooks"; gw push -q origin feat:main; gw fetch -q origin
  mp_py 'd["plugins"][0]["hooks"]["description"] = {"command": "other"}'; cm "a change hidden under a description key"; pv
  expect O31 1 "a description key whose value is not text changes"
  new_repo_o; mp_py 'd["plugins"] += [{"name": ["g"], "source": "./plugins/g"}, {"name": ["g"], "source": "./plugins/h"}]'; cm "odd names"; pv
  expect O32 1 "a duplicated name that is not a string: red"
  hasnt "$OUT" "Traceback" "[O32b] …a red line, not a traceback"
}

# ── the ordinary kind: a plugin removed whole ──────────────────────────────────────────────────────────
# new_repo_x — new_repo_o plus plugin kit-gamma (released 0.3.0, last in the marketplace) and three pending change files on main:
# gonly.md names kit-gamma alone, mix.md alpha and kit-gamma, al.md alpha alone
new_repo_x() {
  new_repo_o
  gw checkout -q main
  setm kit-gamma; setcl kit-gamma 0.3.0; echo g > "$W/plugins/kit-gamma/g.txt"; mp_add kit-gamma ./plugins/kit-gamma
  cfw gonly.md kit-gamma patch "kit-gamma alone"; cfw mix.md "alpha, kit-gamma" minor "alpha and kit-gamma do more"
  cfw al.md alpha patch "alpha alone"
  gw add -A; gw commit -q -m "kit-gamma"; gw push -q origin main; gw checkout -q feat; gw merge -q --ff-only main
}
# rm_x [keep] — remove kit-gamma: every file of plugins/kit-gamma/ (but kit-gamma/<keep> when named) and its marketplace entry
rm_x() {
  gw rm -q -r plugins/kit-gamma; [ -z "${1:-}" ] || { mkdir -p "$W/plugins/kit-gamma"; echo k > "$W/plugins/kit-gamma/$1"; }
  mp_py 'd["plugins"] = [e for e in d["plugins"] if e["name"] != "kit-gamma"]'
}
# rm_xn [keep] — rm_x, and both of kit-gamma's notes handled (gonly.md deleted, mix.md down to alpha): each case below changes one thing
rm_xn() { rm_x "${1:-}"; gw rm -q .changes/gonly.md; cfw mix.md alpha minor "alpha does more"; }
fam_removal() { PV=$1
  new_repo_x; rm_x; gw rm -q .changes/gonly.md; cfw mix.md alpha minor "alpha does more"; cm "kit-gamma removed whole"; pv
  expect X1 0 "a plugin removed whole: its entry, its files, the note naming it alone, its name and words out of a mixed note"
  has "$OUT" "plugin kit-gamma: removed whole" "[X1b] …and it says so"
  new_repo_x; rm_x; cm "removed, notes untouched"; pv
  expect X2 1 "a plugin removed whole with its pending notes left as they were (no later PR could clear them)"
  has "$OUT" ".changes/gonly.md still names the removed plugin kit-gamma" "[X2b] …and names each note left"
  has "$OUT" ".changes/mix.md still names the removed plugin kit-gamma" "[X2c] …the mixed one too"
  new_repo_x; rm_xn; cfw mix.md alpha minor "alpha and Gamma do more"; cm "short name left"; pv
  expect X3 1 "a mixed note's new body names the removed plugin by the part after its first -"
  has "$OUT" ".changes/mix.md: the body still names the removed plugin kit-gamma" "[X3b] …and says which"
  new_repo_x; rm_xn; cfw mix.md alpha minor "alpha and KIT-GAMMA do more"; cm "full name left"; pv
  expect X4 1 "a mixed note's new body names the removed plugin in other case"
  new_repo_x; rm_xn; cfw mix.md alpha patch "alpha does more"; cm "level moved"; pv
  expect X5 1 "a mixed note whose level changes"
  new_repo_x; rm_xn; cfw mix.md "alpha, beta" minor "alpha does more"; cm "a name added"; pv
  expect X6 1 "a mixed note that gains a name"
  new_repo_x; rm_xn; cfw mix.md "kit-gamma, alpha" minor "alpha does more"; cm "reordered"; pv
  expect X6b 1 "a mixed note that keeps the removed name"
  new_repo_x; rm_xn; gw rm -q .changes/al.md; cm "a note of a staying plugin deleted"; pv
  expect X7 1 "a deleted note that names only a staying plugin"
  new_repo_x; rm_x; gw rm -q .changes/gonly.md .changes/mix.md; cm "a mixed note deleted"; pv
  expect X8 1 "a deleted note that also names a staying plugin"
  new_repo_x; rm_xn; cfw al.md alpha patch "alpha alone, reworded"; cm "a staying note edited"; pv
  expect X9 1 "an edited note that loses no removed name"
  new_repo_x; rm_xn keep.txt; cm "a file left"; pv
  expect X10 1 "an entry removed while plugins/kit-gamma/ still holds a file"
  new_repo_x; gw rm -q -r plugins/kit-gamma; cm "directory gone, entry kept"; pv
  expect X11 1 "the files removed while the marketplace still lists the plugin"
  new_repo_x; rm_x; gw rm -q .changes/gonly.md; cfw mix.md alpha minor "alpha does more"; printf -- '---\nplugins: alpha\nlevel: minor\n---\nx\ny\n' > "$W/.changes/mix.md"; cm "malformed"; pv
  expect X12 1 "an edited mixed note that is malformed"
  new_repo_x; rm_x; gw rm -q .changes/gonly.md; cfw mix.md alpha minor "alpha and gammaray do more"; cm "a word that holds the name"; pv
  expect X13 0 "a body word that only holds the removed name (gammaray) does not name it"
  new_repo_x; base_x 'd["plugins"].append({"name": "ext", "source": {"source": "github", "repo": "o/r"}})' ext.md
  mp_py 'd["plugins"] = [e for e in d["plugins"] if e["name"] != "ext"]'; gw rm -q .changes/ext.md; cm "drop ext"; pv
  expect X14 1 "an entry whose source is not in this tree is never removed whole"
  new_repo_x; base_x 'd["plugins"].append({"name": "kg", "source": "./plugins/kit-gamma"})' kg.md
  mp_py 'd["plugins"] = [e for e in d["plugins"] if e["name"] != "kg"]'; gw rm -q .changes/kg.md; cm "drop kg"; pv
  expect X14b 1 "an entry whose source is another directory (plugins/kg holds nothing, plugins/kit-gamma does) is not removed whole"
  new_repo_x; rm_x; gw rm -q .changes/gonly.md; cfw mix.md alpha minor "alpha does more"; printf '__pycache__/\n' > "$W/.gitignore"
  cm "removed, ignored cache left"; mkdir -p "$W/plugins/kit-gamma/__pycache__"; echo c > "$W/plugins/kit-gamma/__pycache__/g.pyc"; pv
  expect X15 0 "an ignored file left on disk under the removed directory (CI's checkout has none)"
  new_repo_x; rm_x; gw rm -q .changes/gonly.md; cfw mix.md alpha minor "alpha does more"; rmdir "$W/plugins/kit-gamma" 2>/dev/null
  echo f > "$W/plugins/kit-gamma"; cm "a file where the directory was"; pv
  expect X16 1 "a file at plugins/kit-gamma is not a removal"
  new_repo_x; base_x 'd["plugins"].append({"name": ["odd"], "source": "./plugins/odd"})' -
  rm_x; gw rm -q .changes/gonly.md; cfw mix.md alpha minor "alpha does more"; cm "removed, odd name on the base"; pv
  hasnt "$OUT" "Traceback" "[X17] a base entry whose name is not text: a verdict, not a traceback"
}
# base_x <python on d> <note file|-> — on main: edit the marketplace (and add a pending note naming the new entry), then merge into feat
base_x() {
  gw checkout -q main; mp_py "$1"
  [ "$2" = - ] || cfw "$2" "${2%.md}" patch "a note of ${2%.md}"
  gw add -A; gw commit -q -m "base edit"; gw push -q origin main; gw checkout -q feat; gw merge -q --ff-only main
}
# mp_py <python on d> — edit the marketplace of W in place
mp_py() { python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); exec(sys.argv[2]); json.dump(d,open(p,"w"))' "$W/.claude-plugin/marketplace.json" "$1"; }
# mp_add <name> <source> / mp_set_source <name> <source> — edit the marketplace of W
mp_add() { python3 -c 'import json,sys; p,n,s=sys.argv[1:]; d=json.load(open(p)); d["plugins"].append({"name": n, "source": s}); json.dump(d,open(p,"w"))' "$W/.claude-plugin/marketplace.json" "$1" "$2"; }
mp_set_source() { python3 -c 'import json,sys; p,n,s=sys.argv[1:]; d=json.load(open(p)); [e.update(source=s) for e in d["plugins"] if e["name"]==n]; json.dump(d,open(p,"w"))' "$W/.claude-plugin/marketplace.json" "$1" "$2"; }

# ── the release, hotfix and back-merge kinds (row B) ───────────────────────────────────────────────────
# new_repo_r — new_repo_o plus: plugin gamma 0.3.0 (named by no change file) and plugins/alpha/CONTRACT.md on main, origin/release at
# that commit, then a feature merged into main (alpha minor, pending); W on feat at main's tip
new_repo_r() {
  new_repo_o; gw checkout -q main
  setm gamma; setcl gamma 0.3.0; echo g > "$W/plugins/gamma/g.txt"; mp_add gamma ./plugins/gamma
  printf 'Frozen at: 2.9.0\n<!-- surface:begin -->\nx\n<!-- surface:end -->\n' > "$W/plugins/alpha/CONTRACT.md"
  cm "gamma and a contract"; gw push -q origin main; gw push -q origin main:release
  echo a3 >> "$W/plugins/alpha/a.txt"; cfw feat1.md alpha minor "alpha does more"; cm "a feature"; gw push -q origin main
  gw fetch -q origin; gw checkout -q feat; gw merge -q --ff-only main
}
cut_() { ( cd "$W" && env -u GITHUB_ACTIONS -u GITHUB_BASE_REF python3 "$PV" cut "$@" ) >/dev/null 2>&1; }
# vof <plugin> — its released version: the first `## ` heading of its CHANGELOG when that is a version, else "unreleased"
vof() { python3 -c 'import re,sys
h=[l[3:].strip() for l in open(sys.argv[1]).read().split("\n") if l.startswith("## ")]
print(h[0] if h and re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", h[0]) else "unreleased")' "$W/plugins/$1/CHANGELOG.md"; }
# rel_bump <plugin> <from> <to> — move a plugin's released version (its CHANGELOG heading)
rel_bump() {
  sed -i.bak "s/^## $2\$/## $3/" "$W/plugins/$1/CHANGELOG.md"; rm -f "$W/plugins/$1/CHANGELOG.md.bak"
}

fam_release() { PV=$1
  new_repo_r; cut_; cm "release"; pv
  expect R1 0 "a release cut from main: every pending change file shipped, one step each, CHANGELOGs written"
  has "$OUT" "kind: release" "[R1b] …the kind is release"
  eq "$(vof alpha) $(vof beta) $(vof gamma)" "2.10.0 1.0.1 0.3.0" "[R1c] alpha one minor, beta one patch, gamma (not named) unchanged"
  eq "$(gw diff --name-only origin/main HEAD -- kb)" "" "[R1d] the cut writes no kb page (kb/current-state.md keeps its old line)"
  eq "$(gw diff --name-only origin/main HEAD -- 'plugins/*/.claude-plugin/plugin.json')" "" "[R1e] the cut writes no manifest"
  new_repo_r; cut_; gw checkout -q main -- .changes/pend.md; cm "release"; pv
  expect R2 1 "a pending change file of main left in .changes/"
  new_repo_r; cut_; cfw extra.md alpha patch "rides along"; cm "release"; pv
  expect R3 1 "a release that adds a change file"
  new_repo_r; cut_; rel_bump alpha 2.10.0 2.11.0; cm "release"; pv
  expect R4 1 "alpha raised two minors (state line and CHANGELOG heading moved with it)"
  new_repo_r; cut_; rel_bump alpha 2.10.0 2.9.1; cm "release"; pv
  expect R4b 1 "alpha raised a patch where its change file says minor"
  new_repo_r; cut_; rel_bump gamma 0.3.0 0.3.1; cm "release"; pv
  expect R6 1 "gamma raised, and no pending change file names it"
  new_repo_r; cut_; sed -i.bak '/alpha does more/d' "$W/plugins/alpha/CHANGELOG.md"; rm -f "$W/plugins/alpha/CHANGELOG.md.bak"; cm "release"; pv
  expect R7 1 "a shipped line missing from the CHANGELOG entry"
  new_repo_r; cut_; echo more >> "$W/plugins/alpha/a.txt"; cm "release"; pv
  expect R8 1 "a release that also changes a plugin file"
  new_repo_r; cut_; echo r2 >> "$W/README.md"; cm "release"; pv
  expect R8b 1 "a release that also changes a file outside plugins/"
  new_repo_r; cut_; cm "release"
  gw checkout -q -b hf origin/release; echo h > "$W/hf.txt"; cm "a hotfix"; gw push -q origin hf:release; gw checkout -q feat; gw fetch -q origin; pv
  expect R9 1 "origin/release holds a commit HEAD lacks"
  new_repo_r; cut_; setm alpha ', "description": "new"'; cm "release"; pv
  expect R10 1 "a release that changes a manifest"
  new_repo_r; cut_; setm alpha ', "version": "2.10.0"'; cm "release"; pv
  expect R10b 1 "a release that writes its version into a manifest"
  new_repo_r; cut_; sed -i.bak 's/version 2.9.0/version 2.10.0/' "$W/kb/current-state.md"; rm -f "$W/kb/current-state.md.bak"; cm "release"; pv
  expect R11 1 "a release that writes a version number into kb/current-state.md"
  new_repo_r; cut_; sed -i.bak 's/^Frozen at: .*/Frozen at: 2.10.0/' "$W/plugins/alpha/CONTRACT.md"; rm -f "$W/plugins/alpha/CONTRACT.md.bak"; cm "release"; pv
  expect R12a 0 "a release that moves only Frozen at"
  new_repo_r; cut_; sed -i.bak 's/^x$/y/' "$W/plugins/alpha/CONTRACT.md"; rm -f "$W/plugins/alpha/CONTRACT.md.bak"; cm "release"; pv
  expect R12b 1 "a release that changes a CONTRACT.md beyond Frozen at"
  new_repo_r; gw checkout -q main; cfw g.md gamma major "gamma breaks"; echo g2 >> "$W/plugins/gamma/g.txt"; cm "gamma breaks"; gw push -q origin main
  gw checkout -q feat; gw merge -q --ff-only main; cut_; cm "release"; pv
  expect R13 0 "a release with a major change file on a 0.x plugin"
  eq "$(vof gamma)" "0.4.0" "[R13b] …a major on 0.3.0 is the minor 0.4.0"
  new_repo_r; gw checkout -q main; mp_add ghost ./plugins/ghost; cfw gh.md ghost patch "a plugin with no directory"; cm "ghost"
  gw push -q origin main; gw checkout -q feat; gw merge -q --ff-only main; gw rm -q .changes/gh.md; cm "drop it"; cut_; cm "release"; pv
  expect R14 1 "a pending change file naming a plugin with no directory, deleted by the release"
  # the first public release: alpha never released (its CHANGELOG starts with the private history) goes to 0.1.0 at any level
  new_repo_f; cut_; cm "release"; pv
  expect R15 0 "a first release: alpha (unreleased, a minor named) to 0.1.0, beta one patch"
  eq "$(vof alpha) $(vof beta)" "0.1.0 1.0.1" "[R15b] …alpha 0.1.0, beta 1.0.1"
  eq "$(sed -n 1p "$W/plugins/alpha/CONTRACT.md")" "Frozen at: 0.1.0" "[R15c] …and the contract of a first release is frozen at 0.1.0"
  new_repo_f; cut_; rel_bump alpha 0.1.0 0.2.0; cm "release"; pv
  expect R15d 1 "a first release at 0.2.0"
}
# new_repo_f — new_repo_r where alpha was never released (main's CHANGELOG of alpha starts with the private history)
new_repo_f() {
  new_repo_r; gw checkout -q main; setcl alpha -; cm "alpha unreleased"; gw push -q origin main; gw checkout -q feat; gw merge -q --ff-only main
}

# new_repo_h — new_repo_r released (the release merged into main and promoted), W on branch hf from origin/release with a fix of
# alpha and a patch change file, cut with --hotfix and committed
new_repo_h() {
  new_repo_r; cut_; cm "release"; gw push -q origin feat:main; gw push -q origin feat:release; gw fetch -q origin
  gw checkout -q -b hf origin/release; echo fix >> "$W/plugins/alpha/a.txt"; cfw fix.md alpha patch "alpha no longer breaks"; cm "fix"
}
ph() { pv --base origin/release; }

fam_hotfix() { PV=$1
  new_repo_h; cut_ --hotfix; cm "cut"; ph
  expect H1 0 "a hotfix: alpha one patch above release, its change file consumed into the CHANGELOG"
  has "$OUT" "kind: hotfix" "[H1b] …the kind is hotfix"
  eq "$(vof alpha)" "2.10.1" "[H1c] …alpha is 2.10.1"
  OUT=$(cd "$W" && env -u GITHUB_ACTIONS GITHUB_BASE_REF=release python3 "$PV" check --repo "$W" 2>&1); RC=$?
  has "$OUT" "kind: hotfix" "[H1d] GITHUB_BASE_REF=release is the hotfix kind"
  new_repo_h; cut_ --hotfix; rel_bump alpha 2.10.1 2.10.2; cm "cut"; ph
  expect H2 1 "a hotfix two patches above release"
  new_repo_h; cut_ --hotfix; echo b2 >> "$W/plugins/beta/b.txt"; cm "cut"; ph
  expect H3 1 "a hotfix that changes beta and does not raise it"
  new_repo_h; cut_ --hotfix; cm "cut"; gw checkout -q HEAD~1 -- .changes/fix.md; cm "put it back"; ph
  expect H4 1 "the consumed change file left in .changes/ (its line is in the CHANGELOG)"
  new_repo_h; cfw fix.md alpha minor "alpha no longer breaks"; cm "minor"
  printf '# Changelog of alpha\n\n## 2.10.1\n\n- minor: alpha no longer breaks\n\n' > "$W/plugins/alpha/CHANGELOG.md.new"
  sed -n '3,$p' "$W/plugins/alpha/CHANGELOG.md" >> "$W/plugins/alpha/CHANGELOG.md.new"; mv "$W/plugins/alpha/CHANGELOG.md.new" "$W/plugins/alpha/CHANGELOG.md"
  gw rm -q .changes/fix.md; cm "by hand"; ph
  expect H5 1 "a hotfix whose change file says minor (version and CHANGELOG as a patch)"
  new_repo_h; cut_ --hotfix; mp_py 'd["description"] = "changed"'; cm "cut"; ph
  expect H7 1 "a hotfix that changes the marketplace"
  new_repo_h; cut_ --hotfix; setm delta; cm "cut"; ph
  expect H8 1 "a hotfix that adds a plugin"
  new_repo_h; cfw fix.md "alpha, beta" patch "alpha no longer breaks"; cm "names beta"; cut_ --hotfix
  gw checkout -q origin/release -- plugins/beta; cm "cut"; ph
  expect H9 1 "a hotfix change file that names beta, which the hotfix does not change"
  new_repo_h; gw checkout -q main; gw merge -q --ff-only origin/main; echo feat >> "$W/plugins/beta/b.txt"; cfw feat2.md beta patch "beta feature"
  cm "a feature on main"; gw push -q origin main; gw fetch -q origin; gw checkout -q -b hf2 origin/main
  echo fix >> "$W/plugins/alpha/a.txt"; cfw fix.md alpha patch "alpha fixed"; cm "fix"; cut_; cm "cut"; ph
  expect H10 1 "a hotfix branched from main: it carries main's unreleased commit"
  new_repo_h; cut_ --hotfix; setm alpha ', "version": "2.10.1"'; cm "cut, and a version written into the manifest"; ph
  expect H12 1 "a hotfix that writes its version into a manifest"
  # a release branch from before the reset (its manifests carry a version): cut --hotfix refuses, the first release is from main
  new_repo_h; gw checkout -q -b old origin/release; setv beta '"1.0.1"'; cm "a pre-reset manifest"; gw push -q origin old:release
  gw fetch -q origin; gw checkout -q -b hf3 origin/release; echo fix3 >> "$W/plugins/alpha/a.txt"; cfw fix3.md alpha patch "x"; cm "fix"
  OUT=$(cd "$W" && env -u GITHUB_ACTIONS -u GITHUB_BASE_REF python3 "$PV" cut --hotfix 2>&1); RC=$?
  expect H11 1 "cut --hotfix on a release whose manifests carry a version"
  has "$OUT" "predates the version reset" "[H11b] …says the release predates the reset"
}

# new_repo_b — new_repo_h merged into release (the squash lands on release), W on backmerge/x at the release tip; main moved on
new_repo_b() {
  new_repo_h; cut_ --hotfix; cm "cut"; gw push -q origin hf:release
  gw checkout -q main; gw merge -q --ff-only origin/main; echo m > "$W/main.txt"; cm "main moves on"; gw push -q origin main
  gw fetch -q origin; gw checkout -q -b backmerge/x origin/release
}

fam_backmerge() { PV=$1
  new_repo_b; pv
  expect B1 0 "a back-merge: the release tip into main, no change file"
  has "$OUT" "kind: back-merge" "[B1b] …the kind is back-merge"
  new_repo_b; echo r2 >> "$W/README.md"; cm "one more"; pv
  expect B2 1 "a back-merge branch with a commit that is not on release"
  hasnt "$OUT" "kind: back-merge" "[B2b] …is not the back-merge kind"
  new_repo_b; gw checkout -q -b hf2 origin/release; echo fix2 >> "$W/plugins/alpha/a.txt"; rel_bump alpha 2.10.1 2.10.2
  cm "second hotfix"; gw push -q origin hf2:release; gw fetch -q origin; gw checkout -q backmerge/x; pv
  expect B3 1 "a back-merge of an older release tip: its versions are not release's"
  new_repo_b; gw checkout -q --detach origin/main; gw merge -q --no-ff -m "test merge" backmerge/x; pv
  expect B4 0 "CI's test merge (first parent main, second the back-merge head)"
  has "$OUT" "kind: back-merge" "[B4b] …is the back-merge kind"
  new_repo_b; echo u > "$W/untracked.txt"; pv
  expect B5 1 "a back-merge with an untracked file in the working tree"
  new_repo_r; echo more >> "$W/plugins/alpha/a.txt"; rel_bump alpha 2.9.0 9.9.9; cm "an ordinary PR raises alpha, no change file"
  gw tag origin/release HEAD; pv
  expect B6 1 "an ordinary PR with a tag named origin/release at its head (the tag must not stand in for the branch)"
  hasnt "$OUT" "kind: back-merge" "[B6b] …is not read as a back-merge"
}

FAMILIES="fam_real fam_scratch fam_ordinary fam_removal fam_release fam_hotfix fam_backmerge"
for f in $FAMILIES; do echo "-- $f"; "$f" "$PV_REAL"; done

# ── each planted break must turn its family red ─────────────────────────────────────────────────
BRK() {  # BRK <label> <family> <needle> <old> <new>   (in a copy of release.py)
  local d="$TMP/break-$1"; mkdir -p "$d"; cp "$PV_REAL" "$d/release.py"
  mutate "$d/release.py" "$4" "$5" && expect_red "$1" "$2" "$d/release.py" "$3"
}
echo "-- planted breaks"
CMP='    if vtuple(head) <= vtuple(old):'
BRK comparison-inverted fam_scratch '[S3]' "$CMP" '    if vtuple(head) >= vtuple(old):'
BRK strings-compared fam_scratch '[S4]' "$CMP" '    if head <= old:'
BRK equal-passes fam_scratch '[S2]' "$CMP" '    if vtuple(head) < vtuple(old):'
BRK new-plugin-red fam_scratch '[S8]' '    if old is None:
        if exists:' '    if old is None and False:
        if exists:'
BRK every-plugin-checked fam_scratch '[S1]' '    touched = plugins_touched(paths)' '    touched = sorted(os.listdir(os.path.join(repo, "plugins")))'
BRK merge-base-not-tip fam_scratch '[S11]' '    exists, head = read_manifest(repo, name)
    old = rev_version(repo, base, name)' '    exists, head = read_manifest(repo, name)
    old = rev_version(repo, git(repo, "merge-base", "HEAD", base)[1].decode().strip(), name)'
BRK symlink-followed fam_scratch '[S19]' '    if os.path.islink(path):
        raise Bad("plugins/%s/%s is a symlink: its version' '    if False:
        raise Bad("plugins/%s/%s is a symlink: its version'
BRK committed-only fam_scratch '[S12]' '"--ignore-submodules=none", mb)' '"--ignore-submodules=none", mb, "HEAD")'
BRK untracked-ignored fam_scratch '[S13]' 'untracked = set(p for p in out2.decode' 'untracked = set() or set(p for p in b"".decode'
BRK submodule-ignored fam_scratch '[S28]' '"--no-renames", "--ignore-submodules=none", mb)' '"--no-renames", mb)'
BRK non-utf8-name-lost fam_scratch '[S29]' 'fields = out.decode("utf-8", "surrogateescape")' 'fields = out.decode("utf-8", "replace")'
BRK ci-not-run-passes fam_scratch '[S23]' '    if os.environ.get("GITHUB_ACTIONS"):' '    if False:'
BRK leading-zero-accepted fam_scratch '[S16]' '(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)' '[0-9]+\.[0-9]+\.[0-9]+'
BRK lost-manifest-passes fam_scratch '[S21]' '            bad.append("plugin %s lost its manifest and still has files" % name)
        else:' '            print("plugin %s: ok" % name)
        else:'
BRK unresolved-base-passes fam_scratch '[S24]' '            print("red: base ref %s does not resolve" % given)
            return 1' '            return 0'
BRK kind-always-bootstrap fam_ordinary '[O3]' '    if not ever_had(repo, base, CHANGES + "/README.md"):' '    if True:'
BRK version-move-not-release fam_ordinary '[O6b]' '    if any_version_moved(repo, mb):
        return "release"' '    if False:
        return "release"'
BRK change-file-optional fam_ordinary '[O2]' '        if name not in named:
            bad.append("plugin %s changed and no change file' '        if False:
            bad.append("plugin %s changed and no change file'
BRK any-status-is-added fam_ordinary '[O8a]' '            if status == "A":' '            if True:'
BRK pending-delete-passes fam_ordinary '[O8b]' 'and show(repo, mb, p) is not None:' 'and show(repo, mb, p) is not None and os.path.exists(os.path.join(repo, p)):'
BRK upgrade-edit-any fam_ordinary '[O8d]' '    if now[:3] != old:' '    if now[:2] != old[:2]:'
BRK upgrade-empty-ok fam_ordinary '[O8g]' '    if "upgrade" in head and not head["upgrade"]:' '    if False:'
BRK any-level fam_ordinary '[O7 level]' '    if head["level"] not in LEVELS:' '    if False:'
BRK unknown-plugin-passes fam_ordinary '[O7 unknown]' '        if unknown:
            bad.append("%s: plugins: %s' '        if False:
            bad.append("%s: plugins: %s'
BRK body-many-lines fam_ordinary '[O7 twolines]' '    if len(body) != 1:' '    if not body:'
BRK subdir-allowed fam_ordinary '[O7 subdir]' '        if "/" in rest or not CHANGE_NAME.fullmatch(rest):' '        if not CHANGE_NAME.fullmatch(rest.split("/")[-1]):'
BRK marketplace-unchecked fam_ordinary '[O11]' '        if keys:
            bad.append("%s carries a version key' '        if False:
            bad.append("%s carries a version key'
BRK version-key-allowed fam_ordinary '[O9]' '        keys = version_keys(data) if exists else []' '        keys = []'
BRK top-level-only fam_ordinary '[O9f]' '        keys = version_keys(data) if exists else []' '        keys = [("version", "x")] if exists and carries_version(data) else []'
BRK version-key-ordinary-only fam_hotfix '[H12]' '        check_no_versions(repo, bad)' '        kind == "ordinary" and check_no_versions(repo, bad)'
BRK unrelease-passes fam_ordinary '[O9d]' '        if old != now and not reset and name not in removed:' '        if False:'
BRK new-plugin-is-release fam_ordinary '[O16d]' '    for name in plugin_names_at(repo, rev):
        try:
            now = released_here(repo, name)' '    for name in plugin_names(repo, rev):
        try:
            now = released_here(repo, name)'
BRK reset-red fam_ordinary '[O10]' '    reset = base_carries_versions(repo, mb)' '    reset = []'
BRK readme-delete-passes fam_ordinary '[O18]' '        if p == CHANGES + "/README.md" and (os.path.islink(os.path.join(repo, p)) or not os.path.isfile(os.path.join(repo, p))):' '        if False:'
BRK tip-decides-kind fam_ordinary '[O19b]' '    if not ever_had(repo, base, CHANGES + "/README.md"):' '    if not git(repo, "ls-tree", "--name-only", base, "--", CHANGES)[1].strip():'
BRK entries-unchecked fam_ordinary '[O20b]' '    if not isinstance(np_, list) or np_[:len(op)] != op:' '    if False:'
BRK prefix-only-length fam_ordinary '[O20a]' '    if not isinstance(np_, list) or np_[:len(op)] != op:' '    if not isinstance(np_, list) or len(np_) < len(op):'
BRK duplicates-allowed fam_ordinary '[O25]' '    if dups:' '    if False:'
BRK top-level-unchecked fam_ordinary '[O26]' '    if o != n:' '    if False:'
BRK description-counted fam_ordinary '[O27]' '        return {k: _no_description(x) for k, x in v.items() if not (k == "description" and isinstance(x, str))}' '        return {k: _no_description(x) for k, x in v.items()}'
BRK any-description-dropped fam_ordinary '[O31]' 'if not (k == "description" and isinstance(x, str))}' 'if k != "description"}'
BRK entry-description-counted fam_ordinary '[O27]' '        return [_no_description(x) for x in v]' '        return v'
BRK readme-symlink-passes fam_ordinary '[O30]' 'and (os.path.islink(os.path.join(repo, p)) or not os.path.isfile(os.path.join(repo, p))):' 'and not os.path.isfile(os.path.join(repo, p)):'
BRK special-unchecked fam_ordinary '[O21a]' '    for p in special_under_plugins(repo):
        bad.append("%s is a symlink or a submodule: what' '    for p in []:
        bad.append("%s is a symlink or a submodule: what'
BRK changefile-symlink fam_ordinary '[O22]' '        if os.path.islink(os.path.join(repo, p)) or not os.path.isfile(os.path.join(repo, p)):' '        if False:'
BRK any-plugin-dir-named fam_ordinary '[O24]' '        return set(marketplace_entries(json_or_none(open(path, "rb").read())))' '        return plugin_dirs(repo)'
BRK base-ref-ignored fam_ordinary '[O15]' 'if os.environ.get("GITHUB_BASE_REF") else BASE_DEFAULT' 'if False else BASE_DEFAULT'
BRK removal-files-unchecked fam_removal '[X10]' '        if not holds_file(repo, "plugins/" + n):' '        if True:'
BRK removed-entry-is-drift fam_removal '[X1]' '    op = [e for e in op if not (isinstance(e, dict) and isinstance(e.get("name"), str) and e["name"] in removed)] if isinstance(op, list) else []' '    op = op if isinstance(op, list) else []'
BRK removed-needs-change-file fam_removal '[X1]' '        if name in removed:
            continue' '        if False:
            continue'
BRK removed-release-moved fam_removal '[X1]' 'if old != now and not reset and name not in removed:' 'if old != now and not reset:'
BRK mixed-note-deleted fam_removal '[X8]' '        if len(gone) != len(old_plugins):' '        if False:'
BRK staying-note-edited fam_removal '[X9]' '    if not gone:
        bad.append("%s is a pending' '    if False:
        bad.append("%s is a pending'
BRK names-unchecked fam_removal '[X6]' '    if plugins != want:' '    if False:'
BRK level-unchecked fam_removal '[X5]' '    if level != old_level:' '    if False:'
BRK body-unchecked fam_removal '[X3]' '    for n in names_removed(line, removed):' '    for n in []:'
BRK short-name-unchecked fam_removal '[X3]' ' + ([n.split("-", 1)[1].lower()] if "-" in n else [])' ''
BRK substring-match fam_removal '[X13]' 'r"(?<![a-z0-9])%s(?![a-z0-9])"' 'r"%s"'
BRK notes-left-pass fam_removal '[X2]' '    if removed:
        pending_left(repo, mb, paths, removed, bad)' '    if False:
        pending_left(repo, mb, paths, removed, bad)'
BRK source-unchecked fam_removal '[X14]' '        if not isinstance(src, str) or os.path.normpath(src).replace(os.sep, "/") != "plugins/" + n:' '        if False:'
BRK ignored-counted fam_removal '[X15]' '"--cached", "--others", "--exclude-standard"' '"--cached", "--others"'
BRK odd-name-crash fam_removal '[X17]' 'isinstance(e.get("name"), str) and e["name"] in removed' 'e.get("name") in removed'
BRK body-case-sensitive fam_removal '[X4]' '    low = line.lower()' '    low = line'

BRK pending-left-passes fam_release '[R2]' '    for p in change_files_here(repo):
        bad.append("%s is in .changes/' '    for p in []:
        bad.append("%s is in .changes/'
BRK any-step fam_release '[R4]' '            if now != want:
                bad.append("plugin %s: %s -> %s; the change files' '            if False:
                bad.append("plugin %s: %s -> %s; the change files'
BRK unnamed-raise fam_release '[R6]' '        elif now != old:
            bad.append("plugin %s: %s -> %s, and no pending' '        elif False:
            bad.append("plugin %s: %s -> %s, and no pending'
BRK manifest-in-scope fam_release '[R10]' '        elif len(parts) == 3 and parts[0] == "plugins" and parts[2] == CHANGELOG:' '        elif len(parts) >= 3 and parts[0] == "plugins" and parts[2] in (CHANGELOG, ".claude-plugin"):'
BRK kb-in-scope fam_release '[R11]' '        elif len(parts) == 3 and parts[0] == "plugins" and parts[2] == CHANGELOG:' '        elif p.startswith("kb/") or (len(parts) == 3 and parts[0] == "plugins" and parts[2] == CHANGELOG):'
BRK cut-writes-state fam_release '[R1d]' '    for p in files:
        os.remove(os.path.join(repo, p))' '    open(os.path.join(repo, "kb", "current-state.md"), "a").write("- alpha 2.10.0\\n")
    for p in files:
        os.remove(os.path.join(repo, p))'
BRK first-any-number fam_release '[R15d]' '            want = bump(old, levels[name]) if old else FIRST_RELEASE' '            want = bump(old, levels[name]) if old else now'
BRK first-not-frozen fam_release '[R15c]' '            frozen[rel] = plan[n][1]                    # the first release' '            pass                    # the first release'
BRK hotfix-pre-reset fam_hotfix '[H11]' '        if hotfix and base_carries_versions(repo, base):' '        if False:'
BRK changelog-unchecked fam_release '[R7]' '            if missing:
                bad.append("plugins/%s/%s `## %s` lacks %d' '            if False:
                bad.append("plugins/%s/%s `## %s` lacks %d'
BRK scope-unchecked fam_release '[R8]' '                       % (name, old or "unreleased", now or "unreleased"))
    release_scope(repo, mb, paths, bad)' '                       % (name, old or "unreleased", now or "unreleased"))
    pass'
BRK release-ancestor fam_release '[R9]' '    if rel and not is_ancestor(repo, rel, "HEAD"):
        bad.append(' '    if False:
        bad.append('
BRK contract-any-edit fam_release '[R12b]' '            if not same_but(text_at(repo, mb, p), text_here(repo, p), FROZEN):' '            if False:'
BRK zero-major-is-major fam_release '[R13b]' '    if level == "major" and x > 0:' '    if level == "major":'
BRK hotfix-not-told fam_hotfix '[H1]' '    if branch_of(base_ref) == RELEASE:' '    if False:'
BRK hotfix-any-version fam_hotfix '[H2]' '        if now != want:
            bad.append("plugin %s changed: a hotfix' '        if False:
            bad.append("plugin %s changed: a hotfix'
BRK hotfix-left fam_hotfix '[H4]' '        if show(repo, base, p) is None:' '        if False:'
BRK hotfix-level fam_hotfix '[H5]' '        if level != "patch":
            bad.append("%s: level %s; a hotfix' '        if False:
            bad.append("%s: level %s; a hotfix'
BRK hotfix-marketplace fam_hotfix '[H7]' '    if MARKETPLACE in paths:
        bad.append("%s changes in a hotfix' '    if False:
        bad.append("%s changes in a hotfix'
BRK hotfix-unnamed fam_hotfix '[H9]' '    for name in sorted(set(named) - set(touched)):' '    for name in []:'
BRK backmerge-any-commit fam_backmerge '[B2]' 'if tip and tip != mb and is_ancestor(repo, tip, rel) and' 'if tip and tip != mb and'
BRK backmerge-versions fam_backmerge '[B3]' '        if theirs is not None and now != theirs:' '        if False:'
BRK testmerge-parent fam_backmerge '[B4]' '    if len(parts) == 3 and parts[1] == base:' '    if False:'
BRK ref-shadowed fam_backmerge '[B6]' '    return "refs/remotes/" + ref if ref.startswith("origin/") else ref' '    return ref'
BRK hotfix-carries-main fam_hotfix '[H10]' '    if carried:' '    if False:'
BRK ghost-dropped fam_release '[R14]' '    for name in sorted(set(levels) - set(names)):' '    for name in []:'
BRK backmerge-dirty fam_backmerge '[B5]' 'and not is_ancestor(repo, tip, base) and worktree_clean(repo):' 'and not is_ancestor(repo, tip, base):'

PVC="$TMP/break-none"; mkdir -p "$PVC"; cp "$PV_REAL" "$PVC/release.py"
QN=0; okdef=$(declare -f ok); baddef=$(declare -f bad); sp=$PASS; sf=$FAIL
ok() { :; }; bad() { QN=$((QN+1)); }
for f in fam_scratch fam_ordinary fam_removal fam_release fam_hotfix fam_backmerge; do "$f" "$PVC/release.py" >/dev/null 2>&1; done
eval "$okdef"; eval "$baddef"; PASS=$sp; FAIL=$sf
eq "$QN" 0 "control: an unbroken copy passes every scratch family (no failed check)"

echo; summary
