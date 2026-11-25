#!/bin/bash
# =============================================================================
# Gate kb-check (plugins/vibemaestro-sdlc/gates/workflows/kb-check.yml, installed by `install_gates.py --only kb-check`)
# =============================================================================
# Run: bash tests/test-gates-kb-check.sh
#
#   [T] the template: one job, pull_request only, never a draft, contents: read, no secret, fetch-depth 0, a guarded self-hosted runs-on
#   [I] the installer: opt-in, the 12 modules and the pin, a repo that already has gates gets only the new files, never an overwrite, --update, en
#   [R] the rendered workflow's own `run:` block, run on scratch repos built from nothing (a bare origin, a base with a story, a spec and a plan,
#       a PR ref): a Title-less story plan, an empty, an 81-character and a backtick Title are red; a valid Title and a PR with no kb file are
#       green; the bare `kb.py check` is green on the Title-less plan (why the step has `check links`); a base without kb.py warns and passes;
#       the PR's own copy of kb.py or a missing module cannot make it green
# Real git, no network, no sleep. Every red-expected run goes through `capped`.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
# shellcheck source=fixtures/flow.sh
. "$HERE/fixtures/flow.sh"
# shellcheck source=fixtures/ports.sh
. "$HERE/fixtures/ports.sh"
# shellcheck source=fixtures/gates.sh
. "$HERE/fixtures/gates.sh"

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
INSTALL="$PLUGIN/scripts/install_gates.py"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
export PYTHONDONTWRITEBYTECODE=1
python3 -c 'import yaml' 2>/dev/null || { bad "PyYAML is missing: the workflow cannot be read"; summary; exit 1; }
MODULES="current_state everyday hookout init_setup kb kb_index kb_plan messages rule_packs rules sdlc_config vsdlc"

pin_ok() {  # pin_ok <repo> — the kit line is 40 hex or -, and the sha256 line is recomputed here from the 12 files on disk
  python3 - "$1" <<'PY'
import hashlib, re, sys
root, names = sys.argv[1], "current_state everyday hookout init_setup kb kb_index kb_plan messages rule_packs rules sdlc_config vsdlc".split()
pin = open(root + "/.vibemaestro/gates/kb-check.pin").read().split("\n")
assert re.fullmatch(r"kit: (-|[0-9a-f]{40})", pin[0]), pin[0]
h = hashlib.sha256()
for n in sorted(x + ".py" for x in names):
    h.update(n.encode() + b"\0" + open("%s/.vibemaestro/gates/%s" % (root, n), "rb").read() + b"\0")
assert pin[1] == "sha256: " + h.hexdigest() and pin[2] == "", pin
PY
}
install() {  # install <repo> [args…] — OUT and RC of the installer
  local r=$1; shift; RC=0; OUT=$(cenv python3 "$INSTALL" --root "$r" "$@" 2>&1) || RC=$?
}
mkrepo() { local d; d=$(fresh); G init -q -b main "$d"; echo "$d"; }
tree_hash() { (cd "$1" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -c1-16); }

