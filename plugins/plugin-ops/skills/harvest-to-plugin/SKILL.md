---
name: harvest-to-plugin
description: >
  Analyzes a Claude Code session transcript — the active session by default, or any session given
  its session id or transcript path — finds the repeated manual work and multi-step macros you kept
  doing by hand, and PACKAGES them as a real marketplace plugin under this repo's `plugins/<name>/`
  (its skills/commands/subagents/hooks, plus a project-scoped rule when one fits), registered in
  `marketplace.json`, then OFFERS to publish. Use this whenever the user wants to turn a session into
  a reusable plugin: "harvest this session into a plugin", "turn this session into a marketplace
  plugin", "package what I keep doing by hand as a plugin", "make a plugin out of what I did here",
  or "/harvest-to-plugin <session-id>". It only creates what is genuinely new — it scans existing
  plugins first and MERGES into (or skips) work that already exists, so it never ships a redundant
  workflow.
version: 0.1.0
---

# Harvest to Plugin

Turn the work you just did by hand into a packaged, installable **marketplace plugin** in *this*
repo. This skill reads a session transcript, finds patterns that repeated (>=2 near-identical asks,
or a stable multi-tool macro), designs each as a complete **usage/workflow**, and materializes the
accepted ones as a plugin under `plugins/<name>/` — creating a **new** plugin or **merging into an
existing** one — then stops and **offers** to publish. You never lose control of the remote: nothing
is committed or pushed unless you say yes.

Three references are the authority here; read them before deciding artifact types or writing files:
- **shared chassis** — the steps every session→plugin skill shares (transcript resolution, purpose
  map, catalog resolution, per-type safety, validation, expert review, the confirmation card, publish
  handoff). Resolve it by glob and `Read` it, then reference its sections §A … §J instead of
  re-narrating them:

  ```bash
  common="$(find .claude/skills plugins -path '*/references/session-plugin-common.md' 2>/dev/null | head -1)"
  echo "${common:-NO_COMMON}"
  ```

- **[`references/artifact-catalog.md`](references/artifact-catalog.md)** — which pattern maps to which
  artifact type, per-type templates, merge recipes, per-type safety, and the "Composing usage
  bundles" minimality rules.
- **[`references/plugin-packaging.md`](references/plugin-packaging.md)** — how to assemble those
  artifacts into a **valid plugin** (plugin.json, marketplace registration, collision handling,
  `${CLAUDE_PLUGIN_ROOT}` hooks, rule scope, new-vs-merge, publish handoff). The catalog *defers*
  full-plugin generation; this file is that missing piece.

## When to use

- After a session where you repeated the same kind of request, or walked Claude through the same
  multi-step procedure more than once, and you want it packaged as a **plugin** for this marketplace.
- "turn this session into a marketplace plugin", "package what I keep doing by hand as a plugin",
  "/harvest-to-plugin".

## When NOT to use

- **Target is an existing plugin you want improved** — use `tune-plugin` (`lens = enhance` for
  redundancy removal, `lens = audit` for bug fixes, `lens = both` for both). Those lenses start from a
  named/selected plugin and improve it *in place*; this skill starts from a session and produces a
  plugin.
- **You want loose user/project artifacts, not a plugin** (a bare command, a CLAUDE.md line, a
  permission) — use `harvest-automations`. It emits across the whole customization surface and does
  not package or publish.
- **Nothing recurred >=2x** — there is nothing to harvest. Say so and create nothing.

---

## Step 1 — Resolve the session transcript

Follow the shared chassis **§A** (`$ARGUMENTS` selects the session: empty = active, a UUID, or a
`.jsonl` path; resolve `$tx`, handle `NO_TRANSCRIPT` via `AskUserQuestion`, confirm by reading only the
**tail** — never the whole transcript, per **§C**). Only the transcript PATH is passed onward to the
analysis subagent.

## Step 2 — Analyze in a subagent (usages + plugin-purpose map)

Build the **plugin-purpose map** first (shared chassis **§B**) so the analyzer knows what already
exists. Dispatch **one** `Explore` subagent (sonnet) with the transcript **PATH** (not its contents) and the
purpose map as text. Brief it to:

- Stream the JSONL with `jq -c` (do not load it whole); cluster by **user intent / usage** — what the
  user kept asking for and the end-to-end workflow that served it — not by artifact type.
- Score recurrence: >=2 near-identical asks, or a stable multi-tool macro repeated across the session.
- For huge transcripts (>~20k lines), **sample by intent-cluster** rather than full read.
- For each opportunity, design the **usage** first (trigger, end-to-end steps, outcome), then choose
  the **smallest set of plugin artifacts** that delivers it — types per the catalog rubric.
- Flag, per opportunity, whether the purpose map suggests it belongs in an **existing** plugin
  (candidate name + why) vs. a **new** one. This is a routing hint only — Step 3b verifies it.
- **Never paste raw transcript content back** — evidence is line numbers / short quote refs only.

Return **ONLY** this JSON, capped at the **top 4** opportunities by impact (recurrence x manual effort
saved); extras go in `also_noticed` (titles only):

