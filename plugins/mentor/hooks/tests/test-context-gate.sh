#!/usr/bin/env bash
# test-context-gate.sh — regression tests for context-gate.sh (UserPromptSubmit),
# begin-plan.sh's plan-start context check, and bypass-context.sh (v2.8.0: the gate
# never blocks/erases — the top tier ASKS the user, with a session bypass marker).
#
# Builds a real git repo (project-scoped .mentor/ state) and a set of transcript
# fixtures, then drives the hook with UserPromptSubmit JSON across the full tier
# matrix: passthroughs, kill switch, threshold precedence, once-per-session warn,
# the ask tier and its degradations, transcript extraction edge cases, and
# fail-soft robustness.
#
# Since v2.34.0 this hook also carries the planning-intent nudge as tier 2 (see
# test-planning-nudge.sh). Every case here pins MENTOR_PLANNING_INTENT=off so the tiers
# stay separately measurable; section J below is the one place both run at once, and it
# exists because the merge's whole risk is one tier's early return swallowing the other.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$(dirname "$SCRIPT_DIR")"
HOOK="$HOOKS/context-gate.sh"
BEGIN="$HOOKS/begin-plan.sh"
for f in "$HOOK" "$BEGIN"; do [ -f "$f" ] || { echo "FATAL: not found: $f" >&2; exit 1; }; done
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required to run this suite" >&2; exit 1; }

ROOT="$(cd "$(mktemp -d)" && pwd -P)"
REPO="$ROOT/sample-repo"
git init -q -b main "$REPO" >/dev/null 2>&1
( cd "$REPO"; git config user.email t@t.co; git config user.name t; echo x > f; git add -A; git commit -q -m init ) >/dev/null 2>&1
STATE="$REPO/.mentor"; mkdir -p "$STATE"
CONF="$STATE/config.json"
ERRFILE="$ROOT/err"
BASH_BIN="$(command -v bash)"
NOJQ_DIR="$ROOT/nojq"; mkdir -p "$NOJQ_DIR"   # empty PATH dir → `command -v jq` fails

trap 'rm -rf "$ROOT"' EXIT

