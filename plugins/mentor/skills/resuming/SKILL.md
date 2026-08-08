---
name: resuming
description: >
  Browse and continue this repo's mentor handoff notes. User-invoked via /mentor:resume.
  Lists ONLY the current repo's live (unresolved) handoff notes (newest first) from every
  plan-topic folder, lets the user pick one — from a slug/number argument or interactively —
  then loads the chosen note and resumes the work per its recommended mentor commands. A note
  is stamped resolved (moved into a resolved/ subdir, never re-listed) only when its work
  completes per the plan file or a nested /mentor:handoff supersedes it — never merely on
  load — so finished work is never re-read but unfinished work stays resumable. The consume
  side of /mentor:handoff (which writes the notes). Strictly repo-scoped: the notes live
  under this repo's .mentor/ tree, so notes from other repos never appear. Scans the note
  for secrets before surfacing it.
---

# Resume — Browse & Continue a Handoff Note

This skill is the **consume** side of `/mentor:handoff`. `/mentor:handoff` compacts a session into a
self-contained handoff document saved inside its plan-topic folder — the repo's gitignored
`.mentor/plans/<topic>/handoffs/` dir; `/mentor:resume` lists those documents **for this repo only**,
lets the user pick one, and continues the work from it in a fresh session.

A note stays **live** (listed) until its work is actually finished: it is stamped **resolved** (moved
into a `resolved/` subdir, never re-listed) only when all its tasks are done per the plan file
(Step 5's final rule) or when a nested `/mentor:handoff` supersedes it with a fresher note. Loading a
note does NOT resolve it — a session that reads a note and stalls leaves the work resumable.

It reads notes and stamps the consumed one only on completion; it never authors them. It is strictly
**repo-scoped** — the notes live under this repo's `.mentor/` tree (the same place `/mentor:handoff`
writes), so notes saved for other repositories cannot appear here.

## When to use

- Starting a fresh session and you want to pick up where a prior session (or another agent) left off.
- You have one or more handoff notes for this repo and want to continue one of them.

## When NOT to use

- You want to **create** a handoff note for the next agent — that is `/mentor:handoff`, not this skill.
- You want to pick the next **plan** to build, or see which plans are already built — that is
  `/mentor:track`. This skill resumes a *session* from a note someone wrote; plan state is a
  different question with a different answer.
- This repo has no handoff notes — there is nothing to resume (Step 3 handles this and points you at
  `/mentor:handoff`).

---

## Step 1 — Resolve the repo-scoped mentor dir

Derive the per-repo mentor dir via the shared subcommand — the same call `/mentor:handoff`
uses, so reading and writing agree by construction:

```bash
mentor_dir="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" dir)"
echo "$mentor_dir"
```

Notes live in **two locations** under `$mentor_dir`, both covered by Step 2's `find`:

- `plans/<topic>/handoffs/*.md` — the canonical per-plan-topic location `/mentor:handoff` writes.
- `handoffs/*.md` — the legacy flat dir (pre-v2.10 notes); still listed so old notes stay
  resumable, but nothing new is written there.

Read **only** from under `$mentor_dir` — never scan other repos' dirs (repo-scoped is a locked
requirement). The subcommand resolves via `--git-common-dir`, so a git **worktree** lands on the
same key the note was written under, and outside a git repo it echoes
`$HOME/.claude/mentor/_no-repo` — the same fallback `/mentor:handoff` gets.

## Step 2 — List the notes, newest first

List the `*.md` notes from **both** Step 1 locations, **newest first by the filename timestamp**
(the `YYYYMMDD-HHMMSS` prefix sorts lexically = chronologically, so a reverse sort on the *basename*
is robust even if file mtimes drift — and orders correctly across topic dirs, where a full-path sort
would group by topic instead). For each file:

