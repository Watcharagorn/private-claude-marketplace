---
name: dispatch-agents
description: >
  The default implementation path for mentor plans (subagents-driven
  development) — annotate every plan's implementation steps as subagent
  dispatches and execute them after approval; the main thread orchestrates,
  subagents implement. Invoked by plan Steps 4 and 6, or when the user says
  "dispatch agents" / "fan out" / "parallelize". Trivial work may skip with a
  stated `Dispatch: skipped` reason.
---

# Dispatch Agents

This skill defines the annotation grammar for plan steps that fan out to
subagents, and how to execute them. It is the default implementation path for
mentor plans, used by `plan` (Step 4 annotation, Step 6 execution) and
referenced by `plan-review` and `handoff`.

## When to use

This is the DEFAULT for every mentor plan: `plan` Step 4 invokes this skill to
annotate the implementation steps, and Step 6 invokes it again to execute them
after approval. Also invoked when the user explicitly says "dispatch agents",
"fan out", "use subagents", "parallelize this".

## Escape hatch — when a plan may skip annotation

Skip dispatch annotation ONLY when one of these branches holds:

- **Trivial:** the whole implementation is a small mechanical change (roughly
  ≤ ~20 changed lines) AND the main thread already holds everything needed
  from planning — implementing requires no new file reading; or
- **Interactive:** the work needs tight mid-implementation back-and-forth with
  the user.

A skipping plan MUST open its `## Implementation steps` section with one line —
`Dispatch: skipped — <one-line reason>` — so the skip is visible and reviewable
at approval. No line, no skip. If a skipped implementation turns out
non-trivial mid-flight, stop and dispatch normally per this skill.

## Context efficiency — the orchestrator contract

The point of SDD: quality through narrow focus, and a lean main thread.

- **The main thread MUST NOT read the implementation files a step delegates** —
  that context belongs to the dispatched agent. Verify `Done when:` with
  observable checks instead; the step's `git diff` and a failing command's
  output are always in-bounds as diagnostics.
- **Prefer executable pass/fail `Done when:` criteria** (the named test /
  typecheck / lint command) over presence checks; use grep/ls checks only when
  no runnable check exists.
- **On a failed `Done when:`**, re-dispatch the same role once with the failure
  evidence (diff + command output) as inputs. If it fails again, surface to the
  user — only then may the main thread read the files and take over.
- **Track progress in the plan file:** as each step's `Done when:` passes, mark
  its line in `plan.md` (append `✅`), so a resumed or handed-off session knows
  exactly what already ran.
- **Prompt sketches must be self-contained.** Each agent starts with zero
  memory of this conversation: give exact file paths, the approved plan path,
  the distilled facts it needs from research or prior steps (paste result
  lines, not files), and its `Done when:` verbatim.
- **Return contract:** agents return a short summary, file paths touched, and
  verification output — never full file bodies.
- **No nested fan-out:** dispatched agents cannot dispatch further agents —
  size each step so one agent completes it alone.

## Per-step output shape

Each step in the plan must be annotated as:

```
Step N — <short title>  [role: <subagent_type> · model: <opus|sonnet|haiku> · effort: <low|medium|high>]
  Goal: <what this step must produce>
  Inputs: <files / facts / prior-step outputs the agent needs>
  Prompt sketch: <2–4 lines briefing the agent like a smart colleague who just walked in>
  Done when: <observable acceptance criterion>
```

Group steps that have no dependencies under a **"Run in parallel:"** header so they dispatch in a single message. Dependent steps go under **"Sequential:"**.

## Choosing `role`

The authoritative list of `role:` values is the `Agent` tool's `subagent_type` enum in your current tool spec — the set of agents actually installed and enabled. Do **not** scan `~/.claude/agents/` or plugin `agents/` folders on disk — those can list disabled plugins. If nothing in the enum fits, fall back to `general-purpose` and put the specialty in the prompt.

| Need | Role |
|---|---|
| Locate code, grep symbols, find files | `Explore` |
| Design implementation strategy / architecture | `Plan` |
| Open-ended research, code edits, multi-step | `general-purpose` |
| Domain-specific (platform browsing, Jira, etc.) | the matching project agent |

## Choosing `model` — default Sonnet, step up to Opus

**Default subagents to `sonnet`** — it handles well-scoped sub-tasks at materially lower cost without quality loss: code edits, refactors, investigations, locating code, mechanical/bulk work.

**Step up to `opus`** only when the step genuinely needs heavy judgment: architecture/design decisions with real tradeoffs, security review, cross-cutting synthesis, the `Plan` step of a multi-workstream initiative.

**Step down to `haiku`** only for trivial, parallel-safe lookups ("does file X contain symbol Y?", one-shot fact retrievals).

## Choosing `effort` — low / medium / high

Effort is communicated to the dispatched agent **through prompt scope and depth instructions**, not a config field.

- **low** — single targeted lookup or quick check. Cap output ("report under 150 words").
- **medium** — standard investigation across one feature/module. Default.
- **high** — deep, cross-cutting analysis or implementation. Tell the agent to think carefully, consider edge cases, verify assumptions, report tradeoffs.

Effort and model are independent levers: a `low`-effort `opus` step is fine, and a `high`-effort `sonnet` step is fine.

## Decomposition rubric

