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

   One guard before you arm: if another framework already owns the plan of record for
   this work (a spec-kit `tasks.md` phase, a Jira epic — decide from what the user
   asked, not by sniffing the repo), do **not** arm. Point at that framework's own next
   command, or invoke `Skill({"skill": "mentor:dispatch-agents"})` to execute one of its
   phases (`plan-track`, "When NOT to use"). This sits before the arm deliberately:
   nothing releases `.planning` but an approved plan.

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
   - If stdout contains **`[mentor] Plan gate NOT armed — another session's plan gate
     is already active`**, the gate was NOT armed and no marker was touched — a
     different, still-live session already owns it (this repo shares one `.planning`
     marker across every linked git worktree). Do not re-run `begin-plan.sh` to force
     it. Surface the printed owner/age to the user and ask before proceeding — either
     wait for that session, or have the user explicitly authorize overriding it.
   - If stdout contains **`CONTEXT: ASK`**, do **not** call the plan skill yet — the
     gate was intentionally not armed; the user decides first. Follow the printed
     directive: ask via AskUserQuestion. On **"Hand off & plan in a fresh session"**
     invoke `Skill(skill="mentor:handoff-note")` and STOP; on **"Proceed anyway"** run the
     printed bypass script, re-run `begin-plan.sh`, then continue below — the re-run
     prints `CONTEXT: HANDOFF`, so follow that line's guidance.
   - If stdout contains **`CONTEXT: HANDOFF`**, the gate IS armed — surface the
     advisory to the user, keep the plan lean, and at the approval step lead with
     **Hand off to next agent (Recommended)**.
   - If stdout contains **`CONTEXT: WARN`**, mention it to the user and continue.

2. **Immediately call `Skill({"skill": "mentor:planning"})` and follow it end
   to end** (after resolving a `CONTEXT: ASK` per step 1).
   At the approval step, take the option list from the **option-set table** in the
   skill's `{#approve}` section — it fixes the precedence between the `MODE:`
   default, `CONTEXT: WARN` / `CONTEXT: HANDOFF`, and an oversized plan (which leads
   with **Split into multiple plans**). Do not improvise the list here: one copy of
   it, in the skill, is the only way it stays right. Each option maps to an
   `approve-plan.sh` invocation the skill specifies; all of them validate the plan
   and release the gate except Review, Split, Keep planning, and **Pause — still
   drafting**, which stay in planning. That last one runs no script at all: it writes
   a handoff doc and stops with the gate still armed, so a session that runs out of
   room mid-plan can continue next session without an approval it never gave.

**Never re-run step 1 once it has run.** `begin-plan.sh` resets the `.planning` marker's
mtime, and `approve-plan.sh` then refuses to release a plan file older than the marker —
stranding a finished plan unapprovable.


The task to plan:

$ARGUMENTS
