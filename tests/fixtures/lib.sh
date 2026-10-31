# shellcheck shell=bash
# =============================================================================
# Dụng cụ chung cho các suite tests/test-*.sh (được `source`)
# =============================================================================
# Không có `set -e` ở đây và không chạy gì khi source: chỉ định nghĩa hàm.
#
# Nguyên tắc dụng cụ: hook của plugin được chạy bằng CHÍNH chuỗi `command` trong hooks/hooks.json (qua
# `bash -c`, với biến môi trường Claude Code đặt) — không gọi thẳng tên script. Gõ sai tên script trong
# hooks.json thì suite đỏ, thay vì xanh trên một đường chạy mà Claude Code không bao giờ đi.
# Nguồn tên biến: tài liệu hooks của Claude Code ("Environment Variables for Hooks": CLAUDE_PROJECT_DIR,
# CLAUDE_PLUGIN_ROOT, CLAUDE_PLUGIN_DATA, CLAUDE_PLUGIN_OPTION_<KEY>, CLAUDE_ENV_FILE).
# =============================================================================

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
has()   { case "$1" in *"$2"*) ok "$3";; *) bad "$3 (thiếu '$2')";; esac; }
hasnt() { case "$1" in *"$2"*) bad "$3 (thừa '$2')";; *) ok "$3";; esac; }
eq()    { [ "$1" = "$2" ] && ok "$3" || bad "$3 (được '$1', cần '$2')"; }
ne()    { [ "$1" != "$2" ] && ok "$3" || bad "$3 (hai vế đều '$1')"; }
empty() { [ -z "$1" ] && ok "$2" || bad "$2 (cần rỗng, được ${#1} byte: ${1:0:120})"; }
nonempty() { [ -n "$1" ] && ok "$2" || bad "$2 (rỗng)"; }

# shellcheck source=netguard.sh
. "$(dirname "${BASH_SOURCE[0]}")/netguard.sh"
# shellcheck source=capped.sh
. "$(dirname "${BASH_SOURCE[0]}")/capped.sh"
# shellcheck source=plant.sh
. "$(dirname "${BASH_SOURCE[0]}")/plant.sh"   # plant_break: one planted break through capped, its own copy, no bytecode

