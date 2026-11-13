#!/bin/bash
# =============================================================================
# Gate signing-rules (plugins/vibemaestro-sdlc/gates/signing_rules.py): a PR that changes who signs is an owner merge
# =============================================================================
# Run: bash tests/test-signing-rules.sh
#
# A scratch repository holds a seeded base: two batons, a kind, a small baton.py and sdlc_config.py with every name of the gate's
# default list, and a --list file of its own. Each case is a branch off the base whose head the test writes, then the gate judges
# `base HEAD`. Families:
#   [S] Stops: a change as stops_of parses it is red and names both values; a reorder, the Purpose line or the body is green
#   [A] baton directories: an added file (a symlink, a rename, an odd name, a nested one) is red; a delete is green
#   [L] named lists: an edit, a split line, an indirect value, a mutation or a re-binding anywhere, a string-named store, a removal
#       are red; a call site is green
#   [G] the gate and its list: its files are red; --list is read at the base, so a head that edits the list is judged by the old one
#   [E] cannot judge: a file that does not parse is red; a name absent at the base tip or a bad --list is rc 65 (or 64); a bad rev rc 2
#   [M] what lands, the head merged into the base tip: a change main made after the branch was cut is not the PR's; a helper the
#       branch changes under a name main added is; a conflict or a git without merge-tree --write-tree is rc 2
#   [T] --touches: the block the merge guard reads, `baton` with the head's Stops or `other` per cause, then `end <n>`; `end 0` when
#       green; no block when it cannot conclude
#   [K] the kit's own tree: every default name is found
# Every run that must be red goes through `capped`. Real git on a throw-away repository; no network.
# =============================================================================
set -uo pipefail
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC_ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
# shellcheck source=fixtures/lib.sh
. "$HERE/fixtures/lib.sh"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
export PYTHONDONTWRITEBYTECODE=1
GATE="$SRC_ROOT/plugins/vibemaestro-sdlc/gates/signing_rules.py"
R="$TMP/repo"
SD=plugins/vibemaestro-sdlc
BP="$SD/scripts/baton.py"

g() { git -C "$R" -c user.name=t -c user.email=t@example.invalid "$@"; }
commit() { g add -A && g commit -q -m "$1"; }
gate() { python3 "$GATE" "$@" --cwd "$R"; }
# br <name>: a fresh branch off the base, for one case's head
br() { g checkout -q -B "$1" base; }
put() { mkdir -p "$(dirname "$R/$1")"; printf '%b' "$2" > "$R/$1"; }
baton() { printf '#!/usr/bin/env bash\n# Purpose: %s\n# Stops: %s\necho %s\n' "$1" "$2" "${3:-hi}"; }
# baton_py [<extra lines appended>] [<SIGN_AGAIN_STOPS value>] [<_WORDS value>]: the seeded baton.py, with every default name (and
# the grant limits an older baton.py held, off the default list)
baton_py() {
  cat <<EOF
import re
HEADER_FIELDS = ("Purpose", "Stops")
OPTIONAL_FIELDS = ()
HEADER_LINE = re.compile(r"^# *([A-Z][a-z]+): *(.*)\$")
_WORDS = ${3:-("secrets", "publish")}
STOP_WORDS = _WORDS + ("owner-acts",)
GRANT_LIFE_MAX = 7 * 24 * 3600
GRANT_STEPS_MAX = GRANT_RUNS_MAX = GRANT_ENUM_MAX = 20
APPROVAL_LIFE_MAX = 30 * 24 * 3600
CHARTER_LIFE_MAX = 90 * 24 * 3600
CHARTER_KINDS = ("baton", "workflow", "script", "test")
SIGN_AGAIN_STOPS = ${2:-("security-boundary", "irreversible-delete", "no-way-back", "history-rewrite")}
PLAN_SECRETS_KITS = ("vault-put-text", "script-run")
PLUGIN_ROOT = "plugins/vibemaestro-sdlc"
KIT_ROOT = PLUGIN_ROOT + "/batons"
KINDS_DIR = KINDS_REAL = PLUGIN_ROOT + "/templates/baton-kinds"


def parse_header(lines):
    return [HEADER_LINE.match(x) for x in lines if x.split(":")[0].lstrip("# ") in HEADER_FIELDS + OPTIONAL_FIELDS]


def stops_of(text):
    return parse_header(text.splitlines())


def allowed(word):
    return word in STOP_WORDS
EOF
  [ -n "${1:-}" ] && printf '%b' "$1"
  return 0
}

