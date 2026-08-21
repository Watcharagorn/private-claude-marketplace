# plan-track — rationale

Why the rules in `SKILL.md` are shaped the way they are. Read this before overriding one,
or before changing the renderer behind `query --format tree`. It is deliberately not
loaded on a normal run — `SKILL.md` is paid for on every `/mentor:track`, this file only
when someone is about to change something.

## Why the hierarchy is rendered by the script, not by prose

Until v2.38.0 the layout lived in `SKILL.md` as a ~9.5KB section — a table of glyphs, then
about forty bullets specifying columns, parentheticals, nesting, numbering and sort order.
Two costs came with that, and both were measured on real sessions rather than guessed at:

**It was paid on every invocation.** That section alone was ~2.8k tokens of instruction,
loaded whether the user asked to build something or just wanted to know what was left. On
top of it, Step 1 handed the model the full JSON array — 19.8KB, ~5.8k tokens, on a repo
with 40 plans — because the model needed every field in order to draw the view by hand.
The rendered tree is ~6.5KB. Between the prose and the payload, moving the render into
`plan-state.sh` returns roughly 7k tokens per `/mentor:track`, on a path that was
measurably arriving at 100k+ before any real work began.

**It re-derived the layout every session.** Nothing in the prose was a judgment call —
glyph per state, tier abbreviation, indent per depth, which entries get ordinals — yet
each run reconstructed all of it from description. Two sessions over the same repo could
and did produce differently-shaped views, which matters because Step 2 resolves the user's
pick against the numbers in that view. A script cannot drift that way; a paragraph can.

The general form: when every input to a decision is already a field the tooling holds, the
decision is not instruction, it is code that hasn't been written yet.

## Why the tier and category columns pad blank instead of defaulting

An entry whose `priority` is `null` gets blank padding, never a `[med]` tag. Nobody has
judged that plan's impact, which is a different fact from having judged it medium —
inventing a default here would launder a guess into something that reads like a record,
in the one view a user goes to precisely because they trust it. Same reasoning for
`category`. The renderer keeps the column aligned so a scan down it answers "what actually
matters" without reading a single slug; that separation is the whole reason the fields
exist.

## Why the view never sorts or filters on tier or category

`/mentor:track` is the inventory of what's left. A view that quietly dropped the low tiers
or hid a category would make "what's remaining?" a lie exactly where it costs most, and it
would renumber the ordinals Step 2 resolves against — so "build 4" would point at a
different plan than the user was looking at. The tags exist to let a reader skip the noise
themselves, not to let the view decide for them.

## Why `gate: left uncontained` is excluded from the unparented-fix count

The `— ⚠ N unparented open fix(es) trace here` clause catches lineage without containment:
an open fix that names a plan through `deferred_from` but was never parented to it, which
`open_descendants` is structurally blind to because it walks `parent` only. Without the
clause, an `implemented` plan whose every confirmed defect was parked flat reads completely
clean — the wrong answer to "any fixes left under this plan?".

One exclusion is load-bearing. A stub whose sidecar note reads `gate: left uncontained` was
deferred by the user at `mentor:dispatch-agents`' non-goal disposition gate, where flat *is*
the answer they gave: the finding was judged not to block the plan's goal, which is
precisely why it is not a fix child. Counting it and then printing a hint telling the reader
to adopt it instructs them to undo a decision they already made — every session, forever.
`query`'s projection drops `note`, so the renderer re-reads the sidecars for that one field
rather than making each caller re-derive the exclusion with its own `grep`.

The count keys on `category: "fix"` for precision, so a legacy defect stub captured with no
category stays uncounted; `set-category <slug> fix` repairs that first.

## Why deps, group and parent are three separate axes

The render never blurs them, because they answer different questions:

- **`deps`** — "should happen before, elsewhere" (the `— deps:` clause, advisory only).
- **`group`/`order`** — "sibling of a split, same rank" (the `▸ group:` header).
- **`parent`** — "must close before its container reads done" (tree position, the root's
  open-descendant count, and the not-really-done warn).

Collapsing any two of them loses a distinction a user acts on. Draining a root's open
descendants in order is `/mentor:resume <root>`'s job — it walks the same descendants;
`/mentor:track` only ever shows the count and the warn.

## Why the ordinals are load-bearing

Group headers, handoff sublines, goal sublines and the repair-hint footer never consume an
ordinal, and numbering is depth-first so a root's fixes number immediately after it and
before the next top-level entry. Step 2 resolves a bare integer as a 1-based ordinal into
exactly this render. Anything that renumbers it — re-sorting, filtering, a second layout,
or a subline that quietly takes a number — makes the user's "build 4" resolve to a plan
they never pointed at. This is why `SKILL.md` says to print the output verbatim rather than
tidy it.

## Why `--open-counts` replaced the per-root walk

The open-descendant figure on every entry used to take one `subtree` call per root — 32
subprocesses and about five seconds on this repo before a single line was drawn, on a view
whose whole job is to be the fast answer to "what's left?". v2.33.0 folded it into one pass
over the parent graph, computed during the same scan `query` already makes. The flag is what
lets Step 1 be one call rather than one plus a walk, and it is why the roll-up clauses can be
rendered at all without the view becoming slow enough that people stop running it.
