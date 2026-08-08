---
name: dispatch-agents
description: >
  The default implementation path for mentor plans (subagents-driven
  development) — annotate every plan's implementation steps as subagent
  dispatches and execute them after approval; the main thread orchestrates,
  subagents implement. Invoked by plan Steps 4 and 6, or when the user says
  "dispatch agents" / "fan out" / "parallelize". Trivial work may skip with a
  stated `Dispatch: skipped` reason.
---

# Dispatch Agents

This skill defines the annotation grammar for plan steps that fan out to
subagents, and how to execute them. It is the default implementation path for
mentor plans, used by `plan` (Step 4 annotation, Step 6 execution) and
referenced by `plan-review` and `handoff`.

## When to use

This is the DEFAULT for every mentor plan: `plan` Step 4 invokes this skill to
annotate the implementation steps, and Step 6 invokes it again to execute them
after approval. Also invoked when the user explicitly says "dispatch agents",
"fan out", "use subagents", "parallelize this".

**Also load it for any ad hoc fan-out that is not plan implementation** — a
research sweep, a multi-repo survey, an architecture-gap audit, a handoff note
that says "dispatch parallel `Explore` agents". The annotation grammar and the
plan mechanics do not apply to those; the "Async runtime & lifecycle" contract
does, and it is the whole reason to be here. Skipping the skill because the work
has no plan is how a nine-agent fan-out goes out without the deliver-before-idling
block and returns one report.

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
mechanic here (approved-plan read, ✅ ticks, `plan-state.sh`, the gate) has no
counterpart and is skipped, and `/mentor:defer` redirects: a follow-up belonging to
that framework's backlog goes there, not into a mentor stub (repo work outside its
scope still defers normally). Three rules hold on this path:

- Copy `Goal:`/`Done when:` **verbatim from the task's own text** and verify the
  delivery against that text — your brief is a lossy transcription of it.
- Never let the record **drift from the work**: the orchestrator, not the agent, lands
  each check-off in the same commit as that task's own work — never batched, never
  left dirty for a later task to sweep in.
- Write that progress line and **nothing else** in the framework's files. A spec
  conflict blocking a `Done when:` goes to that framework's own amend command — mentor
  never edits another framework's artifact of record.

If this work should be gated, mentor should own the plan: `/mentor:plan`.

## Escape hatch — when a plan may skip annotation

Skip dispatch annotation ONLY when one of these branches holds:

- **Trivial:** the whole implementation is a small mechanical change (roughly
  ≤ ~20 changed lines) AND the main thread already holds everything needed
  from planning — implementing requires no new file reading; or
- **Interactive:** the work needs tight mid-implementation back-and-forth with
  the user.

A skipping plan MUST open its `## Implementation steps` section with one line —
`Dispatch: skipped — <one-line reason>` — so the skip is visible and reviewable
at approval. No line, no skip. If a skipped implementation turns out
non-trivial mid-flight, stop and dispatch normally per this skill.

**Check the skip against the plan you actually wrote.** The step count is the
cheapest honest test: a plan carrying more than about two steps, or any step whose
`Done when:` needs a service brought up, a browser driven, or a screenshot compared,
is not "a small mechanical change" however mechanical each individual edit looks —
re-annotate it. The reason to be strict here is that this line is load-bearing far
beyond dispatch: everything downstream of it — step ticks, `/simplify`, the closing
checklist, the acceptance pass — is written once for the dispatch path and only
*restated* for the skipped one, so an over-claimed skip is how a plan quietly loses
all of it at once.

## Context efficiency — the orchestrator contract

The point of SDD: quality through narrow focus, and a lean main thread.

- **The main thread MUST NOT read the implementation files a step delegates** —
  that context belongs to the dispatched agent. Verify `Done when:` with
  observable checks instead; the step's `git diff` and a failing command's
  output are always in-bounds as diagnostics.
- **Prefer executable pass/fail `Done when:` criteria** (the named test /
  typecheck / lint command) over presence checks; use grep/ls checks only when
  no runnable check exists. **When the check itself mutates the artifact it
  verifies** (an importer, a migration runner, a `--write` formatter, a seed
  script), running it live means the verification consumes the very thing it
  was meant to confirm — run it against a `mktemp -d` copy outside the repo
  instead, diff/compare, then discard. When the check can't run detached
  (needs live git context, a database, or a running service), snapshot state
  and restore it after, or point the check at a disposable instance.
- **On a failed `Done when:`**, re-dispatch the same role once with the failure
  evidence (diff + command output) as inputs. If it fails again, surface to the
  user — only then may the main thread read the files and take over.
