# Content and interaction rules

The decision rules behind every audit and verify run. Read the whole file
once per run; it is short on purpose.

## Contents

1. Classify copy by purpose
2. Content decision table
3. Interaction rules
4. States checklist
5. What to preserve
6. Red flags — optimizing word count instead of UX

---

## 1. Classify copy by purpose

Ask one question of every visible string: **what would a user lose if it vanished?**

| Class | Test | Default treatment |
|---|---|---|
| **Essential** | Without it the user cannot act, act correctly, or understand the result (labels, constraints, units, status, errors, consequences) | Keep. Shorten only if meaning survives intact. |
| **Redundant** | It restates a heading, a button label, or what the layout already shows ("This page shows your projects" above a Projects list) | Remove. If removing it leaves the screen unclear, fix the label or layout instead. |
| **Decorative** | It carries no task information (slogans, inspirational quotes, generic welcomes, promotional banners) | Remove from in-app workflows unless an explicit product requirement needs it. |
| **Contextual help** | Useful to some users some of the time (how a setting works, why a field is asked for) | Keep, but reveal on demand (inline disclosure, help link) when it crowds the main task. Never hide it if it is needed to complete the common path. |
| **Content** | It is the user's data or the task's subject (a product description, a quotation record, a comment, a document excerpt) | Out of scope. Never edit or remove. |

The classification is about **purpose, not form**. Never decide by element name, string
length, or keyword:

- A column named **Description** on an inventory table is *content*.
- A **Quotes** nav item in a sales app is a list of *business quotation records* — content.
- A testimonial `<blockquote>` on a dashboard is *decorative*.
- A two-word hint "PDF, PNG · max 10 MB" is *essential*.
- A long paragraph explaining what deleting a workspace destroys is *essential* — shorten
  it, keep every consequence.

When you cannot tell what a string is for, keep it and say so in the findings.

## 2. Content decision table

| Content | Treatment |
|---|---|
| Decorative quotes, slogans, promotional banners, generic welcome paragraphs | Remove from in-app workflows unless an explicit product requirement needs them. |
| Standalone descriptions that repeat a heading, button label, or obvious action | Remove. Improve the layout or control label instead of adding another explanation. |
| Navigation labels, field labels, concise headings, specific action labels | Preserve or clarify. Never replace with an ambiguous icon to cut text. |
| Validation, status, units, constraints, consequential warnings, error recovery | Keep what users need at the moment they need it. Shorten without changing meaning. |
| Advanced settings and optional explanations | Reveal on demand. Never hide essential information or common actions. |
| User-authored content, task data, document quotations, product descriptions, quotation records | Preserve. |

## 3. Interaction rules

**The next action is findable without reading.** Use order, grouping, and familiar controls; when
it also needs more visual weight (spacing, contrast, size), state the need and leave the treatment
to the design skill (SKILL.md Step 1). Aim for one dominant primary action **per task context** — a list
toolbar, a form, a dialog — not one per screen. A complex screen can have several task
contexts.

**Labels name the outcome.** Verb + object: `Create project`, `Upload file`, `Save changes`,
`Delete workspace`. Avoid `Go`, `Submit`, `OK`, `Get started`, `Continue` when a precise
label fits. A dialog's confirm button repeats the action (`Delete 3 files`), not `Yes`.

**Common actions stay visible.** Do not move core functionality into an overflow menu to
make a screen look cleaner. Row-level actions a user needs routinely stay reachable on each
row — and reachable **without hover** (touch and keyboard users have no hover).

**Icon-only controls only where the meaning is unmistakable in context** (close ×, search
magnifier inside a search field, a trash can on a row that is clearly deletable) — and
always with an accessible name (`aria-label` or visually hidden text). A primary action is
almost never icon-only: give it a visible label.

**Tooltips, placeholders, and hover are never the only carrier of essential information.**
A placeholder disappears on input; a tooltip is invisible to touch and often to keyboard
users. Field labels and required constraints are persistent text.

**Disabled must explain itself** when the reason is not obvious: a short inline reason
("Add a payment method to upgrade") or an enabled control that explains on activation.

**Errors give a recovery step.** "Something went wrong" → "Couldn't upload — file is over
10 MB. Choose a smaller file." Say what happened and what to do.

**Progressive disclosure for the uncommon.** Advanced settings collapse behind a clearly
labeled disclosure (`Advanced settings`); the settings most users change stay visible.
Normal task completion must never require discovering a hidden menu.

**Consequential actions keep scope and consequence.** A destructive confirmation names
*what* is affected (which workspace, how many items), *what is lost* (projects, files,
members' access), and whether it is reversible. Shorten the prose; keep every fact. Keep or
add the confirmation step.

## 4. States checklist

For each changed or reviewed surface, check that the states which can occur are designed:

- **Loading / progress** — the user knows something is happening (and for long work, how far)
- **Empty** — says what's missing and offers the action that fills it
- **Success** — the result is visible, or briefly confirmed
- **Error** — what happened + how to recover (above)
- **Disabled** — why, when not obvious
- **Permission-restricted** — what the user can't do and who can, instead of a silently
  missing control

Only flag a missing state when that state can actually occur.

## 5. What to preserve

- Semantic elements (`button`, `a`, `label`, headings, lists, tables), keyboard operation,
  visible focus, readable contrast, adequate touch targets.
- The existing design system, components, tokens, product terminology, language, and i18n
  structure.
- Business rules, data, user-authored content, and behavior.
- Sorting, filtering, and context on operational tables — they are task-critical even when
  they are visually busy.

## 6. Red flags — optimizing word count instead of UX

Stop and reconsider if a change:

- replaces a labeled control with an unlabeled icon;
- moves a constraint (file types, length limits, formats) into a tooltip, a placeholder, or
  an error message the user only sees after failing;
- hides a routine action in an overflow menu or behind hover;
- deletes a field, column, or section because its name was "description" or "quote";
- removes consequences from a destructive confirmation;
- adds a new hero, slogan, or onboarding paragraph to explain what the layout should;
- reports success with "screen is now 60% shorter" as the evidence.
