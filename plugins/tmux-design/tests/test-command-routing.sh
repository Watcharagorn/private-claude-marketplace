#!/usr/bin/env bash
# test-command-routing.sh — regression tests for the command → skill hand-off
# (commands/console.md, commands/decorate.md).
#
# Why this suite exists: both of this plugin's commands share a name with the skill they
# delegate to, so `Skill({"skill":"tmux-design:console"})` returns the COMMAND body rather
# than the skill. Measured once in a real session: the model then spent two `find` sweeps
# hunting for SKILL.md and read a stale cached 0.2.0 copy that predated the -L sandbox
# requirement and the check_cols.py step entirely — every mandatory step it skipped was
# simply absent from the file it found. The fix is a concrete path in the command body, and
# it has exactly two ways to rot silently:
#
#   1. The path drifts from the skill's real location, so the `cat` fails and the model
#      falls back to `find` — the original bug, restored by its own fix.
#   2. Someone "simplifies" ${CLAUDE_PLUGIN_ROOT} into a bare path handed to Read. Command
#      bodies are injected as prompt text and nothing expands variables there, so the
#      variable only works inside a shell command line. A bare `Read ${CLAUDE_PLUGIN_ROOT}/…`
#      resolves to a literal not-found, which sends the model straight back to `find`.
#
# Runs entirely read-only against the plugin tree; touches no user state.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

PASS=0; FAIL=0
chk() { desc="$1"; shift
  if "$@"; then PASS=$((PASS+1)); printf "  ok   %s\n" "$desc"
  else FAIL=$((FAIL+1)); printf "  FAIL %s\n" "$desc"; fi
}

echo "== A. every command names its skill's file, and that file exists =="
for name in console decorate; do
  cmd="$ROOT_DIR/commands/$name.md"
  skill="$ROOT_DIR/skills/$name/SKILL.md"
  chk "$name: command file exists"  test -f "$cmd"
  chk "$name: skill file exists"    test -f "$skill"
  # The path must name THIS command's skill — a copy-paste that leaves console.md pointing
  # at decorate's SKILL.md would pass a naive "contains a path" check.
  chk "$name: command cites \${CLAUDE_PLUGIN_ROOT}/skills/$name/SKILL.md" \
    grep -qF "\${CLAUDE_PLUGIN_ROOT}/skills/$name/SKILL.md" "$cmd"
  chk "$name: the cited path is inside a shell invocation, not a bare Read target" \
    grep -qE "(cat|bash|source) \"?\\\$\{CLAUDE_PLUGIN_ROOT\}/skills/$name/SKILL\.md" "$cmd"
  chk "$name: tells the model to read it FIRST" \
    sh -c 'grep -qiE "first, before anything else" "$0"' "$cmd"
  chk "$name: warns against locating it with find/Glob" \
    sh -c 'grep -qiE "find. or .Glob|with \`find\`" "$0"' "$cmd"
done

echo
echo "== B. the commands stay thin routers =="
# A command may accompany a skill only as a thin delegating entry point. The console command
# used to compress the five-step verify loop into two sentences and present that as the
# punchline, which is what made the command body feel sufficient on its own — a weaker loop
# shipped in the artifact that gets injected INSTEAD of the skill.
CONSOLE_CMD="$ROOT_DIR/commands/console.md"
chk "console command defers the verify loop to the skill" \
  sh -c 'grep -qiE "verify loop is five steps|Run it from the skill" "$0"' "$CONSOLE_CMD"
chk "console command does not claim respawn+capture is the whole loop" \
  sh -c '! grep -qiE "Always finish by respawning" "$0"' "$CONSOLE_CMD"
for name in console decorate; do
  cmd="$ROOT_DIR/commands/$name.md"
  # Thin means thin: these routers are argument parsers plus a pointer. If one grows past
  # ~60 lines it has started duplicating the skill, which is the failure the catalog names.
  n=$(wc -l < "$cmd")
  chk "$name: command stays under 60 lines (is $n)"  test "$n" -lt 60
  chk "$name: says the skill wins on disagreement" \
    sh -c 'grep -qi "the skill wins" "$0"' "$cmd"
done

echo
echo "== C. no hardcoded install paths =="
# A literal /Users/... or ~/.claude/plugins/... path breaks the moment the plugin installs
# anywhere else, and pointing at a versioned cache dir is how the stale-copy read happened.
for name in console decorate; do
  cmd="$ROOT_DIR/commands/$name.md"
  chk "$name: no /Users/ path" \
    sh -c '! grep -q "/Users/" "$0"' "$cmd"
  chk "$name: no ~/.claude plugins-cache path" \
    sh -c '! grep -qE "~/\.claude[^ ]*/plugins" "$0"' "$cmd"
done

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
