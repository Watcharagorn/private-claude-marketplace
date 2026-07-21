---
name: handoff
description: >
  Compact the current conversation into a handoff document so another agent can
  pick up the work in a fresh session. User-invoked via /mentor:handoff. Summarizes
  the conversation and progress, recommends which mentor commands the next agent
  should run, references existing artifacts (the plan file, PRDs, ADRs, issues,
  commits, diffs) by path/URL instead of duplicating them, and redacts secrets.
  Saved under the repo's gitignored .mentor/handoffs/ dir, so it never pollutes
  `git status`. Ends by printing a copy-paste resume prompt so the next session
  can continue instantly.
---

# Handoff — Compact the Session for the Next Agent

This skill turns the current conversation into a **self-contained handoff document** a fresh agent
can use to continue the work — without re-reading this entire session. The document is saved
under the repo's **gitignored `.mentor/handoffs/` dir**, so it never shows up in `git status`.

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

`$ARGUMENTS` (the command argument) answers **"what will the next session be used for?"** Use it to
decide what the document emphasizes — the parts of the work relevant to that focus get the most
detail. If the argument is empty, write a general handoff covering the whole session.

## Step 2 — Compute the save path

Save under the **per-repo mentor dir** at `<repo>/.mentor/handoffs/` (consistent with where mentor
keeps plans; the `.mentor/` tree is exempt from the plan gate, so the write is always allowed):

```bash
git_common="$(git rev-parse --git-common-dir 2>/dev/null || true)"
if [ -n "$git_common" ]; then
  repo_root="$(cd "$(dirname "$git_common")" && pwd)"
  hand_dir="$repo_root/.mentor/handoffs"
else
  hand_dir="$HOME/.claude/mentor/_no-repo/handoffs"   # not in a git repo
fi
mkdir -p -m 700 "$hand_dir"
# keep transient handoffs out of git (in-repo only); never clobber a user-tweaked file
if [ -n "$git_common" ] && [ ! -e "$repo_root/.mentor/.gitignore" ]; then
  printf '%s\n' '*' '!.gitignore' '!config.json' '!constitution.md' > "$repo_root/.mentor/.gitignore"
fi
slug="session"   # ← REPLACE with a short kebab-case of the next-session focus, e.g. "auth-retry-fix"
out="${hand_dir}/$(date +%Y%m%d-%H%M%S)-${slug}.md"
echo "$out"
```

Derive `slug` from the focus you resolved in Step 1 (short kebab-case, ≤40 chars). Set it as the
`slug=` variable above **before** running the snippet — never leave a literal `<…>` placeholder in
the path. If you have no specific focus, the `session` default is a valid filename. (If not inside a
git repo, the snippet falls back to `$HOME/.claude/mentor/_no-repo/handoffs/`.)

> **The directory AND filename are computed by the snippet above — never infer them from an existing
> file.** The canonical location is `<repo>/.mentor/handoffs/<YYYYMMDD-HHMMSS>-<slug>.md`. Do
> **not** read a prior handoff to copy its path or naming: older notes may use a stale layout (e.g.
> `…/plans/HANDOFF-<slug>.md`), and Step 3 below fully specifies the section structure, so you never
> need a sample to imitate. **Discoverability contract:** `/mentor:resume` lists ONLY notes under the
> `handoffs/` dir whose name matches `^[0-9]{8}-[0-9]{6}-.+\.md$`. A note saved in any other directory
> — or named differently (e.g. `HANDOFF-<slug>.md`) — is **invisible to `/mentor:resume`**; the next
> agent will never find it. Write exactly the path the snippet echoes, and run the snippet **once**,
> reusing that path — re-running it mints a new timestamp, and a note written to a second path
> strands the first.

## Step 3 — Author the handoff document

Write a Markdown document with these sections (skip a section only if genuinely empty):

- **Goal / next-session focus** — from `$ARGUMENTS`; what the next agent should accomplish.
- **What happened** — a tight summary of the conversation and the progress made. Narrative, not a transcript.
- **Current state** — branch, what is done vs pending, any failing checks or known-broken bits.
- **Recommended mentor commands for the next agent** — see the mapping below.
- **Referenced artifacts (do not duplicate)** — link by **path/URL**, never paste the contents:
  - the current mentor plan file at `<repo>/.mentor/plans/<slug>/plan.md` (if one exists),
    plus its `zoom/*.html` visual aids when relevant,
  - PRDs / ADRs / design docs by path,
  - issue / PR / MR URLs,
  - key commit SHAs (`git rev-parse --short HEAD`, relevant ancestors),
  - the working diff — reference it as "see `git diff` / `git status`", do **not** paste the whole diff.
- **Open questions / risks** — unresolved decisions, assumptions to verify, traps to avoid.

### Recommended-mentor-commands mapping

Pick the entries that fit the current state, tailored to the next-session focus:

- **Unclear approach / unfinished design** → `/mentor:plan <focus>` (runs the gated plan harness).
- **A plan exists but its decisions feel shaky** → `/mentor:grill` to pressure-test it, then re-plan / approve.
- **Approved plan, ready to build** → resume implementation — execute the plan's dispatch annotations via `Skill(skill="mentor:dispatch-agents")`; `/mentor:ship` when done.
- **Repeated manual work worth capturing** → `/loom:harvest`.
- **Heavy multi-area work** → dispatch subagents per `mentor:dispatch-agents`.
- If `.mentor/config.json` exists (a persisted mode — `/mentor:mode status` shows it), cite the repo's approval-gate default so the next agent knows whether "Proceed" or "Deliver plan only" is listed first at plan approval.

## Step 4 — Redact secrets

Before writing, scrub the document of **API keys, passwords, tokens, connection strings, and PII**.
Replace any such value with `<REDACTED>`. This is a hard requirement — never carry a live secret into
a handoff file. Never invent or guess secret values. Redact actual secret **values**, not vocabulary —
prose that merely mentions words like "token" or "password" (e.g. "fixing auth token retry") is fine.

## Step 5 — Report

Before reporting, **verify the written path is under the `handoffs/` dir and its filename matches
`<YYYYMMDD-HHMMSS>-<slug>.md`** (the exact pattern `/mentor:resume` lists). If it is not, you used
the wrong path — recompute via the Step 2 snippet and re-write there.

Write the file, then tell the user the **absolute path** and note that it is **gitignored**.
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

## Done when

- The document is written under the per-repo, **gitignored** `.mentor/handoffs/` dir.
- Existing artifacts are referenced by path/URL, **not duplicated**.
- Secrets are redacted.
- The content is tailored to the next-session focus.
- The recommended next-step mentor commands are listed.
- The report **ends with literal copy-paste resume prompts** (`/mentor:resume <slug>` + the
  plugin-free alternative) — real values filled in, no placeholders.

### Do NOT

- Do **not** write the handoff anywhere in the repo outside `.mentor/handoffs/`.
- Do **not** save it anywhere but the Step 2 `handoffs/` path, or under a non-timestamped name —
  `/mentor:resume` only finds `handoffs/<YYYYMMDD-HHMMSS>-<slug>.md`.
- Do **not** read a prior handoff to copy its path/naming — compute the path in Step 2.
- Do **not** paste large artifacts (full diffs, whole plan bodies, file dumps) — reference them.
- Do **not** carry secrets or PII into the file.
