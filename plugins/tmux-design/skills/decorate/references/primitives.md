# Primitives — frames, charts, marks, and width

Read when choosing how to draw something, or when alignment is wrong.

- [Width correctness](#width-correctness) — read this first; it breaks everything else
- [Tables](#tables)
- [Frames and dividers](#frames-and-dividers)
- [Bars, sparklines, gauges](#bars-sparklines-gauges)
- [Marks, badges, banners](#marks-badges-banners)
- [Motion, repaint, and the wrapper's cut](#motion-repaint-and-the-wrappers-cut) — what viddy/watch/borders take before you draw
- [Nerd Fonts](#nerd-fonts)

## Width correctness

The single most common cause of an ugly pane. `len()` is never display width:

| String | `len()` | Columns | Why |
|---|---|---|---|
| `⛔ blocked` | 9 | **10** | U+26D4 is East-Asian-Width **W** |
| `⚡ hot` | 5 | **6** | U+26A1 is W |
| `日本語` | 3 | **6** | CJK ideographs are W |
| `⚠` vs `⚠️` | 1 vs 2 | **1 vs 2** | U+FE0F (VS16) promotes to 2 columns |
| `🧑‍🌾` | 3 | **2** | ZWJ sequence renders as one glyph |
| `🇯🇵` | 2 | **2** | regional-indicator pair = one flag |
| `\x1b[38;5;114mOK\x1b[0m` | 17 | **2** | escapes are invisible |

Use the kit: `vlen()` to measure, `pad()` to align, `trunc()` to cut. All three are
grapheme-aware, clamp every cluster to at most 2 columns, and treat escapes as zero width.

**Stripping ANSI is not just SGR.** A pattern like `\x1b\[[0-9;]*m` misses cursor moves, erases,
and — the one that really hurts — OSC-8 hyperlinks, whose visible text is a few characters but
whose wrapper is ~30 bytes. `ANSI_RE` in the kit covers CSI *and* OSC.

### East Asian Width "Ambiguous" — the hidden hazard

Box-drawing and block characters are EAW=**A**. They are 1 column in a Western locale and **2** in
a CJK locale, with iTerm2's "ambiguous-width = double" setting, or on a CJK Windows Terminal.

```
─ 2500 A    │ 2502 A    ╭ 256D A    █ 2588 A    ▌ 258C A
● 25CF A    • 2022 A    → 2192 A    ★ 2605 A    ▒ 2592 A
▣ 25A3 A    ▓ 2593 A    ○ 25CB A  ← the block/ring set a status glyph reaches for
░ 2591 N  ← inconsistent with ▒, so a shade ramp can misalign against itself
```

There is no fix inside the string. Ship an ASCII border mode and select it at setup:

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/renderer_template.py" demo --ascii   # or TMUX_DESIGN_BORDER=ascii
```

**Prefer EAW=N marks for fixed-width slots** — they are 1 column everywhere:
`✓ 2713` `✗ 2717` `✔ 2714` `✘ 2718` `❯ 276F` `▸ 25B8` `› 203A` `» 00BB` `▪ 25AA` `⚠ 26A0`
`↳ 21B3` `☐ 2610` `☑ 2611` `∅ 2205` `◉ 25C9` `▰ 25B0` `▱ 25B1` `▬ 25AC`

Check anything before adopting it — reject `A`, `W`, `F`:
```bash
python3 -c "import unicodedata as u; print(u.east_asian_width(chr(0x2713)))"
```

### Emoji

Terminals genuinely disagree, and no library can paper over it. VS16 is handled correctly by only
about 7 of 23 terminals tested; ZWJ sequences render as 2 columns in Ghostty/foot/iTerm2/WezTerm
but 4–6 in Alacritty/kitty/GNOME Terminal/Windows Terminal. VS Code's xterm.js only knows Unicode
12.1, so anything newer measures wrong.

**Rule: emoji only in a trailing column where a one-cell error costs nothing.** For anything
inside a table, use the EAW=N marks above or a Nerd Font glyph.

### Untrusted text

Strip bidi controls and C0/C1 before laying out anything from a branch name, log line, commit
message, or filename. A stray U+202E measures zero columns and visually reverses the rest of the
row — a layout bug *and* a spoofing vector. `sanitize()` does this while preserving ZWJ.

## Tables

The idiom, which `table()` implements:

- **Bold header row** in the `head` role, with a thin `border`-colored rule beneath it. The rule is
  the cheapest possible separator — a full grid costs a column per boundary and buys nothing.
- **Two-space column gaps.** One space reads as a single run-on token; three wastes a narrow pane.
- **Right-align numerics** (`ralign={2, 3}`) so magnitudes line up on the decimal and the eye can
  compare column-wise without reading.
- **Normalize numbers before padding** — `num()` strips exchange-style trailing zeros
  (`60800.00000000` → `60800`). Negative money reads `-$150.78`, never `$-150.78`.
- **Pass `width`** when the pane is tight. `table()` then trims its widest column until the row
  fits rather than letting the terminal fold every line — one truncated cell beats a wrapped table.
- **Never `str.ljust`** on a cell that may contain color; use `pad()`, which measures columns.

Reach for `kv()` instead when there is one row: a one-row table is over-decoration.

## Frames and dividers

```
light    ─ │ ┌ ┐ └ ┘   ├ ┤ ┬ ┴ ┼        rounded  ╭ ╮ ╰ ╯   (light weight only)
heavy    ━ ┃ ┏ ┓ ┗ ┛   ┣ ┫ ┳ ┻ ╋        double   ═ ║ ╔ ╗ ╚ ╝   ╠ ╣ ╦ ╩ ╬
dashed   ╌ ┄ ┈ (h)  ╎ ┆ ┊ (v)           ascii    - | + + + +
```

- **Weights never mix.** There are no glyphs joining light to heavy to double.
- **Rounded corners exist only in light weight.**
- Code point order is `╭ ╮ ╯ ╰` (256D–2570), *not* reading order. Getting this backwards produces
  a subtly wrong box.

Choose by cost: a `panel()` costs 2 columns and 2 rows; a `divider()` costs 1 row and groups just
as well. In a short pane, prefer dividers. Reach for a panel only when the grouping needs to be
unmistakable — a frame around every section is visual noise, not structure.

```python
divider("throughput")                       # labelled rule
panel([line1, line2], heading="palette")    # framed block
```

### `spread(left, right)` — a two-sided title/header row

`divider()`'s label is centered and drawn in the border character; `spread()` is the plain-text
sibling for "left … right, filled to a guaranteed minimum gap" — a pane title on the left, a
`freshness()` stamp or countdown on the right:

```python
spread(c(MUTED, "orders · staging"), freshness(12, "14:32"))
# orders · staging                                              ● 14:32 (12s ago)
```

RIGHT is the live value and is never dropped to make room; LEFT truncates first (down to nothing
if it must). `fill` defaults to a plain space — pass an EAW=**N** mark instead of a box-drawing
character if you want a filled rule (`─` measures 1 column by this kit's own width model but may
still render 2-wide in a CJK-locale terminal, same caveat as everywhere else on this page).

## Bars, sparklines, gauges

Three different questions; do not substitute one for another.

### `bar(pct, width)` — "how much is done?"

Horizontal eighth-blocks, **descending** code points U+258F → U+2588:
```
▏ 258F  ▎ 258E  ▍ 258D  ▌ 258C  ▋ 258B  ▊ 258A  ▉ 2589  █ 2588
```
Sub-cell resolution is what lets a 20-column bar show real movement instead of a stuck block —
it has the precision of a 160-column one. Compute `full = int(pct*W)` and `eighths = round((pct*W - full) * 8)`, then append
`_HBLOCKS[eighths - 1]` when `eighths` is non-zero — the set is 1-indexed by eighths, so subtracting
one is what maps 1→`▏` and 8→`█`. (When `eighths` rounds up to 8, carry it into `full` instead.)

### `sparkline(values)` — "which way is it going?"

Vertical eighth-blocks, **ascending** code points U+2581 → U+2588:
```
▁ 2581  ▂ 2582  ▃ 2583  ▄ 2584  ▅ 2585  ▆ 2586  ▇ 2587  █ 2588
```
**The ascending/descending asymmetry between these two sets is a classic off-by-one.** Use a
*space* for a true zero — `▁` already shows ink and reads as "small but present" when the value is
actually nothing.

### `gauge(pct)` — "how close is it?"

Deliberately inverted: 0% renders full, `span`% renders empty, with heat coloring. Predates the
other two and is kept because proximity and progress are genuinely different instruments. Don't
replace a `bar()` with it or the reader will misread the direction.

## Marks, badges, banners

- **`badge(text, role)`** — a filled chip (`bg=role`). Scans faster than colored text down a
  column because the eye finds the block before it reads the word. Degrades to `[text]`.
- **`kv(pairs)`** — aligned label/value lines. The right answer for single-value readouts; a
  one-row table is over-decoration.
- **`freshness(age_s)`** — colored heartbeat with `(Xm ago)`. The fastest way to notice a pane has
  silently died, which is otherwise invisible when the last render still looks plausible.
- **`none_line()`** — `∅ none` in dim. An empty section must still say so; a blank gap reads as a
  broken renderer.

**Banners**: a `▌ TITLE` line plus a `divider()` is enough and costs nothing. `figlet` is optional
and often absent — check `command -v figlet` first. If you want one, `-f smslant` is 4 rows and
ships by default; **Calvin S** is 3 rows drawn from `╔═╗║╚╝`, so it visually matches box borders.
Never pipe figlet through `lolcat` into anything width-aware — see rule 4 in the skill.

## Motion, repaint, and the wrapper's cut

- **Spinners are illegal under `viddy`** and in any non-tty. viddy owns the redraw; a spinner
  underneath it fights for the same cells. Spinners belong only in foreground interactive scripts,
  gated on `[ -t 1 ]`.
- **The wrapper owns the pane; your renderer gets what's left.** `#{pane_width}x#{pane_height}` is
  the pane, and every refresher recommended here keeps some of it. Budget from the remainder, not
  from the pane, or a table sized "to fit" wraps and the wrapped rows push the content further out
  of view:

  | Surface | Its cut | Lever |
  |---|---|---|
  | `viddy` (default header) | 3 rows header + 1 row key bar; 1 column right | `-t` drops the header |
  | `viddy -t` | 1 row key bar; 1 column right | — |
  | `viddy -w` (no wrap) | + 1 row when content is wider than the content area | keep content narrower |
  | `watch -c` | 2 rows of header | `-t` |
  | `lnav` | its own top and bottom status lines | measure |
  | `pane-border-status top` | 1 row **per pane** | `off` |

  So a default-header viddy pane gives you `pane_width - 1` columns × `pane_height - 4` rows.
- **A renderer that owns its own loop has no wrapper cut** — its only external cost is
  `pane-border-status`. Budget it as `pane_height − (header rows + margin)`, deriving the header
  total from the glyph's own row count rather than writing it as a literal, and derive it **once**.
  That total is consumed in more than one place — the value the renderer publishes for its body,
  and the row limit the body renderer is called with — so the same number written twice
  misdimensions the body the first time a row is added or cut, silently and only at some pane
  heights.
- **viddy's scrollbar column arrives one line earlier than "overflow" suggests.** Measured on
  viddy 1.3.1: with a 20-row content area, 19 rows of content draw at full width and 20 rows put
  `↑ ║ … ↓` in the last column — it appears as soon as content *reaches* the content area, not
  after it exceeds it. This is worth budgeting unconditionally rather than "only when long",
  because the failure feeds itself: lines written to the full pane width wrap the moment the
  scrollbar takes that column, wrapping adds rows, and the extra rows keep the scrollbar there.
  Reserve the column and none of it starts.
- **Measure after loading chrome, not before.** `pane-border-status top` costs a row per pane and
  the theme generator sets it, so a height measured before the theme loads is one row too generous
  for every pane. `#{pane_height}` reports the true post-border size once it's on.
- **Numbers age; the probe doesn't.** These are one viddy release. To re-measure any wrapper, run
  it in the sandbox from `console`'s verify loop against a renderer that prints numbered
  full-width lines, and count what survives.
- **Synchronized output** removes tearing on a full-frame repaint. Wrap the whole frame:
  ```bash
  printf '\033[?2026h'; render; printf '\033[?2026l'
  ```
  Without it the emulator may paint mid-write, showing half old and half new content. Free where
  supported, silently ignored where not. tmux gained app→tmux mode 2026 in **3.7**.
- **Never `clear`.** That blank frame between redraws *is* the flicker, and it destroys scrollback.
  Full-canvas work belongs in the alternate screen (`\033[?1049h` / `\033[?1049l`, restored with a
  `trap`) or, better, a `display-popup`.

### Status-driven animated glyphs (the renderer owns the loop)

Everything above assumes a refresher owns the redraw. A renderer may own it instead — a continuous
paint loop replacing `viddy` — but only when **motion carries data** *and* the paint cadence must
exceed the data cadence. Both, or use `viddy`: motion that isn't reporting anything is decoration,
and decoration doesn't justify owning a redraw.

**The idiom.** Draw a small glyph shaped like the thing being monitored — a cell grid for a cluster
of tasks, a line of nodes for a pipeline. Structure (borders, connectors) keeps a fixed accent
color; only the *living* parts take a status color, and the **rate** of their motion encodes
urgency: fastest at worst, slowest at healthy. The reader then gets state from motion before
reading a word, which is the entire justification. A glyph whose speed never changes is decoration
wearing a status costume.

**Derive aggregate status as the worst of each entity's own current state** — never by grepping the
rendered frame for a status color. A pane that shows history (a strip of recent results per entity)
keeps past failures on screen, so a frame-wide grep reports the worst thing that *ever* happened
and the glyph never recovers.

**Where motion may live.** In dedicated chrome (a header glyph, a countdown bar), or *inside a mark
that already carries meaning* — swapping a status dot between two shapes so it breathes. Motion
occupying its own cells beside data rows gets cut: it competes with the reader's actual target.
Every layer added or cut moves the chrome math, which is why the row total above is derived once
rather than written twice.

**Two clocks, never one.** Fetch on the slow cadence into a file, with an atomic rename so a
half-written frame is never read (the caching idiom in `tmux-chrome.md`); paint on the fast one, and
never let the paint loop trigger a fetch. Paint both waiting states explicitly — a refresh in
flight over a good cache, and a cold start with no cache — because painting nothing while a fetch
runs is indistinguishable from the loop having died.

**Motion and `freshness()` answer different questions.** Motion says *the monitor is alive*;
`freshness()` says *the data is fresh*. Under two clocks a live loop will happily paint an hour-old
cache and look perfectly healthy, so keep both.

**A spinner is legal here.** The rule above bans spinners *under `viddy`*, and its stated exception
is foreground scripts on a real tty — a respawned loop owning its pane is that case. Nothing
underneath is competing for the cells.

Requirements of owning the loop:

- **Home and overwrite; never `clear`** (above). `console`'s `tput cup 0 0` / `tput ed` fallback is
  the same move; the refinement is a per-line erase-to-EOL plus one erase-below at the end, so a
  frame that shrinks doesn't leave the previous frame's tail on screen.
- **Stay on the normal screen.** Full-canvas work belongs in the alternate screen (above) — a
  persistent pane does not, because its scrollback and `capture-pane` have to see the frame.
- **Wrap each frame in synchronized output** (above). A sub-second full-frame repaint is the
  highest tearing-risk surface in this guide; it composes with home-and-overwrite rather than
  replacing it, so this is not a choice between recipes.
- **Stop painting when the window is inactive** (`#{window_active}`) while still refreshing data —
  animating a pane nobody is looking at burns a core to no effect.
- **Refetch on resize**, so the body refits now rather than at the next slow tick.
- **Keep a one-variable path back to a static refresher.** An own loop is the most fragile thing in
  the pane; falling back to `viddy` by flipping one environment variable is what makes it safe to
  adopt.
- **Ship a one-shot frame mode** — one synchronous fetch, one paint, exit. Without it the pane
  cannot be verified at all; see `console`'s verify loop.

**Width.** The block and ring glyphs this idiom reaches for are mostly EAW=**A** ("Width
correctness" above), so a glyph drawn to an exact column count breaks that contract in a CJK
locale. And the two states of a breathing mark must come from the *same* EAW class: `●`→`◉` does
not — `● 25CF` is A, `◉ 25C9` is N — so the row narrows by a column every other frame. Take both
states from the N list, or use the ASCII mode.

## Nerd Fonts

PUA glyphs are **width 1 in every implementation**, which is exactly why they beat emoji for
decoration. But a missing glyph renders as tofu, a blank, or a 2-column box depending on the
terminal — **you cannot detect it from the output**. So treat them as progressive enhancement:
gate on an explicit opt-in (`--nerd`, `NERD_FONT=1`) with an ASCII fallback table, the way
starship, powerlevel10k and eza do. Never probe per render.

Powerline set, worth memorizing:
```
 E0A0 branch     E0B0 right hard divider     E0B2 left hard
 E0A1 line no.   E0B1 right soft divider     E0B3 left soft
 E0A2 padlock    E0B4/E0B6 half-circles (the "pill" look)
```
Grammar: **hard dividers between different-colored segments, soft dividers within one color.**

Current ranges (v3.x — v2-era values are widely quoted online and are wrong):
`nf-pl-` E0A0–E0A2/E0B0–E0B3 · `nf-cod-` EA60–EC1E · `nf-fa-` ED00–F2FF · `nf-dev-` E700–E8EF ·
`nf-oct-` F400–F533 · `nf-md-` **F0001–F1AF0**. The v3.0 remap moved Material Design icons out of
the old `F500–FD46` BMP range (it collided with real CJK), so the symptom of a stale config is
*only* the Material icons showing tofu. Prefer BMP sets for compatibility — MDI is Plane 15 and
some terminals can't render it at all.

Four sets use real assigned Unicode, so watch their width: `☰ 2630` and `⚡ 26A1` are **W (2
columns)**; `♥ 2665` and `⭘ 2B58` are Ambiguous. Everything in the PUA is width 1.

```bash
fc-list :charset=e0b0 family          # does any font cover U+E0B0?
brew install --cask font-symbols-only-nerd-font   # fallback font, no patching needed
```
The modern setup is a symbols-only fallback font rather than a patched text font — keep your
preferred font and let the terminal fall back for PUA ranges.
