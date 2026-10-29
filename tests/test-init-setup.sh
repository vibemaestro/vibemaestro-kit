#!/bin/bash
# =============================================================================
# init-kb as the one door: `kb.py init` with --answers, --adopt, --detect and --dry-run
# =============================================================================
# Run: bash tests/test-init-setup.sh
#
# Families:
#   [a] an empty repo, default answers: the files of section B exist, `kb.py config check` and `kb.py check current-state` pass
#   [b] a second run, and a run after a person edited the files: the tree hash is identical, the report says `kept` for each file
#   [c] a synthetic repo shaped like the hub (the fixture without its config, plus a workflow): `--adopt --detect` and the hand-written
#       answers give the golden config, every pre-existing file keeps its hash, no rule file is written, the report lists the hand work
#   [d] an existing config and different answers: nothing is rewritten, `differs` and `would add` are printed, rc 0
#   [e] bad answers (bad regex, unknown key, schema 2, invalid JSON, not an object): rc 65 and `git status --porcelain` empty
#   [f] markers without --adopt: plain init proceeds (rc 0) and keeps every pre-existing file (no refusal since 2.0.0)
#   [g] --dry-run writes nothing; --detect without --adopt is rc 64
#   [h] an answers file that spells out every key of the schema is written verbatim (data-equal), not merged over the defaults
#   [m] a new config holds merge.deny_globs (the list the init-kb skill proposes, or the answer, [] included) and the report
#       names it, so the guarded merge can merge the repo's PRs
#
# Every family runs on a copy of the real plugin; then each planted break (one mutation of kb.py or init_setup.py) must turn the
# family it belongs to red. Real git on throw-away repositories, a fake gh that must stay unused, the network shims of netguard.sh,
# no model, no network. Prose of messages is never asserted, only exit codes, files, hashes, JSON and the words the spec names.
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

PLUGIN="$SRC_ROOT/plugins/vibemaestro-sdlc"
SHAPED="$HERE/fixtures/hub-shaped"
FX="$HERE/fixtures/init-setup"
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
GHB="$TMP/ghbin"; mk_gh "$GHB"
export GH_LOG="$TMP/gh.log"; : > "$GH_LOG"

PLX=""; OUT=""; RC=0

# ── helpers ──────────────────────────────────────────────────────────────────────────────────────
# mk_repo — a new git repo with one committed file, so `git status --porcelain` is meaningful
mk_repo() { local d; d=$(fresh); git_ init -q -b main "$d"; echo x > "$d/a.txt"; git_ -C "$d" add -A; git_ -C "$d" commit -qm c; printf '%s' "$d"; }
# mk_adopt — the synthetic repo shaped like the hub, without its config, with a workflow, committed
mk_adopt() {
  local d; d=$(fresh); cp -r "$SHAPED/." "$d/"; rm -f "$d/.vibemaestro/sdlc.json"; rmdir "$d/.vibemaestro" 2>/dev/null
  mkdir -p "$d/.github/workflows"; cp "$FX/ci.yml" "$d/.github/workflows/ci.yml"
  git_ init -q -b main "$d"; git_ -C "$d" add -A; git_ -C "$d" commit -qm base; printf '%s' "$d"
}
# kbi <repo> <args...> — `kb.py init <args>` from inside <repo>; stdout and stderr in OUT, rc in RC
kbi() { local d=$1; shift; OUT=$(cd "$d" && cenv PATH="$GHB:$PATH" python3 "$PLX/scripts/kb.py" init "$@" 2>&1); RC=$?; }
kbk() { local d=$1; shift; (cd "$d" && cenv python3 "$PLX/scripts/kb.py" "$@" 2>&1); }
porcelain() { git_ -C "$1" status --porcelain; }
# files_hash <dir> — "path sha" lines of every file but .git, sorted: the pre-existing files are compared line by line
files_hash() { (cd "$1" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r p; do printf '%s %s\n' "$p" "$(sha1sum < "$p" | cut -d' ' -f1)"; done); }
# jeq <file a> <file b> — rc 0 when the two JSON files hold the same data
jeq() { python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1])) == json.load(open(sys.argv[2])) else 1)' "$1" "$2"; }
# lines_with <text> <prefix> — the lines of the report that start with the word
count_start() { printf '%s\n' "$1" | grep -c "^$2"; }

