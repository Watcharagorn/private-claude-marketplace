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
   At the approval step, take the option list from the **option-set table** in the
   skill's `{#approve}` section — it fixes the precedence between the `MODE:`
   default, `CONTEXT: WARN` / `CONTEXT: HANDOFF`, and an oversized plan (which leads
   with **Split into multiple plans**). Do not improvise the list here: one copy of
   it, in the skill, is the only way it stays right. Each option maps to an
   `approve-plan.sh` invocation the skill specifies; all of them validate the plan
   and release the gate except Review, Split, and Keep planning, which stay in
   planning.

**If that call returns this command's own text** — any re-invocation or
previously-loaded notice — rather than a file whose frontmatter reads
`name: plan`, the skill body never loaded: this command and the skill share the
name `plan`. Resolve and read it directly, then follow that file end to end:

```bash
echo "${CLAUDE_PLUGIN_ROOT}/skills/plan/SKILL.md"
```

`Read` the printed path — `Read` cannot expand `${CLAUDE_PLUGIN_ROOT}` itself. **Do not
re-run the steps above this one:** they already ran, and a step that writes or marks
something can undo its own first pass when repeated.

That bites hardest at step 1 here: re-running `begin-plan.sh` resets the `.planning`
marker's mtime, and `approve-plan.sh` then refuses to release a plan file older than the
marker — stranding a finished plan unapprovable.


The task to plan:

$ARGUMENTS
