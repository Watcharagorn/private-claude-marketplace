---
name: touring
description: |
  Create an editable post-approval guided review set for a feature or plan.
  Triggered by tour, walkthrough, UAT, acceptance review, or pass/not-pass
  feedback requests. Builds a self-contained HTML page plus Markdown and JSON
  deliverables under `.mentor/tours/`, with scenario cards, checklists,
  reviewer marks, feedback, and report export. The subject may be a plan or
  standalone topic. Claude Artifact hosting is optional after local delivery.
  Distinct from zoom: tours are editable acceptance reviews, never dependent on
  a hosted URL.
---

# Tour — Editable Guided-Review Artifact

## Host portability

Use a structured question UI when the host offers one; otherwise ask the same focused question directly and wait for the answer. If delegated agents are unavailable or prohibited, perform the required research, review, or implementation serially and retain the same evidence, scope, and verification contract. Treat Mentor helpers as optional host integrations: resolve them with `PLUGIN_ROOT` first, then `CLAUDE_PLUGIN_ROOT`; if neither is available, work from the repository's durable `.mentor/` artifacts and report any state action that cannot be performed safely. This rule overrides later host-specific tool names, preserving user choice and plan continuity across hosts.

Generate (and iterate) an **editable local review set**: a guided tour of a system's scenarios that
a reviewer walks hands-on, marking each scenario **pass / not-pass** with feedback. Always write a
self-contained HTML page plus companion Markdown and JSON files; their shared local path is the
portable deliverable. A host may additionally publish the HTML. The tour is a **post-approval
deliverable** — it is not the plan, not a zoom, and never lives in `plans/`.

## When to use

- The user asks for an editable / interactive review artifact, a guided tour or walkthrough page, an
  acceptance (UAT-style) review page, or "a page where reviewers can mark pass/not-pass and leave
  feedback".
- After implementation, to hand a reviewer (end-user or developer) a hands-on checklist of every
  scenario the work introduced.

## When NOT to use

- The user wants the **plan content** reviewed — that is `/plan-review` (the two-stage 4-topic
  pre-approval review) or `/mentor:grill` (decision interview), not a tour.
- The user wants a **read-only visual view of a subject** (a plan topic, a subsystem, a design) —
  that is the `zoom` skill (`.mentor/zooms/<slug>/`, local-open only, explicitly never published,
  no marks to record). A tour is different: an editable acceptance page with local review exports.
- The subject has no walkable behavior (pure docs/config with nothing to exercise).

---

## Step 0 — Guard, state dir, and subject resolution

Derive the project-scoped mentor state dir and check the planning gate. When available,
`plan-state.sh dir` owns both worktree and non-repository resolution, including the portable state
home; never hardcode a host configuration directory:

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
```

- **Resolve the subject**, in priority order:
  1. the **argument** — a topic ("secret rotation flow") or a plan-slug substring for multi-plan repos;
  2. the **newest plan** from the listing above (the default when one exists) — but when
     `$sibling_wts` is non-empty (`ARMED_ELSEWHERE`), first drop any candidate whose OWNER column
     (from `list --owners` above) matches one of those wt-ids: a sibling's live marker means that
     plan is mid-write, not this tour's subject. If the filter empties the candidate list or leaves
     the pick ambiguous, ask the user for an explicit subject instead of guessing;
  3. the feature/system under discussion in the **current conversation**.
  The plan is an *input source*, never a prerequisite — the skill works standalone.
  **Note:** the newest plan in that raw `ls -t` listing may be the sibling's — name the plan you
  picked.
- Derive the tour **slug** from the subject (kebab-case, stable across re-runs so revisions hit the
  same file → same URL).

## Step 1 — Audience gate (one question, skippable)

If the argument already names the audience (`user` | `dev` | `both`), skip this step. Otherwise ask
**one structured-or-direct question** (single-select when supported, header "Audience") — **every question stands on its own**,
answered from the question screen alone, never sending the user to a file, a plan section, a coined
id or code, or an earlier turn to learn what it means:

1. **End-user walkthrough** — plain-language scenarios, UI/CLI steps, no internals.
2. **Technical deep-dive** — every workflow variant and condition, exact commands/YAML, internals.
3. **Both** — two artifacts sharing one scenario manifest, each fitted to its audience.

## Step 2 — Scenario inventory (one bounded research pass)

Dispatch **one read-only research agent** when the host supports delegation; otherwise perform the
same bounded survey in the main thread. The result must meet the **SCENARIO MANIFEST** contract —
structured, machine-usable, **no prose padding and no word cap on the manifest itself** (a card list
cannot fit a 400-word summary contract without truncating coverage):

- Per card: `id` · `section` (lettered group) · `title` · `goal` · `steps` (numbered, reviewer-
  executable) · `commands` (exact copy-paste commands / YAML snippets, verified against real files)
  · `expected` (observable checks) · `variants` (which mode/trigger/error-path this card covers)
  · `evidence` (`file:line` refs).
- **Variant coverage is mandatory**: enumerate the subject's modes, task types, triggers, and error
  paths (e.g. sync/async, scaling, dependencies, HTTP, failure handling) so each is walkable — not
  just the happy-path contract.
- Plus **OPEN QUESTIONS** (anything unverifiable). No raw file dumps beyond the per-card snippets.

The main thread holds only this manifest — it does not re-read the repo (the same orchestrator
contract `dispatch-agents` enforces for implementation). A delegated pass also follows the
`dispatch-agents` **"Async runtime & lifecycle"** rules: the prompt requires delivery before idling,
idle-with-no-manifest gets one nudge, and the agent is stopped/released once the manifest is consumed.

## Step 3 — Coverage cross-check (before any rendering)

Map every subject feature and **variant** to ≥1 card. Print a short gap table
(`feature/variant → covered by | GAP`). Fill gaps (one follow-up dispatch or a targeted addition) or
explicitly acknowledge them to the user **before** rendering. Never render a knowingly gapped tour
silently.

## Step 4 — Render (the main thread authors the HTML)

The **main thread** writes the page (rendering is the orchestrator's own job — do not dispatch a
render agent). One self-contained HTML file **per audience**, fixed anatomy:

- **Page header** — subject, one-line purpose ("walk each scenario, mark pass/not-pass, export the
  report when done"), a "Before you start" prerequisites block (environment, where to run commands),
  and a compact legend for the hollow/✓/✗ marks. The page must be self-explanatory to a reviewer
  who opens only the URL, with no session context.
- Lettered **sections** → **scenario cards**: goal, numbered steps, copy-paste command blocks,
  expected-behavior checklist, **Pass / Not-pass** toggle pair (click again to unmark), and a
  **feedback textarea**.
- **Sticky scrollspy sidebar** listing every scenario with a live status dot (hollow = unmarked,
  filled ✓/✗ once marked); **top progress meter** (n passed / n failed / n open).
- **Completion state** — when every card is marked (open = 0), the progress meter becomes a done
  banner (`All N scenarios reviewed — X passed / Y not passed`) with an inline nudge to the export
  buttons. The reviewer must be able to tell they are DONE.
- State persisted to `localStorage` under a key namespaced per artifact
  (`mentor-tour:<slug>:<audience>`) so two tours never collide and marks survive reloads.
- **Copy report (MD)** and **Download JSON** buttons exporting all marks + feedback. Both exports
  embed a header — tour slug, audience, timestamp, pass/fail/open counts — so a pasted-back report
  is self-identifying.
- **Audience fitting** — the end-user artifact rewrites steps in plain language, showing commands
  only where the reviewer must actually run one; the dev artifact keeps exact commands/YAML,
  variants, and evidence refs.
- Fully self-contained (inline CSS/JS, no external requests), theme-aware (light/dark), and
  space-efficient by default.

**Design pass — runtime discovery, never hardcoded:** read the current host's available design/UX
capabilities and use the strongest relevant one. If none is available, degrade gracefully with the one-line notice
`Design pass: skipped — no design skill in session.`

## Step 5 — Write local deliverables; optionally publish

```bash
# Re-derive: each shell call is independent. `plan-state.sh dir` supplies the portable
# state home when available; the fallback is the current repository's durable tree.
plugin_root="${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}"
if [ -n "$plugin_root" ] && [ -x "$plugin_root/hooks/plan-state.sh" ]; then
  state_dir="$(bash "$plugin_root/hooks/plan-state.sh" dir)"
