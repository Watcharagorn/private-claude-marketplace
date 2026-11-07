#!/usr/bin/env bash
# test-context-gate.sh — regression tests for context-gate.sh (UserPromptSubmit) and
# begin-plan.sh's plan-start context check (v4.2.0: warn-only — no tier blocks, asks a
# question, or suggests a handoff; the top tier is a CONTEXT: HIGH notice).
#
# Builds a real git repo (project-scoped .mentor/ state) and a set of transcript
# fixtures, then drives the hook with UserPromptSubmit JSON across the full tier
# matrix: passthroughs, kill switch, threshold precedence, once-per-session warn,
# the HIGH tier, synthetic-prompt detection, transcript extraction edge cases, and
# fail-soft robustness.
#
# Since v4.3.0 the thresholds come from mentor_context_limits: section K drives that
# helper directly (window precedence, ratio parsing, the clamp, and no window → the
# pre-v4.3.0 numbers) and section L drives the hook with a known window.
#
# Since v2.34.0 this hook also carries the planning-intent nudge as tier 2 (see
# test-planning-nudge.sh). Every case here pins MENTOR_PLANNING_INTENT=off so the tiers
# stay separately measurable; section J tests both running at once, and it
# exists because the merge's whole risk is one tier's early return swallowing the other.
# Section M covers the per-prompt plan pointer, independently of both warning tiers.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS="$(dirname "$SCRIPT_DIR")"
HOOK="$HOOKS/context-gate.sh"
BEGIN="$HOOKS/begin-plan.sh"
for f in "$HOOK" "$BEGIN"; do [ -f "$f" ] || { echo "FATAL: not found: $f" >&2; exit 1; }; done
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required to run this suite" >&2; exit 1; }

ROOT="$(cd "$(mktemp -d)" && pwd -P)"
SANDBOX="$ROOT/home"; mkdir -p "$SANDBOX"
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

# Pin the environment: a developer's own MENTOR_CONTEXT_* or a host-reported window must
# not move an assertion, and MENTOR_STATE_HOME points the session-dir window lookup (and
# the nudge marker) at a sandbox instead of the real config dir.
STATE_HOME="$ROOT/state-home"
PIN_ENV=(-u MENTOR_CONTEXT_GATE -u MENTOR_CONTEXT_WARN_TOKENS -u MENTOR_CONTEXT_BLOCK_TOKENS
  -u MENTOR_CONTEXT_WARN_HIGH_TOKENS -u MENTOR_CONTEXT_TAIL_LINES -u MENTOR_CONTEXT_WINDOW
  -u CLAUDE_CODE_AUTO_COMPACT_WINDOW -u MENTOR_CONTEXT_WARN_RATIO -u MENTOR_CONTEXT_HIGH_RATIO
  -u CLAUDE_CONFIG_DIR -u XDG_STATE_HOME -u MENTOR_STATE_HOME)

