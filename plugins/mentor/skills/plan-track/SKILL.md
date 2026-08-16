---
name: plan-track
description: |
  Show the repo-wide remaining-work hierarchy — plan lifecycle states, step progress, deps, fix children rolled up under their root with open-descendant counts, deferred stubs, live handoffs — then build the next unbuilt plan. Backs /mentor:track. Use when asked what plans exist, what's left, which plan is next, whether a plan is already implemented or REALLY done (open fixes), "any task left for <plan>", or to implement/pick up/retry a plan generically — an unnamed "what's next" survey, /plan-split with no group named, or /mentor:defer stubs to survey. Reads lifecycle state, refuses when context is too large, warns (never blocks) on unmet deps and a root done with open descendants, routes a deferred stub to /mentor:plan, executes via mentor:dispatch-agents. Inventory and roll-up only — not authoring a request (/mentor:plan), capturing mid-flow work (/mentor:defer), draining a named root's fixes or a named split group's siblings in order (/mentor:resume), or judging plan quality (/plan-review).
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
- "Is X really done?" / "any fixes still open under X?" / "any task left for X?"
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
  this. Draining a root's open fix children in order is also `/mentor:resume <root>`'s
  job, not this skill's — here you only ever see the count and the warn.
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
[ -n "$CLAUDE_PLUGIN_ROOT" ] && [ -d "$CLAUDE_PLUGIN_ROOT/hooks" ] || { echo "ERROR: CLAUDE_PLUGIN_ROOT unresolved or stale — do not search the plugin cache or hardcode a version path; ask the user to /reload-plugins or restart" >&2; exit 1; }
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
a `plan.md` (slug, effective state, group, order, `priority`, `deps` — each marked `missing` when
no such plan dir exists, `origin`, live handoffs, `✅` step counts), plus topic dirs holding a live
handoff but no plan yet, plus the legacy flat `.mentor/handoffs/*.md` dir. It replaces the old
`list` table — `list` still exists and is byte-compatible, but `overview` is the only call that
also carries deps, origin, priority, and step counts, so it is Step 1 now. Whenever it prints anything, that output is valid JSON
(`jq .` parses it); see the hook script's header comment for the exact per-entry shape
(`kind: "plan" | "no_plan_topic" | "legacy_handoffs"`). Plan files live at `PLANS_DIR/<PLAN>/plan.md`.

**It can also print nothing at all** — stdout empty, exit 0, one stderr line saying which case it
hit: **no git repo** (mentor keeps no plan registry outside a repo), or **no `.mentor/plans` dir
yet** (nothing has ever been planned here). Don't feed that to `jq` and don't render an empty
hierarchy — say it in one line and stop. Say what the emptiness means and no more: mentor tracks
only its own plans, so "no mentor plans in this repo" is never a claim that the repo has no work
in flight — planning may simply live somewhere else.

If `$ARGUMENTS` is `status` (case-insensitive) or contains any whitespace — a full sentence or
multi-word survey ask, rather than a single ordinal/slug token — render the hierarchy below and
stop; the user asked to look, not to build. This is a mechanical check, not a judgment call: a bare
ordinal and a bare slug never contain whitespace, so only a genuinely single-token argument (or no
argument at all, which Step 2's own no-argument branch already handles safely via
`AskUserQuestion`) reaches Step 2's resolution below. Without it, a survey sentence that happens to
contain one plan's slug as a unique substring would fall through to Step 2's "a unique match is
selected directly" rule and silently proceed toward Step 3 — this deliberately diverges from
`mentor:resuming` Step 4's rule, which resolves a slug embedded anywhere in a longer phrase: here
any surrounding prose stops at Step 1 instead, on purpose, because a survey-shaped ask must never
silently resolve into a build. Name the plan directly — by ordinal or bare slug alone — to act on
it.

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
1. ● [high]          recommended-first-clean   implemented (3/3 steps)
2. ○ [crit]          oauth-refactor            draft (deferred) — deps: fix-gate-msg-typo
3. ○ [noise]         fix-gate-msg-typo         draft (deferred)
4. ◐                 some-feature              in_progress (1/4 steps)
     └ handoff: 20260801-224510-implement.md (live)
