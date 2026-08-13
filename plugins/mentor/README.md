# mentor

A lean planning harness for Claude Code. One enforcement mechanism: `/mentor:plan`
arms this worktree's plan gate marker (`.planning.<wt-id>` — one per git worktree
since v2.23.0), and a single fail-closed `PreToolUse` hook blocks every repo edit in
that worktree — even under `bypassPermissions` — until the plan is approved. Plans
are **Mermaid-first Markdown** documents persisted in the repo's **`.mentor/`** dir
(gitignored, shared across every worktree), with required per-topic visualizations
and a mandatory **Use case scenarios** section proving the plan understood the
request. They auto-open for review and are the single source of truth for
implementation, handoff, and review.

## Quick start

```
/mentor:mode plan-only        # optional: set the approval-gate default (plan | plan-only)
/mentor:grill <topic>         # optional: sharpen open design decisions before you plan
/mentor:plan <what you want to build>
```

`/mentor:plan`:

1. Runs `begin-plan.sh`, which writes this worktree's own `.planning.<wt-id>` marker
   — **arming the edit gate for this worktree**. From here, repo source edits in
   THIS worktree are blocked until approval; other worktrees plan and edit
   independently (see "Known limitations").
2. Follows the `plan` skill: optional clarify (grilling), research
   (subagent delegation suggested for big tasks), domain routing, open-decision
   resolution (every open question or decision that needs the user is asked via
   `AskUserQuestion`, one at a time, each with evidence and a recommended
   option), then a
   Markdown plan written to `<repo>/.mentor/plans/<slug>/plan.md` (in-repo, gitignored).
3. At approval you choose the outcome — **Proceed** (implement), **Deliver plan
   only** (the plan file is the deliverable), hand off, review, keep planning, or
   **Pause — still drafting** (hand off *without* approving: the gate stays armed
   and the plan stays `draft`, for when the session runs out of room before the
   plan is settled — the one option that runs no script). Any *approving*
   choice runs `approve-plan.sh`, which validates the plan (non-empty,
   and newer than the marker, so a stale plan from a prior session can never
   release the gate) and deletes the marker. The gate opens; the chosen outcome
   follows. On Proceed, implementation is **subagents-first**: the plan's steps
   are dispatch-annotated by default and executed per `dispatch-agents` — the
   main thread orchestrates, subagents implement and verify (one fresh verifier
   agent per Verification topic, with no escape hatch).

> `/mentor:plan` is **namespaced** — it cannot collide with Claude Code's native
> reserved `/plan` command. The same holds for every mentor command: they exist
> **only** in `/mentor:<name>` form. A bare `/ship` or `/plan` is not mentor's —
> it is whatever else claims that name, or nothing at all, and "nothing at all"
> is the dangerous case: the assistant may improvise a substitute flow rather
> than report that the command didn't resolve.

> Enabling mentor **mid-session** (e.g. toggling it on in `.claude/settings.json`)
> doesn't make its commands or skills live in that same session — until you
> `/reload-plugins` (or start a fresh session), neither `/mentor:ship` nor a
> skill trigger like "dispatch agents" resolves, and Claude Code silently falls
> back to whatever else claims the name, or improvises a substitute. Old
> versions also linger in `~/.claude/plugins/cache/` — never `Read` one as if
> it were current; check `.claude-plugin/plugin.json` for the live version,
> then match it against the `Changes in vX.Y.Z` sections below to see whether
> a given fix is in your copy.

## Commands