mkdir -p "$R"; git -C "$R" init -q -b main
put "$SD/batons/merge.sh" "$(baton 'merge one PR' secrets)\n"
put "$SD/batons/pub.sh" "$(baton 'post a note' 'publish, secrets')\n"
put "$SD/templates/baton-kinds/kind.sh" "$(baton 'a kind' none)\n"
put "$BP" "$(baton_py)\n"
put "$SD/scripts/sdlc_config.py" 'MERGE_DENY_DEFAULT = (".github/workflows/**", "**/*secret*")\n'
put "$SD/gates/signing_rules.py" '# the scratch repository'"'"'s copy of the gate path\n'
put "$SD/scripts/kb_plan.py" 'TOUCH_KINDS = ("script", "baton")\nTOUCH_OBJECT_KINDS = ("rbac",)\nTOUCH_JUDGES = (".vibemaestro/sdlc.json",)\nTOUCH_JUDGE_DIRS = (".vibemaestro/gates/",)\n\n\ndef parse_touches(cell, repo):\n    return [], []\n\n\ndef touch_kind(path):\n    return "other"\n\n\ndef judges(cfg):\n    return set(TOUCH_JUDGES)\n\n\ndef is_judge(path, judged):\n    return path in judged or path.startswith(TOUCH_JUDGE_DIRS)\n'
put "rules.json" '{"baton_dirs": ["ops"], "lists": {"lib/r.py": ["GRANT_NEVER"]}, "files": []}\n'
put "lib/r.py" 'GRANT_NEVER = ("history-rewrite",)\n'
put README.md 'seed\n'
commit base; g tag base

echo "== [B] the seeded base: green, every default name found =="
br b-readme; put README.md 'seed, edited\n'; commit readme
O=$(gate base HEAD); rc=$?
eq "$rc" 0 "[B] a README edit: rc 0"
eq "$O" "signing-rules: green (20 names, 0 baton files changed)" "[B] …the green line names 20 names"

echo "== [S] Stops as stops_of parses them =="
br s-none; put "$SD/batons/merge.sh" "$(baton 'merge one PR' none)\n"; commit s
O=$(capped gate base HEAD); rc=$?
eq "$rc" 1 "[S] Stops: secrets → none: rc 1"
eq "$O" "RED $SD/batons/merge.sh: Stops 'secrets' → 'none'
signing-rules: red, an owner merge (1 cause)" "[S] …one line names the path and both values"

br s-gone; put "$SD/batons/merge.sh" '#!/usr/bin/env bash\n# Purpose: merge one PR\necho hi\n'; commit s
O=$(capped gate base HEAD); rc=$?
eq "$rc" 1 "[S] the Stops line removed: rc 1"
has "$O" "RED $SD/batons/merge.sh: Stops 'secrets' → None" "[S] …named as None"

br s-case; put "$SD/batons/merge.sh" "$(baton 'merge one PR' Secrets)\n"; commit s
O=$(capped gate base HEAD); rc=$?
eq "$rc" 1 "[S] Stops: Secrets (an unknown word): rc 1"
has "$O" "Stops 'secrets' → 'Secrets'" "[S] …both spellings named"

br s-order; put "$SD/batons/pub.sh" "$(baton 'post a note' 'secrets,publish')\n"; commit s
O=$(gate base HEAD); rc=$?
eq "$rc" 0 "[S] Stops reordered and respaced (publish, secrets → secrets,publish): rc 0"
eq "$O" "signing-rules: green (20 names, 1 baton file changed)" "[S] …the baton file counted"

br s-purpose; put "$SD/batons/merge.sh" "$(baton 'merge one PR after its checks' secrets 'merged')\n"; commit s
O=$(gate base HEAD); rc=$?
eq "$rc" 0 "[S] the Purpose line and the body edited, Stops kept: rc 0"

echo "== [A] files under a baton directory =="
br a-new; put "$SD/batons/new.sh" "$(baton 'new' none)\n"; commit a
O=$(capped gate base HEAD); rc=$?
eq "$rc" 1 "[A] a new baton under batons/: rc 1"
eq "$O" "RED $SD/batons/new.sh: a new file under a baton directory
signing-rules: red, an owner merge (1 cause)" "[A] …named"

