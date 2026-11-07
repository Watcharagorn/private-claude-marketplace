#!/usr/bin/env bash
# Static and executable checks for the Mentor Claude Code/Codex portability contract.
set -euo pipefail

plugin_root="$(cd "$(dirname "$0")/.." && pwd -P)"

python3 - "$plugin_root" <<'PY'
import json
import re
import sys
from pathlib import Path

root = Path(sys.argv[1])
manifest = json.loads((root / "plugin.json").read_text())
assert manifest["extensions"]["com.openai"]["hooks"] == []

capabilities = json.loads((root / "capabilities.json").read_text())
assert capabilities["tier"] == "dual-enhanced"
assert capabilities["hosts"]["claude"]["status"] == "supported"
assert capabilities["hosts"]["codex"]["status"] == "supported"
assert capabilities["hosts"]["codex"]["hooks"] is False
workflows = {workflow["name"]: workflow for workflow in capabilities["workflows"]}
tracking = workflows["planning"]["fallback"]
for declaration in (
    "Claude-only hooks:",
    "per-prompt plan pointer (context-gate.sh)",
    "SessionStart re-attachment (plan-reattach.sh)",
    "automatic hook-recorded plan_sha256 hashes on Write/Edit (plan-open.sh)",
    "plan-state.sh record-write <slug>",
    "drift <slug> (known/changed/unknown)",
    "portable record-write, drift and tick commands",
):
    assert declaration in tracking, declaration
for host in ("claude", "codex"):
    assert workflows["planning"][host]["status"] == "supported"

hooks = json.loads((root / "hooks" / "hooks.json").read_text())["hooks"]
assert len(hooks["SessionStart"]) == 1
reattach = hooks["SessionStart"][0]
assert "matcher" not in reattach  # Includes clear/fork as well as startup/resume/compact.
assert reattach["hooks"][0]["command"] == 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-reattach.sh"'
assert (root / "hooks" / "plan-reattach.sh").is_file()

skills = sorted((root / "skills").glob("*/SKILL.md"))
assert len(skills) == 9, len(skills)
for skill in skills:
    text = skill.read_text()
    assert "Use a structured question UI when the host offers one" in text, skill
    assert "PLUGIN_ROOT" in text, skill
    assert "~/.claude/mentor/_no-repo" not in text, skill

harness = (root / "evals" / "harness.py").read_text()
assert 'args[0] in ("claude", "codex")' in harness
assert '".agents"' in harness
assert '"codex", "exec"' in harness

evals = json.loads((root / "evals" / "evals.json").read_text())
direct_plan = next(case for case in evals["evals"] if case["id"] == 20)
assert direct_plan["expected"] == "planning"

for host in ("claude", "codex"):
    assert (root / "adapters" / host / "README.md").is_file()
PY

printf 'PASS mentor dual-host contract\n'
