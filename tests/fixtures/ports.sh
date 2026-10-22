# shellcheck shell=bash
# =============================================================================
# Helpers of the test-core-* suites (sourced AFTER lib.sh and flow.sh; defines functions only)
# =============================================================================
# The five suites test the two cores (intent_branch.py, open_pr.py) and their adapters as they are TODAY, with real git on
# throw-away repositories, a fake `gh` first in PATH and the network shims of netguard.sh. Three rules shape these helpers:
#   - Every core runs under `env -i` (cenv): an ambient variable of the machine running the tests (an author identity, a
#     token file, a repo-location variable) must not change an outcome. A test that needs a variable passes it explicitly.
#   - Every suite is a list of FAMILY functions `fam_xxx <plugin dir>` that take the plugin copy to test. The suite runs
#     them all on a copy of the real plugin, then runs one family on a copy with ONE planted break (expect_red) and
#     requires red on the check that family is about. A suite that cannot go red proves nothing.
#   - Assertions read exit codes, payload fields, files, refs and tokens. Prose of a message is never asserted.
# Fixture names are synthetic (acme, example); no path or name of another repository appears here.
# =============================================================================

# Tokens the cores write today. They are the literals of the current body shape; moving them into config, or a rename,
# then touches this block only.
TOK_SUMMARY='Tóm tắt'; TOK_EVIDENCE='Bằng chứng chạy'; TOK_FLOW='Luồng'; TOK_CRITERIA='Tiêu chí chấp nhận'
TOK_FIXES='Vá cho'; TOK_NOT_RUN='KHÔNG CHẠY:'; TOK_NO_STATE_CHANGE='KHÔNG ĐỔI HIỆN TRẠNG:'

# cenv [NAME=value ...] command ... — run a command in a minimal environment. GH_LOG and the closing-link knobs survive on
# purpose (the fake gh reads them); everything else of the caller's environment is dropped. BATON_POSTCHECK_WAITS is empty: a
# planted post-check failure is read once, not again after 15 s of waits (a suite that tests the retry sets it after cenv).
cenv() {
  env -i PATH="$PATH" HOME="$HOME" TMPDIR="$TMPDIR" GIT_CONFIG_GLOBAL="$GIT_CONFIG_GLOBAL" GIT_CONFIG_NOSYSTEM=1 \
      PYTHONUTF8=1 PYTHONDONTWRITEBYTECODE=1 OPEN_PR_LINK_WAIT_S=0 GH_LOG="${GH_LOG:-/dev/null}" BATON_POSTCHECK_WAITS= \
      GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t "$@"
}

# fresh — a new empty scratch directory (printed). Families run several times (real copy, then each mutant), so none may
# reuse a path.
fresh() { mktemp -d "$TMP/f.XXXXXX"; }

# mk_plugin_copy <dir> — a copy of the real plugin, bytecode removed.
mk_plugin_copy() { cp -r "$PLUGIN" "$1"; find "$1" -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null; }

# mutate <file> <old> <new> — replace exactly one occurrence; red when the anchor is gone, so a change of the core cannot
# turn a planted break into a silent no-op.
mutate() {
  python3 - "$1" "$2" "$3" <<'PY' || { bad "break anchor not found in $(basename "$1"): ${2:0:60}"; return 1; }
import sys
p, old, new = sys.argv[1:4]
t = open(p, encoding="utf-8").read()
if t.count(old) != 1:
    sys.exit(1)
open(p, "w", encoding="utf-8").write(t.replace(old, new, 1))
PY
}

