---
name: plan-review
description: |
  Pre-approval plan reviewer — judges a written plan's QUALITY before you approve
  it, not whether it has been built (that is /mentor:track). Trigger phrases:
  `/plan-review`, "review this plan", "review the plan", "is this plan any good",
  "send the plan to reviewers" — or, for the mechanical pass alone:
  "check plan consistency", "consistency review",
  "analyze the plan for consistency".
  Reads the current mentor plan (.md) and, with the edit gate closed, runs a
  staged review: Stage 1 judgment reviewers (practicality,
  comprehensiveness), then a fold gate that walks their recommended edits
  ONE AT A TIME — each edit its own question, verdicted fold/skip; then
  Stage 2 mechanical reviewers (cleanliness + a
  spec-kit-analyze-style consistency check over related artifacts) against
  the updated plan, whose safe fixes auto-fold while decision-level findings
  surface as a one-line digest — only CRITICAL ones get their own question,
  the rest resolve in one batch. Stage 2 is also invocable on its own.
---

# Plan Review — Judgment, Fold, then Mechanical Auto-Fold

A pre-approval review pass in **two stages of two concurrent reviewers each**:
it reads the current plan, confirms at the Step 2 gate, then fans out the
**judgment reviewers** (practicality, comprehensiveness) — one `Agent()` call
per dimension in a **single message**. Their recommended edits go through a
**fold gate** (Step 4): the user verdicts each edit **one question at a
time** — every question presents the reviewer's case the way a human reviewer
would, self-contained and in plain language, key words bolded — and the
accepted edits are folded by re-writing the plan in place. Only then do the **mechanical reviewers** (cleanliness,
consistency) dispatch — against the UPDATED plan, so they also catch anything
the fold introduced. Their `MECHANICAL`-tagged fixes are auto-folded;
`DECISION-REQUIRED` findings surface as a one-line digest, CRITICAL ones
walked one question at a time and the rest resolved in a single batched
verdict — applied only on the user's verdict, never automatically. Reviewers stay
read-only and this worktree's plan gate (`.planning.<wt-id>`, or a live legacy
`.planning`) stays closed throughout, but this skill
itself writes ONE file — the plan `.md`, at Step 5 (fold) and Step 7
(auto-fold + verdict fold), inside the gate-exempt `.mentor/` tree. The
mechanical stage can also be invoked **on its own** (see Stage-2-only mode
below).

The four fixed dimensions are:

1. **Practicality** — is the approach feasible, realistically scoped, low-risk?
2. **Comprehensiveness** — does it cover the requirement, edge cases, and gaps?
3. **Cleanliness** — is the resulting design simple, maintainable, reuse-aware?
4. **Consistency** — spec-kit-`analyze`-style: do the plan's own sections and
   its related planning artifacts cover, agree with, and unambiguously specify
   each other?

The judgment reviewers weigh the plan's solution against the requirement and
reality — accepting their edits is a call only the user can make. The
mechanical reviewers police quality and coherence, where a safe fix needs no
human in the loop. The lanes are exclusive so the reviewers don't overlap:

| Reviewer | Stage | Looks | Owns (exclusively) |
|---|---|---|---|
| Practicality | 1 — judgment | outward | feasibility, scope realism, risk |
| Comprehensiveness | 1 — judgment | outward | does the **solution** address the real requirement & real-world edge cases |
| Cleanliness | 2 — mechanical | outward | design simplicity, maintainability, reuse |
| Consistency | 2 — mechanical | inward + across | do the plan's **own sections & related artifacts** agree, trace to each other, stay unambiguous |

The boundary that matters: a **comprehensiveness gap** = the plan omits
something the *real requirement* needs; a **consistency coverage-gap** = the plan
*states* something (a scenario) but no step carries it through. There is no
domain detection — the full pass always reviews these same four dimensions.

## When to use

- The user typed `/plan-review` (or "review this plan"), or chose "Review the plan (staged)" at the `plan` approval step — run both stages.
- The user asked for the consistency check alone ("check plan consistency", "consistency review") — run Stage-2-only mode.
- A mentor plan `.md` exists in the plans dir and the user wants feedback before approving.

## When NOT to use

- After approval — the plan is released; use `mentor:dispatch-agents` to execute it.
- The user wants their own **open design decisions** interactively pressure-tested,
  one question at a time — that is `/mentor:grill`. This skill audits a written
  document with fixed lenses; grilling interrogates the person.
- The user is asking **whether a plan has been built**, not whether it is any good —
  that is `/mentor:track`.
- No plan file in the mentor plans dir.
- Single-file typo fixes or trivial edits where review costs more than the change.
- The user explicitly asked, live in this session, NOT to invoke sub-agents — honor it
  directly and skip this skill. A **standing** policy found in the repo rather than said
  live (CLAUDE.md, a project rule file, an earlier handoff note) is not this bullet: it is
  `dispatch-agents`' pre-dispatch **Standing no-subagents policy** check, which asks rather
  than silently skipping.

## Step 1 — Resolve the plan file(s)

```bash
[ -d "${CLAUDE_PLUGIN_ROOT}/hooks" ] || { echo "ERROR: CLAUDE_PLUGIN_ROOT unresolved or stale — do not search the plugin cache or hardcode a version path; ask the user to /reload-plugins or restart" >&2; exit 1; }
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" current
```

