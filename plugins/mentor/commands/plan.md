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
   nothing releases this worktree's `.planning.<wt-id>` marker (or a live legacy
   `.planning`) but an approved plan.

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/hooks/begin-plan.sh" [<target-slug>]
   ```

   Pass the target plan's slug as the one optional argument whenever you already
   know it — e.g. the user named an existing plan/topic, or you are resuming or
   claiming a specific `.mentor/plans/<slug>/` dir — so `begin-plan.sh` can WARN if
   that slug is already owned by a different worktree with a live marker (see "also
   armed elsewhere" below). Leave it off for a brand-new topic with no slug yet; the
   arm still succeeds either way.

   This writes THIS WORKTREE's own `.planning.<wt-id>` marker (v2.23.0 — one marker
   per git worktree; `plans/` itself stays shared across every worktree). From this
   point, `plan-gate.sh` blocks every repo source edit **in this worktree** until the
   plan is approved — a sibling worktree plans and edits independently. The only file
   you write during planning is the Markdown plan at `<repo>/.mentor/plans/<slug>/plan.md`
   (inside the repo, but the `.mentor/` tree is exempt from the gate). Read the
   script's stdout — it carries the `MODE:` line (plan / plan-only / UNSET — only
   sets which approval option is listed first; NEVER ask the user to pick a mode
   upfront) and, when the session context is large, a `CONTEXT:` line:
   - If stdout contains **`[mentor] Plan gate NOT armed — another session's plan gate
     is already active`**, the gate was NOT armed and no marker was touched — a
     different, still-live session in **this same worktree** already owns it (each
     worktree now arms its own independent marker; this refusal is scoped to a
     collision within one worktree, not across worktrees). Do not re-run
     `begin-plan.sh` to force it. Surface the printed owner/age to the user and ask
     before proceeding — either wait for that session, or, once the user explicitly
     authorizes overriding it, re-run the exact same command with
     `--override-foreign-marker` appended (the refusal message itself names this).
     Never delete the marker file by hand instead — that skips this guard's own
     stranding check entirely.
   - If stdout contains **`[mentor] Plan gate NOT armed — a legacy repo-wide plan
     gate marker is still active.`** (the distinct first line), this is NOT "another
     session's plan gate" in the sense above — it is a pre-upgrade, repo-wide marker
     with no worktree attribution that fail-closed blocks every worktree, including
     ones that never armed anything. The ASK-recovery advice for the branch above
     (re-run once the user authorizes) does **not** apply here: surface the printed
     owner/age to the user and either wait for its owning session to approve/release
     it, or get the user's explicit authorization to remove the marker by hand. Do
     **not** re-run `begin-plan.sh` to force it.
   - If stdout contains one or more `also armed elsewhere:` lines, that is purely
     informational — a live marker in a sibling worktree, reported so you know it
     exists. It does not block this worktree's gate: do not re-run `begin-plan.sh`,
     and do not wait for it.
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

**Never re-run step 1 once it has run.** `begin-plan.sh` resets THIS worktree's
`.planning.<wt-id>` marker's mtime (or the legacy `.planning`'s, in the empty-wt-id
fallback), and `approve-plan.sh` then refuses to release a plan file older than the
marker — stranding a finished plan unapprovable.


The task to plan:

$ARGUMENTS
