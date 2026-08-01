# Session → Plugin — shared chassis

**Purpose.** The steps every *session-driven plugin* skill shares — transcript resolution, the
plugin-purpose map, the artifact catalog, per-type write safety, validation, expert review, the
user-confirmation card, and the publish handoff. `audit-plugin` (fix how an **existing** plugin
misbehaved, from one session) and `learn` (audit + enhance a plugin across its sessions) both read this
file so the mechanics live in **one** place. Each skill keeps only its **distinct lens** (what to look
for — the AUDIT/ENHANCE briefs live in `references/analysis-lenses.md`) and points here for the rest.
`learn`/`track` additionally share **§K** (multi-session discovery, usage tracking + the learning
ledger); `harvest-automations` shares **§K** too and owns its project-scoped harvest ledger there at
**§K.6/§K.7**.

Read this once at the start of a run; reference its sections by letter (§A … §K). Do **not** re-narrate
these mechanics inside a skill.

---

## §A — Resolve the session transcript (+ subagents)

The input selects **which** session to analyze: **empty** = the active session; a **session id**
(UUID) = resolved under `$cfg/projects/` (see the `cfg` line below); a **path** to a `.jsonl` = used directly.

```bash
cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"                     # real transcripts live under $cfg, not a hardcoded ~/.claude
arg="$1"                                                       # UUID · path · empty
arg="$(printf '%s' "$arg" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"   # trim

if [ -z "$arg" ]; then                                        # active session under hashed cwd
  root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  hash="$(printf '%s' "$root" | sed 's/[/.]/-/g')"
  tx="$(ls -t "$cfg/projects/$hash"/*.jsonl 2>/dev/null | head -1)"
elif printf '%s' "$arg" | grep -Eq '(/|\.jsonl$)'; then
  tx="$arg"                                                    # looks like a path
else
  tx="$(find "$cfg/projects" -maxdepth 2 -name "${arg}.jsonl" 2>/dev/null | head -1)"
fi
[ -n "$tx" ] && [ -e "$tx" ] && echo "$tx ($(wc -l <"$tx") lines)" || echo "NO_TRANSCRIPT"

# Subagents dir (sidechain meta + jsonl) — evidence + a fallback when attribution is sparse:
if [ -n "$tx" ] && [ -e "$tx" ]; then
  sid="$(basename "$tx" .jsonl)"
  find "$cfg/projects" -type d -path "*/${sid}/subagents" 2>/dev/null
fi
```

Pick the **largest / top-level `<id>.jsonl`** (directly under a project dir, **not** a file under
`.../<id>/subagents/`) as the main transcript. `NO_TRANSCRIPT` → `AskUserQuestion` for a valid id/path
(the id may belong to another machine, or nothing auto-discovered). Confirm the intended session by
reading only the **tail** (`tail -n 5 "$tx"`) — never the whole file. The `subagents/*.meta.json`
files summarize each dispatched agent's work.

## §B — Build the plugin-purpose map

Build it **dynamically** — never hardcode plugin names or purposes — from each plugin's manifest. New
plugins appear here automatically.

```bash
# find (not a bare glob): a bare `for f in plugins/*/...` aborts under zsh's nomatch when
# plugins/ is absent — the same failure §D avoids. find degrades to an empty map instead.
find plugins -maxdepth 3 -path '*/.claude-plugin/plugin.json' 2>/dev/null | while read -r f; do
  python3 -c "import json,sys; d=json.load(open('$f')); print(d['name'],'::',d.get('description',''))"