# ── [a] [b] the app repo ─────────────────────────────────────────────────────────────────────────
fam_app() {
  PLX=$1; local R H1 H2 H3 n
  R=$(mk_repo); kbi "$R"
  eq "$RC" 0 "[a] an empty repo, default answers: rc 0"
  for f in kb/README.md kb/current-state.md kb/intent/.gitkeep kb/specs/.gitkeep kb/plans/.gitkeep kb/decisions/.gitkeep .vibemaestro/sdlc.json .vibemaestro/rules/README.md .vibemaestro/rules/example.instructions.md; do
    [ -f "$R/$f" ] && ok "[a] written: $f" || bad "[a] missing: $f"
  done
  printf '{"schema":1,"language":"en","rules":{"dirs":[".vibemaestro/rules"]},"current_state":{"template":"ledger"},"merge":{"deny_globs":[".github/workflows/**",".vibemaestro/*",".vibemaestro/gates/**",".vibemaestro/rules/**","**/*secret*"]}}\n' > "$TMP/app-expect.json"
  jeq "$R/.vibemaestro/sdlc.json" "$TMP/app-expect.json" && ok "[a] the config holds schema, the scaffold keys and nothing else (not a copy of the defaults)" || bad "[a] the config differs from the scaffold keys: $(cat "$R/.vibemaestro/sdlc.json")"
  has "$(cat "$R/.vibemaestro/rules/example.instructions.md")" "status: example" "[a] the example rule is status: example"
  eq "$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import rules; print(len(rules.load_dir(sys.argv[2], rules.RULE_SUFFIX)))' "$PLX/scripts" "$R/.vibemaestro/rules")" 0 "[a] …so the engine delivers none of the files of the directory"
  kbk "$R" config check >/dev/null; eq "$?" 0 "[a] kb.py config check on the written config: rc 0"
  kbk "$R" check current-state >/dev/null; eq "$?" 0 "[a] kb.py check current-state on the generated ledger: rc 0"
  # [b] second run: same answers, same tree, every file kept
  H1=$(tree_hash_all "$R"); kbi "$R"
  eq "$RC" 0 "[b] second run: rc 0"; eq "$(tree_hash_all "$R")" "$H1" "[b] second run: the tree hash is identical"
  eq "$(count_start "$OUT" created)" 0 "[b] …the report creates nothing"
  [ "$(count_start "$OUT" kept)" -ge 9 ] && ok "[b] …and says kept for each of the nine files ($(count_start "$OUT" kept))" || bad "[b] fewer than nine kept lines: $OUT"
  # a person edits the generated files; a third run keeps every byte (the `x` mode is the only guard)
  printf '\nA note.\n' >> "$R/kb/README.md"; printf '\nOne more line.\n' >> "$R/kb/current-state.md"
  printf '\nOwn rules.\n' >> "$R/.vibemaestro/rules/README.md"; printf '%s\n' '{"schema": 1, "pr": {"draft": true}}' > "$R/.vibemaestro/sdlc.json"
  H2=$(tree_hash_all "$R"); kbi "$R"
  eq "$(tree_hash_all "$R")" "$H2" "[b] after edits by a person: a run keeps every byte (README, current-state, rules README, config)"
  # the other template: the skeleton must pass the gate of its own preset
  R=$(mk_repo); printf '{"current_state": {"template": "map"}}' > "$TMP/ans-map.json"; kbi "$R" --answers "$TMP/ans-map.json"
  eq "$RC" 0 "[a] template map: rc 0"
  kbk "$R" check current-state >/dev/null; eq "$?" 0 "[a] template map: the generated skeleton passes check current-state"
  for tc in '{"current_state": {"template": "map", "table": {"columns": 3}}}' '{"current_state": {"table": {"columns": 4, "required": true}}}'; do
    R=$(mk_repo); printf '%s' "$tc" > "$TMP/ans-tc.json"; kbi "$R" --answers "$TMP/ans-tc.json"
    eq "$RC" 0 "[a] answers that set the table width: rc 0"; kbk "$R" check current-state >/dev/null; eq "$?" 0 "[a] …the skeleton has a table of that width and passes check current-state ($tc)"
  done
  # a rules directory chosen by the person gets the scaffold; a directory that holds own rules does not
  R=$(mk_repo); printf '{"rules": {"dirs": ["docs/rules"]}}' > "$TMP/ans-dir.json"; kbi "$R" --answers "$TMP/ans-dir.json"
  [ -f "$R/docs/rules/example.instructions.md" ] && [ ! -e "$R/.vibemaestro/rules" ] && ok "[a] rules.dirs from the answers: the scaffold goes there" || bad "[a] the scaffold is not in the chosen directory"
  R=$(mk_repo); mkdir -p "$R/.vibemaestro/rules"; printf -- '---\napplyTo: "src/**"\n---\n\nOwn rule.\n' > "$R/.vibemaestro/rules/own.instructions.md"
  kbi "$R"; eq "$RC" 0 "[a] a rules directory with a rule of its own: rc 0"
  [ ! -e "$R/.vibemaestro/rules/example.instructions.md" ] && [ ! -e "$R/.vibemaestro/rules/README.md" ] && ok "[a] …and no example or README is dropped among the repo's own rules" || bad "[a] scaffold files written next to a repo's own rule"
  n=$(cat "$GH_LOG" | wc -l | tr -d ' '); eq "$n" 0 "[a] init never calls gh (the fake gh log is empty)"
}

