---
name: release-notes
description: >
  Generate a quick release note from the latest release tag to the current commit.
  Produces a meaningful title + categorized changelog (Features, Bug Fixes, UX Polish).
  Invoke when the user says "release note", "generate release notes", "what changed since last release", or "/release-notes".
version: 1.1.0
---

# Release Notes Generator

Generate a concise, human-readable release note from the latest git tag to HEAD.

## When to invoke

- User says "generate release note", "release notes", "what changed since last release"
- User types `/release-notes`
- User asks for a changelog before a deployment or merge to master

## Procedure

### 1. Sync remote tags and discover the range

Always fetch remote tags first — local tags may be stale if Jenkins or CI has tagged a release since the last fetch.

```bash
# Sync remote tags (fast, non-destructive)
git fetch --tags

# Latest tag by semver (handles vX.Y.Z-N pattern correctly)
LATEST_TAG=$(git tag --sort=-version:refname | head -1)

# Tag date and subject for context
git show ${LATEST_TAG} --format="%ai %s" -s

# Commits in range (one-line)
git log ${LATEST_TAG}..HEAD --oneline
```

**If HEAD is already contained in the latest tag** (empty log output): the current branch has no unreleased commits. Ask the user whether they want release notes *for* the latest tag (i.e., `<prev-tag>` → `<latest-tag>`) and re-run with that range:

```bash
PREV_TAG=$(git tag --sort=-version:refname | sed -n '2p')
git log ${PREV_TAG}..${LATEST_TAG} --oneline
git show ${PREV_TAG} --format="%ai %s" -s
```

### 2. Filter signal commits

Keep only user-visible work. **Exclude** these prefixes (internal pipeline noise):
- `pipeline(*)` — SDLC agent commits
- `chore(sdlc)` — gitignore/cleanup
- `plan(*)` — plan revisions
- `docs(*)` — documentation-only changes
- `ux(*)` — unless it produced a visible UI change

**Include** these prefixes:
- `feat(*)` — new features
- `fix(*)` — bug fixes
- `ux(*)` — visual/UX polish that users see

### 3. Determine the next version

Inspect the tag pattern (e.g. `v1.8.0-1`). Apply semver bump:
- Any `feat(*)` commit present → **minor** bump (e.g. `v1.9.0`)
- Bug fixes only → **patch** bump (e.g. `v1.8.1`)
- Breaking changes noted in commit message → **major** bump

Strip the build suffix (`-1`) from the proposed next version tag.

### 4. Write the release note

Output directly in the conversation (no file write unless asked). Format:

```
## Release Notes — <NEXT_VERSION> (<DATE>)

**Range:** `<LATEST_TAG>` → HEAD (`<TAG_DATE>` → today)

---

### Features

**<REQ-ID or short label> — <Feature Name>**
- <bullet: what changed and why it matters to the user>
- <bullet: ...>

### Bug Fixes

- **<Area>:** <one-line description of what was broken and how it's fixed>

### UX Polish

- <one-line improvement>
```

### 5. Suggest a title

After the body, suggest a short meaningful title (5–7 words, title-case) that captures the theme, e.g.:
- "Wishlist Sort, Auth Hardening & Cleanup"
- "Auth Session Fix & Hard Delete"

## Rules

- **Always run `git fetch --tags` before any tag lookup** — never trust local-only tags.
- Never include pipeline/chore/plan/arch/docs commits in the output — they are implementation noise.
- Group `feat` commits by REQ number when possible; if multiple REQs share a theme, merge under one heading.
- If a REQ has no user-facing description (only pipeline commits), omit it.
- Bug fixes get one line each — no sub-bullets unless there are two distinct aspects.
- UX Polish is optional; skip the section if there are none.
- Keep the full note under ~40 lines. Trim sub-bullets to the most impactful points.
- Do NOT write to a file unless the user explicitly asks to save it.
