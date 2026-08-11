---
name: harvest-automations
description: >
  Analyzes Claude Code session transcripts, detects repeated manual prompts and multi-step work you
  keep doing by hand, then CREATES or UPDATES reusable artifacts across the full customization
  surface — skills, commands, subagents, hooks, permissions, CLAUDE.md/memory, rules, MCP servers,
  output styles. Never packages or publishes a plugin (use audit-plugin or learn for that). With NO
  argument it harvests ALL un-harvested sessions of the current project one at a time, oldest first,
  auto-folding passing artifacts as it goes (--review confirms each session, --headless never
  prompts, --dry-run previews; ledger + watermark skip sessions already done); a session id or
  .jsonl path harvests that ONE session interactively — "harvest this session" means the ACTIVE
  session, single mode. Invoked via "/harvest", "harvest this session/project", "harvest all
  sessions", "harvest session <id>", "turn this session into a skill / command / agent", "automate
  what I keep doing by hand", or "what could I have automated".
version: 1.0.0
---

# Harvest Automations

Turn the work you did by hand into reusable Claude Code customizations. This skill reads session
transcripts, finds patterns that repeated (>=2 near-identical asks, or a stable multi-tool macro),
and designs each one as a complete **usage/workflow** — how you'll trigger it, what happens end to
end, what you get. Each usage is delivered by the smallest artifact bundle per Claude guidance —
**creating new** artifacts or **merging into existing** ones across the whole customization surface.
In project-wide mode passing usages fold in **automatically** (everything lands at project scope, so
`git diff` is the review); in single mode — and per session with `--review` — you choose the usages
you want (never raw artifact types).

It runs in one of two **modes**, chosen by `$ARGUMENTS`:

- **project-wide** (no argument) — harvest **every un-harvested session of the current project**,
  sequentially, oldest→newest, **auto-folding each session's passing artifacts with no prompts**
  (ledger + watermark advance after each session, so a crash loses at most one session). A per-project
  **ledger + watermark** (the same mechanism `loom:learn` uses) skip sessions already harvested, so
  re-runs only pick up new work. Flags: `--dry-run` previews what would be analyzed; `--review` pauses
  each session for interactive confirmation before folding; `--headless` (for scheduled/unattended
  runs) never prompts at all and skips the active session.
- **single-session** (a session id or a transcript `.jsonl` path) — harvest that ONE session
  **interactively** (cards + confirm — the manual escape hatch), and record it in the ledger so a
  later project-wide run skips it.

The authoritative best-practice rubric (which pattern maps to which artifact), the per-type templates,
and the merge recipes live in **[`../../references/artifact-catalog.md`](../../references/artifact-catalog.md)**.
Read it before deciding artifact types and before writing any file. **Project-wide mode** adds a
multi-session layer — discovery, then a sequential per-session analyze→fold loop — orchestrated in
**[`references/project-wide.md`](references/project-wide.md)** so this file stays focused on the
single-session and shared flow. The harvest **ledger schema, eligibility, watermark rule, and the
del-then-append persistence recipe** are the single source of truth in chassis **§K.6/§K.7** — this
skill and `project-wide.md` reference them rather than keeping their own copies.

## When to use

- After a session where you repeated the same kind of request, or walked Claude through the same
  multi-step procedure more than once.
- When you want to sweep a **whole project's** sessions for everything worth automating — "harvest
  this project", "harvest all sessions", "what could I have automated across this repo".
- When you say "automate what I keep doing by hand" or "what could I have automated here".
- When you want this session's manual work distilled into a skill, command, subagent, hook,
  permission, CLAUDE.md entry, rule, MCP server, or output style.

## When NOT to use

- One-off tasks with nothing repeated. If nothing recurs >=2x, there is **nothing to harvest** —
  say so and create nothing.
- A session that was itself pure planning/exploration with no manual macro to capture.
- When the user wants a one-time artifact for a specific known need — just create it directly; you
  do not need transcript analysis for that.

`cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"` throughout — this machine's real transcripts and state
live under `$cfg`, **never** a hardcoded `$HOME/.claude`.

---

## Step 1 — Resolve mode + transcript(s)

`$ARGUMENTS` selects the mode, flags, and which session(s) to analyze:

