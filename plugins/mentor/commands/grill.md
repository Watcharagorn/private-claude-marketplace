---
description: Stress-test and sharpen a plan or design by relentless one-question-at-a-time interview before building
argument-hint: [plan or design to grill — defaults to the current mentor plan / conversation]
allowed-tools: [Bash, Read, Grep, Glob, Skill, Task, AskUserQuestion]
---

# mentor — grill the design

Run a grilling session to pressure-test a plan or design **before any code is written**.

Immediately call `Skill({"skill": "mentor:grilling"})` and follow it end to end. It interviews you
**one question at a time** (each with a recommended answer), walking the decision tree and resolving
open choices until you reach a shared understanding — exploring the codebase via a dispatched
subagent rather than asking what the code can answer.

This is the inverse of `/plan-review`: grill **sharpens the decisions** before a plan is locked;
`/plan-review` **audits the finished plan** at the approve gate. Grilling makes no repo edits.

The subject is **optional**:

- **empty** — grills the **current mentor plan** if one exists, otherwise the design in this conversation.
- a **topic / decision** — grills that design area directly.

$ARGUMENTS
