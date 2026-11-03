#!/bin/bash
# =============================================================================
# Public kit — scripts/export-public.sh: the published tree of one rev, read from git objects only, and its one tree digest
# =============================================================================
# Run: bash tests/test-export-public.sh
#      PLUGIN_REQUIRE_CLAUDE=1 bash …   # no `claude` is RED (default: the install part [I] is SKIPPED, loudly)
#
# Every case runs the real script on a
# scratch repository whose first commit R1 holds this checkout's tracked files (work tree content), a LICENSE and a NOTICE when the
# checkout has none yet, a config whose public.private is .vibemaestro/sdlc.json and private-dir/**, and planted files: the root kb/
# and private-dir/ ones must stay out, the others (tests/, scripts/, .changes/, .github/, docs/, kbx/, a kb/ below the root,
# private-dir.md) must be exported.
#   [L] the file list equals the tree minus the root kb/ and the private list, computed here by this suite's own rule (never the script's)
#   [X] no path under the root kb/ or matching public.private; no planted private content; the planted public files are there
#   [D] two exports of one rev: one stdout line, the same digest, the same names, bytes, modes and mtimes (umask 077 for the
#       second); the digest is what `git init`, `git add -Af`, `git write-tree` give for the dir; a branch name gives the sha's digest
#   [G] a .gitignore inside the export drops nothing from the digest (control: plain `git add -A` does drop the file)
#   [R] a local `git replace` (of a blob; then of the commit, its tree and a blob at once while the repo config and
#       GIT_CONFIG_COUNT set core.useReplaceRefs=true) and a smudge filter do not change the export: bytes, digest, mtimes
#       (controls: each is active in the repository)
#   [S] a signed commit with log.showSignature=true: rc 0, mtimes are its committer time (control: `git show` prints more)
#   [N] a rev with no LICENSE, or no NOTICE: rc 0, one WARN line naming it, a digest, no plugin copy of the missing file
#   [F] refusals, each rc != 0, no digest, nothing written: a symlink, a gitlink, a `..` path that would escape the outdir, a `.git`
#       path and its HFS and NTFS lookalikes, a tree with a duplicate entry, a commit time out of range (rc 4), a failing
#       `git ls-files` (rc 4), a missing README.md, a config with no public.private (absent file, null, not JSON) or an invalid
#       glob in it, a committed plugin LICENSE, a non-empty outdir, an empty outdir argument, a rev
#       shaped like an option; and a written tree that differs from the git entries (a .gitattributes that rewrites a file on
#       `git add`): rc != 0, no digest
#   [W] an untracked, a modified and a staged file in the work tree do not appear; the digest stays R1's
#   R1, the fixture, is this tree in the private unreleased form whatever tree runs the suite: each `## X.Y.Z` section leaves the
#       CHANGELOG (a private tree after a release cut, a released export); on the public export (fixtures/lib.sh tree_shape) each
#       manifest also loses its `version` and `repository`, and a sibling dependency the export turned into >=X.Y.Z is named bare again; a private
#       manifest is copied as it is, so a version there stays red (instrument lines in [V])
#   [V] the version: a rev whose CHANGELOGs start with `## 0.1.0` exports
#       each manifest with version 0.1.0 right after name and >=0.1.0 on each bare sibling dependency, the digest still the written
#       tree; an unreleased rev exports each manifest byte for byte with a WARN; a manifest version that differs from its
#       CHANGELOG's is refused; a pre-reset manifest whose version equals its CHANGELOG's is exported as it is plus `repository`;
#       each released manifest gets `repository`, https://github.com/ and --repository <owner/name> (default the kit's public
#       repository), a value that is not owner/name is rc 2, and a source manifest with another `repository` is refused;
#       the floor: a brain section whose `Released together:` line names sdlc 0.2.0 exports `>=0.2.0`, and a later rev that
#       releases only sdlc exports brain's manifest byte for byte (still `>=0.2.0`) while sdlc's moves; a sibling the line does
#       not name gets >=0.1.0; a heading `##  X.Y.Z` reads as the version does; a line that does not read (an empty one too),
#       two lines in a section and a floor above the sibling's release are refused (rc 3)
#   [I] isolated install (`claude`, no login, no model): CLAUDE_CONFIG_DIR and HOME in scratch, `marketplace add <export>`, the two
#       plugins install into the cache with their LICENSE and NOTICE; the export is deleted; the cached sdlc SessionStart hooks print
#       their context; after one `brain op add` by the installed brain (control: silent before it) the cached brain hook prints its
#       banner
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"

EXPORT="$SRC_ROOT/scripts/export-public.sh"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
export PYTHONDONTWRITEBYTECODE=1
unset GH_TOKEN GITHUB_TOKEN
PLUGINS="vibemaestro-sdlc vibemaestro-brain"
HEX40='^[0-9a-f]{40}$'

