#!/bin/bash
# =============================================================================
# kb.py find / list / outline: find what is in kb/ without reading it
# =============================================================================
# Run: bash tests/test-kb-index.sh
#
# A synthetic kb/ (no content from any other repo) with a superseded pair, a done intent,
# a missing description, an accented description, a legacy `status: active` decision, a long spec with fenced code, and 30
# documents with long descriptions for the output budgets. Every document body carries a marker that must never be printed.
#   [F] find: ranking (words matched, then score, then newest date), --type, --all, --limit, accents, no match
#   [L] list: format, filters, deterministic path order, README and current-state not indexed
#   [O] outline: every start line holds its heading, sections sum to the file, a section's bytes equal sed|wc -c
#   [B] byte budgets: find <= 3000 B at the default limit, list <= 300 B per line, outline <= 150 B per row
#   [C] kb.py check: lifecycle (good, unknown status, dangling and one-sided links, superseded without superseded_by), --strict,
#       the spec size warning and its config key `kb.spec_warn_bytes`
#   [S] SessionStart: the kb/ paragraph names the three finders by the plugin's kb.py path, lists no file, stays in 9000 characters
# Each family runs on the real plugin, then on copies of it with one planted break each, which must turn that family red.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
export PYTHONDONTWRITEBYTECODE=1
BODY='BODY-MARKER-NEVER-PRINTED'

# doc <repo> <rel path under kb/> <frontmatter lines, \n-separated or empty> [body]
doc() {
  local f="$1/kb/$2"; mkdir -p "$(dirname "$f")"
  { if [ -n "$3" ]; then printf -- '---\n%b\n---\n\n' "$3"; fi
    printf '# %s\n\n%b\n' "$(basename "$2" .md)" "${4:-$BODY}"; } > "$f"
}

KB="$TMP/repo"
mk_fixture() {
  local r=$1 i
  mkdir -p "$r/kb"; git_ init -q -b main "$r"
  printf '# kb readme mentioning login and payment\n%s\n' "$BODY" > "$r/kb/README.md"
  printf '# Current state: login, payment\n%s\n' "$BODY" > "$r/kb/current-state.md"
  doc "$r" intent/2026-01-01-alpha-login.md 'description: "Login form for the alpha app"'
  doc "$r" intent/2026-01-05-alpha-login-retry.md 'status: done\ndescription: "Retry the login form after a timeout"'
  doc "$r" specs/2026-01-02-alpha-login.md 'description: "Design of the login form"' "## Login flow\n\n$BODY\n\n## Errors\n\nnone"
  doc "$r" specs/2026-01-03-old-payment.md 'status: superseded\nsuperseded_by: kb/specs/2026-01-04-payment.md\ndescription: "Payment by invoice"'
  doc "$r" specs/2026-01-04-payment.md 'supersedes: kb/specs/2026-01-03-old-payment.md\ndescription: "Payment by card"'
  doc "$r" plans/2026-01-07-nodesc.md 'issue: 4' "## zeta and omega\n\n$BODY"
  doc "$r" intent/2026-01-09-zeta-zeta.md 'description: "zeta zeta"' "## zeta\n\n$BODY"
  doc "$r" intent/2026-02-01-beta-x.md 'description: "beta thing"'
  doc "$r" intent/2026-03-01-beta-y.md 'description: "beta thing"'
  doc "$r" decisions/2026-01-08-keep-ledger.md 'applyTo: "src/**"\nstatus: active\ndescription: "Hiện trạng của sổ: giữ dạng sổ"'
  doc "$r" ports/ledger.md 'description: "port ledger"'
  doc "$r" intent/2026-01-10-kappa.md 'description: "other words"'
  doc "$r" intent/2026-01-11-other.md 'description: "kappa"'
  doc "$r" plans/2026-01-12-heads.md 'description: "five headings"' "## lambda one\n## lambda two\n## lambda three\n## lambda four\n## lambda five"
  doc "$r" plans/2026-01-13-mixed.md 'description: "lambda"' "## lambda"
  # Vietnamese: 3-byte letters, so a cut in characters would overshoot the byte budgets
  doc "$r" specs/2026-05-01-mot-ten-file-kha-dai-de-thu-ngan-sach-byte-cua-moi-dong.md "description: \"Hiện trạng $(printf 'ệ%.0s' $(seq 1 200))\"" "### Hiện trạng $(printf 'ệ%.0s' $(seq 1 120))\n\n$BODY"
  # a long spec: 40 headings of 150 characters at three levels, a fenced block holding heading-like lines, ~60 KB
  { printf -- '---\ndescription: "A long spec"\n---\n\n# Long spec\n\nintro %s\n' "$BODY"
    for i in $(seq 1 40); do
      printf '\n%s Section %02d %s\n\n' "$( [ $((i % 4)) = 0 ] && echo '##' || { [ $((i % 2)) = 0 ] && echo '###' || echo '####'; } )" "$i" "$(printf 'w%.0s' $(seq 1 140))"
      printf 'text %s %s\n' "$BODY" "$(head -c 1400 /dev/zero | tr '\0' x)"
      [ "$i" = 7 ] && printf '\n```bash\n# not a heading\n## not a heading either\n```\n'
    done; } > "$r/kb/specs/2026-01-06-long-spec.md"
  # thirty documents with long descriptions, all matching `bulk`
  for i in $(seq 10 39); do
    doc "$r" specs/2026-04-$i-bulk-$i.md "description: \"bulk $(printf 'd%.0s' $(seq 1 300))\""
  done
}
mk_fixture "$KB"