# run <prompt> <session> <transcript> [env=val ...] → sets RC / OUT / ERR
run() {
  local prompt="$1" sess="$2" tx="$3"; shift 3
  RC=0
  OUT="$(mkinput "$prompt" "$tx" "$REPO" "$sess" \
    | env "${PIN_ENV[@]}" HOME="$SANDBOX" MENTOR_STATE_HOME="$STATE_HOME" MENTOR_PLANNING_INTENT=off "$@" bash "$HOOK" 2>"$ERRFILE")" || RC=$?
  ERR="$(cat "$ERRFILE")"
}
# run_nojq: same, but with a PATH where jq cannot be found. Input is fed from a FILE
# (not a pipe): the hook exits at the `command -v jq` guard before reading stdin, so a
# pipe would hand its producer a BrokenPipe that pipefail then surfaces as the rc.
run_nojq() {
  local prompt="$1" sess="$2" tx="$3"
  mkinput "$prompt" "$tx" "$REPO" "$sess" > "$ROOT/in.json"
  RC=0
  OUT="$(HOME="$SANDBOX" PATH="$NOJQ_DIR" "$BASH_BIN" "$HOOK" < "$ROOT/in.json" 2>"$ERRFILE")" || RC=$?
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
chk "warn → no handoff suggestion"          sh -c '! printf "%s" "$1" | grep -qi "handoff\|mentor:resume"' _ "$OUT"
# Synthetic-prompt detection, proven where it changes the output: at the WARN tier a
# detected synthetic prompt is silent and burns no marker.
#
# SYNTHETIC_SHAPES is the observed wire contract, kept as verbatim first lines so a
# harness wording change is a one-line fixture edit rather than an archaeology dig.
# Every entry MUST assert both silence and the unburned marker — an `exit 0` check
# alone proves nothing here, since the gate never blocks and an UNDETECTED prompt
# also exits 0.
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
  run "$shape" "warnsyn$i" "$TX_WARN"
  chk "synthetic [$label] → exit 0"            test "$RC" = "0"
  chk "synthetic [$label] → silent at warn"    test -z "$OUT"
  chk "synthetic [$label] → no marker burned"  test ! -e "$(marker "warnsyn$i")"
done
# NEGATIVE: a HUMAN prompt that merely quotes a synthetic phrase must still be warned.
# This is what forbids relaxing the anchored patterns into leading-wildcard matches.
run 'why did I see "3 background agents were stopped by the user" in my log?' warnsynneg "$TX_WARN"
chk "human quoting a synthetic phrase → still warns" contains "getting large" "$OUT"
run 'summarize what Another Claude session sent a message: means' warnsynneg2 "$TX_WARN"
chk "human quoting the wrapper mid-sentence → still warns" contains "getting large" "$OUT"

echo "== B2. Warn-high tier (near-limit, re-fires) =="
TX_HIGH="$ROOT/high.jsonl"; mktx "$TX_HIGH" usage:320000   # ≥ 315000 (90% of 350k), < 350000
run "hello" hi1 "$TX_HIGH"
chk "320k → exit 0"                          test "$RC" = "0"
chk "320k → near-limit notice"               contains "nearing the limit" "$OUT"
chk "320k → no handoff suggestion"           sh -c '! printf "%s" "$1" | grep -qi "handoff\|mentor:resume"' _ "$OUT"
run "hello again" hi1 "$TX_HIGH"
chk "same session → re-fires (no marker)"    contains "nearing the limit" "$OUT"
printf '{"context_warn_high_tokens":100000}\n' > "$CONF"
run "hello" hi2 "$TX_UNDER"
chk "config context_warn_high_tokens honored (150k ≥ 100k)" contains "nearing the limit" "$OUT"
rm -f "$CONF"

echo "== C. HIGH tier (top tier — warn-only) =="
# 'bypassPermissions' legitimately appears in begin-plan's ARMED text — match the retired
# context bypass only.
nohandoff() { ! printf '%s' "$1" | grep -qi 'AskUserQuestion\|handoff\|mentor:resume\|bypass-context\|bypass for'; }
run "please do a thing" high1 "$TX_ASK"
chk "365k plain prompt → exit 0"          test "$RC" = "0"
chk "365k → CONTEXT: HIGH warning"        contains "CONTEXT: HIGH" "$OUT"
chk "365k → one line"                     test "$(printf '%s\n' "$OUT" | grep -c .)" = "1"
chk "365k → no question/handoff/bypass"   nohandoff "$OUT"
chk "365k → nothing on stderr"            test -z "$ERR"
run "and again" high1 "$TX_ASK"
chk "same session → re-fires (no marker)" contains "CONTEXT: HIGH" "$OUT"
# A leftover pre-v4.2.0 bypass marker is ignored — the warning is the same.
: > "$STATE/.context-bypass-highbp"
run "do a thing" highbp "$TX_ASK"
chk "legacy bypass marker → same warning" contains "CONTEXT: HIGH" "$OUT"
chk "legacy bypass marker → no bypass text" nohandoff "$OUT"
rm -f "$STATE/.context-bypass-highbp"
# Synthetic prompts are measured too and get the same warning.
run "<task-notification>reviewer finished</task-notification>" highsyn "$TX_ASK"
chk "synthetic at HIGH → exit 0"          test "$RC" = "0"
chk "synthetic at HIGH → warned"          contains "CONTEXT: HIGH" "$OUT"
run "/mentor:plan \"x\"" high2 "$TX_ASK"
chk "slash /mentor:plan passes"           test "$RC" = "0"
chk "slash /mentor:plan → silent"         test -z "$OUT$ERR"
run "/compact" high3 "$TX_ASK"
chk "slash /compact passes"               test "$RC" = "0"
chk "slash /compact → silent"             test -z "$OUT$ERR"
run "" high4 "$TX_ASK"
chk "empty prompt passes"                 test "$RC" = "0"
chk "empty prompt → silent"               test -z "$OUT$ERR"
[ -e "$HOOKS/bypass-context.sh" ] && FAILBP=1 || FAILBP=0
chk "bypass-context.sh retired"           test "$FAILBP" = "0"

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
chk "env lowers ask threshold → CONTEXT: HIGH" contains "CONTEXT: HIGH" "$OUT"
chk "env lowers → still exit 0"            test "$RC" = "0"
printf '{"context_block_tokens":1000}\n' > "$CONF"
run "do thing" p2 "$TX_UNDER"
chk "config lowers → CONTEXT: HIGH"        contains "CONTEXT: HIGH" "$OUT"
printf '{"context_block_tokens":999999999}\n' > "$CONF"
run "do thing" p3 "$TX_UNDER" MENTOR_CONTEXT_BLOCK_TOKENS=1000
chk "env beats config → CONTEXT: HIGH"     contains "CONTEXT: HIGH" "$OUT"
rm -f "$CONF"
run "do thing" p4 "$TX_UNDER" MENTOR_CONTEXT_BLOCK_TOKENS=abc
chk "non-numeric env → default (150k<350k, no HIGH)" test "$RC" = "0"
chk "non-numeric env → silent"             test -z "$OUT$ERR"

echo "== F. Transcript extraction edge cases (HIGH-level unless noted) =="
mktx "$ROOT/sm.jsonl" sidechain_mask:365000
run "do thing" f1 "$ROOT/sm.jsonl"
chk "trailing sidechain doesn't mask 365k → HIGH" contains "CONTEXT: HIGH" "$OUT"
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
chk "usage after compact → HIGH"               contains "CONTEXT: HIGH" "$OUT"
mktx "$ROOT/gb.jsonl" garbage:365000
run "do thing" f5 "$ROOT/gb.jsonl"
chk "garbage lines interleaved → HIGH"         contains "CONTEXT: HIGH" "$OUT"
mktx "$ROOT/ul.jsonl" usageless:365000
run "do thing" f6 "$ROOT/ul.jsonl"
chk "usage-less assistant skipped → HIGH"      contains "CONTEXT: HIGH" "$OUT"
mktx "$ROOT/syn.jsonl" synthetic_trailing:365000
run "do thing" f7 "$ROOT/syn.jsonl"
chk "trailing <synthetic> all-zero after 365k → HIGH" contains "CONTEXT: HIGH" "$OUT"

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
  OUT="$( cd "$REPO" && env "${PIN_ENV[@]}" HOME="$SANDBOX" MENTOR_STATE_HOME="$STATE_HOME" \
      CLAUDE_CONFIG_DIR="$CFG" CLAUDE_CODE_SESSION_ID="$SESS" bash "$BEGIN" 2>&1 )" || RC=$?
}
bp 400000
chk "over-ask → armed (never refuses)"       contains "Plan phase ARMED" "$OUT"
chk "over-ask → gate marker created"         has_marker
chk "over-ask → CONTEXT: HIGH printed"       contains "CONTEXT: HIGH" "$OUT"
chk "over-ask → lean-planning advisory"      sh -c 'printf "%s" "$1" | grep -qw "lean"' _ "$OUT"
chk "over-ask → no question/handoff/bypass"  nohandoff "$OUT"
bp 230000
chk "warn → armed + CONTEXT: WARN"           contains "CONTEXT: WARN" "$OUT"
chk "warn → gate marker created"             has_marker
chk "warn → no lean-planning advisory" sh -c '! printf "%s" "$1" | grep -qw "lean"' _ "$OUT"
chk "warn → no handoff suggestion"           nohandoff "$OUT"
bp none
chk "no transcript → arms silently (no CONTEXT line)" sh -c '! printf "%s" "$1" | grep -q "CONTEXT:"' _ "$OUT"
chk "no transcript → gate marker created"    has_marker

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
    | env "${PIN_ENV[@]}" -u MENTOR_PLANNING_INTENT HOME="$NUDGE_HOME" \
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
chk "MENTOR_CONTEXT_GATE=off → gate silent"      test -z "$(printf '%s' "$OUT" | grep -c 'CONTEXT: HIGH' | grep -v '^0$')"
chk "MENTOR_CONTEXT_GATE=off → nudge still runs" contains "This looks like a planning request" "$OUT"

