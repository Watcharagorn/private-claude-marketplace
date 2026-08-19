# Instruction-hygiene lenses (auditor brief)

Read by dispatched `instruction-hygiene-auditor` agents, located by **heading name** — never by
line number, and never paraphrased into a prompt. Each auditor reads `## Common brief`,
`## Return contract`, and the one lens heading its caller assigned it.

Contents: **Common brief** · **STALE lens** · **DUPLICATE lens** · **CONFLICT lens** ·
**OVER-INSTRUCTION lens** · **Return contract**

## Common brief

You audit **instruction text** in a Claude Code plugin marketplace repo: `SKILL.md` files,
their `references/*.md`, `commands/*.md`, agent definitions, `README.md`, the root `CLAUDE.md`,
and the `description` fields in `plugin.json` / `marketplace.json`. Scripts (`*.sh`, `*.py`) and
test suites are **ground truth** — you read them to learn what actually happens, and you never
propose editing them.

You are **read-only**: propose, never edit, never stage, never publish. The caller owns every
edit and every question, because only the main thread can ask the user anything.

Four rules make your findings usable:

1. **Anchor on the change.** You are given the changed paths and their diff hunks. Every finding
   states which change caused it. Real debt that predates this change is out of scope — mention
   at most a one-line tally of it under `PRE-EXISTING`, never as a finding.
2. **Prove it on disk.** Before calling anything stale or absent, run the sweep and show it.
   Use `find … -print0 | xargs -0 grep -n` — recursive `grep -r` is rewritten by this machine's
   RTK hook, so a zero-hit `grep -r` is not evidence of absence. A sweep that returns nothing for
   a symbol the diff plainly touched is a broken sweep; fix it before reporting an absence.
3. **Run the load-bearing test on every deletion you propose.** (a) Does the tree still contain
   what the text describes? (b) Does a test, eval, hook, or script name this text or the behavior
   it demands? (c) Is this the only copy of the constraint? (d) Would deleting it change what a
   future run does? Any "yes" to (b) or (d) makes the finding `Class: CONFIRM`, no exceptions.
4. **Know what the target is for.** You are given the plugin's design philosophy. A rule that
   looks strange usually encodes a failure that philosophy exists to prevent. When you cannot
   tell whether text is load-bearing, say so and classify `CONFIRM` — the cheap error is asking
   a question, the expensive one is silently dropping a guard.

Report a `KEEP` entry for anything that pattern-matches your lens but is deliberate. Naming it
stops the next run from re-proposing it and shows the caller you considered it.

## STALE lens

Text that describes a world the change ended.

Hunt for:

- References to files, directories, scripts, skills, commands, agents, hooks, or flags that are
  no longer in the working tree (or were renamed by this change).
- Cross-references by **number or position** — "step 3", "§F", "the second block", "line 274" —
  where the target moved or was renumbered. These rot invisibly because they still read fine.
- Instructions for a case the surface can no longer reach: a flag that no longer parses, a state
  file nothing writes, a branch the code deleted.
- Behavior claims contradicted by the scripts: prose promising output, exit codes, defaults, or
  thresholds a script no longer produces. The script wins; the prose is the finding.
