# Page contract

The templates and rules the main thread uses to write `00-head.html`, the scenario shells, `10-answers.html`,
`90-decisions.html` and `99-foot.html`, and the rules every section fragment follows. `{{…}}` marks a value
the main thread fills in; everything else is copied as written. The two `{{include …}}` lines are copied as
they stand: assembly (§1) replaces each with a file from the skill's `assets/`, the page's fixed CSS and its
one script, so the main thread neither reads nor retypes them.

Read the sections you apply when you reach them: the main thread needs §1–§8 when it writes its fragments and
assembles (§2 for the titles, ledes, anchors and radio names its own parts use, §4's bullets for the variant
radios), section workers get §2 by path in their briefs, and §9 is for publishing.

Contents: 1 Parts and assembly · 2 Fragment rules · 3 `00-head.html` · 4 Switching CSS · 5 Scenario shells ·
6 Questions and decisions · 7 `99-foot.html` · 8 Checks · 9 Publishing constraints

**Layout.** One scrolling page. A contents sidebar stays in view beside it and lists the sections the page
includes, with every scenario nested under Scenarios and each edge card under its parent; it folds into a top
bar at phone width (§3). Scenario cards stack in order, each card's hops stack in path order, and a sequence
sits under the scenario whose trigger starts it. Only a card's variants, its Before/After view and its width
switch in place, because they redraw the same frame (§4). The theme is in §3.

## 1. Parts and assembly

| Part | Writer | Holds |
|---|---|---|
| `00-head.html` | main thread | doctype, head, the include line for `assets/page.css` (tokens, page CSS, the switching block), the contents sidebar, the title block, `<main>` open |
| `10-answers.html` | main thread | Questions for you (read-only list) |
| `20-scenarios/000-open.html` | main thread | section open, title and lede, legend, cards container open |
| `20-scenarios/001-style-<group>-w<n>.html` | cells worker n | one `<style>` of chrome CSS for its primitives |
| `20-scenarios/001-style-flows.html` | sequences worker | one `<style>` for the sequences drawn inside cards |
| `20-scenarios/sNN-0-shell.html` | main thread | a card's article open, title bar with its switches, Who / Does / Result, path, stage open |
| `20-scenarios/sNN-h<n>.html` | cells worker | one hop: its heading, every frame and note, every variant and view |
| `20-scenarios/sNN-s<k>.html` | sequences worker | flow `seq-<k>`, owned by this card, drawn below its hops |
| `20-scenarios/sNN-z-close.html` | main thread | stage close, comment box, Copy, article close |
| `20-scenarios/zzz-close.html` | main thread | cards container and section close |
| `30-architecture.html` · `50-data.html` | section workers | one `<section>` each |
| `40-sequences.html` | sequences worker | one `<section>` of the flows no scenario owns; absent when every flow has an owner |
| `90-decisions.html` | main thread | Settled with you · Defaults I set · Stated in the plan (a plan with no decision table of its own, §6) |
| `99-foot.html` | main thread | footer, "Not affected by this plan", provenance totals, `</main>`, the include line for `assets/page.js` (the one page script), `</html>` |

`NN` is the parent scenario's two-digit number and an edge card adds its letter (`s04a-0-shell.html`). A C-locale
sort puts `000-open` and `001-style-*` first, then each card's `-0-shell`, its `-h<n>` hops, its `-s<k>` flows
and its `-z-close`; `-` sorts before `a`, so S4a follows S4 and precedes `s05`. Only the parts a section plan
includes exist.

Assemble with one null-delimited command, because an absolute `$review_dir` may contain spaces. The `awk`
replaces each `{{include <file>}}` line with that file from `$assets` (`SKILL.md` §0):

```bash
find "$review_dir/_parts" -type f -name '*.html' -print0 | LC_ALL=C sort -z | xargs -0 cat \
  | awk -v d="$assets" '/^\{\{include [a-z.]+\}\}$/{f=d "/" substr($0,11,length($0)-12); while((getline l < f)>0) print l; close(f); next} {print}' \
  > "$review_dir/review.html"
```