# kbx <plugin> <args...> — kb.py of <plugin> run inside the fixture repo
kbx() { local p=$1; shift; ( cd "$KB" && python3 "$p/scripts/kb.py" "$@" ); }
lines() { printf '%s\n' "$1" | grep -c . ; }
nth() { printf '%s\n' "$1" | sed -n "$2p" | cut -d' ' -f1; }

fam_find() {
  local p=$1 O rc
  O=$(kbx "$p" find login); rc=$?
  eq "$rc" 0 "[F] find login: rc 0"
  eq "$(nth "$O" 1)" kb/specs/2026-01-02-alpha-login.md "[F] find login: path + description + heading ranks first"
  eq "$(nth "$O" 2)" kb/intent/2026-01-01-alpha-login.md "[F] find login: path + description second"
  hasnt "$O" alpha-login-retry "[F] find login: the done intent is hidden"
  has "$O" '(1 superseded/done hidden; --all shows them)' "[F] find login: says how many it hid"
  has "$(kbx "$p" find login --all)" 'kb/intent/2026-01-05-alpha-login-retry.md | intent | done | 2026-01-05 | Retry' "[F] find login --all: the done intent, in the one-line format"
  O=$(kbx "$p" find payment)
  eq "$O" 'kb/specs/2026-01-04-payment.md | spec | live | 2026-01-04 | Payment by card
(1 superseded/done hidden; --all shows them)' "[F] find payment: only the live document"
  has "$(kbx "$p" find payment --all)" 'kb/specs/2026-01-03-old-payment.md | spec | superseded | 2026-01-03 | Payment by invoice | superseded_by: kb/specs/2026-01-04-payment.md' "[F] find --all: the superseded one carries superseded_by"
  O=$(kbx "$p" find zeta omega)
  eq "$(nth "$O" 1)" kb/plans/2026-01-07-nodesc.md "[F] two words matched (weak) rank above one word matched (strong)"
  has "$O" 'kb/plans/2026-01-07-nodesc.md | plan | live | 2026-01-07 | (no description)' "[F] a missing description prints (no description)"
  eq "$(nth "$(kbx "$p" find kappa)" 1)" kb/intent/2026-01-10-kappa.md "[F] path (3) outweighs description (2), even against a newer date"
  eq "$(nth "$(kbx "$p" find lambda)" 1)" kb/plans/2026-01-13-mixed.md "[F] headings count at most 3 per word: five heading hits tie with description + one heading, the newer wins"
  kbx "$p" find a >/dev/null 2>&1; eq "$?" 64 "[F] find with only one-character words: rc 64 (they are ignored, so nothing is asked)"
  O=$(kbx "$p" find beta)
  eq "$(nth "$O" 1)" kb/intent/2026-03-01-beta-y.md "[F] equal score: the newest date first"
  O=$(kbx "$p" find login --type spec)
  eq "$(lines "$O")" 1 "[F] --type spec: one line"; has "$O" 'kb/specs/2026-01-02-alpha-login.md' "[F] --type spec: the spec"
  O=$(kbx "$p" find login --limit 1)
  eq "$(nth "$O" 1)" kb/specs/2026-01-02-alpha-login.md "[F] --limit 1: the best match"; has "$O" '(1 more; raise --limit)' "[F] --limit 1: says one more"
  has "$(kbx "$p" find hien trang)" 'kb/decisions/2026-01-08-keep-ledger.md | decision | live |' "[F] accent-insensitive: 'hien trang' finds 'Hiện trạng'; legacy active reads live"
  has "$(kbx "$p" find HIỆN)" 'keep-ledger' "[F] case and accents in the query are folded too"
  O=$(kbx "$p" find nothingmatchesthis 2>/dev/null); rc=$?
  eq "$rc" 1 "[F] no match: rc 1"; empty "$O" "[F] no match: nothing on stdout"
  kbx "$p" find login --type bogus >/dev/null 2>&1; eq "$?" 64 "[F] --type bogus: rc 64"
  kbx "$p" find login --limit 0 >/dev/null 2>&1; eq "$?" 64 "[F] --limit 0: rc 64"
  hasnt "$(kbx "$p" find readme current state 2>/dev/null)" 'kb/README.md' "[F] README is not indexed"
}

