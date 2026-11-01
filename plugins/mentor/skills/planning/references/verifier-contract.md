# Verifier prompt and return contract

Read this whenever a run needs a grade: after each implementation step, for each
`## Verification` topic, for the plan's `## Goal check`, and before a playbook's
merge. The agent that built the work never grades it (AGENTS.md → Mentor core
concept, rule 5). Paste the fenced block under "What the verifier must return"
into every verifier's prompt verbatim. A verifier briefed only with "check step 3"
re-derives the criteria from memory and confirms instead of checking.

## Who is dispatched

| Grade | One fresh verifier per | Brief carries |
|---|---|---|
| Step | implementation step | the step's `Goal:` and `Done when:` lines, verbatim |
| Topic | `## Verification` topic | its `Focus:`, `Checks:`, `Pass when:` lines, verbatim |
| Goal check | plan | the `## Goal check` predicate and the `## Done review` |
| Merge (playbook) | pull request | the PR diff, the plan path, the Goal check |

- Dispatch in the **foreground**, so the turn stays live until the verdict lands.
  Default model `sonnet`, effort `medium`; a topic may name its own.
- Where the host offers no subagents, run the same checks serially in the main
  thread and label the verdict `self-graded`. Never present a self-graded PASS as
  independent.

## What to hand the verifier

- The lines named in the table above, copied verbatim, never paraphrased.
- The exact file paths, and the plan path `.mentor/plans/<slug>/plan.md`.
- Any tool invocation already resolved this session (module path, launch flags), so
  the verifier does not rediscover it.
- For a race or timing-sensitive check, ask for 5+ independent runs before a PASS.
- The safe-check rule: a zero-hit or empty result is not evidence until the check
  itself is shown to work. A single-line `grep` misses a claim that wraps lines; an
  unquoted glob aborts under zsh `nomatch`; ERE wants `|`, not `\|`.
- For a plan predating `Topic N —`, derive the three lines from the prose bullet
  (title from its subject, its text as `Checks:`, its stated outcome as `Pass when:`).

## What the verifier must return

```
Verdict: PASS | FAIL | HANDBACK
<evidence per check — the exact command run and its output, or a file:line citation>

Gaps / Missing:
<one stamped line per gap, or the literal words "none found">
  [GOAL] <finding> — which `Done when:` / `Pass when:` / Goal check it leaves unmet — fix: <a few words>
  [NON-GOAL][SMALL] <finding> — why the goal is met without it — fix: <a few words>
  [NON-GOAL][LARGE] <finding> — why the goal is met without it — fix: <a few words>

Weakened checks:
<any `Done when:` or Goal check reworded since approval so it is easier to meet, or "none">

Evidence review:
<each Done review scenario marked observed with no evidence or a dead evidence path, or "none" / "n/a"; `evidence: not capturable on this host, verify by <command>` counts as evidence when it names a command>

Notes:
<observations that are NOT defects, or the literal word "none">

Cross-topic:
<a finding that belongs to a different step or topic — name it in one line, or "none">
```

## How the verdict is decided

- **`FAIL` iff at least one `[GOAL]` gap exists**, a check was weakened, or the
  evidence review lists a scenario. `[NON-GOAL]` gaps never fail a grade; they
  become decision-log rows marked `review?: optional`.
- **`HANDBACK`** is a verdict on the brief, not the work: the check itself is broken,
  unrunnable, or larger than what was handed over. Report what you did check and list
  the remainder. It costs the step none of its retry budget.
- **Stamps.** `[GOAL]` names the bullet it leaves unmet, which makes the stamp
  checkable. `[LARGE]` judges the fix: more than one layer, ~10+ files, a live
  multi-service stack to prove, or a design decision the plan never made.
- **Tiebreaks point at review**, never at a silent fix: unsure `[GOAL]` → stamp
  `[NON-GOAL]`; unsure `[LARGE]` → stamp `[LARGE]`. A misfiled `[NON-GOAL]` surfaces
  as a review row the human clears in seconds; a misfiled `[GOAL]` disappears.
- `Gaps / Missing:` is mandatory even on PASS. Its explicit line is what forces
  "what is missing?" to be asked.
- `Notes:` holds everything that is not a defect, so no review row is spent on a
  non-problem.
- `Cross-topic:` never fails this grade. The orchestrator routes it to that step's
  or topic's verifier, or logs it as its own row.
- The verifier reports and stamps. It never fixes, never edits the plan, and never
  ticks a step.

## What the orchestrator does with it

The caller decides what a verdict triggers: planning → "After Proceed" for a step,
topic, or Goal check (no PASS row, no tick), and merging → "Step 3.5" for a merge.
**HANDBACK** is a verdict on the brief: repair the brief or the check and re-dispatch
fresh, with the remainder as its inputs. It costs no retry (merging caps it at one
repair per PR).

Before going idle, the verifier writes its block to
`.mentor/plans/<slug>/step-N-verify.md`, `topic-N-verify.md` or `goal-verify.md`.
A verifier carrying several topics returns the whole block once per topic, each
under its own `Topic N —` heading and written to its own file: one merged verdict
hides a failing topic behind a passing one.
