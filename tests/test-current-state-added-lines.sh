#!/bin/bash
# =============================================================================
# The current-state failure names the lines this change added and the bytes over the cap
# =============================================================================
# Run: bash tests/test-current-state-added-lines.sh
#
# When `kb.py check current-state` (or the diff gate)
# fails, `current_state.render` lists the lines the working tree has and the merge-base with `origin/main` does not, with
# their line numbers, and says by how many bytes (or lines) the file is over its cap. A session then knows which of ITS lines
# to shorten. Without git, a repository, `origin/main`, a merge-base (a shallow clone) or with a git that hangs, the message
# comes without the block: the failure, its rc and the rest of the text never change.
#   [M] a planted over-cap diff: the added lines, their numbers, the cap, the cut at 20 lines and 100 characters
#   [G] the diff gate (`--diff`) prints the same block
#   [R] the root is the one `kb.py` found: `render` lists the added lines for a root it is given, wherever cwd is; kb.py run from a
#       subdirectory of a repository whose kb/ is not at the top
#   [N] nothing to compare with: no remote, no git repository, a shallow clone with no merge-base, a git that fails, a git that hangs
# Then each planted break of the message must turn its family red and an unbroken copy must stay green.
# Real git on throw-away repositories, no network.
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
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
H0=$(tree_hash "$SRC_ROOT")   # the suite imports the real plugin: it must leave no bytecode behind in the tree

PLX=""; PT=""; PW=""; F=""
LED=kb/current-state.md
CFG='{"schema": 1, "current_state": {"watch": ["src/"], "limits": {"bytes": 1000}}}'
PAD=$(printf 'x%.0s' $(seq 1 60)); CUT=$(printf 'x%.0s' $(seq 1 84))   # "added-marker-01 " is 16 characters: 84 more make 100

# ── fixtures ─────────────────────────────────────────────────────────────
# gp <git args> — git in PT with the working directory inside the scratch root (git_ reads `feat/x` as a path relative to it)
gp() { ( cd "$PT" && git_ "$@" ); }
# mk_case <added lines> [width of an added line's padding] — PT on feat/x: origin/main holds the config and a ledger of two lines, the
# branch appends <added lines> lines `added-marker-NN <padding>` to it (plain words: no history sign, so the size is the only fault).
mk_case() {
  mk_pr_repo
  mkdir -p "$PT/.vibemaestro" "$PT/kb" "$PT/src"
  printf '%s' "$CFG" > "$PT/.vibemaestro/sdlc.json"; printf '# State\n\nbase one\nbase two\n' > "$PT/$LED"
  git_ -C "$PT" add -A; git_ -C "$PT" commit -q -m "config and ledger"
  gp push -q origin feat/x:main; gp fetch -q origin; gp branch -f gbase origin/main
  python3 - "$PT/$LED" "$1" "${2:-60}" <<'PY'
import sys
p, n, w = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
with open(p, encoding="utf-8") as f:
    kept = f.read().replace("base two\n", "")          # a deleted line must not be listed as an added one
with open(p, "w", encoding="utf-8") as f:
    f.write(kept)
with open(p, "a", encoding="utf-8") as f:
    for i in range(1, n + 1):
        f.write("added-marker-%02d %s\n" % (i, "x" * w))
PY
  git_ -C "$PT" add "$LED"; git_ -C "$PT" commit -q -m "ledger grows" >/dev/null 2>&1 || true
  : > "$F/body-empty.txt"
}
kbd() { ( cd "$PT" && cenv python3 "$PLX/scripts/kb.py" "$@" ); }
# bytes_over — how many bytes the ledger in PT is over the 1000-byte cap
bytes_over() { echo $(( $(wc -c < "$PT/$LED") - 1000 )); }

