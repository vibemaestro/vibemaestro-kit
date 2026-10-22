#!/bin/bash
# =============================================================================
# One current-state gate for both templates: profile, presets, every knob, the diff gate
# =============================================================================
# Run: bash tests/test-gate-current-state.sh
#
# It ports the families of the gate suite of the hub (231 ok measured) against the SYNTHETIC
# hub-shaped fixture (tests/fixtures/hub-shaped, names `example`/`acme`), and adds the `ledger` profile's own faults.
# Parity with another gate is judged by rc and by the SET of (line, class) problems, never by message wording, so no case
# below reads prose.
#
#   [D] the diff gate on the map profile: watched path, ledger changed, exemption token and its reason length
#   [B] size: bytes, characters per line (not bytes, NFC, CRLF, no final newline) and a repo-defined history pattern
#   [T] tables of the map profile: named columns, separator row, rows, closed Status values, one table per section,
#       fences, ATX headings, indented code, escaped pipes, whitespace (the `tables` knob)
#   [W] tables that no `tables` entry covers: the `table.columns` fallback and `required`
#   [O] `table_own_width`: a table no entry covers is checked against its own header
#   [Y] `decorations`: a label next to a closed value is taken off before the `enums` comparison
#   [A] decide(paths, body, profile): the (rc, message) shape, the `ledger` argument, deleted ledger, UTF-8, exemption
#   [L] the `ledger` profile: good fixture and every planted fault (size, history sign, table, watch, token), knobs
#       spelled out, `limits.lines: null`, the presets as the loader lays them
#   [V] the new current_state keys are validated: rc 65 from `kb.py config check` naming the key
#   [K] kb.py: the shape check with the repo's profile, `--diff`, `--config-ref` (a PR cannot relax its own gate)
#   [P] open_pr.py: builtin, off, external, and no config with the legacy repo script
#   [N] dated labels: a label's date is not a history sign, nothing else is exempted, the gate never blocks on a label
#
# Every family runs on a copy of the real plugin; then each planted break (one mutation of the module) must turn the family it
# belongs to red and an unbroken copy must stay green. Real git on throw-away repositories, a fake gh, the network shims of
# netguard.sh, no hub on the machine, no network.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
# shellcheck source=fixtures/flow.sh
. "$HERE/fixtures/flow.sh"
# shellcheck source=fixtures/ports.sh
. "$HERE/fixtures/ports.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
SHAPED="$HERE/fixtures/hub-shaped"
GR="$HERE/fixtures/gate_run.py"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
GHB="$TMP/ghbin"; mk_gh "$GHB"
export GH_LOG="$TMP/gh.log"; : > "$GH_LOG"

PLX=""; T=""; SK=""; PW=""; PT=""; F=""
NSC='NO STATE CHANGE:'

# ── helpers ──────────────────────────────────────────────────────────────────────────────────────
# mkprof <name> <python statements editing the config dict d> — a profile root: the fixture's config with the edits applied
mkprof() {
  local d="$TMP/prof-$1"; rm -rf "$d"; mkdir -p "$d/.vibemaestro"
  python3 - "$SHAPED/.vibemaestro/sdlc.json" "$d/.vibemaestro/sdlc.json" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
exec(sys.argv[3])
json.dump(d, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False)
PY
  printf '%s' "$d"
}
# gr <profile root> shape <ledger> | gr <profile root> diff <ledger|-> <body|-> paths...
gr() { local r=$1; shift; cenv python3 "$GR" "$PLX/scripts" "$r" "$@"; }
rcof() { printf '%s' "${1%%$'\n'*}"; }
# mk <name> <python expression giving the bytes> — a ledger file under $T
mk() { python3 -c "import sys; sys.stdout.buffer.write($2)" > "$T/$1"; }
# mkrep <name> <old> <new> — the skeleton with ONE replacement (\n in an argument is a line break); an anchor that is not in
# the skeleton is a defect of the case, not a pass
mkrep() {
  python3 - "$SK" "$T/$1" "$2" "$3" <<'PY' || { bad "mkrep $1: the anchor is not in the skeleton"; return 0; }
import sys
b = open(sys.argv[1], "rb").read()
old, new = [a.replace("\\n", "\n").encode() for a in sys.argv[3:5]]
if old not in b:
    sys.exit(1)
open(sys.argv[2], "wb").write(b.replace(old, new, 1))
PY
  cmp -s "$SK" "$T/$1" && bad "mkrep $1: the case equals the skeleton"
  return 0
}
# shp <profile root> <ledger file name under $T> <want rc> <label> [class] — the shape check; for rc 1 a class must be listed
shp() {
  local R; R=$(gr "$1" shape "$T/$2")
  if [ "$(rcof "$R")" != "$3" ]; then bad "$4 (want rc $3, got: ${R//$'\n'/ })"
  elif [ "$3" = 1 ] && [ -n "${5:-}" ]; then has "$R" "|$5" "$4 → rc 1 ($5)"
  else ok "$4 → rc $3"; fi
}
# dif <profile root> <ledger file under $T or -> <body text> <want rc> <label> paths... — the diff gate
dif() {
  local prof=$1 led=$2 body=$3 want=$4 lab=$5 R; shift 5
  printf '%s' "$body" > "$T/body.txt"
  [ "$led" = - ] || led="$T/$led"
  R=$(gr "$prof" diff "$led" "$T/body.txt" "$@")
  eq "$(rcof "$R")" "$want" "$lab"
}

# the skeleton: the smallest ledger the map profile of the fixture accepts, so every case below deviates in exactly one thing
mk_skeleton() {
  SK="$T/skel.md"
  cat > "$SK" <<'EOF_SKEL'
# Platform state

**Measured on 13/10/2026.**

## 1. Clusters

| Cluster | Status | What it is · read | Check |
|---|---|---|---|
| `c` | running | A test cluster · read: `README.md` | `check c` |

## 2. What runs

| Area | Component | Status | What it is · where to read | Check |
|---|---|---|---|---|
| `a` | A | running | One sentence · read: `x.md` | `check a` |

## 8. Not in place

| Item | Status | Where to read |
|---|---|---|
| T | off: the reason lives at the target | `y.md` |
EOF_SKEL
}
R2='| `a` | A | running | One sentence · read: `x.md` | `check a` |'
H2='| Area | Component | Status | What it is · where to read | Check |'
S2='|---|---|---|---|---|'
R1='| `c` | running | A test cluster · read: `README.md` | `check c` |'
H1='| Cluster | Status | What it is · read | Check |'
S1='|---|---|---|---|'
R8='| T | off: the reason lives at the target | `y.md` |'
H8='| Item | Status | Where to read |'
S8='|---|---|---|'

MAP="$SHAPED"
# a family sets PLX, $T (fresh scratch) and the skeleton, then reads its cases

# ── [D] the diff gate ────────────────────────────────────────────────────────────────────────────
fam_diff() {
  PLX=$1; T=$(fresh); mk_skeleton
  local LONG="$NSC only an internal value changed, nothing visible moved"
  dif "$MAP" "skel.md" "done" 1 "[D1] a watched path (systems/) with no ledger change → rc 1" systems/a/x.sh
  dif "$MAP" "skel.md" "" 1 "[D2] the second watched prefix (deploy/) with no ledger change → rc 1" deploy/prod/values.yaml
  dif "$MAP" "skel.md" "$NSC ok" 1 "[D3] an exemption with no real reason (too short) → rc 1" systems/x.sh
  dif "$MAP" "skel.md" "" 0 "[D4] the ledger is in the diff → rc 0" systems/x.sh kb/current-state.md
  dif "$MAP" "skel.md" "$LONG" 0 "[D5] an exemption with the token and a real reason → rc 0" systems/x.sh
  dif "$MAP" "skel.md" "" 0 "[D6] no watched path, no ledger: the gate does not apply → rc 0" kb/decisions/2026-01-01-x.md docs/y.md .github/workflows/z.yml
  dif "$MAP" "skel.md" "" 0 "[D7] an empty list of paths passes and does not crash"
  dif "$MAP" "skel.md" "" 0 "[D8] the prefix is anchored at the start: docs/systems/notes.md is not watched" docs/systems/notes.md
  dif "$MAP" "skel.md" "intro
$LONG
tail" 0 "[D9] the exemption line may sit among other lines of the body" deploy/x
  dif "$MAP" "skel.md" "see $LONG" 1 "[D10] the token must start the line: a mention in prose is not an exemption" deploy/x
  dif "$MAP" "skel.md" "   $LONG" 0 "[D11] leading blanks before the token are allowed" deploy/x
  dif "$MAP" "skel.md" "OTHER TOKEN: only an internal value changed, nothing moved" 1 "[D12] a line that starts with another token is no exemption" deploy/x
  dif "$MAP" "skel.md" "no state change: only an internal value changed, nothing moved" 1 "[D13] the token is case sensitive" deploy/x
  dif "$MAP" "skel.md" "$NSC
$LONG" 0 "[D14] a token alone on a line followed by a real reason line, the first match is the one read, as with a line-anchored pattern" deploy/x
  local P2; P2=$(mkprof two-tokens 'd["tokens"]["no_state_change"] = ["NO STATE CHANGE:", "NOTHING TO RECORD:"]')
  dif "$P2" "skel.md" "NOTHING TO RECORD: only an internal value changed, nothing moved" 0 "[D15] a second configured token exempts too" deploy/x
  dif "$P2" "skel.md" "$LONG" 0 "[D16] …and the first one still does" deploy/x
  local P0; P0=$(mkprof min0 'd["current_state"]["exempt"]["min_reason_chars"] = 0')
  dif "$P0" "skel.md" "$NSC" 0 "[D17] exempt.min_reason_chars 0: the token alone is enough" deploy/x
  dif "$P0" "skel.md" "no token at all" 1 "[D18] …and a body without the token is still refused" deploy/x
  dif "$MAP" "skel.md" "$NSC 12345678901234" 1 "[D19] 14 characters of reason against a minimum of 15 → rc 1" deploy/x
  dif "$MAP" "skel.md" "$NSC 123456789012345" 0 "[D20] exactly 15 characters → rc 0 (the boundary)" deploy/x
  # kept as at the hub: a bare token takes the next line with text as its reason (1.1.0 read only the token's line)
  dif "$MAP" "skel.md" "$NSC
only an internal value changed, nothing moved" 0 "[D27] a bare token then the reason on the next line → rc 0, as at the hub" deploy/x
  dif "$MAP" "skel.md" "$NSC
short" 1 "[D28] …a next line under 15 characters is still too short → rc 1" deploy/x
  dif "$MAP" "skel.md" "$NSC
## Bằng chứng chạy" 0 "[D25] a bare token then a heading of 18 characters → rc 0: the heading is the reason, as at the hub" deploy/x
  dif "$MAP" "skel.md" "$NSC   
## Bằng chứng chạy" 0 "[D26] …the same with blanks after the token → rc 0" deploy/x
  local PE; PE=$(mkprof empty-watch 'd["current_state"]["watch"] = []')
  dif "$PE" "skel.md" "" 0 "[D21] watch [] makes the gate vacuous: a path that was watched passes" systems/x.sh
  mkrep bad-size.md "$R2" "$R2
$(python3 -c "print('y' * 401)")"
  dif "$PE" "bad-size.md" "" 0 "[D22] …even with the ledger in the diff and a bad ledger (nothing is watched, nothing applies)" kb/current-state.md
  local PW2; PW2=$(mkprof other-watch 'd["current_state"]["watch"] = ["svc/"]')
  dif "$PW2" "skel.md" "" 1 "[D23] watch is read from the profile: svc/ is watched there" svc/a.go
  dif "$PW2" "skel.md" "" 0 "[D24] …and systems/ is not" systems/a.go
}

# ── [B] size ─────────────────────────────────────────────────────────────────────────────────────
fam_budget() {
  PLX=$1; T=$(fresh); mk_skeleton
  local SKB; SKB=$(wc -c < "$SK" | tr -d ' ')
  mk b28000.md "open('$SK','rb').read() + (('x'*99+'\n')*400).encode()[: 28000 - $SKB]"
  mk b28001.md "open('$SK','rb').read() + (('x'*99+'\n')*400).encode()[: 28001 - $SKB]"
  [ "$(wc -c < "$T/b28000.md" | tr -d ' ')" = 28000 ] && [ "$(wc -c < "$T/b28001.md" | tr -d ' ')" = 28001 ] \
    && ok "[B0] instrument: the planted ledgers measure exactly 28000 and 28001 bytes" || bad "[B0] instrument: the planted ledgers are not the size the cases need"
  shp "$MAP" skel.md 0 "[B1] the skeleton (the good ledger) passes"
  shp "$MAP" b28000.md 0 "[B2] 28000 bytes → pass (the boundary)"
  shp "$MAP" b28001.md 1 "[B3] 28001 bytes → fail (boundary +1, a positive control)" size.bytes
  mk c400.md "open('$SK','rb').read() + ('y'*400+'\n').encode()"
  mk c401.md "open('$SK','rb').read() + ('y'*401+'\n').encode()"
  mk c500.md "open('$SK','rb').read() + ('y'*500+'\n').encode()"
  shp "$MAP" c400.md 0 "[B4] a line of exactly 400 characters → pass"
  shp "$MAP" c401.md 1 "[B5] a line of 401 characters → fail" size.line_chars
  shp "$MAP" c500.md 1 "[B6] a line of 500 characters → fail (an older cap does not survive)" size.line_chars
  mk v400.md "open('$SK','rb').read() + ('ế'*400+'\n').encode()"
  mk v401.md "open('$SK','rb').read() + ('ế'*401+'\n').encode()"
  [ "$(tail -n 1 "$T/v400.md" | wc -c | tr -d ' ')" = 1201 ] && ok "[B7] instrument: 400 accented letters weigh 1200 bytes (the case tells characters from bytes)" || bad "[B7] instrument: the accented line is not heavier than 400 bytes"
  shp "$MAP" v400.md 0 "[B8] 400 accented letters (1200 bytes) → pass: the unit is the character"
  shp "$MAP" v401.md 1 "[B9] 401 accented letters → fail" size.line_chars
  mk n400.md "open('$SK','rb').read() + (__import__('unicodedata').normalize('NFD','ế')*400+'\n').encode()"
  mk n401.md "open('$SK','rb').read() + (__import__('unicodedata').normalize('NFD','ế')*401+'\n').encode()"
  shp "$MAP" n400.md 0 "[B10] 400 letters in decomposed form → pass (counted after NFC)"
  shp "$MAP" n401.md 1 "[B11] 401 letters in decomposed form → fail (a positive control)" size.line_chars
  mk crlf400.md "open('$SK','rb').read() + ('y'*400+'\r\n').encode()"
  mk crlf401.md "open('$SK','rb').read() + ('y'*401+'\r\n').encode()"
  mk nonl400.md "open('$SK','rb').read() + ('y'*400).encode()"
  mk nonl401.md "open('$SK','rb').read() + ('y'*401).encode()"
  shp "$MAP" crlf400.md 0 "[B12] 400 characters and a CRLF → pass (the CR is not a character of the line)"
  shp "$MAP" crlf401.md 1 "[B13] 401 characters and a CRLF → fail" size.line_chars
  shp "$MAP" nonl400.md 0 "[B14] a last line of 400 characters with no final newline → pass"
  shp "$MAP" nonl401.md 1 "[B15] a last line of 401 characters with no final newline is still measured → fail" size.line_chars
  # the history pattern the repo names in its own config (the hub's diary sign is one such entry)
  mk d.md "open('$SK','rb').read() + 'Measured 12/10: check x → ok\n'.encode()"
  mk d-on.md "open('$SK','rb').read() + 'Measured on 12/10/2026 is the stamp form, not a diary line\n'.encode()"
  shp "$MAP" d.md 1 "[B16] a ledger with 'Measured 12/10' → fail" pattern.measured_dm
  shp "$MAP" d-on.md 0 "[B17] 'Measured on 12/10/2026' (the stamp form of line 3) is not the diary sign → pass"
  local i=0 v
  for v in 'measured 12/10 x' 'Measured 1/10 x' 'MEASURED 12/10 x' 'Measured  12/10 x' 'Measured 12/1 x' 'measured 1/1 x' 'Result: Measured 31/12 ok'; do
    i=$((i+1)); mk dv$i.md "open('$SK','rb').read() + '$v\n'.encode()"
    shp "$MAP" dv$i.md 1 "[B18] the diary variant '$v' → fail" pattern.measured_dm
  done
  for v in 'Measured on 12/10/2026 in prose' 'measured on 1/1/2026' 'we must measure again after a bump' 'MEASURED ON 13/10/2026'; do
    i=$((i+1)); mk dv$i.md "open('$SK','rb').read() + '$v\n'.encode()"
    shp "$MAP" dv$i.md 0 "[B19] not a diary line: '$v' → pass"
  done
  # the same sizes through decide(): a ledger of 28001 bytes blocks a diff that carries the ledger, with or without exemption
  dif "$MAP" b28001.md "" 1 "[B20] diff gate: the ledger is in the diff and is over the byte cap → rc 1" systems/x.sh kb/current-state.md
  dif "$MAP" b28001.md "$NSC only an internal value changed, nothing visible moved" 1 "[B21] …an exemption never excuses the size" systems/x.sh
  dif "$MAP" c401.md "" 1 "[B22] diff gate: a ledger line over the cap in a diff that carries the ledger → rc 1" kb/current-state.md
  dif "$MAP" b28001.md "" 0 "[B23] diff gate: a diff that touches neither watched paths nor the ledger ignores a bad ledger" docs/y.md
}

