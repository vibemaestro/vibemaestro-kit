#!/bin/bash
# =============================================================================
# Public kit — scripts/export-gate.sh and .github/workflows/export-gate.yml: the export of one rev, scanned for terms and secrets
# =============================================================================
# Run: bash tests/test-export-gate.sh
#
# The gate runs for real (the real export, the real term scanner) on a scratch repository whose commit R1 holds this checkout's tracked files, with MADE-UP terms and a stub
# gitleaks packed in a tarball whose sha256 this suite writes into its own pins file. No network, no real secret.
#   [G]  clean R1: rc 0, one `export-gate: rev=<R1> digest=<d>` line with d = export-public's stdout, `controls: terms 2/2, gitleaks
#        2/2`; gitleaks ran twice with the gate's config, an ignore file of its own, --ignore-gitleaks-allow and --redact: over exactly
#        the export plus the three control files, then over a mirror with one neutral name per file; no `terms:` count line; the work
#        dir is gone afterwards
#   [U]  a made-up term R1 holds under the root kb/ (not exported) is not a hit (control: R1 does hold it there)
#   [T]  a made-up term in an exported file: rc 1, the scanner's index line; in an exported file NAME: rc 1, the path withheld
#   [S]  the gate's sentinel term in a scratch root CHANGELOG file: rc 1, a term=2:2 line
#   [K]  a fake token in docs/README.md: rc 1, `gitleaks: github-pat file #N line L` with N its position in the export's index; with
#        a `gitleaks:allow` comment on its line: still rc 1; in an exported .svg (the stub skips it by name, as gitleaks' default rules
#        do): rc 1, through the mirror
#   [X]  a copy of export-public that keeps the root kb/: rc 1, `under kb/` named, no path printed; one that ignores public.private:
#        rc 1, `matching public.private[0]` named, no path printed
#   [P]  a copy of export-public that ignores the config, on a rev without one: the gate reads the list itself and stops, rc 3
#   [M]  an old-branch PR whose head holds an exported file main has fixed since: red on the head (control), green on the
#        test-merge commit, whose sha the green line names
#   [E]  term file empty, blank or missing: rc 3, nothing exported; [C] a wrong sha256, a tarball whose binary prints another
#        version, no pin for this platform: rc 3, gitleaks never run; [O] a work dir inside the repository: rc 2; [R] not a commit: rc 2
#   [D]  a copy of export-public that prints a wrong digest: rc 3
#   [L]  no output line of any run holds a made-up term, the sentinel or a fake token
#   [B1-B8] planted breaks in copies of the gate, each must turn its case red for its own reason: `add -A` for `add -Af`, no term
#        canary planted, no token planted, the digest check removed, a blind gitleaks, no --ignore-gitleaks-allow, the `terms:` line
#        kept, no mirror run
#   [W]  workflow shape (YAML parser): only pull_request and workflow_dispatch (input rev, required); permissions contents: read; the
#        secret named once, in the env of the step that calls the gate; no `${{ }}` in a run block; checkout pinned by sha, no persisted
#        credentials, full history; runs-on from vars.CI_GATE_RUNNER, then vars.CI_RUNNER; REV from the test-merge commit (github.sha) or the
#        dispatch input (planted break: REV from the PR head is red); no path
#        filter (every PR: the export is the whole tree but kb/ and public.private); the job runs only if github.event.repository.private
#        (planted breaks: a copy with a path filter, and one without the `if:`, are red)
#   [WR] the step's real run block, with a stub gate: the secret reaches the gate only as a 0600 file, gone afterwards, never in the
#        gate's environment; an empty, blank or absent secret is red before the gate runs
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"

GATE="$SRC_ROOT/scripts/export-gate.sh"
EXPORT="$SRC_ROOT/scripts/export-public.sh"
WF="$SRC_ROOT/.github/workflows/export-gate.yml"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
export PYTHONDONTWRITEBYTECODE=1
unset GH_TOKEN GITHUB_TOKEN GITLEAKS_CONFIG GITLEAKS_CONFIG_TOML
CTL=export-gate-control
TERM1=$(printf 'qzvmadeup%s' internalname)   # made-up terms, built here: this file is exported too, so it must not hold them whole
TERM2=$(printf 'qzvmadeup%s' seatname)
ALL_LOGS="$TMP/all.log"; : > "$ALL_LOGS"

for f in "$GATE" "$WF" "$SRC_ROOT/scripts/export-gate.pins" "$SRC_ROOT/scripts/export-gate.gitleaks.toml"; do
  [ -f "$f" ] || { bad "missing: ${f#"$SRC_ROOT"/}"; summary; exit 1; }
done
SENTINEL=$(sed -n 's/^SENTINEL = "-"\.join(("\(.*\)", "\(.*\)"))$/\1-\2/p' "$GATE")
nonempty "$SENTINEL" "the gate's sentinel term is readable from its source"

