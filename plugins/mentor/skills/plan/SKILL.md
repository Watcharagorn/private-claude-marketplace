---
name: plan
description: >
  The mentor planning workflow. Invoked by /mentor:plan after begin-plan.sh arms
  the edit gate. Guides research, domain routing, writing a Mermaid-first
  Markdown plan outside the repo, and the approval that releases the gate.
---

# mentor Plan

The flow: resolve the mode & load the constitution → clarify if needed →
research (delegation suggested) → domain routing → write the Markdown plan
(with a Constitution Check when a constitution exists) → (optional
topic × perspective HTML zooms on request) → approve & release.

While the `.planning` marker is armed, `plan-gate.sh` blocks every
Write/Edit/MultiEdit/NotebookEdit inside the repo working tree — the only files
written during planning are the plan and its opt-in zoom artifacts, all outside
the repo. Do not run repo-mutating shell commands during planning either; Bash
is not enforced, but the rule is the same.

## Step 0 — Mode & constitution {#mode}

`begin-plan.sh` printed a `MODE:` line:

- **`MODE: plan`** — default: plan, then execute on approval.
- **`MODE: plan-only`** — the plan file is the deliverable; after approval you
  do NOT implement and do NOT dispatch implementation agents.
- **`MODE: UNSET`** — ask the user **once** via `AskUserQuestion` (plan /
  plan-only), persist with
  `bash "${CLAUDE_PLUGIN_ROOT}/hooks/set-mode.sh" <choice>`, then continue.

**Load the constitution.** Check for `.mentor/constitution.md` at the repo root
(`git rev-parse --show-toplevel`). If it exists, `Read` it now — its principles
are governing rules for this repo. Keep them in mind through research and design,
and prove compliance in the plan's **Constitution Check** section (Step 4). If it
is absent, no constitution governs this repo; skip the Constitution Check (you may
mention `/mentor:constitution` once if the user seems to want project-wide rules).

## Step 1 — Clarify (optional) {#clarify}

If the request is ambiguous — unclear scope, multiple plausible interpretations,
missing acceptance criteria — invoke `Skill(skill="mentor:grilling")` before
designing anything. Skip this for well-specified tasks.

## Step 2 — Research (delegation suggested, not enforced) {#research}

For multi-area or unfamiliar tasks, prefer dispatching **1–3 read-only `Explore`
agents** over disjoint areas (issue the `Agent` calls in one message) — it keeps
the main conversation lean. For small, well-scoped tasks, read the files and
draft directly in the main thread. Nothing enforces delegation; use judgment.

**Research return contract — put this in every research agent's prompt.** Each
agent returns, and nothing more:

- **FINDINGS** — conclusions only, ≤ ~400 words.
- **EVIDENCE** — `file:line` references only. No file dumps, no pasted source blocks.
- **OPEN QUESTIONS** — anything blocking, as a short list.

For a large plan you may additionally dispatch one `Plan` agent to author the
plan body: hand it the distilled research and the content spec below (Step 4);
its return is the plan body you persist. For most plans, author it yourself.

If a domain matched (Step 3), fold that domain skill's research directives into
the research prompts.

## Step 3 — Domain routing {#domains}

Scan the task (and refine after research returns) against the registry. For each
matched domain, invoke its planning skill **exactly once** via `Skill(skill="…")`.
Multiple domains may match; if none match, invoke the dynamic fallback.

| Domain | Trigger signals | Skill to invoke | Extra plan deliverable |
|---|---|---|---|
| frontend | UX/UI — components, pages, styles, layout, design systems, theming, responsive | `Skill(skill="plan-domain-frontend")` | ASCII wireframes + delta/token tables; live mockups only in an HTML zoom combo (Step 5) |
| backend-api | API/endpoint/route/handler/schema/DTO/contract | `Skill(skill="plan-domain-backend-api")` | Before/after contract diff tables + schema diffs + Mermaid sequence flow |
| architecture (C4) | Structural change — new/changed/removed service, container, datastore, queue, external integration, component, or data flow (NOT pure content/config/doc/style/refactor) | `Skill(skill="plan-domain-architecture")` | Diff-highlighted C4-style Mermaid flowcharts, only the levels that change |
| dynamic (fallback) | no registered domain matched | `Skill(skill="plan-domain-dynamic")` | Domain best-practices section (practice→step mapping) |

Each matched domain skill returns directives you fold into the research prompts
and the plan body.

## Step 4 — Write the Markdown plan {#write-the-plan}

Compute the path (substituting a kebab-case `<slug>` derived from the request —
≤30 chars, drop articles, keep nouns/verbs):

```bash
slug="<slug>"
git_common="$(git rev-parse --git-common-dir 2>/dev/null)"
repo_root="$(cd "$(dirname "$git_common")" && pwd)"
repo_base="$(basename "$repo_root")"
repo_hash="$(printf '%s' "$repo_root" | shasum | cut -c1-8)"
plans_dir="$HOME/.claude/mentor/${repo_base}-${repo_hash}/plans"
mkdir -p -m 700 "$plans_dir"   # 700: plans may contain sensitive paths/snippets
echo "${plans_dir}/${slug}.md"   # slug-derived, NO timestamp — stable across revisions
```

