---
name: dispatch-agents
description: >
  Routing, annotation grammar, and the async runtime contract for any fan-out of
  work to subagents. Verification, review, and research always dispatch — an
  independent grader is the product there, not an optimization. Implementation has
  to earn it: dispatch only when two or more file-disjoint steps can be in flight
  at once, otherwise keep it in the main thread with a stated `Dispatch: skipped`
  reason. Verification dispatch has no skip on a mentor plan. Use this whenever
  work is about to fan out — a plan's implementation steps, a research sweep, a
  multi-repo survey, a verification round — or when the user says "dispatch
  agents", "fan out", "use subagents", "parallelize this".
---

# Dispatch Agents

## Host portability

Use a structured question UI when the host offers one; otherwise ask the same focused question directly and wait for the answer. If delegated agents are unavailable or prohibited, perform the required research, review, or implementation serially and retain the same evidence, scope, and verification contract. Treat Mentor helpers as optional host integrations: resolve them with `PLUGIN_ROOT` first, then `CLAUDE_PLUGIN_ROOT`; if neither is available, work from the repository's durable `.mentor/` artifacts and report any state action that cannot be performed safely. This rule overrides later host-specific tool names, preserving user choice and plan continuity across hosts.

This skill decides **where each kind of work runs** — main thread or dispatched
subagent — and then carries the annotation grammar for the steps that do fan out and
the contract for executing them.

## When to use

Load this whenever work is about to fan out to subagents: routing and annotating a
plan's implementation steps, executing those steps after approval, or an explicit
"dispatch agents", "fan out", "use subagents", "parallelize this".

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

## Two preconditions this skill does not establish for you

Before the first implementation dispatch, confirm both yourself. They are separate
reads — `context` answers only the second:

```bash
bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}/hooks/plan-state.sh" query --slug <slug> --fields state --format tsv
bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}/hooks/plan-state.sh" context    # CONTEXT: ASK|HANDOFF|WARN|OK|UNKNOWN
```

- **The plan is not `draft`.** A `draft` plan is one the approval gate never
  released, and dispatching against it implements something nobody approved.
- **The session is big enough to finish.** Dispatching a full implementation with
  nothing measuring the session is how a run dies mid-plan with no handoff — act on
  the tier `context` prints rather than noting it and carrying on.

Executing a plan this session didn't author — a fresh session, a handoff, one of a
`/plan-split` group — is what `/mentor:track` is for: it picks the plan, reads its
state, and re-enters an interrupted run at the first unticked step rather than
rebuilding from step 1. That is the convenient route, not a required one.

## When NOT to use — another framework owns the plan of record

Work already planned elsewhere (spec-kit's `tasks.md`, a Jira epic): do not author a
mentor plan or run an approval question over it. Annotate that framework's phase with the grammar below and execute. What that path skips,
why it is self-graded, and its three rules for touching that framework's files are in
`references/other-framework-path.md` — read it before the first dispatch on such a phase.

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
   This is the same test as the decomposition rubric's **Find independent steps**, and
   colliding parallel edits are the failure mode here that costs the most to unwind.
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
  does not spend that re-dispatch:** any dispatched agent — implementer, verifier,
  reviewer, a `zoom` combo or a `plan-split` child author — that delivers partial work
  plus a remainder brief did what the standing contract asks of it, so verify what it
  actually claims and dispatch the same role fresh with the remainder as its `Inputs:`.
  This holds wherever the return lands, the verification failure loop below included.
  That chain is bounded at one — a second hand-back means the step
  was mis-scoped, so put the re-scope to the user instead of letting it slow-bleed across
  N contexts.

**Recording what happened**

- **Tick each step as its `Done when:` passes:**
  `bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}/hooks/plan-state.sh" tick <slug> <N>` (N = the step's
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
  [ -d "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}/hooks" ] || { echo "ERROR: Mentor helper unavailable — set PLUGIN_ROOT (or use the Claude compatibility fallback) or use the documented artifact fallback" >&2; exit 1; }
  bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}/hooks/plan-state.sh" set <slug> in_progress    # before the first dispatch
  bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}/hooks/plan-state.sh" set <slug> implemented    # every Done when: + Verification PASS
  bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}/hooks/plan-state.sh" set <slug> failed --note "<what broke>"
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
- **Return contract:** agents return a summary under ~300 words, file paths touched, and
  verification output — never full file bodies, whole diffs, or long logs, which go to a
  file beside the plan and cited in the reply instead. The cap is a default, not an
  override: a brief that sets its own cap or return shape governs — `plan-review`'s
  600-word reviewer, `touring`'s uncapped manifest, and a verifier's
  `references/verifier-contract.md` block all ship in full. Verification output must
  include the exact command(s) that produced it, copy-pasteable, or re-verifying means
  re-deriving the command blind. The ceiling ships to agents in
  `hooks/dispatch-contract.txt`; **adjudicate detail from the durable copy, not by asking
  for a longer reply** — a dispatch-heavy plan pays this cost 9–15 times, and the
  orchestrator's context is the one thing in the session that never compacts.
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

  When a defer **is** the verdict, `deferring` fixes the parent link from one question —
  which plan's work does this item block from being *really* done? — and this skill states
  no competing answer (`mentor:deferring` → **blocking vs backlog**). The gate's own
  default of flat is in `references/non-goal-gate.md`.