done
```

This map drives purpose-matched plugin selection/routing and the labels in the confirmation card (§I).

## §C — HARD RULE: never read the whole transcript in the main thread

Pass only **PATHs** to the analysis subagents. If you must peek (e.g. for selection), stream with
`jq -c` / `python3` and read summaries, not raw bodies. Transcripts are large; loading one blows the
main context and defeats the point of delegating. Subagents return **FINDINGS** (distilled, word-
capped) + **EVIDENCE** (`file:line` / line refs only) + **OPEN QUESTIONS** — **never** raw transcript
dumps.

## §D — Resolve the artifact catalog

The catalog is the authority on **which artifact type fits which recurring pattern**, the per-type
templates, merge recipes, per-type safety, the minimality principle, and the "Composing usage bundles"
legitimate pairings / anti-patterns. **Resolve it by glob — never hardcode a path** (it may move):

```bash
# find (not a bare glob): robust when one search root is absent — a bare multi-pattern glob
# aborts under zsh's nomatch when e.g. plugins/ doesn't exist, silently defeating resolution.
catalog="$(find .claude/skills plugins -path '*/references/artifact-catalog.md' 2>/dev/null | head -1)"
[ -n "$catalog" ] && echo "catalog: $catalog" || echo "NO_CATALOG — using inline fallback rubric"
```

If found, `Read` it and reference its mechanics; do **not** re-narrate them. Subagents can't call
`Skill()`, so when a reviewer/analyzer needs the rubric, **inline the relevant playbook** into its
brief.

**Inline fallback rubric** (use only when the glob finds nothing):

| Recurring pattern | Best artifact | Safety / strategy |
|---|---|---|
| Same multi-step procedure done by hand 2+ times | **skill** | whole-file (new) / append-section (extend) |
| Same short phrase typed repeatedly to start the same work | **command** (thin entry point) | whole-file |
| Heavy / isolatable / parallelizable work done inline | **subagent** | whole-file |
| "Every time X happens, do Y" regardless of context | **hook** | merge-json into `hooks.json` |
| Repeated approval prompts for the same command | **permission** | merge-json (`allow += […] \| unique`) |
| Guidance that should fire only for certain file paths | **rule** | whole-file / append-section |

A command may only accompany a skill as a **thin delegating entry point**
("Follow the `<skill>` skill with $ARGUMENTS") — never duplicate the steps in both.

## §E — Per-type write safety

- **merge-json** (a hook in `hooks.json`, a permission, an mcp entry): **backup first**, edit with
  `jq`, validate with `jq empty`, **restore the backup on failure** — never partial-write or drop
  sibling keys.
- **append-section** (a step/section added to an existing skill/command, a rule): add a new clearly
  headed section; never rewrite existing content.
- **whole-file** (a new skill/command/agent): write the template on create; on edit, `Read` → insert
  → write back.

## §F — Hook paths use `${CLAUDE_PLUGIN_ROOT}`

Hook command templates must use `${CLAUDE_PLUGIN_ROOT}` (e.g.
`bash ${CLAUDE_PLUGIN_ROOT}/hooks/<script>.sh`) — **never** a hardcoded `/Users/...` or
`~/.claude/plugins/...` path. A hardcoded path silently breaks every hook once the plugin installs
under `~/.claude/plugins/cache/...`, and `publish-plugin` will reject it.

## §G — Validate before publishing

```bash
# Embedded Python in any hook heredoc:
python3 - "<hook-script>" << 'PY'
import sys
c = open(sys.argv[1]).read()
i = c.find("<< 'PYEOF'"); s = c.index('\n', i) + 1; e = c.find('\nPYEOF\n', s)
try: compile(c[s:e], 'block.py', 'exec'); print('Python OK')
except SyntaxError as ex: print(f'SYNTAX ERROR line {ex.lineno}: {ex.msg}')
PY

