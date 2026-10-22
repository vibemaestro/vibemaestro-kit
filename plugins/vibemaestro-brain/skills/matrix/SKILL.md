---
name: matrix
description: "Print the Brain Matrix: what vibemaestro-brain holds in each cell (Know/Do × hot/warm/cold) and what it did in this session. User-invoked only (/matrix)."
disable-model-invocation: true
---

# matrix — the Brain Matrix for the owner

Run this one command and show its output as it is, in a code block, with no summary in place of it:

```bash
brain matrix
```

Seven rows, one per cell (Do·warm has two: the Workbench and code intelligence (external)), each `cell | store | size chars
(≈tokens) | loaded when | forgetting rule | last consolidated | survives compaction | warnings`, then what the brain did in this
session: hook lines per event, characters injected, compactions with the last trigger and context size, the last loss score,
the last `cost` line, and the `--bulk`, `--shorter` and `--drop-anchor` ops.

- The token column is characters ÷ 4, not calibrated.
- The Know·hot cell lists the repo index (shared, injected by vibemaestro-sdlc when its `current_state.inject` is on): the brain only lists it.
- The code intelligence row lists enabled plugins (`*-lsp`, `.lsp.json` or `lspServers`, serena); the kit ships no code for it.
- If `brain` is not on PATH, the plugin is not enabled in this session: say so; do not run its script by hand.
