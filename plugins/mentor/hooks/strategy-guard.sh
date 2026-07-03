#!/usr/bin/env bash
# PreToolUse:ExitPlanMode
#
# Validates that the plan body satisfies the marker contract for the declared strategy.
# Supersedes the global dispatch-agents-guard.sh.
#
# Exit 0 = allow, Exit 2 = block (stderr fed back to Claude).

. "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

input=$(cat)
tool_name=$(echo "$input" | jq -r '.tool_name // ""')
[ "$tool_name" != "ExitPlanMode" ] && exit 0

# Resolve the plan body. ExitPlanMode's tool surface evolved: the legacy shape
# passed `tool_input.plan` (a string); the current shape carries no body and
# the plan lives in a file Claude Code already wrote. Try, in order:
#   1. tool_input.plan_path  — explicit path, when surfaced by the host
#   2. tool_input.plan       — legacy inline body
#   3. most-recent *.md under $HOME/.claude/mentor/plans/<basename>-<hash>/
#                              — primary global fallback (v0.13.0+)
#   4. most-recent *.md under "${cwd}/.claude/plans/" — legacy in-repo fallback
#                              (pre-0.13 plans; kept for one version, drop in 0.14)
plan_path=$(echo "$input" | jq -r '.tool_input.plan_path // ""')
plan_inline=$(echo "$input" | jq -r '.tool_input.plan // ""')
cwd=$(echo "$input" | jq -r '.cwd // ""')

# Derive the global plans dir from cwd's git repo root (lib/state.sh, matches SKILL.md Step 6b).
global_plans_dir=""
legacy_plans_dir=""
if [ -n "$cwd" ]; then
  repo_root=$(mentor_repo_root "$cwd")
  if [ -n "$repo_root" ]; then
    global_plans_dir=$(mentor_plans_dir "$repo_root")
    # Pre-0.33 location — an in-flight session may still write here. Drop in 0.34.
    legacy_plans_dir="${HOME}/.claude/mentor/plans/$(basename "$repo_root")-$(printf '%s' "$repo_root" | shasum | cut -c1-8)"
  fi
fi

# Resolve the configured output format → deliverable file extension. The plan is
# persisted with this extension and that file is the REQUIRED deliverable below.
#   md              → *.md   (Mermaid-first Markdown; the .md is its own canonical source)
#   html (or unset) → *.html (bespoke styled HTML; backward compat — pre-format repos)
plan_ext="$(mentor_plan_ext "${repo_root:-}")"

if [ -n "$plan_path" ] && [ -r "$plan_path" ]; then
  plan=$(cat "$plan_path")
  plan_source="plan_path=${plan_path}"
elif [ -n "$plan_inline" ]; then
  plan="$plan_inline"
  plan_source="tool_input.plan (legacy)"
else
  fallback_file=""
  # Resolve the deliverable by the CONFIGURED format extension (md → *.md, else *.html),
  # newest wins. Foreign-format leftovers are cleared by begin-plan.sh on a format switch.
  if [ -n "$global_plans_dir" ] && [ -d "$global_plans_dir" ]; then
    fallback_file=$(ls -t "${global_plans_dir}/"*."${plan_ext}" 2>/dev/null | head -1)
  fi
  if [ -z "$fallback_file" ] && [ -n "$legacy_plans_dir" ] && [ -d "$legacy_plans_dir" ]; then
    # Pre-0.33 plans location. Drop in 0.34.
    fallback_file=$(ls -t "${legacy_plans_dir}/"*."${plan_ext}" 2>/dev/null | head -1)
  fi
  if [ -z "$fallback_file" ] && [ -n "$cwd" ] && [ -d "${cwd}/.claude/plans" ]; then
    # Legacy in-repo location (pre-v0.13.0). Honored for one release for migration.
    fallback_file=$(ls -t "${cwd}/.claude/plans/"*."${plan_ext}" 2>/dev/null | head -1)
  fi
  if [ -n "$fallback_file" ] && [ -r "$fallback_file" ]; then
    plan=$(cat "$fallback_file")
    plan_source="fallback=${fallback_file}"
  else
    plan=""
    plan_source="<none — no plan_path, no inline plan, no fallback file>"
  fi
fi

# v0.15.0: plans persist as HTML carrying the canonical plan in a
# <script type="text/markdown" id="plan-source">…</script> block. When present,
# extract that block so all marker greps run against clean Markdown (never HTML body).
if printf '%s' "$plan" | grep -q 'id="plan-source"'; then
  plan=$(printf '%s' "$plan" | sed -n '/<script[^>]*id="plan-source"/,/<\/script>/p' | sed '1d;$d')
fi

