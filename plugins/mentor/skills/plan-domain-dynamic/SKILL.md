---
name: plan-domain-dynamic
description: >
  Dynamic-domain fallback planning skill, invoked ONCE by mentor-plan
  (Step 1.5 domain detection) when NO registered domain skill matched.
  Orchestrator-invoked only (like plan-review) — not a /command. Unlike the
  static domain skills it does not know the domain in advance: it owns a
  dispatch contract for a small domain-definer agent (prompt token
  mentor:domain-dynamic) that names the task's domain on the fly, derives
  global best practices for planning in that domain, and returns a compact
  DOMAIN BRIEF whose directives shape the research prompts, the plan-author
  prompt, and the plan HTML — so every plan gets domain-expert treatment.
  No new hooks; instruction-only.
---

# Dynamic-Domain Planning Fallback

Invoked **once per plan** by `mentor-plan`'s domain detection (top of Step 1.5) when **no
registered domain matched** (frontend, backend-api). The registered skills hardcode their
domain's directives; this skill *derives* them: it dispatches a small **domain-definer agent**
that identifies the domain, distills the global best practices experts apply when planning work
in that domain, and returns them as a compact brief. The main thread stays **courier + renderer**
— it folds the brief into the agents the flow already dispatches; it never synthesizes domain
expertise itself.

## Objective — reviewer comprehension first

The ONE goal: the plan must read as if a **domain expert planned it** and a **generalist can
review it**. The brief exists to inject expert-level shaping (what to research, what the plan
must contain, how to visualize it, what typically goes wrong); the generalist-reviewer principle
(mentor-plan 1.5b — owned there, not here) governs how it is written.

## 1 — Domain-definer dispatch (before 1.5a)

ONE `Agent` call — `subagent_type: general-purpose`, `model: sonnet`, `effort: medium` —
dispatched **BEFORE the 1.5a research agents**, because its RESEARCH DIRECTIVES shape their
prompts. The agent is small (≤ ~350-word return, no plan authoring); the sequential hop is the
only ordering that makes the brief's research directives real.

- The prompt MUST contain the literal token `mentor:domain-dynamic` — traceability only; it
  satisfies no gate.
- **Token hazard (hard rule).** Never paste any text containing the literal plan-author token
  (the one `plan-author-gate` greps for) into the domain-definer's dispatch prompt — the
  dispatch tracker greps the dispatched prompt, so even a quoted mention would falsely mark the
  plan as authored and silently release the authoring gate. Explanatory sentences like this one
  live in this SKILL.md only, never in the prompt template.
- **Inputs:** the user's task statement and the chosen strategy.
- **Grounding:** the agent MAY take ~2 repo peeks (README / CLAUDE.md / top-level listing) to
  ground the domain identification, and MAY use up to ~2 web searches when the domain is
  unfamiliar. If web search is unavailable, derive from training knowledge — never stall. It
  must flag low-confidence domain identification explicitly.
- **Gate note (by design):** this dispatch touches `.research-dispatched`, which releases
  `plan-read-gate` before any research agent has run. That is intentional (the definer's own
  repo peeks need it); **1.5a research remains mandatory** regardless.
- **Worktree strategies:** the definer is dispatched after `EnterWorktree` per the Step 1.5
  Ordering note, so its repo peeks read the worktree copy.

### Required return — DOMAIN BRIEF (≤ ~350 words, nothing else)

```
DOMAIN: <named domain(s)>  ·  confidence: <high|low>
BEST PRACTICES:
- <practice — one line, with its WHY>   (5–8 entries)
RESEARCH DIRECTIVES:
- <what the Explore agents should additionally locate>
AUTHOR DIRECTIVES:
- <domain-specific plan sections/checks — e.g. rollback plan for a migration,
   idempotency notes for a job>
VIZ IDIOM: <recommended primary visualization for this domain>
PITFALLS:
- <common failure modes the plan must address>
```

