#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("audit_claude_plugin.py")
SPEC = importlib.util.spec_from_file_location("audit_claude_plugin", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class AuditTests(unittest.TestCase):
    def test_detects_identity_and_portability_risks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / ".claude-plugin").mkdir()
            (root / ".claude-plugin" / "plugin.json").write_text(
                json.dumps({"name": "demo", "version": "1.0.0"}), encoding="utf-8"
            )
            (root / "plugin.json").write_text(
                json.dumps({"name": "demo", "version": "1.0.1"}), encoding="utf-8"
            )
            skill = root / "skills" / "demo"
            skill.mkdir(parents=True)
            (skill / "SKILL.md").write_text(
                "---\nname: demo\ndescription: Demo\nargument-hint: topic\n---\n"
                "Run `${CLAUDE_PLUGIN_ROOT}/scripts/demo.sh`, use AskUserQuestion, then use `/demo`.\n",
                encoding="utf-8",
            )

            findings = MODULE.audit(root)
            codes = {item.code for item in findings}
            self.assertIn("manifest-identity-drift", codes)
            self.assertIn("host-specific-skill-frontmatter", codes)
            self.assertIn("claude-plugin-root", codes)
            self.assertIn("structured-question-tool", codes)
            self.assertIn("slash-command-dependency", codes)

    def test_portable_skill_has_no_risk_findings(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "plugin.json").write_text(
                json.dumps({"name": "demo", "version": "1.0.0"}), encoding="utf-8"
            )
            skill = root / "skills" / "demo"
            skill.mkdir(parents=True)
            (skill / "SKILL.md").write_text(
                "---\nname: demo\ndescription: Create a demo output.\n---\nCreate the requested demo.\n",
                encoding="utf-8",
            )

            findings = MODULE.audit(root)
            risks = [item for item in findings if item.severity in {"blocker", "review"}]
            self.assertEqual([], risks)

    def test_marketplace_discovers_local_plugins(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / ".claude-plugin").mkdir()
            (root / ".claude-plugin" / "marketplace.json").write_text(
                json.dumps({"plugins": [{"name": "demo", "source": "./plugins/demo"}]}),
                encoding="utf-8",
            )
            plugin = root / "plugins" / "demo" / ".claude-plugin"
            plugin.mkdir(parents=True)
            (plugin / "plugin.json").write_text(
                json.dumps({"name": "demo", "version": "1.0.0"}), encoding="utf-8"
            )

            findings = MODULE.audit(root)
            by_code = {item.code: item for item in findings}
            self.assertEqual("plugins/demo", by_code["missing-portable-manifest"].path)
            self.assertIn("claude-marketplace", by_code)

    def test_detects_unsupported_default_skill_exposure(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "plugin.json").write_text(
                json.dumps({"name": "demo", "version": "1.0.0"}), encoding="utf-8"
            )
            skill = root / "skills" / "claude-only"
            skill.mkdir(parents=True)
            (skill / "SKILL.md").write_text(
                "---\nname: claude-only\ndescription: Claude-only workflow.\n---\nRun it.\n",
                encoding="utf-8",
            )
            (root / "capabilities.json").write_text(
                json.dumps(
                    {
                        "workflows": [
                            {
                                "skills": ["claude-only"],
                                "claude": {"status": "supported"},
                                "codex": {"status": "unsupported"},
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )

            findings = MODULE.audit(root)
            exposure = [item for item in findings if item.code == "unsupported-skill-exposure"]
            self.assertEqual(1, len(exposure))
            self.assertIn("codex", exposure[0].message)


if __name__ == "__main__":
    unittest.main()
