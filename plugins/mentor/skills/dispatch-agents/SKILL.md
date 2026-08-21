---
name: dispatch-agents
description: >
  How a mentor plan routes work between the main thread and subagents, plus the
  annotation grammar and async runtime contract that govern every dispatch.
  Verification, review, and research always dispatch — an independent grader is
  the product there, not an optimization. Implementation has to earn it: dispatch
  only when two or more file-disjoint steps can be in flight at once, otherwise
  keep it in the main thread with a stated `Dispatch: skipped` reason. Invoked by
  plan Steps 4 and 6, or when the user says "dispatch agents" / "fan out" /
  "parallelize". Verification dispatch has no skip on a mentor plan. Also owns
  "Unattended continuation" — the per-step loop that runs a granted plan to
  completion without a human in the turn, gated per step by plan-state.sh instant.
---

# Dispatch Agents

This skill decides **where each kind of work runs** — main thread or dispatched
subagent — and then carries the annotation grammar for the steps that do fan out and
the contract for executing them. Used by `plan` (Step 4 routing + annotation, Step 6
execution) and referenced by `plan-review` and `handoff`.

## When to use

Every mentor plan comes through here: `plan` Step 4 invokes this skill to route and
annotate the implementation steps, and Step 6 invokes it again to execute them after
approval. Also invoked when the user explicitly says "dispatch agents", "fan out",
"use subagents", "parallelize this".

**The routing answer differs by kind of work, and that is the point of the skill.**
Verification, review, and research dispatch unconditionally — there an independent
context is the product, not a speed-up. Implementation has to earn dispatch against
the test in "Where dispatch pays" below, because implementation is where the case for
subagents is weakest: it is write-heavy rather than read-heavy, its steps usually
depend on each other, and the brief has to reconstruct context the main thread already
holds. Reading this skill as "dispatch everything" is the most expensive way to
misread it.

**Also load it for any ad hoc fan-out that is not plan implementation** — a research
sweep, a multi-repo survey, an architecture-gap audit, a fact-check of the plan's own
claims/figures against a live or authoritative source, a handoff note that says
"dispatch parallel `Explore` agents". The annotation grammar and the plan mechanics do
not apply to those; the "Async runtime & lifecycle" contract does, and it is the whole
reason to be here. Skipping the skill because the work has no plan is how a nine-agent
fan-out goes out without the deliver-before-idling block and returns one report.

## When NOT to use — starting from a plan this session didn't write

If you are picking up a plan that already exists — a fresh session, a handoff, or
one of a `/plan-split` group — go through **`/mentor:track`** instead of invoking
this skill directly. It answers two things this skill cannot:

- **Which plan, and how far did it get?** Track reads each plan's state and re-enters
  an interrupted run at the first unticked step, rather than rebuilding from step 1.
  It also refuses `draft` plans, which the approval gate never released.
- **Is this session big enough to finish the job?** Track runs a context check first
  (its Step 0 explains why nothing else covers this path). Dispatching straight from
  here is the one route into a full implementation with nothing measuring the session.

When `mentor:planning` Step 6 or `mentor:plan-track` invokes this skill, those checks
already ran; carry on.

## When NOT to use — another framework owns the plan of record