Write the plan there with the `Write` tool. The path is outside the repo, so the
edit gate allows it; `plan-open.sh` auto-opens it for review the first time
(VSCode tab when available — toggle preview with ⇧⌘V; opener configurable via
`MENTOR_PLAN_OPENER`, disable with `MENTOR_PLAN_OPEN=off`, both under `env` in
`~/.claude/settings.json`). **Keep it current:** on every revision re-write this
SAME file in place — never create a second timestamped copy. Never write the
plan inside the repo or to the harness-native `~/.claude/plans/` dir.

### Content spec

The `.md` file is the canonical plan — self-contained, portable, renders richly
on GitHub/GitLab and any Mermaid-capable viewer. No inline HTML/CSS/SVG.

Required sections, in order:

1. `# <Plan title>`
2. `## Context` — the problem, what prompted it, intended outcome.
3. `## Use case scenarios` — actors & triggers; current vs expected behavior;
   numbered concrete scenario walkthroughs (real values from research, not
   placeholders); edge cases & assumptions (flag anything unverified). Give this
   section visualization treatment — a Mermaid flowchart/sequenceDiagram of
   actor→trigger→outcome, or a current-vs-expected GFM table — so the reviewer
   can verify your understanding at a glance.
4. `## Approach` — the recommended design, with one visualization per
   significant change/decision realized inline under its owning topic.
5. `## Constitution Check` — **include only when `.mentor/constitution.md` exists**
   (Step 0). A GFM table with one row per principle: `Principle | Verdict | Notes`,
   verdict = ✅ complies / ⚠️ deviates / ➖ N/A. For every ⚠️, the Notes cell must
   either point at the plan change that resolves it or record an explicit,
   justified deviation. If a principle can only be honored by amending the
   constitution, say so and stop short of encoding the violation as the plan.
6. `## Implementation steps` — numbered, concrete. If the work will fan out to
   subagents after approval, annotate steps per `Skill(skill="dispatch-agents")`
   (`[role: … · model: … · effort: …]`, grouped `Run in parallel:` /
   `Sequential:`) — optional, self-serve.
7. `## Critical files`
8. `## Out of scope`
9. `## Verification` — how to test end-to-end.

**Visualization decision rule (pick exactly ONE idiom per artifact):**

- Tabular data (field lists, diffs, matrices, before/after values) → **GFM table**.
- Topology / sequence / state (flows, state machines, ER, dependencies) →
  **Mermaid** fenced block.
- Spatial/layout fidelity (UI zone wireframes, fixed-width alignment) →
  **ASCII diagram in a code fence**.
- Callouts / cautions → **GFM alert** (`> [!NOTE]`, `> [!WARNING]`, …).
- Literal code / payloads → fenced code with a language tag.

**Anti-duplication:** never restate in prose what a diagram already shows, and
never show the same thing two ways. Prose next to a diagram is limited to a
one-line caption, a legend, and the why/insight the diagram cannot encode.

**Mermaid portability rules:** do NOT set `theme`/`themeVariables`/`%%{init}%%`
(GitHub/GitLab apply their own); do NOT use `C4Context`/`C4Container` (use
`flowchart TB` + `subgraph` + `classDef` instead); keep each diagram small —
split dense flows into 2–3 focused diagrams; a `;` inside `Note over …: text`
truncates the note — use `,` or `+`.

**Generalist-reviewer principle:** write for a generalist, not a domain expert —
define jargon at first use, state why each step matters, prefer concrete
examples. The plan must be approvable by someone outside the domain.

## Step 5 — Optional HTML zoom (explicit user opt-in only) {#html-zoom}

