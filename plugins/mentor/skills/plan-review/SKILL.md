---
name: plan-review
description: |
  Pre-approval plan reviewer. Trigger phrases: `/plan-review`,
  "review this plan", "review the plan", "send the plan to reviewers" —
  or, for the consistency check alone: "check plan consistency",
  "consistency review", "analyze the plan for consistency".
  Reads the current mentor plan (.md) and, with the edit gate closed, runs
  a light review (three read-only reviewers: practicality,
  comprehensiveness, cleanliness), then a spec-kit-analyze-style
  consistency check over the plan and its related artifacts once the
  light review returns. The consistency check is also invocable on its
  own.
---

# Plan Review — Light Review, then Consistency

A pre-approval review pass in **two stages**: it reads the current plan,
confirms at the Step 2 gate, then fans out the **three light reviewers**
(practicality, comprehensiveness, cleanliness) — one `Agent()` call per
dimension in a **single message**. Once all three have returned, it dispatches
the **consistency** reviewer as an automatic follow-up stage. Sequencing keeps
the heavier cross-artifact consistency analysis from racing the light pass and
lets its findings land after the solution-level ones. The `.planning` gate
stays closed throughout; reviewers are read-only. The consistency stage can
also be invoked **on its own** (see Consistency-only mode below).

The four fixed dimensions are:

1. **Practicality** — is the approach feasible, realistically scoped, low-risk?
2. **Comprehensiveness** — does it cover the requirement, edge cases, and gaps?
3. **Cleanliness** — is the resulting design simple, maintainable, reuse-aware?
4. **Consistency** — spec-kit-`analyze`-style: do the plan's own sections and
   its related planning artifacts cover, agree with, and unambiguously specify
   each other?

The first three review the plan's solution **outward** (against the requirement,
feasibility, and design quality); **consistency** reviews it **inward and
across** (does the document — and its related artifacts — agree with itself?).
The lanes are exclusive so the reviewers don't overlap:

| Reviewer | Looks | Owns (exclusively) |
|---|---|---|
| Practicality | outward | feasibility, scope realism, risk |
| Comprehensiveness | outward | does the **solution** address the real requirement & real-world edge cases |
| Cleanliness | outward | design simplicity, maintainability, reuse |
| Consistency | inward + across | do the plan's **own sections & related artifacts** agree, trace to each other, stay unambiguous |

The boundary that matters: a **comprehensiveness gap** = the plan omits
something the *real requirement* needs; a **consistency coverage-gap** = the plan
*states* something (a scenario) but no step carries it through. There is no
domain detection — the full pass always reviews these same four dimensions.

## When to use

- The user typed `/plan-review` (or "review this plan"), or chose "Review the plan (light)" at the `plan` approval step — run both stages.
- The user asked for the consistency check alone ("check plan consistency", "consistency review") — run Consistency-only mode.
- A mentor plan `.md` exists in the plans dir and the user wants feedback before approving.

## When NOT to use

- After approval — the plan is released; use `mentor:dispatch-agents` to execute it.
- No plan file in the mentor plans dir.
- Single-file typo fixes or trivial edits where review costs more than the change.
- The user explicitly asked you NOT to invoke sub-agents.

## Step 1 — Resolve the plan file(s)

```bash
git_common=$(git rev-parse --git-common-dir 2>/dev/null) && \
  repo_root=$(cd "$(dirname "$git_common")" && pwd) && \
  d="$repo_root/.mentor/plans"
primary=$(ls -t "$d"/*/plan.md 2>/dev/null | head -1)   # the PRIMARY plan — the subject every reviewer reads
plan_dir=$(dirname "$primary")                          # the primary plan's own <slug>/ folder
echo "$primary"
```

If `$primary` is empty, print `Plan review aborted: no plan file found.` and
stop. Then `Read` the primary plan — it IS its own canonical source. Do **not**
edit it.

**Related artifact set (consistency reviewer only).** Also enumerate the other
planning artifacts so the consistency reviewer can check cross-artifact
coherence — the first three reviewers only ever see the primary plan:

```bash
ls -t "$d"/*/plan.md 2>/dev/null                      # all plans (one <slug>/ dir each)
ls    "$plan_dir"/zoom/*.html 2>/dev/null             # the primary plan's supplementary zoom artifacts
const_rel="$(jq -r '.constitution_path // empty' "$repo_root/.mentor/config.json" 2>/dev/null)"
const_path="${repo_root}/${const_rel:-.mentor/constitution.md}"
[ -f "$const_path" ] && echo "$const_path"            # the resolved constitution (default or constitution_path)
```

Pass the primary plan plus this list to the consistency reviewer. If the only
entry is the primary plan itself, it runs an internal-only pass (no
cross-artifact comparisons).

## Step 2 — User confirmation gate (AskUserQuestion)

**Skip this step** if the calling context explicitly instructs you to (e.g. the
user already chose "Review the plan (light)" at the approval step), or if the
user explicitly asked for the consistency check alone — that ask is the
confirmation; go straight to Consistency-only mode. Otherwise ask one
question:

```
Question — header "Plan review", single-select, 3 options:
  1. "Run review"   (Recommended)
     description: "Light review first (practicality, comprehensiveness, cleanliness), then the internal + cross-artifact consistency check once it completes."
  2. "Consistency only"
     description: "Skip the light review; run just the spec-kit-analyze-style consistency check."
  3. "Pass (skip)"
     description: "Return to planning without dispatching."
```

On "Pass (skip)": print `Plan review: skipped by user.` and return — no dispatch.
On "Consistency only": jump to Consistency-only mode.

## Step 3 — Fan out the three light reviewers

Issue **one `Agent()` call per topic in a single assistant message** so the
three run concurrently — the consistency reviewer is not in this batch; it
dispatches in Step 4. Each call uses
`subagent_type: general-purpose`, `model: sonnet`,
`description: "Review plan: <topic>"`. Every reviewer must stay in its own lane
(see the table above) — drop any finding another reviewer owns. Reviewer
dispatches follow `dispatch-agents`' **"Async runtime & lifecycle"** rules —
in particular, verdict-producing reviewers write a durable copy of their
verdict under `.mentor/plans/<slug>/` before returning, and finished reviewers
are closed out once their findings are consumed.

### Reviewers 1-3 — practicality, comprehensiveness, cleanliness

Each `prompt` must contain:

1. `Act as a solution/architecture reviewer of this plan. You are reviewing a plan, not implementing it.`
2. The primary plan file path with an explicit `Read this file before doing anything else.`
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
7. **Constitution (conditional)** — if the resolved constitution exists (the
   `$const_path` from Step 1 — default `.mentor/constitution.md`, or the file
   `constitution_path` in `.mentor/config.json` points at), add its path to
   every reviewer's prompt with:
   `Also read <const_path> and flag, under Risks, any place this plan
   violates a stated principle (name the principle).` Skip this line when the file
   is absent — do not add a separate constitution reviewer; the check stays folded
   into all reviewers.

## Step 4 — The consistency reviewer (spec-kit-`analyze`-style)

This step owns the dispatch timing: send this reviewer **only after all three
light reviewers have returned** — automatically, in the same turn you surface
their findings, with no extra confirmation gate. If a light reviewer dies,
note it and dispatch this one anyway; the lanes are independent.

A distinct contract: a structured, severity-tagged consistency analysis rather
than the prose block. `subagent_type: general-purpose`, `model: sonnet`,
`description: "Review plan: consistency"`. Its `prompt` must contain:

1. `Act as a spec-consistency analyzer. You analyze the plan (and its related planning artifacts) for internal and cross-artifact consistency. You are NOT implementing it, and NOT judging whether the approach is good.`
2. The primary plan path with `Read this file first.`, then the related-artifact
   list from Step 1 (other plans' `plan.md`s, the primary plan's `zoom/*.html`,
   the resolved constitution `$const_path`) with `Read the ones that appear related to the
   primary plan (inside the primary plan's folder, or referenced by it); ignore
   unrelated plans.`
