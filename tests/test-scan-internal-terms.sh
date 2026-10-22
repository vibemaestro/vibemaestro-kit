#!/bin/bash
# =============================================================================
# Internal-term scanner: scripts/scan-internal-terms.sh
# =============================================================================
# Run: bash tests/test-scan-internal-terms.sh
#
# The suite builds throw-away git repositories and a SYNTHETIC term file (made-up words, never a real list) and checks,
# in seventeen checks, that the scanner finds a planted term in a file, in a deleted file (history only), in a commit
# message, in an author e-mail and in a branch name; ignores `glim` inside `glimmer`; honours an `allow:` line for one
# exact string in one file; finds a planted application name in plugins/vibemaestro-other but not inside
# plugins/vibemaestro-apps; exits 2 when the instrument is unusable; with --exclude counts a hit under the excluded
# directory without failing and still fails for a hit outside it (path tricks included); with --ci refuses a missing or
# empty term file; is not fooled by hostile file names (`-`, a newline, a leading dash) or by a NUL byte in --ci mode; and never prints a
# term, not in the output, not in an argument list, not for a term inside a path or when it fails. The self-hit of the
# scanner's own header is reproduced with a made-up whole-word term. Every positive assert has its control next
# to it: the same command on the same repository before the plant (exit 0) or on a clean variant.
# No secret, no network, no repository other than the ones it creates in a scratch directory.
# Last line on success: "ok: 17/17 scanner checks".
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SCAN="$HERE/../scripts/scan-internal-terms.sh"
[ -f "$SCAN" ] || { echo "FAIL: $SCAN does not exist"; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-scan.XXXXXX"); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/home" "$TMP/tmp"
export HOME="$TMP/home" TMPDIR="$TMP/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=tester GIT_AUTHOR_EMAIL=tester@example.invalid
export GIT_COMMITTER_NAME=tester GIT_COMMITTER_EMAIL=tester@example.invalid
unset KIT_TERMS_FILE
# shellcheck source=fixtures/netguard.sh
. "$HERE/fixtures/netguard.sh"
net_guard_install "$TMP"

# synthetic terms: 1 = plain term, 2 = whole-word term, plus one allow line; apps file: one application name
TERMS="$TMP/terms.txt"
printf '%s\n' 'zorblax' 'w:glim' 'allow: docs/INSTALL.md acme/zorblax-kit' > "$TERMS"
APPS="$TMP/apps.txt"
printf '%s\n' 'widgetco' > "$APPS"

PASS=0; TOTAL=0; CUR=""; BAD=0
OUT=""; RC=0

scan() {  # scan <dir> <args...>: runs the scanner in <dir>, sets OUT (stdout) and RC
  local d=$1; shift
  OUT=$(cd "$d" && bash "$SCAN" "$@" 2>"$TMP/stderr"); RC=$?
}
note() { echo "  FAIL [$CUR] $*"; BAD=1; }
want_rc() {  # want_rc <rc> <what>
  [ "$RC" = "$1" ] && return 0
  note "$2: exit $RC, want $1"
  while IFS= read -r l; do echo "      | $l"; done <<< "$OUT"
  while IFS= read -r l; do echo "      ! $l"; done < "$TMP/stderr"
}
has() { case $OUT in *"$1"*) ;; *) note "output lacks: $1"; while IFS= read -r l; do echo "      | $l"; done <<< "$OUT" ;; esac; }
lacks() { case $OUT in *"$1"*) note "output has, should not: $1" ;; esac; }
last_is() { [ "${OUT##*$'\n'}" = "$1" ] || note "last line is '${OUT##*$'\n'}', want '$1'"; }
clean_run() { want_rc 0 "$1"; last_is "control: found 1/1; hits: 0"; }

mk() {  # mk <name>: a repository with one clean commit; prints its path
  local r=$TMP/$1
  mkdir -p "$r"; git init -q "$r" 2>/dev/null
  printf 'clean\n' > "$r/README.md"
  git -C "$r" add -- README.md
  git -C "$r" commit -q -m "initial"
  printf '%s' "$r"
}
put() {  # put <repo> <path> <content> <message>: write, add and commit one file
  mkdir -p "$(dirname "$1/$2")"; printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add -- "$2"; git -C "$1" commit -q -m "$4"
}
h12() { local h; h=$(git -C "$1" rev-parse "${2:-HEAD}"); printf '%s' "${h:0:12}"; }

check() {  # check <n> <title> <function>
  CUR="$1 $2"; BAD=0; TOTAL=$((TOTAL+1))
  "$3"
  if [ "$BAD" = 0 ]; then PASS=$((PASS+1)); echo "ok   $CUR"; else echo "FAIL $CUR"; fi
}

