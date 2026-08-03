---
name: resume
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
version: 0.4.0
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

If no conforming notes are found, tell the user **this repo has no handoff notes yet** and suggest
running `/mentor:handoff` (in a session with work to hand off) to create one. Then **stop** — there is
nothing to resume.

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
  - A **unique** match is selected directly. If the input is **ambiguous** (matches >1 note) or
    **matches nothing**, **never auto-pick** — re-print the list and re-ask. **Mechanical
    self-check before proceeding:** the selection must have resolved through one of the three
    literal rules above (ordinal, keyword alias, slug substring). "It obviously meant the latest
    one" is not a rule — a typo or free phrase that matches nothing (e.g. "lastest hand-off"
    against slugs it doesn't substring-match) is a NO-match: re-print and re-ask.
- **With no argument**, call `AskUserQuestion` (single-select) with the **4 newest** notes as quick
  options — `label` = the slug, `description` = the human date + focus preview. Older notes are
  reachable through the always-present **"Other"** free-text (resolved by the rule above). This
  respects `AskUserQuestion`'s 4-option cap.
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
   Do **not** stamp the note yet — loading is not finishing; if this session stalls, the note must
   still be listed for the next one.
4. **Reference artifacts by their paths** — the plan file, PRDs/ADRs, issue/PR URLs, commit SHAs as
   the note lists them. Do **not** paste their contents; open/read them only as needed to act.
5. **Verify the gate state on disk — never trust the note's claim.** A note may say the plan gate is
   released (or armed); check the actual marker before acting. Derive the path *in the same command*
   — shell variables don't survive between Bash calls, and a half-derived path makes this check
   answer RELEASED every time, which is the one wrong answer it must never give:

   ```bash
   mentor_dir="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" dir)"
   test -f "$mentor_dir/plans/.planning" && echo ARMED || echo RELEASED
   ```

   If the marker state contradicts the note, say so and follow the marker, not the note. When the
   note resumes **implementation**, also glance at branch ownership before the first edit — GitHub +
   `gh` only, fail-soft:

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
   resuming implementation of an **approved plan**, implementation is subagents-first: invoke
   `Skill(skill="mentor:dispatch-agents")` and follow its "Executing the dispatches" section (the same
   SDD path plan Step 6 and handoff prescribe).
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
  continued via the note's recommended mentor command(s) — and nothing beyond them.
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
- Do **not** create handoff notes here — that is `/mentor:handoff`.
- Do **not** rename a skipped non-conforming file unasked — surface it and wait for the user.
- Do **not** echo a live secret found in a note — warn and redact.
- Do **not** copy the note into the repo working tree.
