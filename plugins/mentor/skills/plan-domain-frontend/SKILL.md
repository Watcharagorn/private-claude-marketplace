---
name: plan-domain-frontend
description: >
  Domain planning skill for FRONTEND / UX-UI work, invoked ONCE by `plan`
  (Step 3 domain routing) when the task touches components, pages, styles,
  layout, or design systems. Not a /command. Shapes the research prompts and
  the Markdown plan body: a before/after delta table, ASCII zone wireframe,
  and token table per changed surface, all derived from the project's REAL
  design tokens and source. The live before/after HTML/CSS mockup dispatch
  (prompt token mentor:frontend-mockup) is reserved for the opt-in HTML zoom
  (`plan` Step 5), when the user explicitly requests a visual zoom of a
  UI surface.
---

# Frontend Planning Domain

Invoked **once per plan** by `plan`'s domain routing (Step 3) when the task touches UX/UI —
components, pages, styles, layout, design systems, theming, responsive work. This skill adds
directives to the research and plan-writing the flow already performs, plus — **only when the user
requests an HTML zoom of a UI surface** (`plan` Step 5) — one extra dispatch: the
mockup-author (§4).

The plan deliverable (Markdown, always): a **before/after delta table + ASCII zone wireframe +
token table** per changed surface (§3), precise about *what* changes and approximate about layout.
When the user explicitly requests a visual zoom of a UI surface, the standalone zoom html file
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

## Preflight — invoke the official frontend-design skill

When this domain matches, the main thread invokes `Skill(skill="frontend-design:frontend-design")`
**once**, before writing the plan, and distills its design principles for the plan body (§2) and
any later mockup-author prompt (§4). If that skill is unavailable in the session, degrade
gracefully — proceed without it and note the omission in the plan's Context.

Three global rules govern everything in this domain (restated as hard rules in §Constraints):

1. The official frontend-design skill controls design and review decisions — invoke it first.
2. All design work derives from **REAL front-end source files** — never invented structure.
3. **Never create mockup HTML files inside the repo** (`docs/`, `mockups/`, or any documentation
   directory). The opt-in zoom html lives beside the plan at
   `~/.claude/mentor/<repo>-<hash>/plans/…` — outside the repo — so that is the one compliant
   place for mockup markup.

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
do not inline token values into FINDINGS; whoever renders the deltas (and the mockup-author, if a
zoom is later requested) reads the source itself.

## 2 — Shape the plan body (`plan` Step 4)

Apply these requirements when writing the plan:

- Implementation steps target **REAL component files** (from research EVIDENCE) — never repo
  mockup files, never new files in documentation directories.
- Apply the distilled frontend-design principles from the Preflight.
- Emit an itemized **`## Proposed UI changes per surface`** section — one entry per changed
  surface, each naming the surface, its source file(s), and the concrete visual deltas. This
  section drives the delta rendering (§3) and is the mockup-author's spec if a zoom is requested
  (§4); without it the AFTER cannot be authored.
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

## 4 — Mockup-author dispatch (HTML zoom only — `plan` Step 5)

> **This skill owns the contract.** Dispatch the mockup-author **only** when the user explicitly
> requests an HTML zoom of a UI surface (`plan` Step 5). The `.md` plan (§3) stays the source
> of truth; the zoom is a supplementary visual aid for the requested surface(s) only.

Rules:

- **Sequencing.** Dispatch AFTER the plan is written — the AFTER pane needs the authored
  `Proposed UI changes per surface` spec.
- **Skip when there is no visual delta** (e.g. a pure component refactor): do not dispatch; note
  "no visual change" instead. Never force identical before/after panes.
- **Re-dispatch on revision.** If the `Proposed UI changes per surface` section changes during a
  Keep-planning iteration and the zoom is being refreshed, re-dispatch the mockup-author **before**
  re-writing the zoom html — never ship stale panes.
- **`srcdoc` only — never a hosted Artifact.** The mockup-author returns self-contained `srcdoc`
  mini-docs (per the dispatch contract below); it must **not** call the `Artifact` tool or return a
  claude.ai-hosted URL. The panes are embedded **inline** in the single self-contained zoom html
  file — a published artifact would be a detached, drifting copy.

### Dispatch contract

One `Agent` call — `subagent_type: general-purpose`, `model: sonnet`, `effort: high`. The prompt
MUST contain the literal token `mentor:frontend-mockup` and these inputs:

1. The changed-surface list (scoped to the requested zoom area) with the real component / token /
   font **file paths** from research EVIDENCE.
2. The plan's `Proposed UI changes per surface` section, verbatim.
3. The distilled frontend-design principles from the Preflight.
4. The instruction: *"Read the real source files yourself. The BEFORE pane must faithfully
   reproduce the current UI; the AFTER pane the proposed UI. Invent nothing — every color, font,
   spacing value, and structural element comes from the project's actual source or the
   proposed-changes spec."*
5. The isolation requirement: *"Return each pane as a COMPLETE self-contained mini-HTML document
   (its own `<style>` with the project's real tokens inlined, system-font fallback) suitable for
   an `<iframe srcdoc>`. **Static HTML/CSS + inline SVG ONLY — no JavaScript at all (no `<script>`,
   no `<canvas>`), no external CSS/JS, no images.** The pane must render identically inside an
   `<iframe srcdoc>` with scripting disabled."*
6. The review-clarity requirement (the quality bar above): *"Place numbered markers (➊➋➌) directly
   on the changed elements in the AFTER mini-doc — a small absolutely-positioned span on a
   `position:relative` wrapper, self-contained — and list them in CALLOUTS keyed to the same
   numbers. Verify the AFTER holds at 360px; if reflow matters, return a second AFTER mini-doc
   prefixed `--- AFTER (mobile 360) ---`. List every color/font token you introduced or changed in
   TOKENS. Note any contrast or focus-order delta in A11Y. Order surfaces by user-visibility
   (primary surface first)."*
7. The delivery prohibition (**do not skip — the agent does not otherwise know this**): *"Do NOT
   call the `Artifact` tool and do NOT return any hosted / claude.ai URL. The panes are embedded
   **inline** as `<iframe srcdoc>` in a single self-contained zoom html file — a published Artifact
   is a detached, drifting copy. Return ONLY the self-contained mini-HTML documents in the format
   below; nothing hosted, nothing external."*

**Required return format** (and nothing else) — one block per changed surface, each header field on
its own line with its fixed prefix (so the renderer parses deterministically):

```
### SURFACE: <name>  ·  VIEWPORT: <desktop|mobile|both>
CHANGED: <comma-separated deltas>
CALLOUTS: ➊ <delta 1> | ➋ <delta 2> | ➌ <delta 3>
TOKENS: <name>=<value>, <name>=<value>      (omit line if no token introduced/changed)
A11Y: <contrast / focus-order note>          (omit line if none)
--- BEFORE ---
<!doctype html>…complete self-contained mini-doc, current UI…</html>
--- AFTER ---
<!doctype html>…proposed UI; ➊➋➌ markers ON the changed elements…</html>
--- AFTER (mobile 360) ---
<!doctype html>…optional: proposed UI at 360px, only when reflow matters…</html>
--- END ---
```

### Renderer duties (main thread)

**Receiving the panes** (async): the mockup-author runs in the background, so take its returned
blocks from the **delivered completion message** — never reconstruct them from `subagents/*.jsonl`
or task `.output` files, and if the completion notification is body-less, request them **once** via
the completion channel (a `SendMessage` to the agent). Never busy-poll in Bash.

Parse each block and HTML-attribute-escape every mini-doc (BEFORE, AFTER, and any mobile AFTER)
**in this order**: `&` → `&amp;` FIRST, then `"` → `&quot;`. (Order matters — escaping `"` first
would let the later `&` pass corrupt the `&quot;` entities. Do NOT escape `<` / `>`; `srcdoc` does
not need it.) Drop the escaped docs into `<iframe srcdoc="…">` panes inside the zoom html file —
under zoom, that file IS the container; there is no host plan HTML. Render `CALLOUTS:` as a
numbered list keyed to the ➊➋➌ markers, `TOKENS:` as a swatch strip (color tokens get a color
chip), `VIEWPORT:` as a label on the AFTER pane, `A11Y:` alongside, and a mobile AFTER as a third
AFTER pane with its iframe capped at 360px wide. The zoom file follows `plan` Step 5's
constraints (single self-contained file, inline CSS, WCAG-AA, ≥15px); the pane/badge/callout
styling is yours to design.

## Constraints recap (hard rules)

1. Invoke `frontend-design:frontend-design` once before writing the plan; distill, don't skip.
2. Delta renderings, mockups, and implementation steps derive ONLY from real front-end source
   files.
3. No mockup files inside the repo, ever — the opt-in zoom html (outside the repo) is the only
   mockup surface.
