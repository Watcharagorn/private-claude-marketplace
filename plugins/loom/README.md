# loom

Session-driven harvesting and plugin lifecycle tools: **harvest** working sessions into reusable
Claude Code artifacts (auto-folded per session), **audit** an existing plugin from a session to find &
fix how it misbehaved, **learn** from every session that ever used a plugin (or from one named
session) with both audit + enhance lenses, **track** plugin usage so learning is instant, **automate**
a daily unattended harvest+learn schedule, **onboard** new users through the whole setup, and
**publish** releases with the plugin manifest, marketplace catalog, README, and git kept in sync.

New here? **`/loom:onboard`** walks through everything below step by step.

## Scope

The plugin-lifecycle skills (`audit-plugin`, `learn`, `publish-plugin`) operate **on this marketplace
repo** — they write `plugins/<name>/`, edit `.claude-plugin/marketplace.json`, and commit/push this
repo; run them with **cwd = this repo**. `learn` **discovers** sessions machine-wide (across every
project folder, from the active config dir) but its implement + publish tail is repo-scoped like the
others. `harvest-automations` and `track` are the exceptions: both work in **any** repo (or none) —
`harvest-automations` harvests a session (or, with no argument, **every un-harvested session of the
current project, auto-folding each session's artifacts** at project scope) into user/project
artifacts, keeping a per-project ledger + watermark in the config dir; `track` only touches config-dir
state. Enable `loom@private-marketplace` wherever you want `/harvest` or usage tracking.

## Commands

| Command | Args | Does |
|---|---|---|
| `/loom:harvest` | `[session-id \| transcript.jsonl \| --dry-run \| --review \| --headless]` | No arg: **sequentially auto-harvest** every un-harvested session of the current project — passing artifacts fold in per session with no prompts, at project scope (`git diff` reviews them); per-project ledger + watermark skip done ones and advance per session. `--review` confirms each session; `--dry-run` previews. Id/path: harvest that **one** session **interactively**. Never packages or publishes a plugin |
| `/loom:audit-plugin` | `[session] [plugin]` | Audit an existing plugin from **one** session (the active one if none named) — find how it misbehaved (gate false-positives, wrong-skill calls, retries, post-run surprises) and ship the fixes; one release |
| `/loom:learn` | `<plugin> [session-id] [--dry-run] [--review] [--headless]` | Bare `<plugin>`: learn from **every** unanalyzed session that used it (every project of the active config dir) — one agent per session, both lenses, processed **one at a time, oldest first**: expert-review then **auto-implement** approved items, **commit per session**, one release when the backlog drains; a per-plugin ledger + watermark means sessions are never re-analyzed. `--review` confirms each session; `--headless` does one session per invocation (the daily runner loops it). With a session id: analyze just that **one** session interactively (both lenses; ledger/watermark untouched) |
| `/loom:track` | `[plugin \| marketplace …] [--stop]` | Opt in to usage tracking so `/loom:learn`'s discovery is instant — records which **enabled** plugins loom indexes at session end; no args = status |
| `/loom:automate` | `[--status \| --stop]` | Set up (or inspect/remove) the **daily scheduled headless run** — launchd/cron fires `claude -p` with `--headless` harvest per configured project + concurrent learn rounds per tracked plugin. Idempotent setup |
| `/loom:onboard` | | Guided, resumable setup walkthrough: verify the hook, opt into tracking, learn the modes, optionally schedule the daily automation, finish with a dry-run |

Unqualified forms (`/harvest`, `/audit-plugin`, `/learn`, `/track`, …) also resolve while no other
enabled plugin ships a same-named command.

## Skills

| Skill | Version | Role |
|---|---|---|
| `harvest-automations` | 1.0.0 | Session(s) → loose reusable user/project artifacts across the full customization surface (any repo); with no arg, a **sequential project-wide sweep that auto-folds artifacts per session** via a per-project ledger + watermark (`--review` to confirm each session). Never packages or publishes a plugin |
| `audit-plugin` | 1.0.1 | One session → fixes for how an existing plugin misbehaved (AUDIT lens; select → review → implement → one release) |
| `learn` | 1.1.0 | A plugin's sessions → one plugin, both audit + enhance lenses. Bare: **all** unanalyzed sessions processed one at a time (per-session agent + review + **auto-implement** + per-session commit, ledger + watermark, one release at drain); headless: one session per invocation for the runner's loop; with a session id: that **one** session, interactive |
| `track` | 0.1.0 | Opt-in usage tracking of enabled plugins (any marketplace) → the index that makes `learn` fast |
| `automate` | 0.3.0 | Daily scheduled headless run (launchd/cron): harvest configured projects + concurrent learn rounds per tracked plugin, unattended; per-config-dir schedule isolation |
| `onboard` | 0.1.2 | Guided, resumable loom setup walkthrough — delegates to `track`/`automate`, ends with a verification dry-run |
| `publish-plugin` | 1.2.2 | Release: semver bump, manifest + README sync, validation, commit + push |

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
`harvest/` for project-wide harvest, `automation/` for the daily schedule), never in a repo. Disabling
a plugin pauses its tracking automatically — the hook re-checks effective enablement per session.

