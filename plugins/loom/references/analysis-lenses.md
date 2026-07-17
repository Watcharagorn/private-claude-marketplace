# Analysis lenses — shared AUDIT / ENHANCE briefs

Two skills read this file: **`audit-plugin`** (the AUDIT lens only, over one session) and **`learn`**
(both lenses, over every unanalyzed session). Keeping the briefs here — not inlined in either skill —
means there is exactly **one** wording of each lens, and a per-session analysis agent can read the brief
it needs straight from this file.

Each brief is dispatched to an `Explore`/sonnet subagent given **paths only, never transcript contents**
(chassis §C). A subagent locates the brief it needs by the **literal heading text** below (never by step
number) and **fails loud** if an anchor is missing — it never guesses a brief. The dispatching skill may
wrap the return in its own envelope (a per-session header, a `lens:` tag, a top-N cap); the analysis
itself is defined once, here.

> **CRITICAL — subagents are proposal-only.** A lens subagent cannot call `Skill()` or
> `AskUserQuestion`. Every lens does **ANALYSIS → PROPOSALS ONLY**: no implementing, no asking the user,
> no publishing. The interactive + mutating tail (merge, review, the one question, implement, publish) is
> owned by the dispatching skill.

## Common parse brief

Give this to **every** lens. The JSONL is one `{type, message, timestamp, ...}` object per line;
assistant tool calls live in `message.content[]`; attribution, when present, in `attributionSkill` /
`attributionPlugin`. When attribution is sparse (older transcripts), infer plugin usage by clustering the
invocation timeline and reading `subagents/*.meta.json`.

## Agent A — AUDIT lens

Reconstruct how the selected plugin was actually used and surface **every gate block, error, retry,
workaround, wrong-skill call, redundant question, or post-run discrepancy** — these are the bugs.
Cross-reference the plugin source (`plugins/<selected>/` manifest, `commands/*.md`, `skills/*/SKILL.md`,
`hooks/*` incl. gate scripts) to pin each to a root cause. Return **candidate FIX proposals**, each with
**Observation** (transcript line ref) · **Root cause** (`file:line`) · **minimal change sketch** ·
**type** (bug | enhancement) · **severity** (P1 user-blocking false-positive / lost work · P2 friction /
wrong default · P3 latent inconsistency). Classify gate false-positives, wrong-skill calls, and
workarounds as **bugs**; missing reminders, redundant prompts, ergonomics as **enhancements**.

> **AUDIT self-notice — new domain-visualization skill.** For plugins with a per-domain plan-render
> registry (e.g. `mentor`'s `plan-domain-*`): if the audited artifact would have been materially
> faster/safer to review had a **dedicated domain visualization** existed that no registered
> `plan-domain-*` provides (a standard idiom — architecture/C4, data-model/ER, state-machine, sequence,
> deployment/topology), raise an **enhancement** proposing a **new `plan-domain-<name>` skill**
> (fire-condition + explicit "skip when"; the idiom/levels it renders — render only changed levels; the
> render rule: polished self-contained HTML, diff-highlighted, no ASCII). A new domain is a **minor**
> bump. Skip this notice for plugins without such a registry.

## Agent B — ENHANCE lens

Cluster the session by **user intent / workflow** and surface **FRICTION** — prompts re-typed
near-verbatim, multi-step macros walked by hand 2+ times, copy-paste fix-ups, manual glue between the
plugin's steps — each with a **recurrence count**. Read the selected plugin's surface (manifest,
`commands/*.md`, `skills/*/SKILL.md`, `agents/*.md`, `hooks/*` incl. `hooks.json`) to find **GAPS** where
that friction has no home today (each pinned to a `file:line`, or "no such file"). Return
**optimal-workflow + artifact-set proposals**: for each, the **OPTIMAL WORKFLOW** as *before → after*,
plus the **artifact(s)** `[type · create|edit · path under plugins/<selected>/ · role]`, each tracing to
an **Observation** (transcript line ref) AND a **Gap** (`file:line`), with **recurrence/impact** and the
**catalog row/pairing** (§D) that justifies the type + strategy.

## Return contract

Every lens keeps the main thread lean (§C) and returns: **FINDINGS** (≤400 words each) / **EVIDENCE**
(`file:line` refs only) / **OPEN QUESTIONS**. When a dispatching skill runs a lens per session, it wraps
this with a `SESSION: <id> · <project> · <end-date>` header, tags each finding `lens: audit|enhance`, and
may cap at the top few per lens — but the finding shape above is unchanged.
