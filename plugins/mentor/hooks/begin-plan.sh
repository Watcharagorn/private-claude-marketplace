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
# begin-plan gets no hook stdin, so locate the session transcript ourselves and
# refuse to ARM the gate when the session is already too large for a reliable plan.
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
    block_at="$(mentor_context_threshold "$repo_root" "${MENTOR_CONTEXT_BLOCK_TOKENS:-}" context_block_tokens 270000)"
    warn_at="$(mentor_context_threshold "$repo_root" "${MENTOR_CONTEXT_WARN_TOKENS:-}" context_warn_tokens 200000)"
    if [ "$tokens" -ge "$block_at" ]; then
      cat <<EOF
CONTEXT: BLOCKED (~${tokens} tokens ≥ ${block_at})
[mentor] Plan gate NOT armed — this session's context is too large for a reliable plan.
STOP: do NOT invoke the plan skill. Tell the user to run one of:
  • /mentor:handoff "<focus>"   then  /mentor:resume   in a fresh session, or
  • /compact
and then re-run /mentor:plan. Override for this session with
MENTOR_CONTEXT_BLOCK_TOKENS=<n> (or "context_block_tokens" in .mentor/config.json).
EOF
      exit 0
    fi
    if [ "$tokens" -ge "$warn_at" ]; then
      context_warn="CONTEXT: WARN (~${tokens} tokens ≥ ${warn_at}) — surface to the user; prefer \"Hand off to next agent\" at the approval step."
    fi
  fi
fi

mkdir -p -m 700 "$plans_dir"
mentor_ensure_gitignore "$(mentor_state_dir "$repo_root")"

# Clear per-plan ".opened" sidecars: plan paths are slug-derived, so a stale
# "<slug>.md.opened" from a prior session would suppress plan-open.sh's
# first-creation open for the same slug.
rm -f "${plans_dir}"/*.opened 2>/dev/null || true

: > "${plans_dir}/.planning"

cat <<EOF
[mentor] Plan phase ARMED.
  marker: ${plans_dir}/.planning
  edits:  repo source writes are now BLOCKED until the plan is approved
          (plan-gate.sh — holds even under bypassPermissions).

Now follow the plan skill. Do NOT edit repo files until approval.
EOF

[ -n "$context_warn" ] && echo "$context_warn"

mode="$(mentor_get_mode "$repo_root")"
case "$mode" in
  plan-only)
    echo "MODE: plan-only"
    cat <<'EOF'
plan-only — after approval the plan file is the DELIVERABLE. Do NOT implement
and do NOT dispatch implementation agents; the approval step will soft-stop.
EOF
    ;;
  "")
    echo "MODE: UNSET"
    cat <<'EOF'
No repo mode is set. After entering the plan skill, FIRST ask the user via
AskUserQuestion which mode to persist for this repo — plan (default: plan then
execute on approval) / plan-only (plans are deliverables; no execution) — then run:
  bash "${CLAUDE_PLUGIN_ROOT}/hooks/set-mode.sh" <choice>
and continue planning.
EOF
    ;;
  *)
    echo "MODE: ${mode}"
    ;;
esac
exit 0
