# Changelog of vibemaestro-brain

Newest first. Each `## <version>` is a public release, written from the change notes it ships; the first public release is 0.1.0.

## 0.1.0

- patch: Skill, rule and contract text no longer carries dates, plan-row ids, issue numbers or pointers into the kit's private notes; what each step tells a session to do is unchanged.
- patch: The README describes the plugin as it is now: no plan rows, dates or internal paths, and the dependency on vibemaestro-sdlc without an old version floor.
- minor: No plugin carries a version in the private repo any more (an install follows the commit); the first public release numbers sdlc and brain 0.1.0, and the public tags are `<plugin>--v<version>`.
- patch: The README is written for one person with one Claude seat on one machine: one task or several with local-parallel, who merges, and a worker session named by INTENT_SLUG and SEAT; no other plugin or cluster is needed.
- minor: A session working alone reads a solo core: the coordinator and worker roles moved to the rule coordinated-work, delivered whole only in a sandbox session or where an enabled plugin of the same marketplace ships the marker file sdlc-coordinated; kb.py init records "language" in every new config (en unless answered) and init-kb recommends en; the init-kb branch is chore/kb-init (the old name is still found); the SessionStart hook arguments are core and context (the old ones still work); the BatonRun standard ships in the plugin as docs/batonrun.md; the marketplace description and open-pr.sh's --closes line are English.
- patch: Comments, help text and skill examples no longer point at the maintainers' private notes, issue numbers or dates; behaviour is unchanged.
- patch: `brain` now exits with rc 7 (not 3) when run outside a Claude Code session, so rc 3 only means "another session writes this brain" and the skill's table no longer sends you to `claim --take-over` for nothing.

## Private history (numbering retired 2026-10-20)

The numbers below were private and are not public releases; the version count starts again at 0.1.0.

### 0.3.1

- patch: The plugin README is rewritten for users, in English with a Vietnamese twin (`README.vi.md`): the problem, how the brain stores and re-injects hot memory, hooks, every `brain` command, cost model and the ladder.
- patch: Declare the Apache-2.0 licence in the plugin manifest (`license` field); the kit now ships a `LICENSE` and `NOTICE` at its root.

### 0.3.0

- minor: `brain matrix` and the `matrix` skill show what is installed and active in a session, `brain cost` reads token usage from the transcript, and the compaction log lines carry the cost.
