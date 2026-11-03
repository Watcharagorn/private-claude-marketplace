---
name: playbook-retrospective
description: >
  Retrospective overlay a mentor plan run loads at planning Step 2 when the goal is a
  retrospective of a finished agent session; it never plans or approves on its own. It
  produces new skills, skill-body edits and description tunes, plus proposals it reports
  but does not apply. Turn a session into lessons: "retro", "retrospective", "reflect on
  this session", "lessons learned", "what should become a skill", "turn what I keep doing
  into a skill", "lessons from today's session", "look back over what we did", "worth
  saving as a reusable skill or a tweak to an existing one". Use it even when the thread
  looks empty, short, or compacted — the retro rebuilds the session from its transcript
  on disk, not from memory. For the current or one named session, prefer it over a batch
  harvester. On Claude Code the facade is "/mentor:retro". NOT for batch harvesting
  across many sessions (loom), NOT for changing code in a repo (playbook-software-change),
  and NOT for an ordinary plan (planning).
---

# Playbook — retrospective

Why these rules read as they do — including what was ported from pstack and deliberately
altered — is in `references/rationale.md` → **What was changed, and why**.

## Host portability

Use a structured question UI when the host offers one; otherwise ask the same focused question directly and wait for the answer. If delegated agents are unavailable or prohibited, perform the required research, review, or implementation serially and retain the same evidence, scope, and verification contract. Treat Mentor helpers as optional host integrations: resolve them with `PLUGIN_ROOT` first, then `CLAUDE_PLUGIN_ROOT`; if neither is available, work from the repository's durable `.mentor/` artifacts and report any state action that cannot be performed safely. This rule overrides later host-specific tool names, preserving user choice and plan continuity across hosts.

Planning's general flow never names transcripts, lenses, or skill authoring. This
playbook is where those live. Planning loads it when the goal is a retrospective,
records `## Playbook: playbook-retrospective` plus a decision-log row, and reads the
five overlays below. Nothing here replaces a planning rule; each overlay fills a slot
the general flow leaves open. This playbook is **never co-loaded with
`playbook-software-change`** — a retro delivers local edits, it does not ship code.

## Direct invocation

Triggered directly (a "retro"/"reflect on this session" ask, or on Claude Code
`/mentor:retro`), hand to planning with the goal `retrospective of session <id>` so
the run inherits the edit gate, the one approval, the decision log, the independent
verifier, and the Done review — because a retro that applied skill edits without that
gate would mutate skills before the user approved them.

## The five overlays

### 1. Research directives (planning Step 2)

Build the evidence graph, then run the lenses, then synthesize. The reviewers are
read-only; the **parent** persists each returned output immediately under `evidence/`:

1. Follow `references/evidence-graph.md` to write `evidence/manifest.json` and one
   digest per transcript. The session is rebuilt from disk, never from memory, because
   after compaction the parent's context holds only the latest summary.
2. Dispatch the three lenses — `references/lens-judgment.md`,
   `references/lens-tooling.md`, `references/lens-divergent.md` — as native subagents,
   in parallel when the host has them, else serially in-thread and labelled
   `self-graded`. Each lens returns its output read-only; the parent writes that return
   verbatim to `evidence/lens-judgment.md` / `evidence/lens-tooling.md` /
   `evidence/lens-divergent.md` the moment it lands. On restart the parent skips any
   lens whose evidence file already exists.
3. Run `references/synthesizer.md`; it returns the synthesis read-only and the parent
   writes it verbatim to `evidence/synthesis.md` (Coverage, Accepted, Rejected,
   Backlog, Leftovers), skipped on restart if that file already exists.

### 2. Definition of done (Goal check and `Done when:`)

Per Accepted row: the new or edited skill passes skill-creator's `quick_validate.py`;
its description triggers on the prompt that motivated the row; and when the destination
convention includes a symlink (e.g. `.claude/skills/<name>` plus a relative
`.codex/skills/<name>` link), that link is relative and resolves (checked with
`readlink` / `readlink -f`). An in-repo edit (`plugins/*/skills/`) or a destination
with no symlink has no symlink check. A row is not ticked until its own check passes.

### 3. Extra always-pause items (the run)

A union with the constitution's list — nothing here removes an item:
- Committing or pushing (this playbook delivers local edits only).

Lessons that contradict a plugin core concept, change the constitution, or change
another tool's config (e.g. agt roles) are never applied and never paused on — they go
to the Done review's Leftovers and the run continues.

### 4. Deliver mode (the run's deliver state)

Local edits only, then the Done review — never ship, never merge. Leftovers carry the
Backlog items, the constitution proposals, the core-concept proposals, and the other-tool
proposals the synthesizer sorted out. The run is `done` when the Accepted rows are
applied and graded and the Leftovers are reported.

### 5. Evidence kinds (the Done review)

Per Accepted row, prefer: `quick_validate.py` output; the trigger check on the
motivating prompt; `readlink` / `readlink -f` of each new skill's symlink, when its
destination has one; and the Coverage table in `evidence/synthesis.md` showing every node and
epoch `read`, `opaque` (with its `opaque_reason`), or `skipped` with a reason.

## Where outputs land

- **New skills follow the workspace's documented skill-storage convention** (its
  `CLAUDE.md` / `AGENTS.md`), e.g. `.claude/skills/<name>` plus a **relative**
  `.codex/skills/<name>` symlink pointing at it. With none documented, write
  `.claude/skills/<name>` on Claude Code. On Codex, or when a Codex copy is wanted, a
  project-skill path is not promised: report it as a Leftover with the path to verify.
- **Installed plugin skills are copied to the workspace and the copy is edited** —
  never edit a plugin cache in place.
- Inside this marketplace repo, edit `plugins/*/skills/` directly, under the repo gates.
