---
name: resume
description: >
  Browse and continue this repo's mentor handoff notes. User-invoked via /mentor:resume.
  Lists ONLY the current repo's saved handoff notes (newest first), lets the user pick one —
  from a slug/number argument or interactively — then loads the chosen note and resumes the
  work per its recommended mentor commands. The consume side of /mentor:handoff (which writes
  the notes). Strictly repo-scoped: the handoffs dir is derived from this repo's root + hash,
  so notes from other repos never appear. Scans the note for secrets before surfacing it.
version: 0.1.0
---

# Resume — Browse & Continue a Handoff Note

This skill is the **consume** side of `/mentor:handoff`. `/mentor:handoff` compacts a session into a
self-contained handoff document saved **outside the repo**; `/mentor:resume` lists those documents
**for this repo only**, lets the user pick one, and continues the work from it in a fresh session.

It reads notes; it never writes them. It is strictly **repo-scoped** — the handoffs dir is derived
from this repo's root + hash (the same key `/mentor:handoff` writes under), so notes saved for other
repositories cannot appear here.

## When to use

- Starting a fresh session and you want to pick up where a prior session (or another agent) left off.
- You have one or more handoff notes for this repo and want to continue one of them.

## When NOT to use

- You want to **create** a handoff note for the next agent — that is `/mentor:handoff`, not this skill.
- This repo has no handoff notes — there is nothing to resume (Step 3 handles this and points you at
  `/mentor:handoff`).

---

## Step 1 — Resolve the repo-scoped handoffs dir

Derive the per-repo handoffs dir. **This derivation must stay byte-for-byte identical to where
`/mentor:handoff` writes** — copy the block verbatim:

```bash
# keep in sync with handoff SKILL Step 2
git_common="$(git rev-parse --git-common-dir 2>/dev/null || true)"
if [ -n "$git_common" ]; then
  repo_root="$(cd "$(dirname "$git_common")" && pwd)"
  hand_dir="$repo_root/.mentor/handoffs"
else
  hand_dir="$HOME/.claude/mentor/_no-repo/handoffs"   # not in a git repo
fi
mkdir -p -m 700 "$hand_dir"
echo "$hand_dir"
```

Read **only** from `$hand_dir` — never scan other repos' dirs (repo-scoped is a locked requirement).
Using `--git-common-dir` means a git **worktree** resolves to the same key the note was written under.
If you are **not** inside a git repo, fall back to `$HOME/.claude/mentor/_no-repo/handoffs` — the same
fallback `/mentor:handoff` uses.

## Step 2 — List the notes, newest first

List `*.md` files in `$hand_dir`, **newest first by the filename timestamp** (the `YYYYMMDD-HHMMSS`
prefix sorts lexically = chronologically, so a reverse name sort is robust even if file mtimes drift —
unlike `ls -t`). For each file:

- **Skip** any filename that does not match the handoff naming pattern
  `<YYYYMMDD-HHMMSS>-<slug>.md` (regex `^[0-9]{8}-[0-9]{6}-.+\.md$`). Print a one-line warning naming
  the skipped file and continue — do not abort the whole listing for one stray file.
- Build a **focus preview**: read the note's **"Goal / next-session focus"** section (that section
  name is canonical — it is defined in `/mentor:handoff` SKILL Step 3; reference it, don't restate the
  format) and take its first non-blank line. If that section is absent or empty, fall back to the
  first non-blank paragraph of the note and label the preview `(no focus section)`.
- Parse the timestamp from the filename (`YYYYMMDD-HHMMSS`) for a human-readable date in the listing.

A snippet that lists conforming notes newest-first with their focus preview:

```bash
i=0
for f in $(ls "$hand_dir"/*.md 2>/dev/null | sort -r); do   # reverse name sort = newest first
  base="$(basename "$f")"
  if ! printf '%s' "$base" | grep -Eq '^[0-9]{8}-[0-9]{6}-.+\.md$'; then
    echo "  (skipping non-conforming file: $base)"; continue
  fi
  i=$((i+1))
  focus="$(awk '/^#+[[:space:]].*[Gg]oal.*next-session focus/{f=1;next} f&&/^#+[[:space:]]/{exit} f&&NF{print;exit}' "$f")"
  [ -z "$focus" ] && focus="$(awk 'NF{print;exit}' "$f")  # (no focus section) — first non-blank line
  printf '%d. %s — %s\n' "$i" "$base" "$focus"
done
```

## Step 3 — Empty case

If no conforming notes are found, tell the user **this repo has no handoff notes yet** and suggest
running `/mentor:handoff` (in a session with work to hand off) to create one. Then **stop** — there is
nothing to resume.

## Step 4 — Select a note

Print the full numbered list (newest first) so the user can see every note, then resolve a selection:

- **From the argument** (`$ARGUMENTS`) or from an `AskUserQuestion` "Other" free-text answer:
  - A **bare integer** → a **1-based ordinal** into the printed list (1 = newest).
  - **Otherwise** → a **case-insensitive substring match against the slug** (the filename part after
    the timestamp).
  - A **unique** match is selected directly. If the input is **ambiguous** (matches >1 note) or
    **matches nothing**, **never auto-pick** — re-print the list and re-ask.
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
4. **Reference artifacts by their paths** — the plan file, PRDs/ADRs, issue/PR URLs, commit SHAs as
   the note lists them. Do **not** paste their contents; open/read them only as needed to act.
5. **Act on the note's "Recommended mentor commands for the next agent."** **Bound "act":** invoke the
   listed mentor command(s) **exactly as the note states** — do not infer extra steps or expand beyond
   what the note recommends. If the note recommends `/mentor:plan <focus>`, run that; if it says resume
   implementation of an approved plan, do that.

Do **not** copy or duplicate the note into the repo working tree — it lives outside the repo by design.

## Done when

- Only **this repo's** conforming handoff notes were listed (newest first), or the empty case was
  reported with the `/mentor:handoff` hint.
- The user's selection was resolved unambiguously (argument or interactive), never auto-picked on an
  ambiguous/no match.
- The chosen note was loaded, scanned for secrets, its focus + current state surfaced, and the work
  continued via the note's recommended mentor command(s) — and nothing beyond them.

### Do NOT

- Do **not** scan or list any dir other than this repo's `$hand_dir` (repo-scoped is locked).
- Do **not** create handoff notes here — that is `/mentor:handoff`.
- Do **not** echo a live secret found in a note — warn and redact.
- Do **not** copy the note into the repo working tree.
