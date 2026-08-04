# Verifying the pane shapes the plain loop can't reach

The verify loop in `SKILL.md` ("The verify loop") assumes a pane that settles: render it, sample it,
compare. Three of rule 2's shapes never settle, and each one breaks a different step of the loop —
so each gets its own procedure here. **Every "step N" below refers to that loop's numbered steps**
(1 sandbox, 2 width/resize, 3 respawn every pane the edit reaches, 4 verify live, 5 siblings after a
split).

Read the subsection matching the pane you are verifying:

| Pane shape | Why the plain loop fails | Subsection |
|---|---|---|
| Renderer owns its own paint loop | nothing stable to sample; `#{pane_current_command}` is never `viddy` | [Own-loop](#verifying-an-own-loop-pane) |
| Repaints on typed input (gum prompts, menu loops) | the frame is a function of what has been typed | [Keystroke-driven](#verifying-a-keystroke-driven-pane) |
| A `bind-key` that changes what a pane shows | the binding lives in the client's key dispatch, which no `send-keys` at the pane can reach | [Pane keybinding](#verifying-a-pane-keybinding) |

## Verifying an own-loop pane

A pane whose renderer owns its own paint loop (rule 2) never settles, so three things above change:

- **Step 1 has nothing stable to sample.** Capturing after a sleep returns whichever animation
  frame happened to be on screen — a different one each run, so there is nothing to diff. Such a
  renderer must ship a **one-shot frame mode** (`<renderer> --frame <name>`, or an equivalent env
  flag: one synchronous fetch, one paint, exit); that is the artifact to sandbox. Because it exits
  by itself, the `| cat; sleep 60` + `sleep 5` scaffolding collapses to `| cat` and an immediate
  capture — keep the `| cat`, for the same reason as above.
- **The one-shot must bypass the viewer gate.** A sandbox session is detached and nothing is attached
  to it, so `#{window_active_clients}` is 0 (measured, 3.7b) and a loop that declines to paint when
  nobody is viewing paints *nothing* here: the capture comes back empty **and exits 0**, a
  pass-shaped failure in the one step meant to catch it. Gate that skip on "not one-shot".
  This is also the sharpest argument for `primitives.md` gating on the viewer count rather than
  `#{window_active}` — a detached sandbox's only window *is* its session's current window, so it reads
  `window_active=1` (measured) and a `window_active`-gated loop paints here quite happily. That
  version of the gate hides its own bug in the sandbox and ships it to the pane.
- **Step 2 measures the one-shot, and its resize half runs the loop itself.** Wherever the check
  pipes `<renderer command>` into `check_cols.py` — step 2's width sweep, and rule 7's
  foreign-language branch — an own-loop renderer **hangs** it: the check reads stdin to EOF and the
  loop never closes it. Measure the one-shot mode instead, at `--reserve 0` rather than `--reserve 1`,
  because a pane with no wrapper has no scrollbar column to give back. The resize half changes target
  rather than being dropped: there is no viddy to re-wrap a stale frame, so launch the **loop** in the
  sandbox and shrink the window under it. That check is worth more than the one it replaces — a body
  that refits on the next frame is "Refetch on resize" (`primitives.md`) *verified* rather than
  remembered, and nothing else here tests it. Skipping step 2 is the likeliest failure of this whole
  shape, because following it literally hangs the call: the agent gets punished for compliance, so the
  step most often abandoned is the one this pane needs most.
- **Step 4's process assertion changes.** `#{pane_current_command}` is the loop's own process, never
  `viddy` — assert that instead, and assert the frame *differs* between two captures a second
  apart, which is the only direct evidence the loop is still running rather than stopped on a
  plausible-looking frame. **Assert both captures are non-empty before comparing them**, or the check
  inverts: two *blank* captures are equal, so a diff that finds no change reports "a live loop stopped
  on a good frame" about a pane painting nothing at all. And under a correct viewer gate the diff
  cannot hold when nobody is attached — the loop paints its first frame and then legitimately stops,
  making two captures a second apart identical *by design*. So when `#{window_active_clients}` is 0,
  take liveness from `freshness()` or the cache file's mtime across its atomic rename, exactly as
  step 4 does for a two-clock pane, and take the frame diff in the sandbox where the loop runs under a
  shrink. An assertion that cannot pass is the one that gets abandoned — the argument step 2 makes
  about itself above. **Verifying this pane in the user's live session has its own procedure**, below,
  because that is where the gate turns into a blank capture.

If Ctrl-C is wired to force an immediate refresh instead of exiting — reasonable for a monitoring
pane — then `respawn-pane`/`kill-pane` is the only way to stop it, and step 3's "Pane is dead"
caveat applies with nothing to work around it.

### Verifying an own-loop pane inside a live, multi-window session

Everything above verifies the *renderer*. Step 4 verifies *this pane*, in the user's real session, and
that is where the viewer gate turns into a blank capture. A workspace has one current window and n−1
that are not; `tmuxp load -d` leaves the whole session unviewed. A gated loop paints nothing in any of
them, and then **all three of step 4's signals agree it is healthy**: the capture is empty but exits
0, `#{pane_dead}` reads 0 because the loop is alive and waiting, and the two-capture diff finds no
change. This is the plugin's own worst case — not an error, an answer — and it is the default state of
every window an agent didn't happen to be looking at.

**Diagnose before acting.** One query separates the causes, and costs nothing:

```bash
tmux display -p -t <pane_id> \
  'dead=#{pane_dead} win=#{window_active} viewers=#{window_active_clients} attached=#{session_attached}'
```

`dead=1` is a broken renderer — step 4's existing check owns it. `viewers=0` is the gate working as
designed: not a failure, and not something to debug. Blank with `viewers` ≥ 1 and `dead=0` is the
real bug. Note the target **type** decides what `window_active` means, which is a trap worth knowing
before you read one: `-t <pane_id>` resolves against the session where that window is current, while
`-t <session>:<window>` resolves in that session — so the same window can answer 1 and 0 to the two
spellings (measured, 3.7b). A renderer asking through `$TMUX_PANE` gets the first.

**The cheapest fix is sequencing, not tmux gymnastics.** Batch step 3 by window and make the window
viewable *before* respawning the panes in it, so the first frame lands while a client is watching —
one select per window, not one per capture. Then, cheapest-first:

1. **`attached=0` → select freely.** Nothing is looking at this session, so there is no focus to
   steal. This is the normal shape for a workspace built with `tmuxp load -d`.
2. **Attached → give the window a viewer without touching the user's view, via a grouped probe.**
   `new-session -t <session>` joins the target's session group: the windows are shared, but the
   current window is per-session (`man tmux`: "The current and previous window ... remain
   independent"), so the probe can make the target window current while the user's session stays put.
   Attach a **read-only** client to the probe and the window has a viewer:
   ```bash
   win='<session>:<window>'
   tmux new-session -d -s _tdprobe -t '<session>'   # shares windows; its current window is its own
   tmux set -w -t "$win" window-size manual         # BEFORE the client — see below
   tmux select-window -t '_tdprobe:<window>'        # only the PROBE's current window moves
   tmux -L _tdprobe_view -f /dev/null new-session -d -s V -x 200 -y 50 \
     "TMUX= tmux attach -r -t _tdprobe"             # -r read-only; TMUX= or the client won't nest
   sleep 2                                          # one paint tick, not a guess at the fetch cadence
   tmux capture-pane -e -p -t <pane_id>
   tmux -L _tdprobe_view kill-server                # teardown, in this order
   tmux kill-session -t _tdprobe
   tmux set -w -t "$win" -u window-size             # the leak — never skip this
   ```
   Measured end to end on 3.7b: during the probe the window reads `window_active_clients=1` while the
   user's session's current window is **unchanged**, and afterwards the window's size, its
   `window-size` option, the session's current window and the viewer count are all back exactly where
   they started. Killing a group member is safe (`man tmux`: any session in a group may be killed
   without affecting the others). Because a pane target resolves to the session where its window is
   current, `display -p -t <pane_id> '#{window_active}'` also answers **1** here — so this route
   unblanks a loop gated either way, including a renderer you can't edit.

   Two lines are load-bearing and both fail quietly:
   - **`window-size manual`, set before the client attaches.** `-r` is *not* the size lever here — a
     read-only 200×50 client still resized an 80×24 shared window to 200×49, and it did **not** revert
     when the client died (measured, 3.7b). On a grouped session that reflows a window the user's
     session shares, so every later capture answers a question about a width nobody asked for. This is
     the same hazard the keybinding subsection documents below, and sizing the viewer to match doesn't
     dodge it either: an exactly-matched client still costs a row to its own status line (80×24 →
     80×23, measured).
   - **`set -w -u window-size` on teardown.** The option is a **window** option and the window is
     shared, so it outlives the probe: measured, it was still `manual` on the user's window after the
     probe session was killed, having been unset before. Fixing a blank capture by permanently
     changing how the user's window resizes is not a fix.
3. **Focus theft, last** — for a session you can't probe. Record the current window, select the
   target, wait one paint tick, capture, restore, **all in one bash invocation**: a capture that fails
   between the select and the restore leaves the user's focus parked on a pane they weren't looking
   at, which is how the improvised version of this ends. Record and restore by **id** (`#{window_id}`
   `@N`), never name or index — session and window targets prefix-match and glob (`=` forces exact),
   and indexes shift under `renumber-windows` or a window the user opens mid-probe.
   ```bash
   orig=$(tmux display -p -t '<session>' '#{window_id}')
   tmux select-window -t '<session>:<window>'
   sleep 2 && tmux capture-pane -e -p -t <pane_id>
   tmux select-window -t "$orig"
   ```
   Name its costs rather than implying a clean revert. **`last-window` is rewritten**: measured on
   3.7b, select→restore moves the last-window flag onto the window you probed, so the user's
   `prefix-l` now goes there; restoring that too means `select-window <orig_last>; select-window
   <orig>`, which clears alerts on a third window — say the cost, don't hide it. **Every attached
   client jumps**, which is the whole reason this ranks last. What you *don't* owe is a pane restore:
   each window keeps its own active-pane pointer and `select-window` doesn't touch it (measured —
   away and back left the active pane where it was). Only a `select-pane` owes one, which is why the
   keybinding subsection below restores it.

## Verifying a keystroke-driven pane

Rule 2's third shape can't be verified by capturing a settled frame — what it shows depends on what
has been typed, so you have to drive it. `send-keys` is the only way in: the widgets these panes are
built from read their keys from the terminal rather than stdin, so nothing can be piped at them (the
"TTY safety" table in `decorate/references/tooling.md` has which gum commands this hits). That does
not undo step 3's prohibition — driving a program that is already reading is fine; using `send-keys`
to *restart* one is what gets swallowed mid-child-call and lands as inert text.

Drive it on step 1's isolated server, and point it at a **scratch copy of the datastore**. This is
the only step in the whole loop that writes, so aiming it at the real file means the verification
mutates the thing it was verifying.

```bash
scratch="$(mktemp)"; cp <the real datastore> "$scratch"   # verification writes — never to the original
sbx() { tmux -L _tmuxdesign_sbx "$@"; }
await() {   # await <marker> — no -e here: SGR bytes can split a marker mid-word
  for _ in $(seq 40); do
    sbx capture-pane -p -t _sbx | grep -qF "$1" && return 0
    sleep 0.25
  done
  echo "timeout waiting for: $1" >&2; sbx capture-pane -e -p -t _sbx >&2; return 1
}
sbx -f /dev/null new-session -d -s _sbx -x 100 -y 30 \
  "<tui command, its datastore pointed at $scratch>; echo __DONE__; sleep 60"
await 'Title:' && sbx send-keys -t _sbx -l 'buy milk' && sbx send-keys -t _sbx Enter
await __DONE__ && grep -q 'buy milk' "$scratch"      # the write, not the frame
sbx kill-server
```

**Poll, don't sleep.** A hand-picked `sleep` is guesswork that passes on a fast machine and lands the
next keystroke in the wrong prompt on a slow one, and the run still reports a pass — so `await` has
to *fail* at its timeout rather than fall through. `grep -qF`, not `grep -q`, because prompts
routinely contain `?`, `[` and `(`. And `; echo __DONE__; sleep 60` is there for step 1's reason: the
TUI exits, tmux tears the session down with it, and the final assertion races a pane that no longer
exists — the marker gives you something to wait for and the sleep holds the session open to read it.

Assert the **side effect**, not the frame: a TUI paints a plausible "saved" frame whether or not the
write landed, and the datastore row is the only evidence that it did.

### Rule 4 still applies, and here a one-shot dump is the only way to check it

SKILL.md binds this shape to rules 1, 3, 4 and 5, but everything above verifies the *write* — nothing
measures the **columns**, and for this shape there is no other route to them. The renderer paints
through the tty rather than stdout, so `<renderer> | check_cols.py` receives nothing; and a
`capture-pane` capture cannot stand in, because the pane's screen grid is already hard-wrapped at
pane width, so every line fits by construction (`check_cols.py`'s own scope note says feed it the
renderer's stdout, never a capture). So a keystroke-driven TUI **owes a one-shot dump mode** for the
same reason an own-loop renderer owes a one-shot frame mode — and it is checked the same way:

```bash
w=100
<tui> --dump --width "$w" | python3 "${CLAUDE_PLUGIN_ROOT}/scripts/check_cols.py" "$w" --reserve 0
WIDTH_FIXTURE='⛔ blocked  日本語製品  🧑‍🌾 farmer' \
  <tui> --dump --width "$w" | python3 "${CLAUDE_PLUGIN_ROOT}/scripts/check_cols.py" "$w" --reserve 0
a=$(<tui> --dump --width 60 | wc -l); b=$(<tui> --dump --width 160 | wc -l)
[ -n "$a" ] && [ "$a" -gt 0 ] || echo "EMPTY DUMP — the sweep proved nothing"
```

Five things that make this a real check rather than a second one that always passes:

- **The dump writes composed rows to plain stdout, bypassing curses entirely** — the same strings the
  paint path hands to `addstr`, after `pad()`/`trunc()`. A `--dump` that re-implements the layout is
  a second renderer measuring itself, and the pane keeps its crooked columns.
- **`--reserve 0`, not step 2's `--reserve 1`.** This shape has no wrapper, so there is no scrollbar
  column to give back — the same reasoning the own-loop subsection spells out.
- **Assert the dump is non-empty.** `check_cols.py` exits 0 on zero lines (measured), so a `--dump`
  that no-ops without a tty passes the entire sweep in silence — this shape's version of the
  own-loop's empty-capture trap.
- **The width comes from an argument, not from `curses.COLS`.** Curses reads the terminal; a dump
  that ignores the knob measures one width three times and reports a sweep it never ran.
- **`WIDTH_FIXTURE` is mandatory here, not optional.** A tree of ASCII task names fits 60/100/160 by
  construction whatever the width model is, so the wide-glyph row is the entire value of the sweep.
  Have the dump take a selection/expansion state too, or it only ever measures the initial collapsed
  view — and the deepest view is the one whose columns are tightest.

### What a curses TUI does to the capture — measured, tmux 3.7b

`curses.initscr()` puts the pane on the **alternate screen**, which `primitives.md`'s "stay on the
normal screen" rule warns about. Measured rather than assumed, the split is not what that rule's
phrasing suggests:

- **`capture-pane -p` and `-e` both work.** `-e` returns real SGR bytes
  (`\033[1m\033[38;5;212m…`), so rule 3 *is* checkable on this shape — assert color at a settled
  prompt rather than trusting that the TUI emits it.
- **Scrollback is gone.** `#{alternate_on}` is 1, `#{history_size}` is 0, and `capture-pane -S -100`
  returns only the visible rows. Anything that reaches back through history — diffing against an
  earlier frame, reading a message the TUI printed before it initialized — has nothing to read.
- **`#{pane_current_command}` reads the shell, not the TUI, under this section's own scaffolding.**
  Launched with `exec` it answers `Python`; launched as `<tui>; echo __DONE__; sleep 60` — the form
  prescribed above, which exists so the marker survives the exit — it answers `zsh`. So step 4's
  process assertion is inert here by construction. Assert the frame and the side effect instead, and
  don't read a shell name as evidence the TUI died.

## Verifying a pane keybinding

A `bind-key` lives in the **client's** key dispatch, not in the pane's stdin, so nothing in the loop
above reaches it and `send-keys` aimed at the session under test cannot fire it: `send-keys -t
<target> C-b` then `h` writes two bytes to whatever the pane is running, the binding never runs, and
both sends exit 0 (measured, 3.7b) — a pass-shaped failure in the only step that could have caught
it. `list-keys` is no substitute here; in the sandbox it proves the bind took, not that pressing the
key does anything. Drive it through a real attached client:

```bash
sbx()  { tmux -L _tmuxdesign_sbx  "$@"; }
view() { tmux -L _tmuxdesign_view "$@"; }             # a second server holding nothing but the client
pane=_sbx:<win>.<idx>
await_opt() {   # the previous subsection's await, watching an option instead of a frame
  for _ in $(seq 40); do
    [ "$(sbx show -p -v -t "$pane" "$1" 2>/dev/null)" = "$2" ] && return 0
    sleep 0.25
  done
  echo "timeout: $1 never became $2" >&2; sbx capture-pane -e -p -t "$pane" >&2; return 1
}
sbx set -g window-size manual                          # or the client's size silently becomes the pane's
sbx source-file <the repo file holding the bind-key>   # step 1's -f /dev/null means it isn't loaded yet
view -f /dev/null new-session -d -s _view -x 200 -y 50 \
  "TMUX= tmux -L _tmuxdesign_sbx attach -t _sbx"       # TMUX= or the client refuses to nest
sleep 1
sbx select-pane -t "$pane"                             # #{pane_id} resolves against the ACTIVE pane
p=$(sbx show -gv prefix)                               # read the prefix; never hardcode C-b
view send-keys -t _view "$p" && sleep 0.3 && view send-keys -t _view h
await_opt @<mode> tree && sbx capture-pane -e -p -t "$pane" | head -5
view kill-server; sbx kill-server
```

Every line there is load-bearing, and each one fails quietly:

- **`TMUX=`.** A client launched inside a tmux pane refuses to nest, and the session created to hold
  it dies with it — ask a second later and tmux answers `can't find session`, so the capture races a
  client that never existed. Same clearing the chrome probe in
  `decorate/references/tmux-chrome.md` does, for the same reason.
- **A second socket, and never the ambient server.** A viewer on the user's live server does work,
  and leaks a session into their workspace — the leak step 1's explicit `-L` exists to prevent.
  Address the viewer with the socket it lives on, too: a `-L foo` viewer poked by a bare
  `tmux send-keys -t viewer` is a different server, and on the ambient one target names
  *prefix-match*, so that stray send can land in a live session whose name merely starts the same.
- **`window-size manual`.** A 200×50 client turns a 100×30 sandbox into 200×49 and it does **not**
  revert when the client dies, so every later capture answers a question about a width nobody asked
  for. `-r` is not the lever here even though the chrome probe uses it: a read-only client dispatches
  no bindings, so the keys you send do nothing (measured) — and `ignore-size` alone doesn't hold the
  size either when it is the only client.
- **Read the prefix.** Under `prefix C-a` a hardcoded `C-b` + `h` leaves the option unset after two
  exit-0 sends — this subsection's own failure mode, reintroduced by its own first keystroke.
- **Poll, don't sleep** — for the reason the previous subsection gives; `show -p -v` on an unset user
  option exits 1, so the wait is assertable rather than eyeballed.

Assert the option the binding sets **and** that the pane changed. Either alone is pass-shaped: a
toggle whose script died leaves the previous frame on screen, and a toggle that sets the option but
fails to respawn leaves the option right and the frame stale — so take the two differing captures
"Verifying an own-loop pane" takes.

On the user's real session, don't re-send a prefix; the sandbox already proved the binding. Run what
it runs — `run-shell -t <pane> "<the binding's command verbatim>"` expands `#{pane_id}` against `-t`,
so nothing needs hand-resolving — and drop the `-b` while you do. `run-shell -b` returns 0 for a
missing script, a cleared execute bit or a crash and logs nothing to `show-messages`, which is
precisely why a keypress can never report failure; without `-b` you get 127, or the script's own exit
status, back. If the command prints anything it leaves that pane in view-mode
(`#{pane_in_mode}` → 1), which will poison the step-4 capture — `send-keys -X cancel` first, or run
the script yourself and resolve the id with `display -p -t <pane> '#{pane_id}'`.