# expect_red <label> <family fn> <plugin copy> <needle> — run one family on a broken copy with ok/bad silenced; the family
# must produce at least one failed check, and the failed checks must include <needle> (the tag of the intended check).
# The family runs in a subshell that stops at the first failed check tagged <needle>: that check is all the probe asserts on,
# and what the rest of the family would add (more failed checks) is never read. A family that never reaches the needle runs to
# its end, exactly as before, and the probe is red.
# The run is capped (capped.sh: PLANT_CAP_MEM_MB, PLANT_CAP_SECS): a break that eats memory or never ends is red by the cap that
# stopped it, which the line says, and the next family runs. Only this run is capped; the real-plugin families are not.
_expect_red_run() {  # _expect_red_run <family fn> <plugin copy> <needle> <result file> <scratch dir> — the subshell body of expect_red
  local fam=$1 dir=$2 needle=$3 rf=$4 QN=0 QLAB=""
  # The family's own scratch (every `fresh`, every mktemp) goes under <scratch dir>, which expect_red removes when the run ends.
  TMP=$5; TMPDIR=$5/tmpd; mkdir -p "$TMPDIR"; export TMP TMPDIR
  ok() { :; }
  bad() {
    QN=$((QN+1)); QLAB="$QLAB|$1"
    case "$1" in *"$needle"*) printf '%s\n%s\n' "$QN" "$QLAB" > "$rf"; exit 0;; esac
  }
  "$fam" "$dir" >/dev/null 2>&1
  printf '%s\n%s\n' "$QN" "$QLAB" > "$rf"
}
# Disk: a suite runs dozens of breaks and its tree is removed only when it exits, so each break would leave a copy of the plugin
# and the family's scratch trees until then (a plan run can reach 1.1 GiB of TMPDIR; the
# CI runner's tmp is 1 GiB). So expect_red removes the family's scratch after the run, a cap hit included, and the broken copy when it
# is a one-use `$TMP/break-<label>` directory (what BRK helpers make). A copy under any other name is the suite's to remove.
expect_red() {
  local label=$1 fam=$2 dir=$3 needle=$4 rf QN QLAB crc scratch b
  rf=$(mktemp "${TMPDIR:-/tmp}/expect-red.XXXXXX"); scratch=$(mktemp -d "${TMPDIR:-/tmp}/er-scratch.XXXXXX")
  capped _expect_red_run "$fam" "$dir" "$needle" "$rf" "$scratch"; crc=$?
  rm -rf "$scratch"
  case "$dir" in "$TMP"/break-*) b=${dir#"$TMP"/}; rm -rf "$TMP/${b%%/*}";; esac
  if cap_red "$crc" "break [$label]"; then rm -f "$rf"; return 0; fi
  QN=$(sed -n 1p "$rf"); QLAB=$(sed -n '2,$p' "$rf"); rm -f "$rf"
  [ "${QN:-0}" -gt 0 ] && ok "break [$label]: the family goes red ($QN failed checks)" || bad "break [$label]: the family stays green, the probe is blind"
  has "$QLAB" "$needle" "break [$label]: red on the intended check $needle"
}

# mk_tools <dir> <command>... — a bin directory holding only the named commands (symlinks), for PATHs that must LACK one.
mk_tools() {
  local d=$1 c p; shift; mkdir -p "$d"
  for c in "$@"; do p=$(command -v "$c") && ln -sf "$p" "$d/$c"; done
}
# bare_path <name> — PATH made of the network shims plus a small tool set WITHOUT gh (and without python3 when <name> is nogh-nopy).
bare_path() {
  local d="$TMP/tools-$1"
  if [ ! -d "$d" ]; then
    mk_tools "$d" git bash sh dirname basename grep cat sed head tail tr sort wc mkdir rm env true false
    [ "$1" = nogh-nopy ] || mk_tools "$d" python3
  fi
  printf '%s:%s' "$NET_SHIM_DIR" "$d"
}

# mk_origin — bare origin + a clone `w` with a seed commit on main and kb/intent/; prints the clone path.
mk_origin() {
  local d; d=$(fresh)
  git_ init -q --bare -b main "$d/origin.git"
  git_ clone -q "$d/origin.git" "$d/w" 2>/dev/null
  mkdir -p "$d/w/kb/intent"; echo seed > "$d/w/README.md"
  git_ -C "$d/w" add -A; git_ -C "$d/w" commit -q -m seed
  git_ -C "$d/w" branch -M main; git_ -C "$d/w" push -q -u origin main
  printf '%s' "$d/w"
}

# commit_in <tree> <file> <content> <message> — write, add that one file, commit.
commit_in() { printf '%s\n' "$3" > "$1/$2"; git_ -C "$1" add "$2"; git_ -C "$1" commit -q -m "$4"; }

# snap <tree> — the state of a main tree that a refused command must not change: refs, HEAD, reflogs, status, remote refs.
snap() {
  git_ -C "$1" rev-parse main; git_ -C "$1" symbolic-ref -q HEAD; git_ -C "$1" reflog; git_ -C "$1" reflog show main
  git_ -C "$1" status --porcelain; git_ -C "$1" for-each-ref; git_ -C "$1" ls-remote origin
}

# ref_exists <tree> <ref> — rc 0 when the ref resolves to a commit.
ref_exists() { git_ -C "$1" rev-parse --verify --quiet "$2^{commit}" >/dev/null 2>&1; }
# merges_in <tree> <ref> — number of merge commits reachable from <ref>.
merges_in() { git_ -C "$1" log --merges --oneline "$2" | wc -l | tr -d ' '; }

