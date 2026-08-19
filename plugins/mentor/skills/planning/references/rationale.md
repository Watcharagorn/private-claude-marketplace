# planning — rationale

Why the rules in `SKILL.md` are shaped the way they are: the failure each one
prevents, the mechanism behind it, and the incident that produced it.

**Read this only when you are editing `planning/SKILL.md`, or when a rule there looks
wrong and you are about to work around it.** It is deliberately not part of the skill's
own context — every one of these passages was once inline, re-read on every plan run,
to explain something that only matters when the rule itself is in question.

Each section is anchored so `SKILL.md` can point at it directly.

## Step 0 — the armed-gate check

(The `dir` guard comes first on purpose: outside a git repo, `dir` echoes the
`_no-repo` fallback path — never one ending in `/.mentor` — so `gate`'s `RELEASED`
there is never mistaken for "not armed inside a repo"; the `case` simply has no
branch to match and prints nothing. Inside a repo, `gate` already resolves this
worktree's own marker or the legacy repo-global one, so this check needs no
`--git-common-dir`/`--show-toplevel` handling of its own.)

The equality is **strict**: only the exact `ARMED` token counts as armed for this
check. `ARMED_ELSEWHERE` — a sibling worktree's marker is live, an independent gate
that does not block this one — reads as **NOT ARMED here**, same as `STALE` or
`RELEASED`. `STALE` reading as NOT ARMED is a **deliberate flip** from the old bare
`[ -f marker ]` check: a marker file merely *existing* used to read as armed no
matter its age, but a `STALE` marker is past the self-heal window and
`plan-gate.sh` no longer enforces it — treating it as armed here would make this
check stricter than the gate it is checking.

`GATE: NOT ARMED` means `plan-gate.sh` has no marker enforcing THIS worktree, so
every repo edit stays allowed for the whole session while Step 6 goes on showing its
"no edits until approved" banner. Planning that only *looks* read-only is worse than
planning that admits it isn't, so do not continue: say so in one line and ask the
user to run `/mentor:plan <their request>`, which arms the gate and comes back here.

Do **not** run `begin-plan.sh` yourself to patch this up — on a large session it
answers `CONTEXT: ASK` and exits *without* arming, and resolving that with the user
is the command's job, not this skill's.

## Step 2 — why searching `.mentor/` needs `sweep`, not a grep

**`.mentor/` is gitignored — a recursive `grep` can miss it, even aimed straight at the
dir.** `hooks/lib/state.sh` writes `.mentor/.gitignore` as `*` + negations (only
`.gitignore`/`config.json`/`constitution.md` are un-ignored), so a gitignore-aware search
returns a clean "no hits" for a standing instruction — a "no subagents" policy, an earlier
decision — recorded in a prior handoff note under `.mentor/plans/*/handoffs/`, whether the
search scans the whole repo or `.mentor/` alone. A bare relative path is also wrong in a
linked worktree, which shares the MAIN repo's `.mentor/` (Step 0's `--git-common-dir`
note) rather than having its own.

The mechanism is the **traversal root**, not a missing flag — worth understanding, because
it decides what the fix has to be. Ignore rules apply only while **grep itself** is
walking, and a grep collects the `.gitignore` files at or below its own root without ever
walking *up*. So a search rooted at the repo root or at `.mentor/` finds nothing, while
one rooted at `.mentor/plans/` happens to work — which is exactly why the command that
used to sit here *looked* fine. It is also not a quirk of one machine's toolchain: the
Bash tool's shell carries a `grep` **function** routing to Claude Code's own bundled ugrep
with `--ignore-files` already on, so `grep -r` over `.mentor/` returns a clean zero here
whatever greps are installed — and since that function is not on `PATH`, a check launched
as `bash foo.sh` gets a *different*, ignore-blind `grep` and appears to work. Never
conclude from "it worked in my test script" that it works where this is prescribed. Reaching for a "no ignore" flag is the wrong fix twice
over: those spellings differ per implementation (ugrep rejects the GNU one outright with
exit 2), so a flag only moves the failure to someone else's machine. Hand grep an explicit
file list instead — `find` walks, `grep` only reads — which is what `sweep` does, worktree
resolution included:

## Step 2 — when research earns a dispatch, and why the batch goes out in one message

