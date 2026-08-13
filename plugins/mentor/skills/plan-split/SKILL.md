---
name: plan-split
description: |
  Split one oversized mentor plan into several SEPARATE sibling plan files, each
  small enough to build in its own session. Trigger phrases: `/plan-split`, "split
  this plan into separate plans", "break this plan up", "this plan is too big for one
  pass", "make these into their own plans" — and it is offered as the leading option
  at the `mentor:planning` approval step whenever a plan is oversized. Use this whenever a
  written plan has more work in it than one implementation pass can carry, even if the
  user only says the plan feels unwieldy. Not for reorganizing one plan's steps into
  phases or stages inside a single document — that is a `/mentor:plan` re-write; this
  skill produces N independently buildable plan files. It dispatches one agent per
  slice to author full
  plan-grade children with explicit scope isolation — every child names the sibling
  that owns each area it does NOT touch — then marks the parent superseded. It never
  arms or releases the edit gate.
---

# Plan Split — One Oversized Plan → N Isolated Siblings

`mentor:planning` assumes one ask = one plan. When the ask is huge, that single plan
becomes unreviewable, its implementation runs out of context partway through, and a
resumed session has to guess which steps already landed.

This skill takes the plan that already exists and splits it into **ordinary sibling
plans** in the ordinary `.mentor/plans/` dir. No hierarchy, no new entity — the
children are peers, related only by a `group` field pointing at the parent's slug.

The deliverable that makes them safe to build separately is the **isolation header**
(Step 5): each child states what it owns and, for everything it does not own, which
sibling does. An implementation agent that inherits that boundary cannot wander into
a neighbour's files.

## When to use

- The plan `mentor:planning` just wrote is oversized — roughly >12 implementation steps,
  or it contains independent deliverables that could ship separately.
- The user asks to split, break up, or slice a plan, in any phrasing.
- The user chose **"Split into multiple plans"** at the approval step.

## When NOT to use

- **No plan exists yet** — author one first with `/mentor:plan`. This skill splits a
  written plan; it does not plan.
