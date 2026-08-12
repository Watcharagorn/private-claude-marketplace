---
name: merging
description: >
  Watch a PR's CI checks, triage a failure once (flake vs regression vs a base branch
  that was already broken), and merge on green — always with the user's explicit
  go-ahead. User-invoked via /mentor:merge after /mentor:ship (or for any open PR on
  the current branch, mentor-made or not). Use when the user says "watch the PR and
  merge when green", "check CI and merge", "merge if checks pass", or "is this failure
  even mine". GitHub-only (needs gh); one bounded watch, one rerun max, never a
  busy-poll loop.
---

# merge — watch checks, triage once, merge on green

`/mentor:ship` deliberately ends at "PR open" — re-running ship to get a merge would
re-run simplify, the clean check, tests and the push, and ship has already retired the
topic's handoff notes, so there is nothing to resume from either. This skill is the
re-entry point for the tail: watch CI, work out **once** whether a failure is a flake,
this diff's regression, or rot that was already on the base branch, and merge only when
the user has said so.

## When NOT to use

- The PR isn't on GitHub or `gh` is unavailable — say so and print the PR URL; there
  is no polling fallback worth an agent's turns. This is a `gh` scope line, not a
  domain check: a **self-hosted GitLab** remote lands here too, and so does anything
  else `gh` doesn't speak. Say the tail is manual on that host rather than leaving the
  user to infer it from "isn't on GitHub" — `/mentor:ship` opens the MR fine and
  already closes plan state when it does, so nothing is stuck; only the watch-and-merge
  half is theirs to finish in the web UI.
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

**When `--log-failed` names the job but not the cause** — a bare `1 failed` with no assertion, diff,
or stack — the evidence is in the run's **artifacts**, not stdout (browser/E2E suites put it there).
Look **once**, before spending the rerun on a guess:

```bash
# Re-derive: $run_id died with the block above. `gh api` expands {owner}/{repo} itself.
run_id="$(gh run list --branch "$(git branch --show-current)" --limit 1 --json databaseId -q '.[0].databaseId')"
gh api "repos/{owner}/{repo}/actions/runs/$run_id/artifacts" --jq '.artifacts[].name'
dir="$(mktemp -d)"; gh run download "$run_id" -n "<the report artifact>" -D "$dir" && ls -R "$dir"
```

`gh run view --json` has **no** `artifacts` field, so the REST call is the only listing. `-D` is
mandatory — `gh run download` extracts into the **current directory** by default, dropping hundreds
of MB of report junk into the repo working tree. Download **by name** and read only the small
text/JSON summaries; traces, videos and the HTML report are binaries you cannot read. One artifact,
one look — if it is silent too, report what the log did say and let the decision below stand on the
base-run history.

**Ask whether the failure is even yours before spending the rerun.** "Unrelated to the
diff" reads like a flake, so a deterministic environment failure (a missing binary, a
service that never comes up — `supabase: not found`, exit 127) routes to *flake*, burns
the one-ever rerun on something that cannot pass, then gets relabelled a regression of a
PR that never caused it. Two commands separate rot from a flake — and if the topic's live
handoff note already records a base-branch finding, read it instead of re-deriving:

```bash
# Re-derive here: $branch and $run_id from the block above are gone with their Bash call.
branch="$(git branch --show-current)"
base="$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
[ -n "$base" ] || base="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)"
[ -n "$base" ] || { echo "ERROR: cannot resolve base branch" >&2; exit 1; }   # unset $base makes the diff below a fatal ambiguous-argument
wf="<the failing workflow name from gh run view>"
gh run list --workflow "$wf" --branch "$base" -L 20 \
  --json conclusion,createdAt,url -q '.[] | "\(.createdAt) \(.conclusion) \(.url)"'
git diff --stat "origin/${base}...HEAD" -- .github/ docker-compose*.yml compose*.yaml Makefile
```

The 20-run history is what distinguishes rot from one bad night on the base: one red run
proves nothing, a red streak since a datable commit proves the base was already broken.

Then decide:

- **Pre-existing (broken base)** — the same job fails the same way on `$base`, the streak
  predates this branch, and the diff touched no CI or environment files. **Don't spend the
  rerun**: it can only fail identically. Report both run URLs and the date the streak
  started, then carry this verdict into Step 4, which is where the user chooses what to do
  about a PR that can never go green on its own.
