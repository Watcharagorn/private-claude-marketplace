# Trigger evals — which mentor skill fires?

`hooks/tests/` proves the scripts behave. This proves the **descriptions** do: that a
user's phrasing reaches the skill it should, and — more importantly — not one of its
seven siblings.

mentor ships eight overlapping planning skills (`plan`, `plan-split`, `plan-track`,
`plan-review`, `grilling`, `dispatch-agents`, `resume`, `handoff`). The risk that
matters is not "does `plan-split` trigger" but "does `plan-split` fire when the user
meant `plan-track`". A description tuned on its own can score perfectly and still
collide, so this harness stages **all eight at once** and records which one wins.

## Run it

```bash
cd plugins/mentor/evals
python3 harness.py claude-opus-5 2      # <model> <reps-per-query>
```

Needs the `claude` CLI on PATH. ~20 queries × reps, 6 at a time, roughly 10–25s each.
The scratch project and `results.json` are written to `$TMPDIR/mentor-trigger-eval/`
(override with `MENTOR_EVAL_WORKDIR`) — never into the repo.

Baseline at v2.11.1: **36/40**, 18 of 20 queries clean on both reps.

## Seed the fixture first — this is not optional

```bash
python3 seed.py "$TMPDIR/mentor-trigger-eval/project"
```

`harness.py` stages the skills but not the plans they talk about. Against an empty
project, a query like *"is the invoice plan any good?"* makes the model hunt for a
file that isn't there and answer empty-handed. That scores as "did not trigger" and
is **indistinguishable from a genuinely weak description**.

This is not hypothetical: the first run of this eval reported 32/40, and six of those
eight failures were the missing fixture, not the skills. Seeding cleared all six. The
tell is timing — real triggers land in 7–25s, fixture-starved misses run 35–150s. If
a failure is slow, suspect the fixture before the description.

`seed.py` lays down a superseded parent, three split children with isolation headers
and state sidecars, an implemented standalone plan, and a live handoff note.

## The eval set

`evals.json` is **multi-class**, not the usual boolean `should_trigger`: each query
carries the skill that *should* win, or `none`. A binary label cannot express a
collision, which is the whole point here.

Ten queries are near-misses chosen to be genuinely hard — `resume` vs `plan-track` on
"where were we", `plan-review` vs `grilling` on "review" vs "poke holes", and four
keyword baits (`break up` commits, `split` a component, `review` a PR, `track` a
sprint) that share vocabulary with a skill but must trigger nothing.

## Two known failures, both understood

- **#20** (`plan` fires on a bare "help me plan X") is expected and **not** a hole.
  The semantic match beats any wording that merely asks the model to prefer the
  command — measured: rewording the description moved it 0/3. The real fix is
  `plan/SKILL.md` Step 0, which detects the unarmed gate after loading and refuses.
  The eval only records *which skill fires*, not what it does next, so this stays red
  by construction.
- **#2** is a flawed query, deliberately left alone. It reuses `plan-track`'s own
  phrase "one session at a time" and gives "break this up" no referent. Tuning a
  description to win it would be overfitting to a bad test.

When you add a ninth planning skill, run this first. A new sibling that quietly steals
an existing skill's queries is exactly what it is here to catch.
