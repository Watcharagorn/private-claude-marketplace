---
name: ship
description: Finish the current branch — clean-check, run /simplify, optionally run tests, then ship to a user-chosen target (push + auto-open PR/MR, or push to the branch's upstream). Never force-pushes; never pushes to a protected source branch without an explicit choice. Invoked by /mentor:ship, "ship this", "merge and push", "finish and ship".
---

# ship — Ship the current branch

Drives clean-check → `/simplify` → optional tests → **user-chosen ship target**
for the branch currently checked out. No worktree machinery — the flow operates
on `$PWD`'s repo and branch.

## Step 1 — Context & summary

```bash
repo_root="$(git rev-parse --show-toplevel)"
branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)"
[ "$branch" = "HEAD" ] && { echo "ERROR: detached HEAD — check out a branch first." >&2; exit 1; }

# Base = the branch's upstream if set, else origin's default branch.
base="$(git -C "$repo_root" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null | sed 's#^origin/##')"
if [ -z "$base" ] || [ "$base" = "$branch" ]; then
  base="$(git -C "$repo_root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
fi
```

Render to the user: the branch, the base, and
`git -C "$repo_root" diff "origin/${base}"...HEAD --stat` (fall back to the
local `$base` if the remote ref is absent).

## Step 2 — Pre-flight clean check

```bash
[ -n "$(git -C "$repo_root" status --porcelain)" ] && {
  echo "Working tree has uncommitted changes. Commit or stash them, then re-invoke /mentor:ship." >&2
  exit 1
}
```

## Step 3 — Run `/simplify`

Invoke `Skill(skill="simplify")` (a Claude Code built-in; if unavailable, do a
quick review of the branch diff yourself instead). After it returns:

1. **Re-run the clean check** — simplify may have edited files.
2. If `git status --porcelain` is non-empty:
   - Feature scope: `feature_files=$(git diff --name-only "origin/${base}"...HEAD | sort -u)`
   - Dirty + untracked: `simplify_files=$(git diff --name-only HEAD; git ls-files --others --exclude-standard) | sort -u`
   - If every dirty file is in the feature scope: **auto-commit without
     prompting** — `chore(simplify): refactor before ship` — and surface
     `git diff HEAD~1 --stat` in the ship summary.
   - If any file is OUTSIDE the scope: show the list and ask via
     `AskUserQuestion`: include in-scope only (Recommended) / include all / abort.

## Step 4 — Conditional test step

Ask via `AskUserQuestion`: "Run the test suite before shipping?" —
Yes (Recommended) / No.

**Auto-detect the command from the repo root:**

| Match | Command |
|---|---|
| `package.json` with `scripts.test` | `npm test` |
| `pyproject.toml` declaring pytest OR `pytest.ini` | `pytest` |
| `go.mod` | `go test ./...` |
| `Makefile` with a `test:` target | `make test` |

Pick the first match and tell the user which command will run. If none match,
ask the user for a command (explicit empty input = skip).

On failure, ask: "Tests failed. What now?" — Stop and fix (default, exit 1) /
Ship anyway.

## Step 5 — Choose the ship target (mandatory)

Never decide this yourself. Substitute real values before emitting the call:

```json
{
  "question": "Where should '<branch>' go? It adds <ahead> commit(s) on top of <base>.",
  "header": "Ship target",
  "options": [
    { "label": "Push + open PR/MR (Recommended)",
      "description": "Push '<branch>' to origin/<branch> and automatically open a PR/MR into <base>. The remote <base> is never touched." },
    { "label": "Push to upstream",
      "description": "Push '<branch>' to its upstream (origin/<branch>) with no PR/MR. Use when the branch IS the integration branch." }
  ]
}
```

(`ahead` = `git rev-list --count "origin/${base}..${branch}"`, falling back to
the local base ref.)

### 5A — Push + open PR/MR

Detect the host from `git remote get-url origin`:

- **GitLab** (URL contains `gitlab` or your self-hosted GitLab host) — fold MR
  creation into the push (idempotent — an existing open MR is reused):
  ```bash
  git -C "$repo_root" push -u origin "$branch" \
    -o merge_request.create \
    -o merge_request.target="$base" \
    -o merge_request.remove_source_branch \
    -o merge_request.title="$branch" 2>&1 | tee /tmp/ship-push.out
  ```
  Surface the MR URL (grep for `/-/merge_requests/`). If a `WARNINGS:` block
  names `merge_request.target`, the target is invalid — the MR did NOT open;
  re-resolve the base (ask the user) and retry. An already-open-MR warning is
  fine — print its URL.

- **GitHub** — push, then open the PR with `gh` (run inside the repo):
  ```bash
  git -C "$repo_root" push -u origin "$branch"
  (cd "$repo_root" && gh pr create --base "$base" --head "$branch" --fill)
  ```
  If `gh` is absent, print the compare URL instead.

- **Other host** — push, then print the compare URL for manual PR creation.

### 5B — Push to upstream

```bash
git -C "$repo_root" push -u origin "$branch"
```

**Either target:** if the push is rejected (remote moved), surface the error and
ask whether to `git pull --rebase origin "$branch"` and retry, or stop.
**Never force-push.**

## Failure modes

| Situation | What to do |
|---|---|
| Detached HEAD | Abort — check out a branch first. |
| Dirty tree at Step 2 | Abort — user commits or stashes, then re-invokes. |
| Simplify edited out-of-scope files | Ask before committing. |
| Tests fail | Default: stop; branch intact for iteration. |
| Push rejected | Offer `pull --rebase` + retry, or stop. Never force-push. |
| MR/PR creation fails | The branch is already pushed and safe — print the compare URL. |
