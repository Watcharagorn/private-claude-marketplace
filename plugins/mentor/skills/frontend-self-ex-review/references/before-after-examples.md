# Before / after examples

The target shape of a change — and, just as important, what must survive it. Each example
gives the reason in one line; carry that reason into your findings.

## 1. Wordy empty state → direct next action

**Before**

```text
Unlock your productivity
Welcome to your project workspace. Here you can create and manage projects.
Click below to start creating your first project.
[Get started]
```

**After**

```text
Projects
No projects yet.
[Create project]
```

**Why:** the slogan is decorative, the welcome restates the page, "click below" narrates the
button, and `Get started` hides what the button does. The heading names the place, one line
names the state, the button names the outcome.

## 2. Counterexample — the format hint stays

**Before**

```text
Upload your documents
We support a variety of formats to make your life easier! Please note that only
PDF and PNG files up to 10 MB can be uploaded at this time.
[Choose file]  [Submit]
```

**After**

```text
Upload documents
[Choose file]  PDF or PNG · max 10 MB
[Upload]
```

**Wrong after** — `[Choose file] [Upload]` with no hint, so users discover the restriction
through an error.

**Why:** the cheerleading sentence goes; the constraint is essential and must be visible
*before* the user picks a file. `Submit` becomes `Upload`.

## 3. Icon-only primary action → labeled

**Before**

```html
<button class="fab"><PlusIcon /></button>
```

**After**

```html
<button class="btn-primary"><PlusIcon aria-hidden="true" /> New invoice</button>
```

**Why:** on a page with several possible "add" targets, `+` makes the user guess. A visible
label costs two words; the icon can stay as reinforcement. (Fewer words that require more
guessing is a regression.)

## 4. Destructive confirmation — shorter, same facts

**Before**

```text
Are you absolutely sure you want to do this?
Deleting a workspace is a very serious action and we want to make sure you understand
what will happen. Once you delete your workspace, all of the projects inside it, all
uploaded files, and all member access will be permanently removed and we will not be
able to recover any of it for you, even if you contact support.
[Cancel] [Yes, I'm sure]
```

**After**

```text
Delete "Acme Marketing"?
Permanently deletes 14 projects, all uploaded files, and access for 6 members.
This can't be undone.
Type the workspace name to confirm: [__________]
[Cancel] [Delete workspace]
```

**Why:** every consequence survives (scope, what's lost, irreversibility), the filler goes,
and the confirm button names the action instead of `Yes`.

## 5. Generic error → recovery

**Before:** `Error: something went wrong. Please try again later.`
**After:** `Couldn't save — you're offline. Changes are kept on this device; we'll retry when you reconnect.`

**Why:** the user learns what happened and what (if anything) they need to do.

## 6. Placeholder-as-label → persistent label + hint

**Before**

```html
<input placeholder="Phone number (include country code, e.g. +66)" />
```

**After**

```html
<label for="phone">Phone</label>
<input id="phone" placeholder="+66 81 234 5678" aria-describedby="phone-hint" />
<small id="phone-hint">Include country code</small>
```

**Why:** the placeholder vanishes as soon as the user types; the label and the constraint
must persist. The placeholder may stay as an *example*, never as the instruction.

## 7. Unexplained disabled button

**Before:** a greyed-out `[Publish]` with nothing else.
**After:** `[Publish]` greyed out + `Add a title to publish` beside it.

**Why:** disabled with no reason reads as broken.

## 8. Settings wall → common visible, advanced disclosed

**Before:** 18 settings in one long column, each with a two-sentence description.
**After:** the 5 settings most users change stay visible with short labels and essential
hints; the rest sit under `Advanced settings ▸`, each keeping its hint inside the
disclosure.

**Why:** the common path needs no hunting; nothing is deleted, only reordered by frequency.

## 9. Counterexample — "Description" is the user's content

**Before:** an inventory table with columns `SKU · Name · Description · Stock`, and a page
intro "Here you can see all of your products and their descriptions."

**After:** the intro goes (it restates the heading and the table). The **Description column
stays** — it is the user's product data.

**Wrong after** — dropping the Description column because the task said "remove
descriptions".

## 10. Counterexample — "Quotes" are records

**Before:** a sales app's `Quotes` page listing quotation records (customer, amount,
status), headed by a decorative testimonial: *"This tool changed how we sell!" — a happy
customer*.

**After:** the testimonial goes. The quotation records, their notes, and the `Quotes` nav
label stay.

**Why:** "no quotes" refers to decorative quotations, never to business records that happen
to share the word.
