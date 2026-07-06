---
name: harvest-automations
description: >
  Analyzes a Claude Code session transcript — the active session by default, or any session given
  its session id or transcript path — detects repeated manual prompts and
  multi-step work you keep doing by hand, and then CREATES or UPDATES reusable Claude Code
  artifacts across the full customization surface — skills, commands, subagents, hooks,
  permissions, CLAUDE.md/memory, rules, MCP servers, and output styles — so future similar
  sessions need less manual prompting. It picks the right artifact type per Claude best practice
  and can both create new artifacts and merge into existing ones. Invoked via "/harvest",
  "harvest automations", "harvest this session", "harvest session <id>", "turn this session into
  reusable artifacts / a skill / a command / an agent", "automate what I keep doing by hand", or
  "what could I have automated".
version: 0.3.0
---

# Harvest Automations

Turn the work you just did by hand into reusable Claude Code customizations. This skill reads the
**current session transcript**, finds patterns that repeated (>=2 near-identical asks, or a stable
multi-tool macro), and designs each one as a complete **usage/workflow** — how you'll trigger it,
what happens end to end, what you get. You choose the usages you want (never raw artifact types);
each accepted usage is delivered by the smallest artifact bundle per Claude guidance — **creating
new** artifacts or **merging into existing** ones across the whole customization surface.

The authoritative best-practice rubric (which pattern maps to which artifact), the per-type
templates, and the merge recipes live in **[`../../references/artifact-catalog.md`](../../references/artifact-catalog.md)**.
Read it before deciding artifact types and before writing any file.

## When to use

- After a session where you repeated the same kind of request, or walked Claude through the same
  multi-step procedure more than once.
- When you say "automate what I keep doing by hand" or "what could I have automated here".
- When you want this session's manual work distilled into a skill, command, subagent, hook,
  permission, CLAUDE.md entry, rule, MCP server, or output style.

## When NOT to use

- One-off tasks with nothing repeated. If nothing recurs >=2x, there is **nothing to harvest** —
  say so and create nothing.
- A session that was itself pure planning/exploration with no manual macro to capture.
- When the user wants a one-time artifact for a specific known need — just create it directly; you
  do not need transcript analysis for that.

---

## Step 1 — Resolve the session transcript

`$ARGUMENTS` (the optional token passed to `/harvest`) selects **which** session to analyze. It may be:

- **empty** — analyze the **active** session (auto-discover the newest JSONL under the hashed cwd),
- a **session id** — a UUID like `e05bde45-3ed9-458d-9a2e-ba6744d64a18` (e.g. copied from another
  session, a worktree, or `/status`) — resolved to that session's transcript anywhere under
  `~/.claude/projects/`,
- an explicit **path** to a transcript `.jsonl` — used directly.

Resolve the input to a single transcript PATH (`tx`):

```bash
arg="$ARGUMENTS"
arg="$(printf '%s' "$arg" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"   # trim

if [ -z "$arg" ]; then
  # (a) no argument — auto-discover the active session under the hashed cwd
  root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  hash="$(printf '%s' "$root" | sed 's/[/.]/-/g')"
  tx="$(ls -t "$HOME/.claude/projects/$hash"/*.jsonl 2>/dev/null | head -1)"
elif printf '%s' "$arg" | grep -Eq '(/|\.jsonl$)'; then
  # (b) looks like a path (has a slash or ends in .jsonl) — use directly
  tx="$arg"
else
  # (c) a session id — find <id>.jsonl. -maxdepth 2 keeps it to top-level main
  #     transcripts (projects/<hash>/<id>.jsonl), excluding .../<id>/subagents/
  tx="$(find "$HOME/.claude/projects" -maxdepth 2 -name "${arg}.jsonl" 2>/dev/null | head -1)"
fi
[ -n "$tx" ] && [ -e "$tx" ] && echo "$tx ($(wc -l <"$tx") lines)" || echo "NO_TRANSCRIPT"
```

