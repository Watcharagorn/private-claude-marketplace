---
name: learn
description: Learn from EVERY unanalyzed session that used one plugin, machine-wide — or from ONE named session — improving the plugin with both audit + enhance lenses. With just <plugin>, discovers matching sessions across all project folders (usage-index fast path + transcript-scan backfill), filters already-analyzed ones via a per-plugin ledger + watermark, and analyzes each in its own agent; with <plugin> <session-id>, analyzes only that one session (skips discovery, leaves the ledger/watermark untouched). Merges findings, runs one review → one confirm → one implement → ONE publish. Invoke for "learn <plugin>", "learn from all sessions that used <plugin>", "audit and enhance <plugin> from session <id>", or "/learn <plugin> [session-id] [--dry-run]". For a quick misbehavior-only pass on one session, use audit-plugin.
version: 0.1.0
---

# learn — audit + enhance one plugin from its sessions

Three related skills, one job each:

- **`audit-plugin`** — ONE session → one plugin, **AUDIT lens only** (a quick misbehavior-only fix pass).
- **`learn`** (this skill) — a plugin's sessions → one plugin, **both audit + enhance lenses**. Name only
  the plugin and it sweeps **every unanalyzed session** across all project folders, analyzing each in its
  own agent and never re-analyzing one it has seen; name a plugin **and a session id** and it analyzes
  just that **one** session (skipping discovery and the ledger/watermark).
- **`track`** — the opt-in indexer that makes `learn`'s discovery instant (works fully without it —
  just slower).

`learn` reuses the two analysis lenses **by reference** (never re-inlined): each per-session agent reads
them straight from **`references/analysis-lenses.md`** at heading anchors — the same file `audit-plugin`
reads, so the AUDIT and ENHANCE briefs have one wording. The multi-session mechanics — marker pattern,
machine-wide scan, ledger + watermark, usage index — live in chassis **§K**.

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

`cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"` throughout — **not** §A's `$HOME/.claude` (see §K).

## Mode fork (read `$2` first)

- **`$2` present → single-session mode.** Do **Step 1** (validate the plugin + resolve the chassis), then
  jump to **Step 5-single** below (resolve that one transcript via §A, run one both-lens agent, merge as
  a passthrough), then **Steps 8–9** (report → review → confirm → implement → publish). **Skip** Steps 2–4
  (ledger load, discovery, cap) and **Step 6** (watermark) entirely — a single named run must never move
  the machine-wide watermark or write the ledger, mirroring how `harvest-automations` single-mode leaves
  the watermark alone.
- **`$2` absent → batch mode.** Run Steps 1–10 in order, as written.

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

**Backfill scan (§K.2):** run the machine-wide scan **only** over transcripts whose sessionId is
absent-from-index-or-missing-the-target-key. Build the marker pattern with §K.1 (surface root =
`"$PWD/plugins"`, this repo).

Union the index hits and scan hits, then **filter + order per §K.3** (ledger-outcome-first
eligibility; drop the active session with the `$cfg` restatement; drop transcripts with mtime < 5 min;
namespaced-marker candidates ahead of bare/unqualified-only ones).

- **Zero survivors** → "`<plugin>` is up to date — no unanalyzed sessions used it." Update
  `lastRun.at` only (no new `analyzed[]`), stop cleanly.
- **Out-of-scope notice:** when `~/.claude/projects` exists **and** ≠ `$cfg/projects`, grep it once
  with the same pattern and print "N matching sessions live in `~/.claude/projects` — out of scope for
  this run (active config dir only)." Never let a second config dir masquerade as "up to date".

## Step 4 — Present candidates + cap policy

List survivors newest-first, one line each:

```
<sid-8> · <project-dir> · <end-date> · markers N[ +subagents]
```