fam_list() {
  local p=$1 O
  O=$(kbx "$p" list)
  eq "$(lines "$O")" "$(cd "$KB" && find kb -name '*.md' ! -path kb/README.md ! -path kb/current-state.md | wc -l | tr -d ' ')" "[L] list: one line per document except README and current-state"
  eq "$(printf '%s\n' "$O" | cut -d' ' -f1)" "$(printf '%s\n' "$O" | cut -d' ' -f1 | LC_ALL=C sort)" "[L] list: path order"
  eq "$O" "$(kbx "$p" list)" "[L] list: the same output twice"
  hasnt "$O" 'kb/current-state.md' "[L] current-state is not indexed"
  has "$O" 'kb/ports/ledger.md | ports | live | - | port ledger' "[L] another directory: its name as type, no date gives -"
  eq "$(kbx "$p" list --status superseded)" 'kb/specs/2026-01-03-old-payment.md | spec | superseded | 2026-01-03 | Payment by invoice | superseded_by: kb/specs/2026-01-04-payment.md' "[L] --status superseded"
  eq "$(kbx "$p" list --type decision | cut -d'|' -f3)" ' live ' "[L] --type decision: the legacy active decision is live"
  eq "$(lines "$(kbx "$p" list --type intent --status live)")" 6 "[L] --type intent --status live: the six open intents"
  eq "$(kbx "$p" list --type ports | cut -d' ' -f1)" kb/ports/ledger.md "[L] --type ports: a type that list prints can be filtered on"
  kbx "$p" list --status active >/dev/null 2>&1; eq "$?" 64 "[L] --status active (legacy word, not a status): rc 64"
  kbx "$p" list login >/dev/null 2>&1; eq "$?" 64 "[L] list with words: rc 64 (find takes words)"
}

# outline_bad <plugin> <file> — number of outline rows whose start line does not hold the heading, or whose bytes differ from
# `sed -n start,endp | wc -c`; plus 1 when the header's line or byte count differs from the file's
outline_bad() {
  local p=$1 F=$2 O bad=0 s e b t got rng rest
  O=$( (cd "$KB" && python3 "$p/scripts/kb.py" outline "$F") ) || { echo 99; return; }
  case "$(printf '%s\n' "$O" | head -1)" in *": $(grep -c '' "$F") lines, $(wc -c < "$F" | tr -d ' ')B;"*) ;; *) bad=$((bad + 1));; esac
  while IFS=' ' read -r rng b rest; do
    s=${rng#L}; s=${s%-*}; e=${rng#*-}; b=${b%B}
    t=$(printf '%s' "$rest" | sed 's/^ *//')
    got=$(sed -n "${s}p" "$F" | tr -d '\r' | sed -e 's/^ *//' -e 's/[[:space:]]#*$//')     # the closing run of # is not text
    if [ "$t" != '(preamble)' ]; then
      case "$t" in *…) [ "${got#"${t%…}"}" != "$got" ] || bad=$((bad + 1));; *) [ "$got" = "$t" ] || bad=$((bad + 1));; esac
    fi
    [ "$(sed -n "${s},${e}p" "$F" | wc -c | tr -d ' ')" = "$b" ] || bad=$((bad + 1))
  done < <(printf '%s\n' "$O" | tail -n +2)
  echo "$bad"
}

