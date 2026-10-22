#!/bin/bash
# =============================================================================
# Core of the intent-branch lifecycle (intent_branch.py), as it is today
# =============================================================================
# Run: bash tests/test-core-branch.sh
#
# Ports the families of two hub suites: the branch-lifecycle suite and, from the worker
# suite, the only family that reaches this core (parallel workers leave no merge commit). Real git on throw-away repositories
# with a bare origin; no network; no gh (the issue paths have their own suite). The core under test is a COPY of the plugin
# (the real one first, then one copy per planted break), so the suite proves it can go red.
#
# Exit codes asserted: 0 done, 2 environment, 3 missing intent record, 4 BLOCK (conflict, --no-rebase, push refused, ff
# refused), 5 base or target unusable, 6 branch exists, 7 wrong tree or protected source or repo-location variable, 64 usage.
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
TMP=$(mktemp -d); TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
clean_env "$TMP"

fam_gate() {  # create-intent: the record gate, duplicates, usage
  PLX=$1; local W S out rc; W=$(mk_origin); S=2026-01-01-gate
  out=$(core "$W" create-intent --slug "$S" 2>&1); rc=$?
  eq "$rc" 3 "[B1] no kb/intent/<slug>.md: rc 3"
  ref_exists "$W" "intent/$S" && bad "[B1] a branch exists although the gate refused" || ok "[B1] …and no branch was created"
  : > "$W/kb/intent/$S.md"
  core "$W" create-intent --slug "$S" >/dev/null 2>&1; eq "$?" 3 "[B1] empty record: rc 3 (a placeholder file is not a record)"
  printf 'text\n' > "$W/kb/intent/$S.md"
  out=$(core "$W" create-intent --slug "$S" 2>/dev/null); rc=$?
  eq "$rc" 0 "[B1] record present: rc 0"; eq "$out" "intent/$S" "[B1] stdout is exactly the branch name"
  eq "$(git_ -C "$W" symbolic-ref --short HEAD)" "intent/$S" "[B1] without --no-checkout the new branch is checked out"
  core "$W" create-intent --slug "$S" >/dev/null 2>&1; eq "$?" 6 "[B1] the branch exists: rc 6"
  git_ -C "$W" checkout -q main
  local S2=2026-01-01-origin-only
  printf 'text\n' > "$W/kb/intent/$S2.md"
  core "$W" create-intent --slug "$S2" --no-checkout >/dev/null 2>&1; eq "$?" 0 "[B1] --no-checkout: rc 0"
  eq "$(git_ -C "$W" symbolic-ref --short HEAD)" main "[B1] --no-checkout leaves HEAD alone"
  git_ -C "$W" push -q origin "intent/$S2"; git_ -C "$W" branch -q -D "intent/$S2"
  core "$W" create-intent --slug "$S2" >/dev/null 2>&1; eq "$?" 6 "[B1] the branch exists only on origin: rc 6"
  printf 'text\n' > "$W/kb/intent/2026-01-01-slash.md"
  core "$W" create-intent --slug "2026-01-01-slash/x" >/dev/null 2>&1; eq "$?" 64 "[B1] a slash inside the slug: rc 64"
  core "$W" create-intent --slug 2026-01-01-slash --base origin/nothing >/dev/null 2>&1; eq "$?" 5 "[B1] a base that does not exist: rc 5"
  ref_exists "$W" intent/2026-01-01-slash && bad "[B1] a branch exists after the rc 5" || ok "[B1] …and no branch was created"
  core "$W" create-intent --slug "intent/2026-01-01-slash" --no-checkout >/dev/null 2>&1
  eq "$?" 0 "[B1] a slug given with the intent/ prefix is the same slug"
  core "$(fresh)" create-intent --slug "$S" >/dev/null 2>&1; eq "$?" 2 "[B1] not a git repository: rc 2"
  cenv python3 "$PLX/scripts/intent_branch.py" --cwd "$W" >/dev/null 2>&1; eq "$?" 64 "[B1] no subcommand: rc 64"
  core "$W" create-intent >/dev/null 2>&1; eq "$?" 2 "[B1] required --slug missing: rc 2 (argparse)"
}

