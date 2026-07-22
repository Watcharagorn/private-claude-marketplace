---
description: Start a mentor plan session (marker-driven edit gate, Markdown plan under .mentor/plans/<slug>/)
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
   planning is the Markdown plan at `<repo>/.mentor/plans/<slug>/plan.md` (inside the
   repo, but the `.mentor/` tree is exempt from the gate). Read the script's stdout — it carries the
   `MODE:` line (plan / plan-only / UNSET — only sets which approval option is listed
   first; NEVER ask the user to pick a mode upfront) and, when the session context is
   large, a `CONTEXT:` line:
   - If stdout contains **`CONTEXT: ASK`**, do **not** call the plan skill yet — the
     gate was intentionally not armed; the user decides first. Follow the printed
     directive: ask via AskUserQuestion. On **"Hand off & plan in a fresh session"**
     invoke `Skill(skill="mentor:handoff")` and STOP; on **"Proceed anyway"** run the
     printed bypass script, re-run `begin-plan.sh`, then continue below with a lean
     plan (skip optional zooms and plan-review).
   - If stdout contains **`CONTEXT: HANDOFF`**, the gate IS armed — surface the
     advisory to the user, keep the plan lean, and at the approval step lead with
     **Hand off to next agent (Recommended)**.
   - If stdout contains **`CONTEXT: WARN`**, mention it to the user and continue.

2. **Immediately call `Skill({"skill": "mentor:plan"})` and follow it end
   to end** (after resolving a `CONTEXT: ASK` per step 1) — do **NOT** call
   `mentor:plan` (that would reload this command).
   At the approval step, ask **Proceed / Deliver plan only / Review the plan
   (light) / Keep planning** (the `MODE:` line decides whether Proceed or
   Deliver is listed first; under `CONTEXT: WARN` or `CONTEXT: HANDOFF`,
   **Hand off to next agent** replaces Review and leads — labeled
   **(Recommended)** under HANDOFF); on Proceed run `approve-plan.sh` (no-arg), on
   Deliver `approve-plan.sh --deliver` — both validate the plan and release
   the gate.

The task to plan:

$ARGUMENTS
