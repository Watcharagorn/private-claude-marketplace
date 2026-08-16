---
name: resuming
description: >
  Browse/continue mentor handoff notes; drain fix children parked under a NAMED root or remaining siblings of a NAMED split group. Invoked via /mentor:resume. With no argument: lists live handoff notes (newest first), roots with open descendants, split groups with unbuilt siblings. An argument (slug, number, plan-topic name, root slug, or split-group name) resolves a note, a named root to drain leaf-first (nested fix first), or a named split group to drain its siblings in order (fix subtree first) — never auto-picked on ambiguous match. Each drained item re-enters /mentor:plan's arm/claim/approve cycle; consent per item, re-surveyed after each. A note resolves (moved to resolved/) only when its work completes AND its topic has no open descendants, or a newer /mentor:handoff supersedes it. Consume side of /mentor:handoff; repo-scoped to .mentor/; scans notes for secrets. Not a generic/unnamed "what's next" survey or building the next unbuilt plan (/mentor:track) — needs a named note, root, or split group.
---

# Resume — Continue a Handoff Note, a Parked Fix, or a Split Group

This skill is the **consume** side of `/mentor:handoff`, and the **continuation** side of a fix
parked mid-flow (`mentor:deferring`'s parent-aware capture) or a plan-split left half-built
(`mentor:plan-split`). `/mentor:handoff` compacts a session into a self-contained handoff document
saved inside its plan-topic folder — the repo's gitignored `.mentor/plans/<topic>/handoffs/` dir;
`/mentor:resume` lists those documents **for this repo only**, lets the user pick one, and continues
the work from it in a fresh session. Alongside notes, it also lists — and can drain — roots whose
fix children never got their own note (Step 2), continuing them through the same plan → approve →
build cycle the writer of a note would have gone through by hand (the "Draining Parked Fixes and
Split Groups" section below).

A note stays **live** (listed) until its work is actually finished: it is stamped **resolved** (moved
into a `resolved/` subdir, never re-listed) only when all its tasks are done per the plan file AND
its topic has no open descendants left (Step 5's final rule), or when a nested `/mentor:handoff`
supersedes it with a fresher note. Loading a note does NOT resolve it — a session that reads a note
and stalls leaves the work resumable.

It reads notes and stamps the consumed one only on completion; it never authors them. It is strictly
**repo-scoped** — the notes and plans live under this repo's `.mentor/` tree (the same place
`/mentor:handoff` and `/mentor:plan` write), so notes and plans from other repositories cannot
appear here.

## When to use

- Starting a fresh session and you want to pick up where a prior session (or another agent) left off.
- You have one or more handoff notes for this repo and want to continue one of them.
- A fix got parked mid-implementation or mid-verification (blocking work under an active plan), and
  you want to build it — and any deeper nested fixes parked under it — without hunting for the stub.
- A `/mentor:plan-split` left one or more siblings unbuilt, or one sibling's own parked fix still
  open, and you want to finish the group in order.

## When NOT to use

- You want to **create** a handoff note for the next agent — that is `/mentor:handoff`, not this skill.
- You want to pick the next **plan** to build, or see which plans are already built — that is
  `/mentor:track`. This skill resumes a *session* from a note someone wrote, or drains one specific
  root's or group's remaining pieces; plan state is a different question with a different answer.
- You want the repo-wide picture of everything left across every plan, not just one root's or one
  split group's remaining descendants — that is `/mentor:track`, which renders the whole tree and
  rolls every branch up.
- You just discovered blocking work and want to park it — that is `mentor:deferring`
  (`/mentor:defer`), which captures it with a `parent`; this skill only continues what capture
  already parked.
- This repo has no handoff notes and no open descendants or unbuilt split groups — there is nothing
  to resume (Step 3 handles this and points you at `/mentor:handoff` or `/mentor:plan`).

---

## Step 1 — Resolve the repo-scoped mentor dir

Derive the per-repo mentor dir via the shared subcommand — the same call `/mentor:handoff`
uses, so reading and writing agree by construction:

```bash
mentor_dir="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" dir)"
[ -n "$mentor_dir" ] || { echo "ERROR: mentor dir unresolved — is CLAUDE_PLUGIN_ROOT set? do not search the plugin cache or hardcode a version path; ask the user to /reload-plugins or restart" >&2; exit 1; }
echo "$mentor_dir"
```

Notes live in **two locations** under `$mentor_dir`, both covered by Step 2's `find`:

- `plans/<topic>/handoffs/*.md` — the canonical per-plan-topic location `/mentor:handoff` writes.
- `handoffs/*.md` — the legacy flat dir (pre-v2.10 notes); still listed so old notes stay
  resumable, but nothing new is written there.

Read **only** from under `$mentor_dir` — never scan other repos' dirs (repo-scoped is a locked
requirement). The subcommand resolves via `--git-common-dir`, so a git **worktree** lands on the
same key the note was written under, and outside a git repo it echoes
`$HOME/.claude/mentor/_no-repo` — the same fallback `/mentor:handoff` gets.

## Step 2 — List the notes, newest first

List the `*.md` notes from **both** Step 1 locations, **newest first by the filename timestamp**
(the `YYYYMMDD-HHMMSS` prefix sorts lexically = chronologically, so a reverse sort on the *basename*
is robust even if file mtimes drift — and orders correctly across topic dirs, where a full-path sort
would group by topic instead). For each file:

- **Never list a `resolved/` subdir** — the snippet below excludes them. Notes there are finished:
  their work completed per the plan file, or a newer note superseded them (Step 5's final rule and
  `/mentor:handoff`/`/mentor:ship` stamp them). Re-listing one invites an agent to redo solved work —
  exactly what the stamp exists to prevent. Only if the user *explicitly* asks for resolved/old
  notes, list `plans/*/handoffs/resolved/*.md` too, each marked `[resolved]`.
- **Skip** any filename that does not match the handoff naming pattern
  `<YYYYMMDD-HHMMSS>-<slug>.md` (regex `^[0-9]{8}-[0-9]{6}-.+\.md$`). Print a one-line warning naming
  the skipped file and continue — do not abort the whole listing for one stray file.
- Show the note's **topic** (the `plans/<topic>/` dir it lives in; `(legacy)` for flat-dir notes) so
  the user sees which plan each note continues.
- Build a **focus preview**: read the note's **"Goal / next-session focus"** section (that section
  name is canonical — it is defined in `/mentor:handoff` SKILL Step 3; reference it, don't restate the
  format) and take its first non-blank line. If that section is absent or empty, fall back to the
  first non-blank paragraph of the note and label the preview `(no focus section)`.
