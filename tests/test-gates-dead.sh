#!/bin/bash
# =============================================================================
# Gate: dead branches (plugins/vibemaestro-sdlc/gates/dead_branches.sh), the families of the hub's dead-branch test plus the config keys
# =============================================================================
# Run: bash tests/test-gates-dead.sh
#
# Why a real repo: the one question the script asks is "is the tip of this branch an ancestor of that ref?". Mocking git here would mock
# the thing under test. No case touches a real `origin`: every case builds a bare repo in a temp directory as the remote, and the
# script fetches only with --fetch, which no case passes.
#
# The sure-positive case that matters most is the ORDER OF THE QUESTIONS: the bait repo has the shape main -> intent -> feature that is
# already merged into main. The open intent branch contains the feature, so asking "does an open intent contain it?" first would label
# the feature "in use" and the count would fall to 0.
#
#   [D] the hub's cases: positive, negative, order, the in-intent group, adding and deleting a junk branch, the symbolic ref, printing
#       the cleanup command and not running it, both directions of the exit code, a clean repo
#   [K] config: threshold, protected branches, the intent prefix, the main line, flags over config
#   [B] the base-ref rule and the failures: bad config rc 65, a ref that does not read, usage rc 64, not a repo rc 2
# Each family runs again on a copy with ONE planted break and must go red.
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
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"
[ -f "$PLUGIN/gates/dead_branches.sh" ] && ok "the gate exists" || { bad "the gate is missing"; summary; exit 1; }

# dg <plugin> <repo> [args...] — run the gate; OUT and RC
dg() { local p=$1 r=$2; shift 2; RC=0; OUT=$(cenv bash "$p/gates/dead_branches.sh" --repo "$r" "$@" 2>&1) || RC=$?; }
commit() { printf '%s\n' "$3" > "$1/$2"; G -C "$1" add -A; G -C "$1" commit -qm "$3"; }
num() { printf '%s\n' "$1" | grep -F "$2" | head -1 | awk '{print $NF}'; }
refs() { G -C "$1" for-each-ref --format='%(refname)' refs/heads | sort; }

# Bait repo, the exact shape that once made a person count wrong:
#   main --o base --o merge feature/done --o next
#                       ^                   |
#                 feature/done         intent/rework   (cut AFTER the merge, so it contains it)
#   feature/wip           cut from base, merged nowhere
#   feature/in-intent     merged into intent/rework, NOT into main
setup() {
  BARE="$(mktemp -d "$TMP/o.XXXXXX")/origin.git"; mkdir -p "$BARE"
  G init -q --bare -b main "$BARE"
  WK=$(mktemp -d "$TMP/w.XXXXXX")
  G clone -q "$BARE" "$WK" 2>/dev/null
  G -C "$WK" symbolic-ref HEAD refs/heads/main
  commit "$WK" a.txt base
  G -C "$WK" checkout -q -b feature/wip; commit "$WK" wip.txt wip
  G -C "$WK" checkout -q main; G -C "$WK" checkout -q -b feature/done; commit "$WK" done.txt done
  G -C "$WK" checkout -q main; G -C "$WK" merge -q --no-ff -m "merge feature/done" feature/done
  G -C "$WK" checkout -q -b intent/rework; commit "$WK" intent.txt intent
  G -C "$WK" checkout -q -b feature/in-intent; commit "$WK" ti.txt ti
  G -C "$WK" checkout -q intent/rework; G -C "$WK" merge -q --no-ff -m "merge feature/in-intent" feature/in-intent
  G -C "$WK" checkout -q main; G -C "$WK" push -q origin --all
}

