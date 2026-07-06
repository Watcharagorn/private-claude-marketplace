---
description: analyze a session (active by default, or one given its session id / transcript path) and create/update reusable Claude Code artifacts (skills, commands, agents, hooks, permissions, CLAUDE.md, MCP, rules) to cut future manual work
argument-hint: [optional session-id OR path to a session transcript .jsonl]
allowed-tools: [Bash, Read, Write, Edit, Skill, Task, AskUserQuestion]
---

# plugin-ops — harvest automations

Analyze a session and extract reusable Claude Code artifacts that reduce future manual work.

Follow the `harvest-automations` skill end to end. The skill handles transcript resolution, analysis, artifact generation, and user confirmation.

The argument below is **optional** and selects which session to harvest:

- **empty** — harvest the **active** session (auto-discovered).
- a **session id** (a UUID, e.g. `e05bde45-3ed9-458d-9a2e-ba6744d64a18`) — the skill resolves it to that session's transcript under `~/.claude/projects/`.
- a **path** to a transcript `.jsonl` — used directly.

$ARGUMENTS
