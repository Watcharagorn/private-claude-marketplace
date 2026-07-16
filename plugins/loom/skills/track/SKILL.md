---
name: track
description: Opt in to loom usage tracking so /loom:learn's discovery is instant. Records which enabled plugins — across any marketplace — loom should index at session end; a SessionEnd hook then appends one usage line per finished session. Invoke for "track <plugin>", "track <marketplace>", "start/stop tracking plugin usage", "tracking status", "what is loom tracking", or "/track [plugin | marketplace] [--stop]". Only ever tracks plugins that are ENABLED (at any scope — user, project, or machine-wide install); never analyzes or publishes (that is /loom:learn).
version: 0.1.0
---

# track — opt in to loom usage tracking

`track` is the small companion to `learn`. `learn` can always discover sessions by scanning every
transcript (chassis §K.2) — but that rescans hundreds of files each run. `track` records which
plugins you care about; loom's **SessionEnd hook** then writes one line per finished session to a
usage index (§K.5) so `learn` skips the scan for every session it has already seen.

**Tracking is opt-in and enabled-only.** Nothing is indexed until you name a plugin, and a plugin is
only tracked while it stays **enabled** somewhere (user, current-project, or a machine-wide install).
Disable a plugin and its tracking pauses automatically — no config edit needed.

**Many-to-many by design.** `track[]` holds any number of entries spanning any number of
marketplaces. One call may add several: each positional token is resolved independently as a **plugin
name** or a **marketplace name**.

```
/loom:track mentor sdlc-mini          # two plugins, one marketplace
/loom:track private-marketplace       # marketplace sugar → its currently-enabled plugins
/loom:track mentor ntbx-infra         # plugins from DIFFERENT marketplaces — fine
/loom:track                           # no args → STATUS
/loom:track --stop mentor             # remove entr(ies); index rows are kept (history)
```

## When NOT to invoke

- **You want to analyze / audit / enhance now** → `/loom:learn <plugin>` (works with or without
  tracking; tracking only makes its discovery faster).
- **The plugin isn't enabled anywhere** — `track` refuses it (tracking is enabled-only). Enable it
  first (`/plugin`), then track.

## Inputs

- **positional tokens** — zero or more plugin names and/or marketplace names.
- **`--stop`** — remove the named entr(ies) from `track[]` instead of adding.
- No tokens → **STATUS**.

State lives in the config dir (`cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"`,
`$cfg/loom/learning/config.json`) — **never** in this or any repo. `track` works from **any** cwd.

---

## Step 1 — Parse intent

No positional tokens → **STATUS** (Step 3). `--stop` present → **REMOVE**. Otherwise → **ADD**. Every
positional token is resolved on its own, so one invocation can add a mix of plugins and marketplaces
across marketplaces.

## Step 2 — Resolve the enabled surface (all scopes) and classify each token

Build the set of **enabled** `plugin@marketplace` across all three scopes, each tagged with where it
is enabled — tracking must never target a disabled/unknown plugin, and a plugin enabled only at
**project scope** (or installed project-scoped in *another* project) must still be trackable:

```bash
cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
{
  # (a) user scope
  jq -r '(.enabledPlugins // {}) | to_entries[] | select(.value==true) | "\(.key)\tuser"' \
     "$cfg/settings.json" 2>/dev/null
  # (b) current-project scope (a mention in either file makes it trackable here)
  for f in .claude/settings.local.json .claude/settings.json; do
    jq -r --arg cwd "$PWD" '(.enabledPlugins // {}) | to_entries[]
      | select(.value==true) | "\(.key)\tproject:\($cwd)"' "$f" 2>/dev/null
  done
  # (c) machine-wide install registry — includes PROJECT-SCOPED installs in OTHER projects
  jq -r '.plugins | to_entries[] | .key as $k | .value[]
    | "\($k)\t\(.scope)\(if .projectPath then ":"+.projectPath else "" end)"' \
     "$cfg/plugins/installed_plugins.json" 2>/dev/null
} | sort -u                                    # lines: "<plugin>@<marketplace>\t<scope-label>"
```

Keys are `plugin@marketplace` (verified format). Classify each token against this union:

- token equals the **plugin** part of some entry → resolve to `plugin@marketplace` (if the plugin
  name is ambiguous across two marketplaces, `AskUserQuestion` which marketplace).
- token equals a **marketplace** name (the part after `@`, or a `known_marketplaces.json` key) →
  **sugar**: expand to every currently-enabled plugin in it. **One-shot** expansion — plugins added
  to that marketplace *later* are NOT auto-tracked (state this in the report).
- token matches nothing enabled → **not enabled / unknown**: list what IS enabled (with scope
  labels) and skip that token; never add it.

Per-token verdict with its scope label, e.g. `mentor@private-marketplace (enabled: project —
~/workspace/general-assistant)`.

## Step 3 — Apply (ADD / REMOVE / STATUS)

- **ADD / REMOVE** — edit `$cfg/loom/learning/config.json` under chassis **§E merge-json** discipline
  (`mkdir -p "$cfg/loom/learning"`; **backup → `jq` → `jq empty` validate → restore backup on
  failure**; never partial-write). Schema, **deduped by `plugin@marketplace`** on add
  (`since` = `date -u +%Y-%m-%dT%H:%M:%SZ`):

  ```json
  { "schemaVersion": 1,
    "track": [
      { "plugin": "mentor",     "marketplace": "private-marketplace", "since": "2026-07-16T11:00:00Z" },
      { "plugin": "sdlc-mini",  "marketplace": "private-marketplace", "since": "2026-07-16T11:00:00Z" },
      { "plugin": "ntbx-infra", "marketplace": "ntbx-marketplace",    "since": "2026-07-16T11:05:00Z" }
    ] }
  ```

  Re-adding an already-tracked entry → "already tracked", no duplicate. REMOVE drops the listed
  `plugin@marketplace` entries; **the usage index is left intact** (index rows are history, not
  config). Corrupt/unknown-`schemaVersion` config → move aside, warn, start fresh.

- **STATUS** — print tracked plugins **grouped by marketplace**, flagging any that are now **disabled**
  (present in `track[]` but absent from the Step 2 union); the index size (`wc -l` of
  `usage-index.jsonl`) + newest `endTs`; and each plugin's ledger watermark
  (`$cfg/loom/learning/<plugin>.json` → `.watermark`, or "never learned").

## Step 4 — Report

- **ADD**: per added entry — "Tracking `<plugin>@<marketplace>` (enabled: `<scope>`). Sessions ending
  from now on are indexed at session-end; earlier history is covered by `/loom:learn`'s backfill
  scan." Marketplace sugar → name the plugins it expanded to + the one-shot caveat.
- **REMOVE**: "Stopped tracking `<plugin>@<marketplace>` (index rows kept). Run `/loom:learn` any time
  — it still discovers by scan."
- **STATUS**: the grouped listing above.

Never touch the usage index or any ledger from `track` — those are the hook's and `learn`'s.

---

## Rules

- **Enabled-only, all scopes.** Add only plugins present in the Step 2 union (user ∪ current-project ∪
  machine-wide install registry). Refuse anything else; disabling a plugin later pauses its tracking
  automatically (the hook re-checks effective enablement per session).
- **Per-token, many-to-many.** Each positional token resolves independently; one call may add plugins
  across several marketplaces. Marketplace names are one-shot sugar, never a standing subscription.
- **§E discipline on config.json** — backup, `jq`, validate, restore-on-failure; dedupe by
  `plugin@marketplace`. Never hand-edit past a partial write.
- **Config-dir state only** — `$cfg/loom/learning/config.json`; works from any cwd; never writes to a
  repo. `track` never analyzes, implements, or publishes — that is `learn`.

## Done when

- The intent (ADD / REMOVE / STATUS) was parsed; every token was classified against the all-scope
  enabled surface with a scope-labelled verdict.
- **ADD/REMOVE:** `config.json` was updated under §E discipline (deduped, validated) and each token
  reported; **STATUS:** the grouped listing (tracked-by-marketplace, disabled flags, index size +
  newest entry, per-plugin watermarks) was printed.
- Nothing outside `$cfg/loom/learning/config.json` was written; the index and ledgers were untouched.
