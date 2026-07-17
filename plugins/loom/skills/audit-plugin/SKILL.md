---
name: audit-plugin
description: Audit an EXISTING plugin from ONE session — a named session id/path, or the active session — to find how it misbehaved (gate false-positives, wrong-skill calls, retries, redundant questions, post-run surprises) and ship the fixes. Selects the target plugin once (auto by purpose-match, or the named one), dispatches one proposal-only audit agent, expert-reviews, confirms via one multi-select, implements per artifact-catalog safety, and publishes one version bump. Invoke for "audit <plugin> against session <id>", "fix <plugin> based on session <id>", "what went wrong with <plugin> in this session", or "/audit-plugin <session-id> [plugin]". For enhancement/redundancy work or analysis across every session, use learn; for loose user/project artifacts from a session, use harvest-automations.
version: 1.0.0
---

# Audit Plugin — find & fix how an existing plugin misbehaved (from a session)

Turn a real working session into a shipped **fix** for **ONE existing plugin**. This skill reads a
session transcript, reconstructs how the plugin was actually used, and surfaces the **bugs** —
gate false-positives, wrong-skill calls, retries, workarounds, redundant questions, post-run
discrepancies — then ships the corrections as a single release. It audits; it does not add new
workflows (for that, see the ENHANCE work in `learn`).

Everything except the audit brief (Step 2) lives in the shared chassis — **read it first**: resolve it
by glob and `Read` it, then reference its sections (§A … §J).

```bash
common="$(find .claude/skills plugins -path '*/references/session-plugin-common.md' 2>/dev/null | head -1)"
echo "${common:-NO_COMMON}"
```

> **Jargon, defined once.** *Transcript* = the JSONL log of a past session under
> `~/.claude/projects/`. *Audit fix* = a correctness change for observed misbehavior. *Artifact* = a
> Claude Code customization (skill, command, subagent, hook, permission, rule); the **artifact catalog**
> (§D) is the authority on which type fits. *Plugin surface* = everything a plugin declares — its
> commands, skills, agents, hooks.

## When to invoke

- "audit `<plugin>` against session `<id>`" · "fix `<plugin>` based on session `<id>`"
- "what went wrong with `<plugin>` in this session" · "`<plugin>` blocked me / kept retrying — fix it"
- User types `/audit-plugin` (optionally with a session id and/or plugin name)

## When NOT to invoke

- **No session to learn from.** The audit is evidence-driven — it reads a *real* transcript, not a
  hypothetical. For a feature with no session, use `/mentor:plan`.
- **You want to remove redundant/manual work or add an optimal workflow** (the ENHANCE lens), or to
  analyze **every** session machine-wide, not one → use `learn` (`/loom:learn <plugin> [session-id]`).
  `learn` runs both audit + enhance lenses; a bare `learn <plugin>` sweeps all unanalyzed sessions, and
  `learn <plugin> <session-id>` does one session with both lenses.
- **The redundancy isn't plugin-shaped** (belongs in a user/project artifact, not inside any one
  plugin) → use `harvest-automations` (a sibling skill in this plugin), which works over the whole
  session and does not publish.
- The target plugin lives outside this marketplace repo (the publish step assumes `plugins/<name>/`).

## Inputs

- **`$1` — session ID** (UUID, e.g. `e05bde45-3ed9-458d-9a2e-ba6744d64a18`) or a transcript path.
  **Optional** — omitted, the **active session** is audited (chassis §A resolves it).
- **`$2` — plugin name** (optional, e.g. `mentor`). If omitted, the skill auto-selects the optimal
  target plugin by matching the session against each plugin's declared purpose.

---

## Step 1 — Resolve the transcript, build the purpose map, select the target plugin ONCE

Follow the shared chassis **§A** (resolve transcript + subagents; empty `$1` → the active session),
**§B** (build the plugin-purpose map), and **§C** (never read the whole transcript in the main thread).

Then **select the target plugin**:

- **`$2` given** → validate it exists (`test -d plugins/<name>`). If it does, use it; if not, tell the
  user and ask for a valid one.
- **`$2` omitted** → score each plugin by `invocation count × purpose-matched misbehavior` using the §B
  map (a quick streamed pass with `jq -c` / `python3`, summaries only). **Unambiguous** top score →
  auto-pick and say why (cite score + purpose match). **Ambiguous** (top two close, or the session spans
  plugins) → confirm with **one** `AskUserQuestion`, labelling each option with the plugin name **and**
  its purpose from the map. A skill may call `AskUserQuestion`; this is why selection lives in the main
  thread, not a subagent.

## Step 2 — Run the AUDIT lens: dispatch the analysis subagent

Resolve the shared lens reference and dispatch **one** `Explore` subagent (sonnet) given the **main
transcript PATH**, the **subagents dir PATH**, the **selected plugin** (and root `plugins/<selected>/`),
and the **§B purpose map** as text — **paths only; never the transcript contents** (§C).