## Per-step output shape

Each step in the plan must be annotated as:

```
Step N — <short title>  [role: <subagent_type> · model: <opus|sonnet|haiku> · effort: <low|medium|high>]
  Goal: <what this step must produce>
  Inputs: <files / facts / prior-step outputs the agent needs>
  Prompt sketch: <2–4 lines briefing the agent like a smart colleague who just walked in>
  Done when: <observable acceptance criterion>
```

Nothing is ticked at authoring time — ticking happens at execution, per
**Recording what happened** above, which states where the `✅` lands and why.

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

The authoritative list of `role:` values is the current host's worker-role capability list — the
set of agents actually installed and enabled. Do **not** scan a host cache or plugin `agents/`
folder on disk — those can list disabled integrations. If no role fits, use the general-purpose
worker role and put the specialty in the prompt; if no worker capability exists, execute serially.

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
4. **Collapse small dependent steps.** Adjacent `Sequential:` steps that are individually small (combined ≤ ~40 changed lines) and suit the same role/model merge into ONE step, and so into one dispatch — `one plan step = one dispatch` holds in both directions, which is why **Budget each step to one agent's context** below splits an oversized step into steps rather than into dispatches. Don't pay agent startup per tiny step.
5. **Budget each step to one agent's context.** A dispatched agent never compacts, so
   every tool result and every thinking block it emits stays in its context until the
   step ends. Nobody can count those calls while authoring, so size by smells instead:
   the five that mark an oversized step, and how to split one, are in
   `references/decomposition-smells.md`. Read it while sizing steps — it is the single
   copy, so an author and a reviewer can't end up working from drifted lists.
6. **Assign roles.** Smallest specialist that covers the work.
7. **Assign models.** Default `sonnet`; upgrade only with a reason.
8. **Assign effort.** Default `medium`; upgrade for design/cross-cutting, downgrade for trivial.
9. **Write prompt sketches.** Each agent has zero memory of this conversation — the brief must stand alone. If a `Done when:` is a long test suite, brief the agent to iterate on a filtered subset and run the suite whole only as the final gate. When any step's `Done when:` runs tests, resolve the repo's test invocation **once per session** — `mentor:shipping` Step 4's own order (`.mentor/config.json`'s `test_command` first, else auto-detect, confirmed once it actually runs) — and paste that literal command into every prompt sketch that needs it, because a copy-pasteable string is the only thing that transfers to a context that never saw the earlier steps. The same rule covers any other repeatedly-launched tool a `Done when:` needs (a browser/E2E runner, a dev server): resolve the working invocation the first time it's needed and reuse that exact command in every later prompt sketch — no `.mentor/config.json` key exists for these, so state the resolved command directly rather than pointing at one. When the proof that tool serves is the live multi-service kind, **State done-when** sends the proof itself to a `## Verification` topic — the invocation is still resolved once, but it is handed to that topic's verifier (`references/verifier-contract.md` → "What to hand the verifier") instead of repeated across prompt sketches. It also covers *checkers*, not just invocations: when the repo or environment already ships a validator for the kind of artifact a step produces, name that command in the step's `Done when:` rather than leaving the agent to write its own equivalent — a freelance check is a second, unverified implementation that can drift from the real one unnoticed. (Why the command is pasted rather than described, and how a freelance checker fails: `references/rationale.md` → **Why a resolved command is pasted, not described**.)
10. **State done-when.** Observable, verifiable, no "looks good" — and provable by the
    implementer with **bounded commands**: build, typecheck, unit tests, a targeted
    integration check. Live end-to-end proof across a running multi-service stack
    belongs in a `## Verification` topic, where one fresh verifier runs it exactly
    once. Writing it into a step's `Done when:` as well makes the implementer prove it
    first, in the most expensive context of the session, and the topic then re-proves
    the same ground.

