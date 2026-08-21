# dispatch-agents — rationale

Why the rules in `SKILL.md` are shaped the way they are: the failure each one prevents,
the mechanism behind it, and the commands that are only needed in one specific situation.

**Read this only when you are editing `dispatch-agents/SKILL.md`, when a rule there looks
wrong and you are about to work around it, or when `SKILL.md` points you at a section by
name.** It is deliberately outside the skill's own context — these passages were once
inline, re-read on every dispatch, to explain things that matter only when the rule
itself is in question.

## Contents

- **Where dispatch pays** — the measurements and published findings behind the routing
  test: why verification/review/research dispatch unconditionally, why implementation has
  to earn it, and why a lone sequential dispatch is usually the worst of both worlds.
- **Proving a negative** — verifying that a forbidden tool call never happened, and that
  a fan-out produced every artifact it was supposed to. Both are cases where the obvious
  check inverts the evidence.
- **No busy-wait** — why `ScheduleWakeup` fails for a dispatched agent specifically, and
  why a sleep chain breaks in the middle.
- **The standing prompt contract** — what the injected block carries and why it ships
  through a hook instead of being pasted.
- **Idle-before-report race** — why a foreign task id is dangerous, why a re-brief
  backfires, and what to write when no author report ever arrives.
- **Why the loop refuses more than it runs** — the measurements behind unattended
  continuation (v2.37.0): why the verify route is three-way instead of a boolean, why
  ARMED_ELSEWHERE is not a stop, and which trade-offs were user-ruled rather than derived.
- **Sizing a step to one agent's context** — the measured cost of an oversized step, and
  why the rubric lists smells instead of a tool-call number.
- **Why a resolved command is pasted, not described** — what goes wrong when a fresh
  agent re-derives a test invocation, and why a freelance checker drifts unnoticed.
- **Who commits an implementation run's work** — the concurrent automation run that
  absorbed a step's paths mid-session, and why the closing checklist checks the inverse
  of a dirty tree.
- **When a step goes dark** — why a stalled step tempts the orchestrator into
  hand-debugging, and what that costs the rest of the session.
- **Why a gate-routed stub is flat on purpose** — why `priority` is left unset and why
  the `gate: left uncontained` note exists.

## Where dispatch pays

This section exists because the rule it backs reversed a long-standing default. Mentor
used to declare subagent implementation "the DEFAULT for every mentor plan," with a
narrow escape hatch for trivial or interactive work. That framing survived a long time
without anyone checking it against either the published evidence or mentor's own
telemetry. Both say the same thing, and neither says "dispatch everything."

**Dispatch buys two separable goods, and they have different price tags.**

*Context isolation* is the reliable one, and it is large. Measured across 2,545 mentor
subagent transcripts, the median dispatched agent ingested roughly **247,000 unique
input tokens** and returned about **630 tokens** to the orchestrator — a compression
factor near 390×. The corpus an agent reads to answer a question is 2–3 orders of
magnitude bigger than the answer, and that entire difference is context the main thread
never has to hold. Anthropic's own research system reports the same shape: a subagent
"might explore extensively, using tens of thousands of tokens or more, but returns only
a condensed, distilled summary of its work (often 1,000-2,000 tokens)."

*Parallelism* is the conditional one. The often-quoted headline — a multi-agent system
outperforming single-agent Claude Opus 4 by **90.2%**, and cutting research time "by up
to 90% for complex queries" — is measured on a **breadth-first research eval** and
attributed specifically to "spawning 3–5 subagents in parallel." It is not a general
claim about delegation. In mentor's own telemetry, grouping `Task` calls by the API
response that issued them, **1,352 of 1,742 dispatch responses (63%) carried exactly one
agent**, and only 212 reached the 3-or-more shape the latency finding depends on. Most
of mentor's dispatching had therefore been collecting the isolation benefit while paying
for a benefit it never received.

