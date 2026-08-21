# A worked annotation example

Read this when authoring a plan's implementation steps and you want the grammar from
`SKILL.md` → "Per-step output shape" shown end to end. Execution never needs it — a run
reads the plan file, not this example.

One parallel `Explore` step, then two sequential ones:

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
    Done when: typecheck + tests pass; `git diff --stat` reported with the touched paths.
```