Work already planned elsewhere (spec-kit's `tasks.md`, a Jira epic): do not author a
mentor plan or run an approval question over it (`plan-track`, "When NOT to use").
Annotate that framework's phase with the grammar below and execute — every `plan.md`
mechanic here (approved-plan read, ✅ ticks, `plan-state.sh`, the gate, `## Verification`
dispatch) has no counterpart and is skipped, and `/mentor:defer` redirects: a follow-up
belonging to that framework's backlog goes there, not into a mentor stub. Repo work
outside its scope is **named in your report** and `/mentor:defer` offered — this path is
self-graded, with no verifier and no disposition gate behind it, so there is nothing here
that could responsibly park work on the user's behalf. Three rules hold on this path:

- Copy `Goal:`/`Done when:` **verbatim from the task's own text** and verify the
  delivery against that text — your brief is a lossy transcription of it. You self-grade
  here: the weakest-grader rationale in "Verifying the plan (execution-time)" does not
  reach this path, because that framework owns its own verification.
- Never let the record **drift from the work**: the orchestrator, not the agent, lands
  each check-off in the same commit as that task's own work — never batched, never
  left dirty for a later task to sweep in.
- Write that progress line and **nothing else** in the framework's files. A spec
  conflict blocking a `Done when:` goes to that framework's own amend command — mentor
  never edits another framework's artifact of record.

If this work should be gated, mentor should own the plan: `/mentor:plan`.

## Where dispatch pays — the routing test

Dispatch buys two separable things: **context isolation** — an agent reads a hundred
files and hands back a paragraph, so the corpus never enters the orchestrator's window —
and **parallelism**, but only while several agents are actually in flight. Isolation
alone earns its keep when the work is read-heavy, when an independent grader is the
point, or when one step's context cost would otherwise flood the main thread; it does
**not** when a lone agent works on context the main thread already holds. (The
measurements and published findings behind this: `references/rationale.md` →
**Where dispatch pays**.)

So route by the kind of work, not by a blanket default.

**These always dispatch — no test, no escape hatch:**

- **Verification** of a `## Verification` topic. The context that built the thing is its
  weakest grader, so an independent one is the deliverable rather than an optimization.
- **Review** — `plan-review`'s lenses, adversarial passes, a diff review. Same
  independence argument, and each lens is genuinely disjoint from the others.
- **Research** — codebase sweeps, multi-repo surveys, fact-checks against a live source.
  Read-heavy by nature, which is exactly the shape where an agent ingests the most and
  returns the least.

**Implementation has to earn it.** Annotate implementation steps as `Agent` dispatches
when **all three** of these hold:

1. **Two or more steps can be in flight at the same time.** One agent alone buys
   isolation but no speed, while still paying full price to brief a context that starts
   blind.
2. **Those concurrent steps are file-disjoint**, and none of them mints a value from a
   shared sequence — migration numbers, ports, generated ids, an append-only registry.
   This is the same test as the decomposition rubric's item 3, and colliding parallel
   edits are the failure mode here that costs the most to unwind.
3. **Each brief stands on its own.** A step that needs the conversation to make sense —
   a decision's reasoning, a convention still being settled, the user's live corrections
   — loses the part that mattered when you write it down for a stranger.

**The context-cost override.** A step fails test 1 and still dispatches, alone and
sequentially, when running it in-thread would wreck the orchestrator: its `Done when:`
needs a service brought up, a browser driven, or a screenshot compared, or its `Inputs:`
pull in several whole large files. That is isolation bought deliberately, and it is the
one honest reason to dispatch a single agent. Say so in the annotation's reason so a
reviewer can tell it apart from a reflex.

**When any of the three fails and the override doesn't apply, the work stays in the main
thread**, and the plan opens its `## Implementation steps` section with one visible line:

```
Dispatch: skipped — <one-line reason naming which test failed>
```

No line, no skip — the line is what makes the routing reviewable at approval rather
than a silent choice. "Skipped" names the *dispatch* and nothing else: the plan keeps
every other obligation, and a main-thread implementation that turns out to need
concurrency mid-flight stops and re-routes per this skill.

**Delegating a step to another plugin's own multi-agent skill is not a third route.**
That step is still annotated, just not as an `Agent` dispatch ("Per-step output shape"
below), and the plan keeps its ticks, its closing checklist, and its verification
fan-out.

**The routing never touches Verification** — `## Verification` still gets fresh
verifiers after the last step ("Verifying the plan (execution-time)" below; a
main-thread plan with ≤2 topics gets the lite-verify allowance, never a self-check).
This is the line to hold hardest, because everything downstream of the routing verdict
— step ticks, `/simplify`, the closing checklist, the acceptance pass — is written once
for the dispatch path and only *restated* for the main-thread one, so a routing verdict
claimed carelessly is how a plan quietly loses all of it at once.

## Context efficiency — the orchestrator contract

The point of SDD: quality through narrow focus, and a lean main thread.

**Verification, without pulling the step's context back in**

- **Never read the implementation files a step delegates** — that context belongs to the
  dispatched agent. Verify `Done when:` with observable checks; the step's `git diff` and
  a failing command's output are always in-bounds as diagnostics.
- **Prefer an executable pass/fail `Done when:`** (the named test / typecheck / lint
  command) over a presence check; use grep/ls only when nothing runnable exists.
  **A check that mutates what it verifies** — an importer, a migration runner, a
  `--write` formatter, a seed script — consumes the very thing it was meant to confirm,
  so run it against a `mktemp -d` copy outside the repo, compare, discard. When it
  cannot run detached (live git context, a database, a running service), snapshot state
  and restore after, or point it at a disposable instance.
- **A file the step must NOT touch** — a gitignored config, a credentials file, anything
  `git diff` cannot see — is verified by snapshot: record `shasum -a 256` plus the mtime
  before dispatch and re-compare after. Reading it back to diff by hand pulls the exact
  contents, often the exact credential, into the context the step was keeping them out of.
- **A tool call the step must NOT make**, and **a fan-out of countable per-agent
  artifacts**, are both proved against a complete list rather than by grepping for
  absence — see `references/rationale.md` → **Proving a negative**, which carries the
  two commands and why the obvious alternatives invert the evidence. In both cases a
  zero result is not evidence until the check itself is confirmed working, and an
  agent's own "I never called it" is a self-report: if the census cannot be produced,
  report the claim as **unproven** rather than passing the self-report off as verified.
- **On a failed `Done when:`**, re-dispatch the same role once with the failure evidence
  (diff + command output) as inputs. If it fails again, surface to the user — only then
  may the main thread read the files and take over. **A hand-back is not a failure and
  does not spend that re-dispatch:** an agent delivering partial work plus a remainder
  brief did the right thing, so verify what it actually claims and dispatch the same role
  fresh with the remainder as its `Inputs:`. That chain is bounded at one — a second
  hand-back means the step was mis-scoped, so put the re-scope to the user instead of
  letting it slow-bleed across N contexts.

**Recording what happened**

- **Tick each step as its `Done when:` passes:**
  `bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" tick <slug> <N>` (N = the step's
  ordinal, counting either `Step N — …` or numbered-item lines). Use `tick`, never a
  hand-built `Edit`: mentor counts ticks by scanning step lines only, so a `✅` parked on
  an indented `Done when:` line is invisible and the step reads as never started. It is
  idempotent and fails loud on an out-of-range N. Ticks are also what makes plan state
  self-healing, which is why a missing one matters most on a plan about to be closed
  (`plan-track`'s "reconcile the ticks before writing implemented" is the last chance).
- **Don't mirror step tracking into a separate todo list.** `tick` plus the plan file's
  `✅` marks are the one source of truth; a parallel entry per step is a second ledger to
  keep honest, read by nobody who isn't already looking at `plan.md`. Reserve the todo
  list for work outside the plan.
- **Move the plan's state as you go**, so `/mentor:track` can answer "what is built?" in
  a fresh session without re-reading anything:
  ```bash
  [ -d "${CLAUDE_PLUGIN_ROOT}/hooks" ] || { echo "ERROR: CLAUDE_PLUGIN_ROOT unresolved or stale — do not search the plugin cache or hardcode a version path; ask the user to /reload-plugins or restart" >&2; exit 1; }
  bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" set <slug> in_progress    # before the first dispatch
  bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" set <slug> implemented    # every Done when: + Verification PASS
  bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" set <slug> failed --note "<what broke>"
  ```
  `<slug>` is the plan's directory name. Set `failed` wherever verification ends
  unresolved — the escalate-to-user point after the one remediation re-dispatch also
  failed, and a hand-off. That one is worth remembering: unlike the others it cannot be
  derived from ticks, and the note is what makes the retry cheap.

**Writing the brief, and relaying what comes back**

- **Prompt sketches must be self-contained.** Each agent starts with zero memory of this
  conversation **and no inherited project context — assume it never read CLAUDE.md or
  your repo's conventions**: give exact file paths, the approved plan path, the distilled
  facts it needs from research or prior steps (paste result lines, not files), and its
  `Done when:` verbatim. Do not author the solution-quality line or the standing contract
  block yourself — `hooks/dispatch-contract.sh` appends both to every `Task`/`Agent`
  prompt automatically. A `Prompt sketch:` is the *middle* of a prompt, never the whole
  of it: it ends where the hook's injection begins.
- **Return contract:** agents return a short summary, file paths touched, and
  verification output — never full file bodies. Verification output must include the
  exact command(s) that produced it, copy-pasteable, or re-verifying means re-deriving
  the command blind.
- **Relaying a return to the user strips its ids.** An agent's report is written for
  **you**: its finding codes, table rows, and bare `Location(s)` cells name things the
  user never read. Carry the finding, not its filing — say what the thing is ("the Argo
  controller reads cross-tenant Secrets") and leave the code in your notes. The same
  holds when the relay becomes a question: **every question stands on its own**, answered
  from the question screen alone, never sending the user to a file, a report, or an
  earlier turn to learn what it means.
- **A live secret can arrive by paste.** A step the owner performs by hand exists so a
  credential never passes through the model; nothing stops the user pasting it anyway. On
  handover, say where the value goes and that it must not come back through the
  conversation. If it arrives regardless: proceed, write it to the one file the step
  names and nowhere else, never echo it back, and say **once** that it is now in this
  session's transcript — which persists on disk and `/mentor:handoff` reads back — so
  rotating it is the only cleanup left. Nothing un-sends a turn.

**Scope**

- **No nested fan-out.** Dispatched agents **can** call the Agent tool — nothing in the
  runtime stops them, and a chain they spawn is invisible to you and outlives your
  close-out. Size each step so one agent completes it alone; the injected contract block
  is what actually holds the line.
- **Work discovered mid-flight is carried to the close-out, never parked on your own
  initiative.** When the orchestrator or a dispatched agent notices real work outside the
  current step's scope, the agent **reports** it and the orchestrator holds it: stamp it
  the way a verifier would — `[GOAL]` if it leaves one of this plan's `Done when:`
  bullets unmet, so it gets remediated in the loop, otherwise `[NON-GOAL]` — and fold it
  into "The non-goal disposition gate" below alongside the round's verifier gaps. Holding
  is not dropping: an aside in a chat message disappears at session end, which is the
  failure this rule exists to prevent. But nothing is deferred on your reading of what
  matters — deferral is the user's verdict to give.

  When a defer **is** the verdict, one question fixes the parent link — **which plan's
  work does this item block from being *really* done?** For a confirmed defect that is the
  plan whose work carries it, not merely whichever plan happened to be active when it
  surfaced:
  - **An already-implemented plan's work** — including the active plan once its own
    verification passed → `parent` = that plan's slug. Parking it flat instead makes it
    invisible to every `parent`-walking surface (`query --subtree`, `/mentor:track`'s
    roll-up, `/mentor:resume`'s drain) while the owning plan reads cleanly `implemented`;
    parented, that plan honestly shows "done with open fixes".
  - **An unbuilt plan's future scope** → no `parent` (nothing done exists to block);
    record the ordering as `deps` on that plan instead.
  - **Nobody's in particular** (backlog — a refactor idea, tooling, a feature aside) →
    flat, no `parent`. This is also what a gate verdict routes by default.

## Per-step output shape

Each step in the plan must be annotated as:

```
Step N — <short title>  [role: <subagent_type> · model: <opus|sonnet|haiku> · effort: <low|medium|high>]
  Goal: <what this step must produce>
  Inputs: <files / facts / prior-step outputs the agent needs>
  Prompt sketch: <2–4 lines briefing the agent like a smart colleague who just walked in>
  Done when: <observable acceptance criterion>
```

Nothing is ticked at authoring time. Later, when a step's `Done when:` passes,
the `✅` from the tracking rule above is appended to that step's `Step N —` line —
the top line of the block, never one of the indented fields under it.

Group steps that have no dependencies under a **"Run in parallel:"** header so they dispatch in a single message. Dependent steps go under **"Sequential:"**.

**A step delegated to another plugin's own multi-agent skill** carries
`[delegated: <plugin>:<skill>]` in place of the `[role: … ]` bracket and drops
`Prompt sketch:` — that skill writes its own briefs. `Goal:`, `Inputs:`, and
`Done when:` are unchanged, and the orchestrator still verifies `Done when:`
itself. It cannot be pushed down into a dispatched agent instead: that agent
would have to spawn the skill's own agents, which is the nested fan-out banned
below. It is therefore always `Sequential:` — the main thread runs the skill
itself, so there is no `Agent()` call to ride in a parallel group's single
message.

## Choosing `role`

The authoritative list of `role:` values is the `Agent` tool's `subagent_type` enum in your current tool spec — the set of agents actually installed and enabled. Do **not** scan `~/.claude/agents/` or plugin `agents/` folders on disk — those can list disabled plugins. If nothing in the enum fits, fall back to `general-purpose` and put the specialty in the prompt.

| Need | Role |
|---|---|
| Locate code, grep symbols, find files | `Explore` |
| Design implementation strategy / architecture | `Plan` |
| Open-ended research, code edits, multi-step | `general-purpose` |
| Domain-specific (platform browsing, Jira, etc.) | the matching project agent |
| Verify a plan's Verification-section topic (fresh, independent) | `general-purpose` — opus only on the concrete trigger in "Verifying the plan (execution-time)" below |

## Choosing `model` — default Sonnet, step up to Opus

**Default subagents to `sonnet`** — it handles well-scoped sub-tasks at materially lower cost without quality loss: code edits, refactors, investigations, locating code, mechanical/bulk work.

**Step up to `opus`** only when the step genuinely needs heavy judgment: architecture/design decisions with real tradeoffs, security review, cross-cutting synthesis, the `Plan` step of a multi-workstream initiative.

**Step down to `haiku`** only for trivial, parallel-safe lookups ("does file X contain symbol Y?", one-shot fact retrievals).

## Choosing `effort` — low / medium / high

Effort is communicated to the dispatched agent **through prompt scope and depth instructions**, not a config field.

- **low** — single targeted lookup or quick check. Cap output ("report under 150 words").
- **medium** — standard investigation across one feature/module. Default.
- **high** — deep, cross-cutting analysis or implementation. Tell the agent to think carefully, consider edge cases, verify assumptions, report tradeoffs.

Effort and model are independent levers: a `low`-effort `opus` step is fine, and a `high`-effort `sonnet` step is fine.

## Decomposition rubric

1. **List the work.** Write the bare task list before assigning roles.
2. **Find the critical path.** Which steps must finish before others can start? Those are sequential.
3. **Find independent steps.** Disjoint files/areas, separate research questions, parallel verifications — group these for fan-out. Disjoint files are not enough: steps that each mint a value from a **shared sequence** (migration numbers, ports, generated ids, an append-only registry) collide even in separate files — pre-assign the concrete values in each step's `Inputs:`, or make them `Sequential:`.
4. **Collapse small dependent steps.** Adjacent `Sequential:` steps that are individually small (combined ≤ ~40 changed lines) and suit the same role/model collapse into ONE dispatch — don't pay agent startup per tiny step.
5. **Budget each step to one agent's context.** A dispatched agent never compacts, so
   every tool result and every thinking block it emits stays in its context until the
   step ends. Nobody can count those calls while authoring, so size by smells
   instead; a step showing any of these is oversized and gets split:
   - it spans more than one service or layer;
   - it touches more than ~10 files across distinct areas;
   - its `Done when:` needs a live multi-service stack driven end-to-end (that proof
     belongs to a `## Verification` topic — see **State done-when** below);
   - its `Inputs:`, or the reconnaissance it implies, pull in several whole large
     files (tens of KB each) — the costliest smell by measure, and the one a
     narrow-sounding step hides best;
   - its prompt sketch reads like a project brief rather than a task.

   Split an oversized step into **sequential steps, one dispatch each, handing off by
   report** — each later step takes the prior step's report as its `Inputs:`. *Collapse small
   dependent steps* above bounds the opposite end (collapse tiny steps, split giant
   ones), and if splitting pushes the plan past ~12 steps that is `/plan-split`'s
   threshold doing its job, not a reason to re-merge. (The measured blowup behind these
   smells: `references/rationale.md` → **Sizing a step to one agent's context**.)
6. **Assign roles.** Smallest specialist that covers the work.
7. **Assign models.** Default `sonnet`; upgrade only with a reason.
8. **Assign effort.** Default `medium`; upgrade for design/cross-cutting, downgrade for trivial.
9. **Write prompt sketches.** Each agent has zero memory of this conversation — the brief must stand alone. If a `Done when:` is a long test suite, brief the agent to iterate on a filtered subset and run the suite whole only as the final gate. When any step's `Done when:` runs tests, resolve the repo's test invocation **once per session** — `mentor:shipping` Step 4's own order (`.mentor/config.json`'s `test_command` first, else auto-detect, confirmed once it actually runs) — and paste that literal command into every prompt sketch that needs it, because a copy-pasteable string is the only thing that transfers to a context that never saw the earlier steps. The same rule covers any other repeatedly-launched tool a `Done when:` needs (a browser/E2E runner, a dev server): resolve the working invocation the first time it's needed and reuse that exact command in every later prompt sketch — no `.mentor/config.json` key exists for these, so state the resolved command directly rather than pointing at one. When the proof that tool serves is the live multi-service kind, item 10 sends the proof itself to a `## Verification` topic — the invocation is still resolved once, but it is handed to that topic's verifier (`references/verifier-contract.md` → "What to hand the verifier") instead of repeated across prompt sketches. It also covers *checkers*, not just invocations: when the repo or environment already ships a validator for the kind of artifact a step produces, name that command in the step's `Done when:` rather than leaving the agent to write its own equivalent — a freelance check is a second, unverified implementation that can drift from the real one unnoticed. (Why the command is pasted rather than described, and how a freelance checker fails: `references/rationale.md` → **Why a resolved command is pasted, not described**.)
10. **State done-when.** Observable, verifiable, no "looks good" — and provable by the
    implementer with **bounded commands**: build, typecheck, unit tests, a targeted
    integration check. Live end-to-end proof across a running multi-service stack
    belongs in a `## Verification` topic, where one fresh verifier runs it exactly
    once. Writing it into a step's `Done when:` as well makes the implementer prove it
    first, in the most expensive context of the session, and the topic then re-proves
    the same ground.

## Example

```
Run in parallel:
  Step 1 — Locate all payment-method touchpoints  [role: Explore · model: sonnet · effort: low]
    Goal: list every file that reads/writes payment method state.
    Inputs: src/features/checkout/**, src/db/atomicSale.ts
    Prompt sketch: Find every file referencing `paymentMethod`, `payments` table, or `Payment` types. Group by feature folder. Report under 200 words.
    Done when: file list returned with one-line purpose per file.

Sequential:
  Step 2 — Design refactor  [role: Plan · model: opus · effort: high]
    Goal: implementation plan for unifying payment dispatch.
    Inputs: output of Step 1.
    Prompt sketch: Given these touchpoints, design a refactor that consolidates payment handling behind a single dispatcher. Surface tradeoffs and migration risk.
    Done when: stepwise plan with file-level changes and risks. (Opus — cross-cutting judgment.)

  Step 3 — Implement  [role: general-purpose · model: sonnet · effort: medium]
    Goal: apply the refactor.
    Inputs: Step 2 plan.
    Prompt sketch: Execute the plan from Step 2. Run typecheck and unit tests after each file. Stop and report if a test fails.
    Done when: typecheck + tests pass; diff posted.
```

## Executing the dispatches (after plan approval)

Dispatch implementation/editing agents **only after the plan is approved**
(`approve-plan.sh` released the gate). Every implementation dispatch in a
mentor session routes through this skill — callers load it (once per session)
before issuing `Agent` calls. Then:

1. **Pull each step's brief, not the whole plan** — `bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" brief <slug> --step N` returns the plan title, its `## Context` goal, the whole `## Out of scope` section, one line per step with tick state, the verbatim body of step N, and the `## Verification` topic titles — everything a dispatch needs, at a fraction of `plan.md`'s size. Do not read the whole plan file from memory or by hand; run one `brief` call per step (or per step in a parallel group) instead.
2. **Dispatch "Run in parallel:" groups** — issue ALL `Agent()` calls for each parallel group in a **single message** so they run concurrently. The solution-quality line and the standing contract block ("Deliver before idling," "Async runtime & lifecycle" below) reach every prompt automatically via the dispatch hook, so there is nothing to paste by hand — but the block's directives, including the no-nested-fan-out ban, are non-negotiable regardless of how the prompt sketch itself reads. After dispatching, apply **No busy-wait**: stop and let the harness re-invoke you when agents complete.
3. **Dispatch "Sequential:" steps one at a time** — wait for the prior step's result before issuing the next call.
4. **Verify each `Done when:` criterion** before moving to the next step — agents describe what they intended; trust but verify. On a concurrency- or timing-sensitive criterion, one clean run is not evidence — re-run it yourself 5+ times before accepting a PASS; an agent's self-reported `PASS=N/FAIL=0` from a single run proves nothing about a race. A zero-hit or empty result from your own check is likewise not evidence the criterion failed until you've confirmed the check itself works — a single-line `grep` can miss a claim that wraps across lines, an unquoted glob aborts outright under zsh's `nomatch`, and ERE alternation is `|`, not `\|`; when a check comes back empty, narrow it to one line or run it against a known-positive before trusting the negative. A step that hands back partial work plus a remainder brief has not failed its criterion — verify what it actually claims, then continue it per the hand-back addendum under "On a failed `Done when:`" above.
5. **Execute the plan's Verification section** — dispatch one fresh verifier per `Topic N —` block, all in a single message, even when the plan opened `Dispatch: skipped`. Full contract in "Verifying the plan (execution-time)" below. A plan's own implementation step titled "Verification pass" or similar is not this step; it's ordinary self-graded work covered by item 4 above, never a substitute for this dispatch.
6. **CLOSING CHECKLIST — always, whatever Verification returned** (on a `failed` or handed-off plan the first two items still run; hold the tour and ship offers, which speak for work that was accepted)**:**
   - **Close out finished agents** — enumerate live tasks with `TaskList` and diff
     against this session's own dispatch tree, nested spawns included, before
     `TaskStop`ping only what traces to that tree. Skipping straight to `TaskStop`
     by remembered name doesn't just risk missing a nested spawn — when the harness
     runs several sessions concurrently, a remembered name can belong to a
     **different session's** live agent (its idle notification leaked into this
     session's message stream). The runtime rejecting an unrecognized id is a
     safety net, not a substitute for enumerate-then-diff (see "Async runtime &
     lifecycle" below for the full rule, including the matching ownership check
     before *nudging* on idle — that path has no id-rejection safety net at all).
   - **Offer `/mentor:tour`** — one line: a hands-on acceptance pass building an editable guided-tour review artifact (pass/not-pass scenarios) of what shipped. Do not auto-run it.
   - **Sweep the report you're about to write** — every follow-up, gap, or known-broken
     item in it is **named** there, in plain terms, so nothing survives only as an aside
     that dies with the session. Do not capture them on your own: parking work is the
     user's call, and anything a verifier raised already carries their verdict from "The
     non-goal disposition gate" below. Close by offering `/mentor:defer` as the pointer for
     whatever else they want parked. Either way an unresolved verification topic or an
     unverified claim is never a stub — it's `set <slug> failed --note` on the plan.
   - **Commit this session's implementation work.** `git status --porcelain`: if
     every dirty/untracked path is something this session's dispatches touched,
     ask via `AskUserQuestion` — commit it as this plan's work (recommended) /
     leave it uncommitted, the user commits by hand. Any dirty path this session
     did **not** touch: show the split, same question, scoped to only the paths
     this session owns. Also check the inverse before trusting a clean tree: for
     each step's touched path (its return contract's file list) that is now
     absent from the porcelain output, `git log -1 --format='%h %an %s' -- <path>`
     — no commit at all means a no-op step (nothing to flag), but a commit this
     session didn't make means a concurrent process silently absorbed that path
     mid-dispatch. Fold that into the same question (name the absorbing commit)
     and, however it resolves, record the split in this session's own closing
     commit message — the plan's ✅ ticks still stand, only the attribution needs
     stating. (The run that made this real: `references/rationale.md` →
     **Who commits an implementation run's work**.) The orchestrator is the only
     legal committer here — the standing contract above bars dispatched agents from
     touching the index — and this is deliberately a **question**, never
     `mentor:shipping` Step 3's silent auto-commit: that allowance is scoped to
     files `simplify` itself just created, not to a whole implementation run.
     Skip this bullet only when the tree is clean and nothing was flagged as
     absorbed. One scoped exception: an **instant** run (below) replaces this
     question with its end-of-run auto-commit on the run's own plan branch — a
     user-ruled trade that never touches the branch you were on;
     the question stays for every attended run.
   - **Point at `/mentor:ship`** — one line: once the ticks above are verified and
     the tree is committed (above), the next move is `/mentor:ship` (it hands off
     to `/mentor:merge`'s bounded watch) — not a hand-rolled `git push`, `gh pr
     create`, or a CI-poll loop. Do not auto-run it. A tree still dirty when
     `mentor:shipping` Step 2 runs means something outside this session's own
     work — that abort is real, not a formality it will paraphrase past.

Do NOT paraphrase the plan or summarize what you're about to do. Dispatch immediately.

## Unattended continuation (the per-step loop)

The elaboration of items 1–5 above for a plan that already holds a standing grant: run
it to completion without a human in the turn, asking `plan-state.sh instant` before
every dispatch and every tick, and stopping the moment the script or the evidence says
stop. **On by default** — the `instant` config axis unset behaves as `on`;
`set-mode.sh instant-off`, or `--confirm` on the resume prompt, restores the attended
flow end to end. Why the loop refuses more than it runs, and the measurements behind
the three-way verify route: `references/rationale.md` → **Why the loop refuses more
than it runs**.

Let `PS="${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh"` throughout.

**Pre-flight, once per plan.** `bash "$PS" instant <slug>` — line 1 is the verdict;
branch on it by string equality:

- `UNRESOLVED` (exit 2) — re-run with `--verbose`, report `reason=`, STOP. Never read
  it as GO, and never as HOLD either: "unknown" is "ask", not "unsafe".
- `HOLD` — report `--verbose` and STOP; no dispatch, no tick. `gate-armed`/`gate-stale`
  → plan-track Step 3's ARMED prose (do NOT run approve-plan.sh to clear it — it takes
  no slug); `structure` → run `plan-state.sh verify <slug>`, fix what it names, re-enter.
- `ASK` — AskUserQuestion headed by `reason=`, STOP until answered: `swept-in` →
  plan-track's `approved`-row mandatory confirm; `draft`/`no-grant-on-record` →
  plan-track's "Approving a draft plan here"; `failed` → plan-track's `failed` row;
  `stored-implemented-ticks-open` → the sidecar says done and the ticks say otherwise —
  the user reconciles, never the loop; `context` → `plan-state.sh context`'s own ASK
  block (handoff recommended / bypass-context.sh).
- `NO_STEPS` — a step-less stub is planning work, not loop work: route to
  `Skill(mentor:planning)` (on `origin=deferred`, plan-track's claim path first). STOP.
- `DONE` — nothing left to run; skip to "Verifying the plan (execution-time)".
- `GO` — continue below.

**Enter the plan branch** (user-ruled). The run's commits belong to a
branch of their own, cut from whatever is checked out now: `mentor/<slug>`, or
`mentor/<group>/<slug>` when the sidecar carries a group. Already on it → proceed;
it exists from an earlier handoff → check it out; otherwise `git checkout -b`. When
another unattended run is already active in this working tree (its plan branch is
checked out with a fresh `instant-run-*.md` on a different slug), take a
`git worktree add` sibling instead — one tree, one run. A dirty tree does NOT block
entry (ruled); record every pre-existing dirty path as a `NOTE:` line in the run
record so the end-of-run commit can prove it staged none of them.

**Open the run record** — `.mentor/plans/<slug>/instant-run-<ts>.md` (the
`topic-N-verify.md` convention). Every per-step verdict, `NOTE:` line, and route
decision below is appended there as it happens: an aside in a chat message disappears
at session end, which is the failure this file exists to prevent.

**Per step**, starting at `next_step=` from the pre-flight `--verbose`:

1. `v="$(bash "$PS" instant <slug> N)"` — the WHOLE ladder re-runs per step: gate and
   context are re-read each iteration, which is what closes the blind spot between
   human turns. `UNRESOLVED`/`HOLD` → record, `set <slug> failed --note "<token>:
   <reason=>"`, STOP. `ASK` → record, ask; on "stop", write the `failed --note` before
   ending. `DONE` → the step is already ticked; `N=N+1`, continue. `DEFER`/`GO` → run it.
2. Capture `header_crc=` from `instant <slug> N --verbose` **now** — this is the header
   the tick must land on later.
3. Pull the brief (item 1 above) and dispatch per items 2–3, honoring
   `Run in parallel:`/`Sequential:` exactly as written.
4. **Verify the `Done when:` — the three-way route the script deliberately does not
   pick** (it reports facts; the route is judgment):
   - the criterion is one bounded command and nothing else → run it yourself; tick on
     its output;
   - a prose conjunct remains, or prose only → dispatch ONE fresh verifier per
     `references/verifier-contract.md` and tick on its `Verdict:` — **and under
     `dispatch: solo` this verifier is dispatched anyway** (user-ruled: solo's
     no-agents intent is overridden for verification only). Disclose each such
     dispatch in the run record (`NOTE: solo-override verifier — step N`); never
     self-grade a criterion the same thread just implemented;
   - the criterion turns on a physical or manual event → ask the human. No stand-in
     counts.
   A failed criterion spends the ONE re-dispatch of the orchestrator contract (with
   the diff and failing output as inputs); a hand-back spends nothing. A second
   failure → `set <slug> failed --note`, surface, STOP. A partial mid-step failure
   leaves no rollback: record every file the step wrote in the run record and do NOT
   advance.
5. On `GO`: re-run `instant <slug> N --verbose` and abort the tick unless
   `header_crc=` still equals the value from item 2 (the tick writes positionally
   into an unversioned file — a moved header means it would land on the wrong line).
   Then `bash "$PS" tick <slug> N`. On `DEFER`: dispatch and verify but do NOT tick;
   note `N:defer_until=` for the drain below.
6. Append the step's verdict to the run record, `N=N+1`, and loop while
   `bash "$PS" instant <slug>` is not `DONE`.

**Mid-run context.** The `context-checkpoint.sh` hook (PostToolBatch) injects
`[mentor] CONTEXT CHECKPOINT` advisories between tool batches — advisory only, by
ruling; nothing forces a stop. Obey the ASK-tier directive when it arrives: finish
ONLY the current step, record its outcome, write the handoff, end the turn.

**Drain the deferred list.** For each held step whose `defer_until=` is now ticked:
re-verify its `Done when:`, then tick. Still unsatisfied → `set <slug> failed --note
"step N: forward ref unmet"` and surface.

**Ending an instant run.** `instant <slug>` now reads `DONE` (the grant reads the
STORED state, so it survives its own last tick — that is what authorizes the
`## Verification` remediation). Run "Verifying the plan (execution-time)" and "The
non-goal disposition gate" unchanged — including under `dispatch: solo`, where the
round's fresh verifiers still dispatch per the same user-ruled override as item 4,
disclosed in the run record — then the CLOSING CHECKLIST with ONE substitution
(user-ruled): instead of the commit **question**, commit the run's work
automatically — once, at end of run, on the plan branch. Stage narrowly (only paths
the steps' return contracts name — never `git add -A`, never a whole directory; the
pre-existing dirty paths in the run record must not appear in `git diff --cached`),
run the repo's own mandated pre-commit checks in their headless form first (apply
safe fixes; defer every ask-first decision into the commit body unapplied), and
record the commit sha in the run record. No mid-run commits — real plans carry
`Done when:` criteria that read the pre-change `HEAD`. The branch stays **local**:
push, PR, and merge remain hard stops, so "Offer `/mentor:tour`" and "Point at
`/mentor:ship`" close the run exactly as written above.

## Verifying the plan (execution-time)

Planning authors `## Verification` as `Topic N —` blocks (`planning`'s content spec), not
prose: the context that just ran the build is its weakest grader — it confirms what it
*meant* to do, not checks. Topics are never ticked, and `tick` cannot reach them: it
walks `## Implementation steps` only, so `tick <slug> 1` aimed at Topic 1 silently ticks
Step 1 instead. A verification round moves the plan with `set`.

- **One fresh verifier per topic, all dispatched in a single message.** Fresh means
  never an implementation agent from this plan, never a verifier reused across topics,
  never the agent that wrote a fix being re-verified — independence is the entire value
  of the dispatch.
- **Default `[role: general-purpose · model: sonnet · effort: medium]`**; step up to
  `opus` only when the topic's `Focus:` judges architectural coherence, security, or
  cross-cutting consistency, or the Topic block declares `[model: opus]` — an authored
  `effort:` overrides the default the same way. Verifiers **verify, never fix** —
  commands are fine (the `mktemp -d` rule above covers mutating checks), edits are not.
- **Legacy plans** (prose `## Verification`, approved before this grammar): derive one
  topic per bullet or sentence-group (shape in the contract file below), then dispatch
  normally, never self-check. **Missing or empty section**: ask the user rather than
  invent topics — they supply topics, which dispatch normally, or they explicitly accept
  the plan unverified; the defect is theirs to resolve, never yours to skip or fabricate.
- **Prompt/return contract**: `references/verifier-contract.md` — read before this
  session's first verifier dispatch; paste its "What the verifier must return" block
  into every verifier prompt verbatim. ("Deliver before idling" needs no pasting — the
  dispatch hook appends it.) A return
  with no `Gaps / Missing:` line is not a verdict yet — ask that same verifier for it
  ("Follow-up vs re-dispatch" below); silence is never `none found`.
- **Failure loop.** A `FAIL`, or any non-`none found` Gaps line even on a PASS, surfaces
  the round's gaps. Split them on the contract's stamp and **work every `[GOAL]` gap to a
  fixed point before assembling anything for the user** — a remediation dispatch routinely
  turns up more gaps, so a digest built while the set is still growing is stale before it
  is read.
  - **Re-check context first** — the same move as `planning`'s "Re-check context": run
    `bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" context` fresh rather than trusting
    an earlier reading. A verification round runs mostly on harness-synthetic prompts
    (inbound agent reports), which `context-gate.sh`'s own WARN tier deliberately skips,
    so a round can grow well past WARN with only `context-checkpoint.sh`'s rate-limited
    advisories having said so. This is a **context
    guard, not a disposition question**: at `WARN`, `ASK`, or `HANDOFF`, ask the one
    question the round gets — **remediate now, or hand off to a fresh session?** — and at
    `ASK` answer it with the two-option directive `context` prints itself rather than
    inventing a competing one. At `OK` or `UNKNOWN`, ask nothing and remediate. So a round
    whose gaps are all `[GOAL]` runs silently through to close-out; that is intended — the
    user asked not to be consulted about work the goal requires — and the closing report is
    where it surfaces.
  - **`[GOAL]` gaps are remediated, never asked about.** One dispatch by the file's
    implementation role; a skipped plan assigned none, so pick one the normal way
    ("Choosing `role`" above) — the skip covered the original edits, not their repair.
    Then a **fresh** verifier for that topic. A second failure on the same topic escalates
    to the user (the one-retry contract above) as an explicit verdict rather than a routing
    rule: **remediate again**, **park it as a fix child under this plan** — `parent` = this
    plan's slug, which is legal here because the user chose it, nesting when this plan is
    itself a fix child — or **hand off**, which sets `failed`.
  - **`[NON-GOAL]` gaps are never fixed on your own judgment and never parked on it
    either.** They accumulate across rounds, **deduped by handle** — a re-verify that
    re-reports an unfixed non-goal gap is the same finding, not a second one — and go to
    "The non-goal disposition gate" below once remediation has settled. That dedup is also
    the resume mechanism: a gate interrupted mid-walk simply leaves the plan short of
    `implemented`, and the next round re-presents whatever is still open.
  - **Hand off**: set `failed` with the unresolved topics as its note, then
    `mentor:handoff-note` with the verifier reports, then stop — `handoff-note` writes no
    plan state, so an all-ticked plan would read `implemented` to the next session. An
    unresolvable *verification topic* always exits this way, never as a stub.

  Remediations run **sequentially, never in parallel** — parallel fixes on shared files
  race — and that covers the gate's "Fix it now" dispatches below too. One asymmetry there
  is deliberate: a fix that fails on a `[NON-GOAL]` finding **never** sets `failed`, it
  records as left open. Electing to fix a cosmetic finding must not leave the plan worse
  off than declining to.
- **No escape hatch.** Runs even when the plan opened `Dispatch: skipped`. One allowance
  (**lite verify**): a skipped plan with ≤2 topics may dispatch **one combined fresh
  verifier** carrying both — independence holds, only the fan-out relaxes. `implemented`
  needs every topic PASS and every `[GOAL]` gap fixed; zero topics clears
  that vacuously, so a topicless plan gets there only on the acceptance above. Every
  `[NON-GOAL]` gap carries a user verdict — fixed, deferred, or left open — and the ones
  left open are written to the plan record in the same call:
  `set <slug> implemented --note "open: <handle>, <handle>"`. That
  combined verifier is itself a substitution — carry it into the report the same way
  the disclosure rule below asks of every other one, not just into a passing tick.

## The non-goal disposition gate

Every `[NON-GOAL]` gap the round accumulated is a decision the **user** makes, never one
you make for them. Deferral especially: mentor parks work on a verdict, never on its own
reading of what matters. Run this gate once, after remediation has settled and before the
`implemented` write.

**A stamp the verifier set stands — never re-grade it.** You are the context that built
the thing and wants the plan to close, which is exactly the pressure that re-reads a
`[GOAL]` gap as `[NON-GOAL]` and quietly buries it. **Unstamped** gaps are real and have
their own route: a verifier that ignored the contract, a `Cross-topic:` finding you
promoted to a round gap (those carry no stamp by construction), or work a dispatched
implementation agent reported from outside its step's scope. Ask that verifier for the
stamp, exactly as a missing `Gaps / Missing:` line is re-asked ("Verifying the plan"
above); if it comes back unstamped again, or there is no verifier to ask, treat it as
`[NON-GOAL]` and it rides through this gate with the rest.

1. **Digest.** One line per `[NON-GOAL]` finding, `[LARGE]` first: a 2–4 word handle, the
   size, half a sentence of what it is, and the verifier's `fix:` clause. Empty set → skip
   the gate and go straight to the report. **Size, not severity, drives the split below** —
   the opposite of how `plan-review` walks its findings, and worth holding onto if that
   skill is also in context. Severity was already spent on the `[GOAL]`/`[NON-GOAL]` call;
   what is left to decide is whether the user wants to spend a session on the fix.
2. **Walk the `[LARGE]` ones** — one `AskUserQuestion` each, the handle as its header, a
   `(<k> of <n>)` prefix, opening with one plain sentence naming the decision. In practice
   a round produces none to two of these. Options: **"Defer as its own plan"** /
   **"Fix it now in this session"** / **"Leave open"** / **"Skip the rest"** — the last
   leaves this finding and **every** remaining one open, batched ones included, so offer it
   only while findings still remain anywhere in the gate. Say in the question text that a
   narrower resolution is reachable through "Other".
3. **Batch the `[SMALL]` ones into ONE question.** Header `"Remaining <N>"`. Restate each
   finding as its own line *inside the question text* — the digest may have scrolled away,
   and a question that points back at earlier output is one the user has to leave the
   screen to answer. Three options: **"Fix them all now (Recommended)"** /
   **"Defer them all"** / **"Leave all open"**. Exactly one remaining finding collapses to
   a normal per-finding question instead.
4. **Apply the verdicts once they are all in**, in a single pass. Remediation dispatches
   stay sequential, per the failure loop above.
5. **A Defer verdict is itself the invocation** — run the capture rather than telling the
   user to retype `/mentor:defer`. Invoke `Skill(skill="mentor:deferring")` and state the
   routing as a prose preamble, the shape `planning` already uses when it prepends "The
   user selected …" ahead of a skill load: `from` = this plan, `parent` = **none**,
   `category` = the verifier's judgement, and **`priority` left unset** — an explicitly
   non-goal finding must not float to the top of `/mentor:track`'s build queue. The
   single exception to `parent` = none: a defect in an **already-implemented**
   plan's shipped work parks under *that* plan, which it genuinely blocks. If `deferring`
   refuses the item under its own scope rule, **record it left open and say so** — a
   verdict the user gave must not evaporate because the capture bounced.

   Then stamp each flat stub the capture created, using the slug it reported back:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" set <stub-slug> draft --note "gate: left uncontained"
   ```

   That note is what tells the rest of the harness this stub is flat **on purpose**;
   without it, every future `/mentor:track` and `/mentor:resume` would offer to adopt it,
   asking the user to reverse a decision they already made here. Skip the stamp on the
   already-implemented exception above: that stub has a `parent` and is contained.
   (Why an unstamped flat stub trips the lineage alarm, and why an unset `priority`
   matters: `references/rationale.md` → **Why a gate-routed stub is flat on purpose**.)
6. **Report three groups**, by handle: fixed, deferred (with their stub slugs), and left
   open — plus the verifiers' `Notes:` lines as context, unverdicted. The left-open group
   is exactly what the `implemented` write records as `--note "open: …"`.

Each question follows the relay rule in "Context efficiency — the orchestrator contract"
above: strip the agent-side ids, carry the finding rather than its filing, and let the
question stand on its own.

## Async runtime & lifecycle

Dispatched agents run as background teammates: they can signal **idle** before
(or instead of) delivering, die mid-flight on infra errors, and stay resident
after finishing. These rules govern every dispatch surface in mentor — this
skill, plus the dispatches in `plan` Steps 2 and 3.5, `plan-domain-dynamic`'s
domain-definer (reached from `plan` Step 3's routing, and dispatched ahead of
Step 2's research agents), `zoom` (which `plan` Step 5 delegates to),
`plan-review`, `tour`, `plan-tour`, `plan-split`, `grilling`, `ship`, `merge`,
and any ad hoc fan-out reached from `resume` (each cross-references this
section). **Keep this roster current when a surface starts dispatching** —
a reader who checks it and does not find their surface concludes
the contract does not apply to them, which is exactly how a fan-out goes out raw:

- **Every surface on this roster gets the standing block for free.** Since v2.34.0
  `hooks/dispatch-contract.sh` injects it into every `Task`/`Agent` prompt, so a surface
  no longer has to load this skill just to reach it — most on the roster now run
  `plan-state.sh policy` instead, one call, which also reports whether that injection is
  actually live. What a surface still owes is that preflight: the hook fail-softs silently
  when `jq` or the contract file is missing, and `CONTRACT: MISSING` is the only thing
  that would say so. When adding a surface here, confirm it carries the preflight.
- **A delegated step's fan-out is still yours.** When a plan step hands its
  work to another plugin's own multi-agent skill, the main thread runs that
  skill — its agents are dispatched from this session and land in this
  session's dispatch tree, so **No busy-wait** applies while they run (end the
  turn; the harness re-invokes you) and close-out enumerates them like any
  other. What does not reach them is the standing contract block below: you
  never wrote their prompts, so they may return by plain final text and may
  spawn further agents. Enumerate at close-out rather than trusting that the
  delegated skill closed its own out.
- **Standing no-subagents policy.** Before this session's first dispatch, check for a
  *standing* instruction against subagent use recorded somewhere durable — CLAUDE.md, a
  project rule file, an earlier session's handoff note — as distinct from the user saying
  so live in this session (that case needs no check: honor it directly, per `plan-review`'s
  "When NOT to use"). Run the shared preflight — never a `grep` you
  compose yourself, because `.mentor/` is gitignored and a recursive grep reads nothing
  there while reporting a clean zero indistinguishable from "no policy recorded":

  ```bash
  [ -d "${CLAUDE_PLUGIN_ROOT}/hooks" ] || { echo "ERROR: CLAUDE_PLUGIN_ROOT unresolved or stale — do not search the plugin cache or hardcode a version path; ask the user to /reload-plugins or restart" >&2; exit 1; }
  bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" policy
  ```

  It prints its verdict in words, so there is no exit code to interpret.

  - **`POLICY: SET (dispatch=…)`** → the user already answered this, for this repo. Honor
    it and **ask nothing** — `agents` routes per "Where dispatch pays", `verify-only`
    implements in-thread and still dispatches verification, `solo` keeps both in-thread
    and owes the report a disclosure that the plan carries no independent grader —
    except inside an instant run, where the per-step loop still dispatches its one
    fresh prose-criterion verifier ("Unattended continuation" item 4, user-ruled),
    disclosed in the run record. Nothing
    here is re-litigated per plan or per session; that re-litigation is the whole reason
    the key exists.
  - **`POLICY: NONE`** → route per "Where dispatch pays".
  - **`POLICY: FOUND`** → a standing instruction is on record and it conflicts with the
    routing test. Ask **once**, then **record the answer** so no later surface in this or
    any future session asks again:

    ```bash
    bash "${CLAUDE_PLUGIN_ROOT}/hooks/set-mode.sh" <agents|solo|verify-only>
    ```

    One `AskUserQuestion`, header `Dispatch`, these three options in this order:
    **"Main thread, but still verify independently (Recommended)"** → `verify-only` /
    **"Keep everything in the main thread"** → `solo` / **"Route per the plan's own
    test"** → `agents`. `verify-only` leads because it honors the policy where the policy
    has a real argument — implementation — while keeping the fresh grader, which is the
    part a plan cannot replace. Say in the question that the answer is remembered for this
    repo and changeable with `/mentor:mode`.

    **Quote the policy, not a premise you did not check.** Standing instructions of this
    kind often justify themselves with a reliability claim — that dispatched agents go
    idle without delivering. Measured across 2,495 dispatches in this user's own repos,
    none failed that way (`references/rationale.md` → **Where dispatch pays**). Present
    the decision on its cost, and if the recorded reason is a reliability one, say plainly
    that it is worth re-checking rather than repeating it back as established fact.
  - **`POLICY: UNRESOLVED`** → the check could not run, so the question stays open; never
    read it as "no policy".

  The same call's `CONTRACT:` line reports whether the standing block below will actually
  reach your agents — the one thing no skill can verify by reading itself.
- **A substitution is disclosed as a substitution.** Any of the shapes above — a
  fan-out that ran with fewer agents than the contract called for, a delegated skill's
  own agents declining or being unavailable, a step the standing policy just above kept
  in the main thread, `lite verify`'s one combined verifier standing in for two
  independent ones — changes what actually backed a result, and the report has to say
  so next to that result, not leave it implied. `mentor:shipping` Step 3 is the worked
  case: a solo diff review is reported **as** a solo diff review, because reporting the
  substitute as though the full step ran is what turns a judgment call into a false
  green. **This is not a license** — it does not cover the surfaces on this roster that
  forbid running solo at all (`zoom` and `plan-tour` never hand-render in the main
  thread, `plan-split` never hand-authors a child, and verification's "No escape hatch"
  above has no fallback beyond the one named allowance): there, a solo attempt is a
  contract violation to stop and flag, never a substitution to disclose.
- **No busy-wait.** Waiting is not work: never chain `sleep`s, fire no-op Bash calls,
  or reach for `ScheduleWakeup` to pass the time. This governs **every** waiting surface
  in a mentor session, not only dispatched agents — a long build, a background test
  suite, a deploy. When something else will wake you (a dispatch completing, a
  backgrounded command exiting), **end the turn** and let the harness re-invoke you.
  When nothing will, make **one** bounded blocking call — `until ! pgrep -f <proc>; do
  sleep 5; done`, or a monitor/wait tool — sized under the Bash timeout ceiling (600s).
  One case sits outside that binary: a wait on a live external system the user is
  watching in the foreground, with no bounded local completion signal — ask once via
  `AskUserQuestion` (poll now / hand the check to the next session) rather than starting
  the poll unasked. (Why `ScheduleWakeup` fails here specifically, and why a sleep chain
  breaks in the middle: `references/rationale.md` → **No busy-wait**.)
- **A batch dispatched together is joined together.** When one message dispatches N
  agents as one fan-out (a `zoom` combo set, `plan-review`'s reviewer round, any
  parallel batch), the batch isn't done until its **last** agent's signal arrives —
  don't act on or narrate the batch after its first, third, or ninth idle/report
  while others are still outstanding. This is the same single **end the turn** from
  **No busy-wait** above, just applied to N outstanding signals instead of one: each
  wake-up in between gets silently absorbed (per "An echo from an already-stopped
  agent gets no reply and no narration" below) rather than re-entering the
  orchestrator's attention, so a 12-agent round costs one wait, not twelve.
- **Deliver before idling — the standing prompt contract.** Every dispatched agent
  needs runtime directives it has no other way to learn: the no-nested-fan-out ban, the
  no-poll rule, progress-at-phase-boundary reporting, the hand-back-on-overrun clause,
  applying a mid-run correction before returning, mandatory `SendMessage` delivery
  before going idle with the exact verification commands copy-pasteable, git-index
  hygiene, and the durable-copy rule for verdicts. Its single source is `hooks/dispatch-contract.txt`,
  and `hooks/dispatch-contract.sh` (`PreToolUse`, matching `Task`/`Agent`) appends it to
  every dispatch prompt automatically — so **do not paste it by hand**, and do not
  paraphrase it in a prompt sketch. Confirm it is live with `plan-state.sh policy`
  before the session's first dispatch; its `CONTRACT:` line is the only thing that
  reports the hook's silent fail-soft. (Why it is injected rather than pasted:
  `references/rationale.md` → **The standing prompt contract**. The block's text
  itself is only in `hooks/dispatch-contract.txt`.)
- **Idle-before-report race.** An idle notification can arrive before the agent's
  report, and — with several sessions running concurrently — can even name a task this
  session never dispatched. **Check the id against this session's own dispatch tree
  before reacting:** `SendMessage` to a foreign id succeeds and lands on a stranger's
  live agent, with no id-not-found safety net of the kind that protects `TaskStop`. An
  unrecognized id gets no reply of any kind. On idle **with a recognized id** and no
  report in hand: check the message backlog, then send ONE nudge — *"Status check on
  Step N: send your completed result now — full text, per the return contract. If you
  are still working, reply with the one thing that's left."* Do not restate the step's
  criteria; the agent's context is warm and a re-brief invites it to redo finished work.
  Only if the nudge fails, fall back to independent re-verification. Never re-run
  expensive verification (full builds, E2E suites) while the agent's own report may
  still be in flight, and an idle arriving from an already-`TaskStop`ped agent needs no
  reply at all. (What to write in the plan file when a step closes with no author report
  ever received: `references/rationale.md` → **Idle-before-report race**.)
- **An echo from an already-stopped agent gets no reply and no narration.** Not a
  nudge, not "Agent X already stopped, ignoring" — nothing. On a dispatch-heavy
  plan the whole batch is worth at most one dismissed-count line at close-out, and
  only if it earns one. An echo arriving *after* the plan was announced
  `implemented` is the same non-event: it reopens nothing, and narrating it reads
  to the user as new activity — which is how a finished plan collects a second
  "mark it done" round-trip.
- **Agent died (infra/API error).** Don't reinvent recovery glue: wait with
  escalating patience (minutes-scale, roughly doubling — this sanctioned wait
  for a *dead* agent is not the busy-polling of a healthy one forbidden
  above), then send a resume message: "You died on an infra error mid-step.
  Resume Step N where you left off. Already applied: <paste state>. Your
  `Done when:` <verbatim>." Two failed resumes → fresh re-dispatch of the role.
  **A failure string naming a reset time** ("hit your session limit · resets
  2:50pm") is a quota wall, not an infra blip: don't wait it out, don't
  resume-message. Snapshot what each dead agent already landed, report the
  reset time, and end the turn.
- **Follow-up vs re-dispatch.** A small fix or clarification on work an agent
  already owns — idle **or still running** → send ONE message to that same
  agent (its context is warm; use your runtime's agent-messaging tool — in
  Claude Code that is `SendMessage`, which — like `TaskList`/`TaskStop` below —
  may need fetching via `ToolSearch` first; `select:SendMessage,TaskList,TaskStop`
  in one call loads all three async-lifecycle tools together, so whichever of
  them you reach for first primes the rest). State that the correction must be applied before
  the agent returns. This matters most when something you learn *after*
  dispatching invalidates part of a brief already in flight — a reviewer's
  finding landing while a writer works from the superseded version. Correcting
  it in place beats both alternatives: letting a known-wrong artifact land, or
  re-dispatching a whole combo that was 90% right. A failed `Done when:`
  needing a clean rebrief → re-dispatch the role once (per the orchestrator
  contract above). **Verify the correction landed.** Sending the message is not
  the same as it taking effect, and unlike a step's own delivery this has no
  `Done when:` to re-check it against — apply the same trust-but-verify rule by
  hand: re-read or grep the target artifact for the exact text you asked for
  once the agent reports, and treat a reply that only *describes* the fix as
  unverified.
- **Step stalled / the user interrupts it.** A step that goes dark — no output, no idle
  signal, no death — has no notification coming, so the wake-up is usually the user
  asking why it is taking so long. Debugging the step's subject matter by hand is the
  escape hatch reserved above for a *second* failed `Done when:`, and reaching for it
  early leaves the main thread owning a debugging session it has no context for. Stay
  orchestrator-shaped instead (what that costs when ignored:
  `references/rationale.md` → **When a step goes dark**):
  1. **Snapshot observable state only** — `git log --oneline -5`, `git status --short`,
     `git diff --stat`, a listing of the step's artifact dir. Kill processes the step
     leaked (a browser runner, a stray container) so the re-dispatch starts clean.
  2. **Delegate the diagnosis** — dispatch ONE read-only `Explore` agent pointed at the
     artifact paths and the failing command, and let it return a cause.
  3. **Re-dispatch the role with that diagnosis attached**, counted against the
     one-remediation budget above. Handing a warm diagnosis to a fresh agent is what
     actually closes these steps.

  Keep secrets out of the snapshot: commands that print a process or container
  environment (`docker inspect` over `.Config.Env`, `printenv`, `env`) dump live API keys
  straight into the transcript, and the transcript outlives the turn — `/mentor:handoff`
  reads it back, and so does anyone reviewing the session. Name the one variable you
  need, or check a value's *presence* rather than printing it.
- **Close out.** Once a dispatch's output is consumed and its `Done when:`
  verified, stop/release the agent — finished agents left idling interrupt
  the session with stray notifications and pile up until manually killed.
  Closing out only the agents you remember dispatching misses a nested spawn
  (No nested fan-out, above), which stays resident with no notification of
  its own to prompt you. **Before the final report, before escalating on a
  stalled or failed step, and before any prose claim that a batch is
  "done"/"closed out"/"finished"** — a flow with more than one dispatch round
  (stage-1 reviewers, then a stage-2 fan-out; a plan-review pass followed by a
  zoom pass) makes each intermediate closure claim as real a checkpoint as the
  session's last one — enumerate live tasks: in Claude Code that is `TaskList`
  (see the `SendMessage` note above for the one combined `ToolSearch` fetch
  that covers this too), diffed against this session's own dispatch tree,
  nested spawns included. Stop only what traces to that tree with
  `TaskStop`; note anything else in the one-line report rather than
  stopping it, since it may belong to a sibling session or the user's own
  background work. **The same checkpoints are also the right moment to
  re-check context** — run `bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh"
  context` here too, not only on the failure loop's remediation path
  ("Verifying the plan" above). A verification round runs mostly on
  harness-synthetic prompts, which `context-gate.sh`'s own WARN tier
  deliberately skips, and an all-PASS round never enters the failure loop at
  all — so a clean round can walk straight into the final report with
  whatever context reading it last took, if any. `context-checkpoint.sh`'s
  between-batch advisories (v2.37.0) narrow that gap but are rate-limited
  and easy to sail past, so this deliberate re-check stays. `CONTEXT: WARN`
  or higher belongs in the final report itself (a line naming
  `/mentor:handoff`), not silently absorbed.
- **A live `Monitor` watch is not a dispatch — it has no stop tool.** A CI run, a
  deploy, or a long build tracked via `Monitor` should usually keep running
  (killing it is rarely what you want, unlike a stray dispatched agent). At the
  same close-out checkpoints as above — the final report, escalating on a
  stalled step, any "done"/"closed out" claim, and a handoff — either let it
  resolve first, or record its status as still outstanding plus the exact
  command the next reader uses to get its verdict. Leaving it unmentioned is
  what strands it.
