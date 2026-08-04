---
name: constitution-authoring
description: >
  Create, amend, or show this repo's mentor CONSTITUTION — a committed,
  semantic-versioned set of governing principles (declarative, testable rules) at
  .mentor/constitution.md that every /mentor:plan must verify against. Use this
  whenever the user wants to establish, change, or inspect project-wide
  planning/engineering principles or the "rules of the repo": e.g. "set up a
  constitution", "add/amend/remove a principle", "make every plan enforce X",
  "what principles govern this repo". Standalone authoring flow — it never arms
  the plan gate and is not itself planning. NOT for writing a single plan (use
  /mentor:plan) or reviewing one plan's design (mentor:plan-review).
---

# mentor Constitution

A **constitution** is the supreme rulebook for how work is planned and built in a
repo: a short list of named principles, each declarative and testable, plus a
governance block that records how the document is versioned and amended. Once it
exists, every `/mentor:plan` reads it live and proves compliance in a
**Constitution Check** section; `/plan-review` flags violations. The constitution
never forces itself — a plan may deviate, but only with an explicit, justified
note (or by amending the constitution first).

It is committed to the repo at **`.mentor/constitution.md`** so the whole team
shares one rulebook — unlike plans/handoffs, which are gitignored transient state.
A repo that already keeps its rulebook elsewhere (e.g. `docs/constitution.md`)
can instead **adopt it by reference** (Step 3a): `constitution_path` in
`.mentor/config.json` points at it, and every consumer (`plan` Step 0,
`plan-review`, `zoom`) resolves that path and reads the real file live.

The flow: guard → load any existing constitution → collect/derive principles
(or adopt an external file by reference) → version & date → assemble
(sync-impact report + body) → confirm → write → report.

## Step 1 — Guard {#guard}

```bash
git_common="$(git rev-parse --git-common-dir 2>/dev/null || true)"
if [ -z "$git_common" ]; then
  echo "NOT-A-REPO"
else
  repo_root="$(cd "$(dirname "$git_common")" && pwd)"
  marker="$repo_root/.mentor/plans/.planning"
  echo "REPO_ROOT=$repo_root"
  # A fresh marker means a live plan session; a stale one (>8h) is a crashed
  # session the edit gate self-heals, so treat it as idle.
  if [ -f "$marker" ] && [ -z "$(find "$marker" -mmin +480 2>/dev/null)" ]; then
    echo "PLANNING-ACTIVE"
  else
    echo "PLANNING-IDLE"
  fi
  const_rel="$(jq -r '.constitution_path // empty' "$repo_root/.mentor/config.json" 2>/dev/null)"
  const_path="${repo_root}/${const_rel:-.mentor/constitution.md}"
  echo "CONSTITUTION=$const_path"
  [ -n "$const_rel" ] && echo "ADOPTED-BY-REFERENCE"
  [ -f "$const_path" ] && echo "EXISTS" || echo "NEW"
  echo "TODAY=$(date +%F)"
fi
```

- **`NOT-A-REPO`** → the constitution is per-repo and committed. Tell the user to
  `cd` into a git repo and stop.
- **`PLANNING-ACTIVE`** → a live `.planning` marker is armed (a plan session is
  open). The constitution lives in-repo, so the edit gate would **block** the
  write. Do not attempt it — tell the user to approve or finish the current plan
  first (or re-run this outside a plan session), then stop.
- Otherwise capture `REPO_ROOT`, whether the file `EXISTS` or is `NEW`, and
  `TODAY` for the dates below.

## Step 2 — Load the existing constitution {#load}

If `EXISTS`, `Read` the resolved `CONSTITUTION` file and note its current
**version**, **ratification date**, and the **set of principles** (names +
rules). This is an **amendment**; the ratification date is preserved. If `NEW`,
this is the first **ratification** — version starts at `1.0.0` and the
ratification date is `TODAY`. When the guard printed `ADOPTED-BY-REFERENCE`,
the constitution is an external file the repo already owns: amendments edit
THAT file in place, and only when the user asks — never rewrite an adopted
document into mentor's template uninvited.

