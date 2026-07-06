---
name: tune-plugin
description: Improve an EXISTING plugin from a real session — one skill, three lenses. AUDIT finds how the plugin misbehaved (gate false-positives, wrong-skill calls, retries, post-run surprises) and ships fixes; ENHANCE finds the redundant/manual work the user did around the plugin and ships an optimal workflow + artifact set; BOTH runs the two lenses in parallel, merges/dedupes, and ships one consolidated release. Selects the target plugin once (auto by purpose-match, or the named one), expert-reviews, confirms via one multi-select, implements per artifact-catalog safety, and publishes one version bump. Invoke for "tune/optimize <plugin> from session <id>", "audit <plugin> against session <id>", "fix <plugin> based on session <id>", "enhance <plugin> from session <id>", "make <plugin> eliminate the redundant work I did", "audit and enhance <plugin>", or "/tune-plugin | /audit-plugin | /enhance-plugin <session-id> [plugin]".
version: 0.2.0
---

# Tune Plugin — audit and/or enhance an existing plugin (from a session)

Turn a real working session into a shipped improvement of **ONE existing plugin**. This is a single
skill with a selectable **lens**:

- **AUDIT** — find how the plugin *misbehaved* (gate false-positives, wrong-skill calls, retries,
  post-run surprises) and propose **fixes**.
- **ENHANCE** — find the *redundant / manual* work the user did *around* the plugin and propose an
  **optimal workflow + artifact set** that eliminates it.
- **BOTH** (default) — run the two lenses **in parallel**, **merge/dedupe** their proposals, and ship
  a **single consolidated release**. Run separately, the lenses would each select a plugin, each ask
  their own questions, each review, and each publish — so when fixes and enhancements touch the **same**
  plugin you get merge conflicts, double questions, and two releases. BOTH removes that waste.

Everything except the two lens contracts (Step 2) lives in the shared chassis — **read it first**:
resolve it by glob and `Read` it, then reference its sections (§A … §J).

```bash
common="$(find .claude/skills plugins -path '*/references/session-plugin-common.md' 2>/dev/null | head -1)"
echo "${common:-NO_COMMON}"
```

> **Jargon, defined once.** *Transcript* = the JSONL log of a past session under
> `~/.claude/projects/`. *Audit fix* = a correctness change for observed misbehavior. *Enhancement* =
> an artifact/workflow that removes repeated manual work. *Friction / redundancy* = work the user
> repeated by hand (re-typed prompts, manual multi-step macros, copy-paste fix-ups). *Artifact* = a
> Claude Code customization (skill, command, subagent, hook, permission, rule); the **artifact
> catalog** (§D) is the authority on which type fits. *Plugin surface* = everything a plugin declares —
> its commands, skills, agents, hooks.

## When to invoke

- "tune/optimize `<plugin>` end-to-end from session `<id>`" · "audit **and** enhance `<plugin>`" → **BOTH**
- "audit `<plugin>` against session `<id>`" · "fix `<plugin>` based on session `<id>`" → **AUDIT**
- "enhance `<plugin>` from session `<id>`" · "make `<plugin>` eliminate the redundant work I did" → **ENHANCE**
- User types `/tune-plugin` (BOTH) · `/audit-plugin` (AUDIT) · `/enhance-plugin` (ENHANCE)

## When NOT to invoke

- **No session to learn from.** Every lens is evidence-driven — it reads a *real* transcript, not a
  hypothetical. For a feature with no session, use `/mentor:plan`.
- **You want a NEW plugin from the session**, not an improvement to an existing one → use
  `harvest-to-plugin` (it starts from a session and packages a plugin).
- **The redundancy isn't plugin-shaped** (belongs in a user/project artifact, not inside any one
  plugin) → use `harvest-automations` (a sibling skill in this plugin), which works over the whole session and does not publish.
- The target plugin lives outside this marketplace repo (the publish step assumes `plugins/<name>/`).

## Inputs

- **`$1` — session ID** (UUID, e.g. `e05bde45-3ed9-458d-9a2e-ba6744d64a18`), or a transcript path.
- **`$2` — plugin name** (optional, e.g. `mentor`). If omitted, the skill auto-selects the optimal
  target plugin by matching the session against each plugin's declared purpose.
- **lens** — `audit` | `enhance` | `both`. Set by the invoking command (`/audit-plugin` → audit,
  `/enhance-plugin` → enhance, `/tune-plugin` → both). **Default `both`** when invoked directly.

---

## Step 1 — Resolve the transcript, build the purpose map, select the target plugin ONCE

Follow the shared chassis **§A** (resolve transcript + subagents), **§B** (build the plugin-purpose
map), and **§C** (never read the whole transcript in the main thread). The selection happens **once**
here and is shared by whichever lens(es) run — never let two lenses select independently.

