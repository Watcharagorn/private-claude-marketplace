---
description: Remove a plugin from this marketplace, scrub its references repo-wide, and verify nothing dangles
argument-hint: [plugin]
allowed-tools: [Bash, Grep, Read, Edit]
---

# Remove Plugin

Retire one plugin from this marketplace repo in a single pass: drop its marketplace.json
entry, delete its directory, then hunt down every leftover reference across the rest of the
repo. Arguments provided: $ARGUMENTS

- `$1` = plugin name (e.g. `sdlc-mini`). Required.

A plugin's name shows up in far more places than its own directory — other plugins'
reference docs cite it as a tracked example, skill files mention it in changelog-style prose,
and the marketplace manifest lists it once. Deleting the directory alone leaves the manifest
entry (and any of those citations) behind, which is why the discovery grep, the manifest edit,
and the final repo-wide verification grep all matter — and why the verify step must tell a
stale reference (something that assumes the plugin still exists) apart from a deliberate
historical mention (changelog-style prose citing it as a past example) instead of flagging both
the same way.

## Steps

1. **Preflight.** Confirm `plugins/$1/` exists and `.claude-plugin/marketplace.json` has an
   entry for it. Abort with a clear message if either check fails.
2. **Discover cross-references.** `grep -rl "$1" . --exclude-dir=.git` before touching
   anything, so the full "who mentions this plugin" list is captured while the directory still
   exists to anchor the search.
3. **Remove the manifest entry.** Edit `.claude-plugin/marketplace.json` to delete the `$1`
   block from the `plugins` array, leaving the surrounding entries' formatting untouched.
4. **Validate JSON.** `python3 -m json.tool .claude-plugin/marketplace.json` — must succeed
   before the directory is deleted, so a bad edit is caught while it's still easy to undo.
5. **Delete the plugin directory.** `rm -rf plugins/$1`.
6. **Repo-wide verification sweep.** Re-run the search wider than step 2, since a stale
   mention doesn't always share the plugin's exact casing or live only in prose:
   - `grep -rli "$1" . --exclude-dir=.git` (case-insensitive text)
   - `find . -iname "*$1*" -not -path "./.git/*"` (leftover files/dirs by name)
   - `git ls-files | xargs grep -li "$1"` (tracked files specifically)
7. **Triage every hit from step 6.** For each remaining match, read enough surrounding
   context (`grep -n -B3 -A3`) to decide: a **stale reference** (docs/skills that assume the
   plugin is still installed, an active instruction, a still-listed dependency) must be fixed
   now; a **deliberate historical mention** (changelog-style prose describing a past version
   bump, a "used to include X" example) is left alone and called out explicitly rather than
   silently passed or silently "fixed".

## Output

A summary: manifest diff, directory removed, the full list of remaining hits from step 6 each
labeled fixed / deliberate-keep, and a final verdict. Fail loudly (non-zero) only if a stale
reference from step 7 was left unfixed — deliberate historical mentions do not fail the check.
