---
description: Finish the current branch — simplify, test, then push and open a PR/MR
allowed-tools: [Bash, Read, Grep, Glob, Skill, AskUserQuestion]
---

# mentor — ship

Invoke `Skill({"skill": "mentor:shipping"})` and follow it end to end: it
clean-checks the working tree, runs the simplify pass, runs tests, then pushes and
opens a PR/MR. Invoked by hand it asks about tests and the target; inside a mentor
plan run it follows the plan's Definition of done and puts the Done review in the PR
body.


$ARGUMENTS