**Why that matters rather than merely being wasteful.** Under *equal* thinking-token
budgets, single-agent extended reasoning has been shown to beat multi-agent systems on
multi-hop reasoning, with the overhead going to inter-agent communication, redundant
reasoning, and integrating separately-produced outputs. So a lone dispatch is not a
neutral choice with an idle upside — the tokens it spends re-establishing context are
tokens not spent reasoning. It wins only when the isolation itself is what you needed.

**Why implementation specifically is the weak case.** Anthropic's writeup is explicit:
"some domains that require all agents to share the same context or involve many
dependencies between agents are not a good fit for multi-agent systems today. For
instance, most coding tasks involve fewer truly parallelizable tasks than research, and
LLM agents are not yet great at coordinating and delegating to other agents in real
time." The failure mode is observable at larger scale too: in multi-agent experiments on
shared codebases, "a very low fraction of these PRs were merged, which suggests a lack
of coordination," and one model generation "solved" the conflict problem by "hardly
working together at all." Implementation is where a plan's steps most often share files,
share a sequence, and depend on decisions still live in the conversation — all three of
which are the named anti-patterns.

**Why verification, review, and research keep an unconditional mandate.** For those, the
isolation *is* the deliverable rather than a saving. A verifier's value is that it never
saw the implementation reasoning — the guidance is to have "a fresh model try to refute
the result, so the agent doing the work isn't the one grading it." Research is the
read-heavy shape the compression number above is drawn from. And review lenses are
mutually independent by construction, which is the one condition under which parallel
agents reliably beat one: coordinating swarms working on complementary slices found
**266 vulnerabilities against 21** for independent agents on the same problem.

**The context-cost override, and why it is not a loophole.** A single step whose own
context cost would flood the orchestrator — a live multi-service `Done when:`, a browser
run, several whole large files in `Inputs:` — dispatches alone and sequentially. This is
isolation bought on purpose, and it is the one honest reason to run one agent by itself.
It is separated out and required to state itself in the annotation precisely because it
is the shape a reflexive dispatch would also produce; a reviewer needs to be able to
tell a deliberate purchase from a habit.

**One premise worth not inheriting.** Repositories sometimes record a standing policy
against background agents on the grounds that dispatched agents go idle without
delivering. That specific claim did not survive measurement here: across 2,495
orchestrator-side dispatches, **zero** never returned a result, and all 16 errors were
environmental or user-initiated (interrupts, rejections, a machine sleeping mid-response,
one malformed `isolation` argument). Thin returns were overwhelmingly correct empty
answers. A standing policy is still the user's to keep — but the cost argument above is
the one that holds up, not the reliability one, and a question that quotes a false
premise back at the user is worse than no question. See **Standing no-subagents policy**
in `SKILL.md` for how such a policy is honored once rather than re-litigated per plan.

## Proving a negative

Two `Done when:` shapes cannot be verified by looking for something — they can only be
verified against a *complete* list. Grepping for absence is the wrong instrument in both,
for the reason each bullet gives.

- **A tool call the step must NOT make** — a mutating MCP call during a
  dry-run sweep, a deploy, a write against a live API — is disproved by
  census, not by grep. Each dispatched agent writes its own transcript under
  this session's directory, so list what the whole fan-out actually called and
  read the absence off a complete list:
  ```bash
  d="$(find "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects" -maxdepth 2 -type d \
       -name "$CLAUDE_CODE_SESSION_ID" | head -1)"
  jq -r 'select(.type=="assistant") | .message.content[]?
         | select(.type=="tool_use") | .name' "$d"/subagents/*.jsonl | sort | uniq -c
  ```
  Run it once the last agent has delivered; nested spawns land in the same
  directory, and the sibling `.meta.json` names which agent a file belongs to
  when a hit needs attributing. Grepping those transcripts for the tool's name
  instead inverts the evidence — the brief that forbade the call contains the
  name too, and a zero-hit grep is exactly the not-evidence "Verifying the
  plan (execution-time)" below warns about (a check must be confirmed working
  before its silence is trusted). An agent's own "I never called it" is a
  self-report, not proof; if the census cannot be produced, report the claim
  as unproven rather than passing the self-report off as verification.
