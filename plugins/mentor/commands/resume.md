---
description: Browse this repo's saved mentor handoff notes, or drain the fixes parked under a root plan / a split group's remaining siblings, in a fresh session
argument-hint: [note slug, plan topic, root plan slug, split-group name, or list number]
allowed-tools: [Bash, Read, Skill, Task, AskUserQuestion]
---

# mentor — resume

Browse the handoff notes saved for **this repo**, or continue work that was parked instead of
written up as a note, and pick one to continue, in this fresh session.

Immediately call `Skill({"skill": "mentor:resuming"})` and follow it end to end. It lists only the
current repo's live (unresolved) handoff notes (newest first, across every plan-topic folder) —
**plus roots with open descendants and split groups with unbuilt siblings**, so parked fixes and
half-finished splits stay discoverable even with no note pointing at them. Pick one — directly from
the argument below, or interactively — and it either loads the chosen note and resumes the task per
its recommended mentor commands, or drains the chosen root/group **leaf-first** (each nested fix
before the fix it blocks; each split sibling's own fix subtree before the next sibling), re-surveying
and re-approving one item at a time. A note is **stamped resolved** (never re-listed) only once its
work completes per the plan file **and its topic has no open descendants left**, or a nested
`/mentor:handoff` supersedes it — unfinished work, note or parked fix, stays resumable. It is the
consume side of `/mentor:handoff` (which writes the notes) and the continuation side of a fix parked
via `mentor:deferring`'s parent-aware capture.


The argument below is **optional** and pre-selects an entry — a list number (1-based, newest note
first, drain entries after), a plan-topic name (e.g. `console-remove-animation`), a root plan's own
slug, a split-group's name, or a case-insensitive substring against any of those. If it is empty or
matches nothing unambiguously, the skill lists everything and asks:

$ARGUMENTS
