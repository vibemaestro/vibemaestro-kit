#!/bin/bash
# =============================================================================
# LIVE (not in CI): the exit probe — after a real compaction, does the brain keep 10 of 10 pinned decisions?
# =============================================================================
# Run, from this repository's checkout, on a machine where `claude` is logged in (python3 3.8+ and git on PATH; no tmux):
#     bash tests/live/brain-probe.sh --runs 3 --model opus   the exit run on the coordinator's model: about 30-45 minutes,
#                                                           about 2.5M tokens processed per run
#     bash tests/live/brain-probe.sh --plan        the protocol, the cost estimate and the options; starts nothing
# rc 0 PASS (H 10/10 in every run, every injected block <= 8,000 characters, C < 10/10), 1 FAIL, 2 stopped or void (the reason
# is printed; nothing is scored), 3 the control also reached 10/10 ("not shown necessary at this size"; the owner decides).
#
# The harness is tests/fixtures/brain-probe/probe.py;
# tests/test-brain-matrix.sh runs it against a fake claude (fake_claude.py in the same directory), never a live one.
#
# What it touches: a scratch directory (projects, XDG_STATE_HOME, the probe's logs), removed at the end unless --keep. Claude
# Code itself writes what any session in a new folder writes, in the user's own config: the sessions' transcripts under
# ~/.claude/projects/ (their directories are printed on stderr at the end). Every session runs with --setting-sources
# project,local, so the user's installed plugins (an installed vibemaestro-brain among them) stay out; the preflight stops the
# run unless exactly one brain, this checkout's, is loaded, and unless the block SessionStart:compact leaves is used after
# --resume. --strict-mcp-config keeps the user's MCP servers out too.
# The brain's plugin.json depends on vibemaestro-sdlc, which --setting-sources project,local leaves not enabled, and Claude Code
# does not load a plugin whose dependency is missing (its hooks never run). So every session, in both arms, also loads this
# checkout's sdlc by --plugin-dir; the scratch project's .vibemaestro/sdlc.json says `hooks: off`, so the sdlc is loaded and
# silent. The preflight checks the manifest's dependencies before spending and stops if the sdlc's SessionStart text shows.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
PROBE="$ROOT/tests/fixtures/brain-probe/probe.py"
command -v python3 >/dev/null 2>&1 || { echo "brain-probe: stopped: python3 is not on PATH" >&2; exit 2; }
[ -f "$PROBE" ] || { echo "brain-probe: stopped: $PROBE is missing (run it from the repository checkout)" >&2; exit 2; }
exec python3 "$PROBE" "$@"
