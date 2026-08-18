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

## Environment: a python3 that actually has `pyyaml`

`quick_validate.py` imports `yaml`. On this machine the system `python3` often lacks it, and
`pip3 install --user pyyaml` is refused under PEP 668 (`externally-managed-environment`) — so a
bare `python3 "$SC_SCRIPT"` dead-ends with `ModuleNotFoundError: No module named 'yaml'`.

Resolve an interpreter **before** step 3 and use `$PY` in place of `python3` there. Cache the
venv at a stable path so the bootstrap cost is paid once per machine, never per invocation:

```bash
PY=python3
if ! "$PY" -c "import yaml" >/dev/null 2>&1; then
  for cand in python3.13 python3.12 python3.11 /opt/homebrew/bin/python3 /usr/bin/python3; do
    command -v "$cand" >/dev/null 2>&1 && "$cand" -c "import yaml" >/dev/null 2>&1 && { PY="$cand"; break; }
  done
fi
if ! "$PY" -c "import yaml" >/dev/null 2>&1; then
  VENV="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.cache/quick-validate-venv"
  [ -x "$VENV/bin/python3" ] || { python3 -m venv "$VENV" && "$VENV/bin/pip" install -q pyyaml; }
  PY="$VENV/bin/python3"
fi
"$PY" -c "import yaml" >/dev/null 2>&1 \
  || { echo "cannot obtain a python3 with pyyaml — validate manually"; exit 1; }
```

Never build a throwaway venv under a session scratchpad — it gets cleaned up and the next run
rediscovers the same problem from scratch.
