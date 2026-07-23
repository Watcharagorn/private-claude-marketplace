---
name: plan-review
description: |
  Pre-approval plan reviewer. Trigger phrases: `/plan-review`,
  "review this plan", "review the plan", "send the plan to reviewers" —
  or, for the mechanical pass alone: "check plan consistency",
  "consistency review", "analyze the plan for consistency".
  Reads the current mentor plan (.md) and, with the edit gate closed, runs a
  staged review: Stage 1 judgment reviewers (practicality,
  comprehensiveness), then a fold gate where the user picks which
  recommended edits to fold into the plan; then Stage 2 mechanical
  reviewers (cleanliness + a spec-kit-analyze-style consistency check over
  related artifacts) against the updated plan, whose safe MECHANICAL fixes
  are auto-folded — findings needing a substantive decision are surfaced,
  never auto-applied. Stage 2 is also invocable on its own.
---

# Plan Review — Judgment, Fold, then Mechanical Auto-Fold

A pre-approval review pass in **two stages of two concurrent reviewers each**:
it reads the current plan, confirms at the Step 2 gate, then fans out the
**judgment reviewers** (practicality, comprehensiveness) — one `Agent()` call
per dimension in a **single message**. Their recommended edits go through a
**fold gate** (Step 4): the user picks which to apply, and the picks are
folded by re-writing the plan in place. Only then do the **mechanical
reviewers** (cleanliness, consistency) dispatch — against the UPDATED plan, so
they also catch anything the fold introduced. Their `MECHANICAL`-tagged fixes
are auto-folded; `DECISION-REQUIRED` findings are surfaced, never
auto-applied. Reviewers stay read-only and the `.planning` gate stays closed
throughout, but this skill itself writes ONE file — the plan `.md`, at Step 5
(fold) and Step 7 (auto-fold), inside the gate-exempt `.mentor/` tree. The
mechanical stage can also be invoked **on its own** (see Stage-2-only mode
below).

The four fixed dimensions are:

1. **Practicality** — is the approach feasible, realistically scoped, low-risk?
2. **Comprehensiveness** — does it cover the requirement, edge cases, and gaps?
3. **Cleanliness** — is the resulting design simple, maintainable, reuse-aware?
4. **Consistency** — spec-kit-`analyze`-style: do the plan's own sections and
   its related planning artifacts cover, agree with, and unambiguously specify
   each other?

The judgment reviewers weigh the plan's solution against the requirement and
reality — accepting their edits is a call only the user can make. The
mechanical reviewers police quality and coherence, where a safe fix needs no
human in the loop. The lanes are exclusive so the reviewers don't overlap:

| Reviewer | Stage | Looks | Owns (exclusively) |
|---|---|---|---|
| Practicality | 1 — judgment | outward | feasibility, scope realism, risk |
| Comprehensiveness | 1 — judgment | outward | does the **solution** address the real requirement & real-world edge cases |
| Cleanliness | 2 — mechanical | outward | design simplicity, maintainability, reuse |
| Consistency | 2 — mechanical | inward + across | do the plan's **own sections & related artifacts** agree, trace to each other, stay unambiguous |

The boundary that matters: a **comprehensiveness gap** = the plan omits
something the *real requirement* needs; a **consistency coverage-gap** = the plan
*states* something (a scenario) but no step carries it through. There is no
domain detection — the full pass always reviews these same four dimensions.

## When to use

- The user typed `/plan-review` (or "review this plan"), or chose "Review the plan (staged)" at the `plan` approval step — run both stages.
- The user asked for the consistency check alone ("check plan consistency", "consistency review") — run Stage-2-only mode.
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
edit it yet — plan edits happen only at Step 5 (fold) and Step 7 (auto-fold).

**Related artifact set (consistency reviewer only).** Also enumerate the other
planning artifacts so the consistency reviewer can check cross-artifact
coherence — the Stage 1 reviewers and the cleanliness reviewer only ever see
the primary plan:

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
user already chose "Review the plan (staged)" at the approval step), or if the
user explicitly asked for the consistency check alone — that ask is the
confirmation; go straight to Stage-2-only mode. Otherwise ask one
question:

```
Question — header "Plan review", single-select, 3 options:
  1. "Run staged review"   (Recommended)
     description: "Stage 1 judgment review (practicality, comprehensiveness) with a fold gate where you pick the edits to apply, then Stage 2 mechanical review (cleanliness, consistency) on the updated plan with safe fixes auto-folded."
  2. "Stage 2 only"
     description: "Skip the judgment stage; run just the mechanical pass — cleanliness + the spec-kit-analyze-style consistency check — and auto-fold its safe fixes. Decision-level findings are surfaced, not applied."
  3. "Pass (skip)"
     description: "Return to planning without dispatching."
```

On "Pass (skip)": print `Plan review: skipped by user.` and return — no dispatch.
On "Stage 2 only": jump to Stage-2-only mode.

## Step 3 — Stage 1: fan out the two judgment reviewers

Issue **one `Agent()` call per topic in a single assistant message** so the
two run concurrently — the mechanical reviewers are not in this batch; they
dispatch in Step 6, after the fold. Each call uses
`subagent_type: general-purpose`, `model: sonnet`,
`description: "Review plan: <topic>"`. Every reviewer must stay in its own lane
(see the table above) — drop any finding another reviewer owns. Reviewer
dispatches follow `dispatch-agents`' **"Async runtime & lifecycle"** rules —
in particular, verdict-producing reviewers write a durable copy of their
verdict under `.mentor/plans/<slug>/` before returning. Close **both** Stage 1
reviewers out once their findings are consumed, BEFORE blocking on the Step 4
fold gate — an idle agent must not interrupt the gate with stray
notifications.

If one reviewer dies, note it and run the fold gate on the survivor's
findings; if both die, note it and go straight to Step 6.

### Reviewers 1-2 — practicality, comprehensiveness

Each `prompt` must contain:

1. `Act as a solution/architecture reviewer of this plan. You are reviewing a plan, not implementing it.`
2. The primary plan file path with an explicit `Read this file before doing anything else.`
3. `Critique the plan's solution strictly through the lens of <topic>.` plus the one-line definition:
   - `practicality` → `Is the approach feasible, realistically scoped, and low-risk?`
   - `comprehensiveness` → `Does it cover the requirement, edge cases, and gaps?`
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

## Step 4 — Fold gate: the user picks which edits land

Surface both reviewers' `Strengths/Risks/Gaps/Recommended plan edits` blocks,
numbering every recommended edit with a stable ID as you surface it — `P1,
P2, …` (practicality), `C1, C2, …` (comprehensiveness). The IDs are the
contract for the question below and for "Other" answers.

If neither reviewer returned recommended edits, say so and go straight to
Step 6. Otherwise ask ONE `AskUserQuestion` call containing one
**multi-select** question per dimension that returned edits (omit a dimension
with none):

```
Question 1 — header "Practicality", multiSelect: true
  question: "Which practicality edits should be folded into the plan?
             (Select none to fold none; 'Other' accepts any surfaced IDs, e.g. 'P5, C2'.)"
  options: up to 4, one per recommended edit —
    label "P<n>: <short edit label>",
    description = the concrete change it makes to the plan and why it matters.

Question 2 — header "Completeness", multiSelect: true — same shape with C-IDs.
```

**Overflow (>4 edits in a dimension):** never truncate silently. Consolidate
related edits into combined options (the label carries every folded ID, e.g.
`"P2+P4: unify rollout steps"`), ranked by impact, until ≤4 options remain;
any edit that resists consolidation stays reachable by ID via "Other" — the
question text must say so. Selecting nothing in both questions is a valid
outcome: fold nothing and continue to Step 6 regardless.

**Re-entry dedup:** when the staged review runs again in the same session (the
approval question loops back here), do not re-offer edit IDs the user already
declined — only new or changed findings get options. Note the declined IDs in
the surfaced text so they stay reachable via "Other" if the user changes
their mind.

## Step 5 — Fold the selected edits

