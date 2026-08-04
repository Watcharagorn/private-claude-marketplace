---
description: Theme and style tmux surfaces — named palettes with truecolor degradation, boxes/bars/sparklines/badges, status-bar and pane-border chrome, popups.
argument-hint: "[theme | frame | chrome | popup] [theme name, pane, or session]"
allowed-tools: [Bash, Read, Write, Edit, Glob, Grep]
---

# tmux-design — decorate

**First, before anything else, run** `cat "${CLAUDE_PLUGIN_ROOT}/skills/decorate/SKILL.md"` — that
file is the standard and this command body is only an argument router. Don't go looking for it with
`find` or `Glob`: the plugins cache holds every installed version side by side, so a `find` sweep
returns whichever one it hits first, and an older copy reads as a clean run while missing whole
mandatory steps. Where this file and the skill disagree, the skill wins.

The skill owns the visual vocabulary: semantic roles and named themes, the drawing primitives,
display-column width math, and tmux's own chrome.

Parse the arguments:

- **`theme [name]`** → pick and apply one palette across panes *and* chrome. Ask whether the host
  terminal is light or dark first — that cannot be detected, and getting it wrong makes everything
  unreadable. `${CLAUDE_PLUGIN_ROOT}/scripts/tmux_theme.sh --list` shows the options.
- **`frame [pane]`** → restyle what one pane draws: measure it, choose primitives that fit the data
  shape, rewrite the renderer against the bundled kit, then hand off to `console`'s verify loop.
- **`chrome [session]`** → status bar, window tabs, pane borders, popup styling. Generate a snippet
  with `${CLAUDE_PLUGIN_ROOT}/scripts/tmux_theme.sh <theme>`, show it, then let the user
  `source-file` it.
- **`popup [what]`** → build a `display-popup` surface for something dense or interactive, rather
  than stealing a pane for it.
- **No tokens** → infer from the surrounding request. If it's a styling question, start with the
  theme; if it's one specific pane, start with `frame`.

Two things that are easy to get wrong and expensive to debug:

- **Never rewrite `~/.tmux.conf` in place.** Write a separate file and let the user own the
  `source-file` line — a theme they can't undo is worse than no theme.
- **Width is display columns, not characters.** `⛔ blocked` is 9 characters and 10 columns. Verify
  alignment by measuring rendered lines, not by looking at them.

Arguments provided: $ARGUMENTS
