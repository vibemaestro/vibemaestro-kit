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

# capped.sh and plant.sh are not @full: lib.sh sources them, so a suite reaches them only by calling their functions. On a copy of
# this tree, the guard is red when one user's line loses the file (backends calls expect_red of ports.sh, which runs capped).
echo "== the narrowed @full: capped.sh and plant.sh =="
RT="$TMP/real"; mkdir -p "$RT"
(cd "$SRC_ROOT" && env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git ls-files -z --cached --others --exclude-standard |
  python3 -c 'import os, sys; sys.stdout.write("".join(p + "\0" for p in sys.stdin.read().split("\0") if p and os.path.isfile(p)))' |
  tar --null -T - -cf -) | tar -xf - -C "$RT"
git_ init -q "$RT" && git_ -C "$RT" add -A
rguard() { python3 "$RT/tests/plan.py" --check 2>&1; }
eq "$(rguard | tail -1)" "$(python3 "$PLAN" --check | tail -1)" "control: the guard on the copy of this tree says what it says here"
rplant() {  # rplant <label> <old line text> <new line text> <the guard's words> — the copy's map with one line changed is red
  local o rc
  python3 -I -B - "$RT/tests/suites.map" "$2" "$3" <<'PY' || { bad "planted $1: the map line moved, update the plant"; return; }
import sys
p, old, new = sys.argv[1:4]; s = open(p).read()
if s.count(old) != 1:
    sys.exit(1)
open(p, "w").write(s.replace(old, new))
PY
  o=$(capped rguard); rc=$?
  cp "$SRC_ROOT/tests/suites.map" "$RT/tests/suites.map"
  cap_red "$rc" "planted: $1" && return
  eq "$rc" 1 "planted: $1 → rc 1"; has "$o" "$4" "…the guard says: $4"
}
PORTS=ports.sh   # a variable: the literal path would count as a file this suite runs
rplant "backends loses capped.sh (it reaches it through expect_red)" "$(grep '^backends ' "$HERE/suites.map")" "$(grep '^backends ' "$HERE/suites.map" | sed 's# tests/fixtures/capped.sh##')" \
  "suite \`backends\` calls \`expect_red\` (tests/fixtures/$PORTS), which reaches tests/fixtures/capped.sh"
rplant "capped-breaks loses plant.sh" "$(grep '^capped-breaks' "$HERE/suites.map")" "$(grep '^capped-breaks' "$HERE/suites.map" | sed 's# tests/fixtures/plant.sh##')" \
  "suite \`capped-breaks\` calls \`plant_break\` (tests/fixtures/plant.sh), which reaches tests/fixtures/plant.sh"
eq "$(printf 'tests/fixtures/plant.sh\0' | python3 "$PLAN" --suites --woken | tr '\n' ' ')" "capped-breaks plan " "plant.sh wakes capped-breaks and plan (its load check copies it), not @full"
CU=$(printf 'tests/fixtures/capped.sh\0' | python3 "$PLAN" --suites --woken)
case "$CU" in @full*) bad "capped.sh is @full again: $CU";; *) [ "$(printf '%s\n' "$CU" | grep -c .)" -ge 40 ] && ok "capped.sh wakes the suites that run it ($(printf '%s\n' "$CU" | grep -c .)), not @full" || bad "capped.sh wakes only: $CU";; esac
has "$(printf 'tests/fixtures/netguard.sh\0' | python3 "$PLAN" --suites)" "@full" "netguard.sh stays @full (clean_env installs its shims in every suite)"

