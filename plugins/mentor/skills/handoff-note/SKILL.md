---
name: handoff-note
description: >
  Compact the current conversation into a handoff document so another agent can
  pick up the work in a fresh session. User-invoked via /mentor:handoff. Summarizes
  the conversation and progress, recommends which mentor commands the next agent
  should run, references existing artifacts (the plan file, PRDs, ADRs, issues,
  commits, diffs) by path/URL instead of duplicating them, and redacts secrets.
  Saved inside the plan-topic folder it belongs to — the repo's gitignored
  .mentor/plans/<topic>/handoffs/ dir — so the plan and its handoffs live
  together and `git status` stays clean. Writing a note supersedes the topic's
  older notes (stamped into resolved/), keeping exactly one live resume point
  per topic. Ends by printing a copy-paste resume prompt so the next session
  can continue instantly.
---

# Handoff — Compact the Session for the Next Agent

This skill turns the current conversation into a **self-contained handoff document** a fresh agent
can use to continue the work — without re-reading this entire session. The document is saved
**inside the plan-topic folder it belongs to** — the repo's gitignored
`.mentor/plans/<topic>/handoffs/` dir — so a plan and every handoff about it live together, and
nothing shows up in `git status`.

It is the bridge between two sessions: it captures *what happened*, *where things stand*, and
*what to do next* — pointing the next agent at the right mentor commands rather than restating
everything.

## When to use

- Ending a session with unfinished work you want to resume cleanly later.
- The context has grown large and you want a fresh start without losing the thread.
- Passing the work to a teammate, a scheduled/cloud agent, or a different machine.

## When NOT to use

- The work is finished and shipped — there is nothing to hand off.
- The next step is a single trivial action a one-line note already covers.

---

## Step 1 — Resolve the next-session focus

Before anything else, close out live background work the same way `dispatch-agents`'
"Async runtime & lifecycle" section requires at any other close-out point — dispatched
agents still live (`TaskList`/`TaskStop`, fetched via `ToolSearch` first if this session
hasn't loaded them) and any live `Monitor` watch (that section covers both; a watch has
no stop tool, so resolve it first or record its status and the check command in the
note). A handoff is the session's last exit: anything left resident here has no later
checkpoint in *this* session to catch it, and outlives the note as a stray, unmonitored
task.

`$ARGUMENTS` (the command argument) answers **"what will the next session be used for?"** Use it to
decide what the document emphasizes — the parts of the work relevant to that focus get the most
detail. If the argument is empty, write a general handoff covering the whole session.

