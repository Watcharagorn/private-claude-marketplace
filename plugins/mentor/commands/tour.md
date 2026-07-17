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

The arguments below are **optional** — an audience (`user` | `dev` | `both`) and/or a subject
(topic or plan-slug substring):

$ARGUMENTS