br a-kind; put "$SD/templates/baton-kinds/k2.sh" "$(baton 'k2' none)\n"; commit a
O=$(capped gate base HEAD); rc=$?
eq "$rc" 1 "[A] a new file under templates/baton-kinds/: rc 1"
has "$O" "RED $SD/templates/baton-kinds/k2.sh: a new file under a baton directory" "[A] …named"

br a-link; ln -s merge.sh "$R/$SD/batons/alias.sh"; commit a
O=$(capped gate base HEAD); rc=$?
eq "$rc" 1 "[A] a symlink added under batons/: rc 1"
has "$O" "RED $SD/batons/alias.sh: a symlink added: it can stand in for a baton directory" "[A] …named"

br a-dirlink; g mv "$SD/batons" "$SD/kitz"; ln -s kitz "$R/$SD/batons"; put "$SD/kitz/merge.sh" "$(baton 'merge one PR' none)\n"; commit a
O=$(capped gate base HEAD); rc=$?
eq "$rc" 1 "[A] batons/ moved aside and replaced by a symlink to it, a Stops dropped inside: rc 1"
eq "$O" "RED $SD/batons: a symlink added: it can stand in for a baton directory
signing-rules: red, an owner merge (1 cause)" "[A] …the symlink named"

br a-treelink; g mv "$SD/templates" "$SD/t2"; ln -s t2 "$R/$SD/templates"; commit a
O=$(capped gate base HEAD); rc=$?
eq "$rc" 1 "[A] templates/ (holding baton-kinds/) replaced by a symlink: rc 1"
has "$O" "RED $SD/templates: a symlink added" "[A] …named"

br a-case; put "$SD/Batons/setup.sh" "$(baton 'setup' none)\n"; commit a
O=$(capped gate base HEAD); rc=$?
eq "$rc" 1 "[A] a file added under Batons/ (a case-insensitive checkout merges it into batons/): rc 1"
has "$O" "RED $SD/Batons/setup.sh: a new file under a baton directory" "[A] …named"

br a-mv; g mv "$SD/batons/merge.sh" "$SD/batons/merge2.sh"; commit a
O=$(capped gate base HEAD); rc=$?
eq "$rc" 1 "[A] a baton renamed: rc 1 (the new name is an added file)"
eq "$O" "RED $SD/batons/merge2.sh: a new file under a baton directory
signing-rules: red, an owner merge (1 cause)" "[A] …only the new name: the old one is a delete"

br a-odd; put "$SD/batons/my bä.sh" "$(baton 'odd' none)\n"; put "$SD/batons/nl
x.sh" "$(baton 'nl' none)\n"; commit a
O=$(capped gate base HEAD); rc=$?
eq "$rc" 1 "[A] a name with a space and unicode, and one with a newline: rc 1"
has "$O" "RED $SD/batons/my bä.sh: a new file under a baton directory" "[A] …the space and unicode name as it is"
has "$O" "RED $SD/batons/nl
x.sh: a new file under a baton directory" "[A] …the newline name as it is"
has "$O" "(2 causes)" "[A] …two causes"

br a-deep; put "$SD/batons/sub/x.sh" "$(baton 'deep' none)\n"; put "other/place/batons/y.sh" "$(baton 'y' none)\n"; commit a
O=$(capped gate base HEAD); rc=$?
eq "$rc" 1 "[A] a nested file under batons/, and a batons/ directory elsewhere: rc 1"
has "$O" "(2 causes)" "[A] …both"

br a-moved; g mv "$SD/batons" "$SD/kitz"; put "$BP" "$(baton_py | sed 's#^KIT_ROOT = .*#KIT_ROOT = PLUGIN_ROOT + "/kitz"#')\n"
put "$SD/kitz/merge.sh" "$(baton 'merge one PR' none)\n"; commit a
O=$(capped gate base HEAD); rc=$?
eq "$rc" 1 "[A] batons/ moved by git mv, KIT_ROOT pointed at it and a Stops dropped inside: rc 1"
eq "$O" "RED $BP: KIT_ROOT changed (it decides who signs)
signing-rules: red, an owner merge (1 cause)" "[A] …the path constant named (the moved files are a delete and an add outside a baton directory)"

