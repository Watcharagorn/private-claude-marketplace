---
name: decorate
description: >-
  Owns the VISUAL VOCABULARY of tmux surfaces — theme, frame, chart, badge, status bar, popup.
  Ships named themes (Catppuccin, Tokyo Night, Nord, Gruvbox, Rose Pine) in truecolor with
  256/16/no-color degradation, box-drawing and block primitives (panels, bars, sparklines,
  badges), column-correct width math for emoji/CJK/ANSI, and tmux chrome — status bar, tabs,
  borders, popups. Use whenever the question is how something should LOOK: "make this pane
  prettier", "theme my tmux", "style my status bar", "add a progress bar or sparkline", "my table
  columns are misaligned", "these colors are unreadable on my light terminal", "put a box around
  this output". Reach for it even when tmux is never mentioned; "my CLI output looks ugly" counts.
  For WIRING a pane — adding panes, viddy refresh, lnav formats, session audits — use
  tmux-design:console: this skill styles what a pane shows, console operates the pane.
---

# Decoration for tmux surfaces

`console` decides that a pane renders through a formatter and verifies the change landed.
This skill decides **what that formatter draws** — which colors mean what, which frame to use,
which chart shape fits the data, and how the pane's surroundings (status bar, borders, popups)
are styled to match.

One idea underpins everything here: a pane is glanced at hundreds of times a day, so the reader
should get the answer from *shape and color* before they finish reading a word. Decoration that
doesn't shorten that glance is noise, and decoration that misaligns is worse than none.

## When NOT to use

- Wiring, refresh, or verification of a pane — that's `tmux-design:console`
- Web/GUI frontend work — that's `frontend-design`
- One-shot script output that never lives in a persistent pane

## The decoration standard

**1. Name a role, never a color.** Call sites say `c(OK, …)` / `#[fg=$OK]`, not `38;5;114`.
The indirection is what lets one theme swap restyle every pane at once, and it's the only reason
the 256-color and 16-color fallbacks can exist. Roles: `title head text dim muted border ok warn
err hot accent sel_bg banner_bg`. Pick the theme once per workspace — mixed themes across panes
read as breakage, not variety. → `references/palette.md`

**2. Degrade, never assume.** truecolor → 256 → 16 → none, resolved from `NO_COLOR` (present and
non-empty wins over everything), then `FORCE_COLOR`, then `COLORTERM`, then `TERM`. Nerd-font
glyphs → plain Unicode → ASCII. A missing glyph cannot be detected from the output — it renders
as tofu, a blank, or a double-width box depending on the terminal — so glyph tiers above plain
Unicode are always opt-in, never auto-detected.

**3. Width is display columns, not characters.** `len("⛔ blocked")` is 9; it occupies **10
columns**. `⚡` and every CJK character are 2 columns. `⚠` is 1 but `⚠️` is 2. `🧑‍🌾` is 7 code
points and 2 columns. Measure with the kit's `vlen()`, pad with `pad()`, cut with `trunc()`.
Stripping ANSI before measuring is not enough on its own — the pattern must also cover OSC-8
hyperlinks, whose text is visible but whose wrapper is not.

**4. Colorize last.** Compute the whole frame in plain text, measure it, pad it, *then* apply
color. This is why `figlet | lolcat | boxes` is broken by construction: lolcat emits a color
sequence per character, so everything downstream measures a 40-column line as ~800 bytes. Any
pipeline that colors before it lays out will drift.

**5. Match the primitive to the data shape.** One value → `badge()` or `kv()`. A ratio or
percentage → `bar()`. A series over time → `sparkline()`. Rows → `table()`. Grouped sections →
`panel()` or `divider()`. "How close is it?" → `gauge()` (deliberately inverted; not a progress
bar). A monitored resource's own topology, carrying live status → a status-driven animated glyph,
but only when the renderer owns its paint loop. Reaching for a table when the data is one number is
the most common over-decoration.
→ `references/primitives.md`

**6. Chrome and content share the palette.** A Catppuccin pane inside a default-green status bar
looks broken, not themed. When you theme panes, theme the status bar, window tabs, and pane
borders in the same pass. → `references/tmux-chrome.md`

**7. Budget the real estate first.** `tmux display -p -t <pane> "#{pane_width}x#{pane_height}"`
is the only correct source for the **pane's** size inside tmux — `tput cols` returns its 80-column
fallback when stdout isn't a terminal, which is exactly the situation a pane renderer is in, and
`COLUMNS` is ignored by gum and glow. But the pane's size is not the size you get to draw in. The
refresh wrapper takes its cut first (under viddy: 4 rows, plus the right-hand column as soon as
content fills the pane), and these costs compose rather than replace each other — a frame costs 2
columns and 2 rows, so a panel inside a default-header viddy pane has an inner width of
`pane_width - 3` and an inner height of `pane_height - 6`. Subtract the wrapper's cut before the
frame's, or the frame you carefully sized to the pane wraps anyway. Content that wraps is worse
than the raw text it replaced. → `references/primitives.md`, "Motion, repaint, and the wrapper's
cut"

**8. Don't let meaning rest on hue alone.** Roughly 8% of men have a red-green deficiency, and at
similar luminance those two read as the same brownish gray. Pair every semantic color with a
glyph or word — `✓ ok` / `⛔ blocked`, not a green block and a red block. Contrast ratio measures
luminance, not hue, so passing 4.5:1 does not make a hue distinction legible.

