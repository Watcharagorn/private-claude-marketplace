---
description: Learn from EVERY unanalyzed session that used one plugin, machine-wide — or from ONE named session — improving it with both audit + enhance lenses. Bare <plugin> discovers matching sessions across all project folders, deep-analyzes each in its own agent, merges, then one review → one confirm → one publish; <plugin> <session-id> analyzes just that session (skips discovery, leaves the ledger/watermark untouched). A per-plugin ledger + watermark ensures analyzed sessions are never redone.
argument-hint: <plugin-name> [session-id] [--dry-run]
allowed-tools: [Bash, Read, Write, Edit, Skill, Task, AskUserQuestion]
---

# loom — learn from a plugin's sessions

Follow the `learn` skill end to end. Bare `<plugin>`: it discovers all unanalyzed sessions that used the
plugin, filters them through a per-plugin ledger + watermark, dispatches one deep-analysis agent per
session, merges findings across sessions, and runs a single review → confirm → implement → publish. With
a session id: it analyzes only that one session (both lenses) and leaves the ledger/watermark untouched.

Parse the arguments:

- **First token** = the plugin name to learn from (**required**; must be in this repo's
  `marketplace.json`). Discovery scans the active config dir; the implement + publish tail writes and
  releases **this** repo, so run with cwd = this marketplace repo.
- **Second token** = an optional session id (UUID) or transcript path → **single-session mode** (analyze
  only that session, both lenses; no discovery, no ledger/watermark).
- **`--dry-run`** = batch mode only — discover and present the candidate sessions, no analysis agents, no
  ledger, no writes.

For a quick misbehavior-only pass on one session (the AUDIT lens alone), use `/loom:audit-plugin`.
Tracking (`/loom:track <plugin>`) is optional — it only makes batch discovery faster. `learn` works fully
without it via a full transcript scan.

Arguments provided: $ARGUMENTS