echo "== [T] the template =="
TPL="$PLUGIN/gates/workflows/kb-check.yml"
[ -f "$TPL" ] && ok "template kb-check.yml exists" || { bad "template kb-check.yml is missing"; }
R0=$(mkrepo); install "$R0" --only kb-check
want 0 "[T] --only kb-check installs into an empty repo"
WF="$R0/.github/workflows/kb-check.yml"
python3 - "$WF" <<'PY' && ok "[T] one job, pull_request only, not a draft, contents: read, no secret, fetch-depth 0, one pinned checkout, one run step" || bad "[T] the rendered workflow has the wrong shape"
import re, sys, yaml
text = open(sys.argv[1], encoding="utf-8").read()
d = yaml.safe_load(text)
on = d.get(True, d.get("on"))                       # PyYAML reads the key `on` as True
assert list(on) == ["pull_request"], on
assert "draft == false" in d["jobs"]["kb-check"]["if"]
assert d["permissions"] == {"contents": "read"}, d["permissions"]
assert list(d["jobs"]) == ["kb-check"]
steps = d["jobs"]["kb-check"]["steps"]
uses = [s for s in steps if "uses" in s]; runs = [s for s in steps if "run" in s]
assert len(steps) == 2 and len(uses) == 1 and len(runs) == 1, steps
assert re.fullmatch(r"actions/checkout@[0-9a-f]{40} # v4\.2\.2", uses[0]["uses"] + " # v4.2.2")
assert uses[0]["with"]["fetch-depth"] == 0
assert "secrets." not in text and "pull_request_target" not in text and "@@" not in text
assert "${{" not in runs[0]["run"], "an expression inside run:"
PY
grep -qxF "    runs-on: \${{ vars.CI_GATE_RUNNER || vars.CI_RUNNER || 'ubuntu-latest' }}" "$WF" && ok "[T] runs-on: the gate runner variable, the repo's, the default (same form as the other gates)" || bad "[T] runs-on is not the default expression"
R1=$(mkrepo); install "$R1" --only kb-check --runner-default "self-hosted only"
python3 - "$WF" "$R1/.github/workflows/kb-check.yml" "$HERE/fixtures" <<'PY' && ok "[T] self-hosted only: no label at all, both variables unset (or empty) fail the evaluation, a set one answers" || bad "[T] the self-hosted guard does not hold"
import sys, yaml
sys.path.insert(0, sys.argv[3]); import gh_expr
ro = yaml.safe_load(open(sys.argv[2]))["jobs"]["kb-check"]["runs-on"]
import re
assert not re.search(r"ubuntu|windows|macos", open(sys.argv[2]).read(), re.I) and "fromJSON" in ro, ro
for v, want in (({}, None), ({"CI_RUNNER": ""}, None), ({"CI_RUNNER": "ours"}, "ours"), ({"CI_GATE_RUNNER": "gate", "CI_RUNNER": "ours"}, "gate")):
    try: got = gh_expr.evaluate(ro, {"vars": v})
    except gh_expr.EvalError: got = None
    assert got == want, (v, want, got)
PY

