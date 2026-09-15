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
  self-contained HTML file to .mentor/zooms/[subject-slug]/ — auto-opened
  locally, never hosted, with no reviewer interaction.
  Distinct from /mentor:tour (an editable local acceptance set where
  reviewers mark pass/not-pass and leave feedback) and from /plan-review
  (a quality verdict on a written plan, not an HTML page).
---

# Zoom — Topic × Perspective HTML Review Pages

## Host portability

Use a structured question UI when the host offers one; otherwise ask the same focused question directly and wait for the answer. If delegated agents are unavailable or prohibited, perform the required research, review, or implementation serially and retain the same evidence, scope, and verification contract. Treat Mentor helpers as optional host integrations: resolve them with `PLUGIN_ROOT` first, then `CLAUDE_PLUGIN_ROOT`; if neither is available, work from the repository's durable `.mentor/` artifacts and report any state action that cannot be performed safely. This rule overrides later host-specific tool names, preserving user choice and plan continuity across hosts.

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
Run the Selection gate (skipping questions the ask already answers) and generate via
delegated workers when available, or serially in the main thread otherwise. Keep every
file's scope and self-check contract unchanged in either mode. And
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
  feedback** — that is `/mentor:tour` (a local editable acceptance set). A zoom is
  local, read-only, and has no reviewer interaction.
- The user wants a **quality verdict on a written plan** — that is `/plan-review`
  (staged reviewers folding edits into the `.md`), not an HTML rendering.
- The user wants the plan/doc itself authored or revised — zooms visualize
  content that already exists; they never replace it.

## Step 0 — State dir, subject, and slug

Derive the project-scoped mentor state dir. When available, `plan-state.sh dir` owns
worktree and non-repository resolution through the portable state home; never hardcode
a host configuration directory:

```bash
plugin_root="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"
if [ -n "$plugin_root" ] && [ -x "$plugin_root/hooks/plan-state.sh" ]; then
  state_dir="$(bash "$plugin_root/hooks/plan-state.sh" dir)"
else
  state_dir="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.mentor"
fi
ls -t "$state_dir"/plans/*/plan.md 2>/dev/null | head -3   # candidate plan subjects (newest first)
if [ -n "$plugin_root" ] && [ -x "$plugin_root/hooks/plan-state.sh" ]; then
  sibling_wts="$(bash "$plugin_root/hooks/plan-state.sh" gate --verbose | sed -n 's/^elsewhere=\([^ ]*\).*/\1/p')"
  [ -n "$sibling_wts" ] && bash "$plugin_root/hooks/plan-state.sh" list --owners
fi
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

## Step 1 — Source pack (resolve inputs before generation)

Delegated combo workers must not fan out further (`dispatch-agents`, "no nested
fan-out"), so everything they need to read must be resolved first. The main-thread
fallback follows the same source pack:

| Subject kind | Source pack |
|---|---|
| A canonical document (a mentor plan, spec, ADR, README) | its path — each combo agent `Read`s it directly |
| Repo code / a subsystem | the real file paths (from prior research or a quick Glob/Grep); when the area is broad or unfamiliar, use one read-only research worker when available, otherwise perform the same focused survey, then write FINDINGS + `file:line` EVIDENCE to `${zoom_dir}/_brief.md` |
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
2. Ask one structured multi-select question when supported, or the equivalent direct
   question otherwise — **Topics** (the derived candidates) and **Perspective** (catalog below).
   Skip a question
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

## Step 3 — Generation — one worker per combo

When helpers are available, run the pre-dispatch policy check before the first worker:

```bash
plugin_root="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"
[ -n "$plugin_root" ] && [ -x "$plugin_root/hooks/plan-state.sh" ] && \
  bash "$plugin_root/hooks/plan-state.sh" policy
