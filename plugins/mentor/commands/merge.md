---
description: Watch a PR's CI checks, triage a failure once, merge on green (gated)
argument-hint: "[PR#]"
allowed-tools: [Bash, Read, Grep, Skill, AskUserQuestion]
---

# mentor — merge

Invoke `Skill({"skill": "mentor:merge"})` and follow it end to end: it resolves
the open PR for the current branch (or `$ARGUMENTS` as a PR number), runs one
bounded `gh pr checks --watch`, triages a failure once (flake → single rerun;
regression → stop and report), and merges only on your explicit choice.

**If that call returns this command's own text** — any re-invocation or
previously-loaded notice — rather than a file whose frontmatter reads
`name: merge`, the skill body never loaded: this command and the skill share the
name `merge`. Resolve and read it directly, then follow that file end to end:

```bash
echo "${CLAUDE_PLUGIN_ROOT}/skills/merge/SKILL.md"
```

`Read` the printed path — `Read` cannot expand `${CLAUDE_PLUGIN_ROOT}` itself. **Do not
re-run the steps above this one:** they already ran, and a step that writes or marks
something can undo its own first pass when repeated.


$ARGUMENTS
