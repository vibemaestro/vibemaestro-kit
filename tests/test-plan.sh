#!/bin/bash
# =============================================================================
# The suite planner and its coverage guard: tests/plan.py, tests/suites.map, tests/map-exclusions.txt
# =============================================================================
# Run: bash tests/test-plan.sh   (in every plan: @always in tests/suites.map)
#
#   1. the real tree: `plan.py --check` is green; every tracked file, fed alone to `plan.py --paths`, wakes exactly the suites an
#      independent reading of the map and the exclusion list (groups expanded, fnmatch, an excluded path wakes nothing) says; the
#      documents of a doc-only PR wake nothing while a code file still does; test.yml's tests job runs the plan with full
#      history and no credentials;
#   2. a scratch repository with a small map, driven through real git: modify, add, delete, rename (both names), uncommitted and
#      untracked files, an excluded file, an excluded document a suite line also matches, the suite's own file, @with, a map edit (option B: only the changed line's suite), and
#      every fail-closed case (unmapped path, @full path, bad or empty base, no merge-base, map new or broken at the merge-base,
#      a changed @always/@full/@with line, a planned suite with no file) → full;
#   3. `--suites [--woken] [--old <dir>]` (the merge guard's contract): NUL-separated paths in, what CI plans for them (--woken: no
#      @always set but the suites a path wakes; @with expanded) or one line `@full <reason>` out, run with no git, no PATH and no
#      suite files; with --old a changed map line wakes its suite (option B), without it a changed map is @full; a map that does
#      not parse is rc 1;
#   4. planted breaks, each red: a planner that drops a glob (caught by the oracle of 1 over every tracked file), a planner that
#      ignores a changed map line, and for the guard an unmapped file, a stale glob, an unmapped suite, a map line for a missing
#      suite, an exclusion without a reason, a fixture the suite names but its line does not cover, and an excluded file a suite uses.
# Real git on throw-away repositories under the suite's own scratch tree; no network.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
export PYTHONDONTWRITEBYTECODE=1
PLAN="$HERE/plan.py"

# ── 1. the real tree ─────────────────────────────────────────────────────────────────────────────────────────────────
echo "== the real tree =="
O=$(python3 "$PLAN" --check 2>&1); rc=$?
eq "$rc" 0 "plan.py --check on this tree: rc 0 ($(printf '%s' "$O" | tail -1))"
[ "$rc" = 0 ] || printf '%s\n' "$O" | head -20
# the planner's list of what a published tree lacks is this repository's public.private (a private checkout holds the config)
if [ -f "$SRC_ROOT/.vibemaestro/sdlc.json" ]; then
  eq "$(python3 -c 'import json, sys; print(sorted(json.load(open(sys.argv[1]))["public"]["private"]))' "$SRC_ROOT/.vibemaestro/sdlc.json")" \
     "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import plan; print(sorted(plan.PRIVATE_FILES))' "$HERE")" \
     "plan.py PRIVATE_FILES equals public.private of .vibemaestro/sdlc.json"
fi

# The oracle: an independent reading of the map. It shares no code with plan.py, so a planner that drops a glob, a group or the
# suite's own file disagrees with it on some tracked file.
cat > "$TMP/oracle.py" <<'PY'
import fnmatch, sys
groups, suites = {}, {}
excl = [l.split()[0] for l in open(sys.argv[2], encoding="utf-8") if l.split() and not l.startswith("#")]
for line in open(sys.argv[1], encoding="utf-8"):
    w = line.split("#", 1)[0].split()
    if not w or w[0].startswith("@"):
        continue
    (groups if w[0].startswith("%") else suites)[w[0]] = w[1:]
def expand(ws):
    out = []
    for x in ws:
        out += expand(groups[x]) if x.startswith("%") else [x]
    return out
pats = {s: expand(ws) for s, ws in suites.items()}
for p in sys.stdin.read().splitlines():
    hit = sorted(s for s, ps in pats.items() if p == "tests/test-%s.sh" % s or any(fnmatch.fnmatchcase(p, g) for g in ps))
    if any(fnmatch.fnmatchcase(p, g) for g in excl):
        hit = []
    print("%s\t%s" % (p, " ".join(hit)))
