---
name: dual-host-plugin-migrator
description: Convert a Claude Code plugin or marketplace into a maintained dual-host package whose real workflows work in both Claude Code and Codex. Use for plugin migrations, portability audits, host adapters, or marketplace release primitives; do not use for a submission-only repackaging that does not promise Claude Code compatibility.
---

# Dual-host plugin migrator

Preserve the plugin's user-visible workflows while making support claims evidence-based. Treat portable skills and durable artifacts as the product; treat commands, hooks, host UI, and installation metadata as adapters.

`<skill-root>` below means the directory containing this `SKILL.md`.

## Start with an inventory

1. Read the target repository's `AGENTS.md`, `CLAUDE.md`, release instructions, and current git status. Preserve unrelated and pre-existing changes.
2. Identify whether the input is one plugin, a marketplace containing several plugins, or a publication archive. Do not silently expand a single-plugin request into a marketplace rewrite.
3. Run the bundled read-only audit and inspect its findings rather than mechanically replacing strings:

   ```bash
   python3 <skill-root>/scripts/audit_claude_plugin.py <plugin-or-marketplace-root> --format markdown
   ```

   Do not optimize for zero review findings. A documented thin Claude command or hook adapter should remain visible to the audit; explain why it is safe and keep it out of the portable dependency path.

4. List the actual user workflows. For each workflow, record its portable core, Claude adapter, Codex adapter, fallback, and executable evidence. A manifest that loads is not proof that the workflow works.
5. Check the current official host documentation before relying on a manifest field, hook event, environment variable, marketplace schema, or CLI command. Start with the OpenAI [plugin packaging](https://developers.openai.com/plugins/build/plugins) and [Claude plugin conversion](https://developers.openai.com/plugins/guides/submit-claude-plugin) guides, plus the Claude Code [plugin reference](https://code.claude.com/docs/en/plugins-reference) and [marketplace reference](https://code.claude.com/docs/en/plugin-marketplaces).

Read [references/compatibility-matrix.md](references/compatibility-matrix.md) when the plugin contains commands, agents, hooks, MCP servers, settings, live artifacts, or host-specific state. Read [references/marketplace-maintainer.md](references/marketplace-maintainer.md) when converting a marketplace or establishing a durable release primitive.

## Build a portable core

- Keep reusable workflows in `skills/<name>/SKILL.md` with portable Agent Skills frontmatter. Convert reusable `commands/` and agent procedures into skills; keep Claude slash commands and specialized agents only as optional facades. Verify Claude discovery when retaining a command facade: a command and shared skill with the same name can appear as duplicate components, so rename the portable skill or remove the redundant facade.
- Make direct skill selection or ordinary language sufficient. Provide plain-text clarification when structured-question UI is absent and serial execution when delegation is absent.
- Resolve bundled files without assuming a source checkout. Skill resource links are relative to the skill root. Once invoked, a bundled shell helper should anchor its own resources with `dirname "$0"`; Python should use `Path(__file__).resolve()`. Prefer runtime `PLUGIN_ROOT` when the host actually supplies it, accept `CLAUDE_PLUGIN_ROOT` as a compatibility input where appropriate, or pass an already resolved path explicitly. Test paths from a copied or installed plugin, not only the repository.
- Never write persistent state into the installed plugin directory. Prefer a project-owned, host-neutral directory or a documented state-home variable. Preserve readers or supply a tested migration for released state formats.
- Do not make hooks the sole implementation of a required workflow or safety check. Put the essential check in the portable skill or helper, then let host hooks add enforcement or convenience.
- Return portable files or ordinary conversation output when a host-only live artifact or UI is unavailable. Keep enhanced publication optional.
- Treat MCP support as a transport and authentication question. Adapt configuration for each host and prove the server can start or connect; do not infer support from the presence of `.mcp.json`.

## Package both hosts

Prefer a root `plugin.json` using the Agent Plugins schema as the portable identity. Keep OpenAI-only presentation, registered apps, and Codex hooks under `extensions.com.openai`. Remember that an inline `extensions.com.openai` object replaces, rather than merges with, a `.codex-plugin/plugin.json` overlay.

Retain or generate `.claude-plugin/plugin.json` for Claude Code. Generate `.codex-plugin/plugin.json` only when a compatibility overlay is useful; the portable root manifest is the preferred Codex entry point. Keep shared identity fields synchronized.

For a marketplace, make one host-neutral catalog and each plugin's portable manifest the editable sources. Generate both `.claude-plugin/marketplace.json` and `.agents/plugins/marketplace.json`; byte-check them for drift. Reuse an existing canonical generator when present. Do not replace a repository's established primitive with this skill's example structure merely because the names differ.

Project only the skills a host can honestly use. Keep the default shared `skills/` directory for dual-host workflows or portable wrappers. Move a Claude-only implementation outside that default path and expose it through Claude's custom skill declaration, or generate separate host package roots when selective discovery cannot be expressed safely. A directory-wide `skills: "./skills/"` declaration is a false support claim when it exposes unsupported skills.

Classify each workflow:

- `supported`: exercised by deterministic evidence for that host.
- `partial`: useful degraded behavior exists and is described precisely.
- `unsupported`: no honest implementation exists; name the fallback.

For a marketplace that promises both hosts, reject a release when a core workflow is not supported in either host. Allow a genuine host-specialized exception only with an owner, rationale, fallback, review date, and exit criteria.

## Validate the installed result

Run the repository's own generator, validator, tests, and release checks first. Then verify, in proportion to the change:

1. Validate every `SKILL.md` and every host manifest/catalog that the chosen package layout actually uses. Prefer the repository's validator; otherwise use an available Agent Skills validator, the skill-creator `quick_validate.py`, and the host CLIs. A portable root manifest does not require a redundant Codex overlay.
2. Run deterministic tests for behavior, fallback paths, state compatibility, and bundled-file resolution.
3. Check that generated host projections match canonical sources byte-for-byte.
4. Install from a copied marketplace in isolated Claude and Codex configuration/cache directories. Confirm discovery and enablement, then exercise at least one representative workflow from the installed copy.
5. Report a missing host CLI or unavailable authentication as unverified coverage, not as a pass. Do not publish, commit, push, or change live marketplace configuration unless the user requested that action.

Finish with a concise support matrix, changed canonical sources and generated projections, tests run, unverified or waived capabilities, and any required maintainer follow-up.
