# plan-review — rationale

Why the two gates in `SKILL.md` are shaped the way they are — which findings earn their
own question, which resolve in a batch, and why the two gates recommend bulk answers
differently.

**Read this only when you are editing `plan-review/SKILL.md`, or when one of its gate
rules looks wrong and you are about to change it.** These passages were once inline,
re-read on every review, to justify decisions that only matter when the design is in
question.

## Contents

- **Why the severity line sits where it does** — the measured cost of walking every
  finding, and why CRITICAL is the cut in Step 7 while Step 4 cuts at HIGH.
- **Why bulk is recommended in one gate and not the other**.

## Why the severity line sits where it does

Step 4's exact-4/exact-2 option-shape check governs Step 4's
walk only — this walk's option count varies with the alternatives each finding
carries, so a 3-option question here is well-formed, not malformed. The gate is narrowed to CRITICAL
deliberately: a CRITICAL finding blocks the core requirement, contradicts a
sibling artifact, or violates a constitution MUST — each one is worth its own
question. Below that, a per-question walk taxes the user more than the
decisions are worth (a 21-step plan once produced twelve dense questions and
half an hour of answering), and the digest plus the batch question below keep
every choice the user's at a fraction of the cost. The options come from the
finding itself:

The measured cost is the whole argument: a 21-step plan once produced twelve dense
questions and roughly half an hour of answering at this gate alone. A CRITICAL finding
blocks the core requirement, contradicts a sibling artifact, or violates a constitution
MUST — each is worth its own question. Below that, the digest plus one batched question
keep every choice the user's at a fraction of the cost.

Step 4 cuts one tier lower, at HIGH, because its findings are *edits to the plan being
approved* rather than coherence defects in a plan already judged sound — a HIGH edit
there changes what gets built, which is the same consequence a CRITICAL carries here.

## Why bulk is recommended in one gate and not the other

Marking the
bulk option `(Recommended)` here is deliberate, and matches what Step 4's fold gate
now does below HIGH: the batch IS the design under the severity line, and every listed
recommendation is one the reviewer already named as the most practical and clean
resolution. What is never recommended in either gate is the bulk *decline*, or a bulk
answer covering findings the user has not seen individually. Two edge
cases collapse the batch: exactly one remaining finding gets a normal
per-finding question instead of a one-line list, and a remainder that is all
toss-ups skips straight to the walk — the lead option would cover nothing,
and a declared toss-up is precisely the finding that needs individual
judgment.