fam_outline() {
  local p=$1 F="$KB/kb/specs/2026-01-06-long-spec.md" O bad=0 n=0 s e b lvl t top=0 got want
  O=$(kbx "$p" outline kb/specs/2026-01-06-long-spec.md)
  has "$(printf '%s\n' "$O" | head -1)" "kb/specs/2026-01-06-long-spec.md: $(wc -l < "$F" | tr -d ' ') lines, $(wc -c < "$F" | tr -d ' ')B" "[O] header: line and byte count of the file"
  while IFS=' ' read -r rng b rest; do
    s=${rng#L}; s=${s%-*}; e=${rng#*-}; b=${b%B}
    t=$(printf '%s' "$rest" | sed 's/^ *//')
    [ "$t" = '(preamble)' ] && { top=$((top + b)); continue; }
    n=$((n + 1))
    got=$(sed -n "${s}p" "$F")
    case "$t" in *…) [ "${got#"${t%…}"}" != "$got" ] || bad=$((bad + 1));; *) [ "$got" = "$t" ] || bad=$((bad + 1));; esac
    [ "$(sed -n "${s},${e}p" "$F" | wc -c | tr -d ' ')" = "$b" ] || bad=$((bad + 1))
    case "$t" in '# '*) top=$((top + b));; esac
  done < <(printf '%s\n' "$O" | tail -n +2)
  want=$(grep -c '^#' "$F"); want=$((want - 2))          # minus the two heading-like lines inside the fence
  eq "$n" "$want" "[O] one row per heading outside fenced code ($want)"
  eq "$bad" 0 "[O] every row: line <start> holds its heading, and sed -n start,end | wc -c equals its bytes"
  eq "$top" "$(wc -c < "$F" | tr -d ' ')" "[O] preamble + top-level sections sum to the file size"
  hasnt "$O" 'not a heading' "[O] heading-like lines in fenced code are not headings"
  hasnt "$O" "$BODY" "[O] no body text"
  eq "$(printf '%s\n' "$O" | grep -c '^L.*  ### Section')" 10 "[O] level-3 headings are indented under level 2"
  kbx "$p" outline kb/specs/missing.md >/dev/null 2>&1; eq "$?" 66 "[O] missing file: rc 66"
  local E="$TMP/edge"; mkdir -p "$E"
  printf '# A\nx\n## B\ny' > "$E/nonl.md"
  printf '# A\r\nx\r\n## B\r\ny\r\n' > "$E/crlf.md"
  printf '# A\nx\ry\n## B\nz\n' > "$E/cr.md"
  printf '# Top\n## Use C#\n````md\n```\n## inside\n```\n````\n   ## Indented\n## Closed ##\n' > "$E/fence.md"
  for f in nonl crlf cr fence; do eq "$(outline_bad "$p" "$E/$f.md")" 0 "[O] $f.md: header, every start line and every section size match the file"; done
  O=$(kbx "$p" outline "$E/fence.md")
  hasnt "$O" 'inside' "[O] a 3-backtick line inside a 4-backtick fence does not close it"
  has "$O" '## Use C#' "[O] a # with no space before it is part of the heading (C#)"
  has "$O" 'L8-8' "[O] a heading indented by 3 spaces is a heading, at its own line"
  has "$O" '## Closed' "[O] a closing run of # after a space is dropped"; hasnt "$O" 'Closed #' "[O] …entirely"
  has "$(kbx "$p" outline "$E/cr.md")" 'L3-' "[O] a lone CR does not end a line (## B is line 3, as grep -n says)"
}