# Transcript builder (all fixture kinds live in one python script).
BUILDER="$ROOT/build.py"
cat > "$BUILDER" <<'PY'
import json,sys
f=sys.argv[1]; parts=sys.argv[2].split(":"); kind=parts[0]
def au(t): return {"type":"assistant","message":{"usage":{"input_tokens":t,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
def side(t): return {"type":"assistant","isSidechain":True,"message":{"usage":{"input_tokens":t,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
def synth(): return {"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
def compact(p): return {"type":"system","subtype":"compact_boundary","compactMetadata":{"postTokens":p}}
K={
 "usage": lambda: [au(int(parts[1]))],
 "sidechain_mask": lambda: [au(int(parts[1])), side(3), side(4)],
 "all_sidechain": lambda: [side(3), side(4)],
 "compact_after": lambda: [au(int(parts[1])), compact(int(parts[2]))],
 "usage_after_compact": lambda: [compact(6000), au(int(parts[1]))],
 "garbage": lambda: ["GARBAGE NOT JSON", au(int(parts[1])), "{broken json"],
 "usageless": lambda: [{"type":"assistant","message":{"content":"no usage"}}, au(int(parts[1]))],
 "synthetic_trailing": lambda: [au(int(parts[1])), synth(), synth()],
 "no_assistant": lambda: [{"type":"user","message":{"content":"hi"}}, {"type":"system","subtype":"other"}],
}
lines=K[kind]()
with open(f,"w") as fh:
    for l in lines: fh.write((l if isinstance(l,str) else json.dumps(l))+"\n")
PY
mktx() { python3 "$BUILDER" "$1" "$2"; }

# Standard fixtures.
TX_UNDER="$ROOT/under.jsonl";  mktx "$TX_UNDER" usage:150000
TX_WARN="$ROOT/warn.jsonl";    mktx "$TX_WARN"  usage:215000
TX_WARN_SMALL_GROW="$ROOT/warn-small-grow.jsonl"; mktx "$TX_WARN_SMALL_GROW" usage:240000   # +25k: under the 50k re-arm delta
TX_WARN_BIG_GROW="$ROOT/warn-big-grow.jsonl";     mktx "$TX_WARN_BIG_GROW"   usage:270000   # +55k: over the 50k re-arm delta
TX_ASK="$ROOT/ask.jsonl";      mktx "$TX_ASK"   usage:365000
TX_NONE="$ROOT/missing.jsonl"  # deliberately not created

PASS=0; FAIL=0
chk() { local desc="$1"; shift
  if "$@"; then PASS=$((PASS+1)); printf "  ok   %s\n" "$desc"
  else FAIL=$((FAIL+1)); printf "  FAIL %s\n" "$desc"; fi
}
contains() { case "$2" in *"$1"*) return 0;; *) return 1;; esac; }
mkinput() { python3 -c 'import json,sys;print(json.dumps({"prompt":sys.argv[1],"transcript_path":sys.argv[2],"cwd":sys.argv[3],"session_id":sys.argv[4]}))' "$1" "$2" "$3" "$4"; }

# run <prompt> <session> <transcript> [env=val ...] → sets RC / OUT / ERR
run() {
  local prompt="$1" sess="$2" tx="$3"; shift 3
  RC=0
  OUT="$(mkinput "$prompt" "$tx" "$REPO" "$sess" \
    | env -u MENTOR_CONTEXT_GATE -u MENTOR_CONTEXT_WARN_TOKENS -u MENTOR_CONTEXT_BLOCK_TOKENS -u MENTOR_CONTEXT_TAIL_LINES \
        MENTOR_PLANNING_INTENT=off "$@" bash "$HOOK" 2>"$ERRFILE")" || RC=$?
  ERR="$(cat "$ERRFILE")"
}
# run_nojq: same, but with a PATH where jq cannot be found. Input is fed from a FILE
# (not a pipe): the hook exits at the `command -v jq` guard before reading stdin, so a
# pipe would hand its producer a BrokenPipe that pipefail then surfaces as the rc.
run_nojq() {
  local prompt="$1" sess="$2" tx="$3"
  mkinput "$prompt" "$tx" "$REPO" "$sess" > "$ROOT/in.json"
  RC=0
  OUT="$(PATH="$NOJQ_DIR" "$BASH_BIN" "$HOOK" < "$ROOT/in.json" 2>"$ERRFILE")" || RC=$?
  ERR="$(cat "$ERRFILE")"
}
marker() { echo "$STATE/.context-warned-$1"; }

echo "== A. Baseline (fail-soft, quiet) =="
run "hello" a1 "$TX_UNDER"
chk "under-warn → exit 0"        test "$RC" = "0"
chk "under-warn → silent"        test -z "$OUT$ERR"
run "hello" a2 "$TX_NONE"
chk "missing transcript → exit 0" test "$RC" = "0"
chk "missing transcript → silent" test -z "$OUT$ERR"
mktx "$ROOT/na.jsonl" no_assistant
run "hello" a3 "$ROOT/na.jsonl"
chk "no usable usage → exit 0"   test "$RC" = "0"

echo "== B. Warn tier (re-arms on growth) =="
run "hello" warnsess "$TX_WARN"
chk "215k → exit 0"              test "$RC" = "0"
chk "215k → warn notice on stdout" contains "getting large" "$OUT"
chk "215k → warn marker created"   test -e "$(marker warnsess)"
run "hello again" warnsess "$TX_WARN"
chk "same session → silent"        test -z "$OUT"
chk "same session → still exit 0"  test "$RC" = "0"
run "hello" warnsess2 "$TX_WARN"
chk "new session → warns again"    contains "getting large" "$OUT"
# Re-arm-on-growth: a session that keeps climbing past the delta gets more than the one
# notice at the bottom of the WARN-to-WARN-HIGH zone, but small growth stays quiet.
run "hello" warngrow "$TX_WARN"
chk "warngrow 215k → warns"              contains "getting large" "$OUT"
run "hello" warngrow "$TX_WARN_SMALL_GROW"
chk "warngrow +25k (< delta) → silent"   test -z "$OUT"
run "hello" warngrow "$TX_WARN_BIG_GROW"
chk "warngrow +55k (≥ delta) → re-warns" contains "getting large" "$OUT"
# A synthetic prompt must NOT spend the human's once-per-session warn: in a fan-out
# session the first prompt over the threshold is usually an inbound agent report.
run "<task-notification>reviewer finished</task-notification>" warnsyn "$TX_WARN"
chk "synthetic at warn → exit 0"            test "$RC" = "0"
chk "synthetic at warn → silent"            test -z "$OUT"
chk "synthetic at warn → no marker burned"  test ! -e "$(marker warnsyn)"
run "hello" warnsyn "$TX_WARN"
chk "human after synthetic → still warns"   contains "getting large" "$OUT"
chk "human after synthetic → marker now set" test -e "$(marker warnsyn)"

echo "== B2. Warn-high tier (near-limit, re-fires) =="
TX_HIGH="$ROOT/high.jsonl"; mktx "$TX_HIGH" usage:320000   # ≥ 315000 (90% of 350k), < 350000
run "hello" hi1 "$TX_HIGH"
chk "320k → exit 0"                          test "$RC" = "0"
chk "320k → near-limit notice"               contains "nearing the handoff" "$OUT"
run "hello again" hi1 "$TX_HIGH"
chk "same session → re-fires (no marker)"    contains "nearing the handoff" "$OUT"
printf '{"context_warn_high_tokens":100000}\n' > "$CONF"
run "hello" hi2 "$TX_UNDER"
chk "config context_warn_high_tokens honored (150k ≥ 100k)" contains "nearing the handoff" "$OUT"
rm -f "$CONF"

echo "== C. Ask tier (top tier — never blocks) =="
run "please do a thing" ask1 "$TX_ASK"
chk "365k plain prompt → exit 0"          test "$RC" = "0"
chk "365k → CONTEXT: ASK directive"       contains "CONTEXT: ASK" "$OUT"
chk "365k → names AskUserQuestion"        contains "AskUserQuestion" "$OUT"
chk "365k → names bypass script"          contains "bypass-context.sh" "$OUT"
chk "365k → nothing on stderr"            test -z "$ERR"
run "and again" ask1 "$TX_ASK"
chk "same session → re-asks (no marker)"  contains "CONTEXT: ASK" "$OUT"
# Bypass marker degrades the ask to a one-line advisory.
: > "$STATE/.context-bypass-askbp"
run "do a thing" askbp "$TX_ASK"
chk "bypassed session → exit 0"           test "$RC" = "0"
chk "bypassed → one-line advisory"        contains "bypassed for this session" "$OUT"
chk "bypassed → no ask directive"         sh -c '! printf "%s" "$1" | grep -q "CONTEXT: ASK"' _ "$OUT"
rm -f "$STATE/.context-bypass-askbp"
# A fresh handoff note (<30 min, in its plan-topic dir) suppresses the question and
# points at /mentor:resume.
mkdir -p "$STATE/plans/test-topic/handoffs"
: > "$STATE/plans/test-topic/handoffs/20260722-101500-test-focus.md"
run "do a thing" askh "$TX_ASK"
chk "fresh handoff note → exit 0"         test "$RC" = "0"
chk "fresh handoff → resume pointer"      contains "/mentor:resume test-focus" "$OUT"
chk "fresh handoff → no ask directive"    sh -c '! printf "%s" "$1" | grep -q "CONTEXT: ASK"' _ "$OUT"
# Once the note is stamped resolved (work done / superseded), the suppression stops applying.
mkdir -p "$STATE/plans/test-topic/handoffs/resolved"
mv "$STATE/plans/test-topic/handoffs/20260722-101500-test-focus.md" \
   "$STATE/plans/test-topic/handoffs/resolved/"
run "do a thing" askr "$TX_ASK"
chk "resolved handoff → ask returns"      contains "CONTEXT: ASK" "$OUT"
rm -rf "$STATE/plans/test-topic"
# Legacy flat-dir notes (pre-v2.10) still suppress the ask.
mkdir -p "$STATE/handoffs"
: > "$STATE/handoffs/20260722-101500-legacy-focus.md"
run "do a thing" askl "$TX_ASK"
chk "legacy flat-dir note → resume pointer" contains "/mentor:resume legacy-focus" "$OUT"
rm -rf "$STATE/handoffs"
run "/mentor:handoff \"x\"" ask2 "$TX_ASK"
chk "slash /mentor:handoff passes"        test "$RC" = "0"
chk "slash /mentor:handoff → silent"      test -z "$OUT$ERR"
run "/compact" ask3 "$TX_ASK"
chk "slash /compact passes"               test "$RC" = "0"
chk "slash /compact → silent"             test -z "$OUT$ERR"
run "" ask4 "$TX_ASK"
chk "empty prompt passes"                 test "$RC" = "0"
chk "empty prompt → silent"               test -z "$OUT$ERR"
# Harness-synthetic prompts at ask level: measured, advised loudly, never questioned.
#
# SYNTHETIC_SHAPES is the observed wire contract, kept as verbatim first lines so a
# harness wording change is a one-line fixture edit rather than an archaeology dig.
# Every entry MUST assert all three properties — an `exit 0` check alone proves nothing
# here, since the gate never blocks and an UNDETECTED prompt also exits 0.
SYNTHETIC_SHAPES=(
  # wrapper form — the tag is on line 2, so the bare-tag patterns cannot match it
  $'Another Claude session sent a message:\n<teammate-message teammate_id="etl-research" color="green">\n{"type":"idle_notification","from":"etl-research"}\n</teammate-message>'
  $'Another Claude session sent a message:\n<agent-message from="step6-docs">fix summary body</agent-message>'
  # task notification
  '<task-notification>reviewer finished: verdict Approved</task-notification>'
  # background-agent stop notices (all three observed numeric/quoted forms)
  'Background agent "You are finishing the google-compat repair ..." was stopped by the user.'
  '3 background agents were stopped by the user: "You are a READ-ONLY reviewer...", "You are a READ-ONLY reviewer..."'
  '1 background agent was stopped by the user'
  # bare tags — unexercised on the main thread today, kept as the inner/sidechain shape
  '<agent-message from="step6-docs">fix summary body</agent-message>'
  '<teammate-message>idle ping</teammate-message>'
)
i=0
for shape in "${SYNTHETIC_SHAPES[@]}"; do
  i=$((i+1))
  label="$(printf '%s' "$shape" | head -1 | cut -c1-46)"
  run "$shape" "asksyn$i" "$TX_ASK"
  chk "synthetic [$label] → exit 0"              test "$RC" = "0"
  chk "synthetic [$label] → loud advisory"       contains "agent report" "$OUT"
  chk "synthetic [$label] → no AskUserQuestion"  sh -c '! printf "%s" "$1" | grep -q "AskUserQuestion"' _ "$OUT"
done
# NEGATIVE: a HUMAN prompt that merely quotes a synthetic phrase must still be asked.
# This is what forbids relaxing the anchored patterns into leading-wildcard matches.
run 'why did I see "3 background agents were stopped by the user" in my log?' asksynneg "$TX_ASK"
chk "human quoting a synthetic phrase → still asks" contains "CONTEXT: ASK" "$OUT"
run 'summarize what Another Claude session sent a message: means' asksynneg2 "$TX_ASK"
chk "human quoting the wrapper mid-sentence → still asks" contains "CONTEXT: ASK" "$OUT"

echo "== D. Kill switch =="
run "do thing" ks1 "$TX_ASK" MENTOR_CONTEXT_GATE=off
chk "env MENTOR_CONTEXT_GATE=off → exit 0" test "$RC" = "0"
chk "env off → silent"                     test -z "$OUT$ERR"
printf '{"context_gate":"off"}\n' > "$CONF"
run "do thing" ks2 "$TX_ASK"
chk "config context_gate=off → exit 0"     test "$RC" = "0"
rm -f "$CONF"

echo "== E. Threshold precedence (env > config > default) =="
run "do thing" p1 "$TX_UNDER" MENTOR_CONTEXT_BLOCK_TOKENS=1000
chk "env lowers ask threshold → CONTEXT: ASK" contains "CONTEXT: ASK" "$OUT"
chk "env lowers → still exit 0"            test "$RC" = "0"
printf '{"context_block_tokens":1000}\n' > "$CONF"
run "do thing" p2 "$TX_UNDER"
chk "config lowers → CONTEXT: ASK"         contains "CONTEXT: ASK" "$OUT"
printf '{"context_block_tokens":999999999}\n' > "$CONF"
run "do thing" p3 "$TX_UNDER" MENTOR_CONTEXT_BLOCK_TOKENS=1000
chk "env beats config → CONTEXT: ASK"      contains "CONTEXT: ASK" "$OUT"
rm -f "$CONF"
run "do thing" p4 "$TX_UNDER" MENTOR_CONTEXT_BLOCK_TOKENS=abc
chk "non-numeric env → default (150k<350k, no ask)" test "$RC" = "0"
chk "non-numeric env → silent"             test -z "$OUT$ERR"

echo "== F. Transcript extraction edge cases (ask-level unless noted) =="
mktx "$ROOT/sm.jsonl" sidechain_mask:365000
run "do thing" f1 "$ROOT/sm.jsonl"
chk "trailing sidechain doesn't mask 365k → asks" contains "CONTEXT: ASK" "$OUT"
chk "trailing sidechain → exit 0"              test "$RC" = "0"
mktx "$ROOT/as.jsonl" all_sidechain
run "do thing" f2 "$ROOT/as.jsonl"
chk "all-sidechain → unmeasurable → exit 0"    test "$RC" = "0"
chk "all-sidechain → silent"                   test -z "$OUT$ERR"
mktx "$ROOT/ca.jsonl" compact_after:365000:5000
run "do thing" f3 "$ROOT/ca.jsonl"
chk "compact_boundary(5000) after 365k → exit 0" test "$RC" = "0"
chk "compact_boundary(5000) → silent"          test -z "$OUT$ERR"
mktx "$ROOT/uac.jsonl" usage_after_compact:365000
run "do thing" f4 "$ROOT/uac.jsonl"
chk "usage after compact → asks"               contains "CONTEXT: ASK" "$OUT"
mktx "$ROOT/gb.jsonl" garbage:365000
run "do thing" f5 "$ROOT/gb.jsonl"
chk "garbage lines interleaved → asks"         contains "CONTEXT: ASK" "$OUT"
mktx "$ROOT/ul.jsonl" usageless:365000
run "do thing" f6 "$ROOT/ul.jsonl"
chk "usage-less assistant skipped → asks"      contains "CONTEXT: ASK" "$OUT"
mktx "$ROOT/syn.jsonl" synthetic_trailing:365000
run "do thing" f7 "$ROOT/syn.jsonl"
chk "trailing <synthetic> all-zero after 365k → asks" contains "CONTEXT: ASK" "$OUT"

echo "== G. Robustness =="
run_nojq "do thing" g1 "$TX_ASK"
chk "no jq on PATH → exit 0"        test "$RC" = "0"
chk "no jq → silent"               test -z "$OUT$ERR"
# 25h-old warn marker is pruned → warn re-fires.
run "hello" prune "$TX_WARN"        # create marker
touch -t "$(date -v-25H +%Y%m%d%H%M 2>/dev/null || date -d '25 hours ago' +%Y%m%d%H%M)" "$(marker prune)" 2>/dev/null || true
run "hello" prune "$TX_WARN"
chk "25h-old marker pruned → warn re-fires" contains "getting large" "$OUT"

echo "== H. begin-plan.sh plan-start check (CLAUDE_CONFIG_DIR + CLAUDE_CODE_SESSION_ID fixtures) =="
CFG="$ROOT/cfg"; mkdir -p "$CFG/projects/proj"
SESS="begin-sess"
# v2.23.0: begin-plan.sh now arms a PER-WORKTREE marker (.planning.<wt-id>), not the
# bare legacy .planning — $REPO here is a normal single-worktree repo, so its wt-id
# resolves non-empty and the created marker carries an unpredictable crc suffix. Match
# the whole `.planning*` family rather than the one literal legacy filename.
has_marker() { ls "${STATE}/plans"/.planning* >/dev/null 2>&1; }
no_marker()  { ! has_marker; }
bp() { # <transcript-tokens|none> → sets RC/OUT; cleans marker first
  rm -f "$STATE/plans/.planning" "$STATE/plans"/.planning.*
  local toks="$1"
  if [ "$toks" = "none" ]; then rm -f "$CFG/projects/proj/$SESS.jsonl"
  else mktx "$CFG/projects/proj/$SESS.jsonl" "usage:$toks"; fi
  RC=0
  OUT="$( cd "$REPO" && env -u MENTOR_CONTEXT_GATE -u MENTOR_CONTEXT_BLOCK_TOKENS -u MENTOR_CONTEXT_WARN_TOKENS \
      CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CODE_SESSION_ID="$SESS" bash "$BEGIN" 2>&1 )" || RC=$?
}
bp 400000
chk "over-ask, no bypass → CONTEXT: ASK printed" contains "CONTEXT: ASK" "$OUT"
chk "over-ask → names bypass script"         contains "bypass-context.sh" "$OUT"
chk "over-ask → no gate marker created"      no_marker
chk "over-ask → not armed"                   sh -c '! printf "%s" "$1" | grep -q "Plan phase ARMED"' _ "$OUT"
: > "$STATE/.context-bypass-$SESS"
bp 400000
chk "bypassed over-ask → armed"              contains "Plan phase ARMED" "$OUT"
chk "bypassed over-ask → CONTEXT: HANDOFF"   contains "CONTEXT: HANDOFF" "$OUT"
chk "bypassed over-ask → gate marker created" has_marker
rm -f "$STATE/.context-bypass-$SESS"
bp 230000
chk "warn → armed + CONTEXT: WARN"           contains "CONTEXT: WARN" "$OUT"
chk "warn → gate marker created"             has_marker
chk "warn → no lean-planning advisory" sh -c '! printf "%s" "$1" | grep -qw "lean"' _ "$OUT"
bp none
chk "no transcript → arms silently (no CONTEXT line)" sh -c '! printf "%s" "$1" | grep -q "CONTEXT:"' _ "$OUT"
chk "no transcript → gate marker created"    has_marker

echo "== I. bypass-context.sh =="
BYPASS="$HOOKS/bypass-context.sh"
[ -f "$BYPASS" ] || { echo "FATAL: not found: $BYPASS" >&2; exit 1; }
rm -f "$STATE"/.context-bypass-*
RC=0; OUT="$( cd "$REPO" && CLAUDE_CODE_SESSION_ID=bysess bash "$BYPASS" 2>&1 )" || RC=$?
chk "bypass → exit 0"                        test "$RC" = "0"
chk "bypass → confirmation printed"          contains "bypassed for this session" "$OUT"
chk "bypass → marker created"                test -e "$STATE/.context-bypass-bysess"
RC=0; OUT="$( cd "$REPO" && CLAUDE_CODE_SESSION_ID=bysess bash "$BYPASS" 2>&1 )" || RC=$?
chk "bypass re-run (idempotent) → exit 0"    test "$RC" = "0"
: > "$STATE/.context-bypass-old"
touch -t "$(date -v-25H +%Y%m%d%H%M 2>/dev/null || date -d '25 hours ago' +%Y%m%d%H%M)" "$STATE/.context-bypass-old" 2>/dev/null || true
RC=0; OUT="$( cd "$REPO" && CLAUDE_CODE_SESSION_ID=bysess2 bash "$BYPASS" 2>&1 )" || RC=$?
chk "25h-old bypass marker pruned"           test ! -e "$STATE/.context-bypass-old"
RC=0; OUT="$( cd "$REPO" && env -u CLAUDE_CODE_SESSION_ID bash "$BYPASS" 2>&1 )" || RC=$?
chk "no session id → exit 0 (nosession)"     test "$RC" = "0"
chk "no session id → nosession marker"       test -e "$STATE/.context-bypass-nosession"
rm -f "$STATE"/.context-bypass-*

echo "== J. Tier independence (v2.34.0 merge) =="
# The merge's one real hazard: tier 1 returning early — kill switch off, unmeasurable
# transcript, or a tier that already fired — must never stop tier 2 from running, and
# each kill switch must reach only its own tier. Under the two separate hooks this was
# structurally guaranteed; here it is a behavior that can regress silently.
NUDGE_HOME="$ROOT/nudge-home"; mkdir -p "$NUDGE_HOME"
# Section H drove begin-plan.sh, which armed a real plan-gate marker in this fixture repo
# — and a live marker legitimately suppresses the nudge ("already planning here"). Clear
# them, or every case below would measure that suppression instead of tier independence.
rm -f "$REPO"/.mentor/plans/.planning*
# run_both <prompt> <session> <transcript> [env=val ...] — both tiers live, isolated $HOME
# so the nudge's once-per-session marker never touches the real machine.
run_both() {
  local prompt="$1" sess="$2" tx="$3"; shift 3
  RC=0
  OUT="$(mkinput "$prompt" "$tx" "$REPO" "$sess" \
    | env -u MENTOR_CONTEXT_GATE -u MENTOR_CONTEXT_WARN_TOKENS -u MENTOR_CONTEXT_BLOCK_TOKENS \
          -u MENTOR_CONTEXT_TAIL_LINES -u MENTOR_PLANNING_INTENT HOME="$NUDGE_HOME" \
          "$@" bash "$HOOK" 2>"$ERRFILE")" || RC=$?
  ERR="$(cat "$ERRFILE")"
}

# 1. Gate silent (under threshold) + nudge matches → the nudge still fires.
rm -rf "$NUDGE_HOME"; mkdir -p "$NUDGE_HOME"
run_both "help me plan the billing rewrite" j1 "$TX_UNDER"
chk "gate silent → nudge still fires"            contains "This looks like a planning request" "$OUT"
chk "gate silent + nudge → exit 0"               test "$RC" = "0"

# 2. Gate KILLED + nudge matches → the nudge is untouched by the gate's kill switch.
rm -rf "$NUDGE_HOME"; mkdir -p "$NUDGE_HOME"
run_both "help me plan the billing rewrite" j2 "$TX_ASK" MENTOR_CONTEXT_GATE=off
chk "MENTOR_CONTEXT_GATE=off → gate silent"      test -z "$(printf '%s' "$OUT" | grep -c 'CONTEXT: ASK' | grep -v '^0$')"
chk "MENTOR_CONTEXT_GATE=off → nudge still runs" contains "This looks like a planning request" "$OUT"

# 3. Nudge KILLED + gate over the ask threshold → the gate is untouched by the nudge's
#    kill switch, and the two verdicts never cross-suppress.
rm -rf "$NUDGE_HOME"; mkdir -p "$NUDGE_HOME"
rm -f "$STATE"/.context-bypass-* "$STATE"/.context-warned-*
run_both "help me plan the billing rewrite" j3 "$TX_ASK" MENTOR_PLANNING_INTENT=off
chk "MENTOR_PLANNING_INTENT=off → gate still asks" contains "CONTEXT: ASK" "$OUT"
chk "MENTOR_PLANNING_INTENT=off → nudge silent"    test "$(printf '%s' "$OUT" | grep -c 'This looks like a planning request')" = "0"

# 4. Both fire on one prompt → both lines land, gate verdict FIRST (hooks.json order).
rm -rf "$NUDGE_HOME"; mkdir -p "$NUDGE_HOME"
rm -f "$STATE"/.context-bypass-* "$STATE"/.context-warned-*
run_both "help me plan the billing rewrite" j4 "$TX_ASK"
chk "both tiers fire → gate line present"        contains "CONTEXT: ASK" "$OUT"
chk "both tiers fire → nudge line present"       contains "This looks like a planning request" "$OUT"
gate_ln="$(printf '%s\n' "$OUT" | grep -n 'CONTEXT: ASK' | head -1 | cut -d: -f1)"
nudge_ln="$(printf '%s\n' "$OUT" | grep -n 'This looks like a planning request' | head -1 | cut -d: -f1)"
chk "both tiers fire → gate verdict precedes the nudge" test "${gate_ln:-999}" -lt "${nudge_ln:-0}"
rm -f "$STATE"/.context-bypass-* "$STATE"/.context-warned-*

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