- **empty** → **project-wide** mode (all un-harvested sessions of this project, auto-folded),
- **`--dry-run`** → project-wide **discovery-only preview** (nothing written, no agents),
- **`--review`** → project-wide with a **per-session interactive pause** (cards + confirm per session),
- **`--headless`** → project-wide, **never prompts** (cap auto-defaults, active session skipped;
  overrides `--review` — meant for scheduled runs, see `loom:automate`),
- a **session id** (a UUID like `e05bde45-3ed9-458d-9a2e-ba6744d64a18`) → **single** mode,
- an explicit **path** to a transcript `.jsonl` → **single** mode,
- the user asked for **"this session"** (no id) → **single** mode on the **active** transcript —
  never a project-wide sweep. The bash below cannot see conversational phrasing (its empty-`$arg`
  branch prints `MODE=project-wide`) — YOU route this case: run the project-wide preamble only to
  compute `active`, then set `tx="$active"` and follow the single-mode path.

```bash
cfg="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
arg="$ARGUMENTS"
arg="$(printf '%s' "$arg" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"   # trim
dry=0; review=0; headless=0
case " $arg " in *" --dry-run "*)  dry=1;;      esac
case " $arg " in *" --review "*)   review=1;;   esac
case " $arg " in *" --headless "*) headless=1;; esac
arg="$(printf '%s' "$arg" | sed 's/--dry-run//; s/--review//; s/--headless//' \
      | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
if [ "$headless" = 1 ]; then review=0; fi   # headless can never pause

if [ -z "$arg" ]; then
  # PROJECT-WIDE — compute the project's hashed transcript dir + the active (live) session
  root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  hash="$(printf '%s' "$root" | sed 's/[/.]/-/g')"
  pdir="$cfg/projects/$hash"
  active="$(find "$pdir" -maxdepth 1 -name '*.jsonl' -exec ls -t {} + 2>/dev/null | head -1)"   # newest = live session (find, never a bare glob — zsh nomatch)
  echo "MODE=project-wide dry=$dry review=$review headless=$headless pdir=$pdir active=$active"
elif printf '%s' "$arg" | grep -Eq '(/|\.jsonl$)'; then
  tx="$arg"; echo "MODE=single tx=$tx"                      # looks like a path — use directly
else
  # a session id — find <id>.jsonl. -maxdepth 2 keeps it to top-level main
  #   transcripts (projects/<hash>/<id>.jsonl), excluding .../<id>/subagents/
  tx="$(find "$cfg/projects" -maxdepth 2 -name "${arg}.jsonl" 2>/dev/null | head -1)"
  echo "MODE=single tx=$tx"
fi
```

The cwd is hashed by replacing every `/` and `.` with `-`. `ls -t` picks the most recently written
JSONL — the live session. A session id is unique per session, so the `find` resolves to exactly one
top-level transcript.

**Mode map.** single mode runs **Step 1 → Steps 2–6**. **Project-wide mode**, at the fork below, hands
off to **[`references/project-wide.md`](references/project-wide.md)**, which runs the whole sequential
per-session loop — reusing the analysis brief in **Step 2**, the rubric in **Step 3**, and the apply
mechanics in **Step 5** (and, under `--review`, the cards + confirm in **Step 4**) — then rejoins this
file at **Step 6 (report)**. `--dry-run` stops inside that file, right after discovery.

**Project-wide mode — read [`references/project-wide.md`](references/project-wide.md) now** and follow
its three phases (Discover & ledger → Per-session loop → Finalize). Return here at **Step 6** with the
run manifest.

**Single mode — confirm the transcript.** If `tx` is empty or missing, treat it as `NO_TRANSCRIPT`:

1. A supplied **session id or path that didn't resolve** — tell the user it wasn't found (the id may
   belong to a different machine or have been cleaned up) and use `AskUserQuestion` to ask for a
   correct session id or path.
