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

### Plugin-edit verification gate (MANDATORY)

**Always run `/verify-plugin-edits <plugin>` before `git commit`/`git push` on any change under `plugins/<name>/`.**

- Applies to: any commit touching `plugins/<name>/` — skill edits, script edits, hook edits, manifest/version bumps, README updates.
- Fix every reported FAIL (JSON validity, script syntax, stale terms, description length, hardcoded paths, hook test suites, manifest description sync, cross-block bash variable leakage) before committing. Don't re-derive a subset of these checks by hand (`python3 -m json.tool`, ad hoc `grep`, eyeballing a diff) — the command already covers all of them in one pass.
- Applies even when a skill (loom harvest/learn/audit-plugin, skill-creator, publish-plugin, etc.) is driving the change: run this command as the last step before the commit, not instead of it.
- Exceptions: pure version-number bumps and typo-only fixes that don't touch behavior may skip it (same exception as the skill quality gate above).

### Git staging safety around loom automation (MANDATORY)

Loom's daily automation (`loom:automate`) can run and commit in this repo's working tree while you have uncommitted edits in flight. Because it stages whole directories (`git add "plugins/<plugin>/"` — see `plugins/loom/skills/learn/SKILL.md:274,283`), a loom `learn(<plugin>)` commit can silently sweep in your unrelated uncommitted edits to any file it also touches. This happened in practice: loom's commit `d54fde9` swallowed unrelated in-flight edits to `plugins/mentor/skills/planning/SKILL.md` mid-session.

Before running `git add`/`git commit` on any change in this repo:

1. Check whether a loom automation run is currently active: `pgrep -fl 'daily-run.sh|loom/automation'`.
2. Never `git add -A` or `git add .` — stage only the exact files you intend to commit (e.g. `git add plugins/mentor/ .claude-plugin/marketplace.json`).
3. Immediately before committing, run `git status --porcelain` / `git diff --cached --stat` and confirm every staged path is one you actually authored this session — if anything unexpected shows up, unstage and re-stage narrowly (`git add -p`) rather than committing blind.