echo "== fixture: R1 = this checkout's tracked files + LICENSE, NOTICE =="
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
mkdir -p "$FX/kb"; printf 'private note %s\n' "$TERM1" > "$FX/kb/u-made-up-term.md"   # R1 holds a made-up term where nothing is exported ([U])
# a published tree has no config (it is on the private list) and holds the plugin licence copies its export made: put back what a
# private repo has, so the suite runs from either tree
mkdir -p "$FX/.vibemaestro"; printf '{"schema": 1, "public": {"private": [".vibemaestro/sdlc.json"]}}\n' > "$FX/.vibemaestro/sdlc.json"
rm -f "$FX"/plugins/*/LICENSE "$FX"/plugins/*/NOTICE
[ -e "$FX/LICENSE" ] || printf 'Fixture licence text.\n' > "$FX/LICENSE"
[ -e "$FX/NOTICE" ] || printf 'Fixture notice.\n' > "$FX/NOTICE"
git_ -C "$FX" init -q -b main && git_ -C "$FX" add -Af -- . && git_ -C "$FX" commit -qm R1 || { bad "fixture R1"; summary; exit 1; }
R1=$(git_ -C "$FX" rev-parse HEAD)

# mkrev <branch> <commands> — a commit on R1 plus <commands> (run in $FX; they stage what they change); prints it; $FX back on main
mkrev() {
  git_ -C "$FX" checkout -q -B "$1" "$R1" && (cd "$FX" && eval "$2") >/dev/null && git_ -C "$FX" commit -qm "$1" &&
    git_ -C "$FX" rev-parse HEAD
  git_ -C "$FX" checkout -q main
}
token() { python3 -c 'import secrets, string; a = string.ascii_letters + string.digits; print("ghp_" + "".join(secrets.choice(a) for _ in range(36)))'; }

echo "== stub gitleaks: finds ghp_ + 36 alphanumerics, skips *.svg, honours gitleaks:allow unless --ignore-gitleaks-allow, logs =="
# mkstub <dir> <blind 0|1> <version> — a tarball <dir>/gl.tar.gz holding a stub `gitleaks`, and a pins file <dir>/pins naming its sha256
mkstub() {
  mkdir -p "$1/pkg"
  cat > "$1/pkg/gitleaks" <<EOF
#!/bin/bash
case "\$1" in
  version) echo $3; exit 0 ;;
  dir) ;;
  *) echo "stub: unknown command \$1" >&2; exit 2 ;;
esac
exec python3 - $2 "\$@" <<'PY'
import json, os, re, sys
blind, args = sys.argv[1] == "1", sys.argv[2:]   # args[0] is the command, "dir"
log = "$TMP/stub.log"   # written in at build time: the gate runs gitleaks with a clean environment
target = report = None
i = 1
while i < len(args):
    if args[i] in ("-r", "--report-path"):
        report = args[i + 1]
    if args[i] in ("-r", "--report-path", "-f", "--report-format", "-c", "--config", "-i", "--gitleaks-ignore-path",
                   "--exit-code", "--log-level"):
        i += 2
        continue
    if not args[i].startswith("-"):
        target = args[i]
    i += 1
pat = re.compile(rb"ghp_[0-9A-Za-z]{36}")
out, seen = [], []
for dp, dns, fns in os.walk(target):
    dns[:] = [d for d in dns if d != ".git"]
    for n in fns:
        p = os.path.join(dp, n)
        if n == ".git" or os.path.islink(p):
            continue
        seen.append(os.path.relpath(p, target))
        if n.endswith(".svg"):   # as gitleaks' default rules do: an image is skipped unread
            continue
        for ln, line in enumerate(open(p, "rb").read().split(b"\n"), 1):
            if pat.search(line) and not blind and (b"gitleaks:allow" not in line or "--ignore-gitleaks-allow" in args):
                out.append({"RuleID": "github-pat", "File": p, "StartLine": ln, "Secret": "REDACTED"})
if log:
    with open(log, "a") as f:
        f.write("ARGS " + " ".join(args) + "\n" + "".join("FILE %s\n" % s for s in seen))