fam_worker() {  # worker-branch: cut from the tip of the intent, not from main
  PLX=$1; local W S out rc TIP; W=$(mk_origin); S=2026-01-02-worker
  new_intent "$W" "$S"
  git_ -C "$W" checkout -q "intent/$S"; commit_in "$W" pm.txt "pm work" "pm beat"; git_ -C "$W" push -q origin "intent/$S"; git_ -C "$W" checkout -q main
  TIP=$(git_ -C "$W" rev-parse "origin/intent/$S")
  ne "$TIP" "$(git_ -C "$W" rev-parse main)" "[B2] instrument: the intent tip differs from main (so a cut from main would show)"
  out=$(core "$W" worker-branch --intent "$S" --name feat/w1 --no-checkout 2>/dev/null); rc=$?
  eq "$rc" 0 "[B2] worker-branch --no-checkout from the main tree: rc 0"; eq "$out" feat/w1 "[B2] stdout is the branch name"
  eq "$(git_ -C "$W" rev-parse feat/w1)" "$TIP" "[B2] the branch sits on the intent tip"
  eq "$(git_ -C "$W" symbolic-ref --short HEAD)" main "[B2] HEAD stays on main"
  core "$W" worker-branch --intent "intent/$S" --name feat/w2 --no-checkout >/dev/null 2>&1; eq "$?" 0 "[B2] --intent with the intent/ prefix is accepted"
  core "$W" worker-branch --intent 2026-01-02-nothing --name feat/w9 --no-checkout >/dev/null 2>&1; eq "$?" 5 "[B2] unknown intent: rc 5"
  core "$W" worker-branch --intent "$S" --name intent/another >/dev/null 2>&1; eq "$?" 64 "[B2] a task branch named intent/...: rc 64"
  core "$W" worker-branch --intent "$S" --name feat/w1 --no-checkout >/dev/null 2>&1; eq "$?" 6 "[B2] the name exists locally: rc 6"
  git_ -C "$W" push -q origin feat/w1; git_ -C "$W" branch -q -D feat/w1
  core "$W" worker-branch --intent "$S" --name feat/w1 --no-checkout >/dev/null 2>&1; eq "$?" 6 "[B2] the name exists only on origin: rc 6"
  core "$W" worker-branch --intent "$S" >/dev/null 2>&1; eq "$?" 2 "[B2] required --name missing: rc 2 (argparse)"
  # origin is read before the local branch: a stale local intent branch must not be the cut point
  git_ -C "$W" branch -q -f "intent/$S" main
  core "$W" worker-branch --intent "$S" --name feat/fresh --no-checkout >/dev/null 2>&1
  eq "$(git_ -C "$W" rev-parse feat/fresh)" "$TIP" "[B2] origin/intent/<slug> wins over a stale local intent branch"
  core "$W" worker-branch --intent "$S" --name feat/ref --no-checkout --intent-ref main >/dev/null 2>&1
  eq "$(git_ -C "$W" rev-parse feat/ref)" "$(git_ -C "$W" rev-parse main)" "[B2] --intent-ref names the cut point explicitly"
  core "$(fresh)" worker-branch --intent "$S" --name feat/x >/dev/null 2>&1; eq "$?" 2 "[B2] not a git repository: rc 2"
}

fam_tree() {  # worker-branch with checkout is refused in the main tree and when a repo-location variable is set
  PLX=$1; local W S out rc TIP WT S0; W=$(mk_origin); S=2026-01-03-tree
  new_intent "$W" "$S"; TIP=$(git_ -C "$W" rev-parse "origin/intent/$S")
  echo "unfinished work of another session" > "$W/dirty.txt"
  S0=$(snap "$W")
  out=$(core "$W" worker-branch --intent "$S" --name feat/t1 2>&1); rc=$?
  eq "$rc" 7 "[B3] main tree, checkout requested: rc 7"
  ref_exists "$W" feat/t1 && bad "[B3] the branch was created although refused" || ok "[B3] …no branch was created"
  eq "$(snap "$W")" "$S0" "[B3] …HEAD, refs, reflog and status of the main tree are unchanged"
  eq "$([ -f "$W/dirty.txt" ] && echo kept)" kept "[B3] …the other session's file is still there"
  eq "$(printf '%s\n' "$out" | grep -F 'git worktree add' | grep -cF -- "$(git_ -C "$W" rev-parse --show-toplevel)/.claude/worktrees/")" 1 "[B3] the message names a git worktree add path INSIDE this clone"
  has "$out" "--no-checkout" "[B3] …and the --no-checkout alternative"
  WT="$W/../wt-link"; git_ -C "$W" worktree add -q -b wt/link "$WT" origin/main
  out=$(core "$WT" worker-branch --intent "$S" --name feat/t2 2>/dev/null); rc=$?
  eq "$rc" 0 "[B3] linked worktree, checkout requested: rc 0"; eq "$out" feat/t2 "[B3] …stdout is the branch name"
  eq "$(git_ -C "$WT" symbolic-ref --short HEAD)" feat/t2 "[B3] …the worktree is now on the new branch"
  eq "$(git_ -C "$WT" rev-parse HEAD)" "$TIP" "[B3] …cut from the intent tip"
  eq "$(git_ -C "$W" symbolic-ref --short HEAD)" main "[B3] …the main tree stays on main"
  S0=$(snap "$W")
  out=$(cenv GIT_DIR="$W/.git" GIT_WORK_TREE="$W" python3 "$PLX/scripts/intent_branch.py" --cwd "$WT" worker-branch --intent "$S" --name feat/t3 2>&1); rc=$?
  eq "$rc" 7 "[B3] GIT_DIR and GIT_WORK_TREE aimed at the main tree, --cwd a linked worktree: rc 7"
  ref_exists "$W" feat/t3 && bad "[B3] a branch was created under the variables" || ok "[B3] …no branch was created"
  cenv python3 "$PLX/scripts/intent_branch.py" --cwd "$WT" worker-branch --intent "$S" --name feat/clean >/dev/null 2>&1
  eq "$?" 0 "[B3] control: the same call with no variable set: rc 0"
}

