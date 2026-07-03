---
name: tidy
description: >
  Run /simplify on the working tree, then commit the result locally — never push.
  Simplifies/refactors current changes, re-checks for a clean tree, stages and commits
  with a sensible conventional-commit message. Invoke when the user says "tidy",
  "tidy up", "simplify and commit", "clean up and commit", or "/tidy".
version: 1.2.0
---

# tidy — Simplify + Commit (no push)

Run `/simplify` over the current changes, then commit them **locally**. This skill
**never pushes** and never touches remotes — committing is the last step.

## When to invoke

- User types `/tidy`
- User says "tidy up", "simplify and commit", "clean up and commit"

## Scope guardrails

- **No push. No remote operations.** Not `git push`, not PR/MR creation, not `git fetch`. Committing locally is the final action.
- Operate only in the current repository / working directory — do not create or enter worktrees.
- Do not amend or rewrite existing commits; create one new commit.

## Procedure

### 1. Snapshot the starting state

```bash
# Current branch and whether there's anything to work on
git rev-parse --abbrev-ref HEAD
git status --porcelain
```

- If the tree is **already clean** (empty `status --porcelain`) and there are no staged changes, tell the user there's nothing to tidy and stop.
- Record the pre-simplify changed files so you can detect what simplify alters:
  ```bash
  pre_files=$(git status --porcelain | awk '{print $2}' | sort -u)
  ```

### 2. Run `/simplify`

Invoke `Skill(skill="simplify")`. Let it refactor the working tree.

### 3. Re-check the tree

Simplify may crash mid-edit or make no change.

```bash
git status --porcelain
```

- If nothing changed at all since step 1 and the tree was already as intended, proceed to commit whatever staged/unstaged work exists.
- If `/simplify` failed or left the tree in a broken state, surface the error and **stop** — do not commit a broken tree.

### 4. Review what will be committed

Show the user a compact diff stat before committing:

```bash
git add -A
git diff --cached --stat
```

Briefly summarize in chat what simplify changed (1–3 lines).

### 5. Commit locally

Pick a conventional-commit message that reflects the work:

- If simplify was the substantive change → `refactor: simplify <area>`
- If tidying an existing in-progress feature → `chore(tidy): simplify before commit`
- Otherwise match the dominant change type (`fix:`, `feat:`, etc.)

```bash
git commit -m "<message>"
```

End the commit message with the standard co-author trailer:

```
Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
```

### 6. Confirm — and stop

Report the commit hash and one-line summary. **Do not push.** If the user wants to
push or open a PR, point them to `/ship` (mentor) — that is out of scope here.

## Rules

- **Never push or run any remote command.** This is the defining constraint of `/tidy`.
- One new commit only — never `--amend`, never rebase.
- If `/simplify` edits files outside the pre-existing change scope, list them and ask
  the user (via `AskUserQuestion`) whether to include them before committing.
- If the tree is clean to begin with, do nothing and say so.
- If `/simplify` leaves the tree broken or in conflict, stop and surface it — do not commit.
