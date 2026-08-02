---
name: learn
description: Learn from EVERY unanalyzed session that used one plugin, across every project of the active config dir — or from ONE named session — improving the plugin with both audit + enhance lenses. With just <plugin>, discovers matching sessions across all project folders of `$cfg/projects` (usage-index fast path + scan backfill), filters already-analyzed ones via a per-plugin ledger + watermark, then processes each ONE AT A TIME, oldest first — analyze, expert-review, AUTO-implement approved improvements, COMMIT per session — publishing one release when the backlog drains (--review confirms each session, --dry-run previews; --headless processes exactly ONE session per invocation and never prompts, for the daily runner's fire-per-session loop); with <plugin> <session-id>, analyzes just that session interactively (no discovery, ledger/watermark untouched). Invoke for "learn <plugin>", "learn from all sessions that used <plugin>", "audit and enhance <plugin> from session <id>", or "/learn <plugin>". For a quick misbehavior-only pass on one session, use audit-plugin.
version: 1.1.0
---

# learn — audit + enhance one plugin from its sessions

Three related skills, one job each:

- **`audit-plugin`** — ONE session → one plugin, **AUDIT lens only** (a quick misbehavior-only fix pass).
- **`learn`** (this skill) — a plugin's sessions → one plugin, **both audit + enhance lenses**. Name only
  the plugin and it sweeps **every unanalyzed session** across all project folders, processing each in
  sequence — analyze, review, **implement automatically** — and never re-analyzing one it has seen;
  name a plugin **and a session id** and it analyzes just that **one** session interactively (skipping
  discovery and the ledger/watermark).
- **`track`** — the opt-in indexer that makes `learn`'s discovery instant (works fully without it —
  just slower).

`learn` reuses the two analysis lenses **by reference** (never re-inlined): each per-session agent reads
them straight from **`references/analysis-lenses.md`** at heading anchors — the same file `audit-plugin`
reads, so the AUDIT and ENHANCE briefs have one wording. The multi-session mechanics — marker pattern,
config-dir-wide scan, ledger + watermark, usage index — live in chassis **§K**.

Read the shared chassis first (resolve by glob, then reference §A … §K):

```bash
common="$(find .claude/skills plugins -path '*/references/session-plugin-common.md' 2>/dev/null | head -1)"
echo "${common:-NO_COMMON}"
```

## When NOT to invoke

- **A quick misbehavior-only pass on one session** (the AUDIT lens alone, no enhance) → `audit-plugin`
  (`/audit-plugin <session-id> [plugin]`). Reach for `learn <plugin> <session-id>` instead when you want
  **both** lenses on that one session.
- **Run from outside this marketplace repo.** Discovery is marketplace-agnostic, but the implement +
  publish tail writes `plugins/<plugin>/` and publishes **this** repo — run `learn` with cwd = this
  repo. A plugin tracked from another marketplace is named explicitly (Step 1) with where to run it.
- **The plugin isn't in this repo's `marketplace.json`.** Step 1 refuses it.

## Inputs

- **`$1` — plugin name** (required, e.g. `mentor`). Unqualified — the marketplace is this repo.
- **`$2` — session id / transcript path** (optional). Present → **single-session mode**: analyze only
  that one session (both lenses), **skipping discovery and leaving the ledger/watermark untouched**.
  Absent → **batch mode**: sweep every unanalyzed session (the default flow).
