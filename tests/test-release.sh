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
#       refusal alone
#   [F] cut --fold --public REPO joins the pending change files to each plugin's top released section when the public
#       repository (a local bare repository here) has no tag for it: lines after the section's own, notes under its Upgrade
#       notes, nothing twice, no version moved; check --public passes it as a fold (a CRLF base too), and is red on each
#       broken part; a line of the unpublished section may be reworded (same level, same count), a published or older section
#       stays frozen; each refusal
#   [X] planted breaks: each check goes red on a copy with one break
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
  echo a2 >> "$W/plugins/alpha/a.txt"; cfw a.md alpha minor "alpha does more"; cm "feature"
  echo b2 >> "$W/plugins/beta/b.txt"; cfw b.md beta patch "beta is fixed"; cm "fix"
  gw push -q origin main; gw fetch -q origin; gw checkout -q -b rel
}
rp() { OUT=$(cd "$W" && env -u GITHUB_ACTIONS -u GITHUB_BASE_REF python3 "$RPY" "$@" --repo "$W" 2>&1); RC=$?; }
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

- minor: alpha does more

## 2.9.0" "[C2] …alpha's CHANGELOG gains its entry above the last one"
  has "$(cat "$W/plugins/beta/CHANGELOG.md")" "## 1.0.1

- patch: beta is fixed

## 1.0.0" "[C2] …beta's CHANGELOG gains its entry"
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

- minor: alpha does more
- patch: both are fixed

### Upgrade notes

- Run alpha init once after the update.
- The PLAN lines now start with two spaces.

## 2.9.0" "[C20] …alpha's section ends with its upgrade notes, in the change files' order"
  has "$(cat "$W/plugins/beta/CHANGELOG.md")" "## 1.0.1

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
  eq "$(printf '%s\n' "$OUT" | sed -n 1p)" "- minor: alpha does more" "[C23] …the body starts with the section's lines (the heading is the release's title)"
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

- patch: alpha no longer breaks

### Upgrade notes

- Remove the stale lock file once." "[C25] cut --hotfix writes the upgrade note"
  cm "cut"; rp check --base origin/release
  eq "$RC" 0 "[C25] …and it passes check as a hotfix"
  eq "$(cd "$W" && python3 "$RPY" bogus >/dev/null 2>&1; echo $?)" 64 "[C16] an unknown subcommand: rc 64"
  eq "$(cd "$W" && python3 "$RPY" check --hotfix >/dev/null 2>&1; echo $?)" 64 "[C16] check --hotfix: rc 64"
}

echo "-- fam_cut"; fam_cut "$PLUGIN/scripts/release.py"

# ── [F] cut --fold ─────────────────────────────────────────────────────────────────────────────────────────────────────
# new_fold_repo — new_rel_repo cut into a release on main (alpha 2.10.0 with an upgrade note, beta 1.0.1) and `release` moved to
# it, not published: the public repository P holds only alpha--v2.9.0 and beta--v1.0.0. Then two pending change files on main
# (alpha patch with an upgrade line, beta patch with one); W on branch fold.
new_fold_repo() {
  new_rel_repo; P="$(dirname "$O")/public.git"; git_ init -q --bare -b main "$P"
  gw push -q "$P" main~2:refs/tags/alpha--v2.9.0; gw push -q "$P" main~2:refs/tags/beta--v1.0.0
  cfwu a.md alpha minor "alpha does more" "Run alpha init once."; cm "an upgrade line"; rp cut; cm "release"
  gw checkout -q main; gw merge -q --ff-only rel; gw push -q origin main; gw push -q origin main:release
  echo a3 >> "$W/plugins/alpha/a.txt"; cfwu c.md alpha patch "alpha fixed again" "Re-run alpha init."; cm "alpha fix"
  echo b3 >> "$W/plugins/beta/b.txt"; cfwu d.md beta patch "beta faster" "Beta reads a new key."; cm "beta speed"
  gw push -q origin main; gw fetch -q origin; gw checkout -q -b fold
}
# pubtag <tag> — the public repository publishes <tag>
pubtag() { gw push -q "$P" "main:refs/tags/$1"; }
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

- minor: alpha does more
- patch: alpha fixed again

### Upgrade notes

- Run alpha init once.
- Re-run alpha init.

## 2.9.0" "[F2] …alpha's lines after its own, its note under the Upgrade notes it had"
  has "$(cat "$W/plugins/beta/CHANGELOG.md")" "## 1.0.1

- patch: beta is fixed
- patch: beta faster

### Upgrade notes

- Beta reads a new key.

## 1.0.0" "[F2] …beta's note under a heading made for it"
  eq "$(gw status --porcelain -- kb 'plugins/*/.claude-plugin/plugin.json')" "" "[F2] …no manifest and no kb page written"
  cm "fold"; rp check --public "$P"
  eq "$RC" 0 "[F3] the fold, committed, passes check --public"
  has "$OUT" "kind: fold" "[F3] …as a fold"
  rp check
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
  rp plan --public "$P"; eq "$RC" 64 "[F16] plan --public without --fold: rc 64"
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
}