fam_submodule() {  # a submodule is not a linked worktree: integrate and worker-branch refuse there too
  PLX=$1; local D W S SUBW out; D=$(fresh); S=2026-01-04-sub
  git_ init -q --bare -b main "$D/sub.git"; git_ clone -q "$D/sub.git" "$D/seed" 2>/dev/null
  commit_in "$D/seed" a.txt a "seed"; git_ -C "$D/seed" branch -M main; git_ -C "$D/seed" push -q origin main
  git_ -C "$D/seed" checkout -q -b "intent/$S"; commit_in "$D/seed" b.txt b "intent"; git_ -C "$D/seed" push -q origin "intent/$S"
  W=$(mk_origin)
  git_ -C "$W" -c protocol.file.allow=always submodule add -q "$D/sub.git" sub >/dev/null 2>&1
  SUBW="$W/sub"
  [ -e "$SUBW/.git" ] && ok "[B4] instrument: the submodule exists" || bad "[B4] instrument: the submodule was not created"
  ref_exists "$SUBW" "origin/intent/$S" && ok "[B4] instrument: the submodule clone sees the intent branch" || bad "[B4] instrument: no intent branch in the submodule"
  git_ -C "$SUBW" branch -q feat/s origin/main
  out=$(core "$SUBW" integrate --intent "$S" --branch feat/s --to origin 2>&1); eq "$?" 7 "[B4] integrate from a submodule: rc 7"
  out=$(core "$SUBW" worker-branch --intent "$S" --name feat/s2 2>&1); eq "$?" 7 "[B4] worker-branch with checkout in a submodule: rc 7"
  ref_exists "$SUBW" feat/s2 && bad "[B4] a branch was created in the submodule" || ok "[B4] …no branch was created"
}

fam_origin() {  # integrate --to origin: parallel workers, rebase, no merge commit, push refused
  PLX=$1; local W S out rc W1 W2 W3 FILES; W=$(mk_origin); S=2026-01-05-origin
  new_intent "$W" "$S"
  W1=$(task_wt "$W" feat/w1 "$S" 1); W2=$(task_wt "$W" feat/w2 "$S" 1)
  out=$(core "$W1" integrate --intent "$S" --branch feat/w1 --to origin 2>/dev/null); rc=$?
  eq "$rc" 0 "[B5] worker 1 integrates: rc 0"; has "$out" "origin/intent/$S" "[B5] …stdout names the target"
  out=$(core "$W2" integrate --intent "$S" --branch feat/w2 --to origin 2>/dev/null); rc=$?
  eq "$rc" 0 "[B5] worker 2, whose branch is older than the tip, integrates by rebase: rc 0"
  git_ -C "$W" fetch -q origin
  FILES=$(git_ -C "$W" ls-tree -r --name-only "origin/intent/$S")
  has "$FILES" feat-w1-1.txt "[B5] the work of worker 1 is on origin/intent"; has "$FILES" feat-w2-1.txt "[B5] the work of worker 2 is on origin/intent"
  eq "$(merges_in "$W" "origin/intent/$S")" 0 "[B5] git log --merges on the intent is empty"
  eq "$(git_ -C "$W" rev-list --count "origin/intent/$S..feat/w2")" 0 "[B5] the intent contains the rebased branch (history is linear)"
  # the branch is taken from HEAD when --branch is absent
  W3=$(task_wt "$W" feat/w3 "$S" 1)
  core "$W3" integrate --intent "$S" --to origin >/dev/null 2>&1; eq "$?" 0 "[B5] --branch absent: the checked-out branch is integrated"
  # --no-fetch reads the cached origin ref, so a push after origin moved is refused (BLOCK), and the core never forces
  local W5 REM0; W5=$(task_wt "$W" feat/w5 "$S" 1)
  bump_origin "$W" "$S" later.txt
  REM0=$(git_ -C "$W" ls-remote origin "refs/heads/intent/$S" | cut -f1)
  core "$W5" integrate --intent "$S" --branch feat/w5 --to origin --no-fetch >/dev/null 2>&1; rc=$?
  eq "$rc" 4 "[B5] --no-fetch with a moved origin: the push is refused, rc 4"
  eq "$(git_ -C "$W" ls-remote origin "refs/heads/intent/$S" | cut -f1)" "$REM0" "[B5] …origin/intent did not move"
  core "$W5" integrate --intent "$S" --branch feat/w5 --to origin >/dev/null 2>&1; rc=$?
  eq "$rc" 0 "[B5] control: the same call with the fetch (default) rebases and lands: rc 0"
  # a refusing remote (pre-receive hook) is a BLOCK too
  local W6 REM1; W6=$(task_wt "$W" feat/w6 "$S" 1)
  printf '#!/bin/sh\nexit 1\n' > "$W/../origin.git/hooks/pre-receive"; chmod +x "$W/../origin.git/hooks/pre-receive"
  REM1=$(git_ -C "$W" ls-remote origin "refs/heads/intent/$S" | cut -f1)
  core "$W6" integrate --intent "$S" --branch feat/w6 --to origin >/dev/null 2>&1; eq "$?" 4 "[B5] origin refuses the push: rc 4"
  eq "$(git_ -C "$W" ls-remote origin "refs/heads/intent/$S" | cut -f1)" "$REM1" "[B5] …origin/intent did not move"
}