Before assembly, delete the parts of anything retired in `_ids.md`: a retired hop's `sNN-h<n>.html`, a flow
whose owner changed (its old `sNN-s<k>.html`), and for a retired card its `-0-shell`, `-h*`, `-s*` and
`-z-close` files.

## 2. Fragment rules

- **One section per fragment.** A section worker writes one `<section id="sec-<name>" aria-labelledby="sec-<name>-h">`
  (`architecture`, `sequences`, `data`) that opens with its title and lede (below).
- **Section titles say what the section is.** Every section opens with `<h2 id="sec-<name>-h">` holding its title
  from this table, then one `<p class="pg-lede">`: a sentence in plain words saying what the section shows for
  this subject. The heavy rule and serif title come from `00-head.html`, so the reader never mistakes a
  mockup's own heading for the page's.

  | Section | Title | The lede says |
  |---|---|---|
  | `answers` | Questions for you | how many questions are open, and that they are answered in chat |
  | `scenarios` | Scenarios | what a scenario follows, and how many cards and edge cards there are |
  | `architecture` | Architecture | which parts of the system change, from which level to which |
  | `sequences` | Sequences | which flows no single scenario starts (only those appear here) |
  | `data` | Data and contracts | what is stored, sent and checked that changes |
  | `decisions` | Decisions | what is settled, which defaults were set, and what the plan states without a decision table |

- **Scoped CSS.** A fragment's `<style>` selects only under its own `#sec-<name>`. Cells workers scope chrome
  under `#sec-scenarios .pv-<primitive>`; the sequences worker scopes its in-card flows under
  `#sec-scenarios .pv-flow`, in `001-style-flows.html`. The one exception is the project's built framework CSS
  (§3), which stays unscoped like the CDN runtime it replaces and is inlined once, in the style file of the
  cells worker the main thread names in its brief.
- **Prose wraps at phone width.** Page text around the mockups (notes, captions, sources, section prose,
  tables) never sets `white-space:nowrap` outside a scroll box, so a long path or name wraps instead of
  widening the page. A long code block or diagram scrolls inside its own `overflow-x:auto` box.
- **Scripts.** A section fragment may hold at most one `<script>`: an IIFE wrapped in try/catch, or the
  Mermaid fallback's one module script (§3). Hop files, flow files and style files hold none. Switching never
  depends on a script.
- **Ids.** Every id is unique on the page. Diagram ids carry a per-diagram prefix (`ctx-`, `cont-`, `comp-`,
  `seq-<k>-`, `er-`), including `<title>`, `<desc>`, `<marker>`, `<clipPath>` and gradient ids. Hop-file ids
  use `<scenario>-h<n>-<variant>-<view>-`. Page anchors are `sec-<name>`, `scn-<scenario>` for a card,
  `scn-<scenario>-h<n>` for a hop, and `seq-<k>-flow` for a flow; only `00-head.html` and the shells link to
  them.
- **Radio names** are per card (`S4a-variant`, `S4a-view`, `S4a-width`), because id prefixes do not stop `name`
  collisions. Radio ids are `<scenario>-<axis>-<data-id>` (`S4a-variant-ios`, `S4a-view-before`).
- **Reserved classes** (`.pv-scn`, `.pv-ax`, `.pv-hop`, `.pv-hop-h`, `.pv-v`, `.pv-cap`, and every `.pg-*` class) are
  selected only by the switching block and `00-head.html`.
- **Provenance attributes** (`data-pv`, `data-gap`) are styled only by `00-head.html`. These are the one page
  rule allowed to reach inside `.pv-payload`, and they only mark (outline, underline, hatch), never lay out.

## 3. `00-head.html`

