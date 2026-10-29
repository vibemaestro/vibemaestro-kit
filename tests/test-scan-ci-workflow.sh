#!/bin/bash
# =============================================================================
# The CI job that runs the internal-term scanner with the KIT_TERMS secret (.github/workflows/test.yml, job scan-terms)
# =============================================================================
# Run: bash tests/test-scan-ci-workflow.sh
#
# The scanner has its own suite (tests/test-scan-internal-terms.sh); this one checks the
# WIRING around it, which a right scanner cannot save:
#   [S] shape, read with a YAML parser: only pull_request and push, never pull_request_target; permissions contents: read and nothing wider;
#       the secret named once, in the `env` of the one scan step; no xtrace, no `${{ }}` inside a `run:`, no artifact, no job summary, no
#       add-mask; checkout without persisted credentials; the step calls the scanner with --ci, --terms and --exclude kb/ over --tree;
#       the job's only `if` is `github.event.repository.private` (always true here; a public copy skips it, having no term list)
#   [R] the step's real `run:` block is RUN (bash, RUNNER_TEMP, the secret in KIT_TERMS) in a scratch repository with the real scanner and
#       MADE-UP terms: clean is green with `control: found 1/1; hits: 0`; a hit outside kb/ is red; a hit only in kb/ is green and counted;
#       an empty, blank or absent secret is red with a clear message; a missing RUNNER_TEMP is red; a scanner that exits 0 without the control
#       line is red; the term file is mode 0600 while the scanner runs and gone afterwards; the secret is not in the scanner's environment
#   [T] no output line of any run holds a made-up term (the log, the only place the job prints)
# Then each fault is planted in a copy of the workflow and the shape check must go red (a check that cannot go red proves nothing).
# No network, no real secret, no repository other than the scratch ones.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"

WF="$SRC_ROOT/.github/workflows/test.yml"
SCAN="$SRC_ROOT/scripts/scan-internal-terms.sh"
JOB=scan-terms
TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-scan-ci.XXXXXX"); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
export PYTHONDONTWRITEBYTECODE=1
export GIT_AUTHOR_NAME=tester GIT_AUTHOR_EMAIL=tester@example.invalid GIT_COMMITTER_NAME=tester GIT_COMMITTER_EMAIL=tester@example.invalid
net_guard_install "$TMP"
python3 -c 'import yaml' 2>/dev/null || { bad "PyYAML is missing: the workflow cannot be read"; summary; exit 1; }
[ -f "$WF" ] || { bad "$WF does not exist"; summary; exit 1; }

# ── the YAML reader: shape errors on stdout (empty = fine), or the scan step's run block with --run ─────────────────
PY=$TMP/wf.py
cat > "$PY" <<'PYEOF'
import sys, re, yaml
path, job, mode = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
wf = yaml.safe_load(text)
errs = []
def err(m): errs.append(m)
on = wf.get(True, wf.get("on"))                      # PyYAML reads the key `on` as True
trig = set(on) if isinstance(on, dict) else ({on} if isinstance(on, str) else set(on or []))
if trig != {"pull_request", "push"}: err("triggers are %s, want exactly pull_request and push" % sorted(trig))
if "pull_request_target" in text: err("pull_request_target appears in the file")
if wf.get("permissions") != {"contents": "read"}: err("top-level permissions are %r, want contents: read" % (wf.get("permissions"),))
jobs = wf.get("jobs") or {}
for name, j in jobs.items():
    if "permissions" in j and j["permissions"] != {"contents": "read"}: err("job %s widens permissions: %r" % (name, j["permissions"]))
j = jobs.get(job)
if j is None:
    err("no job %s" % job); steps = []
else:
    steps = j.get("steps") or []
    # private only, and not on a draft PR (the owner's rule: no CI on a draft; ready_for_review and every later commit run it)
    if j.get("if", "github.event.repository.private") != "github.event.repository.private && (github.event_name != 'pull_request' || github.event.pull_request.draft == false)":
        err("the job has an `if` other than github.event.repository.private (and not-a-draft): it could be skipped")
    if "if" not in j: err("the job has no `if: github.event.repository.private`: a public copy would fail closed on every PR")
    if "continue-on-error" in j: err("the job has continue-on-error")