fam_conflict() {  # rc 4: a rebase conflict stops, leaves nothing behind, and writes no merge commit
  PLX=$1; local W S out rc V1 V2 REM0 REM1 HEAD0; W=$(mk_origin); S=2026-01-06-conflict
  new_intent "$W" "$S"; git_ -C "$W" checkout -q "intent/$S"; commit_in "$W" shared.txt base "base line"; git_ -C "$W" push -q origin "intent/$S"; git_ -C "$W" checkout -q main
  V1=$(task_wt "$W" feat/v1 "$S" 0); V2=$(task_wt "$W" feat/v2 "$S" 0)
  commit_in "$V1" shared.txt "worker 1 changes this line" "v1 edit"; commit_in "$V2" shared.txt "worker 2 changes this line" "v2 edit"
  core "$V1" integrate --intent "$S" --branch feat/v1 --to origin >/dev/null 2>&1; eq "$?" 0 "[B6] control: the first of two conflicting workers integrates: rc 0"
  REM0=$(git_ -C "$W" ls-remote origin "refs/heads/intent/$S" | cut -f1); HEAD0=$(git_ -C "$V2" rev-parse HEAD)
  out=$(core "$V2" integrate --intent "$S" --branch feat/v2 --to origin 2>&1); rc=$?
  eq "$rc" 4 "[B6] the second worker's rebase conflicts: rc 4 (BLOCK)"
  REM1=$(git_ -C "$W" ls-remote origin "refs/heads/intent/$S" | cut -f1)
  eq "$REM1" "$REM0" "[B6] …origin/intent did not move"
  eq "$(merges_in "$W" "origin/intent/$S")" 0 "[B6] …no merge commit was made"
  ref_exists "$V2" REBASE_HEAD && bad "[B6] …the worktree is stuck in a rebase" || ok "[B6] …the rebase was aborted (no REBASE_HEAD)"
  eq "$([ -d "$(git_ -C "$V2" rev-parse --absolute-git-dir)/rebase-merge" ] && echo stuck || echo clean)" clean "[B6] …no rebase-merge directory is left"
  eq "$(git_ -C "$V2" rev-parse HEAD)" "$HEAD0" "[B6] …the worker's branch is where it was"
  eq "$(git_ -C "$V2" status --porcelain | wc -l | tr -d ' ')" 0 "[B6] …the worktree is clean"
}

fam_norebase() {  # --no-rebase: a branch older than the tip is refused (rc 4), not repaired
  PLX=$1; local W S out rc E E2 HEAD0 LI0; W=$(mk_origin); S=2026-01-07-norebase
  new_intent "$W" "$S"
  E=$(task_wt "$W" feat/e1 "$S" 1)
  core "$E" integrate --intent "$S" --branch feat/e1 --to origin --no-rebase >/dev/null 2>&1
  eq "$?" 0 "[B7] control: --no-rebase on a branch that already contains the tip: rc 0"
  E2=$(task_wt "$W" feat/e2 "$S" 1); bump_origin "$W" "$S" moved.txt
  HEAD0=$(git_ -C "$E2" rev-parse HEAD); LI0=$(git_ -C "$W" rev-parse "intent/$S")
  core "$E2" integrate --intent "$S" --branch feat/e2 --to local --no-rebase >/dev/null 2>&1; rc=$?
  eq "$rc" 4 "[B7] --no-rebase with a stale branch: rc 4"
  eq "$(git_ -C "$E2" rev-parse HEAD)" "$HEAD0" "[B7] …the branch was not rebased"
  eq "$(git_ -C "$W" rev-parse "intent/$S")" "$LI0" "[B7] …and the local intent did not move"
  core "$E2" integrate --intent "$S" --branch feat/e2 --to local >/dev/null 2>&1; rc=$?
  eq "$rc" 0 "[B7] default: the same call rebases then fast-forwards: rc 0"
  eq "$(merges_in "$W" "intent/$S")" 0 "[B7] …without a merge commit"
  git_ -C "$W" ls-tree -r --name-only "intent/$S" | grep -qx 'feat-e2-1.txt' && ok "[B7] …and the work is on the intent" || bad "[B7] …the work is missing from the intent"
}

