# Codex adapter

Mentor runs guidance-first in Codex through the shared `skills/` directory and the
durable `.mentor/` files. Codex hooks are deliberately disabled in the portable
manifest: hook trust is optional, the current Claude event set is not portable, and
the edit gate must not be advertised as fail-closed until Codex-specific payload and
coverage fixtures prove it.

When a host-native UI action is unavailable, use the portable fallback declared by
the skill: ordinary conversation for questions, the current task for serial work,
and local HTML/Markdown files for review pages.

**The run loop without hooks.** Codex has no Stop hook here, so planning's
run-until-done loop is a prose rule: after the one approval, keep working through the
steps in the current task until a terminal state (done, paused on an always-pause item or a stop word,
or failed). Without subagents each step is graded serially in the main thread, and every
such PASS row is labelled `self-graded` — never presented as independent.
