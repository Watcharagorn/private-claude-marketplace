---
name: console
description: >-
  Set up, redesign, and audit tmux windows/panes so every console surface shows formatted,
  live-refreshing content (tables, gauges, TUIs) — never raw text. Owns pane WIRING and
  verification: tmuxp layout wiring, viddy/watch refresh, renderer wrappers, lnav log formats, and
  the sandbox → respawn-pane → capture-pane loop that makes pane edits actually appear. Use
  whenever the task touches tmux or tmuxp — adding or changing a window, pane, or layout;
  redesigning what a pane displays; making terminal output "a table"; fixing a flickering, raw,
  stale, or monochrome pane; building an lnav log format; or when an edited pane script "isn't
  showing changes". Reach for it even when the user never says "tmux" — "why is my watch pane
  stale" counts. Trigger phrases — "set up a tmux window/pane", "redesign this pane", "audit my
  tmux panes", /tmux-design:console [setup|redesign|audit] [target]. For how a surface should LOOK
  — themes, boxes, bars, sparklines, badges, status-bar and border styling — use
  tmux-design:decorate.
---

# Console design for tmux panes

Set up, modify, and enforce a design standard for tmux windows and the content rendered inside
their panes. The goal of every action: **no pane ever shows raw, monochrome, flickering text** —
everything renders through a formatter (a table renderer, gum, lnav, viddy) with color, alignment,
and in-place refresh. A pane is glanced at hundreds of times a day; every formatting decision
below exists to make that glance faster.

## When NOT to use

- Styling questions — themes, palettes, boxes, charts, status-bar or pane-border appearance,
  popups (use `tmux-design:decorate`; this skill wires panes up, that one decides how they look)
- Web/GUI frontend work (use frontend-design)
- One-shot script output that never lives in a persistent pane

## The design standard

Enforce these in every pane you create or touch:

1. **No raw text.** Every pane renders via a formatter: an ANSI table renderer script, a gum TUI,
   lnav with a proper format, or viddy wrapping a one-shot renderer.
2. **No `clear`-loop refreshers** (`while :; do clear; …; sleep N; done`) — they flicker, hide
   staleness, and swallow Ctrl-C mid-child-call. Wrap a one-shot renderer with
   `viddy -p -n <secs> -- <cmd>` instead: in-place redraw, countdown header, diff-highlight
   (`-d`) that "pulses" changed cells, and scrollable snapshot history for free.
3. **Always emit color.** Panes aren't TTYs — never rely on a library's auto-detection, it will
   silently strip everything. `NO_COLOR` (non-empty) is the opt-out, and `FORCE_COLOR=0` or an empty/`dumb` `TERM` also
   disable it. *Which* colors is
   `tmux-design:decorate`'s call: it owns the semantic roles, the named themes, and the
   truecolor→256→16 degradation. A pane that emits raw color codes instead of naming a role
   can't be re-themed, so route palette questions there rather than hardcoding here.
4. **Tables**: bold header row, thin rule under it, two-space column gaps, right-aligned
   numerics. Pad with **display-column** width math, not `len()` — `⛔ blocked` is 9 characters
   and 10 columns, and colored or hyperlinked cells are mostly invisible bytes. Use the kit's
   `vlen()`/`pad()`; see `${CLAUDE_PLUGIN_ROOT}/skills/decorate/references/primitives.md`. Strip trailing zeros from exchange
   decimals (`60800.00000000` → `60800`). Negative money as `-$150.78`, never `$-150.78`.
5. **Semantic marks**: a mark is read faster than a word — `▰▱` proximity gauges, category dots,
   `∅ none` (dim) for empty sections. Prefer marks that are one column wide in every locale;
   `${CLAUDE_PLUGIN_ROOT}/skills/decorate/references/primitives.md`
   has the safe set and the emoji-width trap.
6. **Timestamps in the reader's local timezone**, short form `12 Jul 19:55` — a pane is glanced
   at, and mentally converting UTC costs more than the timestamp saves. Color heartbeats by
   freshness with `(Xm ago)` — name the `ok`/`warn`/`err` roles, as `freshness()` does, rather
   than the hues, so a theme swap still reads correctly. Pin a fixed zone only when
   the pane tracks one market's clock, and label it when you do.
7. **Renderer scripts stay dependency-free** (Python stdlib ANSI). Before writing one, look for a
   renderer the project already has — `ls scripts/` for a `*view*.py` / `*pane*.py`, `scripts/watch-*`
   wrappers, or read what the tmux/tmuxp config already launches. Extend that instead of
   duplicating its data-loading logic; keep its default output unchanged and add a flag or
   subcommand for the new view so other consumers don't break. If there is none, copy the bundled
   starter into the project's `scripts/` and adapt it:
   ```bash
   cp "${CLAUDE_PLUGIN_ROOT}/scripts/renderer_template.py" scripts/<name>_view.py
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/renderer_template.py" demo   # see the standard rendered
   ```
   It ships `c() vlen() pad() trunc() sanitize() table() panel() divider() bar() sparkline() badge() kv()
   gauge() freshness()` plus theme resolution and local-timezone handling, so the fiddly parts
   (display-column padding, palette, degradation) are already right. Richer tools only if already
   installed — `command -v gum viddy lnav jq bat glow`; `${CLAUDE_PLUGIN_ROOT}/skills/decorate/references/tooling.md` has the
   invocations and the force-color rules that make them work in a pane.
