#!/bin/bash
# =============================================================================
# Releases: `release.py plan` and `cut` (scripts/release.py)
# =============================================================================
# Run: bash tests/test-release.sh
#
# No version in private; the released version is the CHANGELOG's first heading;
# the kinds of `release.py check` are tests/test-plugin-version.sh.
#   [C] plan prints what a cut does and writes nothing; cut raises each named plugin one step (a plugin never released to 0.1.0)
#       by writing its CHANGELOG entry, removes the change files, writes no manifest and no kb page, and sets `Frozen at` where the
#       surface moved since origin/release; its result passes `release.py check` (a release, and a hotfix with --hotfix); each
#       refusal alone; when the marketplace has two or more plugins released after the cut, each new section (release or hotfix)
#       starts with `Released together: <name> <version>, …` naming every one of them, raised or not (none with one); plan and
#       cut print it and each raised plugin's floor on a sibling it depends on; notes print the section, and a paragraph to update
#       the sibling when that floor moved since the previous release (a section with no line, or a first release: no such
#       paragraph); check is red on a PR, a fold too, that changes the `Released together:` line of a released section on the
#       merge-base (one above any private history), wherever a heading put in moves it, or that hides such a section (a lone CR)
#   [F] cut --fold --public REPO joins the pending change files to each plugin's top released section when the public
#       repository (a local bare repository here) has no tag for it: lines after the section's own, notes under its Upgrade
#       notes, nothing twice, no version moved; check --public passes it as a fold (a CRLF base too), and is red on each
#       broken part; a line of the unpublished section may be reworded (same level, same count), a published or older section
#       stays frozen; each refusal; the release's `Released together:` line is kept and not written again
#   [M] the next public section is the final state since the previous public version: a cut (plan, cut and check of a release
#       need --public) joins every section cut and not published into the new one, oldest first, so none stays below the top
#       (check is red when one does); a fold joins a lower unpublished section into the top one, which keeps its version; a
#       pending change file's `supersedes:` takes out the line and note of the change it names, `cancels:` those and its own
#       unless something it cancels was published; a chain keeps only the last; a line already published is not written again;
#       a named line reworded in an unpublished section refuses the cut and the check; a note two files share stays when one goes;
#       a cancel of a published line that an unpublished section repeats keeps its line, and a supersede takes its copy's note; a
#       later fold into a joined section keeps its version; a public repository with no tag of a plugin that has older versions,
#       or an unreadable one, is refused; a plugin the cut does not name keeps no stack (cut refused, check red) and loses no
#       unpublished section; a plugin whose pending lines all go is not raised; check is red on a line left that goes, a line
#       lost, a line twice and a line of any other shape; notes print the joined section and compare the floor with the
#       published section below; a mark without the leading date names the one dated file (two: refused)
# Real git on throw-away repositories, no network.
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
OUT=""; RC=0; W=""; O=""

gw() { ( cd "$W" && git_ "$@" ); }
# setm <plugin> — a manifest with no version (the private form); setcl <plugin> <version> — a CHANGELOG released at <version>
setm() { mkdir -p "$W/plugins/$1/.claude-plugin"; printf '{\n  "name": "%s"\n}\n' "$1" > "$W/plugins/$1/.claude-plugin/plugin.json"; }
setcl() { mkdir -p "$W/plugins/$1"; printf '# Changelog of %s\n\nNewest first.\n\n## %s\n\n- patch: earlier\n' "$1" "$2" > "$W/plugins/$1/CHANGELOG.md"; }
# relv <plugin> <version> — a release of it: a new `## <version>` on top of its CHANGELOG
relv() { python3 - "$W/plugins/$1/CHANGELOG.md" "$2" <<'PY'
import sys
p, v = sys.argv[1:3]; t = open(p).read(); i = t.find("\n## ")
open(p, "w").write(t[:i + 1] + "## %s\n\n- patch: x\n" % v + t[i:])
PY
}
# vof <plugin> — its released version: the CHANGELOG's first `## ` heading
vof() { sed -n 's/^## //p' "$W/plugins/$1/CHANGELOG.md" | head -n 1; }
cm() { gw add -A; gw commit -q -m "$1"; }
cfw() { mkdir -p "$W/.changes"; printf -- '---\nplugins: %s\nlevel: %s\n---\n%s\n' "$2" "$3" "$4" > "$W/.changes/$1"; }
# pubtag <tag> — the public repository publishes <tag>
pubtag() { gw push -q "$P" "main:refs/tags/$1"; }
# cfwu <file> <plugins> <level> <line> <upgrade> — a change file with its optional upgrade line
cfwu() { mkdir -p "$W/.changes"; printf -- '---\nplugins: %s\nlevel: %s\nupgrade: %s\n---\n%s\n' "$2" "$3" "$5" "$4" > "$W/.changes/$1"; }

# ── [C] plan and cut ───────────────────────────────────────────────────────────────────────────────────────────────────
# new_rel_repo — W: a clone of origin O after the bootstrap and the version reset: plugins alpha released 2.9.0 (with a CONTRACT.md)
# and beta 1.0.0 (their CHANGELOGs; no version in a manifest), a marketplace, a current-state with old version lines nothing
# rewrites, origin/release at that commit, then two pending change files on main (alpha minor, beta patch); W on branch rel
new_rel_repo() {
  local d; d=$(fresh); O="$d/origin.git"
  git_ init -q --bare -b main "$O"; git_ clone -q "$O" "$d/w" 2>/dev/null; W="$d/w"
  setm alpha; setm beta; echo a > "$W/plugins/alpha/a.txt"; echo b > "$W/plugins/beta/b.txt"
  printf 'Frozen at: 2.9.0\n<!-- surface:begin -->\nx\n<!-- surface:end -->\n' > "$W/plugins/alpha/CONTRACT.md"
  printf '# Changelog of alpha\n\nNewest first.\n\n## 2.9.0\n\n- minor: older\n' > "$W/plugins/alpha/CHANGELOG.md"
  setcl beta 1.0.0
  mkdir -p "$W/.changes" "$W/.claude-plugin" "$W/kb"; echo "# change files" > "$W/.changes/README.md"
  printf '{"name": "m", "plugins": [{"name": "alpha", "source": "./plugins/alpha"}, {"name": "beta", "source": "./plugins/beta"}]}\n' > "$W/.claude-plugin/marketplace.json"
  printf '# state\n\n- `plugins/alpha/` needs `beta >=1.0.0`, version 2.9.0.\n- Plugin at `plugins/beta/`, version 1.0.0.\n' > "$W/kb/current-state.md"
  cm base; gw branch -M main; gw push -q -u origin main; gw push -q origin main:release
  # the public repository P: both released versions are published
  P="$d/public.git"; git_ init -q --bare -b main "$P"
  gw push -q "$P" main:refs/tags/alpha--v2.9.0; gw push -q "$P" main:refs/tags/beta--v1.0.0
  echo a2 >> "$W/plugins/alpha/a.txt"; cfw a.md alpha minor "alpha does more"; cm "feature"
  echo b2 >> "$W/plugins/beta/b.txt"; cfw b.md beta patch "beta is fixed"; cm "fix"
  gw push -q origin main; gw fetch -q origin; gw checkout -q -b rel
}
# pub_args <args> — the args, plus --public P for a plan, cut or check that names no --public, --fold or --hotfix of its own
# (NOPUB=1: none, for a run that must name no public repository)
pub_args() {
  A=("$@")
  case " $* " in *" --public "*|*" --fold "*|*" --hotfix "*) return;; esac
  [ -z "${NOPUB:-}" ] || return 0
  case "${1:-}" in plan|cut|check) [ -n "${P:-}" ] && A+=(--public "$P");; esac
}
rp() { pub_args "$@"; OUT=$(cd "$W" && env -u GITHUB_ACTIONS -u GITHUB_BASE_REF python3 "$RPY" "${A[@]}" --repo "$W" 2>&1); RC=$?; }
# rpc — rp for a run that must be red (through capped)
rpc() { pub_args "$@"; OUT=$(cd "$W" && capped env -u GITHUB_ACTIONS -u GITHUB_BASE_REF python3 "$RPY" "${A[@]}" --repo "$W" 2>&1); RC=$?; }
tree_id() { ( cd "$W" && { git_ status --porcelain; find . -path ./.git -prune -o -type f -print | sort | xargs cat; } | cksum ); }

