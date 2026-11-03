#!/bin/bash
# =============================================================================
# The BatonRun skill and rule: they name the standard docs/batonrun.md, the skill's stop list is the runner's, and the
# always-on text (at most 1,396 bytes) and the rule (at most 23 lines) stay within their budgets
# =============================================================================
# Run: bash tests/test-batonrun-standard.sh
#
# The checker is tests/fixtures/batonrun_standard_check.py (it reads form only, plugin code only: the documents are not tested).
# This suite runs it on the real tree (green) and on an unchanged copy of the files it reads.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"

CHECK="$HERE/fixtures/batonrun_standard_check.py"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
export PYTHONDONTWRITEBYTECODE=1

FILES="plugins/vibemaestro-sdlc/skills/batonrun/SKILL.md plugins/vibemaestro-sdlc/rules/batonrun.instructions.md
plugins/vibemaestro-sdlc/rules/workflow-core.instructions.md plugins/vibemaestro-sdlc/scripts/baton.py"

echo "== the real tree =="
O=$(python3 -I -B "$CHECK" "$SRC_ROOT" 2>&1); rc=$?
eq "$rc" 0 "the real tree passes (rc 0)"
[ "$rc" = 0 ] || printf '%s\n' "$O" | sed 's/^/       /'
LAST=$(printf '%s\n' "$O" | tail -1)
N=$(printf '%s\n' "$LAST" | sed -n 's/^\([0-9]*\) checks, 0 problems$/\1/p')
[ "${N:-0}" -ge 9 ] && ok "instrument: the checker ran $N checks (at least 9)" || bad "instrument: the last line is '$LAST'"

# copy: a fresh tree holding the files the checker reads
copy() {
  rm -rf "$TMP/t"; mkdir -p "$TMP/t"
  for f in $FILES; do mkdir -p "$TMP/t/$(dirname "$f")"; cp "$SRC_ROOT/$f" "$TMP/t/$f"; done
}

copy
O=$(python3 -I -B "$CHECK" "$TMP/t" 2>&1); eq "$?" 0 "control: an unchanged copy passes"

echo "== instrument controls =="
python3 -I -B "$CHECK" >/dev/null 2>&1; eq "$?" 2 "control: no root is bad usage (rc 2)"

summary