# ex <rev> <outdir> [script] — run the export in $FX; sets RC, DIG (stdout) and ERR (stderr)
ex() {
  DIG=$(cd "$FX" && bash "${3:-$EXPORT}" "$1" "$2" 2>"$TMP/ex.err"); RC=$?; ERR=$(cat "$TMP/ex.err")
}
# plan_digest <dir> [add flag] — the plan's digest, computed here: `git init`, `git add -Af` (or the flag), `git write-tree`
plan_digest() {
  local g; g=$(mktemp -d)
  GIT_DIR="$g" git init -q --template= && (cd "$1" && GIT_DIR="$g" GIT_WORK_TREE="$1" git add "${2:--Af}" -- .) &&
    GIT_DIR="$g" git write-tree
}
# manifest <dir> — one sorted line per entry: kind, mode, mtime, path, sha256 of a file's bytes
manifest() {
  python3 - "$1" <<'PY'
import hashlib, os, stat, sys
root = sys.argv[1]
rows = []
for dp, dns, fns in os.walk(root):
    for n in dns + fns:
        p = os.path.join(dp, n); st = os.lstat(p)
        k = "d" if stat.S_ISDIR(st.st_mode) else "f" if stat.S_ISREG(st.st_mode) else "l" if stat.S_ISLNK(st.st_mode) else "?"
        h = hashlib.sha256(open(p, "rb").read()).hexdigest() if k == "f" else ""
        rows.append("%s %o %d %s %s" % (k, stat.S_IMODE(st.st_mode), st.st_mtime, os.path.relpath(p, root), h))
st = os.lstat(root)
rows.append("root %o %d" % (stat.S_IMODE(st.st_mode), st.st_mtime))
print("\n".join(sorted(rows)))
PY
}
# files_of <dir> — every non-directory under <dir>, relative, sorted
files_of() { (cd "$1" && find . ! -type d | sed 's#^\./##' | LC_ALL=C sort); }
# expected <rev> — this suite's own expansion of <rev>: the tree minus the root kb/ and the fixture's private list, spelled out here
# as plain prefixes (kept apart from the script's glob code on purpose)
expected() {
  git_ -C "$FX" ls-tree -r -z --name-only "$1" | python3 -c '
import sys
paths = [p for p in sys.stdin.buffer.read().decode().split("\0") if p]
keep = [p for p in paths if not p.startswith(("kb/", "private-dir/")) and p != ".vibemaestro/sdlc.json"]
plugins = sorted({p.split("/")[1] for p in paths if p.startswith("plugins/") and p.count("/") >= 2})
keep += ["plugins/%s/%s" % (n, f) for n in plugins for f in ("LICENSE", "NOTICE") if f in paths]
print("\n".join(sorted(keep, key=lambda s: s.encode())))'
}
# mkrev <branch> <commands> — a commit on R1 plus <commands> (run in $FX; they stage what they change); prints it; $FX back on main
mkrev() {
  git_ -C "$FX" checkout -q -B "$1" "$R1" && (cd "$FX" && eval "$2") >/dev/null && git_ -C "$FX" commit -qm "$1" &&
    git_ -C "$FX" rev-parse HEAD
  git_ -C "$FX" checkout -q main
}
# graft <branch> <tree-of-plugins entry line> — R1 with one extra raw entry under plugins/, built with plumbing (git add refuses it)
graft() {
  local pt top
  pt=$( { git_ -C "$FX" ls-tree "$R1:plugins"; printf '%s\n' "$2"; } | git_ -C "$FX" mktree) &&
    top=$(git_ -C "$FX" ls-tree "$R1" | awk -F '\t' -v pt="$pt" '$2 == "plugins" {$0 = "040000 tree " pt "\tplugins"} {print}' |
      git_ -C "$FX" mktree) &&
    git_ -C "$FX" commit-tree -p "$R1" -m "$1" "$top"
}
# refused <label> <outdir> — the last export was refused: rc != 0, no stdout, a reason on stderr, the outdir holds nothing new
refused() {
  [ "$RC" -ne 0 ] && ok "[F] $1: refused (rc $RC)" || bad "[F] $1: exported with rc 0"
  empty "$DIG" "[F] $1: no digest on stdout"
  nonempty "$ERR" "[F] $1: a reason on stderr"
  empty "$(files_of "$2" 2>/dev/null)" "[F] $1: nothing written to the outdir"
}

echo "== fixture: R1 = this checkout's tracked files + LICENSE, NOTICE + planted files =="
FX="$TMP/fx"; mkdir -p "$FX"
git -C "$SRC_ROOT" ls-files -z | python3 -c '
import os, shutil, sys
src, dst = os.fsencode(sys.argv[1]), os.fsencode(sys.argv[2])
for p in sys.stdin.buffer.read().split(b"\0"):
    s, d = os.path.join(src, p), os.path.join(dst, p)
    if not p or not os.path.lexists(s):
        continue
    os.makedirs(os.path.dirname(d), exist_ok=True)
    os.symlink(os.readlink(s), d) if os.path.islink(s) else shutil.copy2(s, d)' "$SRC_ROOT" "$FX"
rm -f "$FX"/plugins/*/LICENSE "$FX"/plugins/*/NOTICE   # a published tree holds the copies its export made; a private one does not
# the private unreleased form (a no-op on the private repo before its first release): no released `## X.Y.Z` section in a
# CHANGELOG; on the export also no manifest version and siblings named bare; a file is rewritten only when it changes
python3 - "$FX" "$(tree_shape "$SRC_ROOT")" $PLUGINS <<'PY' || bad "fixture: R1's conversion to the private unreleased form failed"
import json, os, re, sys
root, shape, names = sys.argv[1], sys.argv[2], sys.argv[3:]
RANGE = re.compile(r">=(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")   # the floor the export writes on a sibling
REL = re.compile(r"## (0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\s*$")
for n in names:
    p = os.path.join(root, "plugins", n, ".claude-plugin", "plugin.json")
    m = json.load(open(p, encoding="utf-8"))
    deps = m.get("dependencies")
    ranged = lambda d: isinstance(d, dict) and set(d) == {"name", "version"} and d["name"] in names and bool(RANGE.fullmatch(d["version"]))
    if shape == "export" and ("version" in m or "repository" in m or any(ranged(d) for d in deps or [])):
        m.pop("version", None)
        m.pop("repository", None)
        if deps is not None:
            m["dependencies"] = [d["name"] if ranged(d) else d for d in deps]
        open(p, "w", encoding="utf-8").write(json.dumps(m, indent=2, ensure_ascii=False) + "\n")
    p = os.path.join(root, "plugins", n, "CHANGELOG.md")
    lines, out, skip = open(p, encoding="utf-8").read().split("\n"), [], False
    for line in lines:
        if line.startswith("## "):
            skip = bool(REL.match(line))
        if not skip:
            out.append(line)
    if out != lines:
        open(p, "w", encoding="utf-8").write("\n".join(out))
PY
[ -e "$FX/LICENSE" ] || printf 'Fixture licence text.\n' > "$FX/LICENSE"
[ -e "$FX/NOTICE" ] || printf 'Fixture notice text.\n' > "$FX/NOTICE"
[ -e "$FX/CHANGELOG.md" ] || printf '# Fixture changelog\n' > "$FX/CHANGELOG.md"
# the markers are built here, so this file (exported like every test) never holds them as one word
PRIV=$(printf 'K2X%s' PRIVATE); PUB=$(printf 'K2X%s' PUBLIC)
mkdir -p "$FX/.vibemaestro"
printf '{"schema": 1, "public": {"private": [".vibemaestro/sdlc.json", "private-dir/**"]}}\n' > "$FX/.vibemaestro/sdlc.json"
PRIVATE_FILES="kb/planted.md kb/sub/planted.md private-dir/planted.md private-dir/a/b.md"
PUBLIC_FILES="tests/planted.txt .changes/planted.md .vibemaestro/planted.json .github/workflows/planted.yml docs/internal-only.md
  kbx/planted.md tests/fixtures/f/kb/planted.md private-dir.md scripts/planted.sh"
for f in $PRIVATE_FILES; do mkdir -p "$FX/$(dirname "$f")"; printf '%s %s\n' "$PRIV" "$f" > "$FX/$f"; done
for f in $PUBLIC_FILES; do mkdir -p "$FX/$(dirname "$f")"; printf '%s %s\n' "$PUB" "$f" > "$FX/$f"; done
git_ -C "$FX" init -q -b main && git_ -C "$FX" add -Af && git_ -C "$FX" commit -qm r1
R1=$(git_ -C "$FX" rev-parse HEAD)
eq "$(git_ -C "$FX" cat-file -t "$R1:kb/planted.md")" blob "fixture: the planted kb/ file is committed in R1 (the exclusion is tested on objects)"
CT=$(git_ -C "$FX" show -s --format=%ct "$R1")

