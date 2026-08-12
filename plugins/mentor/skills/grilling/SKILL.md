---
name: grilling
description: >
  Stress-test and sharpen a plan or design by interrogating the user one question
  at a time, before any code is written. Use when the user wants to pressure-test
  an approach or resolve open design decisions, or uses a "grill" trigger —
  "grill me", "grill this plan", "stress-test this", "pressure-test this approach",
  "poke holes in this". Walks the decision tree one branch at a time, recommends an
  answer for every question, and explores the codebase (via a dispatched subagent)
  rather than asking what the code can answer. This is a conversation, not an
  implementation — it makes no repo edits. For an automated agent audit of a
  finished plan, use /plan-review instead.
---

# Grilling — Sharpen the Design Before You Build

This skill interrogates **you** (the user) to pressure-test a plan or design and resolve its open decisions *before* a plan is locked or any code is written. It walks down each branch of the design tree one decision at a time, recommending an answer for every question, until you reach a shared understanding.

It is a **conversation**, not an implementation. It makes **no repo edits** and does not draft or rewrite the plan — when it surfaces a changed decision, the plan flow re-renders it.

**How this differs from `/plan-review`** (so you always know which to reach for):

> **`/mentor:grill`** sharpens the *decisions* — an interactive interview with you, before the plan is locked.
> **`/plan-review`** audits the *finished plan* — staged reviewer agents (a judgment pass whose edits you verdict one question at a time at a fold gate, then a mechanical pass whose safe fixes are auto-folded and whose decision-level findings are asked one by one) at the approve gate, no human interview.

Grilling resolves "have we actually thought this through?"; plan-review answers "is the written plan any good?". They are complementary, run at different moments, and never replace each other.

Within the plan flow itself, `plan` Step 3.5 owns *post-research* decision resolution — the same one-question-at-a-time, recommended-first protocol, run with research evidence in hand. Grilling owns *pre-research* ambiguity in the request; a decision resolved in either place is never re-asked by the other.

## When to use

- The user typed `/mentor:grill`, or used a grill trigger ("grill me", "grill this plan", "stress-test this", "poke holes in this approach").
- A design or approach has unresolved choices and the user wants to pressure-test it **before** building.
- Naturally upstream of `/mentor:plan`: grill first to sharpen the thinking, then plan.
- A current mentor plan exists and the user wants its decisions challenged before approving (run grill, then return to the proceed gate).

## When NOT to use

- Trivial / single-file changes where the interview costs more than the change.
- The plan is already approved and the user wants implementation — point them at the proceed gate or `/mentor:ship`.
- The user wants an automated audit of a written plan against fixed quality lenses — that is `/plan-review`.
- Pure exploration with no plan or design to interrogate.

---

## Step 1 — Resolve the subject

Figure out *what* you are grilling, in this order:

1. **Explicit argument.** If the user passed a topic (via `/mentor:grill <topic>` or in the message), grill that design.
2. **Current mentor plan.** Otherwise, ask mentor which plan is current:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" current
   ```
   `Read` the `PLAN:` path it prints (the `.md` is canonical) and grill it. Do **not** edit it.
   If `GROUP:` is not `-`, the plan is one slice of a `/plan-split` group and the script
   lists its siblings — ask which slice to grill rather than picking one, since grilling
   the wrong slice wastes the whole interview.
3. **The conversation.** If there is no argument and no plan, grill the design described in the conversation so far.

If there is genuinely nothing to grill, say so in one line and stop.

**Check for related plans before interrogating**, whichever branch above resolved the
subject — branches 1 and 3 in particular never touch plan state on their own:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" list
```

A plan on the same or an adjacent topic — especially one `draft`, `in_progress`, or
`superseded` — carries context worth having before the interview starts: prior
decisions already made, or why an earlier attempt stalled or was rejected. If one
looks related, read its `.mentor/plans/<slug>/.state.json` `note` field directly
(`jq -r .note`) rather than reconstructing its history from the plan body and old
handoffs by hand — the note already holds the reviewer's own summary.

---

## Step 2 — The interview protocol

Interview the user relentlessly about every aspect of this plan until you reach a shared understanding. Walk down each branch of the design tree, resolving dependencies between decisions one-by-one. For each question, provide your **recommended answer** — the most practical and clean solution, never trade maintainability or reliability for implementation speed.

