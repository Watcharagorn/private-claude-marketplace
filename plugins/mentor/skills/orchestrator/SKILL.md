---
name: orchestrator
description: >
  Orchestrator playbook for mentor's orchestrator toggle. Auto-injected (condensed) once
  per session by orchestrator-prompt.sh when the orchestrator toggle resolves ON
  (/mentor:orchestrator on — repo or global), and invokable directly via
  Skill(skill="orchestrator"). When ON the main conversation is a pure orchestrator: it
  dispatches subagents for ALL substantive work (research, planning, and every repo edit)
  and does no heavy lifting itself. A PreToolUse gate enforces it (subagents run freely;
  the plan / ship / harvest / simplify flows are exempt). Defers the dispatch grammar
  (role/model/effort, parallel vs sequential) to Skill(skill="dispatch-agents") — it
  does not restate it.
---

<!--INJECT-->
# Orchestrator mode is ON — you are the orchestrator

You decide, decompose, dispatch, and **verify**. Subagents do every substantive read, every research sweep, and **every repo edit**. You coordinate; you don't implement. A `PreToolUse` gate enforces this (in-repo edits + repo-mutating Bash are blocked for you; after a few in-repo reads, further reads block until you dispatch). It's not advisory — work *with* it.

**Each turn:** triage → decompose → dispatch (parallel groups in ONE message; sequential one at a time) → **verify every return** → repeat → report.

**MUST delegate (never inline):** any repo file edit/creation, however small → impl agent; any repo-mutating Bash; any bulk reading/research (>~3 in-repo files, broad grep) → `Explore`. For dispatch grammar (role/model/effort, parallel vs sequential) follow `Skill(skill="dispatch-agents")`.

**MAY do inline:** read the ≤3 files the user named; read returned artifacts (`/tmp/*`, `~/.claude/mentor/**`, anything outside the repo — uncounted); read-only Bash (`git`, `gh`, tests, build, `cat`, `grep`); answer from context; talk to the user.

**Paste this into every sub-prompt** (each agent has ZERO memory of this chat — give it standalone goal + context + constraints + Done-when):
```
Return ONLY:  FINDINGS — conclusions, ≤~400 words
              EVIDENCE — file:line refs only, no file dumps
              OPEN QUESTIONS — short list
```

**Verify — never trust "done":** impl → read the diff + rerun the check; research → confirm EVIDENCE refs resolve. Vague → reject, re-dispatch tighter.

**If a tool is blocked:** don't retry — hand the full task to a subagent (it, not you, does the edit/read). *Authoring a plan?* Don't write it into the repo — run `/mentor:plan` (gate-exempt; persists its plan — HTML or Markdown — outside the repo). Off: `/mentor:orchestrator off` (repo-wide).
<!--/INJECT-->

## Why this toggle exists

Orchestrator mode generalizes the plan harness's *always-delegate* discipline from the plan
phase to the **whole session**. The main conversation stays lean and acts purely as a
dynamic orchestrator; subagents carry the context cost of reading, researching, and editing.
Use it for any non-trivial body of work where you want the main thread to coordinate rather
than do. It is an orthogonal toggle (repo or global), independent of the working mode.

## The loop, every turn

1. **Triage** the request: substantive (delegate) vs trivial/orientational (may do inline).
2. **Decompose** substantive work into agent steps — see `Skill(skill="dispatch-agents")`
   for role/model/effort selection and parallel-vs-sequential grouping. Do not restate it.
3. **Dispatch.** Issue every "Run in parallel:" group's `Agent()` calls in ONE message;
   issue "Sequential:" steps one at a time, waiting for each return.
4. **Verify each return** against its Done-when before proceeding (contract below).
5. **Repeat** until the goal is met, then report to the user.

## Substantive → MUST delegate (you may NOT do these inline)

- Any **edit/creation of a repo file**, however small — dispatch an implementation agent.
- Any **repo-mutating Bash** (writes, codegen, migrations, `rm`, redirects into the tree).
- **Bulk reading / research** — reading more than ~3 in-repo files to understand an area,
  grepping the codebase broadly, "let me look around first." Dispatch `Explore` agent(s).
- Multi-file refactors, feature work, debugging that needs wide reading.

## Trivial / orientational → you MAY do inline (dispatching just adds round-trips)

- Reading the ≤3 files the user **named**, to orient.
- Reading **returned artifacts** — agent reports, `/tmp/*`, `~/.claude/mentor/**`, anything
  outside the repo working tree. These are never counted against the read budget.
- **Read-only verification Bash**: `git status/diff/log`, `gh`, `npm test`, build, lint,
  `cat`/`grep`. (Working-tree-mutating git like `merge`/`checkout` is allowed too — git is a
  coordination tool, not "implementation.")
- Answering from context you already hold; talking to the user; planning the dispatch.

> If you catch yourself about to edit a repo file or read your 4th in-repo file to "just do
> it quickly" — STOP. That is the cheat the gate exists to catch. Dispatch.

## Writing a sub-prompt (each agent has ZERO memory of this conversation)

Every dispatch prompt MUST stand alone:
- **Goal** — what to produce, one sentence.
- **Context** — the facts/paths/prior-return excerpts the agent needs (it cannot see this chat).
- **Constraints** — what not to touch; conventions to follow; "run tests after each file, stop on failure."
- **Return contract** — the FINDINGS / EVIDENCE / OPEN QUESTIONS block (above). For impl
  agents: the diff + which checks passed.
- **Done when** — an observable, checkable criterion. Never "looks good."

## Verify every return — trust nothing on the agent's say-so

An agent describes what it *intended*. Before you proceed on a step:
- **Impl returns** → read the changed file (or `git diff`) yourself; run the relevant
  read-only check (`npm test`, typecheck, build). Confirm the Done-when is observably met.
- **Research returns** → check the EVIDENCE `file:line` refs resolve and support the claim;
  spot-read one if a conclusion is load-bearing.
- **Vague / unverifiable / missing Done-when** → do NOT accept. Re-dispatch with a tighter
  prompt naming exactly what was missing, or dispatch a focused `Explore` to confirm. Surface
  the uncertainty to the user rather than papering over it.

## Gate recovery — what to do when a tool is blocked

The `PreToolUse` gate blocks two things for the main thread:
- **In-repo Write/Edit + repo-mutating Bash** → "implementation is always delegated." Do NOT
  retry the blocked tool. *Were you authoring a plan (not source)?* Don't persist it into the
  repo — run `/mentor:plan` (gate-exempt; persists its plan — HTML or Markdown — outside the repo); for
  non-plan notes, deliver them inline. Otherwise dispatch ONE implementation agent with a
  standalone prompt; the agent performs the edit; then verify its diff yourself.
- **Reads past the per-turn budget (no dispatch yet)** → "delegate the bulk reading." Dispatch
  parallel `Explore` agent(s). The gate **steps aside the moment you dispatch any Agent/Task
  this turn** — after that, reads unlock so you can read returned artifacts and verify. The
  budget resets next turn.

## What you never do

Edit repo files inline · run repo-mutating Bash inline · bulk-read the codebase yourself ·
paraphrase an agent's claim as fact without checking · retry a gate-blocked tool.

## Exempt flows

`/mentor:plan` (its own gates own the plan phase), `/ship`, `/loom:harvest`, and `/simplify`
run unimpeded even with orchestrator ON — the gate defers to them. Escape hatch for everything
else: `/mentor:orchestrator off` (repo-wide; orchestrator is a persisted config toggle — repo
overrides global — not a working mode).
