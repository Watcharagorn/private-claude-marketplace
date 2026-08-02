# tmux-design

A design standard for tmux console surfaces, plus the workflow that makes changes actually land
on screen. The premise: a pane is glanced at hundreds of times a day, so **no pane should ever
show raw, monochrome, flickering text**. Everything renders through a formatter — an ANSI table
renderer, gum, lnav, or viddy wrapping a one-shot renderer.

Ported from a workspace-local skill (`tmux-console-design`) and generalized so it works in any
repo.

## What's in it

- `skills/console/` — the skill: the 8-rule standard (palette, tables, gauges, cadence), the
  three actions (**setup** / **redesign** / **audit**), and the verify loop.
  - `references/lnav-formats.md` — writing an lnav format for log panes: schema, the
    mutually-exclusive-regex trap, headless install + SQL validation. Loaded only when a pane
    tails a log.
- `scripts/renderer_template.py` — dependency-free (stdlib only) ANSI renderer starter with
  `c() / vlen() / table() / gauge()` helpers and a `demo` mode. Copy it into the project and adapt.
- `commands/console.md` — `/tmux-design:console [setup|redesign|audit] [target]`.

No hooks.

## Usage

```
/tmux-design:console setup portfolio      # add a window/pane and build its renderer
/tmux-design:console redesign %3          # reformat what an existing pane displays
/tmux-design:console audit invest         # sweep a session, report standard violations
```

It also triggers without the command — "make this pane a table", "why is my watch pane stale",
"make my dashboard pane prettier" all reach the same skill.

See the standard rendered before writing anything:

```bash
python3 ~/.claude/plugins/…/tmux-design/scripts/renderer_template.py demo
```

## The two things this exists to prevent

**Flicker loops.** `while :; do clear; …; sleep N; done` blanks the screen between frames, hides
staleness, and swallows Ctrl-C mid-child-call. The standard is `viddy -p -n <secs> -- <renderer>`
— in-place redraw, countdown header, diff highlight, snapshot history. If viddy isn't installed
the skill offers to install it and falls back to `watch -c` or a `tput cup 0 0` redraw, never
`clear`.

**"I edited it but nothing changed."** A tmux pane keeps executing the process it was launched
with; editing the script on disk does nothing to the running pane. Every change ends with
sandbox-render → `tmux respawn-pane -k` → `tmux capture-pane -e -p` to confirm the new output is
really on screen.

## Dependencies

`tmux` (required), `tmuxp` for declarative session config, `viddy` for refresh (fallbacks
documented), `lnav` for log panes. Renderers themselves stay stdlib-only Python so a pane never
breaks on a missing package.
