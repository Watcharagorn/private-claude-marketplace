---
description: Finish the current branch — simplify, test, then push and open a PR/MR
allowed-tools: [Bash, Read, Grep, Glob, Skill, AskUserQuestion]
---

# mentor — ship

Invoke `Skill({"skill": "mentor:ship"})` and follow it end to end: it
clean-checks the working tree, runs the simplify pass, optionally runs tests,
then asks where to ship (push + PR/MR, or push to upstream).

$ARGUMENTS