# ── [T] the tables of the map profile ────────────────────────────────────────────────────────────
fam_tables() {
  PLX=$1; T=$(fresh); mk_skeleton
  cp "$SK" "$T/skel-ok.md"
  shp "$MAP" skel-ok.md 0 "[T0] the skeleton passes (the negative control of this family)"
  mkrep h2-missing.md "$H2" '| Area | Component | Status | What it is · where to read |'
  shp "$MAP" h2-missing.md 1 "[T1] section 2 header lacks the Check column" table.header
  mkrep h2-name.md '| What it is · where to read |' '| What it is |'
  shp "$MAP" h2-name.md 1 "[T1] section 2 renames a column" table.header
  mkrep h2-order.md '| Component | Status |' '| Status | Component |'
  shp "$MAP" h2-order.md 1 "[T1] section 2 swaps two columns" table.header
  mkrep h2-old.md '| What it is · where to read | Check |' '| Invariants to know | Check |'
  shp "$MAP" h2-old.md 1 "[T1] section 2 uses an old column name" table.header
  mkrep h2-extra.md "$H2"$'\n'"$S2" '| Area | Component | Status | What it is · where to read | Check | Notes |\n|---|---|---|---|---|---|'
  shp "$MAP" h2-extra.md 1 "[T1] section 2 has a sixth column in its header" table.header
  mkrep h2-nosep.md "$S2"$'\n| `a`' '| `a`'
  shp "$MAP" h2-nosep.md 1 "[T2] section 2 has no separator row under the header" table.separator
  python3 -c "
import sys, unicodedata
b = open(sys.argv[1], encoding='utf-8').read()
sys.stdout.write(b.replace('What it is · where to read', unicodedata.normalize('NFD', 'What it is · where to read')))" "$SK" > "$T/h2-nfd.md"
  python3 -c "
import sys
sys.stdout.buffer.write(open(sys.argv[1], 'rb').read().replace(b'\n', b'\r\n'))" "$SK" > "$T/crlf-all.md"
  shp "$MAP" h2-nfd.md 0 "[T1] a header written in decomposed form is read after NFC → pass"
  shp "$MAP" crlf-all.md 0 "[T1] the whole skeleton with CRLF line ends → pass"
  local st
  for st in 'in review' 'off' 'not deployed' 'in   review'; do
    mkrep "st-ok.md" '| running | One' "| $st | One"; shp "$MAP" st-ok.md 0 "[T3] Status '$st' (a closed value, spaces collapsed) → pass"
  done
  for st in 'is running' 'Running' 'up' 'running, off' 'unchecked' '*unchecked*' 'running.' 'in review (UAT)' 'temporarily off'; do
    mkrep "st-bad.md" '| running | One' "| $st | One"; shp "$MAP" st-bad.md 1 "[T3] Status '$st' is outside the closed values → fail" table.enum
  done
  # finding 2: without `decorations` the enums are exact values, so a Status that carries a label is outside them; with the
  # fixture's `decorations` the label is taken off first (family [Y])
  local NOD; NOD=$(mkprof no-deco 'd["current_state"]["tables"][0].pop("decorations")')
  for st in 'running *unchecked*' '*unchecked* running'; do
    mkrep "st-label.md" '| running | One' "| $st | One"
    shp "$NOD" st-label.md 1 "[T3] no decorations: Status '$st' is not an exact enum value → fail" table.enum
    shp "$MAP" st-label.md 0 "[T3] decorations on (the fixture): Status '$st' → pass"
  done
  local PNFD; PNFD=$(mkprof nfd-names 'import unicodedata as u; e = d["current_state"]["tables"][0]; e["columns"][3] = u.normalize("NFD", "What it is · where to read").replace("What", "What  "); e["enums"]["Status"][1] = "in  review"')
  shp "$PNFD" skel-ok.md 0 "[T3b] names and enum values in the config are compared after NFC and blank collapsing, like the cells (a double blank in the config)"
  mkrep st-sp.md '| running | One' '| in review | One'
  shp "$PNFD" st-sp.md 0 "[T3b] …an enum value written with a double blank still matches the cell 'in review'"
  mkrep r2-3.md '| `a` | A | running | One sentence · read: `x.md` | `check a` |' '| `a` | A | running | One sentence · read: `x.md` |'
  shp "$MAP" r2-3.md 1 "[T4] section 2 row with 4 cells" table.row_width
  mkrep r2-6.md '| `check a` |' '| `check a` | extra |'
  shp "$MAP" r2-6.md 1 "[T4] section 2 row with 6 cells" table.row_width
  mkrep r2-e1.md '| `check a` |' '|  |'
  shp "$MAP" r2-e1.md 1 "[T4] section 2 row with an empty Check cell" table.cell_empty
  mkrep r2-e2.md '| `a` | A |' '|  | A |'
  shp "$MAP" r2-e2.md 1 "[T4] section 2 row with an empty Area cell" table.cell_empty
  mkrep r2-more.md '| `check a` |' '| `check a` |\n| `b` | B | off | One sentence · read: `z.md` | `check b` |'
  shp "$MAP" r2-more.md 0 "[T4] section 2 with one more well-formed row → pass"
  mkrep r2-none.md "$R2"$'\n' ''
  shp "$MAP" r2-none.md 1 "[T4] section 2 with a header and a separator but no row" table.empty
  mkrep r2-notab.md "$H2"$'\n'"$S2"$'\n'"$R2" 'Only words, no table here.'
  shp "$MAP" r2-notab.md 1 "[T5] section 2 holds no table" table.count
  mkrep r2-two.md "$R2" "$R2"'\n\nAnother table:\n\n| Area | Component | Status | What it is · where to read | Check |\n|---|---|---|---|---|\n| `b` | B | running | x | y |'
  shp "$MAP" r2-two.md 1 "[T5] section 2 holds TWO tables (exactly one is required)" table.count
  mkrep r2-sec.md '## 2. What runs' '## 2b. What runs'
  shp "$MAP" r2-sec.md 1 "[T5] the heading '## 2.' is renamed: there is no section 2 any more" table.count
  mkrep r2-fence.md '| Area | Component |' '```\n| a | b |\n```\n\n| Area | Component |'
  shp "$MAP" r2-fence.md 0 "[T6] a fenced block with a '| a | b |' line before the table is not a table → pass"
  mkrep h8-name.md "$H8" '| Item | Status | Read |'
  shp "$MAP" h8-name.md 1 "[T7] section 8 renames a column" table.header
  mkrep h8-two.md "$H8"$'\n'"$S8" '| Item | Status |\n|---|---|'
  shp "$MAP" h8-two.md 1 "[T7] section 8 has two columns" table.header
  mkrep r8-short.md "$R8" '| T | off: the reason lives at the target |'
  shp "$MAP" r8-short.md 1 "[T7] section 8 row with a missing cell" table.row_width
  mkrep r8-empty.md '| T | off: the reason lives at the target |' '| T |  |'
  shp "$MAP" r8-empty.md 1 "[T7] section 8 row with an empty Status" table.cell_empty
  mkrep r8-free.md '| T | off: the reason lives at the target |' '| T | free text here, no closed value in section 8 |'
  shp "$MAP" r8-free.md 0 "[T7] section 8 Status is free text (the closed values are only asked of section 2) → pass"
  mkrep r8-gone.md '## 8. Not in place' '## 9. Not in place'
  shp "$MAP" r8-gone.md 1 "[T7] there is no section 8 any more" table.count
  # separator rows
  mkrep sep2-ok.md "$S2" '| :--- | ---: | :---: |  ---  |:-----:|'
  shp "$MAP" sep2-ok.md 0 "[T8] section 2 separator with alignment colons and blanks → pass"
  mkrep sep2-txt.md "$S2" '|a|b|c|d|e|'
  shp "$MAP" sep2-txt.md 1 "[T8] section 2 separator of 5 cells that are not dashes" table.separator
  mkrep sep2-few.md "$S2" '|---|---|'
  shp "$MAP" sep2-few.md 1 "[T8] section 2 separator of 2 cells" table.separator
  mkrep sep2-many.md "$S2" '|---|---|---|---|---|---|'
  shp "$MAP" sep2-many.md 1 "[T8] section 2 separator of 6 cells" table.separator
  mkrep sep2-short.md "$S2" '|--|--|--|--|--|'
  shp "$MAP" sep2-short.md 1 "[T8] section 2 separator of two dashes (three are required)" table.separator
  mkrep sep2-hole.md "$S2" '|---|---||---|---|'
  shp "$MAP" sep2-hole.md 1 "[T8] section 2 separator with an empty cell between" table.separator
  mkrep sep8-txt.md "$S8"$'\n| T' '|a|b|c|\n| T'
  shp "$MAP" sep8-txt.md 1 "[T8] section 8 separator of three cells that are not dashes" table.separator
  mkrep sep8-few.md "$S8"$'\n| T' '|---|---|\n| T'
  shp "$MAP" sep8-few.md 1 "[T8] section 8 separator of 2 cells" table.separator
  # a row that lacks its leading pipe is still a row of the table (and is checked)
  mkrep nl-bad.md "$R2" "$R2"'\n`x` | X | up | x | y |'
  shp "$MAP" nl-bad.md 1 "[T9] last row with no leading pipe and Status 'up' is checked → fail" table.enum
  mkrep nl-ok.md "$R2" "$R2"'\n`x` | X | running | x | y |'
  shp "$MAP" nl-ok.md 0 "[T9] last row with no leading pipe, 5 cells, a closed Status → pass"
  mkrep nl-4.md "$R2" "$R2"'\n`x` | X | running | x |'
  shp "$MAP" nl-4.md 1 "[T9] last row with no leading pipe and only 4 cells → fail" table.row_width
  mkrep nl-notail.md "$R2" "$R2"'\n`x` | X | running | x | y'
  shp "$MAP" nl-notail.md 0 "[T9] a row with neither leading nor trailing pipe, 5 cells → pass"
  mkrep nl-mid.md "$R2" "$R2"'\n| `x` | X | up | x | y |\n`z` | Z | running | x | y |'
  shp "$MAP" nl-mid.md 1 "[T9] a bad row followed by a row with no leading pipe: the bad row is caught" table.enum
  mkrep nl-prose.md "$R2" "$R2"'\nA line of prose with a pipe | inside'
  shp "$MAP" nl-prose.md 1 "[T9] prose with a '|' right below the table is read as a row → fail" table.row_width
  mkrep nl-plain.md "$R2" "$R2"'\nA line of prose without the bar'
  shp "$MAP" nl-plain.md 0 "[T9] prose without a '|' right below the table ends it → pass"
  mkrep nl-blank.md "$R2" "$R2"'\n\n`x` | X | up | x | y |'
  shp "$MAP" nl-blank.md 0 "[T9] after a blank line a pipe line without a leading pipe is not part of the table → pass"
  mkrep nl-m8.md "$R8" "$R8"'\nU | x'
  shp "$MAP" nl-m8.md 1 "[T9] section 8 last row with no leading pipe and 2 cells → fail" table.row_width
  mkrep nl-h2.md "$H2" 'Area | Component | Status | What it is · where to read | Check |'
  shp "$MAP" nl-h2.md 1 "[T9] section 2 header with no leading pipe: the separator row is read as the header → fail" table.header
  # invalid UTF-8 is a single finding and the exemption does not excuse it
  mk u8-broken.md "open('$SK','rb').read() + b'hello ch\xc3\x28o\n'"
  mk u8-cut.md "open('$SK','rb').read() + 'Cut inside the letter ế'.encode()[:-1]"
  mk u8-ff.md "open('$SK','rb').read() + b'\xff\xfe\n'"
  mk u8-ok.md "open('$SK','rb').read() + 'Valid accented text: ế ộ ữ ỡ\n'.encode()"
  shp "$MAP" u8-broken.md 1 "[T10] a broken UTF-8 byte in the middle of a line" encoding
  shp "$MAP" u8-cut.md 1 "[T10] a ledger cut inside a multi-byte character at the end" encoding
  shp "$MAP" u8-ff.md 1 "[T10] bytes 0xFF 0xFE" encoding
  shp "$MAP" u8-ok.md 0 "[T10] valid UTF-8 with accented letters → pass (the negative control of this group)"
  dif "$MAP" u8-broken.md "$NSC only an internal value changed, nothing visible moved" 1 "[T10] broken UTF-8 plus a valid exemption still blocks" systems/x.sh
  # escaped pipes
  mkrep e-ok.md '| `check a` |' '| `grep -c "a\|b" x` |'
  shp "$MAP" e-ok.md 0 "[T11] a Check cell with an escaped pipe inside a code span still has 5 cells → pass"
  mkrep e-ok2.md '| One sentence · read: `x.md` |' '| One sentence \| two sentences · read: `x.md` |'
  shp "$MAP" e-ok2.md 0 "[T11] an escaped pipe outside a code span → pass"
  mkrep e-end.md '| `check a` |' '| `grep -c "a\|"` |'
  shp "$MAP" e-end.md 0 "[T11] the last cell ends with an escaped pipe before the closing pipe → pass"
  mkrep e-bad.md '| `check a` |' '| `grep -c "a|b" x` |'
  shp "$MAP" e-bad.md 1 "[T11] an UNescaped pipe in a code span makes 6 cells → fail" table.row_width
  mkrep e-st.md '| running | One' '| running\|off | One'
  shp "$MAP" e-st.md 1 "[T11] Status 'running\\|off' is one unknown value, not two cells → fail" table.enum
  # a second table below a sub-heading still belongs to the section; indentation; fences; ATX headings
  mkrep sub2.md "$R2" "$R2"'\n\n### 2.1 More\n\n| Area | Component | Status | What it is · where to read | Check |\n|---|---|---|---|---|\n| `b` | B | running | x | y |'
  shp "$MAP" sub2.md 1 "[T12] a second table under a level-3 heading is still in section 2 → fail" table.count
  mkrep two8.md "$R8" "$R8"'\n\n| Item | Status | Where to read |\n|---|---|---|\n| U | v | z |'
  shp "$MAP" two8.md 1 "[T12] a second table in section 8 → fail" table.count
  python3 -c "
import sys
b = open(sys.argv[1], encoding='utf-8').read()
a, rest = b.split('## 2. What runs\n')
t, z = rest.split('\n## 8.')
sys.stdout.write(a + '## 2. What runs\n' + ''.join('  ' + l + '\n' if l else '\n' for l in t.split('\n')).rstrip('\n') + '\n\n## 8.' + z)" "$SK" > "$T/ind2.md"
  shp "$MAP" ind2.md 0 "[T13] section 2 table indented by two spaces (header, separator, row) is still a table → pass"
  mkrep ind-fence.md '| Area | Component |' '  ```\n| a | b |\n  ```\n\n| Area | Component |'
  shp "$MAP" ind-fence.md 0 "[T13] an indented fence is still a fence → pass"
  mkrep fence-open.md '## 8. Not in place' '```\na block that never closes\n## 8. Not in place'
  shp "$MAP" fence-open.md 1 "[T13] a fence that opens and never closes swallows the rest, section 8 is lost → fail" table.count
  local H='| Area | Component |'
  mkrep fz-tilde.md "$H" '~~~\n| a | b | c |\n~~~\n\n| Area | Component |'
  shp "$MAP" fz-tilde.md 0 "[T14] a ~~~ fence with a pipe line before the table → pass"
  mkrep fz-info.md "$H" '~~~ yaml\n| a | b | c |\n~~~~~\n\n| Area | Component |'
  shp "$MAP" fz-info.md 0 "[T14] a ~~~ fence with an info string, closed by a longer ~~~~~ → pass"
  mkrep fz-t4.md "$H" '~~~~\n~~~\n| a | b | c |\n~~~~\n\n| Area | Component |'
  shp "$MAP" fz-t4.md 0 "[T14] a ~~~~ fence is not closed by a shorter ~~~ → pass"
  mkrep fz-b4.md "$H" '````\n```\n| a | b | c |\n````\n\n| Area | Component |'
  shp "$MAP" fz-b4.md 0 "[T14] a four-backtick fence is not closed by three → pass"
  mkrep fz-mix.md "$H" '~~~\n```\n\n| Area | Component |'
  shp "$MAP" fz-mix.md 1 "[T14] a ~~~ fence is not closed by backticks: the table is inside it → fail" table.count
  mkrep fz-mix2.md "$H" '```\n~~~\n\n| Area | Component |'
  shp "$MAP" fz-mix2.md 1 "[T14] a backtick fence is not closed by ~~~ → fail" table.count
  mkrep fz-real.md "$R2" "$R2"'\n\n~~~\nx\n~~~\n\n| a | b | c |\n|---|---|\n| 1 | 2 |'
  shp "$MAP" fz-real.md 1 "[T14] a second (malformed) table right after a fence is still a table of section 2 → fail" table.count
  mkrep fz-ind3.md "$H" '   ~~~\n| a | b | c |\n   ~~~\n\n| Area | Component |'
  shp "$MAP" fz-ind3.md 0 "[T14] a ~~~ fence indented three spaces is still a fence → pass"
  mkrep fz-ind4.md "$H" '    ~~~\n\n| Area | Component |'
  shp "$MAP" fz-ind4.md 0 "[T14] four spaces make an indented code block, not a fence; the table below is read → pass"
  mkrep fz-ind4b.md "$H" '    ~~~\n    | a | b | c |\n\n| Area | Component |'
  shp "$MAP" fz-ind4b.md 0 "[T14] a pipe line indented four spaces is not a table → pass"
  mkrep fz-btinfo.md "$H" '``` a`b\n\n| Area | Component |'
  shp "$MAP" fz-btinfo.md 0 "[T14] a backtick run with a backtick in its info is a code span, not a fence → pass"
  local A
  for A in '### a | b | c' '# a | b | c' '###### a | b | c | d' '   ## a | b | c'; do
    mkrep atx-ok.md "$R2" "$R2"$'\n'"$A"; shp "$MAP" atx-ok.md 0 "[T15] the ATX heading '$A' right below the table ends it → pass"
  done
  for A in '####### a | b | c' '#a | b | c'; do
    mkrep atx-bad.md "$R2" "$R2"$'\n'"$A"; shp "$MAP" atx-bad.md 1 "[T15] '$A' is not a heading, so it is a 3-cell row → fail" table.row_width
  done
  mkrep atx-real.md "$R2" "$R2"'\n### Sub\n| a | b | c |\n|---|---|\n| 1 | 2 |'
  shp "$MAP" atx-real.md 1 "[T15] a second (malformed) table below a level-3 heading is still a table of section 2 → fail" table.count
  mkrep i4-hdr.md "$H" '    | a | b |\n\n| Area | Component |'
  shp "$MAP" i4-hdr.md 0 "[T16] a line indented four spaces is not a table header → pass"
  mkrep i4-tab.md "$H" "Code:"$'\n\n\t| a | b | c |\n\n| Area | Component |'
  shp "$MAP" i4-tab.md 0 "[T16] a line indented with one tab (four columns) is not a table header → pass"
  mkrep i4-row.md "$R2" "$R2"'\n    | a | b | c |'
  shp "$MAP" i4-row.md 0 "[T16] a pipe line indented four spaces right below ends the table, it is no row → pass"
  mkrep i3-hdr.md "$H" '   | a | b |\n\n| Area | Component |'
  shp "$MAP" i3-hdr.md 1 "[T16] three spaces still make a table header with no separator → the section holds two tables → fail" table.count
  # whitespace
  mkrep ws-tight.md "$R2" '|`a`|A|running|One sentence · read: `x.md`|`check a`|'
  shp "$MAP" ws-tight.md 0 "[T17] a row written with no blanks around the pipes → pass"
  mkrep ws-lots.md "$R2" $'|   `a`   |\tA\t|   running   | One   sentence · read: `x.md` |    `check a`    |   '
  shp "$MAP" ws-lots.md 0 "[T17] a row with many blanks and tabs and blanks after the last pipe → pass"
  mkrep ws-hdr.md "$H2" '|Area|Component|  Status  |What it is · where to read|Check|'
  shp "$MAP" ws-hdr.md 0 "[T17] a header written tight or padded is compared after collapsing blanks → pass"
  mkrep ws-label.md '| running | One' '| running *unchecked* | One'
  shp "$NOD" ws-label.md 1 "[T17] no decorations: a label next to a closed value is not an exact value → fail" table.enum
  shp "$MAP" ws-label.md 0 "[T17] decorations on: the same label → pass"
  mkrep ws-other.md '| running | One' '| running | *unchecked* One'
  shp "$MAP" ws-other.md 0 "[T17] the label inside the free-text cell → pass"
}