## Example

A worked three-step example of the grammar above — one parallel `Explore` step, then two
sequential ones — is in `references/annotation-example.md`. Read it when authoring a
plan's annotations; execution never needs it.

## Executing the dispatches (after plan approval)

Dispatch implementation/editing agents **only after the plan is approved**
(`approve-plan.sh` released the gate). Then:

1. **Pull each step's brief, not the whole plan** — `bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}/hooks/plan-state.sh" brief <slug> --step N` returns the plan title, its `## Context` goal, the whole `## Out of scope` section, one line per step with tick state, the verbatim body of step N, and the `## Verification` topic titles — everything a dispatch needs, at a fraction of `plan.md`'s size. Do not read the whole plan file from memory or by hand; run one `brief` call per step (or per step in a parallel group) instead.
2. **Dispatch "Run in parallel:" groups** — issue ALL `Agent()` calls for each parallel group in a **single message** so they run concurrently. The solution-quality line and the standing contract block ("Deliver before idling," "Async runtime & lifecycle" below) reach every prompt automatically via the dispatch hook, so there is nothing to paste by hand — but the block's directives, including the no-nested-fan-out ban, are non-negotiable regardless of how the prompt sketch itself reads. After dispatching, apply **No busy-wait**: stop and let the harness re-invoke you when agents complete.
3. **Dispatch "Sequential:" steps one at a time** — wait for the prior step's result before issuing the next call.
4. **Verify each `Done when:` criterion** before moving to the next step — agents describe what they intended; trust but verify. On a concurrency- or timing-sensitive criterion, one clean run is not evidence — re-run it yourself 5+ times before accepting a PASS; an agent's self-reported `PASS=N/FAIL=0` from a single run proves nothing about a race. A zero-hit or empty result from your own check is likewise not evidence the criterion failed until you've confirmed the check itself works — a single-line `grep` can miss a claim that wraps across lines, an unquoted glob aborts outright under zsh's `nomatch`, and ERE alternation is `|`, not `\|`; when a check comes back empty, narrow it to one line or run it against a known-positive before trusting the negative. A step that hands back partial work plus a remainder brief has not failed its criterion — verify what it actually claims, then continue it per the hand-back addendum under "On a failed `Done when:`" above.
5. **Execute the plan's Verification section** — dispatch one fresh verifier per `Topic N —` block, all in a single message, even when the plan opened `Dispatch: skipped`. Full contract in "Verifying the plan (execution-time)" below. A plan's own implementation step titled "Verification pass" or similar is not this step; it's ordinary self-graded work covered by **Verify each `Done when:` criterion** above, never a substitute for this dispatch.
6. **CLOSING CHECKLIST**, whatever Verification returned — a `failed` or handed-off plan gets it too:
   - **Close out finished agents** — enumerate live tasks with `TaskList` and diff
     against this session's own dispatch tree, nested spawns included, before
     `TaskStop`ping only what traces to that tree. A remembered name can belong to
     a **different session's** live agent, and the runtime's id rejection is a
     safety net, not a substitute for enumerate-then-diff (full rule, including
     the ownership check before *nudging* on idle — which has no such net:
     "Async runtime & lifecycle" below).
   - **Sweep the report you're about to write** — every follow-up, gap, or known-broken
     item in it is **named** there, in plain terms, so nothing survives only as an aside
     that dies with the session. Do not capture them on your own: parking work is the
     user's call, and anything a verifier raised already carries their verdict from "The
     non-goal disposition gate" below. And an unresolved verification topic or an
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
     touching the index — and committing an implementation run's work is always a
     **question**, never an assumption: whose work is in the tree is the one thing
     the orchestrator can be wrong about. Skip this bullet only when the tree is
     clean and nothing was flagged as absorbed.

