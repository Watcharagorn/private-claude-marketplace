---
description: Start a mentor plan session (marker-driven edit gate, Markdown plan outside the repo)
argument-hint: [what to plan]
allowed-tools: [Bash, Read, Grep, Glob, Skill, Task, AskUserQuestion, Write, Edit]
---

# mentor — plan

You are entering the mentor plan harness. Read-only-during-planning is enforced
by the plugin's marker-driven edit gate, which works even under
`bypassPermissions`.

Do these in order:

1. **Arm the plan gate — run this FIRST, exactly once, before any reading or drafting:**

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/hooks/begin-plan.sh"
   ```

   This writes the `.planning` marker. From this point, `plan-gate.sh` blocks every
   repo source edit until the plan is approved. The only file you write during
   planning is the Markdown plan under `~/.claude/mentor/<repo>-<hash>/plans/`
   (outside the repo). Read the script's stdout — it carries the `MODE:` line
   (plan / plan-only / UNSET → ask once).

2. **Immediately call `Skill({"skill": "mentor:plan"})` and follow it end
   to end** — do **NOT** call `mentor:plan` (that would reload this command).
   At the approval step, ask **Proceed / Hand off to next agent / Review the
   plan (light) / Keep planning**; on Proceed run `approve-plan.sh`, which
   validates the plan and releases the gate.

The task to plan:

$ARGUMENTS