5. ○ [med]   [fix]   claim-order-tiebreak      draft (deferred, from: loom-automation)
     └ goal: `claim_order()` in `plugins/loom/scripts/automate/daily-run.sh` orders…
```

Per plan entry: `<glyph> [<tier>] [<cat>] <slug>   <state>[ (fix child)][ (deferred[, from: <slug>[ (missing)]])]
[(<ticked>/<total> steps)][ — deps: <a>[, <b> (missing)]][ — N open descendant(s)]`, with an optional
`     └ goal: <text>` subline beneath a deferred entry.

- the **tier tag** carries the entry's `priority` — one of `critical`, `high`, `medium`, `low`,
  `noise`, abbreviated to fit one padded column (`crit`/`high`/`med`/`low`/`noise`). An entry whose
  `priority` is `null` gets **blank padding, not a tag** — nobody has judged that plan's impact,
  which is a different fact from judging it `medium`, and inventing a default here would launder a
  guess into something that reads like a record. Keep the column aligned so a scan down it answers
  "what actually matters" without reading a single slug — that separation is the whole reason the
  field exists.
- the **category tag** carries the entry's `category` — one of `feature`, `fix`, `refactor`,
  `docs`, `tooling`, abbreviated to fit one padded column (`feat`/`fix`/`refac`/`docs`/`tool`),
  rendered right after the tier column. An entry whose `category` is `null` gets **blank padding,
  not a tag** — same philosophy as the tier: nobody has categorized that work, which is different
  from having categorized it, and inventing a default here would launder a guess into something
  that reads like a record.
- **Never sort or filter on the tier or category.** The sort below stays exactly as it was, and a
  `noise` plan (or an uncategorized one) still renders in its usual place: `/mentor:track` is the
  inventory of what's left, and a view that quietly dropped the low tiers or hid a category would
  make "what's remaining?" a lie in the one place a user goes to trust it. The tags are there to let
  a reader *skip* the noise, not to decide for them. When the user's ask is explicitly about impact
  ("what actually matters here?"), say which entries sit in the top tiers in a sentence after the
  hierarchy — that answers the question without reshuffling a view the rest of this skill's steps
  index into by ordinal.
- `(deferred)` only when `origin == "deferred"` — the tag that marks an unclaimed `/mentor:defer`
  stub, so it is never mistaken for a plan someone drafted by hand and left in `draft`.
- `(fix child)` only when `parent` is set — a structural fact read straight from `parent`, never
  to be confused with the bracketed `[fix]` *category* tag above (a manual judgment on what kind
  of work this is, set by `set-category`). Comma-joins the parenthetical when `(deferred)` also
  applies — `(fix child, deferred)` is an unclaimed parked stub; `(fix child)` alone is a claimed
  fix already being built in its own right.
- `from: <slug>` joins that parenthetical on a deferred entry whose `deferred_from` is set — e.g.
  `(deferred, from: loom-automation)` — resolved against the same `overview --json` array already
  in hand (never a filesystem probe). When the slug matches **no entry in that same output**, render
  `from: <slug> (missing)` instead — a deleted source plan must never silently dangle in the very
  view built for triage trust (parity with the `deps` `(missing)` marker below).
- step counts only when `steps.total > 0`.
- the `deps` clause only when `deps` is non-empty; a dep entry with `missing: true` gets
  ` (missing)` appended — named as a dependency, but no such plan dir exists yet.
- the `— N open descendant(s)` clause only on a **true root** — an entry with no `parent` of its
  own — and only when N > 0; an internal fix's own count would just repeat what the next line
  down already shows. Get N (and the list, when asked) from `plan-state.sh subtree <root-slug>`,
  never a hand-rolled walk — "open" is that command's own definition (effective state ∉
  `implemented`/`superseded`), not one to re-derive here. A dangling `parent` (matches no entry in
  this same `overview --json` output) falls the entry back to the top level with `(parent: <slug>
  missing)` appended — parity with the `deps` and `from:` missing markers above.
- a `— ⚠ N unparented open fix(es) trace here` clause when N > 0 open (effective state ∉
  `implemented`/`superseded`) `category: "fix"` entries in this same `overview --json` output
  carry `deferred_from` = this entry's slug but no `parent` of their own — lineage without
  containment, which `subtree` and the descendant roll-up above are structurally blind to
  (typically fixes captured before the owning-plan routing rule existed, or judged backlog at
  capture). The stubs themselves still render flat at the top level — structure stays
  `parent`-only — but without this clause an `implemented` plan whose confirmed defects were
  all captured lineage-only reads completely clean, which is exactly the wrong answer to "any
  fixes left under this plan?". The filter keys on `category: "fix"` for precision, so a legacy
  defect stub captured with no category stays uncounted — `set-category <slug> fix` repairs
  that first. Whenever at least one such clause rendered, close the hierarchy with a single
  repair hint line — unnumbered, never consuming an ordinal (Step 2's selection resolves
  against this render):
  `unparented fixes exist — adopt with: bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" set-parent <stub-slug> <owning-plan>`.
