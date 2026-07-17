---
description: harvest ALL un-harvested sessions of this project into reusable Claude Code artifacts (per-project ledger + watermark skip ones already done), or one session by id/path; --dry-run previews
argument-hint: [session-id | transcript .jsonl path | --dry-run]
allowed-tools: [Bash, Read, Write, Edit, Skill, Task, AskUserQuestion]
---

# loom — harvest automations

Analyze session(s) and extract reusable Claude Code artifacts that reduce future manual work.

Follow the `harvest-automations` skill end to end. The skill handles mode resolution, transcript
discovery, analysis, artifact generation, and user confirmation.

The argument below is **optional** and selects the mode:

- **empty** — **project-wide sweep**: harvest **every un-harvested session of the current project**
  (the active session is always included). A per-project ledger + watermark skip sessions already
  harvested, so re-runs only pick up new work.
- **`--dry-run`** — project-wide **discovery preview**: list what a real run would analyze; **nothing
  is written**, no agents run.
- a **session id** (a UUID, e.g. `e05bde45-3ed9-458d-9a2e-ba6744d64a18`) — **single session**: the
  skill resolves it to that session's transcript under the Claude config dir's `projects/`, and
  ledgers it (without moving the watermark).
- a **path** to a transcript `.jsonl` — **single session**, used directly.

$ARGUMENTS