# ── [c] adopt a repo shaped like the hub ─────────────────────────────────────────────────────────
fam_adopt() {
  PLX=$1; local R B A Z H1
  R=$(mk_adopt); (cd "$R" && files_hash .) > "$TMP/before.hash"
  kbi "$R" --adopt --detect --answers "$FX/answers-adopt.json"
  eq "$RC" 0 "[c] --adopt --detect with the hand-written answers: rc 0"
  jeq "$R/.vibemaestro/sdlc.json" "$FX/golden-adopt.json" && ok "[c] the written config equals the golden file" || bad "[c] the config differs from the golden file: $(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), sort_keys=True))' "$R/.vibemaestro/sdlc.json")"
  files_hash "$R" > "$TMP/after.hash"
  B=$(LC_ALL=C comm -23 "$TMP/before.hash" "$TMP/after.hash"); empty "$B" "[c] every pre-existing file has the same hash (none changed, none removed)"
  A=$(LC_ALL=C comm -13 "$TMP/before.hash" "$TMP/after.hash" | cut -d' ' -f1 | LC_ALL=C sort | tr '\n' ' ')
  has "$A" "./.vibemaestro/sdlc.json" "[c] …the config is among the new files"
  hasnt "$A" ".instructions.md" "[c] …and no rule file is written"; hasnt "$A" "./.github/" "[c] …nothing is written into the existing rule directory (or anywhere under .github)"
  has "$OUT" '"dirs": [".github/instructions"]' "[c] the report shows what --detect proposed: the rules directory"
  has "$OUT" '"runner_default": "ops-runners"' "[c] …the runner label (the commonest runs-on, the fallback of the variable expression)"
  has "$OUT" '"allowlist": ".pr-sensitive-allow"' "[c] …the allowlist file"
  hasnt "$OUT" '"table"' "[c] …and no table width (the ledger has tables of 4, 5 and 3 columns: no single width)"
  hasnt "$OUT" "legacy hook markers" "[c] …and no markers line (the plugin no longer reads them)"
  hasnt "$OUT" "instructions-for-path.py" "[c] the hand work names no legacy hook script"; has "$OUT" "By hand" "[c] …under By hand"; has "$OUT" "After that the plugin" "[c] …and what the plugin does after"
  has "$OUT" "kept    kb/current-state.md" "[c] the existing ledger is kept"
  # same answers twice
  H1=$(tree_hash_all "$R"); kbi "$R" --adopt --detect --answers "$FX/answers-adopt.json"
  eq "$RC" 0 "[c] the same run again: rc 0"; eq "$(tree_hash_all "$R")" "$H1" "[c] …the tree hash is identical"; eq "$(count_start "$OUT" created)" 0 "[c] …nothing created"
  # without --detect nothing is proposed: the answers file is what is written
  R=$(mk_adopt); kbi "$R" --adopt --answers "$FX/answers-adopt.json"
  eq "$RC" 0 "[c] --adopt without --detect: rc 0"
  eq "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("rules" in d, "ci" in d, "sensitive" in d)' "$R/.vibemaestro/sdlc.json")" "False False False" "[c] …the written config holds no detected key (detection only runs when asked)"
  # a rules directory named by the answers does not get a scaffold under --adopt
  R=$(mk_adopt); printf '{"rules": {"dirs": ["docs/newrules"]}}' > "$TMP/ans-nr.json"; kbi "$R" --adopt --answers "$TMP/ans-nr.json"
  [ ! -e "$R/docs/newrules" ] && ok "[c] --adopt writes no rules scaffold, even into a directory the answers name" || bad "[c] --adopt created $(ls "$R/docs/newrules")"
  # only a plain label, or the fallback of `vars.X || 'label'`, is a runner label; any other expression or YAML decoration is skipped
  R=$(mk_repo); mkdir -p "$R/.github/workflows"
  printf 'jobs:\n  a:\n    runs-on: ${{ github.event_name == %spush%s && %sbig%s || %ssmall%s }}\n  b:\n    runs-on: &anchor x\n  c:\n    runs-on: [self-hosted, linux]\n' "'" "'" "'" "'" "'" "'" > "$R/.github/workflows/w.yml"
  git_ -C "$R" add -A; git_ -C "$R" commit -qm wf; kbi "$R" --adopt --detect --dry-run
  hasnt "$OUT" '"runner_default"' "[c] a conditional expression, a YAML anchor and a list are not runner labels"
  # the table width is proposed only when every table has it
  R=$(mk_repo); mkdir -p "$R/kb"; printf '# State\n\n## One\n\n| A | B | C |\n|---|---|---|\n| 1 | 2 | 3 |\n\n## Two\n\n| D | E | F |\n|---|---|---|\n| 4 | 5 | 6 |\n' > "$R/kb/current-state.md"
  git_ -C "$R" add -A; git_ -C "$R" commit -qm cs
  kbi "$R" --adopt --detect --dry-run
  has "$OUT" '"table": {"columns": 3, "required": true}' "[c] one table width in the ledger: it is proposed"
  Z=$(mk_repo); mkdir -p "$Z/docs"; printf '# State\n' > "$Z/docs/current-state.md"; git_ -C "$Z" add -A; git_ -C "$Z" commit -qm cs
  kbi "$Z" --adopt --detect --dry-run; has "$OUT" '"path": "docs/current-state.md"' "[c] a ledger that is not at the default path but is the only one: its path is proposed"
  # paths git ignores are not read: a build copy of a rule or of the ledger is not the repo's own
  Z=$(mk_repo); mkdir -p "$Z/docs" "$Z/build/rules" "$Z/out"; printf '# State\n' > "$Z/docs/current-state.md"
  printf 'build/\nout/current-state.md\n' > "$Z/.gitignore"; printf '# copy\n' > "$Z/out/current-state.md"
  printf -- '---\napplyTo: "**"\ndescription: "d"\n---\n\nx\n' > "$Z/build/rules/a.instructions.md"
  git_ -C "$Z" add -A; git_ -C "$Z" commit -qm cs
  kbi "$Z" --adopt --detect --dry-run
  hasnt "$OUT" "build/rules" "[c] a rule file in a git-ignored directory is not proposed as a rules directory"
  has "$OUT" '"path": "docs/current-state.md"' "[c] …and an ignored copy of the ledger does not hide the one ledger of the repo"
  printf '' > "$Z/.gitignore"; kbi "$Z" --adopt --detect --dry-run
  has "$OUT" "build/rules" "[c] …control: the same directory, not ignored, is proposed"
}