The `PLAN:` line is the **primary** plan — the subject every reviewer reads — and its
directory is `plan_dir`. If nothing is printed, say `Plan review aborted: no plan file
found.` and stop. Then `Read` the primary plan — it IS its own canonical source. Do
**not** edit it yet — plan edits happen only at Step 5 (fold) and Step 7 (auto-fold +
verdict fold).

Primary-subject resolution is safe by construction: bare `current` (no `--any`) is
ownership-scoped to plans owned by this worktree, or unowned, since v2.23.0 — the
plan it resolves is never a sibling worktree's in-flight draft.

**When `GROUP:` is not `-`**, the primary plan is one slice of a `/plan-split` group,
and the script prints its siblings. Reviewing an arbitrary slice is rarely what the
user wants, so ask which sibling to review — or all of them, which means running this
whole skill once per sibling. Do not silently pick one.

**Related artifact set (consistency reviewer only).** Also enumerate the other
planning artifacts so the consistency reviewer can check cross-artifact
coherence — the Stage 1 reviewers and the cleanliness reviewer only ever see
the primary plan:

```bash
plan_dir="<the dirname of the PLAN: path above>"
plans_dir="$(dirname "$plan_dir")"
repo_root="$(cd "$plans_dir/../.." && pwd)"
zoom_dir="$(dirname "$plans_dir")/zooms/$(basename "$plan_dir")"   # mentor:zooming's plan-slug contract
ls -t "$plans_dir"/*/plan.md 2>/dev/null              # ALL plans, newest first, incl. superseded — see below
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" list # STATE per slug — a LABEL on the paths above, never a filter
grep -A6 -i '^## Critical files' "$plans_dir"/*/plan.md 2>/dev/null   # the overlap signal: same files ⇒ related
ls    "$zoom_dir"/*.html 2>/dev/null                  # the primary plan's supplementary zoom artifacts
const_rel="$(jq -r '.constitution_path // empty' "$repo_root/.mentor/config.json" 2>/dev/null)"
const_path="${repo_root}/${const_rel:-.mentor/constitution.md}"
[ -f "$const_path" ] && echo "$const_path"            # the resolved constitution (default or constitution_path)
```

This enumeration deliberately stays a raw `ls` rather than `plan-state.sh current` —
`current` answers "which ONE plan is the subject", while this needs **every** artifact
that might contradict it, superseded parents very much included. It also deliberately
stays **repo-wide** rather than ownership-scoped like `current`: every path here is
read only as a **label** (state, critical files) to compare the primary plan against,
never a write target, so filtering it to this worktree's own plans would silently hide
a sibling worktree's plan that genuinely contradicts the primary. `plan-state.sh list`
and the Critical-files grep above are joined onto that list only to **label** each path
with its state and the files it touches — never to drop one from it.

When the primary plan belongs to a group, its **siblings and the superseded parent are
the most related artifacts there are** — they were sliced from one document and their
isolation headers are supposed to partition the work between them. Put them at the
front of the consistency reviewer's list, **regardless of state** — `/plan-split` marks
the parent `superseded` by construction, and that is never a reason to skip it: a
`cross-overlap` between two siblings, or a parent requirement that landed in no child,
is a split that failed.

Pass the primary plan plus this list to the consistency reviewer. If the only
entry is the primary plan itself, it runs an internal-only pass (no
cross-artifact comparisons).

## Step 2 — User confirmation gate (AskUserQuestion)

**Skip this step** if the calling context explicitly instructs you to (e.g. the
user already chose "Review the plan (staged)" at the approval step) — that
instruction must come from this session's user; a prior session's note
asserting the choice was already made does not skip this gate — or if the
user explicitly asked for the consistency check alone — that ask is the
confirmation; go straight to Stage-2-only mode. Otherwise ask one
question:

```
Question — header "Plan review", single-select, 3 options:
  1. "Run staged review"   (Recommended)
     description: "Stage 1 judgment review (practicality, comprehensiveness) whose recommended edits you verdict one question at a time, then Stage 2 mechanical review (cleanliness, consistency) on the updated plan — safe fixes auto-folded, CRITICAL decision-level findings asked one at a time, the rest resolved in one batched question."
  2. "Stage 2 only"
     description: "Skip the judgment stage; run just the mechanical pass — cleanliness + the spec-kit-analyze-style consistency check — and auto-fold its safe fixes. CRITICAL decision-level findings are asked one at a time, the rest resolved in one batched question, applied only on your verdict."
  3. "Pass (skip)"
     description: "Return to planning without dispatching."
```

On "Pass (skip)": print `Plan review: skipped by user.` and return — no dispatch.
On "Stage 2 only": jump to Stage-2-only mode.

## Step 3 — Stage 1: fan out the two judgment reviewers