echo "== [I] the installer =="
R2=$(mkrepo); install "$R2"
want 0 "[I] a default install"; has_q "kb-check" && bad "[I] a default install mentions kb-check" || ok "[I] kb-check is opt-in: a default install writes no kb-check file"
[ -e "$R2/.vibemaestro/gates/kb.py" ] && bad "[I] a default install vendored kb.py" || ok "[I] …and no kb.py"
H0=$(tree_hash "$R2")
install "$R2" --only kb-check
want 0 "[I] an onboarded repo: --only kb-check" "kb-check.yml"
eq "$(printf '%s\n' "$OUT" | grep -c '^wrote ')" 12 "[I] …12 files are new: the workflow, kb.py, 9 modules, the pin"
eq "$(printf '%s\n' "$OUT" | grep -c '^kept ')" 3 "[I] …the config loader, the message table and gate_common.py are kept as they were"
for m in $MODULES; do [ -f "$R2/.vibemaestro/gates/$m.py" ] && cmp -s "$R2/.vibemaestro/gates/$m.py" "$PLUGIN/scripts/$m.py" || bad "[I] .vibemaestro/gates/$m.py is not the kit's copy"; done; ok "[I] …the 12 modules are the plugin's own bytes"
pin_ok "$R2" && ok "[I] the pin: a kit line (40 hex or -) and the sha256 of the 12 files, recomputed from what is on disk" || bad "[I] the pin is wrong"
install "$R2" --only kb-check
want 0 "[I] a second run"; eq "$(printf '%s\n' "$OUT" | grep -c -E '^(wrote|replaced) ')" 0 "[I] …writes nothing"
H1=$(tree_hash "$R2"); install "$R2" --only kb-check; eq "$(tree_hash "$R2")" "$H1" "[I] …and changes no byte"
# an earlier install's files stay byte for byte: hash everything of the first install that the second one did not add
R2b=$(mkrepo); install "$R2b"; cp -r "$R2b/.github" "$TMP/before-gh"; cp -r "$R2b/.vibemaestro" "$TMP/before-vg"; install "$R2b" --only kb-check
for f in $(cd "$TMP/before-gh" && find . -type f); do cmp -s "$TMP/before-gh/$f" "$R2b/.github/$f" || bad "[I] $f of the first install changed"; done
for f in $(cd "$TMP/before-vg" && find . -type f); do cmp -s "$TMP/before-vg/$f" "$R2b/.vibemaestro/$f" || bad "[I] $f of the first install changed"; done; ok "[I] every file of the first install is unchanged"
# a person's edit is kept; --update replaces the plugin's own copies and the pin, never the workflow
printf '# mine\n' >> "$R2/.github/workflows/kb-check.yml"   # not a break: an input of the keep case
printf '# stale\n' >> "$R2/.vibemaestro/gates/kb.py"        # not a break: an input of the --update case
install "$R2" --only kb-check
want 0 "[I] an edited workflow and an edited kb.py"; printf '%s\n' "$OUT" | grep -q -E '^kept \(differs\) +\.github/workflows/kb-check\.yml$' && ok "[I] …the workflow is kept (differs)" || bad "[I] …the workflow is not kept"
cmp -s "$R2/.vibemaestro/gates/kb.py" "$PLUGIN/scripts/kb.py" && bad "[I] kb.py was overwritten without --update" || ok "[I] …kb.py is kept without --update"
install "$R2" --only kb-check --update
want 0 "[I] --update"; has_q "replaced" && ok "[I] …replaced is printed" || bad "[I] …nothing replaced"
cmp -s "$R2/.vibemaestro/gates/kb.py" "$PLUGIN/scripts/kb.py" && ok "[I] …kb.py is the plugin's again" || bad "[I] …kb.py is still the old one"
grep -q '^# mine' "$R2/.github/workflows/kb-check.yml" && ok "[I] …the edited workflow is still the person's" || bad "[I] …the workflow was overwritten"
# a repo onboarded by an older kit keeps its own config loader and message table: the pin describes what is on disk, and a WARNING says the set mixes versions
R5=$(mkrepo); install "$R5"; printf '# older kit\n' >> "$R5/.vibemaestro/gates/messages.py"   # not a break: the older kit's copy, an input of this case
install "$R5" --only kb-check
want 0 "[I] a kept message table that differs: rc 0" "WARNING kb-check: 1 file(s) of its set are kept and differ"
pin_ok "$R5" && ok "[I] …the pin hashes the files as they are on disk" || bad "[I] …the pin hashes bytes the repo does not hold"
eq "$(sed -n 1p "$R5/.vibemaestro/gates/kb-check.pin")" "kit: -" "[I] …and its kit line is - (the set no longer comes from one commit)"
# a plain --update on a repo that has the gate brings the gate's set and pin along with the config loader and the message table
R6=$(mkrepo); install "$R6" --only kb-check; printf '# old\n' >> "$R6/.vibemaestro/gates/kb.py"; printf '# old\n' >> "$R6/.vibemaestro/gates/messages.py"   # not a break: an older kit's copies
install "$R6" --update
want 0 "[I] --update with no --only on a repo that has kb-check"
cmp -s "$R6/.vibemaestro/gates/kb.py" "$PLUGIN/scripts/kb.py" && ok "[I] …kb.py is the plugin's again, not left behind" || bad "[I] …kb.py stayed old while messages.py was replaced"
pin_ok "$R6" && ok "[I] …and the pin describes the set now on disk" || bad "[I] …the pin is stale"
R8=$(mkrepo); install "$R8" --only kb-check,pr-title; printf '# old\n' >> "$R8/.vibemaestro/gates/kb.py"; printf '# old\n' >> "$R8/.vibemaestro/gates/messages.py"   # not a break: an older kit's copies
install "$R8" --update --only pr-title
cmp -s "$R8/.vibemaestro/gates/kb.py" "$PLUGIN/scripts/kb.py" && pin_ok "$R8" && ok "[I] --update --only <another gate> on a repo that has kb-check: its set and pin come along" || bad "[I] --update --only pr-title left kb.py or the pin behind messages.py"
rm "$R8/.github/workflows/kb-check.yml"; install "$R8" --update; [ -e "$R8/.github/workflows/kb-check.yml" ] && bad "[I] --update wrote the workflow again after a person removed it" || ok "[I] a person who removed kb-check.yml is not given it back by --update"
R7=$(mkrepo); install "$R7"; install "$R7" --update; [ -e "$R7/.vibemaestro/gates/kb.py" ] && bad "[I] --update installed kb-check in a repo that never asked" || ok "[I] --update on a repo without kb-check does not add it"
# language en: the config loader and the message table are English-only as for every gate; the 10 modules are the kit's own and still run
R3=$(mkrepo); put_cfg "$R3" '{"language": "en"}'; install "$R3" --only kb-check
want 0 "[I] language en: --only kb-check"
LC_ALL=C.UTF-8 python3 - "$R3" <<'PY' && ok "[I] …sdlc_config.py and messages.py hold no Vietnamese letter" || bad "[I] …a Vietnamese letter is left in the en copies"
import re, sys
for n in ("sdlc_config.py", "messages.py"):
    assert not re.search("[À-ỹ]", open("%s/.vibemaestro/gates/%s" % (sys.argv[1], n), encoding="utf-8").read()), n
