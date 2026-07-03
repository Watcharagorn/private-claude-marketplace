---
name: publish-plugin
description: >
  Publish (release) a plugin inside this ntbx-marketplace repo. Bumps the plugin's semver,
  syncs the version + description into the plugin manifest, the marketplace manifest, and the
  plugin README (keeping manifest descriptions short and meaningful — trimming bloat on sight, never
  changelogs), validates the JSON, then commits and pushes to origin/main.
  Invoke when the user says "publish the plugin", "release <plugin>", "pump/bump version and push",
  "ship the marketplace plugin", or "/publish-plugin". Repo-scoped to ntbx-marketplace.
version: 1.2.0
---

# Publish Plugin (ntbx-marketplace)

Release a plugin in this marketplace repo: pick the version bump, propagate it everywhere it's
recorded, validate, and push. This is the codified version of the manual release flow used in this
repo — bump the version, keep the manifests and git in sync, and record release notes in git (and README if present).

## When to invoke

- User says "publish the plugin", "release `<plugin>`", "bump/pump the version and push"
- User added or changed a skill/hook/script in `plugins/<name>/` and wants it shipped
- User types `/publish-plugin`

## Repo layout (where things live)

- `plugins/<name>/.claude-plugin/plugin.json` — per-plugin manifest (`version` + brief `description`)
- `.claude-plugin/marketplace.json` — top-level catalog; one entry per plugin with a mirrored brief `description`
- `plugins/<name>/README.md` — human docs (optional; the place for a changelog if you keep one)
- `plugins/<name>/skills/*/SKILL.md` — skills (each has its own `version` in frontmatter)

Two plugins ship today: `mentor`, `sdlc-mini`.

## Procedure

### 1. Identify the target plugin and what changed

```bash
git -C . status
git -C . log --oneline -5
# What's new/changed under plugins/?
git -C . status --porcelain plugins/
```

- If the user named the plugin, use it. Otherwise infer from the changed paths under `plugins/<name>/`.
- If multiple plugins changed, ask which one to publish (or publish each in its own commit).
- Read the current `version` from `plugins/<name>/.claude-plugin/plugin.json`.

### 2. Decide the semver bump

Classify the change against the current version `MAJOR.MINOR.PATCH`:

- **MAJOR** — a breaking change: a removed/renamed skill, hook, script, or config key; changed merge/state semantics; anything that breaks existing users. (e.g. sdlc-mini `0.4.0 → 1.0.0` removed skills + hooks.)
- **MINOR** — additive feature: a **new skill**, new hook, new flag, new capability that is backward-compatible. (e.g. sdlc-mini `1.0.0 → 1.1.0` added the `release-notes` skill.)
- **PATCH** — bug fix or doc/wording fix only, no new surface. (e.g. mentor `0.14.1 → 0.14.2`.)

State the proposed version and the reasoning, then proceed (don't block on confirmation unless the bump is ambiguous — e.g. a change that could be read as either breaking or additive).

### 3. Bump `plugins/<name>/.claude-plugin/plugin.json`

- Set `"version"` to the new value.
- **Leave `"description"` alone** unless this release actually changes what the plugin *does* or
  the surfaces it ships. The `description` is a **brief, present-tense, single-sentence** summary of
  the plugin's purpose (~50–150 chars, target ≤ ~220) — per the official Claude Code docs it is shown
  in the `/plugin` manager when browsing/installing, so it must read as "what is this", not "what
  changed". It is **not** a changelog. Do **not** prepend per-version notes to it. If the release does
  change the plugin's purpose/surface, edit the one sentence to describe the new reality (still
  brief) — don't append history.
- **Keep it short — trim bloat on sight (overrides "leave it alone").** The description must stay a
  **brief, meaningful blurb**: capture the plugin's identity (what it is + its one defining mechanism),
  **not** an inventory of every command/skill/flag. If the *existing* description has already grown
  into a multi-clause feature dump or changelog — **regardless of whether this release touched the
  plugin's purpose** — shorten it to the brief form as part of this release. This is the one case
  where you deliberately rewrite an otherwise-untouched description. A description over ~300 chars is
  almost always bloated: cut it. (Editing the giant string by hand is error-prone — set it with `jq`:
  `jq --arg d "<new>" '.description=$d' plugins/<name>/.claude-plugin/plugin.json > t && mv t plugins/<name>/.claude-plugin/plugin.json`.)

### 4. Mirror into `.claude-plugin/marketplace.json`

- Find the `plugins[]` entry whose `"name"` matches the plugin.
- Keep its `"description"` in sync with the plugin.json one (it may be a slightly fuller prose form —
  the marketplace description spells things out without the backtick-heavy manifest style — but it is
  still a brief one- to two-sentence summary, target ≤ ~400 chars, never a changelog). Touch it when
  step 3 changed the plugin.json description **or** when the existing marketplace description is
  bloated (the same trim-on-sight rule as step 3 applies here). Edit only the matching entry — set it
  with `jq` so you don't touch sibling entries:
  `jq --arg d "<new>" '(.plugins[]|select(.name=="<name>").description)=$d' .claude-plugin/marketplace.json > t && mv t .claude-plugin/marketplace.json`.
  The marketplace entry has **no** `version` field. Leave `source` and `category` alone.

