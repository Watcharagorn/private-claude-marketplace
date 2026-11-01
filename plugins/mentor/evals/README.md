# Trigger evals — which mentor skill fires?

`hooks/tests/` proves the scripts behave. This proves the **descriptions** do: that a
user's phrasing reaches the skill it should, and — more importantly — not one of its
seven siblings.

mentor ships eight overlapping user-facing skills (`planning`, `playbook-software-change`,
`grilling`, `previewing`, `merging`, `shipping`, `constitution-authoring`,
`frontend-self-ex-review`). The risk that matters is not "does `playbook-software-change`
trigger" but "does it fire when the user meant `planning`" — a playbook is loaded *by*
planning, so a direct hit on it is usually the wrong route — or "does `previewing` steal `frontend-self-ex-review`'s UI
queries" (both look at screens; they differ on a review page against a self-explanatory
verdict). A description tuned on its own can score perfectly and still collide, so this
harness stages **all eight at once** and records which one wins.

Note the skill names are the **skill** names, not the command names: since v2.18.0 no
skill shares a name with a command (`/mentor:plan` → skill `planning`, and so on), which
is what makes the skills reachable and their descriptions visible at all. Anything this
harness measures is measuring the real routing surface only because of that split.

## Run it

```bash
cd plugins/mentor/evals
python3 harness.py claude claude-opus-5 2  # <host> <model> <reps-per-query>
python3 harness.py codex gpt-5.6-sol 2
```

Needs the selected host CLI on PATH and its normal authentication. ~42 queries × reps run six
at a time. The scratch projects and `results-<host>.json` files are written to
`$TMPDIR/mentor-trigger-eval/` (override with `MENTOR_EVAL_WORKDIR`) — never into the repo.
Keep Claude and Codex baselines separate because model routing behavior is not interchangeable.

Baseline at v2.11.1: **36/40**, 18 of 20 queries clean on both reps — over 8 staged
skills and queries 1–20. v2.12.0 stages 10 skills (`tour` and the topic × perspective
page skill joined) and adds queries 21–28; re-baseline on the first run. A later refresh staged 15 skills
(`deferring`, `constitution-authoring`, `plan-touring` joined) and added queries 36–44.
**v3.0.0** removed `plan-touring` (14 skills staged, query 42 dropped) and rewrote
several descriptions in the isolation pass — re-baseline pending; the harness was not
re-run as part of that change. **v4.0.0** replaced the topic × perspective skill with
`previewing` (still 14 staged), retargeted queries 21–24, 32 and 44 to it, and added
queries 56–59 (two `previewing` core triggers, near-misses for `plan-review` and
`touring`).

Baseline at v4.0.0 (Claude, `claude-opus-5-5`, 2 reps, 2026-10-11): **98/116**, against
86/108 for the 3.1.0 skills on the older fixture the same day. Every `previewing`,
`plan-review` and `touring` query routed as expected on both reps except #34 (1/2) and
#59 (0/2, before the onboarding plan joined the fixture), and no miss went to a wrong
skill. A 6-rep re-measure on the current fixture, new skills against 3.1.0: #59 6/6
(new query), #34 5/6 vs 5/6, #8 5/6 vs 5/6, #37 2/6 vs 4/6.

