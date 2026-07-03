---
name: plan-domain-backend-api
description: >
  Domain planning skill for BACKEND API work, invoked ONCE by mentor-plan
  (Step 1.5 domain detection) when the task touches routes, endpoints,
  handlers, services, schemas/DTOs, or API contracts. Orchestrator-invoked
  only (like plan-review) — not a /command. Shapes the research dispatch
  (find route definitions, handlers, schemas, callers) and the plan-author
  prompt to produce a before/after API contract comparison in the plan HTML —
  per-endpoint diff tables plus a sequence-flow viz for changed flows. No
  mockup-author agent: contract tables are plain Markdown and live in both
  the rendered body and plan-source.
---

# Backend-API Planning Domain

Invoked **once per plan** by `mentor-plan`'s domain detection (top of Step 1.5) when the task
touches API/endpoint/route/handler/schema/DTO/contract work. Lighter than the frontend domain:
it adds directives to the agents the flow already dispatches — **no extra agent dispatch**.

The signature deliverable: the plan carries a **before/after API contract comparison** — a
per-endpoint diff table, a schema diff per changed DTO, and a sequence-flow viz for each changed
flow — so the user sees exactly how the contract moves before approving.

## Objective — reviewer comprehension first

The ONE goal: a reviewer, before approving, instantly sees **how each API contract moves and
whether it breaks callers**. Every viz choice serves that. The plan-author MUST hit this bar:

- Each in-scope endpoint carries a **status badge**: NEW · CHANGED · BREAKING · DEPRECATED.
- Every field-level delta is **color-coded**: added (green), removed (red), changed (amber).
- Each BREAKING endpoint names its **affected callers** (blast radius) from research EVIDENCE.
- A reviewer can answer "what breaks, and who must change?" from the viz alone — no source dive.

## 1 — Shape the research dispatch (folds into 1.5a)

Append these directives to the backend-relevant `Explore` agents' prompts:

- Locate the **route/endpoint definitions** and their **handlers/controllers** for every
  endpoint in scope.
- Locate the **request/response schemas or DTOs**, validation rules, and the distinct
  **status-code paths**.
- Locate the **API-client callers** — who consumes each endpoint (frontend services, other
  backends, jobs) — so contract changes name their blast radius.
- For each endpoint, **classify the change as backward-compatible or BREAKING** (a removed/renamed
  field, narrowed type, new required field, or changed status code is breaking) and **count the
  callers**, so FINDINGS can drive the status badge and the "Callers affected" cell.

The research return contract is unchanged (FINDINGS ≤ ~400 words / EVIDENCE `file:line` / OPEN
QUESTIONS), with one addition: FINDINGS include a compact **current-contract snapshot** per
in-scope endpoint — method, path, request shape, response shape, status codes, compat
classification, and caller count.

## 2 — Shape the plan-author prompt (folds into 1.5b)

Append to the plan-author agent's prompt — all of it in plain Markdown (it renders in both the
body and `plan-source`; no divergence, no escaping concerns):

- A per-endpoint **before/after contract table**. The first column is a **Status** cell carrying a
  badge token (`NEW` / `CHANGED` / `BREAKING` / `DEPRECATED`) and a `compat: breaking` /
  `compat: backward-compatible` tag. Columns:
  `Status · Method · Path · Request shape · Response shape · Status codes · Callers affected · Note`.
  The `Callers affected` cell lists consumers from research EVIDENCE (or `none in repo`).
- A **schema diff** per changed DTO — added / removed / changed fields, with types — written as
  `+`/`-`/`~`-prefixed lines (the body colorizes these without changing the text; see Step 8
  rule 8).
- A **sequence-flow viz spec** per changed flow (caller → endpoint → handler → downstream),
  rendered in the body as a flow diagram of your design. Encode the diff: **unchanged** hops
  plain; **new** hops visually marked as added; **removed** hops marked as removed (labelled
  "removed"); **changed** hops marked as changed. Label each arrow with the moved field/status;
  include a legend line that decodes the markings.
