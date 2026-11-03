---
description: Run the canonical host-neutral plugin verification gate.
argument-hint: <plugin> | --root
allowed-tools: [Bash]
---

# Verify Plugin Edits

Run the shared release gate for the named plugin. It validates canonical
metadata and host projections, runs deterministic tests, checks every bundled
skill when the validator is available, and performs isolated clean-cache
installs with each available host CLI. An unavailable host CLI is reported as
a warning rather than masking the deterministic result.

Pass `--root` instead of a plugin name for a root-only change (`.claude/**`, `CLAUDE.md`):
`verify-plugin-edits --root` runs the repo's root hook suites (`.claude/hooks/tests/*.sh`) and
fails if any suite fails or none match.

```bash
scripts/verify-plugin-edits "$1"
```
