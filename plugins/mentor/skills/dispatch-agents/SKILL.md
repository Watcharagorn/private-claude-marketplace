---
name: dispatch-agents
description: >
  The default implementation path for mentor plans (subagents-driven
  development) — annotate every plan's implementation steps as subagent
  dispatches, execute them after approval, and verify the result with one
  fresh verifier agent per Verification topic; the main thread orchestrates,
  subagents implement and verify. Invoked by plan Steps 4 and 6, or when the
  user says "dispatch agents" / "fan out" / "parallelize". Trivial work may
  skip implementation dispatch with a stated `Dispatch: skipped` reason —
  verification dispatch has no skip on a mentor plan.
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
belonging to that framework's backlog goes there, not into a mentor stub (repo work
outside its scope still defers normally). Three rules hold on this path:

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

**The skip never covers Verification** — `## Verification` still gets fresh verifiers
after the last step ("Verifying the plan (execution-time)" below; a skipped plan with
≤2 topics gets the lite-verify allowance, never a self-check).

**Check the skip against the plan you actually wrote.** The step count is the cheapest
honest test: a plan carrying more than about two steps, or any step whose `Done when:`
needs a service brought up, a browser driven, or a screenshot compared, is not "a small
mechanical change" however mechanical each individual edit looks — re-annotate it. The
reason to be strict here is that this line is load-bearing far beyond dispatch:
everything downstream of it — step ticks, `/simplify`, the closing checklist, the
acceptance pass — is written once for the dispatch path and only *restated* for the
skipped one, so an over-claimed skip is how a plan quietly loses all of it at once.

## Context efficiency — the orchestrator contract

The point of SDD: quality through narrow focus, and a lean main thread.

- **The main thread MUST NOT read the implementation files a step delegates** —
  that context belongs to the dispatched agent. Verify `Done when:` with
  observable checks instead; the step's `git diff` and a failing command's
  output are always in-bounds as diagnostics.
- **Prefer executable pass/fail `Done when:` criteria** (the named test / typecheck /
  lint command) over presence checks; use grep/ls checks only when no runnable check
  exists. **When the check itself mutates the artifact it verifies** (an importer, a
  migration runner, a `--write` formatter, a seed script), running it live means the
  verification consumes the very thing it was meant to confirm — run it against a
  `mktemp -d` copy outside the repo instead, diff/compare, then discard. When the check
  can't run detached (needs live git context, a database, or a running service),
  snapshot state and restore it after, or point the check at a disposable instance.
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
  its own *while the plan is still open* (a later tick still heals the state),
  but a plan closed `implemented` with ticks still missing has nothing left to
  heal it — `plan-track`'s "reconcile the ticks before writing implemented" is
  the last chance, and `plan-state.sh`'s own post-write warning is a backstop,
  not a substitute. A tick on the wrong line silently costs the next session its
  picture of what landed, which is what `tick` exists to prevent.