# ── [d] an existing config ───────────────────────────────────────────────────────────────────────
fam_exist() {
  PLX=$1; local R H
  R=$(mk_repo); kbi "$R"
  printf '{"ci": {"runner_default": "x-runners"}, "rules": {"dirs": ["other/rules"]}, "pr": {"draft": true}, "current_state": {"template": "map"}}' > "$TMP/ans-d.json"
  H=$(tree_hash_all "$R"); kbi "$R" --answers "$TMP/ans-d.json"
  eq "$RC" 0 "[d] an existing config and different answers: rc 0"
  eq "$(tree_hash_all "$R")" "$H" "[d] nothing is rewritten or added (the tree hash is identical)"
  has "$OUT" "differs rules.dirs" "[d] a key the file has with another value: differs"
  has "$OUT" "differs current_state.template" "[d] …a second one"
  has "$OUT" "would add pr.draft" "[d] a key the file lacks: would add"
  has "$OUT" "would add ci.runner_default" "[d] …a second one"
  hasnt "$OUT" "differs pr.draft" "[d] …and a key the file lacks is not reported as differing"
  kbi "$R" --answers "$FX/answers-adopt.json" --dry-run; eq "$RC" 0 "[d] --dry-run on an existing config: rc 0"
  R=$(mk_repo); kbi "$R"; kbi "$R" --answers "$TMP/app-expect.json"; hasnt "$OUT" "differs" "[d] answers equal to the file: no differs"; hasnt "$OUT" "would add" "[d] …and no would add"
}

