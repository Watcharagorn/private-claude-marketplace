---
name: plan-domain-architecture
description: >
  Domain planning skill for ARCHITECTURE / system-structure work, invoked ONCE
  by `plan` (Step 3 domain routing) when a plan changes structure — a
  new/changed/removed service, container, datastore, queue, external integration,
  component, or data flow. Not a /command. Shapes the research (map the current
  architecture, its containers, external systems, and the edges between them)
  and the Markdown plan to carry a before/after C4-model view — diff-highlighted
  Mermaid Context / Container (/ Component) diagrams, rendering only the C4
  levels the change actually moves. No extra agent; a polished HTML/CSS C4
  diagram is reserved for the opt-in HTML zoom (`plan` Step 5).
---

# Architecture (C4) Planning Domain

Invoked **once per plan** by `plan`'s domain routing (Step 3) when the task **changes system
structure**. Like the backend-api domain (and unlike frontend), it adds directives to the research
and plan-writing the flow already performs — **no extra agent dispatch**.

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
- New elements/relationships are **visually distinct** from changed, removed, and unchanged ones —
  with a legend.
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

## 1 — Shape the research (`plan` Step 2)

When research is delegated (as `plan` Step 2 suggests), append these directives to the
architecture-relevant research agents' prompts; when researching directly, cover the same points:

- Map the **current architecture** from real source — the deployable/runnable **units** (from
  manifests, compose / IaC / k8s, service entrypoints), the **datastores / queues / caches**, and the
  **external systems** the codebase calls (client SDKs, HTTP callers, queue producers/consumers).
- Capture the **edges**: who calls / writes to whom, with the **protocol** (HTTP/gRPC/SQL/queue) and
  **sync vs async**, from `file:line` EVIDENCE.
- For **L1**: identify the **system boundary** (what is "us" vs external), the **actors/personas**, and
  the **external systems**.
- Classify each in-scope element and edge **NEW / CHANGED / REMOVED / UNCHANGED** so FINDINGS can drive
  the status + diff styling.

The research return contract is unchanged (FINDINGS ≤ ~400 words / EVIDENCE `file:line` / OPEN
QUESTIONS), with one addition: FINDINGS include a compact **current-architecture snapshot** for the
levels in scope — the elements (id · name · type/technology) and the relationships (from → to · label ·
sync|async).

## 2 — Shape the plan body (`plan` Step 4)

Build a **plain-prose C4 spec** (a *spec*, never ASCII art) as the working input for the diagrams.
For **each level you render**, provide:

- an **element list** — one line each: `id · name · type/technology · responsibility · status`
  (status ∈ NEW|CHANGED|REMOVED|UNCHANGED);
- a **relationship list** — one line each: `from → to · label/protocol · sync|async · status`.

Make it **diff-aware** (before → after), the same spirit as backend-api's contract diff. State which
levels you are rendering and **why** (which delta justified each). Mark people and external systems so
the diagram can style them distinctly. **Define every architecture term at first use** (generalist-
reviewer principle) — name each container's role, and decode every protocol/abbreviation.

The spec is realized in the `.md` as Mermaid diagrams per §3 — the diagram (+ legend) is what ships;
the spec is scaffolding, not a section to echo verbatim.

## 3 — Plan rendering (`plan` Step 4)

Realize each rendered level **inline in the `.md`** as a Mermaid **`flowchart TB`**:

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
  fence is an acceptable substitute (`plan` Step 4's ASCII carve-out).

Per `plan` Step 4's anti-duplication rule: the diagram (+ legend) IS the artifact — do not also
echo the prose element/relationship lists beside it.

This domain composes with others: when `backend-api` also matched, the C4 Container diagram and the
contract tables are **complementary** (system shape vs. endpoint contracts) — do not duplicate the
sequence-flow viz as a C4 diagram or vice-versa; each answers a different question.

## HTML zoom (opt-in)

When the user explicitly requests a visual zoom of this domain's area (`plan` Step 5), the zoom
html file may carry a **polished HTML/CSS C4 diagram** for the requested level(s) only: boxes with
name + technology sub-label + one-line responsibility, connectors carrying the relationship label
(protocol / sync·async), people and external systems styled distinctly (person glyph / muted
"external" treatment), diff-highlighted with a legend (NEW added-green, CHANGED amber, REMOVED
struck/red, UNCHANGED plain), and a `C4 L1/L2/L3` header per diagram. Pure HTML/CSS with inline SVG
for connectors — self-contained per `plan` Step 5. The `.md` plan stays the source of truth.
