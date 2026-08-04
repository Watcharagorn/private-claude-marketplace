---
name: plan-track
description: |
  Show the repo-wide remaining-work hierarchy — every mentor plan's lifecycle state,
  its step progress, cross-plan deps, deferred /mentor:defer stubs, and live handoffs —
  then build the next unbuilt plan. Backs /mentor:track. Use whenever the user asks
  what plans exist, what's remaining, what's left to build, remaining tasks, which plan
  is next, whether a plan is already implemented, or asks to implement / pick up /
  retry a plan by name or number — especially after /plan-split, or after
  /mentor:defer has stashed stubs to survey. Reads each plan's lifecycle state, refuses
  to start when context is too large, warns (never blocks) on unmet deps, routes a
  deferred stub to /mentor:plan for claiming instead of building it directly, and
  executes via mentor:dispatch-agents.
  About build status, not authoring a new request (/mentor:plan), capturing mid-flow
  work (/mentor:defer), or judging plan quality (/plan-review).
---

# Plan Track — What's Built, What's Next, Build It

`mentor:planning` writes plans; this skill is how you come back to them. Each plan dir
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
- **Capturing new work discovered mid-flow** — that is `/mentor:defer`. It writes the stub; this
  skill only reads what already exists (via `overview`) and, when the user picks a stub, routes
  them to `/mentor:plan` to flesh it out.
- **Auditing a plan's quality before approving it** — that is `/plan-review`.
- **Resuming a *session* from a handoff note** — that is `/mentor:resume`. Handoff
  notes carry conversation context; this skill carries plan state. If the user wants
  "where were we", they want `/mentor:resume`; if they want "what's built", they want
  this.
- **Adopting a plan authored outside mentor** — native plan mode, a colleague's doc.
  It has no state record and no dispatch annotations, so there is nothing here to
  list or execute. Re-run `/mentor:plan` with that plan pasted as the task statement;
  research is short because the decisions are already made, and it comes out the far
  side as a real plan. Do not register it by hand: `approved` means the gate ran, and
  a plan with no `[role:` annotations and no `Dispatch: skipped —` line gives
  `mentor:dispatch-agents` nothing to execute. This holds for a **static** artifact —
  unless another framework still owns planning for this work (spec-kit and the like),
  in which case there is nothing for mentor to adopt: point at that framework's own
  next command, because a second plan of record competes with the live one.

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

