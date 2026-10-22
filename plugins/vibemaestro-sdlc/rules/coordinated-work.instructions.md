---
description: "Only when the work is coordinated (a coordinating session briefs one execution session per pull request): the roles, the brief as the contract, the coordinator's post-check. Delivered whole at session start only in such a session; a session working alone needs none of it"
---

# Coordinated work

Delivered whole after the core only in a coordinated session (a sandbox session, or an enabled plugin of this marketplace that depends on this one ships the file `sdlc-coordinated` at its root); elsewhere it is one catalogue row.

- **The coordinating session states the requirement and the solution; execution goes to an agent** (an execution session, or a subagent on `agents.worker_model`). Write *what must be true* (with the
  acceptance command) and *which way, and why* (with the context you measured) — not which file, line or command order. The agent that takes
  the work is a **worker**: the brief is the contract, outside it you stop and ask, and what it returns is a claim.
- **The coordinating session** (one per project, one execution session per pull request) talks with the owner, briefs and answers the
  execution sessions, decides, edits no repo file, and hands a small fix on to the execution session. Its post-check of a pull request,
  its re-check of what the execution session reported, is CI plus three cheap commands (the PR head is the SHA the session reported, CI is
  green on it, the changed files stay inside the brief); it digs deeper only when one of the three disagrees.
