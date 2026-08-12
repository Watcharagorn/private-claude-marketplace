---
name: deferring
description: >
  Capture work discovered mid-flow — during planning OR implementation — as one or more
  lightweight deferred plan stubs, without derailing the current task. Backs the
  /mentor:defer command, but also triggers conversationally any time the user wants
  something noted for later instead of acted on now: "stash this for later", "defer
  this", "stash these for later: X; Y", "let's not do this now, park it", "add that to
  the backlog", "note that and keep going", "circle back to this later". Accepts one
  item or many in a single call. Each item becomes an ordinary plan directory under
  .mentor/plans/, named for its own slug — same shape as a real plan, just born small
  and marked draft + origin "deferred" — so overview, the approval sweep, and
  /mentor:track already know
  how to handle it. This is capture only: it never plans,
  approves, or implements — that comes later via /mentor:plan (which claims the stub)
  or /mentor:track (which surveys and routes it). Refuses check-shaped items — only
  isolated work to build is captured.
---

# Defer — Stash Work for Later

A `git stash`-like capture for future work. Something surfaces that is real but not what you're
doing right now — a typo worth fixing someday, a refactor idea, a feature the user mentions in
passing while you're mid-plan or mid-implementation. Without this skill that observation lives only
in the conversation and disappears at session end, or it derails the current task while you go
write it up properly. This skill writes it down as a real (if small) plan and hands control right
back.

## When to use

- Mid-planning or mid-implementation, work surfaces that is NOT this task's scope.
- The user says "stash this/these for later", "defer this", "park that", "note it and keep going" —
  or anything with that shape, however phrased.
- One item, or several named in the same breath ("stash these for later: fix the gate message
  typo; also an OAuth refactor").

## When NOT to use

- The work IS this session's scope — just do it, or fold it into the plan already being written.
- **It's a check, not work to build.** A deferred stub names work to build, never a check to run: it
  captures an isolated feature, function, fix, or improvement — something that ships on its own. It
  never captures testing or verification of the *current plan's* own work, because checks belong to
  the plan that made the claims. An unresolvable verification topic ends
  `plan-state.sh set <slug> failed --note "<why>"`, which keeps the retry cheap — never a backlog
  stub that lets the plan close clean while its own claims stay unverified.

  Two nuances keep this honest:

  - **Fix vs check.** When a check *ran* and confirmed a defect, deferring the *fix* is legitimate —
    that's isolated work. Deferring the *check itself* is not.
  - **Ownership of the claim, not the word "test".** A check on *this* plan's own work is never
    deferrable. But a *pre-existing* defect — a flaky test on the base branch, a CI job that was
    already broken before this work began — discovered incidentally is ordinary work to build, and
    deferring its *fix* is exactly what `/mentor:defer` is for.

  Worked examples:

  - Mid-merge, a test on the base branch turns out to have been flaky for weeks → legitimate
    fix-stub: `deferred → fix-flaky-auth-test [med · fix] (.mentor/plans/fix-flaky-auth-test/)`.
  - "Let's verify topic 2 later" (a verification topic with no staging environment available) →
    refused. Point it back at the plan's own record instead:
    `plan-state.sh set <slug> failed --note "Topic 2 unresolved — no staging env"`. If that check
    had *already run* and confirmed a defect the user chooses not to fix now, the fix is deferrable:
    `deferred → fix-empty-input-handling [high · fix] (.mentor/plans/fix-empty-input-handling/)`.
- The user wants to browse or act on stubs that already exist — that's `/mentor:track` ("what's
  remaining?"), which routes a picked stub through `/mentor:plan` + `claim`. This skill only
  creates; it never lists or picks up.
- The item is so trivial that nobody will ever need to come back to it — just say so in this
  response and move on; a stub is only worth the disk space if a future session might act on it.

## Step 1 — Parse the items

From `$ARGUMENTS` or the conversational ask, split into one or more distinct items of future work.
Accept whatever separators the user gave — semicolons, a bullet list, "and" — never make them
reformat a list they already gave you in prose.

For each item, work out (from what's already known — no research needed, this is capture, not
planning):

- a short title and one or two sentences of what "done" would look like,
- **why it's deferred right now** — scope, timing, priority, whatever the conversation makes
  obvious,
- optionally, which other plan or stub it depends on, if the user said so or it's evident (e.g.
  "after the gate typo fix lands"),
- **priority tier** — judge it from the conversation's own signal: severity words ("fragile",
  "broken"), the user's emphasis, or a stated impact. Leave it unset when the conversation gives no
  signal — never invent a default just to fill the field. Whatever you judge gets reported in Step 3
  so the user can correct it with one word,
- **category** — one of the closed vocabulary `feature | fix | refactor | docs | tooling`, picked
  from what the item itself obviously is. Leave it unset if nothing fits cleanly,
- **source plan** — the slug of the plan flow being interrupted, when there is one, so the stub
  records where it came from. Leave it out entirely for a conversational capture that isn't
  interrupting any plan flow.

**Scope check, one line, then keep moving:** is this item work to build, or a check to run? Only
work to build is deferrable — see "When NOT to use" below for the full rule, the fix-vs-check
nuance, and worked examples. Judge it from what's already in the conversation; never research it or
stall the interrupted flow to decide.