1. **List the work.** Write the bare task list before assigning roles.
2. **Find the critical path.** Which steps must finish before others can start? Those are sequential.
3. **Find independent steps.** Disjoint files/areas, separate research questions, parallel verifications — group these for fan-out.
4. **Collapse small dependent steps.** Adjacent `Sequential:` steps that are individually small (combined ≤ ~40 changed lines) and suit the same role/model collapse into ONE dispatch — don't pay agent startup per tiny step.
5. **Assign roles.** Smallest specialist that covers the work.
6. **Assign models.** Default `sonnet`; upgrade only with a reason.
7. **Assign effort.** Default `medium`; upgrade for design/cross-cutting, downgrade for trivial.
8. **Write prompt sketches.** Each agent has zero memory of this conversation — the brief must stand alone.
9. **State done-when.** Observable, verifiable, no "looks good".

## Example

```
Run in parallel:
  Step 1 — Locate all payment-method touchpoints  [role: Explore · model: sonnet · effort: low]
    Goal: list every file that reads/writes payment method state.
    Inputs: src/features/checkout/**, src/db/atomicSale.ts
    Prompt sketch: Find every file referencing `paymentMethod`, `payments` table, or `Payment` types. Group by feature folder. Report under 200 words.
    Done when: file list returned with one-line purpose per file.

Sequential:
  Step 2 — Design refactor  [role: Plan · model: opus · effort: high]
    Goal: implementation plan for unifying payment dispatch.
    Inputs: output of Step 1.
    Prompt sketch: Given these touchpoints, design a refactor that consolidates payment handling behind a single dispatcher. Surface tradeoffs and migration risk.
    Done when: stepwise plan with file-level changes and risks. (Opus — cross-cutting judgment.)

  Step 3 — Implement  [role: general-purpose · model: sonnet · effort: medium]
    Goal: apply the refactor.
    Inputs: Step 2 plan.
    Prompt sketch: Execute the plan from Step 2. Run typecheck and unit tests after each file. Stop and report if a test fails.
    Done when: typecheck + tests pass; diff posted.
```

## Executing the dispatches (after plan approval)

Dispatch implementation/editing agents **only after the plan is approved**
(`approve-plan.sh` released the gate). Every implementation dispatch in a
mentor session routes through this skill — callers load it (once per session)
before issuing `Agent` calls. Then:

1. **Read the approved plan file** (`<repo>/.mentor/plans/<slug>/plan.md`) — do not work from memory.
2. **Dispatch "Run in parallel:" groups** — issue ALL `Agent()` calls for each parallel group in a **single message** so they run concurrently. After dispatching, do not busy-poll with `sleep`/no-op Bash calls; stop and let the harness re-invoke you when agents complete.
3. **Dispatch "Sequential:" steps one at a time** — wait for the prior step's result before issuing the next call.
4. **Verify each `Done when:` criterion** before moving to the next step — agents describe what they intended; trust but verify.
5. **CLOSING CHECKLIST — always, after the last step verifies:**
   - **Close out finished agents** — stop/release any still-resident dispatches (see "Async runtime & lifecycle" below).
   - **Offer `/mentor:tour`** — one line: a hands-on acceptance pass building an editable guided-tour review artifact (pass/not-pass scenarios) of what shipped. Do not auto-run it.

Do NOT paraphrase the plan or summarize what you're about to do. Dispatch immediately.

## Async runtime & lifecycle

Dispatched agents run as background teammates: they can signal **idle** before
(or instead of) delivering, die mid-flight on infra errors, and stay resident
after finishing. These rules govern every dispatch surface in mentor — this
skill, plus the dispatches in `plan` Steps 2/5, `plan-review`, `tour`, and
`grilling` (each cross-references this section):

- **Deliver before idling.** End every prompt sketch with a delivery directive:
  "Deliver your full result (final text / message per your runtime) BEFORE
  going idle — an idle signal with no delivered result is a contract
  violation." Verdict- or report-producing agents (reviewers, verifiers)
  additionally **Write a durable copy** to `<repo>/.mentor/plans/<slug>/`
  (e.g. `step-N-review.md`) before returning — a dropped notification must
  never be the only copy of completed work.
- **Idle-before-report race.** An idle notification can arrive before the
  agent's actual report. On idle with no report in hand: check the message
  backlog, then send ONE nudge requesting the result — only if that fails,
  fall back to independent re-verification. Never re-run expensive
  verification (full builds, E2E suites) while the agent's own report may
  still be in flight.
- **Agent died (infra/API error).** Don't reinvent recovery glue: wait with
  escalating patience (minutes-scale, roughly doubling — this sanctioned wait
  for a *dead* agent is not the busy-polling of a healthy one forbidden
  above), then send a resume message: "You died on an infra error mid-step.
  Resume Step N where you left off. Already applied: <paste state>. Your
  `Done when:` <verbatim>." Two failed resumes → fresh re-dispatch of the role.
- **Follow-up vs re-dispatch.** A small fix or clarification on work an idle
  agent already owns → message that same agent (its context is warm). A failed
  `Done when:` needing a clean rebrief → re-dispatch the role once (per the
  orchestrator contract above).
- **Close out.** Once a dispatch's output is consumed and its `Done when:`
  verified, stop/release the agent — finished agents left idling interrupt
  the session with stray notifications and pile up until manually killed.
