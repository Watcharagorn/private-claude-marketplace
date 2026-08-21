# Verifier prompt and return contract

Read this when dispatching a plan's Verification topics ("Executing the dispatches"
→ **Execute the plan's Verification section** in
`dispatch-agents/SKILL.md` → "Verifying the plan (execution-time)"). Paste
the fenced block under "What the verifier must return" into every verifier's
prompt verbatim. The standing "Deliver before idling" block is NOT pasted —
`hooks/dispatch-contract.sh` appends it to every dispatch automatically. This
block is what turns
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
  dispatches" → **Verify each `Done when:` criterion**: a zero-hit or empty result
  from a check is not evidence
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
Verdict: PASS | FAIL | HANDBACK
<evidence per check — the exact command run and its output, or a file:line citation>

Gaps / Missing:
<one stamped line per gap, or the literal words "none found">
  [GOAL] <finding> — which `Done when:` bullet or this topic's `Pass when:` it leaves unmet — fix: <a few words>
  [NON-GOAL][SMALL] <finding> — why the plan's goal is met without it — fix: <a few words>
  [NON-GOAL][LARGE] <finding> — why the plan's goal is met without it — fix: <a few words>

Notes:
<observations that are NOT defects — context for the reader, or the literal word "none">

Cross-topic:
<a finding that belongs to a DIFFERENT topic's Focus:/Checks: — name the sibling
topic and the finding in one line, or the literal word "none">
```

**`HANDBACK` is not a verdict on the topic — it is a verdict on the brief.** Use it
when the topic has clearly outgrown what you were given (the standing contract's
hand-back clause): report the checks you *did* complete under the evidence line,
stamp whatever gaps you found, and list the remainder concretely. Never stamp `PASS`
or `FAIL` on a topic you only half-checked — a forced `FAIL` spends the round's one
remediation on work nobody attempted, and a forced `PASS` closes the plan on evidence
that was never gathered. A `HANDBACK` costs the round none of its remediation
(`dispatch-agents/SKILL.md` → **Failure loop**); the orchestrator re-dispatches the
topic fresh with your remainder as its inputs.

Every gap line carries stamps, because what happens to a gap turns entirely on
them, and the reader downstream is the orchestrator — the context that just
built the thing and wants the plan to close. Prose leaves that judgment to it;
a stamp takes the judgment away from it and gives it to you, who checked.

- **`[GOAL]`** — without this fix the plan's Goal is unmet, or a `Done when:`
  bullet or this topic's own `Pass when:` stays unmet. Name the bullet in the
  line: the citation is what makes the stamp checkable rather than a feeling.
  These are remediated in the loop without the user being asked.
- **`[NON-GOAL]`** — real, worth recording, but the plan's stated goal is met
  without it. Say why in the same line. These reach the user as a decision.
- **`[LARGE]` / `[SMALL]`** — judged on the **fix**, not on the finding, in the
  conditional-future frame: `[LARGE]` if fixing it would span more than one
  service or layer, touch more than ~10 files, need a live multi-service stack
  to prove, or force design decisions the plan never made.
- **`— fix:`** — a few words on the repair. This gets read back to the user
  verbatim, so "add the missing index on `orders.user_id`" earns its place
  where "fix the query" does not.

**Both tiebreaks point at the user**, deliberately: unsure whether a gap is
`[GOAL]` → stamp `[NON-GOAL]`; unsure whether its fix is `[LARGE]` → stamp
`[LARGE]`. A misfiled `[GOAL]` gets quietly fixed and the user never learns the
finding existed; a misfiled `[NON-GOAL]` reaches them as a question they answer
in one keystroke. Only the second mistake is recoverable.

`Verdict:` follows from the stamps whenever you checked the topic through: **`FAIL`
iff at least one `[GOAL]` gap exists** (`HANDBACK` above is the one case where the
stamps do not decide it, because the checking is incomplete by construction). `[NON-GOAL]` gaps never produce a `FAIL` — they are reported, not
failed on. A topic whose only gap is cosmetic has to be able to reach PASS, or
it sits in a loop that by design will not remediate it and the plan can reach
no terminal state at all.

`Gaps / Missing:` is mandatory even on a `PASS` verdict. An absent or empty
one is a contract violation, not an oversight: that explicit line is the
only thing that forces "what is missing?" to actually get asked, instead of
silence reading as "nothing to report."

`Notes:` is where everything that is **not** a defect goes — context a reader
benefits from, a suggestion, something you checked and found fine. Keeping
those out of `Gaps / Missing:` is what makes the mandatory-on-PASS rule
survivable: every gap line becomes a decision someone has to make, so a note
filed as a gap spends a real question on a non-problem. If you catch yourself
writing "not a defect, just an observation" inside a gap line, it belongs here.

**One carve-out:** `grilling` Step 3's standalone verifier checks a single
trivial change with no plan, no `Done when:`, and no disposition gate behind it
(`grilling/SKILL.md` → "Step 3 — Close"), so nothing downstream reads the
stamps — it returns the block unstamped.

`Cross-topic:` is not a gap against this verdict — a PASS with a real
`Cross-topic:` line is still a PASS; the failure loop reads this topic's gaps,
and a `Cross-topic:` line is not one. Name the finding and stop there; do not
verdict a sibling topic's scope from inside this one — independence is the
whole point of the per-topic split (above). The orchestrator routes it: to
that topic's verifier if still live (`dispatch-agents/SKILL.md` → "Follow-up
vs re-dispatch"), or as a round gap (`Gaps / Missing:`) if that topic already
returned. A finding that belongs to no topic at all is a round gap too — no
finding falls out of the report for want of a home. Whether a gap is a
*confirmed* pre-existing defect (present before this plan's work began) is
worth saying in the finding's own line, since it usually settles the
`[NON-GOAL]` stamp; the disposition is not yours either way. You report and
stamp, the orchestrator and the user decide what becomes of it.

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
