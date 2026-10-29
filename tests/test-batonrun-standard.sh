#!/bin/bash
# =============================================================================
# The BatonRun skill and rule: they name the standard docs/batonrun.md, the skill's stop list is the runner's, and the
# always-on text (at most 1,396 bytes) and the rule (at most 23 lines) stay within their budgets
# =============================================================================
# Run: bash tests/test-batonrun-standard.sh
#
# The checker is tests/fixtures/batonrun_standard_check.py (it reads form only, plugin code only: the documents are not tested).
# This suite runs it on the real tree (green), then
# on copies of the files it reads that each carry ONE planted break and must make it red on the intended check. A planted break
# that does not change the copy fails the suite, so a break cannot silently stop being planted.
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

# plant <id> <file> <old> <new> <expected problem text>: replace every <old> in <file> by <new>; the checker must name the problem
plant() {
  local id=$1 file=$2 old=$3 new=$4 want=$5 out rc
  copy
  if ! python3 -I -B - "$TMP/t/$file" "$old" "$new" <<'PY'
import sys
p, old, new = sys.argv[1:4]
t = open(p, encoding="utf-8").read()
if old not in t:
    sys.exit(1)
open(p, "w", encoding="utf-8").write(t.replace(old, new))
PY
  then bad "planted break [$id]: the change was not applied"; return; fi
  out=$(capped python3 -I -B "$CHECK" "$TMP/t" 2>&1); rc=$?   # capped: memory and time caps (fixtures/capped.sh)
  cap_red "$rc" "planted break [$id]" && return
  if [ "$rc" = 1 ] && printf '%s\n' "$out" | grep -qF -- "$want"; then ok "planted break [$id] is red: $want"
  else bad "planted break [$id] not caught (rc $rc): $(printf '%s\n' "$out" | head -3 | tr '\n' ' ')"; fi
}

echo "== one planted break per check =="
K=plugins/vibemaestro-sdlc/skills/batonrun/SKILL.md
plant stop-skill "$K" "- \`no-way-back\`:" "- no-way-back:" "$K: the stop list"
plant stop-baton plugins/vibemaestro-sdlc/scripts/baton.py '"money-org", ' "" "is not baton.py's"
plant ptr-skill "$K" "docs/batonrun.md" "docs/x.md" "$K: does not name the standard"
plant ptr-rule plugins/vibemaestro-sdlc/rules/batonrun.instructions.md "docs/batonrun.md" "docs/x.md" "batonrun.instructions.md: does not name"
plant ptr-core plugins/vibemaestro-sdlc/rules/workflow-core.instructions.md "docs/batonrun.md" "docs/x.md" "the BatonRun bullet does not name the standard"
plant always-on plugins/vibemaestro-sdlc/rules/workflow-core.instructions.md "delivered as BatonRun.**" \
  "delivered as BatonRun.** $(printf 'x%.0s' $(seq 1 400))" "the always-on text is"
plant always-on-desc "$K" "description: \"" "description: \"$(printf 'y%.0s' $(seq 1 400))" "the always-on text is"
plant rule-lines plugins/vibemaestro-sdlc/rules/batonrun.instructions.md "Run the launcher bare" $'one more line\nRun the launcher bare' \
  "batonrun.instructions.md: 24 lines, over 23"

echo "== instrument controls =="
python3 -I -B "$CHECK" >/dev/null 2>&1; eq "$?" 2 "control: no root is bad usage (rc 2)"

summary
