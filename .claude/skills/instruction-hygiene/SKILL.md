---
name: instruction-hygiene
description: Prune the instruction debt a change just created in this marketplace repo — text that went stale, got duplicated, started contradicting another rule, or now costs context on every run without changing any decision. Anchors on the git diff, dispatches read-only instruction-hygiene-auditor agents by lens, auto-applies mechanical fixes (dead references, missed renames, narrative that belongs in references/rationale.md) and asks before deleting or merging any actual rule. Run it before every commit, ship, or publish touching plugins/<name>/, .claude/, or CLAUDE.md — including when /loom:publish-plugin, /loom:learn, /loom:audit-plugin or /mentor:ship is driving the release. Triggers include "clean up the instructions before publishing", "any stale or duplicate rules after this change", "this skill contradicts itself now", "SKILL.md got bloated", "/prune-instructions".
---

# Instruction Hygiene — prune what the change made stale, duplicate, conflicting, or too heavy

In this repo the instructions *are* the product. A change to one `SKILL.md` leaves debt in the
files it didn't touch: a reference to a step that got renumbered, a rule now stated in three
places, a root `CLAUDE.md` line that contradicts the new default, a paragraph of incident
narrative that every future invocation pays for. Nothing else here reads the corpus as a whole,
so that debt compounds silently until a skill starts giving conflicting orders mid-run.

This pass reads the change, finds the debt it created, and removes it — auto-applying the
mechanical fixes and asking before it deletes anything that constrains behavior.

**It is not the two neighbouring checks, and must not re-derive them:**

| Surface | Answers | Edits? |
|---|---|---|
| `/verify-plugin-edits <plugin>` | Does the text *parse and resolve*? JSON valid, `sh -n` clean, no hardcoded paths, tests green, no cross-block variable leaks, no name collisions | No |
| `plugin-consistency-reviewer` agent | Is the rewrite *correct*? do evals still trace, are step references intact | No |
| **this skill** | Is the corpus still *coherent and lean* after the change? | Yes |

## Where this sits in the pre-ship chain

1. **this skill** — semantic cleanup; it changes files.
2. `/verify-plugin-edits <plugin>` — mechanical validation of the result, **for edits under
   `plugins/<name>/` only**: every check it runs reads `plugins/$1/…`, so it never inspects
   `.claude/**` or root `CLAUDE.md`. A root-only prune has no automated step 2 — run the repo's own
   hook suites by hand instead (`.claude/hooks/tests/*.sh`).
3. `git commit` / `/loom:publish-plugin`.

That order is not cosmetic: this pass edits instruction files, so running it *after* validation
ships edits nothing checked. See `references/rationale.md` → **Order in the chain**.

---

## Step 1 — Anchor on the change

Every finding must trace to something this change did. An unanchored sweep turns into a rewrite
of the whole repo and buries the release under findings nobody asked for.

```bash
repo_root="$(git rev-parse --show-toplevel)" || exit 1
base="$(git -C "$repo_root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
base="${base:-develop}"

# Changed = committed-ahead-of-base + staged + dirty. Any of the three can hold the change:
# a publish flow commits per session before the bump, a hand edit is still dirty.
{
  git -C "$repo_root" diff --name-only "origin/${base}...HEAD" 2>/dev/null || \
    git -C "$repo_root" diff --name-only "${base}...HEAD" 2>/dev/null
  git -C "$repo_root" diff --name-only
  git -C "$repo_root" diff --cached --name-only
} | sort -u | grep -v '^$' > /tmp/ih-changed.txt

echo "== changed =="; cat /tmp/ih-changed.txt
echo "== plugins touched =="
sed -n 's#^plugins/\([^/]*\)/.*#\1#p' /tmp/ih-changed.txt | sort -u
```

No changed paths at all → say so and stop; there is nothing to prune. Plugin paths present →
those plugins are the targets. Only root paths (`CLAUDE.md`, `.claude/**`) → the repo's own
instruction surface is the target.

Read the actual diff of the changed instruction files (`git diff` / `git diff --cached` /
`git diff "origin/${base}...HEAD"` on those paths) before dispatching. The diff is what tells an
auditor *which side of a contradiction is the new intent* — without it, a conflict finding is a
coin flip.

## Step 2 — Build the review set: changed files plus their referrers

Debt lands in the files that *mention* what changed, not in the changed file. Collect them:

```bash
repo_root="$(git rev-parse --show-toplevel)" || exit 1
cd "$repo_root" || exit 1

# The instruction surface. Code (.sh/.py) is ground truth for "does this still exist",
# never text to prune — pruning a rule is an edit to prose, never to a script's logic.
find plugins .claude -type f \( -name '*.md' -o -name '*.json' \) 2>/dev/null > /tmp/ih-surface.txt
[ -f CLAUDE.md ] && echo "CLAUDE.md" >> /tmp/ih-surface.txt
[ -f .claude-plugin/marketplace.json ] && echo ".claude-plugin/marketplace.json" >> /tmp/ih-surface.txt

# Referrers of one symbol the change renamed/removed/redefined (skill name, command, flag,
# script, heading). Repeat per symbol; keep the symbol list short and derived from the diff.
sym='<symbol-from-the-diff>'
tr '\n' '\0' < /tmp/ih-surface.txt | xargs -0 grep -n -- "$sym" 2>/dev/null
```

Use `find … | xargs grep`, never a bare recursive `grep -r`: recursive greps are rewritten by
this machine's RTK hook, so a zero-hit result is not evidence that the term is gone. When a
sweep returns nothing for a symbol you *know* the diff touched, that is a broken sweep, not a
clean repo — fix the sweep before trusting any absence.

## Step 3 — Dispatch the auditors, right-sized

The lenses live in `references/lenses.md` under `## Common brief`, `## STALE lens`,
`## DUPLICATE lens`, `## CONFLICT lens`, `## OVER-INSTRUCTION lens`, and `## Return contract`.
Never paste a lens into the prompt — the reference is the single copy, and an auditor briefed
from a paraphrase drifts from the one briefed from the file.

- **Small change** (one file, one rule, a wording fix): **one** `instruction-hygiene-auditor`,
  all four lenses.
- **Escalate to four in one batch, one lens each**, when the change renames or removes a
  surface, spans multiple files, alters a hook or return contract, or moves a rule between
  files. Those are exactly the changes whose debt lands somewhere the author isn't looking.

