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
   (subagent delegation suggested for big tasks), domain routing, then a
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
| `/mentor:grill [topic]` | One-question-at-a-time interview that sharpens a design's open decisions before you build. Conversation only; no repo edits. |
| `/mentor:handoff "<focus>"` | Compact the session into a handoff document (in `.mentor/handoffs/`, gitignored) for a fresh agent. Also offered as **Hand off to next agent** at the approval gate — leading the options when the context gate warns. |
| `/mentor:resume [slug\|number]` | List this repo's handoff notes and continue the chosen one. |
| `/mentor:tour [user\|dev\|both] [subject]` | **Post-approval acceptance review**: an editable guided-tour artifact — scenario cards with pass/not-pass toggles, feedback capture, and MD/JSON report export — published to a stable URL that revisions republish in place. Subject defaults to the newest plan; artifacts live in `.mentor/tours/` (gitignored). |
| `/plan-review`* | Fixed 4-topic review (practicality, comprehensiveness, cleanliness, and a spec-kit-`analyze`-style **consistency** check across the plan + related artifacts) of the current plan; also offered as **Review the plan (light)** at the proceed gate. |
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

State-dir layout (**project-scoped** — `<repo>/.mentor/`; per-plan dirs since v2.2.0):

```
<repo>/.mentor/
├── .gitignore       # commits config.json + constitution.md; ignores the rest
├── config.json      # {"mode": "plan|plan-only", + context-gate keys}   ← committed
├── constitution.md  # governing principles (/mentor:constitution)        ← committed
├── plans/           # the .planning marker + one dir per plan            ← gitignored
│   └── <slug>/      #   plan.md (+ hidden .plan.md.opened sidecar)
│       └── zoom/    #   <topic>-<perspective>.html opt-in zoom artifacts
├── handoffs/        # handoff notes (/mentor:handoff → /mentor:resume)   ← gitignored
└── tours/           # /mentor:tour review artifacts (<slug>-<audience>.html) ← gitignored
```

Only `config.json` and `constitution.md` are committed (team-shared); plans, handoffs,
tours and the transient markers are gitignored. Un-ignore `plans/` if you want plans
version-controlled. **Not in a git repo?** handoff/resume and the context gate fall
back to `~/.claude/mentor/_no-repo/`.

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
hook) measures the live context size from the session transcript and acts in two tiers:

- **Warn** (default **200000** tokens) — a one-time-per-session notice suggesting
  `/mentor:handoff` (→ `/mentor:resume` in a fresh session) or `/compact`.
- **Block** (default **270000** tokens) — plain prompts are refused (the prompt is
  erased) until you shrink the context. `/mentor:plan` additionally refuses to arm a
  plan in an already-over-block session (`begin-plan.sh`).

Escape hatches always pass: an empty prompt and any slash command (`/mentor:handoff`,
`/compact`, `/mentor:mode`, …) are never gated, so you can always reach the tools that
fix the problem. Everything is fail-soft — no `jq`, no transcript, or an unreadable
transcript simply lets the prompt through.

> **Note:** the gate is a **long-context / 1M-window backstop**. On a standard 200k
> window with auto-compact enabled it may never fire (auto-compact triggers ~155–165k,
> below the 200k warn default). Raise `context_block_tokens` per-repo when you
> intentionally run long-context sessions.

Knobs — env vars under `env` in `~/.claude/settings.json` (or the project's
`.claude/settings.json`), or per-repo keys in `.mentor/config.json`. Precedence:
**env var > `.mentor/config.json` key > default**.

| Env var | `.mentor/config.json` key | Default | Effect |
|---|---|---|---|
| `MENTOR_CONTEXT_GATE=off` | `"context_gate": "off"` | on | Disable the gate entirely (`off\|0\|false\|no`). |
| `MENTOR_CONTEXT_WARN_TOKENS` | `"context_warn_tokens"` | `200000` | Warn threshold (tokens). |
| `MENTOR_CONTEXT_BLOCK_TOKENS` | `"context_block_tokens"` | `270000` | Block threshold (tokens). |
| `MENTOR_CONTEXT_TAIL_LINES` | — | `400` | Transcript tail window scanned for the measurement. |

## How it works

| Piece | Role |
|---|---|
| `commands/plan.md` | The `/mentor:plan` trigger. |
| `hooks/begin-plan.sh` | Arms the `.planning` marker (closes the gate); prints the `MODE:` line (the approval-gate default) — and a `CONTEXT:` line, refusing to arm when the session is already over the block threshold. |
| `hooks/plan-gate.sh` | **The one gate.** Fail-closed `PreToolUse` on Write/Edit/MultiEdit/NotebookEdit — denies in-repo writes while the marker exists, even under `bypassPermissions`. Mentor's own `.mentor/` tree (where the plan file lives) is exempt, so the plan is always writable. Stale markers (>8h) self-heal. |
| `hooks/approve-plan.sh` | Validates the plan (non-empty `.md` **newer than the marker**), releases the gate. Mode-agnostic — flags map to the approval options: no-arg implements, `--deliver` prints the deliverable soft-stop, `--handoff` the hand-off directive (both directives also print on a re-run when the gate is already open); unknown flags are rejected. |
| `hooks/plan-open.sh` | Auto-opens the plan for review the first time it is written (VSCode tab / OS default; HTML zoom artifacts open in the browser). |
| `hooks/set-mode.sh` | Get/set the approval-gate default. |
| `hooks/context-gate.sh` | **Context gate.** `UserPromptSubmit` — measures live context from the transcript and warns once (~200k) then blocks plain prompts (~270k), steering to `/mentor:handoff` or `/compact`. Fail-soft; slash commands always pass. |

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

**Optional HTML zoom:** when you explicitly ask for an HTML preview/zoom, mentor
never renders the whole plan as one file — it first resolves **topic(s) ×
perspective(s)** (end user / implementor / reviewer-architect / QA-tester),
asking for whichever dimension your request didn't name, then dispatches one
agent per topic × perspective combination. Each writes its own supplementary
`plans/<slug>/zoom/<topic>-<perspective>.html` inside the plan's own dir — a
throwaway, self-contained visual aid for that topic through that lens. The `.md`
stays the source of truth.

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
| `plan-domain-frontend` | UX/UI — components, pages, styles, layout, theming | ASCII zone wireframes + delta/token tables; live mockups authored by the zoom combo agent only in an opt-in HTML zoom. |
| `plan-domain-backend-api` | API/endpoint/route/handler/schema/DTO/contract | Before/after contract diff tables, schema diffs, Mermaid sequence flows. |
| `plan-domain-architecture` | Structural change — services, containers, datastores, integrations | Diff-highlighted C4-style Mermaid flowcharts, only the levels that change. |
| `plan-domain-dynamic` | No registered domain matched (fallback) | A dispatched domain-definer names the domain and returns a best-practices brief; the plan gains a practice→step mapping. |

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