# Extract declared strategy
strategy=$(echo "$plan" | grep -iE '^strategy:[[:space:]]*' | head -1 | sed 's/^[Ss]trategy:[[:space:]]*//' | tr -d '[:space:]')

if [ -z "$strategy" ]; then
  cat >&2 <<MSG
[mentor strategy-guard] Plan rejected: no "strategy:" line found.
[mentor strategy-guard] Plan source checked: ${plan_source}

Every plan produced by mentor-plan must end with a footer block. Required lines depend on strategy:

  strategy: normal
  dispatch-agents: skipped

  strategy: dispatch
  [role: <subagent_type> · model: <opus|sonnet|haiku> · effort: <low|medium|high>]  ← at least one step

  strategy: worktree
  worktree: /abs/path (branch=<branch-name>, source=<source-branch>)
  dispatch-agents: skipped

  strategy: worktree+dispatch
  worktree: /abs/path (branch=<branch-name>, source=<source-branch>)
  [role: <subagent_type> · model: <opus|sonnet|haiku> · effort: <low|medium|high>]  ← at least one step

Add the footer and call ExitPlanMode again.
MSG
  exit 2
fi

case "$strategy" in

  normal)
    if ! echo "$plan" | grep -qiE 'dispatch-agents:[[:space:]]*(skipped|opted[- ]out|no)'; then
      cat >&2 <<MSG
[mentor strategy-guard] Plan rejected: strategy is "normal" but "dispatch-agents: skipped" marker is missing.

Add this line to the plan footer:
  dispatch-agents: skipped
MSG
      exit 2
    fi
    if echo "$plan" | grep -qiE '^worktree:[[:space:]]/'; then
      cat >&2 <<MSG
[mentor strategy-guard] Plan rejected: strategy is "normal" but a "worktree:" line is present.

Remove the worktree line, or change strategy to "worktree" or "worktree+dispatch".
MSG
      exit 2
    fi
    ;;

  dispatch)
    if ! echo "$plan" | grep -qE '\[role:[[:space:]]*[A-Za-z_-]+'; then
      cat >&2 <<'MSG'
[mentor strategy-guard] Plan rejected: strategy is "dispatch" but no dispatch step annotations found.

Each agent step must be annotated with:
  [role: <subagent_type> · model: <opus|sonnet|haiku> · effort: <low|medium|high>]

See Skill(skill="dispatch-agents") for the full per-step output shape.
MSG
      exit 2
    fi
    if echo "$plan" | grep -qiE 'dispatch-agents:[[:space:]]*(skipped|opted[- ]out|no)'; then
      cat >&2 <<MSG
[mentor strategy-guard] Plan rejected: strategy is "dispatch" but "dispatch-agents: skipped" marker is present.

Remove the "dispatch-agents: skipped" line (it contradicts the dispatch strategy).
MSG
      exit 2
    fi
    ;;

  worktree)
    # Required format: worktree: /abs/path (branch=<name>, source=<source-branch>)
    # No "feature/" prefix requirement — hotfix/, chore/, release/ branches must work.
    if ! echo "$plan" | grep -qE '^worktree:[[:space:]]*/[^[:space:]]+ \(branch=[^,]+, source=[^)]+\)'; then
      # Distinguish "no worktree line at all" vs "line present but missing source="
      if ! echo "$plan" | grep -qiE '^worktree:[[:space:]]*/'; then
        cat >&2 <<MSG
[mentor strategy-guard] Plan rejected: strategy is "worktree" but no "worktree:" line found.

Add this line to the plan footer (fill in values from the allocate step):
  worktree: /abs/path/to/worktree (branch=<branch-name>, source=<source-branch>)
MSG
      else
        cat >&2 <<MSG
[mentor strategy-guard] Plan rejected: "worktree:" line is missing the required source=<branch> field.

This is a v0.8.0 marker change. Re-allocate the worktree via the strategy skill (which will emit source=<branch>), or hand-edit the footer:
  worktree: /abs/path/to/worktree (branch=<branch-name>, source=<source-branch>)
MSG
      fi
      exit 2
    fi
    if ! echo "$plan" | grep -qiE 'dispatch-agents:[[:space:]]*(skipped|opted[- ]out|no)'; then
      cat >&2 <<MSG
[mentor strategy-guard] Plan rejected: strategy is "worktree" but "dispatch-agents: skipped" marker is missing.

Add this line to the plan footer:
  dispatch-agents: skipped
MSG
      exit 2
    fi
    ;;

  worktree+dispatch|worktree\+dispatch)
    if ! echo "$plan" | grep -qE '^worktree:[[:space:]]*/[^[:space:]]+ \(branch=[^,]+, source=[^)]+\)'; then
      if ! echo "$plan" | grep -qiE '^worktree:[[:space:]]*/'; then
        cat >&2 <<MSG