PY
# a read of the real tree, not a fixture repository: plain git (git_ is pinned to the scratch tree), without the variables that move it
FILES=$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -C "$SRC_ROOT" ls-files)
NF=$(printf '%s\n' "$FILES" | grep -c .)
[ "$NF" -gt 300 ] && ok "instrument: the tracked list is the real one ($NF files)" || bad "instrument: only $NF tracked files listed"
oracle_vs() {  # oracle_vs <plan.py> <map> → the lines where the planner and the oracle disagree
  diff <(printf '%s\n' "$FILES" | python3 "$1" --paths) <(printf '%s\n' "$FILES" | python3 "$TMP/oracle.py" "$2" "$(dirname "$2")/map-exclusions.txt")
}
D=$(oracle_vs "$PLAN" "$HERE/suites.map")
empty "$D" "every tracked file ($NF): plan.py --paths wakes exactly the suites the oracle reads from the map"
WAKES=$(printf '%s\n' "$FILES" | python3 "$PLAN" --paths | awk -F'\t' '$2 != ""' | grep -c .)
[ "$WAKES" -gt 200 ] && ok "instrument: the comparison is not vacuous ($WAKES files wake at least one suite)" || bad "instrument: only $WAKES files wake a suite"

# planted: a planner that drops the last glob of every line — the oracle over every tracked file must catch it
mkdir -p "$TMP/mut/tests"; cp "$HERE/suites.map" "$HERE/map-exclusions.txt" "$TMP/mut/tests/"
sed 's/or hit(path, globs)}/or hit(path, globs[:-1])}/' "$PLAN" > "$TMP/mut/tests/plan.py"
ne "$(cmp -s "$PLAN" "$TMP/mut/tests/plan.py"; echo $?)" 0 "instrument: the planted planner differs from the real one"
nonempty "$(oracle_vs "$TMP/mut/tests/plan.py" "$HERE/suites.map")" "planted: a planner that drops a glob disagrees with the oracle (red)"

# CI tests code, not documents: every document wakes nothing (a PR that touches a plugin README, its .changes/ entry and
# its kb/ records), while every script, skill and rule of a plugin still wakes a suite. Picked by pattern, not named: a path named
# here would count as a file this suite uses.
DOCS=$(printf '%s\n' "$FILES" | grep -E '^(plugins/[^/]+/(README[^/]*[.]md|CHANGELOG[.]md)|[.]changes/|kb/|docs/|README[^/]*[.]md|DEVELOPMENT[.]md)')
CODE=$(printf '%s\n' "$FILES" | grep -E '^plugins/[^/]+/(scripts|skills|rules|hooks)/')
[ "$(printf '%s\n' "$DOCS" | grep -cE '^plugins/[^/]+/README')" -ge 4 ] && ok "instrument: the plugin READMEs are among the documents" || bad "instrument: the plugin READMEs were not picked"
[ "$(printf '%s\n' "$CODE" | grep -c .)" -ge 60 ] && ok "instrument: $(printf '%s\n' "$CODE" | grep -c .) plugin code files picked" || bad "instrument: too few plugin code files picked"
eq "$(printf '%s\n' "$DOCS" | python3 "$PLAN" --paths | awk -F'\t' '$2 != ""')" "" "every document ($(printf '%s\n' "$DOCS" | grep -c .)) wakes no suite"
eq "$(printf '%s\n' "$CODE" | python3 "$PLAN" --paths | awk -F'\t' '$2 == ""')" "" "every plugin script, skill, rule and hook file still wakes a suite"

# CI runs the plan: full history (merge-base), no credentials in the clone, base from the event, no depth-1 fetch over it
WF="$SRC_ROOT/.github/workflows/test.yml"
O=$(python3 - "$WF" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
j = d["jobs"]["tests"]; steps = j["steps"]
co = [s for s in steps if str(s.get("uses", "")).startswith("actions/checkout@")]
run = [s for s in steps if "run-all.sh" in str(s.get("run", ""))]
print("checkout=%d" % len(co))
print("depth=%s" % (co[0].get("with", {}).get("fetch-depth") if co else None))
print("creds=%s" % (co[0].get("with", {}).get("persist-credentials") if co else None))
print("run=%s" % (run[0]["run"].strip() if run else ""))
print("base=%s" % (run[0].get("env", {}).get("BASE", "") if run else ""))
print("shallow=%d" % sum("--depth" in str(s.get("run", "")) for s in steps))
print("on=%s" % sorted((d.get("on") or d.get(True)).keys()))
print("perms=%s" % d.get("permissions"))
print("name=%s" % j.get("name"))
PY
)
has "$O" "checkout=1" "test.yml tests job: one checkout"
has "$O" "depth=0" "test.yml tests job: fetch-depth 0 (the planner needs the merge-base)"
has "$O" "creds=False" "test.yml tests job: persist-credentials false (no token in the clone the suites read)"
has "$O" 'run=bash tests/run-all.sh --changed "$BASE"' "test.yml tests job: runs the plan, bash tests/run-all.sh --changed \"\$BASE\""
has "$O" "base=\${{ github.event_name == 'pull_request' && github.event.pull_request.base.sha || github.event.before }}" "test.yml: BASE is the PR base, or the push's before"
has "$O" "shallow=0" "test.yml tests job: no --depth fetch (it would make the full clone shallow)"
has "$O" "on=['pull_request', 'push']" "test.yml: still on pull_request and push"
has "$O" "perms={'contents': 'read'}" "test.yml: permissions still contents: read only"
hasnt "$(cat "$WF")" "pull_request_target" "test.yml: no pull_request_target"
eq "$(printf '%s\n' "$O" | grep '^name=')" "name=bash tests/run-all.sh" "test.yml: the tests job keeps the check name bash tests/run-all.sh (branch protection may require it)"