fam_cut() { RPY=$1; local before
  new_rel_repo; before=$(tree_id); rp plan
  eq "$RC" 0 "[C1] plan: rc 0"
  has "$OUT" "plugin alpha: 2.9.0 -> 2.10.0 (minor)" "[C1] …alpha one minor"
  has "$OUT" "plugin beta: 1.0.0 -> 1.0.1 (patch)" "[C1] …beta one patch"
  eq "$(tree_id)" "$before" "[C1] …and plan writes nothing"
  rp cut
  eq "$RC" 0 "[C2] cut on a branch from main: rc 0"
  eq "$(vof alpha) $(vof beta)" "2.10.0 1.0.1" "[C2] …released versions raised (the CHANGELOG headings)"
  eq "$(gw status --porcelain -- 'plugins/*/.claude-plugin/plugin.json')" "" "[C2] …no manifest written"
  eq "$(ls "$W/.changes")" "README.md" "[C2] …the change files consumed, README.md kept"
  has "$(cat "$W/plugins/alpha/CHANGELOG.md")" "## 2.10.0

Released together: alpha 2.10.0, beta 1.0.1

- minor: alpha does more

## 2.9.0" "[C2] …alpha's CHANGELOG gains its entry above the last one, after the plugins released together"
  has "$(cat "$W/plugins/beta/CHANGELOG.md")" "## 1.0.1

Released together: alpha 2.10.0, beta 1.0.1

- patch: beta is fixed

## 1.0.0" "[C2] …beta's CHANGELOG gains its entry, after the same line"
  eq "$(gw status --porcelain -- kb)" "" "[C2] …the state line untouched (no version in kb pages)"
  has "$(cat "$W/plugins/alpha/CONTRACT.md")" "Frozen at: 2.9.0" "[C2] …Frozen at kept: the surface is release's"
  cm "release"; rp check
  eq "$RC" 0 "[C3] the cut, committed, passes release.py check"
  has "$OUT" "kind: release" "[C3] …as a release"
  # a plugin never released (no CHANGELOG) goes to 0.1.0 whatever its level, and its CHANGELOG is created
  new_rel_repo; gw checkout -q main; setm gamma; echo g > "$W/plugins/gamma/g.txt"; cfw g.md gamma patch "gamma arrives"
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["plugins"].append({"name": "gamma", "source": "./plugins/gamma"}); json.dump(d,open(p,"w"))' "$W/.claude-plugin/marketplace.json"
  cm "gamma"; gw push -q origin main; gw checkout -q rel; gw merge -q --ff-only main; rp plan
  has "$OUT" "plugin gamma: unreleased -> 0.1.0 (first release)" "[C18] plan: a plugin never released goes to 0.1.0"
  rp cut
  eq "$RC:$(vof gamma)" "0:0.1.0" "[C18] …cut writes 0.1.0, not a patch step (0.0.1)"
  cm "release"; rp check
  eq "$RC" 0 "[C18] …and the cut passes check"
  # release left at a commit from before the reset (the first public release never promoted): the cut compares the surface with
  # main, not with that stale release, so a later patch release after a frozen surface change is not refused
  new_rel_repo; gw checkout -q main; gw rm -q .changes/a.md .changes/b.md
  printf '{\n  "name": "alpha",\n  "version": "2.9.0"\n}\n' > "$W/plugins/alpha/.claude-plugin/plugin.json"; cm "a pre-reset manifest"
  gw push -q origin main; gw push -q -f origin main:release; setm alpha; sed -i.bak 's/^x$/y/' "$W/plugins/alpha/CONTRACT.md"
  printf '# Changelog of alpha\n\nNewest first.\n\n## 0.1.0\n\n- minor: first\n' > "$W/plugins/alpha/CHANGELOG.md"
  sed -i.bak 's/^Frozen at: .*/Frozen at: 0.1.0/' "$W/plugins/alpha/CONTRACT.md"; rm -f "$W/plugins/alpha/CONTRACT.md.bak"
  echo a3 >> "$W/plugins/alpha/a.txt"; cfw c.md alpha patch "a fix"; cm "reset, first release, a fix"; gw push -q origin main
  gw fetch -q origin; gw checkout -q rel; gw merge -q --ff-only main; rp cut
  eq "$RC:$(vof alpha)" "0:0.1.1" "[C19] origin/release from before the reset: a patch release after the first, its surface compared with the first release"
  cm "release 0.1.1"; gw checkout -q main; gw merge -q --ff-only rel; sed -i.bak 's/^y$/z/' "$W/plugins/alpha/CONTRACT.md"; rm -f "$W/plugins/alpha/CONTRACT.md.bak"
  cfw d.md alpha minor "a surface change"; cm "surface after the release"; gw push -q origin main; gw fetch -q origin
  gw checkout -q -b rel2; rp cut
  eq "$RC:$(vof alpha):$(sed -n 1p "$W/plugins/alpha/CONTRACT.md")" "0:0.2.0:Frozen at: 0.2.0" "[C19b] …a surface change after the last release (on main, not promoted) moves Frozen at"
  # the surface moved since release: Frozen at follows the new version
  new_rel_repo; gw checkout -q main; sed -i.bak 's/^x$/y/' "$W/plugins/alpha/CONTRACT.md"; rm -f "$W/plugins/alpha/CONTRACT.md.bak"
  cm "a surface change"; gw push -q origin main; gw checkout -q rel; gw merge -q --ff-only main; rp cut
  has "$(cat "$W/plugins/alpha/CONTRACT.md")" "Frozen at: 2.10.0" "[C4] the surface differs from release: Frozen at becomes 2.10.0"
  cm "release"; rp check
  eq "$RC" 0 "[C4] …and the cut passes check"
  new_rel_repo; gw checkout -q main; sed -i.bak 's/^x$/y/' "$W/plugins/alpha/CONTRACT.md"; rm -f "$W/plugins/alpha/CONTRACT.md.bak"
  rm "$W/.changes/a.md"; cfw a.md alpha patch "a patch only"; cm "surface with a patch"; gw push -q origin main; gw checkout -q rel; gw merge -q --ff-only main
  rp cut
  eq "$RC" 1 "[C5] a surface change named only at patch: cut refused"
  # each refusal alone
  new_rel_repo; echo dirt >> "$W/README.md"; rp cut
  eq "$RC" 1 "[C6] a dirty working tree: refused"
  has "$OUT" "not clean" "[C6] …and it says so"
  new_rel_repo; gw checkout -q main; rp cut
  eq "$RC" 1 "[C7] on main: refused"
  new_rel_repo; gw checkout -q -b release origin/release; gw merge -q --ff-only main; rp cut
  eq "$RC" 1 "[C8] on a branch named release: refused"
  new_rel_repo; gw checkout -q --detach; rp cut
  eq "$RC" 1 "[C9] a detached HEAD: refused"
  new_rel_repo; gw checkout -q -b old origin/main~1; rp cut
  eq "$RC" 1 "[C10] HEAD lacks main's tip: refused"
  new_rel_repo; gw rm -q .changes/a.md .changes/b.md; cm "nothing"; rp cut
  eq "$RC" 1 "[C11] nothing pending: refused"
  new_rel_repo; gw checkout -q -b hf origin/release; echo h > "$W/h.txt"; cm "a hotfix"; gw push -q origin hf:release; gw fetch -q origin
  gw checkout -q rel; rp cut
  eq "$RC" 1 "[C12] release holds a hotfix that main lacks: refused"
  has "$OUT" "back-merge" "[C12] …and it names the back-merge"
  # a hotfix: a branch from release, a patch change file, cut --hotfix, check against origin/release
  new_rel_repo; gw checkout -q -b hf origin/release; echo fix >> "$W/plugins/alpha/a.txt"; cfw fix.md alpha patch "alpha no longer breaks"; cm "fix"
  rp cut --hotfix
  eq "$RC:$(vof alpha)" "0:2.9.1" "[C13] cut --hotfix: rc 0, alpha one patch above release"
  cm "cut"; rp check --base origin/release
  eq "$RC" 0 "[C13] …and it passes check as a hotfix"
  has "$OUT" "kind: hotfix" "[C13] …the hotfix kind"
  # CI checks out the test merge of the PR into release: the change file is added and consumed inside the PR, so .changes/ is
  # the same on both parents and a plain `git log -- .changes/` skips the PR's commits
  gw checkout -q --detach origin/release; gw merge -q --no-ff -m "test merge" hf; rp check --base origin/release
  eq "$RC" 0 "[C13b] the same hotfix on the test merge of it into release passes check"
  has "$OUT" "hotfix change file .changes/fix.md" "[C13b] …and the check finds its change file"
  new_rel_repo; gw checkout -q -b hf origin/release; echo fix >> "$W/plugins/alpha/a.txt"; cfw fix.md alpha minor "a feature"; cm "fix"
  rp cut --hotfix
  eq "$RC" 1 "[C14] cut --hotfix with a minor change file: refused"
  new_rel_repo; gw checkout -q -b hf origin/release; sed -i.bak 's/^x$/y/' "$W/plugins/alpha/CONTRACT.md"; rm -f "$W/plugins/alpha/CONTRACT.md.bak"
  cfw fix.md alpha patch "a fix"; cm "fix"; rp cut --hotfix
  eq "$RC" 1 "[C15] cut --hotfix of a contract surface change: refused"
  new_rel_repo; gw checkout -q main; cfw a.md alpha patch "alpha does more"; cm "a patch"; gw push -q origin main; gw fetch -q origin
  gw checkout -q -b hf origin/main; echo fix >> "$W/plugins/alpha/a.txt"; cfw fix.md alpha patch "a fix"; cm "fix"; rp cut --hotfix
  eq "$RC" 1 "[C17] cut --hotfix on a branch from main (main's patch commits would ride it): refused"
  # upgrade notes: the optional `upgrade:` line of a change file, under `### Upgrade notes` of its plugin's section
  new_rel_repo; gw checkout -q main; rm "$W/.changes/a.md"
  cfwu a.md alpha minor "alpha does more" "Run alpha init once after the update."
  cfwu ab.md "alpha, beta" patch "both are fixed" "The PLAN lines now start with two spaces."
  cm "upgrade lines"; gw push -q origin main; gw checkout -q rel; gw merge -q --ff-only main; rp plan
  eq "$RC" 0 "[C20] plan: change files with an upgrade line are valid"
  rp cut
  eq "$RC" 0 "[C20] cut: rc 0"
  has "$(cat "$W/plugins/alpha/CHANGELOG.md")" "## 2.10.0

Released together: alpha 2.10.0, beta 1.0.1

- minor: alpha does more
- patch: both are fixed

### Upgrade notes

- Run alpha init once after the update.
- The PLAN lines now start with two spaces.

## 2.9.0" "[C20] …alpha's section ends with its upgrade notes, in the change files' order"
  has "$(cat "$W/plugins/beta/CHANGELOG.md")" "## 1.0.1

Released together: alpha 2.10.0, beta 1.0.1

- patch: both are fixed
- patch: beta is fixed

### Upgrade notes

- The PLAN lines now start with two spaces.

## 1.0.0" "[C20] …beta's holds only the note of the file that names it"
  cm "release"; rp check
  eq "$RC" 0 "[C20] …and the cut passes check"
  python3 - "$W/plugins/alpha/CHANGELOG.md" <<'PY2'
import sys
p = sys.argv[1]; t = open(p).read()
open(p, "w").write(t.replace("- Run alpha init once after the update.\n", "", 1))
PY2
  cm "an upgrade note dropped"; rp check
  eq "$RC" 1 "[C21] check: a release whose CHANGELOG lacks an upgrade note is red"
  has "$OUT" "Upgrade notes" "[C21] …and it names the Upgrade notes"
  new_rel_repo; rp cut
  hasnt "$(cat "$W/plugins/alpha/CHANGELOG.md")" "Upgrade notes" "[C22] no change file with an upgrade line: no Upgrade notes heading"
  cm "release"
  RC=0; OUT=$(cd "$W" && python3 "$RPY" notes alpha 2.10.0 --repo "$W" 2>&1) || RC=$?
  eq "$RC" 0 "[C23] notes alpha 2.10.0: rc 0"
  eq "$(printf '%s\n' "$OUT" | sed -n 1p)" "Released together: alpha 2.10.0, beta 1.0.1" "[C23] …the body starts with the section's lines (the heading is the release's title): the plugins released together"
  eq "$(printf '%s\n' "$OUT" | sed -n 3p)" "- minor: alpha does more" "[C23] …then its entries"
  has "$OUT" "### Updating" "[C23] …then an Updating paragraph"
  has "$OUT" '`/plugin`' "[C23] …that names /plugin"
  has "$OUT" '`/reload-plugins`' "[C23] …and /reload-plugins"
  has "$OUT" '`claude plugin update alpha@m`' "[C23] …and the shell command, with the marketplace's own name"
  hasnt "$OUT" "## 2.9.0" "[C23] …and no other version's section"
  RC=0; OUT=$(cd "$W" && python3 "$RPY" notes alpha 9.9.9 --repo "$W" 2>&1) || RC=$?
  eq "$RC" 1 "[C24] notes of a version the CHANGELOG lacks: rc 1"
  RC=0; (cd "$W" && python3 "$RPY" notes alpha --repo "$W" >/dev/null 2>&1) || RC=$?
  eq "$RC" 64 "[C24] notes without a version: rc 64"
  RC=0; (cd "$W" && python3 "$RPY" notes ../alpha 2.10.0 --repo "$W" >/dev/null 2>&1) || RC=$?
  eq "$RC" 64 "[C24] notes of a plugin name that is a path: rc 64"
  # a hotfix renders its upgrade note too
  new_rel_repo; gw checkout -q -b hf origin/release; echo fix >> "$W/plugins/alpha/a.txt"
  cfwu fix.md alpha patch "alpha no longer breaks" "Remove the stale lock file once."; cm "fix"; rp cut --hotfix
  has "$(cat "$W/plugins/alpha/CHANGELOG.md")" "## 2.9.1

Released together: alpha 2.9.1, beta 1.0.0

- patch: alpha no longer breaks

### Upgrade notes

- Remove the stale lock file once." "[C25] cut --hotfix writes the upgrade note"
  cm "cut"; rp check --base origin/release
  eq "$RC" 0 "[C25] …and it passes check as a hotfix"
  # the plugins released together: every marketplace entry released once the cut is written, raised or not
  new_rel_repo; gw rm -q .changes/a.md; cm "only beta pending"; rp cut
  has "$(cat "$W/plugins/beta/CHANGELOG.md")" "## 1.0.1

Released together: alpha 2.9.0, beta 1.0.1

- patch: beta is fixed" "[C26] a cut that raises only beta names alpha at its released version"
  eq "$(gw status --porcelain -- plugins/alpha)" "" "[C26] …and alpha's CHANGELOG is not written"
  new_rel_repo; python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["plugins"]=d["plugins"][:1]; json.dump(d,open(p,"w"))' "$W/.claude-plugin/marketplace.json"
  gw rm -q .changes/b.md; cm "a one-plugin marketplace"; rp cut
  eq "$RC:$(grep -c '^Released together: ' "$W/plugins/alpha/CHANGELOG.md")" "0:0" "[C27] a marketplace with one released plugin: no \`Released together:\` line"
  hasnt "$OUT" "released together" "[C27] …and the cut prints none"
  # the floor: alpha depends on beta; the cut records beta's version, plan prints it, notes tell to update beta when it moved
  new_rel_repo; gw checkout -q main; printf '{\n  "name": "alpha",\n  "dependencies": ["beta"]\n}\n' > "$W/plugins/alpha/.claude-plugin/plugin.json"
  cm "alpha needs beta"; gw push -q origin main; gw fetch -q origin; gw checkout -q rel; gw merge -q --ff-only main
  RC=0; OUT=$(cd "$W" && python3 "$RPY" notes alpha 2.9.0 --repo "$W" 2>&1) || RC=$?
  eq "$RC:$OUT" "0:- minor: older

### Updating

In Claude Code, run \`/plugin\`, open Marketplaces and update \`m\` there (or turn on its auto-update), then run \`/reload-plugins\`. From a shell: \`claude plugin marketplace update m\`, then \`claude plugin update alpha@m\`, then open a new session." \
    "[C28] notes of a section with no \`Released together:\` line: the body as before, no floor paragraph"
  rp plan
  has "$OUT" "released together: alpha 2.10.0, beta 1.0.1" "[C29] plan prints the plugins released together"
  has "$OUT" "plugin alpha: needs beta >=1.0.1 (was >=0.1.0)" "[C29] …and alpha's floor on beta, against its released section's"
  hasnt "$OUT" "plugin beta: needs" "[C29] …and none for beta (it depends on nothing)"
  rp cut; cm "release"; rp check
  eq "$RC" 0 "[C29] …the cut passes check"
  RC=0; OUT=$(cd "$W" && python3 "$RPY" notes alpha 2.10.0 --repo "$W" 2>&1) || RC=$?
  has "$OUT" "### Updating

This version needs beta 1.0.1 or later. Update beta too, before this plugin or with it: \`claude plugin update beta@m\`. Updated alone, this plugin fails to load, and \`/plugin\` names the version it requires.

In Claude Code, run \`/plugin\`" "[C30] notes of alpha 2.10.0: its floor on beta moved, so Updating starts by telling to update beta too"
  RC=0; OUT=$(cd "$W" && python3 "$RPY" notes beta 1.0.1 --repo "$W" 2>&1) || RC=$?
  hasnt "$OUT" "This version needs" "[C30] …beta's notes say nothing of a floor (it depends on nothing)"
  sed -i.bak 's/^Released together: alpha/Released together:  alpha/' "$W/plugins/alpha/CHANGELOG.md"; rm -f "$W/plugins/alpha/CHANGELOG.md.bak"  # the input, not a break
  RC=0; OUT=$(cd "$W" && python3 "$RPY" notes alpha 2.10.0 --repo "$W" 2>&1) || RC=$?
  hasnt "$OUT" "This version needs" "[C30] a line the export refuses (two spaces after the colon): notes read no floor from it either"
  gw checkout -q -- plugins/alpha/CHANGELOG.md
  gw checkout -q main; gw merge -q --ff-only rel; gw push -q origin main; gw push -q origin main:release
  pubtag alpha--v2.10.0; pubtag beta--v1.0.1                  # published: the next release stands on it
  echo a4 >> "$W/plugins/alpha/a.txt"; cfw a4.md alpha patch "alpha again"; cm "alpha again"; gw push -q origin main; gw fetch -q origin
  gw checkout -q -b rel2; rp plan
  has "$OUT" "plugin alpha: needs beta >=1.0.1 (was >=1.0.1)" "[C31] a release of alpha alone: the floor stays beta's version"
  rp cut; cm "release 2"
  RC=0; OUT=$(cd "$W" && python3 "$RPY" notes alpha 2.10.1 --repo "$W" 2>&1) || RC=$?
  has "$OUT" "Released together: alpha 2.10.1, beta 1.0.1" "[C31] …the notes name the pair"
  hasnt "$OUT" "This version needs" "[C31] …and, the floor not moved, say nothing of it"
  # a section on the merge-base keeps its `Released together:` line: the export reads the floor from it
  gw checkout -q main; gw merge -q --ff-only rel2; gw push -q origin main; gw push -q origin main:release; gw fetch -q origin
  gw checkout -q -b edit; echo a5 >> "$W/plugins/alpha/a.txt"; cfw e.md alpha patch "alpha typo"
  sed -i.bak 's/^Released together: alpha 2\.10\.0, beta 1\.0\.1$/Released together: alpha 2.10.0, beta 1.0.2/' "$W/plugins/alpha/CHANGELOG.md"  # the input, not a break
  rm -f "$W/plugins/alpha/CHANGELOG.md.bak"; cm "an ordinary PR that edits a released section's line"; rpc check
  eq "$RC" 1 "[C32] check: an ordinary PR that edits the \`Released together:\` line of a released section is red"
  has "$OUT" "plugins/alpha/CHANGELOG.md \`## 2.10.0\`: its \`Released together:\` line changed" "[C32] …naming the section"
  gw checkout -q -b edit2 main; echo a5 >> "$W/plugins/alpha/a.txt"; cfw e.md alpha patch "alpha typo"
  sed -i.bak 's/^- patch: alpha again$/- patch: alpha, again/' "$W/plugins/alpha/CHANGELOG.md"; rm -f "$W/plugins/alpha/CHANGELOG.md.bak"  # the input, not a break
  cm "an ordinary PR that rewords an entry"; rp check
  eq "$RC" 0 "[C32] control: the same PR rewording an entry line instead is green (only the line is kept)"
  gw checkout -q -b edit3 main; echo a5 >> "$W/plugins/alpha/a.txt"; cfw e.md alpha patch "alpha typo"
  sed -i.bak 's/^Released together: alpha 2\.10\.0,/x\rReleased together: alpha 2.10.0,/' "$W/plugins/alpha/CHANGELOG.md"; rm -f "$W/plugins/alpha/CHANGELOG.md.bak"  # the input, not a break
  cm "the line hidden behind a lone CR"; rpc check
  eq "$RC" 1 "[C32] check: a lone CR in front of the line (git and the export read no line there any more) is red"
  gw checkout -q -b edit4 main; echo a5 >> "$W/plugins/alpha/a.txt"; cfw e.md alpha patch "alpha typo"
  python3 - "$W/plugins/alpha/CHANGELOG.md" <<'PY2'  # the input, not a break
import sys
p = sys.argv[1]; t = open(p, newline="").read()
t = t.replace("\n## 2.10.0\n", "\r## 2.10.0\n", 1).replace("Released together: alpha 2.10.0, beta 1.0.1", "Released together: alpha 2.10.0, beta 1.0.0", 1)
open(p, "w", newline="").write(t)
PY2
  cm "a lone CR hides a released heading, and its line is edited"; rpc check
  eq "$RC" 1 "[C32] check: a lone CR before a released heading (the section is gone as git reads it) is red"
  has "$OUT" "plugins/alpha/CHANGELOG.md \`## 2.10.0\`: the section that holds its \`Released together:\` line is gone" "[C32] …naming the section"
  gw checkout -q -b edit6 main; echo a5 >> "$W/plugins/alpha/a.txt"; cfw e.md alpha patch "alpha typo"
  python3 - "$W/plugins/alpha/CHANGELOG.md" <<'PY2'  # the input, not a break
import sys
p = sys.argv[1]; t = open(p, newline="").read()
t = t.replace("\n## 2.10.1\n", "\r## 2.10.1\n", 1).replace("Released together: alpha 2.10.1, beta 1.0.1", "Released together: alpha 2.10.1, beta 1.0.0", 1)
open(p, "w", newline="").write(t)
PY2
  cm "a lone CR hides the top heading, and its line is edited"; rpc check
  eq "$RC" 1 "[C32] check: a lone CR before the top released heading, its line edited, is red"
  has "$OUT" "plugins/alpha/CHANGELOG.md \`## 2.10.1\`: the section that holds its \`Released together:\` line is gone" "[C32] …naming the section"
  gw checkout -q -b edit5 main; echo a5 >> "$W/plugins/alpha/a.txt"; cfw e.md alpha patch "alpha typo"
  python3 - "$W/plugins/alpha/CHANGELOG.md" <<'PY2'  # the input, not a break
import sys
p = sys.argv[1]; t = open(p).read()
t = t.replace("\n## 2.10.0\n", "\n## Older releases\n\n## 2.10.0\n", 1).replace("Released together: alpha 2.10.0, beta 1.0.1", "Released together: alpha 2.10.0, beta 1.0.0", 1)
open(p, "w").write(t)
PY2
  cm "a heading put above an older section, and its line edited"; rpc check
  eq "$RC" 1 "[C32] check: a non-version heading put above a released section hides nothing: its edited line is red"
  has "$OUT" "plugins/alpha/CHANGELOG.md \`## 2.10.0\`: its \`Released together:\` line changed" "[C32] …naming the section"
  gw checkout -q main; echo b5 >> "$W/plugins/beta/b.txt"; cfw b5.md beta patch "beta again"; cm "beta again"; gw push -q origin main; gw fetch -q origin
  gw checkout -q -b rel3; rp cut
  eq "$RC:$(grep -c '^Released together: alpha 2.10.1, beta 1.0.2$' "$W/plugins/beta/CHANGELOG.md")" "0:1" "[C33] a release of beta alone: its section names alpha 2.10.1"
  cm "release 3"; rp check
  eq "$RC" 0 "[C33] …and passes check"
  sed -i.bak 's/^Released together: alpha 2\.10\.1, beta 1\.0\.1$/Released together: alpha 2.10.1, beta 1.0.2/' "$W/plugins/alpha/CHANGELOG.md"  # the input, not a break
  rm -f "$W/plugins/alpha/CHANGELOG.md.bak"; cm "the release also moves alpha's floor"; rpc check
  eq "$RC" 1 "[C33] check: a release that also edits alpha's released line (alpha's version not moving) is red"
  has "$OUT" "plugins/alpha/CHANGELOG.md \`## 2.10.1\`: its \`Released together:\` line changed" "[C33] …naming alpha's section"
  # a first release: the line, and no paragraph to update a sibling (nothing was installed before)
  new_rel_repo; gw checkout -q main; mkdir -p "$W/plugins/gamma/.claude-plugin"
  printf '{\n  "name": "gamma",\n  "dependencies": ["beta"]\n}\n' > "$W/plugins/gamma/.claude-plugin/plugin.json"; echo g > "$W/plugins/gamma/g.txt"
  cfw g.md gamma patch "gamma arrives"
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["plugins"].append({"name": "gamma", "source": "./plugins/gamma"}); json.dump(d,open(p,"w"))' "$W/.claude-plugin/marketplace.json"
  cm "gamma"; gw push -q origin main; gw fetch -q origin; gw checkout -q rel; gw merge -q --ff-only main; rp plan
  has "$OUT" "plugin gamma: needs beta >=1.0.1" "[C34] plan: a first release needs beta's version"
  hasnt "$OUT" "plugin gamma: needs beta >=1.0.1 (was" "[C34] …with no \`was\` (nothing released before)"
  rp cut; cm "release"
  RC=0; OUT=$(cd "$W" && python3 "$RPY" notes gamma 0.1.0 --repo "$W" 2>&1) || RC=$?
  eq "$RC:$(printf '%s\n' "$OUT" | sed -n 1p)" "0:Released together: alpha 2.10.0, beta 1.0.1, gamma 0.1.0" "[C34] notes gamma 0.1.0: the plugins released together first"
  hasnt "$OUT" "This version needs" "[C34] …and no paragraph to update beta: a first release is not an update"
  # a first release whose CHANGELOG keeps an older `## 0.1.0` under its private history: that heading is not this release
  new_rel_repo; gw checkout -q main; setm delta; echo d > "$W/plugins/delta/d.txt"; cfw d.md delta patch "delta arrives"
  printf '# Changelog of delta\n\n## Private history\n\nNumbers below were private.\n\n## 0.1.0\n\n- patch: private start\n' > "$W/plugins/delta/CHANGELOG.md"
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["plugins"].append({"name": "delta", "source": "./plugins/delta"}); json.dump(d,open(p,"w"))' "$W/.claude-plugin/marketplace.json"
  cm "delta"; gw push -q origin main; gw fetch -q origin; gw checkout -q rel; gw merge -q --ff-only main; rp cut; cm "release"; rp check
  eq "$RC" 0 "[C35] a first release over a private \`## 0.1.0\` of the same number passes check (the cut's line is new, not an edit)"
  eq "$(cd "$W" && python3 "$RPY" bogus >/dev/null 2>&1; echo $?)" 64 "[C16] an unknown subcommand: rc 64"
  eq "$(cd "$W" && python3 "$RPY" check --hotfix >/dev/null 2>&1; echo $?)" 64 "[C16] check --hotfix: rc 64"
}