PY
RC=0; OUT=$(cd "$R3" && cenv python3 -B -I .vibemaestro/gates/kb.py check 2>&1) || RC=$?
want 0 "[I] …and the vendored kb.py runs there" "lifecycle ok"
R4=$(mkrepo); install "$R4" --only nope; want 64 "[I] an unknown gate name is still refused"

echo "== [R] the run block, on scratch repos =="
python3 - "$WF" "$TMP/run.sh" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
open(sys.argv[2], "w", encoding="utf-8").write([s for s in d["jobs"]["kb-check"]["steps"] if "run" in s][0]["run"])
PY
[ -s "$TMP/run.sh" ] && ok "[R] the run block of the rendered workflow is extracted" || bad "[R] no run block"

story_files() {  # story_files <repo> — a story with three AC, its spec, and nothing else of kb/ (built here, not copied from the kit)
  mkdir -p "$1/kb/intent" "$1/kb/specs" "$1/kb/plans"
  cat > "$1/kb/intent/2026-11-12-v.md" <<'EOF'
---
type: story
focus: P1
spec: kb/specs/2026-11-12-v.md
description: "fixture"
---

# fixture

*Ghi lại bằng lời người đặt — 2026-11-12.*

### Story: anh duyệt một story ngắn
*Loại: story · Trọng tâm: P1*

**Là** chủ của đội, **tôi muốn** duyệt bằng một story ngắn, **để** tôi duyệt nhanh.

**Bối cảnh.** Spec dài, review nhiều vòng.

**Tiêu chí chấp nhận (AC)**

*Story (anh đọc)*
1. Khi có việc, thì anh nhận một story ngắn.
2. Khi viết mới, thì nội dung kb là tiếng Việt.

*Spec*
3. Khi có AC, thì nó có tiêu chí trỏ về nó.

**Không làm**
- Không dịch kb cũ.

**Khẩu phần.** Khoảng 1 ngày.

**Lời người hỏi → AC**

| Lời người hỏi | AC |
|---|---|
| “duyệt bằng một story ngắn” | AC1 |
| “kb viết tiếng Việt, có tiêu chí” | AC2, AC3 |
EOF
  cat > "$1/kb/specs/2026-11-12-v.md" <<'EOF'
---
description: "fixture"
---

# fixture

Intent: kb/intent/2026-11-12-v.md

## Mục tiêu

1. Anh duyệt nhanh một story ngắn. → AC1, AC2, AC3

## Ràng buộc

- Không thêm phụ thuộc.

## Tiêu chí chấp nhận

1. Khi có việc, thì anh nhận một story ngắn. → AC1
2. Khi máy kiểm đọc story, thì nó đọc AC theo số anh viết. → AC2, AC3

## Rủi ro cần test phủ

1. Story bị đỏ nhầm.

## Cần làm rõ

Không có.
EOF
}
plan_file() {  # plan_file <repo> <header cells after Row> <row cells after A> — kb/plans/2026-11-12-v.md, a lean plan of one row
  mkdir -p "$1/kb/plans"
  { printf -- '---\ndescription: "fixture"\nfocus: P1\n---\n\n# Plan\n\nIntent: kb/intent/2026-11-12-v.md · Spec: kb/specs/2026-11-12-v.md\n\n'
    printf '| Row | %s |\n|---|---|\n| A | %s |\n' "$2" "$3"; } > "$1/kb/plans/2026-11-12-v.md"
}
LH='Title | How | Delivers (AC) | Depends on | Trust touches | Link'; LR=' | x | AC1, AC2, AC3 | — | none | —'
T80=$(printf 'a%.0s' $(seq 80))

# base_repo <name> [install args…] — a bare origin and a clone on main: a story and a spec, the gate installed (or not), one commit pushed
base_repo() {
  local name=$1; shift
  local d; d=$(mk_origin "$name") || return 1
  story_files "$d"
  if [ "$#" -gt 0 ]; then cenv python3 "$INSTALL" --root "$d" "$@" >/dev/null 2>&1; fi
  G -C "$d" add -A; G -C "$d" commit -qm base; G -C "$d" push -q origin main
  echo "$d"
}
# pr_run <base clone> — what GitHub Actions does for the PR whose head is the current branch of the clone: the head is published as
# refs/pull/1/head, a fresh clone of the origin is checked out at main (checkout of the base), and the block runs there. OUT and RC.
pr_run() {
  local w=$1 sha; sha=$(G -C "$w" rev-parse HEAD)
  G -C "$w" push -q -f origin "HEAD:refs/pull/1/head"
  local run base=${PR_BASE:-main}; run=$(fresh); G clone -q "$(dirname "$w")/origin.git" "$run/c" 2>/dev/null; G -C "$run/c" checkout -q "$base"
  G -C "$run/c" remote set-head origin -d >/dev/null   # actions/checkout leaves no origin/HEAD; a clone does
  RC=0; OUT=$(cd "$run/c" && capped cenv PR_NUMBER=1 BASE_REF="$base" HEAD_SHA="$sha" RUNNER_TEMP="$run" bash "$TMP/run.sh" 2>&1) || RC=$?
  G -C "$w" checkout -q "$base"
}
pr_branch() { G -C "$1" checkout -q -B "pr-$2" main; }
pr_commit() { G -C "$1" add -A; G -C "$1" commit -qm "$2"; }