## Step 2 — Create a stub per item

For each item, in order (an earlier item's slug is a valid `--deps` target for a later one in the
same batch — the stub exists on disk by the time you get there):

1. **Derive a slug** — kebab-case, ≤30 chars, drop articles, keep nouns/verbs (same convention as
   `mentor:planning` Step 4). If it would collide with an existing plan dir that is about something
   else, add a short disambiguator rather than silently overwriting someone else's plan.

2. **Compute and create the plan dir:**

   ```bash
   plans_dir="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" dir --plans)"
   [ -n "$plans_dir" ] || { echo "ERROR: mentor plans dir unresolved — is CLAUDE_PLUGIN_ROOT set?" >&2; exit 1; }
   plan_dir="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" ensure-dir "$plans_dir/$slug")" || exit 1
   echo "${plan_dir}/plan.md"
   ```

3. **Write the stub** with the `Write` tool — exactly these four sections, nothing more:

   ```markdown
   # <Title>

   ## Goal
   <one or two sentences — what "done" looks like once this is picked up>

   ## Context
   <why this surfaced now, and where — the session or plan it was deferred out of>

   ## Why deferred
   <why NOT now — scope, timing, priority>

   ## Suggested first steps
   <a short bullet list — enough for a future /mentor:plan session to start research,
   not a full implementation plan>
   ```

   **No "Relations" section.** Any dependency this item has on another plan or stub lives ONLY in
   the sidecar `deps` field set in the next command — never restate it in the stub's prose. A fact
   with two homes is a fact that can go stale in one of them; the sidecar is the single owner.

4. **Register it:**

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" init "$slug" --deferred${deps:+ --deps "$deps"}${priority:+ --priority "$priority"}${category:+ --category "$category"}${from_plan:+ --from "$from_plan"}
   ```

   `--deferred` sets the sidecar's `origin: "deferred"` — the marker that (a) shields this stub
   from `approve-plan.sh`'s promotion sweep, so it doesn't get swept into `approved` alongside
   whatever real plan is being approved around it, and (b) is what `/mentor:track`'s pick-up flow
   and its draft-approval escape hatch check before they'll treat this as a buildable plan. `--deps`
   is a comma-separated list of plan slugs — existing or not-yet-created (`overview` marks an
   unknown one `missing` rather than failing); pass it only when a dependency is actually known now.
   `--priority`, `--category`, and `--from` carry Step 1's judgment onto the sidecar — each flag is
   passed only when that field was actually judged or known; an unjudged field is simply omitted
   from the command, never sent as an empty or invented value.

This runs exactly the same whether the edit gate is armed or open: `.mentor/` is gate-exempt, so
`plan-gate.sh` never blocks these writes. Deferring mid-`/mentor:plan` (gate armed, read-only
everywhere else) and deferring mid-implementation (gate already released) both just work, with no
special-casing.

## Step 3 — Report and return

One line per stub created, in the order they were made, carrying whatever Step 1 judged:

```
deferred → fix-flaky-auth-test [med · fix]  (.mentor/plans/fix-flaky-auth-test/) — from: merge-oauth-refactor
deferred → oauth-refactor      [feat]       (.mentor/plans/oauth-refactor/) — deps: fix-gate-msg-typo
deferred → fix-gate-msg-typo                (.mentor/plans/fix-gate-msg-typo/)
```

The `[<tier> · <cat>]` tag, the `from: <plan>` clause, and the `deps: <a>` clause each render **only
when that field was actually judged or given** — an unjudged field is dropped from the line
entirely, never shown as an invented placeholder. When only one of tier/category was judged, show
that one word alone in brackets (as `oauth-refactor` does above); the bracket never renders both
sides blank, e.g. `[– · –]` must never appear.

Then **continue exactly where the interrupted flow left off.** Deferring is a side note in the
middle of the current task, not a reason to end the turn, ask a follow-up question, or wait for
acknowledgement — the whole point is that the current task never stalls for this.

## Done when

- Every item became its own plan dir with a stub `plan.md` and a sidecar carrying
  `origin: "deferred"`, plus whatever `priority` / `category` / `deferred_from` Step 1 judged.
- No stub's `plan.md` contains a "Relations" section — deps live only in the sidecar.
- Every item passed the scope check — no stub was created for a check on the current plan's own
  work; a refused item was pointed back at that plan's own Verification record instead.
- The user saw one line per stub, with its path, its judged tag(s) (when any), `from:` (when
  known), and `deps:` (when set) — never an invented placeholder.
- The interrupted flow continued in the same response.

### Do NOT

- Do NOT write a "Relations" section, or restate `deps` in the stub's prose — the sidecar is the
  one owner of that fact.
- Do NOT flesh a stub into a full plan here — that's `/mentor:plan`'s job when the stub is later
  picked up (it runs `claim` on it then).
- Do NOT stop and wait after creating the stubs — return to the interrupted work.
- Do NOT hand-edit `.state.json` — `plan-state.sh init` is the only writer.
- Do NOT invent a priority or category when the conversation gives no signal — leave the field
  unset rather than guess.
- Do NOT create a stub for testing or verification of the current plan's own work — that names work
  to build, never a check to run; route it to the plan's own Verification record
  (`plan-state.sh set <slug> failed --note "<why>"`) instead.
