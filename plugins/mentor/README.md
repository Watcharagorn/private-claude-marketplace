# mentor

A lean planning harness for Claude Code. One enforcement mechanism: `/mentor:plan`
arms a repo-scoped `.planning` marker, and a single fail-closed `PreToolUse` hook
blocks every repo edit — even under `bypassPermissions` — until the plan is
approved. Plans are **Mermaid-first Markdown** documents persisted in the repo's
**`.mentor/`** dir (gitignored), with required per-topic visualizations and a mandatory **Use case
scenarios** section proving the plan understood the request. They auto-open for
review and are the single source of truth for implementation, handoff, and review.

## Quick start

```
/mentor:mode plan-only        # optional: set the approval-gate default (plan | plan-only)
/mentor:grill <topic>         # optional: sharpen open design decisions before you plan
/mentor:plan <what you want to build>
```

`/mentor:plan`:

1. Runs `begin-plan.sh`, which writes the repo-scoped `.planning` marker — **arming
   the edit gate**. From here, repo source edits are blocked until approval.
2. Follows the `plan` skill: optional clarify (grilling), research
   (subagent delegation suggested for big tasks), domain routing, open-decision
   resolution (every open question or decision that needs the user is asked via
   `AskUserQuestion`, one at a time, each with evidence and a recommended
   option), then a
   Markdown plan written to `<repo>/.mentor/plans/<slug>/plan.md` (in-repo, gitignored).
3. At approval you choose the outcome — **Proceed** (implement), **Deliver plan
   only** (the plan file is the deliverable), review, or keep planning. The
   chosen approval runs `approve-plan.sh`, which validates the plan (non-empty,
   and newer than the marker, so a stale plan from a prior session can never
   release the gate) and deletes the marker. The gate opens; the chosen outcome
   follows. On Proceed, implementation is **subagents-first**: the plan's steps
   are dispatch-annotated by default and executed per `dispatch-agents` — the
   main thread orchestrates, subagents implement.

> `/mentor:plan` is **namespaced** — it cannot collide with Claude Code's native
> reserved `/plan` command.

## Commands

| Command | What it does |
|---|---|
| `/mentor:plan <task>` | The gated plan flow (above). |
| `/mentor:constitution [principles]` | Create/amend this repo's governing principles at `.mentor/constitution.md` — versioned, committed, and honored by every plan. |
| `/mentor:mode [plan\|plan-only\|status]` | Get/set the persisted approval-gate default (which approval option is listed first). |
| `/mentor:ship` | Finish the current branch: clean-check → `/simplify` → optional tests → push + auto-open PR/MR (or push to upstream). Never force-pushes. |
| `/mentor:merge [PR#]` | The tail `/mentor:ship` leaves off: one bounded `gh pr checks --watch`, one flake-rerun max (same failure twice = regression → stop and report), then merge only on your explicit choice (now / auto-merge on green / leave open). GitHub-only. |
| `/mentor:grill [topic]` | One-question-at-a-time interview that sharpens a design's open decisions before you build. Conversation only; no repo edits. |
| `/mentor:handoff "<focus>"` | Compact the session into a handoff document (in its plan-topic folder, `.mentor/plans/<topic>/handoffs/`, gitignored) for a fresh agent; ends with copy-paste resume prompts (`/mentor:resume <slug>` + a plugin-free alternative). Also offered as **Hand off to next agent** at the approval gate — leading the options (marked **(Recommended)**) when the context gate warns or asks. |
| `/mentor:resume [slug\|number]` | List this repo's live handoff notes (across all plan topics) and continue the chosen one. A note is stamped **resolved** (moved to a `resolved/` subdir, never re-listed) only when its work completes per the plan file (`/mentor:ship` stamps too) or a nested `/mentor:handoff` supersedes it — unfinished work stays resumable. |
| `/mentor:tour [user\|dev\|both] [subject]` | **Post-approval acceptance review**: an editable guided-tour artifact — scenario cards with pass/not-pass toggles, feedback capture, and MD/JSON report export — published to a stable URL that revisions republish in place. Subject defaults to the newest plan; artifacts live in `.mentor/tours/` (gitignored). |
| `/mentor:zoom [subject] [topic] [perspective]` | **Topic × perspective HTML zoom of any subject** — a repo subsystem, a doc, a mentor plan, or the thing under discussion; no plan file or planning session required. One dispatched agent per combo writes a self-contained page to `.mentor/zooms/<subject-slug>/` (gitignored), auto-opened locally and **never published**. `plan` Step 5 delegates here for in-planning zooms. |
| `/mentor:defer <item(s)>` | `git stash`-like capture: park one or many mid-flow discoveries (mid-planning or mid-implementation) as draft plan stubs at the normal plans location (`origin: "deferred"` in the sidecar, no separate stash area), then return to the interrupted flow. Picked up later via `/mentor:track`, which routes it to `/mentor:plan` to be claimed before it can build. |
| `/mentor:track [slug\|number\|status]` | Repo-wide remaining-work hierarchy — every plan's state, step progress, cross-plan `deps`, deferred stubs, and live handoffs — then build the one you pick. The way back into a `/plan-split` group. |
| `/plan-split`* | Split an oversized plan into independently buildable sibling plans, each with explicit scope isolation; also offered as **Split into multiple plans** at the approval gate when a plan is oversized. |
| `/plan-review`* | Staged review of the current plan: a judgment pass (practicality, comprehensiveness) with a **fold gate** that walks the recommended edits **one question at a time** — each question carries the reviewer's case with the key words bolded — then — against the updated plan — a mechanical pass (cleanliness + spec-kit-`analyze`-style **consistency** across related artifacts) whose safe fixes **auto-fold**; decision-level findings are asked the same one-by-one way, applied only on your verdict. The mechanical stage is invocable alone ("check plan consistency"). Also offered as **Review the plan (staged)** at the proceed gate. |
| `/dispatch-agents`* | The **default implementation path** (subagents-driven development): every plan's steps are dispatch-annotated unless the plan states a `Dispatch: skipped` reason, and executed as subagent dispatches after approval. |

