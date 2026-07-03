#!/usr/bin/env bash
# test-mode.sh — regression tests for set-mode.sh + the plan-only soft-stop paths
# (approve-plan.sh and dispatch-executor.sh).
#
# Runs against a SANDBOX $HOME so it never touches real user state. The approve-plan
# section builds a strategy-guard-valid HTML fixture (plan-source script block, footer
# markers, fresh mtime) and asserts: gate released, soft-stop text printed, and NO
# dispatch directive in plan-only mode (vs. directive present in plan mode).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$(dirname "$SCRIPT_DIR")"
SETMODE="$HOOKS/set-mode.sh"
APPROVE="$HOOKS/approve-plan.sh"
DISPATCH="$HOOKS/dispatch-executor.sh"
for f in "$SETMODE" "$APPROVE" "$DISPATCH"; do
  [ -f "$f" ] || { echo "FATAL: not found: $f" >&2; exit 1; }
done

ROOT="$(cd "$(mktemp -d)" && pwd -P)"
SANDBOX="$ROOT/home"; mkdir -p "$SANDBOX"
REPO="$ROOT/sample-repo"
git init -q -b main "$REPO" >/dev/null 2>&1
( cd "$REPO"; git config user.email t@t.co; git config user.name t; echo x > f; git add -A; git commit -q -m init ) >/dev/null 2>&1
NONGIT="$ROOT/plain"; mkdir -p "$NONGIT"

trap 'rm -rf "$ROOT"' EXIT

repo_root="$(cd "$REPO" && pwd -P)"
repo_base="$(basename "$repo_root")"
repo_hash="$(printf '%s' "$repo_root" | shasum | cut -c1-8)"
STATE_DIR="$SANDBOX/.claude/mentor/${repo_base}-${repo_hash}"
PLANS_DIR="$STATE_DIR/plans"
CONF="$STATE_DIR/config.json"

PASS=0; FAIL=0
chk() { local desc="$1"; shift
  if "$@"; then PASS=$((PASS+1)); printf "  ok   %s\n" "$desc"
  else FAIL=$((FAIL+1)); printf "  FAIL %s\n" "$desc"; fi
}
# Run set-mode.sh in the repo with sandbox HOME; echo stdout, swallow rc into $RC.
sm() { ( cd "$REPO" && HOME="$SANDBOX" bash "$SETMODE" "$@" 2>&1 ); }

echo "== A. set-mode.sh status / set / invalid / key preservation =="
out="$(sm status)"; rc=$?
chk "unset → exits 0"                  test "$rc" = "0"
chk "unset → prints UNSET token"       sh -c "printf '%s' \"\$0\" | grep -q '^UNSET'" "$out"
chk "unset → orchestrator OFF line"    sh -c "printf '%s' \"\$0\" | grep -q 'orchestrator: OFF'" "$out"

out="$(sm plan-only)"
chk "set plan-only → confirmation"     sh -c "printf '%s' \"\$0\" | grep -q 'mode set: plan-only'" "$out"
chk "config.json written"              test -f "$CONF"
chk "config mode is plan-only"         test "$(jq -r .mode "$CONF")" = "plan-only"

out="$(sm status)"
chk "status → mode: plan-only"         sh -c "printf '%s' \"\$0\" | grep -q '^mode: plan-only'" "$out"

# Key preservation: foreign keys AND the orchestrator flag must survive a mode change.
jq '. + {custom: "keep-me", orchestrator: true}' "$CONF" > "$CONF.tmp" && mv "$CONF.tmp" "$CONF"
out="$(sm plan)"
chk "set plan → confirmation"          sh -c "printf '%s' \"\$0\" | grep -q 'mode set: plan'" "$out"
chk "config mode is plan"              test "$(jq -r .mode "$CONF")" = "plan"
chk "foreign config key preserved"     test "$(jq -r .custom "$CONF")" = "keep-me"
chk "orchestrator flag survives mode write" test "$(jq -r .orchestrator "$CONF")" = "true"
out="$(sm status)"
chk "status → mode: plan"              sh -c "printf '%s' \"\$0\" | grep -q '^mode: plan'" "$out"
chk "status → orchestrator ON line"    sh -c "printf '%s' \"\$0\" | grep -q 'orchestrator: ON'" "$out"