2. Otherwise confirm it is the intended session by reading only the **tail**, never the whole
   file — `tail -n 5 <transcript-path>`, substituting the literal path Step 1 resolved (shell
   variables like `tx` don't survive between separate Bash calls).

   The transcript may be an older, different-cwd session, so sanity-check it parses and note its
   `cwd`/timestamp rather than expecting them to match the current repo.

**NEVER read a whole transcript into the main context** — only PATHs are passed onward to the analysis
subagents (chassis §C).

## Step 2 — Delegate analysis to a subagent

Dispatch **one** `Explore` (or `general-purpose`) subagent on **sonnet** per session, with the
transcript **PATH** — not its contents (chassis §C). Brief each to:

- Stream the JSONL with `jq -c` (do not load it whole), cluster by **user intent / usage** — what the
  user kept asking for and what end-to-end workflow served it — not by artifact type.
- Score recurrence: >=2 near-identical asks, or a stable multi-tool macro repeated across the session.
- For each opportunity, design the **usage** first (how the user triggers it, what happens end to end,
  what they get), then choose the **smallest set of artifacts** that delivers it — types, scopes,
  create/update modes per the rubric in `../../references/artifact-catalog.md`. One usage may bundle
  multiple artifacts (e.g. a command + the permission it needs).
- For huge transcripts (>~20k lines), **sample by intent-cluster** rather than full read.
- **Never paste raw transcript content back** — evidence is line numbers / short quote refs only.

Cap each agent's return at the **top 4** opportunities by impact (recurrence × manual effort saved);
extras go in a top-level `also_noticed` array (titles only), which the main agent mentions in chat as
"also noticed, not offered".

**Both modes use the full contract below.** In project-wide mode the loop in
[`references/project-wide.md`](references/project-wide.md) dispatches this same brief once per session,
sequentially — one session's specs in context at a time, dropped after that session is folded.

The subagent returns **ONLY** this JSON (full `draft_spec` per artifact):

```json
{ "also_noticed": ["one-line titles beyond the top 4, or empty"],
  "opportunities": [ {
  "title": "string — named after the USAGE, not the artifact",
  "usage": {
    "invocation": "exactly how the user triggers it: '/cmd <args>', a phrase, or 'automatic on <event>'",
    "example": "one concrete invocation taken from THIS session",
    "workflow": ["step-by-step what happens end to end, user-visible"],
    "outcome": "what the user gets and what manual work disappears"
  },
  "recurrence": { "count": 2, "evidence": ["line/quote refs"] },
  "best_practice_rationale": "why this artifact composition per Claude guidance",
  "artifacts": [ {
    "artifact_type": "skill|command|subagent|hook|permission|claude-md|rule|mcp-server|output-style",
    "role_in_workflow": "what this piece contributes to the usage",
    "mode": "create | update",
    "recommended_scope": "user | project | plugin",
    "target_path": "existing file to update, or null",
    "merge_strategy": "merge-json | append-section | whole-file",
    "draft_spec": { "name": "kebab", "trigger_phrases": ["..."], "steps": ["..."], "tools": ["..."], "argument_hint": "[hint]", "model": "opus|sonnet|haiku|null", "json_fragment": {} }
  } ]
} ] }
```

**Single-mode ledgering.** After **Step 5 completes** (the outcome — `harvested | no-opportunities |
error` — isn't known until the apply finishes), record the session in the harvest ledger so a later
project-wide run skips it — but only for **this project's own** transcripts (a transcript outside
`$cfg/projects/` is "analyzed but not ledgered"). Take the same advisory lock as project-wide
(`mkdir "$ledger.lock"`, steal if >30 min stale, release after the write) so a single run racing a
project-wide run can't clobber the ledger. Use the **§K.7 del-then-append recipe** and the `analyzed[]`
entry shape in **§K.6**; single mode writes only the entry and **never** touches the watermark — one
run does not establish that everything older has been analyzed. Take `projectRoot` from the transcript
tail's `cwd` (never un-hash a dir name — lossy); skip the write when the transcript is live relative
to its own dir (newest there, or mtime < 5 min).

## Step 3 — Apply the decision rubric

Read **[`../../references/artifact-catalog.md`](../../references/artifact-catalog.md)** for the authoritative
best-practice rubric (which pattern -> which artifact), the per-type templates, and the merge recipes.
Validate **every entry in each opportunity's `artifacts[]`** — `artifact_type` / `mode` /
`merge_strategy` — against the catalog before proposing. Project-wide mode applies this rubric per
session and, in auto mode, additionally enforces the tightened **auto bar** in
[`references/project-wide.md`](references/project-wide.md) Phase B (strict recurrence with evidence,
hard minimality, suggest-only deferral, run-manifest convergence).

Also enforce **minimality**: a bundle must be the **smallest set of artifacts that delivers the
usage**. Do not accept skill + command + agent when one artifact serves the workflow; a
multi-artifact bundle is justified only when the usage genuinely needs every piece (e.g. a command
entry point + the permission it requires). See the catalog's "Composing usage bundles" section for
legitimate pairings and anti-patterns.

Rubric headline (full detail in the catalog):

- **skill** — a repeated multi-step playbook worth naming and reusing.
- **command** — a fast, parameterized entry point for a frequent ask.
- **subagent** — isolated heavy or parallelizable work that should run off the main thread.
- **hook** — deterministic behavior that must always run on a given event.
- **permission** — a tool/command that keeps triggering approval prompts.
- **claude-md / memory** — a durable cross-session preference or project fact.
- **rule** — file-type-scoped guidance (applies when matching files are touched).
- **mcp-server** — access to an external tool or API.
- **output-style** — a persistent tone or role for the assistant.

## Step 4 — Propose usages to the user (single mode + per-session `--review` only)

Project-wide **auto** mode never reaches this step — it folds passing usages in automatically per
[`references/project-wide.md`](references/project-wide.md) Phase B. In `--review` mode this step runs
once **per session**, over that session's opportunities.

The user chooses a **usage/workflow**, never an artifact type. Each choice is one complete usage; the
artifacts behind it are implementation detail.

1. **Print a usage card per opportunity** in chat (markdown), then **immediately** call
   `AskUserQuestion` in the same turn — never end the turn on the cards alone. Card format:

   ```
   ## 1. <usage title>
   **You do:** /deploy-ticket <app> <env>
   **Example:** /deploy-ticket galio prod
   **What happens:**
   1. <end-to-end workflow steps, user-visible>
   **You get:** <outcome / manual work removed>
   **Behind it:** creates `commands/deploy-ticket.md` + `agents/ticket-runner.md` (recurrence x4)
   ```

   The "Behind it" line is a footnote — paths + recurrence count only; the card sells the usage.

2. `AskUserQuestion` **multi-select**, one option per usage:

   - `label` = short usage handle, 1-3 words / <=16 chars (e.g. `/deploy-ticket`, "env-var
     sync") — the full invocation belongs in the description and card, not the label.
   - `description` = `<invocation> — <outcome one-liner, <=~80 chars> (creates 2, updates 1)` —
     spell out create vs update counts when a bundle mixes modes.

3. **Zero selection** — if the user selects no usages (or interrupts), report "nothing materialized",
   ledger the session `no-opportunities` (per the Single-mode ledgering rules in Step 2 — otherwise
   nothing ever records the session and the done-when lies), and stop; in per-session `--review` mode,
   ledger the same way and **continue the loop** with the next session instead of stopping. Never
   re-ask, never materialize anything anyway.

4. **Scope confirmation** is ask-each-time per accepted **usage** — batch all scope confirmations
   into **one** `AskUserQuestion` call (<=4 accepted usages = <=4 questions, header = usage
   handle). One scope applies to every artifact in the bundle, with this fallback: settings-based
   artifacts (permission, hook, mcp-server) have **no plugin scope** — if the user picks plugin,
   those artifacts fall to **project** scope (or **user** when not a git repo, same fallback as
   the edge cases below), and the diff/confirm in the apply step must say so.

## Step 5 — Resolve create vs update, then apply (with safety)

Both modes apply artifacts with the mechanics below. **Single mode / `--review`:** for each usage the
user accepted. **Project-wide auto mode:** for each usage passing the auto bar, with scope forced to
**project** (user when not a git repo; never plugin) and the no-op-skip + insert-only guards — see
[`references/project-wide.md`](references/project-wide.md) Phase B.

For each **usage** being applied, loop over every artifact in its `artifacts[]`:

1. **Resolve the concrete target path** from `artifact_type` + chosen scope (see the catalog's
   per-type "On-disk location" tables). Run an existence check to confirm create vs update, and scan sibling names so you don't
   collide or duplicate:

   ```bash
   test -e "<target_path>" && echo "EXISTS -> update" || echo "MISSING -> create"
   ls -1 "$(dirname "<target_path>")" 2>/dev/null   # scan siblings for near-duplicate names
   ```

2. **Apply the per-type strategy** (recipes in the catalog):

   - **merge-json** — hooks, permissions, mcp-server, and other `settings.json` / `.mcp.json`
     keys. Use the **catalog's per-type recipe** for the jq program — array-valued keys
     (`permissions.allow`, hook arrays) need **append + `unique`**; a generic `. * $frag` deep-merge
     REPLACES arrays and silently drops every sibling entry. Wrap whichever recipe applies in this
     safety envelope — timestamped backup first, validate, restore from the **captured** backup path
     on invalid output (never a `.bak.*` glob — with multiple backups it expands to multiple `cp`
     sources and the restore fails):

     ```bash
     target="<settings.json or .mcp.json>"
     [ -e "$target" ] || echo '{}' > "$target"              # create case: jq needs valid input
     bak="$target.bak.$(date +%s)"; cp "$target" "$bak"     # backup FIRST
     jq <catalog recipe for this artifact type> "$target" > "$target.tmp" \
       && jq empty "$target.tmp" \
       && mv "$target.tmp" "$target" \
       || { echo "INVALID JSON — aborting, restoring backup"; rm -f "$target.tmp"; \
            cp "$bak" "$target"; }
     ```

   - **append-section** — CLAUDE.md, rules, memory. **Append** a new, clearly-headed Markdown
     section; never rewrite existing content. For **memory**, write a new memory file and add one
     index line to `MEMORY.md` (do not edit existing memory entries).

   - **whole-file** — skills, commands, subagents, output styles. On **create**, write the
     templated file. On **update**, `Read` the current file -> insert the new step/section ->
     write it back.

3. **For ANY update** (all families) — **single mode / `--review`:** show a diff/summary of what will
   change and ask the user to confirm before writing. **Partial rejection inside a bundle:** creates
   apply directly; each update gets its own diff-confirm. If the user rejects one artifact's update,
   still apply the rest of the bundle, note the skipped artifact in the report, and — when the
   rejected artifact is load-bearing for the usage (per its `role_in_workflow`) — warn that the usage
   is incomplete. **Project-wide auto mode:** no confirmation — an update applies only when it is
   insert-only and not a no-op (project-wide.md Phase B guards); anything else is deferred to the
   report as a suggestion.

4. **Never invent secrets or credentials** — MCP/API values are left as `<PLACEHOLDER>` for the
   user to fill in.

5. **Validate frontmatter** on file-based artifacts: the `name` field must equal the
   directory/file kebab-case name.

## Step 6 — Report

Print a table of every artifact touched, **grouped by usage** and leading with the usage:

| Usage | How to invoke | Artifact path | Type | create / update |
|---|---|---|---|---|

Then add a **LOAD note**:

- User / project skills, commands, agents, rules, settings, and permissions load immediately or on
  the next prompt.
- **Plugin-scope** artifacts need `/reload-plugins`.
- **Output styles** need `/clear` or a new session to take effect.

If anything was **deferred** (plugins, keybindings, monitors, status line, sub-bar suggestions,
rewrite-requiring updates, coerced scopes), list it as a suggestion rather than applying it.

**Project-wide — state block.** Finalize `lastRun` (per §K.6: `artifactsCreated`, `artifactsUpdated`,
`updatesSkippedNoop`, report path — the `analyzed[]` entries and watermark were already written per
session in Phase B), then **release the lock** (`rmdir "$ledger.lock"`). Print:

```
harvested N (+ active) · no-opportunities M · skipped-cap K · created C · updated U · no-op skips S · watermark now <ts>
next run sees only sessions newer than <ts>, plus any skipped-cap/error remainders
review the folded artifacts with `git status` / `git diff` in this repo
```

**Single mode — state line.** "session `<sid-8>` ledgered (`<outcome>`); watermark unchanged." (Or,
for an external transcript, "analyzed but not ledgered".)

---

## Edge cases

- **Nothing recurring** — if no pattern repeats >=2x, report "nothing to harvest (needs >=2
  repeats)" and create nothing (in project-wide mode the session is ledgered `no-opportunities` and
  the loop continues with the next session).