The cwd is hashed by replacing every `/` and `.` with `-`. `ls -t` picks the most recently written
JSONL — the live session. A session id is unique per session, so the `find` resolves to exactly one
top-level transcript.

**If the block prints `NO_TRANSCRIPT`:**

1. A supplied **session id or path that didn't resolve** — tell the user it wasn't found (the id may
   belong to a different machine or have been cleaned up) and use `AskUserQuestion` to ask for a
   correct session id or path.
2. **No argument and nothing auto-discovered** — use `AskUserQuestion` to ask for the transcript path
   or session id.

Confirm it is the intended session by reading only the **tail**, never the whole file:

```bash
tail -n 5 "$tx"
```

For the **active** session (case a) the tail's `cwd` should match `root` and its timestamp be
recent. For a **session id or path** (cases b/c) the transcript is an arbitrary — possibly older,
possibly different-cwd — session, so just sanity-check it parses and note its `cwd`/timestamp rather
than expecting them to match the current repo. **NEVER read the whole transcript into the main
context** — only its PATH is passed onward to the analysis subagent.

## Step 2 — Delegate analysis to a subagent

Dispatch **one** `Explore` (or `general-purpose`) subagent on **sonnet** with the transcript
**PATH** — not its contents. Brief it to:

- Stream the JSONL with `jq -c` (do not load it whole), cluster by **user intent / usage** — what
  the user kept asking for and what end-to-end workflow served it — not by artifact type.
- Score recurrence: >=2 near-identical asks, or a stable multi-tool macro repeated across the
  session.
- For each opportunity, design the **usage** first (how the user will trigger it, what happens end
  to end, what they get), then choose the **smallest set of artifacts** that delivers that usage —
  types, scopes, and create/update modes per the rubric in `../../references/artifact-catalog.md`. One
  usage may bundle multiple artifacts (e.g. a command + the permission it needs).
- For huge transcripts (>~20k lines), **sample by intent-cluster** rather than full read.
- **Never paste raw transcript content back** — evidence is line numbers / short quote refs only.

It must return **ONLY** this JSON, capped at the **top 4** opportunities by impact
(impact = recurrence x manual effort saved). If more than 4 survive, the extras go in the
top-level `also_noticed` array (titles only) — the main agent mentions them in chat as
"also noticed, not offered":

```json
{ "also_noticed": ["one-line titles of opportunities beyond the top 4, or empty"],
  "opportunities": [ {
  "title": "string — named after the USAGE, not the artifact",
  "usage": {
    "invocation": "exactly how the user triggers it: '/cmd <args>', a phrase, or 'automatic on <event>'",
    "example": "one concrete invocation taken from THIS session",
    "workflow": ["step-by-step what happens end to end, user-visible"],
    "outcome": "what the user gets and what manual work disappears"
  },
  "recurrence": { "count": 2, "evidence": ["line/quote refs"] },
  "best_practice_rationale": "why this artifact composition per Claude guidance",
  "artifacts": [ {
    "artifact_type": "skill|command|subagent|hook|permission|claude-md|rule|mcp-server|output-style",
    "role_in_workflow": "what this piece contributes to the usage",
    "mode": "create | update",
    "recommended_scope": "user | project | plugin",
    "target_path": "existing file to update, or null",
    "merge_strategy": "merge-json | append-section | whole-file",
    "draft_spec": { "name": "kebab", "trigger_phrases": ["..."], "steps": ["..."], "tools": ["..."], "argument_hint": "[hint]", "model": "opus|sonnet|haiku|null", "json_fragment": {} }
  } ]
} ] }
```

## Step 3 — Apply the decision rubric

Read **[`../../references/artifact-catalog.md`](../../references/artifact-catalog.md)** for the authoritative
best-practice rubric (which pattern -> which artifact), the per-type templates, and the merge
recipes. Validate **every entry in each opportunity's `artifacts[]`** — `artifact_type` / `mode` /
`merge_strategy` — against the catalog before proposing.

