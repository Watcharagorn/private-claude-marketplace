#!/usr/bin/env bash
# Verify that Loom's maintainer workflow owns canonical inputs and both projections.
set -euo pipefail

plugin_root="$(cd "$(dirname "$0")/.." && pwd -P)"
repo_root="$(cd "$plugin_root/../.." && pwd -P)"

"$repo_root/scripts/marketplace" validate loom >/dev/null

python3 - "$plugin_root" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
manifest = json.loads((root / "plugin.json").read_text())
assert manifest["extensions"]["com.openai"]["hooks"] == []

capabilities = json.loads((root / "capabilities.json").read_text())
publish = next(item for item in capabilities["workflows"] if item["name"] == "publish-plugin")
assert publish["claude"]["status"] == "supported"
assert publish["codex"]["status"] == "supported"

skill = (root / "skills" / "publish-plugin" / "SKILL.md").read_text()
for required in (
    "scripts/marketplace sync",
    "scripts/marketplace validate",
    "scripts/verify-plugin-edits",
    "Never edit a generated Claude Code or Codex",
    "manifest/catalog by hand",
):
    assert required in skill, required
PY

printf 'PASS loom dual-host publish contract\n'
