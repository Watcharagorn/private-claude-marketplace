---
description: harvest ALL un-harvested sessions of this project one at a time, auto-folding passing artifacts in per session (per-project ledger + watermark skip ones already done; --review confirms each session, --dry-run previews), or interactively review one session by id/path
argument-hint: [session-id | transcript .jsonl path | --dry-run | --review | --headless]
allowed-tools: [Bash, Read, Write, Edit, Skill, Task, AskUserQuestion]
---

# loom — harvest automations

Analyze session(s) and extract reusable Claude Code artifacts that reduce future manual work.

Follow the `harvest-automations` skill end to end. The skill handles mode resolution, transcript
discovery, analysis, artifact generation, and folding.

The argument below is **optional** and selects the mode:

- **empty** — **project-wide sweep**: sequentially analyze **every un-harvested session of the current
  project** (oldest first; the active session always rides along) and **automatically fold in** each
  session's passing artifacts at project scope — no per-item prompts, only the cap question on >12
  sessions; review afterwards with `git diff`. Ledger + watermark advance after each session.
- **`--review`** — same sequential sweep, but each session pauses for interactive confirmation
  (cards + diffs) before folding.
- **`--dry-run`** — project-wide **discovery preview**: list what a real run would analyze; **nothing
  is written**, no agents run.
- **`--headless`** — project-wide, for scheduled/unattended runs (`loom:automate` uses this): never
  prompts (cap auto-defaults to Newest 12), skips the active session, overrides `--review`.
- a **session id** (a UUID, e.g. `e05bde45-3ed9-458d-9a2e-ba6744d64a18`) — **single session,
  interactive** (proposal cards + per-update confirmation — the manual escape hatch): the skill
  resolves it to that session's transcript under the Claude config dir's `projects/`, and ledgers it
  (without moving the watermark).
- a **path** to a transcript `.jsonl` — **single session, interactive**, used directly.

$ARGUMENTS