br a-del; g rm -q "$SD/batons/merge.sh"; commit a
O=$(gate base HEAD); rc=$?
eq "$rc" 0 "[A] a baton deleted: rc 0"

echo "== [L] the named lists =="
br l-never; put "$BP" "$(baton_py '' '("history-rewrite",)')\n"; commit l
O=$(capped gate base HEAD); rc=$?
eq "$rc" 1 "[L] SIGN_AGAIN_STOPS edited: rc 1"
eq "$O" "RED $BP: SIGN_AGAIN_STOPS changed (it decides who signs)
signing-rules: red, an owner merge (1 cause)" "[L] …named"

br l-split; put "$BP" "$(baton_py | grep -v '^KINDS_DIR = ')
KINDS_DIR = PLUGIN_ROOT + \"/templates/baton-kinds\"
KINDS_REAL = PLUGIN_ROOT + \"/templates/elsewhere\"\n"; commit l
O=$(capped gate base HEAD); rc=$?
eq "$rc" 1 "[L] KINDS_REAL split off its shared line and pointed elsewhere: rc 1"
has "$O" "RED $BP: KINDS_REAL changed" "[L] …KINDS_REAL named"

br l-off; put "$BP" "$(baton_py | sed -e 's/^GRANT_LIFE_MAX = .*/GRANT_LIFE_MAX = 70 * 24 * 3600/' \
  -e 's/^GRANT_STEPS_MAX = .*/GRANT_STEPS_MAX = GRANT_RUNS_MAX = 20\nGRANT_ENUM_MAX = 21/')\n"; commit l
O=$(gate base HEAD); rc=$?
eq "$rc" 0 "[L] the grant limits, off the default list: GRANT_LIFE_MAX raised and GRANT_ENUM_MAX split off and raised: rc 0"
hasnt "$O" "GRANT_" "[L] …no grant limit named"

br l-deny; put "$SD/scripts/sdlc_config.py" 'MERGE_DENY_DEFAULT = (".github/workflows/**",)\n'; commit l
O=$(capped gate base HEAD); rc=$?
eq "$rc" 1 "[L] MERGE_DENY_DEFAULT edited: rc 1"
has "$O" "RED $SD/scripts/sdlc_config.py: MERGE_DENY_DEFAULT changed" "[L] …named"

br l-indirect; put "$BP" "$(baton_py '' '' '("secrets",)')\n"; commit l
O=$(capped gate base HEAD); rc=$?
eq "$rc" 1 "[L] STOP_WORDS = _WORDS + …, and only _WORDS edited: rc 1"
eq "$O" "RED $BP: STOP_WORDS changed (it decides who signs)
signing-rules: red, an owner merge (1 cause)" "[L] …STOP_WORDS named through the name it reads"

br l-pop; put "$BP" "$(baton_py '\n\ndef relax():\n    PLAN_SECRETS_KITS.pop("plugin-update")\n')\n"; commit l
O=$(capped gate base HEAD); rc=$?
eq "$rc" 1 "[L] PLAN_SECRETS_KITS.pop(…) added in a function: rc 1"
has "$O" "RED $BP: PLAN_SECRETS_KITS changed" "[L] …named"

br l-global; put "$BP" "$(baton_py '\n\ndef relax():\n    global STOP_WORDS\n    STOP_WORDS = ()\n')\n"; commit l
O=$(capped gate base HEAD); rc=$?
eq "$rc" 1 "[L] STOP_WORDS = () in a function with global: rc 1"
has "$O" "RED $BP: STOP_WORDS changed" "[L] …named"

br l-import; put "$BP" "$(baton_py '\nfrom os import sep as APPROVAL_LIFE_MAX\n')\n"; commit l
O=$(capped gate base HEAD); rc=$?
eq "$rc" 1 "[L] APPROVAL_LIFE_MAX re-bound by an import after its line: rc 1"
has "$O" "RED $BP: APPROVAL_LIFE_MAX changed" "[L] …named"

br l-charter; put "$BP" "$(baton_py '\nCHARTER_KINDS = CHARTER_KINDS + ("config",)\n')\n"; commit l
O=$(capped gate base HEAD); rc=$?
eq "$rc" 1 "[L] CHARTER_KINDS widened to config after its line: rc 1"
has "$O" "RED $BP: CHARTER_KINDS changed" "[L] …named"