```

Follow the printed guidance when it exists. Without the helper, honor any live user
restriction on delegation and use the serial fallback rather than blocking.

Step 1's "no nested fan-out" reaches a combo agent only through that injected block, which
is why `CONTRACT: MISSING` matters here even though nothing else in this skill dispatches.
The block's durable-copy clause is for verdict-producing agents (reviewers, verifiers) — a
combo's durable artifact is the HTML file it already writes, and nothing here writes under
`plans/`.

Issue one worker per combo and run all independent combos together when the host supports
parallel delegation. If it does not, write the same files serially in the main thread.
Each worker or serial pass carries: the source pack (Step 1), its topic, its
perspective row from the catalog above, the output path
`${zoom_dir}/<topic>-<perspective>.html`, the spec below, the invent-nothing
rule, and the delivery prohibition: *"Do not publish or return a hosted URL. Return
only the file path + a `Self-check:` line in named
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
in each combo's prompt; a **UI-surface topic** gets the mockup contract from
`references/ui-mockup-contract.md` — read it whenever the combo's perspective needs
to *see* the surface to do its job, and fold its inputs into that combo's prompt.

Per-file spec: a single self-contained file — inline CSS, no build step;
Mermaid via CDN
(`https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js` +
`<pre class="mermaid">`) is allowed; content for the **assigned topic through
the assigned perspective only**, never the whole subject; readable — body text
≥15px-equivalent, WCAG-AA contrast, monospace for code; authored in a
single complete write (no skeleton-then-edit). The path is inside the
gate-exempt `.mentor/` tree, so any armed plan gate allows the write. A host may
auto-open each file, but opening is optional. Stable names — a re-zoom of the same
combo overwrites in place. Zooms whose content is primarily visual (mockups,
diagrams) SHOULD ship lightweight pan/zoom affordances on the outer page
(fullscreen toggle ⛶, overlay scrim, +/−/reset, wheel-zoom — inline JS in the
outer file only; iframe `srcdoc` panes stay no-JS per
`references/ui-mockup-contract.md`).

## Step 4 — Completion check

After each worker or serial pass completes, compare `ls "$zoom_dir"` against the expected combo files and
confirm each file's structural bookends yourself — first bytes match `<!doctype`
or `<html` case-insensitively, last non-whitespace is `</html>`, size non-zero —
as one Bash loop over the dir emitting one `OK`/`BAD` line per file. Read each
agent's `Self-check:` line for everything else. Those bookends are the **only**
re-derivation worth running: they cost no context and catch the truncated page
that an agent dying mid-`Write` still self-reports as balanced, whereas
re-grepping a zoom's *content* to re-verify what the `Self-check:` already
reports just drags HTML into the main thread.

A missing file, a structurally invalid one, and a `Self-check:` missing a
required field all take the same path — rerun that combo once, naming the defect,
before giving up. Delegated work follows the host's normal lifecycle; serial work
needs no worker cleanup. In either case, do not report a batch complete until each
expected file has passed the structural check.

## Step 5 — Re-zoom on revision (completeness-checked, not memory-driven)

When a revision of the subject — a plan edit, a product decision, a code change
— invalidates prior zooms, `grep -l` the invalidated term across every existing
`${zoom_dir}/*.html` and re-dispatch EVERY matching combo in one batched
message when workers are available, or regenerate them serially — never just the combo
you remember changing. **Do not report the re-zoom complete until every regenerated combo
is complete** — a half-written zooms dir
read by anyone else (a reviewer, the user) shows stale panes next to fresh ones with
nothing marking which is which.

Each regeneration brief names the superseded term and the term replacing it, and
requires the returned `Self-check:` to add `residual-<old>=N` — one short reason
per remaining hit — plus `new-term-present=yes`. Then compare: `grep -c` the old
term per regenerated file against the declared count, and re-dispatch once on a
mismatch, or on a hit with no stated reason. The worker that wrote the file
or the serial author already knows which occurrences are deliberate before/after content, so recording
them keeps that judgment where the evidence is — and keeps
acceptance identical on the first regeneration and the third, instead of
drifting with how thorough the orchestrator feels late in a session.

## Done when

- Every selected combo has its `${zoom_dir}/<topic>-<perspective>.html` on disk
  with a consumed `Self-check:` line (one rerun attempted for any missing combo),
  and delegated workers are closed out when the host provides lifecycle controls.
- The selection gate ran (or was skipped because the ask named both dimensions),
  and no zoom covers more than its one topic × perspective.
- Nothing was published: no hosted URL — only local files, which a host may open.

### Do NOT

- Do **not** return a hosted URL or publish a zoom in any form — zooms are local-only;
  the editable review surface is `/mentor:tour`.
- Do **not** write a zoom (or anything else) into the repo source tree, `plans/`,
  or `tours/` — zoom output lives only under `.mentor/zooms/<subject-slug>/`
  (the plan resolution helpers glob `plans/*/plan.md` and must never see zoom
  files).
- Do **not** skip the per-combo generation contract. Use delegated workers when
  available, or author the complete scoped HTML serially in the main-thread fallback;
  `_brief.md` remains the only non-HTML output under `zooms/`.
- Do **not** edit the subject — the plan, doc, or source files are read-only
  inputs here; folding changes into a plan is `plan`/`plan-review` territory.
- Do **not** render the whole subject as one file — one topic × perspective per
  file, always through the Selection gate.
