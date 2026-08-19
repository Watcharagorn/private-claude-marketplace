---
name: plan-touring
description: |
  Paged storytelling walkthrough of a mentor PLAN — a local, self-contained HTML tour
  of how the plan will execute (opening context → one page per implementation step →
  done criteria + risks), with ONE diagram that evolves from current to target state as
  pages advance, plus per-page notes copied back as a Markdown report. Use whenever
  someone wants to SEE or WALK a plan before approving it, even without the word
  "tour": `/plan-tour`, `/mentor:plan-tour`, "tour this plan", "walk me through how
  this plan will execute", "show me the plan step by step", "narrate this plan as an
  architect". Resolves the plan (argument slug, else newest), asks area × perspective
  ONCE (free-form perspective), then dispatches one agent per combo writing one file
  under .mentor/plans/PLAN-SLUG/tour/ — auto-opened locally, NEVER published. Distinct
  from /mentor:tour (a PUBLISHED acceptance page marking pass/not-pass on DELIVERED
  work) and /mentor:zoom (static single-view pages of any subject, no paging or notes).
---

# Plan Tour — Paged Storytelling Walkthrough of a Plan

Generate (and regenerate) a **plan tour**: one self-contained HTML file that tells the
story of how a plan will execute, page by page, through one **area × perspective**
lens. A single inline SVG diagram persists across the whole tour and *evolves* — the
current state on page one, the target state on the last — while narrative text with
highlighted key phrases sits beside it and the reader leaves per-page notes they copy
out as a self-identifying Markdown report.

A plan tour is a **pre-approval comprehension surface**. The plan `.md` stays the
source of truth: no sync contract, no finalize step, and never a hosted copy.

**Sticky re-entry rule.** EVERY plan-tour ask re-enters this contract — the first one,
the Nth one, a free-text follow-up ("re-tour this after the revision", "add a QA
tour"), at any point in any workflow. Run the selection gate (skipping dimensions the
ask already answers) and generate via dispatched agents. Never hand-author a tour file
in the main thread: the page is a few hundred lines of HTML/CSS/JS and writing it
inline burns the context the orchestration still needs. Re-tours reuse the stable
filename and overwrite in place.

## When to use

- The user wants to understand or review **how a plan will execute** before approving
  it — `/mentor:plan-tour`, or the matching natural language.
- `planning` Step 5 delegates here when the user opts into a walkthrough of the plan
  being written.
- A plan changed and its existing tour is stale.

## When NOT to use

- **No plan exists.** Step 0 refuses; there is nothing to page through.
- The user wants a **shareable page where reviewers mark pass/not-pass on work already
  built** — that is `/mentor:tour` (published via the Artifact tool). See
  *Distinctions* below before you decide the two overlap; they do not.
- The user wants a **static view of one slice** of any subject — a subsystem, an ADR,
  a design — with no paging and no story arc: that is `/mentor:zoom`.