[mentor strategy-guard] Plan rejected: strategy is "worktree+dispatch" but no "worktree:" line found.

Add this line to the plan footer:
  worktree: /abs/path/to/worktree (branch=<branch-name>, source=<source-branch>)
MSG
      else
        cat >&2 <<MSG
[mentor strategy-guard] Plan rejected: "worktree:" line is missing the required source=<branch> field.

This is a v0.8.0 marker change. Re-allocate the worktree via the strategy skill, or hand-edit the footer:
  worktree: /abs/path/to/worktree (branch=<branch-name>, source=<source-branch>)
MSG
      fi
      exit 2
    fi
    if ! echo "$plan" | grep -qE '\[role:[[:space:]]*[A-Za-z_-]+'; then
      cat >&2 <<'MSG'
[mentor strategy-guard] Plan rejected: strategy is "worktree+dispatch" but no dispatch step annotations found.

Each agent step must be annotated with:
  [role: <subagent_type> · model: <opus|sonnet|haiku> · effort: <low|medium|high>]
MSG
      exit 2
    fi
    if echo "$plan" | grep -qiE 'dispatch-agents:[[:space:]]*(skipped|opted[- ]out|no)'; then
      cat >&2 <<MSG
[mentor strategy-guard] Plan rejected: strategy is "worktree+dispatch" but "dispatch-agents: skipped" is present.

Remove the "dispatch-agents: skipped" line.
MSG
      exit 2
    fi
    ;;

  *)
    cat >&2 <<MSG
[mentor strategy-guard] Plan rejected: unknown strategy value "$strategy".

Valid values: normal | dispatch | worktree | worktree+dispatch
MSG
    exit 2
    ;;

esac

# The plan document (mentor-plan Step 6b) is the REQUIRED deliverable. Block exit until a
# plan file of the CONFIGURED format extension (*.${plan_ext}) exists in the global plans
# dir. The harness-native ~/.claude/plans/<name>.md does NOT satisfy this (different dir).
# Skip the check only when we cannot derive the dir (no git repo in cwd).
# v0.38.2: existence, NOT freshness. The earlier `-mmin -120` window false-negatived on
# long sessions. The marker grep above already validated the *resolved* plan's footer (so a
# stale/unrelated plan with mismatched markers is rejected anyway) — freshness added nothing.
if [ -n "$global_plans_dir" ]; then
  recent_plan=$(find "$global_plans_dir" -maxdepth 1 -type f -name "*.${plan_ext}" 2>/dev/null | head -1)
  if [ -z "$recent_plan" ] && [ -n "$legacy_plans_dir" ] && [ -d "$legacy_plans_dir" ]; then
    # Pre-0.33 plans location. Drop in 0.34.
    recent_plan=$(find "$legacy_plans_dir" -maxdepth 1 -type f -name "*.${plan_ext}" 2>/dev/null | head -1)
  fi
  if [ -z "$recent_plan" ]; then
    if [ "$plan_ext" = "md" ]; then
      cat >&2 <<MSG
[mentor strategy-guard] Plan markers OK — but no Markdown plan document was found.

This repo's plan output format is "md": the plan is persisted as a self-contained Markdown
file (Mermaid-first visualization), and THAT is the artifact the user reviews — NOT the
harness's ~/.claude/plans/*.md.

Write the Markdown plan now (mentor-plan Step 6b / "Markdown Plan Document Format"):

  ${global_plans_dir}/<slug>.md

The .md file IS its own canonical source: put the Step-5 footer markers (strategy: / worktree: /
dispatch-agents:) as BARE, unindented lines at end-of-file, and dispatch annotations
([role: … · model: … · effort: …]) inline in the steps. The plan-open.sh hook opens it on
Write. Then call ExitPlanMode again — keep the same slug.
MSG
    else
      cat >&2 <<MSG
[mentor strategy-guard] Plan markers OK — but no HTML plan document was found.

This repo's plan output format is "html": the plan is persisted as a styled, self-contained
HTML file, and that is the artifact the user reviews (it auto-opens for review) — NOT the
harness's ~/.claude/plans/*.md. Writing the native .md does not satisfy this step.

Write the HTML now (mentor-plan Step 6b / Step 8 document format):

  ${global_plans_dir}/<slug>.html

It must embed a <script type="text/markdown" id="plan-source"> block holding the full plan
(footer markers + any [role: … · model: … · effort: …] dispatch annotations). The plan-open.sh
hook will open it for you on Write. Then call ExitPlanMode again — keep the same slug.
MSG
    fi
    exit 2
  fi
fi

# Footer markers + HTML deliverable validated; let the native ExitPlanMode modal capture approval.
exit 0