json.dump(out, open(report, "w"))
sys.exit(1 if out else 0)
PY
EOF
  chmod 755 "$1/pkg/gitleaks"
  tar -czf "$1/gl.tar.gz" -C "$1/pkg" gitleaks
  local sum; sum=$(python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1/gl.tar.gz")
  { echo "# test pins"; echo "version 8.30.1"; for k in linux_x64 linux_arm64 darwin_x64 darwin_arm64; do echo "$k $sum"; done; } > "$1/pins"
}
mkstub "$TMP/gl" 0 8.30.1
mkstub "$TMP/gl-blind" 1 8.30.1
mkstub "$TMP/gl-oldver" 0 8.24.3
mkstub "$TMP/gl-noexec" 0 8.30.1   # then its binary is replaced by bytes no system can run, and the pins follow
printf 'not a program\n' > "$TMP/gl-noexec/pkg/gitleaks" && tar -czf "$TMP/gl-noexec/gl.tar.gz" -C "$TMP/gl-noexec/pkg" gitleaks
sum=$(python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$TMP/gl-noexec/gl.tar.gz")
sed -i.bak "s/^\([a-z]*_[a-z0-9]*\) .*/\1 $sum/" "$TMP/gl-noexec/pins"
STUB_GL_LOG="$TMP/stub.log"

printf '%s\nw:%s\n' "$TERM1" "$TERM2" > "$TMP/terms"; chmod 600 "$TMP/terms"

# gate <rev> [args] — run a gate (GATE_BIN, default the real one) in $FX; sets RC and OUT (stdout and stderr)
gate() {
  local rev=$1; shift
  : > "$STUB_GL_LOG"
  OUT=$(cd "$FX" && ${GATE_BIN:+capped} bash "${GATE_BIN:-$GATE}" --rev "$rev" --terms "${TERMS_FILE:-$TMP/terms}" \
        --gitleaks-tarball "${GL_DIR:-$TMP/gl}/gl.tar.gz" --pins "${PINS:-${GL_DIR:-$TMP/gl}/pins}" "$@" 2>&1); RC=$?
  printf '%s\n' "$OUT" >> "$ALL_LOGS"
}
leftover() { find "$TMPDIR" -maxdepth 1 -name 'export-gate.*' | head -n 1; }
# digest_of <rev> <dir> — export-public's stdout for <rev>, exported into <dir> (which must not exist yet)
digest_of() { (cd "$FX" && bash "$EXPORT" "$1" "$2" 2>/dev/null); }
# green_ok — the [G] conditions for the last run, quietly: 0 when all hold (planted breaks need "not green")
green_ok() {
  [ "$RC" -eq 0 ] || return 1
  [ "$(printf '%s\n' "$OUT" | grep -c '^export-gate: rev=')" -eq 1 ] || return 1
  printf '%s\n' "$OUT" | grep -qxF "export-gate: rev=$R1 digest=$D1" || return 1
  printf '%s\n' "$OUT" | grep -qxF "controls: terms 2/2, gitleaks 2/2" || return 1
  ! printf '%s\n' "$OUT" | grep -q '^terms: ' || return 1
  return 0
}

echo "== [G] clean R1 =="
EXP1="$TMP/exp-r1"; D1=$(digest_of "$R1" "$EXP1")
gate "$R1"
green_ok && ok "[G] rc 0, one 'export-gate: rev=$R1 digest=<export-public digest>' line, controls 2/2 and 2/2, no terms: line" ||
  bad "[G] clean R1 is not green (rc $RC): $(printf '%s\n' "$OUT" | tail -n 5 | tr '\n' '|')"
eq "$(grep -c '^ARGS ' "$STUB_GL_LOG")" 2 "[G] gitleaks runs twice (the export dir, then its mirror)"
args=$(sed -n 's/^ARGS //p' "$STUB_GL_LOG" | head -n 1)
margs=$(sed -n 's/^ARGS //p' "$STUB_GL_LOG" | sed -n 2p)
has "$args" "--config $SRC_ROOT/scripts/export-gate.gitleaks.toml" "[G] gitleaks runs with the gate's own config"
has "$args" "--ignore-gitleaks-allow" "[G] gitleaks ignores inline gitleaks:allow comments"
has "$args" "--redact" "[G] gitleaks redacts"
case " $args " in *" -i "*|*" --gitleaks-ignore-path "*) ok "[G] gitleaks gets an ignore path of the gate's own" ;;
  *) bad "[G] gitleaks runs with its default ignore path ('.')" ;; esac