- The user wants a **quality verdict** on the plan (is it any good? what's missing?) —
  that is `/plan-review`, which folds edits into the `.md`.
- The user wants the plan itself authored or revised — a tour visualizes a plan that
  already exists; it never replaces or edits one.

## Step 0 — Resolve the plan subject

```bash
state_dir="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" dir)"   # worktree-safe; _no-repo fallback
[ -n "$state_dir" ] || { echo "ERROR: mentor state dir unresolved — is CLAUDE_PLUGIN_ROOT set? do not search the plugin cache or hardcode a version path; ask the user to /reload-plugins or restart" >&2; exit 1; }
ls -t "$state_dir"/plans/*/plan.md 2>/dev/null | head -5              # candidate plans, newest first
sibling_wts="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" gate --verbose | sed -n 's/^elsewhere=\([^ ]*\).*/\1/p')"
[ -n "$sibling_wts" ] && bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" list --owners   # cross-check OWNER col below
```

Resolve in priority order:

1. **The argument.** Read it as a plan-slug substring first; any token that matches a
   plan dir name resolves the plan, and whatever text is left over is the area and/or
   perspective (`/mentor:plan-tour payments system architect`).
2. **The newest plan** from the listing — but when `$sibling_wts` is non-empty
   (`ARMED_ELSEWHERE`), first drop any candidate whose OWNER column (from `list --owners`
   above) matches one of those wt-ids: a sibling's live marker means that plan is
   mid-write, not this tour's subject. If the filter empties the listing or leaves the
   pick ambiguous, ask the user for an explicit subject instead of guessing. **Note:** the
   newest plan in the raw listing may be the sibling's — name the plan you picked.
3. **Nothing.** No `plans/*/plan.md` anywhere → print exactly one line and stop:

   ```
   Plan tour needs a plan — this repo has none yet. Run /mentor:plan first, then ask for the tour.
   ```

There is **no conversation-subject fallback** here, and that is the one place this
skill deliberately diverges from `zooming`: a tour's page unit *is* the plan's
implementation steps, so without a plan file there is no arc to page through. A visual
of something that is not a plan is `/mentor:zoom`.

When a substring matches **several** plans, apply the same sibling-owned exclusion as
step 2 above, then take the newest remaining match and say which one you took in one
line. Do not spend a question on disambiguation — the selection gate below is the
single question this skill is allowed, and a wrong guess costs one re-run against a
stable filename.

Then read `plan.md` in full (you need it for Step 1 anyway) and hold its path.

**No planning-session guard.** `.mentor/` is exempt from the plan edit gate, so a plan
tour is legal while this worktree's gate reads `ARMED` — which is the common case, since
the whole point is reviewing a plan *before* approval. This skill's combo agents write only
tour artifacts under `.mentor/plans/*/tour/`, never repo source files.

## Step 1 — Selection gate (exactly one question)

Derive candidates from the plan you just read:

- **Areas** — up to 4: always offer **Whole plan** (the default arc), then the plan's
  `## Approach` subsections and/or its implementation-step groupings (e.g. "the
  parallel authoring steps" vs "the review and gate steps"). Areas come from the plan's
  own structure, not from invented categories.
- **Perspectives** — suggest **System architect**, **Developer**, **QA**, and say in
  the question text that any other lens is welcome. Free-form is the point: a plan may
  need a security reviewer, an SRE, a product owner, a support lead.

Ask **ONE** `AskUserQuestion` call carrying up to two multi-select questions — Area and
Perspective — and **skip any dimension the invocation already named** ("tour this plan
as a system architect" skips Perspective; naming both skips the gate entirely). When
only one area is derivable, treat it as resolved and ask Perspective alone
(AskUserQuestion needs 2–4 options per question). **Every question stands on its own:**
the user answers from the question screen alone — never sent to a file, a plan section, a
coined id or code, or an earlier turn to learn what the question means. An area option
names the work it covers in plain language, never the plan heading or step number it was
derived from.

Combos = selected areas × selected perspectives. Kebab-sanitize both halves for the
filename and uniquify colliding area slugs (`-2`, `-3`, …) so no two combos share a
path. **Above 4 combos, confirm the count first** — each tour is a multi-page authored
artifact, not a one-screen page, and every finished file auto-opens a browser tab
(`MENTOR_PLAN_OPEN=off` is the escape hatch).

### Shaping the arc to an arbitrary perspective

The perspective decides what each page *says*, not just its tone. Pass the matching row
to the combo agent; for a lens not in this table, derive its row the same way — name the
one decision this reader makes after the tour, then make every page serve it.

| Perspective | Cares about, page to page | Narrative highlights | Diagram emphasizes |
|---|---|---|---|
| System architect | Where boundaries move, what becomes coupled, which decisions are hard to reverse | Contracts, seams, data ownership, irreversible choices | Containers and the edges between them; new components arrive green, retiring ones ghost out |
| Developer | What to touch, in what order, what blocks what | Real file paths, module/function names, step order and dependencies | File- and module-level nodes; the current step's nodes go active, finished steps stay on |
| QA / tester | What can break, what is observable, what proves a step landed | Verification commands, expected states, edge cases, failure paths | Verification surfaces and the route a failure takes; unexercised areas stay dim |
| Anything else | Derive from the role: what does this reader own, and what would make them say "no"? | The artifacts that role actually reads | The parts of the system that role is accountable for |

**A perspective changes the reader, never the subject.** Every lens — architect
included — pages through *this plan's* steps; the system appears only where the plan
moves it, which is what the current-state → target-state diagram is for. Carry that into
the Perspective question text in one clause ("…as a reader of this plan's steps"), and
when the ask itself sounds like a request to see the system as it stands today ("tour the
system architecture", "review the data flow"), name the choice in one line before
dispatching: this tours the plan; `/mentor:zoom` renders the system itself.

## Step 2 — The page contract (the spec every combo agent must honor)

This is the payload, not a checklist for the main thread — copy it into each combo
prompt as-is. It is locked: it was confirmed against a working example page, and a
combo agent that improvises its own layout produces a file that no longer matches its
siblings.

```
┌────────────────────────────────────────────────────────────────┐
│ header: title · "area × perspective" · progress dots · n/N     │
├──────────────────────────────┬─────────────────────────────────┤
│ FIXED PANE 1 (~60%)          │ FIXED PANE 2 (right column)     │
│ one persistent inline SVG    │ kicker (step tag) · page title  │
│ diagram, full height         │ narrative w/ highlighted marks  │
│                              │ collapsible per-page note box   │
│                              ├─────────────────────────────────┤
│                              │ [◀ Back] [Next ▶]  ⧉ Copy notes │
└──────────────────────────────┴─────────────────────────────────┘
```

**Page unit.** Opening context page (where things stand today, and why the plan
exists) → **one page per implementation step or phase** → closing page (done criteria
+ risks). Every page carries a `step` reference — that string is what the kicker shows
and what the exported report cites, so a pasted-back note is traceable to a step
without asking.

**The evolving diagram.** One inline SVG for the whole tour. Every node and edge
carries a `data-` id, and each page declares a state map over those ids:

| State | Means | Rendered as |
|---|---|---|
| `hidden` | Not yet part of the story | Invisible but still laid out |
| `dim` | Present, not this page's subject | Muted, low contrast |
| `on` | Established and in play | Normal |
| `active` | What this page is about | Amber + highlight pulse |
| `ghost` | Retiring or being removed | Dashed stroke, muted |

Apply states by **toggling CSS classes only — never DOM replacement**. Rebuilding the
SVG per page destroys element identity, kills CSS transitions, and makes the diagram
flicker into a new picture instead of growing into one; continuity across pages is the
whole reason this artifact exists.

```js
function render(i) {
  const page = TOUR.pages[i];
  document.querySelectorAll('[data-id]').forEach(el => {
    const s = page.states[el.dataset.id] || 'hidden';
    el.classList.remove('is-hidden', 'is-dim', 'is-on', 'is-active', 'is-ghost');
    el.classList.add('is-' + s);
  });
  // …kicker, title, narrative, note box, dots, n/N
}
```

An id the page does not name resolves to `hidden`, so the picture is a pure function of
the page index rather than a residue of the path taken — that is what makes going
**back** reverse the story exactly. Use the plugin's diff colour language for what the
plan changes: **NEW = green, active/changed = amber, retiring = ghosted dashes**, with
a compact inline legend so the colours decode without session context. Keep `hidden`
non-reflowing (opacity/visibility, not `display:none`) so the layout never jumps
between pages, and wrap the pulse in `prefers-reduced-motion`.

**Navigation.** ←/→ hotkeys, Back/Next buttons (disabled at the ends), and clickable
progress dots in the header with an extra note-marker on any page that has a note
(recomputed live as the reader types). Hotkeys must be **suppressed while typing in the
note box** — guard on `e.target.closest('textarea, input, [contenteditable]')` — or an
arrow key mid-sentence pages the tour away and the half-written note looks lost.

**Notes & export.** A per-page textarea, all pages persisted under one key:

```
localStorage["mentor-plan-tour:<plan-slug>:<area>-<perspective>"] = JSON of { pageId: noteText }
```

Namespacing by combo keeps two tours of the same plan from colliding. Restore on load;
save on input (debounced) and on page change.

The **⧉ Copy notes (MD)** button copies this exact shape — noted pages only:

```markdown
# Plan tour notes — payment-service-extraction
**Area:** whole plan · **Perspective:** system architect · **Pages noted:** 2 of 7

## Page 3/7 — Step 2: Extract the payment client
<the reviewer's note, verbatim>

## Page 5/7 — Step 4: Cut over the order service
<the reviewer's note, verbatim>
```

The header names plan slug, area, perspective, and page count so a pasted-back report
identifies itself with no session context — that round trip is the entire feedback loop.

Copy via `navigator.clipboard.writeText`, **and ship the fallback**: on a missing API or
a rejected promise, drop a hidden textarea, `select()`, `document.execCommand('copy')`,
remove it. Show a visible **Copied ✓** state for ~1.5s either way, and if both paths
fail, reveal the textarea with "Copy failed — select and copy the text below" so the
reader's notes are never trapped in the page. `file://` pages routinely have no
`navigator.clipboard` (it needs a secure context), and a copy button that silently does
nothing is the named pitfall for this artifact. **No file downloads** — paste-back is
the loop.

**Self-contained.** One HTML file: inline CSS, inline JS, inline SVG, zero external
requests — no CDN, no web fonts, **no Mermaid runtime**. Mermaid is disqualified twice
over: it is a network fetch, and it regenerates its own DOM, which would wipe the
stable `data-` ids the state machine depends on. Body text ≥15px-equivalent, WCAG-AA
contrast, monospace for code. Responsive: two panes above ~800px, stacking to
diagram-on-top / narrative-below beneath it.

**Design pass — discovered at runtime, never hardcoded.** Read the most recent
active-skills system-reminder and use the strongest design/UX skill present; otherwise
use the built-in `artifact-design`. If neither is listed, degrade gracefully with the
one-line notice `Design pass: skipped — no design skill in session.` Hardcoding a
design plugin as a dependency breaks the skill on every machine that lacks it.

## Step 3 — Dispatch, one agent per combo

Create the output dir first — its variables do not survive from Step 0, and an unset
`$state_dir` would write the tour to `/plans` at the filesystem root:

```bash
state_dir="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" dir)"
[ -n "$state_dir" ] || { echo "ERROR: mentor state dir unresolved — is CLAUDE_PLUGIN_ROOT set? do not search the plugin cache or hardcode a version path; ask the user to /reload-plugins or restart" >&2; exit 1; }
tour_dir="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" ensure-dir "$state_dir/plans/<plan-slug>/tour")" || exit 1
```

`ensure-dir` also locks the path to 700, which is what a local-only artifact wants.

**Run the pre-dispatch preflight before the first `Agent` call, not after.** One call,
no skill load:

```bash
[ -d "${CLAUDE_PLUGIN_ROOT}/hooks" ] || { echo "ERROR: CLAUDE_PLUGIN_ROOT unresolved or stale — do not search the plugin cache or hardcode a version path; ask the user to /reload-plugins or restart" >&2; exit 1; }
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" policy
```

`POLICY: SET (dispatch=…)` — the user already recorded where work runs in this repo;
honor it and ask nothing. `FOUND` — a standing no-subagents instruction is on record; ask
ONCE and record the answer, per `dispatch-agents`' **Standing no-subagents policy** (the
recording is what stops every later surface re-asking). `UNRESOLVED` — the check could not
run, which is not a clean result; treat the question as open. `NONE` — dispatch. `CONTRACT: active` confirms
`hooks/dispatch-contract.sh` appends the standing "Deliver before idling" block to every
dispatch prompt automatically: **do not paste it by hand.** Only on `CONTRACT: MISSING`
do you paste it yourself, from `dispatch-agents`' own section of that name.

Without that block a combo can finish its file and still end its turn on a plain
final-text reply, indistinguishable from a hang until someone notices and sends a manual
nudge — which is what `CONTRACT:` exists to warn about. The block governs *delivery*, not
contents: "Return ONLY the file path plus one line" below still says what to deliver, and
the block's durable-copy clause is for verdict-producing agents — a combo's durable
artifact is the HTML file it already writes, so it still writes nothing outside
`<tour_dir>`.

Then issue one `Agent` call per combo (`subagent_type: general-purpose`,
`model: sonnet`, `effort: high`), **ALL combos in one message** — a single combo is
dispatched too, keeping one contract and keeping the HTML out of the main context.

```
Write the plan tour for area "<area>" through the "<perspective>" perspective.

SOURCE PACK — your first action is to Read this file in full; it is the entire
source pack and you do not research the repo:
  <absolute path to plan.md>

PERSPECTIVE BRIEF: <the row from "Shaping the arc", verbatim>
AREA SCOPE: <what this area covers, and what it deliberately leaves to sibling tours>

OUTPUT (exactly one file): <tour_dir>/<area>-<perspective>.html

<the full Step 2 page contract, verbatim>

INVENT NOTHING — every page, node, edge, claim, and step reference traces to the
plan text. Where the plan is silent, say so on the page rather than filling it in.

SINGLE WRITE — author the complete file in ONE `Write` call. No skeleton-then-Edit:
plan-open.sh opens the file on first Write, and the reader must never land on a
half-built page.

DO NOT call the `Artifact` tool and DO NOT return any hosted URL — plan tours are
local files. Return ONLY the file path plus one line:
  Self-check: <N> pages rendered · diagram states declared for all <M> data-ids on
  every page · ←/→ hotkeys wired and suppressed in the note box · clipboard fallback
  present · tags balanced
Never return the HTML body.
```

## Step 4 — Completion check

```bash
# Re-derive: Step 3's block was a separate Bash call and its variables are gone.
state_dir="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" dir)"
[ -n "$state_dir" ] || { echo "ERROR: mentor state dir unresolved — is CLAUDE_PLUGIN_ROOT set? do not search the plugin cache or hardcode a version path; ask the user to /reload-plugins or restart" >&2; exit 1; }
ls -l "$state_dir/plans/<plan-slug>/tour"
```

Compare against the expected combo filenames and read each agent's `Self-check:` line —
consume what the agents reported rather than re-deriving it with ad-hoc greps. Report
any missing or incomplete combo and **re-dispatch it once** before giving up. Follow
`dispatch-agents`' "Async runtime & lifecycle" rules: close out finished combo agents
after this check.

Then print each file's path. Auto-open fires **once per file** (a `.opened` sidecar
marker), so a re-tour of an existing combo will not pop a new tab — the same behavior
re-zooms have. Say so alongside the path when the file already existed, so the user
knows to reopen it themselves rather than waiting for a tab that is not coming.

## Distinctions and the path rationale (read before "fixing" either)

**A plan tour is not an acceptance tour.** `/mentor:tour` publishes via the Artifact
tool, captures pass/not-pass verdicts, and reviews **delivered** work. A plan tour is
local-only, captures free-text notes, and previews **future** work. The two contracts
are mutually exclusive by design: do not add pass/not-pass toggles or a Download JSON
button here, do not publish this page, and do not route an acceptance ask into this
skill. Nothing about acceptance touring changes because this skill exists.

**The nested path is deliberate.** `touring/SKILL.md` states that `tours/` is a sibling
of `plans/`, never inside it, and zooms migrated out of `plans/<slug>/zoom/` in v2.12 —
yet plan tours live at `.mentor/plans/<plan-slug>/tour/` anyway, for four reasons:

- their subject is **always a plan**, so the zoom migration's driver (any-subject slugs
  that do not correspond to a plan dir) does not apply;
- `handoffs/` already establishes the per-plan-subdir precedent;
- plan-resolution helpers glob `plans/*/plan.md`, which a `tour/` subdir cannot match,
  so nothing that enumerates plans can see these files;
- plan dirs are chmod-700, which suits a local-only artifact — the sibling rule exists
  to protect *shared, published* tours, and these are neither.

This is not a bug and not drift. Leave both rules standing as written.

## Done when

- Every selected combo has its `<tour_dir>/<area>-<perspective>.html` on disk with a
  consumed `Self-check:` line (one re-dispatch attempted for any missing combo), and
  finished combo agents are closed out.
- The selection gate ran as exactly one `AskUserQuestion` — or was skipped because the
  ask already named both dimensions.
- Every page of every file honors the Step 2 contract: the page unit, class-toggled
  diagram states, working ←/→ with the typing guard, notes persisted under the
  namespaced key, and a clipboard copy with its fallback.
- Nothing was published: no `Artifact` call, no hosted URL — only local files that
  plan-open.sh auto-opened.
- The plan `.md` is byte-identical to before the tour ran.

### Do NOT

- Do **not** call the `Artifact` tool, return a hosted URL, or publish a plan tour in
  any form — the published review surface is `/mentor:tour`, for delivered work.
- Do **not** add pass/not-pass marks or file downloads — a plan tour captures free-text
  notes that travel back by clipboard, and blurring the two surfaces is how the next
  reader stops being able to tell which one they are looking at.
- Do **not** write anywhere but `.mentor/plans/<plan-slug>/tour/` — never into
  `tours/`, never into `zooms/`, never into the repo source tree.
- Do **not** hand-author or hand-edit tour HTML in the main thread; generation is
  always dispatched.
- Do **not** edit the plan — it is a read-only input here. Folding pasted-back notes
  into it is `/mentor:plan` or `/plan-review` territory.
- Do **not** rebuild the SVG per page, fetch anything external, or ship a copy button
  without its `execCommand` fallback — each one silently breaks a property the reader
  is relying on.
