---
description: Finish the current branch — simplify, test, then push and open a PR/MR
allowed-tools: [Bash, Read, Grep, Glob, Skill, AskUserQuestion]
---

# mentor — ship

Invoke `Skill({"skill": "mentor:ship"})` and follow it end to end: it
clean-checks the working tree, runs the simplify pass, optionally runs tests,
then asks where to ship (push + PR/MR, or push to upstream).

**If that call returns this command's own text** — any re-invocation or
previously-loaded notice — rather than a file whose frontmatter reads
`name: ship`, the skill body never loaded: this command and the skill share the
name `ship`. Resolve and read it directly, then follow that file end to end:

```bash
echo "${CLAUDE_PLUGIN_ROOT}/skills/ship/SKILL.md"
```

`Read` the printed path — `Read` cannot expand `${CLAUDE_PLUGIN_ROOT}` itself. **Do not
re-run the steps above this one:** they already ran, and a step that writes or marks
something can undo its own first pass when repeated.


$ARGUMENTS
