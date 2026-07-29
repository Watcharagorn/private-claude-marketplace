# Project-wide harvest — sequential per-session auto-fold

The extra layer `harvest-automations` runs when invoked with **no argument** (or with `--dry-run` /
`--review` / `--headless`): process **every un-harvested session of the current project ONE AT A TIME,
oldest→newest**, folding each session's passing artifacts in as it goes, tracked by a per-project
**ledger + watermark** so re-runs only pick up new work. Single-session runs never touch this file
(except to borrow the one-entry ledger append in **Phase B**).

The **ledger schema, eligibility rules, watermark semantics, and the del-then-append persistence recipe**
are the chassis's — **§K.6** (harvest ledger, authoritative) and **§K.7** (persistence recipe). This file
owns only the **orchestration**: mode flow, the advisory lock, the per-project discovery loop, the cap
prompt, and the per-session analyze→fold loop. Resolve the chassis first — harvest runs in **any**
repo, so a cwd-relative find alone is not enough; try the plugin's own root first, then the installed
plugin tree, then the cwd (marketplace-repo dev checkout):

```bash
cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"   # self-contained: shell state never survives between blocks
common="${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/references/session-plugin-common.md}"
[ -f "$common" ] || common="$(find "$cfg/plugins" .claude/skills plugins \
    -path '*/references/session-plugin-common.md' 2>/dev/null | head -1)"
echo "${common:-NO_COMMON}"
```

**Shell state does not persist between Bash calls.** Re-derive the Step 1 preamble — `cfg`, `root`,
`hash`, `pdir`, `active`, and the flags — at the top of **every** bash block you run from this file
(an unset `hash` would silently resolve the ledger to `$cfg/loom/harvest/.json`, one shared ledger
for every project).

**How the modes flow.** SKILL.md Step 1 resolves the mode and flags and, in project-wide mode, computes
`cfg`, `root`, `hash`, `pdir`, and `active`, then hands here. Run the three phases below in order, then
return to **SKILL.md Step 6 (report)** with the run manifest. `--dry-run` stops at the end of Phase A.
The analysis brief and return contract live in **SKILL.md Step 2** — Phase B dispatches it once per
session, sequentially.

**The run is fully automatic after Phase A's cap question** (which fires only on >12 sessions): no
usage cards, no multi-select, no scope question, no per-diff confirmation. The user reviews the folded
artifacts afterwards with `git diff` — which is why the auto path forces **project scope** (Phase B.3).
Safety mechanics (timestamped backups, jq validate + restore, `<PLACEHOLDER>` secrets, insert-only
updates) are non-negotiable in every mode. `--review` keeps the same sequential loop but pauses each
session for the interactive confirm (Phase B.4); `--headless` removes even the cap question.

---

## Phase A — Ledger load/init + discovery + eligibility

**Load or initialize the ledger** (schema = **§K.6**). State lives at `$cfg/loom/harvest/<hash>.json`.
One check handles first-run, corrupt, and unknown-`schemaVersion` — and the entire write path is
guarded so `--dry-run` never creates `$cfg/loom/` or mutates anything:

```bash
ledger="$cfg/loom/harvest/$hash.json"
if [ "$dry" != 1 ]; then
  mkdir -p "$cfg/loom/harvest/reports"
  jq -e '.schemaVersion == 1' "$ledger" >/dev/null 2>&1 \
    || { [ -e "$ledger" ] && mv "$ledger" "$ledger.bak-$(date +%s)" && echo "WARN: corrupt/unknown ledger moved aside"; \
         jq -n --arg r "$root" '{schemaVersion:1, projectRoot:$r, watermark:null, analyzed:[]}' > "$ledger"; }
fi
```

`--dry-run` reads the ledger only if it already exists (a missing/corrupt one just means "everything
eligible" for the preview).

**Advisory lock** (guards two harvests of the same project running at once): `mkdir "$ledger.lock"` — if
it already exists, steal it when its mtime is > 30 min old (stale), else abort with "another harvest is
running for this project". Release it in SKILL.md Step 6 and on any abort. (`--dry-run` takes no lock.)

**Discover the project's transcripts** — use `find`, **never a bare glob** (`for tx in "$pdir"/*.jsonl`
aborts under zsh's `nomatch` on an empty dir, making the empty-dir fallback unreachable — the same trap
chassis §B/§D avoid):

