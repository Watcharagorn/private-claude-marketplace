---
description: Map every mention of one or more keywords across a plugin's skills/hooks/commands/references
argument-hint: [plugin] [keyword ...]
allowed-tools: [Bash, Grep, Read]
---

# Plugin Concept Map

Sweep one plugin's whole customization surface for every place a concept or keyword
currently lives — before redesigning its logic — instead of hand-running grep/find/sed
one file at a time. Arguments provided: $ARGUMENTS

- `$1` = plugin name (e.g. `mentor`). Required.
- `$2...` = one or more keywords to map (e.g. `model effort subagent_type dispatch`).
  Required, at least one.

## Steps

1. **Locate matching files.** `grep -rniE "\b($2|...)\b" plugins/$1/{skills,hooks,commands,references} -l`
   (build the alternation from every keyword in `$2...`) to list every file mentioning any
   of the keywords.
2. **Extract context per hit.** For each matching file, pull the surrounding lines around
   every hit (`grep -n -B2 -A2` or a targeted `sed -n` range); for files with dense hits,
   read the whole file instead.
3. **Classify each hit.** Separate skill/command frontmatter fields (e.g. `model:`,
   `effort:`, `subagent_type:`) from plain prose mentions, and note which files are
   dispatch-agent definitions vs documentation/reference files.
4. **Report as a map.** Group by file, listing line number, matched keyword, and short
   context for each hit, so every place the concept lives is visible at a glance before any
   edit is made.

## Output

A file:line concept map for the plugin — grouped by file, each hit annotated with its
keyword, surrounding context, and whether it's a config field or prose mention.