```html
<!doctype html>
<html lang="{{lang, default en}}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{Subject title}} preview</title>
<meta name="mentor-subject" content="{{subject-slug}}">
<meta name="mentor-plan-sha256" content="{{64-hex sha256 of plan.md, or none for a non-plan subject}}">
{{CDN pins, scripts only — see below; omit when the page has no screen frame}}
{{diagram-design's Google Fonts <link>, only when the renderer is diagram-design}}
<style>
{{include page.css}}
</style>
</head>
<body>
<a class="pg-skip" href="#main">Skip to the page</a>
<div class="pg">
<aside class="pg-side">
<details class="pg-toc" open>
<summary><span>Contents</span><span class="pg-here"></span></summary>
<p class="pg-side-title">{{Subject title}}</p>
<nav aria-label="Page contents"><ol>
<li><a href="#sec-answers">Questions for you <span class="pg-n">{{open questions}}</span></a></li>
<li><a href="#sec-scenarios">Scenarios <span class="pg-n">{{cards}}</span></a>
  <ol><li><a href="#scn-S1"><span class="pg-id">S1</span> <span>{{title}}</span></a>
    <ol><li><a href="#scn-S1a"><span class="pg-id">S1a</span> <span>{{edge title}}</span></a></li></ol></li>
  {{… one li per parent, in order, each edge card nested under it}}</ol></li>
<li><a href="#sec-architecture">Architecture</a></li>
{{… one li per other included section, in page order: Sequences, Data and contracts, Decisions}}
</ol></nav>
</details>
<div class="pg-side-actions">
<button type="button" class="pv-copy-all" hidden>Copy all comments</button>
<button type="button" class="pg-theme" hidden>Switch theme</button>
<textarea class="pv-fallback" readonly hidden aria-label="Copy this text"></textarea>
</div>
</aside>
<div class="pg-main">
<header class="pg-head">
<h1>{{Subject title}}</h1>
<dl class="pg-meta"><div><dt>Subject</dt><dd>{{subject-slug}}</dd></div><div><dt>Generated</dt><dd>{{YYYY-MM-DD HH:MM}}</dd></div><div><dt>Diagrams</dt><dd>{{diagram-design (profile NAME) | hand-drawn SVG | hand-drawn SVG, Mermaid for N}}</dd></div>{{<div><dt>Built from</dt><dd>plan.md @ FIRST8HEX, YYYY-MM-DD HH:MM</dd></div> — plan subjects only}}</dl>
<p class="pv-noscript">Copy needs scripts, select the text instead.</p>
<p id="pv-live" class="pg-sr" aria-live="polite"></p>
</header>
<main id="main">
```

- **Contents.** The sidebar lists only the sections the page includes, in page order, under the titles in §2.
  Scenarios nests every card: parents in order, each edge card under its parent, each link to `#scn-<id>`. Keep
  the space between the two spans, so the current-place label reads "S1 Sign in…". Without scripts the links
  still work; with them, the link for the part on screen is marked and, at phone width, named in the top bar.
- **CDN pins.** Only the project's own CSS framework and icon set, at an exact version, loaded as
  `<script>` (a published Artifact blocks CDN stylesheets other than Google Fonts). Thanos, for example:
  `https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4.1.13` and
  `https://cdn.jsdelivr.net/npm/@fortawesome/fontawesome-free@6.4.0/js/all.min.js`. A runtime that needs the
  project's own configuration gets it next to the pin, copied from the repo (for the Tailwind browser runtime, a
  `<style type="text/tailwindcss">` holding the project's `@custom-variant` and `@theme` lines, such as a
  class-based `dark` variant and its font).
  Prefer the repo's built CSS file inlined in a cells worker's style file when one exists, because a JS CSS
  runtime leaves screens unstyled when scripts are blocked. No other library loads from a CDN, except the
  Mermaid fallback below.