Also enforce **minimality**: a bundle must be the **smallest set of artifacts that delivers the
usage**. Do not accept skill + command + agent when one artifact serves the workflow; a
multi-artifact bundle is justified only when the usage genuinely needs every piece (e.g. a command
entry point + the permission it requires). See the catalog's "Composing usage bundles" section for
legitimate pairings and anti-patterns.

Rubric headline (full detail in the catalog):

- **skill** — a repeated multi-step playbook worth naming and reusing.
- **command** — a fast, parameterized entry point for a frequent ask.
- **subagent** — isolated heavy or parallelizable work that should run off the main thread.
- **hook** — deterministic behavior that must always run on a given event.
- **permission** — a tool/command that keeps triggering approval prompts.
- **claude-md / memory** — a durable cross-session preference or project fact.
- **rule** — file-type-scoped guidance (applies when matching files are touched).
- **mcp-server** — access to an external tool or API.
- **output-style** — a persistent tone or role for the assistant.

## Step 4 — Propose usages to the user

The user chooses a **usage/workflow**, never an artifact type. Each choice is one complete
usage; the artifacts behind it are implementation detail.

1. **Print a usage card per opportunity** in chat (markdown), then **immediately** call
   `AskUserQuestion` in the same turn — never end the turn on the cards alone. Card format:

   ```
   ## 1. <usage title>
   **You do:** /deploy-ticket <app> <env>
   **Example:** /deploy-ticket galio prod
   **What happens:**
   1. <end-to-end workflow steps, user-visible>
   **You get:** <outcome / manual work removed>
   **Behind it:** creates `commands/deploy-ticket.md` + `agents/ticket-runner.md` (recurrence x4)
   ```

   The "Behind it" line is a footnote — paths + recurrence count only; the card sells the usage.

2. `AskUserQuestion` **multi-select**, one option per usage:

   - `label` = short usage handle, 1-3 words / <=16 chars (e.g. `/deploy-ticket`, "env-var
     sync") — the full invocation belongs in the description and card, not the label.
   - `description` = `<invocation> — <outcome one-liner, <=~80 chars> (creates 2, updates 1)` —
     spell out create vs update counts when a bundle mixes modes.

3. **Zero selection** — if the user selects no usages (or interrupts), report "nothing
   materialized" and stop. Never re-ask, never materialize anything anyway.

4. **Scope confirmation** is ask-each-time per accepted **usage** — batch all scope confirmations
   into **one** `AskUserQuestion` call (<=4 accepted usages = <=4 questions, header = usage
   handle). One scope applies to every artifact in the bundle, with this fallback: settings-based
   artifacts (permission, hook, mcp-server) have **no plugin scope** — if the user picks plugin,
   those artifacts fall to **project** scope (or **user** when not a git repo, same fallback as
   the edge cases below), and the diff/confirm in Step 5 must say so.

## Step 5 — Resolve create vs update, then apply (with safety)

For each accepted **usage**, loop over every artifact in its `artifacts[]`:

1. **Resolve the concrete target path** from `artifact_type` + chosen scope (see the catalog's path
   table). Run an existence check to confirm create vs update, and scan sibling names so you don't
   collide or duplicate:

   ```bash
   test -e "<target_path>" && echo "EXISTS -> update" || echo "MISSING -> create"
   ls -1 "$(dirname "<target_path>")" 2>/dev/null   # scan siblings for near-duplicate names
   ```

2. **Apply the per-type strategy** (recipes in the catalog):

   - **merge-json** — hooks, permissions, mcp-server, and other `settings.json` / `.mcp.json`
     keys. **Write a timestamped backup first**, deep-merge the `json_fragment` with `jq`, then
     validate and **abort (restoring) on invalid JSON**. Never overwrite the whole file or drop
     sibling entries:

     ```bash
     target="<settings.json or .mcp.json>"
     cp "$target" "$target.bak.$(date +%s)"                 # backup FIRST
     jq --argjson frag '<json_fragment>' '. * $frag' "$target" > "$target.tmp" \
       && jq empty "$target.tmp" \
       && mv "$target.tmp" "$target" \
       || { echo "INVALID JSON — aborting, restoring backup"; rm -f "$target.tmp"; \
            cp "$target".bak.* "$target" 2>/dev/null; }
     ```

   - **append-section** — CLAUDE.md, rules, memory. **Append** a new, clearly-headed Markdown
     section; never rewrite existing content. For **memory**, write a new memory file and add one
     index line to `MEMORY.md` (do not edit existing memory entries).

   - **whole-file** — skills, commands, subagents, output styles. On **create**, write the
     templated file. On **update**, `Read` the current file -> insert the new step/section ->
     write it back.

3. **For ANY update** (all families), **show a diff/summary** of what will change and ask the user
   to confirm before writing. **Partial rejection inside a bundle:** creates apply directly; each
   update gets its own diff-confirm. If the user rejects one artifact's update, still apply the
   rest of the bundle, note the skipped artifact in the report, and — when the rejected artifact is
   load-bearing for the usage (per its `role_in_workflow`) — warn that the usage is incomplete.

4. **Never invent secrets or credentials** — MCP/API values are left as `<PLACEHOLDER>` for the
   user to fill in.

5. **Validate frontmatter** on file-based artifacts: the `name` field must equal the
   directory/file kebab-case name.

## Step 6 — Report

Print a table of every artifact touched, **grouped by usage** and leading with the usage:

| Usage | How to invoke | Artifact path | Type | create / update |
|---|---|---|---|---|

Then add a **LOAD note**:

- User / project skills, commands, agents, rules, settings, and permissions load immediately or on
  the next prompt.
- **Plugin-scope** artifacts need `/reload-plugins`.
- **Output styles** need `/clear` or a new session to take effect.

If anything was **deferred** (plugins, keybindings, monitors, status line), list it as a
suggestion rather than applying it.

---

## Edge cases

- **Nothing recurring** — if no pattern repeats >=2x, report "nothing to harvest (needs >=2
  repeats)" and create nothing.
