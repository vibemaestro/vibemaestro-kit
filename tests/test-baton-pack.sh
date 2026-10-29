#!/bin/bash
# =============================================================================
# BatonRun: keeping a flow that ran right — `baton pack` (scripts/baton.py): the file and its keep record, the refusals, the
# `ok` run it needs (logged on this machine only), --retire, moves between places that a re-run finishes, the per-name lock, and
# the owner: line; in a sandbox a bare name keeps project:, user: is refused, and a stop-list baton packs after go stopped for the owner
# =============================================================================
# Run: bash tests/test-baton-pack.sh
#
# Each area is a FAMILY `fam_<x> <plugin dir>`, run on a copy of the real plugin, then again on copies with ONE planted break in
# baton.py (expect_red, tests/fixtures/ports.sh), which must go red on the intended tag. tests/fixtures/baton_pack.py stops a pack
# at one step, races it for a sequence number, or holds a name's lock. The state is XDG_STATE_HOME and the library XDG_DATA_HOME
# inside the scratch tree, HOME is the scratch home; nothing is written outside the scratch tree, which the last section checks.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
# shellcheck source=fixtures/ports.sh
. "$HERE/fixtures/ports.sh"
# shellcheck source=fixtures/baton-owner.sh
. "$HERE/fixtures/baton-owner.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT    # an input copy is read-only (0400 in a 0500 directory)
clean_env "$TMP"
umask 022                                               # a project root writable by its group is refused: the suite's are not
export PYTHONDONTWRITEBYTECODE=1
H0=$(tree_hash "$SRC_ROOT")
FX="$HERE/fixtures/baton_params.py"
PX="$HERE/fixtures/baton_pack.py"
BT_OUT="$TMP/bt.out"
ST=""; XD=""; BT_ENV=(); OWNER_SID=s-owner

