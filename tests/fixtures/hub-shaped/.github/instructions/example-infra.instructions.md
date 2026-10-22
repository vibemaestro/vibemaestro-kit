---
applyTo: "infrastructure/**,clusters/**"
description: "Example infrastructure rule: render the chart and read the diff before changing a manifest"
---

# Example infrastructure rule

Render the chart with the values of the target environment and read the diff of the rendered manifests before you change a
manifest under `infrastructure/`. A change that renders to the same output needs no review of the environment, and a change
that renders differently names the objects it touches in the commit message.
