---
name: plan-review
description: |
  Pre-ExitPlanMode light reviewer. Trigger phrases: `/plan-review`,
  "review this plan", "review the plan", "send the plan to reviewers".
  Reads the current plan file (plan mode) and reviews the plan's solution
  against three fixed dimensions — practicality, comprehensiveness, and
  cleanliness — with NO domain selection. Picks the best reviewer agent at
  runtime by scoring every subagent in the Agent tool's `subagent_type`
  enum against an `architect` keyword bag (falls back to `general-purpose`),
  and inlines topic-relevant skill playbooks from the active-skills
  system-reminder into each reviewer brief (sub-agents cannot call Skill()
  themselves). Asks the user only Run vs Pass, then fans out three reviewers
  in a single parallel Agent() batch — one per dimension — without leaving
  plan mode.
---

# Plan Review — Fixed 3-Topic Light Review

This skill is a pre-`ExitPlanMode` review pass. It reads the current plan, picks the best registered reviewer agent (and 0–4 supporting skills per topic) **at runtime**, asks the user to confirm Run vs Pass, then fans out **three** `Agent()` calls — one per fixed review dimension — all in a **single message**, without leaving plan mode.

The three fixed dimensions are:

1. **Practicality** — is the approach feasible, realistically scoped, low-risk?
2. **Comprehensiveness** — does it cover the requirement, edge cases, and gaps?
3. **Cleanliness** — is the resulting design simple, maintainable, reuse-aware?

There is **no domain detection and no domain selection** — every plan is reviewed against these same three dimensions.

## When to use

- The user typed `/plan-review` (or "review this plan", "review the plan", "send the plan to reviewers") while still in plan mode.
- A plan file exists at `~/.claude/plans/<slug>.md` (or the mentor `.html`/`.md` plan) and the user wants reviewer feedback before exiting plan mode.

## When NOT to use

- After `ExitPlanMode` — use `dispatch-agents` instead.
- No plan file in `~/.claude/plans/` or the mentor plans dir.
- Single-file typo fixes or trivial edits where review costs more than the change.
- The user explicitly asked you NOT to invoke sub-agents.

---

## Step 1 — Resolve the plan file

1. **Authoritative source.** Search the most recent `<system-reminder>` block in the conversation for a path matching the regex `~/.claude/plans/[^\s)]+\.(md|html)` (or the absolute form `/Users/.../.claude/plans/...`). That is the path the harness wrote when plan mode started.
2. **Fallback.** Only if no reminder is in context, prefer the mentor plan (persisted as `.html` since v0.15.0), then the harness file:
   ```bash
   # newest mentor plan for this repo (html preferred, legacy md), else harness file
   git_common=$(git rev-parse --git-common-dir 2>/dev/null) && \
     repo_root=$(cd "$(dirname "$git_common")" && pwd) && \
     d="$HOME/.claude/mentor/$(basename "$repo_root")-$(printf '%s' "$repo_root" | shasum | cut -c1-8)/plans"
   ls -t "$d"/*.html "$d"/*.md ~/.claude/plans/*.html ~/.claude/plans/*.md 2>/dev/null | head -1
   ```
3. If both fail, print the one-line abort: `Plan review aborted: no plan file found.` and stop.

Then `Read` the plan file. Do **not** edit it. **If the file is HTML**, review the canonical plan in the `<script type="text/markdown" id="plan-source">…</script>` block — that is the authoritative Markdown; ignore the rendered body markup. **If it is a `.md`** (the mentor `md` output format, or a harness-native plan), it IS its own canonical source — review it directly (footer markers at end-of-file, dispatch annotations inline; there is no `plan-source` block to extract).

---

## Step 2 — Inventory reviewers from the active session (no disk scans)

### 2a. Agents — read the Agent tool catalog

The `Agent` tool's `subagent_type` parameter enum, rendered into your current tool spec, **is** the authoritative list of agents installed and enabled in this session. For each enum value, your tool spec already exposes:

- the agent name (the enum value itself)
- a one-line description
- the `(Tools: …)` whitelist

Use that as your candidate set. Do **not** shell out to scan `~/.claude/agents/*.md` or any plugin's `agents/` directory — disk contents include disabled plugins and stale files and will diverge from what is actually callable this session.

