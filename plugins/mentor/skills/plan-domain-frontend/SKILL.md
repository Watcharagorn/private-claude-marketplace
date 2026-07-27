---
name: plan-domain-frontend
description: >
  Domain planning skill for FRONTEND / UX-UI work, invoked ONCE by `plan`
  (Step 3 domain routing) when the task touches components, pages, styles,
  layout, or design systems. Not a /command. Shapes the research prompts and
  the Markdown plan body: a before/after delta table, ASCII zone wireframe,
  and token table per changed surface, all derived from the project's REAL
  design tokens and source. The live before/after HTML/CSS mockup contract
  (prompt token mentor:frontend-mockup) is carried by the per-combo zoom
  agents of the opt-in HTML zoom (`mentor:zoom`, delegated from `plan`
  Step 5), when the user explicitly requests a visual zoom of a UI surface.
---

# Frontend Planning Domain

Invoked **once per plan** by `plan`'s domain routing (Step 3) when the task touches UX/UI —
components, pages, styles, layout, design systems, theming, responsive work. This skill adds
directives to the research and plan-writing the flow already performs, plus — **only when the user
requests an HTML zoom of a UI surface** (`mentor:zoom`, via `plan` Step 5) — the mockup contract
(§4), folded into each UI combo agent's prompt.

The plan deliverable (Markdown, always): a **before/after delta table + ASCII zone wireframe +
token table** per changed surface (§3), precise about *what* changes and approximate about layout.
When the user explicitly requests a visual zoom of a UI surface, that combo's zoom html file
carries **live before/after HTML/CSS mockups** faithful to the project's real design tokens, fonts,
and component structure (§4).

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
`ui-ux-pro-max`), else the built-in `artifact-design`. If none is listed, degrade gracefully —
proceed without it and note the omission in the plan's Context.

Three global rules govern everything in this domain (restated as hard rules in §Constraints):

1. The discovered design skill controls design and review decisions — invoke it first.
2. All design work derives from **REAL front-end source files** — never invented structure.
3. **Never create mockup HTML files inside the repo source tree** (`docs/`, `mockups/`, or any
   documentation directory). The opt-in zoom html lives in mentor's zooms dir at
   `<repo>/.mentor/zooms/<subject-slug>/…` (exempt from the plan gate, so the write is allowed) —
   so that is the one compliant place for mockup markup.

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

## 4 — Mockup contract (HTML zoom only — `mentor:zoom` Step 3)

> **This skill owns the contract.** `mentor:zoom` (Step 3 — delegated from `plan` Step 5 when
> zooming a plan) generates zoom artifacts by dispatching one
> agent per topic × perspective combo; when a combo's topic is a UI surface and the perspective
> needs to *see* that surface to do its job — End user, Reviewer/Architect, or QA/Tester (the
> tester must see the states they verify), everyone **except** the Implementor, whose zoom is
> about file wiring and step order rather than appearance — fold this section into that combo
> agent's prompt. Subagents cannot dispatch nested agents (see `mentor:dispatch-agents`,
> "no nested fan-out"), so there is no separate mockup-author
> dispatch — the combo agent reads the real source files and authors + embeds the mockup panes
> inside its own zoom file. The `.md` plan (§3) stays the source of truth; the zoom is a
> supplementary visual aid for the requested surface(s) only.

Rules:

- **Sequencing.** Zoom combos dispatch AFTER the plan is written — the AFTER pane needs the
  authored `Proposed UI changes per surface` spec.
- **Skip when there is no visual delta** (e.g. a pure component refactor): the zoom notes
  "no visual change" instead. Never force identical before/after panes.
- **Regenerate on revision — completeness-checked, not memory-driven.** If the
  `Proposed UI changes per surface` section changes during a Keep-planning iteration (or a global
  product decision invalidates prior visuals), `grep -l` the invalidated term/content across EVERY
  existing html in the plan's zooms dir (`.mentor/zooms/<plan-slug>/`) and re-dispatch ALL matching combos in one batched
  message with the updated spec — never just "that combo" from memory, and never ship stale panes.
  Wait for the re-dispatches to complete before any `plan-review` dispatch reads the zoom files.
- **Inline panes only — never a hosted Artifact.** The panes are embedded **inline** as
  `<iframe srcdoc>` in the combo's single self-contained zoom html file; the agent must **not**
  call the `Artifact` tool or return a claude.ai-hosted URL — a published artifact would be a
  detached, drifting copy.

### Combo-agent prompt inputs

The UI combo agent's prompt MUST contain the literal token `mentor:frontend-mockup` and these
inputs (so pane fidelity never depends on the agent re-researching):

1. The changed-surface list (scoped to the combo's topic) with the real component / token /
   font **file paths** from research EVIDENCE.
2. The plan's `Proposed UI changes per surface` entries relevant to the topic, verbatim.
3. The distilled design principles from the Preflight's discovered design skill.
4. The instruction: *"Read the real source files yourself. The BEFORE pane must faithfully
   reproduce the current UI; the AFTER pane the proposed UI. Invent nothing — every color, font,
   spacing value, and structural element comes from the project's actual source or the
   proposed-changes spec."*
5. The isolation requirement: *"Author each pane as a COMPLETE self-contained mini-HTML document
   (its own `<style>` with the project's real tokens inlined, system-font fallback) and embed it
   via `<iframe srcdoc>`. **Static HTML/CSS + inline SVG ONLY — no JavaScript at all (no
   `<script>`, no `<canvas>`), no external CSS/JS, no images.** The pane must render identically
   inside an `<iframe srcdoc>` with scripting disabled."*
6. The review-clarity requirement (the quality bar above): *"Place numbered markers (➊➋➌) directly
   on the changed elements in the AFTER pane — a small absolutely-positioned span on a
   `position:relative` wrapper, self-contained — and render a callout list keyed to the same
   numbers beside the panes. Verify the AFTER holds at 360px; when reflow matters, add a third
   AFTER pane with its iframe capped at 360px wide, labeled mobile. Render every color/font token
   you introduced or changed as a swatch strip (color tokens get a color chip). Call out any
   contrast or focus-order delta alongside. Order surfaces by user-visibility (primary surface
   first)."*
7. The escaping rule: *"HTML-attribute-escape every mini-doc before embedding it in `srcdoc` —
   **in this order**: `&` → `&amp;` FIRST, then `"` → `&quot;`. (Order matters — escaping `"`
   first would let the later `&` pass corrupt the `&quot;` entities. Do NOT escape `<` / `>`;
   `srcdoc` does not need it.)"*

The zoom file follows `mentor:zoom` Step 3's constraints (single self-contained file authored in
one `Write`, inline CSS, WCAG-AA, ≥15px); the pane/badge/callout styling is the agent's to design.

## Constraints recap (hard rules)

1. Invoke ONE design skill once before writing the plan — discovered at runtime per the Preflight
   (`frontend-design:frontend-design` when installed, else the strongest present alternative, else
   `artifact-design`); distill, don't skip.
2. Delta renderings, mockups, and implementation steps derive ONLY from real front-end source
   files.
3. No mockup files inside the repo source tree, ever — the opt-in zoom html (in the gate-exempt
   `.mentor/zooms/<subject-slug>/` dir) is the only mockup surface.
