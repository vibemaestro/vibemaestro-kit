# Platform state

**Measured on 13/10/2026.**

## 1. Clusters

| Cluster | Status | What it is · read | Check |
|---|---|---|---|
| `acme-main` | running | The main example cluster · read: `kb/specs/example-api.md` | `check acme-main` |

## 2. What runs

| Area | Component | Status | What it is · where to read | Check |
|---|---|---|---|---|
| `example` | example-api | running | The public API of the example platform · read: `kb/specs/example-api.md` | `check example` |
| `example` | example-worker | in review | Background jobs of the API · read: `kb/specs/example-worker.md` | `check example-worker` |
| `jobs` | example-batch | off | Nightly batch, switched off · read: `kb/decisions/example-batch-off.md` | `check jobs` |

## 8. Not in place

| Item | Status | Where to read |
|---|---|---|
| Staging cluster for example-web | not built: no owner yet | `kb/decisions/example-no-staging.md` |
| Automatic end-to-end run | off: see the decision | `kb/decisions/example-no-e2e.md` |