# 3. Nudge KILLED + gate over the ask threshold → the gate is untouched by the nudge's
#    kill switch, and the two verdicts never cross-suppress.
rm -rf "$NUDGE_HOME"; mkdir -p "$NUDGE_HOME"
rm -f "$STATE"/.context-warned-*
run_both "help me plan the billing rewrite" j3 "$TX_ASK" MENTOR_PLANNING_INTENT=off
chk "MENTOR_PLANNING_INTENT=off → gate still warns" contains "CONTEXT: HIGH" "$OUT"
chk "MENTOR_PLANNING_INTENT=off → nudge silent"    test "$(printf '%s' "$OUT" | grep -c 'This looks like a planning request')" = "0"

# 4. Both fire on one prompt → both lines land, gate verdict FIRST (hooks.json order).
rm -rf "$NUDGE_HOME"; mkdir -p "$NUDGE_HOME"
rm -f "$STATE"/.context-warned-*
run_both "help me plan the billing rewrite" j4 "$TX_ASK"
chk "both tiers fire → gate line present"        contains "CONTEXT: HIGH" "$OUT"
chk "both tiers fire → nudge line present"       contains "This looks like a planning request" "$OUT"
gate_ln="$(printf '%s\n' "$OUT" | grep -n 'CONTEXT: HIGH' | head -1 | cut -d: -f1)"
nudge_ln="$(printf '%s\n' "$OUT" | grep -n 'This looks like a planning request' | head -1 | cut -d: -f1)"
chk "both tiers fire → gate verdict precedes the nudge" test "${gate_ln:-999}" -lt "${nudge_ln:-0}"
rm -f "$STATE"/.context-warned-*

# 5. The nudge's once-per-session marker follows CLAUDE_CONFIG_DIR (v4.3.0). It was
#    hardcoded to ~/.claude, so a second Claude profile wrote into the default one.
rm -rf "$NUDGE_HOME"; mkdir -p "$NUDGE_HOME"
run_both "help me plan the billing rewrite" j5 "$TX_UNDER" CLAUDE_CONFIG_DIR="$ROOT/alt-cfg"
chk "nudge marker lands under CLAUDE_CONFIG_DIR"  test -e "$ROOT/alt-cfg/mentor/_prompt-nudges/.planning-intent-j5"
chk "nudge marker not under \$HOME/.claude"        test ! -e "$NUDGE_HOME/.claude/mentor/_prompt-nudges/.planning-intent-j5"

echo "== K. mentor_context_limits (v4.3.0: window ratio, caps, clamp; the window is never guessed) =="
LIB="$HOOKS/lib/state.sh"
# lim [env=val ...] → "warn warn_high high rearm window" for $REPO and session $LIM_SID.
LIM_SID="limsess"
lim() { env "${PIN_ENV[@]}" MENTOR_STATE_HOME="$STATE_HOME" "$@" \
  bash -c 'set -euo pipefail; . "$1"; mentor_context_limits "$2" "$3"' _ "$LIB" "$REPO" "$LIM_SID"; }
w()  { lim "$@" | awk '{print $5}'; }
wa() { lim MENTOR_CONTEXT_WINDOW=200000 "$@" | awk '{print $1}'; }
TODAY="200000 315000 350000 50000 0"
rm -f "$CONF"
chk "no window source → today's thresholds ($TODAY)"   test "$(lim)" = "$TODAY"
chk "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE is a percent, never a window" \
  test "$(lim CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=70)" = "$TODAY"
