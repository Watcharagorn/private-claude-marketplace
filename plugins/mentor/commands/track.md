---
description: See which mentor plans are built vs pending, and build the next one (plan state)
argument-hint: [slug | number | status]
allowed-tools: [Bash, Read, Grep, Glob, Skill, Task, AskUserQuestion, Write, Edit]
---

# mentor — track

Show this repo's plans with their lifecycle state, then build the one the user picks.

This command does **not** arm the plan gate — it works with plans that already exist.
(Note the name: `/mentor:track`, not `/mentor:plans`. A one-character typo away from
`/mentor:plan` would silently start a new planning session and close the edit gate.)

Do these in order:

1. **Check the context first — before listing, and certainly before dispatching:**

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" context
   ```

   On **`CONTEXT: ASK`**, do not start an implementation — ask the user the two-option
   question the script prints (hand off, or bypass for this session) and follow their
   answer. This is the only context check on the path to a build; the skill's Step 0
   explains why nothing else covers it.

2. **Call `Skill({"skill": "mentor:plan-track"})` and follow it end to end.**
   It lists the plans, resolves the selection, and executes the chosen plan through
   `mentor:dispatch-agents`. A `draft` plan is never built silently — the approval
   gate never released it, so the skill asks you to approve it first, or stops.

Argument (optional) — a plan slug, a 1-based number from the list, or `status` to
print state and stop without building:

$ARGUMENTS