Give each auditor: the changed-path list, the review set, the target's **design philosophy stated
explicitly** (read it from the plugin's README/`plugin.json` description — an auditor that
doesn't know what the plugin is *for* prunes rules that look odd and are load-bearing), the
`references/lenses.md` path with its assigned heading names, and the relevant diff hunks.

Pass **paths and diff hunks, not whole files** — the auditors read what they need; the main
thread holds only their findings.

## Step 4 — Classify every finding: SAFE or CONFIRM

**SAFE — apply without asking.** Each is a checkable fact about the working tree, not a judgment
about whether a rule is worth keeping:

- **Dead reference** — a path, skill/command name, script, flag, `§`/step anchor, or heading
  that is absent from the working tree. One obvious successor → rename; none → delete the clause
  that existed only to point at it.
- **Missed rename** — the old name still in prose while the diff shows the new one in use.
- **Verbatim or near-verbatim duplicate** of a block that also exists in an authority file,
  adding no extra constraint, threshold, or exception → delete the copy, leave a pointer by
  heading name.
- **Narrative in a file that loads every run** → **move** it to that skill's
  `references/rationale.md` under a `## ` heading and point at it by name, leaving the
  imperative rule plus one sentence of why. This repo's prose convention, and the reason
  `MOVE` exists as a fix type at all.
- **Intra-file contradiction the diff resolves** — a renumbered step, a renamed variable, a
  threshold changed in one sentence and not the other, where the diff shows the intended side.

**CONFIRM — never auto-apply:**

- Deleting or merging a **rule** — any imperative that constrains behavior.
- Resolving a **conflict between two rules** by choosing a side. The losing side may be the
  correct one; that call is the user's.
- Anything a **test, eval, or hook references** — the text is load-bearing by construction.
- Anything carrying an **incident story**: "this happened in practice", a version, a commit SHA,
  a measured cost. Those sentences were bought with a failure.
- Trimming a manifest or frontmatter **`description`** — `publish-plugin` owns those and their
  length rules.

**The load-bearing test, run before proposing any deletion** — answer all four, in the finding:

1. Does the working tree still contain what this text describes?
2. Does a test, eval, hook, or script name this text or the behavior it demands?
3. Is this the *only* copy of the constraint, or does an authority file state it too?
4. Would deleting it change what a future run does? (If yes — CONFIRM, always.)

A rule restated exactly at the decision point where it gets violated is **load-bearing
redundancy**, not duplication. Keep it, and record it in the `KEEP` list so the next run doesn't
re-propose it.

## Step 5 — Apply

**SAFE findings:** apply, then grep-confirm each edit landed (`find … | xargs grep -n` on the
new text and on the removed term). An edit reported as applied but silently missed is worse than
one not attempted — the report then certifies hygiene the corpus doesn't have.

**CONFIRM findings:** print one compact card each, then in the same turn ask:

```
## <#>. <lens> — <file>:<line>
**Says now:** <≤2 quoted lines>
**Caused by:** <the diff change that made this stale/duplicate/conflicting>
**Ground truth:** <what is actually on disk, or the competing rule's file:line>
**Load-bearing:** <the test/eval/hook that references it, or NONE — with the sweep that proved it>
**Proposed:** DELETE | MOVE→<dest heading> | REWRITE→<replacement> | RENAME→<new symbol>
**Cost if this call is wrong:** <one line>
```

- **One question per rule deletion or conflict resolution** — each is a standalone decision with
  a different downside, and a batched "approve all" hides which rule the user just dropped.
- **One batched multi-select for the rest** (relocations, pointer rewrites, cosmetic dedupes) —
  they diverge only in effort, so individual gates would be pure friction.
- Every question stands on its own: quote the text and name the file inline. The user must never
  have to leave the question to find out what they are approving.
- **Zero selection is a valid outcome** — apply nothing, report the findings, continue to ship.
- **Unattended callers never prompt.** When the driving flow says it is headless (`learn --headless`,
  the daily runner), apply the SAFE fixes and report every CONFIRM finding **unapplied** — in the
  release's commit body when a publish flow is driving. Blocking a run nobody is watching loses the
  release, and applying a rule deletion nobody approved is worse than leaving the debt one more day.

**Never `git add`, never `git commit`, never `git push`** from this pass. It leaves edits in the
working tree for the release flow to stage narrowly; whole-directory staging in this repo has
already swallowed unrelated in-flight work (`CLAUDE.md` → "Git staging safety around loom
automation").

## Step 6 — Verify the prune

Pruning instructions can break the machinery that reads them:

```bash
repo_root="$(git rev-parse --show-toplevel)" || exit 1
plugin='<target-plugin>'   # skip this block when the change was root-instructions only

find "$repo_root/plugins/$plugin/hooks/tests" "$repo_root/plugins/$plugin/tests" \
  -maxdepth 1 -name '*.sh' 2>/dev/null | while read -r t; do
  echo "== $t"; bash "$t" 2>&1 | tail -3
done
```

Then sweep **your own edits** for the debt you just created: every heading you pointed at must
exist, every renamed symbol must resolve, no pointer may name a file you deleted from.

Hand the mechanical checks to `/verify-plugin-edits <plugin>` — do not re-run its checks here.

## Step 7 — Report

```
## Instruction hygiene — <target>
**Anchor:** <N> changed instruction files vs origin/<base>
**Applied (safe):** <one line per fix — file:line, lens, what changed>
**Confirmed by you:** <one line per approved fix>
**Declined / left as-is:** <one line each, with the reason given>
**Deferred (nobody to ask — headless):** <one line per unapplied CONFIRM finding>
**Kept deliberately:** <load-bearing redundancy and rules that only looked stale — one line each>
**Not covered:** <any surface the pass did not reach, and why>

INSTRUCTION-HYGIENE: applied=<n> confirmed=<n> declined=<n> deferred=<n> kept=<n>
```

The final line is the one a release flow or a later session can cite as proof this ran. State
`Not covered` honestly — a silent gap reads as "the corpus is clean" when it was never read.

---

## Rules

- **Anchor on the diff.** Every finding names the change that caused it; a finding with no
  `Caused by:` is out of scope for this release, however true it is.
- **Prove staleness on disk.** A reference is stale only when a sweep shows the target absent,
  never because it reads as unfamiliar. See `references/rationale.md` → **Absence is not evidence**.
- **Move narrative; don't delete it.** The story is why the rule survives the next reader who
  finds it inconvenient — it just belongs in `references/rationale.md`, not in a file loaded
  every run.
- **Never auto-delete a rule.** Redundant-looking rules are usually the only copy of a guard a
  past incident paid for. See `references/rationale.md` → **The rule that looked redundant**.
- **Auditors are read-only.** They propose with evidence; the edit and the questions belong to
  this thread, which is the only place `AskUserQuestion` can run.
- **Bounded blast radius.** Touch only files the change touched or that reference it. A pass that
  rewrites untouched files is unreviewable inside a release diff.
- **No staging, no committing.** Hand the working tree back to the release flow.
- **Don't re-derive the mechanical gate.** `/verify-plugin-edits` owns JSON, syntax, paths,
  descriptions, tests, collisions. Duplicating its checks here is the exact debt this skill exists
  to remove.

## Done when

- The change was anchored (Step 1), the review set built including referrers (Step 2), and the
  diff read before dispatch.
- Auditors ran right-sized and read-only, briefed from `references/lenses.md` at its headings.
- Every finding is classified SAFE or CONFIRM with the four-question load-bearing test answered.
- SAFE fixes are applied and grep-confirmed; CONFIRM fixes were asked — one question per rule
  deletion or conflict, one batched question for the rest — and applied only where approved, or
  reported unapplied under `Deferred` when the caller was headless.
- The target's test suites still pass and this pass's own pointers all resolve.
- The report is printed with the `INSTRUCTION-HYGIENE:` line, `Kept deliberately` populated, and
  nothing staged or committed.
