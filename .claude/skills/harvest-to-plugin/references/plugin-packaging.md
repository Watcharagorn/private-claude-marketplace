# Plugin Packaging Reference (`harvest-to-plugin`)

**Purpose.** The artifact catalog (`artifact-catalog.md`) is the authority on **individual** artifact
types (skill/command/subagent/hook/rule) — their templates, merge recipes, and per-type safety. But
it deliberately **defers full-plugin generation** ("Deferred in V1 → Full Plugin"), because a bad
`plugin.json` or a malformed `marketplace.json` entry "risks creating an invalid registration that
breaks the plugin loader." This file is the spec for exactly that deferred surface: how to assemble
the harvested artifacts into a **valid, loadable plugin** in *this* marketplace repo, register it,
and hand off cleanly to `publish-plugin`.

Read this alongside `artifact-catalog.md` before writing any plugin file.

## Table of contents
1. Plugin directory layout
2. `plugin.json` schema
3. `marketplace.json` entry schema + registration recipe
4. Plugin-name collision handling (re-run safety)
5. Hooks inside a plugin (`hooks/hooks.json`, `${CLAUDE_PLUGIN_ROOT}`, `PermissionRequest`)
6. `rule` handling — the one type with no plugin scope
7. README (optional)
8. New-plugin vs. merge-into-existing + grouping rules
9. Handoff boundary to `publish-plugin`

---

## 1. Plugin directory layout

A plugin is a directory under `plugins/<name>/`. Only include the subdirs a harvested workflow
actually needs — do not scaffold empty folders.

```
plugins/<name>/
├── .claude-plugin/
│   └── plugin.json          # required manifest
├── commands/<cmd>.md         # thin entry points (optional)
├── skills/<skill>/SKILL.md   # playbooks (optional)
├── agents/<agent>.md         # subagents (optional)
├── hooks/
│   ├── hooks.json            # hook registrations (optional)
│   └── <script>.sh           # hook scripts (optional)
└── README.md                 # human docs (optional)
```

`<name>` is **kebab-case**, derived from the harvested workflow's purpose (e.g. `deploy-ticket`,
`env-sync`). It must match the `name` in `plugin.json` and the `marketplace.json` entry.

## 2. `plugin.json` schema

`plugins/<name>/.claude-plugin/plugin.json`:

```json
{
  "name": "<kebab-name>",
  "description": "<brief, present-tense, one-sentence purpose — ~50-220 chars, NOT a changelog>",
  "version": "0.1.0",
  "author": { "name": "NTBX" }
}
```

- `name` — required, matches the dir.
- `description` — required, a **brief blurb** of what the plugin *is* (its identity + one defining
  mechanism), not a feature inventory. Keep under ~220 chars. `publish-plugin` will trim bloat on
  sight, so start brief.
- `version` — **`0.1.0`** for a freshly harvested plugin (first release). Do not invent a higher
  version; `publish-plugin` owns future bumps.
- `author` — `{ "name": "NTBX" }` to match the repo convention.

Validate: `python3 -m json.tool plugins/<name>/.claude-plugin/plugin.json`.

## 3. `marketplace.json` entry schema + registration recipe

The top-level `.claude-plugin/marketplace.json` catalogs every plugin. Each `plugins[]` entry:

```json
{
  "name": "<kebab-name>",
  "source": "./plugins/<name>",
  "description": "<brief 1-2 sentence prose summary — target <=~400 chars, no changelog>",
  "category": "<one word, e.g. automation | development>"
}
```

- **No `version` field** in the marketplace entry (version lives only in `plugin.json`).
- `source` is the **relative path** `"./plugins/<name>"` — set it by this convention; do not copy a
  value from another repo.
- `category` — a short bucket (this marketplace uses simple words like `automation`/`development`).
  Pick the closest fit for the harvested workflow.

**Register safely (backup → jq → validate → restore on failure):**

```bash
mp=".claude-plugin/marketplace.json"
cp "$mp" "$mp.bak.$(date +%s)"
entry='{"name":"<name>","source":"./plugins/<name>","description":"<desc>","category":"automation"}'
jq --argjson e "$entry" '.plugins += [$e]' "$mp" > "$mp.tmp" \
  && jq empty "$mp.tmp" \
  && mv "$mp.tmp" "$mp" \
  || { echo "INVALID JSON — restoring backup"; rm -f "$mp.tmp"; cp "$mp".bak.* "$mp" 2>/dev/null; }
```

