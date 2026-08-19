# Private Claude Marketplace

Marketplace repo hosting Claude Code plugins under `plugins/<name>/`, registered in `.claude-plugin/marketplace.json`.

## Rules

### Skill quality gate (MANDATORY)

**Always invoke `/skill-creator:skill-creator` before creating or modifying ANY skill** (`SKILL.md` or its supporting files, in any plugin under `plugins/*/skills/`).

- Applies to: creating a new skill, editing an existing skill's `SKILL.md`, changing its frontmatter/description, or restructuring its references/evals.
- The skill-creator skill controls the workflow — follow its guidance for structure, description/triggering quality, and evals rather than editing skill files ad hoc.
- This applies even when another workflow (e.g. loom harvest/tune) is driving the change: load `/skill-creator:skill-creator` first, then proceed.
- Exceptions: pure version-number bumps and typo-only fixes that don't touch behavior or the description may skip it.

### Skill prose convention (mentor and any skill that grows by accretion)

When adding or amending a rule in a plugin `SKILL.md`, put the **imperative rule plus one
sentence of why** in `SKILL.md`, and the **incident narrative / mechanism essay** in that
skill's `references/rationale.md`, pointed at by heading name.

- Rationale files load only when someone edits the skill or is about to override a rule;
  `SKILL.md` loads on every invocation, so narrative there is paid for on every run.
- This binds automated contributors too — a `/loom:learn` cycle harvesting a new rule
  appends the story to `references/rationale.md`, never to `SKILL.md`.
- See `plugins/mentor/README.md` → "Where a new rule goes" for the full convention.

### Instruction hygiene gate (MANDATORY)

**Always run `/prune-instructions [plugin]` before `git commit`/`git push`/publish on any change under `plugins/<name>/`, `.claude/`, or `CLAUDE.md`.** A change leaves its debt in the files it did *not* touch — stale pointers, a rule now stated in three places, a root rule that contradicts the new default, narrative every future run pays for — and nothing else in this repo reads the instruction corpus as a whole.

- It dispatches read-only `instruction-hygiene-auditor` agents by lens, auto-applies the mechanical fixes (dead references, missed renames, narrative relocated to `references/rationale.md`), and asks before deleting or merging any rule. It never stages or commits.
- **Order:** `/prune-instructions` (edits) → `/verify-plugin-edits <plugin>` (validates the result) → commit/publish. Reversed, this pass's own edits ship unchecked. `/verify-plugin-edits` covers `plugins/<name>/` only — for a root-only change (`.claude/**`, `CLAUDE.md`, including this gate's own files) there is no mechanical equivalent yet: run `.claude/hooks/tests/*.sh` by hand instead.
- Applies even when a skill is driving the release (`/loom:publish-plugin`, `/loom:learn`, `/loom:audit-plugin`, `/mentor:ship`) — `publish-plugin` step 0 invokes it, and the `instruction-hygiene-gate.sh` hook reminds you at the commit if it hasn't run this session.
- Unattended callers never prompt: loom's daily `learn --headless` applies the safe fixes and defers every decision into the commit body, unapplied.
- Distinct from the two neighbouring checks — don't substitute one for another: this pass is the only one that judges whether the corpus is still coherent and lean, and the only one that edits.
- Exceptions: pure version-number bumps and typo-only fixes that don't touch behavior (same exception as the gates above).
- See `.claude/skills/instruction-hygiene/references/rationale.md` for why the order, the auto-apply line, and the never-auto-delete-a-rule rule are where they are.

### Plugin-edit verification gate (MANDATORY)

**Always run `/verify-plugin-edits <plugin>` before `git commit`/`git push` on any change under `plugins/<name>/`.**

- Applies to: any commit touching `plugins/<name>/` — skill edits, script edits, hook edits, manifest/version bumps, README updates.
- Fix every reported FAIL (JSON validity, script syntax, stale terms, description length, hardcoded paths, hook test suites, manifest description sync, cross-block bash variable leakage) before committing. Don't re-derive a subset of these checks by hand (`python3 -m json.tool`, ad hoc `grep`, eyeballing a diff) — the command already covers all of them in one pass.
- Applies even when a skill (loom harvest/learn/audit-plugin, skill-creator, publish-plugin, etc.) is driving the change: run this command as the last step before the commit, not instead of it.
- Runs **after** `/prune-instructions` (gate above) for edits under `plugins/<name>/`, so the hygiene pass's own edits there are covered rather than shipping unvalidated. This command never inspects `.claude/**` or root `CLAUDE.md`.
- Exceptions: pure version-number bumps and typo-only fixes that don't touch behavior may skip it (same exception as the skill quality gate above).

### Git staging safety around loom automation (MANDATORY)

Loom's daily automation (`loom:automate`) can run and commit in this repo's working tree while you have uncommitted edits in flight. Because it stages whole directories (`git add "plugins/<plugin>/"` — see `plugins/loom/skills/learn/SKILL.md:274,283`), a loom `learn(<plugin>)` commit can silently sweep in your unrelated uncommitted edits to any file it also touches. This happened in practice: loom's commit `d54fde9` swallowed unrelated in-flight edits to `plugins/mentor/skills/planning/SKILL.md` mid-session.

Before running `git add`/`git commit` on any change in this repo:

1. Check whether a loom automation run is currently active: `pgrep -fl 'daily-run.sh|loom/automation'`.
2. Never `git add -A` or `git add .` — stage only the exact files you intend to commit (e.g. `git add plugins/mentor/ .claude-plugin/marketplace.json`).
3. Immediately before committing, run `git status --porcelain` / `git diff --cached --stat` and confirm every staged path is one you actually authored this session — if anything unexpected shows up, unstage and re-stage narrowly (`git add -p`) rather than committing blind.
