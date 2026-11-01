# Marketplace host support

Generated from `plugins/*/capabilities.json` by `scripts/marketplace sync`. Do not edit by hand.

| Plugin | Tier | Workflow | Claude Code | Codex | Fallback |
| --- | --- | --- | --- | --- | --- |
| mentor | dual-enhanced | planning | Supported | Supported | Use ordinary conversation for the one approval and persist the plan under .mentor. Without a Stop hook the run-until-done loop is a prose rule (keep working until a terminal state); without subagents each step is verified serially in the main thread and labelled self-graded. |
| mentor | dual-enhanced | ux-review | Supported | Supported | Use the portable skill directly from ordinary conversation; it needs no Mentor helper or .mentor state. |
| mentor | dual-enhanced | delivery | Supported | Supported | The playbook is a portable skill loaded by planning. Without slash-command facades use the host's shell and approval flow; without subagents the pre-merge grade is self-graded and says so. |
| mentor | dual-enhanced | visual-artifacts | Supported | Supported | Write the local HTML review page under .mentor (pinned CDN scripts allowed); hosted Artifact publication is optional. |
| mentor | dual-enhanced | governance | Supported | Supported | Persist project principles in .mentor/constitution.md. |
| loom | host-specialized | publish-plugin | Supported | Supported | Run scripts/marketplace directly from the marketplace repository. |
| loom | host-specialized | session-learning | Supported | Unsupported | Export or supply the source session explicitly and maintain the resulting plugin with the portable publish workflow. |
| loom | host-specialized | scheduled-automation | Supported | Unsupported | Use the host scheduler and reporting tools directly; Loom's bundled runner currently invokes Claude Code. |
| tmux-design | dual-core | console | Supported | Supported | Use the same tmux CLI and bundled renderer scripts through the portable skill. |
| tmux-design | dual-core | decorate | Supported | Supported | Use the same named themes and bundled renderer scripts through the portable skill. |

## Active portability waivers

### loom

- Owner: NTBX
- Review by: 2026-12-31
- Missing capability: A host-neutral supplied-session import format and runner adapter for Codex.
- Fallback: Use publish-plugin on either host; run harvest, learning, and scheduled automation from Claude Code until the adapter ships.
- Exit criteria: Codex can ingest an explicit session bundle, run the learning loop without Claude transcript paths, and pass an isolated automation fixture.
- Rationale: Loom's session ingestion and unattended runner depend on Claude Code transcript, hook, and CLI contracts; marketplace publishing is already portable.
