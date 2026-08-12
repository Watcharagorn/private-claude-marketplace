# Verifier prompt and return contract

Read this when dispatching a plan's Verification topics (execution step 5 in
`dispatch-agents/SKILL.md` → "Verifying the plan (execution-time)"). Paste
the fenced block under "What the verifier must return" into every verifier's
prompt verbatim, alongside the standing "Deliver before idling" block
(`dispatch-agents/SKILL.md` → "Async runtime & lifecycle"). It is what turns
a topic's authored `Focus:` / `Checks:` / `Pass when:` into a self-contained
brief and a checkable return — a verifier briefed only with "check topic 3"
has to re-derive the criteria from memory, which is exactly the
confirm-instead-of-check failure this contract exists to prevent.

## What to hand the verifier

- The topic's `Focus:`, `Checks:`, and `Pass when:` lines, copied verbatim
  from the plan's `## Verification` section — never paraphrased.
- The exact file paths the topic concerns.
- The approved plan's path (`.mentor/plans/<slug>/plan.md`), so the verifier
  can read surrounding context a check needs.
- If the check launches a browser/E2E runner or another tool likely to need
  re-deriving (module path, executable location, launch flags), the exact
  working invocation already resolved earlier this session — never send the
  verifier off to rediscover it from scratch.
- If the topic is concurrency- or timing-sensitive (a race, a flaky-under-load
  path), say so in the brief and ask for 5+ independent runs before a PASS —
  one clean run is not evidence for a race condition.
- The safe-check-idiom rule from `dispatch-agents/SKILL.md` → "Executing the
  dispatches" item 4: a zero-hit or empty result from a check is not evidence
  until you've confirmed the check itself works. A verifier's own evidence
  commands are exposed to the same false negatives as the orchestrator's —
  a single-line `grep` missing a claim that wraps across lines, an unquoted
  glob aborting under zsh's `nomatch`, `\|` where ERE wants `|`.

When the plan predates the `Topic N —` grammar and its `## Verification` is
still prose, build those three lines yourself before dispatching, one topic per
bullet or sentence-group: title it from the bullet's subject, hand the bullet's
own text as `Checks:`, and infer `Pass when:` from the outcome it states. The
verifier is briefed from the derived lines and never learns the plan was
written under the older shape — so a legacy plan gets the same independent
check as any other, which is the point of deriving rather than self-checking.

## What the verifier must return

```
Verdict: PASS | FAIL
<evidence per check — the exact command run and its output, or a file:line citation>

Gaps / Missing:
<concrete items found, or the literal words "none found">

Cross-topic:
<a finding that belongs to a DIFFERENT topic's Focus:/Checks: — name the sibling
topic and the finding in one line, or the literal word "none">
```

`Gaps / Missing:` is mandatory even on a `PASS` verdict. An absent or empty
one is a contract violation, not an oversight: that explicit line is the
only thing that forces "what is missing?" to actually get asked, instead of
silence reading as "nothing to report."

`Cross-topic:` is not a gap against this verdict — a PASS with a real
`Cross-topic:` line is still a PASS; the failure loop's "any non-`none found`
Gaps line" rule does not apply to it. Name the finding and stop there; do not
verdict a sibling topic's scope from inside this one — independence is the
whole point of the per-topic split (above). The orchestrator routes it: to
that topic's verifier if still live (`dispatch-agents/SKILL.md` → "Follow-up
vs re-dispatch"), as a round gap if that topic already returned, or through
`/mentor:defer` if it belongs to no topic at all.

Before going idle, write a durable copy to
`.mentor/plans/<slug>/topic-N-verify.md` — the flat, no-subdirectory naming
already used for `step-N-review.md` and `<lens>-review.md`.

## A verifier carrying more than one topic still reports per topic

On a `Dispatch: skipped` plan with ≤2 topics, the lite-verify allowance
(`dispatch-agents/SKILL.md` → "Verifying the plan (execution-time)") lets them
ride a single fresh verifier. It relaxes the fan-out, never the reporting: brief
that verifier to return the whole block above **once per topic**, each
headed by its own `Topic N —` title, with its own `Verdict:` line, its own
evidence, and its own `Gaps / Missing:`. One merged verdict is unusable
downstream — the failure loop remediates and re-verifies a single topic at a
time, so it has to know which one failed, and a gap in one topic hiding
behind a pass in the other is the exact failure the per-topic split exists
to prevent.

Durable copies follow the topics rather than the agent: one
`topic-N-verify.md` per topic carried, each holding that topic's own block, so
a later reader finds a report under the number they are looking for.