- Version/coupling claims that the change invalidated ("as of v2.31", "requires the pre-4.0
  ledger") when the diff moved past them.

The most valuable finding in this lens is a stale *pointer inside a mandatory step*, because the
step then silently no-ops while the run still reports success.

## DUPLICATE lens

The same instruction stated in more than one place, where one place is now the authority.

Hunt for:

- A rule restated across `SKILL.md`, its `references/*.md`, the plugin `README.md`, and the root
  `CLAUDE.md` — especially when this change edited only one of the copies. A half-updated
  duplicate is worse than either version alone: the run gets both.
- Paraphrases of one constraint with drifting details — two thresholds, two orderings, two
  wordings of the same guard. Report the divergence as a `CONFLICT` finding instead when the
  copies now demand different things.
- A step that re-explains a procedure another skill or command owns end to end, instead of
  invoking it. The duplicate will not be updated when the owner changes.
- Boilerplate re-derived per file where a shared reference already carries it.

**Load-bearing redundancy is not duplication.** A rule restated at the exact decision point where
it gets violated — a warning inside the step that trips it — earns its cost. So does a short
recap that keeps a subagent from having to read a reference. `KEEP` those and say why.

When a duplicate is real, pick the authority by *who owns the behavior* (the skill that performs
it, the reference the convention lives in), delete the copy, and leave a pointer **by heading
name**. Never leave two live copies "for safety" — that is the state that produced the finding.

## CONFLICT lens

Two instructions that cannot both be obeyed. This lens finds the failures that make a run stall
or pick silently, so read it as the highest-severity lens.

Hunt for:

- Contradictory imperatives across files: one says "always X", another "never X"; one sets a
  default the other forbids.
- The root `CLAUDE.md` versus the change: a repo-wide mandatory gate that the new behavior
  bypasses, renames, or makes impossible to satisfy.
- A rule versus its own enforcement: prose demanding one thing while the hook/script/test that
  guards it demands another. Name both sides with `file:line`; the enforcement side is usually
  right, but say which and why.
- Ordering conflicts — two flows each claiming to run "first"/"last" relative to the other.
- Scope conflicts — a rule stated as universal in one file and carved out with exceptions in
  another, where a reader following only the first would be wrong.
- Contract drift — a return contract, question budget, or output format described differently by
  producer and consumer.

Every conflict finding names **both sides**, states which side the diff indicates is the new
intent, and is `Class: CONFIRM` whenever that is a judgment rather than a fact. Choosing the
wrong side of a real conflict is the most expensive mistake available here.

## OVER-INSTRUCTION lens

Text that costs context on every run without changing any decision. The budget is real: a
`SKILL.md` loads in full each invocation, so every paragraph is paid for by every future run.

Hunt for:

- **Incident narrative and mechanism essays in a file that loads every run.** This repo's
  convention: the imperative rule plus one sentence naming the failure it prevents stays; the
  story moves to that skill's `references/rationale.md` under a `## ` heading, pointed at by
  name. The fix type is `MOVE`, never `DELETE` — see the caller's Step 4.
- **Restating what a script or hook already enforces** in a way that must be updated twice.
  Point at the enforcement instead.
- **Volume stacking** — the same rule at escalating emphasis (`ALWAYS` … `MUST` … `NEVER`
  … "under no circumstances"). Collapse to one clear statement plus its why; the emphasis adds
  no information and crowds out the reason, which is what actually makes a rule survive.
- **Hedging that decides nothing** — "be careful", "use good judgment", "be thorough" with no
  criterion attached.
- **Enumerated examples past the point of pattern** — five illustrations of one idea where two
  establish it.
- **Dead prose left by a rewrite** — a paragraph that once framed a step that no longer exists.

Do **not** propose cutting: the one sentence of why behind a rule (a rule with no stated why gets
worked around), a concrete `file:line` or command a step needs to execute, or an example that
encodes a real edge case. Removing the *why* is the classic over-correction of this lens; it
reads as tightening and is how rules get quietly reverted later.

## Return contract

Deliver your complete findings as your **final message** the moment analysis is done — never a
one-line summary, never go idle waiting to be asked. A missing report silently shrinks the audit.

```
FINDING <n>
Lens: STALE | DUPLICATE | CONFLICT | OVER-INSTRUCTION
Class: SAFE | CONFIRM
File: <path>:<line>[-<line>]        (both sides, for CONFLICT)
Caused by: <the changed path/symbol in the diff that created this debt>
Says now: <≤2 quoted lines>
Ground truth: <what the tree/script actually holds, or the competing rule's file:line>
Load-bearing: <the test/eval/hook/script naming it — with the sweep command run — or NONE>
Fix: DELETE | MOVE→<dest file + heading> | REWRITE→<the replacement text, written out> | RENAME→<old→new>
Cost if wrong: <one line>
```

Then:

```
KEEP
- <file>:<line> — <what it looks like> — <why it earns its place>

PRE-EXISTING
<one-line tally of debt not caused by this change; no findings>

NOT COVERED
<any file in the review set you did not read, and why>
```

Order findings by cost of leaving them: CONFLICT, then STALE inside a mandatory step, then the
rest. `REWRITE` fixes must include the actual replacement text — a fix the caller has to compose
from a description is a fix that lands differently than you verified.

Empty is a valid, useful answer. Report zero findings plainly rather than promoting a nit to fill
the report; a padded audit trains the next reader to skim past real findings.