echo "-- fam_cut"; fam_cut "$PLUGIN/scripts/release.py"

# ── [F] cut --fold ─────────────────────────────────────────────────────────────────────────────────────────────────────
# new_fold_repo — new_rel_repo cut into a release on main (alpha 2.10.0 with an upgrade note, beta 1.0.1) and `release` moved to
# it, not published: the public repository P holds only alpha--v2.9.0 and beta--v1.0.0. Then two pending change files on main
# (alpha patch with an upgrade line, beta patch with one); W on branch fold.
new_fold_repo() {
  new_rel_repo
  cfwu a.md alpha minor "alpha does more" "Run alpha init once."; cm "an upgrade line"; rp cut; cm "release"
  gw checkout -q main; gw merge -q --ff-only rel; gw push -q origin main; gw push -q origin main:release
  echo a3 >> "$W/plugins/alpha/a.txt"; cfwu c.md alpha patch "alpha fixed again" "Re-run alpha init."; cm "alpha fix"
  echo b3 >> "$W/plugins/beta/b.txt"; cfwu d.md beta patch "beta faster" "Beta reads a new key."; cm "beta speed"
  gw push -q origin main; gw fetch -q origin; gw checkout -q -b fold
}
# lines <file> <line> — how many times <line> is a whole line of <file>
lines() { grep -cxF -- "$2" "$1"; }