Plus the **grown-sessions notice** when any `analyzed[]` entry's recorded `lineCount` is now smaller
than the live `wc -l` ("N previously-analyzed sessions have grown — remove their ledger entries to
re-learn": `jq 'del(.analyzed[] | select(.sessionId=="<sid>"))'`).

**Cap = 12 per run.** ≤ 12 survivors → proceed after printing the list. > 12 → **one**
`AskUserQuestion`: **Newest 12** (default) / Newest 24 / All N (cost warning) / Abort. Remainders are
ledgered `skipped-cap` and **re-offered next run** (§K.3 rule 1). **`--dry-run` stops here** — nothing
written.

## Step 5 — Dispatch ONE analysis agent per session (batches of 4, persist per batch)

Resolve the shared lens reference once (the same file `audit-plugin` reads):

```bash
lenses="$(find .claude/skills plugins -path '*/references/analysis-lenses.md' 2>/dev/null | head -1)"
echo "${lenses:-NO_LENSES}"
```

One `Explore` agent (sonnet) **per session** — **paths only, never transcript contents** (§C). Give
each:

- the **main transcript PATH** and the **subagents dir PATH** (§A) for that session;
- the target plugin root `plugins/<plugin>/` and the §B purpose line;
- the **PATH of `references/analysis-lenses.md`** plus the three heading anchors to read its lens briefs
  from — the literal strings **`Agent A — AUDIT lens`**, **`Agent B — ENHANCE lens`**, and
  **`Common parse brief`**. The agent locates each by text (never by step number) and **fails loud**
  if an anchor is missing — never guesses the brief.

Each agent runs **both** lenses over its one session and returns **PROPOSALS ONLY** (no `Skill()`, no
`AskUserQuestion`, no implementing — §C). Return contract:

```
SESSION: <id> · <project> · <end-date>
FINDINGS   — top 5 per lens, ranked, ≤400 words each, tagged `lens: audit|enhance`
EVIDENCE   — transcript line refs + `file:line` only
OPEN QUESTIONS
```

or the single token **`NO USAGE FOUND`** (marker was a false positive → ledger `no-usage`).

**Batches of 4** parallel agents per message. **After EACH batch** (crash safety — a failure in batch
3 must not lose batches 1–2): append the raw returns to `reports/<plugin>-<ts>-raw.md` **and** append
that batch's `analyzed[]` entries to the ledger via the **§K.7 del-then-append recipe** (under §E's
backup/validate/restore envelope — §E's `. * $frag` deep-merge would *replace* the `analyzed[]` array,
not extend it). Per entry record `sessionId, transcriptPath, project, sessionEndTs, lineCount,
markerHits, viaSubagent, analyzedAt, findings, outcome` (`analyzed` · `no-usage` · malformed return →
`error`).

### Step 5-single — single-session mode (`$2` given)

When a session id/path was supplied, there is no discovery, batching, or ledger. Resolve **that one
transcript** via chassis **§A** (plus its subagents dir), then dispatch **one** `Explore` agent (sonnet)
with the **exact per-agent brief above** (both lenses, briefs read from `analysis-lenses.md` at the three
anchors, PROPOSALS ONLY, same return contract). Hold its return in memory and go straight to **Step 7**
(merge is a passthrough for one session — just order the findings). **Do not** write the ledger, touch
the usage index, or advance the watermark; **skip Step 6**. Note in the final summary that this was a
single-session run and the ledger/watermark were left untouched.

## Step 6 — Advance the watermark (batch mode only)

*Single-session mode (`$2` given) skips this step entirely — see the Mode fork and Step 5-single.*

After all batches: `watermark = max(old, max sessionEndTs over sessions disposed this run)` — **never
`now()`** (§K.4). Update `lastRun` counts (`sessionsAnalyzed`, `sessionsSkippedCap`). The ledger is now
complete and correct **regardless of whether the user accepts anything below** — analysis is durable.

## Step 7 — Merge / dedupe across sessions

Hold only the distilled returns in the main thread. Apply these merge/dedupe rules (same file/root
issue → merge; subset/superset → keep superset; independent → separate; tag by lens), **plus
cross-session aggregation**: the same root cause seen in **k** of **N** sessions collapses to **one**
item labelled `seen in k/N sessions`; **recurrence sorts first**. Fork/resume dedupe: identical findings
with identical transcript timestamps across sessions are copied history → count **once**. Then run the
**composing-entry-point self-notice** over the merged set (would the result still be manual stitching
unless one command/skill drove the pieces end to end, where none exists today? if yes, add one thin
entry point; if no, add nothing); enforce MINIMALITY. *Single-session mode: merge is a passthrough — just
order the one session's findings and run the same self-notice.*

## Step 8 — Consolidated report, then expert review