Then **select the target plugin**:

- **`$2` given** → validate it exists (`test -d plugins/<name>`). If it does, use it; if not, tell the
  user and ask for a valid one.
- **`$2` omitted** → score each plugin by `invocation count × purpose-matched friction/misbehavior`
  using the §B map (a quick streamed pass with `jq -c` / `python3`, summaries only). **Unambiguous**
  top score → auto-pick and say why (cite score + purpose match). **Ambiguous** (top two close, or the
  session spans plugins) → confirm with **one** `AskUserQuestion`, labelling each option with the
  plugin name **and** its purpose from the map, so the user chooses against real plugin jobs. A skill
  may call `AskUserQuestion`; this is why selection lives in the main thread, not a subagent.

## Step 2 — Run the lens(es): dispatch the analysis subagent(s)

Each lens is an `Explore` subagent (sonnet) given the **main transcript PATH**, the **subagents dir
PATH**, the **selected plugin** (and root `plugins/<selected>/`), and the **§B purpose map** as text —
**paths only; never the transcript contents** (§C).

> **CRITICAL — subagents are proposal-only.** A subagent cannot call `Skill()` or `AskUserQuestion`.
> Every lens does **ANALYSIS → PROPOSALS ONLY**: no implementing, no asking the user, no publishing.
> The interactive + mutating tail (merge, review, the one question, implement, publish) is owned by
> this skill (Steps 3–7).

**Common parse brief (give to every lens):** the JSONL is one `{type, message, timestamp, ...}` object
per line; assistant tool calls live in `message.content[]`; attribution, when present, in
`attributionSkill` / `attributionPlugin`. When attribution is sparse (older transcripts), infer plugin
usage by clustering the invocation timeline and reading `subagents/*.meta.json`.

**Dispatch by lens:**

- **lens = both** → issue **both** `Agent` calls in a **single message** so they run concurrently in
  isolated contexts.
- **lens = audit** → dispatch only Agent A.
- **lens = enhance** → dispatch only Agent B.

**Agent A — AUDIT lens.** Reconstruct how the selected plugin was actually used and surface **every
gate block, error, retry, workaround, wrong-skill call, redundant question, or post-run discrepancy**
— these are the bugs. Cross-reference the plugin source (`plugins/<selected>/` manifest,
`commands/*.md`, `skills/*/SKILL.md`, `hooks/*` incl. gate scripts) to pin each to a root cause. Return
**candidate FIX proposals**, each with **Observation** (transcript line ref) · **Root cause**
(`file:line`) · **minimal change sketch** · **type** (bug | enhancement) · **severity** (P1
user-blocking false-positive / lost work · P2 friction / wrong default · P3 latent inconsistency).
Classify gate false-positives, wrong-skill calls, and workarounds as **bugs**; missing reminders,
redundant prompts, ergonomics as **enhancements**.

