---
name: plan-review
description: |
  Pre-approval light plan reviewer. Trigger phrases: `/plan-review`,
  "review this plan", "review the plan", "send the plan to reviewers".
  Reads the current mentor plan (.md) and reviews the plan's solution against
  three fixed dimensions — practicality, comprehensiveness, and cleanliness —
  by fanning out three read-only general-purpose reviewers in a single
  parallel Agent() batch, while the edit gate stays closed.
---

# Plan Review — Fixed 3-Topic Light Review

A pre-approval review pass: it reads the current plan, asks the user Run vs
Pass, then fans out **three** `Agent()` calls — one per fixed dimension — in a
**single message**. The `.planning` gate stays closed throughout; reviewers are
read-only.

The three fixed dimensions are:

1. **Practicality** — is the approach feasible, realistically scoped, low-risk?
2. **Comprehensiveness** — does it cover the requirement, edge cases, and gaps?
3. **Cleanliness** — is the resulting design simple, maintainable, reuse-aware?

There is no domain detection — every plan is reviewed against these same three dimensions.

## When to use

- The user typed `/plan-review` (or "review this plan"), or chose "Review the plan (light)" at the `plan` approval step.
- A mentor plan `.md` exists in the plans dir and the user wants feedback before approving.

## When NOT to use

- After approval — the plan is released; use `dispatch-agents` to execute it.
- No plan file in the mentor plans dir.
- Single-file typo fixes or trivial edits where review costs more than the change.
- The user explicitly asked you NOT to invoke sub-agents.

## Step 1 — Resolve the plan file

```bash
git_common=$(git rev-parse --git-common-dir 2>/dev/null) && \
  repo_root=$(cd "$(dirname "$git_common")" && pwd) && \
  d="$HOME/.claude/mentor/$(basename "$repo_root")-$(printf '%s' "$repo_root" | shasum | cut -c1-8)/plans"
ls -t "$d"/*.md 2>/dev/null | head -1
```

If nothing is found, print `Plan review aborted: no plan file found.` and stop.
Then `Read` the plan file — it IS its own canonical source. Do **not** edit it.

## Step 2 — User confirmation gate (AskUserQuestion)

**Skip this step** if the calling context explicitly instructs you to (e.g. the
user already chose "Review the plan (light)" at the approval step). Otherwise
ask one Run-vs-Pass question:

```
Question — header "Plan review", single-select, 2 options:
  1. "Run light review"   (Recommended)
     description: "Review the plan's solution on practicality, comprehensiveness, and cleanliness."
  2. "Pass (skip)"
     description: "Return to planning without dispatching."
```

On "Pass (skip)": print `Plan review: skipped by user.` and return — no dispatch.

## Step 3 — Fan out the three reviewers

Issue **one `Agent()` call per topic in a single assistant message** so they run
concurrently. Each call uses `subagent_type: general-purpose`, `model: sonnet`,
`description: "Review plan: <topic>"`. Each `prompt` must contain:

1. `Act as a solution/architecture reviewer of this plan. You are reviewing a plan, not implementing it.`
2. The plan file path with an explicit `Read this file before doing anything else.`
3. `Critique the plan's solution strictly through the lens of <topic>.` plus the one-line definition:
   - `practicality` → `Is the approach feasible, realistically scoped, and low-risk?`
   - `comprehensiveness` → `Does it cover the requirement, edge cases, and gaps?`
   - `cleanliness` → `Is the resulting design simple, maintainable, and reuse-aware?`
4. Required structured output:
   ```
   Strengths:
   Risks:
   Gaps:
   Recommended plan edits:
   ```
5. Word cap: `Cap your reply at 400 words.`
6. Anti-recursion: `Do not invoke /plan-review or any planning skill.`
7. **Constitution (conditional)** — if `.mentor/constitution.md` exists at the
   repo root, add its path to every reviewer's prompt with:
   `Also read .mentor/constitution.md and flag, under Risks, any place this plan
   violates a stated principle (name the principle).` Skip this line when the file
   is absent — do not add a fourth reviewer.

## Step 4 — Surface findings

When the reviewers return, surface their findings grouped by dimension. If the
user wants any folded in, revise and re-write the plan file (`plan` Step 4),
then return to the approval question.

### Do NOT

- Do **not** run `approve-plan.sh` from inside this skill — review never releases the gate.
- Do **not** edit the plan file from inside `/plan-review`. Surface findings; let the user decide.
- Do **not** detect domains or ask the user to select domains — this is a fixed 3-topic pass.
