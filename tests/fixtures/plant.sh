# shellcheck shell=bash
# =============================================================================
# plant_break — one planted break, run the one way (sourced by lib.sh; defines functions only)
# =============================================================================
# A planted break copies a tree, replaces one text in one file of the copy, runs a family of checks against the copy and expects
# it red. Doing it here, once, makes the measured failure modes impossible for a suite that uses it
# (each seen in CI or in a parallel run):
#   - the run goes through `capped` (capped.sh): a runaway break cannot take the runner (a suite killed with 137 under parallel load), and a hang ends
#     at the time cap; a cap hit is red and names the cap;
#   - the copy lives under the suite's TMPDIR and is removed when the break ends, red or green: the copies do not pile up on the
#     runner's 1Gi /tmp (a plan once peaked at 1.1 GiB);
#   - no bytecode lands in the source tree (parallel suites copied it): the mutation runs `python3 -I -B`, the command runs with PYTHONDONTWRITEBYTECODE=1
#     and `-B` after every `python3` word of it (`-I` ignores the variable).
#
#   plant_break <label> <tree> <file under tree> <old> <new> -- <command…>
#     <old> must occur exactly once in the file and differ from <new>; `@COPY@` in any argument of the command stands for the copy
#     of <tree>. Verdict (ok/bad of lib.sh, one line): `planted <label>: red (N failing case(s))` when the command's `RESULT <ok>
#     <fail>` line has fail > 0, `…: red by the time|memory cap`, `…: stayed green`, `…: the command gave no RESULT line`, or
#     `…: the mutation did not apply (<why>)`.
# =============================================================================

plant_break() {
  local label=$1 tree=$2 file=$3 old=$4 new=$5 dir out crc why a
  shift 5
  [ "${1-}" = -- ] && shift
  dir=$(mktemp -d "${TMPDIR:-/tmp}/plant.XXXXXX")
  cp -R "$tree" "$dir/copy"
  if ! why=$(python3 -I -B - "$dir/copy/$file" "$old" "$new" 2>&1 <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p, encoding="utf-8").read()
if old == new:
    sys.exit("the planted text and its replacement are the same")
if s.count(old) != 1:
    sys.exit("the planted text occurs %d times, not once" % s.count(old))
open(p, "w", encoding="utf-8").write(s.replace(old, new))
PY
  ); then
    rm -rf "$dir"
    bad "planted $label: the mutation did not apply (${why:-no reason given}: the shipped text changed, update the plant)"
    return
  fi
  local cmd=() rest put
  for a in "$@"; do
    put=""; rest=$a   # @COPY@ → the copy, by prefix/suffix cuts: ${a//…/…} reads `&` in the path as the match (bash 5.2)
    while [[ $rest == *@COPY@* ]]; do put+="${rest%%@COPY@*}$dir/copy"; rest=${rest#*@COPY@}; done
    cmd+=("$put$rest")
    [ "$a" = python3 ] && cmd+=(-B)
  done
  out=$(PYTHONDONTWRITEBYTECODE=1 capped "${cmd[@]}" 2>&1); crc=$?
  rm -rf "$dir"
  cap_red "$crc" "planted $label" && return
  case "$(printf '%s\n' "$out" | awk '/^RESULT /{print $3}')" in
    "") bad "planted $label: the command gave no RESULT line (it did not run its family?)";;
    0) bad "planted $label: stayed green";;
    *) ok "planted $label: red ($(printf '%s\n' "$out" | grep -c '^  FAIL ') failing case(s))";;
  esac
}