- When multiple domains are named, mark exactly **one as primary** — only the primary's
  VIZ IDIOM feeds the THEME spec; secondary domains contribute BEST PRACTICES / PITFALLS
  entries only.
- **Anti-platitude rule:** BEST PRACTICES lists only practices that will **concretely change
  this plan** — no generic advice ("write tests", "document changes") unless the domain gives
  it specific shape.

### Resilience & lifecycle

- **Malformed return:** if the brief is missing required fields, salvage what is present and
  proceed (1.5a research is mandatory regardless); re-dispatch at most once; never block the
  flow on a malformed brief.
- **Late refinement:** if post-research refinement (mentor-plan domain detection, "refine after
  research FINDINGS return") matches a **registered** domain after this fallback already ran,
  invoke that domain skill as usual; its directives supersede the brief's AUTHOR DIRECTIVES and
  VIZ IDIOM (keep PITFALLS as extra edge-case input); do not re-dispatch the definer.
- **Revision rule (mirrors theme stability):** on "Keep planning" / "Keep it current"
  iterations, **reuse the existing DOMAIN BRIEF**; re-dispatch the definer only if the user
  corrects the domain identification (e.g. a flagged `confidence: low` guess) or the task scope
  changes materially.

### Small-plan folding

- **Normal strategy** — no extra dispatch: fold the synthesis duties (and the brief format
  above) into the single research+author agent's prompt as its **first step**, and include the
  `mentor:domain-dynamic` token there too for traceability. That prompt already carries the
  plan-author token, so gate behavior is unchanged.
- **Dispatch strategies with thin scope** — you MAY fold the synthesis into the **first**
  `Explore` agent instead of a separate dispatch, with this caveat: its RESEARCH DIRECTIVES
  then apply only within that agent (sibling Explore prompts are issued in the same message and
  cannot consume them) and the brief feeds only the plan-author (1.5b). The folded agent must
  NOT carry the plan-author token unless it is also the author.

## 2 — Fold into research (1.5a)

Append the brief's RESEARCH DIRECTIVES to the relevant `Explore` agents' prompts. The research
return contract is unchanged (FINDINGS ≤ ~400 words / EVIDENCE `file:line` / OPEN QUESTIONS).

## 3 — Fold into the plan-author (1.5b)

Hand the plan-author the **full DOMAIN BRIEF** and require:

- A **`## Domain best practices applied`** section placed **after the implementation steps**
  (never between `## Context` and `## Use case scenarios` — Step 8b owns that slot), plain
  Markdown identical in the body and `plan-source`. Each row maps a practice → the named
  step/section that honors it. **Omit any practice that changed nothing** — adopted practices
  only, every row names a concrete anchor.
- PITFALLS folded into **Edge cases & assumptions** and **Verification**.
- VIZ IDIOM **adopted into the `THEME:` spec — or consciously overridden there** (html format).
  **In md mode there is no THEME spec** — the VIZ IDIOM instead guides the inline visualization
  idiom (Mermaid / GFM table / ASCII) chosen per Step 8M's decision rule. The main thread keeps
  executing THEME (html) / realizing the idiom (md) only; it never arbitrates between the brief and
  the author (courier + renderer intact).
- If `confidence: low`, mark the domain assumption **visibly** in the plan per Step 8b's
  "flag anything unverified" convention, so the user can correct it before approving.

## 4 — Plan deliverable (Step 8 / Step 8M)

Everything this skill adds is plain Markdown — **no body-only artifacts, no stand-ins, no new
machine-contract rule** — so it is format-agnostic:

- **html (Step 8):** the `Domain best practices applied` content is identical in the body and
  `plan-source`; the body may *style* it (e.g. a practice→step mapping table) and follow the brief's
  VIZ IDIOM via the plan-author's THEME spec — bespoke design as usual.
- **md (Step 8M):** the `.md` is canonical (no plan-source). Render `Domain best practices applied`
  as a **GFM table** (practice → step/section anchor), and realize the brief's VIZ IDIOM inline as a
  Mermaid diagram / GFM table / ASCII per Step 8M's decision rule.
