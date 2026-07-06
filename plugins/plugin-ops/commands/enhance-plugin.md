---
description: Enhance a plugin from a real session — find redundant/manual work the user did around one plugin and ship an optimal workflow + artifact set inside that plugin to eliminate it
argument-hint: [session-id] [plugin-name]
allowed-tools: [Bash, Read, Grep, Glob, Write, Edit, Skill, Task, AskUserQuestion]
---

# Enhance Plugin (from a session transcript)

Turn a real working session into a shipped plugin enhancement. Reads the session to find redundant or
manual work the user did around one plugin, then proposes and ships an **optimal workflow + artifact
set** inside that plugin to eliminate it.

**Follow the `tune-plugin` skill end to end with `lens = enhance`** — dispatch only the ENHANCE lens
(Agent B). It handles transcript resolution, plugin-purpose map construction, friction/routing
analysis, plugin selection, plugin-surface GAP analysis, artifact catalog resolution, proposal
synthesis (including the composing-entry-point self-notice), expert review, user confirmation, and
implementation with per-type safety, then publishes via `publish-plugin`.

Parse the arguments:
- **First token** = the session ID (UUID) or transcript path to learn from (required).
- **Second token** = the plugin name to enhance (skill auto-selects the optimal plugin by
  purpose-matching the session's friction when omitted).

Arguments provided: $ARGUMENTS