fam_budget() {
  local p=$1 O
  O=$(kbx "$p" find bulk)
  eq "$(printf '%s\n' "$O" | grep -c '^kb/')" 10 "[B] find bulk: 10 lines at the default limit (30 match)"
  [ "$(printf '%s\n' "$O" | wc -c)" -le 3000 ] && ok "[B] find at the default limit: $(printf '%s\n' "$O" | wc -c) B <= 3000" || bad "[B] find: $(printf '%s\n' "$O" | wc -c) B > 3000"
  O=$(kbx "$p" list)
  eq "$(printf '%s\n' "$O" | LC_ALL=C awk 'length($0) > 300' | wc -l | tr -d ' ')" 0 "[B] list: no line over 300 B"
  eq "$(kbx "$p" outline kb/specs/2026-05-01-mot-ten-file-kha-dai-de-thu-ngan-sach-byte-cua-moi-dong.md | tail -n +2 | LC_ALL=C awk 'length($0) > 150' | wc -l | tr -d ' ')" 0 "[B] outline: a Vietnamese heading stays within 150 B a row"
  has "$(kbx "$p" list)" 'kb/specs/2026-05-01-mot-ten-file-kha-dai-de-thu-ngan-sach-byte-cua-moi-dong.md | spec | live | 2026-05-01 | Hiện trạng ệ' "[B] the Vietnamese line is listed (the 300 B check above covers it)"
  O=$(kbx "$p" outline kb/specs/2026-01-06-long-spec.md)
  eq "$(printf '%s\n' "$O" | tail -n +2 | LC_ALL=C awk 'length($0) > 150' | wc -l | tr -d ' ')" 0 "[B] outline: no row over 150 B (headings of 150 characters are cut)"
  [ "$(printf '%s\n' "$O" | wc -c)" -le 6300 ] && ok "[B] outline of a 41-heading spec: $(printf '%s\n' "$O" | wc -c) B <= 6300 (150 B a row + header)" || bad "[B] outline: $(printf '%s\n' "$O" | wc -c) B > 6300"
  for c in "find login --all" "find bulk" "list" "outline kb/specs/2026-01-02-alpha-login.md"; do
    # shellcheck disable=SC2086
    hasnt "$(kbx "$p" $c)" "$BODY" "[B] kb.py $c prints no body text"
  done
}

# lc <name> — a fresh repo with an empty kb/ for one lifecycle case; prints its path
lc() { local r="$TMP/lc-$1"; rm -rf "$r"; mkdir -p "$r/kb"; git_ init -q -b main "$r"; printf '%s' "$r"; }
# chk_ <plugin> <repo> [args] — kb.py check in <repo>; sets CO (stdout), CE (stderr), CRC
chk_() { local p=$1 r=$2; shift 2; CO=$(cd "$r" && python3 "$p/scripts/kb.py" check "$@" 2>"$TMP/chk.err"); CRC=$?; CE=$(cat "$TMP/chk.err"); }

