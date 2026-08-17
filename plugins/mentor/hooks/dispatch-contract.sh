#!/usr/bin/env bash
# dispatch-contract.sh — PreToolUse:Task|Agent
#
# Structurally injects mentor's standing dispatch-prompt contract — the
# solution-quality line, then the "Deliver before idling" block — into every
# Task/Agent dispatch, so delivery no longer depends on the orchestrator
# remembering to paste ~2.3KB of directives into each of the 9–15 dispatches a
# typical plan run makes. Source of truth: dispatch-contract.txt (sibling
# file), extracted byte-identical from skills/dispatch-agents/SKILL.md's
# "Deliver before idling — the standing prompt contract" fence. That SKILL.md
# copy stays the canonical *documentation* of the contract (skills read it to
# know what dispatched agents receive); this file is what actually ships it.
#
# Idempotent: skipped when tool_input.prompt already contains the block's
# sentinel (its first line, "Do not call the Agent/Task tool") — so a prompt
# the orchestrator already composed with the block pasted in (per the
# skill's own written contract) is never doubled.
#
# Terminal outcomes only, matching the plan's contract exactly:
#   • injected     — stdout is the hookSpecificOutput JSON below, exit 0
#   • passthrough  — wrong tool, or block already present: exit 0, no stdout
#   • fail-soft    — no jq, no/empty/unreadable contract file, malformed
#                    stdin, an unresolvable script directory, a failed
#                    final write, or any jq failure: exit 0, no stdout
# No degraded path may ever emit non-JSON stdout or a partially-built
# updatedInput — the JSON is assembled in one jq pass and only printed once
# complete, never streamed piecemeal.

set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0
HOOK_DIR="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
CONTRACT_FILE="${HOOK_DIR}/dispatch-contract.txt"
[ -s "$CONTRACT_FILE" ] || exit 0

INPUT="$(cat)" || exit 0
TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)" || exit 0
case "$TOOL_NAME" in
  Task|Agent) ;;
  *) exit 0 ;;
esac

# Sentinel = the block's first line. A missing/blank first line means the
# contract file is malformed, and an unreadable file means head itself fails
# — both fail-soft rather than inject garbage or abort under errexit.
SENTINEL="$(head -n 1 "$CONTRACT_FILE" 2>/dev/null)" || exit 0
[ -n "$SENTINEL" ] || exit 0

PROMPT="$(printf '%s' "$INPUT" | jq -r '.tool_input.prompt // ""' 2>/dev/null)" || exit 0
case "$PROMPT" in
  *"$SENTINEL"*) exit 0 ;;  # already present — idempotent no-op
esac

QUALITY_LINE="Implement the most practical and clean solution — never trade maintainability or reliability for implementation speed."

# Everything below is built in ONE jq pass: the new prompt (quality line +
# blank line + contract block, appended after a blank-line separator from
# whatever prompt text is already there — or standing alone if the prompt is
# empty) folded back into tool_input with every sibling key untouched, then
# wrapped in the hookSpecificOutput envelope. --rawfile keeps the contract
# text (backticks, quotes and all) out of shell interpolation entirely.
OUTPUT="$(printf '%s' "$INPUT" | jq -c \
  --arg quality "$QUALITY_LINE" \
  --rawfile contract "$CONTRACT_FILE" \
  '
  ((.tool_input // {}).prompt // "") as $orig
  | (if $orig == "" then ($quality + "\n\n" + $contract)
     else ($orig + "\n\n" + $quality + "\n\n" + $contract)
     end) as $newprompt
  | ((.tool_input // {}) + {prompt: $newprompt}) as $newinput
  | {hookSpecificOutput: {hookEventName: "PreToolUse", updatedInput: $newinput}}
  ' 2>/dev/null)" || exit 0
[ -n "$OUTPUT" ] || exit 0

printf '%s\n' "$OUTPUT" || exit 0