- **The user wants phases inside one document** ("split it into two stages so we can
  review each half") — that is a re-write of the plan's `## Implementation steps`, not
  N plan files. Check which they mean before dispatching five agents; the give-away is
  whether they expect to build the halves in separate sessions.
- **You want a quality audit of the plan** — that is `/plan-review`.
- **You want to pick which existing plan to build next** — that is `/mentor:track`.
- **The plan is already a child of a split** (it has a `group`) — splitting a slice
  again usually means the first split drew its lines in the wrong place. Say so and
  offer to redraw instead. If the user still wants it, proceed.

---

## Step 1 — Resolve the plan and its state

```bash
[ -n "$CLAUDE_PLUGIN_ROOT" ] && [ -d "$CLAUDE_PLUGIN_ROOT/hooks" ] || { echo "ERROR: CLAUDE_PLUGIN_ROOT unresolved or stale — do not search the plugin cache or hardcode a version path; ask the user to /reload-plugins or restart" >&2; exit 1; }
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" current
```

Use the `PLAN:` path it prints and `Read` that file. If it prints `GROUP:` other than
`-`, this plan is already a slice — see *When NOT to use*. If it reports no plan, say
so in one line and stop.

**Record the `STATE:` value now** — Step 6 needs the parent's state *before* the swap,
and after the swap it is `superseded` and the original is unrecoverable.

## Step 2 — Guard on work already done

Splitting a plan that is partly built can silently re-do finished work, which is far
more expensive than a bad split. Check the plan body for `✅` step ticks:

- **Effective state `implemented`** (every step ticked) — refuse. There is nothing
  left to split. Offer `/mentor:track` to confirm, or `/mentor:plan` for new work.
- **Some steps ticked** — warn, name which steps are done, and get explicit
  confirmation before continuing. When you author the children in Step 4, **carry each
  tick onto the same step in whichever child now owns it**, so the finished work stays
  visibly finished.
- **No ticks** — proceed.

## Step 3 — Propose the slices, and confirm before writing anything

Design the split yourself from the plan body, then put it to the user **before any
file is written**. A split is cheap to redraw now and expensive to redraw after N
agents have authored N plans.

Present each slice as: `slug` · one-line outcome · what it depends on · what it
explicitly does **not** own. **Every question stands on its own** — the user answers
from the question screen alone, never sent to a file, a plan section, a coined id or
code, or an earlier turn to learn what the question means; so the question itself
restates the slices in one line each rather than saying "the split above", which has
already scrolled away. Then ask via `AskUserQuestion`:

- **"Split as proposed"** (recommended), **"Adjust the slices"**, **"Cancel"**.
- **Only when Step 1 reported `STATE: unknown`** (a pre-2.4.0 plan with nothing on
  record), add a second question: *"Was this plan already approved?"* — Yes/No. Step 6
  needs the answer, and asking here costs no extra turn.

Aim for slices that are each independently implementable and roughly one session's
work. If N > 4, confirm the count and mention `MENTOR_PLAN_OPEN=off` — `plan-open.sh`
opens every new `plan.md`, so a 6-way split pops six editor tabs.

## Step 4 — Author the children by dispatch, one agent per slice

Issue one `Agent` call per slice (`subagent_type: general-purpose`, `model: sonnet`,
`effort: high`), **all in a single message** so they run concurrently — the same
pattern `mentor:zooming` Step 3 uses for zoom artifacts. Authoring in the main thread
would defeat the purpose: the point is to keep the orchestrating context lean.

Each subagent starts with **zero memory of this conversation and no
`CLAUDE_PLUGIN_ROOT`**, so a prompt that says "follow the content spec at
`{#write-the-plan}`" gives it nothing it can resolve. Resolve the paths first:

```bash
[ -n "$CLAUDE_PLUGIN_ROOT" ] || { echo "ERROR: CLAUDE_PLUGIN_ROOT unresolved — cannot build subagent prompts; do not search the plugin cache or hardcode a version path; ask the user to /reload-plugins or restart" >&2; exit 1; }
echo "${CLAUDE_PLUGIN_ROOT}/skills/planning/SKILL.md"
mentor_dir="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" dir)"   # worktree-safe
[ -n "$mentor_dir" ] || { echo "ERROR: mentor dir unresolved — is CLAUDE_PLUGIN_ROOT set? do not search the plugin cache or hardcode a version path; ask the user to /reload-plugins or restart" >&2; exit 1; }
ls "$mentor_dir/constitution.md" 2>/dev/null   # include only if it exists
```

**Mint every child's directory from the MAIN THREAD before dispatching any agent —
this is what stamps ownership at creation, not after.** For each slice:

```bash
# Re-derive: the path block above ran as its own Bash call, so $mentor_dir is gone here.
mentor_dir="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" dir)"
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" ensure-dir "${mentor_dir}/plans/<CHILD-SLUG>"
```

`ensure-dir` stamps `owner`/`owner_session` on a plan-topic dir the instant it is
minted (a direct child of `plans/` — see `plan-state.sh`'s `ensure-dir` contract,
v2.23.0). Minting all N children here, before any subagent writes, closes the
unowned window: if a child's directory instead came into existence via the
dispatched agent's own `Write` call, that child would sit **unowned** — and, being
freshly written, **newer than every live marker in the repo** — for the whole
window until Step 6.1 registers it. An unowned plan newer than a marker is exactly
what a sibling worktree's `approve-plan.sh` sweeps when no sibling marker is live
("solo back-compat"), and if the split flow aborts partway, a child minted only by
`Write` stays permanently unowned. Mint first, and every child is owned by this
worktree from its very first byte on disk.

Prompt template — every child gets all of it, then the contract block cited below:

```
Author one plan file. You are writing a plan, not implementing anything.

1. Read <ABS>/skills/planning/SKILL.md and follow its "Content spec" (Step 4) exactly:
   the required sections in order, the visualization decision rule, the Mermaid
   portability rules, and the dispatch annotations from mentor:dispatch-agents.
   This is a real plan — use case scenarios, dispatch-annotated steps, critical
   files, verification. Not a stub or a summary.
2. Read the parent plan at <REPO>/.mentor/plans/<PARENT>/plan.md for context.
   [if a constitution exists:] Read <REPO>/.mentor/constitution.md and include the
   "## Constitution Check" section the content spec requires.
3. Your slice is: <one-line outcome>. It owns: <paths / surfaces / deliverables>.
4. Your siblings are, in order: <slug — outcome — owns> (one line each).
   Everything outside your slice belongs to one of them. Never plan work in it.
5. Open the plan with the isolation header, verbatim in this shape: <the Step 5
   block, filled in>.
6. Every "## Out of scope" entry must name the sibling slug that owns it.
   [if carrying ticks:] These steps are already done — keep their ✅: <list>.
   Put each ✅ on the step's own top line — its `Step N — …` line, or its numbered
   item if that is how the step is written — never on an indented sub-line, which
   mentor cannot see and reads as work never started.
7. Write exactly one file, with a single Write call:
   <REPO>/.mentor/plans/<CHILD-SLUG>/plan.md
   Create no other files. Edit no repo source. Return only the path and a
   one-line summary — never the plan body.
```

**Every child prompt ends with `mentor:dispatch-agents`' standing contract block**, and
that block has exactly one authored home — so read **"Deliver before idling"** in that
skill's "Async runtime & lifecycle" section and paste it verbatim after item 7, the same
read-it-at-the-source pattern its `references/verifier-contract.md` uses. Invoke
`Skill(skill="mentor:dispatch-agents")` here if it is not already loaded; a `/plan-split`
reached directly has loaded nothing. A second copy kept here is how this template drifted
out of step with the canonical text once already. The block is what makes a child report
instead of signalling idle with nothing written — without it, Step 6's missing-child
re-dispatch loop becomes the normal path rather than the rare one, and a paraphrase is no
substitute: it drops directives the child has no other way to learn.

## Step 5 — The isolation header

Every child opens with one GFM alert. This is the artifact that makes the siblings
safe to build in any order and in separate sessions:

```
> [!NOTE]
> **Plan 3 of 5** · group `multi-tenant-billing` · depends on `tenant-data-isolation`
> **Owns:** src/billing/invoice/**, the `/v1/invoices` route
> **Does NOT touch:** metering ingestion → `metering-pipeline` · tenant scoping → `tenant-data-isolation`
```

Name a **sibling slug** for every excluded area — "does not touch metering" tells an
implementation agent nothing about where metering went; "→ `metering-pipeline`" tells
it exactly. The header is where a human reads dependency order at a glance, but it is
not what `/mentor:track` reads: since v2.17.0 the sidecar carries a `deps` array, and
`init --group/--order` below does not populate it. When a child's `depends on` should
also drive track's build order and unmet-dep warnings, set it explicitly —
`plan-state.sh set-deps <child-slug> <a,b>` (cycle-checked).

Keep the first line's shape (`**Plan <n> of <N>** · group \`<slug>\``) — mentor parses
`group` and `order` back out of it whenever a `.state.json` is missing or torn, so the
header is what lets a plan dir survive with nothing in it but `plan.md`.

When you later dispatch implementation for a child, pass its header into the agents'
prompts so the boundary travels with the work.

## Step 6 — Verify, then commit the swap — in this order

The ordering is the whole point: a failed agent must never leave a superseded parent
with no children, which would delete the user's plan.

1. **Verify each child as it lands, and register it immediately — never batch
   registration until all N exist.** For every expected `plan.md`: `ls` it, confirm
   it is non-empty and opens with its isolation header, then IMMEDIATELY register
   that one child:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" init <child-slug> --group <parent-slug> --order <n>
   ```
   `init` re-stamps `owner`/`owner_session` for this worktree (Step 4's `ensure-dir`
   already stamped it at mint time — this is the last-init-wins re-own, and the
   carrier for `--group`/`--order`). A tiered parent's `priority` is **not** inherited:
   nothing copies it down, and a split is exactly where a blanket copy would be wrong —
   a `critical` parent usually splits into one critical slice and several ordinary
   ones. If the parent carried a tier, add `--priority <p>` per child here, judging
   each on its own, so the tiering survives the split instead of being silently lost
   with the parent. Registering per child, as it verifies, matters
   for the same reason Step 4 mints before dispatch: batching registration until
   every child exists would leave each already-verified child relying on nothing
   but its mint-time stamp for the whole remaining verification window, and if the
   split flow aborts before the last child lands, every child verified-but-never-
   registered would carry no `group`/`order` at all — permanently, since nothing
   else writes them.
2. **Re-dispatch** any missing or empty child **once**, with the same prompt, then
   verify and register it exactly as above.
3. **Inherit the parent's state** (the value recorded in Step 1) so approved work
   stays runnable — apply this once ALL N children are verified and registered:

   | Parent state | Children start at | Why |
   |---|---|---|
   | `draft` | `draft` (the `init` default) | approval hasn't happened; the gate will promote them |
   | `approved` · `in_progress` · `failed` | `approved` — `plan-state.sh set <child> approved` | the work was already approved; a split only re-organizes it |
   | `unknown` | the Step 3 answer: approved → `approved`, otherwise `draft` | nothing was on record, so ask rather than guess |

   Without this, splitting after approval — in a fresh session with no marker FOR
   THIS WORKTREE for `approve-plan.sh` to compare against, or in a worktree whose
   live marker belongs to a DIFFERENT worktree (so `approve-plan.sh`'s ownership
   filter excludes these children even though a marker exists) — yields children
   stuck at `draft` that `/mentor:track` will refuse to run. A dead end with no way
   out.
4. **Finally** retire the parent:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" set <parent-slug> superseded
   ```
   The parent's `plan.md` stays on disk as the record of the whole; `superseded` just
   removes it from "the current plan" and sorts it last.

## Step 7 — Check the split holds

Surface these in conversation — they are cheap now and expensive once implementation
starts:

- Every parent scenario and implementation step lands in **exactly one** child.
- No two children own the same deliverable, file, or route.
- No child's header references a sibling slug that does not exist.
- Each child is implementable alone, given only its stated dependencies.
- Each child has a non-empty **Owns** and **Does NOT touch**.

Fix any failure by re-dispatching that child before moving on.

## Step 8 — Return to the approval gate

Splitting never releases the edit gate — only `mentor:planning` does. When you finish,
the gate's original subject no longer exists, so leaving the user here strands them.

Surface each child's **isolation header only** (not the full bodies — that is what the
files are for), then **re-ask `mentor:planning`'s approval question**, exactly as the
"Review the plan (light)" option does when it returns. Note in the question that
**Proceed now approves the whole set** and routes building to `/mentor:track`, so the
user is not left wondering which child "Proceed" means.

## Done when

- The user confirmed the slice map **before** any file was written.
- N children exist, each a full plan per the content spec, each opening with an
  isolation header whose exclusions name owning siblings.
- Every child is registered with its `group` and `order`, and carries the state it
  inherited from the parent.
- The parent is `superseded` — and only after every child verified.
- The user is back at the approval question, looking at the children's headers.

### Do NOT

- Do **not** edit repo source, or arm/release the edit gate — this skill only writes
  under `.mentor/plans/`.
- Do **not** mark the parent `superseded` before every child is verified.
- Do **not** restate the plan content spec, the dispatch grammar, or the approval flow
  here — point the agents and yourself at `mentor:planning` and `mentor:dispatch-agents`.
  Two copies of a spec means one of them is wrong.
- Do **not** write a child anywhere but `<repo>/.mentor/plans/<child-slug>/plan.md`.
- Do **not** author the children in the main thread — that spends the context the
  split exists to protect.
