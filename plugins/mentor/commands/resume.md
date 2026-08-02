---
description: Browse this repo's saved mentor handoff notes and continue one in a fresh session
argument-hint: [slug substring or list number of the note to resume]
allowed-tools: [Bash, Read, Skill, Task, AskUserQuestion]
---

# mentor — resume

Browse the handoff notes saved for **this repo** and pick one to continue, in this fresh session.

Immediately call `Skill({"skill": "mentor:resume"})` and follow it end to end. It lists only the
current repo's live (unresolved) handoff notes (newest first, across every plan-topic folder), lets
you pick one — directly from the argument below, or interactively — then loads the chosen note and
resumes the task per its recommended mentor commands. The note is **stamped resolved** (never
re-listed) only once its work completes per the plan file or a nested `/mentor:handoff` supersedes
it — unfinished work stays resumable. It is the consume side of `/mentor:handoff` (which writes the
notes).

**If that call returns this command's own text** — any re-invocation or
previously-loaded notice — rather than a file whose frontmatter reads
`name: resume`, the skill body never loaded: this command and the skill share the
name `resume`. Resolve and read it directly, then follow that file end to end:

```bash
echo "${CLAUDE_PLUGIN_ROOT}/skills/resume/SKILL.md"
```

`Read` the printed path — `Read` cannot expand `${CLAUDE_PLUGIN_ROOT}` itself. **Do not
re-run the steps above this one:** they already ran, and a step that writes or marks
something can undo its own first pass when repeated.


The argument below is **optional** and pre-selects a note — a list number (1-based, newest first) or a
case-insensitive slug substring. If it is empty or matches nothing unambiguously, the skill lists the
notes and asks:

$ARGUMENTS