\* skill trigger phrases, not registered slash commands — typing them (or the
matching natural language) invokes the skill.

## Repo modes (`/mentor:mode`)

The mode persists in `<repo>/.mentor/config.json` (committed — shared with the team)
and is only the **approval-gate default**: `/mentor:plan`'s final approval question
always offers both **Proceed** and **Deliver plan only**; the mode just decides
which is listed first. It is never asked for upfront — an unset mode behaves as
`plan`, and the real decision is made per task, at approval.

| Mode | Approval question |
|---|---|
| `plan` (or unset) | **Proceed** listed first — plan, then implement on approval. |
| `plan-only` | **Deliver plan only** listed first — the plan file is the deliverable. A default, not a lock: picking Proceed still implements. |

State-dir layout (**project-scoped** — `<repo>/.mentor/`; per-plan-topic dirs since
v2.2.0, handoffs inside them since v2.10.0):

```
<repo>/.mentor/
├── .gitignore       # commits config.json + constitution.md; ignores the rest
├── config.json      # {"mode": "plan|plan-only", + context-gate keys}   ← committed
├── constitution.md  # governing principles (/mentor:constitution)        ← committed
├── plans/           # the .planning marker + one dir per plan topic      ← gitignored
│   └── <slug>/      #   plan.md (+ hidden .plan.md.opened sidecar)
│       │            #   a /mentor:defer stub is an ordinary plan dir born small —
│       │            #   same shape, same location, just origin:"deferred" (v2.17.0)
│       ├── .state.json # lifecycle state + relations (v2.17.0) — written only by plan-state.sh
│       └── handoffs/ #  handoff notes (/mentor:handoff → /mentor:resume);
│           └── resolved/ # solved/superseded notes (stamped on completion or nested handoff)
├── zooms/           # /mentor:zoom artifacts — <subject-slug>/<topic>-<perspective>.html
│                    #   (pre-v2.12 they lived in plans/<slug>/zoom/; auto-relocated) ← gitignored
├── handoffs/        # legacy flat notes (pre-v2.10 — still listed, never written)
└── tours/           # /mentor:tour review artifacts (<slug>-<audience>.html) ← gitignored
```

Only `config.json` and `constitution.md` are committed (team-shared); plans, zooms,
handoffs, tours and the transient markers are gitignored. Un-ignore `plans/` if you want plans
version-controlled. **Not in a git repo?** handoff/resume and the context gate fall
back to `~/.claude/mentor/_no-repo/`.

## Splitting a big plan (`/plan-split`)

`/mentor:plan` assumes one ask = one plan. When the ask is huge, that plan becomes
unreviewable, its implementation runs out of context partway through, and nothing
records what already got built.

`/plan-split` takes the plan mentor just wrote and slices it into **ordinary sibling
plans** — no hierarchy, no new entity, just peers in `.mentor/plans/` sharing a
`group` field. It is offered as the leading option at the approval gate whenever a
plan is oversized (>~12 implementation steps, or independent deliverables that could
ship separately).

Each child is authored by its own dispatched agent, in parallel, and opens with the
**isolation header** that makes the siblings safe to build separately and in any
order:

```
> [!NOTE]
> **Plan 3 of 5** · group `multi-tenant-billing` · depends on `tenant-data-isolation`
> **Owns:** src/billing/invoice/**, the `/v1/invoices` route
> **Does NOT touch:** metering ingestion → `metering-pipeline` · tenant scoping → `tenant-data-isolation`
```

Every excluded area names the **sibling that owns it** — "does not touch metering"
tells an implementation agent nothing; "→ `metering-pipeline`" tells it exactly. The
header is also the authority on dependency order, and it travels into the
implementation agents' prompts, so the boundary follows the work.

The parent is marked `superseded` **only after every child is verified to exist** — a
failed authoring agent can never strand you with a retired parent and no children.
Splitting never releases the edit gate; when it finishes, you land back at the
approval question looking at the children's headers, where **Proceed approves the
whole set** and routes building to `/mentor:track`.

## Plan state (`/mentor:track`)

Every plan dir carries a hidden `.state.json` recording where it stands, so a fresh
session can answer "which of these five is next?" without re-reading five plans.

| State | Meaning |
|---|---|
| `draft` | Written, not yet approved. `/mentor:track` won't build it until you approve it. |
| `approved` | The gate released it. Ready to build. |
| `in_progress` | Execution started; some steps are ticked. |
| `implemented` | Every `Done when:` passed. |
| `failed` | Escalated after the remediation re-dispatch; the note says what broke. |
| `superseded` | Replaced by its children via `/plan-split`. Sorted last. |
| *(no sidecar)* | `unknown` — a pre-2.4.0 plan. Never reported as "never approved". |

**The sidecar is a cache, not the only truth.** Reads take the *more advanced* of the
stored state and the state derived from the plan's `✅` step ticks — every step ticked
reads `implemented`, some reads `in_progress`. Since `dispatch-agents` already writes
those ticks, a forgotten state write costs nothing and old plan dirs read correctly
with no migration.

Group membership heals the same way: a split child's isolation header carries
`**Plan 3 of 5** · group \`…\``, and mentor parses `group`/`order` back out of it when
the sidecar is missing or torn. Delete a `.state.json` outright and the plan still
lists with the right state, group, and position — a plan dir needs nothing but its
`plan.md`.

> This is not a return to the v1.0.0 footer markers. Those were in-document contracts
> the model had to maintain by hand, and they broke when it forgot. The sidecar is
> written only by `hooks/plan-state.sh` and is *derivable from the plan file*, so
> forgetting is a no-op rather than a corruption.

### Sidecar schema (v2.17.0: `deps` + `origin`)

Two fields joined the sidecar, both written only through `plan-state.sh`; old 4-field
sidecars need no migration — every reader defaults the new fields.