W=$(base_repo gate --only kb-check)
commit_cfg "$W" '{"schema": 1}' "base config"; G -C "$W" push -q origin main   # the base has a config for the run block to restore
pr_branch "$W" notitle; plan_file "$W" 'How | Delivers (AC) | Depends on | Trust touches | Link' 'x | AC1, AC2, AC3 | — | none | —'; pr_commit "$W" notitle
(cd "$W" && cenv python3 -B -I .vibemaestro/gates/kb.py check >/dev/null 2>&1); eq "$?" 0 "[R] the bare kb.py check is green on a story plan with no Title column (it judges the documents' life, not the plan's trace)"
RC=0; OUT=$(cd "$W" && capped cenv python3 -B -I .vibemaestro/gates/kb.py check links --base origin/main 2>&1) || RC=$?
eq "$RC" 65 "[R] …and kb.py check links is red on it"
pr_run "$W"; eq "$RC" 65 "[R] a Title-less story plan: the step is red (rc 65)"; has "$OUT" "no Title column" "[R] …and says 'no Title column'"

pr_branch "$W" ok; plan_file "$W" "$LH" "A short outcome${LR}"; pr_commit "$W" ok
pr_run "$W"; eq "$RC" 0 "[R] the same plan with a valid Title: green"; has "$OUT" "links: 0 failing" "[R] …check links ran and found nothing"
pr_branch "$W" t80; plan_file "$W" "$LH" "${T80}${LR}"; pr_commit "$W" t80
pr_run "$W"; eq "$RC" 0 "[R] a Title of exactly 80 characters: green"
pr_branch "$W" empty; plan_file "$W" "$LH" " ${LR}"; pr_commit "$W" empty
pr_run "$W"; eq "$RC" 65 "[R] an empty Title: red"; has "$OUT" "has an empty Title" "[R] …named"
pr_branch "$W" t81; plan_file "$W" "$LH" "${T80}a${LR}"; pr_commit "$W" t81
pr_run "$W"; eq "$RC" 65 "[R] a Title of 81 characters: red"; has "$OUT" "has a Title over 80 characters" "[R] …named"
pr_branch "$W" tick; plan_file "$W" "$LH" 'Edit `kb.py`'"${LR}"; pr_commit "$W" tick
pr_run "$W"; eq "$RC" 65 "[R] a Title with a backtick: red"; has "$OUT" "has a backtick in its Title" "[R] …named"
pr_branch "$W" nokb; mkdir -p "$W/src"; echo x > "$W/src/a.txt"; pr_commit "$W" nokb
pr_run "$W"; eq "$RC" 0 "[R] a PR that touches no kb file: green"

# the PR is judged by the base's copy: a head that swaps in its own kb.py, or its own config, does not change the verdict
pr_branch "$W" selfcheck; plan_file "$W" 'How | Delivers (AC) | Depends on | Trust touches | Link' 'x | AC1, AC2, AC3 | — | none | —'
printf 'import sys\nsys.exit(0)\n' > "$W/.vibemaestro/gates/kb.py"   # not a break: the PR's own input, a gate that passes everything
pr_commit "$W" selfcheck; pr_run "$W"; eq "$RC" 65 "[R] a Title-less plan on a PR that replaces kb.py with a no-op: still red (the base's copy ran)"
pr_branch "$W" selfcfg; plan_file "$W" 'How | Delivers (AC) | Depends on | Trust touches | Link' 'x | AC1, AC2, AC3 | — | none | —'
mkdir -p "$W/.vibemaestro"; printf '{"schema": 1, "kb": {"intent_max_bytes": 1}}' > "$W/.vibemaestro/sdlc.json"   # not a break: the PR's own config
pr_commit "$W" selfcfg; pr_run "$W"; eq "$RC" 65 "[R] …and a PR that rewrites .vibemaestro/sdlc.json is judged by the base's config (red on the plan, not on its own limit)"
has "$OUT" "no Title column" "[R] …the verdict is the plan's"

