---
description: Stash one or more items of work discovered mid-flow as deferred plan stubs, then return to what you were doing
argument-hint: [item 1; item 2; ...] — one or many, any separator
allowed-tools: [Bash, Read, Grep, Glob, Skill, Task, AskUserQuestion, Write, Edit]
---

# mentor — defer

Stash work discovered **mid-flow** — during planning or during implementation — as one or more
lightweight plan stubs, without derailing what you are doing right now.

Immediately call `Skill({"skill": "mentor:defer"})` and follow it end to end. It accepts one item
or many in a single call, creates a stub `plan.md` (Goal / Context / Why deferred / Suggested first
steps) plus a `.state.json` marked `origin: "deferred"` for each, reports the created stubs one
line each, then returns you to the interrupted flow.

**If that call returns this command's own text** — any re-invocation or previously-loaded notice —
rather than a file whose frontmatter reads `name: defer`, the skill body never loaded: this command
and the skill share the name `defer`. Resolve and read it directly, then follow that file end to
end:

```bash
echo "${CLAUDE_PLUGIN_ROOT}/skills/defer/SKILL.md"
```

`Read` the printed path — `Read` cannot expand `${CLAUDE_PLUGIN_ROOT}` itself. **Do not re-run**
any step already taken — arriving here mid-flow, there is nothing above to re-run anyway.

The items to defer — one or many, freeform (semicolons, a bullet list, or plain "and" are all
fine):

$ARGUMENTS