echo "-- fam_fold"; fam_fold "$PLUGIN/scripts/release.py"

# ── [X] planted breaks ───────────────────────────────────────────────────────────────────────────────────────────────────
echo "-- planted breaks"
BRKC() {  # BRKC <label> <needle> <old> <new> — a copy of release.py, family fam_cut
  local d="$TMP/break-$1"; mkdir -p "$d"; cp "$PLUGIN/scripts/release.py" "$d/release.py"
  mutate "$d/release.py" "$3" "$4" && expect_red "$1" fam_cut "$d/release.py" "$2"
}
BRKC cut-no-changelog '[C2] …alpha' '        write_changelog(repo, n, new, lines, notes)' '        pass'
BRKC cut-keeps-files '[C2] …the change files consumed' '        os.remove(os.path.join(repo, p))' '        pass'
BRKC cut-writes-state '[C2] …the state line untouched' '    for p in files:
        os.remove(os.path.join(repo, p))' '    open(os.path.join(repo, "kb", "current-state.md"), "a").write("- alpha 2.10.0\\n")
    for p in files:
        os.remove(os.path.join(repo, p))'
BRKC cut-first-any '[C18] …cut writes 0.1.0' '        plan[n] = (old, bump(old, level) if old else FIRST_RELEASE,' '        plan[n] = (old, bump(old or "0.0.0", level),'
BRKC stale-release-compared '[C19]' '        ref = released_ref or last_release_commit(repo, base, n) or base' '        ref = resolve(repo, RELEASE_REF) or base'
BRKC base-as-last-release '[C19b]' '        ref = released_ref or last_release_commit(repo, base, n) or base' '        ref = released_ref or base'
BRKC cut-frozen-kept '[C4]' '        frozen[rel] = plan[n][1]
    return plan, files, frozen' '        pass
    return plan, files, frozen'
