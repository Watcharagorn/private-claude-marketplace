---
description: Stress-test and sharpen a plan or design by relentless one-question-at-a-time interview before building
argument-hint: [plan or design to grill — defaults to the current mentor plan / conversation]
allowed-tools: [Bash, Read, Grep, Glob, Skill, Task, AskUserQuestion, Edit]
---

# mentor — grill the design

Run a grilling session to pressure-test a plan or design **before any code is written**.

Immediately call `Skill({"skill": "mentor:grilling"})` and follow it end to end. It interviews you
**one question at a time** (each with a recommended answer), walking the decision tree and resolving
open choices until you reach a shared understanding — exploring the codebase directly rather than
asking what the code can answer.

Grill is also the plan-quality pass on a drafted plan: run it at the approve gate to judge whether
the written plan is any good. Grilling makes no repo edits, beyond a settled trivial one-file change
(the skill's Step 3 trivial-implement branch).

The subject is **optional**:

- **empty** — grills the **current mentor plan** if one exists, otherwise the design in this conversation.
- a **topic / decision** — grills that design area directly.

$ARGUMENTS
