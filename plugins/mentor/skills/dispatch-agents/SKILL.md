---
name: dispatch-agents
description: Decompose a plan into a sequence (or fan-out) of subagent dispatches, each annotated with role, model, and effort. Invoked when the user opts into the dispatch-agents strategy during plan mode, or explicitly asks to "dispatch agents" / "fan out" / "parallelize" a task.
---

# Dispatch Agents Strategy

This skill rewrites a plan as a series of **agent dispatches** instead of inline tool calls by the orchestrator. Each step is a self-contained brief for one subagent, optimally configured.

## When to use

- The user answered **"yes"** to the plan-mode dispatch-agents question.
- The user explicitly says "dispatch agents", "fan out", "use subagents", "parallelize this".
- A task spans multiple disjoint areas, would blow the orchestrator's context, or has clearly independent sub-tasks worth running concurrently.

## When NOT to use

- Single-file edits the orchestrator can do directly.
- Tasks where the orchestrator already has all the context loaded — dispatching just adds round-trips.
- Anything requiring tight back-and-forth with the user.
- **No-source-edit tasks** — live e2e / running-app observation, smoke-testing, or read-only
  monitoring, where **the dispatched agents themselves edit no source**. The plan-approval
  machinery does not apply here; dispatch plain read-only **monitor / `Explore`** agents directly
  (see the carve-out under ["Persist the plan…"](#persist-the-plan-then-exit-mandatory)).

## Per-step output shape

Each step in the plan must be annotated as:

```
Step N — <short title>  [role: <subagent_type> · model: <opus|sonnet|haiku> · effort: <low|medium|high>]
  Goal: <what this step must produce>
  Inputs: <files / facts / prior-step outputs the agent needs>
  Prompt sketch: <2–4 lines briefing the agent like a smart colleague who just walked in>
  Done when: <observable acceptance criterion>
```

Group steps that have no dependencies under a **"Run in parallel:"** header so the orchestrator dispatches them in a single message.

## Choosing `role`

The authoritative list of `role:` values is the `Agent` tool's `subagent_type` enum in your current tool spec — that is the set of agents actually installed and enabled for this session. The table below is guidance for matching common needs; if a project ships a more specific agent (visible in your enum), prefer it over the generic entries here. Do **not** scan `~/.claude/agents/` or any plugin's `agents/` folder on disk — those paths can list disabled plugins and will diverge from what is callable. If nothing in the enum fits, fall back to `general-purpose` and put the specialty in the prompt.

Match to the closest registered `subagent_type`. Common picks:

| Need | Role |
|---|---|
| Locate code, grep symbols, find files | `Explore` |
| Design implementation strategy / architecture | `Plan` |
| Open-ended research, code edits, multi-step | `general-purpose` |
| GitLab / SonarQube / external platform browsing | `explorer` (project-defined) |
| Claude Code / SDK / API how-to questions | `claude-code-guide` |
| Domain-specific (Jira, calendar, SDLC, etc.) | the matching project agent |

If nothing fits, default to `general-purpose` and put the specialty in the prompt.

## Choosing `model` — default Sonnet, step up to Opus

The documented best practice for Claude Code orchestration is **orchestrator on Opus, subagents on Sonnet** for focused work — Sonnet handles well-scoped sub-tasks at materially lower cost without quality loss. Sonnet 4.6 also has the **1M context window at GA pricing**, so "needs long context" is no longer a reason to reach for Opus.

**Default subagents to `sonnet`.** Use it for:
- Code edits, refactors, single-feature investigations.
- Locating code, grepping, file enumeration, dependency tracing.
- Mechanical / bulk work across a known file list.
- Anything well-scoped, even if it reads many files (Sonnet's 1M handles it).

**Step up to `opus`** only when the step genuinely needs heavy judgment:
- Architecture / design decisions with real tradeoffs.
- Security review, threat modeling, complex audits.
- Cross-cutting synthesis where multiple subsystems interact non-trivially.
- The orchestrator's `Plan` step for a multi-workstream initiative.

**Step down to `haiku`** only for trivial, parallel-safe lookups:
- "Does file X contain symbol Y?"
- "Print the first 50 lines of these 5 files."
- One-shot fact retrievals that don't need synthesis.

**Known caveat — Opus subagents + 1M context.** There is an open Claude Code bug ([anthropics/claude-code#51060](https://github.com/anthropics/claude-code/issues/51060)) where subagents spawned with `model: opus` can fail with "1M context requires extra usage" even when Extra Usage is enabled on the parent session. If you assign `opus` to a subagent and it fails this way, downgrade to `sonnet` (still 1M) as the workaround.

## Choosing `effort` — low / medium / high

Effort is communicated to the dispatched agent **through prompt scope and depth instructions**, not through a config field.

- **low** — single targeted lookup or quick check. Cap output ("report under 150 words"). Use when the answer is a short fact or a yes/no.
- **medium** — standard investigation across one feature / module. Default for most steps. No special instructions needed.
- **high** — deep, cross-cutting analysis or implementation. Tell the agent to think carefully, consider edge cases, verify assumptions, and report tradeoffs. Use for design, security review, complex refactors.

Effort and model are independent levers: a `low`-effort `opus` step is fine (cheap insurance for a tricky lookup), and a `high`-effort `sonnet` step is fine (deep but narrow work).

## Decomposition rubric

1. **List the work.** Write the bare task list before assigning roles.
2. **Find the critical path.** Which steps must finish before others can start? Those are sequential.
3. **Find independent steps.** Disjoint files/areas, separate research questions, parallel verifications — group these for fan-out.
4. **Assign roles.** Smallest specialist that covers the work.
5. **Assign models.** Default `opus`; downgrade only with a reason.
6. **Assign effort.** Default `medium`; upgrade for design/cross-cutting, downgrade for trivial.
7. **Write prompt sketches.** Each agent has zero memory of this conversation — the brief must stand alone.
8. **State done-when.** Observable, verifiable, no "looks good".

## Example

```
Plan — refactor checkout payment handling

Run in parallel:
  Step 1 — Locate all payment-method touchpoints  [role: Explore · model: sonnet · effort: low]
    Goal: list every file that reads/writes payment method state.
    Inputs: src/features/checkout/**, src/db/atomicSale.ts
    Prompt sketch: Find every file referencing `paymentMethod`, `payments` table, or `Payment` types. Group by feature folder. Report under 200 words.
    Done when: file list returned with one-line purpose per file.

  Step 2 — Audit current payment tests  [role: Explore · model: sonnet · effort: low]
    Goal: enumerate existing test coverage for payment flows.
    Inputs: src/**/*.test.ts, e2e/**
    Prompt sketch: List tests that exercise payment paths (cash, QR, split). Note which scenarios are missing.
    Done when: coverage matrix returned.

Sequential:
  Step 3 — Design refactor  [role: Plan · model: opus · effort: high]
    Goal: implementation plan for unifying payment dispatch.
    Inputs: outputs of Steps 1 & 2.
    Prompt sketch: Given these touchpoints and tests, design a refactor that consolidates payment handling behind a single dispatcher. Surface tradeoffs and migration risk.
    Done when: stepwise plan with file-level changes and risks. (Opus chosen here — cross-cutting judgment.)

  Step 4 — Implement  [role: general-purpose · model: sonnet · effort: medium]
    Goal: apply the refactor.
    Inputs: Step 3 plan.
    Prompt sketch: Execute the plan from Step 3. Run typecheck and unit tests after each file. Stop and report if a test fails.
    Done when: typecheck + tests pass; diff posted.
```

## Persist the plan, then exit (mandatory)

> **Carve-out — no-source-edit tasks (check this FIRST).** If **the dispatched agents edit no
> source** — live e2e / running-app observation, smoke-testing, or read-only monitoring — then
> **none of this section applies**: do not arm `begin-plan.sh`, do not author a plan file, and do
> not gate on approval. Dispatch read-only **monitor / `Explore`** agents directly and stop.
> Everything below — the gate, the HTML artifact, the owned-flow/native branching — governs only
> **source-editing** plans.

> **Gate:** Agent dispatch is permitted ONLY after the user approves the plan via `ExitPlanMode`. During plan mode, only read-only research/review agents (`Explore`, `Plan`, `/plan-review` reviewers) may be dispatched. All implementation/editing agents — and any source-file edits — must wait until after approval.

This skill is frequently invoked **directly** (the user types `/dispatch-agents`), which bypasses
`mentor-plan` and its Step 6b. You are still responsible for producing the plan-file artifact — in
the repo's resolved output format (mentor-plan Step 0: a styled `.html`, or a Mermaid-first `.md`).
The user reviews that file (it auto-opens for review), not the harness `.md`. **Resolve the format
once** (`bash "${CLAUDE_PLUGIN_ROOT}/hooks/set-plan-output-format.sh" status` → the `format:` line,
or `UNSET` → ask the user Markdown/HTML and persist) before computing the path below.

> **Owned-flow note (v0.21.0).** Check for a `.planning` marker in the plans dir. If it is
> **present**, you are inside the plugin-owned harness (the user came via `/mentor:plan`)
> — release with `approve-plan.sh`, not `ExitPlanMode` (step 3 below). If there is **no** marker but
> the session is in `bypassPermissions` and you want read-only enforced during planning, arm the
> gate first: `bash "${CLAUDE_PLUGIN_ROOT}/hooks/begin-plan.sh"`. In a genuine native plan-mode
> session, skip arming and use the native `ExitPlanMode` path.
>
> **Always delegate research AND authoring.** Decompose by dispatching `Explore` subagents and
> collecting their distilled returns — each returns FINDINGS (≤~400 words) + EVIDENCE (`file:line`
> only, no file dumps) + open questions (the shared contract with mentor-plan Step 1.5a). Then
> dispatch **ONE `Plan` agent** (`model: opus`) whose **prompt carries the token
> `mentor:plan-author`** to AUTHOR the full annotated plan body (it returns the complete Markdown,
> including every `[role: … · model: … · effort: …]` annotation and the footer markers), and
> written for a generalist reviewer (define jargon, state why each step matters — mentor-plan
> 1.5b principle). The
> orchestrator renders that returned Markdown into the plan file and **synthesizes nothing by hand**
> (mentor-plan Step 1.5b). The plans-HTML write below is blocked by `plan-author-gate.sh` until
> that plan-author agent has been dispatched (escape hatch `MENTOR_PLAN_AUTHOR=off`).
> Note: this direct path performs **no domain detection** — use `/mentor:plan` when you want the
> domain planning skills (frontend / backend-api / dynamic fallback) to shape the plan.

Before releasing the plan:

1. Compute the path and create the dir (substitute `<slug>`, or `plan`; `ext` from the format
   resolved above — `html` or `md`):
   ```bash
   slug="<slug>"; ext="<html|md>"   # ext = the resolved output format (mentor-plan Step 0)
   git_common="$(git rev-parse --git-common-dir 2>/dev/null)"
   repo_root="$(cd "$(dirname "$git_common")" && pwd)"
   repo_base="$(basename "$repo_root")"; repo_hash="$(printf '%s' "$repo_root" | shasum | cut -c1-8)"
   plans_dir="$HOME/.claude/mentor/${repo_base}-${repo_hash}/plans"
   mkdir -p -m 700 "$plans_dir"; echo "${plans_dir}/${slug}.${ext}"   # slug-derived, NO timestamp — stable across revisions (re-write the same file)
   ```
2. `Write` the plan document to that path, per the resolved format:
   - **`html`** — a self-contained HTML document following **[mentor-plan Step 8](../mentor-plan/SKILL.md)**
     (rendered `<body>` + a `<script type="text/markdown" id="plan-source">` block). Put the
     **complete annotated plan in the `plan-source` block verbatim**.
   - **`md`** — a self-contained Markdown document following **[mentor-plan Step 8M](../mentor-plan/SKILL.md)**.
     The `.md` IS its own canonical source — the **complete annotated plan is the file itself**, with
     the footer markers as **bare lines at end-of-file** and the `[role: …]` annotations inline (no
     `plan-source` block).

   Either way, render the **per-step dispatch cards** so the parallel/sequential grouping and the
   `role`/`model`/`effort` annotations are clearly visible (html: styled cards of your design; md: a
   GFM list/table under `Run in parallel:` / `Sequential:` headers), and include the footer markers
   verbatim:
   ```
   strategy: dispatch
   ```
   (add `worktree: …` if this is a worktree+dispatch plan). The dispatch-executor reads these
   annotations to fan out the agents (at approval an html plan is finalized to `<slug>.md`, so
   in both formats the executor reads the Markdown file directly; the `plan-source` block is
   read only on the fail-soft fallback) — keep each annotation on its own line. You do not need to open the file; the
   `plan-open.sh` hook opens it for review on first creation (html → VSCode tab or Chrome; md →
   VSCode tab or the OS default Markdown handler, never raw-text Chrome); it refreshes in place on
   later edits (no new tab/window, no focus-steal).
3. **Release the plan — pick the path that matches the flow.** Detect it:
   `[ -f "${plans_dir}/.planning" ] && echo OWNED || echo NATIVE`.
   - **OWNED** (`.planning` present — session already in `bypassPermissions`): ask a
     **Proceed / Hand off to next agent / Review the plan (light) / Keep planning** question, and on
     **Proceed** run `bash "${CLAUDE_PLUGIN_ROOT}/hooks/approve-plan.sh"`. It validates the plan (via
     `strategy-guard.sh`), deletes the marker (the edit gate opens), and prints the dispatch
     directive. Do **not** call `ExitPlanMode` and do **not** write `.proceed-mode`. On **Hand off to
     next agent**, run `bash "${CLAUDE_PLUGIN_ROOT}/hooks/approve-plan.sh" --handoff` — same
     validation + gate release, but it suppresses the dispatch directive; **follow the hand-off
     directive the hook prints to stdout** (invoke the handoff skill for this approved plan, then
     stop) and do not implement or dispatch in this session. On **Review the plan (light)**, invoke
     `Skill(skill="plan-review")` (read-only reviewers, gate stays closed), surface findings, then
     loop back to re-ask. On **Keep planning**, return to refining.
   - **NATIVE** (no marker): use the proceed-mode question + `.proceed-mode` + `ExitPlanMode` path
     exactly as mentor-plan **Step 6c-native** describes — escape hatch
     `MENTOR_PLAN_EXIT_MODE`, else `AskUserQuestion` (**Accept edits** → `acceptEdits`,
     **Bypass permissions** → `bypassPermissions`, **Review each edit** → `default`, **Keep
     planning** → don't exit), then `printf '%s\n' "<chosen-mode>" > "${plans_dir}/.proceed-mode"`,
     then call `ExitPlanMode` with no arguments. If the guard rejects for a missing `.html`, write
     it and retry — the `.proceed-mode` marker survives the rejection.

## Hand-off back to the orchestrator

**Do NOT dispatch any implementation/editing agent and do not edit source files until the plan is approved** — `approve-plan.sh` in the owned flow, or `ExitPlanMode` approval in native plan mode. A `PreToolUse` hook actively blocks in-repo source edits while the plan phase is active (the `.planning` marker, or native plan mode), so this gate is enforced — not merely advisory. Only after release does dispatch proceed as described below.

After release (`approve-plan.sh` prints the dispatch directive in the owned flow; `PostToolUse:ExitPlanMode` does so in native):

1. **Read the plan file immediately.** The dispatch directive prints the resolved path
   (e.g. `~/.claude/mentor/<repo>-<hash>/plans/<slug>.md`). At approval the plan was **finalized**:
   an html-format plan's canonical Markdown was extracted into `<slug>.md` and the `.html` was
   deleted — so post-approval the plan is normally a **Markdown** (`.md`) document that IS its own
   canonical source: read it directly (footer markers at end-of-file, annotations inline). Only if
   finalize fail-softed and an **HTML** file is still the resolved plan, read the canonical plan
   from the Markdown inside `<script type="text/markdown" id="plan-source">…</script>`, not the
   rendered body. Do not continue inline — read the plan first.
2. **Dispatch "Run in parallel:" groups.** Issue ALL `Agent()` calls for each parallel group
   in a **single message** so they run concurrently. After dispatching, **do not issue a no-op
   `Bash` call** (e.g. `echo "Waiting…"`) or `sleep` to "hold" while the agents run — that wastes a
   round-trip. Emit a brief text note (or nothing) and stop; the harness delivers each agent's
   `task-notification` automatically and re-invokes you when it completes.
3. **Dispatch "Sequential:" steps one at a time.** Wait for the prior step's result before
   issuing the next `Agent()` call.
4. **Verify each Done when: criterion** before moving to the next step — agents describe
   what they intended; trust but verify.
   - **Render-only fixes are yours; plan content is not.** This carve-out applies **during
     planning only** — post-approval the html plan has been finalized to `<slug>.md` and there is
     no render layer left. Pre-approval, if review surfaces a small cosmetic/render defect in the
     plan **HTML** (a CSS or theme-alignment tweak, a Mermaid `themeVariables` / ER row-color fix
     — see [mentor-plan Step 8 rule 11](../mentor-plan/SKILL.md)), you MAY apply it inline:
     rendering the HTML is the orchestrator's own job, not plan authorship.
     Two hard limits — (a) **never edit the `<script id="plan-source">` block** (that is plan
     *content*; the strategy-guard greps it and a hand-edit desyncs body↔source — route any content
     change back through the plan-author); (b) anything spanning **multiple files or in-repo source**
     dispatches a corrective agent. This carve-out covers the rendered plan artifact (which lives
     outside the repo) only — in-repo source edits stay gated. **For a `.md` plan (md format, or
     the finalized post-approval plan) there is no render layer and no `plan-source` block** — the
     `.md` is pure content, so this carve-out does not apply: route every change (even a typo)
     back through the plan-author and re-write the `.md`.

Do NOT paraphrase the plan or summarize what you're about to do. Dispatch immediately.