fam_fold() { RPY=$1; local before
  new_fold_repo; before=$(tree_id); rp plan --fold --public "$P"
  eq "$RC" 0 "[F1] plan --fold: rc 0"
  has "$OUT" "plugin alpha: 2.10.0 -> 2.10.0 (fold, minor)" "[F1] …alpha joins its unpublished 2.10.0, a minor section"
  has "$OUT" "plugin beta: 1.0.1 -> 1.0.1 (fold, patch)" "[F1] …beta joins its 1.0.1"
  eq "$(tree_id)" "$before" "[F1] …and plan writes nothing"
  rp cut --fold --public "$P"
  eq "$RC" 0 "[F2] cut --fold: rc 0"
  eq "$(vof alpha) $(vof beta)" "2.10.0 1.0.1" "[F2] …no version moves"
  eq "$(ls "$W/.changes")" "README.md" "[F2] …the change files consumed"
  has "$(cat "$W/plugins/alpha/CHANGELOG.md")" "## 2.10.0

Released together: alpha 2.10.0, beta 1.0.1

- minor: alpha does more
- patch: alpha fixed again

### Upgrade notes

- Run alpha init once.
- Re-run alpha init.

## 2.9.0" "[F2] …alpha's lines after its own, its note under the Upgrade notes it had"
  has "$(cat "$W/plugins/beta/CHANGELOG.md")" "## 1.0.1

Released together: alpha 2.10.0, beta 1.0.1

- patch: beta is fixed
- patch: beta faster

### Upgrade notes

- Beta reads a new key.

## 1.0.0" "[F2] …beta's note under a heading made for it"
  eq "$(gw status --porcelain -- kb 'plugins/*/.claude-plugin/plugin.json')" "" "[F2] …no manifest and no kb page written"
  eq "$(grep -c '^Released together: ' "$W/plugins/alpha/CHANGELOG.md")" 1 "[F2] …the fold keeps the release's \`Released together:\` line and writes none"
  cm "fold"; rp check --public "$P"
  eq "$RC" 0 "[F3] the fold, committed, passes check --public"
  has "$OUT" "kind: fold" "[F3] …as a fold"
  NOPUB=1 rp check
  eq "$RC" 1 "[F4] check of a fold with no --public: red"
  has "$OUT" "a fold needs --public" "[F4] …and it says the publication was not read"
  pubtag alpha--v2.10.0; rp check --public "$P"
  eq "$RC" 1 "[F5] check of a fold into a published version: red"
  has "$OUT" "alpha 2.10.0 is published" "[F5] …naming the plugin and version"
  # a line already in the section, pending again, is written once
  new_fold_repo; cfw e.md alpha minor "alpha does more"; cm "the same line again"; rp cut --fold --public "$P"
  eq "$RC:$(lines "$W/plugins/alpha/CHANGELOG.md" "- minor: alpha does more")" "0:1" "[F6] a pending line the section holds is not written twice"
  cm "fold"; rp check --public "$P"
  eq "$RC" 0 "[F6] …and that fold passes check"
  # refusals
  new_fold_repo; pubtag alpha--v2.10.0; rp cut --fold --public "$P"
  eq "$RC" 1 "[F7] cut --fold into a published version: refused"
  has "$OUT" "alpha--v2.10.0" "[F7] …naming its tag"
  eq "$(gw status --porcelain)" "" "[F7] …and nothing written"
  new_fold_repo; rp cut --fold --public "$(dirname "$O")/nothing.git"
  eq "$RC" 1 "[F8] cut --fold when the public tags cannot be read: refused"
  has "$OUT" "cannot be read" "[F8] …and it says so"
  new_fold_repo; gw checkout -q main; setm gamma; echo g > "$W/plugins/gamma/g.txt"; cfw g.md gamma patch "gamma arrives"
  python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["plugins"].append({"name": "gamma", "source": "./plugins/gamma"}); json.dump(d,open(p,"w"))' "$W/.claude-plugin/marketplace.json"
  cm "gamma"; gw push -q origin main; gw checkout -q fold; gw merge -q --ff-only main; rp cut --fold --public "$P"
  eq "$RC" 1 "[F9] cut --fold of a plugin never released: refused"
  has "$OUT" "gamma was never released" "[F9] …naming it"
  new_fold_repo; gw checkout -q main; cfw f.md beta minor "beta gains a flag"; cm "beta minor"; gw push -q origin main
  gw checkout -q fold; gw merge -q --ff-only main; rp cut --fold --public "$P"
  eq "$RC" 1 "[F10] cut --fold of a minor into a patch section: refused"
  has "$OUT" "asks 1.1.0" "[F10] …naming the version it would ask"
  # the same fold written by hand is red in check
  python3 - "$W/plugins/beta/CHANGELOG.md" <<'PY2'
import sys
p = sys.argv[1]; t = open(p).read()
open(p, "w").write(t.replace("- patch: beta is fixed\n", "- patch: beta is fixed\n- patch: beta faster\n- minor: beta gains a flag\n\n"
                             "### Upgrade notes\n\n- Beta reads a new key.\n", 1))
PY2
  gw rm -q .changes/d.md .changes/f.md; cm "a hand fold"; rp check --public "$P"
  eq "$RC" 1 "[F11] check of a fold whose section asks another version: red"
  has "$OUT" "asks 1.1.0" "[F11] …naming the version it asks"
  # check: each part of a fold alone
  new_fold_repo; rp cut --fold --public "$P"; sed -i.bak '/^- minor: alpha does more$/d' "$W/plugins/alpha/CHANGELOG.md"; rm -f "$W/plugins/alpha/CHANGELOG.md.bak"
  cm "a line dropped"; rp check --public "$P"
  eq "$RC" 1 "[F12] check of a fold that drops a line of the base's section: red"
  has "$OUT" "drops 1 line" "[F12] …and it says so"
  new_fold_repo; rp cut --fold --public "$P"; gw checkout -q HEAD -- .changes/d.md; cm "a file left"; rp check --public "$P"
  eq "$RC" 1 "[F13] check of a fold that leaves a pending file: red"
  has "$OUT" ".changes/d.md is in .changes/" "[F13] …naming it"
  new_fold_repo; rp cut --fold --public "$P"; sed -i.bak 's/^- patch: alpha fixed again$/&\n&/' "$W/plugins/alpha/CHANGELOG.md"; rm -f "$W/plugins/alpha/CHANGELOG.md.bak"
  cm "a line twice"; rp check --public "$P"
  eq "$RC" 1 "[F14] check of a fold that writes a line twice: red"
  has "$OUT" "holds a line twice" "[F14] …and it says so"
  new_fold_repo; gw checkout -q main; gw rm -q .changes/d.md; cm "only alpha pending"; gw push -q origin main; gw checkout -q fold
  gw merge -q --ff-only main; rp cut --fold --public "$P"
  sed -i.bak 's/^- patch: beta is fixed$/&\n- patch: beta, unshipped/' "$W/plugins/beta/CHANGELOG.md"; rm -f "$W/plugins/beta/CHANGELOG.md.bak"
  cm "beta written too"; rp check --public "$P"
  eq "$RC" 1 "[F15] check of a fold that changes the CHANGELOG of a plugin it does not ship: red"
  has "$OUT" "no consumed change file names beta" "[F15] …naming it"
  # usage
  new_fold_repo
  rp cut --fold; eq "$RC" 64 "[F16] cut --fold without --public: rc 64"
  rp cut --fold --hotfix --public "$P"; eq "$RC" 64 "[F16] cut --fold --hotfix: rc 64"
  rp plan --hotfix --public "$P"; eq "$RC" 64 "[F16] plan --hotfix --public: rc 64"
  rp cut --fold --public -x; eq "$RC" 64 "[F16] a --public that starts with a dash: rc 64"
  rp check --fold; eq "$RC" 64 "[F16] check --fold: rc 64"
  eq "$(gw status --porcelain)" "" "[F16] …and nothing written"
  # check: an unreadable tag list, the release scope, a line no file ships, a line in the wrong part, an older section rewritten
  new_fold_repo; rp cut --fold --public "$P"; cm "fold"; rp check --public "$(dirname "$O")/nothing.git"
  eq "$RC" 1 "[F17] check of a fold when the public tags cannot be read: red"
  has "$OUT" "cannot be read" "[F17] …and it says so"
  new_fold_repo; rp cut --fold --public "$P"; echo more >> "$W/README.md"; cm "fold and a README line"; rp check --public "$P"
  eq "$RC" 1 "[F18] check of a fold that also changes another file: red"
  has "$OUT" "README.md: a release PR changes only" "[F18] …naming it"
  new_fold_repo; rp cut --fold --public "$P"; sed -i.bak 's/^- patch: alpha fixed again$/&\n- patch: invented/' "$W/plugins/alpha/CHANGELOG.md"; rm -f "$W/plugins/alpha/CHANGELOG.md.bak"
  cm "an invented line"; rp check --public "$P"
  eq "$RC" 1 "[F19] check of a fold that adds a line no change file ships: red"
  has "$OUT" "no consumed change file ships" "[F19] …and it says so"
  new_fold_repo; rp cut --fold --public "$P"
  python3 - "$W/plugins/alpha/CHANGELOG.md" <<'PY2'
import sys
p = sys.argv[1]; t = open(p).read()
t = t.replace("- patch: alpha fixed again\n", "", 1).replace("- Re-run alpha init.\n", "- Re-run alpha init.\n- patch: alpha fixed again\n", 1)
open(p, "w").write(t)
PY2
  cm "an entry under the notes"; rp check --public "$P"
  eq "$RC" 1 "[F20] check of a fold whose entry sits under Upgrade notes: red"
  has "$OUT" "lacks 1 shipped line" "[F20] …and it says so"
  new_fold_repo; rp cut --fold --public "$P"; sed -i.bak 's/^- minor: older$/- minor: older, reworded/' "$W/plugins/alpha/CHANGELOG.md"; rm -f "$W/plugins/alpha/CHANGELOG.md.bak"
  cm "an older section rewritten"; rp check --public "$P"
  eq "$RC" 1 "[F21] check of a fold that rewrites an older section: red"
  has "$OUT" "changes 1 line(s) outside its \`## 2.10.0\` section: the sections below it are frozen" "[F21] …and says the older sections are frozen"
  new_fold_repo; sed -i.bak 's/^## 2\.10\.0$/& /' "$W/plugins/alpha/CHANGELOG.md"; rm -f "$W/plugins/alpha/CHANGELOG.md.bak"; cm "a trailing space"
  rp cut --fold --public "$P"
  eq "$RC" 1 "[F22] cut --fold of a section whose heading carries a trailing space: refused"
  has "$OUT" "trailing spaces" "[F22] …with a reason, not a traceback"
  new_fold_repo; gw rm -q .changes/c.md .changes/d.md; cfw e.md alpha minor "alpha does more"; cm "only a line already shipped"
  rp cut --fold --public "$P"
  eq "$RC:$(gw status --porcelain)" "1:" "[F23] cut --fold that would change no CHANGELOG: refused, nothing written"
  has "$OUT" "nothing to fold" "[F23] …and it says so"
  new_fold_repo; rp cut --fold --public "$P"; sed -i.bak '/^- Re-run alpha init\.$/d' "$W/plugins/alpha/CHANGELOG.md"; rm -f "$W/plugins/alpha/CHANGELOG.md.bak"
  cm "a note dropped"; rp check --public "$P"
  eq "$RC" 1 "[F24] check of a fold that lacks an upgrade note: red"
  has "$OUT" "under \`### Upgrade notes\`" "[F24] …and it names the Upgrade notes"
  new_fold_repo; rp cut --fold --public "$P"; cm "fold"; sed -i.bak 's/^## 2\.10\.0$/& /' "$W/plugins/alpha/CHANGELOG.md"; rm -f "$W/plugins/alpha/CHANGELOG.md.bak"
  cm "a trailing space after the fold"; rp check --public "$P"
  eq "$RC" 1 "[F25] check of a fold whose heading carries a trailing space: red"
  has "$OUT" "trailing spaces" "[F25] …with a reason, not a traceback"
  new_fold_repo; rp cut --fold --public "$P"; sed -i.bak 's/^- patch: alpha fixed again$/&\nSome prose./' "$W/plugins/alpha/CHANGELOG.md"; rm -f "$W/plugins/alpha/CHANGELOG.md.bak"
  cm "a prose line"; rp check --public "$P"
  eq "$RC" 1 "[F26] check of a fold that adds a line of prose: red"
  has "$OUT" "gains 1 line(s) no consumed change file ships, first: Some prose." "[F26] …naming it"
  new_fold_repo; rp cut --fold --public "$P"
  python3 - "$W/plugins/alpha/CHANGELOG.md" <<'PY2'
import sys
p = sys.argv[1]; t = open(p).read()
t = t.replace("- minor: alpha does more\n", "", 1).replace("- Re-run alpha init.\n", "- Re-run alpha init.\n- minor: alpha does more\n", 1)
open(p, "w").write(t)
PY2
  cm "a base entry under the notes"; rp check --public "$P"
  eq "$RC" 1 "[F27] check of a fold that moves an entry of the base below Upgrade notes: red"
  has "$OUT" "moves 1 entry line" "[F27] …and it says so"
  # a base CHANGELOG with CRLF line ends and a blank line at its end: the cut writes LF, and check still passes it
  new_fold_repo; gw checkout -q main; printf '\n' >> "$W/plugins/alpha/CHANGELOG.md"; sed -i.bak 's/$/\r/' "$W/plugins/alpha/CHANGELOG.md"; rm -f "$W/plugins/alpha/CHANGELOG.md.bak"
  cm "CRLF"; gw push -q origin main; gw checkout -q fold; gw merge -q --ff-only main; rp cut --fold --public "$P"; cm "fold"; rp check --public "$P"
  eq "$RC" 0 "[F28] a fold of a CRLF CHANGELOG with a blank last line passes check"
  # a line of the unpublished section may be reworded (same level, same count); a published one stays frozen
  new_fold_repo; rp cut --fold --public "$P"; sed -i.bak 's/^- minor: alpha does more$/- minor: alpha does much more/' "$W/plugins/alpha/CHANGELOG.md"; rm -f "$W/plugins/alpha/CHANGELOG.md.bak"
  cm "an entry reworded"; rp check --public "$P"
  eq "$RC" 0 "[F29] check of a fold that rewords an entry of the unpublished section, same level: green"
  has "$OUT" "plugin alpha: rewords 1 line(s) of its unpublished \`## 2.10.0\` section: ok" "[F29] …and it says so"
  new_fold_repo; rp cut --fold --public "$P"; sed -i.bak 's/^- Run alpha init once\.$/- Run alpha init once, then restart./' "$W/plugins/alpha/CHANGELOG.md"; rm -f "$W/plugins/alpha/CHANGELOG.md.bak"
  cm "a note reworded"; rp check --public "$P"
  eq "$RC" 0 "[F30] check of a fold that rewords an upgrade note of the unpublished section: green"
  has "$OUT" "rewords 1 line(s)" "[F30] …and it says so"
  new_fold_repo; rp cut --fold --public "$P"; sed -i.bak 's/^- minor: alpha does more$/- patch: alpha does more/' "$W/plugins/alpha/CHANGELOG.md"; rm -f "$W/plugins/alpha/CHANGELOG.md.bak"
  cm "a level changed"; rp check --public "$P"
  eq "$RC" 1 "[F31] check of a fold that rewords an entry to another level: red"
  has "$OUT" "a reworded line keeps its \`- <level>:\`" "[F31] …and it names the level"
  new_fold_repo; rp cut --fold --public "$P"; sed -i.bak 's/^- minor: alpha does more$/- minor: alpha does much more/' "$W/plugins/alpha/CHANGELOG.md"; rm -f "$W/plugins/alpha/CHANGELOG.md.bak"
  cm "an entry reworded"; pubtag alpha--v2.10.0; rp check --public "$P"
  eq "$RC" 1 "[F32] check of a reword in a published section: red"
  has "$OUT" "its section is frozen, this change rewords 1 of its line(s)" "[F32] …and it says the section is frozen"
  hasnt "$OUT" "rewords 1 line(s) of its unpublished" "[F32] …and prints no reword ok next to the red"
  new_fold_repo; rp cut --fold --public "$P"
  python3 - "$W/plugins/alpha/CHANGELOG.md" <<'PY2'
import sys
p = sys.argv[1]; t = open(p).read()
t = t.replace("- minor: alpha does more\n", "- minor: alpha does much more\n", 1).replace("- Run alpha init once.\n", "", 1)
open(p, "w").write(t)
PY2
  cm "a reword and a note dropped"; rp check --public "$P"
  eq "$RC" 1 "[F33] check of a fold that rewords a line and drops another: red"
  has "$OUT" "drops 2 line(s)" "[F33] …a count that moved accepts no reword: both base lines are named as dropped"
  # a base section that already holds a pending line (the cut writes it once): another line of it may still be reworded
  new_fold_repo; gw checkout -q main; sed -i.bak 's/^- minor: alpha does more$/&\n- patch: alpha polish/' "$W/plugins/alpha/CHANGELOG.md"; rm -f "$W/plugins/alpha/CHANGELOG.md.bak"
  cfw e.md alpha minor "alpha does more"; cm "a second entry, and a pending line 2.10.0 holds"; gw push -q origin main; gw checkout -q fold; gw merge -q --ff-only main
  rp cut --fold --public "$P"; sed -i.bak 's/^- patch: alpha polish$/- patch: alpha polished/' "$W/plugins/alpha/CHANGELOG.md"; rm -f "$W/plugins/alpha/CHANGELOG.md.bak"
  cm "a reword next to a line the base held"; rp check --public "$P"
  eq "$RC" 0 "[F34] check of a reword in a section that already held a pending line: green"
  has "$OUT" "rewords 1 line(s)" "[F34] …and it says so"
  new_fold_repo; rp cut --fold --public "$P"; sed -i.bak 's/^Newest first\.$/&\nAn added line./' "$W/plugins/alpha/CHANGELOG.md"; rm -f "$W/plugins/alpha/CHANGELOG.md.bak"
  cm "one line added above the sections"; rp check --public "$P"
  eq "$RC" 1 "[F35] check of a fold that adds a line outside its section: red"
  has "$OUT" "changes 1 line(s) outside" "[F35] …and counts that one line"
  new_fold_repo; rp cut --fold --public "$P"
  sed -i.bak 's/^Released together: alpha 2\.10\.0, beta 1\.0\.1$/&\n&/' "$W/plugins/alpha/CHANGELOG.md"; rm -f "$W/plugins/alpha/CHANGELOG.md.bak"  # the input, not a break
  cm "the line twice in a fold"; rpc check --public "$P"
  eq "$RC" 1 "[F36] check of a fold that writes the \`Released together:\` line twice (the export refuses that section): red"
  has "$OUT" "its \`Released together:\` line changed" "[F36] …naming the line"
}