fam_local() {  # --to local: fast-forward the local intent branch; a branch held by another worktree; a diverged local branch
  PLX=$1; local W S out rc L1 L2 L3 L4 I0; W=$(mk_origin); S=2026-01-08-local
  new_intent "$W" "$S"
  L1=$(task_wt "$W" feat/l1 "$S" 1)
  out=$(core "$L1" integrate --intent "$S" --branch feat/l1 --to local 2>/dev/null); rc=$?
  eq "$rc" 0 "[B8] --to local: rc 0"; has "$out" "intent/$S" "[B8] …stdout names the intent"
  eq "$(git_ -C "$W" rev-parse "intent/$S")" "$(git_ -C "$W" rev-parse feat/l1)" "[B8] …the local intent is now at the branch tip"
  eq "$(merges_in "$W" "intent/$S")" 0 "[B8] …with no merge commit (fast-forward only)"
  release "$L1"; git_ -C "$W" branch -q -D "intent/$S"
  L2=$(task_wt "$W" feat/l2 "$S" 1)
  core "$L2" integrate --intent "$S" --branch feat/l2 --to local >/dev/null 2>&1; eq "$?" 0 "[B8] no local intent branch: it is created from the tip, rc 0"
  ref_exists "$W" "intent/$S" && ok "[B8] …and the local intent branch exists again" || bad "[B8] …no local intent branch was created"
  release "$L2"
  # the local intent is held by another worktree: only one worktree may hold a branch
  git_ -C "$W" checkout -q "intent/$S"
  L3=$(task_wt "$W" feat/l3 "$S" 1); I0=$(git_ -C "$W" rev-parse "intent/$S")
  core "$L3" integrate --intent "$S" --branch feat/l3 --to local >/dev/null 2>&1; eq "$?" 5 "[B8] the intent is checked out in the main tree: rc 5"
  eq "$(git_ -C "$W" rev-parse "intent/$S")" "$I0" "[B8] …the intent did not move"
  core "$L3" integrate --intent "$S" --branch feat/l3 --to origin >/dev/null 2>&1; eq "$?" 0 "[B8] control: the same state with --to origin: rc 0"
  git_ -C "$W" checkout -q main
  # a local intent branch that diverged from origin: the final --ff-only is refused (rc 4), nothing is merged
  git_ -C "$W" branch -q -f "intent/$S" "origin/intent/$S"
  git_ -C "$W" checkout -q "intent/$S"; commit_in "$W" local-only.txt x "local only"; git_ -C "$W" checkout -q main
  L4=$(task_wt "$W" feat/l4 "$S" 1); I0=$(git_ -C "$W" rev-parse "intent/$S")
  core "$L4" integrate --intent "$S" --branch feat/l4 --to local >/dev/null 2>&1; eq "$?" 4 "[B8] a diverged local intent: the fast-forward is refused, rc 4"
  eq "$(git_ -C "$W" rev-parse "intent/$S")" "$I0" "[B8] …the local intent is unchanged"
  eq "$(merges_in "$W" "intent/$S")" 0 "[B8] …and no merge commit exists"
}

fam_protected() {  # rc 7: the main tree, and main/master in every spelling, are refused BEFORE any fetch or rebase
  PLX=$1; local W S out rc I1 S0 S1 REM0 ref; W=$(mk_origin); S=2026-01-09-protected
  new_intent "$W" "$S"
  git_ -C "$W" branch -q feat/old main
  I1=$(task_wt "$W" feat/i1 "$S" 1)
  bump_origin "$W" "$S" ahead.txt
  echo "another session's work" > "$W/dirty.txt"
  S0=$(snap "$W"); REM0=$(git_ -C "$W" ls-remote origin "refs/heads/intent/$S" | cut -f1)
  out=$(core "$W" integrate --intent "$S" --to origin 2>&1); rc=$?
  eq "$rc" 7 "[B9] integrate in the main tree (on main): rc 7"
  eq "$(printf '%s\n' "$out" | grep -F 'git worktree add' | grep -cF -- "$(git_ -C "$W" rev-parse --show-toplevel)/.claude/worktrees/")" 1 "[B9] …the message names a worktree path inside this clone"
  eq "$(snap "$W")" "$S0" "[B9] …refs, reflog, status and remote refs of the main tree are unchanged"
  core "$W" integrate --intent "$S" --branch feat/old --to origin >/dev/null 2>&1; eq "$?" 7 "[B9] the main tree with --branch <child>: rc 7 (rebase would check the child out in place)"
  eq "$(snap "$W")" "$S0" "[B9] …and the main tree is unchanged"
  for ref in main master refs/heads/main refs/heads/master heads/main origin/main; do
    core "$I1" integrate --intent "$S" --branch "$ref" --to origin >/dev/null 2>&1; eq "$?" 7 "[B9] from a worktree, --branch $ref: rc 7"
  done
  eq "$(git_ -C "$W" ls-remote origin "refs/heads/intent/$S" | cut -f1)" "$REM0" "[B9] …origin/intent did not move"
  eq "$(snap "$W")" "$S0" "[B9] …and the guard ran before the fetch: the main tree's refs and reflog are unchanged"
  # HEAD on main in a linked worktree, no --branch
  local JM; git_ -C "$W" checkout -q --detach; JM="$W/../wt-main"; git_ -C "$W" worktree add -q "$JM" main
  local MAIN0; MAIN0=$(git_ -C "$W" rev-parse main)
  core "$JM" integrate --intent "$S" --to origin >/dev/null 2>&1; eq "$?" 7 "[B9] a linked worktree whose HEAD is main, no --branch: rc 7"
  eq "$(git_ -C "$W" rev-parse main)" "$MAIN0" "[B9] …main was not rewritten"
  core "$I1" integrate --intent "$S" --to origin >/dev/null 2>&1; eq "$?" 0 "[B9] control: a worktree on its own branch integrates: rc 0"
}

