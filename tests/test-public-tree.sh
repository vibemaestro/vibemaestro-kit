#!/bin/bash
# =============================================================================
# The public-tree check: scripts/public-tree.py, its baseline and its allow file
# =============================================================================
# Run: bash tests/test-public-tree.sh
#
#   1. each class is red when planted (a real kb path, a bare kb stem, an issue number, a plan row, a dated owner decision, a dated
#      diary line, an e-mail, a home path, a private term) and the look-alikes stay green (kb/current-state.md, a made-up kb path,
#      a flag with a dated value, a reserved e-mail domain, a placeholder home path, a timestamp);
#   2. the exempt paths: the root kb/, a public.private glob, the allow file; a kb/ below the root is not exempt;
#   3. the baseline: a baselined hit is green, a hit the baseline lacks is red, a stale line is red, an edited hit line is red, a
#      line the base's baseline lacks is red (the baseline only shrinks), a base without the check accepts a first baseline;
#   4. the allow file: an exact string covers its hit, a stale entry is red, a term class is refused, a line half covered is red;
#   5. the output names path, line and class, never the line text or a term; the instrument's control runs first;
#   6. the CI job (.github/workflows/public-tree.yml): its shape read with a YAML parser, each planted fault seen; its real run block
#      run in a scratch repository with a made-up secret: green on a clean tree, red on a planted term (never printed), red on an
#      empty secret, the term file gone afterwards.
# Real git on throw-away repositories under the suite's scratch tree; no network, no real secret. Every planted string is built here from
# pieces, so this file carries no hit of its own (the check reads it too).
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
CHECK="$SRC_ROOT/scripts/public-tree.py"

# the planted strings, each spelled in two parts
K="k""b"
KBPATH="see $K/specs/2026-01-01-real.md for why"
KBSTEM="it supersedes 2026-01-01""-real, read it"
ISSUE="the fix of iss""ue #1""87 holds"
ROW="done in plan ro""w C1 of the split"
OWNER="the owner's rule (2026""-10-17): run it twice a week"
DIARY="the job id is the run id (measured on 2026""-10-16)"
MAIL="write to jane""@corp-mail.io for access"
HOMEP="cd /ho""me/alice/src/app"
PRIVLINE=$(printf 'zq%sxv-%s-term' "$RANDOM" "$RANDOM")   # a made-up private term of this run
TERMLINE="the build host is $PRIVLINE today"

R="$TMP/repo"
mk_repo() {  # mk_repo <dir> [--no-check] — a publishing repo with a real kb file; the check's script is tracked unless --no-check
  local d=$1
  mkdir -p "$d/$K/specs" "$d/src" "$d/scripts" "$d/.vibemaestro" "$d/secret"
  git_ init -q -b main ${INIT_OPTS:-} "$d"
  printf '# real\n' > "$d/$K/specs/2026-01-01-real.md"; mkdir -p "$d/$K/state"; printf '# a page\n' > "$d/$K/state/repo.md"
  printf '# state\n' > "$d/$K/current-state.md"
  printf '{"public": {"private": [".vibemaestro/sdlc.json", "secret/**"]}}\n' > "$d/.vibemaestro/sdlc.json"
  printf 'plain\n' > "$d/src/clean.txt"
  [ "${2:-}" = --no-check ] || printf '# the check\n' > "$d/scripts/public-tree.py"
  cm "$d" base
}
cm() { git_ -C "$1" add -A && git_ -C "$1" commit -qm "$2"; }
head_() { git_ -C "$1" rev-parse HEAD; }
run() { python3 "$CHECK" --root "$R" "$@" 2>&1; }   # prints the findings and the summary; rc is the check's

mk_repo "$R"
BASE=$(head_ "$R")

echo "== the instrument and a clean tree =="
O=$(run --base "$BASE"); rc=$?
eq "$rc" 0 "a clean publishing tree is green (rc $rc)"
has "$O" "control: 5/5" "the control ran: one planted line per class found (no term file: five classes)"
has "$O" "terms: not checked" "without a term file it says the term class was not checked"
has "$O" "hits: 0 baselined, 0 allowed, 0 new" "the summary counts nothing"