# bt <plugin> <dir> <baton args...> — rc of baton run from <dir> with the state in $ST and the library in $XD (plus BT_ENV); the
# output is in $BT_OUT. A `sign --by owner` first goes through the plugin's guard hook, as when the owner clicks the dialog.
bt() {
  local p=$1 d=$2; shift 2
  [ "${1:-} ${2:-} ${3:-}" = "sign --by owner" ] && owner_asked "$p" "$d" "$ST" "$OWNER_SID" "${@:2}" >/dev/null
  [ "${1:-}" = mode ] && [ $# -gt 1 ] && mode_asked "$p" "$d" "$ST" "$OWNER_SID" "${@:2}" >/dev/null
  ( cd "$d" && cenv XDG_STATE_HOME="$ST" XDG_DATA_HOME="$XD" CLAUDE_CODE_SESSION_ID="$OWNER_SID" ${BT_ENV[@]+"${BT_ENV[@]}"} \
      python3 "$p/scripts/baton.py" "$@" ) > "$BT_OUT" 2>&1; echo $?
}
out() { cat "$BT_OUT"; }
# px <plugin> <dir> <fixture args...> — the pack fixture from <dir>, same environment; its last line is `rc <n>`
px() {
  local p=$1 d=$2; shift 2
  ( cd "$d" && cenv XDG_STATE_HOME="$ST" XDG_DATA_HOME="$XD" CLAUDE_CODE_SESSION_ID="$OWNER_SID" ${BT_ENV[@]+"${BT_ENV[@]}"} \
      python3 "$PX" "$@" ) > "$BT_OUT" 2>&1; echo $?
}
seal_for() {
  ( cd "$2" && cenv XDG_STATE_HOME="$ST" XDG_DATA_HOME="$XD" ${BT_ENV[@]+"${BT_ENV[@]}"} python3 "$1/scripts/baton.py" rehearse "${@:3}" ) 2>/dev/null \
    | sed -n 's/^seal \([^ ]*\) .*/\1/p'
}
sg() { local p=$1 d=$2 by=$3 seal; shift 3; seal=$(seal_for "$p" "$d" "$@"); bt "$p" "$d" sign --by "$by" --seal "${seal:-none}" "$@"; }
# setup <plugin> — a fresh state (mode auto), library and working directory W; prints nothing
setup() { ST="$(fresh)/state"; XD="$(fresh)/data"; W=$(fresh); BT_ENV=(); bt "$1" "$W" mode auto >/dev/null; }
bdir() { printf '%s' "$ST/vibemaestro/baton"; }
lib() { printf '%s' "$XD/vibemaestro/batons"; }
shaf() { python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"; }
pkey() { ( cd "$1" && python3 -c 'import hashlib, os, subprocess
r = subprocess.run(["git", "rev-parse", "--git-common-dir"], capture_output=True, text=True)
print("project-" + hashlib.sha256(os.path.realpath(r.stdout.strip()).encode()).hexdigest()[:16])' ); }
repo() { git_ init -q -b main "$1"; }
D() { printf '%s' "dest=$1"; }
# mk <plugin> <file> [<extra line>] — a kept-baton-ready scratch baton (Params dest=path, a testable Target); the extra line
# (a comment) makes other bytes
mk() { python3 "$FX" make "$1" "$2" "dest=path" "{dest}/** — the file"; [ -z "${3:-}" ] || printf '%s\n' "$3" >> "$2"; }
# okrun <plugin> <dir> <script> — one ok run of the script (go, mode auto, Stops none) into a fresh directory; prints the rc
okrun() { local o; o=$(fresh); bt "$1" "$2" go "$3" "$(D "$o")"; }
# recs <key> <name> — the keep and retire records of a name, one file name per line
recs() { ls "$(bdir)/kept/$1/$2" 2>/dev/null | grep -E '^[0-9]{6}\.json$'; }
nrecs() { recs "$1" "$2" | wc -l | tr -d ' '; }
newest() { local f; f=$(recs "$1" "$2" | tail -n 1); [ -n "$f" ] && cat "$(bdir)/kept/$1/$2/$f"; }
lastlog() { tail -n 1 "$(bdir)/log.tsv"; }

# ── a keep: the file, the record, the log, the owner: line, a call right after ───────────────────────────────────────────────
fam_keep() {
  local P=$1 A R K o; setup "$P"; mk "$P" "$W/s.sh"; A=$(shaf "$W/s.sh")
  eq "$(okrun "$P" "$W" "$W/s.sh")" 0 "[keep] the scratch baton runs ok"
  eq "$(bt "$P" "$W" pack "$W/s.sh" user:a)" 0 "[keep] pack a scratch baton as user:a: rc 0"
  eq "$(shaf "$(lib)/a.sh" 2>/dev/null)" "$A" "[keep] …the library holds the bytes that ran"
  eq "$(nrecs user a)" 1 "[keep] …one keep record"
  eq "$(newest user a | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha256"])')" "$A" "[keep] …naming the sha256"
  local r; r=$(newest user a)
  eq "$(python3 -c 'import json,sys; r=json.loads(sys.argv[1]); print(" ".join(sorted(r)))' "$r" 2>/dev/null)" \
     "kept_at kept_by name params place prev_sha256 root sha256 stops" "[keep] …with the fields of §7"
  eq "$(python3 -c 'import json,sys; r=json.loads(sys.argv[1]); print(r["place"], r["name"], r["params"], r["stops"], r["prev_sha256"], json.dumps(r["kept_by"]))' "$r" 2>/dev/null)" \
     'user a dest=path none None {"session": "s-owner"}' "[keep] …place, name, Params, Stops, no earlier sha, kept_by the session"
  has "$(out)" "owner: kept user:a (new) — Stops none — sha256 ${A:0:12} — changed: (new) — body +" "[keep] a user: keep prints one owner: line"
  has "$(out)" "— not reviewed — Purpose: a test baton" "[keep] …'not reviewed', then the Purpose last (a Purpose cannot pose as the fields)"
  eq "$(grep -c '^owner: ' "$BT_OUT")" 1 "[keep] …exactly one"
  eq "$(lastlog | cut -f2,10,13 | tr '\t' ' ')" "pack kept user:a@$A" "[keep] the log has the event pack, result kept, baton user:a@<sha256>"
  o=$(fresh)
  eq "$(bt "$P" "$W" go user:a "$(D "$o")")" 0 "[keep] a call right after pack runs: rc 0"
  [ -f "$o/x" ] && ok "[keep] …and did its write" || bad "[keep] …and did its write"
  has "$(out)" "not reviewed, kept by s-owner" "[keep] …go's line names who kept it"
  eq "$(bt "$P" "$W" pack "$W/s.sh" user:a)" 0 "[keep] a re-pack of the same bytes: rc 0"
  has "$(out)" "already kept" "[keep] …says already kept"
  has "$(out)" "owner: already kept user:a" "[keep] …and relays it to the owner again (a keep cut before its line still reaches the owner)"
  echo '# edited by hand' >> "$(lib)/a.sh"; local E; E=$(shaf "$(lib)/a.sh")
  eq "$(bt "$P" "$W" pack "$W/s.sh" user:a)" 0 "[keep] a re-pack over a hand-edited file: rc 0"
  has "$(out)" "the file held sha256 ${E:0:12}, restored to these bytes" "[keep] …says the file was restored, and what it held"
  eq "$(shaf "$(lib)/a.sh")" "$A" "[keep] …the kept bytes are back"
  eq "$(nrecs user a)" 1 "[keep] …and writes no second record"
  R=$(fresh); repo "$R"; K=$(pkey "$R")
  BT_ENV=(SEAT=seat-1 INTENT_SLUG=2026-10-24-x); mk "$P" "$W/t.sh" "# t"; okrun "$P" "$W" "$W/t.sh" >/dev/null
  eq "$(bt "$P" "$R" pack "$W/t.sh" project:t)" 0 "[keep] pack with SEAT and INTENT_SLUG set: rc 0"
  eq "$(newest "$K" t | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["kept_by"], sort_keys=True))')" \
     '{"intent": "2026-10-24-x", "seat": "seat-1", "session": "s-owner"}' "[keep] …kept_by holds the session, the seat and the intent"
  BT_ENV=(); bt "$P" "$W" pack "$W/t.sh" user:t >/dev/null
  BT_ENV=(SEAT='bad seat!'); mk "$P" "$W/u.sh" "# u"; okrun "$P" "$W" "$W/u.sh" >/dev/null; bt "$P" "$W" pack "$W/u.sh" user:u >/dev/null
  eq "$(newest user u | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["kept_by"]))')" '{"session": "s-owner"}' \
     "[keep] …a part that is not a valid name is left out"
  BT_ENV=()
  R=$(fresh); repo "$R"; K=$(pkey "$R"); mk "$P" "$R/s.sh"; okrun "$P" "$R" "$R/s.sh" >/dev/null
  eq "$(bt "$P" "$R" pack "$R/s.sh" project:p)" 0 "[keep] pack as project:p: rc 0"
  [ -f "$R/.vibemaestro/batons/p.sh" ] && ok "[keep] …the file is in <root>/.vibemaestro/batons" || bad "[keep] …the file is in <root>/.vibemaestro/batons"
  eq "$(modeof "$R/.vibemaestro/batons")" 755 "[keep] …the place directory is created with mode 755"
  eq "$(nrecs "$K" p)" 1 "[keep] …one keep record under the repository's place key"
  hasnt "$(out)" "owner: " "[keep] …a project: keep prints no owner: line"
  has "$(out)" "kept project:p (new)" "[keep] …but the same facts"
  eq "$(newest "$K" p | python3 -c 'import json,sys; print(json.load(sys.stdin)["root"])')" "$R" "[keep] …root is the project root's real path"
  o=$(fresh); eq "$(bt "$P" "$R" go project:p "$(D "$o")")" 0 "[keep] go project:p right after: rc 0"
  # SIGTERM right after the record: the log line and the owner: line still come, then rc 5
  mk "$P" "$W/i.sh" "# i"; A=$(shaf "$W/i.sh"); okrun "$P" "$W" "$W/i.sh" >/dev/null
  px "$P" "$W" term "$P" write_record "$W/i.sh" user:i >/dev/null
  has "$(out)" "owner: kept user:i (new)" "[keep] a SIGTERM right after the record: the owner: line still comes"
  has "$(out)" "rc 5" "[keep] …then rc 5, interrupted"
  eq "$(grep -c "	pack	.*	kept	.*user:i@$A" "$(bdir)/log.tsv")" 1 "[keep] …and the log has its pack kept line"
  # Stops words as a set; a copy name with a trailing -; after a retire the next keep says so
  mk "$P" "$W/d1.sh" "# d1"; sed -i 's/^# Stops: none$/# Stops: publish, publish/' "$W/d1.sh"; o=$(fresh)
  sg "$P" "$W" owner "$W/d1.sh" "$(D "$o")" >/dev/null; bt "$P" "$W" run "$W/d1.sh" "$(D "$o")" >/dev/null
  bt "$P" "$W" pack "$W/d1.sh" user:dup >/dev/null
  eq "$(newest user dup | python3 -c 'import json,sys; print(json.load(sys.stdin)["stops"])')" publish "[keep] Stops are kept as a set: publish, publish is publish"
  eq "$(bt "$P" "$W" pack "$W/t.sh" user:t-v2-)" 64 "[keep] a copy name with a trailing -: rc 64"
  bt "$P" "$W" pack --retire user:t "$(shaf "$W/t.sh")" >/dev/null; okrun "$P" "$W" "$W/t.sh" >/dev/null
  bt "$P" "$W" pack "$W/t.sh" user:t >/dev/null
  has "$(out)" "owner: kept user:t (after retired " "[keep] a keep after a retire says (after retired …), not (new)"
}
modeof() { python3 -c 'import os, stat, sys; print("%o" % stat.S_IMODE(os.stat(sys.argv[1]).st_mode))' "$1" 2>/dev/null; }

# ── refusals of §7 and §4 ─────────────────────────────────────────────────────────────────────────────────────────────────────
fam_refuse() {
  local P=$1 R T; setup "$P"; mk "$P" "$W/s.sh"; okrun "$P" "$W" "$W/s.sh" >/dev/null
  eq "$(bt "$P" "$W" pack "$W/s.sh" a)" 64 "[refuse] no place: rc 64"
  has "$(out)" "name the place of a: project:a or user:a" "[refuse] …and names the two places"
  eq "$(bt "$P" "$W" pack "$W/s.sh" kit:a)" 64 "[refuse] a kit: target: rc 64"
  eq "$(bt "$P" "$W" pack "$W/s.sh" kind:a)" 64 "[refuse] a kind: target: rc 64"
  eq "$(bt "$P" "$W" pack "$W/s.sh" lib:a)" 64 "[refuse] an unknown prefix: rc 64"
  eq "$(bt "$P" "$W" pack "$W/s.sh" user:merge-pr)" 64 "[refuse] a name a kit ships: rc 64"
  eq "$(bt "$P" "$W" pack "$W/s.sh" user:install-file)" 64 "[refuse] a name a callable kind ships: rc 64"
  eq "$(bt "$P" "$W" pack "$W/s.sh" user:deploy-v2)" 64 "[refuse] a copy name -v<digits>: rc 64"
  eq "$(bt "$P" "$W" pack "$W/s.sh" user:deploy-1a2b3c4)" 64 "[refuse] a copy name -<7 hex>: rc 64"
  eq "$(bt "$P" "$W" pack "$W/s.sh" user:deploy-1a2b3c)" 0 "[refuse] …six hex is not a copy name: rc 0"
  eq "$(bt "$P" "$W" pack "$W/s.sh" user:Bad)" 64 "[refuse] a name outside [a-z0-9-]: rc 64"
  eq "$(bt "$P" "$W" pack "$W/s.sh" $'user:merge-pr\n')" 64 "[refuse] a name ending in a newline: rc 64"
  eq "$(bt "$P" "$W" pack "$W/s.sh" $'user:zz\n')" 64 "[refuse] …any name ending in a newline: rc 64"
  eq "$(bt "$P" "$W" go $'user:zz\n' "$(D "$W")")" 64 "[refuse] …and go refuses one too: rc 64"
  eq "$(bt "$P" "$W" pack kit:merge-pr user:mp)" 64 "[refuse] a kit: source: rc 64"
  eq "$(bt "$P" "$W" pack "$W/s.sh")" 64 "[refuse] no target: rc 64"
  eq "$(bt "$P" "$W" pack --retire user:x)" 64 "[refuse] --retire without a sha: rc 64"
  eq "$(bt "$P" "$W" pack --retire user:x abc)" 64 "[refuse] --retire with a bad sha: rc 64"
  ls "$(lib)" 2>/dev/null | grep -qv '^deploy-1a2b3c.sh$' && bad "[refuse] …nothing else was written" || ok "[refuse] …nothing else was written"
  # check, as the target place checks it
  python3 "$FX" make "$P" "$W/n.sh" "none" "the file"; okrun "$P" "$W" "$W/n.sh" >/dev/null
  eq "$(bt "$P" "$W" pack "$W/n.sh" user:n)" 1 "[refuse] a fixed-value script (Params: none): rc 1"
  has "$(out)" "declares Params with at least one key" "[refuse] …check names why"
  python3 "$FX" make "$P" "$W/q.sh" "dest=path" "the file named by dest"; okrun "$P" "$W" "$W/q.sh" >/dev/null
  eq "$(bt "$P" "$W" pack "$W/q.sh" user:q)" 1 "[refuse] prose Targets: rc 1"
  [ ! -e "$(lib)/n.sh" ] && [ ! -e "$(lib)/q.sh" ] && ok "[refuse] …nothing written" || bad "[refuse] …nothing written"
  # the source
  eq "$(bt "$P" "$W" pack "$W/none.sh" user:z)" 66 "[refuse] a source that does not exist: rc 66"
  mkfifo "$W/fifo"
  eq "$(wrun 10 "$W" pack "$W/fifo" user:f)" 66 \
     "[refuse] a FIFO source: rc 66, no hang"
  { cat "$W/s.sh"; head -c 270000 /dev/zero | tr '\0' '#'; echo; } > "$W/big.sh"
  eq "$(bt "$P" "$W" pack "$W/big.sh" user:big)" 66 "[refuse] a source over 256 KiB: rc 66"
  # places
  T=$(fresh); eq "$(bt "$P" "$T" pack "$W/s.sh" project:a)" 66 "[refuse] project: with no project root: rc 66"
  R=$(fresh); repo "$R"; mkdir -p "$R/.vibemaestro/batons"; chmod 775 "$R/.vibemaestro/batons"
  eq "$(bt "$P" "$R" pack "$W/s.sh" project:a)" 3 "[refuse] a project place others can write: rc 3"
  chmod 755 "$R/.vibemaestro/batons"; rmdir "$R/.vibemaestro/batons"; T=$(fresh); ln -s "$T" "$R/.vibemaestro/batons"
  eq "$(bt "$P" "$R" pack "$W/s.sh" project:a)" 64 "[refuse] a symlinked place directory: rc 64"
  [ -z "$(ls "$T")" ] && ok "[refuse] …nothing written where it led" || bad "[refuse] …nothing written where it led"
  # a symlinked parent of the place: refused, and nothing is made where it leads
  R=$(fresh); repo "$R"; T=$(fresh); ln -s "$T" "$R/.vibemaestro"
  eq "$(bt "$P" "$R" pack "$W/s.sh" project:a)" 64 "[refuse] a symlinked .vibemaestro: rc 64"
  [ -z "$(ls -A "$T")" ] && ok "[refuse] …nothing made where the parent link leads" || bad "[refuse] …nothing made where the parent link leads"
  local XD0=$XD; XD=$(fresh); T=$(fresh); ln -s "$T" "$XD/vibemaestro"; mk "$P" "$W/ll.sh" "# ll"; okrun "$P" "$W" "$W/ll.sh" >/dev/null
  eq "$(bt "$P" "$W" pack "$W/ll.sh" user:ll)" 64 "[refuse] a symlinked library parent: rc 64"
  [ -z "$(ls -A "$T")" ] && ok "[refuse] …nothing made where the library link leads" || bad "[refuse] …nothing made where the library link leads"
  XD=$XD0
  # a rename that fails leaves no temporary copy
  mk "$P" "$W/dd.sh" "# dd"; okrun "$P" "$W" "$W/dd.sh" >/dev/null; mkdir -p "$(lib)/dd.sh/x"
  eq "$(bt "$P" "$W" pack "$W/dd.sh" user:dd)" 2 "[refuse] the target is a directory: rc 2"
  [ -z "$(ls -A "$(lib)" | grep pack-)" ] && ok "[refuse] …a failed rename leaves no temporary file" || bad "[refuse] …a failed rename leaves no temporary file"
  rm -rf "$(lib)/dd.sh"
  eq "$(px "$P" "$W" nospace "$P" "$W/dd.sh" user:dd)" 0 "[refuse] the nospace fixture ran"
  has "$(out)" "rc 2" "[refuse] a write that fails (ENOSPC): rc 2"
  [ -z "$(ls -A "$(lib)" | grep pack-)" ] && ok "[refuse] …a failed write leaves no temporary file" || bad "[refuse] …a failed write leaves no temporary file"
  # a place message carries the root escaped: a directory name cannot forge a line
  R="$(fresh)/x"$'\n''owner: FORGED'; mkdir -p "$R"; repo "$R"; T=$(fresh); ln -s "$T" "$R/.vibemaestro"
  eq "$(bt "$P" "$R" pack "$W/s.sh" project:a)" 64 "[refuse] a link under a root whose name holds a newline: rc 64"
  eq "$(grep -c '^owner: FORGED' "$BT_OUT")" 0 "[refuse] …the root is escaped: no forged line"
  # an error that is not a link says what it is
  if [ "$(id -u)" != 0 ]; then
    XD0=$XD; XD=$(fresh); mkdir -p "$XD/vibemaestro"; chmod 000 "$XD/vibemaestro"
    eq "$(bt "$P" "$W" pack "$W/ll.sh" user:ll)" 2 "[refuse] a place level it may not open: rc 2"
    has "$(out)" "Permission denied" "[refuse] …named as such, not as a link"
    chmod 755 "$XD/vibemaestro"; XD=$XD0
  else
    ok "[refuse] a place level it may not open: rc 2 (root: not tested)"; ok "[refuse] …named as such, not as a link (root: not tested)"
  fi
  # a target that is a symlink is replaced, never followed
  T=$(fresh); echo keep-me > "$T/victim"; ln -s "$T/victim" "$(lib)/l.sh"; mk "$P" "$W/l.sh" "# l"; okrun "$P" "$W" "$W/l.sh" >/dev/null
  eq "$(bt "$P" "$W" pack "$W/l.sh" user:l)" 0 "[refuse] a target file that is a symlink: rc 0"
  eq "$(cat "$T/victim")" keep-me "[refuse] …a symlinked target is replaced, the file it led to unchanged"
  [ -f "$(lib)/l.sh" ] && [ ! -L "$(lib)/l.sh" ] && ok "[refuse] …the target is now a regular file" || bad "[refuse] …the target is now a regular file"
}
# wrun <seconds> <dir> <baton args...> — baton from <dir> in the suite's environment, bounded; prints its rc or "timeout"
wrun() { local s=$1 d=$2; shift 2; within "$s" env -i PATH="$PATH" HOME="$HOME" TMPDIR="$TMPDIR" XDG_STATE_HOME="$ST" XDG_DATA_HOME="$XD" \
  CLAUDE_CODE_SESSION_ID="$OWNER_SID" bash -c 'cd "$0" && exec python3 "$@"' "$d" "$P/scripts/baton.py" "$@"; }
within() {
  python3 -c 'import subprocess, sys
try:
    print(subprocess.run(sys.argv[2:], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=float(sys.argv[1])).returncode)
except subprocess.TimeoutExpired:
    print("timeout")' "$@"
}

# ── the ok run (A2, P2): these bytes, logged on this machine's baton log, nothing else ─────────────────────────────────────────
fam_okrun() {
  local P=$1 A R S2 o; setup "$P"; mk "$P" "$W/s.sh"
  eq "$(bt "$P" "$W" pack "$W/s.sh" user:a)" 3 "[okrun] no ok run of these bytes: rc 3"
  has "$(out)" "no ok run" "[okrun] …named"
  okrun "$P" "$W" "$W/s.sh" >/dev/null; echo '# edited after the run' >> "$W/s.sh"
  eq "$(bt "$P" "$W" pack "$W/s.sh" user:a)" 3 "[okrun] the source changed after its ok run: rc 3"
  [ ! -e "$(lib)/a.sh" ] && ok "[okrun] …nothing written" || bad "[okrun] …nothing written"
  A=$(shaf "$W/s.sh")
  # claims that are not this machine's log: a record, a log elsewhere, another state's log, a failed run, an old 12-field line
  mkdir -p "$(bdir)/kept/project-0123456789abcdef/a"; printf '{"sha256": "%s", "ok_runs": 5, "kept_by": "local", "kept_at": "2026-10-24T08:00:00Z"}\n' "$A" \
    > "$(bdir)/kept/project-0123456789abcdef/a/000001.json"
  printf '%s\trun\t-\t-\t-\t-\t-\t-\t-\tok\t-\t-\tscratch@%s\n' "2026-10-24T08:00:00Z" "$A" > "$W/log.tsv"
  mkdir -p "$W/.vibemaestro"; cp "$W/log.tsv" "$W/.vibemaestro/log.tsv"
  S2="$(fresh)/state"; o=$(fresh)
  ( cd "$W" && cenv XDG_STATE_HOME="$S2" XDG_DATA_HOME="$XD" python3 "$P/scripts/baton.py" mode auto >/dev/null 2>&1
    cenv XDG_STATE_HOME="$S2" XDG_DATA_HOME="$XD" python3 "$P/scripts/baton.py" go "$W/s.sh" "$(D "$o")" >/dev/null 2>&1 )
  printf '%s\trun\t-\t-\t-\t-\t-\t-\t-\tfailed\t-\t-\tscratch@%s\n' "2026-10-24T08:00:00Z" "$A" >> "$(bdir)/log.tsv"
  printf '%s\trun\t-\t-\t-\t-\t-\t-\t-\tok\t-\t-\n' "2026-10-24T08:00:00Z" >> "$(bdir)/log.tsv"
  printf '%s\tgo\t-\t-\t-\t-\t-\t-\t-\tok\t-\t-\tscratch@%s\n' "2026-10-24T08:00:00Z" "$A" >> "$(bdir)/log.tsv"
  eq "$(bt "$P" "$W" pack "$W/s.sh" user:a)" 3 "[okrun] only this machine's baton log counts: a record's claim, a log.tsv beside the baton, another state's ok run, a failed run, a go line: rc 3"
  echo "# ok_run scratch@$A" >> "$W/s.sh"
  eq "$(bt "$P" "$W" pack "$W/s.sh" user:a)" 3 "[okrun] …nor a claim inside the file"
  sed -i '$d' "$W/s.sh"; okrun "$P" "$W" "$W/s.sh" >/dev/null
  eq "$(bt "$P" "$W" pack "$W/s.sh" user:a)" 0 "[okrun] an ok run of the bytes as they are now: rc 0"
  eq "$(shaf "$(lib)/a.sh")" "$A" "[okrun] …the bytes written are the bytes that ran"
}

# ── the same bytes under another name (A3) ────────────────────────────────────────────────────────────────────────────────────
fam_copy() {
  local P=$1 A R; setup "$P"; mk "$P" "$W/s.sh"; A=$(shaf "$W/s.sh"); okrun "$P" "$W" "$W/s.sh" >/dev/null
  bt "$P" "$W" pack "$W/s.sh" user:a >/dev/null
  eq "$(bt "$P" "$W" pack "$W/s.sh" user:b)" 3 "[copy] the same bytes under another name: rc 3"
  has "$(out)" "user:a" "[copy] …names the name that holds them"
  [ ! -e "$(lib)/b.sh" ] && ok "[copy] …nothing written" || bad "[copy] …nothing written"
  mk "$P" "$W/t.sh" "# t"; okrun "$P" "$W" "$W/t.sh" >/dev/null; cp "$W/t.sh" "$(lib)/c.sh"
  eq "$(bt "$P" "$W" pack "$W/t.sh" user:d)" 3 "[copy] another name's file holds the bytes, never kept: rc 3"
  rm -f "$(lib)/c.sh"
  mk "$P" "$W/e2.sh" "# e2"; okrun "$P" "$W" "$W/e2.sh" >/dev/null; bt "$P" "$W" pack "$W/e2.sh" user:a >/dev/null
  eq "$(bt "$P" "$W" pack "$W/s.sh" user:b)" 3 "[copy] an older keep of another name, not retired, holds them: rc 3"
  eq "$(bt "$P" "$W" pack --retire user:a "$A")" 0 "[copy] retire that sha: rc 0"
  eq "$(bt "$P" "$W" pack "$W/s.sh" user:b)" 0 "[copy] …then the bytes pack under the other name: rc 0"
  mk "$P" "$W/f.sh" "# f"; A=$(shaf "$W/f.sh"); okrun "$P" "$W" "$W/f.sh" >/dev/null; bt "$P" "$W" pack "$W/f.sh" user:f1 >/dev/null
  bt "$P" "$W" pack --retire user:f1 "$A" >/dev/null
  eq "$(bt "$P" "$W" pack "$W/f.sh" user:f2)" 0 "[copy] retiring a sha frees it while the old file still holds it: rc 0"
  # two names packed at once: the copy check and the write are one step in the place
  mk "$P" "$W/g.sh" "# g"; okrun "$P" "$W" "$W/g.sh" >/dev/null
  px "$P" "$W" slow "$P" keep_refusal 1 pack "$W/g.sh" user:g1 > "$TMP/g1.out" &
  px "$P" "$W" slow "$P" keep_refusal 1 pack "$W/g.sh" user:g2 > "$TMP/g2.out" &
  wait
  eq "$(ls "$(lib)" | grep -c -E '^g[12]\.sh$')" 1 "[copy] two names packed at once with the same bytes: only one lands"
  R=$(fresh); repo "$R"; okrun "$P" "$R" "$W/s.sh" >/dev/null
  eq "$(bt "$P" "$R" pack "$W/s.sh" project:b)" 0 "[copy] the same bytes in another place: rc 0 (the binding differs)"
}

# ── a sandbox (INTENT_SLUG and SEAT both set): project: by default, never user:, and a stop-list baton that stopped for the owner ─
fam_sandbox() {
  local P=$1 R K A B o; setup "$P"; R=$(fresh); repo "$R"; K=$(pkey "$R")
  mk "$P" "$W/s.sh"; A=$(shaf "$W/s.sh"); okrun "$P" "$W" "$W/s.sh" >/dev/null
  BT_ENV=(SEAT=seat-1 INTENT_SLUG=2026-10-25-x)
  eq "$(bt "$P" "$R" pack "$W/s.sh" s)" 0 "[sandbox] a bare name keeps project:<name>: rc 0"
  has "$(out)" "kept project:s (new)" "[sandbox] …as project:s"
  has "$(out)" "project: (a sandbox keeps to project:)" "[sandbox] …and says it chose project: because this is a sandbox"
  [ -f "$R/.vibemaestro/batons/s.sh" ] && ok "[sandbox] …the file is in <root>/.vibemaestro/batons" || bad "[sandbox] …the file is in <root>/.vibemaestro/batons"
  eq "$(nrecs "$K" s)" 1 "[sandbox] …one keep record under the repository's place key"
  mk "$P" "$W/u.sh" "# u"; okrun "$P" "$W" "$W/u.sh" >/dev/null
  eq "$(bt "$P" "$R" pack "$W/u.sh" user:u)" 64 "[sandbox] a user: target in a sandbox: rc 64"
  has "$(out)" "project:u" "[sandbox] …the refusal says to use project:u"
  [ ! -e "$(lib)/u.sh" ] && ok "[sandbox] …nothing written to the library" || bad "[sandbox] …nothing written to the library"
  eq "$(nrecs user u)" 0 "[sandbox] …and no user: record"
  eq "$(bt "$P" "$R" pack project:s user:s)" 64 "[sandbox] a move to user: in a sandbox: rc 64"
  [ -f "$R/.vibemaestro/batons/s.sh" ] && ok "[sandbox] …the project file stays" || bad "[sandbox] …the project file stays"
  eq "$(bt "$P" "$R" pack "$W/u.sh" "user:")" 64 "[sandbox] user: with no name: rc 64"
  BT_ENV=(SEAT= INTENT_SLUG=2026-10-25-x)
  eq "$(bt "$P" "$R" pack "$W/u.sh" u)" 64 "[sandbox] SEAT empty is no sandbox: a bare name: rc 64"
  eq "$(bt "$P" "$R" pack "$W/u.sh" user:u)" 0 "[sandbox] …and user: keeps: rc 0"
  BT_ENV=(SEAT=seat-1 INTENT_SLUG=' ')
  eq "$(bt "$P" "$R" pack "$W/u.sh" u2)" 64 "[sandbox] INTENT_SLUG blank is no sandbox: a bare name: rc 64"
  # a stop-list baton: no ok run in a pod; go to the owner's card, then pack it as project:
  BT_ENV=(SEAT=seat-1 INTENT_SLUG=2026-10-25-x)
  mk "$P" "$W/p.sh" "# p"; sed -i 's/^# Stops: none$/# Stops: publish/' "$W/p.sh"; B=$(shaf "$W/p.sh")
  eq "$(bt "$P" "$R" pack "$W/p.sh" p)" 3 "[sandbox] a stop-list baton before go: rc 3 (no ok run, no stop for the owner)"
  has "$(out)" "a stop-list baton packs as project: once go has stopped for the owner" "[sandbox] …the refusal points a stop-list baton to go's stop"
  o=$(fresh); eq "$(bt "$P" "$R" go "$W/p.sh" "$(D "$o")")" 8 "[sandbox] go of the stop-list baton stops for the owner: rc 8"
  eq "$(grep -c "	go	.*	owner	.*scratch@$B" "$(bdir)/log.tsv")" 1 "[sandbox] …and logs one go owner line binding its sha256"
  BT_ENV=()
  eq "$(bt "$P" "$R" pack "$W/p.sh" project:p)" 3 "[sandbox] outside a sandbox that line is no ok run: rc 3"
  BT_ENV=(SEAT=seat-1 INTENT_SLUG=2026-10-25-x)
  eq "$(bt "$P" "$R" pack "$W/p.sh" user:p)" 64 "[sandbox] …to user: in a sandbox: rc 64"
  eq "$(bt "$P" "$R" pack "$W/p.sh" p)" 0 "[sandbox] the stop-list baton packs as project:p after go stopped for the owner: rc 0"
  has "$(out)" "not run: stop-list, the owner signs after merge" "[sandbox] …the line says it has not run"
  eq "$(newest "$K" p | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha256"])')" "$B" "[sandbox] …its keep record pins those bytes"
  o=$(fresh); eq "$(bt "$P" "$R" go project:p "$(D "$o")")" 8 "[sandbox] a call of project:p in the pod still stops for the owner: rc 8"
  [ -z "$(ls -A "$o")" ] && ok "[sandbox] …nothing ran" || bad "[sandbox] …nothing ran"
  mk "$P" "$W/p2.sh" "# p2"; sed -i 's/^# Stops: none$/# Stops: publish/' "$W/p2.sh"; o=$(fresh)
  bt "$P" "$R" go "$W/p2.sh" "$(D "$o")" >/dev/null; echo '# changed after go' >> "$W/p2.sh"
  eq "$(bt "$P" "$R" pack "$W/p2.sh" p2)" 3 "[sandbox] bytes changed after go stopped for the owner: rc 3"
  # the line is written only for a stop from the Stops list: a Stops: none baton stopped by mode manual gets none
  baton_set_mode "$ST" manual                                     # setup: in a pod no dialog changes the mode
  mk "$P" "$W/m.sh" "# m"; A=$(shaf "$W/m.sh"); o=$(fresh)
  eq "$(bt "$P" "$R" go "$W/m.sh" "$(D "$o")")" 8 "[sandbox] mode manual: a Stops: none baton stops for the owner: rc 8"
  eq "$(grep -c "	go	.*	owner	.*@$A" "$(bdir)/log.tsv")" 0 "[sandbox] …and logs no go owner line"
  eq "$(bt "$P" "$R" pack "$W/m.sh" m)" 3 "[sandbox] …so it does not pack: rc 3"
  hasnt "$(out)" "a stop-list baton packs" "[sandbox] …and the refusal of a Stops: none baton does not point to the stop-list path"
  bt "$P" "$W" mode auto >/dev/null
  # outside a sandbox, go writes no line for a stop-list baton
  BT_ENV=(); mk "$P" "$W/q.sh" "# q"; sed -i 's/^# Stops: none$/# Stops: publish/' "$W/q.sh"; A=$(shaf "$W/q.sh"); o=$(fresh)
  eq "$(bt "$P" "$R" go "$W/q.sh" "$(D "$o")")" 8 "[sandbox] outside a sandbox the stop-list baton stops for the owner: rc 8"
  eq "$(grep -c "	go	.*	owner	.*@$A" "$(bdir)/log.tsv")" 0 "[sandbox] …and logs no go owner line"
  BT_ENV=(SEAT=seat-1 INTENT_SLUG=2026-10-25-x)
  eq "$(bt "$P" "$R" pack "$W/q.sh" q)" 3 "[sandbox] …so a pack in a sandbox later is refused: rc 3"
  BT_ENV=()
}