For multi-area or unfamiliar tasks, prefer dispatching **1–3 read-only `Explore`
agents** (`model: sonnet` — this is locate-and-map work, not design; leaving it
unpinned defaults to the session's own model, a needless cost multiplied by every
agent in the batch) over disjoint areas — issue every `Agent()` call for the batch in a
**single message** (N `tool_use` blocks side by side), not one call per message
waiting for each dispatch's tool_result before writing the next. Serializing the
dispatch buys nothing — the agents run async once out either way — and spends a
full main-thread round trip per agent. This keeps the main conversation lean. The strongest signal is an unfamiliar external
platform (an integration, SDK, or cloud service this session has not already
researched) **together with** 2+ pre-existing areas of the repo: each half alone
looks manageable inline, and the pair is what actually exhausts a context
window. A second, standalone signal: **2+ separate git roots** touched by the
same plan — unlike areas within one repo, a second root doesn't need pairing
with an unfamiliar platform to earn its own dispatch, since each root carries
a full orientation cost (build system, conventions, entry points) the other
root's research does nothing to amortize. Dispatch one agent per root, still
inside the 1–3 cap, and resolve each root's real path first (`git rev-parse
--show-toplevel`) before dispatching — a stale duplicate checkout otherwise
burns a whole dispatch researching the wrong copy. The edit gate only
protects the repo the session's CWD sits in, so a step whose work lands in a
second root isn't read-only-gated the way this repo's own edits are, until
that root has its own plan and gate (`plan-state.sh relocate`'s README note
spells out the same limit for a moved plan). For small, well-scoped tasks,
read the files and draft directly in the main thread. Nothing enforces
delegation; use judgment — with one backstop for when that judgment already
said "inline" and the reading kept going: once main-thread research reading
passes roughly 5 files or ~500 cumulative lines, the task is no longer small,
so dispatch an `Explore` for what is left rather than bulk-reading on. The one
artifact a decision actually turns on is still read here (Step 3.5's evidence
rule) — it is the survey reading around it that belongs in an agent. Context
spent on raw research reads doesn't come back for the rest of the plan —
grilling, drafting, and Step 3.5's decision loop still have to fit in what's
left.

## Step 6 — why the option rows are ordered the way they are

Split leads on an oversized plan because handing one off whole only moves the problem
to the next session, while the split's authoring cost lands in dispatched agents
rather than in this thread. **`CONTEXT: HANDOFF` outranks even that**: at that size the
safest possible act is to write the handoff and stop, and the split can happen in the
fresh session with room to verify it — which is also why *Split* is the option that
yields in the oversized **and** `CONTEXT: HANDOFF` row. Review stays visible in the
oversized-only row because an oversized plan is exactly the kind most worth reviewing;
*Keep planning* yields instead.

**Why *Keep planning* yields to the new option once a context verdict fires.** Both
mean "do not approve yet", so listing both wastes one of four slots — and of the two,
*Keep planning* is the one that needs no button: the user just keeps talking and
planning continues. "Pause — still drafting" cannot be improvised that way, because it
has to write the handoff **without** approving, and every other listed option at that
point releases the gate. *Proceed* and *Deliver plan only* both stay visible in every
row: the `MODE:` default must always be offered (Step 0), and pushing the option that
starts implementation into free text would make the highest-consequence answer the
hardest one to give.

## Retracting an approval — why each of the three steps is required

The `plan-state.sh set <slug> draft` line in the first snippet above is not optional
either. **Every** approval path — no-arg, `--deliver`, `--handoff` — promotes the
plan's `.state.json` to `approved` before it exits, and `begin-plan.sh` touches only
the marker. Re-arm alone therefore leaves a plan recorded as `approved` behind a
closed gate: `/mentor:track` reads the sidecar, not the marker, so a later session
sees a green light and dispatches implementation agents into a gate that denies
their first write.

Two consequences to tell the user about while you do it:

- **The plan must be re-written before it can be approved again.** Re-running
  `begin-plan.sh` resets the marker's mtime, and `approve-plan.sh` refuses any
  `plan.md` older than the marker. This is the same staleness defense that stops an
  old plan being resurrected, and here it fires on the plan you just retracted. Any
  genuine revision (a Rev bump per Step 4) clears it.
- **Retraction is a pre-implementation act.** Effective state is the *more advanced* of
  the stored state and what the plan's `✅` step ticks imply, so storing `draft` on a
  plan that already has ticks is silently outranked — `plan-state.sh` even says so as it
  writes. If any step is ticked, work has already shipped: surface that to the user as a
  rollback decision (revert the work, or keep it and re-plan the remainder) instead of
  quietly writing a state that will not take.