br l-string; put "$BP" "$(baton_py '\nglobals()["SIGN_AGAIN_STOPS"] = ()\n')\n"; commit l
O=$(capped gate base HEAD); rc=$?
eq "$rc" 1 "[L] globals()[\"SIGN_AGAIN_STOPS\"] = (): rc 1"
has "$O" "RED $BP: SIGN_AGAIN_STOPS changed" "[L] …named"

for case in 'update|globals().update(STOP_WORDS=("publish",), SIGN_AGAIN_STOPS=())|STOP_WORDS' \
            'concat|globals()["STOP_" + "WORDS"] = ()|STOP_WORDS' \
            'exec|exec("SIGN_AGAIN_STOPS = ()")|SIGN_AGAIN_STOPS' \
            'modules|import sys\nsys.modules[__name__].SIGN_AGAIN_STOPS = ()|SIGN_AGAIN_STOPS' \
            'unbound|dict.clear(PLAN_SECRETS_KITS)|PLAN_SECRETS_KITS' \
            'alias|_k = PLAN_SECRETS_KITS\n_k.clear()|PLAN_SECRETS_KITS' \
            'getattr|getattr(PLAN_SECRETS_KITS, "clear")()|PLAN_SECRETS_KITS' \
            'helper|def _tidy(d):\n    d.pop("plugin-update", None)\n_tidy(PLAN_SECRETS_KITS)|PLAN_SECRETS_KITS' \
            'bound|_drop = PLAN_SECRETS_KITS.clear\n_drop()|PLAN_SECRETS_KITS' \
            'attr|parse_header.__defaults__ = ()|parse_header' \
            'init|PLAN_SECRETS_KITS.__init__({"plugin-update": "x", "foo": "bar"})|PLAN_SECRETS_KITS'; do
  IFS='|' read -r name code want <<< "$case"
  br "l-$name"; put "$BP" "$(baton_py "\n$code\n")\n"; commit l
  O=$(capped gate base HEAD); rc=$?
  eq "$rc" 1 "[L] reached without its own line ($name): rc 1"
  has "$O" "RED $BP: $want changed" "[L] …$name: $want named"
done

g checkout -q -B l-iftop-base base; put "$BP" "$(baton_py | grep -v '^_WORDS = ')\nif True:\n    _WORDS = (\"secrets\", \"publish\")\n"; commit l0
g checkout -q -B l-iftop l-iftop-base; put "$BP" "$(baton_py | grep -v '^_WORDS = ')\nif True:\n    _WORDS = (\"secrets\",)\n"; commit l
O=$(capped gate l-iftop-base l-iftop); rc=$?
eq "$rc" 1 "[L] STOP_WORDS built from a name defined under a top-level if, and only that name edited: rc 1"
has "$O" "RED $BP: STOP_WORDS changed" "[L] …STOP_WORDS named"

br l-gone; put "$BP" "$(baton_py | grep -v '^SIGN_AGAIN_STOPS =')\n"; commit l
O=$(capped gate base HEAD); rc=$?
eq "$rc" 1 "[L] SIGN_AGAIN_STOPS removed: rc 1"
has "$O" "RED $BP: SIGN_AGAIN_STOPS changed" "[L] …named"

br l-parser; put "$BP" "$(baton_py | sed 's/^OPTIONAL_FIELDS = ()/OPTIONAL_FIELDS = ("Params",)/')\n"; commit l
O=$(capped gate base HEAD); rc=$?
eq "$rc" 1 "[L] a constant parse_header reads edited: rc 1"
has "$O" "RED $BP: parse_header changed" "[L] …parse_header named"
has "$O" "RED $BP: stops_of changed" "[L] …and stops_of, which calls it"

br l-call; put "$BP" "$(baton_py | sed 's/return word in STOP_WORDS/return word not in STOP_WORDS/')\n\n\ndef other(k):\n    if len(STOP_WORDS) and STOP_WORDS[0] and PLAN_SECRETS_KITS.get(k):\n        return sorted(STOP_WORDS), \", \".join(SIGN_AGAIN_STOPS), \"%s\" % (APPROVAL_LIFE_MAX,), stops_of(k), [w for w in STOP_WORDS]\n"; commit l
O=$(gate base HEAD); rc=$?
eq "$rc" 0 "[L] call sites edited and new plain reads added (in, len, [0], .get, sorted, join, %, a call, a loop): rc 0"