chk "a model name is never read as a window"           test "$(lim ANTHROPIC_MODEL='claude-opus-5-5[1m]')" = "$TODAY"
# Window precedence: MENTOR_CONTEXT_WINDOW > config > CLAUDE_CODE_AUTO_COMPACT_WINDOW > session file.
SDIR="$STATE_HOME/sessions/$LIM_SID"; mkdir -p "$SDIR"
echo 180000 > "$SDIR/context-window"
chk "session context-window file alone → 180000"       test "$(w)" = "180000"
chk "CLAUDE_CODE_AUTO_COMPACT_WINDOW beats the file"   test "$(w CLAUDE_CODE_AUTO_COMPACT_WINDOW=300000)" = "300000"
printf '{"context_window_tokens":400000}\n' > "$CONF"
chk "config context_window_tokens beats CLAUDE_CODE_AUTO_COMPACT_WINDOW" \
  test "$(w CLAUDE_CODE_AUTO_COMPACT_WINDOW=300000)" = "400000"
chk "MENTOR_CONTEXT_WINDOW beats config"               test "$(w MENTOR_CONTEXT_WINDOW=200000 CLAUDE_CODE_AUTO_COMPACT_WINDOW=300000)" = "200000"
chk "non-numeric env window falls through to config"   test "$(w MENTOR_CONTEXT_WINDOW=200k)" = "400000"
chk "zero env window falls through to config"          test "$(w MENTOR_CONTEXT_WINDOW=0)" = "400000"
rm -f "$CONF"
echo garbage > "$SDIR/context-window"
chk "non-numeric session file → unknown → today's"     test "$(lim)" = "$TODAY"
rm -f "$SDIR/context-window"
# A session id that would climb out of sessions/ is never used as a path.
mkdir -p "$STATE_HOME/escape"; echo 200000 > "$STATE_HOME/escape/context-window"
chk "path-traversal session id → file not read"       test "$(LIM_SID='../escape' lim)" = "$TODAY"
rm -rf "$STATE_HOME/escape"
chk "leading zeros read as decimal, not octal"        test "$(w MENTOR_CONTEXT_WINDOW=0200000)" = "200000"
# warn = min(warn_ratio × window, warn cap); high = min(high_ratio × window, high cap).
chk "200k window → 100000 / 117000 / 130000, re-arm 20000" \
  test "$(lim MENTOR_CONTEXT_WINDOW=200000)" = "100000 117000 130000 20000 200000"
chk "1M window → the caps win (200000 / 315000 / 350000)" \
  test "$(lim MENTOR_CONTEXT_WINDOW=1000000)" = "200000 315000 350000 100000 1000000"
chk "a lowered cap still caps a known window" \
  test "$(lim MENTOR_CONTEXT_WINDOW=1000000 MENTOR_CONTEXT_WARN_TOKENS=150000 | awk '{print $1}')" = "150000"
# Ratio precedence (env > config > default) and decimal parsing.
printf '{"context_warn_ratio":0.4}\n' > "$CONF"
chk "config ratio (JSON number 0.4) → warn 80000"      test "$(wa)" = "80000"
chk "env ratio beats config → warn 60000"              test "$(wa MENTOR_CONTEXT_WARN_RATIO=0.3)" = "60000"
chk "malformed env ratio falls through to config"      test "$(wa MENTOR_CONTEXT_WARN_RATIO=abc)" = "80000"
rm -f "$CONF"
chk "leading-dot decimal .45 accepted → 90000"         test "$(wa MENTOR_CONTEXT_WARN_RATIO=.45)" = "90000"
chk "comma decimal 0,4 rejected → default 0.5"         test "$(wa MENTOR_CONTEXT_WARN_RATIO=0,4)" = "100000"
chk "ratio above 1 rejected → default"                 test "$(wa MENTOR_CONTEXT_WARN_RATIO=1.5)" = "100000"
chk "ratio 0 rejected → default"                       test "$(wa MENTOR_CONTEXT_WARN_RATIO=0)" = "100000"
chk "negative ratio rejected → default"                test "$(wa MENTOR_CONTEXT_WARN_RATIO=-0.4)" = "100000"
chk "comma-decimal locale still parses 0.4"            test "$(wa MENTOR_CONTEXT_WARN_RATIO=0.4 LC_ALL=de_DE.UTF-8)" = "80000"
chk "high ratio env honored → high 120000" \
  test "$(lim MENTOR_CONTEXT_WINDOW=200000 MENTOR_CONTEXT_HIGH_RATIO=0.6 | awk '{print $3}')" = "120000"
chk "ratios alone, no window → today's"                test "$(lim MENTOR_CONTEXT_WARN_RATIO=0.1 MENTOR_CONTEXT_HIGH_RATIO=0.2)" = "$TODAY"
# The clamp keeps warn ≤ warn_high ≤ high and only ever lowers a value.
chk "inverted ratios (0.8 / 0.6) → clamped 108000 108000 120000" \
  test "$(lim MENTOR_CONTEXT_WINDOW=200000 MENTOR_CONTEXT_WARN_RATIO=0.8 MENTOR_CONTEXT_HIGH_RATIO=0.6)" = "108000 108000 120000 20000 200000"