- **A fan-out of countable per-agent artifacts** (a batch fetch, a multi-repo survey) is
  verified as a set, once, after the last agent delivers — never as one ad hoc
  want/got comparison per report as it arrives, which just repeats the same check N
  times. Derive `want` from the dispatch input (the batch you handed out), never from
  the agent's own report — a self-reported count checked against itself proves
  nothing, the same trust-but-verify gap item 4 below exists to close. One pass,
  one row per unit:
  ```bash
  for unit in "${units[@]}"; do
    want=$(wc -l < "batch-$unit.txt"); got=$(wc -l < "records-$unit.jsonl" 2>/dev/null || echo 0)
    printf '%s\twant=%s\tgot=%s\t%s\n' "$unit" "$want" "$got" "$([ "$want" = "$got" ] && echo PASS || echo FAIL)"
  done
  ```
  A zero `got` is the same not-evidence case as the census above — confirm the check
  itself works (right path, no unquoted glob eaten by `nomatch`) before trusting it.

**The shared rule underneath both.** A zero result is not evidence until the check that
produced it is confirmed working — right path, no unquoted glob eaten by `nomatch`, no
single-line `grep` against a claim that wraps. This is the same not-evidence standard
`SKILL.md`'s "Verifying the plan (execution-time)" applies to a verifier's silence.

## No busy-wait — why a sleep chain and ScheduleWakeup are both wrong

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

## The standing prompt contract — what it carries and why it is injected, not pasted

- **Deliver before idling — the standing prompt contract.** Every dispatched
  agent needs a fixed set of runtime directives it has no other way to learn:
  the no-nested-fan-out ban, the no-poll rule, progress-at-phase-boundary
  reporting, the hand-back-on-overrun clause, applying a mid-run correction before
  returning, mandatory `SendMessage` delivery before going idle with the exact
  verification commands copy-pasteable, git-index hygiene, and the durable-copy rule
  for verdicts.
  Its single source is `hooks/dispatch-contract.txt`; `hooks/dispatch-contract.sh`
  (`PreToolUse`, matching `Task`/`Agent`) appends it to every dispatch prompt
  automatically — so **do not paste it by hand**. Paraphrasing it in a prompt
  sketch is redundant at best: the hook still appends the real block after it,
  and a hand-typed paraphrase risks silently dropping a directive the agent has
  no other way to learn. The hook is idempotent — it checks for the block's own
  first line before injecting — so a surface that still pastes it manually
  costs nothing extra; the block lands exactly once either way.

## Idle-before-report race — why a foreign id is dangerous and a re-brief backfires

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
  Only if the nudge fails, fall back to independent re-verification — and if
  that closes the step with no author report ever received, say so plainly in
  the plan file: that step's `## Verification` topic verifier has no author
  rationale to weigh against, so its own read of the artifact is the step's
  only judgment, not a second opinion, and deserves the scrutiny that implies.
  Never re-run expensive verification (full builds, E2E suites) while the
  agent's own report may still be in flight. The race also resolves in the other direction:
  an idle notification arriving from an agent **already** `TaskStop`ped needs no
  reply at all — the stop already closed it out.

## Why the loop refuses more than it runs

The unattended loop (v2.37.0) was almost built as a confirmation-remover. Three
adversarial reviews measured the premise and found the loop already ran unattended:
"Executing the dispatches" has had zero per-step questions since it was written, so the
total harvestable friction on the resume path was roughly ONE conditional answer — the
closing commit question. What the reviews found instead was the gap worth closing:
context-gate.sh is UserPromptSubmit-only, so a run that collapses N human turns into one
receives zero context readings in between. One real session grew ~247,465 tokens between
two readings with nothing said. That is why `context-checkpoint.sh` (PostToolBatch)
exists, and why the loop's per-step `instant` call re-reads gate AND context every
iteration rather than trusting the pre-flight.