echo "== [G] the gate and its list =="
br g-self; put "$SD/gates/signing_rules.py" '# edited\n'; commit g
O=$(capped gate base HEAD); rc=$?
eq "$rc" 1 "[G] the gate's file changed: rc 1"
eq "$O" "RED $SD/gates/signing_rules.py: the gate or its list changed
signing-rules: red, an owner merge (1 cause)" "[G] …named"

br g-job; put ".github/workflows/signing-rules.yml" 'name: x\n'; put "$SD/gates/gate_common.py" '# helper\n'; commit g
O=$(capped gate base HEAD); rc=$?
eq "$rc" 1 "[G] the gate's workflow and its helper gate_common.py added: rc 1"
has "$O" "RED .github/workflows/signing-rules.yml: the gate or its list changed" "[G] …the workflow named"
has "$O" "RED $SD/gates/gate_common.py: the gate or its list changed" "[G] …the helper named"

br g-shadow; put "$SD/gates/baton.py" 'def stops_of(text):\n    return None\n'; commit g
O=$(capped gate base HEAD); rc=$?
eq "$rc" 1 "[G] a baton.py added beside the gate (the copy a vendored gate reads Stops with): rc 1"
eq "$O" "RED $SD/gates/baton.py: the gate or its list changed
signing-rules: red, an owner merge (1 cause)" "[G] …named"

br g-list-ops; put "ops/x.sh" "$(baton 'x' none)\n"; put "$SD/batons/new.sh" "$(baton 'new' none)\n"; commit g
O=$(capped gate base HEAD --list rules.json); rc=$?
eq "$rc" 1 "[G] --list: a file added under its own baton directory: rc 1"
eq "$O" "RED ops/x.sh: a new file under a baton directory
signing-rules: red, an owner merge (1 cause)" "[G] …only its directories count (batons/ is not on that list)"

br g-list-edit; put "lib/r.py" 'GRANT_NEVER = ()\n'; commit g
O=$(capped gate base HEAD --list rules.json); rc=$?
eq "$rc" 1 "[G] --list: a name of its own list edited: rc 1"
has "$O" "RED lib/r.py: GRANT_NEVER changed" "[G] …named"

br g-list-head; put "rules.json" '{"baton_dirs": [], "lists": {}, "files": []}\n'; put "lib/r.py" 'GRANT_NEVER = ()\n'; commit g
O=$(capped gate base HEAD --list rules.json); rc=$?
eq "$rc" 1 "[G] the head empties the list and edits GRANT_NEVER: rc 1, judged by the base list"
eq "$O" "RED rules.json: the gate or its list changed
RED lib/r.py: GRANT_NEVER changed (it decides who signs)
signing-rules: red, an owner merge (2 causes)" "[G] …names the list file and GRANT_NEVER"

br g-list-new; put "rules2.json" '{"baton_dirs": [], "lists": {}, "files": []}\n'; commit g
O=$(capped gate base HEAD --list rules2.json 2>&1); rc=$?
eq "$rc" 65 "[G] a --list file the base does not have: rc 65"
has "$O" "--list rules2.json is not on the base base" "[G] …said"

echo "== [E] what the gate cannot judge =="
br e-parse; put "$BP" "$(baton_py)\ndef broken(:\n"; commit e
O=$(capped gate base HEAD); rc=$?
eq "$rc" 1 "[E] baton.py does not parse in the merged tree: rc 1"
eq "$O" "RED $BP: does not parse at the merged tree (29)
signing-rules: red, an owner merge (1 cause)" "[E] …named, with the line"

br e-parse-base; put "lib/r.py" 'GRANT_NEVER = (\n'; commit e; g tag -f base-parse >/dev/null; put "lib/r.py" 'GRANT_NEVER = ()\n'; commit e2
O=$(capped python3 "$GATE" base-parse HEAD --list rules.json --cwd "$R"); rc=$?
eq "$rc" 1 "[E] a list file that does not parse at the base tip: rc 1"
has "$O" "RED lib/r.py: does not parse at the base tip (1)" "[E] …named, with the line"