fam_envs() {  # repo-location variables are refused by integrate (rc 7) before any git command
  PLX=$1; local W S v K KW S0; W=$(mk_origin); S=2026-01-10-envs
  new_intent "$W" "$S"; git_ -C "$W" branch -q feat/free main
  KW=$(task_wt "$W" feat/kw "$S" 1); echo wip > "$W/dirty.txt"; S0=$(snap "$W")
  cenv GIT_DIR="$W/.git" GIT_WORK_TREE="$W" python3 "$PLX/scripts/intent_branch.py" --cwd "$KW" integrate --intent "$S" --branch feat/free --to origin >/dev/null 2>&1
  eq "$?" 7 "[B10] GIT_DIR and GIT_WORK_TREE aimed at the main tree, --cwd a worktree: rc 7"
  eq "$(snap "$W")" "$S0" "[B10] …the main tree is unchanged"
  for v in GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES; do
    cenv "$v=$W/.git" python3 "$PLX/scripts/intent_branch.py" --cwd "$KW" integrate --intent "$S" --branch feat/free --to origin >/dev/null 2>&1
    eq "$?" 7 "[B10] integrate with $v set: rc 7"
  done
  core "$KW" integrate --intent "$S" --branch feat/free --to origin >/dev/null 2>&1; eq "$?" 0 "[B10] control: the same call with no variable: rc 0"
  eq "$(git_ -C "$W" symbolic-ref --short HEAD)" main "[B10] …and the main tree is still on main"
}

fam_usage() {  # integrate: arguments and unusable targets
  PLX=$1; local W S T; W=$(mk_origin); S=2026-01-11-usage
  new_intent "$W" "$S"; T=$(task_wt "$W" feat/u1 "$S" 1)
  core "$T" integrate --intent "$S" --branch "intent/$S" --to origin >/dev/null 2>&1; eq "$?" 64 "[B11] the branch to integrate is the intent itself: rc 64"
  core "$T" integrate --intent "$S" --branch feat/nothing --to origin >/dev/null 2>&1; eq "$?" 5 "[B11] a branch that does not exist: rc 5"
  core "$T" integrate --intent 2026-01-11-none --branch feat/u1 --to origin >/dev/null 2>&1; eq "$?" 5 "[B11] an intent that exists nowhere: rc 5"
  git_ -C "$T" checkout -q --detach
  core "$T" integrate --intent "$S" --to origin >/dev/null 2>&1; eq "$?" 64 "[B11] detached HEAD and no --branch: rc 64"
  core "$T" integrate --intent "$S" --branch feat/u1 --to sideways >/dev/null 2>&1; eq "$?" 2 "[B11] --to must be local or origin: rc 2 (argparse)"
  core "$T" integrate --intent "$S" --branch feat/u1 >/dev/null 2>&1; eq "$?" 2 "[B11] --to is required: rc 2 (argparse)"
  core "$(fresh)" integrate --intent "$S" --branch feat/u1 --to origin >/dev/null 2>&1; eq "$?" 2 "[B11] not a git repository: rc 2"
}

fam_ffonly() {  # no code path calls git merge without --ff-only
  PLX=$1; local BARE
  BARE=$(grep -nE '"merge"' "$PLX/scripts/intent_branch.py" | grep -vF -e '--ff-only' -e 'merge-base' || true)
  empty "$BARE" "[B12] every merge call in the core carries --ff-only"
  grep -qF -e '"merge", "--ff-only"' "$PLX/scripts/intent_branch.py" && ok "[B12] instrument: the pattern finds the real merge call" || bad "[B12] instrument: the pattern finds no merge call"
}