# 1. a planted term in a tracked file (and in a file name) is found; an untracked file is not scanned
c1() {
  local r; r=$(mk r1)
  scan "$r" --terms "$TERMS" --tree; clean_run "clean tree"
  printf 'notes ZORBLAX here\n' > "$r/notes.md"
  scan "$r" --terms "$TERMS" --tree; clean_run "untracked file is not scanned (control)"
  git -C "$r" add -- notes.md
  scan "$r" --terms "$TERMS" --tree; want_rc 1 "planted term in a tracked file"
  has "tree notes.md term=1:1"; last_is "control: found 1/1; hits: 1"; lacks "orblax"; lacks "ORBLAX"
  put "$r" "zorblax-notes.txt" "innocent" "add a file whose name carries the term"
  scan "$r" --terms "$TERMS" --tree; want_rc 1 "term in a file name"
  has "name #"; lacks "zorblax-notes"
  r=$(mk r1b)
  scan "$r" --terms "$TERMS" --tree; has "scanned files: 1; skipped binary files: 0"
  printf 'zorblax\0bin\n' > "$r/blob.dat"; git -C "$r" add -- blob.dat
  scan "$r" --terms "$TERMS" --tree; clean_run "a binary file is skipped, not scanned"
  has "skipped binary files: 1"
  ln -s zorblax-target "$r/link"; git -C "$r" add -- link
  scan "$r" --terms "$TERMS" --tree; want_rc 1 "a tracked symlink: the target text is content"
  has "tree link term=1:1"
}
# 2. a term only in a deleted file: invisible to the tree scan, found in the history
c2() {
  local r; r=$(mk r2)
  put "$r" "gone.txt" "line with zorblax" "add a file"
  git -C "$r" rm -q -- gone.txt; git -C "$r" commit -q -m "remove the file"
  scan "$r" --terms "$TERMS" --tree; clean_run "deleted file is not in the tree"
  scan "$r" --terms "$TERMS" --history; want_rc 1 "deleted file in the history"
  has " gone.txt term=1:1"; has "history diff "; last_is "control: found 1/1; hits: 2"
  scan "$r" --terms "$TERMS" --tree --history; want_rc 1 "both modes in one run"
  last_is "control: found 1/1; hits: 2"
  scan "$TMP" --terms "$TERMS" --history "$r"; want_rc 1 "--history <directory> from another place"
  scan "$r" --terms "$TERMS" --history HEAD~2; clean_run "--history <rev> before the term was added (control)"
  scan "$r" --terms "$TERMS" --history HEAD~1; want_rc 1 "--history <rev> that includes the commit"
  git clone -q --bare "$r" "$TMP/r2.git" 2>/dev/null
  scan "$TMP" --terms "$TERMS" --history "$TMP/r2.git"; want_rc 1 "a bare repository"
  # a NUL byte in a later diff must not hide earlier hits (grep would stop printing lines on a "binary" stream)
  r=$(mk r2b)
  put "$r" "old.txt" "zorblax" "add the term"
  scan "$r" --terms "$TERMS" --history; want_rc 1 "term before the NUL commit (control)"
  { head -c 9000 /dev/zero | tr '\0' x; echo; printf 'bin\0tail\n'; } > "$r/late.dat"
  git -C "$r" add -- late.dat; git -C "$r" commit -q -m "late NUL"
  scan "$r" --terms "$TERMS" --history; want_rc 1 "a NUL byte in the diff stream"
  # an attribute that marks every file binary must not hide the diffs
  r=$(mk r2c)
  put "$r" ".gitattributes" "* -diff" "mark everything binary"
  put "$r" "s.txt" "zorblax secret" "add a file"
  git -C "$r" rm -q -- s.txt; git -C "$r" commit -q -m "remove it"
  scan "$r" --terms "$TERMS" --history; want_rc 1 "-diff attribute"
}
# 3. a term in a commit message, and in an annotated tag
c3() {
  local r h; r=$(mk r3)
  scan "$r" --terms "$TERMS" --history; clean_run "clean history"
  git -C "$r" commit -q --allow-empty -m "mention zorblax in the message"
  h=$(h12 "$r")
  scan "$r" --terms "$TERMS" --history; want_rc 1 "term in a commit message"
  has "history commit $h message term=1:1"; last_is "control: found 1/1; hits: 1"
  scan "$r" --terms "$TERMS" --tree; clean_run "a message is not in the tree (control)"
  git -C "$r" replace "$h" HEAD~1
  scan "$r" --terms "$TERMS" --history; want_rc 1 "a replace ref does not hide the real commit"
  has "history commit $h message term=1:1"
  r=$(mk r3t)
  git -C "$r" tag -a v1 -m "release zorblax"
  scan "$r" --terms "$TERMS" --history; want_rc 1 "term in an annotated tag"
  has "history tag-annotation "; lacks "zorblax"
}
# 4. a term in an author e-mail (and in a committer name)
c4() {
  local r h; r=$(mk r4)
  scan "$r" --terms "$TERMS" --history; clean_run "clean identities"
  GIT_AUTHOR_EMAIL=zorblax@example.invalid git -C "$r" commit -q --allow-empty -m "neutral message"
  h=$(h12 "$r")
  scan "$r" --terms "$TERMS" --history; want_rc 1 "term in an author e-mail"
  has "history commit $h author term=1:1"; last_is "control: found 1/1; hits: 1"
  GIT_COMMITTER_NAME=zorblax git -C "$r" commit -q --allow-empty -m "neutral again"
  h=$(h12 "$r")
  scan "$r" --terms "$TERMS" --history; want_rc 1 "term in a committer name"
  has "history commit $h committer term=1:1"
}
# 5. a term in a branch name and in a tag name
c5() {
  local r; r=$(mk r5)
  scan "$r" --terms "$TERMS" --history; clean_run "clean refs"
  git -C "$r" branch zorblax-wip
  scan "$r" --terms "$TERMS" --history; want_rc 1 "term in a branch name"
  has "history branch #"; has "term=1:1"; lacks "zorblax"; last_is "control: found 1/1; hits: 1"
  git -C "$r" branch -q -D zorblax-wip
  scan "$r" --terms "$TERMS" --history; clean_run "branch deleted (control)"
  git -C "$r" tag zorblax-v2
  scan "$r" --terms "$TERMS" --history; want_rc 1 "term in a lightweight tag name"
  has "history tag #"
}
# 6. the word-boundary case: `glim` inside `glimmer` is ignored, `glim` alone is found
c6() {
  local r; r=$(mk r6)
  put "$r" "story.md" "my glimmer and the glimpse" "add prose"
  scan "$r" --terms "$TERMS" --tree --history; clean_run "glim inside glimmer"
  put "$r" "real.md" "the glim cluster, not a word part" "add the whole word"
  scan "$r" --terms "$TERMS" --tree --history; want_rc 1 "whole word glim"
  has "tree real.md term=1:2"; lacks "story.md"
  has "history diff "; last_is "control: found 1/1; hits: 2"
  r=$(mk r6b)
  git -C "$r" branch glimmer; put "$r" "glimmer.txt" "x" "add glimmer.txt"
  scan "$r" --terms "$TERMS" --tree --history; clean_run "glim inside a branch and a file name"
  git -C "$r" branch glim-main; put "$r" "glim-notes.txt" "x" "add glim-notes.txt"
  scan "$r" --terms "$TERMS" --tree --history; want_rc 1 "glim as a word in a branch and a file name"
  has "history branch #"; has "name #"
}
# 7. an allow line permits one exact string in one file, nowhere else
c7() {
  local r; r=$(mk r7)
  put "$r" "docs/INSTALL.md" "install: claude plugin install acme/zorblax-kit" "document the install string"
  scan "$r" --terms "$TERMS" --tree --history; clean_run "allowed string in the allowed file"
  put "$r" "docs/OTHER.md" "install: claude plugin install acme/zorblax-kit" "same string in another file"
  scan "$r" --terms "$TERMS" --tree --history; want_rc 1 "allow does not travel to another file"
  has "tree docs/OTHER.md term=1:1"; has "history diff "; lacks "INSTALL.md"
  git -C "$r" rm -q -- docs/OTHER.md; git -C "$r" commit -q -m "drop it"
  put "$r" "docs/INSTALL.md" "install: acme/zorblax-kit, and a bare zorblax" "bare term in the allowed file"
  scan "$r" --terms "$TERMS" --tree; want_rc 1 "a bare term in the allowed file"
  has "tree docs/INSTALL.md term=1:1"
}
# 8. a planted application name is found in plugins/vibemaestro-other
c8() {
  local r; r=$(mk r8)
  put "$r" "plugins/vibemaestro-other/skill.md" "deploy widgetco with helm" "mention an application"
  scan "$r" --terms "$APPS" --skip plugins/vibemaestro-apps --tree --history
  want_rc 1 "application name in another plugin"
  has "tree plugins/vibemaestro-other/skill.md term=1:1"; has "history diff "
  scan "$r" --terms "$APPS" --tree plugins/vibemaestro-other; want_rc 1 "scoped to that plugin by --tree path"
  put "$r" "plugins/vibemaestro-apps/clean.md" "nothing to see" "add a clean file in the apps plugin"
  scan "$r" --terms "$APPS" --tree plugins/vibemaestro-apps; clean_run "other directory (control)"
}
# 9. the same name inside plugins/vibemaestro-apps is not a hit, and the internal terms still are
c9() {
  local r; r=$(mk r9)
  put "$r" "plugins/vibemaestro-apps/template.md" "chart for widgetco" "add an application template"
  scan "$r" --terms "$APPS" --skip plugins/vibemaestro-apps --tree --history
  clean_run "application name inside the apps plugin"
  scan "$r" --terms "$APPS" --tree --history; want_rc 1 "without --skip the same name is a hit (control)"
  has "tree plugins/vibemaestro-apps/template.md term=1:1"
  put "$r" "plugins/vibemaestro-apps/widgetco-chart.yaml" "x" "add a file named after an application"
  scan "$r" --terms "$APPS" --skip plugins/vibemaestro-apps --tree; clean_run "--skip also covers file names"
  scan "$r" --terms "$APPS" --tree; want_rc 1 "file name hit without --skip (control)"
  put "$r" "plugins/vibemaestro-apps/internal.md" "mentions zorblax" "add an internal term in the apps plugin"
  scan "$r" --terms "$TERMS" --terms "$APPS" --skip plugins/vibemaestro-apps --tree --history
  want_rc 1 "two term files, the internal one covers the apps directory"
  has "tree plugins/vibemaestro-apps/internal.md term=1:1"; lacks "template.md term=2"
  lacks "term=2:1"
}
# 10. misuse and a broken instrument exit 2, never 0
c10() {
  local r shim; r=$(mk r10)
  : > "$TMP/empty.txt"
  scan "$r" --terms "$TMP/empty.txt" --tree; want_rc 2 "empty term file"
  printf '\n  \n\n' > "$TMP/blank.txt"
  scan "$r" --terms "$TMP/blank.txt" --tree; want_rc 2 "term file of blank lines"
  printf 'allow: README.md something\n' > "$TMP/allowonly.txt"
  scan "$r" --terms "$TMP/allowonly.txt" --tree; want_rc 2 "term file with only an allow line"
  scan "$r" --terms "$TMP/missing.txt" --tree; want_rc 2 "missing term file"
  scan "$r" --tree; want_rc 2 "no term file at all"
  scan "$r" --terms "$TERMS"; want_rc 2 "neither --tree nor --history"
  scan "$TMP" --terms "$TERMS" --tree; want_rc 2 "not a git repository"
  scan "$r" --terms "$TERMS" --bogus; want_rc 2 "unknown option"
  scan "$r" --terms "$TERMS" --tree; clean_run "valid run (control)"
  OUT=$(cd "$r" && KIT_TERMS_FILE="$TERMS" bash "$SCAN" --tree 2>"$TMP/stderr"); RC=$?
  clean_run "terms from KIT_TERMS_FILE"
  # a shallow clone has no complete history: exit 2, and the full clone is the control
  put "$r" "once.txt" "zorblax" "add the term"
  git -C "$r" rm -q -- once.txt; git -C "$r" commit -q -m "remove the term"
  git clone -q --depth 1 "file://$r" "$TMP/r10-shallow" 2>/dev/null
  scan "$TMP/r10-shallow" --terms "$TERMS" --history; want_rc 2 "shallow clone"
  git clone -q "file://$r" "$TMP/r10-full" 2>/dev/null
  scan "$TMP/r10-full" --terms "$TERMS" --history; want_rc 1 "full clone of the same repository (control)"
  # a byte order mark must not disable the first term
  printf '\xef\xbb\xbfzorblax\n' > "$TMP/bom.txt"
  scan "$TMP/r10-full" --terms "$TMP/bom.txt" --history; want_rc 1 "term file with a byte order mark"
  # a tracked file that is not in the working tree cannot be judged clean
  put "$r" "keep.txt" "plain" "add a file"
  rm "$r/keep.txt"
  scan "$r" --terms "$TERMS" --tree; want_rc 2 "tracked file missing from the working tree"
  git -C "$r" checkout -q -- keep.txt
  scan "$r" --terms "$TERMS" --tree; clean_run "file restored (control)"
  mkdir "$r/untracked-dir"; : > "$r/untracked-dir/x"
  scan "$r" --terms "$TERMS" --tree untracked-dir; want_rc 2 "no tracked file under the path"
  shim=$TMP/shim; mkdir "$shim"; printf '#!/bin/bash\nexit 1\n' > "$shim/grep"; chmod +x "$shim/grep"
  OUT=$(cd "$r" && PATH="$shim:$PATH" bash "$SCAN" --terms "$TERMS" --tree 2>"$TMP/stderr"); RC=$?
  want_rc 2 "a grep that finds nothing: the planted control is missed"; last_is "control: found 0/1; hits: unknown"
}