case "$args" in "dir $FX"*|"dir $SRC_ROOT"*) bad "[G] gitleaks scanned inside a checkout" ;; dir\ /*) ok "[G] gitleaks scans a dir outside both checkouts" ;;
  *) bad "[G] gitleaks was not run as 'dir <absolute path>': $args" ;; esac
want=$( { (cd "$EXP1" && find . -type f | sed 's#^\./##'); printf '%s\n' "$CTL/.gitignore" "$CTL/hidden.svg" "$CTL/plain.txt"; } | LC_ALL=C sort)
got=$(awk '/^ARGS /{n++} n==1 && sub(/^FILE /, "")' "$STUB_GL_LOG" | LC_ALL=C sort)
eq "$got" "$want" "[G] gitleaks scanned exactly the export plus the three control files"
mgot=$(awk '/^ARGS /{n++} n==2 && sub(/^FILE /, "")' "$STUB_GL_LOG" | LC_ALL=C sort)
mwant=$(i=0; printf '%s\n' "$want" | while read -r _; do i=$((i+1)); printf 'f%06d\n' "$i"; done)
eq "$mgot" "$mwant" "[G] the mirror holds one neutral name per scanned file"
for f in "--config $SRC_ROOT/scripts/export-gate.gitleaks.toml" "--ignore-gitleaks-allow" "--redact"; do
  has "$margs" "$f" "[G] the mirror run has $f too"
done
empty "$(leftover)" "[G] the gate's work dir is removed"

echo "== [U] a made-up term outside the export =="
git_ -C "$FX" grep -q -i -F -e "$TERM1" "$R1" -- kb/ && ok "[U] control: R1 holds the made-up term under kb/" || bad "[U] R1 lacks the term"
[ "$RC" -eq 0 ] && ok "[U] it is not a hit: the root kb/ is not exported" || bad "[U] the clean run is red"

echo "== [T] made-up terms in the export =="
RT=$(mkrev t-content "printf 'see %s here\n' '$TERM1' >> plugins/vibemaestro-sdlc/rules/workflow-core.instructions.md && git add plugins/vibemaestro-sdlc/rules/workflow-core.instructions.md")
gate "$RT"
eq "$RC" 1 "[T] a term in an exported file: rc 1"
has "$OUT" "tree plugins/vibemaestro-sdlc/rules/workflow-core.instructions.md term=1:1" "[T] the scanner's index line"
hasnt "$OUT" "export-gate: rev=" "[T] no green line"
has "$OUT" "export-gate: red rev=$RT" "[T] a red line names the rev"
RN=$(mkrev t-name "printf '%s\n' '$TERM1' > 'plugins/vibemaestro-sdlc/$TERM2' && git add plugins/")
gate "$RN"
eq "$RC" 1 "[T] a term in an exported file name: rc 1"
has "$OUT" "(path withheld; file #" "[T] the path of its content hit is withheld"
case "$OUT" in *"name #"*"term=1:2"*) ok "[T] a name hit line" ;; *) bad "[T] no name hit line" ;; esac

echo "== [S] the sentinel term =="
RS=$(mkrev s-sentinel "printf 'scratch %s\n' '$SENTINEL' > CHANGELOG.export-gate-scratch && git add CHANGELOG.export-gate-scratch")
gate "$RS"
eq "$RC" 1 "[S] the sentinel in a root CHANGELOG file: rc 1"
has "$OUT" "tree CHANGELOG.export-gate-scratch term=2:2" "[S] the sentinel hit line"

echo "== [K] a fake token =="
TOK=$(token)
RK=$(mkrev k-token "printf 'key = \"%s\"\n' '$TOK' >> docs/README.md && git add docs/README.md")
gate "$RK"
eq "$RC" 1 "[K] a token in docs/README.md: rc 1"
n=$(digest_of "$RK" "$TMP/exp-rk" >/dev/null; { (cd "$TMP/exp-rk" && find . -type f | sed 's#^\./##'); printf '%s\n' "$CTL/.gitignore" "$CTL/hidden.svg" "$CTL/plain.txt"; } |
    LC_ALL=C sort | grep -n -x -F 'docs/README.md' | cut -d: -f1)
line=$(wc -l < "$FX/docs/README.md" | tr -d ' '); line=$((line+1))
has "$OUT" "gitleaks: github-pat file #$n line $line" "[K] the finding by rule, index and line"
hasnt "$OUT" "docs/README.md" "[K] the path is not printed"
TOK2=$(token)
RA=$(mkrev k-allow "printf 'key = \"%s\" # gitleaks:allow\n' '$TOK2' >> docs/README.md && git add docs/README.md")
gate "$RA"
eq "$RC" 1 "[K] a token with a gitleaks:allow comment: still rc 1"

TOK3=$(token)
RV=$(mkrev k-svg "printf '<svg><!-- key = \"%s\" --></svg>\n' '$TOK3' > plugins/vibemaestro-sdlc/icon.svg && git add plugins/")
gate "$RV"
eq "$RC" 1 "[K] a token in an exported .svg, a name gitleaks' default rules skip: rc 1 (the mirror run)"
has "$OUT" "gitleaks: github-pat file #" "[K] the .svg finding"

echo "== [X] an export that leaks the root kb/ or a public.private path =="
SEL='    if path.startswith(KB) or any(rx.match(path) for rx in private):'
# xbreak <label> <new selection line> <what the forbidden line names> <a leaked path that must not be printed>
xbreak() {
  local d="$TMP/x-$1"; mkdir -p "$d"; cp "$SRC_ROOT"/scripts/export-gate.* "$SRC_ROOT/scripts/scan-internal-terms.sh" "$d/"
  python3 - "$EXPORT" "$d/export-public.sh" "$SEL" "$2" <<'PY'
import sys
src, dst, old, new = sys.argv[1:]
s = open(src).read()
open(dst, "w").write(s.replace(old, new) if s.count(old) == 1 else s)
PY
  if cmp -s "$EXPORT" "$d/export-public.sh"; then bad "[X] $1: the planted export did not apply (the selection line moved?)"; return; fi
  GATE_BIN="$d/export-gate.sh" gate "$R1"
  eq "$RC" 1 "[X] $1: rc 1"
  has "$OUT" "forbidden: " "[X] $1: a forbidden line"
  has "$OUT" "$3" "[X] $1: it names $3"
  hasnt "$OUT" "$4" "[X] $1: no path is printed"
}
xbreak keeps-kb '    if any(rx.match(path) for rx in private):' "under kb/" kb/current-state.md
xbreak no-private-list '    if path.startswith(KB):' "matching public.private[0]" ".vibemaestro/sdlc.json"

echo "== [P] the gate's own private list: a rev that does not say what stays private =="
# an exporter that ignores the config exports a rev with none; the gate reads the list itself and must not pass it
mkdir -p "$TMP/p"; cp "$SRC_ROOT"/scripts/export-gate.* "$SRC_ROOT/scripts/scan-internal-terms.sh" "$TMP/p/"
python3 - "$EXPORT" "$TMP/p/export-public.sh" <<'PY'
import sys
src, dst = sys.argv[1:]
s = open(src).read(); old = "private = private_list({p: (m, k, o) for p, m, k, o in entries})"
open(dst, "w").write(s.replace(old, "private = []") if s.count(old) == 1 else s)
PY
if cmp -s "$EXPORT" "$TMP/p/export-public.sh"; then bad "[P] the planted exporter did not apply (the private_list line moved?)"; else
  RP=$(mkrev p-nocfg 'git_ rm -q .vibemaestro/sdlc.json')
  GATE_BIN="$TMP/p/export-gate.sh" gate "$RP"
  eq "$RC" 3 "[P] no public.private at the rev: the gate itself stops, rc 3"
  has "$OUT" "has no public.private list" "[P] …and says why"
  hasnt "$OUT" "export-gate: rev=" "[P] …no green line"
fi

echo "== [M] a pull request is gated on what merges: the test-merge commit, not its head =="
# base B holds an exported file with a made-up term; main fixes it; an old branch cut at B changes something else; the test-merge
# commit (refs/pull/N/merge, github.sha) is the old branch on top of main
git_ -C "$FX" checkout -q -B m-base "$R1"
printf 'echo %s\n' "$TERM1" > "$FX/scripts/outdated-tool.sh"; git_ -C "$FX" add scripts/outdated-tool.sh; git_ -C "$FX" commit -qm "m: outdated"
git_ -C "$FX" checkout -q -B m-main; printf 'echo fixed\n' > "$FX/scripts/outdated-tool.sh"; git_ -C "$FX" commit -qam "m: main fixes it"
git_ -C "$FX" checkout -q -B m-old m-base; printf 'unrelated\n' > "$FX/plugins/m-unrelated.txt"; git_ -C "$FX" add plugins; git_ -C "$FX" commit -qm "m: old branch"
git_ -C "$FX" checkout -q -B m-merge m-main; git_ -C "$FX" merge -q --no-ff --no-edit m-old
MOLD=$(git_ -C "$FX" rev-parse m-old); MMERGE=$(git_ -C "$FX" rev-parse m-merge); git_ -C "$FX" checkout -q main
gate "$MOLD"
eq "$RC" 1 "[M] control: the PR head still holds the outdated exported file: rc 1"
gate "$MMERGE"
eq "$RC" 0 "[M] the test-merge commit, where main's fix wins: rc 0 ($(printf '%s' "$OUT" | tail -1))"
has "$OUT" "export-gate: rev=$MMERGE digest=" "[M] the green line names the commit it exported"

echo "== [E] the term file =="
for kind in empty blank missing; do
  case $kind in empty) : > "$TMP/t.$kind" ;; blank) printf '  \n\n\t\n' > "$TMP/t.$kind" ;; missing) rm -f "$TMP/t.$kind" ;; esac
  TERMS_FILE="$TMP/t.$kind" gate "$R1"
  eq "$RC" 3 "[E] $kind term file: rc 3"
  hasnt "$OUT" "export-gate: rev=" "[E] $kind: no green line"
  [ -s "$STUB_GL_LOG" ] && bad "[E] $kind: gitleaks ran" || ok "[E] $kind: nothing scanned"
done

echo "== [C] the pinned gitleaks =="
sed 's/^\(linux_x64\|linux_arm64\|darwin_x64\|darwin_arm64\) .*/\1 0000000000000000000000000000000000000000000000000000000000000000/' "$TMP/gl/pins" > "$TMP/pins.bad"
PINS="$TMP/pins.bad" gate "$R1"
eq "$RC" 3 "[C] a wrong sha256: rc 3"
has "$OUT" "checksum mismatch" "[C] says checksum mismatch"
[ -s "$STUB_GL_LOG" ] && bad "[C] the unverified binary ran" || ok "[C] the unverified binary never ran"
GL_DIR="$TMP/gl-oldver" PINS="$TMP/gl-oldver/pins" gate "$R1"
eq "$RC" 3 "[C] a binary that prints another version: rc 3"
GL_DIR="$TMP/gl-noexec" gate "$R1"
eq "$RC" 3 "[C] a verified binary that cannot run: rc 3 (an unexpected error is a broken instrument, not a finding)"
has "$OUT" "export-gate: broken: an unexpected" "[C] it says so, by the error's type only"
grep -v -E '^(linux|darwin)_' "$TMP/gl/pins" > "$TMP/pins.none"
PINS="$TMP/pins.none" gate "$R1"
eq "$RC" 3 "[C] no pin for this platform: rc 3"

