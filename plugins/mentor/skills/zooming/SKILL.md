---
name: zooming
description: |
  Topic × perspective HTML zoom — focused, self-contained, LOCAL HTML review
  pages for ANY subject: a repo subsystem, a design doc or ADR, a mentor plan,
  or just the thing under discussion. No plan file and no planning session
  required. Trigger phrases: `/zoom`, `/mentor:zoom`, "zoom into X", "show me
  X as an HTML page", "render a visual preview of this", "make a diagram page
  for X", "I want to SEE this instead of reading markdown",
  "update/refresh the zoom", "the zoom is stale". Resolves
  topic(s) × perspective(s) (End user / Implementor / Reviewer-Architect /
  QA-Tester), then dispatches one agent per combo, each writing ONE
  self-contained HTML file to .mentor/zooms/<subject-slug>/ — auto-opened
  locally, NEVER published via the Artifact tool, no reviewer interaction.
  Distinct from /mentor:tour (a published, editable acceptance page where
  reviewers mark pass/not-pass and leave feedback) and from /plan-review
  (a quality verdict on a written plan, not an HTML page).
---

# Zoom — Topic × Perspective HTML Review Pages

Generate (and regenerate) **zoom artifacts**: self-contained HTML pages, each
scoped to one **topic × perspective** pair, that let a human *see* one slice of a
subject through one lens instead of reading prose. The subject can be anything —
a mentor plan, a subsystem of the repo, a design doc, the feature under
discussion. Zooms are **throwaway local visual aids**: the subject (the `.md`
plan, the source code, the doc) stays the source of truth — no sync contract, no
finalize step, and **never a hosted copy**.

