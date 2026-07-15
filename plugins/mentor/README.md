# mentor

A lean planning harness for Claude Code. One enforcement mechanism: `/mentor:plan`
arms a repo-scoped `.planning` marker, and a single fail-closed `PreToolUse` hook
blocks every repo edit — even under `bypassPermissions` — until the plan is
approved. Plans are **Mermaid-first Markdown** documents persisted **outside the
repo**, with required per-topic visualizations and a mandatory **Use case
scenarios** section proving the plan understood the request. They auto-open for
review and are the single source of truth for implementation, handoff, and review.

## Quick start

```
/mentor:mode plan-only        # optional: persist a repo WORKING MODE (plan | plan-only)
/mentor:grill <topic>         # optional: sharpen open design decisions before you plan
/mentor:plan <what you want to build>
```

`/mentor:plan`:

1. Runs `begin-plan.sh`, which writes the repo-scoped `.planning` marker — **arming
   the edit gate**. From here, repo source edits are blocked until approval.
2. Follows the `plan` skill: optional clarify (grilling), research
   (subagent delegation suggested for big tasks), domain routing, then a
   Markdown plan written to `~/.claude/mentor/<repo>-<hash>/plans/<slug>.md`.
3. At approval, runs `approve-plan.sh` — it validates the plan (non-empty, and
   newer than the marker, so a stale plan from a prior session can never release
   the gate) and deletes the marker. The gate opens; implementation begins.

> `/mentor:plan` is **namespaced** — it cannot collide with Claude Code's native
> reserved `/plan` command.

## Commands

| Command | What it does |
|---|---|
| `/mentor:plan <task>` | The gated plan flow (above). |
| `/mentor:constitution [principles]` | Create/amend this repo's governing principles at `.mentor/constitution.md` — versioned, committed, and honored by every plan. |
| `/mentor:mode [plan\|plan-only\|status]` | Get/set the persisted repo working mode. |
| `/mentor:ship` | Finish the current branch: clean-check → `/simplify` → optional tests → push + auto-open PR/MR (or push to upstream). Never force-pushes. |
| `/mentor:grill [topic]` | One-question-at-a-time interview that sharpens a design's open decisions before you build. Conversation only; no repo edits. |
| `/mentor:handoff "<focus>"` | Compact the session into a handoff document (outside the repo) for a fresh agent. Also offered as **Hand off to next agent** at the proceed gate. |
| `/mentor:resume [slug\|number]` | List this repo's handoff notes and continue the chosen one. |
| `/plan-review` | Fixed 3-topic review (practicality, comprehensiveness, cleanliness) of the current plan; also offered as **Review the plan (light)** at the proceed gate. |
| `/dispatch-agents` | The annotation grammar for fanning a plan out to subagents, and how to execute the dispatches after approval. |

## Repo modes (`/mentor:mode`)

The mode persists in `~/.claude/mentor/<repo>-<hash>/config.json`:

| Mode | Behavior |
|---|---|
| `plan` | Default: `/mentor:plan` plans, then executes on approval. (Does **not** force planning — it names the default flow.) |
| `plan-only` | Plans are the deliverable: after approval execution **soft-stops** — no implementation, no dispatch. |

State-dir layout:

```
~/.claude/mentor/<repo>-<hash>/
├── config.json     # {"mode": "plan|plan-only"}
├── plans/          # <slug>.md plan + the .planning marker (+ *.opened sidecars)
└── handoffs/       # handoff notes (/mentor:handoff → /mentor:resume)
```

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

## How it works

| Piece | Role |
|---|---|
| `commands/plan.md` | The `/mentor:plan` trigger. |
| `hooks/begin-plan.sh` | Arms the `.planning` marker (closes the gate); prints the `MODE:` line. |
| `hooks/plan-gate.sh` | **The one gate.** Fail-closed `PreToolUse` on Write/Edit/MultiEdit/NotebookEdit — denies in-repo writes while the marker exists, even under `bypassPermissions`. The plan file lives outside the repo, so it is always writable. Stale markers (>8h) self-heal. |
| `hooks/approve-plan.sh` | Validates the plan (non-empty `.md` **newer than the marker**), releases the gate. `--handoff` prints a hand-off directive instead of implementing; plan-only mode prints a soft-stop directive. |
| `hooks/plan-open.sh` | Auto-opens the plan for review the first time it is written (VSCode tab / OS default; HTML zoom artifacts open in the browser). |
| `hooks/set-mode.sh` | Get/set the repo working mode. |

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

**Optional HTML zoom:** when you explicitly ask to zoom into a specific topic or
area for visual review (a UI surface, a flow, an architecture slice), a
supplementary `<slug>-<topic>.html` is written next to the `.md` — a throwaway,
self-contained visual aid for that area only. The `.md` stays the source of truth.

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
| `plan-domain-frontend` | UX/UI — components, pages, styles, layout, theming | ASCII zone wireframes + delta/token tables; live mockups via a dispatched mockup-author only in an opt-in HTML zoom. |
| `plan-domain-backend-api` | API/endpoint/route/handler/schema/DTO/contract | Before/after contract diff tables, schema diffs, Mermaid sequence flows. |
| `plan-domain-architecture` | Structural change — services, containers, datastores, integrations | Diff-highlighted C4-style Mermaid flowcharts, only the levels that change. |
| `plan-domain-dynamic` | No registered domain matched (fallback) | A dispatched domain-definer names the domain and returns a best-practices brief; the plan gains a practice→step mapping. |

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

Stale state from older versions (`orchestrator`/`format` keys in `config.json`,
old marker sidecars, legacy `~/.claude/mentor/plans/` dirs) is simply ignored.

## Requirements

`jq`, `git`, and `python3` (only as a `realpath` fallback for path canonicalization).

## Attribution

The `grilling` (`/mentor:grill`) and `handoff` (`/mentor:handoff`) skills are adapted from
[mattpocock/skills](https://github.com/mattpocock/skills) (the `productivity` skill set), reworked
to fit mentor's conventions, namespacing, and gates.