fam_hub() {
  local p=$1 O D U I D2 D3 OUT2 B A R
  setup; local W=$WK BR=$BARE B0 A0
  B0=$(refs "$BR"); dg "$p" "$W"; O=$OUT; A0=$(refs "$BR")
  [ "$B0" = "$A0" ] && ok "[D] the first run deletes no branch on the remote" || bad "[D] the gate deleted a branch on its first run"
  if printf '%s\n' "$O" | grep -qF 'origin/feature/done' && ! printf '%s\n' "$O" | grep -F 'origin/feature/done' | grep -qF '<-'; then ok "[D] positive: feature/done is in the deletable group, not the intent group"
  else bad "[D] positive: feature/done is not in the deletable group: $(printf '%s' "$O" | grep -F feature/done)"; fi
  D=$(num "$O" 'deletable'); [ "$D" = 1 ] && ok "[D] deletable count = 1" || bad "[D] deletable count: $D"
  if G -C "$W" merge-base --is-ancestor feature/done intent/rework; then ok "[D] the bait has the right shape: intent/rework CONTAINS feature/done (the trap is real)"
  else bad "[D] the bait does not have the trap shape: the positive case is meaningless"; fi
  if printf '%s\n' "$O" | sed -n '/entirely inside/,$p' | grep -qF 'origin/feature/wip'; then bad "[D] negative: feature/wip (unmerged) counted as deletable"
  else ok "[D] negative: feature/wip is not in the deletable group"; fi
  U=$(num "$O" 'not merged anywhere'); [ "$U" = 2 ] && ok "[D] not-merged count = 2 (feature/wip and intent/rework)" || bad "[D] not-merged count: $U"
  I=$(num "$O" 'open intent branch'); [ "$I" = 1 ] && ok "[D] in-intent count = 1" || bad "[D] in-intent count: $I"
  printf '%s\n' "$O" | grep -qF 'origin/feature/in-intent  <- origin/intent/rework' && ok "[D] feature/in-intent is attributed to intent/rework" || bad "[D] attribution: $(printf '%s' "$O" | grep -F in-intent)"
  G -C "$W" checkout -q -b feature/junk main; commit "$W" junk.txt junk; G -C "$W" checkout -q main; G -C "$W" merge -q --no-ff -m "merge junk" feature/junk
  G -C "$W" push -q origin main feature/junk
  dg "$p" "$W"; D2=$(num "$OUT" 'deletable'); [ "$D2" = 2 ] && ok "[D] a merged junk branch: the count rises by one (1 -> 2)" || bad "[D] after adding junk: $D2"
  G -C "$W" push -q origin --delete feature/junk; G -C "$W" fetch -q --prune origin
  dg "$p" "$W"; D3=$(num "$OUT" 'deletable'); [ "$D3" = 1 ] && ok "[D] deleting the junk branch: the count falls by one (2 -> 1)" || bad "[D] after deleting junk: $D3"
  # `origin/HEAD` shortens to `origin` and appears after the first fetch; before the fix it filled in exactly the slot of a branch just deleted
  G -C "$W" fetch -q origin; G -C "$W" remote set-head origin main >/dev/null; dg "$p" "$W"; OUT2=$OUT
  if printf '%s\n' "$OUT2" | sed -n '/entirely inside/,$p' | grep -qxE ' *origin'; then bad "[D] origin/HEAD counted as a branch"; else ok "[D] the symbolic ref origin/HEAD is not counted as a branch"; fi
  [ "$(num "$OUT2" 'deletable')" = 1 ] && ok "[D] after a fetch (origin/HEAD exists) the count is still 1" || bad "[D] after fetch: $(num "$OUT2" 'deletable')"
  [ "$(num "$OUT2" 'not merged anywhere')" = 2 ] && ok "[D] …and the not-merged count is still 2 (the symbolic ref is not a branch of any group)" || bad "[D] after fetch the not-merged count is $(num "$OUT2" 'not merged anywhere')"
  printf '%s\n' "$O" | grep -qF 'git push origin --delete' && ok "[D] the cleanup command is printed for a person" || bad "[D] no cleanup command"
  B=$(refs "$BR"); dg "$p" "$W"; A=$(refs "$BR")
  [ "$B" = "$A" ] && ok "[D] running the gate again deletes no branch on the remote" || bad "[D] the gate deleted a branch"
  if grep -nE '^[[:space:]]*(g |git )' "$p/gates/dead_branches.sh" | grep -qE 'push .*--delete|branch -[dD]'; then bad "[D] the source runs a delete command"; else ok "[D] the source executes no delete command"; fi
  dg "$p" "$W" --threshold 0; [ "$RC" = 1 ] && ok "[D] red when over the threshold (1 dead > 0)" || bad "[D] over the threshold: rc $RC"
  dg "$p" "$W" --threshold 5; [ "$RC" = 0 ] && ok "[D] green when under the threshold (1 dead <= 5)" || bad "[D] under the threshold: rc $RC"
  dg "$p" "$W" --threshold 1; [ "$RC" = 0 ] && ok "[D] green exactly at the threshold (1 dead <= 1)" || bad "[D] at the threshold: rc $RC"
  local CL W2; CL=$(mktemp -d "$TMP/c.XXXXXX"); mv "$CL" "$CL.git"; CL="$CL.git"; G init -q --bare -b main "$CL"
  W2=$(mktemp -d "$TMP/w.XXXXXX"); G clone -q "$CL" "$W2" 2>/dev/null; G -C "$W2" symbolic-ref HEAD refs/heads/main; commit "$W2" a.txt base; G -C "$W2" push -q origin main
  dg "$p" "$W2" --threshold 0; [ "$RC" = 0 ] && ok "[D] a repo with no dead branch: green" || bad "[D] clean repo: rc $RC"
}

