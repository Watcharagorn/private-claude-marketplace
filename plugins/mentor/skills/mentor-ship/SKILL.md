---
name: mentor-ship
description: Worktree-aware /ship flow for mentor. Auto-injected by ship-entry.sh when the user types /ship inside a mentor-managed worktree. Runs /simplify, catches the source branch up into the worktree (all conflict resolution happens in the worktree), optionally runs tests, then asks the user to choose a ship target — remote:worktree (push the feature branch to its own remote + automatically open a PR/MR; default) or local:source (fast-forward into the LOCAL source branch, with a separate explicit confirmation before any push to the remote source). Never pushes worktree commits into the remote source branch without explicit confirmation. Always asks before cleaning up the worktree. Triggered by "/ship", "ship this", "merge and push", "finish and ship".
---

# mentor-ship — Worktree-aware /ship Flow

Drives `/simplify` → catch-up-source → optional tests → **user-chosen ship target** → cleanup for a worktree created by `mentor-plan`. The worktree is the integration buffer: all conflict resolution and source-catch-up happen there.

**Core safety rule (v0.14.0):** the flow **never merges worktree commits into the remote source branch directly**. At ship time the user always chooses the target:

- **`remote:worktree` (default)** — push the feature branch to its own remote branch (`origin/<feature>`) and automatically open a PR/MR into the source branch. The remote source branch is never touched.
- **`local:source`** — fast-forward the feature branch into the **local** source branch only. Pushing that local source to `origin` requires a **separate explicit confirmation** — it never happens automatically.

After the target step completes, the flow **always asks** before tearing down the worktree.

## When to use

- The UserPromptSubmit hook auto-injects this skill when the user types `/ship` inside a mentor-managed worktree.
- The user explicitly invokes `/mentor-ship`, "ship this", "merge and push", or "finish and ship" inside such a worktree.

If `$PWD` is not inside a mentor-managed worktree (no state file at `git rev-parse --git-path worktrees/<name>/mentor.json`), this skill is **not** the right one — fall through to the global `/ship`.

## Environment variable

`${CLAUDE_PLUGIN_ROOT}` — the plugin root exposed by the Claude Code harness. The harness always
sets it when the plugin loads, so there is no hardcoded fallback path (never hardcode an install
location — the real install dir is version-scoped under `~/.claude/plugins/cache/`).

---

## Step-by-step execution

### Step 1 — Detect worktree context

```bash
wt_name="$(basename "$PWD")"
state_dir="$(git -C "$PWD" rev-parse --git-path "worktrees/${wt_name}" 2>/dev/null)"
state_file="${state_dir}/mentor.json"

if [ ! -f "$state_file" ]; then
  echo "ERROR: Not inside a mentor worktree (no $state_file)." >&2
  exit 1
fi

source_branch="$(jq -r '.source_branch' "$state_file")"
feature_branch="$(jq -r '.feature_branch' "$state_file")"
worktree_path="$PWD"
```

### Step 2 — Identify the main repo path

```bash
git_common_dir="$(git -C "$PWD" rev-parse --git-common-dir)"
# Make absolute if relative
if [[ "$git_common_dir" != /* ]]; then
  git_common_dir="$(cd "$PWD" && cd "$git_common_dir" && pwd)"
fi
main_repo="$(dirname "$git_common_dir")"
```

### Step 3 — Sanity-check the state file

```bash
actual_branch="$(git -C "$worktree_path" rev-parse --abbrev-ref HEAD)"
if [ "$actual_branch" != "$feature_branch" ]; then
  echo "ERROR: Worktree HEAD is on '${actual_branch}' but state file says '${feature_branch}'." >&2
  echo "Update ${state_file} or re-allocate the worktree." >&2
  exit 1
fi
```

Do NOT silently proceed on mismatch — the user may have renamed the branch or checked something else out inside the worktree.

### Step 4 — Show summary

Render to the user:

```
Branch:    <feature_branch>
Source:    <source_branch>
Path:      <worktree_path>
Changed files (vs <source_branch>):
<output of: git -C <worktree_path> diff <source_branch>...HEAD --stat>
```

