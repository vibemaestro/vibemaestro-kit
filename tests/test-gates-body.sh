#!/bin/bash
# =============================================================================
# Gate: the cap on the PR body (plugins/vibemaestro-sdlc/gates/pr_body.py): 3000 characters, summary 10 lines, evidence 30 lines
# =============================================================================
# Run: bash tests/test-gates-body.sh
#
#   [L] the total: exactly the limit passes, one over is red; characters not bytes; CRLF and surrounding whitespace; no headings
#   [S] the sections: summary 10/11 and evidence 30/31 lines, blank lines, fence delimiters, sub-headings, flow and criteria lines
#   [H] the headings: levels, case, emphasis, colon, closing hashes, setext, a suffix, fences, a heading twice, the `en` tokens
#   [K] the config: each limit at 0 is off, a custom limit, an invalid value is rc 65 naming the key
#   [G] --pr through a fake gh (red, green, a null body, gh failing, --repo), --body-file, usage
#   [B] the base-ref rule: a PR that raises its own limit is judged by the base; a bad ref; the standard library only
#   [X] what GitHub does not show or reads alike: headings in HTML comments and list fences, look-alike headings (spaces, invisible
#       characters, emoji, numbers, links, NFD), `<h2>`, the not-run note, a hostile long line, characters outside the BMP
# The workflow template is tested by tests/test-gates-workflows.sh; open_pr.py's refusal by tests/test-core-pr.sh ([P12]).
# Each family also runs on a copy of the plugin with ONE planted break and must go red. Real git, a fake gh, no network, no sleep.
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
# shellcheck source=fixtures/gates.sh
. "$HERE/fixtures/gates.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
[ -f "$PLUGIN/gates/pr_body.py" ] && ok "the gate exists" || { bad "the gate is missing"; summary; exit 1; }

PB() { printf '%s' "$1/gates/pr_body.py"; }
cfgrepo() { local r; r=$(mk_repo t); put_cfg "$r" "$1"; echo "$r"; }

# mkbody <summary lines> <evidence lines> [total characters] — the shape open_pr.py builds, in the vi tokens; the flow section is padded
# with one line of `y` so that the whole body is exactly <total> characters once stripped
mkbody() {
  python3 - "$1" "$2" "${3:-0}" <<'PY'
import sys
s, e, total = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
b = ("## Tóm tắt\n\n" + "\n".join("s%d" % i for i in range(s)) + "\n\n## Bằng chứng chạy\n\n```\n"
     + "\n".join("e%d" % i for i in range(e)) + "\n```\n\n## Luồng\n\n- [x] a\n")
if total:
    b = b.rstrip("\n") + "\n" + "y" * (total - len(b.rstrip("\n")) - 1)
sys.stdout.write(b)
PY
}
# gb <repo> <body text> [gate args...] — run the gate on a body, from a file; sets RC and OUT
gb() {
  local r=$1 t=$2; shift 2
  printf '%s' "$t" > "$TMP/body.md"
  RC=0; OUT=$(cenv python3 "$PB_P" --cwd "$r" --body-file "$TMP/body.md" "$@" 2>&1) || RC=$?
}
# the gate of the copy under test: families set PB_P
fam_total() {
  local p=$1 r b; PB_P=$(PB "$p"); r=$(cfgrepo '{}')
  gb "$r" "$(mkbody 10 30 3000)"; want 0 "[L] a body of exactly 3000 characters (10 summary lines, 30 evidence lines): green"
  [ "$(printf '%s' "$(mkbody 10 30 3000)" | python3 -c 'import sys; print(len(sys.stdin.read().strip()))')" = 3000 ] && ok "[L] …control: the body is 3000 characters" || bad "[L] the fixture is not 3000 characters"
  gb "$r" "$(mkbody 10 30 3001)"; want 1 "[L] one character over: red" "over pr.body.max_chars (3000)"
  has_q "3001 characters" && ok "[L] …the numbers are in the message" || bad "[L] no count in: $OUT"
  gb "$r" "$(python3 -c 'print("x" * 3000, end="")')"; want 0 "[L] no headings, 3000 characters: green (judged on the total only)"
  gb "$r" "$(python3 -c 'print("x" * 3001, end="")')"; want 1 "[L] no headings, 3001 characters: red"
  gb "$r" "$(python3 -c 'print("line\n" * 40, end="")')"; want 0 "[L] no headings and 40 short lines: green (nothing to count lines on)"
  gb "$r" ""; want 0 "[L] an empty body: green"
  gb "$r" "$(python3 -c 'print("é" * 3000, end="")')"; want 0 "[L] 3000 accented characters (6000 bytes): green, the unit is the character"
  gb "$r" "$(python3 -c 'print("\n\n  " + "x" * 3000 + "  \n\n", end="")')"; want 0 "[L] leading and trailing whitespace is not counted"
  python3 -c 'import sys; sys.stdout.buffer.write(("ab\n" * 1000)[:2999].replace("\n", "\r\n").encode())' > "$TMP/crlf.md"
  RC=0; OUT=$(cenv python3 "$PB_P" --cwd "$r" --body-file "$TMP/crlf.md" 2>&1) || RC=$?
  want 0 "[L] 1000 lines of CRLF (about 3999 bytes, 2999 characters read as LF): green, a CRLF is one character"
  RC=0; OUT=$(cenv python3 "$PB_P" --cwd "$r" --body-file - < "$TMP/crlf.md" 2>&1) || RC=$?
  want 0 "[L] --body-file - reads stdin"
}