# ── 2. a scratch repository ──────────────────────────────────────────────────────────────────────────────────────────
echo "== the planner on real git =="
R="$TMP/r"
mk_scratch() {  # a repository with three suites, a guard suite, a fixture, an exclusion and a small map; one commit on main
  rm -rf "$R"; mkdir -p "$R/tests/fixtures" "$R/src" "$R/docs" "$R/other" "$R/plugins/pp/sub"
  cp "$PLAN" "$R/tests/plan.py"
  for s in a b c plan; do printf '#!/bin/bash\necho %s\n' "$s" > "$R/tests/test-$s.sh"; done
  printf '#!/bin/bash\n. "$HERE/fixtures/fa.sh"\n' > "$R/tests/test-a.sh"
  printf 'x=1\n' > "$R/tests/fixtures/fa.sh"
  # c copies a plugin directory through a variable: `$PL/sub` must be read as plugins/pp/sub
  printf '#!/bin/bash\nPL="$SRC_ROOT/plugins/pp"\ncp -R "$PL/sub" "$TMP/x"\n' > "$R/tests/test-c.sh"
  printf 'print(1)\n' > "$R/plugins/pp/sub/x.py"
  printf 'readme\n' > "$R/plugins/pp/README.md"
  printf 'lib\n' > "$R/tests/fixtures/lib.sh"
  printf 'run\n' > "$R/tests/run-all.sh"
  for f in a.txt a2.txt b.txt c.txt b-notes.md; do printf '%s\n' "$f" > "$R/src/$f"; done
  printf 'doc\n' > "$R/docs/x.md"
  cat > "$R/tests/suites.map" <<'MAP'
@full tests/plan.py tests/map-exclusions.txt tests/run-all.sh tests/fixtures/lib.sh
@always plan
@with b c
%src-a src/a*
a %src-a tests/fixtures/fa.sh
b src/b*
c src/c* plugins/pp/sub/*
plan tests/suites.map plugins/pp/README.md
MAP
  printf 'docs/*  documents no suite reads\nsrc/*.md  documents, although the line of b matches them\n' > "$R/tests/map-exclusions.txt"
  git_ init -q -b main "$R" && git_ -C "$R" add -A && git_ -C "$R" -c user.name=t -c user.email=t@t.invalid commit -qm base
}
cm() { git_ -C "$R" add -A && git_ -C "$R" -c user.name=t -c user.email=t@t.invalid commit -qm "$1"; }
pl() { python3 "$R/tests/plan.py" "$@" 2>"$TMP/err" | tr '\n' ' ' | sed 's/ $//'; }
ALL="a b c plan"
case_() {  # case_ <label> <expected plan> <base> [<head>] — run the planner, compare
  local got; got=$(pl "${@:3}"); eq "$got" "$2" "$1 → [$2] ($(cat "$TMP/err"))"
}

mk_scratch
eq "$(python3 "$R/tests/plan.py" --check | tail -1)" "plan --check: ok (18 tracked files, 4 suites)" "control: the scratch map passes the guard"
git_ -C "$R" checkout -qb w
printf 'more\n' >> "$R/src/a.txt"; cm m
case_ "a modified file wakes its suite (through a group)" "a plan" main w
git_ -C "$R" reset -q --hard main
printf 'n\n' > "$R/src/a-new.txt"; cm add
case_ "an added file wakes the suite whose glob matches" "a plan" main w
git_ -C "$R" reset -q --hard main
git_ -C "$R" rm -q src/c.txt; cm del
case_ "a deleted file wakes its suite" "c plan" main w
git_ -C "$R" reset -q --hard main
git_ -C "$R" mv src/a2.txt src/b2.txt; cm mv
case_ "a rename wakes the suites of both names (and @with b c)" "a b c plan" main w
git_ -C "$R" reset -q --hard main
printf 'x\n' >> "$R/tests/fixtures/fa.sh"; cm fx
case_ "a fixture on a suite's line wakes it" "a plan" main w
git_ -C "$R" reset -q --hard main
printf 'echo c2\n' >> "$R/tests/test-c.sh"; cm self
case_ "a suite's own file wakes it" "c plan" main w
git_ -C "$R" reset -q --hard main
printf 'y\n' >> "$R/docs/x.md"; cm doc
case_ "an excluded file wakes nothing: the @always set" "plan" main w
git_ -C "$R" reset -q --hard main
printf 'y\n' >> "$R/src/b-notes.md"; cm bdoc
case_ "an excluded document wakes nothing although a suite line matches it" "plan" main w
printf 'y\n' >> "$R/src/b.txt"; cm bcode
case_ "…while a code file on the same line still wakes it (+ @with)" "b c plan" main w
git_ -C "$R" reset -q --hard main
case_ "an empty diff: the @always set" "plan" main w
printf 'z\n' >> "$R/src/c.txt"
case_ "no head: an uncommitted change counts" "c plan" main
git_ -C "$R" checkout -q -- src/c.txt
printf 'u\n' > "$R/src/a-untracked.txt"
case_ "no head: an untracked file counts" "a plan" main
rm -f "$R/src/a-untracked.txt"
mkdir -p "$R/other"; printf 'z\n' > "$R/other/z.txt"; cm unmapped
case_ "fail closed: a path in no line and not excluded → full" "$ALL" main w
has "$(cat "$TMP/err")" "plan: full — \`other/z.txt\` matches no suite and no exclusion" "…and stderr names the path"
git_ -C "$R" reset -q --hard main
printf '\n' >> "$R/tests/fixtures/lib.sh"; cm full
case_ "fail closed: an @full path → full" "$ALL" main w
git_ -C "$R" reset -q --hard main
case_ "fail closed: a base that does not resolve → full" "$ALL" no-such-ref w
case_ "fail closed: an empty base → full" "$ALL" "" w
git_ -C "$R" checkout -q --orphan lone && cm lone
case_ "fail closed: no merge-base → full" "$ALL" main lone
git_ -C "$R" checkout -q -f w && git_ -C "$R" reset -q --hard main

echo "== a map edit (option B) =="
sed -i 's#^b src/b\*$#b src/b* docs/*#' "$R/tests/suites.map"; cm mapb
case_ "a changed suite line runs that suite (+ @with, + @always), not the others" "b c plan" main w
git_ -C "$R" reset -q --hard main
sed -i 's#^a %src-a tests/fixtures/fa.sh$#a %src-a#' "$R/tests/suites.map"; printf 'q\n' >> "$R/tests/fixtures/fa.sh"; cm mapa
case_ "a glob removed from a line, its file changed in the same diff: still woken (old line)" "a plan" main w
git_ -C "$R" reset -q --hard main
sed -i 's#^%src-a src/a\*$#%src-a src/a* src/z*#' "$R/tests/suites.map"; cm mapg
case_ "a changed group changes every line that uses it" "a plan" main w
git_ -C "$R" reset -q --hard main
sed -i 's#^@always plan$#@always plan c#' "$R/tests/suites.map"; cm mapalways
case_ "fail closed: a changed @always line → full" "$ALL" main w
git_ -C "$R" reset -q --hard main
sed -i 's#^@with b c$#@with b a#' "$R/tests/suites.map"; cm mapwith
case_ "fail closed: a changed @with line → full" "$ALL" main w
git_ -C "$R" reset -q --hard main
printf 'd src/d*\n' >> "$R/tests/suites.map"; printf 'd\n' > "$R/src/d.txt"; cm mapd
case_ "fail closed: a planned suite with no file → full" "$ALL" main w
git_ -C "$R" reset -q --hard main
git_ -C "$R" checkout -q --orphan nomap main && git_ -C "$R" rm -q --cached tests/suites.map &&
  git_ -C "$R" commit -qm nomap
git_ -C "$R" checkout -q -b w2 && git_ -C "$R" add tests/suites.map && cm withmap
case_ "fail closed: no map at the merge-base → full" "$ALL" nomap w2
git_ -C "$R" checkout -q -f w && git_ -C "$R" reset -q --hard main
git_ -C "$R" checkout -q -b broken main && printf 'BAD LINE @@\n' >> "$R/tests/suites.map" && cm broken
git_ -C "$R" checkout -q -b fixed && sed -i '$d' "$R/tests/suites.map" && printf 'more\n' >> "$R/src/c.txt" && cm fixed
case_ "fail closed: the map does not parse at the merge-base → full" "$ALL" broken fixed
git_ -C "$R" checkout -q -f w && git_ -C "$R" reset -q --hard main

echo "== planted: a planner that ignores a changed map line =="
sed -i 's#^b src/b\*$#b src/b* docs/*#' "$R/tests/suites.map"; cm mapb2
sed 's/            if old.suites.get(s) != m.suites.get(s) and s in m.suites:/            if False:/' "$PLAN" > "$TMP/plan-ignore.py"
ne "$(cmp -s "$PLAN" "$TMP/plan-ignore.py"; echo $?)" 0 "instrument: the planted planner differs"
cp "$TMP/plan-ignore.py" "$R/tests/plan.py"
GOT=$(pl main w)
ne "$GOT" "b c plan" "planted: ignoring the changed line of b drops b — the case above would be red (got [$GOT])"
cp "$PLAN" "$R/tests/plan.py"; git_ -C "$R" reset -q --hard main

echo "== a submodule pointer bump under ignore = all =="
# .gitmodules says `ignore = all`: a plain `git diff --name-only` hides a bump of the gitlink, so a PR that only moves the pointer
# of plugins/sm woke no suite. The gitlink is written with update-index (no clone, no network): the diff compares the two hashes.
R="$TMP/r2"; mk_scratch
SHA1=1111111111111111111111111111111111111111; SHA2=2222222222222222222222222222222222222222
printf '[submodule "sm"]\n\tpath = plugins/sm\n\turl = ./sm.git\n\tignore = all\n' > "$R/.gitmodules"
sed -i 's#^b src/b\*$#b src/b* plugins/sm#' "$R/tests/suites.map"
git_ -C "$R" add .gitmodules tests/suites.map && git_ -C "$R" update-index --add --cacheinfo "160000,$SHA1,plugins/sm" &&
  git_ -C "$R" -c user.name=t -c user.email=t@t.invalid commit -qm gitlink
git_ -C "$R" checkout -qb bump && git_ -C "$R" update-index --cacheinfo "160000,$SHA2,plugins/sm" &&
  git_ -C "$R" -c user.name=t -c user.email=t@t.invalid commit -qm bump
eq "$(git_ -C "$R" diff --name-only main bump | wc -l | tr -d ' ')" 0 "instrument: a plain git diff --name-only sees nothing of the bump (ignore = all)"
eq "$(git_ -C "$R" diff --name-only --ignore-submodules=none main bump)" "plugins/sm" "instrument: with --ignore-submodules=none it sees plugins/sm"
case_ "a gitlink bump under ignore = all wakes the suite whose glob covers it (+ @with, + @always)" "b c plan" main bump
sed 's/"--no-ext-diff", "--ignore-submodules=none", mb, h/"--no-ext-diff", mb, h/' "$PLAN" > "$TMP/plan-nosub.py"
ne "$(cmp -s "$PLAN" "$TMP/plan-nosub.py"; echo $?)" 0 "instrument: the planted planner differs from the real one"
cp "$TMP/plan-nosub.py" "$R/tests/plan.py"
GOT=$(pl main bump)
ne "$GOT" "b c plan" "planted: a planner without --ignore-submodules=none misses the bump (red; got [$GOT])"
cp "$PLAN" "$R/tests/plan.py"
R="$TMP/r"

echo "== --suites: the merge guard's contract (paths in, suites or @full out, no git, no tree) =="
# The merge guard (its --behind auto) copies the planner and its two inputs from the base commit into an empty directory and
# runs `plan.py --suites` there, NUL-separated paths on stdin, with an empty PATH: no git, no tests/test-*.sh. It asks the
# base's side with --woken (and --old <merge base's inputs> when the map changed) and the PR's side as CI plans it.
S="$TMP/suites"; rm -rf "$S"; mkdir -p "$S/tests" "$S/old/tests"
cp "$R/tests/suites.map" "$R/tests/map-exclusions.txt" "$S/tests/"; cp "$R/tests/suites.map" "$TMP/map.orig"
su() {  # su <plan.py> [--woken] [--old] -- <path>... → the planner's stdout on one line; stderr in $TMP/err, rc in SRC_RC
  local pl=$1 fl=(); shift
  while [ "$1" != -- ]; do case "$1" in --old) fl+=(--old "$S/old");; *) fl+=("$1");; esac; shift; done; shift
  cp "$pl" "$S/tests/plan.py"
  SU=$(printf '%s\0' "$@" | (cd "$S" && env -i PATH= LC_ALL=C HOME="$S" "$(command -v python3)" -I -B tests/plan.py --suites "${fl[@]}") 2>"$TMP/err")
  SRC_RC=$?
  printf '%s' "$SU" | tr '\n' ' ' | sed 's/ $//'
}
sucase() {  # sucase <label> <expected> <flags...> -- <path>...
  local label=$1 want=$2 got; shift 2
  got=$(su "$PLAN" "$@"); eq "$got" "$want" "--suites: $label → [$want] ($(cat "$TMP/err"))"
}
sucase "the PR's side: what CI plans (the @always set included)" "a plan" -- src/a.txt
sucase "--woken: a file wakes its suite (through a group), no @always" "a" --woken -- src/a.txt
sucase "--woken: @with expanded" "b c" --woken -- src/b.txt
sucase "--woken: two paths, the union" "a c" --woken -- src/a.txt src/c.txt
sucase "--woken: a suite's own file wakes it" "a" --woken -- tests/test-a.sh
sucase "--woken: an excluded file wakes nothing" "" --woken -- docs/x.md
sucase "--woken: an @always suite a path wakes stays (its own file)" "plan" --woken -- tests/test-plan.sh
sucase "--woken: an @always suite a path wakes stays (its line)" "plan" --woken -- plugins/pp/README.md
sucase "--woken, no path: nothing" "" --woken --
sucase "an @full path: one line @full" "@full \`tests/fixtures/lib.sh\` decides what runs (@full)" --woken -- src/a.txt tests/fixtures/lib.sh
sucase "a path in no line and not excluded: @full" "@full \`other/z.txt\` matches no suite and no exclusion" --woken -- other/z.txt
sucase "a path holding a newline is one path (NUL-separated)" "a" --woken -- "src/a
b.txt"
su "$PLAN" --woken -- src/a.txt >/dev/null; eq "$SRC_RC" 0 "--suites: rc 0"
for bad in "--old --woken" "--old -x" "--old= " "--woken --woken" "extra" "--woken extra" "--old a b" "--old"; do
  # shellcheck disable=SC2086
  (cd "$S" && printf 'src/a.txt\0' | env -i PATH= LC_ALL=C "$(command -v python3)" -I -B tests/plan.py --suites $bad >/dev/null 2>&1); rc=$?
  eq "$rc" 2 "--suites $bad: usage, rc 2"
done
(cd "$S" && printf 'src/a.txt\0' | env -i PATH= LC_ALL=C "$(command -v python3)" -I -B tests/plan.py --suites --old "" >/dev/null 2>&1); rc=$?
eq "$rc" 2 "--suites --old '': usage, rc 2"
sed 's/ and rest\[1\] and not rest\[1\].startswith("-"):$/:/' "$PLAN" > "$TMP/plan-su.py"
ne "$(cmp -s "$PLAN" "$TMP/plan-su.py"; echo $?)" 0 "instrument: the planted planner (that takes any --old value) differs from the real one"
(cp "$TMP/plan-su.py" "$S/tests/plan.py" && cd "$S" && printf 'src/a.txt\0' | env -i PATH= LC_ALL=C "$(command -v python3)" -I -B tests/plan.py --suites --old --woken >/dev/null 2>&1); rc=$?
ne "$rc" 2 "planted: --suites that takes --woken as the --old directory is red (rc $rc)"
# the map changed: --old <dir> holds the map from before (the guard gives the merge base's) — option B; without it, @full
cp "$TMP/map.orig" "$S/old/tests/suites.map"; sed -i 's#^b src/b\*$#b src/b* docs/*#' "$S/tests/suites.map"
sucase "--old: a changed suite line wakes that suite (+ @with), and the map wakes its own line (plan)" "b c plan" --woken --old -- tests/suites.map
sucase "a changed map without --old (the PR's side: its map is never read): @full" "@full tests/suites.map is new at this head (no map at the merge-base to compare)" -- tests/suites.map
sucase "--old, the map not among the paths: the old map is not read" "a" --woken --old -- src/a.txt
sed -i 's#^@always plan$#@always plan c#' "$S/tests/suites.map"
sucase "--old: a changed @always line → @full" "@full the @always line of tests/suites.map changed" --woken --old -- tests/suites.map
cp "$TMP/map.orig" "$S/tests/suites.map"; rm -f "$S/old/tests/suites.map"
sucase "--old with no map in <dir>: @full" "@full tests/suites.map is new at this head (no map at the merge-base to compare)" --woken --old -- tests/suites.map
cp "$TMP/map.orig" "$S/old/tests/suites.map"
cp "$S/tests/suites.map" "$TMP/map.keep"; printf 'BAD LINE @@\n' >> "$S/tests/suites.map"
su "$PLAN" --woken -- src/a.txt >/dev/null; eq "$SRC_RC" 1 "--suites: a map that does not parse → rc 1"
has "$(cat "$TMP/err")" "plan --suites: tests/suites.map:" "…stderr names the map"
cp "$TMP/map.keep" "$S/tests/suites.map"
plant_su() {  # plant_su <label> <sed expression> <expected the real planner gives> <flags...> -- <path>... — the planted one differs
  local label=$1 expr=$2 want=$3 got; shift 3
  sed "$expr" "$PLAN" > "$TMP/plan-su.py"
  ne "$(cmp -s "$PLAN" "$TMP/plan-su.py"; echo $?)" 0 "instrument: the planted planner ($label) differs from the real one"
  got=$(capped su "$TMP/plan-su.py" "$@"); ne "$got" "$want" "planted: --suites $label is red (got [$got])"
}
plant_su "--woken that keeps the @always set" 's/always=not woken, check_files=False/always=True, check_files=False/' "a" --woken -- src/a.txt
plant_su "that drops the @always set from the PR's side" 's/always=not woken, check_files=False/always=False, check_files=False/' "a plan" -- src/a.txt
plant_su "that does not expand @with" 's/^    out = with_closure(m, out)$/    pass/' "b c" --woken -- src/b.txt
plant_su "that ignores @full" 's/        if hit(p, m.full):$/        if False:/' "@full \`tests/fixtures/lib.sh\` decides what runs (@full)" --woken -- tests/fixtures/lib.sh
plant_su "that lets an unmapped path wake nothing" 's/^        if not w:$/        if False:/' "@full \`other/z.txt\` matches no suite and no exclusion" --woken -- other/z.txt
sed -i 's#^b src/b\*$#b src/b* docs/*#' "$S/tests/suites.map"
plant_su "that ignores --old" 's/        if old_dir is not None and MAP_REL in paths and os.path.isfile(os.path.join(old_dir, MAP_REL)):$/        if False:/' "b c plan" --woken --old -- tests/suites.map
plant_su "--woken whose map path does not wake its own line" 's/    if woken and MAP_REL in paths:  /    if False:  /' "b c plan" --woken --old -- tests/suites.map
cp "$TMP/map.orig" "$S/tests/suites.map"

echo "== the guard: planted breaks =="
guard() { python3 "$R/tests/plan.py" --check 2>&1; }
red() {  # red <label> <expected text> — the guard on the scratch tree as it is now is red and says so
  local o rc; o=$(capped guard); rc=$?   # capped: memory and time caps (fixtures/capped.sh)
  cap_red "$rc" "planted: $1" && return
  eq "$rc" 1 "planted: $1 → rc 1"; has "$o" "$2" "…the guard says: $2"
}
mkdir -p "$R/other"; printf 'z\n' > "$R/other/z.txt"
red "an unmapped tracked file" "\`other/z.txt\` is mapped to no suite and not excluded"
rm -f "$R/other/z.txt"
printf 'e src/e*\n' >> "$R/tests/suites.map"; printf '#!/bin/bash\n' > "$R/tests/test-e.sh"
red "a glob that matches no file" "\`src/e*\` matches no tracked file"
git_ -C "$R" checkout -q -- tests/suites.map; rm -f "$R/tests/test-e.sh"
printf '#!/bin/bash\n' > "$R/tests/test-f.sh"
red "a suite with no line" "suite \`f\` (tests/test-f.sh) has no line"
rm -f "$R/tests/test-f.sh"
printf 'g src/c*\n' >> "$R/tests/suites.map"
red "a line for a suite with no file" "maps \`g\`, but tests/test-g.sh does not exist"
git_ -C "$R" checkout -q -- tests/suites.map
printf 'src/c.txt\n' >> "$R/tests/map-exclusions.txt"
red "an exclusion without a reason" "has no reason"
git_ -C "$R" checkout -q -- tests/map-exclusions.txt
sed -i 's#^a %src-a tests/fixtures/fa.sh$#a %src-a#' "$R/tests/suites.map"
red "a fixture the suite sources but its line does not cover" "suite \`a\` uses these files but its line in tests/suites.map does not cover tests/fixtures/fa.sh"
git_ -C "$R" checkout -q -- tests/suites.map
printf 'plugins/pp/sub/x.py  planted: a file suite c copies\n' >> "$R/tests/map-exclusions.txt"
red "an excluded file a suite uses" "suite \`c\` uses \`plugins/pp/sub/x.py\`, which tests/map-exclusions.txt excludes"
git_ -C "$R" checkout -q -- tests/map-exclusions.txt
sed -i 's#^c src/c\* plugins/pp/sub/\*$#c src/c*#; s#^plan tests/suites.map plugins/pp/README.md$#plan tests/suites.map plugins/pp/*#' "$R/tests/suites.map"
red "a plugin directory the suite copies through a variable (\$PL/sub) but its line does not cover" "suite \`c\` uses these files but its line in tests/suites.map does not cover plugins/pp/sub/x.py"
git_ -C "$R" checkout -q -- tests/suites.map
eq "$(guard | tail -1)" "plan --check: ok (18 tracked files, 4 suites)" "control: the restored scratch tree is green again"

echo "== a published tree: no root kb/ =="
# the map excludes kb/*.md and maps .vibemaestro/*; a fixture holds its own kb/current-state.md and .vibemaestro/sdlc.json; suite a
# names kb/current-state.md, .vibemaestro/sdlc.json (the repo's own) and a plugin licence copy (an export makes it)
printf 'kb/*.md  private records, absent from a published tree\n' >> "$R/tests/map-exclusions.txt"
mkdir -p "$R/tests/fixtures/f/kb" "$R/tests/fixtures/f/.vibemaestro"
printf 'fixture ledger\n' > "$R/tests/fixtures/f/kb/current-state.md"; printf '{}\n' > "$R/tests/fixtures/f/.vibemaestro/sdlc.json"
sed -i 's#^b src/b\*$#b src/b* tests/fixtures/f/kb/* tests/fixtures/f/.vibemaestro/*#; s#^plan tests/suites.map plugins/pp/README.md$#plan tests/suites.map plugins/pp/README.md .vibemaestro/*#' "$R/tests/suites.map"
printf 'cat "$SRC_ROOT/kb/current-state.md" "$SRC_ROOT/.vibemaestro/sdlc.json" "$SRC_ROOT/plugins/pp/LICENSE" 2>/dev/null || true\n' >> "$R/tests/test-a.sh"
cm published
eq "$(guard | tail -1)" "plan --check: ok (20 tracked files, 4 suites)" "a tree with no root kb/ and no config: the guard is green"
cp "$R/tests/plan.py" "$TMP/plan.good"
python3 - "$R/tests/plan.py" $'        if side_only(g) and not any(fnmatch.fnmatchcase(f, g) for f in files if published_only(f)):\n            continue   # a published tree has no kb/: its exclusions there have nothing to match\n' '' <<'PY'
import sys
p, old, new = sys.argv[1:]; s = open(p).read(); assert s.count(old) == 1, "plan.py moved: update this planted break"
open(p, "w").write(s.replace(old, new))
PY
red "the kb/ exclusions must match in a tree without kb/" "\`kb/*.md\` matches no tracked file"
cp "$TMP/plan.good" "$R/tests/plan.py"
python3 - "$R/tests/plan.py" $'    return t.startswith("kb/") or t in PRIVATE_FILES' $'    return t in PRIVATE_FILES' <<'PY'
import sys
p, old, new = sys.argv[1:]; s = open(p).read(); assert s.count(old) == 1, "plan.py moved: update this planted break"
open(p, "w").write(s.replace(old, new))
PY
red "a root kb/ path read as the fixture's by its tail" "suite \`a\` uses these files but its line in tests/suites.map does not cover tests/fixtures/f/kb/current-state.md"
cp "$TMP/plan.good" "$R/tests/plan.py"

summary