scan = [s for s in steps if "scripts/scan-internal-terms.sh" in str(s.get("run", ""))]
if len(scan) != 1: err("want exactly one step that runs the scanner, found %d" % len(scan))
if text.count("secrets.KIT_TERMS") != 1: err("secrets.KIT_TERMS appears %d times, want 1" % text.count("secrets.KIT_TERMS"))
if re.search(r"secrets\.(?!KIT_TERMS)", text): err("another secret is read")
run = ""
if scan:
    s = scan[0]
    run = s["run"]
    if (s.get("env") or {}).get("KIT_TERMS") != "${{ secrets.KIT_TERMS }}": err("the secret is not in the scan step's env as KIT_TERMS")
    if "if" in s: err("the scan step has an `if`")
    if s.get("continue-on-error"): err("the scan step has continue-on-error")
    for need in ("--ci", "--terms", "--exclude kb/", "--tree", "!= \"control: found 1/1; hits: 0\"", "chmod 600", "RUNNER_TEMP"):
        if need not in run: err("the scan step lacks: %s" % need)
for n, jj in jobs.items():
    for s in jj.get("steps") or []:
        r = s.get("run", "")
        if "${{" in r: err("job %s has a ${{ }} inside a run block" % n)
        if re.search(r"set\s+-[a-z]*x|xtrace|\bsh -x|bash -x", r): err("job %s turns xtrace on" % n)
        if "add-mask" in r: err("job %s uses add-mask" % n)
        if "GITHUB_STEP_SUMMARY" in r: err("job %s writes a job summary" % n)
        if "upload-artifact" in str(s.get("uses", "")): err("job %s uploads an artifact" % n)
        if "secrets." in str(s.get("with", "")): err("job %s passes a secret through with:" % n)
co = [s for s in steps if str(s.get("uses", "")).startswith("actions/checkout")]
if not co or (co[0].get("with") or {}).get("persist-credentials") is not False: err("checkout does not set persist-credentials: false")
if mode == "--run":
    sys.stdout.write(run)
else:
    for e in errs: print(e)
PYEOF
shape() { python3 -B -I "$PY" "$1" "$JOB" --shape; }

echo "[S] shape"
E=$(shape "$WF")
empty "$E" "S1 the real workflow passes the shape check"
python3 -B -I "$PY" "$WF" "$JOB" --run > "$TMP/step.sh"
nonempty "$(cat "$TMP/step.sh")" "S2 the scan step's run block was extracted"

