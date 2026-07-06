# mentor

A plugin-owned planning harness for Claude Code. It runs its **own** read-only plan phase —
gated by a fail-closed marker hook that holds even under `bypassPermissions` — so you get
enforced "no edits until approved" planning **without** relying on Claude Code's native plan
mode. Plans are persisted as a single self-contained document — **your choice** of a bespoke
**styled-HTML** doc (a per-plan theme, live mockups, animation) or a **Mermaid-first Markdown** doc
(portable; renders on GitHub/GitLab), via [`/mentor:plan-output-format`](#plan-output-format-mentorplan-output-format).
Either way it carries required per-topic visualizations + a mandatory **Use case scenarios** section
proving the plan understood the request, auto-opens for review, and serves as the single source of
truth for every downstream hook. **An HTML plan lives only until approval:** the moment you confirm
the plan, its canonical Markdown is extracted into `<slug>.md` and the `.html` is deleted — the lean
`.md` is the plan file implementation (and every later consumer) reads, so the heavy rendered HTML
never burns context after review. (Exception: `plan-only` repos keep the styled HTML — there the
plan file is the deliverable and nothing downstream consumes it.)

## Quick start

```
/mentor:mode plan-only        # persist a repo WORKING MODE (plan | plan-only)
/mentor:plan-output-format md # persist the plan OUTPUT FORMAT (md | html) — asked once if unset
/mentor:orchestrator on       # orthogonal toggle: force always-orchestrate (repo or global)
/mentor:grill <topic>         # optional: sharpen open design decisions before you plan
/mentor:plan <what you want to build>
```

This is the entry point. It:

1. Runs `begin-plan.sh`, which writes the repo-scoped `.planning` marker — **arming the edit
   gate**. From here, repo source edits (and repo-writing Bash) are blocked until approval.
2. Follows the `mentor-plan` skill: a 4-option strategy question, **mandatory research
   dispatch** (Step 1.5), then a bespoke-themed HTML plan.
3. At approval, runs `approve-plan.sh` (validate → release the gate → emit the dispatch directive
   for dispatch strategies). No `ExitPlanMode`, no native `.md` plan file.

> `/mentor:plan` is **namespaced** — it cannot collide with Claude Code's native
> reserved `/plan` command (which would launch native plan mode, the thing this harness replaces).

## Repo modes (`/mentor:mode`) — persisted per repo

```
/mentor:mode plan | plan-only   # set the WORKING MODE
/mentor:mode [status]           # show (UNSET → the model asks and persists)
```

The mode lives in `~/.claude/mentor/<repo>-<hash>/config.json` and is the **single source of
truth** — there is no session toggle and no env switch.

| Mode | Behavior |
|---|---|
| `plan` | Today's default: `/mentor:plan` plans, then executes on approval. **Note: `plan` does not force planning** — it names the default flow. |
| `plan-only` | Plans are the deliverable: `/mentor:plan` runs the full harness, but after approval execution **soft-stops** — no implementation, no dispatch (the gates still open; it is an instruction-level stop, not a hard gate). |

> **`commander` is no longer a mode** (it was, pre-0.37). Always-orchestrate is now the orthogonal
> **orchestrator toggle** — see [Orchestrator toggle](#orchestrator-toggle--session-wide-orchestration)
> below. `mode` and `orchestrator` are independent: e.g. `plan` + orchestrator ON, or `plan-only`
> + orchestrator OFF.

State-dir layout (the legacy `~/.claude/mentor/plans/<repo>-<hash>/` dir is auto-migrated on first
hook contact; a legacy `{"mode":"commander"}` config auto-migrates to `{"mode":"plan","orchestrator":true}`):

```
~/.claude/mentor/config.json     # {"orchestrator": true|false} — GLOBAL toggle
~/.claude/mentor/<repo>-<hash>/
├── config.json     # {"mode": "plan|plan-only", "orchestrator": true|false, "format": "md|html"} — repo policy
└── plans/          # plan file (HTML or Markdown) + markers (.planning, .research-dispatched, …)
```

### Viewing the plan

The plan auto-opens for review the first time it is written (`plan-open.sh`):

- **Inside VSCode** (Claude Code running in the integrated terminal): the plan opens as a
  **focused editor tab** via the VSCode CLI. To render it in the **integrated browser**, install
  Microsoft's [**Live Preview**](https://marketplace.visualstudio.com/items?itemName=ms-vscode.live-server)
  extension and set, in your VSCode settings:
  ```jsonc
  "livePreview.openPreviewTarget": "Embedded Preview",
  "livePreview.useIntegratedBrowser": true
  ```
  then click **Show Preview** in the editor title bar (or ⇧⌘P → *Live Preview: Show Preview*)
  on the open plan tab. (There is no headless way to fire VSCode's integrated browser from a
  hook, so the render is one keystroke.)
- **Outside VSCode:** an **HTML** plan opens in **Google Chrome**, falling back to your OS default browser.
- **Markdown (`md`) plans** open as a **VSCode editor tab** (toggle preview with ⇧⌘V; install a Mermaid preview extension to render the diagrams) or, outside VSCode, the **OS default Markdown handler** — never a raw-text browser tab (Chrome is deliberately skipped for `.md`).

Knobs — set under `env` in `~/.claude/settings.json` (a shell `export` won't reach the hook):

| Var | Effect |
|---|---|
| `MENTOR_PLAN_OPENER` | `auto` (default) · `vscode` · `chrome` · `system` (legacy OS-default opener) |
| `MENTOR_PLAN_VSCODE_BIN` | Force the VSCode CLI binary (default: auto-detect `code` / `code-insiders` / `cursor` / `windsurf` / `codium`) |
| `MENTOR_PLAN_OPEN=off` | Disable auto-open entirely |

## Plan output format (`/mentor:plan-output-format`)

```
/mentor:plan-output-format md | html   # set the OUTPUT FORMAT
/mentor:plan-output-format [status]     # show (UNSET → the model asks and persists)
```

The format persists per repo in `~/.claude/mentor/<repo>-<hash>/config.json` (the `format` key,
alongside `mode`/`orchestrator`). There is **no baked-in default** — the first `/mentor:plan` in a
repo asks once (Markdown / HTML) and persists your choice. An env override
`MENTOR_PLAN_FORMAT=md|html` (under `env` in `~/.claude/settings.json`) wins over the persisted
value. Existing repos are unaffected until they opt in — when unset, the gates resolve the original
`.html` deliverable.

| Format | Deliverable |
|---|---|
| `html` | A single **self-contained styled HTML** document — a bespoke per-plan theme, **live before/after `<iframe>` mockups** (frontend), purposeful animation, in-place self-refresh. The original deliverable; richest review surface. **Review-time only:** at approval it is finalized — the canonical Markdown is extracted to `<slug>.md` and the `.html` is deleted; implementation reads the `.md` (plan-only repos keep the HTML — it is the deliverable there). |
| `md` | A single **self-contained Markdown** document. Visualization is **Mermaid-first** (` ```mermaid ` flowchart/sequence/ER/state/class), with **ASCII diagrams**, **GFM tables**, and **GFM alerts**. The `.md` *is* its own canonical source (footer markers at end-of-file, dispatch annotations inline — no embedded `plan-source` block). Portable: renders richly on GitHub/GitLab and in any Mermaid-capable Markdown viewer. |

**Markdown visualization idiom** — one artifact per change, never two representations of one thing:
tabular data → **GFM table**; topology / sequence / state → **Mermaid**; spatial layout or a
Mermaid-unsupported idiom → **ASCII** in a code fence; callouts → **GFM alerts**. C4 architecture
uses a Mermaid `flowchart` + `classDef` + legend table (not the experimental `C4Context`, which
GitHub/GitLab don't render).

**Markdown limitations** (vs HTML — choose knowingly): no live `<iframe>` mockups (frontend degrades
to a delta table + ASCII wireframe + token table), no animation, no scroll/panel-preserving
self-refresh, single-column layout, and platform styling instead of a bespoke theme. **VSCode's
built-in Markdown preview needs a Mermaid extension** to render the diagrams (GitHub/GitLab render
them natively).

## How it works

| Piece | Role |
|---|---|
| `commands/plan.md` | The `/mentor:plan` trigger. |
| `hooks/begin-plan.sh` | Arms the `.planning` marker (closes the gate); clears stale flags. |
| `hooks/plan-phase-gate.sh` | **Fail-closed** PreToolUse gate (Write/Edit/NotebookEdit/Bash). Marker-driven and mode-independent — denies in-repo writes during planning even under `bypassPermissions`. Allows the HTML plan write (it lives outside the repo). |
| `hooks/research-dispatch-tracker.sh` | Records subagent dispatches: `.research-dispatched` on any dispatch, and `.plan-authored` when a **plan-author** is dispatched (prompt token `mentor:plan-author`, or a `Plan` agent). |
| `hooks/plan-read-gate.sh` | **Always-delegate-RESEARCH floor:** ~2 free reads, then blocks bulk reads until a research subagent is dispatched — keeps the main conversation lean. |
| `hooks/plan-author-gate.sh` | **Always-delegate-AUTHORING floor:** blocks the plan-file write until a **plan-author** subagent has been dispatched — the main thread renders the returned body, it never drafts the plan. |
| `hooks/plan-html-stop-gate.sh` | **Persist-the-plan floor (Stop):** once the plan-author has returned, the turn cannot end until the plan file is written — in every mode the plan file (HTML or Markdown, per format) is the deliverable, not the chat text. |
| `hooks/approve-plan.sh` | Validates the plan (via `strategy-guard.sh`), releases the gate, **finalizes the plan** (via `plan-finalize.sh`), prints the dispatch directive. With `--handoff`: same validation + gate release + finalize, but prints a hand-off directive (write a `/mentor:handoff` doc, then stop) and **suppresses dispatch** — for any strategy. |
| `hooks/plan-finalize.sh` | **Approval-time finalizer:** given the explicit, just-validated plan (`--plan <path>` — never "newest `*.html`", so stale HTMLs from abandoned sessions are never resurrected), extracts the canonical Markdown from its `plan-source` block into `<slug>.md`, deletes the `.html` (+ its `.opened` sidecar), and pre-marks the `.md` as opened (no second review tab). Runs from `approve-plan.sh` (owned flow) and `dispatch-executor.sh` (native `PostToolUse:ExitPlanMode`); fail-soft, no-op for `.md` targets, **skipped in plan-only mode** (the plan file is the deliverable there). |

### Always-delegate planning (context optimization)

During the plan phase the main thread does **no bulk codebase reading and does not draft the
plan** — it *orchestrates*. It dispatches `Explore` subagents for research (FINDINGS + `file:line`
evidence only, no file dumps), then dispatches a **plan-author** `Plan` agent that **returns the
complete plan body**; the main thread only renders that returned Markdown into the plan file and
releases. Two hard floors enforce this:

- `plan-read-gate.sh` — ~2 free reads, then bulk reads are blocked until a research subagent is
  dispatched. Escape hatch: `MENTOR_PLAN_RESEARCH=off`.
- `plan-author-gate.sh` — the plan-file write is blocked until a plan-author subagent (prompt
  token `mentor:plan-author`, or a `Plan` agent) has been dispatched. Escape hatch:
  `MENTOR_PLAN_AUTHOR=off`.

### Strategies

Normal · Dispatch · Worktree · Worktree+Dispatch. Worktree strategies allocate an isolated
branch worktree (env files seeded automatically). Dispatch strategies fan the plan out into
annotated subagent steps.

### Domain planning skills

Every plan gets domain treatment. When the task touches a registered domain, `mentor-plan`
invokes that domain's planning skill **once** (registry at the top of Step 1.5 — same `Skill()`
mechanism as `/plan-review`). The domain skill shapes the research dispatch, the plan-author
prompt, and the plan's extra deliverable (rendered per format — Step 8/8M). Instruction-only — no new hooks; when no
registered domain matches, the **dynamic fallback** routes the plan instead (last table row).

| Domain | Triggers | Extra plan-HTML deliverable |
|---|---|---|
| `plan-domain-frontend` | UX/UI — components, pages, styles, layout, design systems, theming | **Live before/after HTML/CSS mockups** per changed surface, built from the project's REAL design tokens/fonts by a dispatched mockup-author agent (prompt token `mentor:frontend-mockup`, runs after the plan-author). Panes render in style-isolated `<iframe srcdoc>` frames; the canonical `plan-source` block carries a prose stand-in only. Honors the global rules: invokes `frontend-design:frontend-design` first, derives only from real source files, never creates mockup files in the repo. |
| `plan-domain-backend-api` | API/endpoint/route/handler/schema/DTO/contract | **Before/after API contract diff tables** (method/path/request/response/status), schema diffs per changed DTO, and a sequence-flow viz per changed flow — plain Markdown, present in both the body and `plan-source`. No extra agent. |
| `plan-domain-dynamic` | **No registered domain matched** (fallback) | A small **domain-definer agent** (prompt token `mentor:domain-dynamic`, dispatched before research) names the task's domain on the fly and returns a compact DOMAIN BRIEF — global best practices, research/author directives, viz idiom, pitfalls. The plan gains a **`Domain best practices applied`** section (practice→step mapping, plain Markdown in body + `plan-source`). |

Domain detection is LLM judgment, not a hard rule set — borderline tasks may route to a
registered domain in one session and the dynamic fallback in another. Either way the plan gets
domain-expert shaping, the mandatory **Use case scenarios** section, and prose written for a
generalist reviewer.

### Other commands

- `/mentor:grill [topic]` — relentless one-question-at-a-time interview that **sharpens a plan or design's open decisions before you build**. Conversation only; makes no repo edits; explores the codebase via a dispatched subagent. Distinct from `/plan-review`: **grill sharpens the decisions before a plan is locked; `/plan-review` audits the finished plan at the approve gate.** Naturally runs upstream of `/mentor:plan`.
- `/mentor:handoff "<next-session focus>"` — compact the conversation into a **handoff document** (saved outside the repo, under the per-repo mentor dir) for a fresh agent: summary + current state + recommended next-step mentor commands + artifacts referenced by path, with secrets redacted. Also offered as a **Hand off to next agent** option at the owned-flow proceed gate (approve + release the gate, write the handoff doc, then stop — no dispatch this session).
- `/mentor:resume [slug|number]` — the **consume** side of `/mentor:handoff`: lists **this repo's** saved handoff notes (newest first), lets you pick one (by slug/number argument or interactively), then loads it and continues the work per its recommended mentor commands. Strictly repo-scoped; scans the note for secrets before surfacing it.
- `/plan-review` — a fixed 3-topic review of the current plan; also offered as a **Review the plan (light)** option at the owned-flow proceed gate, which loops back to re-ask without releasing the edit gate.
- `/ship` — worktree-aware finish that auto-opens the MR/PR on push.
- `/dispatch-agents` — decompose a plan into annotated subagent dispatches.
- `/plugin-ops:harvest` — analyze the finished session and turn repeated manual work into reusable artifacts (**moved to the `plugin-ops` plugin in v0.45.0** — see below).
- `/mentor:mode [plan|plan-only|status]` — get/set the persisted **repo working mode** (see above).
- `/mentor:plan-output-format [md|html|status]` — get/set the persisted **plan output format** (see [above](#plan-output-format-mentorplan-output-format)).
- `/mentor:orchestrator [on|off|status|clear] [global]` — toggle the orthogonal **orchestrator** flag (see below).

### Harvest — moved to `plugin-ops` (v0.45.0)

The harvest capability (`/harvest` command + `harvest-automations` skill) **moved to the
`plugin-ops` plugin** in mentor v0.45.0 — it is session-lifecycle tooling, not planning. Invoke it
as `/plugin-ops:harvest [optional session-id or transcript .jsonl]` (unqualified `/harvest` also
resolves while unique). Behavior is unchanged: it analyzes a session transcript, detects repeated
manual work, and creates/updates the smallest set of Claude Code artifacts (skills, commands,
agents, hooks, permissions, rules, …) that removes it. Requires `plugin-ops@private-marketplace`
to be enabled where you run it. Mentor's orchestrator still exempts the harvest flow (the flow
flag now matches `/plugin-ops:harvest` and bare `/harvest`).

## Orchestrator toggle — session-wide orchestration

```
/mentor:orchestrator on            # turn ON for this repo
/mentor:orchestrator off           # explicit repo OFF (overrides a global ON)
/mentor:orchestrator on global     # turn ON globally (every repo, unless it sets its own)
/mentor:orchestrator clear         # delete the repo value → re-inherit the global/default
/mentor:orchestrator status        # show resolved state + raw repo/global values
```

Orchestrator is an **orthogonal toggle**, not a working mode. Where the plan harness enforces
*always-delegate* only during the plan phase, the orchestrator toggle generalizes it to the
**whole session**. When ON, the main conversation becomes a pure **orchestrator**: it dispatches
subagents for *all* substantive work — research, planning, and **every repo edit** — verifies
their returns, and does no heavy lifting itself. This fills the gap after a plan is approved (and
for ad-hoc tasks with no plan), forcing implementation through agents too.

**Scope & precedence.** It persists as `{"orchestrator": true|false}` per-repo
(`~/.claude/mentor/<repo>-<hash>/config.json`) and globally (`~/.claude/mentor/config.json`).
Resolution: **explicit repo value > legacy `mode:commander` > global value > OFF.** So a repo
`off` overrides a global `on`; `clear` deletes the scope's key to re-inherit the lower one. A
global `on` takes effect **only inside a git repo** (the gate is repo-scoped — outside a repo
there is nothing to gate).

It is enforced by hard `PreToolUse` hooks (not advice):

| Piece | Role |
|---|---|
| `hooks/orchestrator-gate.sh` | The gate (Read/Grep/Glob/Write/Edit/MultiEdit/NotebookEdit/Bash). Blocks the **main** conversation's in-repo Write/Edit + repo-mutating Bash, and bulk in-repo reads past a per-turn budget. **Subagents run freely** (detected via `agent_id` / `transcript_path` ~ `/subagents/`), so there is no deadlock. |
| `hooks/orchestrator-prompt.sh` | `UserPromptSubmit`: owns the operational session state (read budget, dispatch flag, flow-exempt marker), runs the one-shot legacy-config migration, emits a one-line reminder, and injects a **condensed** orchestrator playbook once per session (never the whole SKILL.md). |
| `hooks/orchestrator-dispatch-tracker.sh` | `Agent\|Task`: once the orchestrator dispatches this turn, **reads unlock** so it can read returned artifacts and verify. |
| `skills/orchestrator/SKILL.md` | The orchestrator playbook (triage → dispatch → verify), invokable via `Skill(skill="orchestrator")`. Defers the dispatch grammar to `dispatch-agents`. |

**Pragmatic, not draconian.** The orchestrator may still: read a few files per turn to orient,
read returned artifacts (`/tmp`, `~/.claude/mentor/**`, anything outside the repo — uncounted),
and run **read-only** verification Bash (`git`, `gh`, tests, builds, `cat`/`grep`). It must
delegate all edits and bulk research.

**Exempt flows** run unimpeded even with orchestrator ON: `/mentor:plan` (its own gates own the
plan phase), `/ship`, `/plugin-ops:harvest`, and `/simplify`.

**Knobs:** `MENTOR_ORCHESTRATOR_READ_FREE` (in-repo reads per turn before the nudge; default 3),
`MENTOR_ORCHESTRATOR_ARTIFACT_DIRS` (comma-separated repo-relative build/output dirs Bash may
write to — default `node_modules,dist,build,coverage,.next,target,__pycache__,.pytest_cache,…`).
On/off is the resolved repo/global config (`/mentor:orchestrator`). With orchestrator OFF (the
default), every gate short-circuits — behavior is unchanged.

> **Renamed in v0.37:** `commander` was a *mode*; it is now the *orchestrator toggle*. Legacy
> `{"mode":"commander"}` configs auto-migrate to `{"mode":"plan","orchestrator":true}` on first
> contact. `/mentor:commander on|off|status` remains for one release as a redirect stub.

## Native plan mode (fallback)

If you enter native plan mode (Shift+Tab) instead of using `/mentor:plan`, the plugin
falls back to its previous behavior: `block-edits-in-plan-mode.sh` enforces read-only and the
plan is approved via `ExitPlanMode` (with the proceed-mode question that auto-switches the session
mode). Both paths are mutually exclusive and never double-fire.

## Requirements

`jq`, `git`, and `python3` (the Bash write-path analyzer degrades to fail-open without `python3`;
Write/Edit gating remains fully fail-closed).

## Attribution

The `grilling` (`/mentor:grill`) and `handoff` (`/mentor:handoff`) skills are adapted from
[mattpocock/skills](https://github.com/mattpocock/skills) (the `productivity` skill set), reworked
to fit mentor's conventions, namespacing, and gates.
