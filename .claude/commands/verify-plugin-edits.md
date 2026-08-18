---
description: Hygiene check a plugin's edits before commit/publish (JSON, scripts, stale terms, descriptions, paths)
argument-hint: [plugin] [stale-term ...]
allowed-tools: [Bash, Grep, Read]
---

# Verify Plugin Edits

Run the full pre-commit/pre-publish hygiene checklist against one plugin in this
marketplace repo. Arguments provided: $ARGUMENTS

- `$1` = plugin name (e.g. `loom`, `mentor`). Required.
- `$2...` = optional stale/deleted-concept terms to confirm are gone from the plugin's text.

## Checks (run all; report one PASS/FAIL line per category)

1. **JSON validity** — `python3 -m json.tool` every `*.json` under `plugins/$1/`
   (plugin.json, evals.json, hooks.json, …) plus this repo's
   `.claude-plugin/marketplace.json`.
2. **Script syntax** — `sh -n` every `*.sh` under `plugins/$1/` (scripts/, hooks/).
3. **Stale terms** — for each term in `$2...`, `grep -rn` across `plugins/$1/skills/`,
   `plugins/$1/references/`, and `plugins/$1/commands/`; any hit is a FAIL with file:line.
4. **Description length** — for each `SKILL.md` under `plugins/$1/skills/`, measure the
   frontmatter `description` length; flag any over ~1024 chars.
5. **Hardcoded paths** — grep the plugin's hooks.json, commands, and skills for
   hardcoded `/Users/` or literal `~/.claude` paths that should be
   `$CLAUDE_PLUGIN_ROOT` / `${CLAUDE_CONFIG_DIR:-$HOME/.claude}`.
   - Also run `jq -r '.. | .command? // empty' plugins/$1/hooks/hooks.json` and check those
     command strings specifically — a hardcoded path hides more easily inside JSON than in
     prose, and it breaks for anyone whose config dir isn't the default.
6. **Test suites** — discover `plugins/$1/hooks/tests/*.sh` (falling back to
   `plugins/$1/tests/*.sh`) and run each with `bash`. Capture each suite's own
   `RESULT: PASS=n FAIL=n` tally plus its exit code, and sum a grand total. The category
   FAILs if any suite reports `FAIL>0` or exits non-zero. Without this, a green JSON/syntax
   check reads as "safe to commit" while the behavior the hooks are supposed to guarantee
   is already broken.
7. **Manifest description sync** — compare `.description` in
   `plugins/$1/.claude-plugin/plugin.json` against the same plugin's entry in
   `.claude-plugin/marketplace.json`. FAIL if the two strings differ; warn when the
   plugin.json description exceeds ~300 chars or the marketplace one exceeds ~450. These two
   descriptions are the plugin's shop window and they drift apart quietly, because nothing
   else in the repo reads both at once.
8. **Cross-block bash variable leakage** — for each `SKILL.md` under `plugins/$1/skills/`, extract
   every fenced ` ```bash ` block separately. Each fenced block runs as its own Bash tool call, so
   shell state — including variable assignments — does not survive from one block to the next. Flag
   any `$var` used in a block where it was never assigned, when that same name *is* assigned in a
   different block of the same file. Report `file:line` per hit and FAIL if any are found.

   That pattern is the fingerprint of a call site that got refactored while its derivation snippet
   stayed behind in the old block, and it fails silently rather than loudly: mentor v2.14.0 shipped
   `$repo_root` orphaned in `resume/SKILL.md` (making the release gate always report RELEASED) and
   `$branch` read from a different block than the one setting it in `ship/SKILL.md` (making
   `gh pr list --head ""` match every open PR). Both defeated the very safety check they belonged to.

   Implement it generically — split blocks with awk, collect each block's `NAME=` assignments, then
   cross-reference `$NAME` uses against them. Don't hardcode a list of variable names; the next
   instance will use different ones.
9. **Skill/command name collision** — for each `commands/<name>.md` under `plugins/$1/commands/`,
   check whether `plugins/$1/skills/<name>/` also exists (same basename). FAIL if so, listing the
   colliding pair. `Skill(skill="$1:<name>")` resolves ambiguously between the command file and the
   skill's `SKILL.md`, so the skill body can silently fail to load — the run still reports success
   while the skill's mandatory steps never execute. mentor v2.17.0 shipped exactly this for `resume`
   (skipping its secret scan and on-disk gate verification) and was fixed by renaming the skill
   (`resume` → `resuming`); see `plugins/mentor/hooks/tests/test-skill-command-collision.sh` for the
   full history. Use `find`, not a bare glob — a bare `for f in plugins/$1/commands/*.md` aborts under
   zsh's `nomatch` when a plugin has no `commands/` dir, silently skipping the check:

   ```bash
   find "plugins/$1/commands" -maxdepth 1 -name '*.md' 2>/dev/null | while read -r f; do
     c="$(basename "$f" .md)"
     [ -d "plugins/$1/skills/$c" ] && echo "COLLISION: $1 -> commands/$c.md <-> skills/$c/"
   done
   ```

   The fix is to rename the skill (and rewrite every cross-reference — `/rename-skill` does this),
   not to delete the command.

## Output

One PASS/FAIL line per category with `file:line` detail for every failure; end with an
overall verdict. Exit non-zero (report FAIL overall) if any category failed.
