# Executing a phase another framework owns

Read this before the first dispatch on a phase whose plan of record lives elsewhere —
spec-kit's `tasks.md`, a Jira epic, any backlog mentor did not author. `SKILL.md` →
"When NOT to use — another framework owns the plan of record" holds the routing decision;
this file is what the path costs once you are on it. A mentor plan never reaches here.

## What this path skips

Every `plan.md` mechanic in `SKILL.md` has no counterpart here and is skipped: the
approved-plan read, ✅ ticks, `plan-state.sh`, the edit gate, and the `## Verification`
dispatch. `/mentor:defer` redirects too — a follow-up belonging to that framework's
backlog goes there, not into a mentor stub.

Repo work outside that framework's scope is **named in your report** and `/mentor:defer`
offered. This path is self-graded, with no verifier and no disposition gate behind it, so
there is nothing here that could responsibly park work on the user's behalf.

## The three rules

- **Copy `Goal:`/`Done when:` verbatim from the task's own text**, and verify the delivery
  against that text — your brief is a lossy transcription of it. You self-grade here: the
  weakest-grader rationale in `SKILL.md` → "Verifying the plan (execution-time)" does not
  reach this path, because that framework owns its own verification.
- **Never let the record drift from the work.** The orchestrator, not the agent, lands
  each check-off in the same commit as that task's own work — never batched, never left
  dirty for a later task to sweep in.
- **Write that progress line and nothing else in the framework's files.** A spec conflict
  blocking a `Done when:` goes to that framework's own amend command — mentor never edits
  another framework's artifact of record.