# ── [W] tables no `tables` entry covers ──────────────────────────────────────────────────────────
fam_other() {
  PLX=$1; T=$(fresh); mk_skeleton
  local W4; W4=$(mkprof width4 'd["current_state"]["table"] = {"columns": 4, "required": False}; d["current_state"]["table_own_width"] = False')
  shp "$W4" "$(basename "$SK")" 0 "[W0] the skeleton passes with a 4-column fallback (the one uncovered table is section 1)"
  mkrep r1-short.md "$R1" '| `c` | running | A test cluster · read: `README.md` |'
  shp "$W4" r1-short.md 1 "[W1] the uncovered table: a row with 3 cells where the fallback wants 4" table.row_width
  mkrep r1-names.md "$H1" '| Name | State | Content | Command |'
  shp "$W4" r1-names.md 0 "[W2] the fallback counts cells, it does not name columns: renamed columns → pass"
  mkrep s1-ok.md "$S1"$'\n| `c`' '|:---|---:|:---:| --- |\n| `c`'
  shp "$W4" s1-ok.md 0 "[W3] separator with alignment, 4 cells → pass"
  mkrep s1-few.md "$S1"$'\n| `c`' '|---|---|\n| `c`'
  shp "$W4" s1-few.md 1 "[W3] separator with 2 cells under a 4-cell header" table.separator
  mkrep s1-txt.md "$S1"$'\n| `c`' '|a|b|c|d|\n| `c`'
  shp "$W4" s1-txt.md 1 "[W3] a separator row of 4 cells that are not dashes" table.separator
  mkrep s1-many.md "$S1"$'\n| `c`' '|---|---|---|---|---|\n| `c`'
  shp "$W4" s1-many.md 1 "[W3] separator with 5 cells under a 4-cell header" table.separator
  mkrep s1-none.md "$S1"$'\n| `c`' '| `c`'
  shp "$W4" s1-none.md 1 "[W3] no separator row" table.separator
  mkrep s1-dup.md "$R1" "$R1"'\n|---|---|---|---|'
  shp "$W4" s1-dup.md 0 "[W4] an extra row that looks like a separator but has 4 cells counts as a row of 4 → pass"
  mkrep s1-dup6.md "$R1" "$R1"'\n|---|---|---|---|---|---|'
  shp "$W4" s1-dup6.md 1 "[W4] an extra separator-looking row of 6 cells → fail" table.row_width
  mkrep one-line.md '## 8. Not in place' '## 3. Other\n\nA lonely line:\n\n| only | one | line | here |\n\n## 8. Not in place'
  shp "$W4" one-line.md 1 "[W5] a lone line of the right width that starts with a pipe is a header with no separator → fail" table.separator
  mkrep nl1.md "$R1" "$R1"'\na | b'
  shp "$W4" nl1.md 1 "[W6] a last row with no leading pipe and 2 cells → fail" table.row_width
  mkrep nl1-ok.md "$R1" "$R1"'\n`d` | off | x | y'
  shp "$W4" nl1-ok.md 0 "[W6] a last row with no leading pipe and 4 cells → pass"
  mkrep nlh1.md "$H1" 'Cluster | Status | What it is · read | Check |'
  shp "$W4" nlh1.md 1 "[W6] a header with no leading pipe: the separator is read as the header, the next row is no separator → fail" table.separator
  mkrep w6.md "$R1" '| `c` | running | A test cluster · read: `README.md` | `check c` | extra | more |'
  shp "$W4" w6.md 1 "[W7] a row with 6 cells under a 4-cell header" table.row_width
  mkrep w5.md "$R1" '| `c` | running | A test cluster · read: `README.md` | `check c` |  |'
  shp "$W4" w5.md 1 "[W7] a row with one empty cell too many at the end" table.row_width
  mkrep e1-ok.md '| `c` | running | A test' '| `c` | running | A \| test'
  shp "$W4" e1-ok.md 0 "[W8] an escaped pipe in the uncovered table → pass"
  mkrep e1-bad.md '| `c` | running | A test' '| `c` | run | ning | A test'
  shp "$W4" e1-bad.md 1 "[W8] an unescaped pipe in the uncovered table makes 5 cells → fail" table.row_width
  mkrep atx1.md "$R1" "$R1"'\n### a | b'
  shp "$W4" atx1.md 0 "[W9] an ATX heading right below the uncovered table ends it → pass"
  mkrep plain.md '## 8. Not in place' '## 3. Other\n\n| a | b | c | d |\n|---|---|---|---|\n| 1 | 2 | 3 | 4 |\n\n## 8. Not in place'
  shp "$W4" plain.md 0 "[W10] a well-formed 4-cell table below a plain heading → pass"
  mkrep plain-bad.md '## 8. Not in place' '## 3. Other\n\n| a | b | c | d |\n|---|---|---|---|\n| 1 | 2 | 3 |\n\n## 8. Not in place'
  shp "$W4" plain-bad.md 1 "[W10] …and a 3-cell row in it → fail" table.row_width
  mkrep split1.md "$S1" '\n|---|---|---|---|'
  shp "$W4" split1.md 1 "[W11] a blank line between the header and the separator splits the table → fail" table.separator
  mkrep hdr-only.md '## 8. Not in place' '## 3. Other\n\n| a | b | c | d |\n|---|---|---|---|\n\n## 8. Not in place'
  shp "$W4" hdr-only.md 0 "[W4b] an uncovered table that is only a header and a separator passes the fallback (only a table of an entry needs a data row)"
  mkrep e1-empty.md "$R1" '| `c` | running |  | `check c` |'
  shp "$W4" e1-empty.md 1 "[W4c] no_empty_cells also applies to an uncovered table checked by the fallback (pinned: the hub only checked sections 2 and 8)" table.cell_empty
  local PNE; PNE=$(mkprof allow-empty 'd["current_state"]["no_empty_cells"] = False')
  mkrep r2-e1b.md '| `check a` |' '|  |'
  shp "$PNE" r2-e1b.md 0 "[W4d] no_empty_cells false: an empty cell in a covered table is fine (no_empty_cells true: see [T4])"
  shp "$MAP" r2-e1b.md 1 "[W4e] …and with no_empty_cells true the same ledger fails" table.cell_empty
  # without a fallback the uncovered tables are not looked at
  local NOW; NOW=$(mkprof no-own-width 'd["current_state"]["table_own_width"] = False')
  shp "$NOW" r1-short.md 0 "[W12] table null and table_own_width false: a malformed uncovered table is not looked at → pass"
  shp "$MAP" r1-short.md 1 "[W12b] …and the fixture, which turns table_own_width on, fails it ([O1])" table.row_width
  # required
  local WR; WR=$(mkprof required 'd["current_state"]["table"] = {"columns": 4, "required": True}; d["current_state"]["tables"] = []; d["current_state"]["table_own_width"] = False')
  mk notab.md "b'# Platform state\n\nNo table at all.\n'"
  shp "$WR" notab.md 1 "[W13] table.required: a ledger with no table → fail" table.required
  shp "$WR" skel.md 1 "[W14] table.columns 4 with no tables entries: the 5-column and 3-column tables are uncovered and wrong" table.header
  local WN; WN=$(mkprof not-required 'd["current_state"]["table"] = {"columns": 4, "required": False}; d["current_state"]["tables"] = []; d["current_state"]["table_own_width"] = False')
  shp "$WN" notab.md 0 "[W15] required false: no table is fine"
}