else
  state_dir="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.mentor"
fi
mkdir -p "$state_dir/tours"
tour_file="$state_dir/tours/<slug>-<audience>.html"
tour_md="$state_dir/tours/<slug>-<audience>.md"
tour_json="$state_dir/tours/<slug>-<audience>.json"
```

- Write the HTML to `tour_file`, a Markdown review/report template to `tour_md`, and the scenario
  manifest plus initial review state to `tour_json` — **`tours/` is a sibling of `plans/`, never inside `plans/`**
  (the plan resolution helpers glob `plans/*/plan.md` and must never see tour files; the
  `.mentor/.gitignore` whitelist keeps `tours/` out of git automatically).
- The HTML's export buttons may generate a reviewer-completed MD/JSON report at review time, but
  the authored companion files above must exist before delivery. Report all three local paths.
- **Claude enhancement only:** if a Claude Artifact capability is available and the user asks for
  hosting, publish the already-written HTML with a stable title and preserve its URL on revisions.
  A missing Artifact capability is not an error and never changes the local deliverable contract.
- On first delivery, explain marking semantics (hollow → ✓/✗ toggle), localStorage persistence,
  and the MD/JSON exports. On a revision, report the changed local paths; include a hosted URL only
  when one was explicitly created or updated.

## Step 6 — Revision loop + parity rule

- A revision edits the **same local files**. Keep the slug stable; when a hosted enhancement exists,
  republish its same URL too.
- **Card `id`s are immutable across revisions** — never renumber existing cards; new cards get new
  ids — so a reviewer's persisted marks never shift to the wrong card.
- **A pasted-back exported report is revision input**: treat each not-passed card's feedback as the
  change list — no parsing step, just read it.
- **Parity rule (when both audiences exist):** any structural change — navigation, section layout,
  coverage additions, theme — is applied to **both** artifacts in the same turn, or the skip is
  printed explicitly (`Not applied to the <other> tour — say the word to sync it.`). Silent drift
  between the two artifacts is a defect.
- Content-coverage revisions (new scenarios) re-run the Step 3 cross-check for the added surface.

## Do NOT

- Do **not** modify the plan file — it is a read-only input (the Step 2 dispatched agent reads
  it; the main thread does not re-read it). A tour writes only under `.mentor/tours/`, which the
  edit gate exempts, so an armed planning gate is not a reason to abort — mention it if the
  subject is a plan still being drafted, since the tour will describe a moving target.
- Do **not** write anything into `plans/` or `zooms/` (tour files live in `tours/`), and do not
  publish a plan or zoom. A tour may be hosted only as an optional enhancement after its local
  HTML, Markdown, and JSON deliverables exist.
- Do **not** dispatch a rendering agent — the main thread renders; only the scenario inventory is
  delegated.
- Do **not** hardcode a design plugin name as a dependency — discover at runtime, degrade gracefully.
- Do **not** re-explain the marking/persistence/republish mechanics after the first publish.