- **Never list a `resolved/` subdir** — the snippet below excludes them. Notes there are finished:
  their work completed per the plan file, or a newer note superseded them (Step 5's final rule and
  `/mentor:handoff`/`/mentor:ship` stamp them). Re-listing one invites an agent to redo solved work —
  exactly what the stamp exists to prevent. Only if the user *explicitly* asks for resolved/old
  notes, list `plans/*/handoffs/resolved/*.md` too, each marked `[resolved]`.
- **Skip** any filename that does not match the handoff naming pattern
  `<YYYYMMDD-HHMMSS>-<slug>.md` (regex `^[0-9]{8}-[0-9]{6}-.+\.md$`). Print a one-line warning naming
  the skipped file and continue — do not abort the whole listing for one stray file.
- Show the note's **topic** (the `plans/<topic>/` dir it lives in; `(legacy)` for flat-dir notes) so
  the user sees which plan each note continues.
- Build a **focus preview**: read the note's **"Goal / next-session focus"** section (that section
  name is canonical — it is defined in `/mentor:handoff` SKILL Step 3; reference it, don't restate the
  format) and take its first non-blank line. If that section is absent or empty, fall back to the
  first non-blank paragraph of the note and label the preview `(no focus section)`.
- Parse the timestamp from the filename (`YYYYMMDD-HHMMSS`) for a human-readable date in the listing.

A snippet that lists conforming notes newest-first with their topic and focus preview. It is
deliberately `find`-based, not glob-based — an unmatched glob aborts the whole command under zsh
(and either location may legitimately be empty), while `find` just yields nothing for a missing dir:

```bash
# Re-derive: Step 1's block was a separate Bash call and its variables are gone. An unset
# $mentor_dir makes `find` search "/plans" and "/handoffs" — which silently yield nothing,
# so the listing reports "no handoff notes" for a repo that has them.
mentor_dir="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" dir)"
i=0; skipped=""
while IFS= read -r f; do
  base="$(basename "$f")"
  if ! printf '%s' "$base" | grep -Eq '^[0-9]{8}-[0-9]{6}-.+\.md$'; then
    echo "  (skipping non-conforming file: $base)"; skipped="$skipped$base "; continue
  fi
  case "$f" in
    */plans/*/handoffs/*) topic="$(basename "$(dirname "$(dirname "$f")")")" ;;
    *)                    topic="(legacy)" ;;
  esac
  i=$((i+1))
  focus="$(awk '/^#+[[:space:]].*[Gg]oal.*next-session focus/{f=1;next} f&&/^#+[[:space:]]/{exit} f&&NF{print;exit}' "$f")"
  [ -z "$focus" ] && focus="$(awk 'NF{print;exit}' "$f")"   # (no focus section) — first non-blank line
  printf '%d. [%s] %s — %s\n' "$i" "$topic" "$base" "$focus"
done < <(find "$mentor_dir/plans" "$mentor_dir/handoffs" \
              -type f -name '*.md' -path '*/handoffs/*' -not -path '*/handoffs/resolved/*' 2>/dev/null \
         | awk -F/ '{print $NF "\t" $0}' | sort -r | cut -f2-)   # newest first by basename timestamp
if [ -n "$skipped" ]; then echo "skipped non-conforming: $skipped"; fi   # `if`, not `&&`: as the block's last command a false `&&` exits 1 and the whole listing renders as an error
```

The exclusion is anchored to `*/handoffs/resolved/*` on purpose — a bare `*/resolved/*` would also
match a **repo whose own path** contains a `resolved/` segment (or a topic slug named `resolved`)
and silently hide every note while the hooks still see them.

## Step 3 — Empty case

If no conforming notes are found **and Step 2 skipped nothing**, tell the user **this repo has no
handoff notes yet** and suggest running `/mentor:handoff` (in a session with work to hand off) to
create one. Then **stop** — there is nothing to resume.

If the listing is empty **only because every candidate was skipped as non-conforming**, do NOT
report "no handoff notes" — that is false, and it sends the user off to write a second note while a
real one sits unreadable on disk. The skip warnings land in bash output, which the user never sees,
so this step is the only place the miss can surface. Name each skipped file to the user, then
continue to **Step 4's recovery path** instead of stopping here.

