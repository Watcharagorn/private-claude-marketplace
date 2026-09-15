"""Focused tests for the canonical marketplace generator."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from datetime import date
from pathlib import Path
from unittest import mock


SOURCE_ROOT = Path(__file__).resolve().parents[2]
REPO_ROOT = Path(os.environ.get("MARKETPLACE_ROOT", SOURCE_ROOT))
CLI = Path(os.environ.get("MARKETPLACE_CLI", SOURCE_ROOT / "scripts" / "marketplace"))


class MarketplaceCliTests(unittest.TestCase):
    def run_cli(self, root: Path, *arguments: str, expected: int = 0) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            [sys.executable, str(CLI), "--root", str(root), *arguments],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def make_fixture(self) -> tempfile.TemporaryDirectory[str]:
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        shutil.copytree(REPO_ROOT / "marketplace", root / "marketplace")
        (root / "plugins").mkdir()
        (root / "marketplace" / "catalog.json").write_text(
            json.dumps(
                {
                    "$schema": "./catalog.schema.json",
                    "schemaVersion": 1,
                    "name": "fixture-marketplace",
                    "displayName": "Fixture Marketplace",
                    "owner": {"name": "Fixture"},
                    "plugins": [],
                }
            ),
            encoding="utf-8",
        )
        self.addCleanup(temporary.cleanup)
        return temporary

    def test_repository_projections_are_current_and_codex_hooks_are_disabled(self) -> None:
        self.run_cli(REPO_ROOT, "validate")
        self.run_cli(REPO_ROOT, "validate", "mentor")
        support_matrix = (REPO_ROOT / "marketplace" / "support-matrix.md").read_text()
        self.assertIn("| mentor | dual-enhanced | planning | Supported | Supported |", support_matrix)
        self.assertIn("## Active portability waivers", support_matrix)

        for name in ("mentor", "loom", "tmux-design"):
            root_manifest = json.loads((REPO_ROOT / "plugins" / name / "plugin.json").read_text())
            self.assertEqual(root_manifest["extensions"]["com.openai"]["hooks"], [])
            manifest = json.loads((REPO_ROOT / "plugins" / name / ".codex-plugin" / "plugin.json").read_text())
            self.assertNotIn("hooks", manifest)
            self.assertEqual(manifest["skills"], "./skills/")
            self.assertIn("interface", manifest)

            capabilities = json.loads((REPO_ROOT / "plugins" / name / "capabilities.json").read_text())
            actual_skills = {
                skill.parent.name
                for skill in (REPO_ROOT / "plugins" / name / "skills").glob("*/SKILL.md")
            }
            mapped_skills = {
                skill
                for workflow in capabilities["workflows"]
                for skill in workflow["skills"]
            }
            self.assertEqual(actual_skills, mapped_skills)
            if capabilities["tier"].startswith("dual-"):
                self.assertIsNone(capabilities["waiver"])
                for workflow in capabilities["workflows"]:
                    self.assertEqual(workflow["claude"]["status"], "supported")
                    self.assertEqual(workflow["codex"]["status"], "supported")
            else:
                self.assertGreaterEqual(
                    date.fromisoformat(capabilities["waiver"]["reviewBy"]), date.today()
                )

    def test_new_sync_detects_drift_and_publish_bumps_without_vcs_actions(self) -> None:
        temporary = self.make_fixture()
        root = Path(temporary.name)
        self.run_cli(root, "new", "sample", "--description", "Reusable sample workflow guidance.")
        self.assertTrue((root / "plugins" / "sample" / "skills" / "sample" / "SKILL.md").is_file())
        self.run_cli(root, "validate", "sample")
        self.run_cli(root, "validate")

        canonical = json.loads((root / "plugins" / "sample" / "plugin.json").read_text())
        self.assertEqual(canonical["extensions"]["com.openai"]["hooks"], [])
        capabilities = json.loads((root / "plugins" / "sample" / "capabilities.json").read_text())
        self.assertEqual(capabilities["tier"], "dual-core")
        self.assertEqual(capabilities["hosts"]["claude"]["status"], "supported")
        self.assertEqual(capabilities["hosts"]["codex"]["status"], "supported")

        generated = root / "plugins" / "sample" / ".codex-plugin" / "plugin.json"
        generated.write_text("{}\n", encoding="utf-8")
        result = self.run_cli(root, "validate", "sample", expected=1)
        self.assertIn("generated projection drift", result.stderr)

        self.run_cli(root, "sync", "sample")
        matrix = root / "marketplace" / "support-matrix.md"
        matrix.write_text("stale\n", encoding="utf-8")
        result = self.run_cli(root, "validate", expected=1)
        self.assertIn("marketplace/support-matrix.md", result.stderr)
        self.run_cli(root, "sync")
        with mock.patch.dict(os.environ, {"MARKETPLACE_NESTED_PUBLISH_TEST": "1"}):
            published = self.run_cli(root, "publish", "sample", "--bump", "minor")
        self.assertIn("no commit, tag, or push was performed", published.stdout)
        manifest = json.loads((root / "plugins" / "sample" / "plugin.json").read_text())
        self.assertEqual(manifest["version"], "0.2.0")

    def test_dual_host_tier_rejects_missing_codex_workflow_support(self) -> None:
        temporary = self.make_fixture()
        root = Path(temporary.name)
        self.run_cli(root, "new", "sample")
        path = root / "plugins" / "sample" / "capabilities.json"
        capabilities = json.loads(path.read_text())
        capabilities["workflows"][0]["codex"] = {"status": "unsupported", "test": None}
        capabilities["hosts"]["codex"]["status"] = "unsupported"
        path.write_text(json.dumps(capabilities), encoding="utf-8")
        result = self.run_cli(root, "validate", "sample", expected=1)
        self.assertIn("dual tiers require both hosts supported", result.stderr)

    def test_non_portable_skill_frontmatter_is_rejected_without_external_tools(self) -> None:
        temporary = self.make_fixture()
        root = Path(temporary.name)
        self.run_cli(root, "new", "sample")
        path = root / "plugins" / "sample" / "skills" / "sample" / "SKILL.md"
        skill = path.read_text()
        path.write_text(skill.replace("description:", "version: 1.0.0\ndescription:", 1))
        result = self.run_cli(root, "validate", "sample", expected=1)
        self.assertIn("non-portable skill frontmatter: version", result.stderr)


if __name__ == "__main__":
    unittest.main()
