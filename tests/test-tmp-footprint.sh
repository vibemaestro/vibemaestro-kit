#!/bin/bash
# =============================================================================
# expect_red leaves no scratch behind: a suite's tmp tree stays small while its planted breaks run
# =============================================================================
# Run: bash tests/test-tmp-footprint.sh
#
# Why: a suite runs dozens of planted breaks and its tree under TMPDIR is removed only when the suite exits. Each break used to leave a
# copy of the plugin and the scratch trees of the family it ran, so a plan run peaked at 1.1 GiB of TMPDIR and the CI runner (a 1 GiB
# tmp volume) evicted two pods without a log. expect_red (tests/fixtures/ports.sh) now runs the family with a scratch root of its own and
# removes it afterwards, and removes the one-use `$TMP/break-<label>` copy a BRK helper made.
#
#   [F] after expect_red: no `f.*` tree, no `break-*` copy, no `er-scratch.*` is left in the suite's TMP; the family's `fresh` and mktemp
#       land under the scratch root, not in the suite's TMP; a copy with another name is not touched; a break ended by the time cap
#       leaves nothing either
#   [B] planted breaks of ports.sh (a copy of it): the scratch removal gone, the break-copy removal gone, the family's scratch root gone:
#       each leaves something and the probe says so
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"

PORTS="$HERE/fixtures/ports.sh"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"

# The probe: a suite in miniature. It sources the ports file it is given, runs one expect_red on a family that writes into `fresh`
# and mktemp trees, and prints what is left in its TMP (names only), plus where the family's trees were made.
PROBE="$TMP/probe.sh"
cat > "$PROBE" <<'EOF'
set -uo pipefail
HERE=$1; PORTS=$2; MODE=$3
. "$HERE/fixtures/lib.sh"
. "$PORTS"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
REC="$TMP/where.txt"
fam_probe() { local d m; d=$(fresh); head -c 300000 /dev/zero > "$d/blob"; m=$(mktemp -d); printf '%s\n%s\n' "$d" "$m" > "$REC"
  [ "$MODE" = cap ] && sleep 8
  bad "[Z1] the probe check"; }
mkdir -p "$TMP/mycopy" "$TMP/break-p"; echo keep > "$TMP/mycopy/f"; echo gone > "$TMP/break-p/f"
case "$MODE" in
  cap)  PLANT_CAP_SECS=1 expect_red p fam_probe "$TMP/break-p" "[Z1]" >/dev/null 2>&1;;
  keep) expect_red p fam_probe "$TMP/mycopy" "[Z1]" >/dev/null 2>&1;;
  *)    expect_red p fam_probe "$TMP/break-p" "[Z1]" >/dev/null 2>&1;;
esac
echo "left: $(ls -A "$TMP" | grep -E '^(f\.|break-|er-scratch)' | tr '\n' ' ')"
echo "left in tmpd: $(ls -A "$TMPDIR" | grep -E '^(tmp\.|er-scratch)' | tr '\n' ' ')"
echo "mycopy: $([ -d "$TMP/mycopy" ] && echo kept || echo gone)"
rel() { local r=${1#"$TMP"/}; dirname "$r" | sed 's#\.[A-Za-z0-9]\{6\}#.X#g'; }
echo "family fresh in: $(rel "$(sed -n 1p "$REC")")"
echo "family mktemp in: $(rel "$(sed -n 2p "$REC")")"
EOF
probe() { bash "$PROBE" "$HERE" "$1" "$2" 2>&1; }

echo "== [F] expect_red cleans after itself =="
OUT=$(probe "$PORTS" run)
has "$OUT" "left: " "[F] control: the probe reports"
eq "$(printf '%s\n' "$OUT" | sed -n 's/^left: //p' | tr -d ' ')" "" "[F] a break copy and the family's scratch are gone after expect_red"
eq "$(printf '%s\n' "$OUT" | sed -n 's/^left in tmpd: //p' | tr -d ' ')" "" "[F] …and nothing of the family's mktemp is left"
has "$OUT" "family fresh in: tmpd/er-scratch.X" "[F] the family's fresh tree was made under the scratch root, not the suite's TMP"
has "$OUT" "family mktemp in: tmpd/er-scratch.X/tmpd" "[F] …and its mktemp too"
OUT=$(probe "$PORTS" keep)
has "$OUT" "mycopy: kept" "[F] a copy that is not named break-* is left alone"
OUT=$(probe "$PORTS" cap)
eq "$(printf '%s\n' "$OUT" | sed -n 's/^left: //p' | tr -d ' ')" "" "[F] a break stopped by the time cap leaves nothing either"

echo "== [B] planted breaks of ports.sh: each must leave something =="
# BRK <label> <needle> <sed expression on ports.sh> <mode> — the probe on a copy of ports.sh with one break; it must report the needle
BRK() {
  local f="$TMP/ports-$1.sh" out
  sed "$3" "$PORTS" > "$f"
  ne "$(cmp -s "$PORTS" "$f"; echo $?)" 0 "instrument: [$1] changes ports.sh"
  out=$(capped probe "$f" "$4")
  has "$out" "$2" "break [$1]: the probe reports what is left"
}
BRK scratch-kept 'left in tmpd: er-scratch' 's#^  rm -rf "$scratch"$#  :#' run
BRK copy-kept 'left: break-p' 's#^  case "$dir" in "$TMP"/break-\*) .*$#  :#' run
BRK family-in-suite-tmp 'family fresh in: .' 's#^  TMP=$5; TMPDIR=$5/tmpd; mkdir -p "$TMPDIR"; export TMP TMPDIR$#  :#' run

echo; summary