echo "== [O] [R] work dir and rev =="
mkdir -p "$FX/tmp-in-repo"
OUT=$(cd "$FX" && TMPDIR="$FX/tmp-in-repo" bash "$GATE" --rev "$R1" --terms "$TMP/terms" --gitleaks-tarball "$TMP/gl/gl.tar.gz" --pins "$TMP/gl/pins" 2>&1); RC=$?
eq "$RC" 2 "[O] a work dir inside the repository: rc 2"
empty "$(ls -A "$FX/tmp-in-repo")" "[O] nothing written inside the repository"
rmdir "$FX/tmp-in-repo"
gate "not-a-rev-$RANDOM"
eq "$RC" 2 "[R] not a commit: rc 2"
gate "--version"
eq "$RC" 2 "[R] a rev shaped like an option: rc 2"

echo "== [D] a wrong digest from the export =="
mkdir -p "$TMP/d"; cp "$SRC_ROOT"/scripts/export-gate.* "$SRC_ROOT/scripts/scan-internal-terms.sh" "$TMP/d/"
sed 's/^print(digest)$/print("1" * len(digest))/' "$EXPORT" > "$TMP/d/export-public.sh"
if cmp -s "$EXPORT" "$TMP/d/export-public.sh"; then bad "[D] the planted digest did not apply"; else
  GATE_BIN="$TMP/d/export-gate.sh" gate "$R1"
  eq "$RC" 3 "[D] rc 3"
  hasnt "$OUT" "export-gate: rev=" "[D] no green line"
