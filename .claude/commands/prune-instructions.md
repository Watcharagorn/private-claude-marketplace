---
description: Prune the instruction debt a change created — stale, duplicate, conflicting, over-instruction — before commit/ship/publish
argument-hint: [plugin]
allowed-tools: [Bash, Grep, Read, Edit, Agent, AskUserQuestion, Skill]
---

# Prune Instructions

Run this repo's mandatory pre-ship instruction-hygiene pass. Arguments provided: $ARGUMENTS

- `$1` = plugin name (e.g. `mentor`, `loom`). **Optional, and additive** — it names which plugin to
  audit; changed root `CLAUDE.md`/`AGENTS.md`/`.claude/**` are always included regardless. When
  omitted, the target is derived from the change itself (the `plugins/<name>/` paths in the diff;
  root-only changes target `CLAUDE.md`, `AGENTS.md` and `.claude/`). A root-only prune that touched
  `.claude/**` or `CLAUDE.md` is then validated with `scripts/verify-plugin-edits --root`; no
  verifier mode reads `AGENTS.md`.

## What to do

Invoke `Skill(skill="instruction-hygiene")` and follow it end to end, passing `$1` as the target
when given. The skill owns the workflow: anchor on the diff, build the review set, dispatch the
read-only `instruction-hygiene-auditor` agents by lens, auto-apply the mechanical fixes, ask before
deleting or merging any rule, verify, and report.

Do not re-derive its steps here, and do not shortcut to a hand sweep of the diff — the whole point
is that a single reader skimming their own change is precisely what misses debt in the files they
did not touch.

## Where it sits

`CLAUDE.md` → **Instruction hygiene gate** owns the chain and its ordering; the skill restates it at
the point of use. Don't re-derive it here.

This command never stages or commits. It hands the working tree back for the release flow to stage
narrowly.
