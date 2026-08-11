---
name: touring
description: |
  Editable guided-tour review artifact — mentor's post-approval acceptance
  surface. Use whenever the user wants a shareable page to hands-on review,
  test, or sign off on delivered work, even if they don't say "tour":
  "editable review artifact", "guided tour / walkthrough page", "UAT or
  acceptance review", "let reviewers mark pass/not-pass and leave feedback",
  "update/revise the tour", "re-publish the review page with these fixes",
  "/tour". Builds one self-contained HTML page per audience (end-user
  walkthrough / technical deep-dive) from an agent-derived scenario manifest —
  scenario cards, checklists, pass/not-pass toggles, feedback capture, report
  export — published via the Artifact tool to a stable URL that revisions
  republish in place. Subject defaults to the newest mentor plan but works
  standalone from any topic.
  Distinct from /mentor:zoom, which renders local-only, never-published
  visual pages of any subject with no reviewer interaction — a tour is
  published on purpose and captures pass/not-pass verdicts.
---

# Tour — Editable Guided-Review Artifact

Generate (and iterate) an **editable review page**: a guided tour of a system's scenarios that a
reviewer walks hands-on, marking each scenario **pass / not-pass** with feedback, all in one
self-contained HTML artifact with a stable URL. The tour is a **post-approval deliverable** — it is
not the plan, not a zoom, and never lives in `plans/`.

## When to use

- The user asks for an editable / interactive review artifact, a guided tour or walkthrough page, an
  acceptance (UAT-style) review page, or "a page where reviewers can mark pass/not-pass and leave
  feedback".
- After implementation, to hand a reviewer (end-user or developer) a hands-on checklist of every
  scenario the work introduced.

## When NOT to use

- A mentor planning session is active (a fresh `.planning` marker) — approve or abandon the plan
  first; Step 0 enforces this.
- The user wants the **plan content** reviewed — that is `/plan-review` (the two-stage 4-topic
  pre-approval review) or `/mentor:grill` (decision interview), not a tour.
- The user wants a **read-only visual view of a subject** (a plan topic, a subsystem, a design) —
  that is the `zoom` skill (`.mentor/zooms/<slug>/`, local-open only, explicitly never published,
  no marks to record). A tour is different: an editable acceptance page, published on purpose.
- The subject has no walkable behavior (pure docs/config with nothing to exercise).

---

## Step 0 — Guard, state dir, and subject resolution

Derive the project-scoped mentor state dir and check the planning gate (same derivation as
`hooks/lib/state.sh` — never hardcode paths; not in a git repo → fall back to
`~/.claude/mentor/_no-repo`):

```bash
state_dir="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" dir)"   # worktree-safe; _no-repo fallback
[ -n "$state_dir" ] || { echo "ERROR: mentor state dir unresolved — is CLAUDE_PLUGIN_ROOT set?" >&2; exit 1; }
[ "$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" gate)" = "ARMED" ] && echo "PLANNING_ACTIVE"
ls -t "$state_dir"/plans/*/plan.md 2>/dev/null | head -3   # candidate plan subjects (newest first)
```

- **`PLANNING_ACTIVE`** → print the one-line abort and stop:
  `Tour aborted: a mentor planning session is active — approve or abandon the plan first.`
- **Resolve the subject**, in priority order:
  1. the **argument** — a topic ("secret rotation flow") or a plan-slug substring for multi-plan repos;
  2. the **newest plan** from the listing above (the default when one exists);
  3. the feature/system under discussion in the **current conversation**.
  The plan is an *input source*, never a prerequisite — the skill works standalone.
- Derive the tour **slug** from the subject (kebab-case, stable across re-runs so revisions hit the
  same file → same URL).

## Step 1 — Audience gate (one question, skippable)

If the argument already names the audience (`user` | `dev` | `both`), skip this step. Otherwise ask
**one** `AskUserQuestion` (single-select, header "Audience") — **every question stands on its own**,
answered from the question screen alone, never sending the user to a file, a plan section, a coined
id or code, or an earlier turn to learn what it means:

1. **End-user walkthrough** — plain-language scenarios, UI/CLI steps, no internals.
2. **Technical deep-dive** — every workflow variant and condition, exact commands/YAML, internals.
3. **Both** — two artifacts sharing one scenario manifest, each fitted to its audience.

## Step 2 — Scenario inventory (ONE dispatched agent)

Dispatch **one `Explore` agent** over the subject + the relevant repo paths (scripts, manifests,
docs, workflow definitions). Its prompt must require the **SCENARIO MANIFEST** return contract —
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
contract `dispatch-agents` enforces for implementation). This dispatch also follows the
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
- Fully self-contained (inline CSS/JS, no external requests — the Artifact CSP blocks them);
  theme-aware (light/dark); default visual theme: **space-efficient**.

**Design pass — runtime discovery, never hardcoded:** read the most recent active-skills
system-reminder and pick the strongest design/UX skill present (e.g. `ui-ux-pro-max` when installed);
otherwise use the built-in `artifact-design` skill (required before Artifact publishing anyway). If
neither is listed, degrade gracefully with the one-line notice
`Design pass: skipped — no design skill in session.`

## Step 5 — Publish (stable URL; mechanics note printed once)

```bash
# Re-derive: Step 1's block was a separate Bash call and its variables are gone. An unset
# $state_dir would write the tour to /tours at the filesystem root instead of the repo.
state_dir="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" dir)"   # worktree-safe
[ -n "$state_dir" ] || { echo "ERROR: mentor state dir unresolved — is CLAUDE_PLUGIN_ROOT set?" >&2; exit 1; }
mkdir -p "$state_dir/tours"   # bare on purpose: tours are meant to be shared, not 700
tour_file="$state_dir/tours/<slug>-<audience>.html"
[ -f "$tour_file" ] && echo "EXISTS"    # decides the mechanics note below
```

- Write the HTML to `tour_file` — **`tours/` is a sibling of `plans/`, never inside `plans/`**
  (the plan resolution helpers glob `plans/*/plan.md` and must never see tour files; the
  `.mentor/.gitignore` whitelist keeps `tours/` out of git automatically).
- Publish via the **Artifact tool** with a stable `<title>` and a stable favicon. Same file path →
  same URL on every republish. For a tour first published in an *earlier* session, pass the existing
  artifact URL (`action: "list"` to find it) so the link is preserved. This is the one mentor
  artifact that is *meant* to be published — unlike zoom files, which stay local.
- **Only if the file did not exist before this run**, print the mechanics note once:
  marking semantics (hollow → ✓/✗ toggle), localStorage persistence, the MD/JSON export, and the
  republish contract ("same tour → same URL; just tell me what to change"). On any revision,
  **never re-explain these** — report only what changed and the URL.

## Step 6 — Revision loop + parity rule

- A revision edits the **same file** and republishes the **same URL**. Keep the slug stable.
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

- Do **not** run while a fresh `.planning` marker is armed, and do **not** modify the plan file —
  it is a read-only input (the Step 2 dispatched agent reads it; the main thread does not re-read it).
- Do **not** write anything into `plans/` or `zooms/` (tour files live in `tours/`), and do **not**
  publish the plan or a zoom artifact via the Artifact tool — the `zoom` skill's local-only
  prohibition still stands; only the tour page is published.
- Do **not** dispatch a rendering agent — the main thread renders; only the scenario inventory is
  delegated.
- Do **not** hardcode a design plugin name as a dependency — discover at runtime, degrade gracefully.
- Do **not** re-explain the marking/persistence/republish mechanics after the first publish.