**Record the `(Tools: …)` whitelist for each candidate.** It tells you what the reviewer can call. Most reviewer agents declare an explicit list that excludes `Skill`, which is why supporting playbooks must be inlined into the prompt in Step 6.

The agent's own declared `model:` frontmatter is **not** visible from inside the session; this skill uses a fixed model for all reviewers (see Step 3).

### 2b. Skills — read the system-reminder

Find the most recent `<system-reminder>` block containing the line `The following skills are available for use with the Skill tool:` and read every `- <name>: <description>` line. That is the authoritative session list.

Build an in-memory list of `(skill_name, description)`.

If no such reminder is in context, **degrade gracefully**: proceed with the dispatch but skip the playbook-inlining step entirely (Step 6 emits no `## Reviewer playbook` sections, and Step 3's supporting-skill picks return empty). Include this one-line notice in the Step 5 runtime summary:

```
Supporting skills: skipped — active-skill list unavailable in session.
```

Do **not** fall back to scanning `SKILL.md` files on disk — the harness filters the active set per session and a disk scan will lie.

### 2c. Multi-skill loading per dispatched reviewer

A single reviewer dispatch can inline more than one supporting skill relevant to its topic. When Step 3 returns multiple skills above threshold for the same topic, the dispatcher (Step 6) must include **every** selected skill's playbook in that one `Agent()` call's prompt — one `## Reviewer playbook (from <skill-name>)` section per skill, in score-rank order. See Step 3 for the cap.

---

## Step 3 — Runtime scoring (one architect agent + per-topic supporting skills)

There is no domain detection. Scoring picks a single reviewer agent and the supporting skills relevant to each of the three fixed topics.

### Pick the reviewer agent (architect bag)

Score every candidate agent from Step 2a against the single keyword bag:

- `architect` → `{architect, architecture, design, review, practical, clean, simplify, system, maintainability, structure, quality, code}`

**Domain-noun set** (for prefix bonus): `{architect, arch, design, review, quality}`.

Scoring algorithm (hardened against generalist over-fit):

1. Compute `base` = number of whole-word, case-insensitive matches of the architect bag in `(agent.name + " " + agent.description).lower()`.
2. `+3` bonus if the agent's `name` contains one of the architect domain nouns.
3. Cap the score at `5`.
4. Threshold: `score >= 2`. Below threshold → use `general-purpose` with the preamble `"Act as a solution/architecture reviewer of this plan."`.
5. Tie-break: shortest `name` length (prefer a focused specialist).

The **same** picked agent is used for all three reviewers.

### Per-topic supporting skills

Define three small topic keyword bags so each reviewer inlines the playbooks most relevant to its dimension:

- `practicality` → `{practical, feasible, risk, scope, effort, estimate, simplify}`
- `comprehensiveness` → `{coverage, edge, gap, complete, requirement, test, spec}`
- `cleanliness` → `{clean, simplify, maintainability, reuse, refactor, quality, review}`

For each topic, apply the same whole-word scoring algorithm to the skill inventory from Step 2b. Keep **all** skills with `score >= 2` for that topic, ranked by score (tie-break: shortest name first), with a **soft cap of 4** per topic to bound prompt size. (Skills like `simplify` / `code-review` will naturally land on `cleanliness`.) For each picked skill, `Read` its `SKILL.md` source from the active-skills entry (the harness exposes the source path in plugin layouts; if not visible, fall back to globbing for a file with that `name:` in `~/.claude/plugins/*/skills/*/SKILL.md` — this is a per-skill body read, not a discovery scan, and is the only acceptable disk read in this skill). Capture the body (everything after the closing `---` of the frontmatter) for inlining in Step 6. Do **not** instruct the reviewer to call `Skill(...)` itself — the existing reviewer agents lack `Skill` in their `tools:` whitelist.

If Step 2b's reminder was absent, this step yields zero supporting skills for every topic (the dispatch proceeds without playbooks).

### Model & effort

This is a light pass — keep it cheap. All three reviewers run `model: sonnet`, `effort: medium`.

---

## Step 4 — User confirmation gate (AskUserQuestion)

**Skip this step** if the calling context explicitly instructs you to skip it (e.g. the message
immediately preceding this skill invocation states that the user already chose "Review the plan
(light)"). If that skip instruction is present, proceed directly to Step 5.

Otherwise, send a **single `AskUserQuestion` call with one question** — Run vs Pass. No domain selection.

```
Question — header "Plan review", single-select, 2 options:
  1. "Run light review"   (Recommended)            ← first
     description: "Review the plan's solution on practicality, comprehensiveness, and cleanliness."
  2. "Pass (skip)"
     description: "Return to plan mode without dispatching."
```

### Resolution rules

- `"Pass (skip)"` ⇒ print `Plan review: skipped by user.` and **return**. No dispatch. Plan mode remains active.
- `"Run light review"` ⇒ proceed to Step 5.

---

## Step 5 — Emit the dispatch block (audit log)

Print the planned fan-out in the exact grammar from `dispatch-agents` SKILL.md (mirrored — do **not** call `dispatch-agents`). Always exactly three entries:

```
Run in parallel:
  Step 1 — Review practicality        [role: <agent_name> · model: sonnet · effort: medium]
    Goal: Critique the plan's solution for practicality.
    Inputs: <plan file path>, optional playbooks: <skill names or none>
    Done when: Structured review block returned ≤400 words.
  Step 2 — Review comprehensiveness   [role: <agent_name> · model: sonnet · effort: medium]
    Goal: Critique the plan's solution for comprehensiveness.
    Inputs: <plan file path>, optional playbooks: <skill names or none>
    Done when: Structured review block returned ≤400 words.
  Step 3 — Review cleanliness         [role: <agent_name> · model: sonnet · effort: medium]
    Goal: Critique the plan's solution for cleanliness.
    Inputs: <plan file path>, optional playbooks: <skill names or none>
    Done when: Structured review block returned ≤400 words.
```

Then print the runtime summary:

```
Plan: <path>
Reviewer (runtime-picked): <agent_name>  (sonnet)   ← or "general-purpose (fallback)"
Playbooks per topic:
  practicality       -> <skills or "(none)">
  comprehensiveness  -> <skills or "(none)">
  cleanliness        -> <skills or "(none)">
```

If Step 2b's reminder was absent, append the one-line notice from Step 2b directly under the summary:

```
Supporting skills: skipped — active-skill list unavailable in session.
```

---

## Step 6 — Fan out the three reviewers

Issue **one `Agent()` call per topic in a single assistant message** so they run concurrently. Each `prompt` field must contain:

1. `You are reviewing a plan, not implementing it.`
2. The plan file path with an explicit `Read this file before doing anything else.`
3. `Critique the plan's solution strictly through the lens of <topic>.` plus the one-line definition:
   - `practicality` → `Is the approach feasible, realistically scoped, and low-risk?`
   - `comprehensiveness` → `Does it cover the requirement, edge cases, and gaps?`
   - `cleanliness` → `Is the resulting design simple, maintainable, and reuse-aware?`
4. The inlined `## Reviewer playbook (from <skill-name>)` section — verbatim body of each chosen skill's SKILL.md (everything after the closing `---` of the frontmatter) for **that topic**. **One section per supporting skill, in score-rank order; include every skill Step 3 returned for the topic (up to the soft cap of 4), not just the top one.** If no skills matched (or Step 2b's reminder was absent), omit this block.
5. Required structured output:
   ```
   Strengths:
   Risks:
   Gaps:
   Recommended plan edits:
   ```
6. Word cap: `Cap your reply at 400 words.`
7. Anti-recursion: `Do not invoke /plan-review or any planning skill.`

Each `Agent()` call uses:
- `subagent_type` = the picked architect agent name, or `general-purpose` if the score didn't clear the threshold.
- `model` = `sonnet`.
- `description` = `Review plan: <topic>` (`<topic>` is `practicality`, `comprehensiveness`, or `cleanliness`).

### Do NOT

- Do **not** call `Skill(skill="dispatch-agents")`. That skill is designed for post-`ExitPlanMode` and would not fire here.
- Do **not** call `ExitPlanMode`. The user runs this to refine the plan in place.
- Do **not** edit the plan file from inside `/plan-review`. Surface findings; let the user decide which edits to make.
- Do **not** instruct reviewers to call `Skill(...)`; their `tools:` whitelist usually excludes it.
- Do **not** detect domains or ask the user to select domains — this is a fixed 3-topic pass.