**Read-only shortcut:** if the user only wants to *see* the current constitution
(e.g. "show me our principles", "what governs this repo") and requested no change,
surface it verbatim and stop here — do not bump the version or rewrite. The rest
of this flow is for creating or amending.

## Step 3 — Collect / derive the principles {#principles}

Principles come from, in priority order: (1) what the user passed to
`/mentor:constitution`; (2) the existing constitution (for an amendment); (3) the
repo's own conventions when the user asked you to bootstrap one — skim
`README`, `CLAUDE.md`/`AGENTS.md`, `CONTRIBUTING`, lint/CI config, and obvious
patterns to propose a first draft. **Respect a user-specified principle count** —
do not pad to a fixed number.

A good principle is:

- **Named** — a short noun phrase (e.g. "Test-First", "Library-First", "No secrets in the repo").
- **Declarative & testable** — written in MUST / MUST NOT / SHOULD language, so a
  reviewer can objectively check a plan against it. This is what makes the
  downstream Constitution Check meaningful rather than a rubber stamp. Avoid
  aspirational mush ("write good code"); prefer "Every new endpoint ships with a
  contract test."
- **Justified** — one `Rationale:` line saying why it exists.

Keep the whole document short and high-signal (typically 3–7 principles). Add an
optional extra section (Constraints / Security / Workflow) only if the user has
rules that are not principles.

### Step 3a — Adopt an existing external constitution (by reference) {#adopt}