fam_life() {
  local p=$1 r
  r=$(lc good)
  doc "$r" specs/2026-01-01-a.md 'status: superseded\nsuperseded_by: ./kb/specs/2026-01-02-b.md\ndescription: "a"'
  doc "$r" specs/2026-01-02-b.md 'status: live\nsupersedes:\n  - kb/specs/../specs/2026-01-01-a.md\ndescription: "b"'
  doc "$r" intent/2026-01-03-c.md 'status: done\ndescription: "c"'
  doc "$r" plans/2026-01-04-d.md 'status: draft\ndescription: "d"'
  doc "$r" decisions/2026-01-05-e.md 'status: active\ndescription: "e"'
  chk_ "$p" "$r"; eq "$CRC" 0 "[C] good: a superseded pair, done, draft and a legacy active decision pass"
  has "$CO" 'kb/: 5 documents, lifecycle ok' "[C] good: the summary line counts the documents"
  chk_ "$p" "$r" --strict; eq "$CRC" 0 "[C] good: --strict passes when every document has description and status"

  r=$(lc unknown); doc "$r" specs/2026-01-01-a.md 'status: obsolete\ndescription: "a"'
  chk_ "$p" "$r"; eq "$CRC" 65 "[C] unknown status: rc 65"; has "$CE" "kb/specs/2026-01-01-a.md: unknown status 'obsolete'" "[C] unknown status: names the file and the value"

  r=$(lc dangling); doc "$r" specs/2026-01-01-a.md 'status: superseded\nsuperseded_by: kb/specs/2026-09-09-gone.md\ndescription: "a"'
  chk_ "$p" "$r"; eq "$CRC" 65 "[C] dangling superseded_by: rc 65"; has "$CE" 'superseded_by points to a missing file: kb/specs/2026-09-09-gone.md' "[C] dangling: names the missing path"

  r=$(lc dangling2); doc "$r" specs/2026-01-02-b.md 'supersedes: kb/specs/2026-09-09-gone.md\ndescription: "b"'
  chk_ "$p" "$r"; eq "$CRC" 65 "[C] dangling supersedes: rc 65"

  r=$(lc onesided)
  doc "$r" specs/2026-01-01-a.md 'status: superseded\nsuperseded_by: kb/specs/2026-01-02-b.md\ndescription: "a"'
  doc "$r" specs/2026-01-02-b.md 'description: "b"'
  chk_ "$p" "$r"; eq "$CRC" 65 "[C] one-sided (superseded_by without supersedes): rc 65"
  has "$CE" 'kb/specs/2026-01-01-a.md: superseded_by: kb/specs/2026-01-02-b.md does not point back' "[C] one-sided: names both ends"

  r=$(lc onesided2)
  doc "$r" specs/2026-01-01-a.md 'description: "a"'
  doc "$r" specs/2026-01-02-b.md 'supersedes: kb/specs/2026-01-01-a.md\ndescription: "b"'
  chk_ "$p" "$r"; eq "$CRC" 65 "[C] one-sided (supersedes without superseded_by): rc 65"
  has "$CE" 'kb/specs/2026-01-02-b.md: supersedes: kb/specs/2026-01-01-a.md does not point back' "[C] one-sided the other way: names both ends"

  r=$(lc outside)
  printf -- '---\nsupersedes: kb/specs/2026-01-01-a.md\n---\n' > "$r/README.md"
  doc "$r" specs/2026-01-01-a.md 'status: superseded\nsuperseded_by: README.md\ndescription: "a"'
  chk_ "$p" "$r"; eq "$CRC" 65 "[C] superseded_by outside kb/ (even when it points back): rc 65"; has "$CE" 'must be a repo-relative path under kb/: README.md' "[C] outside kb/: says why"
  r=$(lc absolute); doc "$r" specs/2026-01-01-a.md 'status: superseded\nsuperseded_by: /kb/specs/2026-01-02-b.md\ndescription: "a"'
  doc "$r" specs/2026-01-02-b.md 'supersedes: kb/specs/2026-01-01-a.md\ndescription: "b"'
  chk_ "$p" "$r"; has "$CE" 'must be a repo-relative path under kb/: /kb/specs/2026-01-02-b.md' "[C] an absolute path is named as such, not as a missing back-link"
  r=$(lc escape); doc "$r" specs/2026-01-01-a.md 'supersedes: ../outside.md\ndescription: "a"'
  chk_ "$p" "$r"; eq "$CRC" 65 "[C] a link that leaves the repo: rc 65"
  r=$(lc self); doc "$r" specs/2026-01-01-a.md 'status: superseded\nsuperseded_by: kb/specs/2026-01-01-a.md\nsupersedes: kb/specs/2026-01-01-a.md\ndescription: "a"'
  chk_ "$p" "$r"; eq "$CRC" 65 "[C] a document that supersedes itself: rc 65"; has "$CE" 'points to the document itself' "[C] self link: says so"

  r=$(lc nolink); doc "$r" specs/2026-01-01-a.md 'status: superseded\ndescription: "a"'
  chk_ "$p" "$r"; eq "$CRC" 65 "[C] superseded without superseded_by: rc 65"

  r=$(lc strict); doc "$r" specs/2026-01-01-a.md 'status: live'; doc "$r" specs/2026-01-02-b.md 'description: "b"'
  chk_ "$p" "$r"; eq "$CRC" 0 "[C] missing description and status: rc 0 without --strict (status defaults to live)"
  chk_ "$p" "$r" --strict; eq "$CRC" 65 "[C] --strict: rc 65"
  has "$CE" 'kb/specs/2026-01-01-a.md: no description' "[C] --strict: the missing description"; has "$CE" 'kb/specs/2026-01-02-b.md: no status' "[C] --strict: the missing status"

  r=$(lc size)
  doc "$r" specs/2026-01-01-big.md 'description: "big"' "$(head -c 50000 /dev/zero | tr '\0' x)"
  doc "$r" plans/2026-01-02-bigplan.md 'description: "big plan"' "$(head -c 50000 /dev/zero | tr '\0' x)"
  chk_ "$p" "$r"; eq "$CRC" 0 "[C] a spec over 40000 B: rc stays 0"
  has "$CO" 'WARNING kb/specs/2026-01-01-big.md: 500' "[C] the default threshold lists the big spec with its size"
  hasnt "$CO" 'bigplan' "[C] the size guard looks at specs only"
  mkdir -p "$r/.vibemaestro"; printf '{"schema": 1, "kb": {"spec_warn_bytes": 100000}}' > "$r/.vibemaestro/sdlc.json"
  chk_ "$p" "$r"; hasnt "$CO" 'WARNING' "[C] kb.spec_warn_bytes 100000: no warning"
  printf '{"schema": 1, "kb": {"spec_warn_bytes": null}}' > "$r/.vibemaestro/sdlc.json"
  chk_ "$p" "$r"; hasnt "$CO" 'WARNING' "[C] kb.spec_warn_bytes null: the guard is off"
  printf '{"schema": 1, "kb": {"spec_warn_bytes": 0}}' > "$r/.vibemaestro/sdlc.json"
  chk_ "$p" "$r"; eq "$CRC" 65 "[C] kb.spec_warn_bytes 0: invalid config, rc 65"; has "$CE" 'kb.spec_warn_bytes' "[C] invalid config: names the key"
  for c in "find big" "list" "outline kb/specs/2026-01-01-big.md"; do
    # shellcheck disable=SC2086
    (cd "$r" && python3 "$p/scripts/kb.py" $c >/dev/null 2>&1); eq "$?" 65 "[C] invalid config: kb.py $c exits 65 too"
  done
  rm -rf "$r/.vibemaestro"

  r=$(lc markers); doc "$r" specs/2026-01-01-a.md 'description: "a"'
  mkdir -p "$r/.claude"; cp "$HERE/fixtures/hub-shaped/.claude/settings.json" "$r/.claude/settings.json"
  chk_ "$p" "$r"; eq "$CRC" 0 "[C] a repo whose settings name the old project hook scripts: the read-only check runs like anywhere else"
  eq "$(cd "$r" && python3 "$p/scripts/kb.py" find specs 2>/dev/null | cut -d' ' -f1)" kb/specs/2026-01-01-a.md "[C] …and so does find"
}

