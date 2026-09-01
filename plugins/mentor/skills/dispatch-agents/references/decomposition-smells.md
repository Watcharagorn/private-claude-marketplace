# Decomposition smells — when a step is too big for one agent

Read this while sizing plan steps (the **Budget each step to one agent's context**
rubric item in `SKILL.md`), and whenever you are judging whether an existing plan's
steps are the right size — `mentor:plan-review` cites this file for the same reason.
It is the single source for the smell list, so a reviewer and an author can never be
working from two drifted copies.

## Why smells rather than a count

A dispatched agent never compacts. Every tool result and every thinking block it
emits stays in its context until the step ends, so a step that looked modest on the
page can exhaust an agent's window halfway through and hand back nothing usable.
Nobody can count those calls while authoring a plan — the number depends on what the
agent finds. Smells are what you *can* see at authoring time.

## The five smells

A step showing **any** of these is oversized and gets split:

1. **It spans more than one service or layer.**
2. **It touches more than ~10 files across distinct areas.**
3. **Its `Done when:` needs a live multi-service stack driven end-to-end.** That
   proof belongs to a `## Verification` topic instead — see *State done-when* in the
   rubric.
4. **Its `Inputs:`, or the reconnaissance it implies, pull in several whole large
   files** (tens of KB each). This is the costliest smell by measure, and the one a
   narrow-sounding step hides best.
5. **Its prompt sketch reads like a project brief rather than a task.**

## How to split

Split into **sequential steps, one dispatch each, handing off by report** — each
later step takes the prior step's report as its `Inputs:`. The rubric's *Collapse
small dependent steps* bounds the opposite end: collapse tiny steps, split giant
ones. If splitting pushes the plan past ~12 steps, that is `/plan-split`'s threshold
doing its job, not a reason to re-merge.

The measured context blowup behind these smells is in `rationale.md` →
**Sizing a step to one agent's context**.