| Command | What it does |
|---|---|
| `/mentor:plan <task>` | The gated plan flow (above). |
| `/mentor:constitution [principles]` | Create/amend this repo's governing principles at `.mentor/constitution.md` — versioned, committed, and honored by every plan. |
| `/mentor:mode [plan\|plan-only\|status]` | Get/set the persisted approval-gate default (which approval option is listed first). |
| `/mentor:ship` | Finish the current branch: clean-check → `/simplify` → optional tests → push + auto-open PR/MR (or push to upstream). Never force-pushes. |
| `/mentor:merge [PR#]` | The tail `/mentor:ship` leaves off: one bounded `gh pr checks --watch`, then one triage — flake (one rerun max) / regression (stop and report) / already broken on the base branch (don't spend the rerun; capture the rot with `/mentor:defer`) — then merge only on your explicit choice. GitHub-only. |
| `/mentor:grill [topic]` | One-question-at-a-time interview that sharpens a design's open decisions before you build. Conversation only; no repo edits. |
| `/mentor:handoff "<focus>"` | Compact the session into a handoff document (in its plan-topic folder, `.mentor/plans/<topic>/handoffs/`, gitignored) for a fresh agent; ends with copy-paste resume prompts (`/mentor:resume <slug>` + a plugin-free alternative). Also offered at the approval gate in two flavors — **Hand off to next agent** (approves and releases first; leads the options, marked **(Recommended)**, when the context gate warns or asks) and **Pause — still drafting** (hands off with the gate still armed and the plan still `draft`, so the next session continues planning). |
| `/mentor:resume [slug\|number]` | List this repo's live handoff notes (across all plan topics) and continue the chosen one. A note is stamped **resolved** (moved to a `resolved/` subdir, never re-listed) only when its work completes per the plan file (`/mentor:ship` stamps too) or a nested `/mentor:handoff` supersedes it — unfinished work stays resumable. |
| `/mentor:plan-tour [plan slug] [area] [perspective]` | **Pre-approval storytelling walkthrough**: a paged, local-only HTML tour of how a plan will execute — one persistent diagram evolving alongside narrative text, per chosen area × perspective, with per-page notes exportable as a self-identifying MD report. Never published; distinct from `/mentor:tour` below (published, post-approval, pass/not-pass acceptance). Artifacts live in `.mentor/plans/<slug>/tour/` (gitignored). |
| `/mentor:tour [user\|dev\|both] [subject]` | **Post-approval acceptance review**: an editable guided-tour artifact — scenario cards with pass/not-pass toggles, feedback capture, and MD/JSON report export — published to a stable URL that revisions republish in place. Subject defaults to the newest plan; artifacts live in `.mentor/tours/` (gitignored). |
| `/mentor:zoom [subject] [topic] [perspective]` | **Topic × perspective HTML zoom of any subject** — a repo subsystem, a doc, a mentor plan, or the thing under discussion; no plan file or planning session required. One dispatched agent per combo writes a self-contained page to `.mentor/zooms/<subject-slug>/` (gitignored), auto-opened locally and **never published**. `plan` Step 5 delegates here for in-planning zooms. |
| `/mentor:defer <item(s)>` | `git stash`-like capture: park one or many mid-flow discoveries (mid-planning or mid-implementation) as draft plan stubs at the normal plans location (`origin: "deferred"` in the sidecar, no separate stash area), then return to the interrupted flow. Picked up later via `/mentor:track`, which routes it to `/mentor:plan` to be claimed before it can build. |
| `/mentor:track [slug\|number\|status]` | Repo-wide remaining-work hierarchy — every plan's state, step progress, cross-plan `deps`, deferred stubs, and live handoffs — then build the one you pick. The way back into a `/plan-split` group. |
| `plan-split`* | Split an oversized plan into independently buildable sibling plans, each with explicit scope isolation; also offered as **Split into multiple plans** at the approval gate when a plan is oversized. |
| `plan-review`* | Staged review of the current plan: a judgment pass (practicality, comprehensiveness) with a **fold gate** that walks the recommended edits **one question at a time** — each question carries the reviewer's case with the key words bolded — then — against the updated plan — a mechanical pass (cleanliness + spec-kit-`analyze`-style **consistency** across related artifacts) whose safe fixes **auto-fold**; decision-level findings are asked the same one-by-one way, applied only on your verdict. The mechanical stage is invocable alone ("check plan consistency"). Also offered as **Review the plan (staged)** at the proceed gate. |
| `dispatch-agents`* | The **default implementation path** (subagents-driven development): every plan's steps are dispatch-annotated unless the plan states a `Dispatch: skipped` reason, executed as subagent dispatches after approval, then verified by one fresh verifier agent per Verification topic — implementation dispatch may skip, verification dispatch never does on a mentor plan. |

\* skill trigger phrases, not registered slash commands — there is no `/plan-split`,
`/plan-review`, or `/dispatch-agents` command. They invoke only via
`Skill({"skill": "mentor:<name>"})` or natural language matching the skill's
`description:` (which may not be the literal name above).

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
├── plans/           # one .planning.<wt-id> gate marker PER WORKTREE (v2.23.0) +
│                    #   one dir per plan topic, SHARED across every worktree;
│                    #   bare `.planning` is the reserved legacy repo-wide marker ← gitignored
│   └── <slug>/      #   plan.md (+ hidden .plan.md.opened sidecar)
│       │            #   a /mentor:defer stub is an ordinary plan dir born small —
│       │            #   same shape, same location, just origin:"deferred" (v2.17.0)
│       ├── .state.json # lifecycle state + relations (v2.17.0) — written only by plan-state.sh
│       ├── tour/      # /mentor:plan-tour artifacts — <area>-<perspective>.html (pre-approval walkthrough)
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
| `implemented` | Every `Done when:` passed and every Verification topic PASS, with each reported gap fixed, deferred, or explicitly accepted — a plan with no topics clears that vacuously, so it gets here only if you accept it unverified. |
| `failed` | Escalated after the remediation re-dispatch, or handed off with verification unresolved; the note says what broke or which topics are outstanding. |
| `superseded` | Replaced by its children via `/plan-split`. Sorted last. |
| *(no sidecar)* | `unknown` — a pre-2.4.0 plan. Never reported as "never approved". |

**The sidecar is a cache, not the only truth.** Reads take the *more advanced* of the
stored state and the state derived from the plan's `✅` step ticks — every step ticked
reads `implemented`, some reads `in_progress` — with one exception: a recorded `failed`
outranks the derivation, since only an orchestrator that watched something break writes
it, and an all-ticked plan must not read its way back out of that. That derivation
reports how far *implementation* got, not verification — the verifier dispatch runs
after the last step ticks, so an all-ticked plan reads `implemented` while its
Verification topics may still be outstanding. Since `dispatch-agents` already writes
those ticks, a forgotten state write costs nothing and old plan dirs read correctly with
no migration.

Group membership heals the same way: a split child's isolation header carries
`**Plan 3 of 5** · group \`…\``, and mentor parses `group`/`order` back out of it when
the sidecar is missing or torn. Delete a `.state.json` outright and the plan still
lists with the right state, group, and position — a plan dir needs nothing but its
`plan.md`.

> This is not a return to the v1.0.0 footer markers. Those were in-document contracts
> the model had to maintain by hand, and they broke when it forgot. The sidecar is
> written only by `hooks/plan-state.sh` and is *derivable from the plan file*, so
> forgetting is a no-op rather than a corruption.

### Sidecar schema

Every field is written only through `plan-state.sh`; older, shorter sidecars need no
migration — every reader defaults the fields it doesn't find.

| Field | Type | Written by | Since |
|---|---|---|---|
| `state` | one of 6 states | `init` / `set` | v2.4.0 |
| `group` | split-parent slug or `null` | `init --group` | v2.4.0 |
| `order` | int or `null` | `init --order` | v2.4.0 |
| `note` | free text, replaced each write | `set --note` | v2.4.0 |
| `deps` | array of plan slugs, default `[]` | `init --deps a,b` / `set-deps <slug> a,b` | v2.17.0 |
| `origin` | `"deferred"` or `null` | `init --deferred` sets it; `claim <slug>` clears it | v2.17.0 |
| `owner` / `owner_session` | wt-id + session id, or `null` | `ensure-dir` / `init` / `claim` | v2.23.0 |
| `priority` | `critical`\|`high`\|`medium`\|`low`\|`noise`, or `null` | `init --priority P` / `set-priority <slug> P` | v2.24.0 |
| `category` | `feature`\|`fix`\|`refactor`\|`docs`\|`tooling`, or `null` | `init --category C` / `set-category <slug> C` | v2.25.0 |
| `deferred_from` | a plan slug (unvalidated), or `null` | `init --from S` | v2.25.0 |

Omitting a flag **preserves** whatever is stored, which is what lets deps, origin,
ownership and priority all survive a later `set <slug> approved` untouched; passing one
with an explicit empty value **clears** it. `note` is the one exception — it is replaced
on every write, so a plain `set` deliberately clears a stale failure note.

`set-deps` replaces a plan's deps wholesale and refuses a write that would create a
dependency cycle (direct or transitive) — fail-soft: a stderr warning, no write.
Unknown dep slugs are allowed (the dep plan may not exist yet); `overview` marks them
`missing` rather than failing.

`priority` is the plan's **impact tier** — how much this plan matters, so
`/mentor:track`'s hierarchy can separate the work that counts from the noise. It is
orthogonal to the other two ordering fields: `order` sequences siblings *inside* a split
group, `deps` says what must be built *first*, and neither says whether a plan is worth
building at all. Unlike `deps`' arbitrary slugs the vocabulary is a **closed set**,
validated on write — the field exists so a renderer can bucket plans by tier, and an
unvalidated typo would silently become a sixth bucket. An unset priority stays `null` and
renders as absent, never as a default tier: "nobody has judged this plan" is a different
and more honest answer than `medium`. `set-priority <slug> ""` clears it back to unset.

`category` is the stub's **kind of work** — a closed set like `priority`, validated the same
way, deliberately excluding `test`/`verify`: a deferred stub captures work to build, never a
check to run, and a vocabulary with a testing entry would quietly invite the very thing the
scope rule rules out. `set-category <slug> ""` clears it back to unset, mirroring
`set-priority`.

`deferred_from` names the plan slug a stub was captured out of — unvalidated like `deps`'
targets, since the source plan may itself be deleted later. Unlike `deps`, `plan-state.sh`
carries **no** script-side `missing` flag for it: a dangling `deferred_from` is resolved
render-side, by `/mentor:track` checking the slug against the same `overview --json` array it
already holds, rendering `from: <slug> (missing)`.

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
JSON array covering every plan dir with a `plan.md` (state, group, order, `priority`,
`category`, `deps`, each marked `missing` when no such plan dir exists, `origin`,
`deferred_from`, live handoffs, ticked/total step counts, and `goal` — a one-line summary
computed only for `origin: "deferred"` entries, `null` otherwise; it is not a sidecar
field, it is extracted from the stub's own `## Goal` section at read time), plus topic
dirs with a live handoff but no `plan.md` yet, plus the legacy flat `.mentor/handoffs/`
dir. Computed fresh on every call — nothing is cached, so it can never drift from the
sidecars, plan ticks, or filesystem it reads. `/mentor:track` renders it as a hierarchy,
e.g.:

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
plan session — while this worktree's plan gate (`.planning.<wt-id>`, or a live
legacy `.planning`) is armed, the edit gate would block it here.

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

- **Warn** (default **200000** tokens) — a notice suggesting `/mentor:handoff`
  (→ `/mentor:resume` in a fresh session) or `/compact`; re-arms every ~50000
  tokens of further growth (a quarter of the warn threshold at defaults)
  rather than firing only once. Skipped entirely for harness-synthetic
  prompts (see below) — a fan-out-heavy stretch that runs almost entirely on
  inbound agent reports can sit in this band a long while with no nudge;
  `dispatch-agents`' verification failure loop re-checks context explicitly
  for that reason.
- **Warn-high** (default **90% of the ask threshold**, i.e. 315000) — a near-limit
  nudge that re-fires on every prompt: wrap the current unit of work and steer toward
  a natural handoff boundary; avoid opening new large workstreams.
- **Ask** (default **350000** tokens) — the agent must **ask you first** before acting
  on the prompt: **Hand off to next agent (Recommended)** writes the handoff doc right
  there and stops; **Proceed anyway** bypasses the gate for this session (a
  `.context-bypass-<session_id>` marker — warnings continue, and a fresh session
  re-arms the gate) and your original request runs immediately in the same turn.
  A fresh handoff note (<30 min old) suppresses the question — the advisory just
  points at `/mentor:resume`. Harness-synthetic prompts (inbound agent/teammate reports,
  task notifications, background-agent stop notices) get a loud advisory instead of a
  question, so autonomous flows are never stalled — and they never trigger a
  WARN re-arm, which belongs to your next real prompt.
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
| `MENTOR_PLANNING_INTENT=off` | `"planning_intent": "off"` | on | Disable the planning-intent advisory hook entirely (`off\|0\|false\|no`). |
| — | `"test_command"` | auto-detect | `/mentor:ship` Step 4's test command — set it where auto-detect guesses wrong (monorepos). No env-var twin. |

## How it works

| Piece | Role |
|---|---|
| `commands/plan.md` | The `/mentor:plan` trigger. |
| `hooks/begin-plan.sh` | Arms **this worktree's own** `.planning.<wt-id>` marker (v2.23.0; closes the gate for this worktree only — an optional `<slug>` argument WARNs if that slug is already owned by a live sibling worktree); prunes stale sibling markers with a per-marker notice; refuses over a live legacy `.planning` (distinct refusal message); prints the `MODE:` line (the approval-gate default), any live siblings as informational "also armed elsewhere" lines — and a `CONTEXT:` line: over the ask threshold it asks the user first (hand off, or bypass + lean plan) before arming. A foreign-marker refusal (a DIFFERENT, still-live session owns this worktree's own marker) names the supported recovery: re-run with `--override-foreign-marker` once the user explicitly authorizes it — the flag re-arms past the guard and still prints who it overrode; it is the confirmed-override route, never a way to skip the confirm itself. |
| `hooks/plan-gate.sh` | **The one gate.** Fail-closed `PreToolUse` on Write/Edit/MultiEdit/NotebookEdit — denies in-repo writes while THIS worktree's own marker or the legacy repo-wide marker exists, even under `bypassPermissions`; a live sibling worktree's marker never denies here. Mentor's own `.mentor/` tree (where the plan file lives) is exempt, so the plan is always writable. Stale markers (>8h) self-heal on a would-deny write, each with a named notice. |
| `hooks/approve-plan.sh` | Validates the plan (non-empty `.md` **newer than the marker**), releases this worktree's gate. Promotes only plans **owned** by this worktree (or unowned, when no sibling marker is live) — never a sibling's in-flight draft; a live legacy marker only sweeps repo-wide when the approving session is the one that armed it. Mode-agnostic — flags map to the approval options: no-arg implements, `--deliver` prints the deliverable soft-stop, `--handoff` the hand-off directive (both directives also print on a re-run when the gate is already open); unknown flags are rejected. |
| `hooks/plan-open.sh` | Auto-opens the plan for review the first time it is written (VSCode tab / OS default; HTML zoom artifacts in `.mentor/zooms/` open in the browser). |
| `hooks/set-mode.sh` | Get/set the approval-gate default. |
| `hooks/context-gate.sh` | **Context gate.** `UserPromptSubmit` — measures live context from the transcript: warns once (~200k), re-warns near the limit (~315k), and above ~350k asks the user — hand off (recommended) or bypass for the session. Never blocks or erases prompts. Fail-soft; slash commands always pass. |
| `hooks/bypass-context.sh` | Writes the session-scoped `.context-bypass-<session_id>` marker when the user answers "Proceed anyway" — degrades the ask tier to a one-line advisory for the rest of the session. |
| `hooks/planning-intent.sh` | **Planning-intent advisory.** `UserPromptSubmit` — a narrow, once-per-session, non-blocking nudge: an anchored opener ("help me plan…", "let's plan…") suggests `/mentor:plan <topic>` so a conversational planning ask doesn't silently skip the edit gate. Never blocks, never creates repo state; suppressed only while THIS worktree's own marker or the legacy marker is live — routed through the same liveness check as the gate, so a long-stale marker no longer suppresses it forever, and a sibling worktree's marker never suppresses it here. |
| `hooks/plan-state.sh` | **The one plan-state API** (not a hook — skills call it directly). `init` / `set` / `set-deps` / `set-priority` / `claim` / `tick` / `verify` / `list [--owners]` / `current [--any]` / `overview` / `context` / `dir` / `ensure-dir` / `gate` / `handoff-path` / `handoff-selfcheck`. `verify <slug>` backs planning's "Verify the write": fence-balance + table-pipe-count `CHECK:` lines that gate its exit code, plus informational-only `CHECK: Rev-note order` and `CHECK: context` lines (the latter folds the separately-mandated pre-approval context re-check into the same call). Sole writer of `.state.json` (incl. `deps` and `origin`, v2.17.0; `owner`/`owner_session` — the minting/re-owning worktree — v2.23.0, stamped by `ensure-dir`/`init`/`claim`; `priority` — the impact tier, v2.24.0, written by `init --priority`/`set-priority` and surfaced on every `overview` entry); derives effective state from the plan's ✅ ticks; `current` is group-aware and, since v2.23.0, ownership-scoped to plans owned by this worktree (`--any` for a deliberate repo-wide read) — after a split it reports the whole owned group rather than whichever child agent finished last. `list --owners` adds an OWNER column for slug-reuse scans. `overview --json` computes the repo-wide plans+deps+handoffs+owner hierarchy fresh on every call — nothing cached. `dir` (v2.14.0) is the one repo-scoped `.mentor` path derivation — skills call it instead of hand-rolling `git-common-dir` snippets that drift. `gate` is the one plan-gate marker status check for THIS worktree (`ARMED`/`STALE`/`ARMED_ELSEWHERE`/`RELEASED`, read-only; `--verbose` adds per-token fields, e.g. `owner_worktree=` on `ARMED` or one `elsewhere=` line per live sibling on `ARMED_ELSEWHERE`) — resuming/touring/plan-track call it instead of each re-deriving the marker path and 8h staleness window themselves. `handoff-path`/`handoff-selfcheck` back `handoff-note`'s Step 2/Step 5: the first resolves + confines + creates a topic's private `handoffs/` dir (+ gitignore) and prints the timestamped note path in one call; the second supersedes a topic's older notes into `resolved/` and prints both self-check verdicts atomically, so neither half of the check can be dropped by a partial hand-copy. |