# faults planted in a copy of the workflow: each must be seen
plant() {  # plant <name> <python expression on s (the text)>
  local f=$TMP/plant-$1.yml
  python3 -B -I - "$WF" "$f" "$2" <<'PYEOF'
import sys
s = open(sys.argv[1]).read()
t = eval(sys.argv[3])
assert t != s, "the plant did not change the file"
open(sys.argv[2], "w").write(t)
PYEOF
  [ -f "$f" ] || { bad "S plant $1: not built"; return; }
  local seen crc
  seen=$(capped shape "$f"); crc=$?   # capped: memory and time caps (fixtures/capped.sh)
  cap_red "$crc" "S plant $1" && return
  [ -n "$seen" ] && ok "S plant $1 is seen" || bad "S plant $1 is NOT seen"
}
plant target 's.replace("  pull_request:\n", "  pull_request_target:\n", 1)'
plant extra-trigger 's.replace("on:\n", "on:\n  workflow_dispatch:\n", 1)'
plant perm-write 's.replace("permissions:\n  contents: read", "permissions:\n  contents: write", 1)'
plant xtrace 's.replace("set -uo pipefail", "set -xuo pipefail", 1)'
plant expr-in-run 's.replace("terms=$(mktemp", "echo ${{ secrets.KIT_TERMS }}; terms=$(mktemp", 1)'
plant no-env 's.replace("          KIT_TERMS: ${{ secrets.KIT_TERMS }}\n", "          KIT_TERMS: nothing\n", 1)'
plant no-ci 's.replace("--ci --terms", "--terms", 1)'
plant no-exclude 's.replace(" --exclude kb/", "", 1)'
plant no-control 's.replace("control: found 1/1; hits: 0", "hits: 0", 1)'
plant no-if 's.replace("    if: github.event.repository.private && (github.event_name != \x27pull_request\x27 || github.event.pull_request.draft == false)\n", "", 1)'
# the scan job is the last checkout in the file (the tests job above it keeps no credentials either): remove the last one
plant creds '"".join(s.rsplit("          persist-credentials: false\n", 1))'
plant artifact 's + "      - uses: actions/upload-artifact@v4\n        with:\n          path: x\n"'
plant summary 's.replace("          unset KIT_TERMS\n", "          unset KIT_TERMS\n          echo hi >> $GITHUB_STEP_SUMMARY\n", 1)'
plant skippable 's.replace("    if: github.event.repository.private && (github.event_name != \x27pull_request\x27 || github.event.pull_request.draft == false)\n", "    if: github.event_name == \x27push\x27\n", 1)'
plant mask 's.replace("          unset KIT_TERMS\n", "          unset KIT_TERMS\n          echo ::add-mask::x\n", 1)'

# ── the run block, run ───────────────────────────────────────────────────────────────────────────────────────────
echo "[R] the run block"
N=0
mkrepo() {  # mkrepo <name>: a scratch repository with the real scanner tracked in scripts/; prints the path
  local r=$TMP/$1
  mkdir -p "$r/scripts" "$r/kb" "$r/plugins"
  git init -q "$r" 2>/dev/null
  cp "$SCAN" "$r/scripts/scan-internal-terms.sh"
  printf 'clean\n' > "$r/README.md"; printf 'clean\n' > "$r/plugins/p.txt"; printf 'clean\n' > "$r/kb/n.md"
  git -C "$r" add -A; git -C "$r" commit -q -m init
  printf '%s' "$r"
}
put() { mkdir -p "$(dirname "$1/$2")"; printf '%s\n' "$3" > "$1/$2"; git -C "$1" add -A; git -C "$1" commit -q -m "plant"; }
SECRET=$'zorblax\nw:glim\nquuxcorp'   # made-up terms, in the scanner's term-file format
OUT=""; RC=0
step() {  # step <repo> [secret]: runs the real block; secret defaults to SECRET; "-" leaves KIT_TERMS unset
  local r=$1 sec=${2-$SECRET} rt=$TMP/rt-$((N=N+1))
  mkdir -p "$rt"
  if [ "$sec" = "-" ]; then
    OUT=$(cd "$r" && env -u KIT_TERMS RUNNER_TEMP="$rt" bash -c "$(cat "$TMP/step.sh")" 2>&1); RC=$?
  else
    OUT=$(cd "$r" && KIT_TERMS="$sec" RUNNER_TEMP="$rt" bash -c "$(cat "$TMP/step.sh")" 2>&1); RC=$?
  fi
  LEFT=$(ls -A "$rt" | wc -l | tr -d ' ')
}
no_terms() {  # no_terms <what>: no line of the last output holds a made-up term (case-insensitive)
  local t
  for t in zorblax glim quuxcorp; do
    case $(printf '%s' "$OUT" | tr 'A-Z' 'a-z') in *"$t"*) bad "$1: the output holds the term '$t'"; return ;; esac
  done
  ok "$1: no term in the output"
}

R=$(mkrepo r-clean)
step "$R"
eq "$RC" 0 "R1 clean tree, good secret: green"
eq "${OUT##*$'\n'}" "control: found 1/1; hits: 0" "R1 the scan line is the last line of the log"
has "$OUT" "control: found 1/1; hits: 0" "R1 the log has the scan line"
has "$OUT" "excluded under kb/: 0 hits" "R1 the log has the exclusion count"
has "$OUT" "terms: 3" "R1 the log has the number of terms (a count, a badly pasted list shows here)"
eq "$LEFT" 0 "R1 the term file is removed afterwards"
no_terms "R1"

