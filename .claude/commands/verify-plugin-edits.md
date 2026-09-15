---
description: Run the canonical host-neutral plugin verification gate.
argument-hint: <plugin>
allowed-tools: [Bash]
---

# Verify Plugin Edits

Run the shared release gate for the named plugin. It validates canonical
metadata and host projections, runs deterministic tests, checks every bundled
skill when the validator is available, and performs isolated clean-cache
installs with each available host CLI. An unavailable host CLI is reported as
a warning rather than masking the deterministic result.

```bash
scripts/verify-plugin-edits "$1"
```