fi

echo "== [B] planted breaks in copies of the gate =="
# plant <name> <sed expression> — a copy of the scripts dir whose gate has the break; prints the gate's path, or nothing if it did not apply
plant() {
  local d="$TMP/b-$1"; mkdir -p "$d"
  cp "$SRC_ROOT"/scripts/export-gate.* "$SRC_ROOT/scripts/scan-internal-terms.sh" "$EXPORT" "$d/"
  capped sed "$2" "$GATE" > "$d/export-gate.sh"   # capped: memory and time caps (fixtures/capped.sh)
  cmp -s "$GATE" "$d/export-gate.sh" || printf '%s' "$d/export-gate.sh"
}
# broken <label> <gate> <reason> — the clean [G] run of a broken gate must not be green, and must say <reason> (its own failure)
broken() {
  local label=$1 g=$2
  [ -n "$g" ] || { bad "$label: the planted break did not apply"; return; }
  GATE_BIN="$g" gate "$R1"
  if green_ok; then bad "$label: still green"
  else has "$OUT" "$3" "$label: red (rc $RC) for its own reason"; fi
}
broken "[B1] add -A for add -Af" "$(plant b1 's/"add", "-Af"/"add", "-A"/g')" "a control is not scanned"
broken "[B2] no term canary in the controls" "$(plant b2 's/^CONTROL_TEXT = .*/CONTROL_TEXT = "control\\ntoken = \\"%(token)s\\"\\n"/')" \
  "a control was missed: terms 0/2, gitleaks 2/2"
broken "[B3] no token in the controls" "$(plant b3 's/^CONTROL_TEXT = .*/CONTROL_TEXT = "control %(canary)s\\n"/')" \
  "a control was missed: terms 2/2, gitleaks 0/2"
# [B4] the digest check is what makes [D] red: without it, the wrong digest goes through
g4=$(plant b4 's/^    if tree != digest:$/    if False:/')
if [ -n "$g4" ]; then
  sed 's/^print(digest)$/print("1" * len(digest))/' "$EXPORT" > "$TMP/b-b4/export-public.sh"
  GATE_BIN="$g4" gate "$R1"
  [ "$RC" -eq 3 ] && bad "[B4] without the digest check the wrong digest is still refused: [D] cannot tell" ||
    ok "[B4] without the digest check the wrong digest goes through (rc $RC): [D] tells"