Do NOT paraphrase the plan or summarize what you're about to do. Dispatch immediately.

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
  (`references/dispatch-recovery.md` → **Follow-up vs re-dispatch**); silence is
  never `none found`. A
  `Verdict: HANDBACK` is exempt: it is a complete answer about an incomplete
  check, so re-asking it just spends the round-trip the hand-back saved.
- **Failure loop.** A `FAIL`, or any non-`none found` Gaps line even on a PASS, surfaces
  the round's gaps. Split them on the contract's stamp and **work every `[GOAL]` gap to a
  fixed point before assembling anything for the user** — a remediation dispatch routinely
  turns up more gaps, so a digest built while the set is still growing is stale before it
  is read. **`Verdict: HANDBACK` is not a `FAIL`** — the topic outgrew its brief, so it
  routes to "On a failed `Done when:`" above and costs this round none of its one
  remediation: re-dispatch the topic fresh with the verifier's remainder as its inputs.
  Read it as a `FAIL` and the topic burns its retry on work nobody attempted.
  - **Re-check context first** — the same move as `planning`'s "Re-check context": run
    `bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}/hooks/plan-state.sh" context` fresh rather than trusting
    an earlier reading. A verification round runs mostly on harness-synthetic prompts
    (inbound agent reports), which `context-gate.sh`'s own WARN tier deliberately skips,
    so a round can grow well past WARN with only `context-checkpoint.sh`'s rate-limited
    advisories having said so. Those advisories are **advisory by ruling — no tier
    blocks** — so obey them when they arrive; nothing will stop the run for you
    (`references/rationale.md` → **Why the context checkpoint is advisory-only**). This is a **context
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
  race — and that covers the fix-now dispatches "The non-goal disposition gate"
  below can produce too. One asymmetry there
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
`[GOAL]` gap as `[NON-GOAL]` and quietly buries it. **Unstamped** gaps are a different
thing from non-goal ones and have their own route:
`references/non-goal-gate.md` → **Unstamped gaps have their own route**.

The gate's six steps are in `references/non-goal-gate.md`. Read it when the round has any
open finding the user has not ruled on — stamped `[NON-GOAL]` or not. Routing the unstamped
ones is what decides whether the set is empty, so the empty-set skip is that file's step 1,
never a reason to stay out of the file.

## Async runtime & lifecycle

