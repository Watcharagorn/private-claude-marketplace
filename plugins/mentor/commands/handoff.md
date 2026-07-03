---
description: Compact the current conversation into a handoff document (saved outside the repo) for a fresh agent to pick up
argument-hint: [what the next session will focus on]
allowed-tools: [Bash, Read, Write, Skill, Task]
---

# mentor — handoff

Compact this conversation into a self-contained handoff document so another agent can continue the
work in a fresh session.

Immediately call `Skill({"skill": "mentor:handoff"})` and follow it end to end. It summarizes the
session and progress, recommends which mentor commands the next agent should run, references existing
artifacts (the plan file, issues, commits, diffs) by path/URL instead of duplicating them, redacts
secrets, and saves the document **outside the repo** (under the per-repo mentor dir) so `git status`
stays clean.

The argument below is **optional** and describes what the next session will focus on — use it to
tailor what the document emphasizes:

$ARGUMENTS