fam_start() {
  local p=$1 C
  C=$(printf '{"session_id":"%s","hook_event_name":"SessionStart","cwd":"%s"}' "$(sid)" "$KB" | (cd "$KB" && CLAUDE_PROJECT_DIR="$KB" python3 "$p/scripts/session-start.py" boi-canh) | python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])')
  has "$C" "\`python3 \"$p/scripts/kb.py\"\`" "[S] names kb.py of this plugin by its path"
  for w in '`kb/current-state.md` is the map' '`find <words>`' '`list --type intent --status live`' '`outline <file>`'; do has "$C" "$w" "[S] says $w"; done
  hasnt "$C" '2026-03-01-beta-y.md' "[S] lists no intent file to read"
  [ "$(nchars "$C")" -le 9000 ] && ok "[S] context $(nchars "$C") characters <= 9000" || bad "[S] context over 9000: $(nchars "$C")"
}

FAMS="find list outline budget life start"
for f in $FAMS; do echo "== $f (real plugin) =="; "fam_$f" "$PLUGIN"; done

echo "== instrument controls =="
eq "$(nth 'a b
c d' 2)" c "control: nth reads the first word of a line"
[ "$(printf 'x%.0s' $(seq 1 301) | LC_ALL=C awk 'length($0) > 300' | wc -l | tr -d ' ')" = 1 ] && ok "control: the 300 B line filter catches a 301 B line" || bad "control: the line filter misses a long line"
grep -q 'BODY-MARKER-NEVER-PRINTED' "$KB/kb/specs/2026-01-02-alpha-login.md" && ok "control: the body marker is in the fixture (the no-body checks can fail)" || bad "control: no body marker in the fixture"

echo "== planted breaks: each must turn its family red =="
# probe <family> <label> <python old> <python new> [script]: copy the plugin, replace one string in scripts/<script> (default
# kb_index.py), run the family
probe() {
  local fam=$1 label=$2 d n
  d=$(mktemp -d "$TMP/mut.XXXXXX")/plugin; cp -r "$PLUGIN" "$d"   # a unique parent, so two probes never share a copy
  if ! python3 - "$d/scripts/${5:-kb_index.py}" "$3" "$4" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p, encoding="utf-8").read()
if s.count(old) != 1:
    sys.exit(1)
