---
name: learn
description: Learn from EVERY unanalyzed session that used one plugin, machine-wide, in a single command — the multi-session counterpart to tune-plugin. Discovers matching sessions across all project folders (usage-index fast path + transcript-scan backfill), filters out already-analyzed ones via a per-plugin ledger + watermark, dispatches ONE deep-analysis agent per session (both audit + enhance lenses), merges findings cross-session, then runs one review → one confirm → one implement → ONE publish of the target plugin. Invoke for "learn <plugin>", "learn from all sessions that used <plugin>", "audit/enhance <plugin> across every session", or "/learn <plugin> [--dry-run]". Marks analyzed sessions so future runs never redo them.
version: 0.1.0
---

# learn — audit + enhance one plugin from EVERY session that used it

Three related skills, one job each:

- **`tune-plugin`** — ONE known session → one plugin. You name the session.
- **`learn`** (this skill) — **ALL unanalyzed sessions** that ever used a plugin → one plugin. You
  name only the plugin; it finds the sessions across every project folder, analyzes each in its own
  agent, and never re-analyzes one it has already seen.
- **`track`** — the opt-in indexer that makes `learn`'s discovery instant (works fully without it —
  just slower).

`learn` reuses `tune-plugin`'s two analysis lenses **by reference** (never re-inlined): each
per-session agent reads them straight from `tune-plugin`'s SKILL.md at heading anchors. The mechanics
— marker pattern, machine-wide scan, ledger + watermark, usage index — live in chassis **§K**.

Read the shared chassis first (resolve by glob, then reference §A … §K):

```bash
common="$(find .claude/skills plugins -path '*/references/session-plugin-common.md' 2>/dev/null | head -1)"
echo "${common:-NO_COMMON}"
```

## When NOT to invoke

- **A single known session** → `tune-plugin` / `audit-plugin` / `enhance-plugin` (you already have the
  id; no discovery needed).
- **Run from outside this marketplace repo.** Discovery is marketplace-agnostic, but the implement +
  publish tail writes `plugins/<plugin>/` and publishes **this** repo — run `learn` with cwd = this
  repo. A plugin tracked from another marketplace is named explicitly (Step 1) with where to run it.
- **The plugin isn't in this repo's `marketplace.json`.** Step 1 refuses it.

## Inputs

- **`$1` — plugin name** (required, e.g. `mentor`). Unqualified — the marketplace is this repo.
- **`--dry-run`** — Steps 1–4 only: discover + present candidates, **no agents, no writes** (no ledger,
  no reports). For previewing what a real run would analyze.

`cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"` throughout — **not** §A's `$HOME/.claude` (see §K).

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

One `Explore` agent (sonnet) **per session** — **paths only, never transcript contents** (§C). Give
each:

- the **main transcript PATH** and the **subagents dir PATH** (§A) for that session;
- the target plugin root `plugins/<plugin>/` and the §B purpose line;
- the **PATH of `tune-plugin`'s SKILL.md** plus the three heading anchors to read its lens briefs
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
that batch's `analyzed[]` entries to the ledger under §E discipline. Per entry record `sessionId,
transcriptPath, project, sessionEndTs, lineCount, markerHits, viaSubagent, analyzedAt, findings,
outcome` (`analyzed` · `no-usage` · malformed return → `error`).

## Step 6 — Advance the watermark

After all batches: `watermark = max(old, max sessionEndTs over sessions disposed this run)` — **never
`now()`** (§K.4). Update `lastRun` counts (`sessionsAnalyzed`, `sessionsSkippedCap`). The ledger is now
complete and correct **regardless of whether the user accepts anything below** — analysis is durable.

## Step 7 — Merge / dedupe across sessions

Hold only the distilled returns in the main thread. Apply `tune-plugin` Step 3's merge/dedupe rules
(same file/root issue → merge; subset/superset → keep superset; independent → separate; tag by lens),
**plus cross-session aggregation**: the same root cause seen in **k** of **N** sessions collapses to
**one** item labelled `seen in k/N sessions`; **recurrence sorts first**. Fork/resume dedupe: identical
findings with identical transcript timestamps across sessions are copied history → count **once**. Run
`tune-plugin`'s composing-entry-point self-notice over the merged set; enforce MINIMALITY.

## Step 8 — Consolidated report, then expert review

Write `reports/<plugin>-<ts>.md` (the merged, ranked set with per-item recurrence + evidence) and point
`lastRun.report` at it **before** reviewing — findings are preserved even if review or the user aborts.
Then review the set **once** per chassis **§H**. The trio escalation triggers here by default
(multi-session, typically multi-artifact; and a hook/settings merge if the proposed changes include
one). State the target plugin's design philosophy to the reviewer(s); fold verdicts back in.

## Step 9 — Confirm → implement → publish ONCE

Chassis **§I**: print one compact card per merged item (tagged by lens; show `×k/N` recurrence), then
**immediately** call **one** `AskUserQuestion` multi-select in the same turn.

- **Zero selection** → clean **no-op**: create/change/publish nothing. Say so explicitly — **the
  ledger, watermark, and reports are already written** (Steps 5–8), so the analysis is not lost and
  these sessions won't be re-analyzed. This is a valid outcome.
- **Selection** → implement the chosen items into `plugins/<plugin>/` per §D (catalog) / §E (write
  safety) / §F (`${CLAUDE_PLUGIN_ROOT}` hooks) / §G (validate + grep-confirm). Then **publish exactly
  once** via §J — the plugin being published is the **analyzed target plugin**, which is **loom itself
  when running `/learn loom`**. Report the new version + `old..new` push and advise `/reload-plugins`.

## Step 10 — Finalize

Update `lastRun` (findings proposed/accepted, published version, report path) and each `analyzed[]`
entry's `findings`/`outcome`. Print a summary: sessions analyzed, findings, what shipped, and "next run
only sees sessions newer than `<watermark>` plus any `skipped-cap`/`error` remainders." If `<plugin>`
isn't tracked, add: "Tip: `/loom:track <plugin>` indexes future sessions at session-end, making
discovery instant."

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
- **Lens briefs read by each agent from `tune-plugin`'s SKILL.md at heading anchors** — never
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