fam_identity() {  # [B13] who commits the rebase inside integrate: rebase.identity, then git's own resolution, then rc 2
  PLX=$1; local W S W1 W2 OUT rc H0 R0 id
  # stale <var> — a fresh intent whose worker branch is older than the tip, so integrate must rebase it; sets W, S, W2
  stale() {
    W=$(mk_origin); S=2026-01-13-ident$1; new_intent "$W" "$S"
    W1=$(task_wt "$W" feat/w1 "$S" 1); W2=$(task_wt "$W" feat/w2 "$S" 1)
    core "$W1" integrate --intent "$S" --branch feat/w1 --to origin >/dev/null 2>&1
  }
  # integ <env NAME=value ...> — integrate W2 with NO ambient author or committer variable except the ones given.
  # user.useConfigOnly=true (through GIT_CONFIG_COUNT) turns off git's guess of an identity from the system user and the host
  # name, which succeeds on a host whose name has a domain: without it the "nothing resolves" cases would depend on the machine.
  integ() { ( cd "$W2" && cenv env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.useConfigOnly GIT_CONFIG_VALUE_0=true "$@" python3 "$PLX/scripts/intent_branch.py" --cwd "$W2" integrate --intent "$S" --branch feat/w2 --to origin ); }
  who() { git_ -C "$W2" log -1 --format='%cn <%ce>' feat/w2; }
  # 1. config wins over everything: an ambient committer, a git config identity
  stale a; git_ -C "$W" config user.name gitcfg-bot; git_ -C "$W" config user.email gitcfg@example.com
  mkdir -p "$W2/.vibemaestro"; printf '{"rebase": {"identity": {"name": "cfg-bot", "email": "cfg@example.com"}}}' > "$W2/.vibemaestro/sdlc.json"
  integ GIT_COMMITTER_NAME=env-bot GIT_COMMITTER_EMAIL=env@example.com >/dev/null 2>&1; rc=$?
  eq "$rc" 0 "[B13] rebase.identity with an ambient committer and a git config identity: rc 0"
  eq "$(who)" "cfg-bot <cfg@example.com>" "[B13] …the config identity commits the rebase, not the environment, not git config"
  # 2. the environment alone (a sandbox session): GIT_COMMITTER_NAME and GIT_COMMITTER_EMAIL, no git config, no config file
  stale b
  integ GIT_COMMITTER_NAME=env-bot GIT_COMMITTER_EMAIL=env@example.com >/dev/null 2>&1; rc=$?
  eq "$rc" 0 "[B13] only GIT_COMMITTER_NAME and GIT_COMMITTER_EMAIL in the environment: rc 0"
  eq "$(who)" "env-bot <env@example.com>" "[B13] …git's own resolution is used (the environment)"
  # 3. git config alone (a workstation)
  stale c; git_ -C "$W" config user.name gitcfg-bot; git_ -C "$W" config user.email gitcfg@example.com
  integ >/dev/null 2>&1; rc=$?
  eq "$rc" 0 "[B13] only git config user.name and user.email: rc 0"
  eq "$(who)" "gitcfg-bot <gitcfg@example.com>" "[B13] …git's own resolution is used (git config)"
  # 4. gpgsign: a global signing setup that cannot sign must not stop a machine commit
  stale d; git_ -C "$W" config user.name gitcfg-bot; git_ -C "$W" config user.email gitcfg@example.com
  git_ -C "$W" config commit.gpgsign true; git_ -C "$W" config gpg.program /bin/false
  integ >/dev/null 2>&1; rc=$?
  eq "$rc" 0 "[B13] commit.gpgsign=true with a signer that fails: the rebase still succeeds (rc 0)"
  eq "$(git_ -C "$W2" cat-file -p feat/w2 | grep -c '^gpgsig')" 0 "[B13] …and the rebased commit is not signed"
  # 5. nothing resolves: rc 2 before anything moves, with a hint that names both ways out
  stale e; H0=$(git_ -C "$W2" rev-parse feat/w2); R0=$(git_ -C "$W" ls-remote origin "refs/heads/intent/$S" | cut -f1)
  OUT=$(integ 2>&1 >/dev/null); rc=$?
  eq "$rc" 2 "[B13] no config identity, no committer in the environment, no git config: rc 2"
  has "$OUT" "rebase.identity" "[B13] …the message says to set rebase.identity"; has "$OUT" "user.name" "[B13] …or the git identity"
  eq "$(git_ -C "$W2" rev-parse feat/w2)" "$H0" "[B13] …the branch was not touched"
  eq "$(git_ -C "$W" ls-remote origin "refs/heads/intent/$S" | cut -f1)" "$R0" "[B13] …origin/intent did not move"
  ref_exists "$W2" REBASE_HEAD && bad "[B13] …a rebase was started" || ok "[B13] …no rebase was started"
  # GIT_AUTHOR_* alone is not a committer: git would die inside the rebase, so the core says rc 2 first
  stale f
  ( cd "$W2" && cenv env -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.useConfigOnly GIT_CONFIG_VALUE_0=true python3 "$PLX/scripts/intent_branch.py" --cwd "$W2" integrate --intent "$S" --branch feat/w2 --to origin ) >/dev/null 2>&1
  eq "$?" 2 "[B13] GIT_AUTHOR_* alone is no committer identity: rc 2"
  # a branch that needs no rebase never asks for an identity
  stale g; W3=$(task_wt "$W" feat/w3 "$S" 1)
  ( cd "$W3" && cenv env -u GIT_AUTHOR_NAME -u GIT_AUTHOR_EMAIL -u GIT_COMMITTER_NAME -u GIT_COMMITTER_EMAIL python3 "$PLX/scripts/intent_branch.py" --cwd "$W3" integrate --intent "$S" --branch feat/w3 --to origin ) >/dev/null 2>&1
  eq "$?" 0 "[B13] a branch that already contains the tip needs no identity: rc 0"
  # no variable of the old channel is read
  eq "$(grep -c -E 'VSDLC_' "$PLX/scripts/intent_branch.py" "$PLX/scripts/open_pr.py" | awk -F: '{s+=$2} END{print s+0}')" 0 "[B13] the cores read no VSDLC_ variable"
}

FAMILIES="fam_gate fam_worker fam_tree fam_submodule fam_origin fam_conflict fam_norebase fam_local fam_protected fam_envs fam_usage fam_ffonly fam_identity"

echo "== the real core =="
PL0="$TMP/plugin-real"; mk_plugin_copy "$PL0"
[ -f "$PL0/scripts/intent_branch.py" ] && ok "instrument: the plugin copy has the core" || bad "instrument: the core is missing from the copy"
for f in $FAMILIES; do echo "-- $f"; "$f" "$PL0"; done