echo "== [L] [X] the file list =="
O1="$TMP/o1"; ex "$R1" "$O1"
eq "$RC" 0 "[L] export of R1: rc 0 ($ERR)"
[[ "$DIG" =~ $HEX40 ]] && ok "[D] stdout is exactly one 40-hex line" || bad "[D] stdout is not one 40-hex line: '$DIG'"
D1=$DIG
EXP=$(expected "$R1"); GOT=$(files_of "$O1")
eq "$GOT" "$EXP" "[L] the file list equals the tree of R1 minus the root kb/ and the private list ($(printf '%s\n' "$EXP" | wc -l | tr -d ' ') files)"
for f in .claude-plugin/marketplace.json README.md LICENSE NOTICE CHANGELOG.md .gitignore scripts/export-public.sh \
         tests/test-export-public.sh .github/workflows/test.yml .github/actions/fetch-plugin/action.yml \
         plugins/vibemaestro-sdlc/hooks/hooks.json plugins/vibemaestro-brain/bin/brain $PUBLIC_FILES; do
  [ -f "$O1/$f" ] && ok "[L] exported: $f" || bad "[L] missing from the export: $f"
done
for p in $PLUGINS; do
  cmp -s "$O1/plugins/$p/LICENSE" "$FX/LICENSE" && cmp -s "$O1/plugins/$p/NOTICE" "$FX/NOTICE" &&
    ok "[L] plugins/$p carries LICENSE and NOTICE equal to the root files (Q7)" || bad "[L] plugins/$p: LICENSE or NOTICE missing or different"
done
empty "$(printf '%s\n' "$GOT" | grep -E '^(kb|private-dir)/|^\.vibemaestro/sdlc\.json$')" \
  "[X] no path under the root kb/ or private-dir/, no .vibemaestro/sdlc.json"
empty "$(grep -rlF "$PRIV" "$O1" 2>/dev/null)" "[X] no planted private content anywhere in the export"
eq "$(grep -rlF "$PUB" "$O1" 2>/dev/null | wc -l | tr -d ' ')" "$(printf '%s\n' $PUBLIC_FILES | wc -l | tr -d ' ')" \
  "[X] every planted public file is exported (control: the private ones were planted beside them)"
empty "$(find "$O1" -type l)" "[X] no symlink in the export"

echo "== [D] the same rev, the same tree =="
O2="$TMP/o2"; DIG=$( (umask 077 && cd "$FX" && bash "$EXPORT" main "$O2") 2>"$TMP/ex.err"); RC=$?
eq "$RC" 0 "[D] second export (branch name, umask 077): rc 0"
eq "$DIG" "$D1" "[D] the branch name gives the sha's digest"
eq "$(manifest "$O2")" "$(manifest "$O1")" "[D] the two exports match in names, bytes, modes and mtimes"
eq "$(plan_digest "$O1")" "$D1" "[D] the printed digest is the plan's: git init, git add -Af, git write-tree of the dir"
empty "$(manifest "$O1" | awk -v ct="$CT" '$3 != ct')" "[D] every mtime, the root's too, is R1's committer time"
empty "$(manifest "$O1" | awk '($1 == "d" || $1 == "root") && $2 != "755"
                               $1 == "f" && $2 != "644" && $2 != "755"')" \
  "[D] directories 0755, files 0644 or 0755"
eq "$(stat -c %a "$O1/plugins/vibemaestro-brain/bin/brain" 2>/dev/null || stat -f %Lp "$O1/plugins/vibemaestro-brain/bin/brain")" 755 \
  "[D] an executable stays 0755 (bin/brain)"

echo "== [G] a .gitignore inside the export =="
RG=$(mkrev gi 'printf "CONTRACT.md\n" > plugins/vibemaestro-sdlc/.gitignore && git_ add -f plugins/vibemaestro-sdlc/.gitignore')
OG="$TMP/og"; ex "$RG" "$OG"
eq "$RC" 0 "[G] export with a .gitignore that ignores a shipped file: rc 0"
[ -f "$OG/plugins/vibemaestro-sdlc/CONTRACT.md" ] && ok "[G] the ignored file is exported" || bad "[G] the ignored file is missing"
eq "$(plan_digest "$OG")" "$DIG" "[G] the digest counts the ignored file (git add -Af)"
[ "$(plan_digest "$OG" -A)" != "$DIG" ] && ok "[G] control: plain git add -A drops it, so the case would see a dropped file" ||
  bad "[G] control: plain git add -A gives the same tree, the .gitignore case proves nothing"

echo "== [R] replace refs and filters in the repository =="
RB=$(git_ -C "$FX" rev-parse "$R1:README.md"); RAW=$(git_ -C "$FX" cat-file blob "$RB" | cksum)   # before the replace ref exists
FAKE=$(printf 'REPLACED README\n' | git_ -C "$FX" hash-object -w --stdin)
git_ -C "$FX" replace "$RB" "$FAKE"
printf 'README.md filter=k2evil\n' > "$FX/.git/info/attributes"
git_ -C "$FX" config filter.k2evil.smudge 'sed s/^/SMUDGED/'
has "$(git_ -C "$FX" cat-file blob "$RB")" 'REPLACED README' "[R] control: the replace ref is active in the repository"
has "$(git_ -C "$FX" cat-file --filters "$R1:README.md" | head -n 1)" SMUDGED "[R] control: the smudge filter is active"
OR="$TMP/or"; ex "$R1" "$OR"
eq "$RC:$DIG" "0:$D1" "[R] export with a replace ref and a smudge filter: rc 0 and R1's digest"
eq "$(cksum < "$OR/README.md")" "$RAW" "[R] README.md holds the raw blob, not the replacement or the smudged text"
git_ -C "$FX" replace -d "$RB" >/dev/null; rm -f "$FX/.git/info/attributes"; git_ -C "$FX" config --unset filter.k2evil.smudge
KB=$(git_ -C "$FX" rev-parse "$R1:kb/planted.md")
NT=$(git_ -C "$FX" rev-parse "$(graft leak "$(printf '100644 blob %s\tleaked.md' "$KB")")^{tree}")
FC=$(printf 'tree %s\nparent %s\nauthor t <t@t> 555 +0000\ncommitter t <t@t> 555 +0000\n\nfake\n' \
       "$(git_ -C "$FX" rev-parse "$R1^{tree}")" "$R1" | git_ -C "$FX" hash-object -t commit -w --stdin)
