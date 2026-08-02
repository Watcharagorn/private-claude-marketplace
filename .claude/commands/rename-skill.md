---
description: Rename a plugin skill and rewrite every cross-reference, then verify nothing dangles
argument-hint: [plugin] [old-skill-name] [new-skill-name]
allowed-tools: [Bash, Grep, Read, Edit, Skill]
---

# Rename Plugin Skill

Rename one skill inside a plugin in this marketplace repo and fix every reference to it in
the same pass. Arguments provided: $ARGUMENTS

- `$1` = plugin name (e.g. `mentor`, `loom`). Required.
- `$2` = current skill directory name (e.g. `mentor-plan`). Required.
- `$3` = new skill directory name (e.g. `plan`). Required.

A skill name appears in far more places than its own directory — command bodies invoke it as
`$1:$2`, hook scripts match on it literally, the plugin README lists it, and sibling skills
link to it. A rename that misses one of those leaves a silently broken invocation that no
JSON validator catches, which is why the discovery grep and the final verification grep both
matter.

If the user states a rule instead of one pair (e.g. "drop the `mentor-` prefix from every skill
that has it"), expand it into the matching pairs first, list them, then run the steps below
once per pair.

## Steps

1. **Preflight.** Confirm `plugins/$1/skills/$2/SKILL.md` exists and `plugins/$1/skills/$3`
   does not. Abort with a clear message if either check fails — a rename onto an existing
   directory would merge two skills.
2. **Discover cross-references.** `grep -rln "$2" plugins/$1 --include='*.md' --include='*.json' --include='*.sh'`
   and keep the file list. Run it before the move so the old name is still findable everywhere.
3. **Move the directory.** `git mv plugins/$1/skills/$2 plugins/$1/skills/$3` — `git mv` keeps
   the rename visible in history rather than showing a delete plus an add.
4. **Fix the frontmatter.** Set `name: $3` in the moved `SKILL.md`. The frontmatter `name` must
   equal the directory name or the skill will not load under the name people invoke.
5. **Rewrite the references.** In every file from step 2, replace the literal `$2` with `$3`,
   treating `$1:$2` invocation syntax as `$1:$3` and preserving surrounding markdown backticks.
6. **Verify.** Re-run `grep -rn "$2" plugins/$1`. Report PASS only when zero hits remain. Call
   out any deliberate survivors (CHANGELOG or historical prose) explicitly instead of letting
   them pass silently.
7. **Quality gate.** Per this repo's CLAUDE.md, load `/skill-creator:skill-creator` before
   accepting the modified `SKILL.md`, then run `/validate-skills $1 $3`.

## Output

A summary table: directory renamed, each file edited with its replacement count, the final
grep verdict, and the validation verdict. Fail loudly if step 6 found survivors.
