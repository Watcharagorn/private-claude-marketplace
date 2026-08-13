---
name: planning
description: >
  Not a standalone entry point, and NOT for a conversational planning request — when the
  user asks to plan something, run the /mentor:plan COMMAND; never select this skill to
  answer that ask. This is the body of that command: it runs begin-plan.sh first to arm
  the marker-driven edit gate that holds planning read-only; loaded any other way this
  skill detects the unarmed gate at Step 0 and stops, pointing you at the command.
  Guides research, domain routing, resolving open decisions with the user one at a
  time (AskUserQuestion with decision support), writing a Mermaid-first Markdown
  plan into the gate-exempt .mentor/ tree, and the approval that releases the gate.
---

# mentor Plan

The flow: resolve the mode & load the constitution → clarify if needed →
research (delegation suggested) → domain routing → resolve open decisions
with the user → write the Markdown plan
(with a Constitution Check when a constitution exists) → (optional
topic × perspective HTML zooms via `mentor:zooming`, or a plan tour via
`mentor:plan-touring`, on request) → approve & release →
subagents-first implementation (dispatch-agents).

While this worktree's `.planning.<wt-id>` marker is armed — or the legacy,
repo-global `.planning` marker, which blocks every worktree at once —
`plan-gate.sh` blocks every Write/Edit/MultiEdit/NotebookEdit inside the repo
working tree. The only files written during planning are the plan and its
opt-in zoom artifacts, all inside the gate-exempt `.mentor/` tree. Do not run
repo-mutating shell commands during planning either; Bash is not enforced,
but the rule is the same.

## Step 0 — Mode & constitution {#mode}

**First, confirm the edit gate is actually armed for THIS worktree.** This skill is
the body of the `/mentor:plan` command, which runs `begin-plan.sh` before invoking
it. If you were loaded some other way — most likely a conversational "help me plan
this" — that never ran:

```bash
case "$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" dir)" in
  */.mentor)
    [ "$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" gate)" = "ARMED" ] || echo "GATE: NOT ARMED"
    ;;
esac
```

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

No output means the gate is armed for this worktree, or you are outside a repo
where there is nothing to protect. Either way, continue.

`begin-plan.sh` printed a `MODE:` line. The mode is only the **approval-gate
default** — it decides which option Step 6 lists first; both outcomes are
always offered there, and you never ask the user to pick a mode upfront:

- **`MODE: plan-only`** — list **"Deliver plan only"** first at Step 6.
- **`MODE: plan`**, **`MODE: UNSET (default: plan)`**, or no `MODE:` line at
  all (not in a git repo, so there was nothing to arm — distinct from the
  unarmed-inside-a-repo case the check above catches) — list **"Proceed"** first.

`begin-plan.sh` may also print a **`CONTEXT:`** line (the context gate):

- **`CONTEXT: WARN`** — the session is getting large. Surface it to the user and use
  the WARN row of Step 6's option set (it leads with **"Hand off to next agent"**).
  Nothing about *how* you plan changes.
- **`CONTEXT: HANDOFF`** — critically large, and the user already chose to proceed
  (gate bypassed). Everything WARN does, plus: do not propose a zoom or plan tour
  (Step 5) or plan-review yourself — an explicit user ask for any of these is still
  honored — and use the HANDOFF row at Step 6. "Keep the plan lean", if the command
  layer said it, means exactly those omissions: Step 4's content spec never shrinks.
- **`CONTEXT: ASK`** never reaches this skill — the command layer resolves it with the
  user first; noted for completeness.