### Step 5 — Pre-flight clean check

```bash
if [ -n "$(git -C "$worktree_path" status --porcelain)" ]; then
  echo "Worktree has uncommitted changes. Commit or stash them, then re-invoke /ship." >&2
  exit 1
fi
```

### Step 6 — Run `/simplify` on the worktree

Invoke `Skill(skill="simplify")`. After it returns:

1. **Re-run the clean check.** Simplify may have crashed mid-edit.
2. If `git -C <worktree_path> status --porcelain` is non-empty:
   - Compute the feature's existing change scope: `feature_files=$(git -C <worktree_path> diff --name-only <source_branch>...HEAD | sort -u)`
   - Compute the new dirty files: `simplify_files=$(git -C <worktree_path> diff --name-only HEAD | sort -u)` and untracked: `simplify_untracked=$(git -C <worktree_path> ls-files --others --exclude-standard | sort -u)`
   - If every `simplify_files` ∪ `simplify_untracked` entry is in `feature_files`: **auto-commit without prompting** with message `chore(simplify): refactor before ship`. Surface `git -C <worktree_path> diff HEAD~1 --stat` in the ship summary so the user sees what changed.
   - If any file is OUTSIDE the feature scope: show the list and ask via `AskUserQuestion`:
     - "Include out-of-scope files in the simplify commit?" — (a) include all, (b) include in-scope only, (c) abort ship. Default = (b).
   - Stage and commit accordingly.

### Step 7 — Catch up the worktree to the source branch

All integration happens in the worktree — the source branch must never receive surprise conflicts.

```bash
# Fetch source if a remote exists — captures remote movement too.
has_remote=0
if git -C "$main_repo" ls-remote --exit-code origin "$source_branch" >/dev/null 2>&1; then
  git -C "$main_repo" fetch origin "$source_branch"
  source_ref="origin/${source_branch}"
  has_remote=1
else
  source_ref="$source_branch"
fi

source_ahead=$(git -C "$main_repo" rev-list --count "${feature_branch}..${source_ref}")
```

- `source_ahead == 0` → source has not moved; nothing to catch up. Continue.
- `source_ahead > 0` → merge `$source_ref` into the worktree:
  ```bash
  if ! git -C "$worktree_path" merge --no-ff "$source_ref" \
       -m "Merge ${source_ref} into ${feature_branch} before ship"; then
    echo "" >&2
    echo "Merge conflict in the worktree. Resolve conflicts in:" >&2
    git -C "$worktree_path" diff --name-only --diff-filter=U >&2
    echo "" >&2
    echo "Resolve in $worktree_path, commit the resolution, then re-invoke /ship." >&2
    exit 1
  fi
  ```
  Do NOT auto-abort. The conflict markers should remain in the worktree for the user to resolve.

If `has_remote=1`, also fast-forward the local source branch in the main repo. The target isn't chosen until Step 10, so do this unconditionally: if the user later picks `local:source` (Step 11B) the FF-merge target is already current; if they pick `remote:worktree` (Step 11A) this is harmless (the local source is simply up to date and never touched).
```bash
if git -C "$main_repo" merge-base --is-ancestor "$source_branch" "origin/${source_branch}"; then
  git -C "$main_repo" branch -f "$source_branch" "origin/${source_branch}"
fi
```
If the local source is NOT a strict ancestor of the remote, warn but continue — the user has local-only commits on source; let the race-recheck in Step 11B catch any real divergence.

### Step 8 — Check what the worktree adds on top of source

```bash
ahead=$(git -C "$main_repo" rev-list --count "${source_branch}..${feature_branch}")
```

- `ahead == 0` → nothing to ship. Show "No net change after simplify and catch-up." Skip the target step and go straight to **Step 12 — Cleanup** (which itself asks before removing anything).
- `ahead > 0` → continue.

### Step 9 — Conditional test step

Ask via `AskUserQuestion`:

> "Run test suite before merging into <source_branch>?"
>
> - Yes — run the test suite (recommended).
> - No — skip tests.

Default = Yes.

**Auto-detect command from `$worktree_path`:**

| Match | Command |
|---|---|
| `package.json` with `scripts.test` | `npm test` |
| `pyproject.toml` declaring pytest OR `pytest.ini` | `pytest` |
| `go.mod` | `go test ./...` |
| `Makefile` with a `test:` target | `make test` |

Pick the first match in this order and tell the user which command will run.

If **none** match, ask the user to provide a command:

> "No test command auto-detected. Provide one to run, or leave empty to skip."

Do NOT offer "skip" as a first-class option — explicit empty input is the only bypass.

Run the command from inside `$worktree_path`. On failure, ask via `AskUserQuestion`:

> "Tests failed. What now?"
>
> - Stop and let me fix in the worktree (recommended).
> - Merge and push anyway.

Default = stop. On stop → exit 1; worktree is intact for the user to iterate.

### Step 10 — Choose the ship target (mandatory)

Never decide this yourself. Call `AskUserQuestion` with **exactly** this shape (the recommended option is listed **first** so it is the default):

```json
{
  "question": "Where should this worktree's work go? It adds <ahead> commit(s) on top of <source_branch>.",
  "header": "Ship target",
  "options": [
    {
      "label": "remote:worktree (Recommended)",
      "description": "Push feature branch '<feature_branch>' to its own remote (origin/<feature_branch>) and automatically open a PR/MR into <source_branch>. The remote <source_branch> is never touched."
    },
    {
      "label": "local:source",
      "description": "Fast-forward '<feature_branch>' into the LOCAL <source_branch> only. Pushing to origin/<source_branch> needs a separate explicit confirmation."
    }
  ]
}
```

Substitute the real `<ahead>`, `<feature_branch>`, and `<source_branch>` values into every string **before** emitting the tool call — `AskUserQuestion` shows the literal text, so unresolved placeholders leak to the user. Example: with `ahead=3`, `feature_branch="feature/auth-retry"`, `source_branch="main"`, the question becomes `"Where should this worktree's work go? It adds 3 commit(s) on top of main."` and the first option's description becomes `"Push feature branch 'feature/auth-retry' to its own remote (origin/feature/auth-retry) and automatically open a PR/MR into main. …"`.

Then branch on the answer: **remote:worktree → Step 11A**, **local:source → Step 11B**.

---

### Step 11A — Target `remote:worktree` (push feature branch to its own remote + auto-open MR/PR)

This never touches `origin/<source_branch>`. The MR/PR is created **automatically** as part of shipping — there is no separate "open it?" prompt.

1. **Detect the remote host:**
   ```bash
   remote_url="$(git -C "$worktree_path" remote get-url origin 2>/dev/null)"
   ```
   GitLab if `remote_url` points at a GitLab host (contains `gitlab` or your self-hosted GitLab host, e.g. `git.ntbx.tech`); GitHub if it contains `github.com` (or your GitHub host); otherwise "other".

2. **Resolve a valid MR/PR target.** `$source_branch` is the fork point recorded in `mentor.json`; if it has since merged and been deleted on origin, it is **not** a valid MR/PR target — GitLab rejects `merge_request.target=<gone>` with a `WARNINGS:` block and `gh pr create --base <gone>` fails outright. Reuse Step 7's `has_remote` (1 ⇒ `$source_branch` still exists on origin):

   ```bash
   mr_target="$source_branch"
   if [ "$has_remote" != "1" ]; then
     # Source fork-point is gone from origin (already merged + deleted). The right
     # integration target is genuinely ambiguous — do NOT silently retarget. Recommend
     # origin's default branch, but make the user confirm. Resolve the default
     # locale-safely (never parse `git remote show origin` prose):
     default_branch="$(git -C "$worktree_path" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
     [ -z "$default_branch" ] && default_branch="$(git -C "$worktree_path" ls-remote --symref origin HEAD 2>/dev/null | sed -n 's#^ref: refs/heads/\([^\t ]*\).*HEAD#\1#p')"
     remote_branches="$(git -C "$worktree_path" ls-remote --heads origin 2>/dev/null | sed 's#.*refs/heads/##')"
   fi
   ```

   If `has_remote != 1`, call `AskUserQuestion`: *"Source branch '`<source_branch>`' no longer exists on origin. Which branch should the MR/PR target?"* — options = the `remote_branches` list, with `<default_branch>` listed **first** as the recommended option. Set `mr_target` to the answer. (This is exactly the manual recovery the model had to perform mid-session: probe origin → ask → e.g. `staging`, *not* `master`.) Selecting a target only chooses where the MR opens; it never touches `origin/<source>`, so the core ship-safety rule is unaffected.

