---
name: plan-track
description: |
  Show which EXISTING mentor plans have been implemented and which are still
  unbuilt, then build the next unbuilt one. Backs the /mentor:track command. Use this
  whenever the user asks what plans exist, which plan to build next, what is left to
  build, whether a plan has already been implemented, or asks to implement / pick up /
  retry a plan by name or number — and especially after /plan-split has left a group
  of sibling plans to work through one session at a time. It reads each plan's
  lifecycle state (draft / approved / in progress / implemented / failed), refuses to
  start an implementation when this session's context is already too large to finish
  one reliably, and executes the chosen plan through mentor:dispatch-agents.
  This is about build status, not about authoring a plan for a new request (that is
  /mentor:plan) or judging a plan's quality (that is /plan-review).
---

# Plan Track — What's Built, What's Next, Build It

`mentor:plan` writes plans; this skill is how you come back to them. Each plan dir
carries a `.state.json` sidecar recording where it stands, so a fresh session can
answer "which of these five is next?" without re-reading five plans and guessing.

The state you act on is the **effective** state: the more advanced of what the sidecar
says and what the plan's `✅` step ticks show. That means a forgotten state write
costs nothing — the ticks `mentor:dispatch-agents` already writes keep the picture
honest on their own.

## When to use

- "What plans do I have?" / "what's left?" / "which one is next?" / "did we finish X?"
- "Implement the next plan" / "pick up plan 2" / "retry the one that failed."
- Any fresh session continuing a `/plan-split` group.

## When NOT to use

- **Authoring a plan for a new ask** — that is `/mentor:plan`.
- **One plan is too big** — that is `/plan-split`.
- **Auditing a plan's quality before approving it** — that is `/plan-review`.
- **Resuming a *session* from a handoff note** — that is `/mentor:resume`. Handoff
  notes carry conversation context; this skill carries plan state. If the user wants
  "where were we", they want `/mentor:resume`; if they want "what's built", they want
  this.

---

## Step 0 — Check the context before doing anything else

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" context
```

This is load-bearing, not a formality. `context-gate.sh` lets **every** slash-prefixed
prompt through, and `begin-plan.sh`'s check only runs for `/mentor:plan` — so without
this check `/mentor:track` could launch a full implementation in a session already too
large to finish it, and the work would degrade partway through with no warning.

The tiers match the rest of the plugin exactly, which matters: being *stricter* than
the gate — refusing someone who already chose to keep going — is as much a bug as
having no check at all.

- **`CONTEXT: ASK`** — do not dispatch yet. Ask the user the two-option question the
  script prints (hand off, or bypass for this session) and follow their answer.
  Listing is still fine; only building waits.
- **`CONTEXT: HANDOFF`** — they already chose to continue. Proceed, but build **one**
  plan and hand off before the next.
- **`CONTEXT: WARN`** — surface it, then continue. Recommend a fresh session before
  starting the *next* plan.
- **`CONTEXT: OK` / `UNKNOWN`** — continue.

## Step 1 — List the plans

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" list
```

Show the table as-is. It groups split siblings together, orders them by their `order`
field, and sorts `superseded` and `unknown` last. Plan files live at
`PLANS_DIR/<PLAN>/plan.md`.

If the script reports **no git repo**, say that plainly in one line — mentor keeps no
plan registry outside a repo. Printing an empty list next to plan files the user can
see would just be confusing.

If `$ARGUMENTS` is `status`, stop here — the user asked to look, not to build.

## Step 2 — Select a plan

Resolve the selection using **`mentor:resume` Step 4's rule, unchanged**: a bare
integer is a 1-based ordinal into the printed list; anything else is a
case-insensitive substring match on the slug; a unique match is selected directly; an
ambiguous or empty match re-prints the list and re-asks rather than auto-picking; with
no argument, `AskUserQuestion` offers the 4 most relevant plans and "Other" covers the
rest.

"Most relevant" here means the ones the user can act on: unfinished plans first, in
group and `order` sequence. Do not offer `superseded` parents as quick options — they
were replaced by their children.

## Step 3 — Act on the plan's effective state

| Effective state | What to do |
|---|---|
| `approved` | Set `in_progress`, then execute (below). |
| `failed` | Show the sidecar's note — it says what broke last time — then set `in_progress` and retry, feeding that note to the first agent. |
| `in_progress` | An interrupted run. Re-enter execution **from the first unticked step**; never restart from step 1. |
| `implemented` | Say so and offer another. Do not rebuild it. |
| `draft` | **Refuse to execute.** The approval gate never released this plan. Point the user at `/mentor:plan`'s approval step. In a fresh session there is no `.planning` marker, so `plan-gate.sh` would happily allow the edits — this refusal is what keeps that from becoming a hole in the gate. |
| `unknown` | A pre-2.4.0 plan with nothing on record. Never show the approval pointer — it would be false for a plan that shipped months ago. Offer: mark it implemented, or leave it alone. |

To move state:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" set <slug> <state> [--note "…"]
```

**Executing** — invoke `Skill(skill="mentor:dispatch-agents")` and follow its
"Executing the dispatches" section as written. Two things are specific to arriving
here rather than straight from `mentor:plan`:

- On an `in_progress` plan, start at the **first unticked step**. The plan's `✅` marks
  are the record of a run that was interrupted; re-running ticked steps is the failure
  mode this whole skill exists to prevent.
- When the plan is a **split child**, pass its isolation header into every
  implementation agent's prompt, so the sibling boundary travels with the work.

## Step 4 — Close out

When every `Done when:` has passed, `set <slug> implemented`. When the remediation
re-dispatch has failed and you are escalating to the user, `set <slug> failed --note
"<what broke>"` — the note is what makes the retry cheap next time.

Then report what is left (`list` again is enough) and, if the group has more plans,
recommend a **fresh session** for the next one: a plan that just consumed a full
implementation pass has left little room for another.

## Done when

- The context check ran before any dispatch.
- The user saw real state, not a guess.
- The selected plan was resolved unambiguously, never auto-picked.
- A `draft` plan was refused; an `implemented` one was not rebuilt.
- The plan that ran ended at `implemented` or at `failed` with a note.

### Do NOT

- Do **not** dispatch implementation on `CONTEXT: ASK` before the user has answered —
  and do **not** refuse them on `CONTEXT: HANDOFF`, which means they already did.
- Do **not** execute a `draft` plan, however open the gate happens to be.
- Do **not** arm or release the edit gate — only `mentor:plan` does that.
- Do **not** restate the dispatch grammar or the selection rule here; cite
  `mentor:dispatch-agents` and `mentor:resume` Step 4. A second copy is a second thing
  to keep true.
- Do **not** hand-edit `.state.json` — `plan-state.sh` is the only writer.