# ── a Stops word changed (A8) ─────────────────────────────────────────────────────────────────────────────────────────────────
fam_stops() {
  local P=$1 o; setup "$P"; mk "$P" "$W/s.sh"; okrun "$P" "$W" "$W/s.sh" >/dev/null; bt "$P" "$W" pack "$W/s.sh" user:s >/dev/null
  mk "$P" "$W/t.sh" "# v2"; sed -i 's/^# Stops: none$/# Stops: publish/' "$W/t.sh"; o=$(fresh)
  sg "$P" "$W" owner "$W/t.sh" "$(D "$o")" >/dev/null
  eq "$(bt "$P" "$W" run "$W/t.sh" "$(D "$o")")" 0 "[stops] the Stops: publish version runs ok, signed by the owner"
  eq "$(bt "$P" "$W" pack "$W/t.sh" user:s)" 3 "[stops] a Stops word changed: rc 3"
  has "$(out)" "Stops" "[stops] …named"
  eq "$(nrecs user s)" 1 "[stops] …no record written"
  mk "$P" "$(lib)/old.sh" "# a library file of today"; sed -i 's/^# Stops: none$/# Stops: publish/' "$(lib)/old.sh"
  mk "$P" "$W/o.sh" "# old v2"; okrun "$P" "$W" "$W/o.sh" >/dev/null
  eq "$(bt "$P" "$W" pack "$W/o.sh" user:old)" 3 "[stops] a library file with other Stops and no record: rc 3"
  mk "$P" "$W/r.sh" "# reordered"; sed -i 's/^# Stops: none$/# Stops: publish, secrets/' "$W/r.sh"; o=$(fresh)
  sg "$P" "$W" owner "$W/r.sh" "$(D "$o")" >/dev/null; bt "$P" "$W" run "$W/r.sh" "$(D "$o")" >/dev/null
  bt "$P" "$W" pack "$W/r.sh" user:r >/dev/null
  mk "$P" "$W/r2.sh" "# reordered v2"; sed -i 's/^# Stops: none$/# Stops: secrets, publish/' "$W/r2.sh"; o=$(fresh)
  sg "$P" "$W" owner "$W/r2.sh" "$(D "$o")" >/dev/null; bt "$P" "$W" run "$W/r2.sh" "$(D "$o")" >/dev/null
  eq "$(bt "$P" "$W" pack "$W/r2.sh" user:r)" 0 "[stops] the same Stops words in another order: rc 0"
}