**v4.1.0** stages 15 skills (`frontend-self-ex-review` joined) and adds queries 60–73: core
and plain-wording triggers for a self-explanatory screen (#60–63, #69–71), near-misses for
`plan-review` (#64), `touring` (#65) and `previewing` (#68), and four `none` baits (blog-copy
editing #66, an aesthetic restyle #67, a general UI review with no self-explanatory goal #72, a
component code review #73). Measured on the shipped description (Claude, `claude-opus-5-5`,
2026-10-16): #60–62, #66, #69, #72 and #73 at 4 reps went **28/28**; the 17 queries the new skill
could plausibly steal (#7, 9, 21–27, 34, 40, 43, 44, 56–59) plus #63–65, #67, #68, #70 and #71 at
2 reps went **46/48**. The two misses, #34 and #57, went to no skill in the slow 30–45s band, not
to the new skill; #57 scored 4/4 with and 4/4 without the skill staged in a same-day run. Two
earlier description drafts are not comparable: one that read as review-only lost "make it
textless" requests (#62 0/2) until the description said to use the skill first even when the
user asks for the change. A full-suite re-baseline is still pending.

**v5.0.0** removed `plan-track`, `plan-review`, `dispatch-agents`, `resuming`,
`handoff-note`, `touring` and `deferring`, so the harness stages 8 skills. Their 34 queries
went: 30 deleted, and 4 kept as `none` negatives — #6 ("where were we"), #11 (fan out to
subagents), #13 (write up where we are for a fresh session) and #36 (note a bug for later) —
since no mentor skill owns those asks any more. The set is now 42 queries (25 skill, 17
`none`). Every number above was measured on the larger skill set and is not comparable;
re-baseline on the first run.

## Seed the fixture first — this is not optional

```bash
python3 seed.py "$TMPDIR/mentor-trigger-eval/project-claude"
python3 seed.py "$TMPDIR/mentor-trigger-eval/project-codex"
```

`harness.py` stages the skills but not the plans they talk about. Against an empty
project, a query like *"comment on each scenario of the onboarding plan"* makes the model hunt for a
file that isn't there and answer empty-handed. That scores as "did not trigger" and
is **indistinguishable from a genuinely weak description**.

This is not hypothetical: the first run of this eval reported 32/40, and six of those
eight failures were the missing fixture, not the skills. Seeding cleared all six. The
tell is timing and wording: real triggers land in 7–25s, while a fixture-starved miss
either runs slow (35–150s) as the model hunts for the file, or comes back fast (13–25s)
saying there's no such plan or area. Either way, suspect the fixture before the
description.

`seed.py` lays down a superseded parent, three split children with isolation headers and
state sidecars, an implemented standalone plan, an approved `user-onboarding` plan
(query 59), and one review page at `.mentor/reviews/billing-invoice/review.html`, so
query 32's refresh finds a prior page. It also lays down a work queue in the
billing-invoice plan's context and four subject stubs — payment, ingestion, auth,
checkout — for queries 22–24 and 44, which name an area with no plan.

The v4.0.0 fixture added a tour page, the queue line, the stubs and the onboarding
plan; results from older fixtures are not comparable on ids 22–24, 44 and 59. v5.0.0
dropped the handoff note and the tour page along with the skills that read them.

## The eval set

`evals.json` is **multi-class**, not the usual boolean `should_trigger`: each query
carries the skill that *should* win, or `none`. A binary label cannot express a
collision, which is the whole point here.

Many queries are near-misses chosen to be genuinely hard — an in-document re-phasing
(#3), `previewing` vs `frontend-self-ex-review` on a page of the
frontend (#68), `shipping` vs `merging` on "get it up as a PR" (#30), and keyword baits
(`break up` commits, `split` a component, `review` a PR, `track` a sprint, a video-call
meeting, the US constitution, a general UI review, a component code review) that share
vocabulary with a skill but must trigger nothing. The four v5.0.0 negatives (#6, #11,
#13, #36) guard the opposite drift: a kept skill quietly absorbing a removed one's asks.

## Known failures

- **#20** is intentionally green from v3.1.0 onward: natural-language planning is the
  portable entry point. Claude can still add the `/mentor:plan` command and edit gate,
  while Codex follows the same skill guidance-first.
- **#2** is a flawed query, deliberately left alone. It borrows the old plan-status
  phrase "one session at a time" and gives "break this up" no referent. Tuning a
  description to win it would be overfitting to a bad test.

When you add a skill, run this first. A new sibling that quietly steals
an existing skill's queries is exactly what it is here to catch — v2.12.0's topic ×
perspective page skill (checked against the then-staged `tour` and `plan-review`, since removed) is the worked example, and v4.1.0's
`frontend-self-ex-review` added near-misses against `previewing`.

## Behaviour evals (v6.0.0)

`behaviour.json` is a separate, smaller set: it checks what an **approved run** does, not
which skill fires — no question on a reversible fork, a pause on an always-pause item, a
decision-log row per choice, a verifier before every tick, a mid-run product call decided without pausing, and
a non-code goal picking no playbook. Each case seeds a scratch repo with an approved plan
and is graded by a reader against its assertions; `harness.py` does not run it.
