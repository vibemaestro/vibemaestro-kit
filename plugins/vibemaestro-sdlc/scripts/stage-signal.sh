#!/usr/bin/env bash
# =============================================================================
# The stage signal — tell the sandbox which SDLC stage an intent is in
# =============================================================================
# Use (the scripts call it; a skill runs it by "${CLAUDE_PLUGIN_ROOT}/scripts/stage-signal.sh"):
#   stage-signal.sh <spec|code|review|ship> [<stem>] [--branch <name>] [--subagents <0-99>]
#
# It runs `session-notify --intent <stem> --stage <stage> [--subagents <n>] "<text>"`, so a dashboard can show each intent at its
# stage. <stem> is the intent file name without `.md`; left out, it is read from the checked-out branch (or from `--branch`), which
# must be `<branch.intent_prefix><stem>`.
#
# It does nothing, and says nothing, when `session-notify` is not on the PATH or its `--help` does not name `--stage` (a laptop
# session, or a pod whose image has the plain command only): one probe, no state. The text is a fixed phrase plus the stem, and the
# stem must be letters, digits, `-` and `_`, 1-80 characters, so no user or PR text can reach the command. A bad argument or a
# refusal of the command prints one line on stderr; the exit code is 0 in every case, because a signal must never fail the work.
# =============================================================================
set -u
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
export LC_ALL=C

command -v session-notify >/dev/null 2>&1 || exit 0
TO=(); command -v timeout >/dev/null 2>&1 && TO=(timeout 10)
"${TO[@]+"${TO[@]}"}" session-notify --help 2>&1 | grep -qF -- --stage || exit 0

note() { echo "stage-signal: $1; no signal sent" >&2; exit 0; }
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

if [ -z "$STEM" ]; then
    [ -n "$BRANCH" ] || BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || BRANCH=""
    PFX=$(python3 "$HERE/sdlc_config.py" get branch.intent_prefix 2>/dev/null) || PFX="intent/"
    case "$BRANCH" in "$PFX"?*) STEM="${BRANCH#"$PFX"}" ;; *) note "not on an intent branch" ;; esac
fi
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
