---
description: Zoom into any subject as focused topic × perspective HTML review pages — local files, never published
argument-hint: [subject or plan slug] [topic] [perspective]
allowed-tools: [Bash, Read, Grep, Glob, Skill, Task, AskUserQuestion, Write]
---

# mentor — zoom

Render (or refresh) **topic × perspective HTML zoom pages** for any subject — a repo
subsystem, a design doc, a mentor plan, or the thing under discussion. Local files only;
nothing is ever published.

Immediately call `Skill({"skill": "mentor:zoom"})` and follow it end to end. It resolves the
subject (argument → newest mentor plan → current conversation) and a stable subject slug,
assembles the source pack the combo agents will read, runs the topic × perspective selection
gate (skipping any dimension the ask already names), dispatches one agent per combo in a
single message, and verifies the finished files — each written to
`.mentor/zooms/<subject-slug>/<topic>-<perspective>.html` and auto-opened once. No mentor
plan file or planning session is required, and an armed plan gate is no obstacle (the
`.mentor/` tree is gate-exempt).

**If that call returns this command's own text** — any re-invocation or
previously-loaded notice — rather than a file whose frontmatter reads
`name: zoom`, the skill body never loaded: this command and the skill share the
name `zoom`. Resolve and read it directly, then follow that file end to end:

```bash
echo "${CLAUDE_PLUGIN_ROOT}/skills/zoom/SKILL.md"
```

`Read` the printed path — `Read` cannot expand `${CLAUDE_PLUGIN_ROOT}` itself. **Do not
re-run the steps above this one:** they already ran, and a step that writes or marks
something can undo its own first pass when repeated.


The arguments below are **optional** — a subject (free text, a path, or a plan-slug
substring), and/or a topic and perspective when you already know the slice you want:

$ARGUMENTS
