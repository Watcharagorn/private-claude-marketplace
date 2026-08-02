# Tooling — when to reach past the stdlib

Read before using any external formatter. The bundled Python kit is the guaranteed path; these
tools are an upgrade for machines that already have them, never a dependency a pane depends on.

```bash
command -v gum glow bat rich jq figlet chafa    # probe first, always
```

## The force-color rule

This is why "use gum" fails in practice. **A pane renderer's stdout is not a terminal**, so every
one of these tools strips color unless told otherwise — and the variable differs by ecosystem:

| Variable | Applies to | Effect |
|---|---|---|
| **`CLICOLOR_FORCE=1`** | Go / Charm (gum, glow), BSD tools | keep color when piped |
| `FORCE_COLOR=1\|2\|3` | Node (chalk, boxen, ora) | 16 / 256 / truecolor |
| `NO_COLOR` (non-empty) | everything well-behaved | **off, beats both of the above** |
| `CLICOLOR=0` | BSD | off |

**`FORCE_COLOR` does nothing for gum.** Setting it and seeing color vanish is the single most
common confusion here.

Verified behavior for `gum style` when piped:

| Condition | Result |
|---|---|
| no env | color **stripped** |
| `FORCE_COLOR=1` | color **stripped** ← the trap |
| `CLICOLOR_FORCE=1` | color **kept** |
| `TERM=dumb` + `CLICOLOR_FORCE=1` | color **kept** |

**Better than any env var**: write to the pane's TTY, and stdout genuinely *is* a terminal, so
color *and* width auto-detect correctly with no configuration:

```bash
printf '…' > "$(tmux display -p -t <target> '#{pane_tty}')"
```

## TTY safety

Anything that opens `/dev/tty` dies in a non-interactive context with `could not open a new TTY`.

| Safe non-interactively | Requires a real TTY |
|---|---|
| `gum style`, `gum join`, `gum format`, `gum log`, `gum table --print` | `gum choose/filter/confirm/input/write/file/pager` |
| `glow -s dark`, `bat -f`, `rich --force-terminal`, `starship prompt` | `fzf`, `tv`, `lazygit`, `btop`, and every full-screen TUI |

The TTY-requiring set is fine inside `tmux display-popup`, which provides one.

## gum

```bash
gum style --border rounded --border-foreground 99 --padding "1 2" --width 40 --align center "Deploy OK"
gum format -t template '{{ Foreground "82" "✔" }} ok  {{ Faint "(3.2s)" }}'; echo
gum log -l warn --time kitchen --prefix build "retrying" attempt 2
gum join --horizontal "$(gum style --border normal a)" "$(gum style --border normal b)"
```

Gotchas, all of which produce silently wrong layout:

- **`--width` is the INNER width; the border adds 2.** `--width 60 --border rounded` occupies 62
  columns. Compute `INNER=$((pane_width - 2))`.
- **`--strip-ansi` defaults ON for stdin** — piping already-colored text into `gum style` kills the
  color. Pass `--no-strip-ansi`. Width math stays correct either way (lipgloss is ANSI-aware).
- **`--align` is horizontal only.** `top`/`middle` silently render as left.
- `--padding`/`--margin` are CSS shorthand: `"2"`, `"1 4"`, `"1 2 3"`, `"1 2 3 4"`.
- **`gum format -t template` emits no trailing newline** — the only subcommand that doesn't.
  Append `; echo`.
- **`gum log` writes to stderr.** Redirect with `2>&1` if you're capturing.
- `gum table --print` ignores `--widths`, ignores `--header.foreground`, and always renders the
  first data row in the interactive "selected" style. For real tables use the kit's `table()`.

Template functions that exist: `Bold Faint Italic Underline Overline Blink Reverse CrossOut`
`Color "<fg>" "<bg>" "text"` `Foreground` `Background`. `Strikethrough`, `Width`, `Align` and
`repeat` do **not** exist as template functions.

Every flag has an env var, so a script can be themed once:
```bash
export CLICOLOR_FORCE=1 BORDER=rounded BORDER_FOREGROUND=99 PADDING="0 2" WIDTH=30
gum style "themed by env"
```

## glow

```bash
glow -s dark -w 72 README.md
```

- Built-in styles are exactly: `auto dark light notty ascii dracula tokyo-night pink`.
  **`catppuccin`, `nord`, `gruvbox` and `solarized` do not exist**, despite being widely claimed
  online. Passing an unknown name does not error loudly enough to notice.
- **`GLAMOUR_STYLE` is not honored by the glow CLI** (it works in the glamour Go library). Always
  pass `-s` explicitly. `-s auto` resolves to `notty` when piped — i.e. no color.
- Default non-TTY width is 78 and **`COLUMNS` is ignored** — pass `-w N`.

## bat, rich, others

```bash
bat -f --paging=never --terminal-width 80 file.py    # -f = --decorations=always --color=always
rich "text" --print --panel rounded --force-terminal
delta --color-only --paging=never                    # diffs
eza --color=always --icons=always
chafa -f symbols -s 80x24 image.png                  # explicit size required when piped
```

```python
from rich.console import Console
console = Console(force_terminal=True, width=80)     # BOTH are required when piping
```

`rich.box` styles: `ASCII SQUARE MINIMAL SIMPLE HORIZONTALS ROUNDED HEAVY HEAVY_EDGE HEAVY_HEAD
DOUBLE DOUBLE_EDGE MARKDOWN` (and variants).

## Degradation ladder

When a tool is missing, step down rather than failing:

1. The bundled kit (`renderer_template.py`) — always available, stdlib only.
2. Hand-built Unicode frames — available whenever the locale is UTF-8.
3. Pure ASCII `+ - |` — when `locale charmap` is not UTF-8, or in a CJK locale where box-drawing
   characters are double-width (see `primitives.md`).

```bash
[ "$(locale charmap 2>/dev/null)" = "UTF-8" ] || export TMUX_DESIGN_BORDER=ascii
```

## Anti-patterns

- **Colorizing before laying out.** `figlet X | lolcat | boxes` is broken by construction: lolcat
  emits a color sequence per character, so a 40-column line becomes ~800 bytes and every
  width-aware tool downstream — `boxes`, `column`, `fold`, `gum` — computes nonsense. Colorize
  last, always. `cfonts --gradient` is the better choice when you want a gradient, because it
  colors *and* lays out in one pass.
- **`boxes` measures bytes, not display cells** — emoji or CJK inside will misalign its right edge.
- **Emitting kitty graphics inside tmux.** tmux does not support the protocol (issue #4902 open).
  `allow-passthrough` pushes the bytes through, but tmux does not know those cells are occupied, so
  the image doesn't scroll, doesn't survive a redraw, and leaks across panes. Use
  `chafa -f symbols` — text cells tmux fully understands, and they stay scrollable and copyable.
- **Assuming the tool exists.** `figlet`, `boxes`, `chafa`, `lolcat`, `viddy` and `lnav` are
  frequently absent. Probe, then degrade.
- **ANSI leaking into logs or CI.** Decorated output is not greppable. Keep machine-readable output
  plain (or offer `--json`) and put decoration on the human path.
