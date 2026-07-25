---
name: plan
description: >
  The mentor planning workflow. Invoked by /mentor:plan after begin-plan.sh arms
  the edit gate. Guides research, domain routing, resolving open decisions with
  the user one at a time (AskUserQuestion with decision support), writing a
  Mermaid-first Markdown plan into the gate-exempt .mentor/ tree, and the
  approval that releases the gate.
---

# mentor Plan

The flow: resolve the mode & load the constitution → clarify if needed →
research (delegation suggested) → domain routing → resolve open decisions
with the user → write the Markdown plan
(with a Constitution Check when a constitution exists) → (optional
topic × perspective HTML zooms on request) → approve & release →
subagents-first implementation (dispatch-agents).

While the `.planning` marker is armed, `plan-gate.sh` blocks every
Write/Edit/MultiEdit/NotebookEdit inside the repo working tree — the only files
written during planning are the plan and its opt-in zoom artifacts, all inside
the gate-exempt `.mentor/` tree. Do not run repo-mutating shell commands during
planning either; Bash is not enforced, but the rule is the same.

## Step 0 — Mode & constitution {#mode}

`begin-plan.sh` printed a `MODE:` line. The mode is only the **approval-gate
default** — it decides which option Step 6 lists first; both outcomes are
always offered there, and you never ask the user to pick a mode upfront:

- **`MODE: plan-only`** — list **"Deliver plan only"** first at Step 6.
- **`MODE: plan`**, **`MODE: UNSET (default: plan)`**, or no `MODE:` line at
  all (not in a git repo — the gate was not armed) — list **"Proceed"** first.

