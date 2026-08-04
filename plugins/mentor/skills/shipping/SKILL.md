---
name: shipping
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

# branch == base: no PR/MR can open (a branch cannot target itself) and every push here
# lands on the protected branch. Ask before Step 2 — never fall through to Step 5.
# An `if` block, not `[ … ] && echo`: as the block's last command the latter exits 1 on
# every normal ship, which reads as a failed step.
if [ "$branch" = "$base" ]; then
  echo "ON-BASE: $branch is this repo's default/integration branch"
fi
```

Render to the user: the branch, the base, and
`git -C "$repo_root" diff "origin/${base}"...HEAD --stat` (fall back to the
local `$base` if the remote ref is absent).

**On the base branch.** If the block printed `ON-BASE`, stop and ask via
`AskUserQuestion` before Step 2:

- **Cut a feature branch from here and re-invoke (Recommended)** —
  `git switch -c <type>/<slug>`. Branch now, not later: Step 3 commits to
  whatever is checked out, so deferring means undoing a `chore(simplify)`
  commit on `<base>`.
- **Ship from `<branch>` anyway** — pushes straight to `origin/<branch>`, no
  PR/MR, no review. This binds Step 5: skip its question and go to **5B**.

5A is never offered here — `-o merge_request.target="$base"` from `$base` is a
self-targeting MR (GitLab answers `WARNINGS:` and opens nothing) and
`gh pr create --base X --head X` fails, both *after* the push has already landed
on the protected branch.

**`repo_root`, `branch` and `base` do not survive to the next step.** Every step below
is a separate Bash call, so re-run the block above at the top of any step that uses them.
This is not bookkeeping pedantry: `git -C ""` silently falls back to cwd, so an unset
`repo_root` looks like it worked, while an unset `base` turns `origin/${base}...HEAD` into
a fatal `ambiguous argument` — which reads downstream as "the feature touched no files"
and makes every file look out-of-scope.

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
# Re-derive: every Step here is a separate Bash call, so Step 1's variables are gone.
# `git -C ""` silently falls back to cwd, so an unset $repo_root looks fine and isn't.
repo_root="$(git rev-parse --show-toplevel)"
base="$(git -C "$repo_root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
[ -n "$base" ] || base="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)"

# --untracked-files=no on purpose: untracked files cannot be pushed, so they cannot reach
# the PR — blocking on them protects nothing, while permanently bricking ship in any repo
# that keeps local artifacts around (a tool's .temp/, .venv, a cache dir). This gate still
# blocks staged adds and unmerged paths; the exemption is narrowly "never `git add`ed".
[ -n "$(git -C "$repo_root" status --porcelain --untracked-files=no)" ] && {
  git -C "$repo_root" status --short --untracked-files=no >&2   # name them; else the user re-runs status
  echo "Working tree has uncommitted changes. Commit or stash them, then re-invoke /mentor:ship." >&2
  exit 1
}

# Untracked paths are REPORTED, never staged, never blocking. Keep this listing — Step 3
# uses it as the baseline for telling simplify's new files from pre-existing local junk.
git -C "$repo_root" ls-files --others --exclude-standard
```

One exception worth a question: if an untracked path sits under a directory that also
appears in `git diff --name-only "origin/${base}"...HEAD`, that is the "forgot to
`git add` the new module" case — the only untracked state that can actually break the PR.
Ask via `AskUserQuestion` before continuing. Otherwise say what you saw and move on;
never `git add` an untracked path to satisfy this step.

**Abort means abort.** Never branch, stage, commit, or stash on the user's behalf
to get past this gate — the exit belongs to the user, and a hand-sorted commit
ship invented is the one commit it must never author.

## Step 3 — Run `/simplify`

Invoke `Skill(skill="simplify")` **in this thread** (a Claude Code built-in; if
unavailable, do a quick review of the branch diff yourself instead). It fans out its own
review agents: while they run, **No busy-wait** applies here too
(`mentor:dispatch-agents`, "Async runtime & lifecycle") — end the turn and let the
harness re-invoke you when they report. A `Bash true` poll burns a whole turn and returns
nothing.

Mentor is subagents-first for *implementation*, which makes wrapping this call in an
`Agent` dispatch a tempting read — but it is the one thing that breaks the step. Simplify
already runs its own agents, so the wrapper adds no parallelism; what it does add is a
delegate that commits its own result and returns "done". Everything numbered below then
becomes dead code — including the out-of-scope question — and the **Re-entry** paragraph
that lands you at Step 4 never fires, so the ship tail's two `AskUserQuestion` gates are
skipped and the push happens without the user ever choosing to test or choosing where the
branch goes. Keep the call in-thread and this step keeps its checks.

After it returns:

1. **Re-run the clean check** — simplify may have edited files. Step 2's
   `--untracked-files=no` exemption is for the **blocking gate only**; untracked files
   belong in the comparison here, because simplify can create them.