chk "warn_high above the limit → clamped to the limit" test "$(lim MENTOR_CONTEXT_WARN_HIGH_TOKENS=500000)" = "200000 350000 350000 50000 0"
chk "limit under the warn cap → warn pulled down"      test "$(lim MENTOR_CONTEXT_BLOCK_TOKENS=1000)" = "900 900 1000 225 0"
chk "warn_high set low is kept, warn follows it down"  test "$(lim MENTOR_CONTEXT_WARN_HIGH_TOKENS=100000)" = "100000 100000 350000 25000 0"

echo "== L. The gate with a known window (percent text, progress-first line) =="
TX_95="$ROOT/w95.jsonl";   mktx "$TX_95"  usage:95000
TX_105="$ROOT/w105.jsonl"; mktx "$TX_105" usage:105000
TX_125="$ROOT/w125.jsonl"; mktx "$TX_125" usage:125000
TX_135="$ROOT/w135.jsonl"; mktx "$TX_135" usage:135000
PROGRESS_LINE="Before compacting, record your progress in the plan: finished steps, what's in flight, findings, the exact next action. The summary is lossy; the plan is not."
run "hello" win1 "$TX_95" MENTOR_CONTEXT_WINDOW=200000
chk "200k window, 95k → silent (under 50%)"            test -z "$OUT$ERR"
run "hello" win1 "$TX_105" MENTOR_CONTEXT_WINDOW=200000
chk "200k window, 105k → first warning (~100k)"        contains "getting large" "$OUT"
chk "200k window, 105k → ~N tokens (r% of window)"     contains "~105000 tokens (52% of window)" "$OUT"
chk "200k window, 105k → progress-first line"          contains "$PROGRESS_LINE" "$OUT"
run "hello" win2 "$TX_125" MENTOR_CONTEXT_WINDOW=200000
chk "200k window, 125k → near-limit (≥ 117000)"        contains "nearing the limit" "$OUT"
chk "200k window, 125k → % of window"                  contains "(62% of window)" "$OUT"
run "hello" win3 "$TX_135" MENTOR_CONTEXT_WINDOW=200000
chk "200k window, 135k → CONTEXT: HIGH (≥ 130000)"     contains "CONTEXT: HIGH" "$OUT"
chk "200k window, 135k → still one line"               test "$(printf '%s\n' "$OUT" | grep -c .)" = "1"
chk "200k window, 135k → progress-first line"          contains "$PROGRESS_LINE" "$OUT"
# Re-arm with a known window is 10% of it: +55k at a 1M window stays quiet.
run "hello" win1m "$TX_WARN" MENTOR_CONTEXT_WINDOW=1000000
chk "1M window, 215k → warns at the 200k cap"          contains "getting large" "$OUT"
run "hello" win1m "$TX_WARN_BIG_GROW" MENTOR_CONTEXT_WINDOW=1000000
chk "1M window, +55k → silent (re-arm 100000)"         test -z "$OUT"
# The session dir's context-window file, keyed by the hook's own session_id.
mkdir -p "$STATE_HOME/sessions/winfile"; echo 200000 > "$STATE_HOME/sessions/winfile/context-window"
run "hello" winfile "$TX_105"
chk "session context-window file → warns at 105k"      contains "(52% of window)" "$OUT"
rm -rf "$STATE_HOME/sessions/winfile"
# No window: today's thresholds, no percent, the progress-first line on every tier.
run "hello" nowin1 "$TX_105"
chk "no window, 105k → silent (today's 200k warn)"     test -z "$OUT$ERR"
run "hello" nowin2 "$TX_WARN"
chk "no window, WARN → no percent text"                sh -c '! printf "%s" "$1" | grep -q "% of window"' _ "$OUT"
chk "no window, WARN → progress-first line"            contains "$PROGRESS_LINE" "$OUT"
run "hello" nowin3 "$TX_HIGH"
chk "no window, WARN-HIGH → progress-first line"       contains "$PROGRESS_LINE" "$OUT"
run "hello" nowin4 "$TX_ASK"
chk "no window, HIGH → progress-first line"            contains "$PROGRESS_LINE" "$OUT"

echo "== M. Live plan pointer on every prompt =="
. "$LIB"
PLANS="$STATE/plans"
WT_ID="$(mentor_worktree_id "$REPO")"
GATE="$(mentor_plan_marker "$PLANS" "$WT_ID")"
CHANGE_NOTE="plan.md changed since mentor last wrote it — read it before editing it further"
NO_PLAN_HINT="mentor plan: no plan file yet · it is created at research start (planning Step 2)"
mkdir -p "$PLANS"
# Every fixture records stored state explicitly; tests must never infer lifecycle
# state from ticks or accidentally depend on real session/config directories.
pointer_plan() { # <slug> <stored-state> <owner> <body>
  local slug="$1" stored="$2" owner="$3" body="$4"
  mkdir -p "$PLANS/$slug"
  printf '%s\n' "$body" > "$PLANS/$slug/plan.md"
  jq -n --arg state "$stored" --arg owner "$owner" \
    '{state:$state,owner:$owner}' > "$PLANS/$slug/.state.json"
}
pointer_lines() { printf '%s\n' "$1" | grep -c '^mentor plan:'; }
line_count() { printf '%s\n' "$1" | grep -c .; }
pointer_baseline() {
  local plan_dir="$PLANS/$1" digest
  digest="$(mentor_plan_sha256 "$plan_dir/plan.md")"
  jq --arg hash "$digest" '. + {plan_sha256:$hash}' "$plan_dir/.state.json" > "$ROOT/sidecar.tmp"
  mv "$ROOT/sidecar.tmp" "$plan_dir/.state.json"
}
live_gate() {
  : > "$1"
  python3 - "$1" <<'PY'
import os, sys, time
stamp = time.time() - 60
os.utime(sys.argv[1], (stamp, stamp))
PY
}
after_gate() { # <file> [seconds after the own gate]
  python3 - "$1" "$GATE" "${2:-10}" <<'PY'
import os, sys
stamp = os.stat(sys.argv[2]).st_mtime + int(sys.argv[3])
os.utime(sys.argv[1], (stamp, stamp))
PY
}
rm -f "$PLANS"/.planning* "$STATE"/.run-*