# 11. --exclude: a hit under the directory is counted and does not fail; a hit outside it fails
c11() {
  local r; r=$(mk r11)
  scan "$r" --terms "$TERMS" --exclude kb/ --tree; clean_run "clean tree with --exclude"; has "excluded under kb/: 0 hits"
  put "$r" "kb/design.md" "the zorblax design" "a term in kb"
  scan "$r" --terms "$TERMS" --tree; want_rc 1 "the term in kb/, no --exclude (control)"
  scan "$r" --terms "$TERMS" --exclude kb/ --tree; clean_run "the term only in kb/"; has "excluded under kb/: 1 hits"
  lacks "kb/design.md"
  put "$r" "plugins/p/file.txt" "the zorblax plugin" "a term outside kb"
  scan "$r" --terms "$TERMS" --exclude kb/ --tree; want_rc 1 "a term outside kb/ as well"
  has "tree plugins/p/file.txt term=1:1"; has "excluded under kb/: 1 hits"; last_is "control: found 1/1; hits: 1"
  # the file name alone is a hit too, and is counted under the directory
  r=$(mk r11b); put "$r" "kb/zorblax.md" "plain" "a term in a name under kb"
  scan "$r" --terms "$TERMS" --exclude kb/ --tree; clean_run "a term in a file name under kb/"; has "excluded under kb/: 1 hits"
  # two directories, counted apart
  r=$(mk r11c); put "$r" "kb/a.md" "zorblax" "kb"; put "$r" "docs/b.md" "zorblax" "docs"
  scan "$r" --terms "$TERMS" --exclude kb/ --exclude docs/ --tree; clean_run "two excluded directories"
  has "excluded under kb/: 1 hits"; has "excluded under docs/: 1 hits"
}
# 12. --exclude cannot be talked into hiding a hit: the path tricks
c12() {
  local r; r=$(mk r12)
  # a file or a directory that only looks like kb/
  put "$r" "kb" "zorblax" "a file named kb"
  scan "$r" --terms "$TERMS" --exclude kb/ --tree; want_rc 1 "a FILE named kb is not under kb/"
  git -C "$r" rm -q -- kb; git -C "$r" commit -q -m "drop it"
  put "$r" "KB/x.md" "zorblax" "upper case"
  scan "$r" --terms "$TERMS" --exclude kb/ --tree; want_rc 1 "KB/ is not kb/ (case)"
  git -C "$r" rm -q -- KB/x.md; git -C "$r" commit -q -m "drop it"
  put "$r" "plugins/kb/x.md" "zorblax" "a nested kb"
  scan "$r" --terms "$TERMS" --exclude kb/ --tree; want_rc 1 "plugins/kb/ is not kb/ (only the top level)"
  git -C "$r" rm -q -- plugins/kb/x.md; git -C "$r" commit -q -m "drop it"
  put "$r" "kb-old/x.md" "zorblax" "a longer name"
  scan "$r" --terms "$TERMS" --exclude kb/ --tree; want_rc 1 "kb-old/ is not kb/ (the slash)"
  git -C "$r" rm -q -- kb-old/x.md; git -C "$r" commit -q -m "drop it"
  # a tracked link under kb/ that points out: its target text is scanned under its own name, the target is not followed
  mkdir -p "$r/kb" "$r/plugins/q"; printf 'zorblax\n' > "$r/plugins/q/f.txt"
  ln -s ../plugins/q "$r/kb/out"; git -C "$r" add -- kb/out plugins/q/f.txt; git -C "$r" commit -q -m "a link out of kb"
  scan "$r" --terms "$TERMS" --exclude kb/ --tree; want_rc 1 "the real file behind a link out of kb/"
  has "tree plugins/q/f.txt term=1:1"
  # the value itself: only a plain relative directory ending in a slash
  git -C "$r" rm -q -rf -- plugins kb; git -C "$r" commit -q -m "clean"
  scan "$r" --terms "$TERMS" --exclude kb/ --tree; clean_run "the clean tree again (control)"
  local bad
  for bad in kb ./kb/ ../kb/ kb/../plugins/ /kb/ kb//x/ ./ / "" kb/./x/; do
    scan "$r" --terms "$TERMS" --exclude "$bad" --tree; want_rc 2 "--exclude '$bad'"
  done
  scan "$r" --terms "$TERMS" --exclude kb/ --history; want_rc 2 "--exclude with --history"
  scan "$r" --terms "$TERMS" --exclude; want_rc 2 "--exclude without a value"
}
# 13. --ci: no term file, an empty one or the environment fallback never passes; the instrument still checks itself
c13() {
  local r shim; r=$(mk r13)
  scan "$r" --ci --terms "$TERMS" --exclude kb/ --tree; clean_run "--ci with a good term file (control)"
  : > "$TMP/ci-empty.txt"
  scan "$r" --ci --terms "$TMP/ci-empty.txt" --exclude kb/ --tree; want_rc 2 "--ci with an empty term file"
  [ -f "$TMP/stderr" ] && case $(cat "$TMP/stderr") in *KIT_TERMS*) ;; *) note "the --ci message does not name the KIT_TERMS secret" ;; esac
  printf '\n \n\t\n' > "$TMP/ci-blank.txt"
  scan "$r" --ci --terms "$TMP/ci-blank.txt" --exclude kb/ --tree; want_rc 2 "--ci with a blank term file"
  printf 'allow: README.md something\n' > "$TMP/ci-allow.txt"
  scan "$r" --ci --terms "$TMP/ci-allow.txt" --exclude kb/ --tree; want_rc 2 "--ci with only an allow line"
  scan "$r" --ci --terms "$TMP/ci-missing.txt" --exclude kb/ --tree; want_rc 2 "--ci with a missing term file"
  scan "$r" --ci --exclude kb/ --tree; want_rc 2 "--ci without --terms"
  OUT=$(cd "$r" && KIT_TERMS_FILE="$TERMS" bash "$SCAN" --ci --exclude kb/ --tree 2>"$TMP/stderr"); RC=$?
  want_rc 2 "--ci does not fall back to KIT_TERMS_FILE"
  OUT=$(cd "$r" && KIT_TERMS_FILE="$TERMS" bash "$SCAN" --exclude kb/ --tree 2>"$TMP/stderr"); RC=$?
  clean_run "without --ci the fallback still works (control)"
  # the hint belongs to the term-file stage only: a later failure does not carry it
  scan "$TMP" --ci --terms "$TERMS" --tree; want_rc 2 "--ci, not a git repository"
  case $(cat "$TMP/stderr") in *KIT_TERMS*) note "the term-file hint is repeated on a failure unrelated to the terms" ;; esac
  # a control miss: the planted canary is not found
  shim=$TMP/shim13; mkdir "$shim"; printf '#!/bin/bash\nexit 1\n' > "$shim/grep"; chmod +x "$shim/grep"
  OUT=$(cd "$r" && PATH="$shim:$PATH" bash "$SCAN" --ci --terms "$TERMS" --exclude kb/ --tree 2>"$TMP/stderr"); RC=$?
  want_rc 2 "--ci with a grep that finds nothing"; last_is "control: found 0/1; hits: unknown"
  # a control that cannot see what lies outside an excluded directory: here an exclusion that swallows every hit
  shim=$TMP/scan13b.sh
  sed -e 's|^  rec "\$2"$|  printf "0 %s\\n" "$2" >> "$XHITS"|' "$SCAN" > "$shim"
  cmp -s "$shim" "$SCAN" && note "the mutated scanner is the original: the sed did not apply"
  OUT=$(cd "$r" && bash "$shim" --ci --terms "$TERMS" --exclude kb/ --tree 2>"$TMP/stderr"); RC=$?
  want_rc 2 "an exclusion that swallows every hit is caught by the control"; last_is "control: found 0/1; hits: unknown"
}
# 14. no term is printed; the scanner's own header does not hit a short whole-word term
c14() {
  local r; r=$(mk r14)
  # a term inside a path, a term in a file, a failing run: no line carries the term
  put "$r" "plugins/zorblax-dir/a.txt" "zorblax" "term in a path and in a file"
  put "$r" "kb/zorblax-note.md" "zorblax" "term in a path under kb"
  scan "$r" --terms "$TERMS" --exclude kb/ --tree; want_rc 1 "a term in a path and in a file"
  lacks "zorblax"; lacks "ZORBLAX"
  [ -z "$(grep -i -e zorblax -- "$TMP/stderr")" ] || note "the term is on stderr"
  has "(path withheld"
  # the same through every error path that mentions a file
  rm "$r/plugins/zorblax-dir/a.txt"
  scan "$r" --terms "$TERMS" --exclude kb/ --tree; want_rc 2 "a tracked file with a term in its path is missing"
  lacks "zorblax"; [ -z "$(grep -i -e zorblax -- "$TMP/stderr")" ] || note "the term is on stderr (missing file)"
  git -C "$r" checkout -q -- plugins/zorblax-dir/a.txt
  if [ "$(id -u)" != 0 ]; then
    chmod 000 "$r/plugins/zorblax-dir/a.txt"
    scan "$r" --terms "$TERMS" --exclude kb/ --tree; want_rc 2 "an unreadable tracked file with a term in its path"
    lacks "zorblax"; [ -z "$(grep -i -e zorblax -- "$TMP/stderr")" ] || note "the term is on stderr (unreadable file)"
    chmod 644 "$r/plugins/zorblax-dir/a.txt"
  fi
  # the self-hit: a header that documents a whole-word term with a real short name as its example matches that term.
  # The name is assembled here so that this file does not hold it either.
  local nm=am; nm=${nm}i
  r=$(mk r14b)
  printf 'w:%s\n' "$nm" > "$TMP/short.txt"
  put "$r" "scripts/old-header.sh" "#   w:<term>   the same, but only as a whole word (\`$nm\` must not match \`family\`)" "the old header line"
  scan "$r" --terms "$TMP/short.txt" --exclude kb/ --tree; want_rc 1 "the old header line hits a whole-word term (control)"
  has "tree scripts/old-header.sh term=1:1"
  scan "$HERE/.." --terms "$TMP/short.txt" --exclude kb/ --tree scripts/scan-internal-terms.sh
  want_rc 0 "the scanner as it is holds no hit for that short whole-word name"; last_is "control: found 1/1; hits: 0"
}

