---
description: Start a mentor plan session (plugin-owned harness — no native plan mode)
argument-hint: [what to plan]
allowed-tools: [Bash, Read, Grep, Glob, Skill, Task, AskUserQuestion, Write, Edit]
---

# mentor — owned plan harness

You are entering the **plugin-owned** plan harness. This deliberately does **not** use
Claude Code's native plan mode (Shift+Tab) or `ExitPlanMode` — read-only-during-planning
is enforced by the plugin's own marker-driven gate, which works even under
`bypassPermissions`.

Do these in order:

1. **Arm the plan-phase gate — run this FIRST, exactly once, before any reading or drafting:**

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/hooks/begin-plan.sh"
   ```

   This writes the `.planning` marker. From this point, `plan-phase-gate.sh` blocks every
   repo source edit (and repo-writing Bash) until the plan is approved, and `plan-read-gate.sh`
   requires you to delegate research to subagents. The only file you may write during planning
   is the persisted plan file (a styled `.html` or a Mermaid-first `.md`, per `/mentor:plan-output-format`) under `~/.claude/mentor/<repo>-<hash>/plans/…` (outside the repo).
   If the repo's persisted mode is `plan-only` (`/mentor:mode`), the plan is the deliverable —
   after approval, do not implement or dispatch.

2. **Immediately call `Skill({"skill": "mentor:mentor-plan"})` and follow it end to end** —
   this is the inner planning skill. Do **NOT** call `mentor:plan` (that would reload this command).
   Follow it from Step 1 (strategy question) through Step 6. When you reach the approval step,
   because the `.planning` marker is present you use the **owned-flow release**: ask
   **Proceed / Hand off to next agent / Review the plan (light) / Keep planning**, and on Proceed run
   `approve-plan.sh` (do **not** call `ExitPlanMode` and do **not** write `.proceed-mode`). **Hand
   off to next agent** runs `approve-plan.sh --handoff` (approve + release the gate, then write a
   `/mentor:handoff` doc for a fresh agent and stop — no dispatch). **Review the plan (light)**
   invokes `mentor:plan-review` (read-only reviewers, gate stays closed), then loops back to re-ask.

The task to plan:

$ARGUMENTS