# ── [e] bad answers ──────────────────────────────────────────────────────────────────────────────
# bcase <label> <answers text | -> <key the message must name | -> [more init args...]
bcase() {
  local R l=$1 t=$2 k=$3; shift 3; R=$(mk_repo)
  [ "$t" != - ] && printf '%s' "$t" > "$TMP/bad.json"
  kbi "$R" "$@" --answers "$TMP/bad.json"
  eq "$RC" 65 "[e] $l: rc 65"; empty "$(porcelain "$R")" "[e] $l: git status --porcelain is empty (nothing written)"
  [ "$k" = - ] || has "$OUT" "$k" "[e] $l: the message names '$k'"
}
fam_bad() {
  PLX=$1; local R
  bcase "a bad regex" '{"pr": {"title": {"pattern": "("}}}' pr.title.pattern
  bcase "an unknown key" '{"bogus": 1}' bogus
  bcase "an unknown key two levels down" '{"pr": {"title": {"bogus": 1}}}' pr.title.bogus
  bcase "schema above the plugin's" '{"schema": 2}' schema
  bcase "invalid JSON" '{nope' -
  bcase "a JSON array" '[1, 2]' -
  bcase "a bad value among good ones" '{"ci": {"runner_default": "ok-runners"}, "hooks": "sometimes"}' hooks
  R=$(mk_adopt); printf '{"commits": {"round_pattern": "no-group"}}' > "$TMP/bad2.json"; kbi "$R" --adopt --detect --answers "$TMP/bad2.json"
  eq "$RC" 65 "[e] adopt with --detect and a bad answer: rc 65"; empty "$(porcelain "$R")" "[e] …and nothing written"
  R=$(mk_repo); kbi "$R" --answers "$TMP/does-not-exist.json"
  eq "$RC" 66 "[e] an answers file that does not exist: rc 66"; empty "$(porcelain "$R")" "[e] …and nothing written"
  R=$(mk_repo); kbi "$R" --answers "$TMP"
  eq "$RC" 66 "[e] an answers path that is a directory: rc 66"; empty "$(porcelain "$R")" "[e] …and nothing written"
  bcase "a lone surrogate in a comment key (valid for the schema, not encodable)" '{"_note": "\ud800"}' -
  R=$(mk_repo); printf '{"rules": {"dirs": ["a.txt"]}}' > "$TMP/under-file.json"
  kbi "$R" --answers "$TMP/under-file.json"; eq "$RC" 65 "[e] a rules directory under a path that is a file: rc 65"; empty "$(porcelain "$R")" "[e] …and nothing written"
  kbi "$R" --answers "$TMP/under-file.json" --dry-run; eq "$RC" 65 "[e] …--dry-run says the same (it does not promise a write that would crash)"
  printf '{"current_state": {"path": "a.txt/cs.md"}}' > "$TMP/cs-under-file.json"; kbi "$R" --answers "$TMP/cs-under-file.json"
  eq "$RC" 65 "[e] a ledger path under a file: rc 65"; empty "$(porcelain "$R")" "[e] …and nothing written"
  R=$(mk_repo); mkdir "$TMP/outside"; ln -s "$TMP/outside" "$R/rl"; git_ -C "$R" add -A; git_ -C "$R" commit -qm link
  printf '{"rules": {"dirs": ["rl"]}}' > "$TMP/link.json"; kbi "$R" --answers "$TMP/link.json"
  eq "$RC" 65 "[e] a rules directory that is a link out of the repo: rc 65"; empty "$(ls -A "$TMP/outside")" "[e] …and nothing was written outside the repo"; empty "$(porcelain "$R")" "[e] …nor inside it"
  R=$(mk_repo); printf '{"ci": {"runner_default": "ok-runners"}}' > "$TMP/good.json"; kbi "$R" --answers "$TMP/good.json"
  eq "$RC" 0 "[e] control: valid answers are accepted (rc 0)"; has "$(cat "$R/.vibemaestro/sdlc.json")" "ok-runners" "[e] …and written"
}

# ── [f] [g] no marker refusal, the flags ─────────────────────────────────────────────────────────
fam_flags() {
  PLX=$1; local R Z H H2 B
  R=$(mk_adopt); files_hash "$R" > "$TMP/f-before.hash"; kbi "$R"
  eq "$RC" 0 "[f] markers present, plain init (no --adopt): rc 0"; has "$OUT" "created .vibemaestro/sdlc.json" "[f] …the config is written"
  files_hash "$R" > "$TMP/f-after.hash"
  B=$(LC_ALL=C comm -23 "$TMP/f-before.hash" "$TMP/f-after.hash"); empty "$B" "[f] …every pre-existing file has the same hash"
  R=$(mk_adopt); kbi "$R" --answers "$FX/answers-adopt.json"; eq "$RC" 0 "[f] markers present, answers but no --adopt: rc 0"
  R=$(mk_adopt); H=$(tree_hash_all "$R")
  Z=$(mk_repo); H2=$(tree_hash_all "$Z"); kbi "$Z" --detect; eq "$RC" 64 "[g] --detect without --adopt: rc 64"; eq "$(tree_hash_all "$Z")" "$H2" "[g] …and nothing written"
  kbi "$R" --adopt --detect --dry-run --answers "$FX/answers-adopt.json"
  eq "$RC" 0 "[g] --adopt --detect --dry-run: rc 0"; empty "$(porcelain "$R")" "[g] …git status --porcelain is empty"; eq "$(tree_hash_all "$R")" "$H" "[g] …the tree hash is identical"
  has "$OUT" "would create .vibemaestro/sdlc.json" "[g] …the report says what it would create"
  R=$(mk_repo); kbi "$R" --dry-run; eq "$RC" 0 "[g] an app repo with --dry-run: rc 0"; empty "$(porcelain "$R")" "[g] …git status --porcelain is empty"
  has "$OUT" "would create kb/README.md" "[g] …the report says what it would create"
  kbi "$R" --adopt --bogus; eq "$RC" 64 "[g] an unknown argument: rc 64"
  kbi "$R" --answers; eq "$RC" 64 "[g] --answers without a file: rc 64"
  # an empty value was read as "no answers" and the default config was written
  Z=$(mk_repo); H2=$(tree_hash_all "$Z"); kbi "$Z" --answers ""; eq "$RC" 64 "[g] --answers \"\" (an empty path): rc 64"
  eq "$(tree_hash_all "$Z")" "$H2" "[g] …and nothing written"; has "$OUT" "--answers needs a file path" "[g] …the message says why"
}

