---
description: Opt in to loom usage tracking so /loom:learn's discovery is instant — record which ENABLED plugins (across any marketplace) loom should index at session end. No args shows status; --stop removes entries. Only tracks enabled plugins; never analyzes or publishes.
argument-hint: [plugin-name | marketplace-name …] [--stop]
allowed-tools: [Bash, Read, Write, Edit, AskUserQuestion]
---

# loom — track plugin usage

Follow the `track` skill end to end. It records your opt-in in the config dir; loom's SessionEnd hook
then indexes finished sessions so `/loom:learn` can skip scanning.

Parse the arguments:

- **No tokens** → **status**: what loom is tracking (grouped by marketplace), the index size, and each
  plugin's learn watermark.
- **One or more names** → **add**: each token is a **plugin name** or a **marketplace name** (sugar
  that expands to that marketplace's currently-enabled plugins). Only **enabled** plugins are accepted.
- **`--stop <name…>`** → **remove** the listed entries (the usage index is kept).

Works from any cwd — it only touches config-dir state, never a repo.

Arguments provided: $ARGUMENTS