fam_added() { PLX=$1
  local over
  mk_case 30; OUT=$(kbd check current-state 2>&1); RC=$?; over=$(bytes_over)
  eq "$RC" 65 "[M1] a ledger over its cap: rc 65, as before"
  has "$OUT" "vượt trần byte" "[M2] …the usual problem line is still there"
  has "$OUT" "Quá trần $over byte" "[M3] …and the bytes over the cap are named ($over)"
  has "$OUT" "PR này đã thêm 30 dòng" "[M4] …and the count of lines this change added"
  has "$OUT" "dòng 4: added-marker-01 " "[M5] the first added line, with its number in the file (the heading, a blank line and one base line come first; the other base line was deleted)"
  has "$OUT" "dòng 23: added-marker-20 " "[M6] the 20th added line, with its number"
  hasnt "$OUT" "added-marker-21" "[M7] the 21st is cut"
  has "$OUT" "… và 10 dòng nữa" "[M8] …and the rest is counted"
  hasnt "$OUT" "base one" "[M9] a line the base already had is not listed"
  hasnt "$OUT" "base two" "[M9b] …nor one this change deleted"
  mk_case 7 150; OUT=$(kbd check current-state 2>&1); RC=$?
  eq "$RC" 65 "[M10] seven lines of 150 characters: still over the cap"
  has "$OUT" "dòng 4: added-marker-01 ${CUT}…" "[M11] a long line is cut at 100 characters, with an ellipsis"
  hasnt "$OUT" "${PAD}${PAD}" "[M12] …and not printed whole"
  # a ledger over its cap by a line, not a byte: the caps are different units, each named
  mk_case 5; printf '%s' '{"schema": 1, "current_state": {"limits": {"lines": 6, "bytes": 100000}}}' > "$PT/.vibemaestro/sdlc.json"
  OUT=$(kbd check current-state 2>&1); RC=$?
  has "$OUT" "Quá trần 2 dòng (8 > 6)" "[M13] over the line cap: the lines over are named, in lines"
  # a line that starts with two plus signs is printed by git as `+++ ...`: it is an added line like any other, and the numbers after it hold
  mk_case 2; printf '%s' '{"schema": 1, "current_state": {"limits": {"bytes": 200}}}' > "$PT/.vibemaestro/sdlc.json"
  printf '%s\n' '++ plus plus line' "- dash line" $'\rCR\033[31mESC' >> "$PT/$LED"; git_ -C "$PT" add "$LED"; git_ -C "$PT" commit -q -m "odd lines"
  OUT=$(kbd check current-state 2>&1); RC=$?
  has "$OUT" "dòng 6: ++ plus plus line" "[M16] an added line that starts with ++ is listed"
  has "$OUT" "dòng 7: - dash line" "[M16b] …and the line after it keeps its number"
  has "$OUT" "dòng 8: ?CR?[31mESC" "[M17] control characters in an added line are shown as ? (no CR or ESC in the log)"
  # the ledger that passes says nothing of this
  mk_case 0; OUT=$(kbd check current-state 2>&1); RC=$?
  eq "$RC" 0 "[M14] a ledger within its cap: rc 0"
  hasnt "$OUT" "PR này đã thêm" "[M15] …and no added-lines block"
}
fam_gate() { PLX=$1
  mk_case 30; printf 'x\n' > "$PT/src/a.sh"; git_ -C "$PT" add src/a.sh; git_ -C "$PT" commit -q -m "watched"
  OUT=$(kbd check current-state --diff gbase...HEAD --body-file "$F/body-empty.txt" 2>&1); RC=$?
  eq "$RC" 65 "[G1] the diff gate over the cap: rc 65"
  has "$OUT" "dòng 4: added-marker-01 " "[G2] …it prints the added lines too"
  has "$OUT" "Quá trần $(bytes_over) byte" "[G3] …and the bytes over the cap"
}
# a repository with a ledger over its cap and nothing to compare it with: the message is the old one
over_ledger() {  # over_ledger <dir> — config and a 30-line ledger in <dir>
  mkdir -p "$1/.vibemaestro" "$1/kb"; printf '%s' "$CFG" > "$1/.vibemaestro/sdlc.json"
  { printf '# State\n\n'; for i in $(seq 1 30); do printf 'added-marker-%02d %s\n' "$i" "$PAD"; done; } > "$1/$LED"
}
# nocmp <tag> <what> <dir> [kb] — `render` called from <dir> (no kb.py: it needs a working git to find its root) returns its usual message
# with no block; with `kb` the whole `kb.py check current-state` is run there too. NOCMP_PATH puts a stand-in git first.
nocmp() {
  local out rc
  out=$(cd "$3" && timeout 25 env -i PATH="${NOCMP_PATH:-$PATH}" HOME="$HOME" GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" GIT_CONFIG_NOSYSTEM=1 PYTHONUTF8=1 \
        GIT_CEILING_DIRECTORIES="$(dirname -- "$FIXTURE_SCRATCH")" python3 -B -c '
import sys
sys.path.insert(0, sys.argv[1] + "/scripts")
import current_state as c
print(c.render("kb/current-state.md", [(0, "vượt trần byte: 2337 > 1000 — chi tiết đang nằm sai chỗ")]))' "$PLX" 2>&1); rc=$?
  eq "$rc" 0 "[$1] $2: render returns (rc 124 would be the timeout)"
  has "$out" "vượt trần byte" "[$1] $2: the usual problem line"
  has "$out" "Quá trần 1337 byte" "[$1] $2: the bytes over, which need no git"
  has "$out" "Sửa: viết đè" "[$1] $2: the closing advice"
  hasnt "$out" "PR này đã thêm" "[$1] $2: no added-lines block"
  hasnt "$out" "Traceback" "[$1] $2: no traceback"
  if [ "${4:-}" = kb ]; then
    out=$(cd "$3" && timeout 25 env -i PATH="$PATH" HOME="$HOME" GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" GIT_CONFIG_NOSYSTEM=1 PYTHONUTF8=1 PYTHONDONTWRITEBYTECODE=1 \
          python3 "$PLX/scripts/kb.py" check current-state 2>&1); rc=$?
    eq "$rc" 65 "[$1] $2: kb.py check current-state still fails with rc 65"
    has "$out" "Quá trần" "[$1] $2: …naming the bytes over"
    hasnt "$out" "PR này đã thêm" "[$1] $2: …with no block"
  fi
}
fam_nocmp() { PLX=$1
  local d s
  d=$(fresh); git_ init -q -b main "$d"; over_ledger "$d"; git_ -C "$d" add -A; git_ -C "$d" commit -q -m one
  nocmp N1 "a repository with no remote and no origin/main" "$d" kb
  d=$(fresh); over_ledger "$d"
  nocmp N2 "a directory that is not a repository" "$d"
  # a shallow clone: origin/main is fetched at depth 1 on its own, so HEAD and origin/main share no history
  mk_case 30; s=$(fresh)
  gp push -q origin feat/x
  # main moves on from the base the branch was cut from (its ledger is the base's: the tip differs from the branch)
  gp push -q origin "$(gp commit-tree 'origin/main^{tree}' -p origin/main -m 'main moves')":refs/heads/main
  ( cd "$s" && git_ clone -q --depth 1 --branch feat/x "file://$(git_ -C "$PT" remote get-url origin)" c 2>/dev/null )
  ( cd "$s/c" && git_ fetch -q --depth 1 origin main:refs/remotes/origin/main 2>/dev/null )
  eq "$(git_ -C "$s/c" merge-base HEAD origin/main 2>/dev/null | wc -c | tr -d ' ')" 0 "[N3a] control: the shallow clone has origin/main and no merge-base"
  nocmp N3 "a shallow clone with no merge-base" "$s/c" kb
  # a git that fails and one that hangs, in front of the real one
  s=$(fresh); mkdir "$s/bin"
  mkdir "$s/nogit"; ln -s "$(command -v python3)" "$s/nogit/python3"
  d=$(fresh); over_ledger "$d"
  NOCMP_PATH="$s/nogit" nocmp N6 "no git binary at all" "$d"
  printf '#!/bin/sh\nexit 128\n' > "$s/bin/git"; chmod +x "$s/bin/git"
  d=$(fresh); over_ledger "$d"
  NOCMP_PATH="$s/bin:$PATH" nocmp N4 "a git that exits 128" "$d"
  printf '#!/bin/sh\nsleep 40\n' > "$s/bin/git"
  SECONDS=0; NOCMP_PATH="$s/bin:$PATH" nocmp N5 "a git that hangs (killed after 10 s)" "$d"
  [ "$SECONDS" -lt 25 ] && ok "[N5b] …and it came back in $SECONDS s" || bad "[N5b] the message waited $SECONDS s for a hung git"
}

# a path or root git cannot be given (a NUL, a lone surrogate) is no reason to raise: added_lines is for a message that is already a failure
fam_args() { PLX=$1
  local out
  out=$(cd "$TMP" && python3 -B -c '
import sys
sys.path.insert(0, sys.argv[1] + "/scripts")
import current_state as c
print(c.added_lines("kb/a\0b", sys.argv[2]), c.added_lines("kb/x.md", "\0"), c.added_lines("kb/\udcff.md", sys.argv[2]))' "$PLX" "$TMP" 2>&1)
  eq "$out" "None None None" "[A1] added_lines with a NUL or a lone surrogate returns None, never raises"
}

# render takes the root its caller found: cwd outside the repository must not hide the block, and kb/ below the git top still works
fam_root() { PLX=$1
  local out
  mk_case 30
  out=$(cd "$TMP" && python3 -B -c '
import sys
sys.path.insert(0, sys.argv[1] + "/scripts")
import current_state as c
print(c.render("kb/current-state.md", [(0, "vượt trần byte: 1 > 0")], sys.argv[2]))' "$PLX" "$PT" 2>&1)
  has "$out" "PR này đã thêm 30 dòng" "[R1] render with an explicit root, cwd outside the repository: the added-lines block is there"
  has "$out" "dòng 4: added-marker-01 " "[R2] …with the line numbers"
  out=$(cd "$TMP" && python3 -B -c '
import sys
sys.path.insert(0, sys.argv[1] + "/scripts")
import current_state as c
print(c.render("kb/current-state.md", [(0, "vượt trần byte: 1 > 0")]))' "$PLX" 2>&1)
  hasnt "$out" "PR này đã thêm" "[R3] instrument: the same call with no root, from the same cwd, has no block"
  # kb/ below the git top: the ledger is at app/kb/, the config says so, kb.py runs from app/
  mk_pr_repo
  mkdir -p "$PT/.vibemaestro" "$PT/app/kb"
  printf '%s' '{"schema": 1, "current_state": {"path": "app/kb/current-state.md", "limits": {"bytes": 1000}}}' > "$PT/.vibemaestro/sdlc.json"
  printf '# State\n\nbase one\n' > "$PT/app/kb/current-state.md"
  git_ -C "$PT" add -A; git_ -C "$PT" commit -q -m "config and ledger"
  gp push -q origin feat/x:main; gp fetch -q origin
  for i in $(seq 1 30); do printf 'added-marker-%02d %s\n' "$i" "$PAD" >> "$PT/app/kb/current-state.md"; done
  git_ -C "$PT" add -A; git_ -C "$PT" commit -q -m "ledger grows"
  out=$(cd "$PT/app" && cenv python3 "$PLX/scripts/kb.py" check current-state 2>&1); RC=$?
  eq "$RC" 65 "[R4] kb/ below the git top, kb.py run from that subdirectory: rc 65"
  has "$out" "app/kb/current-state.md" "[R5] …the ledger is named by its path from the repository root"
  has "$out" "PR này đã thêm 30 dòng vào app/kb/current-state.md" "[R6] …and the added-lines block is there"
  # the call site in kb.py: the CLI finds the same root without help, so call the command function from a cwd outside the repository
  out=$(cd "$TMP" && python3 -B -c '
import os, sys
sys.path.insert(0, sys.argv[1] + "/scripts")
import kb
cfg = kb.C.load(sys.argv[2])[0]
kb.cmd_check_current_state(sys.argv[2], os.path.join(sys.argv[2], "app", "kb", "current-state.md"), cfg)' "$PLX" "$PT" 2>&1 >/dev/null)
  has "$out" "PR này đã thêm 30 dòng vào app/kb/current-state.md" "[R7] kb.py's own call, cwd outside the repository: the block is there (kb.py passes its root)"
}

FAMILIES="fam_added fam_gate fam_root fam_nocmp fam_args"
for f in $FAMILIES; do echo "-- $f"; "$f" "$PLUGIN"; done

# ── each planted break must turn its family red ─────────────────────────────────────────────────
BRK() {  # BRK <label> <family> <needle> <old> <new>   (all in scripts/current_state.py)
  local d="$TMP/break-$1"; mk_plugin_copy "$d"
  mutate "$d/scripts/current_state.py" "$4" "$5" && expect_red "$1" "$2" "$d" "$3"
}
BRKK() {  # BRKK <label> <family> <needle> <old> <new>   (in scripts/kb.py)
  local d="$TMP/break-$1"; mk_plugin_copy "$d"
  mutate "$d/scripts/kb.py" "$4" "$5" && expect_red "$1" "$2" "$d" "$3"
}
echo "-- planted breaks"
BRKK kb-root-dropped fam_root '[R7]' '        sys.stderr.write(current_state.render(rel, probs, root, profile["language"]) + "\n")' '        sys.stderr.write(current_state.render(rel, probs, None, profile["language"]) + "\n")'
BRK root-ignored fam_root '[R1]' '    top = (root or _git_out(os.getcwd(), "rev-parse", "--show-toplevel") or "").strip()' '    top = (_git_out(os.getcwd(), "rev-parse", "--show-toplevel") or "").strip()'
BRK no-added-block fam_added '[M5]' '    add = added_lines(path, root)' '    add = None'
BRK no-added-block-gate fam_gate '[G2]' '    add = added_lines(path, root)' '    add = None'
BRK bytes-over-not-named fam_added '[M3]' 'lines.append(M("cs.over_by", got - cap,' 'lines.append(M("cs.over_by", cap,'
BRK lines-over-in-bytes fam_added '[M13]' 'bytes_, got, cap = why.unit == "bytes", why.got, why.cap' 'bytes_, got, cap = True, why.got, why.cap'
BRK line-number-stuck fam_added '[M6]' '            got.append((n, ln[1:]))
            n += 1' '            got.append((n, ln[1:]))'
BRK plusplus-line-dropped fam_added '[M16]' 'elif n and ln.startswith("+"):' 'elif n and ln.startswith("+") and not ln.startswith("+++"):'
BRK control-chars-raw fam_added '[M17]' 'text = _CONTROL.sub("?", text)' 'pass'
BRK valueerror-raises fam_args '[A1]' '    except (OSError, ValueError, subprocess.SubprocessError):' '    except (OSError, subprocess.SubprocessError):'
BRK no-cut-at-20 fam_added '[M7]' 'ADDED_MAX = 20' 'ADDED_MAX = 1000'
BRK no-cut-at-100 fam_added '[M11]' 'ADDED_CHARS = 100' 'ADDED_CHARS = 1000'
BRK base-lines-listed fam_added '[M9b]' 'elif n and ln.startswith("+"):' 'elif n:'
BRK raises-without-base fam_nocmp '[N1]' '    if not mb:
        return None' '    if not mb:
        raise RuntimeError("no merge-base")'
BRK raises-without-git fam_nocmp '[N6]' '    except (OSError, ValueError, subprocess.SubprocessError):' '    except (ValueError, subprocess.SubprocessError):'
BRK no-timeout fam_nocmp '[N5]' 'GIT_TIMEOUT = 10' 'GIT_TIMEOUT = 100'
BRK tip-instead-of-merge-base fam_nocmp '[N3]' '    mb = (_git_out(top, "merge-base", "HEAD", BASE_REF) or "").strip()' '    mb = (_git_out(top, "merge-base", "HEAD", BASE_REF) or _git_out(top, "rev-parse", BASE_REF) or "").strip()'

PLC="$TMP/break-none"; mk_plugin_copy "$PLC"
QN=0; okdef=$(declare -f ok); baddef=$(declare -f bad); sp=$PASS; sf=$FAIL
ok() { :; }; bad() { QN=$((QN+1)); }
for f in $FAMILIES; do "$f" "$PLC" >/dev/null 2>&1; done
eval "$okdef"; eval "$baddef"; PASS=$sp; FAIL=$sf
eq "$QN" 0 "control: an unbroken copy passes every family (no failed check)"

eq "$(tree_hash "$SRC_ROOT")" "$H0" "the repository tree is unchanged by the suite"

echo; summary