# 15. hostile names and contents cannot switch the gate off
c15() {
  local r
  r=$(mk r15); put "$r" "plugins/leak.txt" "the zorblax name" "a hit outside kb"; put "$r" "plugins/leak2.txt" "a glim here" "a hit for the second term"
  scan "$r" --ci --terms "$TERMS" --exclude kb/ --tree; want_rc 1 "two hits, plain tree (control)"; has "tree plugins/leak.txt term=1:1"; has "tree plugins/leak2.txt term=1:2"
  has "terms: 2"
  # a tracked file named "-": grep reads it as stdin, and used to end the scan of every term after the first
  printf 'clean\n' > "$r/-"; git -C "$r" add -- ./-; git -C "$r" commit -q -m "a file named dash"
  scan "$r" --ci --terms "$TERMS" --exclude kb/ --tree; want_rc 1 "a file named - next to the hits"
  has "tree plugins/leak.txt term=1:1"; has "tree plugins/leak2.txt term=1:2"; lacks "standard input"
  printf 'the zorblax name\n' > "$r/-"; git -C "$r" commit -q -a -m "the term in it"
  scan "$r" --ci --terms "$TERMS" --exclude kb/ --tree; want_rc 1 "a term inside the file named -"; has "tree - term=1:1"
  # a name that starts with dashes, and a name with a newline: the name hit is filed under the right file
  r=$(mk r15b)
  printf 'x\n' > "$r/--zorblax"; git -C "$r" add -- ./--zorblax; git -C "$r" commit -q -m "dashes"
  scan "$r" --ci --terms "$TERMS" --exclude kb/ --tree; want_rc 1 "a term in a name that starts with --"
  r=$(mk r15c); put "$r" "kb/z.md" "plain" "a file under kb"
  printf 'c\n' > "$r/a"$'\n'"b"; printf 'c\n' > "$r/abc_zorblax"; git -C "$r" add -A; git -C "$r" commit -q -m "a newline in a name, and a term in the next name"
  scan "$r" --ci --terms "$TERMS" --exclude kb/ --tree; want_rc 1 "a term in a name after a name with a newline"
  has "excluded under kb/: 0 hits"; has "name #"
  r=$(mk r15d); put "$r" "kb/z.md" "plain" "a file under kb"
  printf 'c\n' > "$r/a"$'\n'"b"; git -C "$r" add -A; git -C "$r" commit -q -m "a newline in a name only"
  scan "$r" --ci --terms "$TERMS" --exclude kb/ --tree; clean_run "a newline in a name, no term (control)"
  # a NUL byte: skipped by default (counted), read as text in --ci
  r=$(mk r15e); printf 'x zorblax y\n\0\n' > "$r/plugins-bin.dat"; git -C "$r" add -A; git -C "$r" commit -q -m "a text file with a NUL byte"
  scan "$r" --terms "$TERMS" --tree; clean_run "without --ci a file with a NUL byte is skipped"; has "skipped binary files: 1"
  scan "$r" --ci --terms "$TERMS" --exclude kb/ --tree; want_rc 1 "with --ci the same file is read as text"; has "tree plugins-bin.dat term=1:1"; has "binary files read as text: 1"
  printf 'plain\n' > "$r/plugins-bin.dat"; git -C "$r" commit -q -a -m "clean it"
  scan "$r" --ci --terms "$TERMS" --exclude kb/ --tree; clean_run "the file cleaned (control)"
}
# 16. no term in an argument list, and the scratch copy of the terms goes where TMPDIR says
c16() {
  local r shim real log; r=$(mk r16); put "$r" "plugins/leak.txt" "the zorblax name and a glim" "a hit outside kb"
  put "$r" "plugins/zorblax-notes.txt" "zorblax" "a hit in a path that itself holds a term"
  real=$(command -v grep); shim=$TMP/shim16; log=$TMP/shim16.log; mkdir -p "$shim" "$TMP/scratch16"; : > "$log"
  printf '#!/bin/bash\nprintf "%%s %%s\\n" "$*" "TERM=$TERM" >> "%s"\nls "${TMPDIR:-/tmp}" >> "%s.ls"\nexec "%s" "$@"\n' "$log" "$log" "$real" > "$shim/grep"; chmod +x "$shim/grep"
  OUT=$(cd "$r" && TERM=xterm TMPDIR="$TMP/scratch16" PATH="$shim:$PATH" bash "$SCAN" --ci --terms "$TERMS" --exclude kb/ --tree 2>"$TMP/stderr"); RC=$?
  want_rc 1 "the hit is found through the spying grep"; has "tree plugins/leak.txt term=1:1"
  [ -s "$log" ] || note "the spy was never called: the check below proves nothing"
  # the tracked paths are in the argument list of the content greps (they are data, not terms); a TERM variable or an -e argument or the
  # path lookup of a withheld hit (-x) must not carry a term
  local ll; ll=$(tr 'A-Z' 'a-z' < "$log")
  case $ll in *"term=zorblax"*|*"term=glim"*) note "a term is in the TERM variable of a child process" ;; esac
  case $ll in *"-e zorblax"*|*"-e glim"*) note "a term is in an argument list of grep (-e)" ;; esac
  case $(grep -e ' -x ' -- "$log" | tr 'A-Z' 'a-z') in *zorblax*|*glim*) note "a path that holds a term is in an argument list (the withheld-path lookup)" ;; esac
  grep -q -e ' -x ' -- "$log" || note "the withheld-path lookup was not exercised"
  case $(cat "$log") in *"TERM=xterm"*) ;; *) note "the spy did not see the exported TERM: the environment check proves nothing" ;; esac
  grep -q -e 'scan-terms\.' -- "$log.ls" 2>/dev/null || note "the scanner's scratch directory is not under TMPDIR"
  [ -z "$(ls -A "$TMP/scratch16")" ] || note "the scratch directory was left behind"
}

