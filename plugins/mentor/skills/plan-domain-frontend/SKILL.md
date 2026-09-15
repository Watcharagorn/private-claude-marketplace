---
name: plan-domain-frontend
description: >
  Domain planning skill for FRONTEND / UX-UI work, invoked ONCE by `plan`
  (Step 3 domain routing) when the task touches components, pages, styles,
  layout, or design systems — or directly, whenever you want this domain's
  shaping applied. Shapes the research prompts and
  the Markdown plan body: a before/after delta table, ASCII zone wireframe,
  and token table per changed surface, all derived from the project's REAL
  design tokens and source. The live before/after HTML/CSS mockup contract
  (prompt token mentor:frontend-mockup) belongs to `mentor:zooming` and applies
  only when the user explicitly requests a visual zoom of a UI surface.
---

# Frontend Planning Domain

## Host portability

Use a structured question UI when the host offers one; otherwise ask the same focused question directly and wait for the answer. If delegated agents are unavailable or prohibited, perform the required research, review, or implementation serially and retain the same evidence, scope, and verification contract. Treat Mentor helpers as optional host integrations: resolve them with `PLUGIN_ROOT` first, then `CLAUDE_PLUGIN_ROOT`; if neither is available, work from the repository's durable `.mentor/` artifacts and report any state action that cannot be performed safely. This rule overrides later host-specific tool names, preserving user choice and plan continuity across hosts.

Invoked by `plan`'s Step 3 domain routing when the task touches UX/UI — components, pages,
styles, layout, design systems, theming, responsive work — or directly whenever you want this
domain's shaping. Standalone, apply §1 to whatever research is underway and §2–3 to whichever
plan or document you are authoring. This skill adds directives to research and plan-writing; the
live mockup contract for an opt-in HTML zoom lives with the skill that generates zooms
(`mentor:zooming` → `references/ui-mockup-contract.md`).

The plan deliverable (Markdown, always): a **before/after delta table + ASCII zone wireframe +
token table** per changed surface (§3), precise about *what* changes and approximate about layout.
When the user explicitly requests a visual zoom of a UI surface, that combo's zoom html file
carries **live before/after HTML/CSS mockups** faithful to the project's real design tokens, fonts,
and component structure — see §4 for who owns that contract.

## Visualization quality bar (the point of this skill)

The before/after rendering exists for ONE reason: a human reviewing the plan must instantly and
richly understand the UI change **before** approving. Everything below serves that review
experience. The full bar applies to zoom mockups; items 3, 6, and 7 apply directly to the Markdown
delta rendering too. A mockup MUST hit items 1–3; include 4–7 when the change touches them (never
pad identical panes):

1. **Faithful BEFORE** — the current UI reproduced from real source (tokens/fonts/structure), not
   approximated.
2. **Legible AFTER** — the proposed UI with every visual delta *shown*, not just described.
3. **Numbered delta callouts** — each change marked ➊➋➌, keyed to a CALLOUTS list.
4. **Holds at mobile width** — the AFTER must not break at 360px; note reflow behavior.
5. **Changed states** — hover / active / empty / error states shown when the change touches them.
6. **Token swatch strip** — the actual colors/fonts introduced or changed, as swatches.
7. **A11y deltas** — contrast or focus-order changes called out when relevant.

## Preflight — invoke a design skill (runtime discovery, never hardcoded)

When this domain matches, the main thread invokes ONE design/UX skill **once**, before writing the
plan, and distills its design principles for the plan body (§2) and any later UI combo-agent prompt
(§4). Pick it by **runtime discovery** (the same idiom `tour` uses): read the most recent
active-skills system-reminder and pick the strongest design/UX skill present —
`frontend-design:frontend-design` when installed, else the strongest alternative (e.g.
`ui-ux-pro-max`). Do not require a host-specific artifact-design capability. If no relevant design
capability is listed, degrade gracefully — proceed without it and note the omission in the plan's
Context.

Three global rules govern everything in this domain (restated as hard rules in §Constraints):

1. The discovered design skill controls design and review decisions — invoke it first.
2. All design work derives from **REAL front-end source files** — never invented structure.
3. **Never create mockup HTML files inside the repo source tree** (`docs/`, `mockups/`, or any
   documentation directory). The opt-in zoom html lives in mentor's zooms dir at
   `<repo>/.mentor/zooms/<subject-slug>/…` (exempt from the plan gate, so the write is allowed) —
   so that is the one compliant place for mockup markup.

## Platform-rendered surfaces — a narrower fidelity source

Everything above assumes the surface is rendered by the product's **own** component
tree, so "derive from real source" means the repo's design tokens, fonts, and
components (§Constraints recap, rule 2). Some UX/UI changes instead render inside a
**third-party client's own chrome** — a Discord/Slack message embed, a push
notification, an email client's rendering of an HTML email — where there are no repo
tokens or components to derive from, because the repo only builds the *payload* the
platform then renders on its own terms. This is still the frontend domain (it is a
visual, user-facing surface), just with the fidelity source relocated:

- **Skip the Preflight's design-skill discovery** for such a surface. A local design
  system governs the product's own UI, not a platform's chrome — invoking one here has
  nothing to distill from.
- **§1 (research)** locates the **platform's documented render + payload schema**
  (field caps, allowed colors/formatting, size limits) and the **repo's own
  payload-building / emitting code** — the place the message is actually assembled —
  instead of component/token/font files.