- **Ask the questions one at a time**, waiting for feedback on each question before continuing. Asking multiple questions at once is bewildering — favor `AskUserQuestion` with a single focused question (your recommended option first).
- **Every question stands on its own.** The user answers from the question screen alone — never sent to a file, a plan section, a coined id or code (`G14`, `P2`), or an earlier turn to learn what the question means. Name things in plain language, quote the evidence that decides it rather than citing where it lives, and say in each option what it changes and what it costs. This binds the ids *you* mint hardest: an interview that numbers its own questions or decisions (`G7`, `D23`) has built a private index the user never received, so say "the cross-tenant Secrets read", not "G14" — the header takes a plain-language handle, and a bare number belongs in your notes, not in anything the user reads. A definition you gave twenty turns ago is not one they still have.
- **Order by dependency.** Resolve the decisions that other decisions hang off of first; let each answer narrow the next question.
- **If a question can be answered by exploring the codebase, explore the codebase instead of asking.** Step 1's subject reads are yours to do directly; past those, **needing a second file — or any read beyond ~100 lines — is the dispatch signal**: hand that question to an `Explore` subagent and keep interviewing while it runs, then fold what it finds into your next question. The budget is about volume, not curiosity: an interview that reads hundreds of lines inline is too heavy to hand off. (Dispatches follow `dispatch-agents`' "Async runtime & lifecycle" rules: deliver-before-idle, one nudge on a silent idle, close out when consumed.) Dispatches return the same shape planning's research does — FINDINGS (≤ ~400 words) / EVIDENCE (`file:line`) / OPEN QUESTIONS — so a shipped-capability overlap surfaces as a named fact instead of dissolving into paraphrase.
- **Before folding a dispatched agent's findings into your next question, screen FINDINGS for a shipped-capability overlap.** If they name a shipped skill, command, feature, endpoint, or script the user could already invoke today to get what the subject under design promises, your next `AskUserQuestion` must be the overlap fork itself — extend the shipped capability, supersede it, or build alongside it, recommended option first — before any further branch question assumes the capability is new. An overlap found here costs one question; the same overlap found at the plan's research step costs the whole interview and everything already built on it.
- Keep going until the material decisions are resolved or explicitly deferred — do not stop at the first easy answer.
- **If a question is declined, or the interview breaks off before Step 3's Close**, don't let resolved decisions vanish silently: summarize what's been resolved so far — and any codebase research already done — in your closing message, and suggest `/mentor:handoff` to persist it for a fresh agent to pick up, rather than letting the turn end with nothing recoverable.

---

## Step 3 — Close

When you reach shared understanding:

1. Summarize the **resolved decisions** and any **deferred / open items** in a short recap.
2. If a mentor plan was the subject, **surface the deltas** between the plan and what you just resolved, and tell the user to fold them in by re-running the plan flow (`/mentor:plan`) or, if mid-plan, re-asking the proceed gate. **Do not edit the plan file yourself** if this worktree's gate is armed — surface the changes and let the plan flow re-render them. A second hazard the gate does **not** cover: a plan whose sidecar `owner` is a *different* worktree (check `.mentor/plans/<slug>/.state.json`'s `owner` field the same way you already read its `note` above) — no gate blocks editing that file, since the plan-gate deny is scoped to the owning worktree's writes, not to the file itself, and this worktree may be wide open while that plan is someone else's live draft. Treat a foreign-owned plan the same as an armed gate: surface the deltas, don't edit.
3. Point to the natural next step: `/mentor:plan` (to author/refresh the plan) or, if a locked plan now looks solid, `/plan-review` then approve.
4. **If the grill settled it and the work turns out trivial** — one file, nothing material left to decide — say so and offer to implement it directly rather than routing a two-line change through the plan flow. Two conditions, both required: this worktree's gate reads **not armed** — check it fresh, `current` (Step 1) never reports the marker at all:
   ```bash
   [ "$(bash "${CLAUDE_PLUGIN_ROOT}/hooks/plan-state.sh" gate)" = "ARMED" ] && echo "GATE: ARMED — trivial-implement branch does not apply"
   ```
   and you state plainly that plan ceremony was skipped and why. `ARMED_ELSEWHERE` (only a sibling worktree's marker is live) does **not** count as armed here — this worktree's own edits are unblocked, so the trivial-implement branch still applies. If the gate reads `ARMED` for THIS worktree, this branch does not apply — `plan-gate.sh` blocks repo edits, so surface the deltas per item 2 and let the plan flow re-render them.

## Done when

- A shared understanding is reached.
- Every material decision is either resolved with the user or explicitly deferred.
- Questions were asked **one at a time**, each with a recommended answer.
- Codebase-answerable questions were answered by a dispatched `Explore` agent, not by asking the user or by bulk-reading.
- A declined question or an interview cut short still left resolved decisions recoverable — recapped and pointed at `/mentor:handoff`, not silently lost.

### Do NOT

- Do **not** implement anything or edit the repo — grilling is conversation + read-only exploration.
- Do **not** edit or rewrite the plan file mid-grill; surface deltas and let the plan flow re-render.
- Do **not** ask multiple questions in one turn.
- Do **not** run a `/plan-review`-style agent audit here — if the user wants that, point them to `/plan-review`.
