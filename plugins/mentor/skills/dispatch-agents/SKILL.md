---
name: dispatch-agents
description: Annotate plan steps as subagent dispatches — role, model, effort, parallel/sequential grouping — and execute them after approval. Invoked when a plan will fan out to subagents, or the user explicitly asks to "dispatch agents" / "fan out" / "parallelize" a task.
---

# Dispatch Agents

This skill defines the annotation grammar for plan steps that fan out to
subagents, and how to execute them. It is the shared reference used by
`plan` (Step 4 dispatch annotations) and `plan-review`.

## When to use

- The plan's implementation steps carry (or should carry) dispatch annotations.
- The user explicitly says "dispatch agents", "fan out", "use subagents", "parallelize this".
- A task spans multiple disjoint areas, would blow the main context, or has clearly independent sub-tasks worth running concurrently.

## When NOT to use

- Single-file edits the main thread can do directly.
- Tasks where the main thread already has all the context loaded — dispatching just adds round-trips.
- Anything requiring tight back-and-forth with the user.

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
4. **Assign roles.** Smallest specialist that covers the work.
5. **Assign models.** Default `sonnet`; upgrade only with a reason.
6. **Assign effort.** Default `medium`; upgrade for design/cross-cutting, downgrade for trivial.
7. **Write prompt sketches.** Each agent has zero memory of this conversation — the brief must stand alone.
8. **State done-when.** Observable, verifiable, no "looks good".

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
(`approve-plan.sh` released the gate). Then:

1. **Read the approved plan file** (`~/.claude/mentor/<repo>-<hash>/plans/<slug>.md`) — do not work from memory.
2. **Dispatch "Run in parallel:" groups** — issue ALL `Agent()` calls for each parallel group in a **single message** so they run concurrently. After dispatching, do not busy-poll with `sleep`/no-op Bash calls; stop and let the harness re-invoke you when agents complete.
3. **Dispatch "Sequential:" steps one at a time** — wait for the prior step's result before issuing the next call.
4. **Verify each `Done when:` criterion** before moving to the next step — agents describe what they intended; trust but verify.

Do NOT paraphrase the plan or summarize what you're about to do. Dispatch immediately.