# Any JSON touched (hooks.json, marketplace.json, settings):
python3 -m json.tool "<file.json>" >/dev/null && echo "JSON OK"
```

Then **grep each target file** to confirm every intended change actually landed.

## §H — Expert review (mandatory, right-sized)

Independent review is what separates a real change from a plausible-but-wrong one. Size it to the
proposal:

- **Default — ONE reviewer:** dispatch a single `Plan` agent (opus, high effort) for a small, low-risk
  set (one or two whole-file artifacts / contained fixes, no hooks, no settings merges).
- **Escalate — the 3-dimension parallel trio** for a non-trivial set (any **hook**/`hooks.json` merge,
  **multiple artifacts**, or a **merge-json into settings**). Fan out three reviewers in **one** `Agent`
  batch:
  - **practicality** — will this actually remove the friction / correct the misbehavior the user hit,
    and will they reach for it? does the workflow match how they really worked?
  - **comprehensiveness** — does the set cover the whole redundancy / all the bugs, or leave a manual
    seam? did the composing-entry-point self-notice get the right answer?
  - **cleanliness** — minimality (no redundant artifacts), correct artifact types per catalog, correct
    create/edit + safety strategy, no hardcoded paths, fits the plugin's design philosophy.

Pick reviewer agent(s) at runtime (score the `Agent` tool's `subagent_type` enum toward an
architect/reviewer bag; fall back to `general-purpose`). Give each the proposal, the target plugin's
source paths + its **design philosophy stated explicitly**, and — since subagents can't call
`Skill()` — **inline the relevant catalog playbook** they need. Each returns **APPROVE / REVISE /
REJECT per item** with reasoning and flags issues not in the set. Fold verdicts back in (revise
REVISEs, drop REJECTs, add anything newly found), then re-read the updated set.

**Sequential callers** (e.g. `learn`'s per-session loop) invoke this review **once per session** over
that session's item set — right-sizing then usually lands at ONE reviewer, with the trio reserved for
sessions whose items include a hook/settings merge or multiple artifacts.

## §I — Confirm with the user (usages, not artifact types)

Print a **compact card per proposed usage/item**, then **immediately** call **one** `AskUserQuestion`
**multi-select** in the same turn — never end the turn on the cards alone. The user picks **USAGES**
(whole workflows / fixes), never raw artifact types; the artifacts behind each are an implementation
footnote.

```
## <#>. <title>
**You do / hit:** <one invocation — '/cmd <args>', a phrase, 'automatic on <event>' — or the bug observed>
**Today (manual) / Before:** <the redundant loop, or the misbehavior, from this session>
**After:** <the one-step / shortened flow, or the corrected behavior>
**You get:** <manual work removed / bug fixed>
**Behind it:** creates `…`, edits `…`, fixes `…`   (recurrence ×N / severity P#)
```

`AskUserQuestion` option per usage: `label` = short handle (≤16 chars); `description` =
`<invocation/lens> — <outcome ≤~80 chars> (creates N, edits M / fixes …)`.

**Zero selection** (the user picks nothing, or interrupts) → stop cleanly: report "nothing
materialized", create/change nothing, do **not** publish. This is a valid no-op outcome.

## §J — Publish handoff

**Publish exactly once**, via `Skill(skill="publish-plugin")`, passing the plugin and the bump as
**INTENT** — e.g. "release `<plugin>` as a **minor** bump: new <artifacts> that remove <redundancy>"
(or "**patch**: fixes <bugs>", or for a first release "first release at 0.1.0 — do not bump").
`publish-plugin` has **no positional parser** — it classifies the bump itself (new artifact surface →
**minor**; bug-only → **patch**; breaking → **major**), syncs manifests + README, validates JSON,
checks hook paths, and commits + pushes to the repo's default branch. Let it own that; let the commit
body enumerate the changes. Report the **new version** and the `old..new` push line, and advise the user to
run **`/reload-plugins`** so the plugin loads. One plugin per publish.

---

## §K — Multi-session discovery, usage tracking + learning ledger

The steps `learn` (analyze **every** session that used plugin X) and `track` (opt-in usage indexer)
share below. `audit-plugin` and single-session `learn` work on **one** session (§A);
`harvest-automations` adds a **project-scoped sweep** (its harvest-ledger spec + persistence recipe live
at §K.6/§K.7); batch `learn` works on **the whole history** for one plugin, so it needs a marker
pattern, a config-dir-wide scan (every project under `$cfg/projects` — the active config dir, not
the whole machine), a per-plugin ledger + watermark, and — when `track` is set up — a usage
index that lets it skip most scanning.

Everywhere in §K, `cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"` and scan `"$cfg/projects"` — §A now
resolves the same `$cfg`, so there is no §A/§K divergence to guard against.

### §K.1 — Usage-marker pattern

A session "used plugin X" if its transcript carries any marker: a namespaced Skill call
(`"skill":"<plugin>:<skill>"`), a namespaced command marker (`<command-name>/<plugin>:<cmd>`), a
**bare** skill name (`"skill":"publish-plugin"` — real transcripts drop the namespace), or an
**unqualified command marker** (`<command-name>/plan` — the *dominant* form for command-driven plugins
like mentor: verified 5 unqualified vs 2 namespaced hits). Bare/unqualified markers admit false
positives (a `/plan` from another source); that is acceptable — the per-session agent returns
`NO USAGE FOUND` → ledgered `no-usage`, never rescanned. Order namespaced hits ahead of bare-only ones
(K.3) so false positives never crowd real sessions out of a capped run.

The builder takes a **surface root** so it works from either caller: the marketplace repo's `plugins/`
(when `learn` runs, cwd = repo), or a marketplace **install location** (when the hook runs, any cwd):

```bash
cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
sroot="$1"                             # "$repo/plugins"  OR  "$cfg/plugins/marketplaces/<mkt>/plugins"
plugin="$2"
pat="\"skill\":\"${plugin}:|<command-name>/${plugin}:"
bare="$(ls "$sroot/${plugin}/skills" 2>/dev/null | paste -sd'|' -)"
[ -n "$bare" ] && pat="${pat}|\"skill\":\"(${bare})\""
cmds="$(ls "$sroot/${plugin}/commands" 2>/dev/null | sed 's/\.md$//' | paste -sd'|' -)"
[ -n "$cmds" ] && pat="${pat}|<command-name>/(${plugin}:)?(${cmds})<"   # unqualified commands too
```

### §K.2 — Scan pipeline (backfill path)

The full config-dir-wide scan — used by `learn` for sessions the index has never seen (pre-hook history,
or projects where loom isn't enabled). `command grep` **throughout**: interactive `grep` here is a
ugrep wrapper (`--ignore-files -I`) that silently skips `.jsonl` as "binary".

```bash
main=$(find "$cfg/projects" -maxdepth 2 -name '*.jsonl' -print0 \
       | xargs -0 command grep -lE -m1 "$pat" 2>/dev/null)
side=$(find "$cfg/projects" -mindepth 4 -maxdepth 4 -path '*/subagents/agent-*.jsonl' -print0 \
       | xargs -0 command grep -lE -m1 "$pat" 2>/dev/null \
       | sed 's|/subagents/agent-[^/]*\.jsonl$|.jsonl|')     # sidecar → parent transcript

# dedupe + one TSV row per candidate:  tx  sid  proj  endTs  markerCount  viaSubagent
printf '%s\n%s\n' "$main" "$side" | command grep . | sort -u | while read -r tx; do
  [ -e "$tx" ] || { echo "WARN: sidecar parent missing: $tx" >&2; continue; }   # orphan sidecar → skip
  sid=$(basename "$tx" .jsonl); proj=$(basename "$(dirname "$tx")")
  end=$(tail -n 50 "$tx" | command grep -o '"timestamp":"[^"]*"' | tail -1 | cut -d'"' -f4)
  [ -z "$end" ] && end="$(date -u -r "$(stat -f %m "$tx")" +%Y-%m-%dT%H:%M:%SZ)"   # mtime fallback (macOS)
  n=$(command grep -cE "$pat" "$tx" 2>/dev/null); n=${n:-0}   # NOT `|| echo 0`: grep -c prints 0 AND exits 1
  if printf '%s\n' "$side" | command grep -qxF "$tx"; then sub=1; else sub=0; fi   # exact-line match
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$tx" "$sid" "$proj" "$end" "$n" "$sub"
done
```

Notes: the first/last physical lines can lack `timestamp` (hence `tail -n 50` + the mtime fallback — an
**empty endTs must never reach the watermark comparison**). Z-suffixed UTC ISO-8601 → lexicographic
compare is valid. `markers=0 & viaSub=1` = "used only inside a spawned agent". When a usage index exists
(K.5), restrict the `find` set to sessionIds **absent from the index OR present without the target key**
before grepping — that is the whole speedup.

### §K.3 — Filter + ordering

Pipe candidates (index hits ∪ scan hits) through `python3`. **Eligibility is ledger-outcome-first** —
this ordering is what makes re-eligibility work; the watermark applies **only** to un-ledgered sessions:

1. `sessionId ∈ analyzed[]` → keep **iff** `outcome ∈ {error, skipped-cap}`; else drop. ("never
   re-analyze" must not become "never analyze": errors and capped remainders come back.)
2. Not in ledger → keep iff `endTs > watermark` (or no watermark yet).
3. Drop the **active session** — newest `.jsonl` under `"$cfg/projects/<hashed-cwd>"` (hash = the cwd
   with `/` and `.` → `-`). Restate this with `$cfg` (a hardcoded `~/.claude` would be the wrong dir
   on a machine that sets `CLAUDE_CONFIG_DIR`).
4. Drop transcripts with mtime < 5 min (possibly still being written) — excluded, **not** ledgered,
   eligible next run.

Survivors sort newest-first by mtime; namespaced-marker candidates ahead of bare/unqualified-only ones.

### §K.4 — Ledger schema + watermark semantics

`$cfg/loom/learning/<plugin>.json`:

```json
{ "schemaVersion": 1, "plugin": "mentor",
  "watermark": "2026-07-14T04:08:24.718Z",
  "lastRun": { "at": "…", "sessionsAnalyzed": 3, "sessionsSkippedCap": 0,
               "findingsProposed": 7, "findingsAccepted": 2,
               "publishedVersion": "0.46.0", "report": "reports/mentor-20260716-091200.md" },
  "analyzed": [
    { "sessionId": "0e7b241f-…", "transcriptPath": "/…/projects/…/0e7b241f-….jsonl",
      "project": "-Users-…-poc-eks-argo-workflow", "sessionEndTs": "2026-07-14T08:49:17.483Z",
      "lineCount": 1487, "markerHits": 2, "viaSubagent": false,
      "analyzedAt": "2026-07-16T09:05:11Z", "findings": 3, "outcome": "analyzed" } ] }
```

`outcome` enum: `analyzed` · `no-usage` · `skipped-cap` · `error`. **`error` AND `skipped-cap` are
re-eligible** (K.3 rule 1). Watermark rule (verbatim): `watermark = max(old, max sessionEndTs over
sessions disposed this run)` — **never `now()`** (that would permanently skip the excluded active
session and in-flight sessions on other terminals); never moves backwards; sound because every matching
session older than it is already in `analyzed[]`. Batch `learn` persists **per session**: sessions are
processed **oldest→newest** and each session's `analyzed[]` entry plus the watermark advance land in
**one** §K.7 write immediately after that session is disposed — the incremental max equals that
session's `sessionEndTs`, so the rule holds after every write and a crash loses at most the in-flight
session (`skipped-cap` remainders are ledgered up front at cap resolution; re-eligible by outcome, so
the watermark passing them is sound). Grown-after-analysis sessions are not auto-re-analyzed
in v1 (`lineCount` recorded; a run prints "N previously-analyzed sessions have grown — remove their
ledger entries to re-learn"). Unknown/newer `schemaVersion` → treat as corrupt (move aside, warn,
start fresh). Escape hatches: delete the ledger (full reset), or
`jq 'del(.analyzed[] | select(.sessionId=="<sid>"))'` (targeted re-learn).

### §K.5 — Usage index (hook-written)

`$cfg/loom/learning/usage-index.jsonl` — one line per finished session, appended by the SessionEnd hook:

```json
{ "sessionId": "…", "tx": "/…/projects/…/<id>.jsonl", "endTs": "2026-07-16T11:32:04Z",
  "cwd": "/Users/…/project/x", "plugins": { "mentor": 14, "sdlc-mini": 0, "ntbx-infra": 3 } }
```

One line carries **one count per tracked plugin across every marketplace**. **Written even when all
counts are 0** (`"plugins": {}`): a line records exactly which plugins the hook *evaluated* for that
session. Reading: skip malformed lines; **last line per sessionId wins** (duplicate SessionEnd firings
are harmless). `learn` consumes it **per target key**, not per line:

- `plugins[target] > 0` → candidate, **no scan**.
- line has key `target` with value `0` → skip, **no scan** (the hook scanned; target wasn't used).
- line present but **missing** key `target` → **must K.2-scan** — the hook never evaluated `target`
  for this session (it ended before `target` was tracked). Missing key ≠ zero.
- line absent entirely → **must K.2-scan**.

So K.2 restricts its `find` set to sessionIds that are either absent from the index **or** present
without the target key. The index is disposable — deleting it only means the next `learn` run scans
more.

### §K.6 — `harvest-automations` project-scoped harvest ledger (authoritative)

`harvest-automations`' project-wide mode keeps its own ledger + watermark, keyed by **project** (a
project hash, not a plugin name like §K.4). This section is the **single source of truth** for its
schema and eligibility; `references/project-wide.md` owns only the orchestration (discovery loop, lock,
the sequential per-session fold loop) and points here for the state rules. It does not consume §K.1/§K.2/§K.5
(those are the config-dir-wide, per-plugin discovery path — harvest's sweep is per-project).

**State location:**

- `$cfg/loom/harvest/<hashed-project>.json` — per-project analyzed ledger + watermark;
- `$cfg/loom/harvest/reports/` — consolidated + raw project-wide reports.

**Ledger schema** (`$cfg/loom/harvest/<hash>.json`):

```json
{ "schemaVersion": 1, "projectRoot": "/Users/…",
  "watermark": "2026-07-14T04:08:24.718Z",
  "lastRun": { "at": "…", "mode": "project-wide", "sessionsAnalyzed": 5, "sessionsSkippedCap": 0,
               "artifactsCreated": 3, "artifactsUpdated": 2, "updatesSkippedNoop": 1,
               "report": "reports/<hash>-<ts>.md" },
  "analyzed": [ { "sessionId": "…", "transcriptPath": "…", "sessionEndTs": "…", "lineCount": 1487,
                  "analyzedAt": "…", "opportunities": 3, "folded": 2, "outcome": "harvested" } ] }
```

`outcome` enum: `harvested | no-opportunities | skipped-cap | error` — only `skipped-cap`/`error` are
re-eligible (as §K.3 rule 1). The filename carries the hash (no `project` field); there is no per-entry
`mode`. `analyzedAt` matches §K.4 naming. `folded` (optional) = artifacts actually written for that
session. `lastRun` is **informational only** — consumers key off `schemaVersion`/`watermark`/
`analyzed[]`, so a `lastRun` field change does not bump `schemaVersion`; an old ledger's `lastRun` is
simply overwritten on the next run. Corrupt / unknown-`schemaVersion` → move aside
(`<ledger>.bak-<ts>`), warn, re-init fresh.

**Eligibility** — §K.3 rule 1 (ledger-outcome-first: `error`/`skipped-cap` come back; `harvested`/
`no-opportunities` do not) and rule 2 (un-ledgered → eligible iff `endTs > watermark`), with these
**harvest-specific deltas**:

- The **active** session (newest `.jsonl` under the project dir) is **always analyzed but never
  ledgered** and never advances the watermark — harvest's core value is the session you just finished.
- Any **other** live transcript (mtime < 5 min) is excluded this run and left un-ledgered (eligible
  next run).
- **Single-session** runs (a session id/path) ledger their one session **without** moving the watermark
  (one run does not establish that everything older was analyzed).
- The **cap counts non-active sessions only** (= 12 per run; the active session always rides along).

**Watermark** — the §K.4 rule verbatim (`watermark = max(old, max sessionEndTs over sessions disposed
this run)`, never `now()`, never backwards); the active session is excluded by construction and
single-session runs never advance it. **Project-wide persistence is per session:** sessions are
processed **oldest→newest**, and each session's `analyzed[]` entry plus the watermark advance land in
**one** §K.7 write immediately after that session is folded — the incremental max equals that session's
`sessionEndTs`, so the rule holds after every write and a crash loses at most the in-flight session.
`skipped-cap` remainders are ledgered up front at cap resolution (re-eligible by outcome, so the
watermark passing them is sound). Grown-after-analysis handling is §K.4's (recorded `lineCount`; a
run prints "N previously-harvested sessions have grown — remove their ledger entries to re-harvest" with
the `jq 'del(.analyzed[] | select(.sessionId=="<sid>"))'` escape hatch).

### §K.7 — Ledger persistence: del-then-append recipe

Appending entries to an `analyzed[]` array must **never** use §E's merge-json `. * $frag` deep-merge —
jq's `*` **replaces** arrays, so a deep-merge would drop every prior entry. Use del-then-append inside
§E's backup → validate → restore-on-failure envelope (delete any existing entry with the same
`sessionId`, then append the batch — so re-runs **replace** rather than duplicate):

```bash
bak="$ledger.bak.$(date +%s)"; cp "$ledger" "$bak"
jq --argjson batch "$entries" \
  '.analyzed = ([.analyzed[] | select([.sessionId] | inside($batch | map(.sessionId)) | not)] + $batch)' \
  "$ledger" > "$ledger.tmp" && jq empty "$ledger.tmp" && mv "$ledger.tmp" "$ledger" \
  || { echo "INVALID — restoring"; rm -f "$ledger.tmp"; cp "$bak" "$ledger"; }
```

Restore from the **captured** `$bak`, never a `"$ledger".bak.*` glob — once more than one backup
exists, the glob expands to multiple sources and `cp` fails (`Not a directory`), silently losing the
restore. Per-session loops back up on every write, so this bites from session 2 onward.

`$entries` is the array of `analyzed[]` objects to write (usually one, in the per-session loops).
Sequential callers extend the same jq program with the watermark advance so entry + watermark land in
one transaction — never in two writes:

```bash
jq --argjson batch "$entries" --arg wm "$endTs" \
  '.analyzed = ([.analyzed[] | select([.sessionId] | inside($batch | map(.sessionId)) | not)] + $batch)
   | .watermark = (if .watermark == null or .watermark < $wm then $wm else .watermark end)' ...
```

**Consumers:** `learn` Step 5 (per session, per-plugin ledger at §K.4), `harvest-automations`
project-wide Phase B (per session, watermark advanced in the same write) and single-mode (one entry, no
watermark clause, §K.6). This is the one place the recipe lives.
