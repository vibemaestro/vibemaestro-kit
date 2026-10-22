#!/bin/bash
# =============================================================================
# Kit — no rule text twice: the rules of every plugin here, and a dependent plugin's rule pack, share no paragraph and no rule name
# =============================================================================
# Run: bash tests/test-no-duplicate-rules.sh
#
# A plugin that depends on vibemaestro-sdlc reuses the sdlc rules through its dependency; a copied paragraph would be reminded
# twice and drift. The dependent plugin here is the fixture tests/fixtures/dependent-plugin. Offline, reads the repo only.
#   Units: the body of every rules/*.instructions.md (frontmatter skipped), split at blank lines; a list item, a table row and a
#   heading are units of their own. Normalised: lower case, whitespace collapsed, a leading list marker removed.
#   [R] the real rules (every plugins/*/rules/) and the fixture's: no unit of 120 characters or more appears twice; no rule file
#       name (or an sdlc rule's old name) in two of them
#   [X] controls on a copy: a planted duplicate paragraph (other case and line breaks), a duplicate list item, a duplicate rule
#       name, an old sdlc name each make the check red; a duplicate of 119 characters does not
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"

SDLC="$SRC_ROOT/plugins/vibemaestro-sdlc"
DEP="$SRC_ROOT/tests/fixtures/dependent-plugin"
ROOTS=(); for d in "$SRC_ROOT"/plugins/*/; do [ -d "$d/rules" ] && ROOTS+=("${d%/}"); done
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
export PYTHONDONTWRITEBYTECODE=1

# dups <plugin root>... — one line per offence on stdout, `units <n>` per plugin on stderr; rc 1 when an offence, 0 when none
dups() {
  python3 -B - "$SDLC/scripts" "$@" <<'PY'
import os, re, sys
sys.path.insert(0, sys.argv[1])
import rules                                     # RENAMED_RULES: the old sdlc names still answer, so they are taken too
MIN = 120
seen, names, out = {}, {}, []
for root in sys.argv[2:]:
    d = os.path.join(root, "rules")
    n_units = 0
    for f in sorted(x for x in os.listdir(d) if x.endswith(".instructions.md")):
        for nm in [f] + [old for old, new in rules.RENAMED_RULES.items() if new == f]:
            if nm in names:
                out.append("duplicate rule name: %s in %s and %s" % (nm, names[nm], root))
            names.setdefault(nm, root)
        lines = open(os.path.join(d, f), encoding="utf-8").read().split("\n")
        i = 0
        if lines and lines[0].strip() == "---":   # skip the frontmatter
            i = next((k for k in range(1, len(lines)) if lines[k].strip() == "---"), len(lines) - 1) + 1
        units, cur = [], None
        for k in range(i, len(lines)):
            s = lines[k]
            if not s.strip():
                cur = None
                continue
            if re.match(r"\s*(?:[-*+]\s|\d+\.\s|\||#)", s) or cur is None:
                cur = [k + 1, []]
                units.append(cur)
            cur[1].append(s)
        for line, body in units:
            t = re.sub(r"\s+", " ", " ".join(body)).strip().lower()
            t = re.sub(r"^(?:[-*+]|\d+\.)\s+", "", t)
            if len(t) < MIN:
                continue
            n_units += 1
            where = "%s:%d" % (os.path.join(os.path.basename(root), "rules", f), line)
            if t in seen:
                out.append("duplicate paragraph: %s and %s: %s" % (seen[t], where, t[:60]))
            else:
                seen[t] = where
    print("units %d %s" % (n_units, os.path.basename(root)), file=sys.stderr)
print("\n".join(out)) if out else None
sys.exit(1 if out else 0)
PY
}

echo "== [R] the real rules of every plugin here, and the fixture's =="
eq "${ROOTS[*]}" "$SDLC" "[R] instrument: the plugins with a rules/ directory are vibemaestro-sdlc alone"
O=$(dups "${ROOTS[@]}" "$DEP" 2>"$TMP/err"); rc=$?
eq "$rc" 0 "[R] no paragraph of 120 characters or more twice, no rule name twice (rc 0)"
empty "$O" "[R] …and no offence printed"
for pm in vibemaestro-sdlc:10 dependent-plugin:1; do
  p=${pm%:*}; n=$(sed -n "s/^units \([0-9]*\) $p\$/\1/p" "$TMP/err")
  [ "${n:-0}" -ge "${pm#*:}" ] && ok "[R] instrument: $n units of 120+ characters compared in $p" || bad "[R] instrument: only '${n:-0}' units read in $p"
done

echo "== [X] planted breaks on a copy =="
copy() { rm -rf "$TMP/s" "$TMP/g"; mkdir -p "$TMP/s" "$TMP/g"; cp -r "$SDLC/rules" "$TMP/s/"; cp -r "$DEP/rules" "$TMP/g/"; }
G="$TMP/g/rules/fixture-clusters.instructions.md"

copy
# the longest paragraph of an sdlc rule, re-wrapped at other places and in upper case, appended to the dependent plugin's rule
P=$(awk 'BEGIN{RS=""} {gsub(/\n/," "); if (length($0)>length(b) && $0 !~ /^(---|#|-|\||[0-9]+\.)/) b=$0} END{print b}' \
  "$SDLC/rules/before-ready.instructions.md")
[ "${#P}" -ge 120 ] && ok "[X] instrument: the planted paragraph is ${#P} characters" || bad "[X] instrument: planted paragraph too short (${#P})"
printf '\n%s\n' "$(printf '%s' "$P" | tr '[:lower:]' '[:upper:]' | fold -s -w 70)" >> "$G"
O=$(capped dups "$TMP/s" "$TMP/g" 2>/dev/null); rc=$?   # capped: memory and time caps (fixtures/capped.sh)
if ! cap_red "$rc" "[X] a planted duplicate paragraph"; then
eq "$rc" 1 "[X] a planted duplicate paragraph (other case, other line breaks) is red"
has "$O" "s/rules/before-ready.instructions.md" "[X] …naming the sdlc rule"
has "$O" "g/rules/fixture-clusters.instructions.md" "[X] …and the dependent plugin's rule"
fi

copy
L=$(grep -m1 -E '^- .{120,}' "$SDLC/rules/pr-no-leaks.instructions.md")
nonempty "$L" "[X] instrument: an sdlc list item of 120+ characters to plant"
printf '\n%s\n' "$L" >> "$G"
capped dups "$TMP/s" "$TMP/g" >/dev/null 2>&1; rc=$?
cap_red "$rc" "[X] a planted duplicate list item" || eq "$rc" 1 "[X] a planted duplicate list item is red"

copy
cp "$G" "$TMP/g/rules/git-process.instructions.md"
O=$(capped dups "$TMP/s" "$TMP/g" 2>/dev/null); rc=$?
if ! cap_red "$rc" "[X] a pack rule named like an sdlc rule"; then
eq "$rc" 1 "[X] a pack rule named like an sdlc rule is red"
has "$O" "duplicate rule name: git-process.instructions.md" "[X] …naming the file"
fi

copy
cp "$G" "$TMP/g/rules/quy-trinh-git.instructions.md"
O=$(capped dups "$TMP/s" "$TMP/g" 2>/dev/null); rc=$?
if ! cap_red "$rc" "[X] a pack rule named like an old sdlc rule name"; then
eq "$rc" 1 "[X] a pack rule named like an sdlc rule's old name is red"
has "$O" "duplicate rule name: quy-trinh-git.instructions.md" "[X] …naming the old name"
fi

for n in 119 120; do
  copy
  T=$(printf 'z%.0s' $(seq 1 "$n"))
  printf '\n%s\n' "$T" >> "$G"; printf '\n%s\n' "$T" >> "$TMP/s/rules/git-process.instructions.md"
  if [ "$n" = 119 ]; then   # green-expected: not capped
    dups "$TMP/s" "$TMP/g" >/dev/null 2>&1; eq "$?" 0 "[X] boundary: a duplicate of 119 characters is not counted"
  else
    capped dups "$TMP/s" "$TMP/g" >/dev/null 2>&1; rc=$?
    cap_red "$rc" "[X] boundary: a duplicate of $n characters" || eq "$rc" 1 "[X] boundary: a duplicate of 120 characters is red"
  fi
done

echo; summary
