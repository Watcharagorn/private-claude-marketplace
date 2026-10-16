# Trigger evals — which mentor skill fires?

`hooks/tests/` proves the scripts behave. This proves the **descriptions** do: that a
user's phrasing reaches the skill it should, and — more importantly — not one of its
fourteen siblings.

mentor ships fifteen overlapping user-facing skills (`planning`, `plan-split`,
`plan-track`, `plan-review`, `grilling`, `dispatch-agents`, `resuming`, `handoff-note`,
`touring`, `previewing`, `merging`, `shipping`, `deferring`, `constitution-authoring`,
`frontend-self-ex-review`).
The risk that
matters is not "does `plan-split` trigger" but "does `plan-split` fire when the user
meant `plan-track`" — or, since v4.0.0, "does `previewing` steal `touring`'s
acceptance-page queries, or `plan-review`'s 'review the plan'" (all three look at a plan;
they differ on page against verdict, and on pass/not-pass interaction).
A description tuned on its own can score perfectly and still
collide, so this harness stages **all fifteen at once** and records which one wins.

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

Needs the selected host CLI on PATH and its normal authentication. ~73 queries × reps run six
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

## Seed the fixture first — this is not optional

```bash
python3 seed.py "$TMPDIR/mentor-trigger-eval/project-claude"
python3 seed.py "$TMPDIR/mentor-trigger-eval/project-codex"
```

`harness.py` stages the skills but not the plans they talk about. Against an empty
project, a query like *"is the invoice plan any good?"* makes the model hunt for a
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
(query 59), a live handoff note, and one review page at
`.mentor/reviews/billing-invoice/review.html`, so query 32's refresh finds a prior page.
It also lays down a QA tour page under `.mentor/tours/` (query 34), a work queue in the
billing-invoice plan's context (query 27), and four subject stubs — payment, ingestion,
auth, checkout — for queries 22–24 and 44, which name an area with no plan.

The v4.0.0 fixture added the tour page, the queue line, the stubs and the onboarding
plan; results from older fixtures are not comparable on ids 22–24, 27, 34, 44 and 59.

## The eval set

`evals.json` is **multi-class**, not the usual boolean `should_trigger`: each query
carries the skill that *should* win, or `none`. A binary label cannot express a
collision, which is the whole point here.

Many queries are near-misses chosen to be genuinely hard — `resume` vs `plan-track` on
"where were we", `plan-review` vs `grilling` on "review" vs "poke holes", `previewing`
vs `touring` on "a page" (a pre-approval review page vs pass/not-pass acceptance),
`previewing` vs `plan-review` on "a proper look at the plan" and "review the plan", and
five keyword baits (`break up` commits, `split` a component, `review` a PR, `track` a
sprint, a video-call meeting) that share vocabulary with a skill but must trigger
nothing.

## Known failures

- **#20** is intentionally green from v3.1.0 onward: natural-language planning is the
  portable entry point. Claude can still add the `/mentor:plan` command and edit gate,
  while Codex follows the same skill guidance-first.
- **#2** is a flawed query, deliberately left alone. It reuses `plan-track`'s own
  phrase "one session at a time" and gives "break this up" no referent. Tuning a
  description to win it would be overfitting to a bad test.
- **#37** (`handoff-note` vs `deferring`) fell from 4/6 on the 3.1.0 skills to 2/6 at
  v4.0.0 in the 6-rep re-measure on the same fixture (2026-10-11). It is set aside and
  not yet explained; read a red #37 as a possible description regression until it is.

- **#55** (`dispatch-agents` on a goal-blocking verification gap, added in v2.33.0) is
  **not baselined**. Measured over 10 runs it splits between `dispatch-agents` and a bare
  non-trigger, every run landing in the 55–100s band this file flags as the
  fixture/latency signature rather than a description defect — and untouched **#45**, a
  pre-existing core trigger whose description v2.33.0 never edited, fails 4/4 the same
  slow way in the same environment. What #55 exists to guard **does** hold flat: across
  all 10 runs `deferring` never fired once. The v4.0.0 baseline above measured the whole
  set, #55 included, on the current fixture: #55 went to no skill on both reps (0/2),
  as it did for the 3.1.0 skills. Compare a red #55 with that run, not with this note.

When you add a skill, run this first. A new sibling that quietly steals
an existing skill's queries is exactly what it is here to catch — v2.12.0's topic ×
perspective page skill (vs `tour`, vs `plan-review`) is the worked example, and v4.0.0's
`previewing` adds near-misses against the same two.
