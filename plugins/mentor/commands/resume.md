---
description: Browse this repo's saved mentor handoff notes and continue one in a fresh session
argument-hint: [slug substring or list number of the note to resume]
allowed-tools: [Bash, Read, Skill, Task, AskUserQuestion]
---

# mentor — resume

Browse the handoff notes saved for **this repo** and pick one to continue, in this fresh session.

Immediately call `Skill({"skill": "mentor:resume"})` and follow it end to end. It lists only the
current repo's handoff notes (newest first), lets you pick one — directly from the argument below, or
interactively — then loads the chosen note and resumes the task per its recommended mentor commands.
It is the consume side of `/mentor:handoff` (which writes the notes).

The argument below is **optional** and pre-selects a note — a list number (1-based, newest first) or a
case-insensitive slug substring. If it is empty or matches nothing unambiguously, the skill lists the
notes and asks:

$ARGUMENTS