Apply exactly the edits the user selected (plus any IDs named via "Other") by
revising and re-writing the SAME plan file in place per `plan` Step 4 — never
a second copy, never anywhere else. Do not apply unselected edits, and do not
"improve" unrelated text while you're in the file — Stage 2 owns quality
fixes. If nothing was selected, skip the write.

## Step 6 — Stage 2: fan out the two mechanical reviewers

Dispatch **only after Step 5 completes** (the write, or the fold-nothing
decision) — both reviewers read the UPDATED plan, so they also catch anything
the fold introduced. Issue one `Agent()` call each in a single message,
`subagent_type: general-purpose`, `model: sonnet`. Dispatches follow
`dispatch-agents`' **"Async runtime & lifecycle"** rules — durable verdict
copies under `.mentor/plans/<slug>/`; close both reviewers out after Step 7
consumes their findings. If one dies, note it and auto-fold the survivor's
MECHANICAL findings.

**Both prompts embed this tagging contract verbatim** — it is what lets
Step 7 apply fixes without a human in the loop:

```
Tag every finding exactly one of:
- MECHANICAL — the fix is fully determined by the plan text itself: wording,
  grammar, section structure, step numbering/ordering labels, terminology
  drift (converge on the dominant term), duplication merges, dangling
  internal references, coherence fixes where one side is unambiguously
  canonical. Applying it changes HOW the plan says something, never WHAT it
  decides. A MECHANICAL finding MUST carry the exact edit: location +
  replacement text — a MECHANICAL finding without one is treated as
  DECISION-REQUIRED.
- DECISION-REQUIRED — resolving it means choosing between substantive
  alternatives: contradictions where either side could be intended, scope or
  step additions/removals/reordering, coverage gaps, feasibility or design
  concerns, constitution violations. State the options; do not pick one.
If in doubt, tag DECISION-REQUIRED — the auto-fold must never make a
substantive choice on the user's behalf.
```

### Reviewer — cleanliness

`description: "Review plan: cleanliness"`. Its `prompt` must contain the same
scaffolding as the Step 3 reviewers (role line, primary plan path +
read-first, anti-recursion, conditional constitution) with these lane
specifics:

- `Critique the plan's solution strictly through the lens of cleanliness.` →
  `Is the resulting design simple, maintainable, and reuse-aware?`
- Required structured output: the `Strengths/Risks/Gaps/Recommended plan
  edits` block, where every `Recommended plan edits` item MUST open with
  `[MECHANICAL]` or `[DECISION-REQUIRED]` per the tagging contract, and a
  MECHANICAL item carries its exact edit (location + replacement text).
  `Risks:`/`Gaps:` items are decision-level context — they are never
  auto-folded.
- Word cap: `Cap your reply at 600 words; the exact location + replacement
  text of MECHANICAL fixes does not count toward the cap.` (A tighter cap
  truncates the fixes, which demotes them at Step 7 and hollows out the
  auto-fold.)

### Reviewer — consistency (spec-kit-`analyze`-style)

A distinct contract: a structured, severity-tagged consistency analysis rather
than the prose block. `description: "Review plan: consistency"`. Its `prompt`
must contain:

1. `Act as a spec-consistency analyzer. You analyze the plan (and its related planning artifacts) for internal and cross-artifact consistency. You are NOT implementing it, and NOT judging whether the approach is good.`
2. The primary plan path with `Read this file first.`, then the related-artifact
   list from Step 1 (other plans' `plan.md`s, the primary plan's `zoom/*.html`,
   the resolved constitution `$const_path`) with `Read the ones that appear related to the
   primary plan (inside the primary plan's folder, or referenced by it); ignore
   unrelated plans.`
3. **Lane guard:** `Judge only coherence, traceability, and agreement — not feasibility, requirement coverage vs reality, or design cleanliness. If a finding is really one of those, DROP it; another reviewer owns it.`
   Plus one cycle-scoped exclusion: `Ignore zoom/*.html staleness relative to
   plan edits made in this review cycle — the plan was just revised and its
   zooms lag by construction; the closing report owns the re-zoom reminder.
   Flag orphan/stale-artifact only when the mismatch predates this review.`
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
6. **Tagging:** the tagging contract above, plus the category defaults:
   `Category defaults: terminology-drift, duplication, dangling-reference, and
   pure-wording ambiguity are usually MECHANICAL; contradiction, coverage-gap,
   underspecification, every cross-* category, and constitution violations are
   DECISION-REQUIRED. The in-doubt rule overrides these defaults.`