## Step 4 — Select a note

Print the full numbered list (newest first) so the user can see every note — **including the
"skipped non-conforming" line when Step 2 skipped anything**. A warning that only lands in
bash output is invisible to the user, and a misnamed-but-real handoff note silently vanishing
is exactly how unfinished work gets lost. If the user then asks to recover a skipped file,
rename it into the canonical pattern using the file's **mtime** for the timestamp
(`mv "$f" "$(dirname "$f")/$(date -r "$f" +%Y%m%d-%H%M%S)-<slug>.md"` — an invented "now"
timestamp would mis-sort the note permanently) and re-list. Only on their explicit request.

Then resolve a selection:

- **From the argument** (`$ARGUMENTS`) or from an `AskUserQuestion` "Other" free-text answer:
  - A **bare integer** → a **1-based ordinal** into the printed list (1 = newest).
  - The **keywords `latest` / `newest` / `last`** (any casing, alone or with filler like
    "latest handoff") → **ordinal 1** (the newest note).
  - **Otherwise** → a **case-insensitive substring match against the slug** (the filename part after
    the timestamp).
  - A **note path or plan slug embedded in a longer phrase** → select from what is embedded. This
    plugin produces that shape itself: `/mentor:handoff` Step 5 prints a plugin-free resume prompt
    that is an absolute note path wrapped in prose, and users paste task briefs ("implement the
    approved X plan: read `<path>`, then …"). Such a phrase substring-matches no slug, so the rule
    below would re-ask — pedantry against someone who named the file, and an agent that overrides it
    here is off-script for every step after. Take the embedded path/slug; any task instructions
    riding along are **context for the work**, never a replacement for Step 6's routing. An embedded
    path may name a file Step 2 skipped as non-conforming — load it anyway (an explicit path is
    better evidence than the listing) and offer the rename recovery above.
  - A **unique** match is selected directly. If the input is **ambiguous** (matches >1 note) or
    **matches nothing**, **never auto-pick** — re-print the list and re-ask. **Mechanical
    self-check before proceeding:** the selection must have resolved through one of the three
    literal rules above (ordinal, keyword alias, slug substring). "It obviously meant the latest
    one" is not a rule — a typo or free phrase that matches nothing (e.g. "lastest hand-off"
    against slugs it doesn't substring-match) is a NO-match: re-print and re-ask.
- **With no argument**, call `AskUserQuestion` (single-select) with the **4 newest** notes as quick
  options — `label` = the slug, `description` = the human date + focus preview. Older notes are
  reachable through the always-present **"Other"** free-text (resolved by the rule above). This
  respects `AskUserQuestion`'s 4-option cap. **Every question stands on its own:** the user answers
  from the question screen alone — never sent to a file, a plan section, a coined id or code, or an
  earlier turn to learn what the question means. A slug is a filename, not a description, so the
  preview must say what that note is actually about ("finish the Thanos SSA reprojection, 3 steps
  left") rather than restating the slug in prose.
- If there is **exactly one** note, skip the picker and ask a simple **Continue / Cancel**.

## Step 5 — Load & continue

1. `Read` the chosen note in full.
2. **Scan for secrets first.** Before surfacing any section, scan the content for secret patterns —
   API keys, passwords, tokens, connection strings, private-key blocks (`-----BEGIN`),
   `AKIA…`, `://user:password@…`. If you find one, **warn** the user that the note appears to contain
   a live secret and do **not** echo the value verbatim — surface a redacted form. (Handoffs are
   supposed to be redacted at write time; this is a defense-in-depth check on load.)
3. State **"Resuming: \<focus\>"** (from the note's Goal / next-session focus), then surface the
   **Current state** and **Open questions / risks** sections so the user sees where things stand.
   If a **Standing directives** section is present, surface it too and obey it for the rest of
   this topic — it is a constraint, not a suggestion, and it does not expire with the session
   that wrote it. Do **not** stamp the note yet — loading is not finishing; if this session
   stalls, the note must still be listed for the next one.
4. **Reference artifacts by their paths** — the plan file, PRDs/ADRs, issue/PR URLs, commit SHAs as
   the note lists them. Do **not** paste their contents; open/read them only as needed to act.
5. **Verify the gate state on disk — never trust the note's claim.** A note may say the plan gate is
   released (or armed); check the actual marker before acting:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" gate --verbose   # ARMED | RELEASED | STALE (+ owner/age/affected_plans when ARMED)
   ```

   If the marker state contradicts the note, say so and follow the marker, not the note.

   **`ARMED` here is never something this session armed itself** — resuming loads a note from a
   *prior* session, so this session hasn't run `/mentor:plan` yet, and any marker it finds predates
   it. `--verbose`'s `owner_session`/`owner_cwd`/`age_min` name who holds it; `affected_plans` names
   which plan(s) `approve-plan.sh` would promote to `approved` if run right now — surface all of it to
   the user. Do **not** try to clear it yourself: never delete the marker (`plan-gate.sh` is its only
   remover) and never run `approve-plan.sh` to "free it up" — it takes no slug and promotes *every*
   plan newer than the marker, which may be a plan nobody reviewed this session (`plan-gate.sh`'s own
   denial for this exact case carries the same warning).

   **Do not assume Step 6's `/mentor:plan <slug>` route resolves this for you.** `begin-plan.sh`'s
   foreign-marker guard compares **session IDs only** — it has no notion of slug or plan — so it fires
   identically whether the marker belongs to a genuinely unrelated plan *or* to the note's own plan
   left mid-draft by a "Pause — still drafting" handoff (resuming is always a new session, so the ids
   never match either way). Read its output: `Plan phase ARMED.` means it re-armed for you, safe to
   continue; `Plan gate NOT armed — another session's plan gate is already active.` means it
   **declined** — the old marker is still sitting there un-owned by this session. On the refusal,
   stop; do not proceed into planning believing the repo is gated just because the marker file still
   exists on disk, and do not fall through to `/mentor:dispatch-agents` or a hand-rolled ship either —
   `plan-gate.sh` will deny the first write regardless, so dispatching burns the whole batch on a wall
   it was always going to hit. Tell the user what's armed and let them decide (wait, or explicitly
   authorize continuing past it). `/mentor:track` is the one route that already handles this itself
   (it stops on any live marker, "whatever the state") — nothing extra to do there.

   **`STALE` is not still-armed, but it is not plain `RELEASED` either — treat it as its own
   determination.** The marker is still on disk (only `plan-gate.sh` deletes it, lazily, on the next
   edit attempt it would otherwise deny) but past the self-heal threshold, which is itself positive
   evidence: `approve-plan.sh` never ran to release it, so the plan was not approved — the gate has
   merely lapsed from age, not from a decision. Do not start drafting or editing on a `STALE` (or
   `RELEASED`) marker — run `/mentor:plan <slug>` first to re-arm it. `mentor:planning`'s own
   unarmed-gate check cannot save you here, because skipping the command means the skill never loads
   to run it. This is exactly the case a note resuming **planning** (its plan still `draft`) will
   usually hit.

   When the note resumes **implementation**, also glance at branch ownership before the first edit
   — GitHub + `gh` only, fail-soft:

   ```bash
   command -v gh >/dev/null && git remote get-url origin 2>/dev/null | grep -qi github && \
     gh pr list --head "$(git branch --show-current)" --state open --json number,title,url 2>/dev/null || true
   ```

   An open PR that isn't this work means new commits would land in someone else's PR; surface it
   now — discovering it at `/mentor:ship` costs a cherry-pick recovery. An open PR that **is** this
   work means the shipping already happened: say `Watch CI and merge with /mentor:merge` rather than
   re-implementing. Nothing else routes a later session into the merge tail, so a raw `gh pr merge`
   here is how a shipped plan ends up stuck at `in_progress`.
6. **Act on the note's "Recommended mentor commands for the next agent."** **Bound "act":** invoke the
   listed mentor command(s) **exactly as the note states** — do not infer extra steps or expand beyond
   what the note recommends. If the note recommends `/mentor:plan <focus>`, run that. If it recommends
   resuming implementation of an **approved plan**, run **`/mentor:track <slug>`** with the plan slug
   the note names. Track is not an extra step you inferred — it is how that recommendation is honored:
   it re-enters at the first unticked step instead of rebuilding from step 1, runs the context check
   that decides whether this session is big enough to finish, and then executes through
   `mentor:dispatch-agents` anyway. `mentor:dispatch-agents` says the same thing from its side ("When
   NOT to use — starting from a plan this session didn't write"), and a resumed note is exactly that
   case. Older notes phrase the recommendation as "implementation via `mentor:dispatch-agents`" —
   honor those **through** `/mentor:track` too; it is the same work, and passing the slug means the
   user who already chose a note isn't asked to choose a plan again. Invoke
   `Skill(skill="mentor:dispatch-agents")` directly only when the note's work has no plan record at
   all, so there is no state for track to read.

   **When the note names no commands at all** — no "Recommended mentor commands for the next agent"
   section — you still have a route; do not improvise one, and do not re-derive plan state here.
   Roughly a third of the notes on disk predate that section or drifted away from it, so this is the
   common case, not the exotic one:
   1. **Sweep the note body for `/mentor:<command>` tokens under any heading.** A note that says
      "run `/mentor:ship`" under `## What REMAINS` is recommending a command — only its heading
      drifted — and Step 6's bound applies to those exactly as if the section were canonical. Two or
      more distinct commands: ask which. **Match bare `mentor:<skill>` tokens too** — not every
      mentor surface has a slash command, so a note naming `mentor:dispatch-agents` (the shape
      `mentor:handoff-note` writes for a fan-out with no plan of record) is recommending it just as
      surely, and a sweep that only knows slashes drops it and falls through to `/mentor:track`.
   2. **None anywhere → `/mentor:track <topic>`**, using the note's own topic slug (the
      `plans/<topic>/` dir it lives in — `/mentor:handoff` writes notes there, so you already hold
      the key). Track reads plan state and already triages an approved plan, a `draft`, a deferred
      stub, and a topic with no plan record; re-deriving that here would fork a decision tree that
      has one owner.
   3. Only when the note's plan of record lives **outside** `.mentor/` — another framework owns it —
      does the no-plan-record rule above apply directly, and `mentor:dispatch-agents` carries the
      branch for it. `/mentor:track` refuses that case by design and sends you to `/mentor:plan`,
      which re-plans decisions someone already made.

   Step 2's `(no focus section)` label is the early tell: a note previewed that way is non-canonical,
   so expect this branch before you start editing rather than after.

   **The bound is on the work, not on how it is executed or delivered.** Running the note's work by
   hand instead of through `/mentor:track` skips the step ticks and `mentor:dispatch-agents`' closing
   sweep — the sweep that routes every follow-up through `/mentor:defer` — and hand-rolling
   `git push` + `gh pr create` skips `mentor:shipping` Step 6, which stamps this note resolved and
   closes the plan's state. The note then stays live and `/mentor:track` re-offers work that already
   shipped. Concretely: when you are about to type `git push`, `gh pr create`, or `gh pr merge`, run
   `/mentor:ship` instead — it hands off to `/mentor:merge`, which owns the merge consent gate. And
   when you are about to issue an `Agent()` call — however the note phrased it ("dispatch parallel
   `Explore` agents", "no single mentor command owns this") — load
   `Skill(skill="mentor:dispatch-agents")` first, then dispatch through it. Prose describing a
   fan-out names no command, so it is neither the no-commands branch above nor licence to dispatch
   raw. That skill appends the standing contract block ("Deliver before idling"), which is the only
   thing that makes a dispatched agent report instead of signalling idle with nothing delivered; a
   fan-out issued without it strands the whole group at once and leaves you redoing their work by
   hand. Going direct rather than through `/mentor:track` is right **only** for a research or
   analysis fan-out, which has no plan steps to re-enter or tick — a fan-out that *implements* plan
   steps still routes through `/mentor:track` per the bound above. Loading the skill honors the
   note's instruction; it does not expand its scope.
7. **Stamp the note resolved when — and only when — its work is done.** Track the note's path for the
   rest of the session; the stamp fires on the first of these:
   - **All the note's tasks completed per the plan file** — every recommended command ran to
     completion and the plan's implementation steps are done (typically the moment `/mentor:ship`
     succeeds; ship also stamps the topic's notes itself as a backstop). Run:

     ```bash
     note="<the resumed note's absolute path>"
     resolved_dir="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" ensure-dir "$(dirname "$note")/resolved")" || exit 1
     mv "$note" "$resolved_dir/$(basename "$note")"
     echo "resolved: $resolved_dir/$(basename "$note")"
     ```

   - **A nested handoff** — this session ends with `/mentor:handoff` continuing the same work; its
     supersede step stamps the older note mechanically, so there is nothing extra to do here — for a
     note in this same `handoffs/` dir. If the note you resumed lives in a different topic dir or the
     legacy flat dir, handoff's sweep cannot see it: hand its absolute path to the handoff step
     explicitly, or stamp it here with the snippet above.

   If the session ends with the work unfinished and no nested handoff, **leave the note live** —
   unfinished work must stay resumable; that is not a failure. A stamp is reversible by moving the
   file back up one directory. **Never stamp a note that already lives under a `resolved/` dir**
   (an explicitly-browsed `[resolved]` note): it is already retired, and the snippet would nest a
   useless `resolved/resolved/` — skip this step for those.

Do **not** copy or duplicate the note into the repo source tree — it lives in the gitignored
`.mentor/` tree by design.

## Done when

- Only **this repo's** conforming, live handoff notes were listed (newest first, with their
  topic), or the empty case was reported with the `/mentor:handoff` hint. Any skipped
  non-conforming files were named in the user-facing list, not just in bash output.
- The user's selection was resolved unambiguously (argument or interactive), never auto-picked on an
  ambiguous/no match.
- The chosen note was loaded, scanned for secrets, its focus + current state surfaced, and the work
  continued via the note's recommended mentor command(s) — and nothing beyond them. The session
  still **ended through a mentor command** — `/mentor:ship` → `/mentor:merge`, `/mentor:handoff`, or
  `/mentor:defer` — never through raw `git`/`gh` or a hand-written file; the bound is on the work,
  not on how it is executed or delivered.
- The note was **stamped resolved** if its work finished this session (all plan-file tasks done) or
  it was superseded by a nested `/mentor:handoff` — and left **live** otherwise.

### Do NOT

- Do **not** scan or list any dir other than this repo's `$mentor_dir` locations (repo-scoped is
  locked).
- Do **not** list notes inside a `resolved/` subdir (finished or superseded work) unless the user
  explicitly asks for resolved notes.
- Do **not** stamp a note merely because it was loaded — only completion (per the plan file) or a
  superseding handoff resolves it; an unfinished note must stay listed.
- Do **not** skip the stamp when the work DID finish — an unstamped solved note WILL be re-listed
  and re-worked by a later session.
- Do **not** hand-write a note into `.mentor/` — `/mentor:handoff` owns a resume point for
  **unfinished** work here, `/mentor:defer` owns work that **outlives this topic** (a flaky test,
  debt, a follow-up), and they are not interchangeable. A hand-composed name lands in Step 2's
  skipped list instead of the resume list; a follow-up misfiled as a handoff after the work shipped
  is retired by the next handoff's supersede sweep. Either way it is lost.
- Do **not** rename a skipped non-conforming file unasked — surface it and wait for the user.
- Do **not** echo a live secret found in a note — warn and redact.
- Do **not** copy the note into the repo working tree.