pointer_plan quiet-run in_progress '' $'# Plan\n## Implementation steps\n1. Work'
run "hello" pointer-none "$TX_UNDER"
chk "unowned run without gate or marker → no pointer" test -z "$OUT$ERR"
printf 'slug=quiet-run\n' > "$STATE/.run-other-session"
run "hello" pointer-none "$TX_UNDER"
chk "different session run marker → no pointer" test -z "$OUT$ERR"
rm -f "$STATE/.run-other-session"

live_gate "$GATE"
run "hello" pointer-empty "$TX_UNDER"
chk "armed gate with no owned draft → research-start location hint" test "$OUT" = "$NO_PLAN_HINT"
pointer_plan sibling-draft draft sibling-worktree $'# Sibling\n## Research notes\nFinding'
run "hello" pointer-empty "$TX_UNDER"
chk "sibling-owned draft → research-start location hint" test "$OUT" = "$NO_PLAN_HINT"
pointer_plan older-draft draft "$WT_ID" $'# Old draft\n## Research notes\nOld finding'
touch -t 202001010000 "$PLANS/older-draft/plan.md"
pointer_plan active-draft draft "$WT_ID" $'# Draft\n## Research notes\nFinding'
pointer_baseline active-draft
pointer_plan completed implemented "$WT_ID" $'# Completed\n## Implementation steps\n1. Shipped ✅'
after_gate "$PLANS/active-draft/plan.md"
# Other candidates are newer: only a current owned draft qualifies.
run "hello" pointer-draft "$TX_UNDER"
DRAFT_POINTER="mentor plan: active-draft · .mentor/plans/active-draft/plan.md · draft · next: drafting"
chk "armed draft → slug, path, stored state, next: drafting" test "$OUT" = "$DRAFT_POINTER"
chk "known draft → no change note" test -z "$(printf '%s\n' "$OUT" | grep -F "$CHANGE_NOTE")"
run "hello again" pointer-draft "$TX_UNDER"
chk "armed draft → pointer repeats each prompt" test "$OUT" = "$DRAFT_POINTER"
run "/compact" pointer-draft "$TX_ASK"
chk "slash command → pointer without context warning" test "$OUT" = "$DRAFT_POINTER"
run "" pointer-draft "$TX_ASK"
chk "empty prompt → pointer without context warning" test "$OUT" = "$DRAFT_POINTER"
run "hello" pointer-draft "$TX_NONE"
chk "unmeasurable context → pointer still prints" test "$OUT" = "$DRAFT_POINTER"
run "hello" pointer-draft "$TX_ASK" MENTOR_CONTEXT_GATE=off
chk "context gate off → pointer still prints" test "$OUT" = "$DRAFT_POINTER"
printf '\n## Implementation steps\n1. Await approval\n2. Later work\n' >> "$PLANS/active-draft/plan.md"
pointer_baseline active-draft
run "hello" pointer-draft "$TX_UNDER"
chk "step-bearing draft → next: drafting before approval" test "$OUT" = "$DRAFT_POINTER"
printf '\nOutside edit\n' >> "$PLANS/active-draft/plan.md"
run "hello" pointer-draft "$TX_UNDER"
chk "changed plan → exact change note on pointer" test "$OUT" = "$DRAFT_POINTER · $CHANGE_NOTE"
chk "changed plan → one pointer line" test "$(line_count "$OUT")" = 1
pointer_baseline active-draft
run "hello" pointer-draft "$TX_UNDER"
chk "tracked write → change note cleared" test "$OUT" = "$DRAFT_POINTER"
rm -f "$GATE"

RUN_BODY=$'# Run\n## Implementation steps\n1. First ✅\n2. Second\n3. Third ✅\n## Goal check\nPredicate'
pointer_plan active-run in_progress "$WT_ID" "$RUN_BODY"
pointer_baseline active-run
printf 'slug=active-run\n' > "$STATE/.run-pointer-run"
RUN_POINTER="mentor plan: active-run · .mentor/plans/active-run/plan.md · in_progress · next: step 2/3"
run "continue" pointer-run "$TX_UNDER"
chk "session run → first unticked step N/M" test "$OUT" = "$RUN_POINTER"
chk "session run → exit 0, silent stderr" test "$RC:$ERR" = "0:"
run "continue again" pointer-run "$TX_UNDER"
chk "session run → pointer repeats each prompt" test "$OUT" = "$RUN_POINTER"
jq '.state="approved"' "$PLANS/active-run/.state.json" > "$ROOT/sidecar.tmp"
mv "$ROOT/sidecar.tmp" "$PLANS/active-run/.state.json"
run "continue" pointer-run "$TX_UNDER"
chk "approved session plan → first unticked step N/M" \
  test "$OUT" = "mentor plan: active-run · .mentor/plans/active-run/plan.md · approved · next: step 2/3"