fam_config() {
  local p=$1 W
  setup; W=$WK
  dg "$p" "$W"; want 1 "[K] the default threshold is 0: one dead branch is red"
  put_cfg "$W" '{"dead_branches": {"max_merged_on_remote": 1}}'
  dg "$p" "$W"; want 0 "[K] dead_branches.max_merged_on_remote 1 from the config: green at the limit" "<= threshold 1"
  put_cfg "$W" '{"dead_branches": {"max_merged_on_remote": 0}}'
  dg "$p" "$W" --threshold 3; want 0 "[K] a flag overrides the config"
  # protected branches are never counted, even when they are merged into the main line
  G -C "$W" checkout -q -b release main; commit "$W" rel.txt rel; G -C "$W" checkout -q main; G -C "$W" merge -q --ff-only release; G -C "$W" push -q origin main release
  put_cfg "$W" '{}'
  dg "$p" "$W"; has_q 'origin/release' && ok "[K] a merged branch named release is deletable by default" || bad "[K] release is not listed: $OUT"
  [ "$(num "$OUT" 'deletable')" = 2 ] && ok "[K] …so the count is 2" || bad "[K] count with release: $(num "$OUT" 'deletable')"
  put_cfg "$W" '{"branch": {"protected": ["main", "release"]}}'
  dg "$p" "$W"; [ "$(num "$OUT" 'deletable')" = 1 ] && ok "[K] branch.protected adds release: not counted any more (1)" || bad "[K] protected not honoured: $(num "$OUT" 'deletable')"
  has_q 'origin/release' && bad "[K] a protected branch is listed" || ok "[K] …and not listed"
  # the intent prefix
  put_cfg "$W" '{"branch": {"intent_prefix": "work/"}}'
  dg "$p" "$W"; [ "$(num "$OUT" 'open intent branch')" = 0 ] && ok "[K] branch.intent_prefix work/: intent/rework is not an open intent any more (0 in use)" || bad "[K] prefix ignored: $(num "$OUT" 'open intent branch')"
  # the main line is the first protected branch that exists on the remote; master here, no main
  local CL W2 M; CL=$(mktemp -d "$TMP/m.XXXXXX"); mv "$CL" "$CL.git"; CL="$CL.git"; G init -q --bare -b master "$CL"
  W2=$(mktemp -d "$TMP/w.XXXXXX"); G clone -q "$CL" "$W2" 2>/dev/null; G -C "$W2" symbolic-ref HEAD refs/heads/master; commit "$W2" a.txt base
  G -C "$W2" checkout -q -b old; commit "$W2" o.txt o; G -C "$W2" checkout -q master; G -C "$W2" merge -q --ff-only old; G -C "$W2" push -q origin master old
  dg "$p" "$W2"; want 1 "[K] a repo whose main line is master: found through branch.protected, one dead branch (old)" "origin/old"
  dg "$p" "$W2" --main nope; want 2 "[K] --main that does not exist on the remote: rc 2"
  dg "$p" "$W2" --main master; want 1 "[K] --main master is accepted"
}

fam_base() {
  local p=$1 W
  setup; W=$WK; G -C "$W" checkout -q main; commit_cfg "$W" '{"dead_branches": {"max_merged_on_remote": 0}}' "base: config"; G -C "$W" branch base
  G -C "$W" checkout -q -b pr; commit_cfg "$W" '{"dead_branches": {"max_merged_on_remote": 99}}' "head: relax the limit"
  dg "$p" "$W" --config-ref base; want 1 "[B] a PR that raises dead_branches.max_merged_on_remote is judged by the base: red" "threshold 0"
  dg "$p" "$W"; want 0 "[B] control: without the ref the head's config applies: green"
  dg "$p" "$W" --config-ref no-such-ref; want 2 "[B] a ref that does not read: rc 2, not green"
  put_cfg "$W" '{"dead_branches": {"max_merged_on_remote": -1}}'
  dg "$p" "$W"; want 65 "[B] an invalid config is rc 65 and names the key" dead_branches.max_merged_on_remote
  put_cfg "$W" '{"branch": {"protected": "main"}}'
  dg "$p" "$W"; want 65 "[B] an invalid branch.protected is rc 65" branch.protected
  dg "$p" "$W" --bogus; want 64 "[B] an unknown flag is rc 64"
  dg "$p" "$W" --threshold abc; want 64 "[B] a threshold that is not a number is rc 64"
  dg "$p" "$W" --threshold; want 64 "[B] a flag with no value is rc 64"
  dg "$p" "$W" --config-ref ""; want 64 "[B] an empty --config-ref is rc 64 (it must not fall back to the working tree)"
  dg "$p" "$TMP"; want 2 "[B] not a git repo: rc 2" "not a git repo"
  local E; E=$(mk_repo norem); dg "$p" "$E"; want 2 "[B] a repo with no remote main line: rc 2, not green"
}

FAMILIES="fam_hub fam_config fam_base"
for f in $FAMILIES; do "$f" "$PLUGIN"; done

