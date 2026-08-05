---
description: Preview how a plan will execute as a paged, local HTML storytelling tour — distinct from the published post-approval /mentor:tour acceptance surface
argument-hint: [plan slug] [area] [perspective]
allowed-tools: [Bash, Read, Grep, Glob, Skill, Task, AskUserQuestion, Write]
---

# mentor — plan-tour

Build (or refresh) a **paged HTML plan tour**: a page-by-page storytelling walkthrough of
how a plan will execute from a chosen area × perspective, with one persistent diagram
that evolves across pages, per-page notes, and a copy-to-clipboard Markdown report.
Local file only, never published — unlike the post-approval `/mentor:tour` acceptance
surface, which reviews delivered work instead of previewing it.

Immediately call `Skill({"skill": "mentor:plan-touring"})` and follow it end to end. It
resolves the plan (argument → newest plan under `.mentor/plans/`), asks the area and
perspective once (skipping any dimension already named), dispatches one agent per combo,
and verifies the finished file — written to
`.mentor/plans/<plan-slug>/tour/<area>-<perspective>.html` and auto-opened once.


The arguments below are **optional** — a plan slug (substring), and/or an area and
perspective when you already know the slice you want:

$ARGUMENTS
