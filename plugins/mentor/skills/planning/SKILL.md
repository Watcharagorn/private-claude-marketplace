---
name: planning
description: >
  Not a standalone entry point, and NOT for a conversational planning request — when the
  user asks to plan something, run the /mentor:plan COMMAND; never select this skill to
  answer that ask. This is the body of that command: it runs begin-plan.sh first to arm
  the marker-driven edit gate that holds planning read-only; loaded any other way this
  skill detects the unarmed gate at Step 0 and stops, pointing you at the command.
  Guides research, domain routing, resolving open decisions with the user one at a
  time (AskUserQuestion with decision support), writing a Mermaid-first Markdown
  plan into the gate-exempt .mentor/ tree, and the approval that releases the gate.
---

# mentor Plan

The flow: resolve the mode & load the constitution → clarify if needed →
research (delegation suggested) → domain routing → resolve open decisions
with the user → write the Markdown plan
(with a Constitution Check when a constitution exists) → (optional
topic × perspective HTML zooms via `mentor:zooming`, or a plan tour via
`mentor:plan-touring`, on request) → approve & release →
subagents-first implementation (dispatch-agents).

While the `.planning` marker is armed, `plan-gate.sh` blocks every
Write/Edit/MultiEdit/NotebookEdit inside the repo working tree — the only files
written during planning are the plan and its opt-in zoom artifacts, all inside
the gate-exempt `.mentor/` tree. Do not run repo-mutating shell commands during
planning either; Bash is not enforced, but the rule is the same.

## Step 0 — Mode & constitution {#mode}

**First, confirm the edit gate is actually armed.** This skill is the body of the
`/mentor:plan` command, which runs `begin-plan.sh` before invoking it. If you were
loaded some other way — most likely a conversational "help me plan this" — that
never ran:

```bash
git_common="$(git rev-parse --git-common-dir 2>/dev/null)"
if [ -n "$git_common" ]; then
  case "$git_common" in /*) ;; *) git_common="$PWD/$git_common" ;; esac
  repo_root="$(cd "$(dirname "$git_common")" && pwd)"
  [ -f "$repo_root/.mentor/plans/.planning" ] || echo "GATE: NOT ARMED"
fi
```

(`--git-common-dir`, not `--show-toplevel`: linked worktrees deliberately share the
main repo's `.mentor/` state dir, so a worktree resolved to its own root would look
for the marker in the wrong place and refuse to plan while the gate was armed.)

`GATE: NOT ARMED` inside a repo means `plan-gate.sh` has no marker to enforce, so
every repo edit stays allowed for the whole session while Step 6 goes on showing its
"no edits until approved" banner. Planning that only *looks* read-only is worse than
planning that admits it isn't, so do not continue: say so in one line and ask the
user to run `/mentor:plan <their request>`, which arms the gate and comes back here.

Do **not** run `begin-plan.sh` yourself to patch this up — on a large session it
answers `CONTEXT: ASK` and exits *without* arming, and resolving that with the user
is the command's job, not this skill's.

No output means the gate is armed, or you are outside a repo where there is nothing
to protect. Either way, continue.

`begin-plan.sh` printed a `MODE:` line. The mode is only the **approval-gate
default** — it decides which option Step 6 lists first; both outcomes are
always offered there, and you never ask the user to pick a mode upfront:

- **`MODE: plan-only`** — list **"Deliver plan only"** first at Step 6.
- **`MODE: plan`**, **`MODE: UNSET (default: plan)`**, or no `MODE:` line at
  all (not in a git repo, so there was nothing to arm — distinct from the
  unarmed-inside-a-repo case the check above catches) — list **"Proceed"** first.

`begin-plan.sh` may also print a **`CONTEXT:`** line (the context gate):

- **`CONTEXT: WARN`** — the session is getting large. Surface it to the user and use
  the WARN row of Step 6's option set (it leads with **"Hand off to next agent"**).
  Nothing about *how* you plan changes.
- **`CONTEXT: HANDOFF`** — critically large, and the user already chose to proceed
  (gate bypassed). Everything WARN does, plus: do not propose a zoom or plan tour
  (Step 5) or plan-review yourself — an explicit user ask for any of these is still
  honored — and use the HANDOFF row at Step 6. "Keep the plan lean", if the command
  layer said it, means exactly those omissions: Step 4's content spec never shrinks.
- **`CONTEXT: ASK`** never reaches this skill — the command layer resolves it with the
  user first; noted for completeness.