jq '.state="in_progress"' "$PLANS/active-run/.state.json" > "$ROOT/sidecar.tmp"
mv "$ROOT/sidecar.tmp" "$PLANS/active-run/.state.json"

# Every warning retains its original line and adds exactly one pointer line.
for spec in "warn:$TX_WARN:getting large" "warn-high:$TX_HIGH:nearing the limit" "high:$TX_ASK:CONTEXT: HIGH"; do
  tier="${spec%%:*}"; rest="${spec#*:}"
  tx="${rest%%:*}"; warning="${rest#*:}"
  printf 'slug=active-run\n' > "$STATE/.run-pointer-$tier"
  run "continue" "pointer-$tier" "$tx"
  chk "$tier + run → warning retained" contains "$warning" "$OUT"
  chk "$tier + run → pointer retained" contains "$RUN_POINTER" "$OUT"
  chk "$tier + run → one extra line" test "$(line_count "$OUT")" = 2
  chk "$tier + run → exactly one pointer" test "$(pointer_lines "$OUT")" = 1
  chk "$tier + run → warning precedes pointer" contains "$warning" "${OUT%%$'\n'*}"
  chk "$tier + run → exit 0, silent stderr" test "$RC:$ERR" = "0:"
  rm -f "$STATE/.run-pointer-$tier"
done
run "continue" pointer-warn "$TX_WARN"
chk "WARN dedup with no live marker → owned recovery pointer" test "$OUT" = "$RUN_POINTER"
printf 'slug=active-run\n' > "$STATE/.run-pointer-warn"
run "continue" pointer-warn "$TX_WARN"
chk "WARN already consumed → pointer still prints" test "$OUT" = "$RUN_POINTER"
rm -f "$STATE/.run-pointer-warn"

printf '%s\n' "$RUN_BODY" | sed 's/2\. Second/2. Second ✅/' > "$PLANS/active-run/plan.md"
pointer_baseline active-run
run "continue" pointer-run "$TX_UNDER"
chk "all steps ticked → stored in_progress and next: goal check" \
  test "$OUT" = "mentor plan: active-run · .mentor/plans/active-run/plan.md · in_progress · next: goal check"
jq '.state="approved"' "$PLANS/active-run/.state.json" > "$ROOT/sidecar.tmp"
mv "$ROOT/sidecar.tmp" "$PLANS/active-run/.state.json"
run "continue" pointer-run "$TX_UNDER"
chk "all steps ticked → approved session plan still points to goal check" \
  test "$OUT" = "mentor plan: active-run · .mentor/plans/active-run/plan.md · approved · next: goal check"
jq '.state="in_progress"' "$PLANS/active-run/.state.json" > "$ROOT/sidecar.tmp"
mv "$ROOT/sidecar.tmp" "$PLANS/active-run/.state.json"
printf '\nOutside run edit\n' >> "$PLANS/active-run/plan.md"
run "continue" pointer-run "$TX_UNDER"
chk "changed run → change note" contains "next: goal check · $CHANGE_NOTE" "$OUT"
printf '{"state":"in_progress","owner":"%s"}\n' "$WT_ID" > "$PLANS/active-run/.state.json"
run "continue" pointer-run "$TX_UNDER"
chk "legacy sidecar → unknown drift stays quiet" \
  test "$OUT" = "mentor plan: active-run · .mentor/plans/active-run/plan.md · in_progress · next: goal check"
printf '{broken json\n' > "$PLANS/active-run/.state.json"
run "continue" pointer-run "$TX_UNDER"
chk "corrupt sidecar → unknown stored state, never fails prompt" test "$RC:$ERR" = "0:"
chk "corrupt sidecar → ticks never imply implemented" contains " · unknown · next: goal check" "$OUT"
rm -f "$PLANS/active-run/plan.md"
run "continue" pointer-run "$TX_UNDER"
chk "run plan file missing → names the unavailable plan, exit 0" \
  test "$RC:$OUT$ERR" = "0:mentor plan: active-run · .mentor/plans/active-run/plan.md · unknown · next: unavailable (plan.md missing)"
printf 'slug=../outside\n' > "$STATE/.run-pointer-run"
run "continue" pointer-run "$TX_UNDER"
chk "invalid run slug → silent, exit 0" test "$RC:$OUT$ERR" = "0:"
rm -f "$STATE/.run-pointer-run"
: > "$PLANS/.planning.sibling-worktree"
run "hello" pointer-sibling "$TX_UNDER"
chk "sibling armed gate → no pointer" test -z "$OUT$ERR"
rm -f "$PLANS/.planning.sibling-worktree"
: > "$GATE"
touch -t 202001010000 "$GATE"
run "hello" pointer-stale "$TX_UNDER"
chk "stale armed gate → no pointer" test -z "$OUT$ERR"
rm -f "$GATE"