- **Plausible flake** (infra timeout, known-flaky test, unrelated to the diff **and** the
  base is green): `gh run rerun "$run_id" --failed` — **once, ever** — then repeat Step 2's
  watch.
- **The same job fails the same way twice, or the failure touches this diff**: it is
  a regression. Stop, report the failing test + log excerpt, and leave the PR open.
  Fixing it is a new working session, not a merge step.

## Step 4 — Merge, gated

Never merge on your own judgment. Ask via `AskUserQuestion`. **Every question stands on its
own** — the user answers from the question screen alone, never sent to a file, a CI log, a
check name, or an earlier turn to learn what the question means: when a failure is what
they are deciding about, put the failing test's name and the one line that explains it in
the question, not a link to the run.

- **Merge now** — `gh pr merge <number> --squash` (match the repo's convention if it
  clearly uses merge/rebase instead).
- **Auto-merge on green** — `gh pr merge <number> --auto --squash`: GitHub merges when
  checks pass, no further watching needed; end the session after confirming it queued.
- **Leave open** — report status and stop.

**On a `pre-existing (broken base)` verdict the option set changes**, because the PR
cannot reach green by waiting: drop **Auto-merge on green** (it would queue forever) and
offer instead **Merge anyway** — stating plainly which jobs *did* pass, so the user is
weighing real evidence rather than a bare override — alongside **Leave open**. Whichever
they pick, the rot itself outlives this PR: it's a pre-existing defect on `base`, not a
check on this PR's own work, so under the scope rule its **fix** is deferrable. Capture
that fix with `/mentor:defer "fix <failing job>, broken on <base> since <date>"` before
you finish; a verdict that lives only in this turn's output is how the same five `gh`
calls get spent again next week.

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
# Derive both here: every earlier assignment died with its own Bash call.
pr="<the PR number from Step 1>"
base="$(gh pr view "$pr" --json baseRefName -q .baseRefName)"
sha="$(gh pr view "$pr" --json mergeCommit -q '.mergeCommit.oid')"
[ -n "$base" ] && [ -n "$sha" ] || { echo "ERROR: no base/merge SHA for PR $pr" >&2; exit 1; }
gh run list --branch "$base" --limit 10 --json databaseId,headSha \
  -q "[.[] | select(.headSha==\"$sha\")][0].databaseId"
```

(`--commit` is absent in older `gh`; filtering the list works everywhere.) Empty means the
run has not been created yet — wait once, retry once, and stop. Do not loop.

Then **one bounded `gh run watch <id>`, exactly as Step 2 does it** (`timeout: 600000`) —
the **No busy-wait** rule owned by `mentor:dispatch-agents`. On red, name the failing job
and stop: no triage, no rerun. Step 3's one-rerun budget is PR-scoped, and a regression on
the base branch is a fresh working session, not a tail on this one.

When the red is the **same test Step 3 flake-verdicted**, that is not a second budget — it is a test
that failed, went green on a rerun, and failed again on what actually landed, which is as easily a
real failure the rerun masked as a flake. This is a pre-existing defect on `base`, not a check on
this PR's own work, so its fix is work to build, never a check to run — name it and capture **that
fix** with `/mentor:defer "fix <test> flaky on <base>"`: that verdict outlives this session, while
another rerun would only re-roll it.

**A green run on `base` is when a deploy artifact actually goes live** — the merged PR may have
touched one. The detection is `mentor:shipping` Step 7's ("Say when the shipped diff touches a
deploy artifact"); if that session's own ship never ran or predates this merge, repeat it here
against `base`'s diff rather than re-deriving a second copy of the pattern list.

## Done when

- The PR was resolved (argument or current branch), its checks reached a terminal
  state through at most one watch + one rerun + one more watch, any regression was
  reported with the failing test named, and a merge happened only through the user's
  explicit choice — or the PR was left open with its status stated plainly.
- A red check was sorted into flake / regression / **pre-existing (broken base)** before
  the rerun was spent, using the base-branch run history and the CI-file diff — and a
  pre-existing verdict reached Step 4 as its own option set plus a `/mentor:defer` capture,
  never as a third dead end.
- A landed merge either closed its plan's state on the user's say-so, or reported that
  no plan matched the branch — never left a shipped plan silently `in_progress`. A PR
  merged outside the session still reached this step, rather than being reported as
  "no open PR, nothing to do".
- After a "Merge now", the base branch's post-merge run was either watched once on the
  user's say-so and its result reported, or explicitly declined — never polled in a loop.
