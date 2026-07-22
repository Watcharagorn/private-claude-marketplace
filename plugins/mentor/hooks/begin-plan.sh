#!/usr/bin/env bash
# begin-plan.sh — arm the mentor plan gate.
#
# Invoked by the /mentor:plan command body as its FIRST action, before any
# drafting. It writes the repo-scoped `.planning` marker (which CLOSES the edit
# gate — plan-gate.sh) and clears stale sidecars from a prior planning session.
# It runs as a normal Bash call and is allowed precisely because the gate never
# matches Bash.
#
# The marker's mtime is the SESSION START: approve-plan.sh only accepts a plan
# file NEWER than the marker, so a stale plan from a prior session can never
# release the gate.
#
# Fail-soft: if we cannot resolve a git repo, print a notice and exit 0 — the
# skill still runs; the gate simply isn't armed outside a repo.

set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

repo_root="$(mentor_repo_root "$(pwd)")"
if [ -z "$repo_root" ]; then
  echo "[mentor] Not inside a git repo — plan gate NOT armed (planning still proceeds)."
  exit 0
fi
plans_dir="$(mentor_plans_dir "$repo_root")"

# --- context gate (plan start) ---------------------------------------------
# begin-plan gets no hook stdin, so locate the session transcript ourselves. Over
# the ask threshold the USER decides first: without a session bypass marker we print
# a CONTEXT: ASK directive (AskUserQuestion — hand off, or bypass and plan lean) and
# do NOT arm yet; with the marker the gate arms with a CONTEXT: HANDOFF advisory.
# The UserPromptSubmit gate never sees /mentor:plan (slash passthrough), so we check
# here. Fail-soft: unmeasurable → skip silently (like the not-a-repo grace above).
context_warn=""
if [ "$(mentor_context_gate_state "$repo_root")" = "on" ]; then
  projects_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
  tx=""
  # Primary (exact, race-free): CLAUDE_CODE_SESSION_ID is exported into Bash tool
  # environments and equals the main-session transcript filename.
  if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    tx="$(find "$projects_dir" -maxdepth 2 -name "${CLAUDE_CODE_SESSION_ID}.jsonl" 2>/dev/null | head -1 || true)"
  fi
  # Fallback (older CC without the env var): newest transcript in the hashed project dir.
  if [ -z "$tx" ]; then
    for base in "$(git -C "$(pwd)" rev-parse --show-toplevel 2>/dev/null || true)" "$(pwd)"; do
      [ -n "$base" ] || continue
      hash="$(printf '%s' "$base" | sed 's/[^A-Za-z0-9]/-/g')"
      tx="$(ls -t "${projects_dir}/${hash}"/*.jsonl 2>/dev/null | head -1 || true)"
      [ -n "$tx" ] && break
    done
  fi
  tokens="$(mentor_context_tokens "$tx")"
  if [ -n "$tokens" ]; then
    ask_at="$(mentor_context_threshold "$repo_root" "${MENTOR_CONTEXT_BLOCK_TOKENS:-}" context_block_tokens 350000)"
    warn_at="$(mentor_context_threshold "$repo_root" "${MENTOR_CONTEXT_WARN_TOKENS:-}" context_warn_tokens 200000)"
    if [ "$tokens" -ge "$ask_at" ]; then
      if [ -e "$(mentor_state_dir "$repo_root")/.context-bypass-${CLAUDE_CODE_SESSION_ID:-nosession}" ]; then
        context_warn="CONTEXT: HANDOFF (~${tokens} tokens ≥ ${ask_at}) — critically large (gate bypassed this session): keep planning lean (skip optional zooms and plan-review); at the approval step lead with \"Hand off to next agent (Recommended)\"."
      else
        hook_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        cat <<EOF
CONTEXT: ASK (~${tokens} tokens ≥ ${ask_at})
[mentor] Plan gate NOT armed yet — the user decides first. Do NOT invoke the plan
skill yet; ask via AskUserQuestion (header "Context", two options):
  1. "Hand off & plan in a fresh session (Recommended)" — invoke
     Skill(skill="mentor:handoff") with the plan request as the focus, write the
     handoff doc, print its copy-paste /mentor:resume prompt, and STOP.
  2. "Proceed anyway (bypass + lean plan)" — run \`bash ${hook_dir}/bypass-context.sh\`,
     re-run \`bash ${hook_dir}/begin-plan.sh\`, then invoke the plan skill and keep the
     plan lean (skip optional zooms and plan-review).
(Threshold: "context_block_tokens" in .mentor/config.json or MENTOR_CONTEXT_BLOCK_TOKENS;
disable entirely with MENTOR_CONTEXT_GATE=off.)
EOF
        exit 0
      fi
    elif [ "$tokens" -ge "$warn_at" ]; then
      context_warn="CONTEXT: WARN (~${tokens} tokens ≥ ${warn_at}) — surface to the user; prefer \"Hand off to next agent\" at the approval step."
    fi
  fi
fi

mkdir -p -m 700 "$plans_dir"
mentor_ensure_gitignore "$(mentor_state_dir "$repo_root")"

# One-shot migration (v2.2.0): flat <slug>.md + <slug>-*.html → <slug>/plan.md +
# <slug>/zoom/<topic>-<perspective>.html. Longest slug first, so "auth-retry"'s
# zooms are never captured by a shorter "auth" plan. Orphan html with no matching
# .md is left in place (harmless, gitignored).
while IFS= read -r f; do
  [ -f "$f" ] || continue
  slug="$(basename "$f" .md)"
  mkdir -p -m 700 "${plans_dir}/${slug}"
  mv -n "$f" "${plans_dir}/${slug}/plan.md" 2>/dev/null || true
  for h in "${plans_dir}/${slug}-"*.html; do
    [ -f "$h" ] || continue
    mkdir -p -m 700 "${plans_dir}/${slug}/zoom"
    base="${h##*/}"
    mv -n "$h" "${plans_dir}/${slug}/zoom/${base#"$slug"-}" 2>/dev/null || true
  done
done < <(ls "${plans_dir}"/*.md 2>/dev/null | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2- || true)

# Clear per-plan ".opened" sidecars (dot-hidden inside each <slug>/ dir; legacy
# flat ones swept too): plan paths are slug-derived, so a stale sidecar from a
# prior session would suppress plan-open.sh's first-creation open for the same slug.
find "$plans_dir" \( -name '*.opened' -o -name '.*.opened' \) -delete 2>/dev/null || true

: > "${plans_dir}/.planning"

cat <<EOF
[mentor] Plan phase ARMED.
  marker: ${plans_dir}/.planning
  edits:  repo source writes are now BLOCKED until the plan is approved
          (plan-gate.sh — holds even under bypassPermissions).

Now follow the plan skill. Do NOT edit repo files until approval.
EOF

[ -n "$context_warn" ] && echo "$context_warn"

# The mode is only the APPROVAL-GATE DEFAULT — it decides which option the
# Step-6 approval question lists first; both outcomes are always offered.
# Never ask the user to pick a mode upfront.
mode="$(mentor_get_mode "$repo_root")"
case "$mode" in
  plan-only)
    echo "MODE: plan-only"
    echo '[mentor] Approval default: "Deliver plan only" listed first ("Proceed" always offered).'
    ;;
  "")
    echo "MODE: UNSET (default: plan)"
    echo '[mentor] No approval default persisted — "Proceed" listed first. Set one with /mentor:mode.'
    ;;
  *)
    echo "MODE: ${mode}"
    echo '[mentor] Approval default: "Proceed" listed first ("Deliver plan only" always offered).'
    ;;
esac
exit 0