## Daily automation (opt-in)

`/loom:automate` installs a once-a-day scheduled job (launchd on macOS, cron on Linux) that runs
`claude -p '/loom:harvest --headless'` in each configured project and, for each tracked plugin,
**concurrent rounds** of `claude -p '/loom:learn <plugin> --headless --concurrent'` (from this repo) —
each round fires up to `concurrency` slots at once (default 3, guarded 1–3), one per isolated git
worktree, each claiming a different backlog session under a per-plugin lock. A worker commits in its
own worktree and reports via a result sidecar; the orchestrator cherry-picks in claim order, finalizes
the ledger only after a clean merge, requeues anything that conflicts, and publishes the bundle once
the queue drains (up to 24 fires/plugin/day, summed across slots). `--headless` guarantees zero
prompts — dead ends stop cleanly, and the runner's own session is skipped. The runs use
`--permission-mode bypassPermissions`; the guardrails are project-scope folds (review with `git diff`),
per-session expert review in `learn`, and the ledgers making every run incremental. A once-per-day
stamp, per-invocation watchdog, and logs (shared plus one per slot) live under `$cfg/loom/automation/`.
Unattended runs default to `claude-sonnet-5` at `xhigh` effort with a 2-hour per-invocation ceiling —
the ceiling stays put when the model gets cheaper, since it bounds one session's analyze→implement→commit;
override per install with `model` / `effort` / `maxRunSecs` / `concurrency` in `config.json` (read fresh
at every fire, no re-install). `--status` inspects,
`--stop` uninstalls. Each `CLAUDE_CONFIG_DIR` gets its own isolated schedule (per-config launchd
label / cron marker), and the runner derives its config dir from its installed location — so its
headless sessions and credentials always belong to the config dir it was set up under, and
several config dirs can run side by side without touching each other.

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
- `scripts/automate/daily-run.sh` — the daily headless runner; `automate` **copies** it to
  `$cfg/loom/automation/bin/` at setup (the scheduler must never point into the plugin cache, which
  moves on updates).

Runtime state (created on demand; **never** committed to any repo):

```
$cfg/loom/                     # cfg = ${CLAUDE_CONFIG_DIR:-$HOME/.claude}
├── learning/                  # track + learn state
│   ├── config.json            # track opt-in: which plugins to index
│   ├── usage-index.jsonl      # one line per finished session (hook-written)
│   ├── <plugin>.json          # per-plugin analyzed ledger + watermark (learn-written)
│   └── reports/               # consolidated + raw learn findings
├── harvest/                   # harvest-automations project-wide state
│   ├── <hashed-project>.json  # per-project analyzed ledger + watermark (harvest-written)
│   └── reports/               # per-run project-wide harvest reports (one section per session)
└── automation/                # loom:automate daily-schedule state
    ├── config.json            # projects to harvest, schedule time, marketplace repo (+ optional model / effort / maxRunSecs)
    ├── bin/daily-run.sh       # the installed runner (copied out of the plugin)
    ├── logs/                  # one log per day
    └── stamps/                # once-per-day success stamp
```

## Developing these skills

Installed plugins are served from the marketplace's git clone, pinned to a commit — working-tree
edits are **not** live. To pick up changes: push to `origin develop`, then
`/plugin marketplace update private-marketplace`, then `/reload-plugins`.