Dispatched agents run as background teammates: they can signal **idle** before
(or instead of) delivering, die mid-flight on infra errors, and stay resident
after finishing. These rules apply to **any** fan-out, whoever launched it and
whether or not a plan is involved — nothing about them is specific to plan
implementation. The standing prompt block reaches dispatched agents on its own via
`hooks/dispatch-contract.sh`, so there is nothing to load or paste to get it; one
`plan-state.sh policy` call confirms the injection is actually live and reports any
standing no-subagents policy at the same time.

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
  [ -d "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}/hooks" ] || { echo "ERROR: Mentor helper unavailable — set PLUGIN_ROOT (or use the Claude compatibility fallback) or use the documented artifact fallback" >&2; exit 1; }
  bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}/hooks/plan-state.sh" policy
  ```

  It prints its verdict in words, so there is no exit code to interpret.

  - **`POLICY: SET (dispatch=…)`** → the user already answered this, for this repo. Honor
    it and **ask nothing** — `agents` routes per "Where dispatch pays", `verify-only`
    implements in-thread and still dispatches verification. Nothing here is re-litigated
    per plan or per session; that re-litigation is the whole reason the key exists. No
    dispatch preference retires the verification round: **"No escape hatch"** below binds
    under every mode, which is why the two values differ only on where implementation
    runs.
  - **`POLICY: NONE`** → route per "Where dispatch pays".
  - **`POLICY: FOUND`** → a standing instruction is on record and it conflicts with the
    routing test. Ask **once**, then **record the answer** so no later surface in this or
    any future session asks again:

    ```bash
    bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}/hooks/set-mode.sh" <agents|verify-only>
    ```

    One `AskUserQuestion`, header `Dispatch`, these two options in this order:
    **"Main thread, but still verify independently (Recommended)"** → `verify-only` /
    **"Route per the plan's own test"** → `agents`. `verify-only` leads because it honors
    the policy where the policy has a real argument — implementation — while keeping the
    fresh grader. There is deliberately no third option that also retires verification:
    a plan cannot grade itself, so that is not a preference mentor offers. Say in the
    question that the answer is remembered for this repo and changeable with
    `/mentor:mode`.

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
  so next to that result, not leave it implied. A solo diff review is reported **as** a
  solo diff review, because reporting the substitute as though the full step ran is what
  turns a judgment call into a false green. **This is not a license** — it does not cover
  work that forbids running solo at all (`zoom` never hand-renders in the main thread,
  `plan-split` never hand-authors a child, and verification's "No escape hatch" above has
  no fallback beyond the one named allowance): there, a solo attempt is a contract
  violation to stop and flag, never a substitution to disclose.
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
  wake-up in between gets silently absorbed (per `references/dispatch-recovery.md`
  → **An echo from an already-stopped agent**) rather than re-entering the
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
  before the session's first dispatch. (Why it is injected rather than pasted:
  `references/rationale.md` → **The standing prompt contract**. The block's text
  itself is only in `hooks/dispatch-contract.txt`.)
- **A dispatch that goes wrong — idle races, echoes, agent death, follow-ups, stalls.**
  Two guards fire before there is time to read anything, so they stay here. **Check a
  notification's id against this session's own dispatch tree before reacting:**
  `SendMessage` to a foreign id succeeds and lands on a stranger's live agent — with
  several sessions running concurrently an idle can name a task this session never
  dispatched, and there is no id-not-found safety net of the kind that protects
  `TaskStop`. An unrecognized id gets no reply of any kind. And **hand-debugging a
  stalled step's subject matter is the escape hatch reserved above for a *second* failed
  `Done when:`** — reaching for it early leaves the main thread owning a debugging
  session it has no context for. The recovery procedure for each is in
  `references/dispatch-recovery.md`. Read it the moment one of the five happens.
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
  (`select:SendMessage,TaskList,TaskStop` in one `ToolSearch` call loads all
  three async-lifecycle tools together), diffed against this session's own dispatch tree,
  nested spawns included. Stop only what traces to that tree with
  `TaskStop`; note anything else in the one-line report rather than
  stopping it, since it may belong to a sibling session or the user's own
  background work. **The same checkpoints are also the right moment to
  re-check context** — run `bash "${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-}}/hooks/plan-state.sh"
  context` here too, not only on the failure loop's remediation path
  ("Verifying the plan (execution-time)" above, which carries the reason). Its
  remediate-or-hand-off question does not apply here — there is nothing left to
  remediate. This second site exists because an all-PASS
  round never enters that loop at all, so a clean round can walk straight into
  the final report on whatever context reading it last took, if any.
  `CONTEXT: WARN` or higher belongs in the final report itself (a line naming
  `/mentor:handoff`), not silently absorbed.
- **A live `Monitor` watch is not a dispatch — it has no stop tool.** A CI run, a
  deploy, or a long build tracked via `Monitor` should usually keep running
  (killing it is rarely what you want, unlike a stray dispatched agent). At the
  same close-out checkpoints as above — the final report, escalating on a
  stalled step, any "done"/"closed out" claim, and a handoff — either let it
  resolve first, or record its status as still outstanding plus the exact
  command the next reader uses to get its verdict. Leaving it unmentioned is
  what strands it.