# `commander` is no longer a mode — it REDIRECTS to mode=plan + orchestrator=true.
rm -f "$CONF"
out="$(sm commander)"
chk "commander → redirect notice"      sh -c "printf '%s' \"\$0\" | grep -q 'now the orchestrator toggle'" "$out"
chk "commander → mode=plan written"    test "$(jq -r .mode "$CONF")" = "plan"
chk "commander → orchestrator=true"    test "$(jq -r .orchestrator "$CONF")" = "true"

out="$(sm bogus)"; rc=$?
chk "invalid mode → exit 1"            test "$rc" = "1"
chk "invalid mode → usage printed"     sh -c "printf '%s' \"\$0\" | grep -q 'Usage:'" "$out"

rc=0; ( cd "$NONGIT" && HOME="$SANDBOX" bash "$SETMODE" status >/dev/null 2>&1 ) || rc=$?
chk "non-repo → exit 1"                test "$rc" = "1"

echo "== B. begin-plan.sh mode/format-aware output =="
sm plan-only >/dev/null
out="$( cd "$REPO" && HOME="$SANDBOX" bash "$HOOKS/begin-plan.sh" 2>&1 )"
chk "plan-only notice in begin-plan"   sh -c "printf '%s' \"\$0\" | grep -q 'MODE: plan-only'" "$out"
# both mode AND format unset → ONE combined ask (no competing 'FIRST ask' directives)
rm -f "$CONF"
out="$( cd "$REPO" && HOME="$SANDBOX" bash "$HOOKS/begin-plan.sh" 2>&1 )"
chk "both unset → combined ask"        sh -c "printf '%s' \"\$0\" | grep -q 'Neither a repo MODE nor a plan output FORMAT'" "$out"
chk "both unset → FORMAT: UNSET line"  sh -c "printf '%s' \"\$0\" | grep -q 'FORMAT: UNSET'" "$out"
# mode unset but format set → mode-only ask (and the resolved FORMAT is reported)
( cd "$REPO" && HOME="$SANDBOX" bash "$HOOKS/set-plan-output-format.sh" md >/dev/null )
out="$( cd "$REPO" && HOME="$SANDBOX" bash "$HOOKS/begin-plan.sh" 2>&1 )"
chk "mode unset, format set → mode ask" sh -c "printf '%s' \"\$0\" | grep -q 'No repo mode is set'" "$out"
chk "format set → FORMAT: md line"      sh -c "printf '%s' \"\$0\" | grep -q 'FORMAT: md'" "$out"
rm -f "$CONF" "$PLANS_DIR/.planning" "$PLANS_DIR"/*.html "$PLANS_DIR"/*.md 2>/dev/null || true

echo "== C. approve-plan.sh: plan-only soft stop vs normal dispatch =="
# Strategy-guard-valid fixture: fresh HTML with plan-source block + dispatch footer.
mkdir -p "$PLANS_DIR"
mkfixture() {
  cat > "$PLANS_DIR/fixture-plan.html" <<'HTML'
<!DOCTYPE html><html><body><h1>Fixture plan</h1>
<script type="text/markdown" id="plan-source">
# Fixture plan

1. Do the thing [role: general-purpose · model: sonnet · effort: low]

strategy: dispatch
</script>
</body></html>
HTML
}
# normal-strategy fixture (strategy-guard-valid: strategy: normal + dispatch-agents: skipped).
mknormalfixture() {
  cat > "$PLANS_DIR/fixture-plan.html" <<'HTML'
<!DOCTYPE html><html><body><h1>Fixture plan</h1>
<script type="text/markdown" id="plan-source">
# Fixture plan

1. Do the thing inline — no agents.

strategy: normal
dispatch-agents: skipped
</script>
</body></html>
HTML
}
# malformed fixture: plan-source present but NO strategy footer → strategy-guard rejects it.
mkbadfixture() {
  cat > "$PLANS_DIR/fixture-plan.html" <<'HTML'
<!DOCTYPE html><html><body><h1>Fixture plan</h1>
<script type="text/markdown" id="plan-source">
# Fixture plan

1. Do the thing — but this plan has NO strategy footer marker.
</script>
</body></html>
HTML
}

# plan-only: gate released, soft-stop text, NO dispatch directive.
sm plan-only >/dev/null
mkfixture; : > "$PLANS_DIR/.planning"
out="$( cd "$REPO" && HOME="$SANDBOX" bash "$APPROVE" 2>&1 )"; rc=$?
chk "plan-only approve exits 0"          test "$rc" = "0"
chk "gate released (marker gone)"        test ! -f "$PLANS_DIR/.planning"
chk "soft-stop text present"             sh -c "printf '%s' \"\$0\" | grep -q 'PLAN-ONLY MODE'" "$out"
chk "NO dispatch directive"              sh -c "! printf '%s' \"\$0\" | grep -q 'Dispatch the agents now'" "$out"

# plan: same fixture → dispatch directive IS emitted.
sm plan >/dev/null
mkfixture; : > "$PLANS_DIR/.planning"
out="$( cd "$REPO" && HOME="$SANDBOX" bash "$APPROVE" 2>&1 )"; rc=$?
chk "plan-mode approve exits 0"          test "$rc" = "0"
chk "plan-mode: dispatch directive emitted" sh -c "printf '%s' \"\$0\" | grep -q 'Dispatch the agents now'" "$out"
chk "plan-mode: no soft-stop text"       sh -c "! printf '%s' \"\$0\" | grep -q 'PLAN-ONLY MODE'" "$out"

echo "== D. dispatch-executor.sh: plan-only suppression on the native path =="
mkjson() { python3 -c 'import json,sys;print(json.dumps({"tool_name":"ExitPlanMode","cwd":sys.argv[1],"tool_input":{"plan_path":sys.argv[2]}}))' "$REPO" "$PLANS_DIR/fixture-plan.html"; }
sm plan-only >/dev/null
out="$(printf '%s' "$(mkjson)" | HOME="$SANDBOX" bash "$DISPATCH" 2>&1)"; rc=$?
chk "plan-only native: exit 0"           test "$rc" = "0"
chk "plan-only native: soft-stop text"   sh -c "printf '%s' \"\$0\" | grep -q 'PLAN-ONLY MODE'" "$out"
chk "plan-only native: no fan-out"       sh -c "! printf '%s' \"\$0\" | grep -q 'Dispatch the agents now'" "$out"
sm plan >/dev/null
out="$(printf '%s' "$(mkjson)" | HOME="$SANDBOX" bash "$DISPATCH" 2>&1)"
chk "plan native: fan-out emitted"       sh -c "printf '%s' \"\$0\" | grep -q 'Dispatch the agents now'" "$out"

echo "== E. approve-plan.sh --handoff: approve + hand off, never dispatch =="
# E1. dispatch-strategy plan + --handoff: gate released, hand-off directive, NO dispatch directive
#     (proves dispatch is suppressed even for a dispatch plan that WOULD otherwise fan out).
sm plan >/dev/null
mkfixture; : > "$PLANS_DIR/.planning"
out="$( cd "$REPO" && HOME="$SANDBOX" bash "$APPROVE" --handoff 2>&1 )"; rc=$?
chk "handoff(dispatch) exits 0"               test "$rc" = "0"
chk "handoff(dispatch) gate released"         test ! -f "$PLANS_DIR/.planning"
chk "handoff(dispatch) sentinel + skill ref"  sh -c "printf '%s' \"\$0\" | grep -q 'HAND-OFF REQUESTED' && printf '%s' \"\$0\" | grep -q 'mentor:handoff'" "$out"
chk "handoff(dispatch) NO dispatch directive" sh -c "! printf '%s' \"\$0\" | grep -q 'ENHANCED-PLANNING DISPATCH ACTIVATED'" "$out"

# E2. normal-strategy plan + --handoff: gate released, sentinel present, no plan-only text.
sm plan >/dev/null
mknormalfixture; : > "$PLANS_DIR/.planning"
out="$( cd "$REPO" && HOME="$SANDBOX" bash "$APPROVE" --handoff 2>&1 )"; rc=$?
chk "handoff(normal) exits 0"                 test "$rc" = "0"
chk "handoff(normal) gate released"           test ! -f "$PLANS_DIR/.planning"
chk "handoff(normal) sentinel present"        sh -c "printf '%s' \"\$0\" | grep -q 'HAND-OFF REQUESTED'" "$out"
chk "handoff(normal) no plan-only text"       sh -c "! printf '%s' \"\$0\" | grep -q 'PLAN-ONLY MODE'" "$out"

# E3. malformed plan + --handoff: validation precedes the hand-off branch → exit non-zero,
#     gate STAYS closed, no sentinel printed.
sm plan >/dev/null
mkbadfixture; : > "$PLANS_DIR/.planning"
out="$( cd "$REPO" && HOME="$SANDBOX" bash "$APPROVE" --handoff 2>&1 )"; rc=$?
chk "handoff(malformed) exits non-zero"       test "$rc" != "0"
chk "handoff(malformed) gate STAYS closed"    test -f "$PLANS_DIR/.planning"
chk "handoff(malformed) no sentinel"          sh -c "! printf '%s' \"\$0\" | grep -q 'HAND-OFF REQUESTED'" "$out"

echo "== F. md output format: approve / dispatch / strategy-guard resolve the .md deliverable =="
SETFMT="$HOOKS/set-plan-output-format.sh"
GUARD="$HOOKS/strategy-guard.sh"
setfmt() { ( cd "$REPO" && HOME="$SANDBOX" bash "$SETFMT" "$@" 2>&1 ); }
# Pure-markdown plan: footer markers at EOF, NO plan-source block, dispatch annotation inline.
mkmdfixture() {
  rm -f "$PLANS_DIR"/*.html "$PLANS_DIR"/*.md
  cat > "$PLANS_DIR/fixture-plan.md" <<'MD'
# Fixture plan (markdown)

## Approach
1. Do the thing [role: general-purpose · model: sonnet · effort: low]

strategy: dispatch
MD
}
mkmdjson() { python3 -c 'import json,sys;print(json.dumps({"tool_name":"ExitPlanMode","cwd":sys.argv[1],"tool_input":{"plan_path":sys.argv[2]}}))' "$REPO" "$PLANS_DIR/fixture-plan.md"; }

sm plan >/dev/null
out="$(setfmt md)"
chk "set-plan-output-format md → confirmation" sh -c "printf '%s' \"\$0\" | grep -q 'plan output format set: md'" "$out"
chk "config format is md"                       test "$(jq -r .format "$CONF")" = "md"
chk "set format preserved mode=plan"            test "$(jq -r .mode "$CONF")" = "plan"

mkmdfixture; : > "$PLANS_DIR/.planning"
out="$( cd "$REPO" && HOME="$SANDBOX" bash "$APPROVE" 2>&1 )"; rc=$?
chk "md approve exits 0 (resolves .md)"         test "$rc" = "0"
chk "md approve released gate"                  test ! -f "$PLANS_DIR/.planning"
chk "md approve: dispatch directive"            sh -c "printf '%s' \"\$0\" | grep -q 'Dispatch the agents now'" "$out"
chk "md approve: plan path is the .md"          sh -c "printf '%s' \"\$0\" | grep -q 'fixture-plan.md'" "$out"

out="$(printf '%s' "$(mkmdjson)" | HOME="$SANDBOX" bash "$DISPATCH" 2>&1)"
chk "md dispatch: fan-out emitted"              sh -c "printf '%s' \"\$0\" | grep -q 'Dispatch the agents now'" "$out"
chk "md dispatch: read-directly directive"      sh -c "printf '%s' \"\$0\" | grep -q 'read the plan directly'" "$out"
chk "md dispatch: NO plan-source instruction"   sh -c "! printf '%s' \"\$0\" | grep -q 'plan-source'" "$out"

# strategy-guard: format=md but only a stale .html present → reject with the md message.
rm -f "$PLANS_DIR"/*.md
cat > "$PLANS_DIR/stale.html" <<'HTML'
<!DOCTYPE html><html><body><script type="text/markdown" id="plan-source">
# x
strategy: normal
dispatch-agents: skipped
</script></body></html>
HTML
sgjson() { python3 -c 'import json,sys;print(json.dumps({"tool_name":"ExitPlanMode","cwd":sys.argv[1],"tool_input":{"plan_path":sys.argv[2]}}))' "$REPO" "$PLANS_DIR/stale.html"; }
out="$(printf '%s' "$(sgjson)" | HOME="$SANDBOX" bash "$GUARD" 2>&1)"; rc=$?
chk "md format + only .html → guard exit 2"     test "$rc" = "2"
chk "md format + only .html → 'no Markdown plan document'" sh -c "printf '%s' \"\$0\" | grep -q 'no Markdown plan document'" "$out"
# And with the .md present, the guard passes.
mkmdfixture
out="$(printf '%s' "$(mkmdjson)" | HOME="$SANDBOX" bash "$GUARD" 2>&1)"; rc=$?
chk "md format + .md present → guard exit 0"     test "$rc" = "0"
rm -f "$PLANS_DIR"/*.html "$PLANS_DIR"/*.md "$PLANS_DIR/.planning"

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