**Load the constitution.** Resolve the constitution path (a repo may keep its
governing doc outside `.mentor/` — `constitution_path` in `.mentor/config.json`
points at it; see `/mentor:constitution`'s adopt-by-reference branch):

```bash
# via the shared subcommand, not --show-toplevel: a linked worktree must resolve to
# the MAIN repo's .mentor, where the constitution actually lives
mentor_dir="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" dir)"
[ -n "$mentor_dir" ] || { echo "ERROR: mentor dir unresolved — is CLAUDE_PLUGIN_ROOT set?" >&2; exit 1; }
repo_root="${mentor_dir%/.mentor}"
const_rel="$(jq -r '.constitution_path // empty' "$mentor_dir/config.json" 2>/dev/null)"
const_path="${repo_root}/${const_rel:-.mentor/constitution.md}"
```

If the resolved file exists, `Read` it now — its principles are governing rules
for this repo. Keep them in mind through research and design, and prove
compliance in the plan's **Constitution Check** section (Step 4). If it is
absent but `docs/constitution.md` or `CONSTITUTION.md` exists at the repo root,
surface that once: the repo appears to have a governing doc mentor is not
reading — suggest `/mentor:constitution` to adopt it by reference. Otherwise no
constitution governs this repo; skip the Constitution Check (you may mention
`/mentor:constitution` once if the user seems to want project-wide rules).

## Step 1 — Clarify (optional) {#clarify}

If the request is ambiguous — unclear scope, multiple plausible interpretations,
missing acceptance criteria — invoke `Skill(skill="mentor:grilling")` before
designing anything. Skip this for well-specified tasks.

## Step 2 — Research (delegation suggested, not enforced) {#research}

For multi-area or unfamiliar tasks, prefer dispatching **1–3 read-only `Explore`
agents** over disjoint areas — issue every `Agent()` call for the batch in a
**single message** (N `tool_use` blocks side by side), not one call per message
waiting for each dispatch's tool_result before writing the next. Serializing the
dispatch buys nothing — the agents run async once out either way — and spends a
full main-thread round trip per agent. This keeps the main conversation lean. The strongest signal is an unfamiliar external
platform (an integration, SDK, or cloud service this session has not already
researched) **together with** 2+ pre-existing areas of the repo: each half alone
looks manageable inline, and the pair is what actually exhausts a context
window. For small, well-scoped tasks, read the files and draft directly in the
main thread. Nothing enforces delegation; use judgment.
**Load the dispatch contract before the first `Agent()` call, not after.** Research
dispatches follow `dispatch-agents`' "Async runtime & lifecycle" rules, and this step
fires before that skill's own first load point (Step 4) — so invoke
`Skill(skill="mentor:dispatch-agents")` here if it is not already loaded, then end
every research prompt with its **"Deliver before idling"** block pasted verbatim,
after the return contract below. Loading it here is for that block and the
**Standing no-subagents policy** check alone: the annotation grammar is Step 4's,
the execution rules are Step 6's, and the edit gate stays closed. Citing the rules
in a paraphrase is not a substitute — it drops
directives the agent has no other way to learn, the no-nested-fan-out ban above all.
One nudge on a silent idle; close each agent out once its findings are consumed.

**Research the category, not just the named instance.** When the request names
one instance of something the repo may have several of — one job to make
continuous, one config to centralize, one surface to consolidate — search for
its siblings before drafting, and carry each hit into Step 3.5 as a scope
decision. A sibling found at the approval gate rewrites the plan; the same
sibling found here costs one question.

**When the request corrects a bad state, also find what regenerates it.** A
migration or cleanup that only fixes the data leaves whatever produced it free
to reproduce the same defect on the next run — a script, an importer, a cron
job, a form handler, or a skill/rule that doesn't validate before writing are
all candidates. Search for that producer before drafting, and carry what you
find into Step 3.5 as a scope decision, the same way a sibling instance is
above.

**A same-session restart — or an earlier grill — is not a blank page.** When
the user interrupts mid-research to broaden or redirect the request and
re-invokes `/mentor:plan`, or when a `grilling` phase (via `/mentor:grill`
directly, or Step 1's own route into it) already ran earlier in this session,
check the conversation for research FINDINGS already delivered on the same
subject before dispatching a fresh round — a broadened scope usually extends
prior findings rather than replacing them, and a prior grill's dispatched
agent may have already covered the same ground, so re-running agents over
territory already covered wastes a full research fan-out on overlap the
transcript already has the answer to. Dispatch new agents only for the
ground the broadened request — or the grill's own research — genuinely
didn't cover.

**`.mentor/` is gitignored — a plain `grep -r` can miss it, even aimed straight at the
dir.** `hooks/lib/state.sh` writes `.mentor/.gitignore` as `*` + negations (only
`.gitignore`/`config.json`/`constitution.md` are un-ignored), so a gitignore-aware search
returns a clean "no hits" for a standing instruction — a "no subagents" policy, an earlier
decision — recorded in a prior handoff note under `.mentor/plans/*/handoffs/`, whether the
search scans the whole repo or `.mentor/` alone. A bare relative path is also wrong in a
linked worktree, which shares the MAIN repo's `.mentor/` (Step 0's `--git-common-dir`
note) rather than having its own. Resolve the real path first, worktree-safe, then bypass
gitignore:
```bash
d="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" dir --plans)"
[ -n "$d" ] || { echo "ERROR: mentor plans dir unresolved — is CLAUDE_PLUGIN_ROOT set?" >&2; exit 1; }
grep -rn --no-ignore "<pattern>" "$d"   # or: rg --no-ignore "<pattern>" "$d"
```

**Verify literal CLI commands, and claims about a live system's current state, before
drafting them into the plan.** A deploy/release-shaped step that types an exact command
from memory or a runbook paraphrase gets its first real syntax check from a plan
reviewer — one fold cycle away from running verbatim against a live system. Before
writing a literal command into such a step, verify it (`--help`, `--dry-run`, or the
tool's own docs) rather than transcribing it as fact. The same applies to claims about
the deploy target's current state (backups exist, a version is what you think it is,
a rollback path works): verify it this session, or write it exactly as `handoff-note`'s
external-state rule does — conditional on a named, mandatory verification command, with
the fact stated as unverified rather than asserted. A step with no captured pre-change
state has no rollback anchor either way.

**A fast-moving vendor/product/SDK topic goes to the reference skill before it goes to
memory.** When a research topic names an external platform, SDK, or cloud service that a
skill already available this session covers — the session's skill list, not a filesystem
hunt — name that skill in the dispatched agent's prompt and tell it to load the skill
before answering; the agent inherits no context of yours, and recall from training data
is where such topics go stale first. Whenever the name could mean more than one product
or API from the same vendor, require FINDINGS to say which one it describes — a silent
pick surfaces only downstream, after it has already shaped a user question.

**Research return contract — put this in every research agent's prompt.** Each
agent returns, and nothing more:

- **FINDINGS** — conclusions only, ≤ ~400 words.
- **EVIDENCE** — `file:line` references only. No file dumps, no pasted source blocks.
- **OPEN QUESTIONS** — anything blocking, as a short list. (These feed
  Step 3.5's triage — they are never silently dropped.)

For a large plan you may additionally dispatch one `Plan` agent to author the
plan body — but only AFTER Step 3.5 has resolved the open decisions: hand it
the distilled research, the resolved decisions, and the content spec below
(Step 4); its return is the plan body you persist. For most plans, author it
yourself.

Before dispatching research agents, do a quick pass of Step 3's domain registry.
If a domain matched, fold that domain skill's research directives into the
research prompts before drafting them. If none matched, run the dynamic
fallback now — `plan-domain-dynamic`'s domain-definer dispatch must complete
before research agents go out, not after; running research first makes its
"before Step 2" mandate unsatisfiable.

## Step 3 — Domain routing {#domains}

Scan the task against the registry, refine after research FINDINGS return, then
re-scan the **drafted plan body** before every Step 4 write — the first draft and each
revision this loop writes. Routing off the request alone misses what a plan only grows
later: a schema section arriving at revision 3 needs backend-api's deliverable as much
as one present from the start. (Bodies rewritten inside `plan-review` or authored by
`plan-split` belong to those skills, not this loop.)

For each matched domain, invoke its planning skill **exactly once** via
`Skill(skill="…")`. Multiple domains may match; if none match, invoke the dynamic
fallback — when a registered domain matches later, `plan-domain-dynamic` owns what
supersedes what.

**Substituting an already-available skill.** No registered domain matched, but a
non-`mentor` skill already available this session — the session's skill list, not a
filesystem hunt — names this task's technology or surface in its description? Invoke
it once instead of the dynamic fallback, for its directives only: never its build,
copy, scaffold, or live-verify steps. Still produce the dynamic row's deliverable —
the `## Domain best practices applied` practice→step table — captioned
`source: <skill>`. If it covers only part of the task, run the dynamic fallback for
the rest. A registered domain matching on a later re-scan supersedes it, as it would
the dynamic brief.

A domain matching **after** research has nothing left to fold its research directives
into, and its deliverable rests on the evidence those directives gather —
backend-api's affected-callers column, say. Filled from recall it only looks
researched, so run the directives first (a targeted `Explore`, or directly per the
domain skill's own "researching directly" clause), then fold the deliverable.

| Domain | Trigger signals | Skill to invoke | Extra plan deliverable |
|---|---|---|---|
| frontend | UX/UI — components, pages, styles, layout, design systems, theming, responsive; also a message/notification surface rendered by a THIRD-PARTY client (chat embed, push notification, email chrome) | `Skill(skill="mentor:plan-domain-frontend")` | ASCII wireframes + delta/token tables (or a payload-shape table for a platform-rendered surface); live mockups only in an HTML zoom combo (`mentor:zooming`, Step 5) |
| backend-api | API/endpoint/route/handler/schema/DTO/contract — or the data model behind it, in ANY storage shape: a migration, table, column, index, constraint, enum, RLS policy (SQL) — or the equivalent entity/relationship change in a config file, CSV, spreadsheet-backed store, or ORM model; also the async edge — queue, topic, subscription, cron/scheduled job — its message contract and delivery semantics (retry, visibility timeout, idempotency, DLQ) | `Skill(skill="mentor:plan-domain-backend-api")` | Before/after contract diff tables + schema diffs + Mermaid sequence flow; on a DDL-or-equivalent change also a per-column delta table + Mermaid ER diff of the changed entities |
| architecture (C4) | Structural change — new/changed/removed service, container, datastore, queue, external integration, component, or data flow (NOT pure content/config/doc/style/refactor) | `Skill(skill="mentor:plan-domain-architecture")` | Diff-highlighted C4-style Mermaid flowcharts, only the levels that change |
| dynamic (fallback) | no registered domain matched — and no available skill substitutes (above) | `Skill(skill="mentor:plan-domain-dynamic")` | Domain best-practices section (practice→step mapping) |

**Rows are not mutually exclusive — keep scanning past the first match.** A plan that
restructures an existing datastore's tables is a common case where two rows both fire:
`architecture` for the datastore/component boundary the change draws or redraws, and
`backend-api` for the schema itself — the row that actually produces the per-column
delta table and Mermaid ER diff. Stopping at the first clear hit ships a plan with only
the structural view and none of the schema-level one, exactly where a reviewer needs it.

Each matched domain skill returns directives you fold into the research prompts
and the plan body.

## Step 3.5 — Resolve open questions & decisions (one at a time) {#decisions}

Before writing the plan, drain every open question so the plan encodes
decisions, not question marks. Collect them from all sources: the research
agents' **OPEN QUESTIONS** returns (Step 2), directives from matched domain
skills (Step 3), and any design fork you noticed yourself (approach A vs B,
scope boundary, acceptance criteria, naming).

Triage each item into exactly one bucket:

- **Codebase-answerable** — the code, config, git history, or docs can settle
  it. Answer it yourself (dispatch a read-only `Explore` agent, or read
  directly for a quick check); never ask the user what the repo can answer.
  (Explore dispatches carry the same contract as Step 2's research agents: load
  `Skill(skill="mentor:dispatch-agents")` if it is not already loaded, and end each
  prompt with its **"Deliver before idling"** block pasted verbatim — a triage
  Explore that idles without delivering strands the very question it was sent to
  settle, and the loop cannot move on without it.)
- **User decision** — preference, product direction, scope, priorities, a
  trade-off with no objectively right answer. Queue it for the user.
- **Immaterial** — the plan comes out the same whichever way it lands. Drop
  it, or record it as a flagged assumption in the plan.

**Mid-loop scope change.** A scope-change request (not a decision *answer* —
a change to what the plan covers) pauses the per-item loop: confirm the scope
delta itself — what's kept, what's cut — in one `AskUserQuestion` before
resuming. A derived boundary question asked in its place resolves nothing,
because the boundary it assumes was never agreed.

Resolve the queued user decisions via `AskUserQuestion` — **one call, one
question, one decision at a time**. Batching decisions into one call produces
rushed, lower-quality answers. Order by dependency: resolve the decision other
decisions hang off first, and let each answer narrow the next question.

**Every question ships with decision support, and stands on its own** — the
user answers from the question screen alone, never sent to a file, a plan
section, a coined id or code (`G14`, `P2`), or an earlier turn to learn what
the question means. A word the user could read as themselves — "user" above
all — never names a domain entity; when a reviewer finding or a research
return used it that way (a caller, a row, a consumer), rename it before the
question reaches the screen. Name things in plain language, quote the
evidence that decides it rather than citing where it lives, and say in each
option what it changes and what it costs:

- In the message text **before** the tool call, give a compact decision brief:
  what the decision is, why it matters to this plan, and the relevant evidence
  from research (observed behavior, constraints, and the code itself — quote
  the line that decides it and put its `file:line` beside the quote, so the
  address is a courtesy for the curious rather than homework for the answer).
  When the decision turns on what is actually in a data or config artifact,
  read the artifact — a research summary's or the plan's own description of
  it is not the evidence. Enumerate the rows a rule applies to, not just the
  rule.
- `AskUserQuestion` needs 2–4 options per question. For open-ended decisions
  (naming, free-form scope), synthesize 2–4 concrete candidates from the
  research — the tool adds a free-text "Other" automatically, so a candidate
  list never traps the user. Only when you truly cannot form two sensible
  candidates, ask in plain prose instead.
- Put your **recommended option first** with "(Recommended)" appended to its
  label (a convention for decision questions like these — fixed workflow gates
  such as Step 6's approval order by position alone), and make each option's
  `description` carry its concrete consequence or trade-off — not a
  restatement of the label. The recommendation itself must be the most
  practical and clean solution — never trade maintainability or reliability
  for implementation speed.
- When options are competing shapes (schemas, layouts, flows, wording), use
  the `preview` field so the user compares them side by side — but keep it to
  a short literal fragment of the thing being chosen between (the actual
  snippet, schema, or wording; roughly ≤10 lines), never a framed mockup.
  Box-drawing glyphs and non-ASCII text (Thai, CJK, …) each expand to a
  6-byte `\uXXXX` escape inside the tool call's JSON, so a mockup that looks
  small on screen can truncate the call mid-string and fail validation —
  costing a whole turn to retry. **If the comparison needs a frame, a grid,
  or aligned columns to be legible, it is not a `preview`**: say so in the
  decision brief and offer an HTML zoom (Step 5 / `mentor:zooming`) instead —
  the user asking is the opt-in that step requires.

Each answer becomes a plan input. An "Other" answer may open new questions —
triage those through the same buckets. If the user explicitly defers a
decision, record the deferral in the plan (as a flagged assumption or under
Out of scope) rather than silently choosing for them. A rejected or
interrupted question is neither an answer nor a deferral — when the
clarification lands, re-issue the question; a recommendation given in prose
does not resolve a decision, and an unresolved decision that is never
re-asked is the shape a stalled plan takes.

**Skip condition:** no open questions survived triage → proceed straight to
Step 4. Never manufacture questions to fill the step — a well-specified task
with clean research needs zero.

This step resolves *post-research* decisions with evidence in hand; Step 1's
grilling handles *pre-research* ambiguity in the request itself. An earlier
grill session does not skip this step — research may have surfaced new forks —
but a decision already resolved anywhere in the conversation is never
re-asked.

## Step 4 — Write the Markdown plan {#write-the-plan}

**Check for a topic-adjacent existing plan before minting a slug** — a re-typed
request derives a fresh slug with no memory of an earlier attempt on the same
topic, and `ensure-dir` below will happily create a second directory beside it,
orphaning whichever one doesn't get worked on next:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" list --owners
```

This is a quick scan, not a fuzzy-match algorithm: only act on a genuinely obvious
naming match — when in doubt, mint fresh, since a false reuse is worse than an
extra plan dir. If one plainly names the same topic, reuse that slug for
`plan_dir` below instead of minting a new one, and read its
`.mentor/plans/<slug>/.state.json` `note` field (`jq -r .note`) for any prior
decision or rejection worth carrying forward. **Never reuse a slug the OWNER
column shows as owned by a different worktree** — that is another worktree's live
or recent draft, not yours to continue; mint a fresh slug instead, the same call
you'd make if nothing plainly matched. Reuse is safe only for a slug this
worktree already owns, or one the OWNER column shows unowned (`-`).

Compute the path (substituting a kebab-case `<slug>` derived from the request —
≤30 chars, drop articles, keep nouns/verbs):

```bash
slug="<slug>"
plans_dir="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" dir --plans)"   # worktree-safe
[ -n "$plans_dir" ] || { echo "ERROR: mentor plans dir unresolved — is CLAUDE_PLUGIN_ROOT set?" >&2; exit 1; }
plan_dir="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" ensure-dir "$plans_dir/$slug")" || exit 1   # creates it AND locks the path to 700
echo "${plan_dir}/plan.md"   # fixed name inside the slug dir, NO timestamp — stable across revisions
```

`ensure-dir` stamps THIS worktree as the new dir's `owner` the moment it mints it —
ownership starts here, not at `init` below.

Write the plan there with the `Write` tool, then register it so mentor can track what
becomes of it:

```bash
slug="<slug>"   # re-derive: the block above was a separate Bash call; an empty slug registers nothing
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" init "$slug"
```

That records the plan as `draft` in a hidden `.state.json` beside it, and re-stamps
`owner` to THIS worktree too — last-init-wins, so running `init` on a slug another
worktree minted re-owns it to you (this is also the mechanism `mentor:resuming`
relies on to re-own a plan being continued in a different worktree). Approval, and
later `/mentor:track`, read that state to know which plans are built and which are
pending. It is idempotent, so re-running it on a revision is harmless.

**Fleshing out a deferred stub.** If `$slug` names an existing stub born via
`/mentor:defer` — you arrived here because `/mentor:track` routed a stub pick to this
skill, or the user pointed you at one directly — run `claim` right after `init` so the
stub stops being shielded from `approve-plan.sh`'s promotion sweep:

```bash
slug="<slug>"   # re-derive: separate Bash call again (see `init` above)
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" claim "$slug"
```

`claim` clears the sidecar's `origin` field; it is a harmless no-op (with a one-line
notice) when there was nothing to clear, so it costs nothing to run whenever this
plan slug could plausibly be a stub you are now fleshing out. A brand-new plan with no
prior stub never needs this line.

The path is inside the gate-exempt
`.mentor/` tree, so the edit gate allows it; `plan-open.sh` auto-opens it for review the first time
(VSCode tab when available — toggle preview with ⇧⌘V; opener configurable via
`MENTOR_PLAN_OPENER`, disable with `MENTOR_PLAN_OPEN=off`, both under `env` in
`~/.claude/settings.json`). **Keep it current:** on every revision re-write this
SAME file in place — never create a second timestamped copy. Never write the
plan anywhere else in the repo or to the harness-native `~/.claude/plans/` dir.
Before each re-write, re-run Step 3's registry scan against the new body — that is
where a domain the plan only just grew gets caught.

**Verify the write:** when a revision applies a sequence of `Edit`s rather
than one whole-block rewrite, re-`grep -n` each edit's target text against
the file's current on-disk state immediately before applying it — an earlier
edit in the same pass can shift nearby text out from under a stale anchor,
and a miss usually means it already moved. An `Edit` whose anchor lands
mid-table or mid-fence can also splice a row or split a fenced block without
erroring — nothing else in this skill catches it, and a revision built from
many small edits (a fold pass, a decision resolution, a split) is exactly
when this happens. After such a revision, run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" verify <slug>
```

before moving on — one call for fence balance and table pipe-count
uniformity (a session was observed hand-rebuilding a different grep/awk
one-liner for this on 5 consecutive revisions, never the same check twice,
and the one revision that dropped the table half is exactly where a
table-adjacent defect landed). A non-zero exit means a fence or a table
broke — fix it before moving on. Its `CHECK: Rev-note order` and
`CHECK: context` lines are informational only and never fail the call; the
latter is the same reading "Re-check context" below asks for, so if nothing
else ran between this call and the approval ask, that reading already
satisfies it — no second `context` call needed. Prefer replacing a whole
table/fenced block in one edit over splicing a single row into it.

### Content spec

The `.md` file is the canonical plan — self-contained, portable, renders richly
on GitHub/GitLab and any Mermaid-capable viewer. No inline HTML/CSS/SVG.

Required sections, in order:

1. `# <Plan title>`
2. `## Context` — the problem, what prompted it, intended outcome.
3. `## Use case scenarios` — actors & triggers; current vs expected behavior;
   numbered concrete scenario walkthroughs (real values from research, not
   placeholders); edge cases & assumptions (flag anything unverified). Give this
   section visualization treatment — a Mermaid flowchart/sequenceDiagram of
   actor→trigger→outcome, or a current-vs-expected GFM table — so the reviewer
   can verify your understanding at a glance.
4. `## Approach` — the recommended design — the most practical and clean
   solution for the requirement, never trading maintainability or reliability
   for implementation speed — with one visualization per significant
   change/decision realized inline under its owning topic.
5. `## Constitution Check` — **include only when the constitution resolved in
   Step 0 exists** (default `.mentor/constitution.md`, or the file
   `constitution_path` points at). A GFM table with one row per principle: `Principle | Verdict | Notes`,
   verdict = ✅ complies / ⚠️ deviates / ➖ N/A. For every ⚠️, the Notes cell must
   either point at the plan change that resolves it or record an explicit,
   justified deviation. If a principle can only be honored by amending the
   constitution, say so and stop short of encoding the violation as the plan.
   A ✅/➖ verdict that rests on a repo search finding nothing names the
   gitignore-bypassed command it ran (Step 2's caveat) — a verdict resting on an
   unqualified `grep -r` is not yet earned.
6. `## Implementation steps` — numbered, concrete, and **dispatch-annotated by
   default** (subagents-driven development: the main thread orchestrates,
   subagents implement — each agent gets one narrow, focused step, and the
   main context stays lean). Before writing this section, invoke
   `Skill(skill="mentor:dispatch-agents")` (skip the re-invocation if Step 2 already
   loaded it) and annotate every implementation
   step per its grammar (`[role: … · model: … · effort: …]`, grouped
   `Run in parallel:` / `Sequential:`) — one plan step = one dispatch.
   **Escape hatch:** when the implementation meets the dispatch-agents skill's
   skip rule, omit the annotations, but the section MUST then open with one
   line: `Dispatch: skipped — <reason>`. No line, no skip.
   **Size each step as you write it:** run every step past the dispatch-agents
   rubric's **"Budget each step to one agent's context"** item — a dispatched
   agent never compacts, so an oversized step burns its context on reconnaissance
   and re-proof rather than the change. Its five smells are all checkable here;
   a step showing any of them splits into sequential steps, one dispatch each,
   handing off by report. If that pushes the count past ~12, that is the
   oversize threshold below doing its job, not a reason to re-merge.
   **Keep it small while you write:** if the step count creeps past ~12 while
   drafting this section — Step 6's oversize threshold below, just reached early —
   pause and offer to defer non-core **isolated deliverables** — a plan's `## Verification`
   section is never a deferrable chunk, since a deferred stub captures work to build, never a check to run —
   via `Skill(skill="mentor:deferring")` before finishing the write, rather than waiting for
   the Step 6 gate to catch an already-oversized plan. A plan that arrives at Step 6
   already trimmed rarely needs the full split treatment.
   **Never title a step "Verification pass," "Testing," or similar** — that name
   belongs to the plan's own `## Verification` section below, and a step that reads
   as satisfying it invites skipping that section's mandatory per-topic dispatch at
   execution time. Name the step for what it builds or fixes instead.
   **A literal command written into a step here, on a live or shared system, must already
   be verified** per Step 2's directive — not transcribed from memory as you draft.
   **A `git diff`/`git log` written against a pathspec needs `--` before the path**
   (`git log <range> -- <path>`) — once `--` is present, git parses everything to its left
   as a revision, so a path left of it fails `fatal: bad revision`/`ambiguous argument`
   instead of running; a bare path with no `--` at all happens to work today only because
   nothing on disk currently collides with a revision name, which is exactly the kind of
   verification-time truth that stops being true later. Put `--` in front of every path
   from the start. This applies to a command anywhere in the plan that reads as git history
   or a diff, including `## Verification` — and if the command is piped into something like
   `grep -c … || echo 0`, a real git failure and a genuine zero-match print the same
   output, so the fallback silently launders an error into a passing `Done when:`. Prefer
   checking the command's own exit status over papering over it with `|| echo 0`.
7. `## Critical files` — cite a file this repo's own tooling edits
   automatically by **section heading**, never a line number: a stale line
   reads as confirmed instead of wrong. This applies anywhere in the plan
   that cites such a file, not just here — `## Implementation steps` and
   `## Verification` included.
8. `## Out of scope` — name every carve-out so the reviewer sees the
   boundary, but give one a **plan number or slug** only when it resolves on
   disk (a `/plan-split` sibling, or a `/mentor:defer` stub for work the user
   actually asked for); an invented `feature 0NN` reads as a roadmap promise
   `/mentor:track` cannot see.
9. `## Verification` — 2–6 single-focus topics, each in this shape:

   ```
   Topic N — <short title>
     Focus: <the single question this topic answers>
     Checks: <concrete commands to run / evidence to gather>
     Pass when: <observable criteria>
   ```

   Each topic runs post-implementation as its own **freshly dispatched
   verifier agent carrying exactly that one topic**: the main thread never
   grades its own session's work (it knows what it *meant* to do, so it
   confirms rather than checks), and one agent never carries two topics (a gap
   in one hides behind a pass in the other). `Topic N —`, never `Step N —` or
   a bare numbered item, keeps mentor's step counter from mistaking a
   verification topic for an implementation step. An optional annotation —
   `Topic N — <title>  [model: <sonnet|opus> · effort: <low|medium|high>]` —
   declares a judgment-heavy topic at authoring time, so the model upgrade is
   a reviewable decision rather than an execution-time guess; without it,
   execution defaults to `sonnet · medium`.

   **This section owns live end-to-end proof.** When a behavior can only be shown
   by driving a running multi-service stack, write that check as a topic here, not
   into a step's `Done when:` — dispatch-agents' **"State done-when"** rubric item
   keeps those to bounded commands (build, typecheck, unit, targeted integration).
   In both places, it is proved twice: by the implementer, in the session's most
   expensive context, and again by the fresh verifier this section dispatches.

**Confirm every matched domain's deliverable actually landed.** If Step 3 matched one
or more domains, check before finishing this revision that each one's *Extra plan
deliverable* — the routing table's rightmost column, with the domain skill's own
deliverable section as the authority on where it goes — is visibly in the body, its own
`##` section or nested under the owning `## Approach` topic per that skill, and not
merely implied by the research that fed it. Where it legitimately degrades to nothing on
this surface, write the degrade line that skill sanctions (frontend's one-line "no visual
change" note): silence is not a degrade path. A domain that fired and left nothing
visible is a silent gap — `plan-review`'s reviewers never learn which domains matched,
so nothing downstream can catch it.

**Visualization decision rule (pick exactly ONE idiom per artifact):**

- Tabular data (field lists, diffs, matrices, before/after values) → **GFM table**.
- Topology / sequence / state (flows, state machines, ER, dependencies) →
  **Mermaid** fenced block.
- Spatial/layout fidelity (UI zone wireframes, fixed-width alignment) →
  **ASCII diagram in a code fence**.
- Callouts / cautions → **GFM alert** (`> [!NOTE]`, `> [!WARNING]`, …).
- Literal code / payloads → fenced code with a language tag.

**State vocabulary rule.** When a plan introduces, renames, or re-scopes a named
status for any entity (`MONITORING → PENDING`, `ACTIVE → TRIGGERED/CANCELLED`),
or changes which transitions are legal between statuses that already exist —
a new cascade side-effect where reaching one terminal status now forces
another, say — render the *transitions*, not just the values. A status name
staying put says nothing about its edges staying put. The `stateDiagram-v2`
the idiom rule already selects shows the shape — which states reach which,
added and removed edges marked; a companion
`From · Event/verb · To · Trigger · Cascade` table carries what a shape
cannot encode, and it is the table that exposes a
**missing** edge, since reverse transitions and cascade side-effects are the
ones that surface late. That pairing is complementary, not the same-thing-twice
the rule below forbids. Skip it when no entity has more than one named state, or
when the states are unchanged and only their storage moves — that delta is
`plan-domain-backend-api`'s per-column table, and restating it here would
duplicate.

**Workspace layout rule.** When a plan introduces on-disk structure the reader cannot see
today — a new state/workspace directory, a sidecar or companion file, a naming scheme other
paths are derived from — render the layout as an **ASCII tree in a code fence** (the idiom
rule's spatial row), with a one-line note per new path saying what writes it. Prose naming
three paths reads as complete until someone has to create them in the right order; the tree
is what makes a missing one visible. Skip it when the change only touches paths that already
exist.

**Anti-duplication:** never restate in prose what a diagram already shows, and
never show the same thing two ways. Prose next to a diagram is limited to a
one-line caption, a legend, and the why/insight the diagram cannot encode.

**Mermaid portability rules:** do NOT set `theme`/`themeVariables`/`%%{init}%%`
(GitHub/GitLab apply their own); do NOT use `C4Context`/`C4Container` (use
`flowchart TB` + `subgraph` + `classDef` instead); keep each diagram small —
split dense flows into 2–3 focused diagrams; a `;` inside `Note over …: text`
truncates the note — use `,` or `+`.

**Generalist-reviewer principle:** write for a generalist, not a domain expert —
define jargon at first use, state why each step matters, prefer concrete
examples. The plan must be approvable by someone outside the domain.

**Verify headline counts before the first write.** Step 3.5's evidence rule —
read the artifact itself, a summary is not the evidence — applies to every
count the plan states about its own scope, not just the decisions that reach a
question: an orphan count, an affected-row count, a terminal-state count.
Re-derive each one from the real data source when you draft it, rather than
carrying a number forward from research recall. A wrong headline count caught
here costs nothing; the same number caught later, once a reviewer's own count
check flags it, costs a multi-section sweep to fix everywhere it was restated.

## Step 5 — Optional HTML zoom & plan tour (explicit user opt-in only) {#html-zoom}

The topic × perspective HTML zoom is its own skill — `zoom` — and this step is
pure delegation. Only when the **user asks** for an HTML zoom / visual preview
— never by default — invoke `Skill(skill="mentor:zooming")` and follow it end to
end with the plan as the subject:

- **Subject = the current plan** (`${plan_dir}/plan.md`), so per the zoom
  skill's plan-slug contract its artifacts land in
  `.mentor/zooms/<plan-slug>/<topic>-<perspective>.html`.
- Candidate **topics** derive from the plan itself — its `## Approach`
  subsections, `Proposed UI changes per surface` entries, or
  implementation-step groupings.
- The constitution path resolved at Step 0 is the one the zoom skill's
  Reviewer/Architect combos consume.

EVERY zoom ask re-enters the zoom skill's contract (its sticky re-entry rule)
— the first one, the Nth one, a free-text follow-up ("update the review
artifact", "add a zoom for X"), a mid-revision regeneration, at any point in
the plan lifecycle.

**Revision completeness.** When a plan revision or a product decision
invalidates prior zooms, re-enter `mentor:zooming` and follow its re-zoom rule
(grep the invalidated term across `.mentor/zooms/<plan-slug>/*.html` and
re-dispatch EVERY matching combo in one batched message). Wait for those
agents to complete before dispatching `plan-review`, so a reviewer never reads
a zoom mid-write.

**Plan tour.** Only when the user asks for a walkthrough or tour of *how the
plan will execute* — never by default — invoke `Skill(skill="mentor:plan-touring")`
with the current plan as the subject; its artifacts land in
`.mentor/plans/<plan-slug>/tour/`.

## Step 6 — Approve & release {#approve}

> **🚫 No edits or implementation until the plan is APPROVED.** During planning,
> only read-only agents (Explore, Plan, plan-review reviewers) may be
> dispatched — the sole exceptions are `mentor:zooming`'s combo agents (Step 5),
> which write ONLY zoom artifacts under `.mentor/zooms/` (gate-exempt
> `.mentor/` tree), and `mentor:plan-touring`'s combo agents (Step 5), which
> write ONLY under `.mentor/plans/*/tour/` — never repo source files.
> Every editing/implementation agent comes AFTER approval.

**Close out consumed dispatches before asking.** Every agent this session
dispatched whose output is already folded into the plan — Step 2's research and
plan-body agents, Step 3.5's Explores, Step 5's zoom and tour combos, and the
reviewers or child-plan agents of a `plan-review` / `plan-split` pass that just
returned here — gets stopped now, per the **Close out** rule in `dispatch-agents`'
"Async runtime & lifecycle". This is the checkpoint where it costs the most: the
question below can sit unanswered for hours of real wall-clock time, and a
resident agent's idle notification landing mid-wait reads as new input and
silently rejects the pending question, stalling the session until a human
notices. Enumerate live tasks first, diff against this session's own dispatch
tree, and stop only what traces to it — a remembered name is not enough, even
when you're sure what's still resident (the same rule `dispatch-agents`'
"Async runtime & lifecycle" states unconditionally). (In Claude Code those are
`TaskList` and `TaskStop`, either of which may need fetching via `ToolSearch`.)

First **surface the complete plan body** in your message — plain markdown,
verbatim, no commentary around it — so the user can review it in the transcript.
If the plan is long, let them scroll; do not summarize instead. Then, in the
same turn, ask via `AskUserQuestion` — `header: "Approve"`, question *"The plan is
ready. What happens next?"* — with the option set the table below selects.
Mention in the question text that a change request — not just approval or
rejection — belongs in the always-present **Other** free text, so redirecting
the plan doesn't have to arrive as a hard reject.

**Only a returned answer approves.** If the approval question was interrupted,
rejected, or never came back — or the user asserts approval in prose ("the plan was
approved", "go ahead, I already okayed it") — ask it again before running
`approve-plan.sh`. Prose selects no option, and this question is the only thing
standing between planning and repo edits; releasing the gate on a remembered or
claimed approval is the one failure this harness exists to prevent. It also costs you
the routing: which flag to run — none, `--deliver`, `--handoff`, or **no script at
all** for "Pause — still drafting", the one option that does not approve — is decided
by *which option came back*, so an unanswered question means you are guessing the
outcome as well as the consent. Re-surface the plan body only if it changed since the user last
saw it (or never was surfaced); otherwise name its path and Rev and re-ask.

### Re-check context

Decide this **before** asking too. Step 0's `CONTEXT:` line is a snapshot from
before research, domain routing, and decision-resolution ran — precisely the
steps that grow a session — so a plan that armed clean can still reach this
question well past the WARN/HANDOFF thresholds with nothing in this skill
having said so. If "Verify the write" above just ran and nothing happened
between it and this ask, its `CHECK: context` line already **is** this
re-check — use that reading. Otherwise (no revision preceded this ask, or
other steps ran since `verify` was last called), re-run the same check now:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" context
```

Neither Step 0's line nor an earlier `context-gate.sh` WARN notice from
mid-session substitutes for this — both are readings from an earlier, smaller
context, and the row you pick below is decided by *the freshest command
output*, run right before this ask.

- **`CONTEXT: ASK`** — do not ask the approval question yet. Ask via
  `AskUserQuestion` (header "Context", two options) exactly as the command
  layer's arm-time ASK does: hand off & stop (`Skill(skill="mentor:handoff-note")`),
  or bypass (`bash "${CLAUDE_PLUGIN_ROOT}/hooks/bypass-context.sh"`, then
  continue below).
- **`CONTEXT: HANDOFF`** or **`CONTEXT: WARN`** — use the matching row below,
  even if Step 0 printed a lower tier or nothing at all.
- **`CONTEXT: OK` / `UNKNOWN`** — no verdict; the table's "neither"/oversized-only
  rows apply.

### Is the plan oversized?

Decide this **before** asking, because it changes which options you offer. The plan is
oversized when any of these holds:

- more than ~12 implementation steps, or
- it contains independent deliverables that could ship separately, or
- the user says it is too big.

**Suppressed when this plan already has a `group`** — it is itself a split child, and
re-slicing a slice usually means the first split drew its lines in the wrong place.
Typing `/plan-split` still works if the user insists.

When oversized, mention in the question text that non-core **isolated deliverables**
can instead be **deferred via `/mentor:defer`** rather than a full split — a lighter
alternative worth naming even though it isn't its own button; a plan's `## Verification`
section is never a deferrable chunk, since a deferred stub captures work to build, never a check to run.
The option table below is unchanged: the user reaches this by typing it into
`AskUserQuestion`'s always-present "Other" free text, not by picking a listed option.

### The option set

`AskUserQuestion` caps at 4, and the oversize and context conditions fire together
constantly — so the precedence is fixed here rather than left to judgment in the
moment:

| Condition | Options, in order | Yields to "Other" |
|---|---|---|
| neither | Proceed · Deliver plan only · Review the plan (staged) · Keep planning | — |
| `CONTEXT: WARN` only | Hand off to next agent · Pause — still drafting · Deliver plan only · Proceed | Review, Keep planning |
| `CONTEXT: HANDOFF` only | **Hand off to next agent (Recommended)** · Pause — still drafting · Deliver plan only · Proceed | Review, Keep planning |
| oversized only | **Split into multiple plans** · Proceed · Review the plan (staged) · Deliver plan only | Keep planning |
| oversized **and** `CONTEXT: WARN` | **Split into multiple plans** · Hand off to next agent · Deliver plan only · Proceed | Review, Keep planning, Pause |
| oversized **and** `CONTEXT: HANDOFF` | **Hand off to next agent (Recommended)** · Pause — still drafting · Deliver plan only · Proceed | Review, Keep planning, Split |

In the first row only, `MODE: plan-only` swaps the leading two so "Deliver plan only"
comes first. Anything yielded to "Other" stays reachable — the user can just say it.
Copy the matched row's option list into the `AskUserQuestion` call verbatim —
don't reconstruct it from memory this late in a long session, where a drifted
list can silently drop the one button (a `Pause`, a `Split`) the situation
actually calls for. Under `CONTEXT: HANDOFF`, also note in the question text
that the session is critically large.

**`/mentor:handoff` stays reachable in every row, including the ones that list no
handoff option.** It is a command, not an option: it writes a handoff note and never
calls `approve-plan.sh`, so it neither releases the gate nor needs the plan approved
first. A user who wants a fresh agent to continue before any context verdict fires can
type it into this question's always-present "Other" free text — the same route
`/mentor:defer` takes above — rather than rejecting the question, which returns no
answer and forces a re-ask. That covers the literal command; bare handoff *intent* in
free text is still governed by the routing rule below.

**Whenever both handoff options are listed, say in the question text which options
release the gate.** They differ only in consent — one approves, one does not — and a
label alone cannot carry that. A user who is out of room reads "hand off" and picks
the first match; if that silently approves, a fresh agent starts implementing a plan
they never approved, which is the one failure this harness exists to prevent. Naming
the consequence in the question costs a sentence and removes the guess.

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

| Label | Description |
|---|---|
| Proceed | Validate the plan, release the edit gate, and begin implementation. |
| Deliver plan only | Validate the plan and release the gate; the plan file is the deliverable — no implementation, no dispatch. (/mentor:handoff can brief a fresh agent afterwards.) |
| Review the plan (staged) | Run plan-review — a judgment pass (practicality, comprehensiveness) whose edits you verdict one question at a time, then a mechanical pass (cleanliness, consistency) whose safe fixes auto-fold and whose decision-level findings are asked one by one. Stays in planning; ends back at this question. |
| Keep planning | Do not release — keep refining, or say what to change. Re-write the plan file and ask again when ready. |
| Split into multiple plans | Slice this plan into independently buildable sibling plans, each with explicit scope isolation. Stays in planning; asks again afterwards. |
| Hand off to next agent | Approve and release, then write a handoff doc so a fresh agent implements it — this session is getting large. |
| Pause — still drafting | Write a handoff doc and stop **without approving**: the gate stays armed and the plan stays `draft`, so the next session continues *planning*, not implementing. For when the session is out of room but the plan is not settled. |

On **Proceed**, run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/approve-plan.sh"
```

It validates the plan (a non-empty `.md` newer than the marker it resolves — this
worktree's `.planning.<wt-id>`, or the legacy repo-global `.planning` when running
in legacy_mode), and on success deletes that marker — the gate OPENS for this
worktree (repo-wide, in legacy_mode). On failure it prints the problem, keeps the
gate closed, and exits non-zero: fix the plan (re-write per Step 4) and re-ask. On
success, implement the plan.

**Executing the implementation after approval (SDD):** implementation is
subagents-first. Invoke `Skill(skill="mentor:dispatch-agents")` first (skip the
re-invocation only if it is already loaded in this session), then follow its
"Executing the dispatches" section: read the approved plan file, dispatch each
`Run in parallel:` group's agents in ONE message (multiple `Agent` calls), run
`Sequential:` steps one at a time, verify each step's `Done when:` before
starting the next, and — once the last step passes — execute the plan's
`## Verification` section per that skill's "Verifying the plan (execution-time)"
rules. Mark each step done as it passes with `bash
"${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" tick <slug> <N>` — see
`mentor:dispatch-agents`' "Track progress in the plan file" for why the tick's
placement is load-bearing and what `tick` does about it. Keep a step's own body
on `-` bullets, though: the counter cannot tell a numbered sub-item from a step,
and an inflated denominator strands a finished plan at `in_progress` forever. Its
**No busy-wait** rule applies to every wait on this path, dispatched or not.
The main thread orchestrates and verifies each step's `Done when:` inline; it
does not re-do or re-read the work it delegated. The plan's end-to-end
`## Verification` is the one thing it never grades itself — that round is
dispatched, per the section named above. Only when the plan opens its
Implementation steps with `Dispatch: skipped — <reason>` does the main thread
implement directly.

**Record progress as plan state.** `approve-plan.sh` just marked this session's plans
`approved`. As implementation runs, move that forward so a later session — or
`/mentor:track` — knows what actually landed instead of re-reading the plan and
guessing:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" set <slug> in_progress            # execution starts
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" tick <slug> <N>                   # each step's Done when: passes
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" set <slug> implemented            # every Done when: + Verification PASS
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" set <slug> failed --note "<what broke>"   # escalating, or handing off with verification unresolved
```

`mentor:dispatch-agents` states this for the dispatch path; it is repeated here
because the **`Dispatch: skipped`** path never loads that skill for
implementation (it still loads it to dispatch verification), and direct
implementation must not be the one route that leaves no record. The ticks above
are also the only step tracker mentor reads here — don't mirror them into a
separate todo list as well; a second list costs a call per step and nothing
reads it (tracking *dispatched agents* themselves, e.g. for the closing
checklist's task sweep, is unrelated and still applies). Missing a transition
is survivable — state also derives from the `✅` step ticks you mark as each step
passes — but `failed` cannot be derived from ticks, so that one is worth remembering.

**Blocking failures get an escape hatch too.** When direct implementation hits
something that stops progress — a failing gate, an escalation only the user can
resolve — and you raise your own ad hoc `AskUserQuestion` about it, include
**Hand off to next agent** among the options. The user may want a fresh session
on this rather than resolving it inline right now, and nothing else on this path
offers that choice.

**Close out the skipped path too.** For the same reason, carry that skill's
CLOSING CHECKLIST items across yourself — there are no implementation agents to
release, but there is still work to hand back:

- **Offer `/mentor:tour`** — one line: a hands-on acceptance pass building an
  editable guided-tour review artifact (pass/not-pass scenarios) of what shipped.
  Do not auto-run it; it publishes to a stable URL, so the user chooses.
- **Sweep the report you're about to write** — every follow-up, gap, or
  known-broken item in it goes through `/mentor:defer` first, scoped to
  work to build, never a check to run: an unresolved verification topic
  or an unverified claim is never a stub — it's `set <slug> failed --note`
  on the plan; only a confirmed defect's fix still defers.

Skipping dispatch is a decision about *who types the edits*, not a discount on
what the user gets at the end. Implementation may be main-thread; verification
never is — the plan's `## Verification` topics are still dispatched to fresh
verifier agents, loading `Skill(skill="mentor:dispatch-agents")` for that if it
is not already loaded.

On **Deliver plan only**, run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/approve-plan.sh" --deliver
```

Same validation + release, then **follow the DELIVER-ONLY directive it prints** —
report where the plan lives and STOP. Do not implement and do not dispatch in
this session.

On **Hand off to next agent**, run:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/approve-plan.sh" --handoff
```

Same validation + release, then **follow the hand-off directive it prints** —
invoke the handoff skill for this approved plan and stop. Do not implement and
do not dispatch in this session.

An **"Other" answer expressing handoff intent** does *not* route here by default.
There are two handoff outcomes now and they differ on consent, so free text like
"let's hand this off" names the outcome without settling whether the plan is
approved — exactly the inference the rule above forbids. Route it only when the
answer also expresses approval ("looks good, hand it off"). Otherwise ask **one**
follow-up `AskUserQuestion`: approve and hand off, or hand off still drafting.

On **Pause — still drafting**, run **no script at all** — not
`approve-plan.sh`, not with any flag. The gate must stay armed and the plan must
stay `draft`; that is the whole point of the option, and every flag this skill
has approves. Instead invoke `Skill(skill="mentor:handoff-note")` with a focus
that states the planning is unfinished, then print its resume prompt and stop.

Give the handoff note these four facts explicitly, because the next agent cannot
infer them and each one has bitten a real session:

- **The plan is `draft` and the gate is deliberately still ARMED** — `mentor:resuming`
  tells the next agent to trust the marker over the note when they disagree, so an
  armed marker with no explanation reads like a crashed session rather than an
  intentional pause.
- **Name the ARMING WORKTREE** — this worktree's id and the repo path it maps to
  (the marker's own `worktree=` line, or `plan-state.sh gate --verbose`'s
  `owner_worktree=`). The marker is scoped to THIS worktree only: a session resuming
  from elsewhere finds no marker of its own at all (`gate` there reads `RELEASED` or
  `ARMED_ELSEWHERE`, never `ARMED`), and without this fact it cannot tell "nothing is
  armed" from "armed, but only over there — go there, or re-own here first."
- **Continue the *existing* plan** at `.mentor/plans/<slug>/plan.md` — reuse that slug.
  A fresh `/mentor:plan` derived from a re-typed request can mint a second plan dir and
  orphan this draft.
- **Re-write the plan file before approving it.** Whoever resumes runs `/mentor:plan`,
  which re-arms the marker with a *fresh* mtime, and `approve-plan.sh` refuses any
  `plan.md` older than the marker. Any real revision (a Rev bump) clears it; without
  this line the next approval fails with "Newest plan predates this planning session"
  and no hint of the cause.

On **Review the plan (staged)**, invoke `Skill(skill="mentor:plan-review")` and
prepend: *"The user selected 'Review the plan (staged)' — skip the Step 2 gate
and start Stage 1 directly."* If this option was reached via free-text "Other"
that explicitly asked for the mechanical/consistency check alone (not the full
staged review), prepend instead: *"The user explicitly asked for the
consistency check alone — skip the Step 2 gate and go straight to
Stage-2-only mode."* Either way its reviewers are read-only and the gate stays
closed; the skill itself folds the Stage 1 edits the user accepts at its
one-question-per-edit fold gate and auto-folds MECHANICAL Stage 2 findings
into the plan file (gate-exempt `.mentor/` writes), walks DECISION-REQUIRED
findings one verdict question at a time (applying only accepted resolutions),
then returns to this same question — this option never releases the gate by
itself.

On **Split into multiple plans**, invoke `Skill(skill="mentor:plan-split")`. It writes
only under `.mentor/plans/`, so the gate stays closed: it confirms a slice map,
dispatches one agent per child, retires the parent, and returns here. Then **re-ask
this same question** against the new sibling set — the oversize condition is now
false, so the option set comes from the table's first two rows. Say in the question
that **Proceed now approves the whole set** and routes building to `/mentor:track`;
otherwise the user is left guessing which child "Proceed" means, and the model is left
implementing whichever one it happens to remember.

On **Keep planning**, do not run the script; return to planning.

**Not in a git repo?** begin-plan reported the gate was NOT armed — skip
`approve-plan.sh` (it would fail outside a repo) and honor the user's choice
directly.

### Retracting an approval {#retract}

Sometimes an approval lands that the user did not intend — they pick an approving
option, then immediately say "no, that wasn't approved yet". Re-arming the gate is the
obvious half of the fix and the only half people remember, so state the rest here:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/begin-plan.sh"                                       # re-arm the gate
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" set <slug> draft --note "approval retracted"
```

**Confirm the re-arm actually took before telling the user it did.** `begin-plan.sh`
can now refuse outright — a live legacy repo-global `.planning` marker fail-closes
against every worktree, this one included:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" gate   # expect ARMED
```

Anything other than `ARMED` means `begin-plan.sh` printed a refusal above instead of
arming — read it and resolve that first (wait for the legacy marker's owning session,
or get the user's explicit authorization to remove it by hand). The plan is not
re-protected until `gate` reads exactly `ARMED`.

**Retracting from a different worktree than the one that drafted this plan needs
re-owning too.** The gate re-arms per-worktree regardless of who owns the plan, but
the plan's sidecar `owner` still points at whichever worktree last minted or `init`ed
it, and re-arming the gate here does not change that. Re-own it before the next
approval, the same as any cross-worktree resume:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" init <slug>   # re-owns to THIS worktree, last-init-wins
```

Skip this line only when you are certain this is the same worktree that drafted the
plan — `init` is otherwise harmless to run either way (idempotent, never lowers state).

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

The cleaner escape is not to need this: when the user is out of room but not ready to
approve, "Pause — still drafting" hands off with the gate still armed and nothing to
retract.