When the user points at a governing doc the repo **already has** ("use
`docs/constitution.md`", "this existing constitution …"), do **not** duplicate
or re-author its content. Adopt it by reference instead:

1. Confirm the file exists and skim it so you can summarize what was adopted.
2. Write only the pointer into `.mentor/config.json` (merge-json safely —
   backup, edit with `jq`, validate, restore on failure):

   ```bash
   # Re-derive: each fenced block is its own Bash call, so Step 1's value is gone.
   repo_root="$(git rev-parse --show-toplevel)"
   cfg="$repo_root/.mentor/config.json"
   mkdir -p "$repo_root/.mentor"   # bare on purpose: constitution.md is committed, not private
   [ -f "$cfg" ] || echo '{}' > "$cfg"
   cp "$cfg" "$cfg.bak"
   jq --arg p "docs/constitution.md" '.constitution_path = $p' "$cfg" > "$cfg.tmp" \
     && jq empty "$cfg.tmp" && mv "$cfg.tmp" "$cfg" && rm -f "$cfg.bak" \
     || { mv "$cfg.bak" "$cfg"; rm -f "$cfg.tmp"; echo "config write FAILED — restored"; }
   ```

3. Report: the adopted path, that every `/mentor:plan` Constitution Check and
   `/plan-review` will now `Read` that file live (they resolve
   `constitution_path`), and commit guidance for `.mentor/config.json` (it is a
   committed file per `.mentor/.gitignore`).
4. **Skip Steps 4–7 entirely** — no version bump, no template, no
   `.mentor/constitution.md` is written. The external file stays exactly as the
   repo owns it.

## Step 4 — Version & dates {#version}

Decide the new version from the nature of the change and state the reason:

| Bump | When |
|---|---|
| **MAJOR** (`x`.0.0) | A principle is removed or redefined backward-incompatibly (plans that were compliant might no longer be). |
| **MINOR** (`x.y`.0) | A new principle is added, or existing guidance is materially expanded. |
| **PATCH** (`x.y.z`) | Wording/typo/clarification only — no change to what a plan must do. |

First ratification is always `1.0.0`. `Ratified` = the original adoption date
(preserved on amendment); `Last amended` = `TODAY`.

## Step 5 — Assemble the document {#assemble}

Fill this template. **Leave no unexplained `[BRACKET]` tokens** — every
placeholder is either replaced or dropped. Prepend the sync-impact report as an
HTML comment. For `<Project Name>`, use the project's own name if it is obvious
(a `package.json` `name`, a README H1, the repo remote) — otherwise fall back to
the `REPO_ROOT` basename.

````markdown
<!--
SYNC IMPACT REPORT
Version:  <old> → <new>   (<MAJOR|MINOR|PATCH>: <one-line reason>)
Ratified: <YYYY-MM-DD>    Last amended: <YYYY-MM-DD>
Principles added:    <names, or none>
Principles modified: <names, or none>
Principles removed:  <names, or none>
Consumed by: mentor `plan` skill (Constitution Check section) and `/plan-review`.
  These read this file LIVE at plan time — there are no generated templates to
  propagate to, so no downstream files need editing.
Deferred TODOs: <anything intentionally left open, or none>
-->

# <Project Name> Constitution

## Principles

### I. <Principle name>
<One or more declarative rules in MUST / SHOULD language — testable, not aspirational.>
_Rationale:_ <why this principle exists.>

### II. <Principle name>
<…>
_Rationale:_ <…>

<!-- add as many principles as the project needs; do not pad to a fixed count -->

## <Optional extra section — Constraints / Security / Workflow>
<Only include if the user has rules that are not principles; otherwise delete this heading.>

## Governance

This constitution supersedes ad-hoc practice for planning and implementation in
this repo. Every `/mentor:plan` MUST include a **Constitution Check** that
verifies the plan against these principles; any deviation MUST be justified
explicitly in the plan, or the constitution amended first via
`/mentor:constitution`.

**Amendment procedure:** amendments are made through `/mentor:constitution`, which
bumps the version semantically — MAJOR (remove/redefine a principle),
MINOR (add a principle or materially expand guidance), PATCH (clarify wording).

**Version:** <X.Y.Z> · **Ratified:** <YYYY-MM-DD> · **Last amended:** <YYYY-MM-DD>
````

## Step 6 — Confirm {#confirm}

Surface the **complete assembled document** in your message (verbatim markdown, no
wrapper commentary) so the user reads exactly what will be committed. Then ask via
`AskUserQuestion` — header "Constitution", single-select:

- **"Ratify & write"** (first time) / **"Save amendment"** (existing) —
  *"Write `.mentor/constitution.md` at v<new>."*
- **"Keep editing"** — *"Adjust principles/wording; re-surface and ask again."*
- **"Cancel"** — *"Do not write anything."*

On **Keep editing**, revise and re-surface. On **Cancel**, stop without writing.

## Step 7 — Write & report {#write}

On approval, create the dir and write the file with `Write` (it is in-repo, but no
plan gate is armed, so the write is allowed):

```bash
# Re-derive: each fenced block is its own Bash call, so Step 1's value is gone.
repo_root="$(git rev-parse --show-toplevel)"
mkdir -p "$repo_root/.mentor"   # bare on purpose: constitution.md is committed, not private
```

Write the assembled document to `$REPO_ROOT/.mentor/constitution.md`. Then report:

- The path and the new version (e.g. `v1.0.0 ratified` / `v1.2.0 — MINOR`).
- A one-line summary of what changed (from the sync-impact report).
- **Commit guidance** — it is a shared, committed artifact, so suggest:
  `git add .mentor/constitution.md && git commit -m "docs: constitution v<new>"`.
  Do not commit for the user unless they ask.
- Remind that from now on `/mentor:plan` will include a Constitution Check against it.

### Do NOT
- Do **not** run `begin-plan.sh` or arm the plan gate — this is not a plan session.
- Do **not** write the constitution anywhere but `$REPO_ROOT/.mentor/constitution.md` —
  with ONE exception: the adopt-by-reference branch (Step 3a), which writes only the
  `constitution_path` key into `.mentor/config.json` and never a second constitution file.
- Do **not** invent principles the user did not ask for and cannot be grounded in
  the repo — when unsure, propose and let Step 6 confirm.
- Do **not** leave placeholder brackets or a stale version/date in the written file.