- ` [worktree: <id>]` appended when the entry's `owner` (an additive field on every `overview
  --json` plan entry, v2.23.0) is set AND differs from the worktree you're running in. Derive
  your own id once, before rendering, by reusing the same helper the hooks use rather than
  re-deriving the recipe by hand:

  ```bash
  [ -n "$CLAUDE_PLUGIN_ROOT" ] && [ -d "$CLAUDE_PLUGIN_ROOT/hooks" ] || { echo "ERROR: CLAUDE_PLUGIN_ROOT unresolved or stale — do not search the plugin cache or hardcode a version path; ask the user to /reload-plugins or restart" >&2; exit 1; }
  this_wt="$(. "${CLAUDE_PLUGIN_ROOT}/hooks/lib/state.sh"; mentor_worktree_id "$(pwd)")"
  ```

  An entry with no `owner` (a pre-2.23.0 plan, or one no worktree has claimed) gets no tag — only
  a KNOWN different owner does. This is what lets a reader spot a sibling worktree's draft before
  Step 2's selection or the dispatch that follows it, without waiting for Step 3's gate check to
  say so.
- each entry's **live** handoffs (its `handoffs` array — `overview` already excludes `resolved/`)
  render as one indented line beneath it: `     └ handoff: <name> (live)`.
- a deferred entry's `goal` (non-null only when `origin == "deferred"`) renders as one indented
  line beneath it, at the same indent the `handoff:` line above uses: `     └ goal: <text>` —
  straight from `overview --json`'s `goal` key; the render never re-opens the plan file.

Split-group siblings (`group` set) stay contiguous, ordered by `order`; on the group's first
sibling, print a one-line header `▸ group: <group-slug>` and indent the members two spaces under
it — same grouping `list` sorted by, just rendered instead of tabulated.

### Fix children nest under their parent, not the top level

Walk `overview --json`'s `parent` field exactly as the paragraph above walks `group`: an entry
with `parent` set never renders at the top level, but directly beneath its parent's line, indented
two spaces deeper than it — recursively, so a fix parked under a fix (a grandchild of the root)
sits two spaces deeper again, however far the chain runs. This composes with the group block: a
split sibling with its own parked fix nests the fix one level deeper under the sibling's own line,
inside the `▸ group:` block.

A worked example, three levels deep — `fix-retry-loop`'s `parent` is `fix-auth-timeout`, whose own
`parent` is `root-plan`; the chain, never physical nesting on disk, produces the indent:

```
1. ⚠ ● root-plan              implemented — not really done, 2 open descendant(s)
  2. ○   fix-auth-timeout       draft (fix child, deferred)
    3. ○   fix-retry-loop         draft (fix child, deferred)
