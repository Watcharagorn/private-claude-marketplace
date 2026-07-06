---
description: Tune a plugin end-to-end from a real session — runs both an AUDIT lens (find bugs/fixes) and an ENHANCE lens (find redundant-work eliminations) in parallel via two agents, merges their proposals, then runs a single consolidated review → selection → implement → publish with one version bump
argument-hint: [session-id] [plugin-name]
allowed-tools: [Bash, Read, Grep, Glob, Write, Edit, Skill, Task, AskUserQuestion]
---

# Tune Plugin (combined audit + enhancement, from a session transcript)

Run the combined audit + enhance workflow against ONE plugin in a single pass.

**Follow the `tune-plugin` skill end to end with `lens = both`** — it selects the target plugin once, fans out two
agents in parallel (Agent A = AUDIT lens: find bugs/fixes; Agent B = ENHANCE lens: find
redundant-work eliminations + optimal workflow/artifact set), merges and dedupes their proposals,
runs a single expert review, presents one multi-select `AskUserQuestion` over fixes and enhancements
together, implements the selected items per artifact-catalog safety rules, and publishes a single
consolidated version bump via `publish-plugin`.

Parse the arguments:
- **First token** = the session ID (UUID) or transcript path to learn from (required).
- **Second token** = the plugin name to tune (optional — skill auto-selects the optimal plugin by
  purpose-matching the session's friction and misbehavior when omitted).

Arguments provided: $ARGUMENTS