echo "== planted breaks: each family must go red on a core with one break =="
BRK() {  # BRK <label> <family> <needle> <old> <new> — copy the plugin, plant one replacement in the core, expect red
  local d="$TMP/break-$1"; mk_plugin_copy "$d"
  mutate "$d/scripts/intent_branch.py" "$4" "$5" && expect_red "$1" "$2" "$d" "$3"
}
BRK missing-record-rc fam_gate '[B1] no kb' 'RC_ENV, RC_INTENT_FILE, RC_BLOCK, RC_TARGET, RC_EXISTS, RC_USAGE = 2, 3, 4, 5, 6, 64' 'RC_ENV, RC_INTENT_FILE, RC_BLOCK, RC_TARGET, RC_EXISTS, RC_USAGE = 2, 9, 4, 5, 6, 64'
BRK exists-rc fam_gate '[B1] the branch exists: rc 6' 'RC_ENV, RC_INTENT_FILE, RC_BLOCK, RC_TARGET, RC_EXISTS, RC_USAGE = 2, 3, 4, 5, 6, 64' 'RC_ENV, RC_INTENT_FILE, RC_BLOCK, RC_TARGET, RC_EXISTS, RC_USAGE = 2, 3, 4, 5, 1, 64'
BRK block-rc fam_conflict '[B6] the second worker' 'RC_ENV, RC_INTENT_FILE, RC_BLOCK, RC_TARGET, RC_EXISTS, RC_USAGE = 2, 3, 4, 5, 6, 64' 'RC_ENV, RC_INTENT_FILE, RC_BLOCK, RC_TARGET, RC_EXISTS, RC_USAGE = 2, 3, 1, 5, 6, 64'
BRK wrong-tree-rc fam_protected '[B9] integrate in the main tree' 'RC_WRONG_TREE = 7' 'RC_WRONG_TREE = 1'
BRK origin-before-local fam_worker '[B2] origin/intent' '["origin/" + intent_branch, intent_branch]' '[intent_branch, "origin/" + intent_branch]'
BRK checkout-guard-off fam_tree '[B3] main tree, checkout requested' 'rc = _refuse_checkout_in_main_tree(a)' 'rc = 0'
BRK env-guard-without-GIT_DIR fam_envs '[B10] integrate with GIT_DIR set' '("GIT_DIR", "GIT_WORK_TREE",' '("GIT_WORK_TREE",'
BRK protected-names-off fam_protected '[B9] from a worktree, --branch main' '        if n in PROTECTED:' '        if False:'
BRK no-rebase-ignored fam_norebase '[B7] --no-rebase with a stale branch' '        if a.no_rebase:' '        if False:'
BRK abort-removed fam_conflict '[B6] …the worktree is stuck' 'git("rebase", "--abort", cwd=a.cwd)' 'git("status", cwd=a.cwd)'
BRK push-forced fam_origin '[B5] --no-fetch with a moved origin' 'rc, out = git("push", "origin",' 'rc, out = git("push", "--force", "origin",'
BRK checkout-detached fam_local '[B8] …the local intent is now at the branch tip' 'rc, out = git("checkout", intent, cwd=a.cwd)' 'rc, out = git("checkout", "--detach", intent, cwd=a.cwd)'
BRK merge-without-ff-only fam_local '[B8] …with no merge commit' 'git("merge", "--ff-only", branch, cwd=a.cwd)' 'git("merge", "--no-ff", "-m", "merge", branch, cwd=a.cwd)'
BRK merge-without-ff-only-static fam_ffonly '[B12] every merge call' 'git("merge", "--ff-only", branch, cwd=a.cwd)' 'git("merge", "--no-ff", "-m", "merge", branch, cwd=a.cwd)'
BRK submodule-passes fam_submodule '[B4] integrate from a submodule' '    if not wt:
        err(M("ib.int_main_tree",' '    if False:
        err(M("ib.int_main_tree",'
BRK identity-config-ignored fam_identity '[B13] …the config identity commits the rebase' '    if REBASE_IDENTITY:' '    if False:'
BRK identity-env-outranks-config fam_identity '[B13] …the config identity commits the rebase' '        env = {"GIT_COMMITTER_NAME": n, "GIT_COMMITTER_EMAIL": e}' '        env = {}'
BRK identity-never-checked fam_identity '[B13] no config identity, no committer' '    return (args, env) if rc == 0 else None' '    return (args, env)'
BRK identity-check-ignores-env fam_identity '[B13] only GIT_COMMITTER_NAME and GIT_COMMITTER_EMAIL' '    rc, _ = git("var", "GIT_COMMITTER_IDENT", cwd=cwd)' '    rc, _ = git("config", "user.email", cwd=cwd)'
BRK gpgsign-not-disabled fam_identity '[B13] commit.gpgsign=true with a signer' '    args, env = ["-c", "commit.gpgsign=false"], {}' '    args, env = [], {}'
# the control of the instrument: an unbroken copy stays green on every family (the probe is not red by itself)
PLC="$TMP/break-none"; mk_plugin_copy "$PLC"
QN=0; okdef=$(declare -f ok); baddef=$(declare -f bad); sp=$PASS; sf=$FAIL
ok() { :; }; bad() { QN=$((QN+1)); }
for f in $FAMILIES; do "$f" "$PLC" >/dev/null 2>&1; done
eval "$okdef"; eval "$baddef"; PASS=$sp; FAIL=$sf
eq "$QN" 0 "control: an unbroken copy of the plugin passes every family (no failed check)"

echo; summary
