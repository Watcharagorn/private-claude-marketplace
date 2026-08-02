---
description: Run skill-creator's quick_validate.py over one or more plugin skills
argument-hint: [plugin] [skill1 skill2 ...]
allowed-tools: [Bash]
---

# Validate Skills

Validate skill directories of a plugin in this marketplace repo using the installed
skill-creator's `quick_validate.py`. Arguments provided: $ARGUMENTS

- `$1` = plugin name (e.g. `mentor`, `loom`). Required.
- `$2...` = optional skill names; when omitted, validate **every** skill dir under
  `plugins/$1/skills/`.

## Steps

1. **Resolve the validator dynamically** — never hardcode a version hash:

   ```bash
   SC_SCRIPT="$(find "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/cache" \
     -path '*skill-creator*/scripts/quick_validate.py' 2>/dev/null | sort | tail -1)"
   [ -n "$SC_SCRIPT" ] || { echo "quick_validate.py not found — is skill-creator installed?"; exit 1; }
   ```

2. **Build the skill list**: the skill names passed as arguments, or (when none given)
   `ls -d plugins/$1/skills/*/`.

3. **Validate each skill dir**:

   ```bash
   for s in <skill dirs>; do
     printf '%s: ' "$(basename "$s")"
     python3 "$SC_SCRIPT" "$s" && echo PASS || echo FAIL
   done
   ```

4. **Report** one pass/fail line per skill, surfacing any validator error text inline.
   Exit non-zero overall if any skill failed.
