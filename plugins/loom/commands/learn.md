---
description: Learn from EVERY unanalyzed session that used one plugin, machine-wide, in a single command — discover matching sessions across all project folders, deep-analyze each in its own agent (audit + enhance), merge findings, then one review → one confirm → one publish of the target plugin. A per-plugin ledger + watermark ensures analyzed sessions are never redone.
argument-hint: <plugin-name> [--dry-run]
allowed-tools: [Bash, Read, Write, Edit, Skill, Task, AskUserQuestion]
---

# loom — learn from every session that used a plugin

Follow the `learn` skill end to end. It discovers all unanalyzed sessions that used the plugin, filters
them through a per-plugin ledger + watermark, dispatches one deep-analysis agent per session, merges
findings across sessions, and runs a single review → confirm → implement → publish.

Parse the arguments:

- **First token** = the plugin name to learn from (**required**; must be in this repo's
  `marketplace.json`). Discovery scans the active config dir; the implement + publish tail writes and
  releases **this** repo, so run with cwd = this marketplace repo.
- **`--dry-run`** = discover and present the candidate sessions only — no analysis agents, no ledger,
  no writes.

Tracking (`/loom:track <plugin>`) is optional — it only makes discovery faster. `learn` works fully
without it via a full transcript scan.

Arguments provided: $ARGUMENTS