git_ -C "$FX" replace -f "$R1" "$FC"; git_ -C "$FX" replace -f "$(git_ -C "$FX" rev-parse "$R1^{tree}")" "$NT"
git_ -C "$FX" replace -f "$RB" "$FAKE"; git_ -C "$FX" config core.useReplaceRefs true
eq "$(git_ -C "$FX" -c core.useReplaceRefs=true show -s --format=%ct "$R1")" 555 "[R] control: R1 is replaced by a commit dated 555"
has "$(git_ -C "$FX" -c core.useReplaceRefs=true ls-tree -r --name-only "$R1")" plugins/leaked.md "[R] control: R1's tree is replaced by one holding a kb/ blob"
has "$(git_ -C "$FX" -c core.useReplaceRefs=true cat-file blob "$RB")" 'REPLACED README' "[R] control: README.md's blob is replaced"
OR2="$TMP/or2"
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.useReplaceRefs GIT_CONFIG_VALUE_0=true
ex "$R1" "$OR2"
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
eq "$RC:$DIG" "0:$D1" "[R] a replaced tree under core.useReplaceRefs=true (repo config and GIT_CONFIG_COUNT): R1's digest"
[ ! -e "$OR2/plugins/leaked.md" ] && ok "[R] …and the kb/ blob does not leak" || bad "[R] the replaced tree leaked a kb/ blob into the export"
eq "$(cksum < "$OR2/README.md")" "$RAW" "[R] …README.md holds the raw blob"
eq "$(manifest "$OR2")" "$(manifest "$O1")" "[R] …and names, bytes, modes and mtimes equal the clean export (not the replaced commit's 555)"
git_ -C "$FX" replace -d "$R1" "$(git_ -C "$FX" rev-parse "$R1^{tree}")" "$RB" >/dev/null; git_ -C "$FX" config --unset core.useReplaceRefs

echo "== [S] a signed commit and log.showSignature=true =="
SC=$(printf 'tree %s\nparent %s\nauthor t <t@t> 1700000000 +0000\ncommitter t <t@t> 1700000123 +0000\ngpgsig -----BEGIN SSH SIGNATURE-----\n U1NIU0lHAAAAAQ==\n -----END SSH SIGNATURE-----\n\nsigned\n' \
       "$(git_ -C "$FX" rev-parse "$R1^{tree}")" "$R1" | git_ -C "$FX" hash-object -t commit -w --stdin)
git_ -C "$FX" config log.showSignature true
SHOWN=$(git_ -C "$FX" show -s --format=%ct "$SC" 2>/dev/null)
[ "$SHOWN" != 1700000123 ] && ok "[S] control: git show prints more than the time for this commit ($(printf '%s' "$SHOWN" | head -n 1))" ||
  echo "  SKIP [S] control: git show prints only the time on this machine (no ssh-keygen?), the trap is not armed here"
OS="$TMP/os"; ex "$SC" "$OS"
eq "$RC:$DIG" "0:$D1" "[S] export of a signed commit: rc 0 and R1's digest ($(printf '%s' "$ERR" | tail -n 1 | cut -c1-80))"
empty "$(manifest "$OS" | awk '$3 != 1700000123')" "[S] every mtime is the signed commit's committer time"
git_ -C "$FX" config --unset log.showSignature

echo "== [N] a rev with no LICENSE or no NOTICE: a WARN, no refusal (K5 refuses to publish it) =="
for f in LICENSE NOTICE; do
  o=LICENSE; [ "$f" = LICENSE ] && o=NOTICE
  RN=$(mkrev "no-$f" "git_ rm -q $f")
  ON="$TMP/on-$f"; ex "$RN" "$ON"
  eq "$RC" 0 "[N] no $f: rc 0"
  [[ "$DIG" =~ $HEX40 ]] && ok "[N] no $f: a digest on stdout" || bad "[N] no $f: no digest ('$DIG')"
  eq "$(printf '%s\n' "$ERR" | grep WARN | grep -vc 'has no released version')" 1 "[N] no $f: exactly one WARN line about the licence files (R1 is unreleased: [V2])"
  has "$(printf '%s\n' "$ERR" | grep WARN | grep -v 'has no released version')" "$f" "[N] no $f: the WARN names $f"
  empty "$(cd "$ON" && ls -d $f plugins/*/$f 2>/dev/null)" "[N] no $f: no $f at the root or in any plugin"
  eq "$(cd "$ON" && ls plugins/*/$o 2>/dev/null | wc -l | tr -d ' ')" 2 "[N] no $f: the two plugins still carry $o"
  eq "$(files_of "$ON")" "$(expected "$RN")" "[N] no $f: the list is the allowlist expansion"
done