for case in 'absent|{"baton_dirs": [], "lists": {"lib/r.py": ["GRANT_NEVER", "NOPE", "NADA"]}, "files": []}|the list names NOPE, NADA in lib/r.py, not found at the base tip base-absent: an invalid list' \
            'nofile|{"baton_dirs": [], "lists": {"lib/missing.py": ["X"]}, "files": []}|the list names lib/missing.py, which is not at the base tip base-nofile: an invalid list'; do
  IFS='|' read -r name json want <<< "$case"
  g checkout -q -B "e-$name" base; put "rules-$name.json" "$json\n"; commit "e-$name"; g tag -f "base-$name" >/dev/null
  O=$(capped python3 "$GATE" "base-$name" HEAD --list "rules-$name.json" --cwd "$R" 2>&1); rc=$?
  eq "$rc" 65 "[E] a listed name absent at the base tip ($name): rc 65, an invalid list"
  eq "$O" "signing-rules: invalid config: $want" "[E] $name: …named"
done

for case in 'key|{"baton_dirs": [], "lists": {}, "files": [], "extra": 1}|exactly the keys' \
            'dotdot|{"baton_dirs": [], "lists": {"../x.py": ["A"]}, "files": []}|is not a relative repository path' \
            'abs|{"baton_dirs": ["/etc"], "lists": {}, "files": []}|baton_dirs must be a list of relative repository paths' \
            'name|{"baton_dirs": [], "lists": {"x.py": ["a-b"]}, "files": []}|must be a non-empty list of Python names' \
            'json|{not json|is not JSON'; do
  IFS='|' read -r name json want <<< "$case"
  g checkout -q -B "v-$name" base; put "bad-$name.json" "$json\n"; commit "v-$name"; g tag -f "base-v-$name" >/dev/null
  O=$(capped python3 "$GATE" "base-v-$name" HEAD --list "bad-$name.json" --cwd "$R" 2>&1); rc=$?
  eq "$rc" 65 "[E] an invalid --list ($name): rc 65"
  has "$O" "$want" "[E] …$name: the reason"
done

O=$(capped gate base HEAD --list /etc/rules.json 2>&1); rc=$?
eq "$rc" 64 "[E] --list with an absolute path: rc 64"
O=$(capped gate base no-such-rev 2>&1); rc=$?
eq "$rc" 2 "[E] an unknown rev: rc 2"
has "$O" "ref \`no-such-rev\` does not read" "[E] …said"
g checkout -q --orphan e-orphan; put "$SD/batons/merge.sh" "$(baton 'merge one PR' none)\n"; commit orphan
O=$(capped gate base HEAD 2>&1); rc=$?
eq "$rc" 2 "[E] a head with no merge base: rc 2, nothing judged"
has "$O" "git merge-tree --write-tree failed (rc 128): fatal: refusing to merge unrelated histories" "[E] …said, the git version not blamed"
hasnt "$O" "signing-rules: green" "[E] …no green line"

echo "== [M] what lands: the head merged into the base tip =="
br m-pr; put README.md 'pr\n'; commit m-pr
g checkout -q -B m-main base; put "$SD/batons/merge.sh" "$(baton 'merge one PR' none)\n"; commit m-main
O=$(gate m-main m-pr); rc=$?
eq "$rc" 0 "[M] main changed a baton's Stops after the PR branched, the PR did not: rc 0"

