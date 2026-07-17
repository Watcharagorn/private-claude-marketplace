# Project-wide harvest — multi-session machinery

The extra layer `harvest-automations` runs when invoked with **no argument** (or `--dry-run`): sweep
**every un-harvested session of the current project**, tracked by a per-project **ledger + watermark**
so re-runs only pick up new work. Single-session runs never touch this file (except to borrow the
ledger recipe + entry shape in **Phase B** for their own ledgering).

This machinery deliberately **mirrors chassis §K** (`loom:learn`) — the state map is registered at
chassis **§K.6**. Where a rule is copied verbatim it is tagged "mirrors chassis §K.N — keep in sync".
Harvest keeps its own copy (rather than calling §K) because its keyspace is **per-project** (a project
hash, not a plugin name) and its **active-session** handling differs.

**How the modes flow.** SKILL.md Step 1 resolves the mode and, in project-wide mode, computes `cfg`,
`root`, `hash`, `pdir`, and `active`, then hands here. Run the three phases below in order, then return
to **SKILL.md Step 3 (rubric)** with the merged opportunity set. `--dry-run` stops at the end of
Phase A. The analysis brief lives in **SKILL.md Step 2** — Phase B reuses it with a slimmer contract.

**Deviations from chassis §K** (harvest-specific, by design):

- the **active** session is always analyzed but **never** ledgered and never advances the watermark;
- **single-session** runs ledger their session **without** moving the watermark;
- the cap counts **non-active** sessions only;
- outcome enums differ per skill — only `skipped-cap`/`error` re-eligibility is shared.

---

## Phase A — Ledger load/init + discovery + eligibility

**Load or initialize the ledger.** State lives at `$cfg/loom/harvest/<hash>.json` (a sibling of
`learning/`; the filename carries the project hash). One check handles first-run, corrupt, and
unknown-`schemaVersion` — none of `$cfg/loom/` need exist yet:

```bash
mkdir -p "$cfg/loom/harvest/reports"
ledger="$cfg/loom/harvest/$hash.json"
jq -e '.schemaVersion == 1' "$ledger" >/dev/null 2>&1 \
  || { [ -e "$ledger" ] && mv "$ledger" "$ledger.bak-$(date +%s)" && echo "WARN: corrupt/unknown ledger moved aside"; \
       jq -n --arg r "$root" '{schemaVersion:1, projectRoot:$r, watermark:null, analyzed:[]}' > "$ledger"; }
```

`--dry-run` skips this write — it loads the ledger read-only and never creates `$cfg/loom/`.

**Advisory lock** (guards two harvests of the same project running at once): `mkdir "$ledger.lock"` —
if it already exists, steal it when its mtime is > 30 min old (stale), else abort with "another
harvest is running for this project". Release it in SKILL.md Step 6 and on any abort. (`--dry-run`
takes no lock.)

**Discover the project's transcripts** — use `find`, **never a bare glob** (`for tx in "$pdir"/*.jsonl`
aborts under zsh's `nomatch` on an empty dir, making the empty-dir fallback unreachable — the same
trap chassis §B/§D avoid):

```bash
find "$pdir" -maxdepth 1 -name '*.jsonl' 2>/dev/null | while read -r tx; do
  sid="$(basename "$tx" .jsonl)"
  end="$(tail -n 50 "$tx" | command grep -o '"timestamp":"[^"]*"' | tail -1 | cut -d'"' -f4)"
  [ -z "$end" ] && end="$(date -u -r "$(stat -f %m "$tx")" +%Y-%m-%dT%H:%M:%SZ)"   # mtime fallback (macOS/BSD date -r)
  printf '%s\t%s\t%s\t%s\t%s\n' "$tx" "$sid" "$end" "$(wc -l <"$tx")" "$([ "$tx" = "$active" ] && echo 1 || echo 0)"
done
```

`command grep` — the interactive `grep` here is a ugrep wrapper that skips `.jsonl` as "binary". The
first/last physical lines can lack a `timestamp`, hence `tail -n 50` + the mtime fallback — an empty
`end` must never reach the watermark comparison. Empty `find` output → **`NO_TRANSCRIPTS`** →
`AskUserQuestion` fallback (offer a session id / path, i.e. single mode).

**Eligibility** *(mirrors chassis §K.3 — keep in sync)* — decide per discovered transcript:

1. `sid ∈ analyzed[]` → eligible **iff** its `outcome ∈ {error, skipped-cap}` (a prior error or capped
   remainder comes back; `harvested`/`no-opportunities` do not — "never re-analyze" must not become
   "never analyze").