**9. Sanitize untrusted text before laying it out.** Branch names, log lines, commit messages,
filenames. A stray U+202E measures zero columns but visually reverses the rest of the row — a
layout bug and a spoofing vector. The kit's `sanitize()` strips bidi controls and C0/C1 while
preserving ZWJ.

**10. Stdlib first; tools are an upgrade, not a dependency.** The bundled kit is pure Python
stdlib so a pane never breaks because a binary is missing. Reach for `gum`/`glow`/`bat` only
behind `command -v`, and know that they strip color when piped unless forced.
→ `references/tooling.md`

## The toolkit

```bash
# See the whole vocabulary, in any theme, at any color depth
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/renderer_template.py" demo --theme catppuccin-mocha
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/renderer_template.py" demo --depth 16 --ascii

# Generate tmux chrome for a theme (stdout only — never edits ~/.tmux.conf)
"${CLAUDE_PLUGIN_ROOT}/scripts/tmux_theme.sh" --list
"${CLAUDE_PLUGIN_ROOT}/scripts/tmux_theme.sh" nord
```

`renderer_template.py` provides `c() vlen() pad() trunc() sanitize() table() panel() divider()
spread() bar() sparkline() badge() kv() gauge() freshness()`. Copy it into the project's `scripts/` and
adapt it; the fiddly parts — column math, theme resolution, degradation — are already correct.
Its `c()` still accepts raw SGR strings, so renderers written before themes existed keep working.

## Actions

### theme — choose and apply one palette

1. Ask what the host terminal's background is. A dark theme on a light terminal is unreadable,
   and this cannot be detected reliably — `catppuccin-latte` is the light option. If the machine
   already runs other themed tmux sessions, read one first (`tmux show -t <other-session>`) and
   name the closest bundled theme instead of hand-copying its color numbers: matching the
   neighbours is usually the actual goal, and a named theme keeps the degradation and the role
   vocabulary that copied literals throw away. `ansi256-legacy` is the one that matches a session
   styled straight from the plain 256-color palette.
2. Set `TMUX_DESIGN_THEME` for the session so every renderer picks it up:
   `tmux setenv -g TMUX_DESIGN_THEME <name>`.
3. Generate and load the matching chrome (below), then re-render the panes.
4. Verify at the target depth — a theme that looks right in truecolor can collapse in 256, where
   the near-gray surface colors quantize onto the same few indices.

### frame — restyle one pane's content

1. Measure the pane, then pick primitives per rule 5 and a border weight that fits.
2. Edit or write the one-shot renderer against the kit's helpers rather than hand-rolling padding.
3. Hand off to `console`'s verify loop — a file edit does not change a running pane.

### chrome — status bar, tabs, borders

Generate a snippet, review it, then have the user load it. Never rewrite `~/.tmux.conf` in place:

```bash
mkdir -p ~/.config/tmux
"${CLAUDE_PLUGIN_ROOT}/scripts/tmux_theme.sh" tokyo-night > ~/.config/tmux/theme.tmux
tmux source-file ~/.config/tmux/theme.tmux && tmux refresh-client -S
```

The generator emits global options (`set -g`), so loading it restyles **every** session on that
tmux server and pins one theme server-wide. That is usually what someone wants and is a surprise
when it isn't — on a machine running several sessions, say so before loading, or scope the options
to one session (`set -t <session>` for `status-*`, and per-window `set -w -t <session>:<n>` for
`pane-border-*` / `window-status-*`, which are window options).

Sanity-check formats with `tmux display-message -a`, which dumps every variable and its live
value — by far the fastest way to debug a `#{}` expression. That shows what an option *expands*
to, not what the client actually draws; to see the rendered bar at the real client width, use
"Verifying rendered chrome" in `references/tmux-chrome.md`. The gotchas that cost the most time
(escaping inside conditionals, `#()` staleness, border styles ignoring attributes) are there too.

### popup — transient overlay surfaces

`display-popup` is the right home for anything dense or interactive: it's sized in percentages,
carries its own border and style, and disappears without perturbing the user's layout. Prefer it
over stealing a pane. `-E` closes when the command exits; `-EE` closes only on success, which
keeps a failure on screen long enough to read.

## Delivering decoration into a pane

Which mechanism you use changes what the tooling can detect:

| Goal | Mechanism |
|---|---|
| Replace what a pane renders | `tmux respawn-pane -k -t <pane> '<cmd>'` (then verify — see `console`) |
| Push transient output into a live pane | `printf '…' > "$(tmux display -p -t <pane> '#{pane_tty}')"` |
| Dense or interactive surface | `tmux display-popup -E -b rounded -T ' title ' '<cmd>'` |

The `#{pane_tty}` route is worth knowing: stdout becomes a **real tty**, so gum and glow
auto-detect both color and the correct width with no environment variables, and the process
already running in the pane isn't disturbed.

## Done when

- Every touched surface names roles, not raw color codes, and one theme covers panes *and* chrome.
- Rendered output is column-correct — verified by measuring, not by eye — including any emoji,
  CJK, or hyperlinked cells.
- The design still reads at the pane's real width, and at 256 colors, and under `NO_COLOR`.
- No meaning carried by hue alone.
- Changes verified live, not assumed from a successful file edit — pane *content* via `console`'s
  verify loop, and *chrome* via "Verifying rendered chrome" in `references/tmux-chrome.md`, since
  that verify loop is pane-scoped and structurally cannot see a status bar or window-tab row.