echo "-- fam_fold"; fam_fold "$PLUGIN/scripts/release.py"

# ── [M] the final state ────────────────────────────────────────────────────────────────────────────────────────────────
# new_unpub_repo — new_rel_repo cut into a release on main (alpha 2.10.0, beta 1.0.1, from a.md and b.md), `release` moved to it,
# not published (P holds alpha--v2.9.0 and beta--v1.0.0 only); W on branch nx at main's tip
new_unpub_repo() {
  new_rel_repo; rp cut; cm "release"
  gw checkout -q main; gw merge -q --ff-only rel; gw push -q origin main; gw push -q origin main:release; gw fetch -q origin
  gw checkout -q -b nx
}
# pend <file> <frontmatter lines, \n-joined> <line> — a change file merged into main, so it is pending on the base; W back on its
# branch at main's tip
pend() {
  local b; b=$(gw rev-parse --abbrev-ref HEAD); gw checkout -q main
  printf -- '---\n%b\n---\n%s\n' "$2" "$3" > "$W/.changes/$1"; echo "$1" >> "$W/plugins/alpha/a.txt"; cm "pend $1"
  gw push -q origin main; gw fetch -q origin; gw checkout -q "$b"; gw merge -q --ff-only main
}
# sec <plugin> <version> — the lines of its `## <version>` section
sec() { sed -n "/^## $2\$/,/^## /p" "$W/plugins/$1/CHANGELOG.md" | sed '1d;$d'; }
# heads <plugin> — its CHANGELOG's version headings, one line
heads() { sed -n 's/^## \([0-9]\)/\1/p' "$W/plugins/$1/CHANGELOG.md" | tr '\n' ' '; }
# onmain <python on t> — edit alpha's CHANGELOG on main and push (an input the test builds, not a break), W back on its branch
onmain() {
  local b; b=$(gw rev-parse --abbrev-ref HEAD); gw checkout -q main
  python3 -c 'import sys; p=sys.argv[1]; t=open(p).read(); exec(sys.argv[2]); open(p,"w").write(t)' "$W/plugins/alpha/CHANGELOG.md" "$1"
  cm "main edits alpha"; gw push -q origin main; gw fetch -q origin; gw checkout -q "$b"; gw merge -q --ff-only main
}