BRKC cut-dirty-ok '[C6]' '        if not worktree_clean(repo):
            raise Refused("the working tree' '        if False:
            raise Refused("the working tree'
BRKC cut-on-any-branch '[C7]' '        if branch in (RELEASE, branch_of(base_ref), default):' '        if False:'
BRKC cut-without-release '[C12]' '        if not hotfix and rel and not is_ancestor(repo, rel, "HEAD"):' '        if False:'
BRKC cut-hotfix-minor '[C14]' '        if hotfix and level != "patch":' '        if False:'
BRKC cut-hotfix-from-main '[C17]' '        if hotfix and main_commits(repo, base):' '        if False:'
BRKC cut-no-upgrade '[C20] …alpha'"'"'s section ends' '        write_changelog(repo, n, new, lines, notes)' '        write_changelog(repo, n, new, lines, [])'
BRKC check-no-upgrade '[C21]' '            lacks = [l for l in ups.get(name, []) if l not in upgrade_part(section)]' '            lacks = []'
BRKC plan-writes '[C1] …and plan writes nothing' '    show_plan(plan, files, frozen, bool(public))
    print("plan only' '    do_cut(repo, hotfix, given)
    print("plan only'
BRKF() {  # BRKF <label> <needle> <old> <new> — a copy of release.py, family fam_fold
  local d="$TMP/break-$1"; mkdir -p "$d"; cp "$PLUGIN/scripts/release.py" "$d/release.py"
  mutate "$d/release.py" "$3" "$4" && expect_red "$1" fam_fold "$d/release.py" "$2"
}
BRKF fold-new-heading '[F2] …alpha'"'"'s lines after its own' '        if public:
            write_fold(repo, n, new, lines, notes)' '        if False:
            write_fold(repo, n, new, lines, notes)'
BRKF fold-no-notes '[F2] …alpha'"'"'s lines after its own' '        ups = (ups.rstrip("\n") if ups else UPGRADE_HEADING + "\n") + "".join("\n" + l for l in notes) + "\n\n"' '        ups = ups'
BRKF fold-kind-ordinary '[F3] …as a fold' '    return "fold" if folded(repo, mb) else "ordinary"' '    return "ordinary"'
BRKF check-fold-no-public '[F4]' '    if not public:
        bad.append("a fold needs' '    if False:
        bad.append("a fold needs'
BRKF check-fold-published '[F5]' '        if tags is not None and PUBLIC_TAG % (name, now) in tags:' '        if False:'
BRKF fold-writes-twice '[F6] a pending line' '    lines = [l for i, l in enumerate(lines) if l not in have and l not in lines[:i]]' '    lines = list(lines)'
BRKF cut-fold-published '[F7]' '    if PUBLIC_TAG % (n, old) in tags:
        raise Refused' '    if False:
        raise Refused'
BRKF fold-unread-tags '[F8]' '    if p.returncode != 0:
        why =' '    if False:
        why ='
BRKF cut-fold-unreleased '[F9] …naming it' '    if old is None:
        raise Refused("plugin %s was never released: a fold' '    if False:
        raise Refused("plugin %s was never released: a fold'
BRKF cut-fold-level '[F10]' '    if want != old:
        raise Refused' '    if False:
        raise Refused'
BRKF check-fold-level '[F11]' '        if want != now:
            bad.append' '        if False:
            bad.append'
BRKF check-fold-drops '[F12]' '        dropped = [l for l in was if l.strip() and l not in section and l not in [b for b, _ in pairs]]' '        dropped = []'
BRKF check-fold-left '[F13]' '    for p in change_files_here(repo):
        bad.append("%s is in .changes/' '    for p in []:
        bad.append("%s is in .changes/'
BRKF check-fold-twice '[F14]' '        twice = sorted(set(l for l in listed if listed.count(l) > 1))' '        twice = []'
BRKF check-fold-other-changelog '[F15]' '            if "plugins/%s/%s" % (name, CHANGELOG) in paths:' '            if False:'
BRKF fold-usage '[F16] cut --fold without --public' '(fold != bool(public) or' '(False or'
BRKF fold-usage-dash '[F16] a --public that starts with a dash' '    if public.startswith("-") or' '    if False or'
BRKF fold-usage-hotfix '[F16] cut --fold --hotfix' 'or (fold and hotfix)' 'or False'
BRKF check-fold-unread '[F17]' '        except Bad as e:
            bad.append(str(e))
    levels, lines, ups = shipped' '        except Bad as e:
            pass
    levels, lines, ups = shipped'
BRKF check-fold-scope '[F18]' 'section: ok" % (name, len(pairs), now))
    release_scope(repo, mb, paths, bad)' 'section: ok" % (name, len(pairs), now))
    pass'
BRKF check-fold-extra '[F19]' '        if extra:
            bad.append' '        if False:
            bad.append'
BRKF check-fold-missing '[F20]' '        missing = [l for l in lines[name] if l not in entries_of(section)]' '        missing = []'
BRKF check-fold-outside '[F21]' '        if outside[0] != outside[1]:' '        if False:'
BRKF cut-fold-heading '[F22] …with a reason' '    if section is None:
        raise Refused' '    if False:
        raise Refused'
BRKF cut-fold-nothing '[F23]' '        if public and not any(' '        if False and not any('
BRKF check-fold-heading '[F25] …with a reason' '        if section is None:
            bad.append("plugins/%s/%s: its first heading' '        if False:
            bad.append("plugins/%s/%s: its first heading'
BRKF check-fold-prose '[F26]' '        extra = [l for l in section if l.strip() and l not in allowed]' '        extra = [l for l in section if l.startswith("- ") and l not in allowed]'
BRKF check-fold-moved '[F27]' '        if moved:
            bad.append' '        if False:
            bad.append'
BRKF check-fold-crlf '[F28]' ' or "").replace("\r\n", "\n")' ' or "")'
BRKF check-fold-eof '[F28]' '    while lines and not lines[-1]:
        lines.pop()' '    while False:
        lines.pop()'
BRKF check-fold-reword-none '[F29]' '            pairs.append((b, h))' '            return [], None'
BRKF check-fold-reword-level '[F31]' '            if (lb.group(1) if lb else None) != (lh.group(1) if lh else None):' '            if False:'
BRKF check-fold-reword-said '[F29] …and it says so' '                print("plugin %s: rewords %d line(s)' '                (lambda *a: None)("plugin %s: rewords %d line(s)'
BRKF check-fold-published-reword '[F32] …and it says' '", this change rewords %d of its line(s)" % len(pairs) if pairs else ""' '""'
BRKF check-fold-reword-dedup '[F34]' '        rest = [l for l in here if l not in new or l in base]' '        rest = [l for l in here if l not in new]'
BRKF check-fold-reword-ok-published '[F32] …and prints no reword' '            if pairs and not (tags is not None and PUBLIC_TAG % (name, now) in tags):' '            if pairs:'
BRKF check-fold-apart '[F35]' '    return sum(max(i2 - i1, j2 - j1)' '    return sum(1 for x, y in zip(a, b) if x != y) + abs(len(a) - len(b)) or sum(max(i2 - i1, j2 - j1)'
BRKF check-fold-lacks '[F24]' '        lacks = [l for l in ups.get(name, []) if l not in upgrade_part(section)]
        listed' '        lacks = []
        listed'
PLC="$TMP/break-none"; mkdir -p "$PLC"; cp "$PLUGIN/scripts/release.py" "$PLC/release.py"
QN=0; okdef=$(declare -f ok); baddef=$(declare -f bad); sp=$PASS; sf=$FAIL
ok() { :; }; bad() { QN=$((QN+1)); }
fam_cut "$PLC/release.py" >/dev/null 2>&1
eval "$okdef"; eval "$baddef"; PASS=$sp; FAIL=$sf
eq "$QN" 0 "control: an unbroken copy passes fam_cut (no failed check)"
QN=0; ok() { :; }; bad() { QN=$((QN+1)); }
fam_fold "$PLC/release.py" >/dev/null 2>&1
eval "$okdef"; eval "$baddef"; PASS=$sp; FAIL=$sf
eq "$QN" 0 "control: an unbroken copy passes fam_fold (no failed check)"

echo; summary