```bash
find "$pdir" -maxdepth 1 -name '*.jsonl' 2>/dev/null | while read -r tx; do
  sid="$(basename "$tx" .jsonl)"
  end="$(tail -n 50 "$tx" | command grep -o '"timestamp":"[^"]*"' | tail -1 | cut -d'"' -f4)"
  [ -z "$end" ] && end="$(date -u -r "$(stat -f %m "$tx")" +%Y-%m-%dT%H:%M:%SZ)"   # mtime fallback (macOS/BSD; GNU: date -u -d "@$(stat -c %Y "$tx")")
  printf '%s\t%s\t%s\t%s\t%s\n' "$tx" "$sid" "$end" "$(wc -l <"$tx")" "$([ "$tx" = "$active" ] && echo 1 || echo 0)"
done
```

`command grep` — the interactive `grep` here is a ugrep wrapper that skips `.jsonl` as "binary". The
first/last physical lines can lack a `timestamp`, hence `tail -n 50` + the mtime fallback — an empty `end`
must never reach the watermark comparison. Empty `find` output → **`NO_TRANSCRIPTS`** → `AskUserQuestion`
fallback (offer a session id / path, i.e. single mode); in `--headless` mode print the message and stop
cleanly instead of asking.

**Eligibility (§K.6).** Decide per discovered transcript by the **§K.6 eligibility rules** — §K.3 rules
1–2 (ledger-outcome-first; un-ledgered eligible iff `endTs > watermark`) plus the harvest-specific deltas
(the **active** session is always analyzed but never ledgered/watermarked; other live transcripts with
mtime < 5 min are excluded; single-session runs don't move the watermark; the cap counts non-active
only). **`--headless` drops the active session entirely** — in a headless run the active transcript is
the headless runner itself, so there is nothing worth analyzing in it. List the eligible **non-active**
survivors, one line each, plus the active session flagged:

```
<sid-8> · <end-date> · <lines>[ · ACTIVE]
```

**Grown-session notice (§K.6/§K.4):** when a ledgered entry's recorded `lineCount` is smaller than the
live `wc -l`, print "N previously-harvested sessions have grown — remove their ledger entries to
re-harvest": `jq 'del(.analyzed[] | select(.sessionId=="<sid>"))' "$ledger"`.

**Cap = 12 non-active per run** (the active session always rides along, uncounted). ≤ 12 → proceed after
printing the list. > 12 → **one** `AskUserQuestion`: **Newest 12** (default) / Newest 24 / All N (cost
warning) / Abort — note in the question that after this answer the run is unattended to completion (in
auto mode). In `--headless` mode never ask: take **Newest 12** and say so. Remainders are ledgered
`skipped-cap` **immediately** in one §K.7 write (no watermark clause — they are re-eligible by outcome,
§K.3 rule 1) so a later crash cannot lose the cap decision.

**Order the survivors oldest→newest by `endTs`, active session (if analyzed) last.** Oldest-first is what
makes the per-session watermark advance monotonic (Phase B.6), and it lets artifacts accrete forward in
time — a later session's near-duplicate proposal lands on the already-created artifact as an update.

**Zero eligible non-active** → "nothing new since `<watermark>` — analyzing the active session only", then
continue with just the active session (in `--headless` mode: stop cleanly instead).

**`--dry-run` stops here:** present the discovery list, eligibility, and cap outcome, then stop — no lock,
no `mkdir`/init writes, no agents, no ledger mutation.

---

## Phase B — Per-session analyze → fold loop

Process the ordered survivors **one at a time** — never in parallel batches. Sequential processing is
what bounds context (one session's specs in memory at a time), keeps the watermark monotonic, and lets
each session build on the artifacts the previous ones created.

**Per-session mode gate:** steps 2–4 below are the **auto** path. In `--review` mode, after step 1's
dispatch, apply only SKILL.md Step 3's validation (catalog + minimality — not the auto bar, not
auto-scope), then run **SKILL.md Steps 4–5** interactively for THIS session's opportunities (cards +
multi-select + scope question + per-update diff-confirm) and rejoin at step 5. Zero selection →
record "nothing materialized" for this session, ledger it `no-opportunities` in step 6 (it will not
be re-offered — the `jq del` escape hatch re-harvests it), and continue the loop; never re-ask.

For **each** session, in order:

1. **Dispatch** one `Explore`/sonnet subagent per the brief in **SKILL.md Step 2**, with the transcript
   **PATH** only (chassis §C). It returns the **full contract** — `draft_spec` included — so every
   passing artifact can be applied immediately, in this same iteration.