R=$(mkrepo r-out); put "$R" "plugins/leak.txt" "the quuxcorp name"
step "$R"
ne "$RC" 0 "R2 a hit outside kb/: red"
has "$OUT" "tree plugins/leak.txt term=1:3" "R2 the hit is reported as a location and a term index"
has "$OUT" "::error::" "R2 an error annotation says it failed"
eq "$LEFT" 0 "R2 the term file is removed after a failure too"
no_terms "R2"

R=$(mkrepo r-kb); put "$R" "kb/design.md" "the quuxcorp name"
step "$R"
eq "$RC" 0 "R3 a hit only in kb/: green"
has "$OUT" "excluded under kb/: 1 hits" "R3 it is counted"
has "$OUT" "control: found 1/1; hits: 0" "R3 the scan line"
no_terms "R3"

R=$(mkrepo r-both); put "$R" "kb/design.md" "quuxcorp"; put "$R" "plugins/x.txt" "ZORBLAX"
step "$R"
ne "$RC" 0 "R4 a hit in kb/ and one outside (upper case): red"
has "$OUT" "tree plugins/x.txt term=1:1" "R4 the outside hit is listed"
hasnt "$OUT" "kb/design.md" "R4 the kb/ hit is not listed"
no_terms "R4"

R=$(mkrepo r-path); put "$R" "plugins/zorblax-dir/y.txt" "zorblax"
step "$R"
ne "$RC" 0 "R5 a term in a file name outside kb/: red"
has "$OUT" "(path withheld" "R5 the path is withheld"
no_terms "R5"

R=$(mkrepo r-trick); git -C "$R" rm -q -rf kb; put "$R" "kb" "zorblax"
step "$R"
eq "$RC" 1 "R6 a file named kb is not kb/: red (a hit, not another failure)"
R=$(mkrepo r-trick2); put "$R" "plugins/kb/z.txt" "zorblax"
step "$R"
eq "$RC" 1 "R6 plugins/kb/ is not kb/: red (a hit)"
R=$(mkrepo r-trick3); put "$R" "KB/z.txt" "zorblax"
step "$R"
eq "$RC" 1 "R6 KB/ is not kb/: red (a hit)"

R=$(mkrepo r-empty)
step "$R" ""
ne "$RC" 0 "R7 an empty secret: red"
has "$OUT" "KIT_TERMS secret is empty or missing" "R7 the message says why"
hasnt "$OUT" "control: found 1/1" "R7 and no scan ran"
step "$R" $' \n\t\n'
ne "$RC" 0 "R7 a blank secret: red"
has "$OUT" "KIT_TERMS secret is empty or missing" "R7 the message says why (blank)"
step "$R" "-"
ne "$RC" 0 "R7 no KIT_TERMS in the environment at all: red"
has "$OUT" "KIT_TERMS secret is empty or missing" "R7 the message says why (unset)"
step "$R" $'allow: README.md something'
ne "$RC" 0 "R7 a secret with only an allow line: red (the scanner refuses a list with no term)"
step "$R"
eq "$RC" 0 "R7 the same repository with a good secret is green (control)"

R=$(mkrepo r-rt)
OUT=$(cd "$R" && env -u RUNNER_TEMP KIT_TERMS="$SECRET" bash -c "$(cat "$TMP/step.sh")" 2>&1); RC=$?
ne "$RC" 0 "R8 no RUNNER_TEMP: red"

