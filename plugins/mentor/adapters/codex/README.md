# Codex adapter

Mentor runs guidance-first in Codex through the shared `skills/` directory and the
durable `.mentor/` files. Codex hooks are deliberately disabled in the portable
manifest: hook trust is optional, the current Claude event set is not portable, and
the edit gate must not be advertised as fail-closed until Codex-specific payload and
coverage fixtures prove it.

When a host-native UI action is unavailable, use the portable fallback declared by
the skill: ordinary conversation for questions, the current task for serial work,
and local HTML/Markdown/JSON files for tours and handoffs.