- **Move the plan's state as you go**, so `/mentor:track` can answer "what is
  built?" in a fresh session without re-reading anything:
  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" set <slug> in_progress    # before the first dispatch
  bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" set <slug> implemented    # every Done when: + Verification PASS
  bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" set <slug> failed --note "<what broke>"
  ```
  `<slug>` is the plan's directory name. Set `failed` wherever verification ends
  unresolved — the escalate-to-user point after the one remediation re-dispatch has also
  failed, and a hand-off. That one is worth remembering, because unlike the others it
  cannot be derived from ticks, and the note is what makes the retry cheap.
- **Prompt sketches must be self-contained.** Each agent starts with zero memory of this
  conversation **and no inherited project context — assume it never read CLAUDE.md or
  your repo's conventions**: give exact file paths, the approved plan path, the
  distilled facts it needs from research or prior steps (paste result lines, not files),
  and its `Done when:` verbatim. Every **implementation** brief additionally carries the
  solution-quality line: `Implement the most practical and clean solution — never trade
  maintainability or reliability for implementation speed.` (read-only roles like
  `Explore` are exempt — the line governs how something is built, not how it's found.)
  That line and the standing contract block ("Deliver before idling" below) are appended
  verbatim at dispatch time — a `Prompt sketch:` is the *middle* of a prompt, never the
  whole of it.
- **Return contract:** agents return a short summary, file paths touched, and
  verification output — never full file bodies. Verification output must include the
  exact command(s) that produced it, copy-pasteable — otherwise re-verifying against an
  API the orchestrator hasn't read means re-deriving the command blind.
- **Relaying a return to the user strips its ids.** An agent's report is written for
  **you**: its finding codes, table rows, step numbers, and bare `Location(s)` cells
  name things the user never read. Carry the finding, not its filing — say what the
  thing is ("the Argo controller reads cross-tenant Secrets") and leave the code in your
  notes; if one must survive because the user holds the artifact it indexes, it rides
  behind the name, never alone. The same holds when the relay becomes a question:
  **every question stands on its own**, answered from the question screen alone, never
  sending the user to a file, a report, or an earlier turn to learn what it means.
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
5. **Assign roles.** Smallest specialist that covers the work.
6. **Assign models.** Default `sonnet`; upgrade only with a reason.
7. **Assign effort.** Default `medium`; upgrade for design/cross-cutting, downgrade for trivial.
8. **Write prompt sketches.** Each agent has zero memory of this conversation — the brief must stand alone. If a `Done when:` is a long test suite, brief the agent to iterate on a filtered subset and run the suite whole only as the final gate. When any step's `Done when:` runs tests, resolve the repo's test invocation **once per session** — `mentor:shipping` Step 4's own order (`.mentor/config.json`'s `test_command` first, else auto-detect, confirmed once it actually runs) — and paste that literal command into every prompt sketch that needs it. A fresh agent told to "run the tests" with no memory of earlier steps will re-derive (or mis-derive) the invocation independently each time; a copy-pasteable string is the only thing that transfers. The same rule covers any other repeatedly-launched tool a `Done when:` needs (a browser/E2E runner, a dev server): resolve the working invocation the first time it's needed and reuse that exact command in every later prompt sketch — no `.mentor/config.json` key exists for these, so state the resolved command directly rather than pointing at one.
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
5. **Execute the plan's Verification section** — dispatch one fresh verifier per `Topic N —` block, all in a single message, even when the plan opened `Dispatch: skipped`. Full contract in "Verifying the plan (execution-time)" below.
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
     item in it goes through `/mentor:defer` first (orchestrator contract above).
   - **Commit this session's implementation work.** `git status --porcelain`: if
     every dirty/untracked path is something this session's dispatches touched,
     ask via `AskUserQuestion` — commit it as this plan's work (recommended) /
     leave it uncommitted, the user commits by hand. Any dirty path this session
     did **not** touch: show the split, same question, scoped to only the paths
     this session owns. The orchestrator is the only legal committer here — the
     standing contract above already bars dispatched agents from touching the
     index — and this is deliberately a **question**, never `mentor:shipping`
     Step 3's silent auto-commit: that allowance is scoped to files `simplify`
     itself just created, not to a whole implementation run. Skip this bullet
     only when the tree is already clean.
   - **Point at `/mentor:ship`** — one line: once the ticks above are verified and
     the tree is committed (above), the next move is `/mentor:ship` (it hands off
     to `/mentor:merge`'s bounded watch) — not a hand-rolled `git push`, `gh pr
     create`, or a CI-poll loop. Do not auto-run it. A tree still dirty when
     `mentor:shipping` Step 2 runs means something outside this session's own
     work — that abort is real, not a formality it will paraphrase past.

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
  into every verifier prompt verbatim, alongside "Deliver before idling" below. A return
  with no `Gaps / Missing:` line is not a verdict yet — ask that same verifier for it
  ("Follow-up vs re-dispatch" below); silence is never `none found`.
- **Failure loop.** A `FAIL`, or any non-`none found` Gaps line even on a PASS, surfaces
  the round's gaps and asks ONE question for the round, however many topics failed —
  **remediate now, or hand off to a fresh session?** (offered early, since verification
  runs when the session is often largest). **Remediate**: one dispatch by the file's
  implementation role; a skipped plan assigned none, so pick one the normal way
  ("Choosing `role`" above) — the skip covered the original edits, not their repair.
  Then a **fresh** verifier for that topic; a second failure escalates to the user and
  sets `failed` (the one-retry contract above). **Hand off**: set `failed` with the
  unresolved topics as its note, then `mentor:handoff-note` with the verifier reports,
  then stop — `handoff-note` writes no plan state, so an all-ticked plan would read
  `implemented` to the next session. A deferred/accepted gap exits the loop; concurrent
  remediations run **sequentially, never in parallel** — parallel fixes on shared files
  race.
- **No escape hatch.** Runs even when the plan opened `Dispatch: skipped`. One allowance
  (**lite verify**): a skipped plan with ≤2 topics may dispatch **one combined fresh
  verifier** carrying both — independence holds, only the fan-out relaxes. `implemented`
  needs every topic PASS with every gap fixed, deferred, or accepted; zero topics clears
  that vacuously, so a topicless plan gets there only on the acceptance above.

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

- **Standing no-subagents policy.** Before this session's first dispatch, check for a
  *standing* instruction against subagent use recorded somewhere durable — CLAUDE.md, a
  project rule file, an earlier session's handoff note — as distinct from the user saying
  so live in this session (that case needs no check: honor it directly, per `plan-review`'s
  "When NOT to use"). `.mentor/` is gitignored, so search it with `grep --no-ignore` — a
  plain `grep -r` misses handoff notes (`planning` Step 2). Found one → stop before
  dispatching and ask ONE `AskUserQuestion`, 3 options, **"Keep the work in the main thread
  instead" first and Recommended** (a standing policy outranks the default path): keep it
  in the main thread / dispatch as designed anyway / skip the affected step. That tension is
  the user's to resolve, not yours to resolve silently.
- **No busy-wait.** Waiting is not work: never chain `sleep`s, fire no-op Bash
  calls, or reach for `ScheduleWakeup` (that tool is for `/loop` mode, not a
  dispatch wait — it can fire successfully and still be wrong here: a timer has
  no idea the dispatch already finished, so it re-enters this session on a
  superseded brief and forces a stale-wakeup recovery instead of a clean
  re-invoke) to pass the time. This governs **every** waiting surface in a mentor
  session, not only dispatched agents — a long build, a background test suite, a
  deploy. When something else will wake you (a dispatch completing, a backgrounded
  command exiting), **end the turn** and let the harness re-invoke you. When nothing
  will, make **one** bounded blocking call — a condition loop such as
  `until ! pgrep -f <proc>; do sleep 5; done`, or a monitor/wait tool — sized under
  the Bash timeout ceiling (600s). A chain of short sleeps burns a turn apiece, and
  the harness blocks bare foreground `sleep` outright, so the chain tends to fail in
  the middle and leave the wait half-done. One case sits outside this binary: a wait
  on a live external system the user is watching in the foreground (a cloud deploy
  settling, a third-party pipeline) with no bounded local completion signal — ask
  once via `AskUserQuestion` (poll now / hand the check to the next session) before
  committing to it, rather than starting the poll unasked. The block below carries an
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
  Deliver your full result via SendMessage BEFORE going idle — if SendMessage
  is not already in your tool list, fetch it first with ToolSearch,
  select:SendMessage. Ending your turn on a plain final-text reply with no
  SendMessage call is a contract violation: it is indistinguishable from not
  reporting at all, because only SendMessage reaches the orchestrator. Include
  the exact command(s) that produced your verification output, copy-pasteable.
  Leave the git index as you found it: edit the working tree and let the orchestrator
  commit — never `git add` / `git rm` / `git mv` / `git stash` / `git commit` (use plain
  `rm`/`mv` to delete or rename a file). If you staged something while investigating,
  `git restore --staged <path>` before you return — staged state you never commit has no
  owner once you go idle, and rides silently into someone else's next commit.
  If you are producing a verdict or report (reviewer, verifier), also write a
  durable copy to `<repo>/.mentor/plans/<slug>/` (e.g. `step-N-review.md`,
  `<lens>-review.md`, or `topic-N-verify.md` for a Verification-topic
  verifier) before returning — a dropped notification must never be the
  only copy of completed work.
  ```
