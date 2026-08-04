# Palette — roles, themes, and degradation

Read when choosing or defining a theme, when output must survive a color-depth change, or when
someone reports colors are unreadable.

## Semantic roles

Every color in a pane is one of these. Call sites name the role; only the theme table knows a hex
value. That indirection is the whole reason a theme swap is one line instead of a grep-and-replace,
and the only reason 256/16-color fallbacks can exist at all.

| Role | Carries | Typical use |
|---|---|---|
| `title` | section identity | `▌ HEADING` lines |
| `head` | column identity | table header row |
| `text` | body | normal cell content |
| `muted` | secondary | labels, units, axis hints |
| `dim` | tertiary | empty states, disabled rows |
| `border` | structure | rules, frames, bar tracks |
| `ok` | positive | healthy, fresh, passing |
| `warn` | caution | pending, aging, degraded |
| `err` | negative | error, stale, failing |
| `hot` | urgency | imminent, needs attention now |
| `accent` | emphasis | highlights, links, sparklines |
| `sel_bg` | selection | selected-row background |
| `banner_bg` | surface | banner strips, badge foreground |

**Attributes are separate from hue.** Bold, dim, italic and reverse carry emphasis and survive
every degradation step, including a 16-color terminal. `title`, `head` and `hot` are bold in all
themes; that emphasis is what still distinguishes them when color is gone entirely.

## Themes

Defined in `scripts/renderer_template.py` (`THEMES`) and `scripts/tmux_theme.sh` (`theme_def`).
**Both files must agree** — the shared vocabulary is what stops a themed pane from sitting inside
an unthemed status bar.

### Catppuccin Mocha (dark) — the reference palette

```
base     #1e1e2e   surface0 #313244   surface1 #45475a   overlay0 #6c7086
text     #cdd6f4   subtext0 #a6adc8   crust    #11111b   mantle   #181825
red   #f38ba8   peach  #fab387   yellow #f9e2af   green #a6e3a1   teal #94e2d5
blue  #89b4fa   mauve  #cba6f7   pink   #f5c2e7   lavender #b4befe  sky #89dceb
```

### Catppuccin Latte (light) — the mandatory counterpart

```
base     #eff1f5   surface0 #ccd0da   surface1 #bcc0cc   overlay0 #9ca0b0
text     #4c4f69   subtext0 #6c6f85   mantle   #e6e9ef
red   #d20f39   peach  #fe640b   yellow #df8e1d   green #40a02b
blue  #1e66f5   mauve  #8839ef   pink   #ea76cb
```

Note how much darker Latte's accents are than Mocha's. That is not a stylistic choice — it is what
makes a light theme legible, and it is why a light theme has to be authored rather than derived by
inverting a dark one. A dark theme on a light terminal is unreadable, and there is no reliable way
to detect which the user has, so **ask**.

### Tokyo Night

```
bg #1a1b26   bg_highlight #292e42   fg #c0caf5   comment #565f89   fg_gutter #3b4261
red #f7768e   orange #ff9e64   yellow #e0af68   green #9ece6a   teal #1abc9c
blue #7aa2f7   cyan #7dcfff   magenta #bb9af7   purple #9d7cd8
```
Storm variant: `bg #24283b`. Day is the light variant.

### Nord

```
Polar Night  nord0 #2e3440  nord1 #3b4252  nord2 #434c5e  nord3 #4c566a
Snow Storm   nord4 #d8dee9  nord5 #e5e9f0  nord6 #eceff4
Frost        nord7 #8fbcbb  nord8 #88c0d0  nord9 #81a1c1  nord10 #5e81ac
Aurora       nord11 #bf616a  nord12 #d08770  nord13 #ebcb8b  nord14 #a3be8c  nord15 #b48ead
```
Nord is the lowest-contrast popular dark palette. `nord3 #4c566a` on `nord0` is well under 3:1 —
use nord1–nord3 for borders and fills, never for text.

### Gruvbox dark

```
bg #282828  bg1 #3c3836  bg2 #504945  fg #ebdbb2  gray #928374  fg4 #a89984
red #fb4934  green #b8bb26  yellow #fabd2f  blue #83a598  purple #d3869b
aqua #8ec07c  orange #fe8019          (bright variants; neutrals are darker)
```

### Rose Pine