```json
{ "also_noticed": ["one-line titles beyond the top 4, or empty"],
  "opportunities": [ {
  "title": "named after the USAGE, not the artifact",
  "usage": {
    "invocation": "how the user triggers it: '/cmd <args>', a phrase, or 'automatic on <event>'",
    "example": "one concrete invocation taken from THIS session",
    "workflow": ["step-by-step, user-visible"],
    "outcome": "what the user gets and what manual work disappears" },
  "recurrence": { "count": 2, "evidence": ["line/quote refs"] },
  "routing_hint": { "candidate_plugin": "existing plugin name or null", "why": "purpose-match reason" },
  "artifacts": [ {
    "artifact_type": "skill|command|subagent|hook|rule",
    "role_in_workflow": "what this piece contributes",
    "draft_spec": { "name": "kebab", "trigger_phrases": ["..."], "steps": ["..."], "tools": ["..."], "argument_hint": "[hint]", "model": "opus|sonnet|haiku|null", "json_fragment": {} } } ]
} ] }
```

## Step 3 — Group + validate against the catalog

Read the `artifact-catalog.md` and `plugin-packaging.md` references. Decide **grouping**: workflows of one cohesive purpose → **one plugin with
several skills**; unrelated workflows → **separate plugins**. Validate each opportunity's `artifacts[]`
against `artifact-catalog.md`, and enforce **minimality** + the catalog's "Composing usage bundles"
anti-patterns (never a skill + command that duplicate the same steps — a command may only be a thin
entry point delegating to the skill; don't add a subagent for work the main thread does in a call or
two). Run the **composing-entry-point self-notice**: if a plugin's several artifacts would still leave
the user manually stitching them together, add **one** thin command (or skill) that drives them end to
end — otherwise add nothing.

## Step 3b — Plugin-surface GAP scan (prevents redundant workflows; makes merge real)

The purpose map only routes by name/description — it does not prove a workflow is absent. So for
**any** existing plugin flagged as a candidate home (`routing_hint.candidate_plugin`), dispatch one
`Explore` subagent (sonnet) scoped to `plugins/<candidate>/`. Brief it to read the manifest, every
`commands/*.md`, `skills/*/SKILL.md`, `agents/*.md`, and `hooks/*` (incl. `hooks.json`), and return
each harvested friction as either a `file:line` **GAP** ("no home for this in the current surface") or
**"already implemented"** (with the file that implements it). Return contract: FINDINGS (<=300 words) /
EVIDENCE (`file:line` only) / OPEN QUESTIONS. Fire this **only** when a candidate exists — it is one
extra sonnet Explore, not a default.

Apply the results as the **concrete new-vs-merge rule**:

