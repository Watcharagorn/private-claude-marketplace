# plugin-ops

Session-driven harvesting and plugin lifecycle tools: **harvest** a working session into reusable
Claude Code artifacts or a new packaged plugin, **tune** (audit/enhance) an existing plugin from a
real session, and **publish** releases with the plugin manifest, marketplace catalog, README, and
git kept in sync.

## Scope

The plugin-lifecycle skills (`harvest-to-plugin`, `tune-plugin`, `publish-plugin`) operate **on
this marketplace repo** — they write `plugins/<name>/`, edit `.claude-plugin/marketplace.json`,
and commit/push this repo; run them with **cwd = this repo**. `harvest-automations` is the
exception: it harvests **any** session into user/project artifacts and works in any repo — enable
`plugin-ops@private-marketplace` wherever you want `/harvest`.

## Commands

| Command | Args | Does |
|---|---|---|
| `/plugin-ops:harvest` | `[session-id \| transcript.jsonl]` | Analyze a session and create/update reusable Claude Code artifacts (skills, commands, agents, hooks, permissions, rules, …) at user/project scope — works in any repo (moved from `mentor` v0.45.0) |
| `/plugin-ops:harvest-to-plugin` | `[session-id \| transcript.jsonl]` | Analyze a session, package repeated work as a **new** plugin (or merge into an existing one), register it, offer to publish |
| `/plugin-ops:tune-plugin` | `<session> [plugin]` | Improve an existing plugin from a session — **both** lenses (audit + enhance), one consolidated release |
| `/plugin-ops:audit-plugin` | `<session> [plugin]` | `tune-plugin` with **lens = audit** — find & fix misbehavior only |
| `/plugin-ops:enhance-plugin` | `<session> [plugin]` | `tune-plugin` with **lens = enhance** — eliminate redundant manual work only |

Unqualified forms (`/harvest-to-plugin`, `/tune-plugin`, …) also resolve while no other enabled
plugin ships a same-named command.

## Skills

| Skill | Version | Role |
|---|---|---|
| `harvest-automations` | 0.3.0 | Session → reusable user/project artifacts across the full customization surface (any repo) |
| `harvest-to-plugin` | 0.1.0 | Session → new plugin (analysis, GAP scan, materialize, register) |
| `tune-plugin` | 0.2.0 | Session → fixes/enhancements for an existing plugin (audit / enhance / both) |
| `publish-plugin` | 1.2.0 | Release: semver bump, manifest + README sync, validation, commit + push |

Skill frontmatter versions are independent of the plugin version (publish-plugin's own rule).

## Architecture

- `references/session-plugin-common.md` — the shared **§A–§J chassis** (transcript resolution,
  plugin-purpose map, catalog resolution, write safety, validation, expert review, confirmation
  card, publish handoff). Both harvest and tune resolve it **by glob at runtime**
  (`*/references/session-plugin-common.md`) — no other plugin should ever ship a copy.
- `references/artifact-catalog.md` — pattern → artifact-type authority, shared by
  `harvest-automations`, `harvest-to-plugin`, and `tune-plugin` (single copy at plugin root;
  formerly duplicated in mentor).
- `skills/harvest-to-plugin/references/plugin-packaging.md` — valid-plugin assembly spec.
- `skills/harvest-to-plugin/evals/` — manual smoke-test scenarios + fixtures (see `evals.json`).

## Developing these skills

Installed plugins are served from the marketplace's git clone, pinned to a commit — working-tree
edits are **not** live. To pick up changes: push to `origin develop`, then
`/plugin marketplace update private-marketplace`, then `/reload-plugins`.