- **Mermaid** (only for a diagram that failed its check twice, SKILL.md §2) loads in that diagram's fragment
  as one module script, `import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.esm.min.mjs"`
  inside a try/catch, and the diagram is one `<pre class="mermaid">` captioned "drawn with Mermaid".
- **Title block.** The Diagrams row names the renderer actually used and is left out on a page with no
  diagram. A plan subject adds the Built from row, matching the `mentor-plan-sha256` meta. A plan that
  `plan-split` superseded adds one `<p>` under the rows naming it superseded and listing the child plans.
- **Theme.** Dark is the default whatever the reader's system setting (`references/rationale.md` "Why one
  scrolling page"). Light comes only from the theme button, stored per browser. Print always uses the light
  tokens. Both themes still meet the contrast rule in `surface-mockup-contract.md` §8.

## 4. Switching CSS

One fixed rule block serves every page and ships at the end of `assets/page.css`, so it reaches the page
through the same include line. Only a card's variants, its Before/After view and its width switch; cards and
hops always stack. Workers write no switching CSS and no JS. A build never regenerates it;
the loop that does, for a maintainer changing the caps or axes, is in `rationale.md` → **Why switching is
CSS-only**.

- **Caps.** Variants 1–12 per card; the card caps in `SKILL.md` §1 keep hops and frames bounded.
- **Positions and ids.** A variant radio's `data-i` is a render-time position; Copy and drafts read only
  `data-id`. A changed variant list regenerates the card's shell and hop files.
- **Without `:has()`** every variant and view stacks, each with its `.pv-cap` caption. Print shows everything,
  captioned.
- **In-mockup controls.** An advance control inside a frame that leads to the next hop is an
  `<a href="#scn-<scenario>-h<n>">`; one that changes the variant is a `<label for>` that variant's radio, and
  the radios stay the keyboard path. A frame inside `<iframe srcdoc>` has no advance control, because neither
  reaches out of the frame.

## 5. Scenario shells

**`000-open.html`:**

```html
<section id="sec-scenarios" aria-labelledby="sec-scenarios-h">
<h2 id="sec-scenarios-h">Scenarios</h2>
<p class="pg-lede">Each scenario follows one person from what they do to what they get, through every screen, message and call it reaches. {{N}} scenarios, {{M}} of them edge cases listed under their parent.</p>
<p class="pv-legend">Plain: verbatim from code · <span data-pv="new">NEW · §</span> proposed by the plan ·
<span class="pv-chrome">schematic host chrome</span> · <span data-pv="illus">illustrative or sample</span> ·
<span class="pv-gap" data-gap="untraced">not traced</span> · <span class="pv-gap" data-gap="unspecified">plan leaves open</span></p>
{{legend: keep only the entries the page uses; a non-plan page has no NEW or plan-leaves-open entry}}
<div class="pv-cards">
```

**`sNN-0-shell.html`** (one per card). A parent card has no `data-parent` and no `<small>`. Omit the variant
fieldset on a card with no variants, the view fieldset on a card with no toggle, the width fieldset unless a
frame reflows, and `.pv-axes` when no fieldset is left. The path list appears only on a card with two or more
hops or a stub; a one-hop card's hop heading already names its surface. One `pv-flow-ref` line follows for each
flow that lists this card under `also=` in `_ids.md`:

```html
<article class="pv-scn" id="scn-S4a" data-id="S4a" data-parent="S4" data-title="{{title}}" data-view-default="{{after|current}}" aria-labelledby="scn-S4a-h">
<p class="pv-cap">{{S4a · title}}</p>
<div class="pv-scn-bar">
<h3 id="scn-S4a-h"><span class="pv-scn-id">S4a</span>{{title}}<small>Edge case of S4: takes {{value}}</small></h3>
<div class="pv-axes">
<fieldset class="pv-ax pv-ax-variant"><legend>Variant</legend>
<input type="radio" name="S4a-variant" id="S4a-variant-ios" data-i="1" data-id="ios" checked><label for="S4a-variant-ios">iOS</label>
<input type="radio" name="S4a-variant" id="S4a-variant-android" data-i="2" data-id="android"><label for="S4a-variant-android">Android</label>
</fieldset>
<fieldset class="pv-ax pv-ax-view"><legend>View</legend>
<input type="radio" name="S4a-view" id="S4a-view-after" data-id="after" checked><label for="S4a-view-after">After</label>
<input type="radio" name="S4a-view" id="S4a-view-before" data-id="before"><label for="S4a-view-before">Before</label>
</fieldset>
</div>
</div>
<dl class="pv-trig"><dt>Who</dt><dd>{{actor}}</dd><dt>Does</dt><dd>{{trigger}}</dd><dt>Result</dt><dd>{{outcome}}</dd></dl>
<ol class="pv-path" aria-label="Path">
<li><a class="pv-stub" href="#scn-S4">same as S4 up to h1</a></li>
<li class="pv-via" aria-hidden="true">→ sync gate or execute job (async) →</li>
<li><a href="#scn-S4a-h3"><span class="pv-hop-n">h3</span> Web · /tickets/:id</a></li>
</ol>
<p class="pv-flow-ref">Sequence for this flow: <a href="#seq-2-flow">{{flow title}}</a>, drawn under S8.</p>
<div class="pv-stage">
```

A hop the card's path never reaches carries `class="pv-unreached"` on its path link and the text "not reached".
The title bar stays in view while the card scrolls, so its switches are always at hand.

**`sNN-z-close.html`:**

```html
</div>
<div class="pv-comment">
<label for="S4a-comment">Your comment on S4a</label>
<textarea id="S4a-comment" class="pv-ta" data-key="mentor-preview:{{subject-slug}}:S4a" rows="3"></textarea>
<button type="button" class="pv-copy" hidden>Copy</button>
<textarea class="pv-fallback" readonly hidden aria-label="Copy this text"></textarea>
</div>
</article>
```

**`zzz-close.html`:** `</div></section>`

**`sNN-s<k>.html`** (the sequences worker, one per flow this card owns; it sits inside the stage, after the
hops). The heading reads "Flowchart:" for a flow drawn as a flowchart:

```html
<section class="pv-flow" id="seq-2-flow" aria-labelledby="seq-2-h">
<h4 class="pv-flow-h" id="seq-2-h">Sequence: {{flow title}}</h4>
<figure id="seq-2-fig">{{the diagram, inlined as <svg class="dd">, its caption and Sources line}}</figure>
</section>
```

## 6. Questions and decisions

```html
<section id="sec-answers" aria-labelledby="sec-answers-h">
<h2 id="sec-answers-h">Questions for you</h2>
<p class="pg-lede">{{N}} open questions this page raised. Answer them in chat, one at a time; this list only shows them.</p>
<ol><li id="q-Q1"><strong>Q1</strong> {{question in plain words}} · Recommended: {{cleanest option}} · <span class="pv-trig">raised by {{S4 h2 | plan §A5}}</span></li></ol>
</section>
```

`90-decisions.html` is a `<section id="sec-decisions" aria-labelledby="sec-decisions-h">` with the title
Decisions and its lede, then two tables, each under an `<h3>`: **Settled with you** and **Defaults I set**, one
row per plan decision (id, decision, source), copied from the plan's decision table. A row goes under Settled
with you only when the plan marks it as the user's ("Settled with user"). A plan with no decision table of its
own gets **Stated in the plan** instead, for the decisions its text states, because calling them settled with
the reader would claim a conversation that never happened. Record `decisions: stated` in the `_ids.md` header
when it is used, so the table stays after `SKILL.md` §6 starts a `## Decisions` table with the first chat
answer; those answers go under Settled with you, beside it.

## 7. `99-foot.html`