3. **Lane guard:** `Judge only coherence, traceability, and agreement — not feasibility, requirement coverage vs reality, or design cleanliness. If a finding is really one of those, DROP it; another reviewer owns it.`
4. **Method:** `Inventory (a) the needs stated in Context, (b) the numbered Use case scenarios incl. edge cases, (c) the Implementation steps, (d) the Critical files. Then run the detection passes across sections — and across artifacts when more than one is related.`
5. **Detection categories:**
   - `coverage-gap` — a scenario/requirement/edge case with no implementation
     step; a step tracing to no stated need; Verification not exercising a
     scenario; Critical files mismatch (listed-but-unused, or touched-but-unlisted);
     an `## Implementation steps` section carrying neither `[role:` dispatch
     annotations nor a `Dispatch: skipped —` opening line (plans are
     dispatch-annotated by default — a plan with neither made no explicit choice).
   - `contradiction` — sections that disagree; step ordering vs a stated dependency.
   - `terminology-drift` — the same concept named differently across sections.
   - `ambiguity` — vague adjectives (fast/scalable/secure/simple) with no
     measurable criteria; unresolved placeholders (TBD/TODO/`<...>`).
   - `underspecification` — a step with a verb but no object/outcome; a scenario
     missing its expected behavior.
   - `duplication` — near-duplicate steps or requirements.
   - **cross-artifact (only when >1 related artifact is read):**
     `cross-contradiction` (two artifacts conflict), `cross-drift` (same concept,
     different term across artifacts), `cross-overlap` (two plans describe the
     same work), `dangling-reference` (references a section/artifact that doesn't
     exist), `orphan/stale-artifact` (an `.html` zoom out of sync with the `.md`).
6. **Severity:** `CRITICAL` (a coverage gap blocking the core requirement, a
   cross-artifact contradiction, or a constitution MUST violation) / `HIGH` /
   `MEDIUM` / `LOW`. High-signal only; cap at ~15 findings.
7. **Required structured output** (the tables carry the content — keep prose minimal):
   ```
   Consistency findings
   | ID | Category | Severity | Location(s) | Summary | Fix |
   | --- | --- | --- | --- | --- | --- |

   Coverage map
   | Requirement / scenario | Covered by step (which artifact)? | Notes |
   | --- | --- | --- |

   Metrics: <N scenarios> · <req coverage %> · <artifacts checked> · <critical count>
   ```
8. Read-only + anti-recursion: `Do not edit any file. Do not invoke /plan-review or any planning skill.`
9. **Constitution (conditional):** if the resolved constitution `$const_path`
   exists (Step 1), read it —
   a MUST-principle violation is a CRITICAL finding, and additionally verify the
   plan's `## Constitution Check` table is internally consistent (every principle
   has a row; every ⚠️ verdict has a resolving or explicitly-justified note).

## Step 5 — Surface findings

Surface findings as each batch returns, grouped by dimension:

- **When the light reviewers return:** surface reviewers 1-3 as their
  `Strengths/Risks/Gaps/Recommended plan edits` blocks, then dispatch the
  consistency reviewer per Step 4.
- **When the consistency reviewer returns:** surface its findings table +
  coverage map + metrics **as-is**.

If the user wants any finding folded in, revise and re-write the plan file
(`plan` Step 4), then return to the approval question.

## Consistency-only mode

Entered by a direct consistency ask or the "Consistency only" gate choice
(see When to use / Step 2). Ensure Step 1 has run — it is the shared
prerequisite of every mode — then skip the light reviewers and dispatch
**only** the Step 4 consistency reviewer, immediately. Surface its output per
Step 5's second bullet. Everything else holds: gate closed, read-only, no
plan edits from inside this skill.

### Do NOT

- Do **not** run `approve-plan.sh` from inside this skill — review never releases the gate.
- Do **not** edit any plan file or artifact from inside `/plan-review`. Surface findings; let the user decide.
- Do **not** detect domains or ask the user to select topics — the review topics are fixed (see the dimension table above).