```
main   base #191724  surface #1f1d2e  overlay #26233a  muted #6e6a86  subtle #908caa
       text #e0def4  love #eb6f92  gold #f6c177  rose #ebbcba  pine #31748f
       foam #9ccfd8  iris #c4a7e7   highlightMed #403d52
moon   base #232136  surface #2a273f  overlay #393552
dawn   base #faf4ed  text #575279  love #b4637a  gold #ea9d34  pine #286983 (light)
```
**Rose Pine has no green.** `ok` maps to foam (cyan). That is a documented compromise, not an
oversight — in this theme especially, pair `ok` with a `✓` so the meaning does not rest on hue.

### ansi256-legacy — the original palette, preserved

```
title 1;38;5;212   head 1;38;5;117   ok 38;5;114   err 38;5;203
warn  38;5;221     hot  1;38;5;208   dim 2 (attribute only, no hue)
```
This is the default so that renderers copied out of this plugin before themes existed keep
rendering byte-for-byte identically. Never change these values.

## Depth detection and degradation

Resolved once at import in `_detect_depth()`. Precedence, highest first:

1. **`NO_COLOR`** — present and *non-empty*, any value → no color. Beats everything, per
   [no-color.org](https://no-color.org). An empty string means unset.
2. **`FORCE_COLOR`** — `0`/`false` off · `1` 16-color · `2` 256 · `3` truecolor.
3. **`TERM`** empty or `dumb` → no color.
4. **`COLORTERM`** contains `truecolor` or `24bit` → truecolor. The single most reliable hint;
   set by VTE, Konsole, iTerm2, kitty, WezTerm, Ghostty, Alacritty, Windows Terminal, and by tmux
   itself since 3.6.
5. **`TERM`** contains `-direct` → truecolor; contains `256color` → 256; else 16.

**There is deliberately no `isatty()` check.** A pane renderer's stdout is not a terminal, so any
library that auto-detects will strip color and leave a monochrome pane. Emitting color whenever the
terminal can carry it is correct here. Note there are three ways to turn it off — `NO_COLOR`
non-empty, `FORCE_COLOR=0`, and an empty or `dumb` `TERM` (steps 1–3 above) — so "always emits
color" is shorthand, not a guarantee. This is the same reasoning as `console` rule 3.

On macOS, do not trust terminfo alone: the system ncurses is 6.0 (2015) and its `xterm-256color`
entry has no `RGB` capability even on terminals that fully support truecolor.

### The 256-quantization trap

Accents survive quantization well — `#89b4fa`→111, `#a6e3a1`→151, `#f38ba8`→210. Surfaces do not.
Catppuccin's ramp `#313244` / `#45475a` / `#585b70` is near-gray, and the xterm cube handles grays
through a separate 24-step ramp, so those three collapse toward the same few indices and the depth
cues between panel fill, border, and selection disappear.

**Always eyeball the 256 fallback separately.** It is not a slightly duller version of the
truecolor render; it is a structurally different image.

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/renderer_template.py" demo --theme catppuccin-mocha --depth 256
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/renderer_template.py" demo --theme catppuccin-mocha --depth 16
```

At 16 colors a theme is *nearly* gone: hues map through `_rgb_to_16` to the eight basic colors, and
every surface and border role collapses together. How much of the semantic layer survives depends on
the theme, and **not always enough** — `_rgb_to_16` picks the nearest basic color by RGB distance, so
a pastel theme lands on white almost everywhere. Measured at 8 colors: `ansi256-legacy` and
`catppuccin-latte` keep `ok`/`warn`/`err` fully distinct (3/3), `nord` keeps 2/3, and
`catppuccin-mocha` collapses `title`/`head`/`ok`/`warn`/`err`/`hot` **all to white** (1/3) — its
accents are light enough that white really is the nearest of the sixteen. So at this tier the
attribute layer and the glyph vocabulary aren't doing "most of the work", they are the only work, and
the "never encode meaning in hue alone" rule below stops being an accessibility nicety and becomes
the thing keeping the pane readable at all. Check your theme at `--depth 16` rather than assuming
the roles survived.

## Curses renderers

A curses TUI reaches the screen through `init_pair`, which takes a color **number**, not an SGR
string — so `c()` and `sgr()` don't apply and the role vocabulary appears to stop at the widget
boundary. It doesn't: `role_index(role, colors)` is the same resolution with a numeric answer, and it
is the whole reason a curses pane never has to hand-roll a palette. Re-deriving the quantization
here is rule 7's re-derivation trap in a third language — the kit already owns the only correct
converter, and `role_index` is verified to agree with `_color_params` at both 256 and 16.

```python
import curses, os
from renderer_template import role_index, THEME, TITLE, HEAD, TEXT, DIM, OK, WARN, ERR, HOT

ROLES = (TITLE, HEAD, TEXT, DIM, OK, WARN, ERR, HOT)
PAIR = {}

def init_theme():
    if os.environ.get("NO_COLOR"):
        return                                # rule 3's opt-out reaches curses too
    curses.start_color()
    curses.use_default_colors()               # -1 now means "the terminal's own default"
    for i, role in enumerate(ROLES, start=1):
        if i >= curses.COLOR_PAIRS:
            break                             # the pair table is finite; overflowing it raises
        idx = role_index(role, curses.COLORS)
        curses.init_pair(i, -1 if idx is None else idx, -1)
        PAIR[role] = i

def attr(role):
    a = curses.color_pair(PAIR.get(role, 0))
    return a | curses.A_DIM if THEME.get(role) == "@dim" else a
```

Four things there are not decoration, and each is a different way the pane goes wrong without it:

- **`use_default_colors()` and the `-1` background.** Without it curses has no concept of "the
  terminal's own background" and every pair falls back to black, which paints a black rectangle over
  a themed terminal. It also makes `role_index`'s `None` directly usable: `None` means the role
  carries no hue of its own (`TEXT`, and the `@dim` sentinel), and `-1` is exactly how you say that
  to curses. Verified in a pane: the reset comes back as `\033[39m` — default foreground — rather
  than a hardcoded color.
- **`curses.COLORS`, not a constant 256.** Pass it and the 16-color tier degrades through the same
  path `c()` uses; hardcode 256 and an 8-color terminal gets indices it cannot render.
- **`@dim` is an attribute, not a hue.** `role_index` returns `None` for it because there is no color
  to return — `A_DIM` is the answer, and a renderer that only reads the number silently loses the
  dim role.
- **Init pairs once, at startup.** `init_pair` is global state, not a per-paint call, and
  `COLOR_PAIRS` is finite (32767 under `tmux-256color`, far smaller on older ncurses — hence the
  guard).

Curses also puts the pane on the **alternate screen**, which changes what verification can see —
`capture-pane` still works, scrollback does not. That is measured and spelled out in "Verifying a
keystroke-driven pane" (`console/references/verifying-pane-shapes.md`); read it before verifying one.

## Contrast and accessibility

- **Targets**: 4.5:1 for body text, 3:1 for borders and other non-text UI.
- **Overlay colors are for borders, never text.** `overlay0 #6c7086` on `base #1e1e2e` fails 4.5:1.
  `text #cdd6f4` on `base` passes comfortably.
- **Never encode meaning in hue alone.** ~8% of men have a red-green deficiency; at similar
  luminance red and green read as the same brownish gray. Pair every semantic color with a glyph or
  word: `✓ ok`, `⛔ blocked`, `◐ pending`. A contrast ratio measures luminance, not hue — passing
  4.5:1 says nothing about whether two hues are distinguishable.
- Safer hue pairs when you need two signals: blue/orange, blue/yellow. Vary lightness as well as
  hue rather than relying on the pair alone.

## Adding a theme

1. Add the role table to `THEMES` in `scripts/renderer_template.py`.
2. Add the matching `theme_def` line to `scripts/tmux_theme.sh` and to its `THEMES` list. It takes
   **13 fields in renderer-role order**: `banner_bg sel_bg title head text muted dim border ok warn
   err hot accent`. Copy the values verbatim — if the two files disagree, a themed pane ends up in a
   differently-themed status bar, which is the exact failure the shared vocabulary prevents.
3. Render and load it before claiming it works:
   ```bash
   R="${CLAUDE_PLUGIN_ROOT}/scripts"
   python3 "$R/renderer_template.py" demo --theme <name>
   "$R/tmux_theme.sh" <name> > /tmp/t.tmux && tmux source-file /tmp/t.tmux
   ```