- **Not a git repo** — `git rev-parse` fails, so the discovery uses the plain `pwd` hash; for
  artifact scope, **project** falls back to **user** scope (there is no repo `.claude/` to write
  into).
- **Re-runs are safe** — the existence check + diff-before-apply means running `/harvest` again on
  the same session updates rather than duplicates.
- **settings / MCP merges** — always **backup + validate + abort-on-invalid**; never partial-write
  a settings or `.mcp.json` file.
- **Huge transcripts** — the analysis subagent samples by intent-cluster (>~20k lines) and never
  pastes raw transcript content back.

---

## Done when

- The transcript PATH was resolved from `$ARGUMENTS` (per Step 1, or supplied via fallback) and
  only its tail was read in the main context — never the whole file.
- A single analysis subagent returned **usage-centric** opportunities with `artifacts[]`, capped
  at 4 (no raw transcript content leaked back); extras beyond 4 were listed as "also noticed".
- Every artifact in every bundle was checked against `../../references/artifact-catalog.md` AND the
  minimality rule.
- Usage cards were printed, the user multi-selected **usages** (never artifact types), and scope
  was confirmed per accepted usage in one batched question — settings-based artifacts fell back
  from plugin scope where needed.
- Zero selection ended with "nothing materialized"; partial rejections applied the rest of the
  bundle and were noted (with an incomplete-usage warning when load-bearing).
- For every artifact in every accepted usage, create-vs-update was resolved by an existence check;
  updates showed a diff and were confirmed; settings/MCP merges were backed up, deep-merged,
  validated, and aborted on invalid JSON; secrets were left as `<PLACEHOLDER>`.
- Frontmatter `name` matches the dir/file kebab name on all file-based artifacts.
- A final table grouped artifacts by usage (usage · how-to-invoke · path · type · create/update),
  plus the LOAD note and any deferred suggestions.
