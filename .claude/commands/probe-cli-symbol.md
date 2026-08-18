---
description: Probe the installed claude CLI binary for an undocumented symbol/behavior via strings + widening-context grep
argument-hint: [keyword-or-symbol]
allowed-tools: [Bash]
---

# Probe CLI Symbol

Reverse-engineer how the installed `claude` binary handles an undocumented keyword or
config field (e.g. a `teammate` setting, an internal `tengu_*` event name) by extracting
its minified source strings and widening context around each hit. Arguments provided:
$ARGUMENTS

- `$1` = keyword or symbol to search for (e.g. `teammateMode`, `resolveTeammateModel`,
  `tengu_effort_command`). Required.

## Steps

1. **Locate the binary.** `which claude` (fall back to `~/.local/bin/claude`); confirm it
   exists and note its path.
2. **Initial sweep.** `strings -a <binary> | grep -iE "$1"` — list distinct candidate
   symbol/string names that mention the keyword.
3. **Widen context per candidate.** For up to the top 5 candidates, run
   `grep -ao ".\{200\}<candidate>.\{0,600\}" <binary>` to pull the surrounding minified
   source around each hit.
4. **Try related variants.** Also sweep camelCase, snake_case, and `tengu_`-prefixed forms
   of `$1` (e.g. `$1` -> `tengu_$1`, snake_case(`$1`)) the same way, since the minified
   source may use a different casing than the search term.
5. **Report.** Group hits by candidate symbol, showing the surrounding context for each,
   and flag which look like function definitions vs plain string literals.

## Output

A summary per candidate symbol: where it was found, the surrounding source context, and
whether it reads as a function definition or a string literal — enough to infer the
mechanism without needing another manual strings/grep round.
