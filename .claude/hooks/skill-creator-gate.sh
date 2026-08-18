#!/usr/bin/env bash
# skill-creator-gate.sh — PreToolUse (Edit|Write|MultiEdit)
#
# Reminds (never blocks) when an Edit/Write/MultiEdit targets a file under
# plugins/<name>/skills/** without /skill-creator:skill-creator having been
# invoked yet this session. This repo's CLAUDE.md mandates that skill first for
# any SKILL.md create/edit — "even when another workflow (e.g. loom
# harvest/tune) is driving the change" — but a text-only rule gets lost once a
# long session is 400+ tool calls deep: a real loom:learn session edited 14
# SKILL.md files without it and only caught the gap in its own closing
# self-report. This hook fires the reminder at the exact moment of risk
# instead of relying on it staying in an agent's active attention.
#
# Warn-only: always exit 0, stdout only (never stderr/exit 2 — that's a real
# block, which this isn't; the CLAUDE.md gate already carves out exceptions
# for version-bump/typo-only edits, and this hook can't tell those apart from
# a real one, so it nags instead of refusing). Silenced for the rest of the
# session once the skill-creator-gate-mark.sh companion (PostToolUse on
# Skill) sees skill-creator actually get invoked.
#
# Fail-soft: no jq / unparsable input / no file path → exit 0. Never brick a
# session over a reminder.

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0
INPUT="$(cat)" || exit 0

# Edit, Write, and MultiEdit all carry the target under the same field name.
FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null)" || exit 0
[ -z "$FILE_PATH" ] && exit 0

case "$FILE_PATH" in
  plugins/*/skills/*|*/plugins/*/skills/*) ;;
  *) exit 0 ;;
esac

SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // "nosession"' 2>/dev/null)" || SESSION_ID="nosession"
marker="/tmp/claude-skill-creator-gate-${SESSION_ID}"
[ -e "$marker" ] && exit 0

echo "[skill-quality-gate] Editing a skill file (${FILE_PATH}) without /skill-creator:skill-creator invoked yet this session. This repo's CLAUDE.md requires that skill FIRST for any SKILL.md create/edit (structure, description/triggering quality, evals) — exceptions only for pure version bumps or typo-only fixes that don't touch behavior or the description. If this edit is one of those exceptions, proceed; otherwise invoke Skill(skill=\"skill-creator:skill-creator\") before continuing."
exit 0
