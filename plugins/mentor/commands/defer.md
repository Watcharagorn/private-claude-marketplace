---
description: Stash one or more items of work discovered mid-flow as deferred plan stubs, then return to what you were doing
argument-hint: [item 1; item 2; ...] — one or many, any separator
allowed-tools: [Bash, Read, Grep, Glob, Skill, Task, AskUserQuestion, Write, Edit]
---

# mentor — defer

Stash work discovered **mid-flow** — during planning or during implementation — as one or more
lightweight plan stubs, without derailing what you are doing right now.

Immediately call `Skill({"skill": "mentor:deferring"})` and follow it end to end. It accepts one item
or many in a single call, judges each item's **priority** (`critical|high|medium|low|noise`) and
**category** (`feature|fix|refactor|docs|tooling` — deliberately no `test`/`verify` entry) from the
conversation's own evidence, plus the **source plan** (`--from`) when one is interrupted, leaving
any of the three unset rather than inventing a default. When a caller supplies that routing
outright — a mentor gate that already carries the user's verdict prepends `from`/`parent`/
`category` in prose ahead of the skill load — the skill takes it as given and judges only what
was left out. It refuses check-shaped items — a deferred
stub captures work to build, never a check to run — then creates a stub `plan.md` (Goal / Context /
Why deferred / Suggested first steps) plus a `.state.json` marked `origin: "deferred"` (with the
judged `priority`/`category`/`deferred_from`) for each, reports every created stub as
`deferred → <slug> [<tier> · <cat>] (.mentor/plans/<slug>/) — from: <plan> — deps: <a>` (tags shown
only when judged), then returns you to the interrupted flow.

The items to defer — one or many, freeform (semicolons, a bullet list, or plain "and" are all
fine):

$ARGUMENTS