Only when the **user asks** for an HTML zoom / visual preview — never by
default — and **never as one file for the whole plan**. Every zoom artifact is
scoped to one **topic × perspective** pair. A whole-plan ask ("preview the plan
as HTML") does not bypass the gate below — it is exactly the case the gate
exists for.

### Selection gate

Resolve two dimensions before generating anything:

1. Derive up to 4 candidate **topics** from the plan itself — its `## Approach`
   subsections, `Proposed UI changes per surface` entries, or
   implementation-step groupings.
2. Ask ONE `AskUserQuestion` call with two multi-select questions — **Topics**
   (the derived candidates) and **Perspective** (catalog below). Skip a
   question only when the user's request already explicitly named that
   dimension ("zoom into checkout as the end user" skips both). When only one
   topic is derivable, treat topic as resolved and ask only Perspective
   (AskUserQuestion needs 2–4 options per question).

| Perspective | The zoom emphasizes |
|---|---|
| End user | Journey/scenario walkthroughs, visible states, UI mockups (frontend topics); hides implementation detail |
| Implementor | File-level touchpoints, sequence diagrams, data structures, step order/dependencies |
| Reviewer / Architect | Architecture slice, trade-offs, risks, constitution compliance for that topic |
| QA / Tester | Test scenarios, edge cases, verification steps for that topic |

Combos = selected topics × selected perspectives. If combos > 6, confirm the
count before dispatching (mention `MENTOR_PLAN_OPEN=off` as the escape hatch —
every finished file auto-opens). Kebab-sanitize topic and perspective names and
uniquify colliding topic slugs (append `-2`, `-3`, …) so no two combos share a
path.

### Generation — one agent per combo, always dispatched

Issue one `Agent` call per combo (`subagent_type: general-purpose`,
`model: sonnet`, `effort: high`), ALL combos in one message — even a single
combo is dispatched, keeping one contract and keeping HTML out of the main
context. Each agent's prompt carries: the plan path (the agent `Read`s it), its
topic, its perspective row from the catalog above, the output path
`${plans_dir}/<slug>-<topic>-<perspective>.html`, the spec below, and the
delivery prohibition: *"Do NOT call the `Artifact` tool and do NOT return any
hosted URL. Return ONLY the file path + a one-line summary — never the HTML
body."* Perspective-conditional inputs: **Reviewer/Architect** combos also get
the `.mentor/constitution.md` path when it exists; a **UI-surface topic** gets
the mockup contract inputs from `plan-domain-frontend` §4 whenever the
perspective needs to *see* the surface to do its job — End user,
Reviewer/Architect, and QA/Tester (the tester must see the states they verify) —
but **not** Implementor, whose zoom is about file wiring and step order, where a
pixel-faithful mockup is redundant.

Per-file spec: a single self-contained file — inline CSS, no build step;
Mermaid via CDN
(`https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js` +
`<pre class="mermaid">`) is allowed; content for the **assigned topic through
the assigned perspective only**, never the whole plan; readable — body text
≥15px-equivalent, WCAG-AA contrast, monospace for code; authored in a
**single `Write` call** (no skeleton-then-`Edit` — plan-open.sh opens the file
on first Write and must never show a half-built page). The path is outside the
repo, so the edit gate allows the Write; plan-open.sh auto-opens each file
once. Stable names — a re-zoom of the same combo overwrites in place. Zoom
artifacts are throwaway visual aids; **the `.md` stays the source of truth** —
no sync contract, no finalize step.

**Completion check.** After the agents return, `ls` the expected paths; report
any missing combo file and re-dispatch it once before giving up.

## Step 6 — Approve & release {#approve}

> **🚫 No edits or implementation until the plan is APPROVED.** During planning,
> only read-only agents (Explore, Plan, plan-review reviewers) may be
> dispatched — the sole exception is Step 5's zoom combo agents, which write
> ONLY zoom artifacts beside the plan (outside the repo), never repo files.
> Every editing/implementation agent comes AFTER approval.

First **surface the complete plan body** in your message — plain markdown,
verbatim, no commentary around it — so the user can review it in the transcript.
If the plan is long, let them scroll; do not summarize instead. Then, in the
same turn, ask via `AskUserQuestion`:

```json
{
  "question": "The plan is ready. Proceed to implementation?",
  "header": "Proceed",
  "options": [
    { "label": "Proceed", "description": "Validate the plan, release the edit gate, and begin implementation." },
    { "label": "Hand off to next agent", "description": "Approve and release the gate, but don't implement here — write a /mentor:handoff document so a fresh agent picks up implementation, then stop." },
    { "label": "Review the plan (light)", "description": "Run plan-review — fan out 4 read-only reviewers over this plan (incl. a spec-kit-analyze-style consistency check). Stays in planning; surfaces findings, then asks again." },
    { "label": "Keep planning", "description": "Do not release — keep refining. Re-write the plan file and ask again when ready." }
  ]
}
```

**plan-only mode:** replace "Proceed" with `{ "label": "Deliver plan",
"description": "Validate the plan and release the gate. The plan file is the
deliverable — no implementation, no dispatch." }` and drop "Hand off".

On **Proceed** (or **Deliver plan**), run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/approve-plan.sh"
```

It validates the plan (a non-empty `.md` newer than the `.planning` marker), and
on success deletes the marker — the gate OPENS. On failure it prints the problem,
keeps the gate closed, and exits non-zero: fix the plan (re-write per Step 4) and
re-ask. In plan-only mode it prints a soft-stop directive — report the plan path
and STOP. Otherwise, implement the plan.

**Executing dispatch annotations after approval:** if the plan carries
`[role: …]` annotations, dispatch each `Run in parallel:` group's agents in ONE
message (multiple `Agent` calls), run `Sequential:` steps one at a time, and
verify each step's `Done when:` before starting the next. Do not busy-poll
background agents — end the turn and let the harness re-invoke you.

On **Hand off to next agent**, run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/approve-plan.sh" --handoff
```

Same validation + release, then **follow the hand-off directive it prints** —
invoke the handoff skill for this approved plan and stop. Do not implement and
do not dispatch in this session.

On **Review the plan (light)**, invoke `Skill(skill="mentor:plan-review")` and
prepend: *"The user selected 'Review the plan (light)' — skip the Run/Pass gate
and dispatch the reviewers directly."* Its reviewers are read-only, so the gate
stays closed. Surface their findings; if the user wants any folded in, revise
and re-write the plan file; then re-ask this same question — this option never
releases the gate by itself.

On **Keep planning**, do not run the script; return to planning.