# ── [h] a full config is written verbatim ────────────────────────────────────────────────────────
fam_full() {
  PLX=$1; local R miss
  R=$(mk_adopt); kbi "$R" --adopt --detect --answers "$FX/answers-full.json"
  eq "$RC" 0 "[h] an answers file with every key of the schema, --adopt --detect: rc 0"
  jeq "$R/.vibemaestro/sdlc.json" "$FX/answers-full.json" && ok "[h] the written config equals the answers file (detected values and scaffold do not leak in; the _comment is kept)" || bad "[h] the config is not the answers file: $(cat "$R/.vibemaestro/sdlc.json" | head -c 300)"
  kbk "$R" config check >/dev/null; eq "$?" 0 "[h] kb.py config check accepts it"
  miss=$(python3 - "$PLX/scripts" "$FX/answers-full.json" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
import sdlc_config as C
def leaves(x, p=""):
    out = set()
    for k, v in x.items():
        if k.startswith("_"):
            continue
        if isinstance(v, dict) and v:
            out |= leaves(v, p + k + ".")
        else:
            out.add(p + k)
    return out
have = leaves(json.load(open(sys.argv[2])))
# a key that defaults to null is covered by the keys of its object
print(" ".join(sorted(k for k in leaves(C.DEFAULTS) if k not in have and not any(h.startswith(k + ".") for h in have))))
PY
)
  empty "$miss" "[h] the full answers file really names every key of the schema (a new schema key turns this red until the file has it)"
  R=$(mk_repo); kbi "$R" --answers "$FX/answers-full.json"
  eq "$RC" 0 "[h] the full answers in an app repo: rc 0"; jeq "$R/.vibemaestro/sdlc.json" "$FX/answers-full.json" && ok "[h] …written verbatim there too" || bad "[h] app repo: the config is not the answers file"
}

# ── [m] merge.deny_globs in a new config ───────────────────────────────────────────────────────────
fam_merge() {
  PLX=$1; local R skill got want
  skill=$(python3 -c 'import json,re,sys
for l in open(sys.argv[1]):
    lists = re.findall(r"`(\[.*?\])`", l) if "`merge.deny_globs`" in l else []
    if lists: print(json.dumps(json.loads(lists[-1]))); break' "$PLX/skills/init-kb/SKILL.md")
  case "$skill" in '['*'.vibemaestro/*"'*) ok "[m] instrument: the skill proposes a deny list ($skill)";; *) bad "[m] instrument: no deny list read from the skill: $skill";; esac
  for mode in app adopt; do
    R=$(mk_repo); if [ "$mode" = adopt ]; then kbi "$R" --adopt; else kbi "$R"; fi
    eq "$RC" 0 "[m] $mode, no answers: rc 0"
    got=$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get("merge", {}).get("deny_globs")))' "$R/.vibemaestro/sdlc.json")
    eq "$got" "$skill" "[m] $mode: the new config holds merge.deny_globs, the list the init-kb skill proposes"
    has "$OUT" "merge.deny_globs = " "[m] $mode: …and the report names it"
  done
  R=$(mk_repo); printf '{"merge": {"deny_globs": []}}' > "$TMP/ans-deny.json"; kbi "$R" --answers "$TMP/ans-deny.json"
  got=$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["merge"]["deny_globs"]))' "$R/.vibemaestro/sdlc.json")
  eq "$RC:$got" "0:[]" "[m] an answer of [] replaces the default"
  R=$(mk_repo); printf '{"merge": {"deny_globs": null}}' > "$TMP/ans-null.json"; kbi "$R" --answers "$TMP/ans-null.json"
  has "$OUT" "merge.deny_globs is unset" "[m] an answer of null: the report says unset"
  hasnt "$OUT" "merge.deny_globs = null" "[m] …and does not claim it was written"
  R=$(mk_repo); mkdir -p "$R/.vibemaestro"; printf '%s\n' '{"schema": 1}' > "$R/.vibemaestro/sdlc.json"
  kbi "$R"; eq "$(cat "$R/.vibemaestro/sdlc.json")" '{"schema": 1}' "[m] an existing config is not rewritten to add it"
  hasnt "$OUT" "merge.deny_globs = " "[m] …and the report does not claim it wrote one"
  # a rules folder under .vibemaestro/ with another name: its glob is added to the list the skill proposes
  want=$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1]) + [".vibemaestro/policies/**"]))' "$skill")
  printf '{"rules": {"dirs": [".vibemaestro/policies"]}}' > "$TMP/ans-policies.json"
  for mode in app adopt; do
    R=$(mk_repo); if [ "$mode" = adopt ]; then kbi "$R" --adopt --answers "$TMP/ans-policies.json"; else kbi "$R" --answers "$TMP/ans-policies.json"; fi
    got=$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get("merge", {}).get("deny_globs")))' "$R/.vibemaestro/sdlc.json")
    eq "$RC:$got" "0:$want" "[m] $mode: rules.dirs .vibemaestro/policies adds .vibemaestro/policies/** to the proposed list"
    has "$OUT" ".vibemaestro/policies/**" "[m] $mode: …and the report names it"
  done
  printf '{"rules": {"dirs": [".vibemaestro/p[1]"]}}' > "$TMP/ans-class.json"
  R=$(mk_repo); kbi "$R" --answers "$TMP/ans-class.json"
  got=$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get("merge", {}).get("deny_globs")[-1]))' "$R/.vibemaestro/sdlc.json")
  eq "$RC:$got" '0:".vibemaestro/p?1?/**"' "[m] a rules folder with a class character in its name still gets a deny glob (fail closed)"
  printf '{"rules": {"dirs": 5}}' > "$TMP/ans-dirs5.json"
  R=$(mk_repo); kbi "$R" --answers "$TMP/ans-dirs5.json"
  eq "$RC" 65 "[m] rules.dirs that is not a list: refused as invalid (rc 65), not a crash"
  printf '{"rules": {"dirs": [".vibemaestro/policies"]}, "merge": {"deny_globs": ["x/**"]}}' > "$TMP/ans-own.json"
  R=$(mk_repo); kbi "$R" --answers "$TMP/ans-own.json"
  got=$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["merge"]["deny_globs"]))' "$R/.vibemaestro/sdlc.json")
  eq "$RC:$got" '0:["x/**"]' "[m] an answer for merge.deny_globs is kept exactly, whatever rules.dirs says"
  printf '{"rules": {"dirs": [".vibemaestro/policies"]}, "merge": {"deny_globs": null}}' > "$TMP/ans-null2.json"
  R=$(mk_repo); kbi "$R" --answers "$TMP/ans-null2.json"
  has "$OUT" "merge.deny_globs is unset" "[m] an answer of null stays unset next to a rules folder"
}