| Field | Before v2.17.0 | v2.17.0 | Written by |
|---|---|---|---|
| `state` | 6 states | unchanged | `init` / `set` |
| `group` | split-parent slug or `null` | unchanged | `init --group` |
| `order` | int or `null` | unchanged | `init --order` |
| `note` | free text, replaced each write | unchanged | `set --note` |
| `deps` | — | array of plan slugs, default `[]` | `init --deps a,b` / `set-deps <slug> a,b` |
| `origin` | — | `"deferred"` or `null` | `init --deferred` sets it; `claim <slug>` clears it |

`set-deps` replaces a plan's deps wholesale and refuses a write that would create a
dependency cycle (direct or transitive) — fail-soft: a stderr warning, no write.
Unknown dep slugs are allowed (the dep plan may not exist yet); `overview` marks them
`missing` rather than failing.

### Deferring work (`/mentor:defer`)

Work discovered mid-planning or mid-implementation that isn't the current task's scope
used to have nowhere to go but conversation prose. `/mentor:defer "<item(s)>"` — or
just saying "stash this for later" — captures one or many items as ordinary plan dirs,
born small: a stub `plan.md` (Goal / Context / Why deferred / Suggested first steps)
plus a sidecar carrying `origin: "deferred"`, at the normal `plans/` location — no
separate stash area. `origin` does two things: it shields the stub from
`approve-plan.sh`'s promotion sweep (a stub jotted mid-planning stays `draft` even
while the surrounding real plan gets approved), and it tells `/mentor:track` this
entry isn't buildable as-is. Picking it up runs `/mentor:plan <slug>`, which fleshes
out the stub and calls `claim <slug>` to clear `origin`, after which normal approval
promotes it like any plan.

### The repo-wide hierarchy (`overview --json`)

`plan-state.sh overview --json` is the one call that answers "what's remaining?" — a
JSON array covering every plan dir with a `plan.md` (state, group, order, `deps`, each
marked `missing` when no such plan dir exists, `origin`, live handoffs, ticked/total
step counts), plus topic dirs with a live handoff but no `plan.md` yet, plus the
legacy flat `.mentor/handoffs/` dir. Computed fresh on every call — nothing is cached,
so it can never drift from the sidecars, plan ticks, or filesystem it reads. `/mentor:track`
renders it as a hierarchy, e.g.:

```
1. ● recommended-first-clean   implemented (3/3 steps)
2. ○ oauth-refactor            draft (deferred) — deps: fix-gate-msg-typo
3. ○ fix-gate-msg-typo         draft (deferred)
4. ◐ some-feature              in_progress (1/4 steps)
     └ handoff: 20260801-224510-implement.md (live)
```

Unmet deps are surfaced with a recommended build order but never block — the user can
always proceed on the selected plan anyway.

```
/mentor:track            # repo-wide hierarchy: plans + deps + live handoffs, pick one, build it
/mentor:track status     # print the hierarchy and stop
/mentor:track 2          # build the 2nd listed (actionable) entry
/mentor:track billing    # substring match on the slug
```

`/mentor:track` runs its own context check before dispatching — the `UserPromptSubmit`
context gate lets every slash command through, so without it a slash command could
launch a full implementation in a session already too large to finish it.

> Named `track`, not `plans`, deliberately: `/mentor:plan` and `/mentor:plans` differ
> by one character and both tab-complete, and the typo would silently start a new
> planning session and close the edit gate.

## Constitution (`/mentor:constitution`)

A **constitution** is this repo's supreme rulebook: a short list of named,
declarative, **testable** principles (MUST/SHOULD language) plus a governance
block. It is the one mentor artifact that lives **in the repo** — committed at
`.mentor/constitution.md` — so the whole team shares one set of rules.

```
/mentor:constitution                     # bootstrap from repo conventions, or
/mentor:constitution "Test-First: every endpoint ships with a contract test"
```

`/mentor:constitution` is a **standalone authoring flow** (it never arms the plan
gate): it loads any existing constitution, collects/derives principles, bumps a
**semantic version** (MAJOR remove/redefine · MINOR add/expand · PATCH reword),
records ratification + last-amended dates, prepends a **sync-impact report**, and
writes the file after you confirm. Because it writes in-repo, run it **outside** a
plan session — while a `.planning` marker is armed the edit gate would block it.

Once it exists, it is honored automatically — there are no generated templates to
keep in sync; the plan skill reads it **live**:

| Consumer | Effect |
|---|---|
| `/mentor:plan` | Reads the constitution and adds a **`## Constitution Check`** table to the plan — one row per principle (✅ complies / ⚠️ deviates / ➖ N/A). Every ⚠️ must be resolved by the plan or justified explicitly. |
| `/plan-review` | Each reviewer additionally flags any principle the plan violates. |

Deviation is allowed but never silent: a plan either satisfies each principle,
records a justified exception, or the constitution is amended first.

## Context gate

A long-running session's context can balloon to the point where plan and answer
quality degrade. The **context gate** (`hooks/context-gate.sh`, a `UserPromptSubmit`
hook) measures the live context size from the session transcript and acts in three
tiers — it **never blocks or erases a prompt**; it warns, then asks:

- **Warn** (default **200000** tokens) — a one-time-per-session notice suggesting
  `/mentor:handoff` (→ `/mentor:resume` in a fresh session) or `/compact`.
- **Warn-high** (default **90% of the ask threshold**, i.e. 315000) — a near-limit
  nudge that re-fires on every prompt: wrap the current unit of work and steer toward
  a natural handoff boundary; avoid opening new large workstreams.