echo "== each class planted is red =="
plant() {  # plant <class> <line> — the line in a tracked file, the check run, the file removed again
  printf 'a first line\n%s\n' "$2" > "$R/src/p.txt"; cm "$R" "plant $1"
  O=$(capped run --base "$BASE"); rc=$?
  eq "$rc" 1 "planted $1 is red (rc $rc)"
  has "$O" "new src/p.txt:2 $1" "…and named path:line and class ($1)"
  git_ -C "$R" rm -q src/p.txt; cm "$R" "unplant $1"
}
plant kb "$KBPATH"
plant kb "$KBSTEM"
plant ref "$ISSUE"
plant ref "$ROW"
plant ref "fixed in P""R 216, then merged"   # a comma then a blank: still a PR number
plant diary "$OWNER"
plant diary "$DIARY"
plant mail "$MAIL"
plant home "$HOMEP"
plant kb "the page is $K/state/repo, read it"                              # a kb path without .md
plant kb "see spe""cs/2026-01-01-real.md#C1"                             # below a kb directory's name, without kb/
plant ref "merged as (#3""53)"
plant ref "the fix: \"#3""53\" and \`#3""54\`"
plant ref "see P""R#353 and P""R-354"
plant ref "upstream owner/repo""#3""53"
plant ref "https://github.com/o/r/pu""ll/353"
plant ref "the link .../pu""ll/353 is enough"
plant ref "đã gộp ở P""R số 353"
plant ref "done in ro""ws C2/C3"
plant ref "the ki""t #1""21 baton"
plant ref "the ki""t #7 baton"                                         # one digit after kit
plant ref "merged P""Rs 338,345 today"                                   # a plural word and a list: still numbers
plant ref "see P""R 338/345"
plant ref "P""R: 353"
plant ref "sent to the background (P""R D of #1""43)"                      # "background" with no property syntax
plant ref "**Background:** the leak came in with #3""53."                # prose, not a declaration
plant ref "Outline: #3""53 then #3""47"
plant ref "Backfill: rows from #3""530"
plant ref "Border: #3""53 is where it broke"                             # a capitalised heading is prose
plant ref "- fill: tracked in #3""53"                                     # prose words are not CSS values
plant ref "- color: still open in #3""530"
plant ref "border: 1px solid; fixed in #3""53"
plant ref "the border: #3""53 is fixed"                                   # a colour value ends the declaration
plant ref "color: #1""2345"                                               # five digits: not a colour length
plant diary "it went in (fixed, 2026""-10-17)"
plant diary "Approved 2026""-10-21: split the repo"
plant diary "đã duyệt 2026""-10-21: tách repo"
plant diary "Chốt 2026""-10-21: tách repo"
plant diary "duyệt: 2026""-10-21 bản cuối"
plant mail "write to _jane""@corp-mail.io_ now"                            # markdown italic
plant mail "the addr jane""@corp-mail.io:now or jane""@corp-mail.io:)"   # a colon without a path is not an SSH remote
plant mail "see a""@example.io"                                          # a reserved name only as the whole label
plant home "C:\\Us""ers\\alice\\x and c:\\us""ers\\bob"
plant home "under /mnt/c/Us""ers/alice/x"
plant home "under /var/ho""me/alice/x"
plant home "cd ~al""ice/src"
plant mail "mail jane""@corp-mail.io: she owns it"   # a colon then a blank: still an e-mail
printf '%s\n' "$PRIVLINE" > "$TMP/terms"
printf 'x\n%s\n' "$TERMLINE" > "$R/src/t.txt"; cm "$R" "plant a term"
O=$(capped run --base "$BASE" --terms "$TMP/terms"); rc=$?
eq "$rc" 1 "a planted private term is red (rc $rc)"
has "$O" "term " "…reported as a term hit"
hasnt "$O" "$PRIVLINE" "…and the term itself is never printed"
has "$O" "control: 6/6" "with a term file the control covers six classes"
git_ -C "$R" rm -q src/t.txt; cm "$R" "unplant term"
O=$(run --base "$BASE" --terms "$TMP/terms"); rc=$?
eq "$rc" 0 "the same term file on the clean tree is green (rc $rc)"

echo "== look-alikes stay green =="
{
  printf 'the map is %s/current-state.md and %s/README.md\n' "$K" "$K"
  printf 'a made-up %s/specs/2026-01-01-nope.md and the directory %s/specs/\n' "$K" "$K"
  printf 'kb.py new intent x --intent 2026-01-01-x --issue 2>err\n'
  printf 'mail x@example.invalid, y@ci.test, z@mail.example.com, w@host.localhost, v@a.example, u@example.org\n'
  printf 'a placeholder /home/<name>/ path and ~/src\n'
  printf 'a scratch dir "$TMP/ho''me/kind-ran" and ${D}/ho''me/x\n'
  printf 'the owner sets --expires 2026-10-17T22:00:00Z\n'
  printf 'a colour #1a2b3c and a list item #1\n'
  printf 'the change file .changes/2026-01-01''-real.md\n'
  printf 'an owner decision, pinned (owner)\n'
  printf 'units per merged P''R 216,520 and per iss''ue 1,024\n'   # a count with a thousands group is not a number
  printf 'the remote git''@github.com:org/repo.git and deploy''@host.io:/srv/app\n'   # an SSH remote is not an e-mail
  printf 'the remote git''@gitlab.corp.io:grp/repo.git\n'                                   # three labels: the whole host
  printf 'color: #3''33333; fill="#0''00"\n'                                                 # a colour, not an issue
  printf 'the ownership since 2026''-10-01, rounding and measurement\n'                 # not diary words
  printf 'mở trình duyệt từ 2026''-10-21 và chốt chặn\n'                               # browser, checkpoint: not diary words
  printf 'border: 1px solid #3''33333; x = linear-gradient(#3''33, #fff)\n'                # colours after a property
  printf 'box-shadow: 0 0 4px #0''00; text-shadow: 1px 1px #3''33; --bg-color: #1''11;\n'  # prefixed and custom properties
  printf '<stop stop-color="#0''00"/> <rect fill="#0''00"/> filter: drop-shadow(0 0 2px #0''00);\n'
  printf 'background: linear-gradient(90deg, #0''00 0%%, #3''33 100%%); background: url(x.png) #0''00;\n'
  printf ':root { --fg: #3''33 } .a { -webkit-box-shadow: 0 0 2px #0''00; border-top-color: #3''33; }\n'

  printf 'npm install -g @anthropic-ai/claude-code''@2.1.290\n'                           # a version is not a domain
  printf 'iss''ue: 42\n'                                                                  # the intent frontmatter key
} > "$R/src/near.txt"; cm "$R" "near misses"
O=$(run --base "$BASE"); rc=$?
eq "$rc" 0 "the look-alikes are green (rc $rc)"
[ "$rc" = 0 ] || printf '%s\n' "$O" | head
git_ -C "$R" rm -q src/near.txt; cm "$R" "rm near"

