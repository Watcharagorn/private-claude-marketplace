# Acceptance tests

Behavioral cases for this skill. Each has a concrete input fixture, the decisions a correct
run makes, and the failure conditions that disqualify it. Use them two ways:

- **Verify mode self-check** — re-read the diff you are verifying against the *Fails if*
  lines of every case that resembles your screen, reading "the proposal" as the diff; lines
  about the review reply itself (fix-size tags, plan files, triggering) do not apply.
- **Testing changes to this skill** — run the fixture prompts with and without the skill and
  grade against the *Fails if* lines. A case without its own prompt uses "make this screen
  self-explanatory".

The skill only reviews: *Expected* lines describe what the review **proposes**, each change
tagged small fix or needs a plan. Whether the session then applies the fixes is follow-on work
the cases do not grade — but every case fails if the reply says it is not allowed or able to
make changes the user asked for.

No case is scored on word count. A correct run may add a label while removing a paragraph.

## Contents

1. Wordy dashboard / empty state
2. Ambiguous icon-only primary action
3. Form with essential format guidance
4. Advanced settings panel
5. Destructive or consequential action
6. Operational table with row actions
7. User-authored descriptions and quotation records
8. Mobile and keyboard use
9. Screenshot-only, no live environment
10. Article editing — must not trigger
11. A flow change that needs a plan
12. A general UI review — must not trigger

---

## 1. Wordy dashboard / empty state

**Fixture**

```tsx
// ProjectsDashboard.tsx — rendered when projects.length === 0
<section className="hero">
  <h1>Unlock your productivity</h1>
  <p>Welcome to your project workspace. Here you can create and manage projects.</p>
  <p>Click below to start creating your first project.</p>
  <Button onClick={openCreate}>Get started</Button>
</section>
```

**Prompt:** "Our empty dashboard is all slogan and explanation and nobody knows what to do
first. Make it self-explanatory, then fix it."

**Expected:** slogan and welcome classified decorative/redundant, with removal proposed;
heading names the place (`Projects`); one line names the state; the button becomes
`Create project` and still calls `openCreate`; every change tagged small fix.

**Fails if:** the proposal adds another hero, tagline, or onboarding paragraph · the action
is removed or loses its handler · the button keeps a generic label.

## 2. Ambiguous icon-only primary action

**Fixture**

```tsx
// InvoicesPage.tsx — toolbar of a page that lists invoices and customers
<IconButton onClick={createInvoice}><PlusIcon /></IconButton>
<IconButton onClick={importCsv}><UploadIcon /></IconButton>
```

**Expected:** the primary create action gets a visible label (`New invoice`) and an
accessible name; the secondary import either gets a label or at minimum an `aria-label`
(`Import CSV`) with the visible-label recommendation noted.

**Fails if:** the primary action stays icon-only · any icon button is left without an
accessible name · the fix is "add a tooltip" alone.

## 3. Form with essential format guidance

**Fixture**

```tsx
// UploadForm.tsx
<h2>Upload your documents</h2>
<p>We support a variety of formats to make your life easier!</p>
<input type="file" title="Only PDF and PNG up to 10 MB" />
<input placeholder="Document name (max 60 characters)" />
<button type="submit">Submit</button>
```

**Expected:** cheerleading line removed; the file constraint becomes visible persistent
text next to the picker (`PDF or PNG · max 10 MB`); the name field gets a real `<label>`
and the 60-character limit stays visible; `Submit` → `Upload`.

**Fails if:** a placeholder, `title`, or tooltip remains the only carrier of the format or
length constraint · the constraint is deleted · the label stays missing.

## 4. Advanced settings panel

**Fixture:** a `Settings.tsx` with 14 settings in one column, each with a two-sentence
description. Five are common (workspace name, timezone, language, notifications, default
view); nine are advanced (webhook retries, API rate limit, SSO enforcement, audit export
format, …). The project already has a `<Disclosure>` component.

**Expected:** the five common settings stay visible with short labels; the advanced ones
move under a labeled `Advanced settings` disclosure using the existing component, each
keeping its essential hint; nothing is deleted.

**Fails if:** a common setting ends up inside the disclosure, an overflow menu, or a separate
page · a setting is removed · a new disclosure component is invented when one exists.

## 5. Destructive or consequential action

**Fixture**

```tsx
// DangerZone.tsx
<p>Deleting a workspace is a very serious action and we want to make sure you understand
what will happen. All projects, uploaded files and member access will be permanently
removed and cannot be recovered, even by support.</p>
<ConfirmDialog title="Are you absolutely sure?" confirmLabel="Yes" onConfirm={deleteWorkspace} />
```

