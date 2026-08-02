---
name: hook-test-scaffold
description: Write or rewrite a sandboxed bash regression-test suite for a plugin hook script in this marketplace repo, following the house template (isolated $HOME, mktemp scratch repo, trap cleanup, chk() PASS/FAIL counter, RESULT line). Use this whenever hook behavior changes or a new hook lands — triggers include "write tests for hooks/<name>.sh", "rewrite the hook test suite", "add regression tests for this hook", "this hook has no tests", or any edit to a plugins/*/hooks/*.sh script that changes its allow/block logic. Reach for it even when the user just says "test this hook" without mentioning a template.
---

# Hook Test Scaffold

Plugin hooks in this repo are shell scripts the harness runs on lifecycle events. They read
real state — `$HOME`, the git repo, files under the config dir — and decide to allow or block.
That makes them exactly the kind of code that is easy to break silently and painful to test
carelessly: a test that touches the real `$HOME` or the real repo can corrupt the machine it
runs on, and a test that skips the edge cases passes while the hook fails in the field.

The suites under `plugins/*/hooks/tests/` all follow one template that solves this — an
isolated sandbox, deterministic cleanup, and a self-counting assertion helper whose final
`RESULT:` line `/verify-plugin-edits` can read. Follow that template so every hook's suite
stays readable to whoever reads the next one, and so the counts aggregate.

## Steps

### Step 1 — Enumerate what the hook actually does

Read the target script under `plugins/<plugin>/hooks/` end to end before writing anything.
List every branch that produces an observable outcome: each allow path, each block path, each
early return. Then list the edge cases the branch logic implies — empty or malformed stdin,
run outside a git repo, missing state file, stale state, an absent dependency script.

The edge cases are where hooks actually fail, so treat this list as the test plan. If a branch
is unreachable or an edge case is genuinely impossible, say so rather than writing a test that
asserts nothing.

### Step 2 — Scaffold the file

Write `plugins/<plugin>/hooks/tests/test-<hook>.sh`:

```bash
#!/usr/bin/env bash
# Regression tests for hooks/<hook>.sh — <one line on what it guards>
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$(cd "$SCRIPT_DIR/.." && pwd)"
for dep in "$HOOKS/<hook>.sh"; do
  [ -f "$dep" ] || { echo "FATAL: $dep not found"; exit 1; }
done

ROOT="$(mktemp -d)"
SANDBOX="$ROOT/home"
mkdir -p "$SANDBOX"
trap 'rm -rf "$ROOT"' EXIT

PASS=0; FAIL=0
chk() {  # chk <description> <command...>
  local desc="$1"; shift
  if "$@"; then PASS=$((PASS+1)); echo "ok   — $desc"
  else FAIL=$((FAIL+1)); echo "FAIL — $desc"; fi
}
```

Use `set -uo pipefail`, not `set -e`: a failing assertion must record a FAIL and let the suite
continue, not abort the run and hide every test after it.

Point the hook at `$SANDBOX` (via `HOME=` / `CLAUDE_CONFIG_DIR=`) rather than the real config
dir. If the hook reads git state, `git init -q -b main` a scratch repo under `$ROOT` with one
throwaway commit — never run the hook against the working repo. The `trap ... EXIT` guarantees
cleanup even when the suite exits early.

### Step 3 — Assert one section per behavior

Group assertions under section headers matching the step-1 list, so a failure points straight
at the behavior that regressed:

```bash
echo "== A. blocks when <condition> =="
chk "exits non-zero on empty stdin" bash -c 'printf "" | "$HOOKS/<hook>.sh"; [ $? -ne 0 ]'
```

Cover the happy path and every edge case you enumerated. Prefer asserting on the hook's
observable contract — exit code, stdout JSON, the state file it wrote — over its internals,
so the tests survive refactors.

### Step 4 — Close with the RESULT line

End the file with:

```bash
echo "RESULT: PASS=$PASS FAIL=$FAIL"
```

`/verify-plugin-edits` parses this line to roll the suite into its pre-commit check, so the
format is load-bearing — keep it exact.

### Step 5 — Run it to green

Run `bash plugins/<plugin>/hooks/tests/test-<hook>.sh` and iterate until `FAIL=0` and every
behavior from step 1 has an assertion. When a test fails, decide deliberately whether the hook
or the expectation is wrong — a test edited to match broken behavior is worse than no test.

Finish by reporting the tally and which behaviors are now covered.