echo "== exempt paths =="
printf '%s\n%s\n' "$ISSUE" "$MAIL" > "$R/$K/specs/notes.md"
printf '%s\n' "$ISSUE" > "$R/secret/a.txt"
cm "$R" "exempt"
O=$(run --base "$BASE"); rc=$?
eq "$rc" 0 "a hit under the root kb/ and under a public.private glob is green (rc $rc)"
mkdir -p "$R/tests/fixtures/f/$K"; printf '%s\n' "$ISSUE" > "$R/tests/fixtures/f/$K/x.md"; cm "$R" "nested kb"
O=$(capped run --base "$BASE"); rc=$?
eq "$rc" 1 "a kb/ below the root is not exempt (rc $rc)"; has "$O" "new tests/fixtures/f/$K/x.md:1 ref" "…and is named"
mkdir -p "$R/$K-notes"; printf '%s\n' "$ISSUE" > "$R/$K-notes/x.txt"; cm "$R" "kb-like name"
O=$(capped run --base "$BASE"); rc=$?
eq "$rc" 1 "a root directory whose name only starts with kb is not exempt (rc $rc)"; has "$O" "new $K-notes/x.txt:1 ref" "…and is named"
git_ -C "$R" rm -q -r tests "$K-notes" "$K/specs/notes.md" secret/a.txt; cm "$R" "rm exempt"

echo "== the baseline =="
printf 'one\n%s\nthree\n' "$ISSUE" > "$R/src/b.txt"; cm "$R" "a hit"
O=$(run --write-baseline); rc=$?
eq "$rc" 0 "--write-baseline writes the hits (rc $rc)"
eq "$(grep -v '^#' "$R/scripts/public-tree.baseline" | grep -c .)" 1 "…one line for the one hit line"
hasnt "$(cat "$R/scripts/public-tree.baseline")" "187" "…and the baseline holds no line text"
O=$(capped run --base "$BASE"); rc=$?
eq "$rc" 1 "a first baseline where the base already has the check is red: the baseline grows (rc $rc)"
has "$O" "grows src/b.txt ref" "…named"
cm "$R" "baseline"; B1=$(head_ "$R")
O=$(run --base "$B1"); rc=$?
eq "$rc" 0 "a baselined hit is green against a base with the same baseline (rc $rc)"
has "$O" "hits: 1 baselined, 0 allowed, 0 new" "…counted as baselined"
printf 'zero\none\n%s\nthree\n' "$ISSUE" > "$R/src/b.txt"; cm "$R" "moved"
O=$(run --base "$B1"); rc=$?
eq "$rc" 0 "the same hit line on another line number is still green (rc $rc)"
printf 'zero\none\n  %s  \nthree\n' "$ISSUE" > "$R/src/b.txt"; cm "$R" "reindented"
O=$(run --base "$B1"); rc=$?
eq "$rc" 0 "a reindented hit line is still green: the hash is of the stripped line (rc $rc)"
printf 'zero\none\n%s, and more\nthree\n' "$ISSUE" > "$R/src/b.txt"; cm "$R" "edited"
O=$(capped run --base "$B1"); rc=$?
eq "$rc" 1 "an edited hit line is red: new hash (rc $rc)"
has "$O" "new src/b.txt:3 ref" "…the edited line is new"; has "$O" "stale src/b.txt ref" "…and its old line stale"
printf 'one\n%s\n%s\nthree\n' "$ISSUE" "$ISSUE" > "$R/src/b.txt"; cm "$R" "duplicate"
O=$(capped run --base "$B1"); rc=$?
eq "$rc" 1 "a second copy of a baselined line is red: the baseline is a multiset (rc $rc)"
printf 'one\nthree\n' > "$R/src/b.txt"; cm "$R" "fixed"
O=$(capped run --base "$B1"); rc=$?
eq "$rc" 1 "a baseline line whose hit is gone is red: it must leave with its hit (rc $rc)"
has "$O" "stale src/b.txt ref" "…named stale"
python3 "$CHECK" --root "$R" --write-baseline >/dev/null; cm "$R" "line leaves"
O=$(run --base "$B1"); rc=$?
eq "$rc" 0 "hit and baseline line removed together: green (rc $rc)"
printf 'one\n%s\n' "$ISSUE" > "$R/src/b.txt"; printf 'one\n%s\n' "$MAIL" > "$R/src/c.txt"; cm "$R" "two hits"
python3 "$CHECK" --root "$R" --write-baseline >/dev/null; cm "$R" "grow"
O=$(capped run --base "$B1"); rc=$?
eq "$rc" 1 "a new baseline line is red: the baseline only shrinks (rc $rc)"
has "$O" "grows src/c.txt mail" "…the added line named"
printf 'not a baseline line\n' >> "$R/scripts/public-tree.baseline"; cm "$R" "bad line"
O=$(capped run --base "$B1"); rc=$?
eq "$rc" 2 "a malformed baseline line is a broken input (rc $rc)"
git_ -C "$R" rm -q src/b.txt src/c.txt scripts/public-tree.baseline; cm "$R" "rm baseline"