echo "== planted breaks: each turns its family red =="
D=dead_branches.sh
BRKG order-swapped fam_hub '[D] positive: feature/done' $D '  if is_in "$b" "$merged_main"; then
    dead="$dead$b"$'"'"'\n'"'"'           # group 1: deletable
    continue
  fi' '  if false; then
    continue
  fi'
BRKG symref-counted fam_hub '[D] after fetch:' $D "  | awk -F'\\t' '\$2 == \"\" { print \$1 }' | grep -vxF \"\$MAIN_REF\" || true)" "  | awk -F'\\t' '{ print \$1 }' | grep -vxF \"\$MAIN_REF\" || true)"
BRKG threshold-off-by-one fam_hub '[D] at the threshold' $D 'if [ "$n_dead" -gt "$THRESHOLD" ]; then' 'if [ "$n_dead" -ge "$THRESHOLD" ]; then'
BRKG threshold-never-red fam_hub '[D] over the threshold' $D 'if [ "$n_dead" -gt "$THRESHOLD" ]; then' 'if false; then'
BRKG deletes-the-branches fam_hub '[D] the gate deleted a branch' $D 'printf '"'"'\ncleanup command - read the list above' 'g push "$REMOTE" --delete ${dead//$REMOTE\//} >/dev/null 2>&1 || true
printf '"'"'\ncleanup command - read the list above'
BRKG no-cleanup-printed fam_hub '[D] no cleanup command' $D "printf '\\n  git push %s --delete \\\\\\n' \"\$REMOTE\"" ":"
BRKG config-threshold-ignored fam_config '[K] dead_branches.max_merged_on_remote 1 from the config' $D '[ -n "$THRESHOLD" ] || THRESHOLD="$(cfg dead_branches.max_merged_on_remote)" || exit $?' '[ -n "$THRESHOLD" ] || THRESHOLD=0'
BRKG flag-ignored fam_config '[K] a flag overrides the config' $D '[ -n "$THRESHOLD" ] || THRESHOLD=' 'THRESHOLD='
BRKG protected-ignored fam_config '[K] protected not honoured' $D '  all_branches=$(printf '"'"'%s\n'"'"' "$all_branches" | grep -vxF "$REMOTE/$b" || true)' '  :'
BRKG prefix-literal fam_config '[K] prefix ignored' $D '    "$REMOTE/$PREFIX"*) ;;' '    "$REMOTE/intent/"*) ;;'
BRKG main-literal fam_config '[K] a repo whose main line is master' $D 'MAIN_REF="$REMOTE/$MAIN"' 'MAIN=main; MAIN_REF="$REMOTE/main"'
BRKG config-from-head fam_base '[B] a PR that raises dead_branches' $D '${CONFIG_REF:+--config-ref "$CONFIG_REF"}' ''
BRKG bad-ref-green fam_base '[B] a ref that does not read' gate_common.py '        raise Infra("ref `%s` does not read" % ref)
    if git(["cat-file"' '        return None
    if git(["cat-file"'
BRKG config-error-swallowed fam_base '[B] an invalid config is rc 65' gate_common.py '        if probs:
            raise ConfigError(sdlc_config.render_problems(probs))
        return cfg' '        return cfg'
BRKG empty-ref-falls-back fam_base '[B] an empty --config-ref' $D '[ $# -ge 2 ] && [ -n "$2" ] || { echo "dead-branches: $1 needs a value" >&2; exit 64; }; CONFIG_REF="$2"' '[ $# -ge 2 ] || { echo "dead-branches: $1 needs a value" >&2; exit 64; }; CONFIG_REF="$2"'
BRKG usage-is-two fam_base '[B] an unknown flag is rc 64' $D "    *) printf 'dead-branches: unknown argument: %s\\n' \"\$1\" >&2; exit 64 ;;" "    *) printf 'dead-branches: unknown argument: %s\\n' \"\$1\" >&2; exit 2 ;;"
BRKG not-a-repo-green fam_base '[B] not a git repo: rc 2' $D "g rev-parse --git-dir >/dev/null 2>&1 || { printf 'dead-branches: %s is not a git repo\\n' \"\$REPO\" >&2; exit 2; }" "g rev-parse --git-dir >/dev/null 2>&1 || { printf 'dead-branches: %s is not a git repo\\n' \"\$REPO\" >&2; exit 0; }"

PLC="$TMP/break-none"; mk_plugin_copy "$PLC"
QN=0; okdef=$(declare -f ok); baddef=$(declare -f bad); sp=$PASS; sf=$FAIL
ok() { :; }; bad() { QN=$((QN+1)); }
for f in $FAMILIES; do "$f" "$PLC" >/dev/null 2>&1; done
eval "$okdef"; eval "$baddef"; PASS=$sp; FAIL=$sf
eq "$QN" 0 "control: an unbroken copy passes every family"

echo; summary