- **§3 (deliverable)** — the token table becomes a **payload-shape/limits table**
  (`Field · Constraint · Current value`) instead of a CSS-token table; the delta table
  and callouts are unchanged.
- **§4 (mockup, opt-in zoom only)** — the mockup approximates the platform's own
  chrome faithfully **from its documented render spec**, labeled plainly as an
  approximation (the platform renders it for real; this pane cannot). The *payload
  content* inside that chrome — copy, field values, colors actually sent — still comes
  ONLY from the repo's real payload-building code, same as any other surface: never
  invent copy or values that aren't in the emitting source.

This stays inside the `frontend` row — it is a fidelity-source substitution, not a
second domain, so the routing table never double-fires on this class of surface.

## 1 — Shape the research (`plan` Step 2)

When research is delegated (as `plan` Step 2 suggests), append these directives to the
frontend-relevant research agents' prompts; when researching directly, cover the same points:

- Locate the **component/page files** for every surface in scope.
- Locate the **design-token / theme source** — CSS custom properties, Tailwind config, theme
  files, styled-system tokens — and the **font definitions**.
- Capture the **current styles per surface** (layout, key colors, spacing idiom) and any
  **shared primitives** (buttons, cards, form controls) the proposal should reuse.

The research return contract is unchanged (FINDINGS ≤ ~400 words / EVIDENCE `file:line` / OPEN
QUESTIONS). EVIDENCE **must** include the `file:line` of the token, theme, and font sources —
do not inline token values into FINDINGS; whoever renders the deltas (and the zoom combo agent, if
a zoom is later requested) reads the source itself.

## 2 — Shape the plan body (`plan` Step 4)

Apply these requirements when writing the plan:

- Implementation steps target **REAL component files** (from research EVIDENCE) — never repo
  mockup files, never new files in documentation directories.
- Apply the distilled design principles from the Preflight's discovered design skill.
- Emit an itemized **`## Proposed UI changes per surface`** section — one entry per changed
  surface, each naming the surface, its source file(s), and the concrete visual deltas. This
  section drives the delta rendering (§3) and is the zoom combo agent's mockup spec if a zoom is
  requested (§4); without it the AFTER cannot be authored.
- When a change makes a surface **full-bleed/full-height**, repositions it, or alters its
  **z-order**, call out the **stacking-context / overlap / hit-test risk** (which existing surface it
  may now cover, and the toggle / `pointer-events` boundary that could break) and name the **e2e
  test** that guards it — the visual renderings show appearance, not layering, so this risk must be
  in prose.

## 3 — Plan deliverable (`plan` Step 4)

Realize the `## Proposed UI changes per surface` section inline in the `.md`, per surface, in this
order:

1. **Before/After delta table** (GFM) — the precise, reviewable contract:
   `Surface · Element · Before · After · Token / why`. Each ➊➋➌ delta is one row. This is the primary
   artifact — exact about *what* changes.
2. **ASCII zone wireframe** in a code fence — **only when layout/position changes** (added panel,
   moved CTA, new column): before and after, side by side or stacked, changed zones marked ➊➋➌. ASCII
   shows *true* relative position — **do not use a Mermaid graph for a wireframe** (it auto-lays-out
   and would imply a layout it isn't expressing).
3. **Token table** (GFM) — `Token · Value · Note`, with the hex **backticked** (e.g. `` `#0969da` ``)
   so GitHub renders an inline color swatch; elsewhere it degrades to plain code.
4. **➊➋➌ callout list** keyed to the table/wireframe markers.

State plainly in each surface's section that the plan shows the **deltas precisely (table) and
layout approximately (ASCII)** — it is **not** a live or pixel-faithful preview (that is the opt-in
HTML zoom's `<iframe>` mockup, §4). For a surface with **no visual delta**, a one-line "no visual
change" note suffices. The §2 stacking-context / overlap / z-order risk prose still applies (it was
always prose, never the rendering). Per `plan` Step 4's anti-duplication rule, the delta table
+ ASCII wireframe IS the surface's visualization — do not also emit a separate per-topic UI diagram
for the same surface.

## 4 — Mockup contract (HTML zoom only)

When the user asks for an HTML zoom of a UI surface, the zoom's combo agents author live
before/after mockup panes. That contract — which perspectives get panes, the no-JS
`iframe srcdoc` isolation rule, the seven prompt inputs, the escaping order — lives with
the skill that dispatches those agents: **`mentor:zooming` →
`references/ui-mockup-contract.md`**. Read it there when you need to know what a UI zoom
will produce; do not restate it here, since a second copy is how the panes and the plan
drift apart.

What this skill owes that contract is the material it consumes: §3's
`Proposed UI changes per surface` entries, the real component/token/font file paths from
research EVIDENCE, and §1's distilled design principles. A zoom whose combos get those is
faithful; one that gets a paraphrase is not.

## Constraints recap (hard rules)

1. Invoke ONE design skill once before writing the plan — discovered at runtime per the Preflight
   (`frontend-design:frontend-design` when installed, else the strongest present alternative);
   distill it, or record the explicit no-capability fallback.
2. Delta renderings, mockups, and implementation steps derive ONLY from real front-end source
   files.
3. No mockup files inside the repo source tree, ever — the opt-in zoom html (in the gate-exempt
   `.mentor/zooms/<subject-slug>/` dir) is the only mockup surface.
