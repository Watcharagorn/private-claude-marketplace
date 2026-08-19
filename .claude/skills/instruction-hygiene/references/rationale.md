# Instruction hygiene — rationale

Read this when a rule in `SKILL.md` looks wrong and you are about to change it, or when editing
this skill. It is deliberately not part of the skill's run-time context — which is the same
convention this skill enforces on everything else in the repo.

## Order in the chain

The pre-ship chain is hygiene → `/verify-plugin-edits` → commit/publish, and the order is
load-bearing in one direction only.

This pass *edits* instruction files: it deletes dead pointers, renames symbols, moves narrative
between files, rewrites clauses. Every one of those edits is exactly the kind of thing
`/verify-plugin-edits` exists to catch when it goes wrong — a moved block that breaks a
cross-block bash variable, a rewritten description that overruns the length cap, a deleted
reference that leaves a dangling pointer, a relocated heading nothing points at any more.

Run mechanical validation first and the release ships this pass's edits unchecked. Run it second
and the edits are covered by the same gate as the original change.

That coverage holds only for changes under `plugins/<name>/`. `/verify-plugin-edits` is
plugin-scoped — every check it runs reads `plugins/$1/…` — so a root-only prune, editing `.claude/**`
or `CLAUDE.md` as this skill's own files do, has no step 2 at all; the repo's root hook suites have
to be run by hand. Extending that command to a root scope is the real fix and is not done yet. The cost of the wrong order is
invisible at commit time and shows up as a broken skill on install, which is the worst place to
find it.

## Absence is not evidence

The most tempting bad finding in this skill is "this reference is stale, the target is gone" based
on a search that never really ran.

On this machine a recursive `grep -r` is intercepted and rewritten by the RTK hook, so a
zero-result recursive grep says nothing about the repo. The same trap has other doors: a bare glob
(`for f in plugins/*/skills/*.md`) aborts under zsh's `nomatch` when one search root is missing,
silently covering nothing while reporting success; a search rooted one directory too deep misses
every hit; a symbol spelled with a different quoting style in the file than in the query returns
clean.

Every one of those failures looks identical to "the term is gone" — and the fix this skill would
then apply is a deletion. So a stale finding must show the sweep that proved absence, using
`find … -print0 | xargs -0 grep -n`, and a sweep that comes back empty for something the diff
plainly touched is treated as a broken sweep rather than a clean repo.

## The rule that looked redundant

Rules in this repo are mostly sediment: something went wrong, and the rule plus its story was
added so it would not go wrong again. That history is invisible in the text — a hard-won guard and
a stray sentence read exactly alike a year later, and the guard often reads *worse*, because it is
oddly specific and inconveniently placed.

That is why deleting or merging a rule is never a SAFE class here, no matter how redundant it
looks, and why the load-bearing test asks whether a test, eval, hook, or script names the
behavior: enforcement is the fingerprint of a rule that was bought with a failure. The repo has
concrete instances — a skill/command name collision that made a skill body silently not load, a
`${CLAUDE_PLUGIN_ROOT}` hook path rule that keeps every hook from going inert on install. Both
look like pedantry until you know the incident.

The asymmetry decides the default: a needless question costs the user one keystroke, while a
silently dropped guard costs the incident again, at the worst moment, with nobody remembering the
rule ever existed.

## Why agents, and why they cannot edit

Detecting this debt is a reading problem across many files, and the reading is what does not fit
in the release thread's context. Handing each lens to its own read-only auditor keeps the corpus
out of the main thread — only the findings come back — and keeps the lenses from contaminating
each other: an agent hunting duplicates finds different things than one hunting conflicts, and one
agent told to do both tends to report whichever it hit first.

They stay read-only for two reasons. `AskUserQuestion` only works in the main thread, so an
editing auditor would have to decide alone exactly where a human call is required. And a subagent
that edits reports "done" while the caller never sees what changed — the same failure mode that
makes delegating a whole ship step a mistake. Propose in the agent, decide and edit in the thread.

## Why the auto-apply line sits where it does

The split is not by risk-of-breakage; it is by **who can be wrong about it**.

A SAFE fix is a claim about the working tree: the file is absent, the step number moved, this
block is a verbatim copy of that one, this paragraph is narrative. Those are checkable, and a
question about them is pure friction — the user has no information the sweep lacks.

A CONFIRM fix is a claim about intent: this rule is not worth its cost, this side of the
contradiction is the right one, this constraint is safe to drop. Nothing in the tree settles
those. Asking is not caution there, it is the only way to get the answer.

That is also why relocations are batched into one question while rule deletions are asked one at a
time: batching items that differ only in effort saves keystrokes, but batching decisions that
differ in *consequence* hides the one the user would have refused.
