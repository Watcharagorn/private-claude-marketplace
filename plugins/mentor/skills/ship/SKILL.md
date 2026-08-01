---
name: ship
description: Finish the current branch — clean-check, run /simplify, optionally run tests, then ship to a user-chosen target (push + auto-open PR/MR, or push to the branch's upstream), then retire the plan topic's live handoff notes (stamped resolved — the work is done). Never force-pushes; never pushes to a protected source branch without an explicit choice. Invoked by /mentor:ship, "ship this", "merge and push", "finish and ship".
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

**Branch-ownership check** (GitHub + `gh` only — skip silently when `gh` is
absent, the remote isn't GitHub, or the call fails; never block on it):

```bash
# Re-derive: Step 1's block was a separate Bash call and its variables are gone. An empty
# $branch would make `gh pr list --head ""` match EVERY open PR in the repo — a false alarm
# that stops a legitimate ship while never checking this branch at all.
repo_root="$(git rev-parse --show-toplevel)"
branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)"
command -v gh >/dev/null && git remote get-url origin 2>/dev/null | grep -qi github && \
  (cd "$repo_root" && gh pr list --head "$branch" --state open \
     --json number,title,url 2>/dev/null) || true
```

If an open PR already exists for this branch, show it and ask via
`AskUserQuestion` whether that PR is **this session's work** (pushing more
commits onto your own PR is normal — continue) or **unrelated** (stop: shipping
would inject these commits into someone else's PR; recommend cutting a fresh
branch from `$base` and cherry-picking). Catching this here is cheap; catching
it after the push means a cherry-pick/branch-reset recovery.

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

**Per-repo override first** — auto-detect guesses wrong in monorepos (a root
`npm test` can proxy to an unrelated workspace), so an explicit setting always
wins:

```bash
jq -r '.test_command // empty' "$repo_root/.mentor/config.json" 2>/dev/null
```

Non-empty → use it verbatim and say so. Otherwise **auto-detect from the repo
root:**

| Match | Command |
|---|---|
| `package.json` with `scripts.test` | `npm test` |
| `pyproject.toml` declaring pytest OR `pytest.ini` | `pytest` |
| `go.mod` | `go test ./...` |
| `Makefile` with a `test:` target | `make test` |

Pick the first match and tell the user which command will run, adding the hint
`(override with "test_command" in .mentor/config.json)` so the key is
discoverable where the misfire happens. If none match, ask the user for a
command (explicit empty input = skip).

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
  fine **when the MR is this branch's own work** — print its URL. (An MR opened
  by someone else is the Step 1 ownership case; if Step 1 was skipped — no `gh`
  on a GitLab remote — check the MR author/title before shrugging it off.)

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

## Step 6 — Retire the topic's handoff notes (post-ship)

A successful ship means the plan's tasks are done — any handoff note still live
for this work is solved, and leaving it listed invites a later `/mentor:resume`
to re-open finished work. Resolve `<topic>` from what **this session actually
worked on**: the plan file it followed (`.mentor/plans/<topic>/plan.md`) or the
handoff note it resumed from (the note's grandparent dir — the `<topic>` above
its `handoffs/` — names it; this also covers focus-slug topics that never got a
`plan.md`). If the session touched notes in more than one topic dir, run the
snippet once per topic. **If you cannot name the topic from this session's own
work, skip this step entirely — never guess** (e.g. from the newest `plan.md`
on disk: it may belong to a different, unfinished workstream, and stamping its
notes would bury live work). Resume Step 7 and the next `/mentor:handoff` still
stamp on their own triggers.

```bash
# Re-derive here (shell vars don't survive between Bash calls) via the shared
# subcommand handoff/resume use: from a linked worktree it resolves to the MAIN
# repo's .mentor, where the notes actually live (show-toplevel would miss them).
hand_dir="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" dir --plans)/<topic>/handoffs"   # ← REPLACE <topic> per the rule above
find "$hand_dir" -maxdepth 1 -type f -name '*.md' 2>/dev/null | while IFS= read -r n; do
  case "$(basename "$n")" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-*.md)  # conforming notes only
      mkdir -p -m 700 "$hand_dir/resolved"
      mv "$n" "$hand_dir/resolved/$(basename "$n")"
      echo "work shipped → resolved: $(basename "$n")" ;;
  esac
done
```

Run this only after the push actually succeeded. Skip silently when there are no
live notes (`find` yields nothing) — this step never blocks the ship report. A
stamp is reversible by moving the file back up one directory.

**Also close the plan's state** — same trigger, same `<topic>` resolution, same
never-guess rule: a shipped plan left `in_progress` is re-offered for building by
the next session's `/mentor:track`:

```bash
plans_dir="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" dir --plans)"
[ -d "$plans_dir/<topic>" ] && \
  bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" set <topic> implemented
```

Guard on the directory rather than letting it fail: `set` exits 1 with "No such
plan" when the plans dir exists but the slug doesn't — exactly the focus-slug
handoff case that never got a `plan.md`. Don't invent a slug to satisfy it.
Two edges worth knowing: `set` with no `--note` replaces any existing note with
an empty one (so a prior `failed` reason is lost), and it has no downgrade guard —
if `<topic>` resolves to a split parent, `implemented` overwrites `superseded`.

## Step 7 — Point at the merge tail

One line in the ship report: `Watch CI and merge with /mentor:merge` (GitHub +
`gh` only — omit the line otherwise). Ship's job ends at the open PR; watching
checks and merging is `/mentor:merge`'s, so it stays re-enterable after a
stalled CI run without re-running ship.

## Failure modes

| Situation | What to do |
|---|---|
| Detached HEAD | Abort — check out a branch first. |
| Dirty tree at Step 2 | Abort — user commits or stashes, then re-invokes. |
| Simplify edited out-of-scope files | Ask before committing. |
| Tests fail | Default: stop; branch intact for iteration. |
| Push rejected | Offer `pull --rebase` + retry, or stop. Never force-push. |
| `gh pr create` fails: PR already exists for this branch | Do NOT open a duplicate — print the existing PR's URL (`gh pr list --head "$branch"`) and confirm with the user it now contains what they meant to ship (Step 1's ownership answer applies). |
| MR/PR creation fails (other) | The branch is already pushed and safe — print the compare URL. |