# ── evolving (A4, A7) ─────────────────────────────────────────────────────────────────────────────────────────────────────────
fam_evolve() {
  local P=$1 A B R o seal; setup "$P"; mk "$P" "$W/s.sh"; A=$(shaf "$W/s.sh"); okrun "$P" "$W" "$W/s.sh" >/dev/null
  bt "$P" "$W" pack "$W/s.sh" user:w >/dev/null
  mk "$P" "$W/t.sh" "# v2"; B=$(shaf "$W/t.sh"); okrun "$P" "$W" "$W/t.sh" >/dev/null
  eq "$(bt "$P" "$W" pack "$W/t.sh" user:w)" 0 "[evolve] pack a new version under the same name: rc 0"
  has "$(out)" "owner: kept user:w (was ${A:0:12})" "[evolve] …the owner: line says was <old sha12>"
  has "$(out)" "changed: none — body +1 -0 lines" "[evolve] …what changed against the file replaced"
  eq "$(newest user w | python3 -c 'import json,sys; print(json.load(sys.stdin)["prev_sha256"])')" "$A" "[evolve] …prev_sha256 is the sha pinned before"
  o=$(fresh); eq "$(bt "$P" "$W" go user:w "$(D "$o")")" 0 "[evolve] the new version runs"
  cp "$W/s.sh" "$(lib)/w.sh"; o=$(fresh)
  eq "$(bt "$P" "$W" go user:w "$(D "$o")")" 3 "[evolve] a library file written back to an older version: rc 3"
  has "$(out)" "was kept with sha256 $B" "[evolve] …the refusal names the newest kept sha"
  # A7 (i): a call signed at the old version, then the name evolves: the signed call does not run
  cp "$W/t.sh" "$(lib)/w.sh"; mk "$P" "$W/u.sh" "# v3"; okrun "$P" "$W" "$W/u.sh" >/dev/null; o=$(fresh)
  sg "$P" "$W" coordinator-auto user:w "$(D "$o")" >/dev/null
  bt "$P" "$W" pack "$W/u.sh" user:w >/dev/null; cp "$W/t.sh" "$(lib)/w.sh"
  eq "$(bt "$P" "$W" run user:w "$(D "$o")")" 3 "[evolve] signed at the old version, evolved before the run: rc 3"
  [ ! -e "$o/x" ] && ok "[evolve] …nothing ran" || bad "[evolve] …nothing ran"
  # A7 (ii): the old bytes kept in a project stay callable there while user: moved on
  R=$(fresh); repo "$R"; okrun "$P" "$R" "$W/s.sh" >/dev/null
  eq "$(bt "$P" "$R" pack "$W/s.sh" project:w)" 0 "[evolve] the first version kept as project:w"
  o=$(fresh); eq "$(bt "$P" "$R" go project:w "$(D "$o")")" 0 "[evolve] …project:w at the old sha runs while user:w moved on"
  cp "$W/s.sh" "$(lib)/w.sh"; o=$(fresh)
  eq "$(bt "$P" "$R" go user:w "$(D "$o")")" 3 "[evolve] …and user:w at that sha is refused"
}

