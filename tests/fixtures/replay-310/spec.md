---
description: "Batch approval: one owner dialog signs a batch; the Goal lists AC1, AC2, AC3 and AC5, and the out-of-scope lines keep the shape of the original's"
---

# Batch approval: one owner dialog per batch

Intent: kb/intent/2026-11-06-batch-approval.md

## Bối cảnh

The owner asks to approve a batch once and have the coordinator run it. This version of the spec names no one-passphrase item.

## Mục tiêu

1. **AC1: One approval per batch.** One owner dialog signs a batch at a commit; it covers the batch's merges and its steps.
2. **AC2: Scope, not bytes, where it is safe.** A step matches by repository, name, field patterns and expiry, so a rerun after a fix stays inside.
3. **AC3: Values under a batch.** The owner types or uploads a value on the entry page with no signature.
4. **AC5: The owner still sees everything.** Every run is post-checked and logged; a daily digest lists what ran under each batch.

## Ngoài phạm vi

- A tooling update voids a pending per-run signature or a queued item: the acts under a batch signature no longer
  depend on it (Goal 1); per-run signatures stay as they are.
- One passphrase per batch and the sitting (Wanted 4): dropped with the grants; the passphrase is typed per act.
- Value patterns for runs (Wanted 2): a batch signature names steps and stops, never values ("không bám code").
- A standing batch for routines asked on the spot (the report chain): the design allows a batch whose rows recur within its life;
  whether to sign one is the owner's choice at that batch's own gate.
- The merge gate `review-done`: the coordinator's act per PR, not the owner's.
- Renaming `revoke` and `log --grants` (they serve approvals only once the first part lands); a later change.
- The vendored `risk-check` of repositories other than the main one: each takes the new copy by `install --update` in a PR of its
  own, an owner merge each (`.gates/` judges later PRs).

## Inputs and failure cases

| Input or failure | Expected behaviour | Test that proves it |
|---|---|---|
| a batch signed at a commit | the coordinator runs its rows | `bash tests/test-batch-approval.sh` |

## Tiêu chí chấp nhận

1. `bash tests/test-batch-approval.sh` → `[one-dialog] ok` → AC1
2. `bash tests/test-batch-approval.sh` → `[scope] ok` → AC2
3. `bash tests/test-batch-approval.sh` → `[values] ok` → AC3
4. `bash tests/test-batch-approval.sh` → `[digest] ok` → AC5
5. PR có mục `## Bằng chứng chạy`