2. **Rubric.** Apply **SKILL.md Step 3** (catalog validation + minimality) to the session's
   opportunities. In auto mode, additionally enforce the **auto bar** — with no human filter, only
   clearly-earned artifacts may fold:
   - **Recurrence ≥2 strictly, with ≥2 concrete evidence refs.** Speculative or evidence-thin items go
     to the report's "suggested, not folded" list instead.
   - **Minimality, enforced hard:** drop any artifact whose `role_in_workflow` is not load-bearing;
     when in doubt, drop the artifact, not the usage.
   - **Suggest-only types never auto-fold** (keybindings, monitors, status line — see the catalog), and
     neither does anything requiring a real secret value. Report as suggestions.
   - **Run-manifest convergence:** an opportunity matching a usage already folded this run (same
     invocation or same artifact name) routes as an **update** to the existing artifact, never a
     parallel create.

3. **Auto-scope** (auto mode): every artifact lands at **project scope** (`<repo>/.claude/...`,
   `<repo>/CLAUDE.md`, `<repo>/.mcp.json` per the catalog's per-type "On-disk location" tables) — project scope puts every
   auto-write inside the repo where `git diff` gives the user a free post-hoc review. Not a git repo →
   **user** scope (same fallback as SKILL.md's edge cases). **Plugin scope is never auto-chosen**; an
   agent's `recommended_scope` of `user` or `plugin` is coerced to project and recorded in the report as
   a note ("agent suggested `<scope>` — move manually if wanted").

4. **Apply** via **SKILL.md Step 5** mechanics — `test -e` create-vs-update, sibling scan, the three
   merge strategies with backup + `jq empty` validate + restore, `<PLACEHOLDER>` secrets, frontmatter
   check — with **no confirmation**, under two auto-mode guards:
   - **No-op skip:** before any update, compute the effective change. A diff that adds nothing (or
     only whitespace), or a merge-json write whose applied recipe leaves the file unchanged (apply
     the catalog recipe to a copy and compare — e.g. `jq -e --argjson frag '<frag>' '(. * $frag) == .'`
     for object-valued fragments, an element-presence check for array-append recipes; never a bare
     `contains($frag)`, whose substring semantics false-positive) → **skip, record "no-op"**. This is
     what absorbs fork/resume transcript copies: the copy's identical proposal hits `test -e` →
     update → no-op → skipped.
   - **Insert-only updates:** never delete or rewrite existing lines in an existing artifact
     (append-section is inherently safe; whole-file updates must be pure insertions). An update that
     requires rewriting existing content is **deferred to the report** as a suggestion, not applied.
     When the two guards disagree (a "mostly-identical" regenerated file), insert-only wins: defer,
     don't guess.

5. **Report.** Append this session's section to `reports/<hash>-<ts>.md` (sid, opportunities,
   per-artifact created/updated/no-op/deferred with evidence refs, `also_noticed`). The report file is
   created on the first session and `lastRun.report` set in Phase C — findings are durable even if a
   later session crashes the run.

6. **Ledger + watermark in ONE §K.7 write** (the extended recipe with the `--arg wm` watermark clause):
   the session's `analyzed[]` entry (`outcome` ∈ `harvested | no-opportunities | error`, plus `folded` =
   artifacts written) **and** `watermark = max(old, this session's endTs)` land in the same jq
   transaction. Oldest→newest ordering makes the incremental max equal this session's `endTs`, so §K.4's
   rule holds after every write and a crash loses at most the in-flight session. **The active session
   skips this step entirely** — folded but never ledgered, never watermarked.

7. **Context hygiene.** Drop the session's `draft_spec`s and agent return; keep only one-line
   run-manifest entries (usage title · invocation · artifact path · type · created/updated/no-op/
   deferred) for the Step 6 table and convergence checks.

**Failure isolation:** an analysis-agent failure or an apply failure ledgers that session `error`
(re-eligible next run, §K.3 rule 1) and the loop **continues** with the next session — one bad session
must not sink the run.

---

## Phase C — Finalize + report

Set `lastRun` (§K.6): `{at, mode: "project-wide", sessionsAnalyzed, sessionsSkippedCap,
artifactsCreated, artifactsUpdated, updatesSkippedNoop, report}`. The watermark was already advanced
incrementally in Phase B — never touch it here beyond verifying it equals the newest disposed
session's `endTs`.

**Then return to [`../SKILL.md`](../SKILL.md) Step 6 (report)** with the run manifest: print the
usage-grouped table, the LOAD note, the deferred-suggestions list ("suggested, not folded" + coerced
scopes + rewrite-requiring updates), the project-wide state block, and release the lock.