# ── retire (A5) ───────────────────────────────────────────────────────────────────────────────────────────────────────────────
fam_retire() {
  local P=$1 A R K o; setup "$P"; R=$(fresh); repo "$R"; K=$(pkey "$R"); mk "$P" "$R/s.sh"; A=$(shaf "$R/s.sh")
  okrun "$P" "$R" "$R/s.sh" >/dev/null; bt "$P" "$R" pack "$R/s.sh" project:r >/dev/null
  eq "$(bt "$P" "$R" pack --retire project:r "$A")" 0 "[retire] --retire project:r <sha>: rc 0"
  eq "$(newest "$K" r | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r["retired"], " ".join(sorted(r)))')" \
     "$A kept_at kept_by retired" "[retire] …a retire record: retired, kept_by, kept_at"
  eq "$(lastlog | cut -f2,13 | tr '\t' ' ')" "retire project:r@$A" "[retire] …the event retire is logged"
  [ -f "$R/.vibemaestro/batons/r.sh" ] && ok "[retire] …the file stays" || bad "[retire] …the file stays"
  o=$(fresh); eq "$(bt "$P" "$R" go project:r "$(D "$o")")" 3 "[retire] a retired sha: go rc 3"
  has "$(out)" "these bytes were retired" "[retire] …named"
  bt "$P" "$R" list project:r >/dev/null; has "$(out)" "retired" "[retire] list marks it retired"
  eq "$(bt "$P" "$R" pack --retire project:r "$A")" 0 "[retire] retiring it again: rc 0"
  has "$(out)" "already retired" "[retire] …already retired, nothing written"
  eq "$(nrecs "$K" r)" 2 "[retire] …still two records"
  eq "$(bt "$P" "$R" pack --retire project:r "$(printf 'e%.0s' $(seq 64))")" 66 "[retire] a sha no keep record names: rc 66"
  eq "$(bt "$P" "$R" pack "$R/s.sh" project:r)" 0 "[retire] packing the retired sha again: rc 0"
  o=$(fresh); eq "$(bt "$P" "$R" go project:r "$(D "$o")")" 0 "[retire] …pins it again"
  mk "$P" "$W/u.sh"; okrun "$P" "$W" "$W/u.sh" >/dev/null; bt "$P" "$W" pack "$W/u.sh" user:u >/dev/null
  eq "$(bt "$P" "$W" pack --retire user:u "$(shaf "$W/u.sh")")" 0 "[retire] retire the newest user: keep: rc 0"
  o=$(fresh); eq "$(bt "$P" "$W" go user:u "$(D "$o")")" 3 "[retire] …the user: name is unpinned"
}