C="$TMP/classes"; mk_repo "$C"
printf 'x\n%s and %s\n' "$KBPATH" "$ISSUE" > "$C/src/k.txt"; cm "$C" "a kb,ref line"
python3 "$CHECK" --root "$C" --write-baseline >/dev/null; cm "$C" "its baseline"; CB=$(head_ "$C")
has "$(cat "$C/scripts/public-tree.baseline")" "src/k.txt	kb,ref	" "a line with two classes is recorded with both"
git_ -C "$C" mv "$K/specs/2026-01-01-real.md" "$K/specs/2026-01-02-moved.md"; cm "$C" "a change in kb/ only"
O=$(python3 "$CHECK" --root "$C" --base "$CB" 2>&1); rc=$?
eq "$rc" 0 "a kb-only change that turns a kb,ref line into a ref line keeps it baselined: lines are known by path and hash (rc $rc)"

H="$TMP/sha256"; INIT_OPTS=--object-format=sha256 mk_repo "$H"; HB=$(head_ "$H")
O=$(python3 "$CHECK" --root "$H" --base "$HB" 2>&1); rc=$?
eq "$rc" 0 "a sha256 repository is read: its blob ids match (rc $rc)"; hasnt "$O" "converted" "…nothing converted"
printf 'src/i.txt ident\n' > "$H/.gitattributes"; printf 'id: $''Id$\n' > "$H/src/i.txt"; cm "$H" "ident"
rm "$H/src/i.txt"; git_ -C "$H" checkout -q -- src/i.txt
O=$(capped python3 "$CHECK" --root "$H" --base "$HB" 2>&1); rc=$?
eq "$rc" 1 "…and a file its checkout converts is red there too (rc $rc)"; has "$O" "converted src/i.txt" "…named"

N="$TMP/new"; mk_repo "$N" --no-check; NB=$(head_ "$N")
printf '%s\n' "$ISSUE" > "$N/src/a.txt"; printf '# the check\n' > "$N/scripts/public-tree.py"; cm "$N" "the check"
python3 "$CHECK" --root "$N" --write-baseline >/dev/null; cm "$N" "first baseline"
O=$(python3 "$CHECK" --root "$N" --base "$NB" 2>&1); rc=$?
eq "$rc" 0 "a base without the check accepts the first baseline (rc $rc)"
has "$O" "first baseline" "…and says so"

echo "== the allow file =="
printf 'one\nfrom ops''@acme-corp.io to %s\n' "jane""@corp-mail.io" > "$R/src/d.txt"; cm "$R" "data"
printf 'src/d.txt\tmail\tops''@acme-corp.io\n' > "$R/scripts/public-tree.allow"; cm "$R" "allow one"
O=$(capped run --base "$BASE"); rc=$?
eq "$rc" 1 "a line with two addresses, one allowed, is red (rc $rc)"; has "$O" "new src/d.txt:2 mail" "…named"
printf 'src/d.txt\tmail\tops''@acme-corp.io to jane''@corp-mail.io\n' > "$R/scripts/public-tree.allow"; cm "$R" "allow both"
O=$(run --base "$BASE"); rc=$?
eq "$rc" 0 "an exact string covering every match of the class is green (rc $rc)"
has "$O" "hits: 0 baselined, 1 allowed, 0 new" "…counted as allowed"
printf 'src/d.txt\tmail\tops''@acme-corp.io to jane''@corp-mail.io\nsrc/clean.txt\tref\tnot in that file\n' > "$R/scripts/public-tree.allow"; cm "$R" "stale allow"
O=$(capped run --base "$BASE"); rc=$?
eq "$rc" 1 "an allow line that covers no hit is red (rc $rc)"; has "$O" "stale-allow scripts/public-tree.allow:2" "…named by its line"
printf 'src/d.txt\tterm\tops\n' > "$R/scripts/public-tree.allow"; cm "$R" "allow a term"
O=$(capped run --base "$BASE"); rc=$?
eq "$rc" 2 "an allow line for the term class is refused (rc $rc)"
git_ -C "$R" rm -q src/d.txt scripts/public-tree.allow; cm "$R" "rm allow"