# the PR's .vibemaestro/sdlc.json is a link to a file outside the checkout: the base's config is restored without writing through it
pr_branch "$W" link; plan_file "$W" "$LH" "A short outcome${LR}"; echo keep > "$TMP/outside.txt"
rm -f "$W/.vibemaestro/sdlc.json"; ln -s "$TMP/outside.txt" "$W/.vibemaestro/sdlc.json"; pr_commit "$W" link   # not a break: the PR's own input, a linked config
pr_run "$W"; eq "$(cat "$TMP/outside.txt")" keep "[R] a PR whose sdlc.json is a link to a file outside the checkout: that file is not written"
eq "$RC" 0 "[R] …and the run itself is green on a valid plan"
G -C "$W" checkout -q -f main; G -C "$W" clean -fdq
pr_branch "$W" linkdir; plan_file "$W" "$LH" "A short outcome${LR}"; mkdir -p "$TMP/outdir"; echo keep > "$TMP/outdir/sdlc.json"
G -C "$W" rm -rq --cached .vibemaestro; rm -rf "$W/.vibemaestro"; ln -s "$TMP/outdir" "$W/.vibemaestro"; pr_commit "$W" linkdir   # not a break: the PR's own input, a linked directory
pr_run "$W"; eq "$(cat "$TMP/outdir/sdlc.json")" keep "[R] a PR whose .vibemaestro is a link to a directory outside the checkout: nothing is written there"
G -C "$W" checkout -q -f main; G -C "$W" clean -fdq

# a base that is not main: a bare check finds its base through origin/HEAD, so the step points it at the PR's base (a size limit judged only against a base).
# A base named pr-head must not be overwritten by the fetch of the PR's own head.
size_case() {  # size_case <base branch name>
  local b=$1 WS; WS=$(mk_origin "size-$1"); story_files "$WS"; put_cfg "$WS" '{"schema": 1, "kb": {"spec_max_bytes": 3000}}'
  cenv python3 "$INSTALL" --root "$WS" --only kb-check >/dev/null 2>&1
  G -C "$WS" add -A; G -C "$WS" commit -qm base; G -C "$WS" push -q origin "main:$b"
  G -C "$(dirname "$WS")/origin.git" symbolic-ref HEAD "refs/heads/$b"
  G -C "$WS" push -q origin :main; G -C "$WS" fetch -q -p origin; G -C "$WS" checkout -q -B "$b" "origin/$b"; G -C "$WS" branch -D main -q
  G -C "$WS" checkout -q -B pr-size "$b"; head -c 4000 /dev/zero | tr '\0' 'x' | fold -w 100 >> "$WS/kb/specs/2026-11-12-v.md"; pr_commit "$WS" grow
  PR_BASE=$b pr_run "$WS"; eq "$RC" 65 "[R] a base named $b: a spec grown past kb.spec_max_bytes is red (the size check needs the right base)"; has "$OUT" "spec_max_bytes" "[R] …the limit is named"
}
size_case master
size_case pr-head

# a base that has no vendored kb.py (the PR that adopts the gates): a warning and rc 0, whatever the PR holds
WB=$(base_repo bare)
pr_branch "$WB" adopt; plan_file "$WB" 'How | Delivers (AC) | Depends on | Trust touches | Link' 'x | AC1, AC2, AC3 | — | none | —'; pr_commit "$WB" adopt
pr_run "$WB"; eq "$RC" 0 "[R] a base with no vendored kb.py: rc 0"; has "$OUT" "::warning::the kb-check gate is not installed on the base branch yet" "[R] …with a warning"
# the set must be whole: a base copy that lacks a module the check imports is red, not green
WM=$(base_repo broken --only kb-check)
G -C "$WM" rm -q .vibemaestro/gates/vsdlc.py; G -C "$WM" commit -qm "drop a module"; G -C "$WM" push -q origin main   # not a break: builds the base of this case
pr_branch "$WM" nomod; plan_file "$WM" "$LH" "A short outcome${LR}"; pr_commit "$WM" nomod
pr_run "$WM"; ne "$RC" 0 "[R] a base copy missing a module of the closure: the step is red (never a silent green)"

summary
