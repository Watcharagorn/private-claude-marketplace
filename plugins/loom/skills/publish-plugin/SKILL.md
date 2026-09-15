---
name: publish-plugin
description: >
  Prepare, validate, and release one marketplace plugin through the canonical
  Claude Code and Codex metadata workflow. Invoke when the user asks to publish,
  release, or semver-bump a plugin in this repository.
metadata:
  version: "1.4.0"
---

# Publish Plugin

Release one plugin through the canonical marketplace inputs, then commit and
push only the reviewed result. Never edit a generated Claude Code or Codex
manifest/catalog by hand, because `scripts/marketplace sync` is their sole
writer. For the rule's rationale, read
[Canonical marketplace projection ownership](references/rationale.md#canonical-marketplace-projection-ownership).

## 1. Prepare the intended release

```bash
git status --short
git log --oneline -5
```

- Identify one target plugin. If more than one plugin changed and the user did
  not name a target, ask which release to prepare.
- Work only in its canonical inputs: `plugins/<name>/plugin.json`,
  `plugins/<name>/capabilities.json`, portable skills, and
  `marketplace/catalog.json` when its catalog policy must change. Do not modify
  `.claude-plugin/`, `.agents/plugins/`, or `plugins/<name>/.codex-plugin/`
  directly.
- If available, run the repository's instruction-hygiene workflow before the
  validation steps. It must finish before the release gate so its edits are
  covered too.

## 2. Choose a semantic-version bump

Classify the change against the version in `plugins/<name>/plugin.json`:

- `major` — removed or incompatible public workflow, state format, hook, or
  configuration behavior.
- `minor` — backward-compatible new user-facing capability.
- `patch` — compatible fix, documentation correction, or internal maintenance.

State the selected bump and why. If it is genuinely ambiguous, ask before
changing the version; for an unattended release, choose the lower compatible
class and record the ambiguity in the commit message.

## 3. Synchronize and validate the canonical inputs

Substitute the resolved plugin name for `<plugin>` and run:

```bash
scripts/marketplace sync <plugin>
scripts/marketplace validate <plugin>
scripts/verify-plugin-edits <plugin>
```

Fix every failure before proceeding. `verify-plugin-edits` runs deterministic
plugin tests and skill validation where available; missing Claude Code or Codex
CLIs are explicit warnings, not permission to ignore canonical failures.

## 4. Prepare the versioned release

Run the canonical publisher with the bump chosen in step 2:

```bash
scripts/marketplace publish <plugin> --bump major|minor|patch
```

The command updates the canonical `plugin.json`, regenerates all host
projections, validates them, and runs deterministic marketplace tests. It does
not commit, tag, or push. Do not supply a hand-written version or edit a
projection after this command.

## 5. Make the final release decision

```bash
scripts/marketplace validate <plugin>
scripts/verify-plugin-edits <plugin>
git diff --check
git diff --name-only
```

- Treat any unexpected changed path as a stop condition. Re-run `sync` to
  repair projection drift; do not patch a generated file.
- Record release notes in the reviewed commit message (and an existing plugin
  README when appropriate), never by appending changelog text to a manifest
  description.
- Stage only the individually reviewed canonical inputs and their generated
  projections. Never use `git add .` or `git add -A`.
- Commit using `feat(<plugin>)!:` for a major release, `feat(<plugin>):` for a
  minor release, and `fix(<plugin>):` for a patch release. Push only when the
  user asked to publish to the configured remote.

## Release rules

- One plugin per release unless the user explicitly requests a coordinated
  release.
- Preserve released durable-state readers or ship an explicit, tested migration
  before a state-format change.
- A release is incomplete until the clean-cache installation smoke check has
  passed in each supported host. CI supplies deterministic Linux validation;
  execute authenticated host installation checks in the release environment.