> **Note on `marketplace.json`'s top-level `name`.** In this repo it currently reads
> `"ntbx-marketplace"` (arguably should be `ntbx-infra-marketplace`). Do **not** change it as a side
> effect of registering a plugin — only touch `.plugins[]`. Flag the mismatch to the user if
> relevant, but leave it alone otherwise.

## 4. Plugin-name collision handling (re-run safety)

Before creating anything, check both the directory and the catalog entry — running the skill twice
must never duplicate an entry or clobber an existing plugin:

```bash
test -d "plugins/<name>" && echo "DIR EXISTS" || echo "DIR FREE"
jq -e --arg n "<name>" '.plugins[] | select(.name==$n)' .claude-plugin/marketplace.json >/dev/null \
  && echo "ENTRY EXISTS" || echo "ENTRY FREE"
```

- **DIR FREE + ENTRY FREE** → create the plugin and append the entry.
- **DIR EXISTS or ENTRY EXISTS** → this is an **update**, not a create. Merge new artifacts into the
  existing plugin (§8 merge path), leave the single marketplace entry as-is (refresh its
  `description` only if the purpose genuinely changed), and **never** append a second entry.
- **Name genuinely taken by an unrelated plugin** → pick a more specific `<name>` (and tell the
  user), rather than merging into a plugin that doesn't fit.

## 5. Hooks inside a plugin

`plugins/<name>/hooks/hooks.json` uses the same shape the catalog documents, but **plugin hook
commands must reference scripts via `${CLAUDE_PLUGIN_ROOT}`** — never a hardcoded `/Users/...` or
`~/.claude/plugins/...` path. Once the plugin installs under
`~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`, a hardcoded path silently breaks every
hook, and `publish-plugin` rejects it.

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash",
        "hooks": [ { "type": "command", "command": "bash ${CLAUDE_PLUGIN_ROOT}/hooks/<script>.sh", "timeout": 10 } ] }
    ]
  }
}
```

The plugin-only **`PermissionRequest`** event is available in `hooks.json` (not in user/project
`settings.json`). Always **merge-json** into an existing `hooks.json` (backup → `jq` → `jq empty` →
restore on failure); never overwrite it whole.

## 6. `rule` handling — the one type with no plugin scope

Per `artifact-catalog.md` §7, **rules have no plugin scope** in current Claude Code — they are
project- or user-scoped only. So a harvested rule cannot live inside `plugins/<name>/`. Write it as a
**project-scoped companion** at `<repo>/.claude/rules/<topic>.md` (whole-file on create,
append-section on update), and in the Step 7 summary present it as *a companion of* the plugin, not
part of it. Before defaulting to this, re-verify whether the installed Claude Code version supports
`<plugin-root>/rules/`; if it does, prefer placing the rule inside the plugin.

## 7. README (optional)

A `plugins/<name>/README.md` is optional. `publish-plugin` will add a changelog/feature line to it
*if it exists*, but does not require one. For a first harvested release, a short README describing the
workflow the plugin automates is nice-to-have, not mandatory — the commit message is the canonical
release note.

## 8. New-plugin vs. merge-into-existing + grouping

**Grouping** (how many plugins for N accepted workflows):
- Workflows serving **one cohesive purpose** → **one plugin** with several skills/commands.
- **Unrelated** workflows → **separate plugins** (one per cohesive purpose).

**New vs. merge** (decided with the skill's Step 3b GAP scan, not by name alone):
- **MERGE** into an existing plugin **iff** (a) the plugin-purpose map shows a strong purpose match
  **and** (b) the plugin-surface GAP scan shows the harvested workflow is **absent** from that
  plugin's current surface. Merge = read → insert → write-back (append a step/section to an existing
  `SKILL.md`, add an artifact into the existing `plugins/<name>/`, merge-json into its `hooks.json`).
- **NEW plugin** otherwise.
- If the GAP scan shows the workflow is **already implemented** → **create nothing** for it; report
  "already covered". This is what prevents proposing a redundant workflow.

## 9. Handoff boundary to `publish-plugin`

This file covers **building and registering** a plugin locally. It does **not** re-implement
versioning, README changelog, or git. When the user opts to publish, invoke the `publish-plugin`
skill and pass the plugin + intent (for a freshly harvested plugin: *"first release at 0.1.0 — do not
bump"*). `publish-plugin` owns semver, manifest/marketplace description sync, the hook-path
portability check, and the commit + push. Do not duplicate its logic here.
