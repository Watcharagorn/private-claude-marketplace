# tmux-design

A design standard for tmux console surfaces, plus the workflow that makes changes actually land
on screen. The premise: a pane is glanced at hundreds of times a day, so **no pane should ever
show raw, monochrome, flickering, or misaligned text**. Everything renders through a formatter —
an ANSI renderer, gum, lnav, or viddy wrapping a one-shot script.

Two skills split the job cleanly:

| Skill | Owns | Reach for it when |
|---|---|---|
| `console` | pane **wiring** and verification | adding a pane, refresh loops, lnav formats, auditing a session, "I edited it but nothing changed" |
| `decorate` | the **visual vocabulary** | themes, boxes, charts, badges, status bar, pane borders, popups, "make it prettier", misaligned columns |

## Commands

| Command | Args | Does |
|---|---|---|
| `/tmux-design:console` | `[setup \| redesign \| audit] [target]` | wire up, reformat, or sweep panes, then verify live |
| `/tmux-design:decorate` | `[theme \| frame \| chrome \| popup] [target]` | apply a palette, restyle a pane, theme tmux chrome, build an overlay |

## Skills

| Skill | Role |
|---|---|
| `console` | The 8-rule standard, three actions (**setup** / **redesign** / **audit**), the viddy refresh rules, and the sandbox → respawn → capture verify loop. |
| `decorate` | Semantic roles and named themes, drawing primitives, display-column width math, and tmux chrome. References load on demand: `palette.md`, `primitives.md`, `tmux-chrome.md`, `tooling.md`. |

## What's in it

- `skills/console/` — the wiring standard and verify loop.
  - `references/lnav-formats.md` — lnav format schema, the mutually-exclusive-regex trap, headless
    install + SQL validation. Loaded only when a pane tails a log.
- `skills/decorate/` — the visual standard.
  - `references/palette.md` — the semantic roles, seven themes (six in hex, plus the original 256-index palette), the color-depth
    ladder, the 256-quantization trap, contrast and colorblind guidance.
  - `references/primitives.md` — frames, bars, sparklines, badges, banners; the width rules
    (East-Asian-Ambiguous box glyphs, emoji, ZWJ, OSC-8); Nerd Font tiers.
  - `references/tmux-chrome.md` — status bar, format language, pane borders, popups.
  - `references/tooling.md` — gum/glow/bat cookbook and the force-color rules that make them
    work in a pane.
- `scripts/renderer_template.py` — dependency-free (stdlib only) themed ANSI renderer with
  `c() vlen() pad() trunc() sanitize() table() panel() divider() spread() bar() sparkline() badge()
  kv() gauge() freshness()` and a `demo` mode. Copy it into the project and adapt.
- `scripts/tmux_theme.sh` — emits a tmux chrome snippet for a named theme, on stdout only.
- `commands/console.md`, `commands/decorate.md`.

No hooks.

## Usage

```
/tmux-design:console setup portfolio      # add a window/pane and build its renderer
/tmux-design:console redesign %3          # reformat what an existing pane displays
/tmux-design:console audit invest         # sweep a session, report standard violations

/tmux-design:decorate theme nord          # one palette across panes and chrome
/tmux-design:decorate frame %3            # restyle what one pane draws
/tmux-design:decorate chrome              # status bar, tabs, pane borders
/tmux-design:decorate popup lazygit       # a display-popup overlay surface
```

Both trigger without the command — "why is my watch pane stale" reaches `console`; "make my
dashboard pane prettier" or "my columns go crooked with Japanese text" reaches `decorate`.

See the whole vocabulary rendered before writing anything:

```bash
python3 …/tmux-design/scripts/renderer_template.py demo --theme catppuccin-mocha
python3 …/tmux-design/scripts/renderer_template.py demo --depth 16 --ascii
…/tmux-design/scripts/tmux_theme.sh --list
```

## The three things this exists to prevent

**Flicker loops.** `while :; do clear; …; sleep N; done` blanks the screen between frames, hides
staleness, and swallows Ctrl-C mid-child-call. The standard is
`viddy -p --unfold -n <secs> -- <renderer>` (`--unfold` avoids a stale-width wrap on live resize).
If viddy isn't installed the skill offers to install it and falls back to `watch -c` or a
`tput cup 0 0` redraw, never `clear`. If a redraw tears, wrap it in synchronized output.

**"I edited it but nothing changed."** A tmux pane keeps executing the process it was launched
with; editing the script on disk does nothing to the running pane. Every change ends with
sandbox-render → `tmux respawn-pane -k` → `tmux capture-pane -e -p`.

**Columns that drift.** `len("⛔ blocked")` is 9; it occupies 10 columns. CJK is 2 columns per
character, `⚠️` is 2 where `⚠` is 1, and a colored or hyperlinked cell is mostly invisible bytes.
The bundled kit measures display columns, so tables stay aligned whatever lands in them.

## Dependencies

`tmux` (required), `tmuxp` for declarative session config, `viddy` for refresh (fallbacks
documented), `lnav` for log panes. `gum`/`glow`/`bat` are optional upgrades, always probed with
`command -v`. Renderers themselves stay stdlib-only Python so a pane never breaks on a missing
package.