Write `reports/<plugin>-<ts>.md` (the merged, ranked set with per-item recurrence + evidence) and point
`lastRun.report` at it **before** reviewing — findings are preserved even if review or the user aborts.
*Single-session mode still writes the report file (useful evidence), but does **not** touch `lastRun` or
the ledger.* Then review the set **once** per chassis **§H**. The trio escalation triggers here by
default (multi-session, typically multi-artifact; and a hook/settings merge if the proposed changes
include one; a single session with one small fix may stay at one reviewer). State the target plugin's
design philosophy to the reviewer(s); fold verdicts back in.

## Step 9 — Confirm → implement → publish ONCE

Chassis **§I**: print one compact card per merged item (tagged by lens; show `×k/N` recurrence), then
**immediately** call **one** `AskUserQuestion` multi-select in the same turn.

- **Zero selection** → clean **no-op**: create/change/publish nothing. Say so explicitly. In **batch
  mode** the ledger, watermark, and report are already written (Steps 5–8), so the analysis is not lost
  and these sessions won't be re-analyzed. In **single-session mode** only the report was written (no
  ledger/watermark), so re-running the same session id re-analyzes it. This is a valid outcome.
- **Selection** → implement the chosen items into `plugins/<plugin>/` per §D (catalog) / §E (write
  safety) / §F (`${CLAUDE_PLUGIN_ROOT}` hooks) / §G (validate + grep-confirm). Then **publish exactly
  once** via §J — the plugin being published is the **analyzed target plugin**, which is **loom itself
  when running `/learn loom`**. Report the new version + `old..new` push and advise `/reload-plugins`.

## Step 10 — Finalize

**Batch mode:** update `lastRun` (findings proposed/accepted, published version, report path) and each
`analyzed[]` entry's `findings`/`outcome`. Print a summary: sessions analyzed, findings, what shipped,
and "next run only sees sessions newer than `<watermark>` plus any `skipped-cap`/`error` remainders." If
`<plugin>` isn't tracked, add: "Tip: `/loom:track <plugin>` indexes future sessions at session-end,
making discovery instant."

**Single-session mode:** no ledger/watermark to finalize. Print a summary: the one session analyzed, the
findings, what shipped, and an explicit note that the ledger/watermark were left untouched (a later batch
`learn <plugin>` will still consider this session).

---

## Dispatch / cap policy

- Newest-first by mtime; namespaced-marker candidates ahead of bare/unqualified-only matches.
- Batch = **4** parallel `Explore` agents per message; ledger + raw report appended **per batch**.
- **Cap = 12/run.** ≤ 12 → proceed. > 12 → one `AskUserQuestion` (Newest 12 default / Newest 24 /
  All N + cost warning / Abort). Remainders ledgered `skipped-cap`, re-offered next run. Abort touches
  nothing.

## Rules

- **One agent per session, both lenses, batches of 4 with per-batch persistence** — analysis is
  durable before the interactive tail; a mid-run crash loses nothing already batched.
- **Paths only to subagents** (§C); subagents return **PROPOSALS ONLY** (no `Skill()`, no
  `AskUserQuestion`, no implementing, no publishing).
- **Lens briefs read by each agent from `references/analysis-lenses.md` at heading anchors** — never
  duplicated into this skill or the prompts; fail loud if an anchor is missing.
- **Ledger + report written before the confirm** — the watermark advances over every disposed session
  regardless of acceptance; "never re-analyze" excludes `error`/`skipped-cap` (they come back).
- **One review, one selection, one implement, ONE publish** — the analyzed target plugin (loom itself
  for `/learn loom`). One plugin per publish.
- **State in the config dir, never in this repo** — `$cfg/loom/learning/`; use `$cfg`, not §A's
  `$HOME/.claude`.

## Done when

- The plugin was validated against this repo's `marketplace.json`; the chassis + ledger + index loaded;
  candidates were discovered index-first with §K.2 backfill and filtered per §K.3 (active session and
  <5-min transcripts excluded); the out-of-scope-roots notice printed when a second config dir exists.
- **Either** zero survivors → "up to date", `lastRun`-only ledger update, clean stop;
- **or `--dry-run`** → candidates + cap decision presented, nothing written;
- **or** one agent per session ran (batches of 4, per-batch ledger + raw report), the watermark
  advanced (§K.4), findings merged cross-session with recurrence, the consolidated report written and
  reviewed once (§H); **then either** the user selected items → implemented (§D/§E/§F/§G) and published
  once (§J), **or** selected nothing → clean no-op with ledger/report already durable — both print the
  finalize summary + the track tip when untracked.