### 5. Record the release notes (NOT in the description)

The changelog lives in the git history and, where present, the README — never in the manifest
`description`. For this release:

- The **git commit message** (step 7) is the canonical per-release note. Write a real summary there.
- If `plugins/<name>/README.md` exists and has a version/changelog or feature section, add a
  `## vX.Y.Z` entry / new feature line there. (Not all plugins have a README — that's fine; the
  commit message suffices.)
- If the new surface is a skill, make sure its own `SKILL.md` frontmatter `version` is sensible
  (it doesn't have to equal the plugin version, but shouldn't be left at a stale placeholder).

### 6. Validate before committing

```bash
# Both manifests must be valid JSON
python3 -m json.tool plugins/<name>/.claude-plugin/plugin.json >/dev/null && echo "plugin.json OK"
python3 -m json.tool .claude-plugin/marketplace.json >/dev/null && echo "marketplace.json OK"

# Confirm the version actually changed and the marketplace entry exists
grep -n '"version"' plugins/<name>/.claude-plugin/plugin.json
grep -n '"name": "<name>"' .claude-plugin/marketplace.json

# Descriptions must stay brief blurbs, not feature dumps / changelogs.
pd=$(jq -r '.description | length' plugins/<name>/.claude-plugin/plugin.json)
md=$(jq -r --arg n "<name>" '.plugins[] | select(.name==$n) | .description | length' .claude-plugin/marketplace.json)
echo "description chars — plugin.json: $pd · marketplace: $md"
[ "$pd" -gt 300 ] && echo "WARN: plugin.json description is long ($pd) — trim to a brief one-sentence blurb (step 3)"
[ "$md" -gt 450 ] && echo "WARN: marketplace description is long ($md) — trim to 1–2 sentences (step 4)"

# Hook-path portability: hooks.json must reference scripts via ${CLAUDE_PLUGIN_ROOT},
# never a hardcoded absolute path (a hardcoded path silently breaks EVERY hook once the
# plugin installs under ~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/).
hj="plugins/<name>/hooks/hooks.json"
if [ -f "$hj" ]; then
  if jq -r '.. | .command? // empty' "$hj" | grep -qE '/\.claude/plugins/|/Users/'; then
    echo "FAIL: $hj hardcodes an absolute install path — use \${CLAUDE_PLUGIN_ROOT}/hooks/..."; exit 1
  else echo "hooks.json paths OK"; fi
fi
# If the plugin ships path tests, run them (e.g. mentor):
[ -f plugins/<name>/hooks/tests/test-hooks-json-paths.sh ] && bash plugins/<name>/hooks/tests/test-hooks-json-paths.sh
```

If either JSON fails to parse, or a hook path is hardcoded, fix it before going further — a broken
manifest breaks the whole marketplace, and a hardcoded hook path makes the plugin inert on install.

### 7. Commit and push

Stage the plugin dir plus the marketplace manifest, commit with a conventional message, push to `main`.

```bash
git -C . add plugins/<name>/ .claude-plugin/marketplace.json
git -C . commit -m "$(cat <<'EOF'
feat(<name>): <summary>, bump to vX.Y.Z

<one or two lines on what the release contains and why>

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
git -C . push origin main
```

- Use `feat(<name>):` for MINOR, `fix(<name>):` for PATCH, `feat(<name>)!:` or a `BREAKING CHANGE:` footer for MAJOR.
- Confirm the push landed (report the new short SHA and the `old..new main -> main` line).

## Rules

- **Keep the surfaces in sync**: plugin.json `version`, and — only when purpose/surface changed —
  the plugin.json + marketplace.json `description`. A version bumped in only one place is a bug.
- The `description` fields are **brief, meaningful, one-sentence summaries** (plugin.json ≤ ~220
  chars; marketplace ≤ ~400, 1–2 sentences), NOT changelogs or feature inventories. Never prepend
  per-version notes to them; release notes go in the commit message (and README if present).
  (This repo previously stuffed multi-version changelogs into `description` — one hit the 10k-char
  cap. That was an anti-pattern; the docs define `description` as a brief, UI-only purpose blurb.)
- **An over-long description is a bug to fix this release, not state to preserve.** Trim it to the
  brief form on sight — even when the plugin's purpose didn't change and even if this release
  touched nothing else about it (steps 3–4).
- Never edit another plugin's manifest in the same commit unless the user is publishing it too.
- Default to one plugin per commit. If several changed, publish them separately.
- Only `git push` after the user has asked to publish/push (this skill is invoked for exactly that),
  and only push `main` unless told otherwise.
- Always validate JSON (step 6) before committing — a malformed manifest takes down the marketplace.
- Match the existing description/README voice; don't reformat untouched entries — the **one
  exception** is trimming a bloated description to the brief form (steps 3–4).
