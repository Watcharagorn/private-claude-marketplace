# Claude Code to dual-host compatibility

Use this reference to classify behavior before editing. Preserve the workflow's intent; do not preserve a host mechanism merely because it already exists.

| Claude Code surface | Portable core | Claude Code adapter | Codex adapter or fallback | Evidence to require |
|---|---|---|---|---|
| `skills/<name>/SKILL.md` | Keep the skill and its scripts, references, and assets. Use portable frontmatter and provider-neutral instructions. | Slash invocation may remain convenient. | Direct skill selection and natural-language invocation must work. | Skill validation plus a realistic invocation fixture. |
| `commands/*.md` | Convert reusable behavior to a skill. Merge duplicate command/skill logic. | Keep a thin command facade if users depend on its name. Avoid giving it the same discovery name as the shared skill, which can create duplicate Claude components. | Use the skill directly; do not promise the Claude command namespace. | The same workflow outcome through both entry paths, plus no duplicate Claude discovery entry. |
| `agents/*.md` | Move reusable procedures and decision criteria into a skill. | Retain a specialist agent when isolation, model choice, or agent UI is valuable. | Delegate only when available; otherwise execute serially in the current task. | Parallel and serial paths produce the same required artifact or decision. |
| `hooks/hooks.json` | Put required validation and state transitions in a callable helper or skill. | Adapt only documented Claude events and payloads. | Adapt only documented Codex hooks. Codex does not run Claude prompt or agent hook handlers. | Feed representative payloads to each adapter and assert exit status, output, and state changes. |
| `${CLAUDE_PLUGIN_ROOT}` | Link skill resources relative to `SKILL.md`. Let invoked shell/Python helpers anchor their own assets with `dirname "$0"` or `Path(__file__).resolve()`. | Continue accepting `CLAUDE_PLUGIN_ROOT`. | Prefer `PLUGIN_ROOT` only where documented; otherwise pass a resolved path explicitly. Compatibility variables in hook subprocesses are not a universal content-substitution contract. | Exercise from a copied install whose absolute path differs from the checkout. |
| `~/.claude`, `CLAUDE_CONFIG_DIR` | Use project-owned durable state or a documented neutral state-home variable. | Read legacy Claude state when compatibility matters. | Use the neutral location and preserve the same schema. | Round-trip current state and read at least one legacy fixture. |
| `AskUserQuestion` or equivalent structured UI | Express the decision and accepted inputs in the skill. | Use structured UI when available. | Ask directly in conversation when structured UI is unavailable. | Both paths capture the same decision without inventing an answer. |
| Claude live artifacts | Define a local file or ordinary response as the durable output. | Artifact publication may be an enhancement. | Return Markdown, JSON, HTML, or another inspectable file. | Base output exists without hosted artifact support. |
| `userConfig` or `${user_config.*}` | Make task-scoped values explicit inputs; move durable secrets/settings to a suitable authenticated service or host-neutral config. | Installation prompts may remain Claude-only convenience. | Do not assume Claude installation prompts or interpolation. | Missing configuration yields an actionable error, never silent success. |
| `.mcp.json` / `mcpServers` | Preserve tool semantics and schemas. Decide whether the server is local or remote. | Configure Claude's supported transport and root variables. | Use portable `mcp.json` where supported or an OpenAI registered/remote MCP mapping. | Server startup/connection, auth, tool schema, read/write behavior, and failure mode. |
| `bin/`, scripts, assets | Keep package-relative and executable resources in the plugin. | A Claude PATH enhancement may remain optional. | Invoke by resolved package path unless Codex documents PATH injection. | Clean installed copy with no source-tree dependency. |
| `settings.json`, output styles, LSP, monitors, channels | Extract any essential workflow into skills or tools. | Keep supported Claude-only enhancement. | Provide a real adapter or mark the feature partial/unsupported. | Capability record names the downgrade and fallback. |

## Skill review

Inspect every skill, not only the manifest:

- Top-level frontmatter should stay within the portable Agent Skills fields used by both hosts. Move host-only metadata to an adapter or remove it when it has no effect.
- Replace product-specific tool names with outcome-based instructions unless the named tool is genuinely required and available.
- Keep references discoverable from `SKILL.md`; resolve relative paths against the skill directory.
- Avoid absolute author-machine paths, source-checkout assumptions, undeclared packages, and credentials.
- Treat structured questions, delegation, background execution, browser UI, and artifact hosting as optional capabilities with fallbacks.

## Hook decisions

For each hook, write down its purpose before translating the event name:

1. **Core behavior:** move it into a portable helper or skill.
2. **Enforcement:** implement separate host adapters only where the host exposes a matching event and payload.
3. **Convenience:** allow the feature to disappear without breaking the workflow.

If the hosts cannot enforce the same policy, say so. An empty Codex hook declaration can be correct when the portable skill owns the behavior; copying an incompatible Claude hook is not.