`begin-plan.sh` may also print a **`CONTEXT:`** line (the context gate). A
**`CONTEXT: WARN`** means the session is getting large — surface it to the user
and use the WARN option set at Step 6 (it leads with **"Hand off to next
agent"**). A **`CONTEXT: HANDOFF`** means the session is critically large and
the user already chose to proceed (gate bypassed): planning continues, but keep
it lean — skip the optional zoom offer and do not offer plan-review (both
inflate the very context that is running out) — and use the Step 6
handoff-leading set with its first option labeled **(Recommended)**. (A
**`CONTEXT: ASK`** never reaches this skill — the command layer resolves it
with the user before invoking the skill; noted here for completeness.)

**Load the constitution.** Resolve the constitution path (a repo may keep its
governing doc outside `.mentor/` — `constitution_path` in `.mentor/config.json`
points at it; see `/mentor:constitution`'s adopt-by-reference branch):

```bash
repo_root="$(git rev-parse --show-toplevel 2>/dev/null)"
const_rel="$(jq -r '.constitution_path // empty' "$repo_root/.mentor/config.json" 2>/dev/null)"
const_path="${repo_root}/${const_rel:-.mentor/constitution.md}"
```

If the resolved file exists, `Read` it now — its principles are governing rules
for this repo. Keep them in mind through research and design, and prove
compliance in the plan's **Constitution Check** section (Step 4). If it is
absent but `docs/constitution.md` or `CONSTITUTION.md` exists at the repo root,
surface that once: the repo appears to have a governing doc mentor is not
reading — suggest `/mentor:constitution` to adopt it by reference. Otherwise no
constitution governs this repo; skip the Constitution Check (you may mention
`/mentor:constitution` once if the user seems to want project-wide rules).

## Step 1 — Clarify (optional) {#clarify}

If the request is ambiguous — unclear scope, multiple plausible interpretations,
missing acceptance criteria — invoke `Skill(skill="mentor:grilling")` before
designing anything. Skip this for well-specified tasks.

## Step 2 — Research (delegation suggested, not enforced) {#research}

For multi-area or unfamiliar tasks, prefer dispatching **1–3 read-only `Explore`
agents** over disjoint areas (issue the `Agent` calls in one message) — it keeps
the main conversation lean. For small, well-scoped tasks, read the files and
draft directly in the main thread. Nothing enforces delegation; use judgment.
(Research dispatches follow `dispatch-agents`' "Async runtime & lifecycle"
rules: deliver-before-idle, one nudge on a silent idle, close out when consumed.)

**Research return contract — put this in every research agent's prompt.** Each
agent returns, and nothing more:

- **FINDINGS** — conclusions only, ≤ ~400 words.
- **EVIDENCE** — `file:line` references only. No file dumps, no pasted source blocks.
- **OPEN QUESTIONS** — anything blocking, as a short list. (These feed
  Step 3.5's triage — they are never silently dropped.)

For a large plan you may additionally dispatch one `Plan` agent to author the
plan body — but only AFTER Step 3.5 has resolved the open decisions: hand it
the distilled research, the resolved decisions, and the content spec below
(Step 4); its return is the plan body you persist. For most plans, author it
yourself.

If a domain matched (Step 3), fold that domain skill's research directives into
the research prompts.

## Step 3 — Domain routing {#domains}

Scan the task (and refine after research returns) against the registry. For each
matched domain, invoke its planning skill **exactly once** via `Skill(skill="…")`.
Multiple domains may match; if none match, invoke the dynamic fallback.

| Domain | Trigger signals | Skill to invoke | Extra plan deliverable |
|---|---|---|---|
| frontend | UX/UI — components, pages, styles, layout, design systems, theming, responsive | `Skill(skill="mentor:plan-domain-frontend")` | ASCII wireframes + delta/token tables; live mockups only in an HTML zoom combo (Step 5) |
| backend-api | API/endpoint/route/handler/schema/DTO/contract | `Skill(skill="mentor:plan-domain-backend-api")` | Before/after contract diff tables + schema diffs + Mermaid sequence flow |
| architecture (C4) | Structural change — new/changed/removed service, container, datastore, queue, external integration, component, or data flow (NOT pure content/config/doc/style/refactor) | `Skill(skill="mentor:plan-domain-architecture")` | Diff-highlighted C4-style Mermaid flowcharts, only the levels that change |
| dynamic (fallback) | no registered domain matched | `Skill(skill="mentor:plan-domain-dynamic")` | Domain best-practices section (practice→step mapping) |

Each matched domain skill returns directives you fold into the research prompts
and the plan body.

## Step 3.5 — Resolve open questions & decisions (one at a time) {#decisions}

Before writing the plan, drain every open question so the plan encodes
decisions, not question marks. Collect them from all sources: the research
agents' **OPEN QUESTIONS** returns (Step 2), directives from matched domain
skills (Step 3), and any design fork you noticed yourself (approach A vs B,
scope boundary, acceptance criteria, naming).

Triage each item into exactly one bucket:

- **Codebase-answerable** — the code, config, git history, or docs can settle
  it. Answer it yourself (dispatch a read-only `Explore` agent, or read
  directly for a quick check); never ask the user what the repo can answer.
  (Explore dispatches follow `dispatch-agents`' "Async runtime & lifecycle"
  rules, same as Step 2's research agents.)
- **User decision** — preference, product direction, scope, priorities, a
  trade-off with no objectively right answer. Queue it for the user.
- **Immaterial** — the plan comes out the same whichever way it lands. Drop
  it, or record it as a flagged assumption in the plan.

Resolve the queued user decisions via `AskUserQuestion` — **one call, one
question, one decision at a time**. Batching decisions into one call produces
rushed, lower-quality answers. Order by dependency: resolve the decision other
decisions hang off first, and let each answer narrow the next question.

**Every question ships with decision support** — the user must be able to
decide from your message alone, without re-reading the codebase:

- In the message text **before** the tool call, give a compact decision brief:
  what the decision is, why it matters to this plan, and the relevant evidence
  from research (`file:line` references, observed behavior, constraints).
- `AskUserQuestion` needs 2–4 options per question. For open-ended decisions
  (naming, free-form scope), synthesize 2–4 concrete candidates from the
  research — the tool adds a free-text "Other" automatically, so a candidate
  list never traps the user. Only when you truly cannot form two sensible
  candidates, ask in plain prose instead.
- Put your **recommended option first** with "(Recommended)" appended to its
  label (a convention for decision questions like these — fixed workflow gates
  such as Step 6's approval order by position alone), and make each option's
  `description` carry its concrete consequence or trade-off — not a
  restatement of the label.
- When options are competing shapes (schemas, layouts, flows, wording), use
  the `preview` field so the user compares them side by side.

Each answer becomes a plan input. An "Other" answer may open new questions —
triage those through the same buckets. If the user explicitly defers a
decision, record the deferral in the plan (as a flagged assumption or under
Out of scope) rather than silently choosing for them.

**Skip condition:** no open questions survived triage → proceed straight to
Step 4. Never manufacture questions to fill the step — a well-specified task
with clean research needs zero.

This step resolves *post-research* decisions with evidence in hand; Step 1's
grilling handles *pre-research* ambiguity in the request itself. An earlier
grill session does not skip this step — research may have surfaced new forks —
but a decision already resolved anywhere in the conversation is never
re-asked.

## Step 4 — Write the Markdown plan {#write-the-plan}

Compute the path (substituting a kebab-case `<slug>` derived from the request —
≤30 chars, drop articles, keep nouns/verbs):

```bash
slug="<slug>"
git_common="$(git rev-parse --git-common-dir 2>/dev/null)"
repo_root="$(cd "$(dirname "$git_common")" && pwd)"
plan_dir="$repo_root/.mentor/plans/$slug"
mkdir -p -m 700 "$plan_dir"   # 700: plans may contain sensitive paths/snippets
echo "${plan_dir}/plan.md"   # fixed name inside the slug dir, NO timestamp — stable across revisions
```

Write the plan there with the `Write` tool, then register it so mentor can track what
becomes of it:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" init "$slug"
```

That records the plan as `draft` in a hidden `.state.json` beside it. Approval, and
later `/mentor:track`, read that state to know which plans are built and which are
pending. It is idempotent, so re-running it on a revision is harmless.

The path is inside the gate-exempt
`.mentor/` tree, so the edit gate allows it; `plan-open.sh` auto-opens it for review the first time
(VSCode tab when available — toggle preview with ⇧⌘V; opener configurable via
`MENTOR_PLAN_OPENER`, disable with `MENTOR_PLAN_OPEN=off`, both under `env` in
`~/.claude/settings.json`). **Keep it current:** on every revision re-write this
SAME file in place — never create a second timestamped copy. Never write the
plan anywhere else in the repo or to the harness-native `~/.claude/plans/` dir.

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
5. `## Constitution Check` — **include only when the constitution resolved in
   Step 0 exists** (default `.mentor/constitution.md`, or the file
   `constitution_path` points at). A GFM table with one row per principle: `Principle | Verdict | Notes`,
   verdict = ✅ complies / ⚠️ deviates / ➖ N/A. For every ⚠️, the Notes cell must
   either point at the plan change that resolves it or record an explicit,
   justified deviation. If a principle can only be honored by amending the
   constitution, say so and stop short of encoding the violation as the plan.
6. `## Implementation steps` — numbered, concrete, and **dispatch-annotated by
   default** (subagents-driven development: the main thread orchestrates,
   subagents implement — each agent gets one narrow, focused step, and the
   main context stays lean). Before writing this section, invoke
   `Skill(skill="mentor:dispatch-agents")` and annotate every implementation
   step per its grammar (`[role: … · model: … · effort: …]`, grouped
   `Run in parallel:` / `Sequential:`) — one plan step = one dispatch.
   **Escape hatch:** when the implementation meets the dispatch-agents skill's
   skip rule, omit the annotations, but the section MUST then open with one
   line: `Dispatch: skipped — <reason>`. No line, no skip.
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

**Sticky re-entry rule.** EVERY zoom ask re-enters this step's contract — the
first one, the Nth one, a free-text follow-up ("update the review artifact",
"add a zoom for X"), a mid-revision regeneration, at any point in the plan
lifecycle. Run the Selection gate (skipping questions the ask already answers)
and generate via dispatched agents. **Never hand-edit or hand-write a zoom file
in the main thread** — least of all late in a session, when context is already
large.

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
`${plan_dir}/zoom/<topic>-<perspective>.html`, the spec below, and the
delivery prohibition: *"Do NOT call the `Artifact` tool and do NOT return any
hosted URL. Return ONLY the file path + a `Self-check:` line — sections
rendered, diagram count, tags balanced, spec constraints met — never the HTML
body."* Perspective-conditional inputs: **Reviewer/Architect** combos also get
the resolved constitution path (Step 0) when that file exists; a **UI-surface topic** gets
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
on first Write and must never show a half-built page). The path is inside the
gate-exempt `.mentor/` tree, so the edit gate allows the Write; plan-open.sh
auto-opens each file once. Stable names — a re-zoom of the same combo
overwrites in place. Zooms whose content is primarily visual (mockups,
diagrams) SHOULD ship lightweight pan/zoom affordances on the outer page
(fullscreen toggle ⛶, overlay scrim, +/−/reset, wheel-zoom — inline JS in the
outer file only; iframe `srcdoc` panes stay no-JS per `plan-domain-frontend`
§4). Zoom
artifacts are throwaway visual aids; **the `.md` stays the source of truth** —
no sync contract, no finalize step.

**Completion check.** After the agents return, `ls "$plan_dir"/zoom` against the
expected combo files and read each agent's `Self-check:` line (do not re-derive
ad-hoc grep probes); report any missing combo file and re-dispatch it once
before giving up. Zoom dispatches follow `dispatch-agents`' "Async runtime &
lifecycle" rules — close out finished combo agents after this check.

**Revision completeness.** When a plan revision or a product decision
invalidates prior zooms, `grep -l` the invalidated term across every existing
`${plan_dir}/zoom/*.html` and re-dispatch EVERY matching combo in one batched
message — not just the combo you remember changing. Wait for those agents to
complete before dispatching `plan-review`, so a reviewer never reads a zoom
mid-write.

## Step 6 — Approve & release {#approve}

> **🚫 No edits or implementation until the plan is APPROVED.** During planning,
> only read-only agents (Explore, Plan, plan-review reviewers) may be
> dispatched — the sole exception is Step 5's zoom combo agents, which write
> ONLY zoom artifacts into the plan's `zoom/` dir (gate-exempt `.mentor/`
> tree), never repo source files.
> Every editing/implementation agent comes AFTER approval.

First **surface the complete plan body** in your message — plain markdown,
verbatim, no commentary around it — so the user can review it in the transcript.
If the plan is long, let them scroll; do not summarize instead. Then, in the
same turn, ask via `AskUserQuestion` — `header: "Approve"`, question *"The plan is
ready. What happens next?"* — with the option set the table below selects.

### Is the plan oversized?

Decide this **before** asking, because it changes which options you offer. The plan is
oversized when any of these holds:

- more than ~12 implementation steps, or
- it contains independent deliverables that could ship separately, or
- the user says it is too big.

**Suppressed when this plan already has a `group`** — it is itself a split child, and
re-slicing a slice usually means the first split drew its lines in the wrong place.
Typing `/plan-split` still works if the user insists.

### The option set

`AskUserQuestion` caps at 4, and the oversize and context conditions fire together
constantly — so the precedence is fixed here rather than left to judgment in the
moment:

| Condition | Options, in order | Yields to "Other" |
|---|---|---|
| neither | Proceed · Deliver plan only · Review the plan (staged) · Keep planning | — |
| `CONTEXT: WARN` only | Hand off to next agent · Deliver plan only · Proceed · Keep planning | Review |
| `CONTEXT: HANDOFF` only | **Hand off to next agent (Recommended)** · Deliver plan only · Proceed · Keep planning | Review |
| oversized only | **Split into multiple plans** · Proceed · Review the plan (staged) · Deliver plan only | Keep planning |
| oversized **and** `CONTEXT: WARN` | **Split into multiple plans** · Hand off to next agent · Deliver plan only · Proceed | Review, Keep planning |
| oversized **and** `CONTEXT: HANDOFF` | **Hand off to next agent (Recommended)** · Split into multiple plans · Deliver plan only · Proceed | Review, Keep planning |

In the first row only, `MODE: plan-only` swaps the leading two so "Deliver plan only"
comes first. Anything yielded to "Other" stays reachable — the user can just say it.
Under `CONTEXT: HANDOFF`, also note in the question text that the session is
critically large.

Split leads on an oversized plan because handing one off whole only moves the problem
to the next session, while the split's authoring cost lands in dispatched agents
rather than in this thread. **`CONTEXT: HANDOFF` outranks even that**: at that size the
safest possible act is to write the handoff and stop, and the split can happen in the
fresh session with room to verify it. Review stays visible in the oversized-only row
because an oversized plan is exactly the kind most worth reviewing; *Keep planning*
yields instead.

| Label | Description |
|---|---|
| Proceed | Validate the plan, release the edit gate, and begin implementation. |
| Deliver plan only | Validate the plan and release the gate; the plan file is the deliverable — no implementation, no dispatch. (/mentor:handoff can brief a fresh agent afterwards.) |
| Review the plan (staged) | Run plan-review — a judgment pass (practicality, comprehensiveness) with a fold gate for the edits you pick, then a mechanical pass (cleanliness, consistency) whose safe fixes auto-fold. Stays in planning; ends back at this question. |
| Keep planning | Do not release — keep refining. Re-write the plan file and ask again when ready. |
| Split into multiple plans | Slice this plan into independently buildable sibling plans, each with explicit scope isolation. Stays in planning; asks again afterwards. |
| Hand off to next agent | Approve and release, then write a handoff doc so a fresh agent implements it — this session is getting large. |

On **Proceed**, run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/approve-plan.sh"
```

It validates the plan (a non-empty `.md` newer than the `.planning` marker), and
on success deletes the marker — the gate OPENS. On failure it prints the problem,
keeps the gate closed, and exits non-zero: fix the plan (re-write per Step 4) and
re-ask. On success, implement the plan.

**Executing the implementation after approval (SDD):** implementation is
subagents-first. Invoke `Skill(skill="mentor:dispatch-agents")` first (skip the
re-invocation only if it is already loaded in this session), then follow its
"Executing the dispatches" section: read the approved plan file, dispatch each
`Run in parallel:` group's agents in ONE message (multiple `Agent` calls), run
`Sequential:` steps one at a time, and verify each step's `Done when:` before
starting the next. Mark each step done in the plan file as it passes. Do not
busy-poll background agents — end the turn and let the harness re-invoke you.
The main thread orchestrates and verifies; it does not re-do or re-read the
work it delegated. Only when the plan opens its Implementation steps with
`Dispatch: skipped — <reason>` does the main thread implement directly.

**Record progress as plan state.** `approve-plan.sh` just marked this session's plans
`approved`. As implementation runs, move that forward so a later session — or
`/mentor:track` — knows what actually landed instead of re-reading the plan and
guessing:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" set <slug> in_progress            # execution starts
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" set <slug> implemented            # every Done when: passed
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" set <slug> failed --note "<what broke>"   # escalating to the user
```

`mentor:dispatch-agents` states this for the dispatch path; it is repeated here
because the **`Dispatch: skipped`** path never loads that skill, and direct
implementation must not be the one route that leaves no record. Missing a transition
is survivable — state also derives from the `✅` step ticks you mark as each step
passes — but `failed` cannot be derived from ticks, so that one is worth remembering.

On **Deliver plan only**, run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/approve-plan.sh" --deliver
```

Same validation + release, then **follow the DELIVER-ONLY directive it prints** —
report where the plan lives and STOP. Do not implement and do not dispatch in
this session.

On **Hand off to next agent** (or an "Other" answer expressing handoff intent),
run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/approve-plan.sh" --handoff
```

Same validation + release, then **follow the hand-off directive it prints** —
invoke the handoff skill for this approved plan and stop. Do not implement and
do not dispatch in this session.

On **Review the plan (staged)**, invoke `Skill(skill="mentor:plan-review")` and
prepend: *"The user selected 'Review the plan (staged)' — skip the Step 2 gate
and start Stage 1 directly."* Its reviewers are read-only and the gate stays
closed; the skill itself folds the Stage 1 edits the user picks at its fold
gate and auto-folds MECHANICAL Stage 2 findings into the plan file
(gate-exempt `.mentor/` writes), surfaces DECISION-REQUIRED findings, then
returns to this same question — this option never releases the gate by
itself.

On **Split into multiple plans**, invoke `Skill(skill="mentor:plan-split")`. It writes
only under `.mentor/plans/`, so the gate stays closed: it confirms a slice map,
dispatches one agent per child, retires the parent, and returns here. Then **re-ask
this same question** against the new sibling set — the oversize condition is now
false, so the option set comes from the table's first two rows. Say in the question
that **Proceed now approves the whole set** and routes building to `/mentor:track`;
otherwise the user is left guessing which child "Proceed" means, and the model is left
implementing whichever one it happens to remember.

On **Keep planning**, do not run the script; return to planning.

**Not in a git repo?** begin-plan reported the gate was NOT armed — skip
`approve-plan.sh` (it would fail outside a repo) and honor the user's choice
directly.