### Commands and skills never share a name

Every command is a **thin entry point** whose body is a skill — and the two must never
carry the same name. When they do, `Skill({"skill": "mentor:<n>"})` resolves to the
COMMAND file and the skill body becomes unreachable: the call returns the command's own
text, the retry returns "already loaded above; instructions unchanged", and every
mandatory step inside the SKILL.md is silently skipped. The skill's `description:` is
shadowed by the command's too, so the skill cannot be reached conversationally either.

Hence the naming split: `/mentor:plan` → skill `planning`, `/mentor:resume` → `resuming`,
`/mentor:handoff` → `handoff-note`, and so on. **Command names are the user-facing
surface and never change; the skill takes the distinct name.**
`hooks/tests/test-skill-command-collision.sh` fails the build if any pair collides
again, if a rename leaves a skill's frontmatter `name:` behind, or if any `Skill()` call
site points at a skill that no longer exists. Prose could not enforce this — each
colliding command used to carry a written fallback for exactly this case, and it went
unused in practice.

### Known limitations

- **Bash is not gated.** The gate covers the Write/Edit/MultiEdit/NotebookEdit
  path (Claude's near-universal edit path); the skill instructs against
  repo-mutating shell commands during planning but does not enforce it.
- **Gates are per-worktree; plans stay shared (v2.23.0).** Each git worktree now
  arms and denies against its own `.planning.<wt-id>` marker
  (`lib/state.sh`'s `mentor_worktree_id`), so planning in one worktree no longer
  blocks writes in another. Every worktree still drafts into the SAME
  `.mentor/plans/` tree, and `approve-plan.sh` only promotes plans it **owns**
  (see "Unowned plans" below) — a sibling's in-flight draft is never swept.
  Two sessions in the SAME worktree still serialize on the one marker; that
  stays intentional.
- **A pre-upgrade bare `.planning` is a reserved legacy marker that blocks
  EVERY worktree**, fail-closed, until it is released or goes stale — only the
  session whose id matches the marker's `session=` can approve through it (a
  repo-wide sweep); every other session is refused and the marker is left
  untouched. `begin-plan.sh` refuses to arm a new per-worktree marker over a
  live legacy one (a distinct refusal message names it), so a worktree cannot
  end up racing both kinds of marker at once.
- **Unowned plans.** A plan's sidecar `owner` is stamped at creation
  (`ensure-dir`) and re-stamped by `init`/`claim` — the normal flow — but a
  plan can still be unowned (e.g. drafted, then `init` skipped). While ANY
  sibling worktree's marker is live, `approve-plan.sh` excludes unowned
  candidates from both "current plan" resolution and the promotion sweep,
  naming them rather than silently promoting or silently skipping them. With
  no sibling marker live, an unowned plan stays a promotion candidate (the
  original, solo-worktree behavior).
- **`git worktree move`/removal orphans state.** Moving or removing a worktree
  leaves its `.planning.<wt-id>` marker behind with nothing left to deny: in
  the moved tree the gate reads open silently (`mentor_worktree_id` now
  derives a different id there), and an approval run from the moved tree lands
  against that already-open gate, leaving the plan at `draft` instead of
  promoting it. Recovery: re-arm (`/mentor:plan`) and re-run `init` to re-own
  the plan in its new worktree. The same move can orphan a plan's sidecar
  `owner` (pointing at a wt-id that no longer resolves anywhere) — recovery is
  the same: `/mentor:plan <slug>` re-owns it via `init`.
- **An older cached plugin copy strips the newest keys.** `plan-state.sh`
  rebuilds `.state.json` as an explicit key-by-key object on every write, so a
  copy that predates a field drops it — an older cache strips
  `owner`/`owner_session` (v2.23.0) or `priority` (v2.24.0) the next time
  anything writes that sidecar. Each degrades to the field's own unset
  handling (unowned; untiered); nothing is corrupted and no other field is
  lost. It is also why a hand-added key of your own never survives: the
  rebuild only emits the fields the schema knows.
- **Same-slug concurrent drafting is unguarded beyond a warning.** Two
  worktrees can now draft the same slug at once (the old repo-global marker
  made this unreachable). `begin-plan.sh` and `plan-state.sh init`/`ensure-dir`
  WARN when a target slug is already owned by a worktree with a live marker,
  but nothing blocks the second worktree from writing anyway — coordinate
  manually.
- **`nosession` marker attribution.** A marker armed without
  `$CLAUDE_CODE_SESSION_ID` set records `session=nosession`, which cannot be
  told apart from any other `nosession`-armed marker — unchanged from before
  v2.23.0. The same gap affects the context gate's
  `.context-bypass-<session_id>` marker: a `nosession` bypass
  (`.context-bypass-nosession`) is indistinguishable across worktrees and
  leaks across them the same way.

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
| `plan-domain-frontend` | UX/UI — components, pages, styles, layout, design systems, theming, responsive; also a message/notification surface rendered by a third-party client (chat embed, push notification, email chrome) | ASCII zone wireframes + delta/token tables (a payload-shape table for a platform-rendered surface); live mockups authored by the zoom combo agent only in an opt-in HTML zoom. |
| `plan-domain-backend-api` | API/endpoint/route/handler/schema/DTO/contract — or the data model behind it: migration, table, column, index, constraint, enum, RLS policy | Before/after contract diff tables, schema diffs, Mermaid sequence flows; on a DDL change also a per-column delta table + a Mermaid ER diff of the changed entities. |
| `plan-domain-architecture` | Structural change — services, containers, datastores, queues, integrations, data flows (not pure content/config/doc/style/refactor) | Diff-highlighted C4-style Mermaid flowcharts, only the levels that change; a provenance list for any changed datastore field. |
| `plan-domain-dynamic` | No registered domain matched, and no already-available project/plugin skill names the technology (fallback) | A dispatched domain-definer names the domain and returns a best-practices brief; the plan gains a practice→step mapping. A substituted available skill can supply the brief instead. |

## Changes in v2.25.0

**Deferred stubs carry triage signals, and the plugin now enforces one rule everywhere it
routes work toward `/mentor:defer`: a deferred stub captures work to build, never a check
to run.** Before this, every stub rendered as a bare `○ <slug> draft (deferred)` line —
no purpose, no priority, no relation to the plan it came out of — and nothing stopped a
plan from stashing its own unresolved verification as a "verify X later" stub.

`.state.json` gains two fields, mirroring the v2.24.0 `priority` pattern exactly:
`category` (closed set `feature`/`fix`/`refactor`/`docs`/`tooling`, deliberately no
`test`/`verify` entry) and `deferred_from` (an unvalidated plan slug, like `deps`'
targets). `init` takes `--category`/`--from`; `set-category` joins `set-priority` as the
follow-up subcommand; `claim` clears `origin` as before but now also **keeps**
`category`/`priority`/`deferred_from`, so a claimed stub's triage history stays readable.

`/mentor:defer` (via the `deferring` skill) judges **priority**, **category**, and
**source plan** from the conversation's own evidence at capture time — the moment that
context still exists — leaving any of the three unset rather than inventing a default,
and reports what it judged inline:
`deferred → <slug> [<tier> · <cat>] (.mentor/plans/<slug>/) — from: <plan> — deps: <a>`.
`overview --json` appends `category`, `deferred_from`, and a computed `goal` key (a
one-line summary of the stub's own `## Goal`, `null` on non-deferred entries — see "The
repo-wide hierarchy" above); `/mentor:track` renders the tier and category as aligned tag
columns, a `from:` clause (`from: <slug> (missing)` when the source plan is gone), and a
`└ goal:` subline, extending the never-sort/never-filter rule to category too.

**The scope rule now runs through every funnel that routes work toward `/mentor:defer`** —
`dispatch-agents`' closing sweep and verification failure loop, `planning`'s oversize-plan
defer offers, `merging` and `resuming`'s flaky-test capture points, and `handoff-note`'s
close-out checklist. An unresolvable verification topic always ends `set <slug> failed
--note`, never a stub; a check that **ran** and confirmed a defect still lets its **fix**
defer, since a pre-existing bug found incidentally (a flaky test on the base branch, CI
broken before this work began) is ordinary work-to-build, not the check itself.

No auto-migration: this repo's pre-2.25.0 stubs keep `category`/`deferred_from` as `null`
and render exactly as before; backfill with `set-priority`/`set-category` while surveying
is a manual, one-time choice, not a requirement.

## Changes in v2.24.0

**Plans carry an impact tier.** `.state.json` gains `priority` — `critical`, `high`,
`medium`, `low`, `noise`, or `null` — so `/mentor:track`'s hierarchy can say which plans
matter and which are noise. Until now there was nowhere to put that: the sidecar was a
fixed key set that silently dropped anything hand-added on the next write, and `--note`
is replaced on every `set` and never surfaced by `overview --json`.

Written two ways: `init <slug> --priority <p>` at mint time, and `set-priority <slug>
<p>` for an existing plan (`""` clears it back to unset). `set-priority` is its own
subcommand for the same reason `set-deps` and `claim` are — `set <slug> <state>` takes
the state as a required positional, so a tier-only edit through it would have to restate
a state the caller never meant to touch. The tier then rides through every later write
untouched, under the same omitted-preserves contract that already carries `deps`,
`origin`, and ownership.

The vocabulary is a **closed set**, validated on write — deliberately unlike `deps`'
arbitrary slugs. The field exists so a renderer can bucket plans by tier, and an
unvalidated typo would silently become a sixth bucket. An invalid value is a usage error
(exit 1, nothing written), never a fail-soft skip: a tiering pass over twenty plans must
not report success having quietly dropped one.

`overview --json` carries `priority` on every entry, `null` where none is set —
including the `no_plan_topic` and `legacy_handoffs` kinds, so a consumer never branches
on kind to read it. An unset tier renders as **absent**, never as a default: "nobody has
judged this plan's impact" is a different and more honest answer than `medium`.
`/mentor:track` renders it as an aligned tag beside each entry and never sorts or filters
on it — a view of what's remaining that quietly hid the low tiers would be a lie in the
one place a user goes to trust it. Old sidecars need no migration, and `list`'s output is
byte-identical in both its shapes.

## Changes in v2.23.0

**The plan gate is now per-worktree — parallel development on one repo no longer
deadlocks.** Before this, the gate marker `<repo>/.mentor/plans/.planning` was one
file per repo: `mentor_repo_root` resolves via `git rev-parse --git-common-dir`, so
every linked worktree shared the same marker, and a session planning in one worktree
blocked every Write/Edit in every other worktree, including sessions that never armed
anything. `begin-plan.sh` also refused to arm a second marker over a live one, so a
second worktree couldn't even start its own plan — and `approve-plan.sh` swept **every**
`plan.md` newer than the marker, including a sibling worktree's still-drafting one.

Each git worktree now arms and is denied against its own marker,
`.mentor/plans/.planning.<wt-id>` (`wt-id` derived from the worktree name plus a
checksum of its real toplevel path — `lib/state.sh`'s new `mentor_worktree_id`). Plans
themselves stay **shared** in the one `.mentor/plans/` tree — this is not per-worktree
plan storage, only per-worktree gating. A pre-upgrade bare `.planning` (no suffix) is
reserved as the **legacy repo-global marker**: it still fail-closed blocks every
worktree until released or stale, and only the session that armed it (`session=` match)
can approve through it repo-wide — everyone else is refused, marker untouched.
Same-worktree serialization is unchanged and intentional: two sessions in one worktree
still contend for the one marker.

**Ownership closes the sweep hole.** A plan's sidecar `.state.json` gains `owner` +
`owner_session` (the worktree that minted or last re-owned it), stamped at three
points — `ensure-dir` (the instant a plan topic dir is created, closing the normal
unowned-draft window), `init` (last-init-wins re-owning, also how `/mentor:plan <slug>`
re-owns a plan resumed in a different worktree), and `claim` (deferred-stub
resurrection). `approve-plan.sh` now promotes only plans owned by the approving
worktree — and, whenever any sibling worktree's marker is live, excludes UNOWNED
candidates too, reporting them by name rather than silently promoting or silently
skipping them; with no sibling live, unowned plans stay promotable (solo back-compat).
Every failure message names the ownership situation ("owned by another worktree —
re-own with `/mentor:plan <slug>`") instead of a misleading "No Markdown plan found."

**`plan-state.sh gate` gains a fourth token, `ARMED_ELSEWHERE`.** The full contract is
now `ARMED` (this worktree's own marker or the legacy marker is live — a write here
would be denied) / `STALE` (exists but past the staleness window, not yet
pruned/healed) / `ARMED_ELSEWHERE` (no marker here, but a sibling worktree's is live —
an independent gate that does not block this worktree) / `RELEASED`. `--verbose` gains
a normative per-token field contract: `ARMED` reports `marker=` / `owner_session=` /
`owner_cwd=` / `owner_worktree=` / `age_min=` / `affected_plans=`; `ARMED_ELSEWHERE`
reports one `elsewhere=<wt-id> session=<sid> worktree=<path> age_min=<n>` line per live
sibling and nothing else; `STALE`/`RELEASED` stay bare tokens. Bare `gate` is
byte-unchanged (still exactly one token on line 1), so every existing `= "ARMED"`
check keeps working — and now correctly reads `ARMED_ELSEWHERE` as "not armed for me."
`current` is now ownership-scoped to plans owned by this worktree (or unowned), with a
new `--any` for a deliberate repo-wide read; `list` gains an opt-in `--owners` column;
`overview` carries an additive `owner` field.

**Every asking/reading skill now understands the difference between "armed here,"
"armed elsewhere," and "a pre-upgrade repo-wide lock."** `planning`'s Step 0 gate
check is rewritten for strict `ARMED` equality (a deliberate flip: `STALE` now reads
as NOT armed) with a guard so it never false-alarms outside a git repo, and its
slug-reuse scan uses `list --owners` to never mint a slug another worktree already
owns. `resuming` teaches that resuming a paused plan in a different worktree from the
one that armed it requires re-owning (`/mentor:plan <slug>` → `init`) before any
approval. `plan-track` hard-refuses approving a `draft` plan owned by a sibling
worktree (worktree B could otherwise promote and dispatch a draft worktree A is
mid-writing) while still allowing dispatch of already-`approved` work under
`ARMED_ELSEWHERE`, and renders ` [worktree: <id>]` on any listed entry owned by another
worktree. `constitution-authoring` treats `ARMED_ELSEWHERE` as NOT planning-active (so
constitution work doesn't re-deadlock repo-wide) while still honoring a live legacy
marker. `touring`/`plan-touring`/`zooming` exclude sibling-owned plans from subject
resolution so "the newest plan" can't silently resolve to a worktree you don't own.
`plan-review` notes its primary-subject resolution is automatically safe via the
now-scoped `current`, while its related-artifact enumeration deliberately stays
repo-wide (those paths are read-only labels, never write targets). `plan-split`
now mints every child's plan dir via the main thread's `ensure-dir` **before**
dispatching the authoring agents — stamping ownership at creation — and registers
(`init --group/--order`) each child **as it verifies**, not batched after all N;
otherwise every child would sit unowned and newer than every live marker for the
whole verification window (sweepable by a sibling's approve) and permanently unowned
if the split aborted partway.

**Known, documented, and deliberately not closed:** a pre-existing sidecar can be
orphaned by `git worktree move`/removal (recovery: re-arm + re-`init`); an older cached
plugin copy rebuilding `.state.json` from its pre-v2.23.0 key whitelist can strip
`owner` (degrades to the unowned handling, never corrupts); two worktrees can now draft
the same slug concurrently, guarded only by a WARN from `begin-plan.sh` and
`init`/`ensure-dir`; and `nosession` marker attribution (plus the pre-existing
`.context-bypass-nosession` cross-worktree leak) is unchanged. All are detailed under
"Known limitations" above.

## Changes in v2.22.0

**A plan's `## Verification` is no longer graded by the thread that wrote the work.**
Until now that section was free-form prose ("how to test end-to-end") and nothing in the
flow owned it: after the last implementation step, the main thread — the same context that
just orchestrated the build — skimmed its own prose. That is the weakest possible reviewer.
It knows what it *meant* to do, so it confirms rather than checks, and nothing ever forces
the question "what is missing?" to be asked at all.

Verification now runs the way `plan-review` already ran: `planning` authors the section as
2–6 single-focus topics (`Topic N — / Focus: / Checks: / Pass when:`, with an optional
`[model: · effort:]` annotation making a model upgrade a reviewable authoring decision), and
`dispatch-agents` executes it by dispatching **one fresh verifier agent per topic, all in a
single message**. Fresh is exact: never an implementation agent from this plan, never a
verifier reused across topics, never the agent that wrote a fix being re-verified.
Verifiers verify and never edit. Each returns `Verdict: PASS | FAIL` plus a **mandatory**
`Gaps / Missing:` section — concrete items or the literal `none found` — because the
explicit line is what forces the question to be asked; a return without it is not a verdict
yet. `plan-review` now flags a plan whose Verification section is missing, empty, or
malformed, so the defect is caught before approval rather than at execution.

**There is no escape hatch.** A plan that opened `Dispatch: skipped` still dispatches
verification — implementation may be main-thread, verification never is. The one sizing
allowance is lite verify: at ≤2 topics a single fresh verifier may carry both, reporting
per topic. A gap — or any non-`none found` gaps line, even on a PASS — surfaces to the user
as **one question for the round**: remediate now, or hand off to a fresh session (offered
before more context is spent, since verification lands when a session is at its largest).
Remediation is one dispatch plus a *fresh* re-verify, sequential when several topics fail;
a second failure escalates and records `failed`.

**A recorded `failed` can no longer be masked by step ticks.** Because verification runs
after every step is ticked, an escalated plan derived `implemented` from its ticks and
outranked the `failed` its orchestrator had just written — reporting success for a plan
that failed. `mentor_plan_state_rank` now ranks `failed` above `implemented`: a derivation
never overrules an explicit failure record, and only an orchestrator that watched something
break writes one. The hand-off branch records state too, so stopping mid-verification does
not read as done. `/mentor:track`'s `failed` recovery splits on the ticks accordingly —
unticked means it broke mid-implementation (retry from the first unticked step); all ticked
means it broke at verification (re-enter the round, stay `failed`).

## Changes in v2.21.0

**Every question stands on its own — now plugin-wide, not just in review.** v2.20.0 fixed
`/plan-review`'s questions; the other eleven skills that call `AskUserQuestion` still had no
such rule, so an interview could ask "G5 logs" or relay "It independently confirmed G14, G5
and G6 … D23 is cheaper" and leave the user to go find what those meant. One canonical
contract now travels with all thirteen asking surfaces — `grilling`, `plan`, `track`,
`plan-split`, `resume`, `zoom`, `tour`, `plan-tour`, `ship`, `merge`, `constitution`,
`dispatch-agents`, and `plan-review` (marked as its fullest statement): the user answers from
the question screen alone, never sent to a file, a plan section, a coined id or code, or an
earlier turn to learn what the question means. `grilling` carries the strongest form, since
it is what mints the ids — say "the cross-tenant Secrets read", not "G14"; a definition given
twenty turns ago is not one the user still has. `resume`'s note picker must say what a note is
*about* rather than restate its slug, and `track`'s plan options describe the work and its
state rather than a hierarchy position that scrolled away. `dispatch-agents` gains the relay
case: an agent's report is written for the orchestrator, so its finding codes, table rows, and
bare `Location(s)` cells get named, never pasted at the user.

**Ad hoc fan-outs are contract-bound.** A handoff note reading "no single mentor command owns
this — dispatch parallel `Explore` agents" led a session to issue nine raw `Agent()` calls with
no "Deliver before idling" block; seven to eight idled without delivering and the work was
redone by hand — the second session in a row to hit it. Five changes close the route: `resume`
now triggers on the keystroke (about to issue an `Agent()` call → load `mentor:dispatch-agents`
first, however the note phrased it) and reconciles direct dispatch against `/mentor:track` (a
research fan-out has no plan steps to tick; an implementing one still routes through track);
`resume`'s fallback command sweep matches bare `mentor:<skill>` tokens, not just
`/mentor:<command>`, so a note naming a skill is no longer dropped; `dispatch-agents` now
explicitly claims non-implementation fan-outs (research sweeps, gap audits) so the route stops
dead-ending at "this is for plan implementation", and its async-surface roster is refreshed
(`ship`, `merge`, `plan-tour`, `plan-split`, `resume` were dispatching or citing but unlisted);
`plan-split`'s child prompt template now carries the standing contract block verbatim — it had
the identical hole, with its missing-child re-dispatch loop absorbing the fallout; and
`handoff-note` writes an executable dispatch instruction instead of the sentence that caused
the failure.

## Changes in v2.20.0

**Review questions now stand on their own.** `/plan-review`'s fold gate and verdict walk
used to lead every question with a letter-number code (`P2`, `C3`) as the header and prefix,
and could point at plan locations by bare label ("Section B", "Step 3") — forcing the user to
scroll back or open the plan just to understand what was being asked. Both gates now name each
edit/finding by a 2–4 word plain-language **handle** ("rollback step", "edge-case tests") that
doubles as the header chip, and every question must be **self-contained**: plan locations are
described by what they do (quoting the plan's current sentence when the edit rewords text),
never by section label; earlier findings are restated in place, never cited by code or
position; a consistency finding's bare `Location(s)` cell is translated before it reaches the
user. Bulk options ("Fold in the rest"), "Other" free-text mapping, re-entry dedup, and the
closing report all follow the handles — the reviewer agents' internal output tables keep their
IDs, since those are never shown as questions.

## Changes in v2.19.0

**A plan can now be walked before it is approved.** mentor had two visual surfaces —
`/mentor:zoom` (static topic × perspective review pages) and `/mentor:tour` (a *published*
post-approval acceptance page where reviewers mark pass/not-pass). Neither told the story of
**how a plan will execute**, which is exactly what a reviewer needs *before* approving it.

`/mentor:plan-tour [plan slug] [area] [perspective]` builds a paged, local-only HTML
walkthrough: an opening context page, one page per implementation step, then a closing page of
done criteria and risks. One persistent inline-SVG diagram evolves from current to target state
as pages advance — class-toggling only, so paging back reverses the story — beside narrative
written for the perspective you name (free-form: "system architect", "on-call engineer",
whatever lens matters). Notes can be left per page and copied out as a self-identifying Markdown
report to paste back into the planning conversation.

Artifacts land in `.mentor/plans/<slug>/tour/<area>-<perspective>.html` and auto-open once, the
same way zooms do. **This is not acceptance touring:** `/mentor:tour` publishes an Artifact and
captures pass/not-pass verdicts on *delivered* work; plan tours are local, capture free text, and
preview *future* work. The two contracts stay mutually exclusive, and `.mentor/tours/` remains
deliberately excluded from auto-open.

## Changes in v2.18.0

**Every skill is now reachable.** Nine skills shared a name with their command
(`constitution defer handoff merge plan resume ship tour zoom`), which made
`Skill({"skill": "mentor:<n>"})` resolve to the *command* file — the SKILL.md body never
loaded. Observed live: `resume`'s secret-scan and gate/PR verification, and `handoff`'s
mandatory `CHECK:` self-verification, all skipped while the run reported success. The
same collision shadowed those nine skills' `description:` out of the model-visible skill
listing, so their trigger phrases were dead text and none could be reached
conversationally.

Each skill is renamed away from its command; **`/mentor:*` command names are unchanged**:

| Command | Skill (was) | Skill (now) |
|---|---|---|
| `/mentor:plan` | `plan` | `planning` |
| `/mentor:resume` | `resume` | `resuming` |
| `/mentor:handoff` | `handoff` | `handoff-note` |
| `/mentor:ship` | `ship` | `shipping` |
| `/mentor:merge` | `merge` | `merging` |
| `/mentor:tour` | `tour` | `touring` |
| `/mentor:plan-tour` | — *(new in v2.19.0)* | `plan-touring` |
| `/mentor:zoom` | `zoom` | `zooming` |
| `/mentor:defer` | `defer` | `deferring` |
| `/mentor:constitution` | `constitution` | `constitution-authoring` |

`grill`/`grilling` and `track`/`plan-track` were already split — they are the control
that proved the fix (they deliver their skill body on the first call).

**The ~110 lines of fallback prose are gone.** Each colliding command carried a block
telling the model to read the SKILL.md directly if the call returned the command's own
text. It was ignored in practice, and post-rename its premise is false, so it is deleted
rather than reworded. Enforcement replaces it:
`hooks/tests/test-skill-command-collision.sh` fails on any collision, any skill whose
frontmatter `name:` no longer matches its directory, and any `Skill()` call site pointing
at a nonexistent skill. See "Commands and skills never share a name" above.

**`planning`'s description is deliberately non-triggering.** Now that it is visible, it
states outright that a conversational planning ask must go through `/mentor:plan` (which
arms the edit gate first) — Step 0's `GATE: NOT ARMED` stop remains the fail-safe. The
trigger evals stage all twelve skills under their new names; `expected` ground truth was
re-pointed, and `merging`/`shipping` are now actually staged (two expectations were
previously unsatisfiable, so those cases could never pass).

**Smaller things:** `handoff` pasted `plan-state.sh list` in its "Current state" section
— `list` only tables topics that already have a `plan.md`, so work done outside a plan
printed "No plans …" and got reported as invisible to `/mentor:track`. It now pastes
`overview`, which is what `/mentor:track` itself reads, and offers `/mentor:defer` to
register a stub. `grilling` gained a concrete dispatch threshold (a second file, or any
read past ~100 lines, hands off to an `Explore` subagent) and a gated "the grill settled
it and the work is trivial → implement directly" close, valid only when no `.planning`
marker is armed.

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
implement. *(That split has since narrowed: end-to-end plan verification is
dispatched too, one fresh verifier agent per Verification topic — see the
`dispatch-agents` row under "Commands". Only per-step `Done when:` verification
is still the main thread's.)* Each agent gets one narrow, focused step (quality
through focus) and the main context stays lean (no implementation files loaded).
This extends the existing inline per-step `[role: … · model: … · effort: …]`
grammar — it is NOT
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
