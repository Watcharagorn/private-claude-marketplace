---
description: Set up, redesign, or audit tmux panes against the console design standard — colored tables/gauges, viddy in-place refresh, local timestamps, verified live with capture-pane.
argument-hint: "[setup | redesign | audit] [window/pane or session]"
allowed-tools: [Bash, Read, Write, Edit, Glob, Grep]
---

# tmux-design — console

**First, before anything else, run** `cat "${CLAUDE_PLUGIN_ROOT}/skills/console/SKILL.md"` — that
file is the standard and this command body is only an argument router. Don't go looking for it with
`find` or `Glob`: the plugins cache holds every installed version side by side, so a `find` sweep
returns whichever one it hits first, and an older copy reads as a clean run while missing whole
mandatory steps. Where this file and the skill disagree, the skill wins.

The skill owns pane wiring — layouts, refresh cadence, the bundled renderer starter, the lnav format
recipe, and the verify loop.

For how a surface should *look* — themes, boxes, bars, sparklines, badges, status-bar and
pane-border styling, popups — use `/tmux-design:decorate` instead.

Parse the arguments:

- **`setup [name]`** → add a window or pane: layout choice, a `scripts/watch-<name>` wrapper, a
  one-shot renderer built to the standard, then verify.
- **`redesign [pane]`** → reformat what an existing pane displays: locate it, measure its real
  estate, rewrite the renderer, respawn, verify.
- **`audit [session]`** → sweep every pane in the session, capture each one, and report a
  per-pane verdict table of standard violations. Read-only until you're asked to fix.
- **No tokens** → infer the action from the surrounding request; if the target is ambiguous, list
  the session's panes first and ask which one.

The step that gets skipped and shouldn't: editing a script never changes a running pane — which is
why the skill's verify loop is five steps and not the two that sentence implies. Run it from the
skill; a loop reconstructed from this line has no sandbox isolation, no width assertion, and no
account of the other panes the same edit just changed.

Arguments provided: $ARGUMENTS
