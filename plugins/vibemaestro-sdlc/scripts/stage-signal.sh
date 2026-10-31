#!/usr/bin/env bash
# =============================================================================
# The stage signal — tell the sandbox which SDLC stage an intent is in
# =============================================================================
# Use (the scripts call it; a skill runs it by "${CLAUDE_PLUGIN_ROOT}/scripts/stage-signal.sh"):
#   stage-signal.sh <spec|code|review|ship> [<stem>] [--branch <name>] [--subagents <0-99>]
#   stage-signal.sh ask [<stem>] [--branch <name>]            the question on stdin
#   stage-signal.sh done [<stem>] [--branch <name>]           the report on stdin
#   stage-signal.sh progress <tests-pass|tests-fail|ci-green|ci-red|fix-pushed> [<stem>] [--branch <name>]
#   stage-signal.sh bind <stem> --agent <id>                  the main session ties a subagent to its intent
#
# Outside a sandbox (no `session-notify` on the PATH) every form records into the local state file of the session
# (`scripts/local_state.py`; the place and shape are the item `local-state` of CONTRACT.md), and nothing at all without
# CLAUDE_CODE_SESSION_ID. In a sandbox the stage forms run as below, and ask, done, progress and bind do nothing: the sandbox
# records those through its own `session-ask`, `session-done`, `session-notify` and hooks.
#
# It runs `session-notify --intent <stem> --stage <stage> [--subagents <n>] "<text>"`, so a dashboard can show each intent at its
# stage. <stem> is the intent file name without `.md`; left out, it is read from the checked-out branch (or from `--branch`), which
# must be `<branch.intent_prefix><stem>`.
#
# In a sandbox it does nothing, and says nothing, when the `--help` of `session-notify` does not name `--stage` (a pod whose
# image has the plain command only): one probe, no state. The text is a fixed phrase plus the stem, and the
# stem must be letters, digits, `-` and `_`, 1-80 characters, so no user or PR text can reach the command. A bad argument or a
# refusal of the command prints one line on stderr; the exit code is 0 in every case, because a signal must never fail the work.
# =============================================================================
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
export LC_ALL=C

TO=(); command -v timeout >/dev/null 2>&1 && TO=(timeout 10)
note() { echo "stage-signal: $1; no signal sent" >&2; exit 0; }
# stem_of_branch — the stem from --branch or the checked-out branch, into STEM; a refusal when it is not an intent branch
stem_of_branch() {
    [ -n "$BRANCH" ] || BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || BRANCH=""
    PFX=$(python3 "$HERE/sdlc_config.py" get branch.intent_prefix 2>/dev/null) || PFX="intent/"
    case "$BRANCH" in "$PFX"?*) STEM="${BRANCH#"$PFX"}" ;; *) note "not on an intent branch" ;; esac
}

if ! command -v session-notify >/dev/null 2>&1; then
    # Outside a sandbox: the local state file. local_state.py checks every value against its pattern and refuses with one line.
    [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || exit 0
    VERB="${1:-}"; [ $# -gt 0 ] && shift
    STEP="" STEM="" BRANCH="" N="" AGENT=""
    case "$VERB" in
        spec|code|review|ship|ask|done|bind) ;;
        progress) STEP="${1:-}"; [ $# -gt 0 ] && shift ;;
        *) note "unknown stage" ;;
    esac
    if [ $# -gt 0 ]; then case "$1" in --*) ;; *) STEM="$1"; shift ;; esac; fi
    while [ $# -gt 0 ]; do
        case "$1:$VERB" in
            --branch:bind) note "bind takes its stem, not --branch" ;;
            --branch:*) BRANCH="${2:-}"; shift 2 || shift ;;
            --subagents:spec|--subagents:code|--subagents:review|--subagents:ship) N="${2:-}"; [ -n "$N" ] || note "--subagents needs a number"; shift 2 ;;
            --agent:bind) AGENT="${2:-}"; [ -n "$AGENT" ] || note "--agent needs an id"; shift 2 ;;
            *) note "unknown argument '${1:0:20}'" ;;
        esac
    done
    if [ -z "$STEM" ]; then [ "$VERB" = bind ] && note "bind needs the stem"; stem_of_branch; fi
    A=("$VERB" "$STEM")
    [ -n "$N" ] && A+=(--subagents "$N")
    [ "$VERB" = progress ] && A+=(--step "$STEP")
    [ "$VERB" = bind ] && A+=(--agent "$AGENT")
    command -v python3 >/dev/null 2>&1 || note "no python3"
    "${TO[@]+"${TO[@]}"}" python3 -I "$HERE/local_state.py" "${A[@]}" || echo "stage-signal: the local state writer failed; going on" >&2
    exit 0 # local: the signal never fails the caller
fi
case "${1:-}" in ask|done|progress|bind) exit 0 ;; esac
"${TO[@]+"${TO[@]}"}" session-notify --help 2>&1 | grep -qF -- --stage || exit 0

bad_stem() {  # 0 when the stem is not safe to send
    case "$1" in
        ''|-*) return 0 ;;
        *[!A-Za-z0-9_-]*) return 0 ;;
    esac
    [ "${#1}" -gt 80 ]
}

STAGE="${1:-}"; [ $# -gt 0 ] && shift
STEM="" BRANCH="" N=""
if [ $# -gt 0 ]; then case "$1" in --*) ;; *) STEM="$1"; shift ;; esac; fi
while [ $# -gt 0 ]; do
    case "$1" in
        --branch) BRANCH="${2:-}"; shift 2 || shift ;;
        --subagents) N="${2:-}"; [ -n "$N" ] || note "--subagents needs a number"; shift 2 ;;
        *) note "unknown argument '${1:0:20}'" ;;
    esac
done

case "$STAGE" in spec|code|review|ship) ;; *) note "unknown stage" ;; esac
if [ -n "$N" ]; then case "$N" in [0-9]|[0-9][0-9]) ;; *) note "--subagents is not 0-99" ;; esac; fi

[ -z "$STEM" ] && stem_of_branch
bad_stem "$STEM" && note "the intent stem is empty, longer than 80 characters or has a character outside A-Za-z0-9_-"

case "$STAGE" in
    spec) T="$STEM: spec stage started" ;;
    code) T="$STEM: coding started" ;;
    review) T="$STEM: review round started" ;;
    ship) T="$STEM: ship started" ;;
esac

"${TO[@]+"${TO[@]}"}" session-notify --intent "$STEM" --stage "$STAGE" ${N:+--subagents "$N"} "$T" >/dev/null 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
    echo "stage-signal: session-notify refused the $STAGE signal (exit $RC); going on" >&2
    exit 0 # refused: the signal never fails the caller
fi
exit 0
