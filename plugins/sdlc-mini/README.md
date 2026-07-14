# sdlc-mini

Turbo SDLC helpers. No hooks.

## v1.4.0 — init-turbo-manifest moved to devflow

`init-turbo-manifest` has **moved to the devflow plugin** as the `turbo-manifest` skill, so all
deployment-config ownership (manifest + `thanos-env-vars-*`) now lives together in devflow, and the
manifest workflow was upgraded to the latest schema (`healthcheck`, `publish`, `api_docs`, the
`external` app type, and the new canonical schema URL). The sdlc-mini skill remains only as a
deprecated redirect. To manage a `turbo-manifest.yml`, invoke **`/devflow:turbo-manifest`**.

## v1.0.0 — BREAKING change

The **worktree strategy now lives entirely in the `mentor` plugin** (v0.9.0+).

> **Note (mentor ≥1.0.0):** mentor has since removed worktree strategies entirely — the table
> below is historical. For isolated-branch work use Claude Code's native worktree tooling
> (`EnterWorktree`); mentor's ship flow is now `/mentor:ship` (current branch, no worktrees).

The following sdlc-mini surface area was removed in this release:

- Skills: `sdlc-mini-plan`, `sdlc-mini-finish`
- Hooks: `plan-question-redirect.sh`, `strategy-guard.sh`, `worktree-confine.sh`, `dispatch-executor.sh`
- Scripts: `sdlc-mini-worktree.sh` (allocator + `<project>/.claude-plugin/sdlc.json` `worktrees[]` registry writer)

Equivalent functionality lives in `mentor`:

| sdlc-mini (≤0.4.0) | mentor (≥0.9.0) |
|---|---|
| `sdlc-mini-plan` 4-option strategy question | `mentor-plan` (identical 4 options) |
| `sdlc-mini-worktree.sh allocate <slug>` | inline `git worktree add` in `mentor-plan` |
| `<project>/.claude-plugin/sdlc.json` `worktrees[]` registry | per-tree `.git/worktrees/<name>/mentor.json` state file (captures `source_branch` + `feature_branch`) |
| `worktree-confine.sh` (PreToolUse hard cap) | `mentor/hooks/worktree-confine.sh` (same allow/block rules; gated on the new state file + `git worktree list --porcelain` reconciliation) |
| `strategy-guard.sh` | `mentor/hooks/strategy-guard.sh` (stricter — requires `source=<branch>` in the plan footer) |
| `dispatch-executor.sh` | `mentor/hooks/dispatch-executor.sh` (verbatim port) |
| `/sdlc-mini-finish` (merge to configured `merge_target_branch`) | `/ship` inside the worktree (ff-only merge back into the captured source branch) |

The merge target semantics changed: mentor merges back into the branch that was current when the worktree was allocated (captured as `source_branch`). If you previously relied on sdlc-mini-finish to merge feature→staging regardless of where the worktree was cut from, **checkout `staging` first**, then enter plan mode — the source-branch capture will record `staging` as the merge target.

## What's left

- `skills/init-turbo-manifest/` — **deprecated redirect** → moved to the devflow plugin as
  **`/devflow:turbo-manifest`** (init / add-app / validate / migrate / explain, on the upgraded schema).
- `skills/init-turbo-env-config/` — **deprecated** (the `rogue.py` template model is retired). Now a
  tombstone that redirects to the devflow env-var skills: **`/devflow:config-from-env`** (per-framework
  loader standard), **`/devflow:thanos-env-vars-scaffold`** (scaffold/convert + build the env-var
  catalog), and **`/devflow:thanos-env-vars-setup`** (push the catalog into thanos).
- `skills/release-notes/` — generate a categorized changelog (Features, Bug Fixes, UX Polish) from the latest git tag to HEAD, with a meaningful title. Invoke via `/release-notes` or "what changed since last release". _(added in v1.1.0)_
- `skills/tidy/` — run `/simplify` over the working tree, then commit the result **locally — never pushes**. Invoke via `/tidy` or "simplify and commit". For pushing/PRs use mentor's `/mentor:ship`. _(added in v1.2.0)_

None of these skills touch worktrees.

## Migration — in-flight users

If you upgrade with a sdlc-mini worktree already allocated (registered in `<project>/.claude-plugin/sdlc.json` `worktrees[]`) but not yet finished, complete it manually:

1. From inside the active worktree, note the source branch you originally cut from. If you don't remember, `git log feature/<slug> --not main --oneline | tail -1` shows the first commit on the feature branch; its parent is the source.
2. Switch to the main checkout and merge: `git merge --no-ff feature/<slug>` (or against `staging`, or whatever target you intended).
3. Remove the worktree: `git -C <main-checkout> worktree remove <worktree-path>` (add `--force` if the worktree is dirty), then `git worktree prune`.
4. (Cosmetic) Hand-edit `<project>/.claude-plugin/sdlc.json` to drop the now-orphan entry from `worktrees[]`. No consumer reads that array after upgrade.

New worktrees allocated post-upgrade go through mentor and use the new state-file layout — no further migration needed.

## Layout

```
sdlc-mini/
├── .claude-plugin/plugin.json
├── README.md
├── hooks/hooks.json                    — empty (no hooks registered)
└── skills/
    ├── init-turbo-manifest/SKILL.md
    ├── init-turbo-env-config/SKILL.md
    ├── release-notes/SKILL.md
    └── tidy/SKILL.md
```