- **Idle-before-report race.** An idle notification can arrive before the
  agent's actual report — and, when the harness is running several sessions
  concurrently, a notification can name a task this session never dispatched
  at all (a sibling session's idle/report leaking into this one's message
  stream). Check the id against this session's own dispatch tree before
  reacting: the id-not-found safety net that protects `TaskStop` below does
  **not** protect a nudge — `SendMessage` to a foreign id succeeds and lands
  on a stranger's live agent. An unrecognized id gets no reply of any kind,
  not even the nudge. On idle **with a recognized id** and no report in
  hand: check the message backlog, then send ONE nudge: "Status check on
  Step N: send your completed result now — full text, per the return
  contract. If you are still working, reply with the one thing that's
  left." Do not restate the step's criteria —
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
  contract above). **Verify the correction landed.** Sending the message is not
  the same as it taking effect, and unlike a step's own delivery this has no
  `Done when:` to re-check it against — apply the same trust-but-verify rule by
  hand: re-read or grep the target artifact for the exact text you asked for
  once the agent reports, and treat a reply that only *describes* the fix as
  unverified.
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
- **A live `Monitor` watch is not a dispatch — it has no stop tool.** A CI run, a
  deploy, or a long build tracked via `Monitor` should usually keep running
  (killing it is rarely what you want, unlike a stray dispatched agent). At the
  same close-out checkpoints as above — the final report, escalating on a
  stalled step, any "done"/"closed out" claim, and a handoff — either let it
  resolve first, or record its status as still outstanding plus the exact
  command the next reader uses to get its verdict. Leaving it unmentioned is
  what strands it.