**Why the verify route is three-way, not a boolean.** Measured across 72 parseable
`Done when:` blocks in this repo: 14 (19%) are settled by a bounded command alone, 19
carry a command plus a prose conjunct that still decides it, 33 are judgment only. A
"has a runnable check" boolean would auto-tick the 19 on evidence that proves a fraction
of them — `fix-plans-under-root` step 7 has exactly one code span and a prose conjunct
that actually decides it. So the script reports five mechanically-decidable ambiguity
facts and refuses when any fires; the model picks the route. Tiebreak, the loop's own:
unsure a condition holds → it does not hold. (`references/verifier-contract.md`'s stamp
tiebreaks resolve the other way — unsure `[GOAL]` → `[NON-GOAL]` — because a misfiled
gap reaches the user for a verdict, while a false tick here reaches no one.)

**Why ARMED_ELSEWHERE proceeds and STALE stops.** `mentor_plan_tick_step` ends in `mv`,
which bumps plan.md's mtime; `mentor_newly_planned` is `find -newer <marker>` and IS
approve-plan.sh's promotion set; approve-plan.sh resolves this worktree's own marker
with no staleness test. So any own/legacy marker file on disk — live or stale — makes
every plan the loop ticks a promotion candidate, manufacturing the exact "swept in by
approve-plan.sh… not necessarily reviewed" case plan-track's `approved` row carries a
mandatory confirm for. A STALE marker is the worse of the two: being older, its
`find -newer` set is larger. A sibling worktree's marker is different in kind: no own
or legacy marker exists here, approve-plan.sh run here resolves nothing, and the
sibling's own run goes strict, excluding foreign-owned candidates. It also does not
block writes here at all.

**Which trades were user-ruled (2026-08-20), not derived** — recorded so a later
reader knows which side of each to argue with:

- *Context checkpoint is advisory-only, all tiers.* On PostToolBatch, exit 2 stops the
  agentic loop dead — mid-step, half-edited tree, no handoff note, no `failed --note`.
  The ruling chose "never blind" over "forced stop": exhaustion stays possible if a run
  ignores the directive.
- *Under `dispatch: solo`, the prose-criterion verifier dispatches anyway.* The
  alternatives were refusing to run unattended (making on-by-default inert in the very
  repo that uses mentor most) or self-grading (uncalibrated self-assessment written as
  positional ticks into an unversioned file — the artifact the v2.36.0 parser fix just
  proved can be silently corrupted). Solo's no-agents intent is overridden for
  verification only, disclosed per dispatch in the run record.
