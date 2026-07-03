#!/usr/bin/env bash
# test-hooks-json-paths.sh — regression guard for hooks.json path portability.
#
# A plugin's hooks.json must reference its scripts through the harness-provided
# ${CLAUDE_PLUGIN_ROOT}, NEVER a hardcoded absolute path. A hardcoded path (e.g.
# ~/.claude/plugins/<marketplace>/plugins/<plugin>/hooks/...) does not match the
# real install location (~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/),
# so EVERY hook silently fails with "No such file or directory" once installed —
# which voids mentor's entire fail-closed gate guarantee. This test fails if that
# defect (regressed once, v0.24.0–v0.37.0) ever comes back. See
# session d892ce9e audit / plan mentor-audit-d892ce9e-hooks-path-portability.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="$(dirname "$SCRIPT_DIR")"
HJ="$HOOKS_DIR/hooks.json"
[ -f "$HJ" ] || { echo "FATAL: hooks.json not found at $HJ" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required" >&2; exit 1; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf "  ok   %s\n" "$1"; }
bad()  { FAIL=$((FAIL+1)); printf "  FAIL %s\n" "$1"; }

echo "== A. hooks.json is valid JSON =="
if jq . "$HJ" >/dev/null 2>&1; then ok "parses as JSON"; else bad "hooks.json is not valid JSON"; fi

# All command strings, anywhere in the structure.
CMDS="$(jq -r '.. | .command? // empty' "$HJ")"

echo "== B. no hardcoded absolute install paths =="
if printf '%s\n' "$CMDS" | grep -q '/\.claude/plugins/'; then
  bad "a command hardcodes /.claude/plugins/ (must use \${CLAUDE_PLUGIN_ROOT})"
  printf '%s\n' "$CMDS" | grep '/\.claude/plugins/' | sed 's/^/       offending: /'
else ok "no command references /.claude/plugins/"; fi

if printf '%s\n' "$CMDS" | grep -q '/Users/'; then
  bad "a command hardcodes a /Users/ home path"
  printf '%s\n' "$CMDS" | grep '/Users/' | sed 's/^/       offending: /'
else ok "no command references /Users/"; fi

echo "== C. every hooks/*.sh reference goes through \${CLAUDE_PLUGIN_ROOT} =="
bad_refs=0
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  case "$cmd" in
    *hooks/*.sh*)
      case "$cmd" in
        *'${CLAUDE_PLUGIN_ROOT}'*) : ;;
        *) bad_refs=$((bad_refs+1)); printf "       not rooted: %s\n" "$cmd" ;;
      esac
      ;;
  esac
done <<< "$CMDS"
if [ "$bad_refs" = 0 ]; then ok "all hooks/*.sh refs use \${CLAUDE_PLUGIN_ROOT}"; else bad "$bad_refs command(s) reference a hook script without \${CLAUDE_PLUGIN_ROOT}"; fi

echo "== D. every referenced hook script exists on disk =="
missing=0
scripts="$(printf '%s\n' "$CMDS" | sed -nE 's#.*/hooks/([A-Za-z0-9._-]+\.sh).*#\1#p' | sort -u)"
while IFS= read -r s; do
  [ -n "$s" ] || continue
  if [ -f "$HOOKS_DIR/$s" ]; then : ; else missing=$((missing+1)); printf "       missing: %s\n" "$s"; fi
done <<< "$scripts"
if [ "$missing" = 0 ]; then ok "all referenced scripts present in $HOOKS_DIR"; else bad "$missing referenced script(s) missing"; fi

echo "== E. no hook script points the model at a ~/.claude/skills/ path =="
# Same defect class as a hardcoded hooks.json path: a path that won't resolve once
# installed. A hook must NOT emit a user-global ~/.claude/skills/<name> path to reach a
# sibling PLUGIN skill — plugin skills ship under the version-scoped cache, not
# ~/.claude/skills/. Reference sibling skills via Skill(skill="<name>") instead.
# (Regressed once: strategy-guard.sh told the model to read
# ~/.claude/skills/dispatch-agents/SKILL.md, fixed in v0.37.3.)
skills_refs=0
for f in "$HOOKS_DIR"/*.sh; do
  [ -f "$f" ] || continue
  if grep -nE '\.claude/skills/' "$f" >/dev/null 2>&1; then
    skills_refs=$((skills_refs+1))
    grep -nE '\.claude/skills/' "$f" | sed "s#^#       $(basename "$f"): #"
  fi
done
if [ "$skills_refs" = 0 ]; then ok "no hook references a ~/.claude/skills/ path"; else bad "$skills_refs hook script(s) reference a non-portable ~/.claude/skills/ path (use Skill(skill=...))"; fi

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