```bash
lenses="$(find .claude/skills plugins -path '*/references/analysis-lenses.md' 2>/dev/null | head -1)"
echo "${lenses:-NO_LENSES}"
```

Brief the subagent from that file: give it the two sections located by their literal heading text (never
by step number) — the headings **`Common parse brief`** and **`Agent A — AUDIT lens`**; **fail loud** if
an anchor is missing rather than guessing. The subagent does **ANALYSIS → PROPOSALS ONLY** (no `Skill()`,
no `AskUserQuestion`, no implementing, no publishing — the interactive/mutating tail is this skill's,
Steps 3–7). It returns per the file's **Return contract**: **FINDINGS** (≤400 words each) / **EVIDENCE**
(`file:line` refs only) / **OPEN QUESTIONS**.

## Step 3 — Order the proposals + composing-entry-point self-notice

Hold only the distilled return in the main thread and build **one** proposal list, **ordered by impact**
(P1 fixes first). A single lens needs no cross-lens merge — just order and de-duplicate any proposals
that touch the same `file:line`.

Run the **composing-entry-point self-notice** once: *would the result still be manual stitching unless a
single composing entry point — one command/skill that drives the others end to end — existed, where none
does today?* If **yes**, add one thin command/skill (per §D's legitimate pairings). If **no** (the
existing surface already composes the pieces), say so and add nothing — the cleaner answer. Enforce
**MINIMALITY**: the smallest set that fixes the bugs; every artifact load-bearing; prefer **editing** an
existing plugin file over a near-duplicate; honor the catalog's bundle anti-patterns.

## Step 4 — Expert review

Review the set **once**. Follow shared chassis **§H** (one reviewer by default; escalate to the
practicality / comprehensiveness / cleanliness trio for a non-trivial set — any hook, multiple
artifacts, or a settings merge). State the selected plugin's **design philosophy** explicitly to the
reviewer(s). Fold verdicts back into the set.

## Step 5 — Confirm with the user

Follow shared chassis **§I**: print a compact card per fix, then **immediately** call **one**
`AskUserQuestion` **multi-select** in the same turn. Zero selection → a clean **no-op** (nothing
materialized, nothing published).

## Step 6 — Implement the selected fixes

Resolve the artifact catalog (§D) and implement in `plugins/<selected>/` using the per-type write safety
(**§E**), the `${CLAUDE_PLUGIN_ROOT}` hook rule (**§F**), and the pre-publish validation (**§G**) —
embedded-Python compile + JSON validate, then grep each target file to confirm the change landed.

## Step 7 — Publish ONCE

Follow shared chassis **§J**: invoke `publish-plugin` with the plugin + one consolidated bump as
**intent** (highest class present: new artifact surface → minor; bug-only → patch; breaking → major).
Report the new version + the `old..new` push line on the default branch, and advise `/reload-plugins`.

---

## Rules

- **Single lens, single session, ONE publish.** Select the target plugin **once** (Step 1); everything
  downstream (order, review, one question, implement, one publish) follows. One plugin per publish.
- **Subagent returns PROPOSALS ONLY** — no `Skill()`, no `AskUserQuestion`, no implementing, no
  publishing. This skill owns the order, the review, the one question, the implement, and the publish.
- **Evidence over assumption** — every fix traces to an **Observation** (transcript line ref) AND a
  **Root cause** (`file:line`). No speculative additions.
- **Honor the shared chassis** — §C (no whole-transcript reads in the main thread), §D (catalog by glob,
  inline fallback if absent), §E/§F (per-type write safety; `${CLAUDE_PLUGIN_ROOT}` hooks), §G (validate
  embedded Python + JSON, grep-confirm), §H (mandatory right-sized review) — plus MINIMALITY per Step 3.
- **Lens brief read from `references/analysis-lenses.md` at its heading anchor** — never duplicated into
  this skill or the prompt; fail loud if the anchor is missing.

## Done when

- The transcript + subagents were resolved (§A; active session when `$1` omitted); the purpose map was
  built (§B); the target plugin was selected **once** (validated when `$2` given, auto-picked or
  `AskUserQuestion`-confirmed otherwise); no raw transcript was read in the main thread (§C).
- The AUDIT lens ran in a proposal-only subagent briefed from `analysis-lenses.md`; the set was ordered
  by impact, deduped on shared `file:line`, and the composing-entry-point self-notice ran.
- The set was expert-reviewed once (§H) and revised per the verdicts; the user confirmed via one
  multi-select `AskUserQuestion` (§I).
- **Then either:** the selected fixes were applied per §E/§F, validated per §G (embedded Python + JSON),
  grep-confirmed, and **published once** via `publish-plugin` (§J) — new version + push reported, user
  advised to run `/reload-plugins`;
- **or** the user selected nothing → a clean **no-op**: nothing created, nothing changed, nothing
  published.
