---
description: Review a plan or any subject as one scenario-based HTML page — mockups of every surface, edge cases, C4 and sequence diagrams, the changed data and contracts, and open questions asked in chat
argument-hint: [subject or plan slug]
allowed-tools: [Bash, Read, Grep, Glob, Skill, Task, AskUserQuestion, Write, Edit, Artifact]
---

# mentor — preview

Build (or refresh) **one review page** for a plan or any other subject: one scrolling page with a
contents sidebar, a mockup of every surface each scenario reaches, each edge case as its own card,
each sequence under the scenario that starts it, the C4 levels that move, the changed data and
contracts, and the decisions — only the sections the subject changes. Every card has a comment box with Copy, and open questions come back to chat one at a
time.

Immediately call `Skill({"skill": "mentor:previewing"})` and follow it end to end. It resolves the
subject (argument → newest mentor plan → current conversation) and a stable subject slug, plans
the sections, inventories every surface, settles diagram-design once, has workers write the page's
fragments, assembles and checks `.mentor/reviews/<subject-slug>/review.html`, opens it, offers once
per build to publish it, and then asks the open questions; a run that finds the page current rebuilds
nothing and does neither. No planning session is required, and an armed plan
gate is no obstacle (the `.mentor/` tree is gate-exempt).

The argument below is **optional** — a subject (free text, a path, or a plan-slug substring):

$ARGUMENTS