7. **Severity:** `CRITICAL` (a coverage gap blocking the core requirement, a
   cross-artifact contradiction, or a constitution MUST violation) / `HIGH` /
   `MEDIUM` / `LOW`. High-signal only; cap at ~15 findings. The `Fix` column's
   location + replacement text is exempt from any length pressure — a
   MECHANICAL fix without its exact edit gets demoted at Step 7.
8. **Required structured output** (the tables carry the content — keep prose minimal):
   ```
   Consistency findings
   | ID | Tag | Category | Severity | Location(s) | Summary | Fix |
   | --- | --- | --- | --- | --- | --- | --- |

   Coverage map
   | Requirement / scenario | Covered by step (which artifact)? | Notes |
   | --- | --- | --- |

   Metrics: <N scenarios> · <req coverage %> · <artifacts checked> · <critical count>
   ```
9. Read-only + anti-recursion: `Do not edit any file. Do not invoke /plan-review or any planning skill.`
10. **Constitution (conditional):** if the resolved constitution `$const_path`
    exists (Step 1), read it —
    a MUST-principle violation is a CRITICAL finding, and additionally verify the
    plan's `## Constitution Check` table is internally consistent (every principle
    has a row; every ⚠️ verdict has a resolving or explicitly-justified note).

## Step 7 — Auto-fold and report

Partition the Stage 2 findings by tag.

**Apply** every MECHANICAL fix in ONE revision pass, re-writing the plan file
in place (`plan` Step 4). Guards:

- A finding tagged MECHANICAL without an exact location + replacement is
  misdeclared — demote it to DECISION-REQUIRED, never guess an edit.
- **Conflict rule:** when the two reviewers return overlapping or
  contradictory MECHANICAL fixes for the same text, consistency wins
  terminology, cleanliness wins structure and wording; if still ambiguous,
  demote both to DECISION-REQUIRED.
- Never apply a DECISION-REQUIRED finding — those choices belong to the user.

**Report** three groups, by ID: **applied**, **surfaced for decision** (the
DECISION-REQUIRED findings and demotions, plus the consistency reviewer's
coverage map + metrics as-is), and **dead lanes** (if any reviewer died). If
the Step 5 fold or this auto-fold touched content covered by an existing
`zoom/*.html`, add a reminder that those zooms need re-dispatch — re-zooming
happens in the plan flow (`plan` "Revision completeness"), never from inside
this skill.

Then return to the approval question when invoked from `plan` Step 6, or end
with the report when invoked standalone.

## Stage-2-only mode

Entered by a direct consistency ask ("check plan consistency", "consistency
review") or the "Stage 2 only" gate choice (see When to use / Step 2). Ensure
Step 1 has run — it is the shared prerequisite of every mode — then skip
Steps 3–5 and run Steps 6–7 against the plan as it stands, including the
auto-fold.

**Write confirm on the direct-ask path:** a bare "check plan consistency" was
previously read-only, so when this mode is entered by trigger phrase (not the
Step 2 gate choice, whose description already announces the auto-fold), ask
one single-select question before Step 7 writes anything — header
"Auto-fold", options "Apply safe fixes (Recommended)" / "Surface only". On
"Surface only", run Step 7's partition + report but skip the write.

### Do NOT

- Do **not** run `approve-plan.sh` from inside this skill — review never releases the gate.
- Plan-file writes from inside this skill are limited to exactly two moments — Step 5 (the user's fold-gate selections) and Step 7 (MECHANICAL-tagged Stage 2 findings). Never apply an unselected or DECISION-REQUIRED finding, never touch zoom artifacts or repo source files, and always follow `plan` Step 4's re-write-in-place rule.
- Do **not** detect domains or ask the user to select topics — the review topics are fixed (see the dimension table above).