FAMILIES="fam_app fam_adopt fam_exist fam_bad fam_flags fam_full fam_merge"
PL0="$TMP/plugin-real"; mk_plugin_copy "$PL0"
for f in init_setup.py kb.py; do [ -f "$PL0/scripts/$f" ] && ok "instrument: the plugin copy has $f" || bad "instrument: $f is missing from the copy"; done
for f in answers-adopt.json golden-adopt.json answers-full.json ci.yml; do [ -f "$FX/$f" ] && ok "instrument: fixture $f exists" || bad "instrument: fixture $f is missing"; done
for f in $FAMILIES; do echo "-- $f"; "$f" "$PL0"; done
eq "$(wc -l < "$GH_LOG" | tr -d ' ')" 0 "no family called gh"

echo "== planted breaks: each family must go red on a plugin with one break =="
BRK() {  # BRK <label> <family> <needle> <file under scripts/> <old> <new>
  local d="$TMP/break-$1"; mk_plugin_copy "$d"
  mutate "$d/scripts/$4" "$5" "$6" && expect_red "$1" "$2" "$d" "$3"
}
BRK deny-not-written fam_merge '[m] app: the new config holds merge.deny_globs' init_setup.py '"current_state": {"template": "ledger"}, "merge": {"deny_globs": DENY_DEFAULT}}' '"current_state": {"template": "ledger"}}'
BRK deny-not-written-adopt fam_merge '[m] adopt: the new config holds merge.deny_globs' init_setup.py 'ADOPT_SCAFFOLD = {"schema": 1, "language": NEW_LANGUAGE, "merge": {"deny_globs": DENY_DEFAULT}}' 'ADOPT_SCAFFOLD = {"schema": 1, "language": NEW_LANGUAGE}'
BRK deny-drifts-from-skill fam_merge '[m] app: the new config holds merge.deny_globs' sdlc_config.py 'MERGE_DENY_DEFAULT = (".github/workflows/**", ".vibemaestro/*", ".vibemaestro/gates/**", ".vibemaestro/rules/**", "**/*secret*")' 'MERGE_DENY_DEFAULT = (".github/workflows/**",)'
BRK deny-floor-not-derived fam_merge '[m] app: rules.dirs .vibemaestro/policies adds .vibemaestro/policies/** to the proposed list' init_setup.py '"deny_globs" not in (inputs.get("merge") or {}):' 'False:'
BRK deny-note-silent fam_merge '[m] app: …and the report names it' init_setup.py '        out((DENY_NOTE % j(deny)) if deny is not None else DENY_UNSET_NOTE)' '        out("")'
BRK deny-null-claimed fam_merge '[m] an answer of null: the report says unset' init_setup.py '        out((DENY_NOTE % j(deny)) if deny is not None else DENY_UNSET_NOTE)' '        out(DENY_NOTE % j(deny))'
BRK overwrites-existing-files fam_app '[b] after edits by a person' init_setup.py 'open(path, "x", encoding="utf-8")' 'open(path, "w", encoding="utf-8")'
BRK validation-skipped fam_bad '[e] a bad regex: git status --porcelain is empty' init_setup.py '    if bad:' '    if False:'
BRK detect-always-on fam_adopt '[c] …the written config holds no detected key' init_setup.py 'prop = detect(root) if o["detect"] else {}' 'prop = detect(root) if True else {}'
BRK markers-refusal-restored fam_flags '[f] markers present, plain init (no --adopt): rc 0' kb.py '        return 65
    if rest[0] == "base":' '        return 65
    if all(m in (vsdlc.read_text(os.path.join(root, ".claude", "settings.json")) or "") for m in ("instructions-for-path.py", "instructions-for-command.py")):
        return die("refused", 3)
    if rest[0] == "base":'