# ── git_: git pinned to the scratch tree ─────────────────────────────────────────────────────────────────────────
# Every fixture git call goes through git_ (G in gates.sh wraps it). It runs only on a target INSIDE the suite's scratch root
# (FIXTURE_SCRATCH, exported by clean_env) and, for anything but init and clone, only where a repository of its own sits between the
# target and that root: a directory inside a work tree belongs to the enclosing repository, so a path that lands in the real worktree
# (or in a scratch directory that is not a repository) must stop here instead of committing there. The accepted grammar is small on
# purpose: global options `-C <path>` (folded in order, as git does) and `-c k=v` (not core.worktree/gitdir/bare), then a subcommand; every
# absolute or climbing (`..`) path argument must land inside the root; GIT_DIR, GIT_WORK_TREE, GIT_INDEX_FILE and the like are removed from git's
# environment. Anything else (`--git-dir`, `--work-tree`, a bare `--version` with other words) is refused: use `-C <repo>`. Refusal: a line on stderr naming
# the suite and the reason, rc 97 (the code of the netguard shims for "forbidden"), git not run. Why: a repeated $RANDOM name made
# mk_repo return three lines of `git commit` text as its "path", cm made that relative directory in the real worktree and the
# commit landed there. Pure bash tests, no extra git process per call.
_pin_suite() { basename -- "${BASH_SOURCE[${#BASH_SOURCE[@]}-1]:-$0}"; }
_pin_norm() {  # _pin_norm <absolute path> — the path with its `.` and `..` segments resolved lexically
  local IFS=/ seg out=""
  set -f   # called only inside $(...): no globbing of a segment, and no effect on the caller
  for seg in $1; do
    case "$seg" in ''|.) ;; ..) out=${out%/*};; *) out="$out/$seg";; esac
  done
  printf '%s' "${out:-/}"
}
_pin_phys() {  # _pin_phys <path> — physical absolute path. What exists is resolved by the kernel (`cd -P`: a symlink is followed and a `..`
  # after it is applied to the link's TARGET, as git's own chdir does). The rest, a tail of names that are not there yet, is appended and
  # normalised: its `..` can only cancel names that do not exist, so no link can hide in it.
  local p=$1 rest="" base
  case "$p" in /*) ;; *) p="$PWD/$p";; esac
  while [ ! -d "$p" ]; do rest="/${p##*/}$rest"; p=${p%/*}; [ -n "$p" ] || { p=/; break; }; done
  base=$(cd -P -- "$p" 2>/dev/null && pwd -P)
  _pin_norm "$base$rest"
}
_pin_inside() { case "$1" in "$FIXTURE_SCRATCH"|"$FIXTURE_SCRATCH"/*) return 0;; esac; return 1; }
_pin_outside_arg() {  # _pin_outside_arg <arg> <base dir> → 0 when the argument names a path outside the scratch root (prints why)
  # A path is judged where it lands, physically (symlinks followed): an absolute one as it is, a relative one that looks like a path (it holds a
  # `/` or starts with a dot) joined to the directory git runs in. A plain word (`main`, `-b`'s value) and `main..feat` are not paths and pass, unless the word names a symlink there.
  local a=$1 v=$1 ph
  case "$a" in -*=*) v=${a#*=};; esac
  case "$v" in
    /*) ;;
    */*|.*) v="$2/$v";;
    *) [ -L "$2/$v" ] || return 1; v="$2/$v";;   # a plain word is no path, unless it names a symlink in the directory git runs in (`worktree add el`)
  esac
  ph=$(_pin_phys "$v"); _pin_inside "$ph" && return 1
  echo "path argument '$a' lands outside the scratch root"; return 0
}
_pin_check() {  # _pin_check <git args…> → 0 allowed; else prints the reason and returns 1
  local args=("$@") n=$# i=0 j a v c="" sub="" target ph last
  if [ -z "${FIXTURE_SCRATCH:-}" ]; then
    echo "FIXTURE_SCRATCH is not set in $(_pin_suite): clean_env was skipped, so there is no scratch root to pin git to"; return 1
  fi
  [ "$n" -ne 1 ] || case "${args[0]}" in --version|version) return 0;; esac
  while [ $i -lt $n ]; do  # global options: only -C <path> (each relative to the one before, as git does) and -c <key=value>
    a=${args[$i]}
    case "$a" in
      -C) v=${args[$((i+1))]:-}; [ -n "$v" ] || { echo "-C without a path"; return 1; }
          if [ -z "$c" ]; then c=$v; else case "$v" in /*) c=$v;; *) c="$c/$v";; esac; fi; i=$((i+2));;
      -c) case "${args[$((i+1))]:-}" in core.worktree*|core.gitdir*|core.bare*) echo "-c ${args[$((i+1))]} moves the repository"; return 1;; esac; i=$((i+2));;
      -*) echo "global option '$a' is not allowed (only -C and -c)"; return 1;;
      *) sub=$a; break;;
    esac
  done
  [ -n "$sub" ] || { echo "no git subcommand"; return 1; }
  if [ -n "$c" ]; then
    target=$(_pin_phys "$c"); _pin_inside "$target" || { echo "-C '$c' is outside the scratch root"; return 1; }
  else
    target=$(_pin_phys "$PWD")
  fi
  local judge=1 key=""
  if [ "$sub" = config ]; then   # a config VALUE is not a location (gpg.program /bin/false), except for the few keys that move or run things
    for ((j=i+1; j<n; j++)); do case "${args[$j]}" in -*) ;; *) key=$(printf '%s' "${args[$j]}" | tr 'A-Z' 'a-z'); break;; esac; done
    case "$key" in core.worktree|core.gitdir|core.hookspath|core.bare|include.path|includeif.*) ;; *) judge=0;; esac
  fi
  if [ "$judge" = 1 ]; then for ((i=i+1; i<n; i++)); do _pin_outside_arg "${args[$i]}" "$target" && return 1; done; fi   # every other argument: where it lands, if it is a path
  case "$sub" in
    init|clone)  # a repository to be created: with -C its directory is the base; without it the last argument must be an absolute path inside, else the cwd must be
      if [ -z "$c" ]; then
        last=${args[$((n-1))]}
        case "$last" in /*) ;; *) _pin_inside "$target" || { echo "$sub has no -C and no absolute destination, and the current directory is outside the scratch root"; return 1; };; esac
      fi
      return 0;;
  esac
  _pin_inside "$target" || { echo "no -C and the current directory is outside the scratch root"; return 1; }
  [ -d "$target" ] || { echo "'$target' is not a directory"; return 1; }
  while :; do  # a repository of its own, at or above the target and below the root
    if [ -e "$target/.git" ] || { [ -f "$target/HEAD" ] && [ -d "$target/objects" ]; }; then return 0; fi
    [ "$target" != "$FIXTURE_SCRATCH" ] || break
    target=$(dirname -- "$target")
  done
  echo "no repository of its own between the target and the scratch root (git would use one above it)"; return 1
}
git_() {
  local why
  if ! why=$(_pin_check "$@"); then
    printf 'git_: refusing "%s": %s\n' "$*" "$why" >&2
    # a refusal inside a suite that carries on must not pass for green: summary() turns the suite red when this file is not empty
    [ -z "${FIXTURE_SCRATCH:-}" ] || printf '%s\n' "$why" >> "$FIXTURE_SCRATCH/.pin-refusals" 2>/dev/null
    return 97
  fi
  # the repository-location variables are taken out of git's environment: GIT_DIR and friends would send it elsewhere whatever -C says
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
    GIT_CEILING_DIRECTORIES="$(dirname -- "$FIXTURE_SCRATCH")" git -c user.email=t@t -c user.name=t -c commit.gpgsign=false "$@"
}

# môi trường sạch cho mọi suite: không hub, không biến của plugin/phiên, HOME trống.
# clean_env <thư mục tạm> — gọi ngay sau mktemp. Phép "độc lập khỏi hub" của plugin được đo trong trạng thái này.
clean_env() {
  local t=$1
  # `HOME` is replaced below, which hides packages installed in the user site (PyYAML on macOS). Pin the user base to the
  # real one first so the YAML checks still parse real YAML.
  export PYTHONUSERBASE="${PYTHONUSERBASE:-$(python3 -m site --user-base 2>/dev/null)}"
  export GIT_CONFIG_GLOBAL="$t/gitconfig"; : > "$GIT_CONFIG_GLOBAL"; export GIT_CONFIG_NOSYSTEM=1
  export FIXTURE_SCRATCH; FIXTURE_SCRATCH=$(cd -P -- "$t" && pwd -P)   # the root git_ is pinned to
  export HOME="$t/home"; mkdir -p "$HOME"
  export TMPDIR="$t/tmpd"; mkdir -p "$TMPDIR"
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES   # a suite's git must not be sent elsewhere
  # CLAUDE_CONFIG_DIR too: the hooks read the plugin registry under it (rule packs), and a suite must not see the real one
  unset VIBEMAESTRO_HUB CLAUDE_PLUGIN_OPTION_HUB_PATH INSTRUCTIONS_TARGET_ROOT INTENT_SLUG SEAT \
        CLAUDE_PLUGIN_ROOT CLAUDE_PROJECT_DIR CLAUDE_ENV_FILE CLAUDE_CONFIG_DIR KUBECONFIG PYTHONDONTWRITEBYTECODE
  # The state directory and the session: a suite run from inside a Claude Code session must not write the session's real local
  # state file (stage-signal.sh, outside a sandbox), which a dashboard would show as real work. XDG_STATE_HOME is the default
  # place under the scratch HOME, so a check of the default place still holds; a test that needs the session sets it itself.
  export XDG_STATE_HOME="$HOME/.local/state"
  unset CLAUDE_CODE_SESSION_ID CLAUDE_CODE_CHILD_SESSION
  net_guard_install "$t"
}

# ── bóc JSON hook ────────────────────────────────────────────────────────────
_jq() { python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
h = d.get("hookSpecificOutput") or {}
k = sys.argv[1]
v = {"ctx": h.get("additionalContext", ""), "sys": d.get("systemMessage", ""),
     "dec": h.get("permissionDecision", ""), "why": h.get("permissionDecisionReason", "")}[k]
sys.stdout.write(v)' "$1"; }
ctx()  { printf '%s' "$1" | _jq ctx; }
sysm() { printf '%s' "$1" | _jq sys; }
dec()  { printf '%s' "$1" | _jq dec; }
why()  { printf '%s' "$1" | _jq why; }
isjson() { printf '%s' "$1" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' 2>/dev/null; }
nchars() { python3 -c 'import sys; print(len(sys.stdin.read()))' <<<"$1"; }

# ── lệnh hook lấy từ một file hooks (hooks.json của plugin, hoặc settings.json) ─
# hook_cmds <file> <event> <tool>  → mỗi dòng một `command` (không chứa xuống dòng)
# `matcher` là regex neo hai đầu kiểu Claude Code; <tool>="" = bỏ lọc (SessionStart).
hook_cmds() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, re, sys
f, ev, tool = sys.argv[1:4]
d = json.load(open(f))
d = d.get("hooks", d)
for blk in d.get(ev, []):
    m = blk.get("matcher")
    if tool and m and not re.fullmatch(m, tool):
        continue
    for h in blk.get("hooks", []):
        if h.get("type") == "command":
            print(h["command"])
PY
}

# run_cmds <file> <event> <tool> <stdin> — chạy từng command, in stdout nối nhau.
# Biến môi trường do người gọi đặt (export hoặc tiền tố) được kế thừa.
run_cmds() {
  local file=$1 ev=$2 tool=$3 in=$4 c
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    printf '%s' "$in" | bash -c "$c" 2>/dev/null
  done < <(hook_cmds "$file" "$ev" "$tool")
}

# ── bộ luật giả: bản chép của plugin THẬT, chỉ thay thư mục rules/ ──────────────
VN='Thân bài tiếng Việt đa byte.'
rule() {  # rule <plugin> <file> <applyTo|-> <applyWhen|-> <level|-> <mô tả>
  { printf -- '---\n'
    [ "$3" != - ] && printf 'applyTo: "%s"\n' "$3"
    [ "$4" != - ] && printf 'applyWhen: "%s"\n' "$4"
    [ "$5" != - ] && printf 'level: %s\n' "$5"
    printf 'description: "%s"\n---\n\n# %s\n\n%s\n' "$6" "$6" "$VN"; } > "$1/rules/$2"
}
dec_() {  # dec_ <repo> <file> <applyTo> <mô tả>
  mkdir -p "$1/kb/decisions"
  printf -- '---\napplyTo: "%s"\ndescription: "%s"\n---\n\n# %s\n' "$3" "$4" "$4" > "$1/kb/decisions/$2"
}

CORE_NAME=workflow-core.instructions.md
CORE_LAST='CUOI-LOI-QUY-TRINH-DA-DEN-NOI'
# mk_core <plugin> [số đoạn đệm] — file lõi quy trình giả, dòng cuối là mốc.
mk_core() {
  local p=$1 pad=${2:-3} i
  {
    printf -- '---\ndescription: "LOI-QUY-TRINH-GIA"\n---\n\n'
    printf '# Cách làm việc chung (giả)\n\nDONG-DAU-LOI-QUY-TRINH\n\n'
    for i in $(seq 1 "$pad"); do printf -- '- Đoạn đệm số %s: giải thích vì sao trước khi làm, rồi mới làm.\n\n' "$i"; done
    printf '%s\n' "$CORE_LAST"
  } > "$p/rules/$CORE_NAME"
}

# mk_plugin <dir> — bản chép plugin THẬT (script, hook, skill thật) với bộ luật GIẢ trong rules/.
mk_plugin() {
  local d=$1
  cp -r "$PLUGIN" "$d"; find "$d" -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null
  rm -rf "$d/rules"; mkdir -p "$d/rules"
  rule "$d" r-all.instructions.md      '**'           - - 'PL-LUAT-MOI-FILE'
  rule "$d" r-clusters.instructions.md 'clusters/**'  - - 'PL-LUAT-CLUSTERS'
  rule "$d" r-cmd.instructions.md      -   'lenh-bay'      - 'PL-LUAT-LENH-BAY'
  rule "$d" r-block.instructions.md    -   'nguy-hiem'     block 'PL-LUAT-CHAN-NGUY-HIEM'
  mk_core "$d"
}

# mk_bait_hub <dir> — "hub giả có lỗi": thứ plugin KHÔNG ĐƯỢC đọc nữa. Có đủ bố cục mà hub cũ đòi
# (.github/hooks/*.py, .github/instructions/*.md) và mọi thứ trong đó là mồi: luật mang dấu BAIT-HUB-*,
# script nổ/ghi file bẫy. Nếu plugin còn đọc hoặc chạy bất cứ thứ gì ở đây, dấu BAIT-HUB-* lọt vào output
# hoặc file `bait-ran` xuất hiện (và test đỏ).
mk_bait_hub() {
  local h=$1
  mkdir -p "$h/.github/hooks" "$h/.github/instructions" "$h/.github/skills/sandbox-session" "$h/scripts" "$h/kb/decisions"
  for s in instructions-for-path instructions-for-command rules_source; do
    printf 'open("%s/bait-ran","a").write("%s\\n")\nprint("BAIT-HUB-SCRIPT-CHAY")\nraise SystemExit(3)\n' "$h" "$s" > "$h/.github/hooks/$s.py"
  done
  printf -- '---\ndescription: "BAIT-HUB-LOI-MAU-THUAN"\n---\n\nBAIT-HUB-DONG-LOI\n' > "$h/.github/instructions/$CORE_NAME"
  printf -- '---\napplyTo: "**"\napplyWhen: "."\nlevel: block\ndescription: "BAIT-HUB-LUAT-CHAN-MOI-THU"\n---\n\nBAIT-HUB\n' > "$h/.github/instructions/bait.instructions.md"
  printf -- '---\nname: sandbox-session\ndescription: BAIT-HUB-SKILL\n---\n' > "$h/.github/skills/sandbox-session/SKILL.md"
  printf '#!/bin/bash\ntouch "%s/bait-ran"\necho BAIT-HUB-SCRIPT-CHAY\nexit 9\n' "$h" > "$h/scripts/intent-branch.sh"
  cp "$h/scripts/intent-branch.sh" "$h/scripts/open-pr.sh"; chmod +x "$h/scripts/"*.sh
  git_ -C "$h" init -q -b main; git_ -C "$h" add -A; git_ -C "$h" commit -qm bait
}

# mk_app <dir> [có kb 1|0] — repo app giả (không có hook dự án nào).
mk_app() {
  local a=$1 kb=${2:-1}
  mkdir -p "$a/src" "$a/clusters" "$a/docs"
  : > "$a/src/main.ts"; : > "$a/clusters/x.yaml"; : > "$a/docs/y.md"
  if [ "$kb" = 1 ]; then
    mkdir -p "$a/kb/intent"
    printf '# Hiện trạng giả\n' > "$a/kb/current-state.md"
    printf -- '---\ndescription: "y"\n---\n' > "$a/kb/intent/2026-10-01-viec-dang-mo.md"
    dec_ "$a" d-app.md 'src/**' 'APP-QD-SRC'
  fi
  git_ -C "$a" init -q -b main
  git_ -C "$a" add -A; git_ -C "$a" commit -qm c1
}

# payload JSON cho từng loại hook
p_edit() { printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$1" "$2"; }
p_nb()   { printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"NotebookEdit","tool_input":{"notebook_path":"%s"}}' "$1" "$2"; }
p_bash() { printf '{"session_id":"%s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"%s"}}' "$1" "$2"; }
p_start() { printf '{"session_id":"%s","hook_event_name":"SessionStart","source":"startup"}' "$1"; }

# băm cây (bỏ .git) + trạng thái git — dùng cho G2
tree_hash() { (cd "$1" && find . -path ./.git -prune -o -type f -print0 | sort -z | xargs -0 sha1sum | sha1sum | cut -d' ' -f1); }
git_state() { git_ -C "$1" status --porcelain | sha1sum | cut -d' ' -f1; }

sid() { echo "s$RANDOM$RANDOM$RANDOM"; }

# tree_shape <root> — the tree a suite runs on, told by three marks: the root kb/ and .vibemaestro/sdlc.json, which
# scripts/export-public.sh never writes, and a plugins/<name>/LICENSE, which only it writes (it refuses a committed one). `private`:
# the first two and no plugin LICENSE (the repo); `export`: a plugin LICENSE and neither of the others (the public tree); any other
# mix is neither shape: prints `neither` and returns 1, so a check that asks gets no expected value and goes red
tree_shape() {
  local k=0 c=0 l=0 f
  [ -d "$1/kb" ] && k=1
  [ -e "$1/.vibemaestro/sdlc.json" ] && c=1
  for f in "$1"/plugins/*/LICENSE; do [ -e "$f" ] && l=1; done
  case "$k$c$l" in 110) echo private;; 001) echo export;; *) echo neither; return 1;; esac
}
# want_version <root> <plugin dir> — the `version` the plugin's manifest must carry in that tree: none on the private tree (prints
# nothing); on the export, the released version of its CHANGELOG.md (the first `## ` heading when that is X.Y.Z, read as
# export-public.sh reads it: bytes, split on LF, undecodable bytes replaced; no file is never released), nothing when never
# released; `neither-shape` on a tree of neither shape, `unreadable` when the CHANGELOG cannot be read (no manifest matches either)
want_version() {
  local s; s=$(tree_shape "$1") || { echo neither-shape; return 1; }
  [ "$s" = export ] || return 0
  python3 -c '
import os, re, sys
p = sys.argv[1]
if not os.path.lexists(p):
    sys.exit(0)
try:
    raw = open(p, "rb").read()
except OSError:
    print("unreadable"); sys.exit(1)
for line in raw.decode("utf-8", "replace").split("\n"):
    if line.startswith("## "):
        v = line[3:].strip()
        print(v if re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", v, re.ASCII) else "")
        break' "$2/CHANGELOG.md"
}

summary() {
  local nl
  if [ -n "${NET_LOG:-}" ]; then   # a suite that never installed the shims has nothing to say
    nl=$(net_guard_empty) && ok "network guard: no curl, wget, nc or ssh call (shim log empty)" || bad "network guard: a network tool was called: $nl"
  fi
  if [ -n "${FIXTURE_SCRATCH:-}" ] && [ -s "$FIXTURE_SCRATCH/.pin-refusals" ]; then
    bad "git_ refused $(wc -l < "$FIXTURE_SCRATCH/.pin-refusals" | tr -d ' ') call(s) during this suite (first reason: $(head -n 1 "$FIXTURE_SCRATCH/.pin-refusals")): a refused fixture call weakens the test, fix the call"
  fi
  if [ -n "${TMPDIR:-}" ] && [ -s "$TMPDIR/.cap-hits" ]; then   # capped.sh: a hit is red by the cap, not by the break's own check: say how many
    echo "  note: $(wc -l < "$TMPDIR/.cap-hits" | tr -d ' ') planted run(s) ended by a cap (memory/time), see the 'red by the' lines above"
  fi
  echo "$PASS ok, $FAIL fail"
  # run-all.sh sets SUITE_RESULTS_DIR so the ledger suite can read the counts of this very run instead of running the suites again
  [ -n "${SUITE_RESULTS_DIR:-}" ] && printf '%s %s\n' "$PASS" "$FAIL" > "$SUITE_RESULTS_DIR/$(basename "$0" .sh)" 2>/dev/null
  [ "$FAIL" -eq 0 ]
}

# baton_set_mode <XDG_STATE_HOME> <manual|auto> — a suite's setup: the mode file as a `mode` change the owner signed leaves it,
# with its `dialog <id>` line (baton.py PROOF_LINE). The change itself takes the owner's dialog record (fixtures/baton-owner.sh
# mode_asked), which a suite that only needs a mode to be set does not exercise.
baton_set_mode() {
  ( umask 077; mkdir -p "$1/vibemaestro/baton" && printf '%s\ndialog %s\n' "$2" 0123456789abcdef0123456789abcdef > "$1/vibemaestro/baton/mode" )
}
