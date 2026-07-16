# Private Claude Marketplace

Marketplace repo hosting Claude Code plugins under `plugins/<name>/`, registered in `.claude-plugin/marketplace.json`.

## Rules

### Skill quality gate (MANDATORY)

**Always invoke `/skill-creator:skill-creator` before creating or modifying ANY skill** (`SKILL.md` or its supporting files, in any plugin under `plugins/*/skills/`).

- Applies to: creating a new skill, editing an existing skill's `SKILL.md`, changing its frontmatter/description, or restructuring its references/evals.
- The skill-creator skill controls the workflow — follow its guidance for structure, description/triggering quality, and evals rather than editing skill files ad hoc.
- This applies even when another workflow (e.g. loom harvest/tune) is driving the change: load `/skill-creator:skill-creator` first, then proceed.
- Exceptions: pure version-number bumps and typo-only fixes that don't touch behavior or the description may skip it.