echo "== output, inputs and refusals =="
MARK="unique$RANDOM""marker"
printf '%s %s\n' "$MARK" "$ISSUE" > "$R/src/m.txt"; cm "$R" "marker"
O=$(capped run --base "$BASE"); rc=$?
eq "$rc" 1 "control for the next check: the hit is red (rc $rc)"
hasnt "$O" "$MARK" "the output never holds the line text"
git_ -C "$R" rm -q src/m.txt; cm "$R" "rm marker"
printf 'x\0%s\0binary\n' "$ISSUE" > "$R/src/bin.dat"; cm "$R" "binary"
O=$(capped run --base "$BASE"); rc=$?
eq "$rc" 1 "a hit inside a file with NUL bytes is red: the text in it is read (rc $rc)"; has "$O" "binary read as text" "…and counted"
has "$O" "new src/bin.dat:1 ref" "…on its own line number (a NUL is read as a blank, not a line break)"
printf 'a\nb\0c\nsee %s\n' "$ISSUE" > "$R/src/bin.dat"; cm "$R" "binary 2"
O=$(capped run --base "$BASE"); has "$O" "new src/bin.dat:3 ref" "…line numbers count newlines only"
printf '%s\n' "$ISSUE" | iconv -f UTF-8 -t UTF-16 > "$R/src/u16.txt"; printf '%s\n' "$MAIL" | iconv -f UTF-8 -t UTF-16LE > "$R/src/u16le.txt"
git_ -C "$R" rm -q src/bin.dat; cm "$R" "utf-16"
O=$(capped run --base "$BASE"); rc=$?
eq "$rc" 1 "UTF-16, with and without a BOM, is decoded and red (rc $rc)"
has "$O" "new src/u16.txt:1 ref" "…the BOM file"; has "$O" "new src/u16le.txt:1 mail" "…the file without a BOM"
git_ -C "$R" rm -q src/u16.txt src/u16le.txt
printf '%s\n' "$MAIL" | iconv -f UTF-8 -t UTF-32 > "$R/src/u32.txt"; printf '%s\n' "$MAIL" | iconv -f UTF-8 -t UTF-32LE > "$R/src/u32le.txt"
printf '%s\n' "$MAIL" | iconv -f UTF-8 -t UTF-32BE > "$R/src/u32be.txt"; cm "$R" "utf-32"
O=$(capped run --base "$BASE"); rc=$?
eq "$rc" 1 "UTF-32, with and without a BOM, is decoded and red (rc $rc)"
has "$O" "new src/u32.txt:1 mail" "…the BOM file"; has "$O" "new src/u32le.txt:1 mail" "…little-endian without a BOM"
has "$O" "new src/u32be.txt:1 mail" "…big-endian without a BOM"
git_ -C "$R" rm -q src/u32.txt src/u32le.txt src/u32be.txt
printf '%s\n' "$TERMLINE" | iconv -f UTF-8 -t UTF-16 > "$R/src/t16.txt"; cm "$R" "a term in UTF-16"
O=$(capped run --base "$BASE" --terms "$TMP/terms"); rc=$?
eq "$rc" 1 "a private term in a UTF-16 file is red: its decoded text goes through the term scanner (rc $rc)"
POS=$(git_ -C "$R" ls-files | grep -n -x -F src/t16.txt | cut -d: -f1)
has "$O" "term decoded tree #$POS term=" "…reported as a decoded term hit, the file by its place in git ls-files (#$POS)"; hasnt "$O" "$PRIVLINE" "…the term not printed"
printf 't16.txt\n' | iconv -f UTF-8 -t UTF-16 > "$R/src/.gitignore"; git_ -C "$R" add -f src/.gitignore; cm "$R" "a UTF-16 ignore file"
O=$(capped run --base "$BASE" --terms "$TMP/terms"); rc=$?
eq "$rc" 1 "a UTF-16 .gitignore naming that file does not hide it from the decoded term scan (rc $rc)"
git_ -C "$R" rm -q src/t16.txt src/.gitignore; cm "$R" "rm terms in utf-16"
printf 'src/enc.txt working-tree-encoding=UTF-32LE\n' > "$R/.gitattributes"; cm "$R" "an encoding attribute"
printf '%s\n' "$ISSUE" | iconv -f UTF-8 -t UTF-32LE > "$R/src/enc.txt"; cm "$R" "a file converted on checkout"
O=$(capped run --base "$BASE"); rc=$?
eq "$rc" 1 "a file the checkout converts (working-tree-encoding) is red: the export ships its blob, not these bytes (rc $rc)"
has "$O" "converted src/enc.txt" "…named converted"
git_ -C "$R" rm -q src/enc.txt .gitattributes; cm "$R" "rm converted"
printf 'one\r\ntwo\r\n' > "$R/src/crlf.txt"; printf 'plain\n' > "$R/src/\"q.txt"; cm "$R" "crlf and a quoted name"
O=$(run --base "$BASE"); rc=$?
eq "$rc" 0 "a CRLF file and a path starting with a quote are not converted (rc $rc)"
rm "$R/src/clean.txt"; git_ -C "$R" -c core.autocrlf=true checkout -q -- src/clean.txt; git_ -C "$R" config core.autocrlf true
O=$(run --base "$BASE"); rc=$?
eq "$rc" 0 "core.autocrlf=true (line endings only) is not a conversion (rc $rc)"; hasnt "$O" "converted" "…nothing named converted"
git_ -C "$R" config --unset core.autocrlf; rm "$R/src/clean.txt"; git_ -C "$R" checkout -q -- src/clean.txt
printf 'plain\n%s\n' "$ISSUE" > "$R/src/clean.txt"
O=$(capped run --base "$BASE"); rc=$?
eq "$rc" 1 "an edited, uncommitted hit is red as new (rc $rc)"; hasnt "$O" "converted" "…and not as converted (git sees the edit)"
git_ -C "$R" checkout -q -- src/clean.txt; git_ -C "$R" rm -q "src/\"q.txt" src/crlf.txt; cm "$R" "rm crlf"
printf '%s\n' "$ISSUE" > "$TMP/outside.txt"; ln -s "$TMP/outside.txt" "$R/src/link"; cm "$R" "a link"
O=$(run --base "$BASE"); rc=$?
eq "$rc" 0 "a symlink is not followed (the export refuses one) (rc $rc)"; has "$O" "skipped: 1 symlink" "…and counted"
git_ -C "$R" rm -q src/link; cm "$R" "rm link"
O=$(capped run --ci --base "$BASE"); rc=$?
eq "$rc" 2 "--ci without a term file is refused (rc $rc)"
O=$(capped run --ci --terms "$TMP/terms"); rc=$?
eq "$rc" 2 "--ci without --base is refused (rc $rc)"; has "$O" "--ci needs" "…for that reason"
O=$(capped python3 -B -c 'import importlib.util, re, sys
s = importlib.util.spec_from_file_location("pt", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
m.HOME_RX = re.compile("(?!x)x")
sys.argv = ["pt", "--root", sys.argv[2], "--base", sys.argv[3]]; sys.exit(m.main())' "$CHECK" "$R" "$BASE" 2>&1); rc=$?
eq "$rc" 2 "a class the instrument cannot find any more fails the control (rc $rc)"; has "$O" "control: found 4 of 5" "…and says so"
printf '[commit]\n\tgpgsign = true\n[core]\n\thooksPath = %s\n' "$TMP/hooks" > "$GIT_CONFIG_GLOBAL"
mkdir -p "$TMP/hooks"; printf '#!/bin/sh\nexit 1\n' > "$TMP/hooks/pre-commit"; chmod +x "$TMP/hooks/pre-commit"
O=$(run --base "$BASE" --terms "$TMP/terms"); rc=$?
eq "$rc" 0 "signing and a failing hook in the user's git config do not break the control (rc $rc)"
: > "$GIT_CONFIG_GLOBAL"
O=$(capped run --base "$BASE" --terms "$TMP/no-such-file"); rc=$?
eq "$rc" 2 "a missing term file is refused (rc $rc)"
O=$(capped run --base 0000000000000000000000000000000000000000); rc=$?
eq "$rc" 2 "an unresolvable base is refused (rc $rc)"
printf '%s\n' "$ISSUE" > "$R/src/q.txt"; cm "$R" "a hit"
printf '{"public": {"private": [".vibemaestro/sdlc.json", "secret/**", "src/q.txt"]}}\n' > "$R/.vibemaestro/sdlc.json"
O=$(capped run --base "$BASE"); rc=$?
eq "$rc" 1 "an uncommitted public.private edit does not hide a file: HEAD's config is read (rc $rc)"
git_ -C "$R" add .vibemaestro/sdlc.json
O=$(capped run --base "$BASE"); rc=$?
eq "$rc" 1 "…nor a staged one (rc $rc)"
git_ -C "$R" rm -q src/q.txt; git_ -C "$R" checkout -q HEAD -- .vibemaestro/sdlc.json; cm "$R" "rm q"
mkdir -p "$R/secret"; printf '%s\n' "$TERMLINE" > "$R/secret/t.txt"; printf 'x\n' > "$R/secret/$PRIVLINE.txt"; cm "$R" "a term in a private file"
O=$(run --base "$BASE" --terms "$TMP/terms"); rc=$?
eq "$rc" 0 "a term in a public.private file, in its content or its name, is not a finding: it is never published (rc $rc)"
git_ -C "$R" rm -q secret/t.txt "secret/$PRIVLINE.txt"; cm "$R" "rm private term"
mkdir -p "$R/secret"; printf 'x\n' > "$R/secret/a
b.txt"; cm "$R" "a private path with a newline"
O=$(capped run --base "$BASE" --terms "$TMP/terms"); rc=$?
eq "$rc" 2 "a public.private path holding a newline is refused: the scanner's skip list is lines (rc $rc)"
git_ -C "$R" rm -q "secret/a
b.txt"; cm "$R" "rm newline path"
O=$(python3 -B -c 'import importlib.util, sys
s = importlib.util.spec_from_file_location("pt", sys.argv[1]); m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
print(m.private_skips(["s/a/1", "s/a/2", "s/b", "p", "kb/x"], [m.glob_regex("s/a/**"), m.glob_regex("p")]))' "$CHECK")
eq "$O" "['p', 's/a']" "a directory whose every file is private is one skip"
printf '{}\n' > "$R/.vibemaestro/sdlc.json"; cm "$R" "no public"
O=$(capped run --base "$BASE"); rc=$?
eq "$rc" 2 "a repo with no public.private does not publish: refused (rc $rc)"

echo "== the glob reading of public.private equals the export's =="
O=$(python3 -B -I - "$CHECK" "$SRC_ROOT/scripts/export-public.sh" <<'PYEOF'
import re, sys
def load(path):
    t = open(path, encoding="utf-8").read()
    bad = re.search(r'^GLOB_BAD_CHARS = .*$', t, re.M).group(0)
    fn = re.search(r'^def glob_regex\(g\):\n(?:(?:    .*|)\n)+', t, re.M).group(0)
    ns = {"re": re}
    exec(bad + "\n" + fn, ns)
    return ns["glob_regex"]
a, b = load(sys.argv[1]), load(sys.argv[2])
globs = [".vibemaestro/sdlc.json", "secret/**", "**/*.key", "a!b", "x[1]", "{a,b}", "a\\b", "/abs", "a/../b", "a**b", "*.md", "d/?.txt", "", None]
paths = [".vibemaestro/sdlc.json", "secret/a/b.txt", "x/y.key", "a!b", "c.md", "d/1.txt", "d/12.txt", "deep/c.md"]
diff = []
for g in globs:
    ra, rb = a(g), b(g)
    if (ra is None) != (rb is None):
        diff.append("validity of %r" % (g,))
    elif ra is not None:
        diff += ["%r on %s" % (g, p) for p in paths if bool(ra.match(p)) != bool(rb.match(p))]
print("\n".join(diff) or "same")
PYEOF
)
eq "$O" "same" "public-tree reads every public.private glob as export-public.sh does (valid or not, what it matches)"

echo "== the CI job =="
WF="$SRC_ROOT/.github/workflows/public-tree.yml"
python3 -c 'import yaml' 2>/dev/null || { bad "PyYAML is missing: the workflow cannot be read"; summary; exit 1; }
cat > "$TMP/wf.py" <<'PYEOF'
import re, sys, yaml
path, mode = sys.argv[1], sys.argv[2]
text = open(path).read()
wf = yaml.safe_load(text)
errs = []
on = wf.get(True, wf.get("on"))                      # PyYAML reads the key `on` as True
if not isinstance(on, dict) or set(on) != {"pull_request", "push"} or (on.get("push") or {}).get("branches") != ["main"]:
    errs.append("triggers are not exactly pull_request and push to main")
elif "ready_for_review" not in ((on.get("pull_request") or {}).get("types") or []):
    errs.append("a draft marked ready does not run the check")
if "pull_request_target" in text: errs.append("pull_request_target appears")
if wf.get("permissions") != {"contents": "read"}: errs.append("permissions wider than contents: read")
j = (wf.get("jobs") or {}).get("public-tree") or {}
if j.get("name") != "public-tree": errs.append("no job named public-tree (the required check's name)")
if not str(j.get("if", "")).startswith("github.event.repository.private && "): errs.append("the job does not need a private repository")
if "github.event.pull_request.draft == false" not in str(j.get("if", "")): errs.append("the job runs on a draft")
if "continue-on-error" in j or "permissions" in j: errs.append("the job has continue-on-error or its own permissions")
steps = j.get("steps") or []
co = [x for x in steps if str(x.get("uses", "")).startswith("actions/checkout@")]
if len(co) != 1 or (co[0].get("with") or {}).get("persist-credentials") is not False or (co[0].get("with") or {}).get("fetch-depth") != 0:
    errs.append("checkout must keep no credentials and fetch the full history")
if co and not re.fullmatch(r"actions/checkout@[0-9a-f]{40}", co[0]["uses"]): errs.append("checkout is not pinned to a commit")
run = [x for x in steps if "scripts/public-tree.py" in str(x.get("run", ""))]
if len(run) != 1: errs.append("want exactly one step that runs the check")
if text.count("secrets.") != 1 or text.count("secrets.KIT_TERMS") != 1: errs.append("the file reads a secret other than KIT_TERMS once")
block = ""
if run:
    st = run[0]; block = st["run"]
    env = st.get("env") or {}
    if env.get("KIT_TERMS") != "${{ secrets.KIT_TERMS }}": errs.append("the secret is not in the step's env as KIT_TERMS")
    if env.get("EVENT") != "${{ github.event_name }}" or env.get("BEFORE") != "${{ github.event.before }}": errs.append("EVENT or BEFORE is not the event's")
    if "git rev-parse --verify --quiet 'HEAD^1'" not in block: errs.append("a pull request's base is not the test-merge commit's first parent")
    if "if" in st or st.get("continue-on-error"): errs.append("the step can be skipped")
    if not re.search(r'python3 -I -B scripts/public-tree\.py --ci --base "\$BASE" --terms "\$terms"', block): errs.append("the check is not called isolated (-I -B) with --ci, --base and --terms")
for x in steps:
    r = str(x.get("run", ""))
    if "${{" in r: errs.append("a ${{ }} inside a run block")
    if re.search(r"set\s+-[a-z]*x|xtrace|bash -x", r): errs.append("xtrace")
    if "GITHUB_STEP_SUMMARY" in r or "add-mask" in r or "upload-artifact" in str(x.get("uses", "")): errs.append("a summary, mask or artifact")
sys.stdout.write(block if mode == "--run" else "".join(e + "\n" for e in errs))
PYEOF
E=$(python3 -B -I "$TMP/wf.py" "$WF" --shape)
empty "$E" "W1 the workflow passes the shape check"
wplant() {  # wplant <name> <python expression on s (the text)> — the fault in a copy must be seen
  local f="$TMP/wf-$1.yml" seen
  python3 -B -I -c 'import sys; s=open(sys.argv[1]).read(); t=eval(sys.argv[3]); assert t != s; open(sys.argv[2],"w").write(t)' "$WF" "$f" "$2" \
    || { bad "W plant $1: not built"; return; }
  seen=$(capped python3 -B -I "$TMP/wf.py" "$f" --shape)
  nonempty "$seen" "W plant $1 is seen"
}
wplant no-if 's.replace("    if: github.event.repository.private && ", "    if: ", 1)'
wplant draft 's.replace(" && (github.event_name == \x27push\x27 || github.event.pull_request.draft == false)", "", 1)'
wplant no-ready 's.replace(", ready_for_review]", "]", 1)'
wplant rename 's.replace("    name: public-tree\n", "    name: tree\n", 1)'
wplant creds 's.replace("persist-credentials: false", "persist-credentials: true", 1)'
wplant shallow 's.replace("fetch-depth: 0", "fetch-depth: 1", 1)'
wplant no-ci 's.replace("public-tree.py --ci ", "public-tree.py ", 1)'
wplant not-isolated 's.replace("python3 -I -B scripts/public-tree.py", "python3 scripts/public-tree.py", 1)'
wplant expr-in-run 's.replace("umask 077", "echo ${{ secrets.KIT_TERMS }}; umask 077", 1)'
wplant target 's.replace("  pull_request:\n", "  pull_request_target:\n", 1)'
wplant perm 's.replace("  contents: read", "  contents: write", 1)'
wplant xtrace 's.replace("set -uo pipefail", "set -xuo pipefail", 1)'
wplant base-sha 's.replace("git rev-parse --verify --quiet \x27HEAD^1\x27", "echo \"$BEFORE\"", 1)'
wplant skippable 's.replace("        run: |", "        continue-on-error: true\n        run: |", 1)'

python3 -B -I "$TMP/wf.py" "$WF" --run > "$TMP/step.sh"
nonempty "$(cat "$TMP/step.sh")" "W2 the step's run block was extracted"
W="$TMP/wrepo"; mk_repo "$W"; mkdir -p "$W/scripts"
cp "$CHECK" "$W/scripts/public-tree.py"; cp "$SRC_ROOT/scripts/scan-internal-terms.sh" "$W/scripts/"; cm "$W" "the real check"
WB=$(head_ "$W")
step() {  # step <secret|-> — the real run block in W; OUT, RC, LEFT (files left in RUNNER_TEMP)
  local rt; rt=$(mktemp -d "$TMP/rt.XXXXXX")
  if [ "$1" = - ]; then OUT=$(cd "$W" && env -u KIT_TERMS RUNNER_TEMP="$rt" EVENT="${EVENT_:-push}" BEFORE="${BEFORE_:-$WB}" bash -c "$(cat "$TMP/step.sh")" 2>&1); RC=$?
  else OUT=$(cd "$W" && KIT_TERMS="$1" RUNNER_TEMP="$rt" EVENT="${EVENT_:-push}" BEFORE="${BEFORE_:-$WB}" bash -c "$(cat "$TMP/step.sh")" 2>&1); RC=$?; fi
  LEFT=$(ls -A "$rt" | wc -l | tr -d ' ')
}
step "$PRIVLINE"
eq "$RC" 0 "W3 the run block on a clean tree with a made-up secret is green (rc $RC)"
has "$OUT" "control: 6/6" "W3 …the term class is checked"
eq "$LEFT" 0 "W3 the term file is gone afterwards"
printf 'x\n%s\n' "$TERMLINE" > "$W/src/t.txt"; cm "$W" "a term"
step "$PRIVLINE"
eq "$RC" 1 "W4 a planted term is red (rc $RC)"; has "$OUT" "::error::" "W4 …with an error annotation"
hasnt "$OUT" "$PRIVLINE" "W4 …and the term is not in the log"
eq "$LEFT" 0 "W4 the term file is gone after a failure too"
step " "
eq "$RC" 1 "W5 a blank secret is red (rc $RC)"; has "$OUT" "KIT_TERMS secret is empty" "W5 …and says why"
step -
eq "$RC" 1 "W6 an absent secret is red (rc $RC)"
git_ -C "$W" rm -q src/t.txt; printf '%s\n' "$ISSUE" > "$W/src/t.txt"
printf 'import sys\nprint("control: 6/6")\nprint("hits: 0 baselined, 0 allowed, 0 new")\nsys.exit(0)\n' > "$W/scripts/secrets.py"; cm "$W" "a shadow module"
step "$PRIVLINE"
eq "$RC" 1 "W6b a module next to the check (scripts/secrets.py) does not replace the standard library: the hit stays red (rc $RC)"
git_ -C "$W" rm -q scripts/secrets.py; cm "$W" "rm shadow"
git_ -C "$W" rm -q src/t.txt; cm "$W" "rm term"
BEFORE_=0000000000000000000000000000000000000000 step "$PRIVLINE"
eq "$RC" 1 "W7 a push whose before does not resolve is red (rc $RC)"
EVENT_=pull_request BEFORE_=0000000000000000000000000000000000000000 step "$PRIVLINE"
eq "$RC" 0 "W8 a pull request takes HEAD^1 as its base, not the event's data (rc $RC)"

summary