**Load the constitution.** Resolve the constitution path (a repo may keep its
governing doc outside `.mentor/` — `constitution_path` in `.mentor/config.json`
points at it; see `/mentor:constitution`'s adopt-by-reference branch):

```bash
# via the shared subcommand, not --show-toplevel: a linked worktree must resolve to
# the MAIN repo's .mentor, where the constitution actually lives
mentor_dir="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" dir)"
repo_root="${mentor_dir%/.mentor}"
const_rel="$(jq -r '.constitution_path // empty' "$mentor_dir/config.json" 2>/dev/null)"
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
the main conversation lean. The strongest signal is an unfamiliar external
platform (an integration, SDK, or cloud service this session has not already
researched) **together with** 2+ pre-existing areas of the repo: each half alone
looks manageable inline, and the pair is what actually exhausts a context
window. For small, well-scoped tasks, read the files and draft directly in the
main thread. Nothing enforces delegation; use judgment.
**Load the dispatch contract before the first `Agent()` call, not after.** Research
dispatches follow `dispatch-agents`' "Async runtime & lifecycle" rules, and this step
fires before that skill's own first load point (Step 4) — so invoke
`Skill(skill="mentor:dispatch-agents")` here if it is not already loaded, then end
every research prompt with its **"Deliver before idling"** block pasted verbatim,
after the return contract below. Loading it here is for that block alone: the
annotation grammar is Step 4's, the execution rules are Step 6's, and the edit gate
stays closed. Citing the rules in a paraphrase is not a substitute — it drops
directives the agent has no other way to learn, the no-nested-fan-out ban above all.
One nudge on a silent idle; close each agent out once its findings are consumed.

**Research the category, not just the named instance.** When the request names
one instance of something the repo may have several of — one job to make
continuous, one config to centralize, one surface to consolidate — search for
its siblings before drafting, and carry each hit into Step 3.5 as a scope
decision. A sibling found at the approval gate rewrites the plan; the same
sibling found here costs one question.

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

Scan the task against the registry, refine after research FINDINGS return, then
re-scan the **drafted plan body** before every Step 4 write — the first draft and each
revision this loop writes. Routing off the request alone misses what a plan only grows
later: a schema section arriving at revision 3 needs backend-api's deliverable as much
as one present from the start. (Bodies rewritten inside `plan-review` or authored by
`plan-split` belong to those skills, not this loop.)

For each matched domain, invoke its planning skill **exactly once** via
`Skill(skill="…")`. Multiple domains may match; if none match, invoke the dynamic
fallback — when a registered domain matches later, `plan-domain-dynamic` owns what
supersedes what.

**Substituting an already-available skill.** No registered domain matched, but a
non-`mentor` skill already available this session — the session's skill list, not a
filesystem hunt — names this task's technology or surface in its description? Invoke
it once instead of the dynamic fallback, for its directives only: never its build,
copy, scaffold, or live-verify steps. Still produce the dynamic row's deliverable —
the `## Domain best practices applied` practice→step table — captioned
`source: <skill>`. If it covers only part of the task, run the dynamic fallback for
the rest. A registered domain matching on a later re-scan supersedes it, as it would
the dynamic brief.

A domain matching **after** research has nothing left to fold its research directives
into, and its deliverable rests on the evidence those directives gather —
backend-api's affected-callers column, say. Filled from recall it only looks
researched, so run the directives first (a targeted `Explore`, or directly per the
domain skill's own "researching directly" clause), then fold the deliverable.

| Domain | Trigger signals | Skill to invoke | Extra plan deliverable |
|---|---|---|---|
| frontend | UX/UI — components, pages, styles, layout, design systems, theming, responsive; also a message/notification surface rendered by a THIRD-PARTY client (chat embed, push notification, email chrome) | `Skill(skill="mentor:plan-domain-frontend")` | ASCII wireframes + delta/token tables (or a payload-shape table for a platform-rendered surface); live mockups only in an HTML zoom combo (`mentor:zooming`, Step 5) |
| backend-api | API/endpoint/route/handler/schema/DTO/contract — or the data model behind it: migration, table, column, index, constraint, enum, RLS policy | `Skill(skill="mentor:plan-domain-backend-api")` | Before/after contract diff tables + schema diffs + Mermaid sequence flow; on a DDL change also a per-column delta table + Mermaid ER diff of the changed entities |
| architecture (C4) | Structural change — new/changed/removed service, container, datastore, queue, external integration, component, or data flow (NOT pure content/config/doc/style/refactor) | `Skill(skill="mentor:plan-domain-architecture")` | Diff-highlighted C4-style Mermaid flowcharts, only the levels that change |
| dynamic (fallback) | no registered domain matched — and no available skill substitutes (above) | `Skill(skill="mentor:plan-domain-dynamic")` | Domain best-practices section (practice→step mapping) |

**Rows are not mutually exclusive — keep scanning past the first match.** A plan that
restructures an existing datastore's tables is a common case where two rows both fire:
`architecture` for the datastore/component boundary the change draws or redraws, and
`backend-api` for the schema itself — the row that actually produces the per-column
delta table and Mermaid ER diff. Stopping at the first clear hit ships a plan with only
the structural view and none of the schema-level one, exactly where a reviewer needs it.

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
  (Explore dispatches carry the same contract as Step 2's research agents: load
  `Skill(skill="mentor:dispatch-agents")` if it is not already loaded, and end each
  prompt with its **"Deliver before idling"** block pasted verbatim — a triage
  Explore that idles without delivering strands the very question it was sent to
  settle, and the loop cannot move on without it.)
- **User decision** — preference, product direction, scope, priorities, a
  trade-off with no objectively right answer. Queue it for the user.
- **Immaterial** — the plan comes out the same whichever way it lands. Drop
  it, or record it as a flagged assumption in the plan.

**Mid-loop scope change.** A scope-change request (not a decision *answer* —
a change to what the plan covers) pauses the per-item loop: confirm the scope
delta itself — what's kept, what's cut — in one `AskUserQuestion` before
resuming. A derived boundary question asked in its place resolves nothing,
because the boundary it assumes was never agreed.

Resolve the queued user decisions via `AskUserQuestion` — **one call, one
question, one decision at a time**. Batching decisions into one call produces
rushed, lower-quality answers. Order by dependency: resolve the decision other
decisions hang off first, and let each answer narrow the next question.

**Every question ships with decision support, and stands on its own** — the
user answers from the question screen alone, never sent to a file, a plan
section, a coined id or code (`G14`, `P2`), or an earlier turn to learn what
the question means. A word the user could read as themselves — "user" above
all — never names a domain entity; when a reviewer finding or a research
return used it that way (a caller, a row, a consumer), rename it before the
question reaches the screen. Name things in plain language, quote the
evidence that decides it rather than citing where it lives, and say in each
option what it changes and what it costs:

- In the message text **before** the tool call, give a compact decision brief:
  what the decision is, why it matters to this plan, and the relevant evidence
  from research (observed behavior, constraints, and the code itself — quote
  the line that decides it and put its `file:line` beside the quote, so the
  address is a courtesy for the curious rather than homework for the answer).
  When the decision turns on what is actually in a data or config artifact,
  read the artifact — a research summary's or the plan's own description of
  it is not the evidence. Enumerate the rows a rule applies to, not just the
  rule.
- `AskUserQuestion` needs 2–4 options per question. For open-ended decisions
  (naming, free-form scope), synthesize 2–4 concrete candidates from the
  research — the tool adds a free-text "Other" automatically, so a candidate
  list never traps the user. Only when you truly cannot form two sensible
  candidates, ask in plain prose instead.
- Put your **recommended option first** with "(Recommended)" appended to its
  label (a convention for decision questions like these — fixed workflow gates
  such as Step 6's approval order by position alone), and make each option's
  `description` carry its concrete consequence or trade-off — not a
  restatement of the label. The recommendation itself must be the most
  practical and clean solution — never trade maintainability or reliability
  for implementation speed.
- When options are competing shapes (schemas, layouts, flows, wording), use
  the `preview` field so the user compares them side by side — but keep it to
  a short literal fragment of the thing being chosen between (the actual
  snippet, schema, or wording; roughly ≤10 lines), never a framed mockup.
  Box-drawing glyphs and non-ASCII text (Thai, CJK, …) each expand to a
  6-byte `\uXXXX` escape inside the tool call's JSON, so a mockup that looks
  small on screen can truncate the call mid-string and fail validation —
  costing a whole turn to retry. **If the comparison needs a frame, a grid,
  or aligned columns to be legible, it is not a `preview`**: say so in the
  decision brief and offer an HTML zoom (Step 5 / `mentor:zooming`) instead —
  the user asking is the opt-in that step requires.

Each answer becomes a plan input. An "Other" answer may open new questions —
triage those through the same buckets. If the user explicitly defers a
decision, record the deferral in the plan (as a flagged assumption or under
Out of scope) rather than silently choosing for them. A rejected or
interrupted question is neither an answer nor a deferral — when the
clarification lands, re-issue the question; a recommendation given in prose
does not resolve a decision, and an unresolved decision that is never
re-asked is the shape a stalled plan takes.

**Skip condition:** no open questions survived triage → proceed straight to
Step 4. Never manufacture questions to fill the step — a well-specified task
with clean research needs zero.

This step resolves *post-research* decisions with evidence in hand; Step 1's
grilling handles *pre-research* ambiguity in the request itself. An earlier
grill session does not skip this step — research may have surfaced new forks —
but a decision already resolved anywhere in the conversation is never
re-asked.

## Step 4 — Write the Markdown plan {#write-the-plan}

**Check for a topic-adjacent existing plan before minting a slug** — a re-typed
request derives a fresh slug with no memory of an earlier attempt on the same
topic, and `ensure-dir` below will happily create a second directory beside it,
orphaning whichever one doesn't get worked on next:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" list
```

This is a quick scan, not a fuzzy-match algorithm: only act on a genuinely obvious
naming match — when in doubt, mint fresh, since a false reuse is worse than an
extra plan dir. If one plainly names the same topic, reuse that slug for
`plan_dir` below instead of minting a new one, and read its
`.mentor/plans/<slug>/.state.json` `note` field (`jq -r .note`) for any prior
decision or rejection worth carrying forward.

Compute the path (substituting a kebab-case `<slug>` derived from the request —
≤30 chars, drop articles, keep nouns/verbs):

```bash
slug="<slug>"
plans_dir="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" dir --plans)"   # worktree-safe
[ -n "$plans_dir" ] || { echo "ERROR: mentor plans dir unresolved — is CLAUDE_PLUGIN_ROOT set?" >&2; exit 1; }
plan_dir="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" ensure-dir "$plans_dir/$slug")" || exit 1   # creates it AND locks the path to 700
echo "${plan_dir}/plan.md"   # fixed name inside the slug dir, NO timestamp — stable across revisions
```

Write the plan there with the `Write` tool, then register it so mentor can track what
becomes of it:

```bash
slug="<slug>"   # re-derive: the block above was a separate Bash call; an empty slug registers nothing
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" init "$slug"
```

That records the plan as `draft` in a hidden `.state.json` beside it. Approval, and
later `/mentor:track`, read that state to know which plans are built and which are
pending. It is idempotent, so re-running it on a revision is harmless.

**Fleshing out a deferred stub.** If `$slug` names an existing stub born via
`/mentor:defer` — you arrived here because `/mentor:track` routed a stub pick to this
skill, or the user pointed you at one directly — run `claim` right after `init` so the
stub stops being shielded from `approve-plan.sh`'s promotion sweep:

```bash
slug="<slug>"   # re-derive: separate Bash call again (see `init` above)
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" claim "$slug"
```

`claim` clears the sidecar's `origin` field; it is a harmless no-op (with a one-line
notice) when there was nothing to clear, so it costs nothing to run whenever this
plan slug could plausibly be a stub you are now fleshing out. A brand-new plan with no
prior stub never needs this line.

The path is inside the gate-exempt
`.mentor/` tree, so the edit gate allows it; `plan-open.sh` auto-opens it for review the first time
(VSCode tab when available — toggle preview with ⇧⌘V; opener configurable via
`MENTOR_PLAN_OPENER`, disable with `MENTOR_PLAN_OPEN=off`, both under `env` in
`~/.claude/settings.json`). **Keep it current:** on every revision re-write this
SAME file in place — never create a second timestamped copy. Never write the
plan anywhere else in the repo or to the harness-native `~/.claude/plans/` dir.
Before each re-write, re-run Step 3's registry scan against the new body — that is
where a domain the plan only just grew gets caught.

**Verify the write:** an `Edit` whose anchor lands mid-table or mid-fence can
splice a row or split a fenced block without erroring — nothing else in this
skill catches it, and a revision built from many small edits (a fold pass, a
decision resolution, a split) is exactly when this happens. After such a
revision, re-read the changed region and confirm every GFM table's rows still
share one pipe-count and every fence still opens and closes in pairs before
moving on — a broken table has no guaranteed downstream reader (a reviewer
pass may not run before the next approval question). Prefer replacing a whole
table/fenced block in one edit over splicing a single row into it.

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
4. `## Approach` — the recommended design — the most practical and clean
   solution for the requirement, never trading maintainability or reliability
   for implementation speed — with one visualization per significant
   change/decision realized inline under its owning topic.
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
   `Skill(skill="mentor:dispatch-agents")` (skip the re-invocation if Step 2 already
   loaded it) and annotate every implementation
   step per its grammar (`[role: … · model: … · effort: …]`, grouped
   `Run in parallel:` / `Sequential:`) — one plan step = one dispatch.
   **Escape hatch:** when the implementation meets the dispatch-agents skill's
   skip rule, omit the annotations, but the section MUST then open with one
   line: `Dispatch: skipped — <reason>`. No line, no skip.
   **Keep it small while you write:** if the step count creeps past ~12 while
   drafting this section — Step 6's oversize threshold below, just reached early —
   pause and offer to defer non-core chunks via `Skill(skill="mentor:deferring")` before
   finishing the write, rather than waiting for the Step 6 gate to catch an already-
   oversized plan. A plan that arrives at Step 6 already trimmed rarely needs the
   full split treatment.
7. `## Critical files`
8. `## Out of scope` — name every carve-out so the reviewer sees the
   boundary, but give one a **plan number or slug** only when it resolves on
   disk (a `/plan-split` sibling, or a `/mentor:defer` stub for work the user
   actually asked for); an invented `feature 0NN` reads as a roadmap promise
   `/mentor:track` cannot see.
9. `## Verification` — how to test end-to-end.

**Visualization decision rule (pick exactly ONE idiom per artifact):**

- Tabular data (field lists, diffs, matrices, before/after values) → **GFM table**.
- Topology / sequence / state (flows, state machines, ER, dependencies) →
  **Mermaid** fenced block.
- Spatial/layout fidelity (UI zone wireframes, fixed-width alignment) →
  **ASCII diagram in a code fence**.
- Callouts / cautions → **GFM alert** (`> [!NOTE]`, `> [!WARNING]`, …).
- Literal code / payloads → fenced code with a language tag.

**State vocabulary rule.** When a plan introduces, renames, or re-scopes a named
status for any entity (`MONITORING → PENDING`, `ACTIVE → TRIGGERED/CANCELLED`),
or changes which transitions are legal between statuses that already exist —
a new cascade side-effect where reaching one terminal status now forces
another, say — render the *transitions*, not just the values. A status name
staying put says nothing about its edges staying put. The `stateDiagram-v2`
the idiom rule already selects shows the shape — which states reach which,
added and removed edges marked; a companion
`From · Event/verb · To · Trigger · Cascade` table carries what a shape
cannot encode, and it is the table that exposes a
**missing** edge, since reverse transitions and cascade side-effects are the
ones that surface late. That pairing is complementary, not the same-thing-twice
the rule below forbids. Skip it when no entity has more than one named state, or
when the states are unchanged and only their storage moves — that delta is
`plan-domain-backend-api`'s per-column table, and restating it here would
duplicate.

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

## Step 5 — Optional HTML zoom & plan tour (explicit user opt-in only) {#html-zoom}

The topic × perspective HTML zoom is its own skill — `zoom` — and this step is
pure delegation. Only when the **user asks** for an HTML zoom / visual preview
— never by default — invoke `Skill(skill="mentor:zooming")` and follow it end to
end with the plan as the subject:

- **Subject = the current plan** (`${plan_dir}/plan.md`), so per the zoom
  skill's plan-slug contract its artifacts land in
  `.mentor/zooms/<plan-slug>/<topic>-<perspective>.html`.
- Candidate **topics** derive from the plan itself — its `## Approach`
  subsections, `Proposed UI changes per surface` entries, or
  implementation-step groupings.
- The constitution path resolved at Step 0 is the one the zoom skill's
  Reviewer/Architect combos consume.

EVERY zoom ask re-enters the zoom skill's contract (its sticky re-entry rule)
— the first one, the Nth one, a free-text follow-up ("update the review
artifact", "add a zoom for X"), a mid-revision regeneration, at any point in
the plan lifecycle.

**Revision completeness.** When a plan revision or a product decision
invalidates prior zooms, re-enter `mentor:zooming` and follow its re-zoom rule
(grep the invalidated term across `.mentor/zooms/<plan-slug>/*.html` and
re-dispatch EVERY matching combo in one batched message). Wait for those
agents to complete before dispatching `plan-review`, so a reviewer never reads
a zoom mid-write.

**Plan tour.** Only when the user asks for a walkthrough or tour of *how the
plan will execute* — never by default — invoke `Skill(skill="mentor:plan-touring")`
with the current plan as the subject; its artifacts land in
`.mentor/plans/<plan-slug>/tour/`.

## Step 6 — Approve & release {#approve}

> **🚫 No edits or implementation until the plan is APPROVED.** During planning,
> only read-only agents (Explore, Plan, plan-review reviewers) may be
> dispatched — the sole exceptions are `mentor:zooming`'s combo agents (Step 5),
> which write ONLY zoom artifacts under `.mentor/zooms/` (gate-exempt
> `.mentor/` tree), and `mentor:plan-touring`'s combo agents (Step 5), which
> write ONLY under `.mentor/plans/*/tour/` — never repo source files.
> Every editing/implementation agent comes AFTER approval.

**Close out consumed dispatches before asking.** Every agent this session
dispatched whose output is already folded into the plan — Step 2's research and
plan-body agents, Step 3.5's Explores, Step 5's zoom and tour combos, and the
reviewers or child-plan agents of a `plan-review` / `plan-split` pass that just
returned here — gets stopped now, per the **Close out** rule in `dispatch-agents`'
"Async runtime & lifecycle". This is the checkpoint where it costs the most: the
question below can sit unanswered for hours of real wall-clock time, and a
resident agent's idle notification landing mid-wait reads as new input and
silently rejects the pending question, stalling the session until a human
notices. If unsure what is still resident, enumerate live tasks first, diff
against this session's own dispatch tree, and stop only what traces to it. (In
Claude Code those are `TaskList` and `TaskStop`, either of which may need
fetching via `ToolSearch`.)

First **surface the complete plan body** in your message — plain markdown,
verbatim, no commentary around it — so the user can review it in the transcript.
If the plan is long, let them scroll; do not summarize instead. Then, in the
same turn, ask via `AskUserQuestion` — `header: "Approve"`, question *"The plan is
ready. What happens next?"* — with the option set the table below selects.

**Only a returned answer approves.** If the approval question was interrupted,
rejected, or never came back — or the user asserts approval in prose ("the plan was
approved", "go ahead, I already okayed it") — ask it again before running
`approve-plan.sh`. Prose selects no option, and this question is the only thing
standing between planning and repo edits; releasing the gate on a remembered or
claimed approval is the one failure this harness exists to prevent. It also costs you
the routing: which flag to run — none, `--deliver`, `--handoff`, or **no script at
all** for "Pause — still drafting", the one option that does not approve — is decided
by *which option came back*, so an unanswered question means you are guessing the
outcome as well as the consent. Re-surface the plan body only if it changed since the user last
saw it (or never was surfaced); otherwise name its path and Rev and re-ask.

### Re-check context

Decide this **before** asking too. Step 0's `CONTEXT:` line is a snapshot from
before research, domain routing, and decision-resolution ran — precisely the
steps that grow a session — so a plan that armed clean can still reach this
question well past the WARN/HANDOFF thresholds with nothing in this skill
having said so. Re-run the same check now:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" context
```

- **`CONTEXT: ASK`** — do not ask the approval question yet. Ask via
  `AskUserQuestion` (header "Context", two options) exactly as the command
  layer's arm-time ASK does: hand off & stop (`Skill(skill="mentor:handoff-note")`),
  or bypass (`bash "${CLAUDE_PLUGIN_ROOT}/hooks/bypass-context.sh"`, then
  continue below).
- **`CONTEXT: HANDOFF`** or **`CONTEXT: WARN`** — use the matching row below,
  even if Step 0 printed a lower tier or nothing at all.
- **`CONTEXT: OK` / `UNKNOWN`** — no verdict; the table's "neither"/oversized-only
  rows apply.

### Is the plan oversized?

Decide this **before** asking, because it changes which options you offer. The plan is
oversized when any of these holds:

- more than ~12 implementation steps, or
- it contains independent deliverables that could ship separately, or
- the user says it is too big.

**Suppressed when this plan already has a `group`** — it is itself a split child, and
re-slicing a slice usually means the first split drew its lines in the wrong place.
Typing `/plan-split` still works if the user insists.

When oversized, mention in the question text that non-core chunks can instead be
**deferred via `/mentor:defer`** rather than a full split — a lighter alternative
worth naming even though it isn't its own button. The option table below is
unchanged: the user reaches this by typing it into `AskUserQuestion`'s always-present
"Other" free text, not by picking a listed option.

### The option set

`AskUserQuestion` caps at 4, and the oversize and context conditions fire together
constantly — so the precedence is fixed here rather than left to judgment in the
moment:

| Condition | Options, in order | Yields to "Other" |
|---|---|---|
| neither | Proceed · Deliver plan only · Review the plan (staged) · Keep planning | — |
| `CONTEXT: WARN` only | Hand off to next agent · Pause — still drafting · Deliver plan only · Proceed | Review, Keep planning |
| `CONTEXT: HANDOFF` only | **Hand off to next agent (Recommended)** · Pause — still drafting · Deliver plan only · Proceed | Review, Keep planning |
| oversized only | **Split into multiple plans** · Proceed · Review the plan (staged) · Deliver plan only | Keep planning |
| oversized **and** `CONTEXT: WARN` | **Split into multiple plans** · Hand off to next agent · Deliver plan only · Proceed | Review, Keep planning, Pause |
| oversized **and** `CONTEXT: HANDOFF` | **Hand off to next agent (Recommended)** · Pause — still drafting · Deliver plan only · Proceed | Review, Keep planning, Split |

In the first row only, `MODE: plan-only` swaps the leading two so "Deliver plan only"
comes first. Anything yielded to "Other" stays reachable — the user can just say it.
Under `CONTEXT: HANDOFF`, also note in the question text that the session is
critically large.

**Whenever both handoff options are listed, say in the question text which options
release the gate.** They differ only in consent — one approves, one does not — and a
label alone cannot carry that. A user who is out of room reads "hand off" and picks
the first match; if that silently approves, a fresh agent starts implementing a plan
they never approved, which is the one failure this harness exists to prevent. Naming
the consequence in the question costs a sentence and removes the guess.

Split leads on an oversized plan because handing one off whole only moves the problem
to the next session, while the split's authoring cost lands in dispatched agents
rather than in this thread. **`CONTEXT: HANDOFF` outranks even that**: at that size the
safest possible act is to write the handoff and stop, and the split can happen in the
fresh session with room to verify it — which is also why *Split* is the option that
yields in the oversized **and** `CONTEXT: HANDOFF` row. Review stays visible in the
oversized-only row because an oversized plan is exactly the kind most worth reviewing;
*Keep planning* yields instead.

**Why *Keep planning* yields to the new option once a context verdict fires.** Both
mean "do not approve yet", so listing both wastes one of four slots — and of the two,
*Keep planning* is the one that needs no button: the user just keeps talking and
planning continues. "Pause — still drafting" cannot be improvised that way, because it
has to write the handoff **without** approving, and every other listed option at that
point releases the gate. *Proceed* and *Deliver plan only* both stay visible in every
row: the `MODE:` default must always be offered (Step 0), and pushing the option that
starts implementation into free text would make the highest-consequence answer the
hardest one to give.

| Label | Description |
|---|---|
| Proceed | Validate the plan, release the edit gate, and begin implementation. |
| Deliver plan only | Validate the plan and release the gate; the plan file is the deliverable — no implementation, no dispatch. (/mentor:handoff can brief a fresh agent afterwards.) |
| Review the plan (staged) | Run plan-review — a judgment pass (practicality, comprehensiveness) whose edits you verdict one question at a time, then a mechanical pass (cleanliness, consistency) whose safe fixes auto-fold and whose decision-level findings are asked one by one. Stays in planning; ends back at this question. |
| Keep planning | Do not release — keep refining. Re-write the plan file and ask again when ready. |
| Split into multiple plans | Slice this plan into independently buildable sibling plans, each with explicit scope isolation. Stays in planning; asks again afterwards. |
| Hand off to next agent | Approve and release, then write a handoff doc so a fresh agent implements it — this session is getting large. |
| Pause — still drafting | Write a handoff doc and stop **without approving**: the gate stays armed and the plan stays `draft`, so the next session continues *planning*, not implementing. For when the session is out of room but the plan is not settled. |

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
starting the next. Mark each step done as it passes with `bash
"${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" tick <slug> <N>` — see
`mentor:dispatch-agents`' "Track progress in the plan file" for why the tick's
placement is load-bearing and what `tick` does about it. Keep a step's own body
on `-` bullets, though: the counter cannot tell a numbered sub-item from a step,
and an inflated denominator strands a finished plan at `in_progress` forever. Its
**No busy-wait** rule applies to every wait on this path, dispatched or not.
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

**Close out the skipped path too.** For the same reason, that skill's CLOSING
CHECKLIST is unreachable here, so carry its two user-facing items across — there
are no agents to release, but there is still work to hand back:

- **Offer `/mentor:tour`** — one line: a hands-on acceptance pass building an
  editable guided-tour review artifact (pass/not-pass scenarios) of what shipped.
  Do not auto-run it; it publishes to a stable URL, so the user chooses.
- **Sweep the report you're about to write** — every follow-up, gap, or
  known-broken item in it goes through `/mentor:defer` first.

Skipping dispatch is a decision about *who types the edits*, not a discount on
what the user gets at the end.

On **Deliver plan only**, run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/approve-plan.sh" --deliver
```

Same validation + release, then **follow the DELIVER-ONLY directive it prints** —
report where the plan lives and STOP. Do not implement and do not dispatch in
this session.

On **Hand off to next agent**, run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/approve-plan.sh" --handoff
```

Same validation + release, then **follow the hand-off directive it prints** —
invoke the handoff skill for this approved plan and stop. Do not implement and
do not dispatch in this session.

An **"Other" answer expressing handoff intent** does *not* route here by default.
There are two handoff outcomes now and they differ on consent, so free text like
"let's hand this off" names the outcome without settling whether the plan is
approved — exactly the inference the rule above forbids. Route it only when the
answer also expresses approval ("looks good, hand it off"). Otherwise ask **one**
follow-up `AskUserQuestion`: approve and hand off, or hand off still drafting.

On **Pause — still drafting**, run **no script at all** — not
`approve-plan.sh`, not with any flag. The gate must stay armed and the plan must
stay `draft`; that is the whole point of the option, and every flag this skill
has approves. Instead invoke `Skill(skill="mentor:handoff-note")` with a focus
that states the planning is unfinished, then print its resume prompt and stop.

Give the handoff note these three facts explicitly, because the next agent cannot
infer them and each one has bitten a real session:

- **The plan is `draft` and the gate is deliberately still ARMED** — `mentor:resuming`
  tells the next agent to trust the marker over the note when they disagree, so an
  armed marker with no explanation reads like a crashed session rather than an
  intentional pause.
- **Continue the *existing* plan** at `.mentor/plans/<slug>/plan.md` — reuse that slug.
  A fresh `/mentor:plan` derived from a re-typed request can mint a second plan dir and
  orphan this draft.
- **Re-write the plan file before approving it.** Whoever resumes runs `/mentor:plan`,
  which re-arms the marker with a *fresh* mtime, and `approve-plan.sh` refuses any
  `plan.md` older than the marker. Any real revision (a Rev bump) clears it; without
  this line the next approval fails with "Newest plan predates this planning session"
  and no hint of the cause.

On **Review the plan (staged)**, invoke `Skill(skill="mentor:plan-review")` and
prepend: *"The user selected 'Review the plan (staged)' — skip the Step 2 gate
and start Stage 1 directly."* Its reviewers are read-only and the gate stays
closed; the skill itself folds the Stage 1 edits the user accepts at its
one-question-per-edit fold gate and auto-folds MECHANICAL Stage 2 findings
into the plan file (gate-exempt `.mentor/` writes), walks DECISION-REQUIRED
findings one verdict question at a time (applying only accepted resolutions),
then returns to this same question — this option never releases the gate by
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

### Retracting an approval {#retract}

Sometimes an approval lands that the user did not intend — they pick an approving
option, then immediately say "no, that wasn't approved yet". Re-arming the gate is the
obvious half of the fix and the only half people remember, so state the rest here:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/begin-plan.sh"                                       # re-arm the gate
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" set <slug> draft --note "approval retracted"
```

The second line is not optional. **Every** approval path — no-arg, `--deliver`,
`--handoff` — promotes the plan's `.state.json` to `approved` before it exits, and
`begin-plan.sh` touches only the marker. Re-arm alone therefore leaves a plan recorded
as `approved` behind a closed gate: `/mentor:track` reads the sidecar, not the marker,
so a later session sees a green light and dispatches implementation agents into a gate
that denies their first write.

Two consequences to tell the user about while you do it:

- **The plan must be re-written before it can be approved again.** Re-running
  `begin-plan.sh` resets the marker's mtime, and `approve-plan.sh` refuses any
  `plan.md` older than the marker. This is the same staleness defense that stops an
  old plan being resurrected, and here it fires on the plan you just retracted. Any
  genuine revision (a Rev bump per Step 4) clears it.
- **Retraction is a pre-implementation act.** Effective state is the *more advanced* of
  the stored state and what the plan's `✅` step ticks imply, so storing `draft` on a
  plan that already has ticks is silently outranked — `plan-state.sh` even says so as it
  writes. If any step is ticked, work has already shipped: surface that to the user as a
  rollback decision (revert the work, or keep it and re-plan the remainder) instead of
  quietly writing a state that will not take.

The cleaner escape is not to need this: when the user is out of room but not ready to
approve, "Pause — still drafting" hands off with the gate still armed and nothing to
retract.