2. Then, if anything is dirty:

   ```bash
   # Re-derive: separate Bash call again — see Step 2.
   repo_root="$(git rev-parse --show-toplevel)"
   base="$(git -C "$repo_root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
   [ -n "$base" ] || base="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)"
   feature_files="$(git -C "$repo_root" diff --name-only "origin/${base}...HEAD" | sort -u)"
   # Braces + the pipe INSIDE the substitution. `v=$(a; b) | sort -u` pipes the
   # assignment's stdout to sort and runs the whole thing in a subshell, so v is
   # never set in this shell at all — the comparison below then silently sees nothing.
   simplify_files="$( { git -C "$repo_root" diff --name-only HEAD
                        git -C "$repo_root" ls-files --others --exclude-standard; } | sort -u )"
   ```

   Subtract Step 2's untracked listing before judging scope: only untracked paths that
   were **not** already there are simplify's output. Pre-existing local junk must never
   reach the "include all" option — that is how a directory nobody meant to commit gets
   committed. Use the same `ls-files --others --exclude-standard` in both places;
   `git status --porcelain` collapses a directory to `?? dir/` while `ls-files` enumerates
   the files inside it, so mixing the two makes the difference meaningless.
   - If every dirty file is in the feature scope: **auto-commit without
     prompting** — `chore(simplify): refactor before ship` — and surface
     `git diff HEAD~1 --stat` in the ship summary.
   - If any file is OUTSIDE the scope: show the list and ask via
     `AskUserQuestion`: include in-scope only (Recommended) / include all / abort.

**Re-entry.** simplify runs its own numbered steps and its own agents, and it runs
long — dozens of tool calls, all of them someone else's flow. When it returns you are
back in **this** skill at Step 4. This is the seam where ship's tail gets dropped:
the next action is Step 4's question, never a `git add`/`git commit`/`git push` you
compose yourself. Steps 4 and 5 are both `AskUserQuestion` gates; skipping them means
the user never chose whether to test, and never chose where the branch goes.

## Step 4 — Conditional test step

Ask via `AskUserQuestion`: "Run the test suite before shipping?" —
Yes (Recommended) / No.

**Per-repo override first** — auto-detect guesses wrong in monorepos (a root
`npm test` can proxy to an unrelated workspace), so an explicit setting always
wins:

```bash
repo_root="$(git rev-parse --show-toplevel)"   # re-derive: separate Bash call (see Step 2)
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

Run it inside a subshell, re-deriving `repo_root` in that same Bash call:

```bash
repo_root="$(git rev-parse --show-toplevel)"   # re-derive: separate Bash call (see Step 2)
(cd "$repo_root" && <the resolved command>)
```

Monorepo test commands routinely start with their own `cd` into a workspace, and cwd
persists across Bash calls — so a bare `cd apps/web && npm run test:e2e` leaves every
later block running one directory down, where `git add CLAUDE.md` fails with `pathspec
did not match any files`. The parentheses confine the move to the test run.

On failure, ask: "Tests failed. What now?" — Stop and fix (default, exit 1) /
Ship anyway.

## Step 5 — Choose the ship target (mandatory)

Both answers must exist before any `git push`: Step 4's test answer and this step's
target answer. If you cannot point at the two `AskUserQuestion` calls in this
transcript, you skipped a step — ask now. Everything up to here is local and
reversible; the push is not.

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

**Not asked when `branch` = `base`** — Step 1's on-base question already chose;
go straight to 5B.

### 5A — Push + open PR/MR

Detect the host from `git remote get-url origin`:

- **GitLab** (URL contains `gitlab` or your self-hosted GitLab host) — fold MR
  creation into the push (idempotent — an existing open MR is reused):
  ```bash
  # Re-derive: separate Bash call, so Step 1/2's vars are gone. Pushing with an empty
  # $branch or $base targets the wrong ref — re-derive before every push, without exception.
  repo_root="$(git rev-parse --show-toplevel)"
  branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)"
  base="$(git -C "$repo_root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
  # Same fallback Steps 2/3 carry. Without it an unset origin/HEAD (any remote added with
  # `git remote add` rather than cloned) pushes -o merge_request.target="" — which fails
  # AFTER the push has already landed.
  [ -n "$base" ] || base="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)"

  # Title mirrors the GitHub path's `--fill`: the commit subject only when the branch is a
  # single commit. Unconditional `log -1` would title multi-commit MRs with Step 3's
  # auto-created `chore(simplify)` commit — worse than the slug. Fail-soft: a missing
  # origin/$base makes rev-list error, the count is empty, and title stays "$branch".
  title="$branch"
  [ "$(git -C "$repo_root" rev-list --count "origin/${base}..HEAD" 2>/dev/null)" = "1" ] &&
    title="$(git -C "$repo_root" log -1 --format=%s)"

  git -C "$repo_root" push -u origin "$branch" \
    -o merge_request.create \
    -o merge_request.target="$base" \
    -o merge_request.remove_source_branch \
    -o merge_request.title="$title" 2>&1 | tee /tmp/ship-push.out
  ```
  Surface the MR URL (grep for `/-/merge_requests/`). If a `WARNINGS:` block
  names `merge_request.target`, the target is invalid — the MR did NOT open;
  re-resolve the base (ask the user) and retry. An already-open-MR warning is
  fine **when the MR is this branch's own work** — print its URL. (An MR opened
  by someone else is the Step 1 ownership case; if Step 1 was skipped — no `gh`
  on a GitLab remote — check the MR author/title before shrugging it off.)

- **GitHub** — push, then open the PR with `gh` (run inside the repo):
  ```bash
  # Re-derive (separate Bash call again — see 5A's GitLab block).
  repo_root="$(git rev-parse --show-toplevel)"
  branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)"
  base="$(git -C "$repo_root" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
  [ -n "$base" ] || base="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)"   # see the GitLab block
  git -C "$repo_root" push -u origin "$branch"
  (cd "$repo_root" && gh pr create --base "$base" --head "$branch" --fill)
  ```
  If `gh` is absent, print the compare URL instead.

- **Other host** — push, then print the compare URL for manual PR creation.

### 5B — Push to upstream

```bash
# Re-derive (separate Bash call again — see 5A).
repo_root="$(git rev-parse --show-toplevel)"
branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)"
git -C "$repo_root" push -u origin "$branch"
```

**Either target:** the two rejections have opposite fixes — read which one git printed,
don't pattern-match the server's wording (it differs per host).
`! [rejected] … (non-fast-forward / fetch first)` is git's own fast-forward check: the
remote moved. Surface it and ask whether to `git pull --rebase origin "$branch"` and
retry, or stop.
`! [remote rejected]` means the *server* refused, and no rebase can change that — a
retry just re-declines. When the reason names a hook or a protected branch
(`pre-receive hook declined`, `protected branch hook declined`, `GH006`), cut a feature
branch from the current HEAD (`git switch -c <type>/<slug>`) and redo the push via
**5A**, so the work lands as a PR/MR into the protected branch. Then, if you were on
`$base`, `git branch -f "$base" "origin/$base"` — those commits now live on the feature
branch, and leaving `$base` ahead makes the next ship's `origin/$base...HEAD` diff and
ahead-count double-count them. Any other remote rejection (`cannot lock ref`, quota):
surface it and stop — never guess.
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
      bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" ensure-dir "$hand_dir/resolved" >/dev/null
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

## Step 7 — Point at the merge tail, and stop

**Stop here.** Ship's job ends at the open PR/MR. Emit one line in the ship report naming
where the tail lives: **GitHub + `gh`** → `Watch CI and merge with /mentor:merge`;
**any other host** (GitLab included — `/mentor:merge` is GitHub-only) →
`Watch the pipeline and merge at <URL>`, reusing the URL 5A already surfaced.
Keeping the tail in `/mentor:merge` is what makes it re-enterable after a stalled CI run
without re-running ship.

Do **not** watch checks, poll `gh run`, or `sleep` after the push — `/mentor:merge`
Step 2 owns the one bounded watch, and chaining sleeps or re-checks is the **No busy-wait**
rule owned by `mentor:dispatch-agents` ("Async runtime & lifecycle").

One carve-out worth naming, because it is the reason this gets overridden: when the plan's
own `Done when:` requires a green CI run, that obligation is real — but it does not license
watching here. Invoke `/mentor:merge`, which owns the bounded watch, and report what it
found. The `Done when:` is satisfied either way; the difference is whether the waiting is
done by something that knows how to wait.

## Failure modes

| Situation | What to do |
|---|---|
| Detached HEAD | Abort — check out a branch first. |
| On the default/integration branch (`branch` = `base`) | Step 1 asks first: cut a feature branch and re-invoke (recommended), or push straight to `origin/<branch>` with no PR. Never offer 5A — the PR/MR cannot open and the push lands first. |
| Dirty tree at Step 2 | Abort — the *user* commits or stashes, then re-invokes; ship never branches, stages or commits to clear it. Untracked-only is NOT dirty; report it and continue. |
| Tempted to watch CI after the push | Stop and hand to `/mentor:merge`. Never a `seq`/`sleep` poll loop — that is the **No busy-wait** rule. |
| Simplify edited out-of-scope files | Ask before committing. |
| Tests fail | Default: stop; branch intact for iteration. |
| A test command with its own `cd` ran unconfined | cwd persists across Bash calls, so later `git add <path>` fails with `pathspec did not match any files`. Wrap it — `(cd "$repo_root" && <cmd>)` — and re-derive `repo_root` in any block that moved. |
| Tempted to dispatch an Agent to run `/simplify` | Keep Step 3 in-thread. The delegate commits its own result and returns "done", so the clean check, the out-of-scope question, and the Step 4/5 gates all silently never run. |
| Push rejected | `! [rejected]` (non-fast-forward) → offer `pull --rebase` + retry, or stop. `! [remote rejected]` (server hook / protected branch) → rebase cannot help; cut a feature branch and redo via 5A, then realign `$base` to `origin/$base`. Never force-push. |
| `gh pr create` fails: PR already exists for this branch | Do NOT open a duplicate — print the existing PR's URL (`gh pr list --head "$branch"`) and confirm with the user it now contains what they meant to ship (Step 1's ownership answer applies). |
| MR/PR creation fails (other) | The branch is already pushed and safe — print the compare URL. |