8. **Refresh cadence matches data cadence** — 90s for fast-moving state, 120s+ for slow. Render
   only the data the pane needs: never run a full fetch to display one section (the pane refreshes
   forever; wasted calls compound).

A finished workspace has three moving parts: a declarative `.tmuxp.yaml` (or tmux config), one
small `scripts/watch-<name>` wrapper per non-interactive pane, and one renderer that each wrapper
invokes with a different mode argument.

## If viddy isn't installed

`viddy` is the one real dependency of rule 2, so check `command -v viddy` before promising a
refresh loop. If it's missing, offer to install it (`brew install viddy`, or
`go install github.com/sachaos/viddy@latest`) — it's worth the install. Until then fall back in
this order, both of which redraw in place rather than blanking the screen:

1. `watch -c -n <secs> <cmd>` — `-c` is what keeps the ANSI codes; without it the pane goes
   monochrome and you've violated rule 3 while thinking you fixed rule 2.
2. `while :; do tput cup 0 0; <cmd>; tput ed; sleep <secs>; done` — homes the cursor and erases
   from there down, so the screen is overwritten rather than emptied and refilled. Never `clear`;
   that blank frame between redraws *is* the flicker.

If a redraw still tears — half the old frame visible under half the new one — wrap it in
synchronized output: `printf '\033[?2026h'` before, `printf '\033[?2026l'` after. tmux passes
this through from 3.7 onward and ignores it harmlessly before that.

## Actions

### setup — add a window or pane

1. Read the workspace's `.tmuxp.yaml` (or create one; session launched via a `tmuxp load`
   launcher script).
2. Choose layout: `main-vertical` + `main-pane-width` for an interactive-focus window;
   `main-horizontal` + `main-pane-height` for a log-dominant window.
3. Give each non-interactive pane a small `scripts/watch-<name>` wrapper — the yaml stays
   declarative and the command is testable outside tmux:
   ```zsh
   #!/bin/zsh
   # <what this pane shows>, refreshed in place by viddy every <N>s.
   cd "$(dirname "$0")/.." || exit 1
   exec viddy -p -n <N> -- <one-shot renderer command>
   ```
4. Build the renderer per the standard above, then run the **verify loop** (below).

### redesign — reformat an existing pane

1. Locate the pane: `tmux list-panes -s -t <session> -F "#{window_name} #{pane_id} #{pane_current_command}"`.
2. Read its current wrapper/command and identify the data source; measure the real estate with
   `tmux display -p -t <pane> "#{pane_width}x#{pane_height}"` and size tables/truncation to fit —
   a table that wraps is worse than the raw text it replaced.
3. Write or update the one-shot renderer (import/reuse the project's existing loader functions —
   don't duplicate parsing logic).
4. Rewire the wrapper to `exec viddy … -- <renderer>` and run the **verify loop**.

### audit — enforce the standard across a session

1. `tmux list-panes -s -t <session> -F "#{window_name} #{pane_id} #{pane_current_command}"`.
2. `tmux capture-pane -e -p -t <pane>` for each; flag violations: no ANSI colors in output,
   `clear`-loop wrappers, wall-of-text (no table/section structure), raw `tail`/`cat` panes,
   non-local timestamps, flicker-prone full-redraw loops.
3. Report a per-pane verdict table (rendered to the standard, naturally), then fix via
   **redesign** on request.

## The verify loop (critical — do not skip)

Editing a script **never** changes a running pane; tmux panes keep executing the process they
were launched with, which is why "I edited it but nothing changed" happens. After any change:

1. **Sandbox first** — render in a disposable session sized like the target, confirm colors
   render as real SGR output (not literal `[38;5;…m` garbage), then kill it:
   ```bash
   tmux new-session -d -s _sbx -x <w> -y <h> "<pane command>" && sleep 5 \
     && tmux capture-pane -e -p -t _sbx | head -30; tmux kill-session -t _sbx
   ```
2. **Respawn the live pane** — `tmux respawn-pane -k -t <pane_id> "<command with absolute path>"`.
   Don't Ctrl-C + retype via send-keys: if the old process is mid-child-call the interrupt is
   swallowed and the typed command lands as inert text. Respawn is deterministic. Caveat: a
   respawned pane runs the command directly (no shell under it), so quitting it shows
   "Pane is dead" until the next full workspace launch.
3. **Verify live** — `sleep 5 && tmux capture-pane -e -p -t <pane_id>`; confirm the new render
   and that `#{pane_current_command}` is the expected process (e.g. `viddy`). Iterate on failure.

## Log-viewer panes (lnav)

Raw log lines in an lnav pane still violate the standard — the fix is a format file, so fields
parse, identifiers get identity colors, and warn/error levels colorize. Read
`references/lnav-formats.md` when a pane tails a log; it covers the schema, the
mutually-exclusive-regex trap that silently NULLs your captures, and the headless install +
SQL validation loop.

## Done when

- Every touched pane shows colored, structured content live in the real session (verified by
  `capture-pane -e`, not assumed from a successful file edit).
- `.tmuxp.yaml` + wrapper scripts reproduce the design on the next `tmuxp load`.
- No `clear`-loops, no raw-text panes, timestamps localized, palette consistent.