2. Not in the ledger → eligible **iff** `end > watermark` (or the watermark is null).
3. **Live transcript** (defined once, here): the `active` path, **or** any transcript with mtime
   < 5 min. The **active** session is *always* analyzed but **never** ledgered and never advances the
   watermark (harvest's core value is the session you just finished). Any *other* live transcript is
   excluded this run and left un-ledgered (it may still be being written) — eligible next run.

List the eligible **non-active** survivors newest-first, one line each, plus the active session
flagged:

```
<sid-8> · <end-date> · <lines>[ · ACTIVE]
```

**Grown-session notice:** when a ledgered entry's recorded `lineCount` is smaller than the live
`wc -l`, print "N previously-harvested sessions have grown — remove their ledger entries to
re-harvest": `jq 'del(.analyzed[] | select(.sessionId=="<sid>"))' "$ledger"`.

**Cap = 12 non-active per run** (the active session always rides along, uncounted). ≤ 12 → proceed
after printing the list. > 12 → **one** `AskUserQuestion`: **Newest 12** (default) / Newest 24 /
All N (cost warning) / Abort. Remainders are ledgered `skipped-cap` and re-offered next run (rule 1).

**Zero eligible non-active** → "nothing new since `<watermark>` — analyzing the active session only",
then continue with just the active session.

**`--dry-run` stops here:** present the discovery list, eligibility, and cap outcome, then stop — no
lock, no `mkdir`/init writes, no agents, no ledger mutation.

---

## Phase B — Dispatch (slim contract + per-batch persistence)

Dispatch the analysis subagents per the brief in **SKILL.md Step 2** (one `Explore`/sonnet per
session, **paths only**, chassis §C), but with the **slim** return contract — a full `draft_spec` for
~50 opportunities across many sessions would bloat the main context. Each session's opportunity keeps
`title`, `usage.invocation/example/outcome`, `recurrence`, and `artifacts[]` as one-liners
(`artifact_type` + `mode` + `recommended_scope` + `target_path`) — **omit** `draft_spec.steps` and
`json_fragment`. The full spec is hydrated later, only for accepted usages (SKILL.md Step 5).

Dispatch in **batches of 4** parallel agents per message. **After EACH batch** (crash safety — a
failure in batch 3 must not lose batches 1–2): append the raw returns to `reports/$hash-<ts>-raw.md`,
then append that batch's ledger entries with the **del-then-append** recipe. jq's `. * $frag`
deep-merge REPLACES arrays, so it must **not** be used for the `analyzed[]` append — only the
backup/validate/restore envelope from the catalog's merge-json recipe is reused:

```bash
cp "$ledger" "$ledger.bak.$(date +%s)"
jq --argjson batch "$entries" \
  '.analyzed = ([.analyzed[] | select([.sessionId] | inside($batch | map(.sessionId)) | not)] + $batch)' \
  "$ledger" > "$ledger.tmp" && jq empty "$ledger.tmp" && mv "$ledger.tmp" "$ledger" \
  || { echo "INVALID — restoring"; rm -f "$ledger.tmp"; cp "$ledger".bak.* "$ledger"; }
```

`$entries` is that batch's array of `analyzed[]` objects. Del-then-append (delete any existing entry
with the same `sessionId`, then append the new one) makes re-runs **replace** rather than duplicate —
which is also why **single mode** borrows this recipe for its one-entry append. The **active**
session's return is held in memory only — never batched into the ledger.

**`analyzed[]` entry shape** (one object per session):

```json
{ "sessionId": "…", "transcriptPath": "…", "sessionEndTs": "…", "lineCount": 1487,
  "analyzedAt": "…", "opportunities": 3, "outcome": "harvested" }
```

`outcome` enum: `harvested | no-opportunities | skipped-cap | error` — only `skipped-cap`/`error` are
re-eligible (Phase A rule 1).

**Full ledger schema** (`$cfg/loom/harvest/<hash>.json`):

```json
{ "schemaVersion": 1, "projectRoot": "/Users/…",
  "watermark": "2026-07-14T04:08:24.718Z",
  "lastRun": { "at": "…", "mode": "project-wide", "sessionsAnalyzed": 5, "sessionsSkippedCap": 0,
               "usagesProposed": 4, "usagesAccepted": 2, "report": "reports/<hash>-<ts>.md" },
  "analyzed": [ { "sessionId": "…", "transcriptPath": "…", "sessionEndTs": "…", "lineCount": 1487,
                  "analyzedAt": "…", "opportunities": 3, "outcome": "harvested" } ] }
```

The filename carries the hash (no `project` field); nothing consumes a per-entry `mode`, so there
isn't one. `analyzedAt` matches chassis §K.4 naming.

---

## Phase C — Advance the watermark, then merge

**Advance the watermark** *(verbatim — mirrors chassis §K.4)*:
`watermark = max(old, max sessionEndTs over sessions disposed this run)` — **never `now()`**, never
backwards. "Disposed" = every session ledgered this run, including `skipped-cap`/`error`; the active
session is excluded by construction. Update `lastRun`. The ledger is now complete and correct
**regardless of whether the user accepts anything below** — analysis is durable. (Sound because every
matching session older than the watermark is already in `analyzed[]`; a full-discovery run is what
establishes that, which is why single-session runs never advance it.)

**Merge across sessions.** Cluster the slim opportunities (active session included) by usage intent:

- the same usage seen in **k** of **N** sessions collapses to **one** item labelled `seen in k/N
  sessions`; recurrence counts are summed and evidence unioned (tagged per session);
- **copied-history dedupe:** identical `usage.example` **and** identical evidence line refs across two
  sessions = a fork/resume copy → count **once**;
- re-apply the **top-4** cap over the merged set.

Write the consolidated `reports/<hash>-<ts>.md` (merged, ranked set with per-item `k/N` recurrence +
evidence) and set `lastRun.report` **before** anything user-facing — findings survive even if the user
declines everything below.

**Then return to [`../SKILL.md`](../SKILL.md) Step 3 (rubric)** with the merged opportunity set. The
cards in Step 4 carry the `Seen in: k/N` line; Step 5 hydrates accepted usages to full `draft_spec`s;
Step 6 prints the project-wide state block and releases the lock.
