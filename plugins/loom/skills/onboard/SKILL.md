---
name: onboard
description: Guided walkthrough that sets up the whole loom plugin for a new user or machine — checks the plugin's tracking state (the SessionEnd hook only proves itself after tracked sessions end), opts plugins into tracking, explains the harvest/learn modes and where state lives, offers the daily automation schedule, and finishes with a verification dry-run. Use when the user says "onboard loom", "set up loom", "help me get started with loom/harvest/learn", "/loom:onboard", asks what loom can do, or has just installed the plugin and asks what to configure. Resumable — each step checks current state first, so re-running skips what's already done.
version: 0.1.0
---

# onboard — set up loom end to end

Walk the user through loom's setup, one step at a time. Every step **checks current state first** and
skips itself when already done — running this twice is safe and fast. Delegate real work to the owning
skills via `Skill()` (`track`, `automate`); never duplicate their logic here.

`cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"` throughout.

## Step 1 — Check the plugin's tracking state

```bash
ls "$cfg/loom" 2>/dev/null
tail -n 3 "$cfg/loom/learning/usage-index.jsonl" 2>/dev/null || echo "NO_INDEX"
```

The SessionEnd hook (`track-usage.sh`) writes one usage-index line per finished session — an existing,
growing `usage-index.jsonl` is a good sign the plugin is enabled and its hook fires. `NO_INDEX` is
normal and not a failure: the hook only writes after a **tracked** session **ends**, so a fresh
install (or one with nothing tracked yet) can't have an index. Note the state and move on — Step 5's
dry-run is the real end-to-end check.

## Step 2 — Tracking (makes learn's discovery instant)

Check `$cfg/loom/learning/config.json` → `track[]`. Nothing tracked → explain the one-liner (tracking
records which enabled plugins loom should index at session end; `learn` works without it, just slower)
and ask whether to opt in now. Yes → `Skill(skill="track")` with the plugins they name. Already
tracked → print the list and move on.

## Step 3 — Explain the modes + where state lives

Keep this to one compact briefing (no questions):

- **`/loom:harvest`** (no arg) — auto-harvests every un-harvested session of the current project,
  one at a time, folding passing artifacts in at **project scope** (review with `git diff`).
  `--review` pauses each session for confirmation; `--dry-run` previews; a session id/path runs one
  session interactively — the manual escape hatch.
- **`/loom:learn <plugin>`** — analyzes every session that used the plugin, expert-reviews and
  auto-implements approved improvements session by session, publishes once. Same
  `--review`/`--dry-run` flags; `<plugin> <session-id>` is the interactive single-session form. Runs
  from the marketplace repo.
- **State** (all under `$cfg/loom/`): `harvest/` per-project ledgers + reports, `learning/` per-plugin
  ledgers + usage index + reports, `automation/` daily-run config + logs. Ledgers + watermarks are why
  re-runs only pick up new sessions.

## Step 4 — Daily automation (optional)

Run `Skill(skill="automate")` with `--status` to learn the current state (it owns schedule
inspection — don't re-implement it here). Not installed → describe it in one sentence (a daily
headless job that harvests chosen projects and learns tracked plugins unattended), **state the
`bypassPermissions` tradeoff plainly** (unattended file edits + a git push for learn's publish —
guarded by project-scope folds, expert review, and `git diff` after the fact), and ask whether to set
it up. Yes → `Skill(skill="automate")` for the setup flow. Already installed → relay the status and
move on.

## Step 5 — Verify with a dry-run

Finish with a real, harmless end-to-end check: run `Skill(skill="harvest-automations")` with
`--dry-run` — it operates on the **current directory's** project — and show the discovery list. Close
with the one-line cheat sheet:

```
/loom:harvest            auto-harvest this project        /loom:harvest --review    confirm each session
/loom:learn <plugin>     improve a plugin from usage      /loom:automate            daily unattended run
/loom:track <plugin>     make learn discovery instant     /loom:onboard             re-run this setup
```

## Done when

- Every step either verified existing state or performed its setup via the owning skill — nothing was
  duplicated inline, nothing re-done that was already configured.
- The bypassPermissions tradeoff was stated **before** offering automation setup.
- The walkthrough ended with the dry-run output and the cheat sheet, and the user knows where state
  lives and how to review auto-folded artifacts (`git diff`).