# ── moves between places (A6) ─────────────────────────────────────────────────────────────────────────────────────────────────
fam_move() {
  local P=$1 A R K o; setup "$P"; R=$(fresh); repo "$R"; K=$(pkey "$R"); mk "$P" "$W/s.sh"; A=$(shaf "$W/s.sh")
  okrun "$P" "$W" "$W/s.sh" >/dev/null; bt "$P" "$W" pack "$W/s.sh" user:m >/dev/null
  eq "$(bt "$P" "$R" pack user:m user:n)" 64 "[move] a move inside one place: rc 64"
  eq "$(bt "$P" "$R" pack user:m project:m)" 0 "[move] user:m to project:m: rc 0"
  [ ! -e "$(lib)/m.sh" ] && ok "[move] a move that leaves no source" || bad "[move] a move that leaves no source"
  eq "$(shaf "$R/.vibemaestro/batons/m.sh")" "$A" "[move] …the target holds the bytes"
  eq "$(newest user m | python3 -c 'import json,sys; print(json.load(sys.stdin).get("retired"))')" "$A" "[move] …the source sha is retired"
  eq "$(lastlog | cut -f2,10 | tr '\t' ' ')" "pack moved" "[move] …logged pack, moved"
  o=$(fresh); eq "$(bt "$P" "$R" go project:m "$(D "$o")")" 0 "[move] …the target runs"
  cp "$R/.vibemaestro/batons/m.sh" "$(lib)/m.sh"; o=$(fresh)
  eq "$(bt "$P" "$R" go user:m "$(D "$o")")" 3 "[move] …a restored source file is not pinned again"
  rm -f "$(lib)/m.sh"
  eq "$(bt "$P" "$R" pack user:m project:m)" 66 "[move] the source gone: rc 66"
  # a move cut after the target is kept: both pinned, the re-run finishes
  mk "$P" "$W/c.sh" "# c"; A=$(shaf "$W/c.sh"); okrun "$P" "$W" "$W/c.sh" >/dev/null; bt "$P" "$W" pack "$W/c.sh" user:c >/dev/null
  px "$P" "$R" cut "$P" after-target user:c project:c >/dev/null
  [ -f "$(lib)/c.sh" ] && [ -f "$R/.vibemaestro/batons/c.sh" ] && ok "[move] cut after the target: both files there" || bad "[move] cut after the target: both files there"
  bt "$P" "$R" list user:c >/dev/null; has "$(out)" "copy of" "[move] …list marks the second one a copy"
  eq "$(bt "$P" "$R" pack user:c project:c)" 0 "[move] …the same command again: rc 0"
  [ ! -e "$(lib)/c.sh" ] && ok "[move] …the re-run removes the source" || bad "[move] …the re-run removes the source"
  eq "$(nrecs "$K" c)" 1 "[move] …and keeps one target record"
  # a move cut after the source is retired: the re-run removes the file
  mk "$P" "$W/d.sh" "# d"; okrun "$P" "$W" "$W/d.sh" >/dev/null; bt "$P" "$W" pack "$W/d.sh" user:d >/dev/null
  px "$P" "$R" cut "$P" after-retire user:d project:d >/dev/null
  [ -f "$(lib)/d.sh" ] && ok "[move] cut after the retire: the source file is still there" || bad "[move] cut after the retire: the source file is still there"
  eq "$(bt "$P" "$R" pack user:d project:d)" 0 "[move] after a cut after the retire, the re-run finishes: rc 0"
  [ ! -e "$(lib)/d.sh" ] && ok "[move] …the source removed" || bad "[move] …the source removed"
  o=$(fresh); eq "$(bt "$P" "$R" go project:d "$(D "$o")")" 0 "[move] …the target runs"
  # an unpinned source is not moved
  mk "$P" "$(lib)/e.sh" "# e, never kept"
  eq "$(bt "$P" "$R" pack user:e project:e)" 3 "[move] an unpinned source: rc 3"
  [ ! -e "$R/.vibemaestro/batons/e.sh" ] && ok "[move] …nothing written" || bad "[move] …nothing written"
  # two opposite moves at once: one waits, and one copy stays callable
  mk "$P" "$W/h.sh" "# h"; okrun "$P" "$W" "$W/h.sh" >/dev/null; bt "$P" "$W" pack "$W/h.sh" user:h >/dev/null
  okrun "$P" "$R" "$W/h.sh" >/dev/null; bt "$P" "$R" pack "$W/h.sh" project:h >/dev/null
  px "$P" "$R" slow "$P" pack_target 1 pack user:h project:h > "$TMP/h1.out" &
  px "$P" "$R" slow "$P" pack_target 1 pack project:h user:h > "$TMP/h2.out" &
  wait
  local n=0; o=$(fresh); [ "$(bt "$P" "$R" go user:h "$(D "$o")")" = 0 ] && n=$((n+1))
  o=$(fresh); [ "$(bt "$P" "$R" go project:h "$(D "$o")")" = 0 ] && n=$((n+1))
  eq "$n" 1 "[move] two opposite moves at once: exactly one copy stays callable"
  # a move whose source was retired on purpose says so
  mk "$P" "$W/j.sh" "# j"; okrun "$P" "$W" "$W/j.sh" >/dev/null; bt "$P" "$W" pack "$W/j.sh" user:j >/dev/null
  bt "$P" "$R" pack "$W/j.sh" project:j >/dev/null; bt "$P" "$R" pack --retire user:j "$(shaf "$W/j.sh")" >/dev/null
  eq "$(bt "$P" "$R" pack user:j project:j)" 0 "[move] a source already retired, its bytes kept at the target: rc 0"
  has "$(out)" "was already retired" "[move] …the message says the source was already retired"
  # project: to user:, from a repository
  eq "$(bt "$P" "$R" pack project:d user:d)" 0 "[move] project:d back to user:d: rc 0"
  has "$(out)" "owner: kept user:d" "[move] …a move into user: prints the owner: line"
  [ ! -e "$R/.vibemaestro/batons/d.sh" ] && ok "[move] …the project file removed" || bad "[move] …the project file removed"
}

# ── parallel packs, the lock, the sequence number (A1, P1) ───────────────────────────────────────────────────────────────────
fam_parallel() {
  local P=$1 X Y i n f pid lock o; setup "$P"; mk "$P" "$W/x.sh" "# X"; mk "$P" "$W/y.sh" "# Y"
  X=$(shaf "$W/x.sh"); Y=$(shaf "$W/y.sh"); okrun "$P" "$W" "$W/x.sh" >/dev/null; okrun "$P" "$W" "$W/y.sh" >/dev/null
  for i in 1 2 3 4 5 6 7 8; do
    f=x; [ $((i % 2)) = 0 ] && f=y
    ( cd "$W" && cenv XDG_STATE_HOME="$ST" XDG_DATA_HOME="$XD" python3 "$P/scripts/baton.py" pack "$W/$f.sh" user:p >/dev/null 2>&1 ) &
  done
  wait
  n=$(recs user p | sort -u | wc -l | tr -d ' ')
  [ "$n" -ge 2 ] && ok "[parallel] 8 packs at once: every keep that changed the pin landed ($n records)" || bad "[parallel] 8 packs at once: every keep that changed the pin landed ($n records)"
  eq "$(shaf "$(lib)/p.sh")" "$(newest user p | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha256"])')" \
     "[parallel] …the file's sha is the newest record's"
  o=$(fresh); eq "$(bt "$P" "$W" go user:p "$(D "$o")")" 0 "[parallel] …go user:p runs"
  # a pack waits while another holds the lock, and lands once it is released
  lock="$(bdir)/kept/user/.lock"; mkdir -p "$(dirname "$lock")"
  mk "$P" "$W/q.sh" "# Q"; okrun "$P" "$W" "$W/q.sh" >/dev/null; mk "$P" "$W/k.sh" "# K"; okrun "$P" "$W" "$W/k.sh" >/dev/null
  mk "$P" "$W/r.sh" "# R"; okrun "$P" "$W" "$W/r.sh" >/dev/null; X=$(shaf "$W/r.sh"); rm -f "$TMP/hold.out"
  python3 "$PX" hold "$lock" 2 > "$TMP/hold.out" & pid=$!
  for i in $(seq 50); do grep -q held "$TMP/hold.out" 2>/dev/null && break; sleep 0.1; done
  ( cd "$W" && cenv XDG_STATE_HOME="$ST" XDG_DATA_HOME="$XD" python3 "$P/scripts/baton.py" pack "$W/q.sh" user:q >/dev/null 2>&1 ) &
  sleep 0.8
  [ ! -e "$(lib)/q.sh" ] && ok "[parallel] a pack waits while another holds the lock" || bad "[parallel] a pack waits while another holds the lock"
  wait
  [ -f "$(lib)/q.sh" ] && ok "[parallel] …and lands once it is released" || bad "[parallel] …and lands once it is released"
  # a lock held past the wait: rc 2, and the message says a lock ends with its process
  rm -f "$TMP/hold.out"; python3 "$PX" hold "$lock" 3 > "$TMP/hold.out" &
  for i in $(seq 50); do grep -q held "$TMP/hold.out" 2>/dev/null && break; sleep 0.1; done
  eq "$(px "$P" "$W" wait "$P" 0.3 "$W/k.sh" user:h)" 0 "[parallel] the wait fixture ran"
  has "$(out)" "rc 2" "[parallel] a lock still held after the wait: rc 2"
  has "$(out)" "a lock ends with the process that holds it" "[parallel] …the message says why it is not stale"
  [ ! -e "$(lib)/h.sh" ] && ok "[parallel] …nothing written" || bad "[parallel] …nothing written"
  wait
  # a pack killed while it holds the lock leaves nothing that wedges the next one
  eq "$(px "$P" "$W" cut "$P" in-lock "$W/k.sh" user:k)" 137 "[parallel] a pack killed while it holds the lock (SIGKILL)"
  [ -e "$lock" ] && ok "[parallel] …its lock file is left behind" || bad "[parallel] …its lock file is left behind"
  eq "$(wrun 10 "$W" pack "$W/k.sh" user:k)" 0 \
     "[parallel] a pack after a killed pack lands at once"
  # a racer takes the next sequence number between the count and the link
  eq "$(px "$P" "$W" race "$P" "$W/r.sh" user:r)" 0 "[parallel] the race fixture ran"
  has "$(out)" "rc 0" "[parallel] …the pack lands: rc 0"
  eq "$(recs user r | tr '\n' ' ')" "000001.json 000002.json " "[parallel] …on the next number"
  eq "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$(bdir)/kept/user/r/000001.json" 2>/dev/null)" racer \
     "[parallel] …the racer's record is intact"
  eq "$(newest user r | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha256"])')" "$X" "[parallel] …and the pack's is the newest"
}