# 17. the pattern files are not shared: a hit path that holds another term, between the chunks of a long file list
c17() {
  local r i; r=$(mk r17)
  mkdir -p "$r/a" "$r/m" "$r/z"
  printf 'zorblax\n' > "$r/a/glim.txt"                      # sorts first: its path holds the second term, and is looked at between the chunks
  for i in $(seq 1 450); do printf 'plain\n' > "$r/m/f$i.txt"; done
  printf 'zorblax\n' > "$r/z/last.txt"                       # in the last chunk
  git -C "$r" add -A; git -C "$r" commit -q -m "450 files"
  scan "$r" --ci --terms "$TERMS" --exclude kb/ --tree; want_rc 1 "hits in the first and in the last chunk"
  has "tree (path withheld; file #2) term=1:1"; has "name #2 term=1:2"; has "tree z/last.txt term=1:1"; last_is "control: found 1/1; hits: 3"
}

check 1 "planted term in a file" c1
check 2 "planted term in a deleted file (history only)" c2
check 3 "planted term in a commit message" c3
check 4 "planted term in an author e-mail" c4
check 5 "planted term in a branch name" c5
check 6 "word boundary: glim inside glimmer" c6
check 7 "allow line for one string in one file" c7
check 8 "application name found in another plugin" c8
check 9 "application name ignored inside the apps plugin" c9
check 10 "exit 2 on unusable terms or a broken instrument" c10
check 11 "--exclude: counted under the directory, fails outside it" c11
check 12 "--exclude: path tricks do not hide a hit" c12
check 13 "--ci: no term file, an empty one or a missed control never passes" c13
check 14 "no term is printed; the scanner's own text does not hit" c14
check 15 "hostile names and a NUL byte cannot switch the gate off" c15
check 16 "no term in an argument list or the environment; the scratch copy follows TMPDIR" c16
check 17 "the pattern files are not shared between the chunks" c17

if NL=$(net_guard_empty); then :; else echo "FAIL: network guard, a network tool was called: $NL"; exit 1; fi
if [ "$PASS" = "$TOTAL" ]; then
  echo "ok: $PASS/$TOTAL scanner checks"
else
  echo "FAIL: $PASS/$TOTAL scanner checks"
  exit 1
fi
