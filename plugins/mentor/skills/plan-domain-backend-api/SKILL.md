---
name: plan-domain-backend-api
description: >
  Domain planning skill for BACKEND API work, invoked ONCE by `plan`
  (Step 3 domain routing) when the task touches routes, endpoints, handlers,
  services, schemas/DTOs, or API contracts. Not a /command. Shapes the
  research (find route definitions, handlers, schemas, callers) and the
  Markdown plan to carry a before/after API contract comparison —
  per-endpoint diff tables, schema diffs, and a Mermaid sequence-flow per
  changed flow. No mockup-author agent; richer styled panels are reserved
  for the opt-in HTML zoom (`plan` Step 5).
---

# Backend-API Planning Domain

Invoked **once per plan** by `plan`'s domain routing (Step 3) when the task touches
API/endpoint/route/handler/schema/DTO/contract work. Lighter than the frontend domain: it adds
directives to the research and plan-writing the flow already performs — **no extra agent dispatch**.

The signature deliverable: the plan carries a **before/after API contract comparison** — a
per-endpoint diff table, a schema diff per changed DTO, and a sequence-flow viz for each changed
flow — so the user sees exactly how the contract moves before approving.

## Objective — reviewer comprehension first

The ONE goal: a reviewer, before approving, instantly sees **how each API contract moves and
whether it breaks callers**. Every viz choice serves that. The plan MUST hit this bar:

- Each in-scope endpoint carries a **status badge**: NEW · CHANGED · BREAKING · DEPRECATED.
- Every field-level delta is **marked**: added (`+`), removed (`-`), changed (`~`).
- Each BREAKING endpoint names its **affected callers** (blast radius) from research EVIDENCE.
- A reviewer can answer "what breaks, and who must change?" from the viz alone — no source dive.

## 1 — Shape the research (`plan` Step 2)

When research is delegated (as `plan` Step 2 suggests), append these directives to the
backend-relevant research agents' prompts; when researching directly, cover the same points:

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

## 2 — Shape the plan body (`plan` Step 4)

Apply these requirements when writing the plan — all of it plain Markdown in the `.md` (the
canonical plan):

- A per-endpoint **before/after contract table**. The first column is a **Status** cell carrying a
  badge token (`NEW` / `CHANGED` / `BREAKING` / `DEPRECATED`) and a `compat: breaking` /
  `compat: backward-compatible` tag. Columns:
  `Status · Method · Path · Request shape · Response shape · Status codes · Callers affected · Note`.
  The `Callers affected` cell lists consumers from research EVIDENCE (or `none in repo`).
- A **schema diff** per changed DTO — added / removed / changed fields, with types — written as
  `+`/`-`/`~`-prefixed lines.
- A **sequence-flow viz** per changed flow (caller → endpoint → handler → downstream). Encode the
  diff: **unchanged** hops plain; **new** hops marked as added; **removed** hops marked as removed
  (labelled "removed"); **changed** hops marked as changed. Label each arrow with the moved
  field/status; include a legend line that decodes the markings.
- Implementation steps name the real route/handler/schema files from research EVIDENCE and the
  affected callers.

The status badge tokens and `compat:` tags are what make "what breaks" scannable.

## 3 — Plan rendering (`plan` Step 4)

Realize each artifact in the `.md` as follows:

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
  blocks** (stacked; md is single-column). A request+response JSON shown side-by-side beats a prose
  table for "what does the payload actually look like now vs. then." Skip when there is no payload
  delta (path/verb-only).

Per `plan` Step 4's anti-duplication rule: the table/diagram IS the artifact — do not also
restate its contents in prose (a one-line caption + the legend are the only adjacent prose).

## HTML zoom (opt-in)

When the user explicitly requests a visual zoom of this domain's area (`plan` Step 5), the
zoom html file may carry the richer treatment for the requested endpoints only: status tokens
rendered as visually distinct NEW/CHANGED/BREAKING/DEPRECATED badges, colorized `+`/`-`/`~` schema
lines, a styled sequence-flow diagram with new/removed/changed hops visually distinct plus a
legend, and side-by-side before/after JSON contract panels in `<pre><code>` (escape `&`/`<`/`>`).
The `.md` plan stays the source of truth.