- **Ask** (default **350000** tokens) — the agent must **ask you first** before acting
  on the prompt: **Hand off to next agent (Recommended)** writes the handoff doc right
  there and stops; **Proceed anyway** bypasses the gate for this session (a
  `.context-bypass-<session_id>` marker — warnings continue, and a fresh session
  re-arms the gate) and your original request runs immediately in the same turn.
  A fresh handoff note (<30 min old) suppresses the question — the advisory just
  points at `/mentor:resume`. Harness-synthetic prompts (subagent reports) get a loud
  advisory instead of a question, so autonomous flows are never stalled.
  `/mentor:plan` gets the same treatment: over the threshold `begin-plan.sh` asks
  first (hand off & plan fresh, or bypass + lean plan) before arming.

Escape hatches always pass: an empty prompt and any slash command (`/mentor:handoff`,
`/compact`, `/mentor:mode`, …) are never gated, so you can always reach the tools that
fix the problem. Everything is fail-soft — no `jq`, no transcript, or an unreadable
transcript simply lets the prompt through.

> **Note:** the gate is a **long-context / 1M-window backstop**. On a standard 200k
> window with auto-compact enabled it may never fire (auto-compact triggers ~155–165k,
> below the 200k warn default). Tune `context_block_tokens` per-repo when you
> intentionally run long-context sessions.

Knobs — env vars under `env` in `~/.claude/settings.json` (or the project's
`.claude/settings.json`), or per-repo keys in `.mentor/config.json`. Precedence:
**env var > `.mentor/config.json` key > default**.

| Env var | `.mentor/config.json` key | Default | Effect |
|---|---|---|---|
| `MENTOR_CONTEXT_GATE=off` | `"context_gate": "off"` | on | Disable the gate entirely (`off\|0\|false\|no`). |
| `MENTOR_CONTEXT_WARN_TOKENS` | `"context_warn_tokens"` | `200000` | Warn threshold (tokens). |
| `MENTOR_CONTEXT_WARN_HIGH_TOKENS` | `"context_warn_high_tokens"` | 90% of ask | Warn-high threshold (tokens). |
| `MENTOR_CONTEXT_BLOCK_TOKENS` | `"context_block_tokens"` | `350000` | Ask threshold (tokens; key name kept for compatibility). |
| `MENTOR_CONTEXT_TAIL_LINES` | — | `400` | Transcript tail window scanned for the measurement. |
| — | `"test_command"` | auto-detect | `/mentor:ship` Step 4's test command — set it where auto-detect guesses wrong (monorepos). No env-var twin. |

## How it works

| Piece | Role |
|---|---|
| `commands/plan.md` | The `/mentor:plan` trigger. |
| `hooks/begin-plan.sh` | Arms the `.planning` marker (closes the gate); prints the `MODE:` line (the approval-gate default) — and a `CONTEXT:` line: over the ask threshold it asks the user first (hand off, or bypass + lean plan) before arming. |
| `hooks/plan-gate.sh` | **The one gate.** Fail-closed `PreToolUse` on Write/Edit/MultiEdit/NotebookEdit — denies in-repo writes while the marker exists, even under `bypassPermissions`. Mentor's own `.mentor/` tree (where the plan file lives) is exempt, so the plan is always writable. Stale markers (>8h) self-heal. |
| `hooks/approve-plan.sh` | Validates the plan (non-empty `.md` **newer than the marker**), releases the gate. Mode-agnostic — flags map to the approval options: no-arg implements, `--deliver` prints the deliverable soft-stop, `--handoff` the hand-off directive (both directives also print on a re-run when the gate is already open); unknown flags are rejected. |
| `hooks/plan-open.sh` | Auto-opens the plan for review the first time it is written (VSCode tab / OS default; HTML zoom artifacts in `.mentor/zooms/` open in the browser). |
| `hooks/set-mode.sh` | Get/set the approval-gate default. |
| `hooks/context-gate.sh` | **Context gate.** `UserPromptSubmit` — measures live context from the transcript: warns once (~200k), re-warns near the limit (~315k), and above ~350k asks the user — hand off (recommended) or bypass for the session. Never blocks or erases prompts. Fail-soft; slash commands always pass. |
| `hooks/bypass-context.sh` | Writes the session-scoped `.context-bypass-<session_id>` marker when the user answers "Proceed anyway" — degrades the ask tier to a one-line advisory for the rest of the session. |
| `hooks/plan-state.sh` | **The one plan-state API** (not a hook — skills call it directly). `init` / `set` / `set-deps` / `claim` / `list` / `current` / `overview` / `context` / `dir`. Sole writer of `.state.json` (incl. `deps` and `origin`, v2.17.0); derives effective state from the plan's ✅ ticks; `current` is group-aware, so after a split it reports the whole group rather than whichever child agent finished last. `overview --json` computes the repo-wide plans+deps+handoffs hierarchy fresh on every call — nothing cached. `dir` (v2.14.0) is the one repo-scoped `.mentor` path derivation — skills call it instead of hand-rolling `git-common-dir` snippets that drift. |

### Known limitations

