---
name: plan-domain-architecture
description: >
  Domain planning skill for ARCHITECTURE / system-structure work, invoked ONCE
  by mentor-plan (Step 1.5 domain detection) when a plan changes structure — a
  new/changed/removed service, container, datastore, queue, external integration,
  component, or data flow. Orchestrator-invoked only (like plan-review) — not a
  /command. Shapes the research dispatch (map the current architecture, its
  containers, external systems, and the edges between them) and the plan-author
  prompt to produce a before/after C4-model visualization in the plan HTML —
  diff-highlighted Context / Container (/ Component) diagrams, rendering only the
  C4 levels the change actually moves. No extra agent: the C4 spec is plain prose
  that lives in plan-source and is rendered to polished HTML by the main thread.
---

# Architecture (C4) Planning Domain

Invoked **once per plan** by `mentor-plan`'s domain detection (top of Step 1.5) when the task
**changes system structure**. Like the backend-api domain (and unlike frontend), it adds directives
to the agents the flow already dispatches — **no extra agent dispatch**.

The signature deliverable: the plan carries a **before/after C4-model view** of the system — a
[C4](https://c4model.com) diagram at each level the change touches, with new/changed/removed elements
visually distinct — so the reviewer sees *how the system's structure moves* before approving.

**C4 in one breath (define it for the reviewer in the plan too).** The **C4 model** describes software
architecture at four zoom levels: **L1 System Context** (the system as one box, its human actors, and
the external systems it talks to — "how it fits the world"), **L2 Container** (the separately
deployable/runnable units *inside* the system — web app, API, database, ETL job, queue — and how they
communicate — "the moving parts"), **L3 Component** (the major components *inside one* container), and
**L4 Code** (class-level; almost never worth drawing). This domain uses **L1 + L2, and L3 only when
one container gains significant internal structure. L4 is never rendered.**

## Objective — reviewer comprehension first

The ONE goal: a reviewer, before approving, instantly sees **how the system's structure moves** —
which containers / components / integrations are **added, changed, or removed**, and **how they
communicate** — from the diagram alone, no source dive. Every choice serves that:

- Each element carries a **status**: NEW · CHANGED · REMOVED · UNCHANGED.
- New elements/relationships are **added-green**, changed **amber**, removed **struck/red**, unchanged
  **plain** — with a legend.
- People and external systems are drawn **distinctly** from in-system containers (C4 convention).
- A reviewer can answer "what new pieces appear, what do they talk to, and what's the blast radius on
  the existing system?" from the viz alone.

## Fire condition (the conditional — match precisely)

**Fire** when the plan **adds / removes / relocates a structural element**:

- a **service / container / deployable or runnable unit** (web app, API, worker, ETL/batch job, CLI);
- a **datastore / queue / cache / topic** (a new table-group that forms a new data boundary counts);
- an **external integration or system boundary** (a new third-party API, a new account/region/network
  boundary, a new actor/persona interaction);
- a **component** (a unit with its own responsibility) **inside** a container, when it is significant;
- a **call / data flow** between any of the above (a new sync call, async message, or data write).

**Do NOT fire** for non-structural changes — there is no C4 delta to draw:

- pure **copy / content** edits, **config-value** tweaks, **dependency** bumps;
- **doc-only** changes;
- **pure styling** with no new component;
- **refactors / bug-fixes** that preserve structure (rename-in-place, internal logic fix).

When unsure whether an element is "significant," ask: *would the reviewer's mental model of the system
change?* If no, don't render it.

## Level selection — render only the level(s) that move

L4 is never rendered. Pick levels by **where the delta lives** (a plan may render more than one):

- **L1 System Context** — render when the system's **external boundary** changes: a new/changed
  external system, third-party integration, or actor/persona interaction.
- **L2 Container** — render when **deployable units or their communication** change (a new
  service/datastore/queue, a new inter-container call). This is the **default** for most structural
  changes.
- **L3 Component** — render **only** when **one container gains/changes significant internal
  components**. Pair it with a minimal **L2 locator** (one box) so the reviewer knows which container
  it zooms into.
- **Greenfield** (no meaningful "before"): render the target state with every element tagged **NEW**.

Do not render a level whose elements are all UNCHANGED — that is noise, not comprehension.

## 1 — Shape the research dispatch (folds into 1.5a)

Append these directives to the architecture-relevant `Explore` agents' prompts:

- Map the **current architecture** from real source — the deployable/runnable **units** (from
  manifests, compose / IaC / k8s, service entrypoints), the **datastores / queues / caches**, and the
  **external systems** the codebase calls (client SDKs, HTTP callers, queue producers/consumers).
- Capture the **edges**: who calls / writes to whom, with the **protocol** (HTTP/gRPC/SQL/queue) and
  **sync vs async**, from `file:line` EVIDENCE.
- For **L1**: identify the **system boundary** (what is "us" vs external), the **actors/personas**, and
  the **external systems**.
- Classify each in-scope element and edge **NEW / CHANGED / REMOVED / UNCHANGED** so FINDINGS can drive
  the status + diff colors.

The research return contract is unchanged (FINDINGS ≤ ~400 words / EVIDENCE `file:line` / OPEN
QUESTIONS), with one addition: FINDINGS include a compact **current-architecture snapshot** for the
levels in scope — the elements (id · name · type/technology) and the relationships (from → to · label ·
sync|async).

## 2 — Shape the plan-author prompt (folds into 1.5b)

Append to the plan-author agent's prompt — all of it as **plain-prose C4 spec** (per Step 8 **rule 9**:
a *spec*, never ASCII art). For **each level you render**, provide:

- an **element list** — one line each: `id · name · type/technology · responsibility · status`
  (status ∈ NEW|CHANGED|REMOVED|UNCHANGED);
- a **relationship list** — one line each: `from → to · label/protocol · sync|async · status`.

Make it **diff-aware** (before → after), the same spirit as backend-api's contract diff. State which
levels you are rendering and **why** (which delta justified each). Mark people and external systems so
the renderer can style them distinctly. **Define every architecture term at first use** (generalist-
reviewer principle) — name each container's role, and decode every protocol/abbreviation.

In the **html** format this prose spec lives in `plan-source`; it is the stand-in the body's diagram
replaces (Step 8 rule 3). In the **md** format there is no plan-source — the `.md` is canonical and the
spec is realized as a Mermaid `flowchart` per [§Markdown-mode rendering](#markdown-mode-rendering-when-format--md).

## 3 — Plan HTML deliverable (Step 8, html format)

The body renders each selected C4 level as a **polished HTML/CSS diagram** (Step 8 **rule 10**):

- **Boxes** for containers/components — each with a name + a **technology sub-label** + a one-line
  responsibility; **connectors** between them carrying the relationship label (and protocol /
  sync·async). **People and external systems are styled distinctly** from in-system containers (C4
  convention: e.g. a person glyph / a muted "external" treatment).
- **Diff-highlighted** with a **legend**: NEW added-green, CHANGED amber, REMOVED struck/red, UNCHANGED
  plain. The reviewer must read the change at a glance.
- **Level headers**: label each diagram `C4 L1 — System Context` / `C4 L2 — Container` / `C4 L3 —
  Component: <container>`. Render **only** the levels that moved (Level-selection above).
- **Self-contained** (Step 8 rule 5): pure HTML/CSS, with **inline** SVG allowed for connectors — **no
  external JS, images, or build step**, and **no ASCII box-drawing / `<pre>` art** (Step 8 rule 9).
- **Stand-in semantics** (Step 8 rule 3): the prose C4 spec stays in `plan-source`; the **body shows
  the diagram** in its place — do not also echo the spec text as a `<pre>` beside the diagram. The
  `plan-review` reviewers read the prose spec from `plan-source`; they never see the diagram.
- Give each diagram a stable `id` and link it from the plan's nav/outline.

This domain composes with others: when `backend-api` also matched, the C4 Container diagram and the
contract tables are **complementary** (system shape vs. endpoint contracts) — do not duplicate the
sequence-flow viz as a C4 diagram or vice-versa; each answers a different question.

## Markdown-mode rendering (when format = md)

When mentor-plan **Step 0** resolved **md**, §1 (research) and §2 (the prose C4 spec) are unchanged —
the plan-author still returns the element + relationship lists per level. The main thread realizes each
rendered level **inline in the `.md`** as a Mermaid **`flowchart TB`** (the `.md` is canonical — no
plan-source split):

- **Do NOT use Mermaid `C4Context` / `C4Container`.** Those diagram types are experimental and fail to
  render on GitHub/GitLab — the block shows as an error box or raw text on exactly the surfaces md plans
  are reviewed. Use a plain `flowchart TB`; it carries all the C4 semantics.
- **Boxes** = nodes labelled with name + technology sub-label (e.g.
  `api["API Gateway<br/><i>Node/Express</i>"]`). **Edges** = arrows labelled with the relationship +
  protocol and sync|async (e.g. `api -->|"reads (SQL, sync)"| db[(Postgres)]`).
- **People / external systems** drawn distinctly — wrap in-system containers in a `subgraph "System"`
  boundary, keep people/external nodes outside it, and give them a distinct `classDef` (a stadium
  `([User])` / a dashed external node).
- **Diff highlight** via `classDef` (`classDef new …`, `classDef changed …`, `classDef removed …` —
  e.g. `stroke-dasharray:4` for removed) applied per node by status, **plus a GFM legend table**
  (Status → color/shape) beneath the diagram — Mermaid styling alone is easy to misread, so the legend
  is mandatory. (Do not hand-set a global Mermaid `theme`/`themeVariables` — platforms override it;
  `classDef` per node is fine.)
- **One diagram per rendered level**, each preceded by a heading `C4 L1 — System Context` /
  `C4 L2 — Container` / `C4 L3 — Component: <container>`. Render only the levels that moved; keep each
  small (split if dense — large flowcharts shrink to unreadable text on GitHub).
- **ASCII fallback:** when a flowchart can't cleanly carry the layout, an ASCII box diagram in a code
  fence is an acceptable substitute (the md ASCII carve-out, Step 8M).

Per Step 8M anti-duplication: the diagram (+ legend) IS the artifact — do not also echo the prose
element/relationship lists beside it.