BRK differs-not-printed fam_exist '[d] a key the file has with another value' init_setup.py '            elif have[key] != val:' '            elif False:'
BRK would-add-not-printed fam_exist '[d] a key the file lacks: would add' init_setup.py '            if key not in have:' '            if False:'
BRK rules-scaffold-under-adopt fam_adopt '[c] --adopt created' init_setup.py '    if not o["adopt"] and rule_dirs:' '    if rule_dirs:'
BRK own-rules-not-respected fam_app '[a] scaffold files written next to' init_setup.py '            if own:
                soft.add(rel)' '            pass'
BRK empty-answers-allowed fam_flags '[g] --answers "" (an empty path): rc 64' init_setup.py '            if not argv[i + 1]:' '            if False:'
BRK detect-walks-ignored fam_adopt '[c] a rule file in a git-ignored directory' init_setup.py '    ignored = _ignored(root)' '    ignored = set()'
BRK detect-without-adopt-allowed fam_flags '[g] --detect without --adopt: rc 64' init_setup.py '    if o["detect"] and not o["adopt"]:' '    if False:'
BRK dry-run-writes fam_flags '[g] …git status --porcelain is empty' init_setup.py '        elif o["dry"]:
            out("would create' '        elif False:
            out("would create'
BRK full-answers-merged-over-defaults fam_full '[h] the config is not the answers file' init_setup.py 'json.dumps(composed, indent=2' 'json.dumps(C._merge(C.defaults(), composed), indent=2'
BRK underscore-keys-dropped fam_full '[h] the config is not the answers file' init_setup.py '    for k, v in over.items():
        if isinstance' '    for k, v in over.items():
        if k.startswith("_"):
            continue
        if isinstance'
BRK scaffold-leaks-into-full-answers fam_full '[h] app repo: the config is not the answers file' init_setup.py '    composed = layer(layer(ADOPT_SCAFFOLD if o["adopt"] else APP_SCAFFOLD, prop), answers)' '    composed = layer(layer(ADOPT_SCAFFOLD if o["adopt"] else APP_SCAFFOLD, prop), answers); composed["upstream_issues"] = True'
BRK table-width-of-mixed-tables fam_adopt '[c] …and no table width' init_setup.py 'widths.pop() if len(widths) == 1 else None' 'max(widths)'
BRK runner-first-label-wins fam_adopt '[c] …the runner label' init_setup.py 'sorted(count, key=lambda k: (-count[k], k))[0]' 'sorted(count)[0]'
BRK unreadable-answers-is-65 fam_bad '[e] an answers path that is a directory: rc 66' init_setup.py '    except OSError as e:                                            # missing, a directory, no permission: nothing to read
        return None, (66,' '    except OSError as e:
        return None, (65,'
BRK unencodable-answers-written fam_bad '[e] a lone surrogate in a comment key' init_setup.py '        cfg_text.encode("utf-8")' '        pass'
BRK paths-not-checked fam_bad '[e] a rules directory under a path that is a file: rc 65' init_setup.py '    blocked = unfit(root, [rel for rel, text in plan if text is not None])' '    blocked = []'
BRK link-out-of-repo-allowed fam_bad '[e] a rules directory that is a link out of the repo: rc 65' init_setup.py '            if real != real_root and not real.startswith(real_root + os.sep):' '            if False:'
BRK dry-run-skips-path-check fam_bad '[e] …--dry-run says the same' init_setup.py '    blocked = unfit(root, [rel for rel, text in plan if text is not None])' '    blocked = [] if o["dry"] else unfit(root, [rel for rel, text in plan if text is not None])'
BRK skeleton-ignores-table-width fam_app 'the skeleton has a table of that width' kb.py 'skeleton_table(table_cols) if table_cols else ""' '(skeleton_table(5) if table_cols else "")'
BRK runner-expression-taken fam_adopt '[c] a conditional expression, a YAML anchor and a list' init_setup.py 'r"""^\$\{\{\s*vars\.\w+\s*' 'r"""'
BRK adopt-edits-existing-ledger fam_adopt '[c] every pre-existing file has the same hash' init_setup.py '        elif write_new(p, text):' '        elif write_new(p, text) or open(p, "a").write("x"):'

echo
summary