4. ○ [noise] other-stub        draft (deferred)
```

`root-plan` carries the roll-up because it has no `parent` of its own; neither fix line repeats
it. A root whose own effective state already reads `implemented` while `subtree` still reports
open descendants — the CLI's warn on `set … implemented` fired once at write time, but nothing
re-checks it later — surfaces the same warning here: prefix the line `⚠ ` and swap the tail to
`— not really done, N open descendant(s)`, exactly as `root-plan` does above.

Numbering stays depth-first and still actionable-entries-only, exactly like the group block: a
root's fixes number immediately after it and before the next top-level entry, so Step 2's ordinal
selection resolves against fix children exactly as it does everything else in this render.

`deps`, `group`/`order`, and `parent` are three separate axes and this render never blurs them:
`deps` means "should happen before, elsewhere" (the `— deps:` clause); `group`/`order` means
"sibling of a split, same rank" (the `▸ group:` header); `parent` means "must close before its
container reads done" (tree position, the root's count, and the warn). Draining a root's open
descendants in order is `/mentor:resume <root>`'s job, not this skill's — it walks the same
subtree; here you only ever see the count and the warn.

`kind: "no_plan_topic"` entries use `▷` and the literal state text `no plan yet`, followed by their
`handoff:` line(s) — a topic that only has conversation history, never a plan.

`kind: "legacy_handoffs"` (topic-less, at most one entry) renders last if present:
`▽ (untracked) legacy handoffs: <name>, <name> — .mentor/handoffs/, no topic`.

Sort `kind: "plan"` entries the same way the old `list` table did: active states first
(`superseded`/`unknown` last), then by group (an ungrouped plan sorts on its own slug), then
`order`, then slug — so a reader who knew the old table still recognizes the order.

### On a broader ask than the hierarchy (a scope/goal digest)

The hierarchy above is deliberately just state + progress — `overview --json`'s `goal` field is
populated **only** for `origin: "deferred"` entries, by design (`plan-state.sh`'s `_plan_walk` skips
the `plan.md` re-read for every ordinary plan so `overview` stays fast on a big plan set; see that
function's own comment). When a survey-shaped ask (the gate above) wants more than the bare
hierarchy — a one-line synopsis of what each plan actually covers — do **not** hand-roll ad hoc
`grep`/heading patterns against `plan.md`: plans don't share one heading convention (one `plan-
split` child may use `### N. Title`, another may not), so an improvised pattern will silently miss
some. Instead, call the shared extractor per plan you're summarizing, same recipe as the worktree-id
lookup above:

```bash
[ -n "$CLAUDE_PLUGIN_ROOT" ] && [ -d "$CLAUDE_PLUGIN_ROOT/hooks" ] || { echo "ERROR: CLAUDE_PLUGIN_ROOT unresolved or stale — do not search the plugin cache or hardcode a version path; ask the user to /reload-plugins or restart" >&2; exit 1; }
synopsis="$(. "${CLAUDE_PLUGIN_ROOT}/hooks/lib/state.sh"; plans_dir="$(mentor_plans_dir "$(git rev-parse --show-toplevel)")"; mentor_plan_goal_line "${plans_dir}/<slug>/plan.md" context)"
```

