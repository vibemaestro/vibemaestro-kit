---
applyWhen: "\bgit\b(?:[^|;&\n]|(?<=\\)\n)*\bworktree[\s\\]+add\b|intent-branch\.sh[\x22\x27]?[\s\\]+worker-branch\b|\bgit(?:\s+(?:-[Cc]\s+\S+|--[\w-]+(?:=\S+)?))*\s+(?:rebase|merge)(?![-\w])|\bgit(?:\s+(?:-[Cc]\s+\S+|--[\w-]+(?:=\S+)?))*\s+commit\b(?:[^|;&\n]|(?<=\\)\n)*--amend\b|\bgit(?:\s+(?:-[Cc]\s+\S+|--[\w-]+(?:=\S+)?))*\s+push\b(?:[^|;&\n]|(?<=\\)\n)*(?:\s-[A-Za-z]*f[A-Za-z]*\b|--force|\s\+\S)"
description: "Git process: a worktree of its own inside the repo, one intent = one branch = one draft PR, one task = one commit, the commit message shape, no push to main, no force; reviewed commits are immutable, catch up with main by merge"
---

# Git process

1. **Every change is made in a worktree of its own, INSIDE the repo**: `<repo>/.claude/worktrees/<name>` (add `.claude/worktrees/` to
   `.git/info/exclude` if not ignored). Outside the repo, the session is asked for permission to read outside its working directory. Do not edit the main working tree or change its branch.
2. **One intent = one branch `intent/<date>-<slug>` = one draft PR.** Create the branch with the skill `intake` (the core
   `intent-branch.sh create-intent`), not with a bare `git checkout -b`: the core refuses when `kb/intent/<slug>.md` does not exist yet.
3. **A sub-task**: cut a sub-branch from the tip of `intent/*` with `intent-branch.sh worker-branch … --no-checkout`, then `git worktree add`; when
   done, integrate back with `intent-branch.sh integrate --to origin` FROM the worktree. The core rebases, then fast-forwards; never `git merge`
   without `--ff-only` when integrating a sub-branch (the linear history is lost and nothing turns red); to catch up with `main` see item 9.
4. **One task, one commit** (code + test + docs together); one round of fixes after a review, one commit; a sub-branch goes into the intent branch as
   one commit per task — squash to the cut point (the merge-base), not to the tip. Folding, rebasing or squashing: rule `commit-unit`.
5. **Commit with an explicit pathspec** (`git add <file>`), not `git add -A`. No `git push --force` (for a chain nobody has reviewed,
   `--force-with-lease`, see `commit-unit`), no push straight to `main`/`master`, no pushing a tag unless you were told to.
6. **Commit message**: subject ≤ 72 characters in the form `type(scope): what was done` (imperative), body at most 3 sentences: what changed, why, the
   trade-off. Do not narrate how you measured; measurements and evidence live in the PR/spec.
7. **Clean up after the PR merges**: remove the worktree and the sub-branch at once (`git worktree remove`, `git branch -d`).
8. **Reviewed commits are immutable.** A commit that a review round has seen is never rebased, squashed or amended: add a new commit. The chain is the record of the rounds, and review comments are pinned to commit SHAs: a rewrite replaces the SHA and orphans the comment, a merge only adds to the set. Rebase and squash belong to chains no review has seen (`commit-unit`).
9. **Catch up with main by merge.** A branch that stood still while main moved can silently revert main's change: its diff carries the old value and CI stays green because the old value passes too.

        git fetch origin && git merge origin/main     # not rebase: the SHAs stay
        git diff origin/main -- <file>                # any line you did not mean to change?

   A clean merge only means no textual conflict; reading the diff is the half that gets skipped. The price is one `Merge branch 'main'` commit, cheaper than orphaned review comments. Fold the round first (`commit-unit`), catch up after.
