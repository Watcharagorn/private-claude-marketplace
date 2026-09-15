#!/usr/bin/env python3
"""Inventory Claude-specific plugin surfaces before a dual-host migration."""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Iterable


IGNORED_DIRS = {
    ".git",
    ".hg",
    ".svn",
    "node_modules",
    "vendor",
    "dist",
    "build",
    "target",
    "tests",
    "test",
    "fixtures",
    "evals",
    "__pycache__",
}
TEXT_SUFFIXES = {".md", ".json", ".yaml", ".yml", ".toml", ".sh", ".py", ".js", ".ts"}
PORTABLE_SKILL_KEYS = {"name", "description", "license", "compatibility", "metadata", "allowed-tools"}


@dataclass(frozen=True, order=True)
class Finding:
    severity: str
    code: str
    path: str
    line: int
    message: str


PATTERNS = (
    (
        re.compile(r"\bCLAUDE_PLUGIN_ROOT\b"),
        "review",
        "claude-plugin-root",
        "Claude-only plugin root reference; provide PLUGIN_ROOT or an explicit/skill-relative fallback.",
    ),
    (
        re.compile(r"\bCLAUDE_CONFIG_DIR\b|(?:^|[\s'\"`])~/.claude(?:/|\b)"),
        "review",
        "claude-state-path",
        "Claude-specific state/config path; separate portable state from compatibility readers.",
    ),
    (
        re.compile(r"\$\{user_config\.[^}]+\}"),
        "blocker",
        "claude-user-config",
        "Claude userConfig interpolation is not portable; replace it with explicit input or host-neutral configuration.",
    ),
    (
        re.compile(r"\bAskUserQuestion\b"),
        "review",
        "structured-question-tool",
        "Structured-question tool dependency needs an ordinary conversation fallback.",
    ),
    (
        re.compile(r"(?i)\bclaude(?:\s+live)?\s+artifacts?\b|\bArtifact\s+(?:API|tool)\b"),
        "review",
        "claude-artifact",
        "Claude artifact behavior needs a portable conversation or local-file output.",
    ),
    (
        re.compile(r"(?i)(?:`|\s)/(?:[a-z0-9][a-z0-9-]*):[a-z0-9][a-z0-9-]*"),
        "review",
        "namespaced-slash-command",
        "Namespaced Claude slash command should have a direct skill or natural-language entry point.",
    ),
    (
        re.compile(r"(?i)\b(?:invoke|run|type|use|command(?:\s+is)?)\s+`?/[a-z][a-z0-9-]+"),
        "review",
        "slash-command-dependency",
        "Slash-command-only guidance needs a direct skill or natural-language entry point.",
    ),
    (
        re.compile(r"(?i)\b(?:Task tool|subagents?|delegat(?:e|ion|ing))\b"),
        "review",
        "delegation-dependency",
        "Delegation may need a serial current-task fallback.",
    ),
)


def relative(path: Path, root: Path) -> str:
    try:
        return str(path.relative_to(root)) or "."
    except ValueError:
        return str(path)


def walk_files(root: Path) -> Iterable[Path]:
    for path in sorted(root.rglob("*")):
        if any(part in IGNORED_DIRS for part in path.relative_to(root).parts):
            continue
        if path.is_file() and path.suffix.lower() in TEXT_SUFFIXES and path.stat().st_size <= 1_000_000:
            yield path


def load_json(path: Path, root: Path, findings: list[Finding]) -> dict | list | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        findings.append(
            Finding("blocker", "invalid-json", relative(path, root), 1, f"Cannot parse JSON: {exc}")
        )
        return None


def top_level_frontmatter_keys(text: str) -> set[str]:
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return set()
    keys: set[str] = set()
    for line in lines[1:]:
        if line.strip() == "---":
            return keys
        match = re.match(r"^([A-Za-z0-9_-]+)\s*:", line)
        if match:
            keys.add(match.group(1))
    return keys


def looks_like_plugin(path: Path) -> bool:
    return any(
        candidate.exists()
        for candidate in (
            path / "plugin.json",
            path / ".claude-plugin" / "plugin.json",
            path / ".codex-plugin" / "plugin.json",
            path / "skills",
            path / "commands",
            path / "hooks",
        )
    )