- **MERGE** into the candidate plugin **iff** (strong purpose match) **AND** (the gap scan shows the
  workflow **absent** from that plugin's surface).
- Otherwise → **NEW plugin**.
- **DROP** any single harvested artifact the scan shows **already exists** — this is what stops the
  skill from proposing a redundant workflow. If **every** artifact for a usage already exists, mark
  that usage **"already covered"** and create nothing for it.

## Step 4 — Expert review (mandatory, right-sized)

Follow the shared chassis **§H** (one reviewer by default; escalate to the practicality /
comprehensiveness / cleanliness trio for a non-trivial set — for harvest that includes **a new plugin
with several pieces**, any **hook**/`hooks.json` merge, or **multiple artifacts**). Add the
harvest-specific checks to the reviewers' brief: the composing-entry-point + GAP-scan calls came out
right, and the plugin **packaging** is valid (`plugin.json`, marketplace registration, `new-vs-merge`).
Inline the relevant catalog/packaging playbook (subagents can't call `Skill()`), and — for a merge —
give the target plugin's source.

## Step 5 — Propose usages to the user

Follow the shared chassis **§I** (a card per usage, then **one** `AskUserQuestion` multi-select in the
same turn; the user picks **usages**, never artifact types; zero selection → "nothing materialized",
create nothing). Use the harvest card shape, and for a **merge** the card must **name the target plugin
and its purpose** (from the §B map) so the user can veto a wrong-home merge before it happens:

```
## 1. <usage title>
**You do:** /deploy-ticket <app> <env>
**Example:** /deploy-ticket galio prod
**What happens:**
1. <end-to-end workflow steps, user-visible>
**You get:** <outcome / manual work removed>
**Mode:** create new plugin `deploy-kit`   (or)   merge into `sdlc-mini` — <its purpose>
**Behind it:** `plugins/deploy-kit/commands/deploy-ticket.md` + `skills/deploy/SKILL.md` (recurrence x4)
```

`AskUserQuestion` option per usage: `label` = short handle (<=16 chars); `description` =
`<invocation> — <outcome ≤~80 chars> (new plugin / merge into X)`.

## Step 6 — Materialize the plugin(s) locally, idempotently

For each accepted usage, follow `references/plugin-packaging.md` and the shared chassis' per-type write
safety (**§E**) + `${CLAUDE_PLUGIN_ROOT}` hook rule (**§F**).

1. **Collision guard (re-run safety)** — before writing:

   ```bash
   test -d "plugins/<name>" && echo "DIR EXISTS -> update" || echo "DIR FREE -> create"
   jq -e --arg n "<name>" '.plugins[]|select(.name==$n)' .claude-plugin/marketplace.json >/dev/null \
     && echo "ENTRY EXISTS" || echo "ENTRY FREE"
   ```

   If the dir/entry exists → **update** semantics (never blind-append a duplicate marketplace entry or
   clobber the dir). If the name is taken by an unrelated plugin → pick a more specific name.

2. **Write the artifacts** per their §E strategy (whole-file for a new skill/command/agent; read →
   insert → write back to extend an existing file; merge-json for `hooks/hooks.json`), hooks using
   `${CLAUDE_PLUGIN_ROOT}` (§F). Harvest-specific beyond §E:
   - **On create** — also scaffold `plugins/<name>/.claude-plugin/plugin.json` (name, brief
     description, `version: 0.1.0`, author NTBX) alongside the chosen artifacts.
   - **`rule`** — write/append `<repo>/.claude/rules/<topic>.md` (whole-file create / append-section
     update). It lands **outside** `plugins/<name>/`; report it as a project-scoped **companion**.

3. **Register in `marketplace.json`** — append `{name, source: "./plugins/<name>", description,
   category}` (no `version`) via `jq` with backup + `jq empty` validate + restore-on-failure (recipe
   in `plugin-packaging.md` §3). Touch only `.plugins[]`; leave the top-level `name` alone.

4. **Validate + confirm** — run the §G checks (JSON valid via `json.tool` on every `plugin.json` +
   `marketplace.json`; hook paths clean per §F; grep-confirm each intended write landed). Harvest-
   specific beyond §G: each generated skill's frontmatter `name` == its dir, and secrets stay
   `<PLACEHOLDER>` — never invent credentials.

## Step 7 — Summarize, then OFFER publish

Print a table grouped by usage:

| Usage | How to invoke | Path | Type | create / merge |
|---|---|---|---|---|

List any **rule companions** separately (they live at `.claude/rules/`, not in the plugin). Then —
unlike `tune-plugin`, which proceeds to publish once you select items to ship — **offer** publish
(nothing is committed/pushed without a yes):

- **Yes** → hand off per shared chassis **§J**, passing the plugin + intent **"first release at 0.1.0 —
  do not bump"** (one plugin per publish).
- **No** → leave the files staged locally, tell the user what was written, and stop cleanly.

---

## Edge cases

- **Nothing recurring** — no pattern repeats >=2x → report "nothing to harvest (needs >=2 repeats)"
  and create nothing.
- **Everything already covered** — if the GAP scan shows every harvested artifact already exists →
  report "already covered", create nothing (this is a success, not a failure).
- **Not a git repo** — `git rev-parse` fails, so Step 1 uses the plain `pwd` hash. There is no repo to
  register a plugin into or push from; tell the user this repo isn't a marketplace and stop (or, if
  they only want a rule companion, write it to `~/.claude/rules/` at user scope and say so).
- **Re-runs are safe** — the Step 6 collision guard means running the skill again updates rather than
  duplicating a plugin or a marketplace entry.
- **Partial rejection inside a plugin** — creates apply directly; each merge gets its own diff-confirm.
  If the user rejects a load-bearing piece, apply the rest, note the skipped artifact, and warn the
  usage is incomplete.
- **Huge transcripts** — the analysis subagent samples by intent-cluster (>~20k lines) and never
  pastes raw transcript content back.
- **settings / hooks merges** — always backup + `jq empty` validate + restore-on-invalid; never
  partial-write a `hooks.json`.

## Done when

- The transcript PATH was resolved from `$ARGUMENTS` (or a fallback) and only its tail was read in the
  main context — never the whole file.
- A single analysis subagent returned usage-centric opportunities (capped at 4, extras as
  "also noticed"), plus a dynamically-built plugin-purpose map; no raw transcript content leaked back.
- Every artifact was validated against `artifact-catalog.md` + the minimality rule; the
  composing-entry-point self-notice ran; and for any routed candidate the **Step 3b GAP scan** ran —
  merging only where a gap exists, dropping already-implemented artifacts, and reporting fully-covered
  usages as "already covered".
- The set was expert-reviewed (right-sized) and revised per verdicts.
- Usage cards were printed and the user multi-selected **usages** (never artifact types); merge cards
  named the target plugin + purpose. Zero selection ended with "nothing materialized".
- Accepted usages were materialized idempotently (collision guard), per-type safety honored, hooks use
  `${CLAUDE_PLUGIN_ROOT}`, rules written as project-scoped companions, and the plugin registered in
  `marketplace.json` (`.plugins[]` only, no duplicate entry). All JSON validated; writes grep-confirmed.
- A usage-grouped summary table was printed, then publish was **offered** — invoked via
  `publish-plugin` (first release, no bump) only on an explicit yes, else left staged locally.
