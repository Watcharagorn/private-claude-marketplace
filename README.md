# Private Agent Marketplace

Marketplace repo hosting portable plugins under `plugins/<name>/` for Claude
Code and Codex. `AGENTS.md` defines the host-neutral maintenance contract.

## Maintainer workflow

The source of truth is deliberately host-neutral:

- `marketplace/catalog.json` owns plugin ordering and availability policy.
- `plugins/<name>/plugin.json` is the portable Agent Plugins manifest.
- `plugins/<name>/capabilities.json` maps every skill workflow to Claude Code
  and Codex support evidence.

Run `scripts/marketplace sync` to generate `.claude-plugin/marketplace.json`,
`.agents/plugins/marketplace.json`, compatibility manifests inside each
plugin, and [`marketplace/support-matrix.md`](marketplace/support-matrix.md).
Generated files are byte-checked and must not be edited by hand.

```bash
scripts/marketplace sync
scripts/marketplace validate
scripts/marketplace test
scripts/verify-plugin-edits mentor
```

Create and release through the same primitive:

```bash
scripts/marketplace new <plugin-name>
scripts/marketplace publish <plugin-name> --bump patch|minor|major
```

`new` starts with a `dual-core` contract: both hosts must be supported and
must name executable evidence. `dual-core` and `dual-enhanced` releases fail
validation when any workflow loses support on either host. A genuinely
host-specific workflow must use `host-specialized` plus an owner, fallback,
expiry date, and exit criteria; expired waivers fail validation.

## Installation smoke checks

Claude Code validates each plugin with `claude plugin validate
plugins/<name>`. Codex can exercise the local marketplace in an isolated cache:

```bash
export CODEX_HOME="$(mktemp -d)"
codex plugin marketplace add "$PWD"
codex plugin add mentor@private-marketplace
codex plugin list
```

Use a disposable `CODEX_HOME` for release checks so an older personal cache
cannot make a broken package appear healthy.