# ── two worktrees, each keeping and running its own version ──────────────────────────────────────────────────────────────────
fam_worktrees() {
  local P=$1 R A B o; setup "$P"; R=$(fresh); repo "$R"; git_ -C "$R" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
  git_ -C "$R" worktree add -q "$R/wt" -b other 2>/dev/null
  mk "$P" "$W/a.sh" "# main"; mk "$P" "$W/b.sh" "# other"; A=$(shaf "$W/a.sh"); B=$(shaf "$W/b.sh")
  okrun "$P" "$R" "$W/a.sh" >/dev/null; okrun "$P" "$R/wt" "$W/b.sh" >/dev/null
  eq "$(bt "$P" "$R" pack "$W/a.sh" project:w)" 0 "[worktrees] the main worktree keeps its version"
  eq "$(bt "$P" "$R/wt" pack "$W/b.sh" project:w)" 0 "[worktrees] the other worktree keeps its own"
  o=$(fresh); eq "$(bt "$P" "$R" go project:w "$(D "$o")")" 0 "[worktrees] two worktrees each running their own kept version: main"
  has "$(lastlog | cut -f13)" "@$A" "[worktrees] …the main worktree's bytes"
  o=$(fresh); eq "$(bt "$P" "$R/wt" go project:w "$(D "$o")")" 0 "[worktrees] …and the other"
  has "$(lastlog | cut -f13)" "@$B" "[worktrees] …the other worktree's bytes"
}

# ── a directory name cannot forge a line: every place message escapes the paths it prints ─────────────────────────────────────
noforge() { [ "$(grep -c '^owner: FORGED' "$BT_OUT")" = 0 ] && ok "$1" || bad "$1 ($(grep -m1 '^owner: FORGED' "$BT_OUT"))"; }
fam_forge() {
  local P=$1 R T X XD0 NL; setup "$P"; mk "$P" "$W/s.sh"; okrun "$P" "$W" "$W/s.sh" >/dev/null; NL=$'\n''owner: FORGED'
  R="$(fresh)/r$NL"; mkdir -p "$R/.vibemaestro"; chmod 777 "$R/.vibemaestro"
  eq "$(bt "$P" "$R" pack "$W/s.sh" project:a)" 3 "[forge] pack in a loose root whose name holds a newline: rc 3"
  noforge "[forge] …no line starts with owner: (pack, a loose root)"
  eq "$(bt "$P" "$R" go project:a "$(D "$W")")" 3 "[forge] …go there: rc 3"
  noforge "[forge] …no line starts with owner: (go, a loose root)"
  chmod 755 "$R/.vibemaestro"
  T="$(fresh)/t$NL"; mkdir -p "$T"
  eq "$(bt "$P" "$T" pack "$W/s.sh" project:a)" 66 "[forge] pack with no project root, from a directory whose name holds a newline: rc 66"
  noforge "[forge] …no line starts with owner: (pack, no root)"
  eq "$(bt "$P" "$T" go project:a "$(D "$W")")" 66 "[forge] …go there: rc 66"
  noforge "[forge] …no line starts with owner: (go, no root)"
  XD0=$XD; XD="$(fresh)/d$NL"; X=$(fresh); mkdir -p "$XD" "$X/batons"; ln -s "$X" "$XD/vibemaestro"
  eq "$(bt "$P" "$W" pack "$W/s.sh" user:zz)" 64 "[forge] pack into a library reached through a link, under a name with a newline: rc 64"
  noforge "[forge] …no line starts with owner: (pack, the place leads elsewhere)"
  eq "$(bt "$P" "$W" go user:zz "$(D "$W")")" 64 "[forge] …go there: rc 64"
  noforge "[forge] …no line starts with owner: (go, the place leads elsewhere)"
  rm "$XD/vibemaestro"; mkdir -p "$(lib)"; ln -s "$W/s.sh" "$(lib)/l.sh"
  eq "$(bt "$P" "$W" go user:l "$(D "$W")")" 64 "[forge] go of a kept file that is a link: rc 64"
  noforge "[forge] …no line starts with owner: (go, a link)"
  eq "$(bt "$P" "$W" go user:none "$(D "$W")")" 66 "[forge] go of a name the library lacks: rc 66"
  noforge "[forge] …no line starts with owner: (go, no such baton)"
  cp "$W/s.sh" "$(lib)/u.sh"
  eq "$(bt "$P" "$W" go user:u "$(D "$W")")" 3 "[forge] go of a file never kept: rc 3"
  noforge "[forge] …no line starts with owner: (go, unpinned)"
  eq "$(bt "$P" "$W" check user:u)" 0 "[forge] check of it: rc 0"
  noforge "[forge] …no line starts with owner: (check ok)"
  rm -f "$(lib)/l.sh"; bt "$P" "$W" pack "$W/s.sh" user:u >/dev/null
  eq "$(bt "$P" "$W" rehearse user:u "$(D "$W")")" 0 "[forge] rehearse of it once kept: rc 0"
  noforge "[forge] …no line starts with owner: (rehearse's header)"
  XD=$XD0
  eq "$(bt "$P" "$W" go $'kit:a\nowner: FORGED')" 64 "[forge] go kit:<a name with a newline>: rc 64"
  noforge "[forge] …no line starts with owner: (kit:)"
  eq "$(bt "$P" "$W" go $'kind:a\nowner: FORGED')" 64 "[forge] go kind:<a name with a newline>: rc 64"
  noforge "[forge] …no line starts with owner: (kind:)"
  eq "$(bt "$P" "$W" pack $'kit:a\nowner: FORGED' user:x)" 64 "[forge] pack from kit:<a name with a newline>: rc 64"
  noforge "[forge] …no line starts with owner: (pack from kit:)"
}

FAMILIES="fam_keep fam_refuse fam_sandbox fam_okrun fam_copy fam_stops fam_evolve fam_retire fam_move fam_parallel fam_worktrees fam_forge"

echo "== the real plugin =="
REAL="$TMP/real"; mk_plugin_copy "$REAL"
for f in $FAMILIES; do echo "-- $f"; "$f" "$REAL"; done