fam_sections() {
  local p=$1 r; PB_P=$(PB "$p"); r=$(cfgrepo '{}')
  gb "$r" "$(mkbody 10 5)"; want 0 "[S] summary of 10 lines: green"
  gb "$r" "$(mkbody 11 5)"; want 1 "[S] summary of 11 lines: red" "pr.body.summary_max_lines (10)"
  has_q "11 non-empty lines" && ok "[S] …with the count" || bad "[S] no count in: $OUT"
  gb "$r" "$(mkbody 3 30)"; want 0 "[S] evidence of 30 lines: green"
  gb "$r" "$(mkbody 3 31)"; want 1 "[S] evidence of 31 lines: red" "pr.body.evidence_max_lines (30)"
  gb "$r" "$(mkbody 11 31)"; want 1 "[S] both over: red"
  [ "$(printf '%s\n' "$OUT" | grep -c '^  - ')" = 2 ] && ok "[S] …each violation on its own line" || bad "[S] not two violation lines: $OUT"
  gb "$r" "$(python3 -c 'print("## Tóm tắt\n\n" + "a\n\n\n" * 10 + "\n## Bằng chứng chạy\nx\n", end="")')"; want 0 "[S] ten lines with blank lines between: blank lines are not counted"
  gb "$r" "$(python3 -c 'print("## Tóm tắt\n\n" + "a\n" * 8 + "### Rủi ro\nb\nc\nd\n\n## Bằng chứng chạy\nx\n", end="")')"; want 1 "[S] a sub-heading of the author's own does not end the summary: 12 lines" "pr.body.summary_max_lines (10)"
  gb "$r" "$(python3 -c 'print("## Tóm tắt\nx\n## Tiêu chí chấp nhận\n" + "- [ ] c\n" * 40 + "## Bằng chứng chạy\ny\n## Luồng\n" + "- [x] f\n" * 40, end="")')"; want 0 "[S] 40 criteria lines and 40 flow lines are not the summary or the evidence: green"
  gb "$r" "$(python3 -c 'print("Closes #1\nPatch for #2\n\n## Tóm tắt\n" + "a\n" * 10 + "## Bằng chứng chạy\nb\n", end="")')"; want 0 "[S] lines above the summary are not the summary"
  gb "$r" "$(python3 -c 'print("## Tóm tắt\nx\n## Bằng chứng chạy\n~~~~\n" + "e\n" * 30 + "~~~~\n", end="")')"; want 0 "[S] a tilde fence around 30 evidence lines: its delimiters are free"
  gb "$r" "$(python3 -c 'print("## Tóm tắt\nx\n## Bằng chứng chạy\n```\n" + "e\n" * 31 + "```\n", end="")')"; want 1 "[S] the same with 31: red"
  gb "$r" "$(python3 -c 'print("## Tóm tắt\nx\n## Bằng chứng chạy\n" + "<!-- hidden -->\n" * 31, end="")')"; want 1 "[S] HTML comment lines are body: 31 of them are red"
}