else bad "[B4] the planted break did not apply"; fi
GL_DIR="$TMP/gl-blind" PINS="$TMP/gl-blind/pins" gate "$R1"
if green_ok; then bad "[B5] a blind gitleaks: still green"
else has "$OUT" "a control was missed: terms 2/2, gitleaks 0/2" "[B5] a blind gitleaks: red (rc $RC) for its own reason"; fi
# [B6] --ignore-gitleaks-allow is what makes the second [K] case red
g6=$(plant b6 's/ "--ignore-gitleaks-allow",//')
if [ -n "$g6" ]; then
  GATE_BIN="$g6" gate "$RA"
  [ "$RC" -eq 1 ] && bad "[B6] without --ignore-gitleaks-allow the allowed token is still red: [K] cannot tell" ||
    ok "[B6] without --ignore-gitleaks-allow the allowed token passes (rc $RC): [K] tells"
else bad "[B6] the planted break did not apply"; fi
broken "[B8] no mirror run" "$(plant b8 's/leaks(M, os.path.join(W, "gitleaks-mirror.json"))/[]/')" \
  "a control was missed: terms 2/2, gitleaks 1/2"
# [B7] dropping the scanner's count line is what keeps the size of the term list out of the log
g7=$(plant b7 's/^        if line.startswith("terms: "):$/        if False:/')
if [ -n "$g7" ]; then
  GATE_BIN="$g7" gate "$R1"
  printf '%s\n' "$OUT" | grep -q '^terms: [0-9]' && ok "[B7] without the drop the count line reaches the log: [G] tells" ||
    bad "[B7] without the drop no count line is printed: [G] cannot tell"
else bad "[B7] the planted break did not apply"; fi

echo "== [L] what the runs printed =="
for s in "$TERM1" "$TERM2" "$SENTINEL" "$TOK" "$TOK2" "$TOK3"; do
  grep -q -i -F -e "$s" "$ALL_LOGS" && bad "[L] a run printed a made-up term, the sentinel or a token" || ok "[L] not printed (${#s} chars)"
done

echo "== [W] workflow shape =="
cat > "$TMP/wcheck.py" <<'PY'
import re, sys, yaml
wf, exp = sys.argv[1], sys.argv[2]
text = open(wf).read()
y = yaml.safe_load(text)
on = y.get("on", y.get(True))
probs = []
def need(cond, msg):
    if not cond:
        probs.append(msg)
need(set(on) == {"pull_request", "workflow_dispatch"}, "triggers are %s" % sorted(on))
need(not on.get("pull_request"), "the pull_request trigger has a filter: %r" % on.get("pull_request"))
need("pull_request_target" not in text, "pull_request_target appears")
rev = ((on.get("workflow_dispatch") or {}).get("inputs") or {}).get("rev") or {}
need(rev.get("required") is True, "dispatch input rev is not required")
need(y.get("permissions") == {"contents": "read"}, "permissions are %r" % y.get("permissions"))
need(text.count("secrets.") == 1 and text.count("secrets.KIT_TERMS") == 1, "the secret is not named exactly once")
jobs = y["jobs"]
need(list(jobs) == ["export-gate"], "jobs are %s" % list(jobs))
job = jobs["export-gate"]
need(job.get("runs-on") == "${{ vars.CI_GATE_RUNNER || vars.CI_RUNNER || 'ubuntu-latest' }}", "runs-on is %r" % job.get("runs-on"))
need(job.get("if") == "github.event.repository.private", "the job's if is %r" % job.get("if"))
steps = job["steps"]
co = [s for s in steps if str(s.get("uses", "")).startswith("actions/checkout@")]
need(len(co) == 1 and re.fullmatch(r"actions/checkout@[0-9a-f]{40}", co[0]["uses"]) is not None, "checkout is not pinned by sha")
w = (co[0].get("with") or {}) if co else {}
need(w.get("persist-credentials") is False, "checkout persists credentials")
need(w.get("fetch-depth") == 0, "checkout is not full history")
for s in steps:
    need("${{" not in str(s.get("run", "")), "a run block holds ${{ }}: %s" % s.get("name"))
gs = [s for s in steps if "scripts/export-gate.sh" in str(s.get("run", ""))]
need(len(gs) == 1, "not exactly one step calls the gate")
if gs:
    env = gs[0].get("env") or {}
    need(env.get("KIT_TERMS") == "${{ secrets.KIT_TERMS }}", "the gate step's env lacks KIT_TERMS")
    need(env.get("REV") == "${{ github.event_name == 'pull_request' && github.sha || inputs.rev }}",
         "REV is %r" % env.get("REV"))
for s in steps:
    if s not in gs:
        need("KIT_TERMS" not in str(s), "another step sees KIT_TERMS: %s" % s.get("name"))
need(not any("upload-artifact" in str(s.get("uses", "")) for s in steps), "an artifact is uploaded")
need("GITHUB_STEP_SUMMARY" not in text and "add-mask" not in text and "set -x" not in text, "summary, add-mask or xtrace")

