---
name: plan-domain-dynamic
description: >
  Dynamic-domain fallback planning skill, invoked ONCE by `plan`
  (Step 3 domain routing) when NO registered domain skill matched. Not a
  /command. Unlike the static domain skills it does not know the domain in
  advance: it owns a dispatch contract for a small domain-definer agent
  (prompt token mentor:domain-dynamic) that names the task's domain on the
  fly, derives global best practices for planning in that domain, and returns
  a compact DOMAIN BRIEF whose directives shape the research prompts and the
  Markdown plan — so every plan gets domain-expert treatment.
  Instruction-only.
---

# Dynamic-Domain Planning Fallback

Invoked **once per plan** by `plan`'s domain routing (Step 3) when **no registered domain
matched** (frontend, backend-api). The registered skills hardcode their domain's directives; this
skill *derives* them: it dispatches a small **domain-definer agent** that identifies the domain,
distills the global best practices experts apply when planning work in that domain, and returns
them as a compact brief. The main thread folds the brief into the research and plan-writing the
flow already performs; it never synthesizes domain expertise itself.

## Objective — reviewer comprehension first

The ONE goal: the plan must read as if a **domain expert planned it** and a **generalist can
review it**. The brief exists to inject expert-level shaping (what to research, what the plan
must contain, how to visualize it, what typically goes wrong); the generalist-reviewer principle
(owned by `plan` Step 4, not here) governs how it is written.

## 1 — Domain-definer dispatch (before Step 2 research)

ONE `Agent` call — `subagent_type: general-purpose`, `model: sonnet`, `effort: medium` —
dispatched **BEFORE the `plan` Step 2 (Research) agents**, because its RESEARCH DIRECTIVES
shape their prompts. The agent is small (≤ ~350-word return, no plan authoring); the sequential
hop is the only ordering that makes the brief's research directives real.

- The prompt MUST contain the literal token `mentor:domain-dynamic` — traceability only.
- **Input:** the user's task statement.
- **Grounding:** the agent MAY take ~2 repo peeks (README / CLAUDE.md / top-level listing) to
  ground the domain identification, and MAY use up to ~2 web searches when the domain is
  unfamiliar. If web search is unavailable, derive from training knowledge — never stall. It
  must flag low-confidence domain identification explicitly.

### Required return — DOMAIN BRIEF (≤ ~350 words, nothing else)

```
DOMAIN: <named domain(s)>  ·  confidence: <high|low>
BEST PRACTICES:
- <practice — one line, with its WHY>   (5–8 entries)
RESEARCH DIRECTIVES:
- <what the research agents should additionally locate>
AUTHOR DIRECTIVES:
- <domain-specific plan sections/checks — e.g. rollback plan for a migration,
   idempotency notes for a job>
VIZ IDIOM: <recommended primary visualization for this domain>
PITFALLS:
- <common failure modes the plan must address>
```

- When multiple domains are named, mark exactly **one as primary** — only the primary's
  VIZ IDIOM drives the plan's visualization choice; secondary domains contribute
  BEST PRACTICES / PITFALLS entries only.
- **Anti-platitude rule:** BEST PRACTICES lists only practices that will **concretely change
  this plan** — no generic advice ("write tests", "document changes") unless the domain gives
  it specific shape.

### Resilience & lifecycle

- **Malformed return:** if the brief is missing required fields, salvage what is present and
  proceed (Step 2 research proceeds regardless); re-dispatch at most once; never block the
  flow on a malformed brief.
- **Late refinement:** if post-research refinement (`plan` Step 3 domain routing, "refine
  after research FINDINGS return") matches a **registered** domain after this fallback already
  ran, invoke that domain skill as usual; its directives supersede the brief's AUTHOR DIRECTIVES
  and VIZ IDIOM (keep PITFALLS as extra edge-case input); do not re-dispatch the definer.
- **Revision rule:** on "Keep planning" / "Keep it current" iterations, **reuse the existing
  DOMAIN BRIEF**; re-dispatch the definer only if the user corrects the domain identification
  (e.g. a flagged `confidence: low` guess) or the task scope changes materially.

### Small-plan folding

For thin scope, fold the definer brief — the synthesis duties and the brief format above — into a
single research agent's prompt as its **first step**, instead of a separate dispatch; include the
`mentor:domain-dynamic` token there too for traceability. Caveat: the RESEARCH DIRECTIVES then
apply only within that agent, and the brief feeds the plan-writing (Step 4) afterwards.

## 2 — Fold into research (`plan` Step 2)

Append the brief's RESEARCH DIRECTIVES to the relevant research agents' prompts (or cover them
directly when not delegating). The research return contract is unchanged (FINDINGS ≤ ~400 words /
EVIDENCE `file:line` / OPEN QUESTIONS).

## 3 — Fold into the plan (`plan` Step 4)

Carry the **full DOMAIN BRIEF** into plan-writing and require:

- A **`## Domain best practices applied`** section placed **after the implementation steps**
  (never between `## Context` and `## Use case scenarios` — the Use case scenarios section of
  `plan` Step 4 owns that slot), plain Markdown. Each row maps a practice → the named
  step/section that honors it. **Omit any practice that changed nothing** — adopted practices
  only, every row names a concrete anchor.
- PITFALLS folded into **Edge cases & assumptions** and **Verification**.
- VIZ IDIOM **adopted — or consciously overridden**: it guides the inline visualization idiom
  (Mermaid / GFM table / ASCII) chosen per `plan` Step 4's visualization decision rule.
- If `confidence: low`, mark the domain assumption **visibly** in the plan per `plan`
  Step 4's "flag anything unverified" convention, so the user can correct it before approving.

## 4 — Plan deliverable (`plan` Step 4)

Everything this skill adds is plain Markdown, inline in the `.md`:

- Render `Domain best practices applied` as a **GFM table** (practice → step/section anchor).
- Realize the brief's VIZ IDIOM inline as a Mermaid diagram / GFM table / ASCII per `plan`
  Step 4's visualization decision rule.

**HTML zoom (opt-in):** when the user explicitly requests a visual zoom of this domain's area
(`plan` Step 5), the brief's VIZ IDIOM may inform the zoom html's richer treatment (styling,
layout, diagram idiom) for the requested area only. The `.md` plan stays the source of truth.