**Sticky re-entry rule.** EVERY zoom ask re-enters this skill's contract — the
first one, the Nth one, a free-text follow-up ("update the review artifact",
"add a zoom for X"), a mid-revision regeneration, at any point in any workflow.
Run the Selection gate (skipping questions the ask already answers) and generate
via dispatched agents. **Never hand-edit or hand-write a zoom file in the main
thread** — least of all late in a session, when context is already large. And
**never one file for the whole subject** — a whole-subject ask ("preview the
plan as HTML") does not bypass the gate below; it is exactly the case the gate
exists for.

## When to use

- The user asks for an HTML zoom, a visual preview, a diagram page, or to "see"
  a subject rendered — `/zoom`, `/mentor:zoom`, or the matching natural language.
- `plan` Step 5 delegates here when the user opts into a zoom during planning.
- A previous zoom needs regenerating because its underlying content changed.

## When NOT to use

- Nobody asked for a visual — zooms are **explicit opt-in only**, never a default
  deliverable.
- The user wants a **shareable page where reviewers mark pass/not-pass and leave
  feedback** — that is `/mentor:tour` (published on purpose, editable). A zoom is
  local, read-only, and has no reviewer interaction.
- The user wants a **quality verdict on a written plan** — that is `/plan-review`
  (staged reviewers folding edits into the `.md`), not an HTML rendering.
- The user wants the plan/doc itself authored or revised — zooms visualize
  content that already exists; they never replace it.

## Step 0 — State dir, subject, and slug

Derive the project-scoped mentor state dir (same derivation as `hooks/lib/state.sh`
— never hardcode paths; not in a git repo → fall back to `~/.claude/mentor/_no-repo`):

```bash
state_dir="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" dir)"   # worktree-safe; _no-repo fallback
[ -n "$state_dir" ] || { echo "ERROR: mentor state dir unresolved — is CLAUDE_PLUGIN_ROOT set? do not search the plugin cache or hardcode a version path; ask the user to /reload-plugins or restart" >&2; exit 1; }
ls -t "$state_dir"/plans/*/plan.md 2>/dev/null | head -3   # candidate plan subjects (newest first)
sibling_wts="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" gate --verbose | sed -n 's/^elsewhere=\([^ ]*\).*/\1/p')"
[ -n "$sibling_wts" ] && bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" list --owners   # cross-check OWNER col below
const_rel="$(jq -r '.constitution_path // empty' "$state_dir/config.json" 2>/dev/null)"
case "$state_dir" in */.mentor)   # in a repo — resolve the constitution against its root
  const_path="${state_dir%/.mentor}/${const_rel:-.mentor/constitution.md}"
  [ -f "$const_path" ] && echo "constitution: $const_path" ;;
esac
```

**Resolve the subject**, in priority order:

1. the **argument** — free text ("the ingestion pipeline"), a file/dir path, or a
   plan-slug substring;
2. the **newest plan** from the listing above, when one exists and the
   conversation is about it — but when `$sibling_wts` is non-empty (`ARMED_ELSEWHERE`),
   first drop any candidate whose OWNER column (from `list --owners` above) matches one
   of those wt-ids: a sibling's live marker means that plan is mid-write, not this
   zoom's subject. If the filter empties the listing or leaves the pick ambiguous, ask
   the user for an explicit subject instead of guessing. **Note:** the newest plan in
   the raw listing may be the sibling's — name the plan you picked.
3. the feature/system under discussion in the **current conversation**.

The plan is an *input source*, never a prerequisite — the skill works standalone.
Derive the **`<subject-slug>`** (kebab-case, stable across re-runs so a re-zoom
overwrites in place). **Plan-slug contract:** when the subject is a mentor plan,
`<subject-slug>` IS the plan's dir name (`basename` of its `plans/<slug>/`) — this
is what lets `plan-review` and `handoff` find a plan's zooms at
`.mentor/zooms/<plan-slug>/` without guessing. All output lands in
`zoom_dir="$state_dir/zooms/<subject-slug>"`.

There is **no planning-session guard**: `.mentor/` is exempt from the plan edit
gate, so zooming is legal while this worktree's gate reads `ARMED` — during planning,
this skill's combo agents are the sole write-capable dispatches allowed, and they
write ONLY zoom artifacts under `.mentor/zooms/`, never repo source files.

## Step 1 — Source pack (resolve inputs before any dispatch)

Dispatched combo agents must not fan out further (`dispatch-agents`, "no nested
fan-out"), so everything they need to read must be resolved first:

| Subject kind | Source pack |
|---|---|
| A canonical document (a mentor plan, spec, ADR, README) | its path — each combo agent `Read`s it directly |
| Repo code / a subsystem | the real file paths (from prior research or a quick Glob/Grep); when the area is broad or unfamiliar, dispatch **one read-only `Explore` agent** first and write its FINDINGS + `file:line` EVIDENCE to `${zoom_dir}/_brief.md` |
| Conversation-only subject (no file exists) | the main thread writes `${zoom_dir}/_brief.md` distilling the conversation — the one main-thread write this skill permits, and it is a brief, never a zoom |

Every combo prompt carries the hard rule: **invent nothing** — every claim,
color, code path, and step in a zoom traces to a real file from the source pack
or to `_brief.md`.

**Pre-assign ids that span files.** "Invent nothing" constrains claims, not
identifiers — an agent minting `R3` for its own slice obeys it, and so does the
sibling minting `R3` for a different one. When the subject carries an id scheme
the combos share (rule ids, numbered callouts, scenario numbers, row labels read
across files), resolve the concrete id→referent map here and paste it verbatim
into every combo prompt — keyed by referent, and covering every namespace the
files reuse, not just the one this revision introduced. Pinning the map also
turns the check afterwards into a known-answer grep instead of an improvised
one. `dispatch-agents`' shared-sequence rule says the same for plan steps; its
`Sequential:` escape is unavailable here, since Step 3 dispatches all combos in
one message.

## Step 2 — Selection gate

Resolve two dimensions before generating anything:

1. Derive up to 4 candidate **topics** from the subject: a plan's `## Approach`
   subsections, `Proposed UI changes per surface` entries, or implementation-step
   groupings; a codebase subject's natural sub-areas; a brief's sections.
2. Ask ONE `AskUserQuestion` call with two multi-select questions — **Topics**
   (the derived candidates) and **Perspective** (catalog below). Skip a question
   only when the user's request already explicitly named that dimension ("zoom
   into checkout as the end user" skips both). When only one topic is derivable,
   treat topic as resolved and ask only Perspective (AskUserQuestion needs 2–4
   options per question). **Every question stands on its own:** the user answers
   from the question screen alone — never sent to a file, a plan section, a coined
   id or code, or an earlier turn to learn what the question means. A topic option
   therefore names the subject matter in the user's own vocabulary, not the plan
   heading it was derived from ("Step 3" tells them nothing once the plan is closed).

| Perspective | The zoom emphasizes |
|---|---|
| End user | Journey/scenario walkthroughs, visible states, UI mockups (UI topics); hides implementation detail |
| Implementor | File-level touchpoints, sequence diagrams, data structures, step order/dependencies |
| Reviewer / Architect | Architecture slice, trade-offs, risks, constitution compliance for that topic |
| QA / Tester | Test scenarios, edge cases, verification steps for that topic |

Combos = selected topics × selected perspectives. If combos > 6, confirm the
count before dispatching (mention `MENTOR_PLAN_OPEN=off` as the escape hatch —
every finished file auto-opens). Kebab-sanitize topic and perspective names and
uniquify colliding topic slugs (append `-2`, `-3`, …) so no two combos share a
path.

## Step 3 — Generation — one agent per combo, always dispatched

**Run the pre-dispatch preflight before the first `Agent` call, not after.** One call,
no skill load:

```bash
[ -d "${CLAUDE_PLUGIN_ROOT}/hooks" ] || { echo "ERROR: CLAUDE_PLUGIN_ROOT unresolved or stale — do not search the plugin cache or hardcode a version path; ask the user to /reload-plugins or restart" >&2; exit 1; }
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" policy
```

`POLICY: FOUND` — a standing no-subagents instruction is on record; stop and ask before
dispatching. `UNRESOLVED` — the check could not run, which is not a clean result; treat
the question as open. `NONE` — dispatch. `CONTRACT: active` confirms
`hooks/dispatch-contract.sh` appends the standing "Deliver before idling" block to every
dispatch prompt automatically: **do not paste it by hand.** Only on `CONTRACT: MISSING`
do you paste it yourself, from `dispatch-agents`' own section of that name.

Step 1's "no nested fan-out" reaches a combo agent only through that injected block, which
is why `CONTRACT: MISSING` matters here even though nothing else in this skill dispatches.
The block's durable-copy clause is for verdict-producing agents (reviewers, verifiers) — a
combo's durable artifact is the HTML file it already writes, and nothing here writes under
`plans/`.

Issue one `Agent` call per combo (`subagent_type: general-purpose`,
`model: sonnet`, `effort: high`), ALL combos in one message — even a single
combo is dispatched, keeping one contract and keeping HTML out of the main
context. Each agent's prompt carries: the source pack (Step 1), its topic, its
perspective row from the catalog above, the output path
`${zoom_dir}/<topic>-<perspective>.html`, the spec below, the invent-nothing
rule, and the delivery prohibition: *"Do NOT call the `Artifact` tool and do NOT
return any hosted URL. Return ONLY the file path + a `Self-check:` line in named
fields — `sections=N diagrams=N doctype=yes closing-html=yes tags-balanced=yes`
— never the HTML body."* Named fields rather than free prose, because prose
makes an **absence** invisible: a combo that quietly omits "full standalone
document" reads just like the ones that claim it, and the omission is the signal
worth catching. Perspective-conditional inputs: **Reviewer/Architect** combos
also get the resolved constitution path (Step 0) when that file exists; on an
**infra-heavy topic**, a Reviewer/Architect combo's emphasis extends to
deployment topology, capacity/health-check chains, and blast radius — if
those facts were gathered live this session (CLI/API output, no source file),
write them to `${zoom_dir}/_brief.md` once per Step 1's conversation-only-subject
row and point every such combo at it, rather than re-deriving the same facts
in each combo's prompt; a **UI-surface topic** gets the mockup contract inputs from
`plan-domain-frontend` §4 whenever the perspective needs to *see* the surface to
do its job — End user, Reviewer/Architect, and QA/Tester (the tester must see
the states they verify) — but **not** Implementor, whose zoom is about file
wiring and step order, where a pixel-faithful mockup is redundant.

Per-file spec: a single self-contained file — inline CSS, no build step;
Mermaid via CDN
(`https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js` +
`<pre class="mermaid">`) is allowed; content for the **assigned topic through
the assigned perspective only**, never the whole subject; readable — body text
≥15px-equivalent, WCAG-AA contrast, monospace for code; authored in a
**single `Write` call** (no skeleton-then-`Edit` — plan-open.sh opens the file
on first Write and must never show a half-built page). The path is inside the
gate-exempt `.mentor/` tree, so any armed plan gate allows the Write;
plan-open.sh auto-opens each file once. Stable names — a re-zoom of the same
combo overwrites in place. Zooms whose content is primarily visual (mockups,
diagrams) SHOULD ship lightweight pan/zoom affordances on the outer page
(fullscreen toggle ⛶, overlay scrim, +/−/reset, wheel-zoom — inline JS in the
outer file only; iframe `srcdoc` panes stay no-JS per `plan-domain-frontend`
§4).

## Step 4 — Completion check

After the agents return, `ls "$zoom_dir"` against the expected combo files and
confirm each file's structural bookends yourself — first bytes match `<!doctype`
or `<html` case-insensitively, last non-whitespace is `</html>`, size non-zero —
as one Bash loop over the dir emitting one `OK`/`BAD` line per file. Read each
agent's `Self-check:` line for everything else. Those bookends are the **only**
re-derivation worth running: they cost no context and catch the truncated page
that an agent dying mid-`Write` still self-reports as balanced, whereas
re-grepping a zoom's *content* to re-verify what the `Self-check:` already
reports just drags HTML into the main thread.

A missing file, a structurally invalid one, and a `Self-check:` missing a
required field all take the same path — re-dispatch that combo once, naming the
defect, before giving up. Zoom dispatches follow `dispatch-agents`' "Async
runtime & lifecycle" rules — close out finished combo agents after the remedy
rather than after the check, so a still-warm agent stays reachable for the
repair. Closing out means calling `TaskList` (fetch it plus `TaskStop` via
`ToolSearch` first if this session hasn't loaded them yet) and diffing
against the dispatched combos before `TaskStop`ping them, for every batch —
not just the last one, since a multi-topic zoom is itself a batch of up to 6
combos and "all combos are closed" is not true until that call has actually
been made.

## Step 5 — Re-zoom on revision (completeness-checked, not memory-driven)

When a revision of the subject — a plan edit, a product decision, a code change
— invalidates prior zooms, `grep -l` the invalidated term across every existing
`${zoom_dir}/*.html` and re-dispatch EVERY matching combo in one batched
message — never just the combo you remember changing. When the subject is a
plan under review, wait for these agents to complete before any `plan-review`
dispatch, so a reviewer never reads a zoom mid-write.

Each re-dispatch prompt names the superseded term and the term replacing it, and
requires the returned `Self-check:` to add `residual-<old>=N` — one short reason
per remaining hit — plus `new-term-present=yes`. Then compare: `grep -c` the old
term per regenerated file against the declared count, and re-dispatch once on a
mismatch, or on a hit with no stated reason. The agent that wrote the file
already knows which occurrences are deliberate before/after content, so asking
it to declare them keeps that judgment where the evidence is — and keeps
acceptance identical on the first regeneration and the third, instead of
drifting with how thorough the orchestrator feels late in a session.

## Done when

- Every selected combo has its `${zoom_dir}/<topic>-<perspective>.html` on disk
  with a consumed `Self-check:` line (one re-dispatch attempted for any missing
  combo), and finished combo agents are closed out.
- The selection gate ran (or was skipped because the ask named both dimensions),
  and no zoom covers more than its one topic × perspective.
- Nothing was published: no `Artifact` call, no hosted URL — only local files
  that plan-open.sh auto-opened.

### Do NOT

- Do **not** call the `Artifact` tool, return a hosted URL, or publish a zoom in
  any form — zooms are local-only; the published review surface is `/mentor:tour`.
- Do **not** write a zoom (or anything else) into the repo source tree, `plans/`,
  or `tours/` — zoom output lives only under `.mentor/zooms/<subject-slug>/`
  (the plan resolution helpers glob `plans/*/plan.md` and must never see zoom
  files).
- Do **not** hand-author or hand-edit zoom HTML in the main thread — generation
  is always dispatched; the only main-thread write is `_brief.md` (Step 1).
- Do **not** edit the subject — the plan, doc, or source files are read-only
  inputs here; folding changes into a plan is `plan`/`plan-review` territory.
- Do **not** render the whole subject as one file — one topic × perspective per
  file, always through the Selection gate.
