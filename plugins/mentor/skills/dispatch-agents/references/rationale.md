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
  reporting, the hand-back-on-overrun clause, mandatory `SendMessage` delivery
  before going idle, git-index hygiene, and the durable-copy rule for verdicts.
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