def discover_plugin_roots(root: Path, findings: list[Finding]) -> list[Path]:
    plugin_roots: set[Path] = set()
    if looks_like_plugin(root):
        plugin_roots.add(root)

    marketplace_path = root / ".claude-plugin" / "marketplace.json"
    if marketplace_path.is_file():
        value = load_json(marketplace_path, root, findings)
        if isinstance(value, dict) and isinstance(value.get("plugins"), list):
            for entry in value["plugins"]:
                if not isinstance(entry, dict):
                    continue
                source = entry.get("source")
                source_path: str | None = None
                if isinstance(source, str):
                    source_path = source
                elif isinstance(source, dict) and source.get("source") == "local":
                    candidate = source.get("path")
                    if isinstance(candidate, str):
                        source_path = candidate
                if source_path and not re.match(r"^[a-z]+://", source_path):
                    candidate = (root / source_path).resolve()
                    if candidate.is_dir() and (candidate == root or root in candidate.parents):
                        plugin_roots.add(candidate)

    plugins_dir = root / "plugins"
    if plugins_dir.is_dir():
        for candidate in plugins_dir.iterdir():
            if candidate.is_dir() and looks_like_plugin(candidate):
                plugin_roots.add(candidate.resolve())

    return sorted(plugin_roots) or [root]


def add_structure_findings(plugin_root: Path, scope: Path, findings: list[Finding]) -> None:
    surfaces = (
        (".claude-plugin/plugin.json", "info", "claude-manifest", "Claude plugin manifest is present."),
        ("plugin.json", "info", "portable-manifest", "Root portable manifest is present."),
        (".codex-plugin/plugin.json", "info", "codex-manifest", "Codex compatibility manifest is present."),
        ("hooks/hooks.json", "review", "claude-hooks", "Hook events and payloads require per-host semantic review."),
        (".mcp.json", "review", "claude-mcp", "Claude MCP configuration requires transport, path, and auth review."),
        ("mcp.json", "info", "portable-mcp", "Portable MCP configuration is present."),
        ("settings.json", "review", "claude-settings", "Claude plugin settings need a portable fallback or adapter."),
    )
    for rel_path, severity, code, message in surfaces:
        path = plugin_root / rel_path
        if path.exists():
            findings.append(Finding(severity, code, relative(path, scope), 1, message))

    for directory, code, message in (
        ("commands", "claude-commands", "Convert reusable commands to skills; retain commands only as Claude facades."),
        ("agents", "claude-agents", "Move reusable agent procedures into skills and provide a serial fallback."),
        ("output-styles", "claude-output-styles", "Extract essential behavior from Claude output styles."),
        ("monitors", "claude-monitors", "Background monitors require an explicit Codex adapter or support exception."),
        ("themes", "claude-themes", "Themes are presentation-only unless a workflow depends on them."),
        ("bin", "claude-bin", "Do not assume Claude PATH injection in portable workflows."),
    ):
        path = plugin_root / directory
        if path.is_dir():
            findings.append(Finding("review", code, relative(path, scope), 1, message))

    if (plugin_root / ".claude-plugin" / "plugin.json").is_file() and not (plugin_root / "plugin.json").is_file():
        findings.append(
            Finding(
                "review",
                "missing-portable-manifest",
                relative(plugin_root, scope),
                1,
                "No root Agent Plugins manifest; add one or document why the repository uses another canonical source.",
            )
        )


def audit_skill(path: Path, root: Path, text: str, findings: list[Finding]) -> None:
    if path.name != "SKILL.md":
        return
    keys = top_level_frontmatter_keys(text)
    if not keys:
        findings.append(
            Finding("blocker", "missing-skill-frontmatter", relative(path, root), 1, "SKILL.md has no closed YAML frontmatter block.")
        )
        return
    for key in sorted(keys - PORTABLE_SKILL_KEYS):
        findings.append(
            Finding(
                "review",
                "host-specific-skill-frontmatter",
                relative(path, root),
                1,
                f"Top-level skill frontmatter key {key!r} is outside the portable baseline.",
            )
        )


def compare_manifests(plugin_root: Path, scope: Path, findings: list[Finding]) -> None:
    manifests: list[tuple[str, dict]] = []
    for rel_path in ("plugin.json", ".claude-plugin/plugin.json", ".codex-plugin/plugin.json"):
        path = plugin_root / rel_path
        if not path.is_file():
            continue
        value = load_json(path, scope, findings)
        if isinstance(value, dict):
            manifests.append((relative(path, scope), value))
    for field in ("name", "version"):
        values = {str(value[field]) for _, value in manifests if field in value}
        if len(values) > 1:
            locations = ", ".join(path for path, value in manifests if field in value)
            findings.append(
                Finding(
                    "blocker",
                    "manifest-identity-drift",
                    relative(plugin_root, scope),
                    1,
                    f"Manifest {field} values differ across {locations}.",
                )
            )


