# Marketplace maintainer contract

This repository ships plugins for both Claude Code and Codex. Treat portable
skills and durable project artifacts as the product; host commands, hooks, and
UI integrations are adapters.

## Canonical maintenance tools

- Use `scripts/marketplace` to synchronize, validate, and publish marketplace
  metadata. Do not hand-edit one host's catalog or manifest as a release
  substitute.
- Run `scripts/verify-plugin-edits <plugin>` after a plugin change. It runs the
  canonical marketplace validation, the plugin's deterministic tests, and
  available skill validation.
- Keep `plugin.json` and portable `skills/` free of host-only paths, tools, and
  guarantees. Put Claude Code or Codex-specific behavior in that host's adapter.

## Compatibility promises

- A change to `.mentor/`-style durable state must preserve readers for released
  data or include an explicit, tested migration.
- Host hooks are guardrails. A portable workflow must remain useful when hooks,
  subagents, publishing, or a structured-question UI are unavailable.
- Do not claim equal host behavior when a capability is adapter-only. Update the
  capability matrix and its tests with the implementation.

## Release safety

- Use semantic versioning from the canonical manifest. A breaking state or
  public-workflow change requires an explicit compatibility decision.
- Verify in a clean plugin cache before publishing. Source-tree success alone
  does not prove an installed plugin can resolve its bundled files.
- Stage exact paths only. Never use `git add -A` or `git add .` in this repo.
