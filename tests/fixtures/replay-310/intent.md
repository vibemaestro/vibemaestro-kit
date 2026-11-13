---
type: story
focus: P7
spec: kb/specs/2026-11-06-batch-approval.md
description: "Batch approval: the owner approves a batch once (a recast of a real drop; Wanted 1 to 5 as AC1 to AC5)"
---

# Batch approval: one owner dialog per batch

## Story

As an owner, I want to approve a batch once, so that the coordinator runs and verifies every act inside it without another signature.

## Acceptance criteria

1. **AC1: One approval per batch.** At the gate (or in chat, for small work), the owner's approval becomes one dialog that covers the batch's merges and its steps. ("One approval per batch")
2. **AC2: Scope, not bytes, where it is safe.** A step matches by repository, name, field patterns and expiry, so a rerun after a fix stays inside. ("Scope, not bytes, where it is safe")
3. **AC3: Values under a batch.** A step may ask the owner for a value; the owner types or uploads it on the entry page with no signature. ("Values under a batch")
4. **AC4: One passphrase per batch.** The batch's sitting keeps the passphrase, or the unlocked key, for the batch's life. ("phải cho giữ mật khẩu chứ")
5. **AC5: The owner still sees everything.** Every run is post-checked and logged; a daily digest lists what ran under each batch. ("The owner still sees everything")

## Not doing

None.

## Measure

Replay one day as a scenario: how many owner acts the new design needs. The target is at most one per batch, plus value entries.
