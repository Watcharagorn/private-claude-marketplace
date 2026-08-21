# The non-goal disposition gate — the six steps

Read this when a verification round has any open finding the user has not ruled on, after
remediation has settled and before the `implemented` write. Route the unstamped gaps first
(below) — that is what decides whether the `[NON-GOAL]` set is empty. Only then does an
empty set skip the gate, which is why these steps are not in `SKILL.md`.

Two rules govern the gate and stay inline in `SKILL.md` → "The non-goal disposition gate",
because the pressure they resist arrives while you are still reading verifier reports:
every `[NON-GOAL]` gap is the **user's** decision, and a stamp the verifier set stands is
never re-graded.

## Unstamped gaps have their own route

**Unstamped** gaps are real, and they are not the same as `[NON-GOAL]` ones: a verifier
that ignored the contract, a `Cross-topic:` finding you promoted to a round gap (those
carry no stamp by construction), or work a dispatched implementation agent reported from
outside its step's scope. Ask that verifier for the stamp, exactly as a missing
`Gaps / Missing:` line is re-asked (`SKILL.md` → "Verifying the plan (execution-time)");
if it comes back unstamped again, or there is no verifier to ask, treat it as `[NON-GOAL]`
and it rides through this gate with the rest.

## The six steps

1. **Digest.** One line per `[NON-GOAL]` finding, `[LARGE]` first: a 2–4 word handle, the
   size, half a sentence of what it is, and the verifier's `fix:` clause. Empty set → skip
   the gate and go straight to the report. **Size, not
   severity, drives the split below** — the opposite of how `plan-review` walks its
   findings, and worth holding onto if that skill is also in context. Severity was already
   spent on the `[GOAL]`/`[NON-GOAL]` call; what is left to decide is whether the user
   wants to spend a session on the fix.
2. **Walk the `[LARGE]` ones** — one `AskUserQuestion` each, the handle as its header, a
   `(<k> of <n>)` prefix, opening with one plain sentence naming the decision. In practice
   a round produces none to two of these. Options: **"Defer as its own plan"** /
   **"Fix it now in this session"** / **"Leave open"** / **"Skip the rest"** — the last
   leaves this finding and **every** remaining one open, batched ones included, so offer it
   only while findings still remain anywhere in the gate. Say in the question text that a
   narrower resolution is reachable through "Other".
3. **Batch the `[SMALL]` ones into ONE question.** Header `"Remaining <N>"`. Restate each
   finding as its own line *inside the question text* — the digest may have scrolled away,
   and a question that points back at earlier output is one the user has to leave the
   screen to answer. Three options: **"Fix them all now (Recommended)"** /
   **"Defer them all"** / **"Leave all open"**. Exactly one remaining finding collapses to
   a normal per-finding question instead.
4. **Apply the verdicts once they are all in**, in a single pass. Remediation dispatches
   stay sequential, per the failure loop in `SKILL.md` → "Verifying the plan
   (execution-time)".
5. **A Defer verdict is itself the invocation** — run the capture rather than telling the
   user to retype `/mentor:defer`. Invoke `Skill(skill="mentor:deferring")` and state the
   routing as a prose preamble, the shape `planning` already uses when it prepends "The
   user selected …" ahead of a skill load: `from` = this plan, `parent` = **none**,
   `category` = the verifier's judgement, and **`priority` left unset** — an explicitly
   non-goal finding must not float to the top of `/mentor:track`'s build queue. The
   single exception to `parent` = none: a defect in an **already-implemented** plan's
   shipped work parks under *that* plan, which it genuinely blocks. If `deferring` refuses
   the item under its own scope rule, **record it left open and say so** — a verdict the
   user gave must not evaporate because the capture bounced.

   Then stamp each flat stub the capture created, using the slug it reported back:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" set <stub-slug> draft --note "gate: left uncontained"
   ```

   That note is what tells the rest of the harness this stub is flat **on purpose**;
   without it, every future `/mentor:track` and `/mentor:resume` would offer to adopt it,
   asking the user to reverse a decision they already made here. Skip the stamp on the
   already-implemented exception above: that stub has a `parent` and is contained.
   (Why an unstamped flat stub trips the lineage alarm, and why an unset `priority`
   matters: `references/rationale.md` → **Why a gate-routed stub is flat on purpose**.)
6. **Report three groups**, by handle: fixed, deferred (with their stub slugs), and left
   open — plus the verifiers' `Notes:` lines as context, unverdicted. The left-open group
   is exactly what the `implemented` write records as `--note "open: …"`.

Each question follows the relay rule in `SKILL.md` → "Context efficiency — the
orchestrator contract": strip the agent-side ids, carry the finding rather than its
filing, and let the question stand on its own.