# ── [O] table_own_width: an uncovered table is checked against its own header ───────────────────
# The fixture profile (MAP) has `table: null` and `table_own_width: true`; the uncovered table of the skeleton is section 1.
fam_own() {
  PLX=$1; T=$(fresh); mk_skeleton
  shp "$MAP" skel.md 0 "[O0] the skeleton passes: its uncovered table is as wide as its header"
  mkrep o-short.md "$R1" '| `c` | running | A test cluster · read: `README.md` |'
  shp "$MAP" o-short.md 1 "[O1] a row with 3 cells under a 4-cell header → fail" table.row_width
  mkrep o-long.md "$R1" '| `c` | running | A test cluster · read: `README.md` | `check c` | x |'
  shp "$MAP" o-long.md 1 "[O2] a row with 5 cells under a 4-cell header → fail" table.row_width
  mkrep o-sep-few.md "$S1"$'\n| `c`' '|---|---|\n| `c`'
  shp "$MAP" o-sep-few.md 1 "[O3] a separator of 2 cells under a 4-cell header → fail" table.separator
  mkrep o-sep-txt.md "$S1"$'\n| `c`' '|a|b|c|d|\n| `c`'
  shp "$MAP" o-sep-txt.md 1 "[O3] a separator row whose cells are not dashes → fail" table.separator
  mkrep o-sep-none.md "$S1"$'\n| `c`' '| `c`'
  shp "$MAP" o-sep-none.md 1 "[O3] no separator row → fail" table.separator
  mkrep o-sep-ok.md "$S1"$'\n| `c`' '|:---|---:|:---:| --- |\n| `c`'
  shp "$MAP" o-sep-ok.md 0 "[O3] a separator with alignment colons and blanks → pass"
  # the width is the header's, not a fixed number: the whole table made 6 wide
  mkrep o-six.md "$H1"$'\n'"$S1"$'\n'"$R1" '| a | b | c | d | e | f |\n|---|---|---|---|---|---|\n| 1 | 2 | 3 | 4 | 5 | 6 |'
  shp "$MAP" o-six.md 0 "[O4] a 6-column uncovered table with 6-cell rows → pass (own width, not a fixed number)"
  mkrep o-six-bad.md "$H1"$'\n'"$S1"$'\n'"$R1" '| a | b | c | d | e | f |\n|---|---|---|---|---|---|\n| 1 | 2 | 3 | 4 | 5 |'
  shp "$MAP" o-six-bad.md 1 "[O4] …and a 5-cell row under that 6-cell header → fail" table.row_width
  mkrep o-two.md "$H1"$'\n'"$S1"$'\n'"$R1" '| a | b |\n|---|---|\n| 1 | 2 |'
  shp "$MAP" o-two.md 0 "[O4] a 2-column uncovered table → pass"
  mkrep o-names.md "$H1" '| Name | State | Content | Command |'
  shp "$MAP" o-names.md 0 "[O5] column names are free in an uncovered table → pass"
  mkrep o-hdr-only.md "$R1" ''
  shp "$MAP" o-hdr-only.md 0 "[O6] header and separator with no data row → pass (only a table of an entry needs a row)"
  mkrep o-empty.md "$R1" '| `c` |  | A test cluster · read: `README.md` | `check c` |'
  shp "$MAP" o-empty.md 0 "[O7] an empty cell in an uncovered table → pass even with no_empty_cells true (width only)"
  mkrep o-empty-cov.md '| `check a` |' '|  |'
  shp "$MAP" o-empty-cov.md 1 "[O7] …while the same empty cell in a table an entry covers still fails" table.cell_empty
  mkrep o-plain.md '## 8. Not in place' '## 3. Other\n\n| a | b |\n|---|---|\n| 1 | 2 | 3 |\n\n## 8. Not in place'
  shp "$MAP" o-plain.md 1 "[O8] a table under a plain heading with a 3-cell row under a 2-cell header → fail" table.row_width
  mkrep o-first.md "$S1" '|---|---|---|---|\n\n| a | b |\n|---|---|\n| 1 | 2 | 3 |'
  shp "$MAP" o-first.md 1 "[O8] a second uncovered table in the same section is looked at too → fail" table.row_width
  mkrep o-nosec.md '# Platform state' '| a | b |\n|---|---|\n| 1 | 2 | 3 |\n\n# Platform state'
  shp "$MAP" o-nosec.md 1 "[O9] a table before any level-2 heading is uncovered and looked at → fail" table.row_width
  mkrep o-fence.md '## 8. Not in place' '## 3. Other\n\n```\n| a | b |\n|---|---|\n| 1 | 2 | 3 |\n```\n\n## 8. Not in place'
  shp "$MAP" o-fence.md 0 "[O10] a malformed table inside a code fence is not a table → pass"
  mkrep o-esc.md '| `c` | running | A test' '| `c` | running | A \| test'
  shp "$MAP" o-esc.md 0 "[O11] an escaped pipe in an uncovered table → pass"
  mkrep o-unesc.md '| `c` | running | A test' '| `c` | run | ning | A test'
  shp "$MAP" o-unesc.md 1 "[O11] an unescaped pipe makes a 5th cell → fail" table.row_width
  # off: not looked at; covered tables are not looked at as uncovered ones
  local NOW; NOW=$(mkprof no-own-width 'd["current_state"]["table_own_width"] = False')
  shp "$NOW" o-short.md 0 "[O12] table_own_width false: the same short row is not looked at → pass"
  mkrep o-cov.md "$R2" '| `a` | A | running |'
  shp "$MAP" o-cov.md 1 "[O13] a short row in a covered table is reported once, as a covered table's row" table.row_width
  eq "$(gr "$MAP" shape "$T/o-cov.md" | grep -c 'table.row_width')" 1 "[O13] …exactly once (a covered table is not checked again as an uncovered one)"
  # with the fixture's section-1 table the only uncovered one, and a second fault elsewhere, the line numbers are kept
  eq "$(gr "$MAP" shape "$T/o-short.md" | sed -n 2p | cut -d'|' -f1)" "$(grep -n -F -- "| \`c\` | running | A test cluster · read: \`README.md\` |" "$T/o-short.md" | head -1 | cut -d: -f1)" "[O14] the problem is reported on the line of the short row"
}

# ── [Y] decorations: a label next to a closed value ──────────────────────
# The fixture profile (MAP) spells `decorations: {Status: "[*]unchecked[*]"}`; the label is a synthetic string of the fixture.
fam_deco() {
  PLX=$1; T=$(fresh); mk_skeleton
  local st
  shp "$MAP" skel.md 0 "[Y0] the skeleton passes"
  for st in 'running *unchecked*' '*unchecked* running' '*unchecked* running *unchecked*' 'running *unchecked* *unchecked*' \
            '*unchecked* *unchecked* off' 'running*unchecked*' '*unchecked*not deployed' 'in review *unchecked*' '*unchecked* in review' \
            'running *UNCHECKED*' '*Unchecked* off' 'running *uNcHeCkEd*' 'in*unchecked* review'; do
    mkrep y-ok.md '| running | One' "| $st | One"; shp "$MAP" y-ok.md 0 "[Y1] Status '$st' (label before, after, both sides, repeated, any case, anywhere) → pass"
  done
  for st in '*unchecked*' '*unchecked* *unchecked*' 'up *unchecked*' '*unchecked* is running' 'running unchecked' 'running (unchecked)' \
            'running *checked*' '*other* running' 'running **unchecked**' 'in *unchecked* review' 'running, *unchecked*'; do
    mkrep y-bad.md '| running | One' "| $st | One"; shp "$MAP" y-bad.md 1 "[Y2] Status '$st' is no closed value once the label is taken off → fail" table.enum
  done
  mkrep y-body.md '| running | One' '| running | *unchecked* One *unchecked*'
  shp "$MAP" y-body.md 0 "[Y3] a label in a free-text cell is never a problem → pass"
  # a column that has enums but no decorations stays exact
  local PC; PC=$(mkprof deco-other-col 'd["current_state"]["tables"][0]["enums"]["Component"] = ["A"]')
  mkrep y-col.md '| `a` | A |' '| `a` | A *unchecked* |'
  shp "$PC" y-col.md 1 "[Y4] a label in a column whose enums have no decorations → fail (decorations are per column)" table.enum
  mkrep y-col-ok.md '| running | One' '| running *unchecked* | One'
  shp "$PC" y-col-ok.md 0 "[Y4] …while the decorated column of the same table still takes it → pass"
  # a list of regexes: each is taken off in turn
  local PL; PL=$(mkprof deco-list 'd["current_state"]["tables"][0]["decorations"]["Status"] = ["[*]unchecked[*]", "[(]uat[)]"]')
  for st in 'running (UAT)' '(uat) running *unchecked*' '*unchecked* off (uat) (uat)'; do
    mkrep y-list.md '| running | One' "| $st | One"; shp "$PL" y-list.md 0 "[Y5] two decorations, Status '$st' → pass"
  done
  mkrep y-list-bad.md '| running | One' '| running (prod) | One'
  shp "$PL" y-list-bad.md 1 "[Y5] a decoration that is in neither regex → fail" table.enum
  # case: any case by default, exact when the regex says so
  local PS; PS=$(mkprof deco-case 'd["current_state"]["tables"][0]["decorations"]["Status"] = "(?-i:[*]unchecked[*])"')
  mkrep y-case.md '| running | One' '| running *unchecked* | One'
  shp "$PS" y-case.md 0 "[Y6] a case-sensitive regex ((?-i:...)): the exact label → pass"
  mkrep y-case-bad.md '| running | One' '| running *UNCHECKED* | One'
  shp "$PS" y-case-bad.md 1 "[Y6] …and the same label in capitals → fail" table.enum
  # the decoration is a regex: anchored at the cell's start, it only matches there
  local PA; PA=$(mkprof deco-anchor 'd["current_state"]["tables"][0]["decorations"]["Status"] = "^[*]unchecked[*] "')
  mkrep y-anch.md '| running | One' '| *unchecked* running | One'
  shp "$PA" y-anch.md 0 "[Y7] a regex anchored with ^ takes the label off the start → pass"
  mkrep y-anch-bad.md '| running | One' '| running *unchecked* | One'
  shp "$PA" y-anch-bad.md 1 "[Y7] …and does not match it at the end → fail" table.enum
  # decorated values do not hide other faults of the same row
  mkrep y-row.md '| running | One sentence · read: `x.md` | `check a` |' '| running *unchecked* | One sentence · read: `x.md` |'
  shp "$MAP" y-row.md 1 "[Y8] a decorated Status in a short row → still a row-width fault" table.row_width
  mkrep y-empty.md '| running | One sentence · read: `x.md` | `check a` |' '| running *unchecked* | One sentence · read: `x.md` |  |'
  shp "$MAP" y-empty.md 1 "[Y8] a decorated Status in a row with an empty Check cell → still an empty-cell fault" table.cell_empty
  # the regexes of a column are removed in the order written: removing the label's inner text first leaves the shell for the next
  local PO1 PO2; PO1=$(mkprof deco-order1 'd["current_state"]["tables"][0]["decorations"]["Status"] = ["x", "[(][)]"]')
  PO2=$(mkprof deco-order2 'd["current_state"]["tables"][0]["decorations"]["Status"] = ["[(][)]", "x"]')
  mkrep y-ord.md '| running | One' '| running(x) | One'
  shp "$PO1" y-ord.md 0 "[Y10] decorations in the order x, then (): 'running(x)' becomes 'running()' and then 'running' → pass"
  shp "$PO2" y-ord.md 1 "[Y10] …in the order (), then x: the shell is not there yet when it is tried → fail (order matters)" table.enum
  # a decoration key is compared with the enums key after NFC and blank collapsing, like column names
  local PK; PK=$(mkprof deco-key-blanks 'e = d["current_state"]["tables"][0]; e["columns"][2] = "Sta  tus"; e["enums"] = {"Sta  tus": e["enums"]["Status"]}; e["decorations"] = {"Sta  tus": "[*]unchecked[*]"}')
  mkrep y-key.md '| Area | Component | Status |' '| Area | Component | Sta tus |'
  python3 - "$T/y-key.md" "$T/y-key3.md" <<'PY'
import sys
a = open(sys.argv[1], encoding="utf-8").read()
open(sys.argv[2], "w", encoding="utf-8").write(a.replace("| running | One", "| running *unchecked* | One", 1))
PY
  shp "$PK" y-key3.md 0 "[Y11] a column spelled with a double blank in columns, enums and decorations: the label is still taken off → pass"
  # `_` keys are comments: ignored by the loader, never compiled
  local PU; PU=$(mkprof deco-comment 'e = d["current_state"]["tables"][0]; e["decorations"]["_note"] = "("; e["enums"]["_n"] = 5')
  shp "$PU" skel.md 0 "[Y12] a _-key under decorations or enums is a comment: no crash, the skeleton passes"
  # no decorations spelled: exact, as before
  local NOD2; NOD2=$(mkprof no-deco2 'd["current_state"]["tables"][0].pop("decorations")')
  mkrep y-exact.md '| running | One' '| running *unchecked* | One'
  shp "$NOD2" y-exact.md 1 "[Y9] no decorations key: the label is outside the closed values" table.enum
}

# ── [A] decide(): the shape of the call ──────────────────────────────────────────────────────────
fam_api() {
  PLX=$1; T=$(fresh); mk_skeleton
  local R
  py() { ( cd "$TMP" && cenv python3 -I -B -c "import sys; sys.path.insert(0, sys.argv[1]); import current_state as S, sdlc_config as C; cfg, _p, _r = C.load(sys.argv[2]); p = S.profile_from_config(cfg); good = open(sys.argv[3], 'rb').read(); $1" "$PLX/scripts" "$MAP" "$SK" ); }
  eq "$(py "r = S.decide(['kb/current-state.md'], '', p, ledger=good); print(type(r).__name__, len(r), type(r[0]).__name__, type(r[1]).__name__)")" "tuple 2 int str" "[A1] decide returns a (rc, message) pair of an int and a string"
  eq "$(py "print(S.decide(['kb/current-state.md'], '', p, ledger=good, root=sys.argv[2])[0])")" 0 "[A2] decide(paths, body, profile, ledger=<bytes>) with a good ledger in the diff → 0"
  eq "$(py "print(S.decide(['kb/current-state.md'], '', p, ledger=good + b'y' * 401, root=sys.argv[2])[0])")" 1 "[A3] …a bad ledger → 1 (a positive control: the argument is measured)"
  eq "$(py "print(S.decide(['kb/current-state.md'], '', p, ledger=good.decode(), root=sys.argv[2])[0])")" 0 "[A4] the ledger argument may be a str → 0"
  eq "$(py "print(S.decide(['kb/current-state.md'], '', p, ledger='ok\n', root=sys.argv[2])[0])")" 1 "[A5] a text with no section 2 or 8 → 1 (the template is enforced)"
  eq "$(py "print(S.decide(['kb/current-state.md'], '', p, ledger=good + b'\xff', root=sys.argv[2])[0])")" 1 "[A6] a ledger of broken UTF-8 → 1"
  eq "$(py "print(S.decide(['kb/current-state.md'], '', p, root=sys.argv[2] + '/does-not-exist')[0])")" 1 "[A7] the ledger is in the diff and cannot be read (deleted) → 1"
  eq "$(py "print(S.decide(['systems/x'], '$NSC only an internal value changed, nothing visible moved', p, root=sys.argv[2] + '/does-not-exist')[0])")" 0 "[A8] a watched change with a valid exemption and no ledger file at all → 0 (nothing to measure)"
  eq "$(py "print(S.decide(['docs/y.md'], '', p, root=sys.argv[2] + '/does-not-exist')[0])")" 0 "[A9] a change that is not watched, no ledger file → 0, no crash"
  eq "$(py "print(S.decide(['kb/current-state.md'], '', p, root=sys.argv[2])[0])")" 0 "[A10] with no ledger argument the ledger is read under the root (the fixture's own ledger) → 0"
  mkdir -p "$T/dirroot/kb/current-state.md"
  eq "$(py "print(S.decide(['kb/current-state.md'], '', p, root=sys.argv[2].replace(sys.argv[2], '$T/dirroot'))[0])")" 1 "[A11] the ledger path is a directory (it cannot be opened) and is in the diff → 1"
  eq "$(py "print(S.decide(['kb/current-state.md'], '', None, ledger=good, root=sys.argv[2])[0])")" 0 "[A12] profile None means the ledger profile; it watches nothing → 0 (does not apply)"
  eq "$(py "print(len(S.problems(good, p)), len(S.problems(good.decode(), p)), S.problems(good + b'y' * 401, p)[0][0])")" "0 0 $(( $(grep -c '' "$SK") + 1 ))" "[A13] problems(text, profile) takes bytes or str and returns (line, reason) pairs; the over-long line is reported at its line"
  eq "$(py "print(S.problems_classified(good + b'y' * 401, p)[0][1])")" size.line_chars "[A14] problems_classified names the class of a problem"
  eq "$(py "print(S.exemption('$NSC enough reason to pass here', p) is not None, S.exemption('no token', p))")" "True None" "[A15] exemption(body, profile) returns the reason or None"
}

# ── [L] the ledger profile ───────────────────────────────────────────────────────────────────────
fam_ledger() {
  PLX=$1; T=$(fresh); mk_skeleton
  local LP; LP="$TMP/prof-ledger-none"; mkdir -p "$LP"                      # no config file: the defaults, the ledger preset
  local LK; LK=$(mkprof ledger-knobs 'd["current_state"] = {"template": "ledger", "watch": ["systems/"], "table": {"columns": 3, "required": True}}')
  local LG="$T/good.md"; printf '# State\n\nA short, current statement.\n\n| Item | Status | Where |\n|---|---|---|\n| a | running | `x.md` |\n' > "$LG"
  shp "$LP" good.md 0 "[L1] the ledger profile (no config) passes its good ledger"
  shp "$LK" good.md 0 "[L2] the ledger profile with a watch list and a 3-column table passes the same ledger"
  python3 -c "import sys; sys.stdout.write('a line\n' * 120)" > "$T/l120.md"
  python3 -c "import sys; sys.stdout.write('a line\n' * 121)" > "$T/l121.md"
  shp "$LP" l120.md 0 "[L3] 120 lines → pass (the boundary of the ledger preset)"
  shp "$LP" l121.md 1 "[L4] 121 lines → fail" size.lines
  python3 -c "import sys; sys.stdout.write(('x' * 99 + '\n') * 120)" > "$T/by-ok.md"
  python3 -c "import sys; sys.stdout.write(('x' * 99 + '\n') * 120 + 'x' * 100)" > "$T/by-big.md"
  [ "$(wc -c < "$T/by-ok.md" | tr -d ' ')" = 12000 ] && ok "[L5] instrument: the planted ledger measures exactly 12000 bytes" || bad "[L5] instrument: the planted ledger is not 12000 bytes"
  shp "$LP" by-ok.md 0 "[L6] 12000 bytes → pass"
  shp "$LP" by-big.md 1 "[L7] 12100 bytes and 121 lines → fail" size.bytes
  python3 -c "import sys; sys.stdout.write('y' * 200 + '\n')" > "$T/c200.md"; python3 -c "import sys; sys.stdout.write('y' * 201 + '\n')" > "$T/c201.md"
  shp "$LP" c200.md 0 "[L8] a line of 200 characters → pass"
  shp "$LP" c201.md 1 "[L9] a line of 201 characters → fail" size.line_chars
  python3 -c "import sys; sys.stdout.buffer.write(('y' * 200 + '\r\n').encode())" > "$T/crlf200.md"
  shp "$LP" crlf200.md 0 "[L10] 200 characters and a CRLF → pass (the CR is no character)"
  python3 -c "import sys; sys.stdout.buffer.write(b'The state is fine.\n\xff\n')" > "$T/bad8.md"
  shp "$LP" bad8.md 1 "[L11] invalid UTF-8 → fail" encoding
  local ID
  for ID in 'date_iso|Set on 2026-10-11 by hand' 'date_slash_ymd|Set 2026/10/11 by hand' 'date_dm|Set on 11/10 by hand' 'date_words_month|Set in tháng 10 năm 2026' \
            'date_words_day|Set on ngày 11 tháng 10' 'date_words_dm|Set on ngày 11/10' 'pr_ref|Fixed by PR 123' 'commit_sha|Built from commit abcdef1234' \
            'past_words|Đã gỡ the old service' 'update_stamp|Cập nhật lần cuối today'; do
    printf '# State\n\n%s\n' "${ID#*|}" > "$T/h-${ID%%|*}.md"
    shp "$LP" "h-${ID%%|*}.md" 1 "[L12] history sign ${ID%%|*}: '${ID#*|}' → fail" "history.${ID%%|*}"
  done
  printf '# State\n\n## History of the system\n\nstuff\n' > "$T/h-head.md"
  shp "$LP" h-head.md 1 "[L12] a history heading → fail" history.history_heading
  local PF; PF=$(mkprof forbid-one 'd["current_state"] = {"template": "ledger", "forbid": ["pr_ref"]}')
  shp "$PF" h-date_iso.md 0 "[L13] forbid lists only pr_ref: a date is tolerated → pass"
  shp "$PF" h-pr_ref.md 1 "[L14] …and a PR reference is not" history.pr_ref
  local PN; PN=$(mkprof no-forbid 'd["current_state"] = {"template": "ledger", "forbid": []}')
  shp "$PN" h-pr_ref.md 0 "[L15] forbid [] tolerates every sign" ; shp "$PN" h-head.md 0 "[L15] …and the history heading"
  local PL; PL=$(mkprof no-line-cap 'd["current_state"] = {"template": "ledger", "limits": {"lines": None}}')
  shp "$PL" l121.md 0 "[L16] limits.lines null: no cap on the number of lines → pass"
  python3 -c "import sys; sys.stdout.write('a\n' * 5000)" > "$T/l5000.md"
  shp "$PL" l5000.md 0 "[L17] …5000 lines → pass"; shp "$LP" l5000.md 1 "[L18] …and the ledger preset still refuses them" size.lines
  local PP; PP=$(mkprof pattern 'd["current_state"] = {"template": "ledger", "forbid_patterns": [{"id": "todo", "regex": "TODO"}]}')
  printf '# State\n\nTODO later\n' > "$T/todo.md"
  shp "$PP" todo.md 1 "[L19] forbid_patterns: a line matching the repo's own regex → fail" pattern.todo
  shp "$LP" todo.md 0 "[L20] …and with no such pattern it passes"
  # table, watch and the exemption on the ledger profile
  printf '# State\n\n| Item | Status |\n|---|---|\n| a | running |\n' > "$T/t2.md"
  shp "$LK" t2.md 1 "[L21] the 3-column table knob: a 2-column table → fail" table.header
  local PTR; PTR=$(mkprof table-no-required 'd["current_state"] = {"template": "ledger", "table": {"columns": 3}}')
  shp "$PTR" good.md 0 "[L21b] table with columns only (required defaults to false): a 3-column table passes, nothing crashes"
  printf '# State\n\nNo tables.\n' > "$T/t0.md"
  shp "$PTR" t0.md 0 "[L21c] …and a ledger with no table passes (required false)"
  shp "$LK" t0.md 1 "[L22] table.required with no table → fail" table.required
  dif "$LK" good.md "" 1 "[L23] watched path with no ledger change → rc 1" systems/a.sh
  dif "$LK" good.md "" 0 "[L24] …with the ledger in the diff → rc 0" systems/a.sh kb/current-state.md
  dif "$LK" good.md "$NSC because nothing visible changed" 0 "[L25] …with the default English exemption token and a reason → rc 0" systems/a.sh
  dif "$LK" good.md "NO STATE CHANGE because nothing visible changed" 1 "[L26] …a token without its colon is not the token → rc 1" systems/a.sh
  dif "$LK" t2.md "" 1 "[L27] a shape fault in a ledger that is in the diff → rc 1" kb/current-state.md
  dif "$LP" good.md "" 0 "[L28] the ledger profile with no config watches nothing: the gate does not apply → rc 0" systems/a.sh
  # the preset as the loader lays it
  eq "$(cenv python3 -I -B -c "
import sys; sys.path.insert(0, sys.argv[1]); import sdlc_config as C
cfg, probs, _ = C.load(sys.argv[2]); cs = cfg['current_state']
print(probs, cs['limits'], cs['forbid'], cs['table'], cs['watch'], cs['gate'])" "$PLX/scripts" "$SHAPED")" "[] {'lines': None, 'bytes': 28000, 'line_chars': 400, 'warn_ratio': 0.85} [] None ['systems/', 'deploy/'] builtin" "[L29] the map preset under the fixture's file: sizes and forbid from the preset, table null and watch spelled by the file"
  local PM; PM=$(mkprof bare-map 'd["current_state"] = {"template": "map"}')
  eq "$(cenv python3 -I -B -c "
import sys; sys.path.insert(0, sys.argv[1]); import sdlc_config as C
cfg, probs, _ = C.load(sys.argv[2]); cs = cfg['current_state']
print(probs, cs['limits'], cs['forbid'], cs['table'], cs['watch'], cs['tables'])" "$PLX/scripts" "$PM")" "[] {'lines': None, 'bytes': 28000, 'line_chars': 400, 'warn_ratio': 0.85} [] {'columns': 5, 'required': True} [] []" "[L30] the bare map preset: no line cap, 28000 bytes, 400 characters, nothing forbidden, a required 5-column table, no watch, no named tables"
  eq "$(cenv python3 -I -B -c "
import sys; sys.path.insert(0, sys.argv[1]); import sdlc_config as C
cfg, probs, _ = C.load(sys.argv[2]); print(cfg['current_state']['limits'], cfg['current_state']['table'])" "$PLX/scripts" "$LP")" "{'lines': 120, 'bytes': 12000, 'line_chars': 200, 'warn_ratio': 0.85} None" "[L31] no config: the ledger preset (120 lines, 12000 bytes, 200 characters, no table)"
  local PX; PX=$(mkprof file-wins 'd["current_state"] = {"template": "map", "limits": {"bytes": 1000}, "table": None}')
  eq "$(cenv python3 -I -B -c "
import sys; sys.path.insert(0, sys.argv[1]); import sdlc_config as C
cfg, probs, _ = C.load(sys.argv[2]); cs = cfg['current_state']; print(cs['limits'], cs['table'])" "$PLX/scripts" "$PX")" "{'lines': None, 'bytes': 1000, 'line_chars': 400, 'warn_ratio': 0.85} None" "[L32] a key spelled in the file wins over the preset (merged per key; table null replaces the preset's table)"
  eq "$(cenv python3 -I -B -c "
import sys; sys.path.insert(0, sys.argv[1]); import sdlc_config as C
print(C.load(sys.argv[2])[0]['current_state']['table_own_width'], C.load(sys.argv[3])[0]['current_state']['table_own_width'], C.load(sys.argv[4])[0]['current_state']['table_own_width'])" "$PLX/scripts" "$LP" "$PM" "$SHAPED")" "False False True" "[L35] table_own_width: off with no config (ledger preset), off in the bare map preset, on where the fixture's file turns it on"
  shp "$PM" good.md 1 "[L33] the bare map preset on a one-table ledger of 3 columns: the required 5-column table is wrong → fail" table.header
  printf '# State\n\n| a | b | c | d | e |\n|---|---|---|---|---|\n| 1 | 2 | 3 | 4 | 5 |\n' > "$T/five.md"
  shp "$PM" five.md 0 "[L34] …and a ledger with a 5-column table passes the bare preset"
}

# ── [V] validation of the new keys ───────────────────────────────────────────────────────────────
fam_validate() {
  PLX=$1
  vc() {  # vc <label> <config json> <want rc> [key the message must name | warn:<key> that must be warned about as unknown]
    local d R rc; d=$(fresh); mkdir -p "$d/.vibemaestro"; printf '%s' "$2" > "$d/.vibemaestro/sdlc.json"
    R=$( cd "$TMP" && cenv python3 "$PLX/scripts/kb.py" config check --root "$d" 2>&1 ); rc=$?
    eq "$rc" "$3" "[V] $1: rc $3"
    case "${4:-}" in
      warn:*) has "$R" "${4#warn:}: unknown key" "[V] $1: warns about ${4#warn:}";;
      ?*) has "$R" "$4" "[V] $1: names $4";;
      *) [ "$3" = 0 ] && hasnt "$R" "unknown key" "[V] $1: no unknown-key warning (every key is known)";;
    esac
  }
  vc "tables, no_empty_cells, forbid_patterns, exempt and a null line cap together" '{"current_state": {"limits": {"lines": null}, "tables": [{"heading": "^2[.]", "columns": ["a", "b"], "enums": {"b": ["x", "y"]}}], "no_empty_cells": true, "forbid_patterns": [{"id": "diary", "regex": "(?i)x"}], "exempt": {"min_reason_chars": 15}}}' 0
  vc "limits.lines zero" '{"current_state": {"limits": {"lines": 0}}}' 65 current_state.limits.lines
  vc "tables is not a list" '{"current_state": {"tables": {}}}' 65 current_state.tables
  vc "a table entry with no columns" '{"current_state": {"tables": [{"heading": "x"}]}}' 65 current_state.tables[0].columns
  vc "a table entry with no heading" '{"current_state": {"tables": [{"columns": ["a"]}]}}' 65 current_state.tables[0].heading
  vc "a table entry with a bad heading regex" '{"current_state": {"tables": [{"heading": "(", "columns": ["a"]}]}}' 65 current_state.tables[0].heading
  vc "a table entry with an unknown key" '{"current_state": {"tables": [{"heading": "x", "columns": ["a"], "color": 1}]}}' 0 warn:current_state.tables[0].color
  vc "an enums column that is not a column" '{"current_state": {"tables": [{"heading": "x", "columns": ["a"], "enums": {"zz": ["v"]}}]}}' 65 current_state.tables[0].enums.zz
  vc "an empty enums list" '{"current_state": {"tables": [{"heading": "x", "columns": ["a"], "enums": {"a": []}}]}}' 65 current_state.tables[0].enums.a
  vc "no_empty_cells that is not a boolean" '{"current_state": {"no_empty_cells": "yes"}}' 65 current_state.no_empty_cells
  vc "a forbid pattern with a bad regex" '{"current_state": {"forbid_patterns": [{"id": "d", "regex": "("}]}}' 65 current_state.forbid_patterns[0].regex
  vc "a forbid pattern whose id is a built-in id" '{"current_state": {"forbid_patterns": [{"id": "date_iso", "regex": "x"}]}}' 65 current_state.forbid_patterns[0].id
  vc "two forbid patterns with the same id" '{"current_state": {"forbid_patterns": [{"id": "d", "regex": "x"}, {"id": "d", "regex": "y"}]}}' 65 current_state.forbid_patterns[1].id
  vc "a forbid pattern with no regex" '{"current_state": {"forbid_patterns": [{"id": "d"}]}}' 65 current_state.forbid_patterns[0].regex
  vc "exempt.min_reason_chars negative" '{"current_state": {"exempt": {"min_reason_chars": -1}}}' 65 current_state.exempt.min_reason_chars
  vc "an unknown key under exempt (a warning)" '{"current_state": {"exempt": {"reason": 3}}}' 0 warn:current_state.exempt.reason
  vc "table with no columns" '{"current_state": {"table": {"required": true}}}' 65 current_state.table.columns
  vc "table with columns only" '{"current_state": {"table": {"columns": 2}}}' 0
  vc "watch entry with a ./ prefix" '{"current_state": {"watch": ["./systems/"]}}' 65 'current_state.watch[0]'
  vc "ledger path with a trailing slash" '{"current_state": {"path": "kb/"}}' 65 current_state.path
  vc "ledger path with a . segment" '{"current_state": {"path": "kb/./current-state.md"}}' 65 current_state.path
  vc "two entries with the same heading" '{"current_state": {"tables": [{"heading": "x", "columns": ["a"]}, {"heading": "x", "columns": ["b"]}]}}' 65 'current_state.tables[1].heading'
  vc "a repeated column name" '{"current_state": {"tables": [{"heading": "x", "columns": ["a", "b", "a"]}]}}' 65 'current_state.tables[0].columns[2]'
  vc "a forbid pattern that matches the empty string" '{"current_state": {"forbid_patterns": [{"id": "d", "regex": "x*"}]}}' 65 current_state.forbid_patterns[0].regex
  vc "decorations as a regex and as a list" '{"current_state": {"tables": [{"heading": "x", "columns": ["a", "b"], "enums": {"b": ["x"], "a": ["y"]}, "decorations": {"b": "[*]z[*]", "a": ["q", "(?i)r"]}}]}}' 0
  vc "decorations that is not an object" '{"current_state": {"tables": [{"heading": "x", "columns": ["a"], "enums": {"a": ["v"]}, "decorations": ["z"]}]}}' 65 current_state.tables[0].decorations
  vc "decorations for a column with no enums" '{"current_state": {"tables": [{"heading": "x", "columns": ["a", "b"], "enums": {"a": ["v"]}, "decorations": {"b": "z"}}]}}' 65 current_state.tables[0].decorations.b
  vc "decorations with no enums at all" '{"current_state": {"tables": [{"heading": "x", "columns": ["a"], "decorations": {"a": "z"}}]}}' 65 current_state.tables[0].decorations.a
  vc "decorations with a bad regex" '{"current_state": {"tables": [{"heading": "x", "columns": ["a"], "enums": {"a": ["v"]}, "decorations": {"a": "("}}]}}' 65 current_state.tables[0].decorations.a
  vc "decorations with a regex that matches the empty string" '{"current_state": {"tables": [{"heading": "x", "columns": ["a"], "enums": {"a": ["v"]}, "decorations": {"a": "z*"}}]}}' 65 current_state.tables[0].decorations.a
  vc "decorations with an empty regex" '{"current_state": {"tables": [{"heading": "x", "columns": ["a"], "enums": {"a": ["v"]}, "decorations": {"a": ""}}]}}' 65 current_state.tables[0].decorations.a
  vc "decorations with an empty list" '{"current_state": {"tables": [{"heading": "x", "columns": ["a"], "enums": {"a": ["v"]}, "decorations": {"a": []}}]}}' 65 current_state.tables[0].decorations.a
  vc "decorations list with a bad second regex" '{"current_state": {"tables": [{"heading": "x", "columns": ["a"], "enums": {"a": ["v"]}, "decorations": {"a": ["z", "["]}}]}}' 65 'current_state.tables[0].decorations.a[1]'
  vc "decorations list with an empty-matching first regex" '{"current_state": {"tables": [{"heading": "x", "columns": ["a"], "enums": {"a": ["v"]}, "decorations": {"a": ["z?", "q"]}}]}}' 65 'current_state.tables[0].decorations.a[0]'
  vc "decorations list with an empty-matching second regex" '{"current_state": {"tables": [{"heading": "x", "columns": ["a"], "enums": {"a": ["v"]}, "decorations": {"a": ["q", "z?"]}}]}}' 65 'current_state.tables[0].decorations.a[1]'
  vc "a _-key under decorations is a comment" '{"current_state": {"tables": [{"heading": "x", "columns": ["a"], "enums": {"a": ["v"]}, "decorations": {"_note": "(", "a": "z"}}]}}' 0
  vc "decorations with a number" '{"current_state": {"tables": [{"heading": "x", "columns": ["a"], "enums": {"a": ["v"]}, "decorations": {"a": 3}}]}}' 65 current_state.tables[0].decorations.a
  vc "table_own_width with table null" '{"current_state": {"table": null, "table_own_width": true}}' 0
  vc "table_own_width with the ledger preset (table null)" '{"current_state": {"table_own_width": true}}' 0
  vc "table_own_width with a table set in the file" '{"current_state": {"table": {"columns": 3}, "table_own_width": true}}' 65 current_state.table_own_width
  vc "table_own_width over the map preset, which sets a table" '{"current_state": {"template": "map", "table_own_width": true}}' 65 current_state.table_own_width
  vc "table_own_width with the map preset and table null" '{"current_state": {"template": "map", "table": null, "table_own_width": true}}' 0
  vc "table_own_width false with a table set" '{"current_state": {"table": {"columns": 3}, "table_own_width": false}}' 0
  vc "table_own_width that is not a boolean" '{"current_state": {"table_own_width": "yes"}}' 65 current_state.table_own_width
  vc "an unknown template" '{"current_state": {"template": "grid"}}' 65 current_state.template
}

# ── [J] the injection cap: with current_state.inject on, an index over 9,000 characters is red ─────────────
# mkinj <name> <characters> [tail] — the skeleton padded with plain lines to exactly <characters> UTF-16 units (the unit the hook cap
# counts), then <tail> (python string literal) appended; the size is checked by the case's instrument line
mkinj() {
  python3 - "$SK" "$T/$1" "$2" "${3:-''}" <<'PY2'
import sys
sk = open(sys.argv[1], encoding="utf-8").read()
units = lambda s: len(s.encode("utf-16-le")) // 2
tail = eval(sys.argv[4])
need = int(sys.argv[3]) - units(sk) - units(tail)
pad = ("x" * 99 + "\n") * (need // 100) + "x" * (need % 100)
open(sys.argv[2], "w", encoding="utf-8", newline="").write(sk + pad + tail)
PY2
}
units_of() { python3 -c 'import sys; print(len(open(sys.argv[1], encoding="utf-8", newline="").read().encode("utf-16-le")) // 2)' "$1"; }
fam_inject() {
  PLX=$1; T=$(fresh); mk_skeleton
  local ON OFF d R
  ON=$(mkprof inject-on 'd["current_state"]["inject"] = True')
  OFF=$(mkprof inject-off 'd["current_state"]["inject"] = False')
  mkinj i9000.md 9000; mkinj i9001.md 9001; mkinj e9001.md 9001 '"\U0001F600"'
  [ "$(units_of "$T/i9000.md")" = 9000 ] && [ "$(units_of "$T/i9001.md")" = 9001 ] && [ "$(units_of "$T/e9001.md")" = 9001 ] \
    && [ "$(python3 -c 'import sys; print(len(open(sys.argv[1], encoding="utf-8").read()))' "$T/e9001.md")" = 9000 ] \
    && ok "[J0] instrument: the planted indexes measure 9000, 9001 and 9001 units (the last 9000 code points, one outside the BMP)" \
    || bad "[J0] instrument: the planted indexes are not the size the cases need"
  shp "$ON" i9000.md 0 "[J1] 9000 characters with inject on → pass (the boundary)"
  shp "$ON" i9001.md 1 "[J2] 9001 characters with inject on → fail" size.inject_chars
  shp "$OFF" i9001.md 0 "[J3] the same 9001 characters with inject off → pass (the cap is the injection's)"
  shp "$MAP" i9001.md 0 "[J3b] …and with inject not set (the default is off) → pass"
  shp "$ON" e9001.md 1 "[J4] 9000 code points, one of them outside the BMP (2 units) → fail: counted as the hook cap counts" size.inject_chars
  dif "$ON" i9001.md "" 1 "[J5] diff gate: the index is in the diff and over the injection cap → rc 1" kb/current-state.md
  dif "$ON" i9001.md "$NSC only an internal value changed, nothing visible moved" 1 "[J5b] …an exemption never excuses it" systems/x.sh
  dif "$OFF" i9001.md "" 0 "[J5c] …with inject off the same diff passes" kb/current-state.md
  d=$(mk_gitrepo "$(cat "$ON/.vibemaestro/sdlc.json")"); cp "$T/i9001.md" "$d/kb/current-state.md"
  R=$(kbd "$d" check current-state 2>&1); eq "$?" 65 "[J6] kb.py check current-state, inject on, 9001 characters → rc 65"
  has "$R" 'with current_state.inject on' "[J6] …for the injection cap"
  cp "$T/i9000.md" "$d/kb/current-state.md"
  kbd "$d" check current-state >/dev/null 2>&1; eq "$?" 0 "[J6b] …9000 characters → rc 0"
  python3 -c 'import sys; p = sys.argv[1]; t = open(p, encoding="utf-8", newline="").read(); open(sys.argv[2], "w", encoding="utf-8", newline="").write(t.replace("\n", "\r\n"))' "$T/i9000.md" "$T/c9000.md"
  shp "$ON" c9000.md 0 "[J8] a CRLF checkout of the 9000-character index → pass (CRLF counts as LF, as CI's LF blob)"
  d=$(fresh); mkdir -p "$d/.vibemaestro"; printf '%s' '{"schema": 1, "current_state": {"inject": "yes"}}' > "$d/.vibemaestro/sdlc.json"
  R=$( cd "$TMP" && cenv python3 "$PLX/scripts/kb.py" config check --root "$d" 2>&1 ); eq "$?" 65 "[J7] inject that is not a boolean → rc 65"
  has "$R" current_state.inject "[J7] …naming current_state.inject"
}

# ── [K] kb.py ────────────────────────────────────────────────────────────────────────────────────
# mk_gitrepo <profile json or ""> — a git repo on main with a ledger and (optionally) the config at the root; prints the path
mk_gitrepo() {
  local d; d=$(fresh); git_ init -q -b main "$d"
  mkdir -p "$d/kb" "$d/systems"; cp "$SK" "$d/kb/current-state.md"; echo seed > "$d/README.md"
  if [ -n "$1" ]; then mkdir -p "$d/.vibemaestro"; printf '%s' "$1" > "$d/.vibemaestro/sdlc.json"; fi
  git_ -C "$d" add -A; git_ -C "$d" commit -q -m seed; printf '%s' "$d"
}
kbd() { local d=$1; shift; ( cd "$d" && cenv python3 "$PLX/scripts/kb.py" "$@" ); }
fam_cli() {
  PLX=$1; T=$(fresh); mk_skeleton
  local CFG R rc d
  CFG=$(cat "$SHAPED/.vibemaestro/sdlc.json")
  d=$(mk_gitrepo "$CFG")
  kbd "$d" check current-state >/dev/null 2>&1; eq "$?" 0 "[K1] check current-state with the repo's profile on its good ledger → rc 0"
  printf '%s\n' "$(python3 -c "print('y' * 401)")" >> "$d/kb/current-state.md"
  R=$(kbd "$d" check current-state 2>&1); rc=$?
  eq "$rc" 65 "[K2] …a line over the profile's 400 characters → rc 65"
  d=$(mk_gitrepo "")
  printf '%s\n' "$(python3 -c "print('y' * 250)")" >> "$d/kb/current-state.md"
  kbd "$d" check current-state >/dev/null 2>&1; eq "$?" 65 "[K3] no config: the ledger preset caps a line at 200 → rc 65"
  d=$(mk_gitrepo "$CFG"); printf '%s\n' "$(python3 -c "print('y' * 250)")" >> "$d/kb/current-state.md"
  kbd "$d" check current-state >/dev/null 2>&1; eq "$?" 0 "[K4] the same 250-character line under the map profile (cap 400) → rc 0"
  # the diff gate
  d=$(mk_gitrepo "$CFG"); git_ -C "$d" checkout -q -b feat/x
  echo x > "$d/systems/a.sh"; git_ -C "$d" add -A; git_ -C "$d" commit -q -m "watched change"
  : > "$T/body-empty.txt"; printf '%s only an internal value changed, nothing visible moved\n' "$NSC" > "$T/body-ex.txt"
  kbd "$d" check current-state --diff main...HEAD --body-file "$T/body-empty.txt" >/dev/null 2>&1; eq "$?" 65 "[K5] --diff: a watched path, no ledger change, no exemption → rc 65"
  kbd "$d" check current-state --diff main...HEAD --body-file "$T/body-ex.txt" >/dev/null 2>&1; eq "$?" 0 "[K6] --diff: …with an exemption line in the body file → rc 0"
  echo "more" >> "$d/kb/current-state.md"; git_ -C "$d" add -A; git_ -C "$d" commit -q -m "ledger"
  kbd "$d" check current-state --diff main...HEAD --body-file "$T/body-empty.txt" >/dev/null 2>&1; eq "$?" 0 "[K7] --diff: …with the ledger changed on the branch → rc 0"
  kbd "$d" check current-state --diff main...no-such-ref --body-file "$T/body-empty.txt" >/dev/null 2>&1; eq "$?" 65 "[K8] --diff: a range that cannot be resolved does not conclude → rc 65"
  kbd "$d" check current-state --diff main...HEAD --body-file "$T/nope.txt" >/dev/null 2>&1; eq "$?" 66 "[K9] --diff: an unreadable body file → rc 66"
  kbd "$d" check current-state --diff main...HEAD >/dev/null 2>&1; eq "$?" 64 "[K10] --diff without --body-file → rc 64 (usage)"
  kbd "$d" check current-state --body-file "$T/body-empty.txt" >/dev/null 2>&1; eq "$?" 64 "[K11] --body-file without --diff → rc 64 (usage)"
  # a repo with no config: nothing is watched
  d=$(mk_gitrepo ""); git_ -C "$d" checkout -q -b feat/x; echo x > "$d/systems/a.sh"; git_ -C "$d" add -A; git_ -C "$d" commit -q -m c
  kbd "$d" check current-state --diff main...HEAD --body-file "$T/body-empty.txt" >/dev/null 2>&1; eq "$?" 0 "[K12] --diff in a repo with no config: watch [] → the gate does not apply → rc 0"
  # the trust rule: the profile of the BASE ref judges, so a PR cannot relax its own gate
  d=$(mk_gitrepo "$CFG"); git_ -C "$d" checkout -q -b feat/relax
  python3 - "$d/.vibemaestro/sdlc.json" <<'PY'
import json, sys
p = sys.argv[1]; c = json.load(open(p, encoding="utf-8")); c["current_state"]["watch"] = []; json.dump(c, open(p, "w", encoding="utf-8"))
PY
  echo x > "$d/systems/a.sh"; git_ -C "$d" add -A; git_ -C "$d" commit -q -m "relax the gate and change a watched path"
  kbd "$d" check current-state --diff main...HEAD --body-file "$T/body-empty.txt" >/dev/null 2>&1; eq "$?" 0 "[K13] the working tree's config is read by default: the relaxed profile lets the change through (a local command)"
  kbd "$d" check current-state --diff main...HEAD --body-file "$T/body-empty.txt" --config-ref main >/dev/null 2>&1; eq "$?" 65 "[K14] --config-ref main: the base profile judges → the PR cannot relax its own gate → rc 65"
  d=$(mk_gitrepo ""); git_ -C "$d" checkout -q -b feat/adopt; mkdir -p "$d/.vibemaestro"; printf '%s' "$CFG" > "$d/.vibemaestro/sdlc.json"
  echo x > "$d/systems/a.sh"; git_ -C "$d" add -A; git_ -C "$d" commit -q -m "add the config and change a watched path"
  kbd "$d" check current-state --diff main...HEAD --body-file "$T/body-empty.txt" --config-ref main >/dev/null 2>&1; eq "$?" 0 "[K15] --config-ref main where the base has no config: the defaults judge (nothing watched) → rc 0"
  d=$(mk_gitrepo "{\"schema\": 1, \"current_state\": {\"watch\": [\"systems/\"], \"gate\": \"external:scripts/gate.py\"}}"); mkdir -p "$d/scripts"
  printf 'def decide(paths, body):\n    return 1, "base script says no"\n' > "$d/scripts/gate.py"; git_ -C "$d" add -A; git_ -C "$d" commit -q -m "gate"
  git_ -C "$d" checkout -q -b feat/swap; printf 'def decide(paths, body):\n    return 0, "head script says yes"\n' > "$d/scripts/gate.py"
  echo x > "$d/systems/a.sh"; git_ -C "$d" add -A; git_ -C "$d" commit -q -m "swap the script"
  kbd "$d" check current-state --diff main...HEAD --body-file "$T/body-empty.txt" >/dev/null 2>&1; eq "$?" 0 "[K16] an external gate runs the working tree's script by default → the PR's own script passes it"
  kbd "$d" check current-state --diff main...HEAD --body-file "$T/body-empty.txt" --config-ref main >/dev/null 2>&1; eq "$?" 65 "[K17] --config-ref main: the BASE ref's script runs → the swapped script does not rescue the PR → rc 65"
  d=$(mk_gitrepo "{\"schema\": 1, \"current_state\": {\"watch\": [\"systems/\"], \"gate\": \"off\"}}"); git_ -C "$d" checkout -q -b feat/x; echo x > "$d/systems/a.sh"; git_ -C "$d" add -A; git_ -C "$d" commit -q -m c
  kbd "$d" check current-state --diff main...HEAD --body-file "$T/body-empty.txt" >/dev/null 2>&1; eq "$?" 0 "[K18] gate off: a watched change with no ledger change → rc 0"
  d=$(mk_gitrepo "{\"schema\": 1, \"current_state\": {\"watch\": [\"systems/\"], \"gate\": \"external:scripts/missing.py\"}}"); git_ -C "$d" checkout -q -b feat/x; echo x > "$d/systems/a.sh"; git_ -C "$d" add -A; git_ -C "$d" commit -q -m c
  kbd "$d" check current-state --diff main...HEAD --body-file "$T/body-empty.txt" >/dev/null 2>&1; eq "$?" 65 "[K19] an external gate whose script does not exist is a block, not a pass → rc 65"
  d=$(mk_gitrepo '{"schema": 1, "current_state": {"watch": ["systems/"], "inject": "yes"}}'); git_ -C "$d" checkout -q -b feat/x
  kbd "$d" check current-state --diff main...HEAD --body-file "$T/body-empty.txt" >/dev/null 2>&1; eq "$?" 65 "[K20] an invalid config makes the diff gate exit 65 (it does not fall back to defaults)"
  # an invalid config at the BASE ref (the working tree's config is valid, so only the ref read can notice)
  d=$(mk_gitrepo '{"schema": 1, "current_state": {"watch": ["systems/"], "inject": "yes"}}'); git_ -C "$d" checkout -q -b feat/fix
  printf '%s' '{"schema": 1, "current_state": {"watch": ["systems/"]}}' > "$d/.vibemaestro/sdlc.json"; echo x > "$d/systems/a.sh"; git_ -C "$d" add -A; git_ -C "$d" commit -q -m "fix the config"
  kbd "$d" check current-state --diff main...HEAD --body-file "$T/body-empty.txt" >/dev/null 2>&1; eq "$?" 65 "[K21] working-tree config valid, a watched change, no ledger change → rc 65 (the control of [K22])"
  kbd "$d" check current-state --diff main...HEAD --body-file "$T/body-ex.txt" --config-ref main >/dev/null 2>&1; eq "$?" 65 "[K22] --config-ref: an invalid config at the ref → rc 65, not a fall back to defaults that would let the PR through"
  kbd "$d" check current-state --diff main...HEAD --body-file "$T/body-ex.txt" --config-ref no-such-ref >/dev/null 2>&1; eq "$?" 65 "[K23] --config-ref that does not resolve to a commit → rc 65 (a typo must not turn the gate off)"
  # a file moved out of a watched prefix still counts as a change under it
  d=$(mk_gitrepo "{\"schema\": 1, \"current_state\": {\"watch\": [\"systems/\"]}}"); echo "content of a file long enough to be a rename" > "$d/systems/a.sh"; git_ -C "$d" add -A; git_ -C "$d" commit -q -m "add"
  git_ -C "$d" checkout -q -b feat/mv; git_ -C "$d" checkout -q main; git_ -C "$d" branch -f base-main main; git_ -C "$d" checkout -q feat/mv
  mkdir -p "$d/elsewhere"; git_ -C "$d" mv systems/a.sh elsewhere/a.sh; git_ -C "$d" commit -q -m "move out of the watched prefix"
  kbd "$d" check current-state --diff base-main...HEAD --body-file "$T/body-empty.txt" >/dev/null 2>&1; eq "$?" 65 "[K24] a file moved out of a watched prefix is a change under it (no rename detection) → rc 65"
  # an external gate under --config-ref: a script that finds the ledger relative to itself, and a script that crashes
  d=$(mk_gitrepo "{\"schema\": 1, \"current_state\": {\"watch\": [\"systems/\"], \"gate\": \"external:scripts/gate.py\"}}"); mkdir -p "$d/scripts"
  printf 'import os\nROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))\n\ndef decide(paths, body):\n    return (0, "ledger found") if os.path.isfile(os.path.join(ROOT, "kb", "current-state.md")) else (1, "no ledger beside the script")\n' > "$d/scripts/gate.py"
  git_ -C "$d" add -A; git_ -C "$d" commit -q -m gate; git_ -C "$d" checkout -q -b feat/x; echo x > "$d/systems/a.sh"; git_ -C "$d" add -A; git_ -C "$d" commit -q -m c
  kbd "$d" check current-state --diff main...HEAD --body-file "$T/body-empty.txt" --config-ref main >/dev/null 2>&1; eq "$?" 0 "[K25] --config-ref with an external script that locates the ledger from its own path: the checkout's ledger is beside the extracted script → rc 0"
  d=$(mk_gitrepo "{\"schema\": 1, \"current_state\": {\"watch\": [\"systems/\"], \"gate\": \"external:scripts/gate.py\"}}"); mkdir -p "$d/scripts"
  printf 'def decide(paths, body):\n    raise RuntimeError("boom")\n' > "$d/scripts/gate.py"
  git_ -C "$d" add -A; git_ -C "$d" commit -q -m gate; git_ -C "$d" checkout -q -b feat/x; echo x > "$d/systems/a.sh"; git_ -C "$d" add -A; git_ -C "$d" commit -q -m c
  kbd "$d" check current-state --diff main...HEAD --body-file "$T/body-empty.txt" >/dev/null 2>&1; eq "$?" 65 "[K26] an external script that raises is a block (rc 65), not a traceback"
}

# ── [P] open_pr.py ───────────────────────────────────────────────────────────────────────────────
fam_pr() {
  PLX=$1; T=$(fresh); mk_skeleton
  local CFG out rc
  mk_pr_repo
  # builtin: the repo's profile is read from the tree the core runs in
  put_pr_cfg() { mkdir -p "$PT/.vibemaestro"; printf '%s' "$1" > "$PT/.vibemaestro/sdlc.json"; git_ -C "$PT" add -A; git_ -C "$PT" commit -q -m "cfg"; }
  mkdir -p "$PT/systems" "$PT/kb"; printf '# State\n\nCurrent and short.\n' > "$PT/kb/current-state.md"
  put_pr_cfg '{"schema": 1, "current_state": {"watch": ["systems/"]}}'
  git_ -C "$PT" branch gbase                                              # the config and the ledger are part of the base
  commit_in "$PT" systems/a.sh a "a watched change"
  out=$(prd --base gbase 2>&1 >/dev/null); rc=$?
  eq "$rc" 4 "[P1] gate builtin, a watched change, no ledger change, no exemption: rc 4"
  printf 'A real summary line.\n\n%s only an internal value changed, nothing visible moved\n' "$NSC" > "$F/sum-ex.md"
  prd --base gbase --summary-file "$F/sum-ex.md" >/dev/null 2>&1; eq "$?" 0 "[P2] …with the default exemption token in the summary → rc 0"
  printf 'A real summary line.\n\n%s too short\n' "$NSC" > "$F/sum-short.md"
  prd --base gbase --summary-file "$F/sum-short.md" >/dev/null 2>&1; eq "$?" 0 "[P3] …a short reason is enough under the default (exempt.min_reason_chars 0)"
  put_pr_cfg '{"schema": 1, "current_state": {"watch": ["systems/"], "exempt": {"min_reason_chars": 15}}}'
  prd --base gbase --summary-file "$F/sum-short.md" >/dev/null 2>&1; eq "$?" 4 "[P4] exempt.min_reason_chars 15 is read by the core: the short reason → rc 4"
  commit_in "$PT" kb/current-state.md "# State

Current and short, with more in it." "ledger updated"
  prd --base gbase >/dev/null 2>&1; eq "$?" 0 "[P5] the ledger changed on the branch and is within the template → rc 0"
  python3 -c "print('y' * 201)" >> "$PT/kb/current-state.md"; git_ -C "$PT" add -A; git_ -C "$PT" commit -q -m "bad ledger"
  prd --base gbase >/dev/null 2>&1; eq "$?" 4 "[P6] …a ledger line over the ledger preset's 200 characters → rc 4"
  put_pr_cfg '{"schema": 1, "current_state": {"watch": ["systems/"], "gate": "off"}}'
  prd --base gbase >/dev/null 2>&1; eq "$?" 0 "[P7] gate off → rc 0 whatever the diff and the ledger"
  put_pr_cfg '{"schema": 1, "current_state": {"watch": ["systems/"], "gate": "external:scripts/gate.py"}}'
  mkdir -p "$PT/scripts"; printf 'def decide(paths, body):\n    return 1, "external says no"\n' > "$PT/scripts/gate.py"; git_ -C "$PT" add -A; git_ -C "$PT" commit -q -m "script"
  prd --base gbase >/dev/null 2>&1; eq "$?" 4 "[P8] gate external:<path>: the repo script's answer decides → rc 4"
  printf 'def decide(paths, body):\n    return 0, "external says yes"\n' > "$PT/scripts/gate.py"; git_ -C "$PT" add -A; git_ -C "$PT" commit -q -m "script yes"
  prd --base gbase >/dev/null 2>&1; eq "$?" 0 "[P9] …and a passing script → rc 0"
  put_pr_cfg '{"schema": 1, "current_state": {"watch": ["systems/"], "gate": "external:scripts/gone.py"}}'
  prd --base gbase >/dev/null 2>&1; eq "$?" 4 "[P10] an external gate whose script is missing blocks (rc 4), it does not pass"
  put_pr_cfg '{"schema": 1, "current_state": {"watch": []}}'
  prd --base no-such-base >/dev/null 2>&1; eq "$?" 0 "[P11] watch [] and an unresolvable base: the gate does not apply and asks git nothing → rc 0"
  put_pr_cfg '{"schema": 1, "current_state": {"watch": ["systems/"]}}'
  prd --base no-such-base >/dev/null 2>&1; eq "$?" 4 "[P12] a watch list and a base that cannot be resolved does not conclude → rc 4"
  # no config file at all, and the legacy repo script
  mk_pr_repo; mkdir -p "$PT/systems"
  commit_in "$PT" systems/a.sh a "a watched change"
  prd --base main >/dev/null 2>&1; eq "$?" 0 "[P13] no config and no script: the gate does not apply → rc 0"
  mkdir -p "$PT/scripts"; printf 'def decide(paths, body):\n    return 1, "legacy script says no"\n' > "$PT/scripts/check-current-state.py"; git_ -C "$PT" add -A; git_ -C "$PT" commit -q -m "legacy script"
  prd --base main >/dev/null 2>&1; eq "$?" 4 "[P14] no config file but scripts/check-current-state.py: the script still decides (today's behaviour) → rc 4"
  put_pr_cfg '{"schema": 1}'
  out=$(prd --base main 2>&1 >/dev/null); rc=$?
  eq "$rc" 0 "[P15] a config file that does not name the script: the builtin gate watches nothing → rc 0"
  has "$out" "scripts/check-current-state.py" "[P16] …and the core says on stderr that the legacy script is not run, naming it, so the repo can choose gate external"
  put_pr_cfg '{"schema": 1, "current_state": {"watch": ["systems/"]}}'
  git_ -C "$PT" branch -f mvbase                                          # systems/a.sh exists on the base
  mkdir -p "$PT/renamed"; git_ -C "$PT" mv systems/a.sh renamed/a.sh; git_ -C "$PT" commit -q -m "move out of the watched prefix"
  prd --base mvbase >/dev/null 2>&1; eq "$?" 4 "[P17] a file moved out of a watched prefix is a change under it (no rename detection) → rc 4"
}

# ── [N] dated labels: the date of a `current_state.labels` label is not a history sign; the gate never blocks on one ──
LBL='\\*chưa kiểm(?: từ (?P<date>[^*]*))?\\*'
# lroot <current_state json> — a profile root with that current_state object; prints the path
lroot() { local d; d=$(fresh); mkdir -p "$d/.vibemaestro"; printf '{"schema": 1, "current_state": %s}' "$1" > "$d/.vibemaestro/sdlc.json"; printf '%s' "$d"; }
lab() { lroot "{\"labels\": {\"regex\": \"${1:-$LBL}\", \"max_age_days\": 7}}"; }
# lsh <profile root> <ledger text> <want rc> <label> [class] — the shape check of that ledger
lsh() { printf '%s' "$2" > "$T/lab.md"; local R; R=$(gr "$1" shape "$T/lab.md")
  if [ "$(rcof "$R")" != "$3" ]; then bad "$4 (want rc $3, got: ${R//$'\n'/ })"
  elif [ -n "${5:-}" ]; then has "$R" "|$5" "$4 → rc $3 ($5)"; else ok "$4 → rc $3"; fi; }
fam_labels() {
  PLX=$1; T=$(fresh)
  local d R rc old
  old=$(python3 -c "import datetime; print(datetime.date.today() - datetime.timedelta(days=30))")
  lsh "$(lab)" "$(printf '# State\n\nA runs *chưa kiểm từ 2026-10-12*.\n')" 0 "[N1] labels set: the date of a dated label is not a history sign"
  lsh "$(lroot '{}')" "$(printf '# State\n\nA runs *chưa kiểm từ 2026-10-12*.\n')" 1 "[N2] no labels key: the same line is history, as today" "history.date_iso"
  lsh "$(lroot '{"labels": null}')" "$(printf '# State\n\nA runs *chưa kiểm từ 2026-10-12*.\n')" 1 "[N2b] labels null: the same" "history.date_iso"
  lsh "$(lab)" "$(printf '# State\n\nA runs *chưa kiểm từ 2026-10-12*, measured 2026-10-01.\n')" 1 "[N3] a second date on the label's line is history" "history.date_iso"
  lsh "$(lab '\\*chưa kiểm(?: từ (?P<date>[0-9-]+))?[^*]*\\*')" "$(printf '# State\n\nA runs *chưa kiểm từ 2026-10-12, fixed in #45*.\n')" 1 \
    "[N3b] a history sign inside the label but outside its date group is history" "history.pr_ref"
  lsh "$(lab '\\*x(?P<date>[^*]*)\\*')" "$(printf '# State\n\nA runs *x2026-10-12 #45*.\n')" 1 \
    "[N4] a date group wider than YYYY-MM-DD exempts nothing (it would hide #45)" "history.pr_ref"
  # a runaway regex: the timer cuts the scan and no date is exempted, so a dated label is judged as any date
  lsh "$(lab '(x+x+)+y (?P<date>[0-9-]*)')" "$(printf '# State\n\nA xxy 2026-10-12 runs.\n%s\n' "$(python3 -c "print('x' * 40)")")" 1 \
    "[N6] a regex that ran over its timer exempts no date" "history.date_iso"
  lsh "$(lab '(x+x+)+y (?P<date>[0-9-]*)')" "$(printf '# State\n\nA xxy 2026-10-12 runs.\n')" 0 "[N6b] control: the same regex and label without the runaway line exempt the date"
  # the diff gate passes with an old label and carries its WARNING
  d=$(mk_gitrepo "{\"schema\": 1, \"current_state\": {\"watch\": [\"systems/\"], \"labels\": {\"regex\": \"$LBL\", \"max_age_days\": 7}}}")
  git_ -C "$d" checkout -q -b feat/x; printf '# State\n\nA runs *chưa kiểm từ %s*. B runs *chưa kiểm*.\n' "$old" > "$d/kb/current-state.md"
  echo x > "$d/systems/a.sh"; git_ -C "$d" add -A; git_ -C "$d" commit -q -m "watched change and ledger"; : > "$T/body-empty.txt"
  R=$(kbd "$d" check current-state --diff main...HEAD --body-file "$T/body-empty.txt" 2>&1); rc=$?
  eq "$rc" 0 "[N7] the diff gate passes with an old and an undated label (warning only)"
  has "$R" "WARNING kb/current-state.md:3: label '*chưa kiểm từ $old*' is 30 days old (over 7)" "[N7b] …and carries the old label's WARNING"
  has "$R" "label '*chưa kiểm*' has no valid date" "[N7c] …and the undated label's"
  # the config check
  vcl() {  # vcl <label> <labels json> <want rc> [words the message must hold]
    local d R; d=$(fresh); mkdir -p "$d/.vibemaestro"; printf '{"schema": 1, "current_state": {"labels": %s}}' "$2" > "$d/.vibemaestro/sdlc.json"
    R=$( cd "$TMP" && cenv python3 "$PLX/scripts/kb.py" config check --root "$d" 2>&1 ); eq "$?" "$3" "[N8] $1: rc $3"
    [ "$3" = 0 ] || has "$R" "current_state.labels${4:+.regex: }${4:-}" "[N8] $1: names current_state.labels${4:+ and says: $4}"
  }
  vcl "the hub's regex and N = 7" "{\"regex\": \"$LBL\", \"max_age_days\": 7}" 0
  vcl "a regex with no named group date" '{"regex": "\\*chưa kiểm( từ [0-9-]+)?\\*", "max_age_days": 7}' 65
  vcl "a regex that matches the empty string" '{"regex": "(?P<date>x)?", "max_age_days": 7}' 65 "matches the empty string"
  vcl "a regex that matches a bare date" '{"regex": "(?P<date>[0-9]{4}-[0-9]{2}-[0-9]{2})", "max_age_days": 7}' 65
  vcl "a regex that does not compile" '{"regex": "(?P<date>", "max_age_days": 7}' 65
  vcl "no max_age_days" "{\"regex\": \"$LBL\"}" 65
  vcl "a negative max_age_days" "{\"regex\": \"$LBL\", \"max_age_days\": -1}" 65
  vcl "an unknown key (a warning)" "{\"regex\": \"$LBL\", \"max_age_days\": 7, \"days\": 3}" 0
  local t0; t0=$(date +%s)
  vcl "a regex that backtracks on the probe" '{"regex": "(?P<date>(?:\\w|\\d|[0-9]|.|\\S)+)+#", "max_age_days": 7}' 65 "runs over 1 s"
  [ $(( $(date +%s) - t0 )) -lt 10 ] && ok "[N8] …and the config check returns in under 10 s" || bad "[N8] …and the config check returns in under 10 s (took $(( $(date +%s) - t0 ))s)"
  # a lookbehind gets a bare date past the config check: a match with no marker outside its date group is not a label
  lsh "$(lab '(?<= )(?P<date>[0-9]{4}-[0-9]{2}-[0-9]{2})')" "$(printf '# State\n\nMeasured 2026-10-18, done.\n')" 1 \
    "[N9] a lookaround around a bare date makes no label: the date stays history" "history.date_iso"
  lsh "$(lab '[ ,](?P<date>[0-9]{4}-[0-9]{2}-[0-9]{2})')" "$(printf '# State\n\nMeasured 2026-10-18, done.\n')" 1 \
    "[N9b] a blank or a comma is no marker word: the date stays history" "history.date_iso"
  # sdlc_config.py is vendored ALONE into a repo's gates (install_gates.py): with labels set it must still load there
  d=$(fresh); cp "$PLX/scripts/sdlc_config.py" "$d/"; mkdir -p "$d/r/.vibemaestro"
  printf '{"schema": 1, "current_state": {"labels": {"regex": "%s", "max_age_days": 7}}}' "$LBL" > "$d/r/.vibemaestro/sdlc.json"
  R=$(cd "$d" && python3 -I -B -c 'import sys; sys.path.insert(0, "."); import sdlc_config as C; print(C.load("r")[1])' 2>&1)
  eq "$R" "[]" "[N11] sdlc_config.py alone (as vendored into gates) loads a config with labels"
}

# ── [G] pages: the ledger as an index plus kb/state pages ─────────────────────────────────
# pg_root [config json] — a fresh ledger root: the config, an index that points to two pages, the two pages (a with an
# applyTo); prints the path. A git repository, so kb.py and the hook find their root as in a real checkout.
PGC='{"schema": 1, "current_state": {"watch": ["systems/"], "watch_exclude": ["systems/tests/"], "pages": "kb/state/*.md"}}'
pg_root() {
  local d; d=$(fresh); mkdir -p "$d/.vibemaestro" "$d/kb/state"; git_ init -q -b main "$d"
  printf '%s' "${1:-$PGC}" > "$d/.vibemaestro/sdlc.json"
  printf '# State\n\nThe app runs: kb/state/a.md. The store is up: kb/state/b.md.\n' > "$d/kb/current-state.md"
  printf -- '---\napplyTo: "src/app/**"\n---\n# App\n\nIt runs.\n' > "$d/kb/state/a.md"
  printf '# Store\n\nIt is up.\n' > "$d/kb/state/b.md"
  printf '%s' "$d"
}
# lgv <root> <want rc> <label> [file|line|class] — the whole-ledger check; for rc 1 the problem must be listed
lgv() {
  local R; R=$(gr "$1" ledger)
  if [ "$(rcof "$R")" != "$2" ]; then bad "$3 (want rc $2, got: ${R//$'\n'/ })"
  elif [ -n "${4:-}" ]; then has "$R" "$4" "$3 → rc $2 ($4)"
  else ok "$3 → rc $2"; fi
}
# pdif <root> <want rc> <label> paths... — the diff gate with the index and the pages read under <root>, no body
pdif() { local r=$1 want=$2 lab=$3; shift 3; : > "$T/body.txt"; eq "$(rcof "$(gr "$r" diff - "$T/body.txt" "$@")")" "$want" "$lab"; }
fam_pages() {
  PLX=$1; T=$(fresh)
  local d R rc
  d=$(pg_root); lgv "$d" 0 "[G1] an index that points to both pages, both under the page cap"
  # the page cap is the page's own: 8000 bytes, 400 characters a line, no line cap (the index cap of the ledger preset is 12000/200/120)
  d=$(pg_root); python3 -c "import sys; sys.stdout.write('# A\n' + ('x' * 399 + '\n') * 19 + 'x' * 395 + '\n')" > "$d/kb/state/a.md"
  [ "$(wc -c < "$d/kb/state/a.md" | tr -d ' ')" = 8000 ] && ok "[G2a] instrument: the page measures exactly 8000 bytes" || bad "[G2a] instrument: the page is not 8000 bytes"
  python3 -c "print('# B'); print('k' * 300); [print('x' * 40) for _ in range(150)]" > "$d/kb/state/b.md"
  lgv "$d" 0 "[G2b] a page of exactly 8000 bytes and one of 152 lines with a 300-character line pass the page cap"
  printf 'y' >> "$d/kb/state/a.md"; lgv "$d" 1 "[G2] a page of 8001 bytes is over its cap (the index's 12000 does not apply)" 'kb/state/a.md|0|size.bytes'
  d=$(pg_root); python3 -c "print('# A'); print('é' * 400)" > "$d/kb/state/a.md"; lgv "$d" 0 "[G3b] a line of 400 characters (800 bytes) passes"
  python3 -c "print('# A'); print('é' * 401)" > "$d/kb/state/a.md"; lgv "$d" 1 "[G3] a line of 401 characters is over the page's line cap" 'kb/state/a.md|2|size.line_chars'
  d=$(pg_root '{"schema": 1, "current_state": {"watch": ["systems/"], "pages": "kb/state/*.md", "page_limits": {"lines": 6}}}')
  lgv "$d" 0 "[G4b] page_limits.lines 6: a page of 6 lines passes"
  printf 'one more\n' >> "$d/kb/state/a.md"; lgv "$d" 1 "[G4] …a page of 7 lines is over it" 'kb/state/a.md|0|size.lines'
  # orphans: the index is the only way in
  d=$(pg_root); printf '# C\n' > "$d/kb/state/c.md"; lgv "$d" 1 "[G6] a page the index does not point to is an orphan" 'kb/state/c.md|0|pages.orphan'
  printf '\nThe cache: kb/state/c.md.\n' >> "$d/kb/state/a.md"; lgv "$d" 1 "[G7] …a pointer from another page does not adopt it" 'kb/state/c.md|0|pages.orphan'
  # dead pointers, and pointers that look alive
  d=$(pg_root); printf 'The queue: kb/state/gone.md.\n' >> "$d/kb/current-state.md"; lgv "$d" 1 "[G8] a pointer to a missing page is dead" 'kb/current-state.md|4|pages.dead_pointer'
  d=$(pg_root); printf 'notes\n' > "$d/kb/state/notes.txt"; printf 'Notes: kb/state/notes.txt\n' >> "$d/kb/current-state.md"
  lgv "$d" 1 "[G9] a pointer into the pages directory at an existing file the glob does not match is dead" 'kb/current-state.md|4|pages.dead_pointer'
  d=$(pg_root); mkdir "$d/kb/state/sub.md"; printf 'Sub: kb/state/sub.md\n' >> "$d/kb/current-state.md"
  R=$(gr "$d" ledger); has "$R" 'kb/state/sub.md|0|pages.not_file' "[G10] a directory the glob matches is not a page"
  has "$R" 'kb/current-state.md|4|pages.dead_pointer' "[G10b] …and a pointer to it is dead"
  d=$(pg_root); printf '# Far\n' > "$d/far.md"; ln -s ../../far.md "$d/kb/state/c.md"; printf 'C: kb/state/c.md\n' >> "$d/kb/current-state.md"
  lgv "$d" 1 "[G11] a symlink the glob matches is not a page (its content would escape the page cap's reading)" 'kb/state/c.md|0|pages.not_file'
  d=$(pg_root); printf '# State\n\nThe app runs: [app](state/a.md). The store: [store](./state/b.md#up).\n' > "$d/kb/current-state.md"
  lgv "$d" 0 "[G12] Markdown links relative to the index count as pointers (no orphan)"
  d=$(pg_root); printf '# State\n\nThe app: kb/state/a.md#runs. The store: kb/state/b.md.\n' > "$d/kb/current-state.md"
  lgv "$d" 0 "[G13] a pointer with an #anchor names the page"
  d=$(pg_root); printf '\nSee [the queue](gone.md).\n' >> "$d/kb/state/b.md"; lgv "$d" 1 "[G14] a relative link from a page to a missing page is dead" 'kb/state/b.md|5|pages.dead_pointer'
  d=$(pg_root); printf '\nFixed in #123 last week.\n' >> "$d/kb/state/b.md"; lgv "$d" 1 "[G15] a page carries the index's history signs" 'kb/state/b.md|5|history.pr_ref'
  d=$(pg_root); printf '\n| a | b | c |\n|---|---|\n| 1 |\n' >> "$d/kb/state/b.md"; lgv "$d" 0 "[G16] a page is not held to the index's table checks"
  d=$(pg_root); printf 'Pages live in kb/state/ as kb/state/*.md, one per area (kb/state/<area>.md).\n' >> "$d/kb/current-state.md"
  lgv "$d" 0 "[G17] a mention of the pages directory or of its glob names no page and is not a pointer"
  # no pages: exactly today's results, whatever kb/state holds
  d=$(pg_root '{"schema": 1, "current_state": {"watch": ["systems/"]}}'); printf '# C\n' > "$d/kb/state/c.md"; printf 'Q: kb/state/gone.md\n' >> "$d/kb/current-state.md"
  printf '\n%s\n' "$(python3 -c "print('y' * 250)")" >> "$d/kb/state/b.md"
  lgv "$d" 0 "[G18] pages unset: an orphan, a dead pointer and an oversized file in kb/state are not looked at"
  R=$(gr "$d" shape "$d/kb/current-state.md"); eq "$(rcof "$R")" 0 "[G18b] …and the index alone passes the shape check as today"
  pdif "$d" 1 "[G27] pages unset: a kb/state file in the diff is not the ledger, so a watched change is still blocked" systems/x.sh kb/state/b.md
  # the diff gate
  d=$(pg_root)
  pdif "$d" 1 "[G21] a watched path with no ledger file in the diff → rc 1" systems/x.sh
  pdif "$d" 0 "[G20] a watched path with only a page in the diff → rc 0" systems/x.sh kb/state/b.md
  pdif "$d" 0 "[G20b] …any page counts, not one named page" systems/x.sh kb/state/a.md
  pdif "$d" 1 "[G22] a non-page file of the pages directory in the diff is not the ledger" systems/x.sh kb/state/notes.txt
  pdif "$d" 0 "[G23] a path under watch_exclude forces no ledger edit" systems/tests/t.sh
  pdif "$d" 1 "[G24] a sibling that only starts like the excluded prefix is still watched" systems/testsx/t.sh
  pdif "$d" 1 "[G25] an excluded path next to a watched one: the watched one still needs the ledger" systems/tests/t.sh systems/a.sh
  pdif "$d" 1 "[G25b] the exclusion is anchored at the start of the path" systems/app/systems/tests/x.sh
  printf '# C\n' > "$d/kb/state/c.md"
  pdif "$d" 1 "[G26] a page in the diff does not wave through a ledger with an orphan page" systems/x.sh kb/state/b.md
  pdif "$d" 1 "[G28] a page alone in the diff makes the gate apply: the orphan blocks" kb/state/b.md
  # kb.py check current-state
  d=$(pg_root); git_ -C "$d" add -A; git_ -C "$d" commit -q -m seed
  kbd "$d" check current-state >/dev/null 2>&1; eq "$?" 0 "[G30b] kb.py check current-state on a good ledger with pages → rc 0"
  printf '# C\n' > "$d/kb/state/c.md"; R=$(kbd "$d" check current-state 2>&1); rc=$?
  eq "$rc" 65 "[G30] …an orphan page → rc 65"; has "$R" "kb/state/c.md" "[G30c] …naming the page"
  rm "$d/kb/state/c.md"; python3 -c "import sys; sys.stdout.write(('x' * 179 + '\n') * 50)" > "$d/kb/state/a.md"   # 9000 bytes, short lines
  kbd "$d" check current-state kb/state/a.md >/dev/null 2>&1; eq "$?" 65 "[G31] a page named as the file is judged by the page cap (9000 > 8000)"
  kbd "$d" check current-state kb/current-state.md >/dev/null 2>&1; eq "$?" 0 "[G31b] the index named as the file is judged alone, as today"
  ln -s "$d" "$T/via-link"
  kbd "$d" check current-state "$T/via-link/kb/state/a.md" >/dev/null 2>&1; eq "$?" 65 "[G32] …and so is the same page named through a symlinked directory (its real path is the page)"
  python3 -c "import sys; sys.stdout.write(('x' * 179 + '\n') * 50)" > "$T/outside.md"; ln -s "$T/outside.md" "$d/kb/state/o.md"
  kbd "$d" check current-state kb/state/o.md >/dev/null 2>&1; eq "$?" 65 "[G32b] …and a page that is itself a symlink to a file outside the repo keeps its page name (page cap)"
  # pointer forms (round 1): a root-absolute link, an angle-bracket link with a space, an NFD name on disk
  d=$(pg_root); printf '# State\n\nThe app: [app](/kb/state/a.md). The store: [store](/kb/state/b.md).\n' > "$d/kb/current-state.md"
  lgv "$d" 0 "[G33] a root-absolute link (/kb/state/a.md, from the repo root as on GitHub) is a pointer"
  printf 'Q: [q](/kb/state/gone.md)\n' >> "$d/kb/current-state.md"; lgv "$d" 1 "[G33b] …and a dead one is dead" 'kb/current-state.md|4|pages.dead_pointer'
  d=$(pg_root); printf '# My\n' > "$d/kb/state/my page.md"; printf 'Mine: [m](<state/my page.md>)\n' >> "$d/kb/current-state.md"
  lgv "$d" 0 "[G34] an angle-bracket link keeps its space (no dead half, no orphan)"
  d=$(pg_root); python3 -c "import sys,unicodedata; n=unicodedata.normalize('NFD','h\u1ea1.md'); open(sys.argv[1]+'/kb/state/'+n,'w').write('# H\\n'); open(sys.argv[1]+'/kb/current-state.md','a').write('H: kb/state/'+n+'\\n')" "$d"
  lgv "$d" 0 "[G35] a page named in NFD on disk and in the index is neither an orphan nor dead"
  d=$(pg_root); mkdir -p "$d/elsewhere"; mv "$d/kb/state/a.md" "$d/kb/state/b.md" "$d/elsewhere/"; rmdir "$d/kb/state"; ln -s ../elsewhere "$d/kb/state"
  lgv "$d" 1 "[G36] a pages directory that is a symlink is refused (pages are read from the tree only)" 'kb/state|0|pages.not_file'
  # pages unset: the gate's words are today's
  d=$(pg_root '{"schema": 1, "current_state": {"watch": ["systems/"]}}'); : > "$T/body.txt"
  has "$(gr "$d" diff - "$T/body.txt" systems/x.sh kb/current-state.md)" 'kb/current-state.md is in the diff and passes the template' "[G37] pages unset: the pass message is today's"
  has "$(gr "$d" diff - "$T/body.txt" systems/x.sh)" 'but kb/current-state.md is not in the diff' "[G37b] pages unset: the fail message is today's"
  # validation
  pv() {  # pv <label> <current_state json> <want rc> [key]
    local v R rc; v=$(fresh); mkdir -p "$v/.vibemaestro"; printf '{"schema": 1, "current_state": %s}' "$2" > "$v/.vibemaestro/sdlc.json"
    R=$( cd "$TMP" && cenv python3 "$PLX/scripts/kb.py" config check --root "$v" 2>&1 ); rc=$?
    eq "$rc" "$3" "[G40] $1: rc $3"
    [ -n "${4:-}" ] && has "$R" "$4" "[G40] $1: names $4"
  }
  pv "pages kb/state/*.md, page_limits and watch_exclude" '{"pages": "kb/state/*.md", "page_limits": {"lines": 50, "bytes": 9000, "line_chars": 300, "warn_ratio": 0.9}, "watch_exclude": ["systems/tests/"]}' 0
  pv "pages one named file" '{"pages": "kb/state/app.md"}' 0
  pv "pages kb/*.md holds the index" '{"pages": "kb/*.md"}' 65 current_state.pages
  pv "pages kb/** (a recursive glob)" '{"pages": "kb/**"}' 65 current_state.pages
  pv "pages kb/state/**/*.md (a recursive glob)" '{"pages": "kb/state/**/*.md"}' 65 current_state.pages
  pv "pages with a wildcard directory" '{"pages": "kb/*/x.md"}' 65 current_state.pages
  pv "pages not ending in .md" '{"pages": "kb/state/*"}' 65 current_state.pages
  pv "pages at the repo root" '{"pages": "*.md"}' 65 current_state.pages
  pv "pages in kb/decisions" '{"pages": "kb/decisions/*.md"}' 65 current_state.pages
  pv "pages inside kb/specs" '{"pages": "kb/specs/state/*.md"}' 65 current_state.pages
  pv "pages above the typed directories, the index elsewhere" '{"path": "STATE.md", "pages": "kb/*.md"}' 65 current_state.pages
  pv "pages above the index" '{"path": "docs/kb/state.md", "pages": "docs/*.md"}' 65 current_state.pages
  pv "watch_exclude with a ./ prefix" '{"watch_exclude": ["./systems/"]}' 65 'current_state.watch_exclude[0]'
  pv "page_limits.bytes zero" '{"page_limits": {"bytes": 0}}' 65 current_state.page_limits.bytes
  pv "an unknown key under page_limits (a warning)" '{"page_limits": {"pages": 3}}' 0
}

# ── [H] pages reach the session by their applyTo (the PreToolUse edit hook) ───────────────────────
# hk <root> <file under root> — the hook's context for an edit of that file, in a session of its own (the hook says a page
# and a rule once per session; hk runs inside `$(…)`, so a counter would not survive the call: the id is a fresh name)
hk() {
  printf '{"session_id":"pg%s","cwd":"%s","tool_name":"Edit","tool_input":{"file_path":"%s/%s"}}' "$(basename "$(mktemp -u "$T/s.XXXXXX")")" "$1" "$1" "$2" \
    | cenv CLAUDE_PLUGIN_ROOT="$PLX" python3 "$PLX/scripts/pre-edit.py" 2>&1
}
fam_pagehook() {
  PLX=$1; T=$(fresh)
  local d R
  d=$(pg_root)
  R=$(hk "$d" src/app/main.py); has "$R" "kb/state/a.md" "[H1] an edit under a page's applyTo names the page"
  hasnt "$R" "kb/state/b.md" "[H2] …and not a page without an applyTo"
  R=$(hk "$d" src/other/main.py); hasnt "$R" "kb/state/a.md" "[H3] an edit outside the page's applyTo names no page"
  R=$(hk "$d" kb/state/b.md); has "$R" "current-state-shape.instructions.md" "[H4] editing a page delivers the index's shape rule"
  R=$(hk "$d" kb/decisions/x.md); hasnt "$R" "current-state-shape.instructions.md" "[H4b] …which a kb file that is not a page does not get"
  python3 -c "import sys; sys.stdout.write('# B\n' + 'x' * 7000 + '\n')" > "$d/kb/state/b.md"
  R=$(hk "$d" kb/state/b.md); has "$R" "WARNING kb/state/b.md: 7005/8000 bytes" "[H5] editing a page near its own cap warns with the page cap"
  d=$(pg_root '{"schema": 1, "current_state": {"watch": ["systems/"]}}')
  R=$(hk "$d" src/app/main.py); hasnt "$R" "kb/state/a.md" "[H6] pages unset: no page is named, whatever kb/state holds"
  R=$(hk "$d" kb/state/b.md); hasnt "$R" "current-state-shape.instructions.md" "[H7] pages unset: a kb/state file is not a page and gets no shape rule"
}

FAMILIES="fam_diff fam_budget fam_tables fam_other fam_own fam_deco fam_api fam_ledger fam_validate fam_cli fam_pr fam_pages fam_pagehook fam_labels"
for f in $FAMILIES; do echo "-- $f"; "$f" "$PLUGIN"; done

# ── each planted break must turn its family red ─────────────────────────────────────────────────
BRK() {  # BRK <label> <family> <needle> <file under scripts/> <old> <new>
  local d="$TMP/break-$1"; mk_plugin_copy "$d"
  mutate "$d/scripts/$4" "$5" "$6" && expect_red "$1" "$2" "$d" "$3"
}
# the dated labels: each break turns its [N] case red
BRK label-date-not-exempted fam_labels '[N1]' current_state.py '                      and not any(s <= x.start() and x.end() <= e for s, e in spans)), None)' '                      ), None)'
BRK labels-on-by-default fam_labels '[N2]' sdlc_config.py '        "labels": None,' '        "labels": {"regex": "\\*chưa kiểm(?: từ (?P<date>[^*]*))?\\*", "max_age_days": 7},'
BRK label-exempts-whole-line fam_labels '[N3]' current_state.py 'and not any(s <= x.start() and x.end() <= e for s, e in spans)), None)' 'and not spans), None)'
BRK label-exempts-whole-label fam_labels '[N3b]' current_state.py '(s, e) if d is not None else None))' 'm.span(0) if d is not None else None))'
BRK label-wide-group-exempts fam_labels '[N4]' current_state.py '        if d is not None and _ISO_SHAPE.fullmatch(d):' '        if d is not None:'
BRK label-overrun-keeps-partial fam_labels '[N6]' current_state.py 'else ([], True)' 'else (out, True)'
BRK label-diff-warning-dropped fam_labels '[N7b]' current_state.py '    return ([w] if w else []) + label_warnings(text, profile, name, today)' '    return [w] if w else []'
BRK label-no-date-group-accepted fam_labels '[N8] a regex with no named group date' sdlc_config.py '        if "date" not in rx.groupindex:' '        if False:'
BRK label-empty-match-accepted fam_labels '[N8] a regex that matches the empty string' sdlc_config.py '        elif got[0]:' '        elif False:'
BRK label-bare-date-accepted fam_labels '[N8] a regex that matches a bare date' sdlc_config.py '        elif got[1]:' '        elif False:'
BRK label-probe-unbounded fam_labels '[N8] …and the config check returns in under 10 s' sdlc_config.py 'LABEL_PROBE_SECONDS = 1 ' 'LABEL_PROBE_SECONDS = 15 '
BRK label-markerless-match fam_labels '[N9]' current_state.py '                if any(c.isalpha() for c in ln[m.start():s] + ln[e:m.end()]):' '                if True:'
BRK label-blank-is-marker fam_labels '[N9b]' current_state.py '                if any(c.isalpha() for c in ln[m.start():s] + ln[e:m.end()]):' '                if m.group(0) and m.group(0) != d:'
BRK label-vendored-import fam_labels '[N11]' sdlc_config.py '        got = []           # the probes' '        import rules
        got = []           # the probes'
BRK label-max-age-optional fam_labels '[N8] no max_age_days' sdlc_config.py '("regex", "max_age_days")),' '("regex",)),'
BRK bytes-cap-off fam_budget '[B3]' current_state.py '    if len(raw) > lim["bytes"]:' '    if False:'
BRK bytes-cap-off-by-one fam_budget '[B2]' current_state.py '    if len(raw) > lim["bytes"]:' '    if len(raw) >= lim["bytes"]:'
BRK line-chars-cap-off fam_budget '[B5]' current_state.py '        if len(ln) > lim["line_chars"]:' '        if False:'
BRK line-chars-counts-bytes fam_budget '[B8]' current_state.py '        if len(ln) > lim["line_chars"]:' '        if len(ln.encode("utf-8")) > lim["line_chars"]:'
BRK cr-counted fam_budget '[B12]' current_state.py 'ln.rstrip("\r")' 'ln'
BRK nfc-dropped fam_budget '[B10]' current_state.py 'unicodedata.normalize("NFC", ln.rstrip("\r"))' 'ln.rstrip("\r")'
BRK last-line-dropped fam_budget '[B15]' current_state.py '    if lines and lines[-1] == "":
        lines = lines[:-1]
    return lines' '    return lines[:-1]'
BRK pattern-ignored fam_budget '[B16]' current_state.py '        for pid, rx in pats:' '        for pid, rx in []:'
BRK lines-cap-ignored fam_ledger '[L4]' current_state.py '    if lim["lines"] is not None and len(lines) > lim["lines"]:' '    if False:'
BRK lines-null-is-zero fam_ledger '[L16]' current_state.py '    if lim["lines"] is not None and len(lines) > lim["lines"]:' '    if len(lines) > (lim["lines"] or 0):'
BRK forbid-ignored fam_ledger '[L12]' current_state.py 'for i in sdlc_config.HISTORY_IDS[:-1] if i in p["forbid"]]' 'for i in sdlc_config.HISTORY_IDS[:-1] if False]'
BRK forbid-lists-everything fam_ledger '[L13]' current_state.py 'for i in sdlc_config.HISTORY_IDS[:-1] if i in p["forbid"]]' 'for i in sdlc_config.HISTORY_IDS[:-1]]'
BRK heading-test-always fam_ledger '[L15]' current_state.py 'if "history_heading" in p["forbid"] and HEADING_HISTORY.search(ln):' 'if HEADING_HISTORY.search(ln):'
BRK utf8-not-checked fam_tables '[T10]' current_state.py '    except UnicodeDecodeError as e:
        return [(0, "encoding"' '    except ZeroDivisionError as e:
        return [(0, "encoding"'
BRK header-names-unchecked fam_tables '[T1]' current_state.py '    if names and got != list(names):' '    if False:'
BRK separator-unchecked fam_tables '[T2]' current_state.py '    if len(c) != k or not all(_SEP.match(x) for x in c):' '    if False:'
BRK row-width-unchecked fam_tables '[T4]' current_state.py '        if len(c) != k:
            out.append((n, "table.row_width"' '        if False:
            out.append((n, "table.row_width"'
BRK empty-cells-unchecked fam_tables '[T4]' current_state.py '        elif no_empty and not all(c):' '        elif False:'
BRK enums-unchecked fam_tables '[T3]' current_state.py '                if value.strip() not in allowed:' '                if False:'
BRK exactly-one-dropped fam_tables '[T5]' current_state.py '        if len(mine) != 1:' '        if len(mine) < 1:'
BRK subheading-resets-section fam_tables '[T12]' current_state.py '        if _ATX.match(line) or _indent(line) >= 4:
            cur = None' '        if _ATX.match(line) or _indent(line) >= 4:
            cur = None
            if line.startswith("###"):
                sec = None'
BRK fences-not-skipped fam_tables '[T14]' current_state.py '        if m and not (m.group(1)[0] == "`" and "`" in m.group(2)):' '        if False:'
BRK escaped-pipe-split fam_tables '[T11]' current_state.py 're.split(r"(?<!\\)\|", s)' 're.split(r"\|", s)'
BRK indented-code-is-table fam_tables '[T16]' current_state.py '        if _ATX.match(line) or _indent(line) >= 4:' '        if _ATX.match(line):'
BRK decorations-ignored fam_deco '[Y1]' current_state.py '                    value = rx.sub("", value)' '                    value = value'
BRK decorations-not-trimmed fam_deco '[Y1]' current_state.py '                if value.strip() not in allowed:' '                if value not in allowed:'
BRK decorations-case-sensitive fam_deco '[Y1]' current_state.py 're.compile(r, re.I) for r in' 're.compile(r) for r in'
BRK decorations-first-regex-only fam_deco '[Y5]' current_state.py '([v] if isinstance(v, str) else v)]' '([v] if isinstance(v, str) else v[:1])]'
BRK decorations-for-every-column fam_deco '[Y4]' current_state.py '(decorations or {}).get(col, ())' '[r for rs in (decorations or {}).values() for r in rs]'
BRK decorations-never-passed fam_deco '[Y1]' current_state.py 'p["no_empty_cells"], entry.get("decorations")))' 'p["no_empty_cells"]))'
BRK decorations-hide-row-faults fam_deco '[Y8]' current_state.py '        if len(c) != k:
            out.append((n, "table.row_width"' '        if len(c) != k and not (decorations and "*" in line):
            out.append((n, "table.row_width"'
BRK decorations-key-unknown fam_validate 'decorations as a regex and as a list' sdlc_config.py 'ITEM_FIELDS = {"tables": ("heading", "columns", "enums", "decorations"),' 'ITEM_FIELDS = {"tables": ("heading", "columns", "enums"),'
BRK decorations-column-unchecked fam_validate 'decorations for a column with no enums' sdlc_config.py '        if not (isinstance(enums, dict) and col in enums):' '        if False:'
BRK decorations-empty-match-accepted fam_validate 'matches the empty string' sdlc_config.py '            if len(out) == n and re.compile(r).search(""):' '            if False:'
BRK decorations-empty-list-accepted fam_validate 'decorations with an empty list' sdlc_config.py '        if isinstance(rx, list) and not rx:' '        if False:'
BRK decorations-regex-unchecked fam_validate 'decorations with a bad regex' sdlc_config.py '            _check(("regex",), r, kj, out)' '            pass'
BRK decorations-reversed fam_deco '[Y10]' current_state.py '                for rx in (decorations or {}).get(col, ()):' '                for rx in reversed((decorations or {}).get(col, ())):'
BRK decorations-key-not-normalised fam_deco '[Y11]' current_state.py 'decorations={_norm(k): [re.compile' 'decorations={k: [re.compile'
BRK decorations-comment-compiled fam_deco '[Y12]' current_state.py 'for k, v in (e.get("decorations") or {}).items() if not k.startswith("_")})' 'for k, v in (e.get("decorations") or {}).items()})'
BRK decorations-empty-match-first-only fam_validate 'empty-matching second regex' sdlc_config.py '            if len(out) == n and re.compile(r).search(""):' '            if len(out) == n and j == 0 and re.compile(r).search(""):'
BRK own-width-ignored fam_own '[O1]' current_state.py '    elif p["table_own_width"]:' '    elif False:'
BRK own-width-fixed-number fam_own '[O4]' current_state.py 'out.extend(_check_table(t[1], None, len(_cells(t[1][0][1])), None, False))' 'out.extend(_check_table(t[1], None, 4, None, False))'
BRK own-width-empty-cells fam_own '[O7]' current_state.py 'out.extend(_check_table(t[1], None, len(_cells(t[1][0][1])), None, False))' 'out.extend(_check_table(t[1], None, len(_cells(t[1][0][1])), None, p["no_empty_cells"]))'
BRK own-width-rechecks-covered fam_own '[O13]' current_state.py '    elif p["table_own_width"]:
        # width only: the header sets the width, nothing else is asked of the cells (`no_empty_cells` belongs to the tables
        # an entry covers and to the `table` fallback)
        for t in tabs:
            if id(t) not in covered:' '    elif p["table_own_width"]:
        # width only: the header sets the width, nothing else is asked of the cells (`no_empty_cells` belongs to the tables
        # an entry covers and to the `table` fallback)
        for t in tabs:
            if True:'
BRK own-width-always-on fam_ledger '[L35]' sdlc_config.py '        "table_own_width": False,' '        "table_own_width": True,'
BRK own-width-conflict-unchecked fam_validate 'table_own_width over the map preset' sdlc_config.py '    if cs["table_own_width"] and cs["table"] is not None:' '    if False:'
BRK own-width-not-boolean fam_validate 'table_own_width that is not a boolean' sdlc_config.py '        "table_own_width": ("bool",),' '        "table_own_width": ("str",),'
BRK fallback-ignored fam_other '[W1]' current_state.py '    if table:
        for t in tabs:' '    if False:
        for t in tabs:'
BRK fallback-eats-covered-tables fam_other '[W0]' current_state.py '            if id(t) not in covered:
                out.extend(_check_table(t[1], None, table["columns"]' '            if True:
                out.extend(_check_table(t[1], None, table["columns"]'
BRK required-ignored fam_other '[W13]' current_state.py '        if table["required"] and not tabs:' '        if False:'
BRK watch-prefix-unanchored fam_diff '[D8]' current_state.py 'if any(x.startswith(w) for w in p["watch"]) and' 'if any(w in x for w in p["watch"]) and'
BRK exemption-ignored fam_diff '[D3]' current_state.py '    why = exemption(body, p)
    if why is not None:' '    why = "x"
    if why is not None:'
BRK exemption-token-anywhere fam_diff '[D10]' current_state.py 'r"^\s*(?:%s)\s*(%s)$"' 'r"(?:%s)\s*(%s)$"'
BRK exemption-reason-own-line fam_diff '[D27]' current_state.py 'r"^\s*(?:%s)\s*(%s)$"' 'r"^\s*(?:%s)[ \t]*(%s)$"'
BRK min-reason-ignored fam_diff '[D19]' current_state.py '    return reason if len(reason) >= need else None' '    return reason'
BRK extra-tokens-ignored fam_diff '[D15]' current_state.py 'toks = p["no_state_change"]' 'toks = p["no_state_change"][:1]'
BRK watch-empty-not-vacuous fam_diff '[D22]' current_state.py '    if not p["watch"]:
        return 0, "the profile watches no path: the diff gate does not apply"' '    if False:
        return 0, "x"'
BRK ledger-in-diff-unmeasured fam_budget '[B20]' current_state.py '    probs = ledger_problems(root, p, ledger)' '    probs = []'
BRK touched-ledger-bypass fam_api '[A7]' current_state.py '    if ledger is None and touched:' '    if False:'
BRK ledger-arg-ignored fam_api '[A3]' current_state.py '    if ledger is None:
        ledger = _read_ledger(root, led)' '    ledger = _read_ledger(root, led)'
BRK preset-not-applied fam_ledger '[L30]' sdlc_config.py 'return _merge(base, {"current_state": PRESETS[template]}) if PRESETS.get(template) else base' 'return base'
BRK preset-beats-file fam_ledger '[L32]' sdlc_config.py '    return _normalise(_merge(_with_preset(data), data))' '    return _normalise(_merge(data, _with_preset(data)))'
BRK preset-line-cap-wrong fam_ledger '[L30]' sdlc_config.py '"limits": {"lines": None, "bytes": 28000, "line_chars": 400},' '"limits": {"lines": 400, "bytes": 28000, "line_chars": 400},'
BRK tables-regex-unchecked fam_validate 'table entry with a bad heading regex' sdlc_config.py '            _check(("regex",), item["heading"], k + ".heading", out)' '            pass'
BRK patterns-builtin-id-allowed fam_validate 'built-in id' sdlc_config.py '            if pid in HISTORY_IDS:' '            if False:'
BRK enums-column-unchecked fam_validate 'enums column that is not a column' sdlc_config.py '                if isinstance(cols, list) and col not in cols:' '                if False:'
BRK lines-null-rejected fam_validate 'null line cap' sdlc_config.py '"limits": ("obj", {"lines": ("intnull", 1),' '"limits": ("obj", {"lines": ("int", 1),'
BRK config-ref-ignored fam_cli '[K14]' kb.py '            cfg, probs = config_at_ref(root, ref, scratch)' '            probs = []'
BRK config-ref-script-ignored fam_cli '[K17]' kb.py '            script_root = scratch' '            script_root = root'
BRK diff-block-exits-zero fam_cli '[K5]' kb.py '            sys.stderr.write("kb: current-state diff gate blocks %s:\n%s\n" % (rng, msg))
            return 65' '            sys.stderr.write("kb: current-state diff gate blocks %s:\n%s\n" % (rng, msg))
            return 0'
BRK ref-not-verified fam_cli '[K23]' kb.py '            if _git(root, "rev-parse", "--verify", "--quiet", ref + "^{commit}")[0] != 0:' '            if False:'
BRK ref-invalid-config-ignored fam_cli '[K22]' kb.py '            if probs:
                sys.stderr.write("kb: %s at %s is invalid:' '            if False:
                sys.stderr.write("kb: %s at %s is invalid:'
BRK renames-detected fam_cli '[K24]' kb.py '"diff", "--name-only", "--no-renames", rng)' '"diff", "--name-only", rng)'
BRK ledger-not-beside-script fam_cli '[K25]' kb.py '            led = cfg["current_state"]["path"]' '            led = "nowhere/none.md"'
BRK external-crash-uncaught fam_cli '[K26]' current_state.py '        except Exception as e:                                    # a gate that cannot run must not wave a PR through' '        except ZeroDivisionError as e:                            # mutated'
BRK core-renames-detected fam_pr '[P17]' open_pr.py '"diff", "--name-only", "--no-renames",' '"diff", "--name-only",'
BRK core-legacy-silent fam_pr '[P16]' open_pr.py '        if present and os.path.isfile(os.path.join(top, *LEGACY_GATE_SCRIPT.split("/"))):
            err(' '        if False:
            err('
BRK names-not-normalised fam_tables '[T3b]' current_state.py '    p["tables"] = [dict(e, columns=[_norm(c) for c in e["columns"]],' '    p["tables"] = [dict(e, columns=list(e["columns"]),'
BRK fallback-needs-rows fam_other '[W4b]' current_state.py '    if len(rows) == 2 and names:' '    if len(rows) == 2:'
BRK empty-cells-always fam_other '[W4d]' current_state.py '        elif no_empty and not all(c):' '        elif not all(c):'
BRK table-required-missing-crash fam_ledger '[L21b]' sdlc_config.py '        cfg["current_state"]["table"].setdefault("required", False)' '        pass'
BRK table-columns-optional fam_validate 'table with no columns' sdlc_config.py '"required": ("bool",)}, ("columns",)),' '"required": ("bool",)}, ()),'
BRK dot-segment-accepted fam_validate 'watch entry with a ./ prefix' sdlc_config.py '    return _rel_ok(v) and all(seg != "." for seg in v.split("/"))' '    return _rel_ok(v)'
BRK empty-regex-accepted fam_validate 'matches the empty string' sdlc_config.py '                if re.compile(rx).search(""):' '                if False:'
BRK shape-check-ignores-profile fam_cli '[K4]' kb.py '    probs = current_state.problems_classified(raw, profile)' '    probs = current_state.problems_classified(raw)'
BRK missing-external-passes fam_cli '[K19]' current_state.py '            return 1, "current_state.gate is %s but that file does not exist" % gate' '            return 0, "x"'
BRK gate-off-ignored fam_cli '[K18]' current_state.py '    if gate == "off":
        return 0, "current_state.gate is off"' '    if False:
        return 0, "x"'
BRK core-builtin-skipped fam_pr '[P1]' open_pr.py '    if profile["gate"] == "builtin" and not profile["watch"]:' '    if profile["gate"] == "builtin":'
BRK core-legacy-script-dropped fam_pr '[P14]' open_pr.py '    if not present and os.path.isfile(os.path.join(top, *LEGACY_GATE_SCRIPT.split("/"))):' '    if False:'
BRK core-legacy-script-always fam_pr '[P15]' open_pr.py '    if not present and os.path.isfile(os.path.join(top, *LEGACY_GATE_SCRIPT.split("/"))):' '    if os.path.isfile(os.path.join(top, *LEGACY_GATE_SCRIPT.split("/"))):'
BRK core-ignores-config fam_pr '[P4]' open_pr.py '    cs_rc, cs_msg = current_state_gate(top or cwd, a.base, head, body, cfg, _present)' '    cs_rc, cs_msg = current_state_gate(top or cwd, a.base, head, body, None, False)'

# pages
BRK page-cap-is-index-cap fam_pages '[G2]' current_state.py 'return dict(p, limits=p["page_limits"],' 'return dict(p, limits=p["limits"],'
BRK page-cap-off-by-one fam_pages '[G2b]' sdlc_config.py '"page_limits": {"lines": None, "bytes": 8000,' '"page_limits": {"lines": None, "bytes": 7999,'
BRK page-line-cap-default-on fam_pages '[G2b]' sdlc_config.py '"page_limits": {"lines": None, "bytes": 8000,' '"page_limits": {"lines": 120, "bytes": 8000,'
BRK page-line-chars-index fam_pages '[G3b]' sdlc_config.py '"bytes": 8000, "line_chars": 400,' '"bytes": 8000, "line_chars": 200,'
BRK pages-unchecked fam_pages '[G2]' current_state.py '    for rel, raw in pages:
        out.extend(' '    for rel, raw in []:
        out.extend('
BRK page-tables-checked fam_pages '[G16]' current_state.py 'tables=[], table=None, table_own_width=False, inject=False)' 'table_own_width=True, inject=False)'
BRK orphan-ignored fam_pages '[G6]' current_state.py '    for rel in sorted(names[k] for k in set(names) - from_index):' '    for rel in []:'
BRK orphan-adopted-by-page fam_pages '[G7]' current_state.py '            if rel == led:
                from_index.add(target)' '            if True:
                from_index.add(target)'
BRK dead-pointer-ignored fam_pages '[G8]' current_state.py '            if target not in names:' '            if False:'
BRK dead-pointer-exists-only fam_pages '[G9]' current_state.py '            if target not in names:' '            if not os.path.exists(os.path.join(root or os.getcwd(), *target.split("/"))):'
BRK not-file-accepted fam_pages '[G11]' current_state.py '        if os.path.islink(full) or not os.path.isfile(full):' '        if not os.path.exists(full):'
BRK links-ignored fam_pages '[G12]' current_state.py '        for m in _LINK.finditer(ln):' '        for m in []:'
BRK links-from-root fam_pages '[G14]' current_state.py 'else posixpath.join(here, t))' 'else t)'
BRK anchor-kept fam_pages '[G13]' current_state.py 'c = re.split(r"[#?]", c, 1)[0].rstrip(".:")' 'c = c.rstrip(".:")'
BRK glob-mention-is-pointer fam_pages '[G17]' current_state.py '_BARE_STOP = "\\s`'"'"'\"()<>\\[\\]{}|*,;!?"' '_BARE_STOP = "\\s`'"'"'\"()\\[\\]{}|,;!?"'
BRK pages-default-on fam_pages '[G18]' sdlc_config.py '        "pages": None,' '        "pages": "kb/state/*.md",'
BRK page-touch-ignored fam_pages '[G20]' current_state.py '    mine = sorted(x for x in paths if x == led or is_page(x, p))' '    mine = sorted(x for x in paths if x == led)'
BRK page-is-any-file-of-dir fam_pages '[G22]' current_state.py 'return bool(p.get("pages")) and sdlc_config.glob_match(p["pages"], rel)' 'return bool(p.get("pages")) and rel.startswith(sdlc_config.page_dir(p["pages"]) + "/")'
BRK exclude-ignored fam_pages '[G23]' current_state.py ' and not any(x.startswith(e) for e in excl))' ')'
BRK exclude-unanchored fam_pages '[G25b]' current_state.py 'not any(x.startswith(e) for e in excl)' 'not any(e in x for e in excl)'
BRK exclude-swallows-all fam_pages '[G25]' current_state.py 'hits = sorted(x for x in paths if' 'hits = [] if any(x.startswith(e) for x in paths for e in excl) else sorted(x for x in paths if'
BRK gate-judges-index-only fam_pages '[G26]' current_state.py '    probs = ledger_problems(root, p, ledger)' '    probs = problems(ledger, p) if ledger is not None else []'
BRK page-touch-not-applied fam_pages '[G28]' current_state.py '    if not hits and not mine:' '    if not hits and not touched:'
BRK kb-whole-ledger-skipped fam_pages '[G30]' kb.py '    whole = not target and profile.get("pages")' '    whole = False'
BRK kb-page-arg-index-cap fam_pages '[G31]' kb.py '    if page:
        profile = current_state.page_profile(profile)' '    if False:
        profile = current_state.page_profile(profile)'
BRK pages-glob-unchecked fam_pages 'pages kb/state/**/*.md (a recursive glob)' sdlc_config.py '        if v is not None and not page_glob_ok(v):' '        if False:'
BRK pages-wild-dir-accepted fam_pages 'pages with a wildcard directory' sdlc_config.py '    return not any(c in d for c in "*?") and _git_path_ok(d)' '    return _git_path_ok(d)'
BRK pages-not-md-accepted fam_pages 'pages not ending in .md' sdlc_config.py 'and name.endswith(".md") and name != ".md"' 'and name != ".md"'
BRK pages-holding-index-accepted fam_pages 'pages above the index' sdlc_config.py '        if cs["path"] == d or cs["path"].startswith(d + "/"):' '        if cs["path"] == d:'
BRK pages-typed-dir-accepted fam_pages 'pages in kb/decisions' sdlc_config.py '            if d == t or d.startswith(t + "/") or t.startswith(d + "/"):' '            if False:'
BRK pages-inside-typed-accepted fam_pages 'pages inside kb/specs' sdlc_config.py '            if d == t or d.startswith(t + "/") or t.startswith(d + "/"):' '            if d == t or t.startswith(d + "/"):'
BRK pages-above-typed-accepted fam_pages 'pages above the typed directories' sdlc_config.py '            if d == t or d.startswith(t + "/") or t.startswith(d + "/"):' '            if d == t or d.startswith(t + "/"):'
BRK exclude-unvalidated fam_pages 'watch_exclude with a ./ prefix' sdlc_config.py '        "watch_exclude": ("gitprefixes",),' '        "watch_exclude": ("strlist",),'
BRK page-limits-unvalidated fam_pages 'page_limits.bytes zero' sdlc_config.py '"page_limits": ("obj", {"lines": ("intnull", 1), "bytes": ("int", 1),' '"page_limits": ("obj", {"lines": ("intnull", 1), "bytes": ("int", 0),'
BRK kb-page-arg-relpath fam_pages '[G32]' kb.py 'current_state.is_page(_repo_rel(path, root), profile)' 'current_state.is_page(os.path.relpath(path, root).replace(os.sep, "/"), profile)'
BRK kb-page-arg-file-resolved fam_pages '[G32b]' kb.py '    real = os.path.join(os.path.realpath(os.path.dirname(os.path.abspath(path))), os.path.basename(path))' '    real = os.path.realpath(path)'
BRK root-link-skipped fam_pages '[G33b]' current_state.py 't.startswith(("mailto:", "#", "//"))' 't.startswith(("mailto:", "#", "/"))'
BRK root-link-joined fam_pages '[G33]' current_state.py 't.lstrip("/") if t.startswith("/") else posixpath' 'posixpath'
BRK angle-link-cut-at-space fam_pages '[G34]' current_state.py '(?:<([^<>\n]+)>|([^)\s<>]+))")' '<?([^)\s>]+)()")'
BRK nfd-names-unmatched fam_pages '[G35]' current_state.py 'names = {unicodedata.normalize("NFC", rel): rel for rel' 'names = {rel: rel for rel'
BRK symlink-dir-followed fam_pages '[G36]' current_state.py '    if os.path.isdir(directory) and os.path.realpath(directory) !=' '    if False and os.path.realpath(directory) !='
BRK unset-pass-reworded fam_pages '[G37]' current_state.py '    if mine and not p.get("pages"):' '    if False:'
BRK unset-fail-reworded fam_pages '[G37b]' current_state.py 'if p.get("pages") else "%s is not" % led' 'if True else "%s is not" % led'
BRK hook-pages-silent fam_pagehook '[H1]' vsdlc.py '        if pages:
            parts.append(' '        if False:
            parts.append('
BRK hook-applyto-ignored fam_pagehook '[H3]' vsdlc.py 'if C.glob_match(g, d + "/" + n) and R.apply_to_matches(t, rel, dirs)]' 'if C.glob_match(g, d + "/" + n)]'
BRK hook-page-no-shape-rule fam_pagehook '[H4]' vsdlc.py '        led = cfg["current_state"]["path"] if _is_page(cfg, rel) else None' '        led = None'
BRK hook-every-kb-file-shape-rule fam_pagehook '[H4b]' vsdlc.py '        led = cfg["current_state"]["path"] if _is_page(cfg, rel) else None' '        led = cfg["current_state"]["path"]'
BRK hook-page-index-cap fam_pagehook '[H5]' vsdlc.py '            profile, name = current_state.page_profile(profile), rel' '            name = rel'
BRK hook-pages-unset-is-on fam_pagehook '[H6]' vsdlc.py '        g = cfg["current_state"].get("pages")
        if not g:
            return []' '        g = cfg["current_state"].get("pages") or "kb/state/*.md"
        if not g:
            return []'
BRK hook-pages-unset-shape-rule fam_pagehook '[H7]' vsdlc.py '    g = cfg["current_state"].get("pages")
    return bool(g) and C.glob_match(g, rel)' '    g = cfg["current_state"].get("pages") or "kb/state/*.md"
    return bool(g) and C.glob_match(g, rel)'

PLC="$TMP/break-none"; mk_plugin_copy "$PLC"
QN=0; okdef=$(declare -f ok); baddef=$(declare -f bad); sp=$PASS; sf=$FAIL
ok() { :; }; bad() { QN=$((QN+1)); }
for f in $FAMILIES; do "$f" "$PLC" >/dev/null 2>&1; done
eval "$okdef"; eval "$baddef"; PASS=$sp; FAIL=$sf
eq "$QN" 0 "control: an unbroken copy passes every family (no failed check)"

# ── [J] the injection cap: its own run, breaks and control, after the families above ───────────────────────
echo "-- fam_inject"; fam_inject "$PLUGIN"
BRK inject-cap-off fam_inject '[J2]' current_state.py '    if p.get("inject") and inject_chars(raw) > INJECT_MAX_CHARS:' '    if False:'
BRK inject-cap-off-by-one fam_inject '[J1]' current_state.py '    if p.get("inject") and inject_chars(raw) > INJECT_MAX_CHARS:' '    if p.get("inject") and inject_chars(raw) >= INJECT_MAX_CHARS:'
BRK inject-switch-ignored fam_inject '[J3]' current_state.py '    if p.get("inject") and inject_chars(raw) > INJECT_MAX_CHARS:' '    if inject_chars(raw) > INJECT_MAX_CHARS:'
BRK inject-counts-code-points fam_inject '[J4]' current_state.py '.replace("\r\n", "\n").encode("utf-16-le")) // 2' '.replace("\r\n", "\n"))'
BRK inject-crlf-counted fam_inject '[J8]' current_state.py 's.replace("\r\n", "\n").encode' 's.encode'
BRK inject-on-by-default fam_inject '[J3b]' sdlc_config.py '        "inject": False,' '        "inject": True,'
BRK inject-not-boolean fam_inject '[J7]' sdlc_config.py '        "inject": ("bool",),' '        "inject": ("str",),'
QN=0; okdef=$(declare -f ok); baddef=$(declare -f bad); sp=$PASS; sf=$FAIL
ok() { :; }; bad() { QN=$((QN+1)); }
fam_inject "$PLC" >/dev/null 2>&1
eval "$okdef"; eval "$baddef"; PASS=$sp; FAIL=$sf
eq "$QN" 0 "control: an unbroken copy passes fam_inject (no failed check)"

echo; summary