3. **Push the feature branch and auto-create the MR/PR:**

   - **GitLab** — fold MR creation into the push with push options (no `glab`; idempotent — an existing open MR is reused, the push still succeeds with a harmless `WARNINGS:` line):
     ```bash
     git -C "$worktree_path" push -u origin "$feature_branch" \
       -o merge_request.create \
       -o merge_request.target="$mr_target" \
       -o merge_request.remove_source_branch \
       -o merge_request.title="$feature_branch" 2>&1 | tee /tmp/ep-ship-push.out
     ```
     Then surface the MR URL: grep `/tmp/ep-ship-push.out` for `merge request` / `/-/merge_requests/` and print the URL. If a `WARNINGS:` block appears instead, read which option it names — do **not** assume "MR already open":
       - names **`merge_request.target`** → the target is invalid (e.g. it was deleted between resolve and push). The MR did **not** open. Surface the warning, re-resolve the target (re-run the Step 2 resolver / ask the user), and retry the push. Do not report success.
       - is about an **already-open MR** → the existing MR was updated; tell the user and print its URL if shown.

   - **GitHub** — push, then open the PR with `gh` (no prompt). `gh` resolves repo/remote from the directory, so run it inside `$worktree_path`:
     ```bash
     git -C "$worktree_path" push -u origin "$feature_branch"
     (cd "$worktree_path" && gh pr create --base "$mr_target" --head "$feature_branch" --fill)
     ```
     If `gh` is not installed, fall back to printing the compare URL derived from `remote_url`.

   - **other host** — push (`git -C "$worktree_path" push -u origin "$feature_branch"`), then print the compare URL for manual MR/PR creation.

   If the **push itself** is rejected (someone else pushed the same branch), surface the error and ask whether to `git -C "$worktree_path" pull --rebase origin "$feature_branch"` and retry, or stop. Do **NOT** force-push.

3. Proceed to **Step 12 — Cleanup**.

---

### Step 11B — Target `local:source` (fast-forward into LOCAL source only)

1. **Protected-branch confirmation.** If `$source_branch` matches `^(main|master|production|release/.*)$`, call `AskUserQuestion`:

   > "About to fast-forward protected branch '<source_branch>' locally. Continue?"
   >
   > - No, stop (default).
   > - Yes, continue.

   On stop → exit 1; worktree intact.

2. **Fast-forward merge into the LOCAL source branch:**
   ```bash
   git -C "$main_repo" checkout "$source_branch"

   # Re-fetch first: Step 7's fetch happened before the Step 10 prompt, so the
   # remote source may have moved while the user was answering. Refresh + FF the
   # local source so the race-guard below compares against the latest remote.
   if git -C "$main_repo" ls-remote --exit-code origin "$source_branch" >/dev/null 2>&1; then
     git -C "$main_repo" fetch origin "$source_branch"
     if git -C "$main_repo" merge-base --is-ancestor "$source_branch" "origin/${source_branch}"; then
       git -C "$main_repo" merge --ff-only "origin/${source_branch}"
     fi
   fi

   # Race-guard: source moved with commits the worktree never caught up on.
   recheck=$(git -C "$main_repo" rev-list --count "${feature_branch}..${source_branch}")
   if [ "$recheck" != "0" ]; then
     echo "ERROR: ${source_branch} moved during ship. Re-invoke /ship to re-catch-up." >&2
     exit 1
   fi

   git -C "$main_repo" merge --ff-only "$feature_branch"
   ```
   Fast-forward only. No `--no-ff` fallback — any non-FF condition means the catch-up in step 7 was bypassed, and silently falling back would re-introduce surprise conflicts on the source branch.

