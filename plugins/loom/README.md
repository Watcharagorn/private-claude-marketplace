# loom

Session-driven harvesting and plugin lifecycle tools: **harvest** a working session into reusable
Claude Code artifacts, **audit** an existing plugin from a session to find & fix how it misbehaved,
**learn** from every session that ever used a plugin (or from one named session) with both audit +
enhance lenses, **track** plugin usage so learning is instant, and **publish** releases with the plugin
manifest, marketplace catalog, README, and git kept in sync.

## Scope

The plugin-lifecycle skills (`audit-plugin`, `learn`, `publish-plugin`) operate **on this marketplace
repo** — they write `plugins/<name>/`, edit `.claude-plugin/marketplace.json`, and commit/push this
repo; run them with **cwd = this repo**. `learn` **discovers** sessions machine-wide (across every
project folder, from the active config dir) but its implement + publish tail is repo-scoped like the
others. `harvest-automations` and `track` are the exceptions: both work in **any** repo (or none) —
`harvest-automations` harvests a session (or, with no argument, **every un-harvested session of the
current project**) into user/project artifacts, keeping a per-project ledger + watermark in the config
dir; `track` only touches config-dir state. Enable `loom@private-marketplace` wherever you want
`/harvest` or usage tracking.

## Commands

| Command | Args | Does |
|---|---|---|
| `/loom:harvest` | `[session-id \| transcript.jsonl \| --dry-run]` | No arg: harvest **every un-harvested session of the current project** (per-project ledger + watermark skip done ones; `--dry-run` previews). Id/path: harvest that **one** session. Creates/updates loose reusable artifacts (skills, commands, agents, hooks, permissions, rules, …) at user/project scope — works in any repo; never packages or publishes a plugin |
| `/loom:audit-plugin` | `[session] [plugin]` | Audit an existing plugin from **one** session (the active one if none named) — find how it misbehaved (gate false-positives, wrong-skill calls, retries, post-run surprises) and ship the fixes; one release |
| `/loom:learn` | `<plugin> [session-id] [--dry-run]` | Bare `<plugin>`: learn from **every** unanalyzed session that used it (machine-wide) — one agent per session, both lenses, merged findings, one release; a per-plugin ledger + watermark means sessions are never re-analyzed. With a session id: analyze just that **one** session (both lenses; ledger/watermark untouched) |
| `/loom:track` | `[plugin \| marketplace …] [--stop]` | Opt in to usage tracking so `/loom:learn`'s discovery is instant — records which **enabled** plugins loom indexes at session end; no args = status |

Unqualified forms (`/harvest`, `/audit-plugin`, `/learn`, `/track`, …) also resolve while no other
enabled plugin ships a same-named command.

## Skills

| Skill | Version | Role |
|---|---|---|
| `harvest-automations` | 0.5.0 | Session(s) → loose reusable user/project artifacts across the full customization surface (any repo); with no arg, a **project-wide sweep** of all un-harvested sessions via a per-project ledger + watermark. Never packages or publishes a plugin |
| `audit-plugin` | 1.0.0 | One session → fixes for how an existing plugin misbehaved (AUDIT lens; select → review → implement → one release) |
| `learn` | 0.2.0 | A plugin's sessions → one plugin, both audit + enhance lenses. Bare: **all** unanalyzed sessions (per-session agents, ledger + watermark, one release); with a session id: that **one** session |
| `track` | 0.1.0 | Opt-in usage tracking of enabled plugins (any marketplace) → the index that makes `learn` fast |
| `publish-plugin` | 1.2.0 | Release: semver bump, manifest + README sync, validation, commit + push |

Skill frontmatter versions are independent of the plugin version (publish-plugin's own rule). The AUDIT
and ENHANCE analysis briefs are shared by `audit-plugin` and `learn` via
`references/analysis-lenses.md` (one wording, read at heading anchors).

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
All loom runtime state lives in the config dir (`$cfg/loom/` — `learning/` for track + learn,
`harvest/` for project-wide harvest), never in a repo. Disabling a plugin pauses its tracking
automatically — the hook re-checks effective enablement per session.

## Architecture

- `references/session-plugin-common.md` — the shared **§A–§K chassis** (transcript resolution,
  plugin-purpose map, catalog resolution, write safety, validation, expert review, confirmation
  card, publish handoff, and **§K** multi-session discovery + usage tracking + the learning ledger,
  including **§K.6/§K.7** the authoritative harvest-ledger spec + del-then-append persistence recipe).
  Every session-driven skill resolves it **by glob at runtime**
  (`*/references/session-plugin-common.md`) — no other plugin should ever ship a copy.
- `references/analysis-lenses.md` — the shared **AUDIT / ENHANCE** analysis briefs, read at heading
  anchors by `audit-plugin` (AUDIT only) and `learn` (both). One wording, never re-inlined.
- `references/artifact-catalog.md` — pattern → artifact-type authority, shared by
  `harvest-automations`, `audit-plugin`, and `learn` (single copy at plugin root; formerly duplicated
  in mentor).
- `hooks/hooks.json` + `hooks/track-usage.sh` — loom's only hook: the opt-in SessionEnd usage
  indexer behind `track` / `learn` (§F path rule; fail-soft, every exit is `exit 0`).

Runtime state (created on demand; **never** committed to any repo):

```
$cfg/loom/                     # cfg = ${CLAUDE_CONFIG_DIR:-$HOME/.claude}
├── learning/                  # track + learn state
│   ├── config.json            # track opt-in: which plugins to index
│   ├── usage-index.jsonl      # one line per finished session (hook-written)
│   ├── <plugin>.json          # per-plugin analyzed ledger + watermark (learn-written)
│   └── reports/               # consolidated + raw learn findings
└── harvest/                   # harvest-automations project-wide state
    ├── <hashed-project>.json  # per-project analyzed ledger + watermark (harvest-written)
    └── reports/               # consolidated + raw project-wide harvest findings
```

## Developing these skills

Installed plugins are served from the marketplace's git clone, pinned to a commit — working-tree
edits are **not** live. To pick up changes: push to `origin develop`, then
`/plugin marketplace update private-marketplace`, then `/reload-plugins`.
