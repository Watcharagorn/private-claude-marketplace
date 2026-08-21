# Dispatch recovery — an agent idles, echoes, dies, or goes dark

Read this when one of five things has already happened to a live dispatch: an idle
notification arrived without a report, an echo came back from an agent you already
stopped, an agent died on an infra error, something you learned after dispatching
invalidates a brief still in flight, or a step went dark. A run where none of them happen
never needs this file, which is why it is not in `SKILL.md`.

Two guards fire before there is time to open anything, so they stay inline in `SKILL.md`
→ "Async runtime & lifecycle": check a notification's id against this session's own
dispatch tree before reacting to it, and do not hand-debug a stalled step's subject
matter early. Everything below assumes both have already been applied.

## Idle before the report

On idle **with a recognized id** and no report in hand: check the message backlog, then
send ONE nudge — *"Status check on Step N: send your completed result now — full text,
per the return contract. If you are still working, reply with the one thing that's
left."* Do not restate the step's criteria; the agent's context is warm and a re-brief
invites it to redo finished work.

Only if the nudge fails, fall back to independent re-verification. Never re-run expensive
verification (full builds, E2E suites) while the agent's own report may still be in
flight, and an idle arriving from an already-`TaskStop`ped agent needs no reply at all.

What to write in the plan file when a step closes with no author report ever received:
`references/rationale.md` → **Idle-before-report race**.

## An echo from an already-stopped agent

It gets no reply and no narration. Not a nudge, not "Agent X already stopped, ignoring" —
nothing. On a dispatch-heavy plan the whole batch is worth at most one dismissed-count
line at close-out, and only if it earns one. An echo arriving *after* the plan was
announced `implemented` is the same non-event: it reopens nothing, and narrating it reads
to the user as new activity — which is how a finished plan collects a second "mark it
done" round-trip.

## Agent died (infra/API error)

Don't reinvent recovery glue: wait with escalating patience (minutes-scale, roughly
doubling — this sanctioned wait for a *dead* agent is not the busy-polling of a healthy
one that "Async runtime & lifecycle" forbids), then send a resume message: "You died on
an infra error mid-step. Resume Step N where you left off. Already applied: <paste
state>. Your `Done when:` <verbatim>." Two failed resumes → fresh re-dispatch of the role.

**A failure string naming a reset time** ("hit your session limit · resets 2:50pm") is a
quota wall, not an infra blip: don't wait it out, don't resume-message. Snapshot what each
dead agent already landed, report the reset time, and end the turn.

## Follow-up vs re-dispatch

A small fix or clarification on work an agent already owns — idle **or still running** →
send ONE message to that same agent (its context is warm; use your runtime's
agent-messaging tool — in Claude Code that is `SendMessage`, which, like
`TaskList`/`TaskStop`, may need fetching via `ToolSearch` first;
`select:SendMessage,TaskList,TaskStop` in one call loads all three async-lifecycle tools
together, so whichever of them you reach for first primes the rest). State that the
correction must be applied before the agent returns.

This matters most when something you learn *after* dispatching invalidates part of a brief
already in flight — a reviewer's finding landing while a writer works from the superseded
version. Correcting it in place beats both alternatives: letting a known-wrong artifact
land, or re-dispatching a whole combo that was 90% right. A failed `Done when:` needing a
clean rebrief → re-dispatch the role once, per the orchestrator contract.

**Verify the correction landed.** Sending the message is not the same as it taking effect,
and unlike a step's own delivery this has no `Done when:` to re-check it against — apply
the same trust-but-verify rule by hand: re-read or grep the target artifact for the exact
text you asked for once the agent reports, and treat a reply that only *describes* the fix
as unverified.

## A step that goes dark

A step with no output, no idle signal, and no death has no notification coming, so the
wake-up is usually the user asking why it is taking so long. Stay orchestrator-shaped
(what that costs when ignored: `references/rationale.md` → **When a step goes dark**):

1. **Snapshot observable state only** — `git log --oneline -5`, `git status --short`,
   `git diff --stat`, a listing of the step's artifact dir. Kill processes the step leaked
   (a browser runner, a stray container) so the re-dispatch starts clean.
2. **Delegate the diagnosis** — dispatch ONE read-only `Explore` agent pointed at the
   artifact paths and the failing command, and let it return a cause.
3. **Re-dispatch the role with that diagnosis attached**, counted against the
   one-remediation budget. Handing a warm diagnosis to a fresh agent is what actually
   closes these steps.

Keep secrets out of the snapshot: commands that print a process or container environment
(`docker inspect` over `.Config.Env`, `printenv`, `env`) dump live API keys straight into
the transcript, and the transcript outlives the turn — `/mentor:handoff` reads it back,
and so does anyone reviewing the session. Name the one variable you need, or check a
value's *presence* rather than printing it.
