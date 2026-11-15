#!/bin/sh
# Every hook command of the plugin: `/bin/sh "${CLAUDE_PLUGIN_ROOT}/scripts/pyrun.sh" [--say] "scripts/<script>" [args…]` runs that
# script of the plugin (the directory above this file's) with this machine's Python 3.8+. Read by an absolute /bin/sh, it needs no
# `sh` on PATH and no execute bit (a noexec mount, a copy that drops modes), and the plugin root appears once in the command.
# On Linux and macOS it is `exec python3 <root>/scripts/<script>`: stdin, stdout, the exit code and the script path are those of
# the `python3 "${CLAUDE_PLUGIN_ROOT}/scripts/<script>"` of before.
# Off Windows a python3 on PATH is run as before, its version unchecked as before (a probe would cost every hook a Python start).
# On Windows, or with no python3: `python3` and `python` may be Store shortcuts that run nothing, `py -3` is the launcher
# python.org installs; each is used only if it is Python 3.8+.
# No Python: exit 0, so no hook blocks an edit only because Python is missing; the one command with --say tells the session why.
# The same file is in vibemaestro-sdlc and vibemaestro-brain (each plugin is installed on its own); tests/test-pyrun.sh keeps them equal.
say=0
if [ "${1:-}" = --say ]; then say=1; shift; fi
script="${0%/*/*}/$1"; shift
if [ "${OS:-}" != Windows_NT ] && command -v python3 >/dev/null 2>&1; then
  exec python3 "$script" "$@"
fi
# Windows writes a pipe in the system code page (cp1252 on most machines): a hook message holding a character it lacks (the
# process core's arrow, a Vietnamese rule) was dropped whole, a block rule's deny with it. Claude Code reads hook output as UTF-8.
export PYTHONIOENCODING=utf-8
# shortcut: one probe per candidate on each hook (a Python start); cache the found interpreter if session start gets slow on Windows
usable() { "$@" -c 'import sys; sys.exit(sys.version_info < (3, 8))' </dev/null >/dev/null 2>&1; }
for p in python3 python; do
  command -v "$p" >/dev/null 2>&1 && usable "$p" && exec "$p" "$script" "$@"
done
command -v py >/dev/null 2>&1 && usable py -3 && exec py -3 "$script" "$@"
[ "$say" = 1 ] || exit 0
missing="Python 3.8 or newer"
command -v git >/dev/null 2>&1 || missing="$missing and no Git"
printf '{"systemMessage": "vibemaestro: this machine has no %s, so the kit is not running in this session (nothing is blocked). Ask Claude how to set it up on this machine.", "hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "The vibemaestro kit found no %s on this machine, so none of its hooks ran and nothing is blocked. The kit needs Python to run its hooks and scripts, and Git to keep the history of the work. Tell the person, in their own language and in plain words without jargon: what is missing and why the kit needs it, how they can check (a new terminal and `python --version` or `git --version`), and the way to install it that fits this machine best. Ask before you install anything."}}\n' "$missing" "$missing"
exit 0
