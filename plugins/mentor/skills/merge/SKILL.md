---
name: merge
description: >
  Watch a PR's CI checks, triage a failure once (flake vs regression), and merge on
  green — always with the user's explicit go-ahead. User-invoked via /mentor:merge
  after /mentor:ship (or for any open PR on the current branch, mentor-made or not).
  Use when the user says "watch the PR and merge when green", "check CI and merge",
  "merge if checks pass". GitHub-only (needs gh); one bounded watch, one rerun max,
  never a busy-poll loop.
---

# merge — watch checks, triage once, merge on green

`/mentor:ship` deliberately ends at "PR open" — re-running ship to get a merge would
re-run simplify, the clean check, tests and the push, and ship has already retired the
topic's handoff notes, so there is nothing to resume from either. This skill is the
re-entry point for the tail: watch CI, distinguish a flake from a regression **once**,
and merge only when the user has said so.

## When NOT to use

- The PR isn't on GitHub or `gh` is unavailable — say so and print the PR URL; there
  is no polling fallback worth an agent's turns.
- The user wants to *create* the PR — that is `/mentor:ship`.

## Step 1 — Resolve the PR

```bash
branch="$(git branch --show-current)"
gh pr list --head "$branch" --state open --json number,title,url,mergeable
```

`$ARGUMENTS` may name a PR number instead — use it verbatim. No open PR → report that
and stop (nothing to watch).

## Step 2 — One bounded watch

```bash
gh pr checks <number> --watch --interval 30
```

Run this with an explicit **`timeout: 600000`** — `--watch` blocks until every check
reaches a terminal state, and the Bash tool's default is 120s with a 600s ceiling, so
without it the call dies on any CI slower than two minutes and looks like a failure.

One blocking call — **never** a hand-rolled sleep/poll loop (mentor's own rule: do not
busy-poll across turns). That leaves three outcomes:

- **All green** → Step 4.
- **Non-zero because checks failed** → Step 3.
- **The 10-minute ceiling hit first** (CI is simply longer than the tool allows) — do
  **not** start a second watch, which would burn another ten minutes to learn the same
  thing. Take one non-blocking `gh pr checks <number>` for current status, report it,
  and offer auto-merge from Step 4: `--auto` hands the waiting to GitHub, which is the
  right tool for CI that outlasts a turn.

## Step 3 — Triage a failure ONCE

Resolve the run id first — nothing upstream produces one (`gh pr checks` prints check
names and URLs, not ids), and `$branch` from Step 1 is gone with its Bash call:

```bash
branch="$(git branch --show-current)"
run_id="$(gh run list --branch "$branch" --limit 1 --json databaseId -q '.[0].databaseId')"
[ -n "$run_id" ] || { echo "ERROR: no workflow run found for $branch" >&2; exit 1; }
gh run view "$run_id" --log-failed
```

Then decide:

- **Plausible flake** (infra timeout, known-flaky test, unrelated to the diff):
  `gh run rerun "$run_id" --failed` — **once, ever** — then repeat Step 2's watch.
- **The same job fails the same way twice, or the failure touches this diff**: it is
  a regression. Stop, report the failing test + log excerpt, and leave the PR open.
  Fixing it is a new working session, not a merge step.

## Step 4 — Merge, gated

Never merge on your own judgment. Ask via `AskUserQuestion`:

- **Merge now** — `gh pr merge <number> --squash` (match the repo's convention if it
  clearly uses merge/rebase instead).
- **Auto-merge on green** — `gh pr merge <number> --auto --squash`: GitHub merges when
  checks pass, no further watching needed; end the session after confirming it queued.
- **Leave open** — report status and stop.

Report the result (merged SHA or queued state) and, if the branch is deletable
per repo convention, mention `--delete-branch` as an option — don't apply it
unasked.

## Done when

- The PR was resolved (argument or current branch), its checks reached a terminal
  state through at most one watch + one rerun + one more watch, any regression was
  reported with the failing test named, and a merge happened only through the user's
  explicit choice — or the PR was left open with its status stated plainly.