echo "== [F] refusals =="
OF="$TMP/of"
R=$(mkrev sym 'ln -s ../../kb/planted.md plugins/vibemaestro-sdlc/link.md && git_ add plugins/vibemaestro-sdlc/link.md')
mkdir -p "$OF/sym"; ex "$R" "$OF/sym"; refused "a symlink under plugins/" "$OF/sym"
has "$ERR" plugins/vibemaestro-sdlc/link.md "[F] the symlink refusal names the path"
R=$(mkrev gitlink "git_ update-index --add --cacheinfo 160000,$R1,plugins/vibemaestro-sdlc/sub")
mkdir -p "$OF/gitlink"; ex "$R" "$OF/gitlink"; refused "a gitlink under plugins/" "$OF/gitlink"
B=$(printf 'ESCAPED\n' | git_ -C "$FX" hash-object -w --stdin)
T1=$(printf '100644 blob %s\tescape.txt\n' "$B" | git_ -C "$FX" mktree); T2=$(printf '040000 tree %s\t..\n' "$T1" | git_ -C "$FX" mktree)
R=$(graft dotdot "$(printf '040000 tree %s\t..' "$T2")")
eq "$(git_ -C "$FX" ls-tree -r --name-only "$R" | grep -c '^plugins/\.\./\.\./escape.txt$')" 1 "[F] control: the crafted rev holds plugins/../../escape.txt"
mkdir -p "$OF/dd/out"; ex "$R" "$OF/dd/out"; refused "a .. path that would escape the outdir" "$OF/dd/out"
has "$ERR" "or '.git' part" "[F] the .. refusal comes from the export's own path check, before git's"
[ ! -e "$OF/escape.txt" ] && [ ! -e "$OF/dd/escape.txt" ] && ok "[F] nothing written outside the outdir" || bad "[F] a file escaped the outdir"
R=$(graft dotgit "$(printf '100644 blob %s\t.git' "$B")")
mkdir -p "$OF/dg"; ex "$R" "$OF/dg"; refused "a .git path" "$OF/dg"
R=$(graft dotgit-case "$(printf '040000 tree %s\t.GiT' "$T1")")
mkdir -p "$OF/dgc"; ex "$R" "$OF/dgc"; refused "a .GiT path (case folded)" "$OF/dgc"
R=$(graft dotgit-hfs "$(printf '040000 tree %s\t.g\342\200\214it' "$T1")")
mkdir -p "$OF/hfs"; ex "$R" "$OF/hfs"; refused "an HFS lookalike of .git (.g<U+200C>it)" "$OF/hfs"
R=$(graft dotgit-ntfs "$(printf '040000 tree %s\tgit~1' "$T1")")
mkdir -p "$OF/ntfs"; ex "$R" "$OF/ntfs"; refused "an NTFS short name of .git (git~1)" "$OF/ntfs"
DUP=$( { git_ -C "$FX" ls-tree "$R1"; printf '040000 tree %s\tplugins\n' "$(git_ -C "$FX" rev-parse "$R1:kb")"; } | python3 -c '
import binascii, sys
out = b""
for line in sys.stdin.read().splitlines():
    meta, name = line.split("\t", 1); mode, kind, oid = meta.split(" ")
    out += (mode.lstrip("0") + " " + name).encode() + b"\0" + binascii.unhexlify(oid)
sys.stdout.buffer.write(out)' | git_ -C "$FX" hash-object -t tree --literally -w --stdin)
R=$(git_ -C "$FX" commit-tree -p "$R1" -m dup "$DUP")
has "$(git_ -C "$FX" ls-tree -r --name-only "$R")" plugins/planted.md "[F] control: a second plugins entry hides kb/ under plugins/"
mkdir -p "$OF/dup"; ex "$R" "$OF/dup"; refused "a tree with a duplicate entry" "$OF/dup"
has "$ERR" "'plugins' appears twice" "[F] the duplicate refusal names the path"
R=$(printf 'tree %s\nauthor t <t@t> 1700000000 +0000\ncommitter t <t@t> 99999999999999999999 +0000\n\nfar\n' \
     "$(git_ -C "$FX" rev-parse "$R1^{tree}")" | git_ -C "$FX" hash-object -t commit --literally -w --stdin)   # newer git fscks hash-object
eq "$(git_ -C "$FX" cat-file -t "$R" 2>&1)" commit "[F] control: the commit dated 99999999999999999999 exists"
mkdir -p "$OF/far"; ex "$R" "$OF/far"; refused "a commit whose committer time is out of range" "$OF/far"
eq "$RC" 4 "[F] the out-of-range time: rc 4"
has "$ERR" 'cannot read a committer time' "[F] the out-of-range time: the message names the committer time, not a traceback"
R=$(mkrev noreadme 'git_ rm -q README.md')
mkdir -p "$OF/noreadme"; ex "$R" "$OF/noreadme"; refused "README.md missing" "$OF/noreadme"
has "$ERR" README.md "[F] the missing-file refusal names it"
R=$(mkrev nocfg 'git_ rm -q .vibemaestro/sdlc.json')
mkdir -p "$OF/nocfg"; ex "$R" "$OF/nocfg"; refused "no .vibemaestro/sdlc.json (the rev does not say what it publishes)" "$OF/nocfg"
has "$ERR" public.private "[F] the no-config refusal names public.private"
for c in 'nullpriv {"schema": 1, "public": {"private": null}}' 'nopub {"schema": 1}' 'notjson {' 'badglob {"schema": 1, "public": {"private": ["ok/**", "../x"]}}' \
         'classglob {"schema": 1, "public": {"private": ["[k]b/**"]}}'; do
  n=${c%% *}; R=$(mkrev "$n" "printf '%s\n' '${c#* }' > .vibemaestro/sdlc.json && git_ add .vibemaestro/sdlc.json")
  mkdir -p "$OF/$n"; ex "$R" "$OF/$n"; refused "config $n: ${c#* }" "$OF/$n"
  eq "$RC" 3 "[F] config $n: refused before writing, rc 3"
done
has "$ERR" 'public.private[0]' "[F] an invalid glob is named by its index"
R=$(mkrev plic 'printf "own licence\n" > plugins/vibemaestro-brain/LICENSE && git_ add plugins/vibemaestro-brain/LICENSE')
mkdir -p "$OF/plic"; ex "$R" "$OF/plic"; refused "a committed plugins/<name>/LICENSE" "$OF/plic"
mkdir -p "$OF/full"; printf 'stale\n' > "$OF/full/stale.txt"; ex "$R1" "$OF/full"
[ "$RC" -ne 0 ] && ok "[F] a non-empty outdir: refused (rc $RC)" || bad "[F] a non-empty outdir: exported"
empty "$DIG" "[F] a non-empty outdir: no digest"
eq "$(files_of "$OF/full")" stale.txt "[F] a non-empty outdir: left as it was"
SHIM="$TMP/shim"; mkdir -p "$SHIM"; REALGIT=$(command -v git)
printf '#!/bin/bash\nfor a in "$@"; do [ "$a" = ls-files ] && { echo "shim: ls-files fails" >&2; exit 1; }; done\nexec %s "$@"\n' "$REALGIT" > "$SHIM/git"
chmod +x "$SHIM/git"
mkdir -p "$OF/lsf"; PATH="$SHIM:$PATH" ex "$R1" "$OF/lsf"; refused "a git ls-files that fails" "$OF/lsf"
eq "$RC" 4 "[F] a failing ls-files: rc 4 (not reported as refused paths)"
has "$ERR" 'git ls-files failed' "[F] a failing ls-files: the message says so"
ex "$R1" ""
[ "$RC" -eq 2 ] && ok "[F] an empty outdir argument: rc 2" || bad "[F] an empty outdir argument: rc $RC"
hasnt "$ERR" Traceback "[F] an empty outdir argument: a message, not a traceback"
for r in --help -q; do
  mkdir -p "$OF/opt"; ex "$r" "$OF/opt"; refused "a rev shaped like an option ($r)" "$OF/opt"
done
ex "$R1" "$OF/missing-parent/x/y"
eq "$RC:$DIG" "0:$D1" "[F] an outdir that does not exist yet is created (rc 0, R1's digest)"
CR=$(printf 'a\r\nb\r\n' | git_ -C "$FX" hash-object -w --no-filters --stdin)
R=$(mkrev attr "printf 'crlf.txt text\n' > plugins/vibemaestro-sdlc/.gitattributes && git_ add -f plugins/vibemaestro-sdlc/.gitattributes && git_ update-index --add --cacheinfo 100644,$CR,plugins/vibemaestro-sdlc/crlf.txt")
eq "$(git_ -C "$FX" cat-file blob "$R:plugins/vibemaestro-sdlc/crlf.txt" | od -c | grep -c '\\r')" 1 "[F] control: the committed blob holds CR bytes"
mkdir -p "$OF/attr"; ex "$R" "$OF/attr"
[ "$RC" -ne 0 ] && ok "[F] a tree git add would rewrite (.gitattributes text on a CRLF file): refused (rc $RC)" ||
  bad "[F] a tree git add would rewrite: exported"
empty "$DIG" "[F] the rewritten tree: no digest"
has "$ERR" crlf.txt "[F] the mismatch refusal names the file"

echo "== [W] the work tree never reaches the export =="
WMARK=$(printf 'K2X%s' WORKTREE)
printf '%s untracked\n' "$WMARK" > "$FX/plugins/vibemaestro-sdlc/UNTRACKED.txt"
printf '%s dirty\n' "$WMARK" >> "$FX/README.md"
printf '%s staged\n' "$WMARK" > "$FX/plugins/vibemaestro-brain/STAGED.txt"; git_ -C "$FX" add plugins/vibemaestro-brain/STAGED.txt
OW="$TMP/ow"; ex HEAD "$OW"
eq "$RC:$DIG" "0:$D1" "[W] export of HEAD with a dirty work tree: rc 0 and R1's digest"
empty "$(grep -rlF "$WMARK" "$OW")" "[W] no untracked, modified or staged content in the export"
eq "$(manifest "$OW")" "$(manifest "$O1")" "[W] the export equals the clean one"
git_ -C "$FX" reset -q --hard; rm -f "$FX/plugins/vibemaestro-sdlc/UNTRACKED.txt"

echo "== [V] the version: the CHANGELOG's released version written into each exported manifest, and the range on siblings =="
# relcl <version> <plugin>... — (in $FX) a release: `## <version>` on top of each named plugin's CHANGELOG, staged
relcl() {
  local v=$1 n; shift
  for n in "$@"; do
    python3 - "plugins/$n/CHANGELOG.md" "$v" <<'PY'
import sys
p, v = sys.argv[1:3]; t = open(p).read(); i = t.find("\n## ")
open(p, "w").write(t[:i + 1] + "## %s\n\n- minor: first\n\n" % v + t[i + 1:] if i >= 0 else t.rstrip("\n") + "\n\n## %s\n" % v)
PY
    git_ add "plugins/$n/CHANGELOG.md"
  done
}
# mf <outdir> <plugin> <python expr on m> — a value of an exported manifest
mf() { python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1/plugins/$2/.claude-plugin/plugin.json" "$3"; }
for n in $PLUGINS; do
  eq "$(git_ -C "$FX" show "$R1:plugins/$n/.claude-plugin/plugin.json" | python3 -c 'import json,sys; print("version" in json.load(sys.stdin))')" False \
    "[V] instrument: R1's $n manifest carries no version (the private form)"
  eq "$(git_ -C "$FX" show "$R1:plugins/$n/CHANGELOG.md" | grep -cE '^## [0-9]+\.[0-9]+\.[0-9]+[[:space:]]*$')" 0 \
    "[V] instrument: R1's $n CHANGELOG has no released \`## X.Y.Z\` section (unreleased)"
done
RV=$(mkrev rel 'relcl 0.1.0 vibemaestro-sdlc vibemaestro-brain')
OV="$TMP/ov"; ex "$RV" "$OV"
eq "$RC" 0 "[V1] a released rev exports: rc 0"
for n in $PLUGINS; do
  eq "$(mf "$OV" "$n" 'list(m)[:2], m["version"]')" "(['name', 'version'], '0.1.0')" "[V1] $n: version 0.1.0 from its CHANGELOG, right after name"
done
for n in vibemaestro-brain; do
  eq "$(mf "$OV" "$n" 'm["dependencies"]')" "[{'name': 'vibemaestro-sdlc', 'version': '>=0.1.0'}]" "[V1] $n: the bare sdlc dependency becomes >=0.1.0"
done
for n in $PLUGINS; do
  eq "$(mf "$OV" "$n" 'm["repository"], list(m)[-1]')" "('https://github.com/vibemaestro/vibemaestro-kit', 'repository')" \
    "[V1] $n: repository is the default public repository, last (the update reminder reads it)"
done
eq "$DIG" "$(plan_digest "$OV")" "[V1] the digest is still the tree of the written directory"
OV2="$TMP/ov2"; ex "$RV" "$OV2"; eq "$(manifest "$OV2")" "$(manifest "$OV")" "[V1] …and a second export of the rev is the same tree"
for n in $PLUGINS; do
  eq "$(cmp -s "$O1/plugins/$n/.claude-plugin/plugin.json" <(git_ -C "$FX" show "$R1:plugins/$n/.claude-plugin/plugin.json") && echo same)" same \
    "[V2] unreleased (R1): $n's manifest exported byte for byte"
  has "$(cd "$FX" && bash "$EXPORT" "$R1" "$(mktemp -d "$TMP/ow.XXXXXX")" 2>&1 >/dev/null)" "WARN plugins/$n has no released version" "[V2] …with a WARN for $n"
done
RM=$(mkrev mismatch 'relcl 0.1.0 vibemaestro-sdlc; python3 -c "import json; p=\"plugins/vibemaestro-sdlc/.claude-plugin/plugin.json\"; m=json.load(open(p)); m[\"version\"]=\"9.9.9\"; json.dump(m, open(p, \"w\"))"; git_ add -A')
OM="$TMP/om"; ex "$RM" "$OM"; refused "a manifest version that differs from its CHANGELOG's" "$OM"
RP=$(mkrev prereset 'relcl 2.30.0 vibemaestro-sdlc; python3 -c "import json; p=\"plugins/vibemaestro-sdlc/.claude-plugin/plugin.json\"; m=json.load(open(p)); m[\"version\"]=\"2.30.0\"; json.dump(m, open(p, \"w\"), indent=2)"; git_ add -A')
OP="$TMP/op"; ex "$RP" "$OP"
eq "$RC:$(python3 -c 'import json,sys; a=json.load(open(sys.argv[1])); b=json.loads(sys.stdin.read()); r=a.pop("repository", None); print(a == b and list(a) == list(b), r)' "$OP/plugins/vibemaestro-sdlc/.claude-plugin/plugin.json" < <(git_ -C "$FX" show "$RP:plugins/vibemaestro-sdlc/.claude-plugin/plugin.json"))" \
  "0:True https://github.com/vibemaestro/vibemaestro-kit" \
  "[V3] a manifest whose version equals its CHANGELOG's (a pre-reset rev) is exported as it is, plus repository"
O4="$TMP/o4"; DIG=$(cd "$FX" && bash "$EXPORT" --repository acme/kit.x "$RV" "$O4" 2>"$TMP/ex.err"); RC=$?
eq "$RC" 0 "[V4] --repository acme/kit.x: rc 0"
for n in $PLUGINS; do
  eq "$(mf "$O4" "$n" 'm["repository"]')" "https://github.com/acme/kit.x" "[V4] $n: repository is the one given"
done
eq "$DIG" "$(plan_digest "$O4")" "[V4] …and the digest is the written tree"
for v in acme acme/kit/x -acme/kit acme/.. acme/. "acme/ki t" https://github.com/acme/kit "" acme/kit$'\n'; do
  OX=$(mktemp -d "$TMP/o4x.XXXXXX"); OUT=$(cd "$FX" && bash "$EXPORT" --repository "$v" "$RV" "$OX" 2>/dev/null); RC=$?
  eq "$RC:$OUT:$(ls -A "$OX" | wc -l | tr -d ' ')" "2::0" "[V4] --repository '$v': rc 2, no digest, nothing written"
done
OX=$(mktemp -d "$TMP/o4x.XXXXXX"); (cd "$FX" && bash "$EXPORT" "$RV" "$OX" --repository acme/kit >/dev/null 2>&1); RC=$?
eq "$RC" 2 "[V4] --repository after the positional arguments: rc 2 (usage)"
RR=$(mkrev ownrepo 'relcl 0.1.0 vibemaestro-sdlc; python3 -c "import json; p=\"plugins/vibemaestro-sdlc/.claude-plugin/plugin.json\"; m=json.load(open(p)); m[\"repository\"]=\"https://github.com/other/kit\"; json.dump(m, open(p, \"w\"))"; git_ add -A')
ORP="$TMP/orepo"; ex "$RR" "$ORP"; refused "a source manifest whose repository is another one" "$ORP"
ORP2="$TMP/orepo2"; DIG=$(cd "$FX" && bash "$EXPORT" --repository other/kit "$RR" "$ORP2" 2>/dev/null); RC=$?
eq "$RC:$(mf "$ORP2" vibemaestro-sdlc 'm["repository"]')" "0:https://github.com/other/kit" "[V5] …and the same repository given: rc 0, kept"
# relct <version> <line> <plugin>... — (in $FX) relcl, the new section starting with <line> (release.py cut's `Released together:`)
relct() {  # builds the export's input, not a break
  local v=$1 l=$2 n; shift 2
  for n in "$@"; do
    python3 - "plugins/$n/CHANGELOG.md" "$v" "$l" <<'PY'
import sys
p, v, l = sys.argv[1:4]; t = open(p).read(); i = t.find("\n## ")
open(p, "w").write(t[:i + 1] + "## %s\n\n%s\n\n- minor: more\n\n" % (v, l) + t[i + 1:])
PY
    git_ add "plugins/$n/CHANGELOG.md"
  done
}
# exc <rev> <outdir> — ex for a run that must be refused (through capped)
exc() { DIG=$(cd "$FX" && capped bash "$EXPORT" "$1" "$2" 2>"$TMP/ex.err"); RC=$?; ERR=$(cat "$TMP/ex.err"); }
TOG="Released together: vibemaestro-sdlc"
B_CMDS="relcl 0.1.0 vibemaestro-sdlc vibemaestro-brain; relct 0.2.0 '$TOG 0.2.0, vibemaestro-brain 0.2.0' vibemaestro-sdlc vibemaestro-brain"
RB=$(mkrev floor-b "$B_CMDS")
RC2=$(mkrev floor-c "$B_CMDS; relct 0.3.0 '$TOG 0.3.0, vibemaestro-brain 0.2.0' vibemaestro-sdlc")
OB="$TMP/ofb"; ex "$RB" "$OB"
eq "$RC" 0 "[V6] a release whose brain section names sdlc 0.2.0: rc 0"
eq "$(mf "$OB" vibemaestro-brain 'm["version"], m["dependencies"]')" "('0.2.0', [{'name': 'vibemaestro-sdlc', 'version': '>=0.2.0'}])" \
  "[V6] brain 0.2.0 needs the sdlc it was released with: >=0.2.0"
eq "$DIG" "$(plan_digest "$OB")" "[V6] …and the digest is the written tree"
OC="$TMP/ofc"; ex "$RC2" "$OC"
eq "$RC:$(mf "$OC" vibemaestro-sdlc 'm["version"]')" "0:0.3.0" "[V7] a later release of sdlc alone: rc 0, sdlc 0.3.0"
eq "$(cmp "$OB/plugins/vibemaestro-brain/.claude-plugin/plugin.json" "$OC/plugins/vibemaestro-brain/.claude-plugin/plugin.json" && echo same)" same \
  "[V7] …brain's version did not move: its exported manifest is byte for byte the earlier release's"
eq "$(mf "$OC" vibemaestro-brain 'm["dependencies"]')" "[{'name': 'vibemaestro-sdlc', 'version': '>=0.2.0'}]" "[V7] …still >=0.2.0"
eq "$(cmp -s "$OB/plugins/vibemaestro-sdlc/.claude-plugin/plugin.json" "$OC/plugins/vibemaestro-sdlc/.claude-plugin/plugin.json" || echo moved)" moved \
  "[V7] …while sdlc's manifest moved (control)"
RN=$(mkrev floor-none "relcl 0.1.0 vibemaestro-sdlc vibemaestro-brain; relct 0.2.0 'Released together: vibemaestro-brain 0.2.0, other 1.0.0' vibemaestro-sdlc vibemaestro-brain")
ON="$TMP/ofn"; ex "$RN" "$ON"
eq "$RC:$(mf "$ON" vibemaestro-brain 'm["dependencies"]')" "0:[{'name': 'vibemaestro-sdlc', 'version': '>=0.1.0'}]" \
  "[V8] a line that does not name sdlc: >=0.1.0, as a section with no line ([V1])"
RX=$(mkrev floor-bad "relcl 0.1.0 vibemaestro-sdlc vibemaestro-brain; relct 0.2.0 '$TOG 0.2, vibemaestro-brain 0.2.0' vibemaestro-sdlc vibemaestro-brain")
OXB="$TMP/ofx"; exc "$RX" "$OXB"; refused "a \`Released together:\` line that does not read" "$OXB"
eq "$RC" 3 "[V9] …rc 3"; has "$ERR" "is not \`Released together: <name> X.Y.Z" "[V9] …naming the line's form"
RH=$(mkrev floor-high "relcl 0.1.0 vibemaestro-sdlc vibemaestro-brain; relct 0.2.0 '$TOG 0.3.0, vibemaestro-brain 0.2.0' vibemaestro-sdlc vibemaestro-brain")
OH="$TMP/ofh"; exc "$RH" "$OH"; refused "a floor above the sibling's released version" "$OH"
eq "$RC" 3 "[V10] …rc 3"; has "$ERR" "needs vibemaestro-sdlc >=0.3.0" "[V10] …naming the floor no install could meet"
# spaced <version> <plugin> — (in $FX) its `## <version>` heading written `##  <version>` (two spaces), staged
spaced() {  # builds the export's input, not a break
  sed "s/^## $1\$/##  $1/" "plugins/$2/CHANGELOG.md" > "$TMP/spaced.md" && cat "$TMP/spaced.md" > "plugins/$2/CHANGELOG.md" && git_ add "plugins/$2/CHANGELOG.md"
}
RS=$(mkrev floor-space "$B_CMDS; spaced 0.2.0 vibemaestro-brain")
OS="$TMP/ofs"; ex "$RS" "$OS"
eq "$RC:$(mf "$OS" vibemaestro-brain 'm["version"], m["dependencies"]')" "0:('0.2.0', [{'name': 'vibemaestro-sdlc', 'version': '>=0.2.0'}])" \
  "[V11] a released heading with two spaces (\`##  0.2.0\`): the version and the floor read from the same section"
RE=$(mkrev floor-empty "relcl 0.1.0 vibemaestro-sdlc vibemaestro-brain; relct 0.2.0 'Released together: ' vibemaestro-sdlc vibemaestro-brain")
OE="$TMP/ofe"; exc "$RE" "$OE"; refused "an empty \`Released together:\` line" "$OE"
eq "$RC" 3 "[V12] …rc 3, not a silent >=0.1.0"
RT=$(mkrev floor-two "relcl 0.1.0 vibemaestro-sdlc vibemaestro-brain; relct 0.2.0 '$TOG 0.2.0, vibemaestro-brain 0.2.0
$TOG 0.1.0, vibemaestro-brain 0.2.0' vibemaestro-sdlc vibemaestro-brain")
OT="$TMP/oft"; exc "$RT" "$OT"; refused "two \`Released together:\` lines in one section" "$OT"
eq "$RC" 3 "[V12] …rc 3"
echo "== [I] isolated install from the export =="
if ! command -v claude >/dev/null 2>&1; then
  if [ "${PLUGIN_REQUIRE_CLAUDE:-}" = 1 ]; then bad "no 'claude' while PLUGIN_REQUIRE_CLAUDE=1"; else
    echo "  SKIP *** no 'claude' on this machine: the install cases [I] did NOT run ***"; fi
  echo; summary; exit $?
fi
APP="$TMP/app"; mk_app "$APP"
# install <export dir> <config dir> <plugin…> — marketplace add, then each install; prints one "rc" line per step
install() {
  local mk=$1 cfg=$2 p; shift 2
  mkdir -p "$cfg"
  CLAUDE_CONFIG_DIR="$cfg" claude plugin marketplace add "$mk" >"$TMP/cl.out" 2>&1; echo "marketplace add rc $?"
  for p in "$@"; do CLAUDE_CONFIG_DIR="$cfg" claude plugin install "$p@vibemaestro" >"$TMP/cl.out" 2>&1; echo "install $p rc $?"; done
}
ipath() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["plugins"][sys.argv[2] + "@vibemaestro"][0]["installPath"])' "$1/plugins/installed_plugins.json" "$2"; }
# sdlc_ctx <installPath> <n> — the additionalContext of the n-th SessionStart command of that cached sdlc
sdlc_ctx() {
  ctx "$(printf '%s' "$(p_start "$(sid)")" | CLAUDE_PLUGIN_ROOT="$1" CLAUDE_PROJECT_DIR="$APP" bash -c "$(hook_cmds "$1/hooks/hooks.json" SessionStart '' | sed -n "$2p")" 2>/dev/null)"
}
MK="$TMP/mk"; ex "$R1" "$MK"
eq "$RC:$DIG" "0:$D1" "[I] a fresh export of R1 for the install: R1's digest"
CFG="$TMP/cfg"
eq "$(install "$MK" "$CFG" $PLUGINS)" "$(echo 'marketplace add rc 0'; for p in $PLUGINS; do echo "install $p rc 0"; done)" \
  "[I] marketplace add <export> and the two installs: rc 0 each ($(tail -n 2 "$TMP/cl.out" | tr '\n' ' '))"
L=$(CLAUDE_CONFIG_DIR="$CFG" claude plugin list 2>&1)
eq "$(printf '%s\n' "$L" | grep -c 'Status: ✔ enabled')" 2 "[I] claude plugin list: 2 enabled"
for p in $PLUGINS; do
  ip=$(ipath "$CFG" "$p" 2>/dev/null)
  case "$ip" in "$CFG"/plugins/cache/*) ok "[I] $p is installed in the cache";; *) bad "[I] $p: installPath '$ip' is not in the cache";; esac
  [ -f "$ip/LICENSE" ] && [ -f "$ip/NOTICE" ] && ok "[I] the cached $p carries LICENSE and NOTICE" || bad "[I] the cached $p lacks LICENSE or NOTICE"
done
rm -rf "$MK"; [ ! -e "$MK" ] && ok "[I] the export is deleted: from here on only the cache" || bad "[I] could not delete the export"
IS=$(ipath "$CFG" vibemaestro-sdlc); IB=$(ipath "$CFG" vibemaestro-brain)
LAST=$(grep -v '^[[:space:]]*$' "$IS/rules/workflow-core.instructions.md" | tail -n 1)
C1=$(sdlc_ctx "$IS" 1); C2=$(sdlc_ctx "$IS" 2)
has "$C1" "${LAST:0:60}" "[I] cached sdlc SessionStart 1: the whole workflow core is delivered"
has "$C2" 'vibemaestro-sdlc:intake' "[I] cached sdlc SessionStart 2: the banner names the intake skill"
hasnt "$C1$C2" WARNING "[I] cached sdlc SessionStart: no WARNING"
SB=$(sid)
bstart() { printf '{"session_id":"%s","cwd":"%s","hook_event_name":"SessionStart","source":"startup"}' "$SB" "$APP" |
  (cd "$APP" && CLAUDE_PLUGIN_ROOT="$IB" CLAUDE_PROJECT_DIR="$APP" CLAUDE_CONFIG_DIR="$CFG" bash -c "$(hook_cmds "$IB/hooks/hooks.json" SessionStart '')" 2>/dev/null); }
empty "$(ctx "$(bstart)")" "[I] control: the cached brain hook is silent while the project has no brain state"
O=$(cd "$APP" && CLAUDE_CODE_SESSION_ID="$SB" CLAUDE_PROJECT_DIR="$APP" CLAUDE_CONFIG_DIR="$CFG" "$IB/bin/brain" op add --kind now --text 'export check item' 2>&1)
eq "$?" 0 "[I] the installed brain adds one item: rc 0 ($O)"
# bctx <n> — the additionalContext of the n-th SessionStart command of the cached brain, given its own input as Claude Code
# gives each command; the first writes the hand-over the later ones read, so 1 runs first
bctx() {
  ctx "$(printf '{"session_id":"%s","cwd":"%s","hook_event_name":"SessionStart","source":"startup"}' "$SB" "$APP" |
    (cd "$APP" && CLAUDE_PLUGIN_ROOT="$IB" CLAUDE_PROJECT_DIR="$APP" CLAUDE_CONFIG_DIR="$CFG" bash -c "$(hook_cmds "$IB/hooks/hooks.json" SessionStart '' | sed -n "$1p")" 2>/dev/null))"
}
BC=$(bctx 1); BA=$BC
for n in $(seq 2 "$(hook_cmds "$IB/hooks/hooks.json" SessionStart '' | wc -l)"); do BA="$BA$(bctx "$n")"; done
has "$BC" 're-injected at SessionStart:startup' "[I] the cached brain SessionStart hook prints its banner"
has "$BA" 'export check item' "[I] …with the item just added, in one of its strings"

echo; summary