> **AUDIT self-notice — new domain-visualization skill.** For plugins with a per-domain plan-render
> registry (e.g. `mentor`'s `plan-domain-*`): if the audited artifact would have been materially
> faster/safer to review had a **dedicated domain visualization** existed that no registered
> `plan-domain-*` provides (a standard idiom — architecture/C4, data-model/ER, state-machine, sequence,
> deployment/topology), raise an **enhancement** proposing a **new `plan-domain-<name>` skill**
> (fire-condition + explicit "skip when"; the idiom/levels it renders — render only changed levels;
> the Step 8 render rule: polished self-contained HTML, diff-highlighted, no ASCII). A new domain is a
> **minor** bump. Skip this notice for plugins without such a registry.

**Agent B — ENHANCE lens.** Cluster the session by **user intent / workflow** and surface **FRICTION**
— prompts re-typed near-verbatim, multi-step macros walked by hand 2+ times, copy-paste fix-ups,
manual glue between the plugin's steps — each with a **recurrence count**. Read the selected plugin's
surface (manifest, `commands/*.md`, `skills/*/SKILL.md`, `agents/*.md`, `hooks/*` incl. `hooks.json`)
to find **GAPS** where that friction has no home today (each pinned to a `file:line`, or "no such
file"). Return **optimal-workflow + artifact-set proposals**: for each, the **OPTIMAL WORKFLOW** as
*before → after*, plus the **artifact(s)** `[type · create|edit · path under plugins/<selected>/ ·
role]`, each tracing to an **Observation** (transcript line ref) AND a **Gap** (`file:line`), with
**recurrence/impact** and the **catalog row/pairing** (§D) that justifies the type + strategy.

**Return contract (every lens — keep the main thread lean, per §C):** **FINDINGS** (≤400 words each) /
**EVIDENCE** (`file:line` refs only) / **OPEN QUESTIONS**.

## Step 3 — Merge / dedupe + composing-entry-point self-notice

Hold only the distilled return(s) in the main thread and build **one** proposal list.

- **lens = both** → combine audit fixes **and** enhancements and **collapse overlaps:**
  - **Same file, same root issue** (an audit fix and an enhancement touch the **same** location) →
    **merge** into a single item whose change satisfies both, so implement never double-edits the same
    lines and the release never has two conflicting diffs for one file.
  - **Subset / superset** → keep the superset, note the absorbed item.
  - **Genuinely independent** → keep separate.
  Tag each item with its **lens** (audit | enhance | both) so the review and card stay legible.
- **single lens** → merge/dedupe is a passthrough; just order the items.

Then **order by impact** (P1 fixes and high-recurrence enhancements first). Run the
**composing-entry-point self-notice** once over the (combined) set: *would the result still be manual
stitching unless a single composing entry point — one command/skill that drives the others end to end
— existed, where none does today?* If **yes**, add one thin command/skill (per §D's legitimate
pairings). If **no** (the existing surface already composes the pieces), say so and add nothing — that
is the cleaner answer. Enforce **MINIMALITY**: the smallest set that fixes the bugs and kills the
redundancy; every artifact load-bearing; prefer **editing** an existing plugin file over a
near-duplicate; honor the catalog's bundle anti-patterns.

## Step 4 — Expert review

Review the whole set **once** (never one review per lens). Follow shared chassis **§H** (one reviewer
by default; escalate to the practicality / comprehensiveness / cleanliness trio for a non-trivial set —
any hook, multiple artifacts, a settings merge, or fixes + enhancements touching the same surface).
State the selected plugin's **design philosophy** explicitly to the reviewer(s), and check that merged
items are genuinely merged (not double-editing one file). Fold verdicts back into the set.

## Step 5 — Confirm with the user

Follow shared chassis **§I**: print a compact card per item (tagged by lens when BOTH), then
**immediately** call **one** `AskUserQuestion` **multi-select** in the same turn. Zero selection → a
clean **no-op** (nothing materialized, nothing published).

## Step 6 — Implement the selected items

Resolve the artifact catalog (§D) and implement in `plugins/<selected>/` using the per-type write
safety (**§E**), the `${CLAUDE_PLUGIN_ROOT}` hook rule (**§F**), and the pre-publish validation
(**§G**) — embedded-Python compile + JSON validate, then grep each target file to confirm the change
landed. For **merged (audit+enhance) items**, apply the single combined change to the shared file
**once** — never let the two intents produce two edits to the same lines.

## Step 7 — Publish ONCE

Follow shared chassis **§J**: invoke `publish-plugin` with the plugin + one consolidated bump as
**intent** (highest class present: new artifact surface → minor; bug-only → patch; breaking → major).
Report the new version + the `old..new` push line on the default branch, and advise `/reload-plugins`.

---

## Rules

- **Lens drives the fan-out.** `both` → both agents in one message; `audit`/`enhance` → that one agent.
  Select the target plugin **once** (Step 1); everything downstream (merge, review, one question,
  implement, one publish) is lens-agnostic.
- **Subagents return PROPOSALS ONLY** — no `Skill()`, no `AskUserQuestion`, no implementing, no
  publishing. This skill owns the merge, the review, the one question, the implement, and the publish.
- **Evidence over assumption** — every item traces to an **Observation** (transcript line ref) AND a
  **Gap / Root cause** (`file:line`). No speculative additions.
- **One review, one selection, one implement, ONE publish / version bump** — even for BOTH. Merged
  items edit a shared file once. One plugin per publish.
- **Honor the shared chassis** — §C (no whole-transcript reads in the main thread), §D (catalog by
  glob, inline fallback if absent), §E/§F (per-type write safety; `${CLAUDE_PLUGIN_ROOT}` hooks), §G
  (validate embedded Python + JSON, grep-confirm), §H (mandatory right-sized review) — plus MINIMALITY
  per Step 3.

## Done when

- The transcript + subagents were resolved (§A); the purpose map was built (§B); the target plugin was
  selected **once** (validated when `$2` given, auto-picked or `AskUserQuestion`-confirmed otherwise);
  no raw transcript was read in the main thread (§C).
- The lens(es) implied by the invocation ran in proposal-only subagents (both → in one message); the
  set was merged/deduped, ordered by impact, and the composing-entry-point self-notice ran.
- The set was expert-reviewed once (§H) and revised per the verdicts; the user confirmed via one
  multi-select `AskUserQuestion` (§I).
- **Then either:** the selected items were applied per §E/§F, validated per §G (embedded Python + JSON),
  grep-confirmed, and **published once** via `publish-plugin` (§J) — new version + push reported, user
  advised to run `/reload-plugins`;
- **or** the user selected nothing → a clean **no-op**: nothing created, nothing changed, nothing
  published.
