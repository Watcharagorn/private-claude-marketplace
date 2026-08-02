---
description: Generate an editable guided-tour review artifact — scenario walkthrough with pass/not-pass marks and feedback
argument-hint: [audience: user|dev|both] [subject or plan slug]
allowed-tools: [Bash, Read, Grep, Glob, Skill, Task, AskUserQuestion, Write, Edit, Artifact]
---

# mentor — tour

Build (or revise) an **editable review page**: a guided tour of scenarios a reviewer walks hands-on,
marking each **pass / not-pass** with feedback, published as a self-contained artifact with a
stable URL.

Immediately call `Skill({"skill": "mentor:tour"})` and follow it end to end. It guards against an
active planning session, resolves the subject (argument → newest mentor plan under
`.mentor/plans/` → current conversation), asks the audience once (skipped when given below), derives
a scenario manifest via a dispatched agent, cross-checks coverage, renders one self-contained HTML
per audience, and publishes to a stable URL — revisions republish in place, with parity kept across
audiences.

**If that call returns this command's own text** — any re-invocation or
previously-loaded notice — rather than a file whose frontmatter reads
`name: tour`, the skill body never loaded: this command and the skill share the
name `tour`. Resolve and read it directly, then follow that file end to end:

```bash
echo "${CLAUDE_PLUGIN_ROOT}/skills/tour/SKILL.md"
```

`Read` the printed path — `Read` cannot expand `${CLAUDE_PLUGIN_ROOT}` itself. **Do not
re-run the steps above this one:** they already ran, and a step that writes or marks
something can undo its own first pass when repeated.


The arguments below are **optional** — an audience (`user` | `dev` | `both`) and/or a subject
(topic or plan-slug substring):

$ARGUMENTS