def audit_capability_exposure(plugin_root: Path, scope: Path, findings: list[Finding]) -> None:
    path = plugin_root / "capabilities.json"
    if not path.is_file() or not (plugin_root / "skills").is_dir():
        return
    value = load_json(path, scope, findings)
    if not isinstance(value, dict) or not isinstance(value.get("workflows"), list):
        return
    for host in ("claude", "codex"):
        exposed: set[str] = set()
        for workflow in value["workflows"]:
            if not isinstance(workflow, dict):
                continue
            host_record = workflow.get(host)
            if not isinstance(host_record, dict) or host_record.get("status") == "supported":
                continue
            skills = workflow.get("skills")
            if isinstance(skills, list):
                exposed.update(
                    skill
                    for skill in skills
                    if isinstance(skill, str) and (plugin_root / "skills" / skill / "SKILL.md").is_file()
                )
        if exposed:
            findings.append(
                Finding(
                    "blocker",
                    "unsupported-skill-exposure",
                    relative(path, scope),
                    1,
                    f"Default skills exposes {', '.join(sorted(exposed))} although capabilities marks them {host} partial/unsupported; move, wrap, or project them selectively.",
                )
            )


def audit(root: Path) -> list[Finding]:
    root = root.resolve()
    findings: list[Finding] = []
    for rel_path, severity, code, message in (
        (".claude-plugin/marketplace.json", "review", "claude-marketplace", "Claude marketplace projection is present."),
        (".agents/plugins/marketplace.json", "info", "codex-marketplace", "Codex marketplace projection is present."),
    ):
        path = root / rel_path
        if path.is_file():
            findings.append(Finding(severity, code, rel_path, 1, message))
    plugin_roots = discover_plugin_roots(root, findings)
    for plugin_root in plugin_roots:
        add_structure_findings(plugin_root, root, findings)
        compare_manifests(plugin_root, root, findings)
        audit_capability_exposure(plugin_root, root, findings)
    seen_patterns: set[tuple[str, str]] = set()
    for plugin_root in plugin_roots:
        for path in walk_files(plugin_root):
            try:
                text = path.read_text(encoding="utf-8")
            except (OSError, UnicodeError) as exc:
                findings.append(Finding("review", "unreadable-text", relative(path, root), 1, str(exc)))
                continue
            audit_skill(path, root, text, findings)
            for number, line in enumerate(text.splitlines(), 1):
                for pattern, severity, code, message in PATTERNS:
                    key = (relative(path, root), code)
                    if key not in seen_patterns and pattern.search(line):
                        seen_patterns.add(key)
                        findings.append(Finding(severity, code, key[0], number, message))
    return sorted(set(findings), key=lambda item: (item.path, item.line, item.severity, item.code))


def render_markdown(root: Path, findings: list[Finding]) -> str:
    counts = {severity: sum(item.severity == severity for item in findings) for severity in ("blocker", "review", "info")}
    lines = [
        f"# Dual-host migration audit: `{root}`",
        "",
        f"Findings: {counts['blocker']} blocker, {counts['review']} review, {counts['info']} info.",
        "",
    ]
    if not findings:
        lines.append("No known Claude-specific surfaces were detected. This is not proof of runtime compatibility.")
        return "\n".join(lines)
    lines.extend(("| Severity | Code | Location | Guidance |", "|---|---|---|---|"))
    for item in findings:
        location = f"{item.path}:{item.line}"
        message = item.message.replace("|", "\\|")
        lines.append(f"| {item.severity} | `{item.code}` | `{location}` | {message} |")
    lines.extend(("", "Review findings semantically; do not apply blind string replacement."))
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path, help="Claude plugin or marketplace root to inspect")
    parser.add_argument("--format", choices=("markdown", "json"), default="markdown")
    args = parser.parse_args(argv)
    root = args.path.expanduser().resolve()
    if not root.is_dir():
        parser.error(f"not a directory: {root}")
    findings = audit(root)
    if args.format == "json":
        payload = {"root": str(root), "findings": [asdict(item) for item in findings]}
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(render_markdown(root, findings))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