echo "== planted breaks: each family must go red on a copy with one break in baton.py =="
# BRK <label> <family> <needle> <old> <new> [<old> <new>]... — a plugin copy with the replacements in baton.py, then expect_red
BRK() {
  local label=$1 fam=$2 needle=$3 d; shift 3; d="$TMP/break-$label"; mk_plugin_copy "$d"
  while [ $# -ge 2 ]; do mutate "$d/scripts/baton.py" "$1" "$2" || return; shift 2; done
  expect_red "$label" "$fam" "$d" "$needle"
}
BRK sandbox-no-default fam_sandbox '[sandbox] a bare name keeps project:<name>: rc 0' '    if ":" not in word and new and in_sandbox():' '    if False:'
BRK sandbox-user-ok fam_sandbox '[sandbox] a user: target in a sandbox: rc 64' '    if place == "user" and new and in_sandbox():' '    if False:'
BRK owner-stop-anywhere fam_sandbox '[sandbox] outside a sandbox that line is no ok run: rc 3' '    if not (in_sandbox() and t.kept.prefix == "project" and stops_of(t.text) not in (None, "none")):' '    if not (t.kept.prefix == "project" and stops_of(t.text) not in (None, "none")):'
BRK owner-stop-any-sha fam_sandbox '[sandbox] bytes changed after go stopped for the owner: rc 3' '    return any(v.endswith("@" + sha) for v in owner_stops())' '    return bool(owner_stops())'
BRK owner-stop-manual fam_sandbox '[sandbox] …and logs no go owner line' '            if stops and in_sandbox():' '            if in_sandbox():'
BRK owner-stop-outside fam_sandbox '[sandbox] …and logs no go owner line' '            if stops and in_sandbox():' '            if stops:'
BRK hint-never fam_sandbox "[sandbox] …the refusal points a stop-list baton to go's stop" '"has stopped for the owner on these bytes (exit 8)" if in_sandbox()' '"has stopped for the owner on these bytes (exit 8)" if False'
BRK hint-always fam_sandbox '[sandbox] …and the refusal of a Stops: none baton does not point to the stop-list path' '                            stops_of(t.text) not in (None, "none") else "")' '                            True else "")'
BRK no-okrun fam_okrun '[okrun] the source changed after its ok run: rc 3' '    return any(v.endswith("@" + sha) for v in ok_runs())' '    return True'
BRK okrun-any-log fam_okrun '[okrun] only this machine' \
    '                if len(v) == len(LOG_FIELDS) and v[1] == "run" and v[9] == "ok":' '                if len(v) >= len(LOG_FIELDS) - 1 and v[9] == "ok":'
BRK no-copy fam_copy '[copy] the same bytes under another name: rc 3' '    other = copy_holder(kept, sha)' '    other = None'
BRK copy-file-only fam_copy '[copy] an older keep of another name' '        if any(is_keep(r) and r["sha256"] == sha for _q, r in recs):' '        if False:'
BRK retire-not-freeing fam_copy '[copy] retiring a sha frees it while the old file still holds it' '        if retired:
            continue' '        if False:
            continue'
BRK copy-unlocked fam_copy '[copy] two names packed at once with the same bytes: only one lands' '            fds = place_locks(t.kept.key)' '            fds = []'
BRK move-one-lock fam_move '[move] two opposite moves at once: exactly one copy stays callable' \
    '        fds = place_locks(src.kept.key, t.kept.key)' '        fds = place_locks(t.kept.key)'
BRK name-newline fam_refuse '[refuse] a name ending in a newline: rc 64' 'KIT_RE = re.compile(r"^[a-z0-9][a-z0-9-]*\Z")' 'KIT_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")'
BRK parent-followed fam_refuse '[refuse] …nothing made where the parent link leads' \
    '    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)' '    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)'
BRK write-tmp-left fam_refuse '[refuse] …a failed write leaves no temporary file' \
    '        except BaseException:                           # a failed write or rename leaves no copy of the bytes behind' '        except ():'
BRK root-unescaped fam_refuse '[refuse] …the root is escaped: no forged line' \
    '"link", kept.word, part, anchor)' '"link" % (kept.word, part, anchor))'
BRK eacces-as-link fam_refuse '[refuse] a place level it may not open: rc 2' '                if e.errno not in (errno.ELOOP, errno.ENOTDIR):' '                if False:'
BRK restore-silent fam_keep '[keep] …says the file was restored' \
    '            restored = "" if old == data else' '            restored = "" if True else'
BRK loose-unescaped fam_forge '[forge] …no line starts with owner: (pack, a loose root)' '               % (esc(path), st.st_uid, stat.S_IMODE(st.st_mode))' '               % (path, st.st_uid, stat.S_IMODE(st.st_mode))' \
    '                    raise Stop(REFUSED, "%s: %s", word, why)' '                    raise Stop(REFUSED, "%s: %s" % (word, why))'
BRK noroot-unescaped fam_forge '[forge] …no line starts with owner: (go, no root)' '"from %s up to HOME", word, os.path.realpath(os.getcwd()))' '"from %s up to HOME" % (word, os.path.realpath(os.getcwd())))'
BRK leads-unescaped fam_forge '[forge] …no line starts with owner: (go, the place leads elsewhere)' $'never reached through a link", word, self.dir,\n                       os.path.realpath(self.dir))' \
    $'never reached through a link" % (word, self.dir,\n                       os.path.realpath(self.dir)))'
BRK link-unescaped fam_forge '[forge] …no line starts with owner: (go, a link)' $'never read through a link", self.word, self.path,\n                           os.path.realpath(self.path))' \
    $'never read through a link" % (self.word, self.path,\n                           os.path.realpath(self.path)))'
BRK unpinned-unescaped fam_forge '[forge] …no line starts with owner: (go, unpinned)' '        msg = "%s: %s (sha256 %s, %s)" % (esc(self.word), why, self.sha, esc(self.path))' '        msg = "%s: %s (sha256 %s, %s)" % (esc(self.word), why, self.sha, self.path)' \
    '            raise Stop(REFUSED, "%s", self.kept.refusal())' '            raise Stop(REFUSED, self.kept.refusal())'
BRK checkok-unescaped fam_forge '[forge] …no line starts with owner: (check ok)' '    say("check ok: %s (sha256 %s)%s", s.path, s.sha[:12],' '    say("check ok: " + s.path + " (sha256 %s)%s", s.sha[:12],'
BRK header-unescaped fam_forge "[forge] …no line starts with owner: (rehearse's header)" '    say("baton script %s (sha256 %s)%s", s.path, s.sha[:12],' '    say("baton script " + s.path + " (sha256 %s)%s", s.sha[:12],'
BRK kitarg-unescaped fam_forge '[forge] …no line starts with owner: (kit:)' "lower-case letters, digits and '-' only (no '/', no '.')\", arg)" "lower-case letters, digits and '-' only (no '/', no '.')\" % arg)"
BRK kindarg-unescaped fam_forge '[forge] …no line starts with owner: (kind:)' $'writes any kind)", arg,\n                   ", ".join(CALLABLE_KINDS))' $'writes any kind)" % (arg,\n                   ", ".join(CALLABLE_KINDS)))'
BRK tmp-left fam_refuse '[refuse] …a failed rename leaves no temporary file' '                os.unlink(tmp, dir_fd=fd)
            except OSError:
                pass
            raise' '                pass
            except OSError:
                pass
            raise'
BRK unmasked fam_keep '[keep] a SIGTERM right after the record: the owner: line still comes' \
    '    old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, CRITICAL)' '    old_mask = signal.pthread_sigmask(signal.SIG_BLOCK, [])'
BRK purpose-first fam_keep "[keep] …'not reviewed', then the Purpose last" '    return "kept %s (%s) — Stops %s — sha256 %s — changed: %s — body %s lines — not reviewed%s — Purpose: %s" % (' \
    '    return "kept %s (%s) — %s — Stops %s — sha256 %s — changed: %s — body %s lines — not reviewed%s" % ('
BRK no-stops fam_stops '[stops] a Stops word changed: rc 3' '    if was is not None and was != stops:' '    if False:'
BRK user-pin-per-sha fam_evolve '[evolve] a library file written back to an older version: rc 3' \
    '    if prefix == "project":
        by = naming[-1][1]' '    if True:
        by = naming[-1][1]'
BRK retire-ignored fam_retire '[retire] a retired sha: go rc 3' \
    '    retired = bool(naming) and is_retire(naming[-1][1])' '    retired = False; naming = [x for x in naming if is_keep(x[1])]'
BRK move-source-first fam_move '[move] after a cut after the retire, the re-run finishes' \
    '            pack_target(t, data, sha)
            retire_source(src, sha)' '            retire_source(src, sha)
            pack_target(t, data, sha)'
BRK move-no-retire fam_move '[move] …a restored source file is not pinned again' '            retire_source(src, sha)' '            pass'
BRK no-lock fam_parallel '[parallel] a pack waits while another holds the lock' \
    '            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)' '            pass'
BRK lock-file-excl fam_parallel '[parallel] a pack after a killed pack lands at once' \
    '    fd = os.open(path, os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)' \
    '    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)'
BRK seq-replace fam_parallel "[parallel] …the racer's record is intact" '                os.link(tmp, path)' '                os.replace(tmp, path)'
BRK no-owner-line fam_keep '[keep] a user: keep prints one owner: line' '            say("owner: %s", facts)' '            say("%s", facts)'
BRK repack-twice fam_keep '[keep] …and writes no second record' '    if newest is not None and newest["sha256"] == sha and kept.pin(sha):' '    if False:'
BRK target-followed fam_refuse '[refuse] …a symlinked target is replaced, the file it led to unchanged' \
    '            os.rename(tmp, kept.name + ".sh", src_dir_fd=fd, dst_dir_fd=fd)' \
    '            open(kept.path, "wb").write(data); os.unlink(tmp, dir_fd=fd)'
BRK kit-name-ok fam_refuse '[refuse] a name a kit ships: rc 64' '    if name in kit_names():' '    if False:'
BRK copy-name-ok fam_refuse '[refuse] a copy name -v<digits>: rc 64' '    if COPY_NAME.search(name):' '    if False:'
BRK kept-check-skipped fam_refuse '[refuse] a fixed-value script (Params: none): rc 1' '        probs = check_script(t)
        if probs:' '        probs = []
        if probs:'

echo "== nothing written outside the scratch tree =="
eq "$(tree_hash "$SRC_ROOT")" "$H0" "the repository tree is unchanged by the suite"
[ ! -e "$HOME/.local/state/vibemaestro" ] && ok "the scratch HOME holds no baton state (every family set XDG_STATE_HOME)" \
  || bad "the scratch HOME holds no baton state (every family set XDG_STATE_HOME)"

echo; summary