- **Bash is not gated.** The gate covers the Write/Edit/MultiEdit/NotebookEdit
  path (Claude's near-universal edit path); the skill instructs against
  repo-mutating shell commands during planning but does not enforce it.
- **The gate protects the current worktree.** The `.planning` marker is shared
  across linked git worktrees (via `git-common-dir`), but the deny check runs
  against the worktree you are planning in — planning from a linked worktree
  leaves the main worktree writable.

### Plan format

Plans are single self-contained **Markdown** documents — Mermaid-first
(` ```mermaid ` flowchart/sequence/ER/state), with GFM tables, ASCII diagrams,
and GFM alerts. Portable: renders richly on GitHub/GitLab and any Mermaid-capable
viewer. One visualization per significant change, never two representations of
one thing.

**Optional HTML zoom (`/mentor:zoom`):** when you explicitly ask for an HTML
preview/zoom, mentor never renders the whole subject as one file — the `zoom`
skill first resolves **topic(s) × perspective(s)** (end user / implementor /
reviewer-architect / QA-tester), asking for whichever dimension your request
didn't name, then dispatches one agent per topic × perspective combination.
Each writes its own supplementary
`.mentor/zooms/<subject-slug>/<topic>-<perspective>.html` — a throwaway,
self-contained, local-only visual aid for that topic through that lens. The
subject stays the source of truth. During planning, `plan` Step 5 delegates
here (the subject slug = the plan slug); standalone, the skill zooms **any**
subject — no plan file required.

### Viewing the plan

The plan auto-opens the first time it is written (`plan-open.sh`): as a
**VSCode editor tab** when a VSCode CLI is available (toggle preview with ⇧⌘V;
install a Mermaid preview extension to render the diagrams), otherwise the OS
default Markdown handler. HTML zoom artifacts open in the browser (or via
VSCode's Live Preview extension).

Knobs — set under `env` in `~/.claude/settings.json` (a shell `export` won't reach the hook):

| Var | Effect |
|---|---|
| `MENTOR_PLAN_OPENER` | `auto` (default) · `vscode` · `chrome` · `system` |
| `MENTOR_PLAN_VSCODE_BIN` | Force the VSCode CLI binary (default: auto-detect `code` / `cursor` / `windsurf` / …) |
| `MENTOR_PLAN_OPEN=off` | Disable auto-open entirely |

### Domain planning skills

When the task touches a registered domain, `plan` invokes that domain's
planning skill once. The domain skill shapes the research prompts and the plan's
extra deliverable. Instruction-only — no hooks.

| Domain | Triggers | Extra plan deliverable |
|---|---|---|
| `plan-domain-frontend` | UX/UI — components, pages, styles, layout, design systems, theming, responsive | ASCII zone wireframes + delta/token tables; live mockups authored by the zoom combo agent only in an opt-in HTML zoom. |
| `plan-domain-backend-api` | API/endpoint/route/handler/schema/DTO/contract | Before/after contract diff tables, schema diffs, Mermaid sequence flows. |
| `plan-domain-architecture` | Structural change — services, containers, datastores, queues, integrations, data flows (not pure content/config/doc/style/refactor) | Diff-highlighted C4-style Mermaid flowcharts, only the levels that change; a provenance list for any changed datastore field. |
| `plan-domain-dynamic` | No registered domain matched (fallback) | A dispatched domain-definer names the domain and returns a best-practices brief; the plan gains a practice→step mapping. |

## Changes in v2.17.0

**Work discovered mid-process now has somewhere to go.** New `/mentor:defer`
captures one or many future-work items — mid-planning or mid-implementation —
as draft plan stubs, then returns to the interrupted flow. A stub is not a new
kind of thing on disk: it is an ordinary plan dir at the normal location, born
`draft` with `origin: "deferred"` in its sidecar. There is no stash area, no
stash label, and no second capture path — which is why `list`, the edit gate,
and the single writer already cover it with no new machinery. Stubs carry no
`Relations` section: dependencies live only in the sidecar, so the fact keeps
exactly one owner.

**Deferred stubs survive an approval sweep.** `approve-plan.sh`'s promotion loop
now skips candidates whose sidecar reads `origin: "deferred"`, so a stub jotted
down while the gate was armed stays `draft` instead of being swept into
`approved` alongside the plan you were actually writing. `plan-state.sh claim
<slug>` clears the shield when the stub enters real planning — and
`/mentor:track` will not approve an unclaimed stub through its draft escape
hatch, so the defer→claim path cannot be bypassed.

**`/mentor:track` answers "what's remaining?" for the whole repo.** Discovery
moved from `list` to the new `plan-state.sh overview --json`, and the view is
now a hierarchy rather than a flat table: every plan with its state and
ticked/total step counts, `deferred` tags, cross-plan dependency edges, and each
plan's live handoffs as sub-lines. It also surfaces two things nothing showed
before — topic dirs holding handoffs but no plan yet, and the legacy flat
`.mentor/handoffs/` dir. Dependencies are advisory: picking a plan whose deps
are unbuilt warns and recommends an order, never blocks.

**The sidecar records relations.** `.state.json` gains `deps` (an array of plan
slugs) and `origin` (`"deferred"` or null), written via `init --deps/--deferred`,
`set-deps`, and `claim`. `set-deps` refuses writes that would close a dependency
cycle, including multi-node ones. Old four-field sidecars need no migration —
readers default the new fields — and `list`/`current` output is byte-identical
to v2.16.0, so anything parsing them keeps working. The repo-wide view is
computed on every call and never cached, so it cannot drift from the files it
describes.

## Changes in v2.16.0

**Review questions now lead with the recommendation.** `/plan-review`'s fold gate
marked `Fold in` as `(Recommended)` only on the reviewer's single highest-impact
edit, and its verdict walk deliberately presented DECISION-REQUIRED alternatives
neutrally. Both now lead with the recommended option: every fold question carries
`(Recommended)` with the reviewer's one-line why in the description, and the verdict
walk orders the reviewer-recommended resolution first. Reviewers name that resolution
themselves — the Step 6 tagging contract now requires it — and on a genuine
either-side-could-be-intended toss-up they say so and the options stay unled. The
guards are unchanged: bulk `Fold in the rest` / `Skip the rest` options are still
never `(Recommended)`, and the recommendation shapes only how options are
*presented*, never whether one is applied — nothing DECISION-REQUIRED is folded
until you verdict it.

**Agents are asked to build the clean thing, not the quick thing.** Four skills —
`plan-review`, `plan`, `grilling`, and `dispatch-agents` — now carry one canonical
line: recommend the most practical and clean solution, never trading maintainability
or reliability for implementation speed. It governs the edits reviewers propose,
planning's recommended option and `## Approach` design, grilling's recommended
answers, and every implementation brief a dispatch writes (read-only roles like
`Explore` are exempt — the line governs how something is built, not how it's found).
It never widens a reviewer's lane: naming a recommendation is a choice among that
reviewer's own proposed fixes, not license to critique outside its lens.

## Changes in v2.14.0

**Approval now promotes plan state on every path.** `approve-plan.sh` previously
left state at `draft` when the plan was approved via `--handoff` / `--deliver`,
so the gate released while `/mentor:plan-track` still reported the plan as
unapproved and refused to build it. All three approval paths now promote.

**A new `/mentor:merge`** picks up where `/mentor:ship` deliberately stops: one
bounded `gh pr checks --watch`, at most one rerun of a plausible flake, and a
merge only on your explicit choice. The same job failing the same way twice is
treated as a regression, reported, and left open — fixing it is a new session.

**One repo-root derivation, not nine.** `plan-state.sh` gained a `dir [--plans]`
subcommand and the skills that hand-rolled `git-common-dir` snippets now call it,
which also fixes a worktree bug in plan's constitution lookup (it used
`--show-toplevel` and missed linked worktrees).

**Smaller things:** `/mentor:resume` surfaces the non-conforming-filename skips it
used to swallow, and can rename one on request; `/mentor:ship` and `/mentor:resume`
check branch ownership before you build on someone else's PR; `/mentor:ship` closes
the plan's state on a successful ship and honors a `test_command` in
`.mentor/config.json` for monorepos where test auto-detection misfires.

## Changes in v2.13.0

`/plan-review` review results now reach you **one question at a time**. The
Stage 1 fold gate drops its per-dimension multi-select: every recommended
edit gets its own single-select question (Fold in / Skip / Skip the rest),
written the way a human reviewer would present the finding — the observation,
why it matters, and what changes, with the **key words bolded** — and, when
the reviewer supplied concrete text, a before → after preview of the exact
edit. Stage 2's DECISION-REQUIRED findings get the same treatment: instead of
ending in a surfaced-only report, each finding is asked one verdict question
(the reviewer's stated alternatives / Leave open / Skip the rest), and
accepted resolutions are folded in one final pass — still never auto-applied.
Stage-2-only's "Surface only" stays fully read-only: no writes, no verdict
walk.

## Changes in v2.12.0

The HTML zoom is now its own skill — **`/mentor:zoom`** — usable on **any**
subject, with no plan file and no planning session required.

- **Extracted from `plan` Step 5.** The ~90-line zoom contract (topic ×
  perspective selection gate, one dispatched agent per combo, self-contained
  local HTML, never published) moved to `skills/zoom/SKILL.md`; `plan` Step 5 is
  now a delegation stub, so the planning flow is unchanged from the user's side.
  New in the standalone skill: a **source pack** step — a plan/doc path, real
  file paths (optionally distilled by one `Explore` agent into a `_brief.md`),
  or a conversation brief — so combo agents always render from real sources.
- **Zooms moved to a flat tree:** `.mentor/zooms/<subject-slug>/…` replaces
  `.mentor/plans/<slug>/zoom/…`. For a plan subject the slug IS the plan slug,
  which is how `plan-review` and `handoff` still find a plan's zooms. The next
  `/mentor:plan` run relocates existing zoom files automatically (idempotent,
  `mv -n`); `plan-open.sh` still auto-opens files left at the legacy path.
- **Boundaries restated:** zoom = local, read-only, never published;
  `/mentor:tour` = published, editable, pass/not-pass acceptance;
  `/plan-review` = a quality verdict on the plan `.md`. The trigger evals grew
  matching near-miss queries, and `tour` joined the staged eval set.

## Changes in v2.11.1

Closes a hole where planning could run with the **edit gate open**.

- **`mentor:plan` now checks the gate before planning.** The marker-driven gate is
  armed by `begin-plan.sh`, which only the `/mentor:plan` command runs. Loaded any
  other way — a conversational "help me plan this" — the skill used to plan anyway,
  with `plan-gate.sh` finding no marker and allowing every repo edit for the rest of
  the session, while the approval step still displayed its "no edits until approved"
  banner. Step 0 now detects the unarmed gate and stops, pointing at the command. It
  deliberately does not arm the marker itself: on a large session `begin-plan.sh`
  answers `CONTEXT: ASK` and exits *without* arming, and resolving that with the user
  belongs to the command layer.
  - The check resolves the repo via `--git-common-dir`, matching `mentor_repo_root`,
    so linked worktrees — which share the main repo's `.mentor/` — are read correctly.
  - Step 0 also no longer reports a missing `MODE:` line as "not in a git repo". That
    was one of two causes; the other is this bug, and it needed the opposite response.
- **Trigger evals** (new, `evals/`) — a re-runnable check that a user's phrasing
  reaches the intended skill and not one of its seven siblings. mentor had eight hook
  test suites and nothing guarding the descriptions. 36/40 at this version; see
  `evals/README.md`, including why the fixture must be seeded before the numbers mean
  anything.

## Changes in v2.11.0

Split an oversized plan into isolated sibling plans, backed by **plan state**. The two
changes are one feature: splitting a plan into five is only useful if mentor can then
tell you which of the five are built.

- **`/plan-split`** (new skill) — slices the current plan into N ordinary sibling
  plans, one dispatched agent per child, each opening with an **isolation header**
  naming what it owns and which sibling owns everything it does not. Offered at the
  approval gate when a plan is oversized. Verifies every child before retiring the
  parent — a failed authoring agent can never strand you with no children — and
  returns you to the approval question.
- **Plan state** (new) — a `.state.json` sidecar per plan dir:
  `draft → approved → in_progress → implemented | failed`, plus `superseded`. Reads
  take the more advanced of the sidecar and the state derived from the plan's `✅`
  step ticks, so a forgotten write is a no-op and older plans need no migration. Group
  and order likewise fall back to parsing the isolation header, so a plan dir survives
  with nothing in it but `plan.md`. A plan with no sidecar reads `unknown`, never
  "never approved".
- **`/mentor:track`** (new command) — lists every plan with its state and builds the
  one you pick, re-entering an interrupted run at the first unticked step. Refuses
  `draft` plans (the gate never released them) and runs the shared context check
  before dispatching, since `context-gate.sh` passes every slash command.
- **`hooks/plan-state.sh`** (new) — `init`/`set`/`list`/`current`/`context`; the only
  writer of the sidecar. Its group-aware `current` replaces three hand-rolled
  `ls -t plans/*/plan.md | head -1` snippets in `plan-review`, `grilling` and
  `lib/state.sh`, which after a split each resolved to whichever child agent finished
  writing last.
- **`approve-plan.sh` promotes state on every approval path** (since v2.14.0 — it was
  no-arg-only before, which left `--handoff`/`--deliver` plans at `draft` and made
  `/mentor:track` falsely refuse them next session). The candidate
  set is snapshotted **before** the marker is deleted: `find -newer <marker>` is true
  for everything once the marker is gone, so promoting afterwards would have stamped
  every plan dir in the repo, including months-old ones, and flipped a just-superseded
  parent back to `approved`.
- **The v2.8.0 ask-first context check is now one shared helper**
  (`mentor_context_verdict`, returning `OK`/`WARN`/`ASK`/`HANDOFF`). `begin-plan.sh`
  routes through it instead of measuring inline, and `/mentor:track` applies the same
  policy — including the `.context-bypass-<session_id>` marker, so a user who chose
  "Proceed anyway" is never then refused by a different entry point.
- **One approval-option precedence table** in `plan` `{#approve}`, now covering
  oversized × `WARN`/`HANDOFF`. `commands/plan.md` points at that table instead of
  keeping a second copy that had already drifted.
- **Lane fixes:** `resume` and `handoff` used to claim the "pick the next plan to
  build" lane; both now point at `/mentor:track`. `dispatch-agents` gained a "When NOT
  to use" so invoking it directly cannot skip the context check.

## Changes in v2.9.0

`/plan-review` is restructured around **who decides each fix**. Stage 1
dispatches the two judgment reviewers (practicality, comprehensiveness) and
ends at a **fold gate**: recommended edits get stable IDs (`P1…`, `C1…`) and a
multi-select question lets you pick exactly which to fold into the plan —
declined IDs are not re-offered when the review re-runs in the same session.
Stage 2 then runs the two mechanical reviewers (cleanliness moved here,
joining the spec-kit-`analyze`-style consistency check) against the **updated**
plan; their findings arrive tagged `MECHANICAL` or `DECISION-REQUIRED`, safe
MECHANICAL fixes **auto-fold** (guarded by a demote-on-doubt rule and a
cross-reviewer conflict rule), and decision-level findings are surfaced, never
auto-applied. "Consistency only" becomes **Stage-2-only mode** — auto-fold
included, with a write confirm on direct consistency asks — and the
approval-gate option is renamed **Review the plan (staged)**.

## Changes in v2.8.0

The context gate **no longer blocks** — the exit-2 tier that erased prompts is
gone. The top tier (default raised **270k → 350k**) is now **ask-first**: the
agent must ask via `AskUserQuestion` — **Hand off to next agent (Recommended)**
writes the handoff doc and stops, while **Proceed anyway** runs the new
`bypass-context.sh` (a session-scoped `.context-bypass-<session_id>` marker) and
fulfills the original prompt in the same turn; warnings continue and a fresh
session re-arms the gate. A handoff note written in the last 30 minutes
suppresses re-asking, and synthetic subagent reports get an advisory instead of
a question so autonomous flows never stall. `begin-plan.sh` asks the same way
instead of refusing to arm — after a bypass it arms with `CONTEXT: HANDOFF`
(lean planning, handoff-leading approval marked "(Recommended)"). Warn-high
(90% of the ask threshold) steers toward a natural handoff boundary. Knob names
are unchanged (`context_block_tokens` is now the ask threshold).

## Changes in v2.7.0

The plan flow now **resolves open questions & decisions with the user before
the plan is written** (`plan` Step 3.5). Open questions from research, domain
directives, and the planner's own design forks are triaged — codebase-answerable
ones are explored (never asked), immaterial ones flagged — and every genuine
user decision is asked via `AskUserQuestion`, **one question at a time**, each
with an evidence brief, a recommended option listed first, trade-off-carrying
option descriptions, and side-by-side previews for competing shapes. Grilling
documents its boundary with the new step (pre-research ambiguity vs
post-research decisions). Also two AskUserQuestion contract fixes: tour's
header chip exceeded the 12-char cap, and ship's recommended-option markers
drifted from the plugin-wide recommended-first "(Recommended)" convention.

## Changes in v2.5.0

`/mentor:handoff` now **ends its report with copy-paste resume prompts** — the last
thing on screen is a fenced `/mentor:resume <slug>` block (the slug uniquely matches
the note, so pasting that one line into a fresh session resumes instantly, no picker),
plus a plain-prompt alternative with the absolute note path for a next agent without
the mentor plugin. Prompts are always literal — real slug, real path, no placeholders.

## Changes in v2.3.0

Subagents-driven development (SDD): approved plans now execute **subagents-first**
by default — the main thread orchestrates and verifies, dispatched agents
implement. Each agent gets one narrow, focused step (quality through focus) and
the main context stays lean (no implementation files loaded). This extends the
existing inline per-step `[role: … · model: … · effort: …]` grammar — it is NOT
a revival of the v1.0.0-removed `dispatch-agents:` footer-line mechanism, and
nothing is hook-enforced:

- **Dispatch-annotated by default:** `plan` Step 4 now invokes
  `mentor:dispatch-agents` and annotates every implementation step (one step =
  one dispatch). Skipping requires the plan to open its Implementation steps
  with `Dispatch: skipped — <reason>` — visible and reviewable at approval.
- **Escape hatch:** trivial work (roughly ≤ ~20 changed lines, nothing new to
  read) or work needing tight user back-and-forth may skip; if a skipped task
  turns out non-trivial mid-flight, stop and dispatch normally.
- **Orchestrator contract:** the main thread never reads delegated files —
  it verifies via executable `Done when:` checks, `git diff`, and failing
  command output; one remediation re-dispatch, then escalate to the user.
  Progress is checked off in `plan.md` (✅) so resumed sessions know what ran.
- **Sequential-collapse rule:** adjacent small dependent steps (combined
  ≤ ~40 lines, same role/model) merge into one dispatch — no agent-startup tax
  per tiny step.
- **Backstops:** `plan-review`'s consistency reviewer flags plans with neither
  annotations nor a skip line; `approve-plan.sh` (Proceed) prints an
  informational SDD directive. In-plugin `Skill()` references are now uniformly
  `mentor:`-namespaced.

## Changes in v2.2.0

One plan = one directory. Previously a single zoom-reviewed plan could leave
30+ flat files in `.mentor/plans/` (the `.md`, up to 16 `<slug>-<topic>-<perspective>.html`
zooms, and a visible `.opened` sidecar for each). Now:

- **Per-plan dirs:** the plan lives at `plans/<slug>/plan.md` (fixed name); zoom
  artifacts live in `plans/<slug>/zoom/<topic>-<perspective>.html` (the `<slug>-`
  filename prefix is gone — the dir carries it).
- **Hidden sidecars:** the open-once markers are dot-hidden
  (`.plan.md.opened`), so `ls .mentor/plans/<slug>/` shows just the plan and its
  `zoom/` dir.
- **Silent migration:** the next `/mentor:plan` run migrates any old flat layout
  in place (`<slug>.md` → `<slug>/plan.md`, `<slug>-*.html` → `<slug>/zoom/`,
  longest slug first so prefix-colliding plans keep their own zooms). Old flat
  `.opened` sidecars are swept; orphan `.html` files without a matching `.md`
  are left where they are (gitignored, harmless).
- **Note:** handoff notes written before v2.2.0 may reference the old flat plan
  path — the plan now lives at `…/<slug>/plan.md`.
- **Superseded (v2.12.0):** the per-plan `plans/<slug>/zoom/` location described
  here was later replaced by the flat `.mentor/zooms/<subject-slug>/` tree;
  `begin-plan.sh` relocates old zoom files automatically.

## Changes in v2.1.0

The working mode no longer gates execution — it is now only the **approval-gate
default**. `/mentor:plan` never asks an upfront mode question (an unset mode behaves
as `plan`), and the approval step **always offers both** "Proceed" and "Deliver plan
only"; the persisted mode merely decides which is listed first.

- **`plan-only` no longer hard-blocks implementation:** choosing "Proceed" in a
  `plan-only` repo implements immediately — teams that relied on the hard stop have
  the operator pick "Deliver plan only" at approval instead.
- **No config migration needed:** a committed `{"mode":"plan-only"}` now simply
  reads as "deliver-first default".
- **`approve-plan.sh` is mode-agnostic:** it gained an explicit `--deliver` flag
  (the deliverable soft-stop) and no longer reads the persisted mode; directives
  are also printed when the gate is already open, and unknown flags are rejected.
- **"Hand off to next agent" moved out of the default approval options** — it
  leads them when the context gate warns, and stays reachable via "Other" or
  `/mentor:handoff` after a deliver-only approval.

## Breaking changes in v2.0.0

mentor's state moved from **user scope** (`~/.claude/mentor/<repo>-<hash>/`) to
**project scope** — `<repo>/.mentor/` — so config, plans, handoffs and markers live in
the repo they belong to (`config.json` + `constitution.md` committed; the rest
gitignored). Also new: the **context gate** (above).

**Migration:** the old user-scope state is **ignored**, not read. Re-run `/mentor:mode`
once per repo to re-persist the working mode; existing plans/handoffs under
`~/.claude/mentor/<repo>-<hash>/` are orphaned and can be deleted. Not-in-a-repo
handoffs still use `~/.claude/mentor/_no-repo/`.

## Breaking changes in v1.0.0

mentor 1.0.0 is a wholesale simplification (~10.5k → ~3k lines). Removed:

- **Worktree strategies** — the 4-option strategy question, worktree allocation,
  `worktree-confine.sh`, and per-worktree `mentor.json` are gone. For isolated-
  branch work use Claude Code's native worktree tooling (`EnterWorktree`).
  `/ship` became `/mentor:ship` and ships the **current branch**.
- **Orchestrator subsystem** — the session-wide always-delegate gate, its prompt
  injector, trackers, `/mentor:orchestrator`, and the `commander` stub.
- **HTML plan format & format config** — `/mentor:plan-output-format`, the styled-
  HTML plan document, its machine contract, and the finalize-to-Markdown
  lifecycle. Markdown is the only plan format; HTML survives as an explicit
  opt-in zoom artifact.
- **Native plan-mode integration** — the `ExitPlanMode`/`.proceed-mode` fallback
  path and its hooks. The owned marker flow is the only flow.
- **Enforced delegation** — the read-budget and plan-author gates
  (`plan-read-gate.sh`, `plan-author-gate.sh`, trackers) are gone; research and
  plan-author delegation is suggested, not enforced. `MENTOR_PLAN_RESEARCH`,
  `MENTOR_PLAN_AUTHOR`, `MENTOR_PLAN_FORMAT`, and `MENTOR_PLAN_EXIT_MODE` no
  longer exist.
- **Footer markers & strategy-guard** — plans no longer carry
  `strategy:`/`worktree:`/`dispatch-agents:` footer lines; approval validates
  freshness instead.

Stale state from older versions (`orchestrator`/`format` keys in `config.json`, old
marker sidecars, and the entire user-scope `~/.claude/mentor/<repo>-<hash>/` tree from
≤ v1.x) is simply ignored.

## Requirements

`jq`, `git`, and `python3` (only as a `realpath` fallback for path canonicalization).

## Attribution

The `grilling` (`/mentor:grill`) and `handoff` (`/mentor:handoff`) skills are adapted from
[mattpocock/skills](https://github.com/mattpocock/skills) (the `productivity` skill set), reworked
to fit mentor's conventions, namespacing, and gates.
