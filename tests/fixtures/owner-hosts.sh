# shellcheck shell=bash
# =============================================================================
# One table of who may answer the owner's dialog, run by the brain's suite (guard-owner, `brain owner`) and the baton's
# (baton-guard, `sign --by owner`) against their own hook and CLI, so the two copies of the host rule cannot drift.
# =============================================================================
# A row: id, permission mode, CLAUDE_CODE_ENTRYPOINT (- unset), the host's flags, the host's program name, the version lines
# of the running host, of CLAUDE_CODE_EXECPATH (- unset) and of `claude` on PATH (a version prints "X (Claude Code)", node prints
# v22.11.0, - prints nothing), the decision (ask: the hook asks and the write after it succeeds), and a part of the reason a
# deny gives (- not checked: the two plugins word it differently). The flags: SDK, those the VS Code extension's SDK passes;
# STUB, a fork of the host runs the command, its command line the same (as a Git Bash fork that runs a Windows program
# keeps); NEST, a script that starts the host again with the SDK's flags, as an SDK app run inside the host does, so the
# outer host's argv does not hold the inner one's; - none; "none": no host process at all, a terminal with no CLAUDE_PID.
# The facts of the official hosts: the VS Code extension's package (extension.js) sets CLAUDE_CODE_ENTRYPOINT=claude-vscode and
# its SDK passes --permission-prompt-tool=stdio for canUseTool; the claude binary names claude-desktop and claude-desktop-3p.
OWNER_SDK="--output-format stream-json --verbose --input-format stream-json --permission-prompt-tool=stdio"
OWNER_HOSTS='
vscode	default	claude-vscode	SDK	claude	2.1.290	-	-	ask	-
desktop	default	claude-desktop	SDK	claude	2.1.290	-	-	ask	-
desktop-3p	acceptEdits	claude-desktop-3p	SDK	claude	2.1.290	-	-	ask	-
two-words	default	claude-vscode	--permission-prompt-tool stdio	claude	2.1.290	-	-	ask	-
fork-stub	default	claude-vscode	SDK STUB	claude	2.1.290	-	-	ask	-
sdk-ts	default	sdk-ts	SDK	claude	2.1.290	-	-	deny	a process started with --permission-prompt-tool
sdk-py	default	sdk-py	SDK	claude	2.1.290	-	-	deny	a process started with --permission-prompt-tool
sdk-cli	default	sdk-cli	SDK	claude	2.1.290	-	-	deny	a process started with --permission-prompt-tool
no-entry	default	-	SDK	claude	2.1.290	-	-	deny	a process started with --permission-prompt-tool
cli	default	cli	SDK	claude	2.1.290	-	-	deny	a process started with --permission-prompt-tool
cowork	default	local-agent	SDK	claude	2.1.290	-	-	deny	a process started with --permission-prompt-tool
mcp-tool	default	claude-vscode	--permission-prompt-tool mcp__x__y	claude	2.1.290	-	-	deny	a process started with --permission-prompt-tool
two-tools	default	claude-vscode	SDK --permission-prompt-tool mcp__x__y	claude	2.1.290	-	-	deny	a process started with --permission-prompt-tool
print	default	claude-vscode	SDK -p	claude	2.1.290	-	-	deny	-
long-print	default	claude-vscode	SDK --print	claude	2.1.290	-	-	deny	-
not-claude	default	claude-vscode	SDK	host	2.1.290	-	-	deny	a process started with --permission-prompt-tool
nested-sdk	default	claude-vscode	SDK :: bash NEST	claude	2.1.290	-	-	deny	a process started with --permission-prompt-tool
auto-vscode	auto	claude-vscode	SDK	claude	2.1.290	-	-	ask	-
auto-desktop	auto	claude-desktop	SDK	claude	2.1.211	-	-	ask	-
auto-old	auto	claude-desktop	SDK	claude	2.1.210	-	-	deny	Claude Code 2.1.210 is older than 2.1.211
auto-fake-path	auto	claude-desktop	SDK	claude	2.1.210	-	2.1.300	deny	Claude Code 2.1.210 is older than 2.1.211
auto-unread	auto	claude-desktop	SDK	claude	-	node	-	deny	(tried: the running Claude Code (process
auto-unread-tried	auto	claude-desktop	SDK	claude	-	node	-	deny	CLAUDE_CODE_EXECPATH, `claude` on PATH). In a terminal, the VS Code extension or the Claude desktop app, switch the permission mode to default
auto-sdk	auto	sdk-ts	SDK	claude	2.1.290	-	-	deny	a process started with --permission-prompt-tool
auto-sdk-old	auto	sdk-ts	SDK	claude	2.1.210	-	-	deny	Anywhere else (an SDK app, a custom prompt tool)
auto-pid-not-claude	auto	cli	-	host	2.1.290	-	-	deny	(tried: `claude` on PATH)
auto-terminal	auto	cli	-	claude	2.1.290	-	-	ask	-
auto-path	auto	-	none	claude	-	-	2.1.211	ask	-
auto-path-old	auto	-	none	claude	-	-	2.1.210	deny	Claude Code 2.1.210 is older than 2.1.211
auto-npm	auto	-	none	claude	-	node	2.1.211	ask	-
auto-none	auto	-	none	claude	-	-	-	deny	(tried: `claude` on PATH)
auto-node-only	auto	-	none	claude	-	node	-	deny	(tried: CLAUDE_CODE_EXECPATH, `claude` on PATH)
'

# owner_vline <dir> <name> <version field> [win] — a program <dir>/<name> that prints the field's version line on --version;
# prints its path. win: on Windows <dir>/<name>.cmd, since Windows' Python starts no #!/bin/sh script (an npm install's claude
# is a .cmd there too)
owner_vline() {
  local l="" f="$1/$2"
  case $3 in -) ;; node) l=v22.11.0;; *) l="$3 (Claude Code)";; esac
  if [ "${4:-}" = win ] && [ "${OS:-}" = Windows_NT ]; then
    f="$f.cmd"; if [ -n "$l" ]; then printf '@echo %s\r\n' "$l"; else printf '@exit /b 0\r\n'; fi > "$f"
  else
    printf '#!/bin/sh\n[ -n "%s" ] && echo "%s"\nexit 0\n' "$l" "$l" > "$f"; chmod +x "$f"
  fi
  printf '%s' "$f"
}

