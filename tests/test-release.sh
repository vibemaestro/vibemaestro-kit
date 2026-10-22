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
  eq "$(cd "$W" && python3 "$RPY" bogus >/dev/null 2>&1; echo $?)" 64 "[C16] an unknown subcommand: rc 64"
  eq "$(cd "$W" && python3 "$RPY" check --hotfix >/dev/null 2>&1; echo $?)" 64 "[C16] check --hotfix: rc 64"
}

echo "-- fam_cut"; fam_cut "$PLUGIN/scripts/release.py"

# ── [X] planted breaks ───────────────────────────────────────────────────────────────────────────────────────────────────
echo "-- planted breaks"
BRKC() {  # BRKC <label> <needle> <old> <new> — a copy of release.py, family fam_cut
  local d="$TMP/break-$1"; mkdir -p "$d"; cp "$PLUGIN/scripts/release.py" "$d/release.py"
  mutate "$d/release.py" "$3" "$4" && expect_red "$1" fam_cut "$d/release.py" "$2"
}
BRKC cut-no-changelog '[C2] …alpha' '        write_changelog(repo, n, new, lines)' '        pass'
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
BRKC plan-writes '[C1] …and plan writes nothing' '    show_plan(plan, files, frozen)
    print("plan only' '    do_cut(repo, hotfix, given)
    print("plan only'
PLC="$TMP/break-none"; mkdir -p "$PLC"; cp "$PLUGIN/scripts/release.py" "$PLC/release.py"
QN=0; okdef=$(declare -f ok); baddef=$(declare -f bad); sp=$PASS; sf=$FAIL
ok() { :; }; bad() { QN=$((QN+1)); }
fam_cut "$PLC/release.py" >/dev/null 2>&1
eval "$okdef"; eval "$baddef"; PASS=$sp; FAIL=$sf
eq "$QN" 0 "control: an unbroken copy passes fam_cut (no failed check)"

echo; summary
