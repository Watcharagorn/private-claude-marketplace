---
description: Analyze a session transcript, find the repeated manual work, and package it as a marketplace plugin under plugins/<name>/ (registered in marketplace.json), then offer to publish
argument-hint: [session-id OR path to a transcript .jsonl]
allowed-tools: [Bash, Read, Grep, Glob, Write, Edit, Skill, Task, AskUserQuestion]
---

# Harvest to Plugin

Turn a real working session into a packaged **marketplace plugin** in this repo. Reads the session
transcript, finds patterns that repeated (>=2 near-identical asks or a stable multi-step macro),
designs each as a usage/workflow, and materializes the accepted ones as a plugin under
`plugins/<name>/` — creating a **new** plugin or **merging into an existing** one — then registers it
in `marketplace.json` and **offers** to publish (nothing is committed or pushed without your yes).

The argument is **optional** and selects which session to analyze:

- **empty** — the **active** session (auto-discovered under the hashed cwd).
- a **session id** (a UUID) — resolved to that session's transcript under `~/.claude/projects/`.
- a **path** to a transcript `.jsonl` — used directly.

**Follow the `harvest-to-plugin` skill end to end** — it handles transcript resolution (reading only
the tail in the main thread), subagent analysis, the plugin-purpose map + plugin-surface GAP scan (so
it never ships a redundant workflow and can merge into an existing plugin), catalog + packaging
validation, expert review, usage confirmation via `AskUserQuestion`, idempotent materialization, and
the publish offer via `publish-plugin`.

Arguments provided: $ARGUMENTS
