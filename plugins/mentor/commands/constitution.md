---
description: Create or amend this repo's mentor constitution — versioned, governing principles every plan must honor
argument-hint: "[principles to set, or an amendment request]"
allowed-tools: [Bash, Read, Write, Edit, Glob, Grep, Skill, AskUserQuestion]
---

# mentor — constitution

The mentor **constitution** is a versioned set of governing principles for this
repo — declarative, testable rules that every `/mentor:plan` must honor. It lives
**in the repo** at `.mentor/constitution.md` (committed, so it is shared with the
whole team), and the `plan` skill reads it live at plan time: each plan gains a
**Constitution Check** section verifying the design against every principle.

This is a **standalone authoring flow** — it does NOT arm the plan gate. Do these
in order:

1. **Immediately call `Skill({"skill": "mentor:constitution-authoring"})` and follow it end
   to end** — it guards (git repo + no active plan session), loads any existing
   constitution, collects/derives principles, bumps the version semantically,
   writes `.mentor/constitution.md`, and reports commit guidance.


2. Do **not** run `begin-plan.sh` and do **not** invoke `/mentor:plan` — authoring
   the constitution is not a plan session.

The principles to set, or the amendment to make:

$ARGUMENTS