- *Auto-commit happens once, at end of run, on a per-plan branch.* Per-step commits
  move HEAD mid-run and real plans carry criteria that read the pre-change HEAD ("the
  suite runs and FAILS against current HEAD"); committing nothing leaves hours of work
  exposed to directory-wide staging by concurrent automation (**Who commits an
  implementation run's work** below). The branch (`mentor/<group>/<slug>`,
  cut from the active branch) keeps the commit off the user's branch entirely; a
  worktree is taken only when a second run is already active in the same tree, because
  an unattended `git checkout` under a user's feet was judged worse than sharing the
  tree with one run. Push/PR/merge stay hard stops — the branch is local until a human
  says otherwise.
- *A dirty tree does not block branch entry.* Ruled; the mitigation is disclosure (the
  run record's `NOTE:` lines) plus narrow staging proven against them at commit time.
- *The end-of-run Verification round dispatches under `dispatch: solo` too* (ruled
  2026-08-20, hygiene pass): the per-step override's unstated boundary, resolved toward
  dispatch — the round exists precisely to independently grade the whole run.
- *An instant auto-selected resume narrates in full but does not end the turn on it*
  (ruled 2026-08-20, hygiene pass): resuming Step 5's own-turn stop is attended-only;
  the announcement is the visibility the stop existed to buy.


## Sizing a step to one agent's context

A step scoped as a feature slice — proto + server + worker + UI, proved end-to-end — has
been measured at **350–420 tool calls and 500–750k tokens** in one such context. Raw file
reads were **~40% of that blowup**, which is why the `Inputs:` smell in the rubric is
listed as the costliest one: a step can read narrow and still be oversized purely from
what it has to ingest before it can start.

## Why a resolved command is pasted, not described

A fresh agent told to "run the tests" has no memory of earlier steps, so it re-derives the
invocation independently — and re-derivation is not idempotent. It may pick a different
runner, a different config, or a subset that passes for reasons the real suite would not.
Each dispatch that re-derives is an independent chance to derive it wrong, and nothing in
the return contract would surface the difference: the agent reports that tests passed, and
they did — just not the ones the plan meant.

A copy-pasteable string is the only thing that survives a context boundary intact.

The same reasoning extends to *checkers*. When the repo already ships a validator for the
kind of artifact a step produces, an agent left to write its own equivalent produces a
second, unverified implementation of a check that already exists. The freelance version
can fail in ways the real one does not — a missing dependency, a stale assumption about
the format — and because both report "valid", nothing reveals that the two have drifted
apart until something downstream breaks on an artifact the real checker would have
rejected.

## Who commits an implementation run's work

The closing checklist asks the orchestrator to check the *inverse* of a dirty tree —
paths a step touched that are now absent from `git status --porcelain` — because a clean
tree is not proof the work is committed. It can equally mean something else committed it.

This is not hypothetical. A `loom` automation run, executing in the same working tree
mid-session, stages whole directories (`git add "plugins/<plugin>/"` —
`plugins/loom/skills/learn/SKILL.md:274,283`) and commits everything under them: commit
`d54fde9` absorbed in-flight edits to `plugins/mentor/skills/planning/SKILL.md` that
belonged to a concurrent session (root `CLAUDE.md` → "Git staging safety around loom
automation"). A dispatched step's just-written files sit in exactly that position. The
plan's ticks would still be correct — the work was done and the `Done when:` had passed —
but the session's own closing commit shows an empty diff for a step that genuinely
changed files, and the attribution is wrong with nothing to flag it.

Hence the rule's shape: `git log -1` per absent path distinguishes a no-op step (no
commit at all) from an absorbed one (a commit this session did not make), and whichever
way the question resolves, the split is recorded in the closing commit message. The ticks
stand; only the attribution needs stating.

## When a step goes dark

A step that produces no output, no idle signal, and no death notification has nothing
that will wake the orchestrator. The wake-up is usually the user asking why it is taking
so long — which arrives with social pressure to produce an answer immediately.

That pressure is what makes hand-debugging tempting, and hand-debugging is the escape
hatch reserved for a *second* failed `Done when:`. Reaching for it early has a specific
cost: the main thread inherits a debugging session it has no context for. It guesses
column names it never read, follows dead ends the step's own agent had already ruled out,
and spends the orchestrator's context — the scarcest thing in the session — on one step's
interior. The orchestrator ends up worse equipped to run the remaining steps than before
it started helping.

Handing a warm diagnosis to a fresh agent is what actually closes these steps.

## Why a gate-routed stub is flat on purpose

Two settings on a gate-routed capture look like omissions and are not.

**`priority` left unset.** The only "conversation" a gate-routed capture can read is the
verifier's digest, which is thick with severity words by construction — a verifier writes
about what is wrong. A capture that reads that register naturally lands on `critical`, and
a `critical` tier floats a stub to the top of `/mentor:track`'s build queue. A finding the
user has *explicitly* judged non-goal must not arrive there ahead of work they asked for.

**`parent` = none, plus the `gate: left uncontained` note.** A `category: fix` stub
carrying `deferred_from` but no `parent` matches `/mentor:track`'s "lineage without
containment" alarm exactly. Without the note, both `/mentor:track` and `/mentor:resume`
would read it as an orphaned fix and spend every future session offering to adopt it —
asking the user to reverse a decision they already made at this gate. The note is what
tells the rest of the harness the flatness is a verdict, not an accident.

The exception is a defect in an already-implemented plan's shipped work: that genuinely
has a parent, is contained, and needs no note.