# owner_hosts <dir> <runner> <eq> <has> — every row, in a fresh <dir>/<id>: HOST, the words that run a command under the row's
# host (a bash script that answers --version with its version line, exports CLAUDE_PID as Claude Code does, and runs the words
# after `::`); HOST_ENV, the row's PATH, CLAUDE_CODE_ENTRYPOINT and CLAUDE_CODE_EXECPATH as VAR=value words. `<runner> <mode>`
# prints the decision (ask/<rc of the write> for an ask) on its first line and the deny's reason on its second.
owner_hosts() {
  local dir=$1 runner=$2 ceq=$3 chas=$4 id mode entry flags prog rv ev pv want why d out fl run got exp
  while IFS=$'\t' read -r id mode entry flags prog rv ev pv want why; do
    [ -n "$id" ] || continue
    d="$dir/$id"; mkdir -p "$d/bin"
    owner_vline "$d/bin" claude "$pv" win > /dev/null
    HOST_ENV=(PATH="$d/bin:$PATH")
    [ "$entry" = - ] || HOST_ENV+=(CLAUDE_CODE_ENTRYPOINT="$entry")
    if [ "$ev" != - ]; then HOST_ENV+=(CLAUDE_CODE_EXECPATH="$(owner_vline "$d" execpath "$ev" win)"); fi
    HOST=()
    if [ "$flags" != none ]; then
      run='"$@"'; [[ $flags == *STUB* ]] && run='( "$@"; exit $? )'   # STUB: a fork of the host runs it, its command line the same
      printf '#!/bin/bash\nif [ "$1" = --version ]; then exec "%s/v" --version; fi\nwhile [ $# -gt 0 ] && [ "$1" != :: ]; do shift; done\nshift\nexport CLAUDE_PID=$(cat /proc/$$/winpid 2>/dev/null || echo $$)\n%s\n' \
        "$d" "$run" > "$d/$prog"
      owner_vline "$d" v "$rv" > /dev/null
      printf '#!/bin/bash\nexec bash "%s/%s" %s "$@"\n' "$d" "$prog" "$OWNER_SDK" > "$d/nest"
      fl=${flags//SDK/$OWNER_SDK}; fl=${fl//NEST/$d/nest}; fl=${fl// STUB/}; [ "$fl" = - ] && fl=""
      read -r -a HOST <<< "bash $d/$prog $fl"
      HOST+=(::)
    fi
    if [ "${OS:-}" = Windows_NT ] && [ "$mode" = auto ] && [ "$flags" != none ]; then
      printf '  SKIP [HOST] %s: Windows Python cannot run the fake host, a Git Bash script, by its command line\n' "$id"; continue
    fi
    out=$("$runner" "$mode"); got=$(printf '%s\n' "$out" | head -n 1); exp=$([ "$want" = ask ] && echo ask/0 || echo deny)
    [ "$got" = "$exp" ] || got="$got: $(printf '%s\n' "$out" | sed -n 2p)"   # a failure shows the deny's reason
    "$ceq" "$got" "$exp" "[HOST] $id: $want"
    [ "$why" = - ] || "$chas" "$(printf '%s\n' "$out" | sed -n 2p)" "$why" "[HOST] $id: the reason says '$why'"
  done <<< "$OWNER_HOSTS"
}

# owner_fold <code file> on|off|restore — the copy's LAUNCHER_FOLD: on runs the macOS launcher rule (app_launcher) on this
# system, off runs it nowhere (a system other than macOS, also on a Mac), restore puts the line back (macOS only). A copy's
# platform constant, as the suites' other copies' constants: not a break
owner_fold() {
  python3 - "$1" "$2" <<'PY' || { bad "owner_fold: LAUNCHER_FOLD not found in $1"; return 1; }
import re, sys
p, how = sys.argv[1:3]
s = open(p, encoding="utf-8").read()
new = {"on": "LAUNCHER_FOLD = True", "off": "LAUNCHER_FOLD = False", "restore": 'LAUNCHER_FOLD = sys.platform == "darwin"'}[how]
s, n = re.subn(r'(?m)^LAUNCHER_FOLD = .*$', new, s)
if n != 1:
    sys.exit(1)
open(p, "w", encoding="utf-8", newline="").write(s)
PY
}

# owner_launchers <dir> <runner> <eq> <has> <code file> — the macOS desktop app's launcher (kb: the measured lineage): the app's
# program, a launcher of its bundle that keeps Claude Code's command line after its own words, Claude Code. Every program is a
# copy of bash at a path of its own, so the rule reads real program paths (/proc/<pid>/exe; proc_pidpath on macOS); a
# program's script reads the words it passes on from a file where its own argv must not carry the flag. A row: id, fold (on:
# the rule runs, off: a system other than macOS), the words the app starts, the decision. <code file> is the copy's baton.py
# or brain_host.py (the file that holds LAUNCHER_FOLD); the rows end with the rule as the copy had it.
owner_launchers() {
  local dir=$1 runner=$2 ceq=$3 chas=$4 code=$5 id fold words want d b got exp out
  if [ "${OS:-}" = Windows_NT ]; then
    printf '  SKIP [LAUNCH] the macOS launcher rows: Windows reads no program path of a Git Bash script\n'; return 0
  fi
  b=$(command -v bash)
  d="$dir/app"; mkdir -p "$d/Claude.app/Contents/MacOS" "$d/Claude.app/Contents/Helpers" "$d/Other.app/Contents/Helpers" "$d/bin" "$d/cc" "$d/cc2"
  for p in Claude.app/Contents/MacOS/Claude Claude.app/Contents/Helpers/disclaimer Claude.app/Contents/Helpers/disclaimer2 \
           Claude.app/Contents/Helpers/mid Other.app/Contents/Helpers/disclaimer bin/disclaimer cc/claude cc2/claude bin/nest \
           bin/app bin/argv0; do
    cp "$b" "$d/$p"
  done
  # app.sh <words file> <command…>: the app runs the words, then the command, as its child; launch.sh runs its words as its
  # child; launch-off.sh drops one of them; launch-mid.sh hands them to a program that carries no flag; host.sh is Claude Code
  printf 'A=(); while IFS= read -r w; do A+=("$w"); done < "$1"; shift\n"${A[@]}" "$@"\n' > "$d/app.sh"
  printf '"$@"\n' > "$d/launch.sh"
  printf 'a=("$@"); unset "a[4]"; "${a[@]}"\n' > "$d/launch-off.sh"
  printf 'printf "%%s\\n" "$@" > "%s/mid.words"; "%s/Claude.app/Contents/Helpers/mid" "%s/app.sh" "%s/mid.words"\n' "$d" "$d" "$d" "$d" > "$d/launch-mid.sh"
  printf 'while [ $# -gt 0 ] && [ "$1" != :: ]; do shift; done\nshift\nexport CLAUDE_PID=$$\n"$@"\n' > "$d/host.sh"
  printf 'n=$1; shift; exec -a "$n" "$@"\n' > "$d/argv0.sh"     # the next program, its argv[0] the first word
  printf 'exec "%s/cc2/claude" "%s/host.sh" --output-format stream-json --input-format stream-json --permission-prompt-tool=stdio :: "$@"\n' "$d" "$d" > "$d/nest.sh"
  local A="$d/Claude.app/Contents/MacOS/Claude" H="$d/Claude.app/Contents/Helpers" CC="$d/cc/claude $d/host.sh $OWNER_SDK ::"
  local rows="
mac-launcher	on	$H/disclaimer $d/launch.sh $CC	ask
non-macos	off	$H/disclaimer $d/launch.sh $CC	deny
outside-bundle	on	$d/bin/disclaimer $d/launch.sh $CC	deny
other-bundle	on	$d/Other.app/Contents/Helpers/disclaimer $d/launch.sh $CC	deny
tail-one-off	on	$H/disclaimer $d/launch-off.sh $CC	deny
not-direct-parent	on	$H/disclaimer $d/launch-mid.sh $CC	deny
two-launchers	on	$H/disclaimer2 $d/launch.sh $H/disclaimer $d/launch.sh $CC	deny
nested-sdk	on	$H/disclaimer $d/launch.sh $CC $d/bin/nest $d/nest.sh	deny
argv0-in-bundle	on	$d/bin/argv0 $d/argv0.sh $H/disclaimer $d/bin/disclaimer $d/launch.sh $CC	deny
parent-outside-bundle	on	$H/disclaimer $d/launch.sh $CC	deny
"
  while IFS=$'\t' read -r id fold words want; do
    [ -n "$id" ] || continue
    owner_fold "$code" "$fold" || return 1
    printf '%s\n' $words > "$d/$id.words"
    HOST=("$A" "$d/app.sh" "$d/$id.words"); HOST_ENV=(PATH="$PATH" CLAUDE_CODE_ENTRYPOINT=claude-desktop)
    [ "$id" != parent-outside-bundle ] || HOST[0]="$d/bin/app"    # the app's own program outside any bundle
    out=$("$runner" default); got=$(printf '%s\n' "$out" | head -n 1); exp=$([ "$want" = ask ] && echo ask/0 || echo deny)
    [ "$got" = "$exp" ] || got="$got: $(printf '%s\n' "$out" | sed -n 2p)"
    "$ceq" "$got" "$exp" "[LAUNCH] $id: $want"
    [ "$want" = ask ] || "$chas" "$(printf '%s\n' "$out" | sed -n 2p)" "a process started with --permission-prompt-tool" \
                           "[LAUNCH] $id: the reason names the process that carries the flag"
  done <<< "$rows"
  owner_fold "$code" restore; HOST=(); HOST_ENV=()
}