- **Track progress in the plan file:** as each step's `Done when:` passes, run
  `bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" tick <slug> <N>` (N = the
  step's ordinal, counting either `Step N — …` or numbered-item lines) to append
  `✅` to that step's own top line. Which line carries the tick is load-bearing,
  not cosmetic: mentor counts ticks by scanning step lines only, so a `✅` parked
  on the indented `Done when:` line that just passed, or any other sub-line, is
  invisible to it and the step reads as never started — `tick` locates the
  step's own line for you instead of trusting a hand-built `Edit` to land on the
  right one, and is idempotent (re-ticking an already-ticked step is a no-op) and
  fails loud on an out-of-range N rather than silently writing nothing useful.
  These ticks are also what makes plan state self-healing — mentor derives
  `in_progress` / `implemented` from them, so a forgotten tick costs nothing on
  its own, but a tick on the wrong line silently costs the next session its
  picture of what landed, which is what `tick` exists to prevent.
- **Move the plan's state as you go**, so `/mentor:track` can answer "what is
  built?" in a fresh session without re-reading anything:
  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" set <slug> in_progress    # before the first dispatch
  bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" set <slug> implemented    # every Done when: passed
  bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" set <slug> failed --note "<what broke>"
  ```
  `<slug>` is the plan's directory name. Set `failed` at the escalate-to-user
  point — after the one remediation re-dispatch has also failed. That one is
  worth remembering, because unlike the others it cannot be derived from ticks,
  and the note is what makes the retry cheap.
- **Prompt sketches must be self-contained.** Each agent starts with zero
  memory of this conversation **and no inherited project context — assume it
  never read CLAUDE.md or your repo's conventions**: give exact file paths,
  the approved plan path,
  the distilled facts it needs from research or prior steps (paste result
  lines, not files), and its `Done when:` verbatim. Every **implementation**
  brief additionally carries the solution-quality line: `Implement the most
  practical and clean solution — never trade maintainability or reliability
  for implementation speed.` (read-only roles like `Explore` are exempt — the
  line governs how something is built, not how it's found.)
  That line and the standing contract block ("Deliver before idling" below) are
  appended verbatim at dispatch time — a `Prompt sketch:` is the *middle* of a
  prompt, never the whole of it.
- **Return contract:** agents return a short summary, file paths touched, and
  verification output — never full file bodies. Verification output must include the
  exact command(s) that produced it, copy-pasteable — otherwise re-verifying against an
  API the orchestrator hasn't read means re-deriving the command blind.
- **Relaying a return to the user strips its ids.** An agent's report is written
  for **you**: its finding codes, table rows, step numbers, and bare `Location(s)`
  cells name things the user never read. Carry the finding, not its filing — say
  what the thing is ("the Argo controller reads cross-tenant Secrets") and leave
  the code in your notes; if one must survive because the user holds the artifact
  it indexes, it rides behind the name, never alone. The same holds when the relay
  becomes a question: **every question stands on its own**, answered from the
  question screen alone, never sending the user to a file, a report, or an earlier
  turn to learn what it means.
- **No nested fan-out:** dispatched agents **can** call the Agent tool — nothing
  in the runtime stops them, and a chain they spawn is invisible to you and
  outlives your close-out. Size each step so one agent completes it alone; the
  contract block below is what actually holds the line.
- **Work discovered mid-flight is captured, not lost.** If the orchestrator or a
  dispatched agent notices real work outside the current step's scope, capture it with
  `/mentor:defer` (one item or several) and keep going — never leave it as an aside in
  a chat message that disappears at session end.

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

## Choosing `role`

The authoritative list of `role:` values is the `Agent` tool's `subagent_type` enum in your current tool spec — the set of agents actually installed and enabled. Do **not** scan `~/.claude/agents/` or plugin `agents/` folders on disk — those can list disabled plugins. If nothing in the enum fits, fall back to `general-purpose` and put the specialty in the prompt.

| Need | Role |
|---|---|
| Locate code, grep symbols, find files | `Explore` |
| Design implementation strategy / architecture | `Plan` |
| Open-ended research, code edits, multi-step | `general-purpose` |
| Domain-specific (platform browsing, Jira, etc.) | the matching project agent |

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
5. **Assign roles.** Smallest specialist that covers the work.
6. **Assign models.** Default `sonnet`; upgrade only with a reason.
7. **Assign effort.** Default `medium`; upgrade for design/cross-cutting, downgrade for trivial.
8. **Write prompt sketches.** Each agent has zero memory of this conversation — the brief must stand alone. If a `Done when:` is a long test suite, brief the agent to iterate on a filtered subset and run the suite whole only as the final gate.
9. **State done-when.** Observable, verifiable, no "looks good".

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

1. **Read the approved plan file** (`<repo>/.mentor/plans/<slug>/plan.md`) — do not work from memory.
2. **Dispatch "Run in parallel:" groups** — issue ALL `Agent()` calls for each parallel group in a **single message** so they run concurrently. Every prompt ends with the solution-quality line plus the full standing contract block ("Deliver before idling," "Async runtime & lifecycle" below) **pasted verbatim** — compressing it to a paraphrase (even a well-intentioned one-liner) silently drops directives a dispatched agent has no other way to learn, including the no-nested-fan-out ban this exact block is what enforces. After dispatching, apply **No busy-wait**: stop and let the harness re-invoke you when agents complete.
3. **Dispatch "Sequential:" steps one at a time** — wait for the prior step's result before issuing the next call.
4. **Verify each `Done when:` criterion** before moving to the next step — agents describe what they intended; trust but verify.
5. **CLOSING CHECKLIST — always, after the last step verifies:**
   - **Close out finished agents** — enumerate live tasks with `TaskList` and diff
     against this session's own dispatch tree, nested spawns included, before
     `TaskStop`ping only what traces to that tree; stopping just the dispatches
     you remember by name misses a nested spawn (see "Async runtime & lifecycle"
     below for the full rule).
   - **Offer `/mentor:tour`** — one line: a hands-on acceptance pass building an editable guided-tour review artifact (pass/not-pass scenarios) of what shipped. Do not auto-run it.
   - **Sweep the report you're about to write** — every follow-up, gap, or known-broken
     item in it goes through `/mentor:defer` first (orchestrator contract above).

Do NOT paraphrase the plan or summarize what you're about to do. Dispatch immediately.

## Async runtime & lifecycle

Dispatched agents run as background teammates: they can signal **idle** before
(or instead of) delivering, die mid-flight on infra errors, and stay resident
after finishing. These rules govern every dispatch surface in mentor — this
skill, plus the dispatches in `plan` Steps 2 and 3.5, `zoom` (which `plan` Step 5
delegates to), `plan-review`, `tour`, `plan-tour`, `plan-split`, `grilling`,
`ship`, `merge`, and any ad hoc fan-out reached from `resume` (each
cross-references this section). **Keep this roster current when a surface starts
dispatching** — a reader who checks it and does not find their surface concludes
the contract does not apply to them, which is exactly how a fan-out goes out raw:

- **No busy-wait.** Waiting is not work: never chain `sleep`s or fire no-op Bash
  calls to pass the time. This governs **every** waiting surface in a mentor
  session, not only dispatched agents — a long build, a background test suite, a
  deploy. When something else will wake you (a dispatch completing, a backgrounded
  command exiting), **end the turn** and let the harness re-invoke you. When nothing
  will, make **one** bounded blocking call — a condition loop such as
  `until ! pgrep -f <proc>; do sleep 5; done`, or a monitor/wait tool — sized under
  the Bash timeout ceiling (600s). A chain of short sleeps burns a turn apiece, and
  the harness blocks bare foreground `sleep` outright, so the chain tends to fail in
  the middle and leave the wait half-done. The block below carries an
  agent-shaped copy of this rule — deliberately without "end the turn", which a
  dispatched agent must never do undelivered.
- **Deliver before idling — the standing prompt contract.** Every dispatched
  prompt, on every surface, ends with this block pasted verbatim. The other
  surfaces cite this section by name rather than copying the block, so a skill
  that dispatches without loading this one must `Read` this block first —
  otherwise the contract never reaches the agent:

  ```
  Do not call the Agent/Task tool — you have no sub-agents. Complete this alone,
  or stop and report the blocker.
  Never poll to pass time (`Bash true`, chained `sleep`s). Wait with ONE bounded
  call: `until <check>; do sleep N; done` (under 600s), a backgrounded run, or a
  monitor tool.
  If this step runs long, send a one-line progress message at each phase boundary
  (what just finished, what is next). The orchestrator ended its turn after
  dispatching you, so your messages are the only thing that can wake it — silence
  is indistinguishable from a hang, and the session's only remaining recovery is a
  human noticing.
  If a correction to this brief arrives mid-run, apply it before you return.
  Deliver your full result (final text / message per your runtime) BEFORE going
  idle — an idle signal with no delivered result is a contract violation. Include the
  exact command(s) that produced your verification output, copy-pasteable.
  If you are producing a verdict or report (reviewer, verifier), also write a
  durable copy to `<repo>/.mentor/plans/<slug>/` (e.g. `step-N-review.md`)
  before returning — a dropped notification must never be the only copy of
  completed work.
  ```
- **Idle-before-report race.** An idle notification can arrive before the
  agent's actual report. On idle with no report in hand: check the message
  backlog, then send ONE nudge: "Status check on Step N: send your completed
  result now — full text, per the return contract. If you are still working,
  reply with the one thing that's left." Do not restate the step's criteria —
  the agent's context is warm, and a re-brief invites it to redo finished work.
  Only if the nudge fails, fall back to independent re-verification. Never
  re-run expensive verification (full builds, E2E suites) while the agent's own
  report may still be in flight. The race also resolves in the other direction:
  an idle notification arriving from an agent **already** `TaskStop`ped needs no
  reply at all — the stop already closed it out.
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
  contract above).
- **Step stalled / the user interrupts it.** A step that goes dark — no output, no idle
  signal, no death — has no notification coming, so the wake-up is usually the user
  asking why it is taking so long. The temptation then is to start debugging the step's
  subject matter by hand: container logs, database queries, reading the artifacts. That
  is the escape hatch reserved above for a *second* failed `Done when:`, and reaching for
  it early means the main thread inherits a debugging session it has no context for —
  guessed column names, dead ends, and a context window spent on someone else's step.
  Stay orchestrator-shaped instead:
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
  background work.
