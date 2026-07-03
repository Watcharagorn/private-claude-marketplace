---
description: Audit a past session by ID to find how a plugin MISBEHAVED (gate false-positives, wrong-skill calls, retries, post-run surprises), break into prioritized fixes, expert-review, implement, and publish
argument-hint: [session-id] [plugin-name]
allowed-tools: [Bash, Read, Grep, Glob, Write, Edit, Skill, Task, AskUserQuestion]
---

# Audit & Fix Plugin

Run the session-audit → fix → review → implement → publish workflow against ONE existing plugin.

**Follow the `tune-plugin` skill end to end with `lens = audit`** — dispatch only the AUDIT lens
(Agent A). It handles transcript resolution, plugin selection, the audit analysis (every gate block,
error, retry, workaround, wrong-skill call, post-run discrepancy → root cause), the mandatory
expert-review pass, implementation (with embedded-Python validation), and publishing via
`publish-plugin`.

Parse the arguments:
- **First token** = the session ID (UUID) or transcript path to audit (required).
- **Second token** = the plugin name to focus on (skill auto-selects by purpose-match if omitted).

Arguments provided: $ARGUMENTS
