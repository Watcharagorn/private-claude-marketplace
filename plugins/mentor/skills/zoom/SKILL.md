---
name: zoom
description: |
  Topic × perspective HTML zoom — focused, self-contained, LOCAL HTML review
  pages for ANY subject: a repo subsystem, a design doc or ADR, a mentor plan,
  or just the thing under discussion. No plan file and no planning session
  required. Trigger phrases: `/zoom`, `/mentor:zoom`, "zoom into X", "show me
  X as an HTML page", "render a visual preview of this", "make a diagram page
  for X", "I want to SEE this instead of reading markdown". Resolves
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
git_common=$(git rev-parse --git-common-dir 2>/dev/null) && \
  repo_root=$(cd "$(dirname "$git_common")" && pwd)
state_dir="${repo_root:+$repo_root/.mentor}"; state_dir="${state_dir:-$HOME/.claude/mentor/_no-repo}"
ls -t "$state_dir"/plans/*/plan.md 2>/dev/null | head -3   # candidate plan subjects (newest first)
const_rel="$(jq -r '.constitution_path // empty' "$state_dir/config.json" 2>/dev/null)"
[ -n "${repo_root:-}" ] && const_path="$repo_root/${const_rel:-.mentor/constitution.md}"
[ -f "${const_path:-}" ] && echo "constitution: $const_path"
```

**Resolve the subject**, in priority order:

1. the **argument** — free text ("the ingestion pipeline"), a file/dir path, or a
   plan-slug substring;
2. the **newest plan** from the listing above, when one exists and the
   conversation is about it;
3. the feature/system under discussion in the **current conversation**.

The plan is an *input source*, never a prerequisite — the skill works standalone.
Derive the **`<subject-slug>`** (kebab-case, stable across re-runs so a re-zoom
overwrites in place). **Plan-slug contract:** when the subject is a mentor plan,
`<subject-slug>` IS the plan's dir name (`basename` of its `plans/<slug>/`) — this
is what lets `plan-review` and `handoff` find a plan's zooms at
`.mentor/zooms/<plan-slug>/` without guessing. All output lands in
`zoom_dir="$state_dir/zooms/<subject-slug>"`.

There is **no planning-session guard**: `.mentor/` is exempt from the plan edit
gate, so zooming is legal while a `.planning` marker is armed — during planning,
this skill's combo agents are the sole write-capable dispatches allowed, and they
write ONLY zoom artifacts under `.mentor/zooms/`, never repo source files.

## Step 1 — Source pack (resolve inputs before any dispatch)

Dispatched combo agents cannot fan out further (`dispatch-agents`, "no nested
fan-out"), so everything they need to read must be resolved first:

| Subject kind | Source pack |
|---|---|
| A canonical document (a mentor plan, spec, ADR, README) | its path — each combo agent `Read`s it directly |
| Repo code / a subsystem | the real file paths (from prior research or a quick Glob/Grep); when the area is broad or unfamiliar, dispatch **one read-only `Explore` agent** first and write its FINDINGS + `file:line` EVIDENCE to `${zoom_dir}/_brief.md` |
| Conversation-only subject (no file exists) | the main thread writes `${zoom_dir}/_brief.md` distilling the conversation — the one main-thread write this skill permits, and it is a brief, never a zoom |

Every combo prompt carries the hard rule: **invent nothing** — every claim,
color, code path, and step in a zoom traces to a real file from the source pack
or to `_brief.md`.

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
   options per question).

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

Issue one `Agent` call per combo (`subagent_type: general-purpose`,
`model: sonnet`, `effort: high`), ALL combos in one message — even a single
combo is dispatched, keeping one contract and keeping HTML out of the main
context. Each agent's prompt carries: the source pack (Step 1), its topic, its
perspective row from the catalog above, the output path
`${zoom_dir}/<topic>-<perspective>.html`, the spec below, the invent-nothing
rule, and the delivery prohibition: *"Do NOT call the `Artifact` tool and do NOT
return any hosted URL. Return ONLY the file path + a `Self-check:` line —
sections rendered, diagram count, tags balanced, spec constraints met — never
the HTML body."* Perspective-conditional inputs: **Reviewer/Architect** combos
also get the resolved constitution path (Step 0) when that file exists; a
**UI-surface topic** gets the mockup contract inputs from
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
read each agent's `Self-check:` line (do not re-derive ad-hoc grep probes);
report any missing combo file and re-dispatch it once before giving up. Zoom
dispatches follow `dispatch-agents`' "Async runtime & lifecycle" rules — close
out finished combo agents after this check.

## Step 5 — Re-zoom on revision (completeness-checked, not memory-driven)

When a revision of the subject — a plan edit, a product decision, a code change
— invalidates prior zooms, `grep -l` the invalidated term across every existing
`${zoom_dir}/*.html` and re-dispatch EVERY matching combo in one batched
message — never just the combo you remember changing. When the subject is a
plan under review, wait for these agents to complete before any `plan-review`
dispatch, so a reviewer never reads a zoom mid-write.

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
