# Dual-host marketplace maintainer primitive

Use this reference when the target is a marketplace or when maintainers need future changes to support both hosts by default.

## Source-of-truth model

Keep editable sources host-neutral:

```text
marketplace/catalog.json          plugin order, paths, listing policy
marketplace/catalog.schema.json   catalog contract
marketplace/capabilities.schema.json
plugins/<name>/plugin.json        portable Agent Plugins manifest
plugins/<name>/capabilities.json  workflow support and evidence
plugins/<name>/skills/...         portable workflows
```

Generate host projections:

```text
.claude-plugin/marketplace.json
.agents/plugins/marketplace.json
plugins/<name>/.claude-plugin/plugin.json
plugins/<name>/.codex-plugin/plugin.json   optional compatibility overlay
marketplace/support-matrix.md              optional human-readable projection
```

Names are examples, not a required migration. If the repository already has an equivalent canonical model, extend it.

## Required operations

A maintainer command should expose deterministic equivalents of:

- `new <plugin>`: create a portable plugin and default to support on both hosts.
- `sync [plugin]`: regenerate every affected host projection from canonical sources.
- `validate [plugin]`: validate schemas, paths, capability coverage, and byte-exact projection drift without modifying files.
- `test [plugin]`: run validation, plugin tests, and every evidence file claimed by supported workflows.
- `publish <plugin> --bump patch|minor|major`: bump the canonical semantic version, regenerate, validate, and test. Do not commit, tag, or push.

Targeted operations must still update or validate shared catalogs whose content depends on the target plugin.

## Capability contract

Record each user workflow, all skills that implement it, its fallback, and per-host status plus executable evidence. Require every shipped skill to appear exactly once so an unreviewed skill cannot bypass the support promise.

Use policy tiers such as:

- `dual-core`: every workflow is supported in Claude Code and Codex.
- `dual-enhanced`: the portable workflows are supported in both; one host may have documented commands, hooks, or UI enhancements.
- `host-specialized`: a real host dependency remains and a time-bounded waiver is complete.

A waiver needs an owner, rationale, missing capability, usable fallback, review date, and exit criteria. Expired waivers fail validation.

Derive aggregate host status from workflow rows. Never let a manually written summary claim more support than the evidence rows.

## Generation and validation invariants

- Identity fields come from the portable plugin manifest and are copied into projections.
- Catalog entries use host-specific source shapes but the same canonical plugin order and path. Local sources start with `./` and resolve from the marketplace root, not from the `.claude-plugin/` or `.agents/plugins/` manifest directory.
- Keep default `skills/` limited to dual-host workflows or portable wrappers. Put Claude-only skills in an adapter-specific custom directory declared only by Claude, or generate separate host package roots when a host cannot exclude them. Unsupported skills must not leak through a directory-wide discovery path.
- Generated files are not hand-edited and are compared as bytes after stable JSON/Markdown serialization.
- Projection paths and capability evidence stay inside the repository.
- A supported workflow has a test path; partial or unsupported rows describe their fallback.
- Manifest hook declarations match capability claims. Do not expose a host hook merely because another host has one.
- Validate portable skill frontmatter, names, descriptions, and package-relative resource paths.

## Clean-host release gate

Use disposable configuration/cache directories and a copied marketplace so existing installations cannot mask broken paths. The gate should:

1. Run canonical validation and deterministic tests.
2. Validate each skill and each host manifest.
3. Add the copied marketplace in Claude Code, install the plugin, and confirm it is enabled.
4. Add the copied marketplace in Codex, install the plugin, and confirm it is enabled.
5. Exercise a representative workflow from the installed package.

Resolve current CLI syntax first. A typical isolated local-marketplace check is:

```bash
smoke_root="$(mktemp -d "${TMPDIR:-/tmp}/dual-host-plugin.XXXXXX")"
mkdir -p "$smoke_root/claude" "$smoke_root/codex" "$smoke_root/work"
plugin_ref="$plugin_name@$marketplace_name"

(cd "$smoke_root/work" && env CLAUDE_CONFIG_DIR="$smoke_root/claude" \
  claude plugin marketplace add "$copied_marketplace" --scope user)
env CLAUDE_CONFIG_DIR="$smoke_root/claude" \
  claude plugin install "$plugin_ref" --scope user
env CLAUDE_CONFIG_DIR="$smoke_root/claude" claude plugin list

env CODEX_HOME="$smoke_root/codex" \
  codex plugin marketplace add "$copied_marketplace"
env CODEX_HOME="$smoke_root/codex" codex plugin add "$plugin_ref"
env CODEX_HOME="$smoke_root/codex" codex plugin list
```

Set `plugin_name`, `marketplace_name`, and `copied_marketplace` explicitly. Run Claude from a neutral work directory so the target repository's project settings do not contaminate the isolated configuration. Keep the disposable directory when evidence is needed; otherwise remove only the exact path returned by `mktemp` after validating its prefix.

If a CLI or authentication is unavailable, emit a visible warning and keep that smoke check unverified. A release policy may choose to fail on unverified host coverage.

Run each host's current strict validator when available and fix its complete output. Do not hardcode a validator's optional-field policy, but include ordinary identity metadata such as description, version, and author when the target schema and validator require it.

The private marketplace implementation that informed this pattern uses `scripts/marketplace` and `scripts/verify-plugin-edits`; reuse them only when they are actually present in the target repository. Its schemas and tier names are local governance examples, not universal Agent Plugins requirements.