```html
<footer id="sec-foot">
<p>{{Not affected by this plan | Not shown for this subject}}: {{sections left out, and scenarios left out because nothing received changes}}</p>
<p>Illustrative {{N}} · Sample {{N}} · Not traced {{N}} · Plan leaves open {{N}}</p>
</footer>
</main>
</div>
</div>
<script>
{{include page.js}}
</script>
</body>
</html>
```

- **Copy block.** `[mentor:preview] subject=<slug> scenario=<id> "<title>" [variant=<id>] view=<v>` on the first
  line, the comment below. `variant=` appears only on a card with variants. There is no `hop=`: every hop of a
  card is on screen at once, so the comment names the hop it means.
- **Drafts.** One `localStorage` key per card, `mentor-preview:<subject-slug>:<scenario-id>`, every access in
  try/catch. Locally opened pages share one origin, so the slug keeps subjects apart, and append-only ids keep
  a draft attached across regenerations. The page works fully when storage is unavailable.
- **Clipboard fallback.** When the clipboard is blocked (a sandboxed Artifact frame), the text appears selected
  in a read-only textarea.
- **Footer and flows.** When every flow is drawn under a scenario, the page has no Sequences section, and the
  footer says "Sequences are drawn under the scenario that starts each flow" instead of listing Sequences as
  not affected.

## 8. Checks

Run after assembly; each line prints `OK` or `BAD`:

```bash
page="$review_dir/review.html"
head -c 64 "$page" | tr 'A-Z' 'a-z' | grep -q '^<!doctype html' && echo "OK doctype" || echo "BAD doctype"
tail -c 64 "$page" | tr -d '[:space:]' | grep -q '</html>$' && echo "OK closing html" || echo "BAD closing html"
[ -s "$page" ] && echo "OK size $(wc -c < "$page" | tr -d ' ')" || echo "BAD empty"
dups=$(grep -o ' id="[^"]*"' "$page" | sort | uniq -d); [ -z "$dups" ] && echo "OK ids unique" || printf 'BAD duplicate ids\n%s\n' "$dups"
s=$(cat "$review_dir"/_parts/20-scenarios/*-[hs][0-9]*.html 2>/dev/null | grep -o '<script' | wc -l | tr -d ' '); [ "$s" = 0 ] && echo "OK no script in hop or flow files" || echo "BAD $s script tags in hop or flow files"
bad=$(grep -oE 'href="#(sec|scn|seq)-[^"]*"' "$page" | sort -u | sed 's/^href="#//;s/"$//' | while IFS= read -r id; do grep -qF " id=\"$id\"" "$page" || printf '%s ' "$id"; done); [ -z "$bad" ] && echo "OK page links" || echo "BAD links with no target: $bad"
n=$(grep -cE '^/\* mentor previewing assets/page\.(css|js):' "$page"); left=$(grep -c '^{{include ' "$page"); [ "$n" = 2 ] && [ "$left" = 0 ] && echo "OK assets inlined" || echo "BAD assets: $n of 2 inlined, $left include lines left"
[ "$(wc -c < "$page")" -gt 1048576 ] && echo "WARN review.html is over 1 MB (shots/ not counted)"
```

The size warning is reported to the user with the heaviest files, never fixed by cutting content: how frames
are drawn, and the one excerpt a long template may become, is `surface-mockup-contract.md` §8 → **Whole
screens from the real components**.

## 9. Publishing constraints

The page is written so it can be published as an Artifact without changes:

- external scripts only from `cdn.jsdelivr.net/npm/` (or another host the publishing tool allows) at an exact
  version; stylesheets only from Google Fonts; everything else inline;
- colours as tokens on `:root` (dark), redefined for the light theme under `[data-theme="light"]`, and an
  explicit `body` background;
- no horizontal page scroll at phone width: the contents fold into a top bar, frames scroll inside
  `.pv-stage`, and page prose wraps long names (§2);
- pictures from `shots/` by relative path, passed to the publishing tool as supporting files;
- host chrome stays schematic, because a page that imitates a real organisation's branding cannot be published.