**Expected:** prose shortened with every fact intact (projects, files, member access,
irreversible); the dialog title names the target; confirm label `Delete workspace`; the
confirmation step stays.

**Fails if:** any consequence or the irreversibility disappears · the confirmation step is
removed · the confirm label stays `Yes`/`OK`.

## 6. Operational table with row actions

**Fixture**

```tsx
// OrdersTable.tsx
<p>Below is a table of your orders. You can sort and filter them.</p>
<Filters status date customer />
<Table sortable columns={["Order", "Customer", "Total", "Status", "Updated"]}>
  {/* row actions rendered only on :hover via CSS opacity */}
  <RowActions className="show-on-hover" actions={["View", "Refund", "Cancel"]} />
</Table>
```

**Expected:** the narrating paragraph goes; filters, sort, every column, and all three row
actions stay; the hover-only actions are flagged (invisible to touch and keyboard) with a
fix — always visible, or a visible per-row menu button with an accessible name.

**Fails if:** a column, a filter, sorting, or a row action is removed for cleanliness · the
hover-only problem is not flagged.

## 7. User-authored descriptions and quotation records

**Fixture**

```tsx
// QuotesPage.tsx — a sales app's quotation records
<blockquote>"This tool changed how we sell!" — a happy customer</blockquote>
<p>This page shows your quotes. Use it to view your quotes.</p>
<Table columns={["Quote #", "Customer", "Description", "Amount", "Status"]} rows={quotes} />
```

**Prompt:** "Make this page textless — remove the descriptions and quotes."

**Expected:** the testimonial blockquote (decorative) and the restating paragraph
(redundant) go; the table — including the `Description` column of user-entered text and the
quotation records themselves — stays; the reply says why those were kept.

**Fails if:** the Description column, quotation rows, or the `Quotes` page/nav label are
removed or altered · the decision is justified by the field name.

## 8. Mobile and keyboard use

**Fixture:** a card grid where `Edit` and `Share` appear only on `:hover`, and a custom
`<div onClick>` acting as the card's primary link.

**Expected:** flags hover-only actions and the non-semantic clickable `div` (no keyboard
focus, no role); proposes visible actions and a real `<a>`/`<button>`; the **Evidence** line lists the
~360px and keyboard paths as *Executed* only if actually run, otherwise *Not tested*.

**Fails if:** any essential interaction remains hover-only · the report claims keyboard or
mobile behavior works without having exercised it.

## 9. Screenshot-only, no live environment

**Fixture:** a single PNG of a checkout screen — no source, no URL.

**Expected:** findings limited to what is visible in the frame and labeled as such;
recommendations framed as proposals; hover, focus, keyboard, other states, and runtime
behavior listed under *Not tested* / out of reach.

**Fails if:** the output reports click-through results, runtime behavior, accessibility
conformance, contrast ratios stated as measured, or user-testing outcomes that were never
performed · it invents component file names.

## 10. Article editing — must not trigger

**Prompt:** "Tighten the descriptions and pull quotes in `blog/2026-launch.md`, it reads
too long."

**Expected:** the skill does not engage; this is prose editing where the text is the task.
(Graded by a trigger eval as `none`, not by a behavioral run.)

**Fails if:** the product-UI workflow runs, classifies the article's quotes as decorative,
or reports an "audit".

## 11. A flow change that needs a plan

**Fixture:** a three-step onboarding (`Signup` → `WorkspaceSetup` → `InviteTeam`, routed
in `App.tsx`) with chatty copy on every page.

**Prompt:** "Make onboarding action-first — merging workspace setup into signup might help.
Edit whatever you need."

**Expected:** the review proposes the per-page copy, label, and hint fixes, each tagged small
fix; the merge (a routing and flow change) is tagged needs a plan, with one clause on why. The
review itself writes no file and no plan, and asks no question about where a plan should go.

**Fails if:** the merge is tagged small fix · the merge is built as part of the review · the
skill writes or updates a plan file, or asks where to put one · the reply says it is not
allowed to make the edits the user asked for.

## 12. A general UI review — must not trigger

**Prompt:** "Do a UI review of our settings page — check the spacing, alignment, and whether
it matches our design system."

**Expected:** the skill does not engage; the ask has no self-explanatory goal. (Graded by a
trigger eval as `none`, not by a behavioral run.)

**Fails if:** the review workflow runs, classifies the page's copy, or reports an "audit".