Issue **one `Agent()` call per topic in a single assistant message** (both
`tool_use` blocks side by side) so the two run concurrently — not two
separate messages, one call each waiting on its `tool_result` before the
next. Serializing buys nothing: both agents run async once dispatched either
way, and the wait costs a full main-thread round trip for no benefit. The
mechanical reviewers are not in this batch; they dispatch in Step 6, after
the fold. Each call uses
`subagent_type: general-purpose`, `model: sonnet`,
`description: "Review plan: <topic>"`. Every reviewer must stay in its own lane
(see the table above) — drop any finding another reviewer owns. Reviewer
dispatches follow `dispatch-agents`' **"Async runtime & lifecycle"**
rules — invoke `Skill(skill="mentor:dispatch-agents")` now if it is not already
loaded (this skill runs standalone as often as it runs from `plan`, so usually it
is not), then end each reviewer's prompt with that section's **"Deliver before
idling"** block pasted verbatim. Loading it is for that block and the **Standing
no-subagents policy** check alone: nothing here is being implemented and this
worktree's plan gate stays closed. That block is also what
produces the durable verdict copy — give each reviewer its own filename for it,
`.mentor/plans/<slug>/practicality-review.md` and
`.mentor/plans/<slug>/comprehensiveness-review.md`, since both dispatch in one
message and the block's own `step-N-review.md` example would have them writing over
each other. Close **both** Stage 1
reviewers out once their findings are consumed, BEFORE blocking on the Step 4
fold gate — an idle agent must not interrupt the gate with stray
notifications. Closing out means actually calling `TaskList` (fetch it plus
`TaskStop` via `ToolSearch` first if they haven't been loaded this session)
and diffing against the two dispatched reviewers before `TaskStop`ping them —
writing "both reviewers are closed out" without having made that call is a
claim you can't back, and the reviewer stays resident, unnoticed, until
something else stops it.

If one reviewer dies, note it and run the fold gate on the survivor's
findings; if both die, note it and go straight to Step 6.

### Reviewers 1-2 — practicality, comprehensiveness

Each `prompt` must contain:

1. `Act as a solution/architecture reviewer of this plan. You are reviewing a plan, not implementing it.`
2. The primary plan file path with an explicit `Read this file before doing anything else.`
3. `Critique the plan's solution strictly through the lens of <topic>.` plus the one-line definition:
   - `practicality` → `Is the approach feasible, realistically scoped, and low-risk?`
   - `comprehensiveness` → `Does it cover the requirement, edge cases, and gaps?`
4. `When proposing Recommended plan edits, recommend the most practical and clean solution — never trade maintainability or reliability for implementation speed — and give each edit a one-line why.` This governs how the reviewer constructs and picks among its OWN proposed edits — it never widens the critique lens set by item 3 above.
5. Required structured output:
   ```
   Strengths:
   Risks:
   Gaps:
   Recommended plan edits:
   ```
6. Word cap: `Cap your reply at 400 words.`
7. Anti-recursion: `Do not invoke /plan-review or any planning skill.`
8. **Constitution (conditional)** — if the resolved constitution exists (the
   `$const_path` from Step 1 — default `.mentor/constitution.md`, or the file
   `constitution_path` in `.mentor/config.json` points at), add its path to
   every reviewer's prompt with:
   `Also read <const_path> and flag, under Risks, any place this plan
   violates a stated principle (name the principle).` Skip this line when the file
   is absent — do not add a separate constitution reviewer; the check stays folded
   into all reviewers.
9. Gitignore caveat: `If a claim in this plan rests on a repo-wide search finding
   nothing, re-check it before trusting it by running: bash
   "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" sweep '<pattern>' --roots repo — .mentor/
   is gitignored by design, so a recursive grep silently skips it. That subcommand hands
   grep an explicit file list instead of letting it walk, and its SWEEP: line reports how
   many files were actually read, so a zero result can be told apart from a search that
   read nothing at all (exit 2).` A reviewer verdicting a plan's own research, rather than
   doing fresh research itself, is exactly the surface this catches — and the wording this
   line used to carry, "re-check with the gitignore bypassed", is what sent reviewers
   reaching for a non-portable flag instead.

## Step 4 — Fold gate: one verdict per edit, asked one at a time

Surface both reviewers' `Strengths/Risks/Gaps/Recommended plan edits` blocks
in full, giving every recommended edit a stable **handle** as you surface it —
a 2–4 word plain-language name for what the edit does ("rollback step",
"edge-case tests", "split the migration"). Handles are the contract for the
questions below, for "Other" answers, and for the closing report. Never use
letter-number codes (`P2`, `C3`) or any other shorthand the user would have
to decode: a code forces a scroll-back to the surfaced block to learn what it
means, while a handle carries its meaning with it.

If neither reviewer returned recommended edits, say so and go straight to
Step 6. Otherwise walk the edits **one at a time** (practicality's edits in
order, then comprehensiveness's): each edit gets its own `AskUserQuestion`
call containing exactly ONE
single-select question, and the next question is not asked until the current
verdict lands. Never batch several edits into one question or one call — the
point is that the user judges each finding on its own merits, the way a
reviewer walks a colleague through a review, instead of skimming a checklist.
Before building each call, count the edits still ahead of this one: the
option set is exactly 4 (`Fold in`, `Skip`, `Skip the rest`, `Fold in the
rest`) while more than one remains, exactly 2 (`Fold in`, `Skip`) on the
last — a long walk is where a call quietly drops back to the 2-option form
out of habit, so treat a mismatch between the count and the position as a
malformed call and rebuild it before sending, not after the user notices.

**Each question must carry the full case, written like a human review — and
stand entirely on its own.** This is the fullest statement of a rule every
mentor skill that asks a question carries: the user answers from the question
screen alone, never sent to a file, a plan section, a coined id or code, or an
earlier turn to learn what the question means. The user verdicts from the
question alone,
without opening the plan or scrolling back through the conversation, so put
the substance in the question itself and **bold the load-bearing words** —
the **risk** being closed, the **place in the plan** touched, the
**behavior** that changes — so the eye lands on what matters first.
Self-contained means no pointers of any kind: never name a plan location by
bare label ("Section A", "Step 3", "the table above") — say what that part of
the plan *does* ("the step that migrates the users table"), and when the edit
rewords existing text, quote the plan's current sentence so the user reads
the actual words. Never cite a reviewer or an earlier finding by code or
position ("as the second practicality edit noted") — restate the point in
place:

```
question: "(<k> of <n>) <ONE plain sentence naming the decision being asked —
           the eye lands on the ask before the evidence — then the reviewer's
           case in 2–4 sentences: what the plan
           currently says (quoted or described by content, never by label),
           why it matters (the concrete **risk**, **gap**, or **cost** of
           leaving it), and what the edit changes — with the key
           words/phrases in **bold**.>"
header: the edit's handle, compressed to ≤12 chars (e.g. "Rollback")
options:
  1. "Fold in (Recommended)" — description: the reviewer's one-line why this
     edit is worth making, then the exact change to the plan — where (named
     by what it does, not a section label), what is added/removed/reworded —
     and the payoff. When the reviewer supplied concrete text, attach a
     `preview` showing the edit as before → after, so the user reads the
     actual words, not a paraphrase.
  2. "Skip" — description: leave the plan unchanged here, and what that
     accepts (the risk stays open / the gap stays uncovered).
  3. "Skip the rest" — description: skip this and every remaining edit and
     move on to Stage 2. (Offer only while more than one edit remains.)
  4. "Fold in the rest" — description: fold this and every remaining edit,
     naming each one it covers by handle ("folds this plus the rollback step
     and edge-case tests"), so the click is never blind. (Offer only while
     more than one edit remains.)
```

Every question at this gate carries the same binary, which is what makes a bulk
answer well-defined here — and offering a bulk decline without a bulk accept
quietly biases the gate toward skipping. If the user **rejects the question** and
free-types an instruction instead ("fold in all"), map it onto the option set,
then state the exact edits — each by handle — you read it as covering and get
confirmation before folding. The span is rarely as obvious as it looks:
answered edits are already behind you, so "all" may mean the remainder or the
whole set.

Mark `"Fold in"` as `(Recommended)` on every edit question — each surfaced
edit is, by construction, one the reviewer already recommends (Step 3's
prompt requires it), so the option that applies it leads and carries the
label; the reviewer's one-line why lives in its `description`, which is what
keeps the mark substantive instead of habitual. Never mark `"Fold in the
rest"` or `"Skip the rest"` as `(Recommended)`: a bulk verdict is the user's
call to make, and nudging toward one would hollow out the one-edit-at-a-time
design this gate exists for. An
"Other" answer may accept a modified version of the edit
("fold the rollback step, but only for the rollout phase") — fold the
modified wording — or name earlier edits by handle to revisit. Skipping every
edit is a valid outcome: fold nothing and continue to Step 6 regardless.

**Re-entry dedup:** when the staged review runs again in the same session (the
approval question loops back here), do not re-ask edits the user already
declined — only new or changed findings get questions. Note the declined
edits by handle in the surfaced text so the user can revive one via "Other"
at any question.

## Step 5 — Fold the accepted edits

Apply exactly the edits the user accepted at the fold gate — including any
modified wordings or revisited edits accepted via "Other" — in ONE pass,
revising and re-writing the SAME plan file in place per `plan` Step 4 — never
a second copy, never anywhere else. Do not apply skipped edits, and do not
"improve" unrelated text while you're in the file — Stage 2 owns quality
fixes. If every edit was skipped, skip the write.

## Step 6 — Stage 2: fan out the two mechanical reviewers

**Re-check context before this dispatch.** Stage 1's two-reviewer round plus
Step 4's walk can spend real budget, and this skill has no earlier context
reading of its own to have grown stale — nothing measures it before this
point, whether entered via Step 5 or, in Stage-2-only mode, directly. Run
`bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" context` and follow its
printed guidance verbatim rather than improvising a question: `ASK` hands you
the exact `AskUserQuestion` to ask, with its hand-off and bypass options, and
holds the dispatch below until it's answered; `HANDOFF`/`WARN` print a note to
carry into Step 7's report and you proceed; `OK`/`UNKNOWN` proceed silently.
This is the same backstop `mentor:track` already runs before its own
dispatch — Stage 2 is this skill's equivalent moment.

Dispatch **only after Step 5 completes** (the write, or the fold-nothing
decision) — both reviewers read the UPDATED plan, so they also catch anything
the fold introduced. Issue one `Agent()` call each in a single message (both
`tool_use` blocks side by side) — not two messages, one call each waiting on
its `tool_result` before the next; that serialization spends a full
main-thread round trip for no benefit, since both agents run async once
dispatched either way. `subagent_type: general-purpose`, `model: sonnet`. Dispatches follow
`dispatch-agents`' **"Async runtime & lifecycle"** rules, handled the same way as
Step 3: load `Skill(skill="mentor:dispatch-agents")` if it is not already loaded,
then end each prompt with its **"Deliver before idling"** block pasted verbatim,
with this stage's own durable-copy filenames —
`.mentor/plans/<slug>/cleanliness-review.md` and
`.mentor/plans/<slug>/consistency-review.md`. Close both reviewers out once their
findings are consumed, BEFORE Step 7's first verdict question — walk or
batch — blocks on the user; an
idle agent must not interrupt the questions with stray notifications. If one
dies, note it and run Step 7 on the survivor's findings.

**Both prompts embed this tagging contract verbatim** — it is what lets
Step 7 apply fixes without a human in the loop:

```
Tag every finding exactly one of:
- MECHANICAL — the fix is fully determined by the plan text itself: wording,
  grammar, section structure, step numbering/ordering labels, terminology
  drift (converge on the dominant term), duplication merges, dangling
  internal references, coherence fixes where one side is unambiguously
  canonical. Applying it changes HOW the plan says something, never WHAT it
  decides. A MECHANICAL finding MUST carry the exact edit: location +
  replacement text — a MECHANICAL finding without one is treated as
  DECISION-REQUIRED.
- DECISION-REQUIRED — resolving it means choosing between substantive
  alternatives: contradictions where either side could be intended, scope or
  step additions/removals/reordering, coverage gaps, feasibility or design
  concerns, constitution violations. State the options and name the one you
  recommend: the most practical and clean solution —
  never trade maintainability or reliability for implementation speed — with
  a one-line why; the choice remains the user's. This governs how you
  construct and choose among your OWN proposed resolutions — it never
  re-scopes what you are critiquing. On a genuine either-side-could-be-intended
  toss-up with no grounded basis to prefer one, say so explicitly and omit
  the recommendation rather than invent one.
If in doubt, tag DECISION-REQUIRED — the auto-fold must never make a
substantive choice on the user's behalf.
```

### Reviewer — cleanliness

`description: "Review plan: cleanliness"`. Its `prompt` must contain the same
scaffolding as the Step 3 reviewers (role line, primary plan path +
read-first, the solution-quality directive, anti-recursion, conditional
constitution, gitignore caveat) with these lane specifics:

- `Critique the plan's solution strictly through the lens of cleanliness.` →
  `Is the resulting design simple, maintainable, and reuse-aware?`
- One lane-specific check, since step size is a maintainability property of the
  plan itself: have the reviewer flag any implementation step showing the
  oversized smells from `mentor:dispatch-agents`' **"Budget each step to one
  agent's context"** rubric item, and any step whose `Done when:` requires a live
  multi-service stack driven end-to-end — that proof belongs to a
  `## Verification` topic, so a step carrying it makes the implementer prove it in
  the session's most expensive context and a fresh verifier re-prove the same
  ground. Paste that rubric item's smell list into the prompt rather than
  paraphrasing it (this step already loads the skill for the standing block), so
  the check cannot drift from the rule it enforces. Both findings are
  `[DECISION-REQUIRED]`: splitting a step, or moving its acceptance into
  `## Verification`, reshapes the plan and must never auto-fold.
- Required structured output: the `Strengths/Risks/Gaps/Recommended plan
  edits` block, where every `Recommended plan edits` item MUST open with
  `[MECHANICAL]` or `[DECISION-REQUIRED]` per the tagging contract, and a
  MECHANICAL item carries its exact edit (location + replacement text).
  A `[DECISION-REQUIRED]` item also carries its severity inline right after
  the tag — `[CRITICAL]`/`[HIGH]`/`[MEDIUM]`/`[LOW]`, the consistency
  reviewer's scale, where CRITICAL in this lane means the plan is unbuildable
  or its acceptance unverifiable as written — because Step 7 uses severity to
  decide which findings earn their own question. `Risks:`/`Gaps:` items are
  decision-level context — they are never auto-folded and never verdicted;
  they surface with the report, not in Step 7's digest or batch.
- Word cap: `Cap your reply at 600 words; the exact location + replacement
  text of MECHANICAL fixes does not count toward the cap.` (A tighter cap
  truncates the fixes, which demotes them at Step 7 and hollows out the
  auto-fold.)

### Reviewer — consistency (spec-kit-`analyze`-style)

A distinct contract: a structured, severity-tagged consistency analysis rather
than the prose block. `description: "Review plan: consistency"`. Its `prompt`
must contain:

1. `Act as a spec-consistency analyzer. You analyze the plan (and its related planning artifacts) for internal and cross-artifact consistency. You are NOT implementing it, and NOT judging whether the approach is good.`
2. The primary plan path with `Read this file first.`, then the related-artifact
   list from Step 1 (other plans' `plan.md`s — each labeled `path — state — critical
   files it touches` — the primary plan's zooms at `$zoom_dir/*.html`, the resolved
   constitution `$const_path`) with `Full-read a plan when its Critical files overlap
   the primary's, or its topic is adjacent. For a non-group plan with no file overlap
   whose state is 'implemented' or 'superseded', the name+state+files line is enough —
   read it in full only if that line suggests overlap. Never skip a plan in the
   primary's split group, regardless of its state.`
3. **Lane guard:** `Judge only coherence, traceability, and agreement — not feasibility, requirement coverage vs reality, or design cleanliness. If a finding is really one of those, DROP it; another reviewer owns it. One bounded exception: you MAY grep the repo to check a count the plan states about itself (the count-mismatch category below), the same way the Critical-files check already reads the repo. That is the plan's own arithmetic, not a judgment about the requirement.`
   Plus one cycle-scoped exclusion: `Ignore zoom html staleness relative to
   plan edits made in this review cycle — the plan was just revised and its
   zooms lag by construction; the closing report owns the re-zoom reminder.
   Flag orphan/stale-artifact only when the mismatch predates this review.`
   Plus one lane clarification for the recommend criterion in the Step 6
   tagging contract: naming a recommended resolution is still a choice made
   inside coherence, traceability, and agreement — it is never license to
   also judge feasibility, requirement coverage vs reality, or design
   cleanliness; those stay the other reviewers' lanes.
4. **Method:** `Inventory (a) the needs stated in Context, (b) the numbered Use case scenarios incl. edge cases, (c) the Implementation steps, (d) the Critical files. Then run the detection passes across sections — and across artifacts when more than one is related.`
5. **Detection categories:**
   - `coverage-gap` — a scenario/requirement/edge case with no implementation
     step; a step tracing to no stated need; Verification not exercising a
     scenario; Critical files mismatch (listed-but-unused, or touched-but-unlisted);
     `count-mismatch` — the plan states a count of its own change surface ("five
     call sites", "3 handlers"): sweep the named identifier with
     `bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" sweep '<identifier>' --roots repo`
     and reconcile the **whole** result set against the plan's list, since confirming
     each listed site cannot reveal the ones nobody listed. Use that subcommand rather
     than composing a recursive `grep`: recursion is what makes grep apply `.gitignore`,
     which silently drops every hit under `.mentor/`, and the `SWEEP:` line's `files=`
     count is what lets you tell a real undercount apart from a search that read nothing
     (exit 2). Report the command run,
     plan-count vs found-count, and the `file:line` hits, so the user verdicts at
     a glance; an
     undercount usually means missing steps, not just a stale numeral, which is why
     `coverage-gap` stays DECISION-REQUIRED rather than auto-folding a new number in;
     an `## Implementation steps` section carrying none of `[role:` dispatch
     annotations, `[delegated:` annotations, or a `Dispatch: skipped —`
     opening line (plans are dispatch-annotated by default — a plan with none
     of the three made no explicit choice);
     a `Dispatch: skipped —` line whose stated reason matches neither of
     `dispatch-agents`' two sanctioned escape-hatch branches (**Trivial**: roughly
     ≤ ~20 changed lines with nothing new to read; **Interactive**: needs tight
     mid-implementation back-and-forth) — an unsanctioned reason is an unreviewed
     skip wearing a disclosed one;
     a missing or empty `## Verification` section, or one whose topics don't carry
     the `Topic N —` / `Focus:` / `Checks:` / `Pass when:` structure (execution
     dispatches one fresh verifier per topic — free-form prose or a malformed
     block can't be split that way).
   - `contradiction` — sections that disagree; step ordering vs a stated dependency.
   - `terminology-drift` — the same concept named differently across sections.
   - `ambiguity` — vague adjectives (fast/scalable/secure/simple) with no
     measurable criteria; unresolved placeholders (TBD/TODO/`<...>`).
   - `underspecification` — a step with a verb but no object/outcome; a scenario
     missing its expected behavior.
   - `duplication` — near-duplicate steps or requirements.
   - **cross-artifact (only when >1 related artifact is read):**
     `cross-contradiction` (two artifacts conflict), `cross-drift` (same concept,
     different term across artifacts), `cross-overlap` (two plans describe the
     same work), `dangling-reference` (references a section/artifact that doesn't
     exist), `orphan/stale-artifact` (an `.html` zoom out of sync with the `.md`).
6. **Tagging:** the tagging contract above, plus the category defaults:
   `Category defaults: terminology-drift, duplication, dangling-reference, and
   pure-wording ambiguity are usually MECHANICAL; contradiction, coverage-gap,
   underspecification, every cross-* category, and constitution violations are
   DECISION-REQUIRED. The in-doubt rule overrides these defaults.`
7. **Severity:** `CRITICAL` (a coverage gap blocking the core requirement, a
   cross-artifact contradiction, or a constitution MUST violation) / `HIGH` /
   `MEDIUM` / `LOW`. High-signal only; cap at ~15 findings. The `Fix` column's
   location + replacement text is exempt from any length pressure — a
   MECHANICAL fix without its exact edit gets demoted at Step 7.
8. **Required structured output** (the tables carry the content — keep prose minimal):
   ```
   Consistency findings
   | ID | Tag | Category | Severity | Location(s) | Summary | Fix |
   | --- | --- | --- | --- | --- | --- | --- |

   Coverage map
   | Requirement / scenario | Covered by step (which artifact)? | Notes |
   | --- | --- | --- |

   Metrics: <N scenarios> · <req coverage %> · <artifacts checked> · <critical count>
   ```
   For a DECISION-REQUIRED finding, the `Fix` column carries the recommended
   resolution and its one-line why — or, on a declared toss-up, says so and
   names why no side is preferred — the same content Step 7's digest, walk,
   and batch question surface as the recommended resolution.
9. Read-only + anti-recursion: `Do not edit any file. Do not invoke /plan-review or any planning skill.`
10. **Constitution (conditional):** if the resolved constitution `$const_path`
    exists (Step 1), read it —
    a MUST-principle violation is a CRITICAL finding, and additionally verify the
    plan's `## Constitution Check` table is internally consistent (every principle
    has a row; every ⚠️ verdict has a resolving or explicitly-justified note).

## Step 7 — Auto-fold, severity-gated verdicts, and report

Partition the Stage 2 findings by tag — tagged findings only; the cleanliness
`Risks:`/`Gaps:` prose is context for the report, never a finding to verdict.
If no DECISION-REQUIRED finding survives the partition, skip the digest and
every verdict question and go straight from the MECHANICAL pass to the report.

**Apply** every MECHANICAL fix in ONE revision pass, re-writing the plan file
in place (`plan` Step 4). Guards:

- A finding tagged MECHANICAL without an exact location + replacement is
  misdeclared — demote it to DECISION-REQUIRED, never guess an edit.
- **Conflict rule:** when the two reviewers return overlapping or
  contradictory MECHANICAL fixes for the same text, consistency wins
  terminology, cleanliness wins structure and wording; if still ambiguous,
  demote both to DECISION-REQUIRED.
- Never apply a DECISION-REQUIRED finding in this pass — those choices go to
  the verdict questions below.
- **Apply the whole batch from one read** — never chain `Edit`s whose `old_string`
  another fix in the same pass just rewrote: that call fails on a string no longer
  in the file. Write the plan back once from the in-memory copy, or, for fixes that
  fall in disjoint blocks, use `plan` Step 4's whole-table/whole-fence replacement.
  Text no finding names comes back unchanged — this pass carries the findings' fixes,
  it does not re-draft. Same rule for Step 5's fold and the second pass below.

**Surface the digest.** Before asking anything, list every DECISION-REQUIRED
finding (demotions included) as one line each, CRITICAL → LOW: a 2–4 word
plain-language **handle** per Step 4's handle contract (compressed to
≤12 chars only when used as a question header; never the reviewer's table
ID — the user hasn't
memorized the table), the severity, a half-sentence of what it is, and the
recommended resolution in a few words (or "toss-up" when the reviewer
declared no recommendation). This is the map the walk used to lack — questions arrived
cold, one dense case at a time, with no way to see how many were coming or
which ones mattered. A severity the reviewer stamped stands — never re-grade
a stamped finding. Only a finding that arrived without one (demotions
usually do) needs a grade: MEDIUM, unless its content meets a CRITICAL
definition — blocks the core requirement, cross-artifact contradiction,
constitution MUST violation, or (cleanliness lane) plan unbuildable /
acceptance unverifiable as written — which makes it CRITICAL.

**Walk the CRITICAL findings**, one at a time — and ONLY the CRITICAL ones,
unless the batch question below routes its findings back here — under
Step 4's per-question *writing* contract — self-containment included: one
`AskUserQuestion` call
per finding, exactly one single-select question, the finding's handle as
header, a `(<k> of <n>)` prefix where `n` counts only the findings being
individually walked (never the whole DECISION-REQUIRED set — a 2-question
walk must not read as a 14-question one), and the question text opening with
one plain sentence naming the
decision being asked, then the reviewer's case in 2–4 sentences with the
**key words bolded** — what disagrees or is missing, **where** (quote or
describe the plan text in place; a bare `Location(s)` cell like
"§Verification" or "Step 3" must be translated into what that part of the
plan says), and what each resolution costs. Step 4's exact-4/exact-2
option-shape check stays in Step 4 — this walk's option count varies with
the alternatives each finding carries, so a 3-option question here is
well-formed, not malformed. The gate is narrowed to CRITICAL
deliberately: a CRITICAL finding blocks the core requirement, contradicts a
sibling artifact, or violates a constitution MUST — each one is worth its own
question. Below that, a per-question walk taxes the user more than the
decisions are worth (a 21-step plan once produced twelve dense questions and
half an hour of answering), and the digest plus the batch question below keep
every choice the user's at a fraction of the cost. The options come from the
finding itself:

- One option per substantive alternative the reviewer stated, ordered with
  the reviewer's recommended resolution **first** — per the Step 6 tagging
  contract the reviewer already named the one that is the most practical and
  clean solution, never trading maintainability or reliability for
  implementation speed — and that option's label carries `(Recommended)`,
  with its description opening on the reviewer's one-line why before it says
  what changes in the plan and what it risks (attach a `preview` of the
  concrete text when the reviewer gave one). When the reviewer declared a
  genuine toss-up and omitted a recommendation (the Step 6 carve-out), present
  the alternatives unled — no option gets `(Recommended)`. A question holds
  at most 4 options, so cap the alternatives at two — the strongest per the
  reviewer — and when more exist, say in the question text that the rest are
  reachable via "Other" by name.
- `"Leave open"` — keep the plan as-is; the finding is recorded in the report.
- `"Skip the rest"` — leave this and every remaining finding open — the rest
  of the walk AND the batched findings below — and go to the report. (Offer
  only while more findings remain beyond this one, batched ones included.)

Before building each question, re-count what actually remains — the
same drift a long walk invites in Step 4's fold gate reaches this walk too,
so check the count rather than carrying the last question's shape forward.

**Batch the rest.** After the walk — or immediately, when nothing is
CRITICAL — resolve every remaining finding in ONE single-select question
rather than one each. The question text restates each remaining finding as
its own line, HIGH → LOW: `**handle** (severity) — half-line summary → its
recommended resolution in a few words` (or `toss-up`). The list IS the
question's substance — the user verdicts from the question screen alone, and
the digest may have scrolled away, so the lines live here, never as a pointer
back to it. Header `"Remaining <N>"`, options:

  1. "Apply all recommendations (Recommended)" — description: applies each
     listed finding's recommended resolution in one pass; if any listed
     finding is a toss-up, or a demoted MECHANICAL with no exact edit to
     apply, name it here as staying open — there is no recommendation to
     apply and guessing one is forbidden; it lands in the report's
     left-open group.
  2. "Leave all open" — description: change nothing; every listed finding is
     recorded in the report as an open finding.
  3. "Walk them one by one" — description: the full per-question walk over
     these findings, severity order, for when the list shows calls the user
     wants to weigh individually.

On "Walk them one by one", run the walk above over the batched findings —
same writing contract, same `Leave open` / `Skip the rest` options on the
same count rule, `n` now counting these findings, and the free-text
bulk-accept applies here too. That walk ends at the report; it never
re-batches. An "Other" answer carries mixed verdicts ("apply the first two,
leave the
rest") — map it by handle and confirm the span before applying. Marking the
bulk option `(Recommended)` here is deliberate, and deliberately different
from Step 4's never-recommend-bulk rule: there, one-edit-at-a-time IS the
gate's design, so nudging toward bulk would hollow it out; here the batch is
the design below CRITICAL, and every listed recommendation is one the
reviewer already named as the most practical and clean resolution. Two edge
cases collapse the batch: exactly one remaining finding gets a normal
per-finding question instead of a one-line list, and a remainder that is all
toss-ups skips straight to the walk — the lead option would cover nothing,
and a declared toss-up is precisely the finding that needs individual
judgment.

**Free-text bulk-accept.** If the user free-types a bulk instruction during
the CRITICAL walk ("accept the rest", "take all the recommendations"), map it
onto the remaining walk findings' recommendations plus the batch's
"Apply all recommendations". Before applying, state by handle what that
covers — toss-ups excluded: they stay open, exactly as the batch's "Apply
all recommendations" would leave them — and confirm
the span, since answered findings are behind you and "all" may mean the
remainder or the whole set.

The recommendation only shapes how the options are **presented** — ordered,
labeled — never whether one is **applied**: nothing here is folded until the
user verdicts it, the same guarantee that holds for every DECISION-REQUIRED
finding, batched ones included. Apply the accepted resolutions — walked and
batched — in ONE second revision pass once every verdict is in — these are
user verdicts, not auto-folds.

**Report** three groups, naming every entry by its handle plus a one-line
summary — never a bare code: **applied** (MECHANICAL fixes and
verdict-accepted resolutions), **left open** (findings the user left open or
skipped, plus the consistency reviewer's coverage map + metrics as-is), and
**dead lanes** (if any reviewer died). If the Step 5 fold or either Step 7
pass touched content covered by an existing `$zoom_dir/*.html`, add a reminder
that those zooms need re-dispatch — re-zooming is `mentor:zooming`'s re-zoom rule
(entered via `plan` Step 5's delegation), never done from inside this skill.

Then return to the approval question when invoked from `plan` Step 6. When
invoked standalone, show the report first — always, even when the underlying
goal was "just get approval", and a resumed session re-asking an interrupted
approval is still standalone. It is the only place the
applied/left-open/dead-lane summary ever reaches the user.

If that standalone caller's goal is to obtain (or re-obtain) plan approval,
route it to `plan` Step 6 (`{#approve}`) rather than hand-rolling a question:
that block owns the `plan-state.sh context` re-check, the full option table
including "Hand off to next agent", and the "only a returned answer approves"
rule for re-asking an interrupted one — a freshly-invented option set drops
all three silently. Invoke `Skill(skill="mentor:planning")` first (standalone,
it usually is not loaded) and run its Step 0 armed-gate check before entering
Step 6: a resumed session's marker is often `STALE`, `RELEASED`, or
`ARMED_ELSEWHERE` (armed in a different worktree — this worktree isn't blocked,
but the plan may need re-owning via `/mentor:plan <slug>` before it can be
approved here), and `approve-plan.sh` on a missing marker reports success while
approving and promoting nothing. Control passes there — the "do not run
`approve-plan.sh`" rule below binds this skill, not the one you handed off to.

## Stage-2-only mode

Entered by a direct consistency ask ("check plan consistency", "consistency
review") or the "Stage 2 only" gate choice (see When to use / Step 2). Ensure
Step 1 has run — it is the shared prerequisite of every mode — then skip
Steps 3–5 and run Steps 6–7 against the plan as it stands, including the
auto-fold.

**Write confirm on the direct-ask path:** a bare "check plan consistency" was
previously read-only, so when this mode is entered by trigger phrase (not the
Step 2 gate choice, whose description already announces the auto-fold), ask
one single-select question before Step 7 writes anything — header
"Auto-fold", options "Apply safe fixes (Recommended)" / "Surface only". On
"Surface only", run Step 7's partition + digest + report but skip both writes
AND every verdict question — walk and batch alike — the user asked to see,
not to change.

**Only this session's live gate choice is exempt.** The carve-out above is for
the Step 2 gate choice specifically — a choice made *now*, by *this* session's
user, from a description that announced the auto-fold. Every other entry into
this mode asks the write-confirm, including a `Skill()` call whose args were
pre-baked by a prior session's handoff note ("auto-fold explicitly authorized
in the note") — the shape `resuming` Step 6 produces when a note names
`mentor:plan-review`. A stale note cannot stand in for a live verdict, and
resuming's "invoke the command exactly as the note states" bound limits
*scope*; it is never licence to skip the invoked skill's own gates.

### Do NOT

- Do **not** run `approve-plan.sh` from inside this skill — review never releases the gate.
- Plan-file writes from inside this skill are limited to exactly two moments — Step 5 (the user's per-edit fold verdicts) and Step 7 (the MECHANICAL auto-fold pass plus the user's verdicts, walked and batched). Never apply an edit or resolution the user did not explicitly accept, never touch zoom artifacts or repo source files, and always follow `plan` Step 4's re-write-in-place rule.
- Do **not** detect domains or ask the user to select topics — the review topics are fixed (see the dimension table above).
