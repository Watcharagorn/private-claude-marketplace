---
name: merging
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
gh pr list --head "$branch" --state all --limit 5 --json number,title,url,state,mergeable,mergeCommit
```

`$ARGUMENTS` may name a PR number instead — use it verbatim.

`--state all`, not `--state open`, because merges happen outside this session all the
time — someone hits the button in the GitHub UI. An **open** PR runs the whole flow from
Step 2. A PR that is already **MERGED** has nothing left to watch or gate, but its plan
state is almost certainly still open, so skip Steps 2–4 and enter at **Step 5** with the
merge commit in hand — that is the only path by which a UI merge ever gets its plan
closed. Neither an open nor a merged PR → report that and stop.

## Step 2 — One bounded watch

```bash
gh pr checks <number> --watch --interval 30
```

Run this with an explicit **`timeout: 600000`** — `--watch` blocks until every check
reaches a terminal state, and the Bash tool's default is 120s with a 600s ceiling, so
without it the call dies on any CI slower than two minutes and looks like a failure.

One blocking call — **never** a hand-rolled sleep/poll loop; this is the **No busy-wait**
rule owned by `mentor:dispatch-agents` ("Async runtime & lifecycle"), which covers waits
on long-running commands as well as on agents. That leaves three outcomes:

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

## Step 5 — Close the plan's state

Only after a merge actually landed. `mentor:shipping` Step 6 closes plan state when it
*opens* the PR, so a PR that merges in a later session — or that `ship` never
opened — leaves its plan at `in_progress`, and the next `/mentor:track` re-offers
work that already shipped. This step closes that half of the loop; it is a no-op
when ship already did it, because `set` is idempotent.

Merge resolves the topic differently from ship, and better: ship asks what *this
session* worked on, which a merge-only session cannot answer, while the PR names
it. Take the merged PR's head branch, strip a leading `<type>/`, and match the
remainder against `plan-state.sh list` slugs with **`mentor:resuming` Step 4's
unique-substring rule** — ambiguous or no match means no candidate, and you stop
here rather than guessing.

With a candidate in hand, ask before writing — a PR often carries only some of a
plan's steps, and `implemented` would hide the rest from `/mentor:track`:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" set <slug> implemented --note "merged: PR #<n> <sha>"
```

Carry the `--note`: a bare `set` replaces any existing note with an empty one, so a
prior `failed` reason would be lost. The directory guard and the split-parent
downgrade caveat are `mentor:shipping` Step 6's ("Also close the plan's state") — follow
them there rather than reading a second copy here. No candidate, or the user says
no → say what you found and stop; never hand-edit `.state.json`.

## Step 6 — The post-merge run on the base branch

Only on the **"Merge now"** branch, and only after Step 5's bookkeeping is durable — an
`--auto` merge lands after this session ends, and a ten-minute block must never sit in
front of a state write.

A green PR run does not imply a green base run: the PR tested a merge preview, the base
tests what actually landed. When that gap keeps biting a repo, the durable fix is branch
protection, required checks, or a merge queue — this step reports, it does not fix.

Ask once via `AskUserQuestion` — "Watch `<base>`'s post-merge run? Yes (Recommended) /
Stop here" — because an unrequested ten-minute wait at the end of a session is worse than
missing the result. On yes, resolve the run **by the merge SHA**, never "newest on base"
(a second merge can land first):

```bash
gh run list --branch "$base" --limit 10 --json databaseId,headSha \
  -q "[.[] | select(.headSha==\"$sha\")][0].databaseId"
```

(`--commit` is absent in older `gh`; filtering the list works everywhere.) Empty means the
run has not been created yet — wait once, retry once, and stop. Do not loop.

Then **one bounded `gh run watch <id>`, exactly as Step 2 does it** (`timeout: 600000`) —
the **No busy-wait** rule owned by `mentor:dispatch-agents`. On red, name the failing job
and stop: no triage, no rerun. Step 3's one-rerun budget is PR-scoped, and a regression on
the base branch is a fresh working session, not a tail on this one.

## Done when

- The PR was resolved (argument or current branch), its checks reached a terminal
  state through at most one watch + one rerun + one more watch, any regression was
  reported with the failing test named, and a merge happened only through the user's
  explicit choice — or the PR was left open with its status stated plainly.
- A landed merge either closed its plan's state on the user's say-so, or reported that
  no plan matched the branch — never left a shipped plan silently `in_progress`. A PR
  merged outside the session still reached this step, rather than being reported as
  "no open PR, nothing to do".
- After a "Merge now", the base branch's post-merge run was either watched once on the
  user's say-so and its result reported, or explicitly declined — never polled in a loop.
