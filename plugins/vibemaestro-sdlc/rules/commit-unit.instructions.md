---
applyWhen: "\bgit(?:\s+(?:-[Cc]\s+\S+|--[\w-]+(?:=\S+)?))*\s+commit(?![-\w])|\bgit(?:\s+(?:-[Cc]\s+\S+|--[\w-]+(?:=\S+)?))*\s+rebase(?![-\w])|\bgit(?:\s+(?:-[Cc]\s+\S+|--[\w-]+(?:=\S+)?))*\s+reset\b(?:[^|;&\n]|(?<=\\)\n)*--soft\b|\bgh(?:\s+(?:-R|--repo)[\s=]+\S+)?\s+pr(?:\s+(?:-R|--repo)[\s=]+\S+)?\s+ready\b"
description: "The commit unit (one task or one fix round, not one typing session), folding a fix round, fold before ready, and the rebase versus squash decision; only for commits no review has seen"
---

# The commit unit, rebase and squash

A commit is a finished, self-consistent piece of work that reverts alone, not a typing session. Everything below applies only to commits no review has seen (`git-process`: reviewed commits are immutable).

| Work | Leaves |
|---|---|
| a task, first pass | one commit: code, tests and docs of that task |
| a fix round after a review | one commit with all the round changed, docs included |
| steps whose order matters and that each revert alone (rename the API, move callers, delete the old path) | one commit per step |
| a merge that catches the branch up with main after a review | kept, never folded |

**Fold a fix round** into the last commit that is already on origin, not the tip of `origin/<branch>` (another session may have pushed there):

    git fetch origin <branch>
    BASE=$(git merge-base HEAD origin/<branch>)
    M=$(git rev-list --merges -1 "$BASE..HEAD")   # a catch-up merge made in this round
    git reset --soft "${M:-$BASE}" && git commit  # one message for the round; push without force

- Reset to the tip of `origin/<branch>` records the other session's files as deleted, and the push still fast-forwards: nothing goes red.
- Fold first, catch up with main after: folding across a catch-up merge flattens it and the PR diff swallows main's files.
- Push refused: fetch again, `git rebase --rebase-merges origin/<branch>` (plain `git rebase` drops merges), push. Never `git merge origin/<branch>`.

**Rebase or squash** are two questions. Rebase: am I standing on current main? (`git fetch origin main && git rebase origin/main`, then `git push --force-with-lease`; on a conflict outside your task, `git rebase --abort` and ask.) Squash: how many entries does main get? Both only before the first review. For each commit ask: can its subject be written as `type(scope): what was done` without lying, and would main stay green if history stopped there?

- Fails (wip, fix typo, address review, a catch-up merge made before the first review, a patch of the commit before): squash it away.
- Passes but holds unrelated work (the body needs "and"): split into PRs. Passes and serves one purpose: one commit, unless the steps are load-bearing (table).

        git fetch origin main
        git reset --soft "$(git merge-base HEAD origin/main)"   # the cut point, never origin/main
        git commit && git push --force-with-lease               # never --force

Resetting to the tip of main deletes what others merged. Check both: `git diff <sha-before> HEAD` is empty, and `git diff --name-status origin/main...HEAD` lists only your files (the first cannot see a reset to the tip).

**Fold before ready.** Before `gh pr ready` or the first review, fold the chain to one commit per task or round, after `git branch backup/<name>`; `git diff backup/<name> HEAD` must be empty; push with `--force-with-lease`. A chain kept on purpose is declared in the PR body with the `tokens.commit_exception` line, if the repo gates the commit count.
