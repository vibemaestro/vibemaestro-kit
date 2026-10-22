---
applyWhen: "\bacme-release\b"
description: "Example command rule: the release tool needs a clean tree and a tag from the main branch"
---

# Example release command rule

Run the release tool from a clean tree on the main branch and tag the exact commit it builds. Do not release from a worktree
that carries unrelated changes.