# a back-merge's case: main adds a listed name NEW, reading the helper _HELP, after the branch point m-point
R_PY='_HELP = 3\n\n\n\nGRANT_NEVER = ("history-rewrite",)\n'
g checkout -q -B m-point base; put lib/r.py "$R_PY"; commit m-point
g checkout -q -B m-new m-point; put lib/r.py "$R_PY"'\n\nNEW = _HELP + 1\n'
put rules-m.json '{"baton_dirs": [], "lists": {"lib/r.py": ["GRANT_NEVER", "NEW"]}, "files": []}\n'; commit m-new
g checkout -q -B m-other m-point; put README.md 'other\n'; commit m-other
O=$(gate m-new m-other --list rules-m.json); rc=$?
eq "$rc" 0 "[M] main added a listed name after the branch point, the branch changed another file: rc 0"
eq "$O" "signing-rules: green (2 names, 0 baton files changed)" "[M] …both names compared"
g checkout -q -B m-helper m-point; put lib/r.py "${R_PY/_HELP = 3/_HELP = 4}"; commit m-helper
O=$(capped gate m-new m-helper --list rules-m.json); rc=$?
eq "$rc" 1 "[M] the branch changed the helper that main's new listed name reads: rc 1"
eq "$O" "RED lib/r.py: NEW changed (it decides who signs)
signing-rules: red, an owner merge (1 cause)" "[M] …the new name named"
g checkout -q -B m-five m-point; put lib/r.py "${R_PY/_HELP = 3/_HELP = 5}"; commit m-five
O=$(capped gate m-five m-helper --list rules.json 2>&1); rc=$?
eq "$rc" 2 "[M] the head conflicts with the base tip (both set _HELP): rc 2"
eq "$O" "signing-rules: could not conclude: the head does not merge cleanly into the base tip (a conflict): merge the base into the branch" "[M] …said"
# a git older than 2.38, whose merge-tree has no --write-tree and exits 129 with its usage
mkdir -p "$TMP/oldgit"
printf '#!/bin/sh\ncase " $* " in *" merge-tree --write-tree "*) echo "usage: git merge-tree <base-tree> <branch1> <branch2>" >&2; exit 129;; esac\nexec "%s" "$@"\n' \
  "$(command -v git)" > "$TMP/oldgit/git"; chmod +x "$TMP/oldgit/git"
O=$(PATH="$TMP/oldgit:$PATH" capped gate m-new m-other --list rules-m.json 2>&1); rc=$?
eq "$rc" 2 "[M] a git without merge-tree --write-tree: rc 2"
eq "$O" "signing-rules: could not conclude: git merge-tree --write-tree failed (rc 129; a git older than 2.38 has no merge-tree --write-tree): usage: git merge-tree <base-tree> <branch1> <branch2>" "[M] …said"

echo "== [T] --touches: the findings block for the merge guard's touches =="
TF="$TMP/touches.txt"
br t-stops; put "$SD/batons/merge.sh" "$(baton 'merge one PR' none)\n"; commit t
O=$(capped gate base HEAD --touches "$TF"); rc=$?
eq "$rc" 1 "[T] a Stops change with --touches: rc 1, as without it"
eq "$(cat "$TF")" 'trust-touches v1
["baton", "'"$SD"'/batons/merge.sh", "-", "none"]
end 1' "[T] …the block: one baton finding with the head's Stops, then end 1"
br t-new; put "$SD/batons/new.sh" "$(baton 'new' 'secrets, publish')\n"; put "$SD/batons/bare.sh" '#!/usr/bin/env bash\necho hi\n'; commit t
capped gate base HEAD --touches "$TF" >/dev/null
eq "$(sed -n 2,4p "$TF")" '["other", "'"$SD"'/batons/bare.sh", "-", "-"]
["baton", "'"$SD"'/batons/new.sh", "-", "publish, secrets"]
end 2' "[T] new batons: baton with the head's Stops; one with no Stops line is other"
br t-list; put "$BP" "$(baton_py '' '("history-rewrite",)')\n"; put "$SD/gates/signing_rules.py" '# edited\n'; commit t
capped gate base HEAD --touches "$TF" >/dev/null
eq "$(sed -n '2,$p' "$TF")" '["other", "'"$SD"'/gates/signing_rules.py", "-", "-"]
["other", "'"$BP"'", "SIGN_AGAIN_STOPS", "-"]
end 2' "[T] a list edit (the name as its object) and the gate's own file: kind other"
br t-green; put README.md 'green\n'; commit t
gate base HEAD --touches "$TF" >/dev/null; rc=$?
eq "$rc/$(cat "$TF")" '0/trust-touches v1
end 0' "[T] a green run writes end 0"
rm -f "$TF"; O=$(capped gate base no-such-rev --touches "$TF" 2>&1); rc=$?
eq "$rc/$([ -e "$TF" ] && echo written || echo none)" "2/none" "[T] a run that cannot conclude writes no block (no end line)"

echo "== [K] the kit's own tree =="
O=$(python3 "$GATE" HEAD HEAD --cwd "$SRC_ROOT"); rc=$?
eq "$rc" 0 "[K] the kit at HEAD: rc 0"
eq "$O" "signing-rules: green (20 names, 0 baton files changed)" "[K] …all 20 default names found in the kit"

echo; summary