print("\n".join(probs) if probs else "OK")
PY
python3 "$TMP/wcheck.py" "$WF" "$EXPORT" > "$TMP/w.out" 2>&1
w=$(cat "$TMP/w.out"); eq "$w" "OK" "[W] the workflow's shape: every PR, only in a private repository"
# wbreak <label> <python old> <python new> <the problem line it must print>
wbreak() {
  python3 - "$WF" "$TMP/wf-$1.yml" "$2" "$3" <<'PY'
import sys
src, dst, old, new = sys.argv[1:]
s = open(src).read()
open(dst, "w").write(s.replace(old, new, 1) if old in s else s)
PY
  if cmp -s "$WF" "$TMP/wf-$1.yml"; then bad "[W] $1: the planted break did not apply"; return; fi
  python3 "$TMP/wcheck.py" "$TMP/wf-$1.yml" "$EXPORT" > "$TMP/w-$1.out" 2>&1
  case "$(cat "$TMP/w-$1.out")" in *"$4"*) ok "[W] planted break: $1 is red" ;;
    *) bad "[W] planted break: $1 is not red: $(head -c 200 "$TMP/w-$1.out")" ;; esac
}
wbreak path-filter $'  pull_request:\n' $'  pull_request:\n    paths:\n      - "plugins/**"\n' "has a filter"
wbreak no-if $'    if: github.event.repository.private\n' '' "the job's if is None"
wbreak pr-head-rev "github.event_name == 'pull_request' && github.sha" "github.event_name == 'pull_request' && github.event.pull_request.head.sha" "REV is"

echo "== [WR] the step's real run block, with a stub gate =="
python3 -c '
import sys, yaml
y = yaml.safe_load(open(sys.argv[1]))
print([s for s in y["jobs"]["export-gate"]["steps"] if "scripts/export-gate.sh" in str(s.get("run", ""))][0]["run"])' "$WF" > "$TMP/block.sh"
RR="$TMP/rr"; mkdir -p "$RR/scripts" "$TMP/runner-temp"
cat > "$RR/scripts/export-gate.sh" <<'EOF'
#!/bin/bash
# stub gate: records how the secret reached it
t=""; while [ $# -gt 0 ]; do case $1 in --terms) t=$2; shift 2 ;; --rev) echo "rev=$2" >> "$STUB_REC"; shift 2 ;; *) shift ;; esac; done
echo "mode=$(stat -c %a "$t" 2>/dev/null || stat -f %Lp "$t")" >> "$STUB_REC"
echo "content=$(cat "$t")" >> "$STUB_REC"
echo "path=$t" >> "$STUB_REC"
env | grep -q '^KIT_TERMS=' && echo "env=leaked" >> "$STUB_REC"
exit "${STUB_RC:-0}"
EOF
export STUB_REC="$TMP/stub.rec"
# block <secret|-unset> — run the block in $RR; sets RC and OUT
block() {
  : > "$STUB_REC"
  if [ "$1" = -unset ]; then OUT=$(cd "$RR" && env -u KIT_TERMS RUNNER_TEMP="$TMP/runner-temp" REV=abc bash "$TMP/block.sh" 2>&1); RC=$?
  else OUT=$(cd "$RR" && KIT_TERMS="$1" RUNNER_TEMP="$TMP/runner-temp" REV=abc bash "$TMP/block.sh" 2>&1); RC=$?; fi
}
block "$TERM1"
eq "$RC" 0 "[WR] a set secret: rc 0"
rec=$(cat "$STUB_REC")
has "$rec" "rev=abc" "[WR] the gate gets REV"
has "$rec" "mode=600" "[WR] the term file is 0600"
has "$rec" "content=$TERM1" "[WR] the term file holds the secret"
hasnt "$rec" "env=leaked" "[WR] the secret is not in the gate's environment"
p=$(sed -n 's/^path=//p' "$STUB_REC")
case "$p" in "$TMP/runner-temp/"*) ok "[WR] the term file is under RUNNER_TEMP" ;; *) bad "[WR] the term file is at $p" ;; esac
[ -e "$p" ] && bad "[WR] the term file is left behind" || ok "[WR] the term file is gone afterwards"
STUB_RC=1 block "$TERM1"; eq "$RC" 1 "[WR] a red gate: the step is red"
OUT=$(cd "$RR" && KIT_TERMS="$TERM1" RUNNER_TEMP="$TMP/runner-temp" REV=mergesha PR_HEAD=headsha bash "$TMP/block.sh" 2>&1)
has "$OUT" "exporting the test-merge commit mergesha of PR head headsha" "[WR] on a pull request the step says which commit it exports"
block "$TERM1"; hasnt "$OUT" "exporting the test-merge" "[WR] …and on a dispatch (no PR head) it says nothing of the kind"
for s in "" "   " -unset; do
  block "$s"
  ne "$RC" 0 "[WR] secret '${s:-empty}': red"
  empty "$(cat "$STUB_REC")" "[WR] secret '${s:-empty}': the gate never ran"
  has "$OUT" "KIT_TERMS" "[WR] secret '${s:-empty}': the message names the secret"
done

summary