# lib.sh sources capped.sh and plant.sh, which only the suites that call them are planned for: anything else they do when lib.sh
# loads would reach every suite. So lib.sh is loaded twice as a suite loads it, without those files and with them, and the two shells
# must match in everything but what the files are for: rc 0 and no output; the same options, shopt, directory, umask, limits, traps
# and aliases, exported functions, disabled builtins and the command hash; every function and variable the same, the new functions
# those of the files, the new variables only NARROW_VARS (not exported). A new global there turns this red: check it changes no suite,
# then name it here. Cheap, and here because `plan` is in every plan. Not seen: open file descriptors (a listing from inside the
# shell sees its own pipe now and then: a flaky check), a file written or a process started at load, and a change that only acts
# when one of their functions runs (the suites that call it run it).
LIBSRC=$(sed -nE 's#^[[:space:]]*\.[[:space:]].*/([A-Za-z0-9_.-]+\.sh)".*#\1#p' "$HERE/fixtures/lib.sh")
FULLMAP=$(sed -n 's/^@full //p' "$HERE/suites.map")
NARROW=$(for f in $LIBSRC; do case " $FULLMAP " in *" tests/fixtures/$f "*) ;; *) echo "$f";; esac; done)
NARROW_VARS="CAP_RC_TIME CAP_RC_MEM"
[ "$(printf '%s\n' $LIBSRC | grep -c .)" -ge 3 ] && ok "instrument: lib.sh sources $(echo $LIBSRC)" || bad "instrument: lib.sh sources only [$LIBSRC]"
eq "$(echo $NARROW)" "capped.sh plant.sh" "instrument: the files lib.sh sources that are not @full"
cat > "$TMP/lib-state.py" <<'PY'
import re, sys
def read(p):   # "" for a file the shell never wrote (it exited while loading)
    try:
        with open(p, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""
def funcs(text):   # `declare -f` output: name → body
    out, cur = {}, None
    for line in text.splitlines(True):
        m = re.match(r"^([A-Za-z_][\w-]*) \(\) $", line)
        if m:
            cur = m.group(1); out[cur] = ""
        if cur:
            out[cur] += line
    return out
VOLATILE = re.compile(r"^(BASH\w*|_|FUNCNAME|LINENO|RANDOM|SRANDOM|SECONDS|EPOCH\w+|PIPESTATUS|BASHPID|COLUMNS|LINES)$")
def vars_(text):   # `declare -p` output: name → (flags, the whole line)
    out = {}
    for line in text.splitlines():
        m = re.match(r"^declare (-\S+) ([A-Za-z_]\w*)(=|$)", line)
        if m and not VOLATILE.match(m.group(2)):
            out[m.group(2)] = (m.group(1), line)
    return out
bare, full, names, allowed = sys.argv[1], sys.argv[2], set(sys.argv[3].split()), set(sys.argv[4].split())
if read(full + ".out").strip() != "rc=0":
    print("lib.sh did not load quietly with rc 0: %s" % (read(full + ".out").strip()[:300] or "the shell exited while loading lib.sh"))
for part in read(bare + ".state").split("\x1e")[1:]:
    key = part.split("\n", 1)[0]
    other = [q for q in read(full + ".state").split("\x1e")[1:] if q.split("\n", 1)[0] == key]
    if not other or other[0] != part:
        print("changed the shell state: %s" % key)
fb, ff = funcs(read(bare + ".fn")), funcs(read(full + ".fn"))
for n in sorted(fb):
    if n not in ff:
        print("lost function %s" % n)
    elif ff[n] != fb[n]:
        print("changed function %s" % n)
for n in sorted(set(ff) - set(fb) - names):
    print("new function %s, not one the files define" % n)
vb, vf = vars_(read(bare + ".vars")), vars_(read(full + ".vars"))
for n in sorted(vb):
    if n not in vf:
        print("lost variable %s" % n)
    elif vf[n] != vb[n]:
        print("changed variable %s" % n)
for n in sorted(set(vf) - set(vb)):
    if n not in allowed or "x" in vf[n][0]:
        print("new variable %s" % n)
PY
lib_loads() {  # lib_loads <fixtures dir> → empty when lib.sh loads with the narrowed files exactly as without them, else what differs
  local d="$TMP/ll-copy" f v pat names
  rm -rf "$d"; mkdir -p "$d"; for f in lib.sh $LIBSRC; do cp "$1/$f" "$d/"; done   # its own copy: the two lib-*.sh go there
  for f in lib.sh $LIBSRC; do bash -n "$d/$f" 2>/dev/null || echo "bash -n: $f does not parse"; done
  pat=$(printf '%s\n' $NARROW | sed 's/[.]/[.]/g' | paste -sd'|' -)
  grep -vE "^[[:space:]]*\.[[:space:]].*/($pat)\"" "$d/lib.sh" > "$d/lib-bare.sh"
  cp "$d/lib.sh" "$d/lib-full.sh"
  names=$(for f in $NARROW; do sed -nE 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)\(\) *\{.*/\1/p' "$d/$f"; done)
  for v in bare full; do
    rm -f "$TMP/ll-$v".*
    # shellcheck disable=SC2016
    (cd "$TMP" && env -i PATH="$PATH" HOME="$HOME" TMPDIR="$TMPDIR" bash -c '
      set -uo pipefail
      . "$1" > "$2.out" 2>&1; echo "rc=$?" >> "$2.out"
      # the hash first: a command the dump itself ran would enter it
      { printf "\036command hash\n"; hash -l 2>/dev/null
        printf "\036options\n"; set +o; shopt -p; printf "\036directory\n"; pwd; printf "\036umask\n"; umask
        printf "\036limits\n"; ulimit -a; printf "\036traps\n"; trap -p; printf "\036aliases\n"; alias -p
        printf "\036exported functions\n"; declare -Fx; printf "\036disabled builtins\n"; enable -n
      } > "$2.state" 2>&1
      declare -f > "$2.fn"; declare -p > "$2.vars"' _ "$d/lib-$v.sh" "$TMP/ll-$v")
  done
  python3 -I -B "$TMP/lib-state.py" "$TMP/ll-bare" "$TMP/ll-full" "$names" "$NARROW_VARS"
}
empty "$(lib_loads "$HERE/fixtures")" "lib.sh loads with capped.sh and plant.sh exactly as without them, but for their functions and NARROW_VARS"
LF="$TMP/libfx"
lplant() {  # lplant <label> <file> <old> <new> <words> — lib.sh does not load cleanly from a copy with one change
  local o
  rm -rf "$LF"; mkdir -p "$LF"; for f in lib.sh $LIBSRC; do cp "$HERE/fixtures/$f" "$LF/"; done
  python3 -I -B - "$LF/$2" "$3" "$4" <<'PY' || { bad "planted $1: the text moved, update the plant"; return; }
import sys
p, old, new = sys.argv[1:4]; s = open(p).read()
if s.count(old) != 1:
    sys.exit(1)
open(p, "w").write(s.replace(old, new))
PY
  o=$(capped lib_loads "$LF"); has "$o" "$5" "planted: $1 → the load check says: $5"
}
lplant "capped.sh exits at the top level" capped.sh "CAP_RC_TIME=247; CAP_RC_MEM=248" "exit 3; CAP_RC_TIME=247; CAP_RC_MEM=248" "the shell exited while loading lib.sh"
lplant "plant.sh does not parse" plant.sh "plant_break() {" "plant_break() { (" "plant.sh does not parse"
lplant "capped.sh turns on errexit" capped.sh "CAP_RC_TIME=247; CAP_RC_MEM=248" "set -e; CAP_RC_TIME=247; CAP_RC_MEM=248" "changed the shell state: options"
lplant "plant.sh prints at load" plant.sh "plant_break() {" "echo loading; plant_break() {" "did not load quietly"
A="CAP_RC_TIME=247; CAP_RC_MEM=248"
while IFS='|' read -r label code words; do
  lplant "capped.sh at load: $label" capped.sh "$A" "$code; $A" "$words"
done <<'EFFECTS'
sets umask|umask 077|changed the shell state: umask
exports a variable|export GIT_AUTHOR_DATE=x|new variable GIT_AUTHOR_DATE
sets the locale|LC_ALL=C|new variable LC_ALL
puts a directory first in PATH|PATH=/opt/x:$PATH|changed variable PATH
traps TERM|trap '' TERM INT|changed the shell state: traps
lowers a limit|ulimit -n 64|changed the shell state: limits
changes IFS|IFS=:|changed variable IFS
redefines bad|bad() { :; }|changed function bad
moves the counters|PASS=0; FAIL=-1000|changed variable FAIL
removes a function|unset -f hasnt|lost function hasnt
defines an alias|alias git=false|changed the shell state: aliases
cds|cd /|changed the shell state: directory
exports a function|export -f ok|changed the shell state: exported functions
disables a builtin|enable -n test|changed the shell state: disabled builtins
hashes a command|hash -p /bin/true zzz|changed the shell state: command hash
EFFECTS

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
print("env=%s" % sorted((run[0].get("env") or {}).items()) if run else "")
print("if=%s" % j.get("if"))
print("shallow=%d" % sum("--depth" in str(s.get("run", "")) for s in steps))
print("on=%s" % sorted((d.get("on") or d.get(True)).keys()))
print("perms=%s" % d.get("permissions"))
print("name=%s" % j.get("name"))
PY
)
has "$O" "checkout=1" "test.yml tests job: one checkout"
has "$O" "depth=0" "test.yml tests job: fetch-depth 0 (the planner needs the merge-base)"
has "$O" "creds=False" "test.yml tests job: persist-credentials false (no token in the clone the suites read)"
eq "$(printf '%s\n' "$O" | grep '^run=')" 'run=pr_head=$PR_HEAD; unset PR_HEAD; bash tests/run-all.sh --changed "@merge-parent:$pr_head"' \
   "test.yml tests job: runs the plan of the PR's own change, and the suites do not inherit PR_HEAD (test-export-gate.sh runs a step that reads one)"
eq "$(printf '%s\n' "$O" | grep '^env=')" "env=[('PLUGIN_REQUIRE_CLAUDE', '1'), ('PR_HEAD', '\${{ github.event.pull_request.head.sha }}')]" \
   "test.yml tests job: PR_HEAD is the event's head.sha, and no BASE (base.sha is the main of the PR's last push)"
eq "$(printf '%s\n' "$O" | grep '^if=')" "if=github.event_name == 'pull_request' && github.event.pull_request.draft == false" \
   "test.yml tests job: a ready PR only, never a push to main (the scheduled full run covers main)"
has "$O" "shallow=0" "test.yml tests job: no --depth fetch (it would make the full clone shallow)"
has "$O" "on=['pull_request', 'push']" "test.yml: still on pull_request and push (the term scan runs on push)"
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

echo "== @merge-parent:<PR head>: the PR's own change against the main it is merged with =="
# On a PR, GitHub checks out a merge commit of the PR head into the current main: main is its first parent, the PR head its second.
# The event's base.sha is the main of the PR's last push: when main moved since, a diff from it also counts what other PRs merged
# (a PR of 3 kb/ files once planned 43/69 suites). @merge-parent:<sha> diffs from the first parent, only when HEAD has exactly two parents
# and the second is <sha> (the event's head.sha): any other commit, a worker's own merge of main included, is the full suite.
MAIN0=$(git_ -C "$R" rev-parse main)
gh_merge() {  # gh_merge <branch>… — detach at main and merge the branches as GitHub does (main first parent)
  git_ -C "$R" checkout -q --detach main && git_ -C "$R" merge -q --no-ff --no-edit "$@"
}
mp() { printf '@merge-parent:%s' "$(git_ -C "$R" rev-parse "$1")"; }   # mp <PR branch> — the word test.yml passes
git_ -C "$R" checkout -q -b pr main && printf 'pr\n' >> "$R/src/a.txt" && cm pr-a
git_ -C "$R" checkout -q main && printf 'other pr\n' >> "$R/src/c.txt" && cm other-pr-c   # main moves after the PR's last push
gh_merge pr
case_ "control: the stale base.sha also plans what main merged since the PR's last push (c)" "a c plan" "$MAIN0" HEAD
case_ "@merge-parent:<PR head> (no head, as in CI): only the PR's own change" "a plan" "$(mp pr)"
has "$(cat "$TMP/err")" "plan: 2/4 suites — 1 changed path" "…and the plan line counts one path"
case_ "@merge-parent:<PR head> with the merge commit as head" "a plan" "$(mp pr)" "$(git_ -C "$R" rev-parse HEAD)"
printf 'u\n' > "$R/src/b-untracked.txt"
case_ "@merge-parent:<PR head>, no head: an untracked file in the checkout still counts" "a b c plan" "$(mp pr)"
rm -f "$R/src/b-untracked.txt"
case_ "fail closed: @merge-parent with no PR head → full" "$ALL" @merge-parent
has "$(cat "$TMP/err")" "names no PR head" "…and the plan line says why"
case_ "fail closed: @merge-parent: with an empty PR head → full" "$ALL" @merge-parent:
case_ "fail closed: a PR head that is not the merge's second parent (an older push) → full" "$ALL" "$(mp pr~1)"
has "$(cat "$TMP/err")" "is not the PR head" "…and the plan line says why"
git_ -C "$R" checkout -q -b pr-merged "$MAIN0" && printf 'pr2\n' >> "$R/src/a.txt" && cm pr2-a
git_ -C "$R" merge -q --no-edit main                                                       # the PR branch merged main (c)
case_ "fail closed: a worker's own merge of main into its branch (main is the second parent) → full" "$ALL" "$(mp pr-merged)"
git_ -C "$R" checkout -q main && printf 'third pr\n' >> "$R/src/b.txt" && cm third-pr-b    # then main moved again (b)
gh_merge pr-merged
case_ "a PR branch that merged main: still only its own change" "a plan" "$(mp pr-merged)"
git_ -C "$R" checkout -q -b pr-revert main && printf 'r\n' >> "$R/src/a.txt" && printf 'r\n' >> "$R/src/c.txt" && cm pr-ac
git_ -C "$R" checkout -q HEAD~1 -- src/c.txt && cm pr-revert-c
gh_merge pr-revert
case_ "a file changed then reverted on the PR: merging changes it not, it wakes nothing" "a plan" "$(mp pr-revert)"
git_ -C "$R" checkout -q -b pr-same "$MAIN0" && printf 'pr\n' >> "$R/src/a.txt" && printf 'other pr\n' >> "$R/src/c.txt" && cm pr-same
gh_merge pr-same
case_ "a file the PR changed exactly as main already did (c): merging changes it not, only a wakes" "a plan" "$(mp pr-same)"
git_ -C "$R" checkout -q -b pr-b main && printf 'pb\n' >> "$R/docs/x.md" && cm pr-b-doc
git_ -C "$R" checkout -q -b pr-c main && printf 'pc\n' >> "$R/src/a2.txt" && cm pr-c-a2
gh_merge pr-b pr-c
eq "$(git_ -C "$R" rev-list --parents -n 1 HEAD | wc -w | tr -d ' ')" 4 "instrument: an octopus merge with three parents"
case_ "fail closed: an octopus merge (three parents) → full" "$ALL" "$(mp pr-b)"
has "$(cat "$TMP/err")" "plan: full — " "…and the plan line says full"
git_ -C "$R" checkout -q --detach pr
case_ "fail closed: HEAD is no merge commit (one parent) → full, never the diff from its parent" "$ALL" "$(mp pr)"
has "$(cat "$TMP/err")" "is not a merge commit of two parents" "…and the plan line says why"
case_ "fail closed: a head that is no merge commit → full" "$ALL" "$(mp pr)" pr
case_ "fail closed: a root commit → full" "$ALL" "$(mp pr)" lone
case_ "fail closed: a head that does not resolve → full" "$ALL" "$(mp pr)" no-such-ref
case_ "fail closed: a PR head that does not resolve → full" "$ALL" @merge-parent:no-such-ref
gh_merge pr && git_ -C "$R" branch -q merged HEAD
SH="$TMP/shallow"; rm -rf "$SH"
git_ init -q "$SH" && git_ -C "$SH" fetch -q --depth 1 "$R" merged:merged 2>/dev/null && git_ -C "$SH" checkout -q merged
eq "$(git_ -C "$SH" rev-parse --is-shallow-repository)" true "instrument: a shallow clone of the merge commit (its parents are missing)"
GOT=$(python3 "$SH/tests/plan.py" "$(mp pr)" 2>"$TMP/err" | tr '\n' ' ' | sed 's/ $//')
eq "$GOT" "$ALL" "fail closed: a merge whose parents are missing (shallow clone) → full ($(cat "$TMP/err"))"
rm -rf "$SH"
git_ -C "$R" checkout -q -f w && git_ -C "$R" branch -q -f main "$MAIN0" && git_ -C "$R" reset -q --hard main

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

echo "== the guard: a function of a fixture an @full file sources =="
# lib.sh (@full) sources capped.sh and plant.sh, which are not @full: a suite that calls one of their functions, directly or through
# a function of another shell fixture (expect_red in ports.sh runs capped), must have the file on its line. The path references do
# not show it: the suite names lib.sh and ports.sh, never capped.sh.
R="$TMP/r3"; mk_scratch
printf '. "$(dirname "${BASH_SOURCE[0]}")/cap.sh"\n. "$(dirname "${BASH_SOURCE[0]}")/pl.sh"   # pl: plx\n' > "$R/tests/fixtures/lib.sh"
printf '# capx — the cap\ncapx() { "$@"; }\n' > "$R/tests/fixtures/cap.sh"
printf 'plx() { capx true; }\n' > "$R/tests/fixtures/pl.sh"
printf 'x=1\nera() {  # era <cmd> — through capx\n  capx "$@"\n}\nquiet() { :; }\n' > "$R/tests/fixtures/fa.sh"
printf '#!/bin/bash\n. "$HERE/fixtures/lib.sh"\n. "$HERE/fixtures/fa.sh"\nera true\n' > "$R/tests/test-a.sh"
printf '#!/bin/bash\n. "$HERE/fixtures/lib.sh"\nplx\n' > "$R/tests/test-b.sh"
# c defines and calls a function named like fa.sh's, without sourcing fa.sh; it mentions capx only in a comment
printf '#!/bin/bash\n. "$HERE/fixtures/lib.sh"\nera() { :; }\nera\n# capx is not called here\n' >> "$R/tests/test-c.sh"
sed -i 's#^a %src-a tests/fixtures/fa.sh$#a %src-a tests/fixtures/fa.sh tests/fixtures/cap.sh#; s#^b src/b\*$#b src/b* tests/fixtures/pl.sh tests/fixtures/cap.sh#' "$R/tests/suites.map"
cm functions
eq "$(guard | tail -1)" "plan --check: ok (20 tracked files, 4 suites)" "control: every suite that reaches cap.sh or pl.sh has it on its line"
sed -i 's#^a %src-a tests/fixtures/fa.sh tests/fixtures/cap.sh$#a %src-a tests/fixtures/fa.sh#' "$R/tests/suites.map"
red "a suite that reaches cap.sh through a function of a fixture it sources (era in fa.sh)" "suite \`a\` calls \`era\` (tests/fixtures/fa.sh), which reaches tests/fixtures/cap.sh that tests/fixtures/lib.sh sources, but its line in tests/suites.map does not cover tests/fixtures/cap.sh"
git_ -C "$R" checkout -q -- tests/suites.map
sed -i 's#^b src/b\* tests/fixtures/pl.sh tests/fixtures/cap.sh$#b src/b* tests/fixtures/cap.sh#' "$R/tests/suites.map"
red "a suite that calls a function of pl.sh without pl.sh on its line" "suite \`b\` calls \`plx\` (tests/fixtures/pl.sh), which reaches tests/fixtures/pl.sh"
git_ -C "$R" checkout -q -- tests/suites.map
sed -i 's#^b src/b\* tests/fixtures/pl.sh tests/fixtures/cap.sh$#b src/b* tests/fixtures/pl.sh#' "$R/tests/suites.map"
red "a suite that reaches cap.sh through a function of another sourced fixture (plx in pl.sh)" "suite \`b\` calls \`plx\` (tests/fixtures/pl.sh), which reaches tests/fixtures/cap.sh"
git_ -C "$R" checkout -q -- tests/suites.map
printf 'capx true\n' >> "$R/tests/test-c.sh"
red "a suite that calls a function of cap.sh directly" "suite \`c\` calls \`capx\` (tests/fixtures/cap.sh), which reaches tests/fixtures/cap.sh"
git_ -C "$R" checkout -q -- tests/test-c.sh
printf 'fb() { era "$@"; }\n' > "$R/tests/fixtures/fb.sh"; printf '. "$HERE/fixtures/fb.sh"\nfb x\n' >> "$R/tests/test-c.sh"
sed -i 's#^c src/c\* plugins/pp/sub/\*$#c src/c* plugins/pp/sub/* tests/fixtures/fb.sh tests/fixtures/fa.sh#' "$R/tests/suites.map"
red "a new fixture whose function reaches cap.sh through two fixtures (fb → era → capx)" "suite \`c\` calls \`fb\` (tests/fixtures/fb.sh), which reaches tests/fixtures/cap.sh"
git_ -C "$R" checkout -q -- tests/suites.map tests/test-c.sh; rm -f "$R/tests/fixtures/fb.sh"
eq "$(guard | tail -1)" "plan --check: ok (20 tracked files, 4 suites)" "control: the restored tree is green again"
# every shape of a call reaches the name: the name as a word anywhere in the code, comments dropped (quote-aware)
while IFS= read -r shape; do
  printf '%s\n' "$shape" >> "$R/tests/test-c.sh"
  red "a call shape the guard must see: $shape" "suite \`c\` calls \`capx\`"
  git_ -C "$R" checkout -q -- tests/test-c.sh
done <<'SHAPES'
eval "capx true"
trap 'capx true' RETURN
_r=capx; "$_r" true
case 1 in 1)capx true;; esac
capx>/dev/null
"capx" a b
echo "x #1"; capx true
if ! capx true; then :; fi
out=$(capx true)
x="$(echo "a #b")"; capx true
y=${x// #/}; capx true
x=$'it\'s # y'; capx true
x=$(echo a)#b; capx true
echo a\ #b; capx true
x="$(case $a in x) echo "a #b";; y) capx true;; esac)"
SHAPES
printf '# capx is named in a comment only\necho hi  # capx here too\ncapxx() { :; }; capxx\n' >> "$R/tests/test-c.sh"
eq "$(guard | tail -1)" "plan --check: ok (20 tracked files, 4 suites)" "control: a name in a comment, or inside a longer word, is no call"
git_ -C "$R" checkout -q -- tests/test-c.sh
# the body of a function runs to the `}` at its own indent: a nested definition or a heredoc that holds one does not end it
fn_case() {  # fn_case <label> <fixture text> <the guard's words> — c sources fn.sh (on its line) and calls fnc
  printf '%s\n' "$2" > "$R/tests/fixtures/fn.sh"
  printf '. "$HERE/fixtures/fn.sh"\nfnc\n' >> "$R/tests/test-c.sh"
  sed -i 's#^c src/c\* plugins/pp/sub/\*$#c src/c* plugins/pp/sub/* tests/fixtures/fn.sh#' "$R/tests/suites.map"
  red "$1" "$3"
  git_ -C "$R" checkout -q -- tests/suites.map tests/test-c.sh; rm -f "$R/tests/fixtures/fn.sh"
}
fn_case "a nested definition before the call" $'fnc() {\n  _inner() { :; }\n  capx true\n}' "suite \`c\` calls \`fnc\` (tests/fixtures/fn.sh), which reaches tests/fixtures/cap.sh"
fn_case "a heredoc holding a definition before the call" $'fnc() {\n  cat <<X\nstub() { :; }\nX\n  capx true\n}' "suite \`c\` calls \`fnc\` (tests/fixtures/fn.sh), which reaches tests/fixtures/cap.sh"
fn_case "a sibling after a definition that closes mid-line inside a multi-line quote" $'_j() { python3 -c \'\nprint(1)\' "$1"; }\nfnc() {\n  capx true\n}' "suite \`c\` calls \`fnc\` (tests/fixtures/fn.sh), which reaches tests/fixtures/cap.sh"
fn_case "a sibling after a definition with a quoted brace" $'_j() { echo "{"; }\nfnc() {\n  capx true\n}' "suite \`c\` calls \`fnc\` (tests/fixtures/fn.sh), which reaches tests/fixtures/cap.sh"
fn_case "a second definition on one line" $'helper() { :; }; fnc() { capx true; }' "suite \`c\` calls \`fnc\` (tests/fixtures/fn.sh), which reaches tests/fixtures/cap.sh"
fn_case "the same name defined twice (if/else)" $'if true; then\n  fnc() {\n    capx true\n  }\nelse\n  fnc() { :; }\nfi' "suite \`c\` calls \`fnc\` (tests/fixtures/fn.sh), which reaches tests/fixtures/cap.sh"
fn_case "a here-string with a bare word before the definition" $'a() {\n  read -r x <<< hello\n}\nfnc() {\n  capx true\n}' "suite \`c\` calls \`fnc\` (tests/fixtures/fn.sh), which reaches tests/fixtures/cap.sh"
fn_case "a here-string with a quoted word before the definition" $'a() {\n  read -r x <<< "hello"\n}\nfnc() {\n  capx true\n}' "suite \`c\` calls \`fnc\` (tests/fixtures/fn.sh), which reaches tests/fixtures/cap.sh"
fn_case "a shift by a name in (( )) before the definition" $'a() {\n  (( y = 1<<bits ))\n}\nfnc() {\n  capx true\n}' "suite \`c\` calls \`fnc\` (tests/fixtures/fn.sh), which reaches tests/fixtures/cap.sh"
fn_case "a shift by a name in \$(( )) before the definition" $'a() {\n  y=$(( 1 << n ))\n}\nfnc() {\n  capx true\n}' "suite \`c\` calls \`fnc\` (tests/fixtures/fn.sh), which reaches tests/fixtures/cap.sh"
fn_case "a subshell in a subshell ((…) && (…)) is no arithmetic: top-level code after it" $'zz() {\n  ((true) && (false))\n}\ncapx true\nfnc() { :; }' "suite \`c\` sources tests/fixtures/fn.sh, whose top-level code reaches tests/fixtures/cap.sh"
fn_case "arithmetic with inner parentheses (( y = (a+b)*2 )) before the definition" $'a() {\n  (( y = (a+b)*2<<k ))\n}\nfnc() {\n  capx true\n}' "suite \`c\` calls \`fnc\` (tests/fixtures/fn.sh), which reaches tests/fixtures/cap.sh"
fn_case "top-level code of a fixture the suite sources" $'capx true\nfnc() { :; }' "suite \`c\` sources tests/fixtures/fn.sh, whose top-level code reaches tests/fixtures/cap.sh"
R="$TMP/r"

summary