fam_headings() {
  local p=$1 r; PB_P=$(PB "$p"); r=$(cfgrepo '{}')
  local eleven; eleven=$(python3 -c 'print("a\n" * 11, end="")')
  local h
  for h in '### Tóm tắt' '# Tóm tắt' '###### Tóm tắt' '## tóm tắt' '## TÓM TẮT' '## Tóm tắt:' '## **Tóm tắt**' '## _Tóm tắt_' '## Tóm tắt ##' '## Tóm tắt (vòng 2)' '   ## Tóm tắt' '##  Tóm tắt  '; do
    gb "$r" "$h
$eleven"; want 1 "[H] the heading «$h» finds the summary: 11 lines are red" "pr.body.summary_max_lines (10)"
  done
  gb "$r" "Tóm tắt
---
$eleven"; want 1 "[H] a setext heading (underlined with ---) finds the summary" "pr.body.summary_max_lines (10)"
  gb "$r" "Tóm tắt
===
$eleven"; want 1 "[H] a setext heading (underlined with ===) finds the summary" "pr.body.summary_max_lines (10)"
  gb "$r" "Tóm tắt
---
$eleven"; want 1 "[H] the setext heading and its underline are not counted as lines (11, not 13)" "11 non-empty lines"
  gb "$r" "## Tóm tắtdài
$eleven"; want 0 "[H] «Tóm tắtdài» is another word, not the token: not a heading, so no line count (green)"
  gb "$r" "    ## Tóm tắt
$eleven"; want 0 "[H] an indented code block is not a heading: green"
  gb "$r" "#Tóm tắt
$eleven"; want 0 "[H] «#Tóm tắt» without a space is not a heading: green"
  gb "$r" "## Summary
$eleven"; want 0 "[H] «Summary» is not the token of the vi preset: green (judged on the total only)"
  gb "$r" "## Tóm tắt
$(python3 -c 'print("a\n" * 6, end="")')
## Tóm tắt
$(python3 -c 'print("b\n" * 6, end="")')"; want 1 "[H] a summary heading twice counts as the sum (6 + 6)" "pr.body.summary_max_lines (10)"
  gb "$r" "## Tóm tắt
x
## Bằng chứng chạy
\`\`\`
## Luồng
$(python3 -c 'print("e\n" * 30, end="")')
\`\`\`
## Luồng
- [x] a"; want 1 "[H] a flow heading inside the evidence fence does not end the evidence: 31 lines" "pr.body.evidence_max_lines (30)"
  gb "$r" "## Tóm tắt
\`\`\`
$eleven
## Bằng chứng chạy
b"; want 1 "[H] an unclosed fence runs to the end: the evidence heading in it is text, 13 summary lines" "13 non-empty lines"
  gb "$r" "## Tóm tắt
$eleven
## Bằng chứng chạy
b"; want 1 "[H] control: the evidence heading right after the summary ends it (11 lines, red)"
  local rr; rr=$(cfgrepo '{"language": "en"}')
  gb "$rr" "## Summary
$eleven"; want 1 "[H] language en: «Summary» finds the summary" "pr.body.summary_max_lines (10)"
  gb "$rr" "## Run evidence
$(python3 -c 'print("e\n" * 31, end="")')"; want 1 "[H] language en: «Run evidence» finds the evidence" "pr.body.evidence_max_lines (30)"
  gb "$rr" "## Tóm tắt
$eleven"; want 0 "[H] language en: the vi heading is no longer a heading: green"
  rr=$(cfgrepo '{"tokens": {"summary_heading": "What changed"}}')
  gb "$rr" "## What changed
$eleven"; want 1 "[H] a custom tokens.summary_heading is the one searched" "pr.body.summary_max_lines (10)"
}

fam_hidden() {
  local p=$1 r h; PB_P=$(PB "$p"); r=$(cfgrepo '{}')
  local forty; forty=$(python3 -c 'print("\n".join("s%d" % i for i in range(40)), end="")')
  gb "$r" "## Tóm tắt
s1
<!--
## Tiêu chí chấp nhận
-->
$forty"; want 1 "[X] a criteria heading hidden in an HTML comment does not cut the summary: 41 lines" "pr.body.summary_max_lines (10)"
  gb "$r" "## Bằng chứng chạy

<!--
## Luồng
-->
$forty"; want 1 "[X] a flow heading hidden in an HTML comment does not cut the evidence" "pr.body.evidence_max_lines (30)"
  gb "$r" "## Bằng chứng chạy
<!-- ## Luồng -->
$forty"; want 1 "[X] the same on one line" "pr.body.evidence_max_lines (30)"
  gb "$r" "## Tóm tắt
<!-- a note --> text
$forty
<!--
## Bằng chứng chạy
-->"; want 1 "[X] an evidence heading hidden inside the summary does not start the evidence: the lines stay in the summary" "pr.body.summary_max_lines (10)"
  gb "$r" "## Tóm tắt
a
<!-- closed -->
## Bằng chứng chạy
$forty"; want 1 "[X] control: a heading after a closed comment is a heading (the evidence has 40 lines)" "pr.body.evidence_max_lines (30)"
  gb "$r" "## Tóm tắt
- \`\`\`
  ## Tiêu chí chấp nhận
  \`\`\`
$forty"; want 1 "[X] a fence opened inside a list item hides its heading: 41 summary lines" "pr.body.summary_max_lines (10)"
  gb "$r" "## Tóm tắt

Rename the \`<!--\` handling.

## Bằng chứng chạy

\`\`\`
$(python3 -c 'print("\n".join("e%d" % i for i in range(20)), end="")')
\`\`\`

## Luồng

- [x] a"; want 0 "[X] a <!-- in the middle of a line is plain text: it opens no comment (20 evidence lines, green)"
  gb "$r" "## Tiêu chí chấp nhận
- [ ] a
x <!--
## Bằng chứng chạy
$forty"; want 1 "[X] a <!-- in the middle of a line does not hide the evidence heading after it" "pr.body.evidence_max_lines (30)"
  gb "$r" "## Tiêu chí chấp nhận
- [ ] a
<!-->
## Bằng chứng chạy
$forty"; want 1 "[X] <!--> is a comment that ends where it starts: the evidence heading after it counts" "pr.body.evidence_max_lines (30)"
  gb "$r" "## Tiêu chí chấp nhận
- [ ] a
<!--
a note
-->
## Bằng chứng chạy
$forty"; want 1 "[X] control: a heading after a multi-line comment block is a heading" "pr.body.evidence_max_lines (30)"
  gb "$r" "## Tiêu chí chấp nhận
- [ ] a
    <!--
## Bằng chứng chạy
$forty"; want 1 "[X] a 4-space indented <!-- is no comment block: the heading after it counts" "pr.body.evidence_max_lines (30)"
  gb "$r" "## Tiêu chí chấp nhận
- [ ] a
para
    \`\`\`
## Bằng chứng chạy
$forty"; want 1 "[X] an indented fence line after a paragraph opens no fence: the heading after it counts" "pr.body.evidence_max_lines (30)"
  gb "$r" "## Tiêu chí chấp nhận
- [ ] a
## Bằng chứng chạy ($(python3 -c 'print("x" * 500, end="")'))
$forty"; want 1 "[X] a heading of more than 500 characters is still a heading" "pr.body.evidence_max_lines (30)"
  gb "$r" "x <!--
## Tóm tắt
$forty"; want 1 "[X] a <!-- before the summary heading does not hide it" "pr.body.summary_max_lines (10)"
  gb "$r" "## Bằng chứng chạy
x
## 9 Luồng
$forty"; want 1 "[X] a heading that only looks like the flow heading (## 9 Luồng) does not end the evidence" "pr.body.evidence_max_lines (30)"
  gb "$r" "## Tiêu chí chấp nhận
- [ ] a
## 9 Bằng chứng chạy
$forty"; want 1 "[X] …but one that looks like the evidence heading starts it from outside a measured section (lenient to start)" "pr.body.evidence_max_lines (30)"
  gb "$r" "## Tóm tắt
mở
### Luồng xử lý
$(python3 -c 'print("\n".join("d%d" % i for i in range(20)), end="")')
## Bằng chứng chạy
x"; want 1 "[X] a summary sub-heading that starts with the flow word (### Luồng xử lý) does not end the summary" "pr.body.summary_max_lines (10)"
  gb "$r" "## Bằng chứng chạy
x
### Tiêu chí chấp nhận (nháp)
$forty"; want 1 "[X] an evidence sub-heading that starts with the criteria words does not end the evidence" "pr.body.evidence_max_lines (30)"
  local rr; rr=$(cfgrepo '{"language": "en"}')
  gb "$rr" "## Summary
mo
### Flow of data
$(python3 -c 'print("\n".join("d%d" % i for i in range(20)), end="")')"; want 1 "[X] language en: ### Flow of data does not end the summary" "pr.body.summary_max_lines (10)"
  gb "$r" "## Bằng chứng chạy
$(python3 -c 'print("\n".join("e%d" % i for i in range(20)), end="")')
## Luồng ##
$(python3 -c 'print("\n".join("f%d" % i for i in range(12)), end="")')"; want 0 "[X] a flow heading with an ATX closing sequence (## Luồng ##) still ends the evidence: 20 lines, green"
  local honest n3=0 H3; mapfile -t H3 < <(python3 - <<'PY'
for h in ["## B\u1eb1ng ch\u1ee9ng ch\u1ea1y:", "## 2. B\u1eb1ng ch\u1ee9ng ch\u1ea1y", "## **B\u1eb1ng ch\u1ee9ng ch\u1ea1y**", "## B\u1eb1ng ch\u1ee9ng ch\u1ea1y (v\u00f2ng 2)", "### B\u1eb1ng ch\u1ee9ng ch\u1ea1y th\u1eed"]:
    print(h)
PY
)
  for honest in "${H3[@]}"; do
    n3=$((n3+1))
    gb "$r" "## Tóm tắt
a
b
c
$honest
$(python3 -c 'print("\n".join("e%d" % i for i in range(20)), end="")')
## Luồng
- [x] a"; want 0 "[X] honest evidence heading #$n3 «$honest» after a 3-line summary and before 20 lines: summary 3, evidence 20, green (a lenient heading switches by design: the total cap bounds the rest)"
  done
  gb "$r" "## Tóm tắt
a
## Bằng chứng chạy
$(python3 -c 'print("\n".join("e%d" % i for i in range(31)), end="")')"; want 1 "[X] control: the exact evidence heading still switches from the summary" "pr.body.evidence_max_lines (30)"
  local eleven; eleven=$(python3 -c 'print("a\n" * 11, end="")')
  local FILL n2=0; mapfile -t FILL < <(python3 - <<'PY'
for ch in ["\u200e", "\u202e", "\u2066", "\u061c", "\u034f", "\u115f", "\u1160", "\u3164", "\uffa0", "\U000e0020"]:
    print("## T\u00f3" + ch + "m t\u1eaft")
PY
)
  for h in "${FILL[@]}"; do
    n2=$((n2+1))
    gb "$r" "$h
$eleven"; want 1 "[X] invisible or filler character #$n2 inside the heading word does not hide the summary" "pr.body.summary_max_lines (10)"
  done
  local nl; nl=$(cenv python3 "$p/scripts/sdlc_config.py" get tokens.not_run_note --root "$r")
  gb "$r" "## Bằng chứng chạy
$(python3 -c 'import sys; print((sys.argv[1] + "\n") * 35, end="")' "$nl")"; want 1 "[X] the not-run note repeated 35 times is 35 lines: only the first one is the kit's" "pr.body.evidence_max_lines (30)"
  local eleven; eleven=$(python3 -c 'print("a\n" * 11, end="")')
  local HEADS n=0; mapfile -t HEADS < <(python3 - <<'PY'
for h in ["## T\u00f3m\u00a0t\u1eaft", "## T\u00f3m  t\u1eaft", "## \u200bT\u00f3m t\u1eaft", "## ~~T\u00f3m t\u1eaft~~", "## \U0001f4dd T\u00f3m t\u1eaft",
          "## 1. T\u00f3m t\u1eaft", "## [T\u00f3m t\u1eaft](x)", "## `T\u00f3m t\u1eaft`", "<h2>T\u00f3m t\u1eaft</h2>", "<h3 id=x>T\u00f3m t\u1eaft",
          "## T\u00f3m\u200b t\u1eaft", "## <b>T\u00f3m t\u1eaft</b>"]:
    print(h)
PY
)
  for h in "${HEADS[@]}"; do
    n=$((n+1))
    gb "$r" "$h
$eleven"; want 1 "[X] look-alike heading #$n «$h» finds the summary" "pr.body.summary_max_lines (10)"
  done
  gb "$r" "$(python3 -c 'import unicodedata; print(unicodedata.normalize("NFD", "## Tóm tắt") + "\n" + "a\n" * 11, end="")')"; want 1 "[X] a heading in NFD (decomposed accents) finds the summary" "pr.body.summary_max_lines (10)"
  gb "$r" "$(python3 -c 'print("\u00a0\u00a0## Tóm tắt\n" + "a\n" * 11, end="")')"; want 0 "[X] control: a non-breaking-space INDENT is not a markdown indent: not a heading (green)"
  local note; note=$(cenv python3 "$p/scripts/sdlc_config.py" get tokens.not_run_note --root "$r")
  gb "$r" "## Bằng chứng chạy

$note

\`\`\`
$(python3 -c 'print("\n".join("e%d" % i for i in range(30)), end="")')
\`\`\`"; want 0 "[X] the not-run note above 30 evidence lines is the kit's own line: green"
  gb "$r" "## Bằng chứng chạy

$note

\`\`\`
$(python3 -c 'print("\n".join("e%d" % i for i in range(31)), end="")')
\`\`\`"; want 1 "[X] …and 31 lines with it are red" "pr.body.evidence_max_lines (30)"
  gb "$r" "$(python3 -c 'print("😀" * 3000, end="")')"; want 0 "[X] 3000 characters outside the BMP: green (a character, not a UTF-16 unit)"
  gb "$r" "$(python3 -c 'print("😀" * 3001, end="")')"; want 1 "[X] 3001: red"
  local rr; rr=$(cfgrepo '{"pr": {"body": {"max_chars": 0}}}')
  printf '## a%*sb\n' 60000 '' > "$TMP/long.md"
  RC=0; OUT=$(cenv timeout 5 python3 "$PB_P" --cwd "$rr" --body-file "$TMP/long.md" 2>&1) || RC=$?
  want 0 "[X] a 60000-character line that starts like a heading is judged at once (no 5-second timeout)"
}

fam_config() {
  local p=$1 r; PB_P=$(PB "$p"); r=$(cfgrepo '{"pr": {"body": {"max_chars": 0}}}')
  gb "$r" "$(python3 -c 'print("x" * 20000, end="")')"; want 0 "[K] max_chars 0: the total is not limited"
  r=$(cfgrepo '{"pr": {"body": {"summary_max_lines": 0}}}')
  gb "$r" "$(mkbody 80 5)"; want 0 "[K] summary_max_lines 0: the summary is not limited"
  gb "$r" "$(mkbody 3 31)"; want 1 "[K] …the evidence limit still applies" "pr.body.evidence_max_lines (30)"
  r=$(cfgrepo '{"pr": {"body": {"evidence_max_lines": 0}}}')
  gb "$r" "$(mkbody 3 90)"; want 0 "[K] evidence_max_lines 0: the evidence is not limited"
  gb "$r" "$(mkbody 11 3)"; want 1 "[K] …the summary limit still applies"
  r=$(cfgrepo '{"pr": {"body": {"max_chars": 0, "summary_max_lines": 0, "evidence_max_lines": 0}}}')
  gb "$r" "$(mkbody 80 90 9000)"; want 0 "[K] all three at 0: nothing is limited"
  r=$(cfgrepo '{"pr": {"body": {"max_chars": 100, "summary_max_lines": 2, "evidence_max_lines": 3}}}')
  gb "$r" "$(python3 -c 'print("x" * 100, end="")')"; want 0 "[K] a custom max_chars 100: 100 characters green"
  gb "$r" "$(python3 -c 'print("x" * 101, end="")')"; want 1 "[K] …101 red" "pr.body.max_chars (100)"
  gb "$r" "## Tóm tắt
a
b
## Bằng chứng chạy
c
d
e"; want 0 "[K] custom summary 2 and evidence 3: at the limits green"
  gb "$r" "## Tóm tắt
a
b
c
## Bằng chứng chạy
c
d
e
f"; want 1 "[K] …one over each: red"
  r=$(cfgrepo '{"pr": {"body": {"max_chars": -1}}}'); gb "$r" "x"; want 65 "[K] a negative limit is rc 65 and names the key" pr.body.max_chars
  r=$(cfgrepo '{"pr": {"body": {"summary_max_lines": "ten"}}}'); gb "$r" "x"; want 65 "[K] a string limit is rc 65" pr.body.summary_max_lines
  r=$(cfgrepo '{"pr": {"body": {"evidence_max_lines": 1.5}}}'); gb "$r" "x"; want 65 "[K] a fractional limit is rc 65" pr.body.evidence_max_lines
  r=$(cfgrepo '{"pr": {"body": {"max_chars": "3000"}}}'); gb "$r" "x"; want 65 "[K] a wrong-typed limit (a string) is rc 65" pr.body.max_chars
  r=$(cfgrepo '{}')
  [ "$(cenv python3 "$p/scripts/sdlc_config.py" get pr.body.max_chars --root "$r" 2>&1)" = 3000 ] && ok "[K] the default max_chars is 3000" || bad "[K] default max_chars: $(cenv python3 "$p/scripts/sdlc_config.py" get pr.body.max_chars --root "$r" 2>&1)"
  [ "$(cenv python3 "$p/scripts/sdlc_config.py" get pr.body.summary_max_lines --root "$r" 2>&1)" = 10 ] && ok "[K] the default summary_max_lines is 10" || bad "[K] default summary_max_lines"
  [ "$(cenv python3 "$p/scripts/sdlc_config.py" get pr.body.evidence_max_lines --root "$r" 2>&1)" = 30 ] && ok "[K] the default evidence_max_lines is 30" || bad "[K] default evidence_max_lines"
  # an older body that still carries the flow checklist (open-pr.sh no longer writes it): it is read as before, never refused
  r=$(cfgrepo '{}'); gb "$r" "$(cat "$HERE/fixtures/pr-body-old-flow.md")"; want 0 "[K] an older body with its flow checklist (## Luồng and ticks) passes"
  gb "$r" "$(cat "$HERE/fixtures/pr-body-old-flow.md")
- [ ] one more flow line"; want 0 "[K] …its flow lines count toward the total only, not the evidence"
}

fam_gh() {
  local p=$1 d r; PB_P=$(PB "$p")
  d=$(mktemp -d "$TMP/gh.XXXXXX"); install_gate_gh "$d/bin" >/dev/null; r=$(cfgrepo '{}')
  prun() {  # prun <view json> [extra fixture json] [gate args...]
    python3 - "$d/fx.json" "$1" "${2:-{\}}" <<'PY'
import json, sys
out, view, extra = sys.argv[1:4]
fx = {"pr view": json.loads(view)}
fx.update(json.loads(extra)); json.dump(fx, open(out, "w"))
PY
    : > "$d/gh.log"
    RC=0; OUT=$(cenv PATH="$d/bin:$PATH" FAKE_GH_LOG="$d/gh.log" FAKE_GH_FX="$d/fx.json" python3 "$PB_P" --cwd "$r" --pr 246 "${@:3}" 2>&1) || RC=$?
  }
  prun "$(python3 -c 'import json; print(json.dumps({"body": "x" * 3001}))')"; want 1 "[G] --pr: the live body is over: red" "pr.body.max_chars (3000)"
  prun "$(python3 -c 'import json; print(json.dumps({"body": "x" * 3000}))')"; want 0 "[G] --pr: 3000 characters: green"
  grep -qF 'pr view 246' "$d/gh.log" && grep -qF -- '--json body' "$d/gh.log" && ok "[G] …the body is read through gh pr view --json body" || bad "[G] unexpected gh call: $(cat "$d/gh.log")"
  prun '{"body": null}'; want 0 "[G] a null body (gh prints null for an empty body): green"
  prun '{"body": "x"}' '{"__fail__": true}'; want 2 "[G] gh failing: rc 2, never green"
  prun '{"title": "no body key"}'; want 2 "[G] a view without a body key: rc 2, never green (gh always prints it)"
  prun '{"body": "x"}' '{}' --repo acme/service
  grep -qF -- '-R acme/service' "$d/gh.log" && ok "[G] --repo is passed to gh" || bad "[G] --repo not passed: $(cat "$d/gh.log")"
  RC=0; OUT=$(cenv python3 "$PB_P" --cwd "$r" 2>&1) || RC=$?; want 64 "[G] no --pr and no --body-file: usage, rc 64"
  RC=0; OUT=$(cenv python3 "$PB_P" --cwd "$r" --pr 1 --body-file x 2>&1) || RC=$?; want 64 "[G] both --pr and --body-file: rc 64"
  RC=0; OUT=$(cenv python3 "$PB_P" --cwd "$r" --pr 2>&1) || RC=$?; want 64 "[G] --pr with no number: rc 64"
  RC=0; OUT=$(cenv python3 "$PB_P" --cwd "$r" --body-file "$TMP/x" --bogus 2>&1) || RC=$?; want 64 "[G] an unknown flag: rc 64"
  RC=0; OUT=$(cenv python3 "$PB_P" --cwd "$r" --body-file "$TMP/does-not-exist.md" 2>&1) || RC=$?; want 2 "[G] a body file that cannot be read: rc 2, not green"
}

fam_base() {
  local p=$1 r; PB_P=$(PB "$p")
  r=$(mk_repo base); commit_cfg "$r" '{"pr": {"body": {"max_chars": 100}}}' "base: config"; G -C "$r" branch base
  G -C "$r" checkout -qb pr; commit_cfg "$r" '{"pr": {"body": {"max_chars": 0}}}' "head: removes the cap"
  local long; long=$(python3 -c 'print("x" * 150, end="")')
  gb "$r" "$long" --config-ref base; want 1 "[B] a PR that removes its own cap is judged by the base: red" "max_chars (100)"
  gb "$r" "$long"; want 0 "[B] control: without the ref the head's config applies: green"
  gb "$r" "$long" --config-ref no-such-ref; want 2 "[B] a ref that does not read: rc 2, not green"
  r=$(mk_repo nocfg); G -C "$r" branch base; put_cfg "$r" '{"pr": {"body": {"max_chars": 5}}}'
  gb "$r" "$long" --config-ref base; want 0 "[B] a base with no config file means the defaults (3000): 150 characters green"
  gb "$r" "$(python3 -c 'print("x" * 3001, end="")')" --config-ref base; want 1 "[B] …and 3001 is red under the defaults of the base" "max_chars (3000)"
  local rb; rb=$(mk_repo badbase); commit_cfg "$rb" '{"pr": {"body": {"max_chars": "x"}}}' "base: invalid"; G -C "$rb" branch base
  gb "$rb" "$long" --config-ref base; want 65 "[B] an invalid config AT THE BASE REF is rc 65 and names the key" pr.body.max_chars
  python3 - "$p/gates/pr_body.py" <<'PY' && ok "[B] the gate parses as Python 3.8 and imports only the standard library" || bad "[B] the gate is not Python 3.8 or imports something else"
import ast, sys
tree = ast.parse(open(sys.argv[1], encoding="utf-8").read(), feature_version=(3, 8))
allowed = {"json", "re", "subprocess", "sys", "unicodedata", "gate_common"}
imports = set()
for n in ast.walk(tree):
    if isinstance(n, ast.Import):
        imports |= {a.name.split(".")[0] for a in n.names}
    elif isinstance(n, ast.ImportFrom):
        imports.add((n.module or "").split(".")[0])
sys.exit(1 if imports - allowed else 0)
PY
}

FAMILIES="fam_total fam_sections fam_headings fam_hidden fam_config fam_gh fam_base"
for f in $FAMILIES; do "$f" "$PLUGIN"; done

echo "== planted breaks: each turns its family red =="
T=pr_body.py
BRKG total-off-by-one fam_total '[L] a body of exactly 3000' $T 'if lim["max_chars"] and n > lim["max_chars"]:' 'if lim["max_chars"] and n >= lim["max_chars"]:'
BRKG total-never fam_total '[L] one character over' $T 'if lim["max_chars"] and n > lim["max_chars"]:' 'if False:'
BRKG total-in-bytes fam_total '[L] 3000 accented characters' $T 'n = len(body.replace("\r\n", "\n").strip())' 'n = len(body.replace("\r\n", "\n").strip().encode("utf-8"))'
BRKG total-crlf-counted fam_total '[L] 1000 lines of CRLF' $T 'n = len(body.replace("\r\n", "\n").strip())' 'n = len(body.strip())'
BRKG total-not-stripped fam_total '[L] leading and trailing whitespace' $T 'n = len(body.replace("\r\n", "\n").strip())' 'n = len(body.replace("\r\n", "\n"))'
BRKG summary-off-by-one fam_sections '[S] summary of 10 lines' $T 'counts[key] > lim[limit_key]' 'counts[key] >= lim[limit_key]'
BRKG summary-never fam_sections '[S] summary of 11 lines' $T 'if lim[limit_key] and counts[key] > lim[limit_key]:' 'if key != "summary_heading" and lim[limit_key] and counts[key] > lim[limit_key]:'
BRKG evidence-never fam_sections '[S] evidence of 31 lines' $T 'if lim[limit_key] and counts[key] > lim[limit_key]:' 'if key != "evidence_heading" and lim[limit_key] and counts[key] > lim[limit_key]:'
BRKG flow-counted-as-evidence fam_sections '[S] 40 criteria lines' $T 'SECTIONS = ("summary_heading", "criteria_heading", "evidence_heading", "flow_heading")' 'SECTIONS = ("summary_heading", "evidence_heading")'
BRKG fence-ignored fam_headings 'flow heading inside the evidence fence' $T '        if fence:
            if re.match' '        if False:
            if re.match'
BRKG prefix-without-boundary fam_headings '«Tóm tắtdài» is another word' $T 'not t[len(tok)].isalnum()' 'True'
BRKG setext-ignored fam_headings 'setext heading (underlined with ---)' $T 'if line.strip() and nxt is not None and _SETEXT_UNDERLINE.match(nxt)' 'if False and nxt is not None and _SETEXT_UNDERLINE.match(nxt)'
BRKG setext-underline-counted fam_headings 'underline are not counted' $T '                i += 1 if h[1] else 0' '                i += 0'
BRKG indent-code-is-heading fam_headings 'an indented code block is not a heading' $T '_ATX = re.compile(r"^ {0,3}#{1,6}' '_ATX = re.compile(r"^ *#{1,6}'
BRKG nfd-not-normalised fam_hidden 'a heading in NFD' $T 'unicodedata.normalize("NFC", seen)' 'seen'
BRKG missing-body-green fam_gh '[G] a view without a body key' $T ' or "body" not in data' ''
BRKG fence-delimiter-counted fam_sections '[S] a tilde fence' $T '                fence = None
            else:' '                fence = None
                count(ln)
            else:'
BRKG case-sensitive fam_headings '## tóm tắt' $T '    return t[k:].casefold()' '    return t[k:]'
BRKG exact-heading-only fam_headings '## Tóm tắt (vòng 2)' $T '(t == tok or (lenient and t.startswith(tok) and not t[len(tok)].isalnum()))' '(t == tok)'
BRKG hash-without-space-is-heading fam_headings '«#Tóm tắt» without a space' $T '#{1,6}(?:[ \t]+(.*))?$")' '#{1,6}[ \t]*(.*)$")'
BRKG spaces-not-collapsed fam_hidden 'look-alike heading #1 ' $T 'unicodedata.normalize("NFC", seen).split())' 'unicodedata.normalize("NFC", seen).split(" "))'
BRKG invisible-kept fam_hidden 'look-alike heading #11 ' $T '_FORMAT = "Cf"' '_FORMAT = "Zz"'
BRKG html-heading-ignored fam_hidden 'look-alike heading #9 ' $T '    m = _ATX.match(line) or _HTML_H.match(line)' '    m = _ATX.match(line)'
BRKG tags-kept fam_hidden 'look-alike heading #12 ' $T 'for ch in _TAG.sub("", text)' 'for ch in text'
BRKG blank-lines-counted fam_sections '[S] ten lines with blank lines' $T '        if not t or cur not in counts:' '        if cur not in counts:'
BRKG subheading-ends-section fam_sections "[S] a sub-heading of the author's own" $T '            if kind:
                cur, note_open = kind, kind == "evidence_heading"' '            if True:
                cur, note_open = kind, kind == "evidence_heading"'
BRKG heading-reset-on-repeat fam_headings 'a summary heading twice' $T '                cur, note_open = kind, kind == "evidence_heading"
                i += 1 if h[1] else 0' '                cur, note_open = kind, kind == "evidence_heading"
                counts[kind] = counts.get(kind, 0) * 0
                i += 1 if h[1] else 0'
BRKG comment-heading-recognised fam_hidden '[X] a criteria heading hidden in an HTML comment' $T '        if comment:
            count(ln)' '        if False:
            count(ln)'
BRKG comment-block-never-closes fam_hidden '[X] control: a heading after a multi-line comment block' $T '            comment = "-->" not in ln
            continue' '            comment = True
            continue'
BRKG comment-line-never-closes fam_hidden '[X] control: a heading after a closed comment' $T '            comment = "-->" not in ln[m.end() - 2:]' '            comment = True'
BRKG comment-short-form-open fam_hidden '[X] <!--> is a comment that ends where it starts' $T '"-->" not in ln[m.end() - 2:]' '"-->" not in ln[m.end():]'
BRKG comment-mid-line fam_hidden '[X] a <!-- in the middle of a line is plain text' $T '_COMMENT_START = re.compile(r"^ {0,3}<!--")' '_COMMENT_START = re.compile(r"^.*<!--")'
BRKG comment-indented fam_hidden '[X] a 4-space indented <!-- is no comment block' $T '_COMMENT_START = re.compile(r"^ {0,3}<!--")' '_COMMENT_START = re.compile(r"^ *<!--")'
BRKG list-fence-unseen fam_hidden '[X] a fence opened inside a list item' $T '_FENCE_OPEN = re.compile(r"^(?: {0,3}|[ \t]*(?:(?:[-*+]|\d{1,9}[.)])[ \t]+)+)(' '_FENCE_OPEN = re.compile(r"^ {0,3}('
BRKG fence-overread fam_hidden '[X] an indented fence line after a paragraph' $T '_FENCE_OPEN = re.compile(r"^(?: {0,3}|[ \t]*(?:(?:[-*+]|\d{1,9}[.)])[ \t]+)+)(' '_FENCE_OPEN = re.compile(r"^[ \t]*('
BRKG not-run-note-counted fam_hidden "[X] the not-run note above 30 evidence lines" $T '            if t == note:
                return' '            if False:
                return'
BRKG not-run-note-anywhere fam_hidden '[X] the not-run note repeated 35 times' $T '        if note_open:
            note_open = False' '        if True:
            note_open = False'
BRKG tokens-hardcoded fam_headings 'language en: «Summary»' $T 't, tok = _clean(text, lenient), _clean(tokens[key], lenient)' 't, tok = _clean(text, lenient), _clean({"summary_heading": "Tóm tắt", "criteria_heading": "Tiêu chí chấp nhận", "evidence_heading": "Bằng chứng chạy", "flow_heading": "Luồng"}[key], lenient)'
BRKG leading-symbols-kept fam_hidden 'look-alike heading #5 ' $T '    while lenient and k < len(t) and not t[k].isalpha():
        k += 1' '    while False:
        k += 1'
BRKG closing-hashes-kept fam_hidden '[X] a flow heading with an ATX closing sequence' $T '_unclose(m.group(1) or "")' '(m.group(1) or "")'
BRKG measured-heading-exact-only fam_hidden '[X] honest evidence heading #1 ' $T '        lenient = key in MEASURED' '        lenient = False'
BRKG invisible-list-only fam_hidden '[X] invisible or filler character #1 ' $T '_FORMAT = "Cf"' '_FORMAT = "Zz"'
BRKG fillers-kept fam_hidden '[X] invisible or filler character #8 ' $T '_FILLERS = "\u034f\u115f\u1160\u3164\uffa0"' '_FILLERS = ""'
BRKG boundary-prefix fam_hidden '[X] a summary sub-heading that starts with the flow word' $T '(lenient and t.startswith(tok)' '(t.startswith(tok)'
BRKG boundary-lenient fam_hidden '[X] a heading that only looks like the flow heading' $T '        lenient = key in MEASURED' '        lenient = True'
BRKG start-strict fam_hidden '[X] …but one that looks like the evidence heading starts it' $T '        lenient = key in MEASURED' '        lenient = False'
BRKG heading-regex-quadratic fam_hidden '[X] a 60000-character line' $T '_ATX = re.compile(r"^ {0,3}#{1,6}(?:[ \t]+(.*))?$")' '_ATX = re.compile(r"^ {0,3}#{1,6}(?:[ \t]+(.*?)[ \t]*)?$")'
BRKG limit-zero-is-limit fam_config '[K] max_chars 0' $T 'if lim["max_chars"] and n > lim["max_chars"]:' 'if n > lim["max_chars"]:'
BRKG summary-zero-is-limit fam_config '[K] summary_max_lines 0' $T 'if lim[limit_key] and counts[key] > lim[limit_key]:' 'if counts[key] > lim[limit_key]:'
BRKS config-defaults-lost fam_config '[K] default max_chars' sdlc_config.py '"body": {"max_chars": 3000,' '"body": {"max_chars": 30000,'
BRKS zero-refused fam_config '[K] max_chars 0' sdlc_config.py '"max_chars": ("int", 0),' '"max_chars": ("int", 1),'
BRKS negative-accepted fam_config '[K] a negative limit is rc 65' sdlc_config.py '"max_chars": ("int", 0),' '"max_chars": ("int", -5),'
BRKG gh-failure-green fam_gh '[G] gh failing' $T '        raise gc.Infra("gh pr view failed: %s" % p.stderr.decode("utf-8", "replace").strip()[:160])' '        return "{}"'
BRKG repo-dropped fam_gh '[G] --repo not passed' $T '(["-R", repo] if repo else [])' '[]'
BRKG both-modes-allowed fam_gh '[G] both --pr and --body-file' $T '(pr is None) == (path is None)' '(pr is None) and (path is None)'
BRKG file-error-green fam_gh '[G] a body file that cannot be read' $T '            raise gc.Infra("cannot read %s: %s" % (path, e.__class__.__name__))' '            body, what = "", path'
BRKG config-from-head fam_base '[B] a PR that removes its own cap' $T '    cfg = gc.load_config(cwd, ref)' '    cfg = gc.load_config(cwd, None)'
BRKG bad-ref-green fam_base '[B] a ref that does not read' gate_common.py '        raise Infra("ref `%s` does not read" % ref)
    if git(["cat-file"' '        return None
    if git(["cat-file"'
BRKG ref-config-error-swallowed fam_base '[B] an invalid config AT THE BASE' gate_common.py '    if probs:
        raise ConfigError(sdlc_config.render_problems(probs) + where)' '    if False:
        raise ConfigError(sdlc_config.render_problems(probs) + where)'

PLC="$TMP/break-none"; mk_plugin_copy "$PLC"
QN=0; okdef=$(declare -f ok); baddef=$(declare -f bad); sp=$PASS; sf=$FAIL
ok() { :; }; bad() { QN=$((QN+1)); }
for f in $FAMILIES; do "$f" "$PLC" >/dev/null 2>&1; done
eval "$okdef"; eval "$baddef"; PASS=$sp; FAIL=$sf
eq "$QN" 0 "control: an unbroken copy passes every family"

echo; summary