open(p, "w", encoding="utf-8").write(s.replace(old, new))
PY
  then bad "probe $label: the string to break is not in ${5:-kb_index.py} exactly once"; return; fi
  n=$( (PASS=0; FAIL=0; "fam_$fam" "$d" >/dev/null 2>&1; echo "$FAIL") )
  [ "$n" -gt 0 ] && ok "probe $label: family $fam goes red ($n failed checks)" || bad "probe $label: family $fam stays green"
}
probe find "no hiding" 'if d["status"] in HIDDEN and not show_all:' 'if False:'
probe find "rank by score only" 'hits.sort(key=lambda h: (h[0], h[1]), reverse=True)' 'hits.sort(key=lambda h: h[1], reverse=True)'
probe find "oldest first" 'hits.sort(key=lambda h: h[2]["date"], reverse=True)' 'hits.sort(key=lambda h: h[2]["date"])'
probe find "accents kept" 'return "".join(c for c in t if not unicodedata.combining(c))' 'return (text or "").lower()'
probe find "path and description weights swapped" '(3 if w in path else 0) + (2 if w in desc else 0)' '(2 if w in path else 0) + (3 if w in desc else 0)'
probe find "heading hits not capped" 'min(3, sum(1 for h in heads if w in h))' 'sum(1 for h in heads if w in h)'
probe find "headings not scored" 'min(3, sum(1 for h in heads if w in h))' '0'
probe list "README indexed" 'skip = {"kb/README.md"} | set(exclude)' 'skip = set()'
probe list "legacy active kept" 'LEGACY = {"active": "live"}' 'LEGACY = {}'
probe outline "start off by one" 'out.append((n, end, sum(sizes[n - 1:end]), lvl, t))' 'out.append((n + 1, end, sum(sizes[n - 1:end]), lvl, t))'
probe outline "fences ignored" 'fence = (run[0], len(run))' 'pass'
probe outline "any fence line closes" 'elif run[0] == fence[0] and len(run) >= fence[1] and not m.group(2).strip():' 'elif True:'
probe outline "text-mode sizes" 'return ([r.decode("utf-8", "replace").rstrip("\r") for r in raw], [len(r) + e for r, e in zip(raw, ends)])' 'return ([r.decode("utf-8", "replace").rstrip("\r") for r in raw], [len(r.decode("utf-8", "replace").rstrip("\r").encode()) + 1 for r in raw])'
probe outline "closing # without a space" 'HEADING_RX = re.compile(r"^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$")' 'HEADING_RX = re.compile(r"^ {0,3}(#{1,6})(?:[ \t]+(.*?))?[ \t#]*$")'
probe outline "section ends at any heading" 'if lvl2 <= lvl:' 'if True:'
probe budget "line cut in characters" 'return head + cut_bytes(desc, max(room, 20)) + tail' 'return head + desc + tail'
probe budget "row cut in characters" 'out.append(head + cut_bytes(cut(t, HEAD_MAX), max(ROW_MAX - len(head.encode("utf-8")), 20)))' 'out.append(head + cut(t, HEAD_MAX))'
probe budget "no default limit" 'FIND_LIMIT = 10' 'FIND_LIMIT = 1000'
probe start "old reminder" '"`find <words>` (one line per document, superseded/done hidden)' '"read every file in kb/ (one line per document, superseded/done hidden)' vsdlc.py
probe life "paths not normalised" 'out.append(posixpath.normpath(p))' 'out.append(p)'
probe life "links may leave kb/" 'if q.startswith("/") or not q.startswith("kb/"):' 'if False:'
probe life "self link accepted" '                if q == p:' '                if False:'
probe life "check with no target not routed" 'all(a == "--strict" for a in argv[1:])' 'False' kb.py
probe life "no back-link check" 'elif p not in t[back]:' 'elif False:'
probe life "no missing-file check" '                if t is None:' '                if False:'
probe life "any status accepted" 'if d["status_raw"] and d["status_raw"] not in STATUSES and d["status_raw"] not in LEGACY:' 'if False:'
probe life "superseded needs no link" 'if d["status"] == "superseded" and not d["superseded_by"]:' 'if False:'
probe life "strict ignored" '        if strict:' '        if False:'
probe life "no size guard" 'if spec_warn and d["type"] == "spec" and d["bytes"] > spec_warn:' 'if False:'
probe life "size guard on every type" 'if spec_warn and d["type"] == "spec" and d["bytes"] > spec_warn:' 'if spec_warn and d["bytes"] > spec_warn:'

summary