**`$ARGUMENTS` sets emphasis, never scope.** It answers what the next session is *for*, not what
this skill produces — this skill's only deliverable is the handoff note itself (see "Do NOT"
below). An argument that also asks for a *plan* to be authored or finalized ("write it up as a
plan", "make this a mentor plan") is a **routing signal**, not an instruction to draft one here:
write the handoff note as normal, capturing the converged design richly in **What happened**, and
let **Recommended mentor commands for the next agent** (Step 3) route it through the "Work planned
outside mentor" mapping's new bullet for this exact shape of ask.

## Step 2 — Compute the save path

Notes live **inside the plan-topic folder they belong to** — `<repo>/.mentor/plans/<topic>/handoffs/`
— so a plan and its handoffs share one directory (its zoom visual aids sit beside it at
`.mentor/zooms/<topic>/`), and `/mentor:resume` can show which topic each note continues. (The `.mentor/` tree is exempt from
the plan gate, so the write is always allowed.) Resolve `topic` first:

- **The session's work is tied to a mentor plan** — you created or followed
  `<repo>/.mentor/plans/<topic>/plan.md` this session — → use that plan's slug as `topic`,
  **unless** `plan-state.sh overview --json` already reports that plan's state as
  `implemented` **and** the Step 1 focus / this note's Recommended-commands routing names a
  different slug — treat that combination as "no related plan" below (this is the reverse of
  Step 5's "different topic dir" case: stamp that plan-topic's own live note, if any, as
  out-of-dir per Step 5, since this note is not continuing it).
- **No related plan** → use the Step 1 focus slug as `topic` (topic == slug is fine); the note
  founds a new topic folder that a later `/mentor:plan` on the same focus will share.

```bash
topic="<topic>"  # ← REPLACE per the rule above (kebab-case; the plan's slug, or the focus slug)
slug="session"   # ← REPLACE with a short kebab-case of the next-session focus, e.g. "auth-retry-fix"
mentor_dir="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" dir)"   # worktree-safe; _no-repo fallback
[ -n "$mentor_dir" ] || { echo "ERROR: mentor dir unresolved — is CLAUDE_PLUGIN_ROOT set?" >&2; exit 1; }
hand_dir="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" ensure-dir "$mentor_dir/plans/$topic/handoffs")" || exit 1
# keep transient handoffs out of git (in-repo only); never clobber a user-tweaked file
case "$mentor_dir" in
  */_no-repo) ;;   # outside a repo — nothing to gitignore
  *) [ -e "$mentor_dir/.gitignore" ] || printf '%s\n' '*' '!.gitignore' '!config.json' '!constitution.md' > "$mentor_dir/.gitignore" ;;
esac
out="${hand_dir}/$(date +%Y%m%d-%H%M%S)-${slug}.md"
echo "$out"
```

Derive `slug` from the focus you resolved in Step 1 (short kebab-case, ≤40 chars). Set both `topic=`
and `slug=` **before** running the snippet — never leave a literal `<…>` placeholder in the path. If
you have no specific focus, the `session` default is a valid filename. (If not inside a git repo, the
snippet falls back to `$HOME/.claude/mentor/_no-repo/plans/<topic>/handoffs/`.)

> **The directory AND filename are computed by the snippet above — never infer them from an existing
> file.** The canonical location is `<repo>/.mentor/plans/<topic>/handoffs/<YYYYMMDD-HHMMSS>-<slug>.md`.
> Do **not** open a prior handoff **as a template** — not for its path, not for its filename, not
> for its section structure, not for anything else. (Reading one is fine when it *is* the work — the
> note this session resumed from; imitating one never is.) Older notes may use a stale layout (e.g.
> the flat `.mentor/handoffs/` dir, `…/plans/HANDOFF-<slug>.md`, or a `YYYY-MM-DD` filename that
> predates the timestamp pattern), Step 2's snippet computes the path and Step 3 below fully
> specifies the section structure — so there is nothing a sample can tell you that this skill does
> not, and "I was only matching the established format" is how a legacy filename convention gets
> copied into a note `/mentor:resume` cannot find. **Discoverability
> contract:** `/mentor:resume` lists ONLY notes under a `plans/*/handoffs/` dir (plus the legacy flat
> `handoffs/` dir, read-only) whose name matches `^[0-9]{8}-[0-9]{6}-.+\.md$`, and never descends into
> a `resolved/` subdir — that is where it stamps notes it has already consumed. A note saved in any
> other directory — or named differently (e.g. `HANDOFF-<slug>.md`) — is **invisible to
> `/mentor:resume`**; the next agent will never find it. Write exactly the path the snippet echoes,
> and run the snippet **once per topic's note**, reusing that path for *that* note — re-running it
> for the **same** topic mints a new timestamp and strands the first. Writing a **second note for a
> different, related topic** ("Courtesy note for a related topic" below) is a separate run of the
> snippet with that topic's own `topic=`, not a re-run of this one.

## Step 3 — Author the handoff document

Write a Markdown document with these sections, each as a literal `##` heading carrying the name as
written (skip a section only if genuinely empty). Two of them are read by machine, not just by the
next agent: `/mentor:resume` matches **Goal / next-session focus** as a *heading* to build its focus
preview, and routes on **Recommended mentor commands for the next agent**. A bold bullet where a
heading belongs, or a renamed section, makes the note unreadable to the command written to consume
it — Step 5's self-check catches that before you report.

- **Goal / next-session focus** — from `$ARGUMENTS`; what the next agent should accomplish.
- **What happened** — a tight summary of the conversation and the progress made. Narrative, not a transcript.
- **Current state** — branch, what is done vs pending, any failing checks or known-broken bits.
  Paste a rendering of
  `bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" overview --json` here — `--json` is required
  (the subcommand exits 1 without it; there is no human-table mode), so read the JSON and write
  the table yourself. A table of real plan states
  beats a prose recollection of what got built, and it is exactly what the next agent needs before
  running `/mentor:track`. Use `overview`, **not** `list`: `list` only tables topics that already
  have a `plan.md`, so on work done outside a plan it prints "No plans …" and you will wrongly
  report the work as invisible to `/mentor:track`. `overview` reports the same topics *plus* the
  ones holding only handoffs (`state: "no plan yet"`) — which is what `/mentor:track` itself
  reads, so this section and that command agree.
  Also run `bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" gate --verbose` and record its verdict
  here, rather than inferring the gate by hand (a raw `test -f .mentor/plans/.planning` collapses
  `ARMED`/`STALE` into one bucket and drops who holds it). `--verbose` only appends
  `owner_session`/`owner_cwd`/`age_min`/`affected_plans` when the state is `ARMED` — `RELEASED` and
  `STALE` print the bare token alone, so don't invent fields that aren't there, and don't normalize
  `STALE` to "released": it means the gate lapsed from age, not from an `approve-plan.sh` decision
  (`mentor:resuming` treats the two as distinct for the same reason). If the marker is `ARMED`,
  state plainly whether `owner_session` is **this session's own id** — unlike a *resumed* session
  (where an armed marker is always a stranger's), a "Pause — still drafting" handoff is usually
  written by the very session that armed it, so the ordinary case here is the opposite of
  `mentor:resuming`'s. Saying so up front is what lets the next agent read an armed gate as
  deliberate rather than alarming (see the "Pause — still drafting" bullet above).
  If the note is going to state or rely on the status of anything outside this repo's working
  tree — a deployed service's actual version, a prod database's actual state, a PR/CI/remote-branch
  status — do not assert it as fact from repo records or memory alone. Write it as conditional on a
  **named, mandatory verification command** the next agent must run first (e.g. `supabase migration
  list` before a migration push, `gh pr view <n> --json state,mergedAt` before assuming a PR
  merged), say plainly that this session could not verify it, and restate the same unverified
  assumption under **Open questions / risks** below.
- **Recommended mentor commands for the next agent** — see the mapping below.
- **Referenced artifacts (do not duplicate)** — link by **path/URL**, never paste the contents:
  - the current mentor plan file at `<repo>/.mentor/plans/<topic>/plan.md` (if one exists —
    with the Step 2 layout it sits right next to this note), plus its zoom visual aids at
    `<repo>/.mentor/zooms/<topic>/*.html` when relevant,
  - PRDs / ADRs / design docs by path,
  - issue / PR / MR URLs,
  - key commit SHAs (`git rev-parse --short HEAD`, relevant ancestors),
  - the working diff — reference it as "see `git diff` / `git status`", do **not** paste the whole diff.
- **Open questions / risks** — unresolved decisions, assumptions to verify, traps to avoid.

### Recommended-mentor-commands mapping

Pick the entries that fit the current state, tailored to the next-session focus:

- **Unclear approach / unfinished design** → `/mentor:plan <focus>` (runs the gated plan harness).
- **A plan file exists but was never approved** (state `draft`, gate still armed — the
  "Pause — still drafting" handoff) → `/mentor:plan <slug>`, continuing the existing draft at
  `<repo>/.mentor/plans/<slug>/plan.md`. Three things to spell out, because the next agent cannot
  infer any of them: **reuse that slug** (a `/mentor:plan` derived from a re-typed request can mint
  a second plan dir and orphan this draft); **do not point at `/mentor:track`**, which refuses a
  `draft` plan by design; and **re-write the plan file before approving it** — `/mentor:plan`
  re-arms the marker with a fresh mtime and `approve-plan.sh` rejects any `plan.md` older than the
  marker, so an unedited draft fails approval with "Newest plan predates this planning session".
  Say plainly that the armed gate is intentional, not a crashed session.
- **A plan exists but its decisions feel shaky** → `/mentor:grill` to pressure-test it, then re-plan / approve.
- **Approved plan(s), ready to build** → `/mentor:track` — it lists each plan's state, lets the next agent pick one, and executes it via `mentor:dispatch-agents`; `/mentor:ship` when done. Point there rather than at "resume implementation": the next agent needs to know *which* plan and *how far it got*, and `/mentor:track` is the only thing that answers both.
- **Work planned outside mentor** → which branch depends on whether anything still *owns* the planning:
  - *A static artifact* (native plan mode, a colleague's doc) → `/mentor:plan <focus>` with that plan
    pasted as the task statement. It has no mentor plan record, so `/mentor:track` cannot *execute*
    it as-is — say that plainly rather than suggesting the next agent "consider registering it",
    which is not something they can act on. What they *can* act on: `/mentor:defer <focus>` writes an
    ordinary stub plan the existing `overview`/`/mentor:track` path already understands, so offer
    that when the work should show up in the hierarchy. (`/mentor:track` does already *list* the
    topic — `overview` reports it as "no plan yet" — so never report it as invisible.)
  - *The design was converged in THIS session but never written as a mentor plan* (the user asked
    this skill to "write it up as a plan" or similar) → say plainly that authoring a plan is
    `mentor:planning`'s job, not this one's — hand-rolling it here skips Step 3's domain routing,
    Step 3.5's decision resolution, and the Content spec, none of which this skill runs. Print a
    literal `/mentor:plan <topic>` line (the SAME `topic` resolved in Step 2 — never a placeholder)
    with this note itself as the task statement (same pattern as the static-artifact bullet above —
    the note IS the artifact). Name the payoff so the user does not have to re-run `/mentor:handoff`
    by hand afterward: **at that plan's Step 6 approval question, "Hand off to next agent" (or
    "Pause — still drafting" if it needs more work first) writes the very handoff being asked for
    now** — one command drives both the plan authoring and the handoff.
  - *Another planning framework owns this work* — you ran its commands this session (e.g. spec-kit's
    `/speckit-*`) → lead with **that framework's own next command**, and say plainly that mentor's
    *planning* commands do not apply here; `/mentor:handoff` and `/mentor:resume` still do. Do not
    send the next agent to `/mentor:plan`: a second plan of record competes with the one already
    governing the work. You lived the session, so you know which harness ran — decide from that, not
    from sniffing the repo for another tool's files.
- **Shipped — a PR/MR is open and CI is pending or red** → `/mentor:merge`. This is the state a
  handoff written right after `/mentor:ship` is usually in, and it is not a resume: the work is
  built and pushed, so pointing the next agent at `/mentor:resume` alone invites them to re-derive
  the CI picture or re-implement. `mentor:resuming` already says this from its side ("Nothing else
  routes a later session into the merge tail"); name `/mentor:merge` here so the note and the
  resume path agree.
- **Repeated manual work worth capturing** → `/loom:harvest`.
- **Heavy multi-area work with no plan of record** (a research sweep, a gap audit, a multi-repo
  survey) → write the instruction the next agent can execute verbatim: *"Load
  `Skill(skill=\"mentor:dispatch-agents\")` before the first `Agent()` call — its 'Deliver before
  idling' block is what makes agents report instead of idling."* **Never write that no mentor
  command owns a fan-out.** Whether or not a command does, the next agent reads that sentence as
  licence to dispatch raw, and a fan-out without the contract block strands the whole group —
  it has already cost two sessions. This is the one mapping entry that names a skill rather than a
  slash command, so spell out the `Skill(...)` call: `mentor:resuming`'s fallback sweep looks for
  `/mentor:<command>` tokens and will not match a bare skill name.
- If `.mentor/config.json` exists (a persisted mode — `/mentor:mode status` shows it), cite the repo's approval-gate default so the next agent knows whether "Proceed" or "Deliver plan only" is listed first at plan approval.

### Courtesy note for a related topic

Sometimes finishing this session's work leaves **another** topic's live note wrong — not the note
this session itself resumed from (Step 5 already stamps that one into `resolved/`), but a
*different* topic whose existing live note now gives bad instructions because of what happened
here (e.g. it says "resume at Step N" and this session moved that topic past N, or blocked it, on
the way to finishing the current focus). Write a second, full handoff note for that topic too — a
**courtesy note** — when, and only when, that topic already has a live note or a plan whose stated
resume point this session just proved wrong. Don't reach for this for every topic merely adjacent
to this session's work: an un-planned follow-up with no existing note belongs to `/mentor:defer`
instead (see the Done-when bullet on it below) — a courtesy note per adjacent topic would bury the
one that actually matters, especially since `/mentor:resume`'s no-argument path shows only the
newest few notes.

Write the courtesy note **before** the primary note. `/mentor:resume`'s bare `latest`/`newest`/
`last` picker sorts by filename timestamp **across every topic dir**, so writing courtesy-then-primary
keeps that picker landing on the primary note — the one this session's own work belongs to.

Re-run Step 2's snippet with `topic="<the other topic>"` and its own `slug=` — this is a genuinely
second note for a second topic, not a re-run for the same one, so nothing gets stranded (see the
scoped once-rule in Step 2 above). Author it per Step 3's section structure, but resolve
**Recommended mentor commands for the next agent** from **that topic's own** state — the `overview
--json` render above already carries its `state`/`steps.ticked`/`steps.total` — never copy the
primary note's routing onto it; that would just recommit the stale instruction you're correcting.
Redact it (Step 4) and run Step 5's supersede + self-check snippet against **its own** `hand_dir`,
independently of the primary note's: each topic dir's `CHECK: live notes now` must read `1` on its
own, and each superseded basename is reported separately.

Report both notes' absolute paths in the report body. The trailing copy-paste resume prompt (the
last thing on screen, per Step 5 below) stays **singular**, for the primary note's slug only — the
courtesy note is reachable with `/mentor:resume <its-slug>` too, but naming it in the trailing
block would compete with the primary as "the" thing to paste next.

## Step 4 — Redact secrets

Before writing, scrub the document of **API keys, passwords, tokens, connection strings, and PII**.
Replace any such value with `<REDACTED>`. This is a hard requirement — never carry a live secret into
a handoff file. Never invent or guess secret values. Redact actual secret **values**, not vocabulary —
prose that merely mentions words like "token" or "password" (e.g. "fixing auth token retry") is fine.

## Step 5 — Report

Before reporting, **verify the written path is under a `plans/<topic>/handoffs/` dir and its
filename matches `<YYYYMMDD-HHMMSS>-<slug>.md`** (the exact location and pattern `/mentor:resume`
lists). If it is not, you used the wrong path — recompute via the Step 2 snippet and **`mv` the
file there** (never re-write and leave the original: a stranded misnamed copy is invisible to
`/mentor:resume` yet looks like a live note to anyone browsing the dir).

Write the file, then **supersede the topic's older notes — programmatic, not a judgment call**. The
note just written is now this topic's single resume point: the plan file carries the durable state,
so any older note of the same topic is stale by construction (this is exactly the nested-handoff
case — a session resumed from an earlier note and is now handing off again). Stamp them into the
`resolved/` subdir so `/mentor:resume` and the hooks stop listing them.

Set `out=` explicitly — shell variables do NOT survive between Bash tool calls, and the Write in
Step 3 sits between this snippet and the Step 2 one, so Step 2's `$out`/`$hand_dir` are gone here.
An empty `$hand_dir` makes the `find` a silent no-op and the stale note stays listed:

```bash
out="<absolute note path from Step 2>"   # ← REPLACE — the file you just wrote
hand_dir="$(dirname "$out")"
# supersede: older conforming notes of this topic → resolved/ (the new note replaces them)
find "$hand_dir" -maxdepth 1 -type f -name '*.md' ! -name "$(basename "$out")" 2>/dev/null \
| while IFS= read -r old; do
    case "$(basename "$old")" in
      [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-*.md)
        bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" ensure-dir "$hand_dir/resolved" >/dev/null
        mv "$old" "$hand_dir/resolved/$(basename "$old")"
        echo "superseded → resolved: $(basename "$old")" ;;
      *)
        echo "  (skipping non-conforming file: $(basename "$old"))" ;;
    esac
  done
# self-check — silence proves nothing, so print a verdict on every path
[ -f "$out" ] || echo "CHECK: \$out is not a file — the note is not where you think it is"
live="$(find "$hand_dir" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-*.md' 2>/dev/null | wc -l | tr -d ' ')"
echo "CHECK: live notes now ${live} (expect 1 — the note just written)"
# the two machine-read headings. Goal's pattern is resuming Step 2's awk verbatim, so this check
# and that listing can never disagree; Recommended stays loose on purpose — only an agent reads it,
# and real notes say "Recommended next mentor commands" / "Recommended commands for the next agent".
miss=""
grep -Eq '^#+[[:space:]].*[Gg]oal.*next-session focus' "$out" || miss="$miss Goal/next-session-focus"
grep -Eq '^#+[[:space:]].*[Rr]ecommended.*commands' "$out"    || miss="$miss Recommended-mentor-commands"
echo "CHECK: headings missing:${miss:- none (2/2 present)}"
```

Read the `CHECK:` line before writing the report — it is the only evidence you have. `live notes
now 1` licenses a supersession claim, but only for the basenames the `superseded → resolved:` lines
actually printed (none printed = there was nothing to supersede — say that, never imply it
happened). `0` means the note is not on disk where you think it is — an empty `$hand_dir`, a wrong
`$out`, or a non-conforming filename; fix that before reporting anything. `2` or more means the
`mv` did not run: name the files still live and tell the user `$hand_dir` needs a manual check.
**No `CHECK:` line at all means the snippet never ran — you have no basis for any claim about
superseding.** Claiming supersession that did not happen is the failure this step exists to prevent.

`CHECK: headings missing:` is the second verdict, and it names the sections `/mentor:resume` parses
rather than merely reads. A missing `Goal/next-session-focus` renders the note as `(no focus
section)` in the listing; a missing `Recommended-mentor-commands` leaves the next session's Step 6
with nothing to route on, which is how a resumed session ends up improvising instead of running the
harness. Fix the note and re-run the check — don't report the miss and move on.

If this session was resumed from a note that lives **outside `$hand_dir`**, the snippet above cannot
see it — stamp that specific note the same way (`mkdir -p` a `resolved/` beside it, `mv` it in). The
three ways this happens: a **legacy flat-dir note** (under `.mentor/handoffs/`), a **different
topic dir** — e.g. the work started under a pre-plan focus-slug topic and, now that a plan exists,
you are handing off under the plan's slug — and the **reverse**: Step 2's `implemented`-plan
branch, where this note deliberately does *not* file under a finished plan whose own topic dir may
still hold a stale live note pointing at work that's already done. The note you just wrote
supersedes the resumed one regardless of which folder it started in; skipping this leaves a stale
duplicate listed forever.
A stamp is reversible by moving the file back up one directory. That `mv` is outside the
self-check's reach, so `echo "superseded → resolved: <basename>"` when you run it — an out-of-dir
note you did not echo is one you may not report as superseded.

Then tell the user the **absolute path** of the new note and note that it is **gitignored**.
Report superseding from the echoed lines alone — name each `superseded → resolved:` basename, or
say plainly that nothing was superseded.
If the Step 2 snippet just created `.mentor/.gitignore`, that file itself shows as untracked —
don't claim `git status` is clean; instead suggest committing it once (it is designed to be
committed, alongside `config.json`/`constitution.md`), after which the `.mentor/` tree stays out
of `git status` for good. Offer a one-line summary of what the next agent should do first.

**End the report with a copy-paste resume prompt** — the very last thing on screen, so the user
can grab it without scrolling. Print a fenced code block containing exactly:

```
/mentor:resume <slug>
```

with `<slug>` replaced by the **actual slug from Step 2**. The slug uniquely matches the note's
filename, so `/mentor:resume` selects it directly — no picker, no re-typing; pasting this one line
into a fresh session resumes the work instantly. Below it, print a second fenced block with a
plain-prompt alternative for a next agent **without** the mentor plugin (a teammate's setup, a
cloud agent). Keep it to a **single line** — however long the path makes it — so it pastes as one
prompt:

```
Read <absolute note path> and continue the work it describes, following its "Recommended mentor commands for the next agent" section.
```

Both blocks must be **literal and complete** — real slug, real absolute path, never a `<…>`
placeholder left for the user to fill in. A prompt that needs editing before pasting defeats the
point.

### Revising a live note in place

Sometimes you need to correct the note you just wrote in this same session — a claim that
changed mid-session, a stale status — which is not what "Report" above covers (a fresh note).
**Revise the same file; never write a second note for the same topic** — Step 2's once-per-topic
rule still applies, and a second timestamped note here just strands the first, the exact failure
`CHECK: live notes now 1` exists to catch.

Use `Edit` with the **exact** old text, never a regex/pattern-based patcher (`perl -pi`, `sed`) — a
substitution that matches nothing fails **silently** in those tools, so a stale claim can survive a
"correction" undetected. After editing, re-run a targeted check and print its own `CHECK:` line,
the same "silence proves nothing" discipline as the self-check above — e.g.:

```bash
out="<the note's absolute path>"
grep -n "<the corrected text, verbatim>" "$out" \
  && echo "CHECK: correction landed" \
  || echo "CHECK: correction NOT found in file — the edit did not land"
```

The heading self-check above only verifies two headings exist — it says nothing about whether the
body you just revised is internally consistent, so this is a separate, required verdict, not a
substitute for it.

## Done when

- The document is written under the per-repo, **gitignored** `.mentor/plans/<topic>/handoffs/` dir.
- The supersede snippet **ran**, and its `CHECK: live notes now` line reported `1` — the new note is
  the topic's only live resume point. Any other reading: the report names what is still live instead
  of claiming supersession.
- Its `CHECK: headings missing:` line reported `none` — the note carries both machine-read sections
  (`Goal / next-session focus`, `Recommended mentor commands …`) as `##` headings, so
  `/mentor:resume` can preview and route on it.
- Existing artifacts are referenced by path/URL, **not duplicated**.
- Secrets are redacted.
- The content is tailored to the next-session focus.
- The recommended next-step mentor commands are listed.
- Work the note surfaced that **outlives the note** — repo-wide breakage, a follow-up feature, debt
  discovered while shipping — was captured with `/mentor:defer` so `/mentor:track` can see it. The
  note's own next steps need no stub: the note itself is durable and will be resumed. What needs one
  is everything that stays true after this topic closes, which otherwise survives only as prose in a
  document nobody re-reads once its work is done.
- The report **ends with literal copy-paste resume prompts** (`/mentor:resume <slug>` + the
  plugin-free alternative) — real values filled in, no placeholders.
- Any claim about state **outside this repo's working tree** (a deploy target, a PR/CI/remote-branch
  status, prod data) is either verified this session or written as conditional on a named
  verification command — never asserted as settled fact from memory.

### Do NOT

- Do **not** write the handoff anywhere in the repo outside `.mentor/plans/<topic>/handoffs/`.
- Do **not** save it anywhere but the Step 2 `handoffs/` path, or under a non-timestamped name —
  `/mentor:resume` only finds `plans/*/handoffs/<YYYYMMDD-HHMMSS>-<slug>.md` (legacy flat
  `handoffs/` notes stay readable, but nothing new is written there).
- Do **not** write into a `resolved/` subdir — that is `/mentor:resume`'s stamp for consumed notes;
  a new note placed there would never be listed.
- Do **not** open a prior handoff as a template — for its path, naming, structure, or anything else.
  Path comes from Step 2's snippet; structure comes from Step 3.
- Do **not** paste large artifacts (full diffs, whole plan bodies, file dumps) — reference them.
- Do **not** author or revise a `plan.md` — that file has exactly one writer, `mentor:planning`
  (plus `deferring`'s stubs and `plan-split`'s children). An argument asking for one routes through
  the "Work planned outside mentor" mapping (Step 3) instead of being hand-rolled here.
- Do **not** carry secrets or PII into the file.