# a scanner that exits 0 but never ran its control: the block must not call that a pass
R=$(mkrepo r-fake)
printf '#!/bin/bash\necho "scanned files: 3; skipped binary files: 0"\necho "hits: 0"\nexit 0\n' > "$R/scripts/scan-internal-terms.sh"
step "$R"
ne "$RC" 0 "R9 a scanner that exits 0 without the control line: red"
has "$OUT" "did not end with" "R9 the message says so"
# a scanner that prints a clean last line but exits 1: the exit code counts
R=$(mkrepo r-fake2)
printf '#!/bin/bash\necho "control: found 1/1; hits: 0"\nexit 1\n' > "$R/scripts/scan-internal-terms.sh"
step "$R"
ne "$RC" 0 "R9 a scanner that exits 1 whatever its last line says: red"
# a scanner that records how it was called: file mode, environment, arguments
R=$(mkrepo r-spy)
cat > "$R/scripts/scan-internal-terms.sh" <<SPY
#!/bin/bash
args=("\$@"); f=""; while [ \$# -gt 0 ]; do [ "\$1" = --terms ] && f=\$2; shift; done
m=\$(stat -c %a "\$f" 2>/dev/null || stat -f %Lp "\$f")
printf '%s\n' "\$m" > "$TMP/spy.mode"
if env | grep -q -e '^KIT_TERMS='; then echo yes > "$TMP/spy.env"; else echo no > "$TMP/spy.env"; fi
case \$f in "\$RUNNER_TEMP"/*) echo under > "$TMP/spy.where" ;; *) echo elsewhere > "$TMP/spy.where" ;; esac
printf '%s\n' "\$TMPDIR" > "$TMP/spy.tmpdir"
printf '%s\n' "\${args[*]}" | sed -e "s|\$f|FILE|" > "$TMP/spy.args"
exec bash "$SCAN" "\${args[@]}"
SPY
step "$R"
eq "$(cat "$TMP/spy.mode" 2>/dev/null)" 600 "R10 the term file is mode 0600 while the scanner runs"
eq "$(cat "$TMP/spy.env" 2>/dev/null)" no "R10 the secret is not in the scanner's environment"
eq "$(cat "$TMP/spy.where" 2>/dev/null)" under "R10 the term file is under RUNNER_TEMP"
eq "$(cat "$TMP/spy.tmpdir" 2>/dev/null)" "$TMP/rt-$N" "R10 TMPDIR is RUNNER_TEMP: the scanner's scratch copy of the terms is cleaned with it"
eq "$(cat "$TMP/spy.args" 2>/dev/null)" "--ci --terms FILE --exclude kb/ --tree" "R10 the scanner is called with --ci, --terms, --exclude kb/ and --tree"
eq "$RC" 0 "R10 and the wrapped real scanner still passes (control)"
eq "$LEFT" 0 "R10 the term file is removed afterwards"

# a file named "-" and a file with a NUL byte next to a hit outside kb/: still red
R=$(mkrepo r-hostile); put "$R" "plugins/leak.txt" "the quuxcorp name"; printf 'clean\n' > "$R/-"; git -C "$R" add -- ./-; git -C "$R" commit -q -m dash
step "$R"
eq "$RC" 1 "R12 a file named - next to a hit outside kb/: red"
has "$OUT" "tree plugins/leak.txt term=1:3" "R12 the last term of the list is still scanned"
R=$(mkrepo r-nul); printf 'x ZORBLAX y\n\0\n' > "$R/plugins/data.bin"; git -C "$R" add -A; git -C "$R" commit -q -m nul
step "$R"
eq "$RC" 1 "R12 a text file with a NUL byte outside kb/: red"
no_terms "R12"

# a control miss inside the real scanner (a grep that finds nothing) is red
R=$(mkrepo r-ctl); shim=$TMP/shim-ctl; mkdir "$shim"; printf '#!/bin/bash\nexit 1\n' > "$shim/grep"; chmod +x "$shim/grep"
rt=$TMP/rt-ctl; mkdir -p "$rt"
OUT=$(cd "$R" && PATH="$shim:$PATH" KIT_TERMS="$SECRET" RUNNER_TEMP="$rt" bash -c "$(cat "$TMP/step.sh")" 2>&1); RC=$?
ne "$RC" 0 "R11 a control that misses its canary: red"
has "$OUT" "control: found 0/1" "R11 the log says the control missed"
no_terms "R11"

summary