echo "== N. Armed-draft freshness and reattachment parity =="
reset_selection() {
  rm -rf "$PLANS"
  rm -f "$STATE"/.run-*
  mkdir -p "$PLANS"
  live_gate "$GATE"
}
selection() { # <case> <expected-slug-or-empty> [stored-state=draft]
  local label="$1" slug="$2" stored="${3:-draft}" attached context expected
  run "hello" selection "$TX_UNDER"
  if [ -n "$slug" ]; then
    chk "$label → prompt selects $slug" contains "mentor plan: $slug · .mentor/plans/$slug/plan.md · $stored · next:" "$OUT"
    expected="path: .mentor/plans/$slug/plan.md"
  else
    chk "$label → prompt gives only the research-start hint" test "$OUT" = "$NO_PLAN_HINT"
    expected="path: .mentor/plans/ (no plan.md yet)"
  fi
  attached="$(jq -nc --arg cwd "$REPO" '{cwd:$cwd,session_id:"selection",source:"compact"}' \
    | env "${PIN_ENV[@]}" HOME="$SANDBOX" bash "$HOOKS/plan-reattach.sh")"
  context="$(printf '%s' "$attached" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
  chk "$label → SessionStart agrees with the prompt selector" contains "$expected" "$context"
}
reset_selection
pointer_plan old-only draft "$WT_ID" '# Old draft'
after_gate "$PLANS/old-only/plan.md" -10
selection 'old-only draft' ''
after_gate "$PLANS/old-only/.state.json" 30
selection 'fresh sidecar cannot refresh an existing old plan' ''
touch -r "$GATE" "$PLANS/old-only/plan.md"
selection 'plan timestamp equal to gate' ''

reset_selection
pointer_plan current draft "$WT_ID" '# Current draft'
after_gate "$PLANS/current/plan.md" 10
for stored in implemented failed superseded approved in_progress; do
  pointer_plan terminal "$stored" "$WT_ID" $'# Terminal\n## Implementation steps\n1. Done ✅'
  after_gate "$PLANS/terminal/plan.md" 40
  selection "newer $stored plan cannot steal draft" current
done
rm -rf "$PLANS/current"
selection 'armed gate without a current draft recovers owned in_progress' terminal in_progress

reset_selection
pointer_plan foreign draft other-worktree '# Foreign draft'
pointer_plan unowned draft '' '# Unowned draft'
after_gate "$PLANS/foreign/plan.md" 20
after_gate "$PLANS/unowned/plan.md" 30
selection 'foreign and unowned drafts' ''
pointer_plan first draft "$WT_ID" '# First current draft'
pointer_plan second draft "$WT_ID" '# Second current draft'
after_gate "$PLANS/first/plan.md" 10
after_gate "$PLANS/second/plan.md" 20
after_gate "$PLANS/first/.state.json" 40
selection 'multiple current drafts use plan mtime' second
before="$(cksum "$GATE" "$PLANS"/*/plan.md "$PLANS"/*/.state.json)"
selection 'selector is read-only' second
chk 'armed selectors preserve gates, plans and sidecars' test "$before" = "$(cksum "$GATE" "$PLANS"/*/plan.md "$PLANS"/*/.state.json)"

reset_selection
pointer_plan between draft "$WT_ID" '# Between gates'
after_gate "$PLANS/between/plan.md" -10
: > "$PLANS/.planning"
after_gate "$PLANS/.planning" -20
selection 'live own gate takes precedence over older legacy gate' ''
after_gate "$PLANS/between/plan.md" 10
after_gate "$PLANS/.planning" 20
selection 'live own gate takes precedence over newer legacy gate' between
touch -t 202001010000 "$GATE"
selection 'stale own gate falls back to live legacy freshness' ''
touch -r "$PLANS/.planning" "$PLANS/between/plan.md"
printf '\nFresh research\n' >> "$PLANS/between/plan.md"
selection 'live legacy gate selects a fresh draft' between
touch -t 202001010000 "$PLANS/.planning"
run 'hello' selection "$TX_UNDER"
chk 'both gates stale → prompt is silent' test -z "$OUT$ERR"

reset_selection
pointer_plan missing draft "$WT_ID" '# Missing draft'
rm "$PLANS/missing/plan.md"
after_gate "$PLANS/missing/.state.json" -10
selection 'stale missing-draft sidecar' ''
touch -r "$GATE" "$PLANS/missing/.state.json"
selection 'missing sidecar equal to gate' ''
after_gate "$PLANS/missing/.state.json" 10
selection 'fresh missing-draft sidecar' missing
chk 'missing armed draft gives no invented next step' contains 'next: unavailable (plan.md missing)' "$OUT"

reset_selection
rm "$GATE"
live_gate "$PLANS/.planning"
pointer_plan fallback draft '' '# Empty worktree id fallback'
chk 'empty worktree id keeps legacy/unowned selector fallback' \
  test "$(mentor_armed_draft "$PLANS" '')" = "$PLANS/fallback/plan.md"

echo '== N2. armed fresh draft B wins over kept run marker A =='
reset_selection
pointer_plan plan-a in_progress "$WT_ID" $'# Run A\n## Implementation steps\n1. Continue run A'
pointer_plan plan-b draft "$WT_ID" '# Fresh research B'
after_gate "$PLANS/plan-a/plan.md" 20
after_gate "$PLANS/plan-b/plan.md" 10
printf 'slug=plan-a\nstarted=kept\n' > "$STATE/.run-selection"
before="$(cksum "$GATE" "$STATE/.run-selection" "$PLANS"/*/plan.md "$PLANS"/*/.state.json)"
selection 'kept run A + armed fresh draft B' plan-b
chk 'draft B wins without modifying the kept marker or either plan' \
  test "$(cksum "$GATE" "$STATE/.run-selection" "$PLANS"/*/plan.md "$PLANS"/*/.state.json)" = "$before"
rm -rf "$PLANS/plan-b"
selection 'no armed draft falls back to exact-session run A' plan-a in_progress
rm "$STATE/.run-selection"
selection 'no draft or marker falls back to owned recovery A' plan-a in_progress

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ]