3. **Separate, explicit push confirmation.** The local source branch is now updated. Pushing it to the remote source is a distinct decision — never bundle it into the merge. Call `AskUserQuestion`:

   > "`<source_branch>` is updated locally. Push it to origin/<source_branch> now?"
   >
   > - No — keep it local; I'll push myself (default).
   > - Yes — push to origin/<source_branch>.

   Default = **No**. Only on an explicit **Yes**:
   ```bash
   if ! git -C "$main_repo" push origin "$source_branch"; then
     echo "Push failed (likely non-fast-forward on remote). Pull ${source_branch}, re-invoke /ship." >&2
     exit 1
   fi
   ```
   Do NOT force-push. On **No**, tell the user the source branch is merged locally and how to push when ready.

4. Proceed to **Step 12 — Cleanup**.

---

### Step 12 — Cleanup (always ask)

Whatever the target, **always ask** before removing the worktree — never tear it down silently. Call `AskUserQuestion`:

> "All planned work is shipped. Clean up the worktree `<worktree_path>` now?"
>
> - Yes — remove the worktree (recommended).
> - No — keep it for follow-up work.

On **No** → stop here; the worktree, branch, and state file stay intact. Tell the user how to re-invoke `/ship` later.

On **Yes**, do these in order. **12a is a tool call, not a shell command** — do not put `ExitWorktree` inside a Bash block; invoke it as the `ExitWorktree` tool. Only after it returns, run the 12b Bash block.

**12a — Exit the worktree, returning to the main checkout (tool call):**

Use `action="keep"`, **not** `action="remove"`. `mentor-plan` creates the worktree with a Bash
`git worktree add` and only *enters* it via `EnterWorktree`, so the harness refuses to remove it
(*"entered an existing worktree … not created by EnterWorktree, so this tool will not remove it"*).
`action="keep"` returns the session to the main checkout, from which 12b removes the worktree.
```
ExitWorktree(action="keep")
```

**12b — Remove the worktree, prune refs, and conditionally delete the local feature branch (Bash):**
```bash
# 1. Remove the worktree dir from the main checkout (we are back in it after 12a's keep).
#    A clean tree is guaranteed by Step 5's pre-flight, and gitignored seeds (.env) do not block a
#    plain remove. Escalate to --force only if a late-dirtied/untracked artifact appeared — warn
#    first (the user already chose to remove the worktree); never discard silently.
git -C "$main_repo" worktree remove "$worktree_path" 2>/dev/null \
  || { echo "WARNING: worktree $worktree_path had uncommitted/untracked changes — force-removing." >&2; \
       git -C "$main_repo" worktree remove --force "$worktree_path"; }

# 2. Prune dangling refs (also clears the git-path state dir)
git -C "$main_repo" worktree prune

# 3. Decide whether the local feature branch is safe to delete.
#    Safe if EITHER:
#      (a) it is fully merged into the local source branch (local:source target), OR
#      (b) it is fully pushed to its own remote (remote:worktree target).
#    This is deliberately state-based, not a flag from Step 11: if the push in
#    11A was skipped or rejected, origin/<feature> is absent or behind, so
#    pushed_to_remote stays "no" and the branch is correctly KEPT.
merged_into_source=$(git -C "$main_repo" rev-list --count "${source_branch}..${feature_branch}")
pushed_to_remote="no"
if git -C "$main_repo" rev-parse --verify --quiet "refs/remotes/origin/${feature_branch}" >/dev/null \
   && [ "$(git -C "$main_repo" rev-list --count "origin/${feature_branch}..${feature_branch}")" = "0" ]; then
  pushed_to_remote="yes"
fi

if [ "$merged_into_source" = "0" ] || [ "$pushed_to_remote" = "yes" ]; then
  git -C "$main_repo" branch -d "$feature_branch" 2>/dev/null \
    || git -C "$main_repo" branch -D "$feature_branch"
else
  echo "WARNING: feature branch ${feature_branch} is neither merged into ${source_branch} nor pushed to origin — keeping branch (delete manually when ready)." >&2
fi
```