- Parse the timestamp from the filename (`YYYYMMDD-HHMMSS`) for a human-readable date in the listing.
- Flag **plan-less topics**: for topic-folder notes (never `(legacy)`, which predates the topic-folder
  structure), when `plans/<topic>/plan.md` doesn't exist, append `(no plan.md — consider /mentor:plan
  <topic>)` after the focus preview — real work has accumulated under this topic with no plan of
  record to give it the edit gate, verification topics, or `/mentor:track`'s hierarchy.

A snippet that lists conforming notes newest-first with their topic and focus preview. It is
deliberately `find`-based, not glob-based — an unmatched glob aborts the whole command under zsh
(and either location may legitimately be empty), while `find` just yields nothing for a missing dir:

**Plugin-wide convention:** every Bash call anywhere in mentor that dereferences
`${CLAUDE_PLUGIN_ROOT}` guards it first — a new Bash tool call is a new shell, so a guard earlier
in the same skill does not cover it. Applies across every skill/command in this plugin, not just
here; when adding a new `${CLAUDE_PLUGIN_ROOT}` call, grep for `CLAUDE_PLUGIN_ROOT unresolved` to
match the existing wording rather than inventing a new one.

```bash
# Re-derive: Step 1's block was a separate Bash call and its variables are gone. An unset
# $mentor_dir would make `find` search "/plans" and "/handoffs" instead of the repo's —
# guarded below rather than left to fail silently.
mentor_dir="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" dir)"
[ -n "$mentor_dir" ] || { echo "ERROR: mentor dir unresolved — is CLAUDE_PLUGIN_ROOT set? do not search the plugin cache or hardcode a version path; ask the user to /reload-plugins or restart" >&2; exit 1; }
i=0; skipped=""
while IFS= read -r f; do
  base="$(basename "$f")"
  if ! printf '%s' "$base" | grep -Eq '^[0-9]{8}-[0-9]{6}-.+\.md$'; then
    echo "  (skipping non-conforming file: $base)"; skipped="$skipped$base "; continue
  fi
  case "$f" in
    */plans/*/handoffs/*) topic="$(basename "$(dirname "$(dirname "$f")")")" ;;
    *)                    topic="(legacy)" ;;
  esac
  i=$((i+1))
  focus="$(awk '/^#+[[:space:]].*[Gg]oal.*next-session focus/{f=1;next} f&&/^#+[[:space:]]/{exit} f&&NF{print;exit}' "$f")"
  [ -z "$focus" ] && focus="$(awk 'NF{print;exit}' "$f")"   # (no focus section) — first non-blank line
  plan_note=""
  if [ "$topic" != "(legacy)" ] && [ ! -f "$mentor_dir/plans/$topic/plan.md" ]; then
    plan_note="  (no plan.md — consider /mentor:plan $topic)"
  fi
  printf '%d. [%s] %s — %s%s\n' "$i" "$topic" "$base" "$focus" "$plan_note"
done < <(find "$mentor_dir/plans" "$mentor_dir/handoffs" \
              -type f -name '*.md' -path '*/handoffs/*' -not -path '*/handoffs/resolved/*' 2>/dev/null \
         | awk -F/ '{print $NF "\t" $0}' | sort -r | cut -f2-)   # newest first by basename timestamp
if [ -n "$skipped" ]; then echo "skipped non-conforming: $skipped"; fi   # `if`, not `&&`: as the block's last command a false `&&` exits 1 and the whole listing renders as an error

# Also list: roots with open descendants, and split groups with unbuilt siblings — printed
# AFTER every note, in the SAME numbering (`i` continues from above, same shell), so Step 4's
# ordinal rule extends unchanged and `latest`/`newest`/`last` still mean the newest NOTE, never
# a drain entry. Every open/closed call goes through `subtree` — never re-derived here. `overview
# --json`'s `parent`/`group` fields (not a hand-rolled walk) pick the candidates to ask it about.
# `-` is the empty-group placeholder (same convention `overview`'s own `_plan_walk` uses
# internally) — NOT a bare empty field: tab is "IFS whitespace" to `read`, so consecutive tabs
# collapse and silently eat a column, exactly the corruption a real empty field would cause here.
ov="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" overview --json)"
drain_rows=()
while IFS="$(printf '\t')" read -r rslug rgroup rstate; do
  [ -n "$rslug" ] || continue
  n="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" subtree "$rslug" | tail -1 | grep -o '^[0-9]\+' || true)"   # `|| true`: "no descendants." has no digit, grep's non-match must not abort the loop
  drain_rows+=("${rslug}$(printf '\t')${rgroup}$(printf '\t')${rstate}$(printf '\t')${n:-0}")
done < <(printf '%s' "$ov" | jq -r '.[] | select(.kind=="plan" and .parent==null) | [.slug, (.group // "-"), .state] | @tsv')
for row in "${drain_rows[@]}"; do   # ungrouped roots with open descendants
  IFS="$(printf '\t')" read -r rslug rgroup rstate n <<<"$row"
  [ "$rgroup" = "-" ] && rgroup=""
  [ -z "$rgroup" ] || continue
  [ "${n:-0}" -gt 0 ] || continue
  i=$((i+1))
  printf '%d. [drain: root] %s — %s open fix(es) parked\n' "$i" "$rslug" "$n"
done
groups_seen=" "   # leading+trailing space so `*" x "*` matches the FIRST entry too, not just later ones
for row in "${drain_rows[@]}"; do   # split groups: unbuilt when any sibling is open, or has open descendants
  IFS="$(printf '\t')" read -r rslug rgroup rstate n <<<"$row"
  [ "$rgroup" = "-" ] && rgroup=""
  [ -n "$rgroup" ] || continue
  case "$groups_seen" in *" ${rgroup} "*) continue ;; esac
  groups_seen="${groups_seen}${rgroup} "
  unbuilt=0
  for row2 in "${drain_rows[@]}"; do
    IFS="$(printf '\t')" read -r gslug ggroup gstate gn <<<"$row2"
    [ "$ggroup" = "$rgroup" ] || continue
    case "$gstate" in implemented|superseded) : ;; *) unbuilt=1 ;; esac
    [ "${gn:-0}" -gt 0 ] && unbuilt=1
  done
  [ "$unbuilt" -eq 1 ] || continue
  i=$((i+1))
  printf '%d. [drain: group] %s — split group with unbuilt sibling(s)\n' "$i" "$rgroup"
done
```

The exclusion is anchored to `*/handoffs/resolved/*` on purpose — a bare `*/resolved/*` would also
match a **repo whose own path** contains a `resolved/` segment (or a topic slug named `resolved`)
and silently hide every note while the hooks still see them.

A root or group printed here may share its slug with a note printed above — a fix parked under a
topic that also wrote a note, or a plan-split sibling whose own note is still live. That is expected,
not a bug in the listing: Step 4 resolves the overlap deterministically (note first, drain offered
after), not by asking which one was meant.

## Step 3 — Empty case

If no conforming notes are found **and Step 2 skipped nothing**, check whether Step 2's drain
listing found anything before declaring defeat — a repo can easily have zero notes and one or more
open roots or unbuilt split groups (a fix parked mid-session that never got written up). When the
drain listing is non-empty, there IS something to resume: skip straight to Step 4 with that list.
Only when **both** lists are empty tell the user **this repo has nothing to resume** — no live
handoff notes, no open descendants, no unbuilt split groups — and suggest `/mentor:handoff` (in a
session with work to hand off) to create a note, or `/mentor:plan <topic>` if they know of specific
work not yet captured at all. Then **stop**.

If the listing is empty **only because every candidate was skipped as non-conforming**, do NOT
report "no handoff notes" — that is false, and it sends the user off to write a second note while a
real one sits unreadable on disk. The skip warnings land in bash output, which the user never sees,
so this step is the only place the miss can surface. Name each skipped file to the user, then
continue to **Step 4's recovery path** instead of stopping here.

## Step 4 — Select a note, root, or split group

Print the full numbered list from Step 2 — notes newest first, then any `[drain: root]` and
`[drain: group]` entries — so the user can see every note **and** everything with open descendants,
including the "skipped non-conforming" line when Step 2 skipped anything. A warning that only lands in
bash output is invisible to the user, and a misnamed-but-real handoff note silently vanishing
is exactly how unfinished work gets lost. If the user then asks to recover a skipped file,
rename it into the canonical pattern using the file's **mtime** for the timestamp
(`mv "$f" "$(dirname "$f")/$(date -r "$f" +%Y%m%d-%H%M%S)-<slug>.md"` — an invented "now"
timestamp would mis-sort the note permanently) and re-list. Only on their explicit request.

Then resolve a selection:

- **From the argument** (`$ARGUMENTS`) or from an `AskUserQuestion` "Other" free-text answer:
  - A **bare integer** → a **1-based ordinal** into the printed list (1 = newest).
  - The **keywords `latest` / `newest` / `last`** (any casing, alone or with filler like
    "latest handoff") → **ordinal 1** (the newest note).
  - A **plan-topic name** (case-insensitive exact match against the `[<topic>]` shown before each
    note in the printed listing — the same handle `/mentor:plan <topic>` and `/mentor:track <topic>`
    use, and how a note is actually asked for from outside this skill) → filter **the printed list**
    to that topic's notes; never re-derive them from disk. **Exactly one** live note under that
    topic — the normal case, since `/mentor:handoff`'s supersede sweep keeps one live note per topic
    dir — → select it directly, mirroring the single-note case below. **More than one** → re-print
    just that topic's notes, still newest first, and ask which. **No note** under that topic → fall
    through to the slug-substring rule below.
  - **A root's own slug** (case-insensitive exact match against a `[drain: root]` entry printed by
    Step 2) → that root's parent-subtree drain ("Draining Parked Fixes and Split Groups" below) —
    unless the same slug is also a live note's topic, in which case the note+fixes rule right below
    this list decides, not this bullet.
  - **A split group's name** (case-insensitive exact match against a `[drain: group]` entry's name —
    the superseded parent's slug — printed by Step 2) → that group's split-group drain (same section
    below).
  - **Otherwise** (including a topic name that matched no note) → a **case-insensitive substring
    match against the slug** — the note's filename slug, a `[drain: root]` entry's slug, or a
    `[drain: group]` entry's name, whichever the printed list actually shows it against.
  - A **note path or plan slug embedded in a longer phrase** → select from what is embedded. This
    plugin produces that shape itself: `/mentor:handoff` Step 5 prints a plugin-free resume prompt
    that is an absolute note path wrapped in prose, and users paste task briefs ("implement the
    approved X plan: read `<path>`, then …"). Such a phrase substring-matches no slug, so the rule
    below would re-ask — pedantry against someone who named the file, and an agent that overrides it
    here is off-script for every step after. Take the embedded path/slug; any task instructions
    riding along are **context for the work**, never a replacement for Step 6's routing. An embedded
    path may name a file Step 2 skipped as non-conforming — load it anyway (an explicit path is
    better evidence than the listing) and offer the rename recovery above.
  - A **unique** match is selected directly. If the input is **ambiguous** (matches >1 entry, of any
    kind — two notes, a note and a differently-named root, two split groups, etc.) or **matches
    nothing**, **never auto-pick** — re-print the list and re-ask. **Mechanical self-check before
    proceeding:** the selection must have resolved through one of the literal rules above (ordinal,
    keyword alias, plan-topic name, root slug, split-group name, slug/name substring, or an embedded
    note path/plan slug). "It obviously meant the latest one" is not a rule — a typo or free phrase
    that matches nothing (e.g. "lastest hand-off" against slugs it doesn't substring-match) is a
    NO-match: re-print and re-ask.

**Note+fixes topics resolve to the note, not the drain, when both match the same topic — this is
not the ambiguous case above.** A note under topic `T` and `T`'s own `[drain: root]` (or
`[drain: group]`) entry both matching the same argument is one topic with two facets, not two
different things the user might have meant: whether the argument was `T`'s slug, an ordinal that
happened to land on the note row, or a substring — resolve it to **the note** and proceed to Step 5.
Step 5's closing rule offers `T`'s drain as its own next step once the note's flow concludes; never
skip the note to jump straight into the drain, and never ask the user to disambiguate something that
isn't actually ambiguous. The ambiguous-match rule above still applies whenever the match spans
genuinely different topics or slugs — this carve-out is only for the same-topic overlap.
- **With no argument**, call `AskUserQuestion` (single-select) with the **4 newest** notes as quick
  options — `label` = the slug, `description` = the human date + focus preview. Older notes, and
  every `[drain: root]`/`[drain: group]` entry, are reachable through the always-present **"Other"**
  free-text (resolved by the rules above — a root slug or group name typed there resolves exactly as
  it would from `$ARGUMENTS`). Quick options stay note-first on purpose: a note carries the richer
  "what happened and what's next" context, so it is the better default guess when nothing narrows the
  choice; a drain entry is one exact name away regardless. This respects `AskUserQuestion`'s 4-option
  cap. **Every question stands on its own:** the user answers
  from the question screen alone — never sent to a file, a plan section, a coined id or code, or an
  earlier turn to learn what the question means. A slug is a filename, not a description, so the
  preview must say what that note is actually about ("finish the Thanos SSA reprojection, 3 steps
  left") rather than restating the slug in prose.
- If there is **exactly one** note, skip the picker and ask a simple **Continue / Cancel**. If there
  are **zero** notes but **exactly one** drain entry (a root or a group) total, the same shortcut
  applies to it — skip the picker and ask Continue / Cancel for that one entry instead.

## Step 5 — Load & continue

This step continues a **handoff note**. When Step 4 resolved to a `[drain: root]` or `[drain:
group]` entry instead, skip to "Draining Parked Fixes and Split Groups" below — the two are separate
continuation modes and this step's numbered flow (secrets scan, gate check, "Recommended mentor
commands") applies only to notes.

Before the numbered flow below, check whether this session has room for the note's work —
nothing upstream of this step has measured context yet, and a resumed note can lead into
substantial work (an implementation via `/mentor:track`, a dispatch fan-out via
`mentor:dispatch-agents`, or open-ended research/analysis with no command of its own — Step 6's
"research or analysis fan-out" case runs entirely without `/mentor:track`'s or
`mentor:dispatch-agents`'s own context checks, so this is the only gate it gets):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" context
```

The tiers match the rest of the plugin — `mentor:plan-track`'s own Step 0 runs this identical call:

- **`CONTEXT: ASK`** — do not act on the note yet; ask the user the two-option question the
  script prints (hand off, or bypass for this session) before continuing below.
- **`CONTEXT: HANDOFF`** — they already chose to continue; proceed, but plan to hand off again
  before this note's work is done.
- **`CONTEXT: WARN`** — surface it, then continue.
- **`CONTEXT: OK` / `UNKNOWN`** — continue.

For work with no further mentor-command checkpoint of its own (the research/analysis case
above), re-run this same check immediately before delivering the final report or summary,
mirroring `mentor:dispatch-agents`'s close-out re-check — a long autonomous stretch between this
reading and that report is exactly the shape `context-gate.sh`'s own WARN tier cannot catch
(`UserPromptSubmit`-only; nothing re-invokes it between prompts).

1. `Read` the chosen note in full.
2. **Scan for secrets first.** Before surfacing any section, scan the content for secret patterns —
   API keys, passwords, tokens, connection strings, private-key blocks (`-----BEGIN`),
   `AKIA…`, `://user:password@…`. If you find one, **warn** the user that the note appears to contain
   a live secret and do **not** echo the value verbatim — surface a redacted form. (Handoffs are
   supposed to be redacted at write time; this is a defense-in-depth check on load.)
3. State **"Resuming: \<focus\>"** (from the note's Goal / next-session focus), then surface the
   **Current state** and **Open questions / risks** sections so the user sees where things stand.
   If a **Standing directives** section is present, surface it too and obey it for the rest of
   this topic — it is a constraint, not a suggestion, and it does not expire with the session
   that wrote it. **This narration is its own turn, before the note's first action of any kind —
   read-only ones included** — folding it silently into a later wrap-up, or skipping straight into
   the note's action steps, does not satisfy this step. Do **not** stamp the note yet — loading is
   not finishing; if this session stalls, the note must still be listed for the next one.
4. **Reference artifacts by their paths** — the plan file, PRDs/ADRs, issue/PR URLs, commit SHAs as
   the note lists them. Do **not** paste their contents; open/read them only as needed to act.
5. **Verify the gate state on disk — never trust the note's claim.** A note may say the plan gate is
   released (or armed); check the actual marker before acting:

   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" gate --verbose   # ARMED | STALE | ARMED_ELSEWHERE | RELEASED (+ per-token fields below)
   ```

   If the marker state contradicts the note, say so and follow the marker, not the note. `gate` is
   read-only and worktree-scoped (v2.23.0): exactly one of four tokens on the first line, and a
   different `--verbose` field set per token — a field that doesn't exist for the token you got back
   was never going to print, it is not "empty":

   - **`ARMED`** — this worktree's own marker is live, or the legacy repo-global `.planning` marker is
     live (which blocks every worktree, this one included). `--verbose` adds `marker=`,
     `owner_session=`, `owner_cwd=`, `owner_worktree=`, `age_min=`, and `affected_plans=` — the plan
     slug(s) `approve-plan.sh` would promote to `approved` if run right now (repo-wide, unfiltered,
     when the armed marker is the legacy one; scoped to this worktree otherwise).
   - **`ARMED_ELSEWHERE`** — no marker of this worktree's own is live, but a *sibling* worktree's is.
     It is an independent gate: it does **not** block writes here. `--verbose` prints one
     `elsewhere=<wt-id> session=<sid> worktree=<path> age_min=<n>` line per live sibling, and nothing
     else — there is no `owner_*`/`affected_plans` for this token.
   - **`STALE`** — a marker (own or legacy) exists but has aged past the self-heal window; bare token,
     no `--verbose` fields.
   - **`RELEASED`** — no marker at all (also what `gate` reads outside any git repo). Bare token, no
     `--verbose` fields.

   `owner_session`/`owner_cwd`/`age_min` (on `ARMED`) name who holds it; `affected_plans` names which
   plan(s) an approve would sweep right now — surface all of it to the user. Do **not** try to clear
   it yourself: `gate` itself never deletes a marker, and it is no longer true that `plan-gate.sh` is
   the only thing that ever does (`begin-plan.sh` now also prunes a **stale sibling** marker on arm,
   and `plan-gate.sh` self-heals a stale own/legacy marker on a would-deny write) — but neither of
   those is you, so still never delete a marker by hand, and never run `approve-plan.sh` to "free it
   up" — it takes no slug and promotes *every* plan newer than the marker it resolves, which may be a
   plan nobody reviewed this session (`plan-gate.sh`'s own denial for this exact case carries the same
   warning).

   **`ARMED_ELSEWHERE` needs one more check before you decide it's someone else's problem: is it your
   own gate, just parked in a different worktree?** Compare each `elsewhere=` line's `worktree=` path
   against the worktree the handoff note itself recorded arming (planning's "Pause — still drafting"
   handoff now names the arming worktree explicitly, for exactly this comparison). A match means this
   **is** your gate — still armed, just not from here: resume it in that worktree, or re-own it here
   first (next paragraph) before you can approve from this one. No match means it is genuinely a
   different, unrelated worktree's planning session — informational only, does not block you.

   **Resuming in a different worktree than the one that armed the gate MUST re-own before any
   approval.** The gate itself re-arms freely per-worktree — `begin-plan.sh` in a new worktree never
   collides with another worktree's marker — but the plan's sidecar `owner` still points at whichever
   worktree minted or last `init`ed it, and `approve-plan.sh`'s owned-filtered candidate search
   excludes a plan this worktree doesn't own. **`/mentor:plan <slug>` is the only carrier that
   re-owns it** — it re-runs `init`, which re-stamps `owner` to this worktree (last-init-wins) — so
   Step 6's `/mentor:plan <slug>` route below is not just how you re-arm, it is how you re-own. On an
   `ARMED_ELSEWHERE` result specifically, check that slug's `owner` first (`plan-state.sh list
   --owners`, or read `.mentor/plans/<slug>/.state.json` directly) before routing to `/mentor:plan
   <slug>`: already owned by THIS worktree means there is nothing to re-own, but owned by the sibling
   worktree named in `elsewhere=` means re-owning it here is a real decision — it can race that
   sibling session if it is still actively drafting — worth saying to the user, not a formality to
   skip past.

   **Do not assume Step 6's `/mentor:plan <slug>` route resolves this for you.** `begin-plan.sh`'s
   foreign-marker guard compares **session IDs only**, on this worktree's own marker — it has no
   notion of slug or plan — so it fires identically whether the marker belongs to a genuinely
   unrelated plan *or* to the note's own plan left mid-draft by a "Pause — still drafting" handoff
   (resuming is always a new session, so the ids never match either way). Read its output: `Plan phase
   ARMED.` means it re-armed for you, safe to continue; `Plan gate NOT armed — another session's plan
   gate is already active.` means it **declined** — the old marker is still sitting there un-owned by
   this session. On the refusal, stop; do not proceed into planning believing the repo is gated just
   because the marker file still exists on disk, and do not fall through to `/mentor:dispatch-agents`
   or a hand-rolled ship either — `plan-gate.sh` will deny the first write regardless, so dispatching
   burns the whole batch on a wall it was always going to hit. Tell the user what's armed and let them
   decide: wait, or explicitly authorize continuing past it — if the latter, re-run the SAME
   `begin-plan.sh` command with `--override-foreign-marker` appended (the refusal message itself
   names this); that re-arms and prints who it overrode, the supported route for a confirm that
   already happened. **Never delete the marker file by hand** to route around the refusal — that skips
   the guard's own stranding check entirely, worse than the wait it exists to enforce. `/mentor:track`
   is the one route that already handles this itself (it stops on any live marker, "whatever the
   state") — nothing extra to do there.

   **`STALE` is not still-armed, but it is not plain `RELEASED` either — treat it as its own
   determination.** The marker can still be sitting on disk — nothing you do here removes it, and it
   is no longer true that only `plan-gate.sh` ever does: it clears lazily, either via
   `plan-gate.sh`'s self-heal on the next edit attempt it would otherwise deny, or via
   `begin-plan.sh` pruning a stale **sibling** marker on the next arm in ANY worktree — but its age
   past the self-heal threshold is itself positive evidence: `approve-plan.sh` never ran to release
   it, so the plan was not approved — the gate has merely lapsed from age, not from a decision. Do not
   start drafting or editing on a `STALE` (or `RELEASED`) marker — run `/mentor:plan <slug>` first to
   re-arm it, unless the note's recommendation is another tracked plugin's command (e.g.
   `/loom:learn`); that work has no mentor plan of record, so this repo's plan gate doesn't apply to
   it — skip straight to running the listed command. `mentor:planning`'s own unarmed-gate check cannot save you here, because skipping the
   command means the skill never loads to run it. This is exactly the case a note resuming
   **planning** (its plan still `draft`) will usually hit.

   When the note resumes **implementation**, also glance at branch ownership before the first edit
   — GitHub + `gh` only, fail-soft:

   ```bash
   command -v gh >/dev/null && git remote get-url origin 2>/dev/null | grep -qi github && \
     gh pr list --head "$(git branch --show-current)" --state open --json number,title,url 2>/dev/null || true
   ```

   An open PR that isn't this work means new commits would land in someone else's PR; surface it
   now — discovering it at `/mentor:ship` costs a cherry-pick recovery. An open PR that **is** this
   work means the shipping already happened: say `Watch CI and merge with /mentor:merge` rather than
   re-implementing. Nothing else routes a later session into the merge tail, so a raw `gh pr merge`
   here is how a shipped plan ends up stuck at `in_progress`.

   **Also report any pre-existing dirty/untracked state before dispatch begins** — the same
   check `mentor:shipping` Step 2 runs, just early enough to act on instead of untangle:

   ```bash
   git status --porcelain --untracked-files=no
   ```

   Non-blocking — this is a report, not a gate; resuming never stashes, commits, or aborts on
   it, and it never re-states `mentor:shipping`'s own rules. Anything printed here pre-dates
   this session's work by construction (nothing has been edited yet), so surface it once and
   let the user decide whether to carry it through, stash it, or commit it before a multi-hour
   dispatch run starts. Skipping this costs nothing today and a scramble later: `mentor:shipping`
   Step 2 finds the same paths mixed in with this session's real output and has to untangle
   ownership from conversational memory instead of a baseline recorded up front.
6. **Act on the note's "Recommended mentor commands for the next agent."** A section that opens with
   a bold **Before any command:** line is naming a mandatory precondition — a specific verification
   step the writing session left open, an external check to wait on — not a command itself and not
   something to skip because it carries no `/mentor:` token. Do it first, before touching any listed
   command. **Bound "act":** invoke the
   listed command(s) **exactly as the note states** — do not infer extra steps or expand beyond
   what the note recommends, whether it names a `/mentor:` command or another tracked plugin's
   (`/loom:harvest`, `/loom:learn <plugin> <session-id>`) — a listed command is a listed command
   regardless of prefix. A note listing `/mentor:ship` or `/mentor:merge` as ready is still bound
   by those skills' own consent gates — `mentor:dispatch-agents`' CLOSING CHECKLIST offers ship,
   it never auto-runs it, and a satisfied trigger condition in the note doesn't override that.
   If the note recommends `/mentor:plan <focus>`, run that. If it recommends resuming
   implementation of an **approved plan**, invoke
   **`Skill(skill="mentor:plan-track", args="<slug>")`** (the skill behind `/mentor:track <slug>`)
   with the plan slug the note names — the bound is on which work and its scope, not on
   mirroring the note's slash token into `Skill()`, which only re-enters through the command
   wrapper for a second hop. Track is not an extra step you inferred — it is how that
   recommendation is honored:
   it re-enters at the first unticked step instead of rebuilding from step 1, runs the context check
   that decides whether this session is big enough to finish, and then executes through
   `mentor:dispatch-agents` anyway. `mentor:dispatch-agents` says the same thing from its side ("When
   NOT to use — starting from a plan this session didn't write"), and a resumed note is exactly that
   case. Older notes phrase the recommendation as "implementation via `mentor:dispatch-agents`" —
   honor those **through** `/mentor:track` too; it is the same work, and passing the slug means the
   user who already chose a note isn't asked to choose a plan again. Invoke
   `Skill(skill="mentor:dispatch-agents")` directly only when the note's work has no plan record at
   all, so there is no state for track to read.

   **When the note names no commands at all** — no "Recommended mentor commands for the next agent"
   section — you still have a route; do not improvise one, and do not re-derive plan state here.
   Roughly a third of the notes on disk predate that section or drifted away from it, so this is the
   common case, not the exotic one:
   1. **Sweep the note body for `/mentor:<command>` tokens under any heading.** A note that says
      "run `/mentor:ship`" under `## What REMAINS` is recommending a command — only its heading
      drifted — and Step 6's bound applies to those exactly as if the section were canonical. Two or
      more distinct commands: ask which. **Match bare `mentor:<skill>` tokens too** — not every
      mentor surface has a slash command, so a note naming `mentor:dispatch-agents` (the shape
      `mentor:handoff-note` writes for a fan-out with no plan of record) is recommending it just as
      surely, and a sweep that only knows slashes drops it and falls through to `/mentor:track`.
      **Match `/loom:<command>` tokens too** — notes route follow-on work there
      (`mentor:handoff-note`'s mapping emits `/loom:harvest`/`/loom:learn`) — but always confirm a
      `/loom:` hit with the user before invoking it, never run it on a single-token sweep match
      alone; a swept token can be prose *about* the pattern, not a real recommendation, and some
      loom commands (`/loom:publish-plugin`) push to the default branch.
   2. **None anywhere → `Skill(skill="mentor:plan-track", args="<topic>")`** (`/mentor:track
      <topic>`), using the note's own topic slug (the
      `plans/<topic>/` dir it lives in — `/mentor:handoff` writes notes there, so you already hold
      the key). Track reads plan state and already triages an approved plan, a `draft`, a deferred
      stub, and a topic with no plan record; re-deriving that here would fork a decision tree that
      has one owner.
   3. Only when the note's plan of record lives **outside** `.mentor/` — another framework owns it —
      does the no-plan-record rule above apply directly, and `mentor:dispatch-agents` carries the
      branch for it. `/mentor:track` refuses that case by design and sends you to `/mentor:plan`,
      which re-plans decisions someone already made.

   Step 2's `(no focus section)` label is the early tell: a note previewed that way is non-canonical,
   so expect this branch before you start editing rather than after.

   **The bound is on the work, not on how it is executed or delivered.** Running the note's work by
   hand instead of through `/mentor:track` skips the step ticks and `mentor:dispatch-agents`' closing
   sweep — the sweep that routes every follow-up through `/mentor:defer` — and hand-rolling
   `git push` + `gh pr create` skips `mentor:shipping` Step 6, which stamps this note resolved and
   closes the plan's state. The note then stays live and `/mentor:track` re-offers work that already
   shipped. Concretely: when you are about to type `git push`, `gh pr create`, or `gh pr merge`, run
   `/mentor:ship` instead — it hands off to `/mentor:merge`, which owns the merge consent gate. And
   when you are about to issue an `Agent()` call — however the note phrased it ("dispatch parallel
   `Explore` agents", "no single mentor command owns this") — load
   `Skill(skill="mentor:dispatch-agents")` first, then dispatch through it. Prose describing a
   fan-out names no command, so it is neither the no-commands branch above nor licence to dispatch
   raw. That skill appends the standing contract block ("Deliver before idling"), which is the only
   thing that makes a dispatched agent report instead of signalling idle with nothing delivered; a
   fan-out issued without it strands the whole group at once and leaves you redoing their work by
   hand. Going direct rather than through `/mentor:track` is right **only** for a research or
   analysis fan-out, which has no plan steps to re-enter or tick — a fan-out that *implements* plan
   steps still routes through `/mentor:track` per the bound above. Loading the skill honors the
   note's instruction; it does not expand its scope.

   A bare "let's commit" is not that signal. Commit normally — the bound is on how the session
   ends, not on any commit along the way, and `mentor:shipping` Step 2 aborts on a dirty tree
   precisely because it expects you to have committed first. What it does bind is the turn after:
   when the note's work is done but unshipped, do not let that commit be the last thing this
   session does. Ask whether to ship now, or run `/mentor:handoff` — which supersedes the note you
   resumed and leaves one live resume point in its place, so the remaining ship step survives the
   session instead of dying with it. Committing finished work and then stopping — no
   `/mentor:ship`, `/mentor:merge`, `/mentor:handoff`, or `/mentor:defer` anywhere in the session —
   is the same raw ending the "Done when" bound rules out; it just arrives one step later than the
   push/PR case.
7. **Stamp the note resolved when — and only when — its work is done.** Track the note's path for the
   rest of the session; the stamp fires on the first of these:
   - **All the note's tasks completed per the plan file** — every recommended command ran to
     completion and the plan's implementation steps are done (typically the moment `/mentor:ship`
     succeeds; ship also stamps the topic's notes itself as a backstop). Run:

     ```bash
     note="<the resumed note's absolute path>"
     resolved_dir="$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" ensure-dir "$(dirname "$note")/resolved")" || exit 1
     mv "$note" "$resolved_dir/$(basename "$note")"
     echo "resolved: $resolved_dir/$(basename "$note")"
     ```

   - **A nested handoff** — this session ends with `/mentor:handoff` continuing the same work; its
     supersede step stamps the older note mechanically, so there is nothing extra to do here — for a
     note in this same `handoffs/` dir. If the note you resumed lives in a different topic dir or the
     legacy flat dir, handoff's sweep cannot see it: hand its absolute path to the handoff step
     explicitly, or stamp it here with the snippet above.
   - **Never while the topic still has open descendants — check before either bullet above fires.**
     Run `bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" subtree <topic-slug>` (the note's topic —
     the `plans/<topic>/` dir it lives in) and read its trailing count. A non-zero count means the
     topic is NOT actually done, however cleanly the note's own tasks wrapped up: every recommended
     command can have run, every step in the plan file can be ticked, and there can still be a fix
     parked underneath that nobody has built. Ticks measure the plan's own steps, not its descendants
     — that gap is exactly what `parent` exists to close. Leave the note live in this case even if the
     bullet above would otherwise have fired; go to the closing paragraph below instead of stamping.

   If the session ends with the work unfinished and no nested handoff, **leave the note live** —
   unfinished work must stay resumable; that is not a failure. A stamp is reversible by moving the
   file back up one directory. **Never stamp a note that already lives under a `resolved/` dir**
   (an explicitly-browsed `[resolved]` note): it is already retired, and the snippet would nest a
   useless `resolved/resolved/` — skip this step for those.

**When this note's topic also has open descendants**, whether or not the note itself just got
stamped resolved, offer the drain as the turn's own next step rather than ending silently: "This
topic still has N open fix(es) parked under it — continue draining them now?" (the count from item
7's `subtree` check above). A **yes** proceeds into "Draining Parked Fixes and Split Groups" below,
treating the topic slug as the root. A **no** leaves them exactly where Step 2 will find them on a
later `/mentor:resume <topic>` call — nothing forces the drain in the same session. Never start it
unprompted, and never let it replace loading the note first: the note can carry Standing directives
or Open questions the drain needs, and this step's own flow already ran before this offer.

Do **not** copy or duplicate the note into the repo source tree — it lives in the gitignored
`.mentor/` tree by design.

## Draining Parked Fixes and Split Groups

Step 4 routes here when the resolved selection is a `[drain: root]` or `[drain: group]` entry, not a
handoff note. This is the other half of "continue" — for work that a fix `parent` (parked via
`mentor:deferring`) or a plan-split left behind and nobody wrote a note about.

**Resume stays the door, not a second surveyor here either.** Every open/closed call below goes
through `subtree`/`overview --json` — this skill never reads `.state.json` or a plan's ✅ ticks
itself to decide what's open. "Open" has exactly one definition (effective state ∉ {`implemented`,
`superseded`}), owned by `plan-state.sh`, and reused unchanged everywhere it matters
(`mentor:plan-track`'s tree render, the `set … implemented` soft warn, and here).

### Ordering: leaf-first, post-order

**Why leaf-first:** a nested fix blocks the fix it was parked under. You cannot honestly call
`fix-auth-timeout` complete while its own child `fix-retry-loop` is still open — whatever
`fix-retry-loop` addresses is presumably still broken underneath it. Post-order (every child before
its parent) is the only ordering where each item is actually ready when its turn comes: everything
it structurally depends on has already closed.

To compute the drain order for a root `R`:

1. `bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" subtree R` — the descendant set, each with its
   effective state and open/closed verdict, plus the trailing open count. This is the only source of
   truth for which descendants are open; never re-derive it.
2. `overview --json`'s `parent` field on those same descendant slugs gives the immediate-parent edges
   needed to arrange them into a tree — `subtree`'s own text is breadth-first with depth, not grouped
   by branch; reconstructing the branch shape is a consumer-side concern layered on top of it by
   design (`hooks/lib/state.sh`'s `mentor_plan_descendants` says so explicitly in its own comment).
3. Walk that tree post-order. At each sibling group, break ties by `order` ascending (present when
   the siblings came from a plan-split, or were parked with an explicit order); when `order` is
   absent or tied, break by ascending directory mtime — `stat -c %Y "$dir" 2>/dev/null || stat -f %m
   "$dir" 2>/dev/null` (earlier-parked first).
4. Drop closed nodes from the queue itself — nothing to build there — but keep walking through them
   structurally: a closed fix can still have an open child parked under it later.

The queue for `R` is that post-order list, filtered to open nodes, with `R` itself joining last —
only if `R`'s own effective state is open. This also covers a fix that is itself split (per
"Composition with plan-split"): its split children inherit its `parent`, so they are just deeper
nodes in the same tree, and `order` breaks ties among them exactly as it would among top-level split
siblings — no separate handling needed.

### Split-group drain

A split-group name resolves to draining its **remaining siblings by `order`**, and — reusing the
rule above rather than restating it — **each sibling's own fix subtree drains before the sibling
itself is considered done**: treat every sibling exactly like a root `R` above, with its own
post-order queue and itself last, then concatenate those per-sibling queues in `order` sequence
across the group. A sibling already `implemented` with no open descendants contributes nothing; the
group is done when every sibling's queue is empty.

### Re-survey after each item

Do not compute the queue once and burn through it. **Re-run the survey — `subtree` for a root, the
same per-sibling walk for a group — after every completed item**, before picking the next one. An
item's own build can park a brand-new child under it (nesting, discovered mid-fix) that must drain
before whatever was going to run next; recomputing fresh each time is what lets a child parked
*during* the drain join the queue immediately, instead of waiting for a second `/mentor:resume` call
to notice it exists.

Stop when `subtree R`'s trailing line reads `0 open descendant(s)` (root drain), or — for a group —
when every sibling's own queue is empty.

### Per-item gate flow

Each queued item is built exactly the way `/mentor:plan` would build it standalone. This mode
re-enters that command's own body per item — it is not a shortcut around it:

1. `bash "${CLAUDE_PLUGIN_ROOT}/hooks/begin-plan.sh" <item-slug>` — the same arm, every one of its
   context/foreign-marker gates intact (`plugins/mentor/commands/plan.md` Step 1). A `CONTEXT: ASK`
   here stops the drain exactly like it would stop a standalone `/mentor:plan`.
2. `Skill({"skill": "mentor:planning"})` — it claims the stub (its own `claim`, since a parked
   child's `origin` is `"deferred"` — `mentor:deferring` owns what that capture wrote and why),
   fleshes it out with the user, and asks its own approval question (`{#approve}`).
3. Only on that item's approval does resume proceed to build it, via the same `mentor:dispatch-agents`
   implementation flow any freshly approved plan gets.

**Consent stays per item.** One approval never covers the rest of the queue — a 4-item subtree is 4
separate approval questions, not one "approve everything" ask up front: each item is its own plan
with its own risk, and a user who wants the next three built without asking says so at that item's
own question, not once for all of them.

```
$ /mentor:resume fix-auth-timeout        (resolves to a root with open descendants)
subtree fix-auth-timeout → fix-retry-loop   draft   open        (1 open descendant)
queue (post-order): fix-retry-loop, fix-auth-timeout
  → begin-plan fix-retry-loop → claim → flesh out → approve → build
  → re-survey: 0 open under fix-retry-loop; fix-auth-timeout itself still open (draft)
  → begin-plan fix-auth-timeout → claim → flesh out → approve → build
  → re-survey: 0 open descendant(s). Done.
```

## Done when

- Only **this repo's** conforming, live handoff notes were listed (newest first, with their
  topic), **plus** every root with open descendants and split group with unbuilt siblings from
  Step 2's drain listing — or the empty case was reported only once BOTH lists came up empty. Any
  skipped non-conforming files were named in the user-facing list, not just in bash output.
- The user's selection was resolved unambiguously (argument or interactive) across both axes —
  note, root, or split group — never auto-picked on an ambiguous/no match, except the deterministic
  note-first resolution for a topic that matches on both axes at once.
- **If the selection was a note:** it was loaded, scanned for secrets, its focus + current state +
  open questions surfaced as their own turn before acting, and the work continued via the note's
  recommended command(s) — mentor's own or another tracked plugin's, exactly as listed — and nothing
  beyond them. The session still **ended through a listed command** — a mentor command
  (`/mentor:ship` → `/mentor:merge`, `/mentor:handoff`, or `/mentor:defer`) or a cross-plugin command
  the note explicitly named — never through raw `git`/`gh` or a hand-written file; the bound is on
  the work, not on how it is executed or delivered. It was **stamped resolved** only if its work
  finished this session (all plan-file tasks done AND its topic has no open descendants left) or it
  was superseded by a nested `/mentor:handoff` — and left **live** otherwise; a topic with both a
  note and open descendants had the note load first, with the drain only offered after.
- **If the selection was a root or split group:** the drain ran leaf-first post-order (or by `order`
  per sibling for a group, each sibling's own fix subtree first), re-surveying after every completed
  item so a fix parked mid-drain joined the queue, with each item going through its own
  `begin-plan.sh` → `mentor:planning` (claim → flesh out → approve) → build — never one approval
  covering more than one item.

### Do NOT

- Do **not** scan or list any dir other than this repo's `$mentor_dir` locations (repo-scoped is
  locked).
- Do **not** list notes inside a `resolved/` subdir (finished or superseded work) unless the user
  explicitly asks for resolved notes.
- Do **not** jump from loading the note straight into its action steps (a live-console macro, a
  code edit) without first stating `Resuming: <focus>` and surfacing Current state / Open
  questions as this session's own output — a later summary that happens to cover the same ground
  does not count.
- Do **not** stamp a note merely because it was loaded — only completion (per the plan file, with no
  open descendants left) or a superseding handoff resolves it; an unfinished note, or one whose
  topic still has open descendants, must stay listed.
- Do **not** skip the stamp when the work DID finish — an unstamped solved note WILL be re-listed
  and re-worked by a later session.
- Do **not** hand-write a note into `.mentor/` — `/mentor:handoff` owns a resume point for
  **unfinished** work here, `/mentor:defer` owns work that **outlives this topic** (a flaky test
  *on the base branch* — a pre-existing defect whose **fix** is work to build, never a check to run;
  debt; a follow-up), and they are not interchangeable. A hand-composed name lands in Step 2's
  skipped list instead of the resume list; a follow-up misfiled as a handoff after the work shipped
  is retired by the next handoff's supersede sweep. Either way it is lost.
- Do **not** rename a skipped non-conforming file unasked — surface it and wait for the user.
- Do **not** echo a live secret found in a note — warn and redact.
- Do **not** copy the note into the repo working tree.
- Do **not** auto-start a topic's drain right after loading its note — always offer, never assume;
  and never skip the note to jump straight to the drain when both match.
- Do **not** compute a drain queue once and reuse it across the whole subtree or group — re-survey
  after every item, or a fix parked mid-drain never gets picked up.
- Do **not** let one approval cover more than one queued item — each drained item gets its own
  `begin-plan.sh` → `mentor:planning` approval question.
- Do **not** re-derive "open"/"closed" from a plan's own ticks or `.state.json` — always go through
  `subtree`/`overview --json`; that classification has one owner.
