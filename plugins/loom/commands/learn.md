---
description: Learn from EVERY unanalyzed session that used one plugin, across every project of the active config dir — or from ONE named session — improving it with both audit + enhance lenses. Bare <plugin> discovers matching sessions, then processes each one at a time, oldest first — analyze, expert-review, auto-implement approved improvements, commit per session — publishing one release when the backlog drains (--review confirms each session, --dry-run previews; --headless does exactly ONE session per invocation for the daily runner's loop); <plugin> <session-id> analyzes just that session interactively (skips discovery, leaves the ledger/watermark untouched). A per-plugin ledger + watermark ensures analyzed sessions are never redone.
argument-hint: <plugin-name> [session-id] [--dry-run] [--review] [--headless]
allowed-tools: [Bash, Read, Write, Edit, Skill, Task, AskUserQuestion]
---

# loom — learn from a plugin's sessions

Follow the `learn` skill end to end. Bare `<plugin>`: it discovers all unanalyzed sessions that used the
plugin, filters them through a per-plugin ledger + watermark, then processes each **one at a time,
oldest first** — one deep-analysis agent, an expert review, automatic implementation of approved
items, and a **commit per session** — publishing one release when the backlog drains (`--headless`
processes exactly one session per invocation; the daily runner loops it). With a session id: it
analyzes only that one session (both lenses) **interactively** and leaves the ledger/watermark
untouched.

Parse the arguments:

- **First token** = the plugin name to learn from (**required**; must be in this repo's
  `marketplace.json`). Discovery scans the active config dir; the implement + publish tail writes and
  releases **this** repo, so run with cwd = this marketplace repo.
- **Second token** = an optional session id (UUID) or transcript path → **single-session mode** (analyze
  only that session, both lenses, interactive confirm; no discovery, no ledger/watermark).
- **`--dry-run`** = batch mode only — discover and present the candidate sessions, no analysis agents, no
  ledger, no writes.
- **`--review`** = batch mode only — pause each session for confirmation before implementing its
  approved items (without it, approved items are implemented automatically).
- **`--headless`** = batch mode, for scheduled/unattended runs (`loom:automate` uses this) — never
  prompts (dead ends stop cleanly), overrides `--review`, and processes exactly **one** session per
  invocation, reporting how many remain so the runner can fire again with a fresh watchdog.

For a quick misbehavior-only pass on one session (the AUDIT lens alone), use `/loom:audit-plugin`.
Tracking (`/loom:track <plugin>`) is optional — it only makes batch discovery faster. `learn` works fully
without it via a full transcript scan.

Arguments provided: $ARGUMENTS
