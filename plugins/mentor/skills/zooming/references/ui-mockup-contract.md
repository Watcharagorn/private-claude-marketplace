# The UI mockup contract

Read this when a zoom combo's topic is a **UI surface** and the perspective needs to
*see* that surface to do its job — End user, Reviewer/Architect, or QA/Tester (the
tester must see the states they verify). Everyone **except** the Implementor, whose
zoom is about file wiring and step order rather than appearance: a pixel-faithful
mockup is redundant there.

Fold this contract into that combo agent's prompt. Combo agents must not dispatch
nested agents, so there is no separate mockup-author dispatch — the combo agent reads
the real source files and authors + embeds the mockup panes inside its own zoom file.
The `.md` plan stays the source of truth; the zoom is a supplementary visual aid for
the requested surface(s) only.

`mentor:plan-domain-frontend` reads this file too, when it needs to say what a UI zoom
will produce. This is the single copy, so the two can't drift.

## Rules

- **Sequencing.** Zoom combos dispatch AFTER the plan is written — the AFTER pane needs
  the authored `Proposed UI changes per surface` spec.
- **Skip when there is no visual delta** (e.g. a pure component refactor): the zoom
  notes "no visual change" instead. Never force identical before/after panes.
- **Regenerate on revision.** A changed `Proposed UI changes per surface` section — or a
  global product decision that invalidates prior visuals — re-dispatches the affected
  combos per `SKILL.md` → **Step 5 — Re-zoom on revision**, which owns the
  completeness-checked sweep and the condition for calling a re-zoom finished. Never
  ship stale panes.
- **Inline panes only — never a hosted Artifact.** The panes are embedded **inline** as
  `<iframe srcdoc>` in the combo's single self-contained zoom html file; the agent must
  **not** call the `Artifact` tool or return a claude.ai-hosted URL — a published
  artifact would be a detached, drifting copy.

## Combo-agent prompt inputs

The UI combo agent's prompt MUST contain the literal token `mentor:frontend-mockup` and
these inputs, so pane fidelity never depends on the agent re-researching:

1. The changed-surface list (scoped to the combo's topic) with the real component /
   token / font **file paths** from research EVIDENCE.
2. The plan's `Proposed UI changes per surface` entries relevant to the topic, verbatim.
3. The distilled design principles from the discovered design skill.
4. The instruction: *"Read the real source files yourself. The BEFORE pane must
   faithfully reproduce the current UI; the AFTER pane the proposed UI. Invent nothing
   — every color, font, spacing value, and structural element comes from the project's
   actual source or the proposed-changes spec."*
5. The isolation requirement: *"Author each pane as a COMPLETE self-contained mini-HTML
   document (its own `<style>` with the project's real tokens inlined, system-font
   fallback) and embed it via `<iframe srcdoc>`. **Static HTML/CSS + inline SVG ONLY —
   no JavaScript at all (no `<script>`, no `<canvas>`), no external CSS/JS, no
   images.** The pane must render identically inside an `<iframe srcdoc>` with
   scripting disabled."*
6. The review-clarity requirement: *"Place numbered markers (➊➋➌) directly on the
   changed elements in the AFTER pane — a small absolutely-positioned span on a
   `position:relative` wrapper, self-contained — and render a callout list keyed to the
   same numbers beside the panes. Verify the AFTER holds at 360px; when reflow matters,
   add a third AFTER pane with its iframe capped at 360px wide, labeled mobile. Render
   every color/font token you introduced or changed as a swatch strip (color tokens get
   a color chip). Call out any contrast or focus-order delta alongside. Order surfaces
   by user-visibility (primary surface first)."*
7. The escaping rule: *"HTML-attribute-escape every mini-doc before embedding it in
   `srcdoc` — **in this order**: `&` → `&amp;` FIRST, then `"` → `&quot;`. (Order
   matters — escaping `"` first would let the later `&` pass corrupt the `&quot;`
   entities. Do NOT escape `<` / `>`; `srcdoc` does not need it.)"*

The zoom file itself follows the per-file spec in `SKILL.md` Step 3 (single
self-contained file authored in one `Write`, inline CSS, WCAG-AA, ≥15px); the
pane/badge/callout styling is the agent's to design.
