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

skills = sorted((root / "skills").glob("*/SKILL.md"))
assert len(skills) == 18, len(skills)
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