fam_final() { RPY=$1
  # a release over an unpublished alpha 2.10.0 (beta's 1.0.1 published): alpha's new section joins it, beta's stands on 1.0.1
  new_unpub_repo; pubtag beta--v1.0.1
  pend c.md 'plugins: alpha\nlevel: patch' "alpha again"; pend e.md 'plugins: beta\nlevel: patch' "beta again"; rp plan
  eq "$RC" 0 "[M1] plan over an unpublished alpha 2.10.0: rc 0"
  has "$OUT" "plugin alpha: 2.10.0 -> 2.10.1 (patch)" "[M1] …alpha one patch above its top"
  has "$OUT" "plugin alpha: joins its unpublished \`## 2.10.0\` section, which goes" "[M1] …and it says alpha 2.10.0 joins"
  hasnt "$OUT" "plugin beta: joins" "[M1] …beta's published 1.0.1 joins nothing"
  rp cut
  eq "$RC:$(heads alpha)" "0:2.10.1 2.9.0 " "[M1] cut: alpha 2.10.1 right above the published 2.9.0, no 2.10.0 left"
  eq "$(sec alpha 2.10.1)" "
Released together: alpha 2.10.1, beta 1.0.2

- minor: alpha does more
- patch: alpha again" "[M1] …its section holds 2.10.0's line, then the pending one (oldest first)"
  eq "$(heads beta)" "1.0.2 1.0.1 1.0.0 " "[M1] …beta 1.0.2 above its published 1.0.1"
  cm "release"; rp check
  eq "$RC" 0 "[M1] check --public passes it as a release"
  has "$OUT" "plugin alpha: 2.10.0 -> 2.10.1 (patch), 2 line(s) in its CHANGELOG: ok, joins unpublished 2.10.0" "[M1] …naming what joined"
  RC=0; OUT=$(cd "$W" && python3 "$RPY" notes alpha 2.10.1 --repo "$W" 2>&1) || RC=$?
  has "$OUT" "- minor: alpha does more
- patch: alpha again" "[M1] notes of alpha 2.10.1: the joined section"
  sed -i.bak '/^- minor: alpha does more$/d' "$W/plugins/alpha/CHANGELOG.md"; rm -f "$W/plugins/alpha/CHANGELOG.md.bak"  # the input, not a break
  cm "a joined line lost"; rpc check
  eq "$RC" 1 "[M2] check: a line of the joined section lost, with no mark: red"
  has "$OUT" "lacks 1 shipped line(s), first: - minor: alpha does more" "[M2] …naming it"
  gw reset -q --hard HEAD~1; sed -i.bak 's/^- patch: alpha again$/&\n&/' "$W/plugins/alpha/CHANGELOG.md"; rm -f "$W/plugins/alpha/CHANGELOG.md.bak"
  cm "a line twice"; rpc check
  eq "$RC" 1 "[M2] check: a line twice: red"
  has "$OUT" "holds a line twice: - patch: alpha again" "[M2] …naming it"
  # a release cut the earlier way, its unpublished 2.10.0 left standing below
  new_unpub_repo; pend c.md 'plugins: alpha\nlevel: patch' "alpha again"
  python3 -c 'import sys; p=sys.argv[1]; t=open(p).read(); i=t.index("## 2.10.0"); open(p,"w").write(t[:i] + "## 2.10.1\n\nReleased together: alpha 2.10.1, beta 1.0.1\n\n- patch: alpha again\n\n" + t[i:])' "$W/plugins/alpha/CHANGELOG.md"  # the input, not a break
  gw rm -q .changes/c.md; cm "a release over an unpublished one"; rpc check
  eq "$RC" 1 "[M3] check: a release that leaves an unpublished section below the top: red"
  has "$OUT" "plugins/alpha/CHANGELOG.md \`## 2.10.0\` is cut and not published, below the top section" "[M3] …naming it"
  # no --public: plan and cut refuse, check of a release is red
  new_rel_repo; before=$(tree_id); NOPUB=1 rp plan
  eq "$RC" 1 "[M4] plan with no --public: rc 1"
  has "$OUT" "name it with --public <repo>" "[M4] …and it says to name the public repository"
  NOPUB=1 rp cut
  eq "$RC:$(tree_id)" "1:$before" "[M4] cut with no --public: refused, nothing written"
  rp cut; cm "release"; NOPUB=1 rpc check
  eq "$RC" 1 "[M4] check of a release with no --public: red"
  has "$OUT" "a release needs --public <repo>" "[M4] …and it says the publication was not read"
  # supersedes: inside the span, a chain, a CRLF file, a line with letters beyond ASCII
  new_rel_repo; pend p.md 'plugins: alpha\nlevel: minor\nupgrade: Run alpha knob init.' "alpha has a knob"
  pend q.md 'plugins: alpha\nlevel: minor\nsupersedes: p' "alpha has a better knob"
  printf -- '---\r\nplugins: alpha\r\nlevel: minor\r\nsupersedes: q\r\n---\r\nalpha has the knob ñ-ü 中\r\n' > "$W/r.md"
  gw checkout -q main; mv "$W/r.md" "$W/.changes/r.md"; cm "pend r"; gw push -q origin main; gw fetch -q origin; gw checkout -q rel; gw merge -q --ff-only main
  rp plan
  has "$OUT" "plugin alpha: takes out (superseded by q): - minor: alpha has a knob" "[M5] plan names each line a supersedes: takes out"
  has "$OUT" "plugin alpha: takes out (superseded by r): - minor: alpha has a better knob" "[M5] …down the chain"
  rp cut
  eq "$RC" 0 "[M5] cut with a chain p <- q <- r: rc 0"
  eq "$(sec alpha 2.10.0)" "
Released together: alpha 2.10.0, beta 1.0.1

- minor: alpha does more
- minor: alpha has the knob ñ-ü 中" "[M5] …only the last of the chain is written, and p's upgrade note goes with p"
  cm "release"; rp check
  eq "$RC" 0 "[M5] check --public passes it"
  printf '%s\n' '- minor: alpha has a knob' >> "$W/plugins/alpha/CHANGELOG.md.l"; python3 -c 'import sys; p=sys.argv[1]; t=open(p).read(); open(p,"w").write(t.replace("- minor: alpha does more\n", "- minor: alpha does more\n- minor: alpha has a knob\n", 1))' "$W/plugins/alpha/CHANGELOG.md"; rm -f "$W/plugins/alpha/CHANGELOG.md.l"  # the input, not a break
  cm "a superseded line put back"; rpc check
  eq "$RC" 1 "[M5] check: a superseded line left in: red"
  has "$OUT" "still holds a line that goes (superseded by q): - minor: alpha has a knob" "[M5] …naming it and why"
  # cancels: everything it cancels is in the span (one in an unpublished section, one pending); its own line goes too, in every
  # plugin it names (beta never had the knob)
  new_unpub_repo; pend k.md 'plugins: alpha\nlevel: minor\nupgrade: Run alpha knob init.' "alpha has a knob"
  pend z.md 'plugins: alpha, beta\nlevel: patch\ncancels: a, k' "the knob and the more are gone"
  pend w.md 'plugins: alpha, beta\nlevel: patch' "alpha and beta log less"; rp cut
  eq "$RC" 0 "[M6] cut with a cancels: of an unpublished line and a pending one: rc 0"
  eq "$(sec alpha 2.11.0)" "
Released together: alpha 2.11.0, beta 1.0.2

- patch: alpha and beta log less" "[M6] …alpha keeps neither the cancelled lines, their note, nor the cancelling line (the level is still the highest named)"
  eq "$(sec beta 1.0.2)" "
Released together: alpha 2.11.0, beta 1.0.2

- patch: beta is fixed
- patch: alpha and beta log less" "[M6] …beta (its unpublished 1.0.1 joined) has no cancelling line either"
  cm "release"; rp check
  eq "$RC" 0 "[M6] check --public passes it"
  # cancels: of a published change keeps its own line (a user loses something); the in-span one goes
  new_unpub_repo; pubtag alpha--v2.10.0; pubtag beta--v1.0.1
  pend s.md 'plugins: alpha\nlevel: patch' "alpha logs more"
  pend z.md 'plugins: alpha\nlevel: patch\ncancels: a, s' "alpha no longer does more"; rp cut
  eq "$RC" 0 "[M7] cut with a cancels: of a published line and a pending one: rc 0"
  eq "$(sec alpha 2.10.1)" "
Released together: alpha 2.10.1, beta 1.0.1

- patch: alpha no longer does more" "[M7] …the cancelling line stays, the pending cancelled one goes"
  has "$(sec alpha 2.10.0)" "- minor: alpha does more" "[M7] …and the published section is untouched"
  cm "release"; rp check
  eq "$RC" 0 "[M7] check --public passes it"
  # a line already published is not written again
  new_rel_repo; pend d.md 'plugins: alpha\nlevel: minor' "older"; rp plan
  has "$OUT" "plugin alpha: takes out (already published): - minor: older" "[M8] plan: a pending line already published is taken out"
  rp cut; eq "$(lines "$W/plugins/alpha/CHANGELOG.md" "- minor: older")" 1 "[M8] cut: the line stays only in the published 2.9.0"
  cm "release"; rp check; eq "$RC" 0 "[M8] check --public passes it"
  python3 -c 'import sys; p=sys.argv[1]; t=open(p).read(); open(p,"w").write(t.replace("- minor: alpha does more\n", "- minor: alpha does more\n- minor: older\n", 1))' "$W/plugins/alpha/CHANGELOG.md"  # the input, not a break
  cm "the published line again"; rpc check
  eq "$RC" 1 "[M8] check: a line already published, written again: red"
  has "$OUT" "still holds a line that goes (already published): - minor: older" "[M8] …naming it"
  # a named line reworded in an unpublished section: cut and check refuse, naming the change
  new_unpub_repo; onmain 't = t.replace("- minor: alpha does more", "- minor: alpha does much more")'
  pend y.md 'plugins: alpha\nlevel: patch\nsupersedes: a' "alpha does the most"; before=$(tree_id); rp cut
  eq "$RC:$(tree_id)" "1:$before" "[M9] cut: a superseded line reworded in the unpublished section: refused, nothing written"
  has "$OUT" "the line of a, which y names, is in no section as written (was it reworded?)" "[M9] …naming the change"
  python3 -c 'import sys; p=sys.argv[1]; t=open(p).read(); i=t.index("## 2.9.0"); j=t.index("## 2.10.0"); open(p,"w").write(t[:j] + "## 2.10.1\n\nReleased together: alpha 2.10.1, beta 1.0.1\n\n- patch: alpha does the most\n\n" + t[i:])' "$W/plugins/alpha/CHANGELOG.md"  # the input, not a break
  gw rm -q .changes/y.md; cm "a release by hand"; rpc check
  eq "$RC" 1 "[M9] check: the same, red"
  has "$OUT" "the line of a, which y names, is in no section as written (was it reworded?)" "[M9] …naming the change"
  # two pending files carry the same upgrade note and one is superseded: the other's note stays, once
  new_rel_repo; pend g1.md 'plugins: alpha\nlevel: patch\nupgrade: Run alpha install --update.' "alpha gate one"
  pend g2.md 'plugins: alpha\nlevel: patch\nupgrade: Run alpha install --update.' "alpha gate two"
  pend g3.md 'plugins: alpha\nlevel: patch\nsupersedes: g1' "alpha gate one, final"; rp cut
  eq "$RC:$(lines "$W/plugins/alpha/CHANGELOG.md" "- Run alpha install --update.")" "0:1" "[M11] cut: a note two files share stays, once, when one of them is superseded"
  hasnt "$(sec alpha 2.10.0)" "- patch: alpha gate one
" "[M11] …and the superseded line goes"
  cm "release"; rp check; eq "$RC" 0 "[M11] check --public passes it"
  # a line published in 2.10.0 and written again in an unpublished 2.10.1 (cut the earlier way): cancelling it is a removal users see
  new_unpub_repo; pubtag alpha--v2.10.0; pubtag beta--v1.0.1
  onmain 'i = t.index("## 2.10.0"); t = t[:i] + "## 2.10.1\n\nReleased together: alpha 2.10.1, beta 1.0.1\n\n- minor: alpha does more\n\n" + t[i:]'
  pend z.md 'plugins: alpha\nlevel: patch\ncancels: a' "alpha no longer does more"; rp cut
  eq "$RC:$(heads alpha)" "0:2.10.2 2.10.0 2.9.0 " "[M12] cut: 2.10.2 joins the unpublished 2.10.1"
  eq "$(sec alpha 2.10.2)" "
Released together: alpha 2.10.2, beta 1.0.1

- patch: alpha no longer does more" "[M12] …the copy of the published line goes, the cancelling line stays"
  cm "release"; rp check; eq "$RC" 0 "[M12] check --public passes it"
  # a fold joins a lower unpublished section (one cut the earlier way) into the top one, which keeps its version
  new_unpub_repo
  onmain 'i = t.index("## 2.10.0"); t = t[:i] + "## 2.11.0\n\nReleased together: alpha 2.11.0, beta 1.0.1\n\n- minor: alpha grows\n\n" + t[i:]'
  pend f.md 'plugins: alpha\nlevel: patch' "alpha fixed"; rp plan --fold --public "$P"
  has "$OUT" "plugin alpha: 2.11.0 -> 2.11.0 (fold, minor)" "[M10] plan --fold: alpha keeps 2.11.0"
  has "$OUT" "plugin alpha: joins its unpublished \`## 2.10.0\` section, which goes" "[M10] …and 2.10.0 joins it"
  rp cut --fold --public "$P"
  eq "$RC:$(heads alpha)" "0:2.11.0 2.9.0 " "[M10] cut --fold: 2.11.0 right above the published 2.9.0"
  eq "$(sec alpha 2.11.0)" "
Released together: alpha 2.11.0, beta 1.0.1

- minor: alpha does more
- minor: alpha grows
- patch: alpha fixed" "[M10] …its section: 2.10.0's line, its own, then the folded one, under its own Released together: line"
  cm "fold"; rp check --public "$P"
  eq "$RC" 0 "[M10] check --public passes it as a fold"
  has "$OUT" "kind: fold" "[M10] …as a fold"
  # a second fold into the joined section: its version stays (it stands two steps above the published 2.9.0 now)
  gw checkout -q main; gw merge -q --ff-only nx; gw push -q origin main; gw push -q origin main:release; gw fetch -q origin
  gw checkout -q -b nx2; pend g.md 'plugins: alpha\nlevel: patch' "alpha fixed twice"; rp cut --fold --public "$P"
  eq "$RC:$(heads alpha)" "0:2.11.0 2.9.0 " "[M13] a later fold into a joined section keeps 2.11.0"
  cm "fold 2"; rp check --public "$P"; eq "$RC" 0 "[M13] check --public passes it"
  # a public repository that holds no tag of alpha (another repository): refused, never read as all unpublished
  new_unpub_repo; E="$(dirname "$O")/beta-only.git"; git_ init -q --bare -b main "$E"; gw push -q "$E" main~3:refs/tags/beta--v1.0.0
  pend c.md 'plugins: alpha\nlevel: patch' "alpha again"
  before=$(tree_id); rp plan --public "$E"
  eq "$RC" 1 "[M14] plan with a public repository holding no tag of alpha: rc 1"
  has "$OUT" "the public repository holds no tag alpha--v<version>: is --public the repository alpha is published to?" "[M14] …saying why"
  rp cut --public "$E"; eq "$RC:$(tree_id)" "1:$before" "[M14] cut: refused, nothing written (2.9.0, published, stays)"
  rp cut; cm "release"; rpc check --public "$E"
  eq "$RC" 1 "[M14] check with that repository: red"
  has "$OUT" "is --public the repository alpha is published to?" "[M14] …saying why"
  new_rel_repo; rp plan --public "$(dirname "$O")/nothing.git"
  eq "$RC" 1 "[M15] plan of a release whose tag list cannot be read: rc 1"
  has "$OUT" "cannot be read" "[M15] …saying so"
  rp cut; cm "release"; rpc check --public "$(dirname "$O")/nothing.git"
  eq "$RC" 1 "[M15] check of a release whose tag list cannot be read: red"
  # a plugin the cut does not name keeps no stack of unpublished sections (alpha 2.11.0 over 2.10.0, a release of beta alone)
  new_unpub_repo
  onmain 'i = t.index("## 2.10.0"); t = t[:i] + "## 2.11.0\n\nReleased together: alpha 2.11.0, beta 1.0.1\n\n- minor: alpha grows\n\n" + t[i:]'
  pend e.md 'plugins: beta\nlevel: patch' "beta again"; before=$(tree_id); rp cut
  eq "$RC:$(tree_id)" "1:$before" "[M16] cut naming beta alone while alpha has 2.11.0 over an unpublished 2.10.0: refused"
  has "$OUT" "plugin alpha has \`## 2.10.0\` cut and not published below its top \`## 2.11.0\`: name it in a change file" "[M16] …saying how"
  python3 -c 'import sys; p=sys.argv[1]; t=open(p).read(); t=t.replace("## 1.0.1\n\nReleased together: alpha 2.10.0, beta 1.0.1\n\n- patch: beta is fixed\n", "## 1.0.2\n\nReleased together: alpha 2.11.0, beta 1.0.2\n\n- patch: beta is fixed\n- patch: beta again\n"); open(p,"w").write(t)' "$W/plugins/beta/CHANGELOG.md"  # the input, not a break
  gw rm -q .changes/e.md; cm "a release of beta by hand"; rpc check
  eq "$RC" 1 "[M16] check: a release of beta that leaves alpha's stack: red"
  has "$OUT" "plugins/alpha/CHANGELOG.md \`## 2.10.0\` is cut and not published, below the top section" "[M16] …naming it"
  # a release of beta that also takes out alpha's unpublished 2.10.0 by hand: red (only a section the release joins may go)
  new_unpub_repo; pend e.md 'plugins: beta\nlevel: patch' "beta again"; rp cut
  python3 -c 'import sys; p=sys.argv[1]; t=open(p).read(); i=t.index("## 2.10.0"); j=t.index("## 2.9.0"); open(p,"w").write(t[:i] + t[j:])' "$W/plugins/alpha/CHANGELOG.md"  # the input, not a break
  cm "beta released, alpha's 2.10.0 dropped by hand"; rpc check
  eq "$RC" 1 "[M17] check: an unpublished section of a plugin the release does not raise, taken out: red"
  has "$OUT" "plugins/alpha/CHANGELOG.md \`## 2.10.0\`: the section that holds its \`Released together:\` line is gone" "[M17] …naming it"
  # every pending line of beta is taken out: beta is not raised, its files are consumed; when every line goes, nothing is cut
  new_rel_repo; pend x.md 'plugins: beta\nlevel: patch\ncancels: b' "beta is not fixed after all"; rp plan
  has "$OUT" "plugin beta: every pending line of it is taken out" "[M18] plan: beta's lines all go"
  rp cut
  eq "$RC:$(heads beta)" "0:1.0.0 " "[M18] cut: beta stays 1.0.0"
  has "$(sec alpha 2.10.0)" "Released together: alpha 2.10.0, beta 1.0.0" "[M18] …and alpha's section names it at 1.0.0"
  cm "release"; rp check
  eq "$RC" 0 "[M18] check --public passes it"
  has "$OUT" "plugin beta: every pending line of it is taken out: not raised, ok" "[M18] …saying beta is not raised"
  new_rel_repo; pend x.md 'plugins: alpha, beta\nlevel: patch\ncancels: a, b' "nothing after all"; before=$(tree_id); rp cut
  eq "$RC:$(tree_id)" "1:$before" "[M18] cut: every pending line taken out: refused, nothing written"
  has "$OUT" "nothing to release" "[M18] …saying so"
  # a release section holding a line no change ships, prose included: red
  new_unpub_repo; pend c.md 'plugins: alpha\nlevel: patch' "alpha again"; rp cut
  python3 -c 'import sys; p=sys.argv[1]; t=open(p).read(); open(p,"w").write(t.replace("- patch: alpha again\n", "- patch: alpha again\nSome prose.\n", 1))' "$W/plugins/alpha/CHANGELOG.md"  # the input, not a break
  cm "prose in the section"; rpc check
  eq "$RC" 1 "[M19] check: a release section with a prose line: red"
  has "$OUT" "gains 1 line(s) no change ships, first: Some prose." "[M19] …naming it"
  # a pending file naming a change that does not exist: the cut refuses (the ordinary check would have been red)
  new_rel_repo; pend y.md 'plugins: alpha\nlevel: patch\nsupersedes: nope' "alpha"; rp plan
  eq "$RC" 1 "[M20] plan: a pending supersedes: of a change that does not exist: rc 1"
  has "$OUT" "nope is no change file of this repository" "[M20] …naming it"
  # after a join, notes compare the floor with the published section below (alpha depends on beta)
  new_rel_repo; gw checkout -q main; printf '{\n  "name": "alpha",\n  "dependencies": ["beta"]\n}\n' > "$W/plugins/alpha/.claude-plugin/plugin.json"
  cm "alpha needs beta"; gw push -q origin main; gw checkout -q rel; gw merge -q --ff-only main; rp cut; cm "release"
  gw checkout -q main; gw merge -q --ff-only rel; gw push -q origin main; gw push -q origin main:release; gw fetch -q origin
  pubtag beta--v1.0.1; gw checkout -q -b nx; pend c.md 'plugins: alpha\nlevel: patch' "alpha again"; rp cut; cm "release 2"
  RC=0; OUT=$(cd "$W" && python3 "$RPY" notes alpha 2.10.1 --repo "$W" 2>&1) || RC=$?
  has "$OUT" "This version needs beta 1.0.1 or later" "[M21] notes of alpha 2.10.1 (2.10.0 joined): the floor moved since the published 2.9.0"
  # a change published in 2.10.0 and repeated, line and note, in an unpublished 2.10.1: superseding it takes the copy's note too
  new_rel_repo; pend n.md 'plugins: alpha\nlevel: minor\nupgrade: Run alpha n.' "alpha n"; rp cut; cm "release"
  gw checkout -q main; gw merge -q --ff-only rel; gw push -q origin main; gw push -q origin main:release; gw fetch -q origin
  pubtag alpha--v2.10.0; pubtag beta--v1.0.1; gw checkout -q -b nx
  onmain 't = t.replace("- Run alpha n.", "- Re-run alpha n by hand."); i = t.index("## 2.10.0"); t = t[:i] + "## 2.10.1\n\nReleased together: alpha 2.10.1, beta 1.0.1\n\n- minor: alpha n\n\n### Upgrade notes\n\n- Run alpha n.\n\n" + t[i:]'
  pend z.md 'plugins: alpha\nlevel: patch\nsupersedes: n' "alpha n, final"; rp cut
  eq "$RC:$(sec alpha 2.10.2)" "0:
Released together: alpha 2.10.2, beta 1.0.1

- patch: alpha n, final" "[M22] cut: the repeated copy of a published change goes with its note"
  cm "release"; rp check; eq "$RC" 0 "[M22] check --public passes it"
  # a superseded change's upgrade note, reworded in its unpublished section: refused, never left in silently
  new_rel_repo; pend k.md 'plugins: alpha\nlevel: minor\nupgrade: Run alpha knob init.' "alpha has a knob"; rp cut; cm "release"
  gw checkout -q main; gw merge -q --ff-only rel; gw push -q origin main; gw push -q origin main:release; gw fetch -q origin
  gw checkout -q -b nx; onmain 't = t.replace("- Run alpha knob init.", "- Run alpha knob init, twice.")'
  pend z.md 'plugins: alpha\nlevel: patch\nsupersedes: k' "alpha has a better knob"; before=$(tree_id); rp cut
  eq "$RC:$(tree_id)" "1:$before" "[M23] cut: a superseded change whose note a fold reworded: refused, nothing written"
  has "$OUT" "the upgrade note of k, which z names, is in no section as written (was it reworded?)" "[M23] …naming it"
  # a plugin whose only pending line is already published but brings an upgrade note: refused, the note is not lost
  new_rel_repo; gw checkout -q main; gw rm -q .changes/b.md; cm "no b"; gw push -q origin main; gw fetch -q origin; gw checkout -q rel
  gw merge -q --ff-only main; pend d.md 'plugins: beta\nlevel: patch\nupgrade: Run beta d.' "earlier"; before=$(tree_id); rp cut
  eq "$RC:$(tree_id)" "1:$before" "[M24] cut: beta's only line already published, with a new upgrade note: refused"
  has "$OUT" "plugin beta: every line of it is taken out (already published) but 1 upgrade note(s) remain" "[M24] …saying why"
  # pending files that supersede one another in a ring of three: refused, not every line dropped
  new_rel_repo; pend p.md 'plugins: alpha\nlevel: patch\nsupersedes: q' "alpha p"; pend q.md 'plugins: alpha\nlevel: patch\nsupersedes: r' "alpha q"
  pend r.md 'plugins: alpha\nlevel: patch\nsupersedes: p' "alpha r"; rp plan
  eq "$RC" 1 "[M25] plan: three pending files that supersede one another in a ring: rc 1"
  has "$OUT" "the pending change files p, q, r supersede or cancel one another in a ring" "[M25] …naming them"
  # a public repository with no tag of any plugin here, each plugin with one released version: refused, the published 2.9.0 stays
  new_rel_repo; E="$(dirname "$O")/empty.git"; git_ init -q --bare -b main "$E"; before=$(tree_id); rp plan --public "$E"
  eq "$RC" 1 "[M26] plan with a public repository that holds no tag of any plugin here: rc 1"
  has "$OUT" "the public repository holds no tag of any plugin here (alpha, beta)" "[M26] …saying why"
  rp cut --public "$E"; eq "$RC:$(tree_id)" "1:$before" "[M26] cut: refused, nothing written"
  rp cut; cm "release"; rpc check --public "$E"
  eq "$RC" 1 "[M26] check with that repository: red"
  has "$OUT" "the public repository holds no tag of any plugin here" "[M26] …saying why"
  # a fold where beta's pending lines all go and its top is published: beta is not touched, and the fold passes its check
  new_unpub_repo; pubtag beta--v1.0.1; pend f.md 'plugins: alpha\nlevel: patch' "alpha fixed"
  pend y.md 'plugins: beta\nlevel: patch' "beta y"; pend x.md 'plugins: beta\nlevel: patch\ncancels: y' "beta without y"
  rp cut --fold --public "$P"
  eq "$RC:$(heads beta)" "0:1.0.1 1.0.0 " "[M27] cut --fold: beta, its lines all gone, keeps 1.0.1"
  cm "fold"; rp check --public "$P"
  eq "$RC" 0 "[M27] check --public passes the fold"
  has "$OUT" "plugin beta: every pending line of it is taken out: not folded, ok" "[M27] …saying beta is not folded"
  # a mark without the leading date, at the cut: the dated file's line goes; two dated files that match: refused, naming both
  new_rel_repo; pend 2026-01-05-k.md 'plugins: alpha\nlevel: minor' "alpha has a knob"; pend z.md 'plugins: alpha\nlevel: minor\nsupersedes: k' "alpha has a better knob"
  rp cut
  eq "$RC:$(lines "$W/plugins/alpha/CHANGELOG.md" "- minor: alpha has a knob")" "0:0" "[M28] cut: an undated mark takes out the dated file's line"
  cm "release"; rp check; eq "$RC" 0 "[M28] check --public passes it"
  new_rel_repo; pend 2026-01-05-d.md 'plugins: alpha\nlevel: patch' "alpha d one"; pend 2026-01-06-d.md 'plugins: alpha\nlevel: patch' "alpha d two"
  pend z.md 'plugins: alpha\nlevel: patch\nsupersedes: d' "alpha d, final"; rp plan
  eq "$RC" 1 "[M29] plan: an undated mark that two pending files match: rc 1"
  has "$OUT" "d matches 2 change files (2026-01-05-d, 2026-01-06-d)" "[M29] …naming both"
  has "$OUT" "z: d matches" "[M29b] …and the file that holds the mark"
  # dated pending files that supersede each other, written without their dates: refused at the cut
  new_rel_repo; pend 2026-01-07-p.md 'plugins: alpha\nlevel: patch\nsupersedes: q' "alpha p"; pend 2026-01-08-q.md 'plugins: alpha\nlevel: patch\nsupersedes: p' "alpha q"
  rp plan
  eq "$RC" 1 "[M30] plan: dated pending files that supersede each other undated: rc 1"
  has "$OUT" "the pending change files 2026-01-07-p, 2026-01-08-q supersede or cancel one another in a ring" "[M30] …naming them"
  # an undated mark of a consumed change file whose line sits in an unpublished section: taken out at the cut, and the check passes
  new_rel_repo; pend 2026-01-09-n.md 'plugins: alpha\nlevel: minor\nupgrade: Run alpha n.' "alpha n"; rp cut; cm "release"
  gw checkout -q main; gw merge -q --ff-only rel; gw push -q origin main; gw push -q origin main:release; gw fetch -q origin
  gw checkout -q -b nx; pend z.md 'plugins: alpha\nlevel: patch\nsupersedes: n' "alpha n, final"; rp cut
  eq "$RC:$(lines "$W/plugins/alpha/CHANGELOG.md" "- minor: alpha n")/$(lines "$W/plugins/alpha/CHANGELOG.md" "- Run alpha n.")" "0:0/0" \
    "[M31] cut: an undated mark of a consumed, unpublished change takes out its line and note"
  cm "release 2"; rp check; eq "$RC" 0 "[M31] check --public passes it"
}
echo "-- fam_final"; fam_final "$PLUGIN/scripts/release.py"

echo; summary