- **Rewrite-requiring update (auto mode)** — an update that would delete or rewrite existing lines is
  never auto-applied; it is deferred to the report as a suggestion (run with `--review` or single mode
  to apply it with a diff-confirm).
- **Per-session agent or apply failure (auto mode)** — the session is ledgered `error` (re-eligible
  next run) and the loop continues; one bad session must not sink the run.
- **Headless run (`--headless`)** — the active session is skipped entirely (it is the headless runner
  itself); the cap auto-defaults to Newest 12; no `AskUserQuestion` fires on any path.
- **Empty project dir / all sessions already harvested** — discovery finds nothing eligible; degrade
  cleanly to "analyzing the active session only".
- **Corrupt / unknown-`schemaVersion` ledger** — moved aside to `<ledger>.bak-<ts>` and re-initialized
  fresh (project-wide.md's init check).
- **Cap overflow** — remainders are ledgered `skipped-cap` and re-offered next run.
- **Concurrent harvest** — the `$ledger.lock` dir makes a second same-project run abort (or steal a
  >30-min-stale lock).
- **Idle-but-open second session** — a second session left open but idle can be ledgered mid-life; if
  you later do more work in it, use the grown-session `jq del` escape hatch to re-harvest (accepted
  v1 limitation, same as `loom:learn`).
- **External transcript (single mode)** — a transcript outside `$cfg/projects/` is analyzed but never
  ledgered.
- **Not a git repo** — discovery uses the plain `pwd` hash; for artifact scope, **project** falls
  back to **user** scope (there is no repo `.claude/` to write into).
- **settings / MCP merges** — always **backup + validate + abort-on-invalid**; never partial-write a
  settings or `.mcp.json` file.
- **Huge transcripts** — the analysis subagent samples by intent-cluster (>~20k lines) and never
  pastes raw transcript content back.

---

## Done when

- The mode + flags were resolved from `$ARGUMENTS` (empty → project-wide auto · `--dry-run` → preview ·
  `--review` → per-session confirm · `--headless` → prompt-free · id/path → single); **zero** hardcoded
  `$HOME/.claude` anywhere.
- **Project-wide** (per [`references/project-wide.md`](references/project-wide.md)): the ledger was
  loaded or initialized (first-run + corrupt + unknown-schema all handled); transcripts were discovered
  via `find` (no bare glob); eligibility was ledger-outcome-first then watermark; the live-transcript
  rule applied (active analyzed, never ledgered — skipped entirely under `--headless`; other live
  transcripts excluded); the cap-12-non-active question fired only on overflow and was the run's
  **only** prompt in auto mode (`--headless`: auto-defaulted, no prompt); `skipped-cap` remainders were
  ledgered at cap resolution; survivors were processed **oldest→newest, one at a time, active last**.
- Each session: ONE sonnet subagent (paths only), the **full contract** with `draft_spec`, capped at
  the top 4 (extras listed as "also noticed"); the **auto bar** enforced in auto mode (strict
  recurrence with evidence, hard minimality, suggest-only deferral, run-manifest convergence, no-op
  skips recorded, insert-only updates); scope auto-resolved (project / user-fallback / never plugin);
  artifacts applied with full safety and no prompts (or the per-session `--review` confirm honored);
  the session's report section appended; the `analyzed[]` entry **and** watermark persisted in one
  §K.7 write (active session folded but never ledgered/watermarked); failures ledgered `error` with
  the loop continuing.
- **Single mode** ledgered the session (own-project transcripts only) **without** moving the watermark;
  an external transcript was "analyzed but not ledgered"; usage cards were printed, the user
  multi-selected **usages** (never artifact types), scope was confirmed per accepted usage in one
  batched question, and every update showed a diff and was confirmed.
- **`--dry-run`** presented discovery + eligibility + cap outcome and wrote nothing.
- Zero selection (single / `--review`) ended with "nothing materialized" — in `--review` the loop
  continued to the next session; partial rejections applied the rest of the bundle and were noted.
- For every artifact, create-vs-update was resolved by an existence check; settings/MCP merges were
  backed up, merged per the catalog's per-type recipe, validated, and aborted on invalid JSON (restoring
  from the captured backup); secrets were left as
  `<PLACEHOLDER>`; frontmatter `name` matched the dir/file kebab name.
- A final table grouped artifacts by usage, plus the LOAD note and deferred-suggestions list; the
  project-wide state block (or single-mode state line) printed and the lock was released.