# hasline <text> <exact line> <label> — ok when the text has a line that is exactly <line>.
hasline() { printf '%s\n' "$1" | grep -qFx -- "$2" && ok "$3" || bad "$3 (no line '$2')"; }
# nline <text> <exact line> — how many lines of the text are exactly <line>.
nline() { printf '%s\n' "$1" | grep -cFx -- "$2" || true; }
# pj <json> <key> — one string field of a JSON object (a non-string is printed as JSON).
pj() { python3 -c 'import json,sys; v=json.load(sys.stdin)[sys.argv[1]]; sys.stdout.write(v if isinstance(v,str) else json.dumps(v))' "$2" <<<"$1"; }
# pkeys <json> — the keys of a JSON object, sorted, space separated.
pkeys() { python3 -c 'import json,sys; sys.stdout.write(" ".join(sorted(json.load(sys.stdin))))' <<<"$1"; }
# mk_submodule <main tree> <scratch dir> — adds a submodule `sub` (its origin has main) to <main tree>; prints its path.
mk_submodule() {
  git_ init -q --bare -b main "$2/sub.git"; git_ clone -q "$2/sub.git" "$2/seed" 2>/dev/null
  commit_in "$2/seed" a.txt a seed; git_ -C "$2/seed" branch -M main; git_ -C "$2/seed" push -q origin main
  git_ -C "$1" -c protocol.file.allow=always submodule add -q "$2/sub.git" sub >/dev/null 2>&1
  printf '%s' "$1/sub"
}

# ── PR-core helpers shared by test-core-pr.sh, test-core-pr-links.sh and test-core-adapters.sh ─────────────────────────────
# They use the globals PLX (plugin copy under test), GHB (a bin directory with the fake gh), PW (main tree), PT (linked worktree
# on feat/x) and F (a directory holding sum.md, ev.txt and an empty ev-empty.txt).
# mk_pr_repo — sets PW (main tree), PT (linked worktree on feat/x) and F (a directory with summary and evidence files).
mk_pr_repo() {
  PW=$(mk_origin); git_ -C "$PW" worktree add -q -b feat/x "$PW/../wt" main; PT=$(cd "$PW/../wt" && pwd -P)
  F=$(fresh)
  printf 'A real summary line.\n' > "$F/sum.md"; printf '$ echo ok\nok\n' > "$F/ev.txt"; : > "$F/ev-empty.txt"
}
# prx <cwd> <args...> — the core from <cwd>. prd <args...> — dry run from the worktree with the usual arguments first.
prx() { local d=$1; shift; ( cd "$d" && cenv python3 "$PLX/scripts/open_pr.py" "$@" ); }
prd() { prx "$PT" --dry-run --title "feat: x" --summary-file "$F/sum.md" --evidence-file "$F/ev.txt" --head feat/x "$@"; }
# prg <extra env NAME=value ...> -- <args...> — the core on its one transport (the fake gh first in PATH), from the worktree.
prg() {
  local e=(); while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
  ( cd "$PT" && cenv PATH="$GHB:$PATH" "${e[@]}" python3 "$PLX/scripts/open_pr.py" --title "feat: x" --summary-file "$F/sum.md" --evidence-file "$F/ev.txt" --head feat/x "$@" )
}


# ── intent-core helpers shared by test-core-branch.sh and test-core-adapters.sh (use the global PLX) ───────────────────────
core() { local w=$1; shift; cenv python3 "$PLX/scripts/intent_branch.py" --cwd "$w" "$@"; }

# new_intent <main tree> <slug> — record, branch (core), commit the record on it, push it, back to main.
new_intent() {
  printf -- '---\ndescription: "example"\n---\n\nintent text\n' > "$1/kb/intent/$2.md"
  core "$1" create-intent --slug "$2" >/dev/null 2>&1
  git_ -C "$1" add -A; git_ -C "$1" commit -q -m "intent $2"
  git_ -C "$1" push -q -u origin "intent/$2"; git_ -C "$1" checkout -q main
}
# task_wt <main tree> <name> <slug> <commits> — linked worktree on a new branch cut from origin/intent/<slug>, with N commits.
task_wt() {
  local wt="$1/../wt-$2" n
  git_ -C "$1" worktree add -q -b "$2" "$wt" "origin/intent/$3"
  wt=$(cd "$wt" && pwd -P)
  for n in $(seq 1 "${4:-1}"); do commit_in "$wt" "${2//\//-}-$n.txt" "$2 $n" "work $2 $n"; done
  printf '%s' "$wt"
}
# bump_origin <main tree> <slug> <file> — another worker lands a commit on origin/intent/<slug> from a second clone. The main
# tree does NOT fetch: its cached origin/intent/<slug> stays behind, which is the ordinary case the core must handle.
bump_origin() {
  local oc; oc=$(fresh)
  git_ clone -q "$(git_ -C "$1" remote get-url origin)" "$oc/c" 2>/dev/null
  git_ -C "$oc/c" checkout -q "intent/$2"; commit_in "$oc/c" "$3" "$3 from elsewhere" "elsewhere $3"
  git_ -C "$oc/c" push -q origin "intent/$2"
}
# release <worktree> — detach HEAD so the worktree no longer holds its branch.
release() { git_ -C "$1" checkout -q --detach; }