Pass `context` explicitly: the function defaults to `goal` (matching its one existing caller,
`_plan_walk`'s deferred-only gate above), and an ordinary plan authored by `mentor:planning`'s
content spec carries a `## Context` section, never a `## Goal` one — passing the wrong (default)
section silently returns empty for every ordinary plan. It already reflows and truncates
consistently (see its own comment in `hooks/lib/state.sh`) — never re-derive that logic inline.

**Setting a tier or category** is one call each, and both are the natural follow-up when the user
reacts to the hierarchy with a judgment ("that one's noise", "these three are critical", "that's
really a docs task"):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" set-priority <slug> critical   # "" clears
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" set-category <slug> fix       # "" clears
```

Each writes nothing but its own field — state, note, deps and ownership all ride through untouched
— so either is safe to run against a plan mid-flight. Only the five tier values, or the five
category values (`feature`/`fix`/`refactor`/`docs`/`tooling`), are accepted; an invalid one exits 1
having written nothing, so a batch that tags several plans should check each call rather than
assume the last one landed. When the user hands you a judgment in their own words ("this is just
cleanup"), map it to the nearest tier or category and say which one you picked — don't invent a
sixth.

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

Where that leaves more than four candidates, **let the tier break the tie** — a `critical` plan
earns one of the four slots over a `noise` one, and an untiered plan sits between them rather than
last (unjudged is not the same as judged unimportant). This is the one place the tier is allowed
to change what the user sees, and only because four slots have to be chosen somehow; Step 1's
rendered hierarchy still shows everything, in its own unchanged order. Name the tier in the
option's `description` when it is doing that work, so a user who disagrees can say so instead of
wondering why their plan wasn't offered.

**Every question stands on its own.** The user answers from the question screen alone — never sent
to a file, a plan section, a coined id or code, or an earlier turn to learn what the question means.
Here that means an option describes the plan's *work* and where it stands ("Thanos SSA reprojection
— approved, 3 of 7 steps left"), never a bare slug or a hierarchy position ("the second one"): the
hierarchy scrolled off the moment the question opened. For a deferred stub, that description can
draw on `overview`'s `goal`, `deferred_from`, and `priority` keys directly — e.g. "claim-order-
tiebreak — medium-priority fix deferred from loom-automation: `claim_order()` in daily-run.sh orders
concurrent…" — rather than falling back to the bare stub state.

**Carry Step 1's worktree tag into this step too.** When the resolved or offered entry has a
` [worktree: <id>]` tag, repeat it — in an `AskUserQuestion` option's `description`, or in the
confirmation line for an argument/ordinal pick — rather than letting it disappear once the
hierarchy scrolls off. By Step 3 a `draft` entry owned by a different, live worktree is a hard
refusal, not a choice; surfacing the tag here, before dispatch, is what makes that refusal
expected instead of a surprise two steps later.

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

**Check `kind` before anything else in this step.** A selected `kind: "no_plan_topic"` entry is a
topic dir holding conversation history and no `plan.md` — no `.state.json`, so no row of the table
below applies, and no implementation steps, so there is nothing to dispatch. Do not fall through to
the table: the closest-looking row (`unknown`) offers "mark it implemented", and `plan-state.sh set`
will accept it — `require_slug` only checks that the dir exists — writing a sidecar no `overview`
branch ever reads, under a report that says the work is done. Say plainly that this topic has no plan
of record, then route:

- **Continue the conversation** → `/mentor:resume <the note's filename slug>` — the part of the
  handoff basename *after* the `YYYYMMDD-HHMMSS-` prefix, taken from this entry's `handoffs` array
  (unsorted — take the highest timestamp if more than one is live). Not the topic slug:
  `mentor:resuming` Step 4 matches its argument against the note's filename slug, and the two are
  only sometimes the same string. That skill loads the note and acts on its "Recommended mentor
  commands for the next agent" section, so do not re-derive the next steps here.
- **Make it buildable** → `/mentor:plan <this topic's slug>`, naming the slug explicitly so `plan.md`
  lands in this same dir beside its handoffs; `mentor:planning` otherwise derives a slug from the
  request and can mint a second topic dir that orphans these notes.

One caveat before recommending resume: `overview` lists every live `*.md` in the topic's `handoffs/`,
while `/mentor:resume` lists only names matching `^[0-9]{8}-[0-9]{6}-.+\.md$`. If the basename
rendered above does not match, say so — the note is real but invisible to resume until it is renamed,
and `mentor:resuming` Step 4 owns that recovery on the user's explicit ask. Never dispatch a
`no_plan_topic` entry, and never offer to.

**A deferred stub short-circuits it next.** If the selected entry's `origin ==
"deferred"` (same `overview --json`), it is an unclaimed `/mentor:defer` stub — a
Goal/Context/Why-deferred skeleton, not a plan ready to build. Say so, then point the user at
`/mentor:plan <the stub's slug or its Goal>` to flesh it out — that skill runs `claim` on the stub
when it does, clearing `origin` so the normal approval sweep can pick it up afterward. The same
path covers a fix child (`parent` set) picked here while still unclaimed — nothing new to route:
`claim` preserves `parent` alongside `origin`, so the fix stays linked to its root through its own
plan → approve → build cycle once `/mentor:plan` claims it. Do not act on the table below for a
deferred stub, and do not offer to build it directly — that is exactly the shortcut the `origin`
shield exists to prevent.

**A live planning session short-circuits it too, whatever the state — but which token comes back
changes what's actually blocked.** Check the gate before acting on the table:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" gate   # ARMED | ARMED_ELSEWHERE | STALE | RELEASED
```

- **`ARMED`** — THIS worktree's own gate (or the legacy repo-global marker) is live, so
  `plan-gate.sh` will deny the first write every implementation agent attempts, whatever state the
  selected plan is in. Dispatching anyway burns the whole batch on a wall — a dispatch you cannot
  finish is worse than one you never started. Say the gate is armed and stop before dispatching; do
  **not** run `approve-plan.sh` to clear it, because it takes no slug and promotes every plan newer
  than the marker it resolves, which would silently approve whatever draft that live session is
  still writing.

  Two things put you here, and the plan's own sidecar note tells them apart — read
  `.mentor/plans/<slug>/.state.json` directly, since `overview --json` does not carry `note`:

  - note says `approval retracted` → this plan's approval was taken back (`planning`'s
    [Retracting an approval](#retract)). Point the user at `/mentor:plan <slug>` to finish planning it.
  - no such note → some *other* plan is being planned right now, and this one is simply waiting.
    Say so and let the user finish or approve that session rather than guessing on their behalf.

  Both readings share the same conclusion — don't dispatch — which is why the check itself is
  state-agnostic and the diagnosis is only there to make the message useful.

- **`ARMED_ELSEWHERE`** — no marker of THIS worktree's own is live; a *sibling* worktree's is. It is
  an independent gate and does **not** block a write here, so dispatching an already-`approved` plan
  proceeds exactly as if the token were `RELEASED`. It does **not**, though, clear the way for
  anything that would promote or dispatch a plan still in `draft`: the `draft` row below and the
  whole **"Approving a draft plan here"** section are hard-refused while this token shows, because a
  sibling worktree mid-drafting is exactly the situation that escape hatch cannot tell apart from
  "safe to promote." Name which worktree with `--verbose`:

  ```bash
  bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" gate --verbose   # one elsewhere=<wt-id> … line per live sibling
  ```

  Surface every `elsewhere=` line to the user before continuing past a `draft` selection.

`STALE` and `RELEASED` place no restriction here — proceed to the table below.

Otherwise, act on the effective state:

| Effective state | What to do |
|---|---|
| `approved` | If the sidecar's note says it was **swept in by `approve-plan.sh`** rather than individually approved (a different plan's approval promoted it too, because both `plan.md` files were newer than that session's marker), show the note and confirm with the user before dispatching — it was not necessarily reviewed. Otherwise set `in_progress`, then execute (below). |
| `failed` | Show the sidecar's note — it says what broke last time, and on a verification failure it names the topics left unresolved. Then split on the ticks (`steps: {ticked, total}` from Step 1's `overview --json`). **`ticked < total`** — it broke mid-implementation: set `in_progress` and retry from the first unticked step, feeding that note to the first agent. **`ticked == total` with `total > 0`** — it broke at end-to-end verification, whether escalated after a failed remediation or handed off with topics outstanding: re-enter `mentor:dispatch-agents`' **Verifying the plan (execution-time)** round on the topics the note names — every topic, if a bare `set … failed` left the note empty — and leave the state at `failed` until Step 4's close-out writes `implemented`. Writing `in_progress` on this shape is erased on the next read — the tick derivation outranks it, so the plan would report `implemented` before the retry has run. A plan with no step lines at all (`{0, 0}`) takes neither branch: it never ran implementation steps, so read the note and pick up where it says. |
| `in_progress` | An interrupted run. Re-enter execution **from the first unticked step**; never restart from step 1. |
| `implemented` | Say so and offer another. Do not rebuild it. |
| `draft` | **Not buildable as it stands.** The approval gate never released this plan, and once the marker has aged out (or the session that armed it ended) `plan-gate.sh` would happily allow the edits — this refusal is what keeps that from becoming a hole in the gate. A `draft` plan *with* a fresh **own** marker is a paused planning session and never reaches this row: the preflight above catches it. There is exactly one authorized way through, on the user's explicit say-so: **"Approving a draft plan here"** below — unless the preflight's gate check read `ARMED_ELSEWHERE`, in which case even that one way through is hard-refused (see above). |
| `unknown` | A pre-2.4.0 plan with nothing on record. Never show the approval pointer — it would be false for a plan that shipped months ago. Offer: mark it implemented, or leave it alone. |

To move state:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" set <slug> <state> [--note "…"]
```

### Approving a draft plan here

**Worktree check, first — before origin.** Whether you arrived here through Step 3's preflight
above or the user jumped straight to "approve draft plan X", check the gate before doing anything
else:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" gate
```

`ARMED_ELSEWHERE` **hard-refuses this whole section** — a sibling worktree is mid-planning, and
this escape hatch cannot tell "safe to promote" from "that worktree is still writing this very
draft." Run `gate --verbose`, name every `elsewhere=<wt-id> … worktree=<path>` line to the user,
and stop; do not ask the three-way question below. `ARMED` (this worktree's own marker, or a live
legacy marker) stops you here too, for the same reason Step 3's preflight already gives for
`ARMED`. Only `STALE` or `RELEASED` let you continue.

**Origin check, next.** Confirm `origin` for this slug (from Step 1's `overview --json`, or
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
user actually chose. Then re-check the gate before running `approve-plan.sh` — the worktree
check at the top of this section ran before the three-way question was asked, and time (and
another worktree's session) can pass while the user answers:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" gate   # must read STALE or RELEASED
```

`ARMED` or `ARMED_ELSEWHERE` here means stop and re-apply the worktree check above instead of
running `approve-plan.sh` blind — edits are still blocked (or another worktree's draft is now
live) and the state move alone will not unblock them:

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
  from `mentor:dispatch-agents`, its **Verifying the plan (execution-time)** dispatch —
  no escape hatch; implementation may be main-thread, verification never is — and its
  **CLOSING CHECKLIST** — the `/mentor:tour` offer, the `/mentor:defer` sweep, and the
  `/mentor:ship` pointer) exactly as the dispatch path does it.
  Arriving here does not make that path unowned — and on a resumed plan the skip
  line is a claim about the plan as it stood when someone last checked it, not as
  it stands now: if it now carries more than about two steps, or any step whose
  `Done when:` needs a service brought up, a browser driven, or a screenshot
  compared, it no longer clears the escape-hatch bar (`mentor:dispatch-agents`,
  "Escape hatch — when a plan may skip annotation") — re-annotate the remaining
  steps as dispatches and execute them normally from here. A skipped plan usually
  writes its steps as plain numbered items rather than `Step N — …` lines — `bash
  "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" tick <slug> <N>` counts either form
  by ordinal, so ticking works the same way regardless of which one this plan uses.

## Step 4 — Close out

When every `Done when:` has passed and every Verification topic is PASS (gaps
fixed, deferred, or accepted), `set <slug> implemented` — a plan with zero topics
clears that vacuously, so it gets there only on the user's explicit acceptance of it
unverified, per **Verifying the plan (execution-time)**. Verification ending
unresolved writes `set <slug> failed --note "<what broke>"` either way — escalating
after the remediation re-dispatch also failed, or handing off with topics
outstanding — and the note is what makes the retry cheap next time.

**Reconcile the ticks before writing `implemented`.** Read this plan's
`steps: {ticked, total}` from `plan-state.sh overview --json`; if `ticked < total`,
either tick the step lines that actually passed or tell the user which steps are
closing untracked and why. `plan-state.sh set <slug> implemented` now prints a
fail-soft warning when `ticked < total`, but that fires only *after* the write and
only names the ratio — it is a backstop for a miss already made, not a substitute
for reconciling here while you still remember which steps actually passed. The
tick-derived state stays deliberately one-directional, so it can *raise* a stale
sidecar but a closed plan's missing ticks are never recovered automatically.

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
- A root marked `implemented` with open descendants still surfaced the warn here, not just at
  write time.
- The plan that ran ended at `implemented` or at `failed` with a note.

### Do NOT

- Do **not** dispatch implementation on `CONTEXT: ASK` before the user has answered —
  and do **not** refuse them on `CONTEXT: HANDOFF`, which means they already did.
- Do **not** execute a plan that is still `draft`, however open the gate happens to be —
  approve it through the step above first, or stop.
- Do **not** build or approve a deferred stub directly, however the user phrases the ask — point
  at `/mentor:plan <slug>` every time; only `claim` (run by that skill) lifts the shield.
- Do **not** dispatch a `kind: "no_plan_topic"` entry or write state for it — it has no plan and no
  steps; route it per Step 3's first short-circuit.
- Do **not** hard-block on unmet deps — Step 2.5 is advisory; the decision to proceed anyway is
  the user's.
- Do **not** **arm** the edit gate, and release it only through "Approving a draft plan
  here", on the user's explicit say-so. `mentor:planning` owns every other approval path.
- Do **not** restate the dispatch grammar or the selection rule here; cite
  `mentor:dispatch-agents` and `mentor:resuming` Step 4. A second copy is a second thing
  to keep true.
- Do **not** hand-edit `.state.json` — `plan-state.sh` is the only writer.