- **`--dry-run`** — batch mode only, Steps 1–4: discover + present candidates, **no agents, no writes**
  (no ledger, no reports). For previewing what a real run would analyze. (In single-session mode there is
  no discovery to preview, so `--dry-run` doesn't apply.)
- **`--review`** — batch mode only: pause each session for a **§I confirm** before implementing its
  approved items. Without it, batch mode implements review-approved items **automatically**.
- **`--headless`** — batch mode, for scheduled/unattended runs (see `loom:automate`): never call
  `AskUserQuestion` — dead ends stop cleanly with a message. Overrides `--review`. Headless processes
  **exactly ONE session per invocation** (the oldest eligible survivor) and reports how many remain,
  so the daily runner can fire once per session with a fresh wall-clock watchdog each time — a kill
  can then only ever cost the one in-flight session, never a finished batch.

`cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"` throughout — **not** §A's `$HOME/.claude` (see §K).

## Mode fork (strip flags FIRST, then read `$2`)

**Parse the flags before anything reads `$2`** — an unstripped `--headless` after the plugin name
would be mistaken for a session id and misroute into single-session mode:

```bash
args="$ARGUMENTS"
dry=0; review=0; headless=0
case " $args " in *" --dry-run "*)  dry=1;;      esac
case " $args " in *" --review "*)   review=1;;   esac
case " $args " in *" --headless "*) headless=1;; esac
args="$(printf '%s' "$args" | sed 's/--dry-run//; s/--review//; s/--headless//' \
       | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s/[[:space:]][[:space:]]*/ /g')"
set -- $args   # $1 = plugin, $2 = optional session id/path
echo "plugin=$1 session=${2:-} dry=$dry review=$review headless=$headless"
if [ "$headless" = 1 ]; then review=0; fi   # headless can never pause
```

- **`$2` present → single-session mode.** Do **Step 1** (validate the plugin + resolve the chassis), then
  jump to **Step 5-single** below (resolve that one transcript via §A, run one both-lens agent, review,
  confirm, implement), then **Steps 6–7** (publish, finalize). **Skip** Steps 2–4 (ledger load,
  discovery, cap) entirely — a single named run must never move the plugin-wide watermark or write the
  ledger, mirroring how `harvest-automations` single-mode leaves the watermark alone. Single-session
  mode is always **interactive** (§I confirm) — it is the manual escape hatch.
- **`$2` absent → batch mode.** Run Steps 1–7 in order, as written.

---

## Step 1 — Validate the plugin + resolve the chassis

```bash
jq -r '.plugins[].name' .claude-plugin/marketplace.json      # valid targets in THIS repo
```

`$1` unknown/missing → list the valid names and stop. If `$1` isn't in this repo's manifest **but** is
a tracked plugin from another marketplace (`$cfg/loom/learning/config.json` → `track[]`), say so
explicitly: "`<plugin>` is tracked via `<other-marketplace>` — run `/loom:learn <plugin>` from that
marketplace's repo" (tracking is marketplace-agnostic; the tail is repo-scoped). Resolve the chassis
(above) and build the §B purpose line for the target plugin.

## Step 2 — Load the ledger + usage index

```bash
mkdir -p "$cfg/loom/learning/reports"
```

Load `$cfg/loom/learning/<plugin>.json` (§K.4) and `$cfg/loom/learning/usage-index.jsonl` (§K.5).
Corrupt or unknown-`schemaVersion` ledger → move aside (`<plugin>.json.bak-<ts>`), warn, start fresh.
Print a one-line prior state: watermark, `analyzed[]` count, last run, and **whether `<plugin>` is
currently tracked** (present in `config.json`). `--dry-run` loads read-only (never creates the ledger).

## Step 3 — Discover candidate sessions (index-first, §K.1–K.3)

**Index fast path (§K.5):** for each `usage-index.jsonl` line (last-wins per sessionId) —
`plugins[<plugin>] > 0` → **candidate, no scan**; key present as `0` → **skip, no scan**; line missing
the `<plugin>` key, or no line at all → hand to the scan.

**Backfill scan (§K.2):** run the config-dir-wide scan **only** over transcripts whose sessionId is
absent-from-index-or-missing-the-target-key. Build the marker pattern with §K.1 (surface root =
`"$PWD/plugins"`, this repo).

Union the index hits and scan hits, then **filter + order per §K.3** (ledger-outcome-first
eligibility; drop the active session with the `$cfg` restatement; drop transcripts with mtime < 5 min;
namespaced-marker candidates ahead of bare/unqualified-only ones).

- **Zero survivors** → first check for a **stranded bundle**: commits touching `plugins/<plugin>/`
  that never reached the remote (`git log --oneline @{u}..HEAD -- "plugins/<plugin>/"` — a prior run
  committed per session but was killed before its publish). Any found → publish them now via Step 6's
  catch-up path (git itself is the tracker; no ledger state needed). Then/otherwise: "`<plugin>` is
  up to date — no unanalyzed sessions used it." Update `lastRun.at` (and `remaining: 0`), stop cleanly.
- **Out-of-scope notice:** other config dirs may hold matching sessions this run will never see —
  in **either** direction (a `~/.claude` run must report `~/.claude-ntb`'s sessions just as an
  `~/.claude-ntb` run reports `~/.claude`'s). Enumerate siblings — `ls -d "$HOME"/.claude*/projects`
  minus `$cfg/projects` itself — grep each once with the same pattern (count only; never analyze,
  ledger, or watermark them), and print "N matching sessions live in `<dir>` — out of scope for this
  run (active config dir only)." Never let a second config dir masquerade as "up to date".

## Step 4 — Present candidates + cap policy

List survivors, one line each:

```
<sid-8> · <project-dir> · <end-date> · markers N[ +subagents]
```

Plus the **grown-sessions notice** when any `analyzed[]` entry's recorded `lineCount` is now smaller
than the live `wc -l` ("N previously-analyzed sessions have grown — remove their ledger entries to
re-learn": `jq 'del(.analyzed[] | select(.sessionId=="<sid>"))'`).

**Cap (interactive batch) = 12 per run.** ≤ 12 survivors → proceed after printing the list. > 12 →
**one** `AskUserQuestion`: **Newest 12** (default) / Newest 24 / All N (cost warning) / Abort — note
that after this answer an auto-mode run is unattended through to its final publish. Remainders are
ledgered `skipped-cap` **immediately** in one §K.7 write (no watermark clause — re-eligible by
outcome, §K.3 rule 1). **`--dry-run` stops here** — nothing written.

**`--headless` takes ONE, not twelve.** Select only the **oldest** eligible survivor; the rest stay
un-ledgered and remain eligible by the watermark rule (processing oldest-first advances the watermark
only to the processed session's `endTs`, so every newer survivor still clears it — no `skipped-cap`
entries needed). Record the count of unselected survivors: it becomes `lastRun.remaining` in Step 7,
which is how the daily runner decides whether to fire again.

**Guard the working tree before implementing (batch mode).** If `git status --porcelain
"plugins/<plugin>/"` is already dirty at this point, those are either a killed run's partial edits or
the user's work in progress — this run cannot tell which, and a per-session commit would silently
sweep them in. Interactive: ask the user. `--headless`: stop cleanly with "plugins/<plugin>/ has
uncommitted changes — commit or clean them before the next scheduled run", set `lastRun.remaining: 0`
(so the runner doesn't hammer), and process nothing.

**Order the selected survivors oldest→newest by `sessionEndTs`** before processing. Oldest-first makes
the per-session watermark advance monotonic (Step 5, item 5) and lets fixes accrete forward — a later
session's agent analyzes the plugin as already improved by the earlier sessions' fixes.

## Step 5 — Sequential per-session loop: analyze → review → implement → persist

Resolve the shared lens reference once (the same file `audit-plugin` reads):

```bash
lenses="$(find .claude/skills plugins -path '*/references/analysis-lenses.md' 2>/dev/null | head -1)"
echo "${lenses:-NO_LENSES}"
```

Process the ordered survivors **one at a time** — never in parallel batches. Sequential processing
bounds context (one session's findings in memory at a time), keeps the watermark monotonic, and means
each session's agent sees the plugin source **as already improved** by earlier sessions. For **each**
session, in order:

1. **Dispatch** one `Explore` agent (sonnet) — **paths only, never transcript contents** (§C). Give it:

   - the **main transcript PATH** and the **subagents dir PATH** (§A) for that session;
   - the target plugin root `plugins/<plugin>/` and the §B purpose line;
   - the **PATH of `references/analysis-lenses.md`** plus the three heading anchors to read its lens
     briefs from — the literal strings **`Agent A — AUDIT lens`**, **`Agent B — ENHANCE lens`**, and
     **`Common parse brief`**. The agent locates each by text (never by step number) and **fails loud**
     if an anchor is missing — never guesses the brief;
   - this convergence line: **"the plugin source is current — if the transcript shows behavior already
     fixed in the current source, report it as `already-addressed`, not a finding."**

   The agent runs **both** lenses over its one session and returns **PROPOSALS ONLY** (no `Skill()`, no
   `AskUserQuestion`, no implementing — §C). Return contract:

   ```
   SESSION: <id> · <project> · <end-date>
   FINDINGS   — top 5 per lens, ranked, ≤400 words each, tagged `lens: audit|enhance`
   EVIDENCE   — transcript line refs + `file:line` only
   OPEN QUESTIONS
   ```

   or the single token **`NO USAGE FOUND`** (marker was a false positive → skip items 2–4, record
   outcome `no-usage` in item 5's write, continue with the next session).

2. **Order + trim** the session's findings: same file/root issue → merge; subset/superset → keep
   superset; drop `already-addressed` items (note them in the report); run the **composing-entry-point
   self-notice** (would the result still be manual stitching unless one command/skill drove the pieces
   end to end, where none exists today? if yes, add one thin entry point; if no, add nothing); enforce
   MINIMALITY. **Run-manifest convergence:** a finding matching an item already implemented earlier in
   this run routes as a refinement of that change (or a no-op skip), never a duplicate.

3. **Expert review per session** (chassis **§H**, right-sized): default **ONE** `Plan` reviewer for
   this session's set; escalate to the trio only when the set includes a hook/`hooks.json` merge, a
   settings merge, or multiple artifacts. State the target plugin's design philosophy; fold verdicts
   back in (revise REVISEs, drop REJECTs).

4. **Implement, then COMMIT this session's delta.** Auto mode (default): implement every
   **APPROVE**-verdict item into `plugins/<plugin>/` per §D (catalog) / §E (write safety) / §F
   (`${CLAUDE_PLUGIN_ROOT}` hooks) / §G (validate + grep-confirm) — no confirmation; an edit whose
   effective diff is empty is recorded as a **no-op skip**. **`--review` instead:** run the **§I
   confirm** over this session's reviewed items first (compact cards + one multi-select); zero
   selection → ledger the session and continue the loop.

   If anything landed, commit it now — plain conventional commit, **no version bump, no push**
   (both are the publish's job, Step 6):

   ```bash
   git add "plugins/<plugin>/" && git commit -m "learn(<plugin>): session <sid-8> — <what shipped>"
   ```

   The commit must come **before** item 5's ledger write, and the order is load-bearing: a kill
   between commit and ledger leaves the session re-eligible, and its re-analysis converges as
   `already-addressed` (a cheap no-op); the reversed order would mark a session `analyzed` while its
   work exists nowhere but a doomed working tree — which is exactly the stranding this design
   eliminates. A failed commit (or later a failed publish) ledgers the session `error` and the loop
   continues — the next session's run, or the next fire, carries the delta forward.

5. **Persist.** Append this session's section to `reports/<plugin>-<ts>.md` (findings, verdicts, what
   was implemented/skipped, evidence, **and the commit SHA from item 4**, so the history maps sessions
   to commits). Then write the session's `analyzed[]` entry **and** the
   watermark advance in **ONE** §K.7 write (the extended recipe with the watermark clause): per entry
   record `sessionId, transcriptPath, project, sessionEndTs, lineCount, markerHits, viaSubagent,
   analyzedAt, findings, outcome` (`analyzed` · `no-usage` · malformed return → `error`). Oldest→newest
   ordering makes the incremental max equal this session's `endTs` (§K.4). Drop the session's raw
   return from context — keep only one-line run-manifest entries (item · files touched · verdict).

**`--headless` exits the loop here:** its one selected session is done — skip straight to Step 6.

**Failure isolation:** an agent failure or implement failure ledgers that session `error` (re-eligible
next run) and the loop **continues** — one bad session must not sink the run.

### Step 5-single — single-session mode (`$2` given)

When a session id/path was supplied, there is no discovery, loop, or ledger. Resolve **that one
transcript** via chassis **§A** (plus its subagents dir), then dispatch **one** `Explore` agent (sonnet)
with the **exact per-agent brief above** (both lenses, briefs read from `analysis-lenses.md` at the three
anchors, PROPOSALS ONLY, same return contract). Order + trim its findings (item 2 above), write
`reports/<plugin>-<ts>.md` (useful evidence — but do **not** touch `lastRun` or the ledger), review per
**§H**, then run the **§I confirm** (always — single mode is interactive) and implement the selected
items per §D/§E/§F/§G. **Do not** write the ledger, touch the usage index, or advance the watermark.
Note in the final summary that this was a single-session run and the ledger/watermark were left
untouched.

## Step 6 — Publish when the backlog drains

The per-session commits (Step 5 item 4) are the durability layer; the publish — version bump,
manifest/README sync, push — is the release layer, and it fires **at most once per invocation**,
only when there is nothing left to wait for:

- **Interactive batch:** after the loop, if ≥1 session committed anything → publish via **§J**. One
  bump covers every commit this run made (they ride along in the push).
- **`--headless`:** publish **only when `remaining` is 0** — i.e. this fire processed the last
  eligible survivor, or Step 3 found a stranded bundle with zero survivors (the catch-up path).
  `remaining > 0` → do **not** publish; report "N sessions remain — commits pending, publish deferred
  to the fire that drains the queue" and let the runner fire again. This is what keeps a 12-session
  backlog at one version bump instead of twelve, while a kill at any point loses at most the
  in-flight session — everything committed is already in git, and the eventual publish (or the next
  run's catch-up) bundles it.
- **Single-session mode:** unchanged — one implement, one publish, as before.

The plugin being published is the **analyzed target plugin** — **loom itself when running
`/learn loom`**. Tell `publish-plugin` when the run is `--headless` so it never pauses on an
ambiguous bump (it picks the lower class and notes the ambiguity in the commit body). Report the new
version + `old..new` push and advise `/reload-plugins`. Nothing committed and no stranded bundle →
nothing to publish; say so.

## Step 7 — Finalize

**Batch mode:** update `lastRun` (`at`, `sessionsAnalyzed`, `sessionsSkippedCap`, `findingsProposed`,
`findingsImplemented`, `updatesSkippedNoop`, `publishedVersion`, `report`, and **`remaining`** — the
count of still-eligible survivors this invocation did not process; the daily runner reads it to decide
whether to fire again, so write it on **every** batch exit path, including dead-end stops). The
`analyzed[]` entries and watermark were already written per session in Step 5. Print a summary:
sessions analyzed, findings, per-session commits (SHAs), whether this invocation published or deferred,
and "next run only sees sessions newer than `<watermark>` plus any `skipped-cap`/`error` remainders."
If `<plugin>` isn't tracked, add: "Tip: `/loom:track <plugin>` indexes future sessions at session-end,
making discovery instant."

**Single-session mode:** no ledger/watermark to finalize. Print a summary: the one session analyzed, the
findings, what shipped, and an explicit note that the ledger/watermark were left untouched (a later batch
`learn <plugin>` will still consider this session).

---

## Dispatch / cap policy

- Selected survivors processed **oldest→newest, one at a time**; namespaced-marker candidates ahead of
  bare/unqualified-only matches when capping.
- **Interactive cap = 12/run.** ≤ 12 → proceed. > 12 → one `AskUserQuestion` (Newest 12 default /
  Newest 24 / All N + cost warning / Abort). Remainders ledgered `skipped-cap` at cap resolution,
  re-offered next run. Abort touches nothing.
- **`--headless` = exactly ONE session per invocation** (the oldest eligible), no cap question, no
  `skipped-cap` entries — unprocessed survivors stay eligible by watermark; `lastRun.remaining` tells
  the runner whether to fire again.

## Rules

- **One agent per session, both lenses, one §K.7 write per session** — entry + watermark land together
  immediately after each session, so analysis is durable as the run goes; a mid-run crash loses at most
  the in-flight session.
- **Paths only to subagents** (§C); subagents return **PROPOSALS ONLY** (no `Skill()`, no
  `AskUserQuestion`, no implementing, no publishing).
- **Lens briefs read by each agent from `references/analysis-lenses.md` at heading anchors** — never
  duplicated into this skill or the prompts; fail loud if an anchor is missing.
- **Review before implement, every session** — §H right-sized per session (usually one reviewer); auto
  mode implements only APPROVE verdicts; `--review` adds the §I confirm.
- **Commit per session, publish at drain** — each session's delta is committed (no bump, no push)
  before its ledger write; the publish fires at most once per invocation, and in headless only on the
  fire that empties the queue (or the catch-up on a stranded bundle). One plugin per publish; git
  itself tracks the pending bundle — never a ledger field.
- **State in the config dir, never in this repo** — `$cfg/loom/learning/`; use `$cfg`, not §A's
  `$HOME/.claude`.

## Done when

- The plugin was validated against this repo's `marketplace.json`; the chassis + ledger + index loaded;
  candidates were discovered index-first with §K.2 backfill and filtered per §K.3 (active session and
  <5-min transcripts excluded); the out-of-scope-roots notice printed when a second config dir exists.
- **Either** zero survivors → "up to date", `lastRun`-only ledger update, clean stop;
- **or `--dry-run`** → candidates + cap decision presented, nothing written;
- **or** the selected survivors ran **oldest→newest, one at a time**: per session — one both-lens agent
  (paths only), findings ordered/trimmed with `already-addressed` drops and run-manifest convergence,
  §H review right-sized (one reviewer default, trio on hooks/settings/multi-artifact), APPROVE items
  implemented automatically (§D/§E/§F/§G) or §I-confirmed first under `--review`, the session's delta
  **committed before** the `analyzed[]` entry + watermark landed in **one** §K.7 write; failures
  ledgered `error` with the loop continuing; then the publish (§J) fired iff the queue drained with
  commits pending (interactive: end of loop; headless: `remaining` 0), and the finalize summary printed
  with per-session commit SHAs + `lastRun.remaining` (+ the track tip when untracked).
- **Single-session mode** ran interactively (§H review + §I confirm), implemented the selection,
  published once if anything shipped, and left the ledger/watermark untouched.
- **`--headless`** never called `AskUserQuestion` on any path, processed at most ONE session, wrote
  `lastRun.remaining` on every exit path, and stopped cleanly (processing nothing) on a pre-dirty
  `plugins/<plugin>/` tree.
