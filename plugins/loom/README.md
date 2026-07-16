# loom

Session-driven harvesting and plugin lifecycle tools: **harvest** a working session into reusable
Claude Code artifacts or a new packaged plugin, **tune** (audit/enhance) an existing plugin from a
real session, **learn** from every session that ever used a plugin in one command, **track** plugin
usage so that learning is instant, and **publish** releases with the plugin manifest, marketplace
catalog, README, and git kept in sync.

## Scope

The plugin-lifecycle skills (`harvest-to-plugin`, `tune-plugin`, `learn`, `publish-plugin`) operate
**on this marketplace repo** — they write `plugins/<name>/`, edit `.claude-plugin/marketplace.json`,
and commit/push this repo; run them with **cwd = this repo**. `learn` **discovers** sessions
machine-wide (across every project folder, from the active config dir) but its implement + publish
tail is repo-scoped like the others. `harvest-automations` and `track` are the exceptions: both work
in **any** repo (or none) — `harvest-automations` harvests any session into user/project artifacts,
and `track` only touches config-dir state. Enable `loom@private-marketplace` wherever you want
`/harvest` or usage tracking.

## Commands

| Command | Args | Does |
|---|---|---|
| `/loom:harvest` | `[session-id \| transcript.jsonl]` | Analyze a session and create/update reusable Claude Code artifacts (skills, commands, agents, hooks, permissions, rules, …) at user/project scope — works in any repo (moved from `mentor` v0.45.0) |
| `/loom:harvest-to-plugin` | `[session-id \| transcript.jsonl]` | Analyze a session, package repeated work as a **new** plugin (or merge into an existing one), register it, offer to publish |
| `/loom:tune-plugin` | `<session> [plugin]` | Improve an existing plugin from a session — **both** lenses (audit + enhance), one consolidated release |
| `/loom:audit-plugin` | `<session> [plugin]` | `tune-plugin` with **lens = audit** — find & fix misbehavior only |
| `/loom:enhance-plugin` | `<session> [plugin]` | `tune-plugin` with **lens = enhance** — eliminate redundant manual work only |
| `/loom:learn` | `<plugin> [--dry-run]` | Learn from **every** unanalyzed session that used a plugin (machine-wide) — one agent per session, merged findings, one consolidated release; a per-plugin ledger + watermark means sessions are never re-analyzed |
| `/loom:track` | `[plugin \| marketplace …] [--stop]` | Opt in to usage tracking so `/loom:learn`'s discovery is instant — records which **enabled** plugins loom indexes at session end; no args = status |

Unqualified forms (`/harvest-to-plugin`, `/tune-plugin`, `/learn`, `/track`, …) also resolve while no
other enabled plugin ships a same-named command.

## Skills

| Skill | Version | Role |
|---|---|---|
| `harvest-automations` | 0.3.0 | Session → reusable user/project artifacts across the full customization surface (any repo) |
| `harvest-to-plugin` | 0.1.0 | Session → new plugin (analysis, GAP scan, materialize, register) |
| `tune-plugin` | 0.2.0 | Session → fixes/enhancements for an existing plugin (audit / enhance / both) |
| `learn` | 0.1.0 | **All** unanalyzed sessions that used a plugin → one plugin (per-session agents, ledger + watermark, one release) |
| `track` | 0.1.0 | Opt-in usage tracking of enabled plugins (any marketplace) → the index that makes `learn` fast |
| `publish-plugin` | 1.2.0 | Release: semver bump, manifest + README sync, validation, commit + push |

Skill frontmatter versions are independent of the plugin version (publish-plugin's own rule).

## Tracking (opt-in) — making `learn` instant

`learn` always works: with no setup it scans every transcript in the active config dir to find the
sessions that used a plugin. `track` makes that instant.

1. **`/loom:track mentor`** — records the opt-in. Only **enabled** plugins are accepted (at any scope:
   user, current-project, or a machine-wide project-scoped install). One call can track several
   plugins across several marketplaces; a marketplace name expands to its enabled plugins.
2. **loom's SessionEnd hook** (`hooks/track-usage.sh`) then appends one line per finished session to a
   usage index, recording how many markers each tracked+enabled plugin left. It is **fail-soft** (a
   session can never fail to end because of tracking) and costs nothing when nothing is tracked.
3. **`/loom:learn mentor`** reads the index and only scans sessions it hasn't already indexed.

`/loom:track` (no args) shows status; `/loom:track --stop mentor` stops tracking (the index is kept).
All tracking state lives in the config dir (`$cfg/loom/learning/`), never in a repo. Disabling a
plugin pauses its tracking automatically — the hook re-checks effective enablement per session.

## Architecture

- `references/session-plugin-common.md` — the shared **§A–§K chassis** (transcript resolution,
  plugin-purpose map, catalog resolution, write safety, validation, expert review, confirmation
  card, publish handoff, and **§K** multi-session discovery + usage tracking + the learning ledger).
  Every session-driven skill resolves it **by glob at runtime**
  (`*/references/session-plugin-common.md`) — no other plugin should ever ship a copy.
- `references/artifact-catalog.md` — pattern → artifact-type authority, shared by
  `harvest-automations`, `harvest-to-plugin`, and `tune-plugin` (single copy at plugin root;
  formerly duplicated in mentor).
- `hooks/hooks.json` + `hooks/track-usage.sh` — loom's only hook: the opt-in SessionEnd usage
  indexer behind `track` / `learn` (§F path rule; fail-soft, every exit is `exit 0`).
- `skills/harvest-to-plugin/references/plugin-packaging.md` — valid-plugin assembly spec.
- `skills/harvest-to-plugin/evals/` — manual smoke-test scenarios + fixtures (see `evals.json`).

Runtime state (created on demand; **never** committed to any repo):

```
$cfg/loom/learning/          # cfg = ${CLAUDE_CONFIG_DIR:-$HOME/.claude}
├── config.json              # track opt-in: which plugins to index
├── usage-index.jsonl        # one line per finished session (hook-written)
├── <plugin>.json            # per-plugin analyzed ledger + watermark (learn-written)
└── reports/                 # consolidated + raw learn findings
```

## Developing these skills

Installed plugins are served from the marketplace's git clone, pinned to a commit — working-tree
edits are **not** live. To pick up changes: push to `origin develop`, then
`/plugin marketplace update private-marketplace`, then `/reload-plugins`.