For the `remote:worktree` target the deletion only removes the **local** copy of the feature branch — `origin/<feature_branch>` (and its open PR/MR) stay intact.

---

## Failure modes

| Situation | What to do |
|---|---|
| **No state file** | Not a mentor worktree. Tell the user, fall through to global `/ship`. |
| **State file says feature branch X, HEAD is Y** | Abort. User renamed/swapped the branch — must update state file or re-allocate. |
| **Dirty working tree at step 5** | Abort. User commits or stashes, then re-invokes. |
| **Simplify edited out-of-scope files** | Ask user before committing — out-of-scope edits are a yellow flag. |
| **Conflict merging source into worktree (step 7)** | Leave merge in progress with conflict markers. Tell user to resolve in worktree and re-invoke. Do NOT `--abort`. |
| **No net change after simplify + catch-up (step 8)** | Skip the target step, go to Step 12 cleanup (which asks before removing). Do NOT silently delete. |
| **Tests fail (step 9)** | Default: stop. Worktree intact for iteration. Source branch is untouched (target step hasn't run yet). |
| **Feature-branch push rejected (step 11A)** | Offer `pull --rebase` + retry, or stop. Do NOT force-push. |
| **MR/PR creation fails (step 11A)** | GitLab: a push-option `WARNINGS:` block is non-fatal — the MR already exists and was updated; print its URL. GitHub: if `gh` is absent or fails, the branch is already pushed and safe — fall back to printing the compare URL. |
| **Source moved between step 7 and step 11B** | Abort with "source moved during ship; re-invoke". Main repo restored via `git checkout` to source's current HEAD; no merge attempted. |
| **Source push rejected (step 11B, after explicit Yes)** | Tell user to pull and re-invoke. Do NOT force-push. |
| **Feature branch neither merged nor pushed at cleanup** | Skip the branch deletion, warn the user. |
| **User declines cleanup (step 12)** | Leave worktree, branch, and state file intact; tell user how to re-invoke `/ship`. |

---

## Quick reference — commands used

| Step | Command |
|---|---|
| Detect state | `git -C $PWD rev-parse --git-path "worktrees/$(basename $PWD)"` |
| Main repo | `git rev-parse --git-common-dir` → dirname |
| HEAD branch | `git -C <worktree> rev-parse --abbrev-ref HEAD` |
| Diff stat | `git -C <worktree> diff <source>...HEAD --stat` |
| Clean check | `git -C <worktree> status --porcelain` |
| Catch up | `git -C <worktree> merge --no-ff origin/<source>` |
| Ahead count | `git -C <main_repo> rev-list --count <source>..<feature>` |
| Resolve MR/PR target | `mr_target=<source>` if `has_remote=1`, else ask the user (recommend `git symbolic-ref --short refs/remotes/origin/HEAD`) — see Step 11A.2 |
| Push feature (remote:worktree) | `git -C <worktree> push -u origin <feature> -o merge_request.create -o merge_request.target=<mr_target> -o merge_request.remove_source_branch` (GitLab) |
| Open MR (GitLab) | automatic via the push options above (no glab needed) |
| Open PR (GitHub) | `gh pr create --base <mr_target> --head <feature> --fill` |
| FF merge (local:source) | `git -C <main_repo> merge --ff-only <feature>` |
| Push source (local:source, after explicit confirm) | `git -C <main_repo> push origin <source>` |
| Cleanup | `ExitWorktree(action="keep")` + `git worktree remove` (`--force` fallback) + `git worktree prune` + `git branch -d` |