- Implementation steps name the real route/handler/schema files from research EVIDENCE and the
  affected callers.

All of the above is **plain Markdown** — the badge/compat tokens and the `+`/`-`/`~` diff lines
are literal text, so they live identically in the body and `plan-source`; the body only *styles*
them (see §3). The status badge tokens and `compat:` tags are what make "what breaks" scannable.

## 3 — Plan HTML deliverable (Step 8, html format)

Two tiers:

**Stays Markdown (identical in body + plan-source):** the contract table (with its `Status` badge
and `compat:` tokens), the per-DTO schema diffs, and the sequence-flow viz spec. No escaping, no
divergence. The body *styles* these without changing the source text — render each table status
token as a visually distinct NEW/CHANGED/BREAKING/DEPRECATED badge, and colorize the `+`/`-`/`~`
schema lines (the literal `+`/`-`/`~` Markdown stays in plan-source; the CSS only colorizes).
Render the sequence-flow as a flow diagram with new/removed/changed hops visually distinct, plus
a legend.

**Body-only rich viz (needs a plan-source stand-in):** the ONLY part not byte-identical to
plan-source is the optional before/after **JSON example** pair per BREAKING/CHANGED endpoint — a
side-by-side before/after panel (before = current payload, after = proposed) inside
`<pre><code>` (escape `&`/`<`/`>`). A request+response JSON shown side-by-side beats a prose table
for "what does the payload actually look like now vs. then." For these, the `plan-source` block
carries a one-line prose stand-in per endpoint under a `## Contract examples` heading ("Body shows
before/after request+response JSON for `POST /x`") — never the escaped JSON/markup. That stand-in is
**plan-source-only**: in the body the JSON panels appear *in its place* — do **not** also echo the
stand-in sentence as a caption or bullet beside the panels (Step 8 rule 3, stand-in handling). Skip
the JSON pair when an endpoint has no payload delta (path/verb-only). No extra agent is dispatched in this
domain — the plan-author produces all of the above.

## Markdown-mode rendering (when format = md)

When mentor-plan **Step 0** resolved **md**, this domain is almost unchanged — its artifacts were
already plain Markdown. There is no body/`plan-source` split (the `.md` is canonical). Realize each
artifact in the `.md` as follows:

- **Contract table** — the GFM table as-is. The `Status` cell keeps its literal `NEW` / `CHANGED` /
  `BREAKING` / `DEPRECATED` token and `compat:` tag (plain text, not a CSS badge — still fully
  scannable).
- **Schema diffs** — put the `+`/`-`/`~` lines in a **` ```diff ` fenced block** so GitHub/GitLab
  colorize added (`+`) and removed (`-`) lines automatically; keep `~` for a changed field with a
  trailing note. No CSS needed.
- **Sequence-flow** — render as a Mermaid **`sequenceDiagram`** (caller → endpoint → handler →
  downstream). Encode the diff in labels/notes (Mermaid sequence can't per-arrow color): mark **new**
  hops with a `+`/`Note over` label, **removed** with a "removed" note, **changed** with a "changed"
  note, and add a one-line **legend** beneath the diagram. (When node status-coloring matters more
  than message order, a `flowchart` + `classDef` new/removed/changed + a legend table is an acceptable
  alternative — pick exactly one, never both. Avoid a `;` inside a `Note over …:` — it truncates.)
- **JSON examples** (BREAKING/CHANGED endpoints) — a before/after pair of **fenced ` ```json `
  blocks** (stacked; md is single-column). No escaping, no `<pre>`, no plan-source stand-in — the
  `.md` is canonical. Skip when there is no payload delta.

Per Step 8M's anti-duplication rule: the table/diagram IS the artifact — do not also restate its
contents in prose (a one-line caption + the legend are the only adjacent prose).