## Step 1 — See the hierarchy

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" overview --json
```

This is the ONE call that answers "what's remaining?" — a JSON array covering every plan dir with
a `plan.md` (slug, effective state, group, order, `deps` — each marked `missing` when no such plan
dir exists, `origin`, live handoffs, `✅` step counts), plus topic dirs holding a live handoff but
no plan yet, plus the legacy flat `.mentor/handoffs/*.md` dir. It replaces the old `list` table —
`list` still exists and is byte-compatible, but `overview` is the only call that also carries deps,
origin, and step counts, so it is Step 1 now. Whenever it prints anything, that output is valid JSON
(`jq .` parses it); see the hook script's header comment for the exact per-entry shape
(`kind: "plan" | "no_plan_topic" | "legacy_handoffs"`). Plan files live at `PLANS_DIR/<PLAN>/plan.md`.

**It can also print nothing at all** — stdout empty, exit 0, one stderr line saying which case it
hit: **no git repo** (mentor keeps no plan registry outside a repo), or **no `.mentor/plans` dir
yet** (nothing has ever been planned here). Don't feed that to `jq` and don't render an empty
hierarchy — say it in one line and stop. Say what the emptiness means and no more: mentor tracks
only its own plans, so "no mentor plans in this repo" is never a claim that the repo has no work
in flight — planning may simply live somewhere else.

If `$ARGUMENTS` is `status`, render the hierarchy below and stop — the user asked to look, not to
build.

### Render it as a hierarchy, not a flat dump

Use a distinct glyph/label per resource **kind** — a plan, a deferred stub, and a handoff must
never read as the same kind of thing at a glance:

| Glyph | Meaning (a bucket — the state word printed after the slug says exactly which) |
|---|---|
| `●` | `implemented` |
| `◐` | `in_progress` |
| `○` | `draft` or `approved` (not yet building) |
| `✕` | `failed` |
| `⊘` | `superseded` / `unknown` — render last, and only when the user is browsing everything |
| `▷` | `kind: "no_plan_topic"` — a topic with a live handoff but no plan yet |

Number **actionable** entries only (`kind: "plan"` or `"no_plan_topic"`) 1..N in render order —
group headers and `handoff:` sub-lines never consume a number, because that numbering is exactly
what Step 2's ordinal selection resolves against:

```
1. ● recommended-first-clean   implemented (3/3 steps)
2. ○ oauth-refactor            draft (deferred) — deps: fix-gate-msg-typo
3. ○ fix-gate-msg-typo         draft (deferred)
4. ◐ some-feature              in_progress (1/4 steps)
     └ handoff: 20260801-224510-implement.md (live)
```

Per plan entry: `<glyph> <slug>   <state>[ (deferred)] [(<ticked>/<total> steps)][ — deps: <a>[,
<b> (missing)]]`.

- `(deferred)` only when `origin == "deferred"` — the tag that marks an unclaimed `/mentor:defer`
  stub, so it is never mistaken for a plan someone drafted by hand and left in `draft`.
- step counts only when `steps.total > 0`.
- the `deps` clause only when `deps` is non-empty; a dep entry with `missing: true` gets
  ` (missing)` appended — named as a dependency, but no such plan dir exists yet.
- each entry's **live** handoffs (its `handoffs` array — `overview` already excludes `resolved/`)
  render as one indented line beneath it: `     └ handoff: <name> (live)`.

Split-group siblings (`group` set) stay contiguous, ordered by `order`; on the group's first
sibling, print a one-line header `▸ group: <group-slug>` and indent the members two spaces under
it — same grouping `list` sorted by, just rendered instead of tabulated.

`kind: "no_plan_topic"` entries use `▷` and the literal state text `no plan yet`, followed by their
`handoff:` line(s) — a topic that only has conversation history, never a plan.

`kind: "legacy_handoffs"` (topic-less, at most one entry) renders last if present:
`▽ (untracked) legacy handoffs: <name>, <name> — .mentor/handoffs/, no topic`.

Sort `kind: "plan"` entries the same way the old `list` table did: active states first
(`superseded`/`unknown` last), then by group (an ungrouped plan sorts on its own slug), then
`order`, then slug — so a reader who knew the old table still recognizes the order.

## Step 2 — Select a plan

Resolve the selection using **`mentor:resuming` Step 4's rule, unchanged**: a bare
integer is a 1-based ordinal into the printed hierarchy (actionable entries only, per Step 1's
numbering); anything else is a case-insensitive substring match on the slug; a unique match is
selected directly; an ambiguous or empty match re-prints the hierarchy and re-asks rather than
auto-picking; with no argument, `AskUserQuestion` offers the 4 most relevant plans and "Other"
covers the rest.

"Most relevant" here means the ones the user can act on: unfinished plans first, in group and
`order` sequence, deferred stubs included (their entry already says so). Do not offer
`superseded` parents as quick options — they were replaced by their children.

## Step 2.5 — Deps advisory (soft — never a block)

If the selected entry's `deps` array is non-empty, look up each dep's effective state in the same
`overview --json` output you already have (match by slug; a dep marked `missing` has no plan dir
at all). When any dep is not `implemented`:

- Say so plainly — name the unmet dep(s) and their current state (or "not yet planned" for a
  `missing` one).
- Recommend a build order: **deps first**, and `order` only as a tie-break within a `group` —
  `deps` and `group`/`order` are independent mechanisms by design, and there is no automated check
  for a contradiction between them, so this is advice, not a computed guarantee.
- **Never block on this.** If the user wants to proceed on the selected plan anyway, continue to
  Step 3 exactly as if the deps were clear.

No deps, or all deps already `implemented` → nothing to say; continue.

## Step 3 — Act on the plan's effective state

**A deferred stub short-circuits this step, first.** If the selected entry's `origin ==
"deferred"` (same `overview --json`), it is an unclaimed `/mentor:defer` stub — a
Goal/Context/Why-deferred skeleton, not a plan ready to build. Say so, then point the user at
`/mentor:plan <the stub's slug or its Goal>` to flesh it out — that skill runs `claim` on the stub
when it does, clearing `origin` so the normal approval sweep can pick it up afterward. Do not act
on the table below for a deferred stub, and do not offer to build it directly — that is exactly
the shortcut the `origin` shield exists to prevent.

Otherwise, act on the effective state:

| Effective state | What to do |
|---|---|
| `approved` | Set `in_progress`, then execute (below). |
| `failed` | Show the sidecar's note — it says what broke last time — then set `in_progress` and retry, feeding that note to the first agent. |
| `in_progress` | An interrupted run. Re-enter execution **from the first unticked step**; never restart from step 1. |
| `implemented` | Say so and offer another. Do not rebuild it. |
| `draft` | **Not buildable as it stands.** The approval gate never released this plan, and in a fresh session there is no `.planning` marker, so `plan-gate.sh` would happily allow the edits — this refusal is what keeps that from becoming a hole in the gate. There is exactly one authorized way through, on the user's explicit say-so: **"Approving a draft plan here"** below. |
| `unknown` | A pre-2.4.0 plan with nothing on record. Never show the approval pointer — it would be false for a plan that shipped months ago. Offer: mark it implemented, or leave it alone. |

To move state:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" set <slug> <state> [--note "…"]
```

### Approving a draft plan here

**Origin check, first.** Confirm `origin` for this slug (from Step 1's `overview --json`, or
re-run it if you no longer have it in hand). If it is `"deferred"` — arriving here any other way
than through Step 3's short-circuit above, e.g. the user jumped straight to "approve draft plan
X" — **refuse**: this is an unclaimed `/mentor:defer` stub, and approving it as-is would promote
a bare Goal/Context/Why-deferred skeleton straight to `approved`, skipping the planning this
escape hatch was never meant to skip. Point the user at `/mentor:plan <slug>` (which claims it)
and stop; do not ask the three-way question below for a deferred stub.

A plan arrives here still `draft` for one of two other reasons: the user approved it in an
earlier session but the approval was never recorded (pre-v2.14 `--handoff`/`--deliver`
didn't record one), or they never approved it and want to now. Both land in the same
place, so ask once with `AskUserQuestion` — approved earlier / approve it now / not yet
— and never infer the answer. Same test as `planning` Step 6: only a **returned answer**
approves. A prose claim ("I approved that one already, just build it") is the reason this
question exists, not a substitute for it — if the question was interrupted or rejected,
ask it again rather than reading the claim as consent. On "not yet", stop and point them
at `/mentor:plan`.

On either yes, move the state first:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" set <slug> approved --note "<which reason>"
```

That call is what makes this safe: it is slug-scoped, so it promotes the one plan the
user actually chose. Then check whether the gate is still armed — if
`.mentor/plans/.planning` exists, edits are still blocked and the state move alone will
not unblock them:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/approve-plan.sh"
```

It takes **no plan argument** — only `--handoff` or `--deliver`, which mean something
else — so passing a slug fails with `Unknown flag`. It also promotes every plan newer
than the marker, which is harmless when the marker is this session's and worth knowing
when it is not; the slug-scoped `set` above is what pins the intent to one plan. Run it
as a single command: a non-zero exit means the gate stayed **closed** and has to be
surfaced, never swallowed by a `||` fallback — a swallowed failure reads exactly like a
successful approval.

**Executing** — invoke `Skill(skill="mentor:dispatch-agents")` and follow its
"Executing the dispatches" section as written. Three things are specific to arriving
here rather than straight from `mentor:planning`:

- On an `in_progress` plan, start at the **first unticked step**. The plan's `✅` marks
  are the record of a run that was interrupted; re-running ticked steps is the failure
  mode this whole skill exists to prevent.
- When the plan is a **split child**, pass its isolation header into every
  implementation agent's prompt, so the sibling boundary travels with the work.
- When the plan states **`Dispatch: skipped`**, there are no agents to dispatch —
  implement in the main thread under `mentor:planning` Step 6's rule for that case, and keep
  everything around it (step ticks, `Done when:` verification, the **No busy-wait** rule
  from `mentor:dispatch-agents`, close-out) exactly as the dispatch path does it.
  Arriving here does not make that path unowned.

## Step 4 — Close out

When every `Done when:` has passed, `set <slug> implemented`. When the remediation
re-dispatch has failed and you are escalating to the user, `set <slug> failed --note
"<what broke>"` — the note is what makes the retry cheap next time.

Then report what is left (re-running Step 1's hierarchy is enough) and, if the group has more plans,
recommend a **fresh session** for the next one: a plan that just consumed a full
implementation pass has left little room for another.

## Done when

- The context check ran before any dispatch.
- The user saw real state, not a guess.
- The selected plan was resolved unambiguously, never auto-picked.
- A `draft` plan was either refused or approved by the user first — never silently
  built; an `implemented` one was not rebuilt.
- A deferred stub (`origin: "deferred"`) was routed to `/mentor:plan`, never built or approved
  directly — through Step 3's short-circuit AND through the draft-approval escape hatch's origin
  check, whichever path the user reached it by.
- Unmet deps on the selected plan were surfaced with a recommended order — and never used to
  block the user who chose to proceed anyway.
- The plan that ran ended at `implemented` or at `failed` with a note.

### Do NOT

- Do **not** dispatch implementation on `CONTEXT: ASK` before the user has answered —
  and do **not** refuse them on `CONTEXT: HANDOFF`, which means they already did.
- Do **not** execute a plan that is still `draft`, however open the gate happens to be —
  approve it through the step above first, or stop.
- Do **not** build or approve a deferred stub directly, however the user phrases the ask — point
  at `/mentor:plan <slug>` every time; only `claim` (run by that skill) lifts the shield.
- Do **not** hard-block on unmet deps — Step 2.5 is advisory; the decision to proceed anyway is
  the user's.
- Do **not** **arm** the edit gate, and release it only through "Approving a draft plan
  here", on the user's explicit say-so. `mentor:planning` owns every other approval path.
- Do **not** restate the dispatch grammar or the selection rule here; cite
  `mentor:dispatch-agents` and `mentor:resuming` Step 4. A second copy is a second thing
  to keep true.
- Do **not** hand-edit `.state.json` — `plan-state.sh` is the only writer.
