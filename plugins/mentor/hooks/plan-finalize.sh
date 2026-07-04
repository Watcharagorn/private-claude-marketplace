#!/usr/bin/env bash
# plan-finalize.sh — terminate the HTML review surface at approval; persist the canonical Markdown.
#
# The styled HTML plan is a REVIEW-TIME artifact only: rich to look at, expensive to re-read
# (rendered markup + inline CSS burn context every time a hook or agent consumes it). The moment
# the user confirms the plan, the review surface has done its job. This script:
#   1. takes the EXPLICIT plan file the caller already resolved AND validated — it never
#      hunts for "the newest *.html" itself, so a stale HTML lingering from an abandoned
#      session can never be resurrected as a fresh-mtime .md that poisons newest-wins
#      resolvers (approve-plan idempotency, handoff path references, plan-review fallback);
#   2. extracts the canonical Markdown from its <script type="text/markdown" id="plan-source">
#      block (mentor_extract_plan_source — the same extraction strategy-guard.sh validates
#      against, so the .md is byte-identical to what the guard approved);
#   3. persists it as the sibling <slug>.md — footer markers and dispatch annotations land as
#      bare lines, so every downstream consumer (dispatch-executor, implementation, handoff)
#      reads it exactly like a native md-format plan;
#   4. deletes the .html (+ its .opened sidecar) and pre-marks the .md as opened, so
#      plan-open.sh never pops a second review tab for a plan the user already approved.
#
# From approval onward the .md IS the plan file — implementation reads it, never the HTML.
#
# Callers (both post-validation, at the approval moment — this script never fires pre-approval):
#   - approve-plan.sh       (owned flow: Proceed / --handoff — NOT plan-only "Deliver plan":
#                            there the plan file is the user's deliverable and nothing
#                            downstream consumes it, so the rich HTML is kept)
#   - dispatch-executor.sh  (native fallback: PostToolUse:ExitPlanMode, after its plan-only
#                            early-exit and only when the resolved plan is an .html)
# On the owned path dispatch-executor runs second with the already-finalized .md → it skips
# the call entirely (extension check), so double-finalize cannot occur.
#
# Usage:  plan-finalize.sh --plan <path-to-plan.html>
# Stdout: the finalized .md path — printed ONLY when a conversion happened (machine contract:
#         callers do `final="$(… || true)"; [ -n "$final" ] && plan="$final"`). Human/warning
#         text goes to stderr. Always exits 0 (fail-soft: a bad/plan-source-less HTML is KEPT —
#         it still carries the canonical block, so downstream consumers stay functional).
#         A --plan that is empty, missing, or not an .html (e.g. an already-finalized .md,
#         or an md-format plan) is a silent no-op.

set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/state.sh"

target=""
[ "${1:-}" = "--plan" ] && target="${2:-}"
case "$target" in
  *.html) ;;                 # only an HTML review surface is finalizable
  *) exit 0 ;;               # empty / .md / anything else — nothing to finalize
esac
[ -f "$target" ] || exit 0   # already finalized or bad path — no-op

plans_dir="$(dirname "$target")"

# Extract the canonical Markdown (shared with strategy-guard.sh via lib/state.sh).
md_body="$(mentor_extract_plan_source < "$target")"

# Validate BEFORE touching anything: non-empty and carrying the strategy footer marker.
# An html without a well-formed plan-source block is left in place, untouched.
if [ -z "$md_body" ] || ! printf '%s' "$md_body" | grep -qiE '^strategy:'; then
  echo "[mentor plan-finalize] No valid plan-source block in ${target} — HTML kept as the plan." >&2
  exit 0
fi

md_file="${target%.html}.md"

# Atomic write: the .md must be complete before the .html is removed.
tmp="$(mktemp "${plans_dir}/.finalize.XXXXXX" 2>/dev/null)" || exit 0
if ! printf '%s\n' "$md_body" > "$tmp" 2>/dev/null; then
  rm -f "$tmp" 2>/dev/null || true
  echo "[mentor plan-finalize] Could not write ${md_file} — HTML kept as the plan." >&2
  exit 0
fi
if ! mv "$tmp" "$md_file" 2>/dev/null; then
  rm -f "$tmp" 2>/dev/null || true
  echo "[mentor plan-finalize] Could not persist ${md_file} — HTML kept as the plan." >&2
  exit 0
fi

# The user already reviewed the (auto-opened) HTML — suppress plan-open.sh for the .md so a
# post-approval Write/Edit to it never steals focus with a fresh review tab.
: > "${md_file}.opened" 2>/dev/null || true

# Terminate the review surface.
rm -f "$target" "${target}.opened" 2>/dev/null || true

echo "$md_file"
exit 0
